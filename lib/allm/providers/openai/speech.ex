defmodule ALLM.Providers.OpenAI.Speech do
  # Attribute block sits ABOVE the @moduledoc because the moduledoc
  # interpolates these constants, and an attribute must be defined before it
  # is read. Interpolating keeps the docs from drifting away from the code.

  @base_url "https://api.openai.com/v1"
  @endpoint "/audio/speech"

  # Adapter-injected defaults for fields the wire requires and Layer A allows
  # to be `nil`. Both are stated in the public `@doc` of `synthesize/2` and in
  # `to_json_body/2`'s `@doc false`, per the injected-default rule.
  @default_model "gpt-4o-mini-tts"
  @default_voice "alloy"

  # OpenAI's documented input limit, measured in Unicode CODE POINTS. The
  # 2026-09-24 probe settled the unit: 2049 x "e" + U+0301 (4098 code points,
  # 2049 graphemes) was rejected with `string_too_long`, and 4096 x U+00E9
  # (4096 code points, 8192 bytes) was accepted.
  @max_input_code_points 4096

  # Req's own `receive_timeout` default (15 s) is too short for a
  # 4096-character synthesis.
  @default_timeout_ms 60_000

  # Option keys that would change the RESPONSE SHAPE this decoder relies on.
  # `stream_format: "sse"` turns the raw-audio body into an event stream.
  @reserved_options ["stream_format"]

  @moduledoc """
  OpenAI text-to-speech adapter. Implements `ALLM.SpeechAdapter` against
  `POST /v1/audio/speech`.

  Layer B — runtime. Wire it with
  `ALLM.Engine.new(speech_adapter: ALLM.Providers.OpenAI.Speech)` and call it
  through `ALLM.synthesize/3`. The key resolves via
  `ALLM.Keys.fetch!(:openai, opts)` at request-build time, so no key ever
  lives on the engine.

      req = ALLM.SpeechRequest.new(input: "Hello.", voice: "coral", format: :wav)
      {:ok, resp} = ALLM.Providers.OpenAI.Speech.synthesize(req, api_key: "sk-...")
      {:ok, wav_bytes} = ALLM.Audio.to_binary(resp.audio)

  ## Wire-field map

  Observed live on **2026-09-24** by `scripts/record_openai_audio_fixtures.exs`,
  whose probe halts the recording pass on any mismatch.

  | Concern | OpenAI |
  |---------|--------|
  | Endpoint | `POST #{@base_url}#{@endpoint}`, JSON body |
  | Auth | `authorization: Bearer <key>` |
  | `input` | `ALLM.SpeechRequest.input`, at most #{@max_input_code_points} code points |
  | `model` | `:model`, or `#{@default_model}` when `nil` |
  | `voice` | `:voice`, or `#{@default_voice}` when `nil`. Forwarded verbatim; OpenAI's valid set differs per model |
  | `response_format` | `:format` as a string (`mp3`, `opus`, `aac`, `flac`, `wav`, `pcm`); omitted when `nil`, and OpenAI answers `mp3` |
  | `instructions`, `speed` | forwarded when set, omitted when `nil`. OpenAI accepts `instructions` on `tts-1` with a 200 even though it documents that model as ignoring them |
  | Options | `ALLM.SpeechRequest.options` merged **under** the fields above; `stream_format` is dropped |
  | 200 body | raw audio bytes; `content-type` names the format |
  | Usage | **none**: the body is raw audio, so `:usage` is an all-`nil` `%ALLM.Usage{}` |
  | Correlation | `x-request-id` response header |
  | Error envelope | `{"error": {"message", "type", "param", "code"}}`; the 401 is sent as `text/plain` |
  | Unknown fields | **ignored** (200), so a mistyped `:options` key does nothing and raises no error |

  ## Adapter-injected defaults

    * `model` defaults to `"#{@default_model}"` when `:model` is `nil`.
    * `voice` defaults to `"#{@default_voice}"` when `:voice` is `nil`. OpenAI
      requires a voice, and `alloy` is accepted by every model probed.
    * The HTTP receive timeout defaults to #{div(@default_timeout_ms, 1000)} s
      when `opts[:request_timeout]` is absent.

  ## Pre-flight gates

  Before any HTTP I/O and before `ALLM.Keys.fetch!/2`, so a request that is
  going to be rejected never needs a key:

    1. **Input shape.** A non-binary, empty, or non-UTF-8 `:input` →
       `:invalid_request` with `metadata.field: :input`.
    2. **Input length.** More than #{@max_input_code_points} **code points** →
       `:context_length_exceeded` with `metadata.count` and `metadata.max`.
       Code points, not graphemes and not bytes: an accented letter written
       as a base letter plus a combining mark counts twice, and a precomposed
       one counts once. The unit was settled by a live probe on 2026-09-24.
       A provider 400 whose message names `string_too_long` maps to the same
       reason, so a caller whose model has another limit sees one reason.

  ## Response

  `:audio` is `%ALLM.Audio{source: {:binary, bytes}}`. `:format` is derived
  from the response `content-type` through `ALLM.SpeechResponse.mime_to_format/1`,
  and `:audio.mime_type` is that format's canonical MIME type (or the raw
  content type when it is an `audio/*` type outside the table). A 200 whose
  content type is not `audio/*`, or whose body is empty, is
  `:malformed_response`. `:raw` is always `nil`: the audio bytes live once,
  in `:audio`. `:model` is the model that was sent.

  `opts[:request_id]` is reflected onto `response.request_id`; when absent,
  OpenAI's `x-request-id` header is used. `request.metadata` round-trips onto
  `response.metadata`.

  > #### The `x-request-id` fallback is unreachable through `ALLM.synthesize/3` {: .warning}
  >
  > The façade always supplies `opts[:request_id]` (it generates one when the
  > caller does not), so on that path `response.request_id` is the façade's
  > id and OpenAI's own correlation id is never observed. It surfaces only on
  > a direct `synthesize/2` / `decode_response/4` call that omits
  > `opts[:request_id]`. Identical to `ALLM.Providers.OpenAI.Moderation`.

  ## Retry

  Each attempt runs inside `ALLM.Retry.run/3` under `opts[:retry]`
  (default `:default`). The attempt marks `:rate_limited` (honouring
  `Retry-After`), `:provider_unavailable`, `:timeout` and `:network_error`
  as retryable, and the policy decides. The default policy's `retry_on` is
  HTTP codes plus `:timeout`, so on its own this loop retries **`:timeout`
  only**. Through `ALLM.synthesize/3` the façade retries all four reasons,
  and `:timeout` is retried by both loops: up to 9 attempts at the default
  policy, against 3 for the other three reasons.

  ## Error-struct hygiene

  `%ALLM.Error.SpeechAdapterError{}` derives `Jason.Encoder`, so it is
  often logged. No raw response body, request header or
  `Authorization` value is copied into it, and there is no body preview.
  Every provider-authored string it carries (`:message`,
  `metadata.openai_code`, `metadata.openai_type`) passes a redactor that
  replaces key-shaped tokens with `[REDACTED]`. OpenAI's real 401 masks the
  key it echoes (`sk-proj-*****…9900`, observed 2026-09-24); the redactor is
  defence in depth.

  > #### Not every error is JSON-encodable {: .warning}
  >
  > The struct derives `Jason.Encoder`, but a `:timeout`, `:network_error`
  > or invalid-JSON `:malformed_response` error carries an exception struct
  > (`Req.TransportError`, `Jason.DecodeError`) on `:cause`, and
  > `Jason.encode!/1` raises `Protocol.UndefinedError` on it. Drop or
  > `Exception.message/1` the `:cause` before encoding. The image, embedding
  > and moderation adapter errors share this limitation.

  ## Test-injection escape hatch

  `synthesize/2` honours `opts[:adapter_opts][:speech_script]`: when the key
  is present, the call is handed to `ALLM.Providers.FakeSpeech.synthesize/2`
  BEFORE any of this adapter's gates run. This is what lets the
  `ALLM.SpeechAdapter` conformance suite drive a real adapter without an
  HTTP stub. `prepare_request/2` returns a stub error under the same key,
  because a scripted response has no `Req.Request` analogue.
  """

  @behaviour ALLM.SpeechAdapter

  require Logger

  alias ALLM.{Audio, Keys, Retry, SpeechRequest, SpeechResponse, Usage}
  alias ALLM.Error.SpeechAdapterError
  alias ALLM.Providers.FakeSpeech
  alias ALLM.Providers.Support.OpenAIHeaders

  @doc """
  Synthesize speech from `request.input` against OpenAI.

  Returns `{:ok, %ALLM.SpeechResponse{}}` or
  `{:error, %ALLM.Error.SpeechAdapterError{}}`. The one exception is
  `ALLM.Keys.fetch!/2`, which raises `%ALLM.Error.EngineError{reason: :missing_key}`
  by design; both pre-flight gates run ahead of it.

  **Injected defaults:** `model` is `"#{@default_model}"` and `voice` is
  `"#{@default_voice}"` when the request leaves them `nil`, and the receive
  timeout is #{div(@default_timeout_ms, 1000)} s when `opts[:request_timeout]`
  is absent.

  **Retry:** this adapter's own `ALLM.Retry.run/3` loop retries `:timeout`
  under the default policy. `:rate_limited`, `:provider_unavailable` and
  `:network_error` are retryable too, but only under a caller-supplied
  `opts[:retry]` that lists them (as `ALLM.synthesize/3`'s own loop does).

  See the module documentation for the gates, the wire-field map and the
  `adapter_opts[:speech_script]` test-injection short-circuit.

  ## Examples

      iex> req = ALLM.SpeechRequest.new(input: "Hello.")
      iex> opts = [adapter_opts: [speech_script: [{:ok, "ID3-bytes"}]]]
      iex> {:ok, resp} = ALLM.Providers.OpenAI.Speech.synthesize(req, opts)
      iex> ALLM.Audio.to_binary(resp.audio)
      {:ok, "ID3-bytes"}

      iex> req = ALLM.SpeechRequest.new(input: String.duplicate("a", 4097))
      iex> {:error, err} = ALLM.Providers.OpenAI.Speech.synthesize(req, [])
      iex> {err.reason, err.metadata}
      {:context_length_exceeded, %{count: 4097, max: 4096}}
  """
  @impl ALLM.SpeechAdapter
  @spec synthesize(SpeechRequest.t(), keyword()) ::
          {:ok, SpeechResponse.t()} | {:error, SpeechAdapterError.t()}
  def synthesize(%SpeechRequest{} = request, opts) when is_list(opts) do
    case fetch_speech_script(opts) do
      nil -> do_synthesize(request, opts)
      _script -> FakeSpeech.synthesize(request, opts)
    end
  end

  @doc """
  Return an unfired `Req.Request` configured exactly as `synthesize/2` would
  fire it, for callers who add headers, middleware or their own retry loop.

  The pre-flight gates run first, so this is defined only for an input that
  passes them. Under `opts[:adapter_opts][:speech_script]` it returns a stub
  error instead of delegating to `ALLM.Providers.FakeSpeech`.

  ## Examples

      iex> req = ALLM.SpeechRequest.new(input: "Hi.")
      iex> {:ok, http} = ALLM.Providers.OpenAI.Speech.prepare_request(req, api_key: "sk-x")
      iex> URI.to_string(http.url)
      "https://api.openai.com/v1/audio/speech"
  """
  @impl ALLM.SpeechAdapter
  @spec prepare_request(SpeechRequest.t(), keyword()) ::
          {:ok, Req.Request.t()} | {:error, SpeechAdapterError.t()}
  def prepare_request(%SpeechRequest{} = request, opts) when is_list(opts) do
    case fetch_speech_script(opts) do
      nil ->
        with :ok <- run_gates(request, opts), do: build_request(request, opts)

      _script ->
        {:error, stub_error(opts)}
    end
  end

  # ---------------------------------------------------------------------------
  # Public testing seams (`@doc false` + `@spec`).
  #
  # Names align with the OpenAI adapter family (`openai/moderation.ex`,
  # `openai/embeddings.ex`): `to_json_body/2` returns a bare `map()`,
  # `decode_response/4` takes `(body, headers, request, opts)`, and the error
  # funnel is renamed per capability (`to_speech_adapter_error/4`). The
  # private helpers `build_metadata/2`, `retry_after_ms/1`, `header_value/2`,
  # `maybe_apply_req_test_stub/2`, `redact_key_material/1` and
  # `sanitize_cause/1` mirror the moderation adapter's, with three deliberate
  # differences:
  #
  #   * `decode_error_body/1` JSON-decodes a BINARY body. OpenAI sends its 401
  #     as `text/plain` carrying JSON, which `Req` leaves undecoded; the
  #     moderation copy returns `%{}` for every binary and so loses the
  #     message before the redactor sees it.
  #   * `sanitize_cause/1` also resets `:position` and `:token`: blanking only
  #     `:data` leaves `Jason.DecodeError.message/1` raising on the bad offset.
  #   * The error funnel tolerates a non-map `"error"` value, and redacts the
  #     provider's `code` / `type` as well as its message.
  # ---------------------------------------------------------------------------

  @doc false
  # Adapter-injected defaults: `model` "gpt-4o-mini-tts" and `voice` "alloy"
  # when nil (the public `synthesize/2` doc states both). nil `format`,
  # `instructions` and `speed` are OMITTED, never sent as null.
  # `request.options` merges UNDER the structural fields, and the reserved
  # `stream_format` key is dropped because it changes the response shape.
  @spec to_json_body(SpeechRequest.t(), keyword()) :: map()
  def to_json_body(%SpeechRequest{} = request, _opts) do
    body =
      %{
        "model" => request.model || @default_model,
        "input" => request.input,
        "voice" => request.voice || @default_voice
      }
      |> put_present("response_format", request.format && Atom.to_string(request.format))
      |> put_present("instructions", request.instructions)
      |> put_present("speed", request.speed)

    request.options
    |> stringify_option_keys()
    |> drop_reserved_options()
    |> Map.merge(body)
  end

  @doc false
  # Pre-flight gate 2: more than 4096 CODE POINTS -> :context_length_exceeded.
  # `String.length/1` would count graphemes, and `byte_size/1` bytes; the
  # 2026-09-24 probe showed the provider counts neither.
  @spec gate_input_length(SpeechRequest.t(), keyword()) :: :ok | {:error, SpeechAdapterError.t()}
  def gate_input_length(%SpeechRequest{input: input}, opts) when is_binary(input) do
    count = input |> String.codepoints() |> length()

    if count > @max_input_code_points do
      {:error,
       SpeechAdapterError.new(:context_length_exceeded,
         provider: :openai,
         message: "input is #{count} code points, over OpenAI's #{@max_input_code_points}",
         metadata: build_metadata(%{count: count, max: @max_input_code_points}, opts)
       )}
    else
      :ok
    end
  end

  @doc false
  @spec decode_response(term(), Enumerable.t() | map(), SpeechRequest.t(), keyword()) ::
          {:ok, SpeechResponse.t()} | {:error, SpeechAdapterError.t()}
  def decode_response(body, headers, request, opts)

  def decode_response(body, headers, %SpeechRequest{} = request, opts)
      when is_binary(body) and byte_size(body) > 0 do
    content_type = header_value(headers, "content-type")

    if audio_content_type?(content_type) do
      format = SpeechResponse.mime_to_format(content_type)
      mime = if format, do: SpeechResponse.format_to_mime(format), else: content_type

      {:ok,
       %SpeechResponse{
         audio: Audio.from_binary(body, mime),
         format: format,
         request_id: Keyword.get(opts, :request_id) || header_value(headers, "x-request-id"),
         model: request.model || @default_model,
         provider: :openai,
         usage: %Usage{},
         raw: nil,
         metadata: request.metadata
       }}
    else
      {:error,
       malformed_error(
         "200 content type #{inspect(redact_key_material(content_type || "(none)"))} is not audio/*",
         opts
       )}
    end
  end

  def decode_response("", _headers, _request, opts),
    do: {:error, malformed_error("empty audio body", opts)}

  def decode_response(_body, _headers, _request, opts),
    do: {:error, malformed_error("body is not raw audio bytes", opts)}

  @doc false
  # `body` may be a decoded map or an undecoded binary: OpenAI's 401 is
  # `text/plain` carrying JSON, which `Req` does not decode.
  @spec to_speech_adapter_error(non_neg_integer(), term(), Enumerable.t() | map(), keyword()) ::
          SpeechAdapterError.t()
  def to_speech_adapter_error(status, body, headers, opts) when is_integer(status) do
    error = body |> decode_error_body() |> error_object()
    message = provider_message(error, status)
    code = redact_optional(Map.get(error, "code"))
    type = redact_optional(Map.get(error, "type"))
    {reason, retry_after} = classify_speech_reason(status, message, retry_after_ms(headers))

    SpeechAdapterError.new(reason,
      provider: :openai,
      status: status,
      retry_after_ms: retry_after,
      message: message,
      metadata: build_metadata(%{status: status, openai_code: code, openai_type: type}, opts)
    )
  end

  # ---------------------------------------------------------------------------
  # Internals — gates
  # ---------------------------------------------------------------------------

  defp fetch_speech_script(opts) do
    opts
    |> Keyword.get(:adapter_opts, [])
    |> Keyword.get(:speech_script)
  end

  # Both gates run ahead of `Keys.fetch!/2`, which is what keeps the
  # unscripted conformance case green in a keyless environment.
  defp run_gates(%SpeechRequest{} = request, opts) do
    with :ok <- gate_input_shape(request, opts), do: gate_input_length(request, opts)
  end

  defp gate_input_shape(%SpeechRequest{input: input}, opts) do
    cond do
      not is_binary(input) -> input_error("input must be a string", opts)
      input == "" -> input_error("input must not be empty", opts)
      not String.valid?(input) -> input_error("input is not valid UTF-8", opts)
      true -> :ok
    end
  end

  defp input_error(message, opts) do
    {:error,
     SpeechAdapterError.new(:invalid_request,
       provider: :openai,
       message: message,
       metadata: build_metadata(%{field: :input}, opts)
     )}
  end

  defp stub_error(opts) do
    SpeechAdapterError.new(:unknown,
      provider: :openai,
      message: "prepare_request/2 has no analogue under the speech_script short-circuit",
      metadata: build_metadata(%{}, opts)
    )
  end

  defp build_metadata(metadata, opts) when is_map(metadata) do
    case Keyword.get(opts, :request_id) do
      nil -> metadata
      request_id -> Map.put(metadata, :request_id, request_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Internals — dispatch
  # ---------------------------------------------------------------------------

  defp do_synthesize(%SpeechRequest{} = request, opts) do
    with :ok <- run_gates(request, opts),
         {:ok, http_req} <- build_request(request, opts) do
      Retry.run(Keyword.get(opts, :retry, :default), retry_telemetry_meta(opts), fn ->
        run_one_attempt(http_req, request, opts)
      end)
    end
  end

  # `Keys.fetch!/2` raises `%EngineError{reason: :missing_key}` by documented
  # design and is not rescued. It runs AFTER `run_gates/2`.
  defp build_request(%SpeechRequest{} = request, opts) do
    api_key = Keys.fetch!(:openai, opts)

    req =
      Req.new(
        method: :post,
        url: @base_url <> @endpoint,
        headers: OpenAIHeaders.json_headers(api_key, opts),
        json: to_json_body(request, opts),
        # The only retry loop is `ALLM.Retry.run/3` above; Req's own must not
        # add attempts behind it.
        retry: false
      )
      |> maybe_apply_req_test_stub(opts)
      |> apply_receive_timeout(opts)

    {:ok, req}
  end

  defp maybe_apply_req_test_stub(req, opts) do
    case opts |> Keyword.get(:adapter_opts, []) |> Keyword.get(:plug) do
      nil -> req
      plug -> Req.merge(req, plug: plug)
    end
  end

  defp apply_receive_timeout(req, opts) do
    case Keyword.get(opts, :request_timeout) do
      ms when is_integer(ms) and ms > 0 -> Req.merge(req, receive_timeout: ms)
      _ -> Req.merge(req, receive_timeout: @default_timeout_ms)
    end
  end

  defp run_one_attempt(http_req, request, opts) do
    case Req.request(http_req) do
      {:ok, %Req.Response{status: status, body: body, headers: headers}}
      when status in 200..299 ->
        decode_response(body, headers, request, opts)

      {:ok, %Req.Response{status: status, body: body, headers: headers}} ->
        classified = to_speech_adapter_error(status, body, headers, opts)

        if classified.reason in [:rate_limited, :provider_unavailable] do
          {:retry, classified.retry_after_ms || 0, classified}
        else
          {:error, classified}
        end

      {:error, %{__struct__: Req.TransportError, reason: :timeout} = cause} ->
        {:retry, 0, transport_error(:timeout, "request timed out", cause, opts)}

      {:error, %{__struct__: Jason.DecodeError} = cause} ->
        {:error,
         %{malformed_error("response body is not valid JSON", opts) | cause: sanitize_cause(cause)}}

      {:error, exception} ->
        {:retry, 0,
         transport_error(
           :network_error,
           "transport failure: " <> Exception.message(exception),
           exception,
           opts
         )}
    end
  end

  defp transport_error(reason, message, cause, opts) do
    SpeechAdapterError.new(reason,
      provider: :openai,
      message: message,
      cause: sanitize_cause(cause),
      metadata: build_metadata(%{}, opts)
    )
  end

  defp retry_telemetry_meta(opts) do
    case Keyword.get(opts, :request_id) do
      nil -> %{provider: :openai}
      request_id -> %{provider: :openai, request_id: request_id}
    end
  end

  # ---------------------------------------------------------------------------
  # Internals — body builder
  # ---------------------------------------------------------------------------

  defp put_present(body, _key, nil), do: body
  defp put_present(body, key, value), do: Map.put(body, key, value)

  defp stringify_option_keys(options) when is_map(options) do
    Map.new(options, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp stringify_option_keys(_options), do: %{}

  defp drop_reserved_options(options) do
    case Map.take(options, @reserved_options) do
      dropped when map_size(dropped) == 0 ->
        options

      dropped ->
        Logger.debug(fn ->
          "ALLM.Providers.OpenAI.Speech: dropping reserved option(s) " <>
            "#{inspect(Map.keys(dropped))}; they would change the response shape."
        end)

        Map.drop(options, @reserved_options)
    end
  end

  # ---------------------------------------------------------------------------
  # Internals — decoding and errors
  # ---------------------------------------------------------------------------

  defp audio_content_type?(ct) when is_binary(ct),
    do: ct |> String.downcase() |> String.starts_with?("audio/")

  defp audio_content_type?(_ct), do: false

  defp malformed_error(detail, opts) do
    SpeechAdapterError.new(:malformed_response,
      provider: :openai,
      message: "could not decode OpenAI speech response: " <> detail,
      metadata: build_metadata(%{}, opts)
    )
  end

  defp decode_error_body(body) when is_map(body), do: body

  defp decode_error_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_error_body(_body), do: %{}

  defp error_object(body) do
    case Map.get(body, "error") do
      e when is_map(e) -> e
      e when is_binary(e) -> %{"message" => e}
      _ -> %{}
    end
  end

  defp provider_message(error, status) do
    case Map.get(error, "message") do
      m when is_binary(m) -> redact_key_material(m)
      _ -> "OpenAI HTTP #{status}"
    end
  end

  defp redact_optional(value) when is_binary(value), do: redact_key_material(value)
  defp redact_optional(_value), do: nil

  defp classify_speech_reason(status, _message, _ra) when status in [401, 403],
    do: {:authentication_failed, nil}

  defp classify_speech_reason(429, _message, ra), do: {:rate_limited, ra}

  defp classify_speech_reason(400, message, _ra) do
    if String.contains?(message, "string_too_long"),
      do: {:context_length_exceeded, nil},
      else: {:invalid_request, nil}
  end

  defp classify_speech_reason(status, _message, _ra) when status in [404, 413, 422],
    do: {:invalid_request, nil}

  defp classify_speech_reason(status, _message, ra) when status in [500, 502, 503, 504],
    do: {:provider_unavailable, ra}

  defp classify_speech_reason(_status, _message, _ra), do: {:unknown, nil}

  # `Jason.DecodeError` carries the undecodable payload on `:data`. Blanking
  # it alone leaves `:position` pointing past the end, and `message/1` then
  # raises, so all three offsets are reset together.
  defp sanitize_cause(%{__struct__: Jason.DecodeError} = cause),
    do: %{cause | data: "", position: 0, token: nil}

  defp sanitize_cause(cause), do: cause

  # Inherited from `ALLM.Providers.OpenAI.Moderation`: same provider, same key
  # shapes.
  defp redact_key_material(message) when is_binary(message) do
    String.replace(message, ~r/\b(?:sk|rk|org)-[A-Za-z0-9_\-]{6,}/, "[REDACTED]")
  end

  # ---------------------------------------------------------------------------
  # Internals — headers
  # ---------------------------------------------------------------------------

  defp retry_after_ms(headers) do
    case header_value(headers, "retry-after") do
      nil -> nil
      value -> parse_retry_after(value)
    end
  end

  defp header_value(headers, name) when is_map(headers) do
    headers |> Map.get(name) |> header_value_to_string()
  end

  defp header_value(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn
      {k, v} when is_binary(k) ->
        if String.downcase(k) == name, do: header_value_to_string(v), else: nil

      _ ->
        nil
    end)
  end

  defp header_value(_headers, _name), do: nil

  defp header_value_to_string([v | _]) when is_binary(v), do: v
  defp header_value_to_string(v) when is_binary(v), do: v
  defp header_value_to_string(_v), do: nil

  defp parse_retry_after(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> seconds * 1_000
      _ -> nil
    end
  end
end
