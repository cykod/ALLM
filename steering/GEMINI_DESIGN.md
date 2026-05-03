# Phase 16: Google Gemini provider (chat + images) — Design Document

> **Goal:** Ship `ALLM.Providers.Gemini` as a third bundled chat adapter (`Adapter` + `StreamAdapter`) and `ALLM.Providers.Gemini.Images` as a second bundled image adapter, covering text generation, streaming, tool calling, multimodal input, and Gemini-native image generation against `https://generativelanguage.googleapis.com/v1beta`.
> **Outcome:** All ten `examples/` scripts (01–10) run green under `ALLM_PROVIDER=gemini mix run examples/run_all.exs` against the live Gemini API, the `AdapterConformance` / `StreamAdapterConformance` / `ImageAdapterConformance` suites pass, and per-call costs land within the per-clean-run budget below.
> **Spec sections:** §6.4 (key resolution), §7.1 (Adapter), §7.2 (StreamAdapter), §8 (Event protocol), §20 (Error model), §32.1 (Initial adapters — refines), §35.3 (ImageAdapter), §35.6 (Vision in chat), §35.7 (Provider adapters in v0.3 — refines).
> **Layers touched:** B (every sub-phase). Each provider adapter is pure Layer B; Layer A/C/D consumers see no surface change. Multi-layer touch is explicitly out of scope.

## Spec amendments required before implementation

This phase **refines** two spec sections; both amendments must land as a single spec PR before Phase 16.1 begins:

1. **§32.1 (Initial adapters)** — add `ALLM.Providers.Gemini` to the bundled chat-adapter set alongside OpenAI, Anthropic, Fake.
2. **§35.7 (Provider adapters in v0.3)** — currently states "Google Imagen … out of core and expected to ship as separate packages." Replace with the following bundling rule:

   > **Bundled-adapter rule.** v0.3 bundles `ALLM.Providers.OpenAI.Images` and `ALLM.Providers.Gemini.Images`. Both implement `ALLM.ImageAdapter` against their provider's image-generation surface that **shares a translator with the same provider's chat surface** — OpenAI's `/v1/images/*` reuses prompt-text and base64 part shapes; Gemini-native image generation IS the chat surface (`generateContent` with `responseModalities`). Adapters covering wholly distinct image-only API surfaces — Imagen `:predict` (`imagen-4.0-*`), Stability, Replicate, fal.ai — are out of core and ship as separate Hex packages implementing the same `ALLM.ImageAdapter` behaviour. The principle is pragmatic, not architectural: in-tree adapters are the ones whose maintenance overlaps with their provider's already-bundled chat adapter.

   Concrete consequence: a future `ALLM.Providers.Gemini.Imagen` (covering Imagen `:predict`) is structurally identical to a bundled adapter — same behaviour, same `Engine.image_adapter` plug-in — but ships as a separate package because its translator does not amortize with `Gemini`'s chat translator.

## Status

| Phase | Description | Layer | Status |
|-------|-------------|-------|--------|
| 16.1  | Skeleton + non-streaming chat (`generateContent`, text-only, no tools) | B | Not Started |
| 16.2  | Streaming chat (`streamGenerateContent?alt=sse`) | B | Not Started |
| 16.3  | Tool calling (function declarations + `functionCall`/`functionResponse` round-trip) — both paths | B | Not Started |
| 16.4  | Multimodal input (`ALLM.ImagePart` → `inlineData`) — both paths | B | Not Started |
| 16.5  | `ALLM.Providers.Gemini.Images` (native image-out via `responseModalities`) | B | Not Started |
| 16.6  | Examples wiring + live-API validation gate | B | Not Started |
| 16.7  | `Response.raw_finish_reason` round-trip through `StreamCollector` (cross-phase: Event payload widening + collector fold + adapter-trio emitter wiring; closes the 16.2 stream-equivalence relaxation) | B | Not Started |

**Overall Progress:** 0/6 phases complete.

## Overview

ALLM ships two production provider adapters today (OpenAI, Anthropic). Gemini is the highest-value missing third — it's the only major provider with a substantively different wire shape (role collapse, parts-as-tagged-union, function-call args as object not string, top-level `systemInstruction`, `usageMetadata` rather than `usage`) so adding it forces the public Layer-A/B/C contracts to remain genuinely provider-neutral instead of OpenAI/Anthropic-shaped by accident. Gemini also unlocks the only major provider with native, conversational image generation via the same chat endpoint — `gemini-3.1-flash-image-preview` is invoked through `generateContent` with `responseModalities: ["TEXT", "IMAGE"]`, which means the chat translator is reused verbatim and the `Gemini.Images` adapter is a thin wrapper that swaps the response decoder. Finally, this phase is the first chance to amortize the lessons from PHASE_10 (OpenAI dual-translator pain) and PHASE_11 (Anthropic streaming SSE rework) on a single-translator provider — the simplest of the three.

- **Deliverables.** `lib/allm/providers/gemini.ex` (chat adapter; both `@behaviour ALLM.Adapter` and `@behaviour ALLM.StreamAdapter`); `lib/allm/providers/gemini/images.ex` (`@behaviour ALLM.ImageAdapter`); `examples/_helpers.exs` extended with `"gemini"` row; `examples/RUN_OUTPUT_GEMINI.md` artifact from a clean live-validation run; `CHANGELOG.md` entry.
- **Spec coverage.** Implements §7.1, §7.2, §35.3 against a new provider; refines §32.1 and §35.7 (amendments above).
- **Layer demonstration.** Every sub-phase is Layer B (provider adapter only). Layer A `%ALLM.Request{}`, `%ALLM.Response{}`, `%ALLM.Event{}`, `%ALLM.ImageRequest{}`, `%ALLM.ImageResponse{}` shapes are unchanged. Layer C `ALLM.generate/3`, `ALLM.stream_generate/3`, `ALLM.generate_image/3` consume the new adapter through the existing `Engine{:adapter, :stream_adapter, :image_adapter}` dispatch — no Layer C changes. Layer D session helpers see no change. The single Layer-B snippet that demonstrates this:

  ```elixir
  # Layer B — engine construction with Gemini
  engine =
    ALLM.Engine.new(
      adapter: ALLM.Providers.Gemini,
      stream_adapter: ALLM.Providers.Gemini,
      image_adapter: ALLM.Providers.Gemini.Images,
      model: "gemini-3-flash-preview"
    )

  # Layer C usage — unchanged surface
  {:ok, response}  = ALLM.generate(engine, request)
  {:ok, stream}    = ALLM.stream_generate(engine, request)
  {:ok, img_resp}  = ALLM.generate_image(engine,
                       %ALLM.ImageRequest{operation: :generate, prompt: "...", model: "gemini-3.1-flash-image-preview"})
  ```

