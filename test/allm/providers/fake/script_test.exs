defmodule ALLM.Providers.Fake.ScriptTest do
  use ExUnit.Case, async: true

  alias ALLM.Error.{AdapterError, StreamError}
  alias ALLM.Providers.Fake.Script
  alias ALLM.{Response, ToolCall, Usage}

  doctest ALLM.Providers.Fake.Script

  # ---------------------------------------------------------------------------
  # detect_shape/1
  # ---------------------------------------------------------------------------

  describe "detect_shape/1" do
    test "detects §31 shape from {:text, _} leading tag" do
      entries = [{:text, "hi"}, {:finish, :stop}]
      assert {:spec31, ^entries} = Script.detect_shape(entries)
    end

    test "detects harness shape from {:ok, _} leading tag" do
      entries = [{:ok, %{output_text: "hi"}}]
      assert {:harness, ^entries} = Script.detect_shape(entries)
    end

    test "detects harness shape from {:text_delta, _} leading tag (stream-side harness)" do
      entries = [{:text_delta, "hi"}]
      assert {:harness, ^entries} = Script.detect_shape(entries)
    end

    test "detects §31 shape from 2-tuple {:error, term}" do
      entries = [{:error, :network_error}]
      assert {:spec31, ^entries} = Script.detect_shape(entries)
    end

    test "detects harness shape from 3-tuple {:error, reason, opts}" do
      entries = [{:error, :rate_limited, [status: 429]}]
      assert {:harness, ^entries} = Script.detect_shape(entries)
    end

    test "shared-semantics :finish tag defaults to §31" do
      entries = [{:finish, :stop}]
      assert {:spec31, ^entries} = Script.detect_shape(entries)
    end

    test "shared-semantics :tool_call tag defaults to §31" do
      entries = [{:tool_call, id: "x", name: "y"}, {:finish, :tool_calls}]
      assert {:spec31, ^entries} = Script.detect_shape(entries)
    end

    test "empty entry list returns {:spec31, []}" do
      assert {:spec31, []} = Script.detect_shape([])
    end

    test "unknown leading tag raises ArgumentError mentioning both vocabularies" do
      assert_raise ArgumentError, ~r/unknown script entry tag/i, fn ->
        Script.detect_shape([{:bogus_tag, "x"}])
      end
    end
  end

  # ---------------------------------------------------------------------------
  # validate!/1
  # ---------------------------------------------------------------------------

  describe "validate!/1" do
    test "mixing :script and :scripts raises ArgumentError" do
      assert_raise ArgumentError, ~r/cannot mix :script and :scripts/, fn ->
        Script.validate!(script: [], scripts: [])
      end
    end

    test ":script being a list of entries returns :ok" do
      assert Script.validate!(script: [{:text, "hi"}]) == :ok
    end

    test ":scripts being a list of lists returns :ok" do
      assert Script.validate!(scripts: [[{:text, "hi"}]]) == :ok
    end

    test ":stream_script being a list of lists returns :ok" do
      assert Script.validate!(stream_script: [[{:text_delta, "hi"}]]) == :ok
    end

    test ":script must be a list" do
      assert_raise ArgumentError, ~r/:script must be a list/, fn ->
        Script.validate!(script: "not a list")
      end
    end

    test ":scripts must be a list of lists" do
      assert_raise ArgumentError, ~r/:scripts must be a list of lists/, fn ->
        Script.validate!(scripts: [not_a_list: :oops])
      end
    end

    test ":stream_script must be a list" do
      assert_raise ArgumentError, ~r/:stream_script must be a list/, fn ->
        Script.validate!(stream_script: "not a list-of-lists")
      end
    end

    test ":script_cursor must be a pid or nil" do
      assert_raise ArgumentError, ~r/:script_cursor/, fn ->
        Script.validate!(script_cursor: 42)
      end
    end

    test ":script_cursor may be a pid" do
      assert Script.validate!(script_cursor: self()) == :ok
    end

    test ":script_cursor may be nil" do
      assert Script.validate!(script_cursor: nil) == :ok
    end

    test "empty opts returns :ok" do
      assert Script.validate!([]) == :ok
    end

    test "empty :script is valid" do
      assert Script.validate!(script: []) == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # fold_to_response/1 — §31 shape
  # ---------------------------------------------------------------------------

  describe "fold_to_response/1 — §31 shape" do
    test "plain text + finish produces %Response{output_text, finish_reason}" do
      assert %Response{output_text: "hello", finish_reason: :stop} =
               Script.fold_to_response([{:text, "hello"}, {:finish, :stop}])
    end

    test "successive :text entries are concatenated" do
      assert %Response{output_text: "hello"} =
               Script.fold_to_response([
                 {:text, "hel"},
                 {:text, "lo"},
                 {:finish, :stop}
               ])
    end

    test "{:tool_call, _} produces a %ToolCall{} on tool_calls" do
      entries = [
        {:tool_call, id: "c1", name: "w", arguments: %{city: "B"}},
        {:finish, :tool_calls}
      ]

      assert %Response{tool_calls: [tc], finish_reason: :tool_calls} =
               Script.fold_to_response(entries)

      assert %ToolCall{id: "c1", name: "w", arguments: %{city: "B"}} = tc
      # raw_arguments should be JSON-encoded arguments by default.
      assert Jason.decode!(tc.raw_arguments) == %{"city" => "B"}
    end

    test ":tool_call_delta accumulates raw_arguments and re-parses on :finish" do
      entries = [
        {:tool_call_delta, id: "c1", arguments_delta: ~S({"ci)},
        {:tool_call_delta, id: "c1", arguments_delta: ~S(ty":"B"})},
        {:finish, :tool_calls}
      ]

      assert %Response{tool_calls: [tc]} = Script.fold_to_response(entries)
      assert tc.raw_arguments == ~S({"city":"B"})
      assert tc.arguments == %{"city" => "B"}
    end

    test "{:usage, map} populates %Response.usage" do
      assert %Response{usage: %Usage{input_tokens: 5, output_tokens: 2}} =
               Script.fold_to_response([
                 {:text, "hi"},
                 {:usage, %{input_tokens: 5, output_tokens: 2}},
                 {:finish, :stop}
               ])
    end

    test "{:usage, map} with unknown keys raises KeyError" do
      assert_raise KeyError, fn ->
        Script.fold_to_response([
          {:usage, %{prompt_tokens: 5}},
          {:finish, :stop}
        ])
      end
    end

    test "{:error, term} short-circuits to {:error, %AdapterError{}}" do
      assert {:error, %AdapterError{reason: :unknown, cause: :boom}} =
               Script.fold_to_response([{:text, "hi"}, {:error, :boom}])
    end

    test "{:delay, ms} sleeps but still produces the response" do
      started = System.monotonic_time(:millisecond)

      assert %Response{output_text: "hi"} =
               Script.fold_to_response([
                 {:delay, 50},
                 {:text, "hi"},
                 {:finish, :stop}
               ])

      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed >= 50
    end

    @tag :capture_log
    test "{:sleep, ms} sleeps (deprecated alias) and still produces the response" do
      started = System.monotonic_time(:millisecond)

      assert %Response{output_text: "hi"} =
               Script.fold_to_response([
                 {:sleep, 20},
                 {:text, "hi"},
                 {:finish, :stop}
               ])

      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed >= 20
    end

    test "{:raw_chunk, _} is ignored in non-streaming fold" do
      assert %Response{output_text: "hi"} =
               Script.fold_to_response([
                 {:raw_chunk, %{ignored: true}},
                 {:text, "hi"},
                 {:finish, :stop}
               ])
    end

    test "tool_call_delta with malformed JSON keeps accumulated raw_arguments" do
      # Unterminated JSON — Jason.decode/1 returns {:error, _} at finalize time;
      # :arguments stays as the pre-decode default (%{}), raw_arguments preserved.
      entries = [
        {:tool_call_delta, id: "c1", arguments_delta: ~S({"ci)},
        {:finish, :tool_calls}
      ]

      assert %Response{tool_calls: [tc]} = Script.fold_to_response(entries)
      assert tc.raw_arguments == ~S({"ci)
      assert tc.arguments == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # fold_to_response/1 — harness shape
  # ---------------------------------------------------------------------------

  describe "fold_to_response/1 — harness shape" do
    test "{:ok, map} builds a %Response{}" do
      assert %Response{output_text: "hi", finish_reason: :stop} =
               Script.fold_to_response([{:ok, %{output_text: "hi", finish_reason: :stop}}])
    end

    test "{:error, reason, opts} returns {:error, %AdapterError{}} forwarded" do
      assert {:error, %AdapterError{reason: :rate_limited, retry_after_ms: 500}} =
               Script.fold_to_response([
                 {:error, :rate_limited, [retry_after_ms: 500]}
               ])
    end
  end

  # ---------------------------------------------------------------------------
  # interpret/1 — per-entry → ALLM.Event list
  # ---------------------------------------------------------------------------

  describe "interpret/1" do
    test "{:text, s} → [{:text_delta, %{id: nil, delta: s}}]" do
      assert Script.interpret({:text, "hi"}) ==
               [{:text_delta, %{id: nil, delta: "hi"}}]
    end

    test "{:tool_call, _} → started + completed (two events)" do
      events =
        Script.interpret({:tool_call, id: "c1", name: "w", arguments: %{"city" => "B"}})

      assert [
               {:tool_call_started, %{id: "c1", name: "w"}},
               {:tool_call_completed,
                %{
                  id: "c1",
                  name: "w",
                  arguments: %{"city" => "B"},
                  raw_arguments: raw
                }}
             ] = events

      assert Jason.decode!(raw) == %{"city" => "B"}
    end

    test "{:tool_call_delta, _} → one delta event" do
      assert Script.interpret({:tool_call_delta, id: "c1", arguments_delta: ~S({"ci)}) ==
               [{:tool_call_delta, %{id: "c1", arguments_delta: ~S({"ci)}}]
    end

    test "{:usage, map} → [{:raw_chunk, {:usage, map}}]" do
      assert Script.interpret({:usage, %{input_tokens: 1}}) ==
               [{:raw_chunk, {:usage, %{input_tokens: 1}}}]
    end

    test "{:raw_chunk, term} → [{:raw_chunk, term}]" do
      assert Script.interpret({:raw_chunk, "raw"}) == [{:raw_chunk, "raw"}]
    end

    test "{:error, atom} where atom is in AdapterError.reason() → forwarded atom" do
      assert [{:error, %AdapterError{reason: :rate_limited}}] =
               Script.interpret({:error, :rate_limited})
    end

    test "{:error, atom_not_in_enum} → :unknown + cause" do
      assert [{:error, %AdapterError{reason: :unknown, cause: :some_unknown_term}}] =
               Script.interpret({:error, :some_unknown_term})
    end

    test "{:error, non-atom-term} → :unknown + cause" do
      assert [{:error, %AdapterError{reason: :unknown, cause: "string"}}] =
               Script.interpret({:error, "string"})
    end

    test "harness {:error_event, reason, opts} → AdapterError" do
      assert [{:error, %AdapterError{reason: :rate_limited, status: 429}}] =
               Script.interpret({:error_event, :rate_limited, [status: 429]})
    end

    test "harness {:stream_error, reason, opts} → StreamError" do
      assert [{:error, %StreamError{reason: :cancelled}}] =
               Script.interpret({:stream_error, :cancelled, []})
    end

    test "{:finish, reason} → [{:message_completed, %{message: assistant}}]" do
      assert [{:message_completed, %{message: msg}}] = Script.interpret({:finish, :stop})
      assert msg.role == :assistant
      assert msg.content == ""
    end

    test "{:delay, ms} → [] (stream/2 handles the sleep separately)" do
      assert Script.interpret({:delay, 5}) == []
    end

    @tag :capture_log
    test "{:sleep, ms} → [] and triggers the deprecation warning (once-per-VM)" do
      # The :sleep warning is deduped across the VM via :persistent_term; this
      # test asserts only that the call returns [] without raising. The
      # Logger.warning/1 fires at most once per BEAM; earlier tests in this
      # suite may have already consumed the "once" slot — tag :capture_log so
      # any emitted output doesn't leak into the test log.
      assert Script.interpret({:sleep, 5}) == []
    end

    test "harness {:text_delta, s} → [{:text_delta, %{id: nil, delta: s}}]" do
      assert Script.interpret({:text_delta, "hi"}) ==
               [{:text_delta, %{id: nil, delta: "hi"}}]
    end

    test "harness {:preflight_error, reason, opts} → [{:error, %AdapterError{}}]" do
      assert [
               {:error,
                %ALLM.Error.AdapterError{
                  reason: :authentication_failed,
                  status: 401
                }}
             ] = Script.interpret({:preflight_error, :authentication_failed, [status: 401]})
    end
  end
end
