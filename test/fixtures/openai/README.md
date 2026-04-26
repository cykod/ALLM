# OpenAI fixtures

Recorded and synthesized response bodies used by `test/allm/providers/openai_*_test.exs`.

## Layout (Phase 10 design Decision #11)

- `chat_completions/` — recorded responses from `gpt-4.1-mini` via `POST /v1/chat/completions`. Phase 10.2 ships hand-synthesized seeds; Phase 10.5 replaces them with live recordings via `scripts/record_openai_fixtures.exs --endpoint chat`.
- `responses/` — recorded responses from `gpt-5.5` via `POST /v1/responses`. Populated in Phase 10.6.
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
