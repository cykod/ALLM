# OpenAI Images fixtures

Wire-shape fixtures for `ALLM.Providers.OpenAI.Images` — see Phase 15
(`steering/PHASE_15_image_layer_6.md`) and AGENT_DESIGN_SPEC.md rule 16.

## Layout

- `recorded/` — live-recorded happy-path response bodies. Hand-synthesized
  initially per AGENT_DESIGN_SPEC.md rule 16 (recorded shapes verify decode
  correctness; request-shape contracts are validated separately via live
  smoke tests in Phase 15.5). Run `scripts/record_openai_image_fixtures.exs`
  with `OPENAI_API_KEY` to replace each synthesized body with a real one;
  the recorder will not overwrite a file that already lacks the leading
  `_comment` field (i.e. a previously-recorded fixture).
- `synthesized/` — hand-crafted error and edge-case bodies. Each carries
  a leading `_comment` field naming the OpenAI doc reference and date
  modeled. **The recorder script never touches `synthesized/`.**

## Files

### `recorded/`

| File | Endpoint | Model | Purpose |
|---|---|---|---|
| `generate_dall_e_2_happy.json` | `/v1/images/generations` | `dall-e-2` | base64 (`b64_json`) happy path |
| `generate_dall_e_2_url_happy.json` | `/v1/images/generations` | `dall-e-2` | URL (`response_format: url`) happy path |
| `generate_dall_e_3_happy.json` | `/v1/images/generations` | `dall-e-3` | base64 + `revised_prompt` |
| `generate_dall_e_2_n4_happy.json` | `/v1/images/generations` | `dall-e-2` | multi-image batch (`n: 4`) |
| `generate_gpt_image_1_happy.json` | `/v1/images/generations` | `gpt-image-1` | base64 (forced) + token usage (`input_tokens`/`output_tokens`/`input_tokens_details`) |
| `edit_dall_e_2_happy.json` | `/v1/images/edits` | `dall-e-2` | base64 happy path (multipart body builder + JSON response decode) |
| `edit_gpt_image_1_happy.json` | `/v1/images/edits` | `gpt-image-1` | base64 (forced) + token usage on edit |
| `variation_dall_e_2_happy.json` | `/v1/images/variations` | `dall-e-2` | base64 happy path (multipart body builder, no `prompt`/`mask`; same response envelope as `:edit`) |

### `inputs/`

Test-input fixtures (NOT recorded responses) used by live and adapter
tests that need a deterministic input image.

| File | Purpose |
|---|---|
| `sample_256.png` | 1×1 PNG (~68 B; tiny placeholder) — used as the `:edit` input image for the live smoke test (Phase 15.5 deliverable; landed early in 15.4 so the recorder script's `:edit` cells work end-to-end). |

### `synthesized/`

| File | HTTP status | Purpose |
|---|---|---|
| `auth_failed.json` | 401 | `:authentication_failed` mapping |
| `rate_limited.json` + `.headers.json` | 429 | `:rate_limited` + `Retry-After` parsing |
| `server_error.json` | 500 | `:provider_unavailable` mapping |
| `invalid_request.json` | 400 | `:invalid_request` mapping |
| `content_filter.json` | 400 | `:content_filter` mapping (code: `content_policy_violation`) |
| `content_filter_empty_data.json` | 200 | `:content_filter` mapping (Decision #5b — accepted-but-empty) |
| `malformed.json` | 200 | `:malformed_response` mapping (missing `data` field) |

## Recording

Hand-synthesized fixtures carry a leading `_comment` field. To replace
them with real OpenAI responses (one-time, ~$0.20 total cost):

```bash
OPENAI_API_KEY=sk-... mix run scripts/record_openai_image_fixtures.exs
```

The recorder writes to `recorded/` only and refuses to overwrite a file
already missing the synthesized `_comment` marker (i.e., one previously
recorded). To force a re-record, delete the file first.
