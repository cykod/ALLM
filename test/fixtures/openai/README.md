# OpenAI fixtures

Recorded and synthesized response bodies used by `test/allm/providers/openai_*_test.exs`.

## Layout (Phase 10 design Decision #11)

- `chat_completions/` — recorded responses from `gpt-4.1-mini` via `POST /v1/chat/completions`. Phase 10.2 ships hand-synthesized seeds; Phase 10.5 replaces them with live recordings via `scripts/record_openai_fixtures.exs --endpoint chat`.
- `responses/` — recorded responses from `gpt-5.5` via `POST /v1/responses`. Populated in Phase 10.6.
- `embeddings/` — `POST /v1/embeddings` bodies, split into `recorded/` (genuine live `text-embedding-3-small` responses, no `_comment` marker) and `synthesized/` (hand-written error and edge-case bodies, each carrying one). Recorder: `scripts/record_openai_embeddings_fixtures.exs`.
- `moderations/` — `POST /v1/moderations` bodies, same `recorded/` + `synthesized/` split. See the moderations section below. Recorder: `scripts/record_openai_moderation_fixtures.exs`.
- `speech/` and `transcriptions/` — `POST /v1/audio/speech` and `POST /v1/audio/transcriptions`, same `recorded/` + `synthesized/` split, stored as JSON envelopes. See the audio section below. Recorder: `scripts/record_openai_audio_fixtures.exs`.
- `synthesized/` — hand-crafted error and edge-case bodies. Each file carries a leading `_comment` JSON field naming its OpenAI doc reference and the date it was modeled. **Never overwritten by the recorder.**

## Recording

```bash
OPENAI_API_KEY=sk-... mix run scripts/record_openai_fixtures.exs --endpoint chat
OPENAI_API_KEY=sk-... mix run scripts/record_openai_fixtures.exs --endpoint responses
```

The recorder script lands in Phase 10.5 alongside the runnable examples. Until then, `chat_completions/` carries hand-synthesized bodies that match the documented wire shape but do not represent actual model output.

## Synthesized files inventory

| File | Models | Purpose |
|------|--------|---------|
| `auth_failed.json` | OpenAI 401 `invalid_api_key` body | `:authentication_failed` mapping |
| `rate_limited.json` (+ `.headers.json` sidecar) | OpenAI 429 `rate_limit_exceeded` body, `Retry-After: 1` | `:rate_limited` mapping + retry loop |
| `server_error.json` | OpenAI 500 `server_error` body | `:provider_unavailable` mapping |
| `invalid_request.json` | OpenAI 400 `invalid_request_error` body | `:invalid_request` mapping |
| `context_length_exceeded.json` | OpenAI 400 with `code: context_length_exceeded` | `:context_length_exceeded` mapping |
| `content_filter.json` | OpenAI 400 with `type: content_filter` | `:content_filter` mapping |
| `malformed.json` | Truncated 200 body | `:malformed_response` mapping |

## `moderations/` (Phase 22.4)

`POST /v1/moderations` against `omni-moderation-latest`. **The endpoint is
free**, so re-recording costs $0.00 and there is no reason to run the probe
sparingly.

### `recorded/` — genuine live responses, 2026-08-31

| File | Recorded from |
|------|---------------|
| `single_clean.json` | one clean string; `flagged: false` |
| `flagged_violence.json` | one threatening string; `flagged: true` with `violence` and `harassment` |
| `batch_mixed.json` | three strings, the middle one flagged — pins one-result-per-input ordering |
| `error_400_bad_model.json` | the shut-down `text-moderation-latest`; the live 400 error envelope |

None carries a `_comment` field, which is what the recorder keys its
refuse-to-overwrite check on and what
`test/allm/providers/openai/moderation_wire_test.exs` asserts per file by
reading the **raw bytes** (an assertion made through the loader calls
`drop_comment/1` and would be tautological).

### `synthesized/` — hand-written, each carrying a `_comment` marker

| File | Models |
|------|--------|
| `null_illicit_categories.json` | `illicit` / `illicit/violent` as `null` — OpenAI's reference types them `"boolean or null"`, but no live body in this tree carries one. Pins the drop-null-category rule. |
| `missing_applied_input_types.json` | a results entry with no `category_applied_input_types`. Pins the `applied_input_types: %{}` fallback. |
| `error_401.json` | 401 with a **deliberately planted, unmasked** `sk-proj-…` token — the redaction test's only target. OpenAI's real moderation 401 *masks* the key (observed 2026-08-31), so no provider-authored text here carries key material. |
| `error_429.json` | 429 envelope, paired with a `retry-after: 7` header in the wire test. |

