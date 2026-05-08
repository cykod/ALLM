defmodule ALLM.Error.ToolError do
  @moduledoc """
  Errors from tool handler execution.

  Layer A — serializable. Note that `:cause` may carry a raised Exception
  struct, the exit reason, or an invalid term the handler returned. Callers
  should treat `:cause` as opaque and rely on `:reason` for programmatic
  dispatch.

  Note: the the documented contract atom `:tool_not_found` is represented here as
  `:not_found` because the module name already carries the "tool" context.

  See design §Sub- for the closed reason enum.
  """

  @typedoc "Closed set of tool-execution error reasons (spec §20)."
  @type reason ::
          :handler_raised
          | :handler_exit
          | :timeout
          | :invalid_return
          | :not_found
          | :encoding_failed

  @type t :: %__MODULE__{
          reason: reason(),
          message: String.t(),
          tool_name: String.t() | nil,
          tool_call_id: String.t() | nil,
          cause: term() | nil,
          metadata: map()
        }

  @legal_reasons ~w(
    handler_raised
    handler_exit
    timeout
    invalid_return
    not_found
    encoding_failed
  )a

  defexception [
    :reason,
    :message,
    :tool_name,
    :tool_call_id,
    :cause,
    metadata: %{}
  ]

  @doc """
  Build a `%ToolError{}` from a `reason` atom and optional keyword fields.

  `opts` may include `:message`, `:tool_name`, `:tool_call_id`, `:cause`, and
  `:metadata`. When `:message` is omitted, the default is
  `"tool error: \#{reason}"` — with a tool-name suffix
  `"tool error (\#{tool_name}): \#{reason}"` when `:tool_name` is set.

  Raises `ArgumentError` if `reason` is not one of the atoms in the closed
  `t:reason/0` enum.

  ## Examples

      iex> err = ALLM.Error.ToolError.new(:handler_raised)
      iex> err.reason
      :handler_raised
      iex> Exception.message(err)
      "tool error: handler_raised"

      iex> err = ALLM.Error.ToolError.new(:timeout, tool_name: "search_web", tool_call_id: "call_1")
      iex> err.tool_call_id
      "call_1"
      iex> Exception.message(err)
      "tool error (search_web): timeout"
  """
  @spec new(reason(), keyword()) :: t()
  def new(reason, opts \\ []) when is_atom(reason) do
    unless reason in @legal_reasons do
      raise ArgumentError,
            "unknown reason #{inspect(reason)} for ALLM.Error.ToolError " <>
              "(legal: #{inspect(@legal_reasons)})"
    end

    tool_name = Keyword.get(opts, :tool_name)
    message = Keyword.get(opts, :message) || default_message(reason, tool_name)

    %__MODULE__{
      reason: reason,
      message: message,
      tool_name: tool_name,
      tool_call_id: Keyword.get(opts, :tool_call_id),
      cause: Keyword.get(opts, :cause),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @impl Exception
  def message(%__MODULE__{message: m}) when is_binary(m) and m != "", do: m

  def message(%__MODULE__{reason: r, tool_name: name}) when is_atom(r) and not is_nil(r),
    do: default_message(r, name)

  def message(%__MODULE__{}), do: "tool error"

  defp default_message(reason, nil), do: "tool error: #{reason}"
  defp default_message(reason, name), do: "tool error (#{name}): #{reason}"

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      reason: ALLM.Serializer.to_atom_field(data["reason"]),
      message: data["message"],
      tool_name: data["tool_name"],
      tool_call_id: data["tool_call_id"],
      cause: data["cause"],
      metadata: data["metadata"] || %{}
    }
  end
end

defimpl Jason.Encoder, for: ALLM.Error.ToolError do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
