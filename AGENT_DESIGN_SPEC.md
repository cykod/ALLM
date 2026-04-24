# Design Spec Guidelines — ALLM

How to write design documents for the ALLM Elixir library. The `/design` skill reads this file automatically.

## Project Context

ALLM is a provider-neutral LLM execution library with first-class streaming and serializable conversation state. The canonical specification is `steering/allm_engine_session_streaming_spec_v0_2.md` — design docs **refine** the spec into implementation phases, they do not redefine it. When a design choice is non-obvious, cite the spec section (`§6.3`, `§12.3`, etc.) so reviewers can diff intent against the spec.

Concrete application shapes the library must support live in `steering/examples/` (`amesury_example.md`, `garden_example.md`, `meal_example.md`, `unllmtd_example.md`). When choosing ergonomics, walk through one example end-to-end and ask: *can a user write this against the API I'm designing without reading the source?*

There is no UI, no database, no service to deploy. Design docs cover **library code**: data structs, behaviours, the engine, stream runners, adapters, session helpers, and the public facade. Anything that crosses the four-layer boundary (see `CLAUDE.md → Architecture in one page`) is a red flag — call it out in the Overview.

## The Four Layers

Every design phase must declare which layer(s) it touches, because the layer dictates the testing strategy, the serializability constraints, and the legal dependency direction:

| Layer | Contents | Constraints |
|-------|----------|-------------|
| **A — Serializable data** | `ALLM.Message`, `ALLM.ToolCall`, `ALLM.Request`, `ALLM.Response`, `ALLM.Thread`, `ALLM.Session`, `ALLM.StepResult`, `ALLM.ChatResult`, `ALLM.Event`, `ALLM.Usage` | Plain structs only. No PIDs, refs, funs, anonymous functions, or API keys. Must round-trip `:erlang.term_to_binary/1` and `Jason.encode!/1 |> Jason.decode!/1` (with module hints). Tested in isolation. |
| **B — Runtime** | `ALLM.Engine`, `ALLM.Adapter`, `ALLM.StreamAdapter`, `ALLM.ToolExecutor`, `ALLM.ToolResultEncoder`, `ALLM.Keys` | Carries non-serializable refs (modules, funs, Finch names, key resolvers). API keys resolve at adapter-call time, never at engine construction. The engine itself must be safe to persist (modules + atoms only). |
| **C — Stateless execution** | `ALLM.generate/3`, `ALLM.stream_generate/3`, `ALLM.step/3`, `ALLM.stream_step/3`, `ALLM.chat/3`, `ALLM.stream/3` | Pure dispatch over a supplied engine. No process state. Streaming variants are primitives; non-streaming variants reduce stream events via `ALLM.StreamCollector`. |
| **D — Stateful continuation** | `ALLM.Session.start/3`, `stream_start/3`, `reply/4`, `stream_reply/4`, `step/3`, `stream_step/3` | Operates over a `%ALLM.Session{}`. Returns updated sessions, never mutates. Composes Layer C. |

**A phase that touches more than one layer is suspect.** Split it. The whole point of the four-layer structure is that each layer has its own test strategy and dependency surface — mixing layers in one phase usually means the layer boundaries are being smuggled across.

## Composability is the Product

ALLM's value proposition is that each layer is independently usable:

- A user can construct `%ALLM.Message{}` and `%ALLM.Request{}` values without ever calling an adapter (Layer A).
- A user can call `ALLM.generate/3` with an engine and a request and get a response, with no session machinery in the way (Layer C).
- A user can drive a multi-turn `ALLM.Session` and persist it to disk between turns (Layer D).
- A user can stream events and write their own reducer instead of using `chat/3` (Layer C streaming primitive).

**Every design must demonstrate that the new functionality preserves this property.** If a Layer C change requires a Layer D wrapper to be useful, the layer boundary is wrong. Show in the Overview how a hypothetical user would consume the new functionality at *each* layer it touches, with a 3-5 line code snippet per layer.

## Document Structure

### 1. Title & Status Table

