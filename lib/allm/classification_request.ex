defmodule ALLM.ClassificationRequest do
  @moduledoc """
  A typed-classification request — Layer A serializable data.

      iex> q = ALLM.ClassificationQuestion.choice("Which team?", ["billing", "technical"])
      iex> req = ALLM.ClassificationRequest.new(state: "My payouts failed.", questions: %{"department" => q})
      iex> ALLM.Validate.classification_request(req)
      :ok

  ## One state, many questions

  A request carries one `:state` — the thing being classified — and a map of
  named `:questions`. Every question is answered independently against the
  same state, and the response keys its answers by the same ids, so asking
  several questions in one request costs one call rather than several.

  `:state` is a string, a JSON object (map), or a JSON array (list). It is
  text only: images and audio are not part of the state union.

  ## Question ids are strings

  The keys of `:questions` must be non-empty binaries. Atom keys would not
  survive a JSON round trip, so `ALLM.Validate.classification_request/1`
  rejects them rather than letting a persisted request change shape.

  ## State encoding caveat

  A map `:state` with atom keys is sent with string keys and comes back
  from a JSON round trip with string keys — the same property every
  `metadata: map()` field has. Use string keys when the request will be
  persisted.

  ## Construction

  `new/1` is a bare `struct!/2` pass-through: unknown keys raise `KeyError`,
  and nothing is enforced. `state: nil` and `questions: %{}` are
  deliberately constructible so that the validator, not the constructor,
  rejects them.

  ## Other fields

  `:model` is `nil` by default and late-resolved. `:options` is the home for
  provider-specific opaque opts; an adapter that has no use for it ignores
  it and says so. `:metadata` is caller-owned.
  """

  alias ALLM.Serializer

  @typedoc "The input being classified: text, a JSON object, or a JSON array."
  @type state :: String.t() | map() | list()

  @type t :: %__MODULE__{
          state: state() | nil,
          questions: %{String.t() => ALLM.ClassificationQuestion.t()},
          model: String.t() | nil,
          options: map(),
          metadata: map()
        }

  defstruct [:state, :model, questions: %{}, options: %{}, metadata: %{}]

  @doc """
  Build a `%ClassificationRequest{}` from keyword opts.

  Unknown keys raise `KeyError` via `struct!/2`. No validation — call
  `ALLM.Validate.classification_request/1` to check the field rules.

  ## Examples

      iex> req = ALLM.ClassificationRequest.new()
      iex> {req.state, req.questions, req.model}
      {nil, %{}, nil}

      iex> req = ALLM.ClassificationRequest.new(state: %{"ticket" => "Refund please"}, model: "jev-1.13.0")
      iex> req.model
      "jev-1.13.0"
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      state: data["state"],
      questions: decode_questions(data["questions"] || %{}),
      model: data["model"],
      options: data["options"] || %{},
      metadata: data["metadata"] || %{}
    }
  end

  # Each question value is a tagged `%ClassificationQuestion{}`, so it goes
  # through `Serializer.hydrate/1` to come back as a struct. Keys are already
  # strings. A non-map value passes through verbatim rather than being
  # repaired, matching `ALLM.ModerationRequest`'s `decode_input/1`.
  defp decode_questions(questions) when is_map(questions),
    do: Map.new(questions, fn {id, q} -> {id, Serializer.hydrate(q)} end)

  defp decode_questions(other), do: other
end

defimpl Jason.Encoder, for: ALLM.ClassificationRequest do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
