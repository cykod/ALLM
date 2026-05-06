defmodule ALLM.ChatEquivalenceTest do
  @moduledoc """
  Sub-phase 7.5 — chat-equivalence property test (spec §3, PHASE_7_DESIGN
  Non-obvious Decision #4).

  The load-bearing correctness invariant for Phase 7: for every Fake
  fixture × valid chat-opts combination,

      ALLM.Chat.run(engine, thread, opts) ≡
        ALLM.Chat.stream(engine, thread, opts)
        |> Enum.reduce(StreamCollector.new(thread), &apply_event/2)
        |> StreamCollector.to_chat_result/1

  modulo `tool_call_id` ordering on `:tool`-role messages and on each
  step's `:tool_results` (Phase 6 design Non-obvious Decision #9).
  `Assertions.assert_equivalent_chat_result/2` normalises the order.

  Because both paths construct the `%ChatResult{}` via the same
  `ALLM.Chat.build_chat_result/1` helper, equivalence is established by
  construction (Non-obvious Decision #4); this property is the
  end-to-end witness.

  ## Process-dict cursor isolation

  Fake's default per-process script cursor is keyed by
  `:erlang.phash2(scripts)` in the reducing process's dictionary. Each
  fixture is constructed twice (once per path) inside its own
  `Task.async/1` so the two paths see fresh process-dict cursors.

  ## Fixture matrix

  Per PHASE_7_DESIGN.md §7.5.1 (Phase 7.6 cleanup restored the strict
  property + 9th fixture), the property exercises:

    * Happy multi-turn (tool_call → text)
    * Multi-turn with `max_turns: 1`
    * Single-turn text
    * Multi-turn with `halt_when` that fires at step 1
    * Manual mode (single-turn tool_calls)
    * Ask-user mid-loop
    * Handler custom halt atom
    * `on_tool_error: fn _, _ -> {:continue, %{ok: 1}} end`
    * `on_tool_error: :halt` — `halted_reason: :tool_error`
    * Vision multi-turn (Phase 17.1 — text+image content)
    * Mixed manual first turn (Phase 18.5 — auto echo + manual confirm)
    * Pure manual first turn (Phase 18.5 — single manual tool call)
    * Auto-only no-manual-flags-set control (Phase 18.5 — byte-identical
      pre/post-Phase-18; same Fake script as `:happy_multi_turn` but
      asserts `metadata.manual_tool_calls` is absent on both arms)

  StreamData iterates a fixture-id and chat-opts variant; each (fixture,
  opts) tuple is a property iteration. Total: ≥100 iterations.

  ## Phase 18.5 relaxation budget

  | Field                          | Relaxation                      | Justification                                                                                | Risk      |
  | ------------------------------ | ------------------------------- | -------------------------------------------------------------------------------------------- | --------- |
  | `metadata.manual_tool_calls`   | none — both arms identical lists | partition is deterministic; same `partition_tool_calls/2` from shared `Chat.build_chat_result/1` | tolerable |
  | `metadata.mode`                | already relaxed by Phase 7      | unchanged                                                                                    | unchanged |
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :property

  alias ALLM.{Chat, ChatResult, Image, ImagePart, Message, StreamCollector, TextPart, Thread, Tool}
  alias ALLM.Test.Assertions
  alias ALLM.Test.FakeFixtures

  # ---------------------------------------------------------------------------
  # Tools
  # ---------------------------------------------------------------------------

  defp echo_tool do
    Tool.new(
      name: "echo",
      description: "",
      schema: %{},
      handler: fn args -> {:ok, args} end
    )
  end

  defp raising_tool do
    Tool.new(
      name: "raises",
      description: "",
      schema: %{},
      handler: fn _ -> raise "boom" end
    )
  end

  defp custom_halt_tool do
    Tool.new(
      name: "plan",
      description: "",
      schema: %{},
      handler: fn _ -> {:halt, :plan_submitted, %{ok: 1}} end
    )
  end

  defp ask_user_tool do
    Tool.new(
      name: "ask",
      description: "",
      schema: %{},
      handler: fn _ -> {:ask_user, "which city?", choices: ["A", "B"]} end
    )
  end

  # Phase 18.5 — per-tool manual fixture helper. `manual: true` opts the
  # tool out of auto-execution under `mode: :auto`; the orchestrator
  # partitions and halts with `:manual_tool_calls`. No handler is needed
  # because the manual subset never executes (per spec §12.4).
  defp manual_tool(name) do
    Tool.new(name: name, description: "", schema: %{}, manual: true)
  end

  defp user_thread, do: Thread.from_messages([ALLM.user("hi")])

  # ---------------------------------------------------------------------------
  # Fixture builders. Each returns `{engine_builder, opts}` where
  # `engine_builder` is a 0-arity fun that yields a fresh engine on each
  # call (so the Fake cursor lives in the calling process — see
  # `step_equivalence_test.exs` for the pattern).
  # ---------------------------------------------------------------------------

  defp fixture(:happy_multi_turn) do
    scripts = [
      [
        {:tool_call, id: "c0", name: "echo", arguments: %{"x" => 1}},
        {:finish, :tool_calls}
      ],
      [{:text, "done"}, {:finish, :stop}]
    ]

    {fn -> FakeFixtures.engine_with_scripts(scripts, tools: [echo_tool()]) end, []}
  end

  defp fixture(:max_turns_one) do
    scripts = [
      [{:tool_call, id: "c0", name: "echo", arguments: %{}}, {:finish, :tool_calls}],
      [{:tool_call, id: "c1", name: "echo", arguments: %{}}, {:finish, :tool_calls}]
    ]

    {fn -> FakeFixtures.engine_with_scripts(scripts, tools: [echo_tool()]) end, [max_turns: 1]}
  end

  defp fixture(:single_turn_text) do
    {fn -> FakeFixtures.engine([{:text, "hi"}, {:finish, :stop}]) end, []}
  end

  defp fixture(:halt_when_at_step_1) do
    scripts = [
      [
        {:tool_call, id: "c0", name: "echo", arguments: %{}},
        {:finish, :tool_calls}
      ],
      [{:text, "done"}, {:finish, :stop}]
    ]

    halt_when = fn sr -> sr.tool_results != [] end

    {fn -> FakeFixtures.engine_with_scripts(scripts, tools: [echo_tool()]) end,
     [halt_when: halt_when]}
  end

  defp fixture(:manual_mode) do
    script = [
      {:tool_call, id: "c0", name: "echo", arguments: %{"x" => 1}},
      {:finish, :tool_calls}
    ]

    {fn -> FakeFixtures.engine(script, tools: [echo_tool()]) end, [mode: :manual]}
  end

  defp fixture(:ask_user_mid_loop) do
    script = [
      {:tool_call, id: "c0", name: "ask", arguments: %{}},
      {:finish, :tool_calls}
    ]

    {fn -> FakeFixtures.engine(script, tools: [ask_user_tool()]) end, []}
  end

  defp fixture(:custom_halt_atom) do
    script = [
      {:tool_call, id: "c0", name: "plan", arguments: %{}},
      {:finish, :tool_calls}
    ]

    {fn -> FakeFixtures.engine(script, tools: [custom_halt_tool()]) end, []}
  end

  defp fixture(:on_tool_error_fun_continue) do
    scripts = [
      [{:tool_call, id: "c0", name: "raises", arguments: %{}}, {:finish, :tool_calls}],
      [{:text, "ok"}, {:finish, :stop}]
    ]

    on_tool_error = fn _, _ -> {:continue, %{ok: 1}} end

    {fn -> FakeFixtures.engine_with_scripts(scripts, tools: [raising_tool()]) end,
     [on_tool_error: on_tool_error]}
  end

  defp fixture(:on_tool_error_halt) do
    script = [
      {:tool_call, id: "c0", name: "raises", arguments: %{}},
      {:finish, :tool_calls}
    ]

    {fn -> FakeFixtures.engine(script, tools: [raising_tool()]) end, [on_tool_error: :halt]}
  end

  # Phase 17.1 — vision-only multi-turn fixture (row 10). User message
  # carries `[%TextPart{}, %ImagePart{}]`; the Fake script is text-only
  # for both arms so the chat-equivalence property holds verbatim.
  defp fixture(:vision_multi_turn) do
    {fn ->
       FakeFixtures.engine([{:text, "I see a cat."}, {:finish, :stop}])
     end, [thread: vision_thread()]}
  end

  # Phase 18.5 — mixed bucket: turn 1 emits two tool calls, one auto
  # (`echo`) and one manual (`confirm`). Auto runs eagerly, the loop
  # halts with `:manual_tool_calls`, and `metadata.manual_tool_calls`
  # carries the manual subset. Both `chat/3` and `stream/3` arms must
  # produce byte-identical metadata (non-relaxed per the budget table).
  defp fixture(:mixed_manual_first_turn) do
    script = [
      {:tool_call, id: "c0", name: "echo", arguments: %{"x" => 1}},
      {:tool_call, id: "c1", name: "confirm", arguments: %{"action" => "delete"}},
      {:finish, :tool_calls}
    ]

    {fn ->
       FakeFixtures.engine(script, tools: [echo_tool(), manual_tool("confirm")])
     end, []}
  end

  # Phase 18.5 — pure manual bucket: turn 1 emits one tool call against
  # a `manual: true` tool. No auto tools execute; loop halts with
  # `:manual_tool_calls` and `metadata.manual_tool_calls` is the
  # singleton list.
  defp fixture(:pure_manual_first_turn) do
    script = [
      {:tool_call, id: "c0", name: "confirm", arguments: %{"action" => "delete"}},
      {:finish, :tool_calls}
    ]

    {fn -> FakeFixtures.engine(script, tools: [manual_tool("confirm")]) end, []}
  end

  # Phase 18.5 — control case: same script as `:happy_multi_turn` (auto
  # tool, multi-turn → text), but explicitly assert via the property
  # that no `manual_tool_calls` key leaks into metadata. Byte-identical
  # to pre-Phase-18 behaviour.
  defp fixture(:auto_only_no_manual_flags_set) do
    scripts = [
      [
        {:tool_call, id: "c0", name: "echo", arguments: %{"x" => 1}},
        {:finish, :tool_calls}
      ],
      [{:text, "done"}, {:finish, :stop}]
    ]

    {fn -> FakeFixtures.engine_with_scripts(scripts, tools: [echo_tool()]) end, []}
  end

  defp vision_thread do
    img = Image.from_url("https://example.com/cat.png")

    Thread.from_messages([
      %Message{
        role: :user,
        content: [
          %TextPart{text: "What's in this image?"},
          %ImagePart{image: img, detail: :high}
        ]
      }
    ])
  end

  # ---------------------------------------------------------------------------
  # Path runners — Task.async isolation per path so the Fake cursor is
  # scoped to a single call's process.
  # ---------------------------------------------------------------------------

  defp run_chat(engine_builder, opts) do
    {thread, opts} = pop_thread(opts)

    Task.async(fn -> Chat.run(engine_builder.(), thread, opts) end)
    |> Task.await(:timer.seconds(5))
  end

  defp run_stream_chat(engine_builder, opts) do
    {thread, opts} = pop_thread(opts)

    Task.async(fn -> stream_and_collect(engine_builder.(), thread, opts) end)
    |> Task.await(:timer.seconds(5))
  end

  defp stream_and_collect(engine, thread, opts) do
    case Chat.stream(engine, thread, opts) do
      {:ok, stream} -> {:ok, fold_to_chat_result(stream, thread)}
      {:error, _} = err -> err
    end
  end

  defp fold_to_chat_result(stream, thread) do
    stream
    |> Enum.reduce(StreamCollector.new(thread), fn event, acc ->
      StreamCollector.apply_event(acc, event)
    end)
    |> StreamCollector.to_chat_result()
  end

  # Pop a `thread:` override from opts (used by the Phase 17.1 vision
  # fixture) — defaults to the canonical text user_thread/0.
  defp pop_thread(opts) do
    case Keyword.pop(opts, :thread) do
      {nil, opts2} -> {user_thread(), opts2}
      {thread, opts2} -> {thread, opts2}
    end
  end

  # ---------------------------------------------------------------------------
  # The property: iterate fixture-id, assert chat-equivalence.
  # ---------------------------------------------------------------------------

  @fixture_ids [
    :happy_multi_turn,
    :max_turns_one,
    :single_turn_text,
    :halt_when_at_step_1,
    :manual_mode,
    :ask_user_mid_loop,
    :custom_halt_atom,
    :on_tool_error_fun_continue,
    :on_tool_error_halt,
    :vision_multi_turn,
    # Phase 18.5 — per-tool manual fixtures (chat-equivalence property
    # holds with `metadata.manual_tool_calls` non-relaxed).
    :mixed_manual_first_turn,
    :pure_manual_first_turn,
    :auto_only_no_manual_flags_set
  ]

  property "Chat.run/3 ≡ Chat.stream/3 |> StreamCollector.to_chat_result/1 — every fixture × valid opts" do
    check all(fixture_id <- StreamData.member_of(@fixture_ids), max_runs: 100) do
      {engine_builder, opts} = fixture(fixture_id)

      assert {:ok, %ChatResult{} = run_result} = run_chat(engine_builder, opts)

      assert {:ok, %ChatResult{} = stream_result} = run_stream_chat(engine_builder, opts)

      Assertions.assert_equivalent_chat_result(run_result, stream_result)
    end
  end

  # Phase 18.5 — explicit per-fixture assertions on `metadata.manual_tool_calls`
  # shape. The property above asserts strict metadata-map equality between
  # arms; these tests pin the absolute key presence/absence + list contents
  # so a future regression that drops the key from BOTH arms simultaneously
  # (which would still pass equivalence) is caught.

  test "mixed_manual_first_turn — both arms surface metadata.manual_tool_calls with the manual subset only" do
    {engine_builder, opts} = fixture(:mixed_manual_first_turn)

    assert {:ok, %ChatResult{} = run_result} = run_chat(engine_builder, opts)
    assert {:ok, %ChatResult{} = stream_result} = run_stream_chat(engine_builder, opts)

    for cr <- [run_result, stream_result] do
      assert cr.halted_reason == :manual_tool_calls
      assert is_list(cr.metadata.manual_tool_calls)
      assert length(cr.metadata.manual_tool_calls) == 1
      assert hd(cr.metadata.manual_tool_calls).name == "confirm"
    end

    Assertions.assert_equivalent_chat_result(run_result, stream_result)
  end

  test "pure_manual_first_turn — both arms surface the singleton manual list" do
    {engine_builder, opts} = fixture(:pure_manual_first_turn)

    assert {:ok, %ChatResult{} = run_result} = run_chat(engine_builder, opts)
    assert {:ok, %ChatResult{} = stream_result} = run_stream_chat(engine_builder, opts)

    for cr <- [run_result, stream_result] do
      assert cr.halted_reason == :manual_tool_calls
      assert [%ALLM.ToolCall{name: "confirm"}] = cr.metadata.manual_tool_calls
    end

    Assertions.assert_equivalent_chat_result(run_result, stream_result)
  end

  test "auto_only_no_manual_flags_set — neither arm leaks a manual_tool_calls key into metadata" do
    {engine_builder, opts} = fixture(:auto_only_no_manual_flags_set)

    assert {:ok, %ChatResult{} = run_result} = run_chat(engine_builder, opts)
    assert {:ok, %ChatResult{} = stream_result} = run_stream_chat(engine_builder, opts)

    for cr <- [run_result, stream_result] do
      assert cr.halted_reason == :completed
      refute Map.has_key?(cr.metadata, :manual_tool_calls)
    end

    Assertions.assert_equivalent_chat_result(run_result, stream_result)
  end
end
