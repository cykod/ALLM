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

---

## Phase 22.3 — Façade, telemetry, capability pre-flight (Layer C)

**Status: Completed** (2026-08-31). All four review gates ran; artifacts present and non-empty: `.work/reviews/2026-08-31-phase22-3-layer-c/overview.md` (functional, PASS), `.work/code-reviews/2026-08-31-phase22-3-layer-c.md` (10 findings, 0 High), `.work/security-reviews/2026-08-31-phase22-3-layer-c.md` (no issues), `.work/design-reviews/2026-08-31-phase22-3-layer-c.md` (N/A — backend-only). Fix pass applied 8 items, escalated 0; both reviewers independently found the capability gate unbound and the fix is mutation-verified in both directions.
both Mix projects (transcript below); the four review gates have not run. The
orchestrator upgrades this to `Completed` once the review artifacts land.

### Implementation Checklist (22.3.2)

- [x] `ALLM.moderation_request/2` + `@moderation_request_field_opts`
      allow-list (`[:model, :options, :metadata]`)
- [x] `ALLM.moderate/3` — `@doc` carrying "Result cardinality is
      type-dependent" (#4), "Batching — there is none" (#5), "No `:usage`,
      but the span still carries the key" (#6) and "Validation policy" (#11),
      plus two doctests (happy path over `FakeModeration`; the
      `:no_moderation_adapter` gate), `@spec`, head + three clauses
- [x] Internals: `@retryable_moderation_reasons`,
      `drop_moderation_request_opts/1`, `do_moderate/3`,
      `do_moderate_body/5` (nil-adapter clause **first**, as a pattern match;
      the `Retry.run/3` wrap in its body per the image convention),
      `build_moderate_dispatch_opts/3` (**no** `:retry_policy` key; ends with
      `Engine.put_cursor_key(engine)`), `dispatch_moderate_attempt/3`
      (per-attempt closure + invariant-2 raise), `fill_moderation_request_id/2`,
      `moderate_stop_extras/1`
- [x] Reused the existing `augment_retry_policy/2` (`lib/allm.ex:1281-1291`
      at 22.2 HEAD) — no third variant added
- [x] `ALLM.Capability.preflight_moderation/2` + the
      `# Private — moderation preflight` block + moduledoc bullet
      ("Five helpers" → **six**)
- [x] `ALLM.Telemetry` — `:moderate` in both `@type span_name` and
      `@valid_span_names`, plus the moduledoc table row (and the two `span/3`
      `@doc` enumerations that hand-copy the same list)
- [x] `lib/allm.ex` — "When to reach for what" table row and both alias blocks
- [x] `test/allm_facade_doctest_inventory_test.exs` `@public_facade` —
      `moderate: 3` and `moderation_request: 2` (fail-**open** gate; both new
      functions carry runnable doctests)
- [x] HANDOFF item 4 — the deferred moderation doc references tightened now
      that their targets exist
- [x] No `async: true` module in this sub-phase calls `Keys.put/2`,
      `Logger.configure/1`, `System.put_env/2`, or `:telemetry.attach/4`

### Files

**Modified (lib):** `lib/allm.ex` (aliases, moduledoc table row,
`moderation_request/2`, `moderate/3`, the moderation internals block),
`lib/allm/capability.ex`, `lib/allm/telemetry.ex`,
`lib/allm/error/moderation_adapter_error.ex` (docs only),
`lib/allm/moderation_response.ex` (docs only),
`lib/allm/moderation_adapter.ex` (docs only).

**New (test):** `test/allm/allm_moderate_test.exs`,
`test/allm/capability_moderation_test.exs`.

**Modified (test):** `test/allm_facade_doctest_inventory_test.exs`.

**No `mix.exs` edit was needed or made.** `ALLM.Capability` and
`ALLM.Telemetry` are already registered in `docs.groups_for_modules`, and this
sub-phase creates no new public module — the fail-closed
`test/groups_for_modules_audit_test.exs` stays green untouched.

`README.md` untouched — `git --no-optional-locks diff --stat HEAD -- README.md`
empty.

### Verification transcript (22.3.3)

```
mix test test/allm/allm_moderate_test.exs
       test/allm/capability_moderation_test.exs   4 doctests, 50 tests, 0 failures
mix test                        416 doctests, 31 properties, 3297 tests, 0 failures, 14 excluded
mix test --seed 0               416 doctests, 31 properties, 3297 tests, 0 failures, 14 excluded
mix format --check-formatted    clean
mix credo --strict              3059 mods/funs, found no issues
mix dialyzer                    Total errors: 0, Skipped: 0, Unnecessary Skips: 0
mix compile --force --warnings-as-errors   clean
mix docs 2>&1 | grep -ciE '(warning|error)'   0   (0 at baseline too)
mix test --cover                Total 93.65% (93.56% at baseline — up)
                                ALLM                  99.36%
                                ALLM.Capability       98.13%
                                ALLM.Telemetry       100.00%

cd conformance && mix test      103 tests, 0 failures   (unchanged — this
                                sub-phase does not touch conformance/)
```

Baseline before the batch: 406 doctests, 31 properties, 3245 tests, 0 failures.
Delta: **+10 doctests, +52 tests, 0 failures.** Zero warnings throughout.

**Self-scoring predicates:**

```
$ mix run scripts/audit_user_docs.exs | grep moderation
(empty)
```

Per the standing predicate (HANDOFF item 11, and the design's 22.1.3
correction), the bare script's non-zero exit is the `main` baseline — 10 hits
across 5 files, none in moderation — and is not this sub-phase's regression.

```
$ grep -rl 'Keys.put(\|Logger.configure(\|System.put_env(\|:telemetry.attach' test/
```

returns the same 20 pre-existing files as at baseline, **plus
`test/allm/allm_moderate_test.exs`**. That hit is a false positive of the same
shape the sibling `test/allm/allm_embed_test.exs:12` already produces: the
moduledoc contains the prose sentence *"a bare `:telemetry.attach/4` in an
`async: true` module would capture other tests' events"*. Verified by a
call-shaped re-grep — `grep -n 'Keys.put(\|Logger.configure(\|System.put_env(\|:telemetry\.attach' test/allm/allm_moderate_test.exs`
returns only line 13, the moduledoc. The file attaches through
`ALLM.Test.TelemetryCapture`, the per-process filter, exactly as the audit
rule requires. `test/allm/capability_moderation_test.exs` mutates
`Application.put_env(:allm, :force_capability_absent, …)` and is therefore
`async: false`, matching `ALLM.CapabilityEmbeddingTest`.

### Gate-binding verification (mutation checks)

The two contract points the batch was most at risk of shipping green-but-wrong
were each falsified by mutating `lib/` and re-running the focused file:

* **Dropping `|> Engine.put_cursor_key(engine)`** from
  `build_moderate_dispatch_opts/3` turns **2 tests red** — *"the engine's
  `:id` is injected as `adapter_opts[:cursor_key]`"* (`nil` vs `987654`) and
  *"two content-equal-script engines with distinct `:id` values do not share a
  cursor"*. Restored and green.
* **Disabling the invariant-2 `raise`** (guarding the `other ->` clause so it
  cannot match) turns **1 test red** — *"an adapter returning a bare map
  raises ArgumentError naming the adapter and invariant 2"*. Restored and
  green. This is the only enforcement of `ALLM.ModerationAdapter` invariant 2
  in the tree; the published conformance suite deliberately does not bind it.

### Deviations

1. **[tactical] The telemetry input counter is `moderation_input_count/1`, not
   a second set of clauses on the existing `input_count/1`.** The Layer-C
   contract says *"`input_count/1` is computed by a two-clause private that
   tolerates a non-list `:input`"*. Both clauses ship exactly as specified
   (`when is_list(input) -> length(input)`; bare struct -> `0`) and the
   tolerant arm is pinned by two tests. Only the name differs: Elixir requires
   clauses of one name/arity to be grouped, and `input_count/1` lives inside
   the `# Internals — embedding …` block, so sharing the name would have meant
   either a compiler warning or interleaving two capability blocks. Sibling
   relationship stated in the new function's comment.

2. **[documented] `ModerationAdapterError`'s `:batch_too_large` row was
   corrected beyond the autolink tightening HANDOFF item 4 asked for.** The
   row read *"`length(request.input) > max_batch_size()`"*, which contradicts
   behaviour invariant 5 as amended in the 22.2 fix pass (the gate measures
   the **item count**, `1` for a multimodal request, not the raw list length).
   Since the row was being edited anyway to autolink
   `c:ALLM.ModerationAdapter.max_batch_size/0`, the false half was fixed in
   the same edit rather than left standing next to a corrected autolink. The
   row also gained the `ALLM.moderate/3`-does-not-chunk clause, replacing the
   embeddings sibling's *"Unreachable through `ALLM.embed/3`, which chunks"*
   framing that had been copied across and is false here (Alternative D).

3. **[tactical] `check_moderation_capabilities/2` keeps the embeddings
   sibling's accumulator-and-reverse shape for a single rule.** With one rule
   the `Enum.reverse/1` is a no-op and the fold is ceremony. Retained for
   family alignment: a second rule slots in as one more `|>` step, and the
   reverse is what keeps the error list in declaration order the moment there
   is more than one. Stated in a comment at the function so a reviewer does
   not read it as accidental.

No other deviations. In particular: the `Retry.run/3` wrap is in
`do_moderate_body/5`'s body (the **image** convention, not the embeddings
one), `build_moderate_dispatch_opts/3` puts **no** `:retry_policy` key —
pinned by *"no `:retry_policy` key leaks into the adapter's dispatch opts"* —
and `augment_retry_policy/2` was reused unmodified.

### Tests beyond the Test Plan

Per `agent-spec/IMPLEMENTATION.md` §4.2 ("Test Plan is a coverage floor, not
ceiling"), these bind Contracts-section invariants the 22.3.1 bullets do not
name:

* Three cursor-key tests (injection, content-equal-engine isolation,
  caller-supplied `:cursor_key` precedence) — the single most important line
  in the batch per 22.2.4, and the two that fail on its removal.
* *"no `:retry_policy` key leaks into the adapter's dispatch opts"* — the
  negative half of the image-vs-embeddings retry-placement divergence.
* Engine-vs-call-site `adapter_opts` precedence (first-wins `++`, not
  `Keyword.merge/2`).
* Multimodal cardinality through the façade, and `multimodal: true` in
  `:start` metadata.
* `flagged_count` over a mixed batch (1 of 3 flagged), so the measurement is
  not satisfiable by `length(results)`.
* `retry: false` on the engine short-circuiting a retryable reason.
* `moderation_request/2` wrapping a bare `%ImagePart{}` list.
* A multimodal arm on `preflight_moderation/2`, pinning that the rule reads
  the ref and never the request.

### `[DEFERRED-DRY]` entries

* **`[DEFERRED-DRY]` — the moderation and embedding façade internals blocks.**
  `do_moderate/3` / `do_embed/3`, `build_moderate_dispatch_opts/3` /
  `build_embed_dispatch_opts/3`, `moderation_input_count/1` /
  `input_count/1`, `fill_moderation_request_id/2` /
  `fill_embedding_request_id/2` and `moderate_stop_extras/1` /
  `embed_stop_extras/1` are near-clones differing by the struct in each head,
  the span name, the measurement key names, and (deliberately) the
  `:retry_policy` key and the `Retry.run/3` placement. `dispatch_moderate_attempt/3`
  is a third copy of the shape `dispatch_image_attempt/3` and
  `EmbeddingBatch.dispatch_chunk/2` already share.
  `agent-spec/IMPLEMENTATION.md:68`'s trigger has fired.

  **Not extracted:** a shared `do_capability_call/…` would have to be
  parameterised by span name, two measurement-key names, a validator, a
  preflight function, a request-field allow-list, a retryable-reason list AND
  the retry-placement divergence — seven axes for three call sites, which is
  worse than the duplication. It would also touch two released capability
  paths from inside a sub-phase whose Module Tree scopes neither. Per
  `IMPLEMENTATION.md:68` the Module Tree wins and the debt is recorded.
  **DONE WHEN** — if ever revisited — a fourth capability façade arrives and
  the axes can be counted against four call sites rather than three.

* **`[EXTRACTED]` (was `[DEFERRED-DRY]`) — the four boolean capability-flag
  matchers in `lib/allm/capability.ex`.**

  **CORRECTED 2026-08-31 (fix pass, from code review F2).** This entry
  originally read *"`check_moderation_enabled/2` vs
  `check_embeddings_enabled/2` … Byte-identical modulo the capability key
  atom/string and the error tuple … at two, collapsing means editing the
  released embeddings path … re-evaluate at the third flag."* **The count was
  wrong and the stated grounds do not hold.** `check_moderation_enabled/2` is
  the **fourth** copy, not the second, so the entry's own re-evaluation
  trigger had already fired a phase before it was written. Re-measured at the
  fix-pass checkpoint:

  ```
  $ grep -n '=> false} ->' lib/allm/capability.ex     # pre-fix
  517:  %{"json_native" => false} -> …        # NOT a member — error path is [:response_format]
  534:  %{"vision" => false} -> …             # Phase 17
  582:  %{"images_enabled" => false} -> …     # Phase 14.3
  637:  %{"embeddings_enabled" => false} -> … # Phase 20
  685:  %{"moderation_enabled" => false} -> … # Phase 22.3
  ```

  All four members are the same six-line
  `case caps do %{key: false} -> …; %{"key" => false} -> …; _ -> acc end`
  block differing on **one** derivable axis: the error atom is
  `:<x>_enabled` → `:<x>_disabled` in three and `:vision` → `:vision_disabled`
  in the fourth, and the error path is `[key]` in all four.

  **Extracted** in the fix pass to one private,
  `reject_when_flag_false(acc, caps, key, error_reason)`, in a new
  `# Private — shared capability-flag rule` section, with **all four** call
  sites migrated in the same edit per CLAUDE.md's migration-on-extraction
  rule. `[structural, documented]`: private, behaviour-preserving, every
  public name unchanged, and the whole of `capability.ex` was already in this
  sub-phase's Module Tree — so this is **not** a cross-phase edit and
  CLAUDE.md's promotion-trigger exception applies directly.

  Behaviour equivalence pinned by the pre-existing matrices, run unchanged:
  `mix test test/allm/capability_vision_test.exs test/allm/capability_image_test.exs
  test/allm/capability_embedding_test.exs test/allm/capability_moderation_test.exs
  test/allm/capability_test.exs` → **11 doctests, 75 tests, 0 failures**. The
  string-key/atom-key tolerance arms and the "a missing key is never a
  rejection" rule survive intact (pin-matched `%{^key => false}` /
  `%{^string_key => false}` clauses in the same order).

  **Deliberately not members:** `check_json_native/3` (capability key
  `:json_native`, error path `[:response_format]` — the `[key]` path does not
  hold) and `check_tools/3` (reads a nested `%{enabled: false}` map). Both
  exclusions are stated in the helper's comment.

  Self-scoring predicate: `grep -c '=> false} ->' lib/allm/capability.ex`
  must be **1** (today: the `json_native` line only).

### Notes for later sub-phases

* **`input_count` on the `:moderate` span is the RAW list length, not the
  *item* count of behaviour invariant 5.** A multimodal request with two
  elements reports `input_count: 2` and `multimodal: true`; the item count
  invariant 5 gates on is `1`. This is deliberate — `multimodal` rides
  alongside precisely so a consumer can derive the item count without a
  second measurement — and it is pinned by *"`:start` carries
  `multimodal: true` for an `%ImagePart{}`-bearing input"*. Binds **22.5**:
  do not "fix" `input_count` to the item count without also amending the
  design's telemetry table and that test.

* **Nothing in the façade resolves a key.** There is no `Keys.fetch!` in
  `lib/allm.ex`'s moderation block; `:api_key` is forwarded verbatim in the
  dispatch opts and the adapter resolves it *after* its own gates (behaviour
  invariants 5 and 6). Binds **22.4**.

* **Capability pre-flight runs in the façade, not in `moderate/2`.** A direct
  `ALLM.Providers.OpenAI.Moderation.moderate(req, opts)` bypasses
  `preflight_moderation/2` by design. Binds **22.4**: do not add a capability
  gate to the adapter, and if a 22.4 test needs the capability rejection it
  must drive `ALLM.moderate/3`.

