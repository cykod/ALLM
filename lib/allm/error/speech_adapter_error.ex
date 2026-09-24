defmodule ALLM.Error.SpeechAdapterError do
  @moduledoc """
  Errors returned by speech-synthesis adapters.

  Layer A — serializable (no PIDs, refs, funs, or raw API keys). A
  closed-enum exception struct with nine reasons.

  There is no `:batch_too_large`: a speech request carries one input, and
  there is no multi-input form to overflow. There is no
  `:unsupported_feature` either, because no bundled speech adapter refuses a
  request field. An adapter that must refuse one adds the reason when it
  lands, which is additive for callers matching on the struct. There is no
  `:content_filter`, which only the transcription sibling
  `ALLM.Error.TranscriptionAdapterError` carries.

  ## Error reasons

  | Reason | HTTP status | Fires when |
  |--------|-------------|------------|
  | `:authentication_failed` | 401/403 | API key missing or invalid. Surface to the user; no retry. |
  | `:rate_limited` | 429 | Provider quota exceeded; `:retry_after_ms` populated when a `Retry-After` header is present. Retried automatically. |
  | `:invalid_request` | 400/404/413 | Request shape rejected, or an empty `:input` reaching a direct adapter call. `:metadata` carries the detail. Fix the request; no retry. |
  | `:context_length_exceeded` | 400 | `:input` is longer than the provider accepts; `:metadata` carries `:count` and `:max` when the adapter gates locally. Split the text; no retry. |
  | `:provider_unavailable` | 5xx | Provider server-side failure. Retried automatically. |
  | `:timeout` | — | Adapter `request_timeout` exceeded. Retried automatically. |
  | `:network_error` | — | TCP/TLS/DNS failure. Retried automatically. |
  | `:malformed_response` | — | 200 without the expected audio payload. No retry; file a bug. |
  | `:unknown` | any | Catch-all for shapes the adapter cannot classify; non-retryable. |
  """

  @typedoc "Closed set of speech-adapter error reasons."
  @type reason ::
          :authentication_failed
          | :rate_limited
          | :invalid_request
          | :context_length_exceeded
          | :provider_unavailable
          | :timeout
          | :network_error
          | :malformed_response
          | :unknown

  @type t :: %__MODULE__{
          reason: reason(),
          message: String.t(),
          provider: atom() | nil,
          status: pos_integer() | nil,
          retry_after_ms: non_neg_integer() | nil,
          cause: term() | nil,
          metadata: map()
        }

  @legal_reasons ~w(
    authentication_failed
    rate_limited
    invalid_request
    context_length_exceeded
    provider_unavailable
    timeout
    network_error
    malformed_response
    unknown
  )a

  @doc """
  Return the closed list of legal `:reason` atoms.

  ## Examples

      iex> :context_length_exceeded in ALLM.Error.SpeechAdapterError.legal_reasons()
      true

      iex> length(ALLM.Error.SpeechAdapterError.legal_reasons())
      9
  """
  @spec legal_reasons() :: [reason()]
  def legal_reasons, do: @legal_reasons

  defexception [
    :reason,
    :message,
    :provider,
    :status,
    :retry_after_ms,
    :cause,
    metadata: %{}
  ]

  @doc """
  Build a `%SpeechAdapterError{}` from a `reason` atom and optional keyword
  fields.

  `opts` may include `:message`, `:provider`, `:status`, `:retry_after_ms`,
  `:cause`, and `:metadata`. When `:message` is omitted, the default is
  `"speech adapter error: \#{reason}"` — with a provider suffix
  `"speech adapter error (\#{provider}): \#{reason}"` when `:provider` is
  set.

  Raises `ArgumentError` if `reason` is not one of the atoms in the closed
  `t:reason/0` enum.

  ## Examples

      iex> err = ALLM.Error.SpeechAdapterError.new(:timeout)
      iex> err.reason
      :timeout
      iex> Exception.message(err)
      "speech adapter error: timeout"

      iex> err = ALLM.Error.SpeechAdapterError.new(:context_length_exceeded, metadata: %{count: 4097, max: 4096})
      iex> err.metadata.max
      4096
  """
  @spec new(reason(), keyword()) :: t()
  def new(reason, opts \\ []) when is_atom(reason) do
    unless reason in @legal_reasons do
      raise ArgumentError,
            "unknown reason #{inspect(reason)} for ALLM.Error.SpeechAdapterError " <>
              "(legal: #{inspect(@legal_reasons)})"
    end

    provider = Keyword.get(opts, :provider)
    message = Keyword.get(opts, :message) || default_message(reason, provider)

    %__MODULE__{
      reason: reason,
      message: message,
      provider: provider,
      status: Keyword.get(opts, :status),
      retry_after_ms: Keyword.get(opts, :retry_after_ms),
      cause: Keyword.get(opts, :cause),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @impl Exception
  def message(%__MODULE__{message: m}) when is_binary(m) and m != "", do: m

  def message(%__MODULE__{reason: r, provider: p}) when is_atom(r) and not is_nil(r),
    do: default_message(r, p)

  def message(%__MODULE__{}), do: "speech adapter error"

  defp default_message(reason, nil), do: "speech adapter error: #{reason}"
  defp default_message(reason, provider), do: "speech adapter error (#{provider}): #{reason}"

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      reason: ALLM.Serializer.to_atom_field(data["reason"]),
      message: data["message"],
      provider: ALLM.Serializer.to_atom_field(data["provider"]),
      status: data["status"],
      retry_after_ms: data["retry_after_ms"],
      cause: data["cause"],
      metadata: data["metadata"] || %{}
    }
  end
end

defimpl Jason.Encoder, for: ALLM.Error.SpeechAdapterError do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
