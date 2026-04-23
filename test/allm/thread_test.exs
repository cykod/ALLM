defmodule ALLM.ThreadTest do
  use ExUnit.Case, async: true

  alias ALLM.{Message, Thread}

  doctest Thread

  describe "new/1" do
    test "builds an empty thread" do
      t = Thread.new()
      assert %Thread{messages: [], metadata: %{}} = t
    end

    test "accepts messages and metadata" do
      msgs = [%Message{role: :user, content: "hi"}]
      t = Thread.new(messages: msgs, metadata: %{trace: "x"})
      assert t.messages == msgs
      assert t.metadata == %{trace: "x"}
    end
  end

  describe "from_messages/1" do
    test "builds a thread from a list" do
      msgs = [%Message{role: :user, content: "hi"}]
      assert %Thread{messages: ^msgs} = Thread.from_messages(msgs)
    end
  end

  describe "add_message/2 + add_messages/2" do
    test "appends a single message" do
      t = Thread.new() |> Thread.add_message(%Message{role: :user, content: "hi"})
      assert length(t.messages) == 1
    end

    test "appends multiple messages preserving order" do
      t =
        Thread.new()
        |> Thread.add_messages([
          %Message{role: :user, content: "a"},
          %Message{role: :assistant, content: "b"}
        ])

      assert Enum.map(t.messages, & &1.content) == ["a", "b"]
    end
  end

  describe "add_system/2 + add_user/2 + add_assistant/2" do
    test "convenience builders attach the right role" do
      t =
        Thread.new()
        |> Thread.add_system("sys")
        |> Thread.add_user("u")
        |> Thread.add_assistant("a")

      assert Enum.map(t.messages, & &1.role) == [:system, :user, :assistant]
      assert Enum.map(t.messages, & &1.content) == ["sys", "u", "a"]
    end
  end

  describe "messages/1 + last_message/1" do
    test "messages/1 returns the list" do
      assert Thread.messages(Thread.new()) == []
    end

    test "last_message/1 returns nil for an empty thread" do
      assert Thread.last_message(Thread.new()) == nil
    end

    test "last_message/1 returns the last message" do
      t = Thread.new() |> Thread.add_user("first") |> Thread.add_user("last")
      assert Thread.last_message(t).content == "last"
    end
  end

  describe "term_to_binary/binary_to_term round-trip" do
    @tag :roundtrip
    test "a fully populated Thread round-trips to equal value" do
      t =
        Thread.new()
        |> Thread.add_system("sys")
        |> Thread.add_user("hi")
        |> Thread.add_assistant("hello")

      assert t == t |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end
  end

  # NOTE: ALLM.Serializer JSON round-trip is deferred to sub-phase 1.5.
end
