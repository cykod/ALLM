# ALLM v0.2 — Implementation Phasing

## Approach

This phasing takes the canonical design in [`allm_engine_session_streaming_spec_v0_2.md`](allm_engine_session_streaming_spec_v0_2.md) and slices it into ordered, independently shippable phases that follow the spec's own §28 build order: **data → engine → behaviours → event → stream runner + Fake → collectors → streaming APIs → non-streaming wrappers → session helpers → real provider adapters**. The library is still at pre-release scaffolding (all Layer A structs exist; `ALLM.Thread` is ~70% implemented; `ALLM.Engine` has the struct but no API functions; every behaviour is a bare `@callback` list; no runtime code runs yet and `test/` is empty), so Phase 1 starts with hardening what is scaffolded and Phases 4–8 deliver the first functioning end-to-end path against `ALLM.Providers.Fake` before any real HTTP provider is touched.

The key constraint shaping the order is **stream-first execution (spec §3)**: non-streaming functions are implemented as reducers over `ALLM.Event` streams, which forces the event protocol, the stream runner, and the Fake streaming adapter to land before any non-streaming wrapper. The second constraint is **serializability (spec §2, Layer A)**: sessions must round-trip through `:erlang.term_to_binary/1` and JSON, which is validated incrementally rather than bolted on at the end. The third constraint is **test-first (`agent-spec/DESIGN.md` §5)**: every phase opens with a Test Plan and the `/design` doc for that phase must include at least happy-path + error-path unit tests, doctests for every new public function, and — once `ALLM.Providers.Fake` exists — integration tests that exercise the spec §31 property scenarios as they come into scope.

### Principles

1. **One layer per phase, justified when broken.** The four-layer architecture (A serializable data · B runtime · C stateless execution · D stateful sessions) dictates the test surface, dependency direction, and serializability rules. Every phase declares its layer up front; multi-layer phases must justify the coupling explicitly (e.g., Phase 4 introduces Fake which is Layer B but exercises Layer A events end-to-end).
2. **TDD with doctests as the minimum bar.** Every phase leads with a Test Plan, and every new public function in `ALLM`, `ALLM.Session`, and behaviour callbacks must have a runnable `@doc` example that compiles under `mix test`. The `mix.exs` 80% coverage threshold is a floor — new code in a phase lands at ≥90% line coverage.
3. **Cite the spec, don't re-state it.** Commit messages, code comments, and design docs reference the section number (`# see §12.3 ask-user`, `# per §7.2 HTTP/1 only`) rather than reproducing the rule. Two sources of truth drift; one canonical source plus pointers does not.
4. **`ALLM.Providers.Fake` is the primary test vehicle.** Network mocks are banned except when testing a real provider adapter's wire shape. Orchestration, tool loops, session state transitions, stream cancellation, and reducer equivalence are all tested against the deterministic scripted adapter.
5. **Stream-equivalence is a contract, not a convenience.** For every non-streaming wrapper `f/n` implemented as a reducer over `stream_f/n`, a property test asserts `f(args) == stream_f(args) |> StreamCollector.collect/1` for every scripted input. This invariant lives or dies with the test, so the test is non-negotiable.
6. **Middleware stays empty in v0.2 (§29).** Cross-cutting concerns — retries, telemetry, capability pre-flight — go through telemetry handlers or adapter wrapping. A phase that proposes populating `Engine.middleware: []` is deferred to v0.3.
7. **Keys never live on the engine.** `ALLM.Keys` resolves keys at adapter-call time (§6.4). Serializability tests in Phase 2 and Phase 8 prove that a serialized engine/session is safe to persist.
8. **Refactor-first when you notice drift.** While touching a module, if duplication, dead callbacks, missing `@spec`s, or spec-vs-code drift is visible, include a small Phase 1-style refactor before the feature work. Keep the scope tight to code the phase touches.

### What Each Phase Delivers

Every phase produces, at minimum:

- A `/design` document under `steering/designs/PHASE_N_<slug>.md` referencing this file and the relevant spec §-numbers, written before implementation begins.
- A green `mix test` suite with ≥80% global coverage and ≥90% on new code; zero `unused_var` warnings.
- `mix credo --strict` clean on changed files; `mix dialyzer` clean against the prior PLT.
- `mix format --check-formatted` clean.
- `@spec` on every new public function matching the Behaviour & Type Contracts section of the design doc verbatim; `@doc` with at least one runnable doctest on every public function.
- For Layer A changes: serializability round-trip tests (`:erlang.term_to_binary/1` + `Jason` with module hints).
- For behaviour changes: an updated conformance suite under `test/support/` that `ALLM.Providers.Fake` passes unchanged.
- A `CHANGELOG.md` entry per public-API change.
- Commit messages citing the spec section the phase implements (e.g., `feat(session): ask-user suspension per §12.3`).

