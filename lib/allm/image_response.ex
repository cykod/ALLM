defmodule ALLM.ImageResponse do
  @moduledoc """
  An image generation/edit/variation response — Layer A serializable data.

  Carries the resolved `:images` list, an
  `:usage` summary (`%ALLM.ImageUsage{}` — never `nil`), optional `:id` /
  `:request_id` / `:model` provider correlation fields, and an opaque
  `:raw` adapter-specific payload analogous to `ALLM.Response.raw`.

  ETF round-trip via `:erlang.term_to_binary/1` is total. JSON round-trip
  works whenever `:raw` is JSON-encodable; a non-encodable `:raw` raises
  `Jason.EncodeError` at encode time — the same caller-responsibility
  contract as `ALLM.Response.raw`.
  """

  alias ALLM.{Image, ImageUsage, Serializer}

  @type t :: %__MODULE__{
          id: String.t() | nil,
          request_id: String.t() | nil,
          model: String.t() | nil,
          images: [Image.t()],
          usage: ImageUsage.t(),
          raw: term(),
          metadata: map()
        }

  defstruct [
    :id,
    :request_id,
    :model,
    :raw,
    images: [],
    usage: %ImageUsage{},
    metadata: %{}
  ]

  @doc """
  Build an `%ImageResponse{}` from keyword opts.

  Unknown keys raise `KeyError` via `struct!/2`.

  ## Examples

      iex> resp = ALLM.ImageResponse.new(model: "gpt-image-1")
      iex> resp.images
      []
      iex> resp.usage.images
      0
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      id: data["id"],
      request_id: data["request_id"],
      model: data["model"],
      images: Serializer.hydrate(data["images"] || []),
      usage: hydrate_usage(data["usage"]),
      raw: data["raw"],
      metadata: data["metadata"] || %{}
    }
  end

  defp hydrate_usage(nil), do: %ImageUsage{}

  defp hydrate_usage(%{"__type__" => _} = tagged) do
    case Serializer.hydrate(tagged) do
      %ImageUsage{} = usage -> usage
      _ -> %ImageUsage{}
    end
  end

  defp hydrate_usage(other), do: other
end

defimpl Jason.Encoder, for: ALLM.ImageResponse do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
