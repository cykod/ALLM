defmodule ALLM.Thread do
  @moduledoc "See spec §5.6 and §14."

  alias ALLM.Message

  @type t :: %__MODULE__{
          messages: [Message.t()],
          metadata: map()
        }

  defstruct messages: [], metadata: %{}

  @spec new(keyword()) :: t()
  def new(opts \\ []), do: struct!(__MODULE__, opts)

  @spec from_messages([Message.t()]) :: t()
  def from_messages(messages), do: %__MODULE__{messages: messages}

  @spec add_message(t(), Message.t()) :: t()
  def add_message(%__MODULE__{messages: ms} = t, %Message{} = m),
    do: %{t | messages: ms ++ [m]}

  @spec add_messages(t(), [Message.t()]) :: t()
  def add_messages(%__MODULE__{messages: ms} = t, more),
    do: %{t | messages: ms ++ more}

  @spec add_system(t(), String.t()) :: t()
  def add_system(t, text), do: add_message(t, %Message{role: :system, content: text})

  @spec add_user(t(), String.t()) :: t()
  def add_user(t, text), do: add_message(t, %Message{role: :user, content: text})

  @spec add_assistant(t(), String.t()) :: t()
  def add_assistant(t, text), do: add_message(t, %Message{role: :assistant, content: text})

  @spec messages(t()) :: [Message.t()]
  def messages(%__MODULE__{messages: ms}), do: ms

  @spec last_message(t()) :: Message.t() | nil
  def last_message(%__MODULE__{messages: []}), do: nil
  def last_message(%__MODULE__{messages: ms}), do: List.last(ms)
end
