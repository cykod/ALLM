defmodule ALLM.ModerationRequest do
  @moduledoc """
  A content-moderation request — Layer A serializable data.

      iex> req = ALLM.ModerationRequest.new(input: ["is this ok?"])
      iex> ALLM.ModerationRequest.multimodal?(req)
      false

  ## `:input` cardinality is type-dependent

  This is the one surprising thing about the moderation wire, and it is a
  property of the provider endpoint rather than an ALLM choice. `:input` is
  a list of items, where an item is either a `t:String.t/0` or an
  `t:ALLM.ImagePart.t/0`:

    * **All strings** — the request is a *batch* of `length(input)`
      independent items. A conforming adapter returns exactly that many
      results, with `:index` values `0..length-1`.
    * **Any `%ALLM.ImagePart{}` present** — the entire `:input` list is
      **one** multimodal item (text plus its images, judged together). A
      conforming adapter returns exactly **one** result, at `index: 0`.

  `multimodal?/1` reports which shape a request is in, so the result count
  is derivable *before* the call. There is no way to send several
  multimodal items in one call, which is why the two shapes share one
  field rather than being modelled separately.

  ## Construction

  `new/1` is a bare `struct!/2` pass-through: unknown keys raise
  `KeyError`, and nothing is enforced. `input: []` is deliberately
  *constructible* so that `ALLM.Validate.moderation_request/1` — not
  `struct!/2` — is what rejects it.

  ## Other fields

  `:model` is `nil` by default and late-resolved; an adapter that receives
  a `nil` model omits the field from the wire body rather than pinning a
  name. `:options` is the documented home for provider-specific opaque
  opts, and `:metadata` is caller-owned and round-tripped onto the
  response unchanged.
  """

  alias ALLM.{ImagePart, Serializer}

  @typedoc """
  One moderation input item: a string, or an image content part.

  The union is what makes the cardinality rule above type-dependent.
  """
  @type item :: String.t() | ALLM.ImagePart.t()

  @type t :: %__MODULE__{
          input: [item()],
          model: String.t() | nil,
          options: map(),
          metadata: map()
        }

  defstruct [:model, input: [], options: %{}, metadata: %{}]

  @doc """
  Build a `%ModerationRequest{}` from keyword opts.

  Unknown keys raise `KeyError` via `struct!/2`. No validation — call
  `ALLM.Validate.moderation_request/1` to check the field rules.

  ## Examples

      iex> req = ALLM.ModerationRequest.new()
      iex> req.input
      []
      iex> req.model
      nil

      iex> req = ALLM.ModerationRequest.new(input: ["a", "b"], model: "omni-moderation-latest")
      iex> length(req.input)
      2
      iex> req.model
      "omni-moderation-latest"
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc """
  True when any element of `:input` is an `t:ALLM.ImagePart.t/0` — see the
  cardinality rule in the module docs.

  A `%ModerationRequest{}` whose `:input` is not a list returns `false`
  rather than raising. That total contract is load-bearing: this function
  is read for telemetry metadata *before* validation runs, so it must have
  one behaviour for the whole "not a list" class rather than raising on
  `42` and returning `false` on `%{}`.

  ## Examples

      iex> ALLM.ModerationRequest.multimodal?(ALLM.ModerationRequest.new(input: ["text"]))
      false

      iex> part = ALLM.ImagePart.new(ALLM.Image.from_url("https://example.com/cat.png"))
      iex> req = ALLM.ModerationRequest.new(input: ["look at this", part])
      iex> ALLM.ModerationRequest.multimodal?(req)
      true
  """
  @spec multimodal?(t()) :: boolean()
  def multimodal?(%__MODULE__{input: input}) when is_list(input),
    do: Enum.any?(input, &is_struct(&1, ImagePart))

  def multimodal?(%__MODULE__{}), do: false

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      input: decode_input(data["input"] || []),
      model: data["model"],
      options: data["options"] || %{},
      metadata: data["metadata"] || %{}
    }
  end

  # `:input` is a union of binaries and `%ImagePart{}` structs, so the
  # `%ImagePart{}` arm has to route through `Serializer.hydrate/1` to come
  # back as a struct rather than a raw tagged map. `hydrate/1` is the item
  # decoder because it is already the identity on a binary. A non-list value
  # passes through verbatim rather than being repaired, matching
  # `ALLM.Embedding`'s `decode_vector/1` contract — `:flagged` on
  # `ALLM.ModerationResult` is the one field in this family that repairs.
  defp decode_input(list) when is_list(list), do: Enum.map(list, &Serializer.hydrate/1)
  defp decode_input(other), do: other
end

defimpl Jason.Encoder, for: ALLM.ModerationRequest do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