### Spec Coverage Map

| Phase | Primary spec sections | Layer |
|-------|----------------------|-------|
| 1 | §5 (data structs), §8 (Event), §9 (request/json_schema), §16 (validation), §20 (errors), §33 (non-goals) | A |
| 2 | §6.1–§6.4 (Engine, Keys, model resolution) | B |
| 3 | §7 (behaviours), §18 (defaults) | B |
| 4 | §31 (Fake), §7 (Adapter/StreamAdapter conformance) | B |
| 5 | §3, §4, §10 (generate/stream_generate), §13 (StreamCollector) | C |
| 6 | §10 (step/stream_step), §12 (tool orchestration), §17 (internal runners) | C |
| 7 | §10 (chat/stream), §12.3 (ask-user), §19 (on_tool_error), §30 (halt_when, timeouts) | C |
| 8 | §11 (Session), §13 (StreamReducer) | D |
| 9 | §6.3 (capability pre-flight), §20 (retries), §29 (telemetry) | B (cross-cutting) |
| 10 | §32.1 (OpenAI adapter), §5.4 structured_finalize | B |
| 11 | §32.1 (Anthropic adapter), tool-forcing pattern | B |
| 12 | §32 (ecosystem), §34 (summary), release polish | — |

Every spec §-number that defines an observable behaviour or public shape appears in at least one phase by the end of Phase 12.

---

## Phase 1: Layer A Hardening — Data, Events, Errors, Facade Constructors

The data layer is mostly scaffolded (every struct in `lib/allm/` exists) but shallow: helpers are missing on `ALLM.Message`, `ALLM.ToolCall`, `ALLM.Request`, `ALLM.Response`, `ALLM.StepResult`, `ALLM.ChatResult`, and `ALLM.Usage`; the `ALLM.Event` module declares the 14-variant union as a `@type` but has no `event?/1` guard or construction helpers; and the top-level `ALLM` facade has none of its constructor functions (`system/1`, `user/1`, `assistant/1`, `tool_result/2`, `tool/1`, `json_schema/3`, `request/2`). This phase finishes Layer A so every subsequent phase can build `%ALLM.Request{}` values, assert round-trippability, and pattern-match events without each downstream phase re-hardening the data surface. It also introduces the `ALLM.Error.*` struct family (`EngineError`, `AdapterError`, `StreamError`, `ValidationError`, `ToolError`) as first-class serializable errors so later phases never have to reach for `{:error, term()}` — which, per `agent-spec/DESIGN.md` §7, is a code smell.

Key behaviours to nail down: `response_format` is normalized to the three tagged shapes (`:text`, `%{type: :json_object}`, `%{type: :json_schema, name:, schema:, strict:}` per §5.4), and `ALLM.json_schema/3` produces the third shape. `ALLM.Event` gains an `event?/1` guard plus property tests confirming every variant round-trips through `:erlang.term_to_binary/1`. Validators live in `ALLM.Validate` with one public function per struct (`request/1`, `message/1`, `tool/1`, `thread/1`, `session/1`) returning `:ok | {:error, %ALLM.Error.ValidationError{}}`; they're used by `ALLM.request/2` and the adapter boundary in later phases. The facade helpers in `lib/allm.ex` are pure data constructors — they do not accept an engine and must not dispatch.

**Delivers:** A complete Layer A surface: helpers and `@spec` on every struct, `ALLM.Event.event?/1` guard, the five `ALLM.Error.*` structs, `ALLM.Validate` with five validator functions, the `ALLM.system/1 · user/1 · assistant/1 · tool_result/2 · tool/1 · json_schema/3 · request/2` constructors in `lib/allm.ex`, round-trip tests for every Layer A struct and every `ALLM.Event` variant through both `:erlang.term_to_binary/1` and `Jason`, and a property test asserting `ALLM.Event.event?/1` accepts every legal variant and rejects malformed shapes. ≥90% coverage on all new code.

**Key decisions to make:** (a) How `Jason` re-hydrates struct types (custom decoder in `ALLM.Serializer` vs documented decode-pattern each caller uses). (b) Whether `ALLM.Error.StreamError` carries the event cursor (offset/index) for replay. (c) Whether `response_format` accepts provider-shaped maps as an escape hatch or only the three canonical shapes.

