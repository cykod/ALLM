# examples/01_plain_text.exs
#
# Demonstrates: a plain non-streaming `ALLM.generate/3` round-trip against the
#               active provider (OpenAI by default; Anthropic via ALLM_PROVIDER).
# Spec section: §4 (top-level facade), §10.1 (generate/3).
# Steering strategy: tight — hard system prompt narrows the assistant to one
#                    word; the assertion is exact-match.
# Natural alternative (commented out below):
#   ALLM.user("Say hi.")
# Run with:    OPENAI_API_KEY=sk-... mix run examples/01_plain_text.exs                                # default
#         OR:  ANTHROPIC_API_KEY=sk-ant-... ALLM_PROVIDER=anthropic mix run examples/01_plain_text.exs

Application.ensure_all_started(:allm)
Code.require_file("_helpers.exs", __DIR__)

engine = ExamplesHelpers.engine()

request =
  ALLM.request([
    ALLM.system("Reply with exactly the word 'OK' and no other text."),
    ALLM.user("Acknowledge.")
  ])

{:ok, response} = ALLM.generate(engine, request)

unless String.trim(response.output_text || "") == "OK" and response.finish_reason == :stop do
  IO.puts(
    :stderr,
    "FAIL: expected output_text 'OK' / finish_reason :stop, got " <>
      inspect({response.output_text, response.finish_reason})
  )

  System.halt(1)
end

IO.puts("OK: plain_text — output=#{inspect(response.output_text)} finish=#{response.finish_reason}")
