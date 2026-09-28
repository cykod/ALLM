# Phase 28 transcript spans — Records

Companion bookkeeping for `steering/2026-09-28_TRANSCRIPT_TIMINGS_DESIGN.md`. The design doc's own Status table is not updated; this file is the status of record.

## Status

| Phase | Status |
|-------|--------|
| 28.1 | Completed (2026-09-28) — reviews: .work/{reviews,code-reviews,security-reviews}/2026-09-28-transcript-timings-28-1 |
| 28.2 | Completed (2026-09-28) — reviews: .work/{reviews,code-reviews,security-reviews}/2026-09-28-transcript-timings-28-2 |
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

## 28.2 Shared helpers, Fake, collector, equivalence

Built against `39d2227` (28.1 commit). Cited sites located by content: `build_response/3`, `interpret_entry`, `segment_events/2`, `on_input_done`, `stream_entry_events` in `lib/allm/providers/fake_transcription.ex`; `transcription_step({:transcription_completed, _}, _)` in `lib/allm/audio_stream.ex`; `with_own_cap/2` in `lib/allm/providers/support/transcription_adapter.ex`.

### Checklist

- [x] Three shared helpers + tests — `span_from/6`, `gate_flags/4`, `with_span_flags/2` (`@doc false` + `@spec`), `test/allm/providers/support/transcription_adapter_test.exs:223` (`describe "span helpers"`, 6 tests: four flag cells × both request structs, non-`true` values off, refusal order, provider `nil` + `request_id` in metadata, `with_span_flags/2` round-trip).
- [x] Fake gate, span builder, four call sites, `@moduledoc` table rows + "Span flags" section with two doctests; `transcribe/2` `@doc` gate list gains step 4, `stream_transcribe/3` `@doc` names the span gate. Tests `test/allm/providers/fake_transcription_test.exs:511`, `:563`, `:632` (32 tests).
- [x] Collector build (`spans: Map.get(completed, :spans)`) + doc paragraph with doctest; `test/allm/audio_stream_test.exs:177` (4 tests, incl. committed `/3` not folded).
- [x] Two behaviour moduledocs: `ALLM.TranscriptionAdapter` invariant 10, `ALLM.TranscriptionStreamAdapter` invariants 9–11.
- [x] Equivalence property widened (`timestamps`/`logprobs` booleans; the word list already reached `[]`, so empty text was already generated) and `:spans` compared with no relaxation; moduledoc says so. Absolute-shape pins `test/allm/audio_stream_equivalence_property_test.exs:194` (IMPLEMENTATION.md 4m).
- [x] Façade pass-through: `test/allm/allm_transcribe_test.exs:312`, `test/allm/allm_stream_transcribe_test.exs:356` (assert on the captured request and the returned spans, not on dispatch opts — 28.1 carried fact).

### Verification (2026-09-28)

