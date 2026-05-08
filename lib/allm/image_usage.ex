defmodule ALLM.ImageUsage do
  @moduledoc """
  Image-side usage and cost summary — Layer A serializable data.

  `:images` defaults to `0` so a freshly-constructed `%ImageUsage{}` reads
  as "no work done yet"; the `%ALLM.ImageResponse{}` struct's default
  `:usage` carries one of these rather than `nil`.

  ## Cost types

  Cost fields are typed `float | nil`. `ALLM.Usage.cost` is already
  `float`, so the chat and image cost types align; adopting `Decimal`
  solely for typed nil-or-number adds runtime weight without semantic
  gain. Float-summation drift on `total_cost = input_cost + output_cost`
  is bounded at ≤1 ULP, well below provider cent-level pricing precision.

  Providers that charge by image-count alone (dall-e-2, dall-e-3) populate
  `:images`, `:size`, `:quality`, and `:total_cost`. Providers that charge by
  tokens (gpt-image-1) additionally populate `:input_tokens` / `:output_tokens`
  / `:input_cost` / `:output_cost`.
  """

  @type t :: %__MODULE__{
          images: non_neg_integer(),
          size: String.t() | nil,
          quality: String.t() | nil,
          input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil,
          input_cost: float() | nil,
          output_cost: float() | nil,
          total_cost: float() | nil
        }

  defstruct [
    :size,
    :quality,
    :input_tokens,
    :output_tokens,
    :input_cost,
    :output_cost,
    :total_cost,
    images: 0
  ]

  @doc """
  Build an `%ImageUsage{}` from keyword opts.

  Unknown keys raise `KeyError` via `struct!/2`.

  ## Examples

      iex> u = ALLM.ImageUsage.new(images: 1, input_tokens: 100)
      iex> u.images
      1
      iex> u.input_tokens
      100
      iex> u.size
      nil
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      images: data["images"] || 0,
      size: data["size"],
      quality: data["quality"],
      input_tokens: data["input_tokens"],
      output_tokens: data["output_tokens"],
      input_cost: data["input_cost"],
      output_cost: data["output_cost"],
      total_cost: data["total_cost"]
    }
  end
end

defimpl Jason.Encoder, for: ALLM.ImageUsage do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
