defmodule ALLM.Tool do
  @moduledoc """
  A tool the model may call — Layer A serializable data plus an optional
  runtime `:handler`.

  The struct itself is pure data (`:name`, `:description`, `:schema`,
  `:metadata`, `:manual` are all serializable), but `:handler` may be an
  anonymous function. A tool with a `fn` handler is **not** safe to
  persist via `:erlang.term_to_binary/1`; persist either `:handler | nil`
  and re-attach at load time, or use a `{Module, :function}` tuple.

  ## Per-tool manual mode

  Setting `manual: true` declares this tool will not be auto-executed by
  `ALLM.chat/3` even when the call uses `mode: :auto`. When the assistant
  emits a tool call for a `manual: true` tool, the chat orchestrator halts
  the loop with `halted_reason: :manual_tool_calls` and surfaces the call
  in `metadata.manual_tool_calls`. The caller resolves the tool result
  either via `ALLM.Session.submit_tool_result/3` (when running through the
  `Session` API) or by appending a `:tool` message to the thread and
  re-issuing `ALLM.chat/3` (raw stateless flow).

  Default: `false` — the tool is auto-executed under `mode: :auto`. The
  flag is silent under whole-loop `mode: :manual`; the whole-loop
  short-circuit fires before the per-tool partition runs.

  See also `guides/tools.md`.
  """

  @type schema :: map()

  @typedoc """
  Legal returns from a tool handler.
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
          manual: boolean(),
          metadata: map()
        }

  @enforce_keys [:name, :description, :schema]
  defstruct [:name, :description, :schema, :handler, manual: false, metadata: %{}]

  @doc """
  Build a `%Tool{}` from keyword opts.

  `:name`, `:description`, and `:schema` are required; omitting any raises
  `ArgumentError` via `struct!/2`. `:handler` is optional — a tool may be
  declared without a handler when the caller handles tool calls manually.

  `:manual` is optional and defaults to `false`. It MUST be a boolean
  passing `:manual` with a non-boolean value (including `nil`) raises
  `ArgumentError`. The `defstruct` default protects against omission, but
  `struct!/2` accepts an explicit `nil` (silently overwriting the default),
  so this constructor adds an explicit guard.

  ## Examples

      iex> tool = ALLM.Tool.new(name: "weather", description: "weather by city", schema: %{"type" => "object"})
      iex> tool.name
      "weather"
      iex> tool.handler
      nil
      iex> tool.manual
      false

      iex> tool = ALLM.Tool.new(name: "charge", description: "charge a card", schema: %{"type" => "object"}, manual: true)
      iex> tool.manual
      true
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    tool = struct!(__MODULE__, opts)

    unless is_boolean(tool.manual) do
      raise ArgumentError,
            "ALLM.Tool :manual must be a boolean, got: #{inspect(tool.manual)}"
    end

    tool
  end

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      name: data["name"],
      description: data["description"],
      schema: data["schema"] || %{},
      handler: data["handler"],
      manual: data["manual"] || false,
      metadata: data["metadata"] || %{}
    }
  end
end

defimpl Jason.Encoder, for: ALLM.Tool do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
