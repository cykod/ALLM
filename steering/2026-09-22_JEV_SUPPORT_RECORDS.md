# Phase 24 Typed Classification — Records

Companion to `steering/2026-09-22_JEV_SUPPORT.md`. Bookkeeping lives here; the design doc's status table and checkboxes are not ticked.

## Status

| Phase | Status | Notes |
|-------|--------|-------|
| 24.1 | Completed | Layer A classification data: four structs, `ClassificationAdapterError`, `Validate.classification_request/1`, enum + registry edits |
| 24.2 | Completed | `ALLM.ClassificationAdapter`, 12 Engine sites, `FakeClassification`, conformance harness (`@case_count 9`) + stub + self-test |
| 24.3 | Completed | `ALLM.classify/3`, `ALLM.classification_request/2`, classification internals block, `:classify` span, `@public_facade` +2 |
| 24.4 | Completed | `ALLM.Providers.TypeSafe.Classification`, recorder + 14-arm live probe, 14 recorded + 5 synthesized fixtures, `Support.Redact.typesafe/1` |
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


## 24.4 — `ALLM.Providers.TypeSafe.Classification`

### Start Green (2026-09-27, HEAD `ab465a0`)

- `mix test` → exit 0: `661 doctests, 33 properties, 5408 tests, 0 failures, 14 excluded, 1 skipped`. Tree clean; `README.md` clean, no stash needed.

### Checklist

- [x] Adapter `lib/allm/providers/typesafe/classification.ex`: `classify/2` (script short-circuit → `prepare_request/2` → one `Req.request/1` → decode/error), `prepare_request/2` (empty questions → `gate_limits/2` → `gate_state/1` → `encode_body/2` → `Keys.fetch!(:typesafe, opts)` → `Req.new(retry: false)` + test stub + receive timeout), seams `to_json_body/2`, `gate_limits/2`, `gate_state/1`, `decode_response/4`, `to_classification_adapter_error/5`, `classify_classification_reason/3`, `redact_key_material/2`; moduledoc wire-field map, `noul` alias note, injected-default section, limits, error table, hygiene, retry, escape hatch. `jev-latest` default documented in `@doc classify/2` and `to_json_body/2`'s `@doc false` comment.
- [x] Recorder + probe `scripts/record_typesafe_classification_fixtures.exs` (loads `.env` itself; `load_dotenv/1`, `overwritable?/1`, `synthesized?/2` copied verbatim from `scripts/record_prompt_cache_fixtures.exs`, the extraction source). `test/support/typesafe_fixtures.ex` delegates to `OpenAITestFixtures.drop_comment/1`.
- [x] Synthesized fixtures (5), each `_comment: "Synthesized — Phase 24.4 …"`.
- [x] `x-typesafe-request-id` **observed** on every arm (success and error) → `ClassificationResponse.id` is populated; the "always nil" moduledoc branch did not apply.
- [x] `extract_error_message/1` narrowed to the three observed `detail` shapes; wire-map inferred rows corrected in the design (dated `> CORRECTED 2026-09-28` notes).
- [x] `:context_length_exceeded` **kept** (arm 9 has a signal); no prune.
- [x] `mix.exs` groups: adapter → Providers (after `ElevenLabs.Transcription`); `test/groups_for_modules_audit_test.exs` green.

### Probe transcript (recorder, first run, 2026-09-27; key never printed)

Invocation: `env -u TYPESAFE_API_KEY mix run scripts/record_typesafe_classification_fixtures.exs` (the script loaded `.env` itself: `[info] Loading .env file …`) → exit 0.

```
  ok   got 200      want 200      1 mixed_questions
  ok   got 200      want 200      2 structured_state
  ok   got 400      want 400      3 error_400_bad_type
  ok   got 400      want 400      4 error_400_too_many_options
  ok   got 200      want 200      4b choice_255_options
  ok   got 400      want 400      5 error_400_too_many_levels
  ok   got 200      want 200      5b score_10_levels
  ok   got 400      want 400      7 error_bad_model
  ok   got 401      want 401      8 error_401_live
  ok   got 400      want 400      9 error_context_length
  ok   got 200      want 200      11 negative_control
  ok   got 200      want 200      12 probe_state_list_any
  ok   got 422      want 422      13 error_422_empty_questions
  ok   got 200@all  want 200|4xx  10 probe_question_ladder [1, 32, 128, 512]
-- header note --  (every arm) x-typesafe-request-id=yes retry-after=no retry-after-ms=no
Billed input tokens this run (from usage): 15287
```

Second run (the zero-call proof): `Nothing to record: … No HTTP requests were made — including the wire probe.` exit 0.

