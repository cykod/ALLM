defmodule ALLM.EmbeddingResponse do
  @moduledoc """
  A text-embedding response — Layer A serializable data.

      iex> resp = ALLM.EmbeddingResponse.new(embeddings: [ALLM.Embedding.new(vector: [0.1, 0.2])])
      iex> ALLM.EmbeddingResponse.vectors(resp)
      [[0.1, 0.2]]

  ## Invariants

  * **Order correspondence** — `Enum.at(vectors(response), i)` is the
    embedding of `Enum.at(request.input, i)` for every `i`. Preserved across
    chunk merges by index rebasing and by `vectors/1`'s sort.
  * **Uniform dimensionality** — every vector in `:embeddings` has the same
    length. Asserted by the adapter conformance suite, not enforced by the
    constructor.
  * **Cardinality** — `length(response.embeddings) == length(request.input)`
    on success.

  ## Usage

  `:usage` is an `t:ALLM.Usage.t/0` and is never `nil`; a response that
  carries no counters holds `%ALLM.Usage{}` with every field `nil`.
  Embeddings bill in tokens, so adapters populate `:input_tokens` and
  `:total_tokens`; `:output_tokens` is always `nil`. Providers that report
  only one of the two counters leave the other `nil` rather than
  synthesizing a value.

  `:raw` carries the same caller-responsibility contract as
  `ALLM.Response.raw`: a non-JSON-encodable `:raw` raises at encode time.
  """

  alias ALLM.{Embedding, Serializer, Usage}

  @type t :: %__MODULE__{
          id: String.t() | nil,
          request_id: String.t() | nil,
          model: String.t() | nil,
          embeddings: [Embedding.t()],
          usage: Usage.t(),
          raw: term(),
          metadata: map()
        }

  defstruct [
    :id,
    :request_id,
    :model,
    :raw,
    embeddings: [],
    usage: %Usage{},
    metadata: %{}
  ]

  @doc """
  Build an `%EmbeddingResponse{}` from keyword opts.

  Unknown keys raise `KeyError` via `struct!/2`.

  ## Examples

      iex> resp = ALLM.EmbeddingResponse.new(model: "text-embedding-3-small")
      iex> resp.embeddings
      []
      iex> resp.usage
      %ALLM.Usage{}
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc """
  Vectors sorted by `:index`, flattened for direct insertion into a
  `vector(N)` column.

  Sorting is what guarantees the order-correspondence invariant even when a
  provider returns items out of order or a chunk merge interleaves them.

  ## Examples

      iex> resp = ALLM.EmbeddingResponse.new(embeddings: [
      ...>   ALLM.Embedding.new(vector: [1.0], index: 1),
      ...>   ALLM.Embedding.new(vector: [0.0], index: 0)
      ...> ])
      iex> ALLM.EmbeddingResponse.vectors(resp)
      [[0.0], [1.0]]

      iex> ALLM.EmbeddingResponse.vectors(ALLM.EmbeddingResponse.new())
      []
  """
  @spec vectors(t()) :: [[float()]]
  def vectors(%__MODULE__{embeddings: embeddings}) do
    embeddings
    |> Enum.sort_by(& &1.index)
    |> Enum.map(& &1.vector)
  end

  @doc """
  Length of the first vector, or `nil` when `:embeddings` is empty. Use to
  size a `vector(N)` column.

  "First" means first in **list order**, not lowest `:index` — unlike
  `vectors/1`, this function does not sort. The two agree only under the
  uniform-dimensionality invariant above, which is asserted by the adapter
  conformance suite rather than by this struct.

  The return is `t:non_neg_integer/0`, not `t:pos_integer/0`: a caller can
  hand-build `%ALLM.Embedding{vector: []}`, and this function then returns
  `0`. Adapters cannot — one that would build an empty vector from a
  provider response returns
  `%ALLM.Error.EmbeddingAdapterError{reason: :malformed_response}` instead —
  so `0` is reachable only through direct struct construction, never from a
  provider round-trip.

  ## Examples

      iex> resp = ALLM.EmbeddingResponse.new(embeddings: [ALLM.Embedding.new(vector: [1.0, 2.0])])
      iex> ALLM.EmbeddingResponse.dimensions(resp)
      2

      iex> ALLM.EmbeddingResponse.dimensions(ALLM.EmbeddingResponse.new())
      nil
  """
  @spec dimensions(t()) :: non_neg_integer() | nil
  def dimensions(%__MODULE__{embeddings: [%Embedding{vector: vector} | _]}), do: length(vector)
  def dimensions(%__MODULE__{}), do: nil

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      id: data["id"],
      request_id: data["request_id"],
      model: data["model"],
      embeddings: Serializer.hydrate(data["embeddings"] || []),
      usage: hydrate_usage(data["usage"]),
      raw: data["raw"],
      metadata: data["metadata"] || %{}
    }
  end

  # Mirrors `ALLM.ImageResponse`'s `hydrate_usage/1` fallback so `:usage` is
  # never `nil` after a decode, including for payloads whose `"usage"` key
  # is absent or explicitly `null`.
  defp hydrate_usage(nil), do: %Usage{}

  defp hydrate_usage(%{"__type__" => _} = tagged) do
    case Serializer.hydrate(tagged) do
      %Usage{} = usage -> usage
      _ -> %Usage{}
    end
  end

  defp hydrate_usage(other), do: other
end

defimpl Jason.Encoder, for: ALLM.EmbeddingResponse do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
