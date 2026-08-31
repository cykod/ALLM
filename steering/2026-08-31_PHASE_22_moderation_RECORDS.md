# Phase 22 — Records

Companion to `steering/2026-08-31_PHASE_22_moderation.md`. Per-sub-phase status,
ticked checklists, deviations, and verification transcripts. The design document
holds contracts only.

---

## Phase 22.1 — Layer A moderation data types

**Status: Completed** (2026-08-31). All four review gates ran and their artifacts are present and non-empty: `.work/reviews/2026-08-31-phase22-1-layer-a/overview.md` (functional, PASS), `.work/code-reviews/2026-08-31-phase22-1-layer-a.md` (7 findings, 0 High), `.work/security-reviews/2026-08-31-phase22-1-layer-a.md` (no issues), `.work/design-reviews/2026-08-31-phase22-1-layer-a.md` (N/A — backend-only). Fix pass applied 6 items, escalated 0, deferred 1 Medium to 22.7 and 5 Lows to the phase-end polish pass.
Date: 2026-08-31.

### Implementation Checklist (22.1.2)

- [x] `lib/allm/moderation_request.ex` per the contract block, including `decode_input/1` and `multimodal?/1`
- [x] `lib/allm/moderation_result.ex` per the contract block, including `@enforce_keys [:flagged]`
- [x] `lib/allm/moderation_response.ex` per the contract block
- [x] `lib/allm/error/moderation_adapter_error.ex`, structurally mirroring `lib/allm/error/embedding_adapter_error.ex`
- [x] Extend `EngineError` (`:no_moderation_adapter`) and `ValidationError` (`:invalid_moderation_request`) — both the `@type` union and the `~w()a` runtime list in each
- [x] `Validate.moderation_request/1` + the `# Internal: moderation_request rules` block at the file bottom
- [x] Register all four modules in `Serializer.@known_modules`
- [x] Add three entries to `test/layer_a_docs_test.exs` `@layer_a`
- [x] `mix.exs` `docs.groups_for_modules`: three entries in `"Data types"`, `ALLM.Error.ModerationAdapterError` in `Errors` — exactly the four modules this sub-phase creates
- [x] `@moduledoc`s carry no banned tokens

### Files

**New (lib):** `lib/allm/moderation_request.ex`, `lib/allm/moderation_result.ex`,
`lib/allm/moderation_response.ex`, `lib/allm/error/moderation_adapter_error.ex`.

**Modified (lib):** `lib/allm/error/engine_error.ex`,
`lib/allm/error/validation_error.ex`, `lib/allm/serializer.ex`,
`lib/allm/validate.ex`.

**New (test):** `test/allm/moderation_request_test.exs`,
`test/allm/moderation_result_test.exs`, `test/allm/moderation_response_test.exs`,
`test/allm/error/moderation_adapter_error_test.exs`,
`test/allm/validate_moderation_request_test.exs`.

**Modified (other):** `test/layer_a_docs_test.exs`, `mix.exs`.

`README.md` untouched — `git diff --stat HEAD -- README.md` empty.

### Verification transcript (22.1.3)

```
mix test <five new files>   21 doctests, 99 tests, 0 failures
mix test                    397 doctests, 31 properties, 3191 tests, 0 failures, 14 excluded
mix test --seed 0           397 doctests, 31 properties, 3191 tests, 0 failures, 14 excluded
mix format --check-formatted  clean
mix credo --strict          2977 mods/funs, found no issues
mix dialyzer                Total errors: 0, Skipped: 0, Unnecessary Skips: 0
mix compile --warnings-as-errors  clean
mix test --cover            Total 93.50%; all four new modules 100.00%
```

Baseline before the batch: 374 doctests, 31 properties, 3089 tests, 0 failures.
Delta: **+23 doctests, +102 tests, 0 failures.** Zero warnings throughout.

`mix run scripts/audit_user_docs.exs` exits **1 at baseline and after** with a
byte-identical hit set (verified by stashing the batch and re-running; `diff`
shows only the compile banner).

**CORRECTED 2026-08-31 (fix pass, from functional review F1).** This paragraph
originally recorded a "24-line hit set". That figure was the count of non-empty
*output lines* (headers and the per-file summary block included), not the count of
hits. The script's own `Total hits:` line reports **10 hits across 5 files**,
re-measured at the fix-pass checkpoint over two consecutive runs:

```
$ mix run scripts/audit_user_docs.exs
Files scanned:    94
Files with hits:  5
Total hits:       10
  guides/fakes.md: 4                    (2× phase_n :114 :141, 1× section_marker :208, 1× spec_section :208)
  lib/allm/engine.ex: 3                 (section_marker :37, :178, :183)
  lib/allm/providers/fake.ex: 1         (section_marker :77)
  lib/allm/providers/fake_images.ex: 1  (section_marker :48)
  lib/allm/validate.ex: 1               (phase_n :19 — a "Phase 21.1" marker in a moduledoc
                                         paragraph this batch did not touch)
exit=1
```

The **substantive** claim was and remains correct: none of the hits is in a file
this batch created or modified, and the moderation modules contribute nothing.
**This gate is red on `main` and was not made redder here.**
`test/layer_a_docs_test.exs`'s Layer-A-scoped run of the same audit is green,
which is what binds the four new modules.

### Audit-gate verification

