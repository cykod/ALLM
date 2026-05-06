defmodule ALLM.SessionPerToolManualTest do
  @moduledoc """
  Phase 18.4 — `ALLM.Session` projection coverage for per-tool manual mode.

  Verifies that:

    * `Session.start/3` under `mode: :auto` partitions tool calls and halts
      at `:awaiting_tools` when any called tool has `manual: true`, with
      `pending_tool_calls` containing only the manual subset.
    * `Session.start/3` under `mode: :manual` keeps whole-loop semantics —
      per-tool flags are silent, `pending_tool_calls` is the full
      `response.tool_calls` list (Decision #5 / #13).
    * `submit_tool_result/3` flips an `:awaiting_tools` session back to
      `:idle` once the manual subset is resolved; an AUTO-bucket id
      returns `{:error, %SessionError{reason: :unknown_tool_call_id}}`
      because that id already ran (its message lives in `session.thread`,
      not `pending_tool_calls`). Closes the AGENT_DESIGN_SPEC item 12
      dispatch-graph reconciliation gap.
    * `Session.stream_start/3` produces the same projection through
      `StreamReducer.finalize/1`; no `:tool_execution_*` events fire when
      the manual bucket is non-empty and pure.
    * Empty-list-write defensive: a whole-loop turn whose metadata
      synthesizes `manual_tool_calls: []` (e.g., a defensively-merged
      reducer fold) MUST fall through to `final_response.tool_calls`
      rather than masking with `[]` — guards Decision #8's `tcs != []`
      load-bearing guard.
  """

  use ExUnit.Case, async: true

  alias ALLM.{ChatResult, Session, StepResult, Thread, Tool, ToolCall}
  alias ALLM.Error.SessionError
  alias ALLM.Session.StreamReducer
  alias ALLM.Test.FakeFixtures

  # ---------------------------------------------------------------------------
  # Tool fixtures
  # ---------------------------------------------------------------------------

  defp weather_tool do
    Tool.new(
      name: "weather",
      description: "",
      schema: %{},
      handler: fn _args -> {:ok, %{forecast: "sunny"}} end
    )
  end

  defp manual_charge_tool do
    Tool.new(
      name: "charge",
      description: "",
      schema: %{},
      handler: fn _args -> {:ok, "should not run"} end,
      manual: true
    )
  end

  defp user_thread, do: Thread.from_messages([ALLM.user("hi")])

  defp count_tag(events, tag), do: Enum.count(events, &match?({^tag, _}, &1))

  # ---------------------------------------------------------------------------
  # Cell 1 — Session.start/3 with mode: :auto + pure manual call
  # ---------------------------------------------------------------------------

  describe "Session.start/3 :auto pure manual" do
    test "halts at :awaiting_tools; pending_tool_calls comes from metadata bucket" do
      engine =
        FakeFixtures.engine(
          [
            {:tool_call, id: "cm", name: "charge", arguments: %{"amount" => 20}},
            {:finish, :tool_calls}
          ],
          tools: [manual_charge_tool()]
        )

      assert {:ok, %Session{} = session, %ChatResult{halted_reason: :manual_tool_calls} = cr} =
               Session.start(engine, [ALLM.user("charge $20")])

      assert session.status == :awaiting_tools
      assert [%ToolCall{id: "cm", name: "charge"}] = session.pending_tool_calls
      assert [%ToolCall{id: "cm"}] = cr.metadata.manual_tool_calls
      # ETF round-trip survives.
      assert session == session |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end
  end

  # ---------------------------------------------------------------------------
  # Cell 2 — Session.start/3 with mode: :auto + only auto calls completes
  # ---------------------------------------------------------------------------

  describe "Session.start/3 :auto only auto calls" do
    test "completes normally with status :completed" do
      scripts = [
        [
          {:tool_call, id: "ca", name: "weather", arguments: %{"city" => "Boston"}},
          {:finish, :tool_calls}
        ],
        [{:text, "It is sunny."}, {:finish, :stop}]
      ]

      engine = FakeFixtures.engine_with_scripts(scripts, tools: [weather_tool()])

      assert {:ok, %Session{} = session, %ChatResult{halted_reason: :completed}} =
               Session.start(engine, [ALLM.user("weather Boston")])

      assert session.status == :completed
      assert session.pending_tool_calls == []
    end
  end

  # ---------------------------------------------------------------------------
  # Cell 3 — Session.start/3 with mode: :manual + per-tool flags;
  # whole-loop wins (Decision #5)
  # ---------------------------------------------------------------------------

  describe "Session.start/3 :manual + per-tool flags (whole-loop wins)" do
    test "pending_tool_calls is the FULL response.tool_calls (manual + auto)" do
      engine =
        FakeFixtures.engine(
          [
            {:tool_call, id: "ca", name: "weather", arguments: %{"city" => "Boston"}},
            {:tool_call, id: "cm", name: "charge", arguments: %{"amount" => 20}},
            {:finish, :tool_calls}
          ],
          tools: [weather_tool(), manual_charge_tool()]
        )

      assert {:ok, %Session{} = session, %ChatResult{halted_reason: :manual_tool_calls} = cr} =
               Session.start(engine, [ALLM.user("hi")], mode: :manual)

      assert session.status == :awaiting_tools

      # Whole-loop surfaces ALL tool calls (not just the manual subset).
      ids = Enum.map(session.pending_tool_calls, & &1.id)
      assert ids == ["ca", "cm"]

      # The whole-loop path does NOT set metadata.manual_tool_calls (only
      # `metadata.manual_turn_index`); the helper falls through to
      # final_response.tool_calls per Decision #8.
      refute Map.has_key?(cr.metadata, :manual_tool_calls)
    end
  end

  # ---------------------------------------------------------------------------
  # Cell 4 — Session.start/3 with mode: :auto + mixed bucket
  # ---------------------------------------------------------------------------

  describe "Session.start/3 :auto mixed bucket" do
    test "pending_tool_calls is manual subset only; thread carries auto :tool message" do
      engine =
        FakeFixtures.engine(
          [
            {:tool_call, id: "ca", name: "weather", arguments: %{"city" => "Boston"}},
            {:tool_call, id: "cm", name: "charge", arguments: %{"amount" => 20}},
            {:finish, :tool_calls}
          ],
          tools: [weather_tool(), manual_charge_tool()]
        )

      assert {:ok, %Session{} = session, %ChatResult{halted_reason: :manual_tool_calls}} =
               Session.start(engine, [ALLM.user("hi")])

      assert session.status == :awaiting_tools
      # Only the manual id pends.
      assert [%ToolCall{id: "cm", name: "charge"}] = session.pending_tool_calls

      # Auto-bucket :tool message is already in the thread.
      tool_msgs = Enum.filter(session.thread.messages, &(&1.role == :tool))
      assert length(tool_msgs) == 1
      assert hd(tool_msgs).tool_call_id == "ca"
      refute Enum.any?(tool_msgs, &(&1.tool_call_id == "cm"))
    end
  end

  # ---------------------------------------------------------------------------
  # Cell 5 — submit_tool_result/3 against the manual subset
  # ---------------------------------------------------------------------------

  describe "submit_tool_result/3 + continue/3 mixed-bucket cycle" do
    test "manual id flips status to :idle; subsequent continue/3 drives next turn" do
      scripts = [
        [
          {:tool_call, id: "ca", name: "weather", arguments: %{"city" => "Boston"}},
          {:tool_call, id: "cm", name: "charge", arguments: %{"amount" => 20}},
          {:finish, :tool_calls}
        ],
        [{:text, "Charged."}, {:finish, :stop}]
      ]

      engine =
        FakeFixtures.engine_with_scripts(scripts, tools: [weather_tool(), manual_charge_tool()])

      assert {:ok, %Session{} = session, _} = Session.start(engine, [ALLM.user("hi")])
      assert session.status == :awaiting_tools

      session = Session.submit_tool_result(session, "cm", %{approved: true})
      assert session.status == :idle
      assert session.pending_tool_calls == []

      assert {:ok, %Session{status: :completed}, _} = Session.continue(engine, session, nil)
    end
  end

  # ---------------------------------------------------------------------------
  # Cell 6 — submit_tool_result/3 with an AUTO-bucket id (already ran)
  # ---------------------------------------------------------------------------

  describe "submit_tool_result/3 with AUTO-bucket id" do
    test "returns {:error, %SessionError{reason: :unknown_tool_call_id}}" do
      engine =
        FakeFixtures.engine(
          [
            {:tool_call, id: "ca", name: "weather", arguments: %{"city" => "Boston"}},
            {:tool_call, id: "cm", name: "charge", arguments: %{"amount" => 20}},
            {:finish, :tool_calls}
          ],
          tools: [weather_tool(), manual_charge_tool()]
        )

      assert {:ok, %Session{} = session, _} = Session.start(engine, [ALLM.user("hi")])
      assert session.status == :awaiting_tools

      # The auto bucket already ran; "ca" is in session.thread, NOT pending_tool_calls.
      assert {:error, %SessionError{reason: :unknown_tool_call_id, metadata: %{tool_call_id: "ca"}}} =
               Session.submit_tool_result(session, "ca", "result")
    end
  end

  # ---------------------------------------------------------------------------
  # Cell 7 — Session.stream_start/3 mixed bucket lifts pending_tool_calls
  # ---------------------------------------------------------------------------

  describe "Session.stream_start/3 mixed bucket" do
    test "terminal :chat_completed result.metadata.manual_tool_calls equals pending_tool_calls" do
      engine =
        FakeFixtures.engine(
          [
            {:tool_call, id: "ca", name: "weather", arguments: %{"city" => "Boston"}},
            {:tool_call, id: "cm", name: "charge", arguments: %{"amount" => 20}},
            {:finish, :tool_calls}
          ],
          tools: [weather_tool(), manual_charge_tool()]
        )

      session = Session.new(thread: user_thread())
      assert {:ok, stream} = Session.stream_start(engine, session)

      reducer = StreamReducer.new(session)

      reducer =
        Enum.reduce(stream, reducer, fn event, acc ->
          StreamReducer.apply_event(acc, event)
        end)

      {projected_session, %ChatResult{} = cr} = StreamReducer.finalize(reducer)

      assert projected_session.status == :awaiting_tools
      assert [%ToolCall{id: "cm"}] = projected_session.pending_tool_calls
      assert cr.metadata.manual_tool_calls == projected_session.pending_tool_calls
    end
  end

  # ---------------------------------------------------------------------------
  # Cell 8 — Session.stream_start/3 :auto pure manual: NO tool_execution_*
  # ---------------------------------------------------------------------------

  describe "Session.stream_start/3 :auto pure manual" do
    test "status :awaiting_tools; no :tool_execution_* events fired" do
      engine =
        FakeFixtures.engine(
          [
            {:tool_call, id: "cm", name: "charge", arguments: %{"amount" => 20}},
            {:finish, :tool_calls}
          ],
          tools: [manual_charge_tool()]
        )

      session = Session.new(thread: user_thread())
      assert {:ok, stream} = Session.stream_start(engine, session)
      events = Enum.to_list(stream)

      assert count_tag(events, :tool_execution_started) == 0
      assert count_tag(events, :tool_execution_completed) == 0

      reducer = StreamReducer.new(session)

      reducer =
        Enum.reduce(events, reducer, fn event, acc ->
          StreamReducer.apply_event(acc, event)
        end)

      {projected, _cr} = StreamReducer.finalize(reducer)
      assert projected.status == :awaiting_tools
      assert [%ToolCall{id: "cm"}] = projected.pending_tool_calls
    end
  end

  # ---------------------------------------------------------------------------
  # Cell 9 — Session.stream_start/3 :manual mixed: whole-loop wins
  # ---------------------------------------------------------------------------

  describe "Session.stream_start/3 :manual mixed (whole-loop wins)" do
    test "pending_tool_calls is FULL response.tool_calls, not the manual subset" do
      engine =
        FakeFixtures.engine(
          [
            {:tool_call, id: "ca", name: "weather", arguments: %{"city" => "Boston"}},
            {:tool_call, id: "cm", name: "charge", arguments: %{"amount" => 20}},
            {:finish, :tool_calls}
          ],
          tools: [weather_tool(), manual_charge_tool()]
        )

      session = Session.new(thread: user_thread())
      assert {:ok, stream} = Session.stream_start(engine, session, mode: :manual)
      events = Enum.to_list(stream)

      reducer = StreamReducer.new(session)

      reducer =
        Enum.reduce(events, reducer, fn event, acc ->
          StreamReducer.apply_event(acc, event)
        end)

      {projected, _cr} = StreamReducer.finalize(reducer)
      assert projected.status == :awaiting_tools

      ids = Enum.map(projected.pending_tool_calls, & &1.id)
      assert ids == ["ca", "cm"]
    end
  end

  # ---------------------------------------------------------------------------
  # Defensive — empty-list metadata MUST NOT mask whole-loop fallback
  # ---------------------------------------------------------------------------

  describe "empty-list-write defensive (Decision #8 tcs != [] guard)" do
    test "whole-loop %ChatResult{} with metadata.manual_tool_calls: [] falls through to final_response.tool_calls" do
      tc = %ToolCall{id: "wl0", name: "echo", arguments: %{}}

      cr = %ChatResult{
        thread: Thread.from_messages([ALLM.user("hi")]),
        final_response: %ALLM.Response{
          finish_reason: :tool_calls,
          tool_calls: [tc]
        },
        halted_reason: :manual_tool_calls,
        metadata: %{manual_turn_index: 0, manual_tool_calls: []},
        steps: []
      }

      session = Session.new(thread: Thread.from_messages([ALLM.user("hi")]))

      projected = Session.apply_chat_result(session, cr)

      assert projected.status == :awaiting_tools
      # Critical: the empty-list metadata clause did NOT mask the
      # final_response.tool_calls list — `tcs != []` guard is load-bearing.
      assert [%ToolCall{id: "wl0"}] = projected.pending_tool_calls
    end

    # Symmetry parallel to the apply_chat_result/2 case above — exercises the
    # same `tcs != []` guard on `step_manual/2`'s metadata clause via the
    # `apply_step_result/2` public-test-seam (`@doc false` + `@spec`).
    test "step_manual/2 with metadata.manual_tool_calls: [] falls through to response.tool_calls" do
      tc = %ToolCall{id: "wl1", name: "echo", arguments: %{}}

      sr = %StepResult{
        thread: Thread.from_messages([ALLM.user("hi")]),
        response: %ALLM.Response{
          finish_reason: :tool_calls,
          tool_calls: [tc]
        },
        tool_results: [],
        done?: false,
        metadata: %{mode: :manual, manual_tool_calls: []}
      }

      session = Session.new(thread: Thread.from_messages([ALLM.user("hi")]))

      projected = Session.apply_step_result(session, sr)

      assert projected.status == :awaiting_tools
      # Critical: the empty-list metadata clause in step_manual/2 did NOT
      # mask the response.tool_calls list — `tcs != []` guard is load-bearing.
      assert [%ToolCall{id: "wl1"}] = projected.pending_tool_calls
    end
  end
end