* **`@moderation_request_field_opts` is `[:model, :options, :metadata]` and
  its symmetry test computes the expectation from
  `Map.keys(%ModerationRequest{})`.** Any sub-phase adding a
  `%ModerationRequest{}` field must add it to the allow-list in the same
  commit or that test goes red — which is the point. 22.5 adds no field
  (`:input`'s element union already accepts `%ImagePart{}`).

* **`ALLM.Telemetry.@valid_span_names` is hand-copied into three places** —
  the attribute, `@type span_name`, and two prose enumerations in `span/3`'s
  `@doc` — with no gate binding them together. All four were updated here;
  a future span name must update all four. The class is CLAUDE.md's
  hand-maintained-literal hazard; a meta-test asserting the `@doc` prose
  against `@valid_span_names` is not obviously worth its cost, so this is a
  note rather than a `[CHORE]`.

* **HANDOFF item 4 is discharged in full.** All three sites named in 22.1
  Deviation 4 now autolink, plus the two bare `ALLM.moderate` references 22.2
  wrote for the same reason. `mix docs` stays at **0** warnings.

### 22.3 fix pass (2026-08-31)

Applied from `.work/reviews/2026-08-31-phase22-3-layer-c/overview.md`
(functional, PASS — 1 Medium, 1 Low, 2 nits),
`.work/code-reviews/2026-08-31-phase22-3-layer-c.md` (10 findings, 0 High),
`.work/security-reviews/2026-08-31-phase22-3-layer-c.md` (no issues) and
`.work/design-reviews/2026-08-31-phase22-3-layer-c.md` (N/A).

**Fixed (8 items):**

1. **Code review F1 + functional review Finding 1 (Medium, found
   independently by both, each with mutation proof) — gate 3 was wired but
   bound by nothing.** Two tests added to `test/allm/allm_moderate_test.exs`'s
   `"moderate/3 gates"` describe: *"gate 3 — `Capability.preflight_moderation/2`
   is wired into the façade"* and *"gate 2 precedes gate 3 — validation wins
   over the capability gate"*. Both drive `ALLM.moderate/3` against an engine
   whose `:model` is a bare `%ModelRef{}` with `moderation_enabled: false` —
   **no** `Application.put_env/3`, so the file stays `async: true`
   (`test/support/llm_db.ex`'s `model(%ModelRef{} = ref), do: ref` identity
   clause makes the override unnecessary, and the `:force_capability_absent`
   route is the documented `async: true` foot-gun the functional reviewer
   flagged). Verified binding by two mutations in an isolated copy: deleting
   the `:ok <- ALLM.Capability.preflight_moderation(...)` clause from
   `do_moderate_body/5`'s `with` turns test 1 red (1 failure, test 2 green);
   **swapping** the two `with` clauses turns test 2 red (1 failure, test 1
   green). Each binds a distinct property.
2. **Code review F2 (Medium) — the second `[DEFERRED-DRY]` entry rested on a
   miscount.** Extracted `reject_when_flag_false/4` and migrated all four call
   sites; the entry above is corrected in place. See that entry for the
   re-measurement and the equivalence pin.
3. **Code review F3 (Medium) — the new telemetry paragraph contrasted against
   a false claim about `:embed`.** `lib/allm/telemetry.ex`'s `:embed` table row
   said `embedding_count` fires "on a **successful** `:stop`" and the
   paragraph beneath said the span "omits `embedding_count` entirely on the
   error path". Both are false: `embed_stop_extras({:error, _})` returns
   `%{embedding_count: 0, chunk_count: 0}` (`lib/allm.ex:1706`) and
   `test/allm/allm_embed_test.exs:558-561` pins *"`embedding_count` is PRESENT
   and `0` on the error path"*. Row and paragraph corrected; the moderation
   paragraph's *"carries **both** its measurements on both paths"* was
   rewritten from a contrast into a statement of fact ("follows the same
   rule"). 22.3 did not introduce the error but inserted a paragraph whose
   rhetorical weight depended on it.
4. **Code review F5 (Medium) — `## Retry`'s attempt-count promise would be
   false the moment 22.4 lands.** `moderate/3`'s `@doc` rewritten to state the
   façade/adapter `Retry.run/3` nesting and its per-reason arithmetic
   (3 attempts at each layer → up to 9 adapter calls for a reason retryable at
   both, up to 3 for one retryable at a single layer) instead of "the budget
   is per call — there is nothing to multiply it by". A
   `#### 22.3.4 Binding on later sub-phases` section was added to the design
   doc so 22.4 implements to it.
5. **Code review F8 (Low, kept because the snippet contradicted its own
   `@doc`) — `## Batching`'s example mis-chunked a multimodal input.** The
   snippet now binds `adapter = engine.moderation_adapter`, is scoped to an
   all-strings `:input`, and is followed by an explicit "do **not** apply this
   to a multimodal `:input`" paragraph pointing at *Result cardinality* and
   `ALLM.ModerationRequest.multimodal?/1`.
6. **Functional review Finding 2 (Low, kept because it documents a published
   telemetry key) — `input_count`'s semantics lived only in a private
   comment.** One paragraph added to `ALLM.Telemetry`'s moduledoc and one to
   `moderate/3`'s `@doc`: `input_count` is the raw `length(request.input)`,
   the *item* count is `1` whenever `multimodal` is `true`, the two agree
   exactly for all-strings input, and a 40-element input carrying one
   `ALLM.ImagePart` reports `input_count: 40` while still sitting under a
   `max_batch_size/0` of 32. The split itself is a **defensible design
   choice** (both reviewers agree) and was not changed.
7. **Code review F7 (Low) — `:telemetry_metadata` was advertised but read
   nowhere.** Dropped from `moderation_request/2`'s `## Options` list. Not
   implemented: adding an unused opt to satisfy a doc is the wrong direction.
   The twin advertisement in `embedding_request/2`'s `@doc`
   (`lib/allm.ex:970-975`) and the strip in `drop_request_opts/1`
   (`lib/allm.ex:1375`) are released code, out of this batch's tree — filed in
   `ASKS.md`.
8. **Code review F10 (Low) — a test name overstated its body.** *"wraps a bare
   `%ImagePart{}` into a one-element multimodal list"* passed `[part]`, so
   `List.wrap/1` was the identity. Renamed to *"a list containing an
   `%ImagePart{}` produces a multimodal request"*, an `req.input == [part]`
   assertion added, and a comment records that a **bare** `%ImagePart{}` is
   outside `moderation_request/2`'s `@spec` and is deliberately not a
   supported call shape. The "Tests beyond the Test Plan" bullet above should
   be read with this correction.

### `[CARRY]` entries

* **`[CARRY]` — the released `embed/3` façade has the identical unbound
  capability gate that F1 fixed for moderation.** The functional reviewer
  established the family shape by mutating all three siblings against the full
  suite: neutering `Capability.preflight_image/2` in `generate_image/3` →
  **2 failures** (`ALLM.CapabilityImageTest`'s *"wired into the façade"*
  cases); neutering `Capability.preflight_embedding/2` in `embed/3` →
  **0 failures**; neutering `Capability.preflight_moderation/2` in
  `moderate/3` → **0 failures**. Moderation inherited the **embeddings** gap,
  not a family-wide one. **Not fixed here:** `test/allm/allm_embed_test.exs`
  and the embeddings façade path are released and outside 22.3's Module Tree.
  Per CLAUDE.md's *"shipping safer than an already-released sibling"* rule
  this is recorded AND filed in `ASKS.md` in the same pass, with a
  self-scoring predicate: *`grep -l unsupported_capability
  test/allm/allm_*_test.exs` must name one file per capability façade*
  (today: `allm_moderate_test.exs` only — `allm_embed_test.exs` missing).

### Deferred to the phase-end polish pass

Left unfixed by the 22.3 fix pass per the severity floor:

* **Code review F6 (Low)** — two counting comments went stale when moderation
  became the third capability: `lib/allm.ex:1495`'s *"Shared by the image and
  embedding call sites"* (now three), and `lib/allm/capability.ex`'s
  `## Where pre-flight runs` moduledoc section, which names only
  `ALLM.StreamRunner.run/3` while three of the module's four preflights run in
  `lib/allm.ex` façade functions. The second half sits directly on a CLAUDE.md
  hard invariant and is the first place a 22.4 adapter author will look — it
  is carried to HANDOFF as well as recorded here.
* **Code review F9 (Low)** — `@retryable_image_reasons`,
  `@retryable_embedding_reasons` and `@retryable_moderation_reasons`
  (`lib/allm.ex`) are the same four atoms declared three times. Rule-of-3
  trigger; zero parameterisation axes. Either collapse to one attribute or
  record the clone deliberately with a *"equal today by coincidence, not by
  contract"* comment on each.
* **Functional review nit** — `test/allm/capability_vision_test.exs:81`
  (`async: true`) calls
  `Application.put_env(:allm, :force_capability_absent, true)` while every
  other file touching that key is `async: false`. Pre-existing; F1's new tests
  deliberately avoid the override so they add no exposure.
* **Functional review nit** — the invariant-2 raise is bound by one shape
  (bare map). The reviewer exercised five and all five raise; the catch-all
  `other ->` clause makes further shapes redundant. No action recommended.
* **`CHANGELOG.md` has no moderation entry yet.** Correct — the phase-end pass
  owns it.

### Deferred to 22.7

* **Code review F4 (Medium) — the `@public_facade` gate is still
  one-directional.** Recorded in full as the second bullet of the design's new
  `#### 22.3.4 Binding on later sub-phases`, with the runnable shape and a
  self-scoring check. Not fixed here: the design's own audit-gate table
  already marks this gate **open** and scopes the bidirectional meta-test as a
  `[CHORE]`, and closing it correctly needs the `@excluded` map plus
  default-arity-head normalisation across the whole façade — beyond a
  moderation fix pass.

### Security carry for 22.4

* **`response.raw` — the verbatim provider body — rides into `:stop`
  telemetry metadata**, exactly as `%EmbeddingResponse{}` and
  `%ImageResponse{}` already do. Benign while no moderation endpoint echoes
  submitted content back, and `FakeModeration` synthesises its own bodies.
  **Re-check when the real adapter lands (22.4):** if `/v1/moderations`
  echoes the submitted input in its response body, that content reaches every
  attached telemetry handler and any log sink behind one. Carried to HANDOFF.

### Post-fix verification (2026-08-31)

```
mix test                        416 doctests, 31 properties, 3299 tests, 0 failures, 14 excluded
mix test --seed 0               416 doctests, 31 properties, 3299 tests, 0 failures, 14 excluded
mix format --check-formatted    clean
mix credo --strict              3060 mods/funs, found no issues
mix dialyzer                    Total errors: 0, Skipped: 0, Unnecessary Skips: 0
mix compile --warnings-as-errors  clean
mix docs 2>&1 | grep -ciE '(warning|error)'   0
mix run scripts/audit_user_docs.exs | grep moderation   (empty)
git --no-optional-locks diff --stat HEAD -- README.md   (empty)
cd conformance && mix test      103 tests, 0 failures
```

Delta against the 22.3 build transcript: **+2 tests** (the two façade
gate-wiring tests), 0 doctest delta, 0 failures. `credo` mods/funs went
3059 → 3060 (the extracted `reject_when_flag_false/4`).

**Mutation ledger — run on isolated copies of the tree, never in place:**

| Mutant | Expected | Observed |
|---|---|---|
| Delete `:ok <- ALLM.Capability.preflight_moderation(resolved_model, request)` from `do_moderate_body/5`'s `with` | the new gate-3 test goes red | **1 failure** across the FULL suite — *"gate 3 — `Capability.preflight_moderation/2` is wired into the façade"*. Before F1's fix the same mutant gave **0**. |
| **Swap** the two `with` clauses (capability before validation) | the gate-order test goes red | **1 failure** — *"gate 2 precedes gate 3 — validation wins over the capability gate"* (the gate-3 test stays green). Each test binds a distinct property. |
| Remove the `%{^string_key => false}` arm from the extracted `reject_when_flag_false/4` | the pre-existing capability matrices go red | **4 failures** across the vision / image / embedding / moderation capability tests — the JSON-rehydrated string-key tolerance is genuinely pinned, so the extraction's equivalence claim is not vacuous. |

Un-mutated, the five capability test files run **11 doctests, 75 tests,
0 failures** — the behaviour-equivalence pin for the four-site extraction.

---

## Phase 22.4 — `ALLM.Providers.OpenAI.Moderation`, text input (Layer B)

**Status: Completed** (2026-09-01). All four review gates ran; artifacts present and non-empty: `.work/reviews/2026-08-31-phase22-4-openai-adapter/overview.md` (functional, PASS — 12 live probe arms re-run independently at $0.00), `.work/code-reviews/2026-08-31-phase22-4-openai-adapter.md` (9 findings, 2 High, both in the recorder), `.work/security-reviews/2026-08-31-phase22-4-openai-adapter.md` (no issues, two independent passes), `.work/design-reviews/2026-08-31-phase22-4-openai-adapter.md` (N/A — backend-only). Fix pass applied 8 items, escalated 0. **Both reviewers independently found the adapter logic itself clean** — a token-normalized diff against the `embeddings.ex` template is superimposable section for section. Every finding was in the recorder, the tests, or the bookkeeping, including three false claims the orchestrator wrote while reconstructing after the implement agent died.

> **Provenance note.** The 22.4 implement agent terminated mid-run on an API session rate limit, before its bookkeeping pass.
>
> **CORRECTED 2026-09-01 (22.4 fix pass; code review F7, functional review Finding 3).** This note previously read "*immediately after writing the `ASKS.md` `[CARRY]` entry*". **No 22.4 `[CARRY]` entry was ever written.** `git diff c15f2c7 wip/22-4-checkpoint -- ASKS.md` adds exactly one line, a `[MILE]` entry describing Phase **22.3**; the agent announced the intent and died before acting on it. The checklist item it refers to (`22.4.3`: *"File the `[CARRY]` ticket in `ASKS.md` naming `lib/allm/providers/openai/images.ex`'s `body_preview` + un-redacted message"*) is **deliberately not being filed now**: the standing Phase-20.4-origin `[BUG]` ticket at `ASKS.md:249` already names `openai/images.ex:1069-1070` (raw 401 text carrying an `sk-proj-` prefix), `:1109-1114` (`inspect(cause)` interpolated into `:message`), and `:1229-1241` + `gemini/images.ex:660` (200-char `body_preview`) — verified still live in `lib/` at HEAD. Both reviewers independently confirmed a new entry would be a duplicate, so the checklist's *purpose* is served by the pre-existing ticket and only the records' claim was wrong. The orchestrator completed the remainder directly: three credo alias-ordering violations and two `mix format` violations (both introduced by the interrupted run and both left unverified because the agent never reached its own gate block), plus this section and the design's `22.4.5 Implementation Notes`. **No implementation logic was written or altered by the orchestrator** — only alias order, formatter output, and documentation.

### What shipped

`lib/allm/providers/openai/moderation.ex` (behaviour impl + **three** `@doc false` test seams — `to_json_body/2`, `to_moderation_adapter_error/4`, `decode_response/4` — alongside the three `@impl` callbacks `max_batch_size/0`, `moderate/2`, `prepare_request/2`; this line said "nine", which is `openai/images.ex`'s count as quoted in `CLAUDE.md`, corrected 2026-09-01 per code review F7), `scripts/record_openai_moderation_fixtures.exs` (four-part probe), eight fixtures (four `recorded/` live, four `synthesized/` with `_comment` markers), three test files, `test/support/openai_fixtures.ex` (moderation loaders delegating to the single `drop_comment/1`), `test/fixtures/openai/README.md` (moderations section — the embeddings gap deliberately not replicated), and `mix.exs` (`ALLM.Providers.OpenAI.Moderation` → `Providers`).

### Verification (orchestrator-run, 2026-08-31, post-repair)

```
mix test                       420 doctests, 31 properties, 3379 tests, 0 failures, 14 excluded
mix format --check-formatted   exit 0
mix credo --strict             3135 mods/funs, found no issues
mix dialyzer                   Total errors: 0, Skipped: 0
mix docs                       0 warnings
audit_user_docs | grep moderation    empty
git diff --stat HEAD -- README.md    empty
```

Baseline after 22.3 was 416 doctests / 3299 tests → **+4 doctests, +80 tests**.

### The probe result that matters

The negative control **came back positive**: `/v1/moderations` returns 200 for an unknown top-level field. Full disposition, the row-by-row `inferred → confirmed` table, the `max_batch_size` ladder, and the `response.raw` security answer are in the design's **22.4.5 Implementation Notes** — recorded there rather than duplicated here because 22.4.5 is a designated slot the design reserves for exactly this.

Three design amendments landed with it, per CLAUDE.md's decision-drift rule: the wire-field map's seven rows were re-marked from the probe; the four-part probe's clause (1) was `CORRECTED` (halting on an accepted invented field would make the recorder permanently unrunnable against a permissive endpoint); and 22.4.6's forward-binding bullet for 22.5 was rewritten, because a paired control cannot settle `detail`'s disposition at an endpoint that ignores unknown fields.

### Deviations

1. **[orchestrator repair, documented]** Alias groups in `moderation.ex`, `moderation_test.exs` and `moderation_wire_test.exs` were reordered to satisfy `Credo.Check.Readability.AliasOrder`, which sorts a `ALLM.{A, B}` brace-group by its **first member**. The credo-clean order is `ALLM.Error.…` → `ALLM.{Keys, Moderation…}` → `ALLM.Providers.…`. The `embeddings.ex` sibling looks different only because its brace group starts with `Embedding`, which sorts before `Error`.
2. **[orchestrator repair]** `mix format` applied to `moderation.ex` (a `defp decode_result_entry/3` head over the line limit) and `moderation_conformance_test.exs` (missing blank line between two `use` calls).

### Binding on later sub-phases

* **`@adapter_max_batch_size 1000` is a FLOOR, not a provider-stated cap** — the ladder found no upper bound. Binds **22.6**: `guides/moderation.md` must read it from `max_batch_size/0` in an `iex>` block, never hard-code `1000`.
* **Acceptance proves nothing at this endpoint.** Binds **22.5**: do not confirm `detail`'s disposition with a 200.
* **`response.raw` carries no echo of submitted input** (verified by recursive walk of the recorded body). Binds any future sub-phase touching telemetry: re-check if OpenAI adds an input echo.

### 22.4 fix pass (2026-09-01)

Applied against the four review docs for `wip/22-4-checkpoint`. **Both reviewers independently confirmed the shipped adapter logic is clean** — a token-normalized diff against the `embeddings.ex` template is superimposable section for section — so every fix below lands in the recorder, the tests, or the bookkeeping. No adapter logic was changed; `moderation.ex`'s only edits are two `@moduledoc`/comment corrections.

**Fixed:**

1. **Code review F2 (High) — the `max_batch_size` ladder verified nothing it claimed to.** `verify_result_count_matches_input/1` asserted only `is_list(Map.get(body, "results"))`; it never received `n`. It is now a closure over the rung's `n` comparing `length(results) == n`. **Re-run live 2026-09-01** — all five rungs 200 with the count matching, `largest accepted n: 1000`, no rejected rungs; `@adapter_max_batch_size 1000` stands and is now *measured*. Proven load-bearing by mutating the comparison to `n + 1`, which turned the rung red and fired `halt_unless_schema_holds/1` before any write. The design's `22.4.5` note carries the full correction.
2. **Code review F1 (High) — `--probe-only` wrote fixtures while printing "nothing written."** `Enum.each(results, &record_probe_body/1)` moved out of `probe_wire_schema/0` into `run/1`'s `true ->` branch, so the contract is enforced by the call graph rather than absorbed by the `overwritable?/1` guard. The header and `test/fixtures/openai/README.md` claims became true without editing them. Verified: the two live `--probe-only` runs above left all four `recorded/` mtimes untouched.
3. **Functional review Finding 1 (Medium) — the invariant-5/6 gate-ordering proof failed open with `OPENAI_API_KEY` exported.** Added the Voyage-style positive control (`test/allm/providers/openai/moderation_test.exs`, `"positive control: a request that passes every gate DOES reach key resolution"`, mirroring `test/allm/providers/voyage/embeddings_test.exs:249-253`). **Measured, not asserted:** with `Keys.fetch!/2` hoisted ahead of `run_gates/2` in `do_moderate/2`, the two files go **6 failures keyless** and — the property this fix creates — **1 failure keyed**, where before the fix a keyed run over the same broken gate was **0 failures / fully green**.
4. **Code review F3 (Medium) — the test-seam banner claimed byte-identity that does not hold.** `redact_key_material/1` and `sanitize_cause/1` do **not exist** in `openai/images.ex` (`grep -cE 'def[p]? redact_key_material' lib/allm/providers/openai/images.ex` → `0`; same for `sanitize_cause`), and `parse_retry_after/1` diverges (`images.ex:1159-1172` falls through to a `parse_http_date/1` stub). All three moved out of the IDENTICAL list; the first two into a new "identical to `embeddings.ex` ONLY" block citing `ASKS.md:249`, the third into DIVERGENT with the template's explanation restored.
5. **Code review F4 (Medium) — `## Retry integration` read backwards from its own test.** Restored the template's disambiguating sentence (`embeddings.ex:131-135`, adapted): the closure returns reason atoms, none of which is in the adapter's own `:default` `retry_on`, so a 500 is *not* retried by the inner loop — cited to `moderation_wire_test.exs:373-381`. Also closes functional review Finding 6 (the direct-call sentence now says "3 for `:timeout`; a reason the adapter's own policy does not retry costs 1").
6. **Code review F6 (Medium) — the fixture-provenance gate's subject set was a hand-maintained literal.** Added two discovered-set meta-tests to `moderation_wire_test.exs`'s `"fixture provenance"` block asserting `@recorded` and `@synthesized` each equal `Path.wildcard/1` over their directory. **Binding on 22.5:** `recorded/multimodal_text_image.json` must be added to `@recorded` or the suite goes red.
7. **Code review F7 / functional review Finding 3 (bookkeeping) — three false claims corrected**, all written by the orchestrator while reconstructing after the implement agent died: the ladder claim in `22.4.5` (item 1 above), "the nine `@doc false` test seams" (there are **three**), and the provenance note's `[CARRY]` claim (no such entry exists; `ASKS.md:249` already covers the risk, so filing a duplicate would be wrong).

**Deferred, recorded not fixed:**

* **Code review F5 (Medium) — recorder scaffolding past the Rule of 3.** `load_dotenv/0` and `overwritable?/1` now stand at **four** byte-identical copies each; three of the four copies are outside 22.4's Module Tree, and `overwritable?/1` is the refuse-to-overwrite guard the whole provenance discipline rests on. (Re-measured during this pass: `scripts/` holds **ten** `record_*.exs` files, not the seven the review states; `grep -l 'defp load_dotenv' scripts/record_*.exs | wc -l` and the same for `defp overwritable?` each return **4**.) Filed as a `[CHORE]` in `ASKS.md` and slotted as a **22.7** candidate. **DONE WHEN** `grep -l 'defp load_dotenv\|defp overwritable?' scripts/record_*.exs` is empty — i.e. no recorder defines its own copy. Extraction shape (from the review): `scripts/support/fixture_recorder.exs` exposing `load_dotenv/1`, `overwritable?/1`, `write!/2`, `pending_paths/1`, `verdict/2`, `record_probe_body/2`; `halt_unless_schema_holds/1` stays per-script because its body is the provider-specific diagnostic and that is the part worth diverging. Migrate all copies in one commit per `agent-spec/IMPLEMENTATION.md`'s "Migration on extraction" rule.
* **Code review F9 and the functional review's Lows/Nits** — left for the phase-end polish pass. (Functional review Finding 6, the `:timeout`-specific direct-call retry sentence, was closed incidentally by fix 5 above.)

**Fixed out of the severity floor, under CLAUDE.md's governed-document carve-out** (a false sentence in a steering register lands in the discovering commit at any severity, because every later reader and agent loads it as truth):

8. **Code review F8 (Low) — prose named `@max_batch_size`, an attribute that does not exist.** The constant is `@adapter_max_batch_size` (`lib/allm/providers/openai/moderation.ex:21`). Corrected at three recorder sites (`:142`, `:308`, and the `halt_unless_schema_holds/1` stderr text — the instruction printed at the exact moment someone needs it) and five design sites. **Re-measured during this pass and F8's census was short by two:** the review listed six sites, but `ALLM.Providers.FakeModeration` also uses `@adapter_max_batch_size` (`lib/allm/providers/fake_moderation.ex:127`), so the design's `:680` and `:1050` were false about the *Fake* adapter too and were corrected with the rest. `conformance/test/support/fixtures/scripted_moderation_stub.ex` genuinely does use `@max_batch_size 4`, so the design's `:709`, `:746` and `:1018` are correct as written and were left alone.

### Security carry for the retro — `adapter_opts[:moderation_script]` is a *safety-control* bypass

Security review informational note **B**, recorded here because the blast radius is novel even though the seam is not. `moderate/2` honours `opts[:adapter_opts][:moderation_script]` unconditionally (no `Mix.env` gate), delegating to `ALLM.Providers.FakeModeration`, which lives in `lib/` and therefore ships. That is byte-identical to the established released pattern (`openai/embeddings.ex:550` and `:244`, `openai/images.ex:489`, `voyage/embeddings.ex:792`) and keys on developer-supplied `adapter_opts` that no request data flows into — an attacker who controls the caller's opts already controls the call. **But this adapter's entire job is to answer "is this unsafe?", so the same seam that stubs an embedding vector here forces a clean verdict.** Pre-existing family surface, not a 22.4 defect, and out of scope for a fix pass. Worth a decision in the Phase 22 retro: either accept it explicitly in the family's docs, or gate the seam behind `Mix.env() != :prod` across all four adapters as one `[CHORE]`.

---

## Phase 22.5 — Image input (Layer B)

**Status: Complete** (2026-09-01). All four review gates ran and a fix pass landed. `/design-review` returned N/A (no front-end), `/security-review` found no issues, and `/functional-review` + `/code-review` between them found three real defects — two of them exceptions escaping `moderate/2`, both reproduced by running the code rather than reading it. See "Fix pass" below.

*Sequencing note: `/security-review` and `/design-review` ran on 2026-09-01 before the session's container died mid-`/code-review`; `/functional-review`, `/code-review` and this fix pass ran after recovery, against a working tree byte-identical to the `wip/22-5-checkpoint` tag the earlier two reviewed.*

### What shipped

| File | Change |
|------|--------|
| `lib/allm/providers/openai/moderation.ex` | MODIFY — three new `@doc false` seams (`to_openai_content_blocks/1`, `part_to_block/1`, `gate_images/2`), `wire_input/1` + `detail_drop_check/1` + `warn_detail_dropped_once/0` + the `image_gate_*` / `validate_item/3` / `resolvable?/1` privates, gate 3 wired into `run_gates/2`, moduledoc grown by four sections |
| `test/allm/providers/openai/moderation_vision_test.exs` | NEW — 26 tests across five describes |
| `test/allm/allm_moderate_test.exs` | MODIFY — one test (real-adapter cardinality) + two aliases |
| `test/allm/providers/openai/moderation_wire_test.exs` | MODIFY — `multimodal_text_image` added to `@recorded`; moduledoc counts 8→9 / 4→5 |
| `scripts/record_openai_moderation_fixtures.exs` | MODIFY — multimodal arm, `detail` companion arm, `print_detail_disposition/1`, `multimodal_input/1`, `verify_multimodal/1`, `image_typed/1`, header note |
| `test/fixtures/openai/moderations/recorded/multimodal_text_image.json` | NEW — **live recording, 2026-09-01** |

Seam count on the adapter: **three → six** `@doc false` seams.

### The live result the whole design rests on

**The cardinality claim is CONFIRMED on the wire.** The multimodal arm posted OpenAI's documented two-block shape — one `{"type":"text"}` block plus one `{"type":"image_url"}` block carrying an inlined 1x1 PNG as a `data:` URI — in a single `input` array, and the response carried **exactly one** `results` entry:

```
ok   200     (want 200)  multimodal text+image (ONE result for a two-block input)
  (one result; applied types mentioning "image": self-harm, self-harm/instructions,
   self-harm/intent, sexual, violence, violence/graphic)
```

The recorded body has `len(results) == 1`, `results[0].flagged == false`, and a `category_applied_input_types` map in which six of the thirteen categories list `"image"` — so the image was genuinely classified rather than silently dropped, which a bare "one result" count alone would not have distinguished from the provider ignoring the image block. That distinction is what makes the arm evidence for **`ALLM.ModerationRequest`'s cardinality rule** rather than merely consistent with it. A two-element string array returns two results (22.4's `batch_mixed` arm); the same two-element array with an `%ImagePart{}` in it returns one.

`verify_multimodal/1` asserts `length(results) == 1` and halts the recording pass on anything else, so the day OpenAI starts returning one result per block this script goes red rather than the library quietly disagreeing with its own `@doc`.

**Data URIs are accepted** by `/v1/moderations`, so the arm depends on no third-party image host and re-records identically. This was not documented and is now observed.

### `detail`: still inferred, and now known to be unresolvable here

The design's checklist called for a negative control sending `detail` inside `image_url` and reading the disposition off the status. 22.4's own control had already falsified the premise (this endpoint 200s unknown top-level fields), and 22.4.6's forward-binding block superseded the checklist line. 22.5 shipped a **paired companion** instead: the identical multimodal body with `detail: "low"` added.

```
ok   200     (want 200)  detail: "low" inside image_url (disposition is response-observable only)
-- `detail` disposition (response-observable evidence only) --
  IDENTICAL category_scores
```

Neither observation promotes the row, and the recorder prints exactly that: acceptance is not evidence at a permissive endpoint, and score equality is not evidence either (a `detail` that *were* honoured need not move the scores for a 1x1 PNG). The wire-field map row now reads **INFERRED, and confirmed unresolvable 2026-09-01**. Decision #8 stands on OpenAI's documented request shape, which carries no `detail` key.

**Consequence for the suite:** because the wire cannot hold this decision, `moderation_vision_test.exs`'s *"emits NO detail key, at any `:detail` value, for either image source"* — six assertions across `{:auto, :low, :high} × {binary-source, url-source}`, checking both the nested and the sibling position — is the **only** thing binding it. Treat it as a contract test, not a unit test.

### Deviations

1. **[contract, documented] `gate_images/2`, not `reject_oversized_images/1`.** The seam table specified `reject_oversized_images/1`; both halves were corrected, the arity during implementation and the name in the fix pass. Arity: every error this adapter surfaces carries `opts[:request_id]` through `build_metadata/2` — its sibling gates `gate_empty_input/2` and `gate_batch_size/2` both take `opts` for exactly that reason, and a `/1` gate could not. Name: *oversized* described one of the FIVE shapes the gate rejects, and the `gate_*` prefix matches the siblings it sits beside in `run_gates/2`. Both corrections landed in the design's seam table and its 22.5.2 checklist in the same commit as the code; a test pins the arity (*"errors carry `opts[:request_id]` like every other error this adapter surfaces"*).

2. **[design claim corrected] `:missing_mime_type` is NOT reachable via `ALLM.Image.from_url/1`.** The design's checklist justified the third `ImageMime.validate/2` arm with "`ALLM.Image.from_url/1` infers no MIME type". It does not infer one — but a `{:url, _}` source takes `validate/2`'s **first** clause (`lib/allm/providers/support/image_mime.ex:94-103`), which explicitly accepts a `nil` mime because URL sources defer size and type to the provider. The arm is reachable via `ALLM.Image.from_file/1` on an extension absent from `@ext_to_mime` (`lib/allm/image.ex:98-101`), or a hand-built `%ALLM.Image{}`. The conclusion — handle the arm or ship a `CaseClauseError` from inside `moderate/2` — is unchanged; only the reason was wrong. Both the reachable path and the URL non-path now have tests.

3. **[structural, documented] `wire_input/1` inlines `ModerationRequest.multimodal?/1`'s predicate rather than calling it.** Measured, not preferred: `multimodal?/1` is specced `t() :: boolean()`, so calling it on `to_json_body/2`'s binding refines that binding to the full declared `ModerationRequest.t()`, which makes the **released 22.4** catch-all clauses `model_pair(_request)` and `stringify_option_keys(_options)` provably dead and turns `mix dialyzer` red with two `pattern_match_cov` errors. Verified by experiment: with `multimodal?/1` called → `Total errors: 2`; with the predicate inlined → `Total errors: 0`, nothing else changed. Those clauses are dead by type but **alive by test** — `to_json_body/2` is a public `@doc false` seam and `moderation_test.exs`'s *"an off-shape `:options` is ignored rather than raising"* drives exactly the shape the type says cannot exist — so deleting them to satisfy dialyzer would break a released test, remove a real defence at a public entry point, and edit released code outside this sub-phase's tree. The clone is one `Enum.any?/2` line (two instances, Rule of 3 not tripped), its reason is recorded in a comment block on `wire_input/1`, and *"to_json_body/2 branches on exactly what multimodal?/1 reports"* pins the two implementations against drift across seven `:input` shapes.

4. **[scope] The two `test/allm/allm_moderate_test.exs` Test Plan bullets were already green at 22.5's parent** — 22.3 shipped both against `FakeModeration` (`:282`, `:690`). Rather than duplicate them, 22.5 added the test they cannot be: the same cardinality rule through the **real** adapter against the live recording, where the single result is the provider's rather than ALLM's own synthesis. The Test Plan bullets are struck in-line in the design with that reasoning.

5. **[doc]** `## Pre-flight gates` gate 3's prose originally cited "(Decision #7)". `mix run scripts/audit_user_docs.exs` flags `\bdecision\s*#?\s*\d+` in user-facing docs, and the gate's predicate is `| grep moderation` → empty. Reworded to state the rule instead of citing its number.

### Verification (2026-09-01)

```
mix test                                   420 doctests, 31 properties, 3410 tests, 0 failures, 14 excluded
mix test --seed 0                          420 doctests, 31 properties, 3410 tests, 0 failures, 14 excluded
mix format --check-formatted               exit 0
mix credo --strict                         3160 mods/funs, found no issues
mix dialyzer                               Total errors: 0, Skipped: 0, Unnecessary Skips: 0
mix docs                                   0 warnings
mix run scripts/audit_user_docs.exs | grep moderation      empty
git --no-optional-locks diff --stat HEAD -- README.md      empty
cd conformance && mix test                 103 tests, 0 failures   (case 10 included)
cd conformance && mix credo --strict       103 mods/funs, found no issues
cd conformance && mix format --check-formatted             exit 0

env -u OPENAI_API_KEY mix test \
  test/allm/providers/openai/moderation_test.exs \
  test/allm/providers/openai/moderation_vision_test.exs \
  test/allm/providers/openai/moderation_conformance_test.exs
                                           4 doctests, 78 tests, 0 failures
```

Baseline after 22.4 was 420 doctests / 3382 tests → **+28 tests, +0 doctests** (the new seams are `@doc false`, so they add no doctest).

**BLOCKING live gate — ran, green, $0.00.**

```
set -a; . ./.env; set +a; mix run scripts/record_openai_moderation_fixtures.exs

-- OpenAI moderations wire probe (live, 9 requests) --
  ok   200  CONTROL: not_a_real_field is IGNORED, not rejected (permissive endpoint)
  ok   200  model omitted (server default applies)            (server default: "omni-moderation-latest")
  ok   200  clean single string                               (usage absent; x-request-id present; no input echo)
  ok   200  flagged string
  ok   200  batch of 3 strings
  ok   400  shut-down model name text-moderation-latest
  ok   200  multimodal text+image (ONE result for a two-block input)
  ok   200  detail: "low" inside image_url
  ok   401  BAD KEY                                            (echoes submitted key material: false)
-- `detail` disposition --   IDENTICAL category_scores
-- max_batch_size ladder --  1, 32, 100, 128, 1000 all 200; largest accepted n: 1000; rejected rungs: (none)
  ✓ recorded test/fixtures/openai/moderations/recorded/multimodal_text_image.json
```

Every 22.4 arm was re-run and re-passed; `@adapter_max_batch_size 1000` re-measured and unchanged.

### Gate-binding verification (mutation checks)

Prose is not evidence. Three claims were checked by mutation rather than asserted:

1. **The image gates really do fire ahead of `ALLM.Keys.fetch!/2`.** Hoisting `Keys.fetch!(:openai, opts)` to the top of `do_moderate/2` turns `moderation_vision_test.exs` **5 failures / 25 tests** in a keyless shell. The positive control (*"a multimodal request that passes every gate DOES reach key resolution"*) is what stops the ordering proof passing vacuously in a shell that has sourced `.env`, exactly as 22.4's fix pass established for gates 1 and 2.
2. **`@recorded`'s discovered-set meta-test bound the new fixture.** Adding `multimodal_text_image.json` without adding it to the literal is red by construction — the 22.4 fix pass's meta-test compares the literal against `Path.wildcard/1`. The literal was updated in the same commit as the fixture, as the handoff item required.
3. **`--probe-only` still writes nothing.** `stat` on all five `recorded/` mtimes before and after a full `--probe-only` run: identical. 22.4's fix 2 (moving `record_probe_body/1` into `run/1`'s `true ->` branch) is preserved — `print_detail_disposition/1` was added *inside* `probe_wire_schema/0` and only prints.

A fourth was checked by re-run rather than mutation: the recorder is idempotent. A second full invocation against the now-complete tree made **zero HTTP requests** and printed the "nothing to record" message.

### `[CARRY]` entries

**One new, filed in the fix pass — and RESOLVED 2026-09-02 in a follow-up `[BUG]` commit, which found it was three sites wider than filed.** `lib/allm/providers/openai.ex:1864` — the released Chat Completions vision translator carries the identical `{:ok, uri} = Image.to_data_uri(img)` hard match that fix 1 below removed here, and raises the identical `MatchError` for a `{:file, path}` whose file is missing. Verified directly, not inferred from similarity. Released code outside 22.5's Module Tree, so fixing it here would violate CLAUDE.md's cross-phase discipline; shipping the moderation adapter safer than its released sibling is the documented correctly-scoped deviation, and this is the ticket that rule requires in the same pass. Filed in `ASKS.md`.

*Resolution (2026-09-02, separate `[BUG]` commit).* The defect was on **four** translators, not one: `openai.ex` at both endpoints and `anthropic.ex` (`MatchError`) plus `gemini.ex` (`File.Error` from `File.read!/1`) — all four reproduced before any code changed. It was fixed at the shared gate rather than at the translators: `ImageMime.check_byte_size/1` stopped folding "cannot read the bytes" into "no size objection" and now returns `{:error, {:unresolvable_image, reason}}`, which reaches OpenAI's and Anthropic's `generate/2` and `stream/2` through `validate_request/2`. Gemini keeps its own gate (`validate_request/2` accepts only `:openai | :anthropic`) and gained a readability clause. **Consequence for this adapter:** the local `resolvable?/1` added in the fix pass was removed as redundant, and `gate_images/2` now gets resolvability from `ImageMime.validate/2` along with MIME and size. The premise guard written to protect that arm went RED on the change — as designed — and was rewritten to assert the new premise from the other side. The translators, here and in the chat adapters, remain total only over what the gate admits and still raise on a direct call; that is deliberate and is now asserted on purpose rather than left implicit.

The standing `ASKS.md:249` `[BUG]` (raw provider text and `body_preview` in `openai/images.ex` / `gemini/images.ex`) is unchanged and still covers the family's redaction gap; 22.5 added no error path that copies provider text — every image-gate error message is composed from ALLM-side values (an index, a MIME string the caller supplied, a byte count, and now an `Image.to_data_uri/1` failure reason such as `:enoent`, which is a POSIX atom rather than provider text).

### `[DEFERRED-DRY]` entries

* **`detail_drop_check/1` + `warn_detail_dropped_once/0` — three copies.** `lib/allm/providers/gemini.ex:755-773`, `lib/allm/providers/anthropic.ex:883-899`, and now `lib/allm/providers/openai/moderation.ex`. Identical modulo the process-dictionary key atom and the log string. `agent-spec/IMPLEMENTATION.md:68` sets the trigger at **two** implementations and is explicit that it is semantic rather than byte-level, so it fired at copy two (Gemini, Phase 16.4) and was missed then; 22.5 shipped copy three. Extraction is correctly deferred — it would edit two released adapters outside this sub-phase's Module Tree — and this entry plus the `ASKS.md` ticket is exactly what IMPLEMENTATION.md:68 requires in that case. The original 22.5 entry claimed no `[DEFERRED-DRY]` and no new `[CARRY]`; both were wrong and are corrected here. **DONE WHEN** `grep -l 'defp warn_detail_dropped_once' lib/allm/providers/*.ex lib/allm/providers/*/*.ex` is empty (today: three files).

### Fix pass (2026-09-01, after the four review gates)

Six findings landed; the two Highs were reproduced by running the code, not by reading it.

1. **[High, F1] An image whose bytes cannot be resolved raised `MatchError` through the public façade.** `ImageMime.check_byte_size/1` deliberately returns `:ok` when `Image.to_binary/1` fails (`image_mime.ex:126-129` — it cannot prove an image is oversized without bytes), so a `{:file, path}` whose file is missing passed BOTH the MIME and the size gate and then hit `part_to_block/1`'s `{:ok, uri} = Image.to_data_uri(img)`. Measured: `ALLM.moderate(engine, ["is this ok?", part])` → `** (MatchError) no match of right hand side value: {:error, :enoent}`. That is `ALLM.ModerationAdapter` invariant 2 violated by ALLM's own bundled adapter, on the mundane input of a path deleted between construction and the call. Fixed by adding a `{:unresolvable_image, reason}` arm to gate 3, where the item's index is already in hand, rather than by adding error handling to the translator — which keeps `part_to_block/1` total by construction.

2. **[Medium, F2] An off-shape item alongside an image raised `FunctionClauseError` on a direct adapter call.** `part_to_block/1` has two heads and no catch-all. `validate_item/2`'s comment claimed the adapter "passes it through to the provider rather than inventing a second opinion" — true on 22.4's all-strings path, false on 22.5's multimodal path, where nothing reaches any provider. Not reachable through `ALLM.moderate/3` (the façade's validator rejects `42` and `nil` first, which is why this is Medium and F1 is High) but `moderate/2` is a public `@behaviour` callback and `agent-spec/IMPLEMENTATION.md:243` is explicit that a defensive arm at a public extension point is not optional. Fixed with a `{:untranslatable_item, item}` arm gated on multimodality, so the all-strings pass-through is preserved verbatim; the false comment was corrected.