* `test/groups_for_modules_audit_test.exs` (fail-closed): removing
  `ALLM.ModerationResult` from `mix.exs` produces
  `Public lib/ modules missing from groups_for_modules: [ALLM.ModerationResult]`.
  **Red as designed.** Restored and green.
* `test/layer_a_docs_test.exs` (fail-open): removing `ALLM.ModerationResult`
  from `@layer_a` produces **silence** — 24 tests, 0 failures instead of 25.
  This falsifies the design's 22.1.3 success criterion, which asked for the
  remove-an-entry check on *both* gates; corrected in place at the claim
  (`2026-08-31_PHASE_22_moderation.md`, 22.1.3). See Deviation 2.

### Deviations

1. **[tactical] `decode_input/1`'s item decoder is `&ALLM.Serializer.hydrate/1`
   rather than a separate `decode_item/1` private.** The contract block specifies
   `decode_input/1` as "an explicit two-clause private (`is_list` →
   `Enum.map(&decode_item/1)`, else pass through verbatim)". Both clauses ship
   exactly as specified; only the mapped function differs.
   `Serializer.hydrate/1` is *already* the identity on a binary and the hydrator
   on a `__type__`-tagged map, so a `decode_item/1` wrapper would have been a
   two-clause restatement of it. Behaviour is identical, and the non-list
   pass-through arm — the contract's actual load-bearing half — is unchanged.

2. **[structural, documented] `decode_input/1` is called as
   `decode_input(data["input"] || [])`, not `decode_input(data["input"])`.** The
   contract block's two clauses would return `nil` for a payload with no
   `"input"` key, violating the declared `[item()]` type on a hand-built map.
   The `|| []` prefix is the same idiom `EmbeddingRequest.__from_tagged__/1`
   uses for its own `:input`, and CLAUDE.md's truthy-default rule permits it
   because `[]` is not truthy. The two specified clauses are untouched; only
   what is handed to them changed. Pinned by
   `moderation_request_test.exs` "missing fields fall back to their defaults"
   and "a non-list `:input` passes through verbatim".

3. **[tactical] `decode_flagged/1`'s `@doc false` rationale is stated as a type
   and blast-radius argument, not as "fail-closed".** The contract block calls
   repairing to `false` "fail-closed … the only safe direction for a moderation
   verdict". The *behaviour* ships exactly as specified — `is_boolean/1` passes
   through, everything else becomes `false` — but the shipped comment does not
   claim `false` is the safety-conservative verdict, because `false` means "not
   flagged", i.e. content passes. What the repair actually buys is stated
   instead: a malformed payload can neither leave a `nil` in a `boolean()` field
   nor manufacture a `true` that blocks legitimate content on a decode glitch.
   The deliberate inversion of `ALLM.Embedding.decode_vector/1`'s
   pass-through-don't-repair contract, and the scoping of the repair to
   `:flagged` alone, are both stated as 22.1.4 requires. **This is a wording
   divergence from the design, deliberately not amended in the design doc**,
   because it is an argument about a label rather than a falsified fact; a
   future reviewer who prefers the design's framing can restore it without any
   code change.

4. **[documented] The moduledocs do not name `ALLM.ModerationAdapter` or
   `ALLM.moderate/3`.** Those land in 22.2 and 22.3. ExDoc autolinks a
   backticked module or function reference and warns when the target does not
   exist, so `ModerationAdapterError`'s moduledoc opens "Errors returned by
   content-moderation adapter implementations" and its `:batch_too_large` row
   writes `max_batch_size()` with parens (the form
   `EmbeddingAdapterError` uses) rather than `max_batch_size/0`. **22.2 and 22.3
   should tighten these references once their targets exist** — specifically:
   `ALLM.Error.ModerationAdapterError`'s moduledoc opener and
   `:batch_too_large` row, and `ALLM.ModerationResponse`'s "Telemetry metadata
   still carries a `:usage` key" sentence, which is currently unlinked prose.

No other deviations.

### `[DEFERRED-DRY]` entries

**CORRECTED 2026-08-31 (fix pass, from code review F1/F2/F6).** This section
originally read "No `[DEFERRED-DRY]` entries: no helper in this batch reached two
implementations." That sentence is false — three helpers and one whole module
reached the `agent-spec/IMPLEMENTATION.md:68` promotion trigger. Two of the three
helpers were consolidated in the fix pass; the rest are recorded below.

* **`[EXTRACTED]` (not deferred) — two byte-identical `ALLM.Validate` rule
  helpers.** `validate_moderation_model/2` was character-for-character
  `validate_embedding_model/2`, and `validate_moderation_input_non_empty/2` was
  character-for-character `validate_embedding_input_non_empty/2`. Both pairs were
  collapsed onto capability-neutral privates — `validate_model_field/2` and
  `validate_input_non_empty/2` — in a new "Internal: capability-neutral field
  rules" section of `lib/allm/validate.ex`, with both call sites
  (`embedding_request/1`, `moderation_request/1`) migrated in the same commit per
  the migration-on-extraction rule. `[structural, documented]`: private,
  behaviour-preserving, every public name unchanged, pinned by the Phase 20
  `test/allm/validate_embedding_request_test.exs` suite. Same shape CLAUDE.md
  blesses for `augment_retry_policy/2` in PHASE_20.3.

