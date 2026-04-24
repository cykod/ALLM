defmodule ALLM.StepEquivalenceTest do
  @moduledoc """
  Sub-phase 6.4 — step-equivalence property test (spec §3).

  The load-bearing correctness invariant for Phase 6: for every Fake
  script drawn from a tool-call-bearing subset of the §31 vocabulary,

      ALLM.step(engine, thread, mode: :auto) ≡
        ALLM.stream_step(engine, thread, mode: :auto)
        |> Enum.reduce(collector, &apply_event/2)
        |> to_step_result/1

  modulo `tool_call_id` ordering on `:tool_results` and on `:tool`-role
  messages within the thread (Phase 6 design Non-obvious Decision #9).
  `assert_equivalent_step_result/2` normalises the order.

  ## Process-dict cursor isolation

  Fake's default per-process script cursor is keyed by
  `:erlang.phash2(scripts)` in the reducing process's dictionary. Running
  `ALLM.step/3` then `ALLM.stream_step/3` sequentially in the same process
  with the same script content would share a cursor and script-exhaust
  the second call. Each path therefore runs inside its own `Task.async/1`
  process so the two calls see fresh process-dict cursors.

  ## Thread extraction from `:step_completed`

  The `StreamCollector` keeps its seeded thread unchanged (the
  `:step_completed` fold clause is a catch-all no-op; Phase 7 may add
  explicit handling). This property extracts the augmented thread from
  the `:step_completed` event's payload directly, then threads it into
  the collector via `Map.put/3` before invoking `to_step_result/1`.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :property

  alias ALLM.{Engine, StepResult, StreamCollector, Thread, Tool}
  alias ALLM.Providers.Fake
  alias ALLM.Test.Assertions

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp user_thread, do: Thread.from_messages([ALLM.user("hi")])

  # Every tool in the property has the same deterministic handler:
  # `{:ok, args}`. Generator wires tool names in lockstep with tool_call
  # entries so there are no `:unknown_tool` pre-flight errors.
  defp tool_for(name) do
    Tool.new(
      name: name,
      description: "",
      schema: %{},
      handler: fn args -> {:ok, args} end
    )
  end

  defp raising_tool(name) do
    Tool.new(
      name: name,
      description: "",
      schema: %{},
      handler: fn _ -> raise "boom" end
    )
  end

  defp engine_of(script, tools) do
    Engine.new(adapter: Fake, adapter_opts: [script: script], tools: tools)
  end

  # Fold the stream through the collector, extracting the augmented thread
  # from the `:step_completed` event. The StreamCollector's catch-all
  # currently no-ops on `:step_completed`; we snapshot the thread from its
  # payload and thread it into the collector before the final call to
  # `to_step_result/1` so the equivalence compares the post-execution
  # thread on both sides.
  defp collect_step_result(stream, initial_thread) do
    initial = StreamCollector.new(initial_thread)

    {collector, final_thread} =
      Enum.reduce(stream, {initial, initial_thread}, fn event, {coll, thread} ->
        new_coll = StreamCollector.apply_event(coll, event)

        new_thread =
          case event do
            {:step_completed, %{thread: %Thread{} = t}} -> t
            _ -> thread
          end

        {new_coll, new_thread}
      end)

    %{collector | thread: final_thread}
    |> StreamCollector.to_step_result()
  end

  # ---------------------------------------------------------------------------
  # Generators — tool-call-bearing §31 scripts
  # ---------------------------------------------------------------------------

  # Generate a tool name from a small closed set so we can register the
  # matching tools on the engine in lockstep with the script.
  defp tool_name_gen do
    StreamData.member_of(["tool_a", "tool_b", "tool_c"])
  end

  defp text_entry_gen do
    StreamData.bind(
      StreamData.string(:alphanumeric, min_length: 1, max_length: 5),
      fn s -> StreamData.constant({:text, s}) end
    )
  end

  defp tool_call_entry_gen do
    StreamData.bind(
      StreamData.tuple({StreamData.integer(0..5), tool_name_gen()}),
      fn {n, name} ->
        StreamData.constant({:tool_call, id: "id_#{n}", name: name, arguments: %{"k" => "v"}})
      end
    )
  end

  defp usage_entry_gen do
    StreamData.bind(
      StreamData.tuple({StreamData.integer(0..50), StreamData.integer(0..50)}),
      fn {input, output} ->
        StreamData.constant({:usage, %{input_tokens: input, output_tokens: output}})
      end
    )
  end

  defp entry_gen do
    StreamData.one_of([
      text_entry_gen(),
      tool_call_entry_gen(),
      usage_entry_gen()
    ])
  end

  defp finish_gen do
    StreamData.member_of([{:finish, :tool_calls}, {:finish, :stop}])
  end

  # A script with at least one tool_call entry (so the equivalence
  # exercises the Phase B tool-execution path for most iterations) plus
  # any mix of other entries, terminating with a :finish. We always
  # include one tool_call so the tool-dispatch branch gets coverage;
  # 1..3 tool calls emulate parallel / streamed variants.
  defp script_with_tools_gen do
    StreamData.bind(
      StreamData.tuple({
        StreamData.list_of(tool_call_entry_gen(), min_length: 1, max_length: 3),
        StreamData.list_of(entry_gen(), min_length: 0, max_length: 6),
        finish_gen()
      }),
      fn {tool_calls, other_entries, finish} ->
        # Interleave tool_calls into the other entries by placing them
        # first; Phase 6 tool-call accumulation tolerates either
        # ordering, but leading tool_calls keeps ids stable.
        StreamData.constant(tool_calls ++ other_entries ++ [finish])
      end
    )
  end

  # Collect the set of tool names referenced by :tool_call entries so we
  # can register them on the engine. Phase 6 rejects unknown tools
  # pre-flight; this generator keeps the tool-set in lockstep.
  defp tools_for_script(script) do
    script
    |> Enum.flat_map(fn
      {:tool_call, fields} -> [Keyword.fetch!(fields, :name)]
      _ -> []
    end)
    |> Enum.uniq()
    |> Enum.map(&tool_for/1)
  end

  # ---------------------------------------------------------------------------
  # Task.async isolation — Fake's per-process cursor collides on
  # content-equal scripts in the same process.
  # ---------------------------------------------------------------------------

  defp run_step(script, tools) do
    Task.async(fn ->
      engine = engine_of(script, tools)
      ALLM.step(engine, user_thread(), mode: :auto)
    end)
    |> Task.await(:timer.seconds(5))
  end

  defp run_stream_step_and_collect(script, tools) do
    Task.async(fn ->
      engine = engine_of(script, tools)

      case ALLM.stream_step(engine, user_thread(), mode: :auto) do
        {:ok, stream} ->
          {:ok, collect_step_result(stream, user_thread())}

        {:error, _} = err ->
          err
      end
    end)
    |> Task.await(:timer.seconds(5))
  end

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  property "step/3 ≡ stream_step/3 |> reduce(collector) |> to_step_result/1" do
    check all(script <- script_with_tools_gen(), max_runs: 100) do
      tools = tools_for_script(script)

      assert {:ok, %StepResult{} = step_result} = run_step(script, tools)

      assert {:ok, %StepResult{} = collected} =
               run_stream_step_and_collect(script, tools)

      Assertions.assert_equivalent_step_result(step_result, collected)
    end
  end

  property "handler-raise equivalence: on_tool_error: :continue" do
    # Mid-execution handler failure: both paths produce identical
    # StepResults with the error encoded as the tool_result content.
    check all(
            n <- StreamData.integer(0..5),
            max_runs: 100
          ) do
      script = [
        {:tool_call, id: "id_#{n}", name: "raiser", arguments: %{}},
        {:finish, :tool_calls}
      ]

      tools = [raising_tool("raiser")]

      step_result =
        Task.async(fn ->
          engine = engine_of(script, tools)
          ALLM.step(engine, user_thread(), mode: :auto, on_tool_error: :continue)
        end)
        |> Task.await(:timer.seconds(5))

      collected =
        Task.async(fn ->
          engine = engine_of(script, tools)

          case ALLM.stream_step(engine, user_thread(),
                 mode: :auto,
                 on_tool_error: :continue
               ) do
            {:ok, stream} -> {:ok, collect_step_result(stream, user_thread())}
            {:error, _} = err -> err
          end
        end)
        |> Task.await(:timer.seconds(5))

      assert {:ok, %StepResult{done?: false, tool_results: [_error_msg]} = a} = step_result
      assert {:ok, %StepResult{done?: false, tool_results: [_]} = b} = collected

      Assertions.assert_equivalent_step_result(a, b)
    end
  end
end
