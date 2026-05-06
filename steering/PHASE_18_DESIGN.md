# Phase 18: Per-tool manual mode — Design Document

> **Goal:** Add a `manual: boolean()` field to `%ALLM.Tool{}` so individual tools opt out of auto-execution under `mode: :auto`. The chat orchestrator partitions a response's tool calls into auto + manual buckets: auto tools run eagerly via the existing `ToolRunner` path, then the loop halts with the existing `:manual_tool_calls` reason, and the manual ones surface in `metadata.manual_tool_calls` (or `pending_tool_calls` on a `%Session{}`).
> **Outcome:** A caller declares `ALLM.tool(name: "charge_card", …, manual: true)`; `ALLM.chat/3` runs auto-bucket tools eagerly and halts on the first turn that hits a manual tool, returning `%ChatResult{halted_reason: :manual_tool_calls, metadata: %{manual_tool_calls: [%ToolCall{}, …]}}` with the auto-bucket tool messages already merged into `result.thread`. Session callers see `status: :awaiting_tools, pending_tool_calls: [<manual ones only>]` and resolve via the existing `submit_tool_result/3` flow. The streaming path emits the same partition: `:tool_execution_*` events fire only for the auto bucket; the trailing `:step_completed` payload carries the new `:manual_tool_calls` key (additive — non-breaking per CLAUDE.md "adding a key to an *existing* event's payload map is NOT breaking"). `mix test`, `mix credo --strict`, `mix dialyzer`, `mix format --check-formatted` all green; coverage ≥ 90 % on every new file. Two new live examples (`14_per_tool_manual.exs`, `15_per_tool_manual_session.exs`) ship under `examples/` and run green against both providers.
> **Spec sections:** §5.2 (Tool struct — field addition), §10.5 (chat halt-reason table — clarification), §12 (manual vs automatic — extends to per-tool), §17 (`ToolRunner` — receives auto bucket only).
> **Layers touched:** A (Tool struct field) + C (chat orchestrator partition) + D (session projection helper). Three layers — split into sub-phases 18.1 (A), 18.2/18.3 (C), 18.4 (D) so each is independently shippable per the AGENT_DESIGN_SPEC "one layer per phase" rule.
> **Phasing doc:** post-v0.3.0; placed after Phase 17 (image layer) per the project's monotonic phase numbering.

## Status

| Sub-phase | Description | Layer | Status |
|-----------|-------------|-------|--------|
| 18.1 | `%ALLM.Tool{manual: boolean()}` field + serialization round-trip + `ALLM.tool/1` pass-through | A | Not Started |
| 18.2 | Non-streaming partition in `ALLM.Chat.do_step/4` (`lib/allm/chat.ex:1029`); `step/3` + `chat/3` halt-reason wiring | C | Not Started |
| 18.3 | Streaming partition mirror in `ALLM.Chat.transition_a_to_b/1` (`lib/allm/chat.ex:1187`); `:step_completed` payload key | C | Not Started |
| 18.4 | `ALLM.Session.manual_tool_calls/1` extension (`lib/allm/session.ex:668-669`) + status-projection table update | D | Not Started |
| 18.5 | Cross-phase: chat-equivalence property updated; spec § amendments; `examples/14_*` + `examples/15_*`; CHANGELOG | C/D | Not Started |

**Overall Progress:** 0/5 sub-phases complete

## Overview

Today, `:mode` is per-call and whole-batch: passing `mode: :manual` halts on the first `:tool_calls` response and surfaces every tool call for caller submission. Real applications usually want a split — let `get_weather` and `lookup_user` auto-run for low-stakes reads, but require a human-confirmation hop before `charge_card`, `send_email`, `delete_account`. Today there's no clean way: callers either flip the entire engine to `mode: :manual` and lose auto-execution for everything, or write a custom `ALLM.ToolExecutor` module that switches on `tool.name`.

Phase 18 makes per-tool manual a first-class concept by adding a single boolean to `%ALLM.Tool{}` and partitioning at one place — `ALLM.Chat.do_step/4` (non-streaming) and its streaming sibling `transition_a_to_b/1`. The partition has three cases per response:

1. **Pure auto bucket** — every called tool has `manual: false`. Existing `run_tools_non_streaming/4` path runs verbatim; zero behavior change for current users.
2. **Pure manual bucket** — every called tool has `manual: true`. Equivalent to today's whole-loop `mode: :manual` for this turn: the assistant message is appended, no tools run, the step halts with `:manual_tool_calls`.
3. **Mixed bucket** — auto tools run eagerly (via the existing `ToolRunner.run_tool_calls/3` / `stream_tool_calls/3` path on the auto subset only), then the step halts with `:manual_tool_calls` and the *manual* tool calls in `metadata.manual_tool_calls`. The thread on the returned `%StepResult{}` / `%ChatResult{}` already carries the auto bucket's `:tool` messages — only the manual ones are pending.

The phase reuses the existing `:manual_tool_calls` halt reason rather than introducing a new atom. Today that atom fires only when `mode: :manual`; after Phase 18 it also fires when `mode: :auto` AND any called tool was per-tool-manual. Distinguishing the two cases is downstream-observable: the existing whole-loop path leaves `metadata.mode == :manual` (set in `lib/allm/chat.ex:1043`); the per-tool path leaves `metadata.manual_tool_calls` (a list) and does NOT set `metadata.mode` to `:manual`. Consumers that only need "tool calls await caller resolution" don't have to distinguish; consumers that need to distinguish (e.g., for telemetry) read either key.

### Dispatch propagation chain (load-bearing)

The `:manual_tool_calls` halt has FOUR dispatch sites that must all recognize the per-tool path. Today only the whole-loop `metadata.mode == :manual` route is wired; Phase 18 extends each:

| Site | File:line | Today's clause | Phase 18 addition |
|------|-----------|----------------|-------------------|
| 1. Loop halt detector | `lib/allm/chat.ex:943` `terminal_condition/5` | `sr.metadata[:mode] == :manual -> {:halt, :manual_tool_calls, %{manual_turn_index: idx}}` | New clause BEFORE the `:mode` clause: `is_list(sr.metadata[:manual_tool_calls]) and sr.metadata.manual_tool_calls != [] -> {:halt, :manual_tool_calls, %{manual_turn_index: idx, manual_tool_calls: sr.metadata.manual_tool_calls}}`. The halt-metadata's third tuple element flows to `ChatResult.metadata` via `build_chat_result/1`. |
| 2. ChatResult metadata propagation | `lib/allm/chat.ex:911` `build_chat_result/1` | `metadata: state.halt_metadata` (whatever `terminal_condition/5` returned) | UNCHANGED — site 1's halt-tuple change suffices. The `manual_tool_calls` key flows in via `state.halt_metadata` automatically. |
| 3. StreamCollector fold | `lib/allm/stream_collector.ex` `apply_event/2` `:step_completed` clause | extracts `Map.get(payload, :mode, :auto)` onto `step_result.metadata` | Add: extract `Map.get(payload, :manual_tool_calls, [])` and merge onto `step_result.metadata` IFF non-empty — empty list MUST NOT overwrite the absence-of-key state, so chat-equivalence holds for pure-auto turns. |
| 4. Session classify_step | `lib/allm/session.ex:703` `classify_step/1` | `meta[:mode] == :manual and response.finish_reason == :tool_calls -> :manual_tool_calls` | New clause BEFORE: `is_list(meta[:manual_tool_calls]) and meta.manual_tool_calls != [] -> :manual_tool_calls`. Routes per-tool path through `step_manual/2` (site 5). |
| 5. Session step_manual | `lib/allm/session.ex:730` `step_manual/2` | `pending_tool_calls: response.tool_calls \|\| []` | Read `meta[:manual_tool_calls]` first, fall back to `response.tool_calls`. |
| 6. Session apply_chat_result manual lifter | `lib/allm/session.ex:646` call site `manual_tool_calls(cr.final_response)` | helper inspects a `%Response{}`-shaped map | Change call site to `manual_tool_calls(cr)`; helper's first clause matches `%ChatResult{metadata: %{manual_tool_calls: tcs}}`, second matches `%ChatResult{final_response: %{tool_calls: tcs}}`. The helper now takes a `%ChatResult{}`, not a `%Response{}`. |

All six sites are listed in the Module Tree as `(MODIFY)` and enumerated as discrete bullets in the Implementation Checklist of their respective sub-phases. AGENT_DESIGN_SPEC checklist item 14 (Layer-C reducer-touch enumeration) is satisfied — every site that absorbs the new metadata key is named.

### Why reuse `:manual_tool_calls` and not introduce `:partial_manual`?

Closed-union halt-reason consumers — pattern-matching on `cr.halted_reason` — break under additive changes. The existing `:manual_tool_calls` already means "loop halted, caller must resolve tool calls before resuming"; that's the same semantic Phase 18 needs. A new atom would force every existing consumer (Session projection, examples scripts, downstream library callers) to update their case statements without any new information being conveyed. The "was this whole-loop or per-tool?" distinction lives in `metadata`, where additive keys are non-breaking. See Decision #1 below.

### Layer demonstration

**Layer A — Tool struct:**

