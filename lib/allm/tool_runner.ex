defmodule ALLM.ToolRunner do
  @moduledoc """
  > #### Internal {: .warning}
  >
  > This module is internal — it's documented for transparency, but call
  > sites should use `ALLM.step/3` / `ALLM.stream_step/3` instead.

  Executes a list of `%ALLM.ToolCall{}` values via the engine's tool
  executor, encodes results via the tool result encoder, and returns
  either:

    * a list of `:tool`-role `%ALLM.Message{}` values (non-streaming), or
    * a lazy stream of `ALLM.Event` values (streaming).

  Both variants share execution logic: parallel dispatch via
  `Task.async_stream/5`, per-tool timeout, and the `on_tool_error`
  policy.

  ## Result ordering

    * `run_tool_calls/3` emits messages in `tool_calls` **input order**
      — results are sorted by input index before returning.
    * `stream_tool_calls/3` emits events in **completion order**
      (`Task.async_stream/5` with `ordered: false`).

  The SET of messages is identical across both paths when compared after
  sorting by `:tool_call_id`; only the emission ordering differs.

  ## Sibling drain on halt

  When a handler returns `{:halt, _, _}` or `{:ask_user, _, _}` — or when
  `on_tool_error: :halt` fires on a failure — the runner continues
  reducing `Task.async_stream/5` until it naturally exhausts. Completed
  siblings still emit their results; the first-observed halt wins for
  the returned `halt_metadata`.

  ## Error policy

  `opts[:on_tool_error]` is one of:

    * `:continue` (default) — the error is encoded as the tool-result
      content and the batch proceeds normally.
    * `:halt` — the batch drains to completion and the final return is
      `{:ok, msgs, halt_metadata}` with `halted_reason: :tool_error`.
    * `(ToolCall.t, term -> {:continue, term} | :halt)`
      called synchronously inside the per-tool task with the failing
      tool call and the error term. `{:continue, replacement}` encodes
      `replacement` via the encoder as the tool-result content;
      `:halt` halts the batch as if the atom form had been supplied.
      A function that raises or returns an invalid shape is wrapped
      as `%ToolError{reason: :invalid_return}` and routed as `:halt`
      WITHOUT re-invoking the function (recursion-avoidance).

  ## Function-form semantics

  Inside the per-tool `Task.async_stream/5` task, the runner resolves
  the function's return to a concrete `:continue` / `:halt` decision
  FIRST, then delegates to the same `route_error/3` path used for
  atom-form `on_tool_error`. The function reference is dropped from
  the dispatch context before the delegated call, so a re-entry with
  the same function is impossible.

  ## Reserved halt atoms

  The following atoms are reserved as orchestrator-owned halt reasons
  and MUST NOT be used by handlers in `{:halt, reason, _}` returns:
  `:ask_user`, `:max_turns`, `:halt_when`, `:tool_error`, `:cancelled`,
  `:completed`. A handler that returns one is wrapped as
  `%ToolError{reason: :invalid_return, metadata: %{reserved_halt_atom: r}}`
  and routed via `on_tool_error`.
  """

  alias ALLM.{Engine, Event, Message, Tool, ToolCall}
  alias ALLM.Error.{EngineError, ToolError}

  @default_tool_timeout 30_000
  @awaiting_user_response "<awaiting user response>"

  # Reserved halt reasons that handlers MUST NOT reuse. A meta-test
  # asserts this attribute equals the documented set so future
  # changes trigger a test failure on import.
  @reserved_halt_atoms [:ask_user, :max_turns, :halt_when, :tool_error, :cancelled, :completed]

  @type on_tool_error ::
          :continue
          | :halt
          | (ToolCall.t(), error_term :: term() -> {:continue, term()} | :halt)

  @type run_opts :: [
          engine: Engine.t() | nil,
          context: map(),
          request_id: String.t() | nil,
          session_id: String.t() | nil,
          tool_executor: module() | nil,
          tool_result_encoder: module() | nil,
          on_tool_error: on_tool_error(),
          tool_timeout: timeout(),
          max_concurrency: pos_integer()
        ]

  @type ask_user_metadata :: %{
          halted_reason: :ask_user,
          pending_question: String.t(),
          pending_tool_call_id: String.t(),
          ask_user_opts: keyword()
        }

  @type tool_halt_metadata :: %{
          halted_reason: atom(),
          halt_tool_call_id: String.t(),
          halt_result: term()
        }

  @type tool_error_halt_metadata :: %{
          required(:halted_reason) => :tool_error,
          required(:halt_tool_call_id) => String.t(),
          optional(:on_tool_error_exception) => Exception.t()
        }

  @type halt_metadata :: ask_user_metadata() | tool_halt_metadata() | tool_error_halt_metadata()

  @type run_outcome ::
          {:ok, [Message.t()]}
          | {:ok, [Message.t()], halt_metadata()}
          | {:error, EngineError.t()}

  @doc """
  Execute a batch of tool calls synchronously and return `:tool`-role
  messages in input order.

  Pre-flights the batch by looking up each `%ToolCall{}` name against
  `tools`; if any lookup fails the function returns
  `{:error, %ALLM.Error.EngineError{reason: :unknown_tool}}`
  synchronously and no tool runs. An empty `tool_calls` list is a
  short-circuit: `{:ok, []}`.

  ## Opts

  | Key | Default | Purpose |
  |-----|---------|---------|
  | `:engine` | `nil` | Engine for context / executor / encoder fallback. |
  | `:tool_executor` | `engine.tool_executor \\|\\| ALLM.ToolExecutor.Default` | Override the executor module. |
  | `:tool_result_encoder` | `engine.tool_result_encoder \\|\\| ALLM.ToolResultEncoder.JSON` | Override the encoder module. |
  | `:on_tool_error` | `:continue` | `:continue`, `:halt`, or `(tool_call, error -> {:continue, term} \| :halt)`. |
  | `:tool_timeout` | `30_000` | Milliseconds before `Task.async_stream/5` kills a task. Timed-out tasks surface as `%ToolError{reason: :timeout}`. |
  | `:max_concurrency` | `max(1, min(length(tool_calls), System.schedulers_online * 2))` | Upper bound on concurrent handler invocations. |
  | `:context` | `engine.context` | Passed to arity-2 handlers. |
  | `:session_id` | `nil` | Threaded from `ALLM.Session` so handler context can correlate. |
  | `:request_id` | `nil` | Forwarded from the adapter's `Response.request_id`. |

  ## Error reason table

  | Condition | Return |
  |-----------|--------|
  | One tool call's `name` is not in `tools` | `{:error, %EngineError{reason: :unknown_tool, metadata: %{tool_name: name}}}` |
  | Encoder raises `Protocol.UndefinedError` / `Jason.EncodeError` | Wrapped as `%ToolError{reason: :encoding_failed}` and routed via `on_tool_error` |
  | Handler raises / exits / returns an invalid shape | `%ToolError{reason: :handler_raised \\| :handler_exit \\| :invalid_return}` (from the executor) routed via `on_tool_error` |
  | Handler exceeds `tool_timeout` | `%ToolError{reason: :timeout}` routed via `on_tool_error` |
  | `on_tool_error` is a function returning `{:continue, replacement}` | `replacement` encoded as tool-result content; batch continues. |
  | `on_tool_error` is a function returning `:halt` | Batch drains; final return `{:ok, msgs, %{halted_reason: :tool_error, halt_tool_call_id: id}}`. When the function form raises, the captured exception is also lifted into halt_metadata as `:on_tool_error_exception`. |
  | `on_tool_error` function returns invalid shape / raises | Wrapped as `%ToolError{reason: :invalid_return}`; routed as `:halt`. Function NOT re-invoked. |
  | `on_tool_error` is a function of arity ≠ 2 | Raises `ArgumentError` at `run_tool_calls/3` entry. |

  ## Examples

      iex> engine = ALLM.Engine.new(adapter: ALLM.Providers.Fake)
      iex> tool = ALLM.Tool.new(
      ...> name: "echo",
      ...> description: "",
      ...> schema: %{},
      ...> handler: fn args -> {:ok, args} end
      ...>)
      iex> call = ALLM.ToolCall.new(id: "c0", name: "echo", arguments: %{"x" => 1})
      iex> {:ok, [msg]} = ALLM.ToolRunner.run_tool_calls([call], [tool], engine: engine)
      iex> msg.role
      :tool
      iex> msg.tool_call_id
      "c0"
      iex> Jason.decode!(msg.content)
      %{"x" => 1}
  """
  @spec run_tool_calls([ToolCall.t()], [Tool.t()], run_opts()) :: run_outcome()
  def run_tool_calls(tool_calls, tools, opts)
      when is_list(tool_calls) and is_list(tools) and is_list(opts) do
    # Validate on_tool_error shape BEFORE any execution (see PHASE_6_DESIGN.md
    # Non-obvious Decision #3 — function form rejected until Phase 7).
    :ok = validate_on_tool_error!(Keyword.get(opts, :on_tool_error, :continue))

    case tool_calls do
      # Empty-list short-circuit (Invariant 9 / Non-obvious Decision #8 Finding
      # F10): Task.async_stream/5 raises ArgumentError on max_concurrency: 0.
      [] ->
        {:ok, []}

      _ ->
        with :ok <- preflight_unknown_tools(tool_calls, tools) do
          ctx = build_ctx(tool_calls, tools, opts)
          outcomes = run_batch(tool_calls, ctx)
          finalize_run_outcome(outcomes)
        end
    end
  end

  @doc """
  Execute a batch of tool calls and return a lazy stream of
  `ALLM.Event` values. Events per tool call (in start order for each
  id, interleaved across ids in completion order):

    * `{:tool_execution_started, %{id, name, arguments}}`
    * `{:tool_execution_completed, %{id, name, result}}`
    * One of:
      * `{:tool_result_encoded, %{id, content}}` — normal handler return
        (including `{:error, _}` routed via `on_tool_error`)
      * `{:ask_user_requested, %{tool_call_id, tool_name, question, opts}}`
        handler returned `{:ask_user, _}` / `{:ask_user, _, _}`
      * `{:tool_halt, %{tool_call_id, reason, result}}` — handler returned
        `{:halt, reason, result}`

  ## Pre-flight errors

  On unknown tool (Invariant 2), the stream contains a single
  `{:error, %ALLM.Error.EngineError{reason: :unknown_tool}}` element
  and terminates. No tools execute.

  ## Timeout semantics

  A tool whose handler exceeds `tool_timeout` has its task killed by
  `Task.async_stream/5`'s `:on_timeout: :kill_task` option. The event
  stream emits `{:tool_execution_completed, %{result: {:error,
  %ToolError{reason: :timeout}}}}` — no new `:tool_execution_cancelled`
  variant (the `ALLM.Event` closed union stays at 16 tags).

  ## Empty short-circuit

  `stream_tool_calls([], _, _)` returns `Stream.concat([])` — an empty
  enumerable — without invoking `Task.async_stream/5`.

  ## Examples

      iex> engine = ALLM.Engine.new(adapter: ALLM.Providers.Fake)
      iex> tool = ALLM.Tool.new(
      ...> name: "echo",
      ...> description: "",
      ...> schema: %{},
      ...> handler: fn args -> {:ok, args} end
      ...>)
      iex> call = ALLM.ToolCall.new(id: "c0", name: "echo", arguments: %{"x" => 1})
      iex> events =
      ...> [call]
      ...> |> ALLM.ToolRunner.stream_tool_calls([tool], engine: engine)
      ...> |> Enum.to_list
      iex> Enum.map(events, &elem(&1, 0))
      [:tool_execution_started, :tool_execution_completed, :tool_result_encoded]
  """
  @spec stream_tool_calls([ToolCall.t()], [Tool.t()], run_opts()) :: Enumerable.t()
  def stream_tool_calls(tool_calls, tools, opts)
      when is_list(tool_calls) and is_list(tools) and is_list(opts) do
    :ok = validate_on_tool_error!(Keyword.get(opts, :on_tool_error, :continue))

    case tool_calls do
      [] ->
        # Empty-list short-circuit (Invariant 9) — no Task.async_stream/5.
        Stream.concat([])

      _ ->
        case preflight_unknown_tools(tool_calls, tools) do
          :ok ->
            build_event_stream(tool_calls, tools, opts)

          {:error, %EngineError{}} = err ->
            # Single-element degenerate stream: one {:error, _} element then EOS.
            Stream.concat([[err]])
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Pre-flight / validation
  # ---------------------------------------------------------------------------

  @doc false
  # Test-only accessor for the reserved-atom attribute (see spec §5.2).
  # Surfaced via @doc false so a meta-test can assert the attribute equals
  # exactly the spec-defined set.
  @spec __reserved_halt_atoms__() :: [atom()]
  def __reserved_halt_atoms__, do: @reserved_halt_atoms

  # Validate `on_tool_error`. Phase 7: function form must be arity 2.
  defp validate_on_tool_error!(policy)
       when policy in [:continue, :halt] or is_nil(policy),
       do: :ok

  defp validate_on_tool_error!(fun) when is_function(fun, 2), do: :ok

  defp validate_on_tool_error!(fun) when is_function(fun) do
    raise ArgumentError,
          "on_tool_error function form must accept (tool_call, error) — arity 2; " <>
            "got function of arity #{:erlang.fun_info(fun)[:arity]}"
  end

  defp validate_on_tool_error!(other) do
    raise ArgumentError,
          "on_tool_error must be :continue, :halt, or a function of arity 2 " <>
            "with signature (tool_call, error), got: #{inspect(other)}"
  end

  # Walk the tool calls once; return `:ok` when every name resolves, or
  # `{:error, %EngineError{reason: :unknown_tool}}` naming the first miss.
  # See PHASE_6_DESIGN.md Invariant 2 / Non-obvious Decision #4.
  defp preflight_unknown_tools(tool_calls, tools) do
    Enum.reduce_while(tool_calls, :ok, fn %ToolCall{name: name}, :ok ->
      case find_tool(tools, name) do
        nil ->
          err =
            EngineError.new(:unknown_tool,
              message: "tool #{name} not in engine.tools",
              metadata: %{tool_name: name}
            )

          {:halt, {:error, err}}

        %Tool{} ->
          {:cont, :ok}
      end
    end)
  end

  defp find_tool(tools, name), do: Enum.find(tools, fn %Tool{name: n} -> n == name end)

  # ---------------------------------------------------------------------------
  # Shared execution context + batch driver
  # ---------------------------------------------------------------------------

  # Gather all dispatch-time values once so both streaming and non-streaming
  # paths share the same state record.
  defp build_ctx(tool_calls, tools, opts) do
    %{
      executor: resolve_executor(opts),
      encoder: resolve_encoder(opts),
      engine: Keyword.get(opts, :engine),
      on_tool_error: Keyword.get(opts, :on_tool_error, :continue),
      timeout: Keyword.get(opts, :tool_timeout, @default_tool_timeout),
      max_concurrency: compute_max_concurrency(tool_calls, opts),
      tools: tools,
      opts: opts
    }
  end

  # Run the whole batch and return a list of 3-tuples `{index, tool_call,
  # dispatch}` in completion order (non-streaming path sorts by index
  # before finalising; streaming path flat-maps events as they arrive).
  defp run_batch(tool_calls, ctx) do
    tool_calls
    |> Enum.with_index()
    |> Task.async_stream(
      fn {tc, idx} -> run_one_indexed(tc, idx, ctx) end,
      ordered: false,
      max_concurrency: ctx.max_concurrency,
      timeout: ctx.timeout,
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> Enum.map(&normalize_task_element(&1, ctx))
  end

  defp run_one_indexed(%ToolCall{} = tc, idx, ctx) do
    tool = find_tool(ctx.tools, tc.name)

    # Phase 9.2: wrap per-tool execution in `ALLM.Telemetry.span(:tool, ...)`.
    # The span fires INSIDE the per-tool worker process so `:duration`
    # reflects only this tool's execution and the auto-exception trap
    # captures only this tool's raise (Phase 9 design Decision #9). The
    # parent's `normalize_task_element/2` synthesises the `:exception`
    # event for timeout-killed tasks because the closure can't trap a
    # kill signal from outside the worker.
    start_metadata = %{
      tool: tool,
      tool_call: tc,
      engine: ctx.engine,
      model: tool_span_model(ctx.engine),
      request_id: Keyword.get(ctx.opts, :request_id)
    }

    dispatch =
      ALLM.Telemetry.span(:tool, start_metadata, fn ->
        result = execute_one_tool(tc, tool, ctx)
        {result, %{result: result}}
      end)

    {idx, tc, dispatch}
  end

  # Phase 9.2 fix-pass (review Finding #4): include `:model` on the
  # `:tool` span metadata for parity with `:generate | :stream | :step |
  # :chat` spans (Phase 9 design Decision #3 / DoD line 737). The model
  # is always reachable via `meta.engine.model`, but lifting it to a
  # top-level key matches the documented common-metadata contract so
  # consumers don't have to special-case the `:tool` shape.
  defp tool_span_model(%Engine{model: model}), do: model
  defp tool_span_model(_), do: nil

  # Convert a Task.async_stream/5 stream element into the canonical
  # `{index, tool_call, dispatch}` shape. `zip_input_on_exit: true` gives
  # us the original input `{tc, idx}` on timeout / exit.
  defp normalize_task_element({:ok, {idx, tc, dispatch}}, _ctx), do: {idx, tc, dispatch}

  defp normalize_task_element({:exit, {{%ToolCall{} = tc, idx}, :timeout}}, ctx) do
    # Phase 9.2: synthesise `[:allm, :tool, :exception]` because the
    # per-tool span's auto-trap can't fire — `Task.async_stream/5`'s
    # `:on_timeout: :kill_task` killed the worker externally before the
    # closure reached its `:stop` arm. `:duration` is `0` because the
    # precise per-task duration is unrecoverable post-kill (Phase 9
    # design Decision #9 + Phase 9.2 implementation note).
    tool = find_tool(ctx.tools, tc.name)

    ALLM.Telemetry.execute([:tool, :exception], %{duration: 0}, %{
      tool: tool,
      tool_call: tc,
      engine: ctx.engine,
      model: tool_span_model(ctx.engine),
      request_id: Keyword.get(ctx.opts, :request_id),
      kind: :exit,
      reason: :timeout,
      stacktrace: []
    })

    err = ToolError.new(:timeout, tool_name: tc.name, tool_call_id: tc.id)
    dispatch = route_error(err, tc, ctx)
    {idx, tc, dispatch}
  end

  defp normalize_task_element({:exit, {{%ToolCall{} = tc, idx}, reason}}, ctx) do
    err = ToolError.new(:handler_exit, tool_name: tc.name, tool_call_id: tc.id, cause: reason)
    dispatch = route_error(err, tc, ctx)
    {idx, tc, dispatch}
  end

  # Reduce raw dispatch outcomes into the final `run_outcome()`:
  # returned message list is sorted by INPUT index; halt metadata is kept
  # for the earliest halting index (first-halt-wins per Invariant 3).
  defp finalize_run_outcome(results) do
    sorted = Enum.sort_by(results, fn {idx, _tc, _d} -> idx end)
    {rev_msgs, halt} = Enum.reduce(sorted, {[], nil}, &reduce_dispatch/2)
    msgs = Enum.reverse(rev_msgs)

    case halt do
      nil -> {:ok, msgs}
      {_idx, meta} -> {:ok, msgs, meta}
    end
  end

  defp reduce_dispatch({_idx, _tc, {:continue, msg, _extra}}, {acc, halt_acc}) do
    {[msg | acc], halt_acc}
  end

  defp reduce_dispatch({idx, _tc, {:halt, msg, extra}}, {acc, halt_acc}) do
    {[msg | acc], keep_earliest_halt(halt_acc, idx, extra.halt_metadata)}
  end

  # First-halt-wins: retain the earliest input-index halt_metadata.
  defp keep_earliest_halt(nil, idx, meta), do: {idx, meta}
  defp keep_earliest_halt({seen_idx, _} = kept, idx, _meta) when seen_idx <= idx, do: kept
  defp keep_earliest_halt(_other, idx, meta), do: {idx, meta}

  # ---------------------------------------------------------------------------
  # Streaming path
  # ---------------------------------------------------------------------------

  # Build a lazy stream that drives Task.async_stream/5 and flat-maps each
  # completed task into a small list of events (3 per tool call).
  defp build_event_stream(tool_calls, tools, opts) do
    ctx = build_ctx(tool_calls, tools, opts)

    tool_calls
    |> Enum.with_index()
    |> Task.async_stream(
      fn {tc, idx} -> run_one_indexed(tc, idx, ctx) end,
      ordered: false,
      max_concurrency: ctx.max_concurrency,
      timeout: ctx.timeout,
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> Stream.flat_map(fn element ->
      {_idx, tc, dispatch} = normalize_task_element(element, ctx)
      events_for_dispatch(tc, dispatch)
    end)
  end

  # Given a %ToolCall{} and a dispatch outcome, build the 3-event trio
  # (started / completed / encoded-or-halt-or-ask-user).
  defp events_for_dispatch(%ToolCall{} = tc, {_continue_or_halt, _msg, extra}) do
    started = Event.tool_execution_started(tc.id, tc.name, tc.arguments || %{})
    completed = Event.tool_execution_completed(tc.id, tc.name, extra.raw_result)

    tail =
      case extra.terminal do
        {:encoded, content} ->
          Event.tool_result_encoded(tc.id, content)

        {:ask_user, question, user_opts} ->
          Event.ask_user_requested(tc.id, tc.name, question, user_opts)

        {:halt, reason, result, content} ->
          # Phase 7.6 cleanup B1: 4-tuple variant carries the encoded
          # `content` so the `StreamCollector` :tool_halt fold can populate
          # `state.tool_results` without an encoder.
          Event.tool_halt(tc.id, reason, result, content)
      end

    [started, completed, tail]
  end

  # ---------------------------------------------------------------------------
  # Per-tool execution (shared helper)
  # ---------------------------------------------------------------------------

  # Execute one tool: call executor, dispatch on handler-return shape,
  # encode the result, and return a dispatch tuple:
  #
  #   {:continue, %Message{}, extra}
  #   {:halt, %Message{}, extra}
  #
  # `extra` carries the raw result (for :tool_execution_completed) and
  # the terminal shape (for the event trio's third element). When the
  # dispatch is `:halt`, `extra.halt_metadata` carries the
  # `halt_metadata()` struct to be surfaced in the final run_outcome.
  @spec execute_one_tool(ToolCall.t(), Tool.t(), map()) ::
          {:continue | :halt, Message.t(), map()}
  defp execute_one_tool(%ToolCall{} = tc, %Tool{} = tool, %{} = ctx) do
    handler_opts = build_handler_opts(ctx.engine, ctx.opts, tc)
    result = ctx.executor.execute(tool, tc.arguments || %{}, handler_opts)
    dispatch_handler_return(result, tc, ctx)
  end

  # Dispatch on the five spec §5.2 handler return shapes plus the
  # executor-wrapped `%ToolError{}` path.
  defp dispatch_handler_return({:ok, value}, %ToolCall{} = tc, ctx) do
    case encode_value(ctx.encoder, value, tc) do
      {:ok, content} ->
        {:continue, tool_msg(tc.id, content),
         %{raw_result: {:ok, value}, terminal: {:encoded, content}}}

      {:error, %ToolError{} = encoding_err} ->
        # Encoder raised — route through on_tool_error (see Non-obvious
        # Decision #3).
        route_error(encoding_err, tc, ctx)
    end
  end

  defp dispatch_handler_return({:error, %ToolError{} = err}, %ToolCall{} = tc, ctx) do
    # Executor-wrapped error (handler raised, exit, invalid_return, not_found).
    route_error(err, tc, ctx)
  end

  defp dispatch_handler_return({:error, reason}, %ToolCall{} = tc, ctx) do
    route_error(reason, tc, ctx)
  end

  defp dispatch_handler_return({:ask_user, question}, %ToolCall{} = tc, _ctx)
       when is_binary(question) do
    handle_ask_user(tc, question, [])
  end

  defp dispatch_handler_return({:ask_user, question, user_opts}, %ToolCall{} = tc, _ctx)
       when is_binary(question) and is_list(user_opts) do
    handle_ask_user(tc, question, user_opts)
  end

  # Reserved halt atoms (spec §5.2) — must not be reused by handlers. Wrap
  # as %ToolError{reason: :invalid_return} so on_tool_error decides whether
  # to encode-and-continue or halt. Ordered BEFORE the general clause.
  defp dispatch_handler_return({:halt, reason, _result}, %ToolCall{} = tc, ctx)
       when reason in @reserved_halt_atoms do
    err =
      ToolError.new(:invalid_return,
        tool_name: tc.name,
        tool_call_id: tc.id,
        message:
          "handler returned {:halt, #{inspect(reason)}, _}; #{inspect(reason)} is reserved " <>
            "(spec §5.2) — pick a non-reserved atom",
        metadata: %{reserved_halt_atom: reason}
      )

    route_error(err, tc, ctx)
  end

  defp dispatch_handler_return({:halt, reason, result}, %ToolCall{} = tc, ctx)
       when is_atom(reason) do
    # Spec §5.2: encode `result` as the tool-result content (see spec §30).
    case encode_value(ctx.encoder, result, tc) do
      {:ok, content} ->
        # Phase 7.6 cleanup B1: pass the encoded `content` through the
        # terminal tuple so `events_for_dispatch/2` builds a `:tool_halt`
        # event whose payload carries `:content`. The `StreamCollector`
        # `:tool_halt` fold then appends the sentinel tool message to
        # `state.tool_results` without re-running the encoder.
        {:halt, tool_msg(tc.id, content),
         %{
           raw_result: {:halt, reason, result},
           terminal: {:halt, reason, result, content},
           halt_metadata: %{
             halted_reason: reason,
             halt_tool_call_id: tc.id,
             halt_result: result
           }
         }}

      {:error, %ToolError{} = encoding_err} ->
        # Encoder failure on halt result — route via on_tool_error.
        route_error(encoding_err, tc, ctx)
    end
  end

  defp dispatch_handler_return(other, %ToolCall{} = tc, ctx) do
    # Belt-and-suspenders for custom executors that return outside the five
    # shapes (the default executor wraps invalid returns in %ToolError{}).
    err = ToolError.new(:invalid_return, tool_name: tc.name, tool_call_id: tc.id, cause: other)
    route_error(err, tc, ctx)
  end

  # Common path for `{:ask_user, _}` / `{:ask_user, _, _}` — emit a halt
  # tuple (drain-to-completion semantics) with "<awaiting user response>"
  # as the tool-result content (spec §12.3 step 1).
  defp handle_ask_user(%ToolCall{} = tc, question, user_opts) do
    {:halt, tool_msg(tc.id, @awaiting_user_response),
     %{
       raw_result: {:ask_user, question, user_opts},
       terminal: {:ask_user, question, user_opts},
       halt_metadata: %{
         halted_reason: :ask_user,
         pending_question: question,
         pending_tool_call_id: tc.id,
         ask_user_opts: user_opts
       }
     }}
  end

  # Route an error term through the `on_tool_error` policy.
  # Function form: invoke synchronously inside the task, resolve the
  # return value to a concrete `:continue` / `:halt` decision FIRST,
  # then construct a ctx_for_halt with the function reference DROPPED
  # and delegate to the atom-form branch — single-invocation guarantee
  # (Phase 7 design Non-obvious Decision #8).
  defp route_error(err, %ToolCall{} = tc, %{on_tool_error: fun} = ctx) when is_function(fun, 2) do
    raw_err =
      case err do
        %ToolError{} = struct -> {:error, struct}
        other -> {:error, other}
      end

    invoke_on_tool_error(fun, tc, err, raw_err, ctx)
  end

  defp route_error(err, %ToolCall{} = tc, ctx) do
    content = encode_error(ctx.encoder, err)

    raw_result =
      case err do
        %ToolError{} = struct -> {:error, struct}
        other -> {:error, other}
      end

    case ctx.on_tool_error do
      :halt ->
        # Phase 7.6 cleanup B3: emit `terminal: {:halt, :tool_error, err,
        # content}` so `events_for_dispatch/2` produces a `:tool_halt`
        # event (was `:tool_result_encoded`). Without this, the streaming
        # `StreamCollector` / `Chat.stream/3` Phase B never observe a halt
        # and the chat loop runs to `max_turns`.
        {:halt, tool_msg(tc.id, content),
         %{
           raw_result: raw_result,
           terminal: {:halt, :tool_error, err, content},
           halt_metadata: build_tool_error_halt_metadata(tc, err)
         }}

      _continue ->
        {:continue, tool_msg(tc.id, content),
         %{raw_result: raw_result, terminal: {:encoded, content}}}
    end
  end

  # Build the `tool_error_halt_metadata` for a `:tool_error` halt.
  #
  # Lifts `:on_tool_error_exception` from the wrapped `%ToolError{}.metadata`
  # to the top-level halt metadata when present (spec §13 / Phase 7 design
  # Non-obvious Decision #8 — chat layer surfaces it via
  # `ChatResult.metadata.on_tool_error_exception` and reads it directly from
  # `step.metadata` rather than fishing it out of `tool_results`).
  defp build_tool_error_halt_metadata(%ToolCall{} = tc, %ToolError{metadata: %{} = m}) do
    base = %{halted_reason: :tool_error, halt_tool_call_id: tc.id}

    case Map.fetch(m, :on_tool_error_exception) do
      {:ok, exception} -> Map.put(base, :on_tool_error_exception, exception)
      :error -> base
    end
  end

  defp build_tool_error_halt_metadata(%ToolCall{} = tc, _err) do
    %{halted_reason: :tool_error, halt_tool_call_id: tc.id}
  end

  # Invoke the function-form on_tool_error inside the task. Catches raises;
  # dispatches on the return shape; routes via the atom-form path with the
  # function reference DROPPED to avoid re-entry.
  defp invoke_on_tool_error(fun, %ToolCall{} = tc, err, raw_err, ctx) do
    error_term =
      case raw_err do
        {:error, %ToolError{} = e} -> e
        {:error, other} -> other
      end

    decision =
      try do
        fun.(tc, error_term)
      rescue
        e ->
          {:invalid_return,
           ToolError.new(:invalid_return,
             tool_name: tc.name,
             tool_call_id: tc.id,
             cause: e,
             metadata: %{on_tool_error_raised: true, on_tool_error_exception: e}
           )}
      end

    case decision do
      {:continue, replacement} ->
        continue_with_replacement(replacement, tc, ctx)

      :halt ->
        ctx_for_halt = %{ctx | on_tool_error: :halt}
        route_error(err, tc, ctx_for_halt)

      {:invalid_return, %ToolError{} = wrapped} ->
        ctx_for_halt = %{ctx | on_tool_error: :halt}
        route_error(wrapped, tc, ctx_for_halt)

      _other ->
        wrapped =
          ToolError.new(:invalid_return,
            tool_name: tc.name,
            tool_call_id: tc.id,
            metadata: %{on_tool_error_invalid: true}
          )

        ctx_for_halt = %{ctx | on_tool_error: :halt}
        route_error(wrapped, tc, ctx_for_halt)
    end
  end

  # `{:continue, replacement}` path — encode the replacement as the
  # tool-result content. Encoder failure on the replacement is wrapped
  # as `%ToolError{reason: :encoding_failed}` and routed as `:halt`
  # WITHOUT re-invoking on_tool_error (recursion-avoidance — Phase 7
  # design Non-obvious Decision #8).
  defp continue_with_replacement(replacement, %ToolCall{} = tc, ctx) do
    case encode_value(ctx.encoder, replacement, tc) do
      {:ok, content} ->
        {:continue, tool_msg(tc.id, content),
         %{
           raw_result: {:ok, replacement},
           terminal: {:encoded, content}
         }}

      {:error, %ToolError{} = encoding_err} ->
        ctx_for_halt = %{ctx | on_tool_error: :halt}
        route_error(encoding_err, tc, ctx_for_halt)
    end
  end

  # Encode a successful handler value. Catch encoder raises and wrap as
  # `%ToolError{reason: :encoding_failed}` (Non-obvious Decision #3).
  defp encode_value(encoder, value, %ToolCall{} = tc) do
    {:ok, encoder.encode(value)}
  rescue
    e in [Protocol.UndefinedError, Jason.EncodeError] ->
      err =
        ToolError.new(:encoding_failed,
          tool_name: tc.name,
          tool_call_id: tc.id,
          cause: e
        )

      {:error, err}
  end

  # Encode an error term for `:tool`-role message content.
  #
  # When the error is itself an encoding failure, we avoid re-invoking the
  # caller's encoder with the original cause (which would loop). Instead
  # we produce a minimal `%{"error" => message}` via `Jason.encode!/1`
  # directly.
  defp encode_error(_encoder, %ToolError{reason: :encoding_failed, cause: cause}) do
    Jason.encode!(%{"error" => exception_or_inspect(cause)})
  end

  defp encode_error(encoder, %ToolError{} = err) do
    encoder.encode({:error, err})
  rescue
    _ in [Protocol.UndefinedError, Jason.EncodeError] ->
      Jason.encode!(%{"error" => Exception.message(err)})
  end

  defp encode_error(encoder, reason) when is_exception(reason) do
    encoder.encode({:error, Exception.message(reason)})
  rescue
    _ in [Protocol.UndefinedError, Jason.EncodeError] ->
      Jason.encode!(%{"error" => Exception.message(reason)})
  end

  defp encode_error(encoder, reason) do
    encoder.encode({:error, reason})
  rescue
    _ in [Protocol.UndefinedError, Jason.EncodeError] ->
      Jason.encode!(%{"error" => inspect(reason)})
  end

  defp exception_or_inspect(cause) when is_exception(cause), do: Exception.message(cause)
  defp exception_or_inspect(cause), do: inspect(cause)

  # ---------------------------------------------------------------------------
  # Handler opts / resolution helpers
  # ---------------------------------------------------------------------------

  defp build_handler_opts(engine, opts, %ToolCall{} = tc) do
    context =
      cond do
        is_map(Keyword.get(opts, :context)) -> Keyword.get(opts, :context)
        match?(%Engine{}, engine) -> engine.context
        true -> %{}
      end

    [
      context: context,
      session_id: Keyword.get(opts, :session_id),
      request_id: Keyword.get(opts, :request_id),
      tool_call: tc,
      engine: engine
    ]
  end

  defp resolve_executor(opts) do
    engine = Keyword.get(opts, :engine)

    cond do
      mod = Keyword.get(opts, :tool_executor) ->
        mod

      match?(%Engine{tool_executor: m} when not is_nil(m), engine) ->
        engine.tool_executor

      true ->
        ALLM.ToolExecutor.Default
    end
  end

  defp resolve_encoder(opts) do
    engine = Keyword.get(opts, :engine)

    cond do
      mod = Keyword.get(opts, :tool_result_encoder) ->
        mod

      match?(%Engine{tool_result_encoder: m} when not is_nil(m), engine) ->
        engine.tool_result_encoder

      true ->
        ALLM.ToolResultEncoder.JSON
    end
  end

  # Default: `max(1, min(length(tool_calls), System.schedulers_online() * 2))`
  # (PHASE_6_DESIGN Non-obvious Decision #8). The outer `max(1, _)` is the
  # belt-and-suspenders guard against any future single-scheduler scenario.
  defp compute_max_concurrency(tool_calls, opts) do
    case Keyword.get(opts, :max_concurrency) do
      nil ->
        max(1, min(length(tool_calls), System.schedulers_online() * 2))

      n when is_integer(n) and n > 0 ->
        n
    end
  end

  defp tool_msg(id, content) when is_binary(id) and is_binary(content) do
    %Message{role: :tool, tool_call_id: id, content: content, metadata: %{}}
  end
end
