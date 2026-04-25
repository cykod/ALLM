defmodule ALLM.StreamGenerateTest do
  @moduledoc """
  Facade-level tests for `ALLM.stream_generate/3` (spec §4, §10.2).
  """

  use ExUnit.Case, async: true

  alias ALLM.{Engine, Message, Request}
  alias ALLM.Error.EngineError
  alias ALLM.Providers.Fake
  alias ALLM.Test.TelemetryCapture

  doctest ALLM, only: [stream_generate: 3]

  defp req, do: Request.new([%Message{role: :user, content: "hi"}])

  describe "stream_generate/3" do
    test "returns {:ok, stream} for a Fake-backed engine" do
      engine =
        Engine.new(
          adapter: Fake,
          adapter_opts: [script: [{:text, "hi"}, {:finish, :stop}]]
        )

      assert {:ok, stream} = ALLM.stream_generate(engine, req())
      events = Enum.to_list(stream)
      assert Enum.any?(events, &match?({:message_completed, _}, &1))
    end

    test "returns {:error, :missing_adapter} when engine.adapter is nil" do
      engine = Engine.new()
      assert {:error, %EngineError{reason: :missing_adapter}} = ALLM.stream_generate(engine, req())
    end

    test "emits [:allm, :stream, :start | :stop] with :request_id, :engine, :model" do
      TelemetryCapture.attach([
        [:allm, :stream, :start],
        [:allm, :stream, :stop]
      ])

      engine =
        Engine.new(
          adapter: Fake,
          model: "fake-m",
          adapter_opts: [script: [{:text, "hi"}, {:finish, :stop}]]
        )

      assert {:ok, stream} = ALLM.stream_generate(engine, req())
      _ = Enum.to_list(stream)

      events = TelemetryCapture.events()
      TelemetryCapture.detach()

      assert {[:allm, :stream, :start], _, start_meta} =
               Enum.find(events, &match?({[:allm, :stream, :start], _, _}, &1))

      assert is_binary(start_meta.request_id)
      assert start_meta.engine == engine
      assert start_meta.model == "fake-m"

      assert {[:allm, :stream, :stop], _, stop_meta} =
               Enum.find(events, &match?({[:allm, :stream, :stop], _, _}, &1))

      assert stop_meta.request_id == start_meta.request_id
      # Lazy-enumerable carve-out: :response is nil on stream span :stop.
      assert Map.get(stop_meta, :response) == nil
    end
  end
end