```elixir
charge =
  ALLM.tool(
    name: "charge_card",
    description: "Charge a credit card",
    schema: %{"type" => "object", "properties" => %{"amount" => %{"type" => "integer"}}},
    handler: fn _args -> {:ok, "ok"} end,
    manual: true
  )

charge.manual
# => true

# Round-trips through ETF and JSON unchanged.
^charge = charge |> :erlang.term_to_binary() |> :erlang.binary_to_term()
```

**Layer C — Stateless chat with mixed bucket:**

```elixir
engine = ALLM.Engine.new(adapter: ALLM.Providers.OpenAI, tools: [weather, charge])
{:ok, result} = ALLM.chat(engine, [ALLM.user("Charge $20 if it's sunny in Boston.")])

result.halted_reason
# => :manual_tool_calls

result.metadata.manual_tool_calls
# => [%ALLM.ToolCall{id: "c1", name: "charge_card", arguments: %{"amount" => 20}}]

# weather already ran; its result is in result.thread
Enum.count(result.thread.messages, &(&1.role == :tool))
# => 1
```

**Layer C — Streaming with mixed bucket:**

```elixir
{:ok, stream} = ALLM.stream(engine, [ALLM.user("Charge $20 if sunny in Boston.")])

events = Enum.to_list(stream)

# :tool_execution_started fires only for `weather` (auto), not for `charge_card` (manual).
Enum.count(events, &match?({:tool_execution_started, _}, &1))
# => 1

# :step_completed payload now carries :manual_tool_calls.
[{:step_completed, sc_payload} | _] = Enum.filter(events, &match?({:step_completed, _}, &1))
sc_payload.manual_tool_calls
# => [%ALLM.ToolCall{name: "charge_card", …}]

# The trailing :chat_completed.result agrees with the non-streaming `chat/3` result.
[{:chat_completed, %{result: cr}}] = Enum.filter(events, &match?({:chat_completed, _}, &1))
cr.halted_reason
# => :manual_tool_calls
```

**Layer D — Session manual cycle (uses existing `submit_tool_result/3`):**

```elixir
{:ok, session, _} = ALLM.Session.start(engine, [ALLM.user("Charge $20 if sunny in Boston.")])

session.status
# => :awaiting_tools

session.pending_tool_calls
# => [%ALLM.ToolCall{name: "charge_card", …}]   # NOT weather — that already ran

# Caller approves out-of-band, submits the result, drives the next turn.
session = ALLM.Session.submit_tool_result(session, "c1", %{status: "approved", txn_id: "tx_42"})
session.status
# => :idle

{:ok, session, _} = ALLM.Session.continue(engine, session, nil)
session.status
# => :completed
```

### Deliverables

- **Modified Layer A:**
  - `lib/allm/tool.ex` — add `manual: boolean()` field with default `false`. Update `@type t`, `defstruct`, `__from_tagged__/1`. No change to `new/1` (struct field with default is keyword pass-through). `@enforce_keys` stays at `[:name, :description, :schema]` — manual remains optional.
- **Modified Layer C:**
  - `lib/allm/chat.ex` — extend `do_step/4` (`chat.ex:1029`) and `transition_a_to_b/1` (`chat.ex:1187`) with the partition. Add private helpers `partition_tool_calls/2` and `manual_step_metadata/1`. The existing `mode: :manual` whole-loop path (`{:manual, :tool_calls}` in `do_step/4`, `chat.ex:1184` in the streaming path) is unchanged — it short-circuits *before* the partition runs.
- **Modified Layer D:**
  - `lib/allm/session.ex` — extend `manual_tool_calls/1` (`session.ex:668-669`) to read `metadata.manual_tool_calls` first, falling back to `response.tool_calls` for backwards compatibility with the whole-loop path. Update `step_manual/2` (`session.ex:730`) similarly. No new public function.
- **Modified facade:**
  - `lib/allm.ex` — `chat/3` `@doc` halt-reason table (currently at `lib/allm.ex:466`) updates the `:manual_tool_calls` row prose. No `@spec` change.
- **New tests:**
  - `test/allm/tool_test.exs` — extend with `:manual` field tests (default false, ETF/JSON round-trip, both true and false values).
  - `test/allm/chat/per_tool_manual_test.exs` (NEW) — non-streaming partition coverage (5 cells in the matrix below).
  - `test/allm/chat/per_tool_manual_stream_test.exs` (NEW) — streaming partition coverage (5 cells).
  - `test/allm/session_per_tool_manual_test.exs` (NEW) — Session projection coverage (3 cells: pure-auto unchanged, pure-manual unchanged, mixed lifts only manual).
  - `test/allm/chat_equivalence_test.exs` (MODIFY) — extend property test fixtures with mixed-manual cases; relaxation budget unchanged.
- **New examples:**
  - `examples/14_per_tool_manual.exs` (NEW) — `chat/3` mixed-bucket smoke against both providers.
  - `examples/15_per_tool_manual_session.exs` (NEW) — `Session.start → submit_tool_result → continue` flow.
- **Spec amendment:**
  - `steering/allm_engine_session_streaming_spec_v0_2.md` §5.2 (Tool struct) — add `manual: boolean()` field with default `false`.
  - §10.5 (chat halt-reasons) — clarify `:manual_tool_calls` fires under both whole-loop and per-tool conditions.
  - §12 (manual vs automatic) — add subsection §12.4 "Per-tool manual" describing the partition.
  - §17 (`ToolRunner`) — clarify the runner receives the auto bucket only; partition lives in `ALLM.Chat`.
- **CHANGELOG.md** — three bullets: `[FEAT] %ALLM.Tool{manual: boolean}` on the data side, `[FEAT] ALLM.chat/3` mixed-bucket partition on the orchestration side, `[DOC] §5.2/§10.5/§12/§17 amendments` on the spec side.

### Spec coverage

| Spec § | Phase 18 implements |
|--------|--------------------|
| §5.2 (Tool struct) | Add `:manual` field, default `false`. Field is Layer A serializable (boolean). |
| §10.5 (`chat/3` halt-reasons) | `:manual_tool_calls` row clarified — fires under whole-loop OR per-tool conditions. |
| §12 (manual vs automatic) | New subsection §12.4 documents the per-tool partition; §12.1/§12.2 unchanged. |
| §17 (`ToolRunner`) | Clarify `run_tool_calls/3` and `stream_tool_calls/3` receive only the auto bucket — partition is upstream in `ALLM.Chat`. |

### Prerequisites

- v0.3.0 codebase at HEAD (commit `a7b934b` or later). No earlier-phase preconditions beyond what already shipped.
- Phase 6 (`ALLM.ToolRunner`), Phase 7 (`ALLM.Chat.run/3`, `Chat.stream/3`, `:manual_tool_calls` halt reason), Phase 8 (`ALLM.Session.submit_tool_result/3`, `apply_chat_result/2`) — all shipped.
- No real-provider work required; the partition is provider-agnostic. Live `examples/` smoke runs use existing OpenAI + Anthropic adapters.

### Out of scope

- **Per-tool `:on_manual` callback** (e.g., side-effect hook fired when a manual tool is hit). YAGNI for v0.4 — telemetry handlers can subscribe to `:step_completed` and read `payload.manual_tool_calls`. *Justification:* the boolean covers the canonical case; a callback adds runtime evaluation cost AND a non-serializable surface to the engine.
- **Conditional manual** (`manual: fn args -> boolean end`). Cleaner alternative: have the handler return `{:halt, :requires_confirmation, args}` per-call (already supported by spec §5.2). *Justification:* the static boolean covers the common case; a function field on `%Tool{}` would not survive `:erlang.term_to_binary/1`-via-JSON round-trip and contradicts §5.7's serializability invariant for tools-on-engine.
- **Per-call manual tool list** (e.g., `chat/3, manual_tools: ["charge_card"]`). Defer until a real caller needs to override the engine-level declaration. *Justification:* the engine-level declaration is what most apps want; per-call override is solvable today by constructing a per-call engine.
- **New halt reason `:partial_manual`**. *Justification:* see Decision #1 below — additive metadata key suffices and is backwards-compatible for closed-`case`-on-halted_reason consumers.
- **New event tag `:tool_skipped_manual`**. *Justification:* adding a new event variant is breaking for any reducer pattern-matching closed on the union (per CLAUDE.md "Adding a variant is breaking for reducers"). The mixed-bucket case is fully observable from the existing `:step_completed` payload's new `:manual_tool_calls` key.
- **`ALLM.Validate.tool/1` warnings** for tools with `handler: nil, manual: false` (today routes to `:not_found` via the executor). *Justification:* warning emission is a separate concern; the existing `%ToolError{reason: :not_found}` path is documented at `lib/allm/tool_executor.ex:72` and routes via `:on_tool_error` predictably. Phase 18 doesn't change that path.
- **Synthetic tool opt-in.** The Anthropic structured-output tool-forcing pattern (`respond_with_json_*`, `lib/allm/providers/anthropic.ex`) ALWAYS sets `manual: false` regardless of caller config. The synthetic tool is library-internal; callers should not be able to mark it manual. *Justification:* documented as an explicit comment at the synthetic-tool construction site; not a configurable surface.

### Non-obvious decisions

