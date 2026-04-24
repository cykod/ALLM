## [FEAT] Phase 6: step/3 + stream_step/3 with parallel tool execution
*Friday, April 24th at 10pm*
Implements Phase 6 sub-phases 6.1-6.4 across three batches: ALLM.ToolRunner 
(parallel Task.async_stream dispatch + on_tool_error policy), ALLM.Chat.step/3 
+ stream_step/3 (three-phase Stream.resource state machine), the ALLM.step/3 + 
stream_step/3 facade, and a 100-iteration step-equivalence property proving 
step ≡ stream_step |> collect. Extends StreamCollector with :tool_results and 
:halt fields plus three fold clauses, activates three §31 scenarios (single 
tool call auto, parallel tool calls, handler raises), and renames @phase_7_opts 
to @orchestration_opts. Folds nine retro findings into AGENT_DESIGN_SPEC, 
AGENT_IMPLEMENTATION_SPEC, and CLAUDE.md (sub-phase retro cadence, shared test 
helpers threshold, primitive-vs-composition verification, struct-field 
structural rule, mid-stream error contract, and others). Test suite: 140 
doctests, 17 properties, 726 tests, 0 failures.

---

## [FEAT] Phase 4+5: Fake adapter + generate/stream_generate facade
*Friday, April 24th at 6pm*
Ships Phase 4 (ALLM.Providers.Fake scripted adapter implementing both
ALLM.Adapter and ALLM.StreamAdapter, plus ALLM.Providers.Fake.Script helper
and ALLM.Test.FakeFixtures test-support fixtures) and Phase 5 (Layer C
execution: ALLM.StreamCollector fold state, ALLM.StreamRunner and ALLM.Runner
internal runners, and the ALLM.generate/3 + ALLM.stream_generate/3 public
facade). The :message_completed event payload additively gains an optional
:finish_reason key (tag count stays at 16). The stream-equivalence property
exercises 100 random §31 fixtures asserting generate ≡ stream_generate |>
collect, and three §31 scenarios previously tagged :pending are now active.
622 tests / 132 doctests / 15 properties green; credo --strict, dialyzer,
format, hex.build all clean. See steering/PHASE_4_DESIGN.md, PHASE_5_DESIGN.md,
and spec §3, §4, §8, §10.1, §10.2, §13.1, §17, §19, §20, §30, §31.

---

## [FEAT] Phase 3: Behaviour contracts, defaults, conformance harness
*Friday, April 24th at 1pm*
Hardens the four Layer B behaviours (ALLM.Adapter, StreamAdapter, ToolExecutor, 
ToolResultEncoder) with rich moduledocs, per-callback docs, and 
error-struct-tightened return types. Ships two default implementations — 
ALLM.ToolExecutor.Default with arity-1/2 dispatch and raise/exit/throw 
conversion to %ToolError{}, and ALLM.ToolResultEncoder.JSON with binary 
passthrough plus Jason-backed encoding — both at 100% coverage. Publishes the 
allm_conformance sibling Hex package under conformance/ with four 
ExUnit.CaseTemplate harnesses (47 injected cases across 
Adapter/StreamAdapter/ToolExecutor/ToolResultEncoder), a permanent StubAdapter 
fixture implementing both adapter behaviours, and harness self-tests; main 
project certifies its defaults via a path-dep on the sibling. Three accumulated 
retros drove AGENT_DESIGN_SPEC and AGENT_IMPLEMENTATION_SPEC refinements: §3 
consolidated into a five-class empirical-verification rule (stdlib exceptions, 
project closed-atom enums, stdlib function failure modes on OTP floor, 
macro-expansion-wrapped raises, opaque-term returns) plus hedge-word guidance, 
and §16 now names both conformance shipping shapes with the Shape-B PLT gotcha 
(plt_add_apps: [:ex_unit]) documented. Main suite: 323 → 393 tests, 0 
failures, 0 credo issues, 0 dialyzer errors; conformance sub-project: 55 tests.

---

