defmodule ALLM.ToolResultEncoder do
  @moduledoc "See spec §7.4."

  @callback encode(term()) :: String.t()
end
