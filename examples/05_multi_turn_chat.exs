# examples/05_multi_turn_chat.exs
#
# Demonstrates: a two-turn dialogue using `ALLM.chat/3` twice with the
#               accumulated thread carried across calls.
# Spec section: §4 (chat/3), §10.5.
# Steering strategy: loose — natural multi-turn dialogue. Assertion is
#                    shape-only: thread grows turn-over-turn and the second
#                    call halts with `:completed`.
# Natural alternative: this IS the natural form.
# Run with:    OPENAI_API_KEY=sk-... mix run examples/05_multi_turn_chat.exs                                # default
#         OR:  ANTHROPIC_API_KEY=sk-ant-... ALLM_PROVIDER=anthropic mix run examples/05_multi_turn_chat.exs

Application.ensure_all_started(:allm)
Code.require_file("_helpers.exs", __DIR__)

engine = ExamplesHelpers.engine()

{:ok, result1} =
  ALLM.chat(engine, [ALLM.user("Pick a number between 1 and 9. Reply with just the digit.")])

# Carry the accumulated thread into the next turn and append a follow-up.
followup_thread =
  ALLM.Thread.add_message(result1.thread, %ALLM.Message{
    role: :user,
    content: "Now multiply that number by 2 and reply with only the result."
  })

{:ok, result2} = ALLM.chat(engine, followup_thread)

ok? =
  length(result1.thread.messages) >= 2 and
    length(result2.thread.messages) > length(result1.thread.messages) and
    result2.halted_reason == :completed

unless ok? do
  IO.puts(
    :stderr,
    "FAIL: multi_turn_chat — t1_msgs=#{length(result1.thread.messages)} t2_msgs=#{length(result2.thread.messages)} halted=#{inspect(result2.halted_reason)}"
  )

  System.halt(1)
end

IO.puts(
  "OK: multi_turn_chat — t1_msgs=#{length(result1.thread.messages)} t2_msgs=#{length(result2.thread.messages)} t2_text=#{inspect(result2.final_response.output_text)}"
)
