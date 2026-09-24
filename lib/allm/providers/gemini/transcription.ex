defmodule ALLM.Providers.Gemini.Transcription do
  # Attribute block sits ABOVE the @moduledoc because the moduledoc
  # interpolates these constants.

  @base_url "https://generativelanguage.googleapis.com/v1beta"

  # Adapter-injected default for a nil `:model` (stated in the public
  # `transcribe/2` doc and in `to_json_body/2`'s `@doc false`).
  @default_model "gemini-flash-latest"

  # Gemini has no transcription endpoint; this fixed instruction is the first
  # text part of every request.
  @transcription_instruction "Generate a verbatim transcript of this audio. Output only the transcript."

  # Gemini's inline-data limit is 20 MB on the whole REQUEST, and the audio
  # travels base64-encoded (4 bytes per 3). This is the largest raw clip whose
  # encoding still leaves 64 KiB for the instruction, hints and JSON framing.
  @max_audio_bytes div((20 * 1024 * 1024 - 64 * 1024) * 3, 4)

  # Req's own `receive_timeout` default (15 s) is too short for a 20 MB upload
  # that the model then has to listen to.
  @default_timeout_ms 120_000

  # MIME types sent as `inlineData.mimeType`, after `ALLM.Audio.normalize_mime/1`.
  # Probed 2026-09-24 (`scripts/record_gemini_audio_fixtures.exs`): mpeg, wav,
  # flac, aac and Ogg-encapsulated opus (sent as both `audio/opus` and
  # `audio/ogg`) were each transcribed correctly. `audio/aiff` is from
  # Google's docs and was not probed (no source clip).
  @accepted_mimes ~w(audio/wav audio/mpeg audio/aiff audio/aac audio/ogg audio/opus audio/flac)

  @moduledoc """
  Google Gemini speech-to-text adapter. Implements `ALLM.TranscriptionAdapter`
  against `generateContent`.

  Layer B — runtime. Wire it with
  `ALLM.Engine.new(transcription_adapter: ALLM.Providers.Gemini.Transcription)`
  and call it through `ALLM.transcribe/3`. The key resolves via
  `ALLM.Keys.fetch!(:gemini, opts)` after the pre-flight gates, so no key
  ever lives on the engine.

      req = ALLM.TranscriptionRequest.new(audio: ALLM.Audio.from_file("clip.mp3"))
      {:ok, resp} = ALLM.Providers.Gemini.Transcription.transcribe(req, api_key: "AIza...")
      resp.text

  ## Transcription is prompted chat

  Gemini has no transcription endpoint. This adapter sends the audio inline
  to a chat model together with a fixed instruction:

  > #{@transcription_instruction}

  The transcript is therefore a language model's answer, not the output of a
  dedicated speech model. It is usually verbatim, but it can paraphrase,
  tidy disfluencies, or refuse, where a Whisper-family model cannot. When
  exact wording matters, prefer `ALLM.Providers.OpenAI.Transcription`.

  > #### Silence is not reliably an empty transcript {: .warning}
  >
  > Given eight minutes of digital silence, the model returned a fluent,
  > invented transcript rather than `""` (observed 2026-09-24 on
  > `gemini-flash-latest`, which then resolved to `gemini-3.8-flash`). Do
  > not treat non-empty `:text` as proof that the clip contained speech.

  `:language` is added to the instruction as a one-sentence hint.
  `:prompt` is appended as a context block (names, spellings, subject
  matter); it is context, not a replacement for the instruction.

  ## Wire-field map

  | Concern | Gemini |
  |---------|--------|
  | Endpoint | `POST {base}/models/<model>:generateContent` |
  | Base URL | `#{@base_url}`, overridable via `adapter_opts[:endpoint]` |
  | Auth | `x-goog-api-key` header |
  | Body | `{"contents": [{"role": "user", "parts": [{"text": <instruction + hints>}, {"inlineData": {"mimeType", "data"}}]}]}` |
  | `model` | `:model`, or `#{@default_model}` when `nil`; a `models/` prefix is accepted |
  | Options | `ALLM.TranscriptionRequest.options` becomes `generationConfig` (e.g. `%{"temperature" => 0.0}`) |
  | Text | the `text` parts of the first candidate, concatenated; parts marked `"thought": true` are dropped |
  | Usage | `usageMetadata`: `promptTokenCount` → `:input_tokens`, `candidatesTokenCount` → `:output_tokens`, `thoughtsTokenCount` → `:reasoning_tokens`, `totalTokenCount` → `:total_tokens` |
  | Id | `responseId` → `:id` |
  | Correlation | none read; neither `x-request-id` nor `x-goog-request-id` came back on the recorded responses |
  | Size limit | 20 MB per request (documented), base64 included; see `max_audio_bytes/0` |
  | Unknown fields | **rejected** (400 `Unknown name`), so a mistyped `:options` key surfaces as `:invalid_request` |

  Accepted MIME types: #{Enum.map_join(@accepted_mimes, ", ", &"`#{&1}`")}.

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
    3. **MIME.** A `:mime_type` that is `nil` or not an accepted type →
       `:invalid_request` with `metadata.mime_type`. Parameters and case are
       ignored (`"audio/ogg; codecs=vorbis"` is sent as `audio/ogg`).

  ## Response

  `:text` is the transcript (`""` when the model returns no text). `:raw` is
  the provider body. `:model` is the model that was sent. `:language` and
  `:duration_seconds` are always `nil`: Gemini reports neither.
  `opts[:request_id]` is reflected onto `response.request_id`, and
  `request.metadata` round-trips onto `response.metadata`.

  **Truncation is not an error.** When the model stops at its output-token
  limit (`finishReason: "MAX_TOKENS"`), the partial transcript is returned as
  `{:ok, response}` with `response.metadata.finish_reason == :length`. Check
  for it on long clips.

  **Safety blocks are errors.** A candidate stopped for `SAFETY`,
  `RECITATION` or another content-policy reason, or a prompt blocked by
  `promptFeedback.blockReason`, returns `:content_filter`. Transcribing
  well-known recited material (song lyrics, famous speeches) can trip
  `RECITATION`.

  > #### There is no provider-side request id {: .info}
  >
  > Neither `x-request-id` nor `x-goog-request-id` came back on the
  > recorded responses, and this adapter reads no response header for a
  > request id, so `response.request_id` is `opts[:request_id]` or `nil`. Through `ALLM.transcribe/3` it is always
  > the façade's id (generated when the caller does not pass one). The
  > provider's `responseId` is on `response.id`.

  ## No retries

  This adapter makes **one** HTTP attempt per call and returns every
  classified error, retryable or not, as `{:error, _}`. Each attempt
  re-uploads the whole clip, so the only retry loop is `ALLM.transcribe/3`'s
  (3 attempts at the default policy). A direct `transcribe/2` caller who
  wants retries wraps the call.

  ## Errors

  | Wire | Reason |
  |------|--------|
  | 400 with `details[].reason == "API_KEY_INVALID"` | `:authentication_failed` |
  | 400 containing `exceeds the maximum number of tokens` or `input token count` | `:context_length_exceeded` |
  | other 400, 404 | `:invalid_request` |
  | 401, 403 | `:authentication_failed` |
  | 429 | `:rate_limited` (`retry_after_ms` from `Retry-After`) |
  | 500, 502, 503, 504 | `:provider_unavailable` |

  Gemini answers a bad key with a **400**, not a 401. This adapter reads the
  `API_KEY_INVALID` marker so a bad key is `:authentication_failed`.

  ## Error-struct hygiene

  No raw response body, request header or API-key value is copied into
  `%ALLM.Error.TranscriptionAdapterError{}`, and there is no body preview.
  The provider's message and `status` pass a redactor that replaces
  Google-shaped credentials (`AIza…` keys and `ya29.…` OAuth tokens) with
  `[REDACTED]`.

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

  alias ALLM.{Audio, Keys, TranscriptionRequest, TranscriptionResponse, Usage}
  alias ALLM.Error.TranscriptionAdapterError
  alias ALLM.Providers.{FakeTranscription, Gemini}
  alias ALLM.Providers.Support.GeminiHeaders

  @doc """
  Return the largest audio clip, in bytes, this adapter will send.

  Google documents a 20 MB limit on an inline request, and the clip travels
  base64-encoded, which adds a third. This cap is the largest raw size whose
  encoding fits 20 MiB with 64 KiB to spare for the instruction and JSON
  framing. It is conservative: a live probe on 2026-09-24 saw a clip at this
  cap accepted, and also a 15,831,040-byte clip (about 21.1 MB once
  encoded). Larger clips need Gemini's Files API, which this adapter does
  not use.

  ## Examples

      iex> ALLM.Providers.Gemini.Transcription.max_audio_bytes()
      15_679_488
  """
  @impl ALLM.TranscriptionAdapter
  @spec max_audio_bytes() :: pos_integer()
  def max_audio_bytes, do: @max_audio_bytes

  @doc """
  Transcribe `request.audio` with a Gemini model.

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

  **The transcript comes from a chat model.** See the module documentation
  for what that means for fidelity, truncation (`metadata.finish_reason`)
  and `:content_filter`.

  ## Examples

      iex> audio = ALLM.Audio.from_binary("ID3", "audio/mpeg")
      iex> req = ALLM.TranscriptionRequest.new(audio: audio)
      iex> opts = [adapter_opts: [transcription_script: [{:ok, "hello"}]]]
      iex> {:ok, resp} = ALLM.Providers.Gemini.Transcription.transcribe(req, opts)
      iex> resp.text
      "hello"

      iex> audio = ALLM.Audio.from_binary("webm", "audio/webm")
      iex> req = ALLM.TranscriptionRequest.new(audio: audio)
      iex> {:error, err} = ALLM.Providers.Gemini.Transcription.transcribe(req, [])
      iex> {err.reason, err.metadata.mime_type}
      {:invalid_request, "audio/webm"}
  """
  @impl ALLM.TranscriptionAdapter
  @spec transcribe(TranscriptionRequest.t(), keyword()) ::
          {:ok, TranscriptionResponse.t()} | {:error, TranscriptionAdapterError.t()}
  def transcribe(%TranscriptionRequest{} = request, opts) when is_list(opts) do
    case fetch_transcription_script(opts) do
      nil -> do_transcribe(request, opts)
      _script -> FakeTranscription.transcribe(request, with_own_cap(opts))
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
      iex> {:ok, http} = ALLM.Providers.Gemini.Transcription.prepare_request(req, api_key: "AIza-x")
      iex> URI.to_string(http.url)
      "https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-latest:generateContent"
  """
  @impl ALLM.TranscriptionAdapter
  @spec prepare_request(TranscriptionRequest.t(), keyword()) ::
          {:ok, Req.Request.t()} | {:error, TranscriptionAdapterError.t()}
  def prepare_request(%TranscriptionRequest{} = request, opts) when is_list(opts) do
    case fetch_transcription_script(opts) do
      nil -> with :ok <- gate_audio(request, opts), do: build_request(request, opts)
      _script -> {:error, stub_error(opts)}
    end
  end

  # ---------------------------------------------------------------------------
  # Public testing seams (`@doc false` + `@spec`).
  #
  # Names align with `ALLM.Providers.OpenAI.Transcription` (capability family):
  # `gate_audio/2`, `to_json_body/2`, `decode_response/4`,
  # `to_transcription_adapter_error/4`. `to_json_body/2` returns
  # `{:ok, map} | {:error, _}` rather than the bare map the chat and
  # embeddings JSON builders return, because building it base64-encodes the
  # audio bytes, which can fail to resolve. Like the OpenAI sibling there is
  # no `ALLM.Retry.run/3` here, and `run_one_attempt/3` never returns
  # `{:retry, …}`.
  # ---------------------------------------------------------------------------

  @doc false
  # The three pre-flight gates, in their fixed order: resolvable -> size ->
  # mime. All run before `Keys.fetch!/2`.
  @spec gate_audio(TranscriptionRequest.t(), keyword()) ::
          :ok | {:error, TranscriptionAdapterError.t()}
  def gate_audio(%TranscriptionRequest{audio: audio}, opts) do
    with {:ok, count} <- measure(audio, opts),
         :ok <- gate_size(count, opts),
         {:ok, _mime} <- wire_mime(audio, opts) do
      :ok
    end
  end

  @doc false
  # Adapter-injected default: `model` "gemini-flash-latest" when nil (the
  # public `transcribe/2` doc states it; the model travels in the URL, which
  # `build_request/2` derives). `request.options` become `generationConfig`.
  # The mime is the gate's own (`wire_mime/2`), so the builder never sends a
  # type the gate would refuse.
  #
  # The response decoder is this module's own, NOT
  # `ALLM.Providers.Gemini.Decode.candidate_parts/1`: that walker turns every
  # `inlineData` into an image part and keeps thought parts, and changing it
  # would change the chat and image paths it serves.
  @spec to_json_body(TranscriptionRequest.t(), keyword()) ::
          {:ok, map()} | {:error, TranscriptionAdapterError.t()}
  def to_json_body(%TranscriptionRequest{audio: %Audio{} = audio} = request, opts) do
    with {:ok, mime} <- wire_mime(audio, opts),
         {:ok, bytes} <- resolve_bytes(audio, opts) do
      parts = [
        %{"text" => instruction_text(request)},
        %{"inlineData" => %{"mimeType" => mime, "data" => Base.encode64(bytes)}}
      ]

      {:ok,
       put_generation_config(%{"contents" => [%{"role" => "user", "parts" => parts}]}, request)}
    end
  end

  def to_json_body(%TranscriptionRequest{}, opts),
    do: {:error, unresolvable_error(:invalid_source, opts)}

  @doc false
  @spec decode_response(term(), Enumerable.t() | map(), TranscriptionRequest.t(), keyword()) ::
          {:ok, TranscriptionResponse.t()} | {:error, TranscriptionAdapterError.t()}
  def decode_response(body, headers, request, opts)

  def decode_response(
        %{"candidates" => [candidate | _]} = body,
        _headers,
        %TranscriptionRequest{} = request,
        opts
      )
      when is_map(candidate) do
    case Gemini.parse_finish_reason(finish_reason_of(candidate)) do
      {:content_filter, raw_finish} ->
        {:error,
         content_filter_error(
           "Gemini stopped the transcript: #{raw_finish}",
           %{finish_reason: raw_finish},
           opts
         )}

      {finish, _raw} ->
        {:ok, build_response(body, candidate, finish, request, opts)}
    end
  end

  def decode_response(%{"promptFeedback" => %{"blockReason" => block}}, _headers, _request, opts)
      when is_binary(block) do
    {:error,
     content_filter_error("Gemini blocked the prompt: #{block}", %{block_reason: block}, opts)}
  end

  def decode_response(_body, _headers, _request, opts),
    do: {:error, malformed_error("no candidate in the response body", opts)}

  @doc false
  # `body` may be a decoded map or an undecodable binary. The status table is
  # the chat adapter's (`ALLM.Providers.Gemini.classify_error/3`), fed a
  # sanitised body so a non-map `"error"` cannot raise inside it. The one
  # rule added here: a 400 whose `details[].reason` is `API_KEY_INVALID` is
  # `:authentication_failed` (the released Gemini siblings still call it
  # `:invalid_request`).
  @spec to_transcription_adapter_error(
          non_neg_integer(),
          term(),
          Enumerable.t() | map(),
          keyword()
        ) :: TranscriptionAdapterError.t()
  def to_transcription_adapter_error(status, body, headers, opts) when is_integer(status) do
    error = body |> decode_error_body() |> error_object()
    message = provider_message(error, status)

    chat_error =
      Gemini.classify_error(status, %{"error" => Map.put(error, "message", message)}, headers)

    TranscriptionAdapterError.new(classify_reason(error, chat_error.reason),
      provider: :gemini,
      status: status,
      retry_after_ms: chat_error.retry_after_ms,
      message: message,
      metadata:
        build_metadata(
          %{status: status, google_status: redact_optional(Map.get(error, "status"))},
          opts
        )
    )
  end

  # ---------------------------------------------------------------------------
  # Internals — gates
  # ---------------------------------------------------------------------------

  defp fetch_transcription_script(opts) do
    opts
    |> Keyword.get(:adapter_opts, [])
    |> Keyword.get(:transcription_script)
  end

  defp with_own_cap(opts) do
    adapter_opts =
      opts
      |> Keyword.get(:adapter_opts, [])
      |> Keyword.put(:max_audio_bytes, @max_audio_bytes)

    Keyword.put(opts, :adapter_opts, adapter_opts)
  end

  defp measure(%Audio{} = audio, opts) do
    case Audio.size(audio) do
      {:ok, count} -> {:ok, count}
      {:error, cause} -> {:error, unresolvable_error(cause, opts)}
    end
  end

  defp measure(_audio, opts), do: {:error, unresolvable_error(:invalid_source, opts)}

  defp gate_size(count, _opts) when count <= @max_audio_bytes, do: :ok

  defp gate_size(count, opts) do
    {:error,
     TranscriptionAdapterError.new(:invalid_request,
       provider: :gemini,
       message: "audio is #{count} bytes, over max_audio_bytes #{@max_audio_bytes}",
       metadata: build_metadata(%{field: :audio, count: count, max: @max_audio_bytes}, opts)
     )}
  end

  # The gate and `to_json_body/2` share this, so the body builder can never
  # send a MIME type the gate would refuse.
  defp wire_mime(%Audio{mime_type: mime}, opts) do
    normalized = Audio.normalize_mime(mime)

    if normalized in @accepted_mimes do
      {:ok, normalized}
    else
      {:error,
       TranscriptionAdapterError.new(:invalid_request,
         provider: :gemini,
         message:
           "audio :mime_type #{inspect(mime)} is not a type Gemini accepts " <>
             "(#{Enum.join(@accepted_mimes, ", ")})",
         metadata: build_metadata(%{field: :audio, mime_type: mime}, opts)
       )}
    end
  end

  defp unresolvable_error(cause, opts) do
    TranscriptionAdapterError.new(:invalid_request,
      provider: :gemini,
      message: "audio bytes could not be resolved (#{inspect(cause)})",
      metadata: build_metadata(%{field: :audio, cause: cause}, opts)
    )
  end

  defp stub_error(opts) do
    TranscriptionAdapterError.new(:unknown,
      provider: :gemini,
      message: "prepare_request/2 has no analogue under the transcription_script short-circuit",
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
  # Internals — dispatch (one attempt, no retry loop)
  # ---------------------------------------------------------------------------

  defp do_transcribe(%TranscriptionRequest{} = request, opts) do
    with :ok <- gate_audio(request, opts),
         {:ok, http_req} <- build_request(request, opts) do
      run_one_attempt(http_req, request, opts)
    end
  end

  # `Keys.fetch!/2` raises `%EngineError{reason: :missing_key}` by documented
  # design and is not rescued. It runs AFTER `gate_audio/2`.
  defp build_request(%TranscriptionRequest{} = request, opts) do
    api_key = Keys.fetch!(:gemini, opts)

    with {:ok, body} <- to_json_body(request, opts) do
      req =
        Req.new(
          method: :post,
          url: endpoint_url(request, opts),
          headers: GeminiHeaders.headers(api_key),
          json: body,
          # One attempt per call: Req's own retry step must not re-upload.
          retry: false
        )
        |> maybe_apply_req_test_stub(opts)
        |> apply_receive_timeout(opts)

      {:ok, req}
    end
  end

  defp endpoint_url(%TranscriptionRequest{model: model}, opts) do
    "#{base_url(opts)}/models/#{strip_model_prefix(model || @default_model)}:generateContent"
  end

  defp strip_model_prefix("models/" <> rest), do: rest
  defp strip_model_prefix(model), do: model

  # The Gemini adapters honour `adapter_opts[:endpoint]` so callers can point
  # at a proxy. A non-binary value falls back to the default.
  defp base_url(opts) do
    case opts |> Keyword.get(:adapter_opts, []) |> Keyword.get(:endpoint) do
      url when is_binary(url) -> url
      _ -> @base_url
    end
  end

  defp maybe_apply_req_test_stub(req, opts) do
    case opts |> Keyword.get(:adapter_opts, []) |> Keyword.get(:plug) do
      nil -> req
      plug -> Req.merge(req, plug: plug)
    end
  end

  # Named after the OpenAI audio adapters' helper, not the family's
  # `maybe_apply_request_timeout/2`: without `opts[:request_timeout]` it
  # applies `@default_timeout_ms` rather than leaving `req` unchanged.
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
        {:error, to_transcription_adapter_error(status, body, headers, opts)}

      {:error, %{__struct__: Req.TransportError, reason: :timeout} = cause} ->
        {:error, transport_error(:timeout, "request timed out", cause, opts)}

      {:error, %{__struct__: Jason.DecodeError} = cause} ->
        {:error,
         %{malformed_error("response body is not valid JSON", opts) | cause: sanitize_cause(cause)}}

      {:error, exception} ->
        {:error,
         transport_error(
           :network_error,
           "transport failure: " <> Exception.message(exception),
           exception,
           opts
         )}
    end
  end

  defp transport_error(reason, message, cause, opts) do
    TranscriptionAdapterError.new(reason,
      provider: :gemini,
      message: message,
      cause: sanitize_cause(cause),
      metadata: build_metadata(%{}, opts)
    )
  end

  # ---------------------------------------------------------------------------
  # Internals — request body
  # ---------------------------------------------------------------------------

  defp resolve_bytes(%Audio{} = audio, opts) do
    case Audio.to_binary(audio) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, cause} -> {:error, unresolvable_error(cause, opts)}
    end
  end

  defp instruction_text(%TranscriptionRequest{language: language, prompt: prompt}) do
    @transcription_instruction <> language_hint(language) <> prompt_block(prompt)
  end

  defp language_hint(language) when is_binary(language),
    do: " The audio is in language #{inspect(language)}."

  defp language_hint(_language), do: ""

  defp prompt_block(prompt) when is_binary(prompt),
    do: "\n\nContext that may help with names and spelling (do not transcribe it):\n" <> prompt

  defp prompt_block(_prompt), do: ""

  defp put_generation_config(body, %TranscriptionRequest{options: options})
       when is_map(options) and map_size(options) > 0 do
    config =
      Map.new(options, fn
        {k, v} when is_atom(k) -> {Atom.to_string(k), v}
        {k, v} -> {k, v}
      end)

    Map.put(body, "generationConfig", config)
  end

  defp put_generation_config(body, _request), do: body

  # ---------------------------------------------------------------------------
  # Internals — response decoding
  # ---------------------------------------------------------------------------

  defp finish_reason_of(%{"finishReason" => reason}) when is_binary(reason), do: reason
  defp finish_reason_of(_candidate), do: nil

  defp build_response(body, candidate, finish, request, opts) do
    %TranscriptionResponse{
      text: candidate_text(candidate),
      id: string_or_nil(Map.get(body, "responseId")),
      request_id: Keyword.get(opts, :request_id),
      model: request.model || @default_model,
      provider: :gemini,
      usage: decode_usage(Map.get(body, "usageMetadata")),
      raw: body,
      metadata: finish_metadata(request.metadata, finish)
    }
  end

  defp finish_metadata(metadata, :length), do: Map.put(metadata, :finish_reason, :length)
  defp finish_metadata(metadata, _finish), do: metadata

  # Text parts only, in order; a part marked `"thought": true` is the model's
  # reasoning, not the transcript. A `thoughtSignature` on an answer part does
  # not make it a thought part.
  defp candidate_text(%{"content" => %{"parts" => parts}}) when is_list(parts) do
    for %{"text" => text} = part when is_binary(text) <- parts,
        Map.get(part, "thought") != true,
        into: "",
        do: text
  end

  defp candidate_text(_candidate), do: ""

  defp decode_usage(%{} = usage) do
    %Usage{
      input_tokens: int_or_nil(usage["promptTokenCount"]),
      output_tokens: int_or_nil(usage["candidatesTokenCount"]),
      reasoning_tokens: int_or_nil(usage["thoughtsTokenCount"]),
      total_tokens: int_or_nil(usage["totalTokenCount"])
    }
  end

  defp decode_usage(_usage), do: %Usage{}

  defp int_or_nil(n) when is_integer(n) and n >= 0, do: n
  defp int_or_nil(_n), do: nil

  defp string_or_nil(s) when is_binary(s), do: s
  defp string_or_nil(_s), do: nil

  defp content_filter_error(message, metadata, opts) do
    TranscriptionAdapterError.new(:content_filter,
      provider: :gemini,
      message: message,
      metadata: build_metadata(metadata, opts)
    )
  end

  defp malformed_error(detail, opts) do
    TranscriptionAdapterError.new(:malformed_response,
      provider: :gemini,
      message: "could not decode Gemini transcription response: " <> detail,
      metadata: build_metadata(%{}, opts)
    )
  end

  # ---------------------------------------------------------------------------
  # Internals — errors
  # ---------------------------------------------------------------------------

  defp classify_reason(error, chat_reason) do
    cond do
      api_key_invalid?(error) -> :authentication_failed
      chat_reason in TranscriptionAdapterError.legal_reasons() -> chat_reason
      true -> :unknown
    end
  end

  defp api_key_invalid?(%{"details" => details}) when is_list(details),
    do: Enum.any?(details, &match?(%{"reason" => "API_KEY_INVALID"}, &1))

  defp api_key_invalid?(_error), do: false

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
      _ -> "Gemini HTTP #{status}"
    end
  end

  defp redact_optional(value) when is_binary(value), do: redact_key_material(value)
  defp redact_optional(_value), do: nil

  # `Jason.DecodeError` carries the undecodable payload on `:data`; blanking
  # only that leaves `message/1` raising on the stale offset.
  defp sanitize_cause(%{__struct__: Jason.DecodeError} = cause),
    do: %{cause | data: "", position: 0, token: nil}

  defp sanitize_cause(cause), do: cause

  # Inherited from `ALLM.Providers.Gemini.Embeddings`: same provider, same
  # Google credential shapes (`AIza…` API keys and `ya29.…` OAuth tokens).
  defp redact_key_material(message) when is_binary(message) do
    String.replace(
      message,
      ~r/\b(?:AIza[A-Za-z0-9_\-]{6,}|ya29\.[A-Za-z0-9_\-.]{6,})/,
      "[REDACTED]"
    )
  end
end
