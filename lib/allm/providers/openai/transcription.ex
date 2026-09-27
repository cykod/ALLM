defmodule ALLM.Providers.OpenAI.Transcription do
  # Attribute block sits ABOVE the @moduledoc because the moduledoc
  # interpolates these constants.

  @base_url "https://api.openai.com/v1"
  @endpoint "/audio/transcriptions"

  # Adapter-injected default for a nil `:model` (stated in the public
  # `transcribe/2` doc and in `to_multipart_body/2`'s `@doc false`).
  @default_model "gpt-transcribe"

  # Settled by the recorder's size ladder on 2026-09-24. OpenAI's cap is
  # 26_214_400 bytes (25 MiB) on the WHOLE multipart body: a 25 MiB + 1 file
  # part answered 413 "Maximum content size limit (26214400) exceeded
  # (26214850 bytes read)", while a 25 MiB - 64 KiB file part was accepted.
  # This is that accepted rung, leaving 64 KiB for the other form fields.
  @max_audio_bytes 25 * 1024 * 1024 - 64 * 1024

  # Req's own `receive_timeout` default (15 s) is too short for a 25 MB upload.
  @default_timeout_ms 120_000

  # Multipart field names the adapter sets itself. `request.options` never
  # overrides them. `response_format` is also dropped with a debug log,
  # because anything but `json` changes the body shape the decoder reads.
  @structural_fields ["file", "model", "response_format", "language", "prompt"]

  # A non-file upload is named `audio.<ext>` from `ALLM.Audio.extension_for_mime/1`
  # (parameters and case ignored). OpenAI trusts the filename extension (a
  # valid mp3 named `audio.bin` got 400 "Unsupported file format bin" on
  # 2026-09-24), so a mime with no extension is rejected locally instead of
  # being sent under a made-up name.

  @moduledoc """
  OpenAI speech-to-text adapter. Implements `ALLM.TranscriptionAdapter`
  against `POST /v1/audio/transcriptions`.

  Layer B — runtime. Wire it with
  `ALLM.Engine.new(transcription_adapter: ALLM.Providers.OpenAI.Transcription)`
  and call it through `ALLM.transcribe/3`. The key resolves via
  `ALLM.Keys.fetch!(:openai, opts)` after the pre-flight gates, so no key
  ever lives on the engine.

      req = ALLM.TranscriptionRequest.new(audio: ALLM.Audio.from_file("clip.mp3"))
      {:ok, resp} = ALLM.Providers.OpenAI.Transcription.transcribe(req, api_key: "sk-...")
      resp.text

  ## Wire-field map

  Observed live on **2026-09-24** by `scripts/record_openai_audio_fixtures.exs`,
  whose probe halts the recording pass on any mismatch.

  | Concern | OpenAI |
  |---------|--------|
  | Endpoint | `POST #{@base_url}#{@endpoint}`, `multipart/form-data` |
  | Auth | `authorization: Bearer <key>` |
  | `file` | the audio bytes. Named by the file's basename for a `{:file, path}` source, else `audio.<ext>` from the MIME type |
  | `model` | `:model`, or `#{@default_model}` when `nil` |
  | `response_format` | always `json` |
  | `language`, `prompt` | sent when set |
  | Options | each `ALLM.TranscriptionRequest.options` entry becomes one form field (a list becomes one field per element, each under the bare key; OpenAI names array parameters with a `[]` suffix, so pass `"timestamp_granularities[]"` as the key where the endpoint expects it); never overrides the fields above; `response_format` is dropped |
  | Response | `{"text", "usage", "languages"?}` |
  | Usage | `{"type": "duration", "seconds"}` (whisper-1, gpt-transcribe) → `:duration_seconds`; `{"type": "tokens", …}` (gpt-4o-mini-transcribe) → `:usage` |
  | Language | `languages[0].code` → `:language` (gpt-transcribe only) |
  | Correlation | `x-request-id` response header |
  | Size limit | 25 MiB on the whole multipart body; see `max_audio_bytes/0` |
  | Duration | no duration cap was found: an 1800-second clip was accepted by gpt-transcribe |
  | Unknown fields | **ignored** (200), so a mistyped `:options` key does nothing and raises no error |

  Accepted formats, per OpenAI's own error text: flac, m4a, mp3, mp4, mpeg,
  mpga, oga, ogg, wav, webm. Other formats are forwarded and answered with
  a 400, surfaced as `:invalid_request`.

  ## Adapter-injected defaults

    * `model` defaults to `"#{@default_model}"` when `:model` is `nil`.
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
    3. **Filename.** A non-file source whose `:mime_type` is `nil` or not a
       known audio type → `:invalid_request` with `metadata.mime_type`.
       Parameters and case are ignored, so `"audio/webm;codecs=opus"` is
       sent as `audio.webm`.
       OpenAI picks the decoder from the upload's filename extension, so such
       a clip would be sent under a name it rejects.

  ## Response

  `:text` is the transcript (`""` for silence). `:raw` is the provider body.
  `:model` is the model that was sent. `opts[:request_id]` is reflected onto
  `response.request_id`; when absent, OpenAI's `x-request-id` header is used.
  `request.metadata` round-trips onto `response.metadata`.

  > #### The `x-request-id` fallback is unreachable through `ALLM.transcribe/3` {: .warning}
  >
  > The façade always supplies `opts[:request_id]` (it generates one when the
  > caller does not), so on that path `response.request_id` is the façade's
  > id and OpenAI's own correlation id is never observed. It surfaces only on
  > a direct `transcribe/2` / `decode_response/4` call that omits
  > `opts[:request_id]`. Identical to `ALLM.Providers.OpenAI.Moderation`.

  ## No retries

  This adapter makes **one** HTTP attempt per call and returns every
  classified error, retryable or not, as `{:error, _}`. Each attempt
  re-uploads the whole clip, so the only retry loop is `ALLM.transcribe/3`'s
  (3 attempts at the default policy). A direct `transcribe/2` caller who
  wants retries wraps the call.

  ## Error-struct hygiene

  No raw response body, request header or `Authorization` value is copied
  into `%ALLM.Error.TranscriptionAdapterError{}`, and there is no body
  preview. The provider's message, `code` and `type` pass a redactor that
  replaces key-shaped tokens with `[REDACTED]`. OpenAI's real 401 is sent as
  `text/plain` and masks the key it echoes (observed 2026-09-24).

  > #### Not every error is JSON-encodable {: .warning}
  >
  > The struct derives `Jason.Encoder`, but a `:timeout`, `:network_error`
  > or invalid-JSON `:malformed_response` error carries an exception struct
  > (`Req.TransportError`, `Jason.DecodeError`) on `:cause`, and
  > `Jason.encode!/1` raises `Protocol.UndefinedError` on it. Drop or
  > `Exception.message/1` the `:cause` before encoding. The image, embedding
  > and moderation adapter errors share this limitation.

  ## Test-injection escape hatch

  `transcribe/2` honours `opts[:adapter_opts][:transcription_script]`: when
  the key is present, the call is handed to
  `ALLM.Providers.FakeTranscription.transcribe/2` BEFORE any of this
  adapter's gates run, with `adapter_opts[:max_audio_bytes]` set to this
  adapter's own `max_audio_bytes/0` so a real clip is not rejected by the
  Fake's small default cap. `prepare_request/2` returns a stub error under
  the same key.
  """

  @behaviour ALLM.TranscriptionAdapter
  @behaviour ALLM.Providers.Support.TranscriptionAdapter

  require Logger

  alias ALLM.{Audio, Keys, TranscriptionRequest, TranscriptionResponse, Usage}
  alias ALLM.Error.TranscriptionAdapterError
  alias ALLM.Providers.FakeTranscription
  alias ALLM.Providers.Support.{HTTPResponse, OpenAIHeaders, Redact}
  alias ALLM.Providers.Support.TranscriptionAdapter, as: TranscriptionSupport

  @doc """
  Return the largest audio clip, in bytes, this adapter will upload.

  OpenAI caps the whole multipart request body at 25 MiB (26,214,400
  bytes). This cap is 25 MiB minus 64 KiB, the largest file part a live
  probe on 2026-09-24 saw accepted, leaving room for the other form fields.
  A very long `:prompt` can still push a clip just under the cap over the
  provider's limit; that surfaces as `:invalid_request` from a 413.

  ## Examples

      iex> ALLM.Providers.OpenAI.Transcription.max_audio_bytes()
      26_148_864
  """
  @impl ALLM.TranscriptionAdapter
  @spec max_audio_bytes() :: pos_integer()
  def max_audio_bytes, do: @max_audio_bytes

  @doc """
  Transcribe `request.audio` against OpenAI.

  Returns `{:ok, %ALLM.TranscriptionResponse{}}` or
  `{:error, %ALLM.Error.TranscriptionAdapterError{}}`. The one exception is
  `ALLM.Keys.fetch!/2`, which raises `%ALLM.Error.EngineError{reason: :missing_key}`
  by design; every pre-flight gate runs ahead of it.

  **Injected defaults:** `model` is `"#{@default_model}"` when the request
  leaves it `nil`, and the receive timeout is #{div(@default_timeout_ms, 1000)} s
  when `opts[:request_timeout]` is absent.

  **No retries:** one HTTP attempt per call, whatever the error. Wrap the
  call yourself if you want retries, or go through `ALLM.transcribe/3`,
  which retries up to 3 times at the default policy.

  **No duration cap was found:** a live probe on 2026-09-24 sent an
  1800-second clip to gpt-transcribe and got a 200. Only the byte cap in
  `max_audio_bytes/0` is enforced here.

  ## Examples

      iex> audio = ALLM.Audio.from_binary("ID3", "audio/mpeg")
      iex> req = ALLM.TranscriptionRequest.new(audio: audio)
      iex> opts = [adapter_opts: [transcription_script: [{:ok, "hello"}]]]
      iex> {:ok, resp} = ALLM.Providers.OpenAI.Transcription.transcribe(req, opts)
      iex> resp.text
      "hello"

      iex> req = ALLM.TranscriptionRequest.new(audio: ALLM.Audio.from_file("/nonexistent.mp3"))
      iex> {:error, err} = ALLM.Providers.OpenAI.Transcription.transcribe(req, [])
      iex> {err.reason, err.metadata.cause}
      {:invalid_request, :enoent}
  """
  @impl ALLM.TranscriptionAdapter
  @spec transcribe(TranscriptionRequest.t(), keyword()) ::
          {:ok, TranscriptionResponse.t()} | {:error, TranscriptionAdapterError.t()}
  def transcribe(%TranscriptionRequest{} = request, opts) when is_list(opts) do
    case TranscriptionSupport.fetch_transcription_script(opts) do
      nil ->
        TranscriptionSupport.do_transcribe(__MODULE__, :openai, request, opts)

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

  The pre-flight gates run first, so this is defined only for audio that
  passes them. Under `opts[:adapter_opts][:transcription_script]` it returns
  a stub error instead of delegating.

  ## Examples

      iex> req = ALLM.TranscriptionRequest.new(audio: ALLM.Audio.from_binary("ID3", "audio/mpeg"))
      iex> {:ok, http} = ALLM.Providers.OpenAI.Transcription.prepare_request(req, api_key: "sk-x")
      iex> URI.to_string(http.url)
      "https://api.openai.com/v1/audio/transcriptions"
  """
  @impl ALLM.TranscriptionAdapter
  @spec prepare_request(TranscriptionRequest.t(), keyword()) ::
          {:ok, Req.Request.t()} | {:error, TranscriptionAdapterError.t()}
  def prepare_request(%TranscriptionRequest{} = request, opts) when is_list(opts) do
    case TranscriptionSupport.fetch_transcription_script(opts) do
      nil -> with :ok <- gate_audio(request, opts), do: build_request(request, opts)
      _script -> {:error, TranscriptionSupport.stub_error(:openai, opts)}
    end
  end

  # ---------------------------------------------------------------------------
  # Public testing seams (`@doc false` + `@spec`).
  #
  # Names align with `openai/speech.ex` and the rest of the OpenAI family;
  # the error funnel is renamed per capability (`to_transcription_adapter_error/4`).
  # `to_multipart_body/2` returns `{:ok, fields} | {:error, _}`, the capability
  # family's shape (`openai/images.ex`'s `to_multipart_body/2`), because
  # building it reads the audio bytes, which can fail. The HTTP helpers are
  # `openai/speech.ex`'s choices from `ALLM.Providers.Support.HTTPResponse`,
  # including its four deliberate differences from `openai/moderation.ex`
  # (binary error bodies are JSON-decoded, every `Jason.DecodeError` offset is
  # reset, a non-map `"error"` value is tolerated, and
  # `apply_receive_timeout/3` always applies a default timeout). The
  # transcription contract (gates, Fake hand-off, dispatch) is shared with the
  # Gemini sibling through `ALLM.Providers.Support.TranscriptionAdapter`. The
  # one structural difference from the speech sibling: there is no
  # `ALLM.Retry.run/3` here, and
  # `ALLM.Providers.Support.TranscriptionAdapter.run_one_attempt/5` never
  # returns `{:retry, …}`.
  # ---------------------------------------------------------------------------

  @doc false
  # The three pre-flight gates, in their fixed order: resolvable -> size ->
  # filename. All run before `Keys.fetch!/2`.
  @impl ALLM.Providers.Support.TranscriptionAdapter
  @spec gate_audio(TranscriptionRequest.t(), keyword()) ::
          :ok | {:error, TranscriptionAdapterError.t()}
  def gate_audio(%TranscriptionRequest{audio: audio}, opts) do
    with {:ok, count} <- TranscriptionSupport.measure(audio, :openai, opts),
         :ok <- TranscriptionSupport.gate_size(count, @max_audio_bytes, :openai, opts) do
      gate_filename(audio, opts)
    end
  end

  @doc false
  # Adapter-injected default: `model` "gpt-transcribe" when nil (the public
  # `transcribe/2` doc states it). `response_format` is always "json".
  # `request.options` become extra fields UNDER the structural ones. A
  # non-file source whose mime has no extension returns the filename gate's
  # error: the body builder never names a part `audio.bin`.
  @spec to_multipart_body(TranscriptionRequest.t(), keyword()) ::
          {:ok, [{String.t(), term()}]} | {:error, TranscriptionAdapterError.t()}
  def to_multipart_body(%TranscriptionRequest{audio: %Audio{} = audio} = request, opts) do
    with {:ok, bytes} <- TranscriptionSupport.resolve_bytes(audio, :openai, opts),
         {:ok, name} <- upload_filename(audio, opts) do
      structural =
        [
          {"file",
           {bytes, filename: name, content_type: audio.mime_type || "application/octet-stream"}},
          {"model", request.model || @default_model},
          {"response_format", "json"}
        ] ++
          TranscriptionSupport.optional_field("language", request.language) ++
          TranscriptionSupport.optional_field("prompt", request.prompt)

      {:ok, structural ++ option_fields(request.options)}
    end
  end

  def to_multipart_body(%TranscriptionRequest{}, opts),
    do: {:error, TranscriptionSupport.unresolvable_error(:invalid_source, :openai, opts)}

  @doc false
  @impl ALLM.Providers.Support.TranscriptionAdapter
  @spec decode_response(term(), Enumerable.t() | map(), TranscriptionRequest.t(), keyword()) ::
          {:ok, TranscriptionResponse.t()} | {:error, TranscriptionAdapterError.t()}
  def decode_response(body, headers, request, opts)

  def decode_response(%{"text" => text} = body, headers, %TranscriptionRequest{} = request, opts)
      when is_binary(text) do
    {usage, duration} = decode_usage(Map.get(body, "usage"))

    {:ok,
     %TranscriptionResponse{
       text: text,
       language: decode_language(Map.get(body, "languages")),
       duration_seconds: duration,
       request_id:
         Keyword.get(opts, :request_id) || HTTPResponse.header_value(headers, "x-request-id"),
       model: request.model || @default_model,
       provider: :openai,
       usage: usage,
       raw: body,
       metadata: request.metadata
     }}
  end

  def decode_response(_body, _headers, _request, opts),
    do: {:error, malformed_error("missing or non-string \"text\" field", opts)}

  @doc false
  # `body` may be a decoded map or an undecoded binary: OpenAI's 401 is
  # `text/plain` carrying JSON, which `Req` does not decode.
  @impl ALLM.Providers.Support.TranscriptionAdapter
  @spec to_transcription_adapter_error(
          non_neg_integer(),
          term(),
          Enumerable.t() | map(),
          keyword()
        ) :: TranscriptionAdapterError.t()
  def to_transcription_adapter_error(status, body, headers, opts) when is_integer(status) do
    error = body |> HTTPResponse.decode_json_error_body() |> HTTPResponse.error_object()

    {reason, retry_after} =
      classify_transcription_reason(status, HTTPResponse.retry_after_ms(headers))

    TranscriptionAdapterError.new(reason,
      provider: :openai,
      status: status,
      retry_after_ms: retry_after,
      message:
        HTTPResponse.redacted_error_message(error, "OpenAI HTTP #{status}", &redact_key_material/1),
      metadata:
        HTTPResponse.build_metadata(
          %{
            status: status,
            openai_code:
              HTTPResponse.redact_optional(Map.get(error, "code"), &redact_key_material/1),
            openai_type:
              HTTPResponse.redact_optional(Map.get(error, "type"), &redact_key_material/1)
          },
          opts
        )
    )
  end

  # ---------------------------------------------------------------------------
  # Internals — gates
  # ---------------------------------------------------------------------------

  defp gate_filename(%Audio{} = audio, opts) do
    with {:ok, _name} <- upload_filename(audio, opts), do: :ok
  end

  # The gate and `to_multipart_body/2` share this, so the body builder can
  # never name a part the gate would refuse (no `audio.bin` fallback).
  defp upload_filename(%Audio{source: {:file, path}}, _opts), do: {:ok, Path.basename(path)}

  defp upload_filename(%Audio{mime_type: mime}, opts) do
    case Audio.extension_for_mime(mime) do
      ext when is_binary(ext) ->
        {:ok, "audio." <> ext}

      nil ->
        {:error,
         TranscriptionAdapterError.new(:invalid_request,
           provider: :openai,
           message:
             "audio :mime_type #{inspect(mime)} names no file format OpenAI accepts; " <>
               "set a known audio MIME type or use ALLM.Audio.from_file/1",
           metadata: HTTPResponse.build_metadata(%{field: :audio, mime_type: mime}, opts)
         )}
    end
  end

  # ---------------------------------------------------------------------------
  # Internals — dispatch (one attempt, no retry loop)
  # ---------------------------------------------------------------------------

  @doc false
  # `Keys.fetch!/2` raises `%EngineError{reason: :missing_key}` by documented
  # design and is not rescued. It runs AFTER `gate_audio/2`. Public only so
  # `ALLM.Providers.Support.TranscriptionAdapter.do_transcribe/4` can call it.
  @impl ALLM.Providers.Support.TranscriptionAdapter
  @spec build_request(TranscriptionRequest.t(), keyword()) ::
          {:ok, Req.Request.t()} | {:error, TranscriptionAdapterError.t()}
  def build_request(%TranscriptionRequest{} = request, opts) do
    api_key = Keys.fetch!(:openai, opts)

    with {:ok, form} <- to_multipart_body(request, opts) do
      req =
        Req.new(
          method: :post,
          url: @base_url <> @endpoint,
          headers: OpenAIHeaders.multipart_headers(api_key, opts),
          form_multipart: form,
          # One attempt per call: Req's own retry step must not re-upload.
          retry: false
        )
        |> HTTPResponse.maybe_apply_req_test_stub(opts)
        |> HTTPResponse.apply_receive_timeout(opts, @default_timeout_ms)

      {:ok, req}
    end
  end

  # ---------------------------------------------------------------------------
  # Internals — multipart fields
  # ---------------------------------------------------------------------------

  # The option-to-field mapping is shared with the other transcription
  # adapters (`ALLM.Providers.Support.TranscriptionAdapter.option_fields/2`).
  # Only a dropped `response_format` is logged: the other structural fields
  # are dropped silently.
  defp option_fields(options) do
    {fields, dropped} = TranscriptionSupport.option_fields(options, @structural_fields)

    if "response_format" in dropped do
      Logger.debug(fn ->
        "ALLM.Providers.OpenAI.Transcription: dropping reserved option \"response_format\"; " <>
          "the decoder reads only the json response shape."
      end)
    end

    fields
  end

  # ---------------------------------------------------------------------------
  # Internals — decoding and errors
  # ---------------------------------------------------------------------------

  defp decode_usage(%{"type" => "duration", "seconds" => seconds}) when is_number(seconds),
    do: {%Usage{}, seconds}

  defp decode_usage(%{"type" => "tokens"} = usage) do
    {%Usage{
       input_tokens: int_or_nil(usage["input_tokens"]),
       output_tokens: int_or_nil(usage["output_tokens"]),
       total_tokens: int_or_nil(usage["total_tokens"])
     }, nil}
  end

  defp decode_usage(_usage), do: {%Usage{}, nil}

  defp int_or_nil(n) when is_integer(n), do: n
  defp int_or_nil(_n), do: nil

  defp decode_language([%{"code" => code} | _]) when is_binary(code), do: code
  defp decode_language(_languages), do: nil

  @doc false
  # Public only so `ALLM.Providers.Support.TranscriptionAdapter.run_one_attempt/5`
  # can build the invalid-JSON error with this adapter's message.
  @impl ALLM.Providers.Support.TranscriptionAdapter
  @spec malformed_error(String.t(), keyword()) :: TranscriptionAdapterError.t()
  def malformed_error(detail, opts) do
    TranscriptionAdapterError.new(:malformed_response,
      provider: :openai,
      message: "could not decode OpenAI transcription response: " <> detail,
      metadata: HTTPResponse.build_metadata(%{}, opts)
    )
  end

  # A 413 carries `type: "server_error"` in its body, so the classifier keys
  # on status alone.
  defp classify_transcription_reason(status, _ra) when status in [401, 403],
    do: {:authentication_failed, nil}

  defp classify_transcription_reason(429, ra), do: {:rate_limited, ra}

  defp classify_transcription_reason(status, _ra) when status in [400, 404, 413, 422],
    do: {:invalid_request, nil}

  defp classify_transcription_reason(status, ra) when status in [500, 502, 503, 504],
    do: {:provider_unavailable, ra}

  defp classify_transcription_reason(_status, _ra), do: {:unknown, nil}

  # The OpenAI pattern (`Support.Redact.openai/1`): same provider, same key
  # shapes as the other OpenAI adapters.
  defp redact_key_material(message) when is_binary(message) do
    Redact.openai(message)
  end
end
