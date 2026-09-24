# Phase 25 — Speech Synthesis & Transcription — Records

Companion to `steering/2026-09-24_SST_SUPPORT.md`. Tick-state, deviations and notes live here; the design doc is not edited for bookkeeping.

## Status

| Phase | Status |
|-------|--------|
| 25.1 | Completed |
| 25.2 | Completed |
| 25.3 | Completed |
| 25.4 | Completed |
| 25.5 | Completed |
| 25.6 | Not started |
| 25.7 | Not started |

## Phase 25.1 — Layer A data

Built 2026-09-24 on `34e3024` (uncommitted working tree).

### Checklist (25.1.2)

- [x] The five structs + `Audio` per the contract blocks (encoder pre-pass and decode hooks as specified). `lib/allm/audio.ex` also carries `defimpl Inspect` (renders `<<N bytes>>` / `<<N chars>>`, file path verbatim).
- [x] The two error modules, shaped after `moderation_adapter_error.ex` (`SpeechAdapterError` 9 reasons, `TranscriptionAdapterError` 10 = the 9 + `:content_filter`; `@type reason` and `@legal_reasons` in lockstep).
- [x] Enum extensions (both lists each): `EngineError` `:no_speech_adapter`, `:no_transcription_adapter`; `ValidationError` `:invalid_speech_request`, `:invalid_transcription_request`. Seven `@known_modules` entries in `lib/allm/serializer.ex`.
- [x] `Validate.speech_request/1`, `transcription_request/1` + rule blocks.
- [x] `@layer_a` +5; `groups_for_modules` for the seven modules (5 → `"Data types"`, 2 → `Errors`).
- [x] Doctests on every public function.

### Verification (run 2026-09-24, working tree on `34e3024`)

| Command | Result |
|---------|--------|
| `mix test test/allm/audio_test.exs test/allm/speech_*_test.exs test/allm/transcription_*_test.exs test/allm/error/speech_adapter_error_test.exs test/allm/error/transcription_adapter_error_test.exs test/allm/validate_speech_request_test.exs test/allm/validate_transcription_request_test.exs` | exit 0 |
| `mix test` | exit 0 — 480 doctests, 32 properties, 3729 tests, 0 failures (baseline at `34e3024`: 445 / 32 / 3565) |
| `mix test --seed 0` | exit 0 |
| `mix format --check-formatted` | exit 0 |
| `mix credo --strict` | exit 0 |
| `mix dialyzer` | exit 0, `Total errors: 0` |
| `mix run scripts/audit_user_docs.exs <file>` for each of the 7 new `lib/` files + `lib/allm/validate.ex` | 0 hits each, exit 0 |
| `mix test test/layer_a_docs_test.exs` | 25 → 30 tests (+5, fail-open gate counted, not removed-and-watched) |
| `mix test test/groups_for_modules_audit_test.exs` | exit 0 |
| `mix test --cover` | every new module 100% (`ALLM.Audio`, the 4 request/response structs, both errors, `Inspect.ALLM.Audio`, all `Jason.Encoder` impls) |
| `grep -rl 'Keys.put(\|Logger.configure(\|System.put_env(\|:telemetry.attach' test/` | no 25.1 file matches. Pre-existing `async: true` matches: `gemini_vision_test.exs`, `gemini_stream_wire_test.exs`, `openai_stream_wire_test.exs`, `anthropic_stream_wire_test.exs`, `openai/images_test.exs`. Most are comment mentions; the two stream-wire tests do call `:telemetry.attach`, and their own comments say they filter by pid. Not in 25.1's tree, and not investigated further. |

`README.md` was clean at start and is untouched (`git diff --stat HEAD -- README.md` empty).

### Deviations and notes

- `[tactical]` `SpeechResponse.mime_to_format/1` also trims and downcases the content type after stripping `;` parameters. The contract says only "parameters after `;` are stripped". HTTP media types are case-insensitive, and every table key is lowercase.
- `[tactical]` Speech validator rows `:voice` / `:instructions` and transcription rows `:language` / `:prompt` share one new private helper `validate_nil_or_binary/3` in `lib/allm/validate.ex`. `:model` reuses the existing `validate_model_field/2`. Field atoms and reasons follow the vocabulary table exactly.
- `[tactical]` `Audio.to_binary/1` / `size/1` guard every source payload with `is_binary/1`, so a hand-built `{:binary, 42}` returns `{:error, :invalid_source}` instead of raising. This matches the validator's `[:audio, :source]` row ("with a binary payload").
- `[tactical]` The enum-extension assertions for `EngineError` / `ValidationError` live in the new test files (`error/*_adapter_error_test.exs`, `validate_*_request_test.exs`). `test/allm/error/engine_error_test.exs` and `validation_error_test.exs` carry hand-maintained `@legal_reasons` literals that were already stale before this phase: they stop at `:no_image_adapter` / `:invalid_image_request`. They are outside the Module Tree and were not touched. This is the HANDOFF item "five of nine error modules lack `legal_reasons/0`".
- `[DEFERRED-DRY]` `hydrate_usage/1` is now a private copy in **five** modules: `lib/allm/response.ex`, `lib/allm/image_response.ex`, `lib/allm/embedding_response.ex` (pre-existing) and `lib/allm/speech_response.ex`, `lib/allm/transcription_response.ex` (new, byte-identical to the embeddings copy). The three existing sites are outside 25.1's Module Tree, so the extraction is not done here. Predicate: `grep -l 'defp hydrate_usage' lib/allm/*.ex` must come back empty, meaning one shared helper (e.g. `@doc false def` on `ALLM.Usage` or `ALLM.Serializer`).
- `[tactical]` (25.1 fix pass, functional review K1) `Audio.size/1` on a `{:file, path}` naming a directory returns `{:error, :eisdir}` instead of `{:ok, <inode size>}`, so a size gate cannot accept what `to_binary/1` rejects. Pinned by `test/allm/audio_test.exs` "{:file, directory} returns {:error, :eisdir}…" (killed by deleting the directory clause).
- `[tactical]` (25.1 fix pass, functional review K6) The "stats, never reads" contract is pinned by `test/allm/audio_size_stat_test.exs` (`async: false`; call-traces `:file.read_file/_` and `:file.open/_` during `size/1`, with a `to_binary/1` control proving the trace sees a read). Mutation M3 (`File.stat` → `File.read` + `byte_size`) now fails it.
- No structural deviations. Every struct field set, default, `@enforce_keys` and enum membership matches the design's contract blocks.

### Binding on later sub-phases (restated from design 25.1.4; unchanged)

- `SpeechResponse.format_to_mime/1` / `mime_to_format/1` are the only MIME↔format tables.
- `Audio.size/1` is the only byte resolver for the STT gates. It returns `{:error, :invalid_source}` for a hand-built off-shape source, `{:error, :enoent}` for a missing file, and (since the 25.1 fix pass) `{:error, :eisdir}` for a directory. Gates convert all three to `:invalid_request`.
- `TranscriptionAdapterError :context_length_exceeded` is produced by `Gemini.Transcription` (25.5).

