defmodule ALLM.Providers.FakeStreamTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ALLM.Error.{AdapterError, StreamError}
  alias ALLM.{Message, Request}
  alias ALLM.Providers.Fake

  import ALLM.Test.AsyncHelpers, only: [wait_for: 2]

  doctest ALLM.Providers.Fake, only: [stream: 2]

  defp fake_request(content \\ "hi") do
    Request.new([%Message{role: :user, content: content}])
  end

  # ---------------------------------------------------------------------------
  # Happy path (§31 shape)
  # ---------------------------------------------------------------------------

  describe "stream/2 — happy path (§31 shape)" do
    test "plain text: 2 text entries + finish → message_started, 2×text_delta, text_completed, message_completed" do
      opts = [
        adapter_opts: [script: [{:text, "hel"}, {:text, "lo"}, {:finish, :stop}]]
      ]

      assert {:ok, stream} = Fake.stream(fake_request(), opts)
      events = Enum.to_list(stream)

      assert [
               {:message_started, _},
               {:text_delta, %{delta: "hel"}},
               {:text_delta, %{delta: "lo"}},
               {:text_completed, %{text: "hello"}},
               {:message_completed, _}
             ] = events
    end

    test "single tool call: tool_call + finish → message_started, tool_call_started, tool_call_completed, message_completed" do
      opts = [
        adapter_opts: [
          script: [
            {:tool_call, id: "c1", name: "w", arguments: %{city: "B"}},
            {:finish, :tool_calls}
          ]
        ]
      ]

      assert {:ok, stream} = Fake.stream(fake_request(), opts)
      events = Enum.to_list(stream)

      assert [
               {:message_started, _},
               {:tool_call_started, %{id: "c1", name: "w"}},
               {:tool_call_completed, %{id: "c1", name: "w"}},
               {:message_completed, _}
             ] = events
    end

    test "tool-call deltas: two :tool_call_delta entries + finish → deltas pass through, no tool_call_started" do
      opts = [
        adapter_opts: [
          script: [
            {:tool_call_delta, id: "c1", arguments_delta: ~S({"ci)},
            {:tool_call_delta, id: "c1", arguments_delta: ~S(ty":"B"})},
            {:finish, :tool_calls}
          ]
        ]
      ]

      assert {:ok, stream} = Fake.stream(fake_request(), opts)
      events = Enum.to_list(stream)

      refute Enum.any?(events, &match?({:tool_call_started, _}, &1))
      assert Enum.count(events, &match?({:tool_call_delta, _}, &1)) == 2
      assert Enum.any?(events, &match?({:message_completed, _}, &1))
    end

    test "empty script: script: [] → :message_started + :message_completed (2 events)" do
      opts = [adapter_opts: [script: []]]

      assert {:ok, stream} = Fake.stream(fake_request(), opts)
      events = Enum.to_list(stream)

      assert [{:message_started, _}, {:message_completed, _}] = events
    end

    test "{:raw_chunk, _} passes through" do
      opts = [
        adapter_opts: [
          script: [{:text, "a"}, {:raw_chunk, %{some: "term"}}, {:finish, :stop}]
        ]
      ]

      assert {:ok, stream} = Fake.stream(fake_request(), opts)
      events = Enum.to_list(stream)

      assert Enum.any?(events, &match?({:raw_chunk, %{some: "term"}}, &1))
    end

    test "{:usage, map} becomes {:raw_chunk, {:usage, map}}" do
      opts = [
        adapter_opts: [
          script: [{:usage, %{input_tokens: 1, output_tokens: 2}}, {:finish, :stop}]
        ]
      ]

      assert {:ok, stream} = Fake.stream(fake_request(), opts)
      events = Enum.to_list(stream)

      assert Enum.any?(
               events,
               &match?(
                 {:raw_chunk, {:usage, %{input_tokens: 1, output_tokens: 2}}},
                 &1
               )
             )
    end
  end

  # ---------------------------------------------------------------------------
  # Happy path (harness shape, :stream_script)
  # ---------------------------------------------------------------------------

  describe "stream/2 — harness shape on :stream_script" do
    test "single-call stream_script with text_delta + finish" do
      opts = [
        adapter_opts: [
          stream_script: [
            [
              {:text_delta, "hel"},
              {:text_delta, "lo"},
              {:finish, :stop}
            ]
          ]
        ]
      ]

      assert {:ok, stream} = Fake.stream(fake_request(), opts)
      events = Enum.to_list(stream)

      assert Enum.any?(events, &match?({:text_delta, %{delta: "hel"}}, &1))
      assert Enum.any?(events, &match?({:text_delta, %{delta: "lo"}}, &1))
      assert Enum.any?(events, &match?({:message_completed, _}, &1))
    end

    test "multi-call stream_script advances the cursor across calls" do
      opts = [
        adapter_opts: [
          stream_script: [
            [{:text_delta, "a"}, {:finish, :stop}],
            [{:text_delta, "b"}, {:finish, :stop}]
          ]
        ]
      ]

      assert {:ok, stream1} = Fake.stream(fake_request(), opts)
      assert Enum.any?(Enum.to_list(stream1), &match?({:text_delta, %{delta: "a"}}, &1))

      assert {:ok, stream2} = Fake.stream(fake_request(), opts)
      assert Enum.any?(Enum.to_list(stream2), &match?({:text_delta, %{delta: "b"}}, &1))
    end

    test ":script is used when :stream_script is absent (fall-through)" do
      opts = [adapter_opts: [script: [{:text, "hi"}, {:finish, :stop}]]]

      assert {:ok, stream} = Fake.stream(fake_request(), opts)
      events = Enum.to_list(stream)

      assert Enum.any?(events, &match?({:text_delta, %{delta: "hi"}}, &1))
    end
  end

  # ---------------------------------------------------------------------------
  # Error paths
  # ---------------------------------------------------------------------------

  describe "stream/2 — error paths" do
    test "§31 {:error, :rate_limited} mid-stream terminates with {:error, %AdapterError{}}" do
      opts = [
        adapter_opts: [
          script: [{:text, "h"}, {:error, :rate_limited}]
        ]
      ]

      assert {:ok, stream} = Fake.stream(fake_request(), opts)
      events = Enum.to_list(stream)

      assert Enum.any?(
               events,
               &match?({:error, %AdapterError{reason: :rate_limited}}, &1)
             )
    end

    test "§31 {:error, \"some string\"} mid-stream → AdapterError :unknown + cause" do
      opts = [
        adapter_opts: [script: [{:text, "h"}, {:error, "some string"}]]
      ]

      assert {:ok, stream} = Fake.stream(fake_request(), opts)
      events = Enum.to_list(stream)

      assert Enum.any?(
               events,
               &match?({:error, %AdapterError{reason: :unknown, cause: "some string"}}, &1)
             )
    end

    test "harness :preflight_error → synchronous {:error, %AdapterError{}} (no stream opened)" do
      opts = [
        adapter_opts: [
          stream_script: [
            [{:preflight_error, :authentication_failed, [status: 401]}]
          ]
        ]
      ]

      assert {:error, %AdapterError{reason: :authentication_failed, status: 401}} =
               Fake.stream(fake_request(), opts)
    end

    test "harness :error_event → mid-stream {:error, %AdapterError{}} event" do
      opts = [
        adapter_opts: [
          stream_script: [
            [{:error_event, :rate_limited, [retry_after_ms: 500]}]
          ]
        ]
      ]

      assert {:ok, stream} = Fake.stream(fake_request(), opts)
      events = Enum.to_list(stream)

      assert Enum.any?(
               events,
               &match?(
                 {:error, %AdapterError{reason: :rate_limited, retry_after_ms: 500}},
                 &1
               )
             )
    end

    test "harness :stream_error → mid-stream {:error, %StreamError{}} event" do
      opts = [
        adapter_opts: [
          stream_script: [[{:stream_error, :cancelled, []}]]
        ]
      ]

      assert {:ok, stream} = Fake.stream(fake_request(), opts)
      events = Enum.to_list(stream)

      assert Enum.any?(
               events,
               &match?({:error, %StreamError{reason: :cancelled}}, &1)
             )
    end
  end

  # ---------------------------------------------------------------------------
  # Timing / backpressure
  # ---------------------------------------------------------------------------

  describe "stream/2 — timing / backpressure" do
    test "{:delay, 50} between two text entries delays wall-clock" do
      opts = [
        adapter_opts: [
          script: [{:text, "a"}, {:delay, 50}, {:text, "b"}, {:finish, :stop}]
        ]
      ]

      assert {:ok, stream} = Fake.stream(fake_request(), opts)
      t0 = System.monotonic_time(:millisecond)
      _events = Enum.to_list(stream)
      elapsed = System.monotonic_time(:millisecond) - t0

      assert elapsed >= 50
    end

    test "{:delay, ms} as the FIRST entry front-loads — :message_started is delayed" do
      opts = [
        adapter_opts: [
          script: [{:delay, 50}, {:text, "a"}, {:finish, :stop}]
        ]
      ]

      assert {:ok, stream} = Fake.stream(fake_request(), opts)

      # Pull the first event and measure how long it took — the stream is
      # lazy, so until we reduce nothing happens. Take 2 events so we're
      # past :message_started AND through the :delay.
      t0 = System.monotonic_time(:millisecond)
      _ = stream |> Enum.take(2)
      elapsed = System.monotonic_time(:millisecond) - t0

      assert elapsed >= 50
    end

    @tag :capture_log
    test "{:sleep, 10} emits a one-time deprecation Logger.warning" do
      opts = [
        adapter_opts: [
          script: [{:text, "a"}, {:sleep, 10}, {:text, "b"}, {:finish, :stop}]
        ]
      ]

      log =
        capture_log(fn ->
          # Reset the persistent_term guard so this test fires the warning
          # independently of other tests' ordering.
          :persistent_term.erase(ALLM.Providers.Fake.Script.SleepWarning)

          assert {:ok, stream} = Fake.stream(fake_request(), opts)
          _ = Enum.to_list(stream)
        end)

      assert log =~ "deprecated"
    end
  end

  # ---------------------------------------------------------------------------
  # Cancellation / halt safety
  # ---------------------------------------------------------------------------

  describe "stream/2 — cancellation / halt safety" do
    test "halt-safety (§31 shape): Enum.take(stream, 2) on a 10-event script fires cleanup within 500ms" do
      ref = :counters.new(1, [:atomics])

      ten_texts =
        Enum.map(?a..?j, fn c -> {:text, <<c>>} end)

      opts = [
        adapter_opts: [
          script: ten_texts ++ [{:finish, :stop}],
          cleanup_observer: ref
        ]
      ]

      assert {:ok, stream} = Fake.stream(fake_request(), opts)
      _ = stream |> Enum.take(2)

      assert wait_for(fn -> :counters.get(ref, 1) == 1 end, 500)
    end

    test "halt-safety (harness shape): same fixture on :stream_script fires cleanup within 500ms" do
      ref = :counters.new(1, [:atomics])

      ten_deltas = Enum.map(?a..?j, fn c -> {:text_delta, <<c>>} end)

      opts = [
        adapter_opts: [
          stream_script: [ten_deltas ++ [{:finish, :stop}]],
          cleanup_observer: ref
        ]
      ]

      assert {:ok, stream} = Fake.stream(fake_request(), opts)
      _ = stream |> Enum.take(2)

      assert wait_for(fn -> :counters.get(ref, 1) == 1 end, 500)
    end

    test "Stream.take_while/2 returning false fires cleanup" do
      ref = :counters.new(1, [:atomics])

      opts = [
        adapter_opts: [
          script: [{:text, "a"}, {:text, "b"}, {:text, "c"}, {:finish, :stop}],
          cleanup_observer: ref
        ]
      ]

      assert {:ok, stream} = Fake.stream(fake_request(), opts)
      _ = stream |> Stream.take_while(&(!match?({:text_delta, _}, &1))) |> Enum.to_list()

      assert wait_for(fn -> :counters.get(ref, 1) == 1 end, 500)
    end

    test "consumer run-to-completion increments counter exactly once" do
      ref = :counters.new(1, [:atomics])

      opts = [
        adapter_opts: [
          script: [{:text, "a"}, {:text, "b"}, {:finish, :stop}],
          cleanup_observer: ref
        ]
      ]

      assert {:ok, stream} = Fake.stream(fake_request(), opts)
      _ = Enum.to_list(stream)

      assert wait_for(fn -> :counters.get(ref, 1) == 1 end, 500)

      # Give the system an extra moment to ensure no further increments.
      Process.sleep(20)
      assert :counters.get(ref, 1) == 1
    end

    test "Stream.run with a reducer that throws fires cleanup" do
      ref = :counters.new(1, [:atomics])

      opts = [
        adapter_opts: [
          script: [{:text, "a"}, {:text, "b"}, {:text, "c"}, {:finish, :stop}],
          cleanup_observer: ref
        ]
      ]

      assert {:ok, stream} = Fake.stream(fake_request(), opts)

      catch_throw(
        Enum.each(stream, fn
          {:text_delta, _} -> throw(:stop_iter)
          _ -> :ok
        end)
      )

      assert wait_for(fn -> :counters.get(ref, 1) == 1 end, 500)
    end
  end

  # ---------------------------------------------------------------------------
  # Multi-call scripting (streams)
  # ---------------------------------------------------------------------------

  describe "stream/2 — multi-call scripting" do
    test "§31 scripts: advances cursor per call; third call synchronously exhausted" do
      opts = [
        adapter_opts: [
          scripts: [
            [{:text, "a"}, {:finish, :stop}],
            [{:text, "b"}, {:finish, :stop}]
          ]
        ]
      ]

      assert {:ok, s1} = Fake.stream(fake_request(), opts)
      events1 = Enum.to_list(s1)
      assert Enum.any?(events1, &match?({:text_delta, %{delta: "a"}}, &1))

      assert {:ok, s2} = Fake.stream(fake_request(), opts)
      events2 = Enum.to_list(s2)
      assert Enum.any?(events2, &match?({:text_delta, %{delta: "b"}}, &1))

      assert {:error, %AdapterError{reason: :no_scripted_response}} =
               Fake.stream(fake_request(), opts)
    end

    test "harness :stream_script advances cursor per call" do
      opts = [
        adapter_opts: [
          stream_script: [
            [{:text_delta, "a"}, {:finish, :stop}],
            [{:text_delta, "b"}, {:finish, :stop}]
          ]
        ]
      ]

      assert {:ok, s1} = Fake.stream(fake_request(), opts)
      assert Enum.any?(Enum.to_list(s1), &match?({:text_delta, %{delta: "a"}}, &1))

      assert {:ok, s2} = Fake.stream(fake_request(), opts)
      assert Enum.any?(Enum.to_list(s2), &match?({:text_delta, %{delta: "b"}}, &1))
    end

    test "explicit :script_cursor works with :stream_script" do
      pid = Fake.start_script_cursor()

      opts = [
        adapter_opts: [
          stream_script: [
            [{:text_delta, "a"}, {:finish, :stop}],
            [{:text_delta, "b"}, {:finish, :stop}]
          ],
          script_cursor: pid
        ]
      ]

      assert {:ok, s1} = Fake.stream(fake_request(), opts)
      _ = Enum.to_list(s1)
      assert Fake.cursor_index(pid) == 1

      assert {:ok, s2} = Fake.stream(fake_request(), opts)
      _ = Enum.to_list(s2)
      assert Fake.cursor_index(pid) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # Request-ignoring
  # ---------------------------------------------------------------------------

  describe "stream/2 — request ignored" do
    test "same script, different requests → same event stream" do
      opts = [
        adapter_opts: [
          scripts: [
            [{:text, "same"}, {:finish, :stop}],
            [{:text, "same"}, {:finish, :stop}]
          ]
        ]
      ]

      {:ok, s_empty} = Fake.stream(Request.new([]), opts)
      events_empty = Enum.to_list(s_empty)

      {:ok, s_tool} =
        Fake.stream(
          Request.new([%Message{role: :tool, content: "r", tool_call_id: "c"}]),
          opts
        )

      events_tool = Enum.to_list(s_tool)

      assert Enum.map(events_empty, &elem(&1, 0)) ==
               Enum.map(events_tool, &elem(&1, 0))
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 5: :finish_reason threaded into :message_completed payload
  # ---------------------------------------------------------------------------

  describe "stream/2 — :message_completed carries :finish_reason (Phase 5)" do
    test "script with {:finish, :stop} → terminal :message_completed payload has finish_reason: :stop" do
      opts = [adapter_opts: [script: [{:text, "hi"}, {:finish, :stop}]]]
      assert {:ok, stream} = Fake.stream(fake_request(), opts)
      events = Enum.to_list(stream)

      {:message_completed, payload} = List.last(events)
      assert payload.finish_reason == :stop
    end

    test "script with {:finish, :tool_calls} → terminal :message_completed payload has finish_reason: :tool_calls" do
      opts = [
        adapter_opts: [
          script: [
            {:tool_call, id: "t", name: "w"},
            {:finish, :tool_calls}
          ]
        ]
      ]

      assert {:ok, stream} = Fake.stream(fake_request(), opts)
      events = Enum.to_list(stream)

      {:message_completed, payload} = List.last(events)
      assert payload.finish_reason == :tool_calls
    end

    test "script with no {:finish, _} entry → terminal :message_completed payload has finish_reason: nil" do
      opts = [adapter_opts: [script: []]]
      assert {:ok, stream} = Fake.stream(fake_request(), opts)
      events = Enum.to_list(stream)

      {:message_completed, payload} = List.last(events)
      assert payload.finish_reason == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Conformance plug-in — inherits the 14 Phase 3 harness cases.
  # ---------------------------------------------------------------------------

  use ALLM.Test.StreamAdapterConformance, stream_adapter: ALLM.Providers.Fake
end
