defmodule ALLM.Usage do
  @moduledoc """
  Token and cost usage for a single response. See spec §5.9a.

  Layer A — pure serializable data. Every numeric field is optional and
  `nil`-able because not every provider returns every counter. Costs are
  populated either by an adapter that knows its own pricing or (in Phase 9)
  by an optional `llm_db` integration.
  """

  @type cost :: float()

  @type t :: %__MODULE__{
          input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil,
          cached_input_tokens: non_neg_integer() | nil,
          reasoning_tokens: non_neg_integer() | nil,
          total_tokens: non_neg_integer() | nil,
          input_cost: cost() | nil,
          output_cost: cost() | nil,
          total_cost: cost() | nil,
          tool_usage: map(),
          extra: map()
        }

  defstruct [
    :input_tokens,
    :output_tokens,
    :cached_input_tokens,
    :reasoning_tokens,
    :total_tokens,
    :input_cost,
    :output_cost,
    :total_cost,
    tool_usage: %{},
    extra: %{}
  ]

  @doc """
  Build a `%Usage{}` from keyword opts.

  Every field is optional. Unknown keys raise `ArgumentError` via `struct!/2`.

  ## Examples

      iex> u = ALLM.Usage.new(input_tokens: 10, output_tokens: 20)
      iex> u.input_tokens
      10
      iex> u.tool_usage
      %{}
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc """
  Return the `:total_tokens` field when set, otherwise the sum of
  `:input_tokens + :output_tokens` when both are integers, otherwise `nil`.

  ## Examples

      iex> ALLM.Usage.total_tokens(ALLM.Usage.new(total_tokens: 42))
      42

      iex> ALLM.Usage.total_tokens(ALLM.Usage.new(input_tokens: 10, output_tokens: 20))
      30

      iex> ALLM.Usage.total_tokens(ALLM.Usage.new([]))
      nil
  """
  @spec total_tokens(t()) :: non_neg_integer() | nil
  def total_tokens(%__MODULE__{total_tokens: t}) when is_integer(t), do: t

  def total_tokens(%__MODULE__{input_tokens: i, output_tokens: o})
      when is_integer(i) and is_integer(o),
      do: i + o

  def total_tokens(%__MODULE__{}), do: nil

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      input_tokens: data["input_tokens"],
      output_tokens: data["output_tokens"],
      cached_input_tokens: data["cached_input_tokens"],
      reasoning_tokens: data["reasoning_tokens"],
      total_tokens: data["total_tokens"],
      input_cost: data["input_cost"],
      output_cost: data["output_cost"],
      total_cost: data["total_cost"],
      tool_usage: data["tool_usage"] || %{},
      extra: data["extra"] || %{}
    }
  end
end

defimpl Jason.Encoder, for: ALLM.Usage do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