Findings, per arm (the expectations above are the OBSERVED ones; the design's arm table is corrected in place):
- Arm 1: `x-typesafe-request-id` present (`req_…`). No `Retry-After` / `retry-after-ms` on any arm (no 429 provoked).
- Arm 2: object score levels are echoed back as object `legend` entries.
- Arms 3, 7: `400 {"detail": {"error_type": "api_usage_error", "message": …}}` (design guessed 422 / "400/404/422").
- Arms 4, 5: `400 {"detail": "Too many choices. Must have at most 255 choices."}` / `"… at most 10 levels."` — a bare-string `detail`. 4b/5b (255 / 10) are 200, binding `@max_choice_options` / `@max_score_levels` from the accepting side.
- Arm 8: `401 {"detail": {"error_type": "authentication_error", "message": "Cannot authenticate with the server. …"}}`; the body does not echo the sent key (asserted).
- Arm 9: `400 {"detail": {"error_type": "max_tokens_exceeded"}}` — no message. `:context_length_exceeded` kept, keyed on that `error_type`.
- Arm 10: no question cap up to 512.
- Arm 11 (negative control): **200** — TypeSafe ignores unknown question fields (an exploratory call showed the same for a top-level field). Acceptance is not evidence of schema membership on this endpoint; the only request-side facts settled are those with a distinguishing RESPONSE (arms 3–5, 7, 9, 13).
- Arm 12 (added): list state `["a", 1]` → 200; the API is `list[any]` (the 422 for `state: 42` names `str | dict | list[any]`). `gate_state/1` kept as the documented contract.
- Arm 13 (added): `questions: {}` → 422 FastAPI list `[{"loc": ["body","questions"], "msg": …, "type": "too_short", "input": {}, "ctx": …}]`.
- Key format: the maintainer's key is `apikey_` + 101 chars of `[A-Za-z0-9_-]` (length 108; prefix recorded, key not printed) → `Support.Redact.typesafe/1` added (design Decision #16 condition met; corrected in place).

Exploration before the recorder was written (four ad-hoc `mix run` scripts in the scratchpad, same endpoint, same key) established the envelope shapes above; plus one post-build end-to-end smoke through `ALLM.classify/3` (200 with typed answers, `id` populated) and one bogus-key 401 through it (error `Jason.encode!`-able, `cause: nil`).

**Cost actuals:** recorder 15,287 billed input tokens (summed from the recorded `usage` objects); exploration + smoke ≈ 1,630 (382 + 272 + 273 + 349 + the 401s/400s, which report no usage). ≈ 16.9k tokens × $0.042/Mtok ≈ **$0.0007**. Unknown: whether the two rejected ~39k-token context-length requests (exploration + arm 9) are billed; if they are, +78k tokens → upper bound ≈ **$0.004**. Within the design's < $0.02 first-implementation budget.

### Tests

New: `test/allm/providers/typesafe/classification_test.exs` (`async: false`, deletes `TYPESAFE_API_KEY` in `setup`, restores `on_exit`; 3 doctests via `doctest Classification`), `classification_wire_test.exs` (`async: true`, `Req.Test`), `classification_conformance_test.exs` (9/9). `mix test test/allm/providers/typesafe/` → `3 doctests, 78 tests, 0 failures`. Coverage (`mix test --cover` on that directory): `TypeSafe.Classification` 94.05%, `Support.Redact` 100%.
Mutants (each run then restored from a scratch copy; `cmp` clean afterwards): `Keys.fetch!` moved ahead of the gates → 7 failures; literal-key pass removed → 2; `* 1.0` coercion removed → 1; `@max_choice_options 256` → 2; `retry: false` dropped → 1 (the `prepare_request/2` options assertion; Req's default `:safe_transient` does not retry a POST, so the 503 one-attempt test binds against an inner loop only); context-length clause disabled → 2.

### Gates [G]

- `mix test` → exit 0, `664 doctests, 33 properties, 5486 tests, 0 failures, 14 excluded, 1 skipped` (+3 doctests, +78 tests vs Start Green). Zero `warning` lines in the log.
- `mix test --seed 0` → exit 0, same counts.
- `mix format --check-formatted` → 0; `mix credo --strict` → 0 (one nesting-depth hit in `fetch_float_map/2` fixed by extracting `float_map/2`); `mix dialyzer` → `Total errors: 0`; `mix compile --force --warnings-as-errors` → 0.
- Docs audit `comm -13` → only `Files scanned:    140` (was 139; the new adapter). No new hit line; `Total hits: 5`. Per-file audit of `classification.ex` + `redact.ex` → 0 hits.
- Process-global grep: the nine prior files plus `test/allm/providers/typesafe/classification_test.exs`, all `async: false`. No `:telemetry.attach` in any new module.
- `grep -rnE '(=>|:) *"noul"|"noul" *=>|:noul\b' lib/ | grep -v providers/typesafe` → empty, exit 1 (positive control `| grep -c providers/typesafe` → 3). The design's literal `grep -rn '"noul"' lib/ | grep -v providers/typesafe` prints the 24.1 alias note in `classification_question.ex:21`, which Decision #2 put there; corrected in place.
- `conformance/`: not touched, not run.

### Deviations / notes

- `[structural, documented]` Recorded fixtures are envelopes `{"status","headers","header_names","body"}` (the ElevenLabs recorder shape) rather than bare bodies, so the tests read the status and the request-id header from the recording; the ladder writes its own summary. Two arms added (12, 13) and three renamed from `error_422_*` to `error_400_*` after the observed statuses. Design arm table corrected in place.
- `[structural, documented]` Every error has `cause: nil`: transport errors put the reason atom in `metadata.transport_reason`, and a 200 JSON-decode failure carries no cause. The design listed `sanitize_cause/1` among the reused helpers; the `ClassificationAdapterError` moduledoc (24.1) says an adapter "must never store a raw exception in `:cause`", and a sanitized `%Req.TransportError{}` still breaks `Jason.encode!/1`. `[CARRY]` safer than the siblings (`lib/allm/providers/support/transcription_adapter.ex` `run_one_attempt/5` / `transport_error/5`, `lib/allm/providers/voyage/embeddings.ex` `run_one_attempt/3`): filed in `.work/ASKS.md` (mon 9/28 12am) with predicate `grep -rn 'cause: HTTPResponse.sanitize_cause' lib/allm/providers/ | wc -l` → 21 (2026-09-28); noted on the 22.7 HANDOFF row.
- `[tactical]` Error `:metadata` = `status`, `typesafe_error_type` (`detail.error_type`), `typesafe_request_id` (header), `request_id` when given. Both provider-authored values pass `redact_optional/2` with the two-pass redactor; pinned by the planted token in `synthesized/error_401.json`'s `error_type` (redaction test "the literal resolved key and the apikey_ token are both removed").
- `[tactical]` `redact_key_material/2`'s key: `classify/2` reads it back off the prepared request's `authorization` header (`request_key/1`) rather than resolving it twice.
- `[tactical]` `encode_body/2` encodes once and sends the iodata as `body:` (with an explicit `content-type`), not `json:`, so the encodability check and the wire body are the same encode.
- `[tactical]` `gate_empty_questions` also rejects a non-map `:questions` (a direct call), rather than raising.
- `[tactical]` `decode_response/4` additionally checks `noul` ∈ [0, 1] and `score` ∈ [0, n−1] (field-population table bounds), and `probabilities`/`legend` share the level count.
- `[tactical]` `extract_error_message/1` is adapter-private (third `detail` extractor): neither released sibling (`Voyage.Embeddings`, `Support.ElevenLabs`) covers all three observed shapes, and both are private; the 422 list's `input` echo is never read. Justified in the naming-parity block.
- Design claim corrected in the error module: `ClassificationAdapterError` moduledoc's `:context_length_exceeded` status cell 422 → 400 (24.1 file, one table cell; a user-facing false claim once the probe observed 400).

### Fix pass (2026-09-28)

- `[fixed]` Two raise paths out of `classify/2`, breaking `ALLM.ClassificationAdapter` invariant 1 (code review F1 + functional review KI-1, same site; security review informational). (1) A non-number score `probabilities` value hit `to_float!/1` (`FunctionClauseError`); now `float_list/2`, the score sibling of `float_map/2`, returns `:malformed_response`, and `to_float!/1` is gone. (2) A 422 `loc` holding an object or a nested non-codepoint list raised `Protocol.UndefinedError` / `UnicodeConversionError` from `to_string/1` in `validation_message/1` (reproduced by `mix run` before fixing); a `loc` with any segment that is not a string or integer now drops the prefix and keeps the `msg`. Pinned by two new breach-table rows in `classification_test.exs` (score `"0" => "x"`, `"2" => nil`) and "a 422 loc holding anything but strings and integers is dropped, never raised on"; both red against the checkpoint `classification.ex`.
- Decoder sweep: a scratch fuzz over `recorded/mixed_questions.json` (every answer field, every score-map level, `answers`, `usage`, `model` × 12 hostile JSON values, 360 bodies) → 0 raises after the fix, 27 (all `to_float!/1`) against the checkpoint file. No other raising conversion on provider data.
- Deferred to the phase-end polish pass (Low): code review F2 / functional KI-2 (probability and `confidence` range checks), code review F3 (`"0".."0"` text when the level count is unknown — error text in code, not a governed document, so outside the false-sentence carve-out).
- Gates: `mix test` → exit 0, `664 doctests, 33 properties, 5487 tests, 0 failures, 14 excluded, 1 skipped`; `--seed 0` same; `mix test test/allm/providers/typesafe/` → `3 doctests, 79 tests, 0 failures`; format, credo `--strict`, dialyzer → 0; docs audit `comm -13` → only `Files scanned:    140`. Fixtures byte-identical to the checkpoint (`cmp` loop over all 19).
