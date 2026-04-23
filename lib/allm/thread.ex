defmodule ALLM.Thread do
  @moduledoc """
  An ordered message log. See spec §5.6 and §14.

  Layer A — pure serializable data. A thread is the canonical container
  for the message history threaded through a session or chat loop; it is
  append-only at the API surface (helpers build new threads rather than
  mutating an existing one).
  """

  alias ALLM.Message

  @type t :: %__MODULE__{
          messages: [Message.t()],
          metadata: map()
        }

  defstruct messages: [], metadata: %{}

  @doc """
  Build a `%Thread{}` from keyword opts.

  ## Examples

      iex> ALLM.Thread.new()
      %ALLM.Thread{messages: [], metadata: %{}}

      iex> ALLM.Thread.new(metadata: %{trace: "x"}).metadata
      %{trace: "x"}
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []), do: struct!(__MODULE__, opts)

  @doc """
  Build a thread from an existing list of messages.

  ## Examples

      iex> t = ALLM.Thread.from_messages([%ALLM.Message{role: :user, content: "hi"}])
      iex> length(t.messages)
      1
  """
  @spec from_messages([Message.t()]) :: t()
  def from_messages(messages), do: %__MODULE__{messages: messages}

  @doc """
  Append a single message to the end of the thread.

  ## Examples

      iex> t = ALLM.Thread.new() |> ALLM.Thread.add_message(%ALLM.Message{role: :user, content: "hi"})
      iex> length(t.messages)
      1
  """
  @spec add_message(t(), Message.t()) :: t()
  def add_message(%__MODULE__{messages: ms} = t, %Message{} = m),
    do: %{t | messages: ms ++ [m]}

  @doc """
  Append multiple messages to the end of the thread, preserving order.

  ## Examples

      iex> t = ALLM.Thread.new() |> ALLM.Thread.add_messages([
      ...>   %ALLM.Message{role: :user, content: "a"},
      ...>   %ALLM.Message{role: :assistant, content: "b"}
      ...> ])
      iex> Enum.map(t.messages, & &1.content)
      ["a", "b"]
  """
  @spec add_messages(t(), [Message.t()]) :: t()
  def add_messages(%__MODULE__{messages: ms} = t, more),
    do: %{t | messages: ms ++ more}

  @doc """
  Append a system-role message with the given text content.

  ## Examples

      iex> ALLM.Thread.new() |> ALLM.Thread.add_system("be nice") |> ALLM.Thread.last_message()
      %ALLM.Message{role: :system, content: "be nice", name: nil, tool_call_id: nil, metadata: %{}}
  """
  @spec add_system(t(), String.t()) :: t()
  def add_system(t, text), do: add_message(t, %Message{role: :system, content: text})

  @doc """
  Append a user-role message with the given text content.

  ## Examples

      iex> ALLM.Thread.new() |> ALLM.Thread.add_user("hi") |> ALLM.Thread.last_message()
      %ALLM.Message{role: :user, content: "hi", name: nil, tool_call_id: nil, metadata: %{}}
  """
  @spec add_user(t(), String.t()) :: t()
  def add_user(t, text), do: add_message(t, %Message{role: :user, content: text})

  @doc """
  Append an assistant-role message with the given text content.

  ## Examples

      iex> ALLM.Thread.new() |> ALLM.Thread.add_assistant("hello") |> ALLM.Thread.last_message()
      %ALLM.Message{role: :assistant, content: "hello", name: nil, tool_call_id: nil, metadata: %{}}
  """
  @spec add_assistant(t(), String.t()) :: t()
  def add_assistant(t, text), do: add_message(t, %Message{role: :assistant, content: text})

  @doc """
  Return the ordered list of messages in the thread.

  ## Examples

      iex> ALLM.Thread.messages(ALLM.Thread.new())
      []
  """
  @spec messages(t()) :: [Message.t()]
  def messages(%__MODULE__{messages: ms}), do: ms

  @doc """
  Return the last message in the thread, or `nil` when the thread is empty.

  ## Examples

      iex> ALLM.Thread.last_message(ALLM.Thread.new())
      nil

      iex> ALLM.Thread.new()
      ...> |> ALLM.Thread.add_user("first")
      ...> |> ALLM.Thread.add_user("last")
      ...> |> ALLM.Thread.last_message()
      ...> |> Map.get(:content)
      "last"
  """
  @spec last_message(t()) :: Message.t() | nil
  def last_message(%__MODULE__{messages: []}), do: nil
  def last_message(%__MODULE__{messages: ms}), do: List.last(ms)

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      messages: ALLM.Serializer.hydrate(data["messages"] || []),
      metadata: data["metadata"] || %{}
    }
  end
end

defimpl Jason.Encoder, for: ALLM.Thread do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