---

## Phase 2: Engine + Keys — Runtime Struct API and Key Resolution

The `ALLM.Engine` struct exists with the right fields but none of its API functions; callers cannot today construct an engine, attach tools, set model, or resolve options. This phase implements `Engine.new/1`, `put_tool/2`, `put_tools/2`, `put_param/3`, `put_context/3`, `with_model/2`, `merge_opts/2`, `resolve_model/2`, `resolve_tools/2`, `resolve_params/2` following the precedence chain in §6 (call opts > engine > app config). It also introduces the `ALLM.Keys` module (§6.4) with its own resolution chain: call opts > `Keys.put/2` runtime override > application config > `System.get_env/1` > `.env` file. Keys are resolved **at adapter-call time**, never stored on the engine. The engine itself must round-trip through `:erlang.term_to_binary/1` (only modules, atoms, and plain data — no PIDs, refs, funs, anonymous functions, or raw keys), which is the load-bearing serializability test for Layer B.

Key behaviours: `resolve_model/2` threads through the `llm_db` catalog when present (§6.3) but must function when `llm_db` is not a dep — a property test runs the full engine surface with `llm_db` both loaded and unloaded. `merge_opts/2` is the single place where Request-level overrides combine with engine defaults; every execution function in later phases goes through it. `ALLM.Keys.put/2` stores a resolver function in an Agent or ETS owned by `ALLM.Keys`, never on the engine struct, which keeps the engine serializable.

**Delivers:** Fully implemented `ALLM.Engine` API, `ALLM.Keys` module with the five-level resolution chain, engine serializability round-trip tests, `llm_db`-absent / `llm_db`-present property tests for `resolve_model/2`, doctests on every public function, and an integration test in `test/allm/engine_test.exs` that constructs an engine, serializes it, deserializes it, and verifies the deserialized engine is functionally identical. ≥90% coverage.

**Key decisions to make:** (a) Where `ALLM.Keys` stores resolver funs (`Agent` vs `:persistent_term` vs ETS) given this affects application-startup ergonomics. (b) Whether `.env` parsing is built in or deferred behind an optional `dotenvy` dep.

---

## Phase 3: Behaviours + Default Implementations + Conformance Harness

All four behaviours (`ALLM.Adapter`, `ALLM.StreamAdapter`, `ALLM.ToolExecutor`, `ALLM.ToolResultEncoder`) currently have only bare `@callback` declarations. This phase fills in the full contract: every callback gets a full `@spec`-style type signature in the behaviour module, `@doc` describing semantics, and — critically — a **conformance test module** under `test/support/` that any implementation can be plugged into (`ALLM.Test.AdapterConformance`, `ALLM.Test.StreamAdapterConformance`, `ALLM.Test.ToolExecutorConformance`, `ALLM.Test.ToolResultEncoderConformance`). The conformance tests are the single source of truth for what it means to implement each behaviour; `ALLM.Providers.Fake` (Phase 4) will be the first implementation to pass them, and every real provider in Phases 10–11 reuses the same suite. This phase also ships the two default implementations: `ALLM.ToolExecutor.Default` (invokes the handler on the `%ALLM.Tool{}`) and `ALLM.ToolResultEncoder.JSON` (encodes tool results with `Jason`, passing strings through unchanged).

Key behaviours: the `Adapter.prepare_request/2` escape hatch (§7) returns a `Req.Request` that advanced users can customize before it goes on the wire, and the conformance suite tests that customizations survive. `ToolExecutor` accepts the arity-2 handler form with the injected `opts` keyword list (`:context`, `:session_id`, `:request_id`, `:tool_call`, `:engine` per §5.2) and the default implementation must correctly dispatch both arity-1 and arity-2 handlers. `ToolResultEncoder.JSON` encodes `{:ok, map}` as a JSON object and `{:error, reason}` as `%{"error" => inspect(reason)}`.

**Delivers:** Fully-specified `ALLM.Adapter`, `ALLM.StreamAdapter`, `ALLM.ToolExecutor`, `ALLM.ToolResultEncoder` behaviours with callback `@spec`s and `@doc`; `ALLM.ToolExecutor.Default` and `ALLM.ToolResultEncoder.JSON` implementations; four conformance test modules under `test/support/` with a shared `use ALLM.Test.XConformance` macro; unit tests on the default implementations covering arity-1 and arity-2 tool handlers, `{:ok, _}`, `{:error, _}`, `{:ask_user, _}`, and `{:halt, _, _}` return shapes. ≥90% coverage on new code.

