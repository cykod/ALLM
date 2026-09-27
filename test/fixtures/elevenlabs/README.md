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
- `speech_stream/recorded/` — live `POST /v1/text-to-speech/{voice_id}/stream`
  (`stream_chunked.json`) and `wss://…/stream-input` sessions (`ws_*.json`),
  written by the same recorder on 2026-09-27 (Phase 26.7).
- `speech/synthesized/`, `transcriptions/synthesized/` — hand-written error
  envelopes for classification rows the probe did not (or could not cheaply)
  observe, plus the planted-key 401 for the redaction test. Each carries a
  leading `_comment` naming Phase 26.6 and what it models. The recorder never
  writes here.

## Envelope shapes

- Audio: `{"status", "headers", "header_names", "body_base64", "byte_size", "sha256"}`.
- JSON (including errors): `{"status", "headers", "header_names", "body"}`.
- HTTP stream: the audio envelope plus `"chunks": [{"byte_size", "t_ms"}]`,
  one entry per data message, `t_ms` since the request was sent.
- WebSocket session: `{"status", "url", "frames", "summary"}`. `status` is the
  upgrade status (101, or the refusal's status with the body in the first
  frame's `upgrade_body`); `url` never carries the key. Each frame is
  `{"dir", "t_ms", "text" | "close" | "closed"}`, where `dir` is from the
  server's side: `"in"` is a client frame, `"out"` a server frame. Server
  audio is replaced by `"<N bytes>"` in every audio frame but the first,
  which is kept whole so a decode test has real base64;
  `ElevenLabsTestFixtures.ws_server_frames/1` turns each placeholder back
  into N zero bytes for replay.
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
