# examples/20_moderate_image.exs
#
# Provider: openai
#
# Same marker rationale as `19_moderate_text.exs`: moderation is a
# single-provider capability, so `run_all.exs` skips this script on the
# anthropic and gemini arms.
#
# Demonstrates: a MULTIMODAL `ALLM.moderate/3` call — one text string and one
#               `%ALLM.ImagePart{}` in the same `:input` list — and the
#               cardinality rule that makes it different from script 19. Any
#               image present means the whole `:input` is ONE item judged as a
#               whole, so the provider returns exactly one result however long
#               the list is. `ALLM.ModerationRequest.multimodal?/1` derives
#               that BEFORE the call; the script asserts the count it derived
#               against the count that actually came back.
#
#               Also prints `:applied_input_types`, the per-category map
#               saying which parts of the input triggered each category. It is
#               the only evidence available that the image was classified
#               rather than silently ignored.
# Spec section: §39.2 (result cardinality), §39.6 (image input).
# Steering strategy: tight on cardinality and index, loose on the verdict. The
#                    fixture is the checked-in 256×256 kestrel PNG that
#                    `12_vision_input.exs` uses — a benign photograph, so the
#                    expected verdict is "not flagged", but the assertion is
#                    the SHAPE (exactly one result, index 0, populated score
#                    map), never a category or a float.
#
#                    The image is inlined as a `data:` URI, not fetched from a
#                    host: `/v1/moderations` accepts data URIs (observed live
#                    2026-09-01), so the script depends on no third party and
#                    re-runs identically offline of everything but OpenAI.
# Cost: $0.00 USD. The `/v1/moderations` endpoint is free.
# Run with:    OPENAI_API_KEY=sk-... mix run examples/20_moderate_image.exs

Application.ensure_all_started(:allm)
Code.require_file("_helpers.exs", __DIR__)

engine = ExamplesHelpers.moderation_engine()

image =
  __DIR__
  |> Path.join("fixtures/kestrel_256.png")
  |> File.read!()
  |> ALLM.Image.from_binary("image/png")

input = [
  "Is this photograph acceptable to publish?",
  %ALLM.ImagePart{image: image}
]

# The cardinality is derivable before the call — this is the whole point of
# `multimodal?/1`. Build the request explicitly so the derivation is visible.
request = ALLM.moderation_request(input)
multimodal? = ALLM.ModerationRequest.multimodal?(request)

if not multimodal? do
  ExamplesHelpers.fail!("multimodal?/1 returned false for an input carrying an %ALLM.ImagePart{}")
end

# Past the halt above, `multimodal?` is necessarily true, and the cardinality
# rule for a multimodal request is one result for the whole input regardless of
# how many elements it carries. Binding this before the halt would compute an
# `else` branch no run can reach.
expected_results = 1

case ALLM.moderate(engine, request) do
  {:ok, %ALLM.ModerationResponse{results: results} = resp} ->
    cond do
      length(results) != expected_results ->
        ExamplesHelpers.fail!(
          "multimodal?/1 predicted #{expected_results} result(s) for a " <>
            "#{length(input)}-element input; the provider returned #{length(results)}"
        )

      true ->
        [result] = results

        cond do
          result.index != 0 ->
            ExamplesHelpers.fail!(
              "expected index 0 on the single multimodal result, got #{result.index}"
            )

          map_size(result.category_scores) == 0 ->
            ExamplesHelpers.fail!("expected a populated category_scores map")

          not Enum.all?(Map.values(result.category_scores), &is_float/1) ->
            ExamplesHelpers.fail!("expected every category score to be a float")

          result.flagged ->
            ExamplesHelpers.fail!(
              "expected a benign photograph NOT to be flagged; categories=" <>
                inspect(ALLM.ModerationResult.flagged_categories(result))
            )

          true ->
            # Which categories considered the image at all. `%{}` when the
            # provider does not report it — printed, never asserted, because
            # it is the model's to change.
            image_typed =
              result.applied_input_types
              |> Enum.filter(fn {_category, types} -> "image" in types end)
              |> Enum.map(fn {category, _types} -> category end)
              |> Enum.sort()

            IO.puts(
              "OK: moderate image — multimodal=true input_elements=#{length(input)} " <>
                "results=#{length(results)} index=0 flagged=false " <>
                "categories_scored=#{map_size(result.category_scores)} " <>
                "applied_to_image=#{inspect(image_typed)} model=#{inspect(resp.model)}"
            )
        end
    end

  {:error, error} ->
    ExamplesHelpers.fail!("ALLM.moderate/3 returned error #{inspect(error)}")
end
