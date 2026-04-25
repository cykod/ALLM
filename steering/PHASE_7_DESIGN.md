# Phase 7: `stream/3` + `chat/3` — Full Orchestration Loop — Design Document

> **Goal:** Ship the first Layer C surface that orchestrates the full multi-turn loop: `ALLM.chat/3` repeatedly runs `step/3`, appends results to the thread, and continues until a terminal condition fires (adapter `finish_reason ∈ {:stop, :length, :content_filter, :error}`, `max_turns` exhausted, `halt_when/1` returns `true`, a handler returns `{:halt, _, _}` or `{:ask_user, _}` / `{:ask_user, _, _}`, `on_tool_error: :halt` fires, or `mode: :manual` surfaces tool calls). `ALLM.stream/3` emits every event across every turn plus a terminal `:chat_completed` event carrying the final `%ALLM.ChatResult{}`.
> **Outcome:** Calling `ALLM.chat(engine, thread)` against a Fake engine whose scripts model an N-turn transcript runs N `step/3` cycles — adapter → (tool calls → tool execution → tool-role messages appended) → assistant message appended — and returns `{:ok, %ChatResult{thread: final_thread, steps: [%StepResult{}, …], final_response: last_response, halted_reason: :completed | :max_turns | :halt_when | :ask_user | :tool_error | :manual_tool_calls | atom()}}`. `ALLM.stream/3` emits every Phase-5 and Phase-6 event across every turn, followed by exactly one terminal `:chat_completed` event. A chat-equivalence property asserts `chat/3 ≡ stream/3 |> collect_chat_result` across every multi-turn Fake fixture. `mix test`, `mix credo --strict`, `mix dialyzer`, `mix format --check-formatted` all green; coverage ≥ 90 % on every new file.
> **Spec sections:** §3 (stream-first), §4 (facade), §5.2 (handler return shapes + reserved halt reasons), §5.9 (ChatResult shape + `halted_reason`), §8 (Event protocol — `:chat_completed` fold clause added; no new variants), §10.5 (`chat/3`), §10.6 (`stream/3`), §12 (`:auto` / `:manual` modes), §12.3 (ask-user — full thread mutation at turn boundary), §17 (`ALLM.Chat.run/3`, `ALLM.Chat.stream/3`), §19 (streaming options — `:max_turns`, `:halt_when` newly consumed), §20 (error reasons — reuses prior phases', no additions), §30 (tool error policy — function form; handler-requested halt), §31 (three property scenarios activated: `max_turns`, `halt_when`, manual-mode full flow).
> **Layers touched:** C (stateless execution). No Layer A changes. No behaviour changes. No new variants added to `ALLM.Event`'s closed union (the `:chat_completed` tag was declared in Phase 1 per spec §8 and currently falls through `StreamCollector`'s catch-all; Phase 7 adds a per-tag fold clause and emits the event from `ALLM.Chat.stream/3`). Per `AGENT_DESIGN_SPEC.md`'s "Adding a new variant to a closed tagged-tuple union is a breaking change for every reducer" rule, this phase does **not** trigger that rule.
> **Phasing doc:** [`PROJECT_PHASING.md`](PROJECT_PHASING.md) Phase 7.

## Status

| Sub-phase | Description | Layer | Status |
|-----------|-------------|-------|--------|
| 7.1 | `StreamCollector` extension — `:step_completed` fold; expanded `:halt` channel; `to_chat_result/1` full Phase-7 semantics | C | DONE |
| 7.2 | `ALLM.ToolRunner` extension — `on_tool_error` function form; expose it on the Phase-6 dispatch path | C | DONE |
| 7.3 | `ALLM.Chat.run/3` — multi-turn loop with `max_turns`, `halt_when`, ask-user thread mutation, manual-mode halt | C | DONE |
| 7.4 | `ALLM.Chat.stream/3` — streaming multi-turn orchestrator, terminal `:chat_completed` event | C | DONE |
| 7.5 | `ALLM.chat/3` + `ALLM.stream/3` facade + doctests + chat-equivalence property + §31 scenario activations | C | DONE |

**Overall Progress:** 5/5 sub-phases complete

## Overview

Phase 7 is the first phase that ships a multi-turn loop: the adapter produces tool calls, ALLM executes them, the thread grows with the assistant message plus `:tool`-role messages, and then ALLM calls the adapter **again** with the updated thread until the model signals completion or an orchestration gate fires. Everything below the orchestrator is already committed — Phase 6 ships `ALLM.step/3` / `ALLM.stream_step/3` (`lib/allm/chat.ex:177-258`), `ALLM.ToolRunner.run_tool_calls/3` / `stream_tool_calls/3` (`lib/allm/tool_runner.ex`), and `ALLM.StreamCollector` with Phase-6 fold clauses for the per-step halt channel (`lib/allm/stream_collector.ex:119-307`). Phase 7 composes those primitives into the multi-turn surface without changing their behaviour.

The phase's load-bearing correctness property is **chat-equivalence** (spec §3's first consequence made testable at the chat layer): for every scripted Fake fixture with a multi-turn shape, `ALLM.chat/3` and `ALLM.stream/3 |> StreamCollector.to_chat_result/1` produce identical `%ChatResult{}` values. That invariant mirrors Phase 5's `generate ≡ stream_generate |> collect` and Phase 6's `step ≡ stream_step |> collect_step`, and it is the final link in the stream-first chain. Both `chat/3` and the `:chat_completed` event's payload are constructed by the *same* function (`ALLM.Chat.build_chat_result/1` — see Non-obvious Decision #4), so equivalence is established by construction: the non-streaming path calls `build_chat_result/1` directly; the streaming path emits `{:chat_completed, %{result: build_chat_result(state)}}` and the collector's fold clause stores the payload's `result` verbatim. `to_chat_result/1` then returns the stored value when present. The property test asserts struct equality modulo the same `tool_call_id`-sort on `:tool`-role messages that Phase 6 already established (`test/support/assertions.ex` — `assert_equivalent_step_result/2`) plus an `assert_equivalent_chat_result/2` extension that sorts each step's `tool_results` the same way and compares `steps` list-by-list.

The phase's second critical obligation is **multi-turn composition without re-implementing step orchestration**. `Chat.run/3` composes `Chat.step/3` calls in a loop; `Chat.stream/3` composes `Chat.stream_step/3` streams sequentially. Phase 6 Non-obvious Decision #1 established the Elixir idiom for driving a sub-stream one event at a time via `Enumerable.reduce/3`'s continuation protocol (see `lib/allm/chat.ex:349-408`); Phase 7 reuses that exact idiom at the outer `stream/3` layer. The state machine is two phases (not three as in `stream_step/3`): **Phase S (`:step`)** — driving the current `stream_step/3` sub-stream one event at a time, folding each event into the outer `StreamCollector`, and when the sub-stream emits its terminal `:step_completed` event, deciding whether to (a) start a new step with the augmented thread, (b) transition to Phase F with a halt reason, or (c) let the loop exhaust `:max_turns` and transition to Phase F. **Phase F (`:final`)** — emitting exactly one `{:chat_completed, %{result: chat_result}}` event and halting. The outer `Stream.resource/3`'s `after_fun` halts the active Phase-S sub-stream via the same `cont.({:halt, :consumer_halt})` idiom as Phase 6; Phase F has no sub-stream. Because `stream_step/3` is itself already a `Stream.resource/3`, the chat-stream owns *one more* outer `Stream.resource/3` — not two layered cleanup hooks. This is the same "drive, don't wrap" rule from Phase 5 Non-obvious Decision #6 applied one layer up.

The phase's third design decision is the **full `on_tool_error` contract**, including the function form `(ToolCall.t(), term() -> {:continue, term()} | :halt)` that Phase 6 explicitly deferred. `ALLM.ToolRunner.run_tool_calls/3` currently raises `ArgumentError` when `on_tool_error` is a function (`lib/allm/tool_runner.ex`, verified 2026-04-24). Phase 7 loosens that guard: function form dispatches per-tool-call, the returned `{:continue, replacement_term}` is encoded as the tool-result content and the batch continues; `:halt` halts with `halted_reason: :tool_error`. The function is called synchronously inside the `Task.async_stream/5` task, so it must be purely computational (no blocking I/O that ignores `tool_timeout`). This is a loosening, not a redesign — the `Chat.step/3` error-path surfaces (`{:ok, msgs}` / `{:ok, msgs, halt_meta}`) stay unchanged.

The phase's fourth obligation is **ask-user suspension as a thread mutation at the turn boundary**, not per-step. Phase 6 Non-obvious Decision #6 explicitly deferred the assistant-message append to the multi-turn layer: "Phase 6's `Chat.step/3` emits `:ask_user_requested`, encode[s] the tool result as `"<awaiting user response>"` per spec §12.3 step 1, populates `StepResult.metadata.pending_question`, [but] does NOT append an `:assistant`-role message with `metadata: %{ask_user: true}` to the thread. That thread mutation is the multi-turn loop's concern." Phase 7 lands that append: when `Chat.run/3`'s step loop produces a `%StepResult{metadata: %{halted_reason: :ask_user, pending_question: q, pending_tool_call_id: id}}`, the orchestrator appends `%Message{role: :assistant, content: q, metadata: %{ask_user: true, tool_call_id: id}}` to the thread before returning the `ChatResult`. The returned `ChatResult.thread` is the thread the caller will continue from (by appending a `:user` message and calling `chat/3` again). This is the canonical spec §12.3 contract.

The phase's fifth obligation is **terminal-condition ordering**, which matters when two conditions fire in the same step:

1. A handler `{:ask_user, …}` wins over everything else for that step (it's a hard suspend; `halt_when` isn't consulted).
2. A handler `{:halt, reason, _}` wins next; `halt_when` isn't consulted.
3. `on_tool_error: :halt` on a handler `{:error, _}` wins next; `halt_when` isn't consulted.
4. `mode: :manual` with `finish_reason: :tool_calls` halts BEFORE the `halt_when` callback gets the step (because manual mode never executes tools in the first place, so `halt_when` on tool-result content is meaningless for this step).
5. Adapter `finish_reason: :stop | :length | :content_filter | :error` halts next (spec §5.9 maps these to `halted_reason: :completed` for `:stop`, `:error` for `:error`; `:length` and `:content_filter` map to `:completed` too, with the raw reason preserved in `final_response.finish_reason`).
6. `halt_when.(step_result)` runs LAST of the per-step gates, and only if none of the above fired.
7. `max_turns` is checked BEFORE the next adapter call, never DURING a step.

This explicit total order is the contract. The test plan exercises each pair for non-interference. See Non-obvious Decision #5.

The phase's sixth obligation is a **minimal `StreamCollector` extension** for multi-turn fold: Phase 5 left `:step_completed` and `:chat_completed` in the catch-all (Phase 5 Non-obvious Decision #12). Phase 6 added three Phase-6 orchestration clauses. Phase 7 adds two more — one for `:step_completed` (append `%StepResult{}` to the existing `:steps` field; reset the per-step halt/tool_results/current_text/current_tool_calls/tool_call_order sub-state so the next step folds cleanly) and one for `:chat_completed` (store the payload's `result` on a new `:chat_result` field). `to_chat_result/1` returns the stored `chat_result` verbatim when present, otherwise computes a ChatResult from the collector's state (the fallback path is exercised by consumers who end the stream early, e.g. `Stream.take/2` before `:chat_completed` fires). Per Phase 5 Non-obvious Decision #5, Phase 7 inserts the two new clauses **ahead** of the catch-all without modifying any prior phase's clause.

### Deliverables

