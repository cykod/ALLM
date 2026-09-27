# Phase 24 Typed Classification — Records

Companion to `steering/2026-09-22_JEV_SUPPORT.md`. Bookkeeping lives here; the design doc's status table and checkboxes are not ticked.

## Status

| Phase | Status | Notes |
|-------|--------|-------|
| 24.1 | Completed | Layer A classification data: four structs, `ClassificationAdapterError`, `Validate.classification_request/1`, enum + registry edits |
| 24.2 | Not Started | |
| 24.3 | Not Started | |
| 24.4 | Not Started | |
| 24.5 | Not Started | |
| 24.6 | Not Started | |

## 24.1 — Layer A classification data

### Start Green (2026-09-27, HEAD `9510ed9`)

- `mix test` (seed 564554) → exit 2: `626 doctests, 33 properties, 5188 tests, 1 failure`. The one failure was `test/allm/providers/anthropic_vision_test.exs:313` ("emits exactly one debug log per process across two calls", saw 2) — the pre-existing `Logger`/`async: true` log-capture race CLAUDE.md documents for that file. Not in 24.1's tree; did not reproduce on either post-change run below.
- `README.md` clean; no stash needed. The one pre-existing modification (`steering/2026-09-22_JEV_SUPPORT.md`, the cite refresh) left as found apart from the CORRECTED note below.
- Docs-audit baseline captured before the first edit: `.work/phase24_audit_baseline.txt` (5 hits / 3 files: `engine.ex` 3, `fake.ex` 1, `fake_images.ex` 1; 132 files scanned).

### Checklist

- [x] Five modules per the contract blocks: `lib/allm/classification_{question,request,answer,response}.ex`, `lib/allm/error/classification_adapter_error.ex` (incl. `decode_questions/1`, guarded builder heads, `hydrate_usage/1`)
- [x] `EngineError` (+`:no_classification_adapter`) and `ValidationError` (+`:invalid_classification_request`): both declarations each
- [x] `Validate.classification_request/1` + `# Internal: classification_request rules` block
- [x] `Serializer.@known_modules` +5
- [x] `@layer_a` +4 — `mix test test/layer_a_docs_test.exs`: 33 tests before the edit, 37 after (+4, one generated test per entry)
- [x] `mix.exs` `groups_for_modules`: four structs → "Data types", the error → Errors; `test/groups_for_modules_audit_test.exs` green

### Tests

New: `test/allm/classification_question_test.exs`, `classification_request_test.exs`, `classification_answer_test.exs`, `classification_response_test.exs`, `error/classification_adapter_error_test.exs`, `validate_classification_request_test.exs` (one test per vocabulary-table row — 16 rows, several parameterised). Modified: `error/engine_error_test.exs`, `error/validation_error_test.exs` (one enum pin each; off-enum controls already present).
Focused run (six new files): `21 doctests, 113 tests, 0 failures`. Coverage (`mix test --cover` on the focused files): 100% on all five new modules and their `Jason.Encoder` impls; the new validator block has no missed lines.

### Gates [G]

- `mix test` → exit 0, `649 doctests, 33 properties, 5307 tests, 0 failures, 14 excluded, 1 skipped` (final run after the last test additions; +23 doctests, +119 tests vs Start Green).
- `mix test --seed 0` → exit 0, same counts.
- `mix format --check-formatted` → 0; `mix credo --strict` → 0 (one `Readability.StringSigils` hit in the new validator test fixed with `~s()`); `mix dialyzer` → 0, `Total errors: 0`.
- Docs audit `comm -13` → only `Files scanned:    137` (was 132, from the five new files); **no new hit line**; total hits still 5. See the CORRECTED note under [G] in the design.
- Process-global grep: nine files, all pre-existing and all `async: false`; no new test file in the list. No `:telemetry.attach` in any new module.

### Deviations / notes

- `[tactical]` `json_encodable?/1` is a private helper in `ALLM.Validate`, not a shared seam. The 24.4 adapter needs the encoded body, not a boolean, so it will write its own `try Jason.encode … rescue Protocol.UndefinedError` rather than call this one (the design asks for a shared *shape*, Decision #17).
- `[tactical]` The `:questions` hard-reject clause also rejects a struct (`is_struct/1`), since a struct is a map but would crash the per-question `Enum.reduce/3`. It still yields exactly `[{:questions, :invalid_shape}]`.
- `[tactical]` `:yes_no` criteria `%{}` is accepted (keys ⊆ `["true","false"]` holds vacuously); pinned by a happy-path test.
- `[tactical]` Choice `:invalid_option` errors run only when the criteria is a non-empty map; `:not_json_encodable` for criteria runs only when no other criteria rule fired, the same one-row-at-most discipline the table states for `:state`.
- `[tactical]` Binary state/instructions also go through the encodability check, so invalid UTF-8 reports `:not_json_encodable` (the table's "shape is fine but encoding fails" row).
- Design claim corrected in place (`> CORRECTED 2026-09-27`): the [G] block's `comm -13 … # must be empty` cannot be empty once a sub-phase adds files, because the `Files scanned:` summary line changes.

### Fix pass (2026-09-27)

Inputs: `.work/reviews/2026-09-27-phase-24-1/overview.md`, `.work/code-reviews/2026-09-27-phase-24-1.md`, `.work/security-reviews/2026-09-27-phase-24-1.md` (design review N/A).

- `[fixed]` `json_encodable?/1` rescued only `Protocol.UndefinedError`, so an improper list in `:state`, `:instructions` or score `:criteria` raised `FunctionClauseError` out of `classification_request/1`, whose `@doc` says encodability "never raises" (security review, informational; reproduced before fixing). Now `rescue _ -> false`. Pinned by `validate_classification_request_test.exs` "an improper list yields :not_json_encodable rather than raising" (red when the rescue is narrowed back). Decision #17's shared shape corrected in place (`> CORRECTED`), so the 24.4 adapter gets the same rescue.
- `[fixed]` `:instructions` accepted a struct (a `%ALLM.Message{}` validated `:ok`) and reported a keyword list as `:not_json_encodable`; it now uses the `:state` shape predicate (renamed `structured_value_shape?/1`), so both are `:invalid_shape` (code review F2). Pinned by "struct or keyword-list instructions yield :invalid_shape, as for :state" (red under the old predicate). The table row is corrected in place (`> CORRECTED`) below the vocabulary table.
- `[fixed]` `ClassificationQuestion.choice/2` `@doc` said any non-list/non-map raises `FunctionClauseError` without saying a keyword list raises `Protocol.UndefinedError` (functional review KI #1). The `@doc` now says so and points to the map form. Behaviour unchanged.
- `[owned elsewhere]` `hydrate_usage/1` sixth private copy (code review F1): planned by the design; the receiver is the `[DEFERRED-DRY]` `[DISPOSITION]` ticket in `.work/ASKS.md` (thu 9/24 3am, "hydrate_usage/1 has five private copies"), whose count 24.6 updates. `grep -l 'defp hydrate_usage' lib/allm/*.ex | wc -l` → 6 on 2026-09-27.
- `[deferred to polish]` `choice/2` silently merging colliding atom/string names (functional review KI #2, Low).
