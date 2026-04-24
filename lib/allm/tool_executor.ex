defmodule ALLM.ToolExecutor do
  @moduledoc """
  Tool-handler invocation contract. See spec §7.3 and §5.2.

  `execute/3` takes a `%ALLM.Tool{}`, the parsed arguments map, and a
  keyword opts list carrying call context (`:context`, `:session_id`,
  `:request_id`, `:tool_call`, `:engine`). It invokes the tool's handler
  and returns the handler's return value unchanged — with two exceptions
  that belong to the executor, not the handler:

    1. A handler raise / exit / throw / bad return is converted to
       `{:error, %ALLM.Error.ToolError{}}` with a `:reason` atom drawn
       from the closed set
       `:handler_raised | :handler_exit | :timeout | :invalid_return |
       :encoding_failed | :not_found`.

    2. A `nil` handler (the `%Tool{}` was declared for manual-mode use)
       is converted to `{:error, %ALLM.Error.ToolError{reason: :not_found}}` —
       the executor cannot invoke a tool with no handler.

  Handler-returned `{:error, _}` values are **NOT** converted; they pass
  through unchanged so the orchestrator can pattern-match on them
  (`on_tool_error` policy, spec §12.3 / §30). The distinction is "did the
  handler crash, or did it report a failure?" — both are failures, but
  the orchestrator handles them differently.

  ## Invariants

    1. `execute/3` receives a `%Tool{}` whose `name` was looked up by the
       caller; executors do not consult a registry.
    2. `execute/3` returns one of the five `t:ALLM.Tool.handler_result/0`
       variants unchanged for handler-returned values; executor-originated
       failures are `{:error, %ToolError{}}` structs.
    3. `opts` is populated by the caller; executors do not synthesize
       `:session_id` / `:request_id` / etc. Missing keys read as `nil`
       when the executor forwards them to an arity-2 handler.
    4. Handler arity dispatch: `:erlang.fun_info(handler, :arity)` — `1`
       calls `handler.(arguments)`; `2` calls `handler.(arguments, opts)`.
       Any other arity is an invalid handler and raises `ArgumentError`
       from the executor.

  ## Handler result shapes

  The five legal handler-returned shapes (spec §5.2):

    * `{:ok, value}` — success; `value` is handed to the
      `ALLM.ToolResultEncoder`.
    * `{:error, reason}` — handler-originated failure; passes through
      unchanged for `on_tool_error` dispatch.
    * `{:ask_user, question}` — suspend the loop and surface a question
      to the user (spec §12.3).
    * `{:ask_user, question, opts}` — same, with caller-supplied options.
    * `{:halt, reason, result}` — halt the loop with a handler-declared
      terminal result.
  """

  @doc """
  Invoke a tool's handler and return its result.

  ## Executor-originated error reasons

  The following `%ToolError{reason: ...}` atoms are produced by the
  executor itself (not by handlers). Handler-returned `{:error, reason}`
  tuples pass through unchanged and do NOT carry these atoms.

  | Reason | Fires when |
  |--------|------------|
  | `:handler_raised` | Handler raised an exception; `:cause` carries the exception struct. Throws are also normalized here with `cause: {:throw, value}`. |
  | `:handler_exit` | Handler called `exit/1` or the handling process died; `:cause` carries the exit reason term. |
  | `:timeout` | Emitted by Phase 6's `ALLM.ToolRunner` under `tool_timeout`. The Phase 3 default executor does not produce this directly — conformance tests that need it use a handler that returns the struct. |
  | `:invalid_return` | Handler returned a value that is not one of the five `handler_result()` variants; `:cause` carries the offending term. |
  | `:not_found` | The `%Tool{}` has `handler: nil` — the tool is not executable by this executor (typically declared for manual-mode use). |
  | `:encoding_failed` | Reserved for encoders; executors do not produce this reason. |
  """
  @callback execute(ALLM.Tool.t(), map(), keyword()) :: ALLM.Tool.handler_result()
end
