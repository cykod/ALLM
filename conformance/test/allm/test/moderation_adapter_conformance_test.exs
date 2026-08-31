defmodule ALLM.Test.ModerationAdapterConformanceTest do
  @moduledoc """
  Self-test of `ALLM.Test.ModerationAdapterConformance` against
  `ALLM.Test.Fixtures.ScriptedModerationStub`.

  Includes three harness meta-tests: a case-count stability guard, a
  count-the-injected-tests guard that catches drift the constant cannot, and
  a missing-opt `KeyError` guard.
  """

  use ExUnit.Case, async: true

  use ALLM.Test.ModerationAdapterConformance,
    moderation_adapter: ALLM.Test.Fixtures.ScriptedModerationStub

  alias ALLM.Test.ModerationAdapterConformance

  @describe_name "ALLM.ModerationAdapter conformance (ALLM.Test.Fixtures.ScriptedModerationStub)"

  describe "harness meta-invariants" do
    test "the harness declares exactly 10 cases (case-count stability)" do
      assert ModerationAdapterConformance.case_count() == 10
    end

    test "the injected describe block contains exactly case_count/0 tests" do
      injected =
        __MODULE__.__ex_unit__().tests
        |> Enum.filter(fn test -> test.tags[:describe] == @describe_name end)

      assert length(injected) == ModerationAdapterConformance.case_count()
    end

    test "the harness macro raises KeyError when the :moderation_adapter opt is missing" do
      quoted =
        quote do
          defmodule __MODULE__.MissingModerationAdapterOpt do
            use ExUnit.Case, async: true
            use ALLM.Test.ModerationAdapterConformance, wrong_key: SomeModule
          end
        end

      assert_raise KeyError, fn ->
        Code.compile_quoted(quoted)
      end
    end
  end
end
