defmodule ALLM.ModerationResult do
  @moduledoc """
  One content-moderation verdict — Layer A serializable data.

      iex> result = ALLM.ModerationResult.new(flagged: true, categories: %{"violence" => true})
      iex> ALLM.ModerationResult.flagged_categories(result)
      ["violence"]

  ## Only `:flagged` is normalized

  `:flagged` is the one field whose meaning is genuinely cross-provider —
  "the provider says this trips its policy" — so it is a first-class
  `t:boolean/0`. Everything below it is **provider-shaped and
  string-keyed**: `categories` and `category_scores` carry the provider's
  own category names exactly as the wire spells them
  (`"self-harm/intent"`, `"illicit/violent"`), and ALLM neither normalizes
  them into a cross-provider taxonomy nor converts them to atoms.

  Three reasons, any one sufficient: a name like `"self-harm/intent"` is
  not a bare atom literal and would cost every caller a quoted atom;
  building atoms from a provider-controlled key set is untrusted-input atom
  growth, while a safelist would silently drop any category the provider
  adds; and string keys make the JSON decode a total identity on these
  maps. The cost is real and worth stating: a caller reading
  `scores["violence"]` is writing provider-specific code, and the compiler
  will not catch a typo.

  ALLM ships **no default threshold** and no "is this unsafe?" predicate.
  Where the line sits varies by jurisdiction, audience, and appetite; a
  library default would be quietly wrong for most callers and would read
  as an endorsement. Use `:flagged` for the provider's own verdict, or
  `score/2` against a threshold you chose.

  ## Fields

  `:index` is always a `t:non_neg_integer/0`, never `nil`, so that
  `Enum.at(response.results, i)` corresponds to `Enum.at(request.input, i)`
  for a batch of strings. A multimodal request yields exactly one result
  and its index is `0`.

  `:applied_input_types` reports, per category, which parts of a
  multimodal input triggered it (`%{"violence" => ["image"]}`). It is `%{}`
  when the provider does not report it — an empty map is the honest
  representation of "not reported".

  ## Construction

  `:flagged` is enforced by `@enforce_keys`, so `new/1` without it raises
  `ArgumentError`. An *unknown* key raises `KeyError` via `struct!/2`.
  Enforcement is on key **absence**, not value — `new(flagged: nil)`
  succeeds.

  ## Deserialization repairs `:flagged`

  This is the one decoder in the moderation family that **repairs** a
  malformed value rather than passing it through. On the JSON decode path
  (`ALLM.Serializer.from_json/1`), a `"flagged"` that is not a boolean —
  absent, `null`, the string `"true"`, a truncated or tampered payload —
  deserializes to `false`, i.e. *not flagged*. The struct's declared
  `t:boolean/0` is preserved rather than admitting a `nil`, and a decode
  glitch cannot manufacture a `true` that blocks legitimate content.

  Two consequences worth stating in the public docs, because both invert a
  reflex carried over from `ALLM.Embedding`:

    * a **corrupted persisted verdict deserializes to "clean"**, not to a
      decode error, and **the repair is silent**. `:categories` and
      `:category_scores` decode independently of `:flagged`, so a tampered
      payload — or one carrying the string `"true"` — comes back
      `flagged: false` beside a fully populated category map, with nothing in
      the struct marking it as repaired. Only a payload truncated so badly
      that all three keys are missing arrives with the category maps empty,
      and that is the absence of data rather than a signal about the repair.
      A caller who needs to detect a corrupted verdict has to validate the
      payload before decoding, or compare `:flagged` against `:categories`;
    * ETF and JSON round-trips are therefore **not interchangeable** for an
      off-contract `flagged: nil`: `:erlang.term_to_binary/1` preserves the
      `nil`, JSON returns `false`.

  The repair is scoped to `:flagged` alone; every other field decodes as a
  pass-through.
  """

  @typedoc """
  A moderation verdict for one input item.

  `:applied_input_types` drops the provider's `category_` prefix; its two
  sibling maps keep their wire spelling.
  """
  @type t :: %__MODULE__{
          flagged: boolean(),
          categories: %{String.t() => boolean()},
          category_scores: %{String.t() => float()},
          # wire: category_applied_input_types
          applied_input_types: %{String.t() => [String.t()]},
          index: non_neg_integer(),
          metadata: map()
        }

  @enforce_keys [:flagged]
  defstruct [
    :flagged,
    categories: %{},
    category_scores: %{},
    applied_input_types: %{},
    index: 0,
    metadata: %{}
  ]

  @doc """
  Build a `%ModerationResult{}` from keyword opts.

  A missing `:flagged` raises `ArgumentError` (`@enforce_keys`); an unknown
  key raises `KeyError` (`struct!/2`).

  ## Examples

      iex> result = ALLM.ModerationResult.new(flagged: false)
      iex> result.index
      0
      iex> result.categories
      %{}
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc """
  Category names whose `:categories` value is `true`, sorted.

  Returns `[]` when nothing is flagged or when the provider reported no
  categories.

  ## Examples

      iex> result = ALLM.ModerationResult.new(
      ...>   flagged: true,
      ...>   categories: %{"violence" => true, "hate" => true, "sexual" => false}
      ...> )
      iex> ALLM.ModerationResult.flagged_categories(result)
      ["hate", "violence"]

      iex> ALLM.ModerationResult.flagged_categories(ALLM.ModerationResult.new(flagged: false))
      []
  """
  @spec flagged_categories(t()) :: [String.t()]
  def flagged_categories(%__MODULE__{categories: categories}) do
    categories
    |> Enum.filter(fn {_name, flagged} -> flagged == true end)
    |> Enum.map(fn {name, _flagged} -> name end)
    |> Enum.sort()
  end

  @doc """
  Score for one category, or `nil` when the provider did not report it.

  Category names are the provider's own strings — see the module docs on
  why they are not normalized.

  ## Examples

      iex> result = ALLM.ModerationResult.new(flagged: true, category_scores: %{"violence" => 0.94})
      iex> ALLM.ModerationResult.score(result, "violence")
      0.94

      iex> result = ALLM.ModerationResult.new(flagged: false)
      iex> ALLM.ModerationResult.score(result, "violence")
      nil
  """
  @spec score(t(), String.t()) :: float() | nil
  def score(%__MODULE__{category_scores: scores}, category), do: Map.get(scores, category)

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      flagged: decode_flagged(data["flagged"]),
      categories: data["categories"] || %{},
      category_scores: data["category_scores"] || %{},
      applied_input_types: data["applied_input_types"] || %{},
      index: data["index"] || 0,
      metadata: data["metadata"] || %{}
    }
  end

  # `@enforce_keys [:flagged]` constrains `struct!/2` at the constructor and
  # does NOT constrain the literal `%__MODULE__{}` built above, so a
  # truncated payload would otherwise yield `flagged: nil` and silently
  # violate the declared `boolean()` type.
  #
  # This is the one decoder in the moderation family that **repairs** rather
  # than passing a malformed value through — a deliberate inversion of
  # `ALLM.Embedding`'s `decode_vector/1` pass-through-don't-repair contract,
  # not a copy error. The repair target is `false`, the struct's own
  # declared default, so a malformed payload can neither leave a `nil` in a
  # `boolean()` field nor manufacture a `true` that blocks legitimate
  # content on a decode glitch. Any later clause added to
  # `__from_tagged__/1` here should pass through; the repair is scoped to
  # `:flagged` alone.
  defp decode_flagged(value) when is_boolean(value), do: value
  defp decode_flagged(_other), do: false
end

defimpl Jason.Encoder, for: ALLM.ModerationResult do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
