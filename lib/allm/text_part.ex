defmodule ALLM.TextPart do
  @moduledoc """
  A text content part used in multimodal `ALLM.Message{:content}` lists. See
  spec §35.6.

  Layer A — pure serializable data. `:text` is the only required field;
  `:metadata` defaults to an empty map. The struct is opaque from the
  validator's point of view (`ALLM.Validate.message/1` accepts any
  `%TextPart{}` regardless of `:text` content — empty strings included).

  Multimodal callers build `%ALLM.Message{content: [...]}` by hand:

      iex> ALLM.Message.new(role: :user, content: [
      ...>   %ALLM.TextPart{text: "What is in this image?"},
      ...>   %ALLM.ImagePart{image: ALLM.Image.from_url("https://example.com/cat.png")}
      ...> ]).role
      :user

  ## Serializability

  ETF round-trip via `:erlang.term_to_binary/1` is total. JSON round-trip via
  `ALLM.Serializer` follows the standard `__type__`-tagged wire shape used by
  every Layer A struct.
  """

  @type t :: %__MODULE__{
          text: String.t(),
          metadata: map()
        }

  @enforce_keys [:text]
  defstruct [:text, metadata: %{}]

  @doc """
  Build a `%TextPart{}` from a string and optional keyword opts.

  Accepts an optional `:metadata` keyword (a map). Empty `text` is allowed —
  the validator does not reject empty TextParts; that is an upstream concern.

  ## Examples

      iex> ALLM.TextPart.new("hi")
      %ALLM.TextPart{text: "hi", metadata: %{}}

      iex> ALLM.TextPart.new("hi", metadata: %{source: :test}).metadata
      %{source: :test}
  """
  @spec new(String.t(), keyword()) :: t()
  def new(text, opts \\ []) when is_binary(text) and is_list(opts) do
    %__MODULE__{
      text: text,
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      text: data["text"],
      metadata: data["metadata"] || %{}
    }
  end
end

defimpl Jason.Encoder, for: ALLM.TextPart do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