## [FEAT] Phase 1 + 2: Layer A data, Engine resolver, Keys chain
*Thursday, April 23rd at 12pm*
Ship Phase 1 and Phase 2 of the ALLM library end-to-end: Layer A data structs 
(Message, Request, Response, Thread, Session, StepResult, ChatResult, Event, 
Tool, ToolCall, Usage) with term_to_binary + Jason round-trip, the 
ALLM.Validate validator, the ALLM.Serializer tagged-JSON encoder/decoder, the 
full Phase 1 error hierarchy under ALLM.Error.*, and the lib/allm.ex facade 
with doctests (Phase 1). On top of that, Phase 2 adds ALLM.Engine's resolver 
API (merge_opts/2, resolve_model/2, resolve_tools/2, resolve_params/2), engine 
serializability via __from_tagged__/1 + Jason.Encoder, the five-level ALLM.Keys 
resolution chain (opts -> runtime Agent -> app_config -> env -> .env), and 
ALLM.Application supervising ALLM.Keys.Store. Suite stands at 323 tests, 96 
doctests, 12 properties, 0 failures, global coverage 96.59%. Also captures the 
process artifacts (AGENT_*_SPEC.md, steering design docs, retros, reviews, 
CHANGELOG) built via the retro-driven build discipline across both phases.

---

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Phase 6.3 + 6.4 — `ALLM.step/3` + `ALLM.stream_step/3` facade + step-equivalence property + §31 activation