- **Prerequisites.**
  - Phases 10.x (OpenAI), 11.x (Anthropic), 13.x–15.x (image layer) all complete — confirmed via `git log --oneline --grep="PHASE_15"` showing `1b8a353` at HEAD.
  - Spec amendments above merged.
  - `lib/allm/providers/support/sse.ex` (Phase 10.1) reused unchanged.
  - `lib/allm/providers/support/openai_headers.ex` is **not** reused — Gemini auth is `x-goog-api-key`, not `Authorization: Bearer`. New helper `lib/allm/providers/support/gemini_headers.ex` (NEW — 16.1).
  - `ALLM.Retry` (`lib/allm/retry.ex`) reused unchanged with the default policy plus a Gemini-specific extension that adds `RESOURCE_EXHAUSTED` (Google's quota status) to the retryable set when the HTTP status is 429.

- **Out of scope.**
  - **Imagen `:predict` (`imagen-4.0-*`).** Different request shape (`instances`/`parameters`/`predictions`), different endpoint (`:predict` not `:generateContent`), no chat-context use case. Defer to a separate `ALLM.Providers.Gemini.Imagen` adapter in a future package per amended §35.7.
  - **Files API uploads (`fileData.fileUri`).** ALLM `ImagePart` carries inline base64 bytes; the Files API would need a separate upload step and persistent URI lifecycle. Inline-only is sufficient for v0.2 vision (≤20 MB request payload).
  - **Gemini-specific tools** (`google_search`, `code_execution`, URL context). Out of `ALLM.Tool` shape. Pass-through via a future `:adapter_opts` extension is possible but explicitly not in this phase.
  - **Cached content (`cachedContent`).** Out of v0.2 prompt-caching layer.
  - **Vertex AI surface** (`aiplatform.googleapis.com`, OAuth bearer auth). Generative Language API only.
  - **Thinking-budget / `thinkingConfig`.** Reasoning controls for Gemini 2.5/3.x land in a follow-up phase mirroring PHASE_10.6 — out of scope here so the request-builder stays small.
  - **Safety settings** (`safetySettings` array). Pass-through via `:adapter_opts` is fine; first-class request-builder keys deferred.
  - **Image edit / variation as distinct operations.** Gemini-native image has no separate edit endpoint — edit is "send image + prompt via `generateContent`". Decision #6 below covers how `:edit` and `:variation` map (or don't).
  - **Streaming image generation.** Gemini streams text, not image bytes; `Images.generate/2` stays synchronous.

- **Non-obvious decisions.**
  1. **Single translator (`to_gemini_request_body/2`), not dual.** Gemini has one `generateContent` endpoint covering both text and image generation — the only difference is `generationConfig.responseModalities`. Avoids the PHASE_10 dual-translator drift (CLAUDE.md "OpenAI has TWO endpoint translators"). *Docs target: `@moduledoc ALLM.Providers.Gemini`.*
  2. **Auth header `x-goog-api-key`, not `?key=` query param.** Both are documented and equivalent. Header keeps API keys out of HTTP access logs and metrics. *Docs target: `@moduledoc ALLM.Providers.Gemini`.*
  3. **`x-goog-api-key` is also the streaming auth.** Same header on `streamGenerateContent`; the `?alt=sse` query param is required and is the **only** required query param. *Docs target: `@doc ALLM.Providers.Gemini.stream/2`.*
  4. **Tool-call args arrive as JSON objects, not strings.** `functionCall.args` is `object`, not the OpenAI Chat-Completions `arguments: string`. The adapter parses-then-re-encodes: store `arguments :: map()` on `%ALLM.ToolCall{}`, populate `raw_arguments :: String.t()` via `Jason.encode!/1` so the cross-provider invariant (`raw_arguments` is canonical-JSON of `arguments`, mirrors Anthropic adapter at `lib/allm/providers/anthropic.ex:1056-1067`) holds. *Docs target: `@moduledoc ALLM.Providers.Gemini` "Wire field map" subsection.*
  5. **Tool results emit as `user`-role turns containing `functionResponse` parts, not `tool`-role messages.** Detection mechanism per Behaviour-design-doc rule 17: scan the in-bound `ALLM.Message`s during request-building — every message whose `role: :tool` is converted to a `role: "user"` Gemini turn whose `parts` contain a single `functionResponse` part. No state flag, no session lookup. The `tool_call_id` on `%ALLM.Message{role: :tool}` is echoed as `functionResponse.id` (optional in Gemini wire but always preserved when known). *Docs target: `@doc false to_gemini_contents/1`.*
  6. **`Gemini.Images.supported_operations/0` returns `[:generate, :edit]`.** No separate edit endpoint exists — `:edit` requests are translated to `generateContent` with the source image as an `inlineData` Part adjacent to the prompt text. `:variation` is **rejected with `:unsupported_operation`** at the entry-point gate per `ImageAdapter` invariant 4; the closest Gemini analogue is "edit with prompt = 'create a variation'" but that's a caller decision, not adapter behaviour. *Docs target: `@doc ALLM.Providers.Gemini.Images.supported_operations/0`.*
  7. **`Gemini.Images.generate/2` reuses the chat translator.** Image generation is `generateContent` with `generationConfig.responseModalities: ["TEXT", "IMAGE"]`. Per spec §35.3 the adapter is a separate module (one operation surface = one module), but its body delegates to `ALLM.Providers.Gemini.to_gemini_request_body/2` with an `:image_response` flag. Eliminates a per-translator drift class. *Docs target: `@moduledoc ALLM.Providers.Gemini.Images`.*
  8. **`finish_reason` mapping is intentionally lossy at the contract layer; raw value preserved on `Response.raw_finish_reason` (top-level field, not under `metadata`).** Gemini's enum has 17 values across STOP/MAX_TOKENS/safety/image-safety/tool-error categories. ALLM `Response.finish_reason :: :stop | :length | :tool_calls | :content_filter | :error | :other` is closed at 6. Mapping (Decision #14 below) collapses safety variants to `:content_filter`, image-safety variants to `:content_filter`, tool-misuse variants to `:error` — and stores the raw enum at `Response.raw_finish_reason` (top-level field on `%ALLM.Response{}` per `lib/allm/response.ex:41`) so callers needing fidelity can distinguish. Mirrors OpenAI Responses (`lib/allm/providers/openai.ex:1010`) and Anthropic (`lib/allm/providers/anthropic.ex:1036-1043`). **Note:** `Response.raw_finish_reason` cannot round-trip through `ALLM.StreamCollector` today — the collector's `:message_completed` fold does not write the field; closure is scheduled in Phase 16.7. *Docs target: `@moduledoc ALLM.Providers.Gemini`.*
  9. **`promptFeedback.blockReason` (no candidates) maps to `{:ok, %Response{finish_reason: :content_filter, content: ""}}`, not `{:error, _}`.** When the *prompt* is blocked, Gemini returns 200 with empty `candidates` and a populated `promptFeedback.blockReason`. The CLAUDE.md mid-stream-error invariant ("Mid-stream adapter errors fold into the response, not the call-site tuple") extends here — a successful HTTP response is a successful call from the adapter's perspective; the content filter is a finish reason. The block reason is preserved at `metadata.error.reason = "blocked:#{block_reason}"` for diagnosis. *Docs target: `@doc ALLM.Providers.Gemini.generate/2`.*
  10. **Empty-`candidates` + no `promptFeedback.blockReason` is `:malformed_response`.** Defensive: a 200 with neither candidates nor a block reason is a Gemini bug; surface as `{:error, %AdapterError{reason: :malformed_response}}` rather than silently returning empty content. *Docs target: error-reason table in `@doc ALLM.Providers.Gemini.generate/2`.*
  11. **`usageMetadata.candidatesTokenCount` is the canonical completion-token field; `responseTokenCount` is read as a defensive fallback only.** The documented field on `models.generateContent` is `candidatesTokenCount` (verify against `ai.google.dev/api/generate-content` at implementation start). Live API surfaces (`ws://`, not in scope here) and preview-channel forum threads have surfaced `responseTokenCount` on some chunks. The decoder reads `candidatesTokenCount` first; if absent, reads `responseTokenCount`; if both absent, leaves `Usage.output_tokens` at `nil` (the `%ALLM.Usage{}` field — see `lib/allm/usage.ex:15`; there is no `:completion_tokens` field) and emits `Logger.warning(fn -> ... end)` once per call. No silent zero. *Docs target: `@doc false ALLM.Providers.Gemini.parse_usage/1`.*
  12. **`usageMetadata` may appear on intermediate stream chunks; collector overwrites-on-read.** Documented variability across model generations. The chunk-to-event mapper emits `{:usage, %ALLM.Usage{...}}` whenever `usageMetadata` is present; `ALLM.StreamCollector.apply_event/2` already overwrites on `:usage` (verified `lib/allm/stream_collector.ex` per existing OpenAI streaming behaviour). *Docs target: `@moduledoc` "Streaming wire shape".*
  13. **Stream terminates on connection close, not `data: [DONE]`.** Documented Gemini SSE behaviour. The `Stream.resource/3` `next_fun` treats Finch's `:done` event as the stream terminator and emits the synthetic `:message_completed` event from accumulated state (mirrors OpenAI Chat Completions at `lib/allm/providers/openai.ex:1392-1395`). *Docs target: `@moduledoc` "Streaming wire shape".*
  14. **`finish_reason` mapping table** (closed against the 17 Gemini values; verified against `ai.google.dev/api/generate-content` at research time):

      | Gemini `finishReason` | ALLM `Response.finish_reason` | Notes |
      |-----------------------|-------------------------------|-------|
      | `STOP` | `:stop` | Normal completion. |
      | `MAX_TOKENS` | `:length` | Token cap hit. |
      | `SAFETY` | `:content_filter` | Raw preserved. |
      | `RECITATION` | `:content_filter` | Raw preserved. |
      | `LANGUAGE` | `:content_filter` | Raw preserved. |
      | `BLOCKLIST` | `:content_filter` | Raw preserved. |
      | `PROHIBITED_CONTENT` | `:content_filter` | Raw preserved. |
      | `SPII` | `:content_filter` | Raw preserved. |
      | `IMAGE_SAFETY` | `:content_filter` | Raw preserved. |
      | `IMAGE_PROHIBITED_CONTENT` | `:content_filter` | Raw preserved. |
      | `IMAGE_RECITATION` | `:content_filter` | Raw preserved. |
      | `IMAGE_OTHER` | `:other` | Raw preserved. |
      | `NO_IMAGE` | `:other` | Raw preserved. |
      | `MALFORMED_FUNCTION_CALL` | `:error` | Raw preserved. |
      | `UNEXPECTED_TOOL_CALL` | `:error` | Raw preserved. |
      | `TOO_MANY_TOOL_CALLS` | `:error` | Raw preserved. |
      | `MISSING_THOUGHT_SIGNATURE` | `:error` | Raw preserved. |
      | `MALFORMED_RESPONSE` | `:error` | Raw preserved. |
      | `OTHER`, `FINISH_REASON_UNSPECIFIED`, anything else | `:other` | Raw preserved. |

      Tool-completion path: when `candidates[0].content.parts` contains at least one `functionCall` and `finishReason == STOP`, the mapping switches to `:tool_calls` (matches OpenAI Chat Completions and Anthropic — finish reason follows the *content* not the wire enum). *Docs target: `@moduledoc ALLM.Providers.Gemini`, this exact table.*

  15. **Gemini error envelope mapping** (Google `{error: {code, status, message, details}}`):

      | HTTP | Google `status` | ALLM `AdapterError.reason` | Retryable (default policy)? |
      |------|-----------------|----------------------------|-----------------------------|
      | 400 | `INVALID_ARGUMENT` (no context-window marker) | `:invalid_request` | no |
      | 400 | `INVALID_ARGUMENT` (`exceeds the maximum number of tokens` substring) | `:context_length_exceeded` | no |
      | 401 | `UNAUTHENTICATED` | `:authentication_failed` | no |
      | 403 | `PERMISSION_DENIED` | `:authentication_failed` | no |
      | 404 | `NOT_FOUND` | `:invalid_request` | no |
      | 429 | `RESOURCE_EXHAUSTED` | `:rate_limited` | yes (Gemini-specific addition; see Decision below) |
      | 500 | `INTERNAL` | `:provider_unavailable` | yes |
      | 503 | `UNAVAILABLE` | `:provider_unavailable` | yes |
      | 504 | `DEADLINE_EXCEEDED` | `:provider_unavailable` | yes |

      Context-window detection: substring `"exceeds the maximum number of tokens"` in `error.message` (Google does not expose a structured code for this; checked against current API docs). Mirrors the `:context_length_exceeded` substring detection in `lib/allm/providers/anthropic.ex:464-469`. *Docs target: `@doc ALLM.Providers.Gemini.generate/2` error-reason table.*

  16. **No Gemini-specific retry-policy wrapper.** The default policy at `lib/allm/retry.ex` already retries HTTP 429 (`:rate_limited`), 500/502/503/504 (`:provider_unavailable`), and `:network_error`/`:timeout`. Gemini's only divergence is that 429 carries Google `status: "RESOURCE_EXHAUSTED"` in the body, which has no behavioural impact — the classifier reads HTTP status, not the body status code, for retry decisions. Anthropic at `lib/allm/providers/anthropic.ex:329-339` only needed `with_anthropic_retry_on/1` because Anthropic returns 529 (Overloaded), an HTTP code the default policy didn't cover. Gemini has no equivalent extension. The retry-policy line in `Gemini.generate/2` reads simply `retry = Keyword.get(opts, :retry, :default)` with no wrapping. **`Retry-After` parsing is a SEPARATE concern from this Decision.** Decision #16 governs *which statuses retry*; `Retry-After` parsing governs *how long to back off* and is independent — `classify_http_error/3` MUST read `Retry-After` from response headers and populate `AdapterError.retry_after_ms` + the retry-loop delay, mirroring `lib/allm/providers/openai.ex:690-737` and `lib/allm/providers/anthropic.ex:515-547`. *Docs target: `@moduledoc ALLM.Providers.Gemini` "Retry policy" subsection.*

  17. **Per-call cost estimate (clean review-pass run).** Gemini 3 Flash Preview: pricing TBD at GA — 2.5 Flash baseline is $0.10/1M input, $0.40/1M output; 3.x preview pricing is verified against `ai.google.dev/pricing` at implementation time and the figures below adjusted. Using 2.5 Flash as the lower-bound proxy: `examples/01–09` average ~600 in / ~400 out tokens per script ≈ 9 × (0.06 + 0.16) µ-USD ≈ $0.002. `examples/10` image-generate: `gemini-3.1-flash-image-preview` per-image cost ≈ $0.04 (preview-pricing baseline; verify) × 1 image. **Per-clean-run `examples/run_all.exs` total: ~$0.05.** Image `:edit` is exercised only in `gemini_live_test.exs` (one additional ~$0.04 call); `mix test --include live` per-clean-run total: ~$0.09. First-implementation cost estimate: 3× clean = ~$0.15–$0.30 across both gates (debugging). Implementer reports actuals against this in retro per CLAUDE.md per-provider example invariant; if Gemini-3 preview pricing diverges materially from 2.5 baseline, the retro updates this Decision.

  20. **Per-provider default temperature in `examples/_helpers.exs`.** Google explicitly recommends `temperature: 1.0` for Gemini 3 (cited from the Gemini-3 CrewAI integration guide and other quickstarts on `ai.google.dev`). ALLM's existing `examples/_helpers.exs` baseline is `temperature: 0` (chosen for OpenAI/Anthropic determinism in review runs). To avoid Gemini-3 misbehaviour at low temperature without forcing `1.0` on every provider, extend `@providers` rows with an optional `:default_temperature` field in Phase 16.6; `engine/1` reads the row's value, falling back to `0` when absent. Gemini's row sets `default_temperature: 1.0`; OpenAI and Anthropic rows omit it (preserving the `0` baseline). The `ALLM_TEMPERATURE` env var continues to override (if it exists today; if not, that's a follow-up). *Docs target: `@moduledoc ExamplesHelpers` + per-provider row comment.* (Decisions #18 and #19 live in later sections; #20 is here to keep the Overview's "Non-obvious decisions" thread complete.)

## Behaviour & Type Contracts

This phase introduces two new modules implementing existing behaviours; **no behaviour, struct, or public-function contract changes**. The Gemini adapter must satisfy:

- `@behaviour ALLM.Adapter` — `generate/2`, `prepare_request/2`, `translate_options/2` (all 3 implemented; Decision #18 below).
- `@behaviour ALLM.StreamAdapter` — `stream/2`.
- `@behaviour ALLM.ImageAdapter` (Gemini.Images only) — `generate/2`, `supported_operations/0`, `prepare_request/2`.

### `ALLM.Providers.Gemini` — public API

```elixir
defmodule ALLM.Providers.Gemini do
  @behaviour ALLM.Adapter
  @behaviour ALLM.StreamAdapter

  @spec generate(ALLM.Request.t(), keyword()) ::
          {:ok, ALLM.Response.t()} | {:error, ALLM.Error.AdapterError.t()}
  @spec stream(ALLM.Request.t(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, ALLM.Error.AdapterError.t()}
  @spec prepare_request(ALLM.Request.t(), keyword()) ::
          {:ok, Req.Request.t()} | {:error, ALLM.Error.AdapterError.t()}
  @spec translate_options(keyword(), ALLM.Request.t()) :: keyword()
end
```

### `ALLM.Providers.Gemini.Images` — public API

```elixir
defmodule ALLM.Providers.Gemini.Images do
  @behaviour ALLM.ImageAdapter

  @spec generate(ALLM.ImageRequest.t(), keyword()) ::
          {:ok, ALLM.ImageResponse.t()} | {:error, ALLM.Error.ImageAdapterError.t()}
  @spec prepare_request(ALLM.ImageRequest.t(), keyword()) ::
          {:ok, Req.Request.t()} | {:error, ALLM.Error.ImageAdapterError.t()}
  @spec supported_operations() :: [:generate | :edit]
end
```

### Wire-field map (per CLAUDE.md provider-design rule 15)

| Concern | Gemini wire field | Notes / divergence vs OpenAI/Anthropic |
|---------|------------------|----------------------------------------|
| Endpoint host | `https://generativelanguage.googleapis.com/v1beta` | hard-coded constant; override via `adapter_opts[:endpoint]`. |
| Endpoint method (chat non-streaming) | `POST /models/{model}:generateContent` | `{model}` is the bare model id, no `models/` prefix in URL builder. |
| Endpoint method (chat streaming) | `POST /models/{model}:streamGenerateContent?alt=sse` | `?alt=sse` is required — without it, server returns JSON array, not SSE. |
| Endpoint method (image) | `POST /models/{model}:generateContent` | identical to chat; differs only by `generationConfig.responseModalities`. |
| Auth header | `x-goog-api-key: $key` | Distinct from OpenAI `Authorization: Bearer $key` and Anthropic `x-api-key: $key` + `anthropic-version: 2023-06-01`. |
| Roles | `user`, `model` | OpenAI `assistant` → Gemini `model`; OpenAI `system` → top-level `systemInstruction`; OpenAI `tool` → `user`-role turn with `functionResponse` part. |
| Content shape | `parts: [Part]` always | OpenAI Chat Completions can send `content: "string"` or `content: [{type: "text", ...}, ...]`; Gemini is always parts-array. |
| Text part | `{"text": "..."}` | |
| Image-in part | `{"inlineData": {"mimeType": "image/png", "data": "<base64>"}}` | OpenAI `image_url`, Anthropic `{type: "image", source: {type: "base64", ...}}` — three distinct shapes; ALLM `%ImagePart{}` normalizes. |
| System message | top-level `systemInstruction: {parts: [{text: "..."}]}` | Single per-request; multiple system messages are concatenated with `\n\n` (matches Anthropic at `lib/allm/providers/anthropic.ex:616-623`). |
| Tool declarations | `tools: [{functionDeclarations: [{name, description, parameters}]}]` | Note: array of `{functionDeclarations: ...}` objects, not array of declarations. |
| Tool-call from model | `parts: [{"functionCall": {"name": "...", "args": {...}, "id": "..."}}]` | `args` is a JSON object, not a string (vs OpenAI Chat Completions `arguments: "..."`). |
| Tool-call delta-field name (streaming) | not delta-streamed; `functionCall` part arrives in a single SSE event | Vs OpenAI `function.arguments` and Anthropic `input_json_delta` (`partial_json`). Adapter still emits `:tool_call_started` + zero `:tool_call_delta` + `:tool_call_completed` to match the existing `Event` protocol. |
| Tool-result envelope | `{"role": "user", "parts": [{"functionResponse": {"name": "...", "response": {...}, "id": "..."}}]}` | `response` is a JSON object; `id` is optional but echoed when in-bound `Message.tool_call_id` is set. |
| Tool choice | `toolConfig.functionCallingConfig.mode = "AUTO" \| "ANY" \| "NONE"` | ALLM `:auto` → `"AUTO"`, ALLM `:required` → `"ANY"`, ALLM `:none` → `"NONE"`, ALLM `{:tool, name}` → `"ANY"` with `allowedFunctionNames: [name]`. |
| Generation params | `generationConfig.{maxOutputTokens, temperature, topP, topK, stopSequences, responseMimeType, responseSchema}` | camelCase; nested under `generationConfig`. ALLM `:max_tokens` → `:maxOutputTokens`. |
| Response format (json) | `generationConfig.responseMimeType: "application/json"` | |
| Response format (json_schema) | `generationConfig.responseMimeType: "application/json"` + `generationConfig.responseSchema: {...}` | OpenAPI subset, not strict JSON Schema — adapter passes the schema through verbatim and lets Gemini reject unsupported keywords. |
| Image-out toggle | `generationConfig.responseModalities: ["TEXT", "IMAGE"]` (or `["IMAGE"]` for image-only) | Gemini-native image only. |
| Image-out aspect ratio | `generationConfig.imageConfig.aspectRatio` | Optional; passed through from `ImageRequest.size` mapping (Decision #19). |
| `finish_reason` location | `candidates[0].finishReason` (UPPER_SNAKE) | Mapping per Decision #14 above. |
| Stop-reason for content-filter (prompt-blocked) | `promptFeedback.blockReason` (top-level, no candidates) | Decision #9 maps to `:content_filter`. |
| Usage location | `usageMetadata` (top-level on response and on stream chunks) | |
| Usage prompt tokens | `usageMetadata.promptTokenCount` | |
| Usage completion tokens | `usageMetadata.candidatesTokenCount` OR `usageMetadata.responseTokenCount` (model-dependent) | Decision #11. |
| Usage total tokens | `usageMetadata.totalTokenCount` | |
| Error envelope | `{"error": {"code": int, "status": "STATUS", "message": "...", "details": [...]}}` | Mapping per Decision #15 table. |
| Streaming SSE event format | `data: <complete GenerateContentResponse JSON>\n\n` | Each event carries deltas of `parts[].text` plus possible final `usageMetadata` and `finishReason`. |
| Streaming terminator | TCP connection close (no `data: [DONE]`) | Decision #13. |

### Decision-named atom vocabulary (additive)

This phase adds **zero** new atoms to closed enums (`AdapterError.reason`, `ImageAdapterError.reason`, `Response.finish_reason`, `Event` variants). All Gemini-specific signals are mapped to existing atoms per Decisions #14, #15. CLAUDE.md "every newly-added atom must have a current-phase use site" trivially satisfied.

### Cross-function invariants (per CLAUDE.md design checklist 6)

- **`generate/2` ≡ `stream/2 |> StreamCollector.collect/1`** (stream-equivalence — §3): for any scripted `Fake`-like test fixture, the non-streaming response from `generate/2` and the reduced response from `stream/2` MUST agree on `content`, `tool_calls` (once Phase 16.3's non-streaming `functionCall` decoder lands), `finish_reason`, and `usage`. The single translator (Decision #1) makes this trivially true at request build time; the response-decoder/chunk-mapper symmetry is the load-bearing test. **Per-phase relaxations:** (a) `Response.raw_finish_reason` is excluded from the projection until Phase 16.7 closes the StreamCollector round-trip gap (top-level field, never written by the `:message_completed` fold today — see `lib/allm/stream_collector.ex:152, 274-294`); (b) `tool_calls` and `finish_reason: :tool_calls` are excluded for `functionCall`-bearing fixtures until Phase 16.3 lands the non-streaming decoder. The streaming side already extracts both correctly; the relaxation is a one-arm gap, not a two-arm divergence.
- **`Gemini.Images.generate/2` reuses `Gemini.to_gemini_request_body/2`** (Decision #7) — the request bodies for `Images.generate(%{operation: :generate, prompt: "...", model: "gemini-3.1-flash-image-preview"})` and `Gemini.generate(%Request{messages: [user "..."], model: "gemini-3.1-flash-image-preview", response_format: %{...}})` MUST be byte-equal except for `generationConfig.responseModalities` and the user-supplied prompt vs message text. Tested via fixture comparison in `test/allm/providers/gemini/images_translator_parity_test.exs` (Phase 16.5).
- **Response decoder symmetry — shared helper extracted to avoid the dual-translator drift class.** `Gemini.generate/2`'s response decoder (Phase 16.1) and `Gemini.Images.generate/2`'s response decoder (Phase 16.5) MUST share a `Gemini.Decode.candidate_parts/1` helper that walks `candidates[0].content.parts` once and returns `{text, tool_calls, image_parts, raw_finish_reason}`. The two callers consume different subsets of the tuple (chat ignores `image_parts`; Images filters for inline-data parts) but the parsing is single-source. Mirrors PHASE_14 Decision #14's "cite both translators" precedent applied to the response half. Test: a response containing both text AND inlineData parts decodes consistently via either entry point — `Gemini.generate/2` returns a `%Response{}` whose `content` matches `Gemini.Images.generate/2`'s response's `metadata.text_content`.
- **`prepare_request/2` returns the same `Req.Request{}` shape `generate/2` would fire** (`ALLM.Adapter` invariant 4) — verified by a test that asserts `generate/2` ≡ `prepare_request/2 |> Req.request!/1 |> decode/1`.
- **`translate_options/2` is identity for Gemini**, Decision #18: `translate_options(opts, _request) :: opts`. Gemini has no opt that needs renaming, routing, or splitting before reaching `to_gemini_request_body/2`. ALLM's `:max_tokens`/`:temperature`/`:top_p`/`:top_k`/`:stop` all flow through unchanged into `to_generation_config/1`, which is where the camelCase rename and `generationConfig` nesting happens. OpenAI's translator does endpoint-aware renaming at the opts layer (`lib/allm/providers/openai.ex:295-307`) because OpenAI's two endpoints diverge on the *opts* shape (`max_tokens` vs `max_completion_tokens` vs `max_output_tokens`); Gemini has one endpoint and no analogous divergence. Anthropic's identity translator at `lib/allm/providers/anthropic.ex:198-199` is the precedent. If a future Gemini-only opt (`:thinking_budget`, `:safety_settings`) needs Layer-C-side processing, this decision is revisited. *Docs target: `@doc ALLM.Providers.Gemini.translate_options/2`.*

## Module Tree

```
lib/allm/
└── providers/
    ├── gemini.ex                                 (NEW — 16.1, 16.2, 16.3, 16.4)
    │                                                 (MODIFY — 16.5; refactor decode_with_candidates to delegate to Gemini.Decode.candidate_parts/1 shared helper)
    ├── gemini/
    │   ├── decode.ex                             (NEW — 16.5; shared candidate_parts/1 helper consumed by both gemini.ex chat decoder and gemini/images.ex image decoder per Decision: response-decoder symmetry)
    │   └── images.ex                             (NEW — 16.5)
    └── support/
        └── gemini_headers.ex                     (NEW — 16.1; build x-goog-api-key + content-type)

examples/
├── _helpers.exs                                  (MODIFY — 16.6; add "gemini" provider row)
├── RUN_OUTPUT_GEMINI.md                          (NEW — 16.6; live-validation artifact)
└── run_all.exs                                   (MODIFY — 16.6 ONLY IF the script enumerates providers; else unchanged)

test/allm/providers/
├── gemini_test.exs                               (NEW — 16.1; non-streaming chat happy + error paths)
│                                                 (MODIFY — 16.3; close 16.1 defensive `:tool` placeholder with canonical `functionResponse` translation test)
├── gemini_wire_test.exs                          (NEW — 16.1; recorded-response decode tests)
├── gemini_stream_test.exs                        (NEW — 16.2; streaming happy + cancellation + timeout)
│                                                 (MODIFY — 16.3; close 16.2 `@functioncall_fixtures` sub-projection relaxation per stream-equivalence relaxation (b))
├── gemini_stream_wire_test.exs                   (NEW — 16.2; recorded-SSE decode tests)
├── gemini_tools_test.exs                         (NEW — 16.3; function-call request/response round-trip)
├── gemini_vision_test.exs                        (NEW — 16.4; ImagePart → inlineData translation)
├── gemini_live_test.exs                          (NEW — 16.6; tagged @tag :live, excluded by default)
└── gemini/
    ├── images_test.exs                           (NEW — 16.5; image-out happy + gates)
    ├── images_wire_test.exs                      (NEW — 16.5; recorded-response decode)
    └── images_translator_parity_test.exs         (NEW — 16.5; byte-equal request-builder check)

test/support/
└── gemini_fixtures.ex                            (NEW — 16.1; recorded-response JSON fixtures + SSE chunks)

conformance/test/
└── gemini_conformance_test.exs                   (NEW — 16.6; runs Adapter + StreamAdapter + Image suites against Gemini stubs)

CHANGELOG.md                                       (MODIFY — 16.6; one line per public-API change)
mix.exs                                            (MODIFY — 16.5; add Gemini modules to ExDoc grouping under "Providers — Gemini")
test/test_helper.exs                               (MODIFY — 16.6; add :live_gemini to ExUnit.start exclude list — pre-req for the @moduletag :live_gemini test module to be excluded by default)
test/allm/examples_helpers_test.exs                (NEW — 16.6; Decision #20 default-temperature merge invariant — exercises the four `engine/1` cases (default-Gemini, override-via-params, non-temperature-params-preserves-default, no-default-row))
steering/allm_engine_session_streaming_spec_v0_2.md (MODIFY — pre-16.1 spec PR; §32.1 + §35.7 amendments)
```

**Module Tree completeness invariant** (CLAUDE.md): the implementer should expect `git diff --stat <pre-16.1>..<post-16.6> | wc -l` to equal **15 entries ± 1** (CHANGELOG.md is the typical off-by-one). No prior-phase `lib/` file should appear modified — if one does, that's a cross-phase fix and per CLAUDE.md "Cross-phase bug discipline" must be documented in retro and reverted from the phase commit.

## Phases

### Phase 16.1 — Skeleton + non-streaming chat (text-only) (Layer B)

**Goal:** A working `ALLM.Providers.Gemini.generate/2` that handles text-only chat with system messages, multi-turn `:user`/`:assistant` messages, and the full error-reason table. No tools, no vision, no streaming.

**Spec sections:** §6.4, §7.1, §20.

#### 16.1.1 Test Plan (write first)

`test/allm/providers/gemini_test.exs` (NEW):

- `generate/2 sends a single user message and decodes a STOP response` (recorded fixture; assert `Response.content`, `finish_reason: :stop`, `usage`, `Response.raw_finish_reason: "STOP"` (top-level, not under `metadata`), `metadata.model_version`).
- `generate/2 sends multi-turn user/assistant history with role mapping :assistant → "model"`.
- `generate/2 hoists a single system message into top-level systemInstruction and removes it from contents`.
- `generate/2 concatenates multiple system messages with "\n\n" into systemInstruction.parts[0].text`.
- `generate/2 maps :max_tokens → generationConfig.maxOutputTokens` and `:temperature/:top_p → generationConfig.{temperature,topP}`.
- `generate/2 with response_format: %{type: :json_object} sets generationConfig.responseMimeType = "application/json"`.
- `generate/2 with response_format: %{type: :json_schema, schema: ...} sets responseMimeType + responseSchema`.
- `generate/2 maps finishReason MAX_TOKENS → :length` and `SAFETY → :content_filter` (one row per Decision #14 mapping table).
- `generate/2 with promptFeedback.blockReason and empty candidates returns {:ok, %Response{finish_reason: :content_filter, content: ""}}` (Decision #9).
- `generate/2 with empty candidates AND no promptFeedback.blockReason returns {:error, %AdapterError{reason: :malformed_response}}` (Decision #10).
- `generate/2 with usageMetadata using "responseTokenCount" decodes equivalently to "candidatesTokenCount"` (Decision #11; one fixture each, assert `Usage` field-equal).
- Error mapping: one test per row of Decision #15 table — 401/403/404/429/500/503/504 + the 400 context-window substring case.
- `generate/2 honors opts[:request_timeout]` — fires `Req` with `:receive_timeout` set; verify via `Req.Test` stub that delays past timeout returns `:timeout`.
- `generate/2 honors opts[:adapter_opts][:endpoint]` override (test against a fake URL).
- `generate/2 returns {:error, %EngineError{reason: :missing_key}} when no key resolvable`.

`test/allm/providers/gemini_wire_test.exs` (NEW):

- One `assert recorded_request_body == expected` test for each request shape (text-only, system+user, multi-turn, generationConfig variants). These pin the wire shape against drift.

#### 16.1.2 Implementation Checklist

- [ ] Spec PR amending §32.1 + §35.7 merged.
- [ ] `lib/allm/providers/support/gemini_headers.ex` — `headers/1` returning `[{"x-goog-api-key", key}, {"content-type", "application/json"}]`.
- [ ] `lib/allm/providers/gemini.ex` skeleton: `@behaviour ALLM.Adapter` declared. `@behaviour ALLM.StreamAdapter` is deferred to Phase 16.2 alongside the `stream/2` callback — declaring it in 16.1 without the impl raises a compile warning. `@stream_adapter_opt` keys defined.
- [ ] `Gemini.generate/2` — calls `ALLM.Keys.fetch!(:gemini, opts)`, builds body via `to_gemini_request_body/2`, fires `Req.post/1` inside `ALLM.Retry.run/3` with the unwrapped default retry policy (Decision #16).
- [ ] `Gemini.prepare_request/2` — same pre-flight as `generate/2` minus the `Req.request/1` call; returns `{:ok, %Req.Request{}}`.
- [ ] `Gemini.translate_options/2` — identity (Decision #18).
- [ ] `to_gemini_request_body/2` (private) — builds the JSON body. Pure function; no I/O.
- [ ] `to_gemini_contents/1` (private) — partitions messages into `(systemInstruction, contents)` with role mapping.
- [ ] `to_generation_config/1` (private) — maps ALLM params → Gemini `generationConfig` keys.
- [ ] `decode_response/2` (private) — parses 200 body into `%Response{}`; handles empty-candidates branches.
- [ ] `parse_finish_reason/1` (private) — closed `case` over the 19 Decision #14 values.
- [ ] `parse_usage/1` (private) — handles both `candidatesTokenCount` and `responseTokenCount`.
- [ ] `classify_error/3` (private) — maps `(status, body, headers)` → `%AdapterError{}` per Decision #15.
- [ ] `default retry policy` (private) — wraps default policy adding 429+RESOURCE_EXHAUSTED.
- [ ] `ALLM.Keys.env_var_for(:gemini)` returns `"GEMINI_API_KEY"`. Verified at design time: `@env_var_table` at `lib/allm/keys.ex:46-53` does NOT include `:gemini`; the unknown-provider fallback at `lib/allm/keys.ex:189-194` returns `String.upcase("gemini") <> "_API_KEY" = "GEMINI_API_KEY"`. **No Keys change required.** (Note: a `:google` row exists in `@env_var_table` returning `"GOOGLE_API_KEY"` — DO NOT use the `:google` provider atom; the Generative Language API uses Google AI Studio's `GEMINI_API_KEY`, distinct from generic Google Cloud keys.)
- [ ] `@doc` on every public function with at least one runnable doctest using a Req.Test stub.
- [ ] `@spec` matches Behaviour & Type Contracts verbatim.

#### 16.1.3 Verification

```bash
mix format
mix test test/allm/providers/gemini_test.exs test/allm/providers/gemini_wire_test.exs
mix test                                       # full suite still green
mix credo --strict lib/allm/providers/gemini.ex lib/allm/providers/support/gemini_headers.ex
mix dialyzer
```

---

### Phase 16.2 — Streaming chat (Layer B)

**Goal:** `ALLM.Providers.Gemini.stream/2` returns a lazy `Enumerable.t()` of `ALLM.Event` values from `streamGenerateContent?alt=sse`. Cleanup-safe, timeout-honoring, mid-stream-error-folding.

**Spec sections:** §7.2, §8, §19.

#### 16.2.1 Test Plan (write first)

`test/allm/providers/gemini_stream_test.exs` (NEW):

- `stream/2 emits :message_started → :text_delta+ → :message_completed for a multi-chunk text response` (script via `FinchStub` from `test/support/finch_stub.ex`).
- `stream/2 emits :usage event when usageMetadata appears on the final chunk`.
- `stream/2 emits :usage event for usageMetadata on intermediate chunks (stream collector overwrites)`.
- `stream/2 emits :tool_call_started + :tool_call_completed (with zero deltas) when a functionCall part arrives in a single SSE event`.
- `stream/2 with promptFeedback.blockReason on the first event emits {:error, %AdapterError{reason: :content_filter}} terminator`.
- `stream/2 maps mid-stream HTTP 429 to {:error, %AdapterError{reason: :rate_limited}} terminator`.
- `stream/2 cancels the underlying Finch ref when consumer halts via Stream.take/2 within 500ms` (pattern from `lib/allm/providers/openai.ex:1361-1368`).
- `stream/2 honors opts[:stream_timeout] and emits {:error, %AdapterError{reason: :timeout}} terminator`.
- `stream/2 uses opts[:finch_module] / opts[:finch_name] when supplied` (test injection).
- `stream/2 emits a terminal {:error, %AdapterError{reason: :authentication_failed}} event when the first chunk is a 401` (call-site stays `{:ok, stream}`; Finch async cannot fail synchronously after `Finch.async_request/3` has been issued, so the 401 status frame folds through the receive loop into a terminal `:error` event per the CLAUDE.md mid-stream-error-fold invariant — same pattern as OpenAI/Anthropic).
- `stream/2 emits a terminal {:error, %AdapterError{reason: :context_length_exceeded}} event when the streaming endpoint replies 400 with the "exceeds the maximum number of tokens" substring before any SSE event` (call-site stays `{:ok, stream}`).
- `stream/2 with a mid-stream 5xx folds to a terminating {:error, %AdapterError{reason: :provider_unavailable}} event, NOT a synchronous {:error, _}` (CLAUDE.md mid-stream-error-fold invariant — synchronous-pre-flight errors are call-site `{:error, _}`; mid-stream errors fold via the `:error` event into `Response{finish_reason: :error}`).
- Cross-cutting: `stream-equivalence property` — for ≥10 scripted multi-chunk text-only fixtures, `generate/2(req) == stream/2(req) |> StreamCollector.collect/1` on `{content, finish_reason, usage}`. The two `functionCall`-bearing fixtures use a sub-projection (`{content, usage}` only) until Phase 16.3 lands the non-streaming `functionCall` decoder, at which point `tool_calls` and `finish_reason` rejoin the projection. `Response.raw_finish_reason` rejoins after Phase 16.7 closes the StreamCollector round-trip gap. Per-phase relaxations are explicit; "no relaxations" applies to each per-phase projection, not the union.

`test/allm/providers/gemini_stream_wire_test.exs` (NEW):

- One `assert request_body == expected` test confirming `stream/2`'s pre-fired body matches `generate/2`'s body (modulo nothing — Gemini does not require a `stream: true` field; the endpoint URL alone selects streaming).

#### 16.2.2 Implementation Checklist

- [ ] Reuse `lib/allm/providers/support/sse.ex` line-buffered decoder unchanged.
- [ ] `Gemini.stream/2` — pre-flight identical to `generate/2`; build body via `to_gemini_request_body/2` (no body diff between modes); open via `Stream.resource/3` calling `Finch.async_request/3`.
- [ ] Private SSE chunk-to-event mapper — **one `defp` clause per event class** (per CLAUDE.md "SSE chunk mappers" rule):
  - `defp handle_chunk(event_data, state)` clauses dispatching on `event_data.candidates`, `event_data.usageMetadata`, `event_data.promptFeedback`, etc.
  - No mega-`case`. Credo's `Refactor.CyclomaticComplexity` (threshold 9) enforces this.
- [ ] State machine accumulates: text deltas, in-progress tool-call IDs (in case future Gemini models split function-call parts across events), final `usageMetadata`, final `finishReason`.
- [ ] Synthetic `:message_completed` emitted on connection close, with accumulated `content`, `tool_calls`, `finish_reason`, `usage`, `metadata`.
- [ ] `Stream.resource/3` `after_fun` cancels Finch ref when `state.done == false`.
- [ ] Mid-stream `{:error, _}` events fold to `{:ok, %Response{finish_reason: :error, metadata: %{error: struct}}}` per CLAUDE.md mid-stream-error invariant.
- [ ] `Logger.debug/1` calls in the chunk mapper use the deferred `fn -> ... end` form (CLAUDE.md hot-path debug rule).

#### 16.2.3 Verification

```bash
mix test test/allm/providers/gemini_stream_test.exs test/allm/providers/gemini_stream_wire_test.exs
mix test                                       # stream-equivalence property in the chat-equivalence suite still green
mix credo --strict lib/allm/providers/gemini.ex
mix dialyzer
```

---

### Phase 16.3 — Tool calling round-trip (both paths) (Layer B)

**Goal:** `Gemini.generate/2` and `Gemini.stream/2` build `tools: [{functionDeclarations: [...]}]` from `Engine.tools` / `request.tools`, decode `functionCall` parts into `%ALLM.ToolCall{}`, and accept multi-turn requests where prior `:tool` messages translate to `user`-role turns containing `functionResponse` parts.

**Spec sections:** §15, §7.1, §7.2.

#### 16.3.1 Test Plan (write first)

`test/allm/providers/gemini_tools_test.exs` (NEW):

- **Request build:**
  - `tools list with one declaration produces tools: [{functionDeclarations: [{name, description, parameters}]}]`.
  - `tool_choice: :auto → toolConfig.functionCallingConfig.mode = "AUTO"`.
  - `tool_choice: :required → "ANY"`.
  - `tool_choice: :none → "NONE"`.
  - `tool_choice: {:tool, "set_color"} → "ANY" + allowedFunctionNames: ["set_color"]`.
- **Response decode (non-streaming):**
  - `response with one functionCall part decodes to %Response{content: "", tool_calls: [%ToolCall{id: ..., name: "...", arguments: %{...}, raw_arguments: "<json>"}], finish_reason: :tool_calls}`.
  - `response with two parallel functionCall parts decodes to two ToolCalls in order`.
  - `response with mixed text + functionCall parts decodes to %Response{content: "text", tool_calls: [...], finish_reason: :tool_calls}`.
  - `arguments :: map() round-trips equivalently to raw_arguments :: String.t()` (assert `arguments == Jason.decode!(raw_arguments)`).
  - `functionCall with id present preserves id on ToolCall.id; missing id generates a synthesized id` (mirror Anthropic's id-or-generate behaviour at `lib/allm/providers/anthropic.ex:1056-1067`).
- **Tool-result round-trip:**
  - `request with prior :tool message translates to {role: "user", parts: [{functionResponse: {name, response, id}}]}`.
  - `request with prior :tool message whose .content is a string is wrapped as response: %{"output" => content}`. Per Gemini wire docs, `functionResponse.response` is a free-form JSON object — there is no provider-prescribed wrapper key; ALLM standardizes on `"output"` so callers can derive the convention without reading provider docs.
  - `request with prior :tool message whose .content is a map passes the map through verbatim as functionResponse.response`.
  - `multi-turn: user → model functionCall → user functionResponse → model text` produces a final assistant turn with text only.
- **Streaming parity:**
  - `stream/2 emits :tool_call_started + :tool_call_completed (no :tool_call_delta) for a functionCall part` (matches non-streaming `tool_calls` accumulation).
  - `stream-equivalence holds for tool-call responses` (extends Phase 16.2 property suite).
- **Finish-reason override:**
  - `STOP + functionCall parts present → finish_reason: :tool_calls` (Decision #14 override path).
  - `MALFORMED_FUNCTION_CALL → finish_reason: :error, raw preserved`.

#### 16.3.2 Implementation Checklist

- [ ] Extend `to_gemini_request_body/2` with `tools` and `toolConfig` builder functions.
- [ ] Extend `to_gemini_contents/1` to translate `:tool`-role messages.
- [ ] Extend response decoder to walk `parts[]` and partition into `text`, `functionCall`, etc.
- [ ] Extend stream chunk mapper to emit `:tool_call_started` + `:tool_call_completed` on `functionCall` part arrival.
- [ ] Override `finish_reason` to `:tool_calls` when content carries `functionCall` parts (matches Anthropic precedent).

#### 16.3.3 Verification

```bash
mix test test/allm/providers/gemini_tools_test.exs
mix test                                       # full suite green; stream-equivalence still passes
mix credo --strict lib/allm/providers/gemini.ex
mix dialyzer
```

---

### Phase 16.4 — Multimodal input (`ImagePart` → `inlineData`) (Layer B)

**Goal:** `Gemini.generate/2` and `Gemini.stream/2` accept `%ALLM.Message{content: [%ALLM.TextPart{}, %ALLM.ImagePart{}, ...]}` and translate each `ImagePart` into a Gemini `inlineData` Part. No new API surface; this is pure request-builder extension.

**Spec sections:** §35.6, §7.1, §7.2.

#### 16.4.1 Test Plan (write first)

`test/allm/providers/gemini_vision_test.exs` (NEW):

- `message with [TextPart, ImagePart] translates to {role: "user", parts: [{text: ...}, {inlineData: {mimeType: ..., data: ...}}]}`.
- `ImagePart with mime_type "image/jpeg" sets inlineData.mimeType = "image/jpeg"`.
- `ImagePart with multiple parts in one message preserves order`.
- `request with vision message and tools combined builds a request with both tools[] and contents[] populated`.
- `stream/2 with vision input streams text deltas as in Phase 16.2`.
- `:fileData/uri ImagePart variant returns {:error, %AdapterError{reason: :unsupported_feature}}` (per Out-of-scope decision; Files API not bundled).
- `system-message ImagePart returns %ValidationError{reason: :invalid_message}` (per Anthropic 17.2 / OpenAI 17.1 precedent — system messages are text-only in v0.3 across all providers; spec §35.6 Out-of-scope #2). Inherited cross-provider invariant; enumerated explicitly per CLAUDE.md "Decision text drift" rule.

#### 16.4.2 Implementation Checklist

- [ ] Extend `to_gemini_contents/1` to walk `Message.content` when it's a list of parts (per §35.6 widening) and emit one Gemini `Part` per ALLM part.
- [ ] Helper name: `part_to_block/1` (NOT `to_image_part/1`). Per CLAUDE.md "byte-identical helper names modulo arity" cross-provider rule, the Gemini helper aligns byte-for-byte with `Anthropic.part_to_block/1` and `OpenAI.part_to_block/2`. Earlier prose used `to_image_part/1`; that name was rejected during 16.4 implementation in favor of cross-provider symmetry. Forward references in §16.5 (`:edit` parity) also use `part_to_block/1`.
- [ ] `part_to_block(%ImagePart{image: %Image{source: {:base64, data}, mime_type: mt}})` → `%{"inlineData" => %{"mimeType" => mt, "data" => data}}`.
- [ ] `part_to_block(%ImagePart{image: %Image{source: {:binary, bytes}, mime_type: mt}})` → `%{"inlineData" => %{"mimeType" => mt, "data" => Base.encode64(bytes)}}`.
- [ ] `part_to_block(%ImagePart{image: %Image{source: {:file, path}, mime_type: mt}})` (with `is_binary(mt)` guard) → reads bytes via `File.read!/1`, base64-encodes, mimics the `{:binary, _}` clause. The `mt == nil` branch is rejected upstream by `reject_unsupported_image_sources/1` so callers know to set `from_file/2` with explicit `mime_type:` (see closed-set ladder bullet below).
- [ ] `{:url, _}` ImagePart variant rejected upstream by `reject_unsupported_image_sources/1` with `%AdapterError{reason: :unsupported_feature}` and message `"Gemini adapter does not fetch URL-source images; pre-fetch and pass as %Image{source: {:binary, _}, mime_type: _}"`. Files API upload is out of scope (per Out-of-scope).
- [ ] **Closed-set ladder.** All four `Image.source` variants accounted for via a two-step ladder, NOT via a single exhaustive `part_to_block/1` dispatch: pre-flight `reject_unsupported_image_sources/1` rejects `{:url, _}` and `{:file, _}` with `mime_type: nil`; happy-path `part_to_block/1` matches `{:base64, _}`, `{:binary, _}`, and `{:file, _}` with non-nil mime. The dispatch translator is intentionally infallible; the closed-set is exhaustive across the ladder, not within a single function. Per CLAUDE.md closed-set extension rule, the dispatch translator's docstring cites the rejecter's file:line.
- [ ] **System-message ImagePart rejection.** Pre-flight `reject_image_in_system_messages/1` (cross-provider helper-name) called as the first step of both `generate/2` and `stream/2` before `reject_unsupported_image_sources/1`. Rejects `system`-role messages whose content list contains any `%ImagePart{}` with `%ValidationError{reason: :invalid_message}`. Inherited from Anthropic 17.2 / OpenAI 17.1 — system messages are text-only in v0.3 across all providers (spec §35.6 Out-of-scope #2). Gemini's `systemInstruction` field is text-only on the wire, so an ImagePart in `:system` would otherwise have to be silently dropped or hard-rejected; the cross-provider precedent picks hard-reject.
- [ ] **`ImageMime.validate_request/2` is intentionally NOT extended to `:gemini` in 16.4.** Gemini's `inlineData.mimeType` allow-list is broader and per-model-conditional (PDF / audio / video accepted by `gemini-2.5-pro` but not by `gemini-2.5-flash`); the `:openai | :anthropic` allow-list `~w(image/png image/jpeg image/webp image/gif)` doesn't transfer cleanly. MIME validation against per-model capability tables is deferred to a future llm_db rollout (§6.3) or to a Phase 16.X opt-in helper. Gemini's pre-flight today validates wire-shape only (URL rejection + nil-mime-file rejection in `reject_unsupported_image_sources/1`). Documented per CLAUDE.md "Decision text drift" rule.
- [ ] No streaming-mapper change required (image-out is Phase 16.5; image-in only affects request build).

#### 16.4.3 Verification

```bash
mix test test/allm/providers/gemini_vision_test.exs
mix test                                       # full suite green
mix credo --strict lib/allm/providers/gemini.ex
mix dialyzer
```

---

### Phase 16.5 — `ALLM.Providers.Gemini.Images` (native image-out) (Layer B)

**Goal:** `Gemini.Images.generate/2` returns image bytes from Gemini-native image models (`gemini-3.1-flash-image-preview` / "Nano Banana 2", `gemini-3-pro-image-preview` / "Nano Banana Pro") via `generateContent` with `responseModalities: ["TEXT", "IMAGE"]`. Reuses `Gemini.to_gemini_request_body/2` (Decision #7).

**Spec sections:** §35.3, §35.7 (refined).

#### 16.5.1 Test Plan (write first)

`test/allm/providers/gemini/images_test.exs` (NEW):

- `supported_operations/0 == [:generate, :edit]` (Decision #6).
- `generate/2 with operation: :variation returns {:error, %ImageAdapterError{reason: :unsupported_operation, metadata: %{operation: :variation}}}` BEFORE any HTTP I/O.
- `generate/2 with operation: :generate, prompt: "...", model: "gemini-3.1-flash-image-preview" sends generationConfig.responseModalities: ["TEXT", "IMAGE"]`.
- `generate/2 decodes inlineData parts in candidates[0].content.parts into %Image{source: {:binary, ...}, mime_type: "image/png"}`.
- `generate/2 with n=2 sets generationConfig.candidateCount: 2 and decodes two %Image{} entries from candidates[].content.parts[]` (Gemini's `generationConfig.candidateCount` accepts integers ≥1; the implementer verifies the model accepts >1 against the live API as part of Phase 16.6, and if rejected falls back to `n=1`-only with a `:unsupported_feature` error, captured as a separate failing test row that's flipped at 16.6 verification time).
- `generate/2 with operation: :edit, prompt: "...", input_images: [%Image{...}] sends a parts list containing both the inlineData source and the text prompt` (note: `ImageRequest.input_images` field name per `lib/allm/image_request.ex`, not `source_image`).
- `generate/2 with size: "1024x1024" sets generationConfig.imageConfig.aspectRatio: "1:1"` (Decision #19 mapping table — see below).
- `generate/2 honors opts[:request_timeout]`.
- `generate/2 with promptFeedback.blockReason returns {:error, %ImageAdapterError{reason: :content_filter}}` (image flow chooses to error rather than return empty content — image generation has no "empty image" semantics).
- Error mapping: one test per row of Decision #15 (delegated to a shared `classify_error/3` helper).
- `generate/2 preserves opts[:request_id] onto response.request_id` (`ImageAdapter` invariant 5).
- `generate/2 round-trips request.metadata onto response.metadata` (`ImageAdapter` invariant 6).

`test/allm/providers/gemini/images_translator_parity_test.exs` (NEW):

- **`:generate` parity** — `Gemini.Images.generate/2(operation: :generate, prompt: "p", model: "gemini-3.1-flash-image-preview")` and `Gemini.generate/2(%Request{messages: [user "p"], model: "gemini-3.1-flash-image-preview", response_format: :text})` produce byte-equal request bodies modulo `generationConfig.responseModalities` (image adds `["TEXT", "IMAGE"]`).
- **`:edit` parity** — `Gemini.Images.generate/2(operation: :edit, prompt: "make it red", input_images: [src_img], model: "gemini-3.1-flash-image-preview")` and `Gemini.generate/2(%Request{messages: [%Message{role: :user, content: [%TextPart{text: "make it red"}, %ImagePart{image: src_img}]}], model: "gemini-3.1-flash-image-preview"})` produce byte-equal request bodies modulo `generationConfig.responseModalities`. Pins the Phase 16.4 `part_to_block/1` helper (cross-provider name; earlier design prose said `to_image_part/1`) as the single image-in code path used by both entry points (no parallel implementation).
- **Response-decoder shared-helper sanity** — a recorded fixture containing both `text` and `inlineData` parts: `Gemini.Decode.candidate_parts/1` returns the same `{text, _, image_parts, _}` tuple regardless of caller. Pinned via direct unit test (the helper is `@doc false`).

`test/allm/providers/gemini/images_wire_test.exs` (NEW):

- Recorded-response decode tests pinning the inlineData decode path against drift.

**Decision #19: image-size mapping** (added here because it's image-only):

| ALLM `ImageRequest.size` | Gemini `imageConfig.aspectRatio` |
|--------------------------|----------------------------------|
| `"1024x1024"`, `"512x512"`, `"256x256"`, any square | `"1:1"` |
| `"1792x1024"`, any 16:9 ratio | `"16:9"` |
| `"1024x1792"`, any 9:16 ratio | `"9:16"` |
| `"1024x768"`, any 4:3 | `"4:3"` |
| `"768x1024"`, any 3:4 | `"3:4"` |
| `nil` | omit `imageConfig` (Gemini default) |
| anything else | `{:error, %ImageAdapterError{reason: :invalid_request, message: "Gemini requires aspect-ratio sizes (1:1, 16:9, 9:16, 4:3, 3:4)"}}` |

**Ratio-matching tolerance.** "Any 16:9 ratio" / "any 9:16 ratio" / "any 4:3" / "any 3:4" rows match the supplied `WxH` against the canonical ratio with a **5% float tolerance** (`abs(w/h - target) / target <= 0.05`). This lets common near-canonical sizes (e.g. `1280x720` for 16:9, `720x1280` for 9:16) map cleanly without forcing callers to memorize Gemini's canonical pixel counts. Exact canonical sizes (`1792x1024`, `1024x1792`, `1024x768`, `768x1024`) are guaranteed to match by construction. Sizes outside 5% of any supported ratio fall through to the `invalid_request` error row.

Pixel sizing (`imageSize: "1K"|"2K"|"4K"`) is not exposed in the v0.2 `ImageRequest.size` field; deferred. Aspect-ratio is the only knob.

#### 16.5.2 Implementation Checklist

- [ ] `lib/allm/providers/gemini/images.ex` — skeleton with `@behaviour ALLM.ImageAdapter`.
- [ ] `Images.supported_operations/0` returns `[:generate, :edit]`.
- [ ] `Images.generate/2`:
  - 1. Operation gate (return `:unsupported_operation` BEFORE I/O).
  - 2. Resolve key via `ALLM.Keys.fetch!(:gemini, opts)`.
  - 3. Build chat-equivalent `%Request{}` from `%ImageRequest{}`:
    - `:generate` — synthesize a single `%Message{role: :user, content: req.prompt}`.
    - `:edit` — synthesize a `%Message{role: :user, content: [%TextPart{text: req.prompt} | image_parts]}` where each `img` in `req.input_images` is wrapped as `%ImagePart{image: img, detail: :auto}`. `ImageRequest.input_images` is `[Image.t()]` (not `[ImagePart.t()]`) per `lib/allm/image_request.ex` — the wrap step is required.
  - 4. Delegate body-build to `Gemini.to_gemini_request_body/2` (which now handles `ImagePart` lists thanks to Phase 16.4).
  - 5. Override `generationConfig.responseModalities = ["TEXT", "IMAGE"]` and `generationConfig.imageConfig.aspectRatio` from Decision #19 mapping.
  - 6. Fire `Req.post/1` inside `ALLM.Retry.run/3` with the unwrapped default retry policy.
  - 7. Decode response via the shared `Gemini.Decode.candidate_parts/1` helper; filter for `inlineData` entries → `%Image{source: {:binary, Base.decode64!(data)}, mime_type: mt}`.
- [ ] `Images.prepare_request/2` mirrors the unfired-Req escape hatch.
- [ ] Image-script test injection per Phase 15 precedent: `opts[:adapter_opts][:image_script]` delegates to `ALLM.Providers.FakeImages.generate/2` for deterministic tests. Verified at design time: `lib/allm/providers/fake_images.ex` exposes `generate/2` accepting scripted `images:` and `:capture_pid` opts; the `image_script` indirection is the OpenAI.Images precedent at `lib/allm/providers/openai/images.ex:251` ("Decision #20").

#### 16.5.3 Verification

```bash
mix test test/allm/providers/gemini/
mix test                                       # full suite green
mix credo --strict lib/allm/providers/gemini/images.ex
mix dialyzer
```

---

### Phase 16.6 — Examples wiring + live-API validation gate (Layer B)

**Goal:** `examples/_helpers.exs` includes the `"gemini"` provider row; all 10 example scripts run green under `ALLM_PROVIDER=gemini mix run examples/run_all.exs`; `examples/RUN_OUTPUT_GEMINI.md` captured.

**Spec sections:** none (operational gate).

#### 16.6.1 Test Plan (write first)

`test/allm/providers/gemini_live_test.exs` (NEW, `@moduletag :live_gemini`, excluded from default `mix test`):

- One `@tag :live` test per representative example script (text/stream/tools/vision/image-out — five total, mirroring scripts 01/02/03/06/10), exercising the full path against the live API. Each test starts a real `Finch` and reads `GEMINI_API_KEY` from `.env`. The remaining example scripts (04/05/07/08/09) are covered by the `ALLM_PROVIDER=gemini mix run examples/run_all.exs` BLOCKING gate; the live-test module is a deterministic subset for `mix test`-style fast regression. Mirrors the OpenAI / Anthropic live-test pattern (also reduced to a representative set, not one-per-script).

`conformance/test/gemini_conformance_test.exs` (NEW):

- Runs `ALLM.Test.ImageAdapterConformance` against `ALLM.Providers.Gemini.Images` using `Req.Test` stubs (the only conformance harness wireable against real provider adapters via the `:image_script` injection seam present on `Gemini.Images` per Phase 16.5 / Decision #20-images).
- Asserts `supported_operations() == [:generate, :edit]` and `:variation` is rejected.
- The chat-adapter `AdapterConformance` + `StreamAdapterConformance` harnesses are stub-only: they drive via `adapter_opts[:script]`, a test-injection seam present on `ALLM.Providers.Fake` (`conformance/test/allm/test/adapter_conformance_test.exs:11` invokes `ALLM.Test.Fixtures.StubAdapter`) but NOT on the real `Gemini` chat adapter — same as `OpenAI` and `Anthropic` (neither ships a `*_conformance_test.exs` invoking those harnesses). Wiring them against the real `Gemini` chat adapter would attempt live network calls for every case.

#### 16.6.2 Implementation Checklist

- [ ] `examples/_helpers.exs` `@providers` map gets a `"gemini"` row, plus the new `:default_temperature` field per Decision #20:
  ```elixir
  "gemini" => %{
    adapter: ALLM.Providers.Gemini,
    default_model: "gemini-3-flash-preview",
    key_env: "GEMINI_API_KEY",
    image_adapter: ALLM.Providers.Gemini.Images,
    image_default_model: "gemini-3.1-flash-image-preview",
    default_temperature: 1.0
  }
  ```
- [ ] `engine/1` in `examples/_helpers.exs` reads the row's `:default_temperature` (default `0` when absent) and merges it onto `extra_opts` BEFORE the caller's overrides — caller-supplied `temperature:` still wins.
- [ ] Verify the model strings against the live `models?key=$GEMINI_API_KEY` listing as the FIRST step of Phase 16.6; if either preview suffix has rotated or a GA name has shipped, update the `@providers` row and CHANGELOG before running the rest of `run_all.exs`.
- [ ] No change to `run_all.exs` if it already iterates `@providers` keys; otherwise add `"gemini"`.
- [ ] Run `ALLM_PROVIDER=gemini mix run examples/run_all.exs`. **BLOCKING gate per CLAUDE.md provider-examples rule.** Must exit 0 across all 10 scripts.
- [ ] Capture stdout into `examples/RUN_OUTPUT_GEMINI.md` (mirror `RUN_OUTPUT_OPENAI.md` and `RUN_OUTPUT_ANTHROPIC.md` format).
- [ ] Update `CHANGELOG.md` with one line per public-API addition (the two new modules).
- [ ] If any prior-phase `lib/` bug surfaces during live validation (per CLAUDE.md "Cross-phase bug discipline"): document in retro, work around in script/README, do NOT modify `lib/` in this phase.

#### 16.6.3 Verification

```bash
mix test                                                       # default exclusion still green
mix test --include live test/allm/providers/gemini_live_test.exs   # requires GEMINI_API_KEY in .env
ALLM_PROVIDER=gemini mix run examples/run_all.exs              # BLOCKING gate
cd conformance && mix test                                      # conformance suite green
```

## Test Plan (cross-phase)

- **Unit tests** — every public function has happy-path + error-path coverage. The `finish_reason` mapping table (Decision #14) and error-classification table (Decision #15) get one test per row — these are closed-enum tables and rule-5 enforcement.
- **Behaviour conformance tests** — Phase 16.6 adds `gemini_conformance_test.exs` invoking the three existing conformance harnesses (`AdapterConformance`, `StreamAdapterConformance`, `ImageAdapterConformance`).
- **Integration tests** — provided via the recorded-fixture wire tests + the live-API tests (Phase 16.6).
- **Property tests** — stream-equivalence for chat (Phase 16.2 + Phase 16.3 extension); request-builder parity for image vs chat translator (Phase 16.5).
- **Doctests** — every public function in `Gemini` and `Gemini.Images` has at least one runnable doctest, using `Req.Test` stubs (or `FakeImages` for image-out).
- **Serializability tests** — none new; Layer A is unchanged.
- **Stream-equivalence relaxation budget**:

  | Relaxation | Justification | Risk |
  |------------|---------------|------|
  | (none) | Decision #1's single translator means request-build is identical between paths; response decoder and stream chunk-mapper share `parse_finish_reason/1`, `parse_usage/1`, `decode_tool_calls/1` helpers. | n/a |

  **Empirical verification of stream-equivalence (with explicit per-phase relaxations):** the existing chat-equivalence property suite at `test/allm/chat_equivalence_test.exs` (verified at design time) is **fixture-driven over `ALLM.Providers.Fake` only** — it does NOT iterate provider adapters, so plugging Gemini in requires more than adding a row. Gemini stream-equivalence is therefore tested **adapter-internally** in `test/allm/providers/gemini_stream_test.exs` via a property over ≥10 recorded SSE fixtures, asserting `Gemini.generate/2(req) == Gemini.stream/2(req) |> StreamCollector.collect/1` on `{content, finish_reason, usage}` for each `@full_equivalence_fixtures` entry, plus a sub-projection `{content, usage}` for the two `@functioncall_fixtures` entries. `Response.raw_finish_reason` is excluded until Phase 16.7 closes the StreamCollector round-trip gap (top-level field on `%ALLM.Response{}` per `lib/allm/response.ex:41`; the collector's `:message_completed` fold at `lib/allm/stream_collector.ex:274-294` reads only `:finish_reason` and `:metadata` from the payload, never `:raw_finish_reason`); `tool_calls` is excluded for `functionCall`-bearing fixtures until Phase 16.3 lands the non-streaming decoder. The shared `parse_*` helpers (Decision #1) make divergence structurally unlikely; the property is the witness. The `:usage` overwrite-on-read behaviour required for Decision #12 is verified at `lib/allm/stream_collector.ex` (StreamCollector clauses begin at line 212+; the `:raw_chunk {:usage, _}` fold uses `struct!(ALLM.Usage, map)` which replaces — not merges — usage state per the moduledoc usage-fold contract).

- **Coverage threshold:** ≥90% on new code (`lib/allm/providers/gemini.ex` + `lib/allm/providers/gemini/images.ex` + `lib/allm/providers/support/gemini_headers.ex`); 80% global floor unchanged.

## Error Contract

This phase introduces **no new error types** and **no new reason atoms**. All Gemini errors map onto `%ALLM.Error.AdapterError{}` (chat/stream) or `%ALLM.Error.ImageAdapterError{}` (image) per the existing closed enums.

### Error-reason table (chat — Phase 16.1, 16.2, 16.3, 16.4)

Per Decision #15 mapping. Repeated here for spec compliance:

| Function | Error reason | Recovery guidance |
|----------|--------------|-------------------|
| `generate/2`, `stream/2` | `:authentication_failed` | Caller's API key missing/invalid; surface to user, no retry. |
| `generate/2`, `stream/2` | `:rate_limited` | Provider 429 (Google `RESOURCE_EXHAUSTED`); retried by default policy with backoff. |
| `generate/2`, `stream/2` | `:invalid_request` | Provider 400 (`INVALID_ARGUMENT` / `NOT_FOUND`); surface to caller. |
| `generate/2`, `stream/2` | `:context_length_exceeded` | 400 with `"exceeds the maximum number of tokens"` substring; caller must shorten input. |
| `generate/2`, `stream/2` | `:content_filter` | mid-stream prompt-block (`promptFeedback.blockReason`) OR `:malformed_function_call` etc; surfaced as response finish_reason in some paths (Decision #9). |
| `generate/2`, `stream/2` | `:provider_unavailable` | 5xx; default-policy retry. |
| `generate/2`, `stream/2` | `:timeout` | request_timeout / stream_timeout exceeded. |
| `generate/2`, `stream/2` | `:network_error` | TCP/TLS/DNS failure. |
| `generate/2`, `stream/2` | `:malformed_response` | 200 with empty candidates AND no promptFeedback.blockReason (Decision #10). |
| `generate/2`, `stream/2` | `:unsupported_feature` | `ImagePart{source: {:url, _}}` reaches translator (Phase 16.4 out-of-scope branch). |

### Error-reason table (images — Phase 16.5)

| Function | Error reason | Recovery guidance |
|----------|--------------|-------------------|
| `Images.generate/2` | `:unsupported_operation` | `:variation` requested; not supported. Caller's responsibility to pick `:generate` or `:edit`. |
| `Images.generate/2` | `:invalid_request` | Bad size mapping (Decision #19) OR provider-rejected request. |
| `Images.generate/2` | `:content_filter` | promptFeedback.blockReason in image flow (no empty-image semantics). |
| `Images.generate/2` | `:authentication_failed`, `:rate_limited`, `:provider_unavailable`, `:timeout`, `:network_error`, `:malformed_response` | Same mapping as chat (shared `classify_error/3`). |

## Streaming & Backpressure

(Phase 16.2.)

- **Cleanup is mandatory.** `Stream.resource/3` `after_fun` cancels the Finch ref via `Finch.cancel_async_request/1` whenever `state.done == false`. Verified by a test that calls `Enum.take(stream, 2)` and asserts no leaked process.
- **Backpressure model.** Finch HTTP/1, line-buffered SSE via `ALLM.Providers.Support.SSE`. Gemini events span at most a few KB (one `GenerateContentResponse` per event); no chunk-spans-multiple-events handling needed beyond what the SSE decoder already provides.
- **Cancellation.** Test `stream/2 cancels Finch ref within 500ms` (≤500ms cancellation deadline per spec §7.2). `FinchStub` simulates a slow upstream and the test asserts cancellation event arrives in time.
- **Connection-close termination.** Per Decision #13: the synthetic `:message_completed` event fires from accumulated state when Finch reports `:done`. No `data: [DONE]` lookahead.
- **`stream_timeout` honored** — `next_fun` calls `receive ... after stream_timeout -> emit :timeout error event`. Mirrors `lib/allm/providers/openai.ex:846-852`.

## Deferred follow-on: Phase 17 — provider-neutral image-generation tool helper

Out of scope for this phase, **but explicitly planned as the next step** so callers have a one-line path to wire image generation into a chat conversation:

- `lib/allm/tools/image_gen.ex` (NEW, Phase 17) — `ALLM.Tools.ImageGen.tool(image_engine, opts \\ [])` returns a configured `%ALLM.Tool{}` with a sensible JSON schema (`prompt`, optional `size`, optional `model`) and a handler that closes over the supplied image engine and dispatches to `ALLM.generate_image/3`. Companion `edit_tool/2` mirrors `ALLM.edit_image/3`.
- The handler's return shape is selectable via `opts[:return]` ∈ `:base64 | :data_uri | {:persist, fun}`. Default: `:data_uri` (compact, model-readable, no filesystem coupling).
- Provider-neutral by construction — the closed-over `image_engine` can carry any `ALLM.ImageAdapter`. A typical wiring is `chat_engine.adapter = Anthropic` plus `image_engine.image_adapter = Gemini.Images`, giving Anthropic chat the ability to call out to Gemini for images.
- Closure handlers are not ETF-serializable; users persisting `ALLM.Session{}` re-attach the handler at load time per the existing `ALLM.Tool` moduledoc rule. Phase 17 documents this; nothing changes about the underlying `Tool` contract.
- Out of scope for Phase 17 itself: auto-attach via `Engine` (`expose_image_tools: true`-style flag), reserved tool names handled inside the orchestration loop, or any chat-loop change. Phase 17 is purely additive: a builder, a schema, an example script, tests.

This deferral keeps Phase 16's surface tight (six provider-adapter sub-phases, no orchestration changes) and preserves the §35.7 bundling rule's clean "one image adapter per provider per chat-shared surface" line. Phase 17 lands after Phase 16 verifies live; estimated ~1 week.

## Definition of Done

- [ ] All 6 sub-phases marked `Completed`.
- [ ] Spec amendments to §32.1 + §35.7 merged before Phase 16.1.
- [ ] `mix test` zero failures, zero `unused_var` warnings, coverage ≥80% globally and ≥90% on new code (3 new files: `gemini.ex`, `gemini/images.ex`, `support/gemini_headers.ex`).
- [ ] `mix credo --strict` zero issues on changed files.
- [ ] `mix dialyzer` zero new warnings.
- [ ] `mix format --check-formatted` passes.
- [ ] Every new public function has `@spec` and `@doc` with at least one runnable doctest.
- [ ] Conformance suite (`AdapterConformance` + `StreamAdapterConformance` + `ImageAdapterConformance`) passes for `Gemini` and `Gemini.Images`.
- [ ] Stream-equivalence property test green on Gemini scripted fixtures (no relaxations).
- [ ] **BLOCKING:** `ALLM_PROVIDER=gemini mix run examples/run_all.exs` exits 0 with all 10 scripts succeeding against the live API.
- [ ] `examples/RUN_OUTPUT_GEMINI.md` captured.
- [ ] CHANGELOG.md updated.
- [ ] Reviewed via `/review`.
- [ ] Implementer-reported per-clean-run cost is within $0.05–$0.15 (Decision #17 estimate ± debugging margin).
