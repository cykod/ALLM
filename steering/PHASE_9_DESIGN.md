# Phase 9: Telemetry, Capability Pre-flight, and Retries — Design Document

> **Goal:** Light up three cross-cutting Layer B concerns that the v0.2 stack has been deferring to a single rollup: `:telemetry.span/3` instrumentation at every public execution boundary (`generate`, `stream_generate`, `step`, `stream_step`, `chat`, `stream`, plus per-tool spans inside `ALLM.ToolRunner`); a shared retry helper (`ALLM.Retry`) with the spec §6.1 default policy that adapters call from inside their own HTTP loops; and `ALLM.Capability`, an optional `Code.ensure_loaded?(LLMDB)`-gated module that pre-flights tool / `response_format` capability and populates `Usage` cost fields when the catalog is loaded.
> **Outcome:** A library user can attach telemetry handlers (`:telemetry.attach_many/4`) to `[:allm, :generate | :stream | :step | :chat | :tool | :adapter, :start | :stop | :exception | :retry]` and observe every public execution with `:duration`, `:request_id`, `:engine`, `:model`, plus span-specific metadata. A `request_id` is generated once at the entry of every Layer-C public function, threaded through every span's `:start` / `:stop` / `:exception` metadata, and surfaces on `Response.request_id` (existing field, populated post-`StreamCollector`). An adapter that calls `ALLM.Retry.run/3` retries on the spec-default closed set (`429 | 500 | 502 | 503 | 504 | :timeout`), respects `Retry-After`, applies bounded jitter, and emits `[:allm, :adapter, :retry]` per attempt; streaming calls never retry. With `LLMDB` absent (the default v0.2 manifest), pre-flight is a no-op and `Usage` cost fields remain `nil`; with `LLMDB` loaded (verified via a `test/support/llm_db.ex` test-fake that mimics the published-package surface), `ALLM.Capability.preflight/2` rejects tool requests against a tools-disabled model with `{:error, %ALLM.Error.ValidationError{reason: :unsupported_capability}}` before the adapter sees the request, and `ALLM.Capability.populate_costs/2` fills `Usage.{input_cost, output_cost, total_cost}` from the catalog's pricing. `mix test`, `mix credo --strict`, `mix dialyzer`, `mix format --check-formatted` all green; ≥ 90 % coverage on every new file. Two CI matrix legs run the full suite: one with `test/support/llm_db.ex` (the loaded path) and one without (the absent path) — proving the dep-free smoke test.
> **Spec sections:** §6.1 (Engine `:retry` field — already shipped in Phase 2; this phase consumes it), §6.3 (capability pre-flight + cost population + `select:` capability-based selection), §20 (retry policy + the `:retry` reason enum row), §29 (telemetry — event names, measurements, metadata).
> **Layers touched:** **A + B (cross-cutting).** `ALLM.Retry` and `ALLM.Capability` are Layer B runtime helpers that adapters and `ALLM.Engine` call; the telemetry instrumentation wraps the existing Layer C entry points (`ALLM.Runner.run/3`, `ALLM.StreamRunner.run/3`, `ALLM.Chat.run/3`, `ALLM.Chat.stream/3`, `ALLM.Chat.step/3`, `ALLM.Chat.stream_step/3`, `ALLM.ToolRunner.run_tool_calls/3`) but the cross-cutting concern itself is Layer B (`:telemetry` is the integration point per spec §29 — handler installation happens once at application boot, not per-call). One Layer A addition: `ALLM.ModelRef` (spec §6.3 lines 637-648 declares this struct as ALLM-owned; it has not yet shipped in any prior phase; Phase 9.4 adds it because `Capability.preflight/2` and `populate_costs/2` consume `%ALLM.ModelRef{}` values). `Response.request_id` already exists from Phase 1; `Usage.{input_cost, output_cost, total_cost}` already exist from Phase 1 — no field additions to those structs. One scoped Phase 1 vocabulary extension on `ALLM.Error.ValidationError.@type reason` (`:unsupported_capability`).
> **Phasing doc:** [`PROJECT_PHASING.md`](PROJECT_PHASING.md) Phase 9.

## Status

| Sub-phase | Description | Layer | Status |
|-----------|-------------|-------|--------|
| 9.1 | `:telemetry.span/3` at generate / stream / step / chat boundaries + `request_id` generation and propagation through telemetry metadata + `Response.request_id` population | B | DONE |
| 9.2 | Per-tool `:telemetry.span/3` inside `ALLM.ToolRunner` + parallel-task attribution | B | DONE |
| 9.3 | `ALLM.Retry` module (default policy + jitter + `Retry-After`) + `[:allm, :adapter, :retry]` per-attempt telemetry + Fake-adapter `retry_until_call:` opt (honored by both `generate/2` and `stream/2`) + dep-free retry-helper tests | B | DONE |
| 9.4 | `ALLM.ModelRef` Layer A struct (spec §6.3) + `ALLM.Capability` module (pre-flight + cost population + `select:`) gated on `Code.ensure_loaded?(LLMDB)` + `:unsupported_capability` ValidationError vocabulary extension + `test/support/llm_db.ex` fake catalog + dep-free CI leg via `Application.put_env/3` override | A + B | DONE |

**Overall Progress:** 4/4 sub-phases complete

## Overview

Phase 9 is **additive instrumentation and runtime helpers** — none of the prior-phase contracts change shape, no Layer A struct grows a field, and every existing test continues to pass without modification. The phase pays down four observability/operability debts that Phase 1–8 deliberately deferred: callers can't observe execution without reading source; adapters duplicate retry logic each implementation; the `llm_db` integration was promised by spec §6.3 but never landed; and `request_id` was reserved on `Response` (`lib/allm/response.ex:22`) without ever being populated. Each sub-phase is independently shippable and has its own `mix test` / `mix credo --strict` / `mix dialyzer` green bar.

The phase's load-bearing correctness obligation is **dep-free function preservation**: with no `LLMDB` module loaded into the BEAM, every existing test passes, every existing public API behaves identically, and `Code.ensure_loaded?(LLMDB)` returns `false`. CI proves this by running the full suite twice: once with `test/support/llm_db.ex` compiled (which mimics the published-package surface — `model/1`, `select/1`) and once with `elixirc_paths/1` excluding it. Both legs must be green. This is the third "no-llm_db" smoke test; the first lives in `test/allm/engine_test.exs`'s `resolve_model/2` row, the second is the implicit case where the suite runs today (no `LLMDB` exists). Phase 9.4 makes the matrix explicit so a future Phase 9-style change can't regress dep-free function silently.

The phase's second obligation is **`request_id` is a metadata-only thread, not an event-protocol field.** The phasing doc raises this as a key decision (a). Chosen: telemetry-metadata only (`:request_id` appears in every span's `:start` / `:stop` / `:exception` measurements map AND on `Response.request_id` post-collection); the `ALLM.Event` closed-tagged-tuple union is **not** extended. Rationale below in Non-obvious Decision #1. The cost: a consumer who folds the event stream by hand (without `ALLM.StreamCollector`) does not see `:request_id` per-event; they read it post-fact from `Response.request_id` after `StreamCollector.to_response/1`. This is the same trade-off the spec §29 metadata table makes — `:request_id` lives on the span, not on each event chunk.

The phase's third obligation is **the `:retry` engine field already exists (`lib/allm/engine.ex:42`, type `:default | false | keyword()`); Phase 9.3 consumes it but does not change its shape.** No `Engine` struct change. The retry execution loop lives in `ALLM.Retry`, which adapters call inside their own HTTP-request function. Spec §6.1's "Retries are adapter-implemented" rule is preserved — `ALLM.Retry.run/3` is a shared helper, not a wrapper around the adapter. The Fake adapter ships its own retry-loop integration (a `retry_until_call: n` opt on `adapter_opts`) so retry semantics are exercised end-to-end without a real provider. Real-provider integration lands in Phase 10/11; both adapters call the same `ALLM.Retry.run/3` helper.

The phase's fourth obligation is **streaming calls are never retried.** Spec §6.1 is explicit: "Streaming calls are not retried automatically (partial output has already been delivered to the consumer)." `ALLM.Retry.run/3` is for non-streaming adapter loops; the streaming adapter's `stream/2` callback never invokes it. This is enforced at the `ALLM.StreamAdapter` behaviour-doc level (Phase 9.3 adds a `@moduledoc` paragraph) plus the conformance suite's "streaming adapter does not call `ALLM.Retry.run/3`" doc note. There is no programmatic enforcement — adapters are trusted; the conformance test surfaces violations as test failures with a hand-written assertion (Phase 10/11 will lift this into a meta-check).

The phase's fifth obligation is **the `:unsupported_capability` ValidationError reason atom is added to the closed enum at `lib/allm/error/validation_error.ex:23-31` AND to the `@legal_reasons` word-list at `lib/allm/error/validation_error.ex:41-49`.** Per `AGENT_DESIGN_SPEC.md` §3 rule 5 + Phase 8.1's pattern, this is a scoped Phase 1 vocabulary extension surfaced explicitly here. Without both edits, `ValidationError.new(:unsupported_capability, [...])` raises `ArgumentError` at construction time. Verified against `lib/allm/error/validation_error.ex:24-31` (committed enum) on 2026-04-25.

The phase's sixth obligation is **telemetry spans are layered around existing Layer C functions, not into Layer C internals.** `:telemetry.span/3` wraps the public-facing `ALLM.Runner.run/3`, `StreamRunner.run/3`, `Chat.run/3`, `Chat.step/3`, `Chat.stream/3`, `Chat.stream_step/3`, and `ToolRunner.run_tool_calls/3` from the **outside** — the implementation of these functions is unchanged, but they are wrapped in a thin `def run(...)` that invokes `:telemetry.span/3` with the body as the closure. This keeps the telemetry concern visible at one site per function and avoids per-line `:telemetry.execute/3` calls scattered through orchestration code. See Phase 9.1's worked example below.