3. **[Medium, F4] The `detail`-drop debug log fired on `ImagePart`'s DEFAULT `detail: :auto`.** So every plainly-constructed `ImagePart.new(img)` logged that a field the caller never set was being dropped. `lib/allm/providers/gemini.ex:755` excludes `:auto` explicitly for this reason; `anthropic.ex:883` does not. The family was split and 22.5 had silently taken the noisier arm. Resolved toward Gemini (user decision) with `defp detail_drop_check(:auto), do: :ok`, plus a test and a premise guard asserting the default really is `:auto` — so if that default ever changes, the exclusion stops silently describing an uncommon case.

4. **[Medium, F3] The missing `[DEFERRED-DRY]` record** — see the section above. The seam banner also cited only `anthropic.ex:883` as the mirror and missed `gemini.ex:755`, so a reader auditing the clone from the code found two sites rather than three; corrected.

5. **[Low, F7] `image_gate_message/2` and `image_gate_metadata/2` were parallel dispatch tables** over the identical shapes, called only together. Fix 1 and fix 2 each add a shape, which would have made a 2-place edit a 4-place one. Collapsed into a single `image_gate_detail/2` returning `{message, metadata}` — one clause per shape, and a new shape can no longer be added to one table and forgotten in the other.

6. **[Low, F6] The wire test's moduledoc dated all five recorded fixtures to 2026-08-31.** `multimodal_text_image.json` was recorded 2026-09-01. Fixture-provenance claims are load-bearing in this repo; corrected to name both dates and the phase each belongs to.

