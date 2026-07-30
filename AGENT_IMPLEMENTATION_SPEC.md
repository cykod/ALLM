# Implementation Spec Guidelines — ALLM

How to implement design documents in the ALLM Elixir library. The `/implement` skill reads this file automatically.

## Workflow

### 1. Start Green

Before writing any code, confirm the tree is green:

```bash
mix deps.get
mix compile --warnings-as-errors
mix format --check-formatted
mix test
mix credo --strict
mix dialyzer
```

All six must pass with zero failures and zero warnings. Pre-existing failures blur the signal on new regressions — if anything fails, **stop and ask the user**. Never normalize a failing baseline. "Two pre-existing failures" is exactly where new failures hide.

If the design touches the streaming runner, also confirm:

```bash
mix test test/allm/providers/fake_conformance_test.exs
```

**Baseline-repair allowance.** If Start Green fails because of a *pre-existing* scaffolding issue outside the current sub-phase's edit scope (unformatted file from initial commit, version-constraint typo in `mix.exs`, broken doctest in unrelated module), resolving it is **baseline repair**, not normalizing a failing baseline. Allowed under three conditions:

1. Touch only what's necessary to turn a failing gate green. Formatting, dep cleanup, scaffold typos — no refactors, renames, semantic changes.
2. Land as a separate commit `chore: baseline repair for <sub-phase> (<gate>)`, before sub-phase work begins.
3. The user authorizes each distinct repair category. If multiple issues, enumerate them all in one round-trip.

The "never normalize" rule stays in force for *mid-phase* failures (a regression from current sub-phase tests is a real regression).

### 2. Read the Whole Design First

Read the entire design doc before writing code. Understand:

- The four-layer assignment of every phase
- How phases depend on each other
- The Test Plan for every phase (these are the tests you write first)
- The Error Contract — every reason and recovery
- The Definition of Done

Implement one phase at a time, in order. Build order in spec §28 is load-bearing. Check the status table — `Completed` rows are done.

### 3. Ask When Uncertain

Stop and ask via `AskUserQuestion` if anything is ambiguous, has multiple valid implementations, or conflicts with the codebase or spec. Common cases:

- Design specifies an event variant or callback that conflicts with `steering/allm_engine_session_streaming_spec_v0_2.md` — spec wins.
- A phase touches more than one layer with no justification.
- An `@spec` uses `term()` for an error type instead of a struct.
- The design adds `middleware:` (reserved for v0.3 — §29).
- A behaviour callback isn't reflected in `ALLM.Providers.Fake`.
- Two valid strategies (e.g., `Stream.resource/3` vs GenServer-backed) and design doesn't specify.
- A Test Plan test depends on API surface that doesn't exist (phase out of order).

### 4. Per-Phase Loop (TDD)

For each phase, in order:

1. **Mark the status table row `In Progress`.**
2. **Write the Test Plan tests first.** Run `mix test path/to/new_test.exs` and confirm they fail with the expected error (usually `UndefinedFunctionError` or assertion failures, not compile errors). A test that fails for the *wrong* reason is broken, not failing.

   **Test Plan is a coverage floor, not ceiling.** Cross-reference the Behaviour & Type Contracts (or Invariants) section. Invariants named there but not in the Test Plan are tests you must add. Common misses: first-halt-wins on tagged-union folds, encoder-fallback cascades, invalid-return dispatch fallbacks, bounded `max_concurrency` peak guarantees. Worked example: Phase 6 Batch 1 shipped 46 tests vs. ~18 Test Plan bullets, the delta covering Contracts-section invariants.
3. **Implement the minimum code to pass.** Don't add functions, fields, or branches the tests don't exercise. If the design specifies functionality the tests don't cover, the Test Plan is incomplete — go back to step 2. **Second-caller promotion check.** The trigger is **semantic, not byte-level** — a clone differing only by an added fall-through clause, a guard, or `def`-vs-`defp` visibility is a clone. Grep for the *name* and read the bodies; a byte-identical grep misses the most common divergence. **When the phase's Module Tree forecloses the consolidation, the Module Tree wins** — record a one-line `[DEFERRED-DRY]` entry in Implementation Notes naming every trigger site, and file it in `ASKS.md` with a grep predicate. Worked example: `drop_comment/1` reached two implementations at Phase 16 (the second carrying an extra `defp drop_comment(other), do: other` clause that defeated a byte-identical grep) and a third at Phase 20.4; the trigger never fired across four months. When implementing a private helper, grep for byte-identical clones in other modules. If found, promote `defp` → `def @doc false` (with `@spec`) and call from both sites in the same commit. Two implementations IS the trigger — don't wait for three. Worked example: `Chat.chat_step_done?/1` and `Chat.chat_merge_halt_metadata/3` (batch 7.4) were byte-identical clones of `StreamCollector` private helpers; promoted in pre-batch-4 prep. **Foreseen second callers are an authoring decision, not a promotion.** When a private helper is *known* at design time to have a second caller in a later batch (cross-module dispatch, streaming/non-streaming pair sharing a helper), land it as `@doc false def` from the start, not `defp` then promote. The promotion path is for *unforeseen* second callers; foreseen ones are designed in. Worked example: PHASE_8's `Session.apply_chat_result/2` and `apply_step_result/2` were authored as `@doc false def` because the design knew `Session.StreamReducer.finalize/1` (Batch 2) would call them across the module boundary — Batch 1 landed them at the right visibility from day one, and Batch 2 used them with no promotion step.
4. **Focused suite green** (`mix test path/to/new_test.exs`).
5. **Full suite green** (`mix test`). Fix any regression before continuing.
6. **Quality gates** (`mix format`, `mix credo --strict`, `mix dialyzer`). Zero issues. **Before gates, re-grep touched modules for private helpers whose only callers were rewritten functions; delete unused helpers in the same commit.** `--warnings-as-errors` catches `def` but not `defp`. Worked example: Phase 7.1's `to_chat_result/1` rewrite stranded `halted_reason_for_finish_reason/1`.
7. **Update doctests.** Every public function added or modified gets a `@doc` with at least one runnable example using `ALLM.Providers.Fake` (Phase 4+) or pure Layer A construction (Phase 1). One doctest per public function is the floor; add a second when there's a meaningfully different branch (default-message vs. `:message` override, happy vs. common-rejection, empty vs. populated). Don't add doctests that only vary input — those belong in the test file. Run `mix test --include doctest`.
8. **Check off `[x]` in the design doc.**
9. **Mark the row `Completed`.** Only when (a) all checkboxes done, (b) all Test Plan tests pass, (c) all gates pass, (d) public API is consistent (no half-defined functions). Else `In Progress`.
10. **Document deviations** in a brief Implementation Notes line. Undocumented deviations are the problem.
11. **Commit citing spec section**: `Phase 4: stream_generate/3 over Fake (§3, §4, §8)`.

### 4a. Tactical vs. structural inference

When the design names a rule and trigger but leaves the Elixir-idiom choice — atom naming for a `{field, reason}` tuple, defensive clauses for string-keyed vs. atom-keyed maps, which error atom to pick when "out of range" is unspecified — pick the idiomatic choice and move on. Log it in Implementation Notes as `[tactical] <one-line>` for review-step audit. Don't halt the loop for round-trip on tactical naming.

