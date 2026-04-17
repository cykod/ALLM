defmodule ALLM.ToolExecutor do
  @moduledoc "See spec §7.3."

  @callback execute(ALLM.Tool.t(), map(), keyword()) :: ALLM.Tool.handler_result()
end
