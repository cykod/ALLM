defmodule ALLM.SessionTest do
  use ExUnit.Case, async: true

  alias ALLM.{ChatResult, Engine, Message, Session, StepResult, Thread, Tool, ToolCall}
  alias ALLM.Error.{EngineError, SessionError, ValidationError}
  alias ALLM.Providers.Fake
  alias ALLM.Test.FakeFixtures

  doctest Session

  defp engine_with_text(text \\ "ok") do
    Engine.new(
      adapter: Fake,
      adapter_opts: [script: [{:text, text}, {:finish, :stop}]]
    )
  end

  defp engine_with_tool_call(name \\ "echo", args \\ %{"x" => 1}) do
    tool = Tool.new(name: name, description: "", schema: %{}, handler: fn a -> {:ok, a} end)

    Engine.new(
      adapter: Fake,
      adapter_opts: [
        script: [
          {:tool_call, id: "call_0", name: name, arguments: args},
          {:finish, :tool_calls}
        ]
      ],
      tools: [tool]
    )
  end

  defp engine_with_error_finish do
    Engine.new(
      adapter: Fake,
      adapter_opts: [script: [{:text, "partial"}, {:error, :rate_limited}]]
    )
  end

  defp assert_round_trip(%Session{} = s) do
    assert s == s |> :erlang.term_to_binary() |> :erlang.binary_to_term()
  end

  # --------------------------------------------------------------------------
  # start/3
  # --------------------------------------------------------------------------

  describe "start/3" do
    test "happy path: returns {:ok, %Session{status: :completed}, %ChatResult{}}" do
      engine = engine_with_text("hello")

      assert {:ok, %Session{status: :completed} = s, %ChatResult{halted_reason: :completed}} =
               Session.start(engine, [ALLM.user("hi")])

      assert s.thread != %Thread{}
      assert_round_trip(s)
    end

    test "accepts a %Thread{} input" do
      engine = engine_with_text()
      thread = Thread.from_messages([ALLM.user("hi")])

      assert {:ok, %Session{status: :completed} = s, %ChatResult{}} =
               Session.start(engine, thread)

      assert_round_trip(s)
    end

    test "accepts a pre-constructed %Session{} preserving :id and :context" do
      engine = engine_with_text()

      seed =
        Session.new(id: "s1", context: %{user: 42}, thread: Thread.from_messages([ALLM.user("hi")]))

      assert {:ok, %Session{id: "s1", context: %{user: 42}} = s, %ChatResult{}} =
               Session.start(engine, seed)

      assert_round_trip(s)
    end

    test "mode: :manual + tool-call script returns :awaiting_tools session" do
      engine = engine_with_tool_call()

      assert {:ok,
              %Session{status: :awaiting_tools, pending_tool_calls: [%ToolCall{id: "call_0"}]} = s,
              %ChatResult{halted_reason: :manual_tool_calls}} =
               Session.start(engine, [ALLM.user("echo please")], mode: :manual)

      assert_round_trip(s)
    end

    test "ask-user fixture returns :awaiting_user session" do
      tool =
        Tool.new(
          name: "ask",
          description: "",
          schema: %{},
          handler: fn _ -> {:ask_user, "Are you sure?"} end
        )

      engine =
        Engine.new(
          adapter: Fake,
          adapter_opts: [
            script: [
              {:tool_call, id: "call_0", name: "ask", arguments: %{}},
              {:finish, :tool_calls}
            ]
          ],
          tools: [tool]
        )

      assert {:ok,
              %Session{
                status: :awaiting_user,
                pending_question: "Are you sure?",
                pending_tool_call_id: "call_0"
              } = s,
              %ChatResult{halted_reason: :ask_user}} =
               Session.start(engine, [ALLM.user("hello")])

      assert_round_trip(s)
    end

    test "finish_reason: :error script projects status: :error and metadata.error" do
      engine = engine_with_error_finish()

      assert {:ok, %Session{status: :error, metadata: %{error: _}} = s,
              %ChatResult{halted_reason: :error}} =
               Session.start(engine, [ALLM.user("hi")])

      assert_round_trip(s)
    end

    test "engine missing :adapter returns {:error, %EngineError{}}" do
      engine = %Engine{}

      assert {:error, %EngineError{reason: :missing_adapter}} =
               Session.start(engine, [ALLM.user("hi")])
    end

    test ":invalid_session_input returns ValidationError" do
      engine = engine_with_text()

      assert {:error, %ValidationError{reason: :invalid_session_input}} =
               Session.start(engine, {:not, "valid"})
    end

    test ":invalid_session_input fires for a list of non-Message terms" do
      engine = engine_with_text()

      assert {:error, %ValidationError{reason: :invalid_session_input}} =
               Session.start(engine, [%{not: :a_message}])
    end
  end

  # --------------------------------------------------------------------------
  # reply/4
  # --------------------------------------------------------------------------

  describe "reply/4" do
    test "appends user message and dispatches" do
      engine =
        Engine.new(
          adapter: Fake,
          adapter_opts: [
            scripts: [
              [{:text, "first"}, {:finish, :stop}],
              [{:text, "second"}, {:finish, :stop}]
            ]
          ]
        )

      {:ok, s, _} = Session.start(engine, [ALLM.user("hi")])
      msg_count_before = length(Session.messages(s))

      assert {:ok, %Session{} = s2, %ChatResult{}} = Session.reply(engine, s, "another")

      assert length(Session.messages(s2)) > msg_count_before
      assert_round_trip(s2)
    end

    test "on :awaiting_user clears pending fields and resumes" do
      tool =
        Tool.new(
          name: "ask",
          description: "",
          schema: %{},
          handler: fn _ -> {:ask_user, "Are you sure?"} end
        )

      engine =
        Engine.new(
          adapter: Fake,
          adapter_opts: [
            scripts: [
              [{:tool_call, id: "call_0", name: "ask", arguments: %{}}, {:finish, :tool_calls}],
              [{:text, "resumed"}, {:finish, :stop}]
            ]
          ],
          tools: [tool]
        )

      {:ok, s, _} = Session.start(engine, [ALLM.user("hi")])
      assert s.status == :awaiting_user

      assert {:ok, %Session{} = s2, %ChatResult{}} = Session.reply(engine, s, "yes")
      assert s2.pending_question == nil
      assert s2.pending_tool_call_id == nil
      assert_round_trip(s2)
    end

    test "on :completed is treated as :idle" do
      engine =
        Engine.new(
          adapter: Fake,
          adapter_opts: [
            scripts: [
              [{:text, "first"}, {:finish, :stop}],
              [{:text, "again"}, {:finish, :stop}]
            ]
          ]
        )

      {:ok, s, _} = Session.start(engine, [ALLM.user("hi")])
      assert s.status == :completed

      assert {:ok, %Session{status: :completed} = s2, _} = Session.reply(engine, s, "more")
      assert_round_trip(s2)
    end

    test "on :awaiting_tools raises ArgumentError" do
      engine = engine_with_tool_call()
      {:ok, s, _} = Session.start(engine, [ALLM.user("echo")], mode: :manual)
      assert s.status == :awaiting_tools

      assert_raise ArgumentError, ~r/submit_tool_result/, fn ->
        Session.reply(engine, s, "no can do")
      end
    end

    test "on :error returns SessionError" do
      engine = engine_with_text()
      s = %Session{status: :error, metadata: %{error: :boom}}

      assert {:error, %SessionError{reason: :session_in_error_state}} =
               Session.reply(engine, s, "hi")
    end
  end

  # --------------------------------------------------------------------------
  # continue/3
  # --------------------------------------------------------------------------

  describe "continue/3" do
    test "with %Message{} appends and runs (equivalent to reply/4)" do
      engine =
        Engine.new(
          adapter: Fake,
          adapter_opts: [
            scripts: [
              [{:text, "first"}, {:finish, :stop}],
              [{:text, "second"}, {:finish, :stop}]
            ]
          ]
        )

      {:ok, s, _} = Session.start(engine, [ALLM.user("hi")])

      assert {:ok, %Session{} = s2, %ChatResult{}} =
               Session.continue(engine, s, %Message{role: :user, content: "x"})

      assert_round_trip(s2)
    end

    test "with nil message skips append and runs on session.thread" do
      # Set up a manual-mode tool cycle: start halts at :awaiting_tools, submit
      # the tool result, status flips to :idle, then continue/3 nil drives the
      # next adapter turn.
      tool = Tool.new(name: "echo", description: "", schema: %{}, handler: fn a -> {:ok, a} end)

      engine =
        Engine.new(
          adapter: Fake,
          adapter_opts: [
            scripts: [
              [
                {:tool_call, id: "call_0", name: "echo", arguments: %{"x" => 1}},
                {:finish, :tool_calls}
              ],
              [{:text, "after"}, {:finish, :stop}]
            ]
          ],
          tools: [tool]
        )

      {:ok, s, _} = Session.start(engine, [ALLM.user("hi")], mode: :manual)
      assert s.status == :awaiting_tools

      s = Session.submit_tool_result(s, "call_0", %{ok: true})
      assert s.status == :idle

      assert {:ok, %Session{status: :completed} = s2, %ChatResult{}} =
               Session.continue(engine, s, nil)

      assert_round_trip(s2)
    end

    test "on :awaiting_tools with nil but pending_tool_calls non-empty raises" do
      engine = engine_with_tool_call()
      {:ok, s, _} = Session.start(engine, [ALLM.user("hi")], mode: :manual)

      assert_raise ArgumentError, ~r/submit_tool_result/, fn ->
        Session.continue(engine, s, nil)
      end
    end

    test "on :awaiting_user with non-user message raises" do
      tool =
        Tool.new(
          name: "ask",
          description: "",
          schema: %{},
          handler: fn _ -> {:ask_user, "Q?"} end
        )

      engine =
        Engine.new(
          adapter: Fake,
          adapter_opts: [
            script: [
              {:tool_call, id: "call_0", name: "ask", arguments: %{}},
              {:finish, :tool_calls}
            ]
          ],
          tools: [tool]
        )

      {:ok, s, _} = Session.start(engine, [ALLM.user("hi")])
      assert s.status == :awaiting_user

      assert_raise ArgumentError, ~r/reply\/4/, fn ->
        Session.continue(engine, s, %Message{role: :assistant, content: "ignore"})
      end
    end

    test "on :error returns SessionError" do
      engine = engine_with_text()
      s = %Session{status: :error}

      assert {:error, %SessionError{reason: :session_in_error_state}} =
               Session.continue(engine, s, %Message{role: :user, content: "x"})
    end
  end

  # --------------------------------------------------------------------------
  # step/3
  # --------------------------------------------------------------------------

  describe "step/3" do
    test ":auto + terminal :stop produces done?: true, status: :completed" do
      engine = engine_with_text("hello")
      s = Session.new(thread: Thread.from_messages([ALLM.user("hi")]))

      assert {:ok, %Session{status: :completed} = s2, %StepResult{done?: true}} =
               Session.step(engine, s)

      assert_round_trip(s2)
    end

    test ":auto + :tool_calls (auto-execute) produces done?: false, status: :idle" do
      engine = engine_with_tool_call()
      s = Session.new(thread: Thread.from_messages([ALLM.user("echo")]))

      assert {:ok, %Session{status: :idle} = s2, %StepResult{done?: false}} =
               Session.step(engine, s)

      assert_round_trip(s2)
    end

    test ":manual + :tool_calls produces awaiting_tools" do
      engine = engine_with_tool_call()
      s = Session.new(thread: Thread.from_messages([ALLM.user("echo")]))

      assert {:ok, %Session{status: :awaiting_tools, pending_tool_calls: [_]} = s2, %StepResult{}} =
               Session.step(engine, s, mode: :manual)

      assert_round_trip(s2)
    end

    test ":auto + :ask_user produces :awaiting_user" do
      tool =
        Tool.new(
          name: "ask",
          description: "",
          schema: %{},
          handler: fn _ -> {:ask_user, "Confirm?"} end
        )

      engine =
        Engine.new(
          adapter: Fake,
          adapter_opts: [
            script: [
              {:tool_call, id: "call_0", name: "ask", arguments: %{}},
              {:finish, :tool_calls}
            ]
          ],
          tools: [tool]
        )

      s = Session.new(thread: Thread.from_messages([ALLM.user("hi")]))

      assert {:ok, %Session{status: :awaiting_user, pending_question: "Confirm?"}, %StepResult{}} =
               Session.step(engine, s)
    end

    test "raises ArgumentError on :awaiting_user" do
      engine = engine_with_text()
      s = %Session{status: :awaiting_user, pending_question: "?"}

      assert_raise ArgumentError, fn -> Session.step(engine, s) end
    end

    test "raises ArgumentError on :awaiting_tools" do
      engine = engine_with_text()

      s = %Session{
        status: :awaiting_tools,
        pending_tool_calls: [%ToolCall{id: "x", name: "y", arguments: %{}}]
      }

      assert_raise ArgumentError, fn -> Session.step(engine, s) end
    end

    test "on :error returns SessionError" do
      engine = engine_with_text()
      s = %Session{status: :error}

      assert {:error, %SessionError{reason: :session_in_error_state}} = Session.step(engine, s)
    end

    test "step/3 does NOT loop — advances thread by exactly one adapter round-trip" do
      engine = engine_with_tool_call()
      s = Session.new(thread: Thread.from_messages([ALLM.user("echo")]))

      msg_count = length(Session.messages(s))
      {:ok, s2, _} = Session.step(engine, s, mode: :auto)

      # one assistant message + one tool-result message = msg_count + 2.
      assert length(Session.messages(s2)) == msg_count + 2
    end
  end

  # --------------------------------------------------------------------------
  # submit_tool_result/3
  # --------------------------------------------------------------------------

  describe "submit_tool_result/3" do
    test "submits a single result, drops from pending_tool_calls, flips to :idle" do
      tc = %ToolCall{id: "c0", name: "echo", arguments: %{}}

      s =
        Session.new(
          status: :awaiting_tools,
          pending_tool_calls: [tc],
          thread: Thread.from_messages([ALLM.user("hi")])
        )

      result = Session.submit_tool_result(s, "c0", %{ok: true})

      assert %Session{status: :idle, pending_tool_calls: []} = result
      assert_round_trip(result)

      tool_msg = result.thread.messages |> List.last()
      assert tool_msg.role == :tool
      assert tool_msg.tool_call_id == "c0"
      # Map content is JSON-encoded to a binary so the resulting message
      # passes `ALLM.Validate.thread/1` on the next adapter call.
      assert tool_msg.content == ~s({"ok":true})
    end

    test "two pending calls — status stays :awaiting_tools until last is submitted" do
      tc0 = %ToolCall{id: "c0", name: "x", arguments: %{}}
      tc1 = %ToolCall{id: "c1", name: "y", arguments: %{}}

      s =
        Session.new(
          status: :awaiting_tools,
          pending_tool_calls: [tc0, tc1],
          thread: Thread.from_messages([ALLM.user("hi")])
        )

      s2 = Session.submit_tool_result(s, "c0", "r0")
      assert s2.status == :awaiting_tools
      assert length(s2.pending_tool_calls) == 1
      assert_round_trip(s2)

      s3 = Session.submit_tool_result(s2, "c1", "r1")
      assert s3.status == :idle
      assert s3.pending_tool_calls == []
    end

    test "raises ArgumentError on :idle (no pending tool calls)" do
      s = Session.new(status: :idle)

      assert_raise ArgumentError, fn ->
        Session.submit_tool_result(s, "c0", "x")
      end
    end

    test "unknown tool_call_id returns SessionError (not raise)" do
      tc = %ToolCall{id: "c0", name: "x", arguments: %{}}
      s = Session.new(status: :awaiting_tools, pending_tool_calls: [tc])

      assert {:error,
              %SessionError{reason: :unknown_tool_call_id, metadata: %{tool_call_id: "bogus"}}} =
               Session.submit_tool_result(s, "bogus", "x")
    end
  end

  # --------------------------------------------------------------------------
  # submit_tool_results/2
  # --------------------------------------------------------------------------

  describe "submit_tool_results/2" do
    test "batch is equivalent to two sequential submit_tool_result/3 calls" do
      tc0 = %ToolCall{id: "c0", name: "x", arguments: %{}}
      tc1 = %ToolCall{id: "c1", name: "y", arguments: %{}}
      thread = Thread.from_messages([ALLM.user("hi")])
      s = Session.new(status: :awaiting_tools, pending_tool_calls: [tc0, tc1], thread: thread)

      via_batch = Session.submit_tool_results(s, [{"c0", "r0"}, {"c1", "r1"}])

      via_singles =
        s
        |> Session.submit_tool_result("c0", "r0")
        |> Session.submit_tool_result("c1", "r1")

      assert via_batch == via_singles
    end

    test "empty batch is identity" do
      s =
        Session.new(
          status: :awaiting_tools,
          pending_tool_calls: [%ToolCall{id: "x", name: "y", arguments: %{}}]
        )

      assert Session.submit_tool_results(s, []) == s
    end

    test "first unknown id short-circuits with SessionError; no partial mutations" do
      tc0 = %ToolCall{id: "c0", name: "x", arguments: %{}}
      tc1 = %ToolCall{id: "c1", name: "y", arguments: %{}}
      thread = Thread.from_messages([ALLM.user("hi")])
      s = Session.new(status: :awaiting_tools, pending_tool_calls: [tc0, tc1], thread: thread)

      assert {:error,
              %SessionError{reason: :unknown_tool_call_id, metadata: %{tool_call_id: "bogus"}}} =
               Session.submit_tool_results(s, [{"bogus", "r"}, {"c1", "r1"}])
    end
  end

  # --------------------------------------------------------------------------
  # Manual-mode end-to-end
  # --------------------------------------------------------------------------

  describe "manual-mode end-to-end" do
    test "start mode: :manual → submit_tool_result × N → continue(nil) drives the next turn" do
      tool = Tool.new(name: "echo", description: "", schema: %{}, handler: fn a -> {:ok, a} end)

      engine =
        Engine.new(
          adapter: Fake,
          adapter_opts: [
            scripts: [
              [
                {:tool_call, id: "call_0", name: "echo", arguments: %{"x" => 1}},
                {:finish, :tool_calls}
              ],
              [{:text, "after"}, {:finish, :stop}]
            ]
          ],
          tools: [tool]
        )

      {:ok, s1, _} = Session.start(engine, [ALLM.user("hi")], mode: :manual)
      assert s1.status == :awaiting_tools
      assert_round_trip(s1)

      s2 = Session.submit_tool_result(s1, "call_0", %{ok: true})
      assert s2.status == :idle
      assert_round_trip(s2)

      assert {:ok, %Session{status: :completed} = s3, %ChatResult{halted_reason: :completed}} =
               Session.continue(engine, s2, nil)

      assert_round_trip(s3)
    end
  end

  # --------------------------------------------------------------------------
  # Ask-user end-to-end
  # --------------------------------------------------------------------------

  describe "ask-user end-to-end" do
    test "start (ask-user) → reply drives the next turn" do
      tool =
        Tool.new(
          name: "ask",
          description: "",
          schema: %{},
          handler: fn _ -> {:ask_user, "Confirm?"} end
        )

      engine =
        Engine.new(
          adapter: Fake,
          adapter_opts: [
            scripts: [
              [{:tool_call, id: "call_0", name: "ask", arguments: %{}}, {:finish, :tool_calls}],
              [{:text, "resumed"}, {:finish, :stop}]
            ]
          ],
          tools: [tool]
        )

      {:ok, s1, _} = Session.start(engine, [ALLM.user("hi")])
      assert s1.status == :awaiting_user
      assert s1.pending_question == "Confirm?"
      assert_round_trip(s1)

      assert {:ok, %Session{} = s2, %ChatResult{}} = Session.reply(engine, s1, "yes")
      assert s2.pending_question == nil
      assert s2.pending_tool_call_id == nil
      assert_round_trip(s2)
    end
  end

  # --------------------------------------------------------------------------
  # session_id propagation
  # --------------------------------------------------------------------------

  describe "session_id propagation (Decision #9)" do
    test "session.id is set when caller didn't pass session_id:" do
      ref = :erlang.unique_integer()
      pid = self()

      tool =
        Tool.new(
          name: "trace",
          description: "",
          schema: %{},
          handler: fn _, opts ->
            send(pid, {ref, :session_id, opts[:session_id]})
            {:ok, %{}}
          end
        )

      engine =
        Engine.new(
          adapter: Fake,
          adapter_opts: [
            scripts: [
              [{:tool_call, id: "call_0", name: "trace", arguments: %{}}, {:finish, :tool_calls}],
              [{:text, "done"}, {:finish, :stop}]
            ]
          ],
          tools: [tool]
        )

      seed = Session.new(id: "session-abc", thread: Thread.from_messages([ALLM.user("hi")]))
      {:ok, _s, _} = Session.start(engine, seed)

      assert_receive {^ref, :session_id, "session-abc"}, 500
    end

    test "caller-passed session_id wins over session.id" do
      ref = :erlang.unique_integer()
      pid = self()

      tool =
        Tool.new(
          name: "trace",
          description: "",
          schema: %{},
          handler: fn _, opts ->
            send(pid, {ref, :session_id, opts[:session_id]})
            {:ok, %{}}
          end
        )

      engine =
        Engine.new(
          adapter: Fake,
          adapter_opts: [
            scripts: [
              [{:tool_call, id: "call_0", name: "trace", arguments: %{}}, {:finish, :tool_calls}],
              [{:text, "done"}, {:finish, :stop}]
            ]
          ],
          tools: [tool]
        )

      seed = Session.new(id: "session-abc", thread: Thread.from_messages([ALLM.user("hi")]))
      {:ok, _s, _} = Session.start(engine, seed, session_id: "caller-supplied")

      assert_receive {^ref, :session_id, "caller-supplied"}, 500
    end

    test "session.id == nil → opts[:session_id] is nil (default)" do
      ref = :erlang.unique_integer()
      pid = self()

      tool =
        Tool.new(
          name: "trace",
          description: "",
          schema: %{},
          handler: fn _, opts ->
            send(pid, {ref, :session_id, opts[:session_id]})
            {:ok, %{}}
          end
        )

      engine =
        Engine.new(
          adapter: Fake,
          adapter_opts: [
            scripts: [
              [{:tool_call, id: "call_0", name: "trace", arguments: %{}}, {:finish, :tool_calls}],
              [{:text, "done"}, {:finish, :stop}]
            ]
          ],
          tools: [tool]
        )

      {:ok, _s, _} = Session.start(engine, [ALLM.user("hi")])
      assert_receive {^ref, :session_id, nil}, 500
    end
  end

  # --------------------------------------------------------------------------
  # context propagation
  # --------------------------------------------------------------------------

  describe "context propagation (Decision #10)" do
    test "session.context is threaded into opts when caller didn't pass context:" do
      ref = :erlang.unique_integer()
      pid = self()

      tool =
        Tool.new(
          name: "trace",
          description: "",
          schema: %{},
          handler: fn _, opts ->
            send(pid, {ref, :context, opts[:context]})
            {:ok, %{}}
          end
        )

      engine =
        Engine.new(
          adapter: Fake,
          adapter_opts: [
            scripts: [
              [{:tool_call, id: "call_0", name: "trace", arguments: %{}}, {:finish, :tool_calls}],
              [{:text, "done"}, {:finish, :stop}]
            ]
          ],
          tools: [tool]
        )

      seed = Session.new(context: %{user: 42}, thread: Thread.from_messages([ALLM.user("hi")]))
      {:ok, _s, _} = Session.start(engine, seed)

      assert_receive {^ref, :context, %{user: 42}}, 500
    end

    test "caller-passed context wins over session.context" do
      ref = :erlang.unique_integer()
      pid = self()

      tool =
        Tool.new(
          name: "trace",
          description: "",
          schema: %{},
          handler: fn _, opts ->
            send(pid, {ref, :context, opts[:context]})
            {:ok, %{}}
          end
        )

      engine =
        Engine.new(
          adapter: Fake,
          adapter_opts: [
            scripts: [
              [{:tool_call, id: "call_0", name: "trace", arguments: %{}}, {:finish, :tool_calls}],
              [{:text, "done"}, {:finish, :stop}]
            ]
          ],
          tools: [tool]
        )

      seed = Session.new(context: %{user: 42}, thread: Thread.from_messages([ALLM.user("hi")]))
      {:ok, _s, _} = Session.start(engine, seed, context: %{from: :caller})

      assert_receive {^ref, :context, %{from: :caller}}, 500
    end
  end

  # Reference fixture module to ensure the alias is used.
  test "FakeFixtures is available in tests" do
    refute is_nil(FakeFixtures.plain_text("x"))
  end

  # --------------------------------------------------------------------------
  # apply_chat_result/2 / apply_step_result/2 branch coverage
  # --------------------------------------------------------------------------

  describe "apply_chat_result/2 (cross-module helper)" do
    test ":tool_error halt projects status: :error and metadata.error" do
      s = Session.new(thread: Thread.from_messages([ALLM.user("hi")]))

      cr = %ChatResult{
        thread: s.thread,
        final_response: nil,
        steps: [],
        halted_reason: :tool_error,
        metadata: %{on_tool_error_exception: %RuntimeError{message: "boom"}}
      }

      result = Session.apply_chat_result(s, cr)
      assert result.status == :error
      assert %RuntimeError{} = result.metadata[:error]
    end

    test ":manual_tool_calls with non-list final_response.tool_calls falls back to []" do
      s = Session.new(thread: Thread.from_messages([ALLM.user("hi")]))

      cr = %ChatResult{
        thread: s.thread,
        # final_response: nil triggers the manual_tool_calls/1 fallback clause.
        final_response: nil,
        steps: [],
        halted_reason: :manual_tool_calls,
        metadata: %{}
      }

      result = Session.apply_chat_result(s, cr)
      assert result.status == :awaiting_tools
      assert result.pending_tool_calls == []
    end
  end

  # --------------------------------------------------------------------------
  # Phase 1 helpers (append_user/2, append_tool_result/3, pending_tool_calls/1)
  # --------------------------------------------------------------------------

  describe "Phase 1 helpers" do
    test "append_user/2 appends a user message to the thread" do
      s = Session.new()
      s2 = Session.append_user(s, "hello")
      assert [%Message{role: :user, content: "hello"}] = Thread.messages(s2.thread)
    end

    test "append_tool_result/3 appends a :tool message with tool_call_id and content" do
      s = Session.new()
      s2 = Session.append_tool_result(s, "call_42", "result-text")

      assert [%Message{role: :tool, tool_call_id: "call_42", content: "result-text"}] =
               Thread.messages(s2.thread)
    end

    test "pending_tool_calls/1 returns the session's pending_tool_calls list" do
      tc = %ToolCall{id: "call_0", name: "echo", arguments: %{}}
      s = Session.new(pending_tool_calls: [tc])
      assert Session.pending_tool_calls(s) == [tc]

      assert Session.pending_tool_calls(Session.new()) == []
    end
  end

  describe "apply_step_result/2 (cross-module helper)" do
    test ":tool_error halt with no exception falls back to metadata" do
      s = Session.new(thread: Thread.from_messages([ALLM.user("hi")]))

      sr = %StepResult{
        thread: s.thread,
        response: %ALLM.Response{finish_reason: :tool_calls, metadata: %{}},
        tool_results: [],
        done?: true,
        metadata: %{halted_reason: :tool_error, error: :raised}
      }

      result = Session.apply_step_result(s, sr)
      assert result.status == :error
      assert result.metadata[:error] == :raised
    end

    test "finish_reason: :error with empty response.metadata falls back to step metadata" do
      s = Session.new(thread: Thread.from_messages([ALLM.user("hi")]))

      sr = %StepResult{
        thread: s.thread,
        response: %ALLM.Response{finish_reason: :error, metadata: nil},
        tool_results: [],
        done?: true,
        metadata: %{some: :data}
      }

      result = Session.apply_step_result(s, sr)
      assert result.status == :error
      assert result.metadata[:error] == %{some: :data}
    end
  end
end
