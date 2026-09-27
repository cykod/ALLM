# Phase 24 Typed Classification — Records

Companion to `steering/2026-09-22_JEV_SUPPORT.md`. Bookkeeping lives here; the design doc's status table and checkboxes are not ticked.

## Status

| Phase | Status | Notes |
|-------|--------|-------|
| 24.1 | Completed | Layer A classification data: four structs, `ClassificationAdapterError`, `Validate.classification_request/1`, enum + registry edits |
| 24.2 | Completed | `ALLM.ClassificationAdapter`, 12 Engine sites, `FakeClassification`, conformance harness (`@case_count 9`) + stub + self-test |
| 24.3 | Completed | `ALLM.classify/3`, `ALLM.classification_request/2`, classification internals block, `:classify` span, `@public_facade` +2 |
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

## 24.2 — Behaviour, engine field, Fake, conformance

### Start Green (2026-09-27, HEAD `7de1c1c`)

- `mix test` (seed 385155) → exit 0: `649 doctests, 33 properties, 5309 tests, 0 failures, 14 excluded, 1 skipped`.
- `README.md` clean; no stash needed. Tree clean at start.

### Checklist

- [x] `lib/allm/classification_adapter.ex`: `classify/2` + optional `prepare_request/2`, numbered invariants 1–9, compilable skeleton, "Cleanup invariant: none."
- [x] `lib/allm/engine.ex`: all 12 Engine-extension sites (1 moduledoc Fake list, 2 module-field bullet, 3 slot-model bullet — the `:model` bullet beside it now says "audio and classification slots", 4 `@type t`, 5 `defstruct`, 6 `@engine_field_keys` (both), 7 `@module_fields` (`:classification_adapter` only), 8 `new/1` module list, 9 `new/1` cursor Fake list, 10 `put_cursor_key/2` comment, 11 `resolve_params/2` prose (both), 12 `__from_tagged__/1` (both)). `grep -c classification lib/allm/engine.ex` → 16.
- [x] `lib/allm/providers/fake_classification.ex` + `test/support/fake_classification_fixtures.ex`
- [x] `conformance/lib/allm/test/classification_adapter_conformance.ex` (`@case_count 9`, `## Script contract`, `## What this suite does NOT bind`), `conformance/test/support/fixtures/scripted_classification_stub.ex`, `conformance/test/allm/test/classification_adapter_conformance_test.exs` (three meta-invariants)
- [x] `mix.exs` groups: `ALLM.ClassificationAdapter` → Behaviours (after `ALLM.ModerationAdapter`), `ALLM.Providers.FakeClassification` → Providers (after `FakeTranscription`); `test/groups_for_modules_audit_test.exs` green

### Tests

New: `test/allm/classification_adapter_test.exs` (9 injected conformance cases + 4 surface tests), `test/allm/providers/fake_classification_test.exs` (39 tests + 6 doctests), `conformance/test/allm/test/classification_adapter_conformance_test.exs` (9 injected + 3 meta). Modified: `test/allm/engine_test.exs` — `classification_adapter: FakeClassification` joins the adapter-slot loop (accept/nil default/`{Mod, []}` raise/JSON/ETF/deny-list), `:classification_model` joins the slot-model loop (accept/independent of `:model`/JSON/deny-list), plus one chat-model + classification-slot JSON round-trip test.
Coverage (`mix test --cover` on the three main-repo files): `FakeClassification` 98.98%, `ClassificationAdapter` 100%.
Mutants (each run then reverted; `git diff` clean afterwards): retry budget keyed on `:erlang.phash2(script)` → red on "two content-equal-script engines with distinct :id values do not share a retry budget"; spent script answering defaults → 4 failures; stub `:yes_no` answer carrying `confidence: 0.5` → red on conformance case 5.

### Gates [G]

- `mix test` → exit 0, `655 doctests, 33 properties, 5371 tests, 0 failures, 14 excluded, 1 skipped` (seed 629186; +6 doctests, +62 tests vs Start Green). Zero `warning` lines in the log.
- `mix test --seed 0` → exit 0, same counts.
- `mix format --check-formatted` → 0; `mix credo --strict` → 0 (one `Readability.StringSigils` hit in the fixtures file fixed with `~s()`); `mix dialyzer` → `Total errors: 0`; `mix compile --force --warnings-as-errors` → clean.
- Docs audit `comm -13` → only `Files scanned:    139` (was 137; two new `lib/` modules). No new hit line; `Total hits: 5` unchanged. The engine.ex rewraps at sites 1 and 9 kept the two pre-existing `§31` lines byte-identical.
- Process-global grep: the same nine files as 24.1, all `async: false`; no new file. No `:telemetry.attach` in any new test module.
- `conformance/`: `mix test` → exit 0 (`206 tests, 0 failures, 1 skipped`); `mix credo --strict` → 0 (a `Refactor.LongQuoteBlocks` hit on the first draft was fixed by moving the three per-type field assertions out of the `quote` as `@doc false` harness defs that use field access only); `mix format --check-formatted` → 0.

