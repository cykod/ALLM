# ElevenLabs fixtures

Response envelopes used by `test/allm/providers/elevenlabs/*_test.exs` and
`test/allm/providers/support/elevenlabs_test.exs`, loaded through
`ALLM.Providers.ElevenLabsTestFixtures` (`test/support/elevenlabs_fixtures.ex`).

## Layout

- `speech/recorded/`, `transcriptions/recorded/` — live responses from
  `POST /v1/text-to-speech/{voice_id}` and `POST /v1/speech-to-text`, written
  by `scripts/record_elevenlabs_audio_fixtures.exs` on 2026-09-26
  (`speech/recorded/tts_default.json`, `speech/recorded/error_401_bad_key.json`
  and `transcriptions/recorded/probe_audio_bin.json` on 2026-09-27). None
  carries a `_comment` marker, and a raw-bytes test per file keeps it so.
- `speech/synthesized/`, `transcriptions/synthesized/` — hand-written error
  envelopes for classification rows the probe did not (or could not cheaply)
  observe, plus the planted-key 401 for the redaction test. Each carries a
  leading `_comment` naming Phase 26.6 and what it models. The recorder never
  writes here.

## Envelope shapes

- Audio: `{"status", "headers", "header_names", "body_base64", "byte_size", "sha256"}`.
- JSON (including errors): `{"status", "headers", "header_names", "body"}`.
- Assert-only probe outcomes (`probe_control.json`): `{"status", "expected", "error_body"?}`.
  `transcriptions/recorded/probe_audio_bin.json` is a JSON envelope, because
  the adapter's upload naming depends on its transcript.

`headers` keeps `content-type`, `request-id`, `character-cost` and
`retry-after` when present; `header_names` lists every response header name,
so an absent correlation header is visible as absent.

## Recording

```bash
( set -a; . ./.env; set +a; mix run scripts/record_elevenlabs_audio_fixtures.exs )
```

The recorder runs only the arms whose target file is missing, halts before
writing anything if any arm's status or body verdict does not match, and
prints `0 live calls` on a fully recorded tree. Delete a file to re-run the
arm that owns it.
