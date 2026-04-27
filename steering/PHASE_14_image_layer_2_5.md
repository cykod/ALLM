# Phase 14: v0.3 Image Pipeline Spine — Behaviour, Layer C Facade, Cross-Cutting, Multimodal Parts

> **Goal:** Take the Layer A image data structs from Phase 13 and turn them into a complete request/response pipeline: a behaviour with conformance + deterministic Fake (sub-phase 14.1, v0.3 Phase 2); the `ALLM.generate_image/3 · edit_image/4 · image_variations/3` Layer C façade dispatching against `engine.image_adapter` (sub-phase 14.2, v0.3 Phase 3); telemetry spans, capability pre-flight, retry integration (sub-phase 14.3, v0.3 Phase 4); structured multimodal content parts on the chat-side (sub-phase 14.4, v0.3 Phase 5).
> **Outcome:** An engine with `image_adapter: ALLM.Providers.FakeImages` produces real `%ALLM.ImageResponse{}` values from `ALLM.generate_image/3`. `[:allm, :image, :start | :stop]` telemetry fires per call. A request whose model declares `images_enabled: false` (when the optional `LLMDB` catalog is loaded) is rejected before any adapter call. `Message.content` accepts `String.t() | [TextPart.t() | ImagePart.t()]`; the v0.2 `[map(), …]` form is removed. Every v0.2 chat caller using string content is unchanged.
> **Spec sections:** §35.3 (`ALLM.ImageAdapter`), §35.4 (engine integration — call-site dispatch), §35.5 (`generate_image/3 · edit_image/4 · image_variations/3` public API), §35.6 (`TextPart`, `ImagePart`, `Message.content` widening), §35.8 (`FakeImages`), §35.9 (telemetry); refines §16 (validators), §29 (telemetry), §6.1 (retry).
> **Layers touched:** B (sub-phase 14.1 — behaviour + Fake adapter), C (14.2 — public façade), B cross-cutting (14.3 — telemetry/capability/retry wiring), A (14.4 — multimodal content-part structs). Each sub-phase touches one layer; no sub-phase crosses a boundary. The doc bundles four single-layer phases per the user's brief; the per-sub-phase shippability invariant is preserved (each sub-phase ends with green `mix test`, `mix credo --strict`, `mix dialyzer`).

## Status

| Phase | Description | Layer | Status |
|-------|-------------|-------|--------|
| 14.1  | `ALLM.ImageAdapter` behaviour + `ALLM.Providers.FakeImages` + published `ALLM.Test.ImageAdapterConformance` | B | Completed |
| 14.2  | `ALLM.generate_image/3 · edit_image/4 · image_variations/3` against `engine.image_adapter` end-to-end through `FakeImages` | C | Not Started |
| 14.3  | `[:allm, :image, :start \| :stop]` telemetry + `ALLM.Capability.preflight_image/2` + `ALLM.Retry` integration + FakeImages `retry_until_call:` extension | B (cross-cutting) | Not Started |
| 14.4  | `ALLM.TextPart`, `ALLM.ImagePart`, `Message.content` widening to `String.t() \| [TextPart.t() \| ImagePart.t()]`; remove v0.2 `[map(), …]` form | A | Not Started |

**Overall Progress:** 0/4 phases complete

## Overview

Phase 13 shipped the four Layer A image structs and a validator; nothing dispatches yet. Phase 14 turns that data layer into a working pipeline: a behaviour for adapters to implement, a deterministic `FakeImages` provider that implements it, a Layer C public façade that calls the adapter, the cross-cutting machinery (telemetry, capability, retry) that wraps the call, and the multimodal-input structured parts that let chat-side adapters consume `ALLM.Image` values inside `Message.content`. Nothing in Phase 14 touches a real network — the OpenAI Images adapter is Phase 15 (`PHASE_15_*.md`, separate doc), and the OpenAI/Anthropic chat-adapter vision wiring is Phase 16 / 17 in the v0.3 plan.

The four sub-phases ladder cleanly. 14.1 lands the behaviour + Fake so 14.2 has something to dispatch to. 14.2 lands the façade with a thin `with`-chain — no telemetry, no preflight, no retry — proving the dispatch shape end-to-end against the Fake. 14.3 wraps the bare façade with the cross-cutting machinery; the three concerns are bundled because each is small (≤30 LOC of new code) and they all ride on the same `with`-chain insertion points. 14.4 is independent of 14.1–14.3 — it lives on the chat side and could ship in any order — but is bundled here because the phasing doc orders it after the image core ships (`steering/RELEASE_0_3_PHASING.md:5`) so that a regression in the multimodal content-part normalization cannot break image generation.