## Phase 25.2 — Behaviours, engine fields, Fakes, conformance

Built 2026-09-24 on `da277bf` (uncommitted working tree). Status: built, gates pending.

### Checklist (25.2.2)

- [x] Both behaviours: callbacks, numbered invariants, `## Minimum impl skeleton`, "Cleanup invariant: none." (`lib/allm/speech_adapter.ex`, `lib/allm/transcription_adapter.ex`; the transcription moduledoc also carries a `## Gate order` section).
- [x] `Engine`: all four fields at every site in the Engine-extension table. Adapter fields at sites 1–11. Model fields at sites 2, 3, 4, 7, 8, plus the moduledoc field table (the `:model` bullet now says the audio slots never read it, and a new `:speech_model`/`:transcription_model` bullet states the resolution order).
- [x] `FakeSpeech`, `FakeTranscription`, `test/support/fake_audio_fixtures.ex`.
- [x] Two conformance suites + stubs + meta-tests (no fixture-gated case bodies).
- [x] `groups_for_modules` (2 behaviours → `Behaviours`, 2 Fakes → `Providers`).

### Verification (run 2026-09-24, working tree on `da277bf`)

| Command | Result |
|---------|--------|
| `mix test test/allm/speech_adapter_test.exs test/allm/transcription_adapter_test.exs test/allm/providers/fake_speech_test.exs test/allm/providers/fake_transcription_test.exs test/allm/engine_test.exs test/groups_for_modules_audit_test.exs` | exit 0: 24 doctests, 130 tests, 0 failures |
| `mix test` | exit 0: 493 doctests, 32 properties, 3818 tests, 0 failures (25.1 end: 480 / 32 / 3729) |
| `mix test --seed 0` | exit 0 (same counts) |
| `mix format --check-formatted` | exit 0 |
| `mix credo --strict` | exit 0, no issues |
| `mix dialyzer` | exit 0, `Total errors: 0` |
| `mix run scripts/audit_user_docs.exs <file>` for the 4 new `lib/` files and the 2 new `conformance/lib/` files | 0 hits each, exit 0 |
| `mix run scripts/audit_user_docs.exs lib/allm/engine.ex` | 3 hits, exit 1. All three are pre-existing `section_marker` lines (`§31` ×2, `§6.4`). The same file at HEAD (`git show HEAD:lib/allm/engine.ex`) also gives 3. No new hit. |
| `cd conformance && mix test` | exit 0: 137 tests, 0 failures |
| `cd conformance && mix credo --strict` | exit 0 (first run found 2 alias-order issues in the new harnesses; fixed) |
| `cd conformance && mix format --check-formatted` | exit 0 |
| `grep -l 'Keys.put(\|Logger.configure(\|System.put_env(\|:telemetry.attach'` over the 7 new test/support files | no match (exit 1) |
| `mix docs` | exit 0, 0 warnings |
| `mix test --cover` | `FakeSpeech`, `FakeTranscription`, both behaviours 100%; `ALLM.Engine` 98.39% |

Mutation checks (each reverted afterwards):
- Keying `FakeSpeech`'s `bump_retry_visits/3` on `:erlang.phash2(script)` alone fails exactly *"two content-equal-script engines with distinct :id values do not share a retry budget"*.
- Replacing speech case 4's `:gate_opts` read (`merge_gate_opts(...)` at the time; `Keyword.get(unquote(opts), :gate_opts, [])` after the fix pass) with `[]` fails exactly the injected case 4 in `ALLM.Test.SpeechAdapterConformanceGateOptsTest`.

`README.md` is untouched.

### Deviations and notes

- `[tactical]` `FakeSpeech`'s input gate rejects a non-binary `:input` as well as `""` (both → `:invalid_request`, `metadata.field: :input`). A hand-built `%SpeechRequest{input: nil}` would otherwise raise on `"FAKE-AUDIO:" <> input` and break invariant 1.
- `[tactical]` `FakeTranscription`'s gate metadata carries `field: :audio` next to `cause` (resolvable gate) or `count`/`max` (size gate). An `:audio` that is not an `%ALLM.Audio{}` → `cause: :invalid_source`, matching what `Audio.size/1` returns for an off-shape source.
- `[tactical]` Both Fakes carry the family's `adapter_opts[:capture_pid]` seam and the public `script/1`, `start_script_cursor/0` and `cursor_index/1`. The design's Fakes section does not list them. They copy `FakeModeration`'s surface, and the Fake tests use them.
- `[tactical]` `{:ok, %SpeechResponse{}}` / `{:ok, %TranscriptionResponse{}}` script entries are returned verbatim, with no `request_id`/`metadata` stamping, as the design specifies. The conformance suites script the `{:ok, binary}` / `{:ok, text}` shapes, which do stamp, so cases 5–6 pass.
- `[tactical]` Meta-invariant 4 (`:gate_opts` reaches every unscripted case) is bound by a second test module per suite (`ALLM.Test.{Speech,Transcription}AdapterConformanceGateOptsTest`) in the same test file. It runs the suite against an inline `PlugRequiredStub` that fails any unscripted call lacking a function `:plug`, *before* its gates. A premise-guard test asserts the stub really does fail without `:plug`. `:gate_opts` is read at runtime inside each case body (`Keyword.get(unquote(opts), :gate_opts, [])`), never stored in a module attribute, because a `fn` plug cannot be escaped into one.
- `[tactical]` `ScriptedTranscriptionStub.max_audio_bytes/0` is `600`: above case 2's 512-byte clip, and small enough to keep case 4 cheap.
- `[DEFERRED-DRY]` The Fake cursor machinery (`cursor_key_id/2`, peek/advance, `bump_retry_visits/3`, the retry and spent-script handling) now has near-identical private copies in `fake_moderation.ex`, `fake_speech.ex` and `fake_transcription.ex`, plus variants in `fake_embeddings.ex` and `fake_images.ex`. The Module Tree lists no shared module, so no extraction was done. Predicate: `grep -l 'defp cursor_key_id' lib/allm/providers/*.ex` must come back empty (one shared helper); today it lists 5 files.
- ~~`[DEFERRED-DRY]` `merge_gate_opts/2` shared-helper extraction~~ — struck by the 25.2 fix pass (code-review F1, `.work/code-reviews/2026-09-24-sst-25-2.md`). Every call site passed `[]` as the base, so `Keyword.merge([], g, _)` returned `g` and the deep merge never ran. The helper, its `@spec` and its self-test are deleted; each unscripted case now reads `opts = Keyword.get(unquote(opts), :gate_opts, [])`. `grep -rn merge_gate_opts conformance/` → no match.
- `[structural, documented]` Speech conformance case 2 asserts `String.starts_with?(mime, "audio/")` as well as `is_binary(mime)` (25.2 fix pass, code-review F2). `ALLM.SpeechAdapter` invariant 2 requires a `:mime_type` beginning `audio/`, and the design's case table (falsifier `nil`) is weaker than that invariant. This is a deviation from the design row, recorded here rather than amended there. Both `FakeSpeech` and `ScriptedSpeechStub` already return `audio/*`. Mutation check: `ScriptedSpeechStub` stamping `"application/octet-stream"` fails case 2 in both conformance self-test modules (`cd conformance && mix test` → 136 tests, 2 failures; reverted).
- Observed, out of tree: `test/allm/engine_property_test.exs:23` hand-copies `@engine_field_keys`. The copy was already stale (no `:embed_adapter` or `:moderation_adapter`) and now also lacks the four audio fields. It fails open: the property only draws deny-list keys from that copy. Not touched.
- `[CARRY]` (unchanged) `fake_embeddings.ex:391` and `fake_images.ex:370` still key retry visits on `:erlang.phash2(script)`. Both new Fakes use the fixed `FakeModeration` shape, and both carry the ported "do not share a retry budget" test.

