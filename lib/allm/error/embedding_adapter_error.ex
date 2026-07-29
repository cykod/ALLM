defmodule ALLM.Error.EmbeddingAdapterError do
  @moduledoc """
  Errors returned by `ALLM.EmbeddingAdapter` implementations.

  Layer A — serializable (no PIDs, refs, funs, or raw API keys). Closed-enum
  exception struct mirroring `ALLM.Error.ImageAdapterError`'s shape with one
  embeddings-specific atom (`:batch_too_large`) and without the two image-only
  atoms (`:content_filter`, `:unsupported_operation`).

  ## Error reasons

  | Reason | HTTP status | Fires when |
  |--------|-------------|------------|
  | `:authentication_failed` | 401/403 | API key missing or invalid. Surface to the user; no retry. |
  | `:rate_limited` | 429 | Provider quota exceeded; `:retry_after_ms` populated when a `Retry-After` header is present. Retried automatically. |
  | `:invalid_request` | 400 | Request shape rejected, or an empty `:input` reaching a direct adapter call. Fix the request; no retry. |
  | `:context_length_exceeded` | 400 | A single input exceeds the model's token limit, or the batch exceeds a per-request token cap. Chunk smaller or shorten inputs; no retry. |
  | `:provider_unavailable` | 5xx | Provider server-side failure. Retried automatically. |
  | `:timeout` | — | Adapter `request_timeout` exceeded. Retried automatically. |
  | `:network_error` | — | TCP/TLS/DNS failure. Retried automatically. |
  | `:malformed_response` | — | 200 with an unparseable body, or an entry whose vector is empty. No retry; file a bug. |
  | `:unsupported_feature` | — | Request combined features the adapter cannot express (e.g. a reduced `:dimensions` on a model that has no such knob). `metadata.feature` carries the rejected field. No retry. |
  | `:batch_too_large` | — | `length(request.input) > max_batch_size()`; `metadata` carries `:count` and `:max`. Unreachable through `ALLM.embed/3`, which chunks; recoverable by chunking. |
  | `:unknown` | any | Catch-all for shapes the adapter cannot classify; non-retryable. |
  """

  @typedoc "Closed set of embedding-adapter error reasons."
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

      iex> :batch_too_large in ALLM.Error.EmbeddingAdapterError.legal_reasons
      true

      iex> length(ALLM.Error.EmbeddingAdapterError.legal_reasons)
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
  Build an `%EmbeddingAdapterError{}` from a `reason` atom and optional keyword
  fields.

  `opts` may include `:message`, `:provider`, `:status`, `:retry_after_ms`,
  `:cause`, and `:metadata`. When `:message` is omitted, the default is
  `"embedding adapter error: \#{reason}"` — with a provider suffix
  `"embedding adapter error (\#{provider}): \#{reason}"` when `:provider` is
  set.

  Raises `ArgumentError` if `reason` is not one of the atoms in the closed
  `t:reason/0` enum.

  ## Examples

      iex> err = ALLM.Error.EmbeddingAdapterError.new(:timeout)
      iex> err.reason
      :timeout
      iex> Exception.message(err)
      "embedding adapter error: timeout"

      iex> err = ALLM.Error.EmbeddingAdapterError.new(:batch_too_large, metadata: %{count: 3000, max: 2048})
      iex> err.metadata.max
      2048
  """
  @spec new(reason(), keyword()) :: t()
  def new(reason, opts \\ []) when is_atom(reason) do
    unless reason in @legal_reasons do
      raise ArgumentError,
            "unknown reason #{inspect(reason)} for ALLM.Error.EmbeddingAdapterError " <>
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

  def message(%__MODULE__{}), do: "embedding adapter error"

  defp default_message(reason, nil), do: "embedding adapter error: #{reason}"
  defp default_message(reason, provider), do: "embedding adapter error (#{provider}): #{reason}"

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

defimpl Jason.Encoder, for: ALLM.Error.EmbeddingAdapterError do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
