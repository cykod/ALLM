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
  `ALLM.TranscriptionAdapter` against `POST /v1/speech-to-text`.

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
  error under the same key.
  """

  @behaviour ALLM.TranscriptionAdapter
  @behaviour ALLM.Providers.Support.TranscriptionAdapter

  require Logger

  alias ALLM.{Audio, Keys, TranscriptionRequest, TranscriptionResponse, Usage}
  alias ALLM.Error.TranscriptionAdapterError
  alias ALLM.Providers.FakeTranscription
  alias ALLM.Providers.Support.ElevenLabs, as: Support
  alias ALLM.Providers.Support.HTTPResponse
  alias ALLM.Providers.Support.TranscriptionAdapter, as: TranscriptionSupport

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
end
