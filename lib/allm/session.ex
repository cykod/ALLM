defmodule ALLM.Session do
  @moduledoc """
  A stateful, serializable chat session. See spec §5.7 and §11.

  Layer A — pure serializable data. Orchestration (`start/3`, `reply/4`,
  streaming variants, tool-result submission) is Layer D and lands in
  Phase 8; this module currently ships only the struct and a handful of
  append/read helpers.

  ## Status + `pending_*` fields

  The `:status` atom is a closed union:

    * `:idle` — the session is ready for a new user turn.
    * `:awaiting_user` — the loop halted mid-step requesting user input;
      `:pending_question` is a non-nil binary carrying the question and
      `:pending_tool_call_id` binds the answer to the originating tool call.
    * `:awaiting_tools` — the loop halted with pending tool calls the caller
      must execute; `:pending_tool_calls` is the non-empty list.
    * `:completed` — the loop terminated normally.
    * `:error` — an unrecoverable adapter or tool error occurred. By
      convention `metadata[:error]` holds the underlying `%ALLM.Error.*{}`
      struct for post-mortem inspection. `ALLM.Validate.session/1`
      (sub-phase 1.4) enforces this.

  ## `context` is caller-owned

  The `:context` field is a free-form `map()` the library threads through
  to arity-2 tool handlers (spec §5.2). The library does **not** walk or
  validate its contents — a caller stuffing `DateTime`, `Decimal`, an
  `Ecto.Repo` reference, or a callback module is legitimate.

  The Layer A serializability invariant is preserved **only for values the
  caller knows are serializable**. Stuffing a PID, ref, or anonymous
  function into `:context` will cause `:erlang.term_to_binary/1` to raise
  `ArgumentError` at persist time; this is the caller's responsibility,
  not the library's. See the Phase 1 design (non-obvious decision #8) for
  the rationale. A typed `serializable()` walk may land in v0.3.
  """

  alias ALLM.{Message, Thread, ToolCall}

  @type status :: :idle | :awaiting_user | :awaiting_tools | :completed | :error

  @type t :: %__MODULE__{
          id: String.t() | nil,
          thread: Thread.t(),
          status: status(),
          pending_tool_calls: [ToolCall.t()],
          pending_question: String.t() | nil,
          pending_tool_call_id: String.t() | nil,
          context: map(),
          metadata: map()
        }

  defstruct [
    :id,
    :pending_question,
    :pending_tool_call_id,
    thread: %Thread{},
    status: :idle,
    pending_tool_calls: [],
    context: %{},
    metadata: %{}
  ]

  @spec new(keyword()) :: t()
  def new(opts \\ []), do: struct!(__MODULE__, opts)

  @spec append(t(), Message.t()) :: t()
  def append(%__MODULE__{thread: thread} = s, %Message{} = m),
    do: %{s | thread: Thread.add_message(thread, m)}

  @spec append_user(t(), String.t()) :: t()
  def append_user(s, text), do: append(s, %Message{role: :user, content: text})

  @spec append_tool_result(t(), String.t(), String.t() | map()) :: t()
  def append_tool_result(s, tool_call_id, content) do
    append(s, %Message{role: :tool, tool_call_id: tool_call_id, content: content})
  end

  @spec pending_tool_calls(t()) :: [ToolCall.t()]
  def pending_tool_calls(%__MODULE__{pending_tool_calls: calls}), do: calls

  @spec messages(t()) :: [Message.t()]
  def messages(%__MODULE__{thread: thread}), do: Thread.messages(thread)

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      id: data["id"],
      thread: hydrate_thread(data["thread"]),
      status: ALLM.Serializer.to_atom_field(data["status"]) || :idle,
      pending_tool_calls: ALLM.Serializer.hydrate(data["pending_tool_calls"] || []),
      pending_question: data["pending_question"],
      pending_tool_call_id: data["pending_tool_call_id"],
      context: data["context"] || %{},
      metadata: data["metadata"] || %{}
    }
  end

  defp hydrate_thread(nil), do: %Thread{}
  defp hydrate_thread(value), do: ALLM.Serializer.hydrate(value)
end

defimpl Jason.Encoder, for: ALLM.Session do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
