defmodule ALLM.ImagePart do
  @moduledoc """
  An image content part used in multimodal `ALLM.Message{:content}` lists
  — Layer A serializable data.

  `:image` (an `%ALLM.Image{}`) is the only required field. `:detail` is
  a closed-set atom in `[:auto, :low, :high]` matching OpenAI's
  vision-detail wire field; `:auto` is the default and matches OpenAI's
  documented default. `:metadata` defaults to an empty map.

  ## Validation

  `ALLM.Validate.message/1` accepts any `%ImagePart{}` in a content
  list. Layer A does not enforce `:detail` membership — callers passing
  an unknown atom (e.g. `:medium`) round-trip cleanly through ETF but
  JSON decoding will surface `{:_unknown, :atom_decode_failed}` per the
  Serializer rescue contract.

  ## Serializability

  ETF round-trip via `:erlang.term_to_binary/1` is total. JSON round-trip via
  `ALLM.Serializer` follows the standard `__type__`-tagged wire shape; the
  embedded `%ALLM.Image{}` round-trips through its own encoder.

  See also `guides/vision.md`.
  """

  alias ALLM.Image

  @type detail :: :auto | :low | :high

  @type t :: %__MODULE__{
          image: Image.t(),
          detail: detail(),
          metadata: map()
        }

  @enforce_keys [:image]
  defstruct [:image, detail: :auto, metadata: %{}]

  @doc """
  Build an `%ImagePart{}` from an `%ALLM.Image{}` and optional keyword opts.

  Accepts `:detail` (one of `:auto | :low | :high`; default `:auto`) and
  `:metadata` (a map).

  ## Examples

      iex> img = ALLM.Image.from_url("https://example.com/cat.png")
      iex> ALLM.ImagePart.new(img).detail
      :auto

      iex> img = ALLM.Image.from_url("https://example.com/cat.png")
      iex> ALLM.ImagePart.new(img, detail: :high).detail
      :high
  """
  @spec new(Image.t(), keyword()) :: t()
  def new(%Image{} = image, opts \\ []) when is_list(opts) do
    %__MODULE__{
      image: image,
      detail: Keyword.get(opts, :detail, :auto),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      image: ALLM.Serializer.hydrate(data["image"]),
      detail: ALLM.Serializer.to_atom_field(data["detail"]) || :auto,
      metadata: data["metadata"] || %{}
    }
  end
end

defimpl Jason.Encoder, for: ALLM.ImagePart do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