The phase's seventh obligation is **adapter retries emit `[:allm, :adapter, :retry]` per attempt.** Spec §29 lists only the six top-level event names; spec §6.1 adds the retry event explicitly ("Each retry attempt emits `[:allm, :adapter, :retry]` telemetry"). Phase 9.3's `ALLM.Retry.run/3` is the single emission site. Metadata: `%{attempt: 1..max_attempts, delay_ms: integer, reason: term, request: Request.t() | nil}`. Measurements: `%{system_time: integer}` (the moment the retry is *scheduled*, before sleep). `:reason` is the term that triggered the retry (a status code, an error atom, or an opaque error term per the adapter's surface).

### Layer demonstration

**Layer B — Telemetry handler integration:**

```elixir
:telemetry.attach_many(
  "my-allm-logger",
  [
    [:allm, :generate, :stop],
    [:allm, :chat, :stop],
    [:allm, :tool, :exception]
  ],
  fn name, measurements, metadata, _config ->
    Logger.info("#{inspect(name)} duration=#{measurements.duration} request_id=#{metadata.request_id}")
  end,
  nil
)
{:ok, _resp} = ALLM.generate(engine, request)
```

**Layer B — Adapter retry integration (used by future OpenAI/Anthropic adapters; exercised in v0.2 by Fake):**

```elixir
def generate(request, opts) do
  retry_policy = Keyword.fetch!(opts, :retry)
  request_id = Keyword.fetch!(opts, :request_id)

  ALLM.Retry.run(retry_policy, %{request_id: request_id, request: request, provider: :fake},
    fn ->
      case do_http_request(request, opts) do
        {:ok, response} -> {:ok, response}
        {:error, {:status, 429, headers}} = err -> {:retry, retry_after(headers), err}
        {:error, {:status, code, _}} = err when code in [500, 502, 503, 504] -> {:retry, 0, err}
        {:error, :timeout} = err -> {:retry, 0, err}
        {:error, _} = err -> err
      end
    end)
end
```

**Layer B — Capability pre-flight (LLMDB-loaded path):**

```elixir
# When LLMDB is loaded, Engine.resolve_model/2 returns a %ModelRef{}.
ref = ALLM.Engine.resolve_model(engine, [])  # %ALLM.ModelRef{capabilities: %{tools: %{enabled: false}}, ...}
:ok = ALLM.Capability.preflight(ref, request)
# OR:
{:error, %ValidationError{reason: :unsupported_capability, errors: [{[:tools], :tools_disabled}]}} =
  ALLM.Capability.preflight(ref, %Request{tools: [some_tool]})
```

**Layer B — Cost population:**

```elixir
ref = ALLM.Engine.resolve_model(engine, [])  # %ModelRef{pricing: %{input: 0.15, output: 0.6}}
usage = %ALLM.Usage{input_tokens: 1_000, output_tokens: 500}
populated = ALLM.Capability.populate_costs(usage, ref)
# populated.input_cost == 0.15 / 1_000_000 * 1_000 == 0.00015
# populated.output_cost == 0.6 / 1_000_000 * 500 == 0.0003
# populated.total_cost == 0.00045
```

### Deliverables

- **New modules:**
  - `lib/allm/model_ref.ex` — `ALLM.ModelRef` (Layer A). Plain struct mirroring spec §6.3 lines 637-648: `:provider, :id, :capabilities, :limits, :pricing, metadata: %{}`. Implements `Jason.Encoder` via `ALLM.Serializer.encode_tagged/2` and `__from_tagged__/1`; registered in `ALLM.Serializer.@known_modules` so `from_json/1` round-trips. ETF round-trip is the load-bearing Layer A test. Constructor `new/1` is `struct!/2`-based (raises `KeyError` on unknown opts). 9.4 adds the struct; the prior phases never used it — verified by grep against `lib/` returning zero matches as of 2026-04-25.
  - `lib/allm/retry.ex` — `ALLM.Retry`. `run/3` runs a closure under the engine's retry policy, emits `[:allm, :adapter, :retry]` per attempt via direct `:telemetry.execute/3` (the event is single-emission, not a span — Decision #16), returns the closure's `{:ok, _}` on success or its last `{:error, _}` on exhaustion. Default policy is materialized via `default_policy/0`; opaque keyword-list overrides per spec §6.1.
  - `lib/allm/capability.ex` — `ALLM.Capability`. `preflight/2` returns `:ok | {:error, %ValidationError{}}`; `populate_costs/2` returns an updated `%Usage{}`; `select/1` delegates to `LLMDB.select/1` when loaded. All three are no-ops (or pass-through identity) when `LLMDB` is not loaded; `select/1` returns `{:error, :catalog_not_loaded}` in the absent path.
  - `lib/allm/telemetry.ex` — `ALLM.Telemetry`. Internal helper. `span/4`, `execute/3`, `request_id/0`, plus a `@event_prefix [:allm]` constant. `span/4` is a thin wrapper around `:telemetry.span/3` that injects `:request_id`, `:engine`, `:model` into both `:start` and `:stop` metadata so per-callsite duplication is avoided. The closure return shape matches `:telemetry.span/3`'s contract — `(-> {result, stop_metadata_extras :: map()})` — so per-span `:stop`-only metadata (`:response`, `:step_result`, `:chat_result`, `:result`) flows naturally; `execute/3` is for non-span single-emission events (currently only `[:allm, :adapter, :retry]`, used by `ALLM.Retry`).
- **Modified modules:**
  - `lib/allm/runner.ex` — wrap `run/3` body in `ALLM.Telemetry.span([:allm, :generate], ...)`; populate `Response.request_id` after collection.
  - `lib/allm/stream_runner.ex` — wrap `run/3` body in `ALLM.Telemetry.span([:allm, :stream], ...)`; thread `request_id` through into `dispatch_opts` so the adapter receives it.
  - `lib/allm/chat.ex` — wrap `run/3`, `step/3`, `stream/3`, `stream_step/3` bodies in `ALLM.Telemetry.span([:allm, :chat | :step], ...)`. The four wrap sites are at the public-function boundary; internal helpers stay un-instrumented.
  - `lib/allm/tool_runner.ex` — wrap each tool execution inside the per-tool task with `ALLM.Telemetry.span([:allm, :tool], ...)`; metadata includes `:tool`, `:tool_call`, `:engine`, `:request_id` (threaded in from the calling Chat function via opts).
  - `lib/allm/providers/fake.ex` — accept `retry_until_call: pos_integer()` in `adapter_opts`; integrate with `ALLM.Retry.run/3`. Used by Phase 9.3's tests; deterministic per-process state via the existing `ALLM.Providers.Fake.Script` mechanism.
  - `lib/allm/error/validation_error.ex` — extend `@type reason` and `@legal_reasons` with `:unsupported_capability` (one new atom).
  - `mix.exs` — leave the `# :llm_db re-added in Phase 9 ...` comment as-is; do **not** add `{:llm_db, "~> X.Y", optional: true}` (Non-obvious Decision #6).
- **Test support:**
  - `test/support/llm_db.ex` — `LLMDB` (no `ALLM.` prefix — mimics the published-package module name verbatim). Implements `model/1` and `select/1` against an in-memory map of test fixtures. **Compiled only in `:test`** via `elixirc_paths(:test)`. The dep-absent path is simulated by an `Application.put_env(:allm, :force_capability_absent, true)` override that `ALLM.Capability.catalog_loaded?/0` consults BEFORE delegating to `Code.ensure_loaded?/1` (per Decision #5; this is reliable, async-safe, and does not require module deletion).
  - `test/support/telemetry_capture.ex` — `ALLM.Test.TelemetryCapture`, a `Process.put/2`-based handler that attaches to a list of event names, captures all events into a list, and exposes `events/0`, `attach/1`, `detach/1`. Used by every Phase 9.1 / 9.2 / 9.3 test. Process-isolated so parallel tests don't cross-contaminate; `:telemetry.attach/4` with a unique handler-id per `setup` block (`"allm-test-#{inspect(self())}-#{System.unique_integer([:positive])}"`).
- **New tests:**
  - `test/allm/telemetry_test.exs` — span-emission tests for every wrapped function (12 spans = 6 wrap sites × 2 events `:start`/`:stop`, plus `:exception` rows for each).
  - `test/allm/retry_test.exs` — `ALLM.Retry.run/3` unit tests: success on first call, success after N-1 retries, exhaustion, `Retry-After` honored, jitter bounds, default policy materialization.
  - `test/allm/capability_test.exs` — `ALLM.Capability` unit tests: `preflight/2` happy path, tool-disabled rejection, json-schema rejection, `populate_costs/2` math, `LLMDB`-absent pass-through.
  - `test/allm/error/validation_error_test.exs` — extended with one row asserting `:unsupported_capability` is a legal reason.
  - `test/allm/providers/fake_retry_test.exs` — Fake adapter end-to-end retry: scripted `retry_until_call: 3` succeeds on attempt 3 and emits `[:allm, :adapter, :retry]` × 2; streaming-no-retry assertion drives `Fake.stream/2 with retry_until_call: 3` and asserts the stream surfaces the failure mid-stream WITH zero `[:allm, :adapter, :retry]` events (Fake honors `retry_until_call:` on the streaming path by emitting an `{:error, _}` event the first n-1 times — Decision #11).
  - `test/allm/model_ref_test.exs` — Layer A unit tests for `ALLM.ModelRef`: `new/1` happy path, ETF round-trip, Jason round-trip, `__from_tagged__/1` field-by-field hydration. Mirrors the Phase 1 pattern for every Layer A struct.
  - Modified — `test/allm/allm_generate_test.exs`, `test/allm/allm_stream_generate_test.exs`, `test/allm/chat_run_test.exs`, `test/allm/chat_step_test.exs`, `test/allm/chat_stream_test.exs`, `test/allm/chat_stream_step_test.exs` (verified flat layout under `test/allm/` on 2026-04-25): one telemetry-emission row per public function asserting `[:allm, :<span>, :start]` and `[:allm, :<span>, :stop]` fire with the documented metadata, INCLUDING per-span `:stop`-only metadata (`:response` for `:generate` / `:stream`; `:step_result` for `:step`; `:chat_result` for `:chat`).
- **Modified facade:** none. All public ALLM-level entry points already exist; Phase 9 wraps their internals.
- **CHANGELOG:** one line per public sub-phase (4 lines total); each cites its spec §-number.

### Spec coverage

| Spec § | Phase 9 implements |
|--------|--------------------|
| §6.1 (`:retry` field + retry policy) | Field already shipped (`lib/allm/engine.ex:42`); 9.3 consumes it via `ALLM.Retry`. |
| §6.3 (capability pre-flight + cost + `select:`) | 9.4 — `ALLM.Capability.preflight/2`, `populate_costs/2`, `select/2`. |
| §20 (error reasons — `:unsupported_capability` row) | 9.4 vocabulary extension on `ValidationError`. |
| §29 (telemetry events + measurements + metadata) | 9.1 (generate/stream/step/chat) + 9.2 (tool) + 9.3 (`[:allm, :adapter, :retry]`). |

### Prerequisites

- Phases 1–8 complete. Phase 9 wraps existing Layer C entry points; nothing in 9 lands without their stable surfaces.
- `:telemetry ~> 1.2` already in `mix.exs:38`. No dep change.
- `Response.request_id :: String.t() | nil` already exists on `lib/allm/response.ex:22`. Phase 9.1 populates it; no struct change.
- `Usage.{input_cost, output_cost, total_cost} :: float() | nil` already exist on `lib/allm/usage.ex:19-21`. Phase 9.4 populates them; no struct change.
- `Engine.retry :: :default | false | keyword()` already on `lib/allm/engine.ex:42` with the documented `@type retry` (line 57). No struct change.
- `ALLM.Error.ValidationError.@type reason` extended with `:unsupported_capability` in 9.4 — single-atom scoped extension at `lib/allm/error/validation_error.ex:23-31` (committed `:invalid_request | :invalid_message | :invalid_tool | :invalid_thread | :invalid_session | :invalid_session_input | :vision_not_in_v0_2`) + `@legal_reasons` word-list at lines 41-49 (verified 2026-04-25 against the committed file).

### Out of scope

- **Real-provider HTTP transport.** Phase 10 (OpenAI) / Phase 11 (Anthropic). Phase 9.3 ships `ALLM.Retry` and the Fake-adapter integration; the actual `Finch` / `Req` retry loops in real providers consume it but are not implemented here.
- **`structured_finalize: true` two-pass execution.** Phase 10 (spec §5.4). Phase 9.4 ships the **capability declaration** that triggers it (`requires_structured_finalize?/1` on adapters), but the two-pass execution itself lands with the OpenAI adapter where it's first needed.
- **Adding `:llm_db` to `mix.exs` as a dep.** Non-obvious Decision #6. Phase 9.4 is integration-by-runtime-existence-check only; the dep is tested with a `test/support/llm_db.ex` fake. A real `:llm_db` Hex dep is added in a future phase (or by the application user) when the published package version is stable.
- **Adapter conformance for retries.** Phase 9.3 ships the `ALLM.Retry` module; the Phase 3 adapter-conformance suite is **not** extended to assert "you must call `ALLM.Retry`" — that's a v0.3 question (a meta-check requires runtime introspection of the adapter's HTTP loop, which the v0.2 conformance harness does not have). The Phase 3 harness gets one new doc paragraph explaining the contract; enforcement is left to future-phase code review.
- **Telemetry on Session operations.** Spec §29's event list is `[:llm, :generate | :stream | :step | :chat | :tool]` — Session is not in the list. Phase 9 keeps this verbatim. A caller who wants a session-level span attaches their own `[:allm, :session, ...]` handler around `ALLM.Session.start/3` etc. at the application layer.
- **`request_id` propagation into `ALLM.Event` payloads.** Non-obvious Decision #1. The `:request_id` field stays on telemetry metadata and `Response.request_id`; the event-protocol union is not extended.
- **`request_id` propagation into `ChatResult`.** `ChatResult.final_response.request_id` already carries the value transitively; adding a `ChatResult.request_id` field is a Layer A change for negligible value over the existing path. Out of scope.
- **Histograms / counters on top of telemetry.** Application concern (the user attaches `:telemetry_metrics_*`); ALLM ships the events.
- **Application-config retry policies.** `Application.get_env(:allm, :retry, :default)` is **not** consulted. Spec §6 resolution chain stops at engine + opts; introducing an app-config layer would add a fourth precedence row Phase 9 doesn't need. The engine field is the single source of truth.
- **`select:` capability-based selection at `ALLM.request/2` level.** Spec §6.3 sample shows `ALLM.request(messages, select: [require: ..., prefer: ...])`. Phase 9.4 ships `ALLM.Capability.select/2` as the helper, but wiring `select:` through `Request` construction and request-time resolution is deferred — `ALLM.Engine.resolve_model/2`'s current contract returns the engine's `:model` verbatim or via `LLMDB.model/1`, not through `LLMDB.select/1`. Adding `select:` to the resolution chain is a Layer-B contract addition that deserves its own spec-cite-and-test pass; deferred to a follow-on phase. The helper exists in 9.4 so the integration is one wire-up away.

### Non-obvious decisions

1. **`:request_id` is metadata-only — it does NOT extend the `ALLM.Event` closed union.** The phasing doc raises this as a key decision (a). Chosen: telemetry-metadata thread (`:request_id` appears in every span's `:start` / `:stop` / `:exception` metadata maps AND on `Response.request_id` post-collection), NOT a per-event field. Rationale: (a) the event union is a closed tagged-tuple type (`lib/allm/event.ex:31-66`) that 14 reducers — `StreamCollector`, the four `chat/3` orchestrators, `Session.StreamReducer`, the conformance suite, every test fixture — pattern-match on; adding a field to every variant's payload map is a 16-tag spread mutation with the documented "additive payload-map keys are non-breaking" carve-out (`CLAUDE.md` §Architecture / `:step_completed` `:mode` precedent), but the actual *value* is the same per-stream constant — duplicating it 14× per stream is denormalized; (b) telemetry handlers are the integration point per spec §29, and they receive `:request_id` for free in span metadata; (c) consumers who want per-event correlation can attach a `Stream.each/2` callback that pulls `:request_id` from the surrounding context (the same context that opened the stream), no protocol change required; (d) `Response.request_id` is the canonical post-fact carrier (already on the struct since Phase 1). Cost: a hand-folded event consumer who never collects to a `%Response{}` and never attaches a telemetry handler does not see `:request_id`; this is a deliberate carve-out matching the spec §29 metadata model. `Docs target: @moduledoc ALLM.Telemetry` ("Why request_id is metadata-only" paragraph).

2. **Telemetry spans wrap public Layer C functions from the outside; the internal implementation is unchanged.** Each wrap site is a 5-line transformation: extract the body into a private `do_run/3`, wrap the public `run/3` in `ALLM.Telemetry.span([:allm, :generate], start_meta(engine, request, opts), fn -> do_run(engine, request, opts) end)`. Rationale: the alternative is per-line `:telemetry.execute/3` calls inside orchestration code, which (a) couples instrumentation to control flow (every `with`-chain needs an `:exception` arm), (b) makes the contract harder to read because a reviewer cannot tell at a glance which spans fire when, and (c) duplicates the `:duration` measurement logic that `:telemetry.span/3` already handles. Single wrap site per public function = single source of truth for that span's contract. `Docs target: @doc ALLM.Telemetry.span/3`.

3. **`ALLM.Telemetry.span/3` injects common metadata once at the call site, not in each handler.** The spec §29 "common to every span" set is `:engine`, `:request_id`, `:model`. Phase 9.1's `ALLM.Telemetry.span/3` accepts a `(engine, request | nil, opts)` triple and computes the common metadata from them, merging with span-specific keys before calling `:telemetry.span/3`. The alternative — leaving metadata construction to each callsite — diverges (one site forgets `:model`, another puts it under `:opts`); a single helper enforces the §29 contract. `Docs target: @doc ALLM.Telemetry.span/3`.

4. **`ALLM.Retry.run/3`'s closure returns one of three shapes: `{:ok, term}`, `{:retry, delay_ms, error}`, or `{:error, term}`.** Spec §6.1 doesn't specify a closure protocol. Three-shape return is necessary because (a) `{:ok, _}` is the obvious success path, (b) `{:error, _}` is non-retryable failure (e.g., `4xx` other than `429` — a `400` is the caller's mistake, not a transient error), and (c) `{:retry, delay_ms, error}` is the retryable failure path where the closure has already extracted `Retry-After` from response headers and computed the next delay (or `0` to use the default backoff). The closure owns provider-specific error parsing because adapter error shapes differ; `ALLM.Retry` owns the loop and the jitter math. The third shape lets the closure pass the `Retry-After` header value back without `ALLM.Retry` having to know how to parse it. `Docs target: @doc ALLM.Retry.run/3`.

5. **The dep-absent path is simulated via an `Application.put_env(:allm, :force_capability_absent, true)` override consulted inside `ALLM.Capability.catalog_loaded?/0`, NOT via `:code.delete/1` + `:code.purge/1`.** `:code.delete/1` removes the *current* version of a module; `Code.ensure_loaded?/1` then re-loads from the BEAM file path, and because `test/support/llm_db.ex` compiles into `_build/test/lib/allm/ebin/`, the .beam stays on the load path and gets re-loaded on the next `Code.ensure_loaded?/1` call — defeating the purge. The `Application.put_env/3` override is the reliable simulator: `catalog_loaded?/0`'s implementation is `Application.get_env(:allm, :force_capability_absent, false) == false and Code.ensure_loaded?(Module.concat(["LLMDB"]))`. Tests that need the absent path do:
   ```elixir
   setup do
     Application.put_env(:allm, :force_capability_absent, true)
     on_exit(fn -> Application.delete_env(:allm, :force_capability_absent) end)
     :ok
   end
   ```
   This is async-safe at the *test* level only when no other test mutates the same key in parallel — the Phase 9.4 dep-free suite runs `async: false` for the same reason (`Application.get_env/3` reads the global env). The override is a Layer-B test seam, not a public API; documented internally only. `Docs target: internal — no user-facing docs`.

6. **No `{:llm_db, ...}` dep is added to `mix.exs`.** The mix.exs comment at line 39 (`# :llm_db re-added in Phase 9 (capability pre-flight / cost population, spec §6.3)`) is preserved as the deferral marker. Per `CLAUDE.md` § "Working on this codebase": "`optional: true` in `mix.exs` does NOT skip Hex version resolution — it only governs whether downstream apps need the dep. A placeholder constraint against a dep with mismatched published versions still breaks `mix deps.get`. Defer future deps as a code comment." Phase 9.4 integrates with `LLMDB` purely via `Code.ensure_loaded?/1` runtime detection. The `test/support/llm_db.ex` fake provides the published-package surface for tests; an application user who depends on the real `:llm_db` Hex package adds it to their own `mix.exs` and ALLM picks it up automatically. This matches the `engine.ex:301-304` precedent for `resolve_model/2`. `Docs target: @moduledoc ALLM.Capability` ("Why this is integration-by-detection, not a Hex dep" paragraph).

7. **`request_id` is generated at the **outermost** Layer-C entry point and threaded down into adapter opts; nested calls do not regenerate.** `ALLM.chat/3` calls `ALLM.step/3` calls `ALLM.Runner.run/3` calls the adapter's `generate/2`. If each layer generated its own `request_id`, the per-step span and the per-tool span and the adapter span would each carry a different id — making correlation impossible. Phase 9.1 generates `request_id` once at the topmost public function (the one the user called) and passes it down via `opts[:request_id]` to inner functions, which pull it via `Keyword.fetch/2`. The wrapper logic: `request_id = Keyword.get(opts, :request_id) || ALLM.Telemetry.request_id()`. Inner functions inherit; outer functions generate. `Docs target: @doc ALLM.Telemetry.request_id/0`.

8. **`ALLM.Retry`'s default jitter is bounded `[0, jitter_ms]`, not `[-jitter_ms, +jitter_ms]`.** Spec §6.1 says "`+ jitter(0..250ms)`" and "`:jitter_ms` (default `250`)" — the leading `+` and the `0..` start are jointly load-bearing: the default is **additive** jitter, never subtractive. A `[-jitter_ms, +jitter_ms]` interval would risk negative delays on small `base_delay_ms` values. Phase 9.3 implements `:rand.uniform(jitter_ms + 1) - 1` to get `[0, jitter_ms]` inclusive (verified on OTP 27: `:rand.uniform/1` returns `1..N` inclusive, the `- 1` shifts to `0..N-1`; passing `jitter_ms + 1` shifts the upper bound to `jitter_ms`). When `jitter_ms == 0`, `:rand.uniform(1) - 1 == 0` — no jitter, deterministic delay. `Docs target: @doc ALLM.Retry.run/3` ("Jitter bounds" paragraph).

9. **Tool spans run inside the per-tool task (`Task.async_stream/5`'s inner closure), not at the `run_tool_calls/3` boundary.** `ALLM.ToolRunner` (Phase 6) executes parallel tool calls via `Task.async_stream/5`. Per-tool telemetry must fire inside the task's closure so `:duration` reflects only that tool's execution and `:exception` traps the per-tool exception (not a sibling's). The `[:allm, :tool]` span is started inside the inner `fn` and concludes before the task returns to the parent stream. Metadata: `:tool` (Tool struct), `:tool_call` (ToolCall), `:engine`, `:request_id`. The parent `:step` span wraps all parallel tools at the outer boundary; the per-tool spans nest inside. `Docs target: @moduledoc ALLM.Telemetry` ("Span nesting" paragraph).

10. **`:exception` events use `:telemetry.span/3`'s automatic exception-trap behaviour.** Spec §29's `:exception` measurement is `%{duration: integer()}`; metadata includes `:kind`, `:reason`, `:stacktrace`. `:telemetry.span/3` (telemetry 1.2+) automatically catches exceptions in the closure and emits `[event_prefix, :exception]` with the right shape. Phase 9 does NOT manually `try/catch + :telemetry.execute/3` — it delegates the exception-trap to the library. The exception is re-raised after emission (verified per the telemetry 1.2 docs: "If the function raises, telemetry will execute the exception event and re-raise the exception"). This preserves the existing semantics of `ALLM.Runner.run/3` etc. — exceptions still bubble to the caller. `Docs target: @doc ALLM.Telemetry.span/3` ("Exception handling" paragraph).

11. **Pre-flight rejection from `ALLM.Capability.preflight/2` is folded into the existing `ALLM.Validate.request/1` call site, not added as a new wrap layer.** `lib/allm/stream_runner.ex:79` calls `Validate.request(request)` after `check_stream_adapter/1`; pre-flight is the next logical step *if* the catalog is loaded. Phase 9.4 adds a fourth chain link: `with :ok <- check_adapter(engine), :ok <- check_stream_adapter(engine.adapter), :ok <- Validate.request(request), :ok <- Capability.preflight(resolved_model, request) do dispatch(...)`. The `Capability.preflight/2` call is a no-op when `LLMDB` is absent (returns `:ok`); when present, it returns `{:error, %ValidationError{reason: :unsupported_capability}}` on a capability mismatch. The same chain link is added to `ALLM.Runner.run/3`'s pre-flight path (which currently delegates to `StreamRunner.run/3` so the link only appears once — verified by reading `lib/allm/runner.ex:69-80`). For `Chat.step/3` and `Chat.run/3`, pre-flight runs once at the first adapter call (multi-turn iterations don't re-pre-flight — the model doesn't change mid-conversation). `Docs target: @moduledoc ALLM.Capability` ("Where pre-flight runs" paragraph).

12. **`Usage.{input_cost, output_cost, total_cost}` are populated post-response, never pre-emptively.** `populate_costs/2` runs after `StreamCollector.to_response/1` produces a `%Response{}` with token counts. The cost fields are populated on the response's `usage`. When `Response.usage` has missing token counts (`nil`), the corresponding cost stays `nil` — partial population is allowed. `total_cost` is computed only when both `input_cost` and `output_cost` are populated; otherwise `nil`. Math: `input_cost = pricing.input * input_tokens / 1_000_000` (pricing is per-million-tokens, an `llm_db` convention; verified against the spec §6.3 `pricing: %{input: number(), output: number()} | nil` shape — units are not specified by the spec; the `/ 1_000_000` divisor is the de-facto standard documented inside `ALLM.Capability`'s `@moduledoc`). `Docs target: @doc ALLM.Capability.populate_costs/2`.

13. **Telemetry-emission tests use `ALLM.Test.TelemetryCapture` (a per-test handler) rather than `:telemetry_test.attach_event_handlers/2`.** `:telemetry_test` exists but only handles single-handler attachment with a list of events; a multi-event capture with ordering preservation is one helper module away. `ALLM.Test.TelemetryCapture` ships under `test/support/` (the standard `elixirc_paths(:test)` location), uses `Process.put/2` for capture state (per-PID, no global pollution), attaches a single handler per test that pattern-matches on the prefix list, and exposes `events/0` returning the captured event list in order. Per-test detach is automatic via `on_exit/1`. The alternative — `:telemetry.attach_many/4` directly in each test — duplicates 8 lines of setup per row. `Docs target: @moduledoc ALLM.Test.TelemetryCapture`.

14. **Sub-phase 9.3 ships `ALLM.Retry` AND a Fake-adapter integration in the same sub-phase.** Splitting `ALLM.Retry` (alone) from "first consumer of `ALLM.Retry`" creates an orphaned module that can't be tested end-to-end. The Fake adapter is the smallest integration that exercises the `[:allm, :adapter, :retry]` telemetry round-trip. Both ship together so the sub-phase has a green CI bar; real-provider integrations (Phase 10/11) reuse the same helper. `Docs target: @moduledoc ALLM.Retry` ("Tested via Fake; consumed by real providers in Phase 10/11" paragraph).

15. **The `[:allm, ...]` event prefix overrides spec §29's `[:llm, ...]` listing AND the `:exception` row is added to every span name (not just `:generate` / `:stream` / `:tool`).** Spec §29 lines 1500-1506 use `[:llm, :generate, :start | :stop | :exception]` for `:generate` / `:stream` / `:tool`, but lists only `:start | :stop` for `:step` and `:chat`. `:telemetry.span/3`'s exception-trap is unconditional — it always emits `[prefix, name, :exception]` when the closure raises — so a `:step` or `:chat` span that raises *will* emit `[:allm, :step | :chat, :exception]` whether the spec lists it or not. Phase 9 ships the full `:start | :stop | :exception` triad for every span name; the spec deviation is surfaced here. The package atom is `:allm` (verified `mix.exs:9`); `PROJECT_PHASING.md:152` already uses `[:allm, ...]`. Phase 9 ships `[:allm, ...]` for consistency. Both deviations (the prefix rename AND the `:exception` extension) are candidates for a single spec-amendment PR after Phase 9 lands. The amendment is non-blocking — Phase 9 ships against the corrected behaviour; the spec gets aligned post-hoc. All Phase 9 docs, code, CHANGELOG entries, and tests use `[:allm, ...]` with `:start | :stop | :exception` for every span name. `Docs target: CHANGELOG entry only` (the spec-deviation note).

16. **`ALLM.Telemetry.execute/3` is the emission path for non-span events; `ALLM.Retry` calls it for `[:allm, :adapter, :retry]`.** Spec §29 lists span-shaped events (`:start | :stop | :exception`); the retry event is single-emission per attempt (no enclosing duration to measure). `:telemetry.span/3` is therefore wrong for it; `:telemetry.execute/3` is the correct API. `ALLM.Telemetry.execute/3` wraps it consistently — same prefix-prepending, same metadata-merge as `span/4` — so the emission contract has one entry point per shape. `ALLM.Retry.run/3`'s implementation calls `ALLM.Telemetry.execute([:adapter, :retry], measurements, metadata)`. The `span_name` closed enum (`:generate | :stream | :step | :chat | :tool`) constrains `span/4`'s name argument; `execute/3` accepts any event-name list because the project may add other non-span events later (per spec §29 reservation). `Docs target: @doc ALLM.Telemetry.execute/3`.

17. **The `Capability.preflight/2` integration in `StreamRunner.run/3` requires hoisting `resolve_request_model/3` from `dispatch/3` into the top-level `with` chain.** The Decision #11 chain is `check_adapter → check_stream_adapter → Validate.request → Capability.preflight → dispatch`. `Capability.preflight/2` takes a `resolved_model :: Engine.resolved_model()` (which means `Engine.resolve_model/2`'s output, which is what currently happens inside `dispatch/3` via `resolve_request_model/3` at `lib/allm/stream_runner.ex:114-149`). The implementer must hoist `resolve_request_model/3` out of `dispatch/3` and into the `with` chain so both `preflight` and the dispatched stream see the same resolved value (no double-resolve). Implementation: extract the resolved model into a `with`-chain bound, pass it as a closure into `dispatch/3` instead of letting `dispatch/3` compute it. The hoist is a small refactor (≤ 20 lines) that PR-9.4 ships as part of the wire-up; called out here so the implementer doesn't choose double-resolve at impl time. The same hoist applies to `Runner.run/3` only via its delegation — `Runner.run/3` calls `StreamRunner.run/3`, so the hoist is single-site at the streaming runner. `Docs target: internal — no user-facing docs`.

## Behaviour & Type Contracts

### `ALLM.Telemetry` (Layer B — new module)

```elixir
defmodule ALLM.Telemetry do
  @event_prefix [:allm]

  @typedoc "Common metadata attached to every Layer-C span (spec §29)."
  @type common_metadata :: %{
          required(:request_id) => String.t(),
          required(:engine) => ALLM.Engine.t(),
          optional(:model) => String.t() | tuple() | struct() | nil
        }

  @typedoc "Span suffix per spec §29; the prefix [:allm] is fixed."
  @type span_name :: :generate | :stream | :step | :chat | :tool

  @spec event_prefix() :: [:allm]
  def event_prefix, do: @event_prefix

  @spec request_id() :: String.t()
  def request_id

  @spec span(span_name(), common_metadata(), (-> {result, map()})) :: result when result: var
  def span(name, start_metadata, fun)
      when is_atom(name) and is_map(start_metadata) and is_function(fun, 0)

  @spec execute([atom(), ...], map(), map()) :: :ok
  def execute(suffix_path, measurements, metadata)
      when is_list(suffix_path) and is_map(measurements) and is_map(metadata)
end
```

**Invariants:**

1. **`request_id/0` returns a 22-character URL-safe binary** (`:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)`). Verified on OTP 27: 16 bytes Base64-URL-encoded without padding is exactly 22 chars (verified in IEx 2026-04-25; `byte_size(Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)) == 22`).
2. **`span/4` injects `:request_id`, `:engine`, `:model` into both `:start` and `:stop` metadata.** The caller-supplied `start_metadata` is shallow-merged on top so callers can override (e.g., a `:tool` span overrides `:engine` with the engine *post-merge_opts*). Per-span `:stop`-only metadata (`:response`, `:step_result`, `:chat_result`, `:result`) flows from the closure's `{result, stop_metadata_extras}` return — the `stop_metadata_extras` map is shallow-merged on top of the start metadata at `:stop` emission time. This matches `:telemetry.span/3`'s closure contract (`(-> {result, stop_metadata})`) verbatim.
3. **`span/4` re-raises any exception thrown by `fun`.** `:telemetry.span/3` (telemetry 1.2+) auto-catches and emits `[prefix, name, :exception]` with `%{kind, reason, stacktrace}` metadata, then re-raises. Verified per the telemetry 1.2 docs (`:telemetry.span/3` second-arity contract).
4. **Event names follow `[:allm, span_name, :start | :stop | :exception]`.** Span name is one of `:generate | :stream | :step | :chat | :tool`. The closed `span_name()` enum prevents typos (`:chats` would fail dialyzer).
5. **`execute/3` emits a single non-span event with the prefix prepended.** Used by `ALLM.Retry` for `[:allm, :adapter, :retry]`. The full event name is `[:allm | suffix_path]`. No metadata merging (caller passes the complete metadata map); no measurements injected by this helper. Same prefix discipline as `span/4`. Decision #16.

### `ALLM.Retry` (Layer B — new module)

```elixir
defmodule ALLM.Retry do
  @typedoc "Closure return: success, retry-with-delay, or non-retryable error."
  @type closure_result(ok) :: {:ok, ok} | {:retry, non_neg_integer(), term()} | {:error, term()}

  @typedoc "Materialized retry policy after merging `:default | false | keyword()`."
  @type policy :: %{
          max_attempts: non_neg_integer(),
          base_delay_ms: pos_integer(),
          max_delay_ms: pos_integer(),
          retry_on: [pos_integer() | atom()],
          jitter_ms: non_neg_integer(),
          respect_retry_after: boolean()
        }

  @spec default_policy() :: policy()
  def default_policy

  @spec materialize(:default | false | keyword()) :: policy() | :no_retry
  def materialize(retry)

  @spec run(policy() | :no_retry | :default | false | keyword(), map(), (-> closure_result(ok))) ::
          {:ok, ok} | {:error, term()}
        when ok: var
  def run(policy_or_retry, telemetry_metadata, fun)
end
```

**Invariants:**

1. **`default_policy/0` returns the spec §6.1 closed map.** `%{max_attempts: 3, base_delay_ms: 500, max_delay_ms: 30_000, retry_on: [429, 500, 502, 503, 504, :timeout], jitter_ms: 250, respect_retry_after: true}`. Field-by-field cited against `steering/allm_engine_session_streaming_spec_v0_2.md:566-575`.
2. **`materialize/1` accepts `:default | false | keyword()` and returns either a `policy()` or `:no_retry`.** `false` → `:no_retry`; `:default` → `default_policy()`; keyword → `Map.merge(default_policy(), Map.new(kw))` — but the merge filters keyword keys against the closed `policy()` field set; unknown keys raise `ArgumentError` at `materialize/1` time so a typo (`max_atempts:`) fails loudly at engine-construction or first-call rather than silently no-opping. `materialize(max_attempts: 0)` → `:no_retry` (per spec §6.1's `non-neg int` shape; `0` collapses to the same path as `false` because zero attempts is indistinguishable from "no retry").
3. **`run/3` with `:no_retry` invokes `fun` once and returns its `{:ok, _}` or unwraps `{:error, _}` / `{:retry, _, error}` to `{:error, error}`.** The retry-shape is collapsed to error in no-retry mode — caller doesn't have to handle the third shape themselves.
4. **`run/3` with a `policy()` invokes `fun` up to `policy.max_attempts` times.** Each call gets the attempt number injected into `telemetry_metadata` as `:attempt` (1-indexed) before any retry-event emission.
5. **Retry decision matrix:** `{:ok, value}` returns `{:ok, value}` immediately. `{:retry, delay_ms, error}` AND attempt < max_attempts AND `error_matches?(error, policy.retry_on)`: emit `[:allm, :adapter, :retry]` with metadata `Map.merge(telemetry_metadata, %{attempt: attempt, delay_ms: actual_delay, reason: error})`, sleep `actual_delay`, then retry. `actual_delay = max(delay_ms, computed_backoff)` where `computed_backoff = min(policy.max_delay_ms, policy.base_delay_ms * (2 ** (attempt - 1))) + :rand.uniform(policy.jitter_ms + 1) - 1`. `{:retry, _, error}` AND attempt == max_attempts: return `{:error, error}` (final attempt, no further retry, no telemetry — the caller's `[:allm, :adapter, :stop]` will fire instead). `{:error, error}` returns `{:error, error}` immediately (non-retryable).
6. **`error_matches?(error, retry_on)` is total over the closed `retry_on` list shapes** — integers match HTTP status codes (provider-specific extraction logic is the closure's job; `error_matches?/2` checks for membership), atoms match error atoms (`:timeout`, `:closed`, etc.). Implementation: `error in retry_on` for the simple case; opaque error structs (`%AdapterError{reason: :timeout}`) match by extracting `:reason` then membership-checking. Documented in `@doc ALLM.Retry.run/3`.
7. **`:respect_retry_after: true` AND `delay_ms > 0` from the closure**: use `delay_ms` as the delay (ignoring the computed backoff), still adding jitter. Computed: `actual_delay = delay_ms + jitter`.
8. **Telemetry event:** `[:allm, :adapter, :retry]` with measurements `%{system_time: System.system_time()}` and metadata `%{attempt: 1..max_attempts-1, delay_ms: actual_delay, reason: error_term, ...telemetry_metadata}`. Emitted *before* sleeping so a caller measuring `:adapter, :stop, :duration - sum(retry, :delay_ms)` recovers the active-call time.
9. **`run/3` is total: returns `{:ok, _} | {:error, _}` for any closure return.** No raise from `run/3` itself (closure raises are propagated, unchanged from a normal function call).

### `ALLM.Capability` (Layer B — new module, gated on `Code.ensure_loaded?(LLMDB)`)

```elixir
defmodule ALLM.Capability do
  alias ALLM.{Engine, Request, Usage}
  alias ALLM.Error.ValidationError

  @typedoc "Result of a pre-flight capability check."
  @type preflight_result :: :ok | {:error, ValidationError.t()}

  @spec preflight(Engine.resolved_model() | nil, Request.t()) :: preflight_result()
  def preflight(model_ref_or_string, request)

  @spec populate_costs(Usage.t(), Engine.resolved_model() | nil) :: Usage.t()
  def populate_costs(usage, model_ref_or_string)

  @spec select(keyword()) ::
          {:ok, ALLM.ModelRef.t()} | {:error, :catalog_not_loaded | :no_match | term()}
  def select(criteria)

  @spec catalog_loaded?() :: boolean()
  def catalog_loaded?
end
```

`Engine.resolved_model/0` is a new exported `@type` on `ALLM.Engine`: `String.t() | tuple() | struct() | nil` — matches `resolve_model/2`'s declared return at `lib/allm/engine.ex:285`. Adding the type alias is the only Engine change in Phase 9.

**Invariants:**

1. **`catalog_loaded?/0` returns `Code.ensure_loaded?(Module.concat(["LLMDB"]))`.** Same idiom as `Engine.resolve_model/2` at `lib/allm/engine.ex:301-304`; the runtime atom is constructed via `Module.concat/1` to keep the dep optional. Verified at impl time via the existing engine.ex precedent.
2. **`preflight/2` returns `:ok` when `catalog_loaded?/0 == false`.** No-op pass-through when the dep is absent.
3. **`preflight/2` returns `:ok` when `model_ref_or_string` is a binary or `nil`.** A bare model string (no `LLMDB.model/1` resolution) carries no capability info; pre-flight is the catalog's job, not a string parser's.
4. **`preflight/2` returns `{:error, %ValidationError{reason: :unsupported_capability, errors: [{[:tools], :tools_disabled}]}}` when the request has tools and `model_ref.capabilities.tools.enabled == false`.** Error path matches the §6.3 wording verbatim.
5. **`preflight/2` returns `{:error, %ValidationError{reason: :unsupported_capability, errors: [{[:response_format], :json_native_disabled}]}}` when `request.response_format` matches `%{type: :json_schema, ...}` AND `model_ref.capabilities.json_native == false`.** The `:json_object` shape is a softer capability — it doesn't require a structured-output schema enforcer; pre-flight does NOT reject `:json_object` requests against a non-`json_native` model (an adapter that returns text-shaped JSON when asked for `:json_object` is a graceful degradation, not an error). `Docs target: @moduledoc ALLM.Capability` ("What pre-flight rejects" paragraph).
6. **`preflight/2` is exhaustive over the rejection set.** Two rules above are the only rejections in v0.2: tools-against-no-tools and json-schema-against-no-json-native. Future capabilities (vision, image gen, audio) extend this set; v0.2 keeps it tight.
7. **`populate_costs/2` returns the input usage unchanged when `catalog_loaded?/0 == false` OR `model_ref_or_string` is a string / `nil`.** No catalog → no pricing → no costs.
8. **`populate_costs/2` populates `:input_cost`, `:output_cost`, `:total_cost` from `model_ref.pricing` when both pricing and tokens are present.** Math: `input_cost = pricing.input * input_tokens / 1_000_000`, `output_cost = pricing.output * output_tokens / 1_000_000`, `total_cost = input_cost + output_cost`. When `model_ref.pricing == nil` OR token counts are `nil`, the corresponding cost field stays at its current value (never overwrites a non-nil cost; only fills `nil`).
9. **`select/1` returns `LLMDB.select(criteria)` when the catalog is loaded.** When absent, returns `{:error, :catalog_not_loaded}` — the only `:error` shape `ALLM.Capability` produces with an atom reason (rather than a struct), because there's no Layer-A error class for "this feature requires an optional dep." Single-arity matches `LLMDB.select/1`'s surface verbatim (no engine context is needed for selection — `:require` and `:prefer` carry the full criteria). `Docs target: @doc ALLM.Capability.select/1`.

### `ALLM.ModelRef` (Layer A — new struct, spec §6.3 lines 637-648)

```elixir
defmodule ALLM.ModelRef do
  @type t :: %__MODULE__{
          provider: atom(),
          id: String.t(),
          capabilities: map(),
          limits: %{context: pos_integer(), output: pos_integer()} | map(),
          pricing: %{input: number(), output: number()} | nil,
          metadata: map()
        }

  defstruct [:provider, :id, :capabilities, :limits, :pricing, metadata: %{}]

  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data)
end

defimpl Jason.Encoder, for: ALLM.ModelRef do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
```

**Invariants:**

1. **Layer A serializability.** ETF round-trip (`:erlang.term_to_binary/1`) is byte-identical for any `%ModelRef{}` value. Jason round-trip equality holds when `:capabilities`, `:limits`, `:pricing`, `:metadata` carry only JSON-native types (string/integer/float/bool/list/map of strings); custom struct values inside those maps follow the same Jason-asymmetry as Phase 1's `Engine.metadata` rule.
2. **Registered in `ALLM.Serializer.@known_modules`.** `from_json/1` hydrates `%{"__type__" => "ALLM.ModelRef", ...}` to `%ALLM.ModelRef{}` automatically. Verified pattern against the existing entries in `lib/allm/serializer.ex`.
3. **`new/1` raises `KeyError` (via `struct!/2`) on unknown opts.** Same shape as every other Layer A struct's `new/1` (Phase 1 convention).
4. **`__from_tagged__/1` hydrates from string-keyed map.** Atom-typed fields (`:provider`) restored via `String.to_existing_atom/1`; nested maps pass through verbatim.

### `ALLM.Error.ValidationError` (Layer A — vocabulary extension only)

```elixir
@type reason ::
        :invalid_request
        | :invalid_message
        | :invalid_tool
        | :invalid_thread
        | :invalid_session
        | :invalid_session_input
        | :unsupported_capability   # NEW — Phase 9.4
        | :vision_not_in_v0_2

@legal_reasons ~w(
  invalid_request
  invalid_message
  invalid_tool
  invalid_thread
  invalid_session
  invalid_session_input
  unsupported_capability             # NEW — Phase 9.4
  vision_not_in_v0_2
)a
```

**Invariants:**

1. The new atom is appended to both the `@type` union and the `@legal_reasons` word-list. Without both edits, `ValidationError.new(:unsupported_capability, [...])` raises `ArgumentError` from the `unless reason in @legal_reasons` check at `lib/allm/error/validation_error.ex:80`. Verified against the committed file on 2026-04-25.
2. **The atom has named use sites in this phase's code path.** Per `AGENT_DESIGN_SPEC.md` §3 rule 13 (no orphaned atoms): the use site is `ALLM.Capability.preflight/2` (two distinct error rows: `{[:tools], :tools_disabled}` and `{[:response_format], :json_native_disabled}` — both carry `reason: :unsupported_capability` on the wrapping struct).

### Atom vocabulary additions

This phase adds **one** new reason atom to the project's closed reason-atom set: `:unsupported_capability` on `ALLM.Error.ValidationError.@type reason`. Per `AGENT_DESIGN_SPEC.md` §3 rule 5, this is a scoped Phase 1 enum extension declared explicitly here with both edits (type union + word-list).

The two **field-error inner atoms** (`:tools_disabled`, `:json_native_disabled`) live inside the `field_error` tuples carried by the wrapping struct's `:errors` list. They are NOT additions to a closed enum — `ALLM.Error.ValidationError.@type field_error` declares the second tuple element as `reason :: atom()` (open atom; `lib/allm/error/validation_error.ex:21`). This matches Phase 1's pattern: the *outer* `reason` is closed; the *inner* per-field reasons are open atoms documented per validator.

The retry-event metadata `:reason` key carries opaque error terms from the closure (e.g., `429`, `:timeout`, an `%AdapterError{}` struct) — it is NOT a closed atom set; documented as `term()` in the `[:allm, :adapter, :retry]` event contract.

### Idiomatic Elixir requirements

- **`:telemetry.span/3` for all spans** — exception trapping is automatic; do NOT wrap with `try/catch + :telemetry.execute/3`.
- **`Module.concat(["LLMDB"])`** for the optional-dep atom in `ALLM.Capability.catalog_loaded?/0` — same idiom as `Engine.resolve_model/2` at `lib/allm/engine.ex:301-304`. The `Module.concat/1` ban from the Phase 2 design (`lib/allm/engine.ex` comment block at lines 295-300) applies to **caller-supplied JSON input** only; here the argument is a compile-time-literal string list, producing a single atom that's safe.
- **`Code.ensure_loaded?/1`** for the runtime guard — never `function_exported?/3` against the optional module without `ensure_loaded?` first (the latter returns `false` for unloaded modules whose `.beam` files are present but not loaded; the former forces the load).
- **`:rand.uniform/1`** for jitter — `:crypto.rand_uniform/2` is Erlang/OTP-deprecated since OTP 24; `:rand.uniform/1` is the canonical replacement (verified per OTP 27 docs).
- **`Keyword.fetch!/2`** for the `:request_id` extraction inside wrapped functions — fail loudly if a callsite omits the inheritance.
- **`Process.put/2` + `Process.get/2`** for `ALLM.Test.TelemetryCapture`'s storage — per-PID, no global pollution; `on_exit/1` cleans up automatically.

## Module Tree

```
lib/allm/
├── telemetry.ex                          (NEW — ALLM.Telemetry; span/4, execute/3, request_id/0, event_prefix/0)
├── retry.ex                              (NEW — ALLM.Retry; default_policy/0, materialize/1, run/3)
├── capability.ex                         (NEW — ALLM.Capability; preflight/2, populate_costs/2, select/1, catalog_loaded?/0)
├── model_ref.ex                          (NEW — ALLM.ModelRef Layer A struct; spec §6.3)
├── runner.ex                             (MODIFY — wrap run/3 in Telemetry.span(:generate, ...); populate Response.request_id)
├── stream_runner.ex                      (MODIFY — wrap run/3 in Telemetry.span(:stream, ...); thread :request_id through dispatch_opts; hoist resolve_request_model/3 from dispatch/3 to the with chain; add Capability.preflight/2 chain link)
├── chat.ex                               (MODIFY — wrap run/3, step/3, stream/3, stream_step/3 with Telemetry.span; thread :request_id into Chat -> ToolRunner opts)
├── tool_runner.ex                        (MODIFY — wrap each task closure in Telemetry.span(:tool, ...); synthesize :exception in normalize_task_element/2 for timeout-killed tasks)
├── stream_collector.ex                   (MODIFY — call Capability.populate_costs/2 in the build-response site; thread resolved model via opts)
├── engine.ex                             (MODIFY — add @type resolved_model/0)
├── serializer.ex                         (MODIFY — register ALLM.ModelRef in @known_modules)
├── error/
│   └── validation_error.ex               (MODIFY — add :unsupported_capability to @type reason and @legal_reasons)
└── providers/
    └── fake.ex                           (MODIFY — accept retry_until_call: pos_integer() in adapter_opts; integrate ALLM.Retry.run/3 in generate/2; honor the same opt in stream/2 by emitting an {:error, _} event the first n-1 calls without invoking ALLM.Retry)

test/allm/
├── telemetry_test.exs                    (NEW — span emission for every wrapped function; request_id propagation; execute/3 round-trip)
├── retry_test.exs                        (NEW — default policy materialization, success / retry / exhaustion / Retry-After / jitter bounds / max_attempts: 0)
├── capability_test.exs                   (NEW — preflight (loaded + absent paths via Application override), populate_costs math, select/1, validation-error vocabulary)
├── model_ref_test.exs                    (NEW — ALLM.ModelRef construction + ETF + Jason round-trips)
├── dep_free_test.exs                     (NEW, async: false — full execution flow with Application.put_env(:allm, :force_capability_absent, true))
├── error/
│   └── validation_error_test.exs         (MODIFY — add :unsupported_capability legal-reason row)
├── providers/
│   └── fake_retry_test.exs               (NEW — Fake adapter end-to-end retry; [:allm, :adapter, :retry] telemetry round-trip; streaming-no-retry assertion)
├── allm_generate_test.exs                (MODIFY — add telemetry-emission row including :response on :stop)
├── allm_stream_generate_test.exs         (MODIFY — add telemetry-emission row including :response on :stop)
├── chat_run_test.exs                     (MODIFY — add telemetry-emission row including :chat_result on :stop)
├── chat_stream_test.exs                  (MODIFY — add telemetry-emission row including :chat_result on :stop)
├── chat_step_test.exs                    (MODIFY — add telemetry-emission row including :step_result on :stop)
├── chat_stream_step_test.exs             (MODIFY — add telemetry-emission row including :step_result on :stop)
└── tool_runner_test.exs                  (MODIFY — add per-tool telemetry-emission row + parallel-task attribution + timeout-→-:exception synthesis)

test/support/
├── llm_db.ex                             (NEW — LLMDB test fake; model/1, select/1)
└── telemetry_capture.ex                  (NEW — ALLM.Test.TelemetryCapture; per-test handler; events/0)
```

Test files mirror source 1:1 (existing flat layout under `test/allm/` — verified 2026-04-25 against the committed tree). The two `test/support/` additions register under `elixirc_paths(:test)` automatically.

## Phases

### Phase 9.1: Telemetry — generate / stream / step / chat spans + `request_id` propagation (Layer B)

**Goal:** Wire `:telemetry.span/3` around every public Layer-C entry point, generate `request_id` once at the outermost call, populate `Response.request_id` on collection, and verify with `ALLM.Test.TelemetryCapture` that every span fires with the spec §29 metadata shape.

**Spec sections:** §29 (event names, measurements, metadata).

**Layer:** B (cross-cutting; instrumentation wraps Layer C functions).

#### 9.1.1 Test Plan

`test/allm/telemetry_test.exs` (NEW):

- `[:allm, :generate, :start | :stop]` fires once per `ALLM.generate/3` call with `:request_id`, `:engine`, `:model` in metadata; `:duration` (native units) in `:stop` measurements; `:response` (the `%Response{}`) in `:stop` metadata per spec §29's `generate / stream — :response (on :stop)` row.
- `[:allm, :generate, :exception]` fires on a raise inside the runner (engineered by passing an adapter that raises `RuntimeError` mid-call); metadata has `:kind`, `:reason`, `:stacktrace`; the exception is re-raised to the caller.
- Same matrix repeated for `:stream` (via `ALLM.stream_generate/3` — `:response` on `:stop` after collection at the wrap site; the wrapped enumerable is consumed by the harness inside the closure to materialize the response for the `:stop` event), `:step` (via `ALLM.step/3` — `:step_result` on `:stop`), `:stream_step` (via `ALLM.stream_step/3` — span name is `:step`, per spec §29's closed list at `steering/allm_engine_session_streaming_spec_v0_2.md:1503`; `:step_result` on `:stop`), `:chat` (via `ALLM.chat/3` — `:chat_result` on `:stop`), `:stream` chat (via `ALLM.stream/3` — span name is `:chat`; `:chat_result` on `:stop`).
- All five span names emit `:exception` when their wrapped closure raises; this includes `:step` and `:chat` even though spec §29 lists only `:start | :stop` for those — per Decision #15's spec-amendment note, `:telemetry.span/3`'s exception trap is unconditional and Phase 9 ships the full `:start | :stop | :exception` triad uniformly.
- `:request_id` is identical across `[:allm, :chat, :start]` and `[:allm, :chat, :stop]` (single id per call).
- `:request_id` is identical across `[:allm, :chat, :start]` and the inner `[:allm, :step, :start]` (inheritance — outer generates, inner inherits via opts).
- `:request_id` is a 22-character URL-safe binary (regex match on `~r/^[A-Za-z0-9_-]{22}$/`).
- After `{:ok, response} = ALLM.generate(engine, request)`, `response.request_id` equals the value emitted in `[:allm, :generate, :start]` metadata.
- Caller-supplied `opts[:request_id]` is honored (caller-wins) — span metadata uses the supplied id, no fresh one is generated.
- Span name closed-enum: passing `:not_a_span` to `Telemetry.span/4` raises `ArgumentError` (dialyzer would catch it but a runtime guard is the test).

`test/support/telemetry_capture.ex` (NEW):

- `attach/1` returns `:ok` and starts capturing into the test's process dictionary.
- `events/0` returns the list of `{event_name, measurements, metadata}` tuples in arrival order.
- `detach/0` removes the handler and clears the dict.
- Multiple `attach/1` calls in one test are idempotent (single handler per PID).

#### 9.1.2 Implementation Checklist

- [ ] Create `lib/allm/telemetry.ex` with `request_id/0` (`:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)`), `event_prefix/0` (`[:allm]`), `span/4` (delegates to `:telemetry.span/3` with the prefix prepended, common metadata merged at `:start`, and the closure's `{result, stop_extras}` tuple shallow-merged at `:stop`), and `execute/3` (delegates to `:telemetry.execute/3` with the prefix prepended).
- [ ] Modify `lib/allm/runner.ex`: extract body to `do_run/3`; wrap `run/3` with `ALLM.Telemetry.span(:generate, common_metadata(engine, request, opts), fn -> response = do_run(engine, request, opts); {response, %{response: response}} end)`; populate `response.request_id` from opts in the `to_response/1` post-fold.
- [ ] Modify `lib/allm/stream_runner.ex`: same wrap pattern (`:stream` span name; closure consumes the wrapped enumerable internally to materialize a `%Response{}` for the `:stop` extras — verify that this does NOT break consumer-driven laziness; if it does, the `:stop` event's `:response` key carries `nil` and the stream is yielded back to the caller); thread `:request_id` from `opts` into the dispatch chain (`build_dispatch_opts/2` adds `:request_id` to the kwlist passed to `engine.adapter.stream/2`).
- [ ] Modify `lib/allm/chat.ex`: wrap `run/3` (`:chat`; `:stop` extras `%{chat_result: result}`), `step/3` (`:step`; `%{step_result: result}`), `stream/3` (`:chat`), `stream_step/3` (`:step`).
- [ ] Verify `request_id` inheritance: when `Chat.run/3` calls into `Chat.step/3` which calls into `Runner.run/3`, the same `request_id` is read from opts at each level (no regeneration). Cite the test rows in 9.1.1 that exercise this.
- [ ] Create `test/support/telemetry_capture.ex` per the helper contract above.
- [ ] Write `test/allm/telemetry_test.exs` per the test plan.
- [ ] Add one telemetry-emission row to each of `test/allm/allm_generate_test.exs`, `test/allm/allm_stream_generate_test.exs`, `test/allm/chat/run_test.exs`, `test/allm/chat/step_test.exs`, `test/allm/chat/stream_test.exs`, `test/allm/chat/stream_step_test.exs`. Each row attaches the capture handler, runs the function, asserts the `:start` and `:stop` events fired with the documented metadata.

#### 9.1.3 Verification

```bash
mix test test/allm/telemetry_test.exs
mix test test/allm/allm_generate_test.exs test/allm/allm_stream_generate_test.exs
mix test test/allm/chat/
mix test                        # full suite still green; no existing test regresses
mix credo --strict lib/allm/telemetry.ex lib/allm/runner.ex lib/allm/stream_runner.ex lib/allm/chat.ex
mix dialyzer
```

### Phase 9.2: Tool telemetry — per-tool spans inside ToolRunner + parallel-task attribution (Layer B)

**Goal:** Emit `[:allm, :tool, :start | :stop | :exception]` per tool execution (one span per tool call, including parallel ones). Metadata: `:tool`, `:tool_call`, `:engine`, `:request_id`. The `:request_id` is inherited from the calling `:step` / `:chat` span.

**Spec sections:** §29 (`[:llm, :tool, :start | :stop | :exception]` row).

**Layer:** B.

#### 9.2.1 Test Plan

`test/allm/tool_runner_test.exs` (MODIFY — add):

- A single tool execution emits one `[:allm, :tool, :start]` and one `[:allm, :tool, :stop]` with `:tool`, `:tool_call`, `:request_id`, `:engine` in metadata; `:result` in `:stop` metadata.
- Three parallel tool executions emit three `:start` events and three `:stop` events; the `:tool_call` ids in metadata are distinct (one per call); attribution is correct (each span's `:tool_call.id` matches a unique input ToolCall).
- A tool that raises emits `[:allm, :tool, :exception]` for that specific tool only — sibling tools' `:stop` events are unaffected.
- `:request_id` in tool spans equals the `:request_id` in the parent `:step` span (inheritance via opts).
- A tool that returns `{:ask_user, _}` emits `[:allm, :tool, :stop]` with `:result` set to the `{:ask_user, _}` tuple (the span sees the handler's raw return — encoding happens later).
- A tool that times out (`tool_timeout` exceeded) emits `[:allm, :tool, :exception]` with `:reason: :timeout`. Implementation note: `Task.async_stream/5`'s `:on_timeout: :kill_task` (`tool_runner.ex:367,439`) kills the worker process externally, so the `:telemetry.span/3` inside the closure cannot trap the timeout — the span never reaches its `:stop` arm. Phase 9.2 instead synthesizes the `:exception` event from `normalize_task_element/2`'s `{:exit, {{tc, idx}, :timeout}}` clause (`tool_runner.ex:384-388`): when the parent stream observes a timeout exit, it calls `ALLM.Telemetry.execute([:tool, :exception], measurements, metadata)` directly with `metadata.reason = :timeout` and the original `:tool` / `:tool_call` / `:request_id` / `:engine` keys threaded through from the task's input attribution. The timeout-→-`:exception` synthesis is therefore the parent's responsibility, not the closure's; the span/closure pair handles the synchronous-raise cases unchanged.

#### 9.2.2 Implementation Checklist

- [ ] Modify `lib/allm/tool_runner.ex`: locate the per-tool task closure in `Task.async_stream/5` (Phase 6 batch 1); wrap the inner work in `ALLM.Telemetry.span(:tool, %{tool: tool, tool_call: tc, engine: engine, request_id: request_id}, fn -> {result, %{result: result}} end)`.
- [ ] Thread `:request_id` from the calling `Chat.step/3` / `Chat.run/3` into `ToolRunner.run_tool_calls/3`'s opts; pull at the per-tool task site.
- [ ] In `normalize_task_element/2`'s `{:exit, {{tc, idx}, :timeout}}` clause (`tool_runner.ex:384-388`), call `ALLM.Telemetry.execute([:tool, :exception], %{duration: 0}, %{tool: tool, tool_call: tc, engine: engine, request_id: request_id, kind: :exit, reason: :timeout, stacktrace: []})` to synthesize the `:exception` event for timeout-killed tasks (per Decision #9). The `:duration` is set to `0` because the precise per-task duration is unrecoverable post-kill; reviewers may opt to thread the elapsed time from the parent's monotonic clock at impl time.
- [ ] Add the test rows above to `test/allm/tool_runner_test.exs`.

#### 9.2.3 Verification

```bash
mix test test/allm/tool_runner_test.exs
mix test                        # full suite still green
mix credo --strict lib/allm/tool_runner.ex
mix dialyzer
```

### Phase 9.3: `ALLM.Retry` + Fake-adapter integration + `[:allm, :adapter, :retry]` telemetry (Layer B)

**Goal:** Ship `ALLM.Retry` with the spec §6.1 default policy, wire it into the Fake adapter via a new `retry_until_call: n` opt, emit `[:allm, :adapter, :retry]` per attempt, and prove the round-trip with end-to-end tests against Fake.

**Spec sections:** §6.1 (retry policy), §29 (`[:allm, :adapter, :retry]` event).

**Layer:** B.

#### 9.3.1 Test Plan

`test/allm/retry_test.exs` (NEW):

- `default_policy/0` returns the exact spec §6.1 map (field-by-field assert).
- `materialize(:default)` returns `default_policy()`.
- `materialize(false)` returns `:no_retry`.
- `materialize([])` returns `default_policy()`.
- `materialize(max_attempts: 5)` returns `%{default_policy() | max_attempts: 5}`.
- `materialize(unknown_key: 1)` raises `ArgumentError`.
- `run(:no_retry, %{}, fn -> {:ok, 1} end)` returns `{:ok, 1}`.
- `run(:no_retry, %{}, fn -> {:retry, 0, :err} end)` returns `{:error, :err}` (retry collapsed to error).
- `run(:default, %{}, counter_fn(3))` retries 2× then succeeds — emits 2× `[:allm, :adapter, :retry]`.
- `run(:default, %{}, fn -> {:retry, 0, 429} end)` retries `max_attempts - 1` times then returns `{:error, 429}`; emits 2× `[:allm, :adapter, :retry]`.
- `run(:default, %{}, fn -> {:error, 400} end)` returns `{:error, 400}` immediately (non-retryable; not in `retry_on`).
- `run(:default, %{}, fn -> {:retry, 1500, 429} end)` (closure-supplied `Retry-After` of 1500ms) sleeps ~1500ms (asserted via `System.monotonic_time(:millisecond)` before/after — tolerance ±100ms); retry event metadata's `:delay_ms` is between 1500 and 1500 + jitter_ms (250).
- Jitter bounds: `run(:default, ...)` with `base_delay_ms: 100, jitter_ms: 50` and 100 iterations — every retry `:delay_ms` is in `[100, 100 + 50]`.
- `error_matches?/2` membership: 429 ∈ default `retry_on`; 400 ∉.
- A closure raise propagates to `run/3`'s caller (no telemetry, no retry).

`test/allm/providers/fake_retry_test.exs` (NEW):

- `Fake.generate/2` with `adapter_opts: [retry_until_call: 1, script: ...]` succeeds on first call (no retry).
- `Fake.generate/2` with `adapter_opts: [retry_until_call: 3, script: ...]` succeeds on third call; emits 2× `[:allm, :adapter, :retry]` with metadata `%{attempt: 1, ...}` and `%{attempt: 2, ...}`.
- `Fake.generate/2` with `retry_until_call: 99` AND default `retry: :default` (max 3 attempts) returns `{:error, _}` (exhaustion). `[:allm, :generate, :stop]` still fires (the call completed, just with an error).
- `engine` with `retry: false` and `retry_until_call: 2` returns `{:error, _}` immediately on first failure (no retry attempted).
- `engine` with `retry: [max_attempts: 5]` and `retry_until_call: 4` succeeds on attempt 4.
- Streaming path: `Fake.stream/2` with `retry_until_call: 3` honors the opt by emitting an `{:error, _}` event the first n-1 times the script is consumed (the per-process counter is shared with the non-streaming integration). `Fake.stream/2` does NOT call `ALLM.Retry.run/3` — verified by attaching the telemetry handler and asserting zero `[:allm, :adapter, :retry]` events fire across the full enumerable's consumption. The stream surfaces a terminal `{:error, _}` event from the adapter and the consumer reduces to a `%Response{finish_reason: :error}` (per CLAUDE.md's "mid-stream errors fold into the response, not the call-site tuple" invariant).

#### 9.3.2 Implementation Checklist

- [ ] Create `lib/allm/retry.ex`. Implement `default_policy/0`, `materialize/1` (with `ArgumentError` on unknown keys), `run/3` (the retry loop). Use `:rand.uniform/1` for jitter; verify `:rand.uniform(jitter_ms + 1) - 1` produces `[0, jitter_ms]` inclusive on OTP 27 (cite IEx-verified at impl time).
- [ ] Modify `lib/allm/providers/fake.ex`: accept `retry_until_call: pos_integer()` in `adapter_opts`; on each call, decrement an internal counter (process-local Agent or `Process.put/2`); when counter > 1, return `{:retry, 0, :fake_transient}`; when counter == 1, return `{:ok, response}`. Wrap the whole thing in `ALLM.Retry.run(retry_policy, telemetry_meta, closure)`.
- [ ] Modify `lib/allm/providers/fake.ex`'s `stream/2`: do NOT call `ALLM.Retry.run/3` (streaming is non-retryable per the spec §6.1 "Streaming calls are not retried" rule). Honor `retry_until_call: n` by emitting a terminal `{:error, :fake_transient}` event the first n-1 calls (so the streaming-no-retry assertion has a falsifiable observation — Decision #11).
- [ ] Update `mix.exs` if needed (no — telemetry is already a dep).
- [ ] Write `test/allm/retry_test.exs` and `test/allm/providers/fake_retry_test.exs` per the test plan.

#### 9.3.3 Verification

```bash
mix test test/allm/retry_test.exs test/allm/providers/fake_retry_test.exs
mix test                        # full suite still green
mix credo --strict lib/allm/retry.ex lib/allm/providers/fake.ex
mix dialyzer
```

### Phase 9.4: `ALLM.Capability` + `LLMDB` runtime gate + `:unsupported_capability` (Layer B)

**Goal:** Ship `ALLM.Capability` with `preflight/2`, `populate_costs/2`, `select/2`, all gated on `Code.ensure_loaded?(LLMDB)`. Add `test/support/llm_db.ex` as the test fake. Wire `Capability.preflight/2` into `StreamRunner.run/3`'s pre-flight chain (single site — `Runner.run/3` delegates to `StreamRunner` so the wire-up appears once). Wire `Capability.populate_costs/2` into the `Response` build path so usage costs are populated post-collection. Add `:unsupported_capability` to the `ValidationError` enum.

**Spec sections:** §6.3 (capability + cost + select), §20 (validation error reasons).

**Layer:** B.

#### 9.4.1 Test Plan

`test/allm/capability_test.exs` (NEW):

- `catalog_loaded?/0` returns `true` when `LLMDB` is loaded (default test setup) and `false` after `Application.put_env(:allm, :force_capability_absent, true)` (per Decision #5).
- `preflight/2` returns `:ok` when `catalog_loaded?/0 == false` regardless of request shape.
- `preflight/2` returns `:ok` when `model_ref_or_string` is a binary or `nil` regardless of request shape.
- `preflight/2` returns `{:error, %ValidationError{reason: :unsupported_capability, errors: [{[:tools], :tools_disabled}]}}` for a `%ModelRef{capabilities: %{tools: %{enabled: false}}}` and a `%Request{tools: [tool]}`.
- `preflight/2` returns `:ok` for a tools-disabled model and a `%Request{tools: []}`.
- `preflight/2` returns `{:error, %ValidationError{reason: :unsupported_capability, errors: [{[:response_format], :json_native_disabled}]}}` for a `%ModelRef{capabilities: %{json_native: false}}` and a `%Request{response_format: %{type: :json_schema, ...}}`.
- `preflight/2` returns `:ok` for a json_native-disabled model and a `%Request{response_format: %{type: :json_object}}` (the soft-capability carve-out per Invariant 5).
- `preflight/2` accumulates BOTH errors when both rejections fire (tools-disabled AND json-schema-rejected) — `:errors` carries two field-error tuples.
- `populate_costs/2` with `usage: %Usage{input_tokens: 1000, output_tokens: 500}` and `model_ref: %ModelRef{pricing: %{input: 0.15, output: 0.6}}` returns `usage` with `:input_cost == 1.5e-4`, `:output_cost == 3.0e-4`, `:total_cost == 4.5e-4`.
- `populate_costs/2` with `usage: %Usage{input_tokens: nil}` leaves `:input_cost` at `nil`; `:output_cost` populates if `output_tokens` is present.
- `populate_costs/2` with `model_ref: %ModelRef{pricing: nil}` returns the input usage unchanged.
- `populate_costs/2` with `catalog_loaded? == false` returns the input usage unchanged.
- `select/1` returns `{:ok, %ModelRef{...}}` from `LLMDB.select/1` when loaded.
- `select/1` returns `{:error, :catalog_not_loaded}` when `LLMDB` is absent (i.e., `catalog_loaded?/0 == false`).

`test/allm/error/validation_error_test.exs` (MODIFY):

- `ValidationError.new(:unsupported_capability, [{[:tools], :tools_disabled}])` constructs a valid struct; `err.reason == :unsupported_capability`.

`test/allm/dep_free_test.exs` (NEW — per Decision #5; `async: false`):

- With `Application.put_env(:allm, :force_capability_absent, true)` set in `setup`: a representative subset of the suite runs (`ALLM.generate/3` happy path, `ALLM.chat/3` happy path, `ALLM.Session.start/3` happy path, retry happy path) without raising and without invoking any `LLMDB` function. Asserted by attaching a `:telemetry` handler on `[:allm, :capability]` (a synthetic event the `ALLM.Capability` module emits *only when it would have called LLMDB but skipped due to the override*) — zero events expected. This makes "no-LLMDB-calls" empirically observable.
- `ALLM.Capability.preflight/2`, `populate_costs/2` return their no-op identity shapes; `select/1` returns `{:error, :catalog_not_loaded}`.
- After `Application.delete_env(:allm, :force_capability_absent)` (in `on_exit/1`), `catalog_loaded?/0` returns to `true` for subsequent suites — proves the override is reversible and CI-safe.

`test/support/llm_db.ex` (NEW):

- Module name is `LLMDB` (no `ALLM.` prefix — mimics published-package surface).
- `model/1` accepts a string / tuple / `%ModelRef{}` and returns a `%ALLM.ModelRef{}` from the test's in-memory map (default fixtures cover `"openai:gpt-4.1-mini"`, `"anthropic:claude-3-haiku"`, `"local:no-tools"` and `"local:no-json-native"` — all four capability shapes).
- `select/1` accepts a `[require: kw, prefer: list]` keyword and returns `{:ok, %ModelRef{}} | {:error, :no_match}`.

#### 9.4.2 Implementation Checklist

- [ ] Create `lib/allm/model_ref.ex` per the contract section. Implement `Jason.Encoder` via `ALLM.Serializer.encode_tagged/2` and the `__from_tagged__/1` hydrator.
- [ ] Modify `lib/allm/serializer.ex` — append `ALLM.ModelRef` to `@known_modules`. Verify ETF + JSON round-trips against `test/allm/model_ref_test.exs`.
- [ ] Create `lib/allm/capability.ex` per the contract section. `catalog_loaded?/0` reads `Application.get_env(:allm, :force_capability_absent, false)` first and short-circuits to `false` if true (per Decision #5).
- [ ] Modify `lib/allm/error/validation_error.ex` — add `:unsupported_capability` to `@type reason` (lines 23-31) and `@legal_reasons` (lines 41-49).
- [ ] Modify `lib/allm/engine.ex`: add `@type resolved_model :: String.t() | tuple() | struct() | nil` and reference it from `resolve_model/2`'s `@spec`.
- [ ] Modify `lib/allm/stream_runner.ex`: hoist `resolve_request_model/3` from `dispatch/3` into `run/3`'s `with` chain (per Decision #17), then add the `Capability.preflight/2` chain link. Order: `check_adapter → check_stream_adapter → Validate.request → resolve_request_model → Capability.preflight → dispatch (passes the already-resolved request)`. Verify no double-resolve regression.
- [ ] Modify `lib/allm/runner.ex`: confirm `run/3` delegates to `StreamRunner.run/3` (it does — line 70); pre-flight chain link inherits automatically.
- [ ] Modify `lib/allm/stream_collector.ex` (or the build-response site — verified at impl time): after `to_response/1` produces the `%Response{}`, call `Capability.populate_costs(response.usage, resolved_model)` to populate cost fields. Resolved model is threaded down via opts from the runner.
- [ ] Create `test/support/llm_db.ex` per the test plan. Module name: `LLMDB` (no namespace).
- [ ] Write `test/allm/capability_test.exs`, `test/allm/dep_free_test.exs` (`async: false`), `test/allm/model_ref_test.exs`, and the `validation_error_test.exs` row.
- [ ] Confirm `mix test` is green both with `LLMDB` loaded (default) and with `Application.put_env(:allm, :force_capability_absent, true)` set (the dep_free_test.exs row exercises this).

#### 9.4.3 Verification

```bash
mix test test/allm/capability_test.exs
mix test test/allm/dep_free_test.exs
mix test                        # full suite green with test/support/llm_db.ex compiled
mix credo --strict lib/allm/capability.ex
mix dialyzer
```

CI (post-phase): the dep-absent path is exercised by `test/allm/dep_free_test.exs` itself (`async: false`, sets the `Application.put_env(:allm, :force_capability_absent, true)` override in `setup`). No separate CI leg is required — the override-based simulation is reliable and runs as part of the standard `mix test` invocation. The `Application.put_env` flag is unset on `on_exit/1` so subsequent suites see the loaded path.

## Test Plan (cross-phase)

### Unit tests

- **`ALLM.Telemetry`** — span emission per name (5 names × 3 events = 15 rows); `request_id/0` shape (regex match); `event_prefix/0` constant; common-metadata merge; `execute/3` round-trip; per-span `:stop`-extras shallow-merge from closure return.
- **`ALLM.Retry`** — `default_policy/0` field-by-field; `materialize/1` five cases (`:default`, `false`, `[]`, `[max_attempts: 5]`, `[max_attempts: 0]` → `:no_retry`) plus `ArgumentError`; `run/3` 13 rows per Phase 9.3.1.
- **`ALLM.Capability`** — `catalog_loaded?/0` two paths (loaded + override-absent); `preflight/2` 8 rows per Phase 9.4.1; `populate_costs/2` 4 rows; `select/1` 2 rows.
- **`ALLM.ModelRef`** — `new/1` happy path + `KeyError` row; ETF round-trip; Jason round-trip; `__from_tagged__/1` field-by-field.
- **`ValidationError`** — one new legal-reason row.

### Integration tests

- Each Phase-9.1 wrapped function (`ALLM.generate/3`, `stream_generate/3`, `step/3`, `stream_step/3`, `chat/3`, `stream/3`) gets one telemetry-emission row asserting both `:start` and `:stop` fire with the documented metadata.
- `ALLM.ToolRunner` parallel-task per-tool span attribution row.
- `Fake.generate/2` retry round-trip — attempts × N + retry telemetry × N-1.
- Dep-free `ALLM.generate/3` / `ALLM.chat/3` / `ALLM.Session.start/3` paths.

### Property tests

- `ALLM.Retry.run/3` jitter bounds: 100 iterations with `base_delay_ms: 100, jitter_ms: 50` — every retry `:delay_ms` ∈ `[100, 150]`. (`StreamData.integer/1` pinned to the policy bounds.)
- `ALLM.Telemetry.request_id/0` 1000 invocations: every output is a 22-char URL-safe binary, every output is unique (`:crypto.strong_rand_bytes/1`'s collision probability over 1000 16-byte values is negligible — verified per OTP 27 docs).

### Doctests

- `ALLM.Telemetry.request_id/0`, `Telemetry.event_prefix/0`, `Telemetry.span/4` (the doctest uses a `:telemetry.attach/4` self-handler and asserts the emitted event arrives), `Telemetry.execute/3`.
- `ALLM.Retry.default_policy/0`, `Retry.materialize/1`, `Retry.run/3` (doctest with a counter closure).
- `ALLM.Capability.catalog_loaded?/0`, `Capability.preflight/2`, `Capability.populate_costs/2` (doctests use the `LLMDB` test fake — runnable under `mix test`).

### Stream-equivalence

This phase introduces no new stream-vs-collected-form variants. `ALLM.generate/3 ≡ ALLM.stream_generate/3 |> StreamCollector.to_response/1` continues to hold; the telemetry wrapping does not affect the equivalence relation because both paths emit the same span set in the same order (single span per public function, regardless of stream/non-stream form). No relaxation table needed.

### Coverage threshold

`mix test --cover` — ≥ 80 % global, ≥ 90 % on every new file (`telemetry.ex`, `retry.ex`, `capability.ex`).

## Error Contract

| Function | Error reason | Recovery guidance |
|----------|--------------|-------------------|
| `ALLM.Capability.preflight/2` | `:unsupported_capability` (with `:tools_disabled` field-error) | Caller passed tools to a model whose catalog declares `tools.enabled = false`; surface to caller, no retry. Recoverable by switching models or removing tools. |
| `ALLM.Capability.preflight/2` | `:unsupported_capability` (with `:json_native_disabled` field-error) | Caller passed `response_format: :json_schema` to a non-`json_native` model; surface to caller. Recoverable by switching models or relaxing to `:json_object`. |
| `ALLM.Capability.select/2` | `:catalog_not_loaded` (atom shape, not a struct) | `LLMDB` is not loaded; recoverable by adding the dep to the application's `mix.exs` or by passing a literal model string. |
| `ALLM.Retry.run/3` | propagates closure's `{:error, _}` | Per-closure non-retryable error. Recovery is closure-specific. |
| `ALLM.Retry.run/3` | propagates closure's `{:retry, _, error}` after exhaustion | Caller may inspect the error term to decide whether to manually retry; default policy already exhausted the budget. |
| `ALLM.Retry.materialize/1` | raises `ArgumentError` on unknown key | Caller passed `retry: [unknown_key: 1]`; programmer error — fix at engine-construction. |

The `:request_id` field on telemetry events is **always present** in span metadata; consumers that rely on it should pattern-match `%{request_id: id}` and not the empty-shape `%{}`. No error rows for missing `:request_id` — Phase 9.1's invariant is "request_id is always present in span metadata" (set at the wrap layer; impossible to omit).

### Field-error atom vocabulary additions

Inside `%ValidationError{reason: :unsupported_capability, errors: [...]}`:

| Field path | Reason atom | Hard-reject? | Fires when |
|------------|-------------|--------------|------------|
| `[:tools]` | `:tools_disabled` | no (accumulating) | request has tools and `model_ref.capabilities.tools.enabled == false` |
| `[:response_format]` | `:json_native_disabled` | no (accumulating) | request has `:json_schema` response_format and `model_ref.capabilities.json_native == false` |

Both are accumulating: `Capability.preflight/2` walks both checks and surfaces both rows in `:errors` when both fire. No hard-reject — the validation is meaningful even when both rules trigger; the caller wants to see all violations. (Contrast with the `:vision_not_in_v0_2` hard-reject from Phase 1's table.)

## Definition of Done

- [ ] All four sub-phases marked `Completed` in the Status table.
- [ ] `mix test` zero failures, zero `unused_var` warnings.
- [ ] Coverage ≥ 80 % globally; ≥ 90 % on every NEW file (`telemetry.ex`, `retry.ex`, `capability.ex`, `model_ref.ex`) AND on the lines of telemetry / preflight / cost-population instrumentation added to MODIFIED files (`runner.ex`, `stream_runner.ex`, `chat.ex`, `tool_runner.ex`, `stream_collector.ex`, `serializer.ex`, `providers/fake.ex`). Verified via per-file coverage report; Phase 9 does not lower the existing 80 % global floor.
- [ ] `mix credo --strict` zero issues on changed files.
- [ ] `mix dialyzer` zero new warnings (vs. pre-Phase-9 PLT).
- [ ] `mix format --check-formatted` passes.
- [ ] Every new public function in `ALLM.Telemetry`, `ALLM.Retry`, `ALLM.Capability` has `@spec` and `@doc` with at least one runnable doctest.
- [ ] `:unsupported_capability` appears in `ValidationError.@type reason` AND `@legal_reasons` (both edits verified at `lib/allm/error/validation_error.ex:23-31` and `:41-49`).
- [ ] `ALLM.ModelRef` ships in `lib/allm/model_ref.ex` with ETF + Jason round-trip tests green; registered in `ALLM.Serializer.@known_modules`.
- [ ] `[:allm, :generate | :stream | :step | :chat | :tool, :start | :stop | :exception]` events fire with the documented common metadata (`:request_id`, `:engine`, `:model`) AND the per-span `:stop`-only metadata (`:response` for `:generate` / `:stream`; `:step_result` for `:step`; `:chat_result` for `:chat`; `:result` for `:tool`) for every public Layer-C entry point — unit-tested via `ALLM.Test.TelemetryCapture` per Phase 9.1.1 and 9.2.1.
- [ ] `[:allm, :adapter, :retry]` events fire per attempt — unit-tested via the Fake-adapter retry round-trip per Phase 9.3.1.
- [ ] Dep-free smoke test: full `mix test` flow passes with `Application.put_env(:allm, :force_capability_absent, true)` set in `setup` of `test/allm/dep_free_test.exs` (`async: false`).
- [ ] `LLMDB`-loaded path: full `mix test` flow passes with `test/support/llm_db.ex` compiled.
- [ ] `Response.request_id` populated post-collection in every Phase-5 / Phase-6 / Phase-7 path that builds a Response.
- [ ] `Usage.{input_cost, output_cost, total_cost}` populated post-response when `LLMDB` is loaded AND `model_ref.pricing` is non-nil AND token counts are present (Phase 9.4.1 row).
- [ ] CHANGELOG.md updated with one line per public sub-phase (4 lines total); each cites its spec §-number.
- [ ] Phase 9.1 doctest in `ALLM.Telemetry.span/4` uses `:telemetry.attach/4` + `Process.send/2` self-handler (no `mix test` flake) — runnable under `mix test test/allm/telemetry_test.exs` via `ExUnit.DocTest`'s `doctest ALLM.Telemetry` host directive (Elixir doctests run inline with the host module's tests; there is no built-in `:doctest` ExUnit tag).
- [ ] No `{:llm_db, ...}` line added to `mix.exs` deps. The deferral comment at line 39 stays as-is.
- [ ] Phase-9-introduced atoms each have at least one named use site in the same phase's pseudocode or contract (`AGENT_DESIGN_SPEC.md` §3 rule 13): `:unsupported_capability` → `Capability.preflight/2`; `:tools_disabled` → preflight tool-rejection branch; `:json_native_disabled` → preflight json-schema-rejection branch.
- [ ] Reviewed via `/review` (per `AGENT_REVIEW_SPEC.md`).

**Spec-amendment ticket (non-blocking).** Phase 9 ships `[:allm, ...]` for every telemetry event prefix. Spec §29 line 1496-1506 uses `[:llm, ...]`. The deviation is captured in this design's Non-obvious Decision #15. After Phase 9 lands, a follow-on PR updates `steering/allm_engine_session_streaming_spec_v0_2.md` §29 to use `[:allm, ...]` consistently — that PR is non-blocking on Phase 9.
