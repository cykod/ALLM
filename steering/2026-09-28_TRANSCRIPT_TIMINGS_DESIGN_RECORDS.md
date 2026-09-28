# Phase 28 transcript spans — Records

Companion bookkeeping for `steering/2026-09-28_TRANSCRIPT_TIMINGS_DESIGN.md`. The design doc's own Status table is not updated; this file is the status of record.

## Status

| Phase | Status |
|-------|--------|
| 28.1 | Completed (2026-09-28) — reviews: .work/{reviews,code-reviews,security-reviews}/2026-09-28-transcript-timings-28-1 |
| 28.2 | Completed (2026-09-28) — reviews: .work/{reviews,code-reviews,security-reviews}/2026-09-28-transcript-timings-28-2 |
| 28.3 | Completed (2026-09-28) — reviews: .work/{reviews,code-reviews,security-reviews}/2026-09-28-transcript-timings-28-3; no fix pass needed (two Lows: one carried to polish, one recorded in Notes for 28.4 / 28.5) |
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

