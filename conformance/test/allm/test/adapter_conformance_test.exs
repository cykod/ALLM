defmodule ALLM.Test.AdapterConformanceTest do
  @moduledoc """
  Self-test of `ALLM.Test.AdapterConformance` against
  `ALLM.Test.Fixtures.StubAdapter`.

  Also includes two meta-tests: a case-count stability guard and a
  missing-opt `KeyError` guard.
  """

  use ExUnit.Case, async: true
  use ALLM.Test.AdapterConformance, adapter: ALLM.Test.Fixtures.StubAdapter

  alias ALLM.Test.AdapterConformance

  describe "harness meta-invariants" do
    test "the harness declares exactly N cases (case-count stability)" do
      # Guards against silent case-count drift. Bump this alongside
      # ALLM.Test.AdapterConformance.@case_count when adding / removing
      # cases.
      assert AdapterConformance.case_count() == 13
    end

    test "the harness macro raises KeyError when the :adapter opt is missing" do
      # The harness does Keyword.fetch!/2 at quoted-expansion time.
      # Design said CompileError; Keyword.fetch!/2 actually raises
      # KeyError on OTP 27 — see retro 2026-04-23-batch3. The raw
      # KeyError propagates up through Code.compile_quoted/1 without
      # being wrapped.
      quoted =
        quote do
          defmodule __MODULE__.MissingAdapterOpt do
            use ExUnit.Case, async: true
            use ALLM.Test.AdapterConformance, wrong_key: SomeModule
          end
        end

      assert_raise KeyError, fn ->
        Code.compile_quoted(quoted)
      end
    end
  end
end
