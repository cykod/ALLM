# examples/09_ask_user.exs
#
# Demonstrates: a tool handler returning `{:ask_user, question, opts}` halts
#               the chat with `halted_reason: :ask_user`; a follow-up turn
#               supplies the user's answer and the loop completes.
# Spec section: §6 (tool handler returns), §10.5 (chat halt reasons),
#               §12.3 (ask-user suspension).
# Steering strategy: loose — first-turn assertion is exact (handler-controlled);
#                    second-turn assertion is shape-only (`:completed`) since
#                    the model's final phrasing is variable.
# Natural alternative: this IS the natural form.
# Run with:    OPENAI_API_KEY=sk-... mix run examples/09_ask_user.exs                                # default
#         OR:  ANTHROPIC_API_KEY=sk-ant-... ALLM_PROVIDER=anthropic mix run examples/09_ask_user.exs

Application.ensure_all_started(:allm)
Code.require_file("_helpers.exs", __DIR__)

weather =
  ALLM.tool(
    name: "get_weather",
    description: "Return weather for a city. If no city is supplied, asks the user.",
    schema: %{
      "type" => "object",
      "properties" => %{"city" => %{"type" => "string"}},
      "additionalProperties" => false
    },
    handler: fn args ->
      case Map.get(args, "city") do
        nil -> {:ask_user, "Which city?", []}
        "" -> {:ask_user, "Which city?", []}
        c -> {:ok, %{forecast: "sunny", city: c}}
      end
    end
  )

engine = ExamplesHelpers.engine(tools: [weather])

messages = [
  ALLM.system(
    "When asked about the weather without a city named, call get_weather with " <>
      "NO arguments (empty object {}); do NOT invent a city. Once the user " <>
      "supplies a city name, call get_weather with that city. After the tool " <>
      "returns a forecast, repeat the forecast verbatim."
  ),
  ALLM.user("What's the weather?")
]

{:ok, result1} = ALLM.chat(engine, messages, tool_choice: :auto)

ok1? =
  result1.halted_reason == :ask_user and result1.pending_question == "Which city?"

unless ok1? do
  IO.puts(
    :stderr,
    "FAIL: ask_user pass-1 — halted=#{inspect(result1.halted_reason)} q=#{inspect(result1.pending_question)}"
  )

  System.halt(1)
end

# Append the user's answer and re-issue chat. The thread already carries the
# assistant's question (Phase 7 places it on the result.thread).
followup =
  ALLM.Thread.add_message(
    result1.thread,
    %ALLM.Message{role: :user, content: "Boston"}
  )

{:ok, result2} = ALLM.chat(engine, followup, tool_choice: :auto)

ok2? = result2.halted_reason == :completed

unless ok2? do
  IO.puts(
    :stderr,
    "FAIL: ask_user pass-2 — halted=#{inspect(result2.halted_reason)} text=#{inspect(result2.final_response.output_text)}"
  )

  System.halt(1)
end

IO.puts(
  "OK: ask_user — pass1=:ask_user (\"Which city?\") pass2=:completed final=#{inspect(result2.final_response.output_text)}"
)
