defmodule ALLM.ChatResult do
  @moduledoc """
  The result of a full chat loop — Layer A serializable data.

  Carries the final `:thread`, the `:final_response`, a list of per-turn
  `:steps`, and a `:halted_reason` atom indicating why the loop stopped.

  `halted_reason: :completed` means the loop terminated normally. Every
  other atom represents a halt — including `:max_turns`, `:halt_when`,
  `:ask_user`, `:tool_error`, `:cancelled`, and any custom atom a tool
  returned via `{:halt, atom, _}`. Use `halted?/1` to check.
  """

  alias ALLM.{Response, StepResult, Thread}

  @typedoc """
  Reason the chat loop halted. `:completed` is the normal-exit atom; every
  other value signals early termination. The type is open (`atom()` tail)
  so custom tool-halt reasons surface here without touching the enum.
  """
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

  @doc """
  Build a `%ChatResult{}` from keyword opts.

  Every field is optional. Unknown keys raise `ArgumentError` via `struct!/2`.

  ## Examples

      iex> cr = ALLM.ChatResult.new(halted_reason: :completed)
      iex> cr.halted_reason
      :completed
      iex> cr.steps
      []
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc """
  Return `true` when `halted_reason` is anything other than `:completed`.

  ## Examples

      iex> ALLM.ChatResult.halted?(ALLM.ChatResult.new(halted_reason: :completed))
      false

      iex> ALLM.ChatResult.halted?(ALLM.ChatResult.new(halted_reason: :max_turns))
      true
  """
  @spec halted?(t()) :: boolean()
  def halted?(%__MODULE__{halted_reason: :completed}), do: false
  def halted?(%__MODULE__{}), do: true

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      thread: hydrate_optional(data["thread"]),
      final_response: hydrate_optional(data["final_response"]),
      steps: ALLM.Serializer.hydrate(data["steps"] || []),
      halted_reason: ALLM.Serializer.to_atom_field(data["halted_reason"]),
      pending_question: data["pending_question"],
      pending_tool_call_id: data["pending_tool_call_id"],
      metadata: data["metadata"] || %{}
    }
  end

  defp hydrate_optional(nil), do: nil
  defp hydrate_optional(value), do: ALLM.Serializer.hydrate(value)
end

defimpl Jason.Encoder, for: ALLM.ChatResult do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
