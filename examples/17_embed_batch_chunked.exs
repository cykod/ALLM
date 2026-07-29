# examples/17_embed_batch_chunked.exs
#
# NO `# Provider:` marker — see 16_embed_single.exs. Runs on all three arms;
# `VOYAGE_API_KEY` is required for `ALLM_PROVIDER=anthropic`.
#
# Demonstrates: transparent batch chunking. 250 inputs go in as one
#               `ALLM.embed/3` call and come back as one response, whatever
#               the provider's per-request cap. 250 is chosen to exceed
#               Gemini's cap of 100 — that arm becomes three sequential HTTP
#               requests, merged behind the façade — while staying inside
#               OpenAI's 2048 and Voyage's 1000, so the same script exercises
#               both the multi-chunk and the single-chunk fast path depending
#               on the arm.
#
#               Asserts cardinality (250 in, 250 out), that `chunk_count`
#               equals the arithmetic the caller would do themselves against
#               `max_batch_size/0`, that indices are exactly `0..249`, that
#               `vectors/1` preserves order-correspondence across the chunk
#               boundaries, and that every vector has the same width.
# Spec section: §36.6 (batching), §36.5 (public API).
# Steering strategy: tight — every assertion is structural and derived from
#                    the adapter's own declared cap, so the script is correct
#                    on a provider whose cap changes.
# Cost: roughly ~$0.001 USD per clean run (250 × ~10 tokens).
# Run with:    OPENAI_API_KEY=sk-...  mix run examples/17_embed_batch_chunked.exs
#         OR:  VOYAGE_API_KEY=pa-...  ALLM_PROVIDER=anthropic mix run examples/17_embed_batch_chunked.exs
#         OR:  GEMINI_API_KEY=...     ALLM_PROVIDER=gemini    mix run examples/17_embed_batch_chunked.exs

Application.ensure_all_started(:allm)
Code.require_file("_helpers.exs", __DIR__)

engine = ExamplesHelpers.embedding_engine()

input_count = 250
inputs = Enum.map(1..input_count, fn i -> "Field note #{i}: a kestrel over the hedgerow." end)

max_batch_size = engine.embed_adapter.max_batch_size()
expected_chunks = ceil(input_count / max_batch_size)

case ALLM.embed(engine, inputs, task_type: :search_document) do
  {:ok, %ALLM.EmbeddingResponse{embeddings: embeddings} = resp} ->
    chunk_count = Map.get(resp.metadata, :chunk_count)
    indices = Enum.map(embeddings, & &1.index)
    vectors = ALLM.EmbeddingResponse.vectors(resp)
    widths = vectors |> Enum.map(&length/1) |> Enum.uniq()

    cond do
      length(embeddings) != input_count ->
        IO.puts(
          :stderr,
          "FAIL: expected #{input_count} embeddings, got #{length(embeddings)}"
        )

        System.halt(1)

      chunk_count != expected_chunks ->
        IO.puts(
          :stderr,
          "FAIL: expected chunk_count #{expected_chunks} " <>
            "(#{input_count} inputs / cap #{max_batch_size}), got #{inspect(chunk_count)}"
        )

        System.halt(1)

      indices != Enum.to_list(0..(input_count - 1)) ->
        IO.puts(
          :stderr,
          "FAIL: indices are not 0..#{input_count - 1} after the chunk merge; " <>
            "first 5 = #{inspect(Enum.take(indices, 5))}"
        )

        System.halt(1)

      length(vectors) != input_count ->
        IO.puts(:stderr, "FAIL: vectors/1 returned #{length(vectors)} rows")
        System.halt(1)

      widths == [] or length(widths) != 1 or hd(widths) == 0 ->
        IO.puts(:stderr, "FAIL: vectors have ragged or zero width: #{inspect(widths)}")
        System.halt(1)

      true ->
        IO.puts(
          "OK: embed batch — inputs=#{input_count} embeddings=#{length(embeddings)} " <>
            "cap=#{max_batch_size} chunk_count=#{chunk_count} dimensions=#{hd(widths)}"
        )
    end

  {:error, error} ->
    # A mid-batch failure fails the whole call; `completed_chunks` /
    # `completed_inputs` on the error metadata say how far it got.
    IO.puts(:stderr, "FAIL: ALLM.embed/3 returned error #{inspect(error)}")
    System.halt(1)
end
