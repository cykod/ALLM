defmodule ALLM.Test.EmbeddingAdapterConformance do
  @moduledoc """
  Injectable conformance suite for `ALLM.EmbeddingAdapter` implementations.

  ## Installation

      {:allm_conformance, "~> 0.3", only: :test}

  ## Usage

      defmodule MyEmbeddingAdapterTest do
        use ExUnit.Case, async: true
        use ALLM.Test.EmbeddingAdapterConformance, embedding_adapter: MyEmbeddingAdapter
      end

  Injects a `describe "ALLM.EmbeddingAdapter conformance (MyEmbeddingAdapter)"`
  block with 10 deterministic cases.

  ## Script contract

  Each injected case scripts the adapter through
  `adapter_opts[:embedding_script]` on the call's `opts` keyword list. See
  `ALLM.Providers.FakeEmbeddings`'s `script/1` `@doc` for the full grammar
  (the published reference implementation the suite targets).

  Real provider adapters honour the same key through a test-injection
  short-circuit that delegates to `ALLM.Providers.FakeEmbeddings.embed/2`
  before any pre-flight gate runs.

  ## Gate cases

  Cases 3 and 4 assert the two pre-flight gates (`:batch_too_large` and
  `:invalid_request`) and therefore pass **no script** — a scripted adapter
  short-circuits before reaching its own gates by design, so scripting them
  would assert nothing. Both cases run against the caller-supplied adapter and
  nothing else: every assertion in this suite has to be reachable for every
  consumer of the package, so no case may be gated on a fixture that lives
  inside `allm_conformance`'s own test tree.

  ## What this suite does NOT bind

  Cases 2 and 5–10 drive the adapter through `adapter_opts[:embedding_script]`.
  For an adapter whose short-circuit returns the scripted response verbatim —
  `ALLM.Providers.FakeEmbeddings` and every bundled provider adapter — the
  success path never reaches that adapter's own response decoder. For those
  adapters these cases therefore do **not** bind `ALLM.EmbeddingAdapter`
  invariant 8 (exactly `length(request.input)` embeddings, `:index` values
  `0..length-1`, uniform non-zero vector length); they bind it only for an
  adapter that implements `embed/2` itself rather than delegating.

  A passthrough adapter's invariant-8 conformance is the job of that adapter's
  own decoder tests, driven from recorded wire fixtures. **Do not read a green
  run of this suite as evidence that a provider's decoder indexes its response
  correctly.**

  ## Why the helpers below take and return plain data

  This package is compiled *before* `allm` in a consuming project's build, so
  the harness module body must not reference `ALLM.*` functions directly —
  every such call happens inside the `using/1` `quote`, which expands at the
  consumer's compile time when `allm` is loaded.
  """

  use ExUnit.CaseTemplate

  @case_count 10

  @doc """
  Return the number of cases injected by `using/1`. Used by harness
  self-tests to guard against silent case-count drift.
  """
  @spec case_count() :: pos_integer()
  def case_count, do: @case_count

  @doc false
  @spec inputs(pos_integer()) :: [String.t()]
  def inputs(count) when is_integer(count) and count >= 1,
    do: for(i <- 1..count, do: "conformance input #{i}")

  using opts do
    quote location: :keep do
      @__allm_embedding_conformance_adapter__ Keyword.fetch!(
                                                unquote(opts),
                                                :embedding_adapter
                                              )

      describe "ALLM.EmbeddingAdapter conformance (#{inspect(@__allm_embedding_conformance_adapter__)})" do
        alias ALLM.{Embedding, EmbeddingRequest, EmbeddingResponse, Usage}
        alias ALLM.Error.EmbeddingAdapterError
        alias ALLM.Test.EmbeddingAdapterConformance, as: Harness

        test "1. max_batch_size/0 returns a pos_integer" do
          max = @__allm_embedding_conformance_adapter__.max_batch_size()
          assert is_integer(max)
          assert max > 0
        end

        test "2. single input returns one embedding with index: 0" do
          req = EmbeddingRequest.new(input: ["a kestrel"])
          script = [{:ok, [Embedding.new(vector: [1.0, 0.0, 0.0], index: 0)]}]

          assert {:ok, %EmbeddingResponse{embeddings: [%Embedding{index: 0}]}} =
                   @__allm_embedding_conformance_adapter__.embed(req,
                     adapter_opts: [embedding_script: script]
                   )
        end

        test "3. input longer than max_batch_size is rejected with :batch_too_large before I/O" do
          adapter = @__allm_embedding_conformance_adapter__
          max = adapter.max_batch_size()
          req = EmbeddingRequest.new(input: Harness.inputs(max + 1))

          # No script: a scripted adapter short-circuits ahead of its gates.
          assert {:error, %EmbeddingAdapterError{reason: :batch_too_large, metadata: meta}} =
                   adapter.embed(req, [])

          assert meta.count == max + 1
          assert meta.max == max
        end

        test "4. empty input is rejected with :invalid_request before I/O" do
          req = EmbeddingRequest.new(input: [])

          assert {:error, %EmbeddingAdapterError{reason: :invalid_request}} =
                   @__allm_embedding_conformance_adapter__.embed(req, [])
        end

        test "5. returns exactly length(input) embeddings" do
          req = EmbeddingRequest.new(input: Harness.inputs(4))
          embeddings = for i <- 0..3, do: Embedding.new(vector: [1.0, i / 10, 0.0], index: i)

          assert {:ok, %EmbeddingResponse{embeddings: out}} =
                   @__allm_embedding_conformance_adapter__.embed(req,
                     adapter_opts: [embedding_script: [{:ok, embeddings}]]
                   )

          assert length(out) == length(req.input)
        end

        test "6. :index values are exactly 0..length-1" do
          req = EmbeddingRequest.new(input: Harness.inputs(3))

          # Deliberately out of order: the contract is on the SET of indices,
          # and an adapter must not depend on the provider emitting them
          # pre-sorted.
          embeddings = for i <- [2, 0, 1], do: Embedding.new(vector: [1.0, i / 10, 0.0], index: i)

          assert {:ok, %EmbeddingResponse{embeddings: out}} =
                   @__allm_embedding_conformance_adapter__.embed(req,
                     adapter_opts: [embedding_script: [{:ok, embeddings}]]
                   )

          assert out |> Enum.map(& &1.index) |> Enum.sort() ==
                   Enum.to_list(0..(length(req.input) - 1))
        end

        test "7. all vectors have identical, non-zero length" do
          req = EmbeddingRequest.new(input: Harness.inputs(3))

          # Distinct vectors of equal dimensionality — a suite that scripted
          # three copies of one vector would pass this case trivially.
          embeddings =
            for i <- 0..2, do: Embedding.new(vector: [1.0, i / 10, 2.0 - i], index: i)

          assert {:ok, %EmbeddingResponse{} = resp} =
                   @__allm_embedding_conformance_adapter__.embed(req,
                     adapter_opts: [embedding_script: [{:ok, embeddings}]]
                   )

          lengths = resp |> EmbeddingResponse.vectors() |> Enum.map(&length/1)

          assert length(Enum.uniq(lengths)) == 1
          assert hd(lengths) > 0
        end

        test "8. round-trips request.metadata onto response.metadata unchanged" do
          metadata = %{trace_id: "abc", user: "alice"}
          req = EmbeddingRequest.new(input: ["x"], metadata: metadata)
          script = [{:ok, [Embedding.new(vector: [1.0, 0.0, 0.0], index: 0)]}]

          assert {:ok, %EmbeddingResponse{metadata: ^metadata}} =
                   @__allm_embedding_conformance_adapter__.embed(req,
                     adapter_opts: [embedding_script: script]
                   )
        end

        test "9. preserves opts[:request_id] onto EmbeddingResponse.request_id" do
          req = EmbeddingRequest.new(input: ["x"])
          script = [{:ok, [Embedding.new(vector: [1.0, 0.0, 0.0], index: 0)]}]

          assert {:ok, %EmbeddingResponse{request_id: "test-id-123"}} =
                   @__allm_embedding_conformance_adapter__.embed(req,
                     adapter_opts: [embedding_script: script],
                     request_id: "test-id-123"
                   )
        end

        test "10. response.usage is a %ALLM.Usage{}, never nil" do
          req = EmbeddingRequest.new(input: ["x"])
          script = [{:ok, [Embedding.new(vector: [1.0, 0.0, 0.0], index: 0)]}]

          assert {:ok, %EmbeddingResponse{usage: %Usage{}}} =
                   @__allm_embedding_conformance_adapter__.embed(req,
                     adapter_opts: [embedding_script: script]
                   )
        end
      end
    end
  end
end
