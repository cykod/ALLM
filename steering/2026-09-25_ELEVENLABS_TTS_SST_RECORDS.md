# Phase 26 — ElevenLabs Audio and Streaming Speech — Records

Companion to `steering/2026-09-25_ELEVENLABS_TTS_SST.md`. Status, ticks, deviations and notes live here. The design doc is edited only for dated `> CORRECTED` claim corrections.

## Status

| Phase | Status |
|-------|--------|
| 26.1 | Completed |
| 26.2 | Completed |
| 26.3 | Completed |
| 26.4 | Completed |
| 26.5 | Completed — fix-pass widened-fence edits (`lib/allm/adapter.ex`, `lib/allm/stream_runner.ex`, `lib/allm.ex` `run_audio_stream/3`, `support/transport.ex`) landed after the review checkpoint and are unreviewed; pinned by `test/allm/transport_opts_routing_test.exs` + the mutation table in §26.5 Fix pass |

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


## Phase 26.3 — Behaviours, Fake streaming, conformance

Built 2026-09-26 on `e567f54`. The working tree is uncommitted; the orchestrator commits after review.

### Checklist (26.3.2)

- [x] `lib/allm/speech_stream_adapter.ex`, `lib/allm/transcription_stream_adapter.ex`: callbacks with `@doc`, a minimum skeleton, and numbered invariants. Cleanup (halt-safety) is invariant 4 in both.
- [x] `lib/allm/providers/support/input_pump.ex` (`spawn_monitor` + linked watchdog + credit window + string-only `:input_error`). `test/support/finch_stub.ex` gains the Agent-backed mode (`install_shared/2`, `senders/1`; `cancel_count/1` and `captured_opts/1` take the Agent pid).
- [x] `FakeSpeech.stream_synthesize/2` and `stream_synthesize_input/3`, `FakeTranscription.stream_transcribe/3` and `stream_sample_rates/0`. Both input paths reduce through the pump. `{:events, _}` entry, moduledoc script tables. Non-streaming `FakeSpeech.synthesize/2` reports `sample_rate: request.sample_rate`.
- [x] Three suites under `conformance/lib/allm/test/`, three stubs under `conformance/test/support/fixtures/`, three meta-test files (four meta-invariants each). `lib/allm/speech_adapter.ex` "HTTP transport guidance" now points at `ALLM.SpeechStreamAdapter`.
- [x] `groups_for_modules`: the two behaviours under `Behaviours`, `InputPump` under `Providers`.

### Deviations

