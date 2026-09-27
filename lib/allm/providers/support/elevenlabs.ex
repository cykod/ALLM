defmodule ALLM.Providers.Support.ElevenLabs do
  @moduledoc """
  The half of the ElevenLabs audio adapters that both of them share:
  the base URL, the auth header, the `output_format` mapping, error
  classification and key redaction.

  Layer B helper, used by `ALLM.Providers.ElevenLabs.Speech` and
  `ALLM.Providers.ElevenLabs.Transcription`. Each adapter wraps what this
  module returns in its own error struct.

  ## Output formats

  `output_format/2` is the only place that maps a request's `format` and
  `sample_rate` to ElevenLabs' `output_format` query value:

  | `format` | `sample_rate` accepted (`nil` picks the default) | `output_format` |
  |----------|---------------------------------------------------|-----------------|
  | `:mp3` or `nil` | 22050, 24000, 44100 (default) | `mp3_22050_32`, `mp3_24000_48`, `mp3_44100_128` |
  | `:opus` | 48000 (default) | `opus_48000_64` |
  | `:pcm` | 8000, 16000, 22050, 24000 (default), 32000, 44100, 48000 | `pcm_<rate>` |
  | `:wav` | the same rates as `:pcm`, 24000 by default | `wav_<rate>` |
  | `:ulaw` | 8000 (default) | `ulaw_8000` |
  | `:alaw` | 8000 (default) | `alaw_8000` |
  | `:aac`, `:flac` | none | ElevenLabs has no such output |

  `ulaw_8000` and `alaw_8000` are the only G.711 values ElevenLabs lists:
  its 403 `invalid_output_format` answer to an invented `ulaw_16000` names
  every accepted value, and no other `ulaw_` or `alaw_` rate is among them
  (observed 2026-09-27). The two answer with `audio/ulaw` and `audio/alaw`
  content types and headerless 8-bit samples.

  ElevenLabs gates some formats by subscription tier: `pcm_44100` and
  `wav_44100` need the Pro tier, and the provider answers them on a lower
  tier with a 403 (observed 2026-09-26), which `classify/2` reports as
  `:unsupported_feature`. The 24,000 Hz defaults for `:pcm` and `:wav` avoid
  that gate.

  ## Error classification

  `classify/2` reads the error envelope ElevenLabs sends,
  `{"detail": {"type", "code", "message", "status", "request_id", "param"?}}`
  (a 422 sends `detail` as a list of validation errors instead), and returns
  the ALLM reason. An invalid API key is answered with a **400** or a
  **401** depending on the key's shape (a hex-shaped key got a 400
  `invalid_api_key`, a mixed-case one a 401 `unauthorized`; observed
  2026-09-26), and both carry `detail.type: authentication_error`, so the
  body is read before the status.
  """

  alias ALLM.Providers.Support.HTTPResponse
  alias ALLM.Providers.Support.Redact
  alias ALLM.SpeechResponse

  @base_url "https://api.elevenlabs.io"

  @pcm_rates [8_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000]

  # format => {accepted rates, default rate}
  @rates %{
    mp3: {[22_050, 24_000, 44_100], 44_100},
    opus: {[48_000], 48_000},
    pcm: {@pcm_rates, 24_000},
    wav: {@pcm_rates, 24_000},
    ulaw: {[8_000], 8_000},
    alaw: {[8_000], 8_000}
  }

  @mp3_bitrates %{22_050 => 32, 24_000 => 48, 44_100 => 128}

  # `detail.code` / `detail.status` values that mean the account is out of
  # credit. Checked before any status row: quota is not a rate limit, and
  # retrying it only spends the next attempt.
  @quota_codes ["quota_exceeded", "insufficient_credits", "payment_required"]

  # A 403 with one of these means the account or the plan cannot use a
  # feature (a tier-gated `output_format` answers `subscription_required` /
  # `output_format_not_allowed`, observed 2026-09-26), or that ElevenLabs
  # does not know the `output_format` at all (`invalid_output_format` with
  # `type: validation_error`, observed 2026-09-27).
  @unsupported_codes [
    "feature_not_available",
    "insufficient_permissions",
    "subscription_required",
    "output_format_not_allowed",
    "invalid_output_format"
  ]

  # WebSocket error codes: the `error` value of a text-to-speech error frame
  # (observed 2026-09-27: `invalid_api_key`, `authentication_required`,
  # `voice_id_does_not_exist`) and the documented `message_type` values of
  # the realtime speech-to-text errors (observed 2026-09-27: `auth_error`
  # and `commit_throttled`), each with its reason.
  @ws_code_reasons Map.new(
                     [
                       {~w(invalid_api_key authentication_required auth_error unaccepted_terms),
                        :authentication_failed},
                       {@quota_codes, :invalid_request},
                       {~w(rate_limited commit_throttled queue_overflow resource_exhausted),
                        :rate_limited},
                       {~w(session_time_limit_exceeded), :context_length_exceeded},
                       {~w(input_error invalid_request chunk_size_exceeded
                           insufficient_audio_activity voice_id_does_not_exist), :invalid_request},
                       {~w(error transcriber_error), :provider_unavailable}
                     ]
                     |> Enum.flat_map(fn {codes, reason} -> Enum.map(codes, &{&1, reason}) end)
                   )

  @typedoc "The resolved output of `output_format/2`."
  @type output :: %{
          output_format: String.t(),
          format: :mp3 | :opus | :pcm | :wav | :ulaw | :alaw,
          mime_type: String.t(),
          sample_rate: pos_integer()
        }

  @doc false
  # The API host: `opts[:base_url]`, then `opts[:adapter_opts][:base_url]`
  # (so an engine can pin a data-residency host), then the global host.
  @spec base_url(keyword()) :: String.t()
  def base_url(opts) do
    Keyword.get(opts, :base_url) ||
      opts |> Keyword.get(:adapter_opts, []) |> Keyword.get(:base_url) ||
      @base_url
  end

  @doc false
  # The WebSocket host: `base_url/1` with its scheme swapped (`https` ->
  # `wss`, `http` -> `ws`; a `ws`/`wss` base URL is kept), so a test can
  # reach a local server through an `http://` base URL.
  @spec ws_base_url(keyword()) :: String.t()
  def ws_base_url(opts) do
    case base_url(opts) do
      "https://" <> rest -> "wss://" <> rest
      "http://" <> rest -> "ws://" <> rest
      other -> other
    end
  end

  @doc false
  # Caller-supplied URL query parameters: `query` with atom keys stringified,
  # `nil` values dropped and the `reserved` names (the ones the adapter
  # derives itself) removed. Anything but a map is no parameters.
  @spec query_params(term(), [String.t()]) :: %{optional(String.t()) => term()}
  def query_params(query, reserved) when is_map(query) do
    query
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.reject(fn {k, v} -> is_nil(v) or k in reserved end)
  end

  def query_params(_query, _reserved), do: %{}

  @doc false
  # ElevenLabs authenticates with the `xi-api-key` header, never a bearer
  # token. `Req`'s `:json` and `:form_multipart` steps add the content type.
  @spec headers(String.t()) :: [{String.t(), String.t()}]
  def headers(api_key) when is_binary(api_key), do: [{"xi-api-key", api_key}]

  @doc """
  Map a speech `format` and `sample_rate` to ElevenLabs' `output_format`.

  A `nil` format is `:mp3`, the provider's own default, and a `nil`
  `sample_rate` takes the format's default rate. Returns
  `{:error, {:format, format}}` for a format ElevenLabs cannot produce and
  `{:error, {:sample_rate, accepted}}` for a rate outside the format's set.

  ## Examples

      iex> ALLM.Providers.Support.ElevenLabs.output_format(nil, nil)
      {:ok, %{output_format: "mp3_44100_128", format: :mp3, mime_type: "audio/mpeg", sample_rate: 44_100}}

      iex> {:ok, out} = ALLM.Providers.Support.ElevenLabs.output_format(:pcm, 16_000)
      iex> out.output_format
      "pcm_16000"

      iex> ALLM.Providers.Support.ElevenLabs.output_format(:ulaw, nil)
      {:ok, %{output_format: "ulaw_8000", format: :ulaw, mime_type: "audio/basic", sample_rate: 8_000}}

      iex> ALLM.Providers.Support.ElevenLabs.output_format(:flac, nil)
      {:error, {:format, :flac}}

      iex> ALLM.Providers.Support.ElevenLabs.output_format(:opus, 24_000)
      {:error, {:sample_rate, [48_000]}}
  """
  @spec output_format(atom() | nil, pos_integer() | nil) ::
          {:ok, output()} | {:error, {:format, term()} | {:sample_rate, [pos_integer()]}}
  def output_format(nil, sample_rate), do: output_format(:mp3, sample_rate)

  def output_format(format, sample_rate) when is_map_key(@rates, format) do
    {accepted, default} = Map.fetch!(@rates, format)
    rate = sample_rate || default

    if rate in accepted do
      {:ok,
       %{
         output_format: wire_name(format, rate),
         format: format,
         # The one format -> MIME table is `ALLM.SpeechResponse`'s.
         mime_type: SpeechResponse.format_to_mime(format),
         sample_rate: rate
       }}
    else
      {:error, {:sample_rate, accepted}}
    end
  end

  def output_format(format, _sample_rate), do: {:error, {:format, format}}

  defp wire_name(:mp3, rate), do: "mp3_#{rate}_#{Map.fetch!(@mp3_bitrates, rate)}"
  defp wire_name(:opus, rate), do: "opus_#{rate}_64"
  defp wire_name(format, rate), do: "#{format}_#{rate}"

  @doc false
  # `{reason, metadata}` for a non-2xx response. `body` is the decoded JSON
  # (or an undecoded JSON binary). `metadata` holds the provider's own
  # `detail.code`, `detail.type` and `detail.status` (as `:provider_status`),
  # each redacted, or `nil` when absent.
  @spec classify(non_neg_integer(), term()) :: {atom(), map()}
  def classify(status, body) when is_integer(status) do
    meta = body |> detail() |> detail_metadata()
    {reason_for(status, meta), meta}
  end

  defp reason_for(status, meta) do
    cond do
      code_in?(meta, @quota_codes) -> :invalid_request
      status == 403 and code_in?(meta, @unsupported_codes) -> :unsupported_feature
      meta.type == "authentication_error" -> :authentication_failed
      true -> reason_for_status(status, meta)
    end
  end

  defp reason_for_status(status, _meta) when status in [401, 403], do: :authentication_failed
  defp reason_for_status(402, _meta), do: :invalid_request

  defp reason_for_status(400, meta) do
    if code_in?(meta, ["text_too_long"]), do: :context_length_exceeded, else: :invalid_request
  end

  defp reason_for_status(status, _meta) when status in [404, 409, 413, 422], do: :invalid_request
  defp reason_for_status(429, _meta), do: :rate_limited
  defp reason_for_status(status, _meta) when status in 500..504, do: :provider_unavailable
  defp reason_for_status(_status, _meta), do: :unknown

  defp code_in?(meta, codes), do: meta.code in codes or meta.provider_status in codes

  @doc false
  # Everything an adapter needs to build its error struct for a non-2xx
  # response: `{reason, fields}` for `SpeechAdapterError.new/2` or
  # `TranscriptionAdapterError.new/2`. `Retry-After` is read only for the
  # two retryable reasons. Every provider-authored string is redacted.
  @spec error_fields(non_neg_integer(), term(), Enumerable.t() | map(), keyword()) ::
          {atom(), keyword()}
  def error_fields(status, body, headers, opts) when is_integer(status) do
    decoded = HTTPResponse.decode_json_error_body(body)
    {reason, meta} = classify(status, decoded)

    retry_after =
      if reason in [:rate_limited, :provider_unavailable],
        do: HTTPResponse.retry_after_ms(headers)

    {reason,
     [
       provider: :elevenlabs,
       status: status,
       retry_after_ms: retry_after,
       message: error_message(status, decoded),
       metadata: HTTPResponse.build_metadata(Map.put(meta, :status, status), opts)
     ]}
  end

  @doc false
  # `{reason, fields}` for an error a WebSocket session reports after the
  # upgrade: `payload` is the decoded error frame and `close_code` the code
  # of the close frame, when one arrived without an error frame (`nil`
  # otherwise). The two endpoints shape the frame differently (both
  # observed): text-to-speech sends `{"error": <code>, "message": <text>,
  # "code": 1008}`, realtime speech-to-text `{"message_type": <code>,
  # "error": <text>}`. So the code is `message_type` when present, else
  # `error`, and the text is `message`, else (beside a `message_type`)
  # `error`. `ws_reason/2` maps the code.
  @spec ws_error_fields(map(), non_neg_integer() | nil, keyword()) :: {atom(), keyword()}
  def ws_error_fields(payload, close_code, opts) when is_map(payload) do
    code = ws_code(payload)
    close_code = close_code || integer_or_nil(Map.get(payload, "code"))
    reason = ws_reason(code, close_code)

    message =
      case ws_message(payload) do
        text when is_binary(text) and text != "" -> redact_key_material(text)
        _ -> "ElevenLabs WebSocket error #{inspect(code || close_code)}"
      end

    {reason,
     [
       provider: :elevenlabs,
       message: message,
       metadata:
         HTTPResponse.build_metadata(
           %{
             code: HTTPResponse.redact_optional(code, &redact_key_material/1),
             close_code: close_code
           },
           opts
         )
     ]}
  end

  @doc false
  # Whether a decoded WebSocket server frame reports an error: it carries a
  # string `error` (both endpoints, observed 2026-09-27), or a
  # `message_type` that ends in `error` or is one of the classified error
  # codes (the documented realtime speech-to-text errors, some of which,
  # such as `commit_throttled`, do not end in `error`).
  @spec ws_error?(map()) :: boolean()
  def ws_error?(%{"error" => code}) when is_binary(code), do: true

  def ws_error?(%{"message_type" => type}) when is_binary(type),
    do: String.ends_with?(type, "error") or is_map_key(@ws_code_reasons, type)

  def ws_error?(_payload), do: false

  @doc false
  # The reason for a WebSocket error `code` (the `error` or `message_type`
  # value of an error frame), falling back on the close code. Observed
  # 2026-09-27: a bad key, a missing key and an unknown voice each answer
  # with an error frame `{"error", "message", "code": 1008}` and then close
  # 1008, so 1008 alone does not mean an authentication failure.
  @spec ws_reason(String.t() | nil, non_neg_integer() | nil) :: atom()
  def ws_reason(code, close_code) do
    case Map.fetch(@ws_code_reasons, code) do
      {:ok, reason} -> reason
      :error -> close_reason(close_code)
    end
  end

  defp close_reason(1008), do: :invalid_request
  defp close_reason(code) when is_integer(code), do: :network_error
  defp close_reason(_code), do: :unknown

  defp ws_code(payload) do
    case payload do
      %{"message_type" => code} when is_binary(code) -> code
      %{"error" => code} when is_binary(code) -> code
      _ -> nil
    end
  end

  defp ws_message(%{"message" => text}) when is_binary(text), do: text
  defp ws_message(%{"message_type" => _, "error" => text}) when is_binary(text), do: text
  defp ws_message(_payload), do: nil

  defp integer_or_nil(n) when is_integer(n), do: n
  defp integer_or_nil(_n), do: nil

  @doc false
  # Replaces an ElevenLabs API key (`sk_` followed by at least 16
  # alphanumerics) with `[REDACTED]`. ElevenLabs' own error bodies did not
  # echo the key on 2026-09-26; this is defence in depth for every
  # provider-authored string an error carries.
  @spec redact_key_material(String.t()) :: String.t()
  def redact_key_material(text) when is_binary(text), do: Redact.elevenlabs(text)

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp detail(%{"detail" => detail}), do: detail
  defp detail(_body), do: nil

  defp detail_metadata(detail) when is_map(detail) do
    %{
      code: HTTPResponse.redact_optional(Map.get(detail, "code"), &redact_key_material/1),
      type: HTTPResponse.redact_optional(Map.get(detail, "type"), &redact_key_material/1),
      provider_status:
        HTTPResponse.redact_optional(Map.get(detail, "status"), &redact_key_material/1)
    }
  end

  defp detail_metadata(_detail), do: %{code: nil, type: nil, provider_status: nil}

  defp error_message(status, decoded) do
    case detail(decoded) do
      %{"message" => message} when is_binary(message) ->
        redact_key_material(message)

      [_ | _] = errors ->
        errors |> Enum.map_join("; ", &validation_message/1) |> redact_key_material()

      _ ->
        "ElevenLabs HTTP #{status}"
    end
  end

  # One entry of a 422's `detail` list: `{"loc": ["body", "text"], "msg": …}`.
  defp validation_message(%{"msg" => msg} = entry) when is_binary(msg) do
    case Map.get(entry, "loc") do
      [_ | _] = loc -> Enum.map_join(loc, ".", &to_string/1) <> ": " <> msg
      _ -> msg
    end
  end

  # An entry without a string `msg` is described generically: its other keys
  # can echo the rejected input.
  defp validation_message(_other), do: "invalid field"
end