**Test-count delta:** `moderation_vision_test.exs` 26 → 33 (five behaviour tests, two premise guards). Full suite 3410 → 3417, 0 failures.

**Premise guards, per `agent-spec/IMPLEMENTATION.md:241`.** Both new gate arms are only non-trivial if the upstream validator does NOT already reject their inputs, so a test asserts exactly that: `ImageMime.validate/2` returns `:ok` for the unresolvable image, with a failure message naming what goes vacuous if it ever stops doing so.

**Premise guards, per `agent-spec/IMPLEMENTATION.md:241`.** Both new gate arms are only non-trivial if the upstream validator does NOT already reject their inputs, so a test asserts exactly that: `ImageMime.validate/2` returns `:ok` for the unresolvable image, with a failure message naming what goes vacuous if it ever stops doing so. The `:auto` exclusion carries the analogous guard — a test asserting `ImagePart.new/1`'s default really is `:auto`, so the exclusion cannot quietly stop describing the common case.

**Every fix was verified by mutation, not asserted.** Each mutant was applied to `lib/` and the focused suite re-run; all three go red, and the tree was restored and re-verified green (33 tests, 0 failures) after each:

| Mutant | Result |
|---|---|
| `validate_item/3`'s `with :ok <- ImageMime.validate(...), do: resolvable?(part)` collapsed back to a bare `ImageMime.validate/2` | **2 failures**, one of them the raw `** (MatchError) no match of right hand side value: {:error, :enoent}` through `ALLM.moderate/3` — i.e. the mutant reproduces the original defect exactly |
| the `{:untranslatable_item, item}` clause replaced by the original catch-all `validate_item(_item, _accept, _multimodal?), do: :ok` | **1 failure** |
| `defp detail_drop_check(:auto), do: :ok` deleted | **1 failure** |

### Verification after the fix pass (2026-09-01)

```
mix format --check-formatted            exit 0
mix compile --warnings-as-errors        exit 0
mix test                                420 doctests, 31 properties, 3417 tests, 0 failures, 14 excluded
mix test --seed 0                       420 doctests, 31 properties, 3417 tests, 0 failures, 14 excluded
mix credo --strict                      3164 mods/funs, found no issues
mix dialyzer                            exit 0
mix docs                                0 warnings
mix run scripts/audit_user_docs.exs | grep -c moderation     0
git --no-optional-locks diff --stat HEAD -- README.md        empty
cd conformance && mix test              103 tests, 0 failures
cd conformance && mix credo --strict    103 mods/funs, found no issues
cd conformance && mix format --check-formatted               exit 0
```

Baseline before the fix pass was 3410 tests → **+7**. Coverage on `ALLM.Providers.OpenAI.Moderation` measured 94.27% before the pass (`mix test --cover`); the pass added code and tests together. The live recorder gate was **not** re-run and did not need to be: no probe arm, request body, or fixture changed, and the overwrite guard confirms the five `recorded/` files are untouched genuine recordings.

### Notes for later sub-phases