- `[tactical]` **`InputPump.stop/2` kills first, then removes the monitor, then waits.** The contract block reads "`demonitor(ref, [:flush])`; `Process.exit(pid, :kill)`; drain". In that order a pump that has been sent `:kill` but is not yet dead could still deliver an element after the drain. The implementation calls `Process.exit/2`, then `Process.demonitor(ref, [:flush, :info])`; when that returns `true` (the monitor had not fired) it monitors the pid again and waits for that `:DOWN`, which is ordered after every message the pump sent, and only then drains `{ref, _}` and any `:DOWN` for `ref`. Same observable contract, idempotent (pinned by "stop/2 is idempotent, including after the pump finished on its own").
- `[structural, documented]` **`InputPump.crash_info/1` (public, doctested) is not in the contract block.** It turns a pump's abnormal `:DOWN` reason into the same string-only `%{kind: :exit, message: _}` map an `:input_error` carries, so `err.cause` never holds the raw exit term (Decision #7). Both Fakes use it, and 26.7/26.8 need the identical conversion. *(Fix pass: the Fakes now reach it through `InputPump.classify/2`, which applies it to every pump `:DOWN`.)*
- `[tactical]` **The Agent-backed FinchStub's pid rides as `finch_stub_ref:`,** not a new key: `ALLM.Providers.Support.Transport.finch_opts/2` forwards only `@finch_forwarded_opts` (`:finch_stub_ref` among them) to `async_request/3`, and a new key would mean editing `transport.ex`, outside this Module Tree. `async_request/3` dispatches on `is_pid/1`; a pid returns a fresh ref per call and delivers to the `async_request/3` caller from a `spawn_link`ed sender. The default `install/2` mode is untouched (pinned by "the default install/2 mode is unchanged…" in `input_pump_test.exs`).
- `[tactical]` **The Fakes' `capture_pid` seam also fires on the stream callbacks**, with the same `{Module, :call, %{request:, opts:}}` message, so 26.4 can assert what the stream façades dispatch.
- `[tactical]` **FakeSpeech's input-form gate is `Validate.speech_request(request, input: :streamed)`**, mapped to `%SpeechAdapterError{reason: :invalid_request, metadata: %{errors: errors}}`. `stream_synthesize/2` gates only empty input, matching `synthesize/2`.
- `[tactical]` **Stream paths that reduce no input return a list** (the Fake has no transport, so a list is already lazy with respect to I/O). Only the input paths are `Stream.resource/3` over the pump.
- `[tactical]` **`{:ok, %SpeechResponse{}}` / `{:ok, %TranscriptionResponse{}}` script entries on a stream path are emitted from the struct's fields**, and the input form does not reduce input for them (as for `{:error, _}` and `{:events, _}`). The design names only `{:ok, bytes}`/`{:ok, text}`; the struct entries were already in the script grammar, and 26.4's equivalence property can generate them.
- `[tactical]` **FakeTranscription's committed segment is the script text verbatim** (`" the quick "`); a text with no words emits no partial and no committed segment; `language: nil`. `:transcription_completed.text` is the trimmed join.
- `[scope]` **The meta-test `KeyError` modules have suite-unique names** (`MissingSpeechStreamAdapterOpt`, `MissingSpeechInputAdapterOpt`, `MissingTranscriptionStreamAdapterOpt`). `__MODULE__` inside the runtime `quote` is `nil`, so the copied name `MissingSpeechAdapterOpt` collided with the Phase 25 suite's module under `async: true` (`cannot define module … because it is currently being defined`, 3 failures in the first full run). The Phase 25 self-tests carry the same latent hazard between themselves only if two suites ever reuse a name.
- `[scope]` **Each suite's `:gate_opts` meta-test keys its reach marker on the stream transport seam** (`:finch_module` for the speech suite, `:ws_module` for the input and transcription suites), not `:plug`: `:plug` is a `Req` option and the stream paths never reach `Req`.
- `[scope]` The FinchStub mode tests live in `input_pump_test.exs`; the Module Tree lists no `finch_stub_test.exs`.
- ~~`[DEFERRED-DRY]` The two Fakes' input loops are parallel … **DONE WHEN** `grep -l 'defp next_input_events' lib/allm/providers/*.ex` lists at most one file.~~ **RESOLVED in the 26.3 fix pass** (code-review F2, `.work/code-reviews/2026-09-26-phase-26-3.md`). The pump-protocol half moved to `ALLM.Providers.Support.InputPump`: `is_pump_message/2` (a `defguard` selecting `{ref, _}` and the pump's `:DOWN` in a selective `receive`), `classify/2` (pure: `{:input, el}` | `:done` | `{:failed, :input_raised | :input_crashed, input_error()}`; `:DOWN` goes through `crash_info/1`) and `default_window/0` (8). Both Fakes migrated; each keeps its own `next_input_events/1` for its element rules and error module, which is what the struck predicate counted — **it measured a proxy** (a function name, not the protocol copy) and could never go below two files without renaming. Replacement predicate, scoring the protocol copy itself: `grep -lE --exclude=input_pump.ex ':input_error|crash_info\(|@input_window' lib/allm/providers/*.ex lib/allm/providers/*/*.ex` must be empty (exit 1 on this tree). The `resolve_script/1` / cursor copies stay under the existing ASKS thu 9/24 3am `[DISPOSITION]` ticket.
- `[tactical, fix pass]` **FakeSpeech struct entries on the stream paths** (code-review F1 + functional-review Known Issue 1, same site). `{:ok, %SpeechResponse{}}` with zero-byte audio now ends `:speech_started`, `:invalid_request`/`cause: :empty_input` (was `started, completed` with no delta — invariant 3 broken); with unreadable audio (`nil`, missing file) it ends `:speech_started`, `:unknown`/`cause: :unreadable_script_audio` (was a synchronous `FunctionClauseError`/`MatchError` — invariant 1 broken). One `body_events/3` builder now serves the `{:ok, bytes}`, struct and input `{:bytes, _}` paths (code-review F3; `on_input_done/1` no longer `tl/1`s a started event). **Also found:** the `[tactical]` row above ("the input form does not reduce input for them") was FALSE for FakeSpeech — `{:entry, {:ok, bytes}}` had no `is_binary/1` guard, so a struct entry went into input `{:bytes, struct}` mode and crashed at `audio_delta/1`. Guard added; both new tests in `fake_speech_test.exs` drive both callbacks and fail against the unguarded clause (mutation run: 2 failures).

### Mutation checks (binding of the new tests)

| Mutant | Failing tests |
|--------|---------------|
| `InputPump.stop/2` skips the drain | behaviour 3 (both tests), FakeSpeech "a halt stops the pump and leaves no pump message…" — 3 |
| No watchdog | behaviour 3 (linked-process premise), behaviour 5 — 2 |
| FinchStub shared sender `spawn` instead of `spawn_link` | behaviour 6 (both), "install_shared/2 delivers to whichever process…" — 3 |

Each file was restored and re-verified green after its run. The stream-timeout reset is pinned by "the stream timeout resets on every input message…" (four 60 ms gaps against a 150 ms timeout); a whole-stream deadline would fail it.

### Notes for later sub-phases

