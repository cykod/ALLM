# Phase 26 — ElevenLabs Audio and Streaming Speech — Records

Companion to `steering/2026-09-25_ELEVENLABS_TTS_SST.md`. Status, ticks, deviations and notes live here. The design doc is edited only for dated `> CORRECTED` claim corrections.

## Status

| Phase | Status |
|-------|--------|
| 26.1 | Completed |
| 26.2 | Completed |

## Phase 26.1 — `Support.HTTPResponse` + `Support.TranscriptionAdapter`

Built 2026-09-26 on `7499917`. The working tree is uncommitted; the orchestrator commits after review.

### Checklist (26.1.2)

- [x] `lib/allm/providers/support/http_response.ex`: ten `@doc false` + `@spec` helpers (`header_value/2`, `retry_after_ms/1`, `decode_error_body/1`, `decode_json_error_body/1`, `error_object/1`, `sanitize_cause/1`, `build_metadata/2`, `maybe_apply_req_test_stub/2`, `maybe_apply_request_timeout/2`, `apply_receive_timeout/3`), plus private `header_value_to_string/1` and `parse_retry_after/1`.
- [x] `lib/allm/providers/support/transcription_adapter.ex`: `fetch_transcription_script/1`, `with_own_cap/2`, `measure/3`, `gate_size/4`, `unresolvable_error/3`, `stub_error/2`, `do_transcribe/4`, `run_one_attempt/5`, `transport_error/5`, `resolve_bytes/3`. `openai/transcription.ex` and `gemini/transcription.ex` are migrated.
- [x] Every copy of each moved helper is migrated, in 12 files: `anthropic.ex`, `openai.ex`, `gemini.ex`, `openai/{embeddings,images,moderation,speech,transcription}.ex`, `gemini/{embeddings,images,transcription}.ex`, `voyage/embeddings.ex`.
- [x] `groups_for_modules` has both modules under `Providers` (`mix.exs`).
- [x] ASKS tickets: two `[DISPOSITION]` entries appended to `.work/ASKS.md` (sat 9/26 8pm). The HTTP ticket is narrowed to the variant names, and the transcription ticket is closed with its empty predicate output.

### Discovery (throwaway script, not committed)

The script parsed every `lib/allm/providers/**/*.ex` with `Code.string_to_quoted/1`, collected each named helper's clauses per file, stripped metadata, and grouped files by `Macro.to_string/1` of the clauses. The first pass split groups on differences with no semantic effect: an ignored variable named `_` vs `_body`, and `opts |> Keyword.get(…)` vs `Keyword.get(opts, …)`. Those were then merged by hand. The raw output at `7499917`:

| Helper | Copies | Text groups (size) |
|--------|--------|--------------------|
| `apply_receive_timeout/2` | 3 | 1 (3) |
| `build_metadata/2` | 9 | 1 (9) |
| `decode_error_body/1` | 12 | 3 (5, 4, 3). The 5 and 4 groups differ only in `_` vs `_body`; the 3 group JSON-decodes binaries |
| `error_object/1` | 3 | 1 (3) |
| `header_value/2` | 9 | 3 (5, 2, 2) |
| `header_value_to_string/1` | 9 | 3 (5, 2, 2). The 5 and one 2 group differ only in `_v` vs `_` |
| `maybe_apply_req_test_stub/2` | 12 | 2 (8, 4), differing only in pipe style |
| `maybe_apply_request_timeout/2` | 9 | 1 (9) |
| `parse_retry_after/1` | 9 | 6 (3, 2, 1, 1, 1, 1) |
| `provider_message/2` | 5 | 3 (2, 2, 1) |
| `redact_optional/1` | 3 | 1 (3) |
| `retry_after_ms/1` | 9 | 1 (9) |
| `sanitize_cause/1` | 9 | 2 (6, 3) |

The transcription helpers were grouped with `:gemini` rewritten to `:openai`. Each of the ten named helpers had one group of 2.

### Deviations