1. **Reuse `:manual_tool_calls` halt reason; do not introduce `:partial_manual`.** Closed-`case` consumers on `halted_reason` would break under a new atom. The "was this whole-loop or per-tool?" question lives in `metadata` (`metadata.mode == :manual` for whole-loop; `metadata.manual_tool_calls` is a list for per-tool). Additive metadata keys are non-breaking. *Docs target:* `@doc ALLM.chat/3` halt-reason table at `lib/allm.ex:466`; spec §10.5.

2. **Partition is in `ALLM.Chat`, not in `ALLM.ToolRunner`.** The runner stays "execute these tool calls"; the orchestration decision (which to execute) is upstream. This keeps the runner's contract closed (input list → output messages or events) and avoids feeding the runner a partial subset that would change its `tool_calls` order tracking. The runner sees only the auto bucket; it never knows the manual ones existed. *Docs target:* `@doc false` on `partition_tool_calls/2`; spec §17 amendment.

3. **Run auto tools BEFORE the halt, not after.** The model committed to those calls. Deferring auto execution until after a manual round-trip would add latency without changing semantics. Streaming UX wins (`:tool_execution_*` events fire live for the cheap auto bucket). *Docs target:* `@doc ALLM.chat/3` "mixed bucket" paragraph; spec §12.4.

4. **Mixed-bucket thread shape: auto results merged in; manual ones pending.** The returned `result.thread.messages` includes the assistant message AND the auto bucket's `:tool` messages — but NOT placeholder messages for the manual ones. This means the thread is *intentionally not well-formed for an immediate next turn* (it has assistant tool_calls without matching `:tool` messages for the manual ids). The caller MUST submit `:tool` messages for the manual ones before re-issuing `chat/3` / `Session.continue/3`. The Session API enforces this via `pending_tool_calls`; raw `chat/3` callers see `metadata.manual_tool_calls` and append `:tool` messages by hand. **This is a footgun for raw `chat/3` callers** — naively re-issuing `chat/3` on `result.thread` without first appending tool-result messages for the manual ids will send a malformed request to the provider (assistant tool_call IDs without matching tool results), surfacing as a `%AdapterError{reason: :invalid_request}`. The `@doc` for `chat/3` MUST carry an explicit warning paragraph titled "Mixed-bucket re-issue" with a worked example showing the required tool-message append. The 18.2 test plan includes a "naive re-issue surfaces a clear validator error" test asserting the failure mode is detectable. *Docs target:* `@doc ALLM.chat/3`; spec §12.4 worked example.

5. **`mode: :manual` (whole-loop) still wins when set.** When `mode: :manual` is passed at the call site, the existing whole-loop short-circuit fires *before* the partition runs (`do_step/4` `{:manual, :tool_calls}` clause at `chat.ex:1034`). The `:manual` flag on individual tools is irrelevant under `mode: :manual`. *Justification:* preserves existing behavior for callers using whole-loop manual; the per-tool flag is additive opt-in for `mode: :auto` callers. *Docs target:* `@doc ALLM.tool/1`; spec §12.4 ("interaction with `:mode`").

6. **Unknown-tool calls go to the auto bucket.** A `%ToolCall{}` whose name doesn't appear in `engine.tools` is routed via the existing `preflight_unknown_tools/2` (`lib/allm/tool_runner.ex:202`) error path. Sending it through the partition first would let `partition_tool_calls/2` inspect a nil tool and either crash or default to auto/manual — both wrong. The partition matches each `%ToolCall{}` against the resolved tools list and assigns unknown names to the auto bucket so `preflight_unknown_tools/2` fires the existing `%EngineError{reason: :unknown_tool}` exactly as today. *Docs target:* `@doc false` on `partition_tool_calls/2`.

7. **`:step_completed` payload gets `:manual_tool_calls` as a NEW key, not as a constructor arg change.** Per CLAUDE.md "adding a key to an *existing* event's payload map is NOT breaking (pattern-matching on payload keys is non-exhaustive)." The constructor in `lib/allm/event.ex` `step_completed/2` and `step_completed/3` (existing arities) gain a fourth optional argument `manual_tool_calls \\ []`. Existing call sites that pass two or three args continue to compile and produce a payload with `manual_tool_calls: []`. *Docs target:* `@doc ALLM.Event.step_completed/4`; spec §8 "Event protocol" amendment.

8. **Session: `manual_tool_calls/1` reads from `%ChatResult{}`, not `%Response{}`.** The existing helper at `lib/allm/session.ex:668-669` is called with `cr.final_response` (a `%Response{}`) at `session.ex:646`. The metadata key Phase 18 introduces lives on `cr.metadata`, NOT `cr.final_response.metadata` — so the existing call site routes to the wrong struct. *What the implementation does to maintain this:* (a) change the call site at `session.ex:646` from `manual_tool_calls(cr.final_response)` to `manual_tool_calls(cr)`; (b) helper becomes 3 clauses — `defp manual_tool_calls(%ChatResult{metadata: %{manual_tool_calls: tcs}}) when is_list(tcs) and tcs != [], do: tcs` first (matches the per-tool path), `defp manual_tool_calls(%ChatResult{final_response: %{tool_calls: tcs}}) when is_list(tcs), do: tcs` second (matches the whole-loop path verbatim), then catch-all returning `[]`. The empty-list guard on the metadata clause prevents the per-tool clause from masking a whole-loop result that happens to carry `manual_tool_calls: []` from a future code path. The 3-clause function is at `lib/allm/session.ex:668-669` (extended); `step_manual/2` at `session.ex:730` gets the analogous 2-clause shape (read `meta[:manual_tool_calls]` first, fall back to `response.tool_calls`).

11. **`terminal_condition/5` and `classify_step/1` get NEW clauses BEFORE the existing `:mode` clauses.** Today's halt detection at `chat.ex:943` and Session classification at `session.ex:703` only recognize `metadata[:mode] == :manual` as the per-call manual path. The per-tool path does NOT set `metadata.mode == :manual` (per Decision #1 — the two paths must be distinguishable). Without a new clause that recognizes `metadata[:manual_tool_calls]` as a halt trigger, the per-tool path's `%StepResult{}` flows through `terminal_condition/5` as `:continue`, the loop runs another adapter turn with a malformed thread (assistant tool_calls without matching `:tool` messages for the manual ids), and the provider rejects it. *What the implementation does to maintain this:* clause-ordering rule — the new `is_list(metadata[:manual_tool_calls]) and metadata.manual_tool_calls != []` clause is inserted BEFORE the existing `metadata[:mode] == :manual` clause at `chat.ex:943` AND at `session.ex:703`. Mutual exclusion is maintained because the partition path NEVER sets `metadata.mode == :manual` (verified: only `lib/allm/chat.ex:1043` writes `mode: :manual` to step metadata, and that line is in the unchanged whole-loop short-circuit).

12. **`StreamCollector.apply_event/2` MUST extract `payload.manual_tool_calls`.** Without this, the streaming arm produces a `%StepResult{}` with `metadata.manual_tool_calls` absent — the chat-equivalence property (`assertions.ex:90` `assert a.metadata == b.metadata`) breaks immediately. *What the implementation does to maintain this:* the `:step_completed` clause in `StreamCollector.apply_event/2` adds `Map.get(payload, :manual_tool_calls, [])` extraction; merges onto `step_result.metadata` as `manual_tool_calls: list` IFF the list is non-empty (empty list is the absence-of-key default — merging it would diverge from the non-streaming arm which only sets the key when the partition produces a non-empty bucket). Sub-phase 18.3 implementation checklist commits to this fold extension explicitly, not hedge-worded.

13. **`mode: :manual` whole-loop wins; per-tool flag is silent under whole-loop.** *What the implementation does to maintain this:* `do_step/4` at `chat.ex:1029-1061`'s top-level `case` matches `{:manual, :tool_calls}` BEFORE the `{:auto, :tool_calls}` arm. The partition is invoked only inside the `:auto` arm. Verified at `chat.ex:1034` (whole-loop short-circuit position) and `chat.ex:1187` (streaming counterpart, `cond` clause ordering).

14. **`preflight_unknown_tools/2` runs BEFORE partition at the chat layer in BOTH paths.** The streaming path already does this at `chat.ex:1231` (`preflight_unknown(response.tool_calls, tools)`). The non-streaming path delegates preflight to `ToolRunner.run_tool_calls/3` (`tool_runner.ex:202`) — Phase 18 ADDS an explicit chat-layer preflight in `do_step/4`'s `{:auto, :tool_calls}` arm BEFORE `partition_tool_calls/2`. *What the implementation does to maintain this:* sub-phase 18.2 implementation checklist adds a bullet: "in `do_step/4`'s `{:auto, :tool_calls}` arm, call `preflight_unknown_tools(response.tool_calls, tools)` BEFORE `partition_tool_calls/2`; on `{:error, _}` short-circuit with the engine error verbatim." The runner's internal preflight at `tool_runner.ex:202` becomes defense-in-depth (it sees only the auto subset, but never observes an unknown name because the chat-layer preflight short-circuited). Decision #6 ("unknown tools to auto bucket") is now redundant but kept as a safety net — the partition can run on a list that's already passed preflight, so it never sees an unknown name.

