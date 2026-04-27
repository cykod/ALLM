defmodule ALLM.ImageRequest do
  @moduledoc """
  A request for image generation, editing, or variation. See spec §35.2.2.

  Layer A — pure serializable data. Three operations:

  - `:generate` — text-to-image; requires `:prompt`, `:input_images == []`.
  - `:edit` — modify one or two input images optionally with a `:mask`;
    requires `:prompt` and `length(:input_images) in 1..2`.
  - `:variation` — generate variants of one input image; requires
    `length(:input_images) == 1` and `:prompt in [nil, ""]`.

  Operation-arity rules are enforced by `ALLM.Validate.image_request/1`
  (Phase 13.3); construction via `new/1` does not validate.

  ## Sizes and qualities

  `:size` accepts `{w, h}` (positive integers), a binary like `"1024x1024"`,
  the atom `:auto`, or `nil`. JSON encodes the tuple as a 2-element array
  `[w, h]`; decode reconstructs the tuple from a 2-element list of positive
  integers, treats `"auto"` as `:auto`, and otherwise passes binaries
  through verbatim.

  `:quality` is the closed atom set `[:low, :standard, :high, :hd, :auto]`
  with a `String.t()` open arm — providers extend the set (`:hd` is
  dall-e-3-only; `:high` is gpt-image-1-only). The decoder restores known
  atoms; unknown binaries pass through verbatim.

  `:operation`, `:response_format`, `:style`, and `:background` are closed
  atom enums; an unknown value at decode time raises `ArgumentError` and
  surfaces as `{:_unknown, :atom_decode_failed}` per the serializer's rescue
  contract.
  """

  alias ALLM.{Image, Serializer}

  @type operation :: :generate | :edit | :variation
  @type size :: {pos_integer(), pos_integer()} | String.t() | :auto
  @type quality :: :low | :standard | :high | :hd | :auto | String.t()
  @type response_format :: :binary | :base64 | :url

  @type t :: %__MODULE__{
          operation: operation(),
          model: String.t() | nil,
          prompt: String.t() | nil,
          n: pos_integer(),
          size: size() | nil,
          quality: quality() | nil,
          style: :natural | :vivid | nil,
          background: :transparent | :opaque | nil,
          response_format: response_format(),
          input_images: [Image.t()],
          mask: Image.t() | nil,
          options: map(),
          metadata: map()
        }

  defstruct [
    :model,
    :prompt,
    :size,
    :quality,
    :style,
    :background,
    :mask,
    operation: :generate,
    n: 1,
    response_format: :binary,
    input_images: [],
    options: %{},
    metadata: %{}
  ]

  @doc """
  Build an `%ImageRequest{}` from keyword opts.

  Unknown keys raise `KeyError` via `struct!/2` (matches `ALLM.Request.new/2`
  precedent). No validation — call `ALLM.Validate.image_request/1` to check
  operation-arity and field rules.

  ## Examples

      iex> req = ALLM.ImageRequest.new(prompt: "a kestrel", size: {1024, 1024}, n: 2)
      iex> req.operation
      :generate
      iex> req.size
      {1024, 1024}
      iex> req.n
      2
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      operation: Serializer.to_atom_field(data["operation"]) || :generate,
      model: data["model"],
      prompt: data["prompt"],
      n: data["n"] || 1,
      size: decode_size(data["size"]),
      quality: decode_quality(data["quality"]),
      style: Serializer.to_atom_field(data["style"]),
      background: Serializer.to_atom_field(data["background"]),
      response_format: Serializer.to_atom_field(data["response_format"]) || :binary,
      input_images: Serializer.hydrate(data["input_images"] || []),
      mask: hydrate_mask(data["mask"]),
      options: data["options"] || %{},
      metadata: data["metadata"] || %{}
    }
  end

  # `:size` decoder — closed atom branch (`:auto`) + tuple branch + binary
  # fall-through. Mirrors `lib/allm/request.ex:94-99`'s `decode_tool_choice/1`
  # closed-set restoration with binary fall-through.
  defp decode_size(nil), do: nil
  defp decode_size("auto"), do: :auto

  defp decode_size([w, h]) when is_integer(w) and is_integer(h) and w > 0 and h > 0 do
    {w, h}
  end

  defp decode_size(other) when is_binary(other), do: other
  defp decode_size(other), do: other

  # `:quality` decoder — try the closed atom set, fall through to binary
  # verbatim (the `String.t()` arm of the type).
  defp decode_quality(nil), do: nil

  defp decode_quality(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp decode_quality(other), do: other

  defp hydrate_mask(nil), do: nil
  defp hydrate_mask(other), do: Serializer.hydrate(other)
end

defimpl Jason.Encoder, for: ALLM.ImageRequest do
  # `:size` is the only tuple-carrying field; pre-pass-transform `{w, h}`
  # into the JSON-array shape `[w, h]` before delegating to
  # `encode_tagged/2`. Mirrors `lib/allm/engine.ex:508`'s pattern for
  # tuple-carrying fields. Other size shapes (binary, `:auto`, nil) pass
  # through verbatim.
  def encode(%ALLM.ImageRequest{size: {w, h}} = value, opts) do
    transformed = %{value | size: [w, h]}
    ALLM.Serializer.encode_tagged(transformed, opts)
  end

  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