- `[structural, documented]` **This refactor touches released code in 12 provider files.** That falls under CLAUDE.md's "two-implementations promotion trigger" exception and `agent-spec/IMPLEMENTATION.md` "Migration on extraction". The change is private and behaviour-preserving. No public name was removed. Every prior-phase test stays green with zero assertion changes, and the mutation table below shows what pins each cell.
- `[structural, documented]` **`header_value/2`, `header_value_to_string/1` and `parse_retry_after/1` were merged on behaviour, not text.** This departs from the design's "byte-identical" rule, for three reasons:
  - `openai/{speech,transcription}.ex` write the map clause as `Map.get |> header_value_to_string()` and rely on its `nil` catch-all. That is equivalent on every input.
  - `anthropic.ex` and `openai.ex` lack the two catch-all clauses. They differ only on inputs that raised `FunctionClauseError` before: headers that are neither a map nor a list, or a non-binary header value. Every caller passes `Req`'s header map or a tuple list. The seam tests `from_anthropic_error/3` / `from_openai_error/3` use lists (`test/allm/providers/anthropic_test.exs:662-668`).
  - The six `parse_retry_after/1` texts are only ever called from `retry_after_ms/1` with a binary. Two of them (`openai.ex`, `openai/images.ex`) fall through to `parse_http_date/1`, and both copies of that were `defp parse_http_date(_value), do: nil`. So all six return the same value for every reachable input. Both `parse_http_date/1` stubs were deleted with them.

  Keeping the text-variant groups would have needed two same-named helpers with identical behaviour. The shared helper is the lenient form. Dialyzer then showed `parse_retry_after/1`'s own catch-all to be unreachable (`pattern_match_cov`), so it was dropped.
- `[scope]` **Two groups of ≥ 2 moved under one helper name each, as the design's size ≥ 2 rule requires.** The JSON-decoding `decode_error_body/1` group (3 copies) became `HTTPResponse.decode_json_error_body/1`. The design named that group as an example of a variant that stays; the correction is next to the claim in the design doc.
- `[scope]` **One group of ≥ 2 stayed: `sanitize_cause/1`'s six data-only copies** (`openai/{embeddings,images,moderation}.ex`, `gemini/{embeddings,images}.ex`, `voyage/embeddings.ex`). The three offset-resetting copies became the shared `sanitize_cause/1`. Moving the six as well would put two same-named helpers with different behaviour in one module, and the shared one would be the known-buggy form (HANDOFF `[BUG]` "`sanitize_cause/1` blanks `Jason.DecodeError.data` but leaves `:position`"). Converging them onto the shared form is that bug's fix, which is a behaviour change outside a refactor. HANDOFF now names the shared helper as the fix.
- `[scope]` **`apply_receive_timeout` moved with its default as an argument** (`apply_receive_timeout/3`). The body was text-identical in three files, but `@default_timeout_ms` differs: 60,000 in speech and 120,000 in both transcription adapters. This follows the design's TranscriptionAdapter rule that "a module attribute is a further argument".
- `[structural, documented]` **Two adapter functions became `@doc false def` + `@spec`** in both transcription adapters, so `TranscriptionAdapter` can call them on the adapter module:
  - `build_request/2`, which the design names.
  - `malformed_error/2`, which the design does not name. `run_one_attempt/5`'s invalid-JSON arm calls it (corrected in the 26.1 fix pass; this line said `/3`), and its message carries the provider name ("could not decode OpenAI/Gemini transcription response").
- `[structural]` `do_transcribe` and `run_one_attempt` take the provider atom as well as the adapter module (`/4` and `/5`). `transport_error/5` needs the atom, and the adapter exposes no provider accessor.
- `[doc]` Comment blocks that listed the moved helpers as private copies were updated in place in `openai/{embeddings,moderation,speech,transcription}.ex`, `gemini/{embeddings,transcription}.ex` and `voyage/embeddings.ex`. The three "`parse_retry_after/1` returns `nil` INLINE … `parse_http_date/1` stub" divergence notes were removed, because the divergence no longer exists.

### Remaining variants (the HTTP predicate's output)

| Helper | Copies | Why it stays |
|--------|--------|--------------|
| `provider_message/2` | 5 (`openai/{speech,transcription}.ex`, `gemini/transcription.ex`: redacts and falls back to `"<Provider> HTTP <status>"`; `gemini/{embeddings,images}.ex`: a different shape with no redaction) | It renders a provider name and calls the per-provider `redact_key_material/1` |
| `redact_optional/1` | 3 (`openai/{speech,transcription}.ex`, `gemini/transcription.ex`) | It calls the per-provider `redact_key_material/1`, whose pattern stays per provider (CLAUDE.md) |
| `sanitize_cause/1` | 6 (listed above) | The data-only form; converging it is the HANDOFF `[BUG]` fix |

