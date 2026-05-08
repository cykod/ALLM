defmodule ALLM.StepResult do
  @moduledoc """
  The result of a single chat step — Layer A serializable data.

  Carries the updated `:thread`, the `:response` from the adapter, any
  `:tool_results` appended during this step, and a `:done?` flag
  indicating whether the chat loop should halt after this step.

  The `:done?` field uses a `?`-suffixed atom key — legal Elixir, and
  round-trips cleanly through `:erlang.term_to_binary/1` and tagged JSON
  encoding via `ALLM.Serializer`.
  """

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

  @doc """
  Build a `%StepResult{}` from keyword opts.

  Every field is optional but `:thread` and `:response` are usually set in
  real output. Unknown keys raise `ArgumentError` via `struct!/2`.

  ## Examples

      iex> sr = ALLM.StepResult.new(done?: true)
      iex> sr.done?
      true
      iex> sr.tool_results
      []
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      thread: hydrate_optional(data["thread"]),
      response: hydrate_optional(data["response"]),
      tool_results: ALLM.Serializer.hydrate(data["tool_results"] || []),
      done?: data["done?"] || false,
      metadata: data["metadata"] || %{}
    }
  end

  defp hydrate_optional(nil), do: nil
  defp hydrate_optional(value), do: ALLM.Serializer.hydrate(value)
end

defimpl Jason.Encoder, for: ALLM.StepResult do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
