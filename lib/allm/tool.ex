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

  The arity-2 keyword list carries call context. Standard keys provided by
  `ALLM.ToolExecutor.Default`:

  | Key | Type | Notes |
  |-----|------|-------|
  | `:context` | `term()` | The opaque value passed via `ALLM.chat(engine, thread, context: ...)` or `Session.reply(session, msg, context: ...)`. Caller-defined shape. |
  | `:session_id` | `String.t() \\| nil` | The `%Session{}.id` when invoked through the Session API; `nil` for stateless `chat/3` / `step/3`. |
  | `:tool_call` | `%ALLM.ToolCall{}` | The exact tool call the assistant emitted (`:id`, `:name`, `:arguments`). |
  | `:engine` | `%ALLM.Engine{}` | The engine driving the call — handlers needing to issue downstream LLM calls reuse it via `ALLM.generate/3` etc. |
  | `:request_id` | `String.t() \\| nil` | Telemetry-correlation id from the parent span. |

  Custom keys in `:context` are passed through unchanged. The arity-1 form
  is preferred when handlers don't need context; arity-2 is detected at
  dispatch time via `:erlang.fun_info(handler, :arity)`.
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
    # Phase 21.1 (F10): normalize atom keys to string keys recursively on
    # `:schema`. Adapters expect string-keyed JSON Schema; pre-21.1 atom
    # keys produced non-deterministic adapter wire shapes. The
    # fast-path returns the input map verbatim when keys are already strings.
    # Normalization helper lives in `ALLM.JsonSchema` so `ALLM.json_schema/3`
    # can reuse it (closes the asymmetry where tool schemas were normalized
    # but response-format schemas were not).
    opts = Keyword.update(opts, :schema, %{}, &ALLM.JsonSchema.normalize/1)
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
      # Phase 21.1: hydrator mirrors new/1's schema normalization so a
      # Tool deserialized from JSON/ETF has the same schema-key shape as
      # one constructed via `new/1`. Closes a round-trip asymmetry where
      # a hand-built or third-party-encoded atom-keyed schema would slip
      # in atom keys past the constructor gate.
      schema: ALLM.JsonSchema.normalize(data["schema"] || %{}),
      handler: data["handler"],
      manual: data["manual"] || false,
      metadata: data["metadata"] || %{}
    }
  end
end

defimpl Jason.Encoder, for: ALLM.Tool do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
