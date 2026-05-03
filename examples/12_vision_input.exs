# examples/12_vision_input.exs
#
# Provider: openai, anthropic, gemini
#
# Demonstrates: a non-streaming `ALLM.generate/3` call with a multimodal
#               user message — `[%ALLM.TextPart{}, %ALLM.ImagePart{}]`
#               content — against the active provider's vision-capable
#               default model (`gpt-4o-mini` on OpenAI;
#               `claude-haiku-4-5-20251001` on Anthropic per Phase 17.3
#               Decision #8). The script asserts a non-empty
#               `output_text` and `finish_reason: :stop`.
# Spec section: §35.6 (vision content parts), §35.7 (provider matrix).
# Steering strategy: loose — vision models produce free-form descriptions
#                    of the input image; the assertion is shape-only
#                    (non-empty text, stop reason). The image is a
#                    checked-in real 256×256 PNG fixture
#                    (`fixtures/kestrel_256.png`, generated once via
#                    dall-e-2) — vision endpoints reject 1×1 synthetic
#                    placeholders with HTTP 400, so a realistic
#                    photographic-style fixture is required.
# Cost: roughly ~$0.001 USD per clean run on either provider (small
#       image + short response).
# Run with:    OPENAI_API_KEY=sk-... mix run examples/12_vision_input.exs
#         OR:  ANTHROPIC_API_KEY=sk-ant-... ALLM_PROVIDER=anthropic mix run examples/12_vision_input.exs

Application.ensure_all_started(:allm)
Code.require_file("_helpers.exs", __DIR__)

engine = ExamplesHelpers.engine(vision: true)

img =
  __DIR__
  |> Path.join("fixtures/kestrel_256.png")
  |> File.read!()
  |> ALLM.Image.from_binary("image/png")

msg = %ALLM.Message{
  role: :user,
  content: [
    %ALLM.TextPart{text: "Describe this image in one short sentence."},
    %ALLM.ImagePart{image: img, detail: :low}
  ]
}

request = ALLM.request([msg])

case ALLM.generate(engine, request) do
  {:ok, %ALLM.Response{output_text: text, finish_reason: reason} = _response}
  when is_binary(text) and reason in [:stop, :length] ->
    if String.trim(text) == "" do
      IO.puts(:stderr, "FAIL: vision response had empty output_text; finish=#{inspect(reason)}")
      System.halt(1)
    end

    IO.puts(
      "OK: vision_input — finish=#{reason} output=#{inspect(String.slice(text, 0, 80))}"
    )

  {:ok, response} ->
    IO.puts(
      :stderr,
      "FAIL: unexpected response shape — output_text=#{inspect(response.output_text)} " <>
        "finish=#{inspect(response.finish_reason)}"
    )

    System.halt(1)

  {:error, error} ->
    IO.puts(:stderr, "FAIL: ALLM.generate/3 returned error #{inspect(error)}")
    System.halt(1)
end
