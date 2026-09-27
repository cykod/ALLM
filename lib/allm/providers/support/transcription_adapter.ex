defmodule ALLM.Providers.Support.TranscriptionAdapter do
  @moduledoc """
  The shared half of the bundled `ALLM.TranscriptionAdapter` implementations.

  Layer B helper. Every bundled transcription adapter follows the same
  contract around its provider-specific request building and decoding:

    * The test-injection hand-off: under
      `opts[:adapter_opts][:transcription_script]` the call goes to
      `ALLM.Providers.FakeTranscription` before any gate runs, with
      `adapter_opts[:max_audio_bytes]` set to the adapter's own cap.
    * Gate order: audio that cannot be resolved, then audio over the
      adapter's byte cap, both before `ALLM.Keys.fetch!/2`.
    * One HTTP attempt per call, with no retry loop.
    * `Jason.DecodeError` causes are sanitised before they reach an error.

  The functions are `@doc false` seams parameterised by the provider atom
  (the `:provider` of every error built here). Where the flow needs the
  adapter's own steps, the adapter module is an argument and these
  callbacks are invoked on it: `gate_audio/2`, `build_request/2`,
  `decode_response/4`, `to_transcription_adapter_error/4` and
  `malformed_error/2`. They are declared as this module's callbacks, so an
  adapter that uses it declares `@behaviour` for this module alongside
  `ALLM.TranscriptionAdapter` and marks each one `@impl`; the compiler then
  reports a missing or misnamed callback.
  """

  alias ALLM.{Audio, TranscriptionRequest, TranscriptionResponse}
  alias ALLM.Error.TranscriptionAdapterError
  alias ALLM.Providers.Support.HTTPResponse

  @doc false
  # The adapter's pre-flight gates (resolvable, size, and any of its own),
  # all before key resolution.
  @callback gate_audio(TranscriptionRequest.t(), keyword()) ::
              :ok | {:error, TranscriptionAdapterError.t()}

  @doc false
  # The ready-to-send request; resolves the provider key.
  @callback build_request(TranscriptionRequest.t(), keyword()) ::
              {:ok, Req.Request.t()} | {:error, TranscriptionAdapterError.t()}

  @doc false
  # Decodes a 2xx body.
  @callback decode_response(term(), Enumerable.t() | map(), TranscriptionRequest.t(), keyword()) ::
              {:ok, TranscriptionResponse.t()} | {:error, TranscriptionAdapterError.t()}

  @doc false
  # Classifies a non-2xx response.
  @callback to_transcription_adapter_error(
              non_neg_integer(),
              term(),
              Enumerable.t() | map(),
              keyword()
            ) :: TranscriptionAdapterError.t()

  @doc false
  # The `:malformed_response` error carrying the adapter's own message.
  @callback malformed_error(String.t(), keyword()) :: TranscriptionAdapterError.t()

  @doc false
  # The Fake hand-off key; `nil` when the call should reach the provider.
  @spec fetch_transcription_script(keyword()) :: term()
  def fetch_transcription_script(opts) do
    opts
    |> Keyword.get(:adapter_opts, [])
    |> Keyword.get(:transcription_script)
  end

  @doc false
  # Opts for the Fake hand-off: the adapter's own byte cap replaces the
  # Fake's small default, so a real clip is not rejected by the Fake.
  @spec with_own_cap(keyword(), pos_integer()) :: keyword()
  def with_own_cap(opts, max_audio_bytes) do
    adapter_opts =
      opts
      |> Keyword.get(:adapter_opts, [])
      |> Keyword.put(:max_audio_bytes, max_audio_bytes)

    Keyword.put(opts, :adapter_opts, adapter_opts)
  end

  @doc false
  # The resolvable gate: the audio's byte count, or `:invalid_request` when
  # it cannot be resolved (including an `:audio` that is not an `%Audio{}`).
  @spec measure(term(), atom(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, TranscriptionAdapterError.t()}
  def measure(%Audio{} = audio, provider, opts) do
    case Audio.size(audio) do
      {:ok, count} -> {:ok, count}
      {:error, cause} -> {:error, unresolvable_error(cause, provider, opts)}
    end
  end

  def measure(_audio, provider, opts),
    do: {:error, unresolvable_error(:invalid_source, provider, opts)}

  @doc false
  # The size gate against the adapter's `max_audio_bytes/0`.
  @spec gate_size(non_neg_integer(), pos_integer(), atom(), keyword()) ::
          :ok | {:error, TranscriptionAdapterError.t()}
  def gate_size(count, max_audio_bytes, _provider, _opts) when count <= max_audio_bytes, do: :ok

  def gate_size(count, max_audio_bytes, provider, opts) do
    {:error,
     TranscriptionAdapterError.new(:invalid_request,
       provider: provider,
       message: "audio is #{count} bytes, over max_audio_bytes #{max_audio_bytes}",
       metadata:
         HTTPResponse.build_metadata(%{field: :audio, count: count, max: max_audio_bytes}, opts)
     )}
  end

  @doc false
  @spec unresolvable_error(term(), atom(), keyword()) :: TranscriptionAdapterError.t()
  def unresolvable_error(cause, provider, opts) do
    TranscriptionAdapterError.new(:invalid_request,
      provider: provider,
      message: "audio bytes could not be resolved (#{inspect(cause)})",
      metadata: HTTPResponse.build_metadata(%{field: :audio, cause: cause}, opts)
    )
  end

  @doc false
  # What `prepare_request/2` returns under the Fake hand-off key.
  @spec stub_error(atom(), keyword()) :: TranscriptionAdapterError.t()
  def stub_error(provider, opts) do
    TranscriptionAdapterError.new(:unknown,
      provider: provider,
      message: "prepare_request/2 has no analogue under the transcription_script short-circuit",
      metadata: HTTPResponse.build_metadata(%{}, opts)
    )
  end

  @doc false
  # The provider path of `transcribe/2`: the adapter's gates, then its
  # request builder (which resolves the key), then one attempt.
  @spec do_transcribe(module(), atom(), TranscriptionRequest.t(), keyword()) ::
          {:ok, TranscriptionResponse.t()} | {:error, TranscriptionAdapterError.t()}
  def do_transcribe(adapter, provider, %TranscriptionRequest{} = request, opts) do
    with :ok <- adapter.gate_audio(request, opts),
         {:ok, http_req} <- adapter.build_request(request, opts) do
      run_one_attempt(adapter, provider, http_req, request, opts)
    end
  end

  @doc false
  # Fires `http_req` once and classifies the outcome. Never retries.
  @spec run_one_attempt(module(), atom(), Req.Request.t(), TranscriptionRequest.t(), keyword()) ::
          {:ok, TranscriptionResponse.t()} | {:error, TranscriptionAdapterError.t()}
  def run_one_attempt(adapter, provider, http_req, request, opts) do
    case Req.request(http_req) do
      {:ok, %Req.Response{status: status, body: body, headers: headers}}
      when status in 200..299 ->
        adapter.decode_response(body, headers, request, opts)

      {:ok, %Req.Response{status: status, body: body, headers: headers}} ->
        {:error, adapter.to_transcription_adapter_error(status, body, headers, opts)}

      {:error, %{__struct__: Req.TransportError, reason: :timeout} = cause} ->
        {:error, transport_error(:timeout, "request timed out", cause, provider, opts)}

      {:error, %{__struct__: Jason.DecodeError} = cause} ->
        {:error,
         %{
           adapter.malformed_error("response body is not valid JSON", opts)
           | cause: HTTPResponse.sanitize_cause(cause)
         }}

      {:error, exception} ->
        {:error,
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
  @spec transport_error(atom(), String.t(), term(), atom(), keyword()) ::
          TranscriptionAdapterError.t()
  def transport_error(reason, message, cause, provider, opts) do
    TranscriptionAdapterError.new(reason,
      provider: provider,
      message: message,
      cause: HTTPResponse.sanitize_cause(cause),
      metadata: HTTPResponse.build_metadata(%{}, opts)
    )
  end

  @doc false
  # A one-element field list when `value` is set, else `[]`.
  @spec optional_field(String.t(), term()) :: [{String.t(), term()}]
  def optional_field(_name, nil), do: []
  def optional_field(name, value), do: [{name, value}]

  @doc false
  # `request.options` as multipart form fields, sorted by name. Keys are
  # stringified; a list value becomes one field per element under the bare
  # key; `nil` values are skipped; numbers and atoms are stringified and
  # other terms JSON-encoded. Keys in `structural` are removed and returned
  # as the second element, so the adapter can log what it dropped.
  @spec option_fields(term(), [String.t()]) :: {[{String.t(), String.t()}], [String.t()]}
  def option_fields(options, structural) when is_map(options) do
    stringified =
      Map.new(options, fn
        {k, v} when is_atom(k) -> {Atom.to_string(k), v}
        {k, v} -> {k, v}
      end)

    fields =
      stringified
      |> Map.drop(structural)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn {name, value} -> form_values(name, value) end)

    {fields, stringified |> Map.take(structural) |> Map.keys()}
  end

  def option_fields(_options, _structural), do: {[], []}

  defp form_values(name, values) when is_list(values),
    do: Enum.flat_map(values, &form_values(name, &1))

  defp form_values(_name, nil), do: []
  defp form_values(name, value) when is_binary(value), do: [{name, value}]

  defp form_values(name, value) when is_number(value) or is_atom(value),
    do: [{name, to_string(value)}]

  defp form_values(name, value), do: [{name, Jason.encode!(value)}]

  @doc false
  # The audio bytes, or `:invalid_request` when they cannot be read.
  @spec resolve_bytes(Audio.t(), atom(), keyword()) ::
          {:ok, binary()} | {:error, TranscriptionAdapterError.t()}
  def resolve_bytes(%Audio{} = audio, provider, opts) do
    case Audio.to_binary(audio) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, cause} -> {:error, unresolvable_error(cause, provider, opts)}
    end
  end
end
