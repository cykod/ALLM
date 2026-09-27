defmodule ALLM.Providers.ElevenLabs.Transcription do
  # Attribute block sits ABOVE the @moduledoc because the moduledoc
  # interpolates these constants.

  @endpoint "/v1/speech-to-text"

  # Adapter-injected default for a nil `:model` (stated in the public
  # `transcribe/2` doc and in `to_multipart_body/2`'s `@doc false`).
  # `scribe_v1` is deprecated.
  @default_model "scribe_v2"

  # ElevenLabs documents the upload limit as "less than 5.0GB". NOT probed:
  # a GB-scale upload arm is prohibitively slow.
  @max_audio_bytes 4_999_999_999

  # Req's own `receive_timeout` default (15 s) is too short for a long clip.
  @default_timeout_ms 120_000

  @stream_endpoint "/v1/speech-to-text/realtime"

  # Adapter-injected default for a nil `:model` on the realtime path (stated
  # in the public `stream_transcribe/3` doc and in `stream_url/2`'s
  # `@doc false`). The only model the realtime endpoint accepts; the batch
  # engine model is never used here, because the two namespaces are disjoint.
  @default_stream_model "scribe_v2_realtime"

  # The `pcm_<rate>` values of the realtime `audio_format` parameter.
  @stream_sample_rates [8_000, 16_000, 22_050, 24_000, 44_100, 48_000]

  # The most audio one `input_audio_chunk` frame carries; a longer input
  # chunk is split. The 2026-09-27 probe had 1,000 ms (and, exploring,
  # 3,000 ms) chunks accepted, so this is a conservative bound, not a limit
  # the provider was seen to enforce.
  @max_chunk_ms 1_000

  @default_stream_timeout 60_000

  # The longest an opted-in segment waits for its timestamped frame (owner
  # decision 2026-09-27, "hold when requested").
  @language_hold_ms 1_000

  # The options that make ElevenLabs send `committed_transcript_with_timestamps`,
  # and so turn the language hold on.
  @hold_options ["include_timestamps", "include_language_detection"]

  # Query parameters the adapter derives from the request itself;
  # `request.options` never overrides them.
  @reserved_query ["model_id", "audio_format", "commit_strategy"]

  # Multipart field names the adapter sets itself. `request.options` never
  # overrides them.
  @structural_fields ["file", "model_id", "language_code"]

  # A non-file upload is named `audio.<ext>` from `ALLM.Audio.extension_for_mime/1`,
  # and `audio.bin` when the mime has no known extension. ElevenLabs reads the
  # content, not the name: the 2026-09-26 probe sent a valid mp3 as
  # `audio.bin` (`application/octet-stream`) and got a 200 with the right
  # transcript. So, unlike the OpenAI sibling, there is no filename gate.
  @fallback_filename "audio.bin"

  @moduledoc """
  ElevenLabs speech-to-text adapter (Scribe). Implements
  `ALLM.TranscriptionAdapter` against `POST /v1/speech-to-text` and
  `ALLM.TranscriptionStreamAdapter` against the realtime WebSocket
  `wss://<host>#{@stream_endpoint}` (see `stream_transcribe/3`).

  Layer B — runtime. Wire it with
  `ALLM.Engine.new(transcription_adapter: ALLM.Providers.ElevenLabs.Transcription)`
  and call it through `ALLM.transcribe/3`. The key resolves via
  `ALLM.Keys.fetch!(:elevenlabs, opts)` (environment variable
  `ELEVENLABS_API_KEY`) after the pre-flight gates, so no key ever lives on
  the engine.

      req = ALLM.TranscriptionRequest.new(audio: ALLM.Audio.from_file("clip.mp3"))
      {:ok, resp} = ALLM.Providers.ElevenLabs.Transcription.transcribe(req, api_key: "sk_...")
      resp.text

  ## Wire-field map

  Observed live on **2026-09-26** by
  `scripts/record_elevenlabs_audio_fixtures.exs`, whose probe halts the
  recording pass on any mismatch.

  | Concern | ElevenLabs |
  |---------|------------|
  | Endpoint | `POST <host>#{@endpoint}`, `multipart/form-data`. The host is `https://api.elevenlabs.io` unless `opts[:base_url]` or `adapter_opts[:base_url]` names another |
  | Auth | `xi-api-key: <key>` |
  | `file` | the audio bytes, named by the file's basename for a `{:file, path}` source, else `audio.<ext>` from the MIME type, else `#{@fallback_filename}`. ElevenLabs detects the format from the content |
  | `model_id` | `:model`, or `#{@default_model}` when `nil` |
  | `language_code` | `:language`, sent when set |
  | `prompt` | ElevenLabs has no such field; refused (see gates) |
  | Options | each `ALLM.TranscriptionRequest.options` entry becomes one form field (a list becomes one field per element); never overrides the fields above |
  | Response | `{"text", "language_code", "language_probability", "audio_duration_secs", "transcription_id", "words"}` |
  | Language | `language_code` → `:language`, as ElevenLabs reports it: an ISO 639-3 code such as `"eng"` |
  | Duration | `audio_duration_secs` → `:duration_seconds` |
  | Correlation | `transcription_id` → `:id`. The response carries no `request-id` header |
  | Usage | **none**: the body has no billing field, so `:usage` is an all-`nil` `%ALLM.Usage{}` |
  | Size limit | documented as less than 5.0 GB; see `max_audio_bytes/0` |
  | Unknown fields | **ignored** (200), so a mistyped `:options` key does nothing and raises no error |

  ## Adapter-injected defaults

    * `model_id` defaults to `"#{@default_model}"` when `:model` is `nil`.
    * The HTTP receive timeout defaults to #{div(@default_timeout_ms, 1000)} s
      when `opts[:request_timeout]` is absent.

  ## Pre-flight gates

  In this order, before any HTTP I/O and before `ALLM.Keys.fetch!/2`:

    1. **Resolvable.** Audio whose bytes cannot be resolved (a missing file,
       a directory, invalid base64, an off-shape source, or an `:audio` that
       is not an `%ALLM.Audio{}`) → `:invalid_request` with
       `metadata.cause` and `metadata.field: :audio`.
    2. **Size.** More than `max_audio_bytes/0` bytes → `:invalid_request`
       with `metadata.count` and `metadata.max`. A `{:file, path}` source is
       measured with a stat, never read.
    3. **Prompt.** A non-`nil` `:prompt` → `:unsupported_feature` with
       `metadata.field: :prompt`.

  ## Response

  `:text` is the transcript. `:raw` is the provider body, including its
  `words` list. `:model` is the model that was sent. `opts[:request_id]` is
  reflected onto `response.request_id`, and `request.metadata` round-trips
  onto `response.metadata`.

  ## No retries

  This adapter makes **one** HTTP attempt per call and returns every
  classified error, retryable or not, as `{:error, _}`. Each attempt
  re-uploads the whole clip, so the only retry loop is `ALLM.transcribe/3`'s.
  A direct `transcribe/2` caller who wants retries wraps the call.

  ## Error-struct hygiene

  No raw response body, request header or `xi-api-key` value is copied into
  `%ALLM.Error.TranscriptionAdapterError{}`. The provider's message and its
  `detail.code`, `detail.type` and `detail.status` pass a redactor that
  replaces ElevenLabs-shaped keys (`sk_…`) with `[REDACTED]`. Classification
  is shared with `ALLM.Providers.ElevenLabs.Speech`.

  ## Test-injection escape hatch

  `transcribe/2` honours `opts[:adapter_opts][:transcription_script]`: when
  the key is present, the call is handed to
  `ALLM.Providers.FakeTranscription.transcribe/2` BEFORE any of this
  adapter's gates run, with `adapter_opts[:max_audio_bytes]` set to this
  adapter's own `max_audio_bytes/0`. `prepare_request/2` returns a stub
  error under the same key. `stream_transcribe/3` hands off to
  `ALLM.Providers.FakeTranscription.stream_transcribe/3` the same way, with
  `adapter_opts[:stream_sample_rates]` set to `stream_sample_rates/0`.
  """

  @behaviour ALLM.TranscriptionAdapter
  @behaviour ALLM.TranscriptionStreamAdapter
  @behaviour ALLM.Providers.Support.TranscriptionAdapter

  require Logger

  alias ALLM.{
    Audio,
    Keys,
    TranscriptionEvent,
    TranscriptionRequest,
    TranscriptionResponse,
    TranscriptionStreamRequest,
    Usage,
    Validate
  }

  alias ALLM.Error.{TranscriptionAdapterError, ValidationError}
  alias ALLM.Providers.FakeTranscription
  alias ALLM.Providers.Support.ElevenLabs, as: Support
  alias ALLM.Providers.Support.{HTTPResponse, InputPump}
  alias ALLM.Providers.Support.TranscriptionAdapter, as: TranscriptionSupport
  alias ALLM.Providers.Support.WebSocket.InputLoop

  @doc """
  Return the largest audio clip, in bytes, this adapter will upload.

  ElevenLabs documents the limit as "less than 5.0GB". This value was not
  probed. The upload goes through `Req`'s multipart step, which holds the
  whole clip in memory, so a clip near the cap needs that much free memory.

  ## Examples

      iex> ALLM.Providers.ElevenLabs.Transcription.max_audio_bytes()
      4_999_999_999
  """
  @impl ALLM.TranscriptionAdapter
  @spec max_audio_bytes() :: pos_integer()
  def max_audio_bytes, do: @max_audio_bytes

  @doc """
  Transcribe `request.audio` against ElevenLabs.

  Returns `{:ok, %ALLM.TranscriptionResponse{}}` or
  `{:error, %ALLM.Error.TranscriptionAdapterError{}}`. The one exception is
  `ALLM.Keys.fetch!/2`, which raises `%ALLM.Error.EngineError{reason: :missing_key}`
  by design; every pre-flight gate runs ahead of it.

  **Injected defaults:** `model_id` is `"#{@default_model}"` when the request
  leaves `:model` `nil`, and the receive timeout is
  #{div(@default_timeout_ms, 1000)} s when `opts[:request_timeout]` is absent.

  **Refused before any I/O** with `:unsupported_feature`: a non-`nil`
  `:prompt` (ElevenLabs has no prompt field).

  **No retries:** one HTTP attempt per call, whatever the error.

  ## Examples

      iex> audio = ALLM.Audio.from_binary("ID3", "audio/mpeg")
      iex> req = ALLM.TranscriptionRequest.new(audio: audio)
      iex> opts = [adapter_opts: [transcription_script: [{:ok, "hello"}]]]
      iex> {:ok, resp} = ALLM.Providers.ElevenLabs.Transcription.transcribe(req, opts)
      iex> resp.text
      "hello"

      iex> audio = ALLM.Audio.from_binary("ID3", "audio/mpeg")
      iex> req = ALLM.TranscriptionRequest.new(audio: audio, prompt: "names: Ada")
      iex> {:error, err} = ALLM.Providers.ElevenLabs.Transcription.transcribe(req, [])
      iex> {err.reason, err.metadata.field}
      {:unsupported_feature, :prompt}
  """
  @impl ALLM.TranscriptionAdapter
  @spec transcribe(TranscriptionRequest.t(), keyword()) ::
          {:ok, TranscriptionResponse.t()} | {:error, TranscriptionAdapterError.t()}
  def transcribe(%TranscriptionRequest{} = request, opts) when is_list(opts) do
    case TranscriptionSupport.fetch_transcription_script(opts) do
      nil ->
        TranscriptionSupport.do_transcribe(__MODULE__, :elevenlabs, request, opts)

      _script ->
        FakeTranscription.transcribe(
          request,
          TranscriptionSupport.with_own_cap(opts, @max_audio_bytes)
        )
    end
  end

  @doc """
  Return an unfired `Req.Request` configured exactly as `transcribe/2` would
  fire it.

  The pre-flight gates run first, so this is defined only for a request that
  passes them. Under `opts[:adapter_opts][:transcription_script]` it returns
  a stub error instead of delegating.

  ## Examples

      iex> req = ALLM.TranscriptionRequest.new(audio: ALLM.Audio.from_binary("ID3", "audio/mpeg"))
      iex> {:ok, http} = ALLM.Providers.ElevenLabs.Transcription.prepare_request(req, api_key: "sk_x")
      iex> URI.to_string(http.url)
      "https://api.elevenlabs.io/v1/speech-to-text"
  """
  @impl ALLM.TranscriptionAdapter
  @spec prepare_request(TranscriptionRequest.t(), keyword()) ::
          {:ok, Req.Request.t()} | {:error, TranscriptionAdapterError.t()}
  def prepare_request(%TranscriptionRequest{} = request, opts) when is_list(opts) do
    case TranscriptionSupport.fetch_transcription_script(opts) do
      nil -> with :ok <- gate_audio(request, opts), do: build_request(request, opts)
      _script -> {:error, TranscriptionSupport.stub_error(:elevenlabs, opts)}
    end
  end

  @doc """
  Return the PCM sample rates, in Hz, `stream_transcribe/3` accepts: the
  `pcm_<rate>` values of ElevenLabs' realtime `audio_format` parameter.

  ## Examples

      iex> ALLM.Providers.ElevenLabs.Transcription.stream_sample_rates()
      [8_000, 16_000, 22_050, 24_000, 44_100, 48_000]
  """
  @impl ALLM.TranscriptionStreamAdapter
  @spec stream_sample_rates() :: [pos_integer()]
  def stream_sample_rates, do: @stream_sample_rates

  @doc """
  Transcribe PCM audio as it arrives, over ElevenLabs' realtime WebSocket
  `wss://<host>#{@stream_endpoint}`.

  `input` is an enumerable of PCM16 little-endian mono binaries at
  `request.sample_rate`, and `:commit` markers. Returns `{:ok, enumerable}`
  of `ALLM.TranscriptionEvent` values, or
  `{:error, %ALLM.Error.TranscriptionAdapterError{}}` from a pre-flight
  gate. The gates run in this order, then `ALLM.Keys.fetch!/2`, before the
  enumerable is returned:

    1. **Request shape.** `ALLM.Validate.transcription_stream_request/1`; a
       failure is `:invalid_request` with the validator's errors on
       `metadata.errors`.
    2. **Sample rate.** `request.sample_rate` must be in
       `stream_sample_rates/0`, else `:invalid_request` with
       `metadata.sample_rate`.
    3. **Language hold.** `adapter_opts[:language_hold_ms]` must be a
       positive integer (milliseconds), else `:invalid_request` with
       `metadata.field: :language_hold_ms`. Checked whether or not the
       request opts in to the hold.

  No socket is opened until the enumerable is reduced. The stream then
  connects, waits for the server's `session_started` (emitted as
  `:transcription_started`, `session_id` included), and only then starts
  reducing `input` in a helper process (see
  `ALLM.Providers.Support.InputPump`). A bad key is not refused at the
  upgrade: ElevenLabs answers 101 and then an `auth_error` frame, which
  ends the stream with `:authentication_failed` before the input is
  reduced.

  **Model resolution.** `model_id` is `request.model`, else
  `"#{@default_stream_model}"`, the only model the realtime endpoint
  accepts. The engine's `transcription_model` is never used here: the
  batch and realtime model names are disjoint.

  **Wire.** The key goes in the upgrade request's `xi-api-key` header, never
  in the URL. The URL carries `model_id`, `audio_format` (`pcm_<rate>`),
  `commit_strategy` (`vad` or `manual`) and `language_code` (when
  `request.language` is set), plus every `request.options` entry as a
  further query parameter (for example `%{"include_timestamps" => true}`);
  an option named `model_id`, `audio_format` or `commit_strategy` is
  dropped. Audio goes out as
  `{"message_type": "input_audio_chunk", "audio_base_64": …, "commit": false, "sample_rate": rate}`,
  one frame per input chunk and at most #{@max_chunk_ms} ms of audio per
  frame (a longer chunk is split). **Chunk boundaries are the caller's:** a
  chunk may end mid-sample, and the odd byte is carried into the next one,
  so only whole samples are sent. `:commit` sends an empty-audio frame with
  `"commit": true`.

  **End of input.** When `input` is exhausted, audio sent since the last
  commit is committed, and the stream waits (up to `:stream_timeout`) for
  the transcript of every commit it sent before it emits
  `:transcription_completed` and closes. ElevenLabs refuses a commit that
  covers less than 0.3 s of audio with a `commit_throttled` frame (observed
  2026-09-27); after the end of input that means there was nothing left to
  transcribe, and the stream completes normally. Mid-stream, a `:commit`
  the provider throttles ends the stream with `:rate_limited`.

  **Events.** `:partial_transcript` for each server partial (a partial
  replaces the previous one), `:committed_transcript` for each server
  `committed_transcript` frame, in commit order. A
  `committed_transcript_with_timestamps` frame (sent only when `options`
  sets `"include_timestamps" => true`, and carrying a language only with
  `"include_language_detection" => true`, observed 2026-09-27) never emits
  an event of its own: its `language_code` becomes the `:language` of the
  segment it belongs to. The two frames of a segment are paired by commit
  order (the n-th timestamped frame belongs to the n-th committed segment),
  never by comparing texts, so two segments with the same text each keep
  their own language. A `warning` frame is logged with `Logger.warning/1`
  and emits nothing.

  ElevenLabs sends the two frames of a segment in either order, most often
  the plain one first (3 of the 4 segments logged on 2026-09-27, the
  recorded `rt_fox` session among them), so:

    * **When `options` sets `"include_timestamps"` or
      `"include_language_detection"`** (to `true` or `"true"`), each
      `:committed_transcript` is **held** until its timestamped frame
      arrives and is then emitted with that frame's language. The hold is
      bounded: the segment is released, with `language: nil`, when the next
      segment's `committed_transcript` arrives, when the stream ends with an
      error, when `:stream_timeout` passes, or after #{@language_hold_ms} ms
      (`adapter_opts[:language_hold_ms]`), whichever comes first. A session
      that is complete but for a held segment completes when the segment is
      released, even if `:stream_timeout` is the deadline that released it. A
      timestamped frame that arrives first is kept, and its segment is
      emitted at once. Holding never drops or reorders a segment, and
      `:transcription_completed` waits for a held segment.
    * **Otherwise** (the default) nothing is held: each segment is emitted
      on its `committed_transcript` frame, latency first, with `language`
      only if its timestamped frame came first, which without those options
      it does not, so `:language` is `nil`.

  A timestamped frame whose segment was already emitted is dropped.
  `:transcription_completed` carries the committed segments (each trimmed,
  empties dropped, joined with one space), the last language a segment
  carried, `duration_seconds` computed from the bytes sent
  (`bytes / (sample_rate * 2)`), `opts[:request_id]` and `request.metadata`;
  `usage` is all-`nil` (the protocol reports none).

  **Failures** end the stream with one `{:error, _}`: `:invalid_request`
  for the input rules of `ALLM.TranscriptionStreamAdapter`
  (`metadata.cause` `:invalid_input_chunk`, including an input whose total
  length is odd, `:input_raised` or `:input_crashed`), a classified server
  error frame (by its `message_type`), `:network_error` for a transport
  failure or a close before the end, and `:timeout`.

  **Options:** `:stream_timeout` (default #{@default_stream_timeout} ms) is
  the silence allowed between two messages, where a server frame and an
  input chunk both count. `:connect_timeout` bounds the upgrade.
  `:ws_module` is the `ALLM.Providers.Support.WebSocket` implementation
  (default `ALLM.Providers.Support.WebSocket.Mint`).
  `adapter_opts[:input_window]` is the input pump's credit window.
  `adapter_opts[:language_hold_ms]` (default #{@language_hold_ms}) bounds the
  language hold described under **Events**; it must be a positive integer
  (ms), and any other value is refused synchronously with
  `:invalid_request`.

  **Halting** the stream closes the socket, stops the input pump and removes
  the socket's and the pump's pending messages from the calling process's
  mailbox. The realtime protocol has no keep-alive, so none is sent.

  `opts[:adapter_opts][:transcription_script]` hands the call to
  `ALLM.Providers.FakeTranscription.stream_transcribe/3` before any gate
  runs, with this adapter's `stream_sample_rates/0` as
  `adapter_opts[:stream_sample_rates]`.

  ## Examples

      iex> req = ALLM.TranscriptionStreamRequest.new(sample_rate: 24_000)
      iex> opts = [adapter_opts: [transcription_script: [{:ok, "the quick fox"}]]]
      iex> {:ok, events} = ALLM.Providers.ElevenLabs.Transcription.stream_transcribe(req, [<<0, 0>>], opts)
      iex> for {:committed_transcript, %{text: t}} <- events, do: t
      ["the quick fox"]

      iex> req = ALLM.TranscriptionStreamRequest.new(sample_rate: 11_025)
      iex> {:error, err} = ALLM.Providers.ElevenLabs.Transcription.stream_transcribe(req, [], [])
      iex> {err.reason, err.metadata.sample_rate}
      {:invalid_request, 11_025}
  """
  @impl ALLM.TranscriptionStreamAdapter
  @spec stream_transcribe(TranscriptionStreamRequest.t(), Enumerable.t(), keyword()) ::
          {:ok, Enumerable.t(TranscriptionEvent.t())} | {:error, TranscriptionAdapterError.t()}
  def stream_transcribe(%TranscriptionStreamRequest{} = request, input, opts)
      when is_list(opts) do
    case TranscriptionSupport.fetch_transcription_script(opts) do
      nil -> do_stream_transcribe(request, input, opts)
      _script -> FakeTranscription.stream_transcribe(request, input, with_own_rates(opts))
    end
  end

  # ---------------------------------------------------------------------------
  # Public testing seams (`@doc false` + `@spec`).
  #
  # Names align with `ALLM.Providers.OpenAI.Transcription`: `to_multipart_body/2`
  # returns `{:ok, fields} | {:error, _}` (building it reads the audio bytes,
  # which can fail), `decode_response/4` takes `(body, headers, request, opts)`
  # and the error funnel is `to_transcription_adapter_error/4`. The
  # transcription contract (gates, Fake hand-off, one attempt) is
  # `ALLM.Providers.Support.TranscriptionAdapter`'s; classification and
  # redaction are `ALLM.Providers.Support.ElevenLabs`'s, shared with the
  # speech adapter.
  # ---------------------------------------------------------------------------

  @doc false
  # The three pre-flight gates, in their fixed order: resolvable -> size ->
  # prompt. All run before `Keys.fetch!/2`.
  @impl ALLM.Providers.Support.TranscriptionAdapter
  @spec gate_audio(TranscriptionRequest.t(), keyword()) ::
          :ok | {:error, TranscriptionAdapterError.t()}
  def gate_audio(%TranscriptionRequest{audio: audio} = request, opts) do
    with {:ok, count} <- TranscriptionSupport.measure(audio, :elevenlabs, opts),
         :ok <- TranscriptionSupport.gate_size(count, @max_audio_bytes, :elevenlabs, opts) do
      gate_prompt(request, opts)
    end
  end

  @doc false
  # Adapter-injected default: `model_id` "scribe_v2" when nil (the public
  # `transcribe/2` doc states it). `language_code` is sent only when set.
  # `request.options` become extra fields UNDER the structural ones.
  @spec to_multipart_body(TranscriptionRequest.t(), keyword()) ::
          {:ok, [{String.t(), term()}]} | {:error, TranscriptionAdapterError.t()}
  def to_multipart_body(%TranscriptionRequest{audio: %Audio{} = audio} = request, opts) do
    with {:ok, bytes} <- TranscriptionSupport.resolve_bytes(audio, :elevenlabs, opts) do
      structural =
        [
          {"file",
           {bytes,
            filename: upload_filename(audio),
            content_type: audio.mime_type || "application/octet-stream"}},
          {"model_id", request.model || @default_model}
        ] ++ TranscriptionSupport.optional_field("language_code", request.language)

      {:ok, structural ++ option_fields(request.options)}
    end
  end

  def to_multipart_body(%TranscriptionRequest{}, opts),
    do: {:error, TranscriptionSupport.unresolvable_error(:invalid_source, :elevenlabs, opts)}

  @doc false
  @impl ALLM.Providers.Support.TranscriptionAdapter
  @spec decode_response(term(), Enumerable.t() | map(), TranscriptionRequest.t(), keyword()) ::
          {:ok, TranscriptionResponse.t()} | {:error, TranscriptionAdapterError.t()}
  def decode_response(body, headers, request, opts)

  def decode_response(%{"text" => text} = body, _headers, %TranscriptionRequest{} = request, opts)
      when is_binary(text) do
    {:ok,
     %TranscriptionResponse{
       text: text,
       language: string_or_nil(Map.get(body, "language_code")),
       duration_seconds: number_or_nil(Map.get(body, "audio_duration_secs")),
       id: string_or_nil(Map.get(body, "transcription_id")),
       request_id: Keyword.get(opts, :request_id),
       model: request.model || @default_model,
       provider: :elevenlabs,
       usage: %Usage{},
       raw: body,
       metadata: request.metadata
     }}
  end

  def decode_response(_body, _headers, _request, opts),
    do: {:error, malformed_error("missing or non-string \"text\" field", opts)}

  @doc false
  # `body` may be a decoded map or an undecoded JSON binary.
  @impl ALLM.Providers.Support.TranscriptionAdapter
  @spec to_transcription_adapter_error(
          non_neg_integer(),
          term(),
          Enumerable.t() | map(),
          keyword()
        ) :: TranscriptionAdapterError.t()
  def to_transcription_adapter_error(status, body, headers, opts) when is_integer(status) do
    {reason, fields} = Support.error_fields(status, body, headers, opts)
    TranscriptionAdapterError.new(reason, fields)
  end

  @doc false
  # `Keys.fetch!/2` raises `%EngineError{reason: :missing_key}` by documented
  # design and is not rescued. It runs AFTER `gate_audio/2`. Public only so
  # `ALLM.Providers.Support.TranscriptionAdapter.do_transcribe/4` can call it.
  @impl ALLM.Providers.Support.TranscriptionAdapter
  @spec build_request(TranscriptionRequest.t(), keyword()) ::
          {:ok, Req.Request.t()} | {:error, TranscriptionAdapterError.t()}
  def build_request(%TranscriptionRequest{} = request, opts) do
    api_key = Keys.fetch!(:elevenlabs, opts)

    with {:ok, form} <- to_multipart_body(request, opts) do
      req =
        Req.new(
          method: :post,
          url: Support.base_url(opts) <> @endpoint,
          headers: Support.headers(api_key),
          form_multipart: form,
          # One attempt per call: Req's own retry step must not re-upload.
          retry: false
        )
        |> HTTPResponse.maybe_apply_req_test_stub(opts)
        |> HTTPResponse.apply_receive_timeout(opts, @default_timeout_ms)

      {:ok, req}
    end
  end

  @doc false
  # Public only so `ALLM.Providers.Support.TranscriptionAdapter.run_one_attempt/5`
  # can build the invalid-JSON error with this adapter's message.
  @impl ALLM.Providers.Support.TranscriptionAdapter
  @spec malformed_error(String.t(), keyword()) :: TranscriptionAdapterError.t()
  def malformed_error(detail, opts) do
    TranscriptionAdapterError.new(:malformed_response,
      provider: :elevenlabs,
      message: "could not decode ElevenLabs transcription response: " <> detail,
      metadata: HTTPResponse.build_metadata(%{}, opts)
    )
  end

  @doc false
  # The realtime URL. The scheme follows the base URL (`https` becomes
  # `wss`, `http` becomes `ws`). Adapter-injected default: `model_id`
  # "scribe_v2_realtime" when nil (the public `stream_transcribe/3` doc
  # states it). `audio_format` is `pcm_<sample_rate>`, `commit_strategy`
  # the request's, and `language_code` is sent only when set; each
  # `request.options` entry becomes one more query parameter UNDER these,
  # and `model_id`, `audio_format` and `commit_strategy` options are dropped.
  # The API key is never part of it.
  @spec stream_url(TranscriptionStreamRequest.t(), keyword()) :: String.t()
  def stream_url(%TranscriptionStreamRequest{} = request, opts) do
    structural =
      %{
        "model_id" => request.model || @default_stream_model,
        "audio_format" => "pcm_#{request.sample_rate}",
        "commit_strategy" => Atom.to_string(request.commit_strategy)
      }
      |> put_present("language_code", request.language)

    query = request.options |> stream_query_options() |> Map.merge(structural)
    Support.ws_base_url(opts) <> @stream_endpoint <> "?" <> URI.encode_query(query)
  end

  @doc false
  # The client frame that carries `audio` (PCM16 bytes, possibly empty) and
  # the commit flag.
  @spec audio_chunk_message(binary(), boolean(), pos_integer()) :: map()
  def audio_chunk_message(audio, commit?, sample_rate) do
    %{
      "message_type" => "input_audio_chunk",
      "audio_base_64" => Base.encode64(audio),
      "commit" => commit?,
      "sample_rate" => sample_rate
    }
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp gate_prompt(%TranscriptionRequest{prompt: nil}, _opts), do: :ok

  defp gate_prompt(%TranscriptionRequest{}, opts) do
    {:error,
     TranscriptionAdapterError.new(:unsupported_feature,
       provider: :elevenlabs,
       message: "ElevenLabs speech-to-text has no prompt field",
       metadata: HTTPResponse.build_metadata(%{field: :prompt}, opts)
     )}
  end

  defp upload_filename(%Audio{source: {:file, path}}), do: Path.basename(path)

  defp upload_filename(%Audio{mime_type: mime}) do
    case Audio.extension_for_mime(mime) do
      ext when is_binary(ext) -> "audio." <> ext
      nil -> @fallback_filename
    end
  end

  defp option_fields(options) do
    {fields, dropped} = TranscriptionSupport.option_fields(options, @structural_fields)

    if dropped != [] do
      Logger.debug(fn ->
        "ALLM.Providers.ElevenLabs.Transcription: dropping option(s) " <>
          "#{inspect(dropped)}; the adapter sets them from the request."
      end)
    end

    fields
  end

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil

  defp number_or_nil(value) when is_number(value), do: value
  defp number_or_nil(_value), do: nil

  # ---------------------------------------------------------------------------
  # Internals — realtime streaming
  #
  # One `Stream.resource/3` whose three functions run in the reducing
  # process, which therefore owns the socket (the loop is
  # `ALLM.Providers.Support.WebSocket.InputLoop`). The start function only
  # connects. The input pump starts on the server's `session_started`, so a
  # session the server refuses never reduces the input. Every pump and
  # transport message resets the silence timer; the realtime protocol has
  # no keep-alive. The after function closes the socket, drains its
  # messages and stops the pump.
  # ---------------------------------------------------------------------------

  defp with_own_rates(opts) do
    adapter_opts =
      opts
      |> Keyword.get(:adapter_opts, [])
      |> Keyword.put(:stream_sample_rates, @stream_sample_rates)

    Keyword.put(opts, :adapter_opts, adapter_opts)
  end

  defp do_stream_transcribe(request, input, opts) do
    with :ok <- gate_stream_request(request, opts),
         :ok <- gate_sample_rate(request, opts),
         :ok <- gate_language_hold(opts) do
      api_key = Keys.fetch!(:elevenlabs, opts)

      {:ok,
       Stream.resource(
         fn -> open_stream(request, input, api_key, opts) end,
         &stream_next/1,
         &InputLoop.close_loop/1
       )}
    end
  end

  defp gate_stream_request(request, opts) do
    case Validate.transcription_stream_request(request) do
      :ok ->
        :ok

      {:error, %ValidationError{errors: errors}} ->
        {:error,
         stream_error(
           :invalid_request,
           "invalid transcription stream request: #{inspect(errors)}",
           %{errors: errors},
           opts
         )}
    end
  end

  defp gate_sample_rate(%TranscriptionStreamRequest{sample_rate: rate}, opts) do
    if rate in @stream_sample_rates do
      :ok
    else
      {:error,
       stream_error(
         :invalid_request,
         "sample_rate #{inspect(rate)} is not one of #{inspect(@stream_sample_rates)}",
         %{field: :sample_rate, sample_rate: rate, supported: @stream_sample_rates},
         opts
       )}
    end
  end

  # `language_hold_ms` feeds `System.monotonic_time/1` arithmetic, so a
  # non-integer (`:infinity` included) would raise mid-enumeration. Refused
  # here, synchronously, whether or not the request opts in to the hold.
  defp gate_language_hold(opts) do
    case language_hold_ms(opts) do
      ms when is_integer(ms) and ms > 0 ->
        :ok

      other ->
        {:error,
         stream_error(
           :invalid_request,
           "adapter_opts[:language_hold_ms] must be a positive integer (ms), got: #{inspect(other)}",
           %{field: :language_hold_ms, language_hold_ms: other},
           opts
         )}
    end
  end

  defp open_stream(request, input, api_key, opts) do
    ws = Keyword.get(opts, :ws_module, ALLM.Providers.Support.WebSocket.Mint)
    stream_timeout = Keyword.get(opts, :stream_timeout, @default_stream_timeout)

    state =
      ws
      |> InputLoop.loop_state(stream_timeout, :infinity)
      |> Map.merge(%{
        request: request,
        input: input,
        opts: opts,
        pending: [],
        done?: false,
        remainder: "",
        max_chunk_bytes: div(request.sample_rate * 2 * @max_chunk_ms, 1000),
        bytes_sent: 0,
        uncommitted: 0,
        awaiting: 0,
        segments: [],
        language: nil,
        hold_language?: hold_language?(request),
        hold_ms: language_hold_ms(opts),
        commits_seen: 0,
        stamps_seen: 0,
        stamps: %{},
        held: nil
      })

    case ws.connect(stream_url(request, opts), Support.headers(api_key), opts) do
      {:ok, conn} ->
        %{state | conn: conn}

      {:error, {:upgrade_status, status, body}} ->
        {reason, fields} = Support.error_fields(status, body, [], opts)
        %{state | pending: [{:error, TranscriptionAdapterError.new(reason, fields)}], done?: true}

      {:error, {:transport, cause}} ->
        error = transport_failure("WebSocket connect failed", cause, opts)
        %{state | pending: [{:error, error}], done?: true}
    end
  end

  defp stream_next(%{pending: [_ | _] = pending} = state), do: {pending, %{state | pending: []}}
  defp stream_next(%{done?: true} = state), do: {:halt, state}

  defp stream_next(state) do
    case InputLoop.next_message(state) do
      {:pump, classified, state} -> on_pump(classified, state)
      {:transport, message, state} -> on_transport(message, state)
      :wake -> on_wake(state)
    end
  end

  # No keep-alive runs, so a wake-up is the silence deadline or the end of
  # a language hold (`wake_at`). Either one releases a held segment, and
  # completion is checked BEFORE the timeout: after the final commit the
  # server sends nothing more if the timestamped frame never comes, so with
  # `stream_timeout` shorter than the hold the silence deadline passes on a
  # session that is complete but for the hold. That session completes; only
  # one still awaiting a commit, or with input left, ends with `:timeout`.
  defp on_wake(state) do
    timed_out? = InputLoop.timed_out?(state)
    {released, state} = release_held(state)
    {done, state} = maybe_complete(state)

    if timed_out? and not state.done? do
      {rest, state} =
        finish(
          state,
          stream_error(
            :timeout,
            "no server frame or input chunk within stream_timeout (#{state.stream_timeout} ms)",
            %{},
            state.opts
          )
        )

      {released ++ rest, state}
    else
      {released ++ done, state}
    end
  end

  defp on_pump({:input, element}, %{pump: {pid, ref}} = state) do
    InputPump.ack(pid, ref)
    on_element(element, state)
  end

  defp on_pump(:done, state), do: end_of_input(%{InputLoop.stop_pump(state) | input_done?: true})

  defp on_pump({:failed, cause, info}, state) do
    error =
      TranscriptionAdapterError.new(:invalid_request,
        provider: :elevenlabs,
        message: "the input stream failed: #{info.message}",
        cause: info,
        metadata: HTTPResponse.build_metadata(%{cause: cause}, state.opts)
      )

    finish(InputLoop.stop_pump(state), error)
  end

  defp on_element(:commit, state), do: emit(send_commit(state))

  defp on_element(chunk, state) when is_binary(chunk) do
    data = state.remainder <> chunk
    whole = byte_size(data) - rem(byte_size(data), 2)
    <<samples::binary-size(whole), remainder::binary>> = data
    emit(send_audio(%{state | remainder: remainder}, samples))
  end

  defp on_element(_element, state),
    do: finish(state, invalid_chunk_error("audio chunks must be binaries or :commit", state.opts))

  # Whole samples only, at most `max_chunk_bytes` per frame.
  defp send_audio(state, ""), do: {:ok, state}

  defp send_audio(state, samples) do
    size = min(byte_size(samples), state.max_chunk_bytes)
    <<frame::binary-size(size), rest::binary>> = samples

    case send_json(state, audio_chunk_message(frame, false, state.request.sample_rate)) do
      {:ok, state} ->
        send_audio(
          %{state | bytes_sent: state.bytes_sent + size, uncommitted: state.uncommitted + size},
          rest
        )

      failed ->
        failed
    end
  end

  defp send_commit(state) do
    case send_json(state, audio_chunk_message("", true, state.request.sample_rate)) do
      {:ok, state} -> {:ok, %{state | uncommitted: 0, awaiting: state.awaiting + 1}}
      failed -> failed
    end
  end

  # Invariant 8: commit what is uncommitted, then wait for every commit's
  # transcript. A sample split at the very end is an input error.
  defp end_of_input(%{remainder: <<_>>} = state) do
    finish(
      state,
      invalid_chunk_error("the input ended mid-sample (odd total length)", state.opts)
    )
  end

  defp end_of_input(%{uncommitted: 0} = state), do: maybe_complete(state)

  defp end_of_input(state) do
    case send_commit(state) do
      {:ok, state} -> maybe_complete(state)
      failed -> emit(failed)
    end
  end

  defp maybe_complete(%{input_done?: true, awaiting: 0, held: nil} = state),
    do: {[completed_event(state)], %{state | done?: true}}

  defp maybe_complete(state), do: {[], state}

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

  defp on_frames([], state, acc), do: {acc, state}

  defp on_frames([frame | rest], state, acc) do
    case on_frame(frame, state) do
      {events, %{done?: true} = state} -> {acc ++ events, state}
      {events, state} -> on_frames(rest, state, acc ++ events)
    end
  end

  defp on_frame({:text, json}, state) do
    case Jason.decode(json) do
      {:ok, %{} = payload} ->
        on_payload(payload, state)

      _ ->
        finish(state, malformed_error("server frame is not a JSON object", state.opts))
    end
  end

  defp on_frame({:close, code, reason}, state) do
    {reason_atom, fields} = Support.ws_error_fields(%{"message" => reason}, code, state.opts)
    finish(state, TranscriptionAdapterError.new(closed_reason(reason_atom), fields))
  end

  defp on_frame(:closed, state) do
    finish(
      state,
      stream_error(:network_error, "ElevenLabs closed the connection early", %{}, state.opts)
    )
  end

  defp on_frame(_binary, state), do: {[], state}

  # A close before the end: an orderly 1000 still cut the session short.
  defp closed_reason(:unknown), do: :network_error
  defp closed_reason(reason), do: reason

  defp on_payload(%{"message_type" => "commit_throttled"}, %{input_done?: true} = state) do
    # After the end of input a throttled commit had too little audio to
    # transcribe (under 0.3 s, observed 2026-09-27): nothing more is coming.
    maybe_complete(%{state | awaiting: max(state.awaiting - 1, 0)})
  end

  defp on_payload(payload, state) do
    if Support.ws_error?(payload) do
      {reason, fields} = Support.ws_error_fields(payload, nil, state.opts)
      finish(state, TranscriptionAdapterError.new(reason, fields))
    else
      on_message(Map.get(payload, "message_type"), payload, state)
    end
  end

  defp on_message("session_started", payload, %{pump: nil, input_done?: false} = state) do
    started =
      TranscriptionEvent.transcription_started(%{
        request_id: Keyword.get(state.opts, :request_id),
        model: state.request.model || @default_stream_model,
        provider: :elevenlabs,
        session_id: string_or_nil(Map.get(payload, "session_id"))
      })

    {[started], InputLoop.start_pump(state, state.input, state.opts)}
  end

  defp on_message("partial_transcript", %{"text" => text}, state) when is_binary(text),
    do: {[TranscriptionEvent.partial_transcript(text)], state}

  # Segment `index` (commit order). A held earlier segment is released
  # first, without a language, so segments never reorder.
  defp on_message("committed_transcript", %{"text" => text}, state) when is_binary(text) do
    {released, state} = release_held(state)
    index = state.commits_seen

    state = %{
      state
      | commits_seen: index + 1,
        awaiting: max(state.awaiting - 1, 0)
    }

    {now, state} = on_committed(Map.fetch(state.stamps, index), index, text, state)
    {done, state} = maybe_complete(state)
    {released ++ now ++ done, state}
  end

  # A timestamped commit never emits an event of its own; it is paired with
  # its segment by commit order, never by text.
  defp on_message("committed_transcript_with_timestamps", payload, state) do
    index = state.stamps_seen
    language = string_or_nil(Map.get(payload, "language_code"))
    on_stamp(index, language, %{state | stamps_seen: index + 1})
  end

  defp on_message("warning", payload, state) do
    Logger.warning(fn ->
      "ALLM.Providers.ElevenLabs.Transcription: server warning " <>
        Support.redact_key_material(inspect(Map.delete(payload, "message_type")))
    end)

    {[], state}
  end

  defp on_message(type, _payload, state)
       when type in ["partial_transcript", "committed_transcript"],
       do: finish(state, malformed_error("#{type} without a string text", state.opts))

  defp on_message(_type, _payload, state), do: {[], state}

  # The segment's timestamped frame came first: emit with its language.
  defp on_committed({:ok, language}, index, text, state),
    do: segment(%{state | stamps: Map.delete(state.stamps, index)}, text, language)

  # Opted in: hold the segment for its timestamped frame, bounded by `wake_at`.
  defp on_committed(:error, index, text, %{hold_language?: true} = state) do
    deadline = System.monotonic_time(:millisecond) + state.hold_ms
    {[], %{state | held: %{index: index, text: text}, wake_at: deadline}}
  end

  defp on_committed(:error, _index, text, state), do: segment(state, text, nil)

  # The held segment's own frame: release it with the language.
  defp on_stamp(index, language, %{held: %{index: index, text: text}} = state) do
    {events, state} = segment(%{state | held: nil, wake_at: nil}, text, language)
    {done, state} = maybe_complete(state)
    {events ++ done, state}
  end

  # Ahead of its segment: keep it for `on_committed/4`.
  defp on_stamp(index, language, %{commits_seen: seen} = state) when index >= seen,
    do: {[], %{state | stamps: Map.put(state.stamps, index, language)}}

  # Its segment already went out: dropped, language included.
  defp on_stamp(_index, _language, state), do: {[], state}

  defp release_held(%{held: nil} = state), do: {[], state}

  defp release_held(%{held: %{text: text}} = state),
    do: segment(%{state | held: nil, wake_at: nil}, text, nil)

  defp segment(state, text, language) do
    state = %{state | segments: [text | state.segments], language: language || state.language}
    {[TranscriptionEvent.committed_transcript(text, language)], state}
  end

  defp hold_language?(%TranscriptionStreamRequest{options: options}) do
    params = Support.query_params(options, [])
    Enum.any?(@hold_options, &(Map.get(params, &1) in [true, "true"]))
  end

  defp language_hold_ms(opts) do
    opts |> Keyword.get(:adapter_opts, []) |> Keyword.get(:language_hold_ms, @language_hold_ms)
  end

  defp completed_event(state) do
    TranscriptionEvent.transcription_completed(%{
      text:
        state.segments
        |> Enum.reverse()
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.join(" "),
      language: state.language,
      duration_seconds: state.bytes_sent / (state.request.sample_rate * 2),
      request_id: Keyword.get(state.opts, :request_id),
      usage: %Usage{},
      metadata: state.request.metadata
    })
  end

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

  # A held segment goes out ahead of the error, so a failure never loses it.
  defp finish(state, %TranscriptionAdapterError{} = error) do
    {released, state} = release_held(state)
    {released ++ [{:error, error}], %{state | done?: true}}
  end

  defp stream_query_options(options) do
    {reserved, params} = options |> Support.query_params([]) |> Map.split(@reserved_query)

    if reserved != %{} do
      Logger.debug(fn ->
        "ALLM.Providers.ElevenLabs.Transcription: dropping query option(s) " <>
          "#{inspect(Map.keys(reserved))}; the adapter sets them from the request."
      end)
    end

    params
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp invalid_chunk_error(message, opts),
    do: stream_error(:invalid_request, message, %{cause: :invalid_input_chunk}, opts)

  defp transport_failure(message, cause, opts) do
    TranscriptionAdapterError.new(:network_error,
      provider: :elevenlabs,
      message: message,
      cause: HTTPResponse.sanitize_cause(cause),
      metadata: HTTPResponse.build_metadata(%{}, opts)
    )
  end

  defp stream_error(reason, message, metadata, opts) do
    TranscriptionAdapterError.new(reason,
      provider: :elevenlabs,
      message: message,
      metadata: HTTPResponse.build_metadata(metadata, opts)
    )
  end
end