- **New modules (main package):**
  - None. Phase 7 adds functions to the existing `ALLM.Chat` module (Phase 6's internal Chat runner).
- **Modified modules:**
  - `lib/allm/stream_collector.ex` — add `:chat_result` field; add two new per-tag fold clauses (`:step_completed`, `:chat_completed`) inserted immediately before the catch-all per Phase 5 Non-obvious Decision #5; extend `to_chat_result/1` to prefer the stored `:chat_result` when present and to compute a Phase-7-aware fallback when absent (handling all seven halted_reason atoms). The `:step_completed` fold reuses existing per-step fields rather than introducing a new bookkeeping field — see Non-obvious Decision #6.
  - `lib/allm/tool_runner.ex` — relax the `on_tool_error` function-form guard (today raises `ArgumentError`); implement per-tool-call dispatch; wire the function's return into the existing `:continue | :halt` routing.
  - `lib/allm/chat.ex` — add `run/3` (multi-turn non-streaming), `stream/3` (multi-turn streaming), and the `build_chat_result/1` + `terminal_condition/4` helpers used by both. Re-export `@moduledoc` headings (add "Multi-turn loop" and "Terminal-condition ordering" sections below Phase 6's existing sections).
  - `lib/allm.ex` — add `chat/3` and `stream/3` as one-line delegations to `ALLM.Chat.run/3` and `ALLM.Chat.stream/3`, matching spec §4's signatures verbatim.
- **Modified tests:**
  - `test/allm/stream_collector_test.exs` — add tests for the two new fold clauses (`:step_completed` appends step, resets sub-state; `:chat_completed` stores result), and the `to_chat_result/1` stored-vs-computed branches, and the Phase-7 halted_reason fallbacks.
  - `test/allm/tool_runner_test.exs` — add tests for the `on_tool_error` function form: `fn _, _ -> {:continue, term} end` replaces the handler's error term in the encoded tool result; `fn _, _ -> :halt end` halts the batch; the function receives `(%ToolCall{}, error_term)` per spec §30.
  - `test/allm/providers/fake_scenarios_test.exs` — flip TWO `@tag :pending` placeholders to active tests per §31: "`max_turns` cap (Phase 7)" at `:430-434` → `halted_reason: :max_turns`; "`halt_when` fires (Phase 7)" at `:437-441` → `halted_reason: :halt_when`. Additionally, ADD one new active test in the same file (no prior placeholder existed): "single tool call with `mode: :manual` — partial flow via `chat/3`" exercising `halted_reason: :manual_tool_calls`. The remaining `@tag :pending` ("session round-trip (Phase 8)" at `:444-448`) stays pending for Phase 8.
- **New tests:**
  - `test/allm/chat_run_test.exs` — `Chat.run/3` unit tests: two-turn happy path (tool_call → tool_result → stop), `max_turns` cap, `halt_when` fires mid-loop, `on_tool_error: :halt` halts at first error, `on_tool_error: fun` routes per-call, handler `{:halt, :custom, result}` surfaces as `halted_reason: :custom`, handler `{:ask_user, q}` appends question to thread, `mode: :manual` halts on first tool-call turn with `halted_reason: :manual_tool_calls`, adapter-level error mid-stream surfaces as `halted_reason: :error`, empty `halt_when` + stop in one turn → `halted_reason: :completed`.
  - `test/allm/chat_stream_test.exs` — `Chat.stream/3` unit tests: event ordering across turns (all step 1 events → all step 2 events → … → `:chat_completed`), consumer-halt propagation at step boundary, consumer-halt propagation mid-step, single terminal `:chat_completed`, ask-user flow emits `:ask_user_requested` then `:chat_completed` (no subsequent step), manual-mode emits no tool-execution events and terminates after the first step's `:step_completed`, `halt_when` firing mid-loop emits the fatal step's `:step_completed` and then `:chat_completed`.
  - `test/allm/allm_chat_test.exs` — facade `ALLM.chat/3` delegates to `Chat.run/3`; doctest using Fake multi-turn fixture.
  - `test/allm/allm_stream_test.exs` — facade `ALLM.stream/3` delegates to `Chat.stream/3`; doctest using Fake multi-turn fixture.
  - `test/allm/chat_equivalence_test.exs` — StreamData property: for every Phase 4 multi-turn fixture, `chat/3 == stream/3 |> collect_chat_result` using `assert_equivalent_chat_result/2`.
- **CHANGELOG entries:** one line per new public symbol (`ALLM.Chat.run/3`, `ALLM.Chat.stream/3`, `ALLM.chat/3`, `ALLM.stream/3`) + one line for the `StreamCollector` `:chat_result` field addition + one line for the `ToolRunner` function-form `on_tool_error` enablement + three scenario lines (two flips for `max_turns` and `halt_when`; one new active test for `mode: :manual` partial flow).
- **No changes to:** `ALLM.Engine`, `ALLM.Keys`, `ALLM.Adapter`, `ALLM.StreamAdapter` behaviours, `ALLM.ToolExecutor` behaviour, `ALLM.ToolResultEncoder` behaviour, `ALLM.ToolExecutor.Default`, `ALLM.ToolResultEncoder.JSON`, `ALLM.Providers.Fake`, `ALLM.Providers.Fake.Script`, `ALLM.Test.FakeFixtures`, the `conformance/` sub-project, `ALLM.Application`, `mix.exs`. No new dependency.

### Spec coverage

- **§3 Stream-first execution.** `chat/3` is implemented as a reducer over `stream/3`'s event stream via `ALLM.StreamCollector.to_chat_result/1`. The reducer follows the same Phase-6 pattern as `step ≡ stream_step |> collect_step`; Phase 7 adds the final link in the chain.
- **§4 Facade.** `chat/3` and `stream/3` are the final two public functions on `ALLM`, with signatures matching spec §4:
  ```elixir
  @spec chat(Engine.t(), Thread.t() | [Message.t()], keyword()) ::
          {:ok, ChatResult.t()} | {:error, EngineError.t() | AdapterError.t() | ValidationError.t()}
  @spec stream(Engine.t(), Thread.t() | [Message.t()], keyword()) ::
          {:ok, Enumerable.t()} | {:error, EngineError.t() | AdapterError.t() | ValidationError.t()}
  ```
  Per `AGENT_DESIGN_SPEC.md`, the error-branch type is narrowed from spec §4's `term()` to the three concrete error structs. No `%ToolError{}` branch — tool-execution errors fold into `ChatResult.halted_reason: :tool_error` rather than the outer tuple (see Phase 6 Invariant 1, inherited).
- **§5.2 Tool handler returns.** Phase 7 consumes all five shapes identically to Phase 6 at the per-step level, with two Phase-7-owned multi-turn effects:
  - `{:halt, reason, _}` — emits Phase-6's `:tool_halt` event at the step layer; Phase 7 surfaces `reason` as `ChatResult.halted_reason`. **Reserved reasons per spec §5.2 are REJECTED at the handler-return boundary.** When a handler returns `{:halt, reason, _}` with `reason in [:ask_user, :max_turns, :halt_when, :tool_error, :cancelled, :completed]`, Phase 7's `Chat.step/3` (actually `ToolRunner`'s per-tool dispatcher — see below) converts the return into a `{:error, %ToolError{reason: :invalid_return, metadata: %{reserved_halt_atom: reason}, message: "handler returned {:halt, :<reason>, _}; :<reason> is reserved by spec §5.2 — use a custom atom like :plan_submitted"}}` outcome, which then flows through the normal `on_tool_error` policy (`:continue` encodes the error as tool-result content; `:halt` halts with `halted_reason: :tool_error`). This preserves spec §5.2's "do not reuse" invariant without extending Phase 1's closed `%ToolError{}` `:reason` enum — `:invalid_return` is the natural fit (`lib/allm/error/tool_error.ex:34-41`, verified 2026-04-24). **Implementation site:** `ToolRunner`'s per-tool dispatcher (`execute_one_tool/3` in `lib/allm/tool_runner.ex`) already pattern-matches on handler returns; Phase 7 adds one more clause `{:halt, reason, _} when reason in @reserved_halt_atoms -> invalid_return_with_reserved_meta(reason)`. The `@reserved_halt_atoms` module attribute in `ToolRunner` enumerates the six reserved atoms.
  - `{:ask_user, question}` / `{:ask_user, question, opts}` — emits Phase-6's `:ask_user_requested` event at the step layer; Phase 7 appends `%Message{role: :assistant, content: question, metadata: %{ask_user: true, tool_call_id: id}}` to the thread (spec §12.3 step 2) and surfaces `halted_reason: :ask_user`, `pending_question: question`, `pending_tool_call_id: id` on the `ChatResult`.
- **§5.9 ChatResult shape + `halted_reason`.** Phase 7 populates every field:
  - `:thread` — the input thread plus all assistant messages, tool-role messages, and (on ask-user suspend) the question assistant message.
  - `:final_response` — the LAST step's `response` (adapter call response, with collector-authoritative `output_text`).
  - `:steps` — every step run, in execution order. Manual-mode halt still produces one step (with `tool_results: []`, `done?: false`, `metadata.mode: :manual`).
  - `:halted_reason` — computed by `terminal_condition/4` per the ordering in "Overview" point 5 above. The seven atoms used: `:completed`, `:max_turns`, `:halt_when`, `:ask_user`, `:tool_error`, `:manual_tool_calls`, `:error`, plus user custom atoms from `{:halt, atom, _}`. `:cancelled` is reserved (spec §5.2) but not produced by Phase 7 — cancellation is consumer-driven (Stream halt) and emits no `:chat_completed` event; a cancelled stream has no ChatResult. Phase 7 does not emit `:cancelled` as a halted_reason.
  - `:pending_question` — `nil` except when `halted_reason: :ask_user`.
  - `:pending_tool_call_id` — `nil` except when `halted_reason: :ask_user`.
  - `:metadata` — carries an `:ask_user_opts` key on ask-user halt; a `:halt_result` key on handler-halt (the term the handler returned); a `:halt_tool_call_id` key on handler-halt or tool_error halt; a `:halt_when_step_index` key on `halt_when` halt (the 0-based index of the step that triggered the gate); a `:manual_turn_index` key on manual-mode halt; otherwise `%{}`.
- **§8 Event protocol.** No new variants. The `:chat_completed` tag (declared in Phase 1) gains an emission site (`Chat.stream/3`) and a `StreamCollector` fold clause. No tag set change.
- **§10.5 `chat/3`, §10.6 `stream/3`.** Implemented per spec signatures; option precedence honoured per §10 (`call opts > request field > engine defaults > app config > library defaults`).
- **§12 Auto vs manual orchestration.** Phase 7 implements both modes **at the chat layer**:
  - `mode: :auto` (default) — executes tool calls automatically, loops until a terminal condition.
  - `mode: :manual` — on the FIRST step whose response has `finish_reason: :tool_calls`, halts with `halted_reason: :manual_tool_calls`, returning the tool calls on `final_response.tool_calls` for the caller to submit results. If the first step's response has no tool calls (a pure text turn), the chat loop continues until a different terminal condition fires — manual mode doesn't mean "always one turn"; it means "surface tool calls when they appear". This mirrors spec §25's sample.
- **§12.3 Ask-user suspension (full).** Phase 7 completes the spec §12.3 contract at the chat layer:
  - Step 1 (tool-result encoding) — Phase 6 done (via `ToolRunner`).
  - Step 2 (append assistant question message to thread) — **Phase 7 adds this.** `ChatResult.thread` contains `%Message{role: :assistant, content: question, metadata: %{ask_user: true, tool_call_id: id}}` as the LAST message. A caller resuming via `ALLM.chat(engine, result.thread ++ [ALLM.user(answer)])` has a well-formed thread.
  - Step 3 (halt before next adapter call) — Phase 6 + Phase 7 combined (Phase 6's step halt propagates; Phase 7 does not start a next step).
  - Steps 4–6 (chat / stream / session caller contracts) — Phase 7 covers chat + stream; Phase 8 covers session.
- **§17 Internal modules.** `ALLM.Chat.run/3` and `ALLM.Chat.stream/3` land with the spec §17 signatures. No new sub-module (`Chat` is already the orchestration home from Phase 6).
- **§19 Streaming options.** Phase 7 newly consumes two opts at the `Chat.run/stream` layer:
  - `:max_turns` — `pos_integer()`. Default `8` (matching spec §21's sample `engine.params[:max_turns]: 8`). Consumed at the chat layer; stripped at `StreamRunner` via the existing `@orchestration_opts` deny-list (renamed from `@phase_7_opts` in Phase 6). A `:max_turns` of `1` reduces `chat/3` to `step/3` semantically, though callers should prefer `step/3` directly.
  - `:halt_when` — `(StepResult.t() -> boolean())`. No default (nil ≡ "never halt on this gate"). Called synchronously between steps with the just-completed step's `%StepResult{}`. Exceptions inside `halt_when` propagate to the caller of `chat/3` / `stream/3` — they are NOT caught. Rationale: `halt_when` is a user-supplied callback and its exceptions are the caller's bug, not the adapter's; swallowing them would mask caller errors.
  - `:on_tool_error` — `:continue | :halt | (ToolCall.t(), term() -> {:continue, term()} | :halt)`. Phase 6 shipped `:continue | :halt`; Phase 7 adds the function form per spec §30. Consumed by `ToolRunner`; not forwarded to the adapter.
  - `:mode` — continues from Phase 6's partial implementation (single-turn manual surfacing). Phase 7 adds the full multi-turn semantics described under §12 above.
- **§20 Error reasons.** Phase 7 introduces NO new error-reason atoms. Every existing atom is already committed in the closed enum of a prior phase. `:max_turns_exceeded` from spec §20 is NOT used — per spec §5.9 the equivalent surfaces as `ChatResult.halted_reason: :max_turns` (no error). This is a spec-internal discrepancy: §20 lists atom tagged-tuple error reasons that predate the ChatResult-halt-reason design; Phase 7 honours §5.9.
- **§30 Tool error policy (full).** Phase 7 implements the function form `(ToolCall.t(), term() -> {:continue, term()} | :halt)`.
  - Invoked synchronously inside the `Task.async_stream/5` task, AFTER the handler returns / raises / encoder fails. Receives the per-tool-call's `%ToolCall{}` and the error term (which may be a raw return from the handler, a wrapped `%ToolError{}`, or an encoder exception struct).
  - `{:continue, replacement_term}` — `replacement_term` is encoded by the tool-result encoder and becomes the tool-result content. The batch continues.
  - `:halt` — same as `:halt` atom path; step halts with `halted_reason: :tool_error`.
  - Raising inside the function is CAUGHT by the same `try/rescue` boundary as the executor's; the raise is wrapped as `%ToolError{reason: :invalid_return, cause: exception, metadata: %{on_tool_error_raised: true}}` and then — to avoid infinite recursion — treated as `:halt` (the function's error policy is itself broken, so the orchestrator halts rather than asking the function again). Test asserts this specific shape.
- **§31 Property-style coverage.** Three of the nine §31 scenarios become active in Phase 7. Two flip from `@tag :pending` (committed at `test/allm/providers/fake_scenarios_test.exs:430-441` for `max_turns` and `halt_when`); one is newly added (manual-mode partial flow — no prior placeholder existed for this scenario in the committed test file):
  - **`max_turns` cap hit mid-loop** — Fake scripts a chain of `{:tool_call, ...}` → `{:finish, :tool_calls}` sequences; `chat/3` with `max_turns: 2` halts after the second step's tool execution without issuing a third adapter call; `ChatResult.halted_reason == :max_turns`; `ChatResult.metadata.max_turns == 2`; `length(ChatResult.steps) == 2`.
  - **`halt_when` returns true** — Fake scripts a `{:tool_call, ...}` + `{:finish, :tool_calls}` first turn and a `{:text, "done"}` + `{:finish, :stop}` second turn; `chat/3` with `halt_when: fn sr -> length(sr.tool_results) > 0 end` halts after the first step; `ChatResult.halted_reason == :halt_when`; `length(ChatResult.steps) == 1`.
  - **single tool call with `mode: :manual` — partial flow via `chat/3`** — Fake scripts `{:tool_call, ...}` + `{:finish, :tool_calls}`; `chat/3` with `mode: :manual` returns `ChatResult.halted_reason == :manual_tool_calls`; `ChatResult.final_response.tool_calls` has the call; `ChatResult.steps` has one step with `tool_results: []`. Full session round-trip flow (the `submit_tool_result/3` resume) stays `@tag :pending` for Phase 8.

  The three remaining scenarios (consumer cancellation releases adapter request, mid-stream adapter error, session round-trip) are either covered by prior phases or stay pending for Phase 8.

### Layer demonstration

Phase 7 is Layer C only. Four consumer-facing usages at Layer C alone — no Layer D session needed:

```elixir
# Layer C: multi-turn non-streaming chat with auto tool execution
engine =
  ALLM.Engine.new(
    adapter: ALLM.Providers.Fake,
    adapter_opts: [
      scripts: [
        [
          {:tool_call, id: "c0", name: "weather", arguments: %{city: "Boston"}},
          {:finish, :tool_calls}
        ],
        [
          {:text, "It's 72°F and sunny in Boston."},
          {:finish, :stop}
        ]
      ]
    ],
    tools: [
      ALLM.tool(
        name: "weather",
        description: "",
        schema: %{"type" => "object"},
        handler: fn %{city: c} -> {:ok, %{forecast: "sunny", city: c}} end
      )
    ]
  )

{:ok, result} = ALLM.chat(engine, [ALLM.user("Weather in Boston?")])
# result.halted_reason == :completed
# result.final_response.output_text == "It's 72°F and sunny in Boston."
# length(result.steps) == 2
```

```elixir
# Layer C: streaming multi-turn chat — every event flows in real time
{:ok, stream} = ALLM.stream(engine, [ALLM.user("Weather in Boston?")])

Enum.each(stream, fn
  {:text_delta, %{delta: d}}               -> IO.write(d)
  {:tool_execution_started, %{name: n}}    -> IO.puts("\n[running #{n}]")
  {:step_completed, _}                     -> IO.puts("[step done]")
  {:chat_completed, %{result: r}}          -> IO.puts("\n[chat halted: #{r.halted_reason}]")
  _ -> :ok
end)
```

```elixir
# Layer C: manual mode halts on first tool-calls turn — no tool execution
{:ok, result} = ALLM.chat(engine, [ALLM.user("Weather in Boston?")], mode: :manual)
# result.halted_reason == :manual_tool_calls
# result.final_response.tool_calls == [%ToolCall{id: "c0", name: "weather", ...}]
# length(result.steps) == 1
# result.steps |> hd |> then(& &1.tool_results) == []
```

```elixir
# Layer C: ask-user suspend — thread has the question as the last assistant message
# (handler returns {:ask_user, "which city?"}; thread then has a :user "Weather?" +
#  :assistant with tool_calls + :tool with "<awaiting user response>" + :assistant
#  with content: "which city?", metadata: %{ask_user: true, ...})
{:ok, result} = ALLM.chat(engine_with_ask_user_handler, [ALLM.user("Weather?")])
# result.halted_reason == :ask_user
# result.pending_question == "which city?"
# result.pending_tool_call_id == "c0"
# List.last(result.thread.messages).metadata[:ask_user] == true
```

No Layer D function is exercised; `ALLM.Session` arrives in Phase 8. All four usages work with no Session.

### Prerequisites

- **Phase 1–4 complete.** Error structs (including `%EngineError{reason: :unknown_tool}`, `%ToolError{reason: :handler_raised | :handler_exit | :timeout | :invalid_return | :encoding_failed}`), `ALLM.Engine` API, behaviours and defaults, `ALLM.Providers.Fake` including multi-script support (`scripts:` opt at `lib/allm/providers/fake.ex`).
- **Phase 5 complete.** `ALLM.stream_generate/3`, `ALLM.generate/3`, `ALLM.StreamCollector` (including thread-less `new/0`, `to_response/1`, and the per-tag fold clauses for adapter events), `ALLM.StreamRunner` with the `@orchestration_opts` deny-list (renamed from `@phase_7_opts` in Phase 6).
- **Phase 6 complete.** `ALLM.step/3`, `ALLM.stream_step/3`, `ALLM.ToolRunner.run_tool_calls/3` + `stream_tool_calls/3`, `StreamCollector`'s Phase 6 fold clauses (`:tool_result_encoded`, `:tool_halt`, `:ask_user_requested`) and the `halt_state` channel, `ALLM.Chat.step/3` + `stream_step/3` including the three-phase `Stream.resource/3` state machine, `test/support/assertions.ex` with `assert_equivalent_step_result/2`.
- **No dependency on Phase 8.** Session integration is out of scope; Phase 7's manual mode halts with `halted_reason: :manual_tool_calls` and the caller must use `chat/3` again with an augmented thread — no `Session.submit_tool_result/3` involved.

### Out of scope

- **`ALLM.Session` integration.** Phase 8. Phase 7 exercises ask-user and manual-mode via `chat/3` direct-thread-resume; Phase 8 wires the Session state transitions (`:awaiting_tools`, `:awaiting_user`).
- **Retries.** Phase 9 (spec §20, §6.1). Phase 7 does not add a retry loop around adapter calls; each step's adapter call inherits Phase 5's pass-through.
- **Telemetry.** Phase 9 (spec §29). Phase 7 does not emit `[:allm, :chat, :start | :stop]` or `[:allm, :step, :start | :stop]` events.
- **`request_id` propagation end-to-end.** Phase 9. Phase 7 reuses Phase 6's per-step propagation (each step has its own `request_id` from the adapter response); there is no chat-level `request_id` in Phase 7. A Phase-9 addition may mint a top-level `request_id` on `chat/3` entry.
- **Capability pre-flight (`llm_db`).** Phase 9 (spec §6.3). Phase 7 does not add a new `llm_db` code path.
- **`structured_finalize` two-pass.** Phase 9 / 10 (spec §5.4, §32.1). Phase 7's chat loop is agnostic to structured output — the adapter either supports the combo or rejects it at the Phase 5 layer.
- **Session round-trip §31 scenario.** Phase 8.
- **Mid-stream adapter-cancellation `halted_reason: :cancelled`.** Per spec §30's cancellation section, consumer halt on a stream terminates WITHOUT emitting `:chat_completed`. Phase 7 does not produce a `ChatResult` for a cancelled stream — there is no one. A `emit_cancelled: true` opt is noted in spec §30 but deferred; if a consumer wants a final ChatResult for logging, they collect events up to the halt and call `StreamCollector.to_chat_result/1` manually (which builds a partial ChatResult from observed state with `halted_reason: :cancelled`).
- **`:halt_when` function-ref serialization.** A `halt_when:` callback is a runtime fun and is NOT serializable onto a `%Session{}`. Per spec §2 Layer A, funs don't belong on serializable structs; `:halt_when` is a Layer C opts-only concern, never a Layer D struct field.

### Non-obvious decisions

1. **`Chat.stream/3` composes multi-turn via a two-phase `Stream.resource/3` state machine driven by `stream_step/3`'s reducer continuation — mirroring the Phase 6 idiom one layer up.** Phase 6 Non-obvious Decision #1 established the "drive, don't wrap" rule for sub-stream composition. Phase 7 applies it: the outer `Chat.stream/3` resource drives `Chat.stream_step/3` enumerables **sequentially**, advancing the current step's reducer one event at a time. When a step's `:step_completed` event arrives, the outer resource decides whether to start a new step (construct a fresh `stream_step/3` enumerable seeded with the updated thread and seed its reducer continuation) or transition to Phase F and emit `:chat_completed`.

   Two rejected alternatives:

   - **`Stream.concat/1` of pre-built step streams.** Requires constructing every step's enumerable ahead of time, but each step's thread depends on the previous step's tool execution results — identical data-dependency problem Phase 6 rejected. Workarounds are more complex than the two-phase state machine.
   - **`Stream.flat_map/2` over a lazy list of streams.** The `flat_map` fun still needs the previous step's result to produce the next stream — circular dependency. A `Stream.unfold/2` with pull-based "ask for next step" semantics is feasible but loses `Stream.resource/3`'s explicit `after_fun` cleanup contract.

   Chosen: one outer `Stream.resource/3` with three state tags:

   - **Phase S (`:step, data`)** — `data` holds `{engine, opts, thread, collector, step_cont, step_index, steps_accumulator}`. `step_cont` is a `{:suspended, _last_event, cont}` shape exactly like Phase 6 Phase A; `cont` drives the current `stream_step/3` enumerable one event at a time. Each `next_fun` invocation advances `cont`; on a regular event, emits it and folds it into the outer collector; on the terminal `:step_completed`, decides transition (see below).
   - **Phase F (`:final, data`)** — `data` holds `{chat_result}`. Emits exactly one `{:chat_completed, %{result: chat_result}}` event and transitions to `{:done, _}` which halts.
   - **Done** — `{:halt, state}`.

   **Per-`:step_completed` transition logic** (invoked inside Phase S's `next_fun` when `cont.({:cont, nil})` returns `{:suspended, {:step_completed, %{response: r, thread: t}}, _next_cont}`):

   ```elixir
   # StepResult is already computed by the step-layer state machine;
   # Phase S extracts it by folding the last :step_completed event back
   # into a dedicated StepResult fold (the step-layer collector already
   # produced it; the chat-layer just reads it out).
   step_result = step_result_from_step_completed(event, collector_for_step)
   steps_acc = steps_accumulator ++ [step_result]

   case terminal_condition(step_result, opts, step_index, thread_after) do
     {:halt, reason, halt_meta} ->
       new_state = %Chat.LoopState{
         data.loop_state
         | thread: thread_after,
           steps: steps_acc,
           halted_reason: reason,
           halt_metadata: halt_meta,
           pending_question: halt_meta[:pending_question],
           pending_tool_call_id: halt_meta[:pending_tool_call_id]
       }
       chat_result = build_chat_result(new_state)
       {[event], {:final, %{chat_result: chat_result}}}

     :continue ->
       new_thread = thread_after  # already includes assistant + tool msgs
       new_step_stream = Chat.stream_step(engine, new_thread, opts)
       new_step_cont = seed_cont(new_step_stream)
       new_data = %{data | thread: new_thread, step_cont: new_step_cont,
                           step_index: step_index + 1, steps_acc: steps_acc}
       {[event], {:step, new_data}}
   end
   ```

   The outer collector is a separate `%StreamCollector{}` from the per-step collector maintained inside `stream_step/3` (which is itself internal to the Phase-6 three-phase state machine). This is fine: each `stream_step/3` invocation has its own inner collector for the step; the outer chat collector aggregates events across all steps and is what `to_chat_result/1` reads. They never share state. When the caller of `stream/3` drives the outer enumerable via `Enum.reduce/3 |> StreamCollector.apply_event/2`, their collector is yet ANOTHER instance — the outer Phase-S collector in `Chat.stream/3` is purely for constructing the final `ChatResult` (via `build_chat_result/1`) when Phase F fires; it is NOT exposed to the consumer.

   **Cleanup ownership.** Same pattern as Phase 6: the outer `after_fun` pattern-matches on the state. In Phase S, it halts `step_cont` via `cont.({:halt, :consumer_halt})` — which triggers `stream_step/3`'s own three-phase `Stream.resource/3` cleanup, which in turn halts whichever Phase-6 sub-phase is active (A, B, or C). The cleanup chain is explicit and top-down:

   ```
   Chat.stream/3 after_fun
     → halt step_cont
       → Chat.stream_step/3 after_fun
         → halt adapter_cont OR tool_cont (whichever is active)
           → adapter's Stream.resource/3 after_fun OR ToolRunner's cleanup
   ```

   Each layer is a `Stream.resource/3` that owns its sub-stream's cleanup via continuation-based halt; there is no cross-layer hook registration. Verified against Elixir 1.17 stdlib docs on 2026-04-24: `Stream.resource/3`'s `after_fun` is called exactly once per reduction, regardless of halt reason.

   `Docs target: @moduledoc ALLM.Chat` ("Multi-turn stream composition" section — the two phases, per-`:step_completed` transition logic, and the layered-cleanup-chain table).

2. **`Chat.run/3` is NOT implemented via `StreamCollector.to_chat_result(stream/3 |> collect)`; it runs the loop directly in process.** An obvious option for the non-streaming path is to call `stream/3` and fold all events through a collector. That would be the cleanest expression of spec §3's stream-first principle. Rejected because:

   - Every `stream_step/3` emission goes through `Stream.resource/3` primitives whose overhead (one `Task.async_stream/5`, one outer resource, one inner resource) is non-trivial compared to `Chat.step/3`'s direct synchronous dispatch. For a 10-turn chat, the streaming path instantiates 10 outer resources + 10 inner resources; the direct path runs a `for`-loop with synchronous `step/3` calls.
   - Chat-equivalence is established by **both paths constructing the ChatResult via the same function** (`build_chat_result/1`), not by one path reducing the other. Phase 6 did the same: `step/3` does NOT call `stream_step/3 |> collect`; each has its own implementation, and the property test asserts equality. The equivalence contract is "the two paths produce the same ChatResult", not "the non-streaming path is implemented in terms of the streaming path".
   - Error handling is simpler: `Chat.run/3` can surface an adapter pre-flight error synchronously as `{:error, struct}` without wrapping it in a stream-folding machine.

   Chosen: `Chat.run/3` is a `Enum.reduce_while/3` over `1..max_turns` (or an explicit recursive helper — both equivalent). Each iteration calls `Chat.step/3`, appends the result to `steps_acc`, checks the `terminal_condition/4` helper, and either `{:cont, new_acc}` or `{:halt, {:ok, chat_result}}`. The single construction point for `ChatResult` (in both paths) is `build_chat_result/1` which takes a Phase-7-internal struct `%ChatLoopState{}` and emits a fully-populated `%ChatResult{}`.

   **Chat-equivalence property** (`test/allm/chat_equivalence_test.exs`) exercises: given a Fake multi-turn fixture + a chat-opts keyword list, `Chat.run/3`'s returned `ChatResult` and `Chat.stream/3 |> StreamCollector.to_chat_result/1`'s returned `ChatResult` are equal modulo tool-message ordering (per Phase 6 Non-obvious Decision #9).

   `Docs target: @moduledoc ALLM.Chat` ("Chat equivalence" section, linking to `test/allm/chat_equivalence_test.exs`).

3. **`:chat_completed` event is emitted EXACTLY ONCE by `Chat.stream/3` — never by `Chat.stream_step/3`, never by `ALLM.Providers.Fake`.** The event is a chat-layer artefact, not an adapter artefact. It signals "the entire multi-turn loop has halted", which is meaningful only at the chat layer. Phase 6's `stream_step/3` terminates with `:step_completed`; Phase 7's `stream/3` appends `:chat_completed` after the final step.

   Consumer contract: `stream/3`'s enumerable always terminates with `:chat_completed` UNLESS the consumer halts it early (in which case no `:chat_completed` fires, matching spec §30's cancellation contract — "a cancelled stream terminates without emitting `:chat_completed`").

   `StreamCollector.to_chat_result/1` prefers the stored `:chat_result` field (from the `:chat_completed` fold clause) when present. When absent — because the consumer halted early — it falls back to ALWAYS assigning `halted_reason: :cancelled` (with one exception: `:error` when `state.error != nil` from a folded adapter error). Partial-step cancellation (e.g., two clean `:step_completed` events observed before halt) is still `:cancelled` — `state.steps` being non-empty does NOT promote to `:completed`, because the orchestrator never emitted `:chat_completed` and therefore never decided the chat completed successfully. Callers distinguish "stream completed naturally" from "stream was halted" by checking whether `collector.chat_result` is nil.

   Test assertion: `stream/3 |> Enum.take(1)` (halt after first event) → `to_chat_result/1` returns a ChatResult with `halted_reason: :cancelled`, `steps: []`. `stream/3 |> Enum.to_list/1` (natural termination) → `halted_reason ∈ {:completed, :max_turns, :halt_when, :ask_user, :tool_error, :manual_tool_calls, :error, atom()}`.

   `Docs target: @doc ALLM.Chat.stream/3` ("Terminal event" paragraph) + `@doc ALLM.StreamCollector.to_chat_result/1` ("Stored-vs-computed branch" paragraph).

4. **Both paths share `Chat.build_chat_result/1` as the single ChatResult construction point.** Chat-equivalence is established by construction rather than by property test alone. `build_chat_result/1` takes a `%ChatLoopState{}` struct (Phase 7-internal; not exported) and returns a `%ChatResult{}`:

   ```elixir
   defmodule ALLM.Chat.LoopState do
     @moduledoc false
     defstruct [
       :engine, :opts, :initial_thread,
       thread: nil,
       steps: [],
       halted_reason: nil,
       halt_metadata: %{},
       pending_question: nil,
       pending_tool_call_id: nil,
       step_index: 0
     ]
   end

   defp build_chat_result(%Chat.LoopState{} = state) do
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
   ```

   `Chat.run/3` constructs a `%Chat.LoopState{}`, updates it across iterations, and calls `build_chat_result/1` at halt. `Chat.stream/3`'s Phase S maintains the same struct (in the `data` field of the `{:step, data}` state tuple) and calls `build_chat_result/1` at `{:final, _}` transition. The streaming and non-streaming paths produce bytewise-identical `%ChatResult{}` values for identical inputs (modulo tool-message ordering, per Phase 6 Decision #9).

   `%Chat.LoopState{}` is `@moduledoc false` / `@opaque`; callers never see it. It's a private internal struct that exists solely to share the build-helper between the two paths.

   `Docs target: internal — no user-facing docs.`

5. **Terminal-condition ordering is encoded in one helper, `Chat.terminal_condition/4`.** To prevent drift between the streaming and non-streaming paths, the six-entry ordering from Overview point 5 is implemented as a single helper:

   ```elixir
   @spec terminal_condition(StepResult.t(), opts :: keyword(), step_index :: non_neg_integer(),
                            thread :: Thread.t()) ::
           {:halt, halted_reason :: atom(), halt_metadata :: map()} | :continue
   def terminal_condition(%StepResult{} = sr, opts, step_index, _thread) do
     cond do
       # Ordering matters — see PHASE_7_DESIGN.md Overview point 5.
       # Note: `is_atom(nil) == true` in Elixir (verified in IEx on OTP 27 on
       # 2026-04-24), so every branch reading `sr.metadata[:halted_reason]`
       # as an `is_atom/1` guard MUST also exclude `nil` explicitly.
       sr.metadata[:halted_reason] == :ask_user ->
         {:halt, :ask_user,
          %{pending_question: sr.metadata.pending_question,
            pending_tool_call_id: sr.metadata.pending_tool_call_id,
            ask_user_opts: Map.get(sr.metadata, :ask_user_opts, [])}}

       sr.metadata[:halted_reason] == :tool_error ->
         {:halt, :tool_error, %{halt_tool_call_id: sr.metadata[:halt_tool_call_id]}}

       is_atom(sr.metadata[:halted_reason]) and
           sr.metadata[:halted_reason] not in [nil, :tool_error, :ask_user] ->
         # Handler-requested halt with custom reason (:plan_submitted, etc.).
         # Reached only when the two specific-atom branches above didn't fire.
         {:halt, sr.metadata.halted_reason,
          %{halt_tool_call_id: sr.metadata[:halt_tool_call_id],
            halt_result: sr.metadata[:halt_result]}}

       sr.metadata[:mode] == :manual ->
         {:halt, :manual_tool_calls, %{manual_turn_index: step_index}}

       sr.response.finish_reason in [:stop, :length, :content_filter] ->
         {:halt, :completed, %{}}

       sr.response.finish_reason == :error ->
         {:halt, :error,
          %{error: Map.get(sr.response.metadata, :error)}}

       halt_when = Keyword.get(opts, :halt_when) ->
         if halt_when.(sr),
           do: {:halt, :halt_when, %{halt_when_step_index: step_index}},
           else: check_max_turns(step_index, opts)

       true ->
         check_max_turns(step_index, opts)
     end
   end

   defp check_max_turns(step_index, opts) do
     max_turns = Keyword.get(opts, :max_turns, 8)
     if step_index + 1 >= max_turns,
       do: {:halt, :max_turns, %{max_turns: max_turns}},
       else: :continue
   end
   ```

   Both `run/3` and `stream/3` call `terminal_condition/4` on the just-completed step; there is no secondary place where halt logic lives. Drift is impossible. Test plan covers each branch individually and several pairs of interactions (e.g., `:tool_error` firing when `halt_when` would ALSO return true — the `:tool_error` branch wins).

   `Docs target: @doc ALLM.Chat.run/3` ("Terminal conditions" table, six rows matching the `cond` branches).

6. **`StreamCollector.:step_completed` fold resets the per-step sub-state so the NEXT step folds cleanly.** Phase 6's `StreamCollector` tracks `:current_text`, `:current_tool_calls`, `:tool_call_order`, `:tool_results`, `:halt`, `:finish_reason`, `:raw_finish_reason`, `:error` — all per-step. Across multiple steps in `stream/3`, the collector fold receives events from EVERY step interleaved ONLY AT THE STREAM BOUNDARY (i.e., all of step 1's events, then all of step 2's events, etc. — never interleaved within a step per Non-obvious Decision #1). The `:step_completed` event is the natural reset point.

   Phase 7 adds a `:step_completed` fold clause:

   ```elixir
   def apply_event(
         %__MODULE__{} = state,
         {:step_completed, %{response: response, thread: thread}}
       ) do
     # Freeze the just-completed step's data into a StepResult and append.
     # Then reset per-step sub-state for the next step's events.
     step_result = %StepResult{
       thread: thread,
       response: response,
       tool_results: state.tool_results,
       done?: step_done?(state),
       metadata: merge_halt_metadata(%{}, state.halt)
     }

     %{
       state
       | steps: state.steps ++ [step_result],
         thread: thread,
         # Reset per-step sub-state.
         current_text: "",
         current_tool_calls: %{},
         tool_call_order: [],
         tool_results: [],
         halt: nil,
         finish_reason: nil,
         raw_finish_reason: nil,
         last_message: nil
     }
   end
   ```

   The `:error` field is NOT reset — a mid-stream adapter error persists across the reset because `to_chat_result/1` needs it to compute `halted_reason: :error`. Test asserts: after a `:step_completed` fold, `collector.current_text == ""` (reset) and `collector.error` is preserved (not reset) when it was set during the step's adapter events.

   **Alternative rejected: separate `%StepCollector{}` struct folded inside the outer `%StreamCollector{}`.** Cleaner in principle but requires two distinct fold dispatchers and doubles the clause count. The reset-at-boundary approach keeps one dispatcher and one type.

   `Docs target: @moduledoc ALLM.StreamCollector` ("Phase 7 extension" paragraph — two rows added to the fold-semantics table: `:step_completed`, `:chat_completed`).

7. **`:chat_completed` fold stores the event's `result` verbatim; `to_chat_result/1` short-circuits to it when present.** The fold:

   ```elixir
   def apply_event(%__MODULE__{} = state, {:chat_completed, %{result: %ChatResult{} = r}}) do
     %{state | chat_result: r, done?: true}
   end
   ```

   `to_chat_result/1`:

   ```elixir
   def to_chat_result(%__MODULE__{chat_result: %ChatResult{} = stored}), do: stored
   def to_chat_result(%__MODULE__{thread: nil}),
     do: raise(ArgumentError, "...")
   def to_chat_result(%__MODULE__{thread: %Thread{} = thread} = state) do
     # Fallback — no :chat_completed event was folded. This happens only
     # when the consumer halted the stream before the orchestrator emitted
     # the terminal event. The orchestrator never reached a decision, so
     # the fallback ALWAYS assigns :cancelled (regardless of how many
     # clean :step_completed events were observed) — :completed would
     # misrepresent the outcome. An adapter mid-stream error (state.error
     # set) short-circuits to :error so the error is visible to logging
     # consumers.
     halted_reason = if state.error, do: :error, else: :cancelled

     %ChatResult{
       thread: thread,
       final_response: extract_final_response(state),
       steps: state.steps,
       halted_reason: halted_reason,
       metadata: state.metadata
     }
   end
   ```

   The short-circuit branch is the canonical path: every natural-termination `stream/3` reduction stores the orchestrator-constructed ChatResult. The fallback is ALWAYS the cancellation path (consumer halted early) with the one exception of a mid-stream adapter error, which surfaces as `:error`. A caller who observes `halted_reason: :cancelled` alongside non-empty `steps` knows the orchestrator ran some steps cleanly but never reached a terminal decision.

   `Docs target: @doc ALLM.StreamCollector.to_chat_result/1` ("Stored-vs-computed branch" paragraph, with a worked example of each branch — stored, cancelled with zero steps, cancelled with two steps, adapter error mid-stream).

8. **`on_tool_error` function form is invoked synchronously inside the `Task.async_stream/5` task, not on the parent process.** Phase 6's `ToolRunner.execute_one_tool/3` already runs inside a `Task.async_stream/5` task; Phase 7 keeps the function-form dispatch in the same context rather than marshalling the error term back to the parent. Two rejected alternatives:

   - **Dispatch on the parent.** Requires `Task.async_stream/5` to return a raw `{:error, _}` and the parent process to then call `on_tool_error.(tool_call, error)` after the batch. Loses `max_concurrency`-bounded execution (the function's work is on one process), and if the function is blocking, it serialises what the batch was about to parallelise.
   - **Separate `Task` for the function call.** Adds a layer of process supervision and latency for no benefit — the function is purely computational per its type signature `(ToolCall.t(), term() -> {:continue, term()} | :halt)`.

   Chosen: inside the task, after the handler's return / encoder raise is converted to an error term, the task calls `on_tool_error.(tool_call, error)`. If it returns `{:continue, replacement}`, the task uses `replacement` as the tool-result content (encoded via the encoder, with the same `try/rescue` wrap — a re-raise in the function's replacement encoder is caught as `%ToolError{reason: :encoding_failed}` but without re-invoking `on_tool_error` to avoid infinite recursion, matching spec §30 "function form" semantics).

   If the function itself raises, the task catches the raise and routes it as `:halt` (per Spec-coverage §30 above). This behaviour is deliberately surprising — a function that raises is a caller bug, and silently treating it as `:continue` would mask bugs. `:halt` at least surfaces the problem via `ChatResult.halted_reason: :tool_error` and preserves the raised exception in `halt_metadata.on_tool_error_exception`.

   Test: `on_tool_error: fn _, _ -> raise "oops" end` → `ChatResult.halted_reason == :tool_error`; `ChatResult.metadata.on_tool_error_exception` is the `%RuntimeError{message: "oops"}`.

   `Docs target: @doc ALLM.ToolRunner.run_tool_calls/3` (update the "Opts" table row for `:on_tool_error` to include the function form; add a "Function form semantics" paragraph).

9. **`max_turns` default is `8`, matching spec §21's sample engine construction.** Spec §21 shows `params: %{temperature: 0.2, max_turns: 8}`. Per spec §10's option precedence, the default lives at the library layer; the engine's `params` map is the recommended place for a deployment-wide override; per-call `opts` wins.

   `8` is the library default. A future `ALLM.Engine.put_param(engine, :max_turns, N)` overrides it globally for the engine; `ALLM.chat(engine, thread, max_turns: N)` overrides it per-call.

   The precedence chain at `Chat.run/3` entry:

   ```elixir
   max_turns =
     Keyword.get(opts, :max_turns) ||
       Map.get(engine.params, :max_turns) ||
       Application.get_env(:allm, :max_turns) ||
       8
   ```

   Test: each level of the chain shadows the levels below; no level present → `8`.

   `Docs target: @doc ALLM.chat/3` ("max_turns precedence" paragraph) + `@doc ALLM.Engine.put_param/3` (mention `:max_turns` as a recognised key).

10. **`ChatResult.final_response` is the LAST step's response, never a synthesized multi-turn response.** One might expect `final_response` to be a merged summary across turns. Rejected: there is no sound merge operation — `output_text` concatenation across turns drops the tool-result boundaries; `finish_reason` merging has no canonical ordering; `tool_calls` merging duplicates calls that were already executed. The LAST step's response is the authoritative "what did the model say at the end"; earlier steps are accessible via `ChatResult.steps`.

    When `steps == []` (degenerate case — `Chat.run/3` never actually ran a step because validation failed but somehow still produced a ChatResult), `final_response == nil`. This shouldn't happen in practice because validation errors surface as `{:error, struct}` before any `ChatResult` is built; the `nil` guard is defensive.

    `Docs target: @moduledoc ALLM.ChatResult` — update the existing `@moduledoc` to clarify this. The current moduledoc does not specify.

11. **`halt_when` is called AFTER the thread mutation for the current step, not BEFORE.** A caller writing `halt_when: fn sr -> length(sr.thread.messages) > 20 end` inspects the thread **as it will appear in the next step's input**. If the gate were called before the thread mutation, `halt_when` would see the INPUT thread of the current step, which is misleading — the caller is asking "has this step pushed the thread into a state I want to halt on?", not "was the thread in that state before this step ran?".

    Concretely, `terminal_condition/4` is called with `step_index` matching the index of the JUST-completed step (0-based), and `thread` matching the thread AFTER the step appended its assistant + tool messages. `halt_when(step_result)` operates on the StepResult (which carries the post-mutation thread); so this invariant is transparent to `halt_when` callers — they just see the right thread.

    Test: a `halt_when` that counts messages fires at the expected step. Test a `halt_when` that reads `sr.tool_results` — the assertion is that this list matches the tool messages in `sr.thread.messages` tail (the per-step invariant from Phase 6 Non-obvious Decision #10).

    `Docs target: @doc ALLM.chat/3` ("halt_when semantics" paragraph).

12. **Manual mode's halt is `ChatResult.halted_reason: :manual_tool_calls` — a new atom for the open tail of §5.9's `halted_reason` type.** Spec §5.9's closed prefix is `:completed | :max_turns | :halt_when | :ask_user | :tool_error | :cancelled`, with `atom()` tail. `:manual_tool_calls` is NOT in the closed prefix but is a legal atom-tail value.

    The name was chosen over alternatives (`:awaiting_tools`, `:manual`, `:tool_calls`) because:

    - `:awaiting_tools` clashes with `%ALLM.Session{}.status: :awaiting_tools` (spec §5.7) — Phase 8 will use that atom for the Session state transition, and overloading it with a different meaning at the ChatResult layer invites confusion.
    - `:manual` is too vague — a future `mode: :manual` extension might halt for other reasons.
    - `:tool_calls` collides with `%ALLM.Response.finish_reason{:tool_calls}` — the atom is already in use at the response layer.

    `:manual_tool_calls` is unique across all ALLM atoms as of 2026-04-24 (verified by grepping `@type` declarations in `lib/allm/` on the committed tree).

    `Docs target: @doc ALLM.chat/3` (include `:manual_tool_calls` in the halt-reason table) + `@moduledoc ALLM.ChatResult` (add to the halt-reason list with a one-line rationale).

13. **`:on_event` observes only adapter-emitted events, NOT chat-layer events.** Phase 5's `:on_event` callback is wired into `ALLM.StreamRunner` (`lib/allm/stream_runner.ex:50,180` — verified 2026-04-24) which observes events at the adapter-stream boundary only. Phase 6's chat-layer events (`:tool_execution_started`, `:tool_execution_completed`, `:tool_result_encoded`, `:ask_user_requested`, `:tool_halt`, `:step_completed`) are emitted OUTSIDE `StreamRunner` (constructed by `ToolRunner.stream_tool_calls/3` and the Phase-6 three-phase state machine), so they NEVER fire `on_event`. Phase 7 adds one more chat-layer event (`:chat_completed`), emitted at the `Chat.stream/3` outer state machine; it also does NOT fire `on_event`.

    User model risk: a caller writing `on_event: &Logger.info/1` expects to log every event flowing through the stream. Reality: only adapter events (`:text_delta`, `:tool_call_*`, `:message_*`, `:raw_chunk`, adapter-emitted `:error`) fire the callback. The orchestration events the chat layer adds are invisible to `on_event`.

    Decision: keep the Phase-5 contract unchanged (no extension of `on_event` scope to chat-layer events) for v0.2; document the asymmetry explicitly in `@doc ALLM.chat/3` / `ALLM.stream/3`. Rationale: extending the scope would require either (a) wiring `on_event` through `Chat.stream/3`'s `Stream.resource/3` `next_fun` (mechanical but invasive), or (b) replacing `on_event` with an event-stream tap pattern (more flexible but more design surface). Both are v0.3 candidates; for v0.2, callers needing visibility on chat-layer events reduce the stream directly with `Stream.each/2` + side effect.

    Test: `stream/3` with `on_event: fn e -> send(self(), {:on_event, e}) end` — count messages received, assert NO `:chat_completed` or `:step_completed` or `:tool_execution_*` messages, only adapter events.

    `Docs target: @doc ALLM.stream/3` and `@doc ALLM.chat/3` ("on_event scope" paragraph).

14. **Streaming ask-user thread asymmetry — documented via `@doc ALLM.stream/3`.** Per Invariant 8 above, `:step_completed.thread` and `:chat_completed.result.thread` differ in the ask-user halt case. This is surfaced in `@doc ALLM.stream/3`'s "Ask-user thread asymmetry" paragraph with a concrete walk-through: the user sends "Weather?"; handler returns `{:ask_user, "which city?"}`; `:step_completed.thread` has 3 messages (user, assistant-with-tool-calls, tool-with-awaiting-response); `:chat_completed.result.thread` has 4 messages (the above + assistant question). Consumers intending to persist thread state between turns persist `ChatResult.thread`, not `:step_completed.thread`.

    `Docs target: @doc ALLM.stream/3` ("Ask-user thread asymmetry" paragraph) + `@doc ALLM.Chat.stream/3`.

## Behaviour & Type Contracts

### `ALLM.Chat.LoopState` (Layer C — new internal struct)

```elixir
defmodule ALLM.Chat.LoopState do
  @moduledoc false
  # Phase 7-internal — not exported. Shared by Chat.run/3 and Chat.stream/3's
  # Phase S state machine to ensure both paths construct ChatResult via
  # the same build_chat_result/1 helper.

  alias ALLM.{Engine, StepResult, Thread}

  # @opaque hides the struct shape from external Dialyzer callers; combined
  # with @moduledoc false, this struct is fully private to ALLM.Chat.
  @opaque t :: %__MODULE__{
          engine: Engine.t(),
          opts: keyword(),
          initial_thread: Thread.t(),
          thread: Thread.t(),
          steps: [StepResult.t()],
          halted_reason: atom() | nil,
          halt_metadata: map(),
          pending_question: String.t() | nil,
          pending_tool_call_id: String.t() | nil,
          step_index: non_neg_integer()
        }

  defstruct [
    :engine,
    :opts,
    :initial_thread,
    :thread,
    steps: [],
    halted_reason: nil,
    halt_metadata: %{},
    pending_question: nil,
    pending_tool_call_id: nil,
    step_index: 0
  ]
end
```

**Invariants:**

1. `thread` starts equal to `initial_thread` and grows monotonically (each step appends assistant + tool messages; ask-user halt appends one more assistant question message).
2. `steps` grows monotonically (one `%StepResult{}` per step run).
3. `halted_reason` is `nil` until terminal_condition/4 returns `{:halt, reason, _}`; then set once and never overwritten.
4. `pending_question` and `pending_tool_call_id` are `nil` unless `halted_reason == :ask_user`.
5. `step_index` equals `length(steps)` at any observation point (both incremented together after each step).
6. Not Layer A — contains `engine` which is Layer B. Not serializable. Never stored on any `%Session{}` (Phase 8 uses a separate `%Session{}` struct that carries only serializable state).

### `ALLM.Chat` (Layer C — Phase 7 additions)

```elixir
defmodule ALLM.Chat do
  # Phase 7 adds run/3 and stream/3 alongside Phase 6's step/3 and stream_step/3.

  @type chat_opts :: [
          mode: :auto | :manual,
          max_turns: pos_integer(),
          halt_when: (StepResult.t() -> boolean()) | nil,
          tool_timeout: timeout(),
          on_tool_error: :continue | :halt | (ToolCall.t(), term() -> {:continue, term()} | :halt),
          tool_executor: module() | nil,
          tool_result_encoder: module() | nil,
          # Phase 5 pass-through opts:
          emit_text_deltas: boolean(),
          emit_tool_deltas: boolean(),
          include_raw_chunks: boolean(),
          on_event: (Event.t() -> any()) | nil,
          # Phase 2 pass-through opts:
          model: String.t(),
          adapter_opts: keyword()
        ]

  @spec run(Engine.t(), Thread.t() | [Message.t()], chat_opts()) ::
          {:ok, ChatResult.t()} | {:error, EngineError.t() | AdapterError.t() | ValidationError.t()}
  def run(engine, thread_or_messages, opts \\ [])

  @spec stream(Engine.t(), Thread.t() | [Message.t()], chat_opts()) ::
          {:ok, Enumerable.t()} | {:error, EngineError.t() | AdapterError.t() | ValidationError.t()}
  def stream(engine, thread_or_messages, opts \\ [])

  # Internal — shared between run/3 and stream/3
  @spec build_chat_result(LoopState.t()) :: ChatResult.t()
  defp build_chat_result(state)

  @spec terminal_condition(StepResult.t(), keyword(), non_neg_integer(), Thread.t()) ::
          {:halt, atom(), map()} | :continue
  defp terminal_condition(step_result, opts, step_index, thread)
end
```

**Invariants:**

1. `run/3` always returns `{:ok, %ChatResult{}}` or `{:error, struct}`. Adapter pre-flight errors (validation, missing adapter) surface as `{:error, struct}` from the FIRST step's `Chat.step/3` call and propagate directly. Mid-loop adapter errors (during any non-first step) surface as `ChatResult.halted_reason: :error` — not as `{:error, _}` — because a ChatResult is already partially built.
2. `stream/3` always returns `{:ok, enumerable}` or `{:error, struct}`. The same pre-flight-vs-mid-loop distinction applies: the first step's pre-flight error surfaces as `{:error, _}` from `stream/3`'s call site; later errors surface as `{:error, _}` events on the stream, followed by a `:chat_completed` event carrying a ChatResult with `halted_reason: :error`.
3. `run/3` and `stream/3 |> StreamCollector.to_chat_result/1` produce equal `ChatResult` values for every chat-opts-keyword + Fake-script combination, modulo tool-message ordering per Phase 6 Non-obvious Decision #9. This is the chat-equivalence invariant.
4. `terminal_condition/4` is TOTAL over the six-entry `cond` ordering from Non-obvious Decision #5. No step result shape falls through without a decision.
5. `build_chat_result/1` is the SINGLE construction point for `%ChatResult{}`. Both `run/3` (at halt) and `stream/3`'s Phase F (at halt) call it. No ad-hoc `%ChatResult{}` literal lives outside this function.
6. `run/3` calls `Chat.step/3` for each turn, threading the `%StepResult.thread` from one call as the input thread of the next. The thread mutations (assistant append, tool append, ask-user question append) are all owned by `step/3` except the ask-user question append which is owned by `run/3` (at the turn boundary, per spec §12.3).
7. `stream/3` calls `Chat.stream_step/3` for each turn, composing sub-streams via the two-phase `Stream.resource/3` from Non-obvious Decision #1. The ask-user question append is owned by `stream/3`'s Phase S when it detects `halted_reason: :ask_user` on the just-completed step — it ADDS the question message to the thread carried in the built `ChatResult`, not as a new `:message_completed` or `:message_started` event. The question appears ONLY on `ChatResult.thread`, not as a streamed event.

8. **Ask-user streaming thread asymmetry (Q3 decision, load-bearing invariant).** The streaming path has an intentional asymmetry between `:step_completed.thread` and `:chat_completed.result.thread` when the step's handler returned `{:ask_user, _}`:
   - `:step_completed.thread` carries the per-step thread WITHOUT the assistant question message (per Phase 6's ask-user contract: the step layer does not append the question).
   - `:chat_completed.result.thread` carries the final thread WITH the assistant question message appended (Phase 7's chat-layer append).

   Stream consumers tracking thread state across events MUST read `:chat_completed.result.thread` for the post-ask-user thread; reading `:step_completed.thread` as the "current thread" immediately after an ask-user halt yields a thread missing the question. The non-streaming `chat/3` has no asymmetry — `ChatResult.thread` always includes the question.

   Rationale for not emitting a synthetic `:message_completed` between `:step_completed` and `:chat_completed`: (a) re-emitting `:message_completed` would violate Phase 6 Non-obvious Decision #12 ("`:message_completed` is emitted exactly once per adapter turn"); (b) adding a new event variant (`:ask_user_message_appended` or similar) is a breaking change for every reducer per AGENT_DESIGN_SPEC; (c) the documented single-source-of-truth for the final thread is `ChatResult.thread`, reachable through both paths. The cost is an asymmetry that must be documented; the alternative is a breaking event-protocol change.

   Test bullet at 7.4.1: build an ask-user Fake fixture; reduce `stream/3` and assert: `step_completed_event.thread` does NOT contain a message with `metadata.ask_user == true` as its last element; `chat_completed_event.result.thread` DOES contain it as the last message. Assert equality: `chat_completed.result.thread == Chat.run/3(same_inputs).thread`.
8. `max_turns` precedence per Non-obvious Decision #9: call opts > engine.params > app config > library default (8).
9. `halt_when` exceptions propagate to the consumer (not caught by the orchestrator).

**Error reason table (synchronous return from `run/3` and `stream/3`):**

| Function | Error reason | Recovery guidance |
|----------|--------------|--------------------|
| `run/3`, `stream/3` | `%EngineError{reason: :missing_adapter}` | Construct engine with `:adapter`. Inherited from Phase 5. |
| `run/3`, `stream/3` | `%EngineError{reason: :missing_stream_adapter}` | Adapter doesn't implement `ALLM.StreamAdapter`. Inherited from Phase 5. |
| `run/3`, `stream/3` | `%EngineError{reason: :unknown_tool, metadata: %{tool_name: name}}` | Pre-flight unknown tool. Inherited from Phase 6. |
| `run/3`, `stream/3` | `%ValidationError{reason: :invalid_thread \| :invalid_request}` | Inherited from Phase 6. |
| `run/3`, `stream/3` | `%AdapterError{reason: _}` | Adapter pre-flight error. Inherited from Phase 5. |
| `run/3`, `stream/3` | `ArgumentError` via `validate_max_turns!/1` at entry | `max_turns` must be a `pos_integer()`. The check fires before any adapter call. Both `run/3` and `stream/3` validate at entry (raised synchronously in the call-site process). |

**Halt-reason table for `ChatResult.halted_reason`:**

| Reason | Fires when | `metadata` keys populated |
|--------|------------|---------------------------|
| `:completed` | Adapter `finish_reason ∈ {:stop, :length, :content_filter}` | `%{}` |
| `:error` | Adapter `finish_reason: :error` (mid-stream adapter error, inherited from Phase 5's §10.1 contract) | `%{error: error_struct}` (when present) |
| `:max_turns` | `step_index + 1 >= max_turns` after a step that didn't otherwise halt | `%{max_turns: N}` |
| `:halt_when` | `halt_when.(step_result)` returns `true` | `%{halt_when_step_index: idx}` |
| `:ask_user` | Handler returned `{:ask_user, _}` or `{:ask_user, _, _}` | `%{pending_question: q, pending_tool_call_id: id, ask_user_opts: opts}` (also populates top-level `:pending_question` and `:pending_tool_call_id` on `%ChatResult{}`) |
| `:tool_error` | `on_tool_error: :halt` fired, or function form returned `:halt`, or function form itself raised | `%{halt_tool_call_id: id}` (plus `:on_tool_error_exception` if function raised) |
| `:manual_tool_calls` | `mode: :manual` and step's `response.finish_reason == :tool_calls` | `%{manual_turn_index: idx}` |
| atom() (user) | Handler returned `{:halt, reason, result}` with `reason` not in the above set | `%{halt_tool_call_id: id, halt_result: result}` |

**Idiomatic Elixir requirements:**

- `Enum.reduce_while/3` for the non-streaming loop (over `1..max_turns // 1` or an explicit accumulator; both are canonical).
- `Stream.resource/3` for the streaming loop, reusing the continuation idiom from Phase 6 (`&Enumerable.reduce(sub_stream, &1, fn e, _ -> {:suspend, e} end)`). Verified in IEx on OTP 27 on 2026-04-24: `Enumerable.reduce/3` suspends correctly on multi-level composition (inner `Stream.resource` driven from outer `Stream.resource` via this idiom).
- `cond do ... end` for `terminal_condition/4` — matches Elixir's idiomatic branching where the clauses don't share a discriminant.
- `with`-chain at the `run/3` and `stream/3` entry for thread validation and first-step pre-flight.

### `ALLM.ToolRunner` (Layer C — Phase 7 amendment)

```elixir
defmodule ALLM.ToolRunner do
  # Phase 7 extends @type run_opts[:on_tool_error] from `:continue | :halt`
  # to `:continue | :halt | (ToolCall.t(), term() -> {:continue, term()} | :halt)`.
  # Phase 6's ArgumentError guard on function form is removed.

  @type on_tool_error ::
          :continue
          | :halt
          | (ToolCall.t(), error_term :: term() -> {:continue, term()} | :halt)

  @type run_opts :: [
          # ...Phase 6 fields unchanged...
          on_tool_error: on_tool_error(),
          # ...remaining fields unchanged...
        ]
end
```

**Invariants (additions to Phase 6's):**

1. **Function-form dispatch.** When `on_tool_error` is a function, `ToolRunner` invokes it inside the `Task.async_stream/5` task AFTER the handler's return / encoder raise is resolved to an error term. The function receives `(tool_call :: %ToolCall{}, error :: term())` and must return `{:continue, term()}` or `:halt`.
2. **`{:continue, replacement}` path.** The runner encodes `replacement` via the same tool-result encoder used for `{:ok, _}` returns. Encoder failures on `replacement` are wrapped as `%ToolError{reason: :encoding_failed}` and NOT re-routed through `on_tool_error` — instead they are treated as `:halt` (no infinite recursion). Same behaviour as Phase 6's `:continue` default on encoder failure; only the routing differs.
3. **`:halt` return path.** Identical to the `:halt` atom-form path: batch drains to completion (sibling-drain per Phase 6 Invariant 3), runner returns `{:ok, msgs, halt_meta}` with `halted_reason: :tool_error`.
4. **Function raises.** Caught via `try/rescue`, wrapped as `%ToolError{reason: :invalid_return, cause: exception, metadata: %{on_tool_error_raised: true}}`, and treated as `:halt`. The exception is surfaced via `ChatResult.metadata.on_tool_error_exception` at the chat layer.
5. **Atom-form behaviour unchanged.** `:continue` and `:halt` atoms behave identically to Phase 6.

**Error reason table (updates to Phase 6's):**

| Condition | Return / behaviour |
|-----------|--------------------|
| `on_tool_error` is a fun and returns `{:continue, replacement}` | `replacement` encoded as tool-result content; batch continues. |
| `on_tool_error` is a fun and returns `:halt` | Batch drains; final return `{:ok, msgs, %{halted_reason: :tool_error, halt_tool_call_id: id}}`. |
| `on_tool_error` is a fun and returns an invalid shape (neither `{:continue, _}` nor `:halt`) | Wrapped as `%ToolError{reason: :invalid_return, metadata: %{on_tool_error_invalid: true}}` and treated as `:halt`. Test asserts this specific shape. |
| `on_tool_error` is a fun and raises | Caught, wrapped as `%ToolError{reason: :invalid_return, cause: exception}`, treated as `:halt`. |

**Idiomatic Elixir requirements:**

- Function-form arity check at call-site: `is_function(on_tool_error, 2)`. If `on_tool_error` is a function of any other arity, raise `ArgumentError` at `run_tool_calls/3` entry (before spawning tasks) with a message pointing to the `(tool_call, error)` signature.
- The Phase-6 `raise ArgumentError` on function-form is removed. Replaced with dispatch.
- **Recursion-avoidance call path (load-bearing).** Phase 6's atom-form `route_error/3` (in `lib/allm/tool_runner.ex`) is the single dispatch point that maps an error term to `:continue` or `:halt`. Phase 7's function-form lives in a SEPARATE code path that resolves the function's return to a concrete `:continue` or `:halt` decision FIRST, then constructs a `ctx_for_halt = %{ctx | on_tool_error: :halt}` (or `:continue`) and only THEN delegates to `route_error/3`. The function reference is DROPPED from `ctx` before `route_error` runs, so a re-entry into the same code path with the same function is impossible. Concretely, when the function raises (or returns an invalid shape), the wrapped `%ToolError{}` is routed through `route_error/3` with `ctx_for_halt`, NOT with the original ctx — preventing the function from being called again. Test bullet at 7.2.1 (function-form raises): use an `Agent` to count function invocations per tool call; assert exactly ONE invocation per tool call regardless of return shape.

### `ALLM.StreamCollector` (Layer C — Phase 7 amendment)

```elixir
defmodule ALLM.StreamCollector do
  # Phase 7 adds :chat_result and (re-documents the already-committed :steps
  # field for Phase 7's usage). :pending_step_state is NOT added — the
  # per-step reset approach (Non-obvious Decision #6) operates on existing
  # fields directly.

  @type state :: %__MODULE__{
          # ...Phase 5 + 6 fields unchanged...
          chat_result: ChatResult.t() | nil   # Phase 7 addition
        }

  defstruct [
    # ...Phase 5 + 6 defaults unchanged...
    chat_result: nil                           # Phase 7 addition
  ]
end
```

**Phase 7 fold clauses (inserted immediately before the catch-all per Phase 5 Non-obvious Decision #5, AFTER Phase 6's clauses):**

```elixir
def apply_event(
      %__MODULE__{} = state,
      {:step_completed, %{response: %Response{} = response, thread: %Thread{} = thread}}
    ) do
  # Step 1: Build StepResult from the PRE-RESET collector state.
  # `step_done?(state)` and `state.halt` and `state.tool_results` MUST be
  # read here — the map-update below replaces them with reset defaults,
  # but Elixir map-update returns a NEW struct, so the references on the
  # right-hand side of `step_result = ...` see the original `state`.
  # An implementer who refactors this into "compute reset_state first,
  # then derive StepResult from reset_state" silently breaks done?/metadata.
  step_result = %StepResult{
    thread: thread,
    response: response,
    tool_results: state.tool_results,
    done?: step_done?(state),
    metadata: merge_halt_metadata(%{}, state.halt)
  }

  # Step 2: Append step + reset per-step sub-state.
  %{
    state
    | steps: state.steps ++ [step_result],
      thread: thread,
      # Reset per-step sub-state for the next step's events.
      current_text: "",
      current_tool_calls: %{},
      tool_call_order: [],
      tool_results: [],
      halt: nil,
      finish_reason: nil,
      raw_finish_reason: nil,
      last_message: nil
      # Note: :error and :metadata are NOT reset.
      #   * :error persists across steps so mid-stream adapter errors
      #     surface in the to_chat_result/1 fallback.
      #   * :metadata persists per the Phase 5 contract — adapter-side
      #     metadata accumulated during prior steps is part of the
      #     collector's running state, not per-step. Phase 6/7 never
      #     write to :metadata at the step layer, so accumulation is
      #     monotonic and safe.
  }
end

def apply_event(
      %__MODULE__{} = state,
      {:chat_completed, %{result: %ChatResult{} = chat_result}}
    ) do
  %{state | chat_result: chat_result, done?: true}
end
```

**`to_chat_result/1` amendment:**

```elixir
def to_chat_result(%__MODULE__{chat_result: %ChatResult{} = stored}), do: stored

def to_chat_result(%__MODULE__{thread: nil}),
  do: raise(ArgumentError, "StreamCollector.to_chat_result/1 requires a thread; ...")

def to_chat_result(%__MODULE__{thread: %Thread{} = thread} = state) do
  # Fallback — no :chat_completed was folded. The orchestrator never
  # reached a terminal decision; the consumer halted the stream early.
  # Always :cancelled, EXCEPT when a mid-stream adapter error was folded
  # (in which case :error preserves the error signal for logging
  # consumers). Non-empty state.steps alongside :cancelled indicates
  # "the consumer observed N clean step completions before halting" —
  # a common logging/debug shape.
  halted_reason = if state.error, do: :error, else: :cancelled

  final_response =
    case state.steps do
      [] -> to_response(state)
      steps -> List.last(steps).response
    end

  %ChatResult{
    thread: thread,
    final_response: final_response,
    steps: state.steps,
    halted_reason: halted_reason,
    metadata: state.metadata
  }
end
```

**Invariants:**

1. `:step_completed` fold appends a `%StepResult{}` to `:steps` and resets per-step sub-state (`:current_text`, `:current_tool_calls`, `:tool_call_order`, `:tool_results`, `:halt`, `:finish_reason`, `:raw_finish_reason`, `:last_message`). `:error` is NOT reset.
2. `:chat_completed` fold stores the event's `:result` verbatim in `:chat_result` and sets `:done? = true`.
3. `to_chat_result/1` prefers the stored `:chat_result`. Fallback path (no stored result): computes halted_reason from state, final_response from last step (or thread-only response for step-less cancellation).
4. Totality preserved: new clauses are total over their declared shape; malformed events fall through to the catch-all.
5. First-chat-result-wins: a second `:chat_completed` event would overwrite the first. Phase 7's emitter produces exactly one, so this is irrelevant in practice, but the behaviour is documented as "last-wins" (matching Elixir's normal map-update semantics).
6. Thread-less fallback when `:chat_result == nil` AND `:thread == nil` raises `ArgumentError` (matching Phase 6's existing behaviour).

**Idiomatic Elixir requirements:**

- `state.steps ++ [step_result]` — list concatenation at the tail. Bounded by `max_turns` (default 8). Prepend + reverse in `to_chat_result/1` is rejected as premature optimisation.
- Struct-literal construction for the fallback `%ChatResult{}` branch.

### `ALLM` (Layer C — public facade additions)

```elixir
defmodule ALLM do
  @spec chat(Engine.t(), Thread.t() | [Message.t()], keyword()) ::
          {:ok, ChatResult.t()} | {:error, EngineError.t() | AdapterError.t() | ValidationError.t()}
  def chat(engine, thread_or_messages, opts \\ []),
    do: ALLM.Chat.run(engine, thread_or_messages, opts)

  @spec stream(Engine.t(), Thread.t() | [Message.t()], keyword()) ::
          {:ok, Enumerable.t()} | {:error, EngineError.t() | AdapterError.t() | ValidationError.t()}
  def stream(engine, thread_or_messages, opts \\ []),
    do: ALLM.Chat.stream(engine, thread_or_messages, opts)
end
```

**Invariants:**

1. Both functions are pure one-line delegations — no logic beyond the delegation. Keeps the facade a transparent entry point and doctests simple.
2. Doctests on both functions use `ALLM.Providers.Fake` with a multi-turn fixture from `ALLM.Test.FakeFixtures`.

## Module Tree

```
lib/allm/
├── stream_collector.ex                     (MODIFY — add :chat_result field; two new fold clauses for :step_completed and :chat_completed; to_chat_result/1 stored-vs-computed branch)
├── tool_runner.ex                          (MODIFY — on_tool_error function form: remove ArgumentError guard, add dispatch inside Task.async_stream/5)
├── chat.ex                                 (MODIFY — add run/3, stream/3, build_chat_result/1, terminal_condition/4; add Chat.LoopState sub-struct)
└── chat/
    └── loop_state.ex                       (NEW — ALLM.Chat.LoopState, Phase 7-internal struct)

lib/allm.ex                                 (MODIFY — add chat/3 and stream/3)

test/allm/
├── stream_collector_test.exs               (MODIFY — tests for 2 new fold clauses, to_chat_result/1 stored-vs-computed branch)
├── tool_runner_test.exs                    (MODIFY — tests for on_tool_error function form: {:continue, _}, :halt, invalid shape, raises)
├── chat_run_test.exs                       (NEW — Chat.run/3 unit tests)
├── chat_stream_test.exs                    (NEW — Chat.stream/3 unit tests)
├── allm_chat_test.exs                      (NEW — facade + doctest)
├── allm_stream_test.exs                    (NEW — facade + doctest)
├── chat_equivalence_test.exs               (NEW — property: chat ≡ stream |> collect_chat_result)
└── providers/
    └── fake_scenarios_test.exs             (MODIFY — flip 2 @tag :pending → active; add 1 new active manual-mode test)

test/support/
└── assertions.ex                           (MODIFY — add assert_equivalent_chat_result/2 helper)

CHANGELOG.md                                (MODIFY — one line per new public symbol + scenario activations)
```

Test files mirror source files 1:1. No `test/support/fake_fixtures.ex` changes required if Phase 4 already ships a `multi_turn_tool_call_then_text/2` fixture; otherwise Phase 7.1 adds one (verify at phase start).

## Phases

### Sub-phase 7.1: `StreamCollector` extension (Layer C)

**Goal:** Extend `ALLM.StreamCollector` with fold clauses for `:step_completed` and `:chat_completed`, add the `:chat_result` field, and update `to_chat_result/1` with the stored-vs-computed branch.

**Spec sections:** §8 (existing closed union), §13.1 (StreamCollector).

#### 7.1.1 Test Plan (write first)

`test/allm/stream_collector_test.exs` (MODIFY — add):

**`:step_completed` fold:**
- `apply_event(state, {:step_completed, %{response: r, thread: t}})` appends a `%StepResult{}` to `state.steps`; the step result's `:response` matches `r`, `:thread` matches `t`, `:tool_results` matches `state.tool_results` (the per-step accumulated tool results).
- After the fold, `state.current_text == ""`, `state.current_tool_calls == %{}`, `state.tool_call_order == []`, `state.tool_results == []`, `state.halt == nil`, `state.finish_reason == nil`, `state.raw_finish_reason == nil`, `state.last_message == nil`.
- The APPENDED `%StepResult{}` carries the PRE-RESET values of `:tool_results`, `:halt`, and `:done?` — verify by setting up a collector with `state.tool_results = [msg]`, `state.halt = {:halt, :foo, "id"}`, then folding `:step_completed` and asserting `List.last(state.steps).tool_results == [msg]` and `metadata.halted_reason == :foo`.
- `state.metadata` is NOT reset by the fold — verify by setting `state.metadata = %{adapter_meta: 1}`, folding `:step_completed`, then asserting `state.metadata == %{adapter_meta: 1}`.
- `state.thread` is updated to `t` (the step's terminal thread becomes the new input thread for the next step).
- `state.error` is NOT reset: if `state.error` was set to `%AdapterError{}` before the `:step_completed` fold, it's still set afterward.
- Two `:step_completed` folds in sequence produce `state.steps` with length 2; subsequent Phase-5 adapter events fold cleanly into the freshly-reset per-step sub-state.

**`:chat_completed` fold:**
- `apply_event(state, {:chat_completed, %{result: %ChatResult{}}})` sets `state.chat_result` to the event's payload and `state.done? = true`.
- A second `:chat_completed` event overwrites the first (last-wins, matching Elixir map-update semantics) — test asserts this behaviour is deterministic even if it's not a shape the orchestrator produces.

**`to_chat_result/1` stored-vs-computed:**
- With `state.chat_result` set: `to_chat_result(state)` returns the stored `%ChatResult{}` verbatim (even when `state.thread == nil` — the stored result is authoritative).
- With `state.chat_result == nil` and `state.thread` set: falls back to computing. Verify (three branches):
  - `halted_reason: :cancelled` when `state.error == nil` and `state.steps == []` (zero-step cancellation).
  - `halted_reason: :cancelled` when `state.error == nil` and `length(state.steps) > 0` (partial-step cancellation — the consumer observed some steps but halted before `:chat_completed`). This is the Q2 Option B semantic: non-empty `steps` does NOT promote to `:completed`.
  - `halted_reason: :error` when `state.error != nil` (adapter error folded mid-stream). Takes precedence over `:cancelled`.
- `final_response` in the fallback is the LAST step's response when `steps != []`, or `to_response(state)` otherwise.
- With `state.chat_result == nil` and `state.thread == nil`: raises `ArgumentError`.
- `final_response` in the fallback is the LAST step's response (when steps is non-empty) or `to_response(state)` (thread-less case... but wait, thread-less collectors can't reach this branch because `thread: nil` raises). Clarify: when `thread` is set and `steps == []`, `final_response` is `to_response(state)` — a response built from the current collector state (which reflects only adapter events received before the consumer halted).

**Totality:**
- Every prior totality test (`stream_collector_test.exs` from Phases 5 and 6) continues to pass: unknown tags, malformed payloads, etc. fall through to the catch-all.

#### 7.1.2 Implementation Checklist

- [ ] Add `:chat_result` field to `%StreamCollector{}` struct with default `nil`.
- [ ] Add `@type state :: %__MODULE__{...chat_result: ChatResult.t() | nil}` addition.
- [ ] Insert two new fold clauses (`:step_completed`, `:chat_completed`) immediately before the catch-all per Phase 5 Non-obvious Decision #5.
- [ ] Update `to_chat_result/1`: add the stored-result short-circuit clause as the first clause; update the existing clause to be the fallback; handle `state.chat_result == nil and state.thread == nil` with `ArgumentError` per existing Phase 5 behaviour.
- [ ] Update the `@moduledoc` "Fold semantics" table with two new rows.
- [ ] Add a "Phase 7 extension" paragraph in the `@moduledoc`.
- [ ] Add tests from the test plan above.

#### 7.1.3 Verification

```bash
mix test test/allm/stream_collector_test.exs
mix test                                    # regression — Phase 5/6 tests still green
mix test --cover                             # ≥90% on lib/allm/stream_collector.ex
mix credo --strict lib/allm/stream_collector.ex
mix dialyzer
mix format --check-formatted
```

### Sub-phase 7.2: `ALLM.ToolRunner` — `on_tool_error` function form (Layer C)

**Goal:** Remove Phase 6's `ArgumentError` guard on `on_tool_error` function form; implement per-tool-call dispatch inside `Task.async_stream/5` tasks.

**Spec sections:** §30 (tool error policy — full function form).

#### 7.2.1 Test Plan (write first)

`test/allm/tool_runner_test.exs` (MODIFY — add):

**Function form — `{:continue, replacement}`:**
- Handler returns `{:error, :bad_arg}`; `on_tool_error: fn _tc, _err -> {:continue, %{fallback: "ok"}} end` → tool-result content is the encoded `%{fallback: "ok"}` (JSON `"{\"fallback\":\"ok\"}"`); batch continues.
- Function receives `(%ToolCall{}, error_term)` — assert via a function that records its args into an Agent and inspect post-hoc; `%ToolCall{}` matches the calling tool's id/name; `error_term` is the raw `{:error, _}` or `%ToolError{}`.

**Function form — `:halt`:**
- Handler returns `{:error, :bad_arg}`; `on_tool_error: fn _, _ -> :halt end` → batch drains, returns `{:ok, msgs, %{halted_reason: :tool_error, halt_tool_call_id: "c0"}}`.

**Function form — encoder failure on replacement:**
- Handler returns `{:error, :bad}`; `on_tool_error: fn _, _ -> {:continue, make_ref()} end` → replacement is non-JSON-encodable; encoder raises; wrapped as `%ToolError{reason: :encoding_failed}`; routed as `:halt` (no infinite recursion through `on_tool_error`).

**Function form — invalid return:**
- `on_tool_error: fn _, _ -> :something_else end` → wrapped as `%ToolError{reason: :invalid_return, metadata: %{on_tool_error_invalid: true}}`; treated as `:halt`.

**Function form — raises:**
- `on_tool_error: fn _, _ -> raise "oops" end` → caught; wrapped as `%ToolError{reason: :invalid_return, cause: %RuntimeError{message: "oops"}, metadata: %{on_tool_error_raised: true}}`; treated as `:halt`.
- **Single-invocation invariant.** Use an `Agent.start_link(fn -> 0 end)` counter; the test function increments on entry. After the batch completes (success / `:halt` / raise / invalid return), assert the counter equals `length(tool_calls_with_errors)` — the function MUST run exactly once per error case, never twice (proves the recursion-avoidance call path is correct).

**Function form — arity check:**
- `on_tool_error: fn _err -> :halt end` (arity 1) → `ArgumentError` raised at `run_tool_calls/3` entry, BEFORE any task is spawned. Message points to the `(tool_call, error)` signature.

**Atom form unchanged:**
- All Phase 6 `:continue` and `:halt` atom-form tests continue to pass.

**Reserved-atom handler halt rejection (spec §5.2 "do not reuse"):**
- Handler returns `{:halt, :tool_error, %{}}` → ToolRunner converts to `%ToolError{reason: :invalid_return, metadata: %{reserved_halt_atom: :tool_error}}`. With `on_tool_error: :continue`, the tool-result message's content is the encoded error (`%{"error" => "handler returned {:halt, :tool_error, _}; :tool_error is reserved..."}`); with `on_tool_error: :halt`, batch halts with `halted_reason: :tool_error`.
- Parameterised over the six reserved atoms (`:ask_user`, `:max_turns`, `:halt_when`, `:tool_error`, `:cancelled`, `:completed`) — each gets its own test case asserting the `metadata.reserved_halt_atom` key carries the attempted reserved atom verbatim.
- Non-reserved atoms (`:plan_submitted`, `:budget_exceeded`, etc.) continue to produce `{:ok, msgs, %{halted_reason: <user atom>, halt_result: result}}` unchanged.
- Attribute check: `@reserved_halt_atoms` in `lib/allm/tool_runner.ex` equals exactly `[:ask_user, :max_turns, :halt_when, :tool_error, :cancelled, :completed]` (verified against spec §5.2 line 229 on 2026-04-24); a meta-test asserts the attribute's MapSet equals the spec's stated set so future spec changes to §5.2 trigger a test failure on import.

#### 7.2.2 Implementation Checklist

- [ ] Update `@type on_tool_error` to include the function form.
- [ ] Update the `@spec` for `run_tool_calls/3` and `stream_tool_calls/3`.
- [ ] Remove the Phase 6 `ArgumentError` guard on function form.
- [ ] Add arity check at `run_tool_calls/3` entry: `is_function(on_tool_error, 2) or on_tool_error in [:continue, :halt]`; raise `ArgumentError` otherwise.
- [ ] Add `@reserved_halt_atoms [:ask_user, :max_turns, :halt_when, :tool_error, :cancelled, :completed]` module attribute to `lib/allm/tool_runner.ex`.
- [ ] Add one more pattern clause to the handler-return dispatcher in `execute_one_tool/3`: `{:halt, reason, _result} when reason in @reserved_halt_atoms -> {:error, %ToolError{reason: :invalid_return, metadata: %{reserved_halt_atom: reason}, message: "..."}}`. Ensure this clause is ordered BEFORE the general `{:halt, reason, result}` clause.
- [ ] Inside the `execute_one_tool/3` helper (or equivalent per current implementation), when the handler / encoder produces an error term, branch on `on_tool_error`:
  - atom `:continue` / `:halt` → unchanged path from Phase 6
  - function → invoke inside `try/rescue`, dispatch on return value.
- [ ] Ensure the function-form call is SYNCHRONOUS inside the task (no new process spawn).
- [ ] Update `@moduledoc` with a "Function form semantics" paragraph.
- [ ] Update the error reason table in `@doc`.
- [ ] Add tests from the test plan above.

#### 7.2.3 Verification

```bash
mix test test/allm/tool_runner_test.exs
mix test                                    # Phase 6 regression
mix test --cover                             # ≥90% on lib/allm/tool_runner.ex
mix credo --strict lib/allm/tool_runner.ex
mix dialyzer
mix format --check-formatted
```

### Sub-phase 7.3: `ALLM.Chat.run/3` (Layer C)

**Goal:** Ship the multi-turn non-streaming orchestrator. Loops `Chat.step/3` calls, applies `terminal_condition/4` after each step, appends ask-user question messages at the turn boundary, returns `%ChatResult{}`.

**Spec sections:** §4, §10.5, §12, §12.3, §17, §19, §30.

#### 7.3.1 Test Plan (write first)

`test/allm/chat_run_test.exs` (NEW):

**Happy path — single-turn text:**
- Fake scripts `{:text, "hello"}` + `{:finish, :stop}`; `run/3` returns `ChatResult` with `halted_reason: :completed`, `steps: [one_step]`, `final_response.output_text: "hello"`.

**Happy path — two-turn tool call:**
- Fake scripts two turns: `{:tool_call, id: "c0", name: "echo", arguments: %{x: 1}}` + `{:finish, :tool_calls}`, then `{:text, "done"}` + `{:finish, :stop}`. Tool handler `fn args -> {:ok, args} end`. `run/3` returns `halted_reason: :completed`, `length(steps) == 2`, `final_response.output_text: "done"`. Thread has 4 messages: user, assistant (with tool_calls), tool, assistant ("done").

**`max_turns` cap:**
- Fake scripts N turns of `{:tool_call, ...}` + `{:finish, :tool_calls}`. `run/3` with `max_turns: 2` halts after step 2. `halted_reason: :max_turns`; `ChatResult.metadata.max_turns == 2`; `length(steps) == 2`.
- `max_turns: 1` halts after one step regardless of finish_reason.
- `max_turns: 8` (default) is the library default; verify by omitting the opt.
- `max_turns: 0` raises `ArgumentError` from `validate_max_turns!/1` at `run/3` entry; no adapter call occurs.
- `max_turns: -1`, `max_turns: nil` (after precedence chain resolves to `nil`), `max_turns: 1.5`, `max_turns: "8"` — all raise `ArgumentError` at entry.

**`halt_when` fires mid-loop:**
- Fake scripts two turns. `halt_when: fn sr -> length(sr.tool_results) > 0 end`. After step 1 (which has a tool_result), `halt_when` returns true; loop halts. `halted_reason: :halt_when`; `ChatResult.metadata.halt_when_step_index == 0`; `length(steps) == 1`.

**`halt_when` never fires:**
- `halt_when: fn _ -> false end` → runs until another condition fires. Verify with a fixture that ends in `:finish, :stop` — `halted_reason: :completed`.

**`halt_when` raises:**
- `halt_when: fn _ -> raise "user bug" end` → the raise propagates out of `run/3` (NOT caught). Test asserts the raise reaches the caller.

**`on_tool_error: :continue` (default):**
- Handler raises; batch continues; the step's `tool_results` contains an encoded error message; `halted_reason: :completed` (loop proceeds to next turn and ends there).

**`on_tool_error: :halt`:**
- Handler raises; batch halts at first error; `halted_reason: :tool_error`; `ChatResult.metadata.halt_tool_call_id == "c0"`.

**`on_tool_error: fun`:**
- `on_tool_error: fn %ToolCall{name: "echo"}, _err -> {:continue, %{replaced: true}} end` → tool-result content is encoded `%{replaced: true}`; loop continues.
- `on_tool_error: fn _, _ -> :halt end` → `halted_reason: :tool_error`.

**Handler `{:halt, :plan_submitted, %{ok: 1}}`:**
- Fake's tool returns `{:halt, :plan_submitted, %{ok: 1}}`; `halted_reason: :plan_submitted` (user custom atom); `ChatResult.metadata.halt_result == %{ok: 1}`; `length(steps) == 1`; thread has the tool-result message with the encoded `%{ok: 1}` content.

**Handler `{:halt, <reserved atom>, _}` — rejected:**
- For each reserved atom (`:ask_user`, `:max_turns`, `:halt_when`, `:tool_error`, `:cancelled`, `:completed`): a tool handler returning `{:halt, reason, _}` with that atom is treated as `%ToolError{reason: :invalid_return, metadata: %{reserved_halt_atom: reason}}` by `ToolRunner`. With `on_tool_error: :continue` (default), the batch continues and the tool-result message's content is the encoded error. With `on_tool_error: :halt`, `ChatResult.halted_reason == :tool_error` — NOT the reserved atom. Test each reserved atom once; verify the `metadata.reserved_halt_atom` key carries the attempted atom for observability.

**Handler `{:ask_user, "which city?", [choices: ["A", "B"]]}`:**
- After the step runs, `run/3` appends `%Message{role: :assistant, content: "which city?", metadata: %{ask_user: true, tool_call_id: "c0"}}` to the thread. `ChatResult.halted_reason == :ask_user`; `ChatResult.pending_question == "which city?"`; `ChatResult.pending_tool_call_id == "c0"`; `ChatResult.metadata.ask_user_opts == [choices: ["A", "B"]]`. The LAST message in `ChatResult.thread.messages` is the assistant question.

**`mode: :manual` halts on first tool-calls turn:**
- Fake scripts `{:tool_call, ...}` + `{:finish, :tool_calls}`; `run/3` with `mode: :manual` → `halted_reason: :manual_tool_calls`; `length(steps) == 1`; `hd(steps).tool_results == []`; `ChatResult.metadata.manual_turn_index == 0`; `ChatResult.final_response.tool_calls` has the tool call.

**`mode: :manual` on text-only turn → continues:**
- Fake scripts `{:text, "hi"}` + `{:finish, :stop}`; `run/3` with `mode: :manual` → `halted_reason: :completed` (no tool calls to surface; loop terminates naturally).

**Adapter pre-flight error:**
- Engine with no adapter → `run/3` returns `{:error, %EngineError{reason: :missing_adapter}}` BEFORE constructing any `ChatResult`.

**Mid-loop adapter error:**
- Fake scripts first turn `{:tool_call, ...}` + `{:finish, :tool_calls}`, second turn `{:error, "rate limited"}`. First turn completes normally (tool executes); second turn's adapter error surfaces as `response.finish_reason: :error` on that step; loop halts; `halted_reason: :error`; `ChatResult.metadata.error` is the error struct; `length(steps) == 2`.

**Empty thread:**
- `run/3` with an empty `[]` list of messages → validation error from Phase 6 passes through; `{:error, %ValidationError{reason: :invalid_request | :invalid_thread}}` (depending on which layer validates empty first — per Phase 1 `Validate.request/1` rejects empty messages).

**Terminal-condition ordering pairs:**
- Handler returns `{:ask_user, _}` AND `halt_when` would return true → `:ask_user` wins. Verify.
- Handler returns `{:halt, :custom, _}` AND `halt_when` would return true → custom atom wins.
- `on_tool_error: :halt` fires AND `halt_when` would return true → `:tool_error` wins.
- `mode: :manual` AND `halt_when` would return true on the manual step → `:manual_tool_calls` wins (because `halt_when` is never consulted in manual mode).
- `max_turns` would fire AND `halt_when` returns true on the last step → `:halt_when` wins (halt_when runs before max_turns check per the `cond` order).
- Adapter `finish_reason: :stop` AND `halt_when` returns true → `:completed` wins (finish_reason branch is checked before halt_when branch per the cond).

#### 7.3.2 Implementation Checklist

- [ ] `lib/allm/chat/loop_state.ex` — new `%Chat.LoopState{}` struct with `@moduledoc false`.
- [ ] `lib/allm/chat.ex` — add `run/3`, `build_chat_result/1`, `terminal_condition/4` with the six-branch `cond` from Non-obvious Decision #5.
- [ ] `run/3` implementation:
  - Call `validate_max_turns!/1` at entry: `max_turns` must be a `pos_integer()`; raise `ArgumentError` with message `"max_turns must be a positive integer; got: <inspect(value)>"` for `0`, negative integers, non-integers, or `nil` after the precedence-chain resolution. Verified in IEx on OTP 27 on 2026-04-24: `is_integer(0) and 0 > 0` is `false`; `is_integer(-1) and -1 > 0` is `false`; the canonical guard for `pos_integer()` is `is_integer(n) and n > 0`.
  - Validate + normalise thread (reuse Phase 6's `normalise_thread/1`).
  - Init `%Chat.LoopState{}` with `initial_thread` and `thread`.
  - `Enum.reduce_while(0..(max_turns - 1), state, fn idx, state -> ... end)`: invoke `Chat.step/3`, pattern-match `{:ok, step_result}`, invoke `terminal_condition/4`, branch `{:halt, reason, meta} | :continue`.
  - On `{:halt, :ask_user, meta}`: append assistant question message to thread BEFORE building chat_result.
  - On other halt atoms: build chat_result from current state.
  - On `:continue`: increment `step_index`, thread the `step_result.thread` as new `state.thread`, accumulate step into `state.steps`, continue.
- [ ] `build_chat_result/1` — single construction point.
- [ ] `terminal_condition/4` — six-branch `cond`.
- [ ] `@doc` with multi-turn doctest (Fake two-turn fixture).
- [ ] `@spec` on every new public/private function matching the contract section.

#### 7.3.3 Verification

```bash
mix test test/allm/chat_run_test.exs
mix test                                    # Phase 5/6 regression
mix test --cover                             # ≥90% on lib/allm/chat.ex
mix credo --strict lib/allm/chat.ex lib/allm/chat/loop_state.ex
mix dialyzer
mix format --check-formatted
```

### Sub-phase 7.4: `ALLM.Chat.stream/3` (Layer C)

**Goal:** Ship the multi-turn streaming orchestrator via a two-phase `Stream.resource/3` driving `stream_step/3` sub-streams sequentially. Emit a terminal `:chat_completed` event.

**Spec sections:** §3, §4, §8 (emission site for `:chat_completed`), §10.6, §12, §12.3, §17, §19, §30.

#### 7.4.1 Test Plan (write first)

`test/allm/chat_stream_test.exs` (NEW):

**Event ordering across turns:**
- Fake multi-turn fixture; `stream/3 |> Enum.to_list/1`; all step 1 events (adapter events + tool-execution + `:step_completed`) precede all step 2 events precede `:chat_completed`. Specifically:
  - Every `:tool_call_started` in step 1 appears before any event in step 2.
  - The single `:step_completed` for step 1 appears before any step 2 event.
  - Exactly one `:chat_completed` — and it is the LAST event.
- Pattern-match on `:chat_completed` payload: it carries a `%ChatResult{}` with `halted_reason: :completed` (or whatever the fixture produces).

**Consumer halt — mid-step:**
- `stream/3 |> Enum.take(3)` — halts mid-adapter-stream in step 1. `after_fun` chain fires:
  - Outer `Chat.stream/3` after_fun halts `step_cont`.
  - `stream_step/3`'s three-phase after_fun halts `adapter_cont`.
  - Fake adapter's `Stream.resource/3` after_fun fires.
- No `:chat_completed` emitted. Verify by asserting the collected list doesn't contain `:chat_completed`.

**Consumer halt — at step boundary:**
- `stream/3 |> Stream.take_while(fn e -> not match?({:step_completed, _}, e) end) |> Enum.to_list/1` — halts right after the first step_completed. No second step's events; no `:chat_completed`.

**Single terminal `:chat_completed`:**
- Over any Fake fixture, count the `:chat_completed` events in `stream/3 |> Enum.to_list/1`. Exactly one, and it's the last element.

**Ask-user flow:**
- Fake scripts `{:tool_call, ...}` + `{:finish, :tool_calls}`; tool handler returns `{:ask_user, "which city?"}`. Stream emits:
  - Adapter events (text/tool_call_*).
  - `:tool_execution_started`, `:tool_execution_completed`, `:ask_user_requested`.
  - `:step_completed`.
  - `:chat_completed` with `ChatResult.halted_reason: :ask_user`, `pending_question: "which city?"`, and the thread's LAST message is the assistant question.

**Manual-mode flow:**
- Fake scripts `{:tool_call, ...}` + `{:finish, :tool_calls}`; `stream/3` with `mode: :manual`. Stream emits:
  - Adapter events (tool_call_*).
  - Phase B is skipped (no tool execution) — NO `:tool_execution_started`, `:tool_execution_completed`, `:tool_result_encoded` events.
  - `:step_completed`.
  - `:chat_completed` with `halted_reason: :manual_tool_calls`.

**`halt_when` mid-loop:**
- Fake scripts two turns; `halt_when: fn sr -> length(sr.tool_results) > 0 end`. Stream emits step 1's events through `:step_completed`, then `:chat_completed` with `halted_reason: :halt_when` — NO step 2 adapter events.

**`max_turns` mid-loop:**
- Fake scripts N turns of tool calls; `max_turns: 2`. Stream emits exactly 2 step-event-groups + `:chat_completed` with `halted_reason: :max_turns`.

**Adapter pre-flight error (first step):**
- Engine with no adapter → `stream/3` returns `{:error, %EngineError{reason: :missing_adapter}}` synchronously; no stream.

**Mid-loop adapter error:**
- Fake scripts first turn normally, second turn with `{:error, "rate limited"}`. Stream emits step 1's events, then step 2's `:error` event (from the adapter), then `:step_completed` with `response.finish_reason: :error`, then `:chat_completed` with `halted_reason: :error`.

**No `:message_started` / `:message_completed` synthesised for ask-user question:**
- The assistant question message appears in `ChatResult.thread.messages` (via the Phase F build step) but is NOT emitted as a separate `:message_started` / `:message_completed` event pair. Verify by counting message_started events against message_completed events per step — they match (no extra for the ask-user question).

#### 7.4.2 Implementation Checklist

- [ ] `lib/allm/chat.ex` — add `stream/3` implementation.
- [ ] Implement the two-phase state machine (`:step` / `:final` / `:done` tags) via `Stream.resource/3`.
- [ ] Init state: construct first `stream_step/3` enumerable, seed `step_cont` via the Phase-6 `Enumerable.reduce/3` continuation idiom.
- [ ] `stream_next({:step, data})`: pull next event from `step_cont`; on regular event, emit + fold; on `:step_completed` event, compute `%StepResult{}` from the event's payload (the step-layer already built it — Phase F's payload carries `response` and `thread`; combine with the outer collector's `state.tool_results` to form a StepResult equal to what non-streaming would produce); invoke `terminal_condition/4`; on `:halt`, build chat_result and transition to `:final`; on `:continue`, start next `stream_step/3` and loop.
- [ ] `stream_next({:final, data})`: emit `{:chat_completed, %{result: data.chat_result}}`; transition to `:done`.
- [ ] `stream_after/1`: pattern-match on state, halt active sub-cont.
- [ ] Update `@moduledoc` with "Multi-turn stream composition" section.
- [ ] Add doctest on `stream/3` using Fake multi-turn fixture.

**Detail — computing StepResult from :step_completed event payload.** The step-layer (Phase 6) emits `:step_completed` with `%{response: r, thread: t}` payload (see `lib/allm/event.ex:315-316`). The Phase-7 outer orchestrator needs a `%StepResult{}` to pass to `terminal_condition/4`. Build it by reading from the outer collector, which has folded every event for this step including `:tool_result_encoded`, `:tool_halt`, `:ask_user_requested`, and any `on_tool_error` halts:

```elixir
defp step_result_from_outer_collector(%StreamCollector{} = c, response, thread) do
  %StepResult{
    thread: thread,
    response: response,
    tool_results: c.tool_results,
    done?: step_done?(c),
    metadata: merge_halt_metadata(%{}, c.halt)
  }
end
```

**State-boundary ownership (load-bearing invariant).** Phase S MUST call `step_result_from_outer_collector/3` on the outer collector's state **BEFORE** folding the just-arrived `:step_completed` event into it. The Phase 7.1 fold clause for `:step_completed` resets `:tool_results`, `:halt`, `:current_text`, `:current_tool_calls`, `:tool_call_order`, `:finish_reason`, `:raw_finish_reason`, `:last_message`; reading after the fold would produce an empty StepResult. Concrete sequence inside `pull_next_phase_s/1` when the pulled event is `{:step_completed, _}`:

```elixir
{:suspended, {:step_completed, %{response: r, thread: t}} = event, next_cont} ->
  # 1. Read pre-fold state into a StepResult
  step_result = step_result_from_outer_collector(data.collector, r, t)
  # 2. NOW fold the :step_completed event (which resets per-step state)
  reset_collector = StreamCollector.apply_event(data.collector, event)
  # 3. Decide transition
  case terminal_condition(step_result, data.opts, data.step_index, t) do ...
```

Both steps 1 and 2 must fire — step 1 captures the StepResult; step 2 keeps the collector's `:steps` field accurate for the eventual chat-equivalence comparison. Test bullet at 7.4 asserts the StepResult's `:tool_results` matches the executed tool messages (non-empty for tool-call fixtures) — which would fail if the implementer reversed the order.

The helper is implemented as a private helper in `Chat`. Promote to `StreamCollector` if a second caller emerges.

#### 7.4.3 Verification

```bash
mix test test/allm/chat_stream_test.exs
mix test                                    # Phase 5/6/7.1/7.3 regression
mix test --cover                             # ≥90% on lib/allm/chat.ex (updated)
mix credo --strict lib/allm/chat.ex
mix dialyzer
mix format --check-formatted
```

### Sub-phase 7.5: Facade + equivalence + §31 scenarios (Layer C)

**Goal:** Expose `ALLM.chat/3` and `ALLM.stream/3` on the public facade; add the chat-equivalence property test; activate three §31 scenarios (two flipped from `@tag :pending`, one newly added).

**Spec sections:** §4 (facade); §31 (property scenarios).

#### 7.5.1 Test Plan (write first)

`test/allm/allm_chat_test.exs` (NEW):

**Facade delegation:**
- `ALLM.chat/3` delegates to `ALLM.Chat.run/3` — verify by asserting identical return shapes across both entry points for a Fake fixture.
- Doctest using a Fake two-turn fixture (tool_call → tool_result → stop).

`test/allm/allm_stream_test.exs` (NEW):

**Facade delegation:**
- `ALLM.stream/3` delegates to `ALLM.Chat.stream/3`.
- Doctest using a Fake two-turn fixture; reduce the stream to count events and assert exactly one `:chat_completed`.

`test/allm/chat_equivalence_test.exs` (NEW):

**Chat-equivalence property:**
- `StreamData` generator produces a chat-opts keyword list (`mode`, `max_turns`, `halt_when`, `on_tool_error` — all within legal ranges) and a Fake fixture name (from the shipped fixtures under `test/support/fake_fixtures.ex`).
- Property: `assert_equivalent_chat_result(Chat.run/3 result, Chat.stream/3 |> StreamCollector.to_chat_result/1)`.
- Run 100 iterations (default StreamData iteration count).
- `assert_equivalent_chat_result/2` sorts each step's `tool_results` by `tool_call_id` before comparing; asserts every other field exactly.

**Specific fixtures exercised by the property:**
- Happy multi-turn (tool_call → text).
- Multi-turn with `max_turns: 1`.
- Single-turn text.
- Multi-turn with `halt_when` that fires at step 1.
- Manual mode.
- Ask-user mid-loop.
- Handler custom halt atom.
- `on_tool_error: :halt`.
- `on_tool_error: fn _, _ -> {:continue, %{ok: 1}} end`.

`test/support/assertions.ex` (MODIFY):

**`assert_equivalent_chat_result/2`:**
- Asserts `halted_reason`, `pending_question`, `pending_tool_call_id`, `metadata` exactly.
- Asserts `final_response` via the existing Response-equivalence logic (inherited from Phase 6 step-equivalence — response's tool_calls are in adapter-emission order, deterministic).
- Asserts `thread.messages`: split into `:tool`-role (sorted by `tool_call_id`) and non-tool (exact order); concatenate back and compare.
- Asserts `steps` element-wise via `assert_equivalent_step_result/2`.

`test/allm/providers/fake_scenarios_test.exs` (MODIFY):

Flip three `@tag :pending` placeholders to active:
- **`max_turns` cap hit mid-loop**: Fake scripts N turns of tool_calls; `chat/3` with `max_turns: 2` → `halted_reason: :max_turns`, `metadata.max_turns == 2`.
- **`halt_when` returns true**: Two-turn Fake fixture; `halt_when: fn sr -> length(sr.tool_results) > 0 end` → `halted_reason: :halt_when`, `metadata.halt_when_step_index == 0`.
- **single tool call with `mode: :manual` — partial flow**: Single-turn Fake; `mode: :manual` → `halted_reason: :manual_tool_calls`, `final_response.tool_calls` has the call. Full session round-trip stays pending.

#### 7.5.2 Implementation Checklist

- [ ] `lib/allm.ex` — add `chat/3` and `stream/3` as one-line delegations with `@spec` and `@doc`.
- [ ] Each facade function's `@doc` includes options docs (`:mode`, `:max_turns`, `:halt_when`, `:on_tool_error` including function form), the halt-reason table, and a multi-turn doctest using Fake.
- [ ] `test/support/assertions.ex` — add `assert_equivalent_chat_result/2`.
- [ ] `test/allm/chat_equivalence_test.exs` — new StreamData property.
- [ ] `test/allm/allm_chat_test.exs` + `test/allm/allm_stream_test.exs` — facade tests + doctests.
- [ ] `test/allm/providers/fake_scenarios_test.exs` — flip two `@tag :pending` markers (`max_turns`, `halt_when`); add one new active test for `mode: :manual` partial flow.
- [ ] CHANGELOG entries.

#### 7.5.3 Verification

```bash
mix test                                                       # full regression
mix test test/allm/chat_equivalence_test.exs --trace           # property test observable
mix test test/allm/providers/fake_scenarios_test.exs           # §31 scenarios active
mix test --cover                                               # ≥90% on changed files; ≥80% global
mix credo --strict
mix dialyzer
mix format --check-formatted
```

## Test Plan (cross-phase)

**Unit tests (per module):**

- `ALLM.StreamCollector` — two new fold clauses, `to_chat_result/1` stored-vs-computed, totality preservation.
- `ALLM.ToolRunner` — function-form `on_tool_error` (continue / halt / invalid / raise / arity check).
- `ALLM.Chat.run/3` — see Sub-phase 7.3 test plan.
- `ALLM.Chat.stream/3` — see Sub-phase 7.4 test plan.
- `ALLM.Chat.LoopState` — construction + invariant tests (though the struct is internal; happy-path coverage is via `Chat.run/3` + `Chat.stream/3`).

**Behaviour conformance tests:** No new behaviours. Existing `ALLM.Test.AdapterConformance` and `ALLM.Test.StreamAdapterConformance` harnesses unchanged.

**Integration tests:**

- Facade delegation (`ALLM.chat/3` → `Chat.run/3`; `ALLM.stream/3` → `Chat.stream/3`).
- Chat-equivalence property (StreamData, 100 iterations).
- Three §31 scenarios flipped active.

**Doctests:**

- `ALLM.chat/3` — Fake two-turn fixture, tool → text → stop.
- `ALLM.stream/3` — Fake two-turn fixture, count `:chat_completed`.
- `ALLM.Chat.run/3` — Fake multi-turn with halt_when.
- `ALLM.Chat.stream/3` — Fake multi-turn with manual mode.
- `ALLM.StreamCollector.to_chat_result/1` — two-branch example (stored + fallback).

**Serializability tests:** No Layer A changes — no new serializability tests. `%ChatResult{}` already round-trips per Phase 1; `%Chat.LoopState{}` is Layer C (non-serializable) and is NOT round-tripped — Phase 8's `Session.t()` is the Layer A analogue.

**Stream-equivalence tests:** `chat_equivalence_test.exs` — see Sub-phase 7.5. Complements Phase 5's `stream_equivalence_test.exs` and Phase 6's `step_equivalence_test.exs`.

**Coverage threshold:** ≥90% on all new code in `lib/allm/chat.ex`, `lib/allm/chat/loop_state.ex`, and modifications to `lib/allm/stream_collector.ex` and `lib/allm/tool_runner.ex`. ≥80% globally per `mix.exs`.

## Error Contract

Phase 7 introduces NO new `ALLM.Error.*` structs and NO new reason atoms. Every error reason listed in Phase 7's tables is already in the closed enum of a prior phase. The only new atoms are `%ChatResult{}.halted_reason` values, which live on the open tail of spec §5.9's type (`atom()`) and do not need enum extension.

**Error reasons surfaced from `ALLM.chat/3` and `ALLM.stream/3`** (all inherited):

| Function | Error reason | Recovery guidance |
|----------|--------------|--------------------|
| `chat/3`, `stream/3` | `%EngineError{reason: :missing_adapter}` | Construct engine with `:adapter`. |
| `chat/3`, `stream/3` | `%EngineError{reason: :missing_stream_adapter}` | Adapter must implement `ALLM.StreamAdapter`. |
| `chat/3`, `stream/3` | `%EngineError{reason: :unknown_tool, metadata: %{tool_name: name}}` | Register the tool. |
| `chat/3`, `stream/3` | `%ValidationError{reason: :invalid_thread \| :invalid_request}` | Fix input shape. |
| `chat/3`, `stream/3` | `%AdapterError{reason: _}` | Adapter pre-flight error (provider-specific). |
| `chat/3` | `ArgumentError` (raised) | `max_turns` must be ≥ 1. Documented; user-correctable. |

**Halted-reason atoms** (not errors — normal `{:ok, ChatResult}` returns):

See the halt-reason table in "Behaviour & Type Contracts § ALLM.Chat" above for the full vocabulary: `:completed`, `:max_turns`, `:halt_when`, `:ask_user`, `:tool_error`, `:manual_tool_calls`, `:error`, plus user custom atoms.

## Streaming & Backpressure

Phase 7 inherits Phase 5 and Phase 6's streaming contracts and extends them one layer up:

- **Cleanup is mandatory.** `Chat.stream/3`'s outer `Stream.resource/3` has an `after_fun` that halts the currently-active `step_cont` via `cont.({:halt, :consumer_halt})`, which triggers `stream_step/3`'s own cleanup chain (Phase 6's three-phase state machine), which in turn halts whichever inner sub-resource is active.
- **Consumer halt is bounded.** Verified against Phase 6's contract: consumer halt via `Enum.take/2` or `Stream.take_while/2` triggers cleanup within 500ms in CI. Phase 7's additional layer (one more `Stream.resource/3`) adds one additional function call to the cleanup chain, which is O(1) and does not change the bound.
- **Backpressure model.** The streaming spec uses `Finch` with HTTP/1 (spec §7.2) at the adapter layer. Phase 7's chat-layer composition does not introduce new backpressure concerns — each step's sub-stream is consumed event-by-event via the `Enumerable.reduce/3` continuation protocol, which is inherently pull-based and respects the consumer's reduction rate.
- **Cancellation.** Phase 7's cancellation (via consumer halt) produces NO `:chat_completed` event. A consumer that needs a final ChatResult for logging collects events and calls `StreamCollector.to_chat_result/1` on the partial state; it receives a `%ChatResult{halted_reason: :cancelled}` via the fallback branch.

## Definition of Done

- [ ] All sub-phases (7.1–7.5) marked `Completed` in the status table
- [ ] `mix test` passes with zero failures, zero `unused_var` warnings, coverage ≥ 80% globally and ≥ 90% on new code
- [ ] `mix credo --strict` passes with zero issues on changed files
- [ ] `mix dialyzer` passes with zero new warnings
- [ ] `mix format --check-formatted` passes
- [ ] Every new public function (`ALLM.chat/3`, `ALLM.stream/3`, `ALLM.Chat.run/3`, `ALLM.Chat.stream/3`) has an `@spec` and an `@doc` with at least one runnable doctest
- [ ] `ALLM.StreamCollector.to_chat_result/1` has an updated `@doc` covering both branches
- [ ] `ALLM.ToolRunner.run_tool_calls/3` has an updated `@doc` covering the function-form `on_tool_error`
- [ ] Chat-equivalence property (`test/allm/chat_equivalence_test.exs`) passes with ≥100 StreamData iterations
- [ ] Three §31 scenarios flipped from `@tag :pending` to active: `max_turns`, `halt_when`, manual-mode partial flow
- [ ] CHANGELOG.md updated with one-line entries: `ALLM.chat/3`, `ALLM.stream/3`, `ALLM.Chat.run/3`, `ALLM.Chat.stream/3`, `:chat_result` field on `StreamCollector`, `on_tool_error` function form, three scenario activations
- [ ] Spec section references in commit messages cite §10.5, §10.6, §12.3, §19, §30 as applicable
- [ ] Reviewed via `/review` (see `AGENT_REVIEW_SPEC.md`)
