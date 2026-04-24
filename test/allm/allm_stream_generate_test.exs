defmodule ALLM.StreamGenerateTest do
  @moduledoc """
  Facade-level tests for `ALLM.stream_generate/3` (spec §4, §10.2).
  """

  use ExUnit.Case, async: true

  alias ALLM.{Engine, Message, Request}
  alias ALLM.Error.EngineError
  alias ALLM.Providers.Fake

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
  end
end