**Key decisions to make:** (a) Whether `ALLM.Test.*Conformance` modules are part of the published package (accessible to library users writing their own adapters) or test-support only. The spec implies the former (§32 "users need it for their own tests") but the mechanics deserve explicit treatment.

---

## Phase 4: `ALLM.Providers.Fake` — Scripted Adapter for Tests

`ALLM.Providers.Fake` is the linchpin of every subsequent orchestration phase (§31) and must land before any execution function because the spec §31 test scenarios are all written against it. This phase implements both the `Adapter` behaviour (non-streaming scripted responses) and the `StreamAdapter` behaviour (scripted event sequences), passes the conformance suites from Phase 3, and ships a fixture library under `test/support/fake_fixtures.ex` with named scripts for common scenarios: plain text, single tool call, parallel tool calls, multi-turn conversation, mid-stream error, empty response, tool call with streaming arg deltas. The fake is deterministic: given the same input thread and the same script, it emits the same events in the same order every time. It also simulates consumer cancellation: when the returned stream is halted early, the fake records the halt in its state so tests can assert on cleanup.

Key behaviours: scripts are plain data (keyword lists or maps) that encode finish reasons, tool call sequences, usage numbers, and optional delays-between-events (for testing backpressure). The fake exposes `ALLM.Providers.Fake.script/1` to load a script into adapter state before the call. For streaming, every event listed in the script is emitted wrapped via `Stream.resource/3` so that consumer halts trigger the `after_fun` — which is the cheapest possible cancellation test. The fake's internal state is process-local (`Process.put/2` under a namespaced key or an Agent started by the test) so parallel tests don't leak fixtures.

**Delivers:** `ALLM.Providers.Fake` implementing both `Adapter` and `StreamAdapter`, passing both conformance suites; `test/support/fake_fixtures.ex` with at least eight named fixtures covering the §31 scenarios' input shapes; doctests on `ALLM.Providers.Fake.script/1`; a cancellation test asserting that `Stream.take(events, 2)` on a 10-event script halts the adapter after 2 events. ≥90% coverage.

**Key decisions to make:** (a) Whether fake state is `Agent`-backed (better for parallel test isolation) or process-dictionary-based (simpler, less setup). (b) Whether scripts support "replay from recording" — i.e., record a real provider response and play it back — which would be valuable for Phases 10–11 but may be out of scope for Phase 4 itself.

---

## Phase 5: `stream_generate/3` + `generate/3` + `StreamCollector` — First Executable Path

This is the first phase that delivers user-visible value: `ALLM.stream_generate/3` returns `{:ok, Enumerable.t()}` of `ALLM.Event` values when called with an engine whose adapter is `ALLM.Providers.Fake`. The implementation is deliberately thin — it's a `with` chain that validates the request (Phase 1), resolves model and keys (Phase 2), and dispatches to `engine.stream_adapter.stream/2` (Phase 3), with `Stream.resource/3` wrapping the result to attach an `after_fun` that releases the adapter's resources on consumer halt. `ALLM.StreamCollector` is a fold state (`new/1`, `apply_event/2`, `to_step_result/1`) that turns an event sequence into an `ALLM.StepResult` or `ALLM.ChatResult`. `ALLM.generate/3` is then implemented as a two-liner: call `stream_generate/3`, pipe through `StreamCollector`, return the final response.

This phase formalizes the **stream-equivalence invariant**: a property test asserts, for every Fake fixture from Phase 4, that `generate/3` and `stream_generate/3 |> StreamCollector.collect/1` produce identical `ALLM.Response` values. This invariant must hold for every subsequent wrapper (`step/3` over `stream_step/3`, `chat/3` over `stream/3`), so the test module is built to be reused. Consumer cancellation has a bounded-time test: halting the stream after 2 events must release the Finch ref (via `Stream.resource/3` cleanup) within 500ms.

**Delivers:** `ALLM.stream_generate/3` and `ALLM.generate/3` in `lib/allm.ex`; `ALLM.StreamCollector` in `lib/allm/stream_collector.ex`; `test/allm/allm_generate_test.exs` with happy path, error path (no adapter, no stream adapter, validation failure), and doctest; `test/allm/allm_stream_generate_test.exs` with event-ordering, cancellation, and error-surfacing tests; `test/allm/stream_collector_test.exs` with property tests covering every `ALLM.Event` variant; `test/allm/stream_equivalence_test.exs` covering `generate` ≡ `stream_generate |> collect` across all Phase 4 fixtures. §31 scenarios covered this phase: pure text streaming with and without `emit_text_deltas: false`, mid-stream adapter error, consumer cancellation releases resources.

