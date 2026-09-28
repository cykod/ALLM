# Phase 28 transcript spans — Records

Companion bookkeeping for `steering/2026-09-28_TRANSCRIPT_TIMINGS_DESIGN.md`. This file is the status of record; the design doc's own Status table was synced to it once, in the polish pass below.

## Status

| Phase | Status |
|-------|--------|
| 28.1 | Completed (2026-09-28) — reviews: .work/{reviews,code-reviews,security-reviews}/2026-09-28-transcript-timings-28-1 |
| 28.2 | Completed (2026-09-28) — reviews: .work/{reviews,code-reviews,security-reviews}/2026-09-28-transcript-timings-28-2 |
| 28.3 | Completed (2026-09-28) — reviews: .work/{reviews,code-reviews,security-reviews}/2026-09-28-transcript-timings-28-3; no fix pass needed (two Lows: one carried to polish, one recorded in Notes for 28.4 / 28.5) |
| 28.4 | Completed (2026-09-28) — reviews: .work/{reviews,code-reviews,security-reviews}/2026-09-28-transcript-timings-28-4; live gate: 01–21 SKIP, 23–26 OK, 27 FAIL on ElevenLabs account TTS quota (external, not a code defect — see §28.4) |
| 28.5 | Completed (2026-09-28) — reviews: .work/{reviews,code-reviews,security-reviews}/2026-09-28-transcript-timings-28-5; live gates: openai `exit=0` (second run; first run's 25 timed out, see §28.5), gemini `exit=0`; snapshots regenerated before the behaviour-preserving fix-pass decoder extraction |
| 28.6 | Completed (2026-09-28) — reviews: .work/{reviews,code-reviews,security-reviews}/2026-09-28-transcript-timings-28-6 (batch shared with 28.7) |
| 28.7 | Completed (2026-09-28) — reviewed in the 28.6 batch (slug 2026-09-28-transcript-timings-28-6) |

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

## 28.3 Live wire probes (scripts + fixtures)

Built against `5f31a0c` (28.2 commit). No `lib/` change. Cited recorder sites located by content: `halt_unless_all_ok/1` and `pending?/1` in all three recorders; the Gemini top-level control arm; `put_generation_config/2` in `lib/allm/providers/gemini/transcription.ex` (the G0/G1 bodies go through the adapter's own `to_json_body/2` with `options` → `generationConfig`).

### Checklist

- [x] Arms E1–E3 in `scripts/record_elevenlabs_audio_fixtures.exs`, O1–O4 in `scripts/record_openai_audio_fixtures.exs`, G0–G1 in `scripts/record_gemini_audio_fixtures.exs`. G2 is not added: Gemini took the refuse branch (decision 2 below).
- [x] Two passes, as the design requires. Pass 1 recorded O1, O2, G0, G1 and E1–E3. Then the OpenAI spelling was hard-coded (`@logprobs_include`, with a comment citing both O1/O2 fixtures) and the Gemini branch was hard-coded (G0/G1 comment citing both fixtures). Pass 2 recorded O3 and O4.
- [x] O1/O2 cross-arm halt: `logprobs_spelling_check/1` (runs when both arms are pending) halts if neither spelling returns a `logprobs` list.
- [x] Discovery arms tightened to their observed outcomes after recording, the convention every earlier arm in these recorders follows ("tightened to its observed outcome"): O1/O3 `:require`, O2 `:absent`, O4 `:absent_silent`, G0/G1 `expect: [400]` with message checks, E3 `words == []` and blank text, E2 `time_base == "session"`. The tightened verdicts were replayed against the recorded bodies in a scratch copy (verdicts made public, no live calls): 13/13 accept. Four negative controls each reject: O1's body under `:absent_silent`, G0's body as G1, E1's body as E3, and E2 with one twin dropped. A time-shifted E2 twin computes `"segment"`.
- [x] Provenance: each new fixture is in the `@recorded` list of its test file. That puts it in the existing per-file raw-byte `refute Map.has_key?(raw, "_comment")` loop, whose failure message names the recorder invocation, and in the `@recorded enumerates every file under recorded/` meta-test. Files: `test/allm/providers/{elevenlabs,openai,gemini}/transcription_wire_test.exs` and `test/allm/providers/elevenlabs/transcription_stream_test.exs`. Mutation: a planted `_comment` in `silence.json`, `rt_two_segments.json`, `logprobs_silence.json` and `probe_logprobs.json` turns each file's suite red (1 failure each); each fixture was restored and `cmp`-verified.

### Per-arm observations (2026-09-28)

| Arm | Status | Observation | Fixture |
|---|---|---|---|
| E1 | 200 | 17 `words`, types `word`/`spacing`, each with numeric `start`/`end`/`logprob` and a binary `text` | `test/fixtures/elevenlabs/transcriptions/recorded/words_explicit.json` |
| E2 | 101 | 3 `committed_transcript` and 3 `committed_transcript_with_timestamps` frames, trimmed texts equal pairwise. Segment 1 words run 0.1–3.44 s and segment 3 words start at 4.9 s, so `time_base: "session"`. The empty middle segment's twin has `"words": null` and `"language_code": null` and arrived **before** its committed frame (frame order: committed, twin, twin, committed, committed, twin) | `test/fixtures/elevenlabs/realtime/recorded/rt_two_segments.json` |
| E3 | 200 | `words: []`, `text: ""`, `language_probability: 0.0` | `test/fixtures/elevenlabs/transcriptions/recorded/silence.json` |
| O1 | 200 | top-level `logprobs`: 10 entries `{token, logprob, bytes}` (`bytes` is an int list) | `test/fixtures/openai/transcriptions/recorded/logprobs_include_brackets.json` |
| O2 | 200 | no `logprobs` key (bare `include` silently ignored) | `test/fixtures/openai/transcriptions/recorded/probe_logprobs_include_bare.json` |
| O3 | 200 | `gpt-4o-mini-transcribe` + `include[]`: 10 `logprobs` entries | `test/fixtures/openai/transcriptions/recorded/logprobs_mini.json` |
| O4 | 200 | silent WAV: `text: ""`, `languages: []`, **no `logprobs` key** | `test/fixtures/openai/transcriptions/recorded/logprobs_silence.json` |
| G0 | 400 | `Unknown name "notARealField" at 'generation_config': Cannot find field.`, so Gemini rejects unknown `generationConfig` fields | `test/fixtures/gemini/transcriptions/recorded/probe_generation_config_control.json` |
| G1 | 400 | `INVALID_ARGUMENT` "Logprobs is not enabled for this model" on `gemini-flash-latest`: the field is in the schema and the model refuses it | `test/fixtures/gemini/transcriptions/recorded/probe_logprobs.json` |
| G2 | — | not run (support branch only) | — |

Live calls: 2 (Gemini) + 4 (OpenAI, over two passes) + 3 (ElevenLabs) = 9, about $0.01 in all, under the design's $0.05 budget. Re-runs over the recorded tree print `0 live calls` for all three recorders (verification below). No fixture holds key material: `grep -rlE 'sk-proj-[A-Za-z0-9]{20}|sk_[a-f0-9]{20}|AIza[0-9A-Za-z_-]{30}' test/fixtures/*/transcriptions/recorded test/fixtures/elevenlabs/realtime/recorded` → no output, exit 1.

### Decisions handed forward

1. **OpenAI include spelling = `include[]=logprobs`.** O1 returns `logprobs` (`test/fixtures/openai/transcriptions/recorded/logprobs_include_brackets.json`, confirmed on the mini model by `logprobs_mini.json`). O2 (bare `include`) returns none (`probe_logprobs_include_bare.json`). 28.5 sends the multipart field `include[]` with value `logprobs`. The existing option test that sends bare `include` (`test/allm/providers/openai/transcription_test.exs:97-101`) tests passthrough only; it is not evidence that the spelling works.
2. **Gemini branch = REFUSE.** G0 returned 400 (`test/fixtures/gemini/transcriptions/recorded/probe_generation_config_control.json`), but G1 returned 400 "Logprobs is not enabled for this model" (`test/fixtures/gemini/transcriptions/recorded/probe_logprobs.json`), not a 200 with `logprobsResult`. So 28.5's Gemini supported list is `[]`, and `logprobs: true` → `:unsupported_feature`, `metadata.field: :logprobs`, before key resolution. `probe_logprobs_silence.json` and its test do not exist. Assumption 6 (thought tokens) is moot, so STOP condition (d) cannot fire.
3. **Realtime time base = `:session`** (`test/fixtures/elevenlabs/realtime/recorded/rt_two_segments.json`, `summary.time_base`). 28.4 passes word times through unchanged. STOP condition (a) did not fire. Assumption 3 held on this run: 3 twins for 3 commits, including the empty commit, with texts equal (STOP condition (c) did not fire).
4. **Blank-text rule per provider.** *ElevenLabs batch:* moot. On silence the source key is present as `words: []` (`test/fixtures/elevenlabs/transcriptions/recorded/silence.json`), so a flagged decode yields `spans: []` without the absent-key branch; the absent-key branches in 28.4 stay covered by synthetic bodies (design Test Plan). *OpenAI:* **exercised.** On silence the `logprobs` key is absent and `text` is `""` (`test/fixtures/openai/transcriptions/recorded/logprobs_silence.json`), so 28.5's decode of that fixture with `logprobs: true` must give `{:ok, %{spans: []}}` (decision 4 blank-text branch). *Gemini:* not applicable (refuse branch).

### Notes for 28.4 / 28.5

- **Empty realtime twin carries `"words": null`, not `[]`.** Under 28.4's "malformed or absent → `nil` spans for that segment" rule, the empty middle segment of `rt_two_segments.json` gets `spans: nil`, and completed `:spans` concatenates only the two fox segments. **Settled by the orchestrator (2026-09-28, gate after 28.3):** the design's blank-text rule (decision 4 — absent source key + blank text → `[]`, the "requested, nothing spoken" reading of decision 3) applies per segment on the realtime path too. A paired twin whose trimmed `text` is blank and whose `words` is `null`/absent yields `spans: []` for that segment, not `nil`; `nil` stays reserved for *untrustworthy* data (twin never arrived, text mismatch, malformed non-null `words`, or absent `words` on non-blank text). 28.4 pins it with a `rt_two_segments.json` replay asserting the middle segment's committed `:spans == []`.
- **Twin-first is live behaviour, not only a stub case.** The empty segment's twin arrived before its `committed_transcript` in `rt_two_segments.json`. 28.4's pairing (`index = state.stamps_seen`) and its twin-first test must handle a twin that precedes its commit mid-session. A replay of this fixture exercises it.
- OpenAI `logprobs[].bytes` is a list of ints. `span_from/6` maps `token` → `text` and ignores `bytes` (design wire-field map).
- Gemini's refusal is per model ("for this model"), probed on `gemini-flash-latest` only (`scripts/record_gemini_audio_fixtures.exs:80`). 28.5/28.6 docs must say the adapter refuses `logprobs` for every Gemini model *on the basis of that one probe*, not that Gemini as a provider lacks logprobs (28.3 functional review, Low).
- Gemini's refusal is per model ("for this model"). The design's no-allow-list reasoning (decision 8) was written for OpenAI; 28.5 refuses Gemini `logprobs` outright per decision 2 above.

### Deviations

1. **[tactical] Record-only arms tightened after recording** (E2 `time_base`, E3, O2, O4, G0, G1). The design marks them *record*. They were recorded first, then converted to asserted outcomes so a provider change halts the recorder. This follows the convention already stated in both the Gemini and OpenAI recorder headers. A fully recorded tree never re-runs them.
2. **[tactical] E3 sends `timestamps_granularity=word`.** The design row says only "ElevenLabs batch, silent WAV". The flagged adapter request (28.4) always sends that field, so E3 probes the request 28.4 will actually send.
3. **[tactical] G0/G1 use the `:envelope` writer** (full body plus headers) despite their `probe_` names, because a later decode test needs the body. The Gemini `:probe` writer drops it.
4. **[tactical] Silent clip** for E3 and O4: 2 s of 16 kHz 16-bit mono zeros behind a 44-byte WAV header, built in-script (ElevenLabs: new `silent_wav/0`; OpenAI: the existing `wav/3`).

### Verification (2026-09-28)

- Pass 1 (`set -a; . ./.env; set +a; mix run scripts/record_<p>_audio_fixtures.exs`): gemini exit 0 (2 live calls), openai exit 0 (2), elevenlabs exit 0 (3). Pass 2: openai exit 0 (2).
- Zero-live-call re-run: `for p in elevenlabs openai gemini; do mix run scripts/record_${p}_audio_fixtures.exs | grep -q '^0 live calls' && echo "$p ok"; done` → `elevenlabs ok`, `openai ok`, `gemini ok`, each exit 0. The recorder compile has 0 `warning` lines per script.
- `mix test test/allm/providers/{elevenlabs,openai,gemini}/transcription_wire_test.exs test/allm/providers/elevenlabs/transcription_stream_test.exs` → `180 tests, 0 failures`.
- `mix test > "$SP/28_3.log" 2>&1` → `exit=0`; `685 doctests, 33 properties, 5586 tests, 0 failures, 14 excluded, 1 skipped` (+9 over 28.2's 5577: one provenance test per new fixture). `grep -c 'warning:' "$SP/28_3.log"` → 0.
- `mix test --seed 0` → exit 0, same counts. `mix credo --strict` → "found no issues". `mix format --check-formatted` → exit 0.

## 28.4 ElevenLabs batch + realtime

Built against `a961670` (28.3 commit). Cited sites located by content: `to_multipart_body/2`, `decode_response/4`, `stream_url/2`, `on_message("committed_transcript_with_timestamps", …)`, `on_committed/4`, `on_stamp/3`, `release_held/1`, `segment/3`, `hold_language?/1`, `completed_event/1` in `lib/allm/providers/elevenlabs/transcription.ex`; the `:unsupported_feature` row in `lib/allm/error/transcription_adapter_error.ex`.

### Checklist

- [x] Batch hand-off (`with_own_cap/2 |> with_span_flags(@span_flags)`), form (`timestamps_granularity=word` structural iff `spans_requested?/1`; the key joins the call-time drop list, `@structural_fields` unchanged), decode (`words` read only when asked; absent/`null` + blank text → `[]`; absent + non-blank → `:unsupported_feature` with `%{field, cause: :absent_from_response, text}`; non-list or an entry without binary `text` → `:malformed_response`). Tests `test/allm/providers/elevenlabs/transcription_test.exs:92`, `:124`, `:240`; `test/allm/providers/elevenlabs/transcription_wire_test.exs:130` (11 tests).
- [x] Realtime URL (`include_timestamps=true` structural iff `spans_requested?/1`), hold predicate (span flag **or** `@hold_options`), stamps widened to `index => %{language, text, spans}` (a map, not the design's tuple — `[tactical]`), pairing sanity check (`paired/3`, trimmed-text compare), `segment/4`, completed `:spans` (`Enum.concat` of the reversed per-segment lists). Tests `test/allm/providers/elevenlabs/transcription_stream_test.exs:583` (13 tests) and `:1257`–`:1291` (4 recorded replays).
- [x] Moduledoc: wire-field-map rows (`timestamps_granularity`, `words` shape), new "Word timings and log-probabilities" section, `stream_transcribe/3` wire/events/spans/hold paragraphs; `transcribe/2` gains a flagged doctest and `stream_transcribe/3` a flagged completed-spans doctest (+2 doctests).
- [x] `TranscriptionAdapterError` `:unsupported_feature` row widened to the post-I/O `cause: :absent_from_response` case (first post-I/O use ships here, pinned by `transcription_wire_test.exs:205`).
- [x] Examples: `examples/24_transcribe_audio.exs` (ElevenLabs arm only: a second, flagged call asserting timed and scored `:word` spans; OpenAI/Gemini flagged calls are 28.5's), `examples/26_stream_transcribe.exs` (`timestamps: true`, asserts timed `:word` spans on the collected response).

### Carried items acted on

1. **Empty realtime twin → `[]`** (orchestrator settlement after 28.3). `twin_spans(nil, text, _)` returns `[]` for a blank twin text and `nil` otherwise; `paired/3` then applies the trimmed-text check. Pinned by the `rt_two_segments.json` replay (`transcription_stream_test.exs:1291`, middle segment `spans: []`) and the synthetic "absent words on a non-blank twin: spans nil; on a blank twin: []" test.
2. **Twin-first mid-session.** The same replay splits the recorded server frames at commit boundaries (`C1 T1 | T2 C2 | C3 T3`) and asserts as a premise that group 2 is twin-then-commit; the stored twin pairs by `stamps_seen` index as before.
3. **Time base `:session`.** Word times pass through unchanged; the replay asserts `summary.time_base == "session"`, non-decreasing `start_seconds` across both fox segments, and segment 3's first start ≥ segment 1's last end.
4. **Shared predicates.** Every flag test goes through `TranscriptionSupport.spans_requested?/1` / `flag_on?/2`; `span_from/6` builds every span, and `with_span_flags/2` sits on both hand-offs. `timestamps: "no", logprobs: 1` switches nothing on (form and URL tests).
5. **[structural, documented] `with_own_rates/1` migrated** onto `TranscriptionSupport.put_adapter_opt/3` (now `fake_stream_opts/1`, which also applies `with_span_flags/2`) per IMPLEMENTATION.md "Migration on extraction". Private, behaviour-preserving (same `adapter_opts[:stream_sample_rates]`), no public name changed; pinned by the existing scripted stream doctests and `transcription_conformance_test.exs`. `grep -rn with_own_rates lib/ test/` → no output, exit 1.
6. **Error doc widened** (above).
7. **No literal `0.0` patterns.** The one zero start in the new tests is compared with `==` (`transcription_test.exs`, "a scripted call with both flags"); `grep -c 'warning:' "$SP/28_4.log"` → 0.

### Deviations

1. **[tactical] Stamps entry is a map** `%{language, text, spans}` rather than the design's `{language, twin_text, spans}` tuple. Same fields, read by name in `paired/3`.
2. **[tactical] `"words": null` on a batch body is treated as absent** (same branch as a missing key). The design names only "absent"; JSON `null` carries no words either.
3. **[tactical] Batch absent-words error names the first set flag** (`:timestamps` before `:logprobs`) in `metadata.field`, since one ElevenLabs source key serves both flags. Pinned by "the absent-words error names :timestamps first when both flags are set".
4. **[tactical] `decode_words/2` is shared** by the batch decoder and the realtime twin decoder (one definition of "a list of maps with a binary `text`"); batch maps its `:error` to `:malformed_response`, realtime to `spans: nil`.
5. **[tactical] Examples:** 24's flagged call runs on the ElevenLabs arm only in this sub-phase; 28.5 adds the OpenAI/Gemini rows.

### Verification (2026-09-28)

- `mix test test/allm/providers/elevenlabs/` → `16 doctests, 379 tests, 0 failures, 1 skipped` (before 28.4: 14 doctests, 347 tests).
- `mix test > "$SP/28_4.log" 2>&1` → `exit=0`; `687 doctests, 33 properties, 5618 tests, 0 failures, 14 excluded, 1 skipped` (28.3: 685 doctests, 5586 tests). `grep -c 'warning:' "$SP/28_4.log"` → 0.
- `mix test --seed 0` → exit 0, same counts.
- `mix credo --strict` → "found no issues" (first pass flagged a string-quote sigil in `decode_batch_words/4` and nesting in the test's frame splitter; both fixed, re-run clean). `mix dialyzer` → "Total errors: 0". `mix format --check-formatted` → exit 0. `mix compile --warnings-as-errors` → exit 0.
- `(cd conformance && mix test)` → `206 tests, 0 failures, 1 skipped`.
- `mix run scripts/audit_user_docs.exs lib/allm/providers/elevenlabs/transcription.ex lib/allm/error/transcription_adapter_error.ex` → "No banned-token matches".
- Mutation table (`mix test test/allm/providers/elevenlabs/ --max-failures 1 --timeout 8000`; file restored and `cmp`-verified after):

| Mutant | Result |
|---|---|
| empty blank twin → `nil` instead of `[]` | red (1) |
| pairing sanity check removed | red (1) |
| hold predicate not widened to span flags | red (1) |
| batch absent `words` always `[]` (non-blank too) | red (1) |
| batch decodes `words` with flags off | red (1) |
| completed `:spans` omitted | red (1) |
| caller's `timestamps_granularity` option not dropped under a flag | red (1) |
| released (twin-never / twin-late) segment gets `[]` instead of `nil` | red (1) |
| no-twin, no-hold clause gets `[]` | green: **equivalent mutant**. With a span flag set the hold is always on, so that clause only runs with flags off, where `segment/4` ignores spans |

- **Live gate** `set -a; . ./.env; set +a; ALLM_PROVIDER=elevenlabs mix run examples/run_all.exs` → `exit=1`. Per-script: `01–21 SKIP (provider gate), 23 OK, 24 OK, 25 OK, 26 OK, 27 FAIL`. 24's flagged call: `spans=17 words=9`, words timed from 0.14 s, `mean_logprob≈-6.4e-5`. 26's flagged stream: committed segment `spans=17`, collected `words=9`, first word at 0.1 s. **27 failure is an account-quota block, not a code failure:** `SpeechAdapterError{reason: :invalid_request, metadata: %{code: "quota_exceeded", close_code: 1008}}`, "You have 1 credits remaining". Re-run alone it fails the same way ("2 credits are required"). 27 is the last script, so no script was left unobserved. The failure is in 27's TTS leg (not touched by this phase) and resolves to no prior phase's commit, so it is recorded here as an environment blocker (top up the ElevenLabs credits, then re-run the arm), not a `[BUG]`. `examples/RUN_OUTPUT_ELEVENLABS.md` is **not** regenerated (snapshot rule: the full run was not green).

### Fix pass (2026-09-28)

Sources: `.work/reviews/2026-09-28-transcript-timings-28-4/overview.md`, `.work/code-reviews/2026-09-28-transcript-timings-28-4.md`, `.work/security-reviews/2026-09-28-transcript-timings-28-4.md` (clean), `.work/design-reviews/2026-09-28-transcript-timings-28-4.md` (N/A).

1. **[structural, documented] Code-review F1 (Medium): decision 4's absent-span rule extracted now, not deferred.** `ALLM.Providers.Support.TranscriptionAdapter` gains `blank_text?/1` and `absent_spans/5` (`@doc false` + `@spec`): blank `text` → `{:ok, []}`, else `:unsupported_feature` with `%{field, cause: :absent_from_response, text}` + request id, `field` = first of `[:timestamps, :logprobs]` that is `flag_on?/2`. Arity 5, not the review's `/4`: a `source` string opens the message so ElevenLabs keeps its exact message (`ElevenLabs returned no "words" list for <field>: true`). ElevenLabs' private `absent_words_error/3` is deleted; `decode_batch_words(nil, …)` and the realtime `twin_spans(nil, …)` call the shared helpers. Behaviour-preserving: `mix test test/allm/providers/elevenlabs/` green unchanged. Tests: `test/allm/providers/support/transcription_adapter_test.exs` "blank_text?/1 …", "absent_spans/5 on a blank transcript …", "absent_spans/5 on a non-blank transcript …" (mutant: field order reversed → `67 tests, 2 failures`, restored and `cmp`-verified). **28.5 obligation:** OpenAI `decode_response/4` and Gemini `build_response` call `absent_spans/5`; DONE WHEN `grep -rn 'absent_from_response,' lib/allm/providers/` lists only `support/transcription_adapter.ex` (today: exit 0, that one line).
2. **Code-review F2 (Low, governed-doc carve-out):** `lib/allm/error/transcription_adapter_error.ex` `:unsupported_feature` row now reads "finds no span data (word timings or log-probabilities)" instead of "no timing data".
3. Code-review F3 (`hold_language?` naming) and F4 (`twin/3` vs `stamped/2` test helper): Low, left for the phase polish pass.
4. Functional-review Low 2 (batch vs stream non-boolean flag validation asymmetry): informational, pre-existing, no false doc sentence; no action.

Verification: `mix test > "$SP/fix_full.log"` → `exit=0`, `687 doctests, 33 properties, 5621 tests, 0 failures, 14 excluded, 1 skipped`; `grep -c 'warning:'` → 0. `mix test --seed 0` → exit 0, same counts. `mix credo --strict` → no issues; `mix dialyzer` → `Total errors: 0`; `mix format --check-formatted` → exit 0; `(cd conformance && mix test)` → `206 tests, 0 failures, 1 skipped`; `mix run scripts/audit_user_docs.exs` on the three touched `lib/` files → no matches.

### Notes for later sub-phases

- **28.5 family test** can drive ElevenLabs batch cells through `prepare_request/2` (gates + build, no send): all four flag cells pass; the realtime column needs no refusal cell (both flags supported).
- **Release gate** (HANDOFF item from 28.1) is still live for OpenAI/Gemini: neither calls `with_span_flags/2` or `gate_flags/4` yet (`grep -rn 'with_span_flags\|gate_flags' lib/allm/providers/openai lib/allm/providers/gemini` → no output).
- **ElevenLabs credits** were exhausted by this run (1 credit left). 28.5's live gates are OpenAI and Gemini only, but any later ElevenLabs arm needs a top-up first.
- **Present-but-empty `words` (28.6 docs):** a `words: []` list on a NON-blank transcript is taken at face value → `spans: []` (batch and realtime twin alike); decision 4 defines only the absent key. The 28.6 doc pass states this in one sentence. Source: functional review 28.4 Known Issues #1.
- **Absent-span rule is shared (28.5):** OpenAI and Gemini call `TranscriptionAdapter.absent_spans/5` (and `blank_text?/1`) rather than re-deriving decision 4; see Fix pass item 1 for the DONE WHEN grep.

## 28.5 OpenAI + Gemini

Built against `ae35cb2` (28.4 commit). Cited sites located by content: `gate_audio/2`, `to_multipart_body/2`, `decode_response/4`, `transcribe/2` hand-off in `lib/allm/providers/openai/transcription.ex`; `gate_audio/2`, `transcribe/2` hand-off in `lib/allm/providers/gemini/transcription.ex`.

### Checklist

- [x] **OpenAI** (`@span_flags [:logprobs]`): hand-off `with_own_cap/2 |> with_span_flags/2`; `gate_flags/4` is the last step of `gate_audio/2` (after resolvable/size/filename, before `Keys.fetch!`); `to_multipart_body/2` adds `{"include[]", "logprobs"}` iff `flag_on?(request, :logprobs)` and drops a caller's `include[]` option for that call only (`@structural_fields` unchanged); `decode_response/4` reads `logprobs` only when `spans_requested?/1`: list → `:token` spans via `span_from/6` (`token` → `text`, `logprob` kept if numeric, times `nil`, `bytes` ignored), absent/`null` → `absent_spans/5` with source `OpenAI returned no "logprobs" list`, anything else → `:malformed_response`. Moduledoc: wire-field rows (`include[]`, response `logprobs`), gate 4, "Token log-probabilities" section, escape-hatch paragraph names `adapter_opts[:span_flags]`; `transcribe/2` gains a keyless refusal doctest.
- [x] **Gemini** (refuse branch, `@span_flags []`): hand-off `with_span_flags/2`; `gate_flags/4` last in `gate_audio/2`. No body or decoder change (no `responseLogprobs`, no span decoder, no G2 fixture). Moduledoc: gate 4 and a "Word timings and log-probabilities are refused" section stating the refusal rests on one probe on `gemini-flash-latest` (`probe_logprobs.json`), not a claim that Gemini lacks logprobs; `transcribe/2` gains a keyless refusal doctest.
- [x] Tests:
  - `test/allm/providers/openai/transcription_test.exs` `describe "span flags"` (9 tests): keyless `timestamps` refusal (`{t,f}`, `{t,t}`), `prepare_request/2` refuse/pass, span gate after audio gates, non-`true` values off, scripted `timestamps` refusal (reason + field only), scripted `logprobs` → Fake spans with logprob and nil times, hand-off `span_flags == [:logprobs]`, form has `include[]` iff `logprobs == true`, caller `include[]` overridden/passed through.
  - `test/allm/providers/openai/transcription_wire_test.exs` `describe "logprobs"` (8 tests): `include[]=logprobs` on the wire, O1 and O3 decode to one `:token` span per entry (count from the fixture), flags off over O1 → `spans: nil`, `mini_tokens.json` + `logprobs: true` → `:unsupported_feature` `:absent_from_response` with `metadata.text`, `logprobs_silence.json` → `{:ok, spans: []}`, malformed shapes → `:malformed_response` (flags on) / `spans: nil` (flags off), non-numeric `logprob` → `nil`.
  - `test/allm/providers/gemini/transcription_test.exs` `describe "span flags (both refused)"` (6 tests): keyless refusal per cell with field, `prepare_request/2` keyless refusal, gate after MIME gate, non-`true` values off and no `generationConfig`, scripted refusal per cell, hand-off `span_flags == []`.
  - `test/allm/providers/gemini/transcription_wire_test.exs` (2 tests): G0/G1 recorded outcomes pin the refuse branch and every flagged cell is refused with a flunking stub; flags off over `mp3.json` → `spans: nil`.
  - `test/allm/providers/support/transcription_adapter_test.exs` `describe "span-flag family consistency (no I/O)"` (17 tests): a literal 12-row expectation table (`[ElevenLabs, OpenAI, Gemini]` × four cells) plus a size check; pass cells `prepare_request(req, api_key: "test-key")` → `{:ok, %Req.Request{}}`; refusal cells also keyless through `transcribe/2` behind a flunking plug; ElevenLabs realtime column (four cells) `stream_transcribe/3` with `ws_module: ALLM.Test.RaisingWebSocket` → `{:ok, _}`.
- [x] `examples/24_transcribe_audio.exs`: OpenAI arm makes a `logprobs: true` call asserting non-empty `:token` spans with numeric logprob and nil times; Gemini arm asserts the local `:unsupported_feature` `field: :logprobs` refusal.

### Carried items acted on

1. `absent_spans/5` reused (not re-derived): DONE WHEN `grep -rn 'absent_from_response,' lib/allm/providers/` → one line, `lib/allm/providers/support/transcription_adapter.ex:191` (exit 0). Gemini does not call it: on the refuse branch no flagged request reaches the decoder.
2. Shared predicates only: every flag check is `flag_on?/2` / `spans_requested?/1` / `gate_flags/4`; `timestamps: "yes"`, `logprobs: 1` switch nothing on (tests above).
3. `mini_tokens.json` exists (`test/fixtures/openai/transcriptions/recorded/mini_tokens.json`, no `logprobs` key, non-blank text) — used as named, no substitution.
4. No literal `0.0` patterns; `grep -c 'warning:' "$SP/28_5.log"` → 0.
5. Release gate: `grep -rn 'with_span_flags\|gate_flags' lib/allm/providers/openai lib/allm/providers/gemini` → 4 lines (hand-off + gate in each adapter), so every bundled adapter now meets the `TranscriptionRequest` moduledoc's pre-I/O refusal promise.

### Deviations

1. **[tactical] The caller-option drop under `logprobs: true` covers the `include[]` key only**, not bare `include` (which OpenAI ignores, per `probe_logprobs_include_bare.json`), so a caller's bare `include` still passes through untouched.
2. **[tactical] A non-numeric `logprob` on an entry with a string `token` decodes to `logprob: nil`**, not `:malformed_response` — the design's malformed rule names only a non-list source or a missing binary text, and the population invariant is "only if". Pinned by the wire test.
3. **[tactical] `examples/RUN_OUTPUT_OPENAI.md` and `RUN_OUTPUT_GEMINI.md` regenerated** from this change's fully green runs (snapshot rule), not left stale.

### Observations

- Recorded OpenAI logprobs include small **positive** values (`1.52587890625e-5` for " brown" in `logprobs_include_brackets.json`); nothing guards `logprob <= 0`, as the span contract says. The 28.6 docs should not claim logprobs are always `<= 0`.

### Verification (2026-09-28)

- Targeted `mix test test/allm/providers/openai/ test/allm/providers/gemini/ test/allm/providers/support/` → `61 doctests, 1220 tests, 0 failures, 2 excluded`.
- `mix test > "$SP/28_5.log" 2>&1` → `exit=0`; `689 doctests, 33 properties, 5663 tests, 0 failures, 14 excluded, 1 skipped` (28.4 fix: 687 doctests, 5621 tests). `grep -c 'warning:' "$SP/28_5.log"` → 0.
- `mix test --seed 0` → exit 0, same counts.
- `mix credo --strict` → "found no issues". `mix dialyzer` → "Total errors: 0". `mix format --check-formatted` → exit 0. `mix compile --warnings-as-errors --force` → exit 0.
- `(cd conformance && mix test)` → `206 tests, 0 failures, 1 skipped`.
- `mix run scripts/audit_user_docs.exs lib/allm/providers/openai/transcription.ex lib/allm/providers/gemini/transcription.ex` → "No banned-token matches".
- Mutation table (`mix test test/allm/providers/{openai,gemini,support}/`; files restored and `cmp`-verified):

| Mutant | Result |
|---|---|
| Gemini `@span_flags [:logprobs]` | red (7) |
| OpenAI hand-off without `with_span_flags/2` | red (2) |
| OpenAI caller `include[]` not dropped under `logprobs: true` | red (1) |
| OpenAI absent `logprobs` always `[]` (non-blank too) | red (1) |
| OpenAI span gate moved after `Keys.fetch!` into `build_request/2` | red (5) |

- **Live gates** (`set -a; . ./.env; set +a; ALLM_PROVIDER=<p> mix run examples/run_all.exs`):
  - **openai, run 1** → `exit=1`: `01–21 OK, 22 SKIP, 23 OK, 24 OK, 25 FAIL, 26 SKIP, 27 SKIP, 28 OK`. 25 (`25_stream_speech.exs`, streaming TTS, not touched by this phase) failed with `SpeechAdapterError{reason: :timeout, message: "no transport message within stream_timeout (60000 ms)"}`. Re-run alone → `exit=0` (`deltas=16 bytes=283200 first_chunk_ms=764`). A one-off provider-side stall, not a reproducible defect; no `[BUG]` filed.
  - **openai, run 2** → `exit=0`: `01–21 OK, 22 SKIP, 23–25 OK, 26–27 SKIP, 28 OK`. 24's logprobs call: `tokens=10`, first `["The", " quick", " brown", " fox"]`, `mean_logprob≈-3.8e-5`. `examples/RUN_OUTPUT_OPENAI.md` regenerated from this run.
  - **gemini** → `exit=0`: `01–18 OK, 19–20 SKIP, 21 OK, 22–23 SKIP, 24 OK, 25–27 SKIP, 28 OK`. 24 prints `refused locally on Gemini, as documented`. `examples/RUN_OUTPUT_GEMINI.md` regenerated from this run.
  - Neither snapshot contains key material (`grep -cE 'AIza[0-9A-Za-z_-]{20}|sk-(proj-)?[A-Za-z0-9]{20}'` → 0 on each log).

### Fix pass (2026-09-28)

1. **Functional M1 (Medium, gate carve-out): gate-before-key now pinned independent of ambient env.** The flunk plug binds gate-before-HTTP only; with `OPENAI_API_KEY` exported, a span gate moved after `Keys.fetch!/2` (but before the send) passed every test. Each refusal cell of the family table (`test/allm/providers/support/transcription_adapter_test.exs` "span-flag family consistency") and the per-adapter span-flag refusal tests (`test/allm/providers/openai/transcription_test.exs` "span flags", `test/allm/providers/gemini/transcription_test.exs` "span flags (both refused)") now also assert the refusal from `gate_audio(request, [])`, which `Support.TranscriptionAdapter.do_transcribe/4` runs before `build_request/2`. The family-table comment and both test moduledocs (the moduledoc claim dated from Phase 25.4/25.5, `git log -S 'fails even with a key exported' -- test/` → `f17a90b`, `e91cdb0`) no longer claim the plug binds key ordering. Mutants (files restored, `git diff --stat` back to pre-mutant counts): OpenAI `gate_flags/4` moved from `gate_audio/2` into `build_request/2` after `Keys.fetch!` with `OPENAI_API_KEY=junk` → `110 tests, 3 failures`; the same for Gemini with `GEMINI_API_KEY=junk GOOGLE_API_KEY=junk` → `105 tests, 4 failures`.
2. **[structural, documented] Code-review F1 (Medium): span-list walk and number coercion extracted.** `ALLM.Providers.Support.TranscriptionAdapter` gains `decode_span_list/3` (`{:ok, spans} | :error`; non-list or any entry lacking a binary `text_key` value → `:error`) and `number_or_nil/1` (`@doc false` + `@spec`). ElevenLabs `decode_words/2` and OpenAI `decode_logprobs/4` call it, each keeping its own malformed message; ElevenLabs' private `number_or_nil/1` is deleted and OpenAI's inline `case` replaced. Private, behaviour-preserving, no public name changed (IMPLEMENTATION.md "Migration on extraction"); existing ElevenLabs/OpenAI tests unmodified and green. DONE: `grep -n 'reduce_while' lib/allm/providers/{openai,elevenlabs}/transcription.ex` → no output, exit 1. New unit tests: "decode_span_list/3 …" (2) and "number_or_nil/1 …" in the "span helpers" describe.
3. Left for the phase polish pass (Low): code-review F2 (OpenAI silent `include[]` drop), F3 (`option_fields/2` second-argument divergence), F4 (cross-adapter decode table), functional L1 (`token_spans/4` gates on either flag), L2 (scripted OpenAI spans are `:word`; no doc claims kind parity — the escape-hatch paragraph promises refusal parity only).

### Notes for later sub-phases

- **28.6 docs:** per-provider table rows now confirmed — OpenAI `logprobs` supported (`include[]=logprobs`, gpt-transcribe + gpt-4o-mini-transcribe), `timestamps` refused; Gemini refuses both (logprobs on the basis of one `gemini-flash-latest` probe); ElevenLabs both. OpenAI's absent-key case lands `whisper-1` on `:unsupported_feature` `:absent_from_response` (inferred from decision 8, not probed live).

## 28.6 Spec, guide, CHANGELOG (docs)

Built against `530f788` (28.5 commit). Documents what shipped per the sections above, not the design's prospective text.

### Checklist

- [x] Spec amendments in `steering/allm_engine_session_streaming_spec_v0_2.md`, each opening `> **Phase 28 amendment (commits `d3bcb3b..530f788`, plus the commit that carries this amendment (28.6 docs + the 28.7 FakeTranscription guard)).**` (`git rev-parse --short HEAD` → `530f788` at write time; stamp reworded in the fix pass below): §37.2.3 (flags, `:spans`, `mean_logprob/1`, `TranscriptSpan`, population invariant by reference to the span moduledoc, per-provider support, no `<= 0` guard, present-but-empty `words: []` → `[]`), §37.2.5 (pre-I/O refusals; post-I/O `cause: :absent_from_response` with `metadata.text`; blank-text success `spans: []`; Fake hand-off refusal; realtime never refuses), §37.2.6 (batch `:invalid_shape` rows), §37.10 (timestamps narrowed; `whisper-1`/`verbose_json` out with reason), §37.11.1 (`committed_transcript/3`, optional completed `:spans`, invariants 9–11 by reference, realtime blank twin → `[]`, untrustworthy twin → `nil`, session-relative times, hold window), §37.11.2 (stream request flags + validator rows). `grep -c 'Phase 28 amendment' steering/allm_engine_session_streaming_spec_v0_2.md` → 6.
- [x] `guides/audio.md`: new `## Word timings and confidence` section (with `### Spans on a stream`) after `## Streaming transcription` / `### Feeding a live source`, four `iex>` blocks (batch flags + `mean_logprob/1`, attribute dropping + flags-off `nil`, OpenAI keyless `timestamps` refusal via the façade, stream committed/completed spans), per-provider table with confirmed rows only (ElevenLabs batch + realtime, OpenAI `gpt-transcribe`/`gpt-4o-mini-transcribe`, Gemini refused, Fake), Gemini phrased as "refuses log-probabilities for every Gemini model on the basis of one probe on `gemini-flash-latest`". "Realtime transcription on ElevenLabs" hold paragraph names `timestamps: true` / `logprobs: true` as a third hold trigger.
- [x] `ALLM.transcribe/3` `@doc`: "Timings and log-probabilities" section + one flagged doctest; `ALLM.stream_transcribe/3` `@doc`: "Timings and log-probabilities" section. Both point at `ALLM.TranscriptSpan`.
- [x] `lib/allm/transcription_request.ex` `@moduledoc` refusal sentence widened to the post-I/O `:absent_from_response` case (HANDOFF item from 28.1, discharged).
- [x] `CHANGELOG.md`: six "Other changes" lines folded into the unreleased `## [REL] v0.6.0` entry (retitled "…, typed classification and transcript timings"), derived from `git diff d3bcb3b..HEAD lib/` plus the 28.7 guard; no breaking line (every touched transcription struct is new since `v0.5.0`). `mix.exs @version` untouched.

### Deviations

1. **[tactical] `lib/allm/transcript_span.ex` `@moduledoc` edited** (not in 28.6's Module Tree): its `:logprob` bullet said "normally zero or negative" with nothing more; it now adds that a provider can report a tiny positive value, so do not assume `logprob <= 0` (28.5 observation, `logprobs_include_brackets.json`). IMPLEMENTATION.md: a docs sub-phase fixes the origin module's docs in the same commit rather than leaving guide and moduledoc disagreeing.
2. **[tactical] Guide `mean_logprob/1` doctest pipes through `Float.round(6)`**: three `-0.1` spans average to `-0.10000000000000002`, which failed the first doctest run. The `ALLM.transcribe/3` doctest uses two spans, where the mean is exactly `-0.1`.
3. **[tactical] Amendment stamp wording** names the range `d3bcb3b..530f788` (28.1–28.5) plus the commit carrying the amendment. The first draft called `530f788` "the phase's last implementation commit", false once 28.7's `lib/` change commits; reworded in the fix pass.

### Verification (2026-09-28)

- Baseline before editing: `mix run scripts/audit_user_docs.exs guides/audio.md` → 0 hits; `mix run scripts/check_guide_fences.exs | head -1` → `71 fences compiled, 14 skipped.`; full suite `689 doctests, 33 properties, 5666 tests, 0 failures`.
- `mix test test/guides_test.exs test/guides_doctest_test.exs` → `94 doctests, 66 tests, 0 failures`.
- `mix run scripts/audit_user_docs.exs guides/audio.md lib/allm.ex lib/allm/transcription_request.ex lib/allm/transcript_span.ex lib/allm/providers/fake_transcription.ex` → "No banned-token matches" (0 hits, unchanged vs. baseline).
- `mix run scripts/check_guide_fences.exs | head -1` → `71 fences compiled, 14 skipped.` (no new fence).
- `mix docs` → exit 0, the same two pre-existing `ALLM.SpeechAdapter.synthesize/2` warnings, none new.
- Full-suite gates: see §28.7 (one run covers both).

## 28.7 `[CHORE]` FakeTranscription malformed `{:retry_until_call, n}`

Built against `530f788`. Scope: `lib/allm/providers/fake_transcription.ex` only.

### Checklist

- [x] `resolve_script/1`'s head arm and `resolve_retry_until_call/4`'s chained arm guarded `when valid_budget(n)` (resp. `m`; `defguardp valid_budget(n) when is_integer(n) and n >= 1`, shared with `validate_entry!/1`'s positive clause since the fix pass); a malformed `{:retry_until_call, _}` in either position goes through the existing `validate_entry!/1`, which raises `ArgumentError` "invalid FakeTranscription script entry: {:retry_until_call, …} (expected …)". Moduledoc (`{:retry_until_call, n}` paragraph and `script/1` doc) says a malformed budget raises when a call reaches it.
- [x] Behavioural test: `test/allm/providers/fake_transcription_test.exs` describe `"{:retry_until_call, n}"`, test `"a malformed {:retry_until_call, <bad>} at the <head|chained> raises from transcribe/2 and stream_transcribe/3"` — 6 generated tests (`0`, `-1`, `:x` × head, chained), each driving `transcribe/2` AND `stream_transcribe/3` directly (not `script/1`) and asserting the raise message names the entry.
- [x] Red before the fix: `mix test test/allm/providers/fake_transcription_test.exs` → `11 doctests, 80 tests, 6 failures`, each "Expected exception ArgumentError but nothing was raised". Green after: `11 doctests, 80 tests, 0 failures`. The chained cases bind the chained arm: with only the head arm guarded, a chained `:x` still reaches `resolve_retry_until_call/4` and returns `:rate_limited`.
- [x] Companion predicate: `grep -nE '\{:retry_until_call, [nm]\} ->' lib/allm/providers/fake_transcription.ex` → no output, exit 1.
- [x] `[DISPOSITION]` appended to `.work/ASKS.md` (ticket located by content: the mon 9/28 12am Phase 24.6 `[DISPOSITION]`, item 3, at `.work/ASKS.md:553` today): narrowed, remainder = the other four Fakes; `grep -nE '\{:retry_until_call, [nm]\} ->' lib/allm/providers/fake_*.ex | wc -l` → 7 (was 9; DONE at 0).
- Not swept (design): the `:cause` exception-struct ticket.

### Verification (2026-09-28, covers 28.6 + 28.7)

- `mix test > "$SP/28_67.log" 2>&1` → `exit=0`; `695 doctests, 33 properties, 5672 tests, 0 failures, 14 excluded, 1 skipped` (baseline `689 / 5666`: +6 doctests from the guide and `transcribe/3`, +6 tests from 28.7). `grep -c 'warning:' "$SP/28_67.log"` → 0.
- `mix test --seed 0` → exit 0, same counts.
- `mix credo --strict` → "found no issues". `mix dialyzer` → "Total errors: 0". `mix format --check-formatted` → exit 0. `mix compile --warnings-as-errors` → exit 0.
- `(cd conformance && mix test)` → `206 tests, 0 failures, 1 skipped`.
- README.md untouched (`git status --short README.md` → empty).

### Fix pass (2026-09-28, covers 28.6 + 28.7)

Sources: `.work/reviews/2026-09-28-transcript-timings-28-6/overview.md`, `.work/code-reviews/2026-09-28-transcript-timings-28-6.md`, security (clean), design review (N/A). All findings Low; the four doc items fixed under the false-sentence-in-a-governed-document carve-out.

1. **Code-review F1: amendment stamps.** All six Phase 28 stamps now read `(commits `d3bcb3b..530f788`, plus the commit that carries this amendment (28.6 docs + the 28.7 FakeTranscription guard))`. `grep -c 'plus the commit that carries this amendment (28.6 docs + the 28.7 FakeTranscription guard)' steering/allm_engine_session_streaming_spec_v0_2.md` → 6; `grep -c "phase's last implementation commit"` on the same file → 0. The 28.6 checklist line and deviation 3 above updated to match.
2. **Code-review F2: §37.2.3 self-contradiction.** Parenthetical restating the per-attribute rules dropped; the sentence now reads "The per-attribute rules are normative in `ALLM.TranscriptSpan`'s moduledoc."
3. **Functional F1: §37.2.5 gate order.** "refused before any I/O and before key resolution" → "refused after the local audio gates, before key resolution and any network I/O" (the flag gate runs after `measure`'s file stat in `gate_audio/2`; functional review observed `/nonexistent.mp3` + `timestamps: true` → `:invalid_request` `cause: :enoent`). Guide/`@doc`/CHANGELOG wording ("before any upload"/"before any request") already accurate; `grep -n 'before any I/O' guides/audio.md lib/allm/transcription_request.ex lib/allm/transcript_span.ex` → no output.
4. **Code-review F4 + functional F2 (same site, `guides/audio.md:638`, both Low, both reached unprompted): table caption.** Now "Each "yes" row for a real provider was confirmed against the live provider on 2026-09-28 …", so the Fake row is excluded.
5. **Code-review F3: `defguardp valid_budget/1`** in `lib/allm/providers/fake_transcription.ex`, used by both resolve arms and `validate_entry!/1`, so the malformed arm's fall-through-to-raise holds by construction. Behaviour-preserving: `mix test test/allm/providers/fake_transcription_test.exs test/guides_test.exs test/guides_doctest_test.exs` → `105 doctests, 146 tests, 0 failures`. File-local; the other four Fakes remain the ASKS remainder (`grep -nE '\{:retry_until_call, [nm]\} ->' lib/allm/providers/fake_*.ex | wc -l` → 7).

Verification after the fix pass: `mix run scripts/audit_user_docs.exs guides/audio.md` → 0 hits; `mix run scripts/check_guide_fences.exs | head -1` → `71 fences compiled, 14 skipped.`; `mix test > "$SP/full.log" 2>&1` → `exit=0`, `695 doctests, 33 properties, 5672 tests, 0 failures, 14 excluded, 1 skipped`, `grep -c 'warning:'` → 0; `mix test --seed 0` → exit 0, same counts; `mix credo --strict` → no issues; `mix dialyzer` → passed; `mix format --check-formatted` → exit 0; `(cd conformance && mix test)` → `206 tests, 0 failures, 1 skipped`.

### Polish pass (2026-09-28, after the gate)

Scope: the deferred Lows only. Each re-verified at `54bd510` before fixing.

1. **28.3 code-review F1:** `logprobs_spelling_check/1`, its call and the `write_result(%{arm: %{write: :none}})` clause deleted from `scripts/record_openai_audio_fixtures.exs`; the O1/O2 comment now says O1's `:require` verdict carries the guarantee. Over the complete tree: `set -a; . ./.env; set +a; mix run scripts/record_openai_audio_fixtures.exs` → `0 live calls: every target is already recorded.`, exit 0.
2. **28.4 code-review F3:** `hold_language?` → `hold_twin?` (state key + private predicate) in `lib/allm/providers/elevenlabs/transcription.ex`; public `language_hold_ms` unchanged.
3. **28.4 code-review F4:** `twin/3` moved to module scope in `test/allm/providers/elevenlabs/transcription_stream_test.exs`; `stamped/2` is now `twin(text, [], language)`, call sites untouched.
4. **28.5 code-review F2 + F3 (same function):** OpenAI `option_fields/2` now takes the full structural list (call site concatenates, as ElevenLabs does) and logs a dropped `include[]` via deferred `Logger.debug(fn -> … end)`. Pinned in `test/allm/providers/openai/transcription_test.exs` ("a caller's include[] option is overridden (and logged) …"); mutant (log disabled) → `57 tests, 1 failure`.
5. **28.5 functional L1:** OpenAI `token_spans/4` gates on `flag_on?(request, :logprobs)` instead of `spans_requested?/1`. Pinned in `test/allm/providers/openai/transcription_wire_test.exs` ("the decode seam reads spans on logprobs alone …"); mutant (old gate) → `42 tests, 1 failure` naming that test.
6. **28.5 functional L2:** documented, not changed: the OpenAI moduledoc's escape-hatch paragraph says scripted calls return the Fake's `:word` spans, while the real adapter returns `:token`.
7. **Gate item:** the design doc's Status table now reads Completed ×7, "Overall Progress: 7/7"; nothing else in the design doc changed.
8. **Skipped: 28.5 code-review F4** (optional family decode table). The four decode invariants stay pinned separately in each adapter's wire tests; adding the table is not a contained change.

Verification: `mix test > "$SP/polish_full.log" 2>&1` → `exit=0`, `695 doctests, 33 properties, 5673 tests, 0 failures, 14 excluded, 1 skipped`, `grep -c 'warning:'` → 0; `mix test --seed 0` → exit 0, same counts; `mix credo --strict` → no issues; `mix dialyzer` → `Total errors: 0`; `mix format --check-formatted` → exit 0; `(cd conformance && mix test)` → `206 tests, 0 failures, 1 skipped`.
