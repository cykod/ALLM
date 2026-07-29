defmodule ALLM.Embedding do
  @moduledoc """
  A single embedding vector — Layer A serializable data.

  One `%Embedding{}` corresponds to one input string in an
  `t:ALLM.EmbeddingRequest.t/0`. `:index` is the position of that input in
  the original request's `:input` list and is **always** a
  `t:non_neg_integer/0` — never `nil` — so that a response merged across
  several provider calls still guarantees
  `Enum.at(ALLM.EmbeddingResponse.vectors(resp), i)` is the embedding of
  `Enum.at(request.input, i)`.

      iex> e = ALLM.Embedding.new(vector: [3.0, 4.0], index: 0)
      iex> ALLM.Embedding.magnitude(e)
      5.0

  ## Construction

  `:vector` is enforced by `@enforce_keys`, so `new/1` without it raises
  `ArgumentError`. An *unknown* key raises `KeyError` via `struct!/2`.
  Enforcement is on key **absence**, not value — `new(vector: nil)`
  succeeds. There is no `is_list/1` guard: constructing an embedding is the
  job of adapter decoders, which always supply a list, and an adapter that
  would build a `vector: []` returns
  `%ALLM.Error.EmbeddingAdapterError{reason: :malformed_response}` instead.
  `magnitude/1` and `normalize/1` are undefined on a `nil` vector — they
  raise `Protocol.UndefinedError`, not the `ArithmeticError` documented
  below.

  ## Numeric contract

  * `normalize/1` is idempotent to within `1.0e-9`.
  * `normalize/1` returns the embedding unchanged whenever `magnitude/1` is
    `0.0` — which covers `vector: []`, an all-zero vector, and a vector
    whose components underflow when squared (`[1.0e-200, 1.0e-200]`). No
    `ArithmeticError`, no `NaN`.
  * `magnitude/1` **raises `ArithmeticError` on float overflow**: Erlang's
    `*` raises `badarith` rather than producing infinity. No embedding
    provider returns components anywhere near `1.0e150`, so the naive sum of
    squares is correct for every real input; the bound is documented rather
    than paid for with max-scaling.
  """

  @enforce_keys [:vector]
  defstruct [:vector, index: 0, metadata: %{}]

  @type t :: %__MODULE__{
          vector: [float()],
          index: non_neg_integer(),
          metadata: map()
        }

  @doc """
  Build an `%Embedding{}` from keyword opts.

  A missing `:vector` raises `ArgumentError` (`@enforce_keys`); an unknown
  key raises `KeyError` (`struct!/2`).

  ## Examples

      iex> e = ALLM.Embedding.new(vector: [0.1, 0.2])
      iex> e.index
      0
      iex> e.metadata
      %{}
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc """
  L2-normalize the vector. Returns the embedding unchanged when the
  magnitude is `0.0`.

  `:index` and `:metadata` are preserved.

  ## Examples

      iex> ALLM.Embedding.normalize(ALLM.Embedding.new(vector: [0.0, 2.0])).vector
      [0.0, 1.0]

      iex> zero = ALLM.Embedding.new(vector: [0.0, 0.0])
      iex> ALLM.Embedding.normalize(zero) == zero
      true
  """
  @spec normalize(t()) :: t()
  def normalize(%__MODULE__{vector: vector} = embedding) do
    case magnitude(embedding) do
      magnitude when magnitude == 0.0 -> embedding
      magnitude -> %{embedding | vector: Enum.map(vector, &(&1 / magnitude))}
    end
  end

  @doc """
  Euclidean norm of the vector.

  Raises `ArithmeticError` when a component squares to a float overflow —
  see the module docs.

  ## Examples

      iex> ALLM.Embedding.magnitude(ALLM.Embedding.new(vector: [3.0, 4.0]))
      5.0

      iex> ALLM.Embedding.magnitude(ALLM.Embedding.new(vector: []))
      0.0
  """
  @spec magnitude(t()) :: float()
  def magnitude(%__MODULE__{vector: vector}) do
    vector
    |> Enum.reduce(0.0, fn component, acc -> component * component + acc end)
    |> :math.sqrt()
  end

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      vector: decode_vector(data["vector"]),
      index: data["index"] || 0,
      metadata: data["metadata"] || %{}
    }
  end

  # Decision #8: `Jason` round-trips `0.0` as `0.0`, but a hand-built
  # `%Embedding{vector: [0, 1]}` decodes to integers, breaking the
  # `[float()]` type and any `Enum.sum/1`-based normalization downstream.
  # Same class as `ALLM.ImageRequest.decode_size/1`'s shape restoration.
  # Non-list / non-numeric values pass through verbatim rather than being
  # silently repaired.
  defp decode_vector(list) when is_list(list), do: Enum.map(list, &decode_component/1)
  defp decode_vector(other), do: other

  # A JSON integer literal too large for a float decodes to a BEAM bignum,
  # and `bignum * 1.0` raises `ArithmeticError`. `Serializer.hydrate_with/2`
  # rescues only `ValidationError` and `ArgumentError`, so an unguarded
  # raise here escapes `Serializer.from_json/2`, whose `@spec` promises
  # `{:ok, struct()} | {:error, ValidationError.t()}`. Pass the value
  # through un-coerced instead, matching the non-numeric arm below and
  # `decode_vector/1`'s pass-through-don't-repair contract. (The float path
  # needs no guard — `Jason` rejects a `1e400` literal outright.)
  defp decode_component(component) when is_number(component) do
    component * 1.0
  rescue
    ArithmeticError -> component
  end

  defp decode_component(other), do: other
end

defimpl Jason.Encoder, for: ALLM.Embedding do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