---

## Phase 6: `stream_step/3` + `step/3` — Single-Turn Tool Loop

`step/3` is one adapter call plus tool execution: invoke the adapter, buffer any tool calls, run each tool through the engine's `ToolExecutor`, encode results with `ToolResultEncoder`, append the resulting `:tool`-role messages to the thread, and return `%ALLM.StepResult{thread, response, tool_results, done?}`. `stream_step/3` does the same but emits events in real time (`tool_call_started`, `tool_call_delta`, `tool_call_completed`, `tool_execution_started`, `tool_execution_completed`, `tool_result_encoded`, `step_completed`). The orchestration lives in `ALLM.Internal.ToolRunner` and `ALLM.Internal.Step`; neither is public API but both are covered by conformance-style tests with Fake as the driver. `done?` is `true` when the response's `finish_reason` is `:stop | :length | :content_filter | :error` or when `{:halt, _, _}` was returned by a handler; it is `false` when `finish_reason: :tool_calls` and tools executed successfully.

Key behaviours: tool handlers returning `{:error, reason}` feed through the engine's `on_tool_error` policy (`:continue | :halt | fun` per §19) — this phase implements `:continue` (encode as tool result, loop continues) and the basic halt path, saving the ask-user and full `halt_when` semantics for Phase 7 where they slot naturally into the multi-turn surface. Parallel tool calls in a single assistant turn are executed concurrently via `Task.async_stream/3` with the engine's `tool_timeout` — this is where the §31 "parallel tool calls" scenario is first exercised.

**Delivers:** `ALLM.stream_step/3` and `ALLM.step/3` in `lib/allm.ex`; `ALLM.Internal.ToolRunner`; `ALLM.Internal.Step`; stream-equivalence property test covering step ≡ `stream_step |> collect`; tests for single tool call in `:auto` and `:manual` mode scaffolding (full manual mode completes in Phase 7 with the chat surface); parallel tool call concurrency test; `{:ok, _}` / `{:error, _}` / unknown-tool handler return shapes. §31 scenarios covered this phase: single tool call with `mode: :auto`, parallel tool calls, tool handler raises (partial — full `on_tool_error` in Phase 7).

**Key decisions to make:** (a) How parallel tool call concurrency is bounded when no `max_concurrency` is specified (default to `System.schedulers_online()` vs `length(tool_calls)`). (b) Whether `ALLM.Internal.ToolRunner` emits a `:tool_execution_cancelled` event if `tool_timeout` elapses (not in the current §8 union — this is a spec amendment flag).

---

## Phase 7: `stream/3` + `chat/3` — Full Orchestration Loop

The multi-turn orchestration loop: repeatedly run a step, append results to the thread, and continue until a terminal condition is reached (`finish_reason: :stop`, `max_turns` exceeded, `halt_when` returns `true`, `{:halt, reason, result}` returned by a handler, or `{:ask_user, ...}` returned by a handler). This phase implements `ALLM.stream/3` (events all the way through) and `ALLM.chat/3` (reducer over the stream, returns `%ALLM.ChatResult{}`). It wires the full orchestration options per §10 and §30: `mode: :auto | :manual`, `max_turns: non_neg_integer()`, `halt_when: (StepResult.t() -> boolean())`, `emit_text_deltas: bool`, `emit_tool_deltas: bool`, `include_raw_chunks: bool`, `on_event: (Event.t() -> any())`, `request_timeout`, `stream_timeout`, `tool_timeout`.

Key behaviours: `:manual` mode stops and returns `%ALLM.ChatResult{halted_reason: :manual_tool_calls}` when the model produces tool calls, leaving tool execution to the caller; this is the first phase where manual mode is fully functional. `{:ask_user, question}` / `{:ask_user, question, opts}` handler returns suspend the loop, emit an `ask_user_requested` event, and set `halted_reason: :ask_user` on the result alongside the `pending_question` and `pending_tool_call_id` (§12.3). `{:halt, reason, result}` emits `tool_halt`, encodes `result` as the tool-result message, and sets `halted_reason: reason` (§5.2). The full `on_tool_error` policy — `:halt`, `:continue`, and the function form `fun.(tool_call, error) :: {:continue, term()} | :halt` — is implemented here. A `halt_when` callback is evaluated after every step before the next adapter call.