```markdown
# Phase N: Title — Design Document

> **Goal:** One-sentence goal
> **Outcome:** What "done" looks like (measurable)
> **Spec sections:** §6.3, §12.3 (every section this phase implements or refines)
> **Layers touched:** A / B / C / D (one or more — call out if multiple, justify if >1)

## Status

| Phase | Description | Layer | Status |
|-------|-------------|-------|--------|
| 1 | Refactor: extract `ALLM.Internal.Stream` from `Engine` | B | Not Started |
| 2 | `ALLM.Event` closed union + `event?/1` guard | A | Not Started |
| 3 | `ALLM.Providers.Fake` stream scripting | B | Not Started |
| 4 | `ALLM.stream_generate/3` over Fake | C | Not Started |
| 5 | `ALLM.generate/3` as a stream reducer | C | Not Started |

**Overall Progress:** 0/5 phases complete
```

Valid statuses: `Not Started`, `In Progress`, `Completed`. Update the table and the progress line every time a phase moves.

#### Naming Convention

Design docs live under `steering/designs/` and are named `PHASE_N_<short-slug>.md` where `N` continues the project-wide phase numbering. Cross-cutting refactors that don't fit a feature phase use `REFACTOR_<short-slug>.md`. Real provider adapters get `PHASE_PROVIDER_<name>.md` (e.g., `PHASE_PROVIDER_OPENAI.md`).

### 2. Overview

3-5 sentence summary of what the design covers and *why now*. Then bullets:

- **Deliverables** — concrete modules, behaviours, structs, public functions added or changed
- **Spec coverage** — which §-numbered spec sections this phase implements (or refines, if the spec is being amended — amendments require a separate spec PR before the design is approved)
- **Layer demonstration** — for each layer touched, a 3-5 line snippet showing how a user consumes the new functionality at *that* layer alone. This is the load-bearing proof that the layer boundary is real.
- **Prerequisites** — earlier phases or spec changes required (with file paths)
- **Out of scope** — what this design deliberately excludes, with a one-line justification each. A missing item at the end reads as oversight; a deliberate exclusion reads as intent.
- **Non-obvious decisions** — choices a future reader would question, each with a one-sentence rationale and a `Docs target:` annotation indicating where the decision surfaces in user-facing documentation. Accepted targets: `Docs target: @moduledoc <Mod>`, `Docs target: @doc <Mod.fun/arity>`, `Docs target: CHANGELOG entry only`, `Docs target: internal — no user-facing docs needed`. This makes the design-rationale → user-docs hand-off explicit so the implementer doesn't have to infer which decisions need `@moduledoc` prose.

### 3. Behaviour & Type Contracts

Every design that introduces or modifies a behaviour, struct, or public function must define the contract before any phase. This is the API surface; phases implement against it.

For each module, specify:

