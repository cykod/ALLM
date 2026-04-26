# examples/openai/03_single_tool_call.exs
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
# Run with:    OPENAI_API_KEY=sk-... mix run examples/openai/03_single_tool_call.exs
#
# Note: Bug #5 (the Responses-API tool-call decoder gap) was fixed in this
# revision, so this example now runs natively on the Responses endpoint
# that `gpt-5.4-nano` selects by default. `:reasoning_effort: :low` gives
# slightly better steering for tool selection than `:none` at marginal
# extra cost.

# Auto-load OPENAI_API_KEY from project-root .env if not already in env.
if System.get_env("OPENAI_API_KEY") in [nil, ""], do: EnvLoader.load(Path.expand(".env", Path.join(__DIR__, "../..")))

Application.ensure_all_started(:allm)

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

engine =
  ALLM.Engine.new(
    adapter: ALLM.Providers.OpenAI,
    model: System.get_env("ALLM_MODEL", "gpt-5.4-nano"),
    params: %{reasoning_effort: :low},
    tool_executor: ALLM.ToolExecutor.Default,
    tool_result_encoder: ALLM.ToolResultEncoder.JSON,
    tools: [weather]
  )

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
    String.contains?(final_text, "sunny")

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
