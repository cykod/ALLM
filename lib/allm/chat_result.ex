defmodule ALLM.ChatResult do
  @moduledoc "See spec §5.9."

  alias ALLM.{Response, StepResult, Thread}

  @type halted_reason ::
          :completed
          | :max_turns
          | :halt_when
          | :ask_user
          | :tool_error
          | :cancelled
          | atom()

  @type t :: %__MODULE__{
          thread: Thread.t(),
          final_response: Response.t(),
          steps: [StepResult.t()],
          halted_reason: halted_reason(),
          pending_question: String.t() | nil,
          pending_tool_call_id: String.t() | nil,
          metadata: map()
        }

  defstruct [
    :thread,
    :final_response,
    :halted_reason,
    :pending_question,
    :pending_tool_call_id,
    steps: [],
    metadata: %{}
  ]
end