* **`[DEFERRED-DRY]` — `validate_moderation_input_elements/2` vs
  `validate_embedding_input_elements/2`** (`lib/allm/validate.ex`). The moderation
  copy differs by one added clause (`{%ImagePart{}, _idx}, acc -> acc`) and one
  renamed error atom (`:not_a_string` → `:invalid_item`). `IMPLEMENTATION.md:68`
  counts an added fall-through clause as a clone, but here the accept set is a
  genuine union and the error vocabulary genuinely diverges, so the two are kept
  separate deliberately. Re-evaluate when a third capability needs a per-element
  rule: at three, an `accept_fun`-parameterised shared fold pays for itself.

* **`[DEFERRED-DRY]` — the four `*AdapterError` modules.**
  `lib/allm/error/adapter_error.ex`, `image_adapter_error.ex`,
  `embedding_adapter_error.ex`, and the new `moderation_adapter_error.ex` are
  four copies of roughly 100 lines of mechanical code: `legal_reasons/0`, `new/2`
  (including the `unless reason in @legal_reasons` guard and its message), the
  three `message/1` clauses, `defp default_message/2`, `__from_tagged__/1`, and
  the trailing `defimpl Jason.Encoder`. `ModerationAdapterError`'s enum is the
  *same eleven atoms* as `EmbeddingAdapterError`'s. The trigger first fired at
  copy three (Phase 20) and was missed then too. **Consolidation is correctly
  foreclosed here** — it would touch three released error modules, which
  CLAUDE.md's cross-phase discipline forbids inside 22.1 — so per
  `IMPLEMENTATION.md:68` the Module Tree wins and the debt is recorded instead.
  Filed in `ASKS.md` with a self-scoring grep predicate. Proposed shape: a
  `use ALLM.Error.AdapterErrorBase, noun: "moderation adapter", reasons: …,
  extra_fields: […]` macro generating everything from `legal_reasons/0` down,
  each module keeping its own `@moduledoc`, `@type reason`, and `@legal_reasons`.

* **`[DEFERRED-DRY]` — `errors_for/1` test helper, two files.**
  `test/allm/validate_moderation_request_test.exs:8-12` and
  `test/allm/validate_embedding_request_test.exs:7-11` are identical apart from
  the validator called and the expected reason atom.
  `agent-spec/IMPLEMENTATION.md:221` sets the promotion threshold at the second
  referencing file, so the trigger has fired. Four lines, low divergence risk;
  lift to `test/support/` as
  `ALLM.Test.ValidateHelpers.errors_for(validator_fun, expected_reason, struct)`
  with both call sites migrated when the third capability family arrives.

### `[CARRY]` entries

* **`[CARRY]` — the released `Fake*` siblings carry the retry-budget defect
  22.2 fixed.** `lib/allm/providers/fake_embeddings.ex:391` and
  `lib/allm/providers/fake_images.ex:370` both key `bump_retry_visits/2` on
  `{:allm_fake_*_retry_visits, :erlang.phash2(script), cursor}`, ignoring
  `adapter_opts[:cursor_key]` that their own `cursor_key_id/2` honours — the
  exact defect corrected in `fake_moderation.ex` (deviation 6). Two engines
  with distinct `:id`s and content-equal scripts therefore share a retry
  budget in one process, so the second engine skips its scripted
  `{:retry_until_call, n}` errors and succeeds on call one. **Not fixed here:**
  both files are released and outside 22.2's Module Tree; per CLAUDE.md's
  *"shipping safer than an already-released sibling"* rule this is recorded
  AND filed in `ASKS.md` in the same pass, with a self-scoring grep predicate.
  `lib/allm/providers/fake.ex` uses a different multi-call mechanism and is
  not implicated.

### Deferred to the phase-end polish pass

Left unfixed by the 22.2 fix pass per the severity floor (Lows and nits):
code review F7 (harness honesty section under-claims case 7 / case 3's
before-key comment is unobservable with a key present), F8
(`{:flagged, categories}` silently ignores unknown category names, and the
reference and the stub disagree about it), F9 (`interpret_entry/3` has no
catch-all, so an unvalidated malformed entry raises `FunctionClauseError`
rather than returning the tuple invariant 2 requires); and functional review F5 (`gate/1` raises on a
non-list `:input`; the `FakeEmbeddings` sibling behaves identically, and
`Validate.moderation_request/1` shields every façade caller).

Two of those bind later work and are recorded here rather than left only in
the review docs:

* **A conformance case injected OUTSIDE the `describe` block is invisible to
  both harness meta-tests** (functional review F4). Measured: a `test` added
  to `using/1`'s `quote` but outside the `describe` gives 14 tests / 0
  failures — `case_count/0` still reports 10 and the `tags[:describe]` filter
  still counts 10, while the extra test rides into every downstream
  consumer's suite. `conformance/test/allm/test/embedding_adapter_conformance_test.exs:25-31`
  carries a byte-identical meta-test shape, so this is **family-wide and
  inherited**, not introduced by 22.2. Fix shape (22.7): assert against the
  module's total `__ex_unit__().tests` count, not only the describe-filtered
  subset.

* **The behaviour's published `## Minimum impl skeleton` is bound by no
  test** (functional review F6). `test/allm/moderation_adapter_test.exs:28-48`
  compiles its own hand-written source, not the skeleton. The reviewer
  extracted the skeleton via `Code.fetch_docs/1` and compiled it: correct
  today (compiles clean, both gates work), but undefended against drift — and
  the 22.2 fix pass has now edited that skeleton (deviation 8), which is
  exactly the drift the absent test would catch. Fix shape: point the existing
  test at the extracted skeleton.

### Notes for later sub-phases

