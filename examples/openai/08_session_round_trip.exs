# examples/openai/08_session_round_trip.exs
#
# Demonstrates: a `%Session{}` survives a binary round-trip via
#               `:erlang.term_to_binary/1` / `:erlang.binary_to_term/1` and
#               continues to drive `Session.reply/4` indistinguishably from
#               an in-memory session.
# Spec section: §4 (Session API), §5.10 (Session shape), §10.7.
# Steering strategy: tight — hard system prompt forces a one-word reply so
#                    both paths produce byte-identical text. Reasoning models
#                    are sufficiently deterministic at `:none` effort to
#                    satisfy the equality assertion in practice; if they
#                    diverge, fall back to the "essentially identical"
#                    weakening recorded in the script's FAIL message.
# Natural alternative (commented out below):
#   ALLM.user("Tell me a joke.")
# Run with:    OPENAI_API_KEY=sk-... mix run examples/openai/08_session_round_trip.exs

# Auto-load OPENAI_API_KEY from project-root .env if not already in env.
if System.get_env("OPENAI_API_KEY") in [nil, ""], do: EnvLoader.load(Path.expand(".env", Path.join(__DIR__, "../..")))

Application.ensure_all_started(:allm)

engine =
  ALLM.Engine.new(
    adapter: ALLM.Providers.OpenAI,
    model: System.get_env("ALLM_MODEL", "gpt-5.4-nano"),
    params: %{reasoning_effort: :none}
  )

start_messages = [
  ALLM.system("Reply with exactly one word: the word the user supplies."),
  ALLM.user("Acknowledge with the word 'OK'.")
]

{:ok, session_in_memory, _result1a} = ALLM.Session.start(engine, start_messages)

# Round-trip through term-encoded binary (the v0.2 wire format).
binary = :erlang.term_to_binary(session_in_memory)
session_round_tripped = :erlang.binary_to_term(binary)

reply_text = "Now reply with exactly the word 'PING'."

{:ok, _s_mem, result_mem} = ALLM.Session.reply(engine, session_in_memory, reply_text)
{:ok, _s_rt, result_rt} = ALLM.Session.reply(engine, session_round_tripped, reply_text)

text_mem = result_mem.final_response.output_text
text_rt = result_rt.final_response.output_text

# Both replies should produce the same text. With a one-word forced answer,
# byte-equality holds in practice; if a reviewer sees a divergence here on
# a future model rev, this is the line to relax to `String.trim/1`-equality.
ok? = is_binary(text_mem) and text_mem == text_rt

unless ok? do
  IO.puts(
    :stderr,
    "FAIL: session_round_trip — in_mem=#{inspect(text_mem)} round_tripped=#{inspect(text_rt)}"
  )

  System.halt(1)
end

IO.puts(
  "OK: session_round_trip — both paths produced #{inspect(text_mem)} (binary length=#{byte_size(binary)})"
)
