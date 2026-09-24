# Phase 25 — Speech Synthesis & Transcription — Records

Companion to `steering/2026-09-24_SST_SUPPORT.md`. Tick-state, deviations and notes live here; the design doc is not edited for bookkeeping.

## Status

| Phase | Status |
|-------|--------|
| 25.1 | Completed |
| 25.2 | Completed |
| 25.3 | Completed |
| 25.4 | Not started |
| 25.5 | Not started |
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

