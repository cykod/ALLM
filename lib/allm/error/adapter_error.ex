defmodule ALLM.Error.AdapterError do
  @moduledoc """
  Errors returned by `ALLM.Adapter` / `ALLM.StreamAdapter` implementations.

  Layer A — serializable (no PIDs, refs, funs, or raw API keys). Refines spec
  §20's atom taxonomy into a struct so provider adapters report failures with
  uniform shape.

  See Phase 1 design §Sub-phase 1.1 for the closed reason enum.
  """

  @typedoc "Closed set of adapter-level error reasons (spec §20)."
  @type reason ::
          :rate_limited
          | :authentication_failed
          | :invalid_request
          | :provider_unavailable
          | :context_length_exceeded
          | :content_filter
          | :timeout
          | :network_error
          | :malformed_response
          | :unsupported_feature
          | :unknown

  @type t :: %__MODULE__{
          reason: reason(),
          message: String.t(),
          provider: atom() | nil,
          status: non_neg_integer() | nil,
          retry_after_ms: non_neg_integer() | nil,
          request_id: String.t() | nil,
          cause: term() | nil,
          metadata: map()
        }

  @legal_reasons ~w(
    rate_limited
    authentication_failed
    invalid_request
    provider_unavailable
    context_length_exceeded
    content_filter
    timeout
    network_error
    malformed_response
    unsupported_feature
    unknown
  )a

  defexception [
    :reason,
    :message,
    :provider,
    :status,
    :retry_after_ms,
    :request_id,
    :cause,
    metadata: %{}
  ]

  @doc """
  Build an `%AdapterError{}` from a `reason` atom and optional keyword fields.

  `opts` may include `:message`, `:provider`, `:status`, `:retry_after_ms`,
  `:request_id`, `:cause`, and `:metadata`. When `:message` is omitted, the
  default is `"adapter error: \#{reason}"` — with a provider suffix
  `"adapter error (\#{provider}): \#{reason}"` when `:provider` is set.

  Raises `ArgumentError` if `reason` is not one of the atoms in the closed
  `t:reason/0` enum.

  ## Examples

      iex> err = ALLM.Error.AdapterError.new(:timeout)
      iex> err.reason
      :timeout
      iex> Exception.message(err)
      "adapter error: timeout"

      iex> err = ALLM.Error.AdapterError.new(:rate_limited, provider: :openai, retry_after_ms: 500)
      iex> err.retry_after_ms
      500
      iex> Exception.message(err)
      "adapter error (openai): rate_limited"
  """
  @spec new(reason(), keyword()) :: t()
  def new(reason, opts \\ []) when is_atom(reason) do
    unless reason in @legal_reasons do
      raise ArgumentError,
            "unknown reason #{inspect(reason)} for ALLM.Error.AdapterError " <>
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
      request_id: Keyword.get(opts, :request_id),
      cause: Keyword.get(opts, :cause),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @impl Exception
  def message(%__MODULE__{message: m}) when is_binary(m) and m != "", do: m

  def message(%__MODULE__{reason: r, provider: p}) when is_atom(r) and not is_nil(r),
    do: default_message(r, p)

  def message(%__MODULE__{}), do: "adapter error"

  defp default_message(reason, nil), do: "adapter error: #{reason}"
  defp default_message(reason, provider), do: "adapter error (#{provider}): #{reason}"

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      reason: ALLM.Serializer.to_atom_field(data["reason"]),
      message: data["message"],
      provider: ALLM.Serializer.to_atom_field(data["provider"]),
      status: data["status"],
      retry_after_ms: data["retry_after_ms"],
      request_id: data["request_id"],
      cause: data["cause"],
      metadata: data["metadata"] || %{}
    }
  end
end

defimpl Jason.Encoder, for: ALLM.Error.AdapterError do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