**Structural inferences are NOT tactical.** `@enforce_keys`, `defexception` fallback clauses, `@derive` vs. `defimpl`, `String.to_existing_atom/1` vs. `String.to_atom/1`, `Stream.resource/3` vs. `Stream.unfold/2`, changes to documented deny-/allow-lists (e.g., adding to `@engine_field_keys`, removing a closed-reason atom), **or changes to a documented `@type state` / `@type t` / `defstruct` field set (rename, drop, add, default change)** — are test-observable invariants belonging in the design's Behaviour & Type Contracts section (`AGENT_DESIGN_SPEC.md §3`). Stop and request a design amendment.

**Struct-field changes especially must round-trip** because the design often authors a field for a *future* phase. Dropping it as "unused now" silently forecloses the downstream landing zone. Worked examples: Phase 5's `:steps: [StepResult.t()]` exists for Phase 6's `:step_completed` fold accumulator; Phase 5's `:last_response: Response.t() | nil` exists for Phase 7's `:chat_completed` reference. Dropping either is a decision for Phase 6/7 without flagging.

**Structural safeguard-addition exception.** When the design omits a structural invariant whose absence creates silent-drift risk (a conformance-suite case-count without introspection, a mirror module without a file:line cite, a validator whose accept set is tighter than what the harness actually passes), the implementer MAY ship the safeguard as a structural deviation with `[structural, documented]` annotation and rationale linking to the drift risk. Retro evaluates promotion to spec. Halting on missing-invariant gaps is optional; halting on wrong-call structural deviations (design says X, implementer wants Y) is still required. Worked examples: Phase 3 Batch 3's `@case_count` + meta-test addition; Phase 4.1's `deltas:` MapSet for tool-call re-parse scoping.

### 4b. Between-sub-phase retro application

If a sub-phase retro names "apply before sub-phase X+1 starts" (or otherwise cites a sub-phase boundary as deadline), run `/apply-retro` BEFORE starting the next sub-phase — don't defer to the phase boundary. Sub-phase-scoped findings have shorter time pressure than phase-scoped ones; a finding whose cost compounds across a sub-phase boundary is exactly the class that breaks "retro cadence is positive." Worked example: Phase 5's `wait_for/2` extraction (5.2 F1 named the fix with deadline "before 5.3 starts," deferred to phase boundary, and 5.4 + Phase 6 Batches 1–3 each paid an incremental cost).

Phase-boundary `/apply-retro` stays the default for findings without an explicit sub-phase deadline.

### 4c. CHANGELOG cadence

During pre-1.0 multi-sub-phase work, group `## Unreleased` entries by sub-phase subheading (`### Phase 1.1 — Error Hierarchy`, …) with Added/Changed/Fixed nested. Keeps Unreleased scannable at mid-phase checkpoints when flat Keep-a-Changelog accumulates 15+ bullets across three categories with no temporal grouping.

Flatten to standard Keep-a-Changelog post-1.0, when release frequency matches entry frequency.

### 4d. Steady-state velocity rubric

After the first 1–2 batches establish conventions, subsequent batches should land in one pass with:

- **No-op Start Green** — pre-flight green, no repair.
- **One-pass implement** — no mid-flight blockers.
- **≤2 small deviations** — small means tactical per §4a.
- **Monotone global coverage** — new code ≥90%, global doesn't dip. Prose-only additions (`@moduledoc`/`@doc` text around doctests) may drift global ±0.1% (excoveralls counts iex lines but not surrounding prose). Per-module new-code coverage is load-bearing; integer-level global dip from prose is noise.

A batch exceeding 2 deviations, ≥1 structural inference, or causing a global dip indicates a design-doc gap. Run `/retro` and `/apply-retro` before the next batch — compounding gaps across batches gets you to Batch N with three unfixed issues.

### 4e. Combining adjacent sub-phases

