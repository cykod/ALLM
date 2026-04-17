defmodule ALLM.Usage do
  @moduledoc "See spec §5.9a."

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
end