### Recording

```bash
set -a; . ./.env; set +a; mix run scripts/record_openai_moderation_fixtures.exs

# Re-run the live wire probe (including the max_batch_size ladder) without
# writing anything — the overwrite guard otherwise makes it a no-op once the
# tree is fully recorded.
set -a; . ./.env; set +a; mix run scripts/record_openai_moderation_fixtures.exs --probe-only
```

## `speech/` and `transcriptions/` (Phase 25.4)

`POST /v1/audio/speech` (TTS) and `POST /v1/audio/transcriptions` (STT).
TTS answers raw audio, and fixtures here are `.json`, so **every file is a
JSON envelope** rather than a bare body:

| Shape | Fields |
|-------|--------|
| audio body | `status`, `headers` (`content-type`, `x-request-id`), `body_base64`, `byte_size`, `sha256` |
| JSON body (success or error) | `status`, `headers`, `body` |
| assert-only probe outcome (`probe_*.json`) | `status`, `expected`, and `error_body` when not 2xx |
| size ladder (`probe_size_ladder.json`) | `rungs` (`file_part_bytes`, `status`, `expected`), `max_accepted_bytes` |

`ALLM.Providers.OpenAITestFixtures.envelope_bytes/1` decodes an audio
envelope and checks it against its `sha256` and `byte_size`.

The STT input clips the recorder synthesizes (with TTS) live next door in
`test/fixtures/audio/quick_brown_fox.{mp3,wav,flac,aac,opus}`, plus a copy of
the mp3 at `examples/fixtures/quick_brown_fox.mp3`. They are binary input
assets, not wire bodies.

### `speech/recorded/` — genuine live responses, 2026-09-24

| File | Recorded from |
|------|---------------|
| `mp3_default.json` | no `response_format`: `audio/mpeg` |
| `wav.json`, `pcm.json` | `response_format` `wav` / `pcm` |
| `error_400_too_long.json` | 4097 ASCII characters: 400 `string_too_long` |
| `error_404_model.json` | an unknown model: 404 `model_not_found` |
| `error_401_bad_key.json` | a fake `sk-proj-` key: 401 sent as `text/plain`, key echoed **masked** |
| `probe_control.json` | an invented top-level field: 200 (ignored) |
| `probe_unit_graphemes.json` | 2049 × `e` + U+0301 (4098 code points, 2049 graphemes): 400. The limit counts code points, not graphemes |
| `probe_unit_bytes.json` | 4096 × U+00E9 (8192 bytes): 200. The limit does not count bytes |

### `transcriptions/recorded/` — genuine live responses, 2026-09-24

| File | Recorded from |
|------|---------------|
| `gpt_transcribe.json` | `gpt-transcribe`: text, `usage.type: duration`, `languages` |
| `mini_tokens.json` | `gpt-4o-mini-transcribe`: text, `usage.type: tokens` |
| `error_400_format.json` | junk bytes named `junk.mp3`: 400 |
| `error_413.json` | the rejected size-ladder rung: 413, 25 MiB cap on the whole multipart body |
| `error_401_bad_key.json` | a fake key: 401 `text/plain`, key echoed masked |
| `probe_control.json` | an invented form field: 200 (ignored) |
| `probe_audio_bin.json` | valid mp3 bytes named `audio.bin`: 400 `Unsupported file format bin` (the filename extension is trusted) |
| `probe_size_ladder.json` | file parts of 25 MB − 64 KiB, 25 MiB − 64 KiB, 25 MiB + 1 on `whisper-1`: 200, 200, 413 |
| `probe_duration.json` | an 1800 s clip on `gpt-transcribe`: 200 (no duration cap found) |

### `synthesized/` (both endpoints) — hand-written, each carrying a `_comment` marker

| File | Models |
|------|--------|
| `error_401.json` | a 401 carrying a **deliberately planted, unmasked** `sk-proj-…` token, sent as `text/plain`: the redaction test's only target |
| `error_429.json` | a 429 envelope with `retry-after: 7` |

### Recording

```bash
( set -a; . ./.env; set +a; mix run scripts/record_openai_audio_fixtures.exs )
```

Every arm has its own target file and runs only while that file is missing,
so a fully recorded tree makes **0 live calls**. Delete a file to re-run the
arm that owns it. One clean run costs roughly $0.40 (pricing quoted in the
script header).
