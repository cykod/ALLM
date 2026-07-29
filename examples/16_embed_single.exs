# examples/16_embed_single.exs
#
# NO `# Provider:` marker — deliberate. Every bundled provider arm has an
# embedding adapter, including Anthropic's (which routes to Voyage AI, since
# Anthropic ships no embeddings endpoint). `run_all.exs` therefore runs this
# script on all three arms. Consequence: `VOYAGE_API_KEY` is a hard
# requirement for `ALLM_PROVIDER=anthropic`.
#
# Demonstrates: the simplest `ALLM.embed/3` call — one input string in, one
#               `%ALLM.Embedding{}` out. Asserts cardinality (1), a non-empty
#               all-float vector, `index: 0`, that
#               `ALLM.EmbeddingResponse.dimensions/1` agrees with the vector
#               length (this is the number you size a `vector(N)` column
#               with), and `metadata.chunk_count == 1` (one input never
#               chunks).
# Spec section: §36.5 (public API), §36.2 (data model), §36.7 (provider
#               adapters).
# Steering strategy: tight — the assertions are structural (cardinality,
#                    element type, width agreement) and independent of the
#                    actual float values, which differ per provider and per
#                    model and are not reproducible.
# Cost: well under $0.001 USD per clean run on every arm (a handful of
#       tokens).
# Run with:    OPENAI_API_KEY=sk-...  mix run examples/16_embed_single.exs
#         OR:  VOYAGE_API_KEY=pa-...  ALLM_PROVIDER=anthropic mix run examples/16_embed_single.exs
#         OR:  GEMINI_API_KEY=...     ALLM_PROVIDER=gemini    mix run examples/16_embed_single.exs

Application.ensure_all_started(:allm)
Code.require_file("_helpers.exs", __DIR__)

engine = ExamplesHelpers.embedding_engine()

input = "A kestrel hovers over a hedgerow, hunting voles."

case ALLM.embed(engine, input) do
  {:ok, %ALLM.EmbeddingResponse{embeddings: [%ALLM.Embedding{} = embedding], usage: usage} = resp} ->
    vector = embedding.vector
    width = ALLM.EmbeddingResponse.dimensions(resp)

    cond do
      not is_list(vector) or vector == [] ->
        IO.puts(:stderr, "FAIL: embedding vector is empty or not a list: #{inspect(vector)}")
        System.halt(1)

      not Enum.all?(vector, &is_float/1) ->
        IO.puts(:stderr, "FAIL: embedding vector has non-float elements")
        System.halt(1)

      embedding.index != 0 ->
        IO.puts(:stderr, "FAIL: expected index 0 for a single input, got #{embedding.index}")
        System.halt(1)

      width != length(vector) ->
        IO.puts(
          :stderr,
          "FAIL: dimensions/1 returned #{inspect(width)} but the vector is #{length(vector)} wide"
        )

        System.halt(1)

      Map.get(resp.metadata, :chunk_count) != 1 ->
        IO.puts(
          :stderr,
          "FAIL: expected chunk_count 1 for a single input, got " <>
            inspect(Map.get(resp.metadata, :chunk_count))
        )

        System.halt(1)

      true ->
        # Gemini reports no usage metadata at all, so `total_tokens` is nil
        # there by design — printed, never asserted.
        IO.puts(
          "OK: embed single — dimensions=#{width} index=#{embedding.index} " <>
            "chunk_count=1 total_tokens=#{inspect(usage.total_tokens)} model=#{inspect(resp.model)}"
        )
    end

  {:ok, %ALLM.EmbeddingResponse{embeddings: embeddings}} ->
    IO.puts(:stderr, "FAIL: expected exactly 1 embedding, got #{length(embeddings)}")
    System.halt(1)

  {:error, error} ->
    IO.puts(:stderr, "FAIL: ALLM.embed/3 returned error #{inspect(error)}")
    System.halt(1)
end