**Delivers:** `ALLM.stream/3` and `ALLM.chat/3` in `lib/allm.ex`; full options plumbing; stream-equivalence test `chat ≡ stream |> collect`; tests for every terminal condition (`:stop`, `:length`, `max_turns`, `halt_when`, `:ask_user`, `:halt`, `on_tool_error {:halt | :continue | fun}`); tests for `:auto` vs `:manual` mode including manual round-trip (get tool calls, submit results via `Session.submit_tool_result/3` stub — full Session integration is Phase 8); doctests for `ALLM.stream/3` and `ALLM.chat/3` using Fake. §31 scenarios covered this phase: `max_turns` cap, `halt_when` fires, tool handler raises (full `on_tool_error`), single tool call in `:manual` mode.

**Key decisions to make:** (a) Whether `:manual` mode in `chat/3` (no Session) requires caller re-invocation of `chat/3` with a thread already containing tool-result messages, or exposes a different entry point. The cleanest answer per spec §11 is that `Session.submit_tool_result/3` is the only manual-resume path; this phase would then deliver a smaller `chat/3` surface for manual mode and defer the round-trip to Phase 8.

---

## Phase 8: `ALLM.Session` — Stateful Continuation (Layer D)

Sessions layer serializable state management on top of the stateless Layer C functions. This phase implements `ALLM.Session.start/3`, `stream_start/3`, `reply/4`, `stream_reply/4`, `step/3`, `stream_step/3`, `submit_tool_result/3`, and `continue/3`, all of which take and return `%ALLM.Session{}`. Status transitions are explicit: `:idle → :awaiting_tools` (manual mode, tool calls produced), `:awaiting_tools → :awaiting_user` (handler returned `:ask_user`), `:awaiting_user → :idle` (user replies via `Session.reply/4`), any state `→ :completed` (finish_reason `:stop`), any state `→ :error` on adapter failure. `ALLM.Session.StreamReducer` is the Layer D analogue of `StreamCollector`: it folds events into both the session state and the chat result in one pass.

The §31 **session round-trip scenario** lives here and is the load-bearing correctness test: `start` a session, serialize it via `:erlang.term_to_binary/1`, deserialize it in a fresh process, `reply` to it, and assert the final thread equals what an in-memory run would have produced. The same round-trip must also work through `Jason` with a documented decoder that re-hydrates struct types. Sessions carry `:context` which is user-supplied plain-data (documented: modules and atoms fine, PIDs/refs/funs not) that's passed to tool handlers via the `:context` opt (§5.2).

**Delivers:** `ALLM.Session.start/3 · stream_start/3 · reply/4 · stream_reply/4 · step/3 · stream_step/3 · submit_tool_result/3 · continue/3`; `ALLM.Session.StreamReducer`; session round-trip tests through both `:erlang.term_to_binary/1` and `Jason`; tests for every status transition; `ask_user` end-to-end (start → suspended → reply → continued); manual mode end-to-end (start → `:awaiting_tools` → submit_tool_result → continued); doctests on every public Session function. §31 scenarios covered this phase: session round-trip (serialize → deserialize → reply yields the same thread tail).

**Key decisions to make:** (a) Whether `ALLM.Session.StreamReducer.finalize/1` returns `{updated_session, chat_result}` (tuple) or `%ALLM.Session{last_result: chat_result}` (embedded). The tuple form is more honest about the two outputs; the embedded form is easier to thread through pipe chains.

---

## Phase 9: Telemetry, Capability Pre-flight, and Retries

This phase lights up three cross-cutting concerns that have been implicit in earlier phases. **Telemetry** (§29) adds `:telemetry.execute/3` calls at standard points: `[:allm, :generate | :stream | :step | :chat | :tool, :start | :stop | :exception]` with `request_id`, `model`, `usage`, `duration` metadata; handlers are pluggable per application. **Capability pre-flight** (§6.3) activates when `llm_db` is loaded: it validates `tools_enabled`, `json_native`, and context-length caps before the adapter call, and auto-sets `structured_finalize: true` when a caller passes tools with `response_format: %{type: :json_schema}` against an adapter that doesn't support the combo natively. **Retries** (§20) implement the default policy (up to 3 attempts on 429/5xx/`:timeout` with exponential backoff + jitter, honoring `Retry-After`) for non-streaming adapter calls only — streaming calls are never retried because the output is already partly consumed. The engine's `:retry` field controls per-call policy; `retry: false` disables and `retry: keyword()` overrides defaults.