Adjacent sub-phases targeting the same layer with no behavioural dependency (Test Plans don't reference each other's types, one's public API doesn't consume the other's output) may be combined. Start Green runs once, CHANGELOG sub-phase subheading covers both, commit narrative stays coherent.

Keep split when targeting different layers, or when one's public API is a dependency of the other (e.g., `ALLM.Validate` returns `%ValidationError{}` from `ALLM.Error` — ordered, not combinable). When in doubt, split.

**Private-helper-contract coupling.** Before combining N sub-phases, enumerate the private helpers each sub-phase calls into. If the same helper appears in ≥2 sub-phases' call graphs, the helper's contract must be named in the design's Behaviour & Type Contracts with both accept sets — otherwise one sub-phase's needs can pull the helper in a direction that breaks the other. A widen-on-demand (relaxing a validator mid-batch because one caller needs a wider accept set) is symptomatic. Public-API dependency isn't enough; shared private helpers also need agreement.

### 4f. Constructor test pattern

To assert "required positional args raise `ArgumentError`", use `Mod.new(nil)` — not `apply(Mod, :new, [])`. Credo's `Refactor.Apply` flags `apply/3`; `nil` falls into the function's reason-validation path and produces the same `ArgumentError`. The `@spec` guarantees arity.

### 4g. Credo gates likely to bite

`mix credo --strict` is a release gate. Write the satisfying shape first.

- **`Refactor.Apply`** — `apply/3` disallowed. Constructor-arity assertions use `Mod.new(nil)`. Optional-dep dispatch uses `Module.concat(["OptionalMod"]).fun(arg)` (see §Common Pitfalls).
- **`Refactor.CyclomaticComplexity`** (threshold 9) — ≥9 independent decision points (if/case/guard/and/or chains, multi-branch `cond`). For flat sequences of guards or `if-raise`, extract one guard per private helper. Worked example: `ALLM.Providers.Fake.Script.validate!/1` at `lib/allm/providers/fake/script.ex` (five guards via `validate_list_opt!/4`).
- **`Refactor.ABCSize`** (threshold 30) — closely related; same fix.
- **`Refactor.LongQuoteBlocks`** (threshold 150) — `quote do…end` inside macros. For conformance harnesses, push helpers out of `quote` and expose as `@doc false def`s; the caller's quoted code invokes them via `unquote(__MODULE__)`.
- **`Refactor.Nesting`** (threshold 2) — deeply nested case/if/cond/with (`case in if in case` is canonical). Fix: (a) flatten to `with`-chain for short-circuit validation, (b) extract private function for inner branch, (c) pattern-match function heads. Worked examples: `lib/allm/stream_runner.ex` flattens to `with :ok <- a, :ok <- b, :ok <- c do …` (Phase 5.2 self-correction); `test/allm/stream_equivalence_test.exs`'s `do_stream_and_collect/1` + `collect_if_ok/1` (Phase 5.4).
- **`Readability.StringSigils`** — double-quoted strings with multiple escapes suggest `~s()`. Apply in test names embedding JSON.

### 4h. Pending tests for deferred phases

When a test file holds scenarios not yet implementable, use `@tag :pending` + `:ok` body + one-line deferred-phase comment:

    @tag :pending
    test "§31 scenario: max_turns cap (Phase 7)" do
      # Phase 7 introduces the orchestrator loop bound.
      :ok
    end

`test/test_helper.exs` configures `ExUnit.start(exclude: [:pending])`. Run with `mix test --only pending`. `--only <tag>` overrides exclude, so `mix test --only spec_31` on a mixed-tag file still surfaces pendings. When implementing a deferred scenario, delete `@tag :pending` AND the `:ok` body together — never leave the tag above new assertions.

### 4i. Closed-enum dual-validation (protocol vs provider acceptance)

Closed enums whose values pass through to a provider (e.g., `@effort_atoms`, future `@thinking_budget_atoms`) MUST distinguish *protocol-level legality* (ALLM accepts the value) from *provider-side acceptance* (provider may reject per-model). Either: (a) split into a protocol enum (validated by `translate_options/2`) AND a per-model acceptance table (validated by the provider, surfaced as `%AdapterError{reason: :invalid_request}`); OR (b) document at the enum's declaration that "values are protocol-legal; provider-side acceptance varies per model." Worked example: PHASE_10.6's `@effort_atoms = [:none, :minimal, :low, :medium, :high, :xhigh]` includes `:minimal` (legal in OpenAI's docs) but `gpt-5.5` rejects it at runtime; surfaced only at PHASE_10.5 live-validation.

**4j. Bounded `max_turns` on streaming-chat-loop tests.** When writing tests for new streaming-chat-loop terminal conditions or halt reasons, configure `max_turns: 2` (or similarly low) on the test fixture's engine/options. A missing terminal-condition signal otherwise manifests as an unbounded loop hitting ExUnit's 60s timeout — diagnosable but slow, with the failure reading as "test hangs" rather than "expected halt :X, got halt :Y." With `max_turns: 2`, a missing terminal manifests as a clean `result.halted_reason == :max_turns_reached` assertion failure. Worked example: PHASE_18.3 Cell 3 hung for 60s when `step_result_from_outer_collector/4` ignored the new payload key.

**4k. Layer-D session tests drive through `Session.{start,stream_start,continue,submit_tool_result}/N` AND `Session.StreamReducer.{new,apply_event,finalize}/N` — not through Layer-C `Chat.{run,stream}/N` directly.** Layer-D's public seam is the contract Session callers bind to; tests bypassing it risk false positives (Layer-C invariants holding while Layer-D's projection is broken) and false negatives (Layer-D masking a Layer-C divergence). Streaming Session tests MUST drive through `Session.stream_start/3 → Enum.to_list(stream) → StreamReducer.{new,apply_event,finalize}/N`. Each layer tests through its own public surface. Worked example: PHASE_18.4's three streaming Session test cells at `test/allm/session_per_tool_manual_test.exs:235-333`.

**4l. Relaxation/strip-set tables co-locate with the property that enforces them.** When a property test asserts equivalence between two arms with a strip-set or relaxation set (e.g., `assert_equivalent_chat_result/2`), the file MUST carry an inline `@moduledoc` table documenting each relaxed field with: (i) field path, (ii) relaxation type ("none — both arms identical", "stripped before assertion", "transformed via `<helper>`"), (iii) justification, (iv) risk level. Relaxation budgets in design docs aren't read at test-failure time; the test file is. Worked example: `test/allm/chat_equivalence_test.exs:54-59` (PHASE_18.5 origin).

**4m. Pair equivalence properties with explicit per-fixture absolute-shape tests.** A property asserting `assert_equivalent_X(arm_a, arm_b)` passes when BOTH arms produce identical results — including the degenerate case where BOTH arms are identically broken (symmetric regression). For each "shape variant" the property exercises (key-present-with-shape-X, key-absent, key-empty), add at least ONE explicit non-property test asserting the absolute shape on BOTH arms. Worked example: `test/allm/chat_equivalence_test.exs:367-410` (PHASE_18.5) pairs the chat-equivalence property with three per-fixture explicit tests including a `refute Map.has_key?` negative pin against Decision #12.

### 5. Quality Gates After Every Phase

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test                              # zero failures, ≥80% coverage globally
mix test --seed 0                     # order-independence; see CLAUDE.md on what a seed does NOT bind
mix test --cover --include doctest    # confirm doctests run
mix credo --strict                    # zero issues on changed files
mix dialyzer                          # zero new warnings vs. prior PLT
```

Pre-existing dialyzer warnings: document in Implementation Notes but don't normalize.

**`mix docs` "no warnings" claims need a grep gate, not an exit code.** `mix docs` returns 0 even when it emits cross-reference warnings (broken `Module.fun/arity` links, hidden-module refs, missing typespec refs), so `mix docs && echo OK` says nothing. When a phase touches docstrings or guides, gate on `mix docs 2>&1 | tee /tmp/mixdocs.log; ! grep -qE '(warning|error)' /tmp/mixdocs.log` — and record the pre-existing count, because a phase adding a link to a `@doc false` function creates a warning that will never resolve. Worked example: REBUILD_DOCUMENTATION ran `mix docs` per phase without gating; 14 cross-ref warnings accumulated silently across seven phases and surfaced only at the final sweep.

**"Docstrings-only" rewrites need a heredoc-scoped rewriter, not just a heredoc-scoped audit.** When a phase's Module Tree authorizes `@moduledoc`/`@doc` rewrites but excludes `def`/`defp` body comments, the bulk pass MUST scope its edits to docstring heredocs using the same state machine the audit script uses — the verifier-and-rewriter-share-a-tracker invariant is what makes "I only touched docstrings" verifiable. Worked example: a 63-file rewrite used a private throwaway that didn't track heredoc context, so 106 body-comment lines shipped against the design's stated invariant; `scripts/check_lib_diff_non_doc.exs` caught them post-hoc and should exit 1 rather than merely printing.

**A capability's docs sub-phase is its first usability test.** Every prior phase drives the reference `Fake*` adapter from tests written by someone who already knows the semantics; the guide is the first artifact written from the position of a user who does not, and it should be EXPECTED to produce API-shape findings rather than only prose. Route those as findings — fix the origin module's own docs in the same commit rather than leaving the guide and the moduledoc disagreeing. Worked example: PHASE_20.7's guide doctest was first drafted scripting `{:error, %EmbeddingAdapterError{reason: :rate_limited}}` — the obvious choice — and failed with `:unknown`, because the façade's widened retry policy consumes a scripted retryable error, retries, exhausts the script and surfaces `:no_scripted_embedding`. Six phases of tests over the same module never hit it.

**"Fix-the-docs" phases go red-first; don't pre-transcribe corrections.** For a phase whose job is correcting drifted guide or `@doc` examples, the design's "Corrected" column is a CLAIM, not a fact. Stand up the `doctest_file` harness as a RED baseline first and let the failures dictate the corrections, rather than pre-specifying replacement values from an audit summary. Worked example: Phase 21 Batch 1's design pinned four values that executed reality contradicted (including one that was a doctest *compile* error), each becoming a correct-the-correction cycle in the implementer's commit.

**Coverage:** global threshold 80% (`mix.exs`). New code ≥90%. Inspect `cover/excoveralls.html`.

### 6. When All Phases Are Complete

Summarize:

- Files created/modified (exact paths)
- Deviations and why
- Public-API additions (functions, behaviours, structs, event variants) — each a CHANGELOG entry
- Test count delta (`mix test` reports total — record before/after)
- Coverage delta
- IEx manual-verification recipe:

```elixir
iex -S mix
iex> engine = ALLM.Providers.Fake.engine(messages: [...])
iex> {:ok, response} = ALLM.generate(engine, ALLM.request([ALLM.user("hello")]))
iex> response.content
```

Real provider adapters: include a smoke test gated by `@tag :integration`.

## TDD: The Non-Negotiables

1. **No production code without a failing test.** Stop, write the test, watch it fail, write the function.
2. **Test must fail for the right reason.** Module-doesn't-exist is good; typo-in-test is broken. Read the failure before "fixing."
3. **Make the test pass with minimum code.** Don't anticipate the next test by adding branches. The next test will tell you what's missing.
4. **Refactor with green tests.** Once green, extract/rename/simplify — but only with green. If a refactor breaks a test, the refactor is wrong.

PRs that ship implementations without tests are blocked.

## Test Patterns Per Layer

### Test file organization

Every `lib/allm/<path>.ex` gets `test/allm/<path>_test.exs`. Don't combine tests for multiple modules into one file. Shared fixtures go in `test/support/`. Property tests live alongside as `test/allm/<path>_property_test.exs`.

The 1:1 mapping keeps lookup trivial and prevents one file from accumulating every "related" test. A module that doesn't justify its own test file usually doesn't justify its own source file.

**`@moduledoc false` struct-only exception.** A `@moduledoc false` module defining only a struct (no public behaviour, no public functions beyond `__struct__/0`) does NOT require a 1:1 test file — it's exercised through its consumer's tests. Note the consumer test as covering both. Worked example: `lib/allm/chat/loop_state.ex` covered via `test/allm/chat_run_test.exs`.

**Shared test helpers.** Promote a cross-test-file helper into `test/support/` the moment a second file references it. Apply the two-copies-triggers-extraction threshold to:

- **Async/timing** (`wait_for/2`, `poll_until/2`, timeout-scoped assertions) → `test/support/async_helpers.ex`.
- **Fixture builders** (Fake scripts, engine constructors with default options, canned messages) → `test/support/fake_fixtures.ex`.
- **Common assertions** (multi-step event sequences, struct-field-diff) → `test/support/assertions.ex`.

**LLMDB `@fixtures` capability maps populate ONLY the keys the fixture's tests exercise.** Absent keys are treated as "no info" by `Capability.preflight*` functions; defensive dummy padding (`tools: %{enabled: false}` on an image-only fixture) is sprawl, not safety. Phase 14.3's three new image fixtures padded `tools` and `json_native` despite neither being relevant to `preflight_image/2` — six dummy LOC. Future v0.4 audio fixtures: populate `audio_enabled` + `supported_audio_operations` only.

One-off inline helpers are fine for single-file use. Two copies is the moment to extract — each additional copy accrues silent divergence (helper names drift, magic numbers diverge, semantics fork). Worked example of non-extraction cost: `wait_for/2` exists in four places as of Phase 5.4 (conformance harness + `fake_stream_test.exs` + `stream_runner_test.exs` + `fake_scenarios_test.exs`) with the recursion-helper name already divergent (`do_wait_for/2` vs. `do_wait/2`), plus a `Process.sleep(50)` regression at `chat_stream_step_test.exs:472` during Phase 6 Batch 2.

**TODO-tag inline helpers slated for extraction.** When an inline test helper is annotated as "Batch N will lift to module X" (a known second caller is coming in a later batch), prefix the in-source comment with `TODO(<source-batch>→<target-batch>):` so a `git grep 'TODO(8.3'` audit at the target-batch boundary finds it. Comment-text-only annotations are fragile against grep. Trivial change; surfaces planned extraction debt as a mechanical pre-batch check.

Do NOT promote inline test-module-specific stubs (e.g., a one-file `@behaviour ALLM.Adapter` stub for one error path). Their scope is one file; extracting creates a dependency from support back into possibly-changing behaviour shapes.

**Migration on extraction.** When extracting a helper, the SAME COMMIT migrates ALL existing inline copies — not just newly-added call sites. Otherwise audits count the helper as "extracted" while N inline copies remain. Mechanical: `git grep '<helper_name>' test/` after extraction; only hits should be the new support module + new call sites. Worked example: pre-batch-3 prep extracted `AsyncHelpers.wait_for/2` and `FakeFixtures.engine/2` but the four pre-existing `wait_for/2` clones in `fake_scenarios_test.exs`, `fake_stream_test.exs`, `stream_runner_test.exs`, and `stream_adapter_conformance.ex` were not migrated — those clones still exist as of end of Phase 7.

### Assertions that bind, and the premise guard

**An assertion over decoder output binds the decoder only when some fixture violates the asserted property.** A test computing a property from real provider output and asserting it holds is asserting a fact about the *fixture* unless the code path is shown to reject a fixture that lacks it. Pair each such assertion with a deliberately-violating fixture, or drop the clause and say what actually enforces it. Worked example: Phase 20.4's invariant-8 test asserts uniform vector length across a three-entry response, but `decode_data_list/2` folds entries independently with no cross-entry length check, so a ragged body decodes cleanly; the cardinality and index clauses of the same test DO bind, because a sibling `shuffled_index_order.json` fixture is deliberately out of order.

**Name the premise guard and reach for it by name.** When an assertion is only non-trivial under a precondition about its *input* — a fixture is un-normalized, a directory holds live recordings and not placeholders, a harness does not simply echo what it was given — write a separate test asserting that precondition, **negatively**, with a failure message naming the test that would otherwise pass vacuously. A premise guard asserts a property of the input, never of the code, and it belongs immediately before the tests it protects. Three independent reinventions of the same idea: Phase 20.2's conformance cases that must not be satisfiable by an echoing harness; Phase 20.4's raw-byte `refute Map.has_key?(raw, "_comment")` over `recorded/` fixtures; Phase 20.5's `abs(magnitude(values) - 1.0) > 0.01` on the recorded 768-wide batch, so that if Google ever starts pre-normalizing truncated output the normalization pair goes red on a changed premise instead of green on a dead test.

**"Delete the defensive arm rather than test it" does not apply at a public extension point.** The rule is sound where the caller set is closed — a private call graph the phase can enumerate. At a `@behaviour` third parties implement, the caller set is open by construction, which is the same premise that justifies shipping a conformance suite at all. Before deleting a defensive arm guarding a behaviour's return contract, verify a conformance case actually certifies that contract **for the shape being deleted**, not merely the easiest shape. Prefer an explicit `raise` naming the violating module and invariant over an incidental `CaseClauseError`: a raise keeps the `@spec` honest (raises don't appear in specs), is coverable by an ~8-line non-conforming stub in `test/support/`, and names the third party rather than surfacing from a `@moduledoc false` internal.

**A reshaped assertion must state which directions of the original property it preserves.** When a design-mandated check is rewritten to dodge a real obstacle, enumerate what the original covered and mark each item kept or dropped — a bidirectional assertion replaced by a unidirectional one is a silent narrowing. Worked example: Phase 20.3 correctly replaced a specified set-equality diff with a behavioural loop (a module attribute is unreadable post-compile); the loop catches a struct field added without an allow-list entry *and* a typo'd entry, but not the reverse, so an allow-listed non-field passes every test and raises `KeyError` inside the bare `struct!/2` the first time a caller passes that opt.

**A fail-open denylist mirroring other lists MUST ship a data-driven drift-guard test.** `Chat.@request_carried_keys` strips orchestration/streaming/tool-runner opts from `request.options` and is hand-copied from `StreamRunner.@orchestration_opts`, `@phase_5_layer_opts`, and `Chat`'s `tool_runner_keys`. A forgotten entry fails OPEN — the key leaks onto the provider wire body — so a spot-check over a fixed key set is insufficient. The test folds the *union of the source lists* (exposed via `@doc false` accessors) into a `chat/3` call and asserts none appear in `req.options`, so a new source-list entry goes red until mirrored. Partition contract worth stating in the denylist's comment: `@engine_field_keys` (via `resolve_params/2`) strips engine-field keys; `@request_carried_keys` strips only keys arriving as *call opts*, which is why `:tool_executor` / `:context` are intentionally absent from the latter.

### Property tests

`:stream_data` (test-only dep). Every property test module uses `use ExUnitProperties` at `test/allm/<path>_property_test.exs`.

Generators for Layer A structs live in `test/support/generators.ex`. Inline generators are fine for single-use; promote when a second property file references the same shape.

Prefer generator-level invariants (`StreamData.bind/2` + `StreamData.filter/2` for unique-by-field) over `check all` post-filter. Post-filter shrinks incorrectly — a shrunk counterexample violating the post-filter silently passes.

**Generator choice.** `StreamData.term/0` is the widest net — use for **totality properties** where the assertion is "this must not raise on arbitrary input" (e.g., `apply_event/2` catch-all robustness at `test/allm/stream_collector_test.exs`). Its search space includes PIDs, refs, funs, non-serializable terms — correct for a Layer C reducer promising totality. **Don't use `StreamData.term/0` for Layer A serializability properties** — those need a closed serializable set (atoms, integers, strings, maps, lists, tuples). Use `StreamData.one_of([...])` with explicit narrower generators or `StreamData.filter/2` to exclude non-serializable shapes. A serializability property accepting PIDs will fail `:erlang.term_to_binary/1 → :erlang.binary_to_term/1` at random iterations, looking like a flaky generator rather than a shape problem.

**Fake-per-process cursor isolation in equivalence properties.** Property tests exercising `generate/3 ≡ stream_generate/3 |> collect` (or `step/3`/`chat/3` analogues) against `ALLM.Providers.Fake` MUST isolate Fake's per-process cursor between calls. Fake's default cursor lives in the caller's process dictionary keyed by `:erlang.phash2(scripts)` — two consecutive calls in the same process against content-identical scripts share the cursor and the second script-exhausts, producing a spurious failure. Use `Task.async(fn -> ... end) |> Task.await(timeout_ms)` to give each call its own process (preferred), or use `Fake.start_script_cursor/0` + `Fake.cursor_index/1` when an iteration needs to assert cursor advancement across calls. Worked templates: `test/allm/stream_equivalence_test.exs` (`run_generate/1` + `run_stream_and_collect/1`), `test/allm/step_equivalence_test.exs`, `test/allm/allm_step_test.exs`.

### Layer A — Serializable data

Every Layer A struct gets:

- **Construction test** for every public constructor (`ALLM.system/1`, `ALLM.user/1`).
- **Validation test** for every invariant (e.g., `ALLM.Message` with `role: :tool` requires `tool_call_id`).
- **`:erlang.term_to_binary/1` round-trip:**

  ```elixir
  msg = ALLM.user("hello")
  assert msg == msg |> :erlang.term_to_binary() |> :erlang.binary_to_term()
  ```

- **JSON round-trip** (with the codec the public API uses):

  ```elixir
  msg = ALLM.user("hello")
  encoded = Jason.encode!(msg)
  decoded = encoded |> Jason.decode!() |> ALLM.Message.from_json!()
  assert msg == decoded
  ```

- For tagged-union types (`ALLM.Event`): one test per variant + a property test asserting closed-union exhaustiveness (helper that pattern-matches every variant and fails on `_unknown`).

A test that constructs a struct, calls `:erlang.term_to_binary/1`, and asserts a binary catches accidental fun/PID/ref leaks.

### Layer B — Runtime

Every behaviour gets a **conformance suite**. The design picks one of two shipping shapes; the implementer reads the design's Non-obvious Decisions to know which.

**Shape A — main-project-internal (`test/support/`).** The suite lives at `test/support/<behaviour>_conformance.ex`, uses `ExUnit.CaseTemplate` or `defmacro __using__/1`, available only inside the main project's test tree. Use when no external consumers and no need to publish. Lower coordination cost.

**Shape B — sibling Hex package (`conformance/`).** Suite lives at `conformance/lib/allm/test/<behaviour>_conformance.ex` and is published separately (e.g., `allm_conformance`); external authors depend with `{:allm_conformance, "~> 0.2", only: :test}`. Use when (a) external users implement the behaviour and need the harness, (b) the harness pulls test-framework deps that would leak into runtime, or (c) consumers would need `"deps/allm/test/support"` in their `elixirc_paths`. Main `allm` depends on the sibling via `path:` dev-dep so its defaults can certify against the harness.

**Shape B PLT gotcha.** A sibling-package harness on `ExUnit.CaseTemplate` expands to `ExUnit.CaseTemplate.__proxy__/2`, which Dialyzer can only resolve if `:ex_unit` is in the sub-project's PLT. Add `dialyzer: [plt_add_apps: [:ex_unit]]` to the sibling's `mix.exs` `project/0` — otherwise `mix dialyzer` warns on unresolved `__proxy__/2`. Include this in Shape B's cost analysis.

The suite is parameterized by implementation:

```elixir
# Shape A (test/support/):
defmodule ALLM.AdapterConformance do
  defmacro __using__(opts) do
    impl = Keyword.fetch!(opts, :impl)
    quote do
      use ExUnit.Case, async: true
      @impl unquote(impl)
      describe "Adapter conformance" do
        test "generate/3 with a minimal request returns {:ok, %ALLM.Response{}}", do: ...
      end
    end
  end
end

# Shape B (conformance/lib/allm/test/):
defmodule ALLM.Test.AdapterConformance do
  use ExUnit.CaseTemplate
  using opts do
    quote do
      @__allm_conformance_adapter__ Keyword.fetch!(unquote(opts), :adapter)
      describe "ALLM.Adapter conformance" do
        test "generate/2 returns {:ok, %ALLM.Response{}}", _context do
          # reads @__allm_conformance_adapter__
        end
      end
    end
  end
end
```

`ALLM.Providers.Fake` is the reference; real adapters reuse via `use ALLM.AdapterConformance, impl: ALLM.Providers.OpenAI` (Shape A) or `use ALLM.Test.AdapterConformance, adapter: ALLM.Providers.OpenAI` (Shape B).

**Shape B harness helpers must be namespaced.** A `defp some_helper/n` inside the harness's `using/1` `quote` block expands into every consuming test module and shares the caller's namespace — collides with any main-module helper of the same name. Same reason: a main-module needing a same-named helper (`eventually/2`) should pick a non-colliding alternative (`wait_for/2`). If the harness needs a helper callable from the `using/1` expansion, define as `@doc false def` on the harness module and invoke via `harness = unquote(__MODULE__); harness.fun(...)` — pushes definition out of quote (reduces `Refactor.LongQuoteBlocks` pressure) and keeps internal helpers out of the caller's namespace.

**…but a helper pushed out of the `quote` must take and return plain data.** The conformance package is compiled *before* the package it certifies in a consuming project's build, so a module-body `def vectors_of(r), do: ALLM.EmbeddingResponse.vectors(r)` emits `module is not available` on every clean build. Anything naming a main-package module stays inside the `using/1` `quote`, which expands at the consumer's compile time when the main package is loaded. The three rules interact: quote-length pressure (`Refactor.LongQuoteBlocks`) and namespace hygiene both push helpers *out*; compile order pushes main-package-touching helpers back *in*.

**A harness self-test's case-count guard must count the injected tests, not re-assert the constant.** `assert case_count() == N` cannot catch a case added to the `quote` without bumping `@case_count`. Filter `__MODULE__.__ex_unit__().tests` by the injected `describe` name and compare against `case_count/0`. Canonical: `conformance/test/allm/test/embedding_adapter_conformance_test.exs`. The five older harnesses (adapter, stream_adapter, tool_executor, tool_result_encoder, image_adapter) still carry the constant-only form and should be back-ported.

**Shape B harnesses must not reference optional fixtures by direct module atom.** A fixture under `conformance/test/support/` (`ALLM.Test.Fixtures.StubAdapter`) isn't on the main package's `elixirc_paths`. Direct reference inside `using/1` — including via `alias` — produces `undefined (module is not available)` warning in every main-package consumer. Resolve at runtime: `stub = Module.concat(["ALLM", "Test", "Fixtures", "StubAdapter"])` + `Code.ensure_loaded?(stub)` gates — `Module.concat/1` with source-literal strings produces the atom at runtime, hiding the reference from compile-time resolution (same pattern as §Common Pitfalls → Optional-dep detection).

The engine itself gets a **serializability test**: `:erlang.term_to_binary/1` succeeds and the round-tripped engine produces equivalent results. Catches accidentally storing a fun or Finch ref on the struct.

### Layer C — Stateless execution

- **Streaming primitive first.** Tests for `stream_generate/3` against `ALLM.Providers.Fake` come before tests for `generate/3`. Non-streaming is a reducer.
- **Stream-equivalence** for every non-streaming wrapper:

  ```elixir
  property "generate/3 equals stream_generate/3 |> StreamCollector.collect/1" do
    check all(script <- fake_event_script_generator()) do
      engine = Fake.engine(stream: script)
      {:ok, response} = ALLM.generate(engine, ALLM.request([ALLM.user("x")]))
      {:ok, stream} = ALLM.stream_generate(engine, ALLM.request([ALLM.user("x")]))
      collected = ALLM.StreamCollector.collect(stream)
      assert response == collected
    end
  end
  ```

- **Cleanup** for every stream resource:

  ```elixir
  test "stream_generate/3 cleans up when the consumer halts early" do
    {:ok, ref} = Fake.tracked_engine()
    {:ok, stream} = ALLM.stream_generate(ref.engine, ALLM.request([ALLM.user("x")]))
    _ = stream |> Enum.take(1)
    assert_receive {:fake_resource_released, ^ref}, 500
  end
  ```

- **Avoid wall-clock timing assertions on multi-process operations.** Tests SHOULD NOT use `assert elapsed_ms <= N` with N < 5000ms on cancellation, async streams, or retry backoff. These flake under CI variance. Prefer deterministic behavioural assertions: event-count (`assert cancel_count == 1`), exit-status (`assert receive_exit(:normal, 5000)`), or message-receipt (`refute_receive {:event, _}, 1000`). Worked example: PHASE_10.3's `assert elapsed_ms <= 500` cancellation test flaked intermittently in 10.3, 10.6, and 11.2 fix follow-up; replacement candidate `assert cancel_count == 1` + `refute_receive {:event, _}, 2000` pins the actual contract without coupling to wall-clock latency.

- **Error contract tests.** Every documented `{:error, %ALLM.Error.X{reason: r}}` gets a Fake-triggered test.

### Layer D — Stateful continuation

- **State-transition tests.** For every `Session` op, assert (a) the returned session has the expected `thread.messages` ending; (b) `usage` accumulates correctly; (c) the session round-trips through `:erlang.term_to_binary/1` after every op.
- **`{:ask_user, ...}` suspension** in both `:auto` and `:manual` (§12.3). Suspended sessions persistable and resumable.
- **Tool execution** in `:auto` (loop runs tools) and `:manual` (caller submits results). Both covered.

## Mocking Policy

- **`ALLM.Providers.Fake` for all orchestration tests.** Non-negotiable. Network mocks couple tests to wire formats and break the layer boundary.
- **`Bypass`/`Plug.Test` only for real provider wire-format tests** at `test/allm/providers/<provider>_wire_test.exs`, tagged `@tag :wire`. They confirm request/response bytes — nothing else.
- **`Mox` only for behaviours without a Fake.** Currently `ALLM.Keys` and rare cases. Prefer extending Fake.

## Error Handling

Errors are first-class data, never strings. Public functions return `{:ok, result}` or `{:error, %ALLM.Error.X{}}` where X is one of:

- `ALLM.Error.AdapterError` — provider-side (auth, rate limit, content filter)
- `ALLM.Error.EngineError` — engine misconfiguration (no adapter, no key, invalid model)
- `ALLM.Error.StreamError` — streaming-specific (chunk parse, truncation)
- `ALLM.Error.ToolError` — tool execution (handler raised, ask-user without prompt)
- `ALLM.Error.SessionError` — session-state corruption (thread invariant violated)

Each struct has at minimum `:reason` (atom from a closed set), `:message` (no secrets), `:provider` (atom or `nil`), `:cause` (underlying term).

**Discipline:**

- **No `{:error, term()}` in `@spec`.** Use the struct.
- **No `raise` in public functions.** Public returns error tuples; internal helpers may raise on programmer errors (`ALLM.ArgumentError` etc.).
- **No swallowed errors.** Every `try/rescue` has a `Logger` call OR an error-tuple return — never both silent.
- **`:cause` for debugging.** Chain the underlying exception so users can `inspect/1` it.

**Required pieces of every error module.** ALLM ships seven error structs (AdapterError, EngineError, StreamError, ToolError, SessionError, ValidationError, ImageAdapterError); v0.4 will add at least AudioAdapterError. Every closed-enum exception module ships **eight required pieces**:

1. Closed `@type reason :: :foo | :bar | ...` enum
2. `@legal_reasons` list literal (so `unless reason in @legal_reasons` is compile-checkable)
3. `defexception` with the six common fields (`:reason, :message, :provider, :cause, :metadata`) plus any specific extras (`:status`, `:retry_after_ms`)
4. `new/2` with reason-validation + `ArgumentError` + default-message helper
5. `legal_reasons/0` `@spec () :: [reason()]` introspection seam
6. `__from_tagged__/1` hydrator
7. `defimpl Jason.Encoder` via `ALLM.Serializer.encode_tagged/2`
8. `Exception.message/1` impl with default-message helper, plus doctests on `new/2` and `Exception.message/1`

Cite `lib/allm/error/adapter_error.ex` and `lib/allm/error/image_adapter_error.ex` as parallel templates. Each new error module is otherwise a 150-LOC mostly-mechanical exercise; the checklist prevents silent omission of (e.g.) `legal_reasons/0` or the `__from_tagged__/1` hydrator.

## Streaming Discipline

- **Every `Stream.resource/3` has a cleanup function.** No exceptions. Test with early consumer halt.
- **Backpressure is the consumer's responsibility.** Producer emits at network rate; consumers control with `Stream.take/2`, `Enum.into/3`. Document in `@doc`.
- **HTTP/1, not HTTP/2** (§7.2). Don't change without spec amendment.
- **SSE parsing is line-buffered.** Events span chunks; buffer until `\n\n`. Test with mid-event splits.

### `Stream.resource/3` three-arity cheatsheet

The three funs have **different return shapes**; mixing them produces a cryptic `Stream.Reducers` pattern-match failure, not a clear type error.

| Fun | Arity | Return shape | Purpose |
|-----|-------|--------------|---------|
| `start_fun` | `(() -> acc)` | Initial acc **only** — never events | Open resources (files, sockets, counters). Stash any pre-emit events in acc for first `next_fun` to drain. |
| `next_fun` | `(acc -> {[events], new_acc} \| {:halt, acc})` | `{events, acc}` or `{:halt, acc}` | Pop work; emit events; advance state. Idempotent on halt. |
| `after_fun` | `(acc -> term)` | Discarded | Cleanup. Runs synchronously on normal halts, reducer throws, trappable consumer exit. NOT on `Process.exit(pid, :kill)`. |

Asymmetry that bites: **`start_fun` returns acc, not `{events, acc}`.** To emit a bookend event (`:message_started`) before consuming entries, stash it in `:pending` at `start_fun`; have `next_fun`'s first clause drain it:

    defp next_fun(%{pending: [_ | _] = pending} = acc), do: {pending, %{acc | pending: []}}

Worked example: `ALLM.Providers.Fake.stream/2` at `lib/allm/providers/fake.ex`.

## Common Commands

```bash
mix deps.get                           # install
mix compile --warnings-as-errors       # compile (CI flag)
mix format                             # autoformat
mix format --check-formatted           # CI gate
mix test                               # full suite
mix test --cover                       # coverage summary
mix test --include doctest             # doctests included (default in mix.exs)
mix test test/path/to/file_test.exs    # single file
mix test test/path/to/file_test.exs:42 # single test by line
mix test --only focus                  # tagged @tag :focus
mix test --only integration            # real provider smoke tests (require keys)
mix credo --strict                     # linter
mix credo --strict lib/allm.ex         # single file
mix dialyzer                           # type checker
mix dialyzer --plt                     # rebuild PLT
iex -S mix                             # REPL with project
```

## Project Conventions

### Module organization

- `lib/allm.ex` — top-level facade (§4). One function per public op, dispatching internally.
- `lib/allm/<struct>.ex` — Layer A structs, one module per struct.
- `lib/allm/engine.ex` — Layer B engine struct.
- `lib/allm/<behaviour>.ex` — Layer B behaviours (`Adapter`, `StreamAdapter`, `ToolExecutor`, `ToolResultEncoder`).
- `lib/allm/session.ex` — Layer D session.
- `lib/allm/stream/` — internal streaming machinery (runner, collector, SSE parser). Not public; don't reference from outside `lib/allm/`.
- `lib/allm/providers/<name>.ex` — adapter implementations. `Fake` is library-proper, not test-only.
- `lib/allm/error/<name>.ex` — error structs.

**Single-file threshold.** Utility surfaces (`ALLM.Validate`, future `ALLM.Serializer`, `ALLM.Keys`) live in single files by default. Split only when (a) two public functions share no private helpers, OR (b) private-helper count exceeds public-function count by more than 4× and the file becomes hard to read. Line count alone isn't a trigger — Elixir's `File`, `Map`, `Enum` are single files with 30+ public functions because the surface is coherent. If the module's *surface* is one concept, keep it in one file.

### Naming

- Streaming variants: `stream_<name>/n` (`stream_generate/3`, `stream_step/3`).
- Behaviour callbacks match the function they back (`generate/3` calls `c:Adapter.generate/3`).
- Internal modules use `ALLM.Internal.X` if they exist outside `lib/allm/stream/`. Avoid; prefer `@moduledoc false`.

### Documentation

- Every public module has a `@moduledoc` describing the layer (A/B/C/D), role, and a runnable example.
- Every public function has a `@doc` with at least one runnable doctest using `ALLM.Providers.Fake`.
- Every behaviour callback has `@callback` AND `@doc` (on the callback, not just the behaviour module).
- ExDoc groups follow the four layers — see `mix.exs` `:docs`.

### Telemetry

Per spec §29:

- `[:allm, :request, :start | :stop | :exception]`
- `[:allm, :stream_request, :start | :stop | :exception]`
- `[:allm, :tool, :start | :stop | :exception]`
- `[:allm, :session, :start | :stop | :exception]`

Measurements: `:duration` (native), `:input_tokens`, `:output_tokens`, `:cost` (when `llm_db` present). Metadata: `:provider`, `:model`, `:engine_id`.

**Don't add new telemetry events without a spec amendment.** Telemetry is a public contract.

**`Telemetry.span/3`'s closure may return either shape.** `{result, stop_metadata_extras}` (2-tuple, metadata-only) or `{result, extra_measurements, stop_metadata_extras}` (3-tuple, when the `:stop` event carries non-default measurements beyond `:duration` and `:monotonic_time`). Phase 14.3 widened this to ship `image_count` as a `:stop` measurement per its Decision #8 (`lib/allm/telemetry.ex:146,165-168`). Future spans needing custom measurements use the 3-tuple form; spans without custom measurements use the 2-tuple form (still the dominant shape — `:generate`, `:step`, `:chat`, `:stream`, `:tool` all use it).

### Logger usage

- `Logger.warning/1` — ops-visible degradations (rate limits, retries).
- `Logger.error/1` — errors propagating to caller (with `error: %ALLM.Error.X{}` metadata).
- No `Logger.debug/1` in hot paths (per-event, per-chunk). Use telemetry.
- Never log API keys, request bodies with PII, response bodies with PII. Structural metadata only (model, token counts, durations).

## Common Pitfalls

- **Don't put a fun on the engine.** Engines must be serializable. Use module + atom (`{MyKeys, :resolve_openai}`). §6.4.
- **Don't put an API key on the engine.** Resolve at adapter-call time via `ALLM.Keys`. §6.4.
- **Don't add a new event variant without updating every reducer.** `ChatResult`, `StepResult`, `Session` all reduce events. §8.
- **Don't reach for HTTP mocks for orchestration.** Use Fake.
- **Don't write a non-streaming function that doesn't reduce its streaming counterpart.** Violates §3 stream-first.
- **Don't use `Stream.unfold/2` for IO-backed streams.** Use `Stream.resource/3` for explicit cleanup.
- **Don't use HTTP/2 for streaming.** §7.2 documents the Finch flow-control bug.
- **Don't add `middleware:` support.** Reserved for v0.3 (§29).
- **Don't depend on `llm_db` from core modules.** Optional. §6.3.
- **Don't use `@opaque` on `@moduledoc false` structs.** `@opaque` is for downstream consumers; `@moduledoc false` declares no downstream consumers. Combination blocks Dialyzer from relating `Mod.t()` to `%Mod{}` pattern matches in private helpers of OTHER modules in the project, forcing them to drop `@spec`. Use `@type`. Worked example: `lib/allm/chat/loop_state.ex` shipped as `@opaque` in batch 7.3; `Chat`'s private helpers had to drop `@spec`s. Fixed in pre-batch-3 prep.
- **Don't forget the `@spec`.** Dialyzer requires it; CI fails on a missing spec for a public function.
- **Don't widen an `@spec` to silence Dialyzer.** Hides real type errors. Fix the impl.
- **Don't `if Mix.env() == :test` in `lib/`.** Test-only code lives in `test/support/` (only in `:test` `elixirc_paths`).
- **Don't normalize Dialyzer warnings.** Each is real. If genuinely false, suppress inline with comment + spec link.
- **Don't change public API without a CHANGELOG entry.** Even pre-1.0, the four `steering/examples/` apps depend on the API.
- **Don't merge a phase with `In Progress` status.** Completed or not done.
- **Don't skip `mix dialyzer` because it's slow.** First run builds PLT (1–2 min); subsequent runs are seconds.
- **Don't rely on the default `:erlang.phash2(script)` cursor for multi-engine or content-equal scripts in the same process.** `Fake` and `FakeImages` both default to a process-dict cursor keyed by `:erlang.phash2(scripts)`. Two engines built with byte-equal scripts in the same test process share the cursor and the second exhausts. Use `Fake.start_script_cursor/0` / `FakeImages.start_script_cursor/0` and pass the pid as `adapter_opts[:script_cursor]`. (Phase 12.2 / 14.1 / 14.2 / 14.3 / 14.4 — overdue across five retros.)
- **`engine.adapter_opts ++ call_site_opts` (NOT `Keyword.merge`).** When a Layer-C façade merges engine-carried `adapter_opts` with call-site `opts[:adapter_opts]`, use `++`. `Keyword.get/2` returns the FIRST occurrence — engine wins on collision. `Keyword.merge/2` would have OPPOSITE semantics (call wins). Mirror: `lib/allm/stream_runner.ex:230`. Phase 14.2 initially shipped `Keyword.merge` and was a silent precedence flip vs the cited precedent.
- **Layer C façades have TWO drop-points for opts.** One at the request-builder boundary (strips opts that collide with the request struct's fields when merged into `Request.new/1` / `ImageRequest.new/1`), one at the dispatch boundary (strips opts that are call-site-only and the adapter must not see — `:stream`, `:request_id`-as-direct-key, etc.). Conflating them produces silently-forwarded opts that real adapters reject. See `StreamRunner.@phase_5_layer_opts:54-61` for the chat-side dispatch-boundary deny-list pattern.

### Elixir serialization exception shapes

Three observed behaviors that surprise most Elixir devs writing Layer A/B serializability tests:

- **`:erlang.term_to_binary/1` silently encodes anonymous functions and funs-in-keyword-lists.** Unsafety is at decode-time across BEAM reloads or nodes (`:badfun`), not encode. Don't write `assert_raise ArgumentError, fn -> :erlang.term_to_binary(…fn…) end` — it never fires.
- **Jason raises `Protocol.UndefinedError`, not `Jason.EncodeError`, when no encoder exists.** `Jason.EncodeError` is for cases where an encoder is defined but rejects input. A function/tuple/struct without `Jason.Encoder` impl produces `Protocol.UndefinedError` at protocol dispatch.
- **`DateTime` and `Decimal` have Jason encoders (ISO-8601 / string) but no matching decoders in this library.** A metadata map containing `%DateTime{}` round-trips through `term_to_binary` cleanly, but the JSON round-trip is **non-equality-preserving** — the decoded value is an ISO-8601 binary, not a `%DateTime{}`. Tests assert `refute decoded == original`, not encode-time raises.
- **`metadata: map()` fields on Layer-A structs do NOT preserve atom keys across JSON round-trip.** Atom keys decode as strings via `Jason.decode!/1`. Two patterns: (1) **string-keyed metadata** — the convention used by `Image`, `TextPart`, `ImagePart` — round-trips JSON cleanly but is asymmetric vs. atom-key constructor sugar (`%{source: :test}` round-trip-decodes as `%{"source" => "test"}`). (2) **closed-set atom field with `Serializer.to_atom_field/1` rescue** — the convention used for `:detail` on `ImagePart` (`[:auto, :low, :high]`) — round-trips atoms cleanly via the registered hydrator path. New Layer-A struct authors choosing pattern (1) for `metadata` MUST add a test-comment naming the asymmetry. Worked example: `test/allm/text_part_test.exs:44-50`. **Generalization beyond `metadata`**: Layer-A maps that may round-trip through JSON MUST be read with dual-keyed accessors (atom AND string). This applies to `metadata` fields on structs (existing convention) AND to capability maps inside `%ModelRef{}` — `lib/allm/capability.ex:393-404`'s `check_vision/3` defines parallel `%{vision: false}` and `%{"vision" => false}` clauses. Single-keyed reads silently fail-open against JSON-rehydrated catalogs/metadata — the worst possible failure mode (no error, wrong answer).

### Optional-dep detection

To reference an optional dep at runtime without a compile-time binding (e.g., `llm_db` per §6.3):

```elixir
mod = Module.concat(["OptionalMod"])
if Code.ensure_loaded?(mod) do
  mod.some_fun(arg)
else
  fallback(arg)
end
```

Three approaches that **don't work** and you'll hit first:

- **Direct reference** (`OptionalMod.some_fun(arg)`): trips `--warnings-as-errors`.
- **`apply/3`** (`apply(OptionalMod, :some_fun, [arg])`): trips Credo's `Refactor.Apply`.
- **Bound variable** (`mod = OptionalMod`): same compile warning — the literal atom triggers it.

`Module.concat(["OptionalMod"])` produces the atom at runtime from a compile-time literal. Exactly one atom is ever created, so it's not the atom-table-exhaustion vector that the same call is on untrusted JSON — see `AGENT_DESIGN_SPEC.md` "scope stdlib bans to their threat model."
