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

  # `stream_synthesize/2`: milliseconds of silence between two transport
  # messages before the stream ends with `:timeout`.
  @default_stream_timeout 60_000

  # OpenAI's `pcm` is headerless 24 kHz 16-bit mono, and its `wav` wraps the
  # same samples. No other rate can be requested, so these two formats accept
  # a `sample_rate` of `nil` or this value, and every other format accepts
  # only `nil`.
  @pcm_sample_rate 24_000
  @pcm_formats [:pcm, :wav]

  # Option keys that would change the RESPONSE SHAPE this decoder relies on.
  # `stream_format: "sse"` turns the raw-audio body into an event stream.
  @reserved_options ["stream_format"]

  @moduledoc """
  OpenAI text-to-speech adapter. Implements `ALLM.SpeechAdapter` and
  `ALLM.SpeechStreamAdapter` against `POST /v1/audio/speech`.

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
  | Streaming | the same request; the body arrives with `transfer-encoding: chunked`, and its first bytes arrive while the rest is still being synthesized (observed 2026-09-26 on `gpt-4o-mini-tts` and `tts-1`) |
  | `sample_rate` | not sent. `pcm` and `wav` are always 24,000 Hz, so the response reports `#{@pcm_sample_rate}` for them and `nil` otherwise |
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
    3. **Sample rate.** OpenAI cannot produce a requested rate. For `:pcm`
       and `:wav` a `sample_rate` of `nil` or `#{@pcm_sample_rate}` passes;
       for every other format (and for a `nil` format, which OpenAI answers
       as `mp3`) only `nil` passes. Anything else is `:unsupported_feature`
       with `metadata.field: :sample_rate`.

  `synthesize/2`, `prepare_request/2` and `stream_synthesize/2` run the same
  three gates.

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

  ## Streaming

  `stream_synthesize/2` sends the same request with `Finch.async_request/3`
  on the `ALLM.Finch` pool (HTTP/1) instead of `Req`, and returns a lazy
  stream of `ALLM.SpeechEvent` values: `:speech_started` when the response
  headers arrive, one `:audio_delta` per body chunk, then
  `:speech_completed`. Usage is an all-`nil` `%ALLM.Usage{}`, as on
  `synthesize/2`. `stream_synthesize_input/3` is not implemented: OpenAI's
  text-in streaming is a different API.

  An HTTP error status is not classified from the status alone. The error
  body is collected until the response ends and then classified exactly as
  `synthesize/2` classifies it, so the key redactor and the
  `string_too_long` rule see the provider's message. A stream is never
  retried once it has been returned.

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
  @behaviour ALLM.SpeechStreamAdapter
  @behaviour ALLM.Providers.Support.SpeechAdapter

  require Logger

  alias ALLM.{Audio, Keys, SpeechEvent, SpeechRequest, SpeechResponse, Usage}
  alias ALLM.Error.SpeechAdapterError
  alias ALLM.Providers.FakeSpeech
  alias ALLM.Providers.Support.{HTTPResponse, OpenAIHeaders}
  alias ALLM.Providers.Support.SpeechAdapter, as: SpeechSupport

  @doc """
  Synthesize speech from `request.input` against OpenAI.

  Returns `{:ok, %ALLM.SpeechResponse{}}` or
  `{:error, %ALLM.Error.SpeechAdapterError{}}`. The one exception is
  `ALLM.Keys.fetch!/2`, which raises `%ALLM.Error.EngineError{reason: :missing_key}`
  by design; all three pre-flight gates run ahead of it.

  **Sample rate:** `response.sample_rate` is `#{@pcm_sample_rate}` for `:pcm`
  and `:wav` and `nil` for every other format. A request `sample_rate` other
  than `nil` (or `#{@pcm_sample_rate}` for `:pcm` / `:wav`) is refused with
  `:unsupported_feature` before any I/O.

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
    case SpeechSupport.fetch_speech_script(opts) do
      nil -> SpeechSupport.do_synthesize(__MODULE__, :openai, request, opts)
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
    case SpeechSupport.fetch_speech_script(opts) do
      nil -> SpeechSupport.prepare_request(__MODULE__, request, opts)
      _script -> {:error, SpeechSupport.stub_error(:openai, opts)}
    end
  end

  @doc """
  Stream speech for `request.input` from OpenAI as it is synthesized.

  Returns `{:ok, enumerable}` of `ALLM.SpeechEvent` values, or
  `{:error, %ALLM.Error.SpeechAdapterError{}}` from a pre-flight gate. The
  three gates of `synthesize/2` run first, then `ALLM.Keys.fetch!/2` (which
  raises `%ALLM.Error.EngineError{reason: :missing_key}` by design). No
  HTTP request is made until the enumerable is reduced.

  **Injected defaults:** the same `model` (`"#{@default_model}"`) and
  `voice` (`"#{@default_voice}"`) as `synthesize/2`, and the same JSON body.

  **Options:**

    * `:stream_timeout` — milliseconds of silence between two transport
      messages before the stream ends with `{:error, %SpeechAdapterError{reason: :timeout}}`.
      Default #{@default_stream_timeout}. The transport's own receive timeout
      defaults above it (see `ALLM.Providers.Support.Transport`).
    * `:receive_timeout`, `:request_timeout`, `:pool_timeout` — forwarded
      to `Finch.async_request/3`.
    * `:finch_name` — the Finch pool (default `ALLM.Finch`).
    * `:finch_module` — the module called for `async_request/3` and
      `cancel_async_request/1` (default `Finch`); tests pass
      `ALLM.Test.FinchStub`.

  Each transport option is read from the top level of `opts`.
  `ALLM.stream_synthesize/3` hoists an engine's `adapter_opts:` transport
  keys (`ALLM.Adapter.transport_opts/0`) there, as the chat façades do; a
  direct call passes them at the top level.

  **Events:** `:speech_started` (with `sample_rate` #{@pcm_sample_rate} for
  `:pcm` and `:wav`, else `nil`) once the response headers arrive, one
  `:audio_delta` per non-empty body chunk, and `:speech_completed` with an
  all-`nil` usage. A failure ends the stream with one `{:error, _}`:

    * an HTTP error status: the error body is collected until the response
      ends, then classified as `synthesize/2` classifies it (a 401 is
      `:authentication_failed`, a `string_too_long` 400 is
      `:context_length_exceeded`), with provider strings redacted;
    * a 200 whose `content-type` is not `audio/*`: `:malformed_response`;
    * a 200 with no audio bytes: `:invalid_request` with
      `metadata.cause: :empty_input`;
    * no transport message within `:stream_timeout`: `:timeout`;
    * a transport failure: `:network_error`.

  **Halting** the stream early (`Enum.take/2`) cancels the HTTP request and
  removes the request's pending messages from the calling process's
  mailbox.

  `opts[:adapter_opts][:speech_script]` hands the call to
  `ALLM.Providers.FakeSpeech.stream_synthesize/2` before any gate runs.

  ## Examples

      iex> req = ALLM.SpeechRequest.new(input: "Hello.", format: :pcm)
      iex> opts = [adapter_opts: [speech_script: [{:ok, "PCM-bytes"}]]]
      iex> {:ok, events} = ALLM.Providers.OpenAI.Speech.stream_synthesize(req, opts)
      iex> for {:audio_delta, bytes} <- events, into: "", do: bytes
      "PCM-bytes"

      iex> req = ALLM.SpeechRequest.new(input: "Hi.", format: :mp3, sample_rate: 24_000)
      iex> {:error, err} = ALLM.Providers.OpenAI.Speech.stream_synthesize(req, [])
      iex> err.reason
      :unsupported_feature
  """
  @impl ALLM.SpeechStreamAdapter
  @spec stream_synthesize(SpeechRequest.t(), keyword()) ::
          {:ok, Enumerable.t(SpeechEvent.t())} | {:error, SpeechAdapterError.t()}
  def stream_synthesize(%SpeechRequest{} = request, opts) when is_list(opts) do
    case SpeechSupport.fetch_speech_script(opts) do
      nil -> do_stream_synthesize(request, opts)
      _script -> FakeSpeech.stream_synthesize(request, opts)
    end
  end

  # ---------------------------------------------------------------------------
  # Public testing seams (`@doc false` + `@spec`).
  #
  # Names align with the OpenAI adapter family (`openai/moderation.ex`,
  # `openai/embeddings.ex`): `to_json_body/2` returns a bare `map()`,
  # `decode_response/4` takes `(body, headers, request, opts)`, and the error
  # funnel is renamed per capability (`to_speech_adapter_error/4`). The HTTP
  # helpers come from `ALLM.Providers.Support.HTTPResponse`, and four choices
  # differ deliberately from the moderation adapter:
  #
  #   * `HTTPResponse.decode_json_error_body/1`, not `decode_error_body/1`:
  #     it JSON-decodes a BINARY body. OpenAI sends its 401 as `text/plain`
  #     carrying JSON, which `Req` leaves undecoded; the moderation adapter
  #     returns `%{}` for every binary and so loses the message before the
  #     redactor sees it.
  #   * `HTTPResponse.sanitize_cause/1`, which also resets `:position` and
  #     `:token`: the moderation adapter's private copy blanks only `:data`,
  #     which leaves `Jason.DecodeError.message/1` raising on the bad offset.
  #   * The error funnel tolerates a non-map `"error"` value
  #     (`HTTPResponse.error_object/1`), and redacts the provider's `code` /
  #     `type` as well as its message.
  #   * `HTTPResponse.apply_receive_timeout/3`, not the family's
  #     `maybe_apply_request_timeout/2`: without `opts[:request_timeout]` it
  #     applies `@default_timeout_ms` instead of leaving `req` unchanged, so it
  #     always sets a timeout.
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
      |> SpeechSupport.put_present(
        "response_format",
        request.format && Atom.to_string(request.format)
      )
      |> SpeechSupport.put_present("instructions", request.instructions)
      |> SpeechSupport.put_present("speed", request.speed)

    request.options
    |> SpeechSupport.stringify_keys()
    |> SpeechSupport.drop_reserved_options(
      @reserved_options,
      __MODULE__,
      "they would change the response shape."
    )
    |> Map.merge(body)
  end

  @doc false
  # Pre-flight gate 2: more than 4096 CODE POINTS -> :context_length_exceeded.
  # `String.length/1` would count graphemes, and `byte_size/1` bytes; the
  # 2026-09-24 probe showed the provider counts neither. Every code point is
  # at least one byte, so an input of at most 4096 bytes passes without the
  # count (which would otherwise build a list as long as the input).
  @spec gate_input_length(SpeechRequest.t(), keyword()) :: :ok | {:error, SpeechAdapterError.t()}
  def gate_input_length(%SpeechRequest{input: input}, _opts)
      when is_binary(input) and byte_size(input) <= @max_input_code_points,
      do: :ok

  def gate_input_length(%SpeechRequest{input: input}, opts) when is_binary(input) do
    count = input |> String.codepoints() |> length()

    if count > @max_input_code_points do
      {:error,
       SpeechAdapterError.new(:context_length_exceeded,
         provider: :openai,
         message: "input is #{count} code points, over OpenAI's #{@max_input_code_points}",
         metadata: HTTPResponse.build_metadata(%{count: count, max: @max_input_code_points}, opts)
       )}
    else
      :ok
    end
  end

  @doc false
  @impl SpeechSupport
  @spec decode_response(term(), Enumerable.t() | map(), SpeechRequest.t(), keyword()) ::
          {:ok, SpeechResponse.t()} | {:error, SpeechAdapterError.t()}
  def decode_response(body, headers, request, opts)

  def decode_response(body, headers, %SpeechRequest{} = request, opts)
      when is_binary(body) and byte_size(body) > 0 do
    content_type = HTTPResponse.header_value(headers, "content-type")

    if SpeechSupport.audio_content_type?(content_type) do
      format = SpeechResponse.mime_to_format(content_type)
      mime = if format, do: SpeechResponse.format_to_mime(format), else: content_type

      {:ok,
       %SpeechResponse{
         audio: Audio.from_binary(body, mime),
         format: format,
         sample_rate: sample_rate_for(format),
         request_id: request_id_for(opts, headers),
         model: request.model || @default_model,
         provider: :openai,
         usage: %Usage{},
         raw: nil,
         metadata: request.metadata
       }}
    else
      {:error, SpeechSupport.non_audio_error(__MODULE__, content_type, opts)}
    end
  end

  def decode_response("", _headers, _request, opts),
    do: {:error, malformed_error("empty audio body", opts)}

  def decode_response(_body, _headers, _request, opts),
    do: {:error, malformed_error("body is not raw audio bytes", opts)}

  @doc false
  # `body` may be a decoded map or an undecoded binary: OpenAI's 401 is
  # `text/plain` carrying JSON, which `Req` does not decode.
  @impl SpeechSupport
  @spec to_speech_adapter_error(non_neg_integer(), term(), Enumerable.t() | map(), keyword()) ::
          SpeechAdapterError.t()
  def to_speech_adapter_error(status, body, headers, opts) when is_integer(status) do
    error = body |> HTTPResponse.decode_json_error_body() |> HTTPResponse.error_object()
    message = provider_message(error, status)
    code = redact_optional(Map.get(error, "code"))
    type = redact_optional(Map.get(error, "type"))

    {reason, retry_after} =
      classify_speech_reason(status, message, HTTPResponse.retry_after_ms(headers))

    SpeechAdapterError.new(reason,
      provider: :openai,
      status: status,
      retry_after_ms: retry_after,
      message: message,
      metadata:
        HTTPResponse.build_metadata(%{status: status, openai_code: code, openai_type: type}, opts)
    )
  end

  # ---------------------------------------------------------------------------
  # Internals — gates and request building
  #
  # The shared contract (Fake hand-off, input-shape gate, retry loop,
  # transport errors, the HTTP stream) is `ALLM.Providers.Support.SpeechAdapter`'s;
  # the `@impl` functions below are the callbacks it invokes on this module.
  # ---------------------------------------------------------------------------

  @doc false
  # All three gates run ahead of `Keys.fetch!/2`, which is what keeps the
  # unscripted conformance cases green in a keyless environment. Shared by
  # `synthesize/2`, `prepare_request/2` and `stream_synthesize/2`.
  @impl SpeechSupport
  @spec run_gates(SpeechRequest.t(), keyword()) :: :ok | {:error, SpeechAdapterError.t()}
  def run_gates(%SpeechRequest{} = request, opts) do
    with :ok <- SpeechSupport.gate_input_shape(request, :openai, opts),
         :ok <- gate_input_length(request, opts) do
      gate_sample_rate(request, opts)
    end
  end

  # OpenAI produces 24 kHz for `pcm` / `wav` and exposes no rate parameter.
  defp gate_sample_rate(%SpeechRequest{sample_rate: nil}, _opts), do: :ok

  defp gate_sample_rate(%SpeechRequest{format: format, sample_rate: @pcm_sample_rate}, _opts)
       when format in @pcm_formats,
       do: :ok

  defp gate_sample_rate(%SpeechRequest{format: format, sample_rate: rate}, opts) do
    supported = if format in @pcm_formats, do: "nil or #{@pcm_sample_rate}", else: "nil"

    {:error,
     SpeechAdapterError.new(:unsupported_feature,
       provider: :openai,
       message:
         "OpenAI cannot produce sample_rate #{inspect(rate)} for format " <>
           "#{inspect(format)}; it accepts #{supported}",
       metadata:
         HTTPResponse.build_metadata(
           %{field: :sample_rate, sample_rate: rate, format: format},
           opts
         )
     )}
  end

  @doc false
  # `Keys.fetch!/2` raises `%EngineError{reason: :missing_key}` by documented
  # design and is not rescued. It runs AFTER `run_gates/2`.
  @impl SpeechSupport
  @spec build_request(SpeechRequest.t(), keyword()) :: {:ok, Req.Request.t()}
  def build_request(%SpeechRequest{} = request, opts) do
    api_key = Keys.fetch!(:openai, opts)

    req =
      Req.new(
        method: :post,
        url: @base_url <> @endpoint,
        headers: OpenAIHeaders.json_headers(api_key, opts),
        json: to_json_body(request, opts),
        # The only retry loop is `ALLM.Retry.run/3` in
        # `Support.SpeechAdapter.do_synthesize/4`; Req's own must not add
        # attempts behind it.
        retry: false
      )
      |> HTTPResponse.maybe_apply_req_test_stub(opts)
      |> HTTPResponse.apply_receive_timeout(opts, @default_timeout_ms)

    {:ok, req}
  end

  # ---------------------------------------------------------------------------
  # Internals — streaming
  #
  # The `Stream.resource/3` state machine over `Finch.async_request/3` is
  # `Support.SpeechAdapter.stream_resource/6`; this module supplies the
  # request and the three streaming callbacks below.
  # ---------------------------------------------------------------------------

  defp do_stream_synthesize(%SpeechRequest{} = request, opts) do
    with :ok <- run_gates(request, opts) do
      api_key = Keys.fetch!(:openai, opts)

      finch_request =
        Finch.build(
          :post,
          @base_url <> @endpoint,
          OpenAIHeaders.json_headers(api_key, opts),
          Jason.encode!(to_json_body(request, opts))
        )

      {:ok,
       SpeechSupport.stream_resource(
         __MODULE__,
         :openai,
         finch_request,
         request,
         opts,
         @default_stream_timeout
       )}
    end
  end

  @doc false
  @impl SpeechSupport
  @spec speech_started(String.t(), Enumerable.t() | map(), SpeechRequest.t(), keyword()) ::
          SpeechEvent.t()
  def speech_started(content_type, headers, %SpeechRequest{} = request, opts) do
    format = SpeechResponse.mime_to_format(content_type)

    SpeechEvent.speech_started(%{
      request_id: request_id_for(opts, headers),
      model: request.model || @default_model,
      provider: :openai,
      format: format,
      mime_type: if(format, do: SpeechResponse.format_to_mime(format), else: content_type),
      sample_rate: sample_rate_for(format)
    })
  end

  @doc false
  @impl SpeechSupport
  @spec speech_completed(Enumerable.t() | map(), SpeechRequest.t(), keyword()) ::
          SpeechEvent.t()
  def speech_completed(headers, %SpeechRequest{} = request, opts) do
    SpeechEvent.speech_completed(%{
      request_id: request_id_for(opts, headers),
      id: nil,
      usage: %Usage{},
      metadata: request.metadata
    })
  end

  @doc false
  @impl SpeechSupport
  @spec empty_audio_error(keyword()) :: SpeechAdapterError.t()
  def empty_audio_error(opts) do
    SpeechAdapterError.new(:invalid_request,
      provider: :openai,
      message: "OpenAI ended the stream without any audio bytes",
      metadata: HTTPResponse.build_metadata(%{cause: :empty_input}, opts)
    )
  end

  # The one correlation rule both paths share (the moduledoc's
  # "Correlation" row): the façade's request id, else `x-request-id`.
  defp request_id_for(opts, headers),
    do: Keyword.get(opts, :request_id) || HTTPResponse.header_value(headers, "x-request-id")

  # ---------------------------------------------------------------------------
  # Internals — decoding and errors
  # ---------------------------------------------------------------------------

  defp sample_rate_for(format) when format in @pcm_formats, do: @pcm_sample_rate
  defp sample_rate_for(_format), do: nil

  @doc false
  @impl SpeechSupport
  @spec malformed_error(String.t(), keyword()) :: SpeechAdapterError.t()
  def malformed_error(detail, opts),
    do: SpeechSupport.malformed_error(:openai, "OpenAI", detail, opts)

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

  @doc false
  # Inherited from `ALLM.Providers.OpenAI.Moderation`: same provider, same key
  # shapes.
  @impl SpeechSupport
  @spec redact_key_material(String.t()) :: String.t()
  def redact_key_material(message) when is_binary(message) do
    String.replace(message, ~r/\b(?:sk|rk|org)-[A-Za-z0-9_\-]{6,}/, "[REDACTED]")
  end
end
