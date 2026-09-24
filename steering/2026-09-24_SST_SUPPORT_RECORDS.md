# Phase 25 — Speech Synthesis & Transcription — Records

Companion to `steering/2026-09-24_SST_SUPPORT.md`. Tick-state, deviations and notes live here; the design doc is not edited for bookkeeping.

## Status

| Phase | Status |
|-------|--------|
| 25.1 | Completed |
| 25.2 | Not started |
| 25.3 | Not started |
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
