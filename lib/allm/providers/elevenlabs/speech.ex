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

  `synthesize/2` honours `opts[:adapter_opts][:speech_script]`: when the key
  is present, the call is handed to `ALLM.Providers.FakeSpeech.synthesize/2`
  BEFORE any of this adapter's gates run. `prepare_request/2` returns a stub
  error under the same key.
  """

  @behaviour ALLM.SpeechAdapter
  @behaviour ALLM.Providers.Support.SpeechAdapter

  alias ALLM.{Audio, Keys, SpeechRequest, SpeechResponse, Usage}
  alias ALLM.Error.SpeechAdapterError
  alias ALLM.Providers.FakeSpeech
  alias ALLM.Providers.Support.ElevenLabs, as: Support
  alias ALLM.Providers.Support.HTTPResponse
  alias ALLM.Providers.Support.SpeechAdapter, as: SpeechSupport

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
  def url(%SpeechRequest{} = request, opts) do
    {:ok, %{output_format: output_format}} =
      Support.output_format(request.format, request.sample_rate)

    query =
      request.options
      |> SpeechSupport.stringify_keys()
      |> Map.get("query")
      |> query_params()
      |> Map.put("output_format", output_format)

    Support.base_url(opts) <>
      @endpoint <>
      URI.encode(request.voice || @default_voice, &URI.char_unreserved?/1) <>
      "?" <> URI.encode_query(query)
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
  # Internals — body and URL builders
  # ---------------------------------------------------------------------------

  defp put_nonempty(map, _key, value) when map_size(value) == 0, do: map
  defp put_nonempty(map, key, value), do: Map.put(map, key, value)

  defp query_params(query) when is_map(query) do
    query
    |> SpeechSupport.stringify_keys()
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.drop(["output_format"])
  end

  defp query_params(_query), do: %{}

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
