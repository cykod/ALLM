defmodule ALLM.ModelRef do
  @moduledoc """
  A model reference returned by an optional model-catalog integration
  Layer A serializable data.

  Carries the catalog's view of a single model: provider, id, capability
  flags (tools, json_native, vision), context/output limits,
  per-million-token pricing, and an opaque `:metadata` bag.

  A `%ModelRef{}` is plain serializable data — no PIDs, refs, funs, or API
  keys. It round-trips through `:erlang.term_to_binary/1` and JSON
  (`ALLM.Serializer.to_json!/1`) just like every other Layer A struct.

  Construction is via `new/1`. Hydration from a JSON-decoded map is via
  `__from_tagged__/1` (called by the serializer's hydrator); the module
  is registered with the serializer's known-modules list so tagged JSON
  (`%{"__type__" => "ALLM.ModelRef", "data" => ...}`) decodes automatically.

  ## Layer A nested-map JSON asymmetry (carve-out)

  `:capabilities`, `:limits`, `:pricing`, and `:metadata` are opaque map
  bags whose **nested keys are not atomized on JSON rehydration**. ETF
  round-trip is byte-identical, but `Jason.encode!/1` →
  `Serializer.from_json/1` produces:

      iex> ref = ALLM.ModelRef.new(
      ...> provider: :openai, id: "x",
      ...> capabilities: %{tools: %{enabled: false}}
      ...>)
      iex> {:ok, hydrated} = ALLM.Serializer.from_json(ALLM.Serializer.to_json!(ref))
      iex> hydrated.capabilities
      %{"tools" => %{"enabled" => false}}

  This matches `ALLM.Engine`'s `:metadata` precedent — opaque
  caller-owned maps don't get atom-key restoration because the closed set
  of valid keys can't be bounded at hydration time. **Consumers handle
  this asymmetry directly:** `ALLM.Capability.preflight/2` and
  `ALLM.Capability.populate_costs/2` pattern-match on both atom-keyed
  and string-keyed shapes, so a JSON-rehydrated `%ModelRef{}` pre-flights
  and prices identically to an in-process one. A naive consumer that
  pattern-matches only on atom-keyed shapes will silently bypass the
  rehydrated ref — see `ALLM.Capability` `@moduledoc`.

  ## Examples

      iex> ref = ALLM.ModelRef.new(provider: :openai, id: "gpt-4.1-mini")
      iex> ref.provider
      :openai
      iex> ref.id
      "gpt-4.1-mini"
      iex> ref.metadata
      %{}
  """

  @type capabilities :: %{
          optional(:tools) => %{enabled: boolean()},
          optional(:json_native) => boolean(),
          optional(atom()) => term()
        }

  @type limits :: %{
          optional(:context) => pos_integer(),
          optional(:output) => pos_integer(),
          optional(atom()) => term()
        }

  @type pricing :: %{input: number(), output: number()} | nil

  @type t :: %__MODULE__{
          provider: atom() | nil,
          id: String.t() | nil,
          capabilities: capabilities() | nil,
          limits: limits() | nil,
          pricing: pricing(),
          metadata: map()
        }

  defstruct [:provider, :id, :capabilities, :limits, :pricing, metadata: %{}]

  @doc """
  Build a `%ALLM.ModelRef{}` from keyword opts.

  Accepts any subset of the documented struct fields; unknown keys raise
  `KeyError` via `struct!/2`.

  ## Examples

      iex> ref = ALLM.ModelRef.new(
      ...> provider: :openai,
      ...> id: "gpt-4.1-mini",
      ...> capabilities: %{tools: %{enabled: true}, json_native: true},
      ...> pricing: %{input: 0.15, output: 0.6}
      ...>)
      iex> ref.pricing
      %{input: 0.15, output: 0.6}
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      provider: ALLM.Serializer.to_atom_field(data["provider"]),
      id: data["id"],
      capabilities: data["capabilities"],
      limits: data["limits"],
      pricing: data["pricing"],
      metadata: data["metadata"] || %{}
    }
  end
end

defimpl Jason.Encoder, for: ALLM.ModelRef do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
