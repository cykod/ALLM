defmodule ALLM.StepResult do
  @moduledoc "See spec §5.8."

  alias ALLM.{Message, Response, Thread}

  @type t :: %__MODULE__{
          thread: Thread.t(),
          response: Response.t(),
          tool_results: [Message.t()],
          done?: boolean(),
          metadata: map()
        }

  defstruct [
    :thread,
    :response,
    tool_results: [],
    done?: false,
    metadata: %{}
  ]
end