- **26.4:** the moduledocs of `test/allm/allm_synthesize_test.exs:6` and `allm_transcribe_test.exs:6` say speech/transcription "has no streaming counterpart"; they become false with the façades. Also still open from 26.2: `lib/allm/speech_request.ex`'s "There is no `:stream` field: speech synthesis is non-streaming."
- **26.5–26.8:** consume pump messages with `InputPump.is_pump_message/2` (a selective-`receive` guard, beside the socket clauses) + `InputPump.classify/2`, ack `{:input, _}` with `InputPump.ack/2`, and default the window with `InputPump.default_window/0` — never re-match `{ref, {:input_error, _}}` / `:DOWN` by hand (the protocol lives in one place since the 26.3 fix pass; `classify/2` already turns a `:DOWN` into `crash_info/1`'s string-only map). Stop the pump in the after function with `InputPump.stop/2` (it drains `{ref, _}` and the `:DOWN`). A test whose input is an `ALLM.stream_generate/3` over `FinchStub` must use `FinchStub.install_shared/2`.
- **26.5–26.8 conformance invocations:** the three new suites take `speech_adapter:` / `transcription_adapter:` (the same keys as the Phase 25 suites) and `gate_opts:`.

### Verification (run 2026-09-26, working tree on `e567f54`)

| Check | Result |
|-------|--------|
| `mix test` | exit 0, 559 doctests, 31 properties, 4324 tests, 0 failures, 14 excluded (26.2: 554 / 4237) |
| `mix test --seed 0` | exit 0, same counts |
| `mix format --check-formatted` | exit 0 |
| `mix credo --strict` | no issues |
| `mix dialyzer` | `Total errors: 0` |
| `mix compile --warnings-as-errors --force` | exit 0 |
| `mix docs 2>&1 \| grep -iE 'warning\|error'` | empty |
| `mix run scripts/audit_user_docs.exs <file>` on the 3 new `lib/` files, the 3 new conformance harnesses, and modified `fake_speech.ex`, `fake_transcription.ex`, `speech_adapter.ex` | "No banned-token matches" each |
| async grep `grep -rl 'Keys.put(\|Logger.configure(\|System.put_env(\|:telemetry.attach' test/ \| xargs grep -L 'async: false' \| wc -l` | 12, unchanged; the new test files use none of the four calls |
| `cd conformance && mix test` | 186 tests, 0 failures (run three times) |
| `cd conformance && mix credo --strict` | no issues |
| `cd conformance && mix format --check-formatted` | exit 0 |
| Suite results for the Fakes | `FakeSpeech` 6/6 speech stream + 6/6 input; `FakeTranscription` 6/6 transcription stream (`test/allm/speech_stream_adapter_test.exs`, `test/allm/transcription_stream_adapter_test.exs`) |
| Coverage (`mix test --cover`) | `InputPump` 97.14%, `FakeSpeech` 96.67%, `FakeTranscription` 99.26%, both behaviours 100%, total 94.87% |
| `README.md` | not modified |

Pre-existing, not this sub-phase: `conformance/test/allm/test/speech_adapter_conformance_test.exs:84` warns `unused alias SpeechAdapterConformance` during `cd conformance && mix test`.


## Phase 26.4 — Façades, `AudioStream`, telemetry

Built 2026-09-26 on `762a66e`. The working tree is uncommitted; the orchestrator commits after review.

### Checklist (26.4.2)

- [x] `ALLM.stream_synthesize/3`, `ALLM.stream_synthesize_input/3`, `ALLM.stream_transcribe/3` (`lib/allm.ex`), each with `@doc` sections for input shapes, gate order, model resolution, no retry after open, laziness/halting, the first-chunk event and "telemetry carries no audio", plus runnable doctests over the Fakes. Internals: `do_stream_synthesize/3`, `do_stream_synthesize_input/4`, `do_stream_transcribe/4`, one shared `check_stream_slot/4` (gates 1–2), `check_stream_input/2` (gate 3), `handle_audio_stream_dispatch/2` (invariant 1) and `wrap_audio_stream/2` (invariant 3 + `[:allm, :audio, :first_chunk]`). No `Retry.run/3`. `@transcription_stream_request_field_opts` added. "When to reach for what" gains three rows.
- [x] `lib/allm/audio_stream.ex` (`collect_speech/1`, `collect_transcription/1`, `text_deltas/1`) + doctests; `mix.exs` `groups_for_modules` `Runtime` (the group holding `ALLM.StreamCollector`).
- [x] `ALLM.Telemetry`: `:stream_synthesize` / `:stream_transcribe` in `@type span_name` and `@valid_span_names`; moduledoc table rows for both spans and `[:allm, :audio, :first_chunk]`, plus a paragraph on the carve-out and `provider_model`.
- [x] `@public_facade` +3 (`test/allm_facade_doctest_inventory_test.exs`). Both "## No streaming yet" sections in `lib/allm.ex` are replaced by "## Streaming" pointers.
- [x] Carry-overs from RECORDS §26.2/§26.3: `lib/allm/speech_request.ex` moduledoc reworded (streaming is a separate call, not a request flag); the moduledocs of `test/allm/allm_synthesize_test.exs` and `allm_transcribe_test.exs` no longer say "no streaming counterpart"; the ragged `:sample_rate` lists in the `speech_request/2` and `synthesize/3` `@doc`s are reflowed.
- [x] Owner decision on `text_deltas/1`: a chat `{:error, err}` raises `ALLM.AudioStream.ChatStreamError` (reason + message, never the struct). Pinned by `audio_stream_test.exs` "a chat error ends the speech stream with :input_raised, never a successful clip". **Mutation run:** `{:error, _err} -> []` (the halting/dropping implementation) → that test and the Jason round-trip test fail (2 failures); restored green.

### Deviations

- `[structural, documented]` **`ALLM.AudioStream.ChatStreamError` lives in its own file, `lib/allm/audio_stream/chat_stream_error.ex` (`@moduledoc false`),** not in `audio_stream.ex` as the Module Tree implies. `test/groups_for_modules_audit_test.exs` excludes a whole file that contains `@moduledoc false` (its moduledoc's "Multi-module files" limitation), so a private exception inside `audio_stream.ex` would have hidden `ALLM.AudioStream` from the audit — the same reasoning the design applies to `Support.WebSocket` / `WebSocket.Mint`.
- `[scope]` **The stream façades raise `ArgumentError` on an adapter's synchronous return that is not `{:ok, enumerable}` or the family's error struct** ("violated ALLM.SpeechStreamAdapter invariant 1" / "…TranscriptionStreamAdapter invariant 1"). The design names only the invariant-3 raise; this mirrors the non-streaming façades' invariant-1 raise. Tested in both façade files.
- `[scope]` **`collect_transcription/1` sets `metadata.committed_text` on an error** (the trimmed single-space join of the committed segments so far). Decision #7 names it; the 26.4 contract bullet for `collect_transcription/1` does not.
- `[scope]` **`collect_speech/1` returns `:malformed_response` for a `:speech_completed` with no preceding `:speech_started`** (there is no MIME type to build the `ALLM.Audio` from), as well as for a stream with no terminal event. It stops reducing at the first terminal event.
- `[scope]` **`provider_model` on `[:allm, :audio, :first_chunk]`** is the `:model` of the stream's start event when the adapter reports a binary one, else the dispatched `request.model` (after slot stamping for speech; `nil` possible). The design names the key without defining it; the definition is in the `ALLM.Telemetry` moduledoc.
- `[tactical]` **`Stream.transform/3`, not `/4`.** The wrapper has no cleanup of its own; the inner stream's after function runs on a wrapper raise (pinned: "the inner stream's after function still runs when the invariant-3 raise fires").
- `[tactical]` **The two span `:stop` events carry `%{response: nil}` only** — no `error`/`usage` keys, matching the chat `:stream` span rather than the non-streaming audio spans.
- `[tactical]` **`opts[:request]` on the input forms must be the capability's request struct;** any other non-nil value raises `CaseClauseError`. `:request` is dropped from the dispatch opts.
- `[tactical]` **Allow-list symmetry tests use a per-field table of valid values rather than a sentinel.** The stream façades validate before dispatch, so a sentinel never reaches the capture seam. The table is keyed by `Map.keys/1` of the struct and the test fails naming any field missing from it, so a new struct field still goes red. The `stream_synthesize*` test covers both speech façades; `speech_request/2`'s existing sentinel test still covers the shared allow-list.
- `[tactical]` **`ALLM.Telemetry.span/3`'s `@doc` list of valid names** was stale since the non-streaming audio spans (it ended at `:moderate`); it now lists all twelve.
- `[scope]` **Equivalence property notes.** (a) `language` is compared as the design requires but binds nothing: neither Fake reports a language (mutating `collect_transcription/1` to drop it left the property green); the collector's own test pins it, and the property moduledoc says so. (b) The transcription generator's PCM length is bounded to ≤ 1,000 bytes because `FakeTranscription.max_audio_bytes/0` (1,024) gates the non-streaming path. (c) Mutation: dropping `sample_rate` in `collect_speech/1` fails the speech property.

### Verification (run 2026-09-26, working tree on `762a66e`)

| Check | Result |
|-------|--------|
| `mix test` | exit 0, 573 doctests, 33 properties, 4400 tests, 0 failures, 14 excluded (26.3: 559 / 31 / 4324) |
| `mix test --seed 0` | exit 0, same counts |
| `mix format --check-formatted` | exit 0 |
| `mix credo --strict` | no issues |
| `mix dialyzer` | `Total errors: 0` |
| `mix compile --warnings-as-errors --force` | exit 0 |
| `mix docs 2>&1 \| grep -iE 'warning\|error'` | empty |
| `mix run scripts/audit_user_docs.exs <file>` on new `lib/allm/audio_stream.ex`, `lib/allm/audio_stream/chat_stream_error.ex`, and modified `lib/allm.ex`, `lib/allm/telemetry.ex`, `lib/allm/speech_request.ex` | "No banned-token matches" each |
| async grep `grep -rl 'Keys.put(\|Logger.configure(\|System.put_env(\|:telemetry.attach' test/ \| xargs grep -L 'async: false' \| wc -l` | 12, unchanged; the four new test files use `ALLM.Test.TelemetryCapture` only |
| Pump-protocol guard `grep -lE --exclude=input_pump.ex ':input_error\|crash_info\(\|@input_window' lib/allm/providers/*.ex lib/allm/providers/*/*.ex lib/allm.ex lib/allm/audio_stream.ex` | exit 1 (empty); the façade layer consumes no pump messages |
| Equivalence property | 2 properties × 100 runs each, green on three consecutive runs |
| Targeted files | `allm_stream_synthesize_test.exs` 3 doctests + 33 tests; `allm_stream_transcribe_test.exs` 1 doctest + 24 tests; `audio_stream_test.exs` 4 doctests + 12 tests |
| Coverage (`mix test --cover`) | `ALLM.AudioStream` 97.67%, `ChatStreamError` 75.00% (the non-map `reason_of/1` and non-exception `detail_of/1` fallbacks), total 94.99% |
| `conformance/` | not touched, so its gates were not run |
| `README.md` | not modified |

### Fix pass (2026-09-26)

Sources: `.work/reviews/2026-09-26-phase-26-4/overview.md`, `.work/code-reviews/2026-09-26-phase-26-4.md`, `.work/security-reviews/2026-09-26-phase-26-4.md` (clean), `.work/design-reviews/2026-09-26-phase-26-4.md` (N/A).

- **Code-review F1 (Medium) fixed.** The three `do_stream_*` bodies now build a spec map and call one private runner, `run_audio_stream/3` (`lib/allm.ex`). The runner owns `started_at`, `request_id`, the span, gate 2 (`check_stream_slot/4`), the façade's remaining gates in order (`run_stream_gates/1`, a list of zero-arity funs), `build_capability_dispatch_opts/3`, the ctx map (a map literal: the positional `stream_ctx/6` is gone), `handle_audio_stream_dispatch/2`, and the `{result, %{response: nil}}` return. Each façade supplies the span name, slot adapter, callback name/arity, resolved model, extra start metadata, gates, forwarded opts, and a `dispatch` fun. The refactor is behaviour-preserving and private. **Mutation:** swapping `stream_transcribe/3`'s two gates fails "gate order the input-shape gate wins over an invalid request" (1 failure). Restored green.
- **Functional-review Low 2 fixed (false-sentence carve-out, per the orchestrator's ruling).** The input-failure `:cause` map is `%{kind: atom, message: String.t()}` (`InputPump`'s `@type input_error`). `lib/allm/audio_stream.ex` called it "a map of two strings", and six 26.3/26.4 sites called it "string-only". Reworded in `audio_stream.ex`, `audio_stream/chat_stream_error.ex`, `speech_stream_adapter.ex`, `transcription_stream_adapter.ex`, `providers/fake_speech.ex`, `providers/fake_transcription.ex` and `providers/support/input_pump.ex` (moduledoc, `@typedoc`, `crash_info/1` doc). `grep -rn "string-only\|two strings" lib/` → exit 1. The design's Decision #7 carries a dated `> CORRECTED` line. The later "string-only" mentions in the design (lines 395, 455, 570, 957, 1172, 1212) are covered by that line and were not edited.
- **Code-review F4 / functional-review Low 3 (a wrong-typed `opts[:request]` raises a bare `CaseClauseError`) was not fixed here.** Both lanes reached it independently. The ruling is that this is not a gate-logic carve-out. The case refuses the bad value loudly, as `FunctionClauseError` does for `stream_synthesize(engine, nil)`. It is the façade's ordinary input handling, not the accept/refuse path of a check that later work is measured against. It stays a Low for the phase-end polish pass.
- **Functional-review Low 1 (`FakeSpeech` batch `{:ok, ""}` returns an empty clip where the stream returns `:empty_input`) was filed, not fixed.** It is outside 26.4's fence (pre-26.4 Fake code) and is filed as a `.work/ASKS.md` `[BUG]` (sat 9/26 9pm) with a self-scoring predicate. Measured today: `MIX_ENV=test mix run -e 'IO.inspect(ALLM.synthesize(ALLM.Engine.new(speech_adapter: ALLM.Providers.FakeSpeech, adapter_opts: [speech_script: [{:ok, ""}]]), "x") |> elem(0))'` → `:ok`. It is done when that prints `:error`.
- Code-review F2, F3 and F5 are Lows and were left for the polish pass. After F1, F2 (an `error:` key on the stream spans' `:stop`) is a one-line change in `run_audio_stream/3`.

### Notes for later sub-phases (26.4)

- **26.5–26.8 and any later streaming capability:** the streaming façades share `run_audio_stream/3`. A change to span shape, gate plumbing or dispatch wrapping goes there once. Do not reintroduce a per-façade copy of the skeleton.

### Fix-pass verification (2026-09-26, working tree on `762a66e`)

| Check | Result |
|-------|--------|
| `mix test` | exit 0, 573 doctests, 33 properties, 4400 tests, 0 failures, 14 excluded |
| `mix test --seed 0` | exit 0, same counts |
| `mix format --check-formatted` | exit 0 |
| `mix credo --strict` | no issues |
| `mix dialyzer` | `Total errors: 0` |
| `mix docs 2>&1 \| grep -iE 'warning\|error'` | empty |
| `mix run scripts/audit_user_docs.exs` on the 8 lib files touched | "No banned-token matches" each |
| async grep `… \| xargs grep -L 'async: false' \| wc -l` | 12, unchanged |


## Phase 26.5 — `OpenAI.Speech` HTTP streaming + recorder arms

Built 2026-09-26 on `a44ac31`. The working tree is uncommitted; the orchestrator commits after review.

### Checklist (26.5.3)

- [x] `ALLM.Providers.OpenAI.Speech.stream_synthesize/2` (`@behaviour ALLM.SpeechStreamAdapter`): `Stream.resource/3` over `finch_module.async_request/3` on `ALLM.Finch`, `Transport.finch_opts/2`, `@default_stream_timeout 60_000` stated in the `@doc`. The pre-flight gates are the one shared `run_gates/2` (shape, length, and the new sample-rate gate).
- [x] Buffered-error-body classification: a status outside 2xx collects `{:data, _}` until `:done`, then calls `to_speech_adapter_error/4`, so the redactor and the `string_too_long` rule see the message.
- [x] `test/support/finch_stub.ex`: `:initial_headers` and `:error_body` install options, in both modes. Recorder arms, and the stream-fixture replay test.
- [x] Non-streaming `synthesize/2` / `prepare_request/2` share the sample-rate gate, and `decode_response/4` reports `sample_rate: 24_000` for `:pcm` and `:wav`, `nil` otherwise. `openai/speech_test.exs` gains the gate and reporting rows (a released-behaviour change, as the checklist says).
- [x] Devil-review rows: the after function cancels, then drains `{ref, _}` in a `receive … after 0` loop (test "a halt drains the request's queued messages from the mailbox"); 24,000 is accepted for both `:pcm` and `:wav` (a row each, in both test files); `synthesize/2` shares the gate.

### Live probe (run 2026-09-26, `( set -a; . ./.env; set +a; mix run scripts/record_openai_audio_fixtures.exs )`)

First run: 4 live calls, exit 0, every arm matched, then 4 files written. Second run: `0 live calls: every target is already recorded`, exit 0.

| Arm | Got | Observation |
|-----|-----|-------------|
| `stream_control` (tts-1, `not_a_real_field`) | 200 | `audio/mpeg`, 7,680 bytes: the unknown field is ignored on the streaming path too |
| `stream_chunked` (gpt-4o-mini-tts, 405 chars, pcm) | 200 | `audio/pcm`, `transfer-encoding: chunked`, 1,600,800 bytes in 90 data messages; first byte 1,728 ms, last 6,735 ms |
| `stream_mp3_tts1` (tts-1, mp3) | 200 | `audio/mpeg`, chunked, 402,048 bytes in 278 data messages; 1,353 ms to 2,137 ms |
| `stream_401` | 401 | `text/plain` JSON, `invalid_api_key`, masked key echo (`sk-proj-****…9900`) |

Alternative E2 (raw chunked body) is confirmed and the wire map's Framing row carries a dated correction in the design. The cost is 820 characters, under $0.02 at the Phase 25 RECORDS prices ($15.00 / 1M characters for tts-1; gpt-4o-mini-tts audio at $12.00 / 1M tokens). An exploratory call from a scratchpad script (one 405-character pcm clip) preceded the recorder run, to see the header set before choosing the assertions.

### Deviations

- `[scope]` **A fourth arm, `stream_control`, writes `probe_stream_control.json`.** The design lists three arms. CLAUDE.md's probe rule pairs each run with an invented-field control, and the existing speech control (`probe_control.json`) was already recorded, so the overwrite guard would never re-run it in the same run as the stream arms.
- `[scope]` **`stream_chunked` also asserts `transfer-encoding: chunked`.** A chunk count alone is weak evidence of streaming: TCP splits any large body into many reads. The note prints first-byte and last-byte times, and the chunked header is a response observable that pins the framing.
- `[tactical]` **Recorder transport is `Finch.stream/5` on `ALLM.Finch`,** the adapter's own pool, not `Req`. The response is wrapped in a `%Req.Response{}` (timings in `private.chunks`) so the existing verdicts and writers apply unchanged.
- `[scope]` **`stream_pcm.json` is 2.1 MB** (1.6 MB of pcm, base64). It follows the Phase 25 envelope literally (`body_base64` plus `chunks`), so the replay test can split the real body at the recorded sizes. Precedent: the four `test/fixtures/openai/images/recorded/*_happy.json` files are 1.0–2.1 MB.
- `[structural]` **`test/allm/providers/openai/speech_wire_test.exs` is modified, and it is not in the Module Tree.** Its "`@recorded` enumerates every file under recorded/" gate is fail-closed and goes red on any new `recorded/` file. `@recorded` gains the four names, which also gives each the raw-bytes `refute Map.has_key?(raw, "_comment")` provenance test. The envelope-integrity test gains the two stream audio envelopes.
- ~~`[tactical]` **Transport opts are hoisted from `adapter_opts`.** The streaming façade (`run_audio_stream/3`) puts engine `adapter_opts` under `opts[:adapter_opts]` and, unlike the chat runner, does not hoist `Adapter.transport_opts/0`. `stream_synthesize/2` reads each transport key from the top level, then from `adapter_opts` (`Keyword.put_new/3`). This is adapter-local; the façade is not touched.~~ **Superseded in the 26.5 fix pass** (code-review F1): the adapter-local copy was the *second* copy of `StreamRunner`'s hoist, not the first. The one body is now `ALLM.Adapter.hoist_transport_opts/2` (`@doc false` + `@spec`), called by `ALLM.StreamRunner` and once by `run_audio_stream/3` in `lib/allm.ex`; `OpenAI.Speech` reads transport opts from the top level only, as the chat adapters do.
- `[tactical]` **A 200 with zero audio bytes ends `:invalid_request`, `metadata.cause: :empty_input`**, per the `SpeechEvent` grammar, not `:malformed_response` as `decode_response/4` reports an empty body on the non-streaming path.
- `[tactical]` **Two flags in the stream state:** `transport_done?` (Finch sent `:done` or `{:error, _}`) and `terminal?` (the stream emitted its terminal). Only a transport that is not done is cancelled, so the bad-content-type and timeout terminals still cancel. A second 2xx `{:headers, _}` (HTTP trailers) does not emit a second `:speech_started`.
- `[tactical]` **The halt-drain test uses a test-local `BurstFinch`,** which queues every frame synchronously inside `async_request/3`. `FinchStub` sends from a spawned process, so with it the queued-at-halt precondition is a race and the `refute_received` could pass vacuously.
- `[scope]` The fixture helper is `OpenAITestFixtures.speech_stream_chunks/1`: the name `stream_chunks/1` is already taken by the SSE chat loader in the same module.
- `[scope]` `openai/speech_stream_conformance_test.exs` passes a raising `:finch_module` as `gate_opts: [finch_module: _]`, so case 4 fails if the gate moves into the stream. *(Fix pass, code-review F5: the two test-local copies became `ALLM.Test.RaisingFinch` in `test/support/raising_finch.ex`.)*
- `[CARRY]` **Safer than the released chat stream adapters on two axes** (code-review F2). (a) Body-aware error classification: the chat adapters classify a streamed non-2xx from the status alone, dropping the provider message and `retry-after` (`lib/allm/providers/openai.ex:839`, `lib/allm/providers/anthropic.ex:1485`, `lib/allm/providers/gemini.ex:1355`). (b) Mailbox drain: their `stream_after_fun/2` only cancels (`lib/allm/providers/openai.ex:1352-1355`, `lib/allm/providers/anthropic.ex:1857-1860`, `lib/allm/providers/gemini.ex:1692-1695`). Released behaviour, outside 26.5's fence; filed in `.work/ASKS.md` (sat 9/26/2026 9pm `[CARRY]`) with its DONE-WHEN predicate.

### Mutation checks

| Mutant (in `lib/allm/providers/openai/speech.ex`) | Failing tests |
|--------|---------------|
| after function does not drain | 1 (the halt-drain test) |
| sample-rate gate accepts 24,000 only for `:pcm` | 2 (the `:wav` row in `speech_test.exs` and in `speech_stream_test.exs`) |
| error status classified from `%{}` instead of the buffered body | 3 (planted-token 401, `string_too_long` 400, recorded 401 replay) |
| after function does not cancel | 4 (malformed content type, timeout, `Enum.take/2`, halt-drain) |
| `decode_response/4` reports `sample_rate: nil` | 1 |

The file was restored and `cmp`-verified against a saved copy after each run.

### Notes for later sub-phases

- **26.6–26.8:** `FinchStub.install/2` now takes `:initial_headers` (default `[]`) and `:error_body` (a binary or list; status, headers, body parts, `:done`; `chunks` not sent). The ElevenLabs HTTP stream tests can use both. *(Corrected in the 26.5 fix pass. This bullet said the audio façade does not hoist transport opts and that a second streaming HTTP adapter would be the second copy of the hoist. `OpenAI.Speech`'s private hoist was already the second copy, after `ALLM.StreamRunner`'s.)* Since the fix pass: `run_audio_stream/3` hoists `adapter_opts` transport keys once via `ALLM.Adapter.hoist_transport_opts/2`, so a streaming adapter reads them from the top level and never hoists. A Finch-backed stream's after function is `ALLM.Providers.Support.Transport.cancel_and_drain(finch_module, ref, transport_done?)` (cancel unless the transport finished, then drain `{ref, _}`). Keyless gate tests use `ALLM.Test.RaisingFinch`.

### Verification (run 2026-09-26, working tree on `a44ac31`)

| Check | Result |
|-------|--------|
| `mix test` | exit 0, 575 doctests, 33 properties, 4448 tests, 0 failures, 14 excluded (26.4: 573 / 33 / 4400) |
| `mix test --seed 0` | exit 0, same counts |
| `mix format --check-formatted` | exit 0 |
| `mix credo --strict` | no issues |
| `mix dialyzer` | `Total errors: 0` |
| `mix compile --warnings-as-errors --force` (dev and test) | exit 0 |
| `mix docs 2>&1 \| grep -iE 'warning\|error'` | empty |
| `mix run scripts/audit_user_docs.exs lib/allm/providers/openai/speech.ex` (no new `lib/` file) | "No banned-token matches" |
| async grep `grep -rl 'Keys.put(\|Logger.configure(\|System.put_env(\|:telemetry.attach' test/ \| xargs grep -L 'async: false' \| wc -l` | 12, unchanged; the two new test files use none of the four calls |
| Pump-protocol guard `grep -lE --exclude=input_pump.ex ':input_error\|crash_info\(\|@input_window' lib/allm/providers/*.ex lib/allm/providers/*/*.ex` | exit 1 (empty) |
| Targeted | `speech_stream_test.exs` 28 tests; `speech_stream_conformance_test.exs` 6 suite cases + 1; `speech_test.exs` +9 tests; `speech_wire_test.exs` +4 provenance rows |
| Coverage (`mix test --cover test/allm/providers/openai/`) | `ALLM.Providers.OpenAI.Speech` 97.48% |
| BLOCKING recorder | exit 0, `stream_chunked` matched; second run `0 live calls` |
| `conformance/` | not touched, so its gates were not run |
| `README.md` | not modified |

### Fix pass (2026-09-26)

From `.work/code-reviews/2026-09-26-phase-26-5.md` (the functional, security and design reviews had no findings). F1 and F3 were tagged DEFER→HANDOFF for 26.6 and were fixed now instead, because 26.6/26.7 build on this plumbing.

- `[structural, fix pass]` **F1:** `ALLM.Adapter.hoist_transport_opts/2` (`@doc false` + `@spec`) is the one hoist body. `ALLM.StreamRunner`'s private copy and `OpenAI.Speech`'s private copy are deleted, and `run_audio_stream/3` in `lib/allm.ex` hoists once on its dispatch opts. `lib/allm/adapter.ex` and `lib/allm/stream_runner.ex` are outside the 26.5 Module Tree; the StreamRunner change moves its private body verbatim (behaviour-preserving, pinned by `test/allm/transport_opts_routing_test.exs:109` and `:125`). The speech test "transport opts arriving in adapter_opts are read" now drives `ALLM.stream_synthesize/3` with engine `adapter_opts`, since a direct adapter call no longer hoists (the chat adapters never did).
- `[structural, fix pass]` **F3:** `ALLM.Providers.Support.Transport.cancel_and_drain/3` (`@doc false` + `@spec`) is the Finch after function: cancel unless `transport_done?` (rescuing a raising cancel), then drain `{ref, _}` with `receive … after 0`. `OpenAI.Speech.stream_after/1` calls it. The three chat adapters are not migrated (the F2 `[CARRY]` above).
- `[tactical, fix pass]` **F4:** `stream_request_id/2` is renamed `request_id_for/2`, and `decode_response/4` calls it instead of spelling the fallback inline.
- **F5:** `ALLM.Test.RaisingFinch` in `test/support/raising_finch.ex`, aliased from both speech stream test files.
- **F2:** `[CARRY]` line in Deviations above, and the `.work/ASKS.md` ticket.

Mutation re-check after the extraction (each file restored and `cmp`-verified):

| Mutant | Failing tests |
|--------|---------------|
| `Transport.cancel_and_drain/3` drains nothing (`{^ref, :never}`) | 1 (the halt-drain test) |
| `Transport.cancel_and_drain/3` never cancels | 4 (malformed content type, timeout, `Enum.take/2`, halt-drain) |
| `run_audio_stream/3` hoists from `[]` | 1 (the façade `adapter_opts` transport test) |

| Check (after the fix pass) | Result |
|-------|--------|
| `mix test` | exit 0, 575 doctests, 33 properties, 4448 tests, 0 failures, 14 excluded |
| `mix test --seed 0` | exit 0, same counts |
| `mix format --check-formatted` | exit 0 |
| `mix credo --strict` | no issues |
| `mix dialyzer` | `Total errors: 0` |
| `mix compile --warnings-as-errors --force` (dev and test) | exit 0 |
| `mix docs 2>&1 \| grep -iE 'warning\|error'` | empty |
| `mix run scripts/audit_user_docs.exs lib/allm/providers/openai/speech.ex lib/allm/providers/support/transport.ex lib/allm/adapter.ex` | "No banned-token matches" |
| Pump-protocol guard `grep -lE --exclude=input_pump.ex ':input_error\|crash_info\(\|@input_window' lib/allm/providers/*.ex lib/allm/providers/*/*.ex` | exit 1 (empty) |
| async grep (as above) | 12, unchanged |
| Live recorder | not re-run (no live calls needed) |
