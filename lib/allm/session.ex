defmodule ALLM.Session do
  @moduledoc """
  See spec §5.7 and §11.

  Struct and helpers only; orchestration (`start/3`, `reply/4`, streaming variants, …)
  is not yet implemented.
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
end
