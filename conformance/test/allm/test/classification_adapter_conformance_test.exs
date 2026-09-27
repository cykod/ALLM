defmodule ALLM.Test.ClassificationAdapterConformanceTest do
  @moduledoc """
  Self-test of `ALLM.Test.ClassificationAdapterConformance` against
  `ALLM.Test.Fixtures.ScriptedClassificationStub`.

  Includes three harness meta-tests: a case-count stability guard, a
  count-the-injected-tests guard that catches drift the constant cannot, and
  a missing-opt `KeyError` guard.
  """

  use ExUnit.Case, async: true

  use ALLM.Test.ClassificationAdapterConformance,
    classification_adapter: ALLM.Test.Fixtures.ScriptedClassificationStub

  alias ALLM.Test.ClassificationAdapterConformance

  @describe_name "ALLM.ClassificationAdapter conformance (ALLM.Test.Fixtures.ScriptedClassificationStub)"

  describe "harness meta-invariants" do
    test "the harness declares exactly 9 cases (case-count stability)" do
      assert ClassificationAdapterConformance.case_count() == 9
    end

    test "the injected describe block contains exactly case_count/0 tests" do
      injected =
        __MODULE__.__ex_unit__().tests
        |> Enum.filter(fn test -> test.tags[:describe] == @describe_name end)

      assert length(injected) == ClassificationAdapterConformance.case_count()
    end

    test "the harness macro raises KeyError when the :classification_adapter opt is missing" do
      quoted =
        quote do
          defmodule __MODULE__.MissingClassificationAdapterOpt do
            use ExUnit.Case, async: true
            use ALLM.Test.ClassificationAdapterConformance, wrong_key: SomeModule
          end
        end

      assert_raise KeyError, fn ->
        Code.compile_quoted(quoted)
      end
    end
  end
end
