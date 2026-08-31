# Phase 5: `stream_generate/3` + `generate/3` + `StreamCollector` — Design Document

> **Goal:** Ship the first user-visible Layer C surface: `ALLM.stream_generate/3` returns a lazy `Enumerable.t()` of `ALLM.Event` values driven by an `ALLM.StreamAdapter`-conforming adapter, `ALLM.generate/3` reduces the same stream into an `%ALLM.Response{}`, and `ALLM.StreamCollector` is the fold state that both non-streaming wrappers (this phase and Phases 6–8) reuse.
> **Outcome:** Calling `ALLM.stream_generate(engine, request)` against a `Fake`-backed engine returns a lazy enumerable whose events (`:message_started`, `:text_delta`, `:text_completed`, `:tool_call_started`, `:tool_call_delta`, `:tool_call_completed`, `:message_completed`, optional `:raw_chunk`, terminal `{:error, _}`) match the script 1:1 per §31. `ALLM.generate(engine, request)` returns an equivalent `{:ok, %Response{}}` via `ALLM.StreamCollector`. A stream-equivalence property test asserts `generate/3 == stream_generate/3 |> collect` across every Phase 4 fixture. A halt-safety test asserts `Enum.take(stream, 2)` on a 10-event script increments Fake's `:counters` cleanup observer within 500 ms. `mix test`, `mix credo --strict`, `mix dialyzer`, `mix format --check-formatted` all green; coverage ≥90 % on every new file.
> **Spec sections:** §3 (stream-first principle), §4 (facade), §8 (event protocol — scoped additive extension to `:message_completed`), §10.1 (`generate/3`), §10.2 (`stream_generate/3`), §13.1 (`StreamCollector`), §17 (`ALLM.Runner`, `ALLM.StreamRunner`), §19 (streaming options — `emit_text_deltas`, `emit_tool_deltas`, `include_raw_chunks`, `on_event`), §20 (error reasons — `:missing_adapter`, `:missing_stream_adapter`, `:invalid_request`), §30 (cancellation semantics), §31 (three property-style scenarios).
> **Layers touched:** C (stateless execution), plus a **single-field additive amendment** to the Layer A `ALLM.Event` `:message_completed` payload (the payload map gains an optional `:finish_reason` key — not a new variant, not a breaking change to the closed tag set). Call out explicitly: Phase 5 does NOT add a new event variant. The tag count stays at 16; only the shape of one existing variant's payload grows by one optional key. Per agent-spec/DESIGN.md "Adding a new variant to a closed tagged-tuple union is a breaking change for every reducer", this phase is *adjacent* to that rule — we extend an existing variant's payload additively, which is backward-compatible for every pattern match that binds `%{message: msg}` and ignores other keys.
> **Phasing doc:** [`PROJECT_PHASING.md`](PROJECT_PHASING.md) Phase 5.

## Status

| Sub-phase | Description | Layer | Status |
|-----------|-------------|-------|--------|
| 5.1 | `:message_completed` payload amendment + `ALLM.StreamCollector` (Layer A micro-amendment + Layer C fold state) | A + C | Not Started |
| 5.2 | `ALLM.StreamRunner` internal + `ALLM.stream_generate/3` public facade (Layer C) | C | Not Started |
| 5.3 | `ALLM.Runner` internal + `ALLM.generate/3` public facade (Layer C) | C | Not Started |
| 5.4 | Stream-equivalence property test + halt-safety + §31 scenario wiring (Layer C — tests only) | C | Not Started |

**Overall Progress:** 0/4 sub-phases complete

## Overview

Phase 5 is the first phase that makes `ALLM.generate/3` and `ALLM.stream_generate/3` callable. The public facade (`lib/allm.ex`) currently ships only Layer A constructors (`system/1`, `user/1`, `assistant/1`, `tool_result/2`, `tool/1`, `json_schema/3`, `request/2`); the engine, adapter behaviours, and Fake are ready (Phases 2–4); the execution layer has no implementation. This phase delivers that layer — deliberately thin — by wiring a `with`-chain dispatch into two internal runner modules (`ALLM.StreamRunner` and `ALLM.Runner` per spec §17) and a shared reducer (`ALLM.StreamCollector` per spec §13.1). The non-streaming path is defined as a reducer over the streaming path (spec §3), which forces the streaming primitive to land first and keeps the two entry points on one canonical implementation.

The phase's load-bearing correctness property is **stream-equivalence** (spec §3's first consequence made testable): for every scripted Fake fixture, `ALLM.generate/3` and `ALLM.stream_generate/3 |> StreamCollector.collect/1` produce identical `%Response{}` values. That invariant is a per-fixture property test in sub-phase 5.4, and it's the gate every future non-streaming wrapper (`step/3` over `stream_step/3` in Phase 6, `chat/3` over `stream/3` in Phase 7) passes unchanged. If the Phase 5 implementation breaks stream-equivalence, Phases 6 and 7 will not have a clean foundation to build on — so the property test is non-negotiable.

The phase's second critical requirement is **resource-safe cancellation** (spec §30). `ALLM.Providers.Fake` already ships `Stream.resource/3`-based cleanup with a `:counters` observer (Phase 4); Phase 5 propagates consumer halt through its post-processing stream pipeline without wrapping in another `Stream.resource/3`. A halt-safety test asserts the Fake observer increments within 500 ms of `Enum.take(stream, 2)`. No additional cleanup machinery is introduced at the Phase 5 layer — the adapter owns the resource; Phase 5 just forwards events through lazy operators (`Stream.each/2`, `Stream.filter/2`) that correctly propagate `{:halt, _}`.

The phase's third design obligation is the **`:message_completed` payload amendment**. Fake's streaming mode consumes `{:finish, reason}` script entries but currently discards `reason` when emitting the terminal `:message_completed` event (see `lib/allm/providers/fake.ex:502-505`). The non-streaming `generate/2` fold retains it. Phase 5's stream-equivalence property cannot hold unless finish-reason survives the stream round-trip, so sub-phase 5.1 extends the `:message_completed` event payload by one optional key — `:finish_reason` — and amends Fake to populate it. This is additive: every existing consumer that binds `{:message_completed, %{message: msg}}` keeps working because Elixir map matching is non-exhaustive; only consumers that now want to read `:finish_reason` opt in. Spec §8's tag count is unchanged. No spec §-number needs renumbering; the amendment rides in the same `lib/allm/event.ex` module as a spec annotation plus a new `message_completed/2` constructor (the `message_completed/1` constructor stays for back-compat, mapping `:finish_reason` to `nil`).

### Deliverables