### Mutation check (26.1.1)

For each moved helper, a mutant was put into the support module, and the test files of every provider file that migrated that helper were run in one `mix test` invocation. Failures were attributed per file by their `test/…exs:N` location. The mutants:

- `header_value`, `retry_after_ms` → `nil`
- `decode_*` and `error_object` → `%{}`
- `sanitize_cause` → identity
- `build_metadata` → drops `request_id`
- the three `Req` helpers → return `req` unchanged
- `fetch_transcription_script` → `nil`
- `with_own_cap` → `opts` unchanged
- `measure` → `{:ok, 0}`
- `gate_size` → `:ok`
- `unresolvable_error` and `stub_error` → a bare error with the wrong or missing fields
- `do_transcribe` → skips the gates
- `run_one_attempt` → always a transport error
- `transport_error` → `:unknown`
- `resolve_bytes` → `{:ok, ""}`

The support modules were restored and `cmp`-verified against saved copies after each run.

| Helper | Failing tests per migrating file |
|--------|----------------------------------|
| `header_value/2` | gemini.ex 2, openai/embeddings 4, openai/images 8, openai/moderation 3, voyage/embeddings 4, anthropic.ex 2, openai.ex 2, openai/speech 11, openai/transcription 5 |
| `retry_after_ms/1` | anthropic.ex 2, gemini.ex 2, openai.ex 2, openai/embeddings 3, openai/images 3, openai/moderation 2, openai/speech 2, openai/transcription 2, voyage/embeddings 3 |
| `decode_error_body/1` | anthropic.ex 1, gemini.ex 1, gemini/images 2, openai.ex 2, openai/images 5, gemini/embeddings 2, openai/embeddings 2, openai/moderation 2, voyage/embeddings 2 |
| `decode_json_error_body/1` | gemini/transcription 7, openai/speech 8, openai/transcription 7 |
| `error_object/1` | gemini/transcription 7, openai/speech 8, openai/transcription 7 |
| `sanitize_cause/1` | gemini/transcription 1, openai/speech 1, openai/transcription 1 |
| `build_metadata/2` | gemini/embeddings 2, gemini/images 4, gemini/transcription 1, openai/embeddings 2, openai/images 6, openai/moderation 2, openai/speech 1, openai/transcription 1, voyage/embeddings 2 |
| `maybe_apply_req_test_stub/2` | anthropic.ex 43, gemini.ex 54, gemini/images 27, openai.ex 44, gemini/embeddings 17, gemini/transcription 20, openai/embeddings 17, openai/images 49, openai/moderation 18, openai/speech 14, openai/transcription 13, voyage/embeddings 18 |
| `maybe_apply_request_timeout/2` | anthropic.ex 1, gemini.ex 1, gemini/embeddings 1, **gemini/images 0 → 1**, openai.ex 1, openai/embeddings 1, **openai/images 0 → 1**, openai/moderation 1, voyage/embeddings 1 |
| `apply_receive_timeout/3` | gemini/transcription 1, openai/speech 2, openai/transcription 1 |
| `fetch_transcription_script/1` | gemini/transcription 7, openai/transcription 7 |
| `with_own_cap/2` | gemini/transcription 2, openai/transcription 2 |
| `measure/3` | gemini/transcription 9, openai/transcription 10 |
| `gate_size/4` | gemini/transcription 3, openai/transcription 3 |
| `unresolvable_error/3` | gemini/transcription 5, openai/transcription 6 |
| `stub_error/2` | gemini/transcription 1, openai/transcription 1 |
| `do_transcribe/4` | gemini/transcription 10, openai/transcription 9 |
| `run_one_attempt/5` | gemini/transcription 21, openai/transcription 14 |
| `transport_error/5` | gemini/transcription 2, openai/transcription 2 |
| `resolve_bytes/3` | gemini/transcription 4, openai/transcription 7 |

Test files per provider file: `anthropic.ex` → `test/allm/providers/anthropic_{test,vision_test,wire_test,stream_wire_test}.exs`; `openai.ex` → the same four `openai_*` files; `gemini.ex` → `gemini_{test,tools_test,vision_test,wire_test,stream_test,stream_wire_test}.exs`; `<dir>/<cap>.ex` → `test/allm/providers/<dir>/<cap>_*test.exs`, excluding `*live*`. The support modules' own tests were not in any run.