- Targeted (the 28.2 block's first command): `20 doctests, 2 properties, 191 tests, 0 failures`.
- `mix compile --warnings-as-errors` → exit 0.
- `mix test > "$SP/28_2.log" 2>&1` → `exit=0`; `685 doctests, 33 properties, 5575 tests, 0 failures, 14 excluded, 1 skipped` (baseline at `39d2227`: 682 doctests, 5533 tests).
- `mix test --seed 0` → exit 0, same counts.
- `mix credo --strict` → "found no issues". `mix dialyzer` → "Total errors: 0". `mix format --check-formatted` → exit 0.
- `(cd conformance && mix test && mix credo --strict && mix format --check-formatted)` → `206 tests, 0 failures, 1 skipped`; credo "found no issues"; format exit 0.
- `mix run scripts/audit_user_docs.exs <file>` → "No banned-token matches" on each of the five modified `lib/` files.
- `mix docs` → the same two pre-existing `ALLM.SpeechAdapter.synthesize/2` warnings as 28.1; none from 28.2 files.
- Mutation table (each run `--max-failures 1 --timeout 5000` or file-scoped; file restored and `cmp`-verified after):

| Mutant | Binding test | Result |
|---|---|---|
| Fake batch: span-flag gate moved after `resolve_script/1` | `fake_transcription_test.exs:633` (cursor unchanged after refusal) | red (1 failure) |
| Fake stream: completed `:spans` drops the last span | property + `audio_stream_equivalence_property_test.exs:194` | red (2 failures) |
| Fake: flags-off committed/completed carry `spans: nil` instead of omitting the key | `fake_transcription_test.exs:563` flags-off cells (`refute Map.has_key?`) | red (7 failures) |

### Deviations (all tactical)

1. **[tactical] Fake span gate is its own `gate_span_flags/2` step in each `with` chain**, not a line inside `gate/2` / `gate_sample_rate/2`. Same position the design requires (after the audio / sample-rate gate, before `resolve_script/1`); `gate/2` and `gate_sample_rate/2` do not take `opts`, which `gate_flags/4` needs for `request_id` metadata.
2. **[tactical] `gate_flags/4` message** is provider-neutral (`"timestamps: true is not supported by this transcription adapter"`); the design specifies only the reason/provider/metadata shape.
3. **Scripted `%TranscriptionResponse{}` on the stream path with non-`nil` `:spans` emits `:spans` whatever the flags** (design 28.2 bullet, read literally). This is a second Fake exception beside decision 3's batch one; both behaviour moduledocs name it so streaming invariant 11 stays true.

### Fix pass (2026-09-28)

Inputs: `.work/reviews/2026-09-28-transcript-timings-28-2/overview.md`, `.work/code-reviews/2026-09-28-transcript-timings-28-2.md`, `.work/security-reviews/2026-09-28-transcript-timings-28-2.md` (clean), design review N/A.

- **Literal `0.0` patterns removed** (functional F1 Medium, single reporter; re-measured: `grep -n '0\.0' test/allm/allm_transcribe_test.exs test/allm/allm_stream_transcribe_test.exs` → `:326` and `:369`, both inside `assert [...] =` patterns). Both now `start_seconds: +0.0`. The Verification block above ran `mix compile --warnings-as-errors`, which compiles `lib/` only and could not see test-file warnings; the code review's "no literal `0.0` patterns" positive note was wrong for the same two sites.
- **`flag_on?/2` + `spans_requested?/1`** (`@doc false` + `@spec`) added to `Support.TranscriptionAdapter` as the single definition of "a flag counts only when exactly `true`"; `gate_flags/4`, `span_from/6` and `FakeTranscription.fake_spans/2` now call them (code-review F2). Pinned by `test/allm/providers/support/transcription_adapter_test.exs` "flag_on?/2 and spans_requested?/1 count a flag only when it is exactly true".
- **`put_adapter_opt/3`** (`@doc false` + `@spec`) extracted; `with_own_cap/2` and `with_span_flags/2` are one-line delegates, names kept (code-review F1, in-fence part). ElevenLabs' private `with_own_rates/1` (`lib/allm/providers/elevenlabs/transcription.ex`) is NOT migrated here — left for 28.4, which owns that file (see Notes below). Pinned by "put_adapter_opt/3 sets one adapter opt and keeps the rest" plus the existing `with_span_flags/2` / `with_own_cap/2` tests.
- Gates after fix: `mix test > $SP/full.log` → `exit=0`, `685 doctests, 33 properties, 5577 tests, 0 failures, 14 excluded, 1 skipped`, `grep -c 'warning:' $SP/full.log` → 0; `mix test --seed 0` → exit 0, same counts; `mix credo --strict` → "found no issues"; `mix format --check-formatted` → exit 0; `mix dialyzer` → "Total errors: 0"; `(cd conformance && mix test)` → `206 tests, 0 failures, 1 skipped`.

### Notes for later sub-phases

- **28.4/28.5 decoders choose `nil` vs a list with `Support.spans_requested?/1`** and test individual flags with `Support.flag_on?/2` — never a truthiness check (`if request.logprobs`), which would accept `"yes"`/`1`.
- **28.4 migrates ElevenLabs' private `with_own_rates/1` onto `Support.put_adapter_opt/3`** as a `[structural, documented]` deviation (IMPLEMENTATION.md "Migration on extraction": private, behaviour-preserving, no public name change). Deferred from the 28.2 fix pass because that file is 28.4's.
- No real adapter calls `gate_flags/4` or `with_span_flags/2` yet: `grep -rn 'gate_flags\|with_span_flags\|span_from' lib/allm/providers/ | grep -v support/transcription_adapter.ex` → only `fake_transcription.ex:300` and `:492`. So a scripted `OpenAI.Transcription` call with `timestamps: true` still returns timed spans until 28.5 wires the hand-off; the `TranscriptionRequest` moduledoc's pre-I/O refusal sentence and the new behaviour invariants are obligations the bundled real adapters meet only from 28.4/28.5 (release gate unchanged — `.work/HANDOFF.md` item stays Open).
- The Fake's per-word times are `i * 0.5`, so word 0 has `start_seconds: 0.0` (a float from `0 * 0.5`); a test that pattern-matches it writes `+0.0` (as `allm_transcribe_test.exs:326` / `allm_stream_transcribe_test.exs:369` do after the 28.2 fix pass) or compares with `==` — a literal `0.0` pattern warns on OTP 27+, and `mix compile --warnings-as-errors` does not compile tests, so check `grep -c 'warning:'` on the full-suite log.

