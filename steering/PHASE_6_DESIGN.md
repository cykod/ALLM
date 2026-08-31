# Phase 6: `stream_step/3` + `step/3` — Single-Turn Tool Loop — Design Document

> **Goal:** Ship the first Layer C surface that executes tools: `ALLM.step/3` runs one adapter call, executes any returned tool calls in parallel via `ALLM.ToolRunner`, appends tool-role messages to the thread, and returns an `%ALLM.StepResult{}`. `ALLM.stream_step/3` does the same but emits adapter events in real time and orchestration events (`:tool_execution_started`, `:tool_execution_completed`, `:tool_result_encoded`, `:tool_halt`, `:ask_user_requested`, `:step_completed`) as they occur.
> **Outcome:** Calling `ALLM.step(engine, thread)` against a `Fake` engine whose script ends with `{:finish, :tool_calls}` executes every tool call via the engine's `tool_executor` (default `ALLM.ToolExecutor.Default`), encodes results via the engine's `tool_result_encoder` (default `ALLM.ToolResultEncoder.JSON`), appends one `:tool`-role message per tool call to the thread, and returns `{:ok, %StepResult{thread: updated_thread, response: response, tool_results: [msgs], done?: false}}`. `ALLM.stream_step/3` emits the same information as a live event stream. A stream-equivalence property asserts `step ≡ stream_step |> collect_step` across every Phase 4 fixture with a tool-call shape. `mix test`, `mix credo --strict`, `mix dialyzer`, `mix format --check-formatted` all green; coverage ≥ 90 % on every new file.
> **Spec sections:** §3 (stream-first), §4 (facade), §5.2 (tool handler return shapes, reserved halt reasons), §5.8 (StepResult shape and `done?` semantics), §7.3 (`ALLM.ToolExecutor`), §7.4 (`ALLM.ToolResultEncoder`), §8 (event protocol — no new variants; five Phase-6-owned tags gain collector fold clauses), §10.3 (`step/3`), §10.4 (`stream_step/3`), §12 (auto vs manual orchestration), §12.3 (ask-user — partial: Phase 6 signals suspension; Phase 8 wires Session transitions), §17 (`ALLM.ToolRunner`, `ALLM.Chat`), §19 (streaming options — adds `:on_tool_error`, `:tool_timeout` to the consumed set), §20 (error reasons — adds `:unknown_tool`, reuses `%ToolError{}` closed reasons), §30 (tool error policy: `:continue | :halt` in Phase 6; function form deferred), §31 (three property scenarios activated).
> **Layers touched:** C (stateless execution). No Layer A changes. No behaviour changes (`ALLM.ToolExecutor` / `ALLM.ToolResultEncoder` behaviours ship in Phase 3; `ALLM.ToolExecutor.Default` / `ALLM.ToolResultEncoder.JSON` ship in Phase 3). No new variants added to `ALLM.Event`'s closed union (the five Phase-6 orchestration tags were declared in Phase 1 per spec §8; Phase 5 left them in the `StreamCollector` catch-all; Phase 6 adds real per-tag clauses). Per `agent-spec/DESIGN.md`'s "Adding a new variant to a closed tagged-tuple union is a breaking change for every reducer" rule, this phase does **not** trigger that rule.
> **Phasing doc:** [`PROJECT_PHASING.md`](PROJECT_PHASING.md) Phase 6.

## Status

| Sub-phase | Description | Layer | Status |
|-----------|-------------|-------|--------|
| 6.1 | `ALLM.ToolRunner` — parallel tool execution + result encoding + streaming variant | C | Not Started |
| 6.2 | `ALLM.Chat.step/3` + `ALLM.Chat.stream_step/3` — step orchestration + stream composition | C | Not Started |
| 6.3 | `ALLM.step/3` + `ALLM.stream_step/3` — public facade + doctests | C | Not Started |
| 6.4 | Stream-equivalence property + §31 scenario activation + `StreamCollector` tool-results fold | C | Not Started |

**Overall Progress:** 0/4 sub-phases complete

## Overview

Phase 6 is the first phase that ships an orchestrated loop: the adapter produces tool calls, ALLM executes them, and the thread grows by the assistant message plus one `:tool`-role message per executed tool call. Everything below the orchestrator is already committed — `ALLM.Tool` and `ALLM.ToolCall` structs exist (`lib/allm/tool.ex:1-77`, `lib/allm/tool_call.ex:1-54`), the `ALLM.ToolExecutor` and `ALLM.ToolResultEncoder` behaviours ship with defaults (`lib/allm/tool_executor/default.ex:46-88`, `lib/allm/tool_result_encoder/json.ex:39-63`), `ALLM.Engine` exposes `resolve_tools/2` with the dedup-by-name semantics Phase 6 needs (`lib/allm/engine.ex:333-342`), `ALLM.Providers.Fake` emits `:tool_call_started`/`:tool_call_delta`/`:tool_call_completed`/`{:finish, :tool_calls}` deterministically (`lib/allm/providers/fake/script.ex:284-349`), and Phase 5 shipped the `stream_generate/3` / `generate/3` / `StreamCollector` path (`lib/allm/stream_runner.ex`, `lib/allm/runner.ex`, `lib/allm/stream_collector.ex`). Phase 6 wires the orchestration on top of that substrate.

The phase's load-bearing correctness property is **step-equivalence** (spec §3's second consequence made testable): for every scripted Fake fixture with a tool-call shape, `ALLM.step/3` and `ALLM.stream_step/3 |> collect_step` produce identical `%StepResult{}` values. That invariant mirrors Phase 5's stream-equivalence property for `generate ≡ stream_generate |> collect`, and is the gate Phase 7's `chat ≡ stream |> collect` will inherit. If Phase 6's implementation breaks step-equivalence, Phase 7 loses its foundation. The property test lives in `test/allm/step_equivalence_test.exs` and runs 100 iterations by default.

The phase's second critical obligation is **parallel tool execution without cancellation of in-flight work**. The `project phasing` document flags this as Phase 6 decision (a): `max_concurrency` default. Phase 6 sets `max_concurrency: min(length(tool_calls), System.schedulers_online() * 2)` — bounded so a 200-parallel-call pathological case doesn't swamp the scheduler, CPU-scaled so most real workloads run everything at once. `Task.async_stream/5` with `ordered: false` streams completed tools in completion order into the event stream. A failing or timing-out tool does NOT cancel its siblings; siblings run to completion, and the per-tool result (success, error, timeout, or handler-raised) is encoded independently. Phase 6 does not introduce `Task.Supervisor` — `Task.async_stream/5` calls the linked form, and consumer crash reasoning is inherited from the existing `Stream.resource/3` cleanup contract.

The phase's third design decision is the **`on_tool_error` policy subset**. Spec §30 defines three policy shapes: `:halt`, `:continue`, and a function form `(ToolCall.t(), term() -> {:continue, term()} | :halt)`. Phase 6 implements the two atom forms — `:continue` (default, encodes the error as the tool-result content and the step returns with `done?: false`) and `:halt` (encodes the error as the tool-result content AND sets `StepResult.done?: true` with `metadata[:halted_reason] = :tool_error`). The function form is deferred to Phase 7, where it slots naturally into the multi-turn `chat/3` surface alongside the `halt_when` callback. Phase 6's `on_tool_error` consumer lives in `ALLM.ToolRunner`; it does not see a function form and raises `ArgumentError` on one (documented caveat — users passing a function to `step/3` get a clear error rather than a silent Phase 7 promise).

The phase's fourth obligation is **streaming composition without leaking a second `Stream.resource/3`**. Phase 5 established that wrapping an adapter stream in an outer `Stream.resource/3` doubles cleanup registration. Phase 6's `stream_step/3` faces a new challenge: the adapter stream ends with `:tool_calls`, then the orchestrator dispatches tool executions that produce further events. This is NOT the same as Phase 5's "adapter events pass through a filter" case — Phase 6 must *generate* new events after the adapter stream closes. The approach (Non-obvious Decision #1): use `Stream.concat/1` to glue `[adapter_stream, tool_execution_stream, step_completed_stream]` into one enumerable. The adapter stream owns its cleanup per Phase 4; the tool-execution stream is a `Task.async_stream/5` wrapped via `Stream.flat_map/2` (Task.async_stream is an enumerable, already honors early halt via `Task.Supervisor`-style cleanup); the `:step_completed` emitter is a single-element `[event]` list. No new `Stream.resource/3` is introduced at the Phase 6 layer.

The phase's fifth obligation is a **minimal `StreamCollector` extension**: Phase 5 left `:tool_execution_*`, `:tool_result_encoded`, `:step_completed`, `:tool_halt`, `:ask_user_requested` in the catch-all (Phase 5 Non-obvious Decision #12). Phase 6 adds a single explicit clause for `:tool_result_encoded` — it accumulates tool-result content into a new `:tool_results` field on the collector struct so `to_step_result/1` returns `%StepResult{tool_results: [msgs]}` correctly when folded from a streaming step. The other four orchestration tags stay in the catch-all for Phase 6 (no collector state depends on them). Per Phase 5 Non-obvious Decision #5, Phase 6 inserts the new clause **ahead** of the catch-all without modifying any Phase 5 clause.

### Deliverables

- **New modules (main package):**
  - `ALLM.ToolRunner` (`lib/allm/tool_runner.ex`) — Internal Layer C orchestration per spec §17. Ships `run_tool_calls/3` (non-streaming, returns `{:ok, [Message.t()]} | {:error, term()} | {:halt, metadata}`) and `stream_tool_calls/3` (streaming, returns an enumerable of `ALLM.Event` values plus a terminal marker). Both are internal — users reach for `ALLM.step/3` / `ALLM.stream_step/3` instead.
  - `ALLM.Chat` (`lib/allm/chat.ex`) — Internal Layer C step runner per spec §17. Phase 6 ships `step/3` and `stream_step/3`; Phase 7 will add `run/3` and `stream/3` to the same module.
