# Design Spec Guidelines — ALLM

How to write design documents for the ALLM Elixir library. The `/design` skill reads this file automatically.

## Project Context

ALLM is a provider-neutral LLM execution library with first-class streaming and serializable conversation state. The canonical spec is `steering/allm_engine_session_streaming_spec_v0_2.md` — design docs **refine** the spec into implementation phases, they don't redefine it. Cite the spec section (`§6.3`, `§12.3`) when a choice is non-obvious.

Concrete application shapes the library must support live in `steering/examples/` (`amesury_example.md`, `garden_example.md`, `meal_example.md`, `unllmtd_example.md`). When choosing ergonomics, walk an example end-to-end: *can a user write this against the API I'm designing without reading the source?*

There is no UI, no database, no service to deploy. Design docs cover **library code**: data structs, behaviours, the engine, stream runners, adapters, session helpers, and the public facade. Anything that crosses the four-layer boundary (see `CLAUDE.md → Architecture in one page`) is a red flag — call it out in the Overview.

## The Four Layers

Every phase declares which layer(s) it touches. The layer dictates testing strategy, serializability constraints, and legal dependency direction:

| Layer | Contents | Constraints |
|-------|----------|-------------|
| **A — Serializable data** | `ALLM.Message`, `ALLM.ToolCall`, `ALLM.Request`, `ALLM.Response`, `ALLM.Thread`, `ALLM.Session`, `ALLM.StepResult`, `ALLM.ChatResult`, `ALLM.Event`, `ALLM.Usage` | Plain structs only. No PIDs, refs, funs, or API keys. Must round-trip `:erlang.term_to_binary/1` and `Jason.encode!/1 |> Jason.decode!/1` (with module hints). Tested in isolation. |
| **B — Runtime** | `ALLM.Engine`, `ALLM.Adapter`, `ALLM.StreamAdapter`, `ALLM.ToolExecutor`, `ALLM.ToolResultEncoder`, `ALLM.Keys` | Carries non-serializable refs (modules, funs, Finch names, key resolvers). API keys resolve at adapter-call time, never at engine construction. Engine itself must be safe to persist (modules + atoms only). |
| **C — Stateless execution** | `ALLM.generate/3`, `ALLM.stream_generate/3`, `ALLM.step/3`, `ALLM.stream_step/3`, `ALLM.chat/3`, `ALLM.stream/3` | Pure dispatch over a supplied engine. No process state. Streaming variants are primitives; non-streaming variants reduce stream events via `ALLM.StreamCollector`. |
| **D — Stateful continuation** | `ALLM.Session.start/3`, `stream_start/3`, `reply/4`, `stream_reply/4`, `step/3`, `stream_step/3` | Operates over a `%ALLM.Session{}`. Returns updated sessions, never mutates. Composes Layer C. |

**A phase touching more than one layer is suspect — split it.** Each layer has its own test strategy and dependency surface; mixing layers in one phase usually means the boundaries are being smuggled across.

## Composability is the Product

Each layer is independently usable:

- A user constructs `%ALLM.Message{}` and `%ALLM.Request{}` without ever calling an adapter (Layer A).
- A user calls `ALLM.generate/3` with engine + request and gets a response — no session machinery (Layer C).
- A user drives a multi-turn `ALLM.Session` and persists between turns (Layer D).
- A user streams events and writes their own reducer instead of using `chat/3` (Layer C streaming primitive).

**Every design must demonstrate this property is preserved.** If a Layer C change requires a Layer D wrapper to be useful, the layer boundary is wrong. Show in the Overview how a hypothetical user consumes the new functionality at *each* layer it touches, with a 3–5 line code snippet per layer.

## Document Structure

### 1. Title & Status Table

```markdown
# Phase N: Title — Design Document

> **Goal:** One-sentence goal
> **Outcome:** What "done" looks like (measurable)
> **Spec sections:** §6.3, §12.3 (every section this phase implements or refines)
> **Layers touched:** A / B / C / D (justify if >1)

## Status

| Phase | Description | Layer | Status |
|-------|-------------|-------|--------|
| 1 | Refactor: extract `ALLM.Internal.Stream` from `Engine` | B | Not Started |
| 2 | `ALLM.Event` closed union + `event?/1` guard | A | Not Started |

**Overall Progress:** 0/N phases complete
```

Valid statuses: `Not Started`, `In Progress`, `Completed`. Update the table and progress every transition.

#### Naming Convention

Designs live under `steering/designs/` as `PHASE_N_<short-slug>.md` continuing project-wide phase numbering. Cross-cutting refactors use `REFACTOR_<short-slug>.md`. Real provider adapters use `PHASE_PROVIDER_<name>.md` (e.g., `PHASE_PROVIDER_OPENAI.md`).

### 2. Overview

3–5 sentence summary of what the design covers and *why now*. Then bullets:

