defmodule ALLM.Providers.FakeScenariosTest do
  @moduledoc """
  Spec §31 property-style scenarios exercised directly against
  `ALLM.Providers.Fake` (Phase 4) plus the Phase 5 streaming-layer
  coverage. `mix test --only spec_31` scopes Phase 12's regression audit
  to one file.

  Active coverage after Phase 8: 12 scenarios (3 Phase 4 + 3 Phase 5 +
  3 Phase 6 + 3 Phase 7 + 1 Phase 8). All §31 scenarios are now active.

  | # | Scenario | Phase |
  |---|---|---|
  | 1 | pure text streaming with `emit_text_deltas: true` (default) | 4 (active) |
  | 2 | pure text streaming with `emit_text_deltas: false` | 5 (active) |
  | 3 | parallel tool calls at adapter level | 4 (active) |
  | 4 | mid-stream adapter error — stream terminates with `{:error, reason}` | 4/5 (active) |
  | 5 | consumer cancellation releases the adapter's HTTP request | 5 (active — `:counters` observer) |
  | 6 | single tool call with `mode: :auto` through `ALLM.step/3` | 6 (active) |
  | 7 | parallel tool calls through `ALLM.step/3` | 6 (active) |
  | 8 | tool handler raises — `on_tool_error` policy (atom forms) | 6 (active) |
  | 9 | `max_turns` cap through `ALLM.chat/3` | 7 (active) |
  | 10 | `halt_when` fires through `ALLM.chat/3` | 7 (active) |
  | 11 | single tool call with `mode: :manual` — partial flow via `ALLM.chat/3` | 7 (active) |
  | 12 | session round-trip via `term_to_binary` + `ALLM.Session.reply/4` | 8 (active) |
  """

  use ExUnit.Case, async: true

  @moduletag :spec_31

  alias ALLM.{ChatResult, Engine, Message, Request, Response, StepResult, Thread, Tool}
  alias ALLM.Error.AdapterError
  alias ALLM.Providers.Fake
  alias ALLM.Test.FakeFixtures

  import ALLM.Test.AsyncHelpers, only: [wait_for: 2]

  defp echo_tool do
    Tool.new(
      name: "echo",
      description: "",
      schema: %{},
      handler: fn args -> {:ok, args} end
    )
  end

  defp weather_tool do
    Tool.new(
      name: "weather",
      description: "",
      schema: %{},
      handler: fn args -> {:ok, args} end
    )
  end

  defp user_thread, do: Thread.from_messages([ALLM.user("hi")])

  defp fake_request(content \\ "x") do
    Request.new([%Message{role: :user, content: content}])
  end

  # ---------------------------------------------------------------------------
  # Phase 4 — covered scenarios
  # ---------------------------------------------------------------------------

  describe "§31 scenario: pure text streaming (emit_text_deltas default-true)" do
    test ~s(script: [{:text, "he"}, {:text, "llo"}, {:finish, :stop}] yields 5 events) do
      opts = [
        adapter_opts: [script: [{:text, "he"}, {:text, "llo"}, {:finish, :stop}]]
      ]

      assert {:ok, stream} = Fake.stream(fake_request(), opts)
      events = Enum.to_list(stream)

      assert [
               {:message_started, _},
               {:text_delta, %{delta: "he"}},
               {:text_delta, %{delta: "llo"}},
               {:text_completed, %{text: "hello"}},
               {:message_completed, _}
             ] = events
    end
  end

  describe "§31 scenario: parallel tool calls in one assistant turn" do
    test "streaming emits two tool_call_started/completed pairs" do
      opts = [
        adapter_opts: [
          script: [
            {:tool_call, id: "c1", name: "a", arguments: %{x: 1}},
            {:tool_call, id: "c2", name: "b", arguments: %{y: 2}},
            {:finish, :tool_calls}
          ]
        ]
      ]

      assert {:ok, stream} = Fake.stream(fake_request(), opts)
      events = Enum.to_list(stream)

      started = for {:tool_call_started, m} <- events, do: m.id
      completed = for {:tool_call_completed, m} <- events, do: m.id

      assert started == ["c1", "c2"]
      assert completed == ["c1", "c2"]
    end

    test "generate/2 folds into Response.tool_calls of length 2" do
      opts = [
        adapter_opts: [
          script: [
            {:tool_call, id: "c1", name: "a", arguments: %{x: 1}},
            {:tool_call, id: "c2", name: "b", arguments: %{y: 2}},
            {:finish, :tool_calls}
          ]
        ]
      ]

      assert {:ok, %Response{tool_calls: tool_calls, finish_reason: :tool_calls}} =
               Fake.generate(fake_request(), opts)

      assert length(tool_calls) == 2
      assert Enum.map(tool_calls, & &1.id) == ["c1", "c2"]
    end
  end

  describe "§31 scenario: mid-stream adapter error terminates stream" do
    test "[{:text, \"h\"}, {:error, :rate_limited}] yields {:error, %AdapterError{reason: :rate_limited}}" do
      opts = [
        adapter_opts: [script: [{:text, "h"}, {:error, :rate_limited}]]
      ]

      assert {:ok, stream} = Fake.stream(fake_request(), opts)
      events = Enum.to_list(stream)

      assert Enum.any?(
               events,
               &match?({:error, %AdapterError{reason: :rate_limited}}, &1)
             )
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 5 — newly active scenarios
  # ---------------------------------------------------------------------------

  describe "§31 scenario: pure text streaming with emit_text_deltas: false" do
    test "stream_generate/3 drops :text_delta but keeps :text_completed + :message_completed" do
      engine =
        Engine.new(
          adapter: Fake,
          adapter_opts: [script: [{:text, "hello"}, {:finish, :stop}]]
        )

      req = Request.new([%Message{role: :user, content: "x"}])

      assert {:ok, stream} = ALLM.stream_generate(engine, req, emit_text_deltas: false)
      events = Enum.to_list(stream)
      tags = Enum.map(events, &elem(&1, 0))

      refute :text_delta in tags
      assert :text_completed in tags
      assert :message_completed in tags
    end

    test "generate/3 on the same engine produces Response with output_text 'hello' (filter doesn't affect non-streaming)" do
      # Non-streaming generate/3 still reduces the full stream through
      # StreamCollector; the filter's only user-visible effect is on the
      # consumer stream ordering, not on the folded %Response{}.
      engine =
        Engine.new(
          adapter: Fake,
          adapter_opts: [script: [{:text, "hello"}, {:finish, :stop}]]
        )

      req = Request.new([%Message{role: :user, content: "x"}])

      assert {:ok, %Response{output_text: "hello", finish_reason: :stop}} =
               ALLM.generate(engine, req, emit_text_deltas: false)
    end
  end

  describe "§31 scenario: mid-stream adapter error through stream_generate/3 and generate/3" do
    test "stream_generate/3 events include terminal {:error, %AdapterError{reason: :rate_limited}}" do
      engine =
        Engine.new(
          adapter: Fake,
          adapter_opts: [script: [{:text, "partial"}, {:error, :rate_limited}]]
        )

      req = Request.new([%Message{role: :user, content: "x"}])

      assert {:ok, stream} = ALLM.stream_generate(engine, req)
      events = Enum.to_list(stream)

      assert Enum.any?(
               events,
               &match?({:error, %AdapterError{reason: :rate_limited}}, &1)
             )
    end

    test "generate/3 folds mid-stream error into %Response{finish_reason: :error, metadata: %{error: _}}" do
      engine =
        Engine.new(
          adapter: Fake,
          adapter_opts: [script: [{:text, "partial"}, {:error, :rate_limited}]]
        )

      req = Request.new([%Message{role: :user, content: "x"}])

      assert {:ok, %Response{output_text: "partial", finish_reason: :error, metadata: meta}} =
               ALLM.generate(engine, req)

      assert %AdapterError{reason: :rate_limited} = meta.error
    end
  end

  describe "§31 scenario: consumer cancellation releases resources" do
    test "Enum.take(stream, 2) on a 10-event script increments :counters observer within 500 ms" do
      ref = :counters.new(1, [:atomics])

      script = [
        {:text, "a"},
        {:text, "b"},
        {:text, "c"},
        {:text, "d"},
        {:text, "e"},
        {:text, "f"},
        {:text, "g"},
        {:text, "h"},
        {:text, "i"},
        {:text, "j"},
        {:finish, :stop}
      ]

      engine =
        Engine.new(
          adapter: Fake,
          adapter_opts: [script: script, cleanup_observer: ref]
        )

      req = Request.new([%Message{role: :user, content: "x"}])

      assert {:ok, stream} = ALLM.stream_generate(engine, req)
      _ = stream |> Enum.take(2)

      assert wait_for(fn -> :counters.get(ref, 1) == 1 end, 500)
    end

    test "halt-safety through filters: emit_text_deltas: false still propagates halt" do
      # Regression test for Phase 5 Non-obvious Decision #6 composition:
      # the Stream.each/Stream.filter pipeline does not break halt
      # propagation, even when filters drop the user-visible events.
      ref = :counters.new(1, [:atomics])

      script = [
        {:text, "a"},
        {:text, "b"},
        {:text, "c"},
        {:text, "d"},
        {:text, "e"},
        {:text, "f"},
        {:text, "g"},
        {:text, "h"},
        {:text, "i"},
        {:text, "j"},
        {:finish, :stop}
      ]

      engine =
        Engine.new(
          adapter: Fake,
          adapter_opts: [script: script, cleanup_observer: ref]
        )

      req = Request.new([%Message{role: :user, content: "x"}])

      assert {:ok, stream} = ALLM.stream_generate(engine, req, emit_text_deltas: false)
      _ = stream |> Enum.take(2)

      assert wait_for(fn -> :counters.get(ref, 1) == 1 end, 500)
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 6 — newly active scenarios covering tool orchestration end-to-end
  # through `ALLM.step/3`. Exercises the full adapter → ToolRunner → Chat
  # pipeline that Phase 4/5 scenarios tested only at the adapter layer.
  # ---------------------------------------------------------------------------

  describe "§31 scenario: single tool call with mode: :auto" do
    test "ALLM.step/3 executes the tool and appends a :tool-role message" do
      tool =
        Tool.new(
          name: "echo",
          description: "",
          schema: %{},
          handler: fn args -> {:ok, args} end
        )

      engine =
        Engine.new(
          adapter: Fake,
          adapter_opts: [
            script: [
              {:tool_call, id: "c0", name: "echo", arguments: %{"x" => 1}},
              {:finish, :tool_calls}
            ]
          ],
          tools: [tool]
        )

      assert {:ok, %StepResult{} = sr} =
               ALLM.step(engine, [ALLM.user("call echo")], mode: :auto)

      assert sr.done? == false
      assert [%Message{role: :tool, tool_call_id: "c0"}] = sr.tool_results
    end
  end

  describe "§31 scenario: parallel tool calls through ALLM.step/3" do
    test "both handlers run and tool_results list has 2 messages (order-independent)" do
      tool_a =
        Tool.new(
          name: "a",
          description: "",
          schema: %{},
          handler: fn _ -> {:ok, %{from: "a"}} end
        )

      tool_b =
        Tool.new(
          name: "b",
          description: "",
          schema: %{},
          handler: fn _ -> {:ok, %{from: "b"}} end
        )

      engine =
        Engine.new(
          adapter: Fake,
          adapter_opts: [
            script: [
              {:tool_call, id: "c0", name: "a", arguments: %{}},
              {:tool_call, id: "c1", name: "b", arguments: %{}},
              {:finish, :tool_calls}
            ]
          ],
          tools: [tool_a, tool_b]
        )

      assert {:ok, %StepResult{} = sr} =
               ALLM.step(engine, [ALLM.user("call both")], mode: :auto)

      assert sr.done? == false
      assert length(sr.tool_results) == 2

      ids = sr.tool_results |> Enum.map(& &1.tool_call_id) |> Enum.sort()
      assert ids == ["c0", "c1"]
    end
  end

  describe "§31 scenario: tool handler raises, on_tool_error policy fires" do
    # Function form of on_tool_error (e.g. `fn exn, ctx -> ... end`) is
    # deferred to Phase 7. This scenario covers the two atom-form policies
    # (`:continue` and `:halt`) which land with Phase 6.
    test ":continue produces done?: false with the error encoded into tool_results" do
      tool =
        Tool.new(
          name: "raiser",
          description: "",
          schema: %{},
          handler: fn _ -> raise "boom" end
        )

      engine =
        Engine.new(
          adapter: Fake,
          adapter_opts: [
            script: [
              {:tool_call, id: "c0", name: "raiser", arguments: %{}},
              {:finish, :tool_calls}
            ]
          ],
          tools: [tool]
        )

      assert {:ok, %StepResult{} = sr} =
               ALLM.step(engine, [ALLM.user("raise")], on_tool_error: :continue)

      assert sr.done? == false
      assert [%Message{role: :tool, tool_call_id: "c0"}] = sr.tool_results
      refute Map.has_key?(sr.metadata, :halted_reason)
    end

    test ":halt sets done?: true with metadata.halted_reason: :tool_error" do
      tool =
        Tool.new(
          name: "raiser",
          description: "",
          schema: %{},
          handler: fn _ -> raise "boom" end
        )

      engine =
        Engine.new(
          adapter: Fake,
          adapter_opts: [
            script: [
              {:tool_call, id: "c0", name: "raiser", arguments: %{}},
              {:finish, :tool_calls}
            ]
          ],
          tools: [tool]
        )

      assert {:ok, %StepResult{} = sr} =
               ALLM.step(engine, [ALLM.user("raise")], on_tool_error: :halt)

      assert sr.done? == true
      assert sr.metadata[:halted_reason] == :tool_error
      assert sr.metadata[:halt_tool_call_id] == "c0"
    end
  end

  # ---------------------------------------------------------------------------
  # Deferred scenarios — one @tag :pending placeholder per remaining §31
  # bullet. Each test body is `:ok` so the placeholder runs without failure
  # and the test listing shows the deferred work. Phase 12's audit can count
  # these by tag.
  # ---------------------------------------------------------------------------

  describe "§31 scenario: max_turns cap (Phase 7)" do
    test "max_turns: 2 caps the loop after 2 steps; halted_reason :max_turns" do
      # Three turns of tool_calls on the wire — chat/3 with max_turns: 2
      # halts after the second step's tool execution without issuing the
      # third adapter call.
      scripts = [
        [{:tool_call, id: "c0", name: "echo", arguments: %{}}, {:finish, :tool_calls}],
        [{:tool_call, id: "c1", name: "echo", arguments: %{}}, {:finish, :tool_calls}],
        [{:tool_call, id: "c2", name: "echo", arguments: %{}}, {:finish, :tool_calls}]
      ]

      engine = FakeFixtures.engine_with_scripts(scripts, tools: [echo_tool()])

      assert {:ok, %ChatResult{} = result} =
               ALLM.chat(engine, user_thread(), max_turns: 2)

      assert result.halted_reason == :max_turns
      assert result.metadata.max_turns == 2
      assert length(result.steps) == 2
    end
  end

  describe "§31 scenario: halt_when fires (Phase 7)" do
    test "halt_when fires at step 1; halted_reason :halt_when" do
      # Two-turn fixture: tool_calls then plain text. halt_when looks at
      # the step's tool_results — which is non-empty after the first turn
      # — and halts before issuing the second adapter call.
      scripts = [
        [{:tool_call, id: "c0", name: "echo", arguments: %{}}, {:finish, :tool_calls}],
        [{:text, "done"}, {:finish, :stop}]
      ]

      engine = FakeFixtures.engine_with_scripts(scripts, tools: [echo_tool()])

      halt_when = fn sr -> sr.tool_results != [] end

      assert {:ok, %ChatResult{} = result} =
               ALLM.chat(engine, user_thread(), halt_when: halt_when)

      assert result.halted_reason == :halt_when
      assert result.metadata.halt_when_step_index == 0
      assert length(result.steps) == 1
    end
  end

  describe "§31 scenario: single tool call with mode: :manual — partial flow via chat/3 (Phase 7)" do
    test "mode: :manual surfaces tool calls without executing; halted_reason :manual_tool_calls" do
      # Single-turn tool-call script. mode: :manual halts on the FIRST
      # response that carries finish_reason: :tool_calls, returning the
      # tool calls on final_response for the caller to submit results
      # (the full session round-trip is Phase 8).
      script = [
        {:tool_call, id: "c0", name: "weather", arguments: %{city: "Boston"}},
        {:finish, :tool_calls}
      ]

      engine = FakeFixtures.engine(script, tools: [weather_tool()])

      assert {:ok, %ChatResult{} = result} =
               ALLM.chat(engine, user_thread(), mode: :manual)

      assert result.halted_reason == :manual_tool_calls
      assert result.metadata.manual_turn_index == 0
      assert length(result.steps) == 1
      assert hd(result.steps).tool_results == []

      # final_response carries the surfaced tool call.
      assert [tool_call] = result.final_response.tool_calls
      assert tool_call.name == "weather"
    end
  end

  describe "§31 scenario: session round-trip (Phase 8)" do
    test "Session.start/3 → term_to_binary → resume → reply/4 thread matches in-process reply/4" do
      # Two-script fixture: turn 1 is the initial user query, turn 2 is
      # the resumption after a (deserialized) reply/4. The cursor is
      # allocated by `engine_with_scripts/2` and threaded through
      # adapter_opts so both adapter calls advance through the script
      # list deterministically.
      scripts = [
        [{:text, "first"}, {:finish, :stop}],
        [{:text, "second"}, {:finish, :stop}]
      ]

      engine_a = FakeFixtures.engine_with_scripts(scripts)
      engine_b = FakeFixtures.engine_with_scripts(scripts)

      # In-process arm: start → reply.
      {:ok, s1, _} = ALLM.Session.start(engine_a, [ALLM.user("hi")])
      {:ok, s2_inproc, _} = ALLM.Session.reply(engine_a, s1, "more")

      # Persist + resume arm: start → ETF → deETF → reply on the
      # restored session against a fresh cursor.
      {:ok, s1_b, _} = ALLM.Session.start(engine_b, [ALLM.user("hi")])
      serialized = :erlang.term_to_binary(s1_b)
      s1_restored = :erlang.binary_to_term(serialized)

      assert s1_b == s1_restored

      {:ok, s2_resumed, _} = ALLM.Session.reply(engine_b, s1_restored, "more")

      # Thread shape match — the load-bearing equivalence claim of the
      # §31 round-trip scenario.
      assert s2_inproc.thread.messages == s2_resumed.thread.messages
    end
  end
end
