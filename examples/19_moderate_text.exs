# examples/19_moderate_text.exs
#
# Provider: openai
#
# The marker is deliberate and is the opposite of the embedding scripts'
# (16–18) deliberate ABSENCE of one. Moderation is a single-provider
# capability — Anthropic ships no moderation endpoint and Gemini's safety
# ratings ride `generateContent` rather than a standalone call — so
# `run_all.exs` SKIPS this script on those arms instead of halting the run
# on `moderation_engine/1`'s ArgumentError.
#
# Demonstrates: `ALLM.moderate/3` over an all-strings `:input`. Asserts the
#               batch cardinality rule (one result per input string, indices
#               0..n-1 in input order), that the obviously-violent string is
#               flagged while the benign one is not, that
#               `ALLM.ModerationResponse.flagged?/1` reports true for the
#               batch as a whole, and that `ModerationResult.score/2` returns
#               a float for a category `flagged_categories/1` named.
# Spec section: §39.5 (public API), §39.2 (data model), §39.6 (adapter notes).
# Steering strategy: tight on shape, loose on the classifier. The assertions
#                    are cardinality, index order, score types, and the
#                    agreement between `:categories` and `:category_scores` —
#                    never a specific category name or a specific float, both
#                    of which are the model's to change. The one verdict
#                    asserted is that a plain threat IS flagged; a moderation
#                    endpoint that answers "clean" to that is broken, not
#                    merely differently tuned.
# Cost: $0.00 USD. The `/v1/moderations` endpoint is free.
# Run with:    OPENAI_API_KEY=sk-... mix run examples/19_moderate_text.exs

Application.ensure_all_started(:allm)
Code.require_file("_helpers.exs", __DIR__)

engine = ExamplesHelpers.moderation_engine()

benign = "A kestrel hovers over a hedgerow, hunting voles."
violent = "I am going to hunt you down and kill you with my bare hands."

fail = fn msg ->
  IO.puts(:stderr, "FAIL: #{msg}")
  System.halt(1)
end

case ALLM.moderate(engine, [benign, violent]) do
  {:ok, %ALLM.ModerationResponse{results: results} = resp} ->
    cond do
      length(results) != 2 ->
        fail.(
          "expected 2 results for a 2-string input (the batch cardinality rule), " <>
            "got #{length(results)}"
        )

      Enum.map(results, & &1.index) != [0, 1] ->
        fail.(
          "expected indices [0, 1] in input order, got #{inspect(Enum.map(results, & &1.index))}"
        )

      true ->
        [clean, threat] = results

        cond do
          clean.flagged ->
            fail.(
              "expected the benign string NOT to be flagged; categories=" <>
                inspect(ALLM.ModerationResult.flagged_categories(clean))
            )

          not threat.flagged ->
            fail.("expected an explicit threat to be flagged, got flagged: false")

          not ALLM.ModerationResponse.flagged?(resp) ->
            fail.("flagged?/1 must be true when any result is flagged")

          map_size(threat.category_scores) == 0 ->
            fail.("expected a populated category_scores map on the flagged result")

          not Enum.all?(Map.values(threat.category_scores), &is_float/1) ->
            fail.("expected every category score to be a float")

          true ->
            categories = ALLM.ModerationResult.flagged_categories(threat)

            case categories do
              [] ->
                fail.("a flagged result must name at least one true category")

              [first | _] ->
                score = ALLM.ModerationResult.score(threat, first)

                if not is_float(score) do
                  fail.(
                    "score/2 for a flagged category #{inspect(first)} returned #{inspect(score)}"
                  )
                end

                IO.puts(
                  "OK: moderate text — results=2 clean_flagged=false threat_flagged=true " <>
                    "categories=#{inspect(categories)} top_score=#{Float.round(score, 4)} " <>
                    "model=#{inspect(resp.model)} id=#{inspect(resp.id)}"
                )
            end
        end
    end

  {:error, error} ->
    fail.("ALLM.moderate/3 returned error #{inspect(error)}")
end
