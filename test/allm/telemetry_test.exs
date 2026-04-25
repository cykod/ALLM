defmodule ALLM.TelemetryTest do
  @moduledoc """
  Phase 9.1 — span emission tests for `ALLM.Telemetry` and every wrapped
  Layer-C entry point. Verifies `:request_id`, `:engine`, `:model` flow on
  both `:start` and `:stop`; per-span `:stop`-only metadata
  (`:response`, `:step_result`, `:chat_result`); request-id inheritance;
  and the closed `span_name` enum guard.
  """

  use ExUnit.Case, async: false

  alias ALLM.{Engine, Telemetry, Thread}
  alias ALLM.Test.TelemetryCapture

  doctest ALLM.Telemetry

  setup do
    on_exit(fn -> TelemetryCapture.detach() end)
    :ok
  end

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  defp text_engine do
    Engine.new(
      adapter: ALLM.Providers.Fake,
      model: "fake-model",
      adapter_opts: [script: [{:text, "hi"}, {:finish, :stop}]]
    )
  end

  defp text_request, do: ALLM.request([ALLM.user("hi")])

  defp user_thread, do: Thread.from_messages([ALLM.user("hi")])

  defp event(events, name) do
    Enum.find(events, fn {n, _, _} -> n == name end)
  end

  # --------------------------------------------------------------------------
  # request_id/0
  # --------------------------------------------------------------------------

  describe "request_id/0" do
    test "returns a 22-char URL-safe binary" do
      id = Telemetry.request_id()
      assert byte_size(id) == 22
      assert id =~ ~r/^[A-Za-z0-9_-]{22}$/
    end

    test "produces distinct ids on consecutive calls" do
      ids = Enum.map(1..50, fn _ -> Telemetry.request_id() end)
      assert length(Enum.uniq(ids)) == 50
    end
  end

  describe "event_prefix/0" do
    test "returns [:allm]" do
      assert Telemetry.event_prefix() == [:allm]
    end
  end

  # --------------------------------------------------------------------------
  # span/3 — closed-enum guard
  # --------------------------------------------------------------------------

  describe "span/3 closed-enum guard" do
    test "raises ArgumentError for unknown span name" do
      assert_raise ArgumentError, ~r/unknown span name/, fn ->
        Telemetry.span(:not_a_span, %{}, fn -> {:ok, %{}} end)
      end
    end

    test "accepts every legal name" do
      for name <- [:generate, :stream, :step, :chat, :tool] do
        assert :ok = Telemetry.span(name, %{}, fn -> {:ok, %{}} end)
      end
    end
  end

  # --------------------------------------------------------------------------
  # span/3 — start/stop metadata merge
  # --------------------------------------------------------------------------

  describe "span/3 metadata merge" do
    test "shallow-merges stop-extras over start metadata" do
      :ok =
        TelemetryCapture.attach([
          [:allm, :generate, :start],
          [:allm, :generate, :stop]
        ])

      result =
        Telemetry.span(:generate, %{request_id: "rid", engine: :eng, model: "m"}, fn ->
          {:value, %{response: :resp_value, extra: :other}}
        end)

      assert result == :value
      events = TelemetryCapture.events()

      assert {[:allm, :generate, :start], _, %{request_id: "rid", engine: :eng, model: "m"}} =
               event(events, [:allm, :generate, :start])

      {_, stop_measurements, stop_meta} = event(events, [:allm, :generate, :stop])
      assert stop_meta.request_id == "rid"
      assert stop_meta.engine == :eng
      assert stop_meta.model == "m"
      assert stop_meta.response == :resp_value
      assert stop_meta.extra == :other
      assert is_integer(stop_measurements.duration)
    end

    test "emits :exception when closure raises and re-raises" do
      :ok = TelemetryCapture.attach([[:allm, :generate, :exception]])

      assert_raise RuntimeError, "boom", fn ->
        Telemetry.span(:generate, %{request_id: "rid"}, fn ->
          raise "boom"
        end)
      end

      events = TelemetryCapture.events()

      assert {[:allm, :generate, :exception], _, meta} =
               event(events, [:allm, :generate, :exception])

      assert meta.kind == :error
      assert %RuntimeError{} = meta.reason
      assert is_list(meta.stacktrace)
      assert meta.request_id == "rid"
    end
  end

  # --------------------------------------------------------------------------
  # execute/3
  # --------------------------------------------------------------------------

  describe "execute/3" do
    test "emits a single event with the prefix prepended" do
      :ok = TelemetryCapture.attach([[:allm, :adapter, :retry]])

      assert :ok = Telemetry.execute([:adapter, :retry], %{n: 1}, %{tag: :ok})

      assert [{[:allm, :adapter, :retry], %{n: 1}, %{tag: :ok}}] =
               TelemetryCapture.events()
    end
  end

  # --------------------------------------------------------------------------
  # ALLM.generate/3 (:generate span)
  # --------------------------------------------------------------------------

  describe "[:allm, :generate] span" do
    test "fires :start and :stop with common + :response metadata" do
      :ok =
        TelemetryCapture.attach([
          [:allm, :generate, :start],
          [:allm, :generate, :stop]
        ])

      engine = text_engine()
      assert {:ok, response} = ALLM.generate(engine, text_request())

      events = TelemetryCapture.events()
      assert {_, _, start_meta} = event(events, [:allm, :generate, :start])
      assert {_, stop_measurements, stop_meta} = event(events, [:allm, :generate, :stop])

      assert is_binary(start_meta.request_id)
      assert start_meta.request_id =~ ~r/^[A-Za-z0-9_-]{22}$/
      assert start_meta.engine == engine
      assert start_meta.model == "fake-model"

      assert stop_meta.request_id == start_meta.request_id
      assert stop_meta.response == response
      assert is_integer(stop_measurements.duration)

      # Response.request_id matches the span's request_id
      assert response.request_id == start_meta.request_id
    end

    test "honors caller-supplied opts[:request_id]" do
      :ok = TelemetryCapture.attach([[:allm, :generate, :start]])

      caller_id = "caller-supplied-rid-aaa"

      assert {:ok, response} =
               ALLM.generate(text_engine(), text_request(), request_id: caller_id)

      assert [{_, _, %{request_id: ^caller_id}}] = TelemetryCapture.events()
      assert response.request_id == caller_id
    end

    test "[:allm, :generate, :exception] fires when the runner raises and re-raises" do
      :ok = TelemetryCapture.attach([[:allm, :generate, :exception]])

      defmodule RaisingAdapter do
        @behaviour ALLM.Adapter
        @behaviour ALLM.StreamAdapter
        @impl true
        def generate(_req, _opts), do: raise("adapter-boom")
        @impl true
        def stream(_req, _opts), do: raise("adapter-boom")
      end

      engine = Engine.new(adapter: RaisingAdapter, model: "raise-m")

      assert_raise RuntimeError, "adapter-boom", fn ->
        ALLM.generate(engine, text_request())
      end

      events = TelemetryCapture.events()
      assert [{[:allm, :generate, :exception], _, meta}] = events
      assert is_binary(meta.request_id)
      assert meta.kind == :error
      assert %RuntimeError{message: "adapter-boom"} = meta.reason
    end
  end

  # --------------------------------------------------------------------------
  # ALLM.stream_generate/3 (:stream span)
  # --------------------------------------------------------------------------

  describe "[:allm, :stream] span" do
    test "fires :start and :stop with common metadata; :response is nil on stream" do
      :ok =
        TelemetryCapture.attach([
          [:allm, :stream, :start],
          [:allm, :stream, :stop]
        ])

      assert {:ok, stream} = ALLM.stream_generate(text_engine(), text_request())
      _ = Enum.to_list(stream)

      events = TelemetryCapture.events()
      assert {_, _, start_meta} = event(events, [:allm, :stream, :start])
      assert {_, _, stop_meta} = event(events, [:allm, :stream, :stop])

      assert is_binary(start_meta.request_id)
      assert start_meta.engine.adapter == ALLM.Providers.Fake
      assert start_meta.model == "fake-model"

      # :response is intentionally nil on stream :stop (lazy-enumerable carve-out)
      assert Map.get(stop_meta, :response) == nil
      assert stop_meta.request_id == start_meta.request_id
    end
  end

  # --------------------------------------------------------------------------
  # ALLM.step/3 (:step span) + :step_result on :stop
  # --------------------------------------------------------------------------

  describe "[:allm, :step] span" do
    test "fires :start and :stop with :step_result on :stop" do
      :ok =
        TelemetryCapture.attach([
          [:allm, :step, :start],
          [:allm, :step, :stop]
        ])

      assert {:ok, sr} = ALLM.step(text_engine(), user_thread())

      events = TelemetryCapture.events()
      assert {_, _, start_meta} = event(events, [:allm, :step, :start])
      assert {_, _, stop_meta} = event(events, [:allm, :step, :stop])

      assert is_binary(start_meta.request_id)
      assert stop_meta.step_result == sr
    end
  end

  describe "[:allm, :step] span (stream_step)" do
    test "fires :start and :stop for stream_step/3" do
      :ok =
        TelemetryCapture.attach([
          [:allm, :step, :start],
          [:allm, :step, :stop]
        ])

      assert {:ok, stream} = ALLM.stream_step(text_engine(), user_thread())
      _ = Enum.to_list(stream)

      events = TelemetryCapture.events()
      assert event(events, [:allm, :step, :start])
      assert {_, _, stop_meta} = event(events, [:allm, :step, :stop])

      # Lazy-enumerable carve-out — :step_result is nil on stream span :stop.
      assert Map.get(stop_meta, :step_result) == nil
    end
  end

  # --------------------------------------------------------------------------
  # ALLM.chat/3 (:chat span) + :chat_result on :stop
  # --------------------------------------------------------------------------

  describe "[:allm, :chat] span" do
    test "fires :start and :stop with :chat_result on :stop" do
      :ok =
        TelemetryCapture.attach([
          [:allm, :chat, :start],
          [:allm, :chat, :stop]
        ])

      assert {:ok, cr} = ALLM.chat(text_engine(), user_thread())

      events = TelemetryCapture.events()
      assert {_, _, start_meta} = event(events, [:allm, :chat, :start])
      assert {_, _, stop_meta} = event(events, [:allm, :chat, :stop])

      assert is_binary(start_meta.request_id)
      assert stop_meta.chat_result == cr
    end

    test "stream chat fires :start and :stop (chat span name; lazy :chat_result is nil)" do
      :ok =
        TelemetryCapture.attach([
          [:allm, :chat, :start],
          [:allm, :chat, :stop]
        ])

      assert {:ok, stream} = ALLM.stream(text_engine(), user_thread())
      _ = Enum.to_list(stream)

      events = TelemetryCapture.events()
      assert event(events, [:allm, :chat, :start])
      assert {_, _, stop_meta} = event(events, [:allm, :chat, :stop])
      assert Map.get(stop_meta, :chat_result) == nil
    end
  end

  # --------------------------------------------------------------------------
  # request_id inheritance
  # --------------------------------------------------------------------------

  describe "request_id inheritance" do
    test "outer :chat and inner :step share the same request_id" do
      :ok =
        TelemetryCapture.attach([
          [:allm, :chat, :start],
          [:allm, :step, :start]
        ])

      assert {:ok, _} = ALLM.chat(text_engine(), user_thread())

      events = TelemetryCapture.events()
      {_, _, %{request_id: chat_id}} = event(events, [:allm, :chat, :start])
      {_, _, %{request_id: step_id}} = event(events, [:allm, :step, :start])

      assert chat_id == step_id
    end

    test "outer :step and inner :generate share the same request_id" do
      :ok =
        TelemetryCapture.attach([
          [:allm, :step, :start],
          [:allm, :generate, :start]
        ])

      assert {:ok, _} = ALLM.step(text_engine(), user_thread())

      events = TelemetryCapture.events()
      {_, _, %{request_id: step_id}} = event(events, [:allm, :step, :start])
      {_, _, %{request_id: gen_id}} = event(events, [:allm, :generate, :start])

      assert step_id == gen_id
    end

    test ":start and :stop carry the same request_id" do
      :ok =
        TelemetryCapture.attach([
          [:allm, :generate, :start],
          [:allm, :generate, :stop]
        ])

      assert {:ok, _} = ALLM.generate(text_engine(), text_request())

      events = TelemetryCapture.events()
      {_, _, %{request_id: start_id}} = event(events, [:allm, :generate, :start])
      {_, _, %{request_id: stop_id}} = event(events, [:allm, :generate, :stop])

      assert start_id == stop_id
    end
  end
end
