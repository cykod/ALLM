defmodule ALLM.ClassificationAnswer do
  @moduledoc """
  The typed answer to one `ALLM.ClassificationQuestion` — Layer A
  serializable data.

      iex> a = ALLM.ClassificationAnswer.new(type: :choice, choice: "billing", confidence: 0.88)
      iex> ALLM.ClassificationAnswer.value(a)
      "billing"

  ## One struct, three shapes

  An answer is a tagged union carried in one struct: `:type` says which
  question type it answers, and that decides which fields are populated.

  | Field | `:choice` | `:score` | `:yes_no` |
  |-------|-----------|----------|-----------|
  | `:choice` | the chosen option name | `nil` | `nil` |
  | `:score` | `nil` | a float between `0.0` and the number of levels minus one | `nil` |
  | `:yes_probability` | `nil` | `nil` | a float between `0.0` and `1.0` |
  | `:probabilities` | a map of option name to probability, one key per option | a list of probabilities, one per level | `nil` |
  | `:legend` | `nil` | a list of level descriptions, one per level | `nil` |
  | `:confidence` | a float between `0.0` and `1.0` | a float between `0.0` and `1.0` | `nil` |

  `value/1` returns the headline field for each type.

  ## Why score lists, but choice maps

  Score levels are ordered, so `:probabilities` and `:legend` are lists where
  index = level: `Enum.at(answer.probabilities, 2)` is the probability of
  level 2. A list round-trips through JSON unchanged, whereas an
  integer-keyed map would come back with string keys. Choice options are
  caller-chosen names with no order, so their probabilities stay a
  string-keyed map.

  ## Confidence is reported, never computed

  `:confidence` is whatever the provider reports; ALLM does not derive it.
  A `:yes_no` answer carries `confidence: nil` because the probability is
  itself the answer. There is no built-in threshold either: the decision
  of what probability counts as "yes" belongs to the caller.

  ## Floats

  An adapter coerces every probability, score and confidence to a float
  when it decodes a provider response, since JSON `1` and `0` decode as
  integers. Decoding a persisted answer does not coerce: the maps and lists
  come back exactly as they were stored.

  ## Construction

  `:type` is enforced, so `new/1` without it raises `ArgumentError`. Unknown
  keys raise `KeyError`.
  """

  alias ALLM.Serializer

  @type t :: %__MODULE__{
          type: ALLM.ClassificationQuestion.question_type(),
          choice: String.t() | nil,
          score: float() | nil,
          yes_probability: float() | nil,
          probabilities: %{String.t() => float()} | [float()] | nil,
          legend: [term()] | nil,
          confidence: float() | nil,
          metadata: map()
        }

  @enforce_keys [:type]
  defstruct [
    :type,
    :choice,
    :score,
    :yes_probability,
    :probabilities,
    :legend,
    :confidence,
    metadata: %{}
  ]

  @doc """
  Build a `%ClassificationAnswer{}` from keyword opts.

  `:type` is required (`ArgumentError` without it); unknown keys raise
  `KeyError`.

  ## Examples

      iex> a = ALLM.ClassificationAnswer.new(type: :yes_no, yes_probability: 0.93)
      iex> {a.type, a.yes_probability, a.confidence}
      {:yes_no, 0.93, nil}
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc """
  The headline value: choice → option name, score → position, yes_no → P(yes).

  ## Examples

      iex> ALLM.ClassificationAnswer.value(ALLM.ClassificationAnswer.new(type: :score, score: 1.05))
      1.05

      iex> ALLM.ClassificationAnswer.value(ALLM.ClassificationAnswer.new(type: :yes_no, yes_probability: 0.2))
      0.2
  """
  @spec value(t()) :: String.t() | float()
  def value(%__MODULE__{type: :choice, choice: choice}), do: choice
  def value(%__MODULE__{type: :score, score: score}), do: score
  def value(%__MODULE__{type: :yes_no, yes_probability: p}), do: p

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      type: Serializer.to_atom_field(data["type"]),
      choice: data["choice"],
      score: data["score"],
      yes_probability: data["yes_probability"],
      # No float coercion here: a persisted answer round-trips as identity.
      probabilities: data["probabilities"],
      legend: data["legend"],
      confidence: data["confidence"],
      metadata: data["metadata"] || %{}
    }
  end
end

defimpl Jason.Encoder, for: ALLM.ClassificationAnswer do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
