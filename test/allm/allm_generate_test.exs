defmodule ALLM.GenerateTest do
  @moduledoc """
  Facade-level tests for `ALLM.generate/3` (spec §4, §10.1).
  """

  use ExUnit.Case, async: true

  alias ALLM.{Engine, Message, Request, Response}
  alias ALLM.Error.EngineError
  alias ALLM.Providers.Fake
  alias ALLM.Test.TelemetryCapture

  doctest ALLM, only: [generate: 3]

  defp req, do: Request.new([%Message{role: :user, content: "hi"}])

  describe "generate/3" do
    test "returns {:ok, %Response{}} for a Fake-backed engine" do
      engine =
        Engine.new(
          adapter: Fake,
          adapter_opts: [script: [{:text, "hi"}, {:finish, :stop}]]
        )

      assert {:ok, %Response{output_text: "hi", finish_reason: :stop}} =
               ALLM.generate(engine, req())
    end

    test "returns {:error, :missing_adapter} when engine.adapter is nil" do
      engine = Engine.new()

      assert {:error, %EngineError{reason: :missing_adapter}} =
               ALLM.generate(engine, req())
    end

    test "emits [:allm, :generate, :start | :stop] with :request_id, :engine, :model and :response on :stop" do
      TelemetryCapture.attach([
        [:allm, :generate, :start],
        [:allm, :generate, :stop]
      ])

      engine =
        Engine.new(
          adapter: Fake,
          model: "fake-m",
          adapter_opts: [script: [{:text, "hi"}, {:finish, :stop}]]
        )

      assert {:ok, response} = ALLM.generate(engine, req())

      events = TelemetryCapture.events()
      TelemetryCapture.detach()

      assert {[:allm, :generate, :start], _, start_meta} =
               Enum.find(events, &match?({[:allm, :generate, :start], _, _}, &1))

      assert is_binary(start_meta.request_id)
      assert start_meta.engine == engine
      assert start_meta.model == "fake-m"

      assert {[:allm, :generate, :stop], _, stop_meta} =
               Enum.find(events, &match?({[:allm, :generate, :stop], _, _}, &1))

      assert stop_meta.request_id == start_meta.request_id
      assert stop_meta.response == response
    end
  end
end