* **`:no_moderation_adapter` and `:invalid_moderation_request` are live in both
  closed enums but only the latter has a use site in this batch.**
  `EngineError`'s `:no_moderation_adapter` has no producer until 22.3's
  `do_moderate_body/5` nil-adapter clause. This is the design's enum-extension
  table as written; recorded so 22.3 knows the atom is already there and must
  not re-add it.
* **`test/allm/error/engine_error_test.exs:8` and
  `test/allm/error/validation_error_test.exs:8` carry stale hand-maintained
  `@legal_reasons` literals.** Both already omit the Phase 20 atoms
  (`:no_embed_adapter`, `:invalid_embedding_request`) and now also omit this
  batch's. They iterate a *subset*, so they fail open — a new atom is never
  exercised by the "every legal reason produces a non-empty message" loop.
  Out of this batch's tree (CLAUDE.md cross-phase discipline).

  **CORRECTED 2026-08-31 (fix pass, from functional review F3).** The predicate
  originally written here — *"each test module's `@legal_reasons` literal must
  equal `<Module>.legal_reasons()`"* — is **not implementable as written**.
  Neither `ALLM.Error.EngineError` nor `ALLM.Error.ValidationError` exports
  `legal_reasons/0`; calling it raises `UndefinedFunctionError`. Re-measured:

  ```
  $ grep -l 'def legal_reasons' lib/allm/error/*.ex
  lib/allm/error/adapter_error.ex
  lib/allm/error/embedding_adapter_error.ex
  lib/allm/error/image_adapter_error.ex
  lib/allm/error/moderation_adapter_error.ex
  ```

  Four of the nine error modules export it; `engine_error.ex`,
  `validation_error.ex`, `session_error.ex`, `stream_error.ex`, and
  `tool_error.ex` declare `@legal_reasons` as a module attribute only. The
  `[CHORE]` therefore has two runnable forms — pick one:

  1. **Promote the accessor first**, then assert. Add
     `@spec legal_reasons() :: [reason()]` / `def legal_reasons, do: @legal_reasons`
     to the five modules that lack it (mirroring the adapter-error shape, which
     also makes each enum introspectable at runtime for callers), and only then
     replace each test's hand-copied literal with
     `assert @legal_reasons == <Module>.legal_reasons()`. Self-scoring:
     `grep -L 'def legal_reasons' lib/allm/error/*.ex` must be empty.
  2. **Derive the enum from BEAM metadata**, needing no `lib/` change, via
     `Code.Typespec.fetch_types/1` (see the 22.7 `[CHORE]` below, which uses the
     same mechanism and subsumes this one).

* **`[CHORE]` for 22.7 — bind `@type reason` against `@legal_reasons`
  repo-wide** (deferred here from code review F3, Medium; out of 22.1's Module
  Tree, and it touches the whole nine-module error family). Every error module
  declares its closed enum **twice** — once as a `@type reason ::` union for
  Dialyzer, once as a `@legal_reasons ~w(…)a` list for the runtime guard — and
  nothing asserts the two agree. `mix dialyzer` cannot catch a divergence (the
  list is a plain term), and the per-module tests only assert the runtime list
  against a hand-copied literal. All nine were verified in sync at the 22.1
  checkpoint: this is an **unbound invariant, not a live bug**. The design's own
  enum-extension table bolds that *both* declarations must be edited — a rule
  stated in prose and enforced by nobody.

  Add one repo-wide, fail-**closed** audit test that discovers its own subjects
  with `Path.wildcard("lib/allm/error/*.ex")` (per CLAUDE.md's audit-gate rule —
  no hand-maintained literal) and reads the type back from BEAM metadata.
  Verified working against this tree:

  ```elixir
  {:ok, types} = Code.Typespec.fetch_types(mod)
  union = Enum.find_value(types, fn
    {:type, {:reason, {:type, _, :union, args}, []}} -> args
    _ -> nil
  end)
  assert Enum.map(union, fn {:atom, _, a} -> a end) == mod.legal_reasons()
  ```

  Self-scoring predicate: with the audit test in place, deleting one atom from
  any `@legal_reasons ~w()a` list while leaving its `@type reason` union intact
  must turn `mix test` red.

* **`mix run scripts/audit_user_docs.exs` is red on `main`** — **10 hits across
  5 files, exit 1** (re-measured at the fix-pass checkpoint; the "24" originally
  recorded here counted output lines, not hits — see the Verification transcript
  above) — and it is listed as a bare Verification step in every sub-phase of
  this design.

  **Do not diff against a recorded hit set.** That instruction decayed the moment
  anyone cleaned a guide, and 22.7 separately owns cleaning `guides/fakes.md`.
  Per CLAUDE.md's self-scoring-predicate rule, 22.2–22.7 use instead:

  ```
  mix run scripts/audit_user_docs.exs | grep moderation    # must be empty
  ```

  which scores itself, survives any change to the standing baseline, and is the
  form now written into every sub-phase's Verification block in the design doc.
  A non-zero exit from the bare script is **not** a sub-phase's own regression.

---

## Phase 22.2 — Behaviour, engine field, Fake, conformance (Layer B)

