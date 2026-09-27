defmodule ALLM.ClassificationAdapterTest do
  @moduledoc """
  Certifies `ALLM.Providers.FakeClassification` — the reference
  implementation — against the published
  `ALLM.Test.ClassificationAdapterConformance` suite, and pins the
  behaviour's callback surface.
  """

  use ExUnit.Case, async: true

  use ALLM.Test.ClassificationAdapterConformance,
    classification_adapter: ALLM.Providers.FakeClassification

  alias ALLM.ClassificationAdapter
  alias ALLM.Providers.FakeClassification

  describe "callback surface" do
    test "declares classify/2 and prepare_request/2" do
      callbacks = ClassificationAdapter.behaviour_info(:callbacks)

      assert {:classify, 2} in callbacks
      assert {:prepare_request, 2} in callbacks
      assert length(callbacks) == 2
    end

    test "prepare_request/2 is the only optional callback" do
      assert ClassificationAdapter.behaviour_info(:optional_callbacks) == [prepare_request: 2]
    end

    test "a module implementing only classify/2 compiles without warning" do
      source = """
      defmodule ALLM.ClassificationAdapterTest.MinimalImpl do
        @behaviour ALLM.ClassificationAdapter

        @impl true
        def classify(_request, _opts), do: {:ok, %ALLM.ClassificationResponse{}}
      end
      """

      # `Code.with_diagnostics/1` collects only this compile's diagnostics; a
      # `:stderr` capture would also see warnings from files compiling
      # concurrently in other async modules.
      {[{minimal_impl, _bytecode}], diagnostics} =
        Code.with_diagnostics(fn -> Code.compile_string(source) end)

      assert diagnostics == []
      assert {:ok, %ALLM.ClassificationResponse{}} = minimal_impl.classify(nil, [])
    end
  end

  describe "FakeClassification implements the behaviour" do
    test "declares @behaviour ALLM.ClassificationAdapter" do
      behaviours =
        FakeClassification.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert ClassificationAdapter in behaviours
    end
  end
end
