# OpenAI fixtures

Recorded and synthesized response bodies used by `test/allm/providers/openai_*_test.exs`.

## Layout (Phase 10 design Decision #11)

- `chat_completions/` — recorded responses from `gpt-4.1-mini` via `POST /v1/chat/completions`. Phase 10.2 ships hand-synthesized seeds; Phase 10.5 replaces them with live recordings via `scripts/record_openai_fixtures.exs --endpoint chat`.
- `responses/` — recorded responses from `gpt-5.5` via `POST /v1/responses`. Populated in Phase 10.6.
- `embeddings/` — `POST /v1/embeddings` bodies, split into `recorded/` (genuine live `text-embedding-3-small` responses, no `_comment` marker) and `synthesized/` (hand-written error and edge-case bodies, each carrying one). Recorder: `scripts/record_openai_embeddings_fixtures.exs`.
- `moderations/` — `POST /v1/moderations` bodies, same `recorded/` + `synthesized/` split. See the moderations section below. Recorder: `scripts/record_openai_moderation_fixtures.exs`.
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
