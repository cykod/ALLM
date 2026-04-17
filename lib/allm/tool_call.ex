defmodule ALLM.ToolCall do
  @moduledoc "See spec §5.3."

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          arguments: map(),
          raw_arguments: String.t() | nil,
          metadata: map()
        }

  defstruct [:id, :name, :arguments, :raw_arguments, metadata: %{}]
end
