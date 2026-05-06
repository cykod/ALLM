# examples/15_per_tool_manual_session.exs
#
# Provider: openai, anthropic
# Demonstrates: per-tool manual mode via the Session API (Phase 18 / spec
#               §12.4). Auto-bucket tools execute eagerly during `Session.start/3`;
#               the session lands in `:awaiting_tools` with `pending_tool_calls`
#               carrying ONLY the manual subset. `submit_tool_result/3` clears
#               the pending call, the session returns to `:idle`, and
#               `continue/3` drives the next turn to `:completed`.
# Spec section: §5.2 (`%ALLM.Tool{manual: true}`), §11 (Session API),
#               §12.4 (per-tool manual partition), §10.5 (`:manual_tool_calls`
#               halt-reason).
# Steering strategy: tight — system prompt forces both tool calls in turn 1;
#                    assertions check (a) `:awaiting_tools` after `start/3`,
#                    (b) `pending_tool_calls` length 1 with the manual name,
#                    (c) `:idle` after `submit_tool_result/3`,
#                    (d) `:completed` with "sunny" in final text after
#                    `continue/3`.
# Run with:    OPENAI_API_KEY=sk-...     mix run examples/15_per_tool_manual_session.exs                                # default
#         OR:  ANTHROPIC_API_KEY=sk-ant-... ALLM_PROVIDER=anthropic mix run examples/15_per_tool_manual_session.exs

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

{:ok, session1, _result1} = ALLM.Session.start(engine, messages, tool_choice: :auto)

ok1? =
  session1.status == :awaiting_tools and
    length(session1.pending_tool_calls) == 1 and
    hd(session1.pending_tool_calls).name == "confirm_action"

unless ok1? do
  IO.puts(
    :stderr,
    "FAIL: session per-tool manual start — status=#{inspect(session1.status)} " <>
      "pending=#{inspect(session1.pending_tool_calls)}"
  )

  System.halt(1)
end

# Caller approves out-of-band and submits the manual tool result. The
# session API enforces the id contract: an unknown id would return
# `{:error, %SessionError{reason: :unknown_tool_call_id}}`.
[%ALLM.ToolCall{id: confirm_id, arguments: confirm_args}] = session1.pending_tool_calls
manual_result = %{status: "approved", action: confirm_args["action"]}

session2 = ALLM.Session.submit_tool_result(session1, confirm_id, manual_result)

unless session2.status == :idle do
  IO.puts(
    :stderr,
    "FAIL: session post-submit — expected :idle, got status=#{inspect(session2.status)} " <>
      "pending=#{inspect(session2.pending_tool_calls)}"
  )

  System.halt(1)
end

# Drive the next turn. `continue/3` with `nil` re-issues the loop on the
# session's existing thread (now containing the assistant tool_calls
# message + both `:tool` result messages).
{:ok, session3, result3} = ALLM.Session.continue(engine, session2, nil)

final_text = result3.final_response.output_text || ""

ok3? =
  session3.status == :completed and
    result3.halted_reason == :completed and
    String.contains?(final_text, "sunny")

unless ok3? do
  IO.puts(
    :stderr,
    "FAIL: session per-tool manual continue — session.status=#{inspect(session3.status)} " <>
      "result.halted_reason=#{inspect(result3.halted_reason)} " <>
      "text=#{inspect(final_text)}"
  )

  System.halt(1)
end

IO.puts(
  "OK: per_tool_manual_session — start=:awaiting_tools pending=1 " <>
    "submit=:idle continue=:completed final=#{inspect(final_text)}"
)