- **Modified modules:**
  - `lib/allm/stream_collector.ex` — add two fields (`:tool_results` and `:halt`); add three per-tag fold clauses for `:tool_result_encoded`, `:tool_halt`, `:ask_user_requested` (immediately before the catch-all per Phase 5 Non-obvious Decision #5); update `to_step_result/1` to compute `done?` from halt state and to populate `tool_results` and halt-metadata. Leave `:tool_execution_started`, `:tool_execution_completed`, `:step_completed` in the catch-all.
  - `lib/allm/stream_runner.ex` — rename `@phase_7_opts` → `@orchestration_opts`, `strip_phase_7_opts/1` → `strip_orchestration_opts/1`, and the associated log string (Non-obvious Decision #5).
  - `lib/allm.ex` — add `step/3` and `stream_step/3` as one-line delegations to `ALLM.Chat.step/3` and `ALLM.Chat.stream_step/3`, matching spec §4's signatures verbatim.
- **Modified tests:**
  - `test/allm/stream_collector_test.exs` — add tests for the three new fold clauses (`:tool_result_encoded`, `:tool_halt`, `:ask_user_requested`), the `done?` computation from halt state, `to_step_result/1`'s halt-metadata merge, and the first-halt-wins invariant; confirm totality property still holds (16 tags, three now have explicit clauses).
  - `test/allm/providers/fake_scenarios_test.exs` — flip three `@tag :pending` placeholders to active tests: "single tool call with `mode: :auto`" (line 287 area), "parallel tool calls" (line 294 area), "tool handler raises — on_tool_error `:continue`" (line 301 area). The remaining `@tag :pending` ("session round-trip", line 308) stays pending for Phase 8.
- **New tests:**
  - `test/allm/tool_runner_test.exs` — happy path (single and parallel tool calls), unknown tool, handler raises (`:continue` and `:halt`), handler `{:halt, reason, result}`, handler `{:ask_user, question}` minimal halt, tool_timeout, encoder failure, arity-1 and arity-2 handler dispatch, `:max_concurrency` bounded behaviour.
  - `test/allm/chat_step_test.exs` — `Chat.step/3` happy path, no-tool-call response, `mode: :auto` executes tools, `mode: :manual` returns tool calls without execution, `on_tool_error: :halt` sets `StepResult.done?: true` + metadata, `{:halt, reason, result}` handler produces `done?: true` + metadata, invalid thread/request errors bubble, assistant message metadata carries `tool_calls` for serializable round-trip.
  - `test/allm/chat_stream_step_test.exs` — `Chat.stream_step/3` event ordering (adapter events → tool-execution events → `:step_completed`), consumer halt propagation (≤ 500 ms), parallel tool execution events interleave, `:tool_halt` emission, `:ask_user_requested` emission, `:tool_result_encoded` emission with correct encoded content.
  - `test/allm/allm_step_test.exs` — facade `ALLM.step/3` delegates to `Chat.step/3`; doctest using Fake.
  - `test/allm/allm_stream_step_test.exs` — facade `ALLM.stream_step/3` delegates to `Chat.stream_step/3`; doctest using Fake.
  - `test/allm/step_equivalence_test.exs` — StreamData property: for every Phase 4 fixture with tool-call shape, `step/3 == stream_step/3 |> collect_step_result` (by `%StepResult{}` equality, allowing for tool-result order variation when `ordered: false`).
- **CHANGELOG entries:** one line per new public symbol (`ALLM.ToolRunner`, `ALLM.Chat`, `ALLM.step/3`, `ALLM.stream_step/3`) + one line for the `StreamCollector` struct extensions (`:tool_results` and `:halt` fields) + one line for the `StreamRunner` attribute rename (internal) + one line per §31 scenario activated (three scenarios).
- **No changes to:** `ALLM.Engine`, `ALLM.Keys`, `ALLM.Adapter`, `ALLM.StreamAdapter` behaviours, `ALLM.ToolExecutor` behaviour, `ALLM.ToolResultEncoder` behaviour, `ALLM.ToolExecutor.Default`, `ALLM.ToolResultEncoder.JSON`, `ALLM.Providers.Fake`, `ALLM.Providers.Fake.Script`, `ALLM.Test.FakeFixtures`, the `conformance/` sub-project, `ALLM.Application`, `mix.exs`. No new dependency.

### Spec coverage

- **§3 Stream-first execution.** `step/3` is implemented as a reducer over `stream_step/3`, extending the first §3 consequence (`generate ≡ stream_generate |> collect`) to the orchestration layer: `step ≡ stream_step |> collect_step_result`. The reducer is `StreamCollector.to_step_result/1` with the Phase 6 `:tool_results` field populated from the `:tool_result_encoded` fold.
- **§4 Facade.** `step/3` and `stream_step/3` are the next two public functions on `ALLM`, with signatures matching spec §4:
  ```elixir
  @spec step(Engine.t(), Thread.t() | [Message.t()], keyword()) ::
          {:ok, StepResult.t()} | {:error, EngineError.t() | AdapterError.t() | ValidationError.t() | ToolError.t()}
  @spec stream_step(Engine.t(), Thread.t() | [Message.t()], keyword()) ::
          {:ok, Enumerable.t()} | {:error, EngineError.t() | AdapterError.t() | ValidationError.t()}
  ```
  Per `agent-spec/DESIGN.md`, the error-branch type is narrowed from spec §4's `term()` to the four concrete error structs. `ToolError` surfaces on `step/3` because tool execution is synchronous there; on `stream_step/3`, `ToolError`s appear as `{:tool_execution_completed, %{result: {:error, %ToolError{}}}}` events rather than a `{:error, _}` return — pre-flight errors only (validation + adapter) return `{:error, _}`.
- **§5.2 Tool handler returns.** Phase 6 recognises and routes all five legal handler returns:
  - `{:ok, term}` → encoded as tool-result content; StepResult.tool_results gains one `:tool`-role message; step continues.
  - `{:error, reason}` → subjected to engine's `on_tool_error` policy (`:continue` default, `:halt` full).
  - `{:ask_user, question}` / `{:ask_user, question, opts}` → emit `:ask_user_requested`; encode tool result as `"<awaiting user response>"` (spec §12.3); StepResult.done?: true; metadata includes `:halted_reason => :ask_user`, `:pending_question`, `:pending_tool_call_id`, `:ask_user_opts`. (Phase 8 wires Session state transitions.)
  - `{:halt, reason, result}` → emit `:tool_halt`; encode `result` as tool-result content (spec §30); StepResult.done?: true; metadata includes `:halted_reason => reason`. Reserved reasons per §5.2 (`:ask_user`, `:max_turns`, `:halt_when`, `:tool_error`, `:cancelled`, `:completed`) are **not** validated at the handler-return boundary — a handler may return `{:halt, :tool_error, ...}` and Phase 6 accepts it, per spec §5.2's "callers pick reason". Phase 7 may add reserved-reason enforcement if needed.
  - Executor-returned `{:error, %ToolError{}}` (handler raised, exit, etc., per `lib/allm/tool_executor.ex:18-23`) — same policy path as `{:error, _}`.
- **§5.8 StepResult shape.** `done?` mapping per Phase 6:
  - `true` when `response.finish_reason != :tool_calls` (no tools to run — terminal step).
  - `true` when `on_tool_error: :halt` fired OR a handler returned `{:halt, _, _}` OR `{:ask_user, _}` / `{:ask_user, _, _}`.
  - `true` when `mode: :auto` AND the tool-execution path completed (phase 6 single-turn; Phase 7 extends via `chat/3` to keep `done?: false` for continuation).
  - **Wait — the spec and phasing disagree here.** The phasing doc says: "`done?` is `true` when ... or when `{:halt, _, _}` was returned by a handler; it is `false` when `finish_reason: :tool_calls` and tools executed successfully." Phase 6 follows the phasing: `done?: false` after successful tool execution signals "more adapter work is expected" so Phase 7's `chat/3` loop can iterate. In Phase 6's isolated `step/3` call, the caller with `done?: false` is expected to call `step/3` again with the updated thread (or move to `chat/3` in Phase 7).
  - `false` in the `mode: :manual` path when the response has tool calls — the caller is expected to submit tool results and resume (full manual flow in Phase 7).

  Phase 6 also puts `:halted_reason` in `StepResult.metadata` when a halt fired: `:tool_error`, `:ask_user`, or the user's custom atom from `{:halt, reason, _}`. When `mode: :manual` returns unexecuted tool calls, Phase 6 puts `metadata.mode: :manual` (NOT a halt — see the "Halt-reason atoms" section below). These metadata keys are Phase-6-owned (not spec'd explicitly); Phase 7 re-consumes them in `chat/3`'s orchestration loop.
- **§7.3 `ALLM.ToolExecutor`.** Phase 6 consumes the behaviour. No changes to the behaviour itself. `ALLM.ToolExecutor.Default` (shipped Phase 3) is the default when `engine.tool_executor == nil`. The executor is called once per tool call with `(tool, parsed_args, opts)` where `opts` carries the spec §5.2 handler-opts keyword list (`:context`, `:session_id`, `:request_id`, `:tool_call`, `:engine`). `:session_id` is `nil` in Phase 6 (Session integration is Phase 8). `:request_id` is the adapter's emitted `request_id` if present, else `nil`.
- **§7.4 `ALLM.ToolResultEncoder`.** Phase 6 consumes the behaviour. `ALLM.ToolResultEncoder.JSON` (shipped Phase 3) is the default when `engine.tool_result_encoder == nil`. The encoder is called with the handler's returned term (or the encoded error payload when `on_tool_error` converts an error to a tool-result). Encoder failures (`Protocol.UndefinedError`, `Jason.EncodeError`) are caught by `ALLM.ToolRunner` and wrapped as `%ToolError{reason: :encoding_failed}` — see Non-obvious Decision #3.
- **§8 Event protocol.** No new variants. The five Phase-6-owned orchestration tags were declared in Phase 1 per spec §8 and currently fall through to `StreamCollector`'s catch-all (Phase 5 Non-obvious Decision #12). Phase 6 emits these tags from `ALLM.ToolRunner.stream_tool_calls/3` and `ALLM.Chat.stream_step/3`:
  - `:tool_execution_started, %{id, name, arguments}` — emitted before each handler invocation (per spec §8 payload shape, verified at `lib/allm/event.ex:39`).
  - `:tool_execution_completed, %{id, name, result}` — emitted after each handler returns or raises; `result` is the raw handler return (`{:ok, _}`, `{:error, _}`, `{:ask_user, _}`, `{:halt, _, _}`, or `{:error, %ToolError{}}`).
  - `:tool_result_encoded, %{id, content}` — emitted after the tool-result encoder produces the content string.
  - `:ask_user_requested, %{tool_call_id, tool_name, question, opts}` — emitted when the handler returns `:ask_user` (per spec §12.3 wire shape at `lib/allm/event.ex:42-48`).
  - `:tool_halt, %{tool_call_id, reason, result}` — emitted when the handler returns `{:halt, reason, result}`.
  - `:step_completed, %{response, thread}` — emitted once per `stream_step/3` call after all tool executions complete. `thread` carries the updated thread including all tool-role messages.
- **§10.3, §10.4 step/stream_step.** Both facade functions are implemented as `with`-chains through `ALLM.Chat`. Spec §10's option precedence is honoured by inheriting Phase 5's `ALLM.Engine.resolve_*` calls.
- **§12 Auto vs manual orchestration.** Phase 6 implements `mode: :auto` (full — executes tools automatically) and `mode: :manual` (partial — step/3 returns tool calls without executing, `StepResult.done?: false` with `metadata.mode: :manual`). Session-based full manual flow (`submit_tool_result/3`, `:awaiting_tools` state) is Phase 8. The atom `:manual_tool_calls` on `ChatResult.halted_reason` is Phase 7's concern per `PROJECT_PHASING.md` — Phase 6 never emits it.
- **§12.3 Ask-user suspension (partial).** Phase 6 implements the single-turn signalling: `:ask_user_requested` event fires, tool result encoded as `"<awaiting user response>"`, StepResult.done?: true with metadata. The question is **not** automatically appended to the thread as an `:assistant` message in Phase 6 — the assistant message with `ask_user: true` metadata is appended by Phase 7's `chat/3` orchestrator (at the turn boundary, where appending makes sense) and Phase 8's `Session.reply/4` (which knows how to resume). In Phase 6's `step/3` isolation, the caller sees `StepResult.metadata.pending_question` and decides. This split keeps Phase 6 single-turn semantics clean: step does one adapter call and one round of tools; any thread-mutation for suspension lives at the multi-turn layer.
- **§17 Internal modules.** `ALLM.ToolRunner.run_tool_calls/3` and `ALLM.Chat.step/3`, `ALLM.Chat.stream_step/3` land with the spec §17 signatures. `ALLM.ToolRunner.stream_tool_calls/3` is a Phase 6 extension (see Non-obvious Decision #2 — `stream_tool_calls` is not in spec §17's stated signatures but is required for `stream_step/3`'s composition).
- **§19 Streaming options.** Phase 5's consumed set (`emit_text_deltas`, `emit_tool_deltas`, `include_raw_chunks`, `on_event`) stays unchanged and flows through `stream_step/3` → `stream_generate/3` verbatim. Phase 6 consumes two more opts at the `Chat.step/stream_step` layer:
  - `:mode` — `:auto | :manual`. Default `:auto`. Consumed by `Chat.step/3` and `Chat.stream_step/3`; the value is stripped from the opts keyword list before `stream_generate/3` is called (preserving Phase 5's `@phase_7_opts` strip — the key continues to flow into the adapter-deny-list per Phase 5 Non-obvious Decision #11). Note: the Phase 5 `@phase_7_opts` module attribute is renamed to `@orchestration_opts` in Phase 6 (see Non-obvious Decision #5) to reflect that the list is now Phase-6-and-7-shared orchestration vocabulary.
  - `:tool_timeout` — `timeout()`. Default `30_000` per spec §30. Consumed by `ALLM.ToolRunner` as the `Task.async_stream/5` `:timeout` option. Passed to engine opt resolution via `resolve_params/2` (the key is in Phase 5's engine-field deny-list, so it doesn't pollute adapter opts).
  - `:on_tool_error` — `:continue | :halt`. Default `:continue` per spec §30. Function form (`:function`) deferred to Phase 7. Consumed by `ALLM.ToolRunner`; not forwarded to the adapter.
  - `:tool_executor` — module. Override for `engine.tool_executor`. Resolved at call time, not stored on engine.
  - `:tool_result_encoder` — module. Override for `engine.tool_result_encoder`. Resolved at call time.
- **§20 Error reasons.** Phase 6 introduces NO new error-reason atoms; every atom is already committed in the closed enum of a prior phase (verified against `lib/allm/error/engine_error.ex:30-38` and `lib/allm/error/tool_error.ex:34-41` on 2026-04-24):
  - `%EngineError{reason: :unknown_tool}` — tool name in a `%ToolCall{}` does not match any `%Tool{}` in the resolved tool list. Already in `@legal_reasons` at `lib/allm/error/engine_error.ex:30-38`.
  - `%ToolError{reason: :handler_raised}` — handler raised an exception. Already in `@legal_reasons` at `lib/allm/error/tool_error.ex:34-41`.
  - `%ToolError{reason: :handler_exit}` — handler exited (caught via `try/catch :exit`). Already in `@legal_reasons`.
  - `%ToolError{reason: :timeout}` — tool handler exceeded `tool_timeout`. Already in `@legal_reasons`.
  - `%ToolError{reason: :invalid_return}` — handler returned a value not matching the five legal shapes. Already in `@legal_reasons`.
  - `%ToolError{reason: :not_found}` — tool name not found (mirrors `:unknown_tool` above for executor-side errors; see Non-obvious Decision #4 for the naming choice).
  - `%ToolError{reason: :encoding_failed}` — `ToolResultEncoder.encode/1` raised. Already in `@legal_reasons`.
- **§30 Tool error policy (partial).** Phase 6 implements `:continue` and `:halt` atoms. Function form `(ToolCall.t(), term() -> {:continue, term()} | :halt)` deferred to Phase 7. Passing a function to Phase 6's step/3 raises `ArgumentError` with message pointing to Phase 7.
- **§31 Property-style coverage.** Three of the nine §31 scenarios become active in Phase 6 (previously `@tag :pending` in `test/allm/providers/fake_scenarios_test.exs`):
  - **single tool call with `mode: :auto`** — Fake script ends with `{:finish, :tool_calls}`; `step/3` with a registered handler for the tool executes it, appends a tool-role message, returns `%StepResult{done?: false, tool_results: [msg]}`.
  - **parallel tool calls in one assistant turn** — Fake script contains two `{:tool_call, ...}` entries plus `{:finish, :tool_calls}`; both handlers execute; both tool-result messages in the thread (order-independent).
  - **tool handler raises — on_tool_error policy fires** — partial coverage via `:continue` (`{:ok, %StepResult{done?: false, tool_results: [error_msg]}}`) AND `:halt` (`{:ok, %StepResult{done?: true, metadata: %{halted_reason: :tool_error}}}`). Full function-form `on_tool_error` remains `@tag :pending` for Phase 7.

  The four remaining scenarios (`max_turns`, `halt_when`, `:manual` mode full session flow, session round-trip) stay `@tag :pending` and are phased into 7–8.

### Layer demonstration

Phase 6 is Layer C only. Three consumer-facing usages at Layer C alone — no Layer D session needed:

```elixir
# Layer C: non-streaming single-turn step with auto tool execution
engine =
  ALLM.Engine.new(
    adapter: ALLM.Providers.Fake,
    adapter_opts: [
      script: [
        {:tool_call, id: "call_0", name: "get_weather", arguments: %{city: "Boston"}},
        {:finish, :tool_calls}
      ]
    ],
    tools: [
      ALLM.tool(
        name: "get_weather",
        description: "fake",
        schema: %{type: "object", properties: %{city: %{type: "string"}}},
        handler: fn %{city: city} -> {:ok, %{forecast: "sunny", city: city}} end
      )
    ]
  )

thread = ALLM.Thread.from_messages([ALLM.user("Weather in Boston?")])
{:ok, step_result} = ALLM.step(engine, thread)
# step_result.tool_results == [%Message{role: :tool, tool_call_id: "call_0", content: ~s({"city":"Boston","forecast":"sunny"})}]
# step_result.done? == false  (tool_calls finish — more adapter work expected)
```

```elixir
# Layer C: streaming single-turn step — events stream in real time
{:ok, stream} = ALLM.stream_step(engine, thread)

Enum.each(stream, fn
  {:tool_call_completed, %{name: n}}       -> IO.puts("-> #{n} requested")
  {:tool_execution_started, %{name: n}}    -> IO.puts("-> #{n} executing")
  {:tool_execution_completed, %{name: n}}  -> IO.puts("-> #{n} done")
  {:step_completed, %{}}                   -> IO.puts("== step done ==")
  _ -> :ok
end)
```

```elixir
# Layer C: manual mode — no execution, tool calls surfaced for caller to handle
{:ok, step_result} = ALLM.step(engine, thread, mode: :manual)
# step_result.response.tool_calls == [%ToolCall{id: "call_0", name: "get_weather", arguments: %{city: "Boston"}}]
# step_result.tool_results == []
# step_result.metadata.mode == :manual
```

No Layer D function is exercised; `ALLM.Session.submit_tool_result/3` arrives in Phase 8. No Phase 7 `chat/3` multi-turn loop is involved; `step/3` is a single turn.

### Prerequisites

- **Phase 1 complete.** `ALLM.Error.EngineError` (including `:unknown_tool` in the committed enum at `lib/allm/error/engine_error.ex:30-38`), `ALLM.Error.ToolError` (all seven reason atoms at `lib/allm/error/tool_error.ex:34-41`), `ALLM.Error.AdapterError`, `ALLM.Error.ValidationError`.
- **Phase 2 complete.** `ALLM.Engine.new/1`, `resolve_tools/2` (dedup-by-name merge at `lib/allm/engine.ex:333-342`), `resolve_params/2`, `merge_opts/2`.
- **Phase 3 complete.** `ALLM.ToolExecutor` behaviour, `ALLM.ToolExecutor.Default` (arity-1 / arity-2 handler dispatch at `lib/allm/tool_executor/default.ex:46-88`), `ALLM.ToolResultEncoder` behaviour, `ALLM.ToolResultEncoder.JSON` (encoding rules at `lib/allm/tool_result_encoder/json.ex:39-63`).
- **Phase 4 complete.** `ALLM.Providers.Fake` emits `:tool_call_*` events for `{:tool_call, ...}` / `{:tool_call_delta, ...}` / `{:finish, :tool_calls}` script entries; `ALLM.Test.FakeFixtures.single_tool_call/2`, `.parallel_tool_calls/1`, `.tool_call_with_streamed_args/2` ship.
- **Phase 5 complete.** `ALLM.stream_generate/3`, `ALLM.generate/3`, `ALLM.StreamCollector` (including per-tag clauses for adapter events), `ALLM.StreamRunner` (including `@phase_7_opts` strip behaviour), `ALLM.Runner`.
- **No dependency on Phases 7–8.** Multi-turn `chat/3`, `stream/3`, `halt_when`, full `on_tool_error` function form, Session state machine — all out of scope for Phase 6.

### Out of scope

- **`ALLM.chat/3`, `ALLM.stream/3`, `ALLM.Chat.run/3`, `ALLM.Chat.stream/3`.** Phase 7.
- **`ALLM.Session` integration.** Phase 8. `:session_id` is `nil` in Phase 6's handler opts; Session state transitions (`:awaiting_tools`, `:awaiting_user`) are not wired.
- **`on_tool_error` function form.** Phase 7 — `(ToolCall.t(), term() -> {:continue, term()} | :halt)` per spec §30.
- **`halt_when` callback.** Phase 7 — evaluated after every step before the next adapter call. Single-turn `step/3` has no "next adapter call" to gate, so `halt_when` is a no-op in Phase 6's scope; a `halt_when:` opt passed to `step/3` is stripped at the `Chat.step/3` layer with a `Logger.debug/1` log and NOT forwarded to the adapter. (It's in `@orchestration_opts`.)
- **`max_turns` cap.** Phase 7 — single-turn `step/3` is always one turn.
- **Ask-user full thread mutation.** Phase 6 emits `:ask_user_requested` and populates `StepResult.metadata`, but does NOT append an `:assistant`-role message with `metadata: %{ask_user: true}` to the thread. That thread mutation is the multi-turn loop's concern (Phase 7's `chat/3` and Phase 8's `Session.reply/4`), which knows how to wire the question into a resumable turn boundary. See Non-obvious Decision #6.
- **Retries.** Phase 9 (spec §20, §6.1). Phase 6 inherits Phase 5's pass-through.
- **Telemetry.** Phase 9 (spec §29). Phase 6 does not emit `[:allm, :step, :start | :stop]` or `[:allm, :tool, :start | :stop | :exception]` events. The `on_event` option (spec §19) passes through from Phase 5 and observes every Phase 6 event for telemetry-like use cases.
- **`request_id` propagation end-to-end.** Phase 9. Phase 6 forwards `Response.request_id` into `ALLM.ToolExecutor`'s `opts[:request_id]` when present, but does not mint one at the top of `step/3`.
- **Tool-execution cancellation on timeout.** A tool that times out has its `Task` killed by `Task.async_stream/5`'s `:on_timeout` default (`:exit`). Phase 6 emits `{:tool_execution_completed, %{result: {:error, %ToolError{reason: :timeout}}}}` for the timed-out tool but does NOT emit a separate `:tool_execution_cancelled` variant (see Non-obvious Decision #7 for the decision against adding a new event variant).
- **Capability pre-flight (`llm_db`).** Phase 9 (spec §6.3). Phase 6 does not add a new `llm_db` code path.
- **Backpressure beyond `Stream` primitives.** Same as Phase 5: the consumer's reduce rate is the only signal. `Task.async_stream/5` provides its own fairness guarantees; Phase 6 does not introduce a demand-based producer.

### Non-obvious decisions

1. **`stream_step/3` composes via `Stream.concat/1`, not an outer `Stream.resource/3`.** Phase 5 Non-obvious Decision #6 established the rule: do not wrap an already-resource-safe stream in another `Stream.resource/3`. Phase 6 faces a new shape: after the adapter stream closes (finish_reason `:tool_calls`), the orchestrator must emit *new* events (tool-execution, step-completion). The naive approach — `Stream.resource/3` that consumes the adapter stream, collects tool calls, then produces tool-execution events — adds a second cleanup hook atop Fake's existing one. Rejected because consumer halt during the adapter-stream phase would fire both `after_fun`s non-deterministically.

   Chosen: compose three enumerables via `Stream.concat/1`:

   ```elixir
   def stream_step_compose(adapter_stream, tool_calls_fn, step_completed_fn) do
     Stream.concat([
       Stream.transform(adapter_stream, %StreamCollector{}, &fold_for_step/2),
       # After adapter closes, Stream.transform returns [] and we move on.
       tool_execution_stream(tool_calls_fn),
       step_completed_stream(step_completed_fn)
     ])
   end
   ```

   `Stream.concat/1` pulls each source lazily; halt propagates to whichever source is currently being pulled. Adapter cleanup is owned by Fake's `Stream.resource/3`; tool-execution cleanup is owned by `Task.async_stream/5`'s internal supervision. `step_completed_stream` is a one-element list that needs no cleanup. Verified against Elixir 1.17 stdlib docs on 2026-04-24: `Stream.concat/1` lazily pulls each enumerable in order and propagates `{:halt, _}` to the source being pulled; `Task.async_stream/5` is enumerable-compatible and cancels remaining tasks on reducer halt.

   **Implementation:** one outer `Stream.resource/3` at the `Chat.stream_step` layer that drives a three-phase state machine. The outer resource does NOT wrap the adapter stream (Phase 5 Non-obvious Decision #6's prohibition); instead it **reduces** the adapter stream lazily in Phase A and delegates cleanup to the adapter via `Enumerable.reduce/3`'s halt protocol.

   Three phases, tagged in the state tuple:

   - **Phase A (`:phase_a`)**: the state holds `{adapter_accumulator, collector}`. Each `next_fun/1` invocation pulls exactly one event from `adapter_stream`'s reducer continuation, emits it downstream, and folds it into `collector`. When the continuation returns `{:done, _}` or `{:halted, _}`, the phase transitions to Phase B. **Phase A terminates on adapter-stream exhaustion, never on event content** (per Finding F4): `finish_reason: :tool_calls` in an intermediate event does not trigger a transition; trailing `:raw_chunk` events after `:message_completed` are still consumed.
   - **Phase B (`:phase_b`)**: the state holds `{tool_event_accumulator, collector, pulled_msgs}`. `tool_event_accumulator` is the lazy reducer continuation of an inner `Task.async_stream/5` enumerable whose tasks each produce a short list of events (`:tool_execution_started`, `:tool_execution_completed`, `:tool_result_encoded` — or `:ask_user_requested` / `:tool_halt` in place of `:tool_result_encoded`) for one tool call. `next_fun/1` pulls one batch of events, emits them, and accumulates any produced `Message.t()` in `pulled_msgs`. When the `Task.async_stream/5` reducer returns `{:done, _}`, transitions to Phase C. **Sibling drain on handler halt** (Finding F5): when a handler returns `{:halt, _, _}` or `{:ask_user, _}` or triggers `on_tool_error: :halt`, Phase B continues to pull until `Task.async_stream/5` completes naturally — it does NOT short-circuit the reducer. This ensures completed siblings' results are included in `tool_results` and emitted as events (not-yet-started tasks are never spawned because `Task.async_stream/5`'s work scheduler is bounded by `max_concurrency`; in-flight tasks are pulled to completion because our reducer continues pulling). The `halt_metadata` is stashed on the state and used in Phase C.
   - **Phase C (`:phase_c`)**: emits exactly one `:step_completed` event whose payload carries the final `%Response{}` (from the collector via `to_response/1`) and the final `%Thread{}` (input thread + augmented assistant message + all pulled tool-role messages, in insertion order for assistant/user/system messages and `tool_call_id`-sorted for tool messages per Non-obvious Decision #9). Transitions to `{:halt, :done}`.

   **Driving a sub-stream one event at a time.** Phase A and Phase B each
   hold a *reducer continuation* in their state tuple, not a whole
   enumerable. The canonical Elixir idiom for pulling a single element from
   an enumerable and resuming later is to use `Enumerable.reduce/3` with a
   reducer that returns `{:suspend, value}` — this shifts the enumerable
   into "step" mode and returns `{:suspended, value, next_cont}` on each
   pull. Seeding:

   ```elixir
   continuation = &Enumerable.reduce(adapter_stream, &1, fn event, _ -> {:suspend, event} end)
   # Wrap the seed in the {:suspended, _, cont} shape we match on in next_fun:
   adapter_cont = {:suspended, nil, continuation}
   ```

   Per-event pull inside `next_fun`:

   ```elixir
   defp pull_next_phase_a(%{adapter_cont: {:suspended, _last, cont}} = data) do
     case cont.({:cont, nil}) do
       {:suspended, event, next_cont} ->
         # One event pulled; fold into collector and emit it downstream.
         new_collector = StreamCollector.apply_event(data.collector, event)
         new_data = %{data | collector: new_collector, adapter_cont: {:suspended, event, next_cont}}
         {[event], {:phase_a, new_data}}

       {:done, _acc} ->
         # Adapter stream exhausted — transition to Phase B.
         transition_a_to_b(data)

       {:halted, _acc} ->
         transition_a_to_b(data)
     end
   end
   ```

   The `{:suspend, event}` reducer-return form is the low-level `Enumerable`
   protocol for step-wise iteration; it is load-bearing here because the
   outer `Stream.resource/3` must emit exactly one event per `next_fun`
   invocation to preserve laziness. Without it, pulling would drain the
   whole sub-stream eagerly.

   **Cleanup ownership.** The outer `after_fun` pattern-matches the state
   and invokes the stashed continuation (NOT `Enumerable.reduce/3` on a
   continuation — `Enumerable.reduce/3` expects an enumerable as its first
   argument, not a continuation closure). The correct shape:

   ```elixir
   defp stream_after({:phase_a, %{adapter_cont: {:suspended, _last, cont}}}) do
     # Trigger the adapter stream's own after_fun exactly once by sending
     # {:halt, _} through its continuation. The inner `fn _, _ -> {:halt, :ok} end`
     # reducer never runs because the outer halt fires before the next
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
   ```

   Both `Enumerable.reduce/3` shapes matter here. Seeding (first code
   block) wraps the enumerable in a closure that, when invoked with
   `{:cont, acc}`, begins reduction and suspends on the first element.
   Cleanup (this block) invokes the **stashed** continuation closure with
   `{:halt, _}`, which propagates through to the source enumerable's
   `Stream.resource/3` `after_fun`. The two call sites are visually
   similar but semantically different: the first establishes the
   continuation; the second drives it.

   This is ONE `Stream.resource/3`, not two. Phase 5's Non-obvious Decision #6 forbade *wrapping* the adapter stream in a second resource whose own `after_fun` would double-register. This pattern *drives* the adapter stream via its reducer continuation; the adapter's `after_fun` fires exactly once (when we halt it in Phase A cleanup or when it exhausts naturally during Phase A transition to B). Verified in IEx on OTP 27 on 2026-04-24: `Enumerable.reduce/3` is the stdlib protocol every `Stream.resource/3`-backed enumerable honors; halting it triggers the resource's `after_fun` exactly once (via the `{:halted, _}` continuation).

   **Rejected alternative: `Stream.concat/1` of three pre-built enumerables.** Requires Phase B's enumerable to be constructed BEFORE Phase A runs — but Phase B's tool-call list depends on Phase A's final collector state, which is only known after Phase A completes. Workarounds (process dict stash, Agent-backed side channel) are more complex than the state machine and don't resolve the root data-dependency problem.

   `Docs target: @moduledoc ALLM.Chat` ("Stream composition" section — the three phases, Phase A exhaustion rule, Phase B sibling-drain rule, and cleanup pattern-match).

2. **`ALLM.ToolRunner` has `run_tool_calls/3` AND `stream_tool_calls/3`, with `stream_tool_calls/3` as a Phase 6 extension to spec §17.** Spec §17 lists only `run_tool_calls/3` on `ALLM.ToolRunner`. Phase 6's `stream_step/3` needs a streaming variant to emit `:tool_execution_*` and `:tool_result_encoded` events in real time. Two rejected alternatives:
   - **Implement `stream_tool_calls/3` inside `ALLM.Chat.stream_step/3` directly.** Couples stream-composition logic (Chat's concern) with parallel-execution logic (ToolRunner's concern). Rejected — violates single-responsibility and makes the `stream_equivalence` property harder to test because the `step/3` path would go through `ToolRunner.run_tool_calls/3` but `stream_step/3` would reimplement.
   - **Make `stream_tool_calls/3` part of `Chat`.** Same coupling issue in a different module.

   Chosen: add `stream_tool_calls/3` to `ALLM.ToolRunner` as a Phase 6 extension to spec §17. Signature: `@spec stream_tool_calls([ToolCall.t()], [Tool.t()], keyword()) :: Enumerable.t()`. Returns an enumerable of `ALLM.Event` values covering `:tool_execution_started`, `:tool_execution_completed`, `:tool_result_encoded`, plus `:ask_user_requested` / `:tool_halt` when a handler returns those shapes. Both functions share the `execute_one_tool/3` helper for dispatch + encoding + error-policy logic; `run_tool_calls/3` accumulates messages, `stream_tool_calls/3` accumulates events.

   The addition is annotated in `ToolRunner`'s `@moduledoc` as "Phase 6 extension to spec §17" so a future reader understands why it's present without diffing the spec.

   `Docs target: @moduledoc ALLM.ToolRunner` (one-paragraph "Phase 6 addition" section) + `@doc ALLM.ToolRunner.stream_tool_calls/3`.

3. **Tool-result encoding failures are wrapped as `%ToolError{reason: :encoding_failed}` and routed through `on_tool_error`.** `ALLM.ToolResultEncoder.JSON.encode/1` raises `Protocol.UndefinedError` on non-JSON-encodable terms (`lib/allm/tool_result_encoder/json.ex:9-22` documents this). If a tool handler returns a Port or PID (not JSON-encodable), the encoder raises, and the step would crash. Phase 6 wraps the encoder call in `try/rescue` inside `ALLM.ToolRunner.execute_one_tool/3`, catches `Protocol.UndefinedError` and `Jason.EncodeError`, and constructs `%ToolError{reason: :encoding_failed, tool_name: name, tool_call_id: id, cause: exception}`.

   The wrapped error is then routed through the normal `on_tool_error` policy (since it's a `{:error, _}`-shaped outcome from ToolRunner's perspective):
   - `:continue` (default) — the error is encoded and becomes the tool-result content; step continues.
   - `:halt` — step halts with `StepResult.done?: true`, metadata `halted_reason: :tool_error`.

   This unifies handler-raised errors and encoder-raised errors under one error-policy branch. Rejected alternative: let encoder raises crash the step. Surfaces cryptic `Protocol.UndefinedError` to callers with no recovery path; violates the spec §20 contract that public functions return `{:ok, _}` or `{:error, %ErrorStruct{}}`.

   **Encoding-of-an-encoding-failure uses `Exception.message/1`**, not `inspect/1`. Verified in IEx on OTP 27 on 2026-04-24: `Exception.message(%Protocol.UndefinedError{protocol: Jason.Encoder, value: make_ref()})` returns a human-readable binary (e.g., `"protocol Jason.Encoder not implemented for #Reference<...> of type Reference"`). `Exception.message/1` is defined for every struct carrying `@derive` or a custom `message/1` clause; for `Protocol.UndefinedError` and `Jason.EncodeError`, `Exception.message/1` is total. The final tool-result content becomes a JSON object `%{"error" => Exception.message(cause)}` encoded via `Jason.encode!/1` (which never fails on a plain string-valued map).

   `Docs target: @doc ALLM.ToolRunner.run_tool_calls/3` (error policy table).

4. **Tool-not-found is `%EngineError{reason: :unknown_tool}`; `metadata.tool_name` surfaces the name to callers.** `ToolError` has `:not_found` in its closed enum (`lib/allm/error/tool_error.ex:34-41`) and `EngineError` has `:unknown_tool` (`lib/allm/error/engine_error.ex:30-38`). Both are available.

   Decision: **`%EngineError{reason: :unknown_tool, metadata: %{tool_name: name}}`** for the case where the adapter returns a tool call with a name that doesn't match any tool in the engine's resolved tool list. Rationale: this is an engine-configuration error (the caller didn't register the tool), not an executor-side error. The `tool_name` goes in the typed `metadata` field (per Finding F12) so callers can programmatically extract it without string-parsing `:message`. `EngineError.cause` stays `nil` here — `cause` is reserved for wrapped underlying exceptions per the Phase 1 error-struct conventions.

   `%ToolError{reason: :not_found}` is reserved for the case where the executor itself cannot locate the tool — a pass-through signal from a custom executor that does its own lookup. In Phase 6, the default executor doesn't do lookup (the tool is passed in by ToolRunner), so `:not_found` only surfaces from custom executors. Phase 6's ToolRunner never emits `:not_found`; conformance test harness in Phase 3 tests `:not_found` against a custom executor.

   **Pre-flight vs partial execution (Finding F12).** Phase 6 pre-flights: if ANY tool call names an unknown tool, the whole batch returns `{:error, %EngineError{...}}` synchronously, no tools execute. Rejected alternative: allow partial execution with unknown tools surfaced as per-tool `%ToolError{reason: :not_found}` via `on_tool_error`. Partial execution has composability appeal but fragments the error signal (the caller gets a StepResult with ambiguous-success status when one tool didn't run); the pre-flight path gives the caller a single, clear, programmable error for a single misconfiguration. This is a Phase 6 choice; Phase 7's `chat/3` may revisit if the multi-turn loop wants to degrade gracefully.

   `Docs target: @doc ALLM.ToolRunner.run_tool_calls/3` (error reason table).

5. **`@phase_7_opts` module attribute in `ALLM.StreamRunner` is renamed to `@orchestration_opts` in Phase 6, along with the paired function name and log string.** Phase 5 named the adapter-deny-list `@phase_7_opts` because those opts (`:mode`, `:max_turns`, `:halt_when`) were all planned for Phase 7 consumption. Phase 6 now consumes `:mode` at the `Chat.step/stream_step` layer — the opt is no longer exclusively Phase 7-owned. Leaving the attribute name as-is would create a lie in the code.

   Decision: rename in Phase 6 sub-phase 6.1. The list's contents stay identical (`[:mode, :max_turns, :halt_when]`). Phase 6 consumes `:mode` at a *higher* layer (Chat) than StreamRunner, so by the time opts reach StreamRunner, `:mode` is already stripped by Chat. StreamRunner's deny-list is the safety-net that catches any unstripped orchestration key before adapter dispatch.

   **Rename scope** (all in `lib/allm/stream_runner.ex`, verified against the committed module on 2026-04-24):
   - Module attribute: `@phase_7_opts` (line 41) → `@orchestration_opts`.
   - Private function: `strip_phase_7_opts/1` (line 119) → `strip_orchestration_opts/1`.
   - `Logger.debug/1` message: `"[ALLM.StreamRunner] stripped Phase 7 opt: ..."` (line 133) → `"[ALLM.StreamRunner] stripped orchestration opt: ..."`.
   - `@moduledoc` section heading `## Phase 7 opts are stripped` (line 9) → `## Orchestration opts are stripped`, and the paragraph's "Phase 7 orchestration opts" → "orchestration opts (Phase 6 and Phase 7 consumers)".

   No change to test surface — existing tests at `test/allm/stream_runner_test.exs` assert behaviour (opts are stripped), not attribute names or log strings; check during implementation to confirm no log-content assertions were added inadvertently.

   CHANGELOG entry: one line noting the rename (internal module attribute; no public API impact).

   `Docs target: internal — @moduledoc ALLM.StreamRunner's "orchestration opts are stripped" paragraph uses the new name.`

6. **Phase 6 emits `:ask_user_requested` but does NOT append an `:assistant` message with `metadata: %{ask_user: true}` to the thread.** Spec §12.3 step 2 says "The question is appended to the thread as an `:assistant` message with `metadata: %{ask_user: true, tool_call_id: id}`". Phase 6 is single-turn; appending the question as an assistant message only makes semantic sense at the turn boundary where the user will reply, and Phase 6's step/3 has no next-turn concept.

   Decision: Phase 6's `Chat.step/3` and `Chat.stream_step/3` emit `:ask_user_requested`, encode the tool result as `"<awaiting user response>"` (per spec §12.3 step 1), and populate `StepResult.metadata.pending_question` + `StepResult.metadata.pending_tool_call_id` + `StepResult.metadata.ask_user_opts`. The thread returned in `StepResult` contains the assistant message (with tool_calls) and the tool-role messages (with the `"<awaiting user response>"` content), but NO trailing `:assistant` message with the question. Phase 7's `chat/3` wraps `step/3` and, when it sees `StepResult.metadata.halted_reason == :ask_user`, appends the assistant question message to the thread before returning the `%ChatResult{}`. Phase 8's `Session.reply/4` consumes the `pending_question` metadata to resume.

   Rejected alternative: Phase 6 appends the assistant question message inside `step/3`. Means the thread returned by `step/3` contains duplicate content if Phase 7 then appends again — or Phase 7 has to detect whether the step already did it. The single-responsibility split (step: executes tools; chat: manages the multi-turn loop including suspension mutations) is cleaner.

   Phase 6 tests assert: the `StepResult.thread` after an ask-user-handler does NOT contain a trailing `:assistant`-role message with `metadata.ask_user == true`. Phase 7 tests will assert the opposite for `chat/3`.

   `Docs target: @doc ALLM.Chat.step/3` ("Ask-user semantics" paragraph); `@doc ALLM.step/3` references it.

7. **Tool timeouts emit `{:tool_execution_completed, %{result: {:error, %ToolError{reason: :timeout}}}}`, NOT a new `:tool_execution_cancelled` event variant.** The phasing doc flags this as Phase 6 decision (b): "Whether `ALLM.Internal.ToolRunner` emits a `:tool_execution_cancelled` event if `tool_timeout` elapses (not in the current §8 union — this is a spec amendment flag)".

   Decision: **do not add `:tool_execution_cancelled`.** Rationale: adding a new variant to the closed `ALLM.Event` union is a breaking change for every reducer per `agent-spec/DESIGN.md`. The timeout signal can ride on the existing `:tool_execution_completed` variant's `:result` payload (already `term()` per `lib/allm/event.ex:40`). A consumer that wants to distinguish timeout from other errors pattern-matches `{:tool_execution_completed, %{result: {:error, %ToolError{reason: :timeout}}}}`. Three rejected alternatives:
   - **Add `:tool_execution_cancelled` variant.** Breaks every Phase 5 reducer that pattern-matches the 16 tags; requires a Phase 5 `StreamCollector` amendment.
   - **Add a `:cancelled` reason to `ToolError.@legal_reasons`.** The existing `:timeout` reason already covers this case; `:cancelled` would only matter if Phase 6 also supported explicit cancellation (it doesn't — see "Out of scope").
   - **Emit a `{:raw_chunk, {:tool_cancelled, id}}`.** Couples the collector to a specific raw-chunk shape; violates `:raw_chunk`'s opaque-payload contract (§8).

   `Docs target: @doc ALLM.ToolRunner.stream_tool_calls/3` ("Timeout semantics" paragraph).

8. **`Task.async_stream/5` default `max_concurrency` is `max(1, min(length(tool_calls), System.schedulers_online() * 2))`, with an empty-list short-circuit.** Phasing doc decision (a): "default to `System.schedulers_online()` vs `length(tool_calls)`". Both defaults have failure modes:
   - `System.schedulers_online()` alone: a 10-tool-call turn on an 8-scheduler machine runs 8 concurrently, leaving 2 queued. For I/O-bound tools (HTTP fetches, file reads) this under-utilises the system.
   - `length(tool_calls)` alone: a pathological 200-tool-call turn spawns 200 tasks concurrently. Memory-bounded; scheduler-contention bounded but non-trivial.

   Decision: `max(1, min(length(tool_calls), System.schedulers_online() * 2))`. The `* 2` factor accommodates I/O-bound tools without unbounded concurrency. The `min` prevents wasted scheduler slots when there are fewer tools than schedulers. The outer `max(1, _)` guards against a single-scheduler edge case (`System.schedulers_online() == 1` → `2` is still fine, but belt-and-suspenders against any future cap).

   **Empty tool_calls guard (Finding F10).** `Task.async_stream/5` raises `ArgumentError` on `max_concurrency: 0` (verified in IEx on OTP 27 on 2026-04-24: `Task.async_stream([], fn _ -> :ok end, max_concurrency: 0) |> Enum.to_list()` raises). Phase 6's `ALLM.ToolRunner.run_tool_calls/3` and `.stream_tool_calls/3` short-circuit before computing `max_concurrency` when `tool_calls == []`: `run_tool_calls([], _, _) -> {:ok, []}` and `stream_tool_calls([], _, _) -> Stream.concat([])`. A test asserts the short-circuit path (no `Task.async_stream/5` invocation, no `ArgumentError`).

   Callers can override via `max_concurrency:` opt at call time. Rejected: use `Application.get_env(:allm, :default_max_concurrency)` — pushes the decision to app config without a sensible default. Rejected: document "tune via opts" with no default — every caller has to think about it.

   `Docs target: @doc ALLM.ToolRunner.run_tool_calls/3` (opts table with `:max_concurrency` row).

9. **Step-equivalence property tests tolerate `tool_results` order variation when tool executions run in parallel with `ordered: false`.** Phase 5's `stream_equivalence` property (`test/allm/stream_equivalence_test.exs`) asserts `generate/3 == stream_generate/3 |> collect` by struct equality. For Phase 6, parallel tool execution with `Task.async_stream(..., ordered: false)` means the streamed tool-result events arrive in completion order (non-deterministic across runs), while non-streaming `step/3` collects results in tool-call-id order (deterministic).

   Decision: the equivalence assertion is exact struct equality MODULO a `tool_call_id` sort on `:tool`-role messages. Every other field is asserted exact.

   **Helper contract (Finding F7):** `assert_equivalent_step_result(a, b)` in `test/support/assertions.ex` asserts field-by-field:
   - `StepResult.response == StepResult.response` — exact. `response.tool_calls` is built by `StreamCollector.build_tool_calls/1` from the collector's `:tool_call_order` (deterministic, adapter event order) on BOTH sides; they match exactly.
   - `StepResult.done? == StepResult.done?` — exact.
   - `StepResult.metadata == StepResult.metadata` — exact. Halt-metadata atoms (`:halted_reason`, `:halt_tool_call_id`, etc.) are deterministic given the same handler return.
   - `StepResult.tool_results` sorted by `tool_call_id` on both sides, then `==`.
   - `StepResult.thread.messages` — split into `:tool`-role messages and everything else:
     - Non-tool messages (`:system`, `:user`, `:assistant`): exact list equality (deterministic ordering — input thread, then augmented assistant message).
     - `:tool`-role messages: sorted by `tool_call_id`, then `==`.
   - The augmented assistant message's `metadata.tool_calls` field is a list of `%ToolCall{}` structs in adapter event order (deterministic) — exact equality required.

   Rejected alternatives:
   - Use `ordered: true` in `Task.async_stream/5`. Serialises output buffering — slow tools block faster ones from emitting. Loses the real-time benefit of streaming.
   - Declare the property doesn't hold for parallel tool calls. Weakens the step-equivalence invariant below spec §3's stream-first guarantee.

   Phase 7 reuses `assert_equivalent_step_result/2` for `chat_equivalence` (extends the helper to sort `ChatResult.steps` by step index — deterministic).

   `Docs target: @moduledoc ALLM.Chat` ("Step equivalence" paragraph referencing the assertion helper) + `@doc ALLM.Test.Assertions.assert_equivalent_step_result/2`.

10. **Assistant message in `StepResult.thread` is built deterministically from the collector's `:current_text` (via `to_response/1`) plus `response.tool_calls` in `metadata.tool_calls`.** When the adapter's `:message_completed` event emits an assistant message (Fake's `closing_events/1` at `lib/allm/providers/fake.ex:520-534` emits `%Message{role: :assistant, content: text}` where `text` is the adapter's own reconstruction), the `%StepResult.thread` loses the tool-call metadata on the assistant message — critical for serialisable round-tripping (spec §2, Layer A). A second, subtler issue (Finding F6): `response.message.content` (from the adapter's `:message_completed` payload) is not guaranteed to equal `response.output_text` (from the collector's `:current_text` accumulation of `:text_delta` events). Real adapters may emit `:message_completed` with a normalized/trimmed final text that differs from the accumulated deltas, or with empty content when no text was produced.

    Decision: `ALLM.Chat.step/3` and `.stream_step/3` build the thread's assistant message from scratch, NOT from `response.message`:

    ```elixir
    assistant_msg = %ALLM.Message{
      role: :assistant,
      content: response.output_text,    # authoritative text from collector's :current_text
      metadata:
        %{finish_reason: response.finish_reason}
        |> maybe_put(:tool_calls, response.tool_calls, &(&1 != []))
    }
    ```

    `response.output_text` is populated by `ALLM.StreamCollector.to_response/1` from `state.current_text` (the accumulated delta string OR the authoritative `:text_completed` payload if seen). This guarantees that the assistant message's content matches what the consumer saw via `:text_delta`/`:text_completed` events — no adapter-dependent divergence. The stored `metadata.tool_calls` is a list of `%ToolCall{}` structs (Layer A serialisable; round-trips through `:erlang.term_to_binary/1` and Jason via `lib/allm/tool_call.ex:51-53`).

    Rejected: use `response.message` verbatim and just patch metadata. Trusts the adapter's final-message content to equal the accumulated text; introduces test flakes when the two diverge. Rejected: store tool_calls as a list of plain maps. Loses the type-tag at deserialisation time; caller has to re-hydrate.

    `Docs target: @doc ALLM.Chat.step/3` ("Assistant message construction" paragraph).

11. **`StreamCollector` gains a `:tool_results` field (list of `Message.t()`, default `[]`) plus three new fold clauses: `:tool_result_encoded`, `:tool_halt`, and `:ask_user_requested`.** Phase 5 Non-obvious Decision #5 said Phase 6 would add orchestration-tag clauses "ahead of the catch-all". Phase 6 adds three such clauses (see the Behaviour & Type Contracts section for exact code):
    - `:tool_result_encoded` → appends `%Message{role: :tool, tool_call_id: id, content: content}` to `state.tool_results`.
    - `:tool_halt, %{tool_call_id: id, reason: reason, result: _}` → sets `state.halt = {:halt, reason, id}` (a new Phase 6 field).
    - `:ask_user_requested, %{tool_call_id: id, question: q, opts: o, tool_name: _}` → sets `state.halt = {:ask_user, :ask_user, id, q, o}` (same field, different shape).

    The `:tool_execution_started`, `:tool_execution_completed`, and `:step_completed` tags stay in the catch-all for Phase 6 — the collector does not need their state. Phase 7's multi-turn `chat/3` may add fold clauses for `:step_completed` (appending `%StepResult{}` to the existing `:steps` field).

    **Why fold `:tool_halt` and `:ask_user_requested` into the collector** (Finding F8): `StreamCollector.to_step_result/1` computes `done?` from the collector's terminal state. With a handler-halt, `finish_reason` stays `:tool_calls` (the adapter's terminal reason) but the step IS done — the handler halted. Folding halt events into a dedicated `:halt` field lets `to_step_result/1` correctly compute `done?: state.halt != nil or state.finish_reason in [:stop, :length, :content_filter, :error]`. Without this, a consumer that collects events via `stream_step/3 |> Enum.reduce(new(), &apply_event/2) |> to_step_result/1` would see `done?: false` after a handler halt — a silent Layer C composability bug.

    `to_step_result/1` is updated accordingly (currently hardcodes `tool_results: []` in the shipped code):
    ```elixir
    done?: state.halt != nil or state.finish_reason in [:stop, :length, :content_filter, :error],
    tool_results: state.tool_results,
    metadata: build_halt_metadata(state)  # folds :halt tuple into :halted_reason keys
    ```

    **Note on `:steps` and `:last_response` field presence.** Verified against `lib/allm/stream_collector.ex:96-108` on 2026-04-24: the committed `%StreamCollector{}` struct already ships with `:steps: []`, `:last_response: nil`, and `:last_message: nil` fields (all three). Phase 5 populates `:last_message` but leaves `:steps` and `:last_response` unpopulated — they are structural shelves for Phase 7's `chat/3` to fill. Phase 6 adds `:tool_results` alongside them; no change to any existing field's population pattern. The design's earlier reference to a "5.1 retro F1 UNAPPLIED" issue reflected a stale codebase survey — the fields exist, the retro is moot for Phase 6's scope.

    `Docs target: @moduledoc ALLM.StreamCollector` ("Phase 6 extension" paragraph under "Fold semantics" — three rows added to the table: `:tool_result_encoded`, `:tool_halt`, `:ask_user_requested`).

12. **`Chat.stream_step/3` emits `:message_completed` only once (from the adapter stream pass-through), NOT a second synthesized one after tool execution.** A potential design confusion: does `stream_step/3` emit a new `:message_completed` for the assistant turn after augmenting the message with tool_calls metadata? Decision: **no**. The adapter's `:message_completed` is passed through verbatim. The augmentation (putting tool_calls into `metadata`) happens in the final `%StepResult.thread` only, not re-emitted as a new event. Rationale: emitting a second `:message_completed` breaks the spec §8 contract that one adapter turn produces one `:message_completed`. Consumers who want the augmented message pull it from `StepResult.thread` (for `step/3`) or from `:step_completed` event's `:thread` field (for `stream_step/3`).

    `Docs target: @doc ALLM.Chat.stream_step/3` ("Event sequence" paragraph).

## Behaviour & Type Contracts

### `ALLM.ToolRunner` (Layer C — new internal module)

```elixir
defmodule ALLM.ToolRunner do
  @moduledoc """
  Internal — use `ALLM.step/3` / `ALLM.stream_step/3` instead. See spec §17.

  Executes a list of `%ToolCall{}` values via the engine's tool executor,
  encodes results via the tool result encoder, and returns either:

    * a list of `:tool`-role `%Message{}` values (non-streaming), or
    * a lazy stream of `ALLM.Event` values (streaming — Phase 6 extension to §17).

  Both variants share execution logic: parallel dispatch via
  `Task.async_stream/5`, per-tool timeout, and the `on_tool_error` policy.
  """

  alias ALLM.{Engine, Event, Message, Tool, ToolCall, ToolExecutor, ToolResultEncoder}
  alias ALLM.Error.{EngineError, ToolError}

  @type run_opts :: [
          engine: Engine.t(),
          context: map(),
          request_id: String.t() | nil,
          session_id: String.t() | nil,
          tool_executor: module() | nil,
          tool_result_encoder: module() | nil,
          on_tool_error: :continue | :halt,
          tool_timeout: timeout(),
          max_concurrency: pos_integer()
        ]

  @type run_outcome ::
          {:ok, [Message.t()]}
          | {:ok, [Message.t()], halt_metadata :: map()}
          | {:error, EngineError.t()}

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
          halted_reason: :tool_error,
          halt_tool_call_id: String.t()
        }

  @type halt_metadata :: ask_user_metadata() | tool_halt_metadata() | tool_error_halt_metadata()

  @spec run_tool_calls([ToolCall.t()], [Tool.t()], run_opts()) :: run_outcome()
  def run_tool_calls(tool_calls, tools, opts)

  @spec stream_tool_calls([ToolCall.t()], [Tool.t()], run_opts()) :: Enumerable.t()
  def stream_tool_calls(tool_calls, tools, opts)
end
```

**Invariants:**

1. `run_tool_calls/3` and `stream_tool_calls/3` emit tool-result messages/events in `tool_calls` input order for the non-streaming path (ToolRunner sorts by input index before returning), and in **execution completion order** for the streaming path (`Task.async_stream/5` with `ordered: false`). The SET of messages/events is identical across both paths when compared after sorting by `tool_call_id`; only the emission ordering differs. This is the load-bearing invariant for Non-obvious Decision #9's equivalence test helper.
2. **Unknown-tool pre-flight (Finding F12).** If **any** tool call names a tool not in `tools`, `run_tool_calls/3` returns `{:error, %EngineError{reason: :unknown_tool, metadata: %{tool_name: name}}}` **synchronously, before** any tool executes. The stream variant emits a single `{:error, %EngineError{reason: :unknown_tool, metadata: %{tool_name: name}}}` event and terminates (via a degenerate stream with exactly one error element). Only the FIRST unknown tool is named in metadata — multiple unknown tools are rare in practice and a single name gives the caller a concrete fix.
3. **Sibling-drain semantics on halt (Finding F5).** When a handler returns `{:halt, _, _}` or `{:ask_user, _, _}`, OR when `on_tool_error: :halt` fires on a `{:error, _}` or `%ToolError{}`, `ToolRunner` CONTINUES reducing the `Task.async_stream/5` until it naturally exhausts. Rationale: once tasks are spawned, they are linked to the caller and running; short-circuiting the reducer doesn't kill them (they finish in their own processes), and not pulling their results means the results are lost while the side effects still ran. Draining is the semantics-preserving path. Consequences:
   - `StepResult.tool_results` / emitted `:tool_result_encoded` events include every tool call that completed, including siblings that completed after the halting call.
   - Unstarted tasks (those never scheduled because the halting tool caused `Task.async_stream/5`'s work queue to complete) are NOT included. `Task.async_stream/5`'s work scheduler saturates `max_concurrency` workers; when the halting tool finishes and we continue draining, the scheduler launches the next queued work item until the batch is empty. So "unstarted" only applies to the degenerate case of a subsequent batch cancellation, which Phase 6 does not trigger.
   - `halt_metadata` reflects the FIRST halt event observed by the reducer (per StreamCollector's first-halt-wins invariant). Multiple siblings halting is a rare race; the first-observed halt wins for the transcript.
4. Handler-returned `{:ask_user, question}` / `{:ask_user, question, opts}` triggers the same drain-to-completion as `{:halt, _, _}`. The halted tool's result is encoded as `"<awaiting user response>"` (spec §12.3). `halt_metadata` is `%ask_user_metadata{}` (typed).
5. `on_tool_error: :halt` on a `{:error, _}` return triggers sibling drain. `halt_metadata` is `%tool_error_halt_metadata{}`.
6. `on_tool_error: :continue` on a `{:error, _}` return encodes the error term as a JSON object `%{"error" => Exception.message(err) | inspect(err)}` (use `Exception.message/1` when err is an exception struct; `inspect/1` otherwise) and the batch proceeds normally.
7. Encoder raises (`Protocol.UndefinedError`, `Jason.EncodeError`) are caught and wrapped as `%ToolError{reason: :encoding_failed, cause: exception}` (Non-obvious Decision #3), then routed through `on_tool_error` identically to handler `{:error, _}` returns.
8. **Tool timeout (Finding F1).** `Task.async_stream/5` is invoked with `timeout: opts[:tool_timeout] || 30_000`, `on_timeout: :kill_task`, `ordered: false`, **and `zip_input_on_exit: true`**. The `zip_input_on_exit: true` option is load-bearing: with `ordered: false` the stream elements arrive in completion order, so the runner needs the original input (`{%ToolCall{}, idx}`) zipped onto exit elements to attribute a timeout (or other non-`:normal` exit) back to the specific tool call AND recover the index used for input-order sorting of the non-streaming path's result list. Without `zip_input_on_exit: true`, a bare `{:exit, :timeout}` element cannot be mapped back to the tool call that timed out. Pattern match on the element:

   ```elixir
   case task_stream_element do
     {:ok, {idx, %ToolCall{} = tc, dispatch}} ->
       # normal completion — dispatch already carries the encoded result
       dispatch

     {:exit, {{%ToolCall{} = tc, idx}, :timeout}} ->
       # wrap as %ToolError{reason: :timeout, tool_name: tc.name, tool_call_id: tc.id}
       # and re-route through on_tool_error
       ...

     {:exit, {{%ToolCall{} = tc, idx}, other_reason}} ->
       # non-timeout exit (task crashed outside the executor's try/rescue, etc.)
       # wrap as %ToolError{reason: :handler_exit, cause: other_reason, ...}
       ...
   end
   ```

   Note: the default `ALLM.ToolExecutor.Default` already catches handler `raise`/`exit` inside its own `try/rescue/catch` boundary (`lib/allm/tool_executor/default.ex`), so the `{:exit, {{tc, idx}, other_reason}}` arm is primarily defensive — it fires only for exits that escape the executor (e.g., a custom executor that forgoes the catch, or an OTP shutdown signal). IEx verification on OTP 27 on 2026-04-24 confirmed the exit-tuple shape with `zip_input_on_exit: true`; an earlier note in this doc pattern-matched on `{:exit, :timeout}` (the stock shape without `zip_input_on_exit`) and has been superseded.

   Timed-out tasks emit `{:tool_execution_completed, %{result: {:error, %ToolError{reason: :timeout}}}}` (Non-obvious Decision #7 — no new `:tool_execution_cancelled` variant).
9. **Empty tool_calls short-circuit (Finding F10).** `run_tool_calls([], _, _)` returns `{:ok, []}` without invoking `Task.async_stream/5`. `stream_tool_calls([], _, _)` returns `Stream.concat([])` (empty enumerable). This guards against `Task.async_stream/5`'s `ArgumentError` on `max_concurrency: 0`.
10. The arity-2 form of handlers receives `opts` keyword with `:context`, `:session_id`, `:request_id`, `:tool_call`, `:engine` populated per spec §5.2. `:session_id` is `nil` in Phase 6. `:request_id` is `opts[:request_id]` (originates from `Response.request_id` when set by the adapter).

**Error reason table (synchronous return from `run_tool_calls/3`):**

| Condition | Return | Recovery |
|-----------|--------|----------|
| A tool call's `name` isn't in `tools` | `{:error, %EngineError{reason: :unknown_tool, message: "tool #{name} not in engine.tools"}}` | Register the tool on the engine or ensure adapter is only emitting known tools. |
| `opts[:on_tool_error]` is a function | `{:error, %ArgumentError{message: "on_tool_error function form is not implemented in Phase 6; use :continue or :halt, or wait for Phase 7"}}` → actually raised, not returned | Pass `:continue` or `:halt` or wait for Phase 7. Documented caveat. |
| A handler returns a value not matching the five legal shapes | `%ToolError{reason: :invalid_return}` surfaced via `on_tool_error` policy | Fix the handler return value. |
| A handler raises | `%ToolError{reason: :handler_raised}` via `on_tool_error` policy | Fix the handler or catch internally. |

**Idiomatic Elixir requirements:**

- `Task.async_stream/5` invocation — verified in IEx on OTP 27 on 2026-04-24: `Task.async_stream/5` accepts `max_concurrency`, `timeout`, `on_timeout: :kill_task | :exit`, `ordered: true | false`, and `zip_input_on_exit: true | false`. Phase 6 uses `on_timeout: :kill_task`, `ordered: false`, and `zip_input_on_exit: true`. With `zip_input_on_exit: true`, a timed-out element has the shape `{:exit, {input, :timeout}}` instead of the stock `{:exit, :timeout}`; this is load-bearing for attributing exits back to specific tool calls when `ordered: false` — see Invariant 8.
- `try/rescue` for handler exceptions is already in `ALLM.ToolExecutor.Default.execute/3` at `lib/allm/tool_executor/default.ex:77-87`. Phase 6's `ToolRunner` does NOT re-wrap; it trusts the executor's return. The encoder-side `try/rescue` is the only Phase 6 addition.
- `Enum.find/2` for tool lookup by name: `Enum.find(tools, fn %Tool{name: n} -> n == tool_call.name end)`. `nil` on not found.
- `:erlang.fun_info/2` for arity dispatch is in the executor, not the ToolRunner. ToolRunner just calls `executor.execute(tool, parsed_args, opts_keyword)`.

### `ALLM.Chat` (Layer C — new internal module, Phase 6 functions)

```elixir
defmodule ALLM.Chat do
  @moduledoc """
  Internal — use `ALLM.step/3` / `ALLM.stream_step/3` / `ALLM.chat/3` /
  `ALLM.stream/3` instead. See spec §17.

  Phase 6 ships `step/3` and `stream_step/3` (single-turn).
  Phase 7 adds `run/3` and `stream/3` (multi-turn).
  """

  alias ALLM.{Engine, Event, Message, Request, Response, StepResult, StreamCollector, Thread, ToolCall, ToolRunner}
  alias ALLM.Error.{AdapterError, EngineError, ValidationError}

  @type step_opts :: [
          mode: :auto | :manual,
          tool_timeout: timeout(),
          on_tool_error: :continue | :halt,
          tool_executor: module() | nil,
          tool_result_encoder: module() | nil,
          # Phase 5 opts passed through:
          emit_text_deltas: boolean(),
          emit_tool_deltas: boolean(),
          include_raw_chunks: boolean(),
          on_event: (Event.t() -> any()) | nil,
          # Phase 2 opts passed through:
          model: String.t(),
          adapter_opts: keyword()
        ]

  @spec step(Engine.t(), Thread.t() | [Message.t()], step_opts()) ::
          {:ok, StepResult.t()} | {:error, EngineError.t() | AdapterError.t() | ValidationError.t()}
  def step(engine, thread_or_messages, opts \\ [])

  @spec stream_step(Engine.t(), Thread.t() | [Message.t()], step_opts()) ::
          {:ok, Enumerable.t()} | {:error, EngineError.t() | AdapterError.t() | ValidationError.t()}
  def stream_step(engine, thread_or_messages, opts \\ [])
end
```

**Invariants:**

1. `step/3` always returns `{:ok, %StepResult{}}` or `{:error, struct}`. A tool-execution failure (handler raise, encoder raise, timeout) that's routed through `on_tool_error: :continue` results in `{:ok, %StepResult{done?: false, tool_results: [error_msg]}}` — not `{:error, _}`. The `{:error, _}` return is reserved for pre-flight failures (validation, adapter synchronous error) and for `%EngineError{reason: :unknown_tool}` (which is a batch-level failure, not a per-tool one).
2. `mode: :auto` (default) executes tool calls via `ALLM.ToolRunner.run_tool_calls/3` and appends tool-result messages to the thread.
3. `mode: :manual` skips tool execution. `StepResult.tool_results == []`; `StepResult.response.tool_calls` carries the tool calls for the caller. `StepResult.done? == false` (caller is expected to submit results and continue). `StepResult.metadata.mode == :manual`. `:halted_reason` is NOT set — this is a mode, not a halt (Finding F2).
4. `StepResult.thread` is the input thread plus:
   - One `:assistant`-role message with `content: response.output_text`, `metadata.tool_calls: response.tool_calls` (if non-empty), `metadata.finish_reason: response.finish_reason`.
   - Zero-to-N `:tool`-role messages, one per executed tool call, with `tool_call_id: id`, `content: encoded_string`.
5. `StepResult.done?` is `true` in three cases: (a) `response.finish_reason != :tool_calls`, (b) `on_tool_error: :halt` fired, (c) a handler returned `{:halt, _, _}` or `{:ask_user, _, _}`. Otherwise `false`.
6. `stream_step/3` emits events in order: all adapter events (pass-through from `stream_generate/3`), then zero-to-N tool-execution event groups (one group per tool: `:tool_execution_started`, `:tool_execution_completed`, `:tool_result_encoded` — optionally `:ask_user_requested` or `:tool_halt` in place of `:tool_result_encoded` when the handler returns those shapes), then one terminal `:step_completed` event. Tool-execution event groups interleave per `Task.async_stream/5`'s completion ordering.
7. `:step_completed` event's `%{response, thread}` payload contains the final response (with augmented metadata) and the final thread (with all tool-role messages appended). This is the authoritative terminal-state event for the stream.

**Error reason table (synchronous return from `step/3` and `stream_step/3`):**

| Function | Error reason | Recovery guidance |
|----------|--------------|--------------------|
| `step/3`, `stream_step/3` | `%EngineError{reason: :missing_adapter}` | Construct engine with `:adapter`. Inherited from Phase 5. |
| `step/3`, `stream_step/3` | `%EngineError{reason: :missing_stream_adapter}` | Adapter doesn't implement `ALLM.StreamAdapter`. Inherited from Phase 5. |
| `step/3`, `stream_step/3` | `%EngineError{reason: :unknown_tool, metadata: %{tool_name: name}}` | One of the returned tool calls names a tool not registered on the engine. Extract `name` from `error.metadata.tool_name`. |
| `step/3`, `stream_step/3` | `%ValidationError{reason: :invalid_request}` | Request shape violation. Inherited from Phase 5. |
| `step/3`, `stream_step/3` | `%AdapterError{reason: _}` | Adapter pre-flight error. Inherited from Phase 5. |
| `step/3` | `%ValidationError{reason: :invalid_thread}` | Thread validation failed (e.g., `:tool` message without `tool_call_id`). Reuses `ALLM.Validate.thread/1` from Phase 1. |

**Idiomatic Elixir requirements:**

- `Stream.resource/3` is used at the `Chat.stream_step/3` layer for the three-phase state machine (Non-obvious Decision #1). The `after_fun` delegates to the active sub-resource via `Enumerable.reduce/3` with a `{:halt, _}` accumulator — triggering that sub-resource's own cleanup once. No implementation-internal claims about Task.async_stream's work scheduler are needed; only the external behaviour matters. Verified in IEx on OTP 27 on 2026-04-24: `[1, 2, 3] |> Task.async_stream(fn x -> x end) |> Enum.take(1) |> length() == 1`, and `Process.info(self(), :links)` after the `Enum.take/2` shows no leaked task processes (linked tasks exit with the consumer if they survive past the halt).
- Assistant-message construction uses plain struct literals and `Map.put/3` on `message.metadata`. No `Message.update_metadata/3` helper is added (Finding F9): construct the augmented assistant message inline in `Chat.step/3` with `%{msg | metadata: Map.put(msg.metadata, :tool_calls, tool_calls)}`.
- `with :ok <- validate(...), {:ok, resp} <- adapter_call(...), {:ok, msgs, halt} <- tool_execution(...) do ...` — the typical Elixir pattern for layered dispatch.

### `ALLM.StreamCollector` (Layer C — amendment for Phase 6)

```elixir
defmodule ALLM.StreamCollector do
  @type halt_state ::
          nil
          | {:halt, reason :: atom(), tool_call_id :: String.t()}
          | {:ask_user, :ask_user, tool_call_id :: String.t(), question :: String.t(), opts :: keyword()}

  @type state :: %__MODULE__{
          # ...existing fields from Phase 5 (thread, current_text, current_tool_calls,
          # tool_call_order, last_message, last_response, steps, usage, finish_reason,
          # raw_finish_reason, error, done?, metadata — all as shipped at
          # lib/allm/stream_collector.ex:96-108)...
          tool_results: [Message.t()],  # Phase 6 addition
          halt: halt_state()            # Phase 6 addition
        }

  defstruct [
    # ...existing defaults unchanged...
    tool_results: [],
    halt: nil
  ]
end
```

**Phase 6 fold clauses (inserted immediately before the catch-all per Phase 5 Non-obvious Decision #5):**

```elixir
def apply_event(
      %__MODULE__{} = state,
      {:tool_result_encoded, %{id: id, content: content}}
    )
    when is_binary(id) and is_binary(content) do
  tool_msg = %Message{role: :tool, tool_call_id: id, content: content, metadata: %{}}
  %{state | tool_results: state.tool_results ++ [tool_msg]}
end

def apply_event(
      %__MODULE__{} = state,
      {:tool_halt, %{tool_call_id: id, reason: reason}}
    )
    when is_binary(id) and is_atom(reason) do
  %{state | halt: {:halt, reason, id}}
end

def apply_event(
      %__MODULE__{} = state,
      {:ask_user_requested, %{tool_call_id: id, question: q, opts: o}}
    )
    when is_binary(id) and is_binary(q) and is_list(o) do
  %{state | halt: {:ask_user, :ask_user, id, q, o}}
end
```

**`to_step_result/1` amendment:**

```elixir
def to_step_result(%__MODULE__{thread: nil}),
  do: raise(ArgumentError, "StreamCollector.to_step_result/1 requires a thread; use to_response/1")

def to_step_result(%__MODULE__{thread: thread} = state) do
  %StepResult{
    thread: thread,
    response: to_response(state),
    tool_results: state.tool_results,
    done?: step_done?(state),
    metadata: merge_halt_metadata(state.metadata, state.halt)
  }
end

defp step_done?(%{halt: halt, finish_reason: fr}) do
  halt != nil or fr in [:stop, :length, :content_filter, :error]
end

defp merge_halt_metadata(base, nil), do: base
defp merge_halt_metadata(base, {:halt, reason, id}),
  do: Map.merge(base, %{halted_reason: reason, halt_tool_call_id: id})
defp merge_halt_metadata(base, {:ask_user, :ask_user, id, q, o}),
  do: Map.merge(base, %{
    halted_reason: :ask_user,
    pending_tool_call_id: id,
    pending_question: q,
    ask_user_opts: o
  })
```

**Invariants:**

1. `:tool_result_encoded` fold appends one `%Message{role: :tool, tool_call_id: id, content: content, metadata: %{}}` to `state.tool_results`. Order is event-arrival order (Task.async_stream completion order for stream path).
2. `:tool_halt` sets `state.halt = {:halt, reason, id}`. Subsequent halt events are IGNORED (first halt wins — rationale: parallel tools may each halt independently; Phase 6 uses first-pulled as canonical per the Phase B sibling-drain rule).
3. `:ask_user_requested` sets `state.halt = {:ask_user, :ask_user, id, q, o}`. Subsequent ask-user events ignored (same rationale).
4. `to_step_result/1` reads `:tool_results` from the struct and computes `done?` from `state.halt` OR `state.finish_reason`. For a thread-less collector (`new/0`), raises `ArgumentError` per existing Phase 5 behaviour.
5. The other orchestration tags (`:tool_execution_started`, `:tool_execution_completed`, `:step_completed`) fall through to the catch-all. Phase 6 adds no explicit clauses for them. Phase 7 may add clauses for `:step_completed` to populate `:steps`.
6. Totality preserved: new clauses are total over their declared shape; malformed events fall through to the catch-all.
7. **First-halt-wins invariant**: once `state.halt != nil`, subsequent `:tool_halt` / `:ask_user_requested` events leave it unchanged. Implementation: the clauses pattern-match `state.halt == nil` (additional guard); a second halt event matches the catch-all no-op. Test asserts: two `:tool_halt` events in sequence → `state.halt` reflects the first.

**Idiomatic Elixir requirements:**

- `state.tool_results ++ [msg]` — list concatenation at the tail. O(n) per event; n is bounded by typical tool-call count (≤ 10 per turn). `[msg | state.tool_results]` with reversal in `to_step_result/1` is rejected as premature optimisation.
- Inline `%Message{role: :tool, tool_call_id: id, content: content, metadata: %{}}` struct construction inside the fold clause — NO `Message.tool_result/2` helper is added (see below). The facade's `ALLM.tool_result/2` at `lib/allm.ex:88-91` already covers caller-side needs; the collector's inline construction avoids a circular module reference (`ALLM.StreamCollector` → `ALLM` → `ALLM.Message`).

### `ALLM.Message` (Layer A — no changes)

**No new helpers in Phase 6** (Finding F9). The facade's `ALLM.tool_result/2` (`lib/allm.ex:88-91`, verified 2026-04-24) already serves callers; the collector inlines `%Message{role: :tool, ...}` struct construction. The earlier draft's `Message.tool_result/2` and `Message.update_metadata/3` additions are dropped.

`Chat.step/3`'s assistant-message augmentation (Non-obvious Decision #10) uses a local private helper `put_tool_calls_metadata(message, [])` (no-op) / `put_tool_calls_metadata(message, tool_calls)` (merges into `metadata`). This helper lives in `lib/allm/chat.ex`, not in `Message`. It's internal — `Message.metadata` is a plain map, so `%{msg | metadata: Map.put(msg.metadata, :tool_calls, tool_calls)}` is the whole implementation.

### `ALLM.StreamRunner` (Layer C — attribute rename only)

```elixir
defmodule ALLM.StreamRunner do
  # Phase 6 rename: @phase_7_opts → @orchestration_opts.
  # Contents unchanged: [:mode, :max_turns, :halt_when].
  # Phase 6 consumes :mode at the ALLM.Chat layer; StreamRunner still strips
  # the full list at the adapter boundary as a safety net.
  @orchestration_opts [:mode, :max_turns, :halt_when]
end
```

**Invariants:**

1. No behavioural change. Every existing test asserting the strip behaviour passes unchanged.
2. The attribute name change is a local refactor per Non-obvious Decision #5.

### `ALLM` (Layer C — public facade additions)

```elixir
defmodule ALLM do
  @spec step(Engine.t(), Thread.t() | [Message.t()], keyword()) ::
          {:ok, StepResult.t()} | {:error, EngineError.t() | AdapterError.t() | ValidationError.t()}
  def step(engine, thread_or_messages, opts \\ []),
    do: ALLM.Chat.step(engine, thread_or_messages, opts)

  @spec stream_step(Engine.t(), Thread.t() | [Message.t()], keyword()) ::
          {:ok, Enumerable.t()} | {:error, EngineError.t() | AdapterError.t() | ValidationError.t()}
  def stream_step(engine, thread_or_messages, opts \\ []),
    do: ALLM.Chat.stream_step(engine, thread_or_messages, opts)
end
```

**Invariants:**

1. Both functions are pure one-line delegations — no logic beyond the delegation. Keeps the facade a transparent entry point and doctests simple.
2. Doctests on both functions use `ALLM.Providers.Fake` with a tool-call fixture from `ALLM.Test.FakeFixtures.single_tool_call/2`.

## Module Tree

```
lib/allm/
├── stream_collector.ex                     (MODIFY — add :tool_results + :halt fields; three new fold clauses; done?/metadata update in to_step_result)
├── stream_runner.ex                        (MODIFY — rename @phase_7_opts → @orchestration_opts, function name, log string, moduledoc heading)
├── tool_runner.ex                          (NEW — ALLM.ToolRunner, internal)
└── chat.ex                                 (NEW — ALLM.Chat, internal)

lib/allm.ex                                 (MODIFY — add step/3 and stream_step/3)

test/allm/
├── stream_collector_test.exs               (MODIFY — tests for 3 new fold clauses, done?/halt metadata, first-halt-wins invariant)
├── tool_runner_test.exs                    (NEW — full tool execution coverage)
├── chat_step_test.exs                      (NEW — Chat.step/3 unit tests)
├── chat_stream_step_test.exs               (NEW — Chat.stream_step/3 unit tests)
├── allm_step_test.exs                      (NEW — facade + doctest)
├── allm_stream_step_test.exs               (NEW — facade + doctest)
├── step_equivalence_test.exs               (NEW — property: step ≡ stream_step |> collect)
└── providers/
    └── fake_scenarios_test.exs             (MODIFY — flip 3 @tag :pending → active)

test/support/
└── assertions.ex                           (NEW or MODIFY — assert_equivalent_step_result/2 helper)

CHANGELOG.md                                (MODIFY — one line per new public symbol + scenario activations)
```

Test files mirror source files 1:1. No `test/support/fake_fixtures.ex` changes — Phase 4's existing fixtures cover every Phase 6 need.

## Phases

### Sub-phase 6.1: `ALLM.ToolRunner` (Layer C)

**Goal:** Ship `ALLM.ToolRunner` with `run_tool_calls/3` (non-streaming) and `stream_tool_calls/3` (streaming). Parallel dispatch via `Task.async_stream/5`; per-tool timeout; `on_tool_error: :continue | :halt`; handler-return dispatch for all five spec §5.2 shapes. Also ship the `StreamRunner` attribute rename (`@phase_7_opts` → `@orchestration_opts`).

**Spec sections:** §5.2, §7.3, §7.4, §17, §30 (partial).

#### 6.1.1 Test Plan (write first)

`test/allm/tool_runner_test.exs` (NEW):

**Happy path (non-streaming):**
- `run_tool_calls([%ToolCall{id: "c0", name: "echo", arguments: %{text: "hi"}}], [%Tool{name: "echo", handler: fn %{text: t} -> {:ok, t} end}], [engine: engine])` → `{:ok, [%Message{role: :tool, tool_call_id: "c0", content: ~s("hi")}]}`.
- Two tool calls with two registered handlers → both execute, both messages returned in call-order. Handler invocation order non-deterministic (`ordered: false`); result order is call-order (ToolRunner sorts by id before returning).
- Arity-1 handler (`fn args -> {:ok, args} end`) dispatched correctly (inherited from `ToolExecutor.Default`).
- Arity-2 handler (`fn args, opts -> {:ok, opts[:context]} end`) receives engine's context map.

**Happy path (streaming):**
- `stream_tool_calls(...)` with one tool call emits exactly `[:tool_execution_started, :tool_execution_completed, :tool_result_encoded]` in that order for that tool.
- With two tool calls, the 2 × 3 = 6 events interleave per completion order; but for each tool-call id, the three events are in order (started → completed → encoded).
- `Enum.to_list/1` on the stream produces `length(tool_calls) * 3` events (no `:step_completed` — that's Chat's concern).

**Unknown tool:**
- `run_tool_calls([%ToolCall{name: "missing"}], [], opts)` → `{:error, %EngineError{reason: :unknown_tool, cause: "missing"}}`. No tools execute.
- Streaming variant: emits one `{:error, %EngineError{}}` and terminates.

**Handler `{:error, reason}`:**
- `on_tool_error: :continue` — handler returns `{:error, :bad_arg}`; result is encoded (via JSON encoder, produces `%{"error" => "bad_arg"}` → `~s({"error":"bad_arg"})`); tool-result message has this as content; outer return is `{:ok, [msg]}`.
- `on_tool_error: :halt` — same handler; outer return is `{:ok, [msg], %{halted_reason: :tool_error, halt_tool_call_id: "c0"}}`. The tool-result message is still in the list (transcript correctness).

**Handler raises:**
- Handler `fn _ -> raise "boom" end` → executor catches via `try/rescue`, returns `{:error, %ToolError{reason: :handler_raised}}`; with `on_tool_error: :continue`, the error is encoded and added as tool-result message.

**Handler `{:halt, reason, result}`:**
- `fn _ -> {:halt, :plan_submitted, %{status: "ok"}} end` → stream emits `:tool_halt`; outer return is `{:ok, [msg_with_encoded_result], %{halted_reason: :plan_submitted, halt_tool_call_id: "c0", halt_result: %{status: "ok"}}}`. Sibling tools in the same batch: any not-yet-started tasks are cancelled; in-flight siblings run to completion (documented limitation).
- A reserved reason (`:tool_error`, `:max_turns`, etc.) is accepted — Phase 6 doesn't validate reserved reasons at the handler-return boundary (per spec §5.2 "callers pick reason").

**Handler `{:ask_user, question}` / `{:ask_user, question, opts}`:**
- `fn _ -> {:ask_user, "which city?"} end` → stream emits `:ask_user_requested`; outer return is `{:ok, [msg_with_awaiting_response_content], %{halted_reason: :ask_user, pending_question: "which city?", pending_tool_call_id: "c0", ask_user_opts: []}}`.
- Tool-result message has `content: "<awaiting user response>"` (spec §12.3 step 1).
- With opts `[choices: ["A", "B"]]` → `ask_user_opts: [choices: ["A", "B"]]`.

**Tool timeout:**
- Handler that sleeps 100ms; `tool_timeout: 50` → the tool's result is `{:error, %ToolError{reason: :timeout}}`; with `on_tool_error: :continue`, the error is encoded and added as tool-result message.
- Streaming variant: `:tool_execution_completed` event's `:result` is `{:error, %ToolError{reason: :timeout}}`.

**Encoder failure:**
- Handler returns `make_ref()` (not JSON-encodable); encoder raises `Protocol.UndefinedError`; ToolRunner catches and wraps as `%ToolError{reason: :encoding_failed}`; with `on_tool_error: :continue`, the error is routed (encoded via inspect); with `on_tool_error: :halt`, step halts.

**`max_concurrency`:**
- 20 tool calls, `max_concurrency: 2`; measure that no more than 2 handlers run concurrently (use a counter via `:counters.new/2` and `add/3`/`sub/2` at entry/exit; assert peak ≤ 2). Verified in IEx on OTP 27 on 2026-04-24: `:counters.new(1, [:atomics])` returns `{:atomics, ref}` — Phase 6 tests use `:counters.new(1, [:write_concurrency])` as a peak-concurrency tracker.

**`on_tool_error` function form rejection:**
- `run_tool_calls(..., on_tool_error: fn _, _ -> :halt end)` raises `ArgumentError` with message pointing to Phase 7.

#### 6.1.2 Implementation Checklist

- [ ] `lib/allm/tool_runner.ex` — new module with module doc, `@moduledoc`, typespecs matching the contract section.
- [ ] `run_tool_calls/3` implementation: (a) validate `on_tool_error` is atom (raise on fn), (b) look up each tool by name and emit `EngineError.unknown_tool/1` on any miss, (c) resolve executor/encoder from opts/engine, (d) `Task.async_stream/5` with computed `max_concurrency`, `ordered: false`, `timeout: tool_timeout`, `on_timeout: :kill_task`, (e) for each completed task, dispatch on handler return shape, (f) accumulate messages + halt-metadata, (g) return `{:ok, msgs}` or `{:ok, msgs, halt_meta}` or `{:error, %EngineError{}}`.
- [ ] `stream_tool_calls/3` implementation: wraps the same execution logic but emits events. Uses `Stream.resource/3` with three-state machine (`:init` → `:emitting` → `:done`), OR `Stream.flat_map/2` over a `Task.async_stream/5` result where each task returns a list of events. Preferred: the latter, because `Task.async_stream/5` is already an enumerable, and `Stream.flat_map/2` preserves laziness.
- [ ] `execute_one_tool/3` helper: shared between the two variants. Runs executor, runs encoder (with try/rescue), routes error through `on_tool_error`, returns a tuple indicating continue/halt/ask_user + the message.
- [ ] Arity-2 handler opts construction: `[context: engine.context, session_id: nil, request_id: opts[:request_id], tool_call: tool_call, engine: engine]`.
- [ ] `lib/allm/stream_runner.ex` — rename attribute, function, log string, and moduledoc section heading per Non-obvious Decision #5. Verify no test asserts the attribute name or log content (they assert behaviour).
- [ ] `test/allm/tool_runner_test.exs` — all tests above.
- [ ] `@spec` on every public function.
- [ ] Doctest on `ALLM.ToolRunner.run_tool_calls/3` and `ALLM.ToolRunner.stream_tool_calls/3` using the single-tool-call scenario.

#### 6.1.3 Verification

```bash
mix test test/allm/tool_runner_test.exs
mix test test/allm/stream_runner_test.exs    # regression — rename doesn't break behaviour
mix test --cover                              # ≥90% on lib/allm/tool_runner.ex
mix dialyzer
mix credo --strict lib/allm/tool_runner.ex lib/allm/stream_runner.ex
mix format --check-formatted
```

### Sub-phase 6.2: `ALLM.Chat.step/3` + `ALLM.Chat.stream_step/3` (Layer C)

**Goal:** Orchestrate one adapter call + tool execution. Compose the streaming variant via the three-phase `Stream.resource/3` state machine per Non-obvious Decision #1. Honour `mode: :auto | :manual`. Augment the assistant message with `tool_calls` in metadata.

**Spec sections:** §3, §10.3, §10.4, §12, §12.3 (partial), §17, §30 (partial).

#### 6.2.1 Test Plan (write first)

`test/allm/chat_step_test.exs` (NEW):

**Happy path — no tool call:**
- Fake script `[{:text, "Hello"}, {:finish, :stop}]`; `Chat.step(engine, [ALLM.user("hi")])` → `{:ok, %StepResult{thread: [user_msg, assistant_msg], response: %Response{output_text: "Hello", finish_reason: :stop}, tool_results: [], done?: true}}`.
- Assistant message has `content: "Hello"`, `metadata.finish_reason: :stop`, no `metadata.tool_calls`.

**Happy path — single tool call (mode: :auto):**
- Fake script `[{:tool_call, id: "c0", name: "echo", arguments: %{x: 1}}, {:finish, :tool_calls}]`; engine has `echo` tool.
- `Chat.step(engine, [user_msg])` → `{:ok, %StepResult{done?: false, tool_results: [tool_msg], ...}}`.
- Thread has: `[user_msg, assistant_msg_with_tool_calls_metadata, tool_msg]`.
- Assistant message has `metadata.tool_calls: [%ToolCall{id: "c0", name: "echo", arguments: %{x: 1}}]`.
- Tool message has `role: :tool, tool_call_id: "c0", content: ~s({"x":1})` (JSON-encoded since handler returns `{:ok, args}`).

**Happy path — parallel tool calls (mode: :auto):**
- Fake script `[{:tool_call, id: "c0", name: "a", arguments: %{}}, {:tool_call, id: "c1", name: "b", arguments: %{}}, {:finish, :tool_calls}]`.
- `Chat.step(...)` → `{:ok, %StepResult{done?: false, tool_results: [msg_c0, msg_c1], ...}}`.
- `StepResult.tool_results` is in `tool_call_id` order (c0, c1) regardless of execution order (Phase 6 sorts before returning).

**mode: :manual:**
- Same script as single-tool-call; `Chat.step(..., mode: :manual)` → `{:ok, %StepResult{done?: false, tool_results: [], response: %Response{tool_calls: [%ToolCall{id: "c0"}]}, metadata: %{mode: :manual}}}`. Assert `metadata[:halted_reason]` is NOT set — `mode: :manual` is NOT a halt (Finding F2).
- No handler invocation (handler should NOT be called; assert via `Process.put/2` sentinel).

**on_tool_error: :halt:**
- Handler `fn _ -> {:error, :bad} end`; `Chat.step(..., on_tool_error: :halt)` → `{:ok, %StepResult{done?: true, tool_results: [error_msg], metadata: %{halted_reason: :tool_error}}}`.

**on_tool_error: :continue (default):**
- Same handler; `Chat.step(...)` → `{:ok, %StepResult{done?: false, tool_results: [error_msg], metadata: %{}}}`.

**Handler `{:halt, reason, result}`:**
- Handler `fn _ -> {:halt, :budget_exceeded, %{used: 100}} end`; `Chat.step(...)` → `{:ok, %StepResult{done?: true, tool_results: [msg_with_encoded_result], metadata: %{halted_reason: :budget_exceeded, halt_tool_call_id: "c0", halt_result: %{used: 100}}}}`.

**Handler `{:ask_user, question}`:**
- Handler `fn _ -> {:ask_user, "which?"} end`; `Chat.step(...)` → `{:ok, %StepResult{done?: true, tool_results: [msg_with_awaiting_response], metadata: %{halted_reason: :ask_user, pending_question: "which?", pending_tool_call_id: "c0", ask_user_opts: []}}}`.
- **Thread does NOT have a trailing `:assistant` message with `metadata.ask_user: true`** (Non-obvious Decision #6). Assert on `StepResult.thread`'s message roles.

**Unknown tool:**
- Adapter returns tool_call `%{name: "unknown"}`; engine has no `unknown` tool registered.
- `Chat.step(...)` → `{:error, %EngineError{reason: :unknown_tool, cause: "unknown"}}`.

**Pre-flight errors:**
- `engine.adapter == nil` → `{:error, %EngineError{reason: :missing_adapter}}`. Inherited from Phase 5.
- `ALLM.Validate.thread/1` failure → `{:error, %ValidationError{}}`. New Phase 6 — thread is validated at step/3 entry.
- `thread_or_messages` as list of messages: normalized to `%Thread{}` via `ALLM.Thread.from_messages/1`.

**Assistant message augmentation:**
- After a tool-call step, the assistant message in `StepResult.thread` has `metadata.tool_calls` as a `[%ToolCall{}]` list. Assert struct type.
- Round-trip: `:erlang.term_to_binary(step_result.thread) |> :erlang.binary_to_term()` preserves tool_calls on the assistant message.

`test/allm/chat_stream_step_test.exs` (NEW):

**Event ordering:**
- Single-tool-call fixture; `Chat.stream_step(...)` → `Enum.to_list(stream)` contains: `[:message_started, :text_delta*, :text_completed?, :tool_call_started, :tool_call_delta*, :tool_call_completed, :message_completed, :tool_execution_started, :tool_execution_completed, :tool_result_encoded, :step_completed]`. The first 7 are adapter events (pass-through), the next 3 are orchestration, the last is terminal.
- All adapter events precede all tool-execution events.
- Exactly one `:step_completed` at the end.

**Parallel tool execution event interleaving:**
- Two-tool-call fixture; assert 2 × `:tool_execution_started`, 2 × `:tool_execution_completed`, 2 × `:tool_result_encoded`, 1 × `:step_completed`. Per-id ordering holds (started → completed → encoded for each id).

**`:step_completed` payload:**
- `%{response: %Response{}, thread: %Thread{}}`; thread contains all assistant and tool-role messages.

**`:tool_halt` emission:**
- Handler returns `{:halt, :x, %{a: 1}}`; stream emits `:tool_halt, %{tool_call_id, reason: :x, result: %{a: 1}}`. Followed by `:step_completed`.

**`:ask_user_requested` emission:**
- Handler returns `{:ask_user, "q?"}`; stream emits `:ask_user_requested, %{tool_call_id, tool_name, question: "q?", opts: []}`. Followed by `:step_completed`.

**Consumer halt propagation:**
- 10-event adapter script + 2 tool calls; `Enum.take(stream, 2)` (halts during adapter phase) → Fake's `:counters` observer increments within 500 ms (inherited Phase 5 contract).
- `Enum.take(stream, 8)` (halts during tool-execution phase) → tool-execution tasks still running have their `Task` processes cleaned up by the `Stream.resource/3` after_fun (verify via process count or linked-process exit).

**mode: :manual (streaming):**
- Stream contains adapter events + `:step_completed` (no tool-execution events). `:step_completed.thread` has assistant message with `tool_calls` metadata but no tool-role messages.

**on_event observer:**
- `on_event: fn e -> send(self(), e) end`; assert every event (including `:tool_execution_*`, `:step_completed`) reaches the mailbox.

#### 6.2.2 Implementation Checklist

- [ ] `lib/allm/chat.ex` — new module with `step/3` and `stream_step/3`.
- [ ] `step/3`: normalise thread (from `[Message]` to `%Thread{}` if needed) → `ALLM.Validate.thread/1` → build `%Request{messages: thread.messages, tools: resolve_tools(engine, opts), ...}` → `ALLM.Runner.run/3` → branch on `mode`:
  - `:manual` + `finish_reason == :tool_calls` → build StepResult with tool_calls in response, `tool_results: []`, `metadata.mode: :manual` (no `:halted_reason`).
  - `:auto` + `finish_reason == :tool_calls` → `ToolRunner.run_tool_calls(response.tool_calls, tools, opts)` → append messages → build StepResult.
  - Otherwise → StepResult with `done?: true`, `tool_results: []`.
- [ ] Assistant message augmentation: `Message.update_metadata(response.message, :tool_calls, response.tool_calls)` when tool_calls non-empty.
- [ ] `stream_step/3`: build adapter stream via `ALLM.StreamRunner.run/3` → `Stream.resource/3` with three-phase state machine (adapter → tool_execution → step_completed). Each phase pulls events and emits them; transitions are explicit.
- [ ] The adapter phase uses `Stream.transform/3` to fold events into a `%StreamCollector{}` while passing them through.
- [ ] The tool-execution phase drives `ALLM.ToolRunner.stream_tool_calls/3` as a lazy child stream inside `Stream.flat_map/2`.
- [ ] The step_completed phase emits one event (single-element list).
- [ ] After_fun for the outer `Stream.resource/3`: signal halt to any active `Task.async_stream/5` (drops the reference; remaining not-yet-started tasks cancel).
- [ ] `@spec`s, `@doc`s (with doctests using Fake + single-tool-call fixture).
- [ ] `lib/allm/stream_collector.ex` — add `:tool_result_encoded` fold clause (immediately before catch-all); add `:tool_results` field to struct; amend `to_step_result/1` to read from the field.
- [ ] `test/allm/stream_collector_test.exs` — tests for the three new fold clauses (`:tool_result_encoded`, `:tool_halt`, `:ask_user_requested`); `to_step_result/1` with `:tool_results` populated; `done?: true` after a halt event; `metadata` merge for halt and ask-user cases; first-halt-wins invariant.
- [ ] `test/allm/chat_step_test.exs`, `test/allm/chat_stream_step_test.exs` — full coverage per 6.2.1.

#### 6.2.3 Verification

```bash
mix test test/allm/chat_step_test.exs
mix test test/allm/chat_stream_step_test.exs
mix test test/allm/stream_collector_test.exs  # regression + new fold
mix test --cover                              # ≥90% on lib/allm/chat.ex
mix dialyzer
mix credo --strict lib/allm/chat.ex lib/allm/stream_collector.ex
mix format --check-formatted
```

### Sub-phase 6.3: `ALLM.step/3` + `ALLM.stream_step/3` (Layer C — public facade)

**Goal:** Ship the public facade. Thin delegations to `ALLM.Chat`. Doctests using Fake.

**Spec sections:** §4, §10.3, §10.4.

#### 6.3.1 Test Plan (write first)

`test/allm/allm_step_test.exs` (NEW):

- `ALLM.step(engine, thread)` with a Fake single-tool-call engine → `{:ok, %StepResult{}}` matching `Chat.step/3`'s output. Assert delegation via module identity.
- `ALLM.step(engine, [ALLM.user("hi")])` accepts list-of-messages form.
- Error paths: missing adapter → `%EngineError{reason: :missing_adapter}`.
- Doctest using `ALLM.Providers.Fake` + `ALLM.Test.FakeFixtures.single_tool_call/2` + inline tool with simple handler.

`test/allm/allm_stream_step_test.exs` (NEW):

- `ALLM.stream_step(engine, thread)` → `{:ok, stream}`; `Enum.to_list/1` matches `Chat.stream_step/3`'s output.
- Doctest using Fake + single-tool-call.

#### 6.3.2 Implementation Checklist

- [ ] `lib/allm.ex` — add `step/3` and `stream_step/3` as one-line delegations to `ALLM.Chat`.
- [ ] `@spec` matching the Behaviour & Type Contracts section.
- [ ] `@doc` with runnable doctests.
- [ ] `test/allm/allm_step_test.exs` and `test/allm/allm_stream_step_test.exs` — facade-level tests.

#### 6.3.3 Verification

```bash
mix test test/allm/allm_step_test.exs
mix test test/allm/allm_stream_step_test.exs
mix test --cover                              # ≥90% on new lines in lib/allm.ex
mix dialyzer
mix credo --strict lib/allm.ex
mix format --check-formatted
```

### Sub-phase 6.4: Step-equivalence property + §31 scenario activation (Layer C — tests only)

**Goal:** Prove the step-equivalence invariant and activate three §31 scenarios.

**Spec sections:** §3, §31.

#### 6.4.1 Test Plan (write first)

`test/allm/step_equivalence_test.exs` (NEW):

Property (`StreamData`):

- `script_of_step_shape` generator yields any tool-call-bearing script drawn from `{:text, "X"}`, `{:tool_call, id: "id_N", name: "tool_N", arguments: %{"k" => "v"}}`, `{:tool_call_delta, id: "id_N", arguments_delta: "..."}`, `{:usage, %{input_tokens: 1, output_tokens: 1}}`, terminated by `{:finish, :tool_calls}` or `{:finish, :stop}`. The generator ensures all tool-call ids have matching registered tools (generated in lockstep).
- For every generated script, assert:
  ```elixir
  {:ok, step_resp} = ALLM.step(engine_of(script), thread_fixture(), mode: :auto)
  {:ok, stream} = ALLM.stream_step(engine_of(script), thread_fixture(), mode: :auto)
  collected_step =
    stream
    |> Enum.reduce(ALLM.StreamCollector.new(%Thread{messages: thread_fixture()}),
                   &ALLM.StreamCollector.apply_event(&2, &1))
    |> ALLM.StreamCollector.to_step_result()
  assert_equivalent_step_result(step_resp, collected_step)
  ```
  `assert_equivalent_step_result/2` sorts `tool_results` by `tool_call_id` before comparison (Non-obvious Decision #9).
- 100 iterations default; `@tag :property`.

**Mid-execution handler failure property:**
- Scripts where one tool handler raises; assert both paths produce identical `%StepResult{done?: false, tool_results: [error_msg]}` (with `on_tool_error: :continue`).

`test/allm/providers/fake_scenarios_test.exs` (MODIFY — flip 3 pending → active):

- **single tool call with `mode: :auto`:** Fake script + engine with echo tool; call `ALLM.step/3`; assert tool_results has one message; assert `StepResult.done? == false`.
- **parallel tool calls:** Fake script with two tool_call entries; engine has both tools; assert tool_results has two messages (order-independent).
- **tool handler raises — on_tool_error policy fires:** Handler raises; `ALLM.step(..., on_tool_error: :continue)` → `{:ok, %StepResult{tool_results: [error_msg]}}`; `ALLM.step(..., on_tool_error: :halt)` → `{:ok, %StepResult{done?: true, metadata: %{halted_reason: :tool_error}}}`. The full function-form coverage stays `@tag :pending` for Phase 7 (comment inline explaining).

`test/support/assertions.ex` (NEW or MODIFY):

```elixir
defmodule ALLM.Test.Assertions do
  import ExUnit.Assertions

  def assert_equivalent_step_result(%ALLM.StepResult{} = a, %ALLM.StepResult{} = b) do
    sort_by_id = fn msgs -> Enum.sort_by(msgs, & &1.tool_call_id) end
    assert sort_by_id.(a.tool_results) == sort_by_id.(b.tool_results)
    assert a.response == b.response
    assert a.done? == b.done?
    assert a.thread.messages |> Enum.reject(& &1.role == :tool) ==
             b.thread.messages |> Enum.reject(& &1.role == :tool)
    # Tool-role messages compared after sorting:
    assert a.thread.messages |> Enum.filter(& &1.role == :tool) |> sort_by_id.() ==
             b.thread.messages |> Enum.filter(& &1.role == :tool) |> sort_by_id.()
    assert a.metadata == b.metadata
    :ok
  end
end
```

#### 6.4.2 Implementation Checklist

- [ ] `test/allm/step_equivalence_test.exs` — property + assertion helper wiring.
- [ ] `test/support/assertions.ex` — new module (or extend existing) with `assert_equivalent_step_result/2`.
- [ ] `test/allm/providers/fake_scenarios_test.exs` — remove `@tag :pending` from three scenarios; implement their bodies; update comment block marking active/pending split.
- [ ] Run `mix test --only spec_31` → 6 passing (3 Phase 4 + 3 Phase 5) + 3 new Phase 6 = 9 − 1 (session stays pending) = 8 passing; 1 (session round-trip) remains pending for Phase 8. Wait — Phase 4 activated "pure text streaming without filter", Phase 5 activated "pure text with `emit_text_deltas: false`", "mid-stream error", and "consumer cancellation". Phase 6 activates "single tool call auto", "parallel tool calls", "tool handler raises". That's 3 (Phase 4) + 3 (Phase 5) + 3 (Phase 6) = 9, but §31 lists 9 scenarios total. The remaining `@tag :pending` for Phase 7 is "max_turns" and "halt_when"; for Phase 7 is "single tool call manual"; for Phase 8 is "session round-trip". So after Phase 6: 6 active, 3 still pending (max_turns, halt_when, single-tool-call-manual, session round-trip — actually that's 4, so 5 active after Phase 6, 4 still pending). Let me re-count against the §31 list at `allm_engine_session_streaming_spec_v0_2.md:1651-1663`:
  - pure text streaming (with + without filter) — 2 scenarios (Phases 4+5)
  - single tool call `:auto` — Phase 6
  - single tool call `:manual` — Phase 7
  - parallel tool calls — Phase 6
  - `max_turns` cap — Phase 7
  - `halt_when` returns true — Phase 7
  - tool handler raises — Phase 6 (partial; function form Phase 7)
  - mid-stream adapter error — Phase 5
  - consumer cancellation — Phase 5
  - session round-trip — Phase 8

  That's 10 bullets but 9 scenarios by the spec heading. The "pure text" bullet is one scenario with two sub-bullets. After Phase 6: Phase 4 (1) + Phase 5 (3: filter variant, mid-stream error, cancellation) + Phase 6 (3: single auto, parallel, handler raises) = 7 active; 3 pending (`:manual`, `max_turns`, `halt_when`, session) — 4. Hmm, doesn't add to 9. The Phase 5 design says "6 active Phase 4+5". Phase 4 activates 3 (via its `fake_scenarios_test.exs`), Phase 5 activates 3 more (6 total). Phase 6 activates 3 more (9 total). Phase 7/8 activate the rest? No — there are `@tag :pending` for 4 scenarios after Phase 5. Phase 6 activates 3, leaving 1 (session). Wait, the codebase survey says 4 pending scenarios remain at the end of Phase 5 (one is session, three are Phase 7 — max_turns, halt_when, handler raises full function form). So Phase 6 activates "tool handler raises" (partial — continue/halt atom forms), and either leaves the function-form sub-scenario pending or folds it in.

  Decision: Phase 6 activates the three scenario-level items (single auto, parallel, handler raises). The function form of `on_tool_error` within the "handler raises" scenario is commented inline as "function form deferred to Phase 7" but the scenario is marked active (the atom-form cases exercise the scenario's spirit). Phase 7 adds a new test for the function form rather than flipping an existing `@tag :pending`.
- [ ] Final `CHANGELOG.md` rollup: one line per new public symbol (`ALLM.ToolRunner`, `ALLM.Chat`, `ALLM.step/3`, `ALLM.stream_step/3`, `ALLM.Message.tool_result/2`, `ALLM.Message.update_metadata/3`) + one line for the `StreamCollector.:tool_results` field + one line for the `@phase_7_opts` rename + one line per §31 scenario activated.

#### 6.4.3 Verification

```bash
mix test test/allm/step_equivalence_test.exs
mix test --only spec_31                        # 8-9 active, 1-2 pending
mix test                                       # full suite green
mix test --cover                               # ≥90% on every new file, ≥80% global
mix credo --strict
mix dialyzer
mix format --check-formatted
mix hex.build                                  # main package still clean
```

## Test Plan (cross-phase)

**Unit tests.** Every public function on `ALLM.ToolRunner`, `ALLM.Chat`, `ALLM.Message` (new helpers), `ALLM.StreamCollector` (regression), and the two facade additions has happy-path + error-path coverage. `ToolRunner.run_tool_calls/3` exercises all five handler return shapes + tool-timeout + encoder-failure + unknown-tool. `Chat.step/3` exercises `mode: :auto | :manual` + `on_tool_error: :continue | :halt` + all three handler halt shapes (`:halt`, `:ask_user`, normal `:error`).

**Behaviour conformance tests.** No new behaviours in Phase 6. The existing Phase 3 conformance suites still pass unchanged (Phase 6 doesn't touch `ALLM.Adapter` / `ALLM.StreamAdapter` / `ALLM.ToolExecutor` / `ALLM.ToolResultEncoder`).

**Integration tests.** Three `@tag :pending` scenario tests flipped to active — these exercise the full adapter → ToolRunner → Chat pipeline end-to-end.

**Property tests.** Step-equivalence property (`step_equivalence_test.exs`) is the load-bearing correctness test. 100 iterations default. Uses `Task.async/1` or an Agent-backed script cursor to isolate parallel iterations (inherited from Phase 5's pattern).

**Doctests.** `ALLM.step/3`, `ALLM.stream_step/3`, `ALLM.Chat.step/3`, `ALLM.Chat.stream_step/3`, `ALLM.ToolRunner.run_tool_calls/3`, `ALLM.ToolRunner.stream_tool_calls/3`, `ALLM.Message.tool_result/2`, `ALLM.Message.update_metadata/3` each carry one runnable doctest using `ALLM.Providers.Fake`.

**Serializability tests.** The `StepResult.thread` returned from `step/3` round-trips through `:erlang.term_to_binary/1` including the assistant message's `metadata.tool_calls` list of `%ToolCall{}` structs. Assertion lives in `chat_step_test.exs`; no new property test is added (the existing Phase 1 Layer A serialisability harness covers Message/ToolCall structs independently).

**Stream-equivalence tests.** `step ≡ stream_step |> collect_step_result` is the Phase 6 contract. Covered by `step_equivalence_test.exs`. The assertion helper `assert_equivalent_step_result/2` sorts `tool_results` by `tool_call_id` to normalize parallel-execution ordering.

**Coverage threshold.** `mix.exs` 80 % global; Phase 6 targets ≥ 90 % on `lib/allm/tool_runner.ex`, `lib/allm/chat.ex`, and the new lines in `lib/allm/stream_collector.ex`, `lib/allm/message.ex`, `lib/allm.ex`. Branch coverage on `ToolRunner.execute_one_tool/3`'s handler-return dispatch is the key risk — each of the five legal return shapes needs a test case.

## Error Contract

| Function | Error reason | Recovery guidance |
|----------|--------------|--------------------|
| `ALLM.step/3`, `ALLM.stream_step/3` | `%EngineError{reason: :missing_adapter}` | Inherited from Phase 5. Construct engine with `:adapter`. |
| `ALLM.step/3`, `ALLM.stream_step/3` | `%EngineError{reason: :missing_stream_adapter}` | Inherited from Phase 5. Use a stream-capable adapter. |
| `ALLM.step/3`, `ALLM.stream_step/3` | `%EngineError{reason: :unknown_tool, cause: name}` | Adapter returned a tool_call with a name not registered on the engine. Register the tool or narrow the adapter's tool_choice. |
| `ALLM.step/3`, `ALLM.stream_step/3` | `%ValidationError{reason: :invalid_request}` | Inherited from Phase 5. Fix the thread / request shape. |
| `ALLM.step/3`, `ALLM.stream_step/3` | `%ValidationError{reason: :invalid_thread}` | Phase 6 — thread validation failure (e.g., tool message without tool_call_id). Fix the thread. |
| `ALLM.step/3`, `ALLM.stream_step/3` | `%AdapterError{reason: _}` (synchronous pre-flight) | Inherited from Phase 5. Adapter-side pre-flight error. |
| `ALLM.stream_step/3` stream event | `{:tool_execution_completed, %{result: {:error, %ToolError{reason: :handler_raised}}}}` | Handler raised. With `on_tool_error: :continue`, error encoded as tool-result content. With `:halt`, step halts with `%StepResult{done?: true, metadata: %{halted_reason: :tool_error}}`. |
| `ALLM.stream_step/3` stream event | `{:tool_execution_completed, %{result: {:error, %ToolError{reason: :handler_exit}}}}` | Handler process exited. Same policy routing. |
| `ALLM.stream_step/3` stream event | `{:tool_execution_completed, %{result: {:error, %ToolError{reason: :timeout}}}}` | Handler exceeded `tool_timeout`. Same policy routing. |
| `ALLM.stream_step/3` stream event | `{:tool_execution_completed, %{result: {:error, %ToolError{reason: :invalid_return}}}}` | Handler returned a value outside the five legal shapes. Same policy routing; typically points to a handler code bug. |
| `ALLM.stream_step/3` stream event | `{:tool_execution_completed, %{result: {:error, %ToolError{reason: :encoding_failed, cause: exception}}}}` | Encoder raised. Same policy routing; `inspect/1` of the exception is used as the encoded tool-result content. |
| `ALLM.ToolRunner.run_tool_calls/3` | `{:error, %EngineError{reason: :unknown_tool}}` | Batch-level failure; no tools executed. |
| `ALLM.ToolRunner.run_tool_calls/3` | `ArgumentError` (`:on_tool_error_function_form_not_implemented`) | Phase 6 rejects function form; use atom or wait for Phase 7. |

**Field-error atom vocabulary.** Not applicable — Phase 6 adds no validator-shaped module.

**Hard-reject semantics.** Not applicable — Phase 6 adds no validator.

**No new atoms introduced.** Phase 6 reuses existing closed enums:
- `ALLM.Error.EngineError.@legal_reasons` — `:unknown_tool` (committed at `lib/allm/error/engine_error.ex:30-38`).
- `ALLM.Error.ToolError.@legal_reasons` — all seven atoms (committed at `lib/allm/error/tool_error.ex:34-41`), verified on 2026-04-24.
- `ALLM.Error.AdapterError.@legal_reasons`, `ALLM.Error.ValidationError` reasons — unchanged from Phase 5.

**Halt-reason atoms (on `StepResult.metadata.halted_reason`).** Phase 6 uses:
- `:tool_error` — spec §5.2 reserved; used for `on_tool_error: :halt` triggers.
- `:ask_user` — spec §5.2 reserved; used for `{:ask_user, _}` handler returns.
- User-supplied atoms from `{:halt, reason, _}` handler returns.

**`mode: :manual` is NOT a halt** (Finding F2). The spec §12.3 and §5.2 distinguish between a halt (loop terminated because of a tool signal) and a mode (caller opted for manual execution). Conflating them would pollute the `halted_reason` vocabulary with a non-halt atom and muddle Phase 7's `ChatResult.halted_reason` type (spec §5.9's closed union). Phase 6 instead puts `StepResult.metadata.mode: :manual` when `mode: :manual` returns unexecuted tool calls, and does NOT set `:halted_reason`. `StepResult.done?` is `false` — the semantic signal is "more work expected, manual submission required", not "the loop halted".

This aligns with `PROJECT_PHASING.md` line 129's phrasing (`%ALLM.ChatResult{halted_reason: :manual_tool_calls}` appears in the Phase 7 text, not Phase 6). Phase 7 will introduce `:manual_tool_calls` as a halt reason when `chat/3` encounters a manual-mode step mid-loop; Phase 6 does NOT write this atom anywhere — it's strictly Phase 7's vocabulary to introduce, and will require a scoped amendment to spec §5.9's `ChatResult.halted_reason` closed union at that time.

## Streaming & Backpressure

- **Cleanup is mandatory and inherited from the adapter (for Phase A of stream_step's pipeline).** Fake's `Stream.resource/3` owns Phase A cleanup. Phase 6's outer `Stream.resource/3` owns Phase B cleanup (tool-execution tasks). The two cleanup hooks fire in different phases of the composed stream; they do not overlap. Tests assert both (a) consumer halt during Phase A fires Fake's observer within 500 ms, and (b) consumer halt during Phase B terminates in-flight `Task.async_stream/5` tasks within 500 ms.
- **Backpressure model.** Inherited from Phase 5 (no buffering, no demand signalling). `Task.async_stream/5`'s internal fairness governs tool-execution parallelism; consumer reduce rate is the only external signal.
- **Cancellation.** Phase 6 extends Phase 5's cancellation contract to cover the tool-execution phase. `Enum.take/2` during Phase B halts in-flight tasks via the outer `Stream.resource/3`'s `after_fun`, which calls the `Task.async_stream/5` enumerable's halt protocol. Consumer process exit with a trappable reason propagates similarly. `Process.exit(consumer, :kill)` during Phase B does NOT fire cleanup (same inherited OTP limitation as Phase 4/5 — not tested).

Phase 6 does not introduce a new producer process. The outer `Stream.resource/3` is a state-machine wrapper, not a producer; it consumes events from the adapter stream and the tool-execution stream lazily.

## Definition of Done

- [ ] All four sub-phases marked `Completed` in the status table.
- [ ] `mix test` passes with zero failures, zero `unused_var` warnings; coverage ≥ 80 % globally and ≥ 90 % on `lib/allm/tool_runner.ex`, `lib/allm/chat.ex`, and the new lines in `lib/allm/stream_collector.ex`, `lib/allm/message.ex`, `lib/allm.ex`.
- [ ] `mix credo --strict` passes on changed files.
- [ ] `mix dialyzer` passes against the prior PLT with zero new warnings.
- [ ] `mix format --check-formatted` passes.
- [ ] Every new public function has an `@spec` and a non-empty `@doc`.
- [ ] Doctests run under `mix test`: `ALLM.step/3`, `ALLM.stream_step/3`, `ALLM.Chat.step/3`, `ALLM.Chat.stream_step/3`, `ALLM.ToolRunner.run_tool_calls/3`, `ALLM.ToolRunner.stream_tool_calls/3`.
- [ ] The Phase 3 conformance suites (`use ALLM.Test.AdapterConformance`, `use ALLM.Test.StreamAdapterConformance`) still pass unchanged against `ALLM.Providers.Fake` (regression — Phase 6 does not touch adapter behaviours).
- [ ] Step-equivalence property passes 100 random fixtures in `step_equivalence_test.exs`.
- [ ] Halt-safety regression tests pass within 500 ms for both Phase A (adapter-stream) and Phase B (tool-execution) halts.
- [ ] `mix test --only spec_31` reports 8-9 active scenarios, 1-2 remaining `@tag :pending` for Phase 7/8.
- [ ] `CHANGELOG.md` has one entry per new public symbol (four: `ALLM.ToolRunner`, `ALLM.Chat`, `ALLM.step/3`, `ALLM.stream_step/3`), one for the `StreamCollector` struct extensions (`:tool_results` + `:halt` fields, new fold clauses), one for the `StreamRunner` attribute/function rename, and one per §31 scenario activated.
- [ ] `mix hex.build` succeeds; main package includes the two new `lib/` files (`tool_runner.ex`, `chat.ex`).
- [ ] Commit messages reference §3, §4, §5.2, §5.8, §7.3, §7.4, §10.3, §10.4, §12, §12.3, §17, §19, §30, §31 as appropriate.
- [ ] Reviewed via `/review` per `agent-spec/REVIEW.md`.
