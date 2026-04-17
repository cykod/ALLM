defmodule ALLM.Message do
  @moduledoc "See spec §5.1."

  @type role :: :system | :user | :assistant | :tool

  @type t :: %__MODULE__{
          role: role(),
          content: String.t() | [map() | struct()],
          name: String.t() | nil,
          tool_call_id: String.t() | nil,
          metadata: map()
        }

  defstruct [:role, :content, :name, :tool_call_id, metadata: %{}]
end
