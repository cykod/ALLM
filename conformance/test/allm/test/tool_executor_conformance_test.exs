defmodule ALLM.Test.ToolExecutorConformanceTest do
  @moduledoc """
  Self-test of `ALLM.Test.ToolExecutorConformance` against a local stub
  executor defined inline in this test file. The inline stub is a thin
  re-implementation of `ALLM.ToolExecutor.Default`'s invariants; it's
  scoped to the test file (not exported from `lib/`) because the real
  default lives in the main `allm` package and is certified from there.
  """

  use ExUnit.Case, async: true

  # ---------------------------------------------------------------------------
  # Inline stub executor (not exported; used only by the harness
  # self-test). Re-implements ALLM.ToolExecutor.Default's dispatch so we
  # can self-certify the harness without a dependency on the main
  # package's default module.
  # ---------------------------------------------------------------------------
  defmodule InlineStubExecutor do
    @moduledoc false
    @behaviour ALLM.ToolExecutor

    alias ALLM.Error.ToolError
    alias ALLM.Tool

    @impl true
    def execute(%Tool{handler: nil, name: name}, _args, _opts) do
      {:error, ToolError.new(:not_found, tool_name: name)}
    end

    def execute(%Tool{handler: handler, name: name}, args, opts)
        when is_function(handler, 1) or is_function(handler, 2) do
      result =
        if is_function(handler, 1), do: handler.(args), else: handler.(args, opts)

      validate_return(result, name)
    rescue
      e -> {:error, ToolError.new(:handler_raised, cause: e, tool_name: name)}
    catch
      :exit, reason ->
        {:error, ToolError.new(:handler_exit, cause: reason, tool_name: name)}

      :throw, value ->
        {:error, ToolError.new(:handler_raised, cause: {:throw, value}, tool_name: name)}
    end

    defp validate_return({:ok, _} = r, _n), do: r
    defp validate_return({:error, _} = r, _n), do: r
    defp validate_return({:ask_user, q} = r, _n) when is_binary(q), do: r

    defp validate_return({:ask_user, q, o} = r, _n)
         when is_binary(q) and is_list(o),
         do: r

    defp validate_return({:halt, reason, _} = r, _n) when is_atom(reason), do: r

    defp validate_return(other, name) do
      {:error, ToolError.new(:invalid_return, cause: other, tool_name: name)}
    end
  end

  use ALLM.Test.ToolExecutorConformance, executor: InlineStubExecutor

  alias ALLM.Test.ToolExecutorConformance

  describe "harness meta-invariants" do
    test "the harness declares exactly N cases (case-count stability)" do
      assert ToolExecutorConformance.case_count() == 11
    end

    test "the harness macro raises KeyError when the :executor opt is missing" do
      quoted =
        quote do
          defmodule __MODULE__.MissingExecutorOpt do
            use ExUnit.Case, async: true
            use ALLM.Test.ToolExecutorConformance, wrong_key: SomeModule
          end
        end

      assert_raise KeyError, fn ->
        Code.compile_quoted(quoted)
      end
    end
  end
end
