defmodule ALLM.StreamRunnerTest do
  use ExUnit.Case, async: true

  alias ALLM.{Engine, Message, Request, StreamRunner}
  alias ALLM.Error.{AdapterError, EngineError, ValidationError}
  alias ALLM.Providers.Fake

  import ALLM.Test.AsyncHelpers, only: [wait_for: 2]

  doctest StreamRunner

  # ---------------------------------------------------------------------------
  # Test-local adapters — inline, to avoid polluting lib/ or test/support/
  # ---------------------------------------------------------------------------

  # Implements ALLM.Adapter only (no stream/2). Used to assert the
  # :missing_stream_adapter guard fires.
  defmodule NonStreamAdapter do
    @moduledoc false
    @behaviour ALLM.Adapter

    @impl ALLM.Adapter
    def generate(_request, _opts), do: {:ok, %ALLM.Response{}}
  end

  # Records the opts it receives to a pid passed via
  # `adapter_opts[:opts_recorder]`. Implements both Adapter behaviours but
  # only `stream/2` is exercised here.
  defmodule RecordingAdapter do
    @moduledoc false
    @behaviour ALLM.StreamAdapter

    @impl ALLM.StreamAdapter
    def stream(_request, opts) do
      case Keyword.get(Keyword.get(opts, :adapter_opts, []), :opts_recorder) do
        pid when is_pid(pid) -> send(pid, {:recorded_opts, opts})
        _ -> :ok
      end

      {:ok,
       Stream.map([{:message_completed, %{message: %Message{role: :assistant, content: ""}}}], & &1)}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp req, do: Request.new([%Message{role: :user, content: "hi"}])

  defp fake_engine(script) do
    Engine.new(adapter: Fake, adapter_opts: [script: script])
  end

  # ---------------------------------------------------------------------------
  # Dispatch + happy path
  # ---------------------------------------------------------------------------

  describe "run/3 — happy path" do
    test "returns {:ok, stream} for a plain-text Fake script" do
      engine = fake_engine([{:text, "hi"}, {:finish, :stop}])

      assert {:ok, stream} = StreamRunner.run(engine, req())
      events = Enum.to_list(stream)
      tags = Enum.map(events, &elem(&1, 0))

      assert :message_started in tags
      assert :text_delta in tags
      assert :text_completed in tags
      assert :message_completed in tags
    end

    test "events arrive in script order" do
      engine = fake_engine([{:text, "a"}, {:text, "b"}, {:finish, :stop}])

      {:ok, stream} = StreamRunner.run(engine, req())
      events = Enum.to_list(stream)

      text_deltas =
        for {:text_delta, %{delta: d}} <- events, do: d

      assert text_deltas == ["a", "b"]
    end
  end

  # ---------------------------------------------------------------------------
  # Error paths
  # ---------------------------------------------------------------------------

  describe "run/3 — validation errors" do
    test "nil adapter returns :missing_adapter" do
      engine = Engine.new()
      assert {:error, %EngineError{reason: :missing_adapter}} = StreamRunner.run(engine, req())
    end

    test "adapter without stream/2 returns :missing_stream_adapter" do
      engine = Engine.new(adapter: NonStreamAdapter)

      assert {:error, %EngineError{reason: :missing_stream_adapter}} =
               StreamRunner.run(engine, req())
    end

    test "empty messages returns %ValidationError{reason: :invalid_request}" do
      engine = fake_engine([{:text, "x"}, {:finish, :stop}])
      empty_req = %Request{Request.new([%Message{role: :user, content: "x"}]) | messages: []}

      assert {:error, %ValidationError{reason: :invalid_request, errors: errors}} =
               StreamRunner.run(engine, empty_req)

      assert {:messages, :empty} in errors
    end

    test "vision message returns :vision_not_in_v0_2" do
      engine = fake_engine([{:text, "x"}, {:finish, :stop}])

      vision_req =
        Request.new([
          %Message{role: :user, content: [%{type: "image", url: "data:..."}]}
        ])

      assert {:error, %ValidationError{reason: :vision_not_in_v0_2}} =
               StreamRunner.run(engine, vision_req)
    end

    test "adapter pre-flight error bubbles as AdapterError" do
      engine = fake_engine([{:preflight_error, :authentication_failed, []}])

      assert {:error, %AdapterError{reason: :authentication_failed}} =
               StreamRunner.run(engine, req())
    end
  end

  # ---------------------------------------------------------------------------
  # Filters (§19)
  # ---------------------------------------------------------------------------

  describe "run/3 — filters" do
    test "emit_text_deltas: false drops :text_delta but keeps :text_completed and :message_completed" do
      engine = fake_engine([{:text, "hi"}, {:finish, :stop}])

      {:ok, stream} = StreamRunner.run(engine, req(), emit_text_deltas: false)
      events = Enum.to_list(stream)
      tags = Enum.map(events, &elem(&1, 0))

      refute :text_delta in tags
      assert :text_completed in tags
      assert :message_completed in tags
    end

    test "emit_tool_deltas: false drops :tool_call_delta events" do
      # Use a tool_call entry with streamed args to generate tool_call_delta events.
      engine =
        fake_engine([
          {:tool_call_delta, id: "t1", name: "weather", arguments_delta: "{\"c\":"},
          {:tool_call_delta, id: "t1", arguments_delta: "\"Paris\"}"},
          {:finish, :tool_calls}
        ])

      {:ok, stream} = StreamRunner.run(engine, req(), emit_tool_deltas: false)
      events = Enum.to_list(stream)
      tags = Enum.map(events, &elem(&1, 0))

      refute :tool_call_delta in tags
    end

    test "include_raw_chunks: false (default) drops non-usage :raw_chunk events" do
      engine = fake_engine([{:raw_chunk, "debug"}, {:text, "hi"}, {:finish, :stop}])

      {:ok, stream} = StreamRunner.run(engine, req())
      events = Enum.to_list(stream)

      refute Enum.any?(events, &match?({:raw_chunk, "debug"}, &1))
    end

    test "include_raw_chunks: true preserves non-usage :raw_chunk events" do
      engine = fake_engine([{:raw_chunk, "debug"}, {:text, "hi"}, {:finish, :stop}])

      {:ok, stream} = StreamRunner.run(engine, req(), include_raw_chunks: true)
      events = Enum.to_list(stream)

      assert Enum.any?(events, &match?({:raw_chunk, "debug"}, &1))
    end

    test "usage carve-out: {:raw_chunk, {:usage, _}} passes even when include_raw_chunks: false" do
      usage = %{input_tokens: 1, output_tokens: 2}

      engine =
        fake_engine([
          {:usage, usage},
          {:text, "hi"},
          {:finish, :stop}
        ])

      # Default (include_raw_chunks: false).
      {:ok, stream} = StreamRunner.run(engine, req())
      events = Enum.to_list(stream)
      assert Enum.any?(events, &match?({:raw_chunk, {:usage, _}}, &1))
    end

    test "usage carve-out: {:raw_chunk, {:usage, _}} passes when include_raw_chunks: true too" do
      usage = %{input_tokens: 1, output_tokens: 2}
      engine = fake_engine([{:usage, usage}, {:text, "hi"}, {:finish, :stop}])

      {:ok, stream} = StreamRunner.run(engine, req(), include_raw_chunks: true)
      events = Enum.to_list(stream)

      assert Enum.any?(events, &match?({:raw_chunk, {:usage, _}}, &1))
    end

    test "filters compose: emit_text_deltas: false AND include_raw_chunks: false; usage still passes" do
      engine =
        fake_engine([
          {:text, "hi"},
          {:raw_chunk, "debug"},
          {:usage, %{input_tokens: 1}},
          {:finish, :stop}
        ])

      {:ok, stream} =
        StreamRunner.run(engine, req(), emit_text_deltas: false, include_raw_chunks: false)

      events = Enum.to_list(stream)
      tags = Enum.map(events, &elem(&1, 0))

      refute :text_delta in tags
      refute Enum.any?(events, &match?({:raw_chunk, "debug"}, &1))
      assert Enum.any?(events, &match?({:raw_chunk, {:usage, _}}, &1))
    end

    test "call opts win over engine params" do
      # Engine says text deltas off; call opts turn them on.
      engine =
        Engine.new(
          adapter: Fake,
          adapter_opts: [script: [{:text, "hi"}, {:finish, :stop}]],
          params: %{emit_text_deltas: false}
        )

      {:ok, stream} = StreamRunner.run(engine, req(), emit_text_deltas: true)
      events = Enum.to_list(stream)
      tags = Enum.map(events, &elem(&1, 0))

      assert :text_delta in tags
    end
  end

  # ---------------------------------------------------------------------------
  # :on_event callback
  # ---------------------------------------------------------------------------

  describe "run/3 — on_event" do
    test "every event the adapter produces is delivered to on_event" do
      engine = fake_engine([{:text, "hi"}, {:finish, :stop}])
      me = self()
      on_event = fn e -> send(me, {:saw, e}) end

      {:ok, stream} = StreamRunner.run(engine, req(), on_event: on_event)
      _events = Enum.to_list(stream)

      # Drain the mailbox and verify we saw at least message_started/text_delta/message_completed.
      assert_received {:saw, {:message_started, _}}
      assert_received {:saw, {:text_delta, _}}
      assert_received {:saw, {:message_completed, _}}
    end

    test "on_event fires BEFORE filters (text_delta visible in callback even when filtered out)" do
      engine = fake_engine([{:text, "hi"}, {:finish, :stop}])
      me = self()
      on_event = fn e -> send(me, {:saw, e}) end

      {:ok, stream} =
        StreamRunner.run(engine, req(), on_event: on_event, emit_text_deltas: false)

      events = Enum.to_list(stream)
      tags = Enum.map(events, &elem(&1, 0))

      # Consumer stream has no text_delta...
      refute :text_delta in tags
      # ... but the on_event callback did see it.
      assert_received {:saw, {:text_delta, _}}
    end

    test "on_event that raises propagates (no try/rescue)" do
      engine = fake_engine([{:text, "hi"}, {:finish, :stop}])
      on_event = fn _ -> raise "boom" end

      {:ok, stream} = StreamRunner.run(engine, req(), on_event: on_event)

      assert_raise RuntimeError, "boom", fn -> Enum.to_list(stream) end
    end

    test "on_event: nil is a no-op (equivalent to default)" do
      engine = fake_engine([{:text, "hi"}, {:finish, :stop}])

      assert {:ok, stream} = StreamRunner.run(engine, req(), on_event: nil)
      events = Enum.to_list(stream)
      assert Enum.any?(events, &match?({:message_completed, _}, &1))
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 7 opts stripped (Non-obvious Decision #11)
  # ---------------------------------------------------------------------------

  describe "run/3 — Phase 7 opts stripped" do
    test "[mode: :auto] succeeds; :mode is not in the dispatch opts" do
      me = self()

      engine =
        Engine.new(
          adapter: RecordingAdapter,
          adapter_opts: [opts_recorder: me]
        )

      assert {:ok, stream} = StreamRunner.run(engine, req(), mode: :auto)
      _ = Enum.to_list(stream)

      assert_received {:recorded_opts, recorded}
      refute Keyword.has_key?(recorded, :mode)
    end

    test "[max_turns: 5, halt_when: fun] succeeds; fun never reaches adapter" do
      me = self()

      engine =
        Engine.new(
          adapter: RecordingAdapter,
          adapter_opts: [opts_recorder: me]
        )

      halt_when = fn _ -> true end

      assert {:ok, stream} =
               StreamRunner.run(engine, req(), max_turns: 5, halt_when: halt_when)

      _ = Enum.to_list(stream)

      assert_received {:recorded_opts, recorded}
      refute Keyword.has_key?(recorded, :max_turns)
      refute Keyword.has_key?(recorded, :halt_when)
      # Walk the whole opts term to be sure the fun value isn't hidden inside a map.
      refute any_function_in?(recorded)
    end

    test "[mode: :auto, emit_text_deltas: false] — mode stripped; emit filter applies" do
      engine = fake_engine([{:text, "hi"}, {:finish, :stop}])

      {:ok, stream} = StreamRunner.run(engine, req(), mode: :auto, emit_text_deltas: false)
      events = Enum.to_list(stream)
      tags = Enum.map(events, &elem(&1, 0))

      refute :text_delta in tags
      assert :text_completed in tags
    end
  end

  defp any_function_in?(term) when is_function(term), do: true
  defp any_function_in?(list) when is_list(list), do: Enum.any?(list, &any_function_in?/1)

  defp any_function_in?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> any_function_in?()

  defp any_function_in?(map) when is_map(map),
    do: Enum.any?(map, fn {k, v} -> any_function_in?(k) or any_function_in?(v) end)

  defp any_function_in?(_), do: false

  # ---------------------------------------------------------------------------
  # Halt propagation (Non-obvious Decision #6)
  # ---------------------------------------------------------------------------

  describe "run/3 — halt propagation" do
    test "Enum.take/2 on a long script fires cleanup observer within 500ms" do
      ref = :counters.new(1, [:atomics])

      script = [
        {:text, "a"},
        {:text, "b"},
        {:text, "c"},
        {:text, "d"},
        {:text, "e"},
        {:text, "f"},
        {:text, "g"},
        {:text, "h"},
        {:text, "i"},
        {:finish, :stop}
      ]

      engine =
        Engine.new(
          adapter: Fake,
          adapter_opts: [script: script, cleanup_observer: ref]
        )

      {:ok, stream} = StreamRunner.run(engine, req())
      _ = stream |> Enum.take(2)

      assert wait_for(fn -> :counters.get(ref, 1) == 1 end, 500)
    end
  end
end
