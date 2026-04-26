# examples/openai/07_manual_tool_round_trip.exs
#
# Demonstrates: `mode: :manual` chat where the loop halts on the first
#               tool-calls turn. Caller submits the tool result manually
#               and re-issues `chat/3` to drive the second turn.
# Spec section: §4 (chat/3), §10.5 (manual mode), §6 (tools).
# Steering strategy: tight — `tool_choice: :auto` with a system prompt that
#                    forces the model to call the tool; the assertion
#                    inspects the manual-halt shape, then the post-result
#                    `:completed` halt.
# Natural alternative (commented out below):
#   ALLM.user("What's the weather in Boston?") with mode: :manual
# Run with:    OPENAI_API_KEY=sk-... mix run examples/openai/07_manual_tool_round_trip.exs
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
    description: "Return weather for a city.",
    schema: %{
      "type" => "object",
      "properties" => %{"city" => %{"type" => "string"}},
      "required" => ["city"],
      "additionalProperties" => false
    },
    handler: fn %{"city" => c} -> {:ok, %{forecast: "sunny", city: c}} end
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

{:ok, result1} = ALLM.chat(engine, messages, mode: :manual, tool_choice: :auto)

pending = result1.final_response.tool_calls

ok1? =
  result1.halted_reason == :manual_tool_calls and length(pending) == 1

unless ok1? do
  IO.puts(
    :stderr,
    "FAIL: manual_tool_round_trip pass-1 — halted=#{inspect(result1.halted_reason)} pending=#{length(pending)}"
  )

  System.halt(1)
end

# Caller computes the tool result outside the loop and threads it back.
[%ALLM.ToolCall{id: tool_call_id, arguments: args}] = pending

city = args["city"] || "Boston"
manual_result = %{forecast: "sunny", city: city}

augmented_thread =
  ALLM.Thread.add_message(
    result1.thread,
    %ALLM.Message{
      role: :tool,
      tool_call_id: tool_call_id,
      content: Jason.encode!(manual_result)
    }
  )

{:ok, result2} = ALLM.chat(engine, augmented_thread, mode: :manual)

final_text = result2.final_response.output_text || ""

ok2? =
  result2.halted_reason == :completed and String.contains?(final_text, "sunny")

unless ok2? do
  IO.puts(
    :stderr,
    "FAIL: manual_tool_round_trip pass-2 — halted=#{inspect(result2.halted_reason)} text=#{inspect(final_text)}"
  )

  System.halt(1)
end

IO.puts(
  "OK: manual_tool_round_trip — pass1=:manual_tool_calls pending=1 pass2=#{result2.halted_reason} final=#{inspect(final_text)}"
)
