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

  require Logger

  alias ALLM.{Audio, Keys, TranscriptionRequest, TranscriptionResponse, Usage}
  alias ALLM.Error.TranscriptionAdapterError
  alias ALLM.Providers.FakeTranscription
  alias ALLM.Providers.Support.OpenAIHeaders

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
      iex> {:ok, http} = ALLM.Providers.OpenAI.Transcription.prepare_request(req, api_key: "sk-x")
      iex> URI.to_string(http.url)
      "https://api.openai.com/v1/audio/transcriptions"
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
  # Names align with `openai/speech.ex` and the rest of the OpenAI family;
  # the error funnel is renamed per capability (`to_transcription_adapter_error/4`).
  # `to_multipart_body/2` returns `{:ok, fields} | {:error, _}`, the capability
  # family's shape (`openai/images.ex`'s `to_multipart_body/2`), because
  # building it reads the audio bytes, which can fail. The private helpers
  # mirror `openai/speech.ex`, including its four deliberate differences
  # from `openai/moderation.ex` (binary error bodies are JSON-decoded,
  # `sanitize_cause/1` resets every `Jason.DecodeError` offset, a non-map
  # `"error"` value is tolerated, and `apply_receive_timeout/2` replaces the
  # family's `maybe_apply_request_timeout/2` because it always applies a
  # default timeout). The one structural difference from the
  # speech sibling: there is no `ALLM.Retry.run/3` here, and
  # `run_one_attempt/3` never returns `{:retry, …}`.
  # ---------------------------------------------------------------------------

  @doc false
  # The three pre-flight gates, in their fixed order: resolvable -> size ->
  # filename. All run before `Keys.fetch!/2`.
  @spec gate_audio(TranscriptionRequest.t(), keyword()) ::
          :ok | {:error, TranscriptionAdapterError.t()}
  def gate_audio(%TranscriptionRequest{audio: audio}, opts) do
    with {:ok, count} <- measure(audio, opts),
         :ok <- gate_size(count, opts) do
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
    with {:ok, bytes} <- resolve_bytes(audio, opts),
         {:ok, name} <- upload_filename(audio, opts) do
      structural =
        [
          {"file",
           {bytes, filename: name, content_type: audio.mime_type || "application/octet-stream"}},
          {"model", request.model || @default_model},
          {"response_format", "json"}
        ] ++
          optional_field("language", request.language) ++ optional_field("prompt", request.prompt)

      {:ok, structural ++ option_fields(request.options)}
    end
  end

  def to_multipart_body(%TranscriptionRequest{}, opts),
    do: {:error, unresolvable_error(:invalid_source, opts)}

  @doc false
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
       request_id: Keyword.get(opts, :request_id) || header_value(headers, "x-request-id"),
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
  @spec to_transcription_adapter_error(
          non_neg_integer(),
          term(),
          Enumerable.t() | map(),
          keyword()
        ) :: TranscriptionAdapterError.t()
  def to_transcription_adapter_error(status, body, headers, opts) when is_integer(status) do
    error = body |> decode_error_body() |> error_object()
    {reason, retry_after} = classify_transcription_reason(status, retry_after_ms(headers))

    TranscriptionAdapterError.new(reason,
      provider: :openai,
      status: status,
      retry_after_ms: retry_after,
      message: provider_message(error, status),
      metadata:
        build_metadata(
          %{
            status: status,
            openai_code: redact_optional(Map.get(error, "code")),
            openai_type: redact_optional(Map.get(error, "type"))
          },
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
       provider: :openai,
       message: "audio is #{count} bytes, over max_audio_bytes #{@max_audio_bytes}",
       metadata: build_metadata(%{field: :audio, count: count, max: @max_audio_bytes}, opts)
     )}
  end

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
           metadata: build_metadata(%{field: :audio, mime_type: mime}, opts)
         )}
    end
  end

  defp unresolvable_error(cause, opts) do
    TranscriptionAdapterError.new(:invalid_request,
      provider: :openai,
      message: "audio bytes could not be resolved (#{inspect(cause)})",
      metadata: build_metadata(%{field: :audio, cause: cause}, opts)
    )
  end

  defp stub_error(opts) do
    TranscriptionAdapterError.new(:unknown,
      provider: :openai,
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
        |> maybe_apply_req_test_stub(opts)
        |> apply_receive_timeout(opts)

      {:ok, req}
    end
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
      provider: :openai,
      message: message,
      cause: sanitize_cause(cause),
      metadata: build_metadata(%{}, opts)
    )
  end

  # ---------------------------------------------------------------------------
  # Internals — multipart fields
  # ---------------------------------------------------------------------------

  defp resolve_bytes(%Audio{} = audio, opts) do
    case Audio.to_binary(audio) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, cause} -> {:error, unresolvable_error(cause, opts)}
    end
  end

  defp optional_field(_name, nil), do: []
  defp optional_field(name, value), do: [{name, value}]

  defp option_fields(options) when is_map(options) do
    stringified =
      Map.new(options, fn
        {k, v} when is_atom(k) -> {Atom.to_string(k), v}
        {k, v} -> {k, v}
      end)

    if Map.has_key?(stringified, "response_format") do
      Logger.debug(fn ->
        "ALLM.Providers.OpenAI.Transcription: dropping reserved option \"response_format\"; " <>
          "the decoder reads only the json response shape."
      end)
    end

    stringified
    |> Map.drop(@structural_fields)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {name, value} -> form_values(name, value) end)
  end

  defp option_fields(_options), do: []

  defp form_values(name, values) when is_list(values),
    do: Enum.flat_map(values, &form_values(name, &1))

  defp form_values(_name, nil), do: []
  defp form_values(name, value) when is_binary(value), do: [{name, value}]

  defp form_values(name, value) when is_number(value) or is_atom(value),
    do: [{name, to_string(value)}]

  defp form_values(name, value), do: [{name, Jason.encode!(value)}]

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

  defp malformed_error(detail, opts) do
    TranscriptionAdapterError.new(:malformed_response,
      provider: :openai,
      message: "could not decode OpenAI transcription response: " <> detail,
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

  # `Jason.DecodeError` carries the undecodable payload on `:data`; blanking
  # only that leaves `message/1` raising on the stale offset.
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
