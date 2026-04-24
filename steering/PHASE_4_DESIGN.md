# Phase 4: `ALLM.Providers.Fake` — Scripted Adapter — Design Document

> **Goal:** Ship `ALLM.Providers.Fake` — a deterministic, scripted adapter that implements both `ALLM.Adapter` and `ALLM.StreamAdapter`, passes the Phase 3 `AdapterConformance` and `StreamAdapterConformance` harnesses unchanged, interprets the spec §31 script shape as its user-facing API, and publishes a fixture library of named scenarios so every Phase 5+ orchestration test has a one-line script to reach for.
> **Outcome:** `ALLM.Providers.Fake` is installed in the main `allm` package at `lib/allm/providers/fake.ex`. A pair of main-project test files (`test/allm/providers/fake_test.exs` and `test/allm/providers/fake_stream_test.exs`) exercise the §31 script surface directly and then `use ALLM.Test.AdapterConformance` / `ALLM.Test.StreamAdapterConformance` as their last line to certify Fake against the Phase 3 harness verbatim. `test/support/fake_fixtures.ex` ships eight named fixtures covering every §31 property-style scenario that Phase 4 is positioned to exercise (pure text, single tool call, parallel tool calls, mid-stream error, empty response, streaming tool-call arg deltas, `{:delay, _}` backpressure, multi-call manual-mode round-trip). A halt-safety test asserts that `Enum.take(stream, 2)` on a 10-event script fires the `Stream.resource/3` `after_fun` within 500 ms. `mix test`, `mix credo --strict`, `mix dialyzer`, `mix format --check-formatted` all green; coverage ≥90 % on `lib/allm/providers/fake.ex`.
> **Spec sections:** §7.1, §7.2 (Adapter / StreamAdapter behaviours — Phase 3 contract), §8 (event protocol), §20 (error reasons), §30 (cancellation), §31 (scripted fake contract — the user-facing API this phase implements)
> **Layers touched:** B (Runtime). Fake is a runtime Layer B implementation: it carries modules, atoms, and serializable plain data in `adapter_opts`, and it depends on the Phase 3 behaviours. No Layer A struct shapes change. No Layer C/D functions are introduced — Phase 5 is the first phase to consume Fake through `ALLM.stream_generate/3`.
> **Phasing doc:** [`PROJECT_PHASING.md`](PROJECT_PHASING.md) Phase 4.

## Status

| Sub-phase | Description | Layer | Status |
|-----------|-------------|-------|--------|
| 4.1 | `ALLM.Providers.Fake.Script` — script interpreter + shape detection (two-shape support, validation, cursor) | B | Completed |
| 4.2 | `ALLM.Providers.Fake` — `ALLM.Adapter` impl (fold scripted events into `%Response{}`) | B | Completed |
| 4.3 | `ALLM.Providers.Fake` — `ALLM.StreamAdapter` impl (`Stream.resource/3` + cleanup observer + `{:delay, _}`) | B | Completed |
| 4.4 | `ALLM.Test.FakeFixtures` — named fixture library under `test/support/` | B | Completed |
| 4.5 | Conformance plug-in + §31 scenario tests (halt-safety, multi-call, `:no_scripted_response`) | B | Completed |

**Overall Progress:** 5/5 sub-phases complete

## Overview

Phase 4 adds the **user-facing deterministic adapter** that every subsequent orchestration phase (5, 6, 7, 8) tests against. The Phase 3 `StubAdapter` that ships inside the `allm_conformance` package certifies the harness itself against a known-good implementation; it is **not** the adapter users reach for when they write `ALLM.chat/3` tests. `ALLM.Providers.Fake` is. Fake lives in the main `allm` package's `lib/allm/providers/fake.ex` so that users importing `{:allm, "~> 0.2"}` get it on the runtime load path (per `AGENT_DESIGN_SPEC.md` §Guidelines — "the Fake implementation is part of the library, not test-only — users need it for their own tests").

