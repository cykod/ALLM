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
| 26.6 | Completed (fix pass re-reviewed: `.work/code-reviews/2026-09-26-phase-26-6-fix.md`) |
| 26.7 | Completed — fix pass re-reviewed (`.work/code-reviews/2026-09-26-phase-26-7-fix.md`, 7 Lows: F4/F5 carried to 26.8 via HANDOFF, rest to polish); owner decision 2026-09-27: word-buffer + `auto_mode` |
| 26.8 | Completed — fix-pass edits (owner decision "hold when requested": `elevenlabs/transcription.ex` language hold + `support/web_socket/input_loop.ex` `wake_at`; test repairs) landed after the review checkpoint and are **unreviewed by a review lane**; pinned by the 7-mutant table and a live 3.8 s confirmation in §26.8 "Owner decision (2026-09-27)" |
| 26.9 | Completed |
| 26.10 | Completed |

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


## Phase 26.6 — ElevenLabs non-streaming adapters

Built 2026-09-26 on `eab71aa`. The working tree is uncommitted; the orchestrator commits after review.

### Checklist (26.6.3)

- [x] `lib/allm/providers/support/elevenlabs.ex` (`ALLM.Providers.Support.ElevenLabs`): `base_url/1`, `headers/1`, `output_format/2` (public, doctested), `classify/2`, `error_fields/4`, `redact_key_material/1`. Both adapters use `Support.HTTPResponse`. `ElevenLabs.Transcription` declares `@behaviour ALLM.Providers.Support.TranscriptionAdapter` with the five `@impl` callbacks and uses it for its gates, Fake hand-off and single attempt; the 26.1 transcription predicate prints nothing with three `*/transcription.ex` files.
- [x] `ALLM.Providers.ElevenLabs.Speech` and `.Transcription`: script hand-off, keyless gates, injected-default `@doc`s (voice, `model_id`, `output_format` + per-format rate, the 60 s / 120 s receive timeouts) in the public `@doc` and the builders' `@doc false` (`url/2`, `to_json_body/2`, `to_multipart_body/2`); `Speech.synthesize/2`'s adapter-level `Retry.run/3` and its `@doc` "Retry" paragraph.
- [x] `scripts/record_elevenlabs_audio_fixtures.exs`, 14 recorded + 11 synthesized fixtures, `test/support/elevenlabs_fixtures.ex`, `test/fixtures/elevenlabs/README.md`. The settled wire-map rows carry a dated `> CORRECTED 2026-09-26 (26.6 probe)` blockquote in the design (under the HTTP wire map, under the Error classification table, and under Decision #10's voice sentence).
- [x] `groups_for_modules`: `ElevenLabs.Speech`, `ElevenLabs.Transcription` and `Support.ElevenLabs` under `Providers`.

### Live probe (run 2026-09-26, `( set -a; . ./.env; set +a; mix run scripts/record_elevenlabs_audio_fixtures.exs )`)

Exploratory calls first, from a scratchpad script (not committed): `GET /v1/user/subscription` and `GET /v1/voices/JBFqnCBsd6RMkjVDRZzb` → **401** `{"detail": {"type": "authentication_error", "code": "unauthorized", "status": "missing_permissions", …}}` (the key lacks `user_read` / `voices_read`); one "Hi." TTS call for the full header set; then one call per format, the control, a bad voice, a body without text, a bad key, `pcm_44100` and `mp3_44100_192` (both 403 `subscription_required`), and three STT calls (fox mp3, as `audio.bin`, with an invented field).

Recorder run 1: exit 1, nothing written. Every arm matched except `too_long`: `eleven_v3` with 5,001 characters answered **200** (audio, billed), not the designed 400 `text_too_long`. The arm was removed (see Deviations). Run 2: 14 live calls, exit 0, every arm matched, 14 files written. Run 3: `0 live calls: every target is already recorded`, exit 0.

| Arm | Got | Observation |
|-----|-----|-------------|
| `control` (TTS, `not_a_real_field`) | 200 | unknown body fields are ignored |
| `tts_default` (default voice, `eleven_flash_v2_5`; 2026-09-26 run sent **no** `output_format`, re-recorded 2026-09-27 with the adapter's own `output_format=mp3_44100_128`) | 200 | `audio/mpeg`, 13,000 bytes; headers include `request-id`, `character-cost: 3`, `history-item-id`, `tts-latency-ms`, `x-trace-id` |
| `tts_mp3` (`mp3_24000_48`) / `tts_pcm` (`pcm_24000`) / `tts_wav` (`wav_24000`) / `tts_opus` (`opus_48000_64`) | 200 each | `audio/mpeg`, `audio/pcm`, `audio/wav`, `audio/opus`: all map through `mime_to_format/1` |
| `tier_gate` (`pcm_44100`, new) | 403 | `code: subscription_required`, `status: output_format_not_allowed`, "only available on the Pro tier and above" |
| `bad_key` (`sk_` + 48 **hex-shaped** characters) | **400** | `type: authentication_error`, `code`/`status: invalid_api_key`, `param: api_key`; no key echo. ~~An invalid key is answered with a 400.~~ CORRECTED 2026-09-27: only a hex-shaped key gets the 400; see `bad_key_401` |
| `bad_key_401` (`sk_` + 48 mixed-case characters; added 2026-09-27) | **401** | `type: authentication_error`, `code: unauthorized`, `status: invalid_api_key`, message "Invalid API key"; no key echo; `speech/recorded/error_401_bad_key.json` |
| `bad_voice` | 404 | `code`/`status: voice_not_found` |
| `error_422` (no `text`) | 422 | `detail` is a list: `[{"type": "missing", "loc": ["body", "text"], "msg": "Field required", "input": null}]` |
| `stt_control` (invented multipart field, new) | 200 | unknown fields are ignored |
| `stt_default` (`scribe_v2`, fox mp3) | 200 | "The quick brown fox jumps over the lazy dog.", `language_code: "eng"`, `audio_duration_secs: 3.72`; headers have `character-cost` but **no `request-id`** |
| `stt_audio_bin` (mp3 as `audio.bin`, `application/octet-stream`) | 200 | content is sniffed. Narrowed 2026-09-27 to expect exactly 200 with a "fox" transcript, and re-recorded as a body envelope |
| `stt_bad_key` (new) | 400 | same envelope as the TTS bad key |

Cost: the billed arms total about 40 TTS characters and 3 × 3.7 s of STT per run, plus the one accidental 5,001-character `eleven_v3` synthesis (≈ $0.50 at the design's $0.10 / 1K characters).

### Deviations

- `[scope, probe]` **The `too_long` arm is falsified and removed.** `eleven_v3` at 5,001 characters returned 200 and was billed. A longer probe risks a much larger bill if it is also accepted, so no input-length arm runs; the recorder's header comment says why. The `text_too_long` → `:context_length_exceeded` row stays documented only and is pinned by `synthesized/error_400_too_long.json`. The design's Input-limit row carries the correction.
- `[structural, probe]` **Error classification widened by the probe** (design CORRECTED under the Error classification table). (a) A body with `detail.type == "authentication_error"` → `:authentication_failed` whatever the status, because an invalid key is a 400; without it the recorded bad-key error classifies as `:invalid_request` (mutation M1 below). (b) The 403 → `:unsupported_feature` row also matches `subscription_required` / `output_format_not_allowed`, the observed tier gate. (c) The quota row also matches `payment_required`.
- `[scope]` **Arms beyond the design's table:** `tier_gate` (the Format table's tier-gate claim), `error_422` (named in the design's Error-envelope row but missing from the 26.6.2 table), `stt_control` (CLAUDE.md pairs every acceptance arm with a control; the design had one for TTS only) and `stt_bad_key` (a recorded STT error for the transcription wire test). `default_voice` and `tts_default` are one arm, as the design's table row groups them.
- `[scope, probe]` **No STT filename gate.** `stt_audio_bin` → 200, so the OpenAI-style gate is not copied; a non-file source with an unknown mime is uploaded as `audio.bin` (the probed name).
- `[tactical]` **Format and mime come from the response** (§37 Decision #4); the content-type outcome rule's fallback did not fire. `sample_rate` comes from the requested `output_format`, since the response does not state it.
- `[tactical]` **Correlation.** TTS: `request-id` → `response.id`, `character-cost` → `raw: %{"character_cost" => n}`. STT: `transcription_id` → `id` (no `request-id` header exists). On both, `request_id` is `opts[:request_id]` only; there is no header fallback, because the provider id already lives on `:id`.
- `[tactical]` `TranscriptionResponse.language` is ElevenLabs' ISO 639-3 `language_code` (`"eng"`), passed through unmapped.
- `[tactical]` Error metadata keys are `status`, `code`, `type` and `provider_status` (`detail.status`), all provider strings redacted. The design named `metadata.code` only.
- `[tactical]` `Support.ElevenLabs.base_url/1` reads `opts[:base_url]`, then `opts[:adapter_opts][:base_url]` (so an engine can pin a residency host), then the global host.
- `[tactical]` `Support.ElevenLabs.error_fields/4` returns `{reason, fields}` for either error module's `new/2`, so the two adapters' error funnels are one line each rather than two copies of the field assembly.
- `[structural, documented]` **Promotion on the two-implementations trigger:** `ALLM.Providers.Support.TranscriptionAdapter.optional_field/2` and `option_fields/2` (`@doc false` + `@spec`). `ElevenLabs.Transcription` would otherwise have been a second copy of `OpenAI.Transcription`'s private `optional_field/2`, `option_fields/1` and `form_values/2`. `lib/allm/providers/openai/transcription.ex` is outside the 26.6 Module Tree; the migration is private and behaviour-preserving (it still logs only a dropped `response_format`), pinned by the existing OpenAI tests. Mutation: renaming string fields inside the shared `form_values/2` fails one OpenAI and one ElevenLabs test. Three new tests in `test/allm/providers/support/transcription_adapter_test.exs`.
- `[scope]` **`test/allm/providers/support/elevenlabs_test.exs`** is not in the Module Tree. The Test Plan put the `output_format/2` and `classify/2` rows under `speech_test.exs`; they test `Support.ElevenLabs`, so they live in that module's own test file (agent-spec/IMPLEMENTATION.md: one test file per `lib/` file), with its doctest.
- `[tactical]` `test/support/elevenlabs_fixtures.ex` delegates to `ALLM.Providers.OpenAITestFixtures.drop_comment/1` and `envelope_bytes/1` rather than adding a third copy of either.
- ~~`[DEFERRED-DRY]` `ElevenLabs.Speech` clones nine of `OpenAI.Speech`'s speech-contract helpers (provider atom and message text differ). No `Support.SpeechAdapter` row exists in 26.6's Module Tree; filed in `.work/ASKS.md` (sat 9/26/2026 10pm) with its predicate. Measured today: 9 lines.~~ Closed by the fix pass (below): `Support.SpeechAdapter` extracted. The nine-name count was also low; code review F2 found renamed and unlisted clones.
- `[scope]` The 26.1 HTTP-variants predicate (`grep -roE 'defp (provider_message|redact_optional|sanitize_cause)\(' lib/allm/providers/ | sort -u | cut -d: -f2 | sort | uniq -c | awk '$1>1'`) now prints `redact_optional` **4** (was 3): `Support.ElevenLabs`'s copy calls the ElevenLabs redactor, the per-provider variant the 26.1 disposition keeps.

### Owner decision needed

- ~~**`ElevenLabs.Transcription.max_audio_bytes/0` is 4,999,999,999** … Options: keep it; lower the cap …; or give the conformance harness a way to size case 4 differently.~~ **Decided 2026-09-27; see "Fix pass" below.** The owner said: "Let's remove the and make a note". Read as: drop case 4 from the ElevenLabs mount only.

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


## Phase 26.6 — ElevenLabs non-streaming adapters

Built 2026-09-26 on `eab71aa`. The working tree is uncommitted; the orchestrator commits after review.

### Checklist (26.6.3)

- [x] `lib/allm/providers/support/elevenlabs.ex` (`ALLM.Providers.Support.ElevenLabs`): `base_url/1`, `headers/1`, `output_format/2` (public, doctested), `classify/2`, `error_fields/4`, `redact_key_material/1`. Both adapters use `Support.HTTPResponse`. `ElevenLabs.Transcription` declares `@behaviour ALLM.Providers.Support.TranscriptionAdapter` with the five `@impl` callbacks and uses it for its gates, Fake hand-off and single attempt; the 26.1 transcription predicate prints nothing with three `*/transcription.ex` files.
- [x] `ALLM.Providers.ElevenLabs.Speech` and `.Transcription`: script hand-off, keyless gates, injected-default `@doc`s (voice, `model_id`, `output_format` + per-format rate, the 60 s / 120 s receive timeouts) in the public `@doc` and the builders' `@doc false` (`url/2`, `to_json_body/2`, `to_multipart_body/2`); `Speech.synthesize/2`'s adapter-level `Retry.run/3` and its `@doc` "Retry" paragraph.
- [x] `scripts/record_elevenlabs_audio_fixtures.exs`, 14 recorded + 11 synthesized fixtures, `test/support/elevenlabs_fixtures.ex`, `test/fixtures/elevenlabs/README.md`. The settled wire-map rows carry a dated `> CORRECTED 2026-09-26 (26.6 probe)` blockquote in the design (under the HTTP wire map, under the Error classification table, and under Decision #10's voice sentence).
- [x] `groups_for_modules`: `ElevenLabs.Speech`, `ElevenLabs.Transcription` and `Support.ElevenLabs` under `Providers`.

### Live probe (run 2026-09-26, `( set -a; . ./.env; set +a; mix run scripts/record_elevenlabs_audio_fixtures.exs )`)

Exploratory calls first, from a scratchpad script (not committed): `GET /v1/user/subscription` and `GET /v1/voices/JBFqnCBsd6RMkjVDRZzb` → **401** `{"detail": {"type": "authentication_error", "code": "unauthorized", "status": "missing_permissions", …}}` (the key lacks `user_read` / `voices_read`); one "Hi." TTS call for the full header set; then one call per format, the control, a bad voice, a body without text, a bad key, `pcm_44100` and `mp3_44100_192` (both 403 `subscription_required`), and three STT calls (fox mp3, as `audio.bin`, with an invented field).

Recorder run 1: exit 1, nothing written. Every arm matched except `too_long`: `eleven_v3` with 5,001 characters answered **200** (audio, billed), not the designed 400 `text_too_long`. The arm was removed (see Deviations). Run 2: 14 live calls, exit 0, every arm matched, 14 files written. Run 3: `0 live calls: every target is already recorded`, exit 0.

| Arm | Got | Observation |
|-----|-----|-------------|
| `control` (TTS, `not_a_real_field`) | 200 | unknown body fields are ignored |
| `tts_default` (default voice, `eleven_flash_v2_5`; 2026-09-26 run sent **no** `output_format`, re-recorded 2026-09-27 with the adapter's own `output_format=mp3_44100_128`) | 200 | `audio/mpeg`, 13,000 bytes; headers include `request-id`, `character-cost: 3`, `history-item-id`, `tts-latency-ms`, `x-trace-id` |
| `tts_mp3` (`mp3_24000_48`) / `tts_pcm` (`pcm_24000`) / `tts_wav` (`wav_24000`) / `tts_opus` (`opus_48000_64`) | 200 each | `audio/mpeg`, `audio/pcm`, `audio/wav`, `audio/opus`: all map through `mime_to_format/1` |
| `tier_gate` (`pcm_44100`, new) | 403 | `code: subscription_required`, `status: output_format_not_allowed`, "only available on the Pro tier and above" |
| `bad_key` (`sk_` + 48 **hex-shaped** characters) | **400** | `type: authentication_error`, `code`/`status: invalid_api_key`, `param: api_key`; no key echo. ~~An invalid key is answered with a 400.~~ CORRECTED 2026-09-27: only a hex-shaped key gets the 400; see `bad_key_401` |
| `bad_key_401` (`sk_` + 48 mixed-case characters; added 2026-09-27) | **401** | `type: authentication_error`, `code: unauthorized`, `status: invalid_api_key`, message "Invalid API key"; no key echo; `speech/recorded/error_401_bad_key.json` |
| `bad_voice` | 404 | `code`/`status: voice_not_found` |
| `error_422` (no `text`) | 422 | `detail` is a list: `[{"type": "missing", "loc": ["body", "text"], "msg": "Field required", "input": null}]` |
| `stt_control` (invented multipart field, new) | 200 | unknown fields are ignored |
| `stt_default` (`scribe_v2`, fox mp3) | 200 | "The quick brown fox jumps over the lazy dog.", `language_code: "eng"`, `audio_duration_secs: 3.72`; headers have `character-cost` but **no `request-id`** |
| `stt_audio_bin` (mp3 as `audio.bin`, `application/octet-stream`) | 200 | content is sniffed. Narrowed 2026-09-27 to expect exactly 200 with a "fox" transcript, and re-recorded as a body envelope |
| `stt_bad_key` (new) | 400 | same envelope as the TTS bad key |

Cost: the billed arms total about 40 TTS characters and 3 × 3.7 s of STT per run, plus the one accidental 5,001-character `eleven_v3` synthesis (≈ $0.50 at the design's $0.10 / 1K characters).

### Deviations

- `[scope, probe]` **The `too_long` arm is falsified and removed.** `eleven_v3` at 5,001 characters returned 200 and was billed. A longer probe risks a much larger bill if it is also accepted, so no input-length arm runs; the recorder's header comment says why. The `text_too_long` → `:context_length_exceeded` row stays documented only and is pinned by `synthesized/error_400_too_long.json`. The design's Input-limit row carries the correction.
- `[structural, probe]` **Error classification widened by the probe** (design CORRECTED under the Error classification table). (a) A body with `detail.type == "authentication_error"` → `:authentication_failed` whatever the status, because an invalid key is a 400; without it the recorded bad-key error classifies as `:invalid_request` (mutation M1 below). (b) The 403 → `:unsupported_feature` row also matches `subscription_required` / `output_format_not_allowed`, the observed tier gate. (c) The quota row also matches `payment_required`.
- `[scope]` **Arms beyond the design's table:** `tier_gate` (the Format table's tier-gate claim), `error_422` (named in the design's Error-envelope row but missing from the 26.6.2 table), `stt_control` (CLAUDE.md pairs every acceptance arm with a control; the design had one for TTS only) and `stt_bad_key` (a recorded STT error for the transcription wire test). `default_voice` and `tts_default` are one arm, as the design's table row groups them.
- `[scope, probe]` **No STT filename gate.** `stt_audio_bin` → 200, so the OpenAI-style gate is not copied; a non-file source with an unknown mime is uploaded as `audio.bin` (the probed name).
- `[tactical]` **Format and mime come from the response** (§37 Decision #4); the content-type outcome rule's fallback did not fire. `sample_rate` comes from the requested `output_format`, since the response does not state it.
- `[tactical]` **Correlation.** TTS: `request-id` → `response.id`, `character-cost` → `raw: %{"character_cost" => n}`. STT: `transcription_id` → `id` (no `request-id` header exists). On both, `request_id` is `opts[:request_id]` only; there is no header fallback, because the provider id already lives on `:id`.
- `[tactical]` `TranscriptionResponse.language` is ElevenLabs' ISO 639-3 `language_code` (`"eng"`), passed through unmapped.
- `[tactical]` Error metadata keys are `status`, `code`, `type` and `provider_status` (`detail.status`), all provider strings redacted. The design named `metadata.code` only.
- `[tactical]` `Support.ElevenLabs.base_url/1` reads `opts[:base_url]`, then `opts[:adapter_opts][:base_url]` (so an engine can pin a residency host), then the global host.
- `[tactical]` `Support.ElevenLabs.error_fields/4` returns `{reason, fields}` for either error module's `new/2`, so the two adapters' error funnels are one line each rather than two copies of the field assembly.
- `[structural, documented]` **Promotion on the two-implementations trigger:** `ALLM.Providers.Support.TranscriptionAdapter.optional_field/2` and `option_fields/2` (`@doc false` + `@spec`). `ElevenLabs.Transcription` would otherwise have been a second copy of `OpenAI.Transcription`'s private `optional_field/2`, `option_fields/1` and `form_values/2`. `lib/allm/providers/openai/transcription.ex` is outside the 26.6 Module Tree; the migration is private and behaviour-preserving (it still logs only a dropped `response_format`), pinned by the existing OpenAI tests. Mutation: renaming string fields inside the shared `form_values/2` fails one OpenAI and one ElevenLabs test. Three new tests in `test/allm/providers/support/transcription_adapter_test.exs`.
- `[scope]` **`test/allm/providers/support/elevenlabs_test.exs`** is not in the Module Tree. The Test Plan put the `output_format/2` and `classify/2` rows under `speech_test.exs`; they test `Support.ElevenLabs`, so they live in that module's own test file (agent-spec/IMPLEMENTATION.md: one test file per `lib/` file), with its doctest.
- `[tactical]` `test/support/elevenlabs_fixtures.ex` delegates to `ALLM.Providers.OpenAITestFixtures.drop_comment/1` and `envelope_bytes/1` rather than adding a third copy of either.
- ~~`[DEFERRED-DRY]` `ElevenLabs.Speech` clones nine of `OpenAI.Speech`'s speech-contract helpers (provider atom and message text differ). No `Support.SpeechAdapter` row exists in 26.6's Module Tree; filed in `.work/ASKS.md` (sat 9/26/2026 10pm) with its predicate. Measured today: 9 lines.~~ Closed by the fix pass (below): `Support.SpeechAdapter` extracted. The nine-name count was also low; code review F2 found renamed and unlisted clones.
- `[scope]` The 26.1 HTTP-variants predicate (`grep -roE 'defp (provider_message|redact_optional|sanitize_cause)\(' lib/allm/providers/ | sort -u | cut -d: -f2 | sort | uniq -c | awk '$1>1'`) now prints `redact_optional` **4** (was 3): `Support.ElevenLabs`'s copy calls the ElevenLabs redactor, the per-provider variant the 26.1 disposition keeps.

### Owner decision needed

- **`ElevenLabs.Transcription.max_audio_bytes/0` is 4,999,999,999** (the design's value, ElevenLabs' documented "less than 5.0GB"). The Phase 25 `TranscriptionAdapterConformance` case 4 builds a `max_audio_bytes() + 1` binary, so `transcription_conformance_test.exs` allocates **5 GB and takes about 22 s** on every `mix test` (measured 2026-09-26: `mix test` 43.4 s with 27.5 s sync; `mix test --exclude module:ALLM.Providers.ElevenLabs.TranscriptionConformanceTest` 21.3 s with 5.8 s sync). The module is `async: false` (so it runs alone) with `@moduletag timeout: 300_000`. Options: keep it; lower the cap to a value the in-memory `Req` multipart path can realistically send (a contract change the design must make); or give the conformance harness a way to size case 4 differently (a `conformance/` change).

### Mutation checks

| Mutant | Failing tests |
|--------|---------------|
| M1 `classify/2` without the `authentication_error` body row | 3 (recorded bad key: support test, speech wire, transcription wire) |
| M2 `redact_key_material/1` is the identity | 4 (both planted-token wire tests, two support tests) |
| M3 no 403 → `:unsupported_feature` row | 3 (feature fixture, recorded tier gate in support and speech wire tests) |
| M4 `Speech` instructions gate removed | 2 (the gate test and the doctest) |
| M5 `Speech` retry loop pinned to one attempt | 1 (the `:rate_limited` retry row) |
| `Support.TranscriptionAdapter` `form_values/2` renames binary fields | 2 (one OpenAI, one ElevenLabs transcription test) |

Each file was restored and `cmp`-verified against a saved copy.

### Notes for later sub-phases

- **26.7–26.8:** classify any HTTP or upgrade status with `Support.ElevenLabs.error_fields/4` / `classify/2`; an invalid key arrives as a **400** or a **401** (by key shape, CORRECTED 2026-09-27), both with `detail.type: authentication_error`, so a WebSocket upgrade failure must be classified from its body too, not from the status. Add WebSocket arms to `speech_arms/0` / `stt_arms/0` in `scripts/record_elevenlabs_audio_fixtures.exs`, behind its overwrite guard. Do not add an input-length arm (the `eleven_v3` 5,001-character arm billed a full synthesis).
- **26.7:** build `ElevenLabs.Speech.stream_synthesize/2` (HTTP `/stream`) on `ALLM.Providers.Support.SpeechAdapter.stream_resource/6`. Implement the optional `speech_started/4`, `speech_completed/3` and `empty_audio_error/1` callbacks; do not clone `OpenAI.Speech`'s stream state machine. The DRY predicate in `.work/ASKS.md` (sun 9/27 `[DISPOSITION]`) must still print nothing. `ElevenLabs.Speech.url/2` builds the HTTP URL; `/stream` and `/stream-input` differ by path, and `Support.ElevenLabs.output_format/2` is the only home of the format table.
- ~~**26.8:** `transcription_conformance_test.exs` is `async: false` with a 300 s module timeout because of the 5 GB case 4 (above). Adding the stream suite to it inherits both.~~ Superseded 2026-09-27: case 4 is skipped for this mount (owner decision), and the module is `async: true` with no raised timeout. **Do not re-add case 4 to the ElevenLabs mount**, and do not remove its `skip_cases:` entry. The sparse-file test in `elevenlabs/transcription_test.exs` binds the size gate instead.
- **26.9:** the examples gate `ALLM_PROVIDER=elevenlabs mix run examples/run_all.exs` needs the elevenlabs `@providers` row that 26.9 adds, so it was **not run and is not claimed** here; 26.6.4's Verification lists no examples gate.

### Fix pass (2026-09-27)

Sources: `.work/reviews/2026-09-26-phase-26-6/overview.md` (functional), `.work/code-reviews/2026-09-26-phase-26-6.md`, `.work/security-reviews/2026-09-26-phase-26-6.md` (clean), and the design review (N/A).

**Deviations**

- `[scope, owner decision 2026-09-27]` **Conformance case 4 is skipped for `ElevenLabs.Transcription` only.** The owner's answer to "Owner decision needed" above was "Let's remove the and make a note". Read as: remove the oversize case from the ElevenLabs mount, keep it for OpenAI, Gemini and the Fakes, and keep the 5 GB cap. Case 4 allocated `max_audio_bytes() + 1` = 5,000,000,000 bytes: 22.1 s and a peak RSS of about 4.99 GB per run (functional review F2). A 4 GB CI runner would OOM-kill. The harness had no per-case opt-out, so `conformance/lib/allm/test/transcription_adapter_conformance.ex` gains `skip_cases: %{n => "reason"}`. A skipped case stays injected and is tagged `skip: "transcription conformance case N skipped: <reason>"`, so ExUnit counts it in every run's skipped total and names it with its reason under `mix test --trace` (a bare run prints only `*` and the count: scoped fix re-review F1). An unknown case number or an empty reason raises `ArgumentError`. A new meta-test module, `ALLM.Test.TranscriptionAdapterConformanceSkipCasesTest`, pins both. The mount site (`test/allm/providers/elevenlabs/transcription_conformance_test.exs`) carries the decision and date in a comment and in the reason. It is `async: true` with no raised timeout, like its OpenAI and Gemini siblings. The size gate is bound by a new test in `elevenlabs/transcription_test.exs`: a sparse file of `max + 1` bytes is refused with `count`/`max`, and one of exactly `max` passes `gate_audio/2`. `File.stat/1` reports the length without allocating it. Mutation: `gate_size(count, @max_audio_bytes + 1, …)` fails that test.
- `[structural, documented]` **`ALLM.Providers.Support.SpeechAdapter` extracted (code review F1)**, the speech sibling of `Support.TranscriptionAdapter`. It holds `fetch_speech_script/1`, `gate_input_shape/3`, `stub_error/2`, `prepare_request/3`, `do_synthesize/4`, `run_one_attempt/5`, `transport_error/5`, `retry_telemetry_meta/2`, `malformed_error/4`, `non_audio_error/3`, `audio_content_type?/1`, `stringify_keys/1`, `put_present/3` and `drop_reserved_options/4`. It also holds `OpenAI.Speech`'s whole Finch stream state machine as `stream_resource/6`. Its callbacks are `run_gates/2`, `build_request/2`, `decode_response/4`, `to_speech_adapter_error/4`, `malformed_error/2` and `redact_key_material/1`, plus the optional `speech_started/4`, `speech_completed/3` and `empty_audio_error/1`. `OpenAI.Speech` (released) and `ElevenLabs.Speech` both migrated. This is the "Migration on extraction" exception: private, behaviour-preserving (log and error texts are byte-identical), and every public name is kept. The adapters gain `@doc false` public callbacks; none is removed. It is pinned by the prior tests: all OpenAI speech, stream and conformance files stay green unchanged. `mix.exs` `groups_for_modules` gains the row.
- `[tactical]` Folded in because the extraction needed one gate shape (code review F5, F6). `ElevenLabs.Speech.run_gates/2` now returns `:ok`, not `{:ok, output}`. `Support.ElevenLabs`'s private `@mime` table is gone; `output_format/2`'s `mime_type` now comes from `ALLM.SpeechResponse.format_to_mime/1`, so only one table exists.
- `[scope]` `test/allm/providers/support/speech_adapter_test.exs` (new, 7 tests). It binds the `Retry.run/3` step mapping and helpers that neither adapter's suite could see, because both run under the default retry policy. See the mutation table below.
- `[probe]` **Recorder builds TTS requests with the adapter's own `url/2` and `to_json_body/2` (code review F3).** The duplicated default constants are retired. Before this fix, `tts_default` had never sent `output_format`, so the `mp3_44100_128` every default call sends had never been probed. Re-recorded live on 2026-09-27: `mp3_44100_128` → 200 `audio/mpeg`, 13,000 bytes, `character-cost: 3`. The speech wire test now also decodes each mp3 body's first frame header. `tts_default` must say 44,100 Hz at 128 kbps, and `tts_mp3` 24,000 Hz. The existing table row asserts only the requested rate, which cannot fail on provider behaviour.
- `[probe]` **`stt_audio_bin` narrowed to exactly 200 with a "fox" transcript, and recorded as a body envelope (code review F4).** One extra short STT call (the 3.7 s fox clip). The transcription wire test asserts the transcript.
- `[probe]` **New `bad_key_401` arm (functional review F1).** A mixed-case `sk_` key → 401 `unauthorized`, `type: authentication_error`, no key echo, recorded as `speech/recorded/error_401_bad_key.json` with a wire test (`:authentication_failed`, status 401). Unbilled. The three "only 400" sentences are corrected: `Support.ElevenLabs`'s moduledoc, `speech/synthesized/error_401.json`'s `_comment`, and the `bad_key` row above. The design gets two dated `CORRECTED 2026-09-27` lines.
- `[scope]` `[DEFERRED-DRY]` The atom-key stringify body is still in four files across capabilities: `Support.SpeechAdapter`, `openai/moderation.ex`, `Support.TranscriptionAdapter.option_fields/2` inline, and `gemini/transcription.ex`. Moderation and transcription were outside this fence. Filed in `.work/ASKS.md` (sun 9/27) with its predicate; measured 4.

Live calls this pass: 3 (`tts_default` "Hello.", `bad_key_401` unbilled, `stt_audio_bin` 3.7 s); re-run `0 live calls`.

**DRY predicate** (replaces the sat 9/26 name-only one; `.work/ASKS.md` sun 9/27 `[DISPOSITION]`):
`grep -rnE 'defp? (fetch_speech_script|gate_input_shape|input_error|stub_error|do_synthesize|run_one_attempt|transport_error|retry_telemetry_meta|audio_content_type\?|stringify_(option_)?keys|drop_reserved(_options)?|put_present|new_stream_state|stream_next|handle_stream_message|stream_after)\(|SpeechAdapterError\.new\(:malformed_response' lib/allm/providers/*/speech.ex` → empty, exit 1.

**Mutation checks (fix pass)**

Each mutant was applied to `lib/allm/providers/support/speech_adapter.ex`, then the file was restored and `cmp`-verified against a saved copy. OpenAI = `openai/speech_test.exs` + `speech_wire_test.exs` + `speech_stream_test.exs`; EL = `elevenlabs/speech_test.exs` + `speech_wire_test.exs`; SA = `support/speech_adapter_test.exs`.

| Mutant | OpenAI | EL | SA |
|--------|--------|----|----|
| `:rate_limited` dropped from the retryable reasons | 1 | 1 | — |
| empty-input gate removed | 4 | 1 | — |
| `audio_content_type?/1` always true | 2 | 1 | — |
| `drop_reserved_options/4` drops nothing | 1 | 1 | — |
| `stringify_keys/1` keeps atom keys | 1 | 1 | — |
| stub error reason `:unknown` → `:invalid_request` | 1 | 1 | — |
| timeout reason → `:network_error` | 1 | 1 | — |
| invalid-UTF-8 gate removed | 1 | 1 | — |
| `sanitize_cause` dropped on JSON decode errors | 1 | 1 | — |
| timeout `{:retry, …}` → `{:error, …}` | 0 | 0 | 1 |
| network error `{:retry, …}` → `{:error, …}` | 0 | 0 | 1 |
| `Retry-After` ignored | 0 | 0 | 1 |
| non-audio content type not redacted | 0 | 0 | 1 |
| request id dropped from retry telemetry | 0 | 0 | 1 |
| stream: empty-audio check disabled | 1 (stream + stream conformance) | n/a | — |
| stream: trailers dropped | 1 | n/a | — |
| stream: no cancel-and-drain | 4 | n/a | — |
| stream: silence timeout → `:network_error` | 1 | n/a | — |

**Verification (fix pass, 2026-09-27)**

| Check | Result |
|-------|--------|
| `mix test` | exit 0; 586 doctests, 33 properties, 4632 tests, 0 failures, 14 excluded, 1 skipped (the ElevenLabs case 4); **19.2 s** (13.4 s async, 5.7 s sync). The pre-fix run was 43.4 s |
| `mix test --seed 0` | exit 0, same counts; 22.7 s |
| `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer` | exit 0; no issues; `Total errors: 0` |
| `mix compile --warnings-as-errors --force`, `MIX_ENV=test mix compile --warnings-as-errors` | exit 0 |
| `mix docs 2>&1 \| grep -iE 'warning\|error'` | empty |
| `cd conformance && mix test && mix credo --strict && mix format --check-formatted` | 194 tests, 0 failures, 1 skipped (the self-test's own skip); no issues; exit 0 |
| audit on `support/speech_adapter.ex`, `openai/speech.ex`, `elevenlabs/speech.ex`, `support/elevenlabs.ex` | 0 hits each |
| 26.1 transcription predicate / pump guard | empty / exit 1 |
| async grep (`… \| xargs grep -L 'async: false' \| wc -l`) | 12, unchanged |
| speech DRY predicate (above) | empty, exit 1 |
| coverage (`mix test --cover` over `test/allm/providers/{openai,elevenlabs,support}`) | `Support.SpeechAdapter` 97.65%, `Support.ElevenLabs` 95.56% |
| recorder re-run | `0 live calls` |
| live key in fixtures (`grep -rlF "$ELEVENLABS_API_KEY" test/fixtures/elevenlabs`, key from `.env` in a subshell) | exit 1 (none) |
| `README.md` | unmodified |

### Verification (run 2026-09-26, working tree on `eab71aa`)

| Check | Result |
|-------|--------|
| `mix test` | exit 0, 586 doctests, 33 properties, 4620 tests, 0 failures, 14 excluded (26.5: 575 / 33 / 4448); 43.4 s, of which 27.5 s sync |
| `mix test --seed 0` | exit 0, same counts |
| `mix format --check-formatted` | exit 0 |
| `mix credo --strict` | no issues |
| `mix dialyzer` | `Total errors: 0` |
| `mix compile --warnings-as-errors --force` (dev) and `MIX_ENV=test mix compile --warnings-as-errors` | exit 0 |
| `mix docs 2>&1 \| grep -iE 'warning\|error'` | empty |
| `mix run scripts/audit_user_docs.exs <file>` on the 3 new `lib/` files and the 2 modified (`support/transcription_adapter.ex`, `openai/transcription.ex`) | "No banned-token matches" each |
| async grep `grep -rl 'Keys.put(\|Logger.configure(\|System.put_env(\|:telemetry.attach' test/ \| xargs grep -L 'async: false' \| wc -l` | 12, unchanged; the new test files use none of the four calls |
| 26.1 transcription predicate (three `*/transcription.ex` files) | empty output, exit 0 |
| Pump-protocol guard `grep -lE --exclude=input_pump.ex ':input_error\|crash_info\(\|@input_window' lib/allm/providers/*.ex lib/allm/providers/*/*.ex` | exit 1 (empty) |
| Targeted | `elevenlabs/speech_test.exs` 3 doctests + 29; `speech_wire_test.exs` 46; `transcription_test.exs` + `transcription_wire_test.exs` + support tests 28 doctests + 254 (with the OpenAI transcription files); both conformance files 12 |
| Conformance suites | `SpeechAdapterConformance` and `TranscriptionAdapterConformance` pass for both ElevenLabs adapters |
| Coverage (`mix test --cover` over the ElevenLabs and support tests) | `ElevenLabs.Speech` 95.65%, `ElevenLabs.Transcription` 100%, `Support.ElevenLabs` 95.56%, `Support.TranscriptionAdapter` 100% |
| BLOCKING recorder | exit 0, every arm matched (14 live calls); re-run `0 live calls`, exit 0 |
| Fixtures contain no live key | `grep -rl "$ELEVENLABS_API_KEY" test/fixtures/elevenlabs` (key loaded from `.env` in a subshell) → no match |
| `conformance/` | not touched, so its gates were not run |
| `README.md` | not modified (`git diff --stat HEAD -- README.md` empty) |



## Phase 26.7 — WebSocket transport + ElevenLabs TTS streaming

Built 2026-09-27 on `591e96b`. The working tree is uncommitted; the orchestrator commits after review.

### Checklist (26.7.3)

- [x] `mix.exs` `{:mint_web_socket, "~> 1.0"}`; `mix deps.get` locked `mint_web_socket 1.0.6` (no new transitive dep: `mint 1.7.1` was already locked); `mix.lock` +1 line.
- [x] `cd conformance && mix deps.get`: `conformance/mix.lock` +1 line (`mint_web_socket`).
- [x] `ALLM.Providers.Support.WebSocket` (`support/web_socket.ex`, behaviour only) and `ALLM.Providers.Support.WebSocket.Mint` (`support/web_socket/mint.ex`: scheme/host/port from the URL, `ws://` → `:http`; selective handshake receive bounded by `:connect_timeout`; ping answered with a pong; `flush_messages/1`). `test/support/web_socket_stub.ex` (Agent-backed from the start), `test/support/ws_test_server.ex` (`:gen_tcp`, port 0 per server, no new dependency).
- [x] `ElevenLabs.Speech.stream_synthesize/2` (Finch, on `Support.SpeechAdapter.stream_resource/6` with the three optional callbacks) and `stream_synthesize_input/3` (WebSocket + `InputPump`); both stream suites added to `elevenlabs/speech_conformance_test.exs`.
- [x] Recorder arms (8 new, behind the overwrite guard); settled rows carry dated `> CORRECTED 2026-09-27 (26.7 probe)` blockquotes in the design (HTTP wire map, WebSocket TTS wire map, Error classification, the WebSocket contract block, Decisions #6 and #11).
- [x] `groups_for_modules`: `Support.WebSocket` and `Support.WebSocket.Mint`, one row each, under `Providers`.

### HANDOFF rows applied

- **`stream_resource/6`, no clone:** `do_stream_synthesize/2` builds the `Finch.Request` (`stream_url/2`, `to_json_body/2`) and calls `SpeechSupport.stream_resource/6`; `speech_started/4`, `speech_completed/3`, `empty_audio_error/1` are `@impl` callbacks. Speech DRY predicate (`.work/ASKS.md` sun 9/27): empty, exit 1.
- **After function:** the HTTP path's is `Support.Transport.cancel_and_drain/3` (inside `stream_resource/6`). The WebSocket path's closes the socket, calls `flush_messages/1`, then `InputPump.stop/2`.
- **Transport opts from the top level:** `:finch_module`, `:finch_name`, `:stream_timeout`, `:ws_module`, `:connect_timeout` are read from `opts` only.
- **InputPump helpers:** `is_pump_message/2` in the selective `receive`, `classify/2`, `ack/2`, `default_window/0`, `stop/2`. Pump-protocol guard: empty, exit 1.
- **`ALLM.Test.RaisingFinch`** for the keyless HTTP gates; its WebSocket sibling `ALLM.Test.RaisingWebSocket` for the input gates.

### Live probe (run 2026-09-27, `( set -a; . ./.env; set +a; mix run scripts/record_elevenlabs_audio_fixtures.exs )`)

Exploratory calls first, from a scratchpad script (not committed), through `Support.WebSocket.Mint`: one `"Hi."` session, then bad key (mixed-case and hex-shaped), unknown voice and no key. All four error calls upgraded with **101** and then sent an error frame and closed 1008; the no-key frame was `{"code": 1008, "error": "authentication_required", "message": "None of the authentication methods (xi-api-key, authorization header, single-use token) were found. …"}`. One live smoke of the finished adapter (`["Hi", "."]`, pcm) followed.

Recorder run 1: exit 1, nothing written. Every arm matched except `ws_v3`, which the arm expected to upgrade: `eleven_v3` was refused at the upgrade with HTTP 400. The arm was widened to `[101, 400]` with a verdict for each (see Deviations). Run 2: 8 live calls, exit 0, every arm matched, 8 files written. Run 3: `0 live calls`, exit 0.

| Arm | Got | Observation |
|-----|-----|-------------|
| `stream_chunked` (`/stream`, flash, 44 chars, `pcm_24000`) | 200 | `audio/pcm`, `transfer-encoding: chunked`, 140,434 bytes in 26 data messages, first 425 ms, last 545 ms; `request-id` and `character-cost: 22` present |
| `ws_tokens` (default `chunk_length_schedule`) | 101 | first audio **563 ms** after the first text frame (after the flush), 2 audio frames, 46,812 bytes; alignment `" Hello world."`, 975 ms; `isFinal` 221 ms after the flush; close 1000 |
| `ws_tokens_auto_mode` (`auto_mode=true`) | 101 | first audio **238 ms** after the first text frame, 5 audio frames, 100,310 bytes; each chunk generated separately (`"Hel"` 557 ms, `"lo"` 464 ms, `" world"` 604 ms, `"."` 464 ms); close 1000 |
| `ws_end` (`inactivity_timeout=1`; `"Hi"`, 500 ms, keep-alive `" "`, 200 ms, `" there."`, flush, close) | 101 | alignment `" Hi there."` (789 ms), no extra pause; `isFinal` 261 ms after the flush; close 1000 |
| `ws_control` (`not_a_real_field` in the initial message) | 101 | audio and `isFinal`: unknown init fields are ignored |
| `ws_v3` (`model_id=eleven_v3`) | **400** at the upgrade | `{"detail": {"type": "validation_error", "code": "unsupported_model", "message": "Model 'eleven_v3' is not supported on the text-to-speech websocket endpoint. Use the text-to-dialogue websocket endpoint instead.", …}}` |
| `ws_bad_voice` | 101 | `{"code": 1008, "error": "voice_id_does_not_exist", "message": …}`, then close 1008 with the message; no audio |
| `ws_bad_key` (mixed-case `sk_`) | 101 | `{"code": 1008, "error": "invalid_api_key", "message": "Invalid API key"}`, then close 1008; no key echo |

Cost: about 44 + 4 × 12 characters of synthesis per clean run, plus the exploratory calls and the failed first run (≈ 200 characters in all, under $0.02 at $0.05 / 1K). No input-length arm.

### Owner decision needed

- **The `/stream-input` latency default.** Decision #11 binds the default to whichever setting gives the lower first-audio time, and `auto_mode=true` won (238 ms against 563 ms, one run each), so the adapter sends `auto_mode=true` unless `options["query"]` sets `auto_mode`. The same run shows the two settings do not produce the same speech: under `auto_mode` each chunk was generated as its own clip (`"Hel"`, `"lo"`, `" world"`, `"."`: 2.1 s against 0.98 s for the whole sentence), and ElevenLabs' docs recommend `auto_mode` only for whole words or sentences. `ALLM.AudioStream.text_deltas/1` feeds raw LLM token deltas, which split words. Options: (a) keep `auto_mode=true` (the rule as written; the trade-off and the `auto_mode: false` escape hatch are in the `stream_synthesize_input/3` `@doc`); (b) default to the provider's `chunk_length_schedule` (quality first; first audio waits for 120 buffered characters or the flush); (c) a middle setting, e.g. a short `chunk_length_schedule` such as `[50]` in the initial message, which needs one more measured arm. The flip is one attribute (`@ws_query_defaults` in `lib/allm/providers/elevenlabs/speech.ex`) plus the `@doc` paragraph and one URL test row.
- **Resolved 2026-09-27 by the owner: "Word-buffer + auto_mode"** — option (a) plus adapter-side word buffering. Applied in the fix pass; see "Fix pass" below.

### Deviations

- `[structural, documented]` **`Support.WebSocket` has a sixth callback, `message_tag/1`.** The contract block's `handle_message/2 → :unknown` cannot select messages on its own: a message has to be received before it can be passed in, and a catch-all `receive` would consume the consumer's unrelated messages. Every transport message of a connection is a 2- or 3-tuple whose second element is the tag (the socket for Mint, a reference for the stub), and the adapter's `receive` guard (`is_transport_message/2`, a `defguardp`) selects on it. Design CORRECTED under the contract block. *(Fix pass: the guard is now a public `defguard` on `ALLM.Providers.Support.WebSocket`, code review F1.)*
- `[structural, documented]` **The WebSocket scheme follows the base URL** (`https` → `wss`, `http` → `ws`, `ws`/`wss` kept), so the end-to-end rows reach `WSTestServer` with `base_url: "http://127.0.0.1:<port>"`. The default and every `https://` base URL still give `wss://`. Design CORRECTED.
- `[structural, probe]` **WebSocket error classification** (`Support.ElevenLabs.ws_error?/1`, `ws_error_fields/3`, `ws_reason/2`, shared with 26.8): one table from the frame's `error` / `message_type` code, then the close code. A bare close 1008 is `:invalid_request`, not the design's inferred `:authentication_failed` (an unknown voice also closes 1008); any other close before a terminal event, including an orderly 1000 before `isFinal`, is `:network_error`. The design's WS `message_type` rows are all in the table now (table-driven test, 18 codes), ahead of 26.8.
- `[probe]` **`stream_chunked` sends 44 characters, not ~400** (the batch's ≤ 50-character budget). 26 chunks over 120 ms still settle the framing row.
- `[probe]` **`ws_tokens` is two arms with two targets** (`ws_tokens.json`, `ws_tokens_auto_mode.json`), because the overwrite guard is per target. **`ws_v3` accepts 400** after run 1 showed the refusal happens at the upgrade; its verdict records the body.
- `[scope]` **`test/support/raising_web_socket.ex`** (`ALLM.Test.RaisingWebSocket`) is not in the Module Tree. It is the `:ws_module` sibling of `ALLM.Test.RaisingFinch`, used by the input suite's `gate_opts` and the keyless gate rows.
- `[scope]` **The URL-builder row lives in `elevenlabs/speech_stream_test.exs`**, not `web_socket_test.exs`: the builder is `ElevenLabs.Speech.ws_url/2` (one test file per `lib/` file).
- `[tactical]` **`ALLM.Providers.Support.WebSocket.Mint.finish_upgrade/4` carries `@dialyzer {:nowarn_function, …}`.** `mint_web_socket` 1.0.6 types its opaque struct's `:fragment` as `tuple()` while its `defstruct` default is `nil`, so Dialyzer infers `Mint.WebSocket.new/5` can only fail. The success path runs in every handshake test.
- `[tactical]` `:speech_started` on the WebSocket path is emitted after the connect and the initial message, before any input, with format, MIME type and rate from the requested `output_format`. `:speech_completed.id` is `nil` there (no correlation id reaches the client). `request_id` is `opts[:request_id]` on both paths, as in 26.6.
- `[tactical]` `:ws_module` is not added to `ALLM.Adapter.transport_opts/0`, so an engine's `adapter_opts` cannot set it; a direct call's top-level opts can. No test needs the engine route.
- `[tactical]` **The slow-input row uses 100 ms gaps under a 250 ms `stream_timeout`**, not the Test Plan's 60 ms under 100 ms: that version failed once in ten full-suite runs (a 40 ms margin is inside scheduler jitter under load). The input still takes 500 ms, twice the timeout, so a timer reset only by transport messages fails it (mutation table).
- `[tactical]` The keep-alive runs only while input is still flowing; after `{"text": ""}` nothing more is sent (test "no keep-alive is sent after the end of input").

### Mutation checks

Each mutant was applied, the targeted files run, and the source restored and `cmp`-verified.

| Mutant | Failing tests |
|--------|---------------|
| pump messages do not reset the silence timer | 1 (slow input under a short timeout) |
| no keep-alive | 1 (keep-alive row) |
| after function skips `flush_messages/1` | 3 (end-to-end halt over Mint, recorded `:tcp` drain rows) |
| after function skips `InputPump.stop/2` | 1 (halt: pump dead within 500 ms) |
| a space appended to each chunk | 7 |
| no `auto_mode` default | 1 (URL row) |
| error frames ignored | 3 |
| a pump started before the connect | 3 (the three "never reduce the input" rows) |
| `WebSocket.Mint` answers no pong | 1 (server-observed pong) |
| `WebSocket.Mint.flush_messages/1` drains nothing | 2 (Mint mailbox row, end-to-end halt row) |
| no buffered delivery of bytes read with the 101 | 2 (the greeting row, and the ping row when its frame shares the read) |

### Notes for later sub-phases

- **26.8:** `stream_transcribe/3` is the second WebSocket stream. Reuse `Support.WebSocket` (`connect/3` with the key in the header, `message_tag/1` + a tag guard in the `receive`), `Support.ElevenLabs.ws_error?/1` / `ws_error_fields/3` (the `message_type` rows are already in the table), `ALLM.Test.WebSocketStub` (`:send_error`, `:unknown`, `{:transport_error, _}`, `:closed`), `ALLM.Test.WSTestServer` and `ALLM.Test.RaisingWebSocket`. `ElevenLabs.Speech`'s `/stream-input` machine (`open_input_stream/4`, `input_next/1`, `await/2`, `wait_ms/1`, `input_after/1`) is the first copy of the owner loop; a second copy triggers the two-implementations rule, so extract the shared skeleton (connect → start pump → selective receive with a silence timer → close/flush/stop) with its first second caller rather than cloning it.
- **26.8 (fix pass):** the owner loop is already shared. Build `stream_transcribe/3` on `ALLM.Providers.Support.WebSocket`'s `@doc false` helpers (`loop_state/3`, `start_pump/3`, `next_message/1`, `timed_out?/1`, `handle_transport/2`, `send_json/2`, `stop_pump/1`, `close_loop/1`) and the public `is_transport_message/2` guard; keep only the payload handlers and the error construction in the adapter. Predicate: `grep -rnE "defp? await\(|receive do" lib/allm/providers/elevenlabs` prints nothing.
- **26.9:** the guide quotes Decision #11's two numbers (238 ms / 563 ms) and the owner's default: `auto_mode=true` with word buffering (`auto_mode: false` turns both off).

### Verification (run 2026-09-27, working tree on `591e96b`)

| Check | Result |
|-------|--------|
| `mix test` | exit 0; 590 doctests, 33 properties, 4778 tests, 0 failures, 14 excluded, 1 skipped (26.6 fix pass: 586 / 33 / 4632) |
| `mix test` ×8 and `mix test --seed 0` ×3 after widening the slow-input row | all 11 exit 0, same counts. Before the widening, 1 run in ~12 failed the slow-input row (see Deviations) |
| `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer` | exit 0; no issues; `Total errors: 0` |
| `mix compile --warnings-as-errors --force` (dev and test) | exit 0 |
| `mix docs 2>&1 \| grep -ciE 'warning\|error'` | 0 |
| `mix run scripts/audit_user_docs.exs` on `support/web_socket.ex`, `support/web_socket/mint.ex`, and the modified `elevenlabs/speech.ex`, `support/elevenlabs.ex` | "No banned-token matches" each |
| async grep (`… \| xargs grep -L 'async: false' \| wc -l`) | 12, unchanged; the new test files use none of the four calls |
| pump-protocol guard / speech DRY predicate | exit 1 (empty) / exit 1 (empty) |
| `cd conformance && mix test && mix credo --strict && mix format --check-formatted` | 194 tests, 0 failures, 1 skipped; no issues; exit 0 |
| `mix hex.build` | succeeds; `Dependencies:` lists `mint_web_socket ~> 1.0 (app: mint_web_socket)` |
| BLOCKING recorder | run 2: 8 live calls, every arm matched; run 3: `0 live calls` |
| live key in fixtures (`grep -rlF "$ELEVENLABS_API_KEY" test/fixtures/elevenlabs`, key from `.env` in a subshell) | exit 1 (none) |
| coverage (`mix test --cover` over `test/allm/providers/{elevenlabs,support}`) | `ElevenLabs.Speech` 99.54%, `Support.ElevenLabs` 96.97%, `Support.WebSocket` 100%, `Support.WebSocket.Mint` **87.23%** (below the 90% new-code floor: the uncovered lines are `Mint.WebSocket` error tuples the local server cannot provoke — an encode error, an upgrade-request error, a failed pong, `{:error, ref, _}` responses — and the `safely/1` rescue arms of `close/1`) |
| `README.md` | not modified |

### Flakes

- `test/allm/providers/support/input_pump_test.exs:118` ("a throw and an exit inside the input are reported with their kind", 26.3) failed once in about 20 runs of the ElevenLabs + support test directories (`assert_receive` with the default 100 ms timeout, seed 331841); it passed on rerun. Pre-existing test code, outside this fence; the new timing-based tests in this batch add load. Filed in HANDOFF. *(Fix pass: both `assert_receive`s in that test now wait 1,000 ms; HANDOFF row discharged.)*

### Fix pass (2026-09-27)

Sources: `.work/reviews/2026-09-26-phase-26-7/overview.md` (D-1), `.work/code-reviews/2026-09-26-phase-26-7.md` (F1–F5), `.work/security-reviews/2026-09-26-phase-26-7.md` (clean), `.work/design-reviews/2026-09-26-phase-26-7.md` (N/A). No live calls.

- **Owner decision (2026-09-27): "Word-buffer + auto_mode".** `auto_mode=true` stays the `/stream-input` default. While it is on (the effective query value, so `options["query"]["auto_mode"]` still turns it off), `ElevenLabs.Speech` holds incoming text in a `word_buffer` and sends only up to the last word boundary; the remainder goes out at the end of input, before the flush. `text_deltas/1` stays a pure mapper: the buffering lives in the adapter's input path because that serves every caller of the `auto_mode` path, not only chat deltas. **Boundary set:** Unicode whitespace, `! ? ;`, and the CJK full-width marks `。 、 ， ！ ？ ； ：` plus `…` (`split_at_word_boundary/1`, a `@doc false` seam). `.`, `,`, `:`, `'` and `-` are not boundaries on their own because they occur inside words and numbers (`3.14`, `1,000`, `10:30`, `don't`); followed by a space they go out at the space, so a sentence-final `.` waits one token or the end of input. CJK marks are included so that text without spaces still streams. Text with no boundary at all waits for the end of input (no size cap: nothing measured needs one). With `auto_mode` off, chunks go out verbatim as before. Tests (`speech_stream_test.exs`): `["Hel","lo"," world","."]` → `"Hello "`, `"world."`; a trailing partial word is flushed before `{"text":"","flush":true}`; a boundary-less chunk is held while the keep-alive still goes out; a `split_at_word_boundary/1` table; the old verbatim row now runs with `auto_mode: false` and asserts `auto_mode=false` in the URL. Design: dated OWNER NOTE under Decision #11.
- **F1 (Medium) — shared owner loop, done now.** `await/2`, `wait_ms/1`, the timer reset, `on_transport`'s transport half, `send_json/2`, `stop_pump/1` and the after function moved to `ALLM.Providers.Support.WebSocket` as `@doc false` + `@spec` defs over a state map (`loop_state/3`, `start_pump/3`, `next_message/1`, `timed_out?/1`, `handle_transport/2`, `send_json/2`, `stop_pump/1`, `close_loop/1`), chosen over a new module because 26.8 already calls `Support.WebSocket` and no `groups_for_modules` row changes. `is_transport_message/2` is a public `defguard` there, used by the moduledoc sample, the loop and `web_socket_test.exs`. `await/2` is one clause (with no pump running, a fresh reference matches no pump message). Predicates: `grep -rn "defp await(%{pump:" lib/allm/providers | wc -l` → 0; `grep -rnE "defp? await\(|receive do" lib/allm/providers/elevenlabs` → empty, exit 1.
- **F2 (Medium, bug) — bytes read with the 101.** They are held in a new `pending` struct field; the next `handle_message/2`, whatever it is given, decodes them first (an `:unknown` message still returns the pending frames). A payload-less `{WebSocket.Mint, socket}` self-message is only a wake-up, and `flush/1` drains it. New test: a greeting split between the 101's read and a later packet, with the mailbox re-ordered to put the `:tcp` message first → one intact frame. Mutant (pending decoded after the next packet): the test fails with `{:unsupported_opcode, <<7::4>>}`, the framing corruption the review predicted.
- **F4 (Low, folded into F2).** `finish_upgrade/5` now holds only `Mint.WebSocket.new/5`, the struct build and the shared `abort/3`; the pending hand-off moved to `handshake/3`. The comment names `mint_web_socket` 1.0.6 with the `deps/` line cites and says to drop the attribute and rerun `mix dialyzer` on a bump.
- **F5 (Low, folded into F2).** `safely/1`'s dead `rescue` removed.
- **F3 (Medium) — cross-packet tests.** `WSTestServer` gained `encode_frame/1`, a `{:frame, opcode, payload, fin?}` frame and `greeting: {:raw, bytes}`. New `web_socket_test.exs` rows: a 10 KB text frame over two reads (16-bit length), a 70,000-byte binary frame whose header is split from its 64-bit length, and a two-fragment text message reassembled; plus three pending-byte rows (non-connection message, socket error, malformed greeting). `speech_stream_test.exs` gained an end-to-end session with two 6,144-byte audio frames (8 KB base64 each) over Mint. **Coverage** (`mix test --cover test/allm/providers/elevenlabs test/allm/providers/support`): `Support.WebSocket.Mint` **90.91%** (was 87.23%), `Support.WebSocket` 100%. Still uncovered: `Mint.WebSocket` encode/decode error tuples, `{:error, ref, _}` responses, the upgrade-request error and `safely/1`'s catch arm.
- **D-1 (Medium) — false doc sentence.** The `stream_synthesize_input/3` `@doc` now says only a refused upgrade never reduces the input; a bad key or an unknown voice is upgraded with 101 and rejected by an error frame and a close 1008, after `:speech_started` and after the input may have been reduced (so a paid chat input is issued). New end-to-end row over `WSTestServer`: 101, then (after the first text frame) the recorded `invalid_api_key` error frame and close 1008 → `[:speech_started, {:error, :authentication_failed, close_code 1008}]` with the first chunk reduced. **The pump is not held until a first server frame:** ElevenLabs sends nothing on a valid session until it has received text (in all four recorded valid sessions, `ws_tokens`, `ws_tokens_auto_mode`, `ws_end`, `ws_control`, the first server frame follows the client's text frames; `ws_end` shows no server frame during a 500 ms pause after `"Hi"`), so holding would deadlock a valid key or cost a grace-window timeout on every first audio. No evidence found that holding is safe and cheap.
- **`input_pump_test.exs:118` flake:** both `assert_receive`s in that test wait 1,000 ms (a trivially safer timeout).
- Rewritten rows because of the word buffer: keep-alive (`"one "`), halt-safety (`"Hi "`), end-to-end halt (`"Hi "`), and the LLM-shaped row (asserts the same text in order, every frame but the last ending at a boundary).

Mutation checks (each restored and `cmp`-verified): pending decoded after the next packet → 1 failure; `flush_word_buffer/1` a no-op → 10; word buffer off under `auto_mode` → 4; `next_message/1` not resetting `last_activity` → 1 (slow input); `close_loop/1` skipping `flush_messages/1` → 4.

| Check (fix pass) | Result |
|-------|--------|
| `mix test` ×5 (seeds 507243, 917882, 482225, 291911, 847852) and `mix test --seed 0` ×2 | all exit 0; 590 doctests, 33 properties, 4799 tests, 0 failures, 14 excluded, 1 skipped |
| `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer` | exit 0; no issues; `Total errors: 0` |
| `mix compile --warnings-as-errors --force` (dev and test) | exit 0 |
| `mix docs 2>&1 \| grep -ciE 'warning\|error'` | 0 |
| `mix run scripts/audit_user_docs.exs` on `support/web_socket.ex`, `support/web_socket/mint.ex`, `elevenlabs/speech.ex` | no matches each |
| pump-protocol guard / speech DRY predicate | exit 1 (empty) / exit 1 (empty) |
| async grep (`… \| xargs grep -L 'async: false' \| wc -l`) | 12, unchanged |
| `cd conformance && mix test && mix credo --strict && mix format --check-formatted` | 194 tests, 0 failures, 1 skipped; no issues; exit 0 |
| `README.md` | not modified |

## Phase 26.8 — ElevenLabs realtime STT

Built 2026-09-27 on `1f152cf`. The working tree is uncommitted; the orchestrator commits after review.

### Checklist (26.8.3)

- [x] `ElevenLabs.Transcription.stream_transcribe/3` + `stream_sample_rates/0` (`@behaviour ALLM.TranscriptionStreamAdapter`), over `Support.WebSocket` + `InputPump` through the shared `Support.WebSocket.InputLoop`; seams `stream_url/2`, `audio_chunk_message/3` (`@doc false`).
- [x] `test/support/pcm.ex` (`ALLM.Test.PCM.wav_pcm_chunks/2`, `0xFFFFFFFF` → to end of file); recorder arms (6, behind the overwrite guard); settled rows carry dated `> CORRECTED 2026-09-27 (26.8 probe)` blockquotes under the realtime STT wire map and the Error classification.
- [x] `transcription_conformance_test.exs` mounts `TranscriptionStreamAdapterConformance`: 6/6. Batch case 4 stays skipped (owner decision 2026-09-27).

### HANDOFF rows applied

- **F4:** `InputLoop.loop_state/3` takes `keepalive_ms: :infinity` (`timeout()`); `wait_ms/1` short-circuits it the way `stream_timeout: :infinity` already was (`deadline_in/3`). The realtime path passes `:infinity`: its protocol has no keep-alive. Pinned by `input_loop_test.exs` "keepalive_ms: :infinity leaves only the silence deadline" (mutant: the `:infinity` clause removed → 55 failures across the two files).
- **F5:** the loop helpers moved, behaviour-preserving, from `Support.WebSocket` into `ALLM.Providers.Support.WebSocket.InputLoop` (`lib/allm/providers/support/web_socket/input_loop.ex`, its own moduledoc and `groups_for_modules` row under `Providers`); `Support.WebSocket` keeps the callbacks and the `is_transport_message/2` guard and no longer aliases `InputPump`. `ElevenLabs.Speech` migrated in the same change. The helpers now carry real `@doc`s (the module is documented).
- **Done-when predicates** (run from the repo root after the change): `grep -rnE "defp? await\(|receive do" lib/allm/providers/elevenlabs` → empty, exit 1; `grep -rn "defp await(%{pump:" lib/allm/providers | wc -l` → 0; pump-protocol guard `grep -lE --exclude=input_pump.ex ':input_error|crash_info\(|@input_window' lib/allm/providers/*.ex lib/allm/providers/*/*.ex` → empty, exit 1.

### Live probe (run 2026-09-27, `( set -a; . ./.env; set +a; mix run scripts/record_elevenlabs_audio_fixtures.exs )`)

Exploratory sessions first, from a scratchpad script through `Support.WebSocket.Mint` (not committed): vad unpaced at 100/1,000/3,000 ms chunks, `include_timestamps` with and without `include_language_detection`, manual with a mid-clip commit, a second commit with nothing uncommitted, an invented query parameter, a bad key; then live smokes of the finished adapter (vad and manual, paced and unpaced). Recorder run 1 crashed before any arm finished (a recorder bug: a `0` deadline passed as a monotonic time; one session opened, nothing written). Run 2: 6 live calls, exit 0, every arm matched, 6 files written. Run 3: `0 live calls`, exit 0.

| Arm | Got | Observation |
|-----|-----|-------------|
| `rt_fox` (fox WAV, 24 kHz from its header, 100 ms chunks, unpaced, vad, `include_timestamps` + `include_language_detection`) | 101 | `session_started{session_id, config}`; one committed `"The quick brown fox jumps over the lazy dog."`; frame order `committed_transcript` then `committed_transcript_with_timestamps` (`language_code: "en"`); 3 partials, one of them **after** the committed segment; unpaced accepted |
| `rt_manual_commit` (manual, halves split by a commit) | 101 | two segments, `"The quick brown fox jump-"`, `"... over the lazy dog."` |
| `rt_end` (half the clip, final commit, then a second commit with no audio) | 101 | committed `"The quick brown fox jump-"`; the second commit → `{"message_type": "commit_throttled", "error": "Commit request ignored: only 0.00s of uncommitted audio. You need at least 0.3s …"}`, then close `[1000, "commit_throttled"]` |
| `rt_control` (`not_a_real_param=1`) | 101 | accepted: a committed segment; unknown query parameters are ignored |
| `rt_big_chunk` (one 1,000 ms chunk + commit) | 101 | accepted, committed `"The quick brown-"` |
| `rt_bad_key` (mixed-case `sk_`) | 101 | `{"message_type": "auth_error", "error": "You must be authenticated to use this endpoint."}`, close `[1000, ""]`; no session, no key echo |

Exploratory-only facts (not recorded): a 3,000 ms chunk was accepted; without `include_timestamps` no timestamped frame is sent; without `include_language_detection` its `language_code` is `null`; the server does not close after a final committed segment (it waits). In manual mode the second segment's text depended on the split point: split at 1.9 s it was `"... over the lazy dog."` (this arm and one exploratory run), split at 2.0 s it was `""` in all five runs (timestamps on or off, paced or unpaced) — provider behaviour, not the adapter's. A live key check: `grep -rlF "$ELEVENLABS_API_KEY" test/fixtures/elevenlabs` (key from `.env` in a subshell) → exit 1.

Cost: about 12 s of audio in the recorded run and about 60 s in the exploratory sessions and smokes, at $0.39/h (well under $0.01).

### Owner decision needed

> RESOLVED 2026-09-27: option (c), "Hold when requested". See "Owner decision (2026-09-27)" below.

- **Language on realtime segments.** The Timestamped-commits rule (a timestamped frame only attaches its language to a segment *not yet emitted*; a late twin is dropped) was implemented as written and is pinned by the Test Plan's three-segment test. In the observed order the plain `committed_transcript` comes first for 3 of the 4 logged segments (`rt_fox` included), so the language is dropped and `:committed_transcript.language` / `:transcription_completed.language` are usually `nil`, even with `include_language_detection=true`. Options: (a) keep as is (documented in the `stream_transcribe/3` `@doc`); (b) let a late twin set `:transcription_completed.language` only (tried and reverted here: the final segment's twin arrives after the completion is emitted, so it would work only mid-stream, which is inconsistent); (c) when `include_timestamps` is requested, hold each `committed_transcript` until its twin arrives (or a short grace), costing latency on every segment. Recommendation: (a) now, (c) if a caller needs language.

### Owner decision (2026-09-27): "Hold when requested"

Applied by the 26.8 fix pass; design OWNER NOTE under the realtime STT wire map.

- **Opted in** (`request.options` sets `include_timestamps` or `include_language_detection` to `true` or `"true"`): each `committed_transcript` is held until its timestamped frame arrives, then emitted with that frame's `language`. A timestamped frame that arrives first is kept, and its segment is emitted at once. The hold is bounded: the segment is released with `language: nil` when the next segment's `committed_transcript` arrives, when the stream ends with an error (the segment goes out ahead of the `{:error, _}`), or after `adapter_opts[:language_hold_ms]` (default 1,000 ms), whichever is first. `:transcription_completed` waits for a held segment. A segment is never dropped or reordered.
- **Not opted in** (the default): unchanged, latency first. Each segment is emitted on its plain frame.
- **Pairing** is by commit order: two counters (`commits_seen`, `stamps_seen`); the n-th timestamped frame belongs to the n-th segment; one that arrives first waits in `stamps` by index; one whose segment already went out is dropped. The text-equality twin check (`last_text`, `pending_language`) is gone, which also resolves code-review F3 (two consecutive identical texts lost the second's language). Known limit: pairing assumes ElevenLabs sends a timestamped frame for every segment once opted in; a skipped one would shift languages by one segment. Not observed.
- **Timer:** `InputLoop` gained a third deadline, `wake_at` (a monotonic-ms instant or `nil`, `nil` from `loop_state/3`), in the same `min/2` as the silence and keep-alive deadlines. No message resets it. The adapter sets it when it holds a segment and clears it on release. `on_wake/1` now ends the stream with `:timeout` only when `timed_out?/1` holds; any other wake releases the held segment. `ElevenLabs.Speech` never sets it.
- **Tests** (`transcription_stream_test.exs`, describe "language hold when opted in"): plain-then-timestamped and timestamped-then-plain each give one segment with its language; `include_language_detection: "true"` alone opts in; the frame never arriving → released after the default bound (`ms >= 950`), `language: nil`, no error, completion present; `language_hold_ms: 2_500` sets the bound (lower bound only); the next segment's plain frame releases a held one at once (bound 5 s, `ms < 2_000`); two identical texts keep `en`/`fr`; an error while held emits the segment first; not opted in emits at once. Plus a default-path identical-text row and an opted-in `rt_fox` replay (`language: "en"` from the recorded frames). `input_loop_test.exs` gained a `wake_at` row.
- **Mutation checks** (each applied, the listed files run, source restored and `cmp`-verified): hold never on → 8 failures; no release on the next plain frame → 1; `finish/2` not releasing → 1; every wake a timeout → 1 (plus the bound row after its `refute {:error, _}` was added); `language_hold_ms` ignored → 1; timestamped-first index off by one (`>` for `>=`) → 4; `InputLoop` ignoring `wake_at` → 3.
- **Live confirmation** (one session, 3.8 s fox WAV, both options, through the adapter; `( set -a; . ./.env; set +a; MIX_ENV=test mix run <scratchpad>/live_hold.exs )`): `transcription_started` at 342 ms; `committed_transcript` `"The quick brown fox jumps over the lazy dog."` with `language: "en"` and `transcription_completed` `language: "en"` at 1,023 ms. No recorder arm added: the recorded `rt_fox` frames already carry both frame types in the observed order, and its opted-in replay binds the adapter. Not probed: whether `include_language_detection` without `include_timestamps` sends a timestamped frame (the exploratory runs saw none without `include_timestamps`, but did not try detection alone); if it does not, that option alone costs up to the bound per segment and yields `nil`.

### Fix pass (2026-09-27, code review F1/F2, HANDOFF flake row)

- **F1** (`input_loop_test.exs`): the pump row now lets the pump send `"b"`, waits until it sits unconsumed in the mailbox, and `refute_received {^ref, _}` after `stop_pump/1` (mutant: `InputPump.stop/2` without `drain/1` → 1 failure). The close row sends a stub-tagged message before `close_loop/1` and refutes it after, keeping an unrelated message (mutant: no `flush_messages/1` → 1 failure); renamed to what it asserts.
- **F2** (`transcription_stream_test.exs` "no keep-alive"): also refutes `{:error, _}`, asserts the completion, and bounds the reducing process's reductions (< 1,000,000). With the new `on_wake/1`, a finite `keepalive_ms` no longer ends the stream; it spins the loop instead (measured 2026-09-27 with `loop_state(stream_timeout, 100)`: 26,795,337 reductions, against 2,789 unmutated), and the bound fails it.
- **Flake** (`input_pump_test.exs`, 26.3 code): `assert_receive` at `:81` and `:111` (and the `:DOWN` at `:114`) wait 1,000 ms, as `:118`'s sibling did in 26.7. `grep -nF 'assert_receive {^ref, {:input_error' test/allm/providers/support/input_pump_test.exs` → every hit carries `1_000`.
- **Verification** (after the fix pass): `mix test` ×5 (random seeds) and `mix test --seed 0` → 593 doctests, 33 properties, 4902 tests, 0 failures, 14 excluded, 1 skipped, every run; `mix format --check-formatted`, `mix compile --warnings-as-errors --force`, `mix credo --strict`, `mix dialyzer` → clean; `mix docs 2>&1 | grep -ciE 'warning|error'` → 0; `audit_user_docs.exs` on `transcription.ex` and `input_loop.ex` → no matches; `cd conformance && mix test && mix credo --strict && mix format --check-formatted` → 194 tests, 0 failures, 1 skipped; no issues; exit 0.

### Deviations

- `[structural, probe]` **End of input and `commit_throttled`.** The design's "commits any uncommitted audio and waits for the final `committed_transcript`" is refined by the probe: the adapter sends a final commit only when audio went out since its last commit, counts the commits it sent (`awaiting`, decremented per `committed_transcript`, floored at 0), and completes when input is done and `awaiting` is 0. A `commit_throttled` frame after the end of input (a commit with < 0.3 s of audio) completes the stream instead of failing it; mid-stream it stays `:rate_limited`. Known limit: under `vad`, a server-initiated commit that arrives after the final commit is sent is counted against it, so the stream can complete one segment early; not observed (every vad run produced one segment, after the final commit). Design CORRECTED under the wire map.
- `[structural, probe]` **Realtime error frames** are `{"message_type": code, "error": text}`, so `Support.ElevenLabs.ws_error_fields/3` reads the code from `message_type` before `error` and the text from `message`, else `error`; `ws_error?/1` also accepts a table `message_type` that does not end in `error` (`commit_throttled`). The TTS frames (`error` code + `message`, no `message_type`) classify as before (their tests unchanged and green). Design CORRECTED under Error classification.
- `[structural, documented]` **The pump starts on `session_started`**, not after the connect: the adapter's start function only connects, and the next function starts the pump when the server's `session_started` arrives (invariant 9's "waits for `session_started` (STT)"). So a bad key, answered with 101 + `auth_error`, never reduces the input — unlike `/stream-input` TTS.
- `[scope]` **DRY promotions to `Support.ElevenLabs`** (second callers): `ws_base_url/1` (was `ElevenLabs.Speech`'s private `ws_base/1`) and `query_params/2` (was Speech's private `query_params/1`, now parameterised by the reserved names). Both `@doc false` + `@spec`, both migrated in `speech.ex`, tests in `support/elevenlabs_test.exs`.
- `[scope]` **`ALLM.Test.WebSocketStub` gained `:greeting`** (server frames delivered on connect, before any client frame): the realtime server speaks first (`session_started`), which the `{:after_client, …}` script could not express.
- `[scope]` **`test/allm/providers/support/web_socket/input_loop_test.exs`** (new, one test file per `lib/` file): deadline arithmetic, selective receive, `send_json/2`, `close_loop/1`.
- `[tactical]` The realtime `options` map becomes query parameters (atom keys stringified, `nil` dropped); `model_id`, `audio_format`, `commit_strategy` are reserved and dropped with a deferred `Logger.debug/1`. `language_code` is structural only when `request.language` is set.
- `[tactical]` The adapter also runs `Validate.transcription_stream_request/1` before the rate gate (`:invalid_request`, `metadata.errors`), mirroring `stream_synthesize_input/3`'s request-shape gate.
- `[tactical]` An empty `committed_transcript` text is emitted as an event and dropped from `completed.text` by the normative join.
- `[tactical]` `@max_chunk_ms` stays 1,000 (accepted live); an exploratory 3,000 ms chunk was accepted too, so it is a conservative bound, stated as such in the attribute comment.
- `[probe]` `rt_fox` sends `include_timestamps` and `include_language_detection` (to see both frame types and a language); `rt_end` adds a second, empty commit to record `commit_throttled`, which the adapter's end-of-input rule relies on.
- `[probe]` `rt_control` and `rt_bad_key` accept `[101, 400, 422]` / `[101, 400, 401, 403]` (outcome recorded either way, the control rule); both got 101.

### Mutation checks

Each mutant was applied to `lib/`, `transcription_stream_test.exs` + `transcription_conformance_test.exs` run, and the source restored and `cmp`-verified.

| Mutant | Failing tests |
|--------|---------------|
| no odd-byte carry (odd chunks sent as-is) | 3 |
| no final commit at end of input | 27 |
| `commit_throttled` after end of input treated as an error | 1 (recorded `rt_end` replay) |
| timestamped twin not dropped | 1 (three-segment language row) |
| no split of long chunks | 1 (3 s at 16 kHz) |
| a `committed_transcript` does not settle the wait | 20 |
| pump started at connect, before `session_started` | 34 (incl. the `rt_bad_key` "input never reduced" row) |
| `InputLoop` without the `keepalive_ms: :infinity` clause | 55 (with `input_loop_test.exs`) |

### Notes for later sub-phases

- **26.9:** the guide's realtime pacing paragraph: unpaced upload is accepted (`rt_fox`: 3.8 s in about 0.3 s); partials can arrive after their segment's commit (a UI should stop showing a partial once its segment is committed); a `:commit` needs at least 0.3 s of uncommitted audio or ElevenLabs refuses it and closes (`commit_throttled`, `:rate_limited` mid-stream); language needs `options: %{"include_timestamps" => true, "include_language_detection" => true}`, and with them each segment is held (up to 1,000 ms) for its language (owner decision 2026-09-27 above). Example 26 reads the WAV with the `0xFFFFFFFF` rule (`ALLM.Test.PCM` is test-only; the example needs its own reader).
- **Any later WebSocket stream:** build on `ALLM.Providers.Support.WebSocket.InputLoop`; pass `keepalive_ms: :infinity` when the protocol has no keep-alive.

### Flakes

- `test/allm/providers/support/input_pump_test.exs:107` ("composition behaviour 2 …", 26.3) failed once in 15 runs of the ElevenLabs + support directories: `assert_receive` at `:111` uses the default 100 ms timeout under load. It is the sibling of the `:118` flake the 26.7 fix pass widened to 1,000 ms. Pre-existing test code outside this fence; not fixed here, filed in HANDOFF. One full-suite run in 11 (seed 290171) also had one failure that did not reproduce at that seed nor in 6 further runs; its test was not captured, so attributing it to `:107` is unverified.

### Verification (run 2026-09-27, working tree on `1f152cf`)

| Check | Result |
|-------|--------|
| Start Green (before any edit) | `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix test` (590 doctests, 33 properties, 4799 tests, 0 failures), `mix credo --strict`, `mix dialyzer`: all clean |
| `mix test` ×11 (random seeds) and `mix test --seed 0` ×2 | 12 of 13 exit 0 with 593 doctests, 33 properties, 4890 tests, 0 failures, 14 excluded, 1 skipped; 1 run (seed 290171) had 1 failure, see Flakes |
| `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer` | exit 0; no issues; `Total errors: 0` |
| `mix compile --warnings-as-errors --force` (dev and test) | exit 0 |
| `mix docs 2>&1 \| grep -ciE 'warning\|error'` | 0 |
| `mix run scripts/audit_user_docs.exs` on `support/web_socket/input_loop.ex` (new) and the modified `elevenlabs/transcription.ex`, `support/elevenlabs.ex`, `support/web_socket.ex` | "No banned-token matches" each |
| async grep (`grep -rl 'Keys.put(\|Logger.configure(\|System.put_env(\|:telemetry.attach' test/`) | the new test files use none of the four calls (`capture_log/2` only) |
| HANDOFF predicates | loop `await`/`receive` predicate: empty, exit 1; `defp await(%{pump:` count: 0; pump-protocol guard: empty, exit 1 |
| `cd conformance && mix test && mix credo --strict && mix format --check-formatted` (not modified; run anyway) | 194 tests, 0 failures, 1 skipped; no issues; exit 0 |
| Stream conformance for `ElevenLabs.Transcription` | 6/6 (`transcription_conformance_test.exs`, 12 tests, 1 skipped = batch case 4) |
| BLOCKING recorder | run 2: 6 live calls, every arm matched; run 3: `0 live calls` |
| coverage (`mix test --cover test/allm/providers/elevenlabs test/allm/providers/support`) | `ElevenLabs.Transcription` 98.30%, `Support.WebSocket.InputLoop` 100%, `Support.WebSocket` 100%, `Support.ElevenLabs` 97.37%, `ElevenLabs.Speech` 99.49% |
| `README.md` | not modified |

## Phase 26.9 — Spec, guide, examples, transport rule

Built 2026-09-27 on `977cb9f`. The working tree is uncommitted; the orchestrator commits after review.

### Checklist (26.9.2)

- [x] Spec (`steering/allm_engine_session_streaming_spec_v0_2.md`), every block opening `> **Phase 26 amendment (commits `6167d79..977cb9f`; docs land in the 26.9 commit).**` (15 blocks): §37 header note; §37.1 item 2; §37.2.5 (the stale "(9 reasons)" corrected to 10 / 10 + `:content_filter`, with `:unsupported_feature` in the enum listing and its use sites); §37.7 matrix with streaming columns; new §37.7.4 ElevenLabs; §37.10 two items struck, plus a still-out-of-scope list; new §37.11 *Streaming audio* (11 subsections: unions, Layer A, behaviours + invariants 1–9, façades, the no-fold exception, `AudioStream`, the equivalence property, transport, ElevenLabs streaming wire, Fakes/conformance, telemetry); §35.7 third carve-out (Decision #1's text verbatim, plus its beneficiary and the not-a-widening paragraph); §27 module tree; §29 two spans + `[:allm, :audio, :first_chunk]`; §8 pointer (the unions are not `ALLM.Event`); §32.5 and §33 notes superseding "streaming remains out of scope".
- [x] `guides/audio.md`: intro and provider table (streaming forms, ElevenLabs); ElevenLabs voices are ids; ElevenLabs model defaults and the `stream_transcribe/3` model exception; ElevenLabs content sniffing; `max_audio_bytes/0` doctest row; no local ElevenLabs length gate; `:unsupported_feature` with two keyless doctests; new sections "Streaming speech" (+ "Streaming text in"), "Streaming transcription" (+ "Feeding a live source", the relay Decision #4 asks for), "A failed stream ends with an error", "PCM and sample rates", "The voice loop" (fence), "Choosing for latency" (238 / 563 ms and the word-buffer default), "Realtime transcription on ElevenLabs" (pacing, late partials, the 0.3 s commit, the language hold), "ElevenLabs" (format table, tier gate, differences); telemetry gains the stream spans and the first-chunk event (fence); the Fakes section gains the stream script rules and the three stream conformance suites.
- [x] `examples/_helpers.exs`: `elevenlabs` row (`adapter: nil`, `key_env: "ELEVENLABS_API_KEY"`, both audio adapters, `speech_voice: "JBFqnCBsd6RMkjVDRZzb"`), `speech_voice: "alloy"` on `openai`, `chat_provider?/1`, `speech_voice/0`, `provider_rows/0` (`@doc false` test seam); `speech_engine/1`'s unavailable message and moduledoc updated.
- [x] `examples/run_all.exs`: a marker-less script runs only when `ExamplesHelpers.chat_provider?/1`.
- [x] `examples/23_synthesize_speech.exs`: voice from `speech_voice/0`; the mime assertion is `ALLM.SpeechResponse.format_to_mime(:mp3)` (26.6's outcome: ElevenLabs answers `audio/mpeg` for mp3, so format and mime derive from the response); marker `openai, elevenlabs`. `24_transcribe_audio.exs` marker `openai, gemini, elevenlabs`.
- [x] `examples/25_stream_speech.exs`, `26_stream_transcribe.exs` (own WAV reader with the `0xFFFFFFFF` rule), `27_voice_loop.exs` (explicit OpenAI chat engine; `SKIP:` line and exit 0 without `OPENAI_API_KEY`); `examples/fixtures/quick_brown_fox.wav` (`cmp`-identical to `test/fixtures/audio/quick_brown_fox.wav`).
- [x] `examples/README.md`; `test/allm/examples_helpers_test.exs` (+4 tests); `CLAUDE.md` (WebSocket transport bullet; the audio exception appended to the fold-into-response bullet); `CHANGELOG.md` folded into the unreleased `## [REL] v0.6.0` entry.

### Deviations

- `[scope]` **`RUN_OUTPUT_OPENAI.md` regenerated and `RUN_OUTPUT_ELEVENLABS.md` created**, although the Module Tree lists neither. 26.9.3 makes regeneration conditional on a clean full run ("There is no `RUN_OUTPUT_ELEVENLABS.md` unless the run is clean"); both arms ran clean, and each file is that run's captured stdout verbatim (the exit-code line the wrapper appended is dropped). `RUN_OUTPUT_ANTHROPIC.md` and `RUN_OUTPUT_GEMINI.md` are untouched: those arms were not run. Neither file contains key material (`grep -lF "$ELEVENLABS_API_KEY"` / `"$OPENAI_API_KEY"` over `examples/RUN_OUTPUT_*.md`, keys from `.env` in a subshell → exit 1).
- `[scope]` **No `CHANGELOG` breaking-change line for `:unsupported_feature`.** Both error modules are new since `v0.5.0` (`git show v0.5.0:lib/allm/error/speech_adapter_error.ex` → does not exist), so relative to the prior tag the reason is part of a new enum, not an extension. Derived from `git diff v0.5.0..HEAD lib/`, per the release rule; the Phase 26 lines are the `7499917..HEAD` part of that diff (the image-variation removal at `7499917` was already in the entry).
- `[scope]` **`ExamplesHelpers.provider_rows/0`** (`@doc false`) is new: the Test Plan's row-shape assertions need the table, and `@providers` had no accessor.
- `[scope]` **`chat_provider?/1` raises `ArgumentError` for an unknown provider**, so `run_all.exs` with a bad `ALLM_PROVIDER` fails at the first marker-less script instead of running each one to its own raise.
- `[tactical]` The example scripts' telemetry handlers are module functions with the parent pid as config, not closures: `:telemetry` logs an info line for a local-function handler, which the first live run showed.
- `[scope]` §37.11 carries the Error Contract, grammar and invariants in the spec rather than pointing at the design, so the spec stays the source of truth for module behaviour (CLAUDE.md "Where things live").

### Provider claims published by the guide and spec (CLAUDE.md docs-sub-phase rule)

Confirmed = observed by a recorder arm or a logged exploratory call (RECORDS §26.5–§26.8 transcripts, or this phase's live runs). Inferred = from provider docs or reasoning only.

| Claim | Where | Status |
|-------|-------|--------|
| ElevenLabs voices are ids, sent in the URL path | guide, §37.7.4 | confirmed (`tts_default`) |
| `JBFqnCBsd6RMkjVDRZzb` answers | guide, §37.7 | confirmed (`tts_default`, and both live arms today) |
| it is the voice ElevenLabs' quickstart uses / a permanent premade voice | guide | inferred (docs; the key lacks `voices_read`, so `category` was not read) |
| `GET /v1/voices` lists an account's voice ids | guide | inferred (docs; the call returned 401 `missing_permissions` for this key) |
| an unknown voice is `:invalid_request` | guide | confirmed (`bad_voice` 404; `ws_bad_voice` `voice_id_does_not_exist`) |
| `eleven_flash_v2_5` is the low-latency model; `eleven_multilingual_v2` higher quality and slower | guide | inferred (docs) |
| realtime accepts only `scribe_v2_realtime`; batch and realtime names disjoint | guide, §37.11.4 | inferred (docs); `scribe_v2_realtime` working is confirmed (`rt_*`) |
| ElevenLabs STT sniffs content; no filename gate | guide, §37.7.4 | confirmed (`stt_audio_bin`) |
| STT limit "less than 5.0 GB" | guide, §37.7.4 | inferred (docs; not probed) |
| 40,000 (flash) / 5,000 (`eleven_v3`) character limits | guide, §37.7.4 | inferred (docs); the v3 figure is contradicted by a billed 200 at 5,001, which both documents state |
| `text_too_long` → `:context_length_exceeded` | guide, §37.7.4 | inferred (docs; synthesized fixture only) |
| no ElevenLabs field for `instructions` / `prompt`; no AAC/FLAC output | guide, §37.2.5 | inferred (docs) |
| OpenAI PCM/WAV are 24 kHz only | guide, §37.2.5, §37.11.2 | inferred (OpenAI TTS guide; the rate is not on the wire) |
| OpenAI text-in streaming is its Realtime API | guide, §37.7 | inferred (docs) |
| OpenAI streams raw chunked audio on `/v1/audio/speech`; first bytes 1,728 ms / 1,353 ms | guide, §37.11.8 | confirmed (`stream_chunked`, `stream_mp3_tts1`) |
| ElevenLabs `/stream` is raw chunked audio; first 425 ms | guide, §37.11.8 | confirmed (26.7 `stream_chunked`) |
| `auto_mode` first audio 238 ms against 563 ms | guide, §37.11.9, CHANGELOG | confirmed (one run each, `ws_tokens*`) |
| `auto_mode` voices each message as its own clip | guide, §37.11.9 | confirmed (alignment in `ws_tokens_auto_mode`) |
| the default schedule waits for about 120 characters | guide | inferred (documented `chunk_length_schedule` `[120,160,250,290]`) |
| unknown body / init / query fields are ignored | guide, §37.7.4 | confirmed (`control`, `stt_control`, `ws_control`, `rt_control`) |
| `request-id` and `character-cost` on TTS; no `request-id` on STT | guide, §37.7.4 | confirmed |
| `usage` is all-`nil` (no billing field) | guide, §37.7.4 | confirmed (bodies recorded) |
| `eleven_v3` refused on `/stream-input` at the upgrade | guide, §37.11.9 | confirmed (`ws_v3`) |
| out-of-credit / quota is `:invalid_request` | guide, §37.7.4 | inferred (documented codes; never observed) |
| a quota error may arrive as a 401 | design Error classification | inferred, still `UNVERIFIED` (no quota state reachable) |
| 44.1 kHz PCM is tier-gated (403) | guide, §37.7.4 | confirmed for `pcm_44100` (`tier_gate`); WAV 44.1 kHz inferred |
| data-residency hosts | guide, §37.7.4 | inferred (docs) |
| `output_format` values in the format table | guide, §37.7.4 | confirmed: `mp3_44100_128`, `mp3_24000_48`, `pcm_24000`, `wav_24000`, `opus_48000_64`; the other rates inferred (docs) |
| ElevenLabs accepts `?authorization=` on the WebSocket | §37.11.8, CLAUDE.md | inferred (docs; never used) |
| unpaced upload accepted | guide, §37.11.9 | confirmed (`rt_fox`, today's example 26: 38 chunks) |
| partials can follow their segment's commit | guide, §37.11.9 | confirmed (`rt_fox`) |
| a commit under 0.3 s is refused with `commit_throttled` + close | guide, §37.11.9 | confirmed (`rt_end`) |
| language needs `include_timestamps` + `include_language_detection` | guide, §37.11.9 | confirmed for both-on and timestamps-only (language `null`); detection alone inferred (not tried) |
| timestamped and plain frames arrive in either order | guide, §37.11.9 | confirmed (4 logged segments) |
| realtime language ISO 639-1, batch ISO 639-3 | guide, §37.7.4 | confirmed (`rt_fox` `"en"`, `stt_default` `"eng"`) |
| a bad key upgrades with 101, then an error frame | guide, §37.11.9 | confirmed (`ws_bad_key`, `rt_bad_key`) |
| 1,000 ms and 3,000 ms realtime chunks accepted | §37.11.9 | confirmed (`rt_big_chunk`; 3,000 ms exploratory) |
| the server does not close after the final commit | §37.11.9 | confirmed (exploratory) |

### Live gates (run 2026-09-27, subshell form, keys from `.env`)

- **BLOCKING** `( set -a; . ./.env; set +a; ALLM_PROVIDER=elevenlabs mix run examples/run_all.exs )` → **exit 0**, run twice (the second after the handler tidy-up, and it is the snapshot). Per script: `01`–`21` SKIP (no chat adapter or marker), `23` OK (mp3, `audio/mpeg`, 44,765 bytes), `24` OK (`scribe_v2`, "The quick brown fox jumps over the lazy dog", 3.72 s), `25` OK (58 deltas, first chunk 434 ms), `26` OK (`scribe_v2_realtime`, 38 chunks, 3 partials, 1 committed segment), `27` OK (heard the fox sentence, 7 reply deltas, first partial 709 ms, first reply audio 1,117 ms). Scripts 23–27 print `OK:`.
- **openai arm** `( set -a; . ./.env; set +a; ALLM_PROVIDER=openai mix run examples/run_all.exs )` → **exit 0**, full run: `01`–`12` OK, `14`–`21` OK, `23` OK, `24` OK, `25` OK (14 deltas, first chunk 995 ms), `26`–`27` SKIP (marker). No script halted, so there is no blocked arm to re-characterize.
- Spend: ElevenLabs two arm runs, each about 44 + 83 + ~60 characters of flash plus ~7.5 s of STT (well under $0.05); OpenAI one full arm (image scripts dominate, as before).

### Verification (run 2026-09-27, working tree on `977cb9f`)

| Check | Result |
|-------|--------|
| `mix test` | exit 0; 601 doctests, 33 properties, 4906 tests, 0 failures, 14 excluded, 1 skipped (26.8: 593 / 33 / 4902; +8 doctests from `guides/audio.md`, +4 tests in `examples_helpers_test.exs`) |
| `mix test --seed 0` | exit 0; same counts |
| `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer` | exit 0; "found no issues"; `Total errors: 0` |
| `mix docs 2>&1 \| grep -ciE 'warning\|error'` | 0 |
| `mix test test/guides_test.exs test/guides_doctest_test.exs` | 64 doctests, 62 tests, 0 failures |
| `mix run scripts/check_guide_fences.exs` | exit 0; `73 fences compiled, 14 skipped.` (corrected 2026-09-27 in the 26.9 fix pass; this row first read "72 … (67 before; `guides/audio.md` 6 fences, 5 new)", none of which reconciled. Re-measured: `mix run scripts/check_guide_fences.exs \| head -1` → `73 fences compiled, 14 skipped.`; `git show 977cb9f:guides/audio.md \| grep -c '^```elixir'` → 3 and `grep -c '^```elixir' guides/audio.md` → 7, so 4 new fences; summing `grep -c '^```elixir'` over `$(grep -oE 'guides/[a-z_]+\.md' mix.exs \| sort -u)` → 83 at `977cb9f` and 87 now, with `grep -c 'fence-check: skip'` summed over the same set → 14 at both, so 69 compiled before and 73 after; only `guides/audio.md` changed) |
| `mix run scripts/audit_user_docs.exs guides/audio.md` / `CHANGELOG.md` | "No banned-token matches" each |
| async grep (`grep -rl 'Keys.put(\|Logger.configure(\|System.put_env(\|:telemetry.attach' test/ \| xargs grep -L 'async: false' \| wc -l`) | 12, unchanged; the modified test uses none of the four |
| `mix hex.build --output <scratchpad>` + `tar -tzf contents.tar.gz` | builds `allm 0.5.0` with `mint_web_socket ~> 1.0`; all 14 `docs[:extras]` files are in the tarball; the tar was deleted. The pre-existing root `allm-0.4.3.tar` / `allm-0.5.0.tar` were not touched (built to the scratchpad to avoid overwriting `allm-0.5.0.tar`) |
| `conformance/` | not touched; not run |
| `README.md` | not modified |

### Fix pass (2026-09-27, reviews under `.work/*/2026-09-26-phase-26-9*`)

- F1/F2: `CHANGELOG.md` and the `guides/audio.md` provider table gave the adapters the façade arity; the adapters are `synthesize/2`, `stream_synthesize/2`, `transcribe/2`, `stream_synthesize_input/3`, `stream_transcribe/3` (`grep -n "^  def \(synthesize\|stream_synthesize\|transcribe\|stream_transcribe\|stream_synthesize_input\)(" lib/allm/providers/*/speech.ex lib/allm/providers/*/transcription.ex`).
- F4: CHANGELOG's "first bundled provider with no chat adapter" was false (Voyage); now "Like Voyage, ElevenLabs has no chat adapter".
- F3: the guide's language bullet now says *either* option turns on the hold (`@hold_options`, `lib/allm/providers/elevenlabs/transcription.ex:44`, `:1011`).
- F5: the WAV reader duplicated in scripts 26/27 is `ExamplesHelpers.read_pcm_wav!/1` + `pcm_chunks/3`; `test/allm/examples_helpers_test.exs` pins the fixture at 24,000 Hz / 182,400 bytes / 38 chunks.
- F6: a self-skip now exits `ExamplesHelpers.skip_exit_status/0` (3) via `ExamplesHelpers.skip!/1`; `run_all.exs` prints `[SKIP] <script> (self-skipped)` and does not count it as a failure. Exercised with two probe scripts in a scratch copy of `run_all.exs` (`[SKIP] 98_probe_skip.exs (self-skipped)`, `[OK] 99_probe_ok.exs`, exit 0). No prior script used a self-skip, so there was no convention to align with.
- F7: both "marker absent → every provider" comments in `run_all.exs` now say every *chat* provider.
- C1: the fence-count row above is corrected in place.
- Live: `( set -a; . ./.env; set +a; ALLM_PROVIDER=elevenlabs mix run examples/run_all.exs )` exit 0, `01–12, 14–21 SKIP (provider gate), 23–27 OK`; `examples/RUN_OUTPUT_ELEVENLABS.md` regenerated from that run's stdout. OpenAI arm untouched and not re-run.

## Phase 26.10 — `[CHORE]` sweep

Built 2026-09-27 on `977cb9f`, in the same working tree as 26.9.

- [x] `steering/2026-09-24_SST_SUPPORT.md`: one pointer line under Alternative D ("Decided in Phase 26 …").
- [x] `.work/ASKS.md`: the `ulaw`/`alaw` `[FEATURE]` ticket filed (sun 9/27 12pm; predicate `grep -n ':ulaw' lib/allm/speech_request.ex` must match; today exit 1), and a `[DISPOSITION]` line re-running every Phase 26 ticket's predicate.
- [x] **Every ticket this phase filed is closed or carries a grep predicate.** Re-run today from the repo root:
  - sat 9/26 8pm HTTP-helper variants — `grep -roE 'defp (provider_message|redact_optional|sanitize_cause)\(' lib/allm/providers/ | sort -u | cut -d: -f2 | sort | uniq -c | awk '$1>1'` → `provider_message` 5, `redact_optional` 4, `sanitize_cause` 6. Open (the 3 → 4 rise is 26.6's per-provider ElevenLabs redactor variant, recorded there).
  - sat 9/26 9pm FakeSpeech `{:ok, ""}` `[BUG]` — `MIX_ENV=test mix run -e '…elem(0))'` → `:ok`. Open.
  - sat 9/26 9pm chat-stream `[CARRY]` — first grep: `anthropic.ex:1485`, `gemini.ex:1355`, `openai.ex:839`; second grep: `gemini.ex`, `anthropic.ex`, `openai.ex`. Open. It was never routed into 26.10's Module Tree (no `(MODIFY — 26.10)` amendment exists in this file), so the released chat adapters are not touched here.
  - sun 9/27 2am stringify `[DEFERRED-DRY]` — `… | wc -l` → 4. Open.
  - Closed tickets stay closed: the 26.1 transcription predicate prints nothing (exit 0 from `awk`, empty output), and the speech DRY ticket was closed in 26.6.
- [x] **HANDOFF DONE-WHEN guards** re-run: pump-protocol guard → empty, exit 1; `grep -rnE "defp? await\(|receive do" lib/allm/providers/elevenlabs` → empty, exit 1; `grep -rn "defp await(%{pump:" lib/allm/providers | wc -l` → 0; every `assert_receive {^ref, {:input_error` in `input_pump_test.exs` carries `1_000`.
- [x] **`UNVERIFIED` rows.** `grep -c UNVERIFIED steering/2026-09-25_ELEVENLABS_TTS_SST.md` → 13 (12 before this sweep's correction line, which contains the word). The predicate counts a token that settled rows keep (corrections are blockquotes beneath the row, never rewrites), so the design carries a dated CORRECTED line under its checklist item, and this table is the check:

  | Design line (at `977cb9f` + this sweep) | Hit | Disposition |
  |---|---|---|
  | :52 | Assumption 4 ("doc-sourced until the probes run") | settled: every probe it names ran (26.6–26.8) |
  | :252 | Decision #10, default voice "permanent premade" | settled that it answers (CORRECTED 2026-09-26 beneath); permanence **still unverified** — the key cannot read `category` |
  | :616 | HTTP map, default voice | settled (26.6 CORRECTED under the HTTP map) |
  | :618 | 200 content-type | settled (same) |
  | :619 | correlation headers | settled (same) |
  | :620 | unknown body field | settled (same) |
  | :621 | HTTP stream framing | settled (26.7 CORRECTED under the HTTP map) |
  | :629 | key-redaction prefix | settled (26.6 CORRECTED) |
  | :671 | WS error frames | settled (26.7 CORRECTED under the WS map) |
  | :699 | realtime pacing | settled (26.8 CORRECTED) |
  | :720 | quota reportedly as 401 | **still unverified**: no quota state is reachable without exhausting the account |
  | :1358 | the 26.10 checklist line | not a row |
  | :1360 | this sweep's CORRECTED line | not a row |

  Still unprobed and not marked `UNVERIFIED` in the design: the 5 GB STT cap ("not probed" in the HTTP map).

### Notes

- Nothing in 26.10's tree touches `lib/` or `test/`: no `[CARRY]` was routed to it.
