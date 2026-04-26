defmodule ALLM.Providers.Support.SSETest do
  use ExUnit.Case, async: true

  alias ALLM.Providers.Support.SSE

  doctest SSE

  describe "new/0" do
    test "returns the empty accumulator shape per Invariant 1" do
      assert SSE.new() == %{
               buffer: "",
               partial: %{event: nil, data: [], id: nil, retry: nil}
             }
    end
  end

  describe "decode_chunk/2" do
    test "empty chunk returns no events and unchanged accumulator" do
      acc = SSE.new()
      assert {[], ^acc} = SSE.decode_chunk(acc, "")
    end

    test "single complete event returns parsed message and clean accumulator" do
      acc = SSE.new()
      {messages, new_acc} = SSE.decode_chunk(acc, "data: hello\n\n")
      assert messages == [%{event: nil, data: "hello", id: nil, retry: nil}]
      assert new_acc == SSE.new()
    end

    test "event split across two chunks reassembles correctly" do
      acc = SSE.new()
      {messages1, acc1} = SSE.decode_chunk(acc, "data: he")
      assert messages1 == []
      {messages2, acc2} = SSE.decode_chunk(acc1, "llo\n\n")
      assert messages2 == [%{event: nil, data: "hello", id: nil, retry: nil}]
      assert acc2 == SSE.new()
    end

    test "comment lines are dropped" do
      acc = SSE.new()
      {messages, new_acc} = SSE.decode_chunk(acc, ": keep-alive\n")
      assert messages == []
      # No partial state introduced by a comment-only line.
      assert new_acc == SSE.new()
    end

    test "multi-line data: joined with \\n" do
      acc = SSE.new()
      {messages, _new_acc} = SSE.decode_chunk(acc, "data: line1\ndata: line2\n\n")
      assert messages == [%{event: nil, data: "line1\nline2", id: nil, retry: nil}]
    end

    test "[DONE] sentinel returns :done marker" do
      acc = SSE.new()
      {messages, _new_acc} = SSE.decode_chunk(acc, "data: [DONE]\n\n")
      assert messages == [:done]
    end

    test "id: field carries through" do
      acc = SSE.new()
      {messages, _new_acc} = SSE.decode_chunk(acc, "id: abc-123\ndata: hello\n\n")
      assert messages == [%{event: nil, data: "hello", id: "abc-123", retry: nil}]
    end

    test "retry: field parses to pos_integer" do
      acc = SSE.new()
      {messages, _new_acc} = SSE.decode_chunk(acc, "retry: 5000\ndata: hello\n\n")
      assert messages == [%{event: nil, data: "hello", id: nil, retry: 5000}]
    end

    test "event: field carries through" do
      acc = SSE.new()
      {messages, _new_acc} = SSE.decode_chunk(acc, "event: ping\ndata: hello\n\n")
      assert messages == [%{event: "ping", data: "hello", id: nil, retry: nil}]
    end

    test "multiple events in one chunk returned in order" do
      acc = SSE.new()
      {messages, _new_acc} = SSE.decode_chunk(acc, "data: one\n\ndata: two\n\ndata: three\n\n")

      assert messages == [
               %{event: nil, data: "one", id: nil, retry: nil},
               %{event: nil, data: "two", id: nil, retry: nil},
               %{event: nil, data: "three", id: nil, retry: nil}
             ]
    end

    test "malformed line with no colon is dropped silently" do
      acc = SSE.new()
      {messages, _new_acc} = SSE.decode_chunk(acc, "garbage-no-colon\ndata: hello\n\n")
      assert messages == [%{event: nil, data: "hello", id: nil, retry: nil}]
    end

    test "accepts CR, LF, and CRLF terminators" do
      # LF
      {messages_lf, _} = SSE.decode_chunk(SSE.new(), "data: lf\n\n")
      assert messages_lf == [%{event: nil, data: "lf", id: nil, retry: nil}]

      # CRLF
      {messages_crlf, _} = SSE.decode_chunk(SSE.new(), "data: crlf\r\n\r\n")
      assert messages_crlf == [%{event: nil, data: "crlf", id: nil, retry: nil}]

      # CR
      {messages_cr, _} = SSE.decode_chunk(SSE.new(), "data: cr\r\r")
      assert messages_cr == [%{event: nil, data: "cr", id: nil, retry: nil}]
    end

    test "empty-line-only chunk dispatches no message (Invariant 2 — never raises)" do
      acc = SSE.new()
      {messages, new_acc} = SSE.decode_chunk(acc, "\n\n")
      assert messages == []
      assert new_acc == SSE.new()
    end

    test "value with no leading space after colon parses verbatim" do
      acc = SSE.new()
      {messages, _new_acc} = SSE.decode_chunk(acc, "data:hello\n\n")
      assert messages == [%{event: nil, data: "hello", id: nil, retry: nil}]
    end

    test "malformed retry: value is dropped silently (Invariant 2)" do
      acc = SSE.new()
      {messages, _new_acc} = SSE.decode_chunk(acc, "retry: not-a-number\ndata: hello\n\n")
      assert messages == [%{event: nil, data: "hello", id: nil, retry: nil}]
    end

    test "unknown field is dropped silently (SSE spec — ignore unrecognized fields)" do
      acc = SSE.new()
      {messages, _new_acc} = SSE.decode_chunk(acc, "weirdfield: x\ndata: hello\n\n")
      assert messages == [%{event: nil, data: "hello", id: nil, retry: nil}]
    end

    test "accumulator round-trips through :erlang.term_to_binary/1 (Invariant 8)" do
      acc = SSE.new()
      # Drive the accumulator into a non-trivial partial state.
      {_msgs, partial_acc} = SSE.decode_chunk(acc, "event: ping\nid: 42\ndata: he")
      assert partial_acc == partial_acc |> :erlang.term_to_binary() |> :erlang.binary_to_term()

      # And the empty accumulator round-trips too.
      assert acc == acc |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end
  end
end