Key behaviours: `request_id` is generated once at the top of `stream_generate/3`, propagates through every event (`ALLM.Event` struct metadata or wrapper), is returned on `ALLM.Response.request_id`, and appears in every telemetry event — this is the correlation ID for observability. Capability pre-flight **does not make network calls**; it runs entirely off the `llm_db` catalog when loaded, and becomes a no-op when `llm_db` is absent (a dep-free test confirms this). Retry jitter is bounded (50%-150% of backoff) to avoid thundering-herd.

**Delivers:** Telemetry calls wired into every execution function in `lib/allm.ex`, `lib/allm/session.ex`, and `lib/allm/internal/tool_runner.ex`; `request_id` propagation end-to-end; `ALLM.Retry` module with exponential backoff + jitter + `Retry-After` parsing; `ALLM.Capability` module gated on `Code.ensure_loaded?(LLMDb)` — a no-op without `llm_db`; tests with `:telemetry_test.attach_event_handlers/2` asserting expected events fire in order; retry tests using Fake with `retry_on_call: n` fixture; a dep-free smoke test that runs the full suite with `llm_db` excluded from the manifest.

**Key decisions to make:** (a) Where `request_id` lives on events — a wrapper struct around every event, or a metadata field on every variant. The former is invasive but clean; the latter requires every variant map to carry `:request_id` and bloats the union. (b) Whether retries are attempted on structured-finalize's second pass independently or tied to the first-pass retry budget.

---

## Phase 10: OpenAI Provider Adapter

First real provider. This phase implements `ALLM.Providers.OpenAI` — both `Adapter` (Chat Completions + Responses API) and `StreamAdapter` (SSE over Finch HTTP/1, per spec §7.2). The SSE decoder lives in `ALLM.Providers.Support.SSE` as a shared helper because Anthropic (Phase 11) will reuse it. The adapter translates ALLM's canonical `response_format` shapes into OpenAI's two (Chat Completions' `%{type: "json_schema", json_schema: ...}` and Responses API's `text: %{format: %{type: "json_schema", ...}}`) and implements the `structured_finalize` two-pass dance (§5.4): pass 1 runs the tool loop with tools enabled and `response_format: nil`; pass 2 issues a final tools-disabled call with the original `response_format` attached and a user-nudge message. `requires_structured_finalize?/1` declares this capability so capability pre-flight from Phase 9 auto-sets the flag. The conformance suites from Phase 3 run unchanged against the OpenAI adapter.

Key behaviours: OpenAI's streaming chunks map onto ALLM events (`content_delta` fragments → `text_delta`; `tool_calls[].function.arguments` fragments → `tool_call_delta`; `finish_reason` → `message_completed` with the normalized enum). `finish_reason` normalization is a pure function with property-tested coverage of every documented OpenAI finish reason plus unknown strings (mapping to `:other` with the raw string preserved in `raw_finish_reason`). API key resolution goes through `ALLM.Keys.get!/2` at request-build time; no key is ever baked into the adapter. Wire-format tests use recorded fixtures (JSON files under `test/fixtures/openai/`) played through a mock Finch transport — this is the only place in the codebase where network mocking is acceptable per the agent-spec/DESIGN.md §10.

**Delivers:** `ALLM.Providers.OpenAI` implementing `Adapter` + `StreamAdapter`; `ALLM.Providers.Support.SSE` line-buffered SSE decoder; finish-reason mapping with property tests; `structured_finalize` two-pass wiring; recorded-fixture wire tests for happy path, 429 with `Retry-After`, 5xx, malformed SSE, mid-stream error, tool-call deltas, structured output; conformance suite passes unchanged; a real-provider smoke test gated on `OPENAI_API_KEY` env var (skipped in CI by default).

**Key decisions to make:** (a) Which API (Chat Completions vs Responses) is the default for new engines. Chat Completions has broader compatibility; Responses is OpenAI's go-forward API and supports some features Chat doesn't. The spec doesn't mandate — this is a design decision for the phase. (b) How to handle OpenAI's `reasoning` content blocks (o1-style), if at all, in v0.2.

---

## Phase 11: Anthropic Provider Adapter

Second real provider. `ALLM.Providers.Anthropic` implements both behaviours for the Messages API, reusing the SSE helper from Phase 10. Anthropic has no native JSON Schema enforcement, so structured output is implemented via the **tool-forcing pattern** (§5.4): when `response_format: %{type: :json_schema, ...}` is passed, the adapter injects a synthetic `respond_with_json` tool whose schema matches the requested schema, and sets `tool_choice: {:tool, "respond_with_json"}`. The tool's "result" is the final structured response, surfaced to the caller as a normal `ALLM.Response.output_text` / `message.content`. Anthropic's streaming chunk format differs from OpenAI (separate `content_block_*` events for text and tools), so chunk-to-event mapping is its own well-tested function. Anthropic's finish reasons (`end_turn`, `max_tokens`, `tool_use`, `stop_sequence`) map to the normalized enum.

