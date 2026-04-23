defmodule ALLM.Tool do
  @moduledoc """
  A tool the model may call. See spec §5.2 and §15.

  Layer A — the struct itself is pure data (`:name`, `:description`, `:schema`,
  `:metadata` are all serializable), but `:handler` may be an anonymous
  function. A tool with a `fn` handler is **not** safe to persist via
  `:erlang.term_to_binary/1`; persist either `:handler | nil` and re-attach
  at load time, or use a `{Module, :function}` tuple.
  """

  @type schema :: map()

  @typedoc """
  Legal returns from a tool handler. See spec §5.2 and §12.3 (ask-user).
  """
  @type handler_result ::
          {:ok, term()}
          | {:error, term()}
          | {:ask_user, String.t()}
          | {:ask_user, String.t(), keyword()}
          | {:halt, atom(), term()}

  @typedoc """
  Tool handler — called with parsed arguments (arity 1) or with arguments
  plus a caller-supplied context keyword list (arity 2).
  """
  @type handler ::
          (map() -> handler_result())
          | (map(), keyword() -> handler_result())

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          schema: schema(),
          handler: handler() | nil,
          metadata: map()
        }

  @enforce_keys [:name, :description, :schema]
  defstruct [:name, :description, :schema, :handler, metadata: %{}]

  @doc """
  Build a `%Tool{}` from keyword opts.

  `:name`, `:description`, and `:schema` are required; omitting any raises
  `ArgumentError` via `struct!/2`. `:handler` is optional — a tool may be
  declared without a handler when the caller handles tool calls manually.

  ## Examples

      iex> tool = ALLM.Tool.new(name: "weather", description: "weather by city", schema: %{"type" => "object"})
      iex> tool.name
      "weather"
      iex> tool.handler
      nil
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      name: data["name"],
      description: data["description"],
      schema: data["schema"] || %{},
      handler: data["handler"],
      metadata: data["metadata"] || %{}
    }
  end
end

defimpl Jason.Encoder, for: ALLM.Tool do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