**Status: Completed** (2026-08-31). All four review gates ran; artifacts present and non-empty: `.work/reviews/2026-08-31-phase22-2-layer-b/overview.md` (functional, PASS with findings — the harness was adversarially probed with nine non-conforming stubs and went red on the correct case each time), `.work/code-reviews/2026-08-31-phase22-2-layer-b.md` (8 findings, 1 High), `.work/security-reviews/2026-08-31-phase22-2-layer-b.md` (no issues), `.work/design-reviews/2026-08-31-phase22-2-layer-b.md` (N/A — backend-only). Fix pass applied 8 items plus 2 self-discovered corrections, escalated 0, deferred 4 Lows/nits to the phase-end polish pass. Implementer gates all green in both
Mix projects (transcript below); the four review gates have not run. The
orchestrator upgrades this to `Completed` once the review artifacts land.

### Implementation Checklist (22.2.2)

- [x] `lib/allm/moderation_adapter.ex` — three callbacks, the numbered
      eight-item invariant list, the `## Minimum impl skeleton`, the
      `## HTTP transport guidance` and `## Batching` sections, and the closing
      **"Cleanup invariant: none."** paragraph
- [x] `lib/allm/engine.ex` — `:moderation_adapter` at **all eight** sites in the
      design's Engine-extension table, site 8 (`resolve_params/2`'s
      hand-maintained prose deny-list, `:456-459`) included
- [x] `lib/allm/providers/fake_moderation.ex` — script vocabulary, pre-flight
      gates before script consumption, the two-source cursor, the
      `capture_pid` seam
- [x] `test/support/fake_moderation_fixtures.ex` — engine + script builders
- [x] `conformance/lib/allm/test/moderation_adapter_conformance.ex` —
      `@case_count 10`, `case_count/0`, `inputs/1`, `png_bytes/0`, `using/1`,
      the `## Gate cases` and `## What this suite does NOT bind` sections; no
      case body gated on an optional fixture
- [x] `conformance/test/support/fixtures/scripted_moderation_stub.ex`
      (`@max_batch_size 4`, gates ahead of the script) and
      `conformance/test/allm/test/moderation_adapter_conformance_test.exs`
      (three meta-invariants)
- [x] `mix.exs` `groups_for_modules`: `ALLM.ModerationAdapter` → `Behaviours`,
      `ALLM.Providers.FakeModeration` → `Providers` — exactly the two modules
      this sub-phase creates (the gate is fail-closed and bidirectional)
- [x] No `async: true` module in this sub-phase calls `Keys.put/2`,
      `Logger.configure/1`, `System.put_env/2`, or `:telemetry.attach/4`

### Files

**New (lib):** `lib/allm/moderation_adapter.ex`,
`lib/allm/providers/fake_moderation.ex`.

**Modified (lib):** `lib/allm/engine.ex` (eight sites).

**New (conformance):** `conformance/lib/allm/test/moderation_adapter_conformance.ex`,
`conformance/test/support/fixtures/scripted_moderation_stub.ex`,
`conformance/test/allm/test/moderation_adapter_conformance_test.exs`.

**New (test):** `test/allm/moderation_adapter_test.exs`,
`test/allm/providers/fake_moderation_test.exs`,
`test/support/fake_moderation_fixtures.ex`.

**Modified (other):** `test/allm/engine_test.exs`, `mix.exs`, `ASKS.md`.

`README.md` untouched — `git --no-optional-locks diff --stat HEAD -- README.md`
empty.

### Verification transcript (22.2.3)

```
mix test <three focused files>   20 doctests, 87 tests, 0 failures
mix test                         406 doctests, 31 properties, 3242 tests, 0 failures, 14 excluded
mix test --seed 0                406 doctests, 31 properties, 3242 tests, 0 failures, 14 excluded
mix format --check-formatted     clean
mix credo --strict               3013 mods/funs, found no issues
mix dialyzer                     Total errors: 0, Skipped: 0, Unnecessary Skips: 0
mix compile --force --warnings-as-errors   clean
mix docs 2>&1 | grep -ciE '(warning|error)'   0   (0 at baseline too)
mix test --cover                 Total 93.56% (93.50% at baseline — up)
                                 ALLM.ModerationAdapter          100.00%
                                 ALLM.Providers.FakeModeration   100.00%
                                 ALLM.Test.FakeModerationFixtures 80.00%

cd conformance && mix test                     103 tests, 0 failures
                  mix credo --strict           102 mods/funs, found no issues
                  mix format --check-formatted clean
                  mix dialyzer                 Total errors: 0
                  mix test <moderation self-test>  13 tests, 0 failures
                                                   (10 injected cases + 3 meta-invariants)
```

Baseline before the batch: 397 doctests, 31 properties, 3191 tests, 0 failures.
Delta: **+9 doctests, +51 tests, 0 failures.** Zero warnings throughout.

**Self-scoring predicates:**

```
$ mix run scripts/audit_user_docs.exs | grep moderation
(empty)
```