- **New modules (main package):**
  - `ALLM.StreamCollector` (`lib/allm/stream_collector.ex`) — Layer C fold state per spec §13.1, with `new/0` (thread-less), `new/1` (thread-backed), `apply_event/2`, `to_response/1` (new — Phase 5 extension, see Non-obvious Decision #2), `to_step_result/1` (spec §13.1), `to_chat_result/1` (spec §13.1). Callers fold via the stdlib idiom `Enum.reduce(stream, StreamCollector.new(), fn e, s -> StreamCollector.apply_event(s, e) end)`; no `collect/2` helper is added — the stdlib form is three visible tokens and keeps the Phase 5 API surface to the four spec §13.1 functions plus the two Phase 5 extensions.
  - `ALLM.StreamRunner` (`lib/allm/stream_runner.ex`) — Internal Layer C runner per spec §17. `run/3` validates, resolves, dispatches to `engine.adapter.stream/2`, applies per-spec-§19 post-filters (`emit_text_deltas`, `emit_tool_deltas`, `include_raw_chunks`) and the `on_event` observer.
  - `ALLM.Runner` (`lib/allm/runner.ex`) — Internal Layer C runner per spec §17. `run/3` calls `StreamRunner.run/3` then folds through `StreamCollector.to_response/1`.
- **Modified modules:**
  - `lib/allm/event.ex` — add `message_completed/2` constructor with optional `finish_reason` arg; document the additive payload key in `@type t` and `@moduledoc`; no change to `event?/1` guard (already accepts any map payload for structured variants).
  - `lib/allm/providers/fake.ex` — thread `finish_reason` from the `{:finish, reason}` entry through `closing_events/1` into the `:message_completed` payload; one-line `closing_events/1` signature change plus a new accumulator field `:finish_reason`.
  - `lib/allm.ex` — add `stream_generate/3` and `generate/3` public functions delegating to the internal runners, with `@spec` and `@doc` carrying runnable doctests that use `ALLM.Providers.Fake`.
- **Modified tests (Phase 4 amendment fallout):**
  - `test/allm/event_test.exs` (adds test for `message_completed/2` + optional `:finish_reason` payload key).
  - `test/allm/providers/fake_stream_test.exs` (one new assertion: `:message_completed` event carries `:finish_reason` when the script has a `{:finish, reason}` entry).
- **New tests:**
  - `test/allm/stream_collector_test.exs` — per-event-variant fold correctness, `new/0` and `new/1` paths, `to_response/1` / `to_step_result/1` / `to_chat_result/1` outputs, `:raw_chunk {:usage, map}` usage accumulation.
  - `test/allm/stream_runner_test.exs` — happy path through Fake, `:missing_adapter` / `:missing_stream_adapter` error paths, filter application (`emit_text_deltas: false`, `emit_tool_deltas: false`, `include_raw_chunks: false`), `on_event` callback fires, pre-flight adapter error bubbles synchronously.
  - `test/allm/runner_test.exs` — happy path through Fake, error paths identical to StreamRunner.
  - `test/allm/allm_stream_generate_test.exs` — facade-level happy path + error paths + doctest coverage; asserts the delegated behaviour matches `StreamRunner`.
  - `test/allm/allm_generate_test.exs` — facade-level happy path + error paths + doctest.
  - `test/allm/stream_equivalence_test.exs` — property test: for every Phase 4 fixture without timing entries (`:delay`/`:sleep` deferred as timing noise) and without terminal script errors, `generate/3` == `stream_generate/3 |> collect` by `%Response{}` equality.
  - Extends `test/allm/providers/fake_scenarios_test.exs` (already exists per Phase 4, tagged `@moduletag :spec_31`) — flip three `@tag :pending` placeholders to active tests: pure text streaming with `emit_text_deltas: false`, mid-stream adapter error terminates with `{:error, reason}`, and consumer cancellation releases resources (mapped to the `:counters` observer increment).
- **CHANGELOG entries:** one line per new public module (`ALLM.StreamCollector`, `ALLM.StreamRunner`, `ALLM.Runner`) + one line per new facade function (`ALLM.stream_generate/3`, `ALLM.generate/3`) + one line for the `:message_completed` payload extension.
- **No changes to:** `ALLM.Engine`, `ALLM.Keys`, `ALLM.Adapter`, `ALLM.StreamAdapter` behaviours, `ALLM.Providers.Fake.Script`, `ALLM.Test.FakeFixtures`, the `conformance/` sub-project, `ALLM.Application`, `mix.exs`. No new dependency.

### Spec coverage

- **§3 Stream-first execution.** `generate/3` is implemented as a reducer over `stream_generate/3`. This makes the first of spec §3's four consequences live: "non-streaming functions are implemented by reducing those streams into final results." The reducer is `StreamCollector.to_response/1`; the property test in 5.4 is the invariant's enforcement.
- **§4 Facade.** `stream_generate/3` and `generate/3` are the second and third public functions on `ALLM` that return execution results (after `request/2`). The signatures match spec §4 verbatim:
  ```elixir
  @spec stream_generate(ALLM.Engine.t(), ALLM.Request.t(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, ALLM.Error.EngineError.t() | ALLM.Error.AdapterError.t() | ALLM.Error.ValidationError.t()}
  @spec generate(ALLM.Engine.t(), ALLM.Request.t(), keyword()) ::
          {:ok, ALLM.Response.t()} | {:error, ALLM.Error.EngineError.t() | ALLM.Error.AdapterError.t() | ALLM.Error.ValidationError.t()}
  ```
  The error-branch type is narrowed from spec §4's `term()` to the three concrete error structs per `agent-spec/DESIGN.md`'s "`{:error, term()}` in a `@spec` is a code smell."
- **§8 Event protocol.** Additive amendment to `:message_completed` payload: gains `:finish_reason` (optional). The full payload after this phase is `%{message: Message.t(), finish_reason: Response.finish_reason() | nil}`. Every other `ALLM.Event` variant is unchanged. The tag count stays at 16; the union is not broadened, narrowed, or re-cased. See Non-obvious Decision #1 for the rationale and the back-compat guarantee.
- **§10.1, §10.2 Non-streaming and streaming generation.** Both facade functions are implemented as `with`-chains through their respective internal runners. Spec §10's option precedence (call opts > request fields > engine > app config > library defaults) is honoured by the existing `ALLM.Engine.resolve_*` functions (Phase 2); Phase 5 calls them at the boundary and threads their results into the adapter call.
- **§13.1 `ALLM.StreamCollector`.** The full module arrives here with one extension over the spec: `to_response/1` (Non-obvious Decision #2), plus a `new/0` variant for thread-less consumers (Non-obvious Decision #3). The spec's `new/1`, `apply_event/2`, `to_step_result/1`, and `to_chat_result/1` land verbatim.
- **§17 Internal modules.** `ALLM.Runner.run/3` and `ALLM.StreamRunner.run/3` land with the spec §17 signatures verbatim. `ALLM.Chat` and `ALLM.ToolRunner` (also in spec §17) are Phase 6/7; they are out-of-scope here.
- **§19 Streaming options.** Of the seven options in the §19 kwlist, Phase 5 implements three (`emit_text_deltas`, `emit_tool_deltas`, `include_raw_chunks`) and one callback (`on_event`). The orchestration options (`mode`, `max_turns`, `halt_when`) land in Phase 7 because `stream_generate/3` is single-request — there is no loop, no turns, no step boundary — and the orchestration flags would be no-ops here. Passing any of those three to `stream_generate/3` is accepted without error but the keys are **stripped** by `StreamRunner` before forwarding to the adapter (see Non-obvious Decision #11) — they never reach `engine.adapter.stream/2` as params. Without stripping, a `halt_when: &fn/1` would flow through `resolve_params/2` into the adapter's params map and trip `Jason.encode!` in real providers (funs are not JSON-encodable). Phase 5 tests assert both that a stripped opt doesn't change the stream's behaviour AND that the adapter's received opts do not contain the stripped key.
- **§20 Error reasons.** `:missing_adapter`, `:missing_stream_adapter` (both from `ALLM.Error.EngineError.@legal_reasons` — Phase 1, verified in committed enum at `lib/allm/error/engine_error.ex:30-38` on 2026-04-24), `:invalid_request` (from `ALLM.Error.ValidationError` — Phase 1). Adapter errors flow through as `%AdapterError{}` untouched.
- **§30 Cancellation.** Consumer halt → adapter `after_fun` fires within 500 ms. Phase 5 inherits the Fake halt-safety contract from Phase 4; the halt-safety test in 5.4 is a regression assertion that the Phase 5 stream pipeline does not break that contract (e.g., by buffering events in a `Stream.resource/3` wrapper that wouldn't propagate halt). Tests confirm `Stream.filter/2` and `Stream.each/2` propagate `{:halt, _}` from the consumer to the upstream adapter stream — this is stdlib behaviour, but the regression test pins it.
- **§31 Property-style coverage.** Three of the nine §31 scenarios become active in Phase 5 (previously `@tag :pending` in `test/allm/providers/fake_scenarios_test.exs`):
  - pure text streaming with `emit_text_deltas: false` — now testable because Phase 5 introduces the filter.
  - mid-stream adapter error — stream terminates with `{:error, reason}`. Fake emits a terminating `{:error, %AdapterError{}}` event from a scripted `{:error, :rate_limited}`; StreamCollector records it into `Response.finish_reason: :error` and `metadata.error` (see Non-obvious Decision #4 for the mid-stream error → response mapping).
  - consumer cancellation releases the adapter's HTTP request — mapped to the `:counters` observer increment for Fake, equivalent for real adapters in Phase 10/11.

  The remaining six scenarios (single tool call `:auto` + `:manual`, parallel tool calls at the `step/3` layer, `max_turns`, `halt_when`, tool handler raises, session round-trip) remain `@tag :pending` and are phased into 6–8.

### Layer demonstration

Phase 5 is Layer C with one additive Layer A payload key. Three consumer-facing usages at Layer C alone — no Layer D session needed:

```elixir
# Layer C: non-streaming single request — the simplest user path
engine = ALLM.Engine.new(
  adapter: ALLM.Providers.Fake,
  adapter_opts: [script: [{:text, "Hello "}, {:text, "world"}, {:finish, :stop}]]
)

req = ALLM.request([ALLM.user("say hi")])
{:ok, response} = ALLM.generate(engine, req)
# response.output_text == "Hello world", response.finish_reason == :stop
```

```elixir
# Layer C: streaming — caller consumes events in real time
{:ok, stream} = ALLM.stream_generate(engine, req)

Enum.each(stream, fn
  {:text_delta, %{delta: d}} -> IO.write(d)
  {:message_completed, %{finish_reason: r}} -> IO.puts("\n[done: #{r}]")
  _ -> :ok
end)
```

```elixir
# Layer C: manual collection — the stream-equivalence idiom
{:ok, stream} = ALLM.stream_generate(engine, req)

response =
  stream
  |> Enum.reduce(ALLM.StreamCollector.new(), fn event, acc ->
    ALLM.StreamCollector.apply_event(acc, event)
  end)
  |> ALLM.StreamCollector.to_response()
# response.output_text == "Hello world", response.finish_reason == :stop
# Equivalent to the generate/3 call above.
```

No Layer D function is exercised; `ALLM.Session` arrives in Phase 8. No Phase 6/7 tool orchestration is involved; `stream_generate/3` is a single adapter call.

### Prerequisites

- **Phase 1 complete.** `ALLM.Error.EngineError` (with `:missing_adapter` and `:missing_stream_adapter` reasons in the committed enum at `lib/allm/error/engine_error.ex:30-38`), `ALLM.Error.AdapterError`, `ALLM.Error.ValidationError`, `ALLM.Event` module (including `event?/1` guard and the existing `message_completed/1` constructor), `ALLM.Response` with the `finish_reason` type, `ALLM.Validate.request/1`.
- **Phase 2 complete.** `ALLM.Engine.new/1`, `resolve_model/2`, `resolve_tools/2`, `resolve_params/2`, `merge_opts/2`. These are the resolution primitives the StreamRunner composes.
- **Phase 3 complete.** `ALLM.Adapter` and `ALLM.StreamAdapter` behaviours with their published callback contracts and conformance harnesses.
- **Phase 4 complete.** `ALLM.Providers.Fake` implements both behaviours; `ALLM.Test.FakeFixtures` ships eight fixtures covering Phase 5's happy and error paths; `test/allm/providers/fake_scenarios_test.exs` exists with three `@tag :pending` placeholders for the scenarios Phase 5 activates.
- **No dependency on Phases 6–8.** Tool execution, multi-turn orchestration, and session state are out of scope. Any event emitted by the adapter that Phase 5 does not recognise (Phase 6/7 events like `:tool_execution_started`, `:step_completed`, `:chat_completed`) is passed through the stream unchanged and recorded by `StreamCollector` without error (no-op fold clauses — see Non-obvious Decision #5).

### Out of scope

- **`ALLM.step/3`, `ALLM.stream_step/3`.** Phase 6. Phase 5 ships no tool-loop orchestration; a response with `finish_reason: :tool_calls` is returned to the caller verbatim, with the tool calls on `response.tool_calls`. The caller is responsible for deciding what to do next. Fake scripts that end with `{:finish, :tool_calls}` are tested at the stream level (the `:tool_call_started`/`:tool_call_completed` events fire); they are not tested end-to-end through a tool executor.
- **`ALLM.chat/3`, `ALLM.stream/3`.** Phase 7.
- **`ALLM.Session` integration.** Phase 8.
- **Retries.** Phase 9 (spec §20, §6.1 retry policy). `engine.retry` is carried through to adapter opts but Phase 5 does not implement the retry loop — adapters own their HTTP retries until Phase 9 builds a shared `ALLM.Retry` module.
- **Telemetry.** Phase 9 (spec §29). Phase 5 does not emit `[:allm, :generate | :stream, :start | :stop | :exception]` events. The `on_event` option (spec §19) is implemented as a pass-through observer for every stream event, which covers the telemetry-like use case without a full telemetry integration.
- **Capability pre-flight (`llm_db`).** Phase 9 (spec §6.3). `resolve_model/2` already functions with `llm_db` absent (Phase 2); Phase 5 does not add a new `llm_db` code path.
- **`request_id` propagation end-to-end.** Phase 9. Phase 5 honours `adapter_opts[:request_id]` verbatim (Fake already does — it attaches to `Response.request_id`), but Phase 5 does not mint one at the top of `stream_generate/3`.
- **`structured_finalize` two-pass logic.** Phase 10 (spec §5.4). Phase 5 passes `request.structured_finalize` through to the adapter unchanged; Fake ignores it; no two-pass dance fires here.
- **Handling for orchestration events in `StreamCollector` beyond Phase 5 need.** `StreamCollector`'s catch-all absorbs every tag Phase 5 doesn't explicitly case (including orchestration events: `:tool_execution_started`, `:tool_execution_completed`, `:tool_result_encoded`, `:ask_user_requested`, `:tool_halt`, `:step_completed`, `:chat_completed`). Phase 6/7 insert per-tag clauses ahead of the catch-all to provide real semantics; no Phase 5 code changes.
- **Backpressure beyond `Stream` primitives.** The consumer's reduce rate is the only backpressure signal. Phase 5 does not implement a buffered mailbox or a demand-based `GenStage` producer. Real provider adapters in Phases 10–11 may introduce a `Task`-based producer inside their own `Stream.resource/3`; Fake does not need one because it produces events synchronously in the consumer's reducing process.

### Non-obvious decisions

1. **Extend `:message_completed` payload with an optional `:finish_reason` key (additive, not a new variant).** Spec §8's `ALLM.Event` union declares `:message_completed` with payload `%{message: Message.t()}`. Phase 5's stream-equivalence property (spec §3's first consequence) cannot hold unless the finish-reason survives the stream round-trip — `generate/3` folds `{:finish, reason}` into `%Response.finish_reason`, and `stream_generate/3 |> collect` must reach the same value. The spec §8 `ALLM.Event` type currently provides no signal for finish-reason (verified against `lib/allm/event.ex:20-42` on 2026-04-24 — the `:message_completed` payload is `%{message: Message.t()}` with no `:finish_reason` key; `Fake.closing_events/1` at `lib/allm/providers/fake.ex:520-529` emits the payload without reason).

   Three rejected alternatives:
   - **New `:finished` or `:response_completed` event variant.** Would broaden the closed union from 16 to 17 tags — `agent-spec/DESIGN.md` marks this as "a breaking change for every reducer." Rejected.
   - **Piggyback on `:raw_chunk` with `{:finish_reason, atom()}` payload.** Works but couples collectors to a particular raw-chunk shape, which is contrary to `:raw_chunk`'s opaque-payload contract (§8).
   - **Have `StreamCollector` infer finish-reason from context** (e.g., `:tool_call_completed` present → `:tool_calls`; else `:stop`). Cannot distinguish `:stop` from `:length` or `:content_filter`, and fails for `:error` streams.

   Chosen: extend the `:message_completed` payload with an optional `:finish_reason` key. Existing consumers that bind `{:message_completed, %{message: msg}}` continue to work because Elixir map patterns are non-exhaustive. The `event?/1` guard is unchanged (verified against `lib/allm/event.ex:79-85` on 2026-04-24 — line 79's clause accepts `:raw_chunk`/`:error` unconditionally; lines 81-83 accept structured variants via `is_map(payload)` + `tag in @tags`; line 85 is the catch-all `false`. Adding a key to an existing variant's map payload changes none of those three clauses' results because `is_map(payload)` doesn't care about key set). A new constructor `ALLM.Event.message_completed/2` is added; the existing arity-1 form stays and maps to `:finish_reason => nil`. Fake's `closing_events/1` threads the reason from the `{:finish, reason}` entry into the payload. Spec §8's tag count stays at 16. One row in `lib/allm/event.ex`'s `@type t` is updated to document the new key.

   `Docs target: @moduledoc ALLM.Event` (one-paragraph "Payload extensions" section listing `:finish_reason` as the Phase 5 addition and documenting the back-compat guarantee) + `@doc ALLM.Event.message_completed/2` + CHANGELOG entry.

2. **Add `StreamCollector.to_response/1` to bridge `stream_generate → Response`.** Spec §13.1 lists four functions on `StreamCollector`: `new/1`, `apply_event/2`, `to_step_result/1`, `to_chat_result/1`. None of these return a bare `%Response{}`. `generate/3` must return `{:ok, Response.t()}` per spec §10.1, so Phase 5 needs a reducer output that's smaller than `%StepResult{}` (which requires a thread to build). Two rejected alternatives:
   - **Build a throwaway thread from `request.messages` and use `to_step_result(s).response`.** Works but conflates Layer C `stream_generate/3` — which has no thread concept — with Layer D state. Surfaces a `%Thread{}` in the return path that the caller discards. Rejected.
   - **Inline the response-extraction logic inside `ALLM.Runner.run/3`.** Duplicates StreamCollector's fold in a separate place; callers reaching for manual collection (the third Layer demonstration snippet above) would lose access to the canonical path.

   Chosen: add `StreamCollector.to_response/1` as a Phase 5 extension to spec §13.1. It returns `%Response{}` built from the collector's accumulated `output_text`, `tool_calls`, `usage`, `finish_reason`, `raw_finish_reason`, and `metadata`. The addition is annotated in the `StreamCollector` moduledoc as "Phase 5 extension to spec §13.1" so a future reader understands why it's here without diffing the spec. `to_response/1` has no dependency on the thread, so it works with `new/0` (thread-less) collectors.

   `Docs target: @moduledoc ALLM.StreamCollector` + `@doc ALLM.StreamCollector.to_response/1`.

3. **`StreamCollector.new/0` exists alongside `StreamCollector.new/1`, and `new/1`'s type widens from `Thread.t()` to `Thread.t() | nil`.** `stream_generate/3` has no thread; spec §13.1 only shows `new(ALLM.Thread.t())`. Phase 5 adds `new/0` (thread-less) AND widens `new/1`'s type signature to accept `nil` so the two arities share a compile-time guarantee. Rejected alternatives: require a synthetic empty thread (ugly), or mint a thread inside `Runner.run/3` (leaks Layer D concepts into Layer C). `new/0` returns a collector with `:thread => nil`; `new/1` called with `nil` returns the same value. `to_step_result/1` and `to_chat_result/1` require a non-nil thread; calling them on a `new/0`-built or `new(nil)`-built collector raises `ArgumentError` with a message that points the caller to `to_response/1` (the right entry point for thread-less collection). `to_response/1` does not require a thread.

   This is two changes to spec §13.1 (new/0 added; new/1 widened), not one. Both are additive: every existing caller passing a non-nil `%Thread{}` is unaffected, and no existing caller passes `nil`.

   `Docs target: @doc ALLM.StreamCollector.new/0` + `@doc ALLM.StreamCollector.new/1` (cross-reference each other).

4. **Terminal `{:error, %ErrorStruct{}}` events map to `%Response{finish_reason: :error, metadata: %{error: struct}}`, and `StreamCollector.to_response/1` still returns `%Response{}`, not `{:error, _}`.** Spec §10.1 signature is `{:ok, %Response{}} | {:error, term()}`, but a mid-stream error after some content has already flowed is ambiguous: is the call a success (we got partial text) or a failure (we got an error)?

   Phase 5's rule: **a mid-stream error is a success at the `generate/3` layer** — the final `%Response{}` carries `finish_reason: :error` and the error struct in `metadata.error`. The caller inspects `response.finish_reason` to detect this. Rationale: the stream yielded events and the consumer processed them; `{:error, _}` would lose everything the collector accumulated before the error. This matches the §31 scenario "mid-stream adapter error — stream terminates with `{:error, reason}`" where the stream itself terminates with an error event but the collected response is still a valid `%Response{}`.

   **Pre-flight errors are different.** When `stream_generate/3`'s adapter call returns `{:error, %AdapterError{}}` synchronously (no stream opened), `generate/3` surfaces the error directly via `{:error, %AdapterError{}}`. The distinction is: pre-flight = no stream = `{:error, _}`; mid-stream = stream emitted events = `%Response{finish_reason: :error}`.

   Rejected: collapse both paths to `{:error, _}` for consistency — loses partial-content info. Rejected: raise on mid-stream error — breaks the spec §10.1 return contract.

   `Docs target: @doc ALLM.generate/3` (the two error paths table) + `@moduledoc ALLM.StreamCollector` ("Mid-stream errors" section).

5. **`StreamCollector`'s fold is Phase 5-scoped; orchestration events are absorbed by the catch-all, not pre-cased.** See Non-obvious Decision #12 for the full rationale. In brief: Phase 5 ships explicit clauses only for the 9 tags an adapter emits; every other tag (orchestration events Phase 6/7 will introduce) falls through to `apply_event(state, _) -> state`. Phase 6/7 add their clauses by inserting new `def apply_event/2` clauses ahead of the catch-all — they do not modify or delete any Phase 5 clause. This is the cross-phase isolation that the "one layer per phase" rule is designed to protect; it also means Phase 5's per-tag tests cannot break when Phase 6 ships.

   Stream-equivalence is preserved across phases because `generate/3` and `stream_generate/3 |> ...reduce...` both consume the same `StreamCollector.apply_event/2`; when Phase 6 fills in `:step_completed` semantics, both sides absorb the change identically.

   `Docs target: @moduledoc ALLM.StreamCollector` (see #12 for the specific section).

6. **The Phase 5 stream pipeline does NOT wrap the adapter stream in another `Stream.resource/3`.** The phasing doc's "with `Stream.resource/3` wrapping the result to attach an `after_fun` that releases the adapter's resources" is misleading as a literal prescription — wrapping an already-resource-safe `Stream.resource/3` (Fake's, per Phase 4) in another `Stream.resource/3` would double-register cleanup without adding any capability. The halt-safety contract is already owned by the adapter's cleanup hook (Fake's `after_fun` increments the `:counters` observer).

   Phase 5's post-processing is done via `Stream.each/2` for `on_event` and `Stream.filter/2` for `emit_text_deltas: false` / `emit_tool_deltas: false` / `include_raw_chunks: false`. Both operators propagate `{:halt, _}` correctly to the upstream (verified against Elixir 1.17 stdlib docs on 2026-04-24: `Stream.each/2` and `Stream.filter/2` are defined via `Stream.transform/3`, which honours `{:halt, _}` returns from the reducer). The halt-safety test in 5.4 asserts the behaviour end-to-end: `Enum.take(stream, 2)` on a 10-event script through the Phase 5 pipeline increments Fake's observer within 500 ms.

   Rejected: eagerly wrap in `Stream.resource/3` "to be safe" — adds no value, complicates cleanup ordering (two `after_fun`s firing non-deterministically), risks mis-testing because the outer `after_fun` runs even when the adapter's doesn't.

   `Docs target: internal — implementation detail documented in `lib/allm/stream_runner.ex` module-level comment.`

7. **`on_event` callback fires on every adapter event, BEFORE filters apply to the consumer stream.** A user who sets `emit_text_deltas: false` AND `on_event: &Logger.debug/1` probably wants to see every event in the log but not see text deltas in the final consumer stream. Phase 5 orders the pipeline as: adapter → `Stream.each(on_event)` → filter → consumer. So `on_event` sees the full event sequence; the consumer sees only the post-filter subset. Rationale: `on_event` is typically for telemetry/logging where completeness matters; filtering is typically for reducing data volume to the downstream consumer.

   **`on_event` failure-mode is "raises in the reducer's process, not the `stream_generate/3` caller's process."** `Stream.each/2` invokes the callback lazily — only when the consumer reduces over the stream. The `stream_generate/3` caller has already received `{:ok, stream}` and moved on; an exception inside `on_event` is raised in whatever process reduces the stream (the consumer). Phase 5 does not wrap the callback in `try/rescue`. Rationale: masking a user-supplied callback's error is surprising; callers who need fault tolerance wrap their own callback. The reducer-process distinction is load-bearing for users who were expecting a `try/rescue` at the `stream_generate/3` call site to catch `on_event` errors — it won't, because the exception hasn't fired yet when `stream_generate/3` returns.

   `Docs target: @doc ALLM.stream_generate/3` (options table with `:on_event` row noting "fires before filters, in the reducer's process; exceptions raise in the reducer, not at `stream_generate/3`'s call site").

8. **`StreamCollector.apply_event/2` is total — it never raises on a well-shaped event.** For every tag in `ALLM.Event.tags/0` (16 tags), there is a matching function clause. A malformed event (e.g., `{:text_delta, :not_a_map}`) would fail to match and fall through to the catch-all `apply_event(state, _unknown) -> state`, preserving fold totality. Rationale: the collector is a reducer over an arbitrary adapter's output; raising mid-fold would destroy already-accumulated state and leave the caller with no response at all. A property test in 5.1 asserts `apply_event/2` is total across the 16-tag union.

   `Docs target: @doc ALLM.StreamCollector.apply_event/2` ("Totality guarantee" paragraph).

9. **Option-key precedence for `:on_event`, `:emit_text_deltas`, `:emit_tool_deltas`, `:include_raw_chunks`: call opts > engine params > library defaults.** This matches spec §10's general precedence but is worth naming explicitly because the §19 streaming options kwlist doesn't travel on a struct field. `ALLM.Engine.resolve_params/2` already returns a map with the call opts winning (Phase 2); Phase 5 reads these four keys from that map. Library defaults: `emit_text_deltas: true`, `emit_tool_deltas: true`, `include_raw_chunks: false` (matches §19 prose — `include_raw_chunks` is opt-in because raw chunks are provider-specific debug data). `on_event` defaults to `nil` (no-op).

   **Exception: `{:usage, _}` raw chunks always survive the filter.** `include_raw_chunks: false` drops `:raw_chunk` events EXCEPT those whose payload matches `{:usage, _}`. Usage raw chunks are load-bearing (Phase 4 Non-obvious Decision #6: Fake emits `{:raw_chunk, {:usage, map}}` because spec §8 has no `:usage` variant), and `%Response.usage` must be populated from them regardless of the caller's filter preference. This makes `generate/3` honour `include_raw_chunks: false` without needing a Runner-side override, because the filter itself preserves the one raw-chunk shape that affects the response. Other raw-chunk payloads (provider debug data) are filtered per caller intent.

   `Docs target: @doc ALLM.stream_generate/3` (options table with defaults column, `:include_raw_chunks` row noting the usage carve-out).

10. **`ALLM.StreamRunner.run/3` and `ALLM.Runner.run/3` are public-at-the-module level (not `@doc false`), but undocumented as user-facing API.** Spec §17 shows the signatures publicly, so the modules exist; but users should reach for `ALLM.stream_generate/3` / `ALLM.generate/3` instead. The runner modules' `@moduledoc` start with "Internal — use `ALLM.stream_generate/3` instead." This gives Phase 6/7 (which will also call through these runners) a published entry point without advertising them as first-class. Rationale: keeping them callable from tests and from other internal phases is valuable; advertising them in ExDoc's landing page isn't. `ex_doc` groups them under "Internal modules" per Phase 12's docs config.

    `Docs target: @moduledoc ALLM.StreamRunner` + `@moduledoc ALLM.Runner` (both start with the "Internal" hedge).

11. **Phase 7 orchestration opts (`mode`, `max_turns`, `halt_when`) are stripped at the `StreamRunner` boundary — not forwarded to the adapter.** The spec §19 kwlist bundles streaming and orchestration opts together, but `stream_generate/3` is single-request (no loop, no turns). If a user passes `halt_when: &fn/1` to `stream_generate/3` by mistake (or by copy-pasting from a Phase 7 `chat/3` example), the value would flow through `Engine.resolve_params/2` into the adapter's params map; a real provider adapter in Phase 10–11 would trip `Jason.encode!` on the fun and fail at the wire layer with a cryptic `Protocol.UndefinedError`.

    Rejected: raise `ArgumentError` on seeing these opts — too aggressive for a legitimate copy-paste; users migrating between `stream_generate/3` and `chat/3` should not hit a crash. Rejected: silently forward and let the adapter fail — hides the intent. Chosen: `StreamRunner` maintains a `@phase_7_opts [:mode, :max_turns, :halt_when]` deny-list and drops those keys from the opts keyword list before the `resolve_params/2` call. Phase 7's own `ALLM.Chat.stream/3` will consume them instead. A `Logger.debug/1` call logs when a Phase 7 key is stripped so power users can see the drop during development; no warning (avoid log-spam in production).

    `Docs target: @moduledoc ALLM.StreamRunner` (one-paragraph "Phase 7 opts are stripped" section) + `@doc ALLM.stream_generate/3` (options table footnote).

12. **`StreamCollector` ships ONLY the Phase 5 per-tag fold clauses + a catch-all. Phase 6/7 events are NOT pre-cased as no-ops.** An earlier draft of this design (sub-phase 5.1 Test Plan) proposed per-tag no-op clauses for orchestration events (`:tool_execution_*`, `:step_completed`, `:chat_completed`, `:tool_halt`, `:ask_user_requested`, `:tool_result_encoded`). Phase 6 would then have to *modify* those clauses to add real semantics — and Phase 5's per-tag no-op assertion tests would break. That's the cross-phase coupling the "one layer per phase" rule is designed to prevent.

    Phase 5 ships explicit clauses for the 9 Phase 5-relevant tags: `:message_started`, `:text_delta`, `:text_completed`, `:tool_call_started`, `:tool_call_delta`, `:tool_call_completed`, `:message_completed`, `:raw_chunk`, `:error`. Every other tag falls through to `apply_event(state, _) -> state`. Phase 6 adds clauses for `:tool_execution_*`, `:tool_result_encoded`, `:step_completed` WITHOUT modifying any Phase 5 clause. Phase 7 adds clauses for `:ask_user_requested`, `:tool_halt`, `:chat_completed` similarly.

    The Phase 5 test plan has ONE test for the catch-all ("unknown/not-yet-implemented tags pass through without changing state") with assertions on three orchestration tags as representative samples — not one test per orchestration tag. Phase 6/7 add per-tag tests when they add per-tag clauses. `apply_event/2`'s totality property test (which iterates all 16 tags) verifies the catch-all handles the orchestration tags safely.

    `Docs target: @moduledoc ALLM.StreamCollector` ("Fold semantics — Phase 5 subset" section listing the 9 explicit tags and noting the catch-all for the rest).

## Behaviour & Type Contracts

### `ALLM.Event` (Layer A — additive payload amendment)

```elixir
defmodule ALLM.Event do
  @type t ::
          {:message_started, %{message: Message.t()}}
          | {:text_delta, %{id: String.t() | nil, delta: String.t()}}
          | {:text_completed, %{id: String.t() | nil, text: String.t()}}
          | {:tool_call_started, %{id: String.t(), name: String.t()}}
          | {:tool_call_delta, %{id: String.t(), arguments_delta: String.t()}}
          | {:tool_call_completed,
             %{id: String.t(), name: String.t(), arguments: map(), raw_arguments: String.t()}}
          | {:tool_execution_started, %{id: String.t(), name: String.t(), arguments: map()}}
          | {:tool_execution_completed, %{id: String.t(), name: String.t(), result: term()}}
          | {:tool_result_encoded, %{id: String.t(), content: String.t()}}
          | {:ask_user_requested,
             %{
               tool_call_id: String.t(),
               tool_name: String.t(),
               question: String.t(),
               opts: keyword()
             }}
          | {:tool_halt, %{tool_call_id: String.t(), reason: atom(), result: term()}}
          # Phase 5 amendment: payload gains optional :finish_reason.
          | {:message_completed,
             %{message: Message.t(), finish_reason: Response.finish_reason() | nil}}
          | {:step_completed, %{response: Response.t(), thread: Thread.t()}}
          | {:chat_completed, %{result: ChatResult.t()}}
          | {:raw_chunk, term()}
          | {:error, term()}

  # Existing arity — preserved for back-compat. New events without finish_reason
  # set the key to nil.
  @spec message_completed(Message.t()) :: t()
  def message_completed(%Message{} = message),
    do: {:message_completed, %{message: message, finish_reason: nil}}

  # Phase 5: new arity.
  @spec message_completed(Message.t(), Response.finish_reason() | nil) :: t()
  def message_completed(%Message{} = message, finish_reason)
      when is_atom(finish_reason) or is_nil(finish_reason),
      do: {:message_completed, %{message: message, finish_reason: finish_reason}}
end
```

**Invariants:**

1. `event?/1` returns `true` for `{:message_completed, %{message: _}}` regardless of whether `:finish_reason` is present (the existing map-based check is unchanged — verified against `lib/allm/event.ex:79-85` on 2026-04-24: the guard is `is_map(payload) and tag in @tags`, which doesn't inspect the payload's key set).
2. `message_completed/1` and `message_completed/2` produce identical output when the reason is `nil`. A property test (`test/allm/event_test.exs`) asserts this.
3. Every legal `finish_reason` atom in `t:Response.finish_reason/0` (`:stop | :length | :tool_calls | :content_filter | :error | :other`) is accepted by `message_completed/2`. `nil` is also accepted. Any other value raises `FunctionClauseError` at the guard (verified in IEx on OTP 27 on 2026-04-24: `is_atom(nil)` returns `true`, `is_atom(:stop)` returns `true`, `is_atom("stop")` returns `false` → guard clause `is_atom(finish_reason) or is_nil(finish_reason)` accepts nil and atoms only; a binary would FunctionClauseError).

**Idiomatic Elixir requirements:**

- The guard `is_atom(finish_reason) or is_nil(finish_reason)` accepts both `:stop` and `nil`. It does **not** enforce the closed `t:Response.finish_reason/0` enum at the event-construction boundary — that enforcement lives in the `@type t` spec and in `Response.finish_reason/0`. Rationale: `StreamCollector` may see a provider-specific reason that wasn't mapped (shouldn't happen with Fake, but will with OpenAI's "unknown" finish reasons in Phase 10); preserving it as a plain atom allows `Response.raw_finish_reason` downstream, which is the spec's escape hatch. The conformance harness (Phase 3) still drives all reasonable values through `:stop | :length | :tool_calls | :content_filter | :error | :other`.

### `ALLM.Providers.Fake` (Layer B — `:message_completed` payload fill)

Modification to `closing_events/1` in `lib/allm/providers/fake.ex:520-529` to thread the finish-reason from the `{:finish, reason}` entry. The `next_fun/1` clause at `lib/allm/providers/fake.ex:502-505` that currently discards `_reason` is updated to capture and forward it:

```elixir
# Before (Phase 4):
defp next_fun(%{entries: [{:finish, _reason} | rest]} = acc) do
  closing = closing_events(acc)
  {closing, %{acc | entries: rest, closed?: true}}
end

# After (Phase 5):
defp next_fun(%{entries: [{:finish, reason} | rest]} = acc) do
  closing = closing_events(%{acc | finish_reason: reason})
  {closing, %{acc | entries: rest, closed?: true, finish_reason: reason}}
end

defp closing_events(%{emitted_text?: true, accumulated_text: text, finish_reason: reason}) do
  [
    {:text_completed, %{id: nil, text: text}},
    {:message_completed,
     %{message: %Message{role: :assistant, content: text}, finish_reason: reason}}
  ]
end

defp closing_events(%{emitted_text?: false, finish_reason: reason}) do
  [{:message_completed,
    %{message: %Message{role: :assistant, content: ""}, finish_reason: reason}}]
end
```

**Invariants:**

1. Scripts ending with `{:finish, :stop}` produce a `:message_completed` event with `finish_reason: :stop`.
2. Scripts ending with `{:finish, :tool_calls}` produce a `:message_completed` event with `finish_reason: :tool_calls`.
3. Scripts with NO `{:finish, _}` entry still produce a terminal `:message_completed` — `finish_reason: nil` — via `close_stream/1`'s fallthrough path when `entries` is empty. The `start_fun/2` accumulator gains a `:finish_reason` field initialised to `nil` so the fallthrough has a sensible default.

**Idiomatic Elixir requirements:**

- The `start_fun/2` accumulator map gains `:finish_reason => nil` as an initial field (the existing map at `lib/allm/providers/fake.ex:456-467` is extended by one key). No struct change; the accumulator stays a plain map.

### `ALLM.StreamCollector` (Layer C — new module)

```elixir
defmodule ALLM.StreamCollector do
  @moduledoc """
  Reduce a stream of `ALLM.Event` values into a collected `%Response{}`,
  `%StepResult{}`, or `%ChatResult{}`. See spec §13.1.

  Phase 5 extensions to the spec:

    * `new/0` builds a thread-less collector used by `ALLM.stream_generate/3`.
    * `to_response/1` returns the accumulated `%Response{}` and is the
      canonical output for thread-less collection.

  Both fit alongside the spec §13.1 signatures (`new/1`, `apply_event/2`,
  `to_step_result/1`, `to_chat_result/1`) without replacing them.
  """

  alias ALLM.{ChatResult, Event, Message, Response, StepResult, Thread, ToolCall, Usage}
  alias ALLM.Error.{AdapterError, StreamError}

  @type state :: %__MODULE__{
          thread: Thread.t() | nil,
          current_text: String.t(),
          current_tool_calls: %{String.t() => ToolCall.t()},
          tool_call_order: [String.t()],
          last_response: Response.t() | nil,
          steps: [StepResult.t()],
          usage: Usage.t(),
          finish_reason: Response.finish_reason() | nil,
          raw_finish_reason: String.t() | nil,
          error: AdapterError.t() | StreamError.t() | term() | nil,
          done?: boolean(),
          metadata: map()
        }

  defstruct thread: nil,
            current_text: "",
            current_tool_calls: %{},
            tool_call_order: [],
            last_response: nil,
            steps: [],
            usage: %Usage{},
            finish_reason: nil,
            raw_finish_reason: nil,
            error: nil,
            done?: false,
            metadata: %{}

  @spec new() :: state()
  def new

  @spec new(Thread.t() | nil) :: state()
  def new(thread)

  @spec apply_event(state(), Event.t()) :: state()
  def apply_event(state, event)

  @spec to_response(state()) :: Response.t()
  def to_response(state)

  @spec to_step_result(state()) :: StepResult.t()
  def to_step_result(state)

  @spec to_chat_result(state()) :: ChatResult.t()
  def to_chat_result(state)
end
```

**Invariants:**

1. `apply_event/2` is total: for any `{tag, payload}` where `tag in Event.tags/0` and `payload` matches the variant's map shape, `apply_event/2` returns an updated state without raising. For malformed events (tag known but payload wrong shape, or tag unknown), `apply_event/2` returns the state unchanged (no-op fold). A property test asserts this over the full 16-tag union.
2. `apply_event/2` is associative over event ordering only in the trivial sense: events within a single stream are consumed left-to-right. The collector's output depends on event order (text deltas concatenate; tool call deltas accumulate per id).
3. Multiple `:text_delta` events with the same `:id` concatenate their `:delta` strings into `:current_text`. A `:text_completed` event replaces `:current_text` verbatim with the `:text` field (trusting the adapter's authoritative final text over the accumulated deltas — see Non-obvious Decision #11 below).
4. `:tool_call_started` followed by `:tool_call_delta` events (one or more) followed by `:tool_call_completed` produces one `%ToolCall{}` in `:current_tool_calls[id]`. Deltas append to `:raw_arguments`; `:tool_call_completed`'s `:arguments` and `:raw_arguments` fields replace the accumulated values (authoritative-final rule again).
5. A terminal `{:error, struct}` event sets `:error => struct` and `:finish_reason => :error`; subsequent events are folded but do not clear `:error`.
6. `:message_completed` with `:finish_reason` populates the collector's `:finish_reason` field. Without `:finish_reason` (nil or absent), the collector's existing `:finish_reason` is preserved (nil by default unless a prior `{:error, _}` set it to `:error`).
7. `:raw_chunk` with payload `{:usage, map}` folds `map` into `:usage` via `struct!(Usage, map)`. Other `:raw_chunk` payloads are passed through without affecting state.
8. `to_response/1` is callable on any collector (including thread-less). `to_step_result/1` and `to_chat_result/1` raise `ArgumentError` when `:thread` is nil, with a message directing the caller to `to_response/1`.
9. `StepResult.done?` mapping: `true` when `finish_reason in [:stop, :length, :content_filter, :error]`, `false` when `:tool_calls` or `nil`. This is a Phase 5 default; Phase 6/7 may override based on orchestration context (e.g., `halt_when` returning true sets `done?: true` regardless of finish_reason).
10. `ChatResult.halted_reason` mapping: `:completed` when `finish_reason in [:stop, :length, :tool_calls, :content_filter] or nil`, `:error` when `finish_reason == :error`. Phase 7 will add `:max_turns`, `:halt_when`, `:ask_user` as real halt reasons.

**Error reason table (for `to_response/1` output):**

`to_response/1` never returns `{:error, _}` — it always returns `%Response{}`. A mid-stream error surfaces via `%Response{finish_reason: :error, metadata: %{error: struct}}`. The struct is the `%AdapterError{}` or `%StreamError{}` from the terminal `{:error, _}` event.

**Fold algorithm — Phase 5 subset (explicit per-tag clauses + catch-all):**

Phase 5 ships explicit clauses for the 9 tags an adapter emits (per spec §8 and the Phase 4 Fake adapter event vocabulary at `lib/allm/providers/fake.ex:131-140`). Every other tag — orchestration events Phase 6/7 will introduce, plus any malformed event — falls through to a single catch-all `apply_event(state, _) -> state`. Per Non-obvious Decision #12, Phase 5 does NOT ship per-tag no-op clauses for orchestration events; Phase 6/7 add their clauses without modifying Phase 5 code.

| Event | State transition |
|-------|------------------|
| `{:message_started, %{message: _}}` | No-op. The stream may emit it but the collector has no message-start state; explicit clause so totality tests bind. |
| `{:text_delta, %{id: _, delta: d}}` | `:current_text` <> d. |
| `{:text_completed, %{id: _, text: t}}` | `:current_text` := t (authoritative-final rule). |
| `{:tool_call_started, %{id: id, name: name}}` | `:current_tool_calls[id] = %ToolCall{id, name, arguments: %{}, raw_arguments: ""}`; `:tool_call_order` appends id (if not already present). |
| `{:tool_call_delta, %{id: id, arguments_delta: ad}}` | `:current_tool_calls[id].raw_arguments` <> ad. If the tool call was not started via `:tool_call_started`, create an implicit one with name `""` (matches Fake's delta-implicit-start semantics at `lib/allm/providers/fake/script.ex:391-398`). |
| `{:tool_call_completed, %{id: id, name: name, arguments: args, raw_arguments: ra}}` | `:current_tool_calls[id] = %ToolCall{id, name, arguments: args, raw_arguments: ra}` (replace, authoritative-final). |
| `{:message_completed, %{message: msg, finish_reason: fr}}` | `:last_response` := Response built from current state + msg + fr; `:finish_reason` := fr (if non-nil). |
| `{:message_completed, %{message: msg}}` | Same as above, treating `fr` as nil (back-compat with pre-Phase-5 `message_completed/1`). |
| `{:raw_chunk, {:usage, map}}` | `:usage` := `struct!(Usage, map)`. Raises `KeyError` on unknown fields (documented pass-through). |
| `{:raw_chunk, _}` | No-op. |
| `{:error, struct}` | `:error` := struct; `:finish_reason` := `:error`. |
| any other tag (`:tool_execution_*`, `:tool_result_encoded`, `:ask_user_requested`, `:tool_halt`, `:step_completed`, `:chat_completed`, or malformed) | State unchanged via catch-all. Phase 6/7 replace the catch-all's effect for specific tags by adding earlier clauses. |

**Idiomatic Elixir requirements:**

- `struct!(Usage, map)` raises `KeyError` if the map has keys not in `%Usage{}`. Same failure mode as Fake's fold (Phase 4 Non-obvious Decision in that design). For Phase 5 tests, scripts use the committed field names (`:input_tokens`, `:output_tokens`, etc. per `lib/allm/usage.ex:26-37`). The catch-all test for `:raw_chunk` with a wrong-shaped `:usage` map asserts `apply_event/2` lets the `KeyError` propagate (this is an adapter bug, not a collector bug, so raising is correct).
- `apply_event/2`'s catch-all clause `def apply_event(state, _), do: state` goes LAST in the function; all the per-tag clauses go first.
- `Map.update/4` (four-arity) is the idiomatic path for the `:tool_call_delta` accumulation when the key may or may not exist: `Map.update(current, id, initial, &append_fun/1)`.

### `ALLM.StreamRunner` (Layer C — new internal module)

```elixir
defmodule ALLM.StreamRunner do
  @moduledoc """
  Internal — use `ALLM.stream_generate/3` instead. See spec §17.

  Validates the request, resolves model/tools/params via `ALLM.Engine`,
  dispatches to the engine adapter's `stream/2`, and applies per-§19
  post-filters and the `:on_event` observer.
  """

  alias ALLM.{Engine, Event, Request, StreamAdapter, Validate}
  alias ALLM.Error.{AdapterError, EngineError, ValidationError}

  @spec run(Engine.t(), Request.t(), keyword()) ::
          {:ok, Enumerable.t()}
          | {:error, EngineError.t() | AdapterError.t() | ValidationError.t()}
  def run(engine, request, opts \\ [])
end
```

**Invariants:**

1. `run/3` is synchronous through the dispatch point. It returns `{:ok, stream}` where `stream` is lazy — no event fires until the caller reduces — or `{:error, struct}` synchronously for pre-flight failures.
2. Validation order (short-circuits on first failure):
   1. `engine.adapter` is non-nil → else `%EngineError{reason: :missing_adapter}`.
   2. `engine.adapter` has `stream/2` exported (via `function_exported?(adapter, :stream, 2)`, which also accepts the adapter's `@behaviour ALLM.StreamAdapter` declaration as sufficient — verified in IEx on OTP 27 on 2026-04-24: `function_exported?(ALLM.Providers.Fake, :stream, 2)` returns `true`). Else `%EngineError{reason: :missing_stream_adapter}`.
   3. `Validate.request(request)` returns `:ok` → else `%ValidationError{}` (the validator's output, passed through verbatim).
3. After validation, `run/3` builds the final request (model resolved via `Engine.resolve_model/2`), resolves params via `Engine.resolve_params/2` into an opts map, and dispatches to `engine.adapter.stream(final_request, dispatch_opts)` where `dispatch_opts` is a keyword list containing `[adapter_opts: engine.adapter_opts ++ opts[:adapter_opts] || []]` merged into the `resolve_params/2` map (converted back to a keyword list).
4. The adapter's returned stream (or `{:error, _}`) is passed to `post_process/2`:
   - `{:error, %AdapterError{}}` returns verbatim — pre-flight error, no stream.
   - `{:ok, stream}` applies `Stream.each(on_event)` first (if `on_event` is non-nil), then `Stream.filter/2` to drop `:text_delta` / `:tool_call_delta` / `:raw_chunk` events per the `emit_*` / `include_raw_chunks` opts.
5. The post-processed stream is the return value; consumer halt propagates to the adapter's internal `Stream.resource/3` cleanup hook via stdlib `Stream.filter/2` and `Stream.each/2` halt semantics.

**Error reason table (synchronous pre-flight):**

| Function | Error reason | Recovery guidance |
|----------|--------------|--------------------|
| `StreamRunner.run/3` | `%EngineError{reason: :missing_adapter}` | Caller passed `ALLM.Engine.new/1` without `:adapter`. Fix the engine construction. |
| `StreamRunner.run/3` | `%EngineError{reason: :missing_stream_adapter}` | Engine's adapter implements `ALLM.Adapter` but not `ALLM.StreamAdapter`. Swap to an adapter that implements both, or call `ALLM.generate/3` (Phase 5 defers non-streaming to the adapter's `generate/2` via collection — but it still requires a `StreamAdapter` because `generate/3` is `stream_generate/3 |> collect`). This error is in the adapter's module shape, not in a flag. |
| `StreamRunner.run/3` | `%ValidationError{reason: :invalid_request}` (or `:vision_not_in_v0_2`) | Request shape violates `ALLM.Validate.request/1`. See `err.errors` list for the offending field paths. |
| `StreamRunner.run/3` | `%AdapterError{reason: _}` | Adapter pre-flight error. Pass-through from `engine.adapter.stream/2`. |

**Idiomatic Elixir requirements:**

- `function_exported?(adapter, :stream, 2)` is the idiomatic behaviour-conformance check (verified against spec §7.2: Fake declares `@behaviour ALLM.StreamAdapter` at `lib/allm/providers/fake.ex:165`, which makes `stream/2` exported). Using `Code.ensure_loaded?/1` + `function_exported?/3` handles the case where the adapter module isn't loaded yet (late-resolved from a serialized engine per Phase 2's serializability contract). The two calls are combined: `Code.ensure_loaded?(adapter) and function_exported?(adapter, :stream, 2)`.
- `with` pipeline style — one line per validation step, final `do` block dispatches to the adapter. Named `with` bindings (e.g., `with :ok <- check_adapter(engine), ...`) are clearer than nested `case`.
- `Stream.each/2` returns a stream that invokes the fun for each element and forwards the element unchanged; it does not change arity. `Stream.filter/2` drops elements for which the predicate returns falsey. Both are lazy and propagate `{:halt, _}` — verified against Elixir 1.17 `Stream` module docs on 2026-04-24.

### `ALLM.Runner` (Layer C — new internal module)

```elixir
defmodule ALLM.Runner do
  @moduledoc """
  Internal — use `ALLM.generate/3` instead. See spec §17.

  Delegates to `ALLM.StreamRunner.run/3`, folds the stream through
  `ALLM.StreamCollector`, and returns the collected `%Response{}`.
  """

  alias ALLM.{Engine, Request, Response, StreamCollector, StreamRunner}
  alias ALLM.Error.{AdapterError, EngineError, ValidationError}

  @spec run(Engine.t(), Request.t(), keyword()) ::
          {:ok, Response.t()}
          | {:error, EngineError.t() | AdapterError.t() | ValidationError.t()}
  def run(engine, request, opts \\ [])
end
```

**Invariants:**

1. Pre-flight errors (`StreamRunner.run/3` returned `{:error, _}`) bubble up verbatim — `{:error, struct}` matches.
2. A successfully-opened stream is reduced through `StreamCollector.new() |> Enum.reduce(stream, ..., &apply_event/2)` and the final collector's `to_response/1` is returned wrapped in `{:ok, _}`.
3. A mid-stream terminal `{:error, struct}` event is folded into `%Response{finish_reason: :error, metadata: %{error: struct}}` — the call is still `{:ok, response}` at the Runner layer (Non-obvious Decision #4). Callers distinguish via `response.finish_reason == :error`.
4. `opts` are forwarded to `StreamRunner.run/3` verbatim. Any runner-specific opts (e.g., `:include_raw_chunks`) still apply — the Runner consumes the post-filtered stream, so `:include_raw_chunks: false` correctly strips raw chunks before the fold reaches `StreamCollector`.

**Error reason table:** identical to `StreamRunner.run/3`'s.

**Idiomatic Elixir requirements:**

- `with {:ok, stream} <- StreamRunner.run(engine, request, opts), ...` — one `with` clause plus a `do` block that folds.

### `ALLM` (Layer C — public facade additions)

```elixir
defmodule ALLM do
  @spec generate(Engine.t(), Request.t(), keyword()) ::
          {:ok, Response.t()}
          | {:error, EngineError.t() | AdapterError.t() | ValidationError.t()}
  def generate(engine, request, opts \\ []), do: ALLM.Runner.run(engine, request, opts)

  @spec stream_generate(Engine.t(), Request.t(), keyword()) ::
          {:ok, Enumerable.t()}
          | {:error, EngineError.t() | AdapterError.t() | ValidationError.t()}
  def stream_generate(engine, request, opts \\ []),
    do: ALLM.StreamRunner.run(engine, request, opts)
end
```

**Invariants:**

1. `generate/3` and `stream_generate/3` are pure delegations — no logic beyond the delegation. Makes doctests predictable and keeps the facade a transparent entry point.
2. Doctests on both functions use `ALLM.Providers.Fake` with `[adapter_opts: [script: [{:text, "hi"}, {:finish, :stop}]]]` — the smallest script that exercises every happy-path fold rule.

## Module Tree

```
lib/allm/
├── event.ex                              (MODIFY — add message_completed/2 + payload key; @type t row amendment)
├── providers/
│   └── fake.ex                           (MODIFY — closing_events/1 threads finish_reason into :message_completed payload)
├── stream_collector.ex                   (NEW — ALLM.StreamCollector)
├── stream_runner.ex                      (NEW — ALLM.StreamRunner, internal)
└── runner.ex                             (NEW — ALLM.Runner, internal)

lib/allm.ex                               (MODIFY — add stream_generate/3 and generate/3)

test/allm/
├── event_test.exs                        (MODIFY — add tests for message_completed/2 + payload compatibility)
├── providers/
│   ├── fake_stream_test.exs              (MODIFY — assert :finish_reason on :message_completed when script has {:finish, _})
│   └── fake_scenarios_test.exs           (MODIFY — flip three @tag :pending → active for the 3 Phase 5 scenarios)
├── stream_collector_test.exs             (NEW — per-variant fold + totality + to_* outputs)
├── stream_runner_test.exs                (NEW — dispatch + validation + filters + on_event)
├── runner_test.exs                       (NEW — dispatch + fold + mid-stream error mapping)
├── stream_equivalence_test.exs           (NEW — property test: generate ≡ stream_generate |> collect)
├── allm_generate_test.exs                (NEW — facade + doctest)
└── allm_stream_generate_test.exs         (NEW — facade + doctest)

CHANGELOG.md                              (MODIFY — one line per new public symbol)
```

Test files mirror source files 1:1. No `test/support/` changes — the existing `ALLM.Test.FakeFixtures` carries every script shape Phase 5 needs.

## Phases

### Sub-phase 5.1: `:message_completed` payload amendment + `ALLM.StreamCollector` (Layer A micro-amendment + Layer C fold state)

**Goal:** Extend `ALLM.Event.message_completed/2` to accept a `finish_reason` arg and populate the payload; thread the reason through Fake's `closing_events/1`; ship `ALLM.StreamCollector` with the Phase 5 per-tag fold clauses (9 explicit tags + catch-all per Non-obvious Decision #12), `new/0`, `new/1`, `apply_event/2`, `to_response/1`, `to_step_result/1`, `to_chat_result/1`. The Phase 4 fallout test (`fake_stream_test.exs`) flips from ignoring finish_reason to asserting its presence.

**Spec sections:** §8 (additive payload amendment), §13.1 (collector)

#### 5.1.1 Test Plan (write first)

`test/allm/event_test.exs` (MODIFY):

- `message_completed/1` returns payload `%{message: msg, finish_reason: nil}` — new assertion on the `:finish_reason` key.
- `message_completed/2` with `:stop` returns payload `%{message: msg, finish_reason: :stop}`.
- `message_completed/2` with `nil` returns payload identical to `message_completed/1`.
- `message_completed/2` with a binary raises `FunctionClauseError` (verified in IEx on OTP 27 on 2026-04-24 per the Behaviour & Type Contracts section).
- `event?/1` returns `true` for `{:message_completed, %{message: msg}}` (no finish_reason key) — back-compat guarantee.
- `event?/1` returns `true` for `{:message_completed, %{message: msg, finish_reason: :stop}}`.

`test/allm/providers/fake_stream_test.exs` (MODIFY):

- For a script `[{:text, "hi"}, {:finish, :stop}]`, the terminal `:message_completed` event's payload contains `finish_reason: :stop`.
- For a script `[{:tool_call, id: "t", name: "w"}, {:finish, :tool_calls}]`, the terminal `:message_completed` event's payload contains `finish_reason: :tool_calls`.
- For a script WITHOUT `{:finish, _}` (e.g., `script: []`), the terminal `:message_completed` event's payload has `finish_reason: nil`.
- The Phase 4 conformance `use ALLM.Test.StreamAdapterConformance` line still passes unchanged (the harness binds `%{}` patterns on `:message_completed`, so the new key is invisible to it).

`test/allm/stream_collector_test.exs` (NEW):

Per-variant fold (one test per Phase 5-relevant tag):

- `apply_event(new(), {:message_started, %{message: msg}})` is a no-op (state unchanged).
- `apply_event(new(), {:text_delta, %{id: nil, delta: "hel"}})` sets `current_text: "hel"`.
- Two `:text_delta` events with the same id → `current_text: "hello"`.
- `:text_completed` after deltas → `current_text` replaced verbatim by the event's `:text` field.
- `:tool_call_started` creates an entry in `current_tool_calls` with empty arguments/raw_arguments.
- `:tool_call_delta` appends to `raw_arguments`.
- `:tool_call_delta` on an id not yet started creates an implicit entry with `name: ""` (matches Fake's `lib/allm/providers/fake/script.ex:391-398` semantics).
- `:tool_call_completed` replaces the entry with authoritative `arguments` + `raw_arguments`.
- `:tool_call_order` preserves first-seen order across multiple tool calls.
- `:message_completed` with `finish_reason: :stop` sets `finish_reason: :stop` on state.
- `:message_completed` without `finish_reason` (back-compat — the existing `message_completed/1` constructor with payload `%{message: msg, finish_reason: nil}`) leaves state `finish_reason` unchanged from prior if prior was non-nil; if prior was nil, remains nil.
- `:raw_chunk` with `{:usage, %{input_tokens: 5, output_tokens: 2}}` sets `usage` to `%Usage{input_tokens: 5, output_tokens: 2, ...}`.
- `:raw_chunk` with a non-usage payload (e.g., `"some string"`) is a no-op.
- `:error` with `%AdapterError{reason: :rate_limited}` sets `error: struct`, `finish_reason: :error`.
- `:error` with `%StreamError{reason: :cancelled}` same.

Catch-all (one test, representative samples per Non-obvious Decision #12):

- `apply_event(state, {:tool_execution_started, %{...}})` returns state unchanged.
- `apply_event(state, {:step_completed, %{...}})` returns state unchanged.
- `apply_event(state, {:chat_completed, %{...}})` returns state unchanged.
- `apply_event(state, :not_even_a_tuple)` returns state unchanged.
- `apply_event(state, {:tool_call_delta, :not_a_map})` returns state unchanged (malformed — catch-all absorbs).
- Per-tag clauses for orchestration events are NOT asserted here — Phase 6/7 will add them when those clauses gain real semantics.

Outputs:

- `to_response/1` on a collector with text + tool calls + usage + finish_reason produces a correctly-populated `%Response{}`.
- `to_response/1` on a new/empty collector produces `%Response{output_text: "", finish_reason: nil, usage: %Usage{}}`.
- `to_response/1` on a collector after a terminal `:error` event produces `%Response{finish_reason: :error, metadata: %{error: struct}}`.
- `to_step_result/1` with a non-nil thread on a collector where `finish_reason == :tool_calls` returns `%StepResult{thread: thread, response: response, tool_results: [], done?: false}` — `done?` is `false` when more adapter work is expected (tool execution → next adapter call in Phase 6).
- `to_step_result/1` with a non-nil thread on a collector where `finish_reason in [:stop, :length, :content_filter, :error]` returns `%StepResult{done?: true}` — terminal finish reasons set `done?: true`.
- `to_step_result/1` with `finish_reason: nil` (no `:message_completed` seen yet, or `:message_completed` without reason) returns `%StepResult{done?: false}` — conservative default; caller decides based on other context.
- `to_step_result/1` with a nil thread (from `new/0`) raises `ArgumentError` with message `"StreamCollector.to_step_result/1 requires a thread; use new/1 with a thread, or call to_response/1 for thread-less collection"`.
- `to_chat_result/1` with a non-nil thread returns `%ChatResult{thread: thread, final_response: response, steps: [], halted_reason: reason}` where `reason` is: `:completed` when `finish_reason in [:stop, :length, :tool_calls, :content_filter]` (normal termination), `:error` when `finish_reason == :error` (mid-stream error), `:completed` when `finish_reason == nil` (conservative default — no halt signal seen).
- `to_chat_result/1` with a nil thread raises `ArgumentError` with the same style message as `to_step_result/1`.

Totality property test (`test/allm/stream_collector_property_test.exs` OR included as a `describe "totality"` block in `stream_collector_test.exs` for simplicity — pick the inline form):

- For every tag in `ALLM.Event.tags/0` and every random map payload (use `StreamData`), `apply_event/2` either returns `%StreamCollector{}` or raises only when the payload's `:usage` map has unknown keys (the documented `KeyError` pass-through).

#### 5.1.2 Implementation Checklist

- [ ] `lib/allm/event.ex` — add `message_completed/2` with guard `is_atom(finish_reason) or is_nil(finish_reason)`; update `message_completed/1` to set `finish_reason: nil` in payload; update `@type t` row for `:message_completed` to reflect the new key; add `@moduledoc` "Payload extensions" paragraph.
- [ ] `lib/allm/providers/fake.ex` — extend `start_fun/2` accumulator with `:finish_reason => nil`; update `next_fun/1`'s `{:finish, reason}` clause to capture reason; extend `closing_events/1`'s two clauses to read `:finish_reason` from the accumulator and include it in the `:message_completed` payload.
- [ ] `lib/allm/stream_collector.ex` — new module, all functions listed in Behaviour & Type Contracts, one `apply_event/2` clause per tag + catch-all.
- [ ] Doctests: at least one on `new/0`, one on `apply_event/2`, one on `to_response/1`.
- [ ] `@spec` on every public function.
- [ ] `@moduledoc` covering the "Phase 5 extensions" paragraph, the "Orchestration events" no-op pointer, and the "Mid-stream errors" mapping per Non-obvious Decision #4.

#### 5.1.3 Verification

```bash
mix test test/allm/event_test.exs
mix test test/allm/providers/fake_stream_test.exs
mix test test/allm/stream_collector_test.exs
mix test --cover                                  # ≥90% on lib/allm/stream_collector.ex
mix dialyzer
mix credo --strict lib/allm/event.ex lib/allm/providers/fake.ex lib/allm/stream_collector.ex
mix format --check-formatted
```

### Sub-phase 5.2: `ALLM.StreamRunner` + `ALLM.stream_generate/3` (Layer C)

**Goal:** Ship the streaming entry point. `StreamRunner.run/3` validates, resolves, dispatches; `stream_generate/3` is a one-line delegation. `emit_text_deltas: false`, `emit_tool_deltas: false`, `include_raw_chunks: false`, `on_event: fn/1` all functional through this layer.

**Spec sections:** §3, §4, §10.2, §17, §19

#### 5.2.1 Test Plan (write first)

`test/allm/stream_runner_test.exs` (NEW):

Dispatch + happy path:
- `run/3` with a Fake engine and `script: [{:text, "hi"}, {:finish, :stop}]` returns `{:ok, stream}`; `Enum.to_list(stream)` includes `:message_started`, `:text_delta`, `:text_completed`, `:message_completed`.
- Events arrive in script order.

Error paths:
- `run/3` with `engine.adapter: nil` returns `{:error, %EngineError{reason: :missing_adapter}}`.
- `run/3` with an adapter that implements only `ALLM.Adapter` (build a no-op stub in the test file) returns `{:error, %EngineError{reason: :missing_stream_adapter}}`.
- `run/3` with a request whose `messages: []` returns `{:error, %ValidationError{reason: :invalid_request, errors: [{:messages, :empty}]}}` (matches Phase 1's validator output).
- `run/3` with a request containing a vision message returns `{:error, %ValidationError{reason: :vision_not_in_v0_2}}` (Phase 1 hard-reject rule).
- `run/3` when the Fake adapter's `stream/2` returns a pre-flight error (script `[{:preflight_error, :authentication_failed, []}]`) returns `{:error, %AdapterError{reason: :authentication_failed}}`.

Filters (§19):
- With `emit_text_deltas: false`, `Enum.to_list(stream)` does NOT contain any `:text_delta` event, but `:text_completed` and `:message_completed` still present; the collector (if applied) still sees the correct text via `:text_completed`.
- With `emit_tool_deltas: false` on a script that includes `:tool_call_delta` entries, `Enum.to_list(stream)` does NOT contain `:tool_call_delta` events.
- With `include_raw_chunks: false` (the default) and a script with a non-usage raw chunk (e.g., `{:raw_chunk, "debug"}`), the stream does NOT emit the `:raw_chunk` event; with `include_raw_chunks: true`, it does.
- With `include_raw_chunks: false` and a `{:usage, %{input_tokens: 1}}` script entry, the stream DOES emit the `{:raw_chunk, {:usage, _}}` event — the filter's usage carve-out (Non-obvious Decision #9) preserves it regardless of the flag. Test asserts: both `include_raw_chunks: false` and `include_raw_chunks: true` yield a stream containing the usage raw chunk.
- Both filters compose: `emit_text_deltas: false` AND `include_raw_chunks: false` drops both kinds (text deltas + non-usage raw chunks) from the same stream; usage raw chunks still pass.
- Filter precedence: call opts > engine params. Engine with `params: %{emit_text_deltas: false}` and call opts `[emit_text_deltas: true]` keeps deltas.

`on_event` callback:
- `on_event: fn e -> send(self(), {:saw, e}) end` — assert every event the adapter produces ends up in the mailbox via `assert_received/1`. Count matches `Enum.to_list(stream) |> length/0` of the PRE-filter stream.
- `on_event` fires EVEN for events later filtered out — the `{:saw, _text_delta}` message arrives even when `emit_text_deltas: false`.
- `on_event` that raises propagates the exception (stream crashes with the original exception). Test uses `try/rescue` on the stream reduce.
- `on_event: nil` (default) is a no-op.

Phase 7 opts stripped (Non-obvious Decision #11):
- `run/3` with `[mode: :auto]` in opts succeeds; the dispatch to `engine.adapter.stream/2`'s opts kwlist does NOT contain `:mode`. Assert via a test-local adapter that records its received opts (or inject an `adapter_opts: [opts_recorder: pid]` hook for Fake if one can be added inline).
- `run/3` with `[max_turns: 5, halt_when: &fn/1]` — same: keys stripped from dispatch opts. The fun value does not reach the adapter's params map (prevents Jason-encode failures in Phase 10+).
- `run/3` with `[mode: :auto, emit_text_deltas: false]` — `mode` is stripped, `emit_text_deltas` is consumed by the filter.

Halt propagation:
- `Enum.take(stream, 2)` through the Phase 5 pipeline still fires Fake's `:counters` cleanup observer within 500 ms (regression test for Non-obvious Decision #6 — ensures `Stream.each/2` and `Stream.filter/2` propagate halt). Target ceiling is 500 ms (matches Phase 3 harness); if CI consistently flakes at 500 ms due to scheduler stalls, bump to 1000 ms as a pragmatic follow-up — do NOT remove the timing assertion because halt-safety is structural and a non-bounded test would hide regressions.

Doctest:
- `@doc` on `ALLM.StreamRunner.run/3` with a minimal Fake engine + script.

`test/allm/allm_stream_generate_test.exs` (NEW):

- `stream_generate/3` with a Fake engine returns `{:ok, stream}`.
- `stream_generate/3` with a nil-adapter engine returns `{:error, %EngineError{reason: :missing_adapter}}`.
- Doctest using `ALLM.Providers.Fake` and the `[adapter_opts: [script: ...]]` pattern.

#### 5.2.2 Implementation Checklist

- [ ] `lib/allm/stream_runner.ex` — new module, `run/3` with the `with` pipeline (check_adapter → check_stream_adapter → Validate.request → resolve_model → strip_phase_7_opts → resolve_params → dispatch → post_process).
- [ ] `@phase_7_opts [:mode, :max_turns, :halt_when]` module attribute; `strip_phase_7_opts/1` drops these keys from the opts kwlist (Non-obvious Decision #11) and logs via `Logger.debug/1` when a key is dropped.
- [ ] `post_process/2` applies `Stream.each(on_event)` (if present) then `Stream.filter/2` for the three filters. The filter fun is built once per call, not per event.
- [ ] Filter's raw-chunk clause distinguishes `{:usage, _}` payload (always pass) from other payloads (drop when `include_raw_chunks: false`). Implementation: `defp keep?({:raw_chunk, {:usage, _}}, _opts), do: true` ahead of the general `:raw_chunk` drop clause. Test coverage in 5.2.1.
- [ ] `lib/allm.ex` — add `stream_generate/3` with `@spec` and `@doc` (doctest using Fake).
- [ ] Phase 5-consumed keys (`:emit_*`, `:include_raw_chunks`, `:on_event`) are read directly from opts by StreamRunner, NOT from `resolve_params/2`'s output — keeps the filter/callback wiring explicit. `:adapter_opts`, `:request_timeout`, `:stream_timeout`, `:tool_timeout` pass through to `engine.adapter.stream/2` via the resolved opts kwlist.
- [ ] `request_timeout` / `stream_timeout` / `tool_timeout` are passed through to `engine.adapter.stream/2` via the opts kwlist — adapters enforce them (spec §30); Phase 5 does not.
- [ ] `on_event` failure mode: no try/rescue (Non-obvious Decision #7). Exception raises in the reducer process, not at `stream_generate/3`'s call site. Users who need resilience wrap their own callback.
- [ ] `function_exported?/3` adapter conformance check: `Code.ensure_loaded?(adapter) and function_exported?(adapter, :stream, 2)`. This catches "module not loaded" and "module doesn't export `stream/2`". A module that exports `stream/2` but doesn't declare `@behaviour ALLM.StreamAdapter` still passes — duck-typing is acceptable at this layer; conformance correctness is enforced by the Phase 3 harness, not by the pre-flight check.

#### 5.2.3 Verification

```bash
mix test test/allm/stream_runner_test.exs
mix test test/allm/allm_stream_generate_test.exs
mix test --cover                                  # ≥90% on lib/allm/stream_runner.ex
mix dialyzer
mix credo --strict lib/allm/stream_runner.ex lib/allm.ex
mix format --check-formatted
```

### Sub-phase 5.3: `ALLM.Runner` + `ALLM.generate/3` (Layer C)

**Goal:** Ship the non-streaming entry point as a reducer over the streaming entry point, enforcing the stream-first principle (spec §3). `Runner.run/3` delegates to `StreamRunner.run/3` with the caller's opts unmodified, folds through `StreamCollector`, returns `{:ok, %Response{}}`. Because the `include_raw_chunks: false` filter preserves `{:usage, _}` raw chunks (Non-obvious Decision #9), no Runner-side override is needed — the collector sees usage regardless of the caller's filter preference, and non-usage raw chunks are filtered per the caller's intent.

**Spec sections:** §3, §4, §10.1, §17

#### 5.3.1 Test Plan (write first)

`test/allm/runner_test.exs` (NEW):

Happy path:
- `run/3` with a Fake engine and script `[{:text, "hi"}, {:finish, :stop}]` returns `{:ok, %Response{output_text: "hi", finish_reason: :stop}}`.
- `run/3` with a script producing tool calls returns `%Response{tool_calls: [%ToolCall{...}], finish_reason: :tool_calls}`.
- `run/3` with `include_raw_chunks: false` (default) still surfaces `Usage` when the script has `{:usage, _}`. The filter preserves `{:usage, _}` raw chunks per Non-obvious Decision #9's carve-out, so the collector sees the usage event and folds it into `Response.usage` regardless of the caller's filter preference. A targeted test asserts: call `run/3` with explicit `include_raw_chunks: false` and a `{:usage, %{input_tokens: 5}}` script entry → `response.usage.input_tokens == 5`.
- `run/3` with `include_raw_chunks: false` AND a non-usage `:raw_chunk` payload (e.g., `{:raw_chunk, "debug"}`) — the collector's `to_response/1` output ignores the raw_chunk regardless, and the filter drops it from the stream before the collector sees it. Tests that the non-usage payload never reaches the collector (no side-effects on response).

Error paths:
- `run/3` with `engine.adapter: nil` → `{:error, %EngineError{reason: :missing_adapter}}`.
- `run/3` with a non-StreamAdapter adapter → `{:error, %EngineError{reason: :missing_stream_adapter}}`.
- `run/3` with an invalid request → `{:error, %ValidationError{}}`.
- `run/3` with a pre-flight adapter error (Fake's `{:preflight_error, _, _}`) → `{:error, %AdapterError{}}`.

Mid-stream error mapping (Non-obvious Decision #4):
- `run/3` with script `[{:text, "partial"}, {:error, :rate_limited}]` returns `{:ok, %Response{output_text: "partial", finish_reason: :error, metadata: %{error: %AdapterError{reason: :rate_limited}}}}`.
- `run/3` with a `{:stream_error, :cancelled, []}` script entry (harness shape) returns `{:ok, %Response{finish_reason: :error, metadata: %{error: %StreamError{reason: :cancelled}}}}`.

`test/allm/allm_generate_test.exs` (NEW):

- `generate/3` with a Fake engine returns `{:ok, %Response{}}`.
- `generate/3` with a nil-adapter engine returns the expected error.
- Doctest using Fake.

#### 5.3.2 Implementation Checklist

- [ ] `lib/allm/runner.ex` — new module. `run/3` delegates to `StreamRunner.run/3` with the caller's opts unmodified; the usage-preserving filter (sub-phase 5.2) handles usage-folding correctness without a Runner-side override.
- [ ] `Enum.reduce(stream, StreamCollector.new(), &StreamCollector.apply_event(&2, &1))` — the fold.
- [ ] `StreamCollector.to_response/1` for the final response.
- [ ] `lib/allm.ex` — `generate/3` delegates.
- [ ] Doctests and `@spec`s.

#### 5.3.3 Verification

```bash
mix test test/allm/runner_test.exs
mix test test/allm/allm_generate_test.exs
mix test --cover                                  # ≥90% on lib/allm/runner.ex
mix dialyzer
mix credo --strict lib/allm/runner.ex lib/allm.ex
mix format --check-formatted
```

### Sub-phase 5.4: Stream-equivalence property + halt-safety + §31 scenario wiring (Layer C — tests only)

**Goal:** Prove the stream-first invariant and the cancellation contract. Wire Phase 4's three `@tag :pending` placeholders in `fake_scenarios_test.exs` to active tests.

**Spec sections:** §3, §30, §31

#### 5.4.1 Test Plan (write first)

`test/allm/stream_equivalence_test.exs` (NEW):

Property (`StreamData`):

- `stream_of_scripts` generator yields any valid `spec31_entry` list drawn from `{:text, "X"}`, `{:tool_call, id: "id_N", name: "t_N", arguments: %{}}`, `{:tool_call_delta, id: "id_N", arguments_delta: "Y"}`, `{:usage, %{input_tokens: 1, output_tokens: 1}}`, terminated by `{:finish, reason}` where `reason in [:stop, :length, :tool_calls, :content_filter]`. Generator EXCLUDES `{:delay, _}`, `{:sleep, _}` (timing noise), `{:error, _}` (short-circuit paths — handled by the separate mid-stream-error property), and `{:raw_chunk, _}` with non-usage payloads (no user-visible effect on `%Response{}`).
- The property harness calls both sides with `include_raw_chunks: true` explicitly — equivalence must hold across the full event set, including usage raw chunks. (If either side ran with `include_raw_chunks: false`, the property would still hold because usage raw chunks are carved out from the filter per Non-obvious Decision #9; testing with `true` is the stricter form.)
- For every generated script, assert:
  ```elixir
  {:ok, stream_resp} =
    ALLM.generate(engine_of(script), request_fixture(), [])
  {:ok, stream} = ALLM.stream_generate(engine_of(script), request_fixture(), [])
  collected_resp =
    stream
    |> Enum.reduce(ALLM.StreamCollector.new(), &ALLM.StreamCollector.apply_event(&2, &1))
    |> ALLM.StreamCollector.to_response()
  assert stream_resp == collected_resp
  ```
  Each iteration uses a fresh process (via `Task.async/1` + `Task.await/1`) to isolate Fake's per-process cursor, OR uses an Agent-backed cursor via `start_script_cursor/0` per the Fake API.
- 100 iterations default; `@tag :property` so CI can gate them.

Mid-stream error equivalence (separate property):
- For scripts ending with `{:error, reason}` where reason is an `AdapterError.legal_reasons()` atom, assert `generate/3`'s `response.finish_reason == :error` AND `response.metadata.error.reason == reason`.

`test/allm/providers/fake_scenarios_test.exs` (MODIFY — flip pending → active for 3 scenarios):

- **pure text streaming with `emit_text_deltas: false`:** construct a Fake engine, call `stream_generate/3` with `[emit_text_deltas: false]`; assert no `:text_delta` events; assert `:text_completed` still present; assert `generate/3` on the same engine produces `%Response{output_text: "hello"}` — the non-streaming path is unaffected by the filter.
- **mid-stream adapter error — stream terminates with `{:error, reason}`:** script `[{:text, "partial"}, {:error, :rate_limited}]`; `stream_generate/3` → events include a terminal `{:error, %AdapterError{reason: :rate_limited}}`; `generate/3` → `%Response{output_text: "partial", finish_reason: :error, metadata: %{error: _}}`.
- **consumer cancellation releases resources:** 10-event script `[{:text, "a"}, ..., {:text, "j"}, {:finish, :stop}]` passed with `[adapter_opts: [script: ..., cleanup_observer: ref]]`; call `stream_generate/3`, consumer does `Enum.take(stream, 2)`, assert `:counters.get(ref, 1) == 1` via the eventually/2 helper within 500 ms. This is the Phase 5-layer regression test for Non-obvious Decision #6 (Phase 5 doesn't break halt-safety).

Halt-safety through filters (separate assertion in scenarios file):
- Same 10-event fixture but with `emit_text_deltas: false`; consumer does `Enum.take(stream, 2)`; assert counter increments within 500 ms. Pins that filter composition doesn't break halt.

#### 5.4.2 Implementation Checklist

- [ ] `test/allm/stream_equivalence_test.exs` — StreamData property + mid-stream error property; tag `@moduletag :property`.
- [ ] `test/allm/providers/fake_scenarios_test.exs` — remove `@tag :pending` from the three Phase 5-coverable tests; implement their bodies; update the comment block at the top of the file to mark which scenarios are now active versus pending.
- [ ] Run `mix test --only spec_31` — verify six scenarios active (three Phase 4 + three new Phase 5); remaining three still `@tag :pending`.
- [ ] Final `CHANGELOG.md` rollup: one line per new public symbol (StreamCollector, StreamRunner, Runner, stream_generate/3, generate/3, message_completed/2).

#### 5.4.3 Verification

```bash
mix test test/allm/stream_equivalence_test.exs
mix test --only spec_31                           # 6 active Phase 4+5 scenarios; 3 remain :pending
mix test                                          # full suite green
mix test --cover                                  # ≥90% on every new file, ≥80% global
mix credo --strict
mix dialyzer
mix format --check-formatted
mix hex.build                                     # main package still clean
```

## Test Plan (cross-phase)

**Unit tests.** Every public function on `ALLM.Event`, `ALLM.Providers.Fake` (regression slice), `ALLM.StreamCollector`, `ALLM.StreamRunner`, `ALLM.Runner`, and the two facade additions (`ALLM.stream_generate/3`, `ALLM.generate/3`) has happy-path + error-path coverage. `apply_event/2` has one test per `ALLM.Event.tags/0` tag (16 tags).

**Behaviour conformance tests.** No new behaviours in Phase 5. The existing `use ALLM.Test.AdapterConformance` / `use ALLM.Test.StreamAdapterConformance` in Phase 4's Fake tests continue to pass unchanged — verify as part of the regression slice in 5.1.

**Integration tests.** The three flipped `@tag :pending` scenarios in `fake_scenarios_test.exs` are the first true integration tests exercising `stream_generate/3` + Fake end-to-end. `runner_test.exs` and `stream_runner_test.exs` are module-level integration between the runner and Fake.

**Property tests.** Stream-equivalence property (`stream_equivalence_test.exs`) is the load-bearing correctness test — 100 iterations of randomly generated §31 scripts. Mid-stream error equivalence (same file) is a separate property. `StreamCollector.apply_event/2` totality property (inline in `stream_collector_test.exs`) asserts no tag raises.

**Doctests.** `ALLM.stream_generate/3`, `ALLM.generate/3`, `ALLM.Event.message_completed/2`, `ALLM.StreamCollector.new/0`, `ALLM.StreamCollector.apply_event/2`, `ALLM.StreamCollector.to_response/1`, `ALLM.StreamRunner.run/3`, `ALLM.Runner.run/3` each carry one runnable doctest using `ALLM.Providers.Fake`.

**Serializability tests.** No Layer A struct changes of substance. `ALLM.Event` is a tagged-tuple union (not a struct); its serializability is already proven in Phase 1's `event_property_test.exs` via `:erlang.term_to_binary/1` round-tripping. The new `:finish_reason` payload key is a plain atom → serializes transparently. A paranoia assertion in `event_test.exs` round-trips a `:message_completed` event with `finish_reason: :stop` through ETF and Jason.

**Stream-equivalence tests.** This is Phase 5's cornerstone. The property in `stream_equivalence_test.exs` asserts `generate ≡ stream_generate |> collect` for every fixture. Separate scenario-level assertions in `scenarios_test.exs` cover the three Phase 5-activated §31 bullets. The template pattern (generator + assertion) is reusable for Phase 6 (`step ≡ stream_step |> collect`) and Phase 7 (`chat ≡ stream |> collect`).

**Coverage threshold.** `mix.exs` configures 80 % globally. Phase 5 targets ≥90 % on `lib/allm/stream_collector.ex`, `lib/allm/stream_runner.ex`, `lib/allm/runner.ex`, and the two new public functions in `lib/allm.ex`. Branch coverage on `StreamCollector.apply_event/2`'s tag dispatch is the key risk — per-variant tests ensure every clause is exercised.

## Error Contract

| Function | Error reason | Recovery guidance |
|----------|--------------|--------------------|
| `ALLM.stream_generate/3` | `%EngineError{reason: :missing_adapter}` | Construct an engine with `:adapter`. Non-recoverable without engine change. |
| `ALLM.stream_generate/3` | `%EngineError{reason: :missing_stream_adapter}` | Adapter module does not implement `ALLM.StreamAdapter`. Use a stream-capable adapter (e.g., `ALLM.Providers.Fake`, future `ALLM.Providers.OpenAI`). |
| `ALLM.stream_generate/3` | `%ValidationError{reason: :invalid_request}` | Request shape invalid per `ALLM.Validate.request/1`. See `err.errors` for field-level issues. |
| `ALLM.stream_generate/3` | `%ValidationError{reason: :vision_not_in_v0_2}` | Vision content parts are a v0.2 hard-reject (spec §33). Remove image parts or wait for v0.3. |
| `ALLM.stream_generate/3` | `%AdapterError{reason: _}` (synchronous, pre-flight) | Adapter rejected the request before opening the stream. Reason per `ALLM.Error.AdapterError` table. |
| `ALLM.stream_generate/3` stream event | `%AdapterError{reason: _}` (mid-stream, terminal) | Provider returned an HTTP-shaped error after SSE started. Stream terminates; collected response (if used) has `finish_reason: :error`. |
| `ALLM.stream_generate/3` stream event | `%StreamError{reason: _}` (mid-stream, terminal) | Transport-shaped error (cancellation, timeout, malformed event). Stream terminates; collected response has `finish_reason: :error`. |
| `ALLM.generate/3` | `%EngineError{reason: :missing_adapter}` | Same as `stream_generate/3`. |
| `ALLM.generate/3` | `%EngineError{reason: :missing_stream_adapter}` | Same as `stream_generate/3` — `generate/3` is a reducer over `stream_generate/3` and needs a streaming-capable adapter. |
| `ALLM.generate/3` | `%ValidationError{...}` | Same as `stream_generate/3`. |
| `ALLM.generate/3` | `%AdapterError{reason: _}` (synchronous only) | Pre-flight adapter error. Mid-stream errors are NOT surfaced here — they fold into `response.finish_reason: :error` (Non-obvious Decision #4). |
| `ALLM.StreamCollector.to_step_result/1` | `ArgumentError` (`:thread_required`) | Thread-less collector (built with `new/0`). Call `to_response/1` instead, or pass a thread to `new/1`. |
| `ALLM.StreamCollector.to_chat_result/1` | `ArgumentError` (`:thread_required`) | Same as above. |
| `ALLM.StreamCollector.apply_event/2` | `KeyError` | Only raised when a `:raw_chunk {:usage, map}` event has unknown keys for `%Usage{}`. Adapter-side bug (Fake fold already enforces this). |
| `ALLM.Event.message_completed/2` | `FunctionClauseError` | `finish_reason` was neither an atom nor `nil`. Programmer error. |

**Field-error atom vocabulary:** Not applicable — Phase 5 ships no validator-shaped module. The Phase 1 vocabulary on `ALLM.Validate.request/1` is the only validator Phase 5 touches, and it is consumed verbatim.

**Hard-reject semantics:** Not applicable at the Phase 5 layer. Phase 1's `:vision_not_in_v0_2` hard-reject is the only one that surfaces here, and it's already hard-rejecting in the validator.

**No new atoms introduced.** Phase 5 uses existing `ALLM.Error.EngineError.@legal_reasons` atoms (`:missing_adapter`, `:missing_stream_adapter` — both committed at `lib/allm/error/engine_error.ex:30-38`), existing `ALLM.Error.AdapterError.@legal_reasons` atoms (all 12 from Phase 1+4), existing `ALLM.Error.StreamError.@legal_reasons` atoms (all 5 from Phase 1), and existing `ALLM.Error.ValidationError` reasons. Verified against the committed enums on 2026-04-24.

## Streaming & Backpressure

- **Cleanup is mandatory and inherited from the adapter.** Fake's `Stream.resource/3` at `lib/allm/providers/fake.ex:448-454` owns cleanup; Phase 5's `Stream.each/2` and `Stream.filter/2` operators propagate `{:halt, _}` upstream. The Phase 5 pipeline does NOT introduce a second `Stream.resource/3` (Non-obvious Decision #6). The halt-safety regression test in 5.4 verifies the end-to-end contract through filter composition.
- **Backpressure model.** The consumer's reduce rate is the only signal. Fake's `{:delay, ms}` entries already implement synthetic latency inside `next_fun/1` (Phase 4 design); Phase 5 forwards those delays unchanged. No buffering, no demand signalling. Real provider adapters in Phases 10–11 may run a `Task`-based producer inside their own `Stream.resource/3`; Phase 5's runners do not care.
- **Cancellation.** Consumer halt (`Enum.take/2`, `Stream.take_while/2` returning false, consumer process exit with a trappable reason) propagates through `Stream.each/2` and `Stream.filter/2` to Fake's `after_fun`. The 500 ms ceiling is the conformance harness bound from Phase 3/4; Phase 5's regression test asserts the ceiling holds through the Phase 5 pipeline. `Process.exit(consumer, :kill)` still does NOT fire cleanup — inherited OTP limitation per Phase 4's brutal-kill caveat; not tested.

Phase 5's streaming design does not add any new `Stream.resource/3` or `Task`-based producer. The entire phase is lazy composition via stdlib `Stream.each/2` and `Stream.filter/2`, which inherits halt-safety and backpressure from the adapter layer. This is deliberate — introducing a new producer process or cleanup hook would duplicate Phase 4's guarantees and risk the cleanup double-fire problem called out in Non-obvious Decision #6.

## Definition of Done

- [ ] All four sub-phases marked `Completed` in the status table.
- [ ] `mix test` passes with zero failures, zero `unused_var` warnings; coverage ≥80 % globally and ≥90 % on `lib/allm/stream_collector.ex`, `lib/allm/stream_runner.ex`, `lib/allm/runner.ex`, and on the new lines in `lib/allm/event.ex`, `lib/allm/providers/fake.ex`, `lib/allm.ex`.
- [ ] `mix credo --strict` passes on changed files.
- [ ] `mix dialyzer` passes against the prior PLT with zero new warnings.
- [ ] `mix format --check-formatted` passes.
- [ ] Every new public function has an `@spec` and a non-empty `@doc`.
- [ ] Doctests run under `mix test`: `ALLM.stream_generate/3`, `ALLM.generate/3`, `ALLM.Event.message_completed/2`, `ALLM.StreamCollector.new/0`, `ALLM.StreamCollector.apply_event/2`, `ALLM.StreamCollector.to_response/1`, `ALLM.StreamRunner.run/3`, `ALLM.Runner.run/3`.
- [ ] The Phase 4 `use ALLM.Test.StreamAdapterConformance, stream_adapter: ALLM.Providers.Fake` line in `fake_stream_test.exs` still passes the 14 injected cases unchanged (regression — the `:message_completed` payload extension is back-compat).
- [ ] The Phase 4 `use ALLM.Test.AdapterConformance, adapter: ALLM.Providers.Fake` line in `fake_test.exs` still passes the 13 injected cases (non-streaming path unaffected by Phase 5).
- [ ] Stream-equivalence property passes 100 random fixtures in `stream_equivalence_test.exs`.
- [ ] Halt-safety regression test passes within 500 ms through both the filter-free and `emit_text_deltas: false` pipeline variants.
- [ ] `mix test --only spec_31` reports 6 passing (3 Phase 4 + 3 Phase 5) and 3 still `@tag :pending`.
- [ ] `CHANGELOG.md` has one entry per new public symbol and one for the `:message_completed` payload extension.
- [ ] `mix hex.build` succeeds; main package includes the three new `lib/` files.
- [ ] Commit messages reference §3, §4, §8, §10.1, §10.2, §13.1, §17, §19, §20, §30, §31 as appropriate.
- [ ] Reviewed via `/review` per `agent-spec/REVIEW.md`.
