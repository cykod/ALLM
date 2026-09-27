defmodule ALLM.ModerationAdapterTest do
  @moduledoc """
  Certifies `ALLM.Providers.FakeModeration` — the reference implementation —
  against the published `ALLM.Test.ModerationAdapterConformance` suite, and
  pins the behaviour's callback surface.
  """

  use ExUnit.Case, async: true
  use ALLM.Test.ModerationAdapterConformance, moderation_adapter: ALLM.Providers.FakeModeration

  alias ALLM.ModerationAdapter
  alias ALLM.Providers.FakeModeration

  describe "callback surface" do
    test "declares moderate/2, max_batch_size/0, and prepare_request/2" do
      callbacks = ModerationAdapter.behaviour_info(:callbacks)

      assert {:moderate, 2} in callbacks
      assert {:max_batch_size, 0} in callbacks
      assert {:prepare_request, 2} in callbacks
    end

    test "prepare_request/2 is the only optional callback" do
      assert ModerationAdapter.behaviour_info(:optional_callbacks) == [prepare_request: 2]
    end

    test "a module implementing only moderate/2 + max_batch_size/0 compiles without warning" do
      source = """
      defmodule ALLM.ModerationAdapterTest.MinimalImpl do
        @behaviour ALLM.ModerationAdapter

        @impl true
        def moderate(_request, _opts), do: {:ok, %ALLM.ModerationResponse{}}

        @impl true
        def max_batch_size, do: 16
      end
      """

      # `Code.with_diagnostics/1` collects only the diagnostics of the compile
      # this process runs, where a `:stderr` capture sees every process's
      # output: in an async module, a warning from any file compiling
      # concurrently would fail this test.
      {[{minimal_impl, _bytecode}], diagnostics} =
        Code.with_diagnostics(fn -> Code.compile_string(source) end)

      assert diagnostics == []
      assert minimal_impl.max_batch_size() == 16
    end
  end

  describe "FakeModeration implements the behaviour" do
    test "declares @behaviour ALLM.ModerationAdapter" do
      behaviours =
        FakeModeration.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert ModerationAdapter in behaviours
    end
  end
end
