defmodule ALLM.Test.ToolResultEncoderConformanceTest do
  @moduledoc """
  Self-test of `ALLM.Test.ToolResultEncoderConformance` against a local
  stub encoder defined inline. Same rationale as the executor self-test:
  the real default (`ALLM.ToolResultEncoder.JSON`) lives in the main
  `allm` package and is certified from there.
  """

  use ExUnit.Case, async: true

  # ---------------------------------------------------------------------------
  # Inline stub encoder — re-implements ALLM.ToolResultEncoder.JSON.
  # ---------------------------------------------------------------------------
  defmodule InlineStubEncoder do
    @moduledoc false
    @behaviour ALLM.ToolResultEncoder

    @impl true
    def encode(value) when is_binary(value), do: value
    def encode({:ok, inner}), do: Jason.encode!(%{ok: inner})
    def encode({:error, reason}) when is_binary(reason), do: Jason.encode!(%{error: reason})
    def encode({:error, reason}), do: Jason.encode!(%{error: inspect(reason)})
    def encode(value), do: Jason.encode!(value)
  end

  use ALLM.Test.ToolResultEncoderConformance, encoder: InlineStubEncoder

  alias ALLM.Test.ToolResultEncoderConformance

  describe "harness meta-invariants" do
    test "the harness declares exactly N cases (case-count stability)" do
      assert ToolResultEncoderConformance.case_count() == 9
    end

    test "the harness macro raises KeyError when the :encoder opt is missing" do
      quoted =
        quote do
          defmodule __MODULE__.MissingEncoderOpt do
            use ExUnit.Case, async: true
            use ALLM.Test.ToolResultEncoderConformance, wrong_key: SomeModule
          end
        end

      assert_raise KeyError, fn ->
        Code.compile_quoted(quoted)
      end
    end
  end
end