### Deviations / notes

- `[tactical]` FakeClassification carries `script/1`, `start_script_cursor/0` and `cursor_index/1`, like FakeModeration. The contract block does not list them; `:script_cursor` precedence needs the latter two, and the conformance moduledoc points at `script/1` for the grammar.
- `[tactical]` The Test Plan's "compiles without warnings (`capture_io(:stderr, …)`)" test uses `Code.with_diagnostics/1`, as `test/allm/moderation_adapter_test.exs` does: a stderr capture in an `async: true` module also sees other files' warnings.
- `[tactical]` An unvalidated script entry reaching `classify/2` (e.g. `{:ok, []}`) raises `ArgumentError` naming the grammar rather than a `FunctionClauseError` from `interpret_entry/3` (FakeModeration raises the latter). Pinned by "classify/2 raises ArgumentError on an unrecognized entry it reaches".
- `[tactical]` Negative scripted scores raise alongside `>= n` ones (the table says "must be in `0..n−1`"); pinned by "a negative score raises".
- `[tactical]` `ScriptedClassificationStub` defaults deliberately differ from the Fake's (last option with probability split evenly, top score level, yes probability `1.0`, `usage.input_tokens: 1`), so a harness case cannot pass by hard-coding the reference's numbers.
- Invariant 1's moduledoc text says enforcement lives "where the adapter is dispatched" rather than naming `ALLM.classify/3`, which does not exist until 24.3 (a named reference would be an ExDoc dead link). 24.3 may sharpen it to name `classify/3` once it lands.
- `[CARRY]` pre-existing, out of tree: `conformance/test/allm/test/speech_adapter_conformance_test.exs:84` emits `warning: unused alias SpeechAdapterConformance` on every `cd conformance && mix test` (last touched by `abc725b`, 25.2). `mix test` still exits 0 and no gate in the [G] block fails on it; it wants a separate `[CHORE]` commit.

### Fix pass (2026-09-27)

Inputs: `.work/reviews/2026-09-27-phase-24-2/overview.md`, `.work/code-reviews/2026-09-27-phase-24-2.md`, `.work/security-reviews/2026-09-27-phase-24-2.md` (clean), design review N/A.

