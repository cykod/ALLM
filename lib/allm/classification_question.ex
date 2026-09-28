defmodule ALLM.ClassificationQuestion do
  @moduledoc """
  One typed question inside an `ALLM.ClassificationRequest` — Layer A
  serializable data.

      iex> q = ALLM.ClassificationQuestion.choice("Which team should handle this?", ["billing", "technical"])
      iex> q.type
      :choice
      iex> q.criteria
      %{"billing" => nil, "technical" => nil}

  ## Question types

  There are three, and a request may mix them freely:

    * `:choice` — pick exactly one option from a named set. The answer
      reports the chosen option plus a probability per option.
    * `:score` — place the input on an ordered scale of levels, low to high.
      The answer reports a (fractional) position on that scale.
    * `:yes_no` — the probability that the answer is "yes". Some providers
      use their own name for this type (TypeSafe calls it "noul"); ALLM
      always spells it `:yes_no`, and an adapter translates on the wire.

  ## Instructions and criteria

  `:instructions` is the question itself. It is a string, or a JSON object or
  array when the question is better expressed as structured data.

  `:criteria` depends on the type:

  | Type | `:criteria` |
  |------|-------------|
  | `:choice` | a map of option name to an optional description (`nil`, a string, or structured data) |
  | `:score` | a list of level descriptions, where index = level |
  | `:yes_no` | `nil`, or a map whose keys are among `"true"` and `"false"`, describing what each answer means |

  Use the builders `choice/2`, `score/2` and `yes_no/2`; they produce these
  shapes and stringify atom option names so the question survives a JSON
  round trip unchanged.

  ## Construction

  `new/1` is a bare `struct!/2` pass-through: unknown keys raise `KeyError`
  and nothing else is checked. The builders raise on a wrongly-typed
  argument (`FunctionClauseError`, or `ArgumentError` for an unknown
  `yes_no/2` option or colliding `choice/2` option names), but counts, emptiness and provider limits are left to
  `ALLM.Validate.classification_request/1`, so a hand-built struct and a
  builder-made one are judged by the same rules.
  """

  alias ALLM.Serializer

  @typedoc "A question type. `:yes_no` is ALLM's neutral name for a yes/no probability."
  @type question_type :: :choice | :score | :yes_no

  @typedoc "String, JSON object, or JSON array: structured instructions or criteria."
  @type structured :: String.t() | map() | list()

  @type t :: %__MODULE__{
          type: question_type() | nil,
          instructions: structured() | nil,
          criteria: %{String.t() => structured() | nil} | [structured()] | map() | nil
        }

  defstruct [:type, :instructions, :criteria]

  @doc """
  Build a `%ClassificationQuestion{}` from keyword opts.

  Unknown keys raise `KeyError` via `struct!/2`. No validation.

  ## Examples

      iex> q = ALLM.ClassificationQuestion.new(type: :yes_no, instructions: "Is this spam?")
      iex> {q.type, q.criteria}
      {:yes_no, nil}
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc """
  Choice over options.

  `options` is a list of names (each description is `nil`) or a map of
  name to description. Atom names are stringified. An `options` that is
  neither a list nor a map raises `FunctionClauseError`. A keyword list is
  still a list, so `choice(q, billing: "Payments")` treats each
  `{name, description}` pair as a name and raises `Protocol.UndefinedError` —
  pass a map for named descriptions. Two distinct names that become the same
  string (`:billing` and `"billing"`) raise `ArgumentError` rather than
  silently merging into one option; repeating the identical name in a list
  is harmless.

  ## Examples

      iex> q = ALLM.ClassificationQuestion.choice("Which team?", [:billing, "sales"])
      iex> q.criteria
      %{"billing" => nil, "sales" => nil}

      iex> q = ALLM.ClassificationQuestion.choice("Which team?", %{billing: "Payments and invoices"})
      iex> q.criteria
      %{"billing" => "Payments and invoices"}
  """
  @spec choice(structured(), [String.t() | atom()] | %{(String.t() | atom()) => structured() | nil}) ::
          t()
  def choice(instructions, options) when is_list(options) or is_map(options) do
    {criteria, given} =
      if is_list(options),
        do: {Map.new(options, &{to_string(&1), nil}), options |> Enum.uniq() |> length()},
        else: {Map.new(options, fn {name, desc} -> {to_string(name), desc} end), map_size(options)}

    if map_size(criteria) != given do
      raise ArgumentError,
            "choice/2 option names collide once atom names are stringified: #{inspect(options)}"
    end

    %__MODULE__{type: :choice, instructions: instructions, criteria: criteria}
  end

  @doc """
  Score on ordered levels, low to high. Level N is `Enum.at(levels, N)`.

  A non-list `levels` raises `FunctionClauseError`.

  ## Examples

      iex> q = ALLM.ClassificationQuestion.score("How frustrated is the customer?", ["Calm", "Frustrated", "Very angry"])
      iex> {q.type, Enum.at(q.criteria, 1)}
      {:score, "Frustrated"}
  """
  @spec score(structured(), [structured()]) :: t()
  def score(instructions, levels) when is_list(levels),
    do: %__MODULE__{type: :score, instructions: instructions, criteria: levels}

  @doc """
  Yes/no. Optional `true:` / `false:` describe what each answer means.

  With neither option `:criteria` is `nil`; otherwise it carries only the
  keys given. Any other option raises `ArgumentError`.

  ## Examples

      iex> ALLM.ClassificationQuestion.yes_no("Is a refund requested?").criteria
      nil

      iex> ALLM.ClassificationQuestion.yes_no("Is a refund requested?", true: "The customer asks for money back").criteria
      %{"true" => "The customer asks for money back"}
  """
  @spec yes_no(structured(), keyword()) :: t()
  def yes_no(instructions, opts \\ []) when is_list(opts) do
    opts = Keyword.validate!(opts, [true, false])

    criteria =
      case opts do
        [] -> nil
        given -> Map.new(given, fn {answer, desc} -> {Atom.to_string(answer), desc} end)
      end

    %__MODULE__{type: :yes_no, instructions: instructions, criteria: criteria}
  end

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      # A closed atom set, restored through `String.to_existing_atom/1`.
      type: Serializer.to_atom_field(data["type"]),
      # JSON already yields string keys and lists, which is exactly the shape
      # every builder produces, so both fields pass through verbatim.
      instructions: data["instructions"],
      criteria: data["criteria"]
    }
  end
end

defimpl Jason.Encoder, for: ALLM.ClassificationQuestion do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