#### Added
- `ALLM.step/3` — new public facade function (spec §4, §10.3). Pure one-line delegation to `ALLM.Chat.step/3`; accepts either an `%ALLM.Thread{}` or a list of `%ALLM.Message{}` as the second arg. `@doc` carries a runnable Fake + inline tool doctest.
- `ALLM.stream_step/3` — new public facade function (spec §4, §10.4). Pure one-line delegation to `ALLM.Chat.stream_step/3`; returns `{:ok, stream}` where the stream emits adapter events → tool-execution event groups → exactly one terminal `:step_completed`. `@doc` carries a runnable Fake + inline tool doctest.
- `ALLM.Test.Assertions` — new test-support module (`test/support/assertions.ex`, not shipped in the Hex package). Exports `assert_equivalent_step_result/2` which compares two `%StepResult{}` values modulo a `tool_call_id` sort on `:tool_results` and on `:tool`-role thread messages (per PHASE_6_DESIGN.md Non-obvious Decision #9). Every other field (`:response`, `:done?`, non-tool-role thread messages, `:metadata`) is compared by exact `==`.
- `test/allm/step_equivalence_test.exs` — `StreamData` property test (`@moduletag :property`) asserting `ALLM.step(engine, thread, mode: :auto) ≡ ALLM.stream_step(engine, thread, mode: :auto) |> reduce(collector) |> to_step_result/1` across 100 randomly generated tool-call-bearing Fake scripts. A second property at 25 iterations covers mid-execution handler failures (`on_tool_error: :continue`). Each iteration isolates Fake's per-process cursor via `Task.async/1` so the two paths see fresh process-dict cursors. Thread extraction from the `:step_completed` event payload compensates for the `StreamCollector` catch-all no-op on that tag (Phase 7 may add explicit handling).
- `test/allm/providers/fake_scenarios_test.exs` — three Phase 6 §31 scenarios activated as new describe blocks: "single tool call with `mode: :auto`" (through `ALLM.step/3` with an echo tool), "parallel tool calls through `ALLM.step/3`" (two tools, order-independent tool_results assertion), "tool handler raises, `on_tool_error` policy fires" (covers atom forms `:continue` and `:halt`; function form deferred to Phase 7 with an inline comment). The existing `@tag :pending` placeholder for the handler-raises scenario was removed; three `@tag :pending` placeholders remain for Phase 7/8 (max_turns, halt_when, session round-trip). Moduledoc scenario table updated to reflect the 9-active / 3-pending split.
- `test/allm/allm_step_test.exs`, `test/allm/allm_stream_step_test.exs` — facade-level tests covering happy paths, pre-flight `%EngineError{reason: :missing_adapter}`, list-of-messages normalisation, and delegation-invariant equality (both facades under `Task.async/1` to isolate cursor state).

### Phase 6.2 — `ALLM.Chat.step/3` + `ALLM.Chat.stream_step/3` + `StreamCollector` extension

#### Added
- `ALLM.Chat` — new internal Layer C module (spec §17). Ships `step/3` (non-streaming single-turn orchestrator) and `stream_step/3` (streaming variant). Normalises `thread_or_messages` (list of `%Message{}` → `ALLM.Thread.from_messages/1`), validates the thread via `ALLM.Validate.thread/1`, dispatches the adapter call via `ALLM.Runner.run/3` / `ALLM.StreamRunner.run/3`, then branches on `:mode` and `response.finish_reason`. `mode: :manual` + `:tool_calls` surfaces tool calls without executing handlers and sets `StepResult.metadata.mode: :manual` (NOT a halt — Finding F2). `mode: :auto` + `:tool_calls` dispatches to `ALLM.ToolRunner.run_tool_calls/3` / `ALLM.ToolRunner.stream_tool_calls/3`, appends tool-role messages to the thread, and surfaces halt metadata (`:tool_error`, `{:halt, reason, result}`, `{:ask_user, ...}`) via `StepResult.metadata`. Assistant-message construction uses `response.output_text` (collector-authoritative) per PHASE_6_DESIGN.md Non-obvious Decision #10. Ask-user handler returns do NOT append an `:assistant` message with `metadata.ask_user: true` in Phase 6 (Non-obvious Decision #6); that thread mutation is Phase 7's concern. `stream_step/3` composes via a single three-phase `Stream.resource/3` state machine (Phase A drives the adapter stream, Phase B drives `ToolRunner.stream_tool_calls/3`, Phase C emits exactly one `:step_completed` event) — one outer resource, no wrapping (Non-obvious Decision #1). Event sequence invariant: all adapter events → zero-to-N tool-execution event groups → exactly one terminal `:step_completed`. No new `ALLM.Event` variants added. No new error-reason atoms added. Error table inherited from Phase 5 plus `%EngineError{reason: :unknown_tool}` from Phase 6.1.

#### Changed
- `ALLM.StreamCollector` — struct gains two fields (`:tool_results: []`, `:halt: nil`) and three new fold clauses (`:tool_result_encoded`, `:tool_halt`, `:ask_user_requested`) inserted immediately before the catch-all per Phase 5 Non-obvious Decision #5. `:tool_result_encoded` appends a `%Message{role: :tool, tool_call_id: id, content: content, metadata: %{}}` to `:tool_results`; `:tool_halt` and `:ask_user_requested` set `:halt` on first observation (first-halt-wins via `halt: nil` guard on the clause head — subsequent halts fall to the catch-all no-op). `to_step_result/1` now reads `:tool_results` from the struct (was hardcoded `[]`), computes `done?` via `step_done?/1` (`halt != nil or finish_reason in [:stop, :length, :content_filter, :error]` — was derived from `:finish_reason` alone), and merges halt metadata into `StepResult.metadata` via `merge_halt_metadata/2` (`{:halt, reason, id}` → `%{halted_reason: reason, halt_tool_call_id: id}`; `{:ask_user, :ask_user, id, q, o}` → `%{halted_reason: :ask_user, pending_tool_call_id: id, pending_question: q, ask_user_opts: o}`). Per PHASE_6_DESIGN.md §StreamCollector extension, Non-obvious Decision #11, and Invariants 1–7. `:tool_execution_started`, `:tool_execution_completed`, and `:step_completed` stay in the catch-all; Phase 7 may add explicit clauses for `:step_completed`. Totality property still holds across the 16-tag closed union.

### Phase 6.1 — `ALLM.ToolRunner` + `StreamRunner` attribute rename

#### Added
- `ALLM.ToolRunner` — new internal Layer C module (spec §17). Ships `run_tool_calls/3` (non-streaming, returns `{:ok, [Message.t()]} | {:ok, [Message.t()], halt_metadata} | {:error, %EngineError{}}`) and `stream_tool_calls/3` (streaming, returns an enumerable of `ALLM.Event` values — Phase 6 extension to spec §17 per PHASE_6_DESIGN.md Non-obvious Decision #2). Both variants share `execute_one_tool/3` for dispatch + encoding + `on_tool_error` policy. Parallel execution via `Task.async_stream/5` with `ordered: false`, `max_concurrency: max(1, min(length(tool_calls), System.schedulers_online() * 2))` default, `on_timeout: :kill_task`, `zip_input_on_exit: true`; per-tool `tool_timeout` (default 30_000 ms). Unknown-tool pre-flight returns `{:error, %EngineError{reason: :unknown_tool, metadata: %{tool_name: name}}}` synchronously (non-streaming) or a single-element error stream (streaming); no tools execute. Empty `tool_calls` short-circuits to `{:ok, []}` / `Stream.concat([])` to guard against `Task.async_stream/5`'s `ArgumentError` on `max_concurrency: 0`. Handler-return dispatch covers all five spec §5.2 shapes: `{:ok, _}`, `{:error, _}` (policy-routed), `{:ask_user, _}` / `{:ask_user, _, _}` (content `"<awaiting user response>"` per spec §12.3; halt with ask-user metadata), `{:halt, reason, result}` (halt with tool_halt metadata). Encoder failures (`Protocol.UndefinedError`, `Jason.EncodeError`) caught and wrapped as `%ToolError{reason: :encoding_failed}`, then routed through `on_tool_error` (Non-obvious Decision #3). Function form of `on_tool_error` raises `ArgumentError` mentioning Phase 7. Sibling-drain on halt (Invariant 3): `Task.async_stream/5` runs to natural exhaustion on handler halt; first-halt-wins (earliest input-index) for `halt_metadata`. No new `ALLM.Event` variants added. No new error-reason atoms added.

#### Changed
- `ALLM.StreamRunner` — internal module-attribute rename (no behavioural change): `@phase_7_opts` → `@orchestration_opts`, `strip_phase_7_opts/1` → `strip_orchestration_opts/1`, `Logger.debug/1` message "Phase 7 opt" → "orchestration opt", `@moduledoc` section heading "Phase 7 opts are stripped" → "Orchestration opts are stripped". Contents unchanged (`[:mode, :max_turns, :halt_when]`). Phase 6 consumes `:mode` at the `ALLM.Chat` layer (Phase 6.2); StreamRunner's deny-list remains as the safety-net before adapter dispatch. Per PHASE_6_DESIGN.md Non-obvious Decision #5.

### Phase 5.4 — Stream-equivalence property + §31 scenario wiring

#### Added
- `test/allm/stream_equivalence_test.exs` — `StreamData` property test module (`@moduletag :property`) asserting `ALLM.generate/3 == ALLM.stream_generate/3 |> reduce(StreamCollector) |> to_response` across 100 randomly generated §31 scripts. Separate property covers mid-stream `{:error, reason}` equivalence (finish_reason and metadata.error agreement). Each iteration runs `generate/3` and `stream_generate/3` in isolated `Task.async/1` processes so Fake's per-process cursor doesn't collide across the two calls.
- `test/allm/providers/fake_scenarios_test.exs` — flipped three `@tag :pending` placeholders to active tests: pure text streaming with `emit_text_deltas: false`, mid-stream adapter error through `stream_generate/3` + `generate/3`, and consumer cancellation releasing Fake's `:counters` observer. Added a halt-safety-through-filters regression assertion (same 10-event fixture + `emit_text_deltas: false` + `Enum.take(stream, 2)` → observer increments within 500 ms) pinning Phase 5 Non-obvious Decision #6.

### Phase 5.3 — `ALLM.Runner` + `ALLM.generate/3`

#### Added
- `ALLM.Runner` — new internal Layer C module (spec §17). `run/3` delegates to `ALLM.StreamRunner.run/3`, folds the returned stream through `ALLM.StreamCollector.new/0 |> apply_event/2` and emits `{:ok, %Response{}}` via `to_response/1`. Pre-flight errors bubble verbatim; mid-stream `{:error, _}` events fold into `%Response{finish_reason: :error, metadata: %{error: struct}}` per Non-obvious Decision #4 — `run/3` still returns `{:ok, _}` in that case. The `include_raw_chunks: false` filter's usage carve-out (§StreamRunner Decision #9) means the collector always sees `{:raw_chunk, {:usage, _}}` regardless of caller intent, so no Runner-side filter override is needed. `@moduledoc` begins with "Internal — use `ALLM.generate/3` instead." (Non-obvious Decision #10).
- `ALLM.generate/3` — new public facade function (spec §4, §10.1). Pure delegation to `ALLM.Runner.run/3`; `@doc` carries a runnable Fake doctest demonstrating the non-streaming path.

### Phase 5.2 — `ALLM.StreamRunner` + `ALLM.stream_generate/3`

#### Added
- `ALLM.StreamRunner` — new internal Layer C module (spec §17). `run/3` validates (`:missing_adapter` → `:missing_stream_adapter` via `Code.ensure_loaded?/1 + function_exported?(adapter, :stream, 2)` → `ALLM.Validate.request/1`), resolves model/params via `ALLM.Engine`, dispatches to `engine.adapter.stream/2`, and post-processes the returned stream. Post-processing composes `Stream.each/2` (for `:on_event`) with `Stream.filter/2` (for `:emit_text_deltas`, `:emit_tool_deltas`, `:include_raw_chunks`) — no extra `Stream.resource/3` wrap (per PHASE_5_DESIGN Non-obvious Decision #6). `{:raw_chunk, {:usage, _}}` events always pass the filter regardless of `:include_raw_chunks` (usage carve-out per Non-obvious Decision #9). `:on_event` exceptions surface in the consumer's reducing process — no `try/rescue` (per Non-obvious Decision #7). `@moduledoc` begins with "Internal — use `ALLM.stream_generate/3` instead." (per Non-obvious Decision #10).
- `ALLM.stream_generate/3` — new public facade function (spec §4, §10.2). Pure delegation to `ALLM.StreamRunner.run/3`; `@doc` carries a runnable Fake doctest.

#### Changed
- Phase 7 orchestration opts (`:mode`, `:max_turns`, `:halt_when`) are deny-listed at the `StreamRunner` boundary and never reach the adapter — prevents a future `Jason.encode!` trip on a `:halt_when` fun when real provider adapters land (per Non-obvious Decision #11). `Logger.debug/1` fires once per stripped key.

### Phase 5.1 — `:message_completed` finish_reason + `ALLM.StreamCollector`

#### Added
- `ALLM.StreamCollector` — new Layer C module (spec §13.1). Reduces an `ALLM.Event` stream into a `%Response{}` (`to_response/1`, thread-less), `%StepResult{}` (`to_step_result/1`), or `%ChatResult{}` (`to_chat_result/1`). Ships `new/0` (Phase 5 extension per PHASE_5_DESIGN Non-obvious Decision #3), `new/1` (accepts `nil` or `%Thread{}` per Non-obvious Decision #3), and `apply_event/2` with nine explicit per-tag clauses plus a catch-all (per Non-obvious Decision #12). Mid-stream `{:error, _}` events fold into `finish_reason: :error` + `metadata.error: struct` so `to_response/1` never returns `{:error, _}` (per Non-obvious Decision #4). `{:raw_chunk, {:usage, map}}` applies `struct!(ALLM.Usage, map)` — documented pass-through that raises `KeyError` on unknown fields (adapter-side contract).
- `ALLM.Event.message_completed/2` — new arity adding an explicit `finish_reason` argument (`is_atom(fr) or is_nil(fr)` guard). `message_completed/1` now emits `finish_reason: nil` for back-compat.

#### Changed
- `:message_completed` event payload additively gains an optional `:finish_reason` key (`Response.finish_reason() | nil`). Tag count stays at 16; `event?/1` accepts both shapes (with and without the key). See PHASE_5_DESIGN Non-obvious Decision #1 for the back-compat guarantee. `ALLM.Providers.Fake` threads the reason from `{:finish, reason}` script entries into the terminal `:message_completed` event.

### Phase 4 — `ALLM.Providers.Fake` scripted adapter

#### Added
- `ALLM.Providers.Fake` — deterministic scripted adapter (Layer B) implementing both `ALLM.Adapter` and `ALLM.StreamAdapter`. Accepts two disjoint script shapes on `adapter_opts` (spec §31 user-facing and Phase 3 harness), supports multi-call sequencing via a per-process cursor with an explicit Agent-backed override (`start_script_cursor/0` / `cursor_index/1`), honours `{:delay, ms}` / `{:sleep, ms}` for backpressure testing, and exposes a `:cleanup_observer` (`:counters` ref) hook for halt-safety assertions. Passes the 13-case `ALLM.Test.AdapterConformance` and 14-case `ALLM.Test.StreamAdapterConformance` harnesses unchanged. See spec §7.1, §7.2, §8, §20, §30, §31.
- `ALLM.Providers.Fake.Script` — pure helper module (Layer B) for shape detection (`detect_shape/1`), boundary validation (`validate!/1`), non-streaming fold (`fold_to_response/1`), and per-entry event translation (`interpret/1`). Shared interpreter for `:finish` / `:tool_call` tags across both script vocabularies; `:error` disambiguates by tuple arity.
- `ALLM.Test.FakeFixtures` — test-support library (`test/support/fake_fixtures.ex`, not shipped in the Hex package) with eight named `adapter_opts` fixtures: `plain_text/1`, `single_tool_call/2`, `parallel_tool_calls/1`, `multi_turn_conversation/1`, `mid_stream_error/1`, `empty_response/0`, `tool_call_with_streamed_args/2` (codepoint-safe split), and `delayed_text/2`. Per Phase 4 design Non-obvious Decision #10.
- `:no_scripted_response` added to `ALLM.Error.AdapterError.@legal_reasons` (12th reason atom, scoped to testing adapters). Spec §31 preserves the bare-atom form; Phase 1's narrowed `{:error, %AdapterError{}}` behaviour contract carries it on the struct's `:reason` field.
- `test/allm/providers/fake_scenarios_test.exs` — three spec §31 scenarios covered today (pure text streaming with `emit_text_deltas: true`, parallel tool calls, mid-stream adapter error) plus six `@tag :pending` placeholders naming the phase that will cover each deferred scenario. `@moduletag :spec_31` allows `mix test --only spec_31` to scope the audit.

### Phase 3.5 — `allm_conformance` Sibling Package + Harness Wiring

#### Added
- `allm_conformance` — new sibling Hex package (in-repo sub-project at `conformance/`, app `:allm_conformance`, version `0.2.0`). Ships four `ExUnit.CaseTemplate`-based harnesses under the `ALLM.Test.*` namespace (`ALLM.Test.AdapterConformance`, `ALLM.Test.StreamAdapterConformance`, `ALLM.Test.ToolExecutorConformance`, `ALLM.Test.ToolResultEncoderConformance`). Consumer install is one line (`{:allm_conformance, "~> 0.2", only: :test}`); no `elixirc_paths` surgery. See `conformance/README.md` for usage and release checklist. Per PHASE_3_DESIGN.md §Non-obvious Decision #1.
- `ALLM.Test.Fixtures.StubAdapter` — permanent scripted test fixture (in `conformance/test/support/`, not exported) implementing both `ALLM.Adapter` and `ALLM.StreamAdapter`. Drives the harness's own self-tests; script shape documented in its `@moduledoc`.
- 43 conformance self-tests across the sub-project (12 + 6 + 10 + 7 injected cases plus 8 meta-tests covering case-count stability and missing-opt `KeyError`).
- Main project `mix.exs` now declares `{:allm_conformance, path: "conformance", only: :test}` so the two default implementations (`ALLM.ToolExecutor.Default`, `ALLM.ToolResultEncoder.JSON`) certify against the harness: `test/allm/tool_executor/default_test.exs` and `test/allm/tool_result_encoder/json_test.exs` each plug in via `use ALLM.Test.<...>Conformance, ...`.
- `LICENSE` files at the repo root and in `conformance/` (MIT, Pascal Rettig) — prerequisite for `mix hex.build`.

#### Notes
- The design doc's `StreamError` mid-stream reason table named `:truncated | :malformed_chunk | :connection_dropped`, but the Phase 1 committed `ALLM.Error.StreamError` enum is `:adapter_error | :cancelled | :timeout | :malformed_event | :unknown`. The conformance suite uses the committed atoms (`:cancelled` in the self-test case) per `AGENT_DESIGN_SPEC.md §3`'s empirical-verification rule.

### Phase 2.4 — Engine Integration Test

#### Added
- `test/allm/engine_integration_test.exs` — four end-to-end scenarios proving the Phase 2 surface composes: (1) serialize → fresh process → deserialize → resolve identically; (2) runtime keys (`ALLM.Keys.put/2`) do not leak into the serialized engine (structural walk, not substring search on the ETF binary); (3) opts-win precedence end-to-end across `resolve_model/2`, `resolve_tools/2`, `resolve_params/2`; (4) `{Module, :function}` MFA tool handlers round-trip through `:erlang.term_to_binary/1` regardless of whether the module is loaded at decode time. Tagged `@moduletag :integration` so the suite can be scoped via `mix test --only integration`.

#### Changed
- `ALLM.Engine.@engine_field_keys` deny-list now includes `:params`. Without this, `resolve_params/2` would have attempted to merge a caller-supplied `opts[:params]` value (including `nil`) into `engine.params` via the opts pathway, contradicting Invariant 6's prose "opts with engine-field keys excluded." Surfaced by Sub-phase 2.4 Scenario 3; see PHASE_2_DESIGN.md Non-obvious decision #5 implementation note.

### Phase 2.2 — Keys + Application

#### Added
- `ALLM.Keys` module with five-level resolution chain (opts → runtime store → app config → env → `.env`) per spec §6.4. `get/1,2` returns `{:ok, key, source}` or `{:error, :missing}`; `fetch!/2` raises `%ALLM.Error.EngineError{reason: :missing_key}` with `:checked_sources` metadata. Empty-string values at every level are treated as missing.
- `ALLM.Keys.Store` — `Agent`-backed in-process key store (Non-obvious decision #1), caches the lazy `.env` load in the same Agent (Decision #10). `clear/0` resets both runtime keys and the dotenv cache.
- `ALLM.Keys.Dotenv` — built-in `.env` parser (Non-obvious decision #2) supporting `KEY=VALUE`, `# comment`, blank lines, `export KEY=VALUE`, and surrounding double-quote stripping. Single quotes are intentionally not stripped (documented limitation).
- `ALLM.Application` supervises `ALLM.Keys.Store`; `mix.exs` `application/0` now sets `mod: {ALLM.Application, []}` so the store starts with the `:allm` OTP app.
- `test/fixtures/sample.env` fixture plus unit + integration tests in `test/allm/keys_test.exs`, `test/allm/keys/store_test.exs`, `test/allm/keys/dotenv_test.exs`.

### Added
- `ALLM.Error.*` struct hierarchy (`EngineError`, `AdapterError`, `StreamError`, `ValidationError`, `ToolError`) — first-class serializable errors with `Exception` impls and default `:message` fallbacks. Per design sub-phase 1.1.
- `.new/1` constructors, `@spec`s, and `@doc` doctests on every Layer A struct (`ALLM.Message`, `ALLM.ToolCall`, `ALLM.Request`, `ALLM.Response`, `ALLM.StepResult`, `ALLM.ChatResult`, `ALLM.Usage`); `@doc` + doctest coverage expanded on the pre-existing `ALLM.Thread` and `ALLM.Tool` helpers; `@moduledoc` rewrite on `ALLM.Session` documenting the `metadata[:error]` convention and the caller-owned `context` contract. Per design sub-phase 1.2.
- Accessor functions `ALLM.Response.text/1`, `ALLM.ChatResult.halted?/1`, and `ALLM.Usage.total_tokens/1` with the documented fallback semantics. Per design sub-phase 1.2.
- `@enforce_keys` on `ALLM.Message` (`:role`, `:content`), `ALLM.ToolCall` (`:id`, `:name`, `:arguments`), and `ALLM.Tool` (`:name`, `:description`, `:schema`) so required-field omission raises `ArgumentError` at construction time. Per design sub-phase 1.2.
- `ALLM.Event.event?/1` guard function with payload-shape checks (map-typed payload required for every tag except the opaque `:raw_chunk` / `:error`), `ALLM.Event.tags/0` returning the closed 16-atom union, and 14 variant constructors (`text_delta/2`, `text_completed/2`, `tool_call_started/2`, `tool_call_delta/2`, `tool_call_completed/4`, `tool_execution_started/3`, `tool_execution_completed/3`, `tool_result_encoded/2`, `ask_user_requested/4`, `tool_halt/3`, `message_started/1`, `message_completed/1`, `step_completed/2`, `chat_completed/1`). Per design sub-phase 1.3.
- `ALLM.Validate` module with five validators (`request/1`, `message/1`, `tool/1`, `thread/1`, `session/1`). Returns structured `%ALLM.Error.ValidationError{}` with field-level error lists. Per sub-phase 1.4.
- `ALLM.Test.Generators` test-support module extracting Layer A struct generators (`role_gen/0`, `text_gen/0`, `tool_name_gen/0`, `message_gen/0`, `tool_gen/0`, `request_gen/0`) for reuse across property tests. Per retro 2026-04-19-phase1-1.4.
- `ALLM.Serializer` with `encode_tagged/2`, `to_json!/1`, `to_iodata!/1`, and `from_json/2` — tagged JSON encoding (`%{"__type__" => ..., "data" => ...}`) with `Jason` round-trip for every Layer A struct. `from_json/2` returns `{:error, %ValidationError{}}` with the closed field-error vocabulary (`:malformed`, `:missing_type_tag`, `:unknown_type_tag`, `:missing`, `:malformed_struct`, `:atom_decode_failed`) from sub-phase 1.5.
- `defimpl Jason.Encoder` and private `__from_tagged__/1` hydrators on every Layer A struct (`ALLM.Message`, `ALLM.Tool`, `ALLM.ToolCall`, `ALLM.Request`, `ALLM.Response`, `ALLM.Thread`, `ALLM.Session`, `ALLM.StepResult`, `ALLM.ChatResult`, `ALLM.Usage`) and every `ALLM.Error.*` struct. Atom-typed fields (`Message.role`, `Request.tool_choice`, `Request.response_format`, `Response.finish_reason`, `Session.status`, `ChatResult.halted_reason`, every error `:reason` and `:provider`) are restored via `String.to_existing_atom/1` per the tagged-encoding design (§1.5).
- `@doc` with runnable doctests on every public constructor in `ALLM` (`system/1`, `user/1`, `assistant/1`, `tool_result/2`, `tool/1`, `json_schema/3`, `request/2`) plus expanded `@moduledoc` with a Layer-A end-to-end worked example. Per sub-phase 1.6.

### Changed
- Removed `:llm_db` dependency from `mix.exs` (pinned to non-existent `~> 0.1`). Will be re-added in Phase 9 when capability pre-flight / cost population (spec §6.3) need it.
- `mix.exs` — added `:stream_data` (`~> 1.1`, test-only) for property-style tests on closed-union types (`ALLM.Event` variants).
- `ALLM.Serializer` now round-trips `response_format` map shapes (`%{type: :json_object}` and `%{type: :json_schema, name: _, schema: _, strict: _}`), preserving atom-keyed form on decode via a new `ALLM.Request.restore_response_format/1` helper. Escape-hatch maps with other string keys pass through unchanged (spec §5.4). Per sub-phase 1.5 review Finding 2.
- `ALLM.Validate.tool/1` now rejects tool names `"auto"`, `"none"`, `"required"` with `{:name, :reserved_tool_name}` to prevent collision with `tool_choice` atom restoration in the Serializer. Per sub-phase 1.5 review Finding 3; vocabulary table in sub-phase 1.4 updated accordingly.
- `ALLM.request/2` rewritten as a thin wrapper around `ALLM.Request.new/2` (semantically identical; internal cleanup so both facade and struct module have independent doctests). Per sub-phase 1.6.

### Fixed
- Normalized `lib/allm/event.ex` formatting (scaffolding commit had unformatted lines).
- `mix docs` warnings resolved — `README.md` and `ALLM.Validate` `@moduledoc` references restructured to avoid ExDoc cross-reference failures (forward-looking `ALLM.generate/3`, `ALLM.Session.reply/4` references phrased as plain text tagged with target phase; spec-path link converted to plain prose; `ALLM.Validate.*/1` glob replaced with an explicit enumeration of the five validators). Per sub-phase 1.6 review Finding 1.
