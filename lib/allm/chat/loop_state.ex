defmodule ALLM.Chat.LoopState do
  @moduledoc false
  # Phase 7-internal — not exported. Shared by Chat.run/3 and Chat.stream/3's
  # Phase S state machine to ensure both paths construct ChatResult via
  # the same build_chat_result/1 helper.
  #
  # Uses `@type` (not `@opaque`) because the module is `@moduledoc false` —
  # opacity is for downstream consumers; @moduledoc false declares the
  # absence of downstream consumers, so @opaque blocks Dialyzer from
  # relating LoopState.t() to %LoopState{} pattern matches in Chat's
  # private helpers without adding any abstraction value.

  alias ALLM.{Engine, StepResult, Thread}

  @type t :: %__MODULE__{
          engine: Engine.t(),
          opts: keyword(),
          initial_thread: Thread.t(),
          thread: Thread.t(),
          steps: [StepResult.t()],
          halted_reason: atom() | nil,
          halt_metadata: map(),
          pending_question: String.t() | nil,
          pending_tool_call_id: String.t() | nil,
          step_index: non_neg_integer(),
          max_turns: pos_integer()
        }

  defstruct [
    :engine,
    :opts,
    :initial_thread,
    :thread,
    :max_turns,
    steps: [],
    halted_reason: nil,
    halt_metadata: %{},
    pending_question: nil,
    pending_tool_call_id: nil,
    step_index: 0
  ]
end
