defmodule ALLM.EmbeddingAdapterTest do
  @moduledoc """
  Certifies `ALLM.Providers.FakeEmbeddings` — the reference implementation —
  against the published `ALLM.Test.EmbeddingAdapterConformance` suite, and
  pins the behaviour's callback surface.
  """

  use ExUnit.Case, async: true
  use ALLM.Test.EmbeddingAdapterConformance, embedding_adapter: ALLM.Providers.FakeEmbeddings

  alias ALLM.EmbeddingAdapter
  alias ALLM.Providers.FakeEmbeddings

  describe "callback surface" do
    test "declares embed/2, max_batch_size/0, and prepare_request/2" do
      callbacks = EmbeddingAdapter.behaviour_info(:callbacks)

      assert {:embed, 2} in callbacks
      assert {:max_batch_size, 0} in callbacks
      assert {:prepare_request, 2} in callbacks
    end

    test "prepare_request/2 is the only optional callback" do
      assert EmbeddingAdapter.behaviour_info(:optional_callbacks) == [prepare_request: 2]
    end

    test "a module implementing only embed/2 + max_batch_size/0 compiles without warning" do
      source = """
      defmodule ALLM.EmbeddingAdapterTest.MinimalImpl do
        @behaviour ALLM.EmbeddingAdapter

        @impl true
        def embed(_request, _opts), do: {:ok, %ALLM.EmbeddingResponse{}}

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

  describe "FakeEmbeddings implements the behaviour" do
    test "declares @behaviour ALLM.EmbeddingAdapter" do
      behaviours =
        FakeEmbeddings.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert EmbeddingAdapter in behaviours
    end
  end
end