### Binding on later sub-phases (restated from design 25.2.4; unchanged)

- Gates run ahead of `Keys.fetch!/2` (binds 25.4, 25.5). Real-adapter conformance invocations pass `gate_opts: [adapter_opts: [plug: fn _conn -> raise … end]]`.
- `build_*_dispatch_opts/3` must call `Engine.put_cursor_key/2` (binds 25.3).
- A real transcription adapter's script hand-off passes its own cap as `adapter_opts[:max_audio_bytes]`. `FakeTranscription` honours that key (pinned by *"adapter_opts[:max_audio_bytes] overrides the cap"*).
- Transcription case 4 sizes from `max_audio_bytes/0`. Record its run time for each real adapter (binds 25.4, 25.5).

## Phase 25.3 — Façades and spans

Built 2026-09-24 on `abc725b` (uncommitted working tree). Status: built, gates pending.

### Checklist (25.3.2)

- [x] The four public functions with `@doc` sections (input shapes, model resolution, gate order, unknown opts, retry nesting, non-conforming raise, `request_id` precedence, "No streaming yet"; `synthesize/3` also "Telemetry carries the audio") and doctests over the Fakes (`speech_request/2` 1, `synthesize/3` 2, `transcription_request/2` 1, `transcribe/3` 2).
- [x] Internals per the Layer C contract: `@speech_request_field_opts` / `@transcription_request_field_opts`, `drop_*_request_opts/1`, `do_synthesize/3` + `do_synthesize_body/4`, `do_transcribe/3` + `do_transcribe_body/4`, `dispatch_{synthesize,transcribe}_attempt/3` (invariant-1 `raise ArgumentError`), `fill_{speech,transcription}_request_id/2`, `@retryable_{speech,transcription}_reasons`. Retry reuses `augment_retry_policy/2` (no new variant). Model stamping is `request.model || engine.<slot>_model`; `Engine.resolve_model/2` / `engine.model` is never read.
- [x] `Telemetry`: `:synthesize`, `:transcribe` in both `@type span_name` and `@valid_span_names`; two table rows plus a paragraph on the stop-key rule and the audio-bytes-in-`:stop`-metadata caution.
- [x] `@public_facade` +4 (fail-open; counted 22 → 26 tests); "When to reach for what" +2 rows.

### Verification (run 2026-09-24, working tree on `abc725b`)

| Command | Result |
|---------|--------|
| `mix test test/allm/allm_synthesize_test.exs test/allm/allm_transcribe_test.exs` | exit 0: 6 doctests, 75 tests, 0 failures |
| `mix test` | exit 0: 505 doctests, 32 properties, 3897 tests, 0 failures (25.2 end: 493 / 32 / 3818) |
| `mix test --seed 0` | exit 0 (same counts) |
| `mix format --check-formatted` | exit 0 |
| `mix credo --strict` | exit 0, no issues |
| `mix dialyzer` | exit 0, `Total errors: 0` |
| `mix docs` | exit 0, no warnings |
| `mix run scripts/audit_user_docs.exs lib/allm.ex` / `lib/allm/telemetry.ex` | 0 hits each (0 at HEAD too) |
| `mix test test/allm_facade_doctest_inventory_test.exs` | 22 → 26 tests (+4) |
| `grep -l 'Keys.put(\\|Logger.configure(\\|System.put_env(\\|:telemetry.attach' test/allm/allm_synthesize_test.exs test/allm/allm_transcribe_test.exs` | no match (exit 1). Both files are `async: true` and use `ALLM.Test.TelemetryCapture`. |

Mutation checks (each reverted): falling back to `engine.model` in the speech model stamp fails exactly *"engine.model (the chat model) never reaches the speech adapter"*; dropping `Engine.put_cursor_key/2` from the shared dispatch-opts builder fails the cursor-key and cursor-isolation tests for all three façades (synthesize, transcribe, moderate — 6 tests).

`README.md` is untouched.

### Deviations and notes