**Two unpinned cells, now pinned.** Nothing pinned `maybe_apply_request_timeout/2` in either image adapter. Each adapter's test file gained one test, "applies opts[:request_timeout] as :receive_timeout, and leaves it unset without one":

- `test/allm/providers/openai/images_test.exs`, in `describe "prepare_request/2"`
- `test/allm/providers/gemini/images_test.exs`, in `describe "prepare_request/2"`

Both pass the key via `opts[:api_key]`, not `Keys.put/2`. After adding them, the mutant was re-run and both cells read 1.

### Verification (run 2026-09-26, working tree on `7499917`)

| Check | Result |
|-------|--------|
| `mix test` | exit 0, 534 doctests, 31 properties, 4182 tests, 0 failures, 14 excluded |
| `mix test --seed 0` | exit 0, same counts |
| `mix format --check-formatted` | exit 0 |
| `mix credo --strict` | exit 0, no issues |
| `mix dialyzer` | exit 0, `Total errors: 0` (after dropping the unreachable `parse_retry_after/1` catch-all) |
| `mix run scripts/audit_user_docs.exs lib/allm/providers/support/http_response.ex` | "No banned-token matches" |
| `mix run scripts/audit_user_docs.exs lib/allm/providers/support/transcription_adapter.ex` | "No banned-token matches" |
| async grep `grep -rl 'Keys.put(\|Logger.configure(\|System.put_env(\|:telemetry.attach' test/ \| xargs grep -L 'async: false'` | 12 files, all pre-existing. This phase adds no hit: its two new test files and two added tests use none of the four calls |
| HTTP predicate (Phase 25 form, 13 names) | 3 lines: `provider_message` 5, `redact_optional` 3, `sanitize_cause` 6. This matches the variant table above |
| Transcription predicate (`.work/ASKS.md` thu 9/24 3am form) | empty output, exit 0 |
| `conformance/` | not touched, so its gates were not run |
| `README.md` | not modified |

New test files are `test/allm/providers/support/http_response_test.exs` (10 describe blocks, one per helper) and `test/allm/providers/support/transcription_adapter_test.exs` (every helper, run for `:openai` and `:gemini`).

### Fix pass (2026-09-26)

Sources: `.work/reviews/2026-09-26-phase-26-1/overview.md`, `.work/code-reviews/2026-09-26-phase-26-1.md`, `.work/security-reviews/2026-09-26-phase-26-1.md` (clean), `.work/design-reviews/2026-09-26-phase-26-1.md` (N/A).

- `[structural, documented]` **Code review F2: the five adapter functions `Support.TranscriptionAdapter` dispatches are now `@callback`s** (`gate_audio/2`, `build_request/2`, `decode_response/4`, `to_transcription_adapter_error/4`, `malformed_error/2`, each `@doc false`). Both transcription adapters declare `@behaviour ALLM.Providers.Support.TranscriptionAdapter` next to `@behaviour ALLM.TranscriptionAdapter` and mark the five `@impl`. Binding check: a probe module declaring the behaviour with only `gate_audio/2` compiled with four "required by behaviour … is not implemented" warnings (`mix run -e 'Code.compile_string(…)'`). The optional `provider/0` callback was not added; the provider-atom `[structural]` note above stands.
- `[doc]` **Code review F1: line-number cites the shrink staled were replaced by symbol anchors.** Measured by comparing each cited line's text at `7499917` and in the working tree for every `<file>.ex:NNN` cite in `lib/` pointing into the 12 migrated files. Fixed: `openai/moderation.ex` (7 cites, into `openai/embeddings.ex`, `openai.ex`, `anthropic.ex`, `gemini.ex`), `gemini/images.ex` (9 cites: the review's `:404` plus, finishing the class in that file, the `openai/images.ex` parity map and two moduledoc cites), and two the review did not list that were accurate at base and stale after the shrink: `support/openai_headers.ex` (`openai.ex:443-446` → `do_prepare/3`) and `openai/images.ex` (`openai.ex:411-435` → `prepare_request/2`). Left as-is: base-stale cites in other files (`gemini.ex` ×9, `gemini/decode.ex:130`), same class, not this refactor's damage; phase-end polish.
- `[doc]` **Code review F3 (Low, taken under the false-comment carve-out):** the empty `# Internals — headers` banner in `openai/speech.ex` is deleted; the `gemini/embeddings.ex` note no longer says the OpenAI sibling carries its own `parse_retry_after/1`; the `voyage/embeddings.ex` `put_pair/2` parenthetical moved back under its bullet.
- Deferred to the phase-end polish pass: code review F4 (Low, `map() | list() | term()` specs). Functional review KI-1 is pre-existing and outside this refactor's fence: transcribed to the HANDOFF image-funnel `[BUG]` row, widened to eight adapters. KI-2 is already tracked (HANDOFF `sanitize_cause/1` `[BUG]` row).

