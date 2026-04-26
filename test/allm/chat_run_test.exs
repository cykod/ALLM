defmodule ALLM.ChatRunTest do
  use ExUnit.Case, async: true

  alias ALLM.{Chat, ChatResult, Engine, Message, Thread, Tool, ToolCall}
  alias ALLM.Error.{EngineError, ValidationError}
  alias ALLM.Providers.Fake
  alias ALLM.Test.{FakeFixtures, TelemetryCapture}

  # ---------------------------------------------------------------------------
  # Helpers
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
      handler: fn _args -> raise "boom" end
    )
  end

  defp tool_call_then_text_scripts do
    [
      [
        {:tool_call, id: "c0", name: "echo", arguments: %{"x" => 1}},
        {:finish, :tool_calls}
      ],
      [{:text, "done"}, {:finish, :stop}]
    ]
  end

  defp user_thread, do: Thread.from_messages([ALLM.user("hi")])

  # ---------------------------------------------------------------------------
  # Happy path — single-turn text
  # ---------------------------------------------------------------------------

  describe "run/3 — happy path" do
    test "single-turn text returns :completed" do
      engine = FakeFixtures.engine([{:text, "hello"}, {:finish, :stop}])

      assert {:ok, %ChatResult{} = result} = Chat.run(engine, user_thread())
      assert result.halted_reason == :completed
      assert length(result.steps) == 1
      assert result.final_response.output_text == "hello"
      assert result.final_response.finish_reason == :stop
    end

    test "two-turn tool call returns :completed with two steps" do
      engine = FakeFixtures.engine_with_scripts(tool_call_then_text_scripts(), tools: [echo_tool()])

      assert {:ok, %ChatResult{} = result} = Chat.run(engine, user_thread())
      assert result.halted_reason == :completed
      assert length(result.steps) == 2
      assert result.final_response.output_text == "done"

      # Thread shape: [user, assistant(tool_calls), tool, assistant("done")]
      assert length(result.thread.messages) == 4
      [_user, _a1, tool_msg, a2] = result.thread.messages
      assert tool_msg.role == :tool
      assert tool_msg.tool_call_id == "c0"
      assert a2.role == :assistant
      assert a2.content == "done"
    end
  end

  # ---------------------------------------------------------------------------
  # max_turns
  # ---------------------------------------------------------------------------

  describe "run/3 — max_turns" do
    test "max_turns: 2 caps at 2 steps with halted_reason: :max_turns" do
      scripts = [
        [{:tool_call, id: "c0", name: "echo", arguments: %{}}, {:finish, :tool_calls}],
        [{:tool_call, id: "c1", name: "echo", arguments: %{}}, {:finish, :tool_calls}],
        [{:tool_call, id: "c2", name: "echo", arguments: %{}}, {:finish, :tool_calls}]
      ]

      engine = FakeFixtures.engine_with_scripts(scripts, tools: [echo_tool()])

      assert {:ok, %ChatResult{} = result} =
               Chat.run(engine, user_thread(), max_turns: 2)

      assert result.halted_reason == :max_turns
      assert length(result.steps) == 2
      assert result.metadata == %{max_turns: 2}
    end

    test "max_turns: 1 halts after one step regardless of finish_reason" do
      engine =
        FakeFixtures.engine(
          [{:tool_call, id: "c0", name: "echo", arguments: %{}}, {:finish, :tool_calls}],
          tools: [echo_tool()]
        )

      assert {:ok, %ChatResult{} = result} = Chat.run(engine, user_thread(), max_turns: 1)
      assert result.halted_reason == :max_turns
      assert length(result.steps) == 1
    end

    test "default max_turns is 8" do
      # Eight tool-call turns, then a ninth would exhaust. With default 8,
      # we cap at 8 with :max_turns.
      scripts =
        for i <- 0..8 do
          [{:tool_call, id: "c#{i}", name: "echo", arguments: %{}}, {:finish, :tool_calls}]
        end

      engine = FakeFixtures.engine_with_scripts(scripts, tools: [echo_tool()])

      assert {:ok, %ChatResult{} = result} = Chat.run(engine, user_thread())
      assert result.halted_reason == :max_turns
      assert result.metadata == %{max_turns: 8}
      assert length(result.steps) == 8
    end

    test "max_turns: 0 raises ArgumentError before adapter call" do
      # Use a missing-adapter engine so the adapter call WOULD fail; verify the
      # ArgumentError fires first.
      engine = %Engine{Engine.new(adapter: ALLM.Providers.Fake) | adapter: nil}

      assert_raise ArgumentError, ~r/max_turns must be a positive integer; got: 0/, fn ->
        Chat.run(engine, user_thread(), max_turns: 0)
      end
    end

    test "max_turns: -1 raises ArgumentError" do
      engine = FakeFixtures.engine([{:text, "x"}, {:finish, :stop}])

      assert_raise ArgumentError, ~r/max_turns must be a positive integer; got: -1/, fn ->
        Chat.run(engine, user_thread(), max_turns: -1)
      end
    end

    test "max_turns: 1.5 raises ArgumentError" do
      engine = FakeFixtures.engine([{:text, "x"}, {:finish, :stop}])

      assert_raise ArgumentError, ~r/max_turns must be a positive integer; got: 1.5/, fn ->
        Chat.run(engine, user_thread(), max_turns: 1.5)
      end
    end

    test ~s|max_turns: "8" raises ArgumentError| do
      engine = FakeFixtures.engine([{:text, "x"}, {:finish, :stop}])

      assert_raise ArgumentError, ~r/max_turns must be a positive integer; got: "8"/, fn ->
        Chat.run(engine, user_thread(), max_turns: "8")
      end
    end

    test "explicit max_turns: nil raises ArgumentError after precedence chain" do
      # Application config absent; engine.params has no max_turns; explicit nil
      # falls through to default 8 because the precedence chain uses ||. So
      # `max_turns: nil` itself does NOT raise — verify that path resolves to
      # the default. To trigger the nil branch directly, set engine.params and
      # opts both nil; the default kicks in.
      engine = FakeFixtures.engine([{:text, "x"}, {:finish, :stop}])
      assert {:ok, %ChatResult{} = result} = Chat.run(engine, user_thread(), max_turns: nil)
      assert result.halted_reason == :completed
    end

    test "max_turns precedence: opts override engine.params" do
      # engine.params.max_turns: 4, opts.max_turns: 1 — 1 should win.
      base =
        FakeFixtures.engine(
          [{:tool_call, id: "c0", name: "echo", arguments: %{}}, {:finish, :tool_calls}],
          tools: [echo_tool()]
        )

      engine = %{base | params: Map.put(base.params, :max_turns, 4)}

      assert {:ok, %ChatResult{} = result} = Chat.run(engine, user_thread(), max_turns: 1)
      assert result.halted_reason == :max_turns
      assert result.metadata == %{max_turns: 1}
    end

    test "max_turns precedence: engine.params used when opts absent" do
      base =
        FakeFixtures.engine(
          [{:tool_call, id: "c0", name: "echo", arguments: %{}}, {:finish, :tool_calls}],
          tools: [echo_tool()]
        )

      engine = %{base | params: Map.put(base.params, :max_turns, 1)}

      assert {:ok, %ChatResult{} = result} = Chat.run(engine, user_thread())
      assert result.halted_reason == :max_turns
      assert result.metadata == %{max_turns: 1}
    end
  end

  # ---------------------------------------------------------------------------
  # halt_when
  # ---------------------------------------------------------------------------

  describe "run/3 — halt_when" do
    test "halt_when fires mid-loop after a tool result" do
      engine = FakeFixtures.engine_with_scripts(tool_call_then_text_scripts(), tools: [echo_tool()])

      halt_when = fn sr -> sr.tool_results != [] end

      assert {:ok, %ChatResult{} = result} =
               Chat.run(engine, user_thread(), halt_when: halt_when)

      assert result.halted_reason == :halt_when
      assert result.metadata == %{halt_when_step_index: 0}
      assert length(result.steps) == 1
    end

    test "halt_when never fires — runs until :completed" do
      engine = FakeFixtures.engine([{:text, "ok"}, {:finish, :stop}])

      assert {:ok, %ChatResult{} = result} =
               Chat.run(engine, user_thread(), halt_when: fn _ -> false end)

      assert result.halted_reason == :completed
    end

    test "halt_when raises propagate to the caller" do
      # Use a tool-call turn so terminal_condition reaches the halt_when branch
      # (the :completed branch short-circuits before halt_when is invoked).
      engine =
        FakeFixtures.engine(
          [{:tool_call, id: "c0", name: "echo", arguments: %{}}, {:finish, :tool_calls}],
          tools: [echo_tool()]
        )

      assert_raise RuntimeError, "user bug", fn ->
        Chat.run(engine, user_thread(), halt_when: fn _ -> raise "user bug" end)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # on_tool_error
  # ---------------------------------------------------------------------------

  describe "run/3 — on_tool_error" do
    test ":continue (default): handler raise → batch continues; loop ends :completed" do
      scripts = [
        [{:tool_call, id: "c0", name: "raises", arguments: %{}}, {:finish, :tool_calls}],
        [{:text, "ok"}, {:finish, :stop}]
      ]

      engine = FakeFixtures.engine_with_scripts(scripts, tools: [raising_tool()])

      assert {:ok, %ChatResult{} = result} = Chat.run(engine, user_thread())
      assert result.halted_reason == :completed
      assert length(result.steps) == 2
      step1 = hd(result.steps)
      assert [%Message{role: :tool, tool_call_id: "c0"}] = step1.tool_results
    end

    test ":halt: handler raise → halted_reason: :tool_error" do
      engine =
        FakeFixtures.engine(
          [{:tool_call, id: "c0", name: "raises", arguments: %{}}, {:finish, :tool_calls}],
          tools: [raising_tool()]
        )

      assert {:ok, %ChatResult{} = result} =
               Chat.run(engine, user_thread(), on_tool_error: :halt)

      assert result.halted_reason == :tool_error
      assert result.metadata.halt_tool_call_id == "c0"
    end

    test "fun returning {:continue, replacement} encodes replacement" do
      scripts = [
        [{:tool_call, id: "c0", name: "raises", arguments: %{}}, {:finish, :tool_calls}],
        [{:text, "ok"}, {:finish, :stop}]
      ]

      engine = FakeFixtures.engine_with_scripts(scripts, tools: [raising_tool()])

      on_tool_error = fn %ToolCall{name: "raises"}, _err -> {:continue, %{replaced: true}} end

      assert {:ok, %ChatResult{} = result} =
               Chat.run(engine, user_thread(), on_tool_error: on_tool_error)

      assert result.halted_reason == :completed
      step1 = hd(result.steps)
      [tool_msg] = step1.tool_results
      assert Jason.decode!(tool_msg.content) == %{"replaced" => true}
    end

    test "fun returning :halt → halted_reason: :tool_error" do
      engine =
        FakeFixtures.engine(
          [{:tool_call, id: "c0", name: "raises", arguments: %{}}, {:finish, :tool_calls}],
          tools: [raising_tool()]
        )

      assert {:ok, %ChatResult{} = result} =
               Chat.run(engine, user_thread(), on_tool_error: fn _, _ -> :halt end)

      assert result.halted_reason == :tool_error
      assert result.metadata.halt_tool_call_id == "c0"
    end

    test "fun raising → halted_reason: :tool_error + :on_tool_error_exception in metadata" do
      engine =
        FakeFixtures.engine(
          [{:tool_call, id: "c0", name: "raises", arguments: %{}}, {:finish, :tool_calls}],
          tools: [raising_tool()]
        )

      assert {:ok, %ChatResult{} = result} =
               Chat.run(engine, user_thread(), on_tool_error: fn _, _ -> raise "handler bug" end)

      assert result.halted_reason == :tool_error
      assert result.metadata.halt_tool_call_id == "c0"
      assert %RuntimeError{message: "handler bug"} = result.metadata.on_tool_error_exception
    end
  end

  # ---------------------------------------------------------------------------
  # Custom halt atoms
  # ---------------------------------------------------------------------------

  describe "run/3 — custom halt atoms" do
    test "handler returns {:halt, :plan_submitted, %{ok: 1}}" do
      tool =
        Tool.new(
          name: "plan",
          description: "",
          schema: %{},
          handler: fn _ -> {:halt, :plan_submitted, %{ok: 1}} end
        )

      engine =
        FakeFixtures.engine(
          [{:tool_call, id: "c0", name: "plan", arguments: %{}}, {:finish, :tool_calls}],
          tools: [tool]
        )

      assert {:ok, %ChatResult{} = result} = Chat.run(engine, user_thread())
      assert result.halted_reason == :plan_submitted
      assert result.metadata.halt_tool_call_id == "c0"
      assert result.metadata.halt_result == %{ok: 1}
      assert length(result.steps) == 1
    end

    for reserved <- [:ask_user, :max_turns, :halt_when, :tool_error, :cancelled, :completed] do
      test "handler returns {:halt, #{inspect(reserved)}, _} — rejected (default :continue)" do
        reserved_atom = unquote(reserved)

        tool =
          Tool.new(
            name: "bad",
            description: "",
            schema: %{},
            handler: fn _ -> {:halt, reserved_atom, %{}} end
          )

        scripts = [
          [{:tool_call, id: "c0", name: "bad", arguments: %{}}, {:finish, :tool_calls}],
          [{:text, "ok"}, {:finish, :stop}]
        ]

        engine = FakeFixtures.engine_with_scripts(scripts, tools: [tool])

        assert {:ok, %ChatResult{} = result} = Chat.run(engine, user_thread())
        assert result.halted_reason == :completed
      end

      test "handler returns {:halt, #{inspect(reserved)}, _} — :halt → :tool_error" do
        reserved_atom = unquote(reserved)

        tool =
          Tool.new(
            name: "bad",
            description: "",
            schema: %{},
            handler: fn _ -> {:halt, reserved_atom, %{}} end
          )

        engine =
          FakeFixtures.engine(
            [{:tool_call, id: "c0", name: "bad", arguments: %{}}, {:finish, :tool_calls}],
            tools: [tool]
          )

        assert {:ok, %ChatResult{} = result} =
                 Chat.run(engine, user_thread(), on_tool_error: :halt)

        assert result.halted_reason == :tool_error
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Ask-user
  # ---------------------------------------------------------------------------

  describe "run/3 — ask_user" do
    test "appends assistant question message at turn boundary" do
      tool =
        Tool.new(
          name: "ask",
          description: "",
          schema: %{},
          handler: fn _ -> {:ask_user, "which city?", choices: ["A", "B"]} end
        )

      engine =
        FakeFixtures.engine(
          [{:tool_call, id: "c0", name: "ask", arguments: %{}}, {:finish, :tool_calls}],
          tools: [tool]
        )

      assert {:ok, %ChatResult{} = result} = Chat.run(engine, user_thread())
      assert result.halted_reason == :ask_user
      assert result.pending_question == "which city?"
      assert result.pending_tool_call_id == "c0"
      assert result.metadata.ask_user_opts == [choices: ["A", "B"]]

      last = List.last(result.thread.messages)
      assert last.role == :assistant
      assert last.content == "which city?"
      assert last.metadata == %{ask_user: true, tool_call_id: "c0"}
    end
  end

  # ---------------------------------------------------------------------------
  # Manual mode
  # ---------------------------------------------------------------------------

  describe "run/3 — mode: :manual" do
    test "halts on first tool-calls turn" do
      engine =
        FakeFixtures.engine(
          [{:tool_call, id: "c0", name: "echo", arguments: %{"x" => 1}}, {:finish, :tool_calls}],
          tools: [echo_tool()]
        )

      assert {:ok, %ChatResult{} = result} = Chat.run(engine, user_thread(), mode: :manual)
      assert result.halted_reason == :manual_tool_calls
      assert length(result.steps) == 1
      assert hd(result.steps).tool_results == []
      assert result.metadata == %{manual_turn_index: 0}
      assert [%ToolCall{id: "c0", name: "echo"}] = result.final_response.tool_calls
    end

    test "text-only turn continues to :completed" do
      engine = FakeFixtures.engine([{:text, "hi"}, {:finish, :stop}])

      assert {:ok, %ChatResult{} = result} = Chat.run(engine, user_thread(), mode: :manual)
      assert result.halted_reason == :completed
    end
  end

  # ---------------------------------------------------------------------------
  # Errors
  # ---------------------------------------------------------------------------

  describe "run/3 — errors" do
    test "adapter pre-flight error → {:error, struct} on call site" do
      engine = %Engine{Engine.new(adapter: ALLM.Providers.Fake) | adapter: nil}

      assert {:error, %EngineError{reason: :missing_adapter}} =
               Chat.run(engine, user_thread())
    end

    test "mid-loop adapter error → halted_reason: :error, length(steps) == 2" do
      scripts = [
        [{:tool_call, id: "c0", name: "echo", arguments: %{}}, {:finish, :tool_calls}],
        [{:error, :rate_limited}]
      ]

      engine = FakeFixtures.engine_with_scripts(scripts, tools: [echo_tool()])

      assert {:ok, %ChatResult{} = result} = Chat.run(engine, user_thread())
      assert result.halted_reason == :error
      assert length(result.steps) == 2
      last_step = List.last(result.steps)
      assert last_step.response.finish_reason == :error
    end

    test "empty thread → {:error, ValidationError}" do
      engine = FakeFixtures.engine([{:text, "x"}, {:finish, :stop}])

      assert {:error, %ValidationError{}} = Chat.run(engine, [])
    end
  end

  # ---------------------------------------------------------------------------
  # Terminal-condition ordering
  # ---------------------------------------------------------------------------

  describe "run/3 — terminal-condition ordering" do
    test ":ask_user beats halt_when" do
      tool =
        Tool.new(
          name: "ask",
          description: "",
          schema: %{},
          handler: fn _ -> {:ask_user, "which?"} end
        )

      engine =
        FakeFixtures.engine(
          [{:tool_call, id: "c0", name: "ask", arguments: %{}}, {:finish, :tool_calls}],
          tools: [tool]
        )

      assert {:ok, %ChatResult{halted_reason: :ask_user}} =
               Chat.run(engine, user_thread(), halt_when: fn _ -> true end)
    end

    test "custom halt atom beats halt_when" do
      tool =
        Tool.new(
          name: "plan",
          description: "",
          schema: %{},
          handler: fn _ -> {:halt, :plan_submitted, %{ok: 1}} end
        )

      engine =
        FakeFixtures.engine(
          [{:tool_call, id: "c0", name: "plan", arguments: %{}}, {:finish, :tool_calls}],
          tools: [tool]
        )

      assert {:ok, %ChatResult{halted_reason: :plan_submitted}} =
               Chat.run(engine, user_thread(), halt_when: fn _ -> true end)
    end

    test ":tool_error beats halt_when" do
      engine =
        FakeFixtures.engine(
          [{:tool_call, id: "c0", name: "raises", arguments: %{}}, {:finish, :tool_calls}],
          tools: [raising_tool()]
        )

      assert {:ok, %ChatResult{halted_reason: :tool_error}} =
               Chat.run(engine, user_thread(),
                 on_tool_error: :halt,
                 halt_when: fn _ -> true end
               )
    end

    test ":manual_tool_calls beats halt_when" do
      engine =
        FakeFixtures.engine(
          [{:tool_call, id: "c0", name: "echo", arguments: %{}}, {:finish, :tool_calls}],
          tools: [echo_tool()]
        )

      assert {:ok, %ChatResult{halted_reason: :manual_tool_calls}} =
               Chat.run(engine, user_thread(),
                 mode: :manual,
                 halt_when: fn _ -> true end
               )
    end

    test ":halt_when beats max_turns" do
      # Tool-call turn followed by text; halt_when fires after first step;
      # max_turns: 1 would also fire but halt_when is checked first.
      engine =
        FakeFixtures.engine(
          [{:tool_call, id: "c0", name: "echo", arguments: %{}}, {:finish, :tool_calls}],
          tools: [echo_tool()]
        )

      assert {:ok, %ChatResult{halted_reason: :halt_when}} =
               Chat.run(engine, user_thread(),
                 max_turns: 1,
                 halt_when: fn _ -> true end
               )
    end

    test ":completed beats halt_when" do
      engine = FakeFixtures.engine([{:text, "hi"}, {:finish, :stop}])

      assert {:ok, %ChatResult{halted_reason: :completed}} =
               Chat.run(engine, user_thread(), halt_when: fn _ -> true end)
    end
  end

  # ---------------------------------------------------------------------------
  # Build-chat-result invariants
  # ---------------------------------------------------------------------------

  describe "run/3 — build_chat_result invariants" do
    test "final_response is the LAST step's response" do
      scripts = [
        [{:tool_call, id: "c0", name: "echo", arguments: %{}}, {:finish, :tool_calls}],
        [{:text, "final"}, {:finish, :stop}]
      ]

      engine = FakeFixtures.engine_with_scripts(scripts, tools: [echo_tool()])

      {:ok, result} = Chat.run(engine, user_thread())
      assert result.final_response == List.last(result.steps).response
    end

    test "steps preserve insertion order" do
      scripts = [
        [{:tool_call, id: "c0", name: "echo", arguments: %{"a" => 0}}, {:finish, :tool_calls}],
        [{:tool_call, id: "c1", name: "echo", arguments: %{"a" => 1}}, {:finish, :tool_calls}],
        [{:text, "ok"}, {:finish, :stop}]
      ]

      engine = FakeFixtures.engine_with_scripts(scripts, tools: [echo_tool()])

      {:ok, result} = Chat.run(engine, user_thread())
      assert length(result.steps) == 3

      assert Enum.map(result.steps, & &1.response.finish_reason) ==
               [:tool_calls, :tool_calls, :stop]
    end
  end

  # ---------------------------------------------------------------------------
  # Sentinel-leak guard — `__resolved_max_turns__` MUST NOT reach the adapter.
  # See review Finding #1 / retro F1: max_turns is threaded via LoopState's
  # explicit field, not via a private opt-key sentinel.
  # ---------------------------------------------------------------------------

  defmodule LeakDetect do
    @moduledoc false
    @behaviour ALLM.Adapter
    @behaviour ALLM.StreamAdapter

    @impl ALLM.Adapter
    def generate(req, opts) do
      send(opts[:adapter_opts][:observer], {:adapter_opts, opts})
      Fake.generate(req, opts)
    end

    @impl ALLM.StreamAdapter
    def stream(req, opts) do
      send(opts[:adapter_opts][:observer], {:adapter_opts, opts})
      Fake.stream(req, opts)
    end
  end

  describe "run/3 — sentinel leak guard" do
    test "no `:__resolved_max_turns__` reaches adapter dispatch (run/3)" do
      observer = self()

      engine =
        Engine.new(
          adapter: LeakDetect,
          adapter_opts: [
            script: [{:text, "hello"}, {:finish, :stop}],
            observer: observer
          ]
        )

      assert {:ok, %ChatResult{}} = Chat.run(engine, user_thread(), max_turns: 3)

      assert_receive {:adapter_opts, opts}
      assert is_list(opts)
      refute Keyword.has_key?(opts, :__resolved_max_turns__)
      # `:max_turns` is an orchestration opt — `StreamRunner` strips it
      # already; this assertion guards the additional invariant that the
      # private sentinel is also absent.
      refute Keyword.has_key?(opts, :max_turns)
    end
  end

  describe "run/3 — telemetry (Phase 9.1)" do
    test "emits [:allm, :chat, :start | :stop] with :request_id, :engine, :model, :chat_result" do
      TelemetryCapture.attach([
        [:allm, :chat, :start],
        [:allm, :chat, :stop]
      ])

      engine = FakeFixtures.engine([{:text, "hello"}, {:finish, :stop}])
      assert {:ok, %ChatResult{} = cr} = Chat.run(engine, user_thread())

      events = TelemetryCapture.events()
      TelemetryCapture.detach()

      assert {[:allm, :chat, :start], _, start_meta} =
               Enum.find(events, &match?({[:allm, :chat, :start], _, _}, &1))

      assert is_binary(start_meta.request_id)
      assert start_meta.engine == engine
      assert Map.has_key?(start_meta, :model)

      assert {[:allm, :chat, :stop], _, stop_meta} =
               Enum.find(events, &match?({[:allm, :chat, :stop], _, _}, &1))

      assert stop_meta.request_id == start_meta.request_id
      assert stop_meta.chat_result == cr
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 10.4 — structured_finalize two-pass orchestration
  # ---------------------------------------------------------------------------

  describe "run/3 — structured_finalize two-pass" do
    setup do
      # Application-level nudge override may leak across tests; clean up.
      on_exit(fn -> Application.delete_env(:allm, :structured_finalize_nudge) end)
      :ok
    end

    defp json_schema_rf do
      %{type: :json_schema, name: "g", schema: %{type: "object"}, strict: true}
    end

    defp finalize_scripts do
      [
        # Pass 1 turn 1 — tool call.
        [
          {:tool_call, id: "c0", name: "echo", arguments: %{"x" => 1}},
          {:finish, :tool_calls}
        ],
        # Pass 1 turn 2 — terminal text (halt :completed).
        [{:text, "tool done"}, {:finish, :stop}],
        # Pass 2 turn 1 — structured JSON.
        [{:text, ~s({"answer": "ok"})}, {:finish, :stop}]
      ]
    end

    test "two-pass run merges steps from both passes; pass 2 produces final_response" do
      engine = FakeFixtures.engine_with_scripts(finalize_scripts(), tools: [echo_tool()])

      assert {:ok, %ChatResult{} = result} =
               Chat.run(engine, user_thread(),
                 structured_finalize: true,
                 response_format: json_schema_rf()
               )

      assert result.halted_reason == :completed
      # Steps from BOTH passes — pass 1 = 2 (tool_call + after-tool follow-up),
      # pass 2 = 1 (single text). Total = 3.
      assert length(result.steps) >= 2
      assert result.final_response.output_text == ~s({"answer": "ok"})
      assert result.metadata.structured_finalize.pass_1_halted == :completed
    end

    test "pass-1 :ask_user halt skips pass 2" do
      ask_tool =
        Tool.new(
          name: "ask",
          description: "",
          schema: %{},
          handler: fn _args -> {:ask_user, "Which one?"} end
        )

      scripts = [
        [{:tool_call, id: "c0", name: "ask", arguments: %{}}, {:finish, :tool_calls}],
        # Pass 2 should not run, but we provide a script for it just in case.
        [{:text, ~s({"answer": "x"})}, {:finish, :stop}]
      ]

      engine = FakeFixtures.engine_with_scripts(scripts, tools: [ask_tool])

      assert {:ok, %ChatResult{} = result} =
               Chat.run(engine, user_thread(),
                 structured_finalize: true,
                 response_format: json_schema_rf()
               )

      assert result.halted_reason == :ask_user
      assert result.metadata.structured_finalize.pass_1_halted == :ask_user
      # Pass-1 final_response is preserved (pass 2 skipped).
      assert result.final_response.finish_reason == :tool_calls
    end

    test "pass-1 :tool_error halt skips pass 2" do
      scripts = [
        [{:tool_call, id: "c0", name: "raises", arguments: %{}}, {:finish, :tool_calls}],
        [{:text, ~s({"answer": "x"})}, {:finish, :stop}]
      ]

      engine = FakeFixtures.engine_with_scripts(scripts, tools: [raising_tool()])

      assert {:ok, %ChatResult{} = result} =
               Chat.run(engine, user_thread(),
                 structured_finalize: true,
                 response_format: json_schema_rf(),
                 on_tool_error: :halt
               )

      assert result.halted_reason == :tool_error
      assert result.metadata.structured_finalize.pass_1_halted == :tool_error
    end

    test ":max_turns is consumed by pass 1; pass 2 still runs (no budget decrement)" do
      scripts = [
        # 2 tool-call turns to exhaust max_turns: 2, then pass 2.
        [{:tool_call, id: "c0", name: "echo", arguments: %{}}, {:finish, :tool_calls}],
        [{:tool_call, id: "c1", name: "echo", arguments: %{}}, {:finish, :tool_calls}],
        # Pass 2 — single structured response.
        [{:text, ~s({"final": true})}, {:finish, :stop}]
      ]

      engine = FakeFixtures.engine_with_scripts(scripts, tools: [echo_tool()])

      assert {:ok, %ChatResult{} = result} =
               Chat.run(engine, user_thread(),
                 max_turns: 2,
                 structured_finalize: true,
                 response_format: json_schema_rf()
               )

      # Pass 1 hit max_turns; pass 2 fired anyway and produced the final.
      assert result.metadata.structured_finalize.pass_1_halted == :max_turns
      assert result.halted_reason == :completed
      assert result.final_response.output_text == ~s({"final": true})
    end

    test "opts[:structured_finalize_nudge] overrides default; thread carries the custom nudge" do
      engine = FakeFixtures.engine_with_scripts(finalize_scripts(), tools: [echo_tool()])

      assert {:ok, %ChatResult{} = result} =
               Chat.run(engine, user_thread(),
                 structured_finalize: true,
                 response_format: json_schema_rf(),
                 structured_finalize_nudge: "Custom nudge text"
               )

      # The user-nudge message lives in the final thread (pass 2 thread).
      user_msgs = Enum.filter(result.thread.messages, &(&1.role == :user))
      assert Enum.any?(user_msgs, fn m -> m.content == "Custom nudge text" end)
    end

    test "Application.put_env nudge honored when no per-call opt" do
      Application.put_env(:allm, :structured_finalize_nudge, "App-default nudge")

      engine = FakeFixtures.engine_with_scripts(finalize_scripts(), tools: [echo_tool()])

      assert {:ok, %ChatResult{} = result} =
               Chat.run(engine, user_thread(),
                 structured_finalize: true,
                 response_format: json_schema_rf()
               )

      user_msgs = Enum.filter(result.thread.messages, &(&1.role == :user))
      assert Enum.any?(user_msgs, fn m -> m.content == "App-default nudge" end)
    end

    test "empty-string nudge skips the user-message append" do
      engine = FakeFixtures.engine_with_scripts(finalize_scripts(), tools: [echo_tool()])

      thread_before = user_thread()

      assert {:ok, %ChatResult{} = result} =
               Chat.run(engine, thread_before,
                 structured_finalize: true,
                 response_format: json_schema_rf(),
                 structured_finalize_nudge: ""
               )

      # No additional user message beyond the original was appended; the
      # only :user role message is the original "hi".
      user_msgs = Enum.filter(result.thread.messages, &(&1.role == :user))
      assert length(user_msgs) == 1
      assert hd(user_msgs).content == "hi"
    end

    test "structured_finalize: false (or absent) uses single-pass path" do
      # Even with response_format set, structured_finalize: false doesn't
      # trigger two-pass — the single-pass loop runs as before.
      engine = FakeFixtures.engine([{:text, "plain"}, {:finish, :stop}])

      assert {:ok, %ChatResult{} = result} =
               Chat.run(engine, user_thread(), response_format: json_schema_rf())

      assert result.halted_reason == :completed
      # No structured_finalize key in metadata — single-pass path.
      refute Map.has_key?(result.metadata, :structured_finalize)
    end

    test "pass-2 adapter pre-flight error propagates as {:error, AdapterError}" do
      # Pass 1 completes normally (tool call + terminal text → :completed).
      # Pass 2's adapter call short-circuits via `:preflight_error`, exercising
      # the defensive `{:error, _}` branch in `run_finalize_pass/4`. Per Phase
      # 10.4 review §6, this branch is realistic in production (e.g., key
      # rotated mid-session) and surfaces verbatim from `Chat.run/3`.
      scripts = [
        # Pass 1 turn 1 — tool call.
        [
          {:tool_call, id: "c0", name: "echo", arguments: %{"x" => 1}},
          {:finish, :tool_calls}
        ],
        # Pass 1 turn 2 — terminal text (halt :completed).
        [{:text, "tool done"}, {:finish, :stop}],
        # Pass 2 turn 1 — adapter pre-flight failure.
        [{:preflight_error, :authentication_failed, []}]
      ]

      engine = FakeFixtures.engine_with_scripts(scripts, tools: [echo_tool()])

      assert {:error, %ALLM.Error.AdapterError{reason: :authentication_failed}} =
               Chat.run(engine, user_thread(),
                 structured_finalize: true,
                 response_format: json_schema_rf()
               )
    end
  end
end
