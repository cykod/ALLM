# examples/03_single_tool_call.exs
#
# Demonstrates: a one-tool round-trip via `ALLM.chat/3` — the model calls
#               `get_weather`, the loop runs the handler, then a second turn
#               synthesises the final assistant text.
# Spec section: §4 (chat/3), §10.5, §6 (tools).
# Steering strategy: tight — system prompt forces the model to call the tool
#                    and then repeat its forecast verbatim. Assertion checks
#                    tool message presence + final text contains "sunny".
# Natural alternative (commented out below):
#   ALLM.user("What's the weather in Boston?")  # without the system steer
# Run with:    OPENAI_API_KEY=sk-... mix run examples/03_single_tool_call.exs                                # default
#         OR:  ANTHROPIC_API_KEY=sk-ant-... ALLM_PROVIDER=anthropic mix run examples/03_single_tool_call.exs

Application.ensure_all_started(:allm)
Code.require_file("_helpers.exs", __DIR__)

weather =
  ALLM.tool(
    name: "get_weather",
    description: "Return a weather forecast for a city.",
    schema: %{
      "type" => "object",
      "properties" => %{"city" => %{"type" => "string"}},
      "required" => ["city"],
      "additionalProperties" => false
    },
    handler: fn %{"city" => city} -> {:ok, %{forecast: "sunny", city: city}} end
  )

engine = ExamplesHelpers.engine(tools: [weather])

messages = [
  ALLM.system(
    "Call get_weather for the requested city. After the tool returns, repeat its forecast verbatim."
  ),
  ALLM.user("What's the weather in Boston?")
]

{:ok, result} = ALLM.chat(engine, messages, tool_choice: :auto)

tool_messages = Enum.filter(result.thread.messages, &(&1.role == :tool))
final_text = result.final_response.output_text || ""

ok? =
  result.halted_reason == :completed and
    length(result.steps) == 2 and
    tool_messages != [] and
    String.contains?(String.downcase(final_text), "sunny")

unless ok? do
  IO.puts(
    :stderr,
    "FAIL: single_tool_call — halted=#{inspect(result.halted_reason)} steps=#{length(result.steps)} tool_msgs=#{length(tool_messages)} text=#{inspect(final_text)}"
  )

  System.halt(1)
end

IO.puts(
  "OK: single_tool_call — steps=#{length(result.steps)} tool_msgs=#{length(tool_messages)} final=#{inspect(final_text)}"
)
