defmodule ALLM.Test.ImageAdapterConformanceTest do
  @moduledoc """
  Self-test of `ALLM.Test.ImageAdapterConformance` against
  `ALLM.Test.Fixtures.ScriptedImageStub`.

  Includes two harness meta-tests: a case-count stability guard and a
  missing-opt `KeyError` guard.
  """

  use ExUnit.Case, async: true
  use ALLM.Test.ImageAdapterConformance, image_adapter: ALLM.Test.Fixtures.ScriptedImageStub

  alias ALLM.Test.ImageAdapterConformance

  describe "harness meta-invariants" do
    test "the harness declares exactly N cases (case-count stability)" do
      assert ImageAdapterConformance.case_count() == 9
    end

    test "the harness macro raises KeyError when the :image_adapter opt is missing" do
      quoted =
        quote do
          defmodule __MODULE__.MissingImageAdapterOpt do
            use ExUnit.Case, async: true
            use ALLM.Test.ImageAdapterConformance, wrong_key: SomeModule
          end
        end

      assert_raise KeyError, fn ->
        Code.compile_quoted(quoted)
      end
    end
  end
end