This phase implements the **spec §31 script shape** — the one the spec itself samples with `{:text, "Hello "}, {:finish, :stop}` — plus multi-call `scripts: [[...], [...]]` list-of-lists sequencing with an automatic per-process cursor (Non-obvious Decision #1). The same module ALSO passes the Phase 3 conformance harness, whose script shape is different (`{:ok, response_map}` / `{:error, reason, opts}` for `AdapterConformance`, passed on `adapter_opts[:script]`; `{:text_delta, str}` / `{:preflight_error, _, _}` / `{:error_event, _, _}` / `{:stream_error, _, _}` / `{:finish, _}` for `StreamAdapterConformance`, passed on `adapter_opts[:stream_script]`). Shape disambiguation is two-axis (Non-obvious Decision #2):

- **Non-streaming (`generate/2`):** both shapes share the `:script` / `:scripts` key; disambiguation is **by leading entry tag**. Harness adapter entries are always `{:ok, map}` or `{:error, reason_atom, keyword()}` (per `conformance/lib/allm/test/adapter_conformance.ex:66, 75`) — tags `:ok` and `:error`/3 never appear in §31's per-event vocabulary. §31 entries' leading tags (`:text`, `:tool_call`, `:tool_call_delta`, `:usage`, `:raw_chunk`, `:finish`, `:delay`, `:sleep`, `:error`/2) never include `:ok` and never produce a 3-tuple `:error`. The `:error` tag disambiguates by `tuple_size/1` (2 → §31, 3 → harness).
- **Streaming (`stream/2`):** the two shapes use **distinct opts keys** — harness uses `adapter_opts[:stream_script]` (verified against `conformance/lib/allm/test/stream_adapter_conformance.ex:90, 108, 120, 139, 164, 177`); §31 uses `adapter_opts[:script]` / `adapter_opts[:scripts]`. Key-based routing replaces any per-tag ambiguity. Fake's `stream/2` reads `:stream_script` first and falls through to `:script`/`:scripts` when absent.

Tags that appear in both vocabularies at face value (`:finish`, `:tool_call`) have **identical semantics** across shapes: `{:finish, reason}` emits `:message_completed`; `{:tool_call, kw}` emits `:tool_call_started` + `:tool_call_completed`. The interpretation is shape-independent, so the "disjoint" claim is about disambiguating tags — shared-semantics tags are interpreted the same way either way.

No spec amendment is required. Spec §31's 1:1 script-entry-to-event claim is honoured for every tag **except** `:finish` (which naturally produces a terminal `:message_completed` and, when Phase 5's stream runner is plugged in, a wrapping `:step_completed`) and `:usage` (which has no native `ALLM.Event` variant — emitted as `{:raw_chunk, {:usage, map}}` per Non-obvious Decision #6). Both relaxations are explicit.

### Deliverables

- **New modules (main package):** `ALLM.Providers.Fake` (`lib/allm/providers/fake.ex`); `ALLM.Providers.Fake.Script` (`lib/allm/providers/fake/script.ex` — script-shape interpreter, tag detection, cursor dispatch, validation).
- **New test-support module (main package):** `ALLM.Test.FakeFixtures` (`test/support/fake_fixtures.ex`) — named §31-shape fixtures reusable across Phase 4–8 orchestration tests.
- **New tests (main package):** `test/allm/providers/fake_test.exs` (happy path + `{:error, term()}` + `:no_scripted_response` + `script`/`scripts` mixing + conformance plug-in via `use ALLM.Test.AdapterConformance`); `test/allm/providers/fake_stream_test.exs` (event ordering + halt-safety + `{:delay, _}` + cancellation cleanup + conformance plug-in via `use ALLM.Test.StreamAdapterConformance`); `test/allm/providers/fake/script_test.exs` (shape detection + tag disambiguation + fold-to-Response correctness + cursor behaviour).
- **Changelog entry:** one line per new public module (`ALLM.Providers.Fake`, `ALLM.Providers.Fake.Script`, `ALLM.Test.FakeFixtures`).
- **No changes to `mix.exs`, `ALLM.Application`, or any Layer A struct.** The cursor is per-process (Non-obvious Decision #1) and needs no supervisor child.
- **No changes to the `conformance/` sub-project.** The Phase 3 harness is stable; Fake plugs into it through its published `using/1` macros. `StubAdapter` remains the harness's permanent self-test subject.

### Spec coverage

- **§7.1** — Fake implements `ALLM.Adapter.generate/2`. `prepare_request/2` and `translate_options/2` stay unimplemented (both `@optional_callbacks` — Fake is not HTTP-backed, so Req-level escape hatches don't apply). The Phase 5 stream-runner integration verifies that absent `translate_options/2` does not raise `UndefinedFunctionError` through Fake — that test already sits in the Phase 5 design per Phase 3 §Out-of-scope's handoff.
- **§7.2** — Fake implements `ALLM.StreamAdapter.stream/2`. Streams are lazy — no event fires until the consumer reduces — and halt-safe via `Stream.resource/3` with an `after_fun` that honours `adapter_opts[:cleanup_observer]` (the same `:counters`-ref mechanism Phase 3's `StreamAdapterConformance` halt-safety case asserts against).
- **§8** — Fake emits exactly the subset of the §8 event union that belongs to an adapter: `:message_started`, `:text_delta`, `:text_completed`, `:tool_call_started`, `:tool_call_delta`, `:tool_call_completed`, `:message_completed`, `:raw_chunk`, `:error`. Orchestrator-owned variants (`:tool_execution_started`, `:step_completed`, `:chat_completed`, `:ask_user_requested`, `:tool_halt`, `:tool_execution_completed`, `:tool_result_encoded`) are **not** emitted by Fake — they are Phase 6/7 concerns.
- **§20** — Error paths use `%ALLM.Error.AdapterError{}` (synchronous `{:error, _}` from `generate/2` and `stream/2`) and `%ALLM.Error.StreamError{}` (mid-stream transport-shaped errors via the harness-compat `{:stream_error, reason, opts}` entry). Script-shape `{:error, term()}` produces `{:error, %AdapterError{reason: :unknown, cause: term}}` for a synchronous `generate/2` error, or a terminating `{:error, %AdapterError{reason: term_atom_or_:unknown, cause: original_term}}` event for streaming — details in §Behaviour & Type Contracts.
- **§20 (Phase 1 amendment)** — `ALLM.Error.AdapterError`'s `@legal_reasons` enum is extended with a 12th atom, `:no_scripted_response`, scoped to testing adapters (Fake). Production adapters do not produce this reason. The amendment is a single-line addition to `lib/allm/error/adapter_error.ex:35-46` and its `t:reason/0` union; see Non-obvious Decision #3 for the rationale and Sub-phase 4.1 for the implementation checklist.
- **§30** — Cancellation: `Stream.resource/3`'s `after_fun` fires synchronously when the consumer halts (`Enum.take/2`, `Stream.run/1` abort, the consumer process exits). The conformance harness's halt-safety case (`counters.get(ref, 1) == 1` within 500 ms) is the load-bearing test.
- **§31** — Fake IS the scripted adapter this section describes. Every entry tag (`:text`, `:tool_call`, `:tool_call_delta`, `:usage`, `:raw_chunk`, `:finish`, `:error`, `:delay`) is supported. The deprecated `{:sleep, ms}` alias is accepted with a one-time `Logger.warning/1` (Non-obvious Decision #8). Calls beyond the last scripted turn return `{:error, %AdapterError{reason: :no_scripted_response, message: "no scripted response"}}` — the bare-atom `:no_scripted_response` from the spec survives as the struct's `:reason` field (Non-obvious Decision #3).

### Layer demonstration

Phase 4 is entirely Layer B. A user can construct an engine backed by Fake and exercise it through the Phase 3 behaviours directly — no Layer C (`stream_generate/3` arrives in Phase 5) needed:

```elixir
# Layer B: adapter-level usage — a user wants to verify their own tool handler
# without waiting for Phase 5.
engine =
  ALLM.Engine.new(
    adapter: ALLM.Providers.Fake,
    adapter_opts: [
      script: [
        {:tool_call, id: "call_1", name: "get_weather", arguments: %{city: "Boston"}},
        {:finish, :tool_calls}
      ]
    ]
  )

{:ok, response} = ALLM.Adapter.generate(fake_request(), engine.adapter_opts)
# response.tool_calls has one %ToolCall{id: "call_1", name: "get_weather", arguments: %{city: "Boston"}}
```

```elixir
# Layer B: streaming usage — same engine, streaming interface.
{:ok, stream} = ALLM.StreamAdapter.stream(fake_request(), engine.adapter_opts)

events = Enum.to_list(stream)
# [{:message_started, _}, {:tool_call_started, _}, {:tool_call_completed, _}, {:message_completed, _}]
```

No Layer C or D function is exercised in these snippets. Phase 5 ships `ALLM.stream_generate/3` and `ALLM.generate/3` that compose over these Layer B primitives.

### Prerequisites

- **Phase 1 complete.** `ALLM.Error.AdapterError`, `ALLM.Error.StreamError`, `ALLM.Event` (with `event?/1` guard), `ALLM.Response`, `ALLM.ToolCall`, `ALLM.Message`, `ALLM.Usage`.
- **Phase 2 complete.** `ALLM.Engine.new/1`, `adapter_opts` field, `resolve_params/2` / `resolve_tools/2`. Fake does not call these directly — the Phase 5 stream runner will — but the `adapter_opts` kwlist plumbing must be in place.
- **Phase 3 complete.** The `ALLM.Adapter` and `ALLM.StreamAdapter` behaviours are the narrowed `%AdapterError{}` contract; the `allm_conformance` sibling package publishes `ALLM.Test.AdapterConformance` and `ALLM.Test.StreamAdapterConformance`; the main `allm` project's `mix.exs` already carries `{:allm_conformance, path: "conformance", only: :test}`.
- **No dependency on Phase 5 or later.** Fake does not emit `:step_completed`, `:chat_completed`, `:tool_execution_*`, `:ask_user_requested`, or `:tool_halt`. Those events are synthesized by Phase 6–7 orchestration code that wraps Fake's output.

### Out of scope

- **`ALLM.stream_generate/3` / `ALLM.generate/3` / `ALLM.step/3` / `ALLM.chat/3`.** Phase 5–7. Phase 4 ships only the adapter; execution functions compose over it later.
- **`ALLM.StreamCollector`.** Phase 5. Phase 4 does not fold streaming events into a `%ChatResult{}` — the Fake adapter's `generate/2` reducer is a separate, narrower operation (see §Behaviour & Type Contracts → "Fold-to-Response semantics").
- **Record-and-replay (recording a real provider response for later replay).** The phasing doc flags this as a Phase 4 decision; deferred to Phase 10 (OpenAI) where recorded wire fixtures become valuable for regression tests. Adding it in Phase 4 would couple Fake to `ALLM.Providers.Support.SSE` which does not exist yet.
- **`ALLM.Providers.Fake.request_id/0` auto-generation.** Real provider adapters (Phase 9) introduce `request_id` propagation. Fake accepts a caller-supplied `adapter_opts[:request_id]` and surfaces it on the `%Response{}` verbatim, but does not auto-mint one.
- **`:ask_user_requested` scripted via Fake.** Ask-user is a tool-handler return value, not an adapter event (spec §12.3). Phase 7 exercises it through `ALLM.ToolExecutor.Default` and a handler that returns `{:ask_user, _}`; Fake is the adapter, not the tool executor.
- **`{:usage, _}` as a first-class `ALLM.Event` variant.** Spec §8's union does not include `:usage`; spec §31's script entry does. Phase 4 emits `{:raw_chunk, {:usage, map}}` for streaming and folds `map` into `%Response.usage` for non-streaming — a targeted gap-fill (Non-obvious Decision #6) rather than a spec amendment.
- **Concurrent multi-call scripting from a single process.** Phase 4 supports sequential multi-call (a chat loop calls Fake N times from the same process, the cursor advances on each call). Concurrent calls from the same process with the same scripts (e.g., a parallel `Task.async_stream/3` over the Fake adapter) would race the per-process cursor; documented as a limitation and the `adapter_opts[:script_cursor]` Agent override is the escape hatch.

### Non-obvious decisions

1. **Cursor is per-process, stored in `Process.put/2` keyed by `:erlang.phash2(scripts)`; `adapter_opts[:script_cursor]` (pid) is an explicit override.** A `Process.dict` cursor is isolated per process (standard ExUnit `async: true` gives each test its own pid), GC'd automatically on pid-down (no ETS cleanup, no supervisor child, no `ALLM.Application` change), and zero-setup for the common case.

   **Content-equal scripts collide — documented footgun.** The key is `{:allm_fake_cursor, :erlang.phash2(scripts)}`, which means two engines built in the **same process** with **content-equal `scripts:` values** share a cursor. A test that constructs two Fake engines simulating two distinct providers with the same fixture script will find the second engine's first call already at index 1 (or `:no_scripted_response` if the fixture was single-call). This is rare in practice (most tests use one engine per test process), but a real footgun when it happens. The prescribed workaround is explicit: pass a distinct `script_cursor: pid` Agent to each engine, derived from `ALLM.Providers.Fake.start_script_cursor/0`. The moduledoc calls this out in bold; a targeted test in `test/allm/providers/fake_test.exs` constructs two engines with identical scripts and asserts the collision (serving as both regression test and executable documentation of the rule). `:erlang.phash2/1` is a 27-bit hash, so distinct-content collisions are statistically rare but possible at scale; the `script_cursor` override is also the fix for the rare hash-collision case.

   The explicit-Agent override exists for two scenarios: (a) cross-process sharing (a Phase 7 `:manual` mode test might `Task.async/1` the adapter call and want the spawned task to see the cursor state), (b) the content-equal-collision case above. Pass `adapter_opts[:script_cursor]: pid` and Fake delegates to the Agent, mirroring Phase 3's `StubAdapter.start_script_cursor/0` API for continuity.

   Rejected alternatives: ETS-backed singleton (needs supervisor child + pid-monitor for GC — too heavy); Agent-per-engine started in a constructor helper that mints a unique token (pid / ref in `adapter_opts` breaks engine JSON-serializability, and the spec §31 sample shows `adapter_opts: [scripts: [...]]` without any helper); auto-generated monotonic token keyed on `self()` + `adapter_opts` identity (adds implicit state that's hard to reason about, trades one footgun for another).

   `Docs target: @moduledoc ALLM.Providers.Fake` (a paragraph explaining the automatic cursor, a bolded "Two engines with content-equal scripts in the same process collide — use explicit `script_cursor:` to disambiguate" warning, and a pointer to the `:script_cursor` escape hatch).

2. **Fake accepts two script shapes — spec §31 user-facing and Phase 3 harness — disambiguated per-entry-point.** The two entry points (`generate/2`, `stream/2`) use different disambiguation rules because the harness itself picks different opts keys for each:
   - **`generate/2`:** both shapes arrive on `adapter_opts[:script]` (or `:scripts` for §31 multi-call). Disambiguation is **by leading entry tag** — harness entries lead with `:ok` or 3-tuple `:error`; §31 entries lead with `:text`, `:tool_call`, `:tool_call_delta`, `:usage`, `:raw_chunk`, `:finish`, `:delay`, `:sleep`, or 2-tuple `:error`. These sets are disjoint. The `:error` tag arity-disambiguates (2 → §31, 3 → harness).
   - **`stream/2`:** harness uses `adapter_opts[:stream_script]` (verified against `conformance/lib/allm/test/stream_adapter_conformance.ex:90, 108, 120, 139, 164, 177` on 2026-04-24); §31 uses `adapter_opts[:script]` / `adapter_opts[:scripts]`. Distinct keys remove any tag-based ambiguity. Fake's `stream/2` reads `:stream_script` first; falls through to `:script` / `:scripts` when absent.

   The tags `:finish` and `:tool_call` literally appear in both vocabularies (harness's `StubAdapter.expand_event/1` handles both — see `conformance/test/support/fixtures/stub_adapter.ex:217-227` — and §31's event grammar includes them verbatim). This is NOT a disambiguation problem because their semantics are **identical** across shapes: `{:finish, reason}` emits `:message_completed`; `{:tool_call, kw}` emits `:tool_call_started` + `:tool_call_completed`. Fake's `Script.interpret/1` has one clause per shared tag that works regardless of the enclosing shape; only the disambiguating tags (`:ok`, 3-tuple `:error`, `:preflight_error`, `:error_event`, `:stream_error`, `:text_delta` vs. §31's `:text`, `:usage`, `:raw_chunk`, `:delay`, `:sleep`, `:tool_call_delta`, 2-tuple `:error`) need shape tagging. `ALLM.Providers.Fake.Script.detect_shape/1` runs the disambiguating-tag check and returns `{:spec31, entries}` or `{:harness, entries}`; entries consisting entirely of shared-semantics tags default to `:spec31`. Rejected alternatives: separate opts keys for all paths (would require a Phase 3 harness change to pass a different key for Fake — out of scope); a single unified shape with a conformance-side translator (same reason). `Docs target: @moduledoc ALLM.Providers.Fake` (a section "Script shapes" with both vocabularies tabulated, the disambiguation rules, and the per-entry-point key table).

3. **Script-exhausted calls return `{:error, %AdapterError{reason: :no_scripted_response}}` — the spec §31 atom is preserved verbatim as the struct's `:reason` field via a Phase 1 enum amendment.** Spec §31 phrases the outcome as `{:error, :no_scripted_response}`, but Phase 3's `ALLM.Adapter` behaviour contract narrowed `{:error, _}` to `{:error, %AdapterError{}}` — a bare atom would violate the behaviour. Rather than lose the spec atom entirely (by mapping to `:unknown` + metadata) or leave a perpetual drift between spec prose and implementation, Phase 4 extends `ALLM.Error.AdapterError.@legal_reasons` with `:no_scripted_response` as the 12th reason atom — a mechanical single-line Phase 1 amendment (verified against committed enum at `lib/allm/error/adapter_error.ex:35-46` on 2026-04-24 — the atom is not currently in the set, so this is a genuine extension). The atom is scoped to testing adapters; production adapters (OpenAI, Anthropic) will never produce it. A convenience constant `ALLM.Providers.Fake.script_exhausted_error()` returns the canonical struct (`%AdapterError{reason: :no_scripted_response, message: "no scripted response"}`) for pattern-match ergonomics. The `t:ALLM.Error.AdapterError.reason/0` union type is extended in lockstep. `Docs target: @doc ALLM.Providers.Fake.generate/2` + `@typedoc ALLM.Error.AdapterError.reason` (Phase 1 amendment's updated enum).

4. **Fake's `generate/2` folds scripted events into a `%Response{}` for the spec §31 shape, and passes the harness-shape `{:ok, map}` through `build_response/1` directly.** Two code paths, one entry point. The §31 fold accumulates `:text` → `output_text`, `:tool_call` → `tool_calls`, `:tool_call_delta` → merged into the pending tool call's `raw_arguments`, `:usage` → `usage`, `:finish` → `finish_reason`, and returns `%Response{}` at the end. The harness-shape path is the StubAdapter's — `{:ok, map}` → `build_response(map)`. Both paths yield identical `%Response{}` shape; the caller's choice of script vocabulary does not affect the output struct. Rejected alternative: a single unified fold that normalises harness-shape into §31-shape first — adds a translation step per call, obscures the invariant that harness-shape is already terminal. `Docs target: @doc ALLM.Providers.Fake.generate/2`.

5. **Mixing `script:` and `scripts:` in the same `adapter_opts` raises `ArgumentError` at the first adapter call, not at `Engine.new/1`.** The spec §31 phrasing "Mixing both raises on engine construction" is load-bearing but mis-sited — `Engine.new/1` is adapter-agnostic and cannot know the Fake-specific invariant. Fake raises at first call (via `ALLM.Providers.Fake.Script.validate!/1`), which is the earliest point Fake sees `adapter_opts`. For construction-time feedback, users may call `ALLM.Providers.Fake.Script.validate!/1` directly on their `adapter_opts` — this is the design's concession to the "on engine construction" spec language without coupling Engine to Fake. `Docs target: @doc ALLM.Providers.Fake.Script.validate!/1`.

6. **`{:usage, map}` script entries emit `{:raw_chunk, {:usage, map}}` in streaming mode and fold into `%Response.usage` in non-streaming mode.** Spec §31 lists `{:usage, map()}` as a script entry but spec §8's `ALLM.Event` union has no `:usage` variant. The closest native tag is `:raw_chunk` whose payload is opaque per §8, so wrapping the usage map inside a raw chunk preserves the 1:1 script-to-event claim without extending the closed union (which would be a breaking change for every Phase 5+ reducer). The `:raw_chunk` payload uses a 2-tuple `{:usage, map}` so downstream consumers can pattern-match on the inner tag without reflection. Non-streaming `generate/2` does not emit raw chunks; it accumulates `usage` maps directly (last-write-wins if multiple `:usage` entries appear in one call's script). `Docs target: @moduledoc ALLM.Providers.Fake` (a one-paragraph section under "Script → event mapping" explaining the `:usage` special case).

7. **`Stream.resource/3`'s `after_fun` is the only cleanup hook, and it increments `adapter_opts[:cleanup_observer]` (a `:counters` ref) when supplied.** The `:counters` mechanism is Phase 3's `StreamAdapterConformance` halt-safety harness contract — shared memory visible across async-test process boundaries, queried with `:counters.get(ref, 1)`, shaped as `:counters.new(1, [:atomics])` → opaque `{:atomics, #Reference}` tuple (not a bare `reference()` — verified in conformance harness at `stream_adapter_conformance.ex:150`). Fake honours the same contract so plugging into the harness is one line. For Fake's own tests (outside the harness), `test/allm/providers/fake_stream_test.exs` sets up a `:counters` ref inline and asserts cleanup independently. No `Process.exit/2`, no `Task.shutdown/1`, no Finch ref — Fake has no HTTP request to cancel; the cleanup is purely "hook your observer so your test can prove the cleanup fired".

   **Brutal-kill caveat.** `Stream.resource/3`'s `after_fun` runs synchronously on **normal** termination paths — consumer `Enum.take/N`, `Stream.take_while/2` returning `false`, `Stream.run/1` scope exit, throws from the reducer, and consumer process exits with a trappable reason (`:normal`, `:shutdown`, user-defined terms). It does **NOT** run when the consumer is killed with `Process.exit(pid, :kill)` — brutal exits skip all cleanup by OTP design. Real provider adapters (Phase 10–11) address this via Finch's own monitor-based connection cleanup; Fake has no HTTP ref to leak so the caveat is purely documentary. Tests assert cleanup on normal halts only; no test should simulate `:kill`. `Docs target: @moduledoc ALLM.Providers.Fake` (section "Cleanup observation").

8. **`{:sleep, ms}` is accepted as a deprecated alias of `{:delay, ms}` with a one-time `Logger.warning/1` per `VM-lifetime`.** Spec §31 notes the alias: "The historical alias `{:sleep, ms}` is accepted but deprecated — prefer `{:delay, ms}`." Implementing the warning via `:persistent_term.put/2` keyed on the module name ensures the log fires at most once per BEAM (users running a 1000-test suite don't see 1000 warnings). A tagged test (`@tag :capture_log`) in `fake_stream_test.exs` asserts the warning fires when `{:sleep, _}` is used. Deletion target: v0.3. `Docs target: @doc ALLM.Providers.Fake.Script.interpret/1` (a `## Deprecation` section).

9. **Fake does NOT emit `:step_completed`, `:chat_completed`, `:tool_execution_*`, `:ask_user_requested`, or `:tool_halt` events.** Those are orchestrator-owned variants (Phase 6 `Step`, Phase 7 `Chat`). An adapter emitting them would mislead downstream reducers into thinking the adapter had already run tool execution or full chat orchestration, which it has not. The Phase 3 `StreamAdapterConformance` harness already matches its "streams a plain text stream" case on `:message_completed` (not `:step_completed`) — consistent with this boundary. `Docs target: @moduledoc ALLM.Providers.Fake` (section "Adapter event vocabulary" — explicit positive and negative lists).

10. **`ALLM.Test.FakeFixtures` lives under `test/support/` (main project), not `lib/`.** The phasing doc says "`test/support/fake_fixtures.ex`"; per the main project's `mix.exs` `elixirc_paths(:test)`, `test/support/` is already on the test load path. Shipping the fixture library in `lib/` would force `Jason` / test helpers to be compile-time deps of the main package for runtime users, which is a runtime tax for non-test callers. Fixtures are test-only by nature; `test/support/` is the right home. Users writing their own tests import Fake (from `lib/`), not the fixture library — they script their own or copy a fixture verbatim. `Docs target: @moduledoc ALLM.Test.FakeFixtures` (one-line note pointing users to Fake itself for their own scripts).

11. **Empty-script / empty-scripts handling.** `adapter_opts: [script: []]` is treated as "zero scripted events in this call" — `generate/2` returns an empty-but-valid `%Response{output_text: "", finish_reason: :stop}` with `metadata: %{empty_script: true}`; `stream/2` returns a stream that emits `:message_started`, then immediately `:message_completed`, then halts. `adapter_opts: [scripts: []]` (multi-call with zero calls) is treated as "every call is exhausted" — `:no_scripted_response` from the first call on. `adapter_opts: [scripts: [[]]]` is one call with zero events (same as `script: []`). These three cases are tested explicitly. Rationale: well-defined corner cases help future test authors avoid "it crashed but I don't know why" when they pass an accidentally-empty fixture. `Docs target: @doc ALLM.Providers.Fake.generate/2` (one row in the behaviour table).

12. **`tool_choice` and `:tools` on the `Request` are ignored by Fake.** A real provider adapter translates these into wire-level fields. Fake has no wire, and testing tool orchestration happens at Phase 6 (ToolRunner) and Phase 7 (Chat). Fake's scripts directly emit `{:tool_call, _}` entries to simulate what the model would return; the caller can set up an engine with `tools: [...]` and a script with `{:tool_call, id: ..., name: ...}`, and Phase 6/7 orchestration will dispatch to the tool executor exactly as it would with a real provider. Documented in the moduledoc's "What Fake is (and isn't)" section. `Docs target: @moduledoc ALLM.Providers.Fake`.

13. **Conformance case 13 (`AdapterConformance` `:request_timeout` passthrough) requires no `opts_recorder` on Fake.** The harness's `opts_recorder` branch (`conformance/lib/allm/test/adapter_conformance.ex:174-202`) is gated on `@__allm_conformance_adapter__ == StubAdapter`; for any other adapter, the case drops to a universal `assert {:ok, _} = ... .generate(req, opts)` assertion. Fake satisfies this by returning `{:ok, %Response{}}` whenever the script has a response entry — it does NOT need to implement `start_opts_recorder/0` / `recorded_opts/1`. Documented so implementers don't reinvent the recorder API. `Docs target: internal — no user-facing docs needed`.

14. **`{:delay, ms}` entries are front-loaded: the interpreter sleeps before consuming the NEXT entry.** `Process.sleep/1` runs inside `Stream.resource/3`'s `next_fun`, which executes on the consumer's reducing process — the delay blocks that process, not a simulated provider. Timing tests measure the wall-clock interval between the emit preceding the `{:delay, _}` entry and the emit following it. Placing `{:delay, ms}` as the FIRST entry of a script delays `:message_started` (the synthetic bookend) by `ms` milliseconds. `Docs target: @moduledoc ALLM.Providers.Fake` (section "Backpressure and delays", one paragraph).

## Behaviour & Type Contracts

### `ALLM.Providers.Fake` (Layer B — `ALLM.Adapter` + `ALLM.StreamAdapter` impl)

```elixir
defmodule ALLM.Providers.Fake do
  @moduledoc """
  Deterministic, scripted adapter for testing. Implements `ALLM.Adapter` and
  `ALLM.StreamAdapter`. See spec §31.

  ## Script shapes

  Fake accepts two disjoint shapes on `adapter_opts[:script]` /
  `adapter_opts[:scripts]` (and `adapter_opts[:stream_script]`). See
  `ALLM.Providers.Fake.Script` for the full tag-to-shape table.
  """

  @behaviour ALLM.Adapter
  @behaviour ALLM.StreamAdapter

  @impl ALLM.Adapter
  @spec generate(ALLM.Request.t(), keyword()) ::
          {:ok, ALLM.Response.t()} | {:error, ALLM.Error.AdapterError.t()}
  def generate(request, opts)

  @impl ALLM.StreamAdapter
  @spec stream(ALLM.Request.t(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, ALLM.Error.AdapterError.t()}
  def stream(request, opts)

  @doc "Return the canonical `%AdapterError{}` for a script-exhausted call."
  @spec script_exhausted_error() :: ALLM.Error.AdapterError.t()
  def script_exhausted_error

  @doc "Start an Agent-backed script cursor for cross-process multi-call scripting."
  @spec start_script_cursor() :: pid()
  def start_script_cursor

  @doc "Read the current cursor index (for assertions in tests)."
  @spec cursor_index(pid()) :: non_neg_integer()
  def cursor_index(pid)
end
```

**Invariants:**

1. `generate/2` and `stream/2` never raise for script-defined failures. Script entries `{:error, term}` and script-exhausted states are converted to `{:error, %AdapterError{}}`. Only programmer errors (mixing `:script` and `:scripts`, passing a non-keyword `:adapter_opts`, unknown script-entry tag) raise `ArgumentError`.
2. `stream/2` returns a lazy `Enumerable.t()` — no event fires until the consumer reduces.
3. The returned stream uses `Stream.resource/3` with an `after_fun` that increments `adapter_opts[:cleanup_observer]` (a `:counters` ref, if present) by 1 at index 1. Halt-safety bound: the `after_fun` runs synchronously when the consumer halts (`Enum.take/2`, `Stream.take_while/2` returning false, consumer process exit).
4. `generate/2` is synchronous: it folds all scripted events into a `%Response{}` and returns. It does not emit events.
5. Multi-call scripting: `adapter_opts[:scripts]` is a `list(list(entry))`. Each call consumes one inner list; the cursor advances on every call. Calls beyond the last scripted turn return the canonical `script_exhausted_error/0`.
6. Script cursor state: by default stored in `Process.put/2` at key `{:allm_fake_cursor, :erlang.phash2(scripts)}`. When `adapter_opts[:script_cursor]` is a pid, Fake delegates to that Agent instead.
7. `request` is accepted but not read — Fake does not inspect any field of `%Request{}`. The scripted response is produced irrespective of the request's messages, tools, tool_choice, or params. This is intentional: Fake is for testing orchestration, not provider-wire fidelity.

**Error reason table (synchronous `generate/2` / `stream/2`):**

| Reason | `%AdapterError{...}` fields | Fires when |
|--------|------------------------------|------------|
| `:no_scripted_response` | `message: "no scripted response"` | Script cursor exceeded `length(scripts)`. Spec §31 atom preserved verbatim via the Phase 1 enum amendment (Non-obvious Decision #3). |
| `:unknown` | `cause: term` | Script entry was `{:error, term}` in §31 shape and `generate/2` is reducing a non-streaming call — the term is preserved in `:cause`. |
| `:authentication_failed` / `:rate_limited` / `:invalid_request` / `:provider_unavailable` / `:context_length_exceeded` / `:content_filter` / `:timeout` / `:network_error` / `:malformed_response` / `:unsupported_feature` | per harness script | Harness-shape `{:error, reason_atom, keyword()}` entry — forwarded verbatim through `AdapterError.new/2`. |

**Mid-stream `{:error, _}` event reason table (`stream/2`):**

| Struct type | Reason | Fires when |
|-------------|--------|------------|
| `AdapterError` | `:unknown`/`:rate_limited`/etc. | Harness-shape `{:error_event, reason, opts}`, or §31-shape `{:error, term}` where the term is an atom in `AdapterError.reason()` closed set. |
| `StreamError` | `:cancelled` / `:timeout` / `:malformed_event` / `:adapter_error` / `:unknown` | Harness-shape `{:stream_error, reason, opts}`. |
| `AdapterError` | `:unknown` (cause=term) | §31-shape `{:error, term}` where the term is NOT an atom in `AdapterError.reason()` — wrapped with `cause: term`. |

**Adapter event vocabulary (streaming):**

Emitted: `:message_started`, `:text_delta`, `:text_completed`, `:tool_call_started`, `:tool_call_delta`, `:tool_call_completed`, `:message_completed`, `:raw_chunk`, `:error`.

Not emitted (orchestrator-owned — Phase 6/7): `:tool_execution_started`, `:tool_execution_completed`, `:tool_result_encoded`, `:ask_user_requested`, `:tool_halt`, `:step_completed`, `:chat_completed`.

**Idiomatic Elixir requirements:**

- `@behaviour ALLM.Adapter` and `@behaviour ALLM.StreamAdapter` both declared — Dialyzer verifies both callback sets.
- `@impl true` annotations on every callback implementation.
- `Stream.resource/3` with a 3-arity anonymous function returning `{[events], new_state} | {:halt, reason}` per OTP 27 (verified against OTP 27 docs and `conformance/test/support/fixtures/stub_adapter.ex:198`).
- `Logger.warning/1` via `require Logger` — once-per-VM dedup via `:persistent_term.put/2` with a module-name key (`__MODULE__.Script.SleepWarning` — a namespaced atom confirmed writable via `:persistent_term.put/2` on OTP 27).

### `ALLM.Providers.Fake.Script` (Layer B — helper module)

```elixir
defmodule ALLM.Providers.Fake.Script do
  @moduledoc """
  Script shape detection, validation, and interpretation for
  `ALLM.Providers.Fake`. See spec §31.
  """

  @typedoc "Detected shape of a script — §31 (user-facing) or Phase 3 harness."
  @type shape :: :spec31 | :harness

  @typedoc "A single spec §31 script entry (one call's worth of events)."
  @type spec31_entry ::
          {:text, String.t()}
          | {:tool_call, keyword()}
          | {:tool_call_delta, keyword()}
          | {:usage, map()}
          | {:raw_chunk, term()}
          | {:finish, ALLM.Response.finish_reason()}
          | {:error, term()}
          | {:delay, non_neg_integer()}
          | {:sleep, non_neg_integer()}

  @typedoc "A single Phase 3 harness-shape entry (non-streaming)."
  @type harness_adapter_entry ::
          {:ok, map()}
          | {:error, atom(), keyword()}

  @typedoc "A single Phase 3 harness-shape entry (streaming)."
  @type harness_stream_entry ::
          {:text_delta, String.t()}
          | {:finish, atom()}
          | {:preflight_error, atom(), keyword()}
          | {:error_event, atom(), keyword()}
          | {:stream_error, atom(), keyword()}

  @spec detect_shape([term()]) :: {:spec31 | :harness, [term()]}
  def detect_shape(entries)

  @spec validate!(keyword()) :: :ok
  def validate!(adapter_opts)

  @spec fold_to_response([spec31_entry() | harness_adapter_entry()]) :: ALLM.Response.t()
  def fold_to_response(entries)

  @spec interpret(spec31_entry() | harness_stream_entry()) :: [ALLM.Event.t()]
  def interpret(entry)
end
```

**Shape-detection algorithm:**

`detect_shape/1` is used only when the opts-key routing is ambiguous — that is, for `generate/2` where both shapes travel on `adapter_opts[:script]`. For `stream/2`, the caller's key choice (`:stream_script` vs. `:script`/`:scripts`) already disambiguates; `detect_shape/1` is not called on that path.

- `detect_shape/1` inspects the first element's leading tag. Lookup table (only disambiguating tags are classified; shared-semantics tags default to `:spec31`):
  - Harness-only (non-streaming): `:ok` → `:harness`.
  - Harness-only (streaming-only, but legal inputs if a user hand-writes harness-style streaming scripts on the `:script` key): `:preflight_error`, `:text_delta`, `:error_event`, `:stream_error` → `:harness`.
  - §31-only: `:text`, `:tool_call_delta`, `:usage`, `:raw_chunk`, `:delay`, `:sleep` → `:spec31`.
  - Shared (same semantics in both shapes): `:tool_call`, `:finish` → default to `:spec31` (the shared interpreter handles both identically, so the classification is inconsequential).
  - `:error` → disambiguate by `tuple_size/1`: 2 → `:spec31`, 3 → `:harness`.
  - Unknown tag → raise `ArgumentError` with the unknown tag and a pointer to both vocabularies.
- For an empty entry list, `detect_shape/1` returns `{:spec31, []}` (the default).

**Validation algorithm (`validate!/1`):**

- `Keyword.has_key?(opts, :script) and Keyword.has_key?(opts, :scripts)` → `raise ArgumentError, "cannot mix :script and :scripts in adapter_opts (spec §31)"`.
- `Keyword.has_key?(opts, :script) and not is_list(Keyword.fetch!(opts, :script))` → `raise ArgumentError, ":script must be a list of entries"`.
- `Keyword.has_key?(opts, :scripts) and not is_list_of_lists?(Keyword.fetch!(opts, :scripts))` → `raise ArgumentError, ":scripts must be a list of lists"`.
- `Keyword.has_key?(opts, :stream_script) and not is_list_of_lists?(Keyword.fetch!(opts, :stream_script))` → `raise ArgumentError, ":stream_script must be a list of lists"`.
- `Keyword.has_key?(opts, :script_cursor)` and the value is neither a pid nor `nil` → `raise ArgumentError`.
- Otherwise return `:ok`.

**Fold-to-Response semantics (`fold_to_response/1`):**

Initial accumulator: `%{output_text: "", tool_calls: %{}, finish_reason: :stop, usage: %ALLM.Usage{}, raw_finish_reason: nil, tool_call_order: [], request_id: nil}`.

Per-entry reducer (spec §31 shape):

- `{:text, s}` → append `s` to `output_text`.
- `{:tool_call, kw}` → require `:id` and `:name` keys; build `%ToolCall{id:, name:, arguments: Keyword.get(kw, :arguments, %{}), raw_arguments: kw[:raw_arguments] || Jason.encode!(args)}`; insert into `tool_calls[id]`; append `id` to `tool_call_order`.
- `{:tool_call_delta, kw}` → require `:id` and `:arguments_delta` keys; append `arguments_delta` to the pending tool call's `raw_arguments`; on `:tool_call_completed` or `:finish`, re-parse `raw_arguments` via `Jason.decode/1` (best-effort — if decode fails, leave `arguments: %{}` and surface the raw string only).
- `{:usage, map}` → `struct!(ALLM.Usage, map)` (last-write-wins).
- `{:raw_chunk, _}` → ignored in non-streaming fold (raw chunks have no place on `%Response{}`).
- `{:finish, reason}` → set `finish_reason: reason`.
- `{:error, term}` → short-circuit: return `{:error, %AdapterError{reason: :unknown, message: "scripted error", cause: term}}`.
- `{:delay, _}` / `{:sleep, _}` → `Process.sleep/1`. (Yes, even non-streaming `generate/2` honours `{:delay, _}` so tests can exercise request_timeout paths — documented in Non-obvious Decision #12... wait, that's not a decision. Let me incorporate this into the fold table here.) In non-streaming mode, `Process.sleep/1` is still useful for testing `opts[:request_timeout]` enforcement in Phase 5.

Per-entry reducer (harness shape): `{:ok, map}` → `build_response(map)`; `{:error, reason, opts}` → `{:error, AdapterError.new(reason, opts)}`. (Harness shape is exactly one entry per call; the fold returns on the first entry.)

**Interpret-for-stream semantics (`interpret/1`):**

Per §31 entry → list of `ALLM.Event` values:

| Script entry | Events produced |
|--------------|-----------------|
| `{:text, s}` | `[{:text_delta, %{id: nil, delta: s}}]` |
| `{:tool_call, kw}` | `[{:tool_call_started, %{id, name}}, {:tool_call_completed, %{id, name, arguments, raw_arguments}}]` (2 events — violates 1:1, but necessary so downstream sees the full lifecycle. The spec §31 "1:1" promise is relaxed for `:tool_call` and `:finish`; documented.) |
| `{:tool_call_delta, kw}` | `[{:tool_call_delta, %{id, arguments_delta}}]` |
| `{:usage, map}` | `[{:raw_chunk, {:usage, map}}]` (Non-obvious Decision #6) |
| `{:raw_chunk, term}` | `[{:raw_chunk, term}]` |
| `{:finish, reason}` | `[{:text_completed, ...} \|\| [], {:message_completed, %{message: assistant_msg}}]` — `:text_completed` prepended only if any `:text` was emitted earlier in this call (carry state between `interpret/1` calls through the fold acc). |
| `{:error, term}` | `[{:error, AdapterError.new(:unknown, cause: term)}]` when `term` is not an atom in `AdapterError.reason()`, else `[{:error, AdapterError.new(term)}]` (atom forwarded to struct). |
| `{:delay, ms}` | `[]` — interpret wraps a `Process.sleep(ms)` in the `Stream.resource/3` `next_fun` before continuing to the next entry. |
| `{:sleep, ms}` | same as `{:delay, _}`, plus `warn_once()`. |

Harness-shape stream entries: `{:text_delta, s}` → `[{:text_delta, %{id: nil, delta: s}}]`; `{:finish, _}` → `[{:message_completed, _}]`; `{:preflight_error, reason, opts}` → synchronous `{:error, AdapterError.new(reason, opts)}` from `stream/2` (not an event); `{:error_event, reason, opts}` → `[{:error, AdapterError.new(reason, opts)}]`; `{:stream_error, reason, opts}` → `[{:error, StreamError.new(reason, opts)}]`.

**Idiomatic Elixir requirements:**

- `is_list_of_lists?/1` is a private helper: `is_list(x) and Enum.all?(x, &is_list/1)`.
- `Jason.encode!/1` failures during `tool_call` raw-arguments synthesis bubble up as `Protocol.UndefinedError` — Jason dispatches through the `Jason.Encoder` protocol and a missing impl raises `Protocol.UndefinedError`, not `Jason.EncodeError` (verified in IEx on OTP 27 on 2026-04-24: `Jason.encode!(fn -> :ok end)` raises `Protocol.UndefinedError`). A targeted test wraps a tool-call fixture with a non-encodable `:arguments` value and asserts `Protocol.UndefinedError`; the moduledoc documents the pass-through so users know to convert tuples / pids / funs before passing them as tool-call arguments.
- `struct!(ALLM.Usage, map)` raises `KeyError` if the map has keys that aren't `ALLM.Usage` fields (verified in IEx on OTP 27 on 2026-04-24: `struct!(%ALLM.Usage{}, %{prompt_tokens: 5})` raises `KeyError` at `struct!/2` — the committed fields are `:input_tokens`, `:output_tokens`, `:cached_input_tokens`, `:reasoning_tokens`, `:total_tokens`, `:input_cost`, `:output_cost`, `:total_cost`, `:tool_usage`, `:extra` per `lib/allm/usage.ex:26-37`). Script authors must use the committed field names; `{:usage, %{prompt_tokens: 5}}` raises `KeyError` at fold time. A targeted test covers this.

### `ALLM.Test.FakeFixtures` (Layer B — test support)

```elixir
defmodule ALLM.Test.FakeFixtures do
  @moduledoc """
  Named scripted scenarios for `ALLM.Providers.Fake`. Every fixture returns
  a keyword-list `adapter_opts` ready to pass to `ALLM.Engine.new/1`.
  """

  @spec plain_text(String.t()) :: keyword()
  def plain_text(text \\ "Hello world")

  @spec single_tool_call(String.t(), map()) :: keyword()
  def single_tool_call(name, arguments)

  @spec parallel_tool_calls([{String.t(), map()}]) :: keyword()
  def parallel_tool_calls(calls)

  @spec multi_turn_conversation([[ALLM.Providers.Fake.Script.spec31_entry()]]) :: keyword()
  def multi_turn_conversation(scripts)

  @spec mid_stream_error(ALLM.Error.AdapterError.reason()) :: keyword()
  def mid_stream_error(reason)

  @spec empty_response() :: keyword()
  def empty_response

  @spec tool_call_with_streamed_args(String.t(), String.t()) :: keyword()
  def tool_call_with_streamed_args(name, arguments_json)

  @spec delayed_text(String.t(), non_neg_integer()) :: keyword()
  def delayed_text(text, delay_ms)
end
```

Eight fixtures ≥ phasing doc's "at least eight" requirement. Each returns a `adapter_opts` kwlist; callers plug into `Engine.new/1` directly.

## Module Tree

```
lib/allm/
├── providers/                                (NEW directory)
│   ├── fake.ex                               (NEW — ALLM.Providers.Fake: both behaviours)
│   └── fake/
│       └── script.ex                         (NEW — ALLM.Providers.Fake.Script: interpreter)

test/allm/
├── providers/                                (NEW directory)
│   ├── fake_test.exs                         (NEW — generate/2 + conformance plug-in)
│   ├── fake_stream_test.exs                  (NEW — stream/2 + halt-safety + conformance plug-in)
│   └── fake/
│       └── script_test.exs                   (NEW — unit tests for shape detection + fold)

test/support/
└── fake_fixtures.ex                          (NEW — ALLM.Test.FakeFixtures)

CHANGELOG.md                                  (MODIFY — one line per new public module)
```

No changes to `mix.exs` (the `allm_conformance` path-dep already present from Phase 3), no changes to `ALLM.Application` (cursor is process-local — Non-obvious Decision #1), no changes to `conformance/`. Test files mirror source 1:1; fixture library under `test/support/` per `AGENT_DESIGN_SPEC.md` §Module Tree and Non-obvious Decision #10.

## Phases

### Sub-phase 4.1: `ALLM.Providers.Fake.Script` — interpreter + shape detection + Phase 1 enum amendment (Layer B + Layer A one-line change)

**Goal:** Ship the pure, dependency-free interpreter module that both `generate/2` and `stream/2` delegate to. Validate `adapter_opts` at the boundary; detect shape by leading tag; fold §31-shape entries into an intermediate accumulator; translate single entries into `ALLM.Event` lists. Also land the scoped Phase 1 amendment adding `:no_scripted_response` to `ALLM.Error.AdapterError.@legal_reasons` (Non-obvious Decision #3).

**Spec sections:** §31, §8, §20

#### 4.1.1 Test Plan (write first)

`test/allm/providers/fake/script_test.exs` (NEW):

Shape detection (`detect_shape/1`):
- `detect_shape([{:text, "hi"}, {:finish, :stop}])` returns `{:spec31, entries}`.
- `detect_shape([{:ok, %{output_text: "hi"}}])` returns `{:harness, entries}`.
- `detect_shape([{:text_delta, "hi"}])` returns `{:harness, entries}` (stream-side harness tag).
- `detect_shape([{:error, :network_error}])` returns `{:spec31, entries}` (2-tuple).
- `detect_shape([{:error, :rate_limited, [status: 429]}])` returns `{:harness, entries}` (3-tuple).
- `detect_shape([{:finish, :stop}])` returns `{:spec31, entries}` — shared-semantics tag, default is `:spec31` (interpreter handles both shapes identically for `:finish`).
- `detect_shape([{:tool_call, id: "x", name: "y"}, {:finish, :tool_calls}])` returns `{:spec31, entries}` — same rationale.
- `detect_shape([])` returns `{:spec31, []}` (default).
- `detect_shape([{:bogus_tag, "x"}])` raises `ArgumentError` mentioning both vocabularies.

Validation (`validate!/1`):
- `validate!([script: [], scripts: []])` raises `ArgumentError, "cannot mix :script and :scripts"`.
- `validate!([script: [{:text, "hi"}]])` returns `:ok`.
- `validate!([scripts: [[{:text, "hi"}]]])` returns `:ok`.
- `validate!([stream_script: [[{:text_delta, "hi"}]]])` returns `:ok`.
- `validate!([script: "not a list"])` raises `ArgumentError, ":script must be a list"`.
- `validate!([scripts: [not_a_list: :oops]])` raises `ArgumentError, ":scripts must be a list of lists"`.
- `validate!([stream_script: "not a list-of-lists"])` raises `ArgumentError, ":stream_script must be a list of lists"`.
- `validate!([script_cursor: 42])` raises `ArgumentError` (not a pid, not nil).
- `validate!([script_cursor: self()])` returns `:ok`.
- `validate!([])` returns `:ok` (empty opts).
- `validate!([script: []])` returns `:ok` — empty script is valid (Non-obvious Decision #11).

Fold-to-Response (`fold_to_response/1`, spec §31 shape):
- Plain text: `[{:text, "hello"}, {:finish, :stop}]` → `%Response{output_text: "hello", finish_reason: :stop}`.
- Concatenation: `[{:text, "hel"}, {:text, "lo"}, {:finish, :stop}]` → `%Response{output_text: "hello"}`.
- Tool call: `[{:tool_call, id: "c1", name: "w", arguments: %{city: "B"}}, {:finish, :tool_calls}]` → `%Response{tool_calls: [%ToolCall{id: "c1", ...}], finish_reason: :tool_calls}`.
- Tool-call deltas then completion: `[{:tool_call_delta, id: "c1", arguments_delta: ~S({"ci)}, {:tool_call_delta, id: "c1", arguments_delta: ~S(ty":"B"})}, {:finish, :tool_calls}]` where `tool_call` implicit-start via the delta's id — verify `raw_arguments` accumulates and `arguments` is re-parsed on close.
- Usage: `[{:text, "hi"}, {:usage, %{input_tokens: 5, output_tokens: 2}}, {:finish, :stop}]` → `%Response{usage: %Usage{input_tokens: 5, output_tokens: 2}}`.
- Usage with wrong field names: `[{:usage, %{prompt_tokens: 5}}, {:finish, :stop}]` raises `KeyError` at `struct!(Usage, …)` — documented regression test so implementers don't accidentally support deprecated OpenAI field names.
- Error short-circuit: `[{:text, "hi"}, {:error, :boom}]` → `{:error, %AdapterError{reason: :unknown, cause: :boom}}`.
- Delay no-op: `[{:delay, 1}, {:text, "hi"}, {:finish, :stop}]` → `%Response{output_text: "hi"}` (delay enforced via `Process.sleep/1` but test asserts wall-clock duration >= 1ms; avoid flaky >= threshold by using 50ms and asserting lower bound).

Fold-to-Response (harness shape):
- `[{:ok, %{output_text: "hi", finish_reason: :stop}}]` → `%Response{output_text: "hi", finish_reason: :stop}`.
- `[{:error, :rate_limited, [retry_after_ms: 500]}]` → `{:error, %AdapterError{reason: :rate_limited, retry_after_ms: 500}}`.

Interpret-for-stream (`interpret/1`):
- `{:text, "hi"}` → `[{:text_delta, %{id: nil, delta: "hi"}}]`.
- `{:tool_call, id: "c1", name: "w", arguments: %{"city" => "B"}}` → 2-element list: `:tool_call_started` + `:tool_call_completed`.
- `{:tool_call_delta, id: "c1", arguments_delta: ~S({"ci)}` → `[{:tool_call_delta, %{id: "c1", arguments_delta: "{\"ci"}}]`.
- `{:usage, %{input_tokens: 1}}` → `[{:raw_chunk, {:usage, %{input_tokens: 1}}}]`.
- `{:raw_chunk, "raw"}` → `[{:raw_chunk, "raw"}]`.
- `{:error, :rate_limited}` (known atom in `AdapterError.reason()`) → `[{:error, %AdapterError{reason: :rate_limited}}]`.
- `{:error, :some_unknown_term}` (atom not in AdapterError enum) → `[{:error, %AdapterError{reason: :unknown, cause: :some_unknown_term}}]`.
- `{:error, "string"}` (non-atom term) → `[{:error, %AdapterError{reason: :unknown, cause: "string"}}]`.
- Harness `{:error_event, :rate_limited, [status: 429]}` → `[{:error, %AdapterError{reason: :rate_limited, status: 429}}]`.
- Harness `{:stream_error, :cancelled, []}` → `[{:error, %StreamError{reason: :cancelled}}]`.

Doctests: at least one runnable doctest on `detect_shape/1` and `fold_to_response/1`.

Phase 1 enum amendment (`test/allm/error/adapter_error_test.exs` — MODIFY):

- `AdapterError.new(:no_scripted_response)` returns `%AdapterError{reason: :no_scripted_response, message: "adapter error: no_scripted_response"}`.
- `AdapterError.legal_reasons()` (if exported) or `AdapterError.__info__(...)` reflects 12 atoms including `:no_scripted_response`.
- The `t:AdapterError.reason/0` type compiles without Dialyzer warnings against callers that pattern-match on `:no_scripted_response`.

#### 4.1.2 Implementation Checklist

- [ ] Extend `lib/allm/error/adapter_error.ex`: add `:no_scripted_response` to `@legal_reasons` (currently 11 atoms → 12); add it to the `t:reason/0` typedoc union; add a one-line row to the error-reason table in the module's `@moduledoc`. Update `test/allm/error/adapter_error_test.exs` (Phase 1's suite) to assert `AdapterError.new(:no_scripted_response)` succeeds and `legal_reasons/0` returns the 12-atom set.
- [ ] Create `lib/allm/providers/fake/script.ex` with `@moduledoc` from §Behaviour & Type Contracts.
- [ ] Implement `@type spec31_entry`, `@type harness_adapter_entry`, `@type harness_stream_entry`, `@type shape`.
- [ ] Implement `detect_shape/1` with `@shape_table` module attribute mapping tag → shape; handle `:error` by `tuple_size/1` disambiguation; shared-semantics tags (`:finish`, `:tool_call`) default to `:spec31`; raise `ArgumentError` on unknown tag.
- [ ] Implement `validate!/1` with five guard clauses (mix, shape of `:script`, shape of `:scripts`, shape of `:stream_script`, shape of `:script_cursor`).
- [ ] Implement `fold_to_response/1` as a `Enum.reduce/3` over entries with a `{:cont | :halt, acc}` pattern via `Enum.reduce_while/3` for the `{:error, _}` short-circuit.
- [ ] Implement `interpret/1` with one clause per entry tag.
- [ ] Add `@spec` and `@doc` on every public function.
- [ ] Doctests on `detect_shape/1` and `fold_to_response/1`.

#### 4.1.3 Verification

```bash
mix test test/allm/providers/fake/script_test.exs
mix test --cover                                # ≥90% on lib/allm/providers/fake/script.ex
mix dialyzer
mix credo --strict lib/allm/providers/fake/script.ex
mix format --check-formatted
```

### Sub-phase 4.2: `ALLM.Providers.Fake` — `ALLM.Adapter` implementation (Layer B)

**Goal:** Non-streaming `generate/2` callback. Delegates to `Fake.Script.validate!/1`, resolves the cursor, reads the current script entry-list, runs `Fake.Script.fold_to_response/1`, returns `{:ok, %Response{}} | {:error, %AdapterError{}}`.

**Spec sections:** §7.1, §31, §20

#### 4.2.1 Test Plan (write first)

`test/allm/providers/fake_test.exs` (NEW):

Happy path (§31 shape):
- `generate/2 with script: [{:text, "hi"}, {:finish, :stop}]` returns `{:ok, %Response{output_text: "hi", finish_reason: :stop}}`.
- `generate/2 with scripts: [[{:text, "call_1"}, {:finish, :stop}]]` returns the same (single-call scripts is equivalent to `script:`).
- Multi-call: script `[[{:text, "a"}, {:finish, :stop}], [{:text, "b"}, {:finish, :stop}]]`; first call returns `output_text: "a"`; second call from the same process returns `output_text: "b"`; third call returns `script_exhausted_error/0`.
- Multi-call with explicit `script_cursor: pid`: same semantics, cursor advances via the Agent; `cursor_index(pid)` returns 2 after two calls.

Happy path (harness shape):
- `generate/2 with script: [{:ok, %{output_text: "hi"}}]` returns `{:ok, %Response{output_text: "hi"}}`.
- `generate/2 with script: [{:error, :rate_limited, [retry_after_ms: 500]}]` returns `{:error, %AdapterError{reason: :rate_limited, retry_after_ms: 500}}`.

Error paths:
- Script-exhausted (`adapter_opts: [script: []]` called once — empty is valid per Non-obvious Decision #11, returns `%Response{output_text: "", finish_reason: :stop, metadata: %{empty_script: true}}`; but `adapter_opts: [scripts: []]` called once returns script-exhausted error).
- `{:error, :boom}` §31 entry → `{:error, %AdapterError{reason: :unknown, cause: :boom}}`.
- Mixing `script:` and `scripts:` — `generate/2` raises `ArgumentError`.
- `:script_cursor` that isn't a pid — `generate/2` raises `ArgumentError`.

Request-ignoring:
- Same script, different requests (including empty thread, threads with tool results, etc.) → same response. Documents that request content does not influence Fake.

Cursor behaviour:
- Default cursor (process-dict): two engines with different scripts in the same process advance independently (different `phash2` keys).
- **Content-equal collision (documented footgun — Non-obvious Decision #1):** two engines built with identical `scripts:` values in the same process share a cursor. A regression test constructs two engines both scripted with `[[{:text, "a"}, {:finish, :stop}], [{:text, "b"}, {:finish, :stop}]]`, calls `generate/2` once on each, and asserts the second engine's call returns the SECOND script entry (not the first) — proving the collision is behavioural, documented, and detectable. The test's `@doc` references Non-obvious Decision #1 and names the workaround (`script_cursor:` Agent).
- Explicit cursor pid (workaround for the collision case): two engines with identical scripts but DISTINCT `script_cursor: pid` values advance independently; same test as above but with two `start_script_cursor/0` pids asserts each engine's first call reads index 0.
- Explicit cursor pid (cross-process sharing): two engines SHARING a cursor pid across processes — parent and spawned Task — advance the same counter; asserts `cursor_index(pid)` after each call.
- Cross-process cursor default (no explicit pid): spawn a Task that calls `generate/2` with the same scripts-content — default process-dict cursor does NOT share (different pid → different process-dict) — each process's first call reads index 0 independently.

`request_id` propagation:
- `adapter_opts[:request_id]` is copied onto `%Response.request_id`.

Doctest:
- One runnable doctest on `ALLM.Providers.Fake.generate/2` using a 2-entry script.

Conformance plug-in (last line of the test file):
- `use ALLM.Test.AdapterConformance, adapter: ALLM.Providers.Fake` — inherits the 13 cases from Phase 3's harness. Each case passes without modification to Fake because Fake's harness-shape branch is a superset of StubAdapter's semantics.

#### 4.2.2 Implementation Checklist

- [ ] Create `lib/allm/providers/fake.ex` with `@behaviour ALLM.Adapter` and `@behaviour ALLM.StreamAdapter`.
- [ ] `@moduledoc` covering script shapes, cursor behaviour, event vocabulary, cleanup observation, per Non-obvious Decisions 1, 2, 7, 9, 10, 12.
- [ ] Implement `generate/2`:
  - `opts |> Keyword.get(:adapter_opts, []) |> Script.validate!()`.
  - Determine whether `:script` or `:scripts` is present; if `:script`, wrap as `[script]` for uniform handling.
  - Resolve cursor: if `adapter_opts[:script_cursor]` is a pid, delegate to `Agent.get_and_update/2`; else read/write `Process.put/get` at `{:allm_fake_cursor, :erlang.phash2(scripts)}`.
  - Index the current script (`Enum.at(scripts, cursor)`); if `nil`, return `script_exhausted_error/0`.
  - Call `Script.fold_to_response(entries)`.
  - Propagate `:request_id` from `adapter_opts` onto the response.
- [ ] Implement `script_exhausted_error/0` returning the canonical struct.
- [ ] Implement `start_script_cursor/0` and `cursor_index/1` (Agent wrappers).
- [ ] `@impl ALLM.Adapter` on `generate/2`.
- [ ] `@spec` on every public function.
- [ ] Doctest on `generate/2`.
- [ ] Append `use ALLM.Test.AdapterConformance, adapter: ALLM.Providers.Fake` at the bottom of `test/allm/providers/fake_test.exs`.

#### 4.2.3 Verification

```bash
mix test test/allm/providers/fake_test.exs
mix test --cover                                # ≥90% on lib/allm/providers/fake.ex (both callbacks once 4.3 lands)
mix dialyzer
mix credo --strict lib/allm/providers/fake.ex
mix format --check-formatted
```

### Sub-phase 4.3: `ALLM.Providers.Fake` — `ALLM.StreamAdapter` implementation (Layer B)

**Goal:** Streaming `stream/2` callback. Returns a `Stream.resource/3` that emits `:message_started`, drives per-entry `interpret/1` calls, emits `:text_completed` before `:message_completed` if text was seen, honours `{:delay, ms}` via `Process.sleep/1` in `next_fun`, and runs the `after_fun` cleanup observer (counters increment) on consumer halt.

**Spec sections:** §7.2, §8, §30, §31

#### 4.3.1 Test Plan (write first)

`test/allm/providers/fake_stream_test.exs` (NEW):

Happy path (§31 shape):
- Plain text: `script: [{:text, "hel"}, {:text, "lo"}, {:finish, :stop}]` → stream emits `:message_started`, `:text_delta` × 2, `:text_completed`, `:message_completed` (5 events).
- Single tool call: `script: [{:tool_call, id: "c1", name: "w", arguments: %{city: "B"}}, {:finish, :tool_calls}]` → `:message_started`, `:tool_call_started`, `:tool_call_completed`, `:message_completed` (4 events — `:tool_call_completed`'s 2-event interpretation + implicit `:message_started` and `:message_completed`).
- Tool-call with streaming args: `script: [{:tool_call_delta, id: "c1", arguments_delta: ~S({"ci)}, {:tool_call_delta, id: "c1", arguments_delta: ~S(ty":"B"})}, {:finish, :tool_calls}]` → `:message_started`, `:tool_call_delta` × 2, `:message_completed` (4 events; note no `:tool_call_started` since no `:tool_call` entry appeared — documents that delta-only mode skips the start event).
- Empty script: `script: []` → `:message_started`, `:message_completed` (2 events).
- `{:raw_chunk, _}`: passes through.
- `{:usage, %{...}}`: emits `{:raw_chunk, {:usage, %{...}}}`.

Happy path (harness shape, for conformance — opts key is `:stream_script`):
- `adapter_opts: [stream_script: [[{:text_delta, "hel"}, {:text_delta, "lo"}, {:finish, :stop}]]]` → stream with `:text_delta` × 2 + `:message_completed`. Note the list-of-lists (one inner list per call) — harness multi-call cursor advances via the standard per-process mechanism.
- `adapter_opts: [stream_script: [[...first call...], [...second call...]]]` — sequential calls from the same process advance the cursor.
- `adapter_opts: [script: [...§31 flat...]]` (no `:stream_script` key) → §31-shape interpretation. `stream/2` reads `:stream_script` first; falls through to `:script` / `:scripts` when absent.

Error paths:
- §31 `{:error, :rate_limited}` mid-stream (passed via `script:`) → terminating `{:error, %AdapterError{reason: :rate_limited}}` event.
- §31 `{:error, "some string"}` mid-stream → terminating `{:error, %AdapterError{reason: :unknown, cause: "some string"}}`.
- Harness `stream_script: [[{:preflight_error, :authentication_failed, [status: 401]}]]` → synchronous `{:error, %AdapterError{reason: :authentication_failed, status: 401}}` from `stream/2` (not an event — matches conformance case 1–9).
- Harness `stream_script: [[{:error_event, :rate_limited, [retry_after_ms: 500]}]]` → terminating `{:error, %AdapterError{reason: :rate_limited, retry_after_ms: 500}}` event (matches conformance case 11).
- Harness `stream_script: [[{:stream_error, :cancelled, []}]]` → terminating `{:error, %StreamError{reason: :cancelled}}` event (matches conformance case 12).

Timing / backpressure:
- `{:delay, 50}` between two `:text` entries → wall-clock duration between the two `:text_delta` events is ≥ 50 ms (assert lower bound; flakiness bounded by the interpreter's `Process.sleep/1`).
- `{:delay, _}` as the FIRST entry → `:message_started` emission is delayed. Asserts the front-loaded-delay invariant from Non-obvious Decision #14.
- `{:sleep, 50}` (deprecated alias) → same effect; `@tag :capture_log` asserts one `Logger.warning/1` fires.

Cancellation / halt safety (both shapes must work):
- **§31 shape:** 10-event `script:` (`[{:text, "a"}, …, {:text, "j"}, {:finish, :stop}]`); consumer `Enum.take(stream, 2)`; assert `adapter_opts[:cleanup_observer]` (a `:counters` ref) reads `:counters.get(ref, 1) == 1` via `eventually/2` within 500 ms.
- **Harness shape:** same fixture expressed as `stream_script: [[{:text_delta, "a"}, ..., {:text_delta, "j"}, {:finish, :stop}]]`; same `Enum.take(stream, 2)` + `:counters` assertion within 500 ms. This is the form the `StreamAdapterConformance` halt-safety case (`conformance/lib/allm/test/stream_adapter_conformance.ex:150-172`) passes Fake — both forms must pass independently.
- Normal consumer termination paths: `Enum.take/2`, `Stream.take_while/2` returning false, `Stream.run/1` with a reducer that throws, consumer process exit with `:normal` reason. All fire `after_fun` within 500 ms.
- Consumer runs the stream to completion; `:counters` ref increments exactly once (not once-per-event).
- **Not tested:** `Process.exit(consumer_pid, :kill)` — brutal kill skips `after_fun` per OTP 27 design (Non-obvious Decision #7 caveat). Tests asserting counter increments on `:kill` would be flaky and misrepresent the contract; they are explicitly out of scope.

Multi-call scripting (streams):
- §31: `scripts: [[{:text, "a"}, {:finish, :stop}], [{:text, "b"}, {:finish, :stop}]]`; first `stream/2` yields text "a"; second (same process) yields text "b"; third returns synchronous `{:error, script_exhausted_error()}`.
- Harness: `stream_script: [[...first call...], [...second call...]]`; same semantics through the `:stream_script` key.
- Explicit `script_cursor: pid`: same semantics through the Agent; works with both keys.

Request-ignoring: same script across different requests → same event stream.

Doctest:
- One runnable doctest on `ALLM.Providers.Fake.stream/2`.

Conformance plug-in (last line of the test file):
- `use ALLM.Test.StreamAdapterConformance, stream_adapter: ALLM.Providers.Fake` — inherits the 14 Phase 3 harness cases. Pre-flight errors, mid-stream errors, halt-safety, and `:stream_timeout` pass unchanged.

#### 4.3.2 Implementation Checklist

- [ ] Implement `stream/2`:
  - `Script.validate!(adapter_opts)` — accepts `:script`, `:scripts`, `:stream_script`, `:script_cursor`, `:cleanup_observer`.
  - Resolve the script source with key precedence: `:stream_script` (harness — always list-of-lists) > `:scripts` (§31 multi-call — list-of-lists) > `:script` (§31 single-call — flat list auto-wrapped as `[script]`). Empty opts → synchronous `{:error, script_exhausted_error()}`.
  - Read current call via cursor; if exhausted, synchronous `{:error, script_exhausted_error()}`.
  - If the first entry of the current call is `:preflight_error` (harness-shape pre-flight), synchronous `{:error, AdapterError.new(reason, opts)}` (no stream opened).
  - Otherwise build and return `{:ok, stream}` with `Stream.resource/3`:
    - `start_fun`: emit `:message_started`; return `{entries, %{emitted_text?: false, cleanup_observer: observer, pending_tool_calls: %{}}}`.
    - `next_fun`: pop one entry; for `{:delay, ms}` / `{:sleep, ms}`, `Process.sleep(ms)` and recurse without emitting; for `{:finish, reason}`, emit `:text_completed` (if `emitted_text?`) + `:message_completed`; for every other entry, `Script.interpret(entry)`.
    - `after_fun`: if `observer` is a `:counters` ref, `:counters.add(observer, 1, 1)`.
- [ ] `@impl ALLM.StreamAdapter`, `@spec stream(Request.t(), keyword()) :: ...`.
- [ ] Append `use ALLM.Test.StreamAdapterConformance, stream_adapter: ALLM.Providers.Fake` at the bottom of `test/allm/providers/fake_stream_test.exs`.

#### 4.3.3 Verification

```bash
mix test test/allm/providers/fake_stream_test.exs
mix test --cover
mix dialyzer
mix credo --strict lib/allm/providers/fake.ex
mix format --check-formatted
```

### Sub-phase 4.4: `ALLM.Test.FakeFixtures` — named fixture library (Layer B — test support)

**Goal:** Publish the eight named fixtures the phasing doc enumerates, each returning a ready-to-use `adapter_opts` kwlist. One fixture per §31 property-style scenario Phase 4 can exercise; Phase 5–8 consume these and add more.

**Spec sections:** §31

#### 4.4.1 Test Plan (write first)

`test/allm/providers/fake/fixtures_test.exs` (co-located with other fake tests) OR extend `fake_test.exs` with a `describe "fixtures"` block — pick the former for modularity.

Per fixture:
- `plain_text("hello")` returns an `adapter_opts` that, fed to `generate/2`, produces `%Response{output_text: "hello", finish_reason: :stop}`.
- `plain_text/1` with a multibyte string (e.g., "héllo") produces `%Response{output_text: "héllo"}` unchanged — the fixture does not transform the string.
- `single_tool_call("get_weather", %{city: "B"})` returns `adapter_opts` that produces a response with one `%ToolCall{name: "get_weather", arguments: %{city: "B"}}` and `finish_reason: :tool_calls`.
- `parallel_tool_calls([{"a", %{x: 1}}, {"b", %{y: 2}}])` returns `adapter_opts` for two tool calls emitted in a single assistant turn; `Response.tool_calls` has two entries in order.
- `multi_turn_conversation([[script1], [script2]])` returns `adapter_opts` with a `scripts:` kwlist; sequential calls from the same process advance.
- `mid_stream_error(:rate_limited)` returns `adapter_opts` that, fed to `stream/2`, produces an event stream that terminates with `{:error, %AdapterError{reason: :rate_limited}}`.
- `empty_response()` returns `adapter_opts: [script: []]`.
- `tool_call_with_streamed_args("get_w", ~S({"city":"B"}))` returns `adapter_opts` whose streaming run emits two `:tool_call_delta` events (the JSON split at a codepoint boundary via `String.split_at/2` — NOT a byte boundary, so non-ASCII `arguments_json` never produces mid-codepoint fragments) plus a final `:finish`. The accumulated raw_arguments parses cleanly under `Jason.decode/1` after recombination.
- `delayed_text("hello", 50)` returns `adapter_opts` that emits a text delta after a 50 ms delay.

#### 4.4.2 Implementation Checklist

- [ ] Create `test/support/fake_fixtures.ex` with `@moduledoc`.
- [ ] Implement all eight public functions with `@spec` and `@doc`.
- [ ] Doctest at least one fixture (pick `plain_text/1` — simplest to validate inline).

#### 4.4.3 Verification

```bash
mix test test/allm/providers/fake/fixtures_test.exs
mix dialyzer
mix credo --strict test/support/fake_fixtures.ex
```

### Sub-phase 4.5: Cross-phase §31 scenario tests + conformance wrap-up (Layer B)

**Goal:** Wire the conformance plug-ins (already noted in 4.2/4.3 implementation checklists), and add one additional scenario-level test file that exercises every §31 property-style bullet Phase 4 is positioned to cover. Phases 5–8 will extend this file as their own scenarios come into scope.

**Spec sections:** §31

#### 4.5.1 Test Plan (write first)

`test/allm/providers/fake_scenarios_test.exs` (NEW):

`@moduletag :spec_31` so Phase 12's regression audit can run `mix test --only spec_31` and see every scenario in one place.

- **pure text streaming with `emit_text_deltas: true`** (default): the 5-event stream for `script: [{:text, "he"}, {:text, "llo"}, {:finish, :stop}]`.
- **pure text streaming with `emit_text_deltas: false`** — DEFERRED to Phase 5 where the orchestrator reads the flag; Phase 4 has no `emit_text_deltas` filter. Document the deferral in the test file as a `@tag :pending` placeholder.
- **parallel tool calls in one assistant turn**: a script with two `{:tool_call, ...}` entries followed by `{:finish, :tool_calls}`; streaming run emits two start/completed pairs; non-streaming `generate/2` folds into a `%Response.tool_calls` list of length 2.
- **mid-stream adapter error — stream terminates with `{:error, reason}`**: `[{:text, "h"}, {:error, :rate_limited}]` yields a stream whose last event is `{:error, %AdapterError{reason: :rate_limited}}`.
- **consumer cancellation releases the adapter's HTTP request** — mapped to "cleanup observer fires within 500 ms" for Fake (no real HTTP).
- **`max_turns` cap** — DEFERRED to Phase 7 (Chat).
- **`halt_when` fires** — DEFERRED to Phase 7.
- **tool handler raises — `on_tool_error` policy** — DEFERRED to Phase 7.
- **session round-trip** — DEFERRED to Phase 8.

Phase 4 covers 3 of the 9 §31 scenarios; the rest are transparently deferred via `@tag :pending` placeholders, giving Phase 12's audit a single file to verify against.

#### 4.5.2 Implementation Checklist

- [ ] Create `test/allm/providers/fake_scenarios_test.exs` with `@moduletag :spec_31`.
- [ ] Implement the three Phase-4-coverable scenario tests.
- [ ] Add `@tag :pending` placeholders for the deferred six, each with a one-line comment naming the phase that implements it.
- [ ] Verify: `mix test --only spec_31` runs the passing three and reports six pending.
- [ ] Final `CHANGELOG.md` entries.

#### 4.5.3 Verification

```bash
mix test --only spec_31                               # the three Phase 4 scenarios pass
mix test                                              # full suite still green
mix test --cover                                      # ≥90% on every new file
mix credo --strict
mix dialyzer
mix format --check-formatted
mix hex.build                                         # main package still clean
```

## Test Plan (cross-phase)

**Unit tests.** Every public function on `ALLM.Providers.Fake`, `ALLM.Providers.Fake.Script`, and `ALLM.Test.FakeFixtures` has happy-path + error-path tests. Script-shape detection has one test per tag in each vocabulary plus the `:error` arity disambiguation.

**Behaviour conformance tests.** `use ALLM.Test.AdapterConformance, adapter: ALLM.Providers.Fake` in `fake_test.exs` and `use ALLM.Test.StreamAdapterConformance, stream_adapter: ALLM.Providers.Fake` in `fake_stream_test.exs`. Both harnesses pass unchanged — Fake is the second known-good implementation (first is `StubAdapter` in the `conformance/` package).

**Integration tests.** None in Phase 4 — no Layer C execution functions exist yet. Phase 5's integration tests (`stream_generate → StreamCollector`) will be the first.

**Property tests.** None in Phase 4. Script-shape fold is deterministic; property-style scenarios land in Phase 5 when event sequences are validated through the orchestrator.

**Doctests.** `ALLM.Providers.Fake.generate/2`, `ALLM.Providers.Fake.stream/2`, `ALLM.Providers.Fake.Script.detect_shape/1`, `ALLM.Providers.Fake.Script.fold_to_response/1`, `ALLM.Test.FakeFixtures.plain_text/1` each carry a runnable doctest.

**Serializability tests.** `ALLM.Providers.Fake` does not ship Layer A struct changes. Indirect: `adapter_opts: [script: [{:text, "hi"}]]` in an engine must survive `:erlang.term_to_binary/1` round-trip — tested in `fake_test.exs` as a paranoia guard (the engine is unchanged from Phase 2; this is a regression test for anyone who might later add a PID to `adapter_opts`).

**Stream-equivalence tests.** Phase 4 does not ship a non-streaming wrapper of `stream/2` at the Fake level (no `Fake.generate/2 ≡ Fake.stream/2 |> collect`); `fold_to_response/1` reducer and `interpret/1` → `Stream.resource/3` are independent code paths that could drift. A targeted property test asserts equivalence: for any `[spec31_entry]` without `{:delay, _}` / `{:sleep, _}` / `{:raw_chunk, _}`, `fold_to_response(entries)` equals `entries |> Enum.flat_map(&interpret/1) |> collect_to_response()` where `collect_to_response/1` is a test-only helper that mirrors Phase 5's `StreamCollector`. This isolates any divergence in Phase 4 itself rather than deferring it to Phase 5.

**Coverage threshold.** `mix.exs` configures 80 % globally. Phase 4 targets ≥90 % on `lib/allm/providers/fake.ex`, `lib/allm/providers/fake/script.ex`, and `test/support/fake_fixtures.ex`. Branch coverage on `Script.detect_shape/1`'s tag table is the key risk — each tag has at least one detection test.

## Error Contract

| Function | Error reason | Recovery guidance |
|----------|--------------|--------------------|
| `ALLM.Providers.Fake.generate/2` | `%AdapterError{reason: :no_scripted_response}` | Scripted call budget exhausted. Caller bug: add more inner lists to `scripts:` or bound the orchestration loop with `max_turns`. |
| `ALLM.Providers.Fake.generate/2` | `%AdapterError{reason: :unknown, cause: term}` | §31-shape `{:error, term}` entry was reduced. `cause` preserves the original term for test assertions. |
| `ALLM.Providers.Fake.generate/2` | `%AdapterError{reason: <harness-reason>}` | Harness-shape `{:error, reason, opts}` entry — orchestrator applies normal retry/telemetry paths per Phase 9. |
| `ALLM.Providers.Fake.stream/2` | `%AdapterError{reason: <harness-reason>}` (synchronous) | `:preflight_error` entry — the stream never starts; orchestrator surfaces this as it would a real 401/403. |
| `ALLM.Providers.Fake.stream/2` stream event | `%AdapterError{reason: <reason>}` | Mid-stream HTTP-shaped error. Orchestrator halts the current step. |
| `ALLM.Providers.Fake.stream/2` stream event | `%StreamError{reason: :cancelled \| :timeout \| …}` | Mid-stream transport-shaped error. Orchestrator halts the current step. |
| `ALLM.Providers.Fake.Script.validate!/1` | `ArgumentError` | Programmer error in test setup (mixed `:script` + `:scripts`, non-list `:script`, non-pid `:script_cursor`). Not recoverable — fix the test. |

**Field-error atom vocabulary:** not applicable — Phase 4 ships no validator-shaped module.

**Hard-reject semantics:** not applicable.

**One new atom introduced via Phase 1 amendment.** `:no_scripted_response` is added to `ALLM.Error.AdapterError.@legal_reasons` (and the `t:reason/0` union) as the 12th reason atom — scoped to testing adapters (Fake), never produced by OpenAI / Anthropic / any production adapter. The committed enum at `lib/allm/error/adapter_error.ex:35-46` (verified 2026-04-24) currently holds eleven reasons; Phase 4 extends it to twelve. `%StreamError{}` reasons are unchanged — every reason Fake emits is already in the committed Phase 1 set (`:adapter_error, :cancelled, :timeout, :malformed_event, :unknown` per `lib/allm/error/stream_error.ex:29-35`). Every other `%AdapterError{}` reason Fake produces is already in the committed Phase 1 set.

## Streaming & Backpressure

Fake is the first `StreamAdapter` implementation in the main `allm` package (`StubAdapter` is the first in the `conformance/` package; Fake is the first library-facing one). Its streaming design sets the pattern every real provider adapter (Phase 10 OpenAI, Phase 11 Anthropic) follows.

- **Cleanup is mandatory.** `Stream.resource/3` with a 3-arity `next_fun` and a 1-arity `after_fun`. `after_fun` receives the final accumulator and increments `adapter_opts[:cleanup_observer]` (a `:counters` ref, if present) at index 1. Halt-safety is bounded by `Stream.resource/3`'s synchronous `after_fun` semantics (runs on `{:halt, _}` returns, on consumer early-termination via `Enum.take/2`, and on consumer process exit when the stream is linked).
- **Backpressure model.** Fake has no network buffer; `{:delay, ms}` / `{:sleep, ms}` script entries call `Process.sleep(ms)` inside the `next_fun` to simulate slow providers. The consumer's reduce rate is the only backpressure signal; slow consumers do not accumulate events (the `next_fun` produces on demand).
- **Cancellation.** Consumer halt (`Enum.take(stream, 2)`, `Stream.take_while/2` returning false, `Stream.run/1` with a user `Process.exit/2`) is caught by `Stream.resource/3` and invokes `after_fun` synchronously. The halt-safety conformance case bounds this at ≤500 ms. Fake has no Finch ref or HTTP connection to cancel — the cleanup is purely the observer increment, which is sufficient to prove the contract works; real providers cancel Finch refs in their own `after_fun`.

Fake's `stream/2` does NOT spawn a `Task` or monitor the consumer process. The entire event production is synchronous on the consumer's reduction; there is no producer process to supervise. This is deliberately simpler than the real-provider streaming model (where Finch runs an async producer in a separate process); Fake does not need it because there is no HTTP IO to hide. Phase 10's OpenAI adapter and Phase 11's Anthropic adapter will introduce the `Task`-based producer pattern.

## Definition of Done

- [ ] All five sub-phases marked `Completed` in the status table.
- [ ] `mix test` passes with zero failures, zero `unused_var` warnings; coverage ≥80 % globally and ≥90 % on `lib/allm/providers/fake.ex`, `lib/allm/providers/fake/script.ex`, and `test/support/fake_fixtures.ex`.
- [ ] `mix credo --strict` passes with zero issues on changed files.
- [ ] `mix dialyzer` passes with zero new warnings against the prior PLT.
- [ ] `mix format --check-formatted` passes.
- [ ] Every new public function has an `@spec` and a non-empty `@doc`.
- [ ] Doctests run under `mix test`: `ALLM.Providers.Fake.generate/2`, `ALLM.Providers.Fake.stream/2`, `ALLM.Providers.Fake.Script.detect_shape/1`, `ALLM.Providers.Fake.Script.fold_to_response/1`, `ALLM.Test.FakeFixtures.plain_text/1`.
- [ ] `use ALLM.Test.AdapterConformance, adapter: ALLM.Providers.Fake` in `fake_test.exs` passes the 13 injected cases.
- [ ] `use ALLM.Test.StreamAdapterConformance, stream_adapter: ALLM.Providers.Fake` in `fake_stream_test.exs` passes the 14 injected cases.
- [ ] Halt-safety test passes within the 500 ms ceiling: 10-event script, `Enum.take(stream, 2)`, `:counters.get(ref, 1) == 1` via `eventually/2` polling.
- [ ] Multi-call scripting works with both default (process-dict) cursor and explicit Agent cursor.
- [ ] Mixing `:script` and `:scripts` raises `ArgumentError` at first call (and `ALLM.Providers.Fake.Script.validate!/1` is callable standalone for construction-time checks).
- [ ] `test/allm/providers/fake_scenarios_test.exs` tagged `@moduletag :spec_31` runs three passing cases plus six `@tag :pending` placeholders.
- [ ] `CHANGELOG.md` has one entry per new public module (`ALLM.Providers.Fake`, `ALLM.Providers.Fake.Script`, `ALLM.Test.FakeFixtures`).
- [ ] `mix hex.build` + `mix hex.publish --dry-run` succeed (main package includes the three new `lib/` files; does not include `test/support/fake_fixtures.ex`).
- [ ] Commit messages reference §7.1, §7.2, §8, §20, §30, §31 as appropriate.
- [ ] Reviewed via `/review` per `AGENT_REVIEW_SPEC.md`.