- `[structural, documented]` One private `build_capability_dispatch_opts/3` replaces the design's per-capability `build_*_dispatch_opts/3`, and `moderate/3` now calls it too (its `build_moderate_dispatch_opts/3` is deleted). The three bodies were the same function modulo which request-field allow-list is dropped, so each caller now drops its own list first (`drop_*_request_opts/1`) and passes the result in. This is the "two implementations is the trigger" migration: private, behaviour-preserving, no public name touched, and pinned by `test/allm/allm_moderate_test.exs`'s plumbing block (all green; the mutation check above shows it binds all three callers). The 25.2.4 binding ("must call `Engine.put_cursor_key/2`") holds through the shared helper.
- `[structural, documented]` The same helper now also serves the image and embeddings paths (25.3 fix pass, code-review F1, per `agent-spec/IMPLEMENTATION.md` "Migration on extraction"). The image body's inline `adapter_opts` concat / `put_cursor_key` / `:stream` drop / `:request_id` + `:adapter_opts` block is replaced by one `build_capability_dispatch_opts/3` call, and `build_embed_dispatch_opts/3` is reduced to that helper plus its trailing `Keyword.put(:retry_policy, …)`. The only difference in the embed path is the order of two `Keyword.drop/2` calls, which commute. That makes five callers: image, embed, moderate, synthesize, transcribe. The change is private and behaviour-preserving, touches no public name, and is pinned by prior-phase tests. Mutation checks on the helper, each reverted: engine-first concat swapped to call-site-first fails `allm_generate_image_test.exs` and `allm_embed_test.exs` precedence tests (2 failures); the `:stream` drop removed fails both files' `:stream` tests (2 failures); `put_cursor_key/2` removed fails `fake_images_test.exs`'s content-equal-engines test, and that mutant **survived every embed test file** (`grep -rlE 'ALLM\.embed\(|embed_many|FakeEmbeddings' test/` → 13 files, 407 tests, 0 failures). Embed's façade-level cursor injection was therefore unpinned before this refactor. The fix pass added `test/allm/allm_embed_test.exs` "two content-equal engines each read their own script from entry 0", which now kills it (2 failures across image + embed). Self-scoring predicate: `grep -n 'Engine.put_cursor_key(engine)' lib/allm.ex` → one hit, inside the helper.
- `[tactical]` `input_length` on `:synthesize` `:start` is `String.length/1` (graphemes), matching `text_length`'s `String.length(text)` from the design's telemetry table. It is not the code-point count the OpenAI 4096 gate will use (Decision #6); the telemetry moduledoc names `String.length/1` so nobody reads it as the gate's measure.
- `[tactical]` `usage` on the error path of both `:stop` events is `nil` (key present), matching `:image` / `:embed`. The Test Plan's "`usage` is present on both paths" is read as key presence.
- `[tactical]` `audio_bytes` is measured through `Audio.size/1` rather than a `{:binary, b}` match, and falls back to `0` for a nil audio or an unresolvable source; `text_length` falls back to `0` for a non-binary `:text`. Both only matter for an adapter (or a verbatim Fake script entry) that breaks invariant 2, and keep the span from raising inside `:stop`. Pinned by one test each.
- `[tactical]` The `:retry` telemetry metadata passed to `Retry.run/3` is `%{request_id, model}` (moderation also passes `input_count`; there is no count here).
- `[tactical]` `transcribe/3`'s `## Retry` says "the bundled transcription adapters do not retry on their own", which becomes true when 25.4/25.5 land per the design's Default-timeouts block. Neither bundled STT adapter exists yet. If 25.4/25.5 change that decision, this sentence changes with them.
- The allow-list symmetry tests bind one direction only (every struct field is reachable, a typo'd entry goes red). An allow-listed *non-field* is not bound; binding it needs a `@doc false` accessor, which the moderation sibling also does not have. Stated in the test comment.
- HANDOFF `provider: nil` item discharged: the façades never read `error.provider`; pinned by *"a Fake-generated error (provider: nil) reaches :stop without raising"* in both test files.

### Binding on later sub-phases

- `transcribe/3`'s `@doc` promises the bundled STT adapters do not retry (façade's 3 attempts is the only loop). Binds 25.4 (`OpenAI.Transcription`) and 25.5 (`Gemini.Transcription`): no adapter-level `Retry.run/3`, no `{:retry, …}` return.
- `synthesize/3`'s `@doc` says a speech adapter's own loop multiplies to up to 9 calls. Binds 25.4's `OpenAI.Speech` `@doc` to say which reasons it retries.


## Phase 25.4 — OpenAI adapters

Built 2026-09-24 on `75e95b3` (uncommitted working tree). Status: built, gates pending.

### Checklist (25.4.3)

- [x] `openai/speech.ex`, `openai/transcription.ex`: gate order `input shape/length (TTS) | resolvable → size → filename (STT) → Keys.fetch!(:openai) → Req → decode`.
- [x] Redactor from `openai/moderation.ex` (same `sk-|rk-|org-` pattern, same provider); `sanitize_cause/1` with the 22.7 fix (`%{cause | data: "", position: 0, token: nil}`); no `body_preview`.
- [x] Recorder `scripts/record_openai_audio_fixtures.exs` + fixtures + loaders in `test/support/openai_fixtures.ex` (`speech_recorded/1`, `speech_synthesized/1`, `transcription_recorded/1`, `transcription_synthesized/1`, `envelope_bytes/1`), all delegating to the existing `drop_comment/1`.
- [x] Wire-map rows the probe settled, amended in the design at the claim (rows rewritten in place plus one dated `> CORRECTED 2026-09-24:` blockquote under the OpenAI table, and one under the 25.4.1 `to_multipart_body/2` bullet).
- [x] `groups_for_modules` (2 adapters → `Providers`); `test/fixtures/openai/README.md` sections.

### Live probe (BLOCKING) — `( set -a; . ./.env; set +a; mix run scripts/record_openai_audio_fixtures.exs )`

First run 2026-09-24: exit 0, **24 live calls**, every asserted arm matched, then 30 files written (5 clips, the examples copy, 9 speech + 9 transcription recorded files, plus `error_413.json` from the ladder). Second run (after the expectations were tightened to the observed outcomes, below): exit 0, `0 live calls: every target is already recorded.`

| Arm | Design expectation | Observed | Outcome |
|-----|--------------------|----------|---------|
| speech control (unknown field) | 200 | 200 | unknown fields still ignored |
| tts default / wav / pcm | 200, `audio/mpeg` / `audio/wav` / `audio/pcm`, `x-request-id` | as expected | CONFIRMED |
| tts 2049 × `e`+U+0301 | 400 if code points | **400** `string_too_long` (*"String should have at most 4096 characters"*) | not graphemes |
| tts 4096 × U+00E9 | 200 if code points | **200** (4.7 MB mp3 on `tts-1`) | not bytes → **code points** |
| tts 4097 ASCII | 400 | 400 `string_too_long`, `code: null`, pydantic-shaped message | CONFIRMED; classifier keys on the message |
| tts bad model | 404 `model_not_found` | as expected (content-type `application/json; charset=utf-8`) | CONFIRMED |
| clips ×5 | 200 | mp3 59,520 B, wav 182,444, flac 107,311, aac 32,534, opus 34,010 | written |
| stt control | 200 | 200 | ignored |
| stt gpt-transcribe | 200, duration usage | `{"type":"duration","seconds":4}`, `languages:[{"code":"en"}]`, exact text | CONFIRMED |
| stt gpt-4o-mini-transcribe | 200, token usage | `input_tokens 37, output_tokens 12, total_tokens 49` (+ `input_token_details`) | CONFIRMED |
| stt junk bytes (`junk.mp3`) | 400 | 400 `invalid_value` *"Audio file might be corrupted or unsupported"* | the accepted-format list was **not** re-observed (the extension was valid) |
| stt `audio.bin` | 200 or 400 | **400** `unsupported_value` *"Unsupported file format bin"* | filename trusted → **filename gate** (design's own outcome rule) |
| stt size ladder (whisper-1) | rung 1 200, rung 3 400/413, rung 2 settles | **200, 200, 413** *"Maximum content size limit (26214400) exceeded (26214850 bytes read)"* | cap is 25 MiB on the **whole body**; `max_audio_bytes/0` = **26,148,864** (rung 2) |
| stt duration > 1500 s | 200 or 400 | **200** at 1800 s | no duration cap found; `@doc transcribe/2` says so |
| bad key ×2 | 401 | 401, `content-type: text/plain`, JSON body | see below |

**401 key echo (HANDOFF item).** The real 401 body on both endpoints echoes a **masked** key: *"Incorrect API key provided: sk-proj-*****************************9900."* The design's claim (inferred until now) is confirmed; the unmasked planted token in `synthesized/error_401.json` stays the redactor's only target. The recorded 401 bodies are safe to commit: the only key they can echo is the recorder's own fake `sk-proj-NOTAREALKEY…`.

**Spend.** OpenAI's pricing page (`https://developers.openai.com/api/docs/pricing`, fetched 2026-09-24): *"`tts-1`: $15.00 / 1M characters"*, *"`gpt-4o-mini-tts`: Audio output at $12.00 per 1M tokens"*, *"`gpt-transcribe`: $0.0045 / minute"*, *"`gpt-4o-mini-transcribe`: $0.003 / minute"*, *"Whisper: $0.006 / minute"*. Estimate for the one live run: `tts-1` ≈ 4,100 billed characters ≈ $0.06; `gpt-4o-mini-tts` 8 short calls < $0.01; whisper-1 ladder rungs 1–2 ≈ 26.6 min ≈ $0.16; gpt-transcribe 1800 s clip ≈ $0.14; four ~4 s clips < $0.01. **Total ≈ $0.37**, one live run only (the second run made 0 calls). Well under the $5 ceiling.

### Verification (run 2026-09-24, working tree on `75e95b3`, shell without any `*_API_KEY`)

| Command | Result |
|---------|--------|
| `mix test test/allm/providers/openai/speech_test.exs speech_wire_test.exs speech_conformance_test.exs transcription_test.exs transcription_wire_test.exs transcription_conformance_test.exs` | exit 0 |
| `mix test` | exit 0: 512 doctests, 32 properties, 4058 tests, 0 failures (baseline at `75e95b3`: 505 / 32 / 3898) |
| `mix test --seed 0` | exit 0 (same counts) |
| `mix format --check-formatted` | exit 0 |
| `mix credo --strict` | exit 0, no issues |
| `mix dialyzer` | exit 0, `Total errors: 0` |
| `mix docs 2>&1 \| grep -ciE 'warning\|error'` | 0 |
| `mix run scripts/audit_user_docs.exs lib/allm/providers/openai/speech.ex` / `…/transcription.ex` | exit 0 each, "No banned-token matches" |
| `grep -l 'Keys.put(\|Logger.configure(\|System.put_env(\|:telemetry.attach'` over the 6 new test files + `test/support/openai_fixtures.ex` | no match (exit 1) |
| `mix test --cover` | `OpenAI.Speech` 99.17%, `OpenAI.Transcription` 100% |
| raw-bytes provenance | one `refute Map.has_key?(raw, "_comment")` test per `recorded/` file (9 speech + 9 transcription, `probe_*` included) and a positive marker test per `synthesized/` file, each set asserted against `Path.wildcard/1` |
| Transcription conformance case 4 (`max_audio_bytes() + 1` ≈ 26 MB) | **119 ms** (`--trace`): not tagged `:slow` |

Mutation checks (each reverted; `mix test test/allm/providers/openai/`): `decode_error_body/1` dropping binaries → 3 failures (the recorded text/plain 401 tests); code-point count → `String.length/1` → 1 failure (the `e`+U+0301 falsifier); transcription hand-off without `adapter_opts[:max_audio_bytes]` → 2 failures; `redact_optional/1` as identity (both adapters) → 2 failures; filename gate always `:ok` → 1 failure.

`README.md` is untouched. `conformance/` is untouched.

### Deviations and notes

- `[structural, documented]` **Filename gate** in `OpenAI.Transcription` (gate 3, after size, before the key): a non-file source whose `:mime_type` is `nil` or outside the adapter's mime→extension table → `:invalid_request` with `metadata.mime_type`. The design's outcome rule named a "nil-mime gate" if `audio.bin` 400'd; it did. An unknown mime would have been named `audio.bin` too, so it is gated by the same rule. A `{:file, path}` source is never gated: it is sent under its basename and a bad extension meets the provider's 400. Design wire-map row and 25.4.1 bullet corrected in place.
- `[tactical]` Every recorded fixture on both endpoints is a JSON envelope (`status`, `headers`, and `body_base64`/`byte_size`/`sha256` or `body`). The design specified the envelope for TTS audio only; using it for JSON bodies too keeps the recorded `content-type` (needed to replay the `text/plain` 401) and `x-request-id`.
- `[tactical]` The duration arm used an 1800 s **8 kHz 8-bit mono WAV** (≈14.4 MB) instead of a low-bitrate mp3: no ffmpeg/lame in the container. The size ladder used 16 kHz 16-bit mono WAVs as designed. Neither is committed.
- `[tactical]` The unit-probe arms (and the control and bad-key TTS arms) use `tts-1`, to bill per character rather than per audio token for a 4096-character input.
- `[tactical]` After the first run, every discovery expectation in the recorder was tightened to the observed status (ladder rung 2 → `[200]`, rung 3 → `[413]`, `audio.bin` → `[400]` + `code: unsupported_value`, duration → `[200]` + text), so a later provider change halts the recorder.
- `[tactical]` `OpenAI.Speech.decode_response/4` sets `audio.mime_type` to `SpeechResponse.format_to_mime(format)` when the content type maps, and to the raw content type only for an `audio/*` type outside the table. The format is derived only via `SpeechResponse.mime_to_format/1` (HANDOFF item); no `;` stripping in the adapter.
- `[tactical]` Error classification: 404/413/422 → `:invalid_request` on both adapters; the TTS 400 whose message contains `string_too_long` → `:context_length_exceeded` (the live 400 carries `code: null`). The 413 body says `type: "server_error"`, so the STT classifier keys on status alone.
- `[tactical]` Both adapters build `Req` with `retry: false`. Req's default only retries idempotent methods, so this changes nothing today; it makes the "one attempt" contract of the STT adapter independent of Req's defaults. The speech adapter's retries come only from `ALLM.Retry.run/3`, and `synthesize/2`'s `@doc` states it retries `:timeout` under the default policy (the 25.3 binding).
- `[tactical]` `OpenAI.Speech` also rejects a non-UTF-8 `:input` (`:invalid_request`), which would otherwise raise inside `Jason` during `Req` encoding and break invariant 1 on a direct adapter call.
- `[tactical]` STT `options` values: binaries as-is, numbers/atoms `to_string/1`, lists one field per element, `nil` skipped, anything else `Jason.encode!/1`. Options are emitted in key order after the structural fields.
- `[DEFERRED-DRY]` The OpenAI error/header helpers (`header_value/2`, `header_value_to_string/1`, `retry_after_ms/1`, `parse_retry_after/1`, `decode_error_body/1`, `error_object/1`, `provider_message/2`, `redact_optional/1`, `redact_key_material/1`, `sanitize_cause/1`, `build_metadata/2`, `maybe_apply_req_test_stub/2`, `apply_receive_timeout/2`) are byte-identical between `openai/speech.ex` and `openai/transcription.ex`, and most have variants in `openai/moderation.ex`, `openai/embeddings.ex`, `openai/images.ex`. The Module Tree lists no shared support module, so no extraction here. ~~Predicate: `grep -l 'defp header_value_to_string' lib/allm/providers/openai/*.ex`~~ — **superseded by the 25.4 fix pass** (code-review F2): it checked one helper of thirteen and its glob missed `openai.ex`, `anthropic.ex`, `gemini.ex`, `gemini/*`, `voyage/*`. **Filed in `.work/ASKS.md` (thu 9/24 2am `[DEFERRED-DRY]`).** Predicate, run from the repo root, must print nothing: `grep -roE 'defp (header_value|header_value_to_string|retry_after_ms|parse_retry_after|decode_error_body|error_object|provider_message|redact_optional|sanitize_cause|build_metadata|maybe_apply_req_test_stub|maybe_apply_request_timeout|apply_receive_timeout)\(' lib/allm/providers/ | sort -u | cut -d: -f2 | sort | uniq -c | awk '$1>1'`. Measured 2026-09-24 (same command, after the fix pass): 13 lines (decode_error_body 11 files, maybe_apply_req_test_stub 11, header_value / header_value_to_string / maybe_apply_request_timeout / parse_retry_after / retry_after_ms 9 each, build_metadata / sanitize_cause 8, provider_message 4, apply_receive_timeout / error_object / redact_optional 2). `redact_key_material/1` stays per-provider and is excluded.
- `[CARRY]` (unchanged from the design) `openai/moderation.ex` `decode_error_body/1` returns `%{}` for every binary, so its text/plain 401 message never reaches the redactor; the new adapters JSON-decode it. Owned by 25.7.

### Fix pass (2026-09-24) — reviews `.work/{reviews/2026-09-24-sst-25-4/overview.md,code-reviews,security-reviews,design-reviews}/2026-09-24-sst-25-4.md`

- `[structural, documented]` Code-review F1+F3+F4 (one cause: the filename gate had its own table and an exact-match lookup). `ALLM.Audio` (25.1 code, outside 25.4's Module Tree) gains two `@doc false` seams: `normalize_mime/1` (drop `;params`, trim, downcase) and `extension_for_mime/1`, backed by an `@mime_to_ext` **derived** from `@ext_to_mime` plus a three-row preferred-extension override (`audio/mpeg → mp3`, `audio/mp4 → m4a`, `audio/ogg → ogg`). `SpeechResponse.mime_to_format/1` (25.1) now calls `Audio.normalize_mime/1` instead of its inline copy — behaviour-preserving, public name unchanged, pinned by its existing doctest (`"audio/wav; codecs=1"` → `:wav`); recorded under CLAUDE.md's extraction exception. `OpenAI.Transcription` drops its hand-inverted `@mime_to_ext`; the gate and `to_multipart_body/2` share one `upload_filename/2`, so the seam returns the gate's `{:error, …}` for an unmapped mime instead of naming a part `audio.bin` (F4). Pinned: `test/allm/providers/openai/transcription_test.exs` "parameterised and mixed-case mimes pass the filename gate, keyless", "a parameterised or mixed-case mime is named by its bare type, sent verbatim", "a non-file mime with no extension returns the filename gate's error"; `test/allm/audio_test.exs` describe "normalize_mime/1 and extension_for_mime/1". Mutation: reverting `extension_for_mime/1` to an un-normalised `Map.get/2` turned 3 tests red (`mix test test/allm/providers/openai/transcription_test.exs test/allm/audio_test.exs` → `14 doctests, 92 tests, 3 failures`).
- `[doc]` Functional #1: `speech.ex`'s moduledoc said the error struct "is commonly logged and persisted" as JSON; both moduledocs now carry a warning that `:timeout` / `:network_error` / invalid-JSON `:malformed_response` errors raise on `Jason.encode!/1` (exception struct on `:cause`). The structural fix stays family-wide (HANDOFF row "(from 22.7, for whoever hardens the remaining `Jason.Encoder` error structs)"; `ASKS.md` wed 7/29 3pm `[BUG]`). Not re-filed.
- `[doc]` Functional #2: both moduledocs now carry moderation's warning that the `x-request-id` fallback is unreachable through `ALLM.synthesize/3` / `ALLM.transcribe/3`.
- Code-review F5, F6, F7 and functional #3 (Low) stay in their review docs for the phase polish pass.

### Binding on later sub-phases

- `Gemini.Transcription` (25.5): name a non-file upload / set `mimeType` via `ALLM.Audio.extension_for_mime/1` / `normalize_mime/1` (never a local table, never an exact-match lookup); no adapter `Retry.run/3`, no `{:retry, …}` (façade `@doc`); pass `adapter_opts[:max_audio_bytes]` on hand-off; tolerate a non-map `"error"`; redact message **and** metadata strings; `sanitize_cause/1` resets all three `Jason.DecodeError` offsets. The recorded clips `test/fixtures/audio/quick_brown_fox.{mp3,wav,flac,aac,opus}` exist for its mime arms (the `.opus` clip is Ogg-encapsulated Opus from OpenAI).
- 25.6: `examples/fixtures/quick_brown_fox.mp3` exists. The guide can state: OpenAI TTS input limit is 4096 code points; OpenAI STT cap is `max_audio_bytes/0` = 26,148,864 bytes (25 MiB body cap); no duration cap was found at 1800 s; OpenAI rejects an upload whose filename extension it does not know.

## Phase 25.5 — Gemini transcription adapter

Built 2026-09-24 on `f17a90b` (uncommitted working tree). Status: built, gates pending.

### Checklist (25.5.3)

- [x] `lib/allm/providers/gemini/transcription.ex` per the wire map and Decisions #8, #12: fixed `@transcription_instruction` + language hint + prompt context block; camelCase `inlineData`; `options` → `generationConfig`; own decoder (text parts concatenated, `"thought": true` parts dropped, `thoughtSignature` parts kept; not `Gemini.Decode.candidate_parts/1`, named in `to_json_body/2`'s `@doc false`); finish reasons via `Gemini.parse_finish_reason/1` (`MAX_TOKENS` → `{:ok, partial}` with `metadata.finish_reason: :length`; `:content_filter` rows and `promptFeedback.blockReason` → `:content_filter`); gate order resolvable → size → mime (`Audio.normalize_mime/1`) → `Keys.fetch!(:gemini)`; no adapter retry, `retry: false`; 120 s default timeout; hand-off to `FakeTranscription` with `adapter_opts[:max_audio_bytes]`.
- [x] Redactor verbatim from `gemini/embeddings.ex` (`AIza…|ya29.…`), applied to the message AND `metadata.google_status`; `sanitize_cause/1` with `%{cause | data: "", position: 0, token: nil}`; no `body_preview`.
- [x] Recorder `scripts/record_gemini_audio_fixtures.exs` (four parts) + 10 recorded + 7 synthesized fixtures + `transcription_recorded/1` / `transcription_synthesized/1` in `test/support/gemini_fixtures.ex` (via the existing `load_json/1` → `drop_comment/1`).
- [x] The `exceeds the maximum number of tokens` → `:context_length_exceeded` arm, pinned by `synthesized/error_400_token_limit.json` (inferred; no probe arm can reach it).
- [x] `groups_for_modules`: `ALLM.Providers.Gemini.Transcription` → `Providers`.
- [x] Design wire-map rows the probe settled amended in place, with a dated `> CORRECTED 2026-09-24:` blockquote under the Gemini table and one under the 25.5.2 probe table ("~15.1 MB" reads as MiB).

### Live probe (BLOCKING) — `( set -a; . ./.env; set +a; mix run scripts/record_gemini_audio_fixtures.exs )`

First run 2026-09-24: exit 0, **10 live calls**, every arm matched, 10 files written. Discovery expectations were then tightened to the observed outcomes (opus arms `[200]` + "fox"; over-cap rung `[200]`), and the opus-as-`audio/opus` arm was switched from a hand-rewritten `mimeType` to the adapter's own `to_json_body/2` (now that the mime is in the set); that one file was deleted and re-recorded: exit 0, **1 live call**. Third run: exit 0, `0 live calls: every target is already recorded.`

| Arm | Design expectation | Observed | Outcome |
|-----|--------------------|----------|---------|
| control (`notARealField` top-level) | 400 `Unknown name` | 400 *"Invalid JSON payload received. Unknown name \"notARealField\": Cannot find field."* | acceptance is evidence on this provider |
| mp3 as `audio/mpeg` | 200, "quick brown fox" | 200, *"The quick brown fox jumps over the lazy dog."*, `modelVersion: gemini-3.8-flash`, answer part carries a `thoughtSignature` | CONFIRMED |
| wav / flac / aac | 200, "fox" | 200 ×3, exact text | CONFIRMED; all stay in the set |
| opus as `audio/ogg` | settles alias row | 200, exact text | — |
| opus as `audio/opus` | settles alias row | 200, exact text | **both 200 → `audio/opus` joins the set; no alias table** |
| at cap (15,679,488 B, 16 kHz 16-bit mono silence WAV) | 200 | 200 | cap not too high |
| over cap (15,831,040 B, ≈21.1 MB base64) | 400 confirms / 200 = conservative | **200** | cap is **conservative** → `[CARRY]` below, cap unchanged |
| bad key (`AIzaNOTAREALKEY…`) | 400 `API_KEY_INVALID` | 400 `INVALID_ARGUMENT`, `details[0].reason: "API_KEY_INVALID"`, message *"API key not valid. Please pass a valid API key."*, **no key echo** | CONFIRMED; mapped to `:authentication_failed` |

**Silence is not an empty transcript (new finding).** Both boundary clips were pure digital silence (~490 s each). The model returned fluent, invented speech (*"So, the first thing is we take our three-inch ring…"*, 1,363 output + 6,179 thinking tokens; *"There were several reasons why this might have seemed the wisest choice…"*). Recorded in `probe_boundary_*.json` (`text`, `usage`). The adapter's moduledoc carries a warning; 25.6's guide should repeat it (binding below). Audio tokenisation observed: 12,250 audio tokens for ~490 s ≈ **25 tokens/s** (the design's ~32/s was unverified).

**Spend.** Google's pricing page (`https://ai.google.dev/gemini-api/docs/pricing`, fetched 2026-09-24), Gemini 3.8 Flash (what `gemini-flash-latest` resolved to): input *"$3.00 or $0.005/min (audio)"* per 1M tokens, output *"$12.00"* per 1M tokens (thinking included). Summed from the recorded `usageMetadata`: ≈25.4k input tokens (≈$0.08) + ≈12.1k output+thinking tokens (≈$0.15), dominated by the two silent boundary clips' hallucinated output. **Total ≈ $0.22** across 11 billable calls (the control and bad-key 400s are not billed). The design estimated $0.05/run; the gap is the thinking + hallucinated output on silence. Well under the $2 stop.

### Verification (run 2026-09-24, working tree on `f17a90b`, shell with `env | grep -c _API_KEY` → 0)

| Command | Result |
|---------|--------|
| `mix test test/allm/providers/gemini/transcription_test.exs transcription_wire_test.exs transcription_conformance_test.exs` | exit 0: 4 doctests, 92 tests, 0 failures |
| `mix test` | exit 0: 518 doctests, 32 properties, 4157 tests, 0 failures (baseline at `f17a90b`: 512 / 32 / 4065) |
| `mix test --seed 0` | exit 0 (same counts) |
| `mix format --check-formatted` | exit 0 |
| `mix compile --warnings-as-errors` | exit 0 |
| `mix credo --strict` | exit 0, no issues |
| `mix dialyzer` | exit 0, `Total errors: 0` |
| `mix docs 2>&1 \| grep -ciE 'warning\|error'` | 0 |
| `mix run scripts/audit_user_docs.exs lib/allm/providers/gemini/transcription.ex` | exit 0, "No banned-token matches" |
| `grep -l 'Keys.put(\|Logger.configure(\|System.put_env(\|:telemetry.attach' test/allm/providers/gemini/transcription*.exs test/support/gemini_fixtures.ex` | no match (exit 1) |
| `mix test --cover` | `Gemini.Transcription` 98.35% |
| raw-bytes provenance | one `refute Map.has_key?(raw, "_comment")` per `recorded/` file (10, `probe_*` included) and a positive marker test per `synthesized/` file (7), each set asserted against `Path.wildcard/1` |
| Conformance case 4 (`max_audio_bytes() + 1` ≈ 15.7 MB) | **73.8 ms** (`--trace`): not tagged `:slow` |

Mutation checks (each reverted; `mix test test/allm/providers/gemini/`): mime gate without `Audio.normalize_mime/1` (exact match) → 2 failures (parameterised-mime gate test + body mime test); `API_KEY_INVALID` rule removed → 3 failures; hand-off without `adapter_opts[:max_audio_bytes]` → 2; redactor as identity → 2; thought parts kept → 2; binary error body decoded to `%{}` → 1.

`README.md` untouched. `conformance/` untouched.

### Deviations and notes

- `[tactical]` Honours `adapter_opts[:endpoint]` (base-URL override), as every released Gemini adapter does; the design did not mention it. A `models/` prefix on `:model` is stripped for the URL.
- `[tactical]` `response.model` is the model that was **sent** (`request.model || "gemini-flash-latest"`), mirroring `OpenAI.Transcription`, not the body's `modelVersion` (which stays on `:raw`). `:language` and `:duration_seconds` are always `nil`.
- `[tactical]` `metadata.finish_reason: :length` is an atom key with an atom value, as the design states; like every atom-keyed metadata it comes back string-keyed after a JSON round-trip.
- `[tactical]` A candidate with no `parts` decodes to `text: ""`; finish reasons other than `:content_filter` (e.g. `OTHER`, `MALFORMED_RESPONSE`) are not errors. Only the rows Decision #8 names are special-cased.
- `[tactical]` Error classification reuses `ALLM.Providers.Gemini.classify_error/3` (status table + context-length marker) fed a sanitised `%{"error" => map}` body, so a non-map `"error"` or a binary body cannot raise inside it; reasons outside `TranscriptionAdapterError.legal_reasons/0` collapse to `:unknown`. `metadata` = `%{status, google_status}` (redacted).
- `[tactical]` Recorded fixtures are JSON envelopes (`status`, `headers`, `body`) as in 25.4; `probe_*.json` also keep `text`, `model_version` and `usage` (no audio). The recorder builds every body with the adapter's own `to_json_body/2`.
- `[tactical]` Two synthesized fixtures beyond the four inferred-only rows: `error_429.json` (Retry-After + one-attempt wire test) and `prompt_blocked.json` (`promptFeedback.blockReason`).
- `[CARRY]` **Cap conservative.** `max_audio_bytes/0` = 15,679,488 stays (design outcome rule), but 15,831,040 raw bytes (≈21.1 MB base64, over 20 MiB) was accepted on 2026-09-24, so Google's real inline limit is above the documented 20 MB at this size. Raising the cap needs a ladder arm to find the actual limit (and cost ≈$0.13 per ~8-minute silent rung); not in 25.5's scope. Predicate for whoever picks it up: a `probe_boundary_*` rung above the cap returning 400 is recorded, and `max_audio_bytes/0` equals the largest accepted rung.
- `[CARRY]` (unchanged from the design, for 25.7) `lib/allm/providers/gemini.ex`, `gemini/images.ex`, `gemini/embeddings.ex` still classify a bad key as `:invalid_request`: `grep -L API_KEY_INVALID lib/allm/providers/gemini.ex lib/allm/providers/gemini/{images,embeddings,transcription}.ex` lists those three (transcription passes). A real recorded bad-key body now exists for their tests: `test/fixtures/gemini/transcriptions/recorded/error_400_bad_key.json`.
- `[DEFERRED-DRY]` Error/header helpers gained one more copy each (`decode_error_body`, `error_object`, `provider_message`, `redact_optional`, `sanitize_cause`, `build_metadata`, `maybe_apply_req_test_stub`, `apply_receive_timeout`). The 25.4 predicate (same command as §25.4) now prints 13 lines: `decode_error_body` / `maybe_apply_req_test_stub` 12, `build_metadata` / `header_value` / `header_value_to_string` / `maybe_apply_request_timeout` / `parse_retry_after` / `retry_after_ms` / `sanitize_cause` 9, `provider_message` 5, `apply_receive_timeout` / `error_object` / `redact_optional` 3. `grep -l 'defp sanitize_cause' lib/allm/providers/*.ex lib/allm/providers/*/*.ex | wc -l` → 9. The Module Tree lists no shared support module.
- `[DEFERRED-DRY]` (added by the 25.5 fix pass, code-review F1) The transcription-capability helpers are also clones: after replacing `:openai`/`:gemini` with one atom, eleven private functions are byte-identical between `lib/allm/providers/gemini/transcription.ex` and `lib/allm/providers/openai/transcription.ex`: `fetch_transcription_script/1`, `with_own_cap/1`, `measure/2`, `gate_size/2`, `unresolvable_error/2`, `stub_error/1`, `build_metadata/2`, `do_transcribe/2`, `run_one_attempt/3`, `transport_error/4`, `resolve_bytes/2` (re-measured by extracting each body from both files, normalising the provider atom and comparing md5: 11/11 identical). The Module Tree lists no support module, so no extraction here. **Filed in `.work/ASKS.md` (thu 9/24 2am, companion to the 25.4 ticket).** Predicate, run from the repo root, must print nothing: `grep -roE 'defp (with_own_cap|fetch_transcription_script|do_transcribe|run_one_attempt|transport_error|unresolvable_error|gate_size|measure|resolve_bytes|stub_error)\(' lib/allm/providers/*/transcription.ex | cut -d: -f2 | sort | uniq -c | awk '$1>1'`. Measured 2026-09-24 (same command, exit 0): 10 lines (`gate_size` / `measure` 4 each, counted per clause; the other eight 2 each). `build_metadata/2` is scored by the §25.4 predicate instead.
- `[DEFERRED-DRY]` (added by the 25.5 fix pass, code-review F3; owner the 25.7 `[CHORE]` sweep) The Gemini credential-redactor regex now has three copies inside one provider (`gemini/{transcription,embeddings,images}.ex`). The §25.4 "stays per-provider" exclusion covers different providers' patterns, not copies of the same one. Filed in `.work/ASKS.md` (thu 9/24 2am). Predicate must print `1`: `grep -c 'AIza\[A-Za-z0-9' lib/allm/providers/gemini/*.ex | grep -vc ':0'`. Measured 2026-09-24 (same command): `3`.
- `[unreviewed]` (25.5 fix pass, code-review F2) The design's `CORRECTED 2026-09-24` note under the Gemini wire-field map (`steering/2026-09-24_SST_SUPPORT.md`, the note after the "Correlation header" row) said "no correlation header (only `content-type` came back)". The recorder keeps only `content-type`, `x-request-id` and `x-goog-request-id`, so that was not observed. It now reads "neither `x-request-id` nor `x-goog-request-id` came back (the recorder kept only those two names plus `content-type`, so no other header was observed either way)". Diff: `git --no-optional-locks diff steering/2026-09-24_SST_SUPPORT.md`, that one sentence. This edit to the design was made by the fix pass and has not been reviewed. The moduledoc and the wire test were reworded to the same claim. The recorder now also writes `header_names` (all response header names, no values), so the next re-record can support a stronger assertion; no live call was made. The wire-field-map row itself ("**none** (no `x-request-id`/`x-goog-request-id`) … CONFIRMED") was left as is.

### Binding on later sub-phases

- 25.6 (guide + example 24): Gemini transcription accepts `audio/mpeg`, `audio/wav`, `audio/flac`, `audio/aac`, `audio/ogg`, `audio/opus` (probed) and `audio/aiff` (docs); `max_audio_bytes/0` = 15,679,488 (conservative); the default model `gemini-flash-latest` resolved to `gemini-3.8-flash` on 2026-09-24; **silence yields an invented transcript, not `""`** — state it in the fidelity section alongside Decision #8's paraphrase caveat. Example 24 under `ALLM_PROVIDER=gemini` transcribes `examples/fixtures/quick_brown_fox.mp3`, which returned the exact sentence.
- 25.7: the `API_KEY_INVALID` `[CARRY]` above.
