defmodule ALLM.ToolCall do
  @moduledoc """
  A provider-emitted tool call. See spec §5.3.

  Layer A — pure serializable data. Carries the provider-assigned `:id` the
  model uses to match the eventual tool-role message back to this call, the
  `:name` of the tool to invoke, and the parsed `:arguments` map. The original
  provider JSON is preserved on `:raw_arguments` so adapters that need the
  exact wire string (streaming reassembly, audit logs) can recover it.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          arguments: map(),
          raw_arguments: String.t() | nil,
          metadata: map()
        }

  @enforce_keys [:id, :name, :arguments]
  defstruct [:id, :name, :arguments, :raw_arguments, metadata: %{}]

  @doc """
  Build a `%ToolCall{}` from keyword opts.

  `:id`, `:name`, and `:arguments` are required; omitting any raises
  `ArgumentError` via `struct!/2`. Optional fields: `:raw_arguments`,
  `:metadata`.

  ## Examples

      iex> ALLM.ToolCall.new(id: "call_1", name: "weather", arguments: %{"city" => "SFO"})
      %ALLM.ToolCall{id: "call_1", name: "weather", arguments: %{"city" => "SFO"}, raw_arguments: nil, metadata: %{}}
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      id: data["id"],
      name: data["name"],
      arguments: data["arguments"] || %{},
      raw_arguments: data["raw_arguments"],
      metadata: data["metadata"] || %{}
    }
  end
end

defimpl Jason.Encoder, for: ALLM.ToolCall do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
