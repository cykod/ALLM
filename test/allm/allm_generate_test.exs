defmodule ALLM.GenerateTest do
  @moduledoc """
  Facade-level tests for `ALLM.generate/3` (spec §4, §10.1).
  """

  use ExUnit.Case, async: true

  alias ALLM.{Engine, Message, Request, Response}
  alias ALLM.Error.EngineError
  alias ALLM.Providers.Fake

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
  end
end
