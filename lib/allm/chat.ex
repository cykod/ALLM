defmodule ALLM.Chat do
  @moduledoc """
  > #### Internal {: .warning}
  >
  > This module is internal — it's documented for transparency, but call
  > sites should use `ALLM.step/3`, `ALLM.stream_step/3`, `ALLM.chat/3`,
  > or `ALLM.stream/3` instead.

  Layer-C single-turn and multi-turn chat orchestrator. The public façade
  delegates here: `step/3` and `stream_step/3` for one round-trip,
  `run/3` and `stream/3` for the multi-turn loop.

  ## Step equivalence

  `step/3` is implemented as a reducer over `stream_step/3`'s event stream
  via `ALLM.StreamCollector`. The two paths must produce identical
  `%ALLM.StepResult{}` values modulo a `tool_call_id` sort on
  `:tool_results` (parallel tool execution completes in non-deterministic
  order; the streaming path emits in completion order while the
  non-streaming path sorts by input index).

  ## Stream composition

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
      (sibling drain).
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

  No new `:message_completed` is synthesised after tool execution.

  ## Assistant message construction

  The augmented assistant message is built from `response.output_text`
  (collector-authoritative — the accumulated `:text_delta` deltas or
  `:text_completed` authoritative text), NOT from
  `response.message.content` (which may be adapter-specific
  normalised/trimmed text). `metadata.finish_reason` is always populated;
  `metadata.tool_calls` is populated only when non-empty.

  ## Ask-user semantics

  `step/3` is single-turn — the returned thread does NOT contain an
  extra `:assistant`-role message with `metadata: %{ask_user: true}`
  for an ask-user handler return. Only `:ask_user_requested` is emitted
  and `StepResult.metadata.pending_question` / `:pending_tool_call_id`
  / `:ask_user_opts` are populated. The multi-turn `run/3` appends the
  question to the thread as an assistant message at the turn boundary.
  """

  alias ALLM.{
    Capability,
    ChatResult,
    Engine,
    Event,
    Message,
    Request,
    Response,
    Runner,
    StepResult,
    StreamCollector,
    StreamRunner,
    Telemetry,
    Thread,
    Tool,
    ToolCall,
    ToolRunner,
    Validate
  }

  alias ALLM.Chat.LoopState
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
    * Anything else (`:stop`, `:length`, `:content_filter`, `:error`)
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
      ...> adapter: ALLM.Providers.Fake,
      ...> adapter_opts: [
      ...> script: [
      ...> {:tool_call, id: "c0", name: "echo", arguments: %{"x" => 1}},
      ...> {:finish, :tool_calls}
      ...> ]
      ...> ],
      ...> tools: [ALLM.tool(
      ...> name: "echo",
      ...> description: "",
      ...> schema: %{},
      ...> handler: fn args -> {:ok, args} end
      ...>)]
      ...>)
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
    request_id = Keyword.get(opts, :request_id) || Telemetry.request_id()
    opts = Keyword.put(opts, :request_id, request_id)

    start_metadata = %{
      request_id: request_id,
      engine: engine,
      model: engine.model
    }

    Telemetry.span(:step, start_metadata, fn ->
      result = do_step_call(engine, thread_or_messages, opts)
      {result, step_stop_extras(result)}
    end)
  end

  defp do_step_call(%Engine{} = engine, thread_or_messages, opts) do
    with {:ok, thread} <- normalise_thread(thread_or_messages),
         :ok <- Validate.thread(thread),
         request <- build_request(thread, engine, opts, stream: false),
         {:ok, response} <- Runner.run(engine, request, drop_orchestration_opts(opts)) do
      do_step(engine, thread, response, opts)
    end
  end

  # Chat consumes the orchestration opts (`:mode`, `:max_turns`, `:halt_when`)
  # itself and must not forward them to Runner / StreamRunner. Without this
  # drop, StreamRunner's defensive backstop logs a debug "stripped
  # orchestration opt" line on every step (visible to anyone running the
  # examples or live code at debug log level). Keep the keys in sync with
  # `ALLM.StreamRunner.@orchestration_opts`.
  defp drop_orchestration_opts(opts), do: Keyword.drop(opts, [:mode, :max_turns, :halt_when])

  defp step_stop_extras({:ok, %StepResult{} = sr}), do: %{step_result: sr}
  defp step_stop_extras({:error, _}), do: %{step_result: nil}

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
  is synthesised after tool execution.

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
  contract intact. See the module-level "Stream composition" section
  for the three-phase state machine.

  ## Examples

      iex> engine = ALLM.Engine.new(
      ...> adapter: ALLM.Providers.Fake,
      ...> adapter_opts: [
      ...> script: [
      ...> {:tool_call, id: "c0", name: "echo", arguments: %{"x" => 1}},
      ...> {:finish, :tool_calls}
      ...> ]
      ...> ],
      ...> tools: [ALLM.tool(
      ...> name: "echo",
      ...> description: "",
      ...> schema: %{},
      ...> handler: fn args -> {:ok, args} end
      ...>)]
      ...>)
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
    request_id = Keyword.get(opts, :request_id) || Telemetry.request_id()
    opts = Keyword.put(opts, :request_id, request_id)

    start_metadata = %{
      request_id: request_id,
      engine: engine,
      model: engine.model
    }

    Telemetry.span(:step, start_metadata, fn ->
      result = do_stream_step_call(engine, thread_or_messages, opts)
      # Stream span: don't materialise the lazy enumerable inside the
      # closure (defeats consumer-driven laziness). :step_result stays nil
      # on :stop for streaming step spans.
      {result, %{step_result: nil}}
    end)
  end

  defp do_stream_step_call(%Engine{} = engine, thread_or_messages, opts) do
    with {:ok, thread} <- normalise_thread(thread_or_messages),
         :ok <- Validate.thread(thread),
         request <- build_request(thread, engine, opts, stream: true),
         {:ok, adapter_stream} <- StreamRunner.run(engine, request, drop_orchestration_opts(opts)) do
      {:ok, build_step_stream(engine, thread, adapter_stream, opts)}
    end
  end

  @typedoc """
  Options accepted by `run/3` (and `stream/3` in Phase 7.4).

    * `:max_turns` — `pos_integer()`. Precedence: call opts > `engine.params`
      > `Application.get_env(:allm, :max_turns)` > library default `8`.
      Validated at entry; raises `ArgumentError` for non-`pos_integer`.
    * `:halt_when` — `(StepResult.t() -> boolean())`. Called AFTER thread
      mutation per turn; exceptions propagate to the caller.
    * Plus every `step_opts/0` key (`:mode`, `:tool_timeout`,
      `:on_tool_error`, etc.).
  """
  @type chat_opts :: keyword()

  @doc """
  Run a multi-turn chat loop and return a `%ALLM.ChatResult{}`.

  Composes `step/3` calls: each step's `thread` becomes the next step's
  input thread. Halts on the first matching terminal condition (see
  `terminal_condition/4` source for the seven-entry total order).

  ## Halt reasons

  | Reason | Fires when |
  |--------|------------|
  | `:completed` | Adapter `finish_reason ∈ {:stop, :length, :content_filter}` |
  | `:error` | Adapter `finish_reason: :error` (mid-stream error folds into the response) |
  | `:max_turns` | `step_index + 1 >= max_turns` after a step that didn't otherwise halt |
  | `:halt_when` | `halt_when.(step_result)` returns `true` |
  | `:ask_user` | Handler returned `{:ask_user, _}` or `{:ask_user, _, _}` |
  | `:tool_error` | `on_tool_error: :halt` fired, or fun form returned `:halt` / raised |
  | `:manual_tool_calls` | `mode: :manual` and step surfaces tool calls |
  | atom (user) | Handler returned `{:halt, reason, result}` |

  Adapter pre-flight errors surface as `{:error, struct}` from the FIRST
  step's `step/3` call. Mid-loop adapter errors fold into the step's
  response and surface as `halted_reason: :error` on the `ChatResult`.

  ## structured_finalize semantics

  When called with `opts[:structured_finalize] == true` AND
  `opts[:response_format] != nil`, `run/3` runs a two-pass orchestration:

    * **Pass 1** runs the tool loop with `response_format` cleared
      (tools preserved). Halts naturally per the table above.
    * **Pass 2** fires only when pass 1 halted on
      `:completed | :max_turns | :halt_when`. Other halts skip pass 2;
      the pass-1 result is returned with
      `metadata.structured_finalize.pass_1_halted == <reason>`.
    * Pass 2 issues a single tools-disabled adapter call carrying the
      original `response_format`, after appending a user-nudge message
      to the thread (override via `opts[:structured_finalize_nudge]` >
      `Application.get_env(:allm, :structured_finalize_nudge)` >
      library default `"Now provide your final structured response."`;
      empty-string nudge skips the append).
    * The merged `%ChatResult{}` carries `:steps` from BOTH passes,
      `:final_response` from pass 2, `:halted_reason` from pass 2,
      `:thread` from pass 2, and
      `metadata.structured_finalize.pass_1_halted`.

  Per Invariant #4: pass 1 consumes the `max_turns` budget; pass 2's
  single call does NOT decrement it.

  ## Examples

      iex> engine = ALLM.Engine.new(
      ...> adapter: ALLM.Providers.Fake,
      ...> adapter_opts: [
      ...> scripts: [
      ...> [{:tool_call, id: "c0", name: "echo", arguments: %{"x" => 1}},
      ...> {:finish, :tool_calls}],
      ...> [{:text, "done"}, {:finish, :stop}]
      ...> ]
      ...> ],
      ...> tools: [ALLM.tool(
      ...> name: "echo",
      ...> description: "",
      ...> schema: %{},
      ...> handler: fn args -> {:ok, args} end
      ...>)]
      ...>)
      iex> thread = ALLM.Thread.from_messages([ALLM.user("echo please")])
      iex> {:ok, %ALLM.ChatResult{} = r} = ALLM.Chat.run(engine, thread)
      iex> r.halted_reason
      :completed
      iex> length(r.steps)
      2
  """
  @spec run(Engine.t(), Thread.t() | [Message.t()], chat_opts()) ::
          {:ok, ChatResult.t()}
          | {:error, EngineError.t() | AdapterError.t() | ValidationError.t()}
  def run(%Engine{} = engine, thread_or_messages, opts \\ []) when is_list(opts) do
    max_turns = resolve_max_turns(engine, opts)
    validate_max_turns!(max_turns)

    request_id = Keyword.get(opts, :request_id) || Telemetry.request_id()
    opts = Keyword.put(opts, :request_id, request_id)

    start_metadata = %{
      request_id: request_id,
      engine: engine,
      model: engine.model
    }

    Telemetry.span(:chat, start_metadata, fn ->
      result =
        if structured_finalize_required?(opts) do
          run_two_pass(engine, thread_or_messages, opts, max_turns)
        else
          do_run_call(engine, thread_or_messages, opts, max_turns)
        end

      {result, chat_stop_extras(result)}
    end)
  end

  # Phase 10.4 — fires when both `structured_finalize: true` AND
  # `response_format: <non-nil>` are set on the opts. Per spec §5.4 +
  # design Decision #7 / Invariant #1.
  defp structured_finalize_required?(opts) do
    Keyword.get(opts, :structured_finalize) == true and
      not is_nil(Keyword.get(opts, :response_format))
  end

  # Two-pass orchestration: pass 1 runs the tool loop with
  # `response_format: nil` (tools preserved); pass 2 issues a single
  # adapter call with `tools: [], response_format: original, structured_finalize: false`.
  # Pass 2 only fires when pass 1 halted on `:completed | :max_turns | :halt_when`.
  defp run_two_pass(%Engine{} = engine, thread_or_messages, opts, max_turns) do
    response_format = Keyword.get(opts, :response_format)

    pass_1_opts =
      opts
      |> Keyword.put(:structured_finalize, false)
      |> Keyword.put(:response_format, nil)

    case do_run_call(engine, thread_or_messages, pass_1_opts, max_turns) do
      {:ok, %ChatResult{} = pass_1_result} ->
        if pass_1_result.halted_reason in [:completed, :max_turns, :halt_when] do
          run_finalize_pass(engine, pass_1_result, response_format, opts)
        else
          # :ask_user, :tool_error, or any other halt — skip pass 2.
          # Surface the pass-1 result with an empty pass_1_halted record
          # in metadata so callers can introspect.
          {:ok,
           %ChatResult{
             pass_1_result
             | metadata:
                 Map.put(pass_1_result.metadata, :structured_finalize, %{
                   pass_1_halted: pass_1_result.halted_reason
                 })
           }}
        end

      {:error, _} = err ->
        err
    end
  end

  # Pass 2 — tools-disabled single adapter call producing the structured
  # final response. Resolves the user-nudge per Decision #8 (per-call opt
  # > app config > library default; empty-string nudge skips append).
  defp run_finalize_pass(%Engine{} = engine, %ChatResult{} = pass_1_result, response_format, opts) do
    nudge =
      Keyword.get(opts, :structured_finalize_nudge) ||
        Application.get_env(:allm, :structured_finalize_nudge) ||
        "Now provide your final structured response."

    pass_2_thread =
      case nudge do
        "" -> pass_1_result.thread
        _ -> Thread.add_message(pass_1_result.thread, %Message{role: :user, content: nudge})
      end

    # Pass 2 engine has zero tools; the adapter receives `tools: []` so
    # Engine.resolve_tools/2 returns []. Per Invariant #4: pass 2 does NOT
    # decrement max_turns budget; budget only governs the loop.
    finalize_engine = %{engine | tools: []}

    pass_2_opts =
      opts
      |> Keyword.put(:structured_finalize, false)
      |> Keyword.put(:response_format, response_format)
      |> Keyword.put(:max_turns, 1)

    case do_run_call(finalize_engine, pass_2_thread, pass_2_opts, 1) do
      {:ok, %ChatResult{} = pass_2_result} ->
        merged = merge_pass_results(pass_1_result, pass_2_result)
        {:ok, merged}

      {:error, _} = err ->
        err
    end
  end

  # Merge per Invariant #6: steps from BOTH passes; final_response /
  # halted_reason / thread from pass 2; metadata carries the
  # structured_finalize observability key.
  defp merge_pass_results(%ChatResult{} = pass_1, %ChatResult{} = pass_2) do
    %ChatResult{
      thread: pass_2.thread,
      final_response: pass_2.final_response,
      steps: pass_1.steps ++ pass_2.steps,
      halted_reason: pass_2.halted_reason,
      pending_question: pass_2.pending_question,
      pending_tool_call_id: pass_2.pending_tool_call_id,
      metadata:
        Map.put(pass_2.metadata, :structured_finalize, %{
          pass_1_halted: pass_1.halted_reason
        })
    }
  end

  defp do_run_call(%Engine{} = engine, thread_or_messages, opts, max_turns) do
    with {:ok, thread} <- normalise_thread(thread_or_messages) do
      # `max_turns` is resolved once at entry and threaded through `LoopState`.
      # `opts` flows verbatim to `step/3` and the adapter — no sentinels, no
      # private keys. `terminal_condition/5` reads `max_turns` from its
      # explicit 5th argument; both `run/3` and (future) `stream/3` resolve
      # the same way at entry.
      state = %LoopState{
        engine: engine,
        opts: opts,
        initial_thread: thread,
        thread: thread,
        max_turns: max_turns
      }

      run_loop(state)
    end
  end

  defp chat_stop_extras({:ok, %ChatResult{} = cr}), do: %{chat_result: cr}
  defp chat_stop_extras({:error, _}), do: %{chat_result: nil}

  @doc """
  Stream a multi-turn chat loop and return a lazy stream of `ALLM.Event`
  values terminating in exactly one `:chat_completed` event.

  Composes `stream_step/3` sub-streams sequentially: the outer
  `Stream.resource/3` drives the current step's reducer one event at a
  time (mirroring `stream_step/3`'s continuation idiom one layer up).
  When a step completes, `terminal_condition/5` decides whether to start
  a new step (with the augmented thread) or transition to the terminal
  `:chat_completed` emission.

  ## Multi-turn stream composition

  Two-phase state machine:

    * **Phase S (`:step`)** — drives the current `stream_step/3`
      enumerable via its reducer continuation. Each `next_fun` pulls one
      event, folds it into the outer `StreamCollector`, and emits it. On
      `:step_completed`, computes a `%StepResult{}` from the PRE-fold
      collector state, folds the event, then invokes
      `terminal_condition/5`. On `:continue`, starts the next step. On
      `{:halt, reason, _}`, builds the final `%ChatResult{}` and
      transitions to Phase F.
    * **Phase F (`:final`)** — emits exactly one
      `{:chat_completed, %{result: chat_result}}` event and halts.

  ## Cleanup chain

  ```
  Chat.stream/3 after_fun
    → halt step_cont
      → Chat.stream_step/3 after_fun
        → halt adapter_cont OR tool_cont (whichever is active)
  ```

  Consumer halt produces NO `:chat_completed` event. Callers needing a
  final `%ChatResult{}` for a cancelled stream collect events and call
  `ALLM.StreamCollector.to_chat_result/1` on the partial state.

  ## Ask-user thread asymmetry

  When a step's handler returns `{:ask_user, _}`, the streamed
  `:step_completed.thread` does NOT include the assistant question
  message — only the `:chat_completed.result.thread` does. Consumers
  persisting thread state across turns should read `ChatResult.thread`,
  not `:step_completed.thread`.

  ## Examples

      iex> engine = ALLM.Engine.new(
      ...> adapter: ALLM.Providers.Fake,
      ...> adapter_opts: [
      ...> scripts: [
      ...> [{:tool_call, id: "c0", name: "echo", arguments: %{"x" => 1}},
      ...> {:finish, :tool_calls}],
      ...> [{:text, "done"}, {:finish, :stop}]
      ...> ]
      ...> ],
      ...> tools: [ALLM.tool(
      ...> name: "echo",
      ...> description: "",
      ...> schema: %{},
      ...> handler: fn args -> {:ok, args} end
      ...>)]
      ...>)
      iex> thread = ALLM.Thread.from_messages([ALLM.user("echo please")])
      iex> {:ok, stream} = ALLM.Chat.stream(engine, thread)
      iex> events = Enum.to_list(stream)
      iex> Enum.count(events, &match?({:chat_completed, _}, &1))
      1
  """
  @spec stream(Engine.t(), Thread.t() | [Message.t()], chat_opts()) ::
          {:ok, Enumerable.t()}
          | {:error, EngineError.t() | AdapterError.t() | ValidationError.t()}
  def stream(%Engine{} = engine, thread_or_messages, opts \\ []) when is_list(opts) do
    max_turns = resolve_max_turns(engine, opts)
    validate_max_turns!(max_turns)

    request_id = Keyword.get(opts, :request_id) || Telemetry.request_id()
    opts = Keyword.put(opts, :request_id, request_id)

    start_metadata = %{
      request_id: request_id,
      engine: engine,
      model: engine.model
    }

    Telemetry.span(:chat, start_metadata, fn ->
      result =
        if structured_finalize_required?(opts) do
          stream_two_pass(engine, thread_or_messages, opts, max_turns)
        else
          do_stream_call(engine, thread_or_messages, opts, max_turns)
        end

      # Lazy enumerable — see Phase 9.1 design line 490.
      {result, %{chat_result: nil}}
    end)
  end

  # Phase 10.4 — stream-equivalent two-pass orchestration. Runs pass 1 as
  # a normal stream, intercepts the terminal `:chat_completed` event to
  # decide whether to start pass 2 (per the same halt-reason rule as
  # `run_two_pass/4`), and emits pass 2's events transparently.
  # Per Invariant #7: exactly one `:chat_completed` event reaches the
  # consumer (pass 1's is suppressed; only pass 2's bubbles out).
  defp stream_two_pass(%Engine{} = engine, thread_or_messages, opts, max_turns) do
    response_format = Keyword.get(opts, :response_format)

    pass_1_opts =
      opts
      |> Keyword.put(:structured_finalize, false)
      |> Keyword.put(:response_format, nil)

    case do_stream_call(engine, thread_or_messages, pass_1_opts, max_turns) do
      {:ok, pass_1_stream} ->
        {:ok, build_two_pass_stream(engine, pass_1_stream, response_format, opts)}

      {:error, _} = err ->
        err
    end
  end

  defp build_two_pass_stream(%Engine{} = engine, pass_1_stream, response_format, opts) do
    Stream.resource(
      fn ->
        {:pass_1,
         %{
           cont: seed_step_cont(pass_1_stream),
           engine: engine,
           opts: opts,
           response_format: response_format
         }}
      end,
      &two_pass_next/1,
      &two_pass_after/1
    )
  end

  defp two_pass_next({:pass_1, %{cont: {:suspended, _last, cont}} = data}) do
    case cont.({:cont, nil}) do
      {:suspended, {:chat_completed, %{result: %ChatResult{} = pass_1_result}}, _next_cont} ->
        # Suppress pass-1's :chat_completed; decide pass 2.
        if pass_1_result.halted_reason in [:completed, :max_turns, :halt_when] do
          start_pass_2(data, pass_1_result)
        else
          # Skip pass 2 — emit a synthesized :chat_completed reflecting
          # the pass_1 halt augmented with structured_finalize metadata.
          augmented = %ChatResult{
            pass_1_result
            | metadata:
                Map.put(pass_1_result.metadata, :structured_finalize, %{
                  pass_1_halted: pass_1_result.halted_reason
                })
          }

          {[Event.chat_completed(augmented)], {:done, nil}}
        end

      {:suspended, event, next_cont} ->
        new_data = %{data | cont: {:suspended, event, next_cont}}
        {[event], {:pass_1, new_data}}

      {_done_or_halted, _acc} ->
        # Pass 1 stream exhausted without :chat_completed (consumer halt
        # upstream) — degenerate; halt our outer stream too.
        {:halt, {:done, nil}}
    end
  end

  defp two_pass_next(
         {:pass_2, %{cont: {:suspended, _last, cont}, pass_1_result: pass_1_result} = data}
       ) do
    case cont.({:cont, nil}) do
      {:suspended, {:chat_completed, %{result: %ChatResult{} = pass_2_result}}, _next_cont} ->
        merged = merge_pass_results(pass_1_result, pass_2_result)
        {[Event.chat_completed(merged)], {:done, nil}}

      {:suspended, event, next_cont} ->
        new_data = %{data | cont: {:suspended, event, next_cont}}
        {[event], {:pass_2, new_data}}

      {_done_or_halted, _acc} ->
        {:halt, {:done, nil}}
    end
  end

  defp two_pass_next({:done, _}), do: {:halt, {:done, nil}}

  defp start_pass_2(
         %{engine: engine, opts: opts, response_format: response_format},
         %ChatResult{} = pass_1_result
       ) do
    nudge =
      Keyword.get(opts, :structured_finalize_nudge) ||
        Application.get_env(:allm, :structured_finalize_nudge) ||
        "Now provide your final structured response."

    pass_2_thread =
      case nudge do
        "" -> pass_1_result.thread
        _ -> Thread.add_message(pass_1_result.thread, %Message{role: :user, content: nudge})
      end

    finalize_engine = %{engine | tools: []}

    pass_2_opts =
      opts
      |> Keyword.put(:structured_finalize, false)
      |> Keyword.put(:response_format, response_format)
      |> Keyword.put(:max_turns, 1)

    case do_stream_call(finalize_engine, pass_2_thread, pass_2_opts, 1) do
      {:ok, pass_2_stream} ->
        new_data = %{
          cont: seed_step_cont(pass_2_stream),
          pass_1_result: pass_1_result
        }

        # No events to emit yet — recurse to drain pass-2's first event.
        two_pass_next({:pass_2, new_data})

      {:error, struct} ->
        # Pass 2 pre-flight failed; surface a synthesized :chat_completed
        # carrying the pass_1 result augmented with the error metadata.
        augmented = %ChatResult{
          pass_1_result
          | metadata:
              Map.merge(pass_1_result.metadata, %{
                structured_finalize: %{
                  pass_1_halted: pass_1_result.halted_reason,
                  pass_2_error: struct
                }
              })
        }

        {[Event.chat_completed(augmented)], {:done, nil}}
    end
  end

  defp two_pass_after({:pass_1, %{cont: {:suspended, _last, cont}}}) do
    _ = cont.({:halt, :consumer_halt})
    :ok
  rescue
    _ -> :ok
  end

  defp two_pass_after({:pass_2, %{cont: {:suspended, _last, cont}}}) do
    _ = cont.({:halt, :consumer_halt})
    :ok
  rescue
    _ -> :ok
  end

  defp two_pass_after({:done, _}), do: :ok

  defp do_stream_call(%Engine{} = engine, thread_or_messages, opts, max_turns) do
    with {:ok, thread} <- normalise_thread(thread_or_messages),
         :ok <- Validate.thread(thread),
         {:ok, first_step_stream} <- stream_step(engine, thread, opts) do
      {:ok, build_chat_stream(engine, thread, first_step_stream, opts, max_turns)}
    end
  end

  defp run_loop(%LoopState{max_turns: max_turns} = init_state) do
    result =
      Enum.reduce_while(0..(max_turns - 1), {:ok, init_state}, fn idx, {:ok, state} ->
        run_step(state, idx)
      end)

    # The `:continue` branch's `check_max_turns/3` guarantees the LAST iteration
    # always halts (`step_index + 1 >= max_turns`). The `Enum.reduce_while/3`
    # natural-exhaustion arm is therefore unreachable and intentionally absent.
    case result do
      {:halt, %LoopState{} = halted_state} ->
        {:ok, build_chat_result(halted_state)}

      {:error, _} = err ->
        err
    end
  end

  defp run_step(
         %LoopState{engine: engine, opts: opts, thread: thread, max_turns: max_turns} = state,
         idx
       ) do
    case step(engine, thread, opts) do
      {:ok, %StepResult{} = sr} ->
        new_steps = state.steps ++ [sr]

        case terminal_condition(sr, opts, idx, sr.thread, max_turns) do
          {:halt, :ask_user, halt_meta} ->
            question_msg = %Message{
              role: :assistant,
              content: halt_meta.pending_question,
              metadata: %{ask_user: true, tool_call_id: halt_meta.pending_tool_call_id}
            }

            new_thread = Thread.add_message(sr.thread, question_msg)

            halted = %LoopState{
              state
              | thread: new_thread,
                steps: new_steps,
                step_index: idx + 1,
                halted_reason: :ask_user,
                halt_metadata: halt_meta,
                pending_question: halt_meta.pending_question,
                pending_tool_call_id: halt_meta.pending_tool_call_id
            }

            {:halt, {:halt, halted}}

          {:halt, reason, halt_meta} ->
            halted = %LoopState{
              state
              | thread: sr.thread,
                steps: new_steps,
                step_index: idx + 1,
                halted_reason: reason,
                halt_metadata: halt_meta
            }

            {:halt, {:halt, halted}}

          :continue ->
            advanced = %LoopState{
              state
              | thread: sr.thread,
                steps: new_steps,
                step_index: idx + 1
            }

            {:cont, {:ok, advanced}}
        end

      {:error, _struct} = err ->
        # First-step pre-flight error surfaces verbatim; subsequent-step
        # errors should not normally reach this branch because mid-stream
        # adapter errors fold into the response (CLAUDE.md mid-stream-error
        # invariant). For totality, if a non-first step returns {:error, _},
        # surface it as halted_reason: :error.
        if idx == 0 do
          {:halt, err}
        else
          halted = %LoopState{
            state
            | step_index: idx,
              halted_reason: :error,
              halt_metadata: %{error: elem(err, 1)}
          }

          {:halt, {:halt, halted}}
        end
    end
  end

  # Single construction point for ChatResult — both run/3 and the future
  # stream/3 Phase F call this. See Phase 7 design Non-obvious Decision #4.
  #
  # Reached only by the run-loop halt arm in batch 2; batch 3's Chat.stream/3
  # Phase F can reach the empty-steps fallback when the consumer halts the
  # stream before any step completes — tested in test/allm/chat_stream_test.exs
  # (Phase 7.4).
  @spec build_chat_result(LoopState.t()) :: ChatResult.t()
  defp build_chat_result(%LoopState{} = state) do
    final_response =
      case state.steps do
        [] -> nil
        steps -> List.last(steps).response
      end

    %ChatResult{
      thread: state.thread,
      final_response: final_response,
      steps: state.steps,
      halted_reason: state.halted_reason || :completed,
      pending_question: state.pending_question,
      pending_tool_call_id: state.pending_tool_call_id,
      metadata: state.halt_metadata
    }
  end

  # Seven-entry total order over a step result. See Phase 7 design
  # Non-obvious Decision #5. Ordering is load-bearing; do not reorder.
  #
  # `max_turns` is passed explicitly (not via `opts`) so the helper has no
  # implicit dependency on a sentinel key; both `run/3` and (future)
  # `stream/3` resolve `max_turns` at entry per Decision #9 and pass the
  # resolved value here.
  @spec terminal_condition(StepResult.t(), keyword(), non_neg_integer(), Thread.t(), pos_integer()) ::
          :continue | {:halt, atom(), map()}
  defp terminal_condition(%StepResult{} = sr, opts, step_index, _thread, max_turns) do
    cond do
      sr.metadata[:halted_reason] == :ask_user -> ask_user_halt(sr)
      sr.metadata[:halted_reason] == :tool_error -> tool_error_halt(sr)
      custom_halt_atom?(sr) -> custom_halt(sr)
      per_tool_manual?(sr) -> per_tool_manual_halt(sr, step_index)
      sr.metadata[:mode] == :manual -> {:halt, :manual_tool_calls, %{manual_turn_index: step_index}}
      sr.response.finish_reason in [:stop, :length, :content_filter] -> {:halt, :completed, %{}}
      sr.response.finish_reason == :error -> error_halt(sr)
      true -> halt_when_or_max_turns(sr, opts, step_index, max_turns)
    end
  end

  # Phase 18.2 — per-tool manual halt detector (Decision #11). The new clause
  # is inserted BEFORE the `metadata[:mode] == :manual` clause; whole-loop
  # turns NEVER set `metadata.manual_tool_calls`, so this guard's `false` for
  # whole-loop and the existing path's behavior is unchanged.
  defp per_tool_manual?(%StepResult{metadata: meta}) do
    is_list(meta[:manual_tool_calls]) and meta.manual_tool_calls != []
  end

  defp per_tool_manual_halt(%StepResult{metadata: meta}, step_index) do
    {:halt, :manual_tool_calls,
     %{manual_turn_index: step_index, manual_tool_calls: meta.manual_tool_calls}}
  end

  defp ask_user_halt(%StepResult{metadata: meta}) do
    {:halt, :ask_user,
     %{
       pending_question: meta[:pending_question],
       pending_tool_call_id: meta[:pending_tool_call_id],
       ask_user_opts: meta[:ask_user_opts]
     }}
  end

  defp tool_error_halt(%StepResult{metadata: meta}) do
    base = %{halt_tool_call_id: meta[:halt_tool_call_id]}

    final =
      case Map.fetch(meta, :on_tool_error_exception) do
        {:ok, exc} -> Map.put(base, :on_tool_error_exception, exc)
        :error -> base
      end

    {:halt, :tool_error, final}
  end

  defp custom_halt_atom?(%StepResult{metadata: meta}) do
    reason = meta[:halted_reason]
    is_atom(reason) and reason not in [nil, :ask_user, :tool_error]
  end

  defp custom_halt(%StepResult{metadata: meta}) do
    {:halt, meta[:halted_reason],
     %{halt_tool_call_id: meta[:halt_tool_call_id], halt_result: meta[:halt_result]}}
  end

  defp error_halt(%StepResult{response: response}) do
    {:halt, :error, %{error: Map.get(response.metadata, :error)}}
  end

  defp halt_when_or_max_turns(%StepResult{} = sr, opts, step_index, max_turns) do
    case Keyword.get(opts, :halt_when) do
      nil -> check_max_turns(step_index, max_turns)
      fun when is_function(fun, 1) -> apply_halt_when(fun, sr, step_index, max_turns)
    end
  end

  defp apply_halt_when(fun, %StepResult{} = sr, step_index, max_turns) do
    if fun.(sr) do
      {:halt, :halt_when, %{halt_when_step_index: step_index}}
    else
      check_max_turns(step_index, max_turns)
    end
  end

  defp check_max_turns(step_index, max_turns) do
    if step_index + 1 >= max_turns do
      {:halt, :max_turns, %{max_turns: max_turns}}
    else
      :continue
    end
  end

  defp resolve_max_turns(%Engine{params: params}, opts) do
    Keyword.get(opts, :max_turns) ||
      Map.get(params || %{}, :max_turns) ||
      Application.get_env(:allm, :max_turns) ||
      8
  end

  defp validate_max_turns!(n) when is_integer(n) and n > 0, do: :ok

  defp validate_max_turns!(other) do
    raise ArgumentError,
          "max_turns must be a positive integer; got: #{inspect(other)}"
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
        run_auto_tool_calls_step(engine, thread, assistant_msg, response, opts)

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

  # Phase 18.2 — chat-layer preflight runs BEFORE partition (Decision #14) so
  # the partition never observes an unknown-tool name. Mirrors the streaming
  # path's preflight at `chat.ex` `start_phase_b/3`. Extracted from `do_step/4`
  # to keep that function under Credo's nesting threshold.
  defp run_auto_tool_calls_step(
         %Engine{} = engine,
         thread,
         assistant_msg,
         %Response{} = response,
         opts
       ) do
    tools = Engine.resolve_tools(engine, opts)

    case preflight_unknown(response.tool_calls, tools) do
      :ok ->
        dispatch_partitioned_tool_calls(engine, thread, assistant_msg, response, tools, opts)

      {:error, %EngineError{}} = err ->
        err
    end
  end

  defp dispatch_partitioned_tool_calls(engine, thread, assistant_msg, response, tools, opts) do
    case partition_tool_calls(response.tool_calls, tools) do
      {_auto, []} ->
        # Pure-auto — byte-identical to the original path: no extra
        # work, run_tools_non_streaming/4 re-resolves tools internally.
        run_tools_non_streaming(engine, thread, assistant_msg, response, opts)

      {[], manual_tcs} ->
        # Pure-manual under :auto — equivalent to whole-loop manual for
        # this turn; no tools execute; metadata.manual_tool_calls (NOT
        # :mode) distinguishes per-tool path per Decision #1.
        {:ok, manual_only_step_result(thread, assistant_msg, response, manual_tcs)}

      {auto_tcs, manual_tcs} ->
        # Mixed — run auto tools eagerly, halt with manual pending.
        run_tools_then_halt(
          engine,
          thread,
          assistant_msg,
          response,
          auto_tcs,
          manual_tcs,
          opts
        )
    end
  end

  # Partition `tool_calls` into `{auto, manual}` by `Tool.manual` flag. Input
  # order is preserved within each bucket (the prepend-then-reverse keeps the
  # call ordering the model committed to). Unknown-tool names go to the auto
  # bucket — the chat-layer preflight runs BEFORE this helper, so unknowns
  # short-circuit the call site before the partition observes them; the auto
  # routing is defense-in-depth.
  #
  # See PHASE_18_DESIGN.md §18.2.2 and Decisions #2, #6, #10.
  @spec partition_tool_calls([ToolCall.t()], [Tool.t()]) ::
          {[ToolCall.t()], [ToolCall.t()]}
  defp partition_tool_calls(tool_calls, tools) do
    tool_index = Map.new(tools, fn %Tool{name: n} = t -> {n, t} end)

    {auto, manual} =
      Enum.reduce(tool_calls, {[], []}, fn %ToolCall{name: name} = tc, {auto, manual} ->
        case Map.get(tool_index, name) do
          %Tool{manual: true} -> {auto, [tc | manual]}
          _other -> {[tc | auto], manual}
        end
      end)

    {Enum.reverse(auto), Enum.reverse(manual)}
  end

  # Pure-manual sub-arm: append the assistant message, surface the manual
  # tool_calls in metadata. The `:mode` key is NOT set — distinguishes the
  # per-tool path from the whole-loop `mode: :manual` path (Decision #1).
  defp manual_only_step_result(thread, assistant_msg, %Response{} = response, manual_tcs) do
    new_thread = Thread.add_message(thread, assistant_msg)

    %StepResult{
      thread: new_thread,
      response: response,
      tool_results: [],
      done?: false,
      metadata: %{manual_tool_calls: manual_tcs}
    }
  end

  # Mixed sub-arm: run the auto subset via the existing ToolRunner path, then
  # surface the manual subset in metadata. The thread carries the assistant
  # message + auto-bucket :tool messages, but NO :tool messages for the manual
  # ids — those are pending for the caller to resolve (Decision #4).
  defp run_tools_then_halt(
         %Engine{} = engine,
         thread,
         assistant_msg,
         %Response{} = response,
         auto_tcs,
         manual_tcs,
         opts
       ) do
    tools = Engine.resolve_tools(engine, opts)
    runner_opts = build_runner_opts(engine, response, opts)

    case ToolRunner.run_tool_calls(auto_tcs, tools, runner_opts) do
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
           metadata: %{manual_tool_calls: manual_tcs}
         }}

      {:ok, tool_msgs, halt_meta} ->
        # Auto-bucket halt (e.g., ask_user, tool_error, custom halt atom)
        # wins over the per-tool manual surface — the per-call halt is more
        # urgent than queuing a manual approval. The existing terminal
        # condition on `halt_meta` keys (handled in terminal_condition/5)
        # routes the halt; we do NOT append manual_tcs here.
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
    # Phase 9.4: populate Usage cost fields when LLMDB is loaded.
    resolved_model = Engine.resolve_model(engine, opts)
    usage = Capability.populate_costs(response.usage, resolved_model)
    response = %Response{response | usage: usage}
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
        dispatch_partitioned_stream(data, response, assistant_msg)

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

  # Phase 18.3 — partition by `Tool.manual` flag (Decision #7). Extracted
  # from `transition_a_to_b/1` to keep that function under Credo's cyclomatic
  # complexity threshold; `mode == :manual` short-circuits BEFORE this helper
  # runs so it sees only the `:auto` arm (Decision #5/#13).
  defp dispatch_partitioned_stream(
         %{engine: engine, opts: opts} = data,
         %Response{} = response,
         assistant_msg
       ) do
    tools = Engine.resolve_tools(engine, opts)

    case partition_tool_calls(response.tool_calls, tools) do
      {_auto, []} ->
        # Pure-auto — UNCHANGED path.
        start_phase_b(data, response, assistant_msg)

      {[], manual_tcs} ->
        # Pure-manual under :auto — skip Phase B entirely; no
        # `:tool_execution_*` events; `:step_completed` fires
        # immediately with `manual_tool_calls: manual_tcs`.
        start_phase_c_manual_only(data, response, assistant_msg, manual_tcs)

      {auto_tcs, manual_tcs} ->
        # Mixed — run auto bucket via Phase B; thread manual_tcs
        # through phase_b_data so the eventual `:step_completed`
        # event carries it.
        start_phase_b_partial(data, response, assistant_msg, auto_tcs, manual_tcs)
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
          manual_tcs: [],
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
          halt_metadata: nil,
          manual_tcs: []
        }

        # Emit the error event, move to :phase_c which will emit a
        # terminal :step_completed. The step_completed thread still has
        # just the assistant message (no tool-role messages).
        {[{:error, err}], {:phase_c, phase_c_data}}
    end
  end

  # Phase 18.3 — mixed-bucket Phase B bootstrap. Identical to `start_phase_b/3`
  # except (a) `auto_tcs` (not `response.tool_calls`) is passed to
  # `ToolRunner.stream_tool_calls/3`, AND (b) `manual_tcs` is threaded through
  # `phase_b_data` so `transition_b_to_c/1` can write it onto `phase_c_data`
  # for `emit_step_completed/1`. See PHASE_18_DESIGN.md §18.3.2 + Decision #7.
  defp start_phase_b_partial(
         %{engine: engine, thread: thread, opts: opts} = _data,
         %Response{} = response,
         assistant_msg,
         auto_tcs,
         manual_tcs
       ) do
    tools = Engine.resolve_tools(engine, opts)
    runner_opts = build_runner_opts(engine, response, opts)

    # Preflight is on the FULL response.tool_calls in start_phase_b/3 above;
    # for the mixed-bucket path the chat-layer cond arm in transition_a_to_b/1
    # has already partitioned. Unknown-tool names route to the auto bucket
    # (per partition_tool_calls/2 invariant), so preflight on auto_tcs catches
    # them — defense-in-depth identical to start_phase_b/3.
    case preflight_unknown(auto_tcs, tools) do
      :ok ->
        tool_stream = ToolRunner.stream_tool_calls(auto_tcs, tools, runner_opts)
        cont = &Enumerable.reduce(tool_stream, &1, fn event, _ -> {:suspend, event} end)

        phase_b_data = %{
          engine: engine,
          thread: thread,
          opts: opts,
          response: response,
          assistant_msg: assistant_msg,
          tool_msgs: [],
          halt_metadata: nil,
          manual_tcs: manual_tcs,
          tool_cont: {:suspended, nil, cont}
        }

        pull_next_phase_b(phase_b_data)

      {:error, %EngineError{} = err} ->
        phase_c_data = %{
          engine: engine,
          thread: Thread.add_message(thread, assistant_msg),
          response: response,
          assistant_msg: assistant_msg,
          tool_msgs: [],
          mode: :auto,
          halt_metadata: nil,
          manual_tcs: manual_tcs
        }

        {[{:error, err}], {:phase_c, phase_c_data}}
    end
  end

  # Phase 18.3 — pure-manual streaming sub-arm. Skips Phase B entirely (no
  # tool execution events, no ToolRunner enumerable to clean up); appends
  # the assistant message to the thread and routes directly to Phase C with
  # `manual_tcs` on the phase_c_data so `emit_step_completed/1` includes the
  # bucket on the `:step_completed` event payload.
  #
  # Mirrors the existing whole-loop manual branch's thread shape (assistant
  # message appended; no `:tool` messages); see PHASE_18_DESIGN.md §18.3.2
  # implementation checklist line item.
  defp start_phase_c_manual_only(
         %{engine: engine, thread: thread} = _data,
         %Response{} = response,
         assistant_msg,
         manual_tcs
       ) do
    phase_c_data = %{
      engine: engine,
      thread: Thread.add_message(thread, assistant_msg),
      response: response,
      assistant_msg: assistant_msg,
      tool_msgs: [],
      mode: :auto,
      halt_metadata: nil,
      manual_tcs: manual_tcs
    }

    stream_next({:phase_c, phase_c_data})
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

  defp update_phase_b_from_event(
         data,
         {:tool_halt, %{tool_call_id: id, reason: reason, result: r} = p}
       ) do
    # First-halt-wins — only set halt_metadata if not already set.
    case data.halt_metadata do
      nil ->
        # Phase 7.6 cleanup B1: prefer the payload's pre-encoded `:content`
        # (set by `ToolRunner` via `Event.tool_halt/4`); fall back to the
        # encoder for callers that emit `Event.tool_halt/3` events.
        content =
          Map.get_lazy(p, :content, fn ->
            encode_for_phase_b(r, data.engine, data.opts)
          end)

        tool_msg = %Message{role: :tool, tool_call_id: id, content: content, metadata: %{}}
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

  # Best-effort encoding of the halt result for a tool-role message —
  # used only as a fallback when a `:tool_halt` event arrives without a
  # pre-encoded `:content` payload key (e.g. an external producer using
  # `Event.tool_halt/3`). The internal Phase 6/7 path uses
  # `Event.tool_halt/4` so the encoder runs once in `ToolRunner`.
  defp encode_for_phase_b(result, engine, opts) do
    encoder = resolve_encoder(engine, opts)

    try do
      encoder.encode(result)
    rescue
      _ -> inspect(result)
    end
  end

  defp resolve_encoder(%Engine{tool_result_encoder: mod}, opts) do
    cond do
      override = Keyword.get(opts, :tool_result_encoder) -> override
      mod != nil -> mod
      true -> ALLM.ToolResultEncoder.JSON
    end
  end

  # --- Phase B → C transition: finalise the thread and queue :step_completed ---

  defp transition_b_to_c(
         %{
           engine: engine,
           thread: thread,
           response: response,
           assistant_msg: assistant_msg,
           tool_msgs: tool_msgs,
           halt_metadata: halt_metadata
         } = data
       ) do
    final_thread =
      thread
      |> Thread.add_message(assistant_msg)
      |> Thread.add_messages(tool_msgs)

    # Phase 18.3 — thread the manual bucket from phase_b_data into
    # phase_c_data so emit_step_completed/1 can build the /4-arity event.
    manual_tcs = Map.get(data, :manual_tcs, [])

    phase_c_data = %{
      engine: engine,
      thread: final_thread,
      response: response,
      assistant_msg: assistant_msg,
      tool_msgs: tool_msgs,
      mode: :auto,
      halt_metadata: halt_metadata,
      manual_tcs: manual_tcs
    }

    stream_next({:phase_c, phase_c_data})
  end

  # --- Phase C: emit :step_completed and halt ---

  defp emit_step_completed(%{thread: thread, response: response, mode: mode} = data) do
    # Phase 7 retro F1+F3: thread the orchestration mode through the
    # `:step_completed` event payload so that downstream reducers
    # (StreamCollector's `:step_completed` fold + multi-turn chat
    # orchestrators) can produce StepResult metadata identical to the
    # non-streaming `Chat.do_step/4` path.
    #
    # Phase 18.3: also thread the per-tool manual bucket through the
    # payload's :manual_tool_calls key (Decision #7). The /4-arity
    # constructor accepts an empty list as the default; the StreamCollector
    # fold extracts the key and merges onto step metadata IFF non-empty
    # (Decision #12).
    manual_tcs = Map.get(data, :manual_tcs, [])
    event = Event.step_completed(response, thread, mode, manual_tcs)
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
  # Multi-turn streaming: two-phase Stream.resource/3 (Phase 7 Decision #1)
  # ---------------------------------------------------------------------------

  defp build_chat_stream(%Engine{} = engine, %Thread{} = thread, first_step_stream, opts, max_turns) do
    Stream.resource(
      fn -> init_chat_state(engine, thread, first_step_stream, opts, max_turns) end,
      &chat_stream_next/1,
      &outer_after_fun/1
    )
  end

  defp init_chat_state(engine, thread, first_step_stream, opts, max_turns) do
    {:step,
     %{
       engine: engine,
       opts: opts,
       max_turns: max_turns,
       thread: thread,
       collector: StreamCollector.new(thread),
       loop_state: %LoopState{
         engine: engine,
         opts: opts,
         initial_thread: thread,
         thread: thread,
         max_turns: max_turns
       },
       step_cont: seed_step_cont(first_step_stream),
       step_index: 0
     }}
  end

  defp seed_step_cont(stream_step_enum) do
    cont = &Enumerable.reduce(stream_step_enum, &1, fn event, _ -> {:suspend, event} end)
    {:suspended, nil, cont}
  end

  defp chat_stream_next({:step, data}), do: pull_next_phase_s(data)

  defp chat_stream_next({:final, %{chat_result: chat_result}}) do
    {[Event.chat_completed(chat_result)], {:done, nil}}
  end

  defp chat_stream_next({:done, _} = state), do: {:halt, state}

  defp pull_next_phase_s(%{step_cont: {:suspended, _last, cont}} = data) do
    # The inner stream_step/3 ALWAYS terminates with a :step_completed
    # event followed by `:done` on the next pull. We pull events until we
    # see :step_completed (the transition trigger); :done / :halted
    # branches are unreachable through normal flow but we route them to
    # finalise_unexpected/3 for totality.
    case cont.({:cont, nil}) do
      {:suspended, {:step_completed, _payload} = event, _next_cont} ->
        handle_step_completed(data, event)

      {:suspended, event, next_cont} ->
        new_collector = StreamCollector.apply_event(data.collector, event)
        new_data = %{data | collector: new_collector, step_cont: {:suspended, event, next_cont}}
        {[event], {:step, new_data}}

      {_done_or_halted, _acc} ->
        finalise_unexpected(data)
    end
  end

  defp handle_step_completed(
         data,
         {:step_completed, %{response: r, thread: t} = payload} = event
       ) do
    # State-boundary ownership (Phase 7 design 7.4.2 — load-bearing):
    # 1. Read pre-fold outer-collector state to compute StepResult. Mode
    #    flows through the event payload itself (Phase 7 retro F1+F3).
    mode = Map.get(payload, :mode, :auto)
    # Phase 18.3 — extract per-tool manual bucket so `terminal_condition/5`
    # can fire `per_tool_manual?/1` and halt with `:manual_tool_calls`.
    manual_tcs = Map.get(payload, :manual_tool_calls, [])
    step_result = step_result_from_outer_collector(data.collector, r, t, mode, manual_tcs)

    # 2. NOW fold the :step_completed event into the outer collector
    #    (which resets per-step sub-state per Phase 7 Decision #6).
    folded_collector = StreamCollector.apply_event(data.collector, event)

    new_steps = data.loop_state.steps ++ [step_result]

    case terminal_condition(step_result, data.opts, data.step_index, t, data.max_turns) do
      :continue ->
        # Start the next step; seed its continuation. The current outer
        # step_cont is already exhausted (we just pulled :step_completed,
        # the stream_step/3 stream's terminal event); no need to halt it.
        # stream_step/3 cannot error here — engine.adapter was pre-flight-
        # validated at stream/3 entry, the augmented thread is always
        # well-formed (Phase 6 builds tool messages with valid shape),
        # and StreamRunner.run pre-flight checks have already passed for
        # this engine. Mid-stream adapter errors fold into the response,
        # not the {:ok|:error} return.
        {:ok, next_step_stream} = stream_step(data.engine, t, data.opts)

        new_loop_state = %LoopState{
          data.loop_state
          | thread: t,
            steps: new_steps,
            step_index: data.step_index + 1
        }

        new_data =
          data
          |> Map.put(:thread, t)
          |> Map.put(:collector, folded_collector)
          |> Map.put(:loop_state, new_loop_state)
          |> Map.put(:step_cont, seed_step_cont(next_step_stream))
          |> Map.put(:step_index, data.step_index + 1)

        {[event], {:step, new_data}}

      {:halt, :ask_user, halt_meta} ->
        # Append assistant question message to the chat-result thread BEFORE
        # building chat_result (Phase 7 Invariant 7 + 8). The :step_completed
        # event already streamed with thread t (without the question); the
        # question lives ONLY on chat_result.thread.
        question_msg = %Message{
          role: :assistant,
          content: halt_meta.pending_question,
          metadata: %{ask_user: true, tool_call_id: halt_meta.pending_tool_call_id}
        }

        new_thread = Thread.add_message(t, question_msg)

        halted_loop_state = %LoopState{
          data.loop_state
          | thread: new_thread,
            steps: new_steps,
            step_index: data.step_index + 1,
            halted_reason: :ask_user,
            halt_metadata: halt_meta,
            pending_question: halt_meta.pending_question,
            pending_tool_call_id: halt_meta.pending_tool_call_id
        }

        chat_result = build_chat_result(halted_loop_state)
        {[event], {:final, %{chat_result: chat_result}}}

      {:halt, reason, halt_meta} ->
        halted_loop_state = %LoopState{
          data.loop_state
          | thread: t,
            steps: new_steps,
            step_index: data.step_index + 1,
            halted_reason: reason,
            halt_metadata: halt_meta
        }

        chat_result = build_chat_result(halted_loop_state)
        {[event], {:final, %{chat_result: chat_result}}}
    end
  end

  # Defensive — unreachable through normal flow because stream_step/3
  # ALWAYS terminates with :step_completed before its enumerable exhausts.
  defp finalise_unexpected(data) do
    halted_loop_state = %LoopState{
      data.loop_state
      | thread: data.thread,
        halted_reason: :cancelled,
        halt_metadata: %{}
    }

    chat_result = build_chat_result(halted_loop_state)
    {[], {:final, %{chat_result: chat_result}}}
  end

  # see PHASE_7_DESIGN.md §7.4.2 — read pre-fold collector state to mirror
  # the StreamCollector :step_completed fold's StepResult shape.
  #
  # Phase 7 retro F1+F2+F3: `mode` arrives via the `:step_completed` event
  # payload (added by `Chat.emit_step_completed/1`); both StepResult
  # constructions (this helper and the StreamCollector fold) read it from
  # the same source. Reuses the promoted `StreamCollector.step_done?/1` /
  # `merge_halt_metadata/2` helpers — no clones (retro F2).
  defp step_result_from_outer_collector(
         %StreamCollector{} = c,
         %Response{} = response,
         %Thread{} = thread,
         mode,
         manual_tcs
       )
       when mode in [:auto, :manual] and is_list(manual_tcs) do
    base_metadata = StreamCollector.merge_halt_metadata(%{}, c.halt)

    metadata =
      if mode == :manual and response.finish_reason == :tool_calls do
        Map.put(base_metadata, :mode, :manual)
      else
        base_metadata
      end

    # Phase 18.3 / Decision #12: write `manual_tool_calls` onto step
    # metadata IFF non-empty — empty list is the absence-of-key default
    # (mirrors StreamCollector.apply_event/2's :step_completed fold).
    metadata =
      if manual_tcs != [] do
        Map.put(metadata, :manual_tool_calls, manual_tcs)
      else
        metadata
      end

    %StepResult{
      thread: thread,
      response: response,
      tool_results: c.tool_results,
      done?: StreamCollector.step_done?(c),
      metadata: metadata
    }
  end

  # Phase 7 Decision #1 cleanup chain: Chat.stream/3 after_fun → halt
  # step_cont (which triggers stream_step/3's after_fun, which halts
  # adapter_cont or tool_cont). Phase F has no sub-stream to halt.
  defp outer_after_fun({:step, %{step_cont: {:suspended, _last, cont}}}) do
    _ = cont.({:halt, :consumer_halt})
    :ok
  rescue
    _ -> :ok
  end

  defp outer_after_fun({:final, _}), do: :ok
  defp outer_after_fun({:done, _}), do: :ok

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
    base = [
      tools: Engine.resolve_tools(engine, opts),
      stream: Keyword.get(flags, :stream, false)
    ]

    extra =
      [
        response_format: Keyword.get(opts, :response_format),
        tool_choice: Keyword.get(opts, :tool_choice)
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    structured =
      case Keyword.get(opts, :structured_finalize) do
        true -> [structured_finalize: true]
        _ -> []
      end

    Request.new(msgs, base ++ extra ++ structured)
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
