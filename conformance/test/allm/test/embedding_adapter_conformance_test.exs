defmodule ALLM.Test.EmbeddingAdapterConformanceTest do
  @moduledoc """
  Self-test of `ALLM.Test.EmbeddingAdapterConformance` against
  `ALLM.Test.Fixtures.ScriptedEmbeddingStub`.

  Includes three harness meta-tests: a case-count stability guard, a
  count-the-injected-tests guard that catches drift the constant cannot, and
  a missing-opt `KeyError` guard.
  """

  use ExUnit.Case, async: true

  use ALLM.Test.EmbeddingAdapterConformance,
    embedding_adapter: ALLM.Test.Fixtures.ScriptedEmbeddingStub

  alias ALLM.Test.EmbeddingAdapterConformance

  @describe_name "ALLM.EmbeddingAdapter conformance (ALLM.Test.Fixtures.ScriptedEmbeddingStub)"

  describe "harness meta-invariants" do
    test "the harness declares exactly 10 cases (case-count stability)" do
      assert EmbeddingAdapterConformance.case_count() == 10
    end

    test "the injected describe block contains exactly case_count/0 tests" do
      injected =
        __MODULE__.__ex_unit__().tests
        |> Enum.filter(fn test -> test.tags[:describe] == @describe_name end)

      assert length(injected) == EmbeddingAdapterConformance.case_count()
    end

    test "the harness macro raises KeyError when the :embedding_adapter opt is missing" do
      quoted =
        quote do
          defmodule __MODULE__.MissingEmbeddingAdapterOpt do
            use ExUnit.Case, async: true
            use ALLM.Test.EmbeddingAdapterConformance, wrong_key: SomeModule
          end
        end

      assert_raise KeyError, fn ->
        Code.compile_quoted(quoted)
      end
    end
  end
end
