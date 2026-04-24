defmodule ALLM.Test.StreamAdapterConformanceTest do
  @moduledoc """
  Self-test of `ALLM.Test.StreamAdapterConformance` against
  `ALLM.Test.Fixtures.StubAdapter`.

  Exercises the stub's `stream/2` + `Stream.resource/3` cleanup path
  (the halt-safety case uses the `:counters`-backed observer).
  """

  use ExUnit.Case, async: true

  use ALLM.Test.StreamAdapterConformance,
    stream_adapter: ALLM.Test.Fixtures.StubAdapter

  alias ALLM.Test.StreamAdapterConformance

  describe "harness meta-invariants" do
    test "the harness declares exactly N cases (case-count stability)" do
      assert StreamAdapterConformance.case_count() == 14
    end

    test "the harness macro raises KeyError when the :stream_adapter opt is missing" do
      quoted =
        quote do
          defmodule __MODULE__.MissingStreamAdapterOpt do
            use ExUnit.Case, async: true
            use ALLM.Test.StreamAdapterConformance, wrong_key: SomeModule
          end
        end

      assert_raise KeyError, fn ->
        Code.compile_quoted(quoted)
      end
    end
  end
end
