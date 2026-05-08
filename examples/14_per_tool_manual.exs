# examples/14_per_tool_manual.exs
#
# Provider: openai, anthropic, gemini
# Demonstrates: per-tool manual mode (Phase 18 / spec §12.4). One tool
#               (`get_weather`) auto-executes; another (`confirm_action`,
#               `manual: true`) halts the loop with `:manual_tool_calls`.
#               The caller appends a `:tool` message for the manual id and
#               re-issues `chat/3` to drive the second turn.
# Spec section: §5.2 (`%ALLM.Tool{manual: true}`), §10.5 (`:manual_tool_calls`
#               halt-reason), §12.4 (per-tool manual partition).
# Steering strategy: tight — system prompt forces both tool calls; assertion
#                    checks the per-tool halt shape, then the post-tool-result
#                    `:completed` halt with "sunny" in the assistant text.
# Natural alternative (commented out below):
#   ALLM.user("Check weather in Boston, then ask me before deleting anything.")
# Run with:    OPENAI_API_KEY=sk-...     mix run examples/14_per_tool_manual.exs                                # default
#         OR:  ANTHROPIC_API_KEY=sk-ant-... ALLM_PROVIDER=anthropic mix run examples/14_per_tool_manual.exs

Application.ensure_all_started(:allm)
Code.require_file("_helpers.exs", __DIR__)

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

confirm =
  ALLM.tool(
    name: "confirm_action",
    description: "Ask the user to confirm a destructive action before performing it.",
    schema: %{
      "type" => "object",
      "properties" => %{"action" => %{"type" => "string"}},
      "required" => ["action"],
      "additionalProperties" => false
    },
    manual: true
  )

engine = ExamplesHelpers.engine(tools: [weather, confirm])

messages = [
  ALLM.system(
    "First call get_weather for Boston. Then call confirm_action with action='delete' " <>
      "to ask the user before deleting. Make BOTH tool calls in your first response. " <>
      "After tool results return, repeat the weather forecast verbatim."
  ),
  ALLM.user("Check weather in Boston, then ask before deleting.")
]

{:ok, result1} = ALLM.chat(engine, messages, tool_choice: :auto)

manual_pending = result1.metadata[:manual_tool_calls] || []

ok1? =
  result1.halted_reason == :manual_tool_calls and
    length(manual_pending) == 1 and
    hd(manual_pending).name == "confirm_action"

unless ok1? do
  IO.puts(
    :stderr,
    "FAIL: per_tool_manual pass-1 — halted=#{inspect(result1.halted_reason)} " <>
      "manual_pending=#{inspect(manual_pending)}"
  )

  System.halt(1)
end

# Caller approves out-of-band and threads the manual tool result back.
[%ALLM.ToolCall{id: confirm_id, arguments: confirm_args}] = manual_pending

manual_result = %{status: "approved", action: confirm_args["action"]}

augmented_thread =
  ALLM.Thread.add_message(
    result1.thread,
    %ALLM.Message{
      role: :tool,
      tool_call_id: confirm_id,
      content: Jason.encode!(manual_result)
    }
  )

{:ok, result2} = ALLM.chat(engine, augmented_thread)

final_text = result2.final_response.output_text || ""

ok2? =
  result2.halted_reason == :completed and String.contains?(final_text, "sunny")

unless ok2? do
  IO.puts(
    :stderr,
    "FAIL: per_tool_manual pass-2 — halted=#{inspect(result2.halted_reason)} " <>
      "text=#{inspect(final_text)}"
  )

  System.halt(1)
end

IO.puts(
  "OK: per_tool_manual — pass1=:manual_tool_calls manual_pending=1 " <>
    "pass2=#{result2.halted_reason} final=#{inspect(final_text)}"
)
