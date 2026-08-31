defmodule ALLM.ModerationResponse do
  @moduledoc """
  A content-moderation response — Layer A serializable data.

      iex> result = ALLM.ModerationResult.new(flagged: true, categories: %{"violence" => true})
      iex> resp = ALLM.ModerationResponse.new(results: [result])
      iex> ALLM.ModerationResponse.flagged?(resp)
      true

  ## Cardinality

  `length(response.results) == length(request.input)` when
  `ALLM.ModerationRequest.multimodal?/1` is `false`, and `== 1` when it is
  `true`. The rule is stated in full on `ALLM.ModerationRequest`.

  ## No `:usage`

  Unlike `ALLM.EmbeddingResponse` and `ALLM.ImageResponse`, this struct has
  **no `:usage` field**. Moderation endpoints are free and return no usage
  object, so there are no counters to carry and synthesizing empty ones
  would be noise. Telemetry metadata still carries a `:usage` key so that a
  metrics handler written against one capability does not `KeyError` when
  pointed at another; the absence is on the struct only.

  ## Fields

  `:provider` is the provider atom (`:openai`), populated by the adapter. It
  is present here and not on `ALLM.EmbeddingResponse` because a moderation
  verdict is routinely persisted alongside the content it judged, and
  "which policy engine said this" is the field an auditor asks for six
  months later.

  `:id` is the provider's own identifier for the call, and there is exactly
  one per HTTP round-trip. `:raw` carries the same caller-responsibility
  contract as `ALLM.Response.raw`: a non-JSON-encodable `:raw` raises at
  encode time.
  """

  alias ALLM.{ModerationResult, Serializer}

  @type t :: %__MODULE__{
          id: String.t() | nil,
          request_id: String.t() | nil,
          model: String.t() | nil,
          provider: atom() | nil,
          results: [ModerationResult.t()],
          raw: term(),
          metadata: map()
        }

  defstruct [:id, :request_id, :model, :provider, :raw, results: [], metadata: %{}]

  @doc """
  Build a `%ModerationResponse{}` from keyword opts.

  Unknown keys raise `KeyError` via `struct!/2`.

  ## Examples

      iex> resp = ALLM.ModerationResponse.new(model: "omni-moderation-latest")
      iex> resp.results
      []
      iex> resp.provider
      nil
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc """
  True when **any** result is flagged.

  This is the one-call answer to "should I stop here?" for the common case
  of moderating a single string.

  ## Examples

      iex> clean = ALLM.ModerationResult.new(flagged: false)
      iex> flagged = ALLM.ModerationResult.new(flagged: true)
      iex> ALLM.ModerationResponse.flagged?(ALLM.ModerationResponse.new(results: [clean, flagged]))
      true

      iex> ALLM.ModerationResponse.flagged?(ALLM.ModerationResponse.new())
      false
  """
  @spec flagged?(t()) :: boolean()
  def flagged?(%__MODULE__{results: results}),
    do: Enum.any?(results, fn %ModerationResult{flagged: flagged} -> flagged == true end)

  @doc """
  Union of every result's flagged categories, deduplicated and sorted.

  Same meaning as `ALLM.ModerationResult.flagged_categories/1`, one scope
  up: use this to report *what* tripped anywhere in a batch, and the
  per-result function to report *which item* tripped it.

  ## Examples

      iex> a = ALLM.ModerationResult.new(flagged: true, categories: %{"violence" => true})
      iex> b = ALLM.ModerationResult.new(flagged: true, categories: %{"violence" => true, "hate" => true})
      iex> ALLM.ModerationResponse.flagged_categories(ALLM.ModerationResponse.new(results: [a, b]))
      ["hate", "violence"]

      iex> ALLM.ModerationResponse.flagged_categories(ALLM.ModerationResponse.new())
      []
  """
  @spec flagged_categories(t()) :: [String.t()]
  def flagged_categories(%__MODULE__{results: results}) do
    results
    |> Enum.flat_map(&ModerationResult.flagged_categories/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      id: data["id"],
      request_id: data["request_id"],
      model: data["model"],
      # `:provider` is an atom on a serializable struct, so it restores
      # through the serializer's `String.to_existing_atom/1` helper, whose
      # raise is rescued into `{:_unknown, :atom_decode_failed}`. A bare
      # `String.to_atom/1` would be untrusted-input atom growth — barred one
      # struct away for the very same reason category keys stay strings.
      provider: Serializer.to_atom_field(data["provider"]),
      # Without `hydrate/1` this decodes to a list of raw maps and the
      # round-trip loses struct identity.
      results: Serializer.hydrate(data["results"] || []),
      raw: data["raw"],
      metadata: data["metadata"] || %{}
    }
  end
end

defimpl Jason.Encoder, for: ALLM.ModerationResponse do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