| Check (after the fix pass) | Result |
|-------|--------|
| `mix test` / `mix test --seed 0` | exit 0, 534 doctests, 31 properties, 4182 tests, 0 failures, 14 excluded |
| `mix format --check-formatted` | exit 0 |
| `mix credo --strict` | no issues |
| `mix dialyzer` | `Total errors: 0` |
| `mix compile --warnings-as-errors --force` | exit 0 |
| `mix docs` | exit 0, no warnings |
| `mix run scripts/audit_user_docs.exs` on each new `lib/` file | "No banned-token matches" ×2 |
| async grep (as above) `\| wc -l` | 12, unchanged |

## Phase 26.2 — Layer A: events, stream request, fields, reasons

Built 2026-09-26 on `6167d79`. The working tree is uncommitted; the orchestrator commits after review.

### Checklist (26.2.2)

- [x] Three new modules: `lib/allm/speech_event.ex`, `lib/allm/transcription_event.ex`, `lib/allm/transcription_stream_request.ex`. `SpeechRequest` and `SpeechResponse` gain `:sample_rate` (default `nil`, decoded as `data["sample_rate"]`). `:unsupported_feature` is added to both error enums: `@type reason`, `@legal_reasons`, the moduledoc reason table and count sentence, and a `legal_reasons/0` doctest.
- [x] `Validate.speech_request/2` (with `speech_request/1` kept through a `\\ []` default) and `Validate.transcription_stream_request/1`.
- [x] `lib/allm.ex` `@speech_request_field_opts` gains `:sample_rate`, and the two `@doc` prose lists naming those opts (`speech_request/2`, `synthesize/3`) gain it too. `test/allm/allm_synthesize_test.exs`'s symmetry test is green.
- [x] `@known_modules` +1 (`ALLM.TranscriptionStreamRequest`; the events are ETF-only and not registered). `@layer_a` +3. `mix.exs` `groups_for_modules` `"Data types"` +3.
- [x] Contract-flip dispositions: below.

### Constructor guards (CLAUDE.md Layer-A constructor rule)

- `SpeechRequest.new/1`, `SpeechResponse.new/1`, `TranscriptionStreamRequest.new/1` stay bare `struct!/2`. No guard on `:sample_rate`, `:commit_strategy` or any other new field. Pinned by `speech_request_test.exs` ("sample_rate is unguarded") and `transcription_stream_request_test.exs` ("fields are unguarded").
- The event constructors are functions, not struct constructors. They check required payload keys (`ArgumentError` naming the missing keys), and `SpeechEvent.audio_delta("")` raises `ArgumentError`, per the design's contract block.
- `TranscriptionStreamRequest.__from_tagged__/1` uses `decode_sample_rate/1` and `decode_commit_strategy/1` pairs, not `||`. Pinned by the JSON round-trip with `sample_rate: 8_000, commit_strategy: :manual`, and by "a JSON payload lacking both keys decodes to the defaults".

### Contract-flip audit (`git grep -n 'unsupported_feature' test/allm/error/ lib/allm/error/speech_adapter_error.ex lib/allm/error/transcription_adapter_error.ex`)

