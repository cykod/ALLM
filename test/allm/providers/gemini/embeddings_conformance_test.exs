defmodule ALLM.Providers.Gemini.EmbeddingsConformanceTest do
  @moduledoc """
  `ALLM.Test.EmbeddingAdapterConformance` invocation against
  `ALLM.Providers.Gemini.Embeddings`.

  Eight of the ten cases drive the adapter through the
  `adapter_opts[:embedding_script]` test-injection short-circuit, which
  delegates to `ALLM.Providers.FakeEmbeddings.embed/2` BEFORE any pre-flight
  gate runs. Cases 3 and 4 pass no script and therefore assert against this
  adapter's own `:batch_too_large` / `:invalid_request` gates — which is why
  those gates must fire ahead of `ALLM.Keys.fetch!/2`, so a keyless CI
  environment still observes the rejection.

  **This suite does not bind `ALLM.EmbeddingAdapter` invariant 8 for this
  adapter.** The scripted success path returns the harness's own embeddings
  verbatim and never reaches `decode_response/4`. That matters more here than
  on the OpenAI adapter, because Gemini's response carries no index field and
  `:index` is assigned by list position — a dropped sub-response shifts every
  subsequent index silently. Invariant 8 is bound by the `decode_response/4`
  fixture test in `test/allm/providers/gemini/embeddings_test.exs`.
  """

  use ExUnit.Case, async: true
  use ALLM.Test.EmbeddingAdapterConformance, embedding_adapter: ALLM.Providers.Gemini.Embeddings
end