- **`@type` definitions** — full typespecs, including the closed union members for tagged tuples (e.g., `ALLM.Event`)
- **`@callback` definitions** — for behaviours, every callback with `@spec`-style argument and return types
- **`@spec` for public functions** — argument types, return types, and the **complete** error tuple shape (`{:error, %ALLM.Error.AdapterError{}}` not `{:error, term()}` — `term()` is a smell that says the error contract isn't designed)
- **Struct shape** — every field with its type, default, and whether it's serializable (Layer A) or runtime (Layer B)
- **Invariants** — properties the type must preserve across all operations (e.g., "`Session.thread.messages` always ends with an `:assistant` or `:tool` message after `reply/4`")

Show the contract as Elixir code blocks. Example:

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

**Contracts must reproduce every test-plan assertion.** If a Test Plan bullet requires a specific Elixir idiom to produce the asserted behaviour — `@enforce_keys` for `struct!/2` raising on missing fields, `defexception` catch-all clauses for `Exception.message/1` on raw structs, `String.to_existing_atom/1` for atom decode safety, `defimpl` vs. `@derive` for protocol dispatch, `Stream.resource/3` cleanup semantics — name the idiom in the Behaviour & Type Contracts section. The contract section must be sufficient to reproduce every test-plan assertion without asking the implementer to infer Elixir-stdlib choices. If an implementer has to add `@enforce_keys` or a `message/1` fallback to make the Test Plan pass, that's a missing contract, not a deviation.

**Test-observable values must be empirically verified, not recalled.** Any concrete fact a design asserts about how code behaves at runtime — the exception a function raises, the atoms a closed enum accepts, the return shape of an opaque stdlib call — is a test-observable that a Test Plan bullet will eventually assert against. If the design got it wrong, the implementer has to choose between truthful code and faithful-to-design code; both are wrong answers. **Before the design ships, every test-observable claim must carry one of: an `(verified in IEx on <date>)` annotation, a cited file:line reference to the committed source, or a quoted stdlib doc snippet.** Memory is not a citation. This rule has five concrete classes (Phase 3 retros surfaced all five one at a time — collapse them into one checklist for future designs):

1. **Stdlib exception shapes.** When a Test Plan asserts that a function raises a specific exception module (`ArgumentError`, `Protocol.UndefinedError`, `Jason.EncodeError`, `KeyError`, etc.), cite the function's docs or `(verified in IEx on <date>)`. Exception shape varies by input category within the same function — `:erlang.fun_info/2` raises `ArgumentError` on a non-function but `FunctionClauseError` on a wrong-arity dispatch.
2. **Project-owned closed atom enumerations.** When a design references atom values from a committed `@type reason :: :foo | :bar | ...` enum, a registry's `@known_modules` list, a tagged-union's variant tags, or any `String.to_existing_atom/1` safelist, cite the `file:line` of the committed enum or annotate `(verified against <path> on <date>)`. Do NOT invent atoms that aren't in the committed set — if an atom is missing, the design must explicitly extend the prior phase's enum as a scoped amendment.
3. **Stdlib function failure modes on the declared OTP floor.** When a Test Plan asserts that `Keyword.fetch!/2`, `Map.fetch!/2`, `:counters.get/2`, `Jason.decode!/1`, etc. raise a specific exception on a specific bad input, run the call in `iex` on the project's declared OTP floor (currently OTP 27 per `mix.exs`) and cite the observed exception. OTP-version-specific behaviour is a test-observable.
4. **Macro-expansion-wrapped stdlib raises.** An exception raised *inside* a `quote do ... end` block or during `Code.compile_quoted/1` / `Code.eval_quoted/2` may or may not be wrapped as `CompileError` depending on which API consumes the AST. If a Test Plan asserts that `use MyCaseTemplate` without a required opt raises `CompileError`, run it in `iex` first — `Keyword.fetch!/2` at quoted-expansion time often surfaces the underlying `KeyError` unwrapped. This is the same class as rule 3 but with a macro-expansion call frame in the middle.
5. **Opaque-term return shapes.** When a design references the return of `:counters.new/2`, `Finch.Conn.*`, `Port.open/2`, `:ets.new/2`, or any other stdlib function that returns an opaque term, inspect the actual return on OTP 27 and cite it. `:counters.new(1, [:atomics])` does not return a bare `reference()` — it returns `{:atomics, #Reference}`. Guards that assume the bare shape silently skip cleanup paths.

**Primitive verification vs. composition verification.** A `(verified in IEx on <date>)` annotation on a single stdlib call is *primitive verification* — the primitive's behaviour in isolation. When the design composes two or more primitives under constraints that force a specific interaction (e.g., `Task.async_stream/5` + `ordered: false` + per-input attribution on timeout; `Stream.resource/3`'s `next_fun` pulling one element at a time from an inner `Enumerable.reduce/3` continuation; `Stream.concat/1` wrapping an already-`Stream.resource/3`-owned enumerable whose cleanup fires once), the primitive's isolated behaviour is *necessary but not sufficient*. The implementer discovers the composition's shape at implementation time, often as a tactical deviation the design didn't predict. Concrete instances: Phase 6 Batch 1 needed `zip_input_on_exit: true` on `Task.async_stream/5` (the design verified `{:exit, :timeout}` in isolation; parallel + `ordered: false` forced per-input attribution the primitive verification didn't reach); Phase 6 Batch 2 needed the `{:suspend, event}` reducer-return idiom to drive a sub-stream one element at a time from inside another resource's `next_fun` (neither `Stream.concat/1` nor `Stream.transform/3` satisfies the state-dependency between phases).

