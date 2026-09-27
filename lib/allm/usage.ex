defmodule ALLM.Usage do
  @moduledoc """
  Token and cost usage for a single response — Layer A serializable data.

  Every numeric field is optional and `nil`-able because not every
  provider returns every counter. Costs are populated either by an
  adapter that knows its own pricing or by an optional model-catalog
  integration.

  `nil` means the provider did not report a counter; `0` means it reported
  zero. The bundled chat adapters never replace a counter missing from the
  provider's response with `0` (pinned for every cache counter by
  `test/allm/providers/cache_usage_family_test.exs:112`).

  ## Cached prompt tokens

  `:input_tokens` is defined as the total prompt size: it includes the
  tokens served from the provider's prompt cache (`:cached_input_tokens`) and
  the tokens written to it on this call (`:cache_write_input_tokens`). So when
  all three are integers, `cached_input_tokens + cache_write_input_tokens <=
  input_tokens`, and `cached_input_tokens / input_tokens` is the cache hit
  ratio whichever provider served the call. The bundled OpenAI (both
  endpoints), Anthropic and Gemini adapters report these fields this way on
  streaming and non-streaming calls alike (pinned by
  `test/allm/providers/cache_usage_family_test.exs:99`).

  Costs do not distinguish cached tokens. `ALLM.Capability.populate_costs/2`
  prices every `:input_tokens` token at the model's plain input rate,
  including cached reads and cache writes, so `:input_cost` for a call with
  cache activity differs from what the provider bills. Cache-aware pricing is
  not implemented.

  ## Fields

  | Field | Type | Notes |
  |-------|------|-------|
  | `:input_tokens` | `non_neg_integer \\| nil` | Total prompt tokens, including cached reads and cache writes. |
  | `:output_tokens` | `non_neg_integer \\| nil` | |
  | `:cached_input_tokens` | `non_neg_integer \\| nil` | Prompt tokens served from the provider's prompt cache. |
  | `:cache_write_input_tokens` | `non_neg_integer \\| nil` | Prompt tokens written to the provider's prompt cache on this call. |
  | `:reasoning_tokens` | `non_neg_integer \\| nil` | Reasoning-model thinking tokens. |
  | `:total_tokens` | `non_neg_integer \\| nil` | |
  | `:input_cost` | `float \\| nil` | USD; populated when the adapter knows pricing. |
  | `:output_cost` | `float \\| nil` | |
  | `:total_cost` | `float \\| nil` | |
  | `:tool_usage` | `map` | Per-tool tally (caller-derived). |
  | `:extra` | `map` | Provider-specific spillover. |
  """

  @type cost :: float()

  @type t :: %__MODULE__{
          input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil,
          cached_input_tokens: non_neg_integer() | nil,
          cache_write_input_tokens: non_neg_integer() | nil,
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
    :cache_write_input_tokens,
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
      cache_write_input_tokens: data["cache_write_input_tokens"],
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