Per the standing predicate (HANDOFF item 3, and the design's 22.1.3 correction),
the bare script's non-zero exit is the `main` baseline — 10 hits across 5 files,
none in moderation — and is not this sub-phase's regression.

```
$ grep -rl 'Keys.put(\|Logger.configure(\|System.put_env(\|:telemetry.attach' test/
```

returns the same 20 pre-existing files as at baseline; **none of this
sub-phase's three new test modules appears in it.**

**No `[CHORE]` commit was needed.** As the design's 22.2.3 note predicted,
`cd conformance && mix format --check-formatted` exits 0 at HEAD —
CLAUDE.md's `image_adapter_conformance.ex:91-92` claim is stale and 22.7 owns
striking it.

### Deviations

1. **[tactical] `FakeModeration` splits "no script" from "script spent".**
   The design specifies the default only for the "no script" case
   (*"Default behaviour with no script: every input yields an unflagged
   result…"*) and was silent on a script whose cursor has run off the end.
   **As shipped in 22.2 both cases took one path** (the clean verdict) on the
   grounds that a synthesized embedding vector is meaningless where a clean
   verdict is not. **Corrected in the 22.2 fix pass** (code review F4): that
   rationale argues for the *no-script* default and does not transfer to a
   spent script, which is almost always an off-by-one in the caller's
   expectation of how many times `moderate/2` is invoked. A truncated
   `[{:retry_until_call, 1}]` script would have reported success on call 1
   with no retry exercised at all.

   Final shape: `:moderation_script` absent or `[]` → default clean verdict;
   a **non-empty** script running off the end (from either `run_scripted/2`
   or `handle_retry_until_call/6`, both routed through `spent_or_default/3`)
   → `{:error, %ModerationAdapterError{reason: :unknown,
   metadata: %{cause: :moderation_script_exhausted}}}`, mirroring
   `FakeEmbeddings`' `exhausted/0`. Recorded in the `@moduledoc`'s
   `## Default verdict (no script)` and new `## Spent script` sections, in the
   design's `Default behaviour with no script` paragraph, and pinned by
   *"running past the end of a NON-EMPTY script errors rather than
   defaulting"*, *"an absent script still yields the default clean verdict"*,
   and *"a retry budget that runs off the end errors rather than reporting
   success"*.

2. **[tactical] `FakeModeration.categories/0` is a public accessor the design
   does not name.** The 13 `omni-moderation` category names are a module
   attribute the adapter synthesizes from; `test/support/fake_moderation_fixtures.ex`
   needs the same vocabulary to build `clean/1`, and a test asserting *"every
   result carries the 13 omni category names"* otherwise hand-copies a
   13-element list. One doctested `@spec`'d accessor, no behaviour change.

3. **[tactical] `provider: :fake` is stamped on every `FakeModeration`
   response.** `%ModerationResponse{}` carries `:provider` (unlike
   `%EmbeddingResponse{}`, so the sibling had nothing to copy). `:fake` is the
   provider atom `ALLM.Providers.Fake` already uses
   (`lib/allm/providers/fake.ex:466`). `ScriptedModerationStub` stamps
   `:stub`, so no conformance case can pass by accident on a shared literal.

4. **[structural, documented] The "minimal impl compiles without warning" test
   binds the module from `Code.compile_string/1`'s return value rather than
   through a module alias.** The sibling shape
   (`test/allm/embedding_adapter_test.exs:28-48`) aliases
   `<TestModule>.MinimalImpl` and then calls it after the capture, which puts an
   undefined-remote-call in the test body itself; Elixir defers that
   diagnostic, and **whether it lands inside the `capture_io` depends on how
   many files the run requires**. Measured: `mix test
   test/allm/embedding_adapter_test.exs` alone **fails** on `assert captured ==
   ""` with that artifact, and passes as soon as a second file joins the run.
   The moderation copy uses `ExUnit.CaptureIO.with_io(:stderr, fn ->
   Code.compile_string(source) end)` and binds `{[{minimal_impl, _}], captured}`,
   so the assertion is about the compiled source and nothing else and the test
   passes as a single-file run. **The sibling is NOT fixed here** — it is
   outside 22.2's Module Tree — and is filed in `ASKS.md` as a `[BUG]` with a
   two-part self-scoring predicate.

5. **[documented] Two design-doc numerals were stale and are corrected in
   place** (`steering/2026-08-31_PHASE_22_moderation.md`): the 22.2 Status row
   (`Not Started` → `Built, gates pending`) and *"Overall Progress: 0/7"*,
   which still read `0` after 22.1 shipped `Completed`.

6. **[fix pass] `bump_retry_visits/3` now keys on `cursor_key_id/2`, and
   `cursor_key_id/2` covers all three precedence sources.** As shipped, the
   retry-visit counter keyed on `:erlang.phash2(script)` + cursor position
   only (`fake_moderation.ex:422-426`), so two engines with distinct `:id`s
   and content-equal scripts got separate cursor slots but a **shared retry
   budget** — engine B would skip its scripted `:rate_limited` returns and
   succeed on call one, contradicting the module's own `## Cursor behaviour`
   guarantee three paragraphs earlier. Nothing tested it. Found independently
   by the code review (F1, High) and the security review (§"Carried forward",
   item 2, as a non-security note). `cursor_key_id/2` additionally gained a
   `:script_cursor` pid clause so the documented direct-call workaround
   disambiguates retry budgets too — unreachable from the two process-dict
   cursor helpers, load-bearing for `bump_retry_visits/3`. Pinned by *"two
   content-equal-script engines with distinct :id values do not share a retry
   budget"* and *"two distinct :script_cursor agents do not share a retry
   budget"*.

7. **[fix pass] Conformance cases 5, 6 and 7 size their input as
   `min(<wanted>, adapter.max_batch_size())`.** As shipped they used the
   literals `4`, `3` and `2`, so the published suite could not certify a
   *conforming* adapter whose cap was below 4: measured red at cap 3 (case 5),
   cap 2 (cases 5, 6) and cap 1 (cases 5, 6, 7, 10). `ScriptedModerationStub`'s
   `@max_batch_size 4` sat exactly on the boundary, so the harness self-test
   gave no warning. Functional review F1 (Medium); it binds **22.4**, whose
   real cap comes from a ladder probe that has not run. Case 6's scramble uses
   `Enum.slide(list, -1, 0)`, which degenerates to the identity at `n == 1`
   and so needs no conditional in the case body (the "no `if`/`case` in a case
   body" property the functional review measured is preserved). Re-verified in
   an isolated copy: 13 tests / 0 failures at caps 4, 3, 2 **and 1**, and the
   suite still goes red for every non-conforming stub (`Good` 0 failures;
   `WrongCardinality` 5+6, `NonSequentialIndex` 6, `BareMap` 9 cases,
   `DropsMetadata` 8+9, `NoGates` 3+4, `AtomKeys` 7, `KeyFirst` 9 cases,
   `ZeroBatch` 1+3+5+6+7 — up from 1+3, because `Harness.inputs(0)` raises,
   which is redder, not greener).

8. **[fix pass] Behaviour invariant 5 measures ITEMS, not raw list
   elements; invariants 9 and 10 appended.** Invariants 3 and 5 contradicted
   each other on multimodal input — 3 says a multimodal `:input` is one item,
   5 gated on `length(request.input)` — observable at cap 1, where conformance
   case 10 goes red for an adapter that gates exactly as 5 instructed
   (functional review F2). The prose fix is accompanied by the three
   implementations that must agree with it: `FakeModeration.gate/1`,
   `ScriptedModerationStub.gate/1` (both now via a shared-shape `item_count/1`)
   and the behaviour's published `## Minimum impl skeleton`. Separately,
   invariants **9** (`request_timeout` → `:timeout`) and **10**
   (`prepare_request/2` semantics) were **appended** — code review F5: both
   were dropped from the embeddings sibling with nothing in their place, while
   `moderation_adapter_error.ex:26` still publishes `:timeout` as *"adapter
   `request_timeout` exceeded"* and 22.3's `@retryable_moderation_reasons`
   retries it. Appended, not slotted in: 1–8 are cited by number from the
   conformance case names and 22.2.4.

9. **[fix pass, pre-existing] `lib/allm/engine.ex`'s three hand-maintained
   prose lists (`:36-37`, `:187`, `:238`) gained BOTH `FakeModeration` and
   `FakeEmbeddings`.** Code review F6 (Low, taken because a false sentence in a
   governed document lands in the discovering commit). `FakeEmbeddings` has
   been missing from all three since Phase 20; `engine.ex` is
   `(MODIFY — 22.2)` in the Module Tree and the omission sits on the same
   three lines, so fixing one word further was cheaper and more honest than
   shipping a list that is still wrong. Behaviour-neutral prose only. The
   design's Engine-extension table still says **eight** sites; these three are
   prose-only comments outside it and are recorded here rather than promoting
   the table to eleven.

10. **[fix pass] `ScriptedModerationStub`'s moduledoc alignment claim
    narrowed.** It read *"An absent or spent script returns one unflagged
    result per input, matching the default verdict
    `ALLM.Providers.FakeModeration` produces"*, which was already stronger
    than the code — driven side by side on `input: ["a", "b"]` the two agree
    on cardinality and `:flagged` but not on category vocabulary (`%{}` vs the
    13 omni names; functional review F3, a nit) — and deviation 1 made it
    materially false for the *spent* half. Narrowed to cardinality and
    `:flagged` for an **absent** script, with the two divergences named
    explicitly. `conformance/mix.exs` `package[:files]` does not ship
    `test/support/`, so this is not published prose; corrected anyway because
    the fix pass is what broke it.

No other deviations. In particular the Engine-extension table's **eight** sites
were applied as a set from the table, not from any prose numeral; site 8 is the
`resolve_params/2` `@doc` prose deny-list and is pinned by
`test/allm/engine_test.exs`'s *"resolve_params/2 does not leak
:moderation_adapter into params"* (the code half) — the prose half is
documentation and has no test.

### `[DEFERRED-DRY]` entries

* **`[DEFERRED-DRY]` — `ALLM.Providers.FakeModeration` vs
  `ALLM.Providers.FakeEmbeddings` cursor machinery.**
  **Scope corrected in the 22.2 fix pass (code review F2).** The entry
  originally named nine functions; the measured clone is **131 of 205
  normalized code lines (64%)** and additionally covers both `gate/1`
  clauses, `run_scripted/2`, `moderate/2`'s body, `script/1` and the
  `validate_entry!/1` + `invalid_entry!/1` skeleton. The named sites are
  therefore: `advance_cursor/2`, `advance_process_dict_cursor/2`,
  `peek_cursor/2`, `cursor_key_id/2`, `start_script_cursor/0`,
  `cursor_index/1`, `maybe_capture/2`, `handle_retry_until_call/6`,
  `bump_retry_visits/3`, `gate/1` (both clauses), `run_scripted/2`,
  `moderate/2`, `script/1`, `validate_entry!/1` and `invalid_entry!/1`. They
  are byte-identical modulo the process-dict key atom
  (`:allm_fake_embeddings_cursor` vs `:allm_fake_moderation_cursor`), the
  error module, the struct in each head, and the exhaustion arm.

  `agent-spec/IMPLEMENTATION.md:68`'s trigger has fired (it arguably fired at
  `FakeImages`, copy two). **Grounds for deferral corrected:** CLAUDE.md's
  cross-phase discipline carries a *named exception* for extraction-trigger
  refactors that are private, behaviour-preserving, leave every public name
  in place and are pinned by the prior phase's own tests — which this one
  would be. The honest ground is therefore `IMPLEMENTATION.md:68`'s "the
  Module Tree wins", not "CLAUDE.md forbids it".

  Proposed shape: an `ALLM.Providers.Support.ScriptCursor` module taking the
  process-dict key atom as an argument —
  `ScriptCursor.advance(:allm_fake_moderation_cursor, script, adapter_opts)` —
  covering roughly half the debt; a
  `use ALLM.Providers.Support.ScriptedAdapter, script_key: :moderation_script,
  error_module: ModerationAdapterError` shape would cover nearly all of it
  across all four fakes.

  **DONE WHEN** (widened — the original predicate, `grep -c 'defp
  advance_process_dict_cursor' lib/allm/providers/*.ex` summing to 0, would
  have scored green with ~40% of the duplication still in place):

      grep -l 'defp advance_process_dict_cursor\|defp bump_retry_visits\|defp maybe_capture\|defp invalid_entry!' lib/allm/providers/*.ex

  must come back EMPTY. Today it returns `fake.ex`, `fake_embeddings.ex`,
  `fake_images.ex` and `fake_moderation.ex`, and it scores partial progress
  honestly as each module is migrated.

  **Both `[DEFERRED-DRY]` entries are filed in `ASKS.md`** as
  `IMPLEMENTATION.md:68` requires — omitted when 22.2 shipped, filed in the
  22.2 fix pass.

* **`[DEFERRED-DRY]` — `ScriptedModerationStub` vs `ScriptedEmbeddingStub`.**
  The two conformance stubs share `start_script_cursor/0`, `advance/1`, both
  `gate/1` clauses, and `build_response/3`'s shape. They are deliberately
  independent per-behaviour fixtures — the embeddings sibling and the image
  sibling (`ScriptedImageStub`) were kept separate for the same reason — and
  a shared base would couple three behaviours' fixtures through one module.
  Recorded rather than extracted; re-evaluate if a fourth stub arrives.

### Notes for later sub-phases

* **The behaviour's numbered invariant list is now the normative citation
  target and its numbering is frozen.** Invariants **5** (batch size) and **6**
  (empty input) both state the *before any I/O and before
  `ALLM.Keys.fetch!/2`* ordering that binds **22.4**: a `moderate/2` that
  resolves the key first passes its own wire tests and fails conformance cases
  3 and 4 only in a keyless CI. Both conformance cases pass **no script**, so
  they are the only two that reach a real adapter's own gates.

* **Invariant 2 is unbound by the conformance suite, deliberately, and the
  suite says so.** Its enforcement is `ALLM.moderate/3`'s `ArgumentError`,
  which **22.3** must ship — copy the wording and the raise from
  `ALLM.EmbeddingBatch.dispatch_chunk/2` (`lib/allm/embedding_batch.ex:140-156`).
  Until 22.3 lands, nothing in the tree enforces it and the harness's
  `## What this suite does NOT bind` section is the only warning a third-party
  adapter author gets.

* **A spent NON-EMPTY `moderation_script` now ERRORS** with
  `%ModerationAdapterError{reason: :unknown,
  metadata: %{cause: :moderation_script_exhausted}}` (deviation 1, corrected
  in the fix pass). Only an absent or `[]` script yields the clean default.
  Binds **22.3+**: a sequence test that runs dry now fails loudly instead of
  reading as a pass — which is the point — so any façade test scripting N
  entries must expect exactly N calls.

* **`@case_count 10` and the case-to-invariant mapping are frozen.** Case 10 is
  the multimodal arm and is written against `FakeModeration` here; **22.5**
  re-runs it unchanged. Adding a case without bumping the attribute turns the
  harness self-test red (it counts `__ex_unit__().tests` filtered on the
  injected describe name, not the constant).

* **`FakeModeration.@max_batch_size` is 32; the OpenAI adapter's is
  independent.** Binds **22.4**, whose cap comes from the ladder probe.
  Conformance case 3 derives its oversized input from
  `adapter.max_batch_size() + 1`, never a literal, so nothing assumes the two
  are equal. `ScriptedModerationStub` keeps its own `4`.

* **The script key is `adapter_opts[:moderation_script]` and the exhaustion
  fallback is a clean verdict, not an error.** Binds **22.4**'s test-injection
  short-circuit (`fetch_moderation_script/1` → `FakeModeration.moderate/2`) and
  binds any 22.3 test that scripts a *sequence* — a script that runs dry
  silently returns unflagged results rather than surfacing
  `:no_scripted_moderation`. Where a 22.3 retry test needs "and then it fails",
  script the failure explicitly.

* **22.1 Deviation 4's doc-tightening is still open for `ALLM.moderate/3`.**
  22.1 recorded that `ModerationAdapterError`'s moduledoc opener,
  its `:batch_too_large` row, and `ModerationResponse`'s `:usage` sentence
  should be tightened into autolinks once their targets exist. 22.2 created
  `ALLM.ModerationAdapter`, so the `max_batch_size()` references may now be
  written as `c:ALLM.ModerationAdapter.max_batch_size/0`; the
  `ALLM.moderate/3` references still cannot be, and **22.3 owns that pass**.
  This batch deliberately did not touch those files (out of Module Tree) and
  wrote its own `ALLM.moderate` references without an arity suffix for the
  same reason — `mix docs` stays at **0** warnings.
