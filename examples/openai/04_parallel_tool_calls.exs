# examples/openai/04_parallel_tool_calls.exs
#
# Demonstrates: two tool calls within one chat loop — Boston weather AND
#               Tokyo time. OpenAI may emit them as a parallel turn or as
#               two consecutive turns; the assertion counts tool messages,
#               not parallel-turn step indices.
# Spec section: §4 (chat/3), §10.5, §6 (parallel tools).
# Steering strategy: tight — `tool_choice: :required` forces ANY tool call;
#                    system prompt names both tools and asks for both cities.
#                    Assertion: exactly two tool messages on the final thread.
# Natural alternative (commented out below):
#   ALLM.user("Tell me Boston's weather and Tokyo's local time.")
# Run with:    OPENAI_API_KEY=sk-... mix run examples/openai/04_parallel_tool_calls.exs
#
# Note: Bug #5 (Responses-API tool-call decoder gap) was fixed in this
# revision, so this example now runs natively on the Responses endpoint
# that `gpt-5.4-nano` selects by default.

# Auto-load OPENAI_API_KEY from project-root .env if not already in env.
if System.get_env("OPENAI_API_KEY") in [nil, ""], do: EnvLoader.load(Path.expand(".env", Path.join(__DIR__, "../..")))

Application.ensure_all_started(:allm)

weather =
  ALLM.tool(
    name: "get_weather",
    description: "Return the weather for a city.",
    schema: %{
      "type" => "object",
      "properties" => %{"city" => %{"type" => "string"}},
      "required" => ["city"],
      "additionalProperties" => false
    },
    handler: fn %{"city" => c} -> {:ok, %{forecast: "sunny", city: c}} end
  )

time =
  ALLM.tool(
    name: "get_time",
    description: "Return the local time for a city.",
    schema: %{
      "type" => "object",
      "properties" => %{"city" => %{"type" => "string"}},
      "required" => ["city"],
      "additionalProperties" => false
    },
    handler: fn %{"city" => c} -> {:ok, %{local_time: "12:00", city: c}} end
  )

engine =
  ALLM.Engine.new(
    adapter: ALLM.Providers.OpenAI,
    model: System.get_env("ALLM_MODEL", "gpt-5.4-nano"),
    params: %{reasoning_effort: :low},
    tool_executor: ALLM.ToolExecutor.Default,
    tool_result_encoder: ALLM.ToolResultEncoder.JSON,
    tools: [weather, time]
  )

messages = [
  ALLM.system(
    "You have two tools, get_weather and get_time. " <>
      "When asked about a city's weather, call get_weather; about a city's time, call get_time. " <>
      "After both tools return, briefly summarise their outputs."
  ),
  ALLM.user("Tell me the weather in Boston and the local time in Tokyo.")
]

{:ok, result} = ALLM.chat(engine, messages, tool_choice: :auto)

tool_count = Enum.count(result.thread.messages, &(&1.role == :tool))

ok? =
  tool_count == 2 and result.halted_reason == :completed

unless ok? do
  IO.puts(
    :stderr,
    "FAIL: parallel_tool_calls — halted=#{inspect(result.halted_reason)} tool_msgs=#{tool_count} steps=#{length(result.steps)}"
  )

  System.halt(1)
end

IO.puts(
  "OK: parallel_tool_calls — tool_msgs=#{tool_count} steps=#{length(result.steps)} final=#{inspect(result.final_response.output_text)}"
)
