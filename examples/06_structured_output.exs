# examples/06_structured_output.exs
#
# Demonstrates: a JSON-schema constrained response via `ALLM.json_schema/3`
#               + `response_format:` opt; the model is forced to emit JSON
#               conforming to the supplied schema.
# Spec section: §5.4 (response_format), §10.4 (structured_finalize),
#               §11 Decision #4 (Anthropic tool-forcing lift + structured_output_tool marker).
# Steering strategy: tight — `strict: true` schema + system prompt that names
#                    the schema obligation. Assertion: JSON decodes and the
#                    `message` field contains "OK".
# Natural alternative (commented out below):
#   ALLM.user("Reply with a JSON greeting.")  # without response_format
# Run with:    OPENAI_API_KEY=sk-... mix run examples/06_structured_output.exs                                # default
#         OR:  ANTHROPIC_API_KEY=sk-ant-... ALLM_PROVIDER=anthropic mix run examples/06_structured_output.exs

Application.ensure_all_started(:allm)
Code.require_file("_helpers.exs", __DIR__)

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

engine = ExamplesHelpers.engine()

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

# Anthropic-only: structured-output via tool-forcing stamps
# `metadata.structured_output_tool == true` on the final response per Decision #4.
# OpenAI's native :json_schema response carries no equivalent marker.
if System.get_env("ALLM_PROVIDER", "openai") == "anthropic" do
  unless result.final_response.metadata[:structured_output_tool] == true do
    IO.puts(
      :stderr,
      "FAIL: expected metadata.structured_output_tool == true for Anthropic, got " <>
        inspect(result.final_response.metadata[:structured_output_tool])
    )

    System.halt(1)
  end
end

IO.puts("OK: structured_output — decoded=#{inspect(decoded)} pass_1=#{inspect(pass_1_halted)}")
