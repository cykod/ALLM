defmodule ALLM.Error.EngineError do
  @moduledoc """
  Errors raised by engine-level operations before any adapter call.

  Layer A — serializable (no PIDs, refs, funs, or raw API keys). Refines spec
  §20's atom taxonomy into a first-class struct so every Layer B/C/D public
  function can return `{:error, %ALLM.Error.EngineError{}}` uniformly.

  See Phase 1 design §Sub-phase 1.1 for the closed reason enum.
  """

  @typedoc "Closed set of engine-level error reasons (spec §20, §35.4)."
  @type reason ::
          :missing_adapter
          | :missing_stream_adapter
          | :missing_model
          | :missing_key
          | :unknown_tool
          | :invalid_engine
          | :unsupported_response_format
          | :no_image_adapter

  @type t :: %__MODULE__{
          reason: reason(),
          message: String.t(),
          provider: atom() | nil,
          cause: term() | nil,
          metadata: map()
        }

  @legal_reasons ~w(
    missing_adapter
    missing_stream_adapter
    missing_model
    missing_key
    unknown_tool
    invalid_engine
    unsupported_response_format
    no_image_adapter
  )a

  defexception [:reason, :message, :provider, :cause, metadata: %{}]

  @doc """
  Build an `%EngineError{}` from a `reason` atom and optional keyword fields.

  `opts` may include `:message`, `:provider`, `:cause`, and `:metadata`. When
  `:message` is omitted, it defaults to `"engine error: \#{reason}"` so
  `Exception.message/1` always returns a non-empty binary.

  Raises `ArgumentError` if `reason` is not one of the atoms in the closed
  `t:reason/0` enum.

  ## Examples

      iex> err = ALLM.Error.EngineError.new(:missing_adapter)
      iex> err.reason
      :missing_adapter
      iex> Exception.message(err)
      "engine error: missing_adapter"

      iex> err = ALLM.Error.EngineError.new(:missing_key, provider: :openai, message: "OPENAI_API_KEY unset")
      iex> err.provider
      :openai
      iex> Exception.message(err)
      "OPENAI_API_KEY unset"
  """
  @spec new(reason(), keyword()) :: t()
  def new(reason, opts \\ []) when is_atom(reason) do
    unless reason in @legal_reasons do
      raise ArgumentError,
            "unknown reason #{inspect(reason)} for ALLM.Error.EngineError " <>
              "(legal: #{inspect(@legal_reasons)})"
    end

    message = Keyword.get(opts, :message) || default_message(reason)

    %__MODULE__{
      reason: reason,
      message: message,
      provider: Keyword.get(opts, :provider),
      cause: Keyword.get(opts, :cause),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @impl Exception
  def message(%__MODULE__{message: m}) when is_binary(m) and m != "", do: m
  def message(%__MODULE__{reason: r}) when is_atom(r) and not is_nil(r), do: default_message(r)
  def message(%__MODULE__{}), do: "engine error"

  defp default_message(reason), do: "engine error: #{reason}"

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      reason: ALLM.Serializer.to_atom_field(data["reason"]),
      message: data["message"],
      provider: ALLM.Serializer.to_atom_field(data["provider"]),
      cause: data["cause"],
      metadata: data["metadata"] || %{}
    }
  end
end

defimpl Jason.Encoder, for: ALLM.Error.EngineError do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
