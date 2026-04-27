defmodule ALLM.Error.ImageAdapterError do
  @moduledoc """
  Errors returned by `ALLM.ImageAdapter` implementations.

  Layer A — serializable (no PIDs, refs, funs, or raw API keys). See spec
  §35.3. Closed-enum exception struct mirroring `ALLM.Error.AdapterError`'s
  shape with one image-specific atom (`:unsupported_operation`).

  See Phase 14.1 design Decision #4 for the closed reason enum and the
  per-reason recovery table.

  ## Error reasons

  | Reason | HTTP status | Fires when |
  |--------|-------------|------------|
  | `:authentication_failed` | 401 | API key missing or invalid. |
  | `:rate_limited` | 429 | Provider quota exceeded; `:retry_after_ms` populated when a `Retry-After` header is present. |
  | `:invalid_request` | 400 | Request shape rejected (unsupported size, invalid prompt, etc.). |
  | `:content_filter` | 400 | Provider safety system rejected the prompt or output. |
  | `:context_length_exceeded` | 400 | Textual prompt exceeds the model's context window. |
  | `:provider_unavailable` | 5xx | Provider server-side failure; retryable. |
  | `:timeout` | — | Adapter `request_timeout` exceeded. |
  | `:network_error` | — | TCP/TLS/DNS failure. |
  | `:malformed_response` | — | 200 with unparseable body. |
  | `:unsupported_feature` | — | Request combined features the adapter cannot express. |
  | `:unsupported_operation` | — | `request.operation not in supported_operations()`; `metadata.operation` carries the rejected atom. |
  | `:unknown` | any | Catch-all for shapes the adapter cannot classify; non-retryable. |
  """

  @typedoc "Closed set of image-adapter error reasons (spec §35.3, Phase 14.1 Decision #4)."
  @type reason ::
          :authentication_failed
          | :rate_limited
          | :invalid_request
          | :content_filter
          | :context_length_exceeded
          | :provider_unavailable
          | :timeout
          | :network_error
          | :malformed_response
          | :unsupported_feature
          | :unsupported_operation
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
    content_filter
    context_length_exceeded
    provider_unavailable
    timeout
    network_error
    malformed_response
    unsupported_feature
    unsupported_operation
    unknown
  )a

  @doc """
  Return the closed list of legal `:reason` atoms.

  ## Examples

      iex> :unsupported_operation in ALLM.Error.ImageAdapterError.legal_reasons()
      true

      iex> length(ALLM.Error.ImageAdapterError.legal_reasons())
      12
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
  Build an `%ImageAdapterError{}` from a `reason` atom and optional keyword fields.

  `opts` may include `:message`, `:provider`, `:status`, `:retry_after_ms`,
  `:cause`, and `:metadata`. When `:message` is omitted, the default is
  `"image adapter error: \#{reason}"` — with a provider suffix
  `"image adapter error (\#{provider}): \#{reason}"` when `:provider` is set.

  Raises `ArgumentError` if `reason` is not one of the atoms in the closed
  `t:reason/0` enum.

  ## Examples

      iex> err = ALLM.Error.ImageAdapterError.new(:timeout)
      iex> err.reason
      :timeout
      iex> Exception.message(err)
      "image adapter error: timeout"

      iex> err = ALLM.Error.ImageAdapterError.new(:unsupported_operation, metadata: %{operation: :edit})
      iex> err.metadata.operation
      :edit
  """
  @spec new(reason(), keyword()) :: t()
  def new(reason, opts \\ []) when is_atom(reason) do
    unless reason in @legal_reasons do
      raise ArgumentError,
            "unknown reason #{inspect(reason)} for ALLM.Error.ImageAdapterError " <>
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

  def message(%__MODULE__{}), do: "image adapter error"

  defp default_message(reason, nil), do: "image adapter error: #{reason}"
  defp default_message(reason, provider), do: "image adapter error (#{provider}): #{reason}"

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

defimpl Jason.Encoder, for: ALLM.Error.ImageAdapterError do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
