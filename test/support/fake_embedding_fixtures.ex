defmodule ALLM.Test.FakeEmbeddingFixtures do
  @moduledoc """
  Named scripted fixtures for `ALLM.Providers.FakeEmbeddings`. Every fixture
  returns a keyword `adapter_opts` ready to pass to `ALLM.Engine.new/1` under
  the `adapter_opts:` key.

  Layer B (test support) — lives under `test/support/` and is not part of the
  published Hex package. The Fake adapter itself ships in `lib/` but its named
  test fixtures stay test-only.

  Vectors are deterministic, fixed-dimensionality, and **not normalized**:
  input `i` of a batch maps to the one-hot-ish vector `[1.0, i / 100, 0.0]`
  verbatim, so two fixtures of different sizes never collide and every vector
  has the same dimensionality. Only `embedding(0)` happens to be unit-length;
  `embedding(100)` has magnitude `√2`. Tests that need unit vectors pipe
  through `ALLM.Embedding.normalize/1` themselves rather than assuming it.
  """

  alias ALLM.{Embedding, Usage}
  alias ALLM.Error.EmbeddingAdapterError

  @dimensions 3

  @doc """
  Deterministic embedding for position `index` — a `#{@dimensions}`-element
  vector that varies with the index.
  """
  @spec embedding(non_neg_integer()) :: Embedding.t()
  def embedding(index) when is_integer(index) and index >= 0 do
    Embedding.new(vector: [1.0, index / 100, 0.0], index: index)
  end

  @doc """
  `count` deterministic embeddings with `:index` values `0..count-1`.
  """
  @spec embeddings(pos_integer()) :: [Embedding.t()]
  def embeddings(count) when is_integer(count) and count > 0,
    do: Enum.map(0..(count - 1), &embedding/1)

  @doc """
  Single-embedding scripted response.
  """
  @spec single() :: keyword()
  def single, do: [embedding_script: [{:ok, embeddings(1)}]]

  @doc """
  Batch of `count` embeddings scripted for a single `embed/2` call.
  """
  @spec batch(pos_integer()) :: keyword()
  def batch(count) when is_integer(count) and count >= 1,
    do: [embedding_script: [{:ok, embeddings(count)}]]

  @doc """
  Batch of `count` embeddings plus a populated `%ALLM.Usage{}` typical of a
  token-priced embeddings call. `:output_tokens` stays `nil` — embeddings have
  no completion side.
  """
  @spec batch_with_usage(pos_integer(), non_neg_integer()) :: keyword()
  def batch_with_usage(count, tokens) when is_integer(count) and count >= 1 do
    usage = %Usage{input_tokens: tokens, output_tokens: nil, total_tokens: tokens}
    [embedding_script: [{:ok, embeddings(count), usage: usage}]]
  end

  @doc """
  Two successive successful calls, each returning `count` embeddings — the
  multi-call cursor fixture.
  """
  @spec two_calls(pos_integer()) :: keyword()
  def two_calls(count) when is_integer(count) and count >= 1,
    do: [embedding_script: [{:ok, embeddings(count)}, {:ok, embeddings(count)}]]

  @doc """
  Empty script — used to exercise the cursor-exhaustion path.
  """
  @spec exhausted_script() :: keyword()
  def exhausted_script, do: [embedding_script: []]

  @doc """
  Script driving a scripted `:rate_limited` rejection returned verbatim.
  """
  @spec rate_limited() :: keyword()
  def rate_limited do
    err =
      EmbeddingAdapterError.new(:rate_limited,
        message: "scripted rate limit",
        provider: :fake,
        retry_after_ms: 250
      )

    [embedding_script: [{:error, err}]]
  end

  @doc """
  Script that fails with a synthetic `:rate_limited` for the first `n - 1`
  calls and then returns `count` embeddings.
  """
  @spec retry_until_call(pos_integer(), pos_integer()) :: keyword()
  def retry_until_call(n, count) when is_integer(n) and n >= 1 do
    [embedding_script: [{:retry_until_call, n}, {:ok, embeddings(count)}]]
  end
end
