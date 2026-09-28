defmodule ALLM.Error.ClassificationAdapterError do
  @moduledoc """
  Errors returned by typed-classification adapters.

  Layer A — serializable (no PIDs, refs, funs, or raw API keys). Closed-enum
  exception struct carrying nine reasons: the moderation enum minus
  `:unsupported_feature` and `:batch_too_large`. A classification request
  has no optional fields an adapter could fail to express, and questions
  are not chunked across calls, so neither atom has anywhere to fire.

  ## Error reasons

  | Reason | HTTP status | Fires when |
  |--------|-------------|------------|
  | `:authentication_failed` | 401/403 | API key missing or invalid. Surface to the user; no retry. |
  | `:rate_limited` | 429 | Provider quota exceeded; `:retry_after_ms` populated when a `Retry-After` header is present. Retried automatically. |
  | `:invalid_request` | 400/404/422 | The provider rejected the body (for example an unknown model); an empty `:questions` map reaching a direct adapter call; a body that cannot be JSON-encoded; or a question over a provider limit, with `:metadata` naming the question and the limit. Fix the request; no retry. |
  | `:context_length_exceeded` | 400 | The state plus the longest question exceeds the model's token budget. Shrink the state; no retry. |
  | `:provider_unavailable` | 500/502/503/504/529 | Provider server-side failure or overload. Retried automatically. |
  | `:timeout` | — | Adapter `request_timeout` exceeded. Retried automatically. |
  | `:network_error` | — | TCP/TLS/DNS failure. Retried automatically. |
  | `:malformed_response` | — | 200 with an unparseable body, a missing `answers` object, an answer for an id that was not asked, a requested id with no answer, or an answer whose type differs from its question's. No retry; report it to the provider. |
  | `:unknown` | any | Catch-all for shapes the adapter cannot classify; non-retryable. |

  ## `:cause` stays encodable

  Like its siblings this struct implements `Jason.Encoder`, so an adapter
  must never store a raw exception in `:cause`: an exception can carry the
  caller's data or a pid, and would make the error itself unencodable.
  Report the condition as data instead — a body that cannot be encoded is
  `reason: :invalid_request` with `metadata: %{cause: :unencodable_body}`,
  not the exception that the encoder raised.
  """

  @typedoc "Closed set of classification-adapter error reasons."
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

      iex> :provider_unavailable in ALLM.Error.ClassificationAdapterError.legal_reasons()
      true

      iex> length(ALLM.Error.ClassificationAdapterError.legal_reasons())
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
  Build a `%ClassificationAdapterError{}` from a `reason` atom and optional
  keyword fields.

  `opts` may include `:message`, `:provider`, `:status`, `:retry_after_ms`,
  `:cause`, and `:metadata`. When `:message` is omitted, the default is
  `"classification adapter error: \#{reason}"` — with a provider suffix
  `"classification adapter error (\#{provider}): \#{reason}"` when
  `:provider` is set.

  Raises `ArgumentError` if `reason` is not one of the atoms in the closed
  `t:reason/0` enum.

  ## Examples

      iex> err = ALLM.Error.ClassificationAdapterError.new(:timeout)
      iex> err.reason
      :timeout
      iex> Exception.message(err)
      "classification adapter error: timeout"

      iex> err = ALLM.Error.ClassificationAdapterError.new(:provider_unavailable, provider: :typesafe, status: 529)
      iex> Exception.message(err)
      "classification adapter error (typesafe): provider_unavailable"
  """
  @spec new(reason(), keyword()) :: t()
  def new(reason, opts \\ []) when is_atom(reason) do
    unless reason in @legal_reasons do
      raise ArgumentError,
            "unknown reason #{inspect(reason)} for ALLM.Error.ClassificationAdapterError " <>
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

  def message(%__MODULE__{}), do: "classification adapter error"

  defp default_message(reason, nil), do: "classification adapter error: #{reason}"

  defp default_message(reason, provider),
    do: "classification adapter error (#{provider}): #{reason}"

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

defimpl Jason.Encoder, for: ALLM.Error.ClassificationAdapterError do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
