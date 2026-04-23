defmodule ALLM.StepResultTest do
  use ExUnit.Case, async: true

  alias ALLM.{Message, Response, StepResult, Thread}

  doctest StepResult

  describe "new/1" do
    test "builds a StepResult with defaults" do
      thread = %Thread{messages: [%Message{role: :user, content: "hi"}]}
      response = %Response{}
      sr = StepResult.new(thread: thread, response: response)

      assert %StepResult{
               thread: ^thread,
               response: ^response,
               tool_results: [],
               done?: false,
               metadata: %{}
             } = sr
    end

    test "accepts tool_results, done?, metadata" do
      thread = %Thread{}
      response = %Response{}
      tool_msg = %Message{role: :tool, tool_call_id: "c1", content: "ok"}

      sr =
        StepResult.new(
          thread: thread,
          response: response,
          tool_results: [tool_msg],
          done?: true,
          metadata: %{turn: 1}
        )

      assert sr.tool_results == [tool_msg]
      assert sr.done? == true
      assert sr.metadata == %{turn: 1}
    end
  end

  describe "term_to_binary/binary_to_term round-trip" do
    @tag :roundtrip
    test "a populated StepResult round-trips, preserving the :done? atom key" do
      sr =
        StepResult.new(
          thread: %Thread{messages: [%Message{role: :user, content: "hi"}]},
          response: %Response{output_text: "ok"},
          done?: true,
          metadata: %{turn: 1}
        )

      assert sr == sr |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end
  end

  # NOTE: ALLM.Serializer JSON round-trip is deferred to sub-phase 1.5.
end
