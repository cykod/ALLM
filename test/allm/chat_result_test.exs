defmodule ALLM.ChatResultTest do
  use ExUnit.Case, async: true

  alias ALLM.{ChatResult, Response, Thread}

  doctest ChatResult

  describe "new/1" do
    test "builds a ChatResult with defaults" do
      thread = %Thread{}
      response = %Response{}

      cr = ChatResult.new(thread: thread, final_response: response, halted_reason: :completed)

      assert %ChatResult{
               thread: ^thread,
               final_response: ^response,
               steps: [],
               halted_reason: :completed,
               metadata: %{}
             } = cr
    end

    test "accepts steps, pending_question, pending_tool_call_id, metadata" do
      cr =
        ChatResult.new(
          thread: %Thread{},
          final_response: %Response{},
          halted_reason: :ask_user,
          steps: [],
          pending_question: "Confirm?",
          pending_tool_call_id: "call_1",
          metadata: %{source: :fake}
        )

      assert cr.pending_question == "Confirm?"
      assert cr.pending_tool_call_id == "call_1"
      assert cr.metadata == %{source: :fake}
    end
  end

  describe "halted?/1" do
    test "returns false when halted_reason is :completed" do
      cr = ChatResult.new(halted_reason: :completed)
      refute ChatResult.halted?(cr)
    end

    test "returns true for :max_turns" do
      cr = ChatResult.new(halted_reason: :max_turns)
      assert ChatResult.halted?(cr)
    end

    test "returns true for :halt_when, :ask_user, :tool_error, :cancelled" do
      for r <- [:halt_when, :ask_user, :tool_error, :cancelled] do
        assert ChatResult.halted?(ChatResult.new(halted_reason: r)),
               "expected halted? to return true for #{inspect(r)}"
      end
    end

    test "returns true for a custom atom reason (atom escape hatch)" do
      assert ChatResult.halted?(ChatResult.new(halted_reason: :custom_halt))
    end
  end

  describe "term_to_binary/binary_to_term round-trip" do
    @tag :roundtrip
    test "a fully populated ChatResult round-trips to equal value" do
      cr =
        ChatResult.new(
          thread: %Thread{},
          final_response: %Response{output_text: "done"},
          halted_reason: :completed,
          metadata: %{}
        )

      assert cr == cr |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end
  end

  # NOTE: ALLM.Serializer JSON round-trip is deferred to sub-phase 1.5.
end
