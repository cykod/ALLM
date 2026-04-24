defmodule ALLM.Providers.Fake.FixturesTest do
  use ExUnit.Case, async: true

  alias ALLM.Error.AdapterError
  alias ALLM.{Message, Request, Response, ToolCall}
  alias ALLM.Providers.Fake
  alias ALLM.Test.FakeFixtures

  doctest ALLM.Test.FakeFixtures

  defp fake_request(content \\ "x") do
    Request.new([%Message{role: :user, content: content}])
  end

  describe "plain_text/1" do
    test "default text feeds into generate/2 and produces the expected Response" do
      opts = [adapter_opts: FakeFixtures.plain_text("hello")]

      assert {:ok, %Response{output_text: "hello", finish_reason: :stop}} =
               Fake.generate(fake_request(), opts)
    end

    test "multibyte text passes through unchanged" do
      opts = [adapter_opts: FakeFixtures.plain_text("héllo")]

      assert {:ok, %Response{output_text: "héllo", finish_reason: :stop}} =
               Fake.generate(fake_request(), opts)
    end
  end

  describe "single_tool_call/2" do
    test "produces one ToolCall with the given name + arguments + finish :tool_calls" do
      opts = [adapter_opts: FakeFixtures.single_tool_call("get_weather", %{city: "B"})]

      assert {:ok,
              %Response{
                tool_calls: [%ToolCall{id: "call_0", name: "get_weather", arguments: %{city: "B"}}],
                finish_reason: :tool_calls
              }} = Fake.generate(fake_request(), opts)
    end
  end

  describe "parallel_tool_calls/1" do
    test "two tool calls in a single assistant turn, ids call_0 + call_1, in order" do
      opts = [
        adapter_opts: FakeFixtures.parallel_tool_calls([{"a", %{x: 1}}, {"b", %{y: 2}}])
      ]

      assert {:ok, %Response{tool_calls: [tc0, tc1], finish_reason: :tool_calls}} =
               Fake.generate(fake_request(), opts)

      assert %ToolCall{id: "call_0", name: "a", arguments: %{x: 1}} = tc0
      assert %ToolCall{id: "call_1", name: "b", arguments: %{y: 2}} = tc1
    end
  end

  describe "multi_turn_conversation/1" do
    test "sequential calls advance the cursor (isolated via explicit Agent)" do
      scripts = [
        [{:text, "first"}, {:finish, :stop}],
        [{:text, "second"}, {:finish, :stop}]
      ]

      # Use an explicit cursor for clean isolation — avoids content-equal
      # hash collision with any other test that might share these entries.
      cursor = Fake.start_script_cursor()

      opts = [
        adapter_opts: FakeFixtures.multi_turn_conversation(scripts) ++ [script_cursor: cursor]
      ]

      assert {:ok, %Response{output_text: "first"}} = Fake.generate(fake_request(), opts)
      assert {:ok, %Response{output_text: "second"}} = Fake.generate(fake_request(), opts)
      assert Fake.cursor_index(cursor) == 2
    end

    test "raises ArgumentError when any inner element isn't a list" do
      assert_raise ArgumentError, ~r/list of lists/, fn ->
        FakeFixtures.multi_turn_conversation([{:text, "not a list"}])
      end
    end
  end

  describe "mid_stream_error/1" do
    test "stream/2 terminates with {:error, %AdapterError{reason: :rate_limited}}" do
      opts = [adapter_opts: FakeFixtures.mid_stream_error(:rate_limited)]

      assert {:ok, stream} = Fake.stream(fake_request(), opts)
      events = Enum.to_list(stream)

      assert Enum.any?(
               events,
               &match?({:error, %AdapterError{reason: :rate_limited}}, &1)
             )
    end
  end

  describe "empty_response/0" do
    test "generate/2 returns empty Response with metadata.empty_script: true" do
      opts = [adapter_opts: FakeFixtures.empty_response()]

      assert {:ok, %Response{output_text: "", finish_reason: :stop, metadata: meta}} =
               Fake.generate(fake_request(), opts)

      assert meta[:empty_script] == true
    end

    test "stream/2 emits :message_started + :message_completed (2 events)" do
      opts = [adapter_opts: FakeFixtures.empty_response()]

      assert {:ok, stream} = Fake.stream(fake_request(), opts)

      assert [{:message_started, _}, {:message_completed, _}] = Enum.to_list(stream)
    end
  end

  describe "tool_call_with_streamed_args/2" do
    test "emits exactly two :tool_call_delta events; reassembled JSON parses via Jason.decode/1" do
      arguments_json = ~S({"city":"B"})
      opts = [adapter_opts: FakeFixtures.tool_call_with_streamed_args("get_w", arguments_json)]

      assert {:ok, stream} = Fake.stream(fake_request(), opts)
      events = Enum.to_list(stream)

      deltas =
        for {:tool_call_delta, %{id: "call_1", arguments_delta: d}} <- events, do: d

      assert length(deltas) == 2

      reassembled = Enum.join(deltas)
      assert {:ok, %{"city" => "B"}} = Jason.decode(reassembled)
    end

    test "codepoint-safe split on multibyte JSON never yields mid-codepoint fragments" do
      # JSON with a multibyte value ensures String.split_at/2 honours codepoints.
      arguments_json = ~S({"city":"München"})
      opts = [adapter_opts: FakeFixtures.tool_call_with_streamed_args("get_w", arguments_json)]

      assert {:ok, stream} = Fake.stream(fake_request(), opts)
      events = Enum.to_list(stream)

      deltas =
        for {:tool_call_delta, %{id: "call_1", arguments_delta: d}} <- events, do: d

      # Each fragment must be valid UTF-8 — a mid-codepoint split would yield
      # a binary whose String.valid?/1 returns false.
      assert Enum.all?(deltas, &String.valid?/1)

      assert {:ok, %{"city" => "München"}} = Jason.decode(Enum.join(deltas))
    end
  end

  describe "delayed_text/2" do
    test "stream emits text after >= delay_ms wall-clock" do
      opts = [adapter_opts: FakeFixtures.delayed_text("hello", 50)]

      assert {:ok, stream} = Fake.stream(fake_request(), opts)

      t0 = System.monotonic_time(:millisecond)
      events = Enum.to_list(stream)
      elapsed = System.monotonic_time(:millisecond) - t0

      assert elapsed >= 50
      assert Enum.any?(events, &match?({:text_delta, %{delta: "hello"}}, &1))
    end
  end
end
