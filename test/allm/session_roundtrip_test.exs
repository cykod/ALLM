defmodule ALLM.SessionRoundtripTest do
  use ExUnit.Case, async: true

  alias ALLM.Error.AdapterError
  alias ALLM.{Message, Session, Thread, ToolCall}

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
end
