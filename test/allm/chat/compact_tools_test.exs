defmodule ALLM.Chat.CompactToolsTest do
  @moduledoc """
  Compact tool disclosure wired into the chat loop (Layer C).

  Every row runs on BOTH arms: `ALLM.chat/3` (non-streaming) and
  `ALLM.stream/3` folded through `ALLM.StreamCollector` (streaming). The
  request each step sends is captured through `ALLM.Providers.Fake`'s
  `:record` adapter option, which sends `{:allm_fake_record, request, opts}`
  to the test process.

  The wire list is `ALLM.ToolHelp.project/2` of the resolved tools; every
  execution site sees the full resolved tools plus `ALLM.ToolHelp.meta_tool/0`.
  """

  use ExUnit.Case, async: true

  alias ALLM.{
    ChatResult,
    Engine,
    Message,
    Request,
    Session,
    StreamCollector,
    Thread,
    Tool,
    ToolCall,
    ToolHelp
  }

  alias ALLM.Error.ValidationError
  alias ALLM.Session.StreamReducer
  alias ALLM.Test.FakeFixtures

  @arms [:chat, :stream]

  defmodule RaisingExecutor do
    @moduledoc false
    @behaviour ALLM.ToolExecutor

    @impl true
    def execute(%ALLM.Tool{}, _args, _opts), do: raise("custom executor must not be reached")
  end

  # ---------------------------------------------------------------------------
  # Tools
  # ---------------------------------------------------------------------------

  defp x_tool(me, extra \\ []) do
    Tool.new(
      [
        name: "x",
        description: "Do the x thing. It has a long explanation that only tool_help shows.",
        schema: %{
          "type" => "object",
          "properties" => %{"a" => %{"type" => "string"}, "b" => %{"type" => "integer"}},
          "required" => ["a"]
        },
        handler: fn args ->
          send(me, {:x_ran, args})
          {:ok, "x done"}
        end,
        compact: true
      ] ++ extra
    )
  end

  defp y_tool do
    Tool.new(
      name: "y",
      description: "Do the y thing. Also long.",
      schema: %{
        "type" => "object",
        "properties" => %{"q" => %{"type" => "string"}},
        "required" => ["q"]
      },
      handler: fn _ -> {:ok, "y done"} end,
      compact: true
    )
  end

  defp full_tool do
    Tool.new(
      name: "full",
      description: "A full tool.",
      schema: %{"type" => "object", "properties" => %{"n" => %{"type" => "integer"}}},
      handler: fn _ -> {:ok, "full done"} end
    )
  end

  @valid_x_args %{"a" => "hello", "b" => 2}
  @bad_x_args %{"b" => 2}

  defp help_call(id \\ "h0", names \\ ["x"]),
    do: {:tool_call, id: id, name: "tool_help", arguments: %{"names" => names}}

  defp x_call(id, args), do: {:tool_call, id: id, name: "x", arguments: args}

  defp text(t \\ "done"), do: [{:text, t}, {:finish, :stop}]

  defp calls(entries), do: entries ++ [{:finish, :tool_calls}]

  # ---------------------------------------------------------------------------
  # Harness
  # ---------------------------------------------------------------------------

  defp engine(scripts, tools, engine_opts \\ []) do
    FakeFixtures.engine_with_scripts(scripts,
      tools: tools,
      adapter_opts: [record: self()],
      engine_opts: engine_opts
    )
  end

  defp user_thread, do: Thread.from_messages([ALLM.user("hi")])

  defp run(:chat, %Engine{} = engine, opts), do: ALLM.chat(engine, user_thread(), opts)

  defp run(:stream, %Engine{} = engine, opts) do
    thread = user_thread()

    case ALLM.stream(engine, thread, opts) do
      {:ok, stream} ->
        {:ok,
         stream
         |> Enum.reduce(StreamCollector.new(thread), &StreamCollector.apply_event(&2, &1))
         |> StreamCollector.to_chat_result()}

      {:error, _} = err ->
        err
    end
  end

  # Drain every request the Fake adapter recorded, in call order.
  defp recorded_requests(acc \\ []) do
    receive do
      {:allm_fake_record, %Request{} = req, _opts} -> recorded_requests([req | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp drain_x_runs(acc \\ []) do
    receive do
      {:x_ran, args} -> drain_x_runs([args | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp tool_message(%ChatResult{thread: thread}, id) do
    Enum.find(thread.messages, &match?(%Message{role: :tool, tool_call_id: ^id}, &1))
  end

  # ---------------------------------------------------------------------------
  # Row 1 — no compact tools: the wire list is the resolved list (Invariant 3)
  # ---------------------------------------------------------------------------

  describe "row 1: no compact tools" do
    test "request.tools == resolved tools, and no tool_help is added" do
      for arm <- @arms do
        engine = engine([text()], [full_tool()])
        assert {:ok, %ChatResult{halted_reason: :completed}} = run(arm, engine, [])

        assert [req] = recorded_requests()
        assert req.tools == Engine.resolve_tools(engine, []), "arm #{arm}"
        refute Enum.any?(req.tools, &(&1.name == "tool_help")), "arm #{arm}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Row 2 — wire list is project/2 of the resolved list (Invariant 1)
  # ---------------------------------------------------------------------------

  describe "row 2: two compact tools and one full tool" do
    test "request.tools == ToolHelp.project/2 of the resolved list" do
      for arm <- @arms do
        tools = [x_tool(self()), full_tool(), y_tool()]
        engine = engine([text()], tools)
        assert {:ok, %ChatResult{halted_reason: :completed}} = run(arm, engine, [])

        assert [req] = recorded_requests()
        assert req.tools == ToolHelp.project(Engine.resolve_tools(engine, []), nil), "arm #{arm}"
        assert Enum.map(req.tools, & &1.name) == ["x", "full", "y", "tool_help"]
        assert Enum.find(req.tools, &(&1.name == "x")).schema == %{"type" => "object"}
        assert Enum.find(req.tools, &(&1.name == "full")) == full_tool()
      end
    end

    test "the wire and execution lists name the same tools (Invariant 1)" do
      tools = [x_tool(self()), full_tool(), y_tool()]
      wire = ToolHelp.project(tools, nil)
      execution = ToolHelp.with_meta_tool(tools)

      assert Enum.map(wire, & &1.name) == Enum.map(execution, & &1.name)
    end
  end

  # ---------------------------------------------------------------------------
  # Row 3 — tool_help round trip, then the stub is called
  # ---------------------------------------------------------------------------

  describe "row 3: tool_help → x(valid) → text" do
    test "tool_help content is render/2 output; x's handler got the args; the run completes" do
      for arm <- @arms do
        tools = [x_tool(self()), y_tool()]

        scripts = [calls([help_call()]), calls([x_call("c1", @valid_x_args)]), text()]
        engine = engine(scripts, tools)

        assert {:ok, %ChatResult{halted_reason: :completed} = cr} = run(arm, engine, [])

        expected = ToolHelp.render(ToolHelp.with_meta_tool(tools), %{"names" => ["x"]})
        assert tool_message(cr, "h0").content == expected, "arm #{arm}"
        assert expected =~ "It has a long explanation that only tool_help shows."
        assert drain_x_runs() == [@valid_x_args], "arm #{arm}"
        assert cr.final_response.output_text == "done"
        _ = recorded_requests()
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Rows 4, 5 — required-argument usage error, routed through on_tool_error
  # ---------------------------------------------------------------------------

  describe "row 4: compact x called without a required argument" do
    test "the first :tool message is the check_args/2 usage error; the handler ran once" do
      for arm <- @arms do
        x = x_tool(self())

        scripts = [
          calls([x_call("c0", @bad_x_args)]),
          calls([x_call("c1", @valid_x_args)]),
          text()
        ]

        assert {:ok, %ChatResult{halted_reason: :completed} = cr} =
                 run(arm, engine(scripts, [x]), [])

        assert %{"error" => usage} = Jason.decode!(tool_message(cr, "c0").content)
        assert {:error, ^usage} = ToolHelp.check_args(x, @bad_x_args)
        assert usage =~ "missing required argument(s): a"
        assert tool_message(cr, "c1").content == "x done"
        assert drain_x_runs() == [@valid_x_args], "arm #{arm}"
        _ = recorded_requests()
      end
    end
  end

  describe "row 5: row 4 with on_tool_error: :halt" do
    test "halts with :tool_error and the handler never ran" do
      for arm <- @arms do
        scripts = [calls([x_call("c0", @bad_x_args)]), text()]

        assert {:ok, %ChatResult{halted_reason: :tool_error}} =
                 run(arm, engine(scripts, [x_tool(self())]), on_tool_error: :halt)

        assert drain_x_runs() == [], "arm #{arm}"
        _ = recorded_requests()
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Row 6 — cache invariant (Invariant 2)
  # ---------------------------------------------------------------------------

  describe "row 6: 3-step run" do
    test "request.tools is == on every step" do
      for arm <- @arms do
        tools = [x_tool(self()), full_tool(), y_tool()]
        scripts = [calls([help_call()]), calls([x_call("c1", @valid_x_args)]), text()]

        assert {:ok, %ChatResult{halted_reason: :completed}} =
                 run(arm, engine(scripts, tools), [])

        assert [r1, r2, r3] = recorded_requests()
        assert r1.tools == r2.tools, "arm #{arm}"
        assert r2.tools == r3.tools, "arm #{arm}"
        assert Enum.any?(r1.tools, &ToolHelp.meta_tool?/1)
        _ = drain_x_runs()
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Row 7 — tool_choice naming a compact tool sends it in full
  # ---------------------------------------------------------------------------

  @forcing_choices [
    "x",
    {:tool, "x"},
    %{"type" => "tool", "name" => "x"},
    %{type: "tool", name: "x"},
    %{"type" => "function", "function" => %{"name" => "x"}},
    %{"type" => "function", "name" => "x"},
    %{"mode" => "ANY", "allowedFunctionNames" => ["x"]}
  ]

  describe "row 7: tool_choice forcing compact x" do
    test "the wire x is the full tool; the other compact tool is a stub" do
      for arm <- @arms, choice <- @forcing_choices do
        x = x_tool(self())
        y = y_tool()

        assert {:ok, %ChatResult{}} = run(arm, engine([text()], [x, y]), tool_choice: choice)

        assert [req] = recorded_requests()
        label = "arm #{arm}, tool_choice #{inspect(choice)}"
        assert Enum.find(req.tools, &(&1.name == "x")) == x, label
        assert Enum.find(req.tools, &(&1.name == "y")) == ToolHelp.stub(y), label
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Row 8 — a user tool named tool_help beside a compact tool
  # ---------------------------------------------------------------------------

  describe "row 8: user tool named tool_help + a compact tool" do
    test "rejected pre-flight with {:tools, :duplicate_name}" do
      mine =
        Tool.new(
          name: "tool_help",
          description: "mine",
          schema: %{},
          handler: fn _ -> {:ok, "mine"} end
        )

      for arm <- @arms do
        assert {:error, %ValidationError{errors: errors}} =
                 run(arm, engine([text()], [mine, x_tool(self())]), [])

        assert {:tools, :duplicate_name} in errors, "arm #{arm}"
      end
    end

    test "a user tool named tool_help without any compact tool is an ordinary tool" do
      mine =
        Tool.new(
          name: "tool_help",
          description: "mine",
          schema: %{},
          handler: fn _ -> {:ok, "mine"} end
        )

      for arm <- @arms do
        scripts = [calls([help_call()]), text()]

        assert {:ok, %ChatResult{halted_reason: :completed} = cr} =
                 run(arm, engine(scripts, [mine, full_tool()]), [])

        assert tool_message(cr, "h0").content == "mine", "arm #{arm}"
        _ = recorded_requests()
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Row 9 — tool_help bypasses a custom executor
  # ---------------------------------------------------------------------------

  describe "row 9: engine with a raising custom tool_executor" do
    test "a tool_help call still succeeds" do
      for arm <- @arms do
        tools = [x_tool(self())]
        scripts = [calls([help_call()]), text()]

        assert {:ok, %ChatResult{halted_reason: :completed} = cr} =
                 run(arm, engine(scripts, tools, tool_executor: RaisingExecutor), [])

        assert tool_message(cr, "h0").content ==
                 ToolHelp.render(ToolHelp.with_meta_tool(tools), %{"names" => ["x"]}),
               "arm #{arm}"

        _ = recorded_requests()
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Row 10 — per-tool manual: tool_help auto-runs, compact manual x halts
  # ---------------------------------------------------------------------------

  describe "row 10: per-tool manual compact x" do
    test "tool_help auto-runs; the loop halts :manual_tool_calls on x" do
      for arm <- @arms do
        tools = [x_tool(self(), manual: true)]
        scripts = [calls([help_call()]), calls([x_call("c1", @valid_x_args)])]

        assert {:ok, %ChatResult{halted_reason: :manual_tool_calls} = cr} =
                 run(arm, engine(scripts, tools), [])

        assert tool_message(cr, "h0").content =~ "## x", "arm #{arm}"
        assert [%ToolCall{id: "c1", name: "x"}] = cr.metadata.manual_tool_calls
        assert drain_x_runs() == [], "arm #{arm}"
        _ = recorded_requests()
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Row 10b — one assistant turn mixing tool_help, an auto compact tool and a
  # per-tool-manual compact tool. This turn shape is the only one that reaches
  # the mixed-turn execution sites (`run_tools_then_halt/7` non-streaming,
  # `start_phase_b_partial/5` streaming).
  # ---------------------------------------------------------------------------

  describe "row 10b: tool_help + auto compact y + manual compact x in one turn" do
    test "the auto calls run (tool_help answered, y's usage error); the loop halts on x" do
      for arm <- @arms do
        tools = [x_tool(self(), manual: true), y_tool()]

        scripts = [
          calls([
            help_call(),
            {:tool_call, id: "yy", name: "y", arguments: %{}},
            x_call("c1", @valid_x_args)
          ])
        ]

        assert {:ok, %ChatResult{halted_reason: :manual_tool_calls} = cr} =
                 run(arm, engine(scripts, tools), []),
               "arm #{arm}"

        help = tool_message(cr, "h0")
        assert help, "arm #{arm}: tool_help result missing"
        assert help.content =~ "It has a long explanation that only tool_help shows.", "arm #{arm}"

        assert help.content ==
                 ToolHelp.render(ToolHelp.with_meta_tool(tools), %{"names" => ["x"]}),
               "arm #{arm}"

        usage = tool_message(cr, "yy")
        assert usage, "arm #{arm}: y result missing"
        assert usage.content =~ "missing required argument(s): q", "arm #{arm}"

        assert [%ToolCall{id: "c1", name: "x"}] = cr.metadata.manual_tool_calls, "arm #{arm}"
        assert drain_x_runs() == [], "arm #{arm}"
        _ = recorded_requests()
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Row 11 — whole-loop mode: :manual via ALLM.Session
  # ---------------------------------------------------------------------------

  describe "row 11: whole-loop mode: :manual via Session" do
    test "non-streaming: tool_help surfaces as pending; answer/2 is submitted; continue proceeds" do
      tools = [x_tool(self())]
      engine = engine([calls([help_call()]), text("after help")], tools)

      assert {:ok, %Session{} = session, _cr} =
               Session.start(engine, [ALLM.user("hi")], mode: :manual)

      assert session.status == :awaiting_tools
      assert [%ToolCall{name: "tool_help"} = tc] = session.pending_tool_calls

      assert tc.arguments == %{"names" => ["x"]}
      content = ToolHelp.answer(tools ++ [ToolHelp.meta_tool()], tc)
      assert content =~ "It has a long explanation that only tool_help shows."
      assert %Session{} = session = Session.submit_tool_result(session, tc.id, content)

      assert {:ok, %Session{status: :completed}, %ChatResult{} = cr} =
               Session.continue(engine, session, nil, mode: :manual)

      assert cr.final_response.output_text == "after help"
      assert [r1, r2] = recorded_requests()
      assert r1.tools == r2.tools
      # The submitted answer reaches the model on the continue step.
      assert Enum.any?(r2.messages, &(&1.role == :tool and &1.content == content))
      assert drain_x_runs() == []
    end

    test "streaming: stream_start → submit answer/2 → stream_step, folded with StreamReducer" do
      tools = [x_tool(self())]
      engine = engine([calls([help_call()]), text("after help")], tools)
      session = Session.new(thread: user_thread())

      assert {:ok, stream} = Session.stream_start(engine, session, mode: :manual)
      {session, _cr} = fold_session(stream, session, :chat)

      assert session.status == :awaiting_tools
      assert [%ToolCall{name: "tool_help"} = tc] = session.pending_tool_calls

      assert tc.arguments == %{"names" => ["x"]}
      content = ToolHelp.answer(tools ++ [ToolHelp.meta_tool()], tc)
      assert content =~ "It has a long explanation that only tool_help shows."
      assert %Session{} = session = Session.submit_tool_result(session, tc.id, content)

      assert {:ok, stream} = Session.stream_step(engine, session, mode: :manual)
      {session, sr} = fold_session(stream, session, :step)

      assert session.status == :completed
      assert sr.response.output_text == "after help"
      assert [r1, r2] = recorded_requests()
      assert r1.tools == r2.tools
      # The submitted answer reaches the model on the stream_step request.
      assert Enum.any?(r2.messages, &(&1.role == :tool and &1.content == content))
    end
  end

  defp fold_session(stream, session, mode) do
    stream
    |> Enum.reduce(StreamReducer.new(session, mode: mode), &StreamReducer.apply_event(&2, &1))
    |> StreamReducer.finalize()
  end

  # ---------------------------------------------------------------------------
  # Row 12 — on_tool_error as a fun/2 receives the usage text
  # ---------------------------------------------------------------------------

  describe "row 12: on_tool_error fun/2 with a missing required argument" do
    test "the fun receives the binary usage text; returning :halt halts" do
      for arm <- @arms do
        me = self()
        x = x_tool(me)

        on_err = fn tc, reason ->
          send(me, {:on_err, tc.id, reason})
          :halt
        end

        scripts = [calls([x_call("c0", @bad_x_args)]), text()]

        assert {:ok, %ChatResult{halted_reason: :tool_error}} =
                 run(arm, engine(scripts, [x]), on_tool_error: on_err)

        {:error, usage} = ToolHelp.check_args(x, @bad_x_args)
        assert_received {:on_err, "c0", ^usage}
        assert drain_x_runs() == [], "arm #{arm}"
        _ = recorded_requests()
      end
    end

    test "returning {:continue, replacement} feeds the replacement back and continues" do
      for arm <- @arms do
        on_err = fn _tc, reason when is_binary(reason) -> {:continue, "retry with a"} end
        scripts = [calls([x_call("c0", @bad_x_args)]), text()]

        assert {:ok, %ChatResult{halted_reason: :completed} = cr} =
                 run(arm, engine(scripts, [x_tool(self())]), on_tool_error: on_err)

        assert tool_message(cr, "c0").content == "retry with a", "arm #{arm}"
        _ = recorded_requests()
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Row 13 — tool_help results count as tool results for halt_when
  # ---------------------------------------------------------------------------

  describe "row 13: halt_when on a tool_help-only first step" do
    test "halts after the tool_help step" do
      for arm <- @arms do
        scripts = [calls([help_call()]), text()]
        halt_when = fn sr -> sr.tool_results != [] end

        assert {:ok, %ChatResult{halted_reason: :halt_when} = cr} =
                 run(arm, engine(scripts, [x_tool(self())]), halt_when: halt_when)

        assert length(cr.steps) == 1, "arm #{arm}"
        assert [_] = recorded_requests()
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Row 14 — each tool_help round trip uses a turn
  # ---------------------------------------------------------------------------

  describe "row 14: max_turns: 2 with tool_help → x → text" do
    test "halts :max_turns before the text" do
      for arm <- @arms do
        scripts = [calls([help_call()]), calls([x_call("c1", @valid_x_args)]), text()]

        assert {:ok, %ChatResult{halted_reason: :max_turns}} =
                 run(arm, engine(scripts, [x_tool(self())]), max_turns: 2)

        assert length(recorded_requests()) == 2, "arm #{arm}"
        _ = drain_x_runs()
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Row 15 — tool_help and x in parallel in one turn
  # ---------------------------------------------------------------------------

  describe "row 15: one turn calling tool_help and x in parallel" do
    test "both execute in that turn; x ran with the supplied arguments" do
      for arm <- @arms do
        scripts = [calls([help_call(), x_call("c1", @valid_x_args)]), text()]

        assert {:ok, %ChatResult{halted_reason: :completed} = cr} =
                 run(arm, engine(scripts, [x_tool(self())]), [])

        assert [first | _] = cr.steps
        ids = first.tool_results |> Enum.map(& &1.tool_call_id) |> Enum.sort()
        assert ids == ["c1", "h0"], "arm #{arm}"
        assert tool_message(cr, "h0").content =~ "## x"
        assert tool_message(cr, "c1").content == "x done"
        assert drain_x_runs() == [@valid_x_args], "arm #{arm}"
        assert length(recorded_requests()) == 2
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Row 16 — structured_finalize pass 2 sends no tools
  # ---------------------------------------------------------------------------

  describe "row 16: structured_finalize with compact tools on the engine" do
    test "pass 2's request.tools == []; no tool_help on pass 2" do
      rf = %{type: :json_schema, name: "g", schema: %{type: "object"}, strict: true}

      for arm <- @arms do
        tools = [x_tool(self()), y_tool()]
        scripts = [text("pass one"), text(~s({"answer": "ok"}))]

        assert {:ok, %ChatResult{halted_reason: :completed}} =
                 run(arm, engine(scripts, tools),
                   structured_finalize: true,
                   response_format: rf
                 )

        assert [pass_1, pass_2] = recorded_requests()
        assert pass_1.tools == ToolHelp.project(tools, nil), "arm #{arm}"
        assert pass_2.tools == [], "arm #{arm}"
      end
    end
  end
end