- **Deliverables** — concrete modules, behaviours, structs, public functions added or changed.
- **Spec coverage** — which §-numbered sections are implemented (or refined; refining requires a separate spec PR before approval).
- **Layer demonstration** — for each layer touched, a 3–5 line snippet showing how a user consumes the new functionality at *that* layer alone. Load-bearing proof the boundary is real.
- **Prerequisites** — earlier phases or spec changes required (with file paths).
- **Out of scope** — what's deliberately excluded, with one-line justification each. A missing item reads as oversight; a deliberate exclusion reads as intent.
- **Non-obvious decisions** — choices a future reader would question, each with one-sentence rationale and a `Docs target:` annotation pointing to user-facing documentation. Accepted: `Docs target: @moduledoc <Mod>`, `Docs target: @doc <Mod.fun/arity>`, `Docs target: CHANGELOG entry only`, `Docs target: internal — no user-facing docs needed`. Makes design-rationale → user-docs hand-off explicit.

### 3. Behaviour & Type Contracts

Every design that introduces or modifies a behaviour, struct, or public function defines the contract before any phase. This is the API surface; phases implement against it.

For each module, specify:

- **`@type` definitions** — full typespecs, including closed-union members for tagged tuples.
- **`@callback` definitions** — every callback with `@spec`-style argument and return types.
- **`@spec` for public functions** — argument types, return types, and the **complete** error tuple shape (`{:error, %ALLM.Error.AdapterError{}}`, not `{:error, term()}` — `term()` says the error contract isn't designed).
- **Struct shape** — every field with type, default, and Layer A (serializable) vs B (runtime).
- **Invariants** — properties the type preserves across operations (e.g., "`Session.thread.messages` always ends with `:assistant` or `:tool` after `reply/4`").

Show the contract as Elixir code blocks:

```elixir
# Layer A — serializable
defmodule ALLM.Event do
  @type usage :: %{prompt_tokens: non_neg_integer(), completion_tokens: non_neg_integer()}

  @type t ::
          {:message_start, role :: :assistant}
          | {:content_delta, text :: String.t()}
          | {:tool_call_start, id :: String.t(), name :: String.t()}
          | {:tool_call_arguments_delta, id :: String.t(), json_fragment :: String.t()}
          | {:tool_call_end, id :: String.t()}
          | {:message_end, finish_reason :: :stop | :length | :tool_calls | :content_filter | :error}
          | {:usage, usage()}
          | {:error, %ALLM.Error.StreamError{}}

  @spec event?(term()) :: boolean()
  def event?(value)
end
```

**Contracts must reproduce every test-plan assertion.** If a Test Plan bullet requires a specific Elixir idiom — `@enforce_keys` for `struct!/2` raising on missing fields, `defexception` catch-all for `Exception.message/1` on raw structs, `String.to_existing_atom/1` for atom decode safety, `defimpl` vs. `@derive` for protocol dispatch, `Stream.resource/3` cleanup semantics — name the idiom in Behaviour & Type Contracts. The contract section must be sufficient to reproduce every test-plan assertion without asking the implementer to infer Elixir-stdlib choices. If an implementer has to add `@enforce_keys` or a `message/1` fallback to make Test Plan pass, that's a missing contract, not a deviation.

**Test-observable values must be empirically verified, not recalled.** Any concrete fact about runtime behaviour — the exception a function raises, the atoms a closed enum accepts, the return shape of an opaque stdlib call — is a test-observable. Wrong design forces the implementer to choose between truthful code and faithful-to-design code; both wrong. **Before the design ships, every test-observable claim must carry one of: an `(verified in IEx on <date>)` annotation, a cited file:line reference to committed source, or a quoted stdlib doc snippet.** Memory is not a citation. Five concrete classes:

1. **Stdlib exception shapes.** When a Test Plan asserts a function raises a specific exception module (`ArgumentError`, `Protocol.UndefinedError`, `Jason.EncodeError`, `KeyError`), cite docs or `(verified in IEx on <date>)`. Exception shape varies by input category within the same function — `:erlang.fun_info/2` raises `ArgumentError` on a non-function but `FunctionClauseError` on wrong-arity dispatch.
2. **Project-owned closed atom enumerations.** When referencing atom values from a committed `@type reason :: :foo | :bar | ...` enum, a registry's `@known_modules` list, a tagged-union's variant tags, or a `String.to_existing_atom/1` safelist, cite `file:line` of the committed enum or `(verified against <path> on <date>)`. Don't invent atoms — if missing, the design must explicitly extend the prior phase's enum as a scoped amendment.
3. **Stdlib failure modes on the declared OTP floor.** When asserting `Keyword.fetch!/2`, `Map.fetch!/2`, `:counters.get/2`, `Jason.decode!/1` raise a specific exception on a specific input, run on the project's declared OTP floor (currently OTP 27 per `mix.exs`) and cite. OTP-version-specific behaviour is a test-observable.
4. **Macro-expansion-wrapped stdlib raises.** Exceptions raised inside `quote do…end` or during `Code.compile_quoted/1` / `Code.eval_quoted/2` may or may not be wrapped as `CompileError` depending on the API. If a Test Plan asserts `use MyCaseTemplate` without a required opt raises `CompileError`, run in `iex` first — `Keyword.fetch!/2` at quoted-expansion time often surfaces the underlying `KeyError` unwrapped. Same class as rule 3 with a macro frame in between.
5. **Opaque-term return shapes.** When referencing the return of `:counters.new/2`, `Finch.Conn.*`, `Port.open/2`, `:ets.new/2`, or any stdlib returning an opaque term, inspect on OTP 27 and cite. `:counters.new(1, [:atomics])` does NOT return a bare `reference()` — it returns `{:atomics, #Reference}`. Guards assuming the bare shape silently skip cleanup paths.

**Primitive verification vs. composition verification.** A `(verified in IEx on <date>)` annotation on a single stdlib call is *primitive verification*. When the design composes two or more primitives under constraints that force a specific interaction (`Task.async_stream/5` + `ordered: false` + per-input attribution on timeout; `Stream.resource/3`'s `next_fun` pulling one element from an inner `Enumerable.reduce/3` continuation; `Stream.concat/1` wrapping an already-`Stream.resource/3`-owned enumerable whose cleanup fires once), primitive behaviour in isolation is *necessary but not sufficient*. The implementer discovers composition shape at impl time, often as a tactical deviation. Concrete instances: Phase 6 Batch 1 needed `zip_input_on_exit: true` on `Task.async_stream/5` (verified `{:exit, :timeout}` in isolation; parallel + `ordered: false` forced per-input attribution); Phase 6 Batch 2 needed the `{:suspend, event}` reducer-return idiom to drive a sub-stream one element at a time from inside another resource's `next_fun` (neither `Stream.concat/1` nor `Stream.transform/3` satisfies the state-dependency).

When composing two or more primitives under phase-specific constraints, either (a) write the composition's IEx verification script inline (full multi-primitive call + observed shape), or (b) explicitly enumerate expected composition behaviours as a numbered list the implementer must verify. A bare "`Task.async_stream/5` accepts `ordered: false`" verification on a one-task case does not license a design needing parallel + attribution + timeout + index-based result sorting; the four-constraint interaction is its own test-observable.

**Hedge words are trip-wires — they signal the author didn't verify.** Phrases like `(or the equivalent)`, `or similar`, `or something like that`, `roughly X`, `presumably`, `I think`, `probably`, `should raise` (without citation) embedded in a Test Plan, Non-obvious Decision, or contract prose are inference markers. Before the design ships, each one must be either (a) replaced with an empirical citation per the five classes, or (b) rewritten to drop the specific claim being softened. A design saying "MFA handlers raise `FunctionClauseError` (or the equivalent)" tells the reader "I didn't try it"; the implementer discovers the truth under time pressure. **Equally dangerous: confident-and-wrong assertions without hedges.** Phase 3 Batch 3 shipped `CompileError` with no hedge — author believed it — and was still wrong. Both are pre-landing checklist items: grep for hedge words AND confirm every concrete claim in the five classes carries citation.

**When a design adds a new type to an existing serializer, dispatcher, or registry, the registration is part of the contract.** Behaviour & Type Contracts must name the registration alongside the type — not bury it in a checklist. A reader of §Behaviour & Type Contracts alone must be able to reproduce every Test Plan assertion, including those depending on dispatcher routing (e.g., `ALLM.Serializer`'s `@known_modules`, a future tool-result encoder registry, an atom-keyed type-tag table). If a Test Plan assertion depends on routing-through-registration, the registration update is part of the contract.

**Any struct field typed `keyword()` requires an encoder-side pre-pass to list-of-pairs.** Jason has no `Encoder` impl for raw 2-tuples, so a kwlist encodes as `[[k, v], …]`, not tuples. Either (a) state the transform explicitly in the contract section with a matching `restore_keyword/1` helper call in `__from_tagged__/1`, or (b) preferred — extend the central `Jason.Encoder` helper (`ALLM.Serializer.encode_tagged/2`) to handle kwlists generically and expose the symmetric restore. Don't inline per-field pre-passes if more than one Layer A/B type carries a keyword field.

**Consumer/producer symmetry for filter keys.** When a design introduces a deny-list, allow-list, or any key-based filter partitioning opts between consumers, the contract section names the symmetry invariant: every key consumed by function A must appear in function B's filter (or vice versa). A reader of §Behaviour & Type Contracts alone must be able to derive both (a) the filter's contents and (b) the invariant that filter contents equal the complementary consumer's handled keys. Prevents cross-sub-phase gaps where a filter feels complete against its own prose but omits a key its counterpart handles (Phase 2 Decision #5's `:params` addendum).

**Behaviour design-doc checklist.** Before finalizing a design that introduces a behaviour plus a conformance harness, run these cross-cutting checks:

1. **Every `@callback` traces to a v0.2 user-visible operation.** A callback without a concrete user story is speculation. Cite the `steering/examples/` or spec § that motivates each.
2. **Every behaviour failure mode has a named atom in the design's vocabulary table.** Prevents per-batch atom drift.
3. **The conformance suite calls only through `@callback`s, or any extra `impl` surface is documented in the contract.** Hidden contracts (suites expecting `impl.script/0` or similar introspection) smuggle a second behaviour into the first.
4. **For streaming-adjacent callbacks, the cleanup invariant is part of the contract, not an implementation note.** `Stream.resource/3` cleanup and bounded cancellation time are test-observable per §8 — structural; on the callback, not in prose.
5. **Every reason atom named is verified to exist in the committed closed set of a prior phase.** Open `lib/allm/error/<name>.ex` (or relevant registry/union), read the `@type reason :: ...` enum, confirm every atom in every error-reason table appears. If a needed atom doesn't exist, extend the Phase 1 enum as a scoped amendment — never silently assume.
6. **Cross-function invariants are part of the contract, not just per-function behaviour.** When functions X and Y are such that X's output flows into Y's input or they share a field mapping, name the invariant *between* them. Three concrete shapes: (a) **Mirror file:line citations** — if X "mirrors" Y, cite by absolute path and line range (a bare "mirrors StubAdapter" is drift risk); (b) **State-boundary resolution** — if X has a pure signature but a bullet says "carry state between calls," name which caller owns state and whether X takes-acc-as-arg or is pure-called-from-stateful-context; (c) **Shape-distinguishing invariants** — if X has branches with divergent downstream behaviour (full vs. delta-accumulated tool calls), name what is preserved vs. transformed on close (atom vs. string keys, caller-supplied vs. provider-echoed). Unnamed shape distinctions produce silent correctness bugs.
7. **Conformance-suite case counts are part of the contract.** Add `@case_count N` + `case_count/0` introspection + a meta-test asserting the injected `describe/2` produces exactly `@case_count` `test` cases. Adding a case without bumping the attribute is silent drift; the attribute makes it a loud PR-review signal. The same applies to any matrix the design declares as exhaustive over a closed product set — status × operation, error-reason × recovery-path, status × event-fold-clause. Headcount the matrix programmatically (`length(rows) × length(cols)` minus n/a cells) and reference the same number in the Test Plan and Definition of Done. Hand-tallied headcounts at different design-pass times drift; a programmatic count is a single source of truth. Worked example: PHASE_8_DESIGN said "23 tests" at L750 and "24 rows" at L862 for the same 5×5 status-transition matrix that decomposed into 25 actual tests once sub-cells were split — three different numbers for the same matrix.
8. **When a bullet describes an outcome whose enforcement lives in a specific config line, cite the config file:line.** Examples: "not in the published Hex package" → `mix.exs` `package/files`; "excluded from `mix test` by default" → `test/test_helper.exs` `ExUnit.start(exclude: [...])`; "CI fails on formatting drift" → workflow file:line; "Dialyzer PLT adds `:ex_unit`" → `conformance/mix.exs` `dialyzer: [plt_add_apps: ...]`. A bare outcome claim without a mechanism cite is drift risk — the next config edit silently breaks it.
9. **Contract-flip audit.** When a sub-phase changes a behaviour from "X passes through" to "X is rejected" (or otherwise inverts a prior-phase assertion / mutates a prior-phase no-op), the Implementation Checklist for that sub-phase MUST list "Audit prior-phase tests asserting the inverted behaviour and rename / flip / delete them" as an explicit bullet, citing every affected file:line. Same when a fold clause moves from no-op (catch-all) to mutating: audit every test helper that walked the stream + called `to_X_result/1`. Mechanical: `git grep '<inverted_assertion_substring>\|to_step_result\|to_chat_result\|to_response' test/`. Worked example: PHASE_7_DESIGN sub-phase 7.2's reserved-atom rejection didn't enumerate that Phase 6's `:tool_error accepted` test must be inverted; sub-phase 7.1's `:step_completed` fold reset broke `step_equivalence_test.exs:collect_step_result/2` silently.
10. **Cross-option × cross-path test matrix.** When a phase introduces `f/n` (streaming OR non-streaming) AND a prior phase shipped option set `O = {opt1, opt2, ...}` consumed by `f/n`, the Test Plan MUST include one row per `o ∈ O` for each path. Streaming and non-streaming Test Plans MUST be matrix-identical for option coverage — if `Chat.run/3` tests `on_tool_error: :halt`, `Chat.stream/3` tests it too. Build the matrix as a table; check both paths cover every cell. Missing cells are exactly where composition bugs hide. Worked example: PHASE_7_DESIGN sub-phase 7.4 Test Plan was missing the `on_tool_error: :halt` row that 7.3 had — the resulting `Chat.stream/3 + on_tool_error: :halt` infinite loop only surfaced at the chat-equivalence property test six weeks later.
11. **Cross-layer accept-set reconciliation.** When a public function's `@spec` declares an accept set wider than a downstream consumer's (a validator, an encoder, a serializer the function calls on the way out), the design's contract section must name the boundary transform — either narrow the public spec or surface the encoder explicitly. Worked example: PHASE_8.2's `submit_tool_result/3` accepted `String.t() | map()` per the design but the next-call `Validate.thread/1` rejected map `:content`; the implementer added `Jason.encode!/1` at the submission boundary as a tactical deviation. Same root cause as PHASE_7 batch-4's three masking-divergence relaxations between streaming `StreamCollector` state and non-streaming `StepResult`. The audit is mechanical: for every public `@spec`, walk every internal call the function makes and confirm the next consumer's accept set is no narrower than the public-facing accept set.
12. **Dispatch-graph and matrix-sub-cell reconciliation for state-machine designs.** When one public function delegates to another (sugar functions, `reply ≡ continue`, `start ≡ continue` on a fresh session), expand the precondition matrix to *one row per internal entry point*. Every cell's legality must be consistent across the chain — a cell illegal at the public-facing function but legal at the internal-entry-point function is a contract bug. Same rule applies inside a single function: when a status × operation matrix cell depends on additional arguments beyond (status, op) — message-arg shape, list cardinality, opt presence — expand the matrix to one row per minimum predicate. Labels like "gated," "conditional," or "depends on input" inside a matrix cell are hiding sub-cells. The implementer must be able to derive the legal/illegal predicate from the matrix alone, without reading the error-contract table to discover that "gated" means three different things. Worked examples: PHASE_8's matrix marked `continue/3` on `:awaiting_user` illegal AND specified `reply/4 ≡ continue(...)`; the two are inconsistent — the matrix needed a `(continue/3, :awaiting_user, %Message{role: :user})` cell explicitly legal as the `reply/4`-delegate path. PHASE_8's `(continue/3, :awaiting_tools)` cell labelled "gated" decomposed at impl time into three sub-cells: `(nil, pending == [])` legal, `(nil, pending != [])` illegal, `(%Message{}, _)` illegal.
13. **Every newly-added reason atom in a current-phase enum extension must have at least one named use site in the current phase's pseudocode or contract.** Orphaned atoms are speculative vocabulary; defer until their phase lands. Closed-enum atoms grow easier than they shrink — a consumer pattern-matching on the union breaks if a future phase prunes. Symmetric inverse of rule 5 (every named atom must exist in committed enum) — every newly-added atom must have a current-phase use site. Worked example: PHASE_8.2 added `:invalid_status_for_operation` and `:no_pending_tool_call` to `SessionError`'s enum; both are documented as "reserved for future use" because Decision #7 routed status mismatches to `ArgumentError` after the vocabulary section was finalized. Either prune at design time or attach a use-site comment per atom.

**Adding a new variant to a closed tagged-tuple union is a breaking change for every reducer.** Call this out explicitly in the Overview when it happens.

### 4. Module Tree

A file tree of new and modified files, marked `(NEW)`, `(MODIFY)`, `(DELETE)`:

```
lib/allm/
├── event.ex                          (MODIFY — add :usage variant)
├── engine.ex                         (MODIFY — add :stream_adapter field)
├── stream/
│   ├── runner.ex                     (NEW — Finch streaming + SSE parser)
│   ├── collector.ex                  (NEW — events → ChatResult reducer)
│   └── sse.ex                        (NEW — line-buffered SSE decoder)
├── providers/
│   └── fake.ex                       (MODIFY — implement StreamAdapter)
└── allm.ex                           (MODIFY — wire stream_generate/3)

test/allm/
├── event_test.exs                    (NEW)
├── stream/
│   ├── runner_test.exs               (NEW)
│   ├── collector_test.exs            (NEW)
│   └── sse_test.exs                  (NEW)
├── providers/
│   └── fake_stream_test.exs          (NEW)
└── allm_stream_generate_test.exs     (NEW)

test/support/
└── fake_stream_fixtures.ex           (NEW — scripted event sequences)
```

Test files mirror source 1:1. Test-only fixtures live under `test/support/` (in `elixirc_paths` for `:test`).

### 5. Phases

Break into ordered phases. Each phase **must**:

- Touch a single layer (call it out — A/B/C/D).
- Be independently shippable: after the phase, `mix test`, `mix credo --strict`, and `mix dialyzer` all pass; public API is consistent (no half-defined functions, no callbacks without implementations).
- Have 4–8 checkboxes — split into sub-phases (1.1, 1.2) if larger.
- Begin with **a Test Plan**, not an implementation sketch (TDD).
- End with a **Verification** sub-section listing exact commands.

Build order follows spec §28 progression unless explicitly justified: data structs → engine → behaviours → event → stream runner + Fake → collectors/reducers → streaming APIs → non-streaming wrappers → session helpers → real adapters.

#### Worked phase example

```markdown
## Phase 4: `ALLM.stream_generate/3` over Fake (Layer C)

**Goal:** Expose a streaming generation primitive returning an `Enumerable.t()` of `ALLM.Event` values, driven by an injected `StreamAdapter`.

**Spec sections:** §3, §4, §8

### 4.1 Test Plan (write first)

`test/allm/allm_stream_generate_test.exs` (NEW):

- `stream_generate/3 with a scripted Fake adapter emits the scripted events in order`
- `stream_generate/3 with no events emits message_start + message_end and nothing else`
- `stream_generate/3 with a tool_call sequence emits tool_call_start → arguments_delta+ → tool_call_end`
- `stream_generate/3 surfaces adapter errors as {:error, %ALLM.Error.AdapterError{}} on the stream`
- `stream_generate/3 closes the underlying stream when the consumer halts (e.g., Stream.take/2)`
- `stream_generate/3 returns {:error, %ALLM.Error.EngineError{reason: :no_stream_adapter}} when the engine has no stream adapter`

Property test (`test/allm/allm_stream_generate_property_test.exs`):
- For any scripted sequence of valid events, `stream_generate/3 |> Enum.to_list/1` returns the sequence verbatim.

### 4.2 Implementation Checklist

- [ ] Define `ALLM.Error.EngineError` and `ALLM.Error.AdapterError` (if not already in Phase 1)
- [ ] Implement `ALLM.stream_generate/3` in `lib/allm.ex`, dispatching to `engine.stream_adapter.stream/3`
- [ ] Wire resource cleanup via `Stream.resource/3` so consumer halts close upstream
- [ ] Document with `@doc` including a runnable doctest using `ALLM.Providers.Fake`
- [ ] Add `@spec` matching Behaviour & Type Contracts verbatim

### 4.3 Verification

```bash
mix test test/allm/allm_stream_generate_test.exs
mix test test/allm/allm_stream_generate_property_test.exs
mix test                              # full suite still green
mix credo --strict lib/allm.ex
mix dialyzer
```

The doctest must pass under `mix test`. A user reading `iex> h ALLM.stream_generate` should see a complete worked example using `ALLM.Providers.Fake` — no real provider required.
```

### 6. Test Plan (cross-phase)

Most important section — ALLM is built TDD-first. For every phase, list:

- **Unit tests** (per module) — every public function has at least one happy-path and one error-path test. Tagged-union types have one test per variant.
- **Behaviour conformance tests** — when introducing/modifying a behaviour, a `Behaviour Conformance` module under `test/support/` that any implementation can plug into. `ALLM.Providers.Fake` is the reference; real adapters reuse the same suite.
- **Integration tests** — multi-module flows (e.g., `stream_generate → StreamCollector → generate`). Use `ALLM.Providers.Fake`, never network mocks, except when explicitly testing a real adapter's wire format.
- **Property tests** (`StreamData`) for closed unions, reducers, round-trippable data. §31 scenarios are the floor.
- **Doctests** — every public function in `ALLM`, `ALLM.Session`, and behaviour callbacks has a runnable `@doc` example. Living docs + cheapest smoke test.
- **Serializability tests** (Layer A only) — every Layer A struct round-trips through both `:erlang.term_to_binary/1` and `Jason.encode!/1 |> Jason.decode!/1` (with a custom decoder re-hydrating the struct). Failures here are blocking.
- **Stream-equivalence tests** — for any non-streaming function `f/n` implemented as a reducer over `stream_f/n`, a property asserts `f(args) ≡ stream_f(args) |> StreamCollector.collect/1` for every scripted input.

**Coverage threshold:** `mix.exs` configures 80% via `test_coverage: [summary: [threshold: 80]]`. Designs may not lower this. New code lands at ≥90%; 80% is the global floor, not the per-phase target.

**Stream-equivalence relaxation budget.** Every `non_streaming ≡ streaming |> collect` property MUST list its relaxation set as an explicit table. Each row: relaxation (e.g., `sort :tool messages by tool_call_id`), justification (e.g., `Task.async_stream/5 non-determinism — Phase 6 baseline`), risk (`tolerable` / `masking-divergence`). Adding a `masking-divergence` row to an existing property is a contract change requiring a linked finding/fix in the same batch. Worked example: PHASE_7's `assert_equivalent_chat_result/2` accumulated three masking-divergence relaxations (halt-sentinel strip + `:halt_result` strip + fixture exclusion) silently across batches before retro F5 named them; Phase 7.6 cleanup dropped all three by fixing the underlying StreamCollector / ToolRunner divergences.

**Before flagging a row as `masking-divergence`, the design author must (a) name the specific code path or state-write site where the two arms diverge, citing `file:line` of the divergent helper or fold; and (b) verify empirically (in IEx on a representative fixture, or by reading committed code) that the named mechanism produces observable divergence.** A `masking-divergence` flag without a named mechanism + empirical verification is a hedge at the relaxation-budget granularity and shifts the verification burden to the implementer. If the named mechanism turns out to be no-divergence at impl time, the row drops from the budget and the property asserts unconditionally — but the design author owns the empirical step, not the implementer. Worked example: PHASE_8's `:metadata` row was flagged `masking-divergence` while §Overview L42 simultaneously stated equivalence-by-construction via `Session.apply_chat_result/2` reuse; the contradiction wasn't caught until impl time, when the implementer empirically confirmed no divergence and shipped without either candidate fix.

### 7. Error Contract

Errors are first-class data, not strings. Every public function that can fail returns `{:error, %ALLM.Error.XError{}}` where `XError` has at minimum:

- `:reason` — atom, drawn from a documented closed set per error type (`:rate_limited`, `:authentication_failed`, `:invalid_request`, `:provider_unavailable`, `:context_length_exceeded`)
- `:message` — human-readable, never includes secrets
- `:provider` — `nil` for engine-level errors, the provider atom otherwise
- `:cause` — underlying exception or term, for debugging; never displayed to users

Every phase introducing a new error path lists:

| Function | Error reason | Recovery guidance |
|----------|--------------|--------------------|
| `stream_generate/3` | `:no_stream_adapter` | Caller passed engine without `:stream_adapter`; recoverable by passing one. |
| `stream_generate/3` | `:authentication_failed` | Key resolver returned no key or provider rejected; surface to user, no retry. |
| `stream_generate/3` | `:rate_limited` | Provider 429; caller may retry with backoff (engine `:retry_policy` if configured). |

`{:error, term()}` in `@spec` is a code smell saying the error contract isn't designed.

### Field-error atom vocabulary

For validator-shaped modules (`ALLM.Validate`, future `ALLM.Serializer.from_json/2`-style decoders), include an **exhaustive** field-error vocabulary table. One row per `{field_path, reason_atom}`:

| Field path | Reason atom | Hard-reject? | Fires when |
|------------|-------------|--------------|------------|
| `[:messages]` | `:empty` | no | request has zero messages |
| `[:tools, idx, :name]` | `:duplicate_name` | no | two tools share a `name` |
| `[:content]` | `:image_part` | **yes** | content list contains an image part (§33) |

Exhaustive means the implementer should never have to invent an atom. If a rule produces an error whose atom isn't in the table, that's a design gap — add the row before implementation.

### Hard-reject semantics

Validators accumulate per-field errors by default (fold over input, return all issues in one `%ValidationError{errors: […]}`). A specific error opts into **hard-reject** — short-circuit, return only that error — when remaining rules would be meaningless or destructive:

- Feature-not-supported gates (`:vision_not_in_v0_2` per §33 — no point validating other fields when refusing the message).
- Shape preconditions whose violation invalidates subsequent rules (content-is-not-a-list short-circuits list-element rules).
- Resource-unsafe continuations (rare at Layer A; more relevant in Layer B adapter loops).

Hard-reject errors are annotated with `Hard-reject? = **yes**` so control flow is derivable from the contract.

### 8. Streaming & Backpressure

For any phase touching Layer C streaming or stream consumption:

- **Cleanup is mandatory.** Every `Stream.resource/3` has an `after_fun` releasing the Finch ref or other resource — verify with a test that halts early (`Enum.take(stream, 2)`) and asserts release.
- **Backpressure model.** Streaming uses `Finch` with HTTP/1 (§7.2). Document the chunk-buffering strategy: how SSE chunks are line-buffered, what happens when an event spans chunks, what happens when the consumer is slow.
- **Cancellation.** Streams must be cancellable from the consumer side. Test that consumer halt → upstream HTTP cancel within a bounded time (≤500ms in CI).

### 9. Definition of Done

- [ ] All phases marked `Completed`
- [ ] `mix test` zero failures, zero `unused_var` warnings, coverage ≥80% globally and ≥90% on new code
- [ ] `mix credo --strict` zero issues on changed files
- [ ] `mix dialyzer` zero new warnings (vs. prior PLT)
- [ ] `mix format --check-formatted` passes
- [ ] Every new public function has `@spec` and `@doc` with at least one runnable doctest
- [ ] Every Layer A struct change has a serializability round-trip test
- [ ] Every behaviour change has the conformance suite updated, and `ALLM.Providers.Fake` passes it
- [ ] Stream-equivalence test passes for any non-streaming wrapper added
- [ ] Spec section references in commit messages match §-numbers in the Overview
- [ ] CHANGELOG.md updated with one line per public-API change
- [ ] Reviewed via `/review` (see `AGENT_REVIEW_SPEC.md`)

**Ticked-with-caveats requires a linked finding.** When a DoD item is ticked but has known caveats (assertion relaxations, excluded test cases, partially-implemented contract), the item MUST link to a retro finding or open issue tracking resolution. A bare tick on a caveated item is misleading. Worked example: PHASE_7's `Chat-equivalence property passes with ≥100 StreamData iterations` ticked in batch 4 with three known divergences (F1/F2/F3) — the tick should be accompanied by `Known caveats: see retro/<file>.md F1-F3 → resolved by Phase 7.6 cleanup`.

## Guidelines

### General

1. **Tests first, always.** Each phase begins with a Test Plan. Implementer writes test, sees it fail, then implements. A design that hands the implementer a finished implementation but no tests is transcription, not design. 80% is a floor; design for ≥90% on new code.
2. **One layer per phase.** If a phase needs two layers, split it. Each layer has different review surfaces (A: serializability + types; B: DI + conformance; C: stream-equivalence + error contracts; D: state-transition correctness).
3. **Compose by reduction, not wrapping.** Non-streaming functions reduce stream events via `ALLM.StreamCollector`. Session functions reduce stateless events into session updates. Parallel implementations of streaming and non-streaming paths violate stream-first (§3).
4. **Reference the spec, don't re-state it.** Cite sections (`# see §12.3 ask-user`). Re-stating in prose creates two sources of truth.
5. **Use `ALLM.Providers.Fake` for orchestration tests.** Never HTTP mocks for orchestration logic. Network mocks reserved for real adapter wire shape (live in that adapter's test file). In CLAUDE.md, non-negotiable.
6. **No PIDs, refs, funs, or anonymous functions on Layer A.** A serialized session must round-trip across processes, nodes, and disk. Modules and atoms are fine; anything else is a leak.
7. **API keys never appear on the engine.** Keys resolve through `ALLM.Keys` at adapter-call time (§6.4). A design putting a key on the engine fails serializability.
8. **Late-resolve model strings.** Optional `llm_db` provides capability checks; core must function without it (§6.3). Designs hard-depending on `llm_db` must justify.
9. **`middleware:` stays empty in v0.2.** Cross-cutting concerns go through telemetry handlers or adapter wrappers (§29). A design proposing middleware is a v0.3 design — file separately.
10. **See something, say something — refactor first.** While reading code you'll touch, if you notice duplication, dead callbacks, missing `@spec`s, or spec/code drift, add a small refactor as Phase 1 before new work. Keep scope tight to code the feature touches.
11. **Cross-phase consistency pass.** Before finishing a multi-phase doc, re-read each phase with every other as context. Specifically check: (a) every new event variant has a reducer case in `ChatResult`, `StepResult`, *and* `Session`; (b) every behaviour callback added is implemented in `ALLM.Providers.Fake`; (c) every `@spec` matches Behaviour & Type Contracts verbatim; (d) **Test Plan vs pseudocode reconciliation** — when a Non-obvious Decision shows pseudocode using short-circuit operators (`||`, `&&`, guarded `with`), and Test Plan bullets specify behaviour for nil/false/empty inputs, walk through the pseudocode's short-circuit semantics on each Test Plan input and verify the assertion matches. `||`-chains eat nil/false; `with`-chains short-circuit on `{:error, _}`. Worked example: PHASE_7 7.3 Test Plan said `max_turns: nil` raises `ArgumentError`; same-section pseudocode at Decision #9 used `||`-chained precedence which falls through to the next layer. The implementer correctly picked the precedence-chain branch; the design caught the disagreement after.

### Elixir-specific

- **Function arity matters.** `ALLM.generate/3` and `ALLM.generate/2` are different functions to the user. Specify exact arities; never silently change.
- **Pattern match the happy path.** Public functions return `{:ok, result}` / `{:error, %ALLM.Error.X{}}`. Internal helpers may return bare values when failure is impossible. Don't overload return shapes (no `{:ok, result, warning}` triples — put the warning on the result struct).
- **Use behaviours for swappable dependencies.** Adapters, tool executors, key resolvers all sit behind behaviours. The Fake is part of the library (`lib/allm/providers/fake.ex`), not test-only — users need it for their own tests.
- **Prefer `Stream.resource/3` over `Stream.unfold/2`** for IO-backed streams. `resource/3` has explicit cleanup; `unfold/2` doesn't.
- **`Logger` for diagnostics, telemetry for instrumentation.** Don't conflate them. `Logger.warning("rate limited")` for ops visibility; `:telemetry.execute([:allm, :request, :stop], ...)` is the integration point for downstream measurement (§29).
- **Doctests are tests.** They run under `mix test`. A `@doc` example that doesn't compile is a failing test. Keep docs honest.
- **No conditional compilation for tests.** Test-only modules live under `test/support/` (in `elixirc_paths` only for `:test`). Never `if Mix.env() == :test` in `lib/`.
- **Scope stdlib bans to their threat model, not globally.** A rule banning a stdlib function ("never `Module.concat/1`", "never `String.to_atom/1`") must annotate **where** the ban applies — input-derived data paths vs. source-literal paths, adapter-facing vs. user-facing, test vs. production. Blanket bans force tactical scoping on every implementer because the functions have legitimate uses on source-controlled input (e.g., `Module.concat(["LLMDB"])` for optional-dep detection with `Code.ensure_loaded?/1`). The invariant is usually "never derive <X> from untrusted input"; write that, not "never <X>".
