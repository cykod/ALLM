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
6. **Cross-function invariants are part of the contract, not just per-function behaviour.** When functions X and Y are such that X's output flows into Y's input or they share a field mapping, name the invariant *between* them. Three concrete shapes: (a) **Mirror file:line citations** — if X "mirrors" Y, cite by absolute path and line range (a bare "mirrors StubAdapter" is drift risk); (b) **State-boundary resolution** — if X has a pure signature but a bullet says "carry state between calls," name which caller owns state and whether X takes-acc-as-arg or is pure-called-from-stateful-context; (c) **Shape-distinguishing invariants** — if X has branches with divergent downstream behaviour (full vs. delta-accumulated tool calls), name what is preserved vs. transformed on close (atom vs. string keys, caller-supplied vs. provider-echoed). Unnamed shape distinctions produce silent correctness bugs. (d) **Negative-claim Decisions ("unchanged," "byte-equal," "removed," "default reused") MUST include a "What the implementation does to maintain this" sentence with cited file:line.** Forces the author to mentally walk the integration before shipping the prose. Decisions touching multi-translator providers (OpenAI's Chat Completions + Responses) MUST cite all translators by file:line — a Decision affecting message-content shape that cites only one will surface as a half-mirror bug. Worked examples: PHASE_14 Decision #9's "default policy reused unchanged" was contradicted by `augment_image_retry_policy/1` (3-of-3 drift across 14.1/14.2/14.3 sub-phases). PHASE_14 Decision #14 was authored with five file:line cites including both OpenAI translators and shipped zero drift across 1071 LOC.
7. **Conformance-suite case counts are part of the contract.** Add `@case_count N` + `case_count/0` introspection + a meta-test asserting the injected `describe/2` produces exactly `@case_count` `test` cases. Adding a case without bumping the attribute is silent drift; the attribute makes it a loud PR-review signal. The same applies to any matrix the design declares as exhaustive over a closed product set — status × operation, error-reason × recovery-path, status × event-fold-clause. Headcount the matrix programmatically (`length(rows) × length(cols)` minus n/a cells) and reference the same number in the Test Plan and Definition of Done. Hand-tallied headcounts at different design-pass times drift; a programmatic count is a single source of truth. Worked example: PHASE_8_DESIGN said "23 tests" at L750 and "24 rows" at L862 for the same 5×5 status-transition matrix that decomposed into 25 actual tests once sub-cells were split — three different numbers for the same matrix.
8. **When a bullet describes an outcome whose enforcement lives in a specific config line, cite the config file:line.** Examples: "not in the published Hex package" → `mix.exs` `package/files`; "excluded from `mix test` by default" → `test/test_helper.exs` `ExUnit.start(exclude: [...])`; "CI fails on formatting drift" → workflow file:line; "Dialyzer PLT adds `:ex_unit`" → `conformance/mix.exs` `dialyzer: [plt_add_apps: ...]`. A bare outcome claim without a mechanism cite is drift risk — the next config edit silently breaks it.
9. **Contract-flip audit.** When a sub-phase changes a behaviour from "X passes through" to "X is rejected" (or otherwise inverts a prior-phase assertion / mutates a prior-phase no-op), the Implementation Checklist for that sub-phase MUST list "Audit prior-phase tests asserting the inverted behaviour and rename / flip / delete them" as an explicit bullet, citing every affected file:line. Same when a fold clause moves from no-op (catch-all) to mutating: audit every test helper that walked the stream + called `to_X_result/1`. Mechanical: `git grep '<inverted_assertion_substring>\|to_step_result\|to_chat_result\|to_response' test/`. **Treat every grep hit as a triage item with an explicit keep/refresh disposition, not just the files named in the Module Tree** — the discovery grep's reach is always broader than the design's hand-picked refresh list, so sibling files keep stale comments describing the pre-fix mechanism. Either the design enumerates all hits with a per-file disposition, or the implementer records a one-line disposition per hit during the audit. Worked example: UNLLMTD_FOOTGUN Phase 2 refreshed the three `*_equivalence_test.exs` moduledocs to engine-id keying but left `allm_chat_test.exs:73`, `allm_step_test.exs:70`, `allm_stream_step_test.exs:69`, and `chat_stream_test.exs:234` still asserting the `:erlang.phash2(scripts)` collision rationale the fix had just removed. Worked example: PHASE_7_DESIGN sub-phase 7.2's reserved-atom rejection didn't enumerate that Phase 6's `:tool_error accepted` test must be inverted; sub-phase 7.1's `:step_completed` fold reset broke `step_equivalence_test.exs:collect_step_result/2` silently.
10. **Cross-option × cross-path test matrix.** When a phase introduces `f/n` (streaming OR non-streaming) AND a prior phase shipped option set `O = {opt1, opt2, ...}` consumed by `f/n`, the Test Plan MUST include one row per `o ∈ O` for each path. Streaming and non-streaming Test Plans MUST be matrix-identical for option coverage — if `Chat.run/3` tests `on_tool_error: :halt`, `Chat.stream/3` tests it too. Build the matrix as a table; check both paths cover every cell. Missing cells are exactly where composition bugs hide. Worked example: PHASE_7_DESIGN sub-phase 7.4 Test Plan was missing the `on_tool_error: :halt` row that 7.3 had — the resulting `Chat.stream/3 + on_tool_error: :halt` infinite loop only surfaced at the chat-equivalence property test six weeks later.
11. **Cross-layer accept-set reconciliation.** When a public function's `@spec` declares an accept set wider than a downstream consumer's (a validator, an encoder, a serializer the function calls on the way out), the design's contract section must name the boundary transform — either narrow the public spec or surface the encoder explicitly. Worked example: PHASE_8.2's `submit_tool_result/3` accepted `String.t() | map()` per the design but the next-call `Validate.thread/1` rejected map `:content`; the implementer added `Jason.encode!/1` at the submission boundary as a tactical deviation. Same root cause as PHASE_7 batch-4's three masking-divergence relaxations between streaming `StreamCollector` state and non-streaming `StepResult`. The audit is mechanical: for every public `@spec`, walk every internal call the function makes and confirm the next consumer's accept set is no narrower than the public-facing accept set.
12. **Dispatch-graph and matrix-sub-cell reconciliation for state-machine designs.** When one public function delegates to another (sugar functions, `reply ≡ continue`, `start ≡ continue` on a fresh session), expand the precondition matrix to *one row per internal entry point*. Every cell's legality must be consistent across the chain — a cell illegal at the public-facing function but legal at the internal-entry-point function is a contract bug. Same rule applies inside a single function: when a status × operation matrix cell depends on additional arguments beyond (status, op) — message-arg shape, list cardinality, opt presence — expand the matrix to one row per minimum predicate. Labels like "gated," "conditional," or "depends on input" inside a matrix cell are hiding sub-cells. The implementer must be able to derive the legal/illegal predicate from the matrix alone, without reading the error-contract table to discover that "gated" means three different things. Worked examples: PHASE_8's matrix marked `continue/3` on `:awaiting_user` illegal AND specified `reply/4 ≡ continue(...)`; the two are inconsistent — the matrix needed a `(continue/3, :awaiting_user, %Message{role: :user})` cell explicitly legal as the `reply/4`-delegate path. PHASE_8's `(continue/3, :awaiting_tools)` cell labelled "gated" decomposed at impl time into three sub-cells: `(nil, pending == [])` legal, `(nil, pending != [])` illegal, `(%Message{}, _)` illegal.
13. **Every newly-added reason atom in a current-phase enum extension must have at least one named use site in the current phase's pseudocode or contract.** Orphaned atoms are speculative vocabulary; defer until their phase lands. Closed-enum atoms grow easier than they shrink — a consumer pattern-matching on the union breaks if a future phase prunes. Symmetric inverse of rule 5 (every named atom must exist in committed enum) — every newly-added atom must have a current-phase use site. Worked example: PHASE_8.2 added `:invalid_status_for_operation` and `:no_pending_tool_call` to `SessionError`'s enum; both are documented as "reserved for future use" because Decision #7 routed status mismatches to `ArgumentError` after the vocabulary section was finalized. Either prune at design time or attach a use-site comment per atom.
14. **Layer-C reducer-touch enumeration.** For every Layer-A field added or extended (any new `Response.*`, `Message.*`, `Usage.*`, `Thread.*` field that adapters populate from stream events OR that orchestration branches read from opts), enumerate the Layer-C reducer / construction helper that absorbs it. Two symmetric sites: outbound — `StreamCollector.apply_event/2` (closed payload-key pattern-match; new keys are silent drops); inbound — `Chat.build_request/4` (closed opts-key read; new opts never reach `%Request{}`). Both extensions are 5-15 LOC; both invisible to design review unless explicitly enumerated. Worked examples: PHASE_10.4 added `:response_format`/`:tool_choice`/`:structured_finalize` on `%Request{}` requiring `Chat.build_request/4` extension; PHASE_10.6 added `Response.metadata.reasoning.summary` requiring `StreamCollector.apply_event/2` `:metadata`-merge clause. Two consecutive phases, same gap class.
    - **Reducer-touch enumeration extends to new event-payload keys, not just Layer-A fields.** When a phase adds a key to an existing event variant's payload map, enumerate every consumer that reads that variant's payload — including OUTER-dispatch reducers beyond the immediate event-emitter's reducer. Two-consumer minimum: the direct `StreamCollector.apply_event/2` clause AND any chat-loop / session-loop outer reducer that reads the payload. Mechanical: `git grep ':<event_variant>' lib/` and verify every match has either (a) extraction of the new key in this phase's diff, or (b) a documented "no extraction needed" justification. Worked example: PHASE_18.3 enumerated three streaming-emit sites for `manual_tool_calls` but missed `Chat.apply_step_completed/2`'s `step_result_from_outer_collector/4`; Cell 3 of the stream test matrix HUNG until the `/4 → /5` extension landed in-commit.
15. **Wire-field map for provider adapters.** Provider-adapter designs MUST include a "Wire-field map" subsection enumerating per-provider: tool-call delta-field name (OpenAI `arguments`, Anthropic `partial_json`); tool-result envelope shape; stop-reason field path; usage location (top-level vs nested); content-filter signal location (HTTP status vs SSE delta finish_reason vs `stop_reason: "refusal"`). The map prevents implementer-time rediscovery of per-provider wire facts. Worked example: PHASE_11.2 implementer hand-derived `partial_json` (Anthropic's `input_json_delta` field name) at fixture-write time because the design treated it as implementation detail.
16. **Synthesized-vs-recorded wire-fixture policy.** The wire-fixture matrix MUST split into *response-shape fixtures* (recorded or synthesized; assert decode correctness) AND *request-shape contracts* (recorded request bodies OR live-validation runs; assert the adapter sends what the provider accepts). Synthesized fixtures cover documented shapes but cannot validate per-model rejection rules or request-side wire-shape divergences. Worked example: PHASE_10.5's BLOCKING live-validation surfaced three real bugs (closed-enum-vs-real-API, request-envelope divergence, endpoint-override bug) that the entire 1252-test wire-stub matrix missed.
17. **Detection-mechanism for state-conditioned behavioural deltas.** When a Decision names a behavioural delta conditioned on state ("first call only", "when tool result present", "on second turn"), the Decision MUST name the detection mechanism — message-history scan, session flag, opts marker, or explicit sentinel. "How to detect X" is consistently left to the implementer when "what to do on X" is design-named, producing per-implementation heuristics that couple adapter behaviour to invariants outside the adapter's scope. Worked examples: PHASE_11.1's retry-status widening (closure vs policy?), PHASE_11.2's `partial_json` accumulation key, PHASE_11.3's multi-turn de-injection (assistant-`metadata.tool_calls` scan vs `:tool` message scan vs session flag).
18. **Provider-neutral examples `_helpers.exs` template.** Phases that introduce or extend the `examples/` framework MUST specify the helper's contract: `@providers` map (provider env-var → `{adapter_module, default_model, key_env_var}`); `engine/1` constructor reading `ALLM_PROVIDER` (default first row); centralized `EnvLoader.load(...)` of project-root `.env` BEFORE key validation; `extra_opts` keyword merged onto baseline (`temperature: 0`, default `tool_executor`/`tool_result_encoder`); `ALLM_MODEL` override; clear failure modes for missing key / unknown provider / unloaded adapter. Worked example: `examples/_helpers.exs` (Phase 11.4) is the canonical reference.
19. **Live-API cost estimation.** Designs that drive live API calls MUST enumerate per-call token budget + per-1M-token pricing + projected total per provider, AND distinguish *per-clean-run cost* (steady-state review-pass) from *first-implementation cost* (2-4× the per-clean-run cost, accounting for debugging passes). Implementer reports MUST cite actuals against the estimate. Worked examples: PHASE_10.5 estimated $0.05/clean-run; first-implementation cost ~$0.10-0.15 (3×). PHASE_11.4 estimated $0.05+$0.08 = $0.13/run; actuals matched within $0.01.
20. **Line-cite drift mitigation in multi-sub-phase designs.** When a phase has ≥2 sub-phases each touching the same file, prefer **helper-name + arm-description** cite shapes over bare line numbers. A cite like `"transition_a_to_b/1's cond block, mode == :auto and response.finish_reason == :tool_calls arm"` survives both pre-sub-phase line drift and within-sub-phase additions; `"chat.ex:1396"` doesn't. Line numbers may accompany helper-name cites for first-time-reader convenience but the helper-name is the load-bearing locator. Defer batch cite-refresh to the FINAL sub-phase. Worked examples: PHASE_18.1 retro F5 (4-line drift), 18.2 F2 (`chat.ex:1184` ambiguity), 18.3 F3 (+30/+116/+123 drift), 18.5 F2 (12-cite final-sub-phase batch refresh validates the pattern).
21. **Spec amendments stamp a commit-range provenance.** When a multi-sub-phase phase amends the spec at the final sub-phase, every amendment block opens with `> **Phase N amendment (commits <first-sha>..<last-sha>).**` — readers can `git show <range> -- lib/` to surface the exact code that motivated the amendment. Citing a single commit is insufficient when implementation spans multiple sub-phases. Pair with the existing "cite a file:line in `lib/`" rule. Worked example: PHASE_18.5's four spec amendments (§5.2, §10.5, §12.4, §17) all cite `2a7fa7c..f56cfa6`; pre-Phase-18 amendments lack the range.

22. **Comparative claims must quote, not cite.** A cite proves a location; only a quote proves the claim. Any sentence asserting that new code "matches", "mirrors", "is the analogue of", or is "the same shape as" existing code must include the two-to-three relevant lines of that existing code inline. These are the claims an implementer trusts hardest, because they are how a phase inherits convention — and they fail independently of whether the cite's line number is current. Worked examples, both struck in-commit during PHASE_20.3: (a) `embedding_count`'s error-path absence was justified as "matching `image_count`", but `image_stop_extras({:error, _})` emits `image_count: 0`; (b) `drop_embedding_request_opts/1` was called "the outbound analogue mirroring `drop_request_opts/1`", which is actually the image path's **inbound** filter. Both cites resolved to the correct file and concept, so spot-checking cite *locations* cannot detect either.
23. **A committed signature must name the channel for every value the function needs.** When a contract block freezes an arity, enumerate how each value the surrounding prose requires actually arrives: parameter, opts key, module attribute, or process state. A block can be complete on its face, type-check under its own `@spec`, and still be silent on a required channel — the gap surfaces only when someone tries to call the function, by which point the frozen arity has foreclosed the alternatives. Worked example: `ALLM.EmbeddingBatch.run/4` was committed at four arguments while the same section required per-chunk `Retry.run/3`, with nothing saying how the policy crossed the boundary; of the implementer's three options (a `run/5` contradicting the contract, a duplicated reason list, or smuggling it through `dispatch_opts`) only the third remained available.
24. **A load-bearing value is stated ONCE per design doc, and a `@spec` narrower than its body must name its enforcing gate.** When a contract block and a per-phase checklist both name the same Dialyzer-sensitive type, default, or atom, they drift — the intra-doc variant of the drift classes above. The checklist *references* the contract block ("add `:id` per the contract block"), it does not re-quote the value. Separately: Dialyzer will not flag a narrowing that merely overlaps (`pos_integer()` declared over a `non_neg_integer()` body), so the promise reads as compiler-checked when it is convention-checked — state which gate enforces it and what happens when a caller bypasses that gate. Worked examples: PHASE 1 of the footgun design specified `:id` as `integer()` in the contract block and `pos_integer() | nil` in the 1.2 checklist; `EmbeddingResponse.dimensions/1` is spec'd `pos_integer() | nil` but computes `length(vector)`, holding only because adapters must reject `vector: []` — a rule that binds adapters, not the callers who construct the public struct directly.
25. **The Module Tree is authoritative on sub-phase attribution.** When a contract-section code block enumerates an edit spanning more than one sub-phase, tag each line with its sub-phase (`# 20.2`) or omit the block and defer to the Module Tree. Worked example: PHASE_20's serializer-registration block listed four `@known_modules` entries as one Layer A unit while the Module Tree split them 3 (20.1) + 1 (20.2); registering the 20.2 entry early would have compiled **silently** — an undefined module atom in a list literal produces no warning, and no test asserts registry membership against loadable modules.
26. **A conformance case's driver may not be chosen on the basis of a claim about unwritten code, and an optional fixture may never be a case's only assertion.** Test-vehicle decisions are validated against the phase's own reference implementation (`Fake*`), which exists by definition. If a case body is `if fixture = optional() do … end`, it must also assert unconditionally against the caller-supplied implementation — ExUnit does not flag an assertion-free test. Worked example: PHASE_20's contract section asserted "the script short-circuit fires before the gates, so a scripted adapter can never reach its own guards" — true only *with* a script — and derived that conformance cases 3 and 4 be driven by a sister stub under `conformance/test/support/`, which resolves to `nil` for every main-project consumer and every external adapter author. Both cases would have compiled to an empty `if` body: assertion-free, reported green, in a *published* conformance package.
27. **Re-read every Test Plan bullet against the contract sections after locking them.** Test Plan bullets are derived artifacts and drift from their sources silently; a bullet that re-states a mechanism (rather than citing the section that owns it) is the drift surface — delete it or cite it. This is the third catalogued sibling of type-contract-vs-test-plan drift and test-bullet-vs-test-vehicle drift; PHASE_20 alone produced six instances across four sub-phases. Worked example: PHASE_20's 20.2 Test Plan gated conformance cases 3/4 on "a `Req.Test` stub fails the test if called" while the contract section 62 lines earlier states in bold that `:plug` is absent from `conformance/mix.exs`.
28. **Constraints a sub-phase binds on later sub-phases get one home.** When an implementation pass discovers something that must hold later (a wire-shape rule, a test-vehicle substitution, a lint trap, a security divergence), it goes in a terminal `#### <phase>.N Binding on later sub-phases` block — a bullet list, each item naming the target sub-phases and the file:line of shipped code demonstrating it. Not scattered through checklist parentheticals and deviation bullets. The mechanism works (PHASE_20.2's "guards must fire ahead of `ALLM.Keys.fetch!/2`" reached 20.4 intact and is pinned by a purpose-named test), which is exactly why it needs a checkable location: the Phase 20 design carried eighteen forward-binding phrases in five formats across five sections, with no way to tell whether a later sub-phase collected them all.
29. **`/ddesign` revision-drift checklist.** When the devil's-advocate pass renames a module, drops a proposed helper, or changes a breaking-vs-non-breaking classification, re-flow the revision through every tail section: Module Tree rows, contract blocks, Verification snippets, "Breaking Changes Summary", Definition of Done. The body of the design gets the revision; the tail does not. Symptoms: a Module Tree row naming a file no later section references; a Breaking Changes Summary claiming N changes while Type Contracts shows N−1; a Path-existence sanity-check block contradicting the Module Tree above it. Related: **a design referencing repo conventions** (CHANGELOG headings, commit tags, file paths) MUST cite the `head`/`grep` invocation against the actual tree confirming the convention exists as written — RELEASE_PLAN specified an `## [Unreleased]` rewrite without checking that `CHANGELOG.md` uses `## [TAG] Phase X`, which would have aborted the first real publish. And **`(verified in IEx on <date>)` annotations must cover both branches of the change** — the input that triggers it AND the fast-path input that does not; a unilateral verification leaves the other branch as an implementer surprise.
30. **Bulk-rewrite phases ship the rewriter, and Phase-0 inventories record test *formats*.** When a phase touches >10 files mechanically, the design enumerates the rewriter as a deliverable alongside the audit script, or states explicitly "hand-edit; bulk transforms are not in scope" — don't leave the implementer to invent an unreviewable throwaway that is less strict than the project's own audit. Separately, a pre-flight inventory listing test files a rewrite must keep green is incomplete without **what format each pins** (substring match, full eval, doctest consume-style vs construction-only); subsequent phases then preserve the format or justify a change in the design rather than the implementer's report.
31. **Every phase's Verification block is uniform**, including `mix format --check-formatted` and `mix test --seed 0` — not just the final phase's. And **a helper introduced in phase N but first called in phase N+1 ships as untested dead code at phase N's gate**: either add a direct unit test for the pure helper in phase N (preferred — it keeps the module change cohesive), or co-locate the helper with its first caller in N+1.
32. **Out-of-Module-Tree debt needs a tree.** A multi-sub-phase design ends with an explicit `[CHORE]` sweep sub-phase carrying its own Module Tree. Every deferral that terminates in an `/asks` ticket accumulates otherwise: the Phase 20 build closed at 16 tickets filed / 1 resolved, with all three tickets naming 20.7 as their deadline unactioned, because 20.7's Module Tree was docs-only and the Module Tree won.

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

**Module Tree completeness invariant.** Every NEW or MODIFY file the phase touches MUST be enumerated in the Module Tree with a `(NEW — N.M)` or `(MODIFY — N.M, <one-sentence rationale>)` tag — including test-support and test files. When a phase's Test Plan asserts an error tuple, dispatch path, or runtime behaviour that depends on a v0.2 internal rescue/match/dispatch path catching a class of exception or value, the Module Tree MUST enumerate the v0.2 file containing that path as MODIFY, AND the Implementation Checklist MUST name the extension as a discrete deliverable. The completeness invariant: `git diff --stat <pre-phase>..<post-phase> | wc -l` should equal the Module Tree entry count for that phase ± 1 (CHANGELOG.md is the typical off-by-one). Worked examples: Phase 13.1+13.2 asserted `Serializer.from_json/1` would return a typed `ValidationError` for corrupted base64; this required extending `Serializer.hydrate_with/2`'s rescue from `ArgumentError`-only to also catching `ValidationError` — the Module Tree didn't enumerate it; surfaced via failing test. Phase 14.4 (largest blast radius, complete tree) hit zero "discovered new file mid-phase" surprises.

**Repo-wide audit-gate obligations are per-commit, never deferrable.** This repo runs several gates that fire on *any* commit landing a public module, facade function, or guide. Before locking a Module Tree, check each against the phase's new artifacts and add a MODIFY row to EVERY sub-phase that lands one:

| Gate | Fires on | Failure mode |
|------|----------|--------------|
| `test/groups_for_modules_audit_test.exs` | new public `lib/` module → `mix.exs` `docs.groups_for_modules` | **closed** (discovers modules from `lib/`) |
| `test/package_files_extras_consistency_test.exs` | new `guides/` file → `mix.exs` `package.files` + `docs.extras` | **closed** |
| `test/layer_a_docs_test.exs` | new Layer A struct → `@layer_a` literal | **open** (hand-maintained) |
| `test/allm_facade_doctest_inventory_test.exs` | new public `ALLM` function → `@public_facade` literal | **open** (hand-maintained) |
| `test/guides_test.exs` + `test/guides_doctest_test.exs` | new guide → each file's own `@guides` / `doctest_file/1` list | **open** (hand-maintained) |

A Module Tree row deferring one of these to a later sub-phase is structurally wrong. Fail-closed gates merely break the phase's own "`mix test` zero failures" criterion. **Fail-open gates ship a silent gap** — a subject absent from a hand-maintained list is never checked, so the defect the gate exists to catch reaches `main`. Fail-open gates therefore need the explicit row most, and per `CLAUDE.md` each wants a meta-test asserting its literal against a discovered set. Worked example: PHASE_20 assigned `mix.exs` `groups_for_modules` to 20.7; the fail-closed gate broke 20.1 immediately and the tree was amended in-commit. The same design never mentioned `test/layer_a_docs_test.exs`; its three new Layer A structs went unregistered and all three shipped banned `(spec §36.2)` tokens in their user-facing `@moduledoc`.

**Path-existence sanity check.** When authoring a Module Tree, `ls` the parent directory of every NEW file path before locking the design. Typos and copied wrong directory levels force the implementer to either invent a new convention or silently re-locate the file. Worked example: PHASE_17 §3.5 line 376 specified `test/fixtures/openai/chat_completions/synthesized/vision_assistant_image_output.exs`; the parent directory does not exist on disk; shipped at `test/fixtures/openai/synthesized/vision_assistant_image_output.json` (one fewer dir level + `.json` extension). One-line check would have caught both the path and the `.exs`-vs-`.json` deviation.

### 5. Phases

Break into ordered phases. Each phase **must**:

- Touch a single layer (call it out — A/B/C/D).
- Be independently shippable: after the phase, `mix test`, `mix credo --strict`, and `mix dialyzer` all pass; public API is consistent (no half-defined functions, no callbacks without implementations).
- Have 4–8 checkboxes — split into sub-phases (1.1, 1.2) if larger.
- Begin with **a Test Plan**, not an implementation sketch (TDD).
- End with a **Verification** sub-section listing exact commands.
- **File structural stability across sub-phases predicts cite-stability.** A target file untouched by sub-phases between design-time and the consuming sub-phase has near-zero drift risk; a target file modified by intervening sub-phases has high drift risk that compounds within each modifying sub-phase. Mitigation: ORDER sub-phases so each target file is touched in as few consecutive sub-phases as possible (ideally one). Worked example: PHASE_18 touched `tool.ex` (only 18.1), `chat.ex` (18.2 + 18.3), `session.ex` (only 18.4); the single-sub-phase files had near-zero cite drift, the dual-sub-phase file had +30/+116/+123 line drift between 18.3 design-time and implementation.

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
- [ ] Reviewed via `/review` (see `agent-spec/REVIEW.md`)

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
