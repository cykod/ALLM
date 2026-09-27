defmodule ALLM.Providers.Support.SpeechAdapter do
  @moduledoc """
  The shared half of the bundled `ALLM.SpeechAdapter` and
  `ALLM.SpeechStreamAdapter` implementations that speak HTTP.

  Layer B helper, the speech sibling of
  `ALLM.Providers.Support.TranscriptionAdapter`. Every bundled speech adapter
  follows the same contract around its provider-specific request building
  and decoding:

    * The test-injection hand-off: under `opts[:adapter_opts][:speech_script]`
      the call goes to `ALLM.Providers.FakeSpeech` before any gate runs.
    * Gates run before `ALLM.Keys.fetch!/2`; the input-shape gate is shared.
    * Each attempt runs inside `ALLM.Retry.run/3` under `opts[:retry]`, and
      marks `:rate_limited`, `:provider_unavailable`, `:timeout` and
      `:network_error` as retryable.
    * `Jason.DecodeError` and transport causes are sanitised before they
      reach an error.
    * The HTTP stream path (`stream_resource/6`) is one `Stream.resource/3`
      over `Finch.async_request/3`, with the same event order, error
      classification and cancel-and-drain on halt for every provider.

  The functions are `@doc false` seams parameterised by the provider atom
  (the `:provider` of every error built here). Where the flow needs the
  adapter's own steps, the adapter module is an argument and these
  callbacks are invoked on it: `run_gates/2`, `build_request/2`,
  `decode_response/4`, `to_speech_adapter_error/4`, `malformed_error/2` and
  `redact_key_material/1`, plus, for an adapter that streams,
  `speech_started/4`, `speech_completed/3` and `empty_audio_error/1`. An
  adapter that uses this module declares `@behaviour` for it alongside
  `ALLM.SpeechAdapter` and marks each one `@impl`, so the compiler reports a
  missing or misnamed callback.
  """

  require Logger

  alias ALLM.Error.SpeechAdapterError
  alias ALLM.Providers.Support.{HTTPResponse, Transport}
  alias ALLM.{Retry, SpeechEvent, SpeechRequest, SpeechResponse}

  @doc false
  # Every pre-flight gate, all before key resolution.
  @callback run_gates(SpeechRequest.t(), keyword()) :: :ok | {:error, SpeechAdapterError.t()}

  @doc false
  # The ready-to-send request; resolves the provider key.
  @callback build_request(SpeechRequest.t(), keyword()) ::
              {:ok, Req.Request.t()} | {:error, SpeechAdapterError.t()}

  @doc false
  # Decodes a 2xx body.
  @callback decode_response(term(), Enumerable.t() | map(), SpeechRequest.t(), keyword()) ::
              {:ok, SpeechResponse.t()} | {:error, SpeechAdapterError.t()}

  @doc false
  # Classifies a non-2xx response.
  @callback to_speech_adapter_error(non_neg_integer(), term(), Enumerable.t() | map(), keyword()) ::
              SpeechAdapterError.t()

  @doc false
  # The `:malformed_response` error carrying the adapter's own message.
  @callback malformed_error(String.t(), keyword()) :: SpeechAdapterError.t()

  @doc false
  # The provider's own key redactor, applied to a provider-authored string.
  @callback redact_key_material(String.t()) :: String.t()

  @doc false
  # Streaming only: the `:speech_started` event for an `audio/*` 2xx.
  @callback speech_started(String.t(), Enumerable.t() | map(), SpeechRequest.t(), keyword()) ::
              SpeechEvent.t()

  @doc false
  # Streaming only: the `:speech_completed` event after the last byte.
  @callback speech_completed(Enumerable.t() | map(), SpeechRequest.t(), keyword()) ::
              SpeechEvent.t()

  @doc false
  # Streaming only: the error for a 2xx stream that ended with no audio.
  @callback empty_audio_error(keyword()) :: SpeechAdapterError.t()

  @optional_callbacks speech_started: 4, speech_completed: 3, empty_audio_error: 1

  # ---------------------------------------------------------------------------
  # Non-streaming contract
  # ---------------------------------------------------------------------------

  @doc false
  # The Fake hand-off key; `nil` when the call should reach the provider.
  @spec fetch_speech_script(keyword()) :: term()
  def fetch_speech_script(opts) do
    opts
    |> Keyword.get(:adapter_opts, [])
    |> Keyword.get(:speech_script)
  end

  @doc false
  # The shared input-shape gate: a non-binary, empty or non-UTF-8 input is
  # `:invalid_request` with `metadata.field: :input`.
  @spec gate_input_shape(SpeechRequest.t(), atom(), keyword()) ::
          :ok | {:error, SpeechAdapterError.t()}
  def gate_input_shape(%SpeechRequest{input: input}, provider, opts) do
    cond do
      not is_binary(input) -> input_error("input must be a string", provider, opts)
      input == "" -> input_error("input must not be empty", provider, opts)
      not String.valid?(input) -> input_error("input is not valid UTF-8", provider, opts)
      true -> :ok
    end
  end

  defp input_error(message, provider, opts) do
    {:error,
     SpeechAdapterError.new(:invalid_request,
       provider: provider,
       message: message,
       metadata: HTTPResponse.build_metadata(%{field: :input}, opts)
     )}
  end

  @doc false
  # What `prepare_request/2` returns under the Fake hand-off key.
  @spec stub_error(atom(), keyword()) :: SpeechAdapterError.t()
  def stub_error(provider, opts) do
    SpeechAdapterError.new(:unknown,
      provider: provider,
      message: "prepare_request/2 has no analogue under the speech_script short-circuit",
      metadata: HTTPResponse.build_metadata(%{}, opts)
    )
  end

  @doc false
  # `prepare_request/2`'s provider path: the gates, then the request builder.
  @spec prepare_request(module(), SpeechRequest.t(), keyword()) ::
          {:ok, Req.Request.t()} | {:error, SpeechAdapterError.t()}
  def prepare_request(adapter, %SpeechRequest{} = request, opts) do
    with :ok <- adapter.run_gates(request, opts), do: adapter.build_request(request, opts)
  end

  @doc false
  # The provider path of `synthesize/2`: the adapter's gates, then its
  # request builder (which resolves the key), then the retry loop.
  @spec do_synthesize(module(), atom(), SpeechRequest.t(), keyword()) ::
          {:ok, SpeechResponse.t()} | {:error, SpeechAdapterError.t()}
  def do_synthesize(adapter, provider, %SpeechRequest{} = request, opts) do
    with :ok <- adapter.run_gates(request, opts),
         {:ok, http_req} <- adapter.build_request(request, opts) do
      Retry.run(Keyword.get(opts, :retry, :default), retry_telemetry_meta(provider, opts), fn ->
        run_one_attempt(adapter, provider, http_req, request, opts)
      end)
    end
  end

  @doc false
  # Fires `http_req` once and returns a `Retry.run/3` step.
  @spec run_one_attempt(module(), atom(), Req.Request.t(), SpeechRequest.t(), keyword()) ::
          {:ok, SpeechResponse.t()}
          | {:error, SpeechAdapterError.t()}
          | {:retry, non_neg_integer(), SpeechAdapterError.t()}
  def run_one_attempt(adapter, provider, http_req, request, opts) do
    case Req.request(http_req) do
      {:ok, %Req.Response{status: status, body: body, headers: headers}}
      when status in 200..299 ->
        adapter.decode_response(body, headers, request, opts)

      {:ok, %Req.Response{status: status, body: body, headers: headers}} ->
        classified = adapter.to_speech_adapter_error(status, body, headers, opts)

        if classified.reason in [:rate_limited, :provider_unavailable] do
          {:retry, classified.retry_after_ms || 0, classified}
        else
          {:error, classified}
        end

      {:error, %{__struct__: Req.TransportError, reason: :timeout} = cause} ->
        {:retry, 0, transport_error(:timeout, "request timed out", cause, provider, opts)}

      {:error, %{__struct__: Jason.DecodeError} = cause} ->
        {:error,
         %{
           adapter.malformed_error("response body is not valid JSON", opts)
           | cause: HTTPResponse.sanitize_cause(cause)
         }}

      {:error, exception} ->
        {:retry, 0,
         transport_error(
           :network_error,
           "transport failure: " <> Exception.message(exception),
           exception,
           provider,
           opts
         )}
    end
  end

  @doc false
  @spec transport_error(atom(), String.t(), term(), atom(), keyword()) :: SpeechAdapterError.t()
  def transport_error(reason, message, cause, provider, opts) do
    SpeechAdapterError.new(reason,
      provider: provider,
      message: message,
      cause: HTTPResponse.sanitize_cause(cause),
      metadata: HTTPResponse.build_metadata(%{}, opts)
    )
  end

  @doc false
  @spec retry_telemetry_meta(atom(), keyword()) :: map()
  def retry_telemetry_meta(provider, opts) do
    case Keyword.get(opts, :request_id) do
      nil -> %{provider: provider}
      request_id -> %{provider: provider, request_id: request_id}
    end
  end

  @doc false
  # The `:malformed_response` builder behind each adapter's
  # `malformed_error/2` callback; `label` names the provider in the message.
  @spec malformed_error(atom(), String.t(), String.t(), keyword()) :: SpeechAdapterError.t()
  def malformed_error(provider, label, detail, opts) do
    SpeechAdapterError.new(:malformed_response,
      provider: provider,
      message: "could not decode #{label} speech response: " <> detail,
      metadata: HTTPResponse.build_metadata(%{}, opts)
    )
  end

  @doc false
  # A 2xx whose content type is not `audio/*`; the content type is
  # provider-authored, so it passes the adapter's redactor.
  @spec non_audio_error(module(), String.t() | nil, keyword()) :: SpeechAdapterError.t()
  def non_audio_error(adapter, content_type, opts) do
    adapter.malformed_error(
      "200 content type #{inspect(adapter.redact_key_material(content_type || "(none)"))} is not audio/*",
      opts
    )
  end

  @doc false
  @spec audio_content_type?(term()) :: boolean()
  def audio_content_type?(ct) when is_binary(ct),
    do: ct |> String.downcase() |> String.starts_with?("audio/")

  def audio_content_type?(_ct), do: false

  @doc false
  # Atom keys become strings; anything that is not a map becomes `%{}`.
  @spec stringify_keys(term()) :: map()
  def stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  def stringify_keys(_other), do: %{}

  @doc false
  # `map` with `key` set, unless `value` is `nil` (a nil field is omitted
  # from a request body, never sent as null).
  @spec put_present(map(), String.t(), term()) :: map()
  def put_present(map, _key, nil), do: map
  def put_present(map, key, value), do: Map.put(map, key, value)

  @doc false
  # `options` without the `reserved` keys, with a deferred debug log naming
  # what was dropped and `why`.
  @spec drop_reserved_options(map(), [String.t()], module(), String.t()) :: map()
  def drop_reserved_options(options, reserved, adapter, why) do
    case Map.take(options, reserved) do
      dropped when map_size(dropped) == 0 ->
        options

      dropped ->
        Logger.debug(fn ->
          "#{inspect(adapter)}: dropping reserved option(s) #{inspect(Map.keys(dropped))}; " <>
            why
        end)

        Map.drop(options, reserved)
    end
  end

  # ---------------------------------------------------------------------------
  # Streaming over Finch
  #
  # `Stream.resource/3` over `Finch.async_request/3`. The three functions run
  # in the reducing process, so the Finch messages arrive in its mailbox.
  # `transport_done?` records that Finch sent its last message (`:done` or
  # `{:error, _}`); `terminal?` that the stream emitted its terminal event.
  # The two differ when the adapter ends the stream itself (a bad content
  # type, a timeout), and only a transport that is not done is cancelled.
  # ---------------------------------------------------------------------------

  @doc false
  # The speech event stream for an already-gated request. Transport options
  # are read from the top level of `opts`: `:finch_module` (default `Finch`),
  # `:finch_name` (default `ALLM.Finch`), `:stream_timeout` (default
  # `default_stream_timeout`) and the keys `Transport.finch_opts/2` forwards.
  @spec stream_resource(
          module(),
          atom(),
          Finch.Request.t(),
          SpeechRequest.t(),
          keyword(),
          pos_integer()
        ) :: Enumerable.t(SpeechEvent.t())
  def stream_resource(
        adapter,
        provider,
        finch_request,
        %SpeechRequest{} = request,
        opts,
        default_stream_timeout
      ) do
    finch_module = Keyword.get(opts, :finch_module, Finch)
    finch_name = Keyword.get(opts, :finch_name, ALLM.Finch)
    stream_timeout = Keyword.get(opts, :stream_timeout, default_stream_timeout)
    finch_opts = Transport.finch_opts(opts, stream_timeout)

    Stream.resource(
      fn ->
        ref = finch_module.async_request(finch_request, finch_name, finch_opts)
        new_stream_state(adapter, provider, ref, finch_module, request, opts)
      end,
      &stream_next(&1, stream_timeout),
      &stream_after/1
    )
  end

  defp new_stream_state(adapter, provider, ref, finch_module, request, opts) do
    %{
      adapter: adapter,
      provider: provider,
      ref: ref,
      finch_module: finch_module,
      request: request,
      opts: opts,
      status: nil,
      headers: [],
      error_body: [],
      bytes: 0,
      started?: false,
      transport_done?: false,
      terminal?: false
    }
  end

  defp stream_next(%{terminal?: true} = state, _timeout), do: {:halt, state}

  defp stream_next(%{ref: ref} = state, timeout) do
    receive do
      {^ref, message} -> handle_stream_message(message, state)
    after
      timeout ->
        terminate(
          state,
          SpeechAdapterError.new(:timeout,
            provider: state.provider,
            message: "no transport message within stream_timeout (#{timeout} ms)",
            metadata: HTTPResponse.build_metadata(%{}, state.opts)
          )
        )
    end
  end

  defp handle_stream_message({:status, status}, state), do: {[], %{state | status: status}}

  # A second `{:headers, _}` on a 2xx response carries HTTP trailers; only
  # the first starts the stream.
  defp handle_stream_message({:headers, headers}, %{status: status, started?: false} = state)
       when status in 200..299 do
    content_type = HTTPResponse.header_value(headers, "content-type")
    state = %{state | headers: headers, started?: true}
    %{adapter: adapter, request: request, opts: opts} = state

    if audio_content_type?(content_type) do
      {[adapter.speech_started(content_type, headers, request, opts)], state}
    else
      terminate(state, non_audio_error(adapter, content_type, opts))
    end
  end

  defp handle_stream_message({:headers, headers}, state),
    do: {[], %{state | headers: state.headers ++ headers}}

  defp handle_stream_message({:data, ""}, state), do: {[], state}

  defp handle_stream_message({:data, chunk}, %{status: status} = state)
       when status in 200..299 do
    {[SpeechEvent.audio_delta(chunk)], %{state | bytes: state.bytes + byte_size(chunk)}}
  end

  defp handle_stream_message({:data, chunk}, state),
    do: {[], %{state | error_body: [state.error_body | chunk]}}

  defp handle_stream_message(:done, state) do
    state = %{state | transport_done?: true}
    %{adapter: adapter, request: request, opts: opts, headers: headers} = state

    case state do
      %{status: status, bytes: 0} when status in 200..299 ->
        terminate(state, adapter.empty_audio_error(opts))

      %{status: status} when status in 200..299 ->
        {[adapter.speech_completed(headers, request, opts)], %{state | terminal?: true}}

      %{status: status} ->
        body = IO.iodata_to_binary(state.error_body)
        terminate(state, adapter.to_speech_adapter_error(status || 0, body, headers, opts))
    end
  end

  defp handle_stream_message({:error, exception}, state) do
    state = %{state | transport_done?: true}

    terminate(
      state,
      transport_error(
        :network_error,
        "transport failure: " <> Exception.message(exception),
        exception,
        state.provider,
        state.opts
      )
    )
  end

  defp handle_stream_message(_other, state), do: {[], state}

  defp terminate(state, %SpeechAdapterError{} = error),
    do: {[{:error, error}], %{state | terminal?: true}}

  # Cancel a request Finch has not finished, then drain the messages it had
  # already queued for this ref, so a halted stream leaves none behind.
  defp stream_after(%{ref: ref, finch_module: finch_module, transport_done?: done?}),
    do: Transport.cancel_and_drain(finch_module, ref, done?)
end