- **Deliverables:**
  - `lib/allm/image_adapter.ex` (NEW) — behaviour with three callbacks (`generate/2`, optional `prepare_request/2`, `supported_operations/0`).
  - `lib/allm/providers/fake_images.ex` (NEW) — scripted Fake; ships in `lib/` not `test/support/` (matches `ALLM.Providers.Fake` precedent at `lib/allm/providers/fake.ex` — published with the library so user tests can use it).
  - `conformance/lib/allm/test/image_adapter_conformance.ex` (NEW) — published conformance suite under the existing `conformance/` Mix project (`mix.exs:51` already wires `:allm_conformance` as a path dep `only: :test`).
  - `conformance/test/allm/test/image_adapter_conformance_test.exs` (NEW) — self-test that the harness produces exactly `@case_count` cases (mirrors `conformance/test/allm/test/adapter_conformance_test.exs` per `conformance/lib/allm/test/adapter_conformance.ex:41`).
  - `lib/allm.ex` (MODIFY) — add `generate_image/3`, `edit_image/4`, `image_variations/3` plus a thin `do_generate_image/3` private helper.
  - `lib/allm/error/engine_error.ex` (MODIFY) — extend `@type reason` and `@legal_reasons` with `:no_image_adapter`.
  - `lib/allm/error/image_adapter_error.ex` (NEW — 14.1) — closed-enum exception struct mirroring `ALLM.Error.AdapterError`. Twelve reason atoms (see Decision #4); fields `:reason`, `:message`, `:provider`, `:status`, `:retry_after_ms`, `:cause`, `:metadata`. Layer A — serializable. Registered in `Serializer.@known_modules` in 14.1 (separate from the 14.4 TextPart/ImagePart extension).
  - `lib/allm/telemetry.ex` (MODIFY) — extend `@valid_span_names` with `:image`; add `:image` to the `span_name()` typedoc.
  - `lib/allm/capability.ex` (MODIFY) — add `preflight_image/2` (parallel to existing `preflight/3`); LLMDB catalog schema extension documented for upstream.
  - `lib/allm/retry.ex` (MODIFY — doc only) — moduledoc note that the helper is now also called from the image-side façade; no signature change.
  - `lib/allm/text_part.ex`, `lib/allm/image_part.ex` (NEW) — Layer A structs per spec §35.6.
  - `lib/allm/message.ex` (MODIFY) — `@type t` widens `:content` to `String.t() | [TextPart.t() | ImagePart.t()]`; add `normalize_content/1` helper.
  - `lib/allm/validate.ex` (MODIFY) — `Validate.message/1` accepts `TextPart`/`ImagePart` structs in lists, rejects raw maps; remove `:vision_not_in_v0_2` hard-reject path.
  - `lib/allm/error/validation_error.ex` (MODIFY) — remove `:vision_not_in_v0_2` from `@type reason` enum and `@legal_reasons` (vision is supported in v0.3).
  - `lib/allm/serializer.ex` (MODIFY) — add `ALLM.TextPart`, `ALLM.ImagePart` to `@known_modules`.
  - `test/allm/validate_test.exs` (MODIFY) — convert the seven `:vision_not_in_v0_2`-asserting tests into `TextPart`/`ImagePart` accept/reject tests; remove the v0.2 raw-map happy-path test (line 252-258) per "raw maps no longer accepted."
  - `test/allm/stream_runner_test.exs` (MODIFY) — convert the line 118 raw-map content fixture to `%ImagePart{}`.
  - `test/allm/response_test.exs` (MODIFY) — convert the line 66 raw-map content fixture to `%TextPart{}`.
  - `test/allm/providers/anthropic_wire_test.exs` (MODIFY) — convert line 413 raw-map content fixture to `%ImagePart{}`.
  - `test/support/fake_image_fixtures.ex` (NEW) — at least seven named scripted-response fixtures.
  - `test/support/llm_db.ex` (MODIFY — 14.3) — extend the `@fixtures` map (currently four entries at `test/support/llm_db.ex:18-51`) with three new image-capability fixtures: `"openai:gpt-image-1"` (`images_enabled: true, supported_image_operations: [:generate, :edit]`), `"local:no-images"` (`images_enabled: false`), `"openai:dall-e-3"` (`images_enabled: true, supported_image_operations: [:generate]`). Required so 14.3's `capability_image_test.exs` can drive `preflight_image/2` rejection paths against committed fixtures.
  - Test files mirroring 1:1 (see Module Tree).
- **Spec coverage:** §35.3 (behaviour), §35.4 (engine.image_adapter dispatch — engine field already on the struct from v0.2; this phase wires the call site), §35.5 (façade), §35.6 (TextPart, ImagePart, Message.content widening), §35.8 (FakeImages), §35.9 (telemetry). Refines §16 (validators — adds part-shape rules, removes the vision hard-reject), §29 (telemetry — adds `:image` to the closed span-name set), §6.1 (retry — image calls now use the helper).
- **Layer demonstration.** Each layer has a 3–5 line user-facing snippet:

  ```elixir
  # Layer B (14.1): user implements the behaviour and runs the conformance suite.
  defmodule MyApp.Stability do
    @behaviour ALLM.ImageAdapter
    def supported_operations, do: [:generate]
    def generate(%ALLM.ImageRequest{operation: :generate} = req, _opts), do: ...
  end
  defmodule MyApp.StabilityTest do
    use ExUnit.Case
    use ALLM.Test.ImageAdapterConformance, image_adapter: MyApp.Stability
  end
  ```

  ```elixir
  # Layer C (14.2): user dispatches against the engine — no session, no chat history.
  iex> engine = ALLM.Engine.new(image_adapter: ALLM.Providers.FakeImages,
  ...>   adapter_opts: [image_script: [{:ok, [%ALLM.Image{source: {:binary, <<137,80,78,71>>}, mime_type: "image/png"}]}]])
  iex> {:ok, %ALLM.ImageResponse{images: [_]}} = ALLM.generate_image(engine, "a kestrel")
  ```

  ```elixir
  # Cross-cutting (14.3): user attaches a telemetry handler and observes a span.
  iex> :telemetry.attach("img-handler", [:allm, :image, :stop],
  ...>   fn _n, m, md, _ -> send(self(), {:img, md.request_id, m.duration}) end, nil)
  iex> {:ok, _} = ALLM.generate_image(engine, "a kestrel")
  iex> assert_received {:img, _id, _ns}
  ```

  ```elixir
  # Layer A (14.4): user constructs a multimodal message — no engine, no adapter.
  iex> msg = %ALLM.Message{role: :user, content: [
  ...>   %ALLM.TextPart{text: "What's in this picture?"},
  ...>   %ALLM.ImagePart{image: ALLM.Image.from_url("https://example.com/cat.png"), detail: :high}
  ...> ]}
  iex> :ok = ALLM.Validate.message(msg)
  ```
- **Prerequisites:**
  - Phase 13 complete: `ALLM.Image`, `ALLM.ImageRequest`, `ALLM.ImageResponse`, `ALLM.ImageUsage`, `ALLM.image_request/2`, `ALLM.Validate.image_request/1`, `ValidationError.@type reason` extended with `:invalid_image_request`. Citations: `steering/PHASE_13_image_layer_a.md`.
  - v0.2 chat pipeline: `ALLM.Adapter` (`lib/allm/adapter.ex`), `ALLM.Providers.Fake` (the parallel pattern for `FakeImages`), `ALLM.Telemetry` (`lib/allm/telemetry.ex:39`), `ALLM.Capability` (`lib/allm/capability.ex`), `ALLM.Retry` (`lib/allm/retry.ex`), the conformance package at `conformance/`.
- **Out of scope (deliberate):**
  - **No real provider adapter.** `ALLM.Providers.OpenAI.Images` is Phase 15 (separate `PHASE_15_*.md`). Phase 14 ships only against `FakeImages`.
  - **No `prepare_request/2` use site.** Phase 14.1 declares the optional callback but doesn't ship a caller; Phase 15's OpenAI Images adapter is the first implementation.
  - **No streaming.** Per phasing principle #2 (`steering/RELEASE_0_3_PHASING.md:12`), there is no `stream_generate_image/3`. The §35.9 telemetry events have no `:start` / partial event analogue beyond the single `:start | :stop` pair on the synchronous span.
  - **No chat-side vision adapter wiring.** The OpenAI chat adapter and Anthropic chat adapter learn to translate `ImagePart` to provider wire shapes in Phase 16/17 of the v0.3 plan. This phase only ships the structs and the validator change; the OpenAI/Anthropic chat adapters' `Validate.message/1`-time behaviour now accepts ImagePart but the ADAPTER itself raises `{:error, %AdapterError{reason: :unsupported_feature}}` until its Phase wires the translator. (`lib/allm/providers/openai.ex` and `lib/allm/providers/anthropic.ex` are MODIFIED in this phase only to add a `:vision_not_yet_wired` `unsupported_feature` rejection — see the Module Tree.)
  - **No assistant-side image-output decoder.** Provider responses with image outputs (rare; some Gemini/OpenAI vision-output models support it) are Phase 16/17 territory.
  - **`Engine.image_adapter` struct field changes.** None — the field already exists from v0.2 sub-phase 2.3 (`lib/allm/engine.ex:74`) and Phase 13 covered the populated round-trip. This phase only USES the field at call time.
  - **LLMDB upstream schema extension is a separate coordination.** This phase ships the consumer-side preflight (`preflight_image/2`) tolerating both atom-keyed and string-keyed capability shapes per the existing `Capability` precedent at `lib/allm/capability.ex:295-318`, plus the in-repo `test/support/llm_db.ex` fixture extension (see Module Tree). The actual `:llm_db` Hex package needs `images_enabled` / `supported_image_operations` in its model-capability schema; that PR is filed against the upstream package and tracked as a v0.3.0 release blocker (release-polish phase per `steering/RELEASE_0_3_PHASING.md:149`).
- **Non-obvious decisions:**
  1. **`ALLM.Providers.FakeImages` lives in `lib/`, not `test/support/`.** Matches `ALLM.Providers.Fake` precedent at `lib/allm/providers/fake.ex` — the chat-side Fake is published with the library because users need it for their own application tests. Same rationale applies to image users; `FakeImages` is part of the library surface, not a test-only fixture. The phasing doc says "test vehicle" loosely (`steering/RELEASE_0_3_PHASING.md:67`); refining to match v0.2 precedent. *Docs target: `@moduledoc ALLM.Providers.FakeImages`.*
  2. **The conformance suite lives under `conformance/lib/allm/test/image_adapter_conformance.ex`, NOT `test/support/image_adapter_conformance.ex` as the phasing doc reads.** The published-package convention from v0.2 (`conformance/lib/allm/test/{adapter,stream_adapter,tool_executor,tool_result_encoder}_conformance.ex`) is established at `conformance/lib/allm/test/adapter_conformance.ex:1`. Downstream packages implementing `ALLM.ImageAdapter` (Stability, Replicate, fal.ai per spec §35.7) `use ALLM.Test.ImageAdapterConformance` from the published Hex package — same as v0.2's `ALLM.Test.AdapterConformance`. Refines the phasing doc location. *Docs target: `@moduledoc ALLM.Test.ImageAdapterConformance` + CHANGELOG entry for the conformance package.*
  3. **`supported_operations/0` is per-module (one list for the adapter), NOT per-call-with-model-arg.** Resolves Phase 2 key decision (a) from `steering/RELEASE_0_3_PHASING.md:73` — the per-module list declares the entire universe of operations the adapter can ever perform; per-model gating (e.g., `dall-e-3` is generate-only while `gpt-image-1` does generate+edit) is the OpenAI Images adapter's internal concern, asserted separately in Phase 15. The conformance suite asserts only the per-module list is honored: a request whose `:operation` is not in `supported_operations/0` returns `{:error, %ALLM.Error.ImageAdapterError{reason: :unsupported_operation, metadata: %{operation: op}}}` BEFORE any HTTP call (per Decision #4). *Docs target: `@doc ALLM.ImageAdapter.supported_operations/0`.*
  4. **Image-adapter errors are typed as `ALLM.Error.ImageAdapterError` from Phase 14.1 onward — NOT a bare 2-tuple, NOT `term()`.** Refines spec §35.3's `{:error, term()}` callback shape into a closed-enum exception struct. The error vocabulary mirrors `ALLM.Error.AdapterError`'s chat-side enum (`lib/allm/adapter.ex:51-63`) plus image-specific `:unsupported_operation`. Verified against OpenAI's class hierarchy via context7 query 2026-04-27 against `/openai/openai-python` — the image endpoints (`/v1/images/generations`, `/v1/images/edits`, `/v1/images/variations`) raise the same `APIConnectionError` / `RateLimitError` / `AuthenticationError` / `BadRequestError` / `APIStatusError` classes as chat, so the image-side closed enum is a near-mirror. Closing the type now (vs deferring to Phase 15) lets Layer C's `generate_image/3` `@spec` enumerate every error variant a caller can pattern-match against. Closed reason atoms: `:authentication_failed` (HTTP 401), `:rate_limited` (HTTP 429; `:retry_after_ms` populated from `Retry-After` header), `:invalid_request` (HTTP 400), `:content_filter` (provider safety rejection), `:context_length_exceeded` (gpt-image-1 token-prefix overflow; absent on dall-e-2/3 paths), `:provider_unavailable` (HTTP 5xx), `:timeout` (`request_timeout` exceeded), `:network_error` (TCP/TLS/DNS), `:malformed_response` (200 with unparseable body), `:unsupported_feature`, `:unsupported_operation` (`metadata.operation` carries the rejected atom), `:unknown` (catch-all). Struct also carries `:status` (HTTP status, optional), `:provider` (atom, optional), `:retry_after_ms` (optional), `:cause` (underlying term, optional), `:metadata` (map). *Docs target: `@moduledoc ALLM.Error.ImageAdapterError` + `@doc ALLM.ImageAdapter.generate/2` + `@callback`-level error table.*
  5. **`engine.image_adapter` is read at the top of `generate_image/3` and threaded through; `engine.image_adapter` is NEVER written.** Mirrors the chat-side pattern in `lib/allm/runner.ex:85-99`: `Runner.run/3` reads `engine.adapter` at the top, dispatches via `StreamRunner.run/3`. Image side: `ALLM.generate_image/3` reads `engine.image_adapter`, returns `EngineError{reason: :no_image_adapter}` when nil, otherwise dispatches. *Docs target: `@doc ALLM.generate_image/3`.*
  6. **`edit_image/4` accepts a single `ALLM.Image.t()` OR a 2-element list `[base, mask]`; the explicit `mask:` keyword is also supported.** Resolves Phase 3 key decision (a) from `steering/RELEASE_0_3_PHASING.md:85`. Three call shapes: `edit_image(engine, base_img, "make the sky pink")` (no mask); `edit_image(engine, [base_img, mask_img], "make the sky pink")` (mask-as-second-element); `edit_image(engine, base_img, "make the sky pink", mask: mask_img)` (explicit mask kw). All three are spec-legal: §35.2.2 (`steering/allm_engine_session_streaming_spec_v0_2.md:1850-1854`) reads `:edit` requires "exactly one `input_images` entry (two for inpaint-with-mask); `mask` optional," so 1-image-+-`mask:` and 2-image-list-form are both legal at the validator (Phase 13's `Validate.image_request/1` accepts `length(input_images) in 1..2` and a non-nil `:mask` independently). The third form is the most ergonomic and matches the spec example at lines 1984-1991; the second form maps directly to `ImageRequest.input_images: [base, mask]`; the first form populates `input_images: [base]` and `mask: nil`. The function dispatches on the second-arg shape. *Docs target: `@doc ALLM.edit_image/4`.*
  7. **`request_id` is generated at the top of `generate_image/3` (NOT inside the adapter); propagates onto `ImageResponse.request_id` as the post-call default.** Mirrors `lib/allm/runner.ex:86`'s pattern (`request_id = Keyword.get(opts, :request_id) || Telemetry.request_id()`). The adapter MAY set `request_id` on the response from the provider's response headers (e.g., OpenAI's `x-request-id`); the façade only fills `nil` after the call. The conformance suite asserts that an adapter receiving `opts[:request_id]` reflects it onto the response unchanged (per phasing doc Phase 2 (b) — "preserves `request_id` from `opts` onto the response"). *Docs target: `@doc ALLM.generate_image/3` + conformance suite case "preserves request_id".*
  8. **`generate_image/3 |> :stop` measurement is `image_count: length(response.images)` on success, `image_count: 0` on error.** Resolves Phase 4 key decision (a) from `steering/RELEASE_0_3_PHASING.md:97`. Returning the actual count (vs the requested `n`) makes cost/observability dashboards reflect what the provider produced (which can be lower than `n` for content-filter rejections on partial batches). The requested `n` is also surfaced — under metadata `:n`, NOT measurements — so dashboards can compare requested-vs-delivered. Rationale: measurements are numeric metrics for histograms/counters; metadata is structured context — telemetry-stdlib idiom. *Docs target: `@moduledoc ALLM.Telemetry` (extend with the `:image` span shape).*
  9. **Retry policy reuses v0.2's `default_policy/0` unchanged.** Resolves Phase 4 key decision (b). Image generation calls have longer wall-clock latency than chat (gpt-image-1 calls run 5-30s vs chat sub-5s), but the retry behaviour is governed by the FAILURE-mode latency, not the success-path latency: 429s have `Retry-After` hints (which v0.2's `respect_retry_after: true` honors) and 5xx errors return immediately. The v0.2 defaults (`max_attempts: 3`, `base_delay_ms: 500`, `max_delay_ms: 8000`) gate the inter-attempt backoff, not the per-attempt request budget. Per-image retry tuning remains callsite-overridable via `engine.retry: [base_delay_ms: 2_000]`. *Docs target: `@moduledoc ALLM.Retry` (extend with image-side note).*
  10. **`ALLM.Capability.preflight_image/2` is a sister function, NOT an overload.** Adding `ImageRequest` to `preflight/3`'s signature would force every existing caller (`StreamRunner` chat path) to pattern-match the request type. Sister function keeps the surface narrow: `preflight/3` for `Request`, `preflight_image/2` for `ImageRequest`. The shared `check_capabilities` private helper is split into `check_chat_capabilities` and `check_image_capabilities` — the latter checks `images_enabled` and `supported_image_operations`. *Docs target: `@doc ALLM.Capability.preflight_image/2`.*
  11. **`Validate.message/1` rejects raw map-shaped content list elements; `[TextPart, ImagePart]` is the ONLY accepted list shape.** Resolves the phasing doc's "untyped `list(map())` form is removed" claim (`steering/RELEASE_0_3_PHASING.md:103`). The grep audit (verified 2026-04-27 against current main) found ONE productive use of the v0.2 raw-map form — `test/allm/validate_test.exs:252-258` "accepts a list of map content parts" — and several test fixtures that use raw maps to assert v0.2's `:vision_not_in_v0_2` rejection. All such uses are MODIFIED in this phase to use `TextPart`/`ImagePart`. The phasing doc's "no v0.2 callers" claim is a slight overstatement; the test-side migration is enumerated in §Module Tree. *Docs target: `@moduledoc ALLM.Message` (rewrite content-shape paragraph) + `@doc ALLM.Validate.message/1` + CHANGELOG breaking-change note.*
  12. **`:vision_not_in_v0_2` is REMOVED from `ValidationError.@type reason` and `@legal_reasons`.** Vision is supported in v0.3 — the atom is dead vocabulary. Removing rather than deprecating because it's the cleanest and closed-enum decode round-trip would still round-trip the dead atom (it's `String.to_existing_atom/1`-resolved; if the source atom is gone from the BEAM, it becomes `{:_unknown, :atom_decode_failed}`). A v0.2 serialized session containing a `%ValidationError{reason: :vision_not_in_v0_2}` JSON-decodes to `:atom_decode_failed` in v0.3 — acceptable per the v0.2 atom-decode contract (`lib/allm/serializer.ex:237-242`), and the v0.3 CHANGELOG flags the removal. *Docs target: CHANGELOG breaking-change note + `@moduledoc ALLM.Error.ValidationError` (note removal).*
  13. **Image-validator does NOT run inside `generate_image/3`'s façade — caller-opt-in.** Matches the v0.2 chat-side precedent: `ALLM.request/2` does not call `ALLM.Validate.request/1`; callers opt in. Same here. The façade only validates that the engine has a non-nil `image_adapter`. Validation that `:operation in [:generate, :edit, :variation]`, that `:n >= 1`, etc., is the caller's responsibility — `Validate.image_request/1` is shipped for callers who want it. The capability pre-flight (`preflight_image/2`) IS automatic in the façade per Phase 14.3 (parallel to `Capability.preflight/3`'s `StreamRunner` wiring at `lib/allm/stream_runner.ex` chat side), so a tools-disabled-style rejection still fires when the catalog is loaded. The split is: shape-validation = caller's choice; capability-validation = automatic. *Docs target: `@doc ALLM.generate_image/3`.*
  14. **Both chat adapters get TWO co-ordinated 14.4 changes: a top-level `ImagePart` guard AND a `stringify_content/1` extension to handle `%TextPart{}` lists.** Phase 14.4 ships `ImagePart` as a valid Layer A struct that `Validate.message/1` accepts AND removes the v0.2 raw-map content shape, so chat-adapter content paths must change in two places: (a) **upstream guard** — `if request.messages |> Enum.any?(fn m -> is_list(m.content) and Enum.any?(m.content, &match?(%ALLM.ImagePart{}, &1)) end), do: {:error, %AdapterError{reason: :unsupported_feature, message: "vision input not yet wired in this adapter"}}` placed at the top of each adapter's `generate/2` and `stream/2` BEFORE either of the two endpoint translators runs (OpenAI has dual entry points: `to_openai_messages/1` for Chat Completions at `lib/allm/providers/openai.ex:1622` and `to_responses_input/1` for Responses at `lib/allm/providers/openai.ex:1478`; the guard fires regardless of endpoint variant). (b) **content materialization** — extend `stringify_content/1` (currently `defp stringify_content(parts) when is_list(parts), do: parts` at `lib/allm/providers/anthropic.ex:690` and `lib/allm/providers/openai.ex:1660`) to materialize `%TextPart{text: t}` to its `:text` (text-only `[%TextPart{text: "a"}, %TextPart{text: "b"}]` joins with `"\n"` separator). Without (b), an all-TextPart content list would emit Jason-encoded `__type__`-tagged maps into the wire body — silent corruption. The upstream guard ensures `stringify_content/1` never sees an `ImagePart`. Both changes go away when Phase 16/17 wires the real vision translators. The `:unsupported_feature` reason atom already exists in `ALLM.Error.AdapterError`'s closed enum (`lib/allm/adapter.ex:62`). *Docs target: `@doc ALLM.Providers.OpenAI.generate/2` + `@doc ALLM.Providers.Anthropic.generate/2` + CHANGELOG temporary-guard notes.*
  15. **Sub-phase 14.3 telemetry: per-call `request_id` is the SAME id used by the adapter and surfaced on the response.** Same rationale as 14.2 (Decision #7). The `Telemetry.span(:image, %{request_id: request_id, ...}, fn -> ... end)` wraps the entire `do_generate_image/3` body so both `:start` and `:stop` carry the same `request_id`, matching the chat-side pattern at `lib/allm/runner.ex:86-99`. The adapter receives `opts[:request_id]` and reflects it onto `response.request_id` per Phase 14.1 conformance.

## Behaviour & Type Contracts

### `ALLM.ImageAdapter` — Layer B behaviour (sub-phase 14.1)

```elixir
defmodule ALLM.ImageAdapter do
  @callback generate(ALLM.ImageRequest.t(), keyword()) ::
              {:ok, ALLM.ImageResponse.t()}
              | {:error, ALLM.Error.ImageAdapterError.t()}

  @callback prepare_request(ALLM.ImageRequest.t(), keyword()) ::
              {:ok, Req.Request.t()} | {:error, ALLM.Error.ImageAdapterError.t()}

  @callback supported_operations() :: [ALLM.ImageRequest.operation()]

  @optional_callbacks prepare_request: 2
end
```

**Contract (asserted by the conformance suite).**

- `supported_operations/0` returns a non-empty subset of `[:generate, :edit, :variation]` (closed set per `ALLM.ImageRequest.@type operation`). The suite asserts the function is exported; it does NOT enforce specific atoms (different adapters legitimately support different subsets).
- `generate/2` MUST return `{:error, %ALLM.Error.ImageAdapterError{reason: :unsupported_operation, metadata: %{operation: op}}}` BEFORE any HTTP I/O when `request.operation not in adapter.supported_operations()`. This is the entry-point gate; per-model gating (e.g., `dall-e-3`-only-supports-generate) is the adapter's internal concern. (The earlier `{:error, {:unsupported_operation, op}}` tuple draft was superseded by Decision #4's closed-enum struct typing — see Phase 14.1 review §9 Nit 3.)
- `generate/2` MUST preserve `opts[:request_id]` onto `response.request_id` when the response shape allows. When `opts[:request_id]` is absent, the adapter is free to populate `response.request_id` from a provider-supplied id (e.g., `x-request-id` HTTP header).
- `generate/2` MUST round-trip `request.metadata` onto `response.metadata` UNCHANGED when the adapter has no use for it. This is the §35.2.2/§35.2.3 metadata invariant — opaque to the library, transparent to the user.
- `prepare_request/2` is optional (`@optional_callbacks`). When implemented, returns a configured-but-unfired `Req.Request` with the provider's body, headers, and URL — the caller may further mutate before firing. Mirrors `ALLM.Adapter.prepare_request/2` semantics at `lib/allm/adapter.ex:78-79`.

**Test-observable verifications.**

- `function_exported?(MyAdapter, :supported_operations, 0)` returns `true` after `defmodule … @behaviour ALLM.ImageAdapter` compiles — verified by reading `Module.behaviour_info(ALLM.ImageAdapter, :callbacks)` semantics in OTP 27 docs.
- The conformance suite uses `use ExUnit.CaseTemplate` (not `use ExUnit.Case`) per `conformance/lib/allm/test/adapter_conformance.ex:39` — required so the consuming test file can declare `use ExUnit.Case, async: true` first and then `use ALLM.Test.ImageAdapterConformance, image_adapter: ...`.

### `ALLM.Error.ImageAdapterError` — Layer A (sub-phase 14.1)

```elixir
defmodule ALLM.Error.ImageAdapterError do
  @typedoc "Closed set of image-adapter error reasons (mirrors AdapterError + image-specific)."
  @type reason ::
          :authentication_failed
          | :rate_limited
          | :invalid_request
          | :content_filter
          | :context_length_exceeded
          | :provider_unavailable
          | :timeout
          | :network_error
          | :malformed_response
          | :unsupported_feature
          | :unsupported_operation
          | :unknown

  @type t :: %__MODULE__{
          reason: reason(),
          message: String.t(),
          provider: atom() | nil,
          status: pos_integer() | nil,
          retry_after_ms: non_neg_integer() | nil,
          cause: term() | nil,
          metadata: map()
        }

  defexception [:reason, :message, :provider, :status, :retry_after_ms, :cause, metadata: %{}]

  @spec new(reason(), keyword()) :: t()
  @doc false
  @spec __from_tagged__(map()) :: t()
end

defimpl Jason.Encoder, for: ALLM.Error.ImageAdapterError do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
```

**Invariants.**

- `new/2` mirrors `ALLM.Error.AdapterError.new/2` (`lib/allm/adapter.ex` + the matching `lib/allm/error/adapter_error.ex`): closed-enum guard against `@legal_reasons`, default `:message` of `"image adapter error: \#{reason}"`, raises `ArgumentError` on unknown reason.
- ETF and JSON round-trips total. `ALLM.Serializer.@known_modules` extends with `ALLM.Error.ImageAdapterError` in 14.1 (separate from the 14.4 `TextPart`/`ImagePart` extension — they're independent).
- `:unsupported_operation` carries the rejected atom in `metadata.operation`. Example: `%ImageAdapterError{reason: :unsupported_operation, metadata: %{operation: :edit}, message: "operation :edit not supported by ALLM.Providers.FakeImages"}`.
- `:rate_limited` carries `:retry_after_ms` from the provider's `Retry-After` header parsed by the adapter (parallel to `AdapterError.retry_after_ms`).

### `ALLM.Providers.FakeImages` — Layer B (sub-phase 14.1)

```elixir
defmodule ALLM.Providers.FakeImages do
  @behaviour ALLM.ImageAdapter

  @impl true
  def supported_operations, do: [:generate, :edit, :variation]

  @impl true
  def generate(%ALLM.ImageRequest{} = request, opts)

  @spec script(keyword()) :: :ok
  @spec start_script_cursor() :: pid()
end
```

**Script contract.**

`adapter_opts[:image_script]` accepts a list of script entries:

```elixir
[
  {:ok, [%ALLM.Image{...}, ...], usage: %ALLM.ImageUsage{...}},
  {:ok, [%ALLM.Image{...}]},                                              # usage: defaults to %ImageUsage{images: 1}
  {:error, %ALLM.Error.ImageAdapterError{reason: :rate_limited, ...}},    # any closed-enum reason
  {:retry_until_call, n}                                                  # added in 14.3 — see retry section below
]
```

- `:ok` 2-tuple — return the listed images plus a default `%ImageUsage{images: length(images)}`.
- `:ok` 3-tuple — return the listed images plus the supplied usage.
- `:error` 2-tuple with a `%ImageAdapterError{}` — return the error verbatim.
- Cursor exhaustion (script entry list empty / past the end) is handled internally — `FakeImages` constructs `%ImageAdapterError{reason: :unknown, message: "no scripted image", metadata: %{cause: :no_scripted_image}}` directly and `script/1`'s validator rejects bare-atom script entries. (Earlier drafts described a `{:error, :no_scripted_image}` script-entry shape; the 14.1 implementation simplified this — see Phase 14.1 review §9 Nit 2.)
- `:retry_until_call` — added in 14.3. Returns a synthetic `%ImageAdapterError{reason: :rate_limited, retry_after_ms: 0}` for the first `n - 1` calls, then advances to the next script entry. Test vehicle for the retry-loop integration (mirrors chat-side `ALLM.Providers.Fake`'s `retry_until_call:` per `lib/allm/providers/fake.ex` retry-test pattern).
- `:unsupported_operation` rejection (when the request's operation isn't in `supported_operations/0`) is produced by `FakeImages` itself BEFORE consulting the script — not a script entry — and emitted as `%ImageAdapterError{reason: :unsupported_operation, metadata: %{operation: op}}` per the conformance contract.

State management: process-local under `Process.put/2` keyed at `{:allm_fake_images_cursor, :erlang.phash2(scripts)}` — matches the chat-side pattern at `lib/allm/providers/fake.ex:73-78`. The `start_script_cursor/0` Agent escape hatch is also mirrored (`lib/allm/providers/fake.ex:101-106`).

**`@case_count` for the conformance suite — exact target: 9.** Each row is a numbered `test` block in the injected `describe`. Per AGENT_DESIGN_SPEC §3 rule 7, the `@case_count` attribute is an introspection seam tested by a meta-assertion in `conformance/test/allm/test/image_adapter_conformance_test.exs`.

| # | Test name | Asserts |
|---|-----------|---------|
| 1 | "returns supported_operations/0 list of legal atoms" | `is_list(MOD.supported_operations())` and every element is in `[:generate, :edit, :variation]` |
| 2 | "rejects unsupported operation before any I/O with `{:error, %ImageAdapterError{reason: :unsupported_operation, metadata: %{operation: op}}}`" | Struct shape, exact reason atom, `metadata.operation` carries the rejected operation atom |
| 3 | "preserves opts[:request_id] onto ImageResponse.request_id when adapter does not override" | `response.request_id == "test-id-123"` |
| 4 | "round-trips request.metadata onto response.metadata unchanged when unused" | byte-equal map |
| 5 | "happy path: returns {:ok, %ImageResponse{}} with non-empty images list for :generate + non-empty prompt" | response shape; `length(response.images) >= 1` |
| 6 | "edit happy path: returns {:ok, %ImageResponse{}} for :edit with a single input_image" | response shape |
| 7 | "variation happy path: returns {:ok, %ImageResponse{}} for :variation with a single input_image and nil prompt" | response shape |
| 8 | "ImageUsage defaults: response.usage.images >= 1 when adapter doesn't supply usage" | invariant (allows adapters to default differently as long as `images` is populated) |
| 9 | "n: 4 batch: response.images has length 4 (or adapter's documented batch cap)" | `length(response.images) in 1..4` (open upper bound — providers may cap; test asserts the floor) |

The conformance suite uses a `ScriptedImageStub` test fixture (defined in the conformance package) that implements `ALLM.ImageAdapter` and reads scripted responses from `opts[:script]` — mirroring `conformance/lib/allm/test/adapter_conformance.ex`'s `StubAdapter` at lines 28-37 and 50-58 of that file.

**What is NOT in the conformance contract.**

- `prepare_request/2` is `@optional_callbacks`; its presence/absence is enforced by the BEAM, not the suite. `image_adapter_test.exs` (in `:allm`) covers the optionality contract via `function_exported?/3` directly.
- The `{:retry_until_call, n}` script entry is `FakeImages`-internal and is NOT part of the `ALLM.ImageAdapter` conformance contract. Real adapters drive the retry loop via `%ALLM.Error.ImageAdapterError{reason: :rate_limited, retry_after_ms: ...}`; the FakeImages 14.3 hint synthesizes the same struct so `Retry.run/3` exercises the production code path verbatim.
- Per-model operation gating (e.g., `dall-e-3`-only-supports-generate) is the adapter's internal concern, NOT in the conformance contract. The suite asserts only that `request.operation not in adapter.supported_operations()` produces `{:error, {:unsupported_operation, op}}` before any I/O — per Decision #3.

### `ALLM.generate_image/3 · edit_image/4 · image_variations/3` — Layer C (sub-phase 14.2)

```elixir
@spec generate_image(ALLM.Engine.t(), String.t() | ALLM.ImageRequest.t(), keyword()) ::
        {:ok, ALLM.ImageResponse.t()}
        | {:error,
           ALLM.Error.EngineError.t()
           | ALLM.Error.ValidationError.t()
           | ALLM.Error.ImageAdapterError.t()}

@spec edit_image(
        ALLM.Engine.t(),
        ALLM.Image.t() | [ALLM.Image.t()],
        String.t(),
        keyword()
      ) ::
        {:ok, ALLM.ImageResponse.t()}
        | {:error,
           ALLM.Error.EngineError.t()
           | ALLM.Error.ValidationError.t()
           | ALLM.Error.ImageAdapterError.t()}

@spec image_variations(ALLM.Engine.t(), ALLM.Image.t(), keyword()) ::
        {:ok, ALLM.ImageResponse.t()}
        | {:error,
           ALLM.Error.EngineError.t()
           | ALLM.Error.ValidationError.t()
           | ALLM.Error.ImageAdapterError.t()}
```

**Invariants.**

- `generate_image/3` accepts either a binary prompt OR a fully-built `%ALLM.ImageRequest{}`. Binary form delegates to `ALLM.image_request/2` (Phase 13 façade) and forwards. Struct form is dispatched verbatim.
- `edit_image/4` builds `%ImageRequest{operation: :edit, prompt: prompt, input_images: ..., mask: ...}` per Decision #6's three call shapes.
- `image_variations/3` builds `%ImageRequest{operation: :variation, input_images: [image], prompt: nil}`.
- All three return `{:error, %ALLM.Error.EngineError{reason: :no_image_adapter}}` when `engine.image_adapter == nil`. This check fires BEFORE any other validation or pre-flight (matches chat-side `Engine.adapter == nil` precedent at `lib/allm/stream_runner.ex:151`).
- `request_id` precedence: `opts[:request_id]` > generated via `ALLM.Telemetry.request_id/0` (matches chat-side pattern at `lib/allm/runner.ex:86`). `request_id` is forwarded to the adapter via `opts[:request_id]` so the conformance suite's "preserves request_id" case passes against `FakeImages` and against any compliant adapter.
- `:stream` opt is silently dropped (image generation is non-streaming per phasing principle #2). A user who passes `stream: true` via `engine.params` does NOT get an error — the opt is simply ignored.
- Unknown opts are forwarded to the adapter via `opts` (matches chat-side `Engine.resolve_params/2` pattern at `lib/allm/engine.ex:376-383` — opt keys not in `@engine_field_keys` flow through).

**Cross-function invariant (mirror file:line citation per AGENT_DESIGN_SPEC §3 rule 6a).** `edit_image/4` and `image_variations/3` MUST produce a `%ImageRequest{}` byte-equal to `ALLM.image_request/2 + struct/2`-built equivalent, modulo the `:operation` / `:input_images` / `:mask` / `:prompt` fields they set. Asserted by a Test Plan property in 14.2.1 ("`edit_image/4 |> Map.from_struct() == ImageRequest.new(...) |> Map.from_struct()`").

### `ALLM.Telemetry` extension (sub-phase 14.3)

```elixir
@type span_name :: :generate | :stream | :step | :chat | :tool | :image
@valid_span_names [:generate, :stream, :step, :chat, :tool, :image]
```

The `:image` atom joins the closed enum at `lib/allm/telemetry.ex:50,52`. A `Telemetry.span(:image, ...)` call now succeeds; previously raised `ArgumentError` per the `lib/allm/telemetry.ex:139-143` guard.

**`[:allm, :image, :start]` event.**

- Measurements: `%{system_time: System.system_time()}` — supplied by `:telemetry.span/3` automatically; we don't override.
- Metadata: `%{request_id: String.t(), engine: ALLM.Engine.t(), model: term(), operation: ALLM.ImageRequest.operation(), n: pos_integer()}`.

**`[:allm, :image, :stop]` event.**

- Measurements: `%{duration: non_neg_integer(), monotonic_time: integer(), image_count: non_neg_integer()}` — `:duration` and `:monotonic_time` from `:telemetry.span/3`; `:image_count` injected by the `stop_extras` map per the existing `Telemetry.span/3` pattern at `lib/allm/telemetry.ex:147-151`.
- Metadata: `%{request_id, engine, model, operation, n, usage: ALLM.ImageUsage.t() | nil, error: term() | nil, response: ALLM.ImageResponse.t() | nil}`.
- On error: `:usage` is `nil`, `:error` is the error struct/term, `:response` is `nil`, `:image_count` is `0`.
- On success: `:error` is `nil`, `:usage` is `response.usage`, `:response` is the full `%ImageResponse{}`, `:image_count` is `length(response.images)`.

### `ALLM.Capability.preflight_image/2` (sub-phase 14.3)

```elixir
@type image_preflight_result ::
        :ok
        | {:error, ALLM.Error.ValidationError.t()}

@spec preflight_image(
        ALLM.Capability.model_ref_or_string(),
        ALLM.ImageRequest.t()
      ) :: image_preflight_result()
def preflight_image(model_ref_or_string, %ALLM.ImageRequest{} = request)
```

**Invariants.**

- Returns `:ok` when the catalog is absent (`Capability.catalog_loaded?/0 == false`) — mirrors chat-side at `lib/allm/capability.ex:177-178`.
- Returns `:ok` when `model_ref_or_string` is a bare string/tuple/`nil` (no capability info available).
- Returns `{:error, %ValidationError{reason: :unsupported_capability, errors: errors}}` when at least one rejection rule fires. Atom in `:errors` list is one of `[:images_disabled, :unsupported_image_operation]`.
- Two rejection rules:
  - `{[:images_enabled], :images_disabled}` — fires when `model_ref.capabilities.images_enabled == false` (or string-key shape `%{"images_enabled" => false}` per the JSON-rehydrated tolerance pattern at `lib/allm/capability.ex:296-303`).
  - `{[:operation], :unsupported_image_operation}` — fires when `request.operation not in model_ref.capabilities.supported_image_operations` (with the same string-key tolerance).
- Does NOT include a `:structured_finalize`-style rewrite branch — image requests don't have an analogous rewrite need in v0.3. The function returns `:ok | {:error, _}` (two-shape, NOT three-shape).
- 2-arity by design — symmetric with `populate_costs/2`, NOT with `preflight/3`. `preflight/3`'s third arg exists because it carries a real (`structured_finalize`) rewrite predicate; image-side has no analogous rewrite, so introducing a 3-arity that ignores its third arg is dead API surface (AGENT_DESIGN_SPEC §3 rule 13). If a future image-rewrite predicate lands, widen the arity then.

### `ALLM.Retry` integration (sub-phase 14.3)

No signature change. The `do_generate_image/3` private helper wraps the adapter call inside `ALLM.Retry.run/3`:

```elixir
def do_generate_image(engine, request, opts, telemetry_metadata) do
  policy = Retry.materialize(engine.retry)

  Retry.run(policy, telemetry_metadata, fn ->
    case engine.image_adapter.generate(request, opts) do
      {:ok, response} ->
        {:ok, response}

      {:error, %ALLM.Error.ImageAdapterError{reason: r} = err}
      when r in [:rate_limited, :provider_unavailable, :timeout, :network_error] ->
        delay = err.retry_after_ms || 0
        {:retry, delay, err}

      {:error, _} = err ->
        err
    end
  end)
end
```

Single error shape — `ImageAdapterError` is the closed type. Real-provider adapters (Phase 15 OpenAI Images) emit `%ImageAdapterError{reason: :rate_limited, retry_after_ms: ...}` to engage the retry loop. `FakeImages`'s `:retry_until_call` script entry produces the same struct shape (`%ImageAdapterError{reason: :rate_limited, retry_after_ms: 0}`) so the test-side retry loop exercises the production code path verbatim.

### `ALLM.TextPart` and `ALLM.ImagePart` — Layer A (sub-phase 14.4)

```elixir
defmodule ALLM.TextPart do
  @type t :: %__MODULE__{text: String.t(), metadata: map()}
  @enforce_keys [:text]
  defstruct [:text, metadata: %{}]

  @spec new(String.t(), keyword()) :: t()
  @doc false
  @spec __from_tagged__(map()) :: t()
end

defmodule ALLM.ImagePart do
  @type detail :: :auto | :low | :high
  @type t :: %__MODULE__{
          image: ALLM.Image.t(),
          detail: detail(),
          metadata: map()
        }
  @enforce_keys [:image]
  defstruct [:image, detail: :auto, metadata: %{}]

  @spec new(ALLM.Image.t(), keyword()) :: t()
  @doc false
  @spec __from_tagged__(map()) :: t()
end
```

**Invariants.**

- ETF and JSON round-trips total. `detail: :auto` (struct default) matches OpenAI's default in their wire shape — Phase 16 OpenAI chat adapter uses this directly. Resolves Phase 5 key decision (b) from `steering/RELEASE_0_3_PHASING.md:109`.
- `ALLM.user/1` does NOT grow to `ALLM.user/2`. Resolves Phase 5 key decision (a). Multimodal callers build `%Message{content: [...]}` by hand. The library prefers explicit construction for multimodal (one source of truth — the struct) over a sister facade function (which would diverge from the existing `ALLM.user/1` `String.t()`-only signature). *Docs target: `@moduledoc ALLM.Message` — extend with multimodal example.*

### `ALLM.Message` widening (sub-phase 14.4)

```elixir
@type t :: %__MODULE__{
        role: role(),
        content: String.t() | [ALLM.TextPart.t() | ALLM.ImagePart.t()],
        name: String.t() | nil,
        tool_call_id: String.t() | nil,
        metadata: map()
      }
```

The `[map() | struct()]` arm at `lib/allm/message.ex:22` is REPLACED with `[ALLM.TextPart.t() | ALLM.ImagePart.t()]`. This is a TYPE-narrowing AND a behaviour-narrowing change — the v0.2 `Validate.message/1` accepted any list of maps with all elements being maps; v0.3's accepts only TextPart/ImagePart structs. Per Decision #11.

**`Message.normalize_content/1` helper.**

```elixir
@spec normalize_content(String.t() | [ALLM.TextPart.t() | ALLM.ImagePart.t()]) ::
        [ALLM.TextPart.t() | ALLM.ImagePart.t()]
def normalize_content(content) when is_binary(content),
  do: [%ALLM.TextPart{text: content}]
def normalize_content(parts) when is_list(parts), do: parts
```

Used by the chat-side adapters (Phase 16/17) to lift string content to a single-part list so the wire-shape translator handles only the structured form. Does NOT mutate `Message.content` — it's a one-way normalization at the adapter boundary.

### `ALLM.Validate.message/1` rewrite (sub-phase 14.4)

```elixir
defp validate_content(errs, content) when is_binary(content), do: errs

defp validate_content(errs, content) when is_list(content) do
  cond do
    Enum.all?(content, &(is_struct(&1, ALLM.TextPart) or is_struct(&1, ALLM.ImagePart))) ->
      errs
    true ->
      [{:content, :invalid_part_type} | errs]
  end
end

defp validate_content(errs, _), do: [{:content, :invalid_type} | errs]
```

The `:vision_not_in_v0_2` short-circuit path at `lib/allm/validate.ex:99-117` is REMOVED. The `vision_error/1` and `image_part?/1` private helpers at `lib/allm/validate.ex:394-404` are also REMOVED.

### `ALLM.Serializer` registry extension (sub-phase 14.4)

`@known_modules` at `lib/allm/serializer.ex:64-83` extends from 22 entries (post-Phase 13) to 24 entries:

```elixir
@known_modules [
  …existing 22…,
  ALLM.TextPart,
  ALLM.ImagePart
]
```

### `ALLM.Error.EngineError` enum extension (sub-phase 14.2)

`lib/allm/error/engine_error.ex:13-21` `@type reason` and `@legal_reasons` extend with `:no_image_adapter`:

```elixir
@type reason ::
        :missing_adapter
        | :missing_stream_adapter
        | :missing_model
        | :missing_key
        | :unknown_tool
        | :invalid_engine
        | :unsupported_response_format
        | :no_image_adapter   # NEW (§35.4)
```

### `ALLM.Error.ValidationError` enum reduction (sub-phase 14.4)

`lib/allm/error/validation_error.ex:23-32` `@type reason` REMOVES `:vision_not_in_v0_2`:

```elixir
@type reason ::
        :invalid_request
        | :invalid_message
        | :invalid_tool
        | :invalid_thread
        | :invalid_session
        | :invalid_session_input
        | :unsupported_capability
        # :vision_not_in_v0_2 — REMOVED (vision is supported in v0.3 via ALLM.ImagePart)
        | :invalid_image_request   # from Phase 13
```

CHANGELOG flags this as a breaking change for any caller pattern-matching on `:vision_not_in_v0_2`.

### Field-error vocabulary additions

| Validator | Field path | Reason atom | Hard-reject? | Fires when |
|-----------|------------|-------------|--------------|------------|
| `Capability.preflight_image/2` | `[:images_enabled]` | `:images_disabled` | no | `model_ref.capabilities.images_enabled == false` (or string-key form) |
| `Capability.preflight_image/2` | `[:operation]` | `:unsupported_image_operation` | no | `request.operation not in model_ref.capabilities.supported_image_operations` |
| `Validate.message/1` | `:content` | `:invalid_part_type` | no | content list contains an element that is not `%ALLM.TextPart{}` or `%ALLM.ImagePart{}` |

The `Validate.message/1` `{:content, :image_part}` reason at `lib/allm/validate.ex:113` is REMOVED in 14.4.

## Module Tree

```
lib/allm/
├── image_adapter.ex                       (NEW — 14.1, behaviour with 3 callbacks)
├── providers/
│   ├── fake_images.ex                     (NEW — 14.1; 14.3 extends with retry_until_call)
│   ├── fake.ex                            (UNCHANGED)
│   ├── openai.ex                          (MODIFY — 14.4, ImagePart guard at top of generate/2 & stream/2; extend stringify_content/1 for [%TextPart{}, ...])
│   └── anthropic.ex                       (MODIFY — 14.4, parallel ImagePart guard + stringify_content/1 extension)
├── text_part.ex                           (NEW — 14.4)
├── image_part.ex                          (NEW — 14.4)
├── message.ex                             (MODIFY — 14.4, @type t widens; add normalize_content/1)
├── validate.ex                            (MODIFY — 14.4, validate_content rewrite; remove vision_error/1 + image_part?/1)
├── error/
│   ├── engine_error.ex                    (MODIFY — 14.2, +:no_image_adapter)
│   ├── image_adapter_error.ex             (NEW — 14.1, closed-enum exception struct)
│   └── validation_error.ex                (MODIFY — 14.4, -:vision_not_in_v0_2)
├── telemetry.ex                           (MODIFY — 14.3, +:image to @valid_span_names)
├── capability.ex                          (MODIFY — 14.3, +preflight_image/2)
├── retry.ex                               (MODIFY — 14.3, @moduledoc note only — no signature change)
├── serializer.ex                          (MODIFY — 14.4, +TextPart, +ImagePart in @known_modules)
└── allm.ex                                (MODIFY — 14.2, +generate_image/3 +edit_image/4 +image_variations/3)

conformance/
├── lib/allm/test/
│   └── image_adapter_conformance.ex       (NEW — 14.1, ALLM.Test.ImageAdapterConformance with @case_count 9)
├── test/allm/test/
│   └── image_adapter_conformance_test.exs (NEW — 14.1, meta-test asserting case count + suite passes against FakeImages)
└── CHANGELOG.md                           (MODIFY — 14.1 entry)

test/allm/
├── image_adapter_test.exs                 (NEW — 14.1)
├── providers/
│   └── fake_images_test.exs               (NEW — 14.1; 14.3 extends with retry_until_call cases)
├── allm_generate_image_test.exs           (NEW — 14.2, integration tests against FakeImages)
├── allm_edit_image_test.exs               (NEW — 14.2)
├── allm_image_variations_test.exs         (NEW — 14.2)
├── error/
│   ├── engine_error_test.exs              (MODIFY — 14.2, +:no_image_adapter case)
│   └── image_adapter_error_test.exs       (NEW — 14.1, closed-enum constructor + Exception.message + ETF + JSON round-trip)
├── telemetry_image_test.exs               (NEW — 14.3, :telemetry_test event-handler assertions)
├── capability_image_test.exs              (NEW — 14.3, preflight_image/2 matrix)
├── retry_image_test.exs                   (NEW — 14.3, retry_until_call round-trip)
├── text_part_test.exs                     (NEW — 14.4)
├── image_part_test.exs                    (NEW — 14.4)
├── message_test.exs                       (MODIFY — 14.4, multimodal content + normalize_content/1)
├── validate_test.exs                      (MODIFY — 14.4, convert :vision_not_in_v0_2 cases to TextPart/ImagePart accept; remove raw-map happy-path test at line 252-258)
├── serializer/
│   └── multimodal_message_test.exs        (NEW — 14.4, JSON round-trip for messages with mixed content lists)
├── stream_runner_test.exs                 (MODIFY — 14.4, line 118 raw-map fixture → %ImagePart{})
├── response_test.exs                      (MODIFY — 14.4, line 66 raw-map fixture → %TextPart{})
├── providers/
│   └── anthropic_wire_test.exs            (MODIFY — 14.4, line 413 raw-map fixture → %ImagePart{})
└── error/
    └── validation_error_test.exs          (MODIFY — 14.4, remove :vision_not_in_v0_2 case)

test/support/
└── fake_image_fixtures.ex                 (NEW — 14.1, named scripted fixtures)

CHANGELOG.md                               (MODIFY — one entry per sub-phase)
mix.exs                                    (MODIFY — 14.1, add ALLM.Providers.FakeImages, ALLM.ImageAdapter to docs groups; 14.4, add ALLM.TextPart, ALLM.ImagePart)
```

## Phases

### Phase 14.1: `ALLM.ImageAdapter` Behaviour + `ALLM.Providers.FakeImages` + Conformance Suite

**Goal:** A behaviour that real adapters and the deterministic Fake both implement, plus a published conformance suite usable from downstream packages.

**Spec sections:** §35.3 (behaviour), §35.8 (Fake).

#### 14.1.1 Test Plan (write first)

`test/allm/image_adapter_test.exs` (NEW) — behaviour-level assertions:

- `Module.behaviour_info(ALLM.ImageAdapter, :callbacks) returns the three callback signatures (generate/2, prepare_request/2, supported_operations/0)`
- `Module.behaviour_info(ALLM.ImageAdapter, :optional_callbacks) returns [prepare_request: 2]`
- Doctest: a minimal `defmodule MyAdapter do @behaviour ALLM.ImageAdapter ... end` example showing the three callbacks.

`test/allm/providers/fake_images_test.exs` (NEW):

- **Script-shape coverage** (one test per shape):
  - `:ok 2-tuple {:ok, [%Image{...}]} returns the images plus default usage with images: 1`
  - `:ok 3-tuple {:ok, [...], usage: %ImageUsage{input_tokens: 100}} returns the supplied usage verbatim`
  - `:error 2-tuple {:error, %ImageAdapterError{reason: :rate_limited}} returns the struct verbatim`
  - `:error with bare atom {:error, :no_scripted_image} (cursor-exhaustion shape) is wrapped to {:error, %ImageAdapterError{reason: :unknown, message: "no scripted image", metadata: %{cause: :no_scripted_image}}} before returning to the caller — public API stays in the closed type`
  - `request operation :edit against an adapter whose supported_operations: [:generate] returns {:error, %ImageAdapterError{reason: :unsupported_operation, metadata: %{operation: :edit}}}`
- **Operation × scripted-result matrix:**
  - `:generate with prompt + 1-image script returns the image`
  - `:edit with prompt + input_image + 1-image script returns the image`
  - `:variation with input_image + 1-image script returns the image (prompt is nil)`
  - `n: 4 with a 4-image script returns all four images`
- **State management:**
  - `Process-local cursor advances per call: two consecutive calls against a 2-entry script return entries 0 and 1 in order`
  - `Exhausted script returns {:error, %ImageAdapterError{reason: :unknown, metadata: %{cause: :no_scripted_image}}}` (not a wrap-around)
  - `start_script_cursor/0 returns a pid; passing it as adapter_opts[:script_cursor] isolates the cursor across processes`
- **Conformance:**
  - `use ALLM.Test.ImageAdapterConformance, image_adapter: ALLM.Providers.FakeImages` — the imported `describe` block runs all 9 cases and passes.
- Doctest: `script/1` showing the 2-tuple ok shape.

`conformance/test/allm/test/image_adapter_conformance_test.exs` (NEW):

- `case_count/0 returns 9` (introspection seam — meta-assertion against silent drift)
- `the harness's injected describe block produces exactly @case_count test cases when used with the bundled ScriptedImageStub` — assert by counting `describe` test names via `ExUnit.TestServer` introspection or by manually enumerating in the test (mirror the v0.2 pattern at `conformance/test/allm/test/adapter_conformance_test.exs`)
- `using the harness with image_adapter: ALLM.Providers.FakeImages compiles and all 9 cases pass`

`test/support/fake_image_fixtures.ex` (NEW): seven named fixtures (Decision spec from phasing doc Phase 2):

1. `single_generate/0` — single PNG return for a generate request
2. `multi_generate/1` (n) — n images for batch
3. `edit_with_mask/0` — edit fixture with a 2-image input list
4. `variation/0` — variation fixture
5. `exhausted_script/0` — empty script vehicle
6. `unsupported_op/0` — script declaring `supported_operations: [:generate]` for testing the :edit rejection
7. `gpt_image_1_usage/0` — fixture returning `%ImageUsage{images: 1, input_tokens: 100, output_tokens: 0}`

#### 14.1.2 Implementation Checklist

- [ ] Create `lib/allm/error/image_adapter_error.ex`:
  - `defexception` with the field list per the contract section.
  - `@legal_reasons` closed list of 12 atoms; `new/2` raises `ArgumentError` on unknown reason (mirror `lib/allm/error/adapter_error.ex` precedent).
  - `__from_tagged__/1` hydrator + `defimpl Jason.Encoder, do: encode_tagged/2` (matches v0.2 error-struct precedent at `lib/allm/error/engine_error.ex:92-107`).
  - `Exception.message/1` impl returning `:message` field with default fallback `"image adapter error: \#{reason}"`.
  - Add `@doc` doctests for `new/2` and `Exception.message/1`.
- [ ] Extend `ALLM.Serializer.@known_modules` (`lib/allm/serializer.ex:64`) with `ALLM.Error.ImageAdapterError` (registry goes from 22 to 23 entries; the 14.4 +TextPart/+ImagePart additions extend further to 25).
- [ ] Create `lib/allm/image_adapter.ex` with the three callbacks, `@optional_callbacks prepare_request: 2`, full `@doc` per callback including the contract bullets, and the closed `ImageAdapterError`-typed error table for `generate/2` per Decision #4.
- [ ] Create `lib/allm/providers/fake_images.ex`:
  - `@behaviour ALLM.ImageAdapter`
  - `supported_operations/0` returns `[:generate, :edit, :variation]` (matches v0.2 `Fake` chat-side pattern of "everything supported")
  - `generate/2` reads from `opts[:adapter_opts][:image_script]` (preferring `:image_scripts` for multi-call), pattern-matches the 2/3-tuple shapes, advances the process-local cursor, returns the response or error
  - Returns `{:error, {:unsupported_operation, op}}` BEFORE consulting the script when `op not in @adapter_supported_operations` (per conformance contract)
  - Sets `response.request_id` from `opts[:request_id]` when the script doesn't already populate it
  - Round-trips `request.metadata` onto `response.metadata` when the script doesn't populate it
  - `script/1` and `start_script_cursor/0` mirror the chat-side Fake pattern at `lib/allm/providers/fake.ex`
- [ ] Create `conformance/lib/allm/test/image_adapter_conformance.ex`:
  - `use ExUnit.CaseTemplate` (matches `conformance/lib/allm/test/adapter_conformance.ex:39`)
  - `@case_count 9` + `case_count/0` introspection seam
  - `using opts do quote location: :keep do … end end` injects 9 `test` cases inside `describe "ALLM.ImageAdapter conformance (#{inspect(...)})"`
  - Each test case scripts the `image_adapter` via `adapter_opts[:image_script]` (matches `FakeImages` shape) and asserts the contracted behaviour
  - Bundle a `ScriptedImageStub` test fixture (defined in the conformance package, NOT in `:allm`) for the suite's self-test in `conformance/test/`
- [ ] Create `conformance/test/allm/test/image_adapter_conformance_test.exs` mirroring `conformance/test/allm/test/adapter_conformance_test.exs`'s shape — the meta-test for `@case_count`.
- [ ] Add a CHANGELOG entry in `conformance/CHANGELOG.md` for the new harness.
- [ ] `@doc` with at least one runnable doctest on every public function.
- [ ] CHANGELOG entry: `[FEAT] v0.3 Phase 14.1: ALLM.ImageAdapter behaviour + ALLM.Providers.FakeImages + ALLM.Test.ImageAdapterConformance harness (§35.3, §35.8)`.

#### 14.1.3 Verification

```bash
mix test test/allm/image_adapter_test.exs test/allm/providers/fake_images_test.exs
cd conformance && mix test                                    # harness self-tests pass
cd .. && mix test                                             # full suite green
mix credo --strict lib/allm/image_adapter.ex lib/allm/providers/fake_images.ex
mix dialyzer
```

---

### Phase 14.2: `ALLM.generate_image/3 · edit_image/4 · image_variations/3` Layer C Façade

**Goal:** End-to-end dispatch from `ALLM.generate_image/3` through `engine.image_adapter.generate/2` to a `%ALLM.ImageResponse{}`, against `FakeImages`. No telemetry, no preflight, no retry yet — those land in 14.3.

**Spec sections:** §35.4 (engine integration call site), §35.5 (façade signatures).

#### 14.2.1 Test Plan (write first)

`test/allm/allm_generate_image_test.exs` (NEW):

- **Adapter presence:**
  - `generate_image/3 with engine.image_adapter == nil returns {:error, %EngineError{reason: :no_image_adapter}}`
  - `generate_image/3 with engine.image_adapter set dispatches and returns {:ok, %ImageResponse{}}`
- **String-prompt sugar:**
  - `generate_image(engine, "a kestrel") builds a %ImageRequest{operation: :generate, prompt: "a kestrel"} and dispatches`
  - `generate_image(engine, "a kestrel", n: 2, size: {1024, 1024}) merges opts into the request`
- **Struct form:**
  - `generate_image(engine, %ImageRequest{operation: :variation, input_images: [img]}) dispatches the struct verbatim — does NOT re-wrap`
  - `generate_image/3 with a manually-built %ImageRequest{operation: :generate, prompt: ""}, where prompt is empty, still dispatches — façade does NOT validate (Decision #13)`
- **Request_id propagation:**
  - `generate_image/3 generates a request_id when opts has none, and forwards it to the adapter via opts[:request_id]`
  - `generate_image(engine, "x", request_id: "caller-supplied") forwards "caller-supplied" verbatim`
  - `Response.request_id is filled from opts[:request_id] when the adapter doesn't populate it`
- **Adapter-error pass-through:**
  - `Adapter returning {:error, %ImageAdapterError{reason: :unknown, metadata: %{cause: :no_scripted_image}}} surfaces verbatim` (FakeImages cursor-exhaustion path)
  - `Adapter returning {:error, %ImageAdapterError{reason: :unsupported_operation, metadata: %{operation: :edit}}} surfaces verbatim`
- **Doctest:** `generate_image/3` doctest with FakeImages.

`test/allm/allm_edit_image_test.exs` (NEW):

- `edit_image(engine, base_img, "make sky pink") builds %ImageRequest{operation: :edit, input_images: [base_img], mask: nil, prompt: "make sky pink"}`
- `edit_image(engine, [base_img, mask_img], "make sky pink") builds %ImageRequest{operation: :edit, input_images: [base_img, mask_img], mask: nil}` (list form — second image is treated as part of input_images, not mask, per spec §35.2.2's "two for inpaint-with-mask" wording — `mask:` keyword is the explicit mask form)
- `edit_image(engine, base_img, "make sky pink", mask: mask_img) builds %ImageRequest{operation: :edit, input_images: [base_img], mask: mask_img}`
- `edit_image/4 with engine.image_adapter == nil returns :no_image_adapter`
- `edit_image/4 forwards opts (n, size, quality, ...) into the request`
- Doctest.

`test/allm/allm_image_variations_test.exs` (NEW):

- `image_variations(engine, img) builds %ImageRequest{operation: :variation, input_images: [img], prompt: nil}`
- `image_variations(engine, img, n: 4) sets n: 4`
- `image_variations/3 with engine.image_adapter == nil returns :no_image_adapter`
- Doctest.

`test/allm/error/engine_error_test.exs` (MODIFY): add a `:no_image_adapter` constructor test mirroring the existing `:missing_adapter` test.

**Cross-function property test (mirror invariant per Decision #6):**

- For arbitrary `(engine, base_img, prompt, opts)` tuples: `edit_image/4 |> Map.from_struct |> Map.delete(:request_id) == ALLM.image_request(prompt, [operation: :edit, input_images: [base_img]] ++ opts) |> Map.from_struct |> Map.delete(:request_id)`. Asserts the sugar produces the same struct as explicit construction.
- Same for `image_variations/3 ≡ image_request("", [operation: :variation, input_images: [img]] ++ opts)` (modulo the prompt — which is nil for variations).

#### 14.2.2 Implementation Checklist

- [ ] Extend `lib/allm/error/engine_error.ex` with `:no_image_adapter` (in `@type reason` AND `@legal_reasons`).
- [ ] In `lib/allm.ex`, add `generate_image/3`:
  - Generates `request_id` via `ALLM.Telemetry.request_id/0` if `opts[:request_id]` is absent
  - Resolves the prompt-string form via `ALLM.image_request/2` then merges with the struct form
  - Returns `{:error, %EngineError{reason: :no_image_adapter}}` when `engine.image_adapter == nil`
  - Threads `opts[:request_id]` to the adapter
  - Calls `engine.image_adapter.generate(request, opts)` and post-processes to fill `response.request_id` if `nil`
- [ ] Add `edit_image/4` per Decision #6's three call shapes.
- [ ] Add `image_variations/3`.
- [ ] `@doc` + `@spec` matching the contract section verbatim. Doctests against `FakeImages`.
- [ ] CHANGELOG entry: `[FEAT] v0.3 Phase 14.2: ALLM.generate_image/3 · edit_image/4 · image_variations/3 + EngineError :no_image_adapter (§35.4, §35.5)`.

#### 14.2.3 Verification

```bash
mix test test/allm/allm_generate_image_test.exs test/allm/allm_edit_image_test.exs test/allm/allm_image_variations_test.exs
mix test test/allm/error/engine_error_test.exs
mix test                              # full suite green
mix credo --strict lib/allm.ex lib/allm/error/engine_error.ex
mix dialyzer
```

---

### Phase 14.3: Telemetry + Capability Pre-flight + Retry — Cross-Cutting

**Goal:** Wrap the bare 14.2 façade with `[:allm, :image, :start | :stop]` telemetry spans, automatic capability pre-flight via `Capability.preflight_image/2`, and retry integration via `ALLM.Retry.run/3`.

**Spec sections:** §35.9 (telemetry), §35.4 (preflight via `supported_operations/0` — the catalog-side check, parallel to v0.2 §6.3), §6.1 (retry).

#### 14.3.1 Test Plan (write first)

`test/allm/telemetry_image_test.exs` (NEW):

- **Span name extension:**
  - `Telemetry.span(:image, %{}, fn -> {:ok, %{}} end) succeeds — proves :image is in @valid_span_names`
  - `Telemetry.span(:image_typo, ...) raises ArgumentError`
- **Event ordering on success:**
  - Use `:telemetry_test.attach_event_handlers/2` (or the existing `test/support/telemetry_capture.ex` helper) to attach to `[:allm, :image, :start]`, `[:allm, :image, :stop]`, then call `generate_image/3` against a FakeImages script that returns 2 images.
  - Assert the `:start` event fires with metadata `%{request_id: <id>, operation: :generate, model: <model>, n: 1, engine: %Engine{}}`.
  - Assert the `:stop` event fires AFTER `:start` with measurements `%{duration: ..., monotonic_time: ..., image_count: 2}` and metadata extending to include `%{usage: %ImageUsage{images: 2}, error: nil, response: %ImageResponse{}}`.
- **Event ordering on validation failure (engine.image_adapter == nil):**
  - The `:start` event still fires (the `:no_image_adapter` check happens INSIDE the span body so observability is uniform — matches chat-side at `lib/allm/runner.ex:95-99`)
  - The `:stop` event fires with `image_count: 0`, `error: %EngineError{reason: :no_image_adapter}`, `response: nil`, `usage: nil`
- **Event ordering on adapter error:**
  - Same as above with `error: {:error_term_from_adapter}`, `image_count: 0`
- **Event ordering on after-retry success (uses `retry_until_call: 2` script + a 1-image follow-up):**
  - The single `[:allm, :image, :start]` and `[:allm, :image, :stop]` span — they wrap the entire retry-loop, NOT each retry attempt
  - `[:allm, :adapter, :retry]` event fires once between attempts (per `ALLM.Retry.run/3`'s telemetry contract at `lib/allm/retry.ex:78-83`)

`test/allm/capability_image_test.exs` (NEW):

- **Catalog absent:**
  - `preflight_image/2 returns :ok when Capability.catalog_loaded?/0 == false` — uses `Application.put_env(:allm, :force_capability_absent, true)` per the existing test seam at `lib/allm/capability.ex:122`
  - The setup uses `on_exit/1` to clear the env var to keep `async: true` safe (verify the env-var-tap pattern across `test/allm/capability_test.exs`)
- **Catalog present, model is bare string:**
  - `preflight_image("openai:gpt-image-1", request) returns :ok` (bare string lacks capability info)
- **Catalog present, model has `images_enabled: false`:**
  - Returns `{:error, %ValidationError{reason: :unsupported_capability, errors: [{[:images_enabled], :images_disabled}]}}`
- **Catalog present, model has `images_enabled: true, supported_image_operations: [:generate]`, request operation is `:edit`:**
  - Returns `{:error, %ValidationError{reason: :unsupported_capability, errors: [{[:operation], :unsupported_image_operation}]}}`
- **Both rules fire (images_enabled: false, operation not supported):**
  - `errors:` list contains BOTH atoms — accumulator semantics matching `preflight/3` at `lib/allm/capability.ex:282-291`
- **JSON-rehydrated string-keyed capabilities:**
  - `capabilities: %{"images_enabled" => false}` (string-key form) produces the same rejection as atom-key form — tolerance pattern from `lib/allm/capability.ex:296-303` extended.
- **Wired into the façade:**
  - `generate_image/3` against a model_ref with `images_enabled: false` returns the `%ValidationError{}` synchronously, no adapter call.
  - The dep-free smoke test (mirrors v0.2 Phase 9.4's pattern): with `force_capability_absent: true`, `generate_image/3` does NOT call into `Capability` — verified by ensuring the test passes even without the test/support/llm_db.ex stub in scope.

`test/allm/retry_image_test.exs` (NEW):

- **Retry-loop happy path:**
  - FakeImages script with `[{:retry_until_call, 2}, {:ok, [%Image{...}]}]` — first call retries, second call returns the image. `generate_image/3` returns `{:ok, response}`.
  - `[:allm, :adapter, :retry]` event fires exactly once with `attempt: 1`.
- **Retry exhausted:**
  - FakeImages script with `[{:retry_until_call, 5}, {:ok, [%Image{...}]}]` and engine.retry: `[max_attempts: 3]` — exhausts the retry budget. `generate_image/3` returns `{:error, %ImageAdapterError{reason: :rate_limited, retry_after_ms: 0}}` (the most recent retry-error struct).
- **Non-retryable error:**
  - FakeImages returns `{:error, %ImageAdapterError{reason: :invalid_request}}` — `:invalid_request` is NOT in the retry-engaging set `[:rate_limited, :provider_unavailable, :timeout, :network_error]`. `generate_image/3` returns it verbatim, NO retry attempt.
- **`:rate_limited` retry with explicit retry_after_ms:**
  - FakeImages script returns `{:error, %ImageAdapterError{reason: :rate_limited, retry_after_ms: 100}}` once, then `{:ok, [...]}`. `generate_image/3` retries (delay≈100ms) and returns the success.

#### 14.3.2 Implementation Checklist

- [ ] In `lib/allm/telemetry.ex`, extend `@valid_span_names` and the `span_name()` typedoc to include `:image`. Update `@moduledoc` to mention `:image` alongside the existing five span names.
- [ ] In `lib/allm/capability.ex`, add `preflight_image/2`:
  - Mirror the structure of `preflight/3` at `lib/allm/capability.ex:174-188`, but 2-arity (no rewrite predicate).
  - Two private helpers: `check_images_enabled/2` and `check_supported_image_operation/2`. Both tolerate string-keyed and atom-keyed `capabilities` per the existing pattern at `lib/allm/capability.ex:296-303`.
  - No rewrite branch (returns `:ok | {:error, _}` only).
  - Add `@doc` with both tolerant-keys doctest examples.
- [ ] In `test/support/llm_db.ex`, extend the `@fixtures` map (currently four entries at lines 18-51) with three new image-capability fixtures:
  - `"openai:gpt-image-1"` → `capabilities: %{tools: %{enabled: false}, json_native: false, images_enabled: true, supported_image_operations: [:generate, :edit]}` plus pricing/limits per the rest of the fixture shape.
  - `"openai:dall-e-3"` → `images_enabled: true, supported_image_operations: [:generate]` (generate-only).
  - `"local:no-images"` → `images_enabled: false, supported_image_operations: []`.
  Required so the 14.3 capability tests can drive `preflight_image/2` rejection paths against committed fixtures rather than building inline `%ModelRef{}` structs.
- [ ] In `lib/allm/providers/fake_images.ex`, extend `generate/2` to recognize the `{:retry_until_call, n}` script entry — return `{:error, %ALLM.Error.ImageAdapterError{reason: :rate_limited, retry_after_ms: 0, message: "FakeImages retry_until_call hint"}}` for the first `n - 1` calls, then advance to the next entry.
- [ ] In `lib/allm.ex`, refactor `generate_image/3` to:
  - Wrap the body in `Telemetry.span(:image, start_metadata, fn -> ... end)` per the chat-side pattern at `lib/allm/runner.ex:95-99`.
  - Compute `start_metadata = %{request_id, engine, model, operation, n}`.
  - Inside the span the `with`-chain runs in this order: **(1) check `engine.image_adapter != nil`** (returning `EngineError{reason: :no_image_adapter}` if nil) → **(2) `Capability.preflight_image/2`** (no-op when catalog absent; returns `{:error, %ValidationError{}}` on rejection) → **(3) `Retry.run/3`-wrapped dispatch** to `engine.image_adapter.generate(request, opts)`. The adapter check fires FIRST so an engine missing both an image adapter AND a tools-disabled model surfaces `:no_image_adapter`, NOT `:unsupported_capability`. Mirrors chat-side `lib/allm/stream_runner.ex` `check_adapter/1` precedence (adapter check is the first gate).
  - The `Retry.run/3` call passes `telemetry_metadata = %{request_id: request_id, model: model, operation: operation}` so `[:allm, :adapter, :retry]` events under the surrounding `:image` span share the same correlation id.
  - Compute `stop_extras = %{image_count, usage, error, response}` from the result.
- [ ] Update `lib/allm/retry.ex` `@moduledoc` with a sentence noting image-side use (no signature change).
- [ ] CHANGELOG entry: `[FEAT] v0.3 Phase 14.3: image telemetry + capability preflight_image + retry integration (§35.9, §6.1)`.

#### 14.3.3 Verification

```bash
mix test test/allm/telemetry_image_test.exs test/allm/capability_image_test.exs test/allm/retry_image_test.exs
mix test                              # full suite green
mix credo --strict lib/allm.ex lib/allm/telemetry.ex lib/allm/capability.ex lib/allm/providers/fake_images.ex
mix dialyzer
```

---

### Phase 14.4: `ALLM.TextPart`, `ALLM.ImagePart`, `Message.content` Widening

**Goal:** Layer A multimodal content parts. v0.2 callers using `String.t()` content are unchanged; the v0.2 raw-`[map(), …]` shape is removed; vision (image inputs) flows through `[TextPart, ImagePart]` content lists.

**Spec sections:** §35.6.

#### 14.4.1 Test Plan (write first)

`test/allm/text_part_test.exs` (NEW):

- `new/2 with text "hi" returns %TextPart{text: "hi", metadata: %{}}`
- `new/2 with text "" returns %TextPart{text: ""}` (empty allowed; validation is upstream)
- `:erlang.term_to_binary/1 round-trip is total`
- `Jason via ALLM.Serializer round-trip is total`
- `metadata: %{key: :value} survives round-trip`
- Doctest.

`test/allm/image_part_test.exs` (NEW):

- `new/2 with image: %Image{...} returns %ImagePart{image: ..., detail: :auto, metadata: %{}}`
- `new/2 with detail: :high returns %ImagePart{detail: :high}`
- `:erlang.term_to_binary/1 round-trip is total`
- `Jason via ALLM.Serializer round-trip is total for every Image source variant + every detail value`
- `Decoded detail atom is restored via to_atom_field/1 against the closed [:auto, :low, :high] set` — verified via parametric round-trip test
- `unknown detail atom in JSON returns {:error, %ValidationError{reason: :invalid_request, errors: [{:_unknown, :atom_decode_failed}]}}` (matches Phase 13's serializer rescue contract)
- Doctest.

`test/allm/message_test.exs` (MODIFY):

- Add: `Message{role: :user, content: [%TextPart{text: "hi"}, %ImagePart{image: img}]} round-trips through ETF and JSON, with deep equality on Image source variants`
- Add: `normalize_content("hi") returns [%TextPart{text: "hi"}]`
- Add: `normalize_content([%TextPart{...}, %ImagePart{...}]) returns the list unchanged`
- Existing v0.2 tests (string content unchanged) MUST continue passing — backward-compat invariant.

`test/allm/serializer/multimodal_message_test.exs` (NEW):

- `Message with content: [%TextPart{text: "x"}] JSON round-trips`
- `Message with content: [%TextPart{}, %ImagePart{image: %Image{source: {:base64, "..."}}}] JSON round-trips`
- `Message with content: [%TextPart{}, %ImagePart{image: %Image{source: {:url, "https://..."}}}] JSON round-trips`
- `ALLM.Serializer.@known_modules contains TextPart and ImagePart` (introspection test)

`test/allm/validate_test.exs` (MODIFY):

- **CONVERT** the seven `:vision_not_in_v0_2`-asserting tests at lines 260-298:
  - "rejects image list part" → "accepts image list part with %ImagePart{}" (test passes a TextPart + ImagePart message and asserts `:ok`)
  - "rejects image_url list part" → REMOVED (no analog — adapters translate ImagePart to provider-specific shapes; image_url is NOT a Layer A concern)
  - "rejects string-keyed image part (JSON-decoded shape)" → REMOVED (untyped maps are no longer accepted; covered by the new `:invalid_part_type` test)
  - Same for the remaining three string-key cases — REMOVED
- **CONVERT** "accepts a list of map content parts (text/tool parts only)" at line 252:
  - REMOVED — raw maps no longer accepted. Replaced by: "accepts a list of TextPart structs" and "accepts a mixed list of TextPart and ImagePart structs"
- **ADD**: `rejects raw map content list element with [{:content, :invalid_part_type}]` — pass `content: [%{type: "text", text: "x"}]` (a raw map) and assert the new error
- **ADD**: `rejects mixed list with one non-Part element with [{:content, :invalid_part_type}]` — pass `content: [%TextPart{text: "x"}, "raw string"]`
- The existing "content that is neither string nor list is invalid" test (line 300) is unchanged — `content: 42` continues to fail with `:invalid_type`.

`test/allm/stream_runner_test.exs` (MODIFY):

- Line 118: `content: [%{type: "image", url: "data:..."}]` → `content: [%ImagePart{image: ALLM.Image.from_url("data:...")}]`. The test's purpose was to assert vision rejection at the StreamRunner level (chat-side); the assertion needs to be re-targeted: in v0.3, the OpenAI/Anthropic chat adapters short-circuit on ImagePart with `:unsupported_feature` per Decision #14, so the new assertion is `{:error, %AdapterError{reason: :unsupported_feature}}` (NOT a `ValidationError`).

`test/allm/response_test.exs` (MODIFY):

- Line 66: `content: [%{type: "text", text: "x"}]` → `content: [%TextPart{text: "x"}]`. Assertion targets are unchanged (the test is about `Response` shape, not about vision).

`test/allm/providers/anthropic_wire_test.exs` (MODIFY):

- Line 413: `content: [%{"type" => "image"}]` → `content: [%ImagePart{image: ALLM.Image.from_url("https://example.com/cat.png")}]`. Assertion target shifts from `:vision_not_in_v0_2` to `%AdapterError{reason: :unsupported_feature}` per Decision #14.
- **ADD** wire-shape regression cases for the `stringify_content/1` extension (Decision #14 part b):
  - `Message{role: :user, content: "hello"}` produces request body `"content": "hello"` — string clause unchanged.
  - `Message{role: :user, content: [%TextPart{text: "hello"}]}` produces request body `"content": "hello"` — single-TextPart materialization.
  - `Message{role: :user, content: [%TextPart{text: "a"}, %TextPart{text: "b"}]}` produces request body `"content": "a\nb"` — multi-TextPart join.
  - `Message{role: :user, content: [%TextPart{text: "x"}, %ImagePart{image: img}]}` returns `{:error, %AdapterError{reason: :unsupported_feature}}` — guard fires before translator.

`test/allm/providers/openai_wire_test.exs` (MODIFY): ADD parallel wire-shape regression cases (the four cases above) for both `to_openai_message/1` (Chat Completions) and `to_responses_input_items/1` (Responses) — each endpoint covered. The OpenAI suite should test the four cases × two endpoints = 8 wire assertions to prove the guard fires regardless of endpoint variant.

`test/allm/error/validation_error_test.exs` (MODIFY):

- Remove the `:vision_not_in_v0_2` constructor test. Assert that `ValidationError.new(:vision_not_in_v0_2, [], ...)` now raises `ArgumentError` (the atom is no longer in `@legal_reasons`).

#### 14.4.2 Implementation Checklist

- [ ] Create `lib/allm/text_part.ex` and `lib/allm/image_part.ex` with `@enforce_keys`, struct, `new/2`, `__from_tagged__/1`, `defimpl Jason.Encoder, do: encode_tagged/2`. Match Phase 13's `Image` pattern for the encoder.
- [ ] Modify `lib/allm/message.ex`:
  - Widen `@type t.content` per the contract section.
  - Add `normalize_content/1` per the contract section.
- [ ] Modify `lib/allm/validate.ex`:
  - Rewrite `validate_content/2` per the contract section.
  - Remove `vision_error/1` and the four `image_part?/1` clauses.
  - Remove the `case vision_error(msg.content) do` short-circuit at `lib/allm/validate.ex:99-117` — replaced by direct accumulator return.
  - Remove the `check_vision_in_messages/2` helper at `lib/allm/validate.ex:374-390`.
  - Update `request/1`, `thread/1`, `session/1` to drop their `with :ok <- check_vision_in_messages(...)` calls (they become straight accumulator chains).
- [ ] Modify `lib/allm/error/validation_error.ex`: remove `:vision_not_in_v0_2` from `@type reason` and `@legal_reasons`. Add `@deprecated`-style note in `@moduledoc` flagging the removal.
- [ ] Modify `lib/allm/serializer.ex`: extend `@known_modules` with `ALLM.TextPart` and `ALLM.ImagePart` (24 total entries).
- [ ] Modify `lib/allm/providers/openai.ex` and `lib/allm/providers/anthropic.ex` per Decision #14 — TWO co-ordinated changes per adapter:
  - **(a) Upstream guard** at the top of `generate/2` AND at the top of `stream/2`: `if request.messages |> Enum.any?(fn m -> is_list(m.content) and Enum.any?(m.content, &match?(%ALLM.ImagePart{}, &1)) end), do: {:error, %ALLM.Error.AdapterError{reason: :unsupported_feature, message: "vision input not yet wired in this adapter; see Phase 16/17"}}`. Fires before either translator runs (OpenAI Chat Completions and Responses both downstream of `generate/2`/`stream/2`).
  - **(b) Materializer extension** to `stringify_content/1` (`lib/allm/providers/openai.ex:1660` and `lib/allm/providers/anthropic.ex:690`): add a clause `defp stringify_content(parts) when is_list(parts), do: parts |> Enum.map(&materialize_part/1) |> Enum.join("\n")` plus a private `defp materialize_part(%ALLM.TextPart{text: t}), do: t`. The upstream guard ensures `%ImagePart{}` never reaches `stringify_content/1`; a bare `materialize_part/1` clause for `ImagePart` is therefore unnecessary, but a catch-all clause `defp materialize_part(other), do: raise ArgumentError, "stringify_content/1 expects a TextPart; got: #{inspect(other)}"` is added as a programmer-error guard for Phase 16/17 wiring. Existing v0.2 callers using `String.t()` content take the binary clause unchanged.
  - Test verification: a v0.2 chat call against `[%ALLM.Message{content: "hello"}]` continues to wire-test green (binary clause); a v0.3 chat call against `[%ALLM.Message{content: [%TextPart{text: "hello"}]}]` produces the same wire body (binary `"hello"`); a v0.3 chat call against `[%ALLM.Message{content: [%TextPart{text: "a"}, %TextPart{text: "b"}]}]` produces `"a\nb"` on the wire.
- [ ] Modify the four test files (`test/allm/validate_test.exs`, `test/allm/stream_runner_test.exs`, `test/allm/response_test.exs`, `test/allm/providers/anthropic_wire_test.exs`, `test/allm/error/validation_error_test.exs`) per the Test Plan.
- [ ] Update `mix.exs` `groups_for_modules: ["Data types": …]` to add `ALLM.TextPart` and `ALLM.ImagePart`.
- [ ] CHANGELOG entry: `[FEAT] v0.3 Phase 14.4: ALLM.TextPart + ALLM.ImagePart + Message.content widening + ValidationError :vision_not_in_v0_2 removed (§35.6, BREAKING for raw-map content callers)`.

#### 14.4.3 Verification

```bash
mix test test/allm/text_part_test.exs test/allm/image_part_test.exs
mix test test/allm/message_test.exs test/allm/validate_test.exs
mix test test/allm/serializer/multimodal_message_test.exs
mix test                              # full v0.2 string-content suite green — backward-compat invariant
mix credo --strict lib/allm/text_part.ex lib/allm/image_part.ex lib/allm/message.ex lib/allm/validate.ex
mix dialyzer
```

The v0.2 backward-compat invariant — every test using `Message{content: "string"}` continues to pass — is the load-bearing assertion.

## Test Plan (cross-phase)

- **Unit tests:** every new public function (`ImageAdapter` callbacks, `FakeImages.generate/2`, `FakeImages.script/1`, `FakeImages.start_script_cursor/0`, `generate_image/3`, `edit_image/4`, `image_variations/3`, `Capability.preflight_image/2`, `TextPart.new/2`, `TextPart.__from_tagged__/1`, `ImagePart.new/2`, `ImagePart.__from_tagged__/1`, `Message.normalize_content/1`) gets at least one happy-path test and one error-/edge-path test.
- **Behaviour conformance tests:** `ALLM.Test.ImageAdapterConformance` is shipped as a published harness AND is exercised by `ALLM.Providers.FakeImages` in the main `:allm` package. The 9-case matrix is the floor; downstream packages may extend.
- **Integration tests:** `generate_image/3 |> Telemetry events |> Capability rejection |> Retry loop` is exercised end-to-end in `test/allm/telemetry_image_test.exs` against `FakeImages` (no real network).
- **Property tests:** at least one StreamData property per sub-phase:
  - 14.1: `forall scripted_response, FakeImages.generate(req, opts) returns a response shape isomorphic to the script entry`
  - 14.2: `forall (img, prompt, opts), edit_image/4 |> Map.from_struct (modulo request_id) == ALLM.image_request(prompt, [operation: :edit, input_images: [img]] ++ opts) |> Map.from_struct`
  - 14.4: `forall (text, image_source), Message{content: [TextPart, ImagePart]} |> term_to_binary |> binary_to_term == itself` and the same for JSON via Serializer
- **Doctests:** every public function has at least one runnable `@doc` example.
- **Serializability tests:** every new Layer A struct (`TextPart`, `ImagePart`) round-trips through both `:erlang.term_to_binary/1` and `ALLM.Serializer`.
- **Stream-equivalence tests:** N/A — image generation is non-streaming per phasing principle #2.
- **Backward-compat tests:** v0.2 chat callers using `Message{content: "string"}` remain green; the v0.2 stream-equivalence properties for chat (`test/allm/chat_equivalence_*`) are NOT extended in this phase (they're chat-only).
- **Cross-option × cross-path test matrix per AGENT_DESIGN_SPEC §3 rule 10:** N/A — image API is a single non-streaming path.

**Coverage threshold:** 80% global per `mix.exs:19`; ≥90% on new code.

**Stream-equivalence relaxation budget.** N/A.

## Error Contract

### Atom additions to `ALLM.Error.EngineError` (sub-phase 14.2)

| Function | Error reason | Recovery guidance |
|----------|--------------|-------------------|
| `generate_image/3`, `edit_image/4`, `image_variations/3` | `:no_image_adapter` | Caller-recoverable. Construct the engine with `image_adapter: SomeImageAdapter`. The engine's chat `:adapter` is independent. |

### Atom additions to `ALLM.Error.ValidationError`

**None** — `:invalid_image_request` was added in Phase 13. `:unsupported_capability` is reused (not a new atom) for the `Capability.preflight_image/2` rejection path.

### Atom removals from `ALLM.Error.ValidationError` (sub-phase 14.4)

| Atom | Recovery guidance |
|------|-------------------|
| `:vision_not_in_v0_2` | Removed. v0.2 callers receiving this atom should migrate to `%ImagePart{}` content parts; the chat adapters return `%AdapterError{reason: :unsupported_feature}` until their respective vision-wiring phases (Phase 16 OpenAI, Phase 17 Anthropic) land. |

### `ALLM.Error.ImageAdapterError` reasons (sub-phase 14.1)

The `ImageAdapter.@callback generate/2` returns `{:error, %ALLM.Error.ImageAdapterError{}}` only — closed type. Caller pattern-matches on `:reason`:

| Reason | HTTP status | Recovery guidance |
|--------|-------------|-------------------|
| `:authentication_failed` | 401 | API key missing or invalid. Surface to user; not retryable. |
| `:rate_limited` | 429 | Provider quota exceeded; `:retry_after_ms` populated when `Retry-After` header present. Engages retry loop. |
| `:invalid_request` | 400 | Request shape rejected (unsupported size, invalid prompt, etc.). Caller-recoverable. |
| `:content_filter` | 400 | Provider safety system rejected the prompt or generated output. Caller-recoverable by rephrasing. |
| `:context_length_exceeded` | 400 | gpt-image-1 textual prompt exceeds the model's context window. Caller-recoverable by shortening. |
| `:provider_unavailable` | 500/502/503/504 | Provider server-side failure. Engages retry loop. |
| `:timeout` | — | Adapter `request_timeout` exceeded. Engages retry loop. |
| `:network_error` | — | TCP/TLS/DNS failure. Engages retry loop. |
| `:malformed_response` | — | 200 with unparseable body. Surface as bug to provider. |
| `:unsupported_feature` | — | Request combined features the adapter cannot express (e.g., `:transparent` background on a model that doesn't support it). |
| `:unsupported_operation` | — | `request.operation not in supported_operations()`; `metadata.operation` carries the rejected atom. Caller-recoverable. |
| `:unknown` | any | Catch-all for shapes the adapter cannot classify; treat as non-retryable. |

The retry loop (Decision in 14.3) engages on `[:rate_limited, :provider_unavailable, :timeout, :network_error]` and uses `:retry_after_ms` when present, otherwise the policy backoff.

### Field-error vocabulary (`ALLM.Capability.preflight_image/2`)

| Field path | Reason atom | Hard-reject? | Fires when |
|------------|-------------|--------------|------------|
| `[:images_enabled]` | `:images_disabled` | no | `model_ref.capabilities.images_enabled == false` |
| `[:operation]` | `:unsupported_image_operation` | no | `request.operation not in model_ref.capabilities.supported_image_operations` |

### Field-error vocabulary additions (`ALLM.Validate.message/1`)

| Field path | Reason atom | Hard-reject? | Fires when |
|------------|-------------|--------------|------------|
| `:content` | `:invalid_part_type` | no | content list contains an element that is not `%ALLM.TextPart{}` or `%ALLM.ImagePart{}` |

### Field-error vocabulary removals (`ALLM.Validate.message/1`)

| Atom | Replacement |
|------|-------------|
| `{:content, :image_part}` | Removed — vision is supported in v0.3. The atom is dead vocabulary; raw-map image parts are now `:invalid_part_type` (caller passed a map instead of `%ImagePart{}`). |

## Streaming & Backpressure

N/A. The image pipeline is request/response only per phasing principle #2 (`steering/RELEASE_0_3_PHASING.md:12`). The §35.9 telemetry events are span-shaped (`:start | :stop` only), not event-stream-shaped.

The chat-side multimodal additions (TextPart/ImagePart) do NOT change the chat-side stream contract. v0.2's `ALLM.Event` closed union is unchanged. Phase 16/17 (vision adapter wiring) will carry assistant-side `ImagePart` outputs through the existing event protocol — that's their concern, not this phase's.

## Definition of Done

- [ ] All four sub-phases (14.1, 14.2, 14.3, 14.4) marked `Completed`
- [ ] `mix test` zero failures, zero `unused_var` warnings, coverage ≥80% globally and ≥90% on new code (verified per phase via `mix test --cover`)
- [ ] `cd conformance && mix test` zero failures (the published-harness self-tests pass for the new `ImageAdapterConformance` module + the `@case_count` meta-test)
- [ ] `mix credo --strict` zero issues on changed files
- [ ] `mix dialyzer` zero new warnings vs the v0.2 PLT
- [ ] `mix format --check-formatted` passes
- [ ] Every new public function has `@spec` and `@doc` with at least one runnable doctest
- [ ] Every new Layer A struct (`TextPart`, `ImagePart`) has serializability round-trip tests for both `:erlang.term_to_binary/1` and JSON via `ALLM.Serializer`
- [ ] `ALLM.Test.ImageAdapterConformance` is shipped under `conformance/lib/allm/test/`; the case_count is 9 and the meta-test asserts that
- [ ] `ALLM.Providers.FakeImages` passes the conformance suite
- [ ] Stream-equivalence tests N/A
- [ ] Spec section references in commit messages cite §35.3, §35.4, §35.5, §35.6, §35.8, §35.9 per phase
- [ ] CHANGELOG.md updated with one entry per sub-phase, plus a BREAKING-CHANGE callout for: (a) removal of `:vision_not_in_v0_2` from `ValidationError.@type reason`, (b) removal of the v0.2 `[map(), …]` content shape acceptance in `Validate.message/1`
- [ ] Reviewed via `/review` per `AGENT_REVIEW_SPEC.md`
- [ ] v0.2 backward-compat invariant: every chat-side test in the v0.2 suite using `Message{content: "string"}` is green
- [ ] Upstream `:llm_db` schema-extension PR is filed against the `:llm_db` Hex package adding `images_enabled` and `supported_image_operations` to the model-capability schema (tracking note for v0.3.0 release polish)
