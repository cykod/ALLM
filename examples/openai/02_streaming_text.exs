# examples/openai/02_streaming_text.exs
#
# Demonstrates: lazy `ALLM.stream_generate/3` consumption — prints text deltas
#               as they arrive over SSE, then asserts the reduced text and
#               event-shape invariants.
# Spec section: §3 (stream-first), §4, §10.2.
# Steering strategy: tight — same prompt as 01; deterministic output lets the
#                    assertion compare the reduced text exactly.
# Natural alternative (commented out below):
#   ALLM.user("Stream me a haiku about Elixir.")
# Run with:    OPENAI_API_KEY=sk-... mix run examples/openai/02_streaming_text.exs

# Auto-load OPENAI_API_KEY from project-root .env if not already in env.
if System.get_env("OPENAI_API_KEY") in [nil, ""], do: EnvLoader.load(Path.expand(".env", Path.join(__DIR__, "../..")))

Application.ensure_all_started(:allm)

engine =
  ALLM.Engine.new(
    adapter: ALLM.Providers.OpenAI,
    model: System.get_env("ALLM_MODEL", "gpt-5.4-nano"),
    params: %{reasoning_effort: :none}
  )

request =
  ALLM.request([
    ALLM.system("Reply with exactly the word 'OK' and no other text."),
    ALLM.user("Acknowledge.")
  ])

{:ok, stream} = ALLM.stream_generate(engine, request)

events = Enum.to_list(stream)

# Print the live deltas as they arrived (replay; the stream has already been
# reduced to a list above for the assertion).
IO.write("delta stream: ")

Enum.each(events, fn
  {:text_delta, %{delta: t}} -> IO.write(t)
  _ -> :ok
end)

IO.puts("")

reduced_text =
  events
  |> Enum.flat_map(fn
    {:text_delta, %{delta: t}} -> [t]
    _ -> []
  end)
  |> Enum.join()

deltas_count = Enum.count(events, &match?({:text_delta, _}, &1))
completed_count = Enum.count(events, &match?({:message_completed, _}, &1))

ok? =
  deltas_count > 0 and
    completed_count == 1 and
    String.trim(reduced_text) == "OK"

unless ok? do
  IO.puts(
    :stderr,
    "FAIL: streaming invariants not met — deltas=#{deltas_count} completed=#{completed_count} text=#{inspect(reduced_text)}"
  )

  System.halt(1)
end

IO.puts(
  "OK: streaming_text — deltas=#{deltas_count} completed=#{completed_count} reduced=#{inspect(reduced_text)}"
)