| Hit (before) | Disposition |
|-----|-------------|
| `speech_adapter_error_test.exs` `@legal_reasons` literal (had no `:unsupported_feature`) | flipped: `:unsupported_feature` added, so the MapSet comparison and the per-reason `new/2` tests cover it |
| `speech_adapter_error_test.exs` "returns the 9-atom closed set" (`== 9`) | flipped: 10 |
| `speech_adapter_error_test.exs` "drops :batch_too_large, :unsupported_feature and :content_filter" (`refute :unsupported_feature`) | flipped: the refute is removed, the test renamed to "drops :batch_too_large and :content_filter", and a new "carries :unsupported_feature" test asserts membership |
| `transcription_adapter_error_test.exs` `@legal_reasons` literal | flipped, as above |
| `transcription_adapter_error_test.exs` "returns the 10-atom closed set" (`== 10`) | flipped: 11 |
| `transcription_adapter_error_test.exs` "drops :batch_too_large and :unsupported_feature" | flipped: renamed "drops :batch_too_large"; new "carries :unsupported_feature" test |
| `speech_adapter_error.ex` moduledoc "nine reasons" and the "There is no `:unsupported_feature` either, because no bundled speech adapter refuses a request field" sentence | flipped: "ten reasons"; the sentence is removed and the reason gets a table row |
| `transcription_adapter_error.ex` moduledoc "ten reasons: the nine that …" and the matching "There is no `:unsupported_feature`" sentence | flipped: "eleven reasons: the ten that …"; sentence removed; table row added |
| `legal_reasons/0` doctests (`length == 9` / `== 10`) | flipped: 10 / 11, plus an `:unsupported_feature in legal_reasons()` doctest each |
| `adapter_error_test.exs`, `embedding_adapter_error_test.exs`, `image_adapter_error_test.exs`, `moderation_adapter_error_test.exs` `@legal_reasons` literals | keep: other error families, which already carried the atom |

After the flip, the predicate's hits are the four keep rows plus the new membership assertions and the two modules' own type/list/table/doctest lines.

### Deviations

- `[scope]` **Event constructor arities not fixed by the design.** The contract block specs only `SpeechEvent`'s constructors. `TranscriptionEvent` got `transcription_started/1`, `partial_transcript/1`, `committed_transcript/2` (language defaults to `nil`) and `transcription_completed/1`, mirroring `SpeechEvent`. No constructor for `:error` in either union, matching `ALLM.Event` (opaque/struct payload).
- `[scope]` **"Required keys" read as "every key in the payload type".** A key may be present with value `nil`. `event?/1` does not check payload keys (only the payload's kind: map, non-empty binary, or the family's error struct), matching `ALLM.Event.event?/1`. `event?({:audio_delta, ""})` is `false`, consistent with the constructor.
- `[scope]` **`event?/1` on `{:error, _}` requires the family's own error struct.** A `TranscriptionAdapterError` is not a speech event, and vice versa. Tested both ways.
- `[scope]` **`speech_request/2` with `input: :streamed` skips the `:input` hard-reject as well as `:empty` / `:invalid_encoding`** (the design's "the three `:input` rows are skipped; any other `:input` value is ignored"). Any other value of the `:input` *option* keeps the default rules (tested).
- `[scope]` The duplicated private `require_keys!/3` in the two event modules is two copies, below the extraction threshold. Not extracted.

### Notes for later sub-phases

- **26.4:** `lib/allm/speech_request.ex` moduledoc still says "There is no `:stream` field: speech synthesis is non-streaming." That becomes false when `stream_synthesize/3` lands; reword it then (streaming is a separate call, not a request flag).
- **26.9:** the spec still reads "`ALLM.Error.SpeechAdapterError` (9 reasons) and `ALLM.Error.TranscriptionAdapterError` (the same 9 plus `:content_filter`)" (`grep -n "(9 reasons)" steering/allm_engine_session_streaming_spec_v0_2.md` → `:2844`, 2026-09-26). Add `:unsupported_feature` there with the rest of the spec amendment.

### Verification (run 2026-09-26, working tree on `6167d79`)

| Check | Result |
|-------|--------|
| `mix test` | exit 0, 554 doctests, 31 properties, 4237 tests, 0 failures, 14 excluded (26.1: 534 / 4182) |
| `mix test --seed 0` | exit 0, same counts |
| `mix format --check-formatted` | exit 0 |
| `mix credo --strict` | no issues |
| `mix dialyzer` | `Total errors: 0` |
| `mix compile --warnings-as-errors --force` | exit 0 |
| `mix run scripts/audit_user_docs.exs <file>` on the 3 new `lib/` files (and the 5 modified Layer A / validator files) | "No banned-token matches" each |
| async grep `grep -rl 'Keys.put(\|Logger.configure(\|System.put_env(\|:telemetry.attach' test/ \| xargs grep -L 'async: false' \| wc -l` | 12, unchanged; the new test files use none of the four calls |
| `test/layer_a_docs_test.exs` | 33 tests (was 30 at `6167d79`: 29 modules + 1). `@layer_a` literal 29 → 32 entries; the delta is exactly the three new modules' moduledoc tests |
| `conformance/` | not touched, so its gates were not run |
| `README.md` | not modified |

