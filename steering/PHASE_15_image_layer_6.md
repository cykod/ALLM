# Phase 15: `ALLM.Providers.OpenAI.Images` — First Real Image Provider — Design Document

> **Goal:** Ship `ALLM.Providers.OpenAI.Images` implementing `ALLM.ImageAdapter` against OpenAI's three image endpoints (`/v1/images/generations`, `/v1/images/edits`, `/v1/images/variations`) with model-aware operation gating across `dall-e-2`, `dall-e-3`, and `gpt-image-1`; plus a runnable `examples/10_generate_image.exs` wired into the BLOCKING `run_all.exs` examples gate.
> **Outcome:** An engine constructed with `image_adapter: ALLM.Providers.OpenAI.Images` produces real `%ALLM.ImageResponse{}` values from `ALLM.generate_image/3`, `edit_image/4`, and `image_variations/3` against a live `OPENAI_API_KEY`. The conformance suite (`use ALLM.Test.ImageAdapterConformance`) passes unchanged. Wire-shape tests cover the 3 ops × 3 models matrix plus seven error classes. Every published `:image_adapter` operation an end-user can perform on OpenAI works without a wrapper.
> **Spec sections:** §35.7 (`ALLM.Providers.OpenAI.Images`), §35.2.1–§35.2.4 (data model — already shipped Phase 13), §35.3 (behaviour — already shipped Phase 14.1), §35.9 (telemetry — already wired Phase 14.3), §6.4 (key resolution at adapter-call time), §7.2 (HTTP transport — `Req` for non-streaming, no Finch needed for image endpoints).
> **Layers touched:** B only. No Layer A struct changes; no Layer C façade changes (the façade landed in Phase 14.2); no Layer D session changes. The phase ships a single new adapter module + tests + recorded fixtures + one example script.

## Status

| Phase | Description | Layer | Status |
|-------|-------------|-------|--------|
| 15.1  | `ALLM.Providers.OpenAI.Images` skeleton + `supported_operations/0` + model-aware gate + endpoint dispatch (no HTTP yet) | B | Not Started |
| 15.2  | `:generate` over `dall-e-2` and `dall-e-3` — JSON body, response decode, error mapping, retry integration | B | Not Started |
| 15.3  | `gpt-image-1` `:generate` — forced-base64 normalization + token-usage mapping (`input_tokens` / `output_tokens`) | B | Not Started |
| 15.4  | `:edit` — multipart/form-data builder + URL-source eager-download path + mask handling | B | Not Started |
| 15.5  | `:variation` — multipart over `dall-e-2`-only; live smoke test gated on `OPENAI_API_KEY` against `dall-e-2:generate` | B | Not Started |
| 15.6  | `examples/10_generate_image.exs` + `examples/_helpers.exs` image-engine constructor + `run_all.exs` integration + `RUN_OUTPUT_OPENAI.md` snapshot refresh | — | Not Started |

**Overall Progress:** 0/6 phases complete

## Overview

Phase 14 shipped the spine — `ALLM.ImageAdapter` behaviour, `ALLM.Providers.FakeImages`, the `ALLM.generate_image/3 · edit_image/4 · image_variations/3` façade, telemetry, capability preflight, retry. Every piece downstream of the adapter call site is in place. Phase 15 plugs the first real provider into that spine: OpenAI Images. It is a pure Layer B addition — one new module under `lib/allm/providers/openai/images.ex`, a peer of the existing chat adapter at `lib/allm/providers/openai.ex`, sharing nothing in code but the namespace and the project's `ALLM.Keys` / `ALLM.Retry` integration patterns.

The phase has a small surface but a wide test matrix. The "3 ops × 3 models" matrix is asymmetric (gpt-image-1 doesn't do `:variation`; dall-e-3 doesn't do `:edit` or `:variation`), and one model (gpt-image-1) has an entirely different response shape — base64-only output, token-based usage. Two of the three endpoints take multipart/form-data, not JSON. The retry path runs through `ALLM.Retry.run/3` exactly as the chat adapter uses it. Per spec §6.4 and the established v0.2 pattern, keys resolve via `ALLM.Keys.fetch!(:openai, opts)` at request-build time — no key ever lives on the engine.

The phasing doc at `steering/RELEASE_0_3_PHASING.md:113–122` is the contract this design refines. Two of its principles are load-bearing here: **Principle #6** (every bundled provider adapter ships with a runnable example, and `/review` BLOCKS on `mix run examples/run_all.exs` exit 0) means `examples/10_generate_image.exs` is part of the deliverable, not an afterthought. **Principle #8** (no `Image.from_url/1` HTTP fetching at construction time) means URL-source `%ALLM.Image{source: {:url, _}}` images on `:edit` / `:variation` are downloaded *by the adapter* at request-build time — not at message-construction time — which keeps `ALLM.Image` serializable.

