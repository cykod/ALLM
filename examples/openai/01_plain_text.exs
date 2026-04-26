# examples/openai/01_plain_text.exs
#
# Demonstrates: a plain non-streaming `ALLM.generate/3` round-trip against the
#               real OpenAI provider.
# Spec section: §4 (top-level facade), §10.1 (generate/3).
# Steering strategy: tight — hard system prompt narrows the assistant to one
#                    word; the assertion is exact-match.
# Natural alternative (commented out below):
#   ALLM.user("Say hi.")
# Run with:    OPENAI_API_KEY=sk-... mix run examples/openai/01_plain_text.exs

# Auto-load OPENAI_API_KEY from project-root .env if not already in env.
if System.get_env("OPENAI_API_KEY") in [nil, ""], do: EnvLoader.load(Path.expand(".env", Path.join(__DIR__, "../..")))

Application.ensure_all_started(:allm)

engine =
  ALLM.Engine.new(
    adapter: ALLM.Providers.OpenAI,
    model: System.get_env("ALLM_MODEL", "gpt-5.4-nano"),
    # `gpt-5.4-nano`'s legal effort enum is `:none | :low | :medium | :high |
    # :xhigh` (the bundled adapter previously also accepted `:minimal`, which
    # the API rejects on this model — removed in the Phase 10.5 retro fix).
    # `:none` is the cheapest reasoning-model call. Override via
    # `ALLM_MODEL=gpt-4.1-mini` for an even cheaper Chat-Completions path;
    # that path silently strips the key.
    params: %{reasoning_effort: :none}
  )

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