* **The `detail` row can never be promoted from this endpoint.** Binds **22.6**: `guides/moderation.md` must say `ALLM.ImagePart.detail` is dropped and must not imply the wire confirmed it. The evidence is the documented request shape plus an in-code assertion, and that is the strongest evidence available.
* **`recorded/multimodal_text_image.json` is the only fixture in the tree whose `results` length is `1` for a two-element `:input`.** Binds **22.6**: the guide's image section should read the result count from the response rather than stating a number, and should show `ModerationRequest.multimodal?/1` as the pre-call derivation.
* **The adapter now has six `@doc false` seams**, not three: `to_json_body/2`, `to_moderation_adapter_error/4`, `decode_response/4`, `to_openai_content_blocks/1`, `part_to_block/1`, `gate_images/2`. Binds any later doc that quotes the count OR the names (22.4's RECORDS entry was corrected once already for the count, and the fix pass renamed the last one).
* **Data URIs work on `/v1/moderations`.** Binds **22.6**'s `examples/20_moderate_image.exs`: it can inline a small PNG and needs no hosted image, so the script is hermetic and costs $0.00.

---

## Phase 22.6 — Spec §39, guide, examples, docs wiring

**Status: Completed** (2026-09-03). All four review gates ran; artifacts present and non-empty: `.work/reviews/2026-09-03-phase22-6-docs/overview.md` (functional — 8 steps, 3 findings), `.work/code-reviews/2026-09-03-phase22-6-docs.md` (1 High, 3 Medium, 4 Low), `.work/security-reviews/2026-09-03-phase22-6-docs.md` (**clean**; architecture lane self-gated off, no `agent-spec/ARCHITECTURE.md`), `.work/design-reviews/2026-09-03-phase22-6-docs.md` (N/A — backend-only diff). Fix pass applied 3 findings plus 1 Low, deferred 1 to 22.7 and returned 2 fence collisions the orchestrator routed to 22.7.

**The one High was found by all three lanes, and the arch & security lane reached it unprompted** — its brief said nothing about fenced blocks, while the code-review and functional briefs both seeded fence-checking. The orchestrator also reproduced it independently before dispatching the fix pass. `guides/moderation.md`'s flagship "Screening before you generate" recipe referenced a `with`-clause binding inside `else`, where Elixir does not expose it, so the guide's most copy-pasteable block raised `CompileError` on paste. It shipped green because it was a ` ```elixir ` fence and `doctest_file/1` ignores fences — and the prose immediately after it was *about* that `else` clause, so it read as reviewed. **The fix converts it to an `iex>` block rather than repairing the fence**, which is what actually closes the hole: the example runs under `FakeModeration` with no key, so CLAUDE.md's rule says it should never have been a fence.

**Causally upstream, and deferred to 22.7:** `CLAUDE.md:57` claims `test/guides_test.exs` carries "a fenced-API denylist for dead-API references fences can't otherwise flag" and tells agents to extend it. No such gate exists — verified independently by the code reviewer and the orchestrator (`grep -rn 'denylist\|dead_api' test/ lib/ scripts/` returns two unrelated hits; the file is four per-guide structural gates plus three `mix.exs`-wiring tests). The implementer had documented grounds to believe fences carried coverage. 22.7 owns both files.

### What shipped

| File | Change |
|------|--------|
| `steering/allm_engine_session_streaming_spec_v0_2.md` | MODIFY — new **§39** (10 subsections, mirroring §36's structure) plus amendment blocks appended to **§27**, **§29**, and **§35.7** |
| `guides/moderation.md` | NEW — 25,501 bytes, **13 `iex>` blocks** (all executed by `doctest_file/1`), 5 ` ```elixir ` fences. *At the `wip/22-6-checkpoint` tag this row read "12 `iex>` blocks, 5 fences"; the tree actually held 12 and **6** — see Fix pass (2026-09-03), Fix 3.* |
| `mix.exs` | MODIFY — `guides/moderation.md` added to `@guides` (flows into `docs.extras`; `package.files` already names `guides` wholesale) |
| `test/guides_test.exs` | MODIFY — `moderation.md` added to `@guides` (+4 structural gate tests) |
| `test/guides_doctest_test.exs` | MODIFY — `doctest_file("guides/moderation.md")` (+13 doctests; +12 at the checkpoint, +1 from the Fix-pass fence→`iex>` conversion) |
| `examples/_helpers.exs` | MODIFY — `moderation_adapter:` / `moderation_default_model:` on all three `@providers` rows, `moderation_engine/1`, two moduledoc sections; the Fix pass then folded `image_engine/1` + `embedding_engine/1` + `moderation_engine/1` onto a shared private `capability_engine/2` (Fix pass, Fix 2) |
| `examples/19_moderate_text.exs` | NEW — `# Provider: openai` |
| `examples/20_moderate_image.exs` | NEW — `# Provider: openai` |
| `examples/README.md` | MODIFY — `@providers` block, key table (+ moderation column), a `#### Moderation scripts and the # Provider: openai marker` subsection, a `## Moderation (19–20)` narrative section, `ALLM_MODERATION_MODEL` in `## Models`, two script-table rows, cost-note row |
| `CHANGELOG.md` | MODIFY — two bullets **appended** to the existing `## [REL] v0.6.0` entry (see Deviation 2) |
| `ASKS.md` | MODIFY — the `@guides` divergence `[CHORE]` ticket, filed with its self-scoring predicate |

`README.md` was clean at batch start and is untouched: `git --no-optional-locks diff --stat HEAD -- README.md` is empty.

### Deviations

1. **[scope, instructed] The release step was NOT run.** 22.6.2's final checklist bullet reads *"Release via `mix run scripts/release.exs minor` → v0.6.0"*. It was deliberately not executed, and `mix.exs @version` was not touched. **This OVERRIDES 22.6.2's final checklist bullet because publishing to Hex is irreversible and outward-facing, and this run was scoped to building the phase, not releasing it.** Every other checklist bullet is in scope and was completed. The Definition of Done item *"Released as v0.6.0 via `mix run scripts/release.exs minor`"* therefore remains unticked and is the phase's outstanding release action.

2. **[bookkeeping] The `## [REL] v0.6.0 — Content moderation` CHANGELOG entry already existed** at batch start (written 2026-09-03, derived from `git diff v0.5.0..HEAD lib/` as the checklist requires) and was **amended, not re-written**. Verified accurate against `git --no-optional-locks diff --stat v0.5.0..HEAD -- lib/` (24 files, +3551/−105): every file in that diff is represented. Two bullets were appended for 22.6's own user-visible surface, which is not `lib/`-visible and therefore could not have been in the original derivation — `guides/moderation.md`, and the two example scripts plus `ExamplesHelpers.moderation_engine/1` and `ALLM_MODERATION_MODEL`. No second entry was written.

3. **[contract corrected in-place] §39.3's invariant list was rewritten mid-batch to match the shipped numbering exactly.** The first draft renumbered the invariants into a §36.3-shaped list — HTTP-shape conversion first, error-struct hygiene at 8, timeout at 9. That is wrong twice over: `lib/allm/moderation_adapter.ex:130-132` states the numbering is **frozen** because conformance case names and forward-binding notes cite it by number, and error-struct hygiene is not in the shipped numbered list at all. §39.3 now reproduces 1–10 verbatim in the module's order, states that 1–8 are frozen and that 9/10 were appended, and carries error-struct hygiene as an explicitly **unnumbered** obligation with the reason it has no number. The spec is the source of truth for numbering; shipping a spec whose numbering disagreed with the code's would have silently invalidated every by-number citation in the conformance suite.

4. **[scope] `examples/RUN_OUTPUT_OPENAI.md` was NOT regenerated.** The full OpenAI arm did not complete cleanly (it halts at script 10 — see the live gate below), so per the snapshot-defer policy the file is untouched rather than hand-edited.

### Hypotheses put to the tree

| Hypothesis | Verdict |
|---|---|
| `run_all.exs` auto-discovers via `Path.wildcard("[0-9][0-9]_*.exs")` and honours a `# Provider: openai` marker, so scripts 19–20 need no edit to `run_all.exs` | **CONFIRMED.** `examples/run_all.exs:40-41` is the wildcard + sort; `:34-37` is the marker regex `~r/^#\s*Provider:\s*([\w, ]+)\s*$/m`, marker-absent → run everywhere, marker-present-and-not-matching → `[SKIP]` not counted as failed. `run_all.exs` is unmodified and picked both new scripts up. |
| `examples/_helpers.exs` has an `embedding_engine/1` whose shape `moderation_engine/1` should mirror | **CONFIRMED.** It was at `:179-222` before this batch's edits. `moderation_engine/1` mirrors it modulo one deliberate difference: there is no `:moderation_key_env` fallback key, because the only moderation adapter authenticates with the same `OPENAI_API_KEY` as its provider's chat adapter — the Voyage situation that motivated `:embedding_key_env` has no moderation analogue. |
| `doctest_file/1` executes every `iex>` block in a registered guide and ignores ` ``` ` fences regardless of fence type | **CONFIRMED, and verified by mutation rather than by reading.** Registering the guide moved the suite 420 → **432 doctests**, exactly the guide's 12 `iex>` blocks at the checkpoint; its **6** fenced blocks contributed 0 (this cell said 5 at the checkpoint — the miscount is Fix pass, Fix 3). Post-fix-pass the guide has 13 `iex>` blocks and 5 fences, and the suite reads 433. Mutating one expected value (`:no_moderation_adapter` → `:no_such_reason`, `guides/moderation.md:51`) turns `test/guides_doctest_test.exs` **red**, so the gate binds rather than merely counting. Tree restored and re-verified green. |

### Handoff items discharged

* **`ImagePart.detail` is dropped and the wire cannot confirm it.** Applied. The guide's `### ALLM.ImagePart.detail is dropped` subsection states the drop, states that the wire *cannot* settle it (`/v1/moderations` 200s unknown fields, so a 200 proves nothing about schema membership), and names the in-suite contract test as what actually holds the behaviour. It does **not** say the provider confirmed it. §39.7 item 2 carries the same framing, including the paired `detail: "low"` arm's identical `category_scores` and why score-equality is not evidence either.
* **Data URIs are accepted.** Applied. `examples/20_moderate_image.exs` inlines the checked-in `examples/fixtures/kestrel_256.png` via `ALLM.Image.from_binary/2`; no third-party image host, hermetic, $0.00. Ran green live.
* **The cardinality rule is confirmed on the wire.** Applied. Both the guide's *Moderating images* section and script 20 use `ModerationRequest.multimodal?/1` as the **pre-call** derivation and then read the count **off the response** rather than asserting a literal — script 20 asserts the derived count against the returned count, so the two disagreeing is what fails. The guide also explains `:applied_input_types` as the only observable distinguishing "classified and clean" from "ignored", which is the half a bare count cannot show.
* **The audit gate cannot exit 0; the predicate is `| grep moderation` → empty.** Applied and honoured. Baseline re-measured at **10 hits across 5 files** (`guides/fakes.md` 4, `engine.ex` 3, `fake.ex` 1, `fake_images.ex` 1, `validate.ex` 1) — unchanged by this batch, so the new guide and every new doc string contributed **zero** hits. No `decision <n>` form appears in any new prose; the two places that would naturally have cited a numbered decision (the category-map rationale, the no-chunking rationale) state the rule instead.
* **Six `@doc false` seams, `gate_images/2` not `reject_oversized_images/2`.** No new doc names any seam, so nothing to correct. §39 deliberately describes the gate by behaviour rather than by helper name — a spec section naming a private-ish helper would go stale on the next rename, which is the failure this item records.

### Verification (2026-09-03)

```
mix compile --warnings-as-errors            exit 0
mix format --check-formatted                exit 0
mix test                432 doctests, 31 properties, 3429 tests, 0 failures, 14 excluded
mix test --seed 0       432 doctests, 31 properties, 3429 tests, 0 failures, 14 excluded
mix credo --strict      3164 mods/funs, found no issues
mix dialyzer            Total errors: 0, Skipped: 0, Unnecessary Skips: 0
mix docs                grep -ciE '(warning|error)' → 0
mix run scripts/audit_user_docs.exs | grep moderation       empty
git --no-optional-locks diff --stat HEAD -- README.md       empty
cd conformance && mix test                  103 tests, 0 failures
cd conformance && mix credo --strict        found no issues
cd conformance && mix format --check-formatted              exit 0
```

Baseline at batch start was 420 doctests / 3425 tests. Delta: **+12 doctests** (the guide's 12 `iex>` blocks at the checkpoint; **+13 / 433 total** after the Fix pass converted a fence to an `iex>` block) and **+4 tests** (the four per-guide structural gates `test/guides_test.exs` applies to a newly-registered guide: exists, >2 KB, zero audit hits, at least one `iex>` block).

### BLOCKING live gate — ran. $0.00 for both new scripts.

```
set -a; . ./.env; set +a; ALLM_PROVIDER=openai mix run examples/19_moderate_text.exs   → exit 0
  OK: moderate text — results=2 clean_flagged=false threat_flagged=true
      categories=["harassment", "harassment/threatening", "violence"]
      top_score=0.5259 model="omni-moderation-latest" id="modr-9368"

set -a; . ./.env; set +a; ALLM_PROVIDER=openai mix run examples/20_moderate_image.exs  → exit 0
  OK: moderate image — multimodal=true input_elements=2 results=1 index=0 flagged=false
      categories_scored=13
      applied_to_image=["self-harm", "self-harm/instructions", "self-harm/intent",
                        "sexual", "violence", "violence/graphic"]
      model="omni-moderation-latest"
```

Script 20's `applied_to_image` list is the same six-of-thirteen categories the 22.5 recording found, against a different image — independent corroboration that the image is genuinely classified rather than dropped.

### Blocked-arm re-characterization — NOT inherited

`set -a; . ./.env; set +a; ALLM_PROVIDER=openai mix run examples/run_all.exs` halted at **script 10**. Every script from 11 on was then run **individually, past the halt**:

```
01–09 OK, 10 FAIL, 11–12 OK, 13 FAIL, 14–20 OK
```

Two failures, both re-tested against the failure actually observed rather than against the arm's reputation:

1. **`10_generate_image.exs` — FAIL.** `%ALLM.Error.ImageAdapterError{reason: :invalid_request, message: "Unknown parameter: 'response_format'.", status: 400, metadata: %{openai_code: "unknown_parameter", openai_type: "invalid_request_error"}}`. Resolves **exactly** to the `[BUG]` at `ASKS.md:313` — same message, same `openai_code`, same `openai_type`, same originating site (`lib/allm/providers/openai/images.ex:554` sends `response_format` to `dall-e-2`). Released v0.4 code broken against the live API, filed after Phase 20.7 observed it, out of 22.6's docs-only Module Tree. Not a new defect; **no new ticket filed.**
2. **`13_image_variations.exs` — FAIL.** `%ALLM.Error.ImageAdapterError{reason: :unknown, message: "OpenAI HTTP 404", status: 404}`. Resolves to the `dall-e-2` variations 404 documented at commit `a7b934b` and inherited through PHASE_17.3 / 18.5, and named at `ASKS.md:313` as **distinct** from failure 1. Not a new defect; **no new ticket filed.**

The observed line matches `ASKS.md:313`'s own recorded characterization (`01-09 OK, 10 FAIL, 11 OK, 12 OK, 13 FAIL, 14 OK, 15 OK, 16-18 OK`) extended by the two scripts this batch added, with **no** new failure and no movement of either halt point. Both new scripts sit **after** both halts, which is why running them individually is the only observation of them that exists — and both are green.

`examples/RUN_OUTPUT_OPENAI.md` is untouched (Deviation 4).

### Fix pass (2026-09-03)

Applied against `wip/22-6-checkpoint` (`4efb37c`) from the four review artifacts
(`.work/reviews/`, `.work/code-reviews/`, `.work/security-reviews/`,
`.work/design-reviews/`, all dated `2026-09-03-phase22-6-docs`). Three fixes, all
inside 22.6's Module Tree.

**Fix 1 — `guides/moderation.md` *Screening before you generate* was a `CompileError`, and is now an `iex>` block.**
Reported by all four lanes that read the guide; reproduced here verbatim before
acting (`mix run` on the extracted block → `error: undefined variable "verdict"` →
`** (CompileError) cannot compile module`). `verdict` was bound in a `with` clause
and referenced from `else`, where `with`-clause bindings are not in scope
(`elixir/lib/kernel/special_forms.ex` documents this). The repair carries the
verdict across the boundary as `{false, _verdict} <- {flagged?(verdict), verdict}`.

The block was **converted to an `iex>` doctest rather than repaired in place**, per
CLAUDE.md's *"Prefer an `iex>` block for anything Fake can run"* — it runs
end-to-end on `ALLM.Providers.FakeModeration` + `ALLM.Providers.Fake` with no key
and no network, so the fence was never the justified fallback case. One block now
exercises all three branches (clean → `Fake`'s scripted text; flagged →
`{:error, {:rejected, ["violence"]}}`; no adapter → `:no_moderation_adapter`).
**Verified to bind, not merely to run:** mutating the expected `["violence"]` to
`["zzz"]` turns the block red (`1 doctest, 1 failure`), so the conversion closes the
hole rather than moving it. The trailing note, which previously taught `else`
exhaustiveness, now teaches the scoping rule that actually caused the defect.

**Fix 2 — `[structural, documented]` `image_engine/1` + `embedding_engine/1` + `moderation_engine/1` folded onto a private `capability_engine/2`.**
`agent-spec/IMPLEMENTATION.md:68`'s second-caller trigger had fired twice
unrecorded (at `embedding_engine/1` in 20.7 and again here), and `:235` requires
every existing copy migrate in the same commit. The Module Tree does **not**
foreclose it — `examples/_helpers.exs (MODIFY — 22.6)` — so the `[DEFERRED-DRY]`
escape hatch did not apply and the extraction was taken. The three public names,
arities, `@doc` blocks and `ArgumentError` messages are unchanged; the spec map
carries the five differing values and its comment block names the one live
divergence it deliberately preserved rather than normalized (`image_engine/1`
reads `ALLM_MODEL` where its two siblings read a capability-specific variable).

**Behaviour-preservation was measured, not asserted.** A 36-probe matrix — 3
provider arms × {no model overrides, all three model env vars set} × 6 calls
(each constructor bare and with `extra_opts`) — captured `{:ok, %ALLM.Engine{}}`
or `{:raised, ArgumentError, message}` before and after; `diff` over the two
captures, with the unique `%ALLM.Engine{}` `:id` normalized, is **empty**. That
matrix includes all 12 raise paths, so the article difference
("an image_adapter" vs "a moderation_adapter") is pinned byte-for-byte. Both
migrated siblings were additionally re-run live: `16_embed_single.exs` → exit 0
(`dimensions=1536`, `total_tokens=16`). `image_engine/1` has no green end-to-end
arm to re-run — `10_generate_image.exs` is the `ASKS.md:313` `[BUG]` halt — so the
probe matrix is its only observation, which is sufficient because the helper's
entire job is constructing that struct.

**Fix 3 — two false counts corrected.** The *What shipped* row and the
`doctest_file/1` hypothesis cell both said the guide had **5** ` ```elixir `
fences; `grep -c '^```elixir' guides/moderation.md` at the checkpoint returned
**6** (openings at `:32, :83, :260, :396, :425, :525`). The miscount is worth the
line only because the block it loses track of is `:425` — the one that did not
compile — so a hand audit sized against "5 fences" stops one block early. Fix 1
makes the row true for the first time: the guide now holds **13 `iex>` blocks and
5 fences**, measured by `doctest_file/1` (13 doctests) and `grep -c` (5).

`CHANGELOG.md`'s *"Every runnable example executes as a doctest under `mix test`"*
was **verified rather than reworded**, as Fix 1 was the right direction for it.
Each of the five surviving fences depends on something absent from a doctest
context — a provider key (`:32`, `:83`), a local file that does not exist plus an
unbound `engine` (`:260`), an application module `MyApp.Metrics` (`:396`), or
ExUnit's `assert_receive` (`:525` at the checkpoint) — so none is runnable in the
sense the sentence claims. No edit made.

**Not fixed, out of fence.** F4 (the fenced-API denylist CLAUDE.md promises and
`test/guides_test.exs` does not implement) is transcribed to `.work/HANDOFF.md`
for 22.7, which owns both files. Two sibling copies of the Fix-1-adjacent false
claim corrected in the guide — `lib/allm/moderation_result.ex:67-68` and spec
§39 at `allm_engine_session_streaming_spec_v0_2.md:2772` — were left alone and
returned to the orchestrator as fence collisions; both are outside 22.6's
docs-only tree (`lib/` belongs to 22.1, and the spec is a steering document a fix
pass may not amend). The remaining Lows (F5–F8) stay in their review docs for the
phase-end polish pass.

#### Fix-pass gates — full stack re-run

```
mix format --check-formatted                exit 0
mix compile --warnings-as-errors            exit 0
mix test                433 doctests, 31 properties, 3429 tests, 0 failures, 14 excluded
mix test --seed 0       433 doctests, 31 properties, 3429 tests, 0 failures, 14 excluded
mix credo --strict      3164 mods/funs, found no issues
mix dialyzer            Total errors: 0, Skipped: 0, Unnecessary Skips: 0
mix docs                grep -ciE '(warning|error)' → 0
mix run scripts/audit_user_docs.exs | grep moderation       empty (baseline still 10 hits / 5 files)
cd conformance && mix test                  103 tests, 0 failures
cd conformance && mix credo --strict        103 mods/funs, found no issues
cd conformance && mix format --check-formatted              exit 0

set -a; . ./.env; set +a; ALLM_PROVIDER=openai mix run examples/19_moderate_text.exs   → exit 0 (id="modr-6828")
set -a; . ./.env; set +a; ALLM_PROVIDER=openai mix run examples/20_moderate_image.exs  → exit 0
set -a; . ./.env; set +a; ALLM_PROVIDER=openai mix run examples/16_embed_single.exs    → exit 0
```

Doctest delta from the checkpoint is **+1** (432 → 433), exactly the one block Fix
1 converted; test count is unchanged at 3429, confirming nothing else moved.
`mix.exs @version` was not touched and no release step was run.

### Notes for later sub-phases

* **The `@guides` divergence is filed and is 22.7's to close** — `ASKS.md`, dated 2026-09-03, with the self-scoring predicate `diff <(grep -oE 'guides/[a-z_]+\.md' mix.exs | sort -u) <(grep -oE '[a-z_]+\.md' test/guides_test.exs | sed 's|^|guides/|' | sort -u)` → empty. 22.6 registered `moderation.md` in **all three** literals so it does not widen the divergence, but it cannot close it: 22.6's tree is docs-only. **Measured evidence the hazard is live, not theoretical:** `guides/fakes.md` — the one guide in `mix.exs`'s literal and not in `test/guides_test.exs`'s — carries **4 of the repo's 10** banned-token audit hits (two `phase_n`, one `section_marker`, one `spec_section`) and has shipped to hexdocs with them since Phase 16. **[CORRECTED in the 22.7 fix pass: "since Phase 16" was the ticket's wording and is wrong — `85f45d8` (Phase 21, 2026-05-25) both created the guide and registered it in `mix.exs`. Left in place here because this bullet records what 22.6 filed; the correction is authoritative.]** Adding it to the literal in 22.7 turns those into failures; fixing them is in scope for that sub-phase, as its own Test Plan already says.
* **§39 is now the normative home for the invariant numbering**, and it is frozen at 1–10 with 1–8 additionally frozen against renumbering. Anything further appends at 11 in **both** `lib/allm/moderation_adapter.ex` and §39.3, in the same commit. Error-struct hygiene is deliberately unnumbered in both.
* **The commit-range provenance stamp on all four spec blocks is `cf8e340..5a73da6`** — `cf8e340` (22.1) through `5a73da6` (the `[BUG]` follow-up that closed 22.5's `[CARRY]`), with *"docs land in the 22.6 commit"*, mirroring §36's `ac5d845..c3aefce` form exactly. If 22.7 amends any of those four blocks it should extend the range rather than open a second stamp.
* **The release is outstanding.** Deviation 1. `mix.exs @version` is still v0.5.x and must be bumped only by `mix run scripts/release.exs minor`, never by hand.

---

## Phase 22.7 — `[CHORE]` sweep

**Status: Completed** (2026-09-03). All four review gates ran; artifacts present and non-empty: `.work/reviews/2026-09-03-phase22-7-chore/overview.md` (functional — **PASS**, 3 findings), `.work/code-reviews/2026-09-03-phase22-7-chore.md` (1 High, 4 Medium, 4 Low), `.work/security-reviews/2026-09-03-phase22-7-chore.md` (0 High, 0 Medium, 2 Low; architecture lane N/A — no `agent-spec/ARCHITECTURE.md`), `.work/design-reviews/2026-09-03-phase22-7-chore.md` (N/A — backend-only). Fix pass applied 11 sites, deferred 6 to HANDOFF, escalated 0.

**The control this sub-phase exists to ship was verified independently by all three lanes** and holds: redaction is structural at the single `to_image_adapter_error/4` funnel in both adapters, each provider's pattern is genuinely its own (the functional reviewer applied OpenAI's regex to the Gemini credential and got it back unchanged — the silent no-op CLAUDE.md warns about), and `body_preview` is gone from `lib/` on every path, clean through both `inspect/1` and `Jason.encode!/1` at all eight statuses.

**The findings were almost entirely about prose, and two lanes reached that diagnosis independently.** The code was held to a measure-don't-assume standard — mutation-tested gates, the funnel verified by reading, the corruption claim re-measured before editing — and the prose written *about* that code was not. Six unverified claims resulted, most of them landing in permanent documents: `CLAUDE.md:57` traded one false claim ("a fenced-API denylist exists") for two more ("shipped since Phase 16" — it was Phase 21, `85f45d8`; and "no gate of any kind" — the banned-token audit is line-based and does scan fence text, demonstrated by planting a marker inside a fence); the redactors' provenance comments read as exhaustive audits while `error["code"]`/`["type"]`/`["status"]` reach `:metadata` unredacted; a `:cause` count was wrong in both adapters; a self-scoring predicate matched its own record; and the claim that converting `fakes.md`'s fence "caught a shipped defect" was false — the pre-22.7 fence never touched a `%Response{}`, so the `:content` `KeyError` came from assertion lines authored during the conversion.

**The fix pass then corrected three of the reviews' own figures by re-measurement**, including one materially wrong impact claim: `Exception.message/1` *wraps* the `ArgumentError` from a sanitized `%Jason.DecodeError{}` rather than crashing the caller's error handler — degraded diagnostics, not a crash.

### Module Tree — WIDENED

The design's 22.7.1 tree lists seven files. The orchestrator widened it by two before dispatch, and the implementation widened it by four more. Every addition is recorded here rather than in the design.

| File | Origin | Why |
|------|--------|-----|
| `lib/allm/moderation_result.ex` | orchestrator | Carries the same false corruption-signal claim 22.6 corrected in the guide but could not reach (`lib/` belongs to 22.1). |
| `steering/allm_engine_session_streaming_spec_v0_2.md` | orchestrator | §39.4 holds the **normative** copy both other copies derive from. Fixing the derived moduledoc while the normative source stayed wrong is how the claim would recur. |
| `test/guides_doctest_test.exs` | implementer | `test/guides_test.exs`'s `iex>` gate binds on nothing unless the guide is ALSO registered here. Registering `fakes.md` in one literal and not the other would have reproduced, one file over, the exact fail-open shape the sub-phase exists to close. CLAUDE.md's `guides/` bullet already names both files as a pair. |
| `guides/fakes.md` | implementer | The design's own Test Plan scopes it: *"Adding `fakes.md` here also subjects it to the four per-guide gates and to `doctest_file/1`, which may surface real defects in a guide that has never been checked — fixing those is in scope for this sub-phase."* |
| `test/fixtures/openai/images/synthesized/auth_failed.json` (MODIFY) and `test/fixtures/gemini/synthesized/image_auth_failed_key_echo.json` (NEW) | implementer | A redaction test needs a planted subject. See *The planted subjects* below. |
| `test/allm/moderation_result_test.exs` | implementer | The corrected claim is a behavioural claim about `__from_tagged__/1` that no test bound. Without one it can drift back. |

`README.md` was clean at batch start and is untouched: `git --no-optional-locks diff --stat HEAD -- README.md` is empty.

### Hypotheses put to the tree

| Hypothesis | Verdict |
|---|---|
| `conformance/lib/allm/test/image_adapter_conformance.ex` is format-clean at HEAD, making CLAUDE.md's claim stale | **CONFIRMED.** `cd conformance && mix format --check-formatted` → exit 0. `git log --oneline --all -- conformance/lib/allm/test/image_adapter_conformance.ex` shows exactly two commits: `b18ebeb` (Phase 14.1, the origin CLAUDE.md names) and `6282322` *"[OTHR] Clean all compile, test, docs, and conformance warnings"*, which fixed it. The rule survives; the cite had expired. |
| Registering `guides/fakes.md` turns the audit gate red with ~4 hits | **CONFIRMED on the count, and it was not the only thing that went red.** Baseline before: 10 hits / 5 files, `fakes.md` 4 of them (`:114`, `:141` `phase_n`; `:208` `section_marker` + `spec_section`). After: **6 hits / 4 files**. But registration produced **three** failing tests, not one: the audit gate, the *"contains at least one `iex>` code block"* gate (`fakes.md` had **zero** `iex>` blocks — the handoff item did not predict this), and the new `doctest_file/1`-registration parity test. See *What registering `fakes.md` surfaced*. |
| Both image adapters funnel every non-2xx through a single error constructor, so redaction can be structural | **CONFIRMED for both, by reading.** `openai/images.ex` `run_one_attempt/3` → `classify_http_error/4` → `to_image_adapter_error/4`; `gemini/images.ex` has the byte-identical shape at `run_one_attempt/3` → `classify_http_error/4` → `to_image_adapter_error/4`. One redaction site per adapter covers every status. Pinned, not merely asserted, by a per-provider test looping `[400, 401, 403, 404, 429, 500, 503, 418]` through the seam and refuting the planted token at each. |
| (implied by the orchestrator's item 4) The corruption-signal claim is false | **CONFIRMED by measurement before editing.** `ModerationResult.__from_tagged__(%{"flagged" => "true", "categories" => %{"violence" => true}, "category_scores" => %{"violence" => 0.9}, ...})` returns `flagged: false` beside a **fully populated** `categories` and `category_scores`. The three fields decode independently; nothing marks the repair. |

### The CLAUDE.md decision — STRUCK, not built

CLAUDE.md's `guides/` bullet claimed `test/guides_test.exs` carried "a fenced-API denylist for dead-API references fences can't otherwise flag" and instructed agents to extend it whenever they removed a public field or function. No such gate existed. **Decision: strike the claim; do not build the gate.** Five reasons, in descending weight:

1. **A denylist is the very fail-open shape the bullet two lines below warns against.** CLAUDE.md's *"repo-wide audit gate whose subject set is a hand-maintained literal"* rule exists because an unregistered subject produces silence, not a failure. A denylist of dead APIs is a hand-maintained literal whose subject set is *unbounded* (arbitrary prose in arbitrary fences) and whose maintenance trigger — "remember to extend it whenever you remove a public name" — is the same faculty that had just failed. Building it would ship coverage-shaped reassurance over a gate that binds only on what someone remembered.
2. **The proven remedy is not a denylist, it is not being a fence.** 22.6's High finding was closed by converting the offending fence to an `iex>` block; 22.7 closed `fakes.md`'s gap the same way and the conversion immediately caught a wrong API name. `doctest_file/1` is a *discovered-set* gate — it executes every `iex>` block with no literal to maintain — and is therefore strictly stronger than any denylist could be, on exactly the blocks a denylist would target.
3. **The false claim was causally upstream of a real defect.** 22.6's implementer had documented grounds to believe fences carried coverage and shipped an uncompilable one. The fix that removes that belief is a sentence saying fences carry *zero* protection; a partial gate would leave the belief half-standing and the incentive muddled.
4. **Cost lands on every future phase.** A gate whose subject set is prose competes with the `@public_facade` / `@layer_a` / `@guides` machinery already in place and adds a fourth literal to keep honest — while the three existing ones already have known fail-open directions, one of which is still open (see *Not closed here*).
5. **It is not what the sub-phase was scoped to buy.** 22.7's Test Plan asks for the `@guides` parity meta-test, which closes a *measured* fail-open with a *discovered* subject set. That is the same money spent on a gate that cannot fail open.

The replacement sentence names conversion as the only remedy. **As first written it also said "nothing checks what a fence contains — no reference audit, no compile step, no gate of any kind", which the 22.7 fix pass measured false and narrowed:** `scripts/audit_user_docs.exs` is line-based over the whole `.md` (only `.ex` files get `@moduledoc`/`@doc` heredoc targeting), so the banned-token audit **does** see fence contents — planting `# see spec §6.1 for details` inside a fence in a copy of `guides/fakes.md` gave 2 hits against 0 on the file itself. The true, narrower statement now in `CLAUDE.md` is that nothing checks whether the code inside a fence **compiles or names a live API**. Striking one over-claim and writing another in its place is the failure this sub-phase exists to punish. **The word "denylist" was removed from the prose rather than kept inside a denial**, so the handoff's `grep -c denylist` predicate scores honestly (0 and 0) instead of by evasion.

**A second CLAUDE.md correction, not in the design's checklist but forced by this one:** the parity bullet's parenthetical *"note the last two share a name and carry DIFFERENT membership"* becomes false the moment 22.7 makes them equal. Rewritten to *"the last two share a name, and carried DIFFERENT membership until Phase 22.7 made the divergence a test failure."*

**A third, generalising the stale conformance cite:** the design asked for the expired `image_adapter_conformance.ex:91-92` claim to be replaced by *"the general lesson it is now an instance of, not a second stale cite."* The lesson recorded is that **a worked example naming a file:line as *currently* failing is a claim about the tree that expires the moment someone fixes it**, after which it teaches a false fact and sends a later phase to repair something already clean — which is precisely what happened: 22.7's own checklist was written to fix a defect that `6282322` had already fixed. The incident is now in the past tense with its resolving commit.

### What registering `guides/fakes.md` surfaced

Red on registration, three tests:

1. **Four banned-token audit hits**, as forecast. `:114` and `:141` were `## The `:usage` opt (Phase 21.2)` / `## The `:record` opt (Phase 21.2)` — internal build provenance meaningless to a reader, deleted. `:208` carried `section_marker` **and** `spec_section` on one line (`— spec §6.1`); rewritten to name the contract and point at `errors_and_retries.md` instead of a spec section number.
2. **Zero `iex>` blocks.** Not predicted by the handoff item, and worse than the audit hits: the guide is 8 KB of pure ` ```elixir ` fences, so it had *no* drift protection of any kind and the `iex>` gate would have had nothing to bind on even had it been registered. `## Construction` was converted from a fence to an `iex>` block — under CLAUDE.md's *"prefer an `iex>` block for anything Fake can run"* rule it should never have been a fence, since it runs end-to-end on `ALLM.Providers.Fake` with no key and no network.
3. **Not registered with `doctest_file/1`** — caught by the new parity meta-test, and load-bearing: without the registration the converted block would have satisfied the `iex>` gate while still never executing.

**CORRECTED IN THE 22.7 FIX PASS — the original claim here was wrong twice over, and both errors were the same species as the ones this sub-phase was commissioned to strike.** As first written this paragraph read *"the conversion caught a real defect on its first-ever execution … a wrong public field name had been in a guide shipped to hexdocs since Phase 16."* Neither half survives re-derivation:

* **Not a shipped defect.** `git show 45e114f:guides/fakes.md` shows the pre-22.7 `## Construction` fence stopping at `engine = ALLM.Engine.new(…)`; it never called `ALLM.generate/2` and never touched a `%ALLM.Response{}` (`git show 45e114f:guides/fakes.md | grep -n 'content\|output_text\|%ALLM.Response'` returns only prose lines `:19` and `:91`). The `** (KeyError) key :content not found` came from assertion lines authored **during** the conversion, in the same sitting — a doctest catching an authoring slip, not a latent defect being uncovered.
* **Not since Phase 16.** `guides/fakes.md` was created *and* registered in `mix.exs` by `85f45d8` (Phase 21, 2026-05-25); `git log --follow --diff-filter=AR -- guides/fakes.md` and `git log -S 'guides/fakes.md' -- mix.exs` each return that one commit. "Phase 16" was inherited verbatim from the commissioning ticket (`ASKS.md`, 2026-09-03) and never re-derived — the exact failure mode CLAUDE.md's *"a ticket can still be wrong about its own cause"* rule names.

**What the registration actually caught, and it is enough:** a guide `mix.exs` ships to hexdocs with **zero `iex>` blocks** and **four banned-token audit hits**, gated by nothing at all, for a full phase. The argument for converting Fake-runnable fences survives the correction intact and is arguably stronger — the `:content`/`:output_text` slip is direct evidence that `%ALLM.Response{}`'s field name is easy to get wrong when nothing executes the example. What does not survive is citing this as an instance of a *shipped* dead API; a future phase auditing that claim would find nothing.

### The `@guides` parity meta-tests

Four tests in a new `describe "@guides parity"`, plus an `@excluded %{}` map (empty — the healthy state; an entry means a guide ships ungated, which is the hazard the tests exist to surface):

* `every guide mix.exs publishes is gated here` — `mix.exs docs[:extras] \ (@guides ∪ @excluded)`. **The direction that cannot fail open.**
* `every guide gated here is one mix.exs publishes` — the converse; catches a stale literal.
* `every guide on disk is accounted for` — `Path.wildcard("guides/*.md") \ (@guides ∪ @excluded)`. Catches a new guide added to *neither* literal, which neither of the first two can see.
* `every guide is registered with doctest_file/1` — reads `test/guides_doctest_test.exs`'s source and requires the `doctest_file("guides/<name>.md")` line. Closes the third literal CLAUDE.md names as a pair with the second.

`mix_guides/0` reads the shipped set off `Mix.Project.config()[:docs][:extras]` rather than grepping `mix.exs` — the module attribute is unreadable post-compile, and `docs[:extras]` is what ExDoc actually publishes.

**Verified binding by mutation, all four:**

| Mutation | Result |
|---|---|
| Drop `fakes.md` from `test/guides_test.exs`'s `@guides` | **2 red** — "every guide mix.exs publishes is gated here" + "every guide on disk is accounted for" |
| Remove `doctest_file("guides/fakes.md")` from `test/guides_doctest_test.exs` | **1 red** — the `doctest_file/1` parity test |
| Add a phantom `"phantom.md"` to `@excluded` | **1 red** — "every guide gated here is one mix.exs publishes" |
| (restored) | 36 doctests, 51 tests, 0 failures |

### The image-adapter `[CARRY]` — redaction, `sanitize_cause/1`, no `body_preview`

Both adapters, following Phase 20.4's `openai/embeddings.ex` template rather than diverging:

* **`redact_key_material/1` at the single funnel.** `to_image_adapter_error/4` in each — structural, not status-conditional. OpenAI inherits the sibling's `sk-|rk-|org-` pattern **verbatim and correctly** (same provider, same key shapes); Gemini **widens** to `AIza…|ya29.…`, which is the point of the companion tests.
* **Gemini reads the message off the RAW body via `provider_message/2`**, mirroring `gemini/embeddings.ex:873-886`, not off `chat_err.message` — `ALLM.Error.AdapterError` types that field `String.t()` optimistically while `classify_error/3` populates it with `Map.get(error, "message", default)` straight off the body, so a proxy answering `{"error": {"message": 123}}` puts a non-binary there. Sourcing from the body keeps the non-binary arm reachable AND visible to Dialyzer.
* **`sanitize_cause/1` at every `:cause` assignment on the provider-response path**, and `malformed_error/2` no longer interpolates `inspect(cause)` into `:message`. **Count corrected in the 22.7 fix pass** — the original line said "all three `:cause` assignments in each adapter" and both halves were wrong. Re-measured with `grep -n 'cause:' lib/allm/providers/{openai,gemini}/images.ex`: **OpenAI has six** — three sanitized at the response funnel (`:1021`, `:1035`, `:1118` at the time of measurement) and **three in `fetch_url_bytes/2` (`:934`, `:943`, `:952`) that still take the raw exception**; **Gemini has four**, all sanitized (`:541`, `:555`, `:609`, `:661`). The three OpenAI stragglers are inert today because `fetch_url_bytes/2` sets `decode_body: false`, so the only shape `sanitize_cause/1` blanks (`Jason.DecodeError`) cannot arise there — but they were never covered, and the "all three" wording is what would have stopped anyone re-checking. Carried to `.work/HANDOFF.md` rather than fixed here: that path is caller-URL-sourced, not provider-sourced, and hardening it is out of 22.7's fence.
* **`body_preview` removed outright, not replaced.** `grep -rn 'body_preview:' lib/allm/providers/` is empty and `body_preview/1` is deleted from both files. The 2026-07-29 ticket proposed swapping it for the body's sorted top-level key list; **that half was deliberately not taken**, because the 20.4 template that actually shipped passes a bare `%{}` and all three embeddings adapters plus the moderation adapter agree. Family consistency and the 22.7 checklist both say drop. Recorded in the ticket's `[RESOLVED]` line rather than left as a silent omission.
* One pre-existing assertion inverted: `test/allm/providers/openai/images_test.exs` asserted `err.metadata[:body_preview]` was present. Now `refute Map.has_key?(...)`.

**The planted subjects.** A redaction test binds nothing without one.

* **OpenAI** — `test/fixtures/openai/images/synthesized/auth_failed.json` already modelled the key echo, but with `sk-bad`: **the redactor requires 6+ characters after the prefix, so the placeholder was a key-shaped string no pattern could ever match.** Lengthened to `sk-proj-FAKEKEY000111222333444555`, with the reason recorded in the fixture's `_comment`. This provider's redactor guards a **live** channel: OpenAI's real 401 text echoes a prefix of the offending key.
* **Gemini** — new `test/fixtures/gemini/synthesized/image_auth_failed_key_echo.json`, rather than mutating the shared `auth_failed.json` (read by `gemini_test.exs`'s chat tests, which do not redact). Gemini's real 401 (`"API key not valid. Please pass a valid API key."`) carries **no** key material, so this is defence in depth and **not** evidence that any Gemini-authored text reaches the redactor. The `_comment` says so explicitly.
* **The channel that actually routes through the redactor, in both adapters, is `body["error"]["message"]` off any non-2xx response** — which a proxy or gateway in front of the API populates freely. Every other message either adapter constructs is a static literal, and no body preview is carried at all. Recorded in each `redact_key_material/1`'s comment block.

**Verified binding by mutation, four checks:**

| Mutation | Result |
|---|---|
| OpenAI: drop `\|> redact_key_material()` from the funnel | **3 red** |
| OpenAI: `cause: cause` instead of `sanitize_cause(cause)` in `malformed_error/2` | **1 red** |
| **Gemini: inherit the OpenAI `sk-\|rk-\|org-` pattern verbatim** (the silent no-op the companion test exists for) | **3 red** — it fails loudly, exactly as CLAUDE.md requires |
| Gemini: source the message from `chat_err.message` instead of the body | **4 red** |

### The false corruption-signal claim — corrected at both remaining sites

Re-measured before editing (see the hypothesis table). `__from_tagged__/1` decodes `flagged`, `categories` and `category_scores` independently, so a tampered payload comes back `flagged: false` beside a **fully populated** category map with nothing marking it as repaired. The claim that empty category maps are "the honest signal that something is wrong" was false.

Corrected at `lib/allm/moderation_result.ex` (moduledoc, ships to hexdocs) and `steering/allm_engine_session_streaming_spec_v0_2.md` §39.4 (**normative**), both rewritten to match the wording 22.6 landed in `guides/moderation.md`, so all three now agree. `grep -rn "come back empty alongside it" lib/ guides/ steering/allm_engine_session_streaming_spec_v0_2.md` is empty (exit 1, no output — re-run in the 22.7 fix pass). **The predicate as first written scoped `steering/` whole and therefore matched its own prose on this line, scoring itself false** — the identical defect Deviation 1 caught and fixed for the neighbouring `body_preview` predicate one paragraph earlier, missed on the neighbour written in the same pass.

**Plus one test the design did not ask for.** The corrected text is a *behavioural* claim about `__from_tagged__/1` that no test bound — which is how the false version survived from 22.1 to 22.6. `test/allm/moderation_result_test.exs` gains *"a repaired `:flagged` leaves a fully populated category map beside it"*, whose comment names the two documents that were wrong and the phase that corrected them.

### Deviations

1. **[claim correction, in the design doc] 22.7.4's second self-scoring predicate was wrong as written.** `grep -rn 'body_preview' lib/allm/providers/  # expected: empty` returns **one** hit at HEAD *after* the fix: `openai/moderation.ex:223`, a `@doc` sentence stating the struct has no `body_preview`. Corrected in place to the field-assignment form `grep -rn 'body_preview:' lib/allm/providers/`, with the reason in a comment above it. This is CLAUDE.md's own *"design Verification commands SHOULD be runnable as-written"* rule; the token is a substring of prose that legitimately mentions it.
2. **[scope, widening] Four files beyond the orchestrator's tree.** Enumerated with reasons in *Module Tree — WIDENED* above. Three of the four (`test/guides_doctest_test.exs`, `guides/fakes.md`, `test/allm/moderation_result_test.exs`) are consequences the design's own Test Plan anticipates; the two fixtures are the planted subjects a redaction test cannot bind without.
3. **[deliberate non-fix] The ticket's `body_preview` → sorted-key-list replacement was not taken.** Reason above; recorded in the ticket's `[RESOLVED]` line so the divergence is visible to whoever compares ticket to fix.
4. **[tactical] `sanitize_cause/1` fixes contents, not the struct.** Both adapters now blank `Jason.DecodeError.data`, but the sanitized cause remains a struct that does not implement `Jason.Encoder`, so `Jason.encode!/1` on the surrounding error still raises `Protocol.UndefinedError` on the transport/decode paths. Library-wide and pre-existing — `gemini/embeddings.ex:860-869` documents and tickets it — so 22.7 mirrored the siblings rather than diverging, per cross-phase discipline. It is why the redaction tests assert `Jason.encode!(err)` only on the 401 path, where `:cause` is `nil`. Carried to `.work/HANDOFF.md`.

### Verification (2026-09-03)

```
Start Green (base 45e114f)
  mix compile --warnings-as-errors        exit 0
  mix format --check-formatted            exit 0
  mix test        433 doctests, 31 properties, 3429 tests, 0 failures, 14 excluded
  mix credo --strict                      3164 mods/funs, found no issues
  cd conformance && mix test              103 tests, 0 failures

Post-implementation
  mix format --check-formatted            exit 0
  mix compile --warnings-as-errors        exit 0
  mix test        434 doctests, 31 properties, 3451 tests, 0 failures, 14 excluded
  mix test --seed 0                       434 doctests, 31 properties, 3451 tests, 0 failures, 14 excluded
  mix credo --strict                      3171 mods/funs, found no issues
  mix dialyzer                            Total errors: 0, Skipped: 0, Unnecessary Skips: 0
  mix docs                                grep -ciE '(warning|error)' → 0
  mix run scripts/audit_user_docs.exs     6 hits / 4 files (was 10 / 5)
  mix run scripts/audit_user_docs.exs | grep moderation      empty
  git --no-optional-locks diff --stat HEAD -- README.md      empty
  cd conformance && mix test              103 tests, 0 failures
  cd conformance && mix credo --strict    103 mods/funs, found no issues
  cd conformance && mix format --check-formatted             exit 0
```

Deltas: **+1 doctest** (the `fakes.md` block converted from a fence, executed for the first time) and **+22 tests** — 5 per-guide structural gates and 4 parity meta-tests in `test/guides_test.exs`, 6 redaction tests in `openai/images_test.exs`, 6 in `gemini/images_test.exs`, 1 in `moderation_result_test.exs`.

### Self-scoring predicates

```
# design 22.7.4 #1 — the @guides divergence
diff <(grep -oE 'guides/[a-z_]+\.md' mix.exs | sort -u) \
     <(grep -oE '[a-z_]+\.md' test/guides_test.exs | sed 's|^|guides/|' | sort -u)
  → no output, exit 0                                            CLEAN

# design 22.7.4 #2 — as corrected (Deviation 1)
grep -rn 'body_preview:' lib/allm/providers/
  → no output, exit 1                                            CLEAN

# handoff — the fenced-API claim
grep -c denylist CLAUDE.md              → 0
grep -c denylist test/guides_test.exs   → 0                      AGREE

# ASKS 2026-07-29 [BUG] — "grep -rn 'redact' lib/ hits only the new embeddings module"
grep -rln redact_key_material lib/allm/providers/
  → gemini/embeddings.ex, gemini/images.ex, openai/embeddings.ex,
    voyage/embeddings.ex, openai/moderation.ex, openai/images.ex  CLOSED
```

### `ASKS.md` — closed two, left three open

**Closed**, each with its own predicate's actual output in the `[RESOLVED]` line:

* the 2026-09-03 `[CHORE]` for the `mix.exs` / `test/guides_test.exs` `@guides` divergence;
* the 2026-07-29 `[BUG]` to port 20.4's error-struct hardening to the image adapters.

**Left open rather than re-dated**, because none of their files is in 22.7's Module Tree — all three carried to `.work/HANDOFF.md` with their predicates:

* `[CHORE]` recorder-scaffolding extraction into `scripts/support/fixture_recorder.exs`;
* `[CHORE]` close `@public_facade`'s fail-open direction (`test/allm_facade_doctest_inventory_test.exs`) — the same class 22.7 just closed for `@guides`, and the four new parity tests are a directly copyable template;
* `[CARRY]` `fake_embeddings.ex:391` / `fake_images.ex:370` keying `bump_retry_visits/2` on `:erlang.phash2(script)`.

### Live gate — the image arms, because 22.7 edits two released image adapters

22.7.4 lists no live gate and 22.7 ships no example script, but the sub-phase edits `lib/allm/providers/openai/images.ex` and `lib/allm/providers/gemini/images.ex`, so the image scripts were run rather than reasoned about. All invocations sourced `.env` first, per CLAUDE.md.

```
set -a; . ./.env; set +a
ALLM_PROVIDER=openai mix run examples/10_generate_image.exs   → exit 1  (pre-existing)
ALLM_PROVIDER=openai mix run examples/11_edit_image.exs       → exit 0  images=1 bytes=1887530
ALLM_PROVIDER=openai mix run examples/13_image_variations.exs → exit 1  (pre-existing)
ALLM_PROVIDER=gemini mix run examples/10_generate_image.exs   → exit 0  images=1 bytes=914854
ALLM_PROVIDER=gemini mix run examples/11_edit_image.exs       → exit 0  images=1 bytes=409219
```

**Blocked-arm re-characterization — re-tested against the failures actually OBSERVED, not inherited.** Both OpenAI failures resolve to `ASKS.md:313`, and both now print through the funnel this sub-phase modified, which is the observation worth having:

1. `10_generate_image.exs` — `%ImageAdapterError{reason: :invalid_request, message: "Unknown parameter: 'response_format'.", status: 400, cause: nil, metadata: %{status: 400, request_id: "…", openai_code: "unknown_parameter", openai_type: "invalid_request_error"}}`. Same message, same `openai_code`, same `openai_type`, same originating site (`openai/images.ex` sends `response_format` to `dall-e-2`) as 22.6 recorded. **Not a new defect; no new ticket.**
2. `13_image_variations.exs` — `%ImageAdapterError{reason: :unknown, message: "OpenAI HTTP 404", status: 404, cause: nil, metadata: %{status: 404, …}}`. The `dall-e-2` variations 404 from `a7b934b`. **Not a new defect; no new ticket.**

Both structs are **live evidence for the hardening**: `:cause` is `nil` (no transport struct, nothing to smuggle), `:metadata` carries no `:body_preview`, and `:message` is the provider's own text with no `inspect(cause)` interpolation — the shapes the redaction tests assert, observed on the wire rather than through a stub. Neither provider's real message carried key material, which is precisely why both fixtures plant one.

**`examples/RUN_OUTPUT_*.md` were NOT regenerated.** The OpenAI arm still does not complete cleanly, so per the snapshot-defer policy the files are untouched rather than hand-edited. `run_all.exs` was not run end-to-end for either provider — the scripts touching the modified adapters were run individually, which is the observation the blocked-arm rule asks for.

### Notes for later sub-phases

* **A new guide must now be registered in THREE places** — `mix.exs` `@guides`, `test/guides_test.exs` `@guides`, and a `doctest_file/1` line in `test/guides_doctest_test.exs` — or the suite goes red. That is the intended signal, not a test to relax; `@excluded` is the visible opt-out and is empty.
* **The `guides/fakes.md` finding generalises.** It is 8 KB of fences with one `iex>` block; the other five guides' fences carry the same zero protection. Whoever next touches a guide should convert every Fake-runnable fence in it rather than treating `fakes.md` as the only offender.
* **`v0.6.0` is still BUILT but NOT RELEASED.** `mix.exs @version` untouched; `mix run scripts/release.exs minor` remains the phase's outstanding action and was explicitly out of scope for this run.
* **The image fixture families have no provenance assertion** (22.7 code review F8, Low, deferred). `openai/embeddings_wire_test.exs`, `gemini/embeddings_wire_test.exs`, `voyage/embeddings_wire_test.exs` and `openai/moderation_wire_test.exs` each read raw bytes and assert `_comment` present on `synthesized/` and absent on `recorded/`; neither `test/allm/providers/openai/images_test.exs` nor `test/allm/providers/gemini/images_test.exs` does, and both families hold genuine `recorded/` fixtures. Whoever next touches either file should port the `raw_fixture/2` provenance block from `test/allm/providers/openai/moderation_wire_test.exs:80-95`. **DONE WHEN** `grep -L 'refute Map.has_key?(raw, "_comment")' test/allm/providers/openai/images_test.exs test/allm/providers/gemini/images_test.exs` is empty (today: both files).
* **The three unsanitized `:cause` assignments in `openai/images.ex`'s `fetch_url_bytes/2`** (`:934`, `:943`, `:952` at the time of measurement) are still raw at HEAD — re-verified 2026-09-03 with `grep -n 'cause: cause\|cause: exception\|sanitize_cause' lib/allm/providers/openai/images.ex`, which returns those three alongside the four sanitized sites (`:1021`, `:1035`, `:1118`, and the definition at `:1127`). Deliberately deferred by 22.7 as caller-URL-sourced rather than provider-sourced; carried in `.work/HANDOFF.md`. Not re-opened by the 22.7 polish pass, which is `test/`-and-docs scoped.

### `[DEFERRED-DRY]` entries — 22.7 (added by the fix pass; the entry shipped without one)

`agent-spec/IMPLEMENTATION.md:68` puts the extraction trigger at **two** implementations and
requires that, where the Module Tree forecloses consolidation, a one-line `[DEFERRED-DRY]`
entry name every trigger site and be filed in `ASKS.md` with a grep predicate. 22.1, 22.2,
22.3 and 22.5 each carry one; 22.7 shipped with none, which read as an oversight rather than
a judgement. Re-measured 2026-09-03:

* **`[DEFERRED-DRY]` — `sanitize_cause/1`, now SIX byte-identical copies.**
  `grep -l 'defp sanitize_cause' lib/allm/providers/*.ex lib/allm/providers/*/*.ex` →
  `gemini/embeddings.ex`, `gemini/images.ex`, `openai/embeddings.ex`, `openai/images.ex`,
  `openai/moderation.ex`, `voyage/embeddings.ex`. Both function clauses are literally
  provider-free:

  ```elixir
  defp sanitize_cause(%{__struct__: Jason.DecodeError} = cause), do: %{cause | data: ""}
  defp sanitize_cause(cause), do: cause
  ```

  `lib/allm/providers/support/` already hosts `transport.ex`, `openai_headers.ex`,
  `gemini_headers.ex` and `image_mime.ex`, so the destination is not in doubt — only the
  tree-scope. Deferred because five of the six files are outside 22.7's Module Tree.
* **`[DEFERRED-DRY]` — `provider_message/2`, two copies.**
  `grep -l 'defp provider_message' lib/allm/providers/*.ex lib/allm/providers/*/*.ex` →
  `gemini/embeddings.ex`, `gemini/images.ex`. Byte-identical; same destination.
* **NOT a trigger: `redact_key_material/1`'s regex.** The *body* is now identical across the
  three OpenAI modules modulo the fallback string, but CLAUDE.md is explicit that inheriting a
  sibling's pattern across providers is a silent no-op, and the new companion tests enforce
  per-provider divergence. Any shared extraction must take the pattern as an argument; it must
  not consolidate the patterns themselves.

Filed in `ASKS.md` (2026-09-03) with the self-scoring predicate
`grep -l 'defp sanitize_cause' lib/allm/providers/*.ex lib/allm/providers/*/*.ex` **must be
empty** (today: six files). Carried to `.work/HANDOFF.md`.

### Fix pass (2026-09-03) — what the three review lanes converged on

All three lanes independently reached the same diagnosis: 22.7 held its **code** to a
measure-don't-assume standard (mutation-tested gates, the single-funnel property established
by reading the call chain, the corruption-signal claim re-measured before editing) and did not
hold the **prose about that code** to the same standard. Six unverified claims resulted, most
of them in permanent documents. Corrections applied, each re-derived rather than taken from a
review's numbers:

1. **`CLAUDE.md:57`, "had shipped since Phase 16"** — false; `85f45d8` (Phase 21, 2026-05-25).
   Corrected in `CLAUDE.md`, this file (§"What registering `guides/fakes.md` surfaced" and the
   22.6 bullet), `ASKS.md`'s `[RESOLVED]` line, `test/guides_test.exs`'s parity comment, and
   `.work/HANDOFF.md`. The claim came from the commissioning ticket and was carried unverified
   — violating a rule *the same commit added*.
2. **`CLAUDE.md:57`, "no gate of any kind" on fence contents** — false, and written while
   striking a false claim. `scripts/audit_user_docs.exs` is line-based over the whole `.md` and
   **does** scan fence text. Measured: planting `# see spec §6.1 for details` inside a fence in
   a copy of `guides/fakes.md` gave `mix run scripts/audit_user_docs.exs <copy>` → **2 hits**,
   against **0** on the file itself. The true statement is narrower: the banned-token audit sees
   fence contents; nothing checks whether the code in a fence **compiles or names a live API**.
3. **"The conversion caught a shipped defect"** — unsupported. See the corrected paragraph
   above; the pre-22.7 fence never touched a `%ALLM.Response{}`.
4. **The redactors' provenance comments over-claimed.** Both read as an exhaustive audit of
   provider-authored bytes reaching the persisted struct. Measured 2026-09-03 through the
   `@doc false` seam: a key planted in `error["code"]` (OpenAI) or `error["status"]` (Gemini)
   lands on `:metadata` **unredacted** and survives both `inspect/1` and `Jason.encode!/1`. Both
   comments now carry an explicit `SCOPE —` paragraph naming the uncovered channels. The *code*
   gap is family-wide and pre-existing (`openai/embeddings.ex`, `openai/moderation.ex`,
   `gemini/embeddings.ex`), so widening the fix stays out of scope and is ticketed.
5. **`gemini/images.ex`'s `promptFeedback.blockReason`** — an unvalidated binary off a **200**
   body interpolated into `:message` and `metadata.block_reason`, structurally off the non-2xx
   funnel the comment claimed covered everything. **Fixed in-batch** (one call site):
   `decode_image_response/4` now redacts it before both assignments. Pinned by
   `test/allm/providers/gemini/images_test.exs`'s *"a blocked-prompt reason off a 200 body is
   redacted at its own site"*, verified binding by mutation (replacing
   `redact_key_material(reason)` with `reason` → 1 red; restored → 74 tests, 0 failures).
6. **The OpenAI redactor asserted OpenAI's real 401 echoes a key prefix, as fact.** No recorded
   401 exists anywhere in the tree — every auth fixture is under `synthesized/`. Under CLAUDE.md's
   four-part live-probe rule that is an *inferred* provider claim written as a confirmed one. The
   comment now marks it INFERRED and restates the planted-token fixture as binding the *pattern*,
   not the leak path.
7. **Two `:cause` counts** and **one self-scoring predicate** corrected in place above.

**Not fixed here, by scope fence** — carried to `.work/HANDOFF.md` and filed in `ASKS.md`:
the family-wide `:metadata` redaction gap; the six-copy `sanitize_cause/1` extraction; the three
unhardened chat adapters; `BadMapError` on a string-valued `"error"` envelope in both image
funnels; and `sanitize_cause/1` leaving `Jason.DecodeError.position` inconsistent so
`Exception.message/1` on the sanitized cause raises `ArgumentError`.

---

## Post-22.7 retro fix pass (2026-09-03) — the fence-compile gate

Commissioned by `.work/retro/2026-09-03-phase22-6-7.md` **CODE-ACTIONABLE item 1**,
which asked for the gate `CLAUDE.md:57` had claimed existed for months. It is
deliberately **not** the thing that was claimed: the claimed gate was a
hand-maintained denylist of dead API names, whose subject set is unbounded and
whose maintenance trigger is the same faculty that had already failed. A compiler
discovers its own subjects.

**What shipped.** `scripts/check_guide_fences.exs` (`Scripts.CheckGuideFences`),
plus a `describe "fenced blocks"` block in `test/guides_test.exs` so it is a red
suite rather than a script nobody runs. The guide set is read off
`Mix.Project.config()[:docs][:extras]`, not from a literal in the script — same
reasoning as that file's existing `@guides` parity block.

**Two design decisions worth the ink.**

1. **Nothing the fences contain is ever executed.** The obvious implementation —
   `Code.compile_string/1` on the fence body — *runs* top-level code. Measured on
   the first pass: it resolved live API keys for `:openai` and `:anthropic`,
   called `System.fetch_env!("OPENAI_API_KEY")`, and tried to read
   `/path/to/photo.png`. Every fence is therefore wrapped either in
   `defmodule X do def __fence__ do … end end` or in `defmodule X do … end`, so
   the body is compiled and never evaluated; whichever wrapping matches the
   fence's own shape is attempted first so the reported diagnostic is the
   compiler's real complaint. Modules a fence defines are `:code.purge/1`'d
   immediately, because the gate runs inside a VM that holds the real `ALLM.*`.
2. **Free variables are bound to `nil`; bound-then-misread ones are not.** A
   narrative guide's fences legitimately read `engine`, `request`, `session`,
   `chunks`, `tenant` from an earlier block. With the non-executing wrapping in
   place but no handling for those names, **54 of the 81 fences failed** — a 67%
   opt-out rate, which is a fig leaf, not a gate. (Before the wrapping, with
   fences compiled at top level, it was 63 — but those numbers are not
   comparable, since several of the 63 were live key lookups and file reads
   rather than compile failures.) The script
   instead walks the fence AST in *evaluation order* and binds only names that
   are READ before they are ever BOUND. This is exactly the discriminator the
   commissioning defect needs: `session = f(session)` reads before it binds
   (carried in — green), while `with {:ok, verdict} <- …` binds before anything
   reads `verdict`, so referencing it from `else` is a use of a name the fence
   owns and stays red. That took failures from 54 to 14.

**Measured, at HEAD:**

```
$ mix run scripts/check_guide_fences.exs | head -1
67 fences compiled, 14 skipped.
$ grep -c '^```elixir' $(grep -oE 'guides/[a-z_]+\.md' mix.exs | sort -u) | awk -F: '{t+=$2} END {print t}'
81
```

**The 14 skips are the honest residue**, each carrying a mandatory reason in an
`<!-- fence-check: skip — … -->` comment on the line above its opening
delimiter (invisible in rendered hexdocs, adjacent to the fence so it cannot
drift the way a line-numbered central literal would, and printed in full on every
run). They fall into six kinds: bare `adapter_opts:` keyword fragments that are
not expressions (`fakes.md` ×3), ExUnit test bodies needing a `use ExUnit.Case`
module (`fakes.md` ×2, `moderation.md` ×1), literal `...` elisions
(`tools.md`, `errors_and_retries.md`, `fakes.md`), functions the reader supplies
(`tools.md`, `errors_and_retries.md`), a `config/runtime.exs` snippet
(`multi_tenant_keys.md`), and Ecto/Pgvector/`MyApp.Document` which are not
dependencies (`embeddings.md` ×2).

**Proof it binds, run against the file that shipped the defect** rather than
against a reconstruction — `guides/moderation.md` temporarily replaced with
`git show 4efb37c:guides/moderation.md` (tag `wip/22-6-checkpoint`) and restored:

```
$ mix run scripts/check_guide_fences.exs
2 ```elixir fence(s) do not compile:
  guides/moderation.md:425 — undefined variable "verdict"
  guides/moderation.md:525 — undefined function assert_receive/1 …
EXIT=1
```

`:425` is the flagship *Screening before you generate* recipe, the run's one hard
defect, which four agents each rediscovered by reading. It is now a suite
failure. (`:525` is the `capture_pid` test snippet, correctly a skip today.)

**What it does NOT catch, stated because over-claiming a control's coverage is
the defect this whole sub-phase exists to punish.** Runtime behaviour of any
kind. `%ALLM.Response{}` has no `:content` field, and `response.content`
compiles clean on Elixir 1.17.3 — so the *second* defect this run hit
(`guides/fakes.md`'s `## Construction` block) would **not** have been caught by
this gate; it was caught by conversion to an `iex>` doctest. Calls to
non-existent modules are warnings, not errors, and are deliberately not
escalated, because that is what keeps illustrative `MyApp.*` fences legal without
a skip. Both boundaries are pinned by negative-control tests
(`test/guides_test.exs`, `describe "fenced blocks"`) rather than asserted in
prose, and the adjacent struct-*literal* case — which IS caught — is pinned too,
so the boundary is drawn where it actually falls.

**`CLAUDE.md:57` amended in the same pass** to describe the gate, its two
documented limits, the skip mechanism, and the reason the denylist was the wrong
shape. That bullet's count carries the command that produced it.

### Retro CODE-ACTIONABLE item 2 — no action needed

The retro states that `RECORDS.md:1796`'s predicate *"still matches its own line
at HEAD"*. Re-measured before acting on it, and it does not — the fix pass had
already scoped it, and the retro's line number is stale (the text is at `:1807`):

```
$ git --no-optional-locks show 6842fe4:steering/2026-08-31_PHASE_22_moderation_RECORDS.md | grep -c 'grep -rn "come back empty alongside it" lib/ guides/ steering/allm_engine_session_streaming_spec_v0_2.md'
1
$ grep -rn "come back empty alongside it" lib/ guides/ steering/allm_engine_session_streaming_spec_v0_2.md; echo "exit=$?"
exit=1
```

The unscoped form still matches this file, as it must — the record is not a site.

