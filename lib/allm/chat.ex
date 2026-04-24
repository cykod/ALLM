defmodule ALLM.Chat do
  @moduledoc """
  Internal — use `ALLM.step/3` / `ALLM.stream_step/3` / `ALLM.chat/3` /
  `ALLM.stream/3` instead. See spec §17.

  Layer C — stateless single-turn step orchestrator. Phase 6 ships `step/3`
  and `stream_step/3`; Phase 7 will add `run/3` and `stream/3` (multi-turn)
  on this same module.

  ## Step equivalence (spec §3 + Phase 6 design Non-obvious Decision #9)

  `step/3` is implemented as a reducer over `stream_step/3`'s event stream
  via `ALLM.StreamCollector`. The two paths must produce identical
  `%ALLM.StepResult{}` values modulo a `tool_call_id` sort on
  `:tool_results` (parallel tool execution completes in non-deterministic
  order; the streaming path emits in completion order while the
  non-streaming path sorts by input index). See
  `steering/PHASE_6_DESIGN.md` Non-obvious Decision #9 for the full
  equivalence contract. The Phase 6 property test in
  `test/allm/step_equivalence_test.exs` (Phase 6.4) exercises this.

  ## Stream composition (Non-obvious Decision #1)

  `stream_step/3` wraps ONE outer `Stream.resource/3` driving a three-phase
  state machine:

    * **Phase A (`:phase_a`)** — drives the adapter stream via its
      `Enumerable.reduce/3` continuation. Each `next_fun` pulls ONE event,
      folds it into a `%StreamCollector{}` and emits it downstream.
      Transitions to Phase B when the adapter stream exhausts; never
      transitions on event content (`:finish_reason: :tool_calls` in an
      intermediate event does NOT trigger the transition — trailing
      `:raw_chunk` events after `:message_completed` are still consumed).
    * **Phase B (`:phase_b`)** — drives `ALLM.ToolRunner.stream_tool_calls/3`
      via its reducer continuation. Each `next_fun` pulls the next event
      trio from one completed tool and emits it downstream. When a handler
      halts or `on_tool_error: :halt` fires, the phase continues pulling
      (sibling drain — see Phase 6 design Non-obvious Decision #1).
    * **Phase C (`:phase_c`)** — emits exactly one `:step_completed` event
      with the final `%Response{}` and final `%Thread{}` (input + augmented
      assistant + tool-role messages).

  The outer `after_fun` pattern-matches on the state tuple and halts the
  active sub-resource (adapter stream in Phase A, tool-execution stream in
  Phase B) via `Enumerable.reduce(acc, {:halt, :consumer_halt}, _)` — this
  triggers the sub-resource's own cleanup exactly once. Phase C has no
  sub-resource to halt. This is ONE `Stream.resource/3`, not two; it drives
  sub-streams by their reducer continuations rather than wrapping them.

  ## Event sequence (Invariant 6)

  Events are emitted in this order:

    1. All adapter events (pass-through).
    2. Zero-to-N tool-execution event groups (for `mode: :auto` +
       `:finish_reason: :tool_calls`). Each group is, per tool:
       `:tool_execution_started` → `:tool_execution_completed` →
       one of `:tool_result_encoded` / `:ask_user_requested` /
       `:tool_halt`. Groups interleave across tools per
       `Task.async_stream/5` completion ordering; within each group the
       three events are emitted together.
    3. Exactly ONE terminal `:step_completed` event.

  No new `:message_completed` is synthesised after tool execution
  (Non-obvious Decision #12).

  ## Assistant message construction (Non-obvious Decision #10)

  The augmented assistant message is built from `response.output_text`
  (collector-authoritative — the accumulated `:text_delta` deltas or
  `:text_completed` authoritative text), NOT from
  `response.message.content` (which may be adapter-specific
  normalised/trimmed text). `metadata.finish_reason` is always populated;
  `metadata.tool_calls` is populated only when non-empty.

  ## Ask-user semantics (Non-obvious Decision #6)

  Phase 6 is single-turn — `step/3`'s thread does NOT contain an extra
  `:assistant`-role message with `metadata: %{ask_user: true}` for an
  ask-user handler return. Only `:ask_user_requested` is emitted and
  `StepResult.metadata.pending_question` / `:pending_tool_call_id` /
  `:ask_user_opts` are populated. Phase 7's `chat/3` appends the question
  to the thread as an assistant message at the turn boundary.
  """

  alias ALLM.{
    Engine,
    Event,
    Message,
    Request,
    Response,
    Runner,
    StepResult,
    StreamCollector,
    StreamRunner,
    Thread,
    ToolCall,
    ToolRunner,
    Validate
  }

  alias ALLM.Error.{AdapterError, EngineError, ValidationError}

  @typedoc """
  Options accepted by `step/3` and `stream_step/3`.

    * `:mode` — `:auto` (default) executes tool calls; `:manual` returns
      them for the caller to submit results.
    * `:tool_timeout` — milliseconds per tool (default 30_000).
    * `:on_tool_error` — `:continue` (default) or `:halt`.
    * `:tool_executor`, `:tool_result_encoder` — module overrides.
    * Phase 5 pass-through opts: `:emit_text_deltas`, `:emit_tool_deltas`,
      `:include_raw_chunks`, `:on_event`.
    * Phase 2 pass-through opts: `:model`, `:adapter_opts`, and any
      adapter-specific keys.
  """
  @type step_opts :: keyword()

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Execute a single step (one adapter call plus any auto-executed tool
  calls) and return a `%ALLM.StepResult{}`.

  Normalises `thread_or_messages` — a list of `%Message{}` is wrapped via
  `ALLM.Thread.from_messages/1`. Validates the thread via
  `ALLM.Validate.thread/1` before the adapter call. Dispatches to
  `ALLM.Runner.run/3` for the adapter round-trip, then branches on
  `:mode` and `response.finish_reason`:

    * `mode: :manual` with `finish_reason: :tool_calls` — returns the tool
      calls surfaced on `response.tool_calls`; `tool_results: []`,
      `done?: false`, `metadata.mode: :manual`. Handler is NOT invoked.
    * `mode: :auto` with `finish_reason: :tool_calls` — dispatches to
      `ALLM.ToolRunner.run_tool_calls/3`, appends tool-role messages to
      the thread, and returns the composed step result.
    * Anything else (`:stop`, `:length`, `:content_filter`, `:error`) —
      `done?: true`, `tool_results: []`.

  ## Error reason table

  | Error | Recovery |
  |-------|----------|
  | `%EngineError{reason: :missing_adapter}` | Construct engine with `:adapter`. |
  | `%EngineError{reason: :missing_stream_adapter}` | Adapter must implement `ALLM.StreamAdapter`. |
  | `%EngineError{reason: :unknown_tool, metadata: %{tool_name: name}}` | Register the tool or filter the adapter's emitted tool calls. |
  | `%ValidationError{reason: :invalid_thread}` | Fix the thread (e.g. missing `tool_call_id` on a `:tool` message). |
  | `%ValidationError{reason: :invalid_request}` | Fix the request shape. |
  | `%AdapterError{reason: _}` | Adapter pre-flight error. |

  ## Examples

      iex> engine = ALLM.Engine.new(
      ...>   adapter: ALLM.Providers.Fake,
      ...>   adapter_opts: [
      ...>     script: [
      ...>       {:tool_call, id: "c0", name: "echo", arguments: %{"x" => 1}},
      ...>       {:finish, :tool_calls}
      ...>     ]
      ...>   ],
      ...>   tools: [ALLM.tool(
      ...>     name: "echo",
      ...>     description: "",
      ...>     schema: %{},
      ...>     handler: fn args -> {:ok, args} end
      ...>   )]
      ...> )
      iex> thread = ALLM.Thread.from_messages([ALLM.user("echo please")])
      iex> {:ok, %ALLM.StepResult{} = sr} = ALLM.Chat.step(engine, thread)
      iex> sr.done?
      false
      iex> length(sr.tool_results)
      1
  """
  @spec step(Engine.t(), Thread.t() | [Message.t()], step_opts()) ::
          {:ok, StepResult.t()}
          | {:error, EngineError.t() | AdapterError.t() | ValidationError.t()}
  def step(%Engine{} = engine, thread_or_messages, opts \\ []) when is_list(opts) do
    with {:ok, thread} <- normalise_thread(thread_or_messages),
         :ok <- Validate.thread(thread),
         request <- build_request(thread, engine, opts, stream: false),
         {:ok, response} <- Runner.run(engine, request, opts) do
      do_step(engine, thread, response, opts)
    end
  end

  @doc """
  Execute a single step and return a lazy stream of `ALLM.Event` values.

  The stream is open — no events fire until the caller reduces. Events are
  emitted in this order: all adapter events (pass-through from
  `stream_generate/3`), then zero-to-N tool-execution event groups (one
  per tool: `:tool_execution_started` → `:tool_execution_completed` →
  `:tool_result_encoded` / `:ask_user_requested` / `:tool_halt`), then
  exactly one terminal `:step_completed` event.

  Consumer halt (via `Enum.take/2`, `Stream.take_while/2`, etc.) propagates
  to whichever phase is currently active — the adapter stream in Phase A
  or the tool-execution stream in Phase B — triggering that sub-resource's
  own cleanup exactly once.

  ## Event sequence

  See the module doc's "Event sequence" section. No new `:message_completed`
  is synthesised after tool execution (Non-obvious Decision #12).

  ## Unknown tools (Phase B pre-flight)

  When the adapter requests a tool that is not registered on the engine,
  `stream_step/3` still returns `{:ok, stream}` — the error does NOT
  surface on the outer tuple. Instead, after the adapter phase completes,
  the stream emits a single `{:error, %ALLM.EngineError{reason:
  :unknown_tool}}` event followed by the terminal `:step_completed`
  event. Consumers that need to short-circuit on unknown tools should
  pattern-match on `{:error, _}` elements during reduction. This differs
  from the non-streaming `step/3` which returns `{:error, %EngineError{}}`
  on the outer tuple; the asymmetry exists because once a stream has been
  constructed the consumer has already committed to reducing it, and
  late-surfacing the error as a stream element keeps the open-stream
  contract intact. See Non-obvious Decision #1 for the underlying
  three-phase state machine.

  ## Examples

      iex> engine = ALLM.Engine.new(
      ...>   adapter: ALLM.Providers.Fake,
      ...>   adapter_opts: [
      ...>     script: [
      ...>       {:tool_call, id: "c0", name: "echo", arguments: %{"x" => 1}},
      ...>       {:finish, :tool_calls}
      ...>     ]
      ...>   ],
      ...>   tools: [ALLM.tool(
      ...>     name: "echo",
      ...>     description: "",
      ...>     schema: %{},
      ...>     handler: fn args -> {:ok, args} end
      ...>   )]
      ...> )
      iex> thread = ALLM.Thread.from_messages([ALLM.user("echo please")])
      iex> {:ok, stream} = ALLM.Chat.stream_step(engine, thread)
      iex> events = Enum.to_list(stream)
      iex> Enum.any?(events, &match?({:step_completed, _}, &1))
      true
  """
  @spec stream_step(Engine.t(), Thread.t() | [Message.t()], step_opts()) ::
          {:ok, Enumerable.t()}
          | {:error, EngineError.t() | AdapterError.t() | ValidationError.t()}
  def stream_step(%Engine{} = engine, thread_or_messages, opts \\ []) when is_list(opts) do
    with {:ok, thread} <- normalise_thread(thread_or_messages),
         :ok <- Validate.thread(thread),
         request <- build_request(thread, engine, opts, stream: true),
         {:ok, adapter_stream} <- StreamRunner.run(engine, request, opts) do
      {:ok, build_step_stream(engine, thread, adapter_stream, opts)}
    end
  end

  # ---------------------------------------------------------------------------
  # Non-streaming step finaliser
  # ---------------------------------------------------------------------------

  # Branch on mode + finish_reason. `:manual` surfaces the tool calls
  # without running them; `:auto` + `:tool_calls` runs ToolRunner;
  # anything else is a terminal step.
  defp do_step(%Engine{} = engine, thread, %Response{} = response, opts) do
    mode = Keyword.get(opts, :mode, :auto)
    assistant_msg = build_assistant_message(response)

    case {mode, response.finish_reason} do
      {:manual, :tool_calls} ->
        new_thread = Thread.add_message(thread, assistant_msg)

        {:ok,
         %StepResult{
           thread: new_thread,
           response: response,
           tool_results: [],
           done?: false,
           metadata: %{mode: :manual}
         }}

      {:auto, :tool_calls} ->
        run_tools_non_streaming(engine, thread, assistant_msg, response, opts)

      {_mode, _other} ->
        new_thread = Thread.add_message(thread, assistant_msg)

        {:ok,
         %StepResult{
           thread: new_thread,
           response: response,
           tool_results: [],
           done?: true,
           metadata: %{}
         }}
    end
  end

  defp run_tools_non_streaming(%Engine{} = engine, thread, assistant_msg, response, opts) do
    tools = Engine.resolve_tools(engine, opts)
    runner_opts = build_runner_opts(engine, response, opts)

    case ToolRunner.run_tool_calls(response.tool_calls, tools, runner_opts) do
      {:ok, tool_msgs} ->
        new_thread =
          thread
          |> Thread.add_message(assistant_msg)
          |> Thread.add_messages(tool_msgs)

        {:ok,
         %StepResult{
           thread: new_thread,
           response: response,
           tool_results: tool_msgs,
           done?: false,
           metadata: %{}
         }}

      {:ok, tool_msgs, halt_meta} ->
        new_thread =
          thread
          |> Thread.add_message(assistant_msg)
          |> Thread.add_messages(tool_msgs)

        {:ok,
         %StepResult{
           thread: new_thread,
           response: response,
           tool_results: tool_msgs,
           done?: true,
           metadata: halt_meta
         }}

      {:error, %EngineError{}} = err ->
        err
    end
  end

  # ---------------------------------------------------------------------------
  # Streaming step: three-phase Stream.resource/3 state machine
  # ---------------------------------------------------------------------------

  # Phase 6 Non-obvious Decision #1 — ONE outer Stream.resource/3 driving
  # three phases via state tuples. See the module doc's "Stream composition"
  # section for the full contract.
  defp build_step_stream(%Engine{} = engine, %Thread{} = thread, adapter_stream, opts) do
    Stream.resource(
      fn -> init_state(engine, thread, adapter_stream, opts) end,
      &stream_next/1,
      &stream_after/1
    )
  end

  defp init_state(engine, thread, adapter_stream, opts) do
    # Seed Phase A with the adapter stream's reducer continuation. The
    # continuation is a 1-arity fun we step by passing {:cont, acc}; it
    # returns {:suspended, event, next_cont}, {:done, acc}, or {:halted,
    # acc}. Wrapping in `&Enumerable.reduce/3` lets us drive any
    # enumerable the adapter provides.
    continuation = &Enumerable.reduce(adapter_stream, &1, fn event, _ -> {:suspend, event} end)

    {:phase_a,
     %{
       engine: engine,
       thread: thread,
       collector: StreamCollector.new(thread),
       opts: opts,
       adapter_cont: {:suspended, nil, continuation}
     }}
  end

  # --- Phase A: pull adapter events one at a time ---

  defp stream_next({:phase_a, data}) do
    pull_next_phase_a(data)
  end

  defp stream_next({:phase_b, data}) do
    pull_next_phase_b(data)
  end

  defp stream_next({:phase_c, data}) do
    emit_step_completed(data)
  end

  defp stream_next({:done, _data} = state) do
    {:halt, state}
  end

  # Advance the adapter stream's reducer continuation by one event. Elixir's
  # Enumerable.reduce/3 protocol: the continuation takes {:cont, acc} and
  # returns either {:suspended, result, next_cont}, {:done, final_acc}, or
  # {:halted, final_acc}. We use the :suspend acc shape so each reduction
  # call returns exactly one event.
  defp pull_next_phase_a(%{adapter_cont: {:suspended, _last, cont}} = data) do
    case cont.({:cont, nil}) do
      {:suspended, event, next_cont} ->
        new_collector = StreamCollector.apply_event(data.collector, event)
        new_data = %{data | collector: new_collector, adapter_cont: {:suspended, event, next_cont}}
        {[event], {:phase_a, new_data}}

      {:done, _acc} ->
        transition_a_to_b(data)

      {:halted, _acc} ->
        transition_a_to_b(data)
    end
  end

  # Phase A exhaustion: Phase B bootstraps with the collector's final
  # response and either runs ToolRunner.stream_tool_calls/3 (when there are
  # tool calls and mode != :manual) or skips straight to Phase C.
  defp transition_a_to_b(%{collector: collector, engine: engine, opts: opts} = data) do
    response = StreamCollector.to_response(collector)
    assistant_msg = build_assistant_message(response)
    mode = Keyword.get(opts, :mode, :auto)

    cond do
      mode == :manual and response.finish_reason == :tool_calls ->
        # :manual — no tool execution; skip directly to :step_completed.
        phase_c_data = %{
          engine: engine,
          thread: Thread.add_message(data.thread, assistant_msg),
          response: response,
          assistant_msg: assistant_msg,
          tool_msgs: [],
          mode: :manual,
          halt_metadata: nil
        }

        stream_next({:phase_c, phase_c_data})

      mode == :auto and response.finish_reason == :tool_calls and response.tool_calls != [] ->
        start_phase_b(data, response, assistant_msg)

      true ->
        # Terminal adapter finish (:stop, :length, :content_filter, :error) —
        # no tool calls to execute; skip directly to :step_completed.
        phase_c_data = %{
          engine: engine,
          thread: Thread.add_message(data.thread, assistant_msg),
          response: response,
          assistant_msg: assistant_msg,
          tool_msgs: [],
          mode: mode,
          halt_metadata: nil
        }

        stream_next({:phase_c, phase_c_data})
    end
  end

  # Phase B bootstrap: construct the ToolRunner.stream_tool_calls/3
  # enumerable and seed its reducer continuation the same way as Phase A's.
  defp start_phase_b(
         %{engine: engine, thread: thread, opts: opts} = _data,
         %Response{} = response,
         assistant_msg
       ) do
    tools = Engine.resolve_tools(engine, opts)
    runner_opts = build_runner_opts(engine, response, opts)

    case preflight_unknown(response.tool_calls, tools) do
      :ok ->
        tool_stream = ToolRunner.stream_tool_calls(response.tool_calls, tools, runner_opts)
        cont = &Enumerable.reduce(tool_stream, &1, fn event, _ -> {:suspend, event} end)

        phase_b_data = %{
          engine: engine,
          thread: thread,
          opts: opts,
          response: response,
          assistant_msg: assistant_msg,
          tool_msgs: [],
          halt_metadata: nil,
          tool_cont: {:suspended, nil, cont}
        }

        pull_next_phase_b(phase_b_data)

      {:error, %EngineError{} = err} ->
        # Surface unknown_tool as a single {:error, _} event followed by
        # halt — Phase 6 ToolRunner's degenerate error-stream shape.
        phase_c_data = %{
          engine: engine,
          thread: Thread.add_message(thread, assistant_msg),
          response: response,
          assistant_msg: assistant_msg,
          tool_msgs: [],
          mode: :auto,
          halt_metadata: nil
        }

        # Emit the error event, move to :phase_c which will emit a
        # terminal :step_completed. The step_completed thread still has
        # just the assistant message (no tool-role messages).
        {[{:error, err}], {:phase_c, phase_c_data}}
    end
  end

  # Pre-flight parallel to ToolRunner's: short-circuit unknown tools
  # before paying the Task.async_stream setup cost and duplicating the
  # error detection logic. See ToolRunner.preflight_unknown_tools/2.
  defp preflight_unknown(tool_calls, tools) do
    Enum.reduce_while(tool_calls, :ok, &preflight_step(&1, tools, &2))
  end

  defp preflight_step(%ToolCall{name: name}, tools, :ok) do
    case Enum.find(tools, fn t -> t.name == name end) do
      nil -> {:halt, {:error, unknown_tool_error(name)}}
      _ -> {:cont, :ok}
    end
  end

  defp unknown_tool_error(name) do
    EngineError.new(:unknown_tool,
      message: "tool #{name} not in engine.tools",
      metadata: %{tool_name: name}
    )
  end

  # --- Phase B: pull tool-execution events ---

  defp pull_next_phase_b(%{tool_cont: :done} = data) do
    transition_b_to_c(data)
  end

  defp pull_next_phase_b(%{tool_cont: {:suspended, _last, cont}} = data) do
    case cont.({:cont, nil}) do
      {:suspended, event, next_cont} ->
        new_data = update_phase_b_from_event(data, event)
        new_data = %{new_data | tool_cont: {:suspended, event, next_cont}}
        {[event], {:phase_b, new_data}}

      {:done, _acc} ->
        transition_b_to_c(data)

      {:halted, _acc} ->
        transition_b_to_c(data)
    end
  end

  # Accumulate tool-role messages + halt metadata by observing the
  # tool-execution event stream. We reuse the same per-event dispatch
  # pattern the collector uses (but with Phase-B-specific state).
  defp update_phase_b_from_event(data, {:tool_result_encoded, %{id: id, content: content}}) do
    tool_msg = %Message{role: :tool, tool_call_id: id, content: content, metadata: %{}}
    %{data | tool_msgs: data.tool_msgs ++ [tool_msg]}
  end

  defp update_phase_b_from_event(data, {:tool_halt, %{tool_call_id: id, reason: reason, result: r}}) do
    # First-halt-wins — only set halt_metadata if not already set.
    case data.halt_metadata do
      nil ->
        tool_msg = encoded_halt_message(id, r, data.engine, data.opts)
        meta = %{halted_reason: reason, halt_tool_call_id: id, halt_result: r}
        %{data | tool_msgs: data.tool_msgs ++ [tool_msg], halt_metadata: meta}

      _already ->
        data
    end
  end

  defp update_phase_b_from_event(
         data,
         {:ask_user_requested, %{tool_call_id: id, question: q, opts: user_opts}}
       ) do
    case data.halt_metadata do
      nil ->
        tool_msg = %Message{
          role: :tool,
          tool_call_id: id,
          content: "<awaiting user response>",
          metadata: %{}
        }

        meta = %{
          halted_reason: :ask_user,
          pending_tool_call_id: id,
          pending_question: q,
          ask_user_opts: user_opts
        }

        %{data | tool_msgs: data.tool_msgs ++ [tool_msg], halt_metadata: meta}

      _already ->
        data
    end
  end

  defp update_phase_b_from_event(data, _event), do: data

  # Best-effort encoding of the halt result for a tool-role message. We use
  # the engine's tool_result_encoder to keep the behaviour consistent with
  # the non-streaming path's ToolRunner; on encoder failure, fall back to
  # `inspect/1` (this halt path is rare enough that propagating an encoder
  # exception would surprise callers).
  defp encoded_halt_message(id, result, engine, opts) do
    encoder = resolve_encoder(engine, opts)

    content =
      try do
        encoder.encode(result)
      rescue
        _ -> inspect(result)
      end

    %Message{role: :tool, tool_call_id: id, content: content, metadata: %{}}
  end

  defp resolve_encoder(%Engine{tool_result_encoder: mod}, opts) do
    cond do
      override = Keyword.get(opts, :tool_result_encoder) -> override
      mod != nil -> mod
      true -> ALLM.ToolResultEncoder.JSON
    end
  end

  # --- Phase B → C transition: finalise the thread and queue :step_completed ---

  defp transition_b_to_c(%{
         engine: engine,
         thread: thread,
         response: response,
         assistant_msg: assistant_msg,
         tool_msgs: tool_msgs,
         halt_metadata: halt_metadata
       }) do
    final_thread =
      thread
      |> Thread.add_message(assistant_msg)
      |> Thread.add_messages(tool_msgs)

    phase_c_data = %{
      engine: engine,
      thread: final_thread,
      response: response,
      assistant_msg: assistant_msg,
      tool_msgs: tool_msgs,
      mode: :auto,
      halt_metadata: halt_metadata
    }

    stream_next({:phase_c, phase_c_data})
  end

  # --- Phase C: emit :step_completed and halt ---

  defp emit_step_completed(%{thread: thread, response: response} = data) do
    event = Event.step_completed(response, thread)
    {[event], {:done, data}}
  end

  # --- after_fun: halt whichever sub-resource is active ---

  defp stream_after({:phase_a, %{adapter_cont: {:suspended, _last, cont}}}) do
    # Trigger the adapter stream's own after_fun exactly once by sending
    # {:halt, _} through its continuation. The `_ -> {:halt, :ok}` inner
    # reducer never runs because the outer halt fires before any next
    # element is presented; this is the canonical Enumerable cleanup idiom.
    _ = cont.({:halt, :consumer_halt})
    :ok
  rescue
    # An already-exhausted continuation may return {:done, _} without
    # accepting {:halt, _} — swallow silently; cleanup already fired.
    _ -> :ok
  end

  defp stream_after({:phase_b, %{tool_cont: {:suspended, _last, cont}}}) do
    _ = cont.({:halt, :consumer_halt})
    :ok
  rescue
    _ -> :ok
  end

  defp stream_after({:phase_b, %{tool_cont: :done}}), do: :ok

  defp stream_after({:phase_c, _data}), do: :ok

  defp stream_after({:done, _data}), do: :ok

  # ---------------------------------------------------------------------------
  # Shared helpers
  # ---------------------------------------------------------------------------

  defp normalise_thread(%Thread{} = thread), do: {:ok, thread}

  defp normalise_thread(messages) when is_list(messages) do
    {:ok, Thread.from_messages(messages)}
  end

  defp normalise_thread(_other) do
    {:error,
     ValidationError.new(:invalid_thread, [{:thread, :invalid_type}],
       message: "thread_or_messages must be a %Thread{} or a list of %Message{}"
     )}
  end

  # The `stream` flag on `%Request{}` is informational in Phase 6 — adapters
  # dispatch via `Runner.run/3` vs `StreamRunner.run/3` based on which the
  # caller invokes, not on this field. We still set it truthfully so that
  # serialized `%Request{}` records round-trip with intent intact.
  defp build_request(%Thread{messages: msgs}, %Engine{} = engine, opts, flags) do
    Request.new(msgs,
      tools: Engine.resolve_tools(engine, opts),
      stream: Keyword.get(flags, :stream, false)
    )
  end

  # Phase 6 design Non-obvious Decision #10: construct the assistant
  # message from `response.output_text` (collector-authoritative), not
  # from `response.message.content` (may diverge on adapters that emit
  # normalised/trimmed final text).
  defp build_assistant_message(%Response{} = response) do
    metadata =
      %{finish_reason: response.finish_reason}
      |> put_tool_calls(response.tool_calls)

    %Message{
      role: :assistant,
      content: response.output_text || "",
      metadata: metadata
    }
  end

  defp put_tool_calls(meta, []), do: meta

  defp put_tool_calls(meta, tool_calls) when is_list(tool_calls),
    do: Map.put(meta, :tool_calls, tool_calls)

  # Build the opts keyword list forwarded to ToolRunner.run_tool_calls/3
  # and stream_tool_calls/3. We project out Phase-5 adapter opts (already
  # consumed during the adapter call) and surface Phase-6 tool-runner opts.
  defp build_runner_opts(%Engine{} = engine, %Response{} = response, opts) do
    tool_runner_keys = [
      :tool_timeout,
      :on_tool_error,
      :tool_executor,
      :tool_result_encoder,
      :max_concurrency,
      :context,
      :session_id
    ]

    base =
      Keyword.take(opts, tool_runner_keys)
      |> Keyword.put_new(:engine, engine)
      |> Keyword.put_new(:context, engine.context)
      |> Keyword.put_new(:session_id, nil)
      |> Keyword.put_new(:request_id, response.request_id)

    base
  end
end