When a design composes two or more primitives under phase-specific constraints, either (a) write the composition's IEx verification script inline (show the full multi-primitive call and the observed shape), or (b) explicitly enumerate the expected behaviours of the composition as a numbered list the implementer must verify during implementation. A bare "`Task.async_stream/5` accepts `ordered: false`" verification on a one-task case does not license a design that needs parallel + attribution + timeout + index-based result sorting; the interaction between those four constraints is its own test-observable.

**Hedge words in a design are trip-wires — they signal the author didn't verify.** Phrases like `(or the equivalent)`, `or similar`, `or something like that`, `roughly X`, `presumably`, `I think`, `probably`, `should raise` (without citation) embedded in a Test Plan, Non-obvious Decision, or contract prose are inference markers. Before the design ships, each one must be either (a) replaced with an empirical citation per the five classes above, or (b) rewritten to drop the specific claim the hedge is softening. A design that says "MFA handlers raise `FunctionClauseError` (or the equivalent)" is telling the reader "I didn't try it"; the implementer will then discover the truth under time pressure. **Equally dangerous: confident-and-wrong assertions without hedge words.** Phase 3 Batch 3 shipped `CompileError` with no hedge — the author believed it — and was still wrong. Hedge words are one signal; the other is any concrete claim in the five classes above that lacks the `(verified ...)` annotation. Treat both as pre-landing checklist items: grep the design for hedge words AND confirm every concrete claim carries its citation.

