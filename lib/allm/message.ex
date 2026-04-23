defmodule ALLM.Message do
  @moduledoc """
  A chat message. See spec §5.1.

  Layer A — pure serializable data. The `:role` atom is a closed union of
  `:system | :user | :assistant | :tool`; `:content` is either a binary or a
  list of structured parts (text/tool parts only in v0.2 — image parts are
  rejected by `ALLM.Validate.message/1` per spec §33).

  `:tool_call_id` is required when `role: :tool` so the model can match the
  tool result back to the call that produced it; this invariant is enforced
  by `ALLM.Validate.message/1` (sub-phase 1.4), not by the struct.

  Construct with `new/1` or directly via `%ALLM.Message{}`.
  """

  @typedoc "Message role — closed union per spec §5.1."
  @type role :: :system | :user | :assistant | :tool

  @type t :: %__MODULE__{
          role: role(),
          content: String.t() | [map() | struct()],
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
