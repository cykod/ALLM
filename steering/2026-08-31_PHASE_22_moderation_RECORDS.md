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
