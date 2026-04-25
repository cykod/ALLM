defmodule ALLM.SessionStatusTransitionTest do
  @moduledoc """
  Phase 8 sub-phase 8.4 — exhaustive status-transition matrix test.

  One test per cell of the matrix from `PHASE_8_DESIGN.md` §Overview:

  | From \\ Op       | start/3 | reply/4 | continue/3 | step/3 | submit_tool_result/3 |
  |-----------------|---------|---------|------------|--------|----------------------|
  | (fresh-input)   | legal   | n/a     | n/a        | n/a    | n/a                  |
  | :idle           | n/a     | legal   | legal      | legal  | raises ArgumentError |
  | :awaiting_user  | n/a     | legal   | raises     | raises | raises               |
  | :awaiting_tools | n/a     | raises  | gated      | raises | legal                |
  | :completed      | n/a     | legal   | legal      | legal  | raises               |
  | :error          | n/a     | SE      | SE         | SE     | SE                   |

  (SE = `{:error, %SessionError{reason: :session_in_error_state}}`.)

  Plus the data-mismatch case: `submit_tool_result/3` on `:awaiting_tools`
  with an unknown id returns `{:error, %SessionError{reason:
  :unknown_tool_call_id}}`.

  Per Decision #7's status-vs-data rule: status mismatches RAISE; data
  mismatches return error tuples.
  """

  use ExUnit.Case, async: true

  alias ALLM.{ChatResult, Session, StepResult, Thread, ToolCall}
  alias ALLM.Error.SessionError
  alias ALLM.Test.FakeFixtures

  # ---------------------------------------------------------------------------
  # Helpers — engine builders + session seeders
  # ---------------------------------------------------------------------------

  defp engine_text!(text \\ "ok"),
    do: FakeFixtures.engine([{:text, text}, {:finish, :stop}])

  defp idle_session do
    Session.new(thread: Thread.from_messages([ALLM.user("hi")]))
  end

  defp completed_session do
    %{idle_session() | status: :completed}
  end

  defp awaiting_user_session do
    %{
      idle_session()
      | status: :awaiting_user,
        pending_question: "Are you sure?",
        pending_tool_call_id: "call_x"
    }
  end

  defp awaiting_tools_session do
    %{
      idle_session()
      | status: :awaiting_tools,
        pending_tool_calls: [%ToolCall{id: "c0", name: "echo", arguments: %{}}]
    }
  end

  defp error_session do
    %{idle_session() | status: :error, metadata: %{error: :boom}}
  end

  # ---------------------------------------------------------------------------
  # start/3 — only the fresh-input cell is legal; the other cells in the
  # row don't exist (start/3 is constructed-at-entry; calling it with an
  # already-statused session is a coerce-through, not a transition).
  # ---------------------------------------------------------------------------

  describe "start/3" do
    test "fresh input → legal; post-status follows ChatResult" do
      engine = engine_text!("hello")

      assert {:ok, %Session{status: :completed}, %ChatResult{halted_reason: :completed}} =
               Session.start(engine, [ALLM.user("hi")])
    end

    test "pre-statused %Session{} input → start/3 still legal (passes through coerce_session_input)" do
      engine = engine_text!()
      seed = %{idle_session() | id: "s1"}

      assert {:ok, %Session{id: "s1", status: :completed}, %ChatResult{}} =
               Session.start(engine, seed)
    end
  end

  # ---------------------------------------------------------------------------
  # reply/4 — 5 cells.
  # ---------------------------------------------------------------------------

  describe "reply/4" do
    test ":idle → legal; post-status :completed" do
      engine = engine_text!()

      assert {:ok, %Session{status: :completed}, %ChatResult{}} =
               Session.reply(engine, idle_session(), "hi")
    end

    test ":awaiting_user → legal; pending fields cleared" do
      engine = engine_text!()

      assert {:ok, %Session{status: :completed} = s, %ChatResult{}} =
               Session.reply(engine, awaiting_user_session(), "yes")

      assert s.pending_question == nil
      assert s.pending_tool_call_id == nil
    end

    test ":awaiting_tools → raises ArgumentError" do
      engine = engine_text!()

      assert_raise ArgumentError, ~r/awaiting_tools/, fn ->
        Session.reply(engine, awaiting_tools_session(), "hi")
      end
    end

    test ":completed → legal (treated as :idle)" do
      engine = engine_text!()

      assert {:ok, %Session{status: :completed}, %ChatResult{}} =
               Session.reply(engine, completed_session(), "more")
    end

    test ":error → {:error, %SessionError{reason: :session_in_error_state}}" do
      engine = engine_text!()

      assert {:error, %SessionError{reason: :session_in_error_state}} =
               Session.reply(engine, error_session(), "hi")
    end
  end

  # ---------------------------------------------------------------------------
  # continue/3 — 5 cells.
  # ---------------------------------------------------------------------------

  describe "continue/3" do
    test ":idle + %Message{} → legal" do
      engine = engine_text!()

      assert {:ok, %Session{status: :completed}, %ChatResult{}} =
               Session.continue(engine, idle_session(), ALLM.user("hi"))
    end

    test ":idle + nil message → legal (drives engine on session.thread as-is)" do
      engine = engine_text!()

      assert {:ok, %Session{status: :completed}, %ChatResult{}} =
               Session.continue(engine, idle_session(), nil)
    end

    test ":awaiting_user + non-user-message → raises ArgumentError" do
      engine = engine_text!()

      assert_raise ArgumentError, ~r/awaiting_user/, fn ->
        Session.continue(engine, awaiting_user_session(), nil)
      end
    end

    test ":awaiting_tools + nil + non-empty pending → raises ArgumentError" do
      engine = engine_text!()

      assert_raise ArgumentError, ~r/awaiting_tools/, fn ->
        Session.continue(engine, awaiting_tools_session(), nil)
      end
    end

    test ":awaiting_tools + nil + empty pending → legal (post-submit resumption)" do
      # Caller submitted all results; status is now :awaiting_tools with []
      # pending — but in practice submit_tool_result/3 flips status to
      # :idle when the last result is submitted. We simulate the design's
      # `legal IFF nil AND pending == []` clause directly.
      engine = engine_text!()

      session = %{idle_session() | status: :awaiting_tools, pending_tool_calls: []}

      assert {:ok, %Session{status: :completed}, %ChatResult{}} =
               Session.continue(engine, session, nil)
    end

    test ":completed → legal (treated as :idle)" do
      engine = engine_text!()

      assert {:ok, %Session{status: :completed}, %ChatResult{}} =
               Session.continue(engine, completed_session(), ALLM.user("more"))
    end

    test ":error → {:error, %SessionError{}}" do
      engine = engine_text!()

      assert {:error, %SessionError{reason: :session_in_error_state}} =
               Session.continue(engine, error_session(), nil)
    end
  end

  # ---------------------------------------------------------------------------
  # step/3 — 5 cells.
  # ---------------------------------------------------------------------------

  describe "step/3" do
    test ":idle → legal; one adapter turn" do
      engine = engine_text!()

      assert {:ok, %Session{status: :completed}, %StepResult{done?: true}} =
               Session.step(engine, idle_session())
    end

    test ":awaiting_user → raises ArgumentError" do
      engine = engine_text!()

      assert_raise ArgumentError, ~r/step/, fn ->
        Session.step(engine, awaiting_user_session())
      end
    end

    test ":awaiting_tools → raises ArgumentError" do
      engine = engine_text!()

      assert_raise ArgumentError, ~r/step/, fn ->
        Session.step(engine, awaiting_tools_session())
      end
    end

    test ":completed → legal (treated as :idle)" do
      engine = engine_text!()

      assert {:ok, %Session{status: :completed}, %StepResult{}} =
               Session.step(engine, completed_session())
    end

    test ":error → {:error, %SessionError{}}" do
      engine = engine_text!()

      assert {:error, %SessionError{reason: :session_in_error_state}} =
               Session.step(engine, error_session())
    end
  end

  # ---------------------------------------------------------------------------
  # submit_tool_result/3 — 5 cells. Plus the data-mismatch row.
  # ---------------------------------------------------------------------------

  describe "submit_tool_result/3" do
    test ":idle → raises ArgumentError" do
      assert_raise ArgumentError, ~r/submit_tool_result/, fn ->
        Session.submit_tool_result(idle_session(), "c0", "result")
      end
    end

    test ":awaiting_user → raises ArgumentError" do
      assert_raise ArgumentError, ~r/submit_tool_result/, fn ->
        Session.submit_tool_result(awaiting_user_session(), "c0", "result")
      end
    end

    test ":awaiting_tools → legal; status flips to :idle when last submitted" do
      assert %Session{status: :idle, pending_tool_calls: []} =
               Session.submit_tool_result(awaiting_tools_session(), "c0", "result")
    end

    test ":completed → raises ArgumentError" do
      assert_raise ArgumentError, ~r/submit_tool_result/, fn ->
        Session.submit_tool_result(completed_session(), "c0", "result")
      end
    end

    test ":error → {:error, %SessionError{reason: :session_in_error_state}}" do
      assert {:error, %SessionError{reason: :session_in_error_state}} =
               Session.submit_tool_result(error_session(), "c0", "result")
    end

    test ":awaiting_tools + unknown id → {:error, %SessionError{reason: :unknown_tool_call_id}}" do
      # Data-mismatch case (Decision #7): does NOT raise.
      assert {:error, %SessionError{reason: :unknown_tool_call_id, metadata: meta}} =
               Session.submit_tool_result(awaiting_tools_session(), "bogus_id", "result")

      assert meta.tool_call_id == "bogus_id"
    end
  end
end