9. **Chat-equivalence property: relaxation budget unchanged.** The `chat ≡ stream |> to_chat_result` property must continue to hold across mixed-bucket inputs. Phase 7's `assert_equivalent_chat_result/2` already strips `metadata.mode` divergence; Phase 18 adds `metadata.manual_tool_calls` as a *non-relaxed* assertion (both arms must produce the same list in the same order). *What the implementation does to maintain this:* both arms compute the partition via the same `partition_tool_calls/2` helper called from the shared `Chat.build_chat_result/1` stage; the order is deterministic (input order from `response.tool_calls`). Relaxation table row is added in 18.5; type is `tolerable` (deterministic).

10. **`ToolRunner.preflight_unknown_tools/2` runs against the FULL list, not the auto subset.** If the model calls four tools and one name is unknown, the entire turn must error with `:unknown_tool` — partition or no partition. The `partition_tool_calls/2` helper runs AFTER `preflight_unknown_tools/2`, so unknown-tool errors surface with the same shape as today. *Docs target:* `@doc false` on `partition_tool_calls/2` ("preflight first; partition second").

## Behaviour & Type Contracts

### `ALLM.Tool` (Layer A)

```elixir
defmodule ALLM.Tool do
  @type schema :: map()

  @type handler_result ::
          {:ok, term()}
          | {:error, term()}
          | {:ask_user, String.t()}
          | {:ask_user, String.t(), keyword()}
          | {:halt, atom(), term()}

  @type handler ::
          (map() -> handler_result())
          | (map(), keyword() -> handler_result())

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          schema: schema(),
          handler: handler() | nil,
          manual: boolean(),
          metadata: map()
        }

  @enforce_keys [:name, :description, :schema]
  defstruct [:name, :description, :schema, :handler, manual: false, metadata: %{}]

  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data) when is_map(data) do
    %__MODULE__{
      name: data["name"],
      description: data["description"],
      schema: data["schema"] || %{},
      handler: data["handler"],
      manual: data["manual"] || false,
      metadata: data["metadata"] || %{}
    }
  end
end
```

**Invariants:**

- `manual` is a `boolean()` (no `nil`, no other shapes). `__from_tagged__/1` coerces missing/null to `false`.
- ETF round-trip: `tool == tool |> :erlang.term_to_binary() |> :erlang.binary_to_term()` for any `tool` constructed via `new/1` (verified per §31 Layer A property).
- JSON round-trip: `tool == tool |> Jason.encode!() |> Jason.decode!() |> ALLM.Serializer.from_json!()` (verified per §31; the `Serializer` re-hydrates via `__from_tagged__/1`).
- `manual: true` does NOT require `handler: nil`; a tool may carry both. The chat orchestrator never invokes the handler when `manual: true` is observed in the partition.

### `ALLM.Chat` partition contract (Layer C, internal)

```elixir
# Private helper — not part of the public API.
@spec partition_tool_calls([ToolCall.t()], [Tool.t()]) :: {[ToolCall.t()], [ToolCall.t()]}
defp partition_tool_calls(tool_calls, tools) do
  tool_index = Map.new(tools, fn %Tool{name: n} = t -> {n, t} end)

  Enum.reduce(tool_calls, {[], []}, fn %ToolCall{name: name} = tc, {auto, manual} ->
    case Map.get(tool_index, name) do
      %Tool{manual: true} -> {auto, [tc | manual]}
      _other              -> {[tc | auto], manual}   # unknown OR manual: false
    end
  end)
  |> then(fn {auto, manual} -> {Enum.reverse(auto), Enum.reverse(manual)} end)
end
```

**Invariants:**

- Input order preserved within each bucket (the `Enum.reverse/1` call restores it after the prepend).
- The union of auto + manual equals the input set (`length(auto) + length(manual) == length(tool_calls)`).
- Unknown-tool calls (no matching `%Tool{}` in `tools`) go to the auto bucket — `preflight_unknown_tools/2` fires the existing error path on the auto subset and the partition's manual bucket is unaffected.
- Empty input returns `{[], []}` (no `Enum.reverse/1` cost on empty lists).

### `ALLM.Chat.do_step/4` extension (non-streaming)

The existing function at `lib/allm/chat.ex:1029-1061` gains a new `case` arm:

```elixir
defp do_step(%Engine{} = engine, thread, %Response{} = response, opts) do
  mode = Keyword.get(opts, :mode, :auto)
  assistant_msg = build_assistant_message(response)

  case {mode, response.finish_reason} do
    {:manual, :tool_calls} ->
      # UNCHANGED — existing whole-loop short-circuit at chat.ex:1034.
      ...

    {:auto, :tool_calls} ->
      tools = Engine.resolve_tools(engine, opts)

      case partition_tool_calls(response.tool_calls, tools) do
        {_auto, []} ->
          # Pure auto — UNCHANGED path at chat.ex:1046-1047.
          run_tools_non_streaming(engine, thread, assistant_msg, response, opts)

        {[], manual_tcs} ->
          # Pure manual — equivalent to whole-loop manual for THIS turn.
          {:ok, manual_only_step_result(thread, assistant_msg, response, manual_tcs)}

        {auto_tcs, manual_tcs} ->
          # Mixed — run auto, halt with manual pending.
          run_tools_then_halt(engine, thread, assistant_msg, response, auto_tcs, manual_tcs, opts)
      end

    {_mode, _other} ->
      # UNCHANGED — terminal step at chat.ex:1049-1059.
      ...
  end
end
```

**Invariants:**

