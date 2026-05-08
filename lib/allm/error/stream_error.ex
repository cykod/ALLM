defmodule ALLM.Error.StreamError do
  @moduledoc """
  Errors that surface mid-stream.

  Layer A — serializable. Typically wraps an underlying `%AdapterError{}` via
  the `:cause` field (`:reason` is `:adapter_error`) or carries the malformed
  term for `:malformed_event`.

  See design §Sub- for the closed reason enum.
  """

  @typedoc "Closed set of streaming-specific error reasons (spec §20)."
  @type reason ::
          :adapter_error
          | :cancelled
          | :timeout
          | :malformed_event
          | :unknown

  @type t :: %__MODULE__{
          reason: reason(),
          message: String.t(),
          provider: atom() | nil,
          event_index: non_neg_integer() | nil,
          cause: term() | nil,
          metadata: map()
        }

  @legal_reasons ~w(
    adapter_error
    cancelled
    timeout
    malformed_event
    unknown
  )a

  defexception [
    :reason,
    :message,
    :provider,
    :event_index,
    :cause,
    metadata: %{}
  ]

  @doc """
  Build a `%StreamError{}` from a `reason` atom and optional keyword fields.

  `opts` may include `:message`, `:provider`, `:event_index`, `:cause`, and
  `:metadata`. When `:message` is omitted, the default is
  `"stream error: \#{reason}"`.

  Raises `ArgumentError` if `reason` is not one of the atoms in the closed
  `t:reason/0` enum.

  ## Examples

      iex> err = ALLM.Error.StreamError.new(:cancelled)
      iex> err.reason
      :cancelled
      iex> Exception.message(err)
      "stream error: cancelled"

      iex> err = ALLM.Error.StreamError.new(:adapter_error, event_index: 3)
      iex> err.event_index
      3
  """
  @spec new(reason(), keyword()) :: t()
  def new(reason, opts \\ []) when is_atom(reason) do
    unless reason in @legal_reasons do
      raise ArgumentError,
            "unknown reason #{inspect(reason)} for ALLM.Error.StreamError " <>
              "(legal: #{inspect(@legal_reasons)})"
    end

    message = Keyword.get(opts, :message) || default_message(reason)

    %__MODULE__{
      reason: reason,
      message: message,
      provider: Keyword.get(opts, :provider),
      event_index: Keyword.get(opts, :event_index),
      cause: Keyword.get(opts, :cause),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @impl Exception
  def message(%__MODULE__{message: m}) when is_binary(m) and m != "", do: m
  def message(%__MODULE__{reason: r}) when is_atom(r) and not is_nil(r), do: default_message(r)
  def message(%__MODULE__{}), do: "stream error"

  defp default_message(reason), do: "stream error: #{reason}"

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      reason: ALLM.Serializer.to_atom_field(data["reason"]),
      message: data["message"],
      provider: ALLM.Serializer.to_atom_field(data["provider"]),
      event_index: data["event_index"],
      cause: data["cause"],
      metadata: data["metadata"] || %{}
    }
  end
end

defimpl Jason.Encoder, for: ALLM.Error.StreamError do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