**When a design adds a new type to an existing serializer, dispatcher, or registry, the registration is part of the contract.** The Behaviour & Type Contracts section must name the registration alongside the type — not bury it in a checklist item. A reader of §Behaviour & Type Contracts alone must be able to reproduce every Test Plan assertion, including those that depend on dispatcher routing (e.g., `ALLM.Serializer`'s `@known_modules` list, a future tool-result encoder registry, or any atom-keyed type-tag table). If a Test Plan assertion depends on routing-through-registration to fire, the registration update is part of the contract.

**Any struct field typed `keyword()` requires an encoder-side pre-pass to list-of-pairs.** Jason has no `Encoder` impl for raw 2-tuples, so a keyword list encodes as `[[k, v], …]`, not as tuples. Either (a) state the transform explicitly in the contract section with a matching `restore_keyword/1` helper call in `__from_tagged__/1`, or (b) preferred — extend the project's central `Jason.Encoder` helper (`ALLM.Serializer.encode_tagged/2`) to handle kwlists generically and expose the symmetric restore helper. Do not inline per-field pre-passes if more than one Layer A/B type carries a keyword field.

**Consumer/producer symmetry for filter keys.** When a design introduces a deny-list, allow-list, or any key-based filter that partitions opts between two or more consumers, the contract section must name the symmetry invariant: every key consumed by function A must appear in function B's filter (or vice versa, per the design). A reader of §Behaviour & Type Contracts alone must be able to derive both (a) the filter's contents and (b) the invariant that the filter's contents equal the complementary consumer's handled keys. This prevents the cross-sub-phase gap where a filter feels complete against its own prose but omits a key its counterpart handles (see Phase 2 Decision #5's `:params` addendum for the canonical case).

**Behaviour design-doc checklist.** Before finalizing a design that introduces a behaviour (a module with `@callback`s) plus a conformance harness, run these five cross-cutting checks:

1. **Every `@callback` traces to a v0.2 user-visible operation.** A callback without a concrete user story is a speculation, not a contract. Cite the `steering/examples/` or spec § that motivates each callback.
2. **Every behaviour failure mode has a named atom in the design's vocabulary table.** Prevents per-batch atom drift when multiple implementers add their own reasons ad-hoc.
3. **The conformance suite calls only through the behaviour's `@callback`s, or the extra `impl` surface it relies on is documented in the contract.** Hidden contracts (suites expecting `impl.script/0` or similar introspection) smuggle a second behaviour into the first; name it or drop it.
4. **For streaming-adjacent callbacks, the cleanup invariant is part of the contract, not an implementation note.** `Stream.resource/3`'s cleanup function and bounded cancellation time are test-observable per §8, which makes them structural; they belong on the callback, not in prose.
5. **Every reason atom named in the design is verified to exist in the committed closed set of a prior phase.** Open `lib/allm/error/<name>.ex` (or the relevant registry / union file), read the `@type reason :: ...` enum, and confirm every atom in every error-reason table of the design appears in the enum. If the design needs an atom that doesn't exist yet, the design must explicitly extend the Phase 1 enum as a scoped amendment — never silently assume a new atom will be accepted.
6. **Cross-function invariants are part of the contract, not just per-function behaviour.** When the design specifies functions X and Y such that X's output flows into Y's input, or X and Y share a field mapping, name the invariant between them — not just each function's behaviour separately. Three concrete shapes to check: (a) **Mirror file:line citations** — if X "mirrors" Y, cite Y by absolute file path and line range (a bare "mirrors StubAdapter" is a drift risk); (b) **State-boundary resolution** — if X has a pure signature but a design bullet says "carry state between calls," name which caller owns the state and whether X takes-acc-as-arg or is pure-called-from-stateful-context; (c) **Shape-distinguishing invariants** — if X has branches with divergent downstream behaviour (e.g., full vs. delta-accumulated tool calls), name what is preserved vs. transformed on close (atom keys vs. string keys, caller-supplied vs. provider-echoed). Unnamed shape distinctions produce silent correctness bugs.
7. **Conformance-suite case counts are part of the contract.** When a design introduces a conformance harness, add `@case_count N` + `case_count/0` introspection + a meta-test asserting the injected `describe/2` block produces exactly `@case_count` `test` cases. Adding a case without bumping the attribute is silent drift; the attribute turns it into a loud PR-review-time signal.
8. **When a design bullet describes an outcome whose enforcement lives in a specific line of project config, cite the config file:line.** Examples: "not in the published Hex package" → `mix.exs` `package/files` line; "excluded from `mix test` by default" → `test/test_helper.exs` `ExUnit.start(exclude: [...])` line; "CI fails on formatting drift" → workflow file:line; "Dialyzer PLT adds `:ex_unit`" → `conformance/mix.exs` `dialyzer: [plt_add_apps: ...]` line. A bare outcome claim without a mechanism cite is a drift risk — the next config edit silently breaks it.

**Adding a new variant to a closed tagged-tuple union is a breaking change for every reducer.** Call this out explicitly in the Overview when it happens.

### 4. Module Tree

A file tree of new and modified files, marked `(NEW)`, `(MODIFY)`, or `(DELETE)`:

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

Test files mirror source files 1:1. Test-only fixtures live under `test/support/` (already in `elixirc_paths` for `:test`).

### 5. Phases

Break the design into ordered phases. Each phase **must**:

- Touch a single layer (call it out — Layer A / B / C / D)
- Be independently shippable: after the phase, `mix test`, `mix credo --strict`, and `mix dialyzer` all pass; the public API is consistent (no half-defined functions, no callbacks without implementations)
- Have 4-8 checkboxes — split into sub-phases (1.1, 1.2) if larger
- Begin with **a Test Plan**, not an implementation sketch (TDD)
- End with a **Verification** sub-section listing the exact commands to run

Build order should follow the spec §28 progression unless explicitly justified: data structs → engine → behaviours → event → stream runner + Fake → collectors/reducers → streaming APIs → non-streaming wrappers → session helpers → real adapters.

#### Worked phase example

```markdown
## Phase 4: `ALLM.stream_generate/3` over Fake (Layer C)

**Goal:** Expose a streaming generation primitive that returns an `Enumerable.t()` of `ALLM.Event` values, driven by an injected `StreamAdapter`.

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
- For any scripted sequence of valid events, `stream_generate/3 |> Enum.to_list/1` returns the sequence verbatim (event-equivalence with the script).

### 4.2 Implementation Checklist

- [ ] Define `ALLM.Error.EngineError` and `ALLM.Error.AdapterError` structs (if not already in Phase 1)
- [ ] Implement `ALLM.stream_generate/3` in `lib/allm.ex`, dispatching to `engine.stream_adapter.stream/3`
- [ ] Wire resource cleanup via `Stream.resource/3` so consumer halts close the upstream
- [ ] Document the function with `@doc` including a runnable doctest using `ALLM.Providers.Fake`
- [ ] Add `@spec` matching the Behaviour & Type Contracts section verbatim

### 4.3 Verification

```bash
mix test test/allm/allm_stream_generate_test.exs
mix test test/allm/allm_stream_generate_property_test.exs
mix test                              # full suite still green
mix credo --strict lib/allm.ex
mix dialyzer
```

The doctest in `@doc` must pass under `mix test`. A user reading `iex> h ALLM.stream_generate` should see a complete worked example using `ALLM.Providers.Fake` — no real provider required.
```

### 6. Test Plan (cross-phase, before implementation phases)

The Test Plan section is the most important section in a design doc — ALLM is built TDD-first. For every phase, list:

- **Unit tests** (per module) — every public function has at least one happy-path and one error-path test. Tagged-union types have one test per variant.
- **Behaviour conformance tests** — when introducing or modifying a behaviour, write a `Behaviour Conformance` test module under `test/support/` that any implementation can be plugged into. `ALLM.Providers.Fake` is the reference implementation; real provider adapters reuse the same conformance suite.
- **Integration tests** — multi-module flows (e.g., `stream_generate → StreamCollector → generate`). Always use `ALLM.Providers.Fake`, never network mocks, except when explicitly testing a real adapter's wire format.
- **Property tests** (`StreamData`) for closed unions, reducers, and round-trippable data. The §31 property scenarios are the floor, not the ceiling.
- **Doctests** — every public function in `ALLM`, `ALLM.Session`, and behaviour callbacks must have a runnable `@doc` example. Doctests double as living documentation and as the cheapest possible smoke test.
- **Serializability tests** (Layer A only) — every Layer A struct must round-trip through both `:erlang.term_to_binary/1` and `Jason.encode!/1 |> Jason.decode!/1` (with a custom decoder that re-hydrates the struct). Failures here are blocking.
- **Stream-equivalence tests** — for any non-streaming function `f/n` implemented as a reducer over `stream_f/n`, a property test asserts that `f(args)` is equivalent to `stream_f(args) |> StreamCollector.collect/1` for every scripted input.

**Coverage threshold:** `mix.exs` configures 80% via `test_coverage: [summary: [threshold: 80]]`. Design docs may not lower this. New code in a phase should land at ≥90% line coverage; the 80% threshold is the global floor, not the per-phase target.

### 7. Error Contract

Errors are first-class data, not strings. Every public function that can fail must return `{:error, %ALLM.Error.XError{}}` where `XError` is a struct with at minimum:

- `:reason` — atom, drawn from a documented closed set per error type (e.g., `:rate_limited`, `:authentication_failed`, `:invalid_request`, `:provider_unavailable`, `:context_length_exceeded`)
- `:message` — human-readable, never includes secrets
- `:provider` — `nil` for engine-level errors, the provider atom otherwise
- `:cause` — the underlying exception or term, for debugging; never displayed to users

Every design phase that introduces a new error path must list:

| Function | Error reason | Recovery guidance |
|----------|--------------|--------------------|
| `stream_generate/3` | `:no_stream_adapter` | Caller passed an engine without `:stream_adapter`; recoverable by passing one. |
| `stream_generate/3` | `:authentication_failed` | Key resolver returned no key or the provider rejected it; surface to user, do not retry. |
| `stream_generate/3` | `:rate_limited` | Provider returned 429; caller may retry with backoff (engine `:retry_policy` handles this if configured). |

`{:error, term()}` in a `@spec` is a code smell that says the error contract isn't designed — call it out in review.

### Field-error atom vocabulary

For validator-shaped modules (`ALLM.Validate`, and future `ALLM.Serializer.from_json/2`-style decoders), the design doc must include an **exhaustive** field-error vocabulary table. One row per `{field_path, reason_atom}` pair:

| Field path | Reason atom | Hard-reject? | Fires when |
|------------|-------------|--------------|------------|
| `[:messages]` | `:empty` | no | request has zero messages |
| `[:tools, idx, :name]` | `:duplicate_name` | no | two tools share a `name` |
| `[:content]` | `:image_part` | **yes** | content list contains an image part (§33) |

Exhaustive means the implementer should never have to invent an atom. If a rule produces an error whose atom isn't in the table, that's a design gap — add the row before implementation. `hard-reject:` marks errors that short-circuit the rest of validation (see "Hard-reject semantics" below).

### Hard-reject semantics

Validators accumulate per-field errors by default (fold over the input, return all issues in one `%ValidationError{errors: […]}`). A specific error opts into **hard-reject** semantics — short-circuit the validator, return only that error — when the remaining rules would be meaningless or destructive to run:

- Feature-not-supported gates (`:vision_not_in_v0_2` per §33 — no point validating other message fields when we're refusing the whole message).
- Shape preconditions whose violation invalidates subsequent rules (e.g., content-is-not-a-list short-circuits list-element rules).
- Resource-unsafe continuations (rare at Layer A; more relevant in Layer B adapter loops).

Hard-reject errors are annotated in the vocabulary table with `Hard-reject? = **yes**` so the validator's control-flow structure is derivable from the contract. Everything else accumulates.

### 8. Streaming & Backpressure

For any phase that touches Layer C streaming or stream consumption:

- **Cleanup is mandatory.** Every `Stream.resource/3` must have an `after_fun` that releases the Finch ref or other resource — verify with a test that halts the stream early (`Enum.take(stream, 2)`) and asserts the resource is released.
- **Backpressure model.** The streaming spec uses `Finch` with HTTP/1 (see spec §7.2). Document the chunk-buffering strategy: how SSE chunks are line-buffered, what happens when an event spans chunks, and what happens when the consumer is slow.
- **Cancellation.** Streams must be cancellable from the consumer side. A test must prove that consumer halt → upstream HTTP cancel within a bounded time (≤500ms in CI).

### 9. Definition of Done

End every design with a checklist:

- [ ] All phases marked `Completed` in the status table
- [ ] `mix test` passes with zero failures, zero `unused_var` warnings, coverage ≥80% globally and ≥90% on new code
- [ ] `mix credo --strict` passes with zero issues on changed files
- [ ] `mix dialyzer` passes with zero new warnings (compare against the prior PLT)
- [ ] `mix format --check-formatted` passes
- [ ] Every new public function has an `@spec` and an `@doc` with at least one runnable doctest
- [ ] Every Layer A struct change has a serializability round-trip test
- [ ] Every behaviour change has the conformance suite updated, and `ALLM.Providers.Fake` passes it
- [ ] Stream-equivalence test passes for any non-streaming wrapper added in this phase
- [ ] Spec section references in commit messages match the §-numbers in the Overview
- [ ] CHANGELOG.md updated with a one-line entry per public-API change
- [ ] Reviewed via `/review` (see `AGENT_REVIEW_SPEC.md`)

## Guidelines

### General

1. **Tests first, always.** Each phase begins with a Test Plan. The implementer writes the test, sees it fail, then implements. A design that hands the implementer a finished implementation but no tests is not a design — it's transcription. The 80% threshold is a floor, not a target; design for ≥90% on new code.
2. **One layer per phase.** If a phase needs to touch two layers, split it. Layer changes have different review surfaces (Layer A: serializability + types; Layer B: dependency injection + behaviour conformance; Layer C: stream-equivalence + error contracts; Layer D: state-transition correctness).
3. **Compose by reduction, not by wrapping.** Non-streaming functions reduce stream events via `ALLM.StreamCollector`. Session functions reduce stateless events into session updates. Designs that introduce parallel implementations of streaming and non-streaming paths violate the stream-first invariant (spec §3).
4. **Reference the spec, don't re-state it.** When a design encodes a spec rule, cite the section: `# see §12.3 ask-user`. Re-stating the spec in prose creates two sources of truth that drift.
5. **Use `ALLM.Providers.Fake` for orchestration tests.** Never reach for HTTP mocks for orchestration logic. Network mocks are reserved for testing a real provider adapter's wire shape (and live in that adapter's test file). This rule is in CLAUDE.md and is non-negotiable.
6. **No PIDs, refs, funs, or anonymous functions on Layer A.** A serialized session must round-trip across processes, nodes, and disk. Modules and atoms are fine; anything else is a leak.
7. **API keys never appear on the engine.** Keys resolve through `ALLM.Keys` at adapter-call time (spec §6.4). A design that puts a key on the engine struct fails the serializability invariant.
8. **Late-resolve model strings.** Optional `llm_db` provides capability checks; core must function without it (spec §6.3). Designs that hard-depend on `llm_db` must justify the dependency.
9. **`middleware:` stays empty in v0.2.** Cross-cutting concerns go through telemetry handlers or adapter wrappers (spec §29). A design that proposes middleware is a v0.3 design — file it separately.
10. **See something, say something — refactor first.** While reading code you'll touch, if you notice duplication, dead behaviour callbacks, missing `@spec`s, or drift between the spec and the code, add a small refactor as Phase 1 before new work. Keep scope tight to code the feature touches.
11. **Cross-phase consistency pass.** Before finishing a multi-phase doc, re-read each phase with every other as context. Specifically check: (a) every new event variant has a reducer case in `ChatResult`, `StepResult`, *and* `Session` reducers; (b) every behaviour callback added is implemented in `ALLM.Providers.Fake`; (c) every `@spec` matches the Behaviour & Type Contracts section verbatim.

### Elixir-specific

- **Function arity matters.** `ALLM.generate/3` and `ALLM.generate/2` are different functions to the user. Designs must specify exact arities and never silently change them.
- **Pattern match the happy path.** Public functions return `{:ok, result}` / `{:error, %ALLM.Error.X{}}`. Internal helpers may return bare values when failure is impossible. Don't overload return shapes (no `{:ok, result, warning}` triples — put the warning on the result struct).
- **Use behaviours for swappable dependencies.** Adapters, tool executors, key resolvers all sit behind behaviours. The Fake implementation is part of the library (`lib/allm/providers/fake.ex`), not test-only — users need it for their own tests.
- **Prefer `Stream.resource/3` over `Stream.unfold/2`** for IO-backed streams. `resource/3` has explicit cleanup; `unfold/2` does not.
- **`Logger` for diagnostics, telemetry for instrumentation.** Don't conflate them. `Logger.warning("rate limited")` is fine for ops visibility; `:telemetry.execute([:allm, :request, :stop], ...)` is the integration point for downstream measurement (spec §29).
- **Doctests are tests.** They run under `mix test`. A `@doc` example that doesn't compile is a failing test. This is a feature — keep the docs honest.
- **No conditional compilation for tests.** Test-only modules live under `test/support/`, which is in `elixirc_paths` only for `:test`. Never `if Mix.env() == :test` in `lib/`.
- **Scope stdlib bans to their threat model, not globally.** A design rule banning an Elixir stdlib function (e.g., "never `Module.concat/1`", "never `String.to_atom/1`") must annotate **where** the ban applies — input-derived data paths versus source-literal paths, adapter-facing vs. user-facing, test vs. production. Blanket bans force tactical scoping judgments on every implementer, because the functions have legitimate uses on source-controlled input (e.g., `Module.concat(["LLMDB"])` for optional-dep detection with `Code.ensure_loaded?/1`). The rule's invariant is usually "never derive <X> from untrusted input"; write that, not "never <X>".
