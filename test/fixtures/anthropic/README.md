# Anthropic fixtures

Recorded and synthesized response bodies used by `test/allm/providers/anthropic_*_test.exs`.

## Layout

- `messages/` — recorded responses from `claude-sonnet-4-6` via `POST /v1/messages` (and SSE streams when 11.2 lands). Phase 11.1 ships hand-synthesized seeds with leading `_comment` provenance; the live recorder script `scripts/record_anthropic_fixtures.exs` replaces them when run with `ANTHROPIC_API_KEY` set. Snapshot date: 2026-04-26 (synthesized).
- `synthesized/` — hand-crafted error and edge-case bodies. Each file carries a leading `_comment` JSON field naming its Anthropic doc reference and the date it was modeled. **Never overwritten by the recorder** (the recorder script refuses to write under `synthesized/`).

## Recording

```bash
ANTHROPIC_API_KEY=sk-ant-... mix run scripts/record_anthropic_fixtures.exs
```

The recorder writes to `messages/` only. To force a re-record over an existing
recorded file, delete the file first; the script refuses to silently overwrite.
Costs are roughly $3/M input + $15/M output tokens for `claude-sonnet-4-6` as
of 2026-04-26 (verify against the current Anthropic pricing page).

## Synthesized files inventory

| File | Models | Purpose |
|------|--------|---------|
| `auth_failed.json` | Anthropic 401 `authentication_error` body | `:authentication_failed` mapping |
| `rate_limited.json` (+ `.headers.json` sidecar) | Anthropic 429 `rate_limit_error` body, `Retry-After: 1` | `:rate_limited` mapping + retry loop |
| `server_error.json` | Anthropic 500 `api_error` body | `:provider_unavailable` mapping |
| `overloaded.json` | Anthropic **529 `overloaded_error`** body (Decision #2) | `:provider_unavailable` mapping; retry-loop coverage of the Anthropic-specific 529 status |
| `bad_request.json` | Anthropic 400 `invalid_request_error` body | `:invalid_request` mapping |
| `context_length_exceeded.json` | Anthropic 400 with `prompt is too long` marker | `:context_length_exceeded` mapping |
| `request_too_large.json` | Anthropic 413 `request_too_large` body | `:invalid_request` mapping (no specialized 413 atom) |
| `malformed.json` | Truncated 200 body | `:malformed_response` mapping |