- **Deliverables:**
  - `lib/allm/providers/openai/images.ex` (NEW) — the adapter module, ~400 LOC.
  - `lib/allm/providers/support/openai_headers.ex` (NEW) — small helper extracting the `authorization`/`content-type`/`openai-organization` builder from the chat adapter so both adapters share it (Decision #11).
  - `lib/allm/providers/openai.ex` (MODIFY) — `defp build_headers/2` (currently at `lib/allm/providers/openai.ex:437–447`) is removed; its single call site delegates to `ALLM.Providers.Support.OpenAIHeaders.json_headers/2`. Behaviour-preserving extraction.
  - `test/allm/providers/openai/images_test.exs` (NEW) — module-level wire tests using `Req.Test.stub/2` for happy paths + closed-enum error mappings (mirrors `test/allm/providers/openai_wire_test.exs:1–80` pattern verified at file:line in research).
  - `test/allm/providers/openai/images_multipart_test.exs` (NEW) — multipart-builder unit tests + `:edit` / `:variation` wire tests.
  - `test/allm/providers/openai/images_conformance_test.exs` (NEW) — invokes `use ALLM.Test.ImageAdapterConformance, image_adapter: ALLM.Providers.OpenAI.Images` (the published suite from Phase 14.1) against a `Req.Test.stub`-driven happy-path stub.
  - `test/allm/providers/openai/images_live_test.exs` (NEW) — `@moduletag :live_openai_images` (excluded by default in `test/test_helper.exs`); skipped when `OPENAI_API_KEY` is unset.
  - `test/fixtures/openai/images/` (NEW directory) — fixtures matrix per §15.7.
  - `test/fixtures/openai/images/README.md` (NEW) — fixture inventory + recording instructions.
  - `scripts/record_openai_image_fixtures.exs` (NEW) — recorder script (mirrors `scripts/record_anthropic_fixtures.exs` pattern).
  - `examples/_helpers.exs` (MODIFY) — extend `@providers` table mapping with image-adapter awareness, plus an `image_engine/1` constructor (Decision #14).
  - `examples/10_generate_image.exs` (NEW) — the smallest reproducer; `dall-e-2` `:generate` against a real key.
  - `examples/run_all.exs` (MODIFY — provider-arm gating) — Anthropic arm skips `10_*.exs` because Anthropic has no image adapter (Decision #15).
  - `examples/RUN_OUTPUT_OPENAI.md` (MODIFY) — refreshed snapshot after live `examples/run_all.exs` for the OpenAI provider.
  - `CHANGELOG.md` (MODIFY) — `[FEAT] ALLM.Providers.OpenAI.Images per §35.7`.
- **Spec coverage:** §35.7 (the OpenAI Images adapter is the entire content of this phase). Refines §6.1 (retry — image-side `Retry-After` parsing now exercised against real OpenAI responses), §6.4 (`Keys.fetch!`), §7.2 (HTTP transport via `Req` — no streaming on this surface). Existing §35.3 conformance contract holds without change.
- **Layer demonstration.** Phase 15 only touches Layer B. The user-facing snippet at every other layer is unchanged from Phase 14:

  ```elixir
  # Layer B — the new adapter, opt-in via engine.image_adapter:
  iex> engine = ALLM.Engine.new(image_adapter: ALLM.Providers.OpenAI.Images, model: "dall-e-2")
  iex> {:ok, %ALLM.ImageResponse{images: [%ALLM.Image{source: {:binary, _}, mime_type: "image/png"}]}} =
  ...>   ALLM.generate_image(engine, "a watercolor kestrel", size: "256x256")
  ```

  Because the adapter implements the existing `ALLM.ImageAdapter` behaviour, every Layer C / Layer D capability that already worked against `FakeImages` (Phase 14.2 façade, Phase 14.3 telemetry/retry) Just Works against the real adapter — no new public API.
- **Prerequisites (all complete on `main`):**
  - Phase 13: `ALLM.Image`, `ALLM.ImageRequest`, `ALLM.ImageResponse`, `ALLM.ImageUsage` (`lib/allm/image.ex`, `lib/allm/image_request.ex`, `lib/allm/image_response.ex`, `lib/allm/image_usage.ex`). `ALLM.Image.to_binary/1` returns `{:ok, bytes} | {:error, :remote_source}` per `lib/allm/image.ex:188–201`.
  - Phase 14.1: `ALLM.ImageAdapter` (`lib/allm/image_adapter.ex`), `ALLM.Error.ImageAdapterError` with 12-atom closed enum (`lib/allm/error/image_adapter_error.ex:30–68`), published `ALLM.Test.ImageAdapterConformance` under `conformance/`.
  - Phase 14.2: `ALLM.generate_image/3 · edit_image/4 · image_variations/3` in `lib/allm.ex` and `:no_image_adapter` reason on `EngineError` (`lib/allm/error/engine_error.ex:13–40`).
  - Phase 14.3: `[:allm, :image, :start | :stop]` telemetry, `ALLM.Capability.preflight_image/2`, `ALLM.Retry` augmented for image-error atoms.
  - v0.2 OpenAI chat adapter (`lib/allm/providers/openai.ex`) — provides the `ALLM.Keys.fetch!/2`, `ALLM.Retry.run/3`, and `Req.Test`-stub testing patterns this phase mirrors.
  - `examples/_helpers.exs` (Phase 11.4) — provider-neutral engine constructor; this phase extends it with `image_engine/1`.
- **Out of scope (deliberate):**
  - **Vision input on the chat adapter.** Phase 16 wires `ALLM.ImagePart` translation into `lib/allm/providers/openai.ex` (Chat Completions + Responses content-part shapes). This phase is image *generation* only.
  - **Anthropic image adapter.** Per spec §35.7 (`steering/allm_engine_session_streaming_spec_v0_2.md:2040`) Anthropic does not offer image generation. Phase 17 wires Anthropic vision-input only.
  - **Streaming partial-image previews.** Per phasing principle #2 (`steering/RELEASE_0_3_PHASING.md:12`) and §35.10, no `stream_generate_image/3`. OpenAI's `partial_images: 1..3` parameter on gpt-image-1 is provider-specific; if a future caller wants it they pass it through `ImageRequest.options[:partial_images]` and consume the wire data themselves. Out of scope here — the adapter does NOT advertise it.
  - **Batch endpoints (OpenAI Batch API for images).** §35.10 — out of scope for v0.3.
  - **`prepare_request/2` callable from production code.** The Phase 14.1 behaviour declares it `@optional_callbacks`; this adapter implements it (mirroring chat-adapter precedent at `lib/allm/providers/openai.ex:411–435`) but no production caller invokes it. Used only by tests for unfired-request inspection.
  - **`requires_structured_finalize?/1`-style capability declarations.** Image generation has no analogue of the chat-adapter tools-+-json_schema two-pass dance; capability checking is entirely catalog-side via `ALLM.Capability.preflight_image/2` (Phase 14.3).
  - **dall-e-3 `style:` and `quality:` tuning depth.** The fields exist on `ALLM.ImageRequest` (Phase 13); the adapter wire-translates them and tests exercise legal values; OpenAI's exact accepted-value enums are NOT re-mirrored in our closed atom set (we accept the documented atoms `:natural | :vivid` for style and `:standard | :hd` for dall-e-3 quality, plus `String.t()` for any future values per `image_request.ex:42–55`). Unknown atoms are passed through verbatim and rejected by the provider, returning `:invalid_request`. Closing the enum further is deferred until OpenAI publishes more values.
  - **Cost population from `llm_db`.** Phase 14.3 wired the optional `llm_db` integration; this phase does not populate cost fields from response data alone (OpenAI returns image counts and tokens, not dollars). Cost-via-catalog is an `llm_db`-dependent path tested already in Phase 14.3; this phase only verifies the adapter-side `ImageUsage` shape (image counts + tokens) round-trips.

- **Non-obvious decisions:**

  1. **Module path is `lib/allm/providers/openai/images.ex` (sub-namespace), NOT `lib/allm/providers/openai_images.ex`.** Matches spec §35.7's named module `ALLM.Providers.OpenAI.Images`. The chat adapter at `lib/allm/providers/openai.ex` is `ALLM.Providers.OpenAI`; the image adapter at `lib/allm/providers/openai/images.ex` is `ALLM.Providers.OpenAI.Images`. Filesystem-mirrors-namespace is the project convention (`lib/allm/error/image_adapter_error.ex` defines `ALLM.Error.ImageAdapterError`). *Docs target: internal — no user-facing docs needed.*

  2. **Endpoint dispatch is a single-pass `case request.operation` lookup, NOT a regex table.** Three operations, three endpoints, one-to-one mapping — `:generate → "/images/generations"`, `:edit → "/images/edits"`, `:variation → "/images/variations"`. The returned strings are paths relative to `@base_url` (`"https://api.openai.com/v1"`); URL assembly is `@base_url <> endpoint_for(op)`, mirroring chat-adapter `path_for/1` at `lib/allm/providers/openai.ex:449–450` (which returns `"/chat/completions"` and similarly composes to `https://api.openai.com/v1/chat/completions`). No model-family regex like the chat adapter's `@endpoint_dispatch` (`lib/allm/providers/openai.ex:126–130`) because there's no model-family-conditional endpoint here. *Docs target: `@doc ALLM.Providers.OpenAI.Images.endpoint_for/1`.*

  3. **Model-aware operation gating is a static `@model_ops` table + a helper, fired BEFORE `Keys.fetch!/2` and BEFORE any HTTP I/O.** Per Phase 14.1 conformance contract (`lib/allm/image_adapter.ex` invariant 4) and the phasing doc's "BEFORE any HTTP call" requirement (`steering/RELEASE_0_3_PHASING.md:115`). Table:
     ```elixir
     @model_ops %{
       "dall-e-2" => [:generate, :edit, :variation],
       "dall-e-3" => [:generate],
       "gpt-image-1" => [:generate, :edit]
     }
     ```
     Unknown model strings (e.g., `"dall-e-4-preview"`) are NOT in the table; the adapter falls back to "let the provider decide" and dispatches anyway. Rationale: the table is descriptive of *known* OpenAI behaviour, not a closed enum of all legal values; closing it would force a code change every time OpenAI ships a model. Unknown-model + unsupported-op → `:invalid_request` from the provider, surfaces via the normal wire-error path. Known-model + unsupported-op → `:unsupported_operation` BEFORE any HTTP call. *Docs target: `@moduledoc ALLM.Providers.OpenAI.Images` + `@doc ALLM.Providers.OpenAI.Images.supported_operations/0` (with the per-model breakdown documented).*

  4. **`supported_operations/0` returns the per-MODULE union of all operations the adapter can ever perform: `[:generate, :edit, :variation]`.** Matches Phase 14.1 Decision #3 (`steering/PHASE_14_image_layer_2_5.md:101`) — per-module declaration, NOT per-call-with-model-arg. The per-model gating in Decision #3 is the adapter's INTERNAL responsibility, surfaced via `:unsupported_operation` errors with `metadata.model` populated. The conformance suite asserts the per-module list is honored on UNKNOWN operations (e.g., a hypothetical `:foo` operation atom); per-model gating gets its own dedicated tests in `images_test.exs`. *Docs target: `@doc ALLM.Providers.OpenAI.Images.supported_operations/0`.*

  5. **`response_format` translates to OpenAI's wire shape with one model-conditional override: `gpt-image-1` ALWAYS returns base64 regardless of the requested format, and the adapter normalizes the response into the caller's requested shape.** Per phasing doc `steering/RELEASE_0_3_PHASING.md:115`. Two distinct concerns:
     - **Wire-out**: For `dall-e-2` / `dall-e-3`, the adapter sets the request body's `"response_format"` field to `"url"` (when caller asked `:url`) or `"b64_json"` (when caller asked `:binary` or `:base64`). For `gpt-image-1`, the adapter OMITS `"response_format"` from the body (the API rejects the parameter on this model — verified against OpenAI docs as of 2026-04-27 via context7).
     - **Wire-in normalization**: The provider response always carries either `url:` or `b64_json:` per image. The adapter materializes the caller's requested form:
       - caller asked `:url` → response carries `{:url, url}` source. (gpt-image-1: caller MAY NOT request `:url`; the adapter rejects the request before HTTP with `:invalid_request` — see Decision #6.)
       - caller asked `:base64` → response carries `{:base64, b64}` source.
       - caller asked `:binary` → adapter Base64-decodes the `b64_json:` field server-side and produces `{:binary, bytes}` source.
     The MIME type defaults to `"image/png"` for dall-e-2 / dall-e-3 responses (the API does not return a content-type field per image; documented behaviour is PNG output). For gpt-image-1 the MIME type is conditional on `request.options[:output_format]` (see Decision #19). This default is on the response struct's `:mime_type` field — callers can override at construction time on input images, but on outputs we trust the documented default.

     **URL-mode expiry warning:** OpenAI documents that image URLs returned via `response_format: :url` expire ~60 minutes after creation. Callers persisting `Image{source: {:url, _}}` beyond that window should download the bytes themselves before persisting, or request `:base64` / `:binary` upfront. The adapter does NOT proactively materialize URL-mode responses to bytes (would force latency and breaks the requested-format contract); the moduledoc and `generate/2` `@doc` carry the warning. *Docs target: `@doc ALLM.Providers.OpenAI.Images.generate/2` (response-format normalization + URL expiry paragraph) + `@moduledoc ALLM.Providers.OpenAI.Images` (model matrix table).*

  6. **`gpt-image-1` + `response_format: :url` is rejected at the model-gate stage with `{:error, %ImageAdapterError{reason: :invalid_request, message: "gpt-image-1 only returns base64; request response_format: :base64 or :binary", metadata: %{model: "gpt-image-1", response_format: :url}}}` BEFORE any HTTP call.** Same shape as `:unsupported_operation`. Surfaced loudly because silently mutating caller-requested formats is worse than a clear error. The closed-enum reason `:invalid_request` from `ImageAdapterError.@type reason` (`lib/allm/error/image_adapter_error.ex:30–68`) is the appropriate atom — same atom OpenAI's 400 path maps to. *Docs target: `@doc ALLM.Providers.OpenAI.Images.generate/2`.*

  7. **`:edit` and `:variation` use multipart/form-data; `:generate` uses JSON.** OpenAI's API requires this split — the edit / variation endpoints take an actual image file in the request body. Multipart construction lives in a private `to_multipart_body/2` helper. `Req` supports multipart natively via the `:form_multipart` option (verified against `deps/req/lib/req/steps.ex:446-468` — body shape is `[{name, value}]` for plain fields and `[{name, {body, filename: "...", content_type: "..."}}]` for file fields, where `body` is a binary or `Stream`). The image bytes come from `ALLM.Image.to_binary/1` (Phase 13, returns `{:ok, bytes} | {:error, :remote_source}`) for `{:binary, _}`, `{:base64, _}`, `{:file, _}` sources, AND from an eager-download path for `{:url, _}` sources (Decision #8). *Docs target: `@moduledoc ALLM.Providers.OpenAI.Images`.*

  8. **URL-source images on `:edit` / `:variation` are eagerly fetched at request-build time via `Req.get/1` against the URL.** Per phasing principle #8 (`steering/RELEASE_0_3_PHASING.md:18`): no eager fetches in `Image.from_url/1`, but adapters MAY (and must) resolve the URL to bytes when the wire requires it. For OpenAI's edit / variation multipart bodies, the wire requires actual file bytes — there's no URL-by-reference form on these endpoints. The adapter calls `Req.get(url, receive_timeout: opts[:request_timeout] || 30_000, max_redirects: 5)` against the image URL, materializes the response body to bytes, and includes them in the multipart payload. Failure modes (closed):
     - 4xx/5xx from the URL host → `{:error, %ImageAdapterError{reason: :invalid_request, message: "could not fetch URL-source image: <status>", metadata: %{url: url, status: status}}}`.
     - Body size > 25 MB (OpenAI image-edit input cap; checked via `content-length` header pre-stream OR streaming-byte-count post-stream) → `{:error, %ImageAdapterError{reason: :invalid_request, message: "URL-source image exceeds 25 MB cap", metadata: %{url: url, size: size}}}`.
     - Content-type does NOT match `~r{^image/(png|jpeg|jpg|webp|gif)$}` → `{:error, %ImageAdapterError{reason: :invalid_request, message: "URL did not return a supported image content-type", metadata: %{url: url, content_type: ct}}}`.
     - More than 5 redirects → `{:error, %ImageAdapterError{reason: :invalid_request, message: "URL-source image fetch exceeded max redirects", metadata: %{url: url}}}` (Req emits `Req.TooManyRedirectsError`; mapped to `:invalid_request`).
     - Timeout / network error → `{:error, %ImageAdapterError{reason: :network_error, ...}}`.
     `:generate` does NOT fetch URLs because `:generate` has no input images by spec §35.2.2. *Docs target: `@doc ALLM.Providers.OpenAI.Images.generate/2` (URL-fetch paragraph) + CHANGELOG note.*

  9. **`:cause` on `ImageAdapterError` carries the underlying term (Req exception, parse failure, etc.); never displayed to users; serializable per Layer A invariant.** Mirrors `lib/allm/error/adapter_error.ex` precedent. The `:metadata` field carries call-site context (`%{model: ..., operation: ..., url: ...}`); `:cause` carries the diagnostic detail. JSON-serialization-of-cause may be partial (Req exception structs have non-trivial Jason encoders); the implementation calls `inspect/1` as a fallback when the cause isn't JSON-encodable, matching `lib/allm/error/adapter_error.ex` precedent. *Docs target: internal — no user-facing docs needed.*

  10. **Retry integration: the adapter's HTTP closure returns `{:retry, delay_ms, %ImageAdapterError{}}` for HTTP status 429/5xx and `:timeout`; `:rate_limited` reason carries `:retry_after_ms`; `ALLM.Retry.run/3` is called with the engine's policy.** Mirrors chat-adapter pattern at `lib/allm/providers/openai.ex:72–76`. The image-side façade in Phase 14.3 already augments `retry_on` with the four image-error atoms (`:rate_limited`, `:provider_unavailable`, `:timeout`, `:network_error`), so the closure's `{:retry, ...}` return surfaces those atoms via `error.reason` and they flow through the augmented `Retry.run/3`. The closure parses `Retry-After` (both `Integer`-seconds and HTTP-date forms — same regex helper as chat adapter) and stamps it onto `ImageAdapterError.retry_after_ms`. `:network_error` (Mint exception, DNS failure, etc.) returns `{:retry, base_delay_ms, error}` — no header to parse, retry uses policy backoff. *Docs target: `@moduledoc ALLM.Providers.OpenAI.Images` (retry paragraph cites Phase 14.3 augmentation).*

  11. **Headers builder is extracted to `ALLM.Providers.Support.OpenAIHeaders` (NEW `lib/allm/providers/support/openai_headers.ex`).** The chat adapter's `build_headers/2` at `lib/allm/providers/openai.ex:437–447` always injects `content-type: application/json`; the image adapter's multipart path must NOT inject `content-type` (so Req fills the boundary). The shared module exports two functions: `json_headers(api_key, opts) :: [{String.t(), String.t()}]` and `multipart_headers(api_key, opts) :: [{String.t(), String.t()}]` (multipart elides `content-type` so `Req`'s `:form_multipart` step sets it with the boundary — see `deps/req/lib/req/steps.ex:482–487`). Both honor `opts[:adapter_opts][:organization]` per chat-adapter precedent at `lib/allm/providers/openai.ex:443–446`. The chat adapter's refactor is behaviour-preserving: `defp build_headers/2` is removed and its single call site delegates to `OpenAIHeaders.json_headers/2`. Same boundary anticipated for "future Stability/Replicate adapters" (`steering/RELEASE_0_3_PHASING.md:121`). *Docs target: `@moduledoc ALLM.Providers.Support.OpenAIHeaders` + CHANGELOG entry.*

  12. **Wire-fixture matrix uses two storage modes: recorded and synthesized — the same split as the chat adapter (`test/fixtures/openai/README.md`).** Per agent-spec/DESIGN.md rule 16 ("synthesized-vs-recorded wire-fixture policy"). Recorded fixtures live under `test/fixtures/openai/images/recorded/`; synthesized error/edge-case fixtures live under `test/fixtures/openai/images/synthesized/`. Recorded fixtures are JSON bodies (with optional `.headers.json` sidecars for multi-header responses); synthesized error fixtures carry a leading `_comment` field naming the OpenAI doc reference and date modeled. The recorder script `scripts/record_openai_image_fixtures.exs` (NEW) writes only to `recorded/`; never overwrites `synthesized/`. *Docs target: `test/fixtures/openai/images/README.md`.*

  13. **Multipart fixtures for `:edit` and `:variation` test the BUILT body, not the round-tripped HTTP body.** The wire test asserts on the multipart body that the adapter constructs (a list of `{name, content}` tuples), then injects a `Req.Test.stub` for the response. The provider response IS recorded JSON — the same JSON shape `:generate` returns. Rationale: recording a real multipart upload's wire format is fragile (boundary strings randomize per request) and provides no extra coverage over asserting the multipart-builder helper's output. The library's `Req` dependency is responsible for correctly encoding the tuple list to wire bytes; the adapter is responsible for producing the right tuples. The split test surface is: (a) `to_multipart_body/2` is unit-tested for shape; (b) the wire test injects a stub for the response. *Docs target: internal — no user-facing docs needed.*

  14. **`examples/_helpers.exs` grows an `image_engine/1` constructor sister to `engine/1`.** `engine/1` constructs a chat-adapter engine; `image_engine/1` constructs an image-adapter engine. Both share the `@providers` table; `image_engine/1` looks up `:image_adapter` (currently `ALLM.Providers.OpenAI.Images` for `"openai"`, `nil` for `"anthropic"`). Calling `image_engine/1` on Anthropic raises a clear `ArgumentError` ("anthropic does not have an image_adapter; this script is OpenAI-only"). The `@providers` table is **restructured from a 3-tuple to a map** `%{adapter:, default_model:, key_env:, image_adapter:, image_default_model:}` so future fields don't churn the destructure pattern in `engine/1` (the current 3-tuple destructure at `examples/_helpers.exs:32` would `MatchError` on extension to a wider tuple). Existing `engine/1` callers are unaffected functionally; `engine/1` updates its destructure from `{adapter, default_model, key_env} = row` to `%{adapter: adapter, default_model: default_model, key_env: key_env} = row`. *Docs target: `@moduledoc ExamplesHelpers` (extend with image_engine paragraph) + the new example script's prologue comment.*

  15. **`run_all.exs` provider-arm gating: when `ALLM_PROVIDER=anthropic`, the script SKIPS `[0-9][0-9]_*.exs` files whose module path requires an image adapter.** Header-comment marker grammar (closed):
     - `# Provider: openai` → run only when `ALLM_PROVIDER == "openai"`.
     - `# Provider: anthropic` → run only when `ALLM_PROVIDER == "anthropic"`.
     - `# Provider: openai, anthropic` (comma-separated, whitespace-tolerant) → run on either.
     - Marker absent → run on every provider (current behaviour for `01_*` through `09_*`).
     The grep regex is `~r/^#\s*Provider:\s*([\w, ]+)\s*$/m` (matched against the file contents, not just the first line). Skipped scripts print `[SKIP] <name> (provider gate)` and do NOT count toward `failed`. (`12_vision_input.exs` from Phase 16 will use `# Provider: openai, anthropic`; `13_image_variations.exs` from a future phase will use `# Provider: openai`.) *Docs target: `examples/run_all.exs` moduledoc + `examples/README.md` mention.*

  16. **Live smoke test runs TWO cells: `dall-e-2:generate` AND `dall-e-2:edit`.** Per phasing doc `steering/RELEASE_0_3_PHASING.md:117` and agent-spec/DESIGN.md rule 16 (request-shape contracts can only be validated against synthesized fixtures OR live runs; multipart bodies are explicitly NOT recorded per Decision #13). Adding `:edit` to the live matrix closes the request-shape coverage gap on the multipart path — without it, no automated check confirms the adapter sends a wire-correct multipart body for `:edit` / `:variation`. `:variation` is NOT live-tested (its multipart shape is a strict subset of `:edit`'s — single `image` field, no `prompt`, no `mask`; live coverage of `:edit` validates the multipart machinery). The other matrix cells (`dall-e-3`, `gpt-image-1`) are exercised via recorded fixtures only. The implementer captures one recorded fixture per response-decode-significant cell during initial recording (~$0.20 total one-time cost); thereafter all CI runs replay against the cached fixtures. The live module `@moduletag :live_openai_images` is excluded by default in `test/test_helper.exs` (added in Phase 15.5); opt-in via `mix test --include live_openai_images`. The example script `examples/10_generate_image.exs` runs against `dall-e-2:generate` and drives the BLOCKING `/review` examples gate. Per agent-spec/DESIGN.md rule 19: per-clean-run live-test cost ≈ $0.04 (one `dall-e-2` 256x256 generate + one `dall-e-2` 256x256 edit at ~$0.018 each); per-clean-run example-gate cost ≈ $0.02 (single `dall-e-2` generate); first-implementation cost ~3× for debug iterations. *Docs target: `examples/10_generate_image.exs` prologue comment + CHANGELOG note + `test/allm/providers/openai/images_live_test.exs` moduledoc.*

  17. **`Req.Test.stub/2` is the testing pattern — same as the chat adapter (`test/allm/providers/openai_wire_test.exs:1–80`).** Each test creates a unique stub atom (`String.to_atom("openai_images_stub_#{System.unique_integer([:positive])}")`), passes it via `adapter_opts: [plug: {Req.Test, stub}]`, and the adapter wires it through `Req.merge(req, plug: plug)` exactly as `lib/allm/providers/openai.ex:456–461` does. Async tests share no global state. The image adapter's `do_prepare/2`-equivalent helper applies the stub identically. *Docs target: internal — no user-facing docs needed.*

  18. **The "request_id" preserved by the adapter is `opts[:request_id]` from the façade — NOT the OpenAI response header `x-request-id`.** Per Phase 14.1 conformance contract (invariant 5): adapters MUST preserve `opts[:request_id]` onto `response.request_id`. The OpenAI response carries an `x-request-id` header that's useful for OpenAI-side support tickets; the adapter stores it on `response.metadata[:openai_request_id]` to keep both fields populated. Conformance does not require populating `metadata[:openai_request_id]`; it's a Phase 15-only convenience. *Docs target: `@doc ALLM.Providers.OpenAI.Images.generate/2` (request-id paragraph) + CHANGELOG.*

  19. **Image MIME-type defaults to `"image/png"` on dall-e-2 / dall-e-3 responses; on gpt-image-1 the MIME is conditional on `request.options[:output_format]`.** OpenAI's image endpoints document PNG as the output format for dall-e-2/3. gpt-image-1's `output_format` parameter (NOT to be confused with `response_format` from Decision #5 — see Wire-field map for the distinction) accepts `"png"|"jpeg"|"webp"` and defaults to `"png"`. When the caller passes `options: %{output_format: "webp"}` through to gpt-image-1, the adapter wires `output_format: "webp"` into the request body AND sets the response's `:mime_type` to `"image/webp"`. The `image_request.options` map is the spec-sanctioned escape hatch for provider-specific knobs (`steering/allm_engine_session_streaming_spec_v0_2.md:§35.2.2`). *Docs target: `@doc ALLM.Providers.OpenAI.Images.generate/2`.*

  20. **Conformance suite hookup: the OpenAI Images adapter honors `adapter_opts[:image_script]` as a documented test-only escape hatch — bypassing HTTP entirely when present.** Per the `ALLM.Test.ImageAdapterConformance` docstring at `conformance/lib/allm/test/image_adapter_conformance.ex:20-31`: "Adapters that read their script from a different key may override by populating the matching field themselves — the harness's requirement is only that the adapter respects the shape the script declares." All 9 conformance cases populate `opts: [adapter_opts: [image_script: [...]]]`; without honoring this key the adapter would attempt HTTP against unstubbed Req and fail every conformance case. The adapter's behaviour: at the top of `generate/2`, BEFORE pre-flight gates, check `Keyword.get(opts, :adapter_opts, []) |> Keyword.get(:image_script)`; if present, delegate to `ALLM.Providers.FakeImages.generate/2` with the same opts (FakeImages already implements the script grammar from Phase 14.1 / 14.3). This is a documented test-only path (the docstring notes "this branch is intended for test injection only; production callers do not populate `:image_script`") — analogous to the chat adapter's `adapter_opts[:plug]` testing escape hatch. The pre-flight gates (operation, model, gpt-image-1+`:url`) are SKIPPED on the script path because conformance cases test conformance with the harness's request, not the adapter's gating; the adapter's own `images_test.exs` covers gates separately. *Docs target: `@moduledoc ALLM.Providers.OpenAI.Images` (test-injection paragraph) + `@doc ALLM.Providers.OpenAI.Images.generate/2` (test-injection precedence note).*

  21. **`:context_length_exceeded` is RESERVED in the closed enum but is NOT mapped to any production wire path in this adapter.** OpenAI's Images endpoints do not document a `context_length_exceeded` error code (the atom in `ALLM.Error.ImageAdapterError.@type reason` is from Phase 14.1's general adapter-error vocabulary, mirroring chat-adapter precedent). Long prompts on gpt-image-1 (which has documented limits ~32000 chars) are rejected by the API with `error.type: "invalid_request_error"` → `:invalid_request`, NOT a context-length code. The synthesized fixture for this row is therefore SPECULATIVE; if the implementer cannot construct a request that triggers a `context_length_exceeded` code from real OpenAI, the row drops from the wire-test matrix. The closed-enum atom remains in `ImageAdapterError` (Phase 14.1 contract; not pruned here) and is reserved for future provider behaviour. *Docs target: CHANGELOG note + `@moduledoc ALLM.Providers.OpenAI.Images` (closed-enum mapping table caveat).*

  22. **`:unsupported_feature` reason atom is NOT produced by this adapter.** Reserved for adapters that reject feature combinations the wire cannot express; the OpenAI Images adapter's mismatches surface as `:unsupported_operation` (operation × model) or `:invalid_request` (`response_format: :url` + gpt-image-1 per Decision #6). The error contract table excludes `:unsupported_feature` from the mapping rows; the closed-enum atom remains valid in `ImageAdapterError` per Phase 14.1. *Docs target: internal — no user-facing docs needed.*

  23. **`n` overflow is NOT pre-flight gated; the provider rejects.** dall-e-3 supports only `n: 1`; gpt-image-1 supports `n: 1..10`; dall-e-2 supports `n: 1..10`. The adapter does NOT pre-flight `n` against the model — sending `n: 4` against dall-e-3 yields a 400 from OpenAI mapping to `:invalid_request`. Consistent with Decision #3's "let the provider decide on unknown models" rationale: numerical caps may grow over time and re-mirroring them in our adapter forces a code-change every quarter. The model-conditional `response_format` rejection (Decision #6) is the EXCEPTION, pre-flighted because the rejection is structural (gpt-image-1 cannot ever return URLs — not a numerical cap) and the message "request `:base64` or `:binary`" is more useful than the API's terse 400. *Docs target: `@moduledoc ALLM.Providers.OpenAI.Images` (gating-rationale paragraph).*

## Behaviour & Type Contracts

### `ALLM.Providers.OpenAI.Images` — Layer B adapter

```elixir
defmodule ALLM.Providers.OpenAI.Images do
  @behaviour ALLM.ImageAdapter

  @base_url "https://api.openai.com/v1"

  @model_ops %{
    "dall-e-2" => [:generate, :edit, :variation],
    "dall-e-3" => [:generate],
    "gpt-image-1" => [:generate, :edit]
  }

  @gpt_image_1_only_base64 ["gpt-image-1"]

  @impl ALLM.ImageAdapter
  @spec supported_operations() :: [:generate | :edit | :variation]
  def supported_operations, do: [:generate, :edit, :variation]

  @impl ALLM.ImageAdapter
  @spec generate(ALLM.ImageRequest.t(), keyword()) ::
          {:ok, ALLM.ImageResponse.t()} | {:error, ALLM.Error.ImageAdapterError.t()}
  def generate(%ALLM.ImageRequest{} = request, opts) when is_list(opts)

  @impl ALLM.ImageAdapter
  @spec prepare_request(ALLM.ImageRequest.t(), keyword()) ::
          {:ok, Req.Request.t()} | {:error, ALLM.Error.ImageAdapterError.t()}
  def prepare_request(%ALLM.ImageRequest{} = request, opts) when is_list(opts)

  # Module-internal helper exposed for testing the model-gate alone.
  @doc false
  @spec gate_model_op(String.t() | nil, ALLM.ImageRequest.operation()) ::
          :ok | {:error, ALLM.Error.ImageAdapterError.t()}
  def gate_model_op(model, operation)

  # Module-internal helper exposed for testing endpoint dispatch alone.
  @doc false
  @spec endpoint_for(ALLM.ImageRequest.operation()) :: String.t()
  def endpoint_for(operation)
end
```

**Invariants** (named here so tests can assert directly):

0. **Conformance test-injection short-circuit** (Decision #20) — when `opts[:adapter_opts][:image_script]` is non-nil, `generate/2` delegates to `ALLM.Providers.FakeImages.generate/2` with the same opts BEFORE any pre-flight gate runs. Production callers do not populate this key; only the conformance harness and the adapter's own `images_test.exs` do.
1. **Pre-HTTP gate ordering** — `generate/2` performs gates in this order before any HTTP I/O (and only when invariant 0 did not short-circuit):
   1. Operation gate: `request.operation in supported_operations()`. Failure → `:unsupported_operation`.
   2. Model gate (if `request.model` is non-nil): `request.operation in @model_ops[request.model]` (when `request.model` is in the table). Failure → `:unsupported_operation` with `metadata: %{operation: op, model: model}`.
   3. gpt-image-1 + `:url` rejection (Decision #6): when `request.model == "gpt-image-1"` and `request.response_format == :url`. Failure → `:invalid_request` with `metadata: %{model: "gpt-image-1", response_format: :url}`.
   4. URL-source resolution (only on `:edit` / `:variation`): each `{:url, _}` input image is fetched via `Req.get/1`. Failure → `:invalid_request` or `:network_error` with `metadata.url`.
2. **Key resolution last** — `ALLM.Keys.fetch!(:openai, opts)` is called AFTER all four gates above, mirroring chat-adapter ordering. Rationale: a request that's going to be rejected pre-flight should not require a valid API key.
3. **Request-id preservation** — `opts[:request_id]` is reflected onto `response.request_id` unchanged. When `opts[:request_id]` is absent, the adapter does NOT generate one (the façade in Phase 14.3 generates it; the adapter is downstream). When `opts[:request_id]` is present, it ALSO appears on every error struct's `metadata[:request_id]` regardless of whether HTTP I/O occurred (pre-flight gate failures and HTTP error paths are uniform).
4. **Metadata round-trip** — `request.metadata` is reflected onto `response.metadata` unchanged. The adapter MAY add provider-specific keys (`:openai_request_id`, `:created`, `:usage_details`) to `response.metadata` but never overwrites caller keys.
5. **Multipart vs JSON dispatch** — `:generate` → JSON body; `:edit` / `:variation` → multipart/form-data body. No third path.

### `ALLM.Providers.Support.OpenAIHeaders` — Layer B helper

```elixir
defmodule ALLM.Providers.Support.OpenAIHeaders do
  @spec json_headers(api_key :: String.t(), opts :: keyword()) :: [{String.t(), String.t()}]
  def json_headers(api_key, opts)

  @spec multipart_headers(api_key :: String.t(), opts :: keyword()) :: [{String.t(), String.t()}]
  def multipart_headers(api_key, opts)
end
```

`json_headers/2` returns `[{"authorization", "Bearer #{api_key}"}, {"content-type", "application/json"}, ...optional org]`; `multipart_headers/2` returns the same MINUS the `content-type` (so `Req` sets it with the boundary). Both honor `opts[:adapter_opts][:organization]` per chat-adapter precedent at `lib/allm/providers/openai.ex:443–446`.

### Wire-field map (per agent-spec/DESIGN.md rule 15)

Body fields are top-level on the request body unless otherwise noted in **JSON path**. Response fields read from the body unless noted.

| Concept | OpenAI wire field | JSON path | Endpoint | Notes |
|---|---|---|---|---|
| Prompt | `prompt` (string) | `body.prompt` | all three | required on `:generate` / `:edit`; absent on `:variation` |
| Model | `model` (string) | `body.model` | all three | when `nil`, OpenAI defaults to `dall-e-2` (we send no field) |
| Count | `n` (int) | `body.n` | all three | dall-e-3 caps at `n: 1`; gpt-image-1 / dall-e-2 cap at `n: 10` — NOT pre-flight gated (Decision #23); provider rejects with `:invalid_request` |
| Size | `size` (string `"WIDTHxHEIGHT"` or `"auto"`) | `body.size` | `:generate` / `:edit` | encoded by `to_size_string/1` (private helper): `{w,h}` → `"#{w}x#{h}"`; `:auto` → `"auto"`; binary → passthrough; `nil` → omit |
| Quality | `quality` (string) | `body.quality` | `:generate` (dall-e-3 + gpt-image-1) | dall-e-3: `"standard"|"hd"`; gpt-image-1: `"low"|"medium"|"high"|"auto"` |
| Style | `style` (string) | `body.style` | `:generate` (dall-e-3 only) | atom `:natural \| :vivid` → string |
| Response format | `response_format` (string) | `body.response_format` | `:generate` / `:edit` (dall-e-2/3 only) | dall-e-2/3: `"url"|"b64_json"`. gpt-image-1: OMITTED (Decision #5/#6) — always base64; the request gate rejects `gpt-image-1 + :url` BEFORE HTTP |
| Output format | `output_format` (string) | `body.output_format` | `:generate` (gpt-image-1 only) | `"png"|"jpeg"|"webp"`; default `"png"`; from `request.options[:output_format]`; controls response `:mime_type` per Decision #19 |
| Background | `background` (string) | `body.background` | `:generate` (gpt-image-1 only) | `"transparent"|"opaque"` |
| Input image (multipart) | `image` field (file body) | multipart field `"image"` | `:edit` / `:variation` | from `Image.to_binary/1` or eager URL fetch (Decision #8); Req tuple shape `{bytes, filename: "image.png", content_type: <mime>}` |
| Mask (multipart) | `mask` field (file body) | multipart field `"mask"` | `:edit` only | when `request.mask != nil`; same tuple shape as input image |
| User (telemetry) | `user` (string) | `body.user` | all three | from `request.options[:user]` |
| Output: image URL | `data[i].url` | response.body.data[].url | response | populated when `response_format=url`; → `{:url, url}` source |
| Output: image bytes (base64) | `data[i].b64_json` | response.body.data[].b64_json | response | populated when `response_format=b64_json` OR gpt-image-1; per Decision #5 normalized to caller's requested `:binary` / `:base64` source |
| Output: revised prompt | `data[i].revised_prompt` | response.body.data[].revised_prompt | response (dall-e-3) | onto `Image.revised_prompt` |
| Usage: image-unit count | n/a | n/a | response | computed `length(response.body.data)` → `ImageUsage.images` |
| Usage: input tokens | `usage.input_tokens` | response.body.usage.input_tokens | response (gpt-image-1) | onto `ImageUsage.input_tokens` |
| Usage: output tokens | `usage.output_tokens` | response.body.usage.output_tokens | response (gpt-image-1) | onto `ImageUsage.output_tokens` |
| Usage details | `usage.input_tokens_details` | response.body.usage.input_tokens_details | response (gpt-image-1) | onto `response.metadata[:usage_details]` |
| OpenAI request id | `x-request-id` | response.headers `x-request-id` | response | onto `response.metadata[:openai_request_id]` per Decision #18; distinct from `opts[:request_id]` which lands on `response.request_id` |
| Stop reason | n/a | n/a | n/a | image responses have no stop reason; `usage.images = length(data)` |
| Content filter (200 path) | empty `data: []` | response.body.data | response | maps to `:content_filter` per Decision #5b — accepted-but-stripped is content-policy, NOT malformed |
| Content filter (400 path) | `error.code == "content_policy_violation"` | response.body.error.code | error | maps to `:content_filter` |
| Rate limit | HTTP 429 + `retry-after` header | response.headers `retry-after` | error | maps to `:rate_limited` with `retry_after_ms` populated |

### Error contract

Per Phase 14.1's `ALLM.Error.ImageAdapterError` closed-enum (`lib/allm/error/image_adapter_error.ex:30–68`). Mappings the adapter implements:

| HTTP Status / cause | `error.reason` | `error.message` shape | `metadata` keys | Recovery |
|---|---|---|---|---|
| 401 | `:authentication_failed` | OpenAI body `error.message` | `:request_id, :status` | Surface; no retry |
| 429 | `:rate_limited` | OpenAI body `error.message` | `:request_id, :status, :retry_after_ms` | Retry after `retry_after_ms` (auto via `Retry.run`) |
| 400 with `code: "content_policy_violation"` | `:content_filter` | OpenAI body | `:request_id, :status` | Surface; no retry |
| 200 with empty `data: []` | `:content_filter` | "OpenAI returned no images (likely content-policy filter)" | `:request_id, :status` | Surface; refine prompt |
| 400 (other) | `:invalid_request` | OpenAI body | `:request_id, :status` | Surface; no retry |
| 500/502/503/504 | `:provider_unavailable` | OpenAI body or status text | `:request_id, :status` | Auto-retry |
| Req `:timeout` | `:timeout` | "request timed out after Nms" | `:request_timeout` | Auto-retry |
| Req `Mint.TransportError` etc. | `:network_error` | inspect of cause | `:cause` | Auto-retry |
| 200 with non-JSON or schema-incompatible body (missing `data` key, wrong type) | `:malformed_response` | "could not parse OpenAI response: <reason>" | `:body_preview` (first 200 chars) | Surface |
| Pre-flight: operation gate | `:unsupported_operation` | "operation X not supported by adapter (or by model M)" | `:operation, :model, :request_id` | Programmer error |
| Pre-flight: gpt-image-1 + `:url` | `:invalid_request` | per Decision #6 | `:model, :response_format, :request_id` | Programmer error |
| URL-source fetch failure | `:invalid_request` or `:network_error` | per Decision #8 | `:url, :status` (when set), `:request_id` | Surface; programmer chooses |
| Unknown / catch-all | `:unknown` | inspect of cause | `:cause, :request_id` | Surface |

Per Decision #21, `:context_length_exceeded` is RESERVED in the closed enum but not actively mapped — long-prompt rejections from OpenAI come through as `:invalid_request`. Per Decision #22, `:unsupported_feature` is not produced by this adapter.

`:retry_after_ms` parsing accepts `Integer`-seconds and HTTP-date forms; same regex as chat-adapter `lib/allm/providers/openai.ex` (extracted to a private helper or inlined — implementer's call).

## Module Tree

```
lib/allm/providers/
├── openai.ex                                   (MODIFY — refactor build_headers/2 to delegate)
├── openai/
│   └── images.ex                               (NEW — the adapter)
└── support/
    ├── sse.ex                                  (unchanged)
    └── openai_headers.ex                       (NEW — shared header builder)

scripts/
└── record_openai_image_fixtures.exs            (NEW — recorder mirroring scripts/record_anthropic_fixtures.exs)

test/allm/providers/openai/
├── images_test.exs                             (NEW — generate wire tests + closed-enum errors)
├── images_multipart_test.exs                   (NEW — edit/variation wire tests + multipart builder unit tests)
├── images_conformance_test.exs                 (NEW — `use ALLM.Test.ImageAdapterConformance`)
└── images_live_test.exs                        (NEW — @moduletag :live_openai_images)

test/fixtures/openai/images/
├── README.md                                   (NEW — fixture inventory)
├── recorded/
│   ├── generate_dall_e_2_happy.json            (NEW — recorded)
│   ├── generate_dall_e_3_happy.json            (NEW — recorded)
│   ├── generate_gpt_image_1_happy.json         (NEW — recorded — token usage shape)
│   ├── edit_dall_e_2_happy.json                (NEW — recorded)
│   ├── edit_gpt_image_1_happy.json             (NEW — recorded)
│   └── variation_dall_e_2_happy.json           (NEW — recorded)
└── synthesized/
    ├── auth_failed.json                        (NEW — 401)
    ├── rate_limited.json                       (NEW — 429 body)
    ├── rate_limited.headers.json               (NEW — Retry-After: 1)
    ├── server_error.json                       (NEW — 500)
    ├── invalid_request.json                    (NEW — 400)
    ├── content_filter.json                     (NEW — 400 with code: "content_policy_violation")
    ├── content_filter_empty_data.json          (NEW — 200 with empty data: []; → :content_filter per Decision #5b)
    └── malformed.json                          (NEW — 200 body that fails to decode — missing data key)

test/test_helper.exs                            (MODIFY — exclude :live_openai_images by default)

examples/
├── _helpers.exs                                (MODIFY — add image_engine/1; extend @providers)
├── 10_generate_image.exs                       (NEW)
├── run_all.exs                                 (MODIFY — provider-arm gating per Decision #15)
├── README.md                                   (MODIFY — add "Image generation" subsection)
└── RUN_OUTPUT_OPENAI.md                        (MODIFY — refreshed snapshot)

CHANGELOG.md                                    (MODIFY — Phase 15 entries)
```

Test files under `test/allm/providers/openai/` mirror `lib/allm/providers/openai/` 1:1 (matching the project's `lib/`-mirrors-`test/` convention).

## Phases

### Phase 15.1: Skeleton, gates, dispatch (no HTTP) (Layer B)

**Goal:** `ALLM.Providers.OpenAI.Images` exists, implements `ALLM.ImageAdapter`, declares `supported_operations/0`, gates operations + models + gpt-image-1 + `:url` BEFORE any HTTP. `generate/2` for an unsupported operation returns `:unsupported_operation` correctly. No HTTP yet — `generate/2` returns `{:error, %ImageAdapterError{reason: :unknown, message: "phase 15.2 stub"}}` for ANY successful gate path. The conformance suite fails at the "happy path" case but passes the "unsupported operation" case.

**Spec sections:** §35.7 (introduction), §35.3 (behaviour conformance).

#### 15.1 Test Plan

`test/allm/providers/openai/images_test.exs` (NEW):
- `supported_operations/0 returns [:generate, :edit, :variation]`
- `generate/2 with operation: :foo (atom not in supported_operations) returns {:error, %ImageAdapterError{reason: :unsupported_operation}}`
  - Asserts `error.metadata[:operation] == :foo`.
- `generate/2 with operation: :variation and model: "dall-e-3" returns :unsupported_operation with metadata model + operation`
- `generate/2 with operation: :edit and model: "dall-e-3" returns :unsupported_operation`
- `generate/2 with operation: :variation and model: "gpt-image-1" returns :unsupported_operation`
- `generate/2 with operation: :generate and model: "dall-e-3" passes the model gate (HTTP stub returns the phase-15.1 stub error)`
- `generate/2 with operation: :generate and model: nil passes the model gate (unknown model = passthrough per Decision #3)`
- `generate/2 with operation: :generate and model: "gpt-image-1" and response_format: :url returns :invalid_request with metadata model + response_format`
- `generate/2 with operation: :generate and model: "gpt-image-1" and response_format: :base64 passes (stub error)`
- `endpoint_for/1 returns the correct path for each operation`
- `gate_model_op/2 returns :ok for legal pairs and {:error, ...} for illegal pairs across the full @model_ops table` (table-driven)
- Conformance suite (`use ALLM.Test.ImageAdapterConformance`) passes ALL 9 cases at this sub-phase: per Decision #20 / Invariant 0, the adapter honors `adapter_opts[:image_script]` as a test-injection short-circuit that delegates to `FakeImages` BEFORE any pre-flight gate runs, so cases 3–9 (which all populate `image_script`) succeed without HTTP. Case 2 (unsupported operation) tests through `GenerateOnlyImageStub` per the harness's branch logic and is unaffected by this adapter's gates.

#### 15.1 Implementation Checklist

- [ ] Create `lib/allm/providers/openai/images.ex` with the module skeleton.
- [ ] Implement `supported_operations/0`.
- [ ] Implement `gate_model_op/2` and `endpoint_for/1` (both `@doc false`).
- [ ] Implement Invariant 0 (test-injection short-circuit, Decision #20): when `opts[:adapter_opts][:image_script]` is non-nil at the top of `generate/2`, delegate to `ALLM.Providers.FakeImages.generate/2` with the same opts and return its result.
- [ ] Implement `generate/2` performing the four pre-HTTP gates in order (after Invariant 0 check), returning a stub `{:error, %ImageAdapterError{reason: :unknown, message: "phase 15.2 stub"}}` on success. (Phase 15.2 replaces the stub.)
- [ ] Implement `prepare_request/2` running the four pre-flight gates first, then returning `{:error, stub_error()}` on success (gate failures surface uniformly across both entry points per Invariant 3); the `:image_script` branch ALSO returns the stub error (no `Req.Request` analogue for scripts).
- [ ] Add `@spec`s matching this design's contract verbatim.
- [ ] Wire `ALLM.Providers.Support.OpenAIHeaders` (NEW) — `json_headers/2` and `multipart_headers/2` only; the existing chat adapter is NOT yet refactored to use it. Refactor lands in 15.2 alongside the JSON path.
- [ ] Coverage ≥90% on new code.

#### 15.1 Verification

```bash
mix test test/allm/providers/openai/images_test.exs
mix credo --strict lib/allm/providers/openai/images.ex lib/allm/providers/support/openai_headers.ex
mix dialyzer
```

### Phase 15.2: `:generate` over dall-e-2 / dall-e-3 (JSON, Req, retry)

**Goal:** `:generate` works end-to-end against recorded fixtures for `dall-e-2` and `dall-e-3` via `Req.Test.stub`. Closed-enum error mapping covers all HTTP error classes the synthesized fixtures define. `ALLM.Retry.run/3` integration verified for 429 + `Retry-After`.

#### 15.2 Test Plan

`test/allm/providers/openai/images_test.exs` (extended):

**Wire-shape (recorded fixtures):**
- `:generate dall-e-2 happy path → {:ok, %ImageResponse{}}` with `:base64` request format, response carries `{:base64, _}` source, `mime_type: "image/png"`, `Image.revised_prompt` populated when present.
- `:generate dall-e-2 happy path with :binary request format → response carries {:binary, bytes}, bytes are Base64-decoded`.
- `:generate dall-e-2 happy path with :url request format → response carries {:url, url} source`.
- `:generate dall-e-3 happy path → {:ok, %ImageResponse{}}` with `:revised_prompt` populated and `usage.images == 1`.
- Multi-image batch: `:generate dall-e-2 with n: 4 → response.images has 4 entries, usage.images == 4`.

**Wire-shape (synthesized errors):**
- 401 → `:authentication_failed` with `:request_id`/`:status` populated.
- 429 + `Retry-After: 1` → first call `:rate_limited` with `retry_after_ms: 1000`; under `ALLM.Retry.run` with `max_attempts: 2`, the second call against a happy-path stub succeeds and the test sees `{:ok, response}`.
- Pre-flight gate failure (operation gate) returns error with `metadata[:request_id]` reflecting `opts[:request_id]` (Invariant 3 — error path uniformity).
- 500 → `:provider_unavailable`; under `Retry.run` retries and surfaces failure when retries exhausted.
- 400 → `:invalid_request` with `error.message` populated.
- 400 with `code: "content_policy_violation"` → `:content_filter`.
- 200 with non-JSON body → `:malformed_response` with `body_preview` (first 200 chars).
- 200 with empty `data: []` → `:content_filter` with message "OpenAI returned no images (likely content-policy filter)" (per Decision #5b).

**Request-shape (asserted on the body sent to the stub):**
- `:generate dall-e-2 sends body `{model: "dall-e-2", prompt: "...", n: 1, size: "256x256", response_format: "b64_json"}`.
- `:generate dall-e-3 sends `{model: "dall-e-3", prompt: "...", n: 1, size: "1024x1024", quality: "hd", style: "vivid"}` when those fields are populated on `ImageRequest`.
- `:generate sends `user` field when `request.options[:user]` is set.
- Authorization header is `Bearer <api_key>` from `ALLM.Keys.fetch!`.
- `openai-organization` header is set when `adapter_opts[:organization]` is supplied.

**Telemetry:**
- `[:allm, :image, :start]` and `[:allm, :image, :stop]` fire with `request_id` matching `opts[:request_id]` when set. (This is the Phase 14.3 façade-side behaviour; sanity-check at the adapter entry point — the adapter does NOT fire telemetry; the façade does.)

**`prepare_request/2`:**
- `prepare_request/2` returns an unfired `Req.Request` with the correct URL (`/v1/images/generations`), method `:post`, `json:` body matching the request-shape assertions, and the API key in the `Authorization` header.

**Conformance suite:**
- `use ALLM.Test.ImageAdapterConformance, image_adapter: ALLM.Providers.OpenAI.Images` — happy path now passes. (The conformance harness at `conformance/lib/allm/test/image_adapter_conformance.ex:55` only consumes `:image_adapter`; happy-path wire-stub injection is the adapter's responsibility under `Req.Test`, not a harness option.)

#### 15.2 Implementation Checklist

- [ ] Replace the 15.1 stub in `generate/2` with the full JSON path for `:generate`:
  - [ ] Build the request body via `to_json_body/2`.
  - [ ] Build URL via `endpoint_for/1` + `@base_url`.
  - [ ] Call `ALLM.Keys.fetch!(:openai, opts)`.
  - [ ] Build headers via `ALLM.Providers.Support.OpenAIHeaders.json_headers/2`.
  - [ ] Construct the `Req.Request` (mirroring chat adapter at `lib/allm/providers/openai.ex:424–434`); apply `:plug` if present; apply `:request_timeout` if present.
  - [ ] Wrap the HTTP call in `ALLM.Retry.run(opts[:retry] || :default, request_id, fn -> ... end)` per Decision #10.
- [ ] Implement `to_json_body/2` — encodes prompt/model/n/size/quality/style/response_format/background/user per the wire-field map. Uses `to_size_string/1` private helper for the `size` field encoding (`{w,h}` → `"#{w}x#{h}"`; `:auto` → `"auto"`; binary passthrough; `nil` → omitted).
- [ ] Implement `to_size_string/1` private helper with the four-branch closed table per the wire-field map row.
- [ ] Implement `decode_response/3` — parses 2xx body, maps to `%ImageResponse{}` per Decision #5 (response-format normalization for non-gpt-image-1 paths) and §15.3 for gpt-image-1.
- [ ] Implement `to_image_adapter_error/2` — maps HTTP status + body + cause to `%ImageAdapterError{}` per the error contract table.
- [ ] Implement `parse_retry_after/1` (private; pull from chat adapter or extract a shared helper).
- [ ] Refactor `lib/allm/providers/openai.ex` `build_headers/2` to delegate to `ALLM.Providers.Support.OpenAIHeaders.json_headers/2`. Same-LOC, behaviour-preserving.
- [ ] Add `prepare_request/2` for `:generate` mirroring chat-adapter shape.
- [ ] Record the three happy-path fixtures via `scripts/record_openai_image_fixtures.exs` (one-time live run, costs ~$0.10).
- [ ] Hand-write the seven synthesized error fixtures.
- [ ] Coverage ≥90% on the new path.

#### 15.2 Verification

```bash
mix test test/allm/providers/openai/images_test.exs
mix test test/allm/providers/openai/images_conformance_test.exs
mix credo --strict lib/allm/providers/openai/images.ex lib/allm/providers/openai.ex lib/allm/providers/support/openai_headers.ex
mix dialyzer
```

### Phase 15.3: gpt-image-1 generate (forced base64 + token usage)

**Goal:** `:generate` against `gpt-image-1` works against the recorded fixture. Response-format normalization correctly handles "always returns base64" by Base64-decoding to `:binary` when the caller asked binary. Token usage (`input_tokens` / `output_tokens`) populates `ImageUsage`.

#### 15.3 Test Plan

- `:generate gpt-image-1 happy path with :binary request format → response.images[0].source == {:binary, bytes}, bytes = Base64.decode!(b64_json from fixture)`.
- `:generate gpt-image-1 happy path with :base64 request format → response.images[0].source == {:base64, b64}` (no decode).
- `:generate gpt-image-1 with :url request format → {:error, :invalid_request} BEFORE HTTP per Decision #6`.
- `:generate gpt-image-1 sends body WITHOUT response_format field` (request-shape assertion).
- `:generate gpt-image-1 happy path populates usage.input_tokens, usage.output_tokens, usage.images`.
- `:generate gpt-image-1 with options: %{output_format: "webp"} → response.images[0].mime_type == "image/webp"`.
- `:generate gpt-image-1 happy path populates usage_details on response.metadata when present in the response body`.

#### 15.3 Implementation Checklist

- [ ] Extend `to_json_body/2` to:
  - [ ] OMIT `response_format` when `request.model == "gpt-image-1"`.
  - [ ] Include `quality` and `background` per the wire-field map.
  - [ ] Pass through `request.options[:output_format]` and `request.options[:user]`.
- [ ] Extend `decode_response/3` to:
  - [ ] Detect gpt-image-1 by `request.model`; if so, force-Base64-decode for `:binary` callers; pass through for `:base64` callers.
  - [ ] Populate `ImageUsage.input_tokens` / `output_tokens` / `images` from response `usage` map (gpt-image-1 only).
  - [ ] Populate `response.metadata[:usage_details]` from `usage.input_tokens_details` (if present).
  - [ ] Resolve `mime_type` from `request.options[:output_format]` ("webp"/"jpeg"/"png") with default `"image/png"`.
- [ ] Record the gpt-image-1 happy fixture (~$0.04 one-time; uses smallest available size).
- [ ] Coverage ≥90% on the new branches.

#### 15.3 Verification

```bash
mix test test/allm/providers/openai/images_test.exs
mix credo --strict lib/allm/providers/openai/images.ex
mix dialyzer
```

### Phase 15.4: `:edit` (multipart + URL eager-download)

**Goal:** `:edit` works end-to-end across `dall-e-2` and `gpt-image-1` against recorded fixtures. Multipart body builder produces correct field tuples for input image + optional mask. `{:url, _}` source images are eagerly fetched at request-build time and the bytes are included in the multipart payload.

#### 15.4 Test Plan

`test/allm/providers/openai/images_multipart_test.exs` (NEW):

**Multipart-builder unit tests (`to_multipart_body/2`):** (Req tuple shape: `{name, value}` for plain fields; `{name, {body, filename: "...", content_type: "..."}}` for file fields per `deps/req/lib/req/steps.ex:446–468`.)
- `to_multipart_body/2 for :edit with binary-source base image returns [{"image", {bytes, filename: "image.png", content_type: "image/png"}}, {"prompt", _}, {"model", _}, ...]`.
- `to_multipart_body/2 for :edit with mask returns the mask field with the correct binary in the same `{body, filename:, content_type:}` tuple shape`.
- `to_multipart_body/2 for :edit with file-source image reads File.read!/1 and includes bytes`.
- `to_multipart_body/2 for :edit with base64-source image Base64-decodes and includes bytes`.
- `to_multipart_body/2 for :edit with URL-source image calls Req.get/1 against the URL and includes bytes` (HTTP stub via `Req.Test.stub` injected through opts).
- `to_multipart_body/2 for :edit with URL-source where Req.get returns 404 → returns {:error, %ImageAdapterError{reason: :invalid_request, metadata: %{url: _, status: 404}}}`.
- `to_multipart_body/2 for :edit with URL-source where Req.get returns non-image content-type → :invalid_request with metadata content_type`.
- `to_multipart_body/2 for :edit with URL-source where Req.get returns body > 25 MB → :invalid_request with metadata.size` (Decision #8).
- `to_multipart_body/2 for :edit with URL-source where Req emits Req.TooManyRedirectsError → :invalid_request` (Decision #8 redirect cap).
- `to_multipart_body/2 for :edit with URL-source where Req.get times out → :network_error`.

**Wire-shape:**
- `:edit dall-e-2 happy → {:ok, %ImageResponse{}}` with response decoded the same way `:generate` decodes (same data: [...] shape).
- `:edit gpt-image-1 happy → {:ok, %ImageResponse{}}` with token usage.
- `:edit dall-e-2 with mask sends mask multipart field`.
- `:edit dall-e-2 without mask omits mask field`.
- `:edit dall-e-3 → :unsupported_operation BEFORE HTTP` (Phase 15.1 behaviour; smoke-test the path is integrated).

**Request-shape:**
- `:edit dall-e-2 sends content-type: multipart/form-data` (Req sets the boundary).
- `:edit gpt-image-1 sends body WITHOUT response_format field` (per Decision #5; same gpt-image-1 rule as `:generate`).

**Routing:**
- `endpoint_for(:edit) == "/images/edits"`.

#### 15.4 Implementation Checklist

- [ ] **Field-applicability hint (from 15.3 retro Finding 2):** before writing `to_multipart_body/2`, factor a model-aware predicate layer (e.g. `fields_for(:edit, model)`) shared with `to_json_body/2`'s gpt-image-1 conditional `put_*` clauses (`put_response_format`, `put_background`, `put_output_format`). The shared work is "which fields apply for this model × operation"; only the leaf serializer (map vs `[{name, value}]` tuple list) diverges. Land the predicate first to avoid a parallel re-implementation of the same conditionals.
- [ ] Implement `to_multipart_body/2` per the wire-field map. Returns `{:ok, [{name, content}, ...]} | {:error, %ImageAdapterError{}}`.
- [ ] Implement `resolve_image_bytes/2` private helper. Returns `{:ok, bytes, mime_type, filename} | {:error, %ImageAdapterError{}}`:
  - [ ] `{:binary, b}` → `{:ok, b, mime_type, "image.png"}` (filename always "image.png" — OpenAI ignores the filename for content-type resolution).
  - [ ] `{:base64, b}` → Base64-decode → bytes; on `Base64.DecodeError` → `:invalid_request`.
  - [ ] `{:file, path}` → `File.read/1` → bytes; mime_type from `image.mime_type` field (Phase 13's `from_file/1` already populates); on `File.Error` → `:invalid_request`.
  - [ ] `{:url, u}` → `Req.get(u, receive_timeout: opts[:request_timeout] || 30_000, max_redirects: 5)`; check 2xx + image content-type prefix-match (`~r{^image/(png|jpeg|jpg|webp|gif)$}`); enforce 25 MB cap; bytes from response. Failure modes per Decision #8.
- [ ] Wire `:edit` and `:variation` paths in `generate/2` to call `to_multipart_body/2` then `Req.new(url:, headers:, form_multipart: form)` with `multipart_headers/2`. Confirm `Req.merge(req, plug: plug)` still applies for `Req.Test.stub` integration on multipart paths.
- [ ] Record `:edit dall-e-2` and `:edit gpt-image-1` happy fixtures (~$0.05 + $0.04 one-time).
- [ ] Coverage ≥90% on multipart paths.

#### 15.4 Verification

```bash
mix test test/allm/providers/openai/images_multipart_test.exs
mix test test/allm/providers/openai/
mix credo --strict lib/allm/providers/openai/images.ex
mix dialyzer
```

### Phase 15.5: `:variation` + live smoke test

**Goal:** `:variation` works against `dall-e-2` (the only supported model) via recorded fixture. Live smoke test against real OpenAI succeeds for `dall-e-2:generate` when `OPENAI_API_KEY` is set.

#### 15.5 Test Plan

`test/allm/providers/openai/images_multipart_test.exs` (extended):
- `:variation dall-e-2 happy → {:ok, %ImageResponse{}}`.
- `:variation dall-e-2 sends content-type: multipart/form-data with single "image" field, no "prompt"`.
- `:variation dall-e-3 → :unsupported_operation BEFORE HTTP`.
- `:variation gpt-image-1 → :unsupported_operation BEFORE HTTP`.

`test/allm/providers/openai/images_live_test.exs` (NEW):
- `@moduletag :live_openai_images`.
- `if System.get_env("OPENAI_API_KEY") in [nil, ""], do: @moduletag :skip`.
- Test 1 — `live: dall-e-2 generate at size 256x256 returns one image, usage.images == 1, image bytes decode as PNG`. Asserts `<<137, 80, 78, 71, _::binary>>` PNG signature on the decoded bytes.
- Test 2 — `live: dall-e-2 edit with a fixture base image at 256x256 returns one image, usage.images == 1, multipart wire path validated end-to-end`. Per Decision #16 (Rule 16 closure): the only automated check that the multipart body the adapter constructs is wire-correct against real OpenAI. Reads a small committed PNG from `test/fixtures/openai/images/inputs/sample_256.png` (NEW small fixture — checked into the repo; ~2 KB). Live cost ~$0.02. `:variation` is NOT live-tested (subset of `:edit`'s multipart shape).

`test/test_helper.exs` (MODIFY):
- Add `:live_openai_images` to the `ExUnit.start(exclude: [...])` list.

#### 15.5 Implementation Checklist

- [ ] Wire `:variation` path through the existing `:edit` multipart machinery (only difference: omits `prompt` and `mask` fields).
- [ ] Record `:variation dall-e-2` happy fixture (~$0.018 one-time).
- [ ] Commit a small `test/fixtures/openai/images/inputs/sample_256.png` (~2 KB; hand-created or generated once during initial setup). This is a TEST INPUT fixture, not a recorded response — checked in alongside the recorded fixtures so the live `:edit` test has a deterministic input.
- [ ] Add live smoke test module with both `:generate` and `:edit` live tests.
- [ ] Update `test/test_helper.exs` to exclude `:live_openai_images` by default.
- [ ] Coverage ≥90%.

#### 15.5 Verification

```bash
mix test test/allm/providers/openai/
# Optional live (costs ~$0.05):
OPENAI_API_KEY=sk-... mix test --include live_openai_images test/allm/providers/openai/images_live_test.exs
mix credo --strict lib/allm/providers/openai/images.ex
mix dialyzer
```

### Phase 15.6: Examples + run_all gate

**Goal:** `examples/10_generate_image.exs` runs end-to-end against real OpenAI when `OPENAI_API_KEY` is set; integrates into `run_all.exs` for the OpenAI provider arm only (skipped on Anthropic per Decision #15); `RUN_OUTPUT_OPENAI.md` snapshot refreshed.

#### 15.6 Test Plan

This phase has NO `mix test` deliverable — it is the BLOCKING `/review` examples-gate per principle #6. Verification is operational:

- `OPENAI_API_KEY=sk-... mix run examples/10_generate_image.exs` exits 0 and prints a sensible report (image saved to a tmp file or path; usage line; revised_prompt if dall-e-3).
- `OPENAI_API_KEY=sk-... mix run examples/run_all.exs` includes `10_generate_image.exs` in the OpenAI arm, all examples pass.
- `ANTHROPIC_API_KEY=sk-ant-... ALLM_PROVIDER=anthropic mix run examples/run_all.exs` SKIPS `10_generate_image.exs` (provider-arm gating per Decision #15) with a `[SKIP]` marker; existing examples 01-09 continue to run.
- `RUN_OUTPUT_OPENAI.md` reflects the new run including `10_generate_image.exs`.

Unit tests on the helper module (`examples/_helpers.exs`) are not required (the helper is non-library code; the BLOCKING gate is the `run_all.exs` exit code).

#### 15.6 Implementation Checklist

- [ ] Restructure `examples/_helpers.exs` `@providers` from `%{provider => {adapter, default_model, key_env}}` 3-tuple values to map values `%{provider => %{adapter:, default_model:, key_env:, image_adapter:, image_default_model:}}` (Decision #14). Update `engine/1`'s destructure at line 32 from `{adapter, default_model, key_env} = row` to `%{adapter: adapter, default_model: default_model, key_env: key_env} = row` — behaviour-preserving.
- [ ] Add `image_engine/1` constructor sister to `engine/1`. Look up `:image_adapter` / `:image_default_model` from the row; raise `ArgumentError` with a clear message when those are `nil` for the active provider.
- [ ] Write `examples/10_generate_image.exs`:
  - [ ] Header comment: `# Provider: openai` (consumed by `run_all.exs` per Decision #15).
  - [ ] Use `image_engine/1` to build the engine.
  - [ ] Call `ALLM.generate_image(engine, "a watercolor kestrel in flight", size: "256x256")` against `dall-e-2`. (Per 15.4 retro — if any future image example needs an input image, prefer a `:binary` or `:file` source over `:url` so the BLOCKING gate does not depend on third-party URL availability.)
  - [ ] Materialize `response.images[0]` via `ALLM.Image.to_binary/1`; write to a tmp file; assert PNG signature.
  - [ ] Print a one-line summary including image count, usage.images, and tmp file path.
  - [ ] Exit non-zero if anything fails — use `IO.puts(:stderr, "FAIL: ...")` and `System.halt(1)` mirroring existing example scripts.
- [ ] Update `examples/run_all.exs` to grep for `# Provider: <name>` headers and skip mismatched provider scripts (Decision #15). Print `[SKIP]` for skipped scripts.
- [ ] Update `examples/README.md` with an "Image generation" subsection.
- [ ] Run `OPENAI_API_KEY=sk-... mix run examples/run_all.exs` and capture the new `RUN_OUTPUT_OPENAI.md` snapshot.
- [ ] Update `CHANGELOG.md` with the Phase 15 entries.

#### 15.6 Verification

```bash
# Mandatory live BLOCKING gate per principle #6:
OPENAI_API_KEY=sk-... mix run examples/run_all.exs       # exit 0, includes 10_generate_image.exs
ANTHROPIC_API_KEY=sk-ant-... ALLM_PROVIDER=anthropic mix run examples/run_all.exs   # exit 0, skips 10_*

# Standalone:
OPENAI_API_KEY=sk-... mix run examples/10_generate_image.exs

# Final unit-test gate (verify nothing regressed):
mix test
mix credo --strict
mix dialyzer
mix format --check-formatted
```

## Test Plan (cross-phase)

**Unit tests** are detailed per sub-phase above. Headcount: ~45 wire tests (3 ops × 3 models × happy/error rows + per-model gating × multipart × URL-fetch) + ~20 unit tests on private helpers (gates, multipart builder, decoder, error mapper).

**Conformance suite**: `test/allm/providers/openai/images_conformance_test.exs` invokes `use ALLM.Test.ImageAdapterConformance, image_adapter: ALLM.Providers.OpenAI.Images, ...` from the published `conformance/` package per Phase 14.1's `ALLM.Test.ImageAdapterConformance`. Asserts:
- Returns `:unsupported_operation` for operations not in `supported_operations()` BEFORE any HTTP.
- Preserves `request_id` from `opts` onto response.
- Round-trips `request.metadata` onto `response.metadata` unchanged.

The conformance suite is parameterized to accept a `Req.Test.stub`-driven happy-path setup, mirroring how the chat conformance suite works against `ALLM.Providers.OpenAI`.

**Integration tests** (cross-module): `test/allm/allm_generate_image_openai_test.exs` (NEW) — happy-path `ALLM.generate_image/3` end-to-end against the OpenAI Images adapter via Req.Test stub, asserting telemetry `[:allm, :image, :start | :stop]` events fire and the response shape round-trips through `Jason` and `:erlang.term_to_binary/1` (Layer A round-trip on the response struct already verified Phase 13 — re-run sanity-check here).

**Property tests**: None new — image data structs already have property tests from Phase 13.

**Doctests**: `@doc` for `supported_operations/0`, `endpoint_for/1`, and the moduledoc header carry minimal compile-time-cheap doctests (no live HTTP). E.g.:
```elixir
iex> ALLM.Providers.OpenAI.Images.supported_operations()
[:generate, :edit, :variation]

iex> ALLM.Providers.OpenAI.Images.endpoint_for(:generate)
"/images/generations"
```
The `prepare_request/2` `@doc` carries a doctest mirroring the chat adapter's pattern at `lib/allm/providers/openai.ex:399–408`: `ALLM.Keys.put(:openai, "sk-doctest")`, build an `ImageRequest`, call `prepare_request/2`, assert on the unfired `Req.Request`'s URL path and `Authorization` header. No `Req.Test.stub` in doctests — that pattern is for wire tests in the test file. `generate/2` doctests use the conformance test-injection short-circuit (Decision #20) by passing `adapter_opts: [image_script: [{:ok, [%Image{...}]}]]` for a deterministic happy-path example without HTTP.

**Coverage**: ≥90% on `lib/allm/providers/openai/images.ex` and `lib/allm/providers/support/openai_headers.ex`. The 80% global floor is unchanged.

**Stream-equivalence**: N/A — image generation is non-streaming per spec §35.1 design goal #2.

## Error Contract

(Reproduced and consolidated from Behaviour & Type Contracts → "Error contract" table above.)

| Function | Error reason | Recovery guidance |
|---|---|---|
| `generate/2` | `:authentication_failed` | OpenAI rejected the key; surface, do not retry. |
| `generate/2` | `:rate_limited` | 429; auto-retry honored via `Retry.run` + `Retry-After`. |
| `generate/2` | `:content_filter` | Provider safety rejected the prompt or input image; surface. |
| `generate/2` | `:invalid_request` | 400 (including long-prompt rejections from gpt-image-1) OR pre-flight gate (gpt-image-1 + `:url`) OR URL-source fetch returned non-image / oversized / too many redirects; surface. |
| `generate/2` | `:provider_unavailable` | 5xx; auto-retry. |
| `generate/2` | `:timeout` | `request_timeout` exceeded; auto-retry. |
| `generate/2` | `:network_error` | TCP/TLS/DNS failure or URL-source fetch network failure; auto-retry. |
| `generate/2` | `:malformed_response` | 200 with empty `data` or undecodable body; surface. |
| `generate/2` | `:unsupported_operation` | Operation not in `supported_operations()` OR not supported by `request.model`; programmer error. |
| `generate/2` | `:unknown` | Catch-all; surface. |

`{:error, term()}` does not appear in any `@spec`. Every error path returns `{:error, %ALLM.Error.ImageAdapterError{}}` per the closed-enum contract from Phase 14.1. `:context_length_exceeded` and `:unsupported_feature` are NOT actively produced by this adapter (Decisions #21, #22); they remain valid atoms on the closed enum for future adapters / provider behaviour.

## Definition of Done

- [ ] All sub-phases (15.1–15.6) marked `Completed`.
- [ ] `mix test` zero failures, zero `unused_var` warnings, coverage ≥80% globally and ≥90% on `lib/allm/providers/openai/images.ex` + `lib/allm/providers/support/openai_headers.ex`.
- [ ] `mix credo --strict` zero issues on changed files.
- [ ] `mix dialyzer` zero new warnings vs. prior PLT.
- [ ] `mix format --check-formatted` passes.
- [ ] Every new public function has `@spec` and `@doc`; doctests on `supported_operations/0`, `endpoint_for/1`.
- [ ] No new Layer A struct fields → no new serializability tests required (Phase 13 round-trip tests still pass against unchanged structs).
- [ ] `ALLM.Test.ImageAdapterConformance` passes for `ALLM.Providers.OpenAI.Images` (Phase 14.1's conformance package — no changes to it required).
- [ ] No new behaviour-conformance suites added; no stream-equivalence properties added.
- [ ] Spec section references in commit messages match `§35.7` (and where relevant, `§6.4`, `§7.2`, `§35.9`).
- [ ] `CHANGELOG.md` entries:
  - `[FEAT] ALLM.Providers.OpenAI.Images per §35.7 — supports dall-e-2 (generate/edit/variation), dall-e-3 (generate), gpt-image-1 (generate/edit).`
  - `[REFACTOR] Extract ALLM.Providers.Support.OpenAIHeaders shared between chat and image adapters.`
  - `[FEAT] examples/10_generate_image.exs runnable against dall-e-2.`
- [ ] `examples/RUN_OUTPUT_OPENAI.md` refreshed.
- [ ] Reviewed via `/review` per `agent-spec/REVIEW.md` — BLOCKING examples gate (`OPENAI_API_KEY=sk-... mix run examples/run_all.exs` exit 0; `ALLM_PROVIDER=anthropic mix run examples/run_all.exs` exit 0 with `[SKIP]` for `10_*.exs`).
