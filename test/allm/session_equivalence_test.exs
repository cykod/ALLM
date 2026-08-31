defmodule ALLM.SessionEquivalenceTest do
  @moduledoc """
  Phase 8 sub-phase 8.4 — session-equivalence property test (spec §11,
  §13.2).

  The load-bearing correctness invariant for Phase 8: for every
  multi-turn Fake script, `ALLM.Session.start/3` returns a session+result
  pair equivalent to `ALLM.Session.stream_start/3 |> reduce(StreamReducer)
  |> StreamReducer.finalize/1`.

  Per `agent-spec/IMPLEMENTATION.md` §Property tests "Fake-per-process
  cursor isolation" rule, each call (non-streaming and streaming) is
  wrapped in `Task.async/Task.await` so the Fake's process-dictionary
  cursor doesn't shared-cursor between the two arms.

  The relaxation budget is documented in `PHASE_8_DESIGN.md` §8.4.1 and
  enforced by `assert_equivalent_session_result/2`. Notably, `:metadata`
  equality is asserted unconditionally (no silent skip) — see Batch 3
  retro for the masking-divergence resolution.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :property

  alias ALLM.{Engine, Session, Tool}
  alias ALLM.Providers.Fake
  alias ALLM.Session.StreamReducer

  import ALLM.Test.Assertions, only: [assert_equivalent_session_result: 2]

  defp echo_tool do
    Tool.new(
      name: "echo",
      description: "",
      schema: %{},
      handler: fn args -> {:ok, args} end
    )
  end

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  # A single text-finish script — ends in :stop.
  defp text_script_gen do
    StreamData.bind(
      StreamData.string(:printable, min_length: 1, max_length: 6),
      fn text -> StreamData.constant([{:text, text}, {:finish, :stop}]) end
    )
  end

  # A tool-calls script — emits one or two tool calls (always against
  # the "echo" tool so the engine's tool list is fixed) and finishes
  # :tool_calls.
  defp tool_calls_script_gen do
    StreamData.bind(
      StreamData.integer(1..2),
      fn n ->
        calls =
          for i <- 0..(n - 1) do
            {:tool_call, id: "c#{i}", name: "echo", arguments: %{"x" => i}}
          end

        StreamData.constant(calls ++ [{:finish, :tool_calls}])
      end
    )
  end

  # A multi-turn script: a list of 1–3 inner scripts, where every inner
  # script EXCEPT the last is a tool-calls turn (driving the loop forward)
  # and the last is a text-finish turn (terminating the loop).
  #
  # Constraints to keep the search space well-formed:
  #
  #   * Always at least one terminating text-finish script (otherwise
  #     `:max_turns` would fire and divergence detection becomes about
  #     halt path, not happy path). The property still covers halt paths
  #     because tool calls naturally drive multiple turns.
  #
  #   * Tool-calls scripts use deterministic `c0`/`c1` ids so the
  #     non-streaming and streaming arms see identical wire-shape
  #     scripts.
  defp multi_turn_script_generator do
    StreamData.bind(
      StreamData.integer(0..2),
      &multi_turn_with_n_tool_turns/1
    )
  end

  defp multi_turn_with_n_tool_turns(n_tool_turns) do
    StreamData.bind(
      StreamData.list_of(tool_calls_script_gen(), length: n_tool_turns),
      &finalize_multi_turn/1
    )
  end

  defp finalize_multi_turn(tool_scripts) do
    StreamData.bind(text_script_gen(), fn final_script ->
      StreamData.constant(tool_scripts ++ [final_script])
    end)
  end

  # ---------------------------------------------------------------------------
  # Engine builders + isolated runs
  # ---------------------------------------------------------------------------

  defp build_engine(scripts) do
    cursor = Fake.start_script_cursor()

    Engine.new(
      adapter: Fake,
      adapter_opts: [scripts: scripts, script_cursor: cursor],
      tools: [echo_tool()]
    )
  end

  defp run_non_streaming(scripts, input) do
    # Build engine inside the task so the script_cursor lives in the
    # task's process — no cursor leak between the two arms.
    Task.async(fn ->
      engine = build_engine(scripts)
      Session.start(engine, input)
    end)
    |> Task.await(:timer.seconds(10))
  end

  defp run_streaming(scripts, input) do
    Task.async(fn -> do_run_streaming(scripts, input) end)
    |> Task.await(:timer.seconds(10))
  end

  defp do_run_streaming(scripts, input) do
    engine = build_engine(scripts)

    with {:ok, stream} <- Session.stream_start(engine, input) do
      {s, r} = collect_stream(stream)
      {:ok, s, r}
    end
  end

  defp collect_stream(stream) do
    stream
    |> Enum.reduce(
      StreamReducer.new(Session.new()),
      fn ev, acc -> StreamReducer.apply_event(acc, ev) end
    )
    |> StreamReducer.finalize()
  end

  # ---------------------------------------------------------------------------
  # Property
  # ---------------------------------------------------------------------------

  property "Session.start/3 ≡ Session.stream_start/3 |> StreamReducer.finalize/1" do
    check all(scripts <- multi_turn_script_generator(), max_runs: 100) do
      input = [ALLM.user("hi")]

      assert {:ok, %Session{} = s1, r1} = run_non_streaming(scripts, input)
      assert {:ok, %Session{} = s2, r2} = run_streaming(scripts, input)

      assert_equivalent_session_result({s1, r1}, {s2, r2})
    end
  end
end