- The `{:manual, :tool_calls}` clause runs FIRST and is unchanged — `mode: :manual` always wins per Decision #5.
- `partition_tool_calls/2` runs only inside the `{:auto, :tool_calls}` arm.
- The pure-auto sub-arm (`{_auto, []}`) is byte-identical to the existing path at `lib/allm/chat.ex:1046-1047` — zero behavior change for callers without per-tool manual flags.
- The pure-manual sub-arm produces a `%StepResult{}` with `done?: false`, `metadata: %{manual_tool_calls: manual_tcs}`, and `tool_results: []`. The `:mode` key is NOT set (distinguishes from the whole-loop path per Decision #1).
- The mixed sub-arm runs auto tools via the existing `run_tools_non_streaming/4` (same `Engine.resolve_tools/2`, same `build_runner_opts/3`, same `ToolRunner.run_tool_calls/3`) on the auto subset only, then merges the result with `metadata.manual_tool_calls: manual_tcs`.

### `ALLM.Chat.transition_a_to_b/1` extension (streaming)

The streaming sibling at `lib/allm/chat.ex:1177-1219` gains the same partition. The existing `cond` keeps the `mode == :manual` short-circuit verbatim and adds a partition step inside the `mode == :auto and response.finish_reason == :tool_calls and response.tool_calls != []` arm:

```elixir
defp transition_a_to_b(%{collector: collector, engine: engine, opts: opts} = data) do
  response = ...   # unchanged
  assistant_msg = build_assistant_message(response)
  mode = Keyword.get(opts, :mode, :auto)

  cond do
    mode == :manual and response.finish_reason == :tool_calls ->
      # UNCHANGED — chat.ex:1187-1199.
      ...

    mode == :auto and response.finish_reason == :tool_calls and response.tool_calls != [] ->
      tools = Engine.resolve_tools(engine, opts)

      case partition_tool_calls(response.tool_calls, tools) do
        {_auto, []} ->
          start_phase_b(data, response, assistant_msg)   # UNCHANGED — chat.ex:1202.

        {[], manual_tcs} ->
          start_phase_c_manual_only(data, response, assistant_msg, manual_tcs)

        {auto_tcs, manual_tcs} ->
          start_phase_b_partial(data, response, assistant_msg, auto_tcs, manual_tcs)
      end

    true ->
      # UNCHANGED — terminal adapter finish.
      ...
  end
end
```

**Invariants:**

- `start_phase_b_partial/4` is identical to `start_phase_b/3` except it passes `auto_tcs` (not `response.tool_calls`) to `ToolRunner.stream_tool_calls/3` AND threads `manual_tcs` through the phase data so the eventual `:step_completed` event carries it.
- `start_phase_c_manual_only/4` skips Phase B entirely (no tool execution events) and emits `:step_completed` with `manual_tool_calls: manual_tcs` directly.
- The `:tool_execution_started` / `:tool_execution_completed` / `:tool_result_encoded` events fire ONLY for the auto bucket. There is no `:tool_skipped_manual` event (out of scope per Decision #1's reasoning + AGENT_DESIGN_SPEC "Adding a new variant to a closed tagged-tuple union is a breaking change").
- The trailing `:step_completed` event payload carries `:manual_tool_calls: list(ToolCall.t())` (empty list when no manual tools were called this turn — additive key, default empty).

### `ALLM.Event.step_completed/4` (extended arity)

```elixir
@spec step_completed(Response.t(), Thread.t()) :: t()
def step_completed(response, thread), do: step_completed(response, thread, :auto, [])

@spec step_completed(Response.t(), Thread.t(), :auto | :manual) :: t()
def step_completed(response, thread, mode), do: step_completed(response, thread, mode, [])

@spec step_completed(Response.t(), Thread.t(), :auto | :manual, [ToolCall.t()]) :: t()
def step_completed(%Response{} = response, %Thread{} = thread, mode, manual_tcs)
    when mode in [:auto, :manual] and is_list(manual_tcs) do
  {:step_completed, %{response: response, thread: thread, mode: mode, manual_tool_calls: manual_tcs}}
end
```

**Invariants:**

- Existing arities `/2` and `/3` continue to work unchanged. The 4-arity form is the new constructor; the older arities forward with `manual_tool_calls: []`.
- The payload always carries the `:manual_tool_calls` key (empty list when not applicable). Pattern-matching on `%{manual_tool_calls: tcs}` is non-exhaustive on the payload, so this is safe additively per CLAUDE.md "adding a key to an *existing* event's payload map is NOT breaking".
- `manual_tool_calls` is a list of `%ToolCall{}` — the partition's manual bucket. Not a list of names; not a list of ids.

### `ALLM.Session.manual_tool_calls/1` extension (Layer D, internal)

The existing private function at `lib/allm/session.ex:668-669`:

```elixir
defp manual_tool_calls(%{tool_calls: tcs}) when is_list(tcs), do: tcs
defp manual_tool_calls(_), do: []
```

is invoked at `session.ex:646` as `manual_tool_calls(cr.final_response)` — passing a `%Response{}`, not a `%ChatResult{}`. Phase 18's metadata key lives on `cr.metadata`, NOT `cr.final_response.metadata`, so the call site MUST be updated alongside the helper:

```elixir
# session.ex:646 (call site change):
tool_calls = manual_tool_calls(cr)   # was: manual_tool_calls(cr.final_response)

# session.ex:668-669 (helper extension — now takes %ChatResult{}):
# Phase 18 — per-tool manual: prefer metadata.manual_tool_calls (the partition
# path's bucket) over response.tool_calls (the whole-loop path's full list).
defp manual_tool_calls(%ChatResult{metadata: %{manual_tool_calls: tcs}})
     when is_list(tcs) and tcs != [],
     do: tcs

defp manual_tool_calls(%ChatResult{final_response: %{tool_calls: tcs}}) when is_list(tcs),
  do: tcs

defp manual_tool_calls(_), do: []
```

The empty-list guard (`tcs != []`) on the first clause prevents a future `metadata.manual_tool_calls: []` write (e.g., from a defensively-merged StreamCollector fold) from masking the whole-loop fallback. Without the guard, a whole-loop manual turn whose StreamCollector incorrectly wrote `manual_tool_calls: []` would short-circuit to `[]` instead of falling through to `final_response.tool_calls`.

`step_manual/2` at `session.ex:730` gets the analogous 2-clause shape, reading `sr.metadata[:manual_tool_calls]` first when non-empty, falling back to `sr.response.tool_calls || []`.

**Invariants:**

- Whole-loop callers (today's `mode: :manual`) get the same list as before — they hit the `final_response.tool_calls` clause because the partition path doesn't set `metadata.manual_tool_calls`.
- Per-tool callers get only the manual bucket — they hit the `metadata.manual_tool_calls` clause first.
- Both clauses are mutually exclusive at the call site: the partition path NEVER also populates `metadata.mode == :manual` per Decision #1.

### `ALLM.Chat.terminal_condition/5` extension (Layer C, internal)

Today's halt detector at `chat.ex:938-948`:

```elixir
cond do
  ...
  sr.metadata[:mode] == :manual -> {:halt, :manual_tool_calls, %{manual_turn_index: step_index}}
  ...
end
```

gains a new clause inserted BEFORE the `:mode` clause:

```elixir
cond do
  ...
  is_list(sr.metadata[:manual_tool_calls]) and sr.metadata.manual_tool_calls != [] ->
    {:halt, :manual_tool_calls, %{
      manual_turn_index: step_index,
      manual_tool_calls: sr.metadata.manual_tool_calls
    }}

  sr.metadata[:mode] == :manual ->
    {:halt, :manual_tool_calls, %{manual_turn_index: step_index}}
  ...
end
```

The halt-tuple's third element flows to `ChatResult.metadata` via `build_chat_result/1` at `chat.ex:911` (existing — sets `metadata: state.halt_metadata`). No change to `build_chat_result/1` is required; the new clause's halt-tuple is sufficient.

**Invariants:**

- New clause's `is_list/1 + != []` guard prevents an empty-list write (defensive — partition produces non-empty manual buckets only when at least one tool was flagged manual).
- Clause-ordering: per-tool path FIRST. The whole-loop `:mode` clause stays in place; both clauses produce `halted_reason: :manual_tool_calls` but with different metadata shapes (whole-loop: `manual_turn_index` only; per-tool: adds `manual_tool_calls`).

### Test-observable claims

| Claim | Verification |
|-------|--------------|
| `%ALLM.Tool{manual: false}` is the default when `:manual` is omitted from `new/1` | Verified against `lib/allm/tool.ex` after the field addition; doctest. |
| `%ALLM.Tool{}` round-trips through `:erlang.term_to_binary/1` with `:manual` preserved | Verified by §31 Layer A property test extension. |
| `lib/allm/chat.ex:1029` is the non-streaming dispatch ladder entry | Verified against committed source on date 2026-05-01 (commit `a7b934b`). |
| `lib/allm/chat.ex:1187` is the streaming partition site | Verified against committed source on date 2026-05-01. |
| `lib/allm/session.ex:668-669` is the existing `manual_tool_calls/1` helper | Verified against committed source on date 2026-05-01. |
| `lib/allm/tool.ex:41` is the `defstruct` for `%ALLM.Tool{}` | Verified against committed source on date 2026-05-01. |
| `:manual_tool_calls` is the existing closed-enum halt-reason for whole-loop manual | Verified against `lib/allm/chat_result.ex:23-30` `@type halted_reason` (atom() tail; `:ask_user`, `:max_turns`, `:halt_when`, `:tool_error`, `:cancelled`, `:completed`, plus open `atom()`). `:manual_tool_calls` is documented in the halt-reason table at `lib/allm.ex:466` and surfaces from `lib/allm/chat.ex:943`. |
| `metadata.manual_tool_calls: list(ToolCall.t())` is a NEW key not previously written by any code path | Verified by `git grep 'manual_tool_calls' lib/` (returns only the moduledoc reference at `lib/allm.ex:466` and the existing helper at `session.ex:668`). |
| Adding a key to a `:step_completed` payload is non-breaking | Per CLAUDE.md line 19 "adding a key to an *existing* event's payload map is NOT breaking". |

## Module Tree

```
lib/allm/
├── tool.ex                              (MODIFY — 18.1, add :manual field + __from_tagged__ clause)
├── chat.ex                              (MODIFY — 18.2/18.3, partition + do_step/4 + transition_a_to_b/1 + terminal_condition/5 clause + chat-layer preflight before partition)
├── event.ex                             (MODIFY — 18.3, step_completed/4 arity addition + @type t :step_completed payload extension)
├── stream_collector.ex                  (MODIFY — 18.3, apply_event/2 :step_completed clause lifts payload.manual_tool_calls onto step_result.metadata when non-empty)
├── session.ex                           (MODIFY — 18.4, manual_tool_calls/1 takes %ChatResult{} + call site at :646 updated + classify_step/1 new clause + step_manual/2 extension)
├── allm.ex                              (MODIFY — 18.5, halt-reason table @doc update for chat/3)
└── providers/
    └── anthropic.ex                     (MODIFY — 18.5, comment-only: synthetic structured-output tool stays manual: false)

test/allm/
├── tool_test.exs                        (MODIFY — 18.1, add :manual field tests)
├── chat/
│   ├── per_tool_manual_test.exs         (NEW — 18.2, non-streaming partition matrix)
│   └── per_tool_manual_stream_test.exs  (NEW — 18.3, streaming partition matrix)
├── session_per_tool_manual_test.exs     (NEW — 18.4, Session projection)
├── chat_equivalence_test.exs            (MODIFY — 18.5, extend property fixtures with mixed-manual cases)
└── event_test.exs                       (MODIFY — 18.3, step_completed/4 arity tests)

test/support/
└── fake_fixtures.ex                     (MODIFY — 18.2/18.3, add `mixed_manual/2` fixture)

examples/
├── 14_per_tool_manual.exs               (NEW — 18.5, chat/3 mixed-bucket smoke)
├── 15_per_tool_manual_session.exs       (NEW — 18.5, Session.start → submit → continue)
└── README.md                            (MODIFY — 18.5, append two rows to the script table)

steering/
└── allm_engine_session_streaming_spec_v0_2.md  (MODIFY — 18.5, §5.2 + §10.5 + §12 + §17)

CHANGELOG.md                             (MODIFY — 18.5, three bullets)
```

**Path-existence check:** `ls test/allm/chat/` exists (committed Phase 7 directory). `ls test/support/` exists. `ls examples/run_all.exs` exists at HEAD (the dual-provider live-validation orchestrator). `ls examples/` exists with 13 numbered scripts at HEAD; 14 and 15 are next.

**Module Tree completeness:** 14 entries; expected `git diff --stat` count of 14 ± 1 (CHANGELOG is the typical off-by-one — counted here).

## Phases

### Phase 18.1: `%ALLM.Tool{manual: boolean()}` (Layer A)

**Goal:** Add the `:manual` field with default `false` and verify ETF + JSON round-trip preservation.

**Spec sections:** §5.2 (Tool struct).

#### 18.1.1 Test Plan (write first)

`test/allm/tool_test.exs` (MODIFY):

- `Tool.new/1 with manual: true sets the field`
- `Tool.new/1 without manual defaults to false`
- `Tool.new/1 with manual: nil raises ArgumentError` (rejects non-boolean — verified via `struct!/2` semantics)
- `Tool struct round-trips through :erlang.term_to_binary/1 preserving :manual`
- `Tool struct round-trips through Jason.encode!/1 → Serializer.from_json!/1 preserving :manual`
- `Tool.__from_tagged__/1 with missing "manual" key returns manual: false`
- `Tool.__from_tagged__/1 with explicit "manual": null returns manual: false`
- `Tool.__from_tagged__/1 with "manual": true returns manual: true`

#### 18.1.2 Implementation Checklist

- [ ] Add `manual: false` to `defstruct` at `lib/allm/tool.ex:41`
- [ ] Add `manual: boolean()` to `@type t` at `lib/allm/tool.ex:32-38`
- [ ] Update `__from_tagged__/1` to read `data["manual"] || false`
- [ ] Update `@moduledoc` to mention `manual: true` semantics ("declares this tool will not be auto-executed by `ALLM.chat/3`; the loop halts with `:manual_tool_calls` and the caller resolves the tool result via `submit_tool_result/3` or by appending a `:tool` message and re-issuing `chat/3`")
- [ ] Verify `ALLM.tool/1` (`lib/allm.ex:128-129`) passes `:manual` through to `Tool.new/1` — no change required since it's keyword forwarding
- [ ] Update `ALLM.Engine` `@moduledoc` (`lib/allm/engine.ex:34`) bullet about `:tools` to mention the new field

#### 18.1.3 Verification

```bash
mix test test/allm/tool_test.exs
mix test                              # full suite (existing tests must still pass — :manual default false preserves behavior)
mix credo --strict lib/allm/tool.ex
mix dialyzer
mix format --check-formatted
```

### Phase 18.2: Non-streaming partition (Layer C)

**Goal:** Extend `ALLM.Chat.do_step/4` to partition tool calls by `tool.manual` under `mode: :auto` and produce a `%StepResult{metadata: %{manual_tool_calls: [...]}}` for the pure-manual and mixed sub-cases.

**Spec sections:** §10.5 (chat halt-reasons), §12 (manual vs auto).

#### 18.2.1 Test Plan (write first)

`test/allm/chat/per_tool_manual_test.exs` (NEW). The five-cell matrix:

| Cell | mode | tools (manual flags) | response.tool_calls | Expected behavior |
|------|------|----------------------|---------------------|-------------------|
| 1 | `:auto` | all `manual: false` | 1 call | Existing path; `metadata.manual_tool_calls` absent |
| 2 | `:auto` | mixed | 2 calls (1 auto + 1 manual) | Auto runs eagerly; halt with `manual_tool_calls: [<manual one>]` |
| 3 | `:auto` | all `manual: true` | 1 call | Pure-manual halt; `metadata.manual_tool_calls: [<call>]`; no tool executed |
| 4 | `:manual` | mixed | 2 calls | Whole-loop wins (Decision #5); `metadata.mode: :manual`; ALL calls surfaced |
| 5 | `:manual` | all `manual: false` | 1 call | Existing whole-loop path verbatim |

Plus error-path tests:

- `partition with unknown-tool name routes through preflight_unknown_tools/2 unchanged` — error returned, no partition observation.
- `partition with empty response.tool_calls is a no-op` — falls through to terminal step.
- `multi-turn chat: turn 1 mixed-bucket halts; caller appends :tool message for manual id; turn 2 chat/3 with augmented thread completes` — end-to-end smoke for the mixed-bucket flow.
- `mixed-bucket footgun: naive re-issue of chat/3 on result.thread without appending tool messages for manual ids surfaces a Validate.thread/1 error or a clear AdapterError` — asserts the malformed-thread failure mode is detectable rather than silent. (Per Decision #4 — this is the load-bearing UX guard for raw `chat/3` callers.)

`test/allm/chat_equivalence_test.exs` (MODIFY): add a property-test fixture exercising mixed manual/auto across multi-turn scripts; assert chat-equivalence (handled in 18.5).

#### 18.2.2 Implementation Checklist

- [ ] Add `partition_tool_calls/2` private helper to `lib/allm/chat.ex` (placed near `do_step/4`)
- [ ] Add chat-layer `preflight_unknown_tools/2` invocation in `do_step/4`'s `{:auto, :tool_calls}` arm BEFORE `partition_tool_calls/2`; mirror the streaming path's existing preflight at `chat.ex:1231` (Decision #14)
- [ ] Extend `do_step/4` with the partition arm under `{:auto, :tool_calls}` per the contract above
- [ ] Add `manual_only_step_result/4` and `run_tools_then_halt/7` helpers
- [ ] Wire `metadata.manual_tool_calls` onto the `%StepResult{}` for both pure-manual and mixed sub-arms
- [ ] **Add new clause to `terminal_condition/5` at `chat.ex:943` BEFORE the `metadata[:mode] == :manual` clause**: `is_list(sr.metadata[:manual_tool_calls]) and sr.metadata.manual_tool_calls != [] -> {:halt, :manual_tool_calls, %{manual_turn_index: idx, manual_tool_calls: sr.metadata.manual_tool_calls}}`. The halt-tuple's third element flows to `ChatResult.metadata` via existing `build_chat_result/1` (no change needed there). Per Decision #11.
- [ ] Update `lib/allm.ex` `chat/3` halt-reason table at line 466 — `:manual_tool_calls` row prose: "Fires when `mode: :manual` and step's `response.finish_reason == :tool_calls`, OR when any called tool has `manual: true` (Phase 18). `metadata` carries `manual_tool_calls: [%ToolCall{}, …]` (the manual bucket)."
- [ ] Verify the existing `:manual_tool_calls` whole-loop tests still pass (no behavior change for that path) — clause ordering matters: per-tool clause is FIRST so it doesn't intercept whole-loop turns (whole-loop turns never set `metadata.manual_tool_calls`, so the new clause's guard is `false` and falls through).

#### 18.2.3 Verification

```bash
mix test test/allm/chat/per_tool_manual_test.exs
mix test test/allm/chat_test.exs       # existing tests must still pass
mix test                                # full suite
mix credo --strict lib/allm/chat.ex
mix dialyzer
```

### Phase 18.3: Streaming partition + `:step_completed` payload key (Layer C)

**Goal:** Extend `ALLM.Chat.transition_a_to_b/1` to mirror the non-streaming partition. Add `:manual_tool_calls` to the `:step_completed` event payload (additive, default empty list).

**Spec sections:** §8 (event protocol — additive payload key), §10.6 (`stream/3`), §13.1 (`StreamCollector`).

#### 18.3.1 Test Plan (write first)

`test/allm/chat/per_tool_manual_stream_test.exs` (NEW) — same five-cell matrix as 18.2 against `ALLM.Chat.stream/3`:

| Cell | Expected stream observations |
|------|------------------------------|
| 1 | `:tool_execution_started`/`:tool_execution_completed` fire for the call; `:step_completed.manual_tool_calls == []` |
| 2 | `:tool_execution_*` fires only for the auto call; `:step_completed.manual_tool_calls` is `[<manual call>]` |
| 3 | NO `:tool_execution_*` events; `:step_completed.manual_tool_calls` is `[<call>]` |
| 4 | NO `:tool_execution_*`; `:step_completed.mode == :manual`; `:step_completed.manual_tool_calls == []` |
| 5 | UNCHANGED — existing whole-loop streaming tests pass |

Plus:

- `Event.step_completed/2 produces a payload with manual_tool_calls: []` (backwards-compat — existing call sites)
- `Event.step_completed/3 produces a payload with manual_tool_calls: []`
- `Event.step_completed/4 with explicit list propagates the list to payload.manual_tool_calls`
- `chat-equivalence: chat/3 ≡ stream/3 |> StreamCollector.to_chat_result/1 for every mixed-manual scripted input` (folds into 18.5's relaxation budget — `:manual_tool_calls` is a non-relaxed field)
- `:tool_execution_started events fire ONLY for the auto bucket` — explicit count assertion

#### 18.3.2 Implementation Checklist

- [ ] Extend `Event.step_completed/2` and `/3` in `lib/allm/event.ex` to forward to a new `/4` arity with `manual_tool_calls: []` default
- [ ] Add `step_completed/4` arity with `@spec` and `@doc` covering the new key
- [ ] Update the `@type t` for `:step_completed` in `lib/allm/event.ex` to include `manual_tool_calls: [ToolCall.t()]` in the payload type
- [ ] Add `partition_tool_calls/2` invocation inside `transition_a_to_b/1` per the contract above (already authored as a private helper in 18.2 — reuse)
- [ ] Add `start_phase_b_partial/4` and `start_phase_c_manual_only/4` helpers. **`start_phase_c_manual_only/4` MUST call `Thread.add_message(data.thread, assistant_msg)` before constructing `phase_c_data`** — mirrors the existing whole-loop manual branch at `chat.ex:1191` so the assistant message with tool_calls remains in the thread.
- [ ] Thread `manual_tool_calls` through THREE state-shape sites: (a) `phase_b_data` at `chat.ex:1236-1245` adds a `:manual_tcs` field; (b) `transition_b_to_c/1` at `chat.ex:1397-1421` reads `phase_b_data.manual_tcs` and writes it into `phase_c_data`; (c) `emit_step_completed/1` at `chat.ex:1425` constructs `Event.step_completed(response, thread, mode, manual_tcs)` using the new `/4` arity. Per Decision #7 (AGENT_DESIGN_SPEC item 14 reducer-touch enumeration).
- [ ] **Update `StreamCollector.apply_event/2`** (`lib/allm/stream_collector.ex`) — `:step_completed` clause adds `Map.get(payload, :manual_tool_calls, [])` extraction; merges onto `step_result.metadata` IFF the list is non-empty (empty-list-is-absence per Decision #12). This is a BLOCKING requirement for chat-equivalence — without it, the streaming arm's `step_result.metadata` lacks the key and `assert a.metadata == b.metadata` (`test/support/assertions.ex:90`) breaks immediately.
- [ ] Verify `:on_event` callbacks see the new payload key via the existing pass-through

#### 18.3.3 Verification

```bash
mix test test/allm/chat/per_tool_manual_stream_test.exs
mix test test/allm/event_test.exs
mix test test/allm/stream_collector_test.exs
mix test                                # full suite
mix credo --strict lib/allm/chat.ex lib/allm/event.ex
mix dialyzer
```

### Phase 18.4: Session projection (Layer D)

**Goal:** Extend `ALLM.Session.manual_tool_calls/1` and `step_manual/2` to read `metadata.manual_tool_calls` first; fall back to `response.tool_calls` for whole-loop compatibility.

**Spec sections:** §11 (Session API — internal helper change; no public surface change).

#### 18.4.1 Test Plan (write first)

`test/allm/session_per_tool_manual_test.exs` (NEW):

- `Session.start/3 with mode: :auto and a manual tool call halts at status: :awaiting_tools with pending_tool_calls populated from the metadata bucket`
- `Session.start/3 with mode: :auto and only auto tool calls completes normally (status: :completed)`
- `Session.start/3 with mode: :manual and per-tool flags ignores the per-tool flags (whole-loop wins per Decision #5); pending_tool_calls populated from response.tool_calls (full list)`
- `Session.start/3 with mode: :auto, mixed bucket: pending_tool_calls is the manual subset only; thread already carries auto tool messages`
- `Session.submit_tool_result/3 against the manual subset flips status to :idle when last submitted; subsequent continue/3 drives the next adapter turn`
- `Session.submit_tool_result/3 with an AUTO-bucket id returns {:error, %SessionError{reason: :unknown_tool_call_id}}` — the auto bucket already ran; its id is not in pending_tool_calls. (Closes the AGENT_DESIGN_SPEC item 12 dispatch-graph reconciliation gap for the continue/submit cycle.)
- `Session.stream_start/3 with mixed bucket: terminal :chat_completed event's result.metadata.manual_tool_calls equals the lifted pending_tool_calls`
- `Session.stream_start/3 with mode: :auto, pure manual: status: :awaiting_tools, no :tool_execution_* events fired`
- `Session.stream_start/3 with mode: :manual, mixed: whole-loop wins; status: :awaiting_tools with FULL response.tool_calls (not the manual subset)`
- Whole-loop turn that synthesizes `metadata.manual_tool_calls: []` (empty list) MUST fall through to `final_response.tool_calls` — guards against the empty-list-write masking the whole-loop fallback (per Decision #8's `tcs != []` guard).

Status-transition matrix coverage (extends Phase 8's matrix at `test/allm/session_status_transition_test.exs`):

| From `:idle` (start) | mode `:auto`, mixed | mode `:auto`, pure manual | mode `:auto`, pure auto | mode `:manual`, any |
|----------------------|---------------------|---------------------------|-------------------------|---------------------|
| To `:awaiting_tools` ✓ | To `:awaiting_tools` ✓ | To `:awaiting_tools` ✓ | To `:completed` ✓ | To `:awaiting_tools` ✓ |

Four cells; each maps to one test row in the new file.

#### 18.4.2 Implementation Checklist

- [ ] **Update call site at `session.ex:646`**: change `manual_tool_calls(cr.final_response)` to `manual_tool_calls(cr)` — the helper now takes a `%ChatResult{}`, not a `%Response{}`. Without this change, the new metadata-clause never matches because `cr.final_response.metadata` doesn't carry the key (it lives on `cr.metadata`).
- [ ] Replace the 2-clause `manual_tool_calls/1` at `lib/allm/session.ex:668-669` with the 3-clause version per the contract above (Decision #8). First clause: `%ChatResult{metadata: %{manual_tool_calls: tcs}}` with `is_list(tcs) and tcs != []` guard. Second clause: `%ChatResult{final_response: %{tool_calls: tcs}}` for whole-loop fallback. Third clause: catch-all returning `[]`.
- [ ] **Add new clause to `classify_step/1` at `session.ex:703` BEFORE the `meta[:mode] == :manual` clause**: `is_list(meta[:manual_tool_calls]) and meta.manual_tool_calls != [] -> :manual_tool_calls`. Per Decision #11 — without this, the per-tool path classifies as `:idle` and `step_manual/2` is never reached.
- [ ] Update `step_manual/2` at `session.ex:730` to read `meta[:manual_tool_calls]` first when non-empty, fall back to `response.tool_calls || []`. The 2-clause shape mirrors the helper.
- [ ] Add a doctest (or moduledoc note) on `ALLM.Session` documenting the per-tool manual semantics — "When `mode: :auto` and any called tool has `manual: true`, `:awaiting_tools` is entered with `pending_tool_calls` containing only the manual subset; auto tools have already executed and their `:tool` messages are in `session.thread`."
- [ ] Verify Phase 8's existing `session_status_transition_test.exs` still passes — the change is a clause addition, not a clause replacement, for `manual_tool_calls/1`. The first new clause's `tcs != []` guard ensures whole-loop turns (which never write `metadata.manual_tool_calls`) fall through unchanged.
- [ ] No new public function on `ALLM.Session`; `submit_tool_result/3` flow works unchanged

#### 18.4.3 Verification

```bash
mix test test/allm/session_per_tool_manual_test.exs
mix test test/allm/session_test.exs
mix test test/allm/session_status_transition_test.exs
mix test                                # full suite
mix credo --strict lib/allm/session.ex
mix dialyzer
```

### Phase 18.5: Chat-equivalence + spec amendments + examples + CHANGELOG

**Goal:** Update the chat-equivalence property to cover mixed-manual fixtures; amend the spec; ship two live examples; update CHANGELOG.

**Spec sections:** §5.2, §10.5, §12, §17.

#### 18.5.1 Test Plan (write first)

`test/allm/chat_equivalence_test.exs` (MODIFY):

- Extend the existing property fixtures with three new scripted scenarios:
  - `mixed_manual_first_turn` — turn 1 has 2 tool calls (1 auto, 1 manual); halts with `:manual_tool_calls`
  - `pure_manual_first_turn` — turn 1 has 1 tool call (manual)
  - `auto_only_no_manual_flags_set` — control case; should be byte-identical pre/post-Phase-18

For each, assert: `chat(engine, msgs, opts) == stream(engine, msgs, opts) |> Enum.to_list() |> StreamCollector.to_chat_result/1` (with the existing relaxation set unchanged).

Relaxation budget table (added to the test file as a comment):

| Field | Relaxation | Justification | Risk |
|-------|------------|---------------|------|
| `metadata.manual_tool_calls` | none — both arms must produce identical lists in identical order | partition is deterministic; same `partition_tool_calls/2` helper called from shared `Chat.build_chat_result/1` | tolerable |
| `metadata.mode` | already relaxed by Phase 7 | unchanged | unchanged |

#### 18.5.2 Spec amendment

In `steering/allm_engine_session_streaming_spec_v0_2.md`:

- §5.2 — add `:manual` field to the Tool struct definition and document semantics ("declares this tool is per-tool manual; the chat orchestrator partitions a turn's tool calls into auto + manual buckets and halts when any manual tool is called"). Cite Phase 18 commit at the inline amendment marker.
- §10.5 — add a sentence to the `chat/3` description noting that `:manual_tool_calls` halt also fires when `mode: :auto` and any called tool has `manual: true`.
- §12 — add subsection §12.4 "Per-tool manual" describing the partition with worked examples for chat/3 and Session.
- §17 — add a sentence clarifying `ToolRunner.run_tool_calls/3` and `stream_tool_calls/3` receive only the auto bucket; partition is upstream in `ALLM.Chat`.

#### 18.5.3 Examples

`examples/14_per_tool_manual.exs` (NEW):

- Steering strategy: tight (system prompt forces both tool calls).
- Two tools: `weather` (auto, deterministic handler returning `{:ok, %{forecast: "sunny", city: "Boston"}}`) and `confirm_action` (manual, no handler).
- `chat/3` call expects `halted_reason: :manual_tool_calls` and `metadata.manual_tool_calls` length 1.
- Caller appends a `:tool` message for `confirm_action`'s id, re-issues `chat/3`, expects `:completed` and final assistant text contains "sunny".
- Provider gate: both OpenAI and Anthropic.

`examples/15_per_tool_manual_session.exs` (NEW):

- Same tools as 14.
- `Session.start → assert :awaiting_tools → submit_tool_result → assert :idle → continue → assert :completed`.
- Provider gate: both OpenAI and Anthropic.

`examples/README.md` — append two table rows.

#### 18.5.4 Implementation Checklist

- [ ] Extend `test/allm/chat_equivalence_test.exs` with three new fixtures
- [ ] Amend `steering/allm_engine_session_streaming_spec_v0_2.md` §5.2, §10.5, §12, §17
- [ ] Author `examples/14_per_tool_manual.exs` and `examples/15_per_tool_manual_session.exs`
- [ ] Update `examples/README.md` script table
- [ ] BLOCKING live-validation: `OPENAI_API_KEY=… mix run examples/run_all.exs` exit 0 AND `ANTHROPIC_API_KEY=… ALLM_PROVIDER=anthropic mix run examples/run_all.exs` exit 0 (per CLAUDE.md "Every bundled provider adapter ships with an examples entry…  the `/review` step BLOCKS on `ALLM_PROVIDER=<name> mix run examples/run_all.exs` exit 0")
- [ ] Capture stdout into `examples/RUN_OUTPUT_OPENAI.md` and `examples/RUN_OUTPUT_ANTHROPIC.md` IFF the live run succeeded (per CLAUDE.md snapshot policy — regen in same commit as the live run, or not at all)
- [ ] Update `CHANGELOG.md` with three bullets under a new `## [Unreleased]` heading

#### 18.5.5 Verification

```bash
mix test                                  # full suite
mix test test/allm/chat_equivalence_test.exs --include property
mix credo --strict
mix dialyzer
mix format --check-formatted
OPENAI_API_KEY=...     mix run examples/run_all.exs
ANTHROPIC_API_KEY=...  ALLM_PROVIDER=anthropic mix run examples/run_all.exs
# Per-clean-run cost projection: ~$0.005 / provider (each example ~$0.001 × 2 scripts × 2-3 turns).
```

## Test Plan (cross-phase summary)

- **Unit tests** — `Tool` struct field round-trip (18.1); partition helper happy paths (18.2); `Event.step_completed/4` (18.3); Session projection (18.4).
- **Behaviour conformance** — none. No behaviour callback signatures change.
- **Integration tests** — `chat/3` mixed-bucket multi-turn (18.2); `stream/3` mixed-bucket multi-turn (18.3); `Session.start → submit_tool_result → continue` mixed-bucket (18.4).
- **Property tests** — chat-equivalence over scripted mixed-manual fixtures (18.5).
- **Doctests** — `@doc Tool.new/1` (the `:manual` keyword), `@doc Event.step_completed/4`, `@doc ALLM.chat/3` halt-reason table.
- **Serializability** — `%Tool{manual: true}` and `%Tool{manual: false}` both round-trip ETF + JSON (18.1).
- **Stream-equivalence** — chat-equivalence property covers the partition (18.5); relaxation budget unchanged from Phase 7.
- **Live examples** — `examples/14_*` + `examples/15_*` against both providers (18.5 BLOCKING).

**Cross-phase × cross-path test matrix** (per AGENT_DESIGN_SPEC checklist item 10):

| Mode × tool flags | Non-streaming `chat/3` | Streaming `stream/3` | Session non-streaming | Session streaming |
|--------------------|-------------------------|----------------------|----------------------|-------------------|
| `:auto`, all auto | Cell 1 (18.2) | Cell 1 (18.3) | covered by 18.4 cell-3 | covered by 18.4 cell-6 |
| `:auto`, mixed | Cell 2 (18.2) | Cell 2 (18.3) | 18.4 cell-1 | 18.4 cell-6 |
| `:auto`, pure manual | Cell 3 (18.2) | Cell 3 (18.3) | 18.4 cell-2 | 18.4 stream cell-1 |
| `:manual`, mixed | Cell 4 (18.2) | Cell 4 (18.3) | 18.4 cell-3 | 18.4 stream cell-2 |
| `:manual`, all auto | Cell 5 (18.2) | Cell 5 (18.3) | covered by Phase 8 existing | covered by Phase 8 existing |

All matrix cells covered — the previous "gap" rows are now bullets in 18.4.1 (`Session.stream_start/3 with mode: :auto, pure manual` and `Session.stream_start/3 with mode: :manual, mixed`).

## Error Contract

Phase 18 introduces zero new error reasons. The partition path reuses:

| Function | Error reason | Recovery guidance |
|----------|--------------|--------------------|
| `chat/3` | `:unknown_tool` (existing) | Engine.tools missing a name in response.tool_calls; same recovery as today (declare the tool or fix the model prompt). |
| `submit_tool_result/3` (existing) | `:unknown_tool_call_id` (existing) | Caller submitted an id not in pending_tool_calls; same recovery as today. |

`metadata.manual_tool_calls` is informational, not an error. The `:manual_tool_calls` halt-reason atom predates Phase 18 (Phase 7).

## Streaming & Backpressure

Phase 18 preserves existing `Stream.resource/3` cleanup invariants. The partition runs synchronously in `transition_a_to_b/1` BEFORE `start_phase_b/3` constructs the `ToolRunner.stream_tool_calls/3` enumerable; cleanup of that enumerable is unchanged from Phase 6/7. No new resource owners.

The pure-manual streaming sub-arm (`start_phase_c_manual_only/4`) skips Phase B entirely — there is no `ToolRunner` enumerable to clean up. Phase C's `:step_completed` event fires immediately and the consumer can halt cleanly.

## Definition of Done

- [ ] All 5 sub-phases marked `Completed`
- [ ] `mix test` zero failures, zero warnings, coverage ≥ 80 % global / ≥ 90 % on new files
- [ ] `mix credo --strict` zero issues on changed files (`lib/allm/tool.ex`, `lib/allm/chat.ex`, `lib/allm/event.ex`, `lib/allm/session.ex`, `lib/allm.ex`)
- [ ] `mix dialyzer` zero new warnings vs. v0.3.0 PLT baseline
- [ ] `mix format --check-formatted` passes
- [ ] Every new public function has `@spec` and `@doc` with at least one runnable doctest (`Event.step_completed/4` carries the doctest; `Tool.new/1` `@doc` mentions `:manual`)
- [ ] `%Tool{}` round-trips ETF + JSON with `:manual` preserved (Phase 18.1 test)
- [ ] Existing whole-loop `mode: :manual` tests pass unchanged
- [ ] Chat-equivalence property passes with mixed-manual fixtures (Phase 18.5)
- [ ] Spec § amendments commit references the Phase 18 commit and cites file:lines
- [ ] CHANGELOG.md updated with three bullets
- [ ] BLOCKING live-validation: `examples/run_all.exs` exit 0 against BOTH providers
- [ ] `examples/RUN_OUTPUT_OPENAI.md` and `examples/RUN_OUTPUT_ANTHROPIC.md` regenerated in the same commit as the live run (per CLAUDE.md snapshot policy)
- [ ] Reviewed via `/review` (see `AGENT_REVIEW_SPEC.md` if present)

## Live-API cost estimation

Per `examples/14_per_tool_manual.exs` + `examples/15_per_tool_manual_session.exs`, both providers, ~3 turns each, ~500 input + ~200 output tokens per turn:

| Provider | Per-script cost | Both scripts | Per-clean-run total | First-implementation (3× retry) |
|----------|-----------------|--------------|---------------------|----------------------------------|
| OpenAI (`gpt-5.4-nano`) | ~$0.001 | ~$0.002 | ~$0.002 | ~$0.008 |
| Anthropic (`claude-sonnet-4-6`) | ~$0.003 | ~$0.006 | ~$0.006 | ~$0.024 |
| **Combined** | — | — | **~$0.008** | **~$0.032** |

Adds ~$0.008 to the dual-provider `/review` pass; cumulative `/review` cost rises from ~$0.13 (v0.3.0) to ~$0.14 per clean run. First-implementation cost uses 4× retry overhead per AGENT_DESIGN_SPEC item 19 (the project's recent worked examples — Phase 10.5 / 11.4 / 17.x — show 3× being optimistic for new orchestration paths).

## Cross-phase consistency check

- Every new event payload key has a reducer case in `StreamCollector.apply_event/2` ✓ (18.3 implementation checklist)
- Every spec § amendment cites a file:line in `lib/` ✓ (Decision text — `lib/allm/chat.ex:1029`, `chat.ex:1187`, `chat.ex:1184`, `lib/allm/session.ex:668-669`, `lib/allm/tool.ex:41`, `lib/allm.ex:466`)
- `@spec` for `partition_tool_calls/2` matches the contract above (18.2 implementation)
- Hedge-word audit on this design — none found (all "should X" claims carry citations or `(verified … 2026-05-01)` annotations; all atom claims cite committed source)
- Test-observable claims table at end of "Behaviour & Type Contracts" verified against committed source on 2026-05-01 (commit `a7b934b`)
