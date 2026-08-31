defmodule ALLM.Error.ModerationAdapterError do
  @moduledoc """
  Errors returned by content-moderation adapter implementations.

  Layer A — serializable (no PIDs, refs, funs, or raw API keys). Closed-enum
  exception struct carrying the same eleven reasons as
  `ALLM.Error.EmbeddingAdapterError`.

  Two atoms that appear on `ALLM.Error.ImageAdapterError` are deliberately
  absent. There is no `:content_filter`: a moderation call is never itself
  content-filtered — classifying harmful text is the endpoint's whole
  purpose. There is no `:unsupported_operation` either, for the same reason
  it is absent from the embeddings sibling — moderation has no operations
  enum.

  ## Error reasons

  | Reason | HTTP status | Fires when |
  |--------|-------------|------------|
  | `:authentication_failed` | 401/403 | API key missing or invalid. Surface to the user; no retry. |
  | `:rate_limited` | 429 | Provider quota exceeded; `:retry_after_ms` populated when a `Retry-After` header is present. Retried automatically. |
  | `:invalid_request` | 400 | Request shape rejected, an empty `:input` reaching a direct adapter call, an unsupported image type, or an image over the provider's size cap. `:metadata` carries the specific detail. Fix the request; no retry. |
  | `:context_length_exceeded` | 400 | A single input exceeds the model's token limit. Shorten it; no retry. |
  | `:provider_unavailable` | 5xx | Provider server-side failure. Retried automatically. |
  | `:timeout` | — | Adapter `request_timeout` exceeded. Retried automatically. |
  | `:network_error` | — | TCP/TLS/DNS failure. Retried automatically. |
  | `:malformed_response` | — | 200 with an unparseable body, or a results entry missing its verdict. No retry; file a bug. |
  | `:unsupported_feature` | — | Request used a field this adapter cannot express; `metadata.feature` names it. No retry. |
  | `:batch_too_large` | — | `length(request.input) > max_batch_size()`; `metadata` carries `:count` and `:max`. Recoverable by chunking the input yourself. |
  | `:unknown` | any | Catch-all for shapes the adapter cannot classify; non-retryable. |
  """

  @typedoc "Closed set of moderation-adapter error reasons."
  @type reason ::
          :authentication_failed
          | :rate_limited
          | :invalid_request
          | :context_length_exceeded
          | :provider_unavailable
          | :timeout
          | :network_error
          | :malformed_response
          | :unsupported_feature
          | :batch_too_large
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
    unsupported_feature
    batch_too_large
    unknown
  )a

  @doc """
  Return the closed list of legal `:reason` atoms.

  ## Examples

      iex> :batch_too_large in ALLM.Error.ModerationAdapterError.legal_reasons()
      true

      iex> length(ALLM.Error.ModerationAdapterError.legal_reasons())
      11
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
  Build a `%ModerationAdapterError{}` from a `reason` atom and optional
  keyword fields.

  `opts` may include `:message`, `:provider`, `:status`, `:retry_after_ms`,
  `:cause`, and `:metadata`. When `:message` is omitted, the default is
  `"moderation adapter error: \#{reason}"` — with a provider suffix
  `"moderation adapter error (\#{provider}): \#{reason}"` when `:provider`
  is set.

  Raises `ArgumentError` if `reason` is not one of the atoms in the closed
  `t:reason/0` enum.

  ## Examples

      iex> err = ALLM.Error.ModerationAdapterError.new(:timeout)
      iex> err.reason
      :timeout
      iex> Exception.message(err)
      "moderation adapter error: timeout"

      iex> err = ALLM.Error.ModerationAdapterError.new(:batch_too_large, metadata: %{count: 500, max: 32})
      iex> err.metadata.max
      32
  """
  @spec new(reason(), keyword()) :: t()
  def new(reason, opts \\ []) when is_atom(reason) do
    unless reason in @legal_reasons do
      raise ArgumentError,
            "unknown reason #{inspect(reason)} for ALLM.Error.ModerationAdapterError " <>
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

  def message(%__MODULE__{}), do: "moderation adapter error"

  defp default_message(reason, nil), do: "moderation adapter error: #{reason}"
  defp default_message(reason, provider), do: "moderation adapter error (#{provider}): #{reason}"

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

defimpl Jason.Encoder, for: ALLM.Error.ModerationAdapterError do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
