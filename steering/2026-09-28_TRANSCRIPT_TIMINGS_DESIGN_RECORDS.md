# Phase 28 transcript spans — Records

Companion bookkeeping for `steering/2026-09-28_TRANSCRIPT_TIMINGS_DESIGN.md`. The design doc's own Status table is not updated; this file is the status of record.

## Status

| Phase | Status |
|-------|--------|
| 28.1 | Completed (2026-09-28) — reviews: .work/{reviews,code-reviews,security-reviews}/2026-09-28-transcript-timings-28-1 |
| 28.2 | Not Started |
| 28.3 | Not Started |
| 28.4 | Not Started |
| 28.5 | Not Started |
| 28.6 | Not Started |
| 28.7 | Not Started |

## 28.1 Layer A: span struct, flags, response field, event constructors

Built against `d3bcb3b` (HEAD at start; no citation drift found — every cited site located by content at the cited lines).

### Checklist

- [x] `lib/allm/transcript_span.ex` per contract, `@moduledoc` examples, 0 banned tokens (`mix run scripts/audit_user_docs.exs lib/allm/transcript_span.ex` → "No banned-token matches").
- [x] Both request structs: fields, `@type`, `@moduledoc` field bullets, `__from_tagged__/1` (`data["…"] || false`).
- [x] `TranscriptionResponse`: `:spans`, type, `hydrate_spans/1` (replaced by `Serializer.hydrate/1` in the 28.1 fix pass — see Fix pass below), `mean_logprob/1` with doctest; "stay on `:raw`" sentence replaced.
- [x] `TranscriptionEvent`: `committed/0` and `completed/0` types (optional `:spans`), `committed_transcript/3` with its own `@doc` + doctest, moduledoc bullets; `@completed_keys` unchanged.
- [x] `Validate`: `{:timestamps | :logprobs, :invalid_shape}` on both validators + doc lines (new private `validate_boolean_field/3`).
- [x] Registrations: `Serializer` `@known_modules`, `test/layer_a_docs_test.exs` `@layer_a`, `mix.exs` `groups_for_modules` (beside `ALLM.TranscriptionResponse`), both façade allow-lists, stream test `@field_values`.

### Verification (2026-09-28)