Key behaviours: `system` messages are pulled out of the thread and sent as a top-level `system` parameter (Anthropic doesn't accept `system`-role messages inline). Image content in messages is rejected with `{:error, %ALLM.Error.ValidationError{reason: :vision_not_in_v0_2}}` per §33 non-goals. The conformance suite passes unchanged. Recorded-fixture wire tests cover happy path, 429, 529 (overloaded), tool use, structured-output tool-forcing, long content (>64KB which is where the HTTP/2 flow-control bug from §7.2 bites — confirming Finch is configured HTTP/1).

**Delivers:** `ALLM.Providers.Anthropic` implementing `Adapter` + `StreamAdapter`; tool-forcing pattern for structured output; finish-reason mapping with property tests; system-message extraction; recorded-fixture wire tests for every error class and the tool-forcing end-to-end; conformance suite passes unchanged; real-provider smoke test gated on `ANTHROPIC_API_KEY`.

**Key decisions to make:** (a) Whether `prompt caching` is exposed in v0.2 or deferred. Anthropic's caching is `cache_control` annotations on message content parts; exposing it requires a Layer A change to `ALLM.Message.content` — this is a spec amendment flag if in scope.

---

## Phase 12: v0.2 Release Polish

The wrap-up phase. This is where the four `steering/examples/` case studies (Amesbury, Garden, meal, unllmtd) are translated into runnable integration tests under `test/examples/` — each test constructs the engine as documented in the example, runs the scripted Fake against it, and asserts the user-visible shape matches the example's promise. If any example fails to translate cleanly, that's a design gap that needs a spec amendment or an earlier-phase fix, not a Phase 12 workaround. This phase also produces the public documentation: `README.md` gets a "Getting Started" that builds a working `chat/3` call against Fake in under 15 lines; `ex_doc` configuration is tuned so the generated hex docs lead with `ALLM`, then `ALLM.Session`, then the behaviour contracts, with the providers as a subsection. A `CHANGELOG.md` rollup covers the entire v0.2 delta since `0.0.1`.

This is also where the §31 scenario-completion audit lives: verify all nine property scenarios pass in CI, tagged under a `@moduletag :spec_31` so they can be run as a single regression suite. Coverage is verified globally at ≥80% and ≥90% on code added in Phases 1–11. `mix dialyzer` is run against the `prod` PLT. The hex package metadata (`mix.exs` package section) is reviewed for accuracy — `0.0.1` bumps to `0.2.0` and the hex publish is a dry-run (not yet published; that's a separate release event).

**Delivers:** Four example-translation integration tests under `test/examples/`; `@moduletag :spec_31` on every §31 scenario with `mix test --only spec_31` green; `README.md` Getting Started; `ex_doc` layout; `CHANGELOG.md` with a one-line entry per public-API change since `0.0.1`; `mix hex.build` dry-run succeeds; a final `/review` pass per `agent-spec/REVIEW.md` recorded as the phase's review artifact.

**Key decisions to make:** (a) Whether to publish `0.2.0` at the end of this phase or stage a `0.2.0-rc.1` for internal use first. (b) Whether the example translations live in `test/examples/` (covered by `mix test`) or `examples/` at the repo root (runnable as scripts via `mix run`). The former catches regressions; the latter is more discoverable.

---

## What Comes After

v0.2 is the **runtime foundation**. Post-release candidates for v0.3 and beyond, all flagged as non-goals in §33:

- Middleware (§29) — populating `Engine.middleware: []` with a composable middleware chain.
- Prompt DSL — a user-facing builder for complex system prompts and few-shot examples.
- Memory stores — pluggable conversation memory beyond raw `Thread` persistence.
- Advanced planning — multi-step agent frameworks (ReAct, tree-of-thought) built on top of `ALLM.chat/3`.
- Embeddings, audio, image generation, vision input — new execution surfaces.
- Additional provider adapters — Gemini, Cohere, Mistral, local LLMs (Ollama, llama.cpp) — each a standalone phase or separate package per §32 ecosystem guidance.

Phases in this document build **toward** that boundary, not past it. If a phase finds itself designing a middleware hook, a memory interface, or a vision content-part encoding, the phase scope is wrong — push the feature into a v0.3 design doc and finish the v0.2 phase with only what §-numbered spec sections require.
