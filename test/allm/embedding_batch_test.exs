defmodule ALLM.EmbeddingBatchTest do
  @moduledoc """
  `ALLM.EmbeddingBatch` — the `@doc false` `chunk/2` and `merge/1` seams
  driven directly, plus the batch-equivalence property driven end-to-end
  through `ALLM.embed/3`.

  ## Batch-equivalence relaxation set

  The property asserts that a chunked `ALLM.embed/3` call returns the same
  embeddings as a single unchunked call against the same scripted vectors.
  Two fields are relaxed; both are contract-defined differences with a named
  code path in `ALLM.EmbeddingBatch.merge/1`, not assertions loosened to hide
  a bug.

  | Field | Relaxation | Justification | Risk |
  |-------|-----------|---------------|------|
  | `:raw` | compared only when `chunk_count == 1` | a multi-chunk merge keeps the first chunk's `:raw` only, discarding the rest — `merge/1`'s `:raw` rule | tolerable — contract-defined |
  | `metadata.chunk_count` | stripped before comparison | it is the one field that necessarily differs between the two arms | tolerable — contract-defined |

  Every other field (`:embeddings` including per-item `:index` and `:vector`
  order, `:usage`, `:model`, `:id`, `:request_id`, and the rest of
  `:metadata`) is compared unrelaxed.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ALLM.{Embedding, EmbeddingBatch, EmbeddingRequest, EmbeddingResponse, Engine, Usage}
  alias ALLM.Test.VariableBatchEmbeddingStub

  # A third-party adapter that violates `ALLM.EmbeddingAdapter` invariant 2 by
  # returning a raw error term instead of `{:error, %EmbeddingAdapterError{}}`
  # — the realistic shape (an un-converted transport error from the HTTP
  # layer). Scope is this file only, so it stays inline.
  defmodule NonConformingEmbeddingAdapter do
    @moduledoc false
    @behaviour ALLM.EmbeddingAdapter

    @impl ALLM.EmbeddingAdapter
    def max_batch_size, do: 2

    @impl ALLM.EmbeddingAdapter
    def embed(%ALLM.EmbeddingRequest{}, _opts), do: {:error, :timeout}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp req(n) when is_integer(n) and n >= 0 do
    EmbeddingRequest.new(input: inputs(n))
  end

  defp inputs(0), do: []
  defp inputs(n), do: Enum.map(1..n, &"chunk #{&1}")

  # Deterministic vector for the GLOBAL input position `i`. Both arms of the
  # equivalence property derive their scripted vectors from this, so a
  # rebasing or merge-order bug shows up as a vector mismatch, not just an
  # index mismatch.
  defp vec(i), do: [i * 1.0, i * 1.0 + 0.5]

  # One script entry's worth of embeddings: `len` items whose `:index` is
  # chunk-LOCAL (`0..len-1`), exactly as a real adapter returns them, but
  # whose vectors encode the global position.
  defp chunk_embeddings(offset, len) do
    Enum.map(0..(len - 1), fn j -> Embedding.new(vector: vec(offset + j), index: j) end)
  end

  defp script_for(total, max) do
    0..(total - 1)
    |> Enum.chunk_every(max)
    |> Enum.map(fn slice -> {:ok, chunk_embeddings(hd(slice), length(slice))} end)
  end

  defp response(opts), do: EmbeddingResponse.new(opts)

  # A non-default value shaped like the field's own default: map-valued
  # `%Usage{}` fields get a map, every other field a number.
  defp usage_sentinel(default) when is_map(default), do: %{"sentinel" => 1}
  defp usage_sentinel(_default), do: 1

  # ---------------------------------------------------------------------------
  # chunk/2
  # ---------------------------------------------------------------------------

  describe "chunk/2" do
    test "250 inputs at max 100 returns 3 pairs with offsets [0, 100, 200]" do
      pairs = EmbeddingBatch.chunk(req(250), 100)

      assert length(pairs) == 3
      assert Enum.map(pairs, &elem(&1, 0)) == [0, 100, 200]
      assert Enum.map(pairs, fn {_o, r} -> length(r.input) end) == [100, 100, 50]
    end

    test "input length exactly max returns one pair with offset 0" do
      assert [{0, %EmbeddingRequest{input: input}}] = EmbeddingBatch.chunk(req(100), 100)
      assert length(input) == 100
    end

    test "input length max+1 returns two pairs" do
      assert [{0, a}, {100, b}] = EmbeddingBatch.chunk(req(101), 100)
      assert length(a.input) == 100
      assert length(b.input) == 1
    end

    test "empty input returns []" do
      assert EmbeddingBatch.chunk(req(0), 100) == []
    end

    test "sub-requests carry every non-:input field of the parent verbatim" do
      parent =
        EmbeddingRequest.new(
          input: inputs(3),
          model: "m",
          dimensions: 512,
          task_type: :search_query,
          truncate: false,
          options: %{"user" => "u"},
          metadata: %{trace: "t"}
        )

      for {_offset, sub} <- EmbeddingBatch.chunk(parent, 2) do
        assert %{parent | input: sub.input} == sub
      end
    end

    test "the concatenated sub-request inputs reconstruct the parent input in order" do
      parent = req(7)

      rebuilt =
        parent
        |> EmbeddingBatch.chunk(3)
        |> Enum.flat_map(fn {_o, r} -> r.input end)

      assert rebuilt == parent.input
    end
  end

  # ---------------------------------------------------------------------------
  # merge/1
  # ---------------------------------------------------------------------------

  describe "merge/1" do
    test "concatenates embeddings and sorts by :index" do
      a = response(embeddings: [Embedding.new(vector: [2.0], index: 2)])

      b =
        response(
          embeddings: [
            Embedding.new(vector: [0.0], index: 0),
            Embedding.new(vector: [1.0], index: 1)
          ]
        )

      merged = EmbeddingBatch.merge([a, b])

      assert Enum.map(merged.embeddings, & &1.index) == [0, 1, 2]
      assert EmbeddingResponse.vectors(merged) == [[0.0], [1.0], [2.0]]
    end

    test "sums :input_tokens and :total_tokens across chunks" do
      a = response(usage: %Usage{input_tokens: 10, total_tokens: 12})
      b = response(usage: %Usage{input_tokens: 5, total_tokens: 6})

      merged = EmbeddingBatch.merge([a, b])

      assert merged.usage.input_tokens == 15
      assert merged.usage.total_tokens == 18
      assert merged.usage.output_tokens == nil
    end

    test "all-nil usage fields stay nil, not 0" do
      merged = EmbeddingBatch.merge([response([]), response([])])

      assert merged.usage == %Usage{}
      assert merged.usage.input_tokens == nil
      assert merged.usage.total_tokens == nil
    end

    test "one chunk nil and another 10 yields 10" do
      a = response(usage: %Usage{input_tokens: nil, total_tokens: nil})
      b = response(usage: %Usage{input_tokens: 10, total_tokens: 10})

      merged = EmbeddingBatch.merge([a, b])

      assert merged.usage.input_tokens == 10
      assert merged.usage.total_tokens == 10
    end

    test "a chunk whose :usage is nil is skipped rather than raising" do
      a = %EmbeddingResponse{response([]) | usage: nil}
      b = response(usage: %Usage{input_tokens: 4, total_tokens: 4})

      merged = EmbeddingBatch.merge([a, b])

      assert merged.usage.input_tokens == 4
    end

    # A usage-field-loss regression is silent AND input-length-dependent: the
    # single-chunk fast path returns the adapter's `%Usage{}` verbatim, so a
    # field `merge_usage/1` forgets is populated below the chunk threshold and
    # reset above it. The batch-equivalence property asserts `usage` equality
    # but cannot see this — `FakeEmbeddings` only ever sets two counters — so
    # these two tests are the only guard.
    test "every numeric %Usage{} field sums and the map-valued fields merge" do
      a =
        response(
          usage: %Usage{
            input_tokens: 5,
            output_tokens: 1,
            cached_input_tokens: 2,
            reasoning_tokens: 3,
            total_tokens: 5,
            input_cost: 0.001,
            output_cost: 0.002,
            total_cost: 0.003,
            tool_usage: %{"t" => 1},
            extra: %{"provider_note" => "first", "shared" => "a"}
          }
        )

      b =
        response(
          usage: %Usage{
            input_tokens: 7,
            output_tokens: 2,
            cached_input_tokens: 4,
            reasoning_tokens: 6,
            total_tokens: 7,
            input_cost: 0.004,
            output_cost: 0.005,
            total_cost: 0.006,
            tool_usage: %{"u" => 2},
            extra: %{"shared" => "b"}
          }
        )

      merged = EmbeddingBatch.merge([a, b]).usage

      assert merged.input_tokens == 12
      assert merged.output_tokens == 3
      assert merged.cached_input_tokens == 6
      assert merged.reasoning_tokens == 9
      assert merged.total_tokens == 12
      assert_in_delta merged.input_cost, 0.005, 1.0e-9
      assert_in_delta merged.output_cost, 0.007, 1.0e-9
      assert_in_delta merged.total_cost, 0.009, 1.0e-9
      assert merged.tool_usage == %{"t" => 1, "u" => 2}
      # Earlier chunk wins on collision, matching the `:raw` / `:metadata` rule.
      assert merged.extra == %{"provider_note" => "first", "shared" => "a"}
    end

    test "no %Usage{} field is reset to its default — including fields added later" do
      # The fixture is derived from `%Usage{}` itself rather than written out,
      # so a NEW field added without a `merge_usage/1` rule fails HERE instead
      # of shipping as a silent multi-chunk-only data loss.
      defaults = Map.from_struct(%Usage{})
      populated = struct!(Usage, Map.new(defaults, fn {k, v} -> {k, usage_sentinel(v)} end))

      merged =
        EmbeddingBatch.merge([response(usage: populated), response(usage: populated)]).usage

      for {key, default} <- defaults do
        assert Map.fetch!(merged, key) != default,
               "merge/1 reset %Usage{}.#{key} to its default — add it to " <>
                 "@summed_usage_fields or @merged_usage_fields in ALLM.EmbeddingBatch"
      end
    end

    test "takes :model / :id / :request_id from the first non-nil" do
      a = response(model: nil, id: nil, request_id: nil)
      b = response(model: "m-b", id: "id-b", request_id: "rid-b")
      c = response(model: "m-c", id: "id-c", request_id: "rid-c")

      merged = EmbeddingBatch.merge([a, b, c])

      assert merged.model == "m-b"
      assert merged.id == "id-b"
      assert merged.request_id == "rid-b"
    end

    test "keeps only the first chunk's :raw and stamps metadata.chunk_count" do
      a = response(raw: %{"chunk" => 1}, metadata: %{trace: "t"})
      b = response(raw: %{"chunk" => 2})
      c = response(raw: %{"chunk" => 3})

      merged = EmbeddingBatch.merge([a, b, c])

      assert merged.raw == %{"chunk" => 1}
      assert merged.metadata == %{trace: "t", chunk_count: 3}
    end

    test "does NOT rebase indices — run/4 owns rebasing" do
      # Two chunks whose `:index` values collide. `merge/1` assumes globally
      # unique indices; it must not silently repair them.
      a = response(embeddings: [Embedding.new(vector: [1.0], index: 0)])
      b = response(embeddings: [Embedding.new(vector: [2.0], index: 0)])

      merged = EmbeddingBatch.merge([a, b])

      assert Enum.map(merged.embeddings, & &1.index) == [0, 0]
    end
  end

  # ---------------------------------------------------------------------------
  # run/4 — index rebasing and the single-chunk fast path
  # ---------------------------------------------------------------------------

  describe "run/4" do
    test "rebases each chunk's local indices by the chunk offset" do
      VariableBatchEmbeddingStub.put_max_batch_size(2)

      dispatch_opts = [
        adapter_opts: [embedding_script: script_for(5, 2)],
        retry_policy: :no_retry
      ]

      assert {:ok, resp} =
               EmbeddingBatch.run(req(5), VariableBatchEmbeddingStub, dispatch_opts, %{})

      assert Enum.map(resp.embeddings, & &1.index) == [0, 1, 2, 3, 4]
      assert EmbeddingResponse.vectors(resp) == Enum.map(0..4, &vec/1)
      assert resp.metadata.chunk_count == 3
    end

    test "single-chunk fast path returns the adapter response with chunk_count 1" do
      VariableBatchEmbeddingStub.put_max_batch_size(100)

      dispatch_opts = [
        adapter_opts: [embedding_script: script_for(3, 100)],
        retry_policy: :no_retry
      ]

      assert {:ok, resp} =
               EmbeddingBatch.run(req(3), VariableBatchEmbeddingStub, dispatch_opts, %{})

      assert resp.metadata.chunk_count == 1
      assert length(resp.embeddings) == 3
    end

    test "an empty input is dispatched once so the adapter's own gate fires" do
      VariableBatchEmbeddingStub.put_max_batch_size(10)

      assert {:error, err} =
               EmbeddingBatch.run(
                 req(0),
                 VariableBatchEmbeddingStub,
                 [retry_policy: :no_retry],
                 %{}
               )

      assert err.reason == :invalid_request
    end

    test "a non-conforming adapter raises ArgumentError naming the module and invariant" do
      # `ALLM.EmbeddingAdapter` is a PUBLIC behaviour: the caller set is open,
      # and the conformance suite's only two error cases are pre-flight
      # argument gates, so an adapter returning a raw transport error passes
      # conformance and reaches here. The raise must name the offender rather
      # than surface an anonymous `CaseClauseError` from a `@moduledoc false`
      # internal, and must NOT be laundered into `run/4`'s `@spec` union.
      assert_raise ArgumentError, ~r/NonConformingEmbeddingAdapter violated/, fn ->
        EmbeddingBatch.run(
          req(1),
          NonConformingEmbeddingAdapter,
          [retry_policy: :no_retry],
          %{}
        )
      end
    end

    test "the raise fires on the multi-chunk path too, and names the bad value" do
      assert_raise ArgumentError, ~r/invariant 2.*\{:error, :timeout\}/s, fn ->
        EmbeddingBatch.run(
          req(4),
          NonConformingEmbeddingAdapter,
          [retry_policy: :no_retry],
          %{}
        )
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Batch-equivalence property (see the relaxation table in @moduledoc)
  # ---------------------------------------------------------------------------

  describe "batch equivalence" do
    property "a chunked embed/3 equals an unchunked one over 1..500 inputs and 1..500 max" do
      check all(
              total <- StreamData.integer(1..500),
              max <- StreamData.integer(1..500),
              max_runs: 100
            ) do
        chunked = run_embed(total, max)
        unchunked = run_embed(total, total)

        assert_batch_equivalent(chunked, unchunked)
      end
    end
  end

  # Each arm runs in its own process: `put_max_batch_size/1` and
  # `FakeEmbeddings`' cursor are both process-dictionary state, so a shared
  # process would leak the previous arm's batch size and cursor position.
  defp run_embed(total, max) do
    task =
      Task.async(fn ->
        VariableBatchEmbeddingStub.put_max_batch_size(max)

        engine =
          Engine.new(
            embed_adapter: VariableBatchEmbeddingStub,
            adapter_opts: [embedding_script: script_for(total, max)],
            retry: false
          )

        ALLM.embed(engine, inputs(total), request_id: "fixed-rid")
      end)

    Task.await(task, 30_000)
  end

  defp assert_batch_equivalent({:ok, chunked}, {:ok, unchunked}) do
    # Relaxation 1: `metadata.chunk_count` necessarily differs.
    chunked_meta = Map.delete(chunked.metadata, :chunk_count)
    unchunked_meta = Map.delete(unchunked.metadata, :chunk_count)
    assert chunked_meta == unchunked_meta

    # Relaxation 2: `:raw` is only comparable on the single-chunk path.
    if chunked.metadata.chunk_count == 1 do
      assert chunked.raw == unchunked.raw
    end

    assert chunked.embeddings == unchunked.embeddings
    assert EmbeddingResponse.vectors(chunked) == EmbeddingResponse.vectors(unchunked)
    assert chunked.usage == unchunked.usage
    assert chunked.model == unchunked.model
    assert chunked.id == unchunked.id
    assert chunked.request_id == unchunked.request_id
  end
end
