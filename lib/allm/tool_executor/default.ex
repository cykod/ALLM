defmodule ALLM.ToolExecutor.Default do
  @moduledoc """
  Default `ALLM.ToolExecutor` — invokes the tool's `:handler` function
  directly, dispatching on arity (1 or 2). Converts raises / exits /
  throws / invalid returns / nil handlers to `%ALLM.Error.ToolError{}`;
  passes handler-returned values (`{:ok, _}`, `{:error, _}`,
  `{:ask_user, _}`, `{:ask_user, _, _}`, `{:halt, _, _}`) through
  unchanged.

  ## Handler-originated vs. executor-originated errors

  This distinction is load-bearing for the orchestrator's
  `on_tool_error` policy. A handler that returns
  `{:error, :user_not_found}` has *reported* a failure — the
  orchestrator may surface that verbatim to the model. A handler that
  raises `RuntimeError` has *crashed* — the orchestrator wraps it in
  `%ALLM.Error.ToolError{reason: :handler_raised}` and applies its
  retry / abort policy. Converting every failure into the same
  `%ToolError{}` would erase the distinction; this executor deliberately
  does not.

  ## Arity dispatch

    * arity 1 — `handler.(arguments)`
    * arity 2 — `handler.(arguments, opts)` where `opts` is the call
      context keyword list (`:context`, `:session_id`, `:request_id`,
      `:tool_call`, `:engine`; missing keys read as `nil`).

  Handlers of other arities raise `ArgumentError`; non-function handlers
  (e.g., `{Module, :function}` MFA tuples, reserved for a future
  enhancement) raise `FunctionClauseError` — the honest failure mode
  until v0.3 extends the dispatch.

  ## Usage

  Used automatically when `engine.tool_executor` is `nil`; the call
  site resolves to this module via
  `engine.tool_executor || ALLM.ToolExecutor.Default`.

  ## Scope

  Synchronous, no retries, no timeouts. `ALLM.ToolRunner` layers parallel
  execution and per-tool timeouts on top.
  """

  @behaviour ALLM.ToolExecutor

  alias ALLM.Error.ToolError
  alias ALLM.Tool

  @doc """
  Invoke a tool's handler and return its result.

  See the module doc for the handler-originated-vs-executor-originated
  error distinction and the arity dispatch rules.

  ## Examples

      iex> tool = ALLM.Tool.new(name: "echo", description: "", schema: %{}, handler: fn args -> {:ok, args} end)
      iex> ALLM.ToolExecutor.Default.execute(tool, %{"x" => 1}, [])
      {:ok, %{"x" => 1}}
  """
  @impl true
  @spec execute(Tool.t(), map(), keyword()) :: Tool.handler_result()
  def execute(%Tool{handler: nil, name: name}, _arguments, _opts) do
    {:error, ToolError.new(:not_found, tool_name: name)}
  end

  def execute(%Tool{handler: handler, name: name} = _tool, arguments, opts) do
    # Validate handler shape *before* the try/rescue so arity / non-function
    # errors propagate to the caller (they're programmer errors, not handler
    # crashes). `:erlang.fun_info(handler, :arity)` raises `FunctionClauseError`
    # for non-function terms (e.g., MFA tuples reserved for v0.3+). Arity-3+
    # funs raise `ArgumentError` here.
    invoker = invoker_for(handler)

    try do
      invoker.(handler, arguments, opts) |> validate_return(name)
    rescue
      e -> {:error, ToolError.new(:handler_raised, cause: e, tool_name: name)}
    catch
      :exit, reason ->
        {:error, ToolError.new(:handler_exit, cause: reason, tool_name: name)}

      :throw, value ->
        {:error, ToolError.new(:handler_raised, cause: {:throw, value}, tool_name: name)}
    end
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  # Pick the invoker function based on handler arity. Runs outside the
  # caller's try/rescue so invalid-shape errors surface to the caller as
  # programmer errors, not handler crashes:
  #
  #   * arity-1 fun → arity-1 invoker
  #   * arity-2 fun → arity-2 invoker
  #   * fun of any other arity → `ArgumentError`
  #   * non-function handler (e.g., `{Module, :function}` MFA tuple, reserved
  #     for a future enhancement) → `FunctionClauseError` (no clause matches).
  defp invoker_for(handler) when is_function(handler, 1),
    do: fn h, args, _opts -> h.(args) end

  defp invoker_for(handler) when is_function(handler, 2),
    do: fn h, args, opts -> h.(args, opts) end

  defp invoker_for(handler) when is_function(handler) do
    {:arity, arity} = :erlang.fun_info(handler, :arity)
    raise ArgumentError, "tool handler must have arity 1 or 2, got: #{arity}"
  end

  # Validate the handler's return against `t:ALLM.Tool.handler_result/0`.
  # The five legal shapes pass through unchanged; everything else becomes
  # a `%ToolError{reason: :invalid_return, cause: value}`.
  defp validate_return({:ok, _} = result, _name), do: result
  defp validate_return({:error, _} = result, _name), do: result
  defp validate_return({:ask_user, question} = result, _name) when is_binary(question), do: result

  defp validate_return({:ask_user, question, opts} = result, _name)
       when is_binary(question) and is_list(opts),
       do: result

  defp validate_return({:halt, reason, _value} = result, _name) when is_atom(reason), do: result

  defp validate_return(other, name) do
    {:error, ToolError.new(:invalid_return, cause: other, tool_name: name)}
  end
end