- Targeted (the 28.1 block's first command): `23 doctests, 208 tests, 0 failures`.
- `mix compile --warnings-as-errors --force` → exit 0.
- `mix test > "$SP/28_1.log" 2>&1` → `exit=0`; `682 doctests, 33 properties, 5532 tests, 0 failures, 14 excluded, 1 skipped` (baseline at `d3bcb3b`: 676 doctests, 5497 tests).
- `mix test --seed 0` → exit 0, same counts.
- `mix credo --strict` → exit 0, "found no issues". `mix dialyzer` → exit 0, "Total errors: 0". `mix format --check-formatted` → exit 0.
- Mutation check: removing `:timestamps, :logprobs` from both façade allow-lists turned `allm_transcribe_test.exs` / `allm_stream_transcribe_test.exs` red (`2 failures`, `:logprobs … not reachable`, `:logprobs did not reach the request`); restored.
- `mix docs` emits two warnings, both about `ALLM.SpeechAdapter.synthesize/2` in speech docs outside this phase; none from 28.1 files.

### Deviations (all tactical)

1. **`mean_logprob/1` doctest values.** The design's falsifier `[word -0.2, spacing -0.2, word -0.4] → -0.3` is not exact in IEEE floats (`(-0.2 + -0.4) / 2 == -0.30000000000000004`). The doctest uses binary-exact `-0.25 / -0.25 / -0.5 → -0.375`; the design's falsifier is kept verbatim in `test/allm/transcription_response_test.exs` with `assert_in_delta … 1.0e-9`, which still separates `-0.3` from the spacing-included `-0.2667`.
2. **Façade `@doc` option enumerations.** `ALLM.transcription_request/2`'s "Only … field names are read" list and `ALLM.stream_transcribe/3`'s "Input shapes" list enumerate the allow-lists verbatim, so both gained `:timestamps`, `:logprobs` with the allow-list edit to stay true. The "Timings and log-probabilities" `@doc` paragraph remains 28.6's.
3. **`TranscriptSpan.__from_tagged__/1`** maps a missing or non-string `"kind"` to `:other` as well as an unknown string (contract names only the unknown-string case); pinned by a test. `new/1` takes no `\\ []` default, since both required keys make a zero-arg call meaningless (contract `@spec new(keyword())` unchanged).
4. **`committed_transcript/3` has its own `@doc`** (the design shows one constructor block); ExDoc attaches `@doc` per arity, so a shared block would have left `/3` undocumented.

### Fix pass (2026-09-28)

Inputs: `.work/reviews/2026-09-28-transcript-timings-28-1/overview.md`, `.work/code-reviews/2026-09-28-transcript-timings-28-1.md`, `.work/security-reviews/2026-09-28-transcript-timings-28-1.md` (clean), design review N/A.

- **Malformed persisted `"spans"` no longer raises out of `Serializer.from_json/1`** (functional F1 Low, code-review F1 Medium, security informational — same site; taken at Medium because `from_json/1`'s `@spec` promises `{:ok, _} | {:error, _}`). `hydrate_spans/1` deleted; `__from_tagged__/1` calls `Serializer.hydrate(data["spans"])`, which is behaviour-equivalent for `nil` (→ `nil`) and lists (`Enum.map(&hydrate/1)`) and passes any other value through, like the sibling `hydrate_usage(other)`. Pinned by `test/allm/transcription_response_test.exs` "a malformed persisted \"spans\" passes through…" (`%{}`, `"oops"`, `%{"a" => 1}` → `{:ok, _}`, `mean_logprob/1 == nil`).
- **[structural, documented]** `validate_embedding_truncate/2` migrated onto `validate_boolean_field/3` (`lib/allm/validate.ex`, embedding rule chain) per `agent-spec/IMPLEMENTATION.md` "Migration on extraction". Private, behaviour-preserving (same `{:truncate, :invalid_shape}` tuple), no public name changed; pinned by `test/allm/validate_embedding_request_test.exs:62-64` and `:100-108`. Code-review F2.
- Gates after fix: `mix test > $SP/full.log` → `exit=0`, `682 doctests, 33 properties, 5533 tests, 0 failures, 14 excluded, 1 skipped`; `mix test --seed 0` → same, exit 0; `mix credo --strict` → exit 0, "found no issues"; `mix format --check-formatted` → exit 0; `mix dialyzer` → exit 0, "Total errors: 0".
- Functional F2 (request `@moduledoc`'s `:unsupported_feature` refusal is ahead of the code until 28.5; sentence also omits the post-I/O `cause: :absent_from_response` case) routed to `.work/HANDOFF.md` and to Notes below.

### Notes for later sub-phases

- `TranscriptionResponse.mean_logprob/1` tolerates non-`%TranscriptSpan{}` list elements (a hand-edited JSON payload can hydrate an untagged map) by skipping them.
- The façade allow-lists now drop `:timestamps` / `:logprobs` from dispatch opts (`Keyword.drop` at the `@transcription_*_field_opts` sites), so 28.2's façade pass-through tests should assert them on the request, not on `opts`.
- **Release gate + doc widening (functional F2, 28.1).** `lib/allm/transcription_request.ex`'s `@moduledoc` says an adapter that cannot honour a `true` flag refuses with `:unsupported_feature` "before sending anything"; no adapter reads either flag until 28.2 (`gate_flags/4`) / 28.4–28.5, so no release may be cut from a 28.1–28.4 tree (`grep -rn 'gate_flags\|\.timestamps\|\.logprobs' lib/allm/providers/` → empty at 28.1). 28.6's doc pass widens the sentence to cover the post-I/O `:unsupported_feature` (`cause: :absent_from_response`).
