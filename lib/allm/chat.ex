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
    Thread,
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
  | atom() (user) | Handler returned `{:halt, reason, result}` |

  Adapter pre-flight errors surface as `{:error, struct}` from the FIRST
  step's `step/3` call. Mid-loop adapter errors fold into the step's
  response and surface as `halted_reason: :error` on the `ChatResult`.

  ## Examples

      iex> engine = ALLM.Engine.new(
      ...>   adapter: ALLM.Providers.Fake,
      ...>   adapter_opts: [
      ...>     scripts: [
      ...>       [{:tool_call, id: "c0", name: "echo", arguments: %{"x" => 1}},
      ...>        {:finish, :tool_calls}],
      ...>       [{:text, "done"}, {:finish, :stop}]
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

  @doc """
  Stream a multi-turn chat loop and return a lazy stream of `ALLM.Event`
  values terminating in exactly one `:chat_completed` event.

  Composes `stream_step/3` sub-streams sequentially: the outer
  `Stream.resource/3` drives the current step's reducer one event at a
  time (mirroring Phase 6's `stream_step/3` continuation idiom one layer
  up). When a step completes, `terminal_condition/5` decides whether to
  start a new step (with the augmented thread) or transition to the
  terminal `:chat_completed` emission.

  ## Multi-turn stream composition

  Two-phase state machine (see Phase 7 design Non-obvious Decision #1):

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

  Consumer halt produces NO `:chat_completed` event (per spec §30
  cancellation contract). Callers needing a final `%ChatResult{}` for a
  cancelled stream collect events and call
  `ALLM.StreamCollector.to_chat_result/1` on the partial state.

  ## Ask-user thread asymmetry

  When a step's handler returns `{:ask_user, _}`, the streamed
  `:step_completed.thread` does NOT include the assistant question
  message — only the `:chat_completed.result.thread` does (Phase 7
  Invariant 8). Consumers persisting thread state across turns should
  read `ChatResult.thread`, not `:step_completed.thread`.

  ## Examples

      iex> engine = ALLM.Engine.new(
      ...>   adapter: ALLM.Providers.Fake,
      ...>   adapter_opts: [
      ...>     scripts: [
      ...>       [{:tool_call, id: "c0", name: "echo", arguments: %{"x" => 1}},
      ...>        {:finish, :tool_calls}],
      ...>       [{:text, "done"}, {:finish, :stop}]
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
      sr.metadata[:mode] == :manual -> {:halt, :manual_tool_calls, %{manual_turn_index: step_index}}
      sr.response.finish_reason in [:stop, :length, :content_filter] -> {:halt, :completed, %{}}
      sr.response.finish_reason == :error -> error_halt(sr)
      true -> halt_when_or_max_turns(sr, opts, step_index, max_turns)
    end
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

  defp emit_step_completed(%{thread: thread, response: response, mode: mode} = data) do
    # Phase 7 retro F1+F3: thread the orchestration mode through the
    # `:step_completed` event payload so that downstream reducers
    # (StreamCollector's `:step_completed` fold + multi-turn chat
    # orchestrators) can produce StepResult metadata identical to the
    # non-streaming `Chat.do_step/4` path.
    event = Event.step_completed(response, thread, mode)
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
    step_result = step_result_from_outer_collector(data.collector, r, t, mode)

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
         mode
       )
       when mode in [:auto, :manual] do
    base_metadata = StreamCollector.merge_halt_metadata(%{}, c.halt)

    metadata =
      if mode == :manual and response.finish_reason == :tool_calls do
        Map.put(base_metadata, :mode, :manual)
      else
        base_metadata
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