- `[fixed]` The `[tactical]` deviation above claimed an unvalidated entry reaching `classify/2` raises `ArgumentError` naming the grammar, but a malformed `{:retry_until_call, n}` did not: `:x` rate-limited forever, `2.5` behaved as 3, `0`/`-1` skipped silently (functional review KI #1, Low; fixed under the claim-vs-behaviour carve-out because the false sentence is this register's). Both `run_scripted/2` and the chained arm of `handle_retry_until_call/6` now guard `when is_integer(n) and n >= 1`, so other shapes reach `interpret_entry/3`'s raise. Pinned by `fake_classification_test.exs` "classify/2 raises ArgumentError on a malformed {:retry_until_call, n} it reaches" (4 values x leading/chained); each guard removed alone turns it red (mutated and reverted). The sibling Fakes are unchanged (released code): `grep -nE '\{:retry_until_call, [nm]\} ->' lib/allm/providers/fake_*.ex | wc -l` -> 9 (2026-09-27), carried in `.work/HANDOFF.md`.
- `[fixed]` Code review F1: the retry test's "leading entry is load-bearing: forces `advance` to WRITE the slot `peek` READS" comment was false for this Fake (`peek_cursor/2` defaults an unwritten slot to `0`; the unled "layered budget" test passes). Reworded to say what the leading entry does here (starts the retry at a nonzero cursor).

## 24.3 — Façade and telemetry

### Start Green (2026-09-27, HEAD `dbc0d3b`)

- `mix test` (seed 702267) → exit 0: `655 doctests, 33 properties, 5372 tests, 0 failures, 14 excluded, 1 skipped`. Tree clean; `README.md` clean, no stash needed.
- `mix test test/allm_facade_doctest_inventory_test.exs` before editing `@public_facade`: **28 tests**.

### Checklist

- [x] `lib/allm.ex`: `@classification_request_field_opts [:questions, :model, :options, :metadata]`, `classification_request/2`, `classify/3` (head + two clauses) after `stream_transcribe/3`; internals block (`@retryable_classification_reasons`, `stringify_question_ids/1`, `drop_classification_request_opts/1`, `do_classify/3`, `question_count/1`, `do_classify_body/4`, `dispatch_classify_attempt/3`, `classify_stop_extras/1`) after the audio internals (after `transcribe_stop_extras/1`). Reuses `augment_retry_policy/2`, `build_capability_dispatch_opts/3`, `fill_request_id/2` unchanged.
- [x] `lib/allm/telemetry.ex`: `:classify` in `@type span_name` and `@valid_span_names`, moduledoc entry-point list, event-table row, stable-key paragraph
- [x] `lib/allm.ex` moduledoc capability table: row after `moderate/3`
- [x] `@doc classify/3` sections: One call many questions, Model resolution, Gate order, Validation, Retry, Telemetry, Raises (`:missing_key` + invariant-1 `ArgumentError`), `request_id` precedence, `:stream`
- [x] `@public_facade` +2 (`classification_request: 2` after `transcription_request: 2`; `classify: 3` in a new `# Classification` group after `# Audio`) — inventory test **28 → 30 (+2)**
- [x] HANDOFF (from 24.2): `ALLM.ClassificationAdapter` invariant 1 now names `ALLM.classify/3` as the enforcer; `dispatch_classify_attempt/3` raises `ArgumentError` with the `dispatch_moderate_attempt/3` wording shape

### Tests

New: `test/allm/allm_classify_test.exs` (`async: true`, `TelemetryCapture` only; 34 tests + 3 doctests via `doctest ALLM, only: [classify: 3, classification_request: 2]`). Covers every 24.3.1 bullet. Modified: `test/allm_facade_doctest_inventory_test.exs`.
Mutants (each run then restored from a scratch copy; `cmp` clean afterwards): model stamping falls back to `engine.model` → red on "engine.model (the chat model) never reaches the classification adapter"; dispatch opts built without `build_capability_dispatch_opts/3` → red on the cursor test (and the `:stream` test); `question_count/1` without the non-map clause → red on "question_count is 0 for a non-map :questions"; `stringify_question_ids/1` removed → 4 red.

### Gates [G]

- `mix test` → exit 0, `661 doctests, 33 properties, 5408 tests, 0 failures, 14 excluded, 1 skipped` (seed 765075; +6 doctests, +36 tests vs Start Green). Zero `warning` lines in the log.
- `mix test --seed 0` → exit 0, same counts.
- `mix format --check-formatted` → 0 (after one `mix format` on the new block); `mix credo --strict` → 0; `mix dialyzer` → `Total errors: 0`; `mix compile --force --warnings-as-errors` → 0.
- Docs audit `comm -13` → only `Files scanned:    139` (unchanged since 24.2; no new `lib/` file). No new hit line; `Total hits: 5`. Per-file `mix run scripts/audit_user_docs.exs lib/allm.ex lib/allm/telemetry.ex lib/allm/classification_adapter.ex` → 0 hits.
- Process-global grep: the same nine files, all `async: false`; the new test file is not among them and attaches telemetry only through `TelemetryCapture`.
- `conformance/`: not touched, not run.

### Deviations / notes

- `[tactical]` `answer_count` is `map_size(response.answers)` with no non-map guard, matching `moderate_stop_extras/1`'s unguarded `length(results)`. FakeClassification's script grammar has no verbatim `{:ok, response}` entry, so no scripted response can carry a non-map `:answers`; a non-conforming third-party adapter doing so raises inside the span (`:exception` event), as on the moderation span.
- `[tactical]` `classification_request/2` stringifies only atom ids of a non-struct map `:questions`; a non-map `:questions` (or a struct) is passed through for the validator's `{:questions, :invalid_shape}` hard-reject.
- `[tactical]` The symmetry test pins both the expected field set (`[:metadata, :model, :options, :questions]`, from `Map.keys/1`) and per-field reachability via a sentinel, as the audio siblings do; the allow-list attribute stays private (no `@doc false` accessor), so an allow-listed non-field is not bound — same accepted gap as `speech_request/2`.
- `[CARRY]` Low, out of 24.3's tree: `conformance/lib/allm/test/classification_adapter_conformance.ex` `## What this suite does NOT bind` still says invariant 1 "is checked where the adapter is dispatched". True, but it can now name `ALLM.classify/3`. Carried in `.work/HANDOFF.md` for 24.5/24.6.
- `[DEFERRED-DRY]` (fix pass, code review F1) Design-sanctioned copy: `lib/allm.ex` `dispatch_{moderate,synthesize,transcribe,classify}_attempt/3` are four semantic clones, and `@retryable_{image,embedding,moderation,speech,transcription,classification}_reasons` six identical lists. Extraction touches released façades → stand-alone `[REFACTOR]`; filed in `.work/ASKS.md` (sun 9/27 11pm). `grep -cE '^  @retryable_[a-z]+_reasons \[' lib/allm.ex` → 6; `grep -cE '^  defp dispatch_(moderate|synthesize|transcribe|classify)_attempt\(' lib/allm.ex` → 4.
- Fix pass (2026-09-27): code review F2 — the three shared-helper comments in `lib/allm.ex` (`augment_retry_policy/2`, `build_capability_dispatch_opts/3`, `fill_request_id/2`) now list `classify`; the same class in `lib/allm/telemetry.ex`'s `span/3` `@doc` (valid-names list and the 3-tuple-form span list omitted `:classify` / `:answer_count`) fixed alongside. Code review F3 (Low, `question_count/1` struct guard) left for the polish pass. Functional review Known Issue 1 (`:options`/`:metadata` unvalidated, Low) routed to `.work/HANDOFF.md` for 24.4.

