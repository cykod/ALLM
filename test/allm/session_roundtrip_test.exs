defmodule ALLM.SessionRoundtripTest do
  use ExUnit.Case, async: true

  alias ALLM.{Engine, Message, Session, Thread, Tool, ToolCall}
  alias ALLM.Error.AdapterError
  alias ALLM.Providers.Fake
  alias ALLM.Test.FakeFixtures

  import ALLM.Test.Assertions, only: [assert_session_round_trip: 1, assert_session_round_trip: 2]

  @tag :roundtrip
  test ":idle session round-trips via term_to_binary" do
    session =
      Session.new(
        id: "s_idle",
        status: :idle,
        thread: %Thread{messages: [%Message{role: :system, content: "sys"}]},
        context: %{"user_id" => 1, :mode => "chat", nested: %{"ok" => true}}
      )

    assert session == session |> :erlang.term_to_binary() |> :erlang.binary_to_term()
  end

  @tag :roundtrip
  test ":awaiting_user session round-trips with pending_question" do
    session =
      Session.new(
        id: "s_au",
        status: :awaiting_user,
        thread: %Thread{messages: [%Message{role: :user, content: "hi"}]},
        pending_question: "What is your name?",
        pending_tool_call_id: "call_1"
      )

    assert session == session |> :erlang.term_to_binary() |> :erlang.binary_to_term()
  end

  @tag :roundtrip
  test ":awaiting_tools session round-trips with pending_tool_calls" do
    session =
      Session.new(
        id: "s_at",
        status: :awaiting_tools,
        thread: %Thread{messages: []},
        pending_tool_calls: [
          %ToolCall{id: "call_1", name: "weather", arguments: %{"city" => "SFO"}}
        ]
      )

    assert session == session |> :erlang.term_to_binary() |> :erlang.binary_to_term()
  end

  @tag :roundtrip
  test ":completed session round-trips" do
    session =
      Session.new(
        id: "s_c",
        status: :completed,
        thread: %Thread{messages: [%Message{role: :assistant, content: "done"}]}
      )

    assert session == session |> :erlang.term_to_binary() |> :erlang.binary_to_term()
  end

  @tag :roundtrip
  test ":error session round-trips with metadata[:error] populated" do
    err = AdapterError.new(:rate_limited, provider: :openai, status: 429)

    session =
      Session.new(
        id: "s_err",
        status: :error,
        thread: %Thread{messages: []},
        metadata: %{error: err}
      )

    round_tripped = session |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    assert session == round_tripped
    assert round_tripped.metadata.error.reason == :rate_limited
  end

  # NOTE: `context` must stay serializable; stuffing a PID/ref/fun is the
  # caller's responsibility (see §Non-obvious decision #8 of the design).

  # ===========================================================================
  # Phase 8.4 — post-operation round-trip rows.
  #
  # Every successful Phase-8 operation produces a session that round-trips
  # via ETF unconditionally and via Jason (modulo caller-supplied
  # non-roundtrippable values in :context / :metadata, parameterised on
  # `assert_session_round_trip/2`'s :exclude).
  # ===========================================================================

  defp engine_text(text \\ "ok") do
    Engine.new(adapter: Fake, adapter_opts: [script: [{:text, text}, {:finish, :stop}]])
  end

  defp echo_tool do
    Tool.new(name: "echo", description: "", schema: %{}, handler: fn a -> {:ok, a} end)
  end

  # Phase 1 caller-owned-data contract: atom keys inside `Message.metadata`
  # and `Session.metadata` are NOT restored on JSON round-trip (they decode
  # to string keys via `Jason.decode/1`). Adapter-emitted assistant
  # messages carry `metadata: %{finish_reason: :stop}` and ChatResult
  # populates `Session.metadata` with `%{manual_turn_index: 0}` etc., both
  # of which diverge across the JSON round-trip. Post-`Chat.run/3` sessions
  # therefore exclude `:thread` and `:metadata` from the JSON equality
  # check; ETF round-trip is still asserted unconditionally per
  # `assert_session_round_trip/2` semantics.
  @post_chat_exclude [:thread, :metadata]

  @tag :roundtrip
  test "round-trip after start/3" do
    {:ok, s, _} = Session.start(engine_text(), [ALLM.user("hi")])
    assert_session_round_trip(s, exclude: @post_chat_exclude)
  end

  @tag :roundtrip
  test "round-trip after reply/4" do
    scripts = [
      [{:text, "first"}, {:finish, :stop}],
      [{:text, "second"}, {:finish, :stop}]
    ]

    engine = FakeFixtures.engine_with_scripts(scripts)
    {:ok, s, _} = Session.start(engine, [ALLM.user("hi")])
    {:ok, s2, _} = Session.reply(engine, s, "more")
    assert_session_round_trip(s2, exclude: @post_chat_exclude)
  end

  @tag :roundtrip
  test "round-trip after continue/3 with %Message{}" do
    scripts = [
      [{:text, "a"}, {:finish, :stop}],
      [{:text, "b"}, {:finish, :stop}]
    ]

    engine = FakeFixtures.engine_with_scripts(scripts)
    {:ok, s, _} = Session.start(engine, [ALLM.user("hi")])
    {:ok, s2, _} = Session.continue(engine, s, ALLM.user("more"))
    assert_session_round_trip(s2, exclude: @post_chat_exclude)
  end

  @tag :roundtrip
  test "round-trip after continue/3 with nil message (manual-tool resumption)" do
    scripts = [
      [{:tool_call, id: "c0", name: "echo", arguments: %{}}, {:finish, :tool_calls}],
      [{:text, "done"}, {:finish, :stop}]
    ]

    engine = FakeFixtures.engine_with_scripts(scripts, tools: [echo_tool()])
    {:ok, s, _} = Session.start(engine, [ALLM.user("hi")], mode: :manual)
    s = Session.submit_tool_result(s, "c0", "ok")
    {:ok, s2, _} = Session.continue(engine, s, nil)
    assert_session_round_trip(s2, exclude: @post_chat_exclude)
  end

  @tag :roundtrip
  test "round-trip after step/3" do
    {:ok, s, _} =
      Session.step(engine_text(), Session.new(thread: Thread.from_messages([ALLM.user("hi")])))

    assert_session_round_trip(s, exclude: @post_chat_exclude)
  end

  @tag :roundtrip
  test "round-trip after submit_tool_result/3 (single, last call → :idle)" do
    seed =
      Session.new(
        status: :awaiting_tools,
        pending_tool_calls: [%ToolCall{id: "c0", name: "echo", arguments: %{}}],
        thread: Thread.from_messages([ALLM.user("hi")])
      )

    s = Session.submit_tool_result(seed, "c0", "ok")
    assert_session_round_trip(s)
  end

  @tag :roundtrip
  test "round-trip after submit_tool_result/3 (intermediate, status stays :awaiting_tools)" do
    seed =
      Session.new(
        status: :awaiting_tools,
        pending_tool_calls: [
          %ToolCall{id: "c0", name: "echo", arguments: %{}},
          %ToolCall{id: "c1", name: "echo", arguments: %{}}
        ],
        thread: Thread.from_messages([ALLM.user("hi")])
      )

    s = Session.submit_tool_result(seed, "c0", "ok")
    assert s.status == :awaiting_tools
    assert_session_round_trip(s)
  end

  @tag :roundtrip
  test "round-trip after submit_tool_results/2 (batch)" do
    seed =
      Session.new(
        status: :awaiting_tools,
        pending_tool_calls: [
          %ToolCall{id: "c0", name: "echo", arguments: %{}},
          %ToolCall{id: "c1", name: "echo", arguments: %{}}
        ],
        thread: Thread.from_messages([ALLM.user("hi")])
      )

    s = Session.submit_tool_results(seed, [{"c0", "r0"}, {"c1", "r1"}])
    assert_session_round_trip(s)
  end

  @tag :roundtrip
  test "round-trip after :awaiting_user → reply/4 cycle" do
    tool =
      Tool.new(
        name: "ask",
        description: "",
        schema: %{},
        handler: fn _ -> {:ask_user, "Are you sure?"} end
      )

    scripts = [
      [{:tool_call, id: "c0", name: "ask", arguments: %{}}, {:finish, :tool_calls}],
      [{:text, "resumed"}, {:finish, :stop}]
    ]

    engine = FakeFixtures.engine_with_scripts(scripts, tools: [tool])
    {:ok, s, _} = Session.start(engine, [ALLM.user("hi")])
    assert s.status == :awaiting_user
    assert_session_round_trip(s, exclude: @post_chat_exclude)

    {:ok, s2, _} = Session.reply(engine, s, "yes")
    assert_session_round_trip(s2, exclude: @post_chat_exclude)
  end

  @tag :roundtrip
  test "round-trip after :error session (mid-stream adapter error)" do
    engine = Engine.new(adapter: Fake, adapter_opts: [script: [{:error, :rate_limited}]])
    {:ok, s, _} = Session.start(engine, [ALLM.user("hi")])
    assert s.status == :error
    # AdapterError struct in :metadata is roundtrippable via Serializer.
    # Exclude :thread for the same reason (post-Chat.run/3 message metadata).
    # Exclude :metadata because the adapter error metadata's `:provider`
    # atom value is restored as a string (Phase 1 caller-owned).
    assert_session_round_trip(s, exclude: [:thread, :metadata])
  end
end
