defmodule ALLM.Providers.ElevenLabs.Speech do
  # Attribute block sits ABOVE the @moduledoc because the moduledoc
  # interpolates these constants, and an attribute must be defined before it
  # is read.

  @endpoint "/v1/text-to-speech/"

  # Adapter-injected defaults for fields the wire requires and Layer A allows
  # to be `nil`. Each is stated in the public `@doc` of `synthesize/2` and in
  # the `@doc false` of the builder that writes it (`url/2` for the voice,
  # `to_json_body/2` for the model). The voice was accepted with a 200 by the
  # 2026-09-26 probe (`tts_default` arm).
  @default_model "eleven_flash_v2_5"
  @default_voice "JBFqnCBsd6RMkjVDRZzb"

  # Req's own `receive_timeout` default (15 s) is too short for a long clip.
  @default_timeout_ms 60_000

  # Both stream paths: milliseconds of silence (no transport message and,
  # on the WebSocket path, no input chunk) before the stream ends with
  # `:timeout`.
  @default_stream_timeout 60_000

  # ElevenLabs closes an idle `/stream-input` socket after
  # `inactivity_timeout` seconds (documented default 20, maximum 180).
  @max_inactivity_timeout 180

  # `/stream-input` query parameters sent unless `options["query"]` sets
  # them. `auto_mode=true` gave the first audio frame in 238 ms against
  # 563 ms under the provider's default `chunk_length_schedule` (2026-09-27
  # probe, `speech_stream/recorded/ws_tokens*.json`, same four tokens).
  @ws_query_defaults %{"auto_mode" => "true"}

  # `request.options` keys that the adapter owns. `output_format` is derived
  # from `format` + `sample_rate`, `model_id` and `text` duplicate modelled
  # fields. They are dropped with a debug log. `query` is not dropped: it
  # holds extra query parameters for the URL, never a body field.
  @reserved_options ["output_format", "model_id", "text"]

  @moduledoc """
  ElevenLabs text-to-speech adapter. Implements `ALLM.SpeechAdapter`
  against `POST /v1/text-to-speech/{voice_id}`.

  Layer B — runtime. Wire it with
  `ALLM.Engine.new(speech_adapter: ALLM.Providers.ElevenLabs.Speech)` and
  call it through `ALLM.synthesize/3`. The key resolves via
  `ALLM.Keys.fetch!(:elevenlabs, opts)` (environment variable
  `ELEVENLABS_API_KEY`) after the pre-flight gates, so no key ever lives on
  the engine.

      req = ALLM.SpeechRequest.new(input: "Hello.", format: :pcm)
      {:ok, resp} = ALLM.Providers.ElevenLabs.Speech.synthesize(req, api_key: "sk_...")
      {resp.sample_rate, resp.audio.mime_type}

  ## Wire-field map

  Observed live on **2026-09-26** by
  `scripts/record_elevenlabs_audio_fixtures.exs`, whose probe halts the
  recording pass on any mismatch.

  | Concern | ElevenLabs |
  |---------|------------|
  | Endpoint | `POST <host>#{@endpoint}<voice>?output_format=…`, JSON body. The host is `https://api.elevenlabs.io` unless `opts[:base_url]` or `adapter_opts[:base_url]` names another (e.g. a data-residency host) |
  | Auth | `xi-api-key: <key>` |
  | Voice | `:voice`, in the URL path, or `#{@default_voice}` when `nil` |
  | `text` | `ALLM.SpeechRequest.input` |
  | `model_id` | `:model`, or `#{@default_model}` when `nil` |
  | `output_format` | from `:format` and `:sample_rate` (table below) |
  | `speed` | sent as `voice_settings.speed` |
  | `instructions` | ElevenLabs has no such field; refused (see gates) |
  | Options | merged **under** the fields above into the JSON body; a `"voice_settings"` map is merged with `speed`, so both are sent. `options["query"]` (a map) adds URL query parameters under `output_format`. `output_format`, `model_id` and `text` are dropped |
  | 200 body | raw audio bytes; `content-type` names the format (`audio/mpeg`, `audio/pcm`, `audio/wav`, `audio/opus`) |
  | Correlation | the `request-id` response header → `response.id` |
  | Cost | the `character-cost` response header → `response.raw` as `%{"character_cost" => n}` |
  | Usage | **none**: the body is raw audio, so `:usage` is an all-`nil` `%ALLM.Usage{}` |
  | Unknown fields | **ignored** (200), so a mistyped `:options` key does nothing and raises no error |

  ## Formats and sample rates

  | `:format` | `:sample_rate` accepted (`nil` → default) | `output_format` |
  |-----------|--------------------------------------------|-----------------|
  | `:mp3` or `nil` | 22050, 24000, **44100** | `mp3_22050_32`, `mp3_24000_48`, `mp3_44100_128` |
  | `:opus` | **48000** | `opus_48000_64` |
  | `:pcm` | 8000, 16000, 22050, **24000**, 32000, 44100, 48000 | `pcm_<rate>` |
  | `:wav` | the same, **24000** by default | `wav_<rate>` |
  | `:aac`, `:flac` | — | refused, `:unsupported_feature` |

  `pcm_44100` and `wav_44100` need ElevenLabs' Pro tier; a lower tier's 403
  surfaces as `:unsupported_feature`.

  ## Adapter-injected defaults

    * `voice` defaults to `"#{@default_voice}"` when `:voice` is `nil`.
      ElevenLabs puts the voice in the URL path, so there is no request
      without one.
    * `model_id` defaults to `"#{@default_model}"`, ElevenLabs' low-latency
      model, when `:model` is `nil`.
    * `output_format` defaults to `mp3_44100_128` when `:format` is `nil`,
      and a `nil` `:sample_rate` takes the **bold** default of the table
      above.
    * The HTTP receive timeout defaults to #{div(@default_timeout_ms, 1000)} s
      when `opts[:request_timeout]` is absent.
    * On `/stream-input` only: `inactivity_timeout` is
      `min(#{@max_inactivity_timeout}, ceil(stream_timeout / 1000))` seconds, and
      `auto_mode=true` unless `options["query"]` sets `auto_mode` (see
      `stream_synthesize_input/3` for the latency and quality trade-off).

  ## Pre-flight gates

  In this order, before any HTTP I/O and before `ALLM.Keys.fetch!/2`, so a
  request that is going to be rejected never needs a key:

    1. **Input shape.** A non-binary, empty, or non-UTF-8 `:input` →
       `:invalid_request` with `metadata.field: :input`.
    2. **Instructions.** A non-`nil` `:instructions` → `:unsupported_feature`
       with `metadata.field: :instructions`.
    3. **Format and sample rate.** A format or rate outside the table above →
       `:unsupported_feature` with `metadata.field` `:format` or
       `:sample_rate`.

  There is no local input-length gate: the limit differs per model. A
  provider 400 whose `detail` names `text_too_long` maps to
  `:context_length_exceeded`.

  ## Response

  `:audio` is `%ALLM.Audio{source: {:binary, bytes}}`. `:format` is derived
  from the response `content-type` through `ALLM.SpeechResponse.mime_to_format/1`,
  and `:audio.mime_type` is that format's canonical MIME type. A 200 whose
  content type is not `audio/*`, or whose body is empty, is
  `:malformed_response`. `:sample_rate` is the rate that was requested (the
  response does not state it). `:model` is the model that was sent.
  `opts[:request_id]` is reflected onto `response.request_id`, and
  `request.metadata` round-trips onto `response.metadata`.

  ## Streaming

  This module also implements `ALLM.SpeechStreamAdapter`, with both
  callbacks:

    * `stream_synthesize/2` sends the same request to
      `POST /v1/text-to-speech/{voice_id}/stream` with `Finch.async_request/3`
      (HTTP/1, the `ALLM.Finch` pool) and emits one `:audio_delta` per body
      chunk. The body is raw chunked audio (observed 2026-09-27: 44
      characters of `pcm_24000` arrived in 26 chunks between 425 ms and
      545 ms). `:speech_completed.id` is the `request-id` header.
    * `stream_synthesize_input/3` speaks an enumerable of text chunks over
      `wss://<host>/v1/text-to-speech/{voice_id}/stream-input`, through
      `ALLM.Providers.Support.WebSocket`. The key goes in the upgrade
      request's `xi-api-key` header, never in the URL.

  | Concern | `/stream-input` (observed 2026-09-27) |
  |---------|------------------------------------------|
  | Query | `model_id`, `output_format`, `inactivity_timeout`, `auto_mode=true` by default; `options["query"]` adds parameters under the first three and may replace `auto_mode` |
  | Initial message | `{"text": " "}` plus `voice_settings` (with `speed`) and the other `options` keys. Unknown keys are ignored |
  | Text | `{"text": text}`, no space appended; whole words only under `auto_mode` (the adapter buffers to a word boundary), each non-empty chunk verbatim without it |
  | End of input | `{"text": "", "flush": true}`, then `{"text": ""}`; the server answers with its last audio, `isFinal: true` and a close 1000 |
  | Audio | `{"audio": base64, "alignment", "normalizedAlignment", "isFinal"}`; a `nil` or `""` audio is skipped |
  | Errors | a bad or missing key and an unknown voice still upgrade with 101, then send `{"error": code, "message", "code": 1008}` and close 1008. `invalid_api_key` and `authentication_required` are `:authentication_failed`, `voice_id_does_not_exist` is `:invalid_request` |
  | Upgrade errors | a model the endpoint does not serve is refused at the upgrade with an HTTP 400 `unsupported_model` (`eleven_v3`), `:invalid_request` |
  | Keep-alive | `{"text": " "}` after half of `inactivity_timeout` without a client frame; a keep-alive sent between `"Hi"` and `" there."` left the returned alignment `" Hi there."` |

  Neither stream is retried once it has been returned.

  ## Retry

  Each attempt runs inside `ALLM.Retry.run/3` under `opts[:retry]`
  (default `:default`). The attempt marks `:rate_limited` (honouring
  `Retry-After`), `:provider_unavailable`, `:timeout` and `:network_error`
  as retryable, and the policy decides. The default policy's `retry_on` is
  HTTP codes plus `:timeout`, so on its own this loop retries **`:timeout`
  only**. Through `ALLM.synthesize/3` the façade retries all four reasons.
  An out-of-credit error is `:invalid_request` and is never retried.

  ## Error-struct hygiene

  No raw response body, request header or `xi-api-key` value is copied into
  `%ALLM.Error.SpeechAdapterError{}`. The provider's message and its
  `detail.code`, `detail.type` and `detail.status` (`metadata.code`,
  `metadata.type`, `metadata.provider_status`) pass a redactor that replaces
  ElevenLabs-shaped keys (`sk_…`) with `[REDACTED]`. ElevenLabs' invalid-key
  error does not echo the key (observed 2026-09-26); the redactor is defence
  in depth.

  ## Test-injection escape hatch

  `synthesize/2`, `stream_synthesize/2` and `stream_synthesize_input/3`
  honour `opts[:adapter_opts][:speech_script]`: when the key is present, the
  call is handed to the same-named `ALLM.Providers.FakeSpeech` function
  BEFORE any of this adapter's gates run. `prepare_request/2` returns a stub
  error under the same key.
  """

  @behaviour ALLM.SpeechAdapter
  @behaviour ALLM.SpeechStreamAdapter
  @behaviour ALLM.Providers.Support.SpeechAdapter

  alias ALLM.{Audio, Keys, SpeechEvent, SpeechRequest, SpeechResponse, Usage, Validate}
  alias ALLM.Error.{SpeechAdapterError, ValidationError}
  alias ALLM.Providers.FakeSpeech
  alias ALLM.Providers.Support.ElevenLabs, as: Support
  alias ALLM.Providers.Support.{HTTPResponse, InputPump}
  alias ALLM.Providers.Support.SpeechAdapter, as: SpeechSupport
  alias ALLM.Providers.Support.WebSocket.InputLoop

  @doc """
  Synthesize speech from `request.input` against ElevenLabs.

  Returns `{:ok, %ALLM.SpeechResponse{}}` or
  `{:error, %ALLM.Error.SpeechAdapterError{}}`. The one exception is
  `ALLM.Keys.fetch!/2`, which raises `%ALLM.Error.EngineError{reason: :missing_key}`
  by design; all three pre-flight gates run ahead of it.

  **Injected defaults:** `voice` is `"#{@default_voice}"` and `model_id` is
  `"#{@default_model}"` when the request leaves them `nil`; `output_format`
  is `mp3_44100_128` for a `nil` format, and a `nil` `sample_rate` takes the
  format's default (44,100 for mp3, 48,000 for opus, 24,000 for pcm and
  wav); the receive timeout is #{div(@default_timeout_ms, 1000)} s when
  `opts[:request_timeout]` is absent.

  **Refused before any I/O** with `:unsupported_feature`: `instructions`,
  `format: :aac | :flac`, and a `sample_rate` outside the format's set.

  **Retry:** this adapter's own `ALLM.Retry.run/3` loop retries `:timeout`
  under the default policy. `:rate_limited`, `:provider_unavailable` and
  `:network_error` are retryable too, but only under a caller-supplied
  `opts[:retry]` that lists them (as `ALLM.synthesize/3`'s own loop does).

  See the module documentation for the wire-field map and the
  `adapter_opts[:speech_script]` test-injection short-circuit.

  ## Examples

      iex> req = ALLM.SpeechRequest.new(input: "Hello.")
      iex> opts = [adapter_opts: [speech_script: [{:ok, "ID3-bytes"}]]]
      iex> {:ok, resp} = ALLM.Providers.ElevenLabs.Speech.synthesize(req, opts)
      iex> ALLM.Audio.to_binary(resp.audio)
      {:ok, "ID3-bytes"}

      iex> req = ALLM.SpeechRequest.new(input: "Hi.", instructions: "Speak slowly.")
      iex> {:error, err} = ALLM.Providers.ElevenLabs.Speech.synthesize(req, [])
      iex> {err.reason, err.metadata.field}
      {:unsupported_feature, :instructions}
  """
  @impl ALLM.SpeechAdapter
  @spec synthesize(SpeechRequest.t(), keyword()) ::
          {:ok, SpeechResponse.t()} | {:error, SpeechAdapterError.t()}
  def synthesize(%SpeechRequest{} = request, opts) when is_list(opts) do
    case SpeechSupport.fetch_speech_script(opts) do
      nil -> SpeechSupport.do_synthesize(__MODULE__, :elevenlabs, request, opts)
      _script -> FakeSpeech.synthesize(request, opts)
    end
  end

  @doc """
  Return an unfired `Req.Request` configured exactly as `synthesize/2` would
  fire it, for callers who add headers, middleware or their own retry loop.

  The pre-flight gates run first, so this is defined only for a request that
  passes them. Under `opts[:adapter_opts][:speech_script]` it returns a stub
  error instead of delegating to `ALLM.Providers.FakeSpeech`.

  ## Examples

      iex> req = ALLM.SpeechRequest.new(input: "Hi.", format: :pcm)
      iex> {:ok, http} = ALLM.Providers.ElevenLabs.Speech.prepare_request(req, api_key: "sk_x")
      iex> URI.to_string(http.url)
      "https://api.elevenlabs.io/v1/text-to-speech/JBFqnCBsd6RMkjVDRZzb?output_format=pcm_24000"
  """
  @impl ALLM.SpeechAdapter
  @spec prepare_request(SpeechRequest.t(), keyword()) ::
          {:ok, Req.Request.t()} | {:error, SpeechAdapterError.t()}
  def prepare_request(%SpeechRequest{} = request, opts) when is_list(opts) do
    case SpeechSupport.fetch_speech_script(opts) do
      nil -> SpeechSupport.prepare_request(__MODULE__, request, opts)
      _script -> {:error, SpeechSupport.stub_error(:elevenlabs, opts)}
    end
  end

  @doc """
  Stream speech for `request.input` from ElevenLabs' HTTP stream endpoint
  (`POST /v1/text-to-speech/{voice_id}/stream`) as it is synthesized.

  Returns `{:ok, enumerable}` of `ALLM.SpeechEvent` values, or
  `{:error, %ALLM.Error.SpeechAdapterError{}}` from a pre-flight gate. The
  three gates of `synthesize/2` run first, then `ALLM.Keys.fetch!/2` (which
  raises `%ALLM.Error.EngineError{reason: :missing_key}` by design). No
  HTTP request is made until the enumerable is reduced.

  **Injected defaults:** the same as `synthesize/2`: `voice` is
  `"#{@default_voice}"` and `model_id` is `"#{@default_model}"` when the
  request leaves them `nil`; `output_format` is `mp3_44100_128` for a `nil`
  format, and a `nil` `sample_rate` takes the format's default. The URL and
  JSON body are `synthesize/2`'s, with `/stream` appended to the path.

  **Options** (each read from the top level of `opts`;
  `ALLM.stream_synthesize/3` hoists an engine's `adapter_opts:` transport
  keys there):

    * `:stream_timeout` — milliseconds of silence between two transport
      messages before the stream ends with `:timeout`. Default
      #{@default_stream_timeout}.
    * `:receive_timeout`, `:request_timeout`, `:pool_timeout` — forwarded
      to `Finch.async_request/3`.
    * `:finch_name` (default `ALLM.Finch`) and `:finch_module` (default
      `Finch`; tests pass `ALLM.Test.FinchStub`).

  **Events:** `:speech_started` once the response headers arrive (`format`
  from the `content-type`, `sample_rate` the requested rate), one
  `:audio_delta` per non-empty body chunk, then `:speech_completed`, whose
  `id` is the `request-id` response header. Usage is all-`nil`. A failure
  ends the stream with one `{:error, _}`: an HTTP error status is
  classified from its body exactly as `synthesize/2` classifies it; a 200
  that is not `audio/*` is `:malformed_response`; a 200 with no audio is
  `:invalid_request` with `metadata.cause: :empty_input`; silence past
  `:stream_timeout` is `:timeout`; a transport failure is `:network_error`.

  **Halting** the stream early (`Enum.take/2`) cancels the HTTP request and
  removes its already-queued messages from the calling process's mailbox
  (best-effort: a message the request process sends while it is being shut
  down can still arrive afterwards). A stream is never retried once it has
  been returned.

  `opts[:adapter_opts][:speech_script]` hands the call to
  `ALLM.Providers.FakeSpeech.stream_synthesize/2` before any gate runs.

  ## Examples

      iex> req = ALLM.SpeechRequest.new(input: "Hello.", format: :pcm)
      iex> opts = [adapter_opts: [speech_script: [{:ok, "PCM-bytes"}]]]
      iex> {:ok, events} = ALLM.Providers.ElevenLabs.Speech.stream_synthesize(req, opts)
      iex> for {:audio_delta, bytes} <- events, into: "", do: bytes
      "PCM-bytes"

      iex> req = ALLM.SpeechRequest.new(input: "Hi.", format: :flac)
      iex> {:error, err} = ALLM.Providers.ElevenLabs.Speech.stream_synthesize(req, [])
      iex> {err.reason, err.metadata.field}
      {:unsupported_feature, :format}
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

  @doc """
  Speak text as it arrives: `input` is an enumerable of text chunks (for
  example `ALLM.AudioStream.text_deltas/1` over a chat stream), sent over
  ElevenLabs' WebSocket endpoint
  `wss://<host>/v1/text-to-speech/{voice_id}/stream-input`.

  `request.input` is ignored. Returns `{:ok, enumerable}` of
  `ALLM.SpeechEvent` values, or `{:error, %ALLM.Error.SpeechAdapterError{}}`
  from a pre-flight gate. The gates run in this order, then
  `ALLM.Keys.fetch!/2`, before the enumerable is returned:

    1. **Request shape.** `ALLM.Validate.speech_request(request, input: :streamed)`;
       a failure is `:invalid_request` with the validator's errors on
       `metadata.errors`.
    2. **Instructions** and 3. **format and sample rate**, as in
       `synthesize/2` (`:unsupported_feature`).

  No socket is opened until the enumerable is reduced. The stream then
  connects, sends the initial message, emits `:speech_started`, and only
  then starts reducing `input` (in a helper process, see
  `ALLM.Providers.Support.InputPump`), so an upgrade the server refuses
  (any status other than 101, such as the HTTP 400 for `eleven_v3`) never
  reduces the input. **A bad key or an unknown voice is not refused at the
  upgrade:** ElevenLabs answers it with 101 and rejects it afterwards with
  an error frame and a close 1008. By then `:speech_started` has been
  emitted and the pump has started, so the input may already be reduced
  (up to the pump's credit window ahead of what was sent) before the
  stream ends with `{:error, %{reason: :authentication_failed}}` (or
  `:invalid_request` for the voice). When `input` is itself a paid stream,
  such as `ALLM.AudioStream.text_deltas/1` over a chat, that request is
  issued even though the key was never valid. The stream does not wait for
  a first server frame before reducing the input, because ElevenLabs sends
  nothing until it has received text.

  **Wire.** The key goes in the upgrade request's `xi-api-key` header,
  never in the URL. The URL carries `model_id`, `output_format` and
  `inactivity_timeout` (plus `options["query"]`, merged under them). The
  initial message is `{"text": " "}` plus `voice_settings` (with `speed`)
  and any other `request.options` keys (e.g. `generation_config`). Text
  is sent as `{"text": text}` with no space appended: under `auto_mode`
  (the default) it is buffered to whole words first (see below), and with
  `auto_mode` off each non-empty chunk is sent verbatim. The end of input
  sends any buffered text, then `{"text": "", "flush": true}` and then
  `{"text": ""}`.

  **Injected defaults:** `voice` is `"#{@default_voice}"` and `model_id`
  is `"#{@default_model}"` when the request leaves them `nil`;
  `output_format` is `mp3_44100_128` for a `nil` format and a `nil`
  `sample_rate` takes the format's default; `inactivity_timeout` is
  `min(#{@max_inactivity_timeout}, ceil(stream_timeout / 1000))` seconds,
  and #{@max_inactivity_timeout} when `:stream_timeout` is `:infinity`, so
  the server does not close a slow input's socket before this stream
  would; and `auto_mode=true`, unless `options["query"]` sets `auto_mode`
  itself. When no frame has been sent for half of `inactivity_timeout`, the
  stream sends ElevenLabs' documented keep-alive, `{"text": " "}`.

  **Latency against quality: `auto_mode` plus word buffering.**
  `auto_mode=true` is the default because it produced the first audio
  sooner (238 ms against 563 ms from the first text chunk, one probe of
  the four chunks `["Hel", "lo", " world", "."]` on 2026-09-27). Under
  `auto_mode` ElevenLabs voices every text frame as it arrives: in that
  probe `"Hel"` and `"lo"` were generated as separate clips (2.1 s against
  1.0 s for the same text under the provider's default buffering), and
  ElevenLabs recommends `auto_mode` only for whole words or sentences.
  So while `auto_mode` is on, the adapter holds incoming text until a word
  boundary and sends only whole words: `["Hel", "lo", " world", "."]` goes
  out as `"Hello "` and, at the end of input, `"world."`. A boundary is
  whitespace or one of `! ? ;` and the CJK full-width marks; `.`, `,`, `:`
  and `'` are sent at the space that follows them, because they also occur
  inside words and numbers ("3.14", "don't"). `?`, `!` and `;` are
  boundaries even inside a token, so a URL's query string is split after
  its `?` (`"https://x.com/a?q=1"` goes out as `"https://x.com/a?"` then
  `"q=1"`). Whitespace includes the no-break space, so a number written
  with one ("10 000") can be split there when it straddles two chunks.
  Text with no boundary at all waits for the end of input. Buffering
  follows `auto_mode`: it is on when the query's `auto_mode` is `true` or
  a string equal to `"true"` ignoring case, and off otherwise. To turn
  both off, pass
  `options: %{"query" => %{"auto_mode" => false}}`: each chunk is then sent
  verbatim and ElevenLabs buffers by its `chunk_length_schedule` (tunable
  through
  `options: %{"generation_config" => %{"chunk_length_schedule" => [...]}}`),
  so the first audio waits for that schedule or the end of input.

  **Options:** `:stream_timeout` (default #{@default_stream_timeout}) is the
  silence allowed between two messages, where both a server frame and an
  input chunk count, so a slow input does not time out a socket whose
  server is waiting for text. `:connect_timeout` bounds the upgrade.
  `:ws_module` is the `ALLM.Providers.Support.WebSocket` implementation
  (default `ALLM.Providers.Support.WebSocket.Mint`).
  `adapter_opts[:input_window]` is the input pump's credit window (default
  8).

  **Events and failures:** `:speech_started` (format, MIME type and sample
  rate from the requested `output_format`), one `:audio_delta` per server
  audio frame, and `:speech_completed` on the server's `isFinal`. A failure
  ends the stream with one `{:error, _}`, `:invalid_request` for the input
  rules of `ALLM.SpeechStreamAdapter` (`metadata.cause` `:invalid_input_chunk`,
  `:empty_input`, `:input_raised` or `:input_crashed`), a classified server
  error frame (an invalid or missing key is `:authentication_failed`, an
  unknown voice `:invalid_request`), `:network_error` for a transport
  failure or a close before `isFinal`, and `:timeout`.

  **Halting** the stream closes the socket, stops the input pump, and
  removes the socket's and the pump's pending messages from the calling
  process's mailbox.

  `opts[:adapter_opts][:speech_script]` hands the call to
  `ALLM.Providers.FakeSpeech.stream_synthesize_input/3` before any gate
  runs.

  ## Examples

      iex> req = ALLM.SpeechRequest.new(input: "", format: :pcm)
      iex> opts = [adapter_opts: [speech_script: [{:ok, "PCM-bytes"}]]]
      iex> {:ok, events} = ALLM.Providers.ElevenLabs.Speech.stream_synthesize_input(req, ["Hel", "lo."], opts)
      iex> for {:audio_delta, bytes} <- events, into: "", do: bytes
      "PCM-bytes"

      iex> req = ALLM.SpeechRequest.new(input: "", instructions: "Whisper.")
      iex> {:error, err} = ALLM.Providers.ElevenLabs.Speech.stream_synthesize_input(req, ["Hi."], [])
      iex> {err.reason, err.metadata.field}
      {:unsupported_feature, :instructions}
  """
  @impl ALLM.SpeechStreamAdapter
  @spec stream_synthesize_input(SpeechRequest.t(), Enumerable.t(String.t()), keyword()) ::
          {:ok, Enumerable.t(SpeechEvent.t())} | {:error, SpeechAdapterError.t()}
  def stream_synthesize_input(%SpeechRequest{} = request, input, opts) when is_list(opts) do
    case SpeechSupport.fetch_speech_script(opts) do
      nil -> do_stream_synthesize_input(request, input, opts)
      _script -> FakeSpeech.stream_synthesize_input(request, input, opts)
    end
  end

  # ---------------------------------------------------------------------------
  # Public testing seams (`@doc false` + `@spec`).
  #
  # Names align with `ALLM.Providers.OpenAI.Speech`: `to_json_body/2` returns
  # a bare `map()`, `decode_response/4` takes `(body, headers, request, opts)`
  # and the error funnel is `to_speech_adapter_error/4`. `url/2` is new
  # because ElevenLabs puts the voice and the output format in the URL.
  # Classification, redaction and the format table live in
  # `ALLM.Providers.Support.ElevenLabs`, shared with the transcription
  # adapter. The speech contract (Fake hand-off, input-shape gate, retry
  # loop, transport errors) is `ALLM.Providers.Support.SpeechAdapter`'s, shared
  # with `ALLM.Providers.OpenAI.Speech`; the `@impl` functions are the
  # callbacks it invokes on this module. The HTTP helpers are `ALLM.Providers.Support.HTTPResponse`'s,
  # with the same choices as the OpenAI sibling: binary error bodies are
  # JSON-decoded, and `apply_receive_timeout/3` always applies a timeout.
  # ---------------------------------------------------------------------------

  @doc false
  # Adapter-injected defaults: the voice "JBFqnCBsd6RMkjVDRZzb" when nil,
  # and `output_format` from `Support.ElevenLabs.output_format/2` (mp3_44100_128
  # for a nil format; the format's default rate for a nil `sample_rate`). The
  # public `synthesize/2` doc states both. `options["query"]` (a map) merges
  # UNDER `output_format`. Assumes the request passed the gates; an
  # unsupported format raises here.
  @spec url(SpeechRequest.t(), keyword()) :: String.t()
  def url(%SpeechRequest{} = request, opts),
    do: build_url(Support.base_url(opts), request, "", %{}, %{})

  @doc false
  # The HTTP stream URL: `url/2` with `/stream` after the voice, so the same
  # injected voice and `output_format` defaults apply.
  @spec stream_url(SpeechRequest.t(), keyword()) :: String.t()
  def stream_url(%SpeechRequest{} = request, opts),
    do: build_url(Support.base_url(opts), request, "/stream", %{}, %{})

  @doc false
  # The `/stream-input` WebSocket URL. The scheme follows the base URL
  # (`https` becomes `wss`, `http` becomes `ws`). Adapter-injected defaults:
  # the voice "JBFqnCBsd6RMkjVDRZzb" when nil, `model_id` "eleven_flash_v2_5"
  # when nil, `output_format` as in `url/2`, and `inactivity_timeout`
  # derived from `opts[:stream_timeout]` (`inactivity_timeout/1`), all
  # structural (`options["query"]` merges UNDER them); and `auto_mode=true`,
  # a default that `options["query"]["auto_mode"]` replaces (the lower
  # first-audio latency of the 2026-09-27 probe). The public
  # `stream_synthesize_input/3` doc states each. The API key is never part
  # of it.
  @spec ws_url(SpeechRequest.t(), keyword()) :: String.t()
  def ws_url(%SpeechRequest{} = request, opts) do
    structural = %{
      "model_id" => request.model || @default_model,
      "inactivity_timeout" =>
        Integer.to_string(
          inactivity_timeout(Keyword.get(opts, :stream_timeout, @default_stream_timeout))
        )
    }

    opts
    |> Support.ws_base_url()
    |> build_url(request, "/stream-input", structural, @ws_query_defaults)
  end

  @doc false
  # Seconds of client silence after which ElevenLabs closes a
  # `/stream-input` socket: `ceil(stream_timeout / 1000)`, capped at 180,
  # the documented maximum, and 180 for `:infinity`.
  @spec inactivity_timeout(timeout()) :: pos_integer()
  def inactivity_timeout(:infinity), do: @max_inactivity_timeout

  def inactivity_timeout(ms) when is_integer(ms) and ms > 0,
    do: min(@max_inactivity_timeout, div(ms + 999, 1000))

  # `defaults` sit under `options["query"]`, `structural` over it.
  defp build_url(base, %SpeechRequest{} = request, suffix, structural, defaults) do
    {:ok, %{output_format: output_format}} =
      Support.output_format(request.format, request.sample_rate)

    query =
      defaults
      |> Map.merge(user_query(request))
      |> Map.merge(structural)
      |> Map.put("output_format", output_format)

    base <>
      @endpoint <>
      URI.encode(request.voice || @default_voice, &URI.char_unreserved?/1) <>
      suffix <> "?" <> URI.encode_query(query)
  end

  @doc false
  # Adapter-injected default: `model_id` "eleven_flash_v2_5" when nil (the
  # public `synthesize/2` doc states it). `speed` is sent as
  # `voice_settings.speed`; a nil `speed` sends no `voice_settings` unless
  # `options` carries one. `request.options` merges UNDER `text` and
  # `model_id`, and an options `"voice_settings"` map is merged with `speed`
  # (speed wins). The reserved `output_format`, `model_id` and `text` option
  # keys are dropped, and `query` goes to the URL instead.
  @spec to_json_body(SpeechRequest.t(), keyword()) :: map()
  def to_json_body(%SpeechRequest{} = request, _opts) do
    options =
      request.options
      |> SpeechSupport.stringify_keys()
      |> Map.delete("query")
      |> SpeechSupport.drop_reserved_options(
        @reserved_options,
        __MODULE__,
        "the adapter sets them from the request."
      )

    voice_settings =
      options
      |> Map.get("voice_settings")
      |> case do
        settings when is_map(settings) -> SpeechSupport.stringify_keys(settings)
        _ -> %{}
      end
      |> SpeechSupport.put_present("speed", request.speed)

    options
    |> Map.delete("voice_settings")
    |> Map.merge(%{"text" => request.input, "model_id" => request.model || @default_model})
    |> put_nonempty("voice_settings", voice_settings)
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
         sample_rate: requested_sample_rate(request),
         id: HTTPResponse.header_value(headers, "request-id"),
         request_id: Keyword.get(opts, :request_id),
         model: request.model || @default_model,
         provider: :elevenlabs,
         usage: %Usage{},
         raw: character_cost(headers),
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
  # `body` may be a decoded map or an undecoded JSON binary.
  @impl SpeechSupport
  @spec to_speech_adapter_error(non_neg_integer(), term(), Enumerable.t() | map(), keyword()) ::
          SpeechAdapterError.t()
  def to_speech_adapter_error(status, body, headers, opts) when is_integer(status) do
    {reason, fields} = Support.error_fields(status, body, headers, opts)
    SpeechAdapterError.new(reason, fields)
  end

  # ---------------------------------------------------------------------------
  # Internals — gates and request building
  # ---------------------------------------------------------------------------

  @doc false
  # All three gates run ahead of `Keys.fetch!/2`. `url/2` and
  # `requested_sample_rate/1` resolve the output format from the same fields.
  @impl SpeechSupport
  @spec run_gates(SpeechRequest.t(), keyword()) :: :ok | {:error, SpeechAdapterError.t()}
  def run_gates(%SpeechRequest{} = request, opts) do
    with :ok <- SpeechSupport.gate_input_shape(request, :elevenlabs, opts),
         :ok <- gate_instructions(request, opts) do
      gate_output_format(request, opts)
    end
  end

  defp gate_instructions(%SpeechRequest{instructions: nil}, _opts), do: :ok

  defp gate_instructions(%SpeechRequest{}, opts) do
    unsupported(
      "ElevenLabs has no instructions field; steer delivery with the voice and voice_settings",
      %{field: :instructions},
      opts
    )
  end

  defp gate_output_format(%SpeechRequest{format: format, sample_rate: rate}, opts) do
    case Support.output_format(format, rate) do
      {:ok, _output} ->
        :ok

      {:error, {:format, _}} ->
        unsupported(
          "ElevenLabs cannot produce format #{inspect(format)}",
          %{field: :format, format: format},
          opts
        )

      {:error, {:sample_rate, accepted}} ->
        unsupported(
          "ElevenLabs cannot produce sample_rate #{inspect(rate)} for format " <>
            "#{inspect(format || :mp3)}; it accepts nil or one of #{inspect(accepted)}",
          %{field: :sample_rate, sample_rate: rate, format: format},
          opts
        )
    end
  end

  defp unsupported(message, metadata, opts) do
    {:error,
     SpeechAdapterError.new(:unsupported_feature,
       provider: :elevenlabs,
       message: message,
       metadata: HTTPResponse.build_metadata(metadata, opts)
     )}
  end

  @doc false
  # `Keys.fetch!/2` raises `%EngineError{reason: :missing_key}` by documented
  # design and is not rescued. It runs AFTER `run_gates/2`.
  @impl SpeechSupport
  @spec build_request(SpeechRequest.t(), keyword()) :: {:ok, Req.Request.t()}
  def build_request(%SpeechRequest{} = request, opts) do
    api_key = Keys.fetch!(:elevenlabs, opts)

    req =
      Req.new(
        method: :post,
        url: url(request, opts),
        headers: Support.headers(api_key),
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
  # Internals — HTTP streaming
  #
  # The `Stream.resource/3` state machine over `Finch.async_request/3` is
  # `Support.SpeechAdapter.stream_resource/6`; this module supplies the
  # request and the three streaming callbacks below.
  # ---------------------------------------------------------------------------

  defp do_stream_synthesize(%SpeechRequest{} = request, opts) do
    with :ok <- run_gates(request, opts) do
      api_key = Keys.fetch!(:elevenlabs, opts)

      finch_request =
        Finch.build(
          :post,
          stream_url(request, opts),
          Support.headers(api_key) ++ [{"content-type", "application/json"}],
          Jason.encode!(to_json_body(request, opts))
        )

      {:ok,
       SpeechSupport.stream_resource(
         __MODULE__,
         :elevenlabs,
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
  def speech_started(content_type, _headers, %SpeechRequest{} = request, opts) do
    format = SpeechResponse.mime_to_format(content_type)

    SpeechEvent.speech_started(%{
      request_id: Keyword.get(opts, :request_id),
      model: request.model || @default_model,
      provider: :elevenlabs,
      format: format,
      mime_type: if(format, do: SpeechResponse.format_to_mime(format), else: content_type),
      sample_rate: requested_sample_rate(request)
    })
  end

  @doc false
  @impl SpeechSupport
  @spec speech_completed(Enumerable.t() | map(), SpeechRequest.t(), keyword()) ::
          SpeechEvent.t()
  def speech_completed(headers, %SpeechRequest{} = request, opts) do
    SpeechEvent.speech_completed(%{
      request_id: Keyword.get(opts, :request_id),
      id: HTTPResponse.header_value(headers, "request-id"),
      usage: %Usage{},
      metadata: request.metadata
    })
  end

  @doc false
  @impl SpeechSupport
  @spec empty_audio_error(keyword()) :: SpeechAdapterError.t()
  def empty_audio_error(opts),
    do:
      stream_error(
        :invalid_request,
        "ElevenLabs ended the stream without any audio bytes",
        %{cause: :empty_input},
        opts
      )

  # ---------------------------------------------------------------------------
  # Internals — WebSocket input streaming
  #
  # One `Stream.resource/3` whose three functions run in the reducing
  # process, which therefore owns the socket. The start function connects,
  # sends the initial message and only then starts the input pump. The next
  # function selects pump messages and this socket's transport messages
  # (never anything else in the mailbox); every one of them resets the
  # silence timer, and a keep-alive is sent when no client frame has gone
  # out for half of `inactivity_timeout`. The after function closes the
  # socket, drains its messages and stops the pump.
  # ---------------------------------------------------------------------------

  defp do_stream_synthesize_input(%SpeechRequest{} = request, input, opts) do
    with :ok <- gate_streamed_request(request, opts),
         :ok <- gate_instructions(request, opts),
         :ok <- gate_output_format(request, opts) do
      api_key = Keys.fetch!(:elevenlabs, opts)

      {:ok,
       Stream.resource(
         fn -> open_input_stream(request, input, api_key, opts) end,
         &input_next/1,
         &InputLoop.close_loop/1
       )}
    end
  end

  defp gate_streamed_request(%SpeechRequest{} = request, opts) do
    case Validate.speech_request(request, input: :streamed) do
      :ok ->
        :ok

      {:error, %ValidationError{errors: errors}} ->
        {:error,
         SpeechAdapterError.new(:invalid_request,
           provider: :elevenlabs,
           message: "invalid speech request: #{inspect(errors)}",
           metadata: HTTPResponse.build_metadata(%{errors: errors}, opts)
         )}
    end
  end

  defp open_input_stream(request, input, api_key, opts) do
    ws = Keyword.get(opts, :ws_module, ALLM.Providers.Support.WebSocket.Mint)
    stream_timeout = Keyword.get(opts, :stream_timeout, @default_stream_timeout)

    state =
      ws
      |> InputLoop.loop_state(stream_timeout, div(inactivity_timeout(stream_timeout) * 1000, 2))
      |> Map.merge(%{
        request: request,
        opts: opts,
        pending: [],
        spoke?: false,
        word_buffer: if(auto_mode?(request), do: "", else: nil),
        bytes: 0,
        done?: false
      })

    with {:ok, conn} <- connect(ws, request, api_key, opts),
         state = %{state | conn: conn},
         {:ok, state} <- send_json(state, init_message(request, opts)) do
      %{InputLoop.start_pump(state, input, opts) | pending: [ws_started_event(request, opts)]}
    else
      {:error, %SpeechAdapterError{} = error} ->
        %{state | pending: [{:error, error}], done?: true}

      {:error, state, %SpeechAdapterError{} = error} ->
        %{state | pending: [{:error, error}], done?: true}
    end
  end

  defp connect(ws, request, api_key, opts) do
    case ws.connect(ws_url(request, opts), Support.headers(api_key), opts) do
      {:ok, conn} ->
        {:ok, conn}

      {:error, {:upgrade_status, status, body}} ->
        {reason, fields} = Support.error_fields(status, body, [], opts)
        {:error, SpeechAdapterError.new(reason, fields)}

      {:error, {:transport, cause}} ->
        {:error, transport_failure("WebSocket connect failed", cause, opts)}
    end
  end

  @doc false
  # The first message on `/stream-input`: `{"text": " "}` plus the same
  # `voice_settings` (with `speed`) and `request.options` keys the HTTP body
  # carries. `model_id` goes in the URL instead.
  @spec init_message(SpeechRequest.t(), keyword()) :: map()
  def init_message(%SpeechRequest{} = request, opts) do
    request
    |> to_json_body(opts)
    |> Map.delete("model_id")
    |> Map.put("text", " ")
  end

  defp input_next(%{pending: [_ | _] = pending} = state), do: {pending, %{state | pending: []}}
  defp input_next(%{done?: true} = state), do: {:halt, state}

  # Selects only this stream's messages: the pump's (while it runs) and the
  # socket's.
  defp input_next(state) do
    case InputLoop.next_message(state) do
      {:pump, classified, state} -> on_pump(classified, state)
      {:transport, message, state} -> on_transport(message, state)
      :wake -> on_wake(state)
    end
  end

  defp on_wake(state) do
    if InputLoop.timed_out?(state) do
      finish(
        state,
        stream_error(
          :timeout,
          "no server frame or input chunk within stream_timeout (#{state.stream_timeout} ms)",
          %{},
          state.opts
        )
      )
    else
      # ElevenLabs' documented keep-alive: a single space.
      emit(send_json(state, %{"text" => " "}))
    end
  end

  defp on_pump({:input, chunk}, %{pump: {pid, ref}} = state) do
    InputPump.ack(pid, ref)
    on_chunk(chunk, state)
  end

  defp on_pump(:done, %{spoke?: false} = state) do
    finish(InputLoop.stop_pump(state), empty_input_error(state.opts))
  end

  defp on_pump(:done, state) do
    state = %{InputLoop.stop_pump(state) | input_done?: true}

    with {:ok, state} <- flush_word_buffer(state),
         {:ok, state} <- send_json(state, %{"text" => "", "flush" => true}) do
      emit(send_json(state, %{"text" => ""}))
    else
      failed -> emit(failed)
    end
  end

  defp on_pump({:failed, cause, info}, state) do
    error =
      SpeechAdapterError.new(:invalid_request,
        provider: :elevenlabs,
        message: "the input stream failed: #{info.message}",
        cause: info,
        metadata: HTTPResponse.build_metadata(%{cause: cause}, state.opts)
      )

    finish(InputLoop.stop_pump(state), error)
  end

  defp on_chunk("", state), do: {[], state}

  defp on_chunk(chunk, state) when is_binary(chunk) do
    if String.valid?(chunk) do
      speak(%{state | spoke?: true}, chunk)
    else
      finish(state, invalid_chunk_error(state.opts))
    end
  end

  defp on_chunk(_chunk, state), do: finish(state, invalid_chunk_error(state.opts))

  # Without `auto_mode` (`word_buffer: nil`) each chunk goes out verbatim
  # and ElevenLabs' `chunk_length_schedule` does the buffering. With it,
  # ElevenLabs voices every text frame as it arrives, so the text is held
  # until a word boundary (see `split_at_word_boundary/1`) and only whole
  # words are sent; the remainder is sent at the end of input.
  defp speak(%{word_buffer: nil} = state, chunk), do: emit(send_json(state, %{"text" => chunk}))

  defp speak(state, chunk) do
    case buffer_words(state.word_buffer, chunk) do
      {"", buffer} -> {[], %{state | word_buffer: buffer}}
      {words, buffer} -> emit(send_json(%{state | word_buffer: buffer}, %{"text" => words}))
    end
  end

  @doc false
  # `split_at_word_boundary(buffer <> chunk)`, scanning only `chunk`. The
  # buffer holds no boundary by construction (it is always the `rest` of a
  # split, or `""`), and every boundary is one codepoint, so the last
  # boundary of `buffer <> chunk` is `chunk`'s own. Rescanning the buffer
  # would make a long boundary-free run cost O(n²) across its chunks.
  @spec buffer_words(String.t(), String.t()) :: {String.t(), String.t()}
  def buffer_words(buffer, chunk) when is_binary(buffer) and is_binary(chunk) do
    case split_at_word_boundary(chunk) do
      {"", rest} -> {"", buffer <> rest}
      {words, rest} -> {buffer <> words, rest}
    end
  end

  defp flush_word_buffer(%{word_buffer: buffer} = state) when buffer in [nil, ""], do: {:ok, state}

  defp flush_word_buffer(state),
    do: send_json(%{state | word_buffer: ""}, %{"text" => state.word_buffer})

  @doc false
  # Splits `text` after its last word boundary: `{words, rest}`, where
  # `words` ends at a boundary (or is `""`) and `rest` is the unfinished
  # word. A boundary is Unicode whitespace (NBSP included, so "10 000"
  # can split at a chunk end) or one of `! ? ;` and the CJK full-width
  # marks `。 、 ， ！ ？ ； ：` and `…`. `.`, `,`, `:`, `'` and `-` are not
  # boundaries on their own, because they occur inside words and numbers
  # ("3.14", "1,000", "10:30", "don't"); followed by a space they are sent
  # at the space. `? ! ;` split even inside a token, so a URL's query
  # string splits after its `?`: kept, and documented, because "Really?"
  # at a chunk end should go out at once.
  @spec split_at_word_boundary(String.t()) :: {String.t(), String.t()}
  def split_at_word_boundary(text) when is_binary(text) do
    # Greedy `.*` puts the split after the LAST boundary.
    case Regex.run(~r/\A(.*[\s!?;。、，！？；：…])(.*)\z/su, text, capture: :all_but_first) do
      [words, rest] -> {words, rest}
      nil -> {"", text}
    end
  end

  # Case-insensitive, so a `"True"` the server may read as true never goes
  # out unbuffered: buffering under auto_mode off only costs latency.
  defp auto_mode?(%SpeechRequest{} = request) do
    @ws_query_defaults
    |> Map.merge(user_query(request))
    |> Map.get("auto_mode")
    |> to_string()
    |> String.downcase() == "true"
  end

  # `options["query"]` as query parameters, minus `output_format` (the
  # adapter derives it from `:format`).
  defp user_query(%SpeechRequest{options: options}) do
    options
    |> SpeechSupport.stringify_keys()
    |> Map.get("query")
    |> Support.query_params(["output_format"])
  end

  defp on_transport(message, state) do
    case InputLoop.handle_transport(state, message) do
      {:ok, state, frames} ->
        on_frames(frames, state, [])

      :unknown ->
        {[], state}

      {:error, state, cause} ->
        finish(state, transport_failure("WebSocket transport failed", cause, state.opts))
    end
  end

  # Each frame yields `{:cont, events, state}` or, for a terminal,
  # `{:halt, events, state}` whose last event is the terminal one.
  defp on_frames([], state, acc), do: {acc, state}

  defp on_frames([frame | rest], state, acc) do
    case on_frame(frame, state) do
      {:cont, events, state} -> on_frames(rest, state, acc ++ events)
      {:halt, events, state} -> {acc ++ events, %{state | done?: true}}
    end
  end

  defp on_frame({:text, json}, state) do
    case Jason.decode(json) do
      {:ok, %{} = payload} -> on_payload(payload, state)
      _ -> halt_error(state, malformed_error("server frame is not a JSON object", state.opts))
    end
  end

  defp on_frame({:close, code, reason}, state) do
    {error_reason, fields} = Support.ws_error_fields(%{"message" => reason}, code, state.opts)
    halt_error(state, SpeechAdapterError.new(closed_reason(error_reason), fields))
  end

  defp on_frame(:closed, state) do
    halt_error(
      state,
      stream_error(
        :network_error,
        "ElevenLabs closed the connection before isFinal",
        %{},
        state.opts
      )
    )
  end

  defp on_frame(_binary, state), do: {:cont, [], state}

  # A close before `isFinal`: an orderly 1000 still means the clip was cut
  # short.
  defp closed_reason(:unknown), do: :network_error
  defp closed_reason(reason), do: reason

  defp on_payload(payload, state) do
    if Support.ws_error?(payload) do
      {reason, fields} = Support.ws_error_fields(payload, nil, state.opts)
      halt_error(state, SpeechAdapterError.new(reason, fields))
    else
      on_audio_payload(payload, state)
    end
  end

  defp on_audio_payload(payload, state) do
    case audio_events(Map.get(payload, "audio"), state) do
      {:ok, events, state} ->
        if Map.get(payload, "isFinal") == true,
          do: final(events, state),
          else: {:cont, events, state}

      {:error, error} ->
        halt_error(state, error)
    end
  end

  defp audio_events(audio, state) when audio in [nil, ""], do: {:ok, [], state}

  defp audio_events(audio, state) when is_binary(audio) do
    case Base.decode64(audio) do
      {:ok, bytes} ->
        {:ok, [SpeechEvent.audio_delta(bytes)], %{state | bytes: state.bytes + byte_size(bytes)}}

      :error ->
        {:error, malformed_error("audio is not base64", state.opts)}
    end
  end

  defp audio_events(_audio, state),
    do: {:error, malformed_error("audio is not a string", state.opts)}

  # `isFinal` ends the clip. With no audio at all the grammar's empty-input
  # rule applies, as on the HTTP stream.
  defp final(_events, %{bytes: 0} = state), do: halt_error(state, empty_audio_error(state.opts))

  defp final(events, state) do
    completed =
      SpeechEvent.speech_completed(%{
        request_id: Keyword.get(state.opts, :request_id),
        id: nil,
        usage: %Usage{},
        metadata: state.request.metadata
      })

    {:halt, events ++ [completed], state}
  end

  defp halt_error(state, %SpeechAdapterError{} = error), do: {:halt, [{:error, error}], state}

  defp send_json(state, message) do
    case InputLoop.send_json(state, message) do
      {:ok, state} ->
        {:ok, state}

      {:error, state, cause} ->
        {:error, state, transport_failure("WebSocket send failed", cause, state.opts)}
    end
  end

  defp emit({:ok, state}), do: {[], state}
  defp emit({:error, state, error}), do: finish(state, error)

  defp finish(state, %SpeechAdapterError{} = error), do: {[{:error, error}], %{state | done?: true}}

  defp ws_started_event(%SpeechRequest{} = request, opts) do
    {:ok, output} = Support.output_format(request.format, request.sample_rate)

    SpeechEvent.speech_started(%{
      request_id: Keyword.get(opts, :request_id),
      model: request.model || @default_model,
      provider: :elevenlabs,
      format: output.format,
      mime_type: output.mime_type,
      sample_rate: output.sample_rate
    })
  end

  defp empty_input_error(opts),
    do:
      stream_error(
        :invalid_request,
        "the input produced no text to speak",
        %{cause: :empty_input},
        opts
      )

  defp invalid_chunk_error(opts),
    do:
      stream_error(
        :invalid_request,
        "input chunks must be UTF-8 strings",
        %{cause: :invalid_input_chunk},
        opts
      )

  defp transport_failure(message, cause, opts) do
    SpeechAdapterError.new(:network_error,
      provider: :elevenlabs,
      message: message,
      cause: HTTPResponse.sanitize_cause(cause),
      metadata: HTTPResponse.build_metadata(%{}, opts)
    )
  end

  defp stream_error(reason, message, metadata, opts) do
    SpeechAdapterError.new(reason,
      provider: :elevenlabs,
      message: message,
      metadata: HTTPResponse.build_metadata(metadata, opts)
    )
  end

  # ---------------------------------------------------------------------------
  # Internals — body and URL builders
  # ---------------------------------------------------------------------------

  defp put_nonempty(map, _key, value) when map_size(value) == 0, do: map
  defp put_nonempty(map, key, value), do: Map.put(map, key, value)

  # ---------------------------------------------------------------------------
  # Internals — decoding and errors
  # ---------------------------------------------------------------------------

  defp requested_sample_rate(%SpeechRequest{format: format, sample_rate: rate}) do
    case Support.output_format(format, rate) do
      {:ok, %{sample_rate: resolved}} -> resolved
      {:error, _} -> nil
    end
  end

  defp character_cost(headers) do
    with value when is_binary(value) <- HTTPResponse.header_value(headers, "character-cost"),
         {n, ""} <- Integer.parse(value) do
      %{"character_cost" => n}
    else
      _ -> nil
    end
  end

  @doc false
  @impl SpeechSupport
  @spec malformed_error(String.t(), keyword()) :: SpeechAdapterError.t()
  def malformed_error(detail, opts),
    do: SpeechSupport.malformed_error(:elevenlabs, "ElevenLabs", detail, opts)

  @doc false
  @impl SpeechSupport
  @spec redact_key_material(String.t()) :: String.t()
  defdelegate redact_key_material(message), to: Support
end
