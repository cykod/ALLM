# examples/openai/06_structured_output.exs
#
# Demonstrates: a JSON-schema constrained response via `ALLM.json_schema/3`
#               + `response_format:` opt; the model is forced to emit JSON
#               conforming to the supplied schema.
# Spec section: §5.4 (response_format), §10.4 (structured_finalize).
# Steering strategy: tight — `strict: true` schema + system prompt that names
#                    the schema obligation. Assertion: JSON decodes and the
#                    `message` field contains "OK".
# Natural alternative (commented out below):
#   ALLM.user("Reply with a JSON greeting.")  # without response_format
# Run with:    OPENAI_API_KEY=sk-... mix run examples/openai/06_structured_output.exs

# Auto-load OPENAI_API_KEY from project-root .env if not already in env.
if System.get_env("OPENAI_API_KEY") in [nil, ""], do: EnvLoader.load(Path.expand(".env", Path.join(__DIR__, "../..")))

Application.ensure_all_started(:allm)

schema =
  ALLM.json_schema(
    "greeting",
    %{
      type: "object",
      properties: %{message: %{type: "string"}},
      required: ["message"],
      additionalProperties: false
    },
    strict: true
  )

engine =
  ALLM.Engine.new(
    adapter: ALLM.Providers.OpenAI,
    model: System.get_env("ALLM_MODEL", "gpt-5.4-nano"),
    params: %{reasoning_effort: :none}
  )

messages = [
  ALLM.system("Always emit valid JSON conforming to the schema."),
  ALLM.user("Greet me with the word 'OK'.")
]

{:ok, result} = ALLM.chat(engine, messages, response_format: schema)

decoded = Jason.decode(result.final_response.output_text || "")

structured_meta = Map.get(result.metadata, :structured_finalize, %{})
pass_1_halted = Map.get(structured_meta, :pass_1_halted)

ok? =
  match?({:ok, %{"message" => _}}, decoded) and
    case decoded do
      {:ok, %{"message" => msg}} -> String.contains?(msg, "OK")
      _ -> false
    end and
    pass_1_halted in [:completed, nil]

unless ok? do
  IO.puts(
    :stderr,
    "FAIL: structured_output — decoded=#{inspect(decoded)} pass_1=#{inspect(pass_1_halted)}"
  )

  System.halt(1)
end

IO.puts("OK: structured_output — decoded=#{inspect(decoded)} pass_1=#{inspect(pass_1_halted)}")
