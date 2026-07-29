# examples/18_embed_query_vs_document.exs
#
# NO `# Provider:` marker — see 16_embed_single.exs. Runs on all three arms;
# `VOYAGE_API_KEY` is required for `ALLM_PROVIDER=anthropic`.
#
# Demonstrates: asymmetric embedding — the retrieval pattern the `:task_type`
#               enum exists for. Two documents are embedded with
#               `task_type: :search_document`; a query is embedded with
#               `task_type: :search_query`; the script ranks the documents by
#               cosine similarity and asserts the on-topic one wins.
#
#               `:task_type` is provider-neutral and deliberately lossy: Gemini
#               maps all five members onto its `taskType` enum, Voyage supports
#               only query/document, and OpenAI has no equivalent and drops the
#               field entirely (logged at :debug). A dropped task type is never
#               an error, so this script runs unchanged on every arm — on
#               OpenAI it simply measures symmetric embeddings.
# Spec section: §36.2 (task types), §36.7 (per-provider mapping).
# Steering strategy: loose — the assertion is a RANKING, not a threshold. The
#                    two documents are on wildly different topics so the
#                    ordering is stable across models; no absolute similarity
#                    value is asserted, since those are not comparable across
#                    providers or models.
# Cost: well under $0.001 USD per clean run (3 short inputs).
# Run with:    OPENAI_API_KEY=sk-...  mix run examples/18_embed_query_vs_document.exs
#         OR:  VOYAGE_API_KEY=pa-...  ALLM_PROVIDER=anthropic mix run examples/18_embed_query_vs_document.exs
#         OR:  GEMINI_API_KEY=...     ALLM_PROVIDER=gemini    mix run examples/18_embed_query_vs_document.exs

Application.ensure_all_started(:allm)
Code.require_file("_helpers.exs", __DIR__)

engine = ExamplesHelpers.embedding_engine()

on_topic = "Kestrels hunt by hovering over open grassland, watching for voles."
off_topic = "Sourdough starter needs a warm kitchen and twice-daily feeding."
query = "How does a kestrel catch its prey?"

cosine = fn a, b ->
  dot = a |> Enum.zip(b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
  norm = fn v -> :math.sqrt(Enum.reduce(v, 0.0, fn x, acc -> acc + x * x end)) end
  magnitude = norm.(a) * norm.(b)

  if magnitude == 0.0, do: 0.0, else: dot / magnitude
end

with {:ok, docs} <- ALLM.embed(engine, [on_topic, off_topic], task_type: :search_document),
     {:ok, q} <- ALLM.embed(engine, query, task_type: :search_query) do
  [on_topic_vector, off_topic_vector] = ALLM.EmbeddingResponse.vectors(docs)
  [query_vector] = ALLM.EmbeddingResponse.vectors(q)

  on_topic_score = cosine.(query_vector, on_topic_vector)
  off_topic_score = cosine.(query_vector, off_topic_vector)

  cond do
    length(on_topic_vector) != length(query_vector) ->
      IO.puts(
        :stderr,
        "FAIL: query and document vectors have different widths " <>
          "(#{length(query_vector)} vs #{length(on_topic_vector)}) — they are not comparable"
      )

      System.halt(1)

    on_topic_score <= off_topic_score ->
      IO.puts(
        :stderr,
        "FAIL: the off-topic document ranked at least as high as the on-topic one " <>
          "(on_topic=#{Float.round(on_topic_score, 4)} " <>
          "off_topic=#{Float.round(off_topic_score, 4)})"
      )

      System.halt(1)

    true ->
      IO.puts(
        "OK: query vs document — dimensions=#{length(query_vector)} " <>
          "on_topic=#{Float.round(on_topic_score, 4)} " <>
          "off_topic=#{Float.round(off_topic_score, 4)}"
      )
  end
else
  {:error, error} ->
    IO.puts(:stderr, "FAIL: ALLM.embed/3 returned error #{inspect(error)}")
    System.halt(1)
end
