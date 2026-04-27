defmodule ALLM.Message do
  @moduledoc """
  A chat message. See spec §5.1 and §35.6.

  Layer A — pure serializable data. The `:role` atom is a closed union of
  `:system | :user | :assistant | :tool`; `:content` is either a binary or a
  list of `ALLM.TextPart.t() | ALLM.ImagePart.t()` structs (multimodal,
  v0.3 §35.6). The v0.2 `[map() | struct()]` shape is no longer accepted —
  raw maps in a content list are rejected by `ALLM.Validate.message/1` with
  `{:content, :invalid_part_type}` per Phase 14.4 Decision #11.

  `:tool_call_id` is required when `role: :tool` so the model can match the
  tool result back to the call that produced it; this invariant is enforced
  by `ALLM.Validate.message/1` (sub-phase 1.4), not by the struct.

  Construct with `new/1` or directly via `%ALLM.Message{}`.

  ## Multimodal example

      iex> img = ALLM.Image.from_url("https://example.com/cat.png")
      iex> ALLM.Message.new(role: :user, content: [
      ...>   %ALLM.TextPart{text: "What is in this image?"},
      ...>   %ALLM.ImagePart{image: img}
      ...> ]).role
      :user
  """

  @typedoc "Message role — closed union per spec §5.1."
  @type role :: :system | :user | :assistant | :tool

  @typedoc "Multimodal content — either a string or a list of TextPart/ImagePart structs (§35.6)."
  @type content :: String.t() | [ALLM.TextPart.t() | ALLM.ImagePart.t()]

  @type t :: %__MODULE__{
          role: role(),
          content: content(),
          name: String.t() | nil,
          tool_call_id: String.t() | nil,
          metadata: map()
        }

  @enforce_keys [:role, :content]
  defstruct [:role, :content, :name, :tool_call_id, metadata: %{}]

  @doc """
  Build a `%Message{}` from keyword opts.

  `:role` and `:content` are required; omitting either raises `ArgumentError`
  via `struct!/2`. Optional fields: `:name`, `:tool_call_id`, `:metadata`.

  `new/1` does **not** validate role/content invariants — use
  `ALLM.Validate.message/1` (sub-phase 1.4) for that.

  ## Examples

      iex> ALLM.Message.new(role: :user, content: "hi")
      %ALLM.Message{role: :user, content: "hi", name: nil, tool_call_id: nil, metadata: %{}}

      iex> ALLM.Message.new(role: :tool, content: "ok", tool_call_id: "call_1").tool_call_id
      "call_1"
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc """
  Lift a `String.t()` content value to a single-element `[%TextPart{}]` list,
  or pass an already-list content through unchanged.

  Used by chat-side adapters at the wire-shape boundary so the translator
  handles only the structured form. Does NOT mutate `Message.content` — this
  is a one-way normalization helper.

  ## Examples

      iex> ALLM.Message.normalize_content("hi")
      [%ALLM.TextPart{text: "hi", metadata: %{}}]

      iex> parts = [%ALLM.TextPart{text: "a"}, %ALLM.TextPart{text: "b"}]
      iex> ALLM.Message.normalize_content(parts) == parts
      true
  """
  @spec normalize_content(content()) :: [ALLM.TextPart.t() | ALLM.ImagePart.t()]
  def normalize_content(content) when is_binary(content),
    do: [%ALLM.TextPart{text: content}]

  def normalize_content(parts) when is_list(parts), do: parts

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      role: ALLM.Serializer.to_atom_field(data["role"]),
      content: ALLM.Serializer.hydrate(data["content"]),
      name: data["name"],
      tool_call_id: data["tool_call_id"],
      metadata: data["metadata"] || %{}
    }
  end
end

defimpl Jason.Encoder, for: ALLM.Message do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
