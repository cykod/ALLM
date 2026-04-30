# Phase 17: Image Layer 7–9 — Vision Input + v0.3.0 Release — Design Document

> **Goal:** Wire `ALLM.ImagePart` content end-to-end through both bundled chat adapters (OpenAI Chat Completions + Responses, Anthropic Messages), then ship v0.3.0 with the multimodal foundation complete.
> **Outcome:** A user can build a `%Message{content: [%TextPart{}, %ImagePart{}]}` and run `ALLM.chat/3` (or stream) against either provider; `ALLM.Chat.run ≡ ALLM.Chat.stream |> reduce` property holds with vision fixtures; `mix.exs` is `0.3.0`; `examples/run_all.exs` passes both arms with vision in scope.
> **Spec sections:** §35.6 (vision content parts), §35.7 (provider matrix — Anthropic chat-vision-only confirmed), §3 (stream-first invariant preserved), §29 (telemetry unchanged), §34 (release process).
> **Layers touched:** B (chat adapters — content-part translators) primarily; D (no session changes; only the integration test surface is exercised); a Layer A footnote in §17.3 trims `:vision_not_in_v0_2` enum if any stragglers remain.

## Status

| Sub-phase | Description | Layer | Status |
|-----------|-------------|-------|--------|
| 17.1 | Vision wiring in `ALLM.Providers.OpenAI` (Chat Completions + Responses translators) | B | Completed |
| 17.2 | Vision wiring in `ALLM.Providers.Anthropic` (Messages API translator) | B | Not Started |
| 17.3 | v0.3.0 release polish — examples, README, CHANGELOG, version bump, hex dry-run | — | Not Started |

**Overall Progress:** 1/3 sub-phases complete

This document covers v0.3 Phases 7, 8, and 9 of `steering/RELEASE_0_3_PHASING.md` as one design (mirroring `PHASE_14_image_layer_2_5.md`'s multi-phase doc convention). Each sub-phase is independently shippable behind its own `mix test` / `mix credo` / `mix dialyzer` gate; bundling reduces design-doc churn for tightly-coupled symmetric work (the OpenAI/Anthropic vision translators share a contract surface and an examples-script seam).

---

## 2. Overview

`ALLM.TextPart` and `ALLM.ImagePart` (Phase 14.4, `lib/allm/text_part.ex`, `lib/allm/image_part.ex`) ship today; the validator (`ALLM.Validate.message/1`, `lib/allm/validate.ex:328-342`) accepts them; `Message.content` is widened to `String.t() | [TextPart.t() | ImagePart.t()]` (`lib/allm/message.ex:31-32`). What's missing is the wire path: both bundled chat adapters currently *reject* `ImagePart` at a `reject_image_parts/1` guard (OpenAI: `lib/allm/providers/openai.ex:1675-1691`; Anthropic: `lib/allm/providers/anthropic.ex:717-733`) added in Phase 14.4 Decision #14(a) precisely so the Layer-A change could ship without leaking half-wired adapters. Phase 17 removes those guards and replaces them with full content-part translators.

The work is symmetric — both adapters translate `[TextPart, ImagePart]` content lists into provider-shaped content blocks, both share the four `ALLM.Image.source` resolution paths (`{:binary, _}`, `{:base64, _}`, `{:url, _}`, `{:file, _}` per `lib/allm/image.ex:47-51`), both honor the `ALLM.Capability.preflight/2` vision-capability gate (added here as a small extension), both extend the existing chat-equivalence property fixtures with one vision case. The asymmetry is in §17.1: OpenAI has TWO endpoint translators (`to_openai_messages/1` at `lib/allm/providers/openai.ex:1616-1641` and `to_responses_input/1` at `:1473-1490`); a content-part translator must wire both, mirror-equivalent, citing both file:line ranges per CLAUDE.md's "OpenAI has TWO endpoint translators" invariant.

### Deliverables

- **§17.1 (Phase 7 of v0.3)** — `lib/allm/providers/openai.ex` extension: replace `reject_image_parts/1` with a content-part translator that flows through both `to_openai_messages/1` (Chat Completions wire shape) and `to_responses_input/1` (Responses API wire shape); MIME validation; recorded wire fixtures × both endpoints × four `Image.source` shapes; live smoke test against `gpt-4o-mini`; `examples/12_vision_input.exs`.
- **§17.2 (Phase 8 of v0.3)** — `lib/allm/providers/anthropic.ex` extension: replace `reject_image_parts/1` with a content-part translator emitting Anthropic's content-block shape with `source: %{type: "base64" | "url", ...}` switching on `ALLM.Image.source`; live smoke test against `claude-haiku-4-5-20251001`; provider-arm extension in `examples/run_all.exs`.
- **§17.3 (Phase 9 of v0.3)** — Three new example scripts (`11_edit_image.exs`, `12_vision_input.exs`, `13_image_variations.exs`); `examples/run_all.exs` wires them with provider gates per `RELEASE_0_3_PHASING.md` Phase 9; `RUN_OUTPUT_OPENAI.md` / `RUN_OUTPUT_ANTHROPIC.md` regenerated; `README.md` adds a "Generating images" section and a "Vision input" section; `mix.exs` `@version "0.2.0"` (`mix.exs:4`) bumps to `"0.3.0"`; `CHANGELOG.md` v0.3.0 rollup; `mix hex.build` dry-run. No `mix hex.publish` in this phase — separate release event.

### Spec Coverage

| § | Where it lands |
|---|----------------|
| §35.6 | Phases 17.1 (OpenAI) and 17.2 (Anthropic); Layer-A part structs already shipped Phase 14.4 |
| §35.7 | Phase 17.2 (no Anthropic image-gen adapter) — confirmed by negative scope; vision-only on the chat side |
| §35.10 | Phase 17.3 (release-polish out-of-scope audit) |
| §3 | Phases 17.1, 17.2 — stream-equivalence property extends with vision fixtures, no streaming-image-preview events introduced |
| §34 | Phase 17.3 (release process) |

### Layer Demonstration

**Layer B (chat adapter consumes ImagePart) — user-facing, no session helpers needed:**

```elixir
img = ALLM.Image.from_file("arch.png")  # `lib/allm/image.ex:97-100`
msg = %ALLM.Message{
  role: :user,
  content: [
    %ALLM.TextPart{text: "What's the failure mode?"},
    %ALLM.ImagePart{image: img, detail: :high}
  ]
}
{:ok, %ALLM.Response{content: text}} = ALLM.generate(engine, ALLM.Request.new([msg]))
```

The same engine + message shape works against OpenAI and Anthropic; the adapter handles wire-shape divergence. No Layer C/D code changes — this is purely a Layer B translator extension.

**Layer C streaming (no new public function — same `stream_generate/3` driving the same StreamCollector):**

```elixir
ALLM.stream_generate(engine, ALLM.Request.new([msg]))
|> Enum.reduce(ALLM.StreamCollector.new(), &ALLM.StreamCollector.apply_event/2)
|> ALLM.StreamCollector.to_response()
```

The user-side ImagePart input flows to the wire in the adapter's request builder; the provider returns text content. `StreamCollector` consumes `:text_delta` / `:text_completed` events (`lib/allm/stream_collector.ex:214,219`) unchanged — there is no per-event-payload branching on input content shape. **Layer-C reducer-touch enumeration:** `StreamCollector.apply_event/2` requires NO new clause for vision *input* (verified by reading every `apply_event/2` clause: none branch on the request side). `Chat.build_request/4` (private, `lib/allm/chat.ex:1697`) is unaffected — the function consumes `Thread.messages` as opaque structs and forwards to the adapter; no opts-key changes for vision.

**Assistant-side image-output decoding** is non-streaming-only (Decision #12 below). The streaming path is *deliberately* asymmetric: the spec §35.6 last sentence ("Assistant responses that contain images (rare today, but supported by some models) deserialize to the same `ALLM.ImagePart` shape") is satisfied by the *non-streaming* JSON response decoder. Streaming-side assistant image-output is **out of scope** for v0.3 and is deferred to v0.4 (see §What Comes After) — adding it requires a new event variant, a `StreamCollector.apply_event/2` clause, and a wider `:text_delta` payload type, which materially exceed Phase 17 scope.

**Prerequisites:** Phases 14.1–14.4 (image data structs + facade + telemetry + content parts) and Phase 15 (OpenAI Images adapter) must be merged. Confirmed at design time:
- `lib/allm/text_part.ex`, `lib/allm/image_part.ex`, `lib/allm/image.ex` all in `main` (commit `f6473ff`)
- `mix.exs:4` is `0.2.0`; CHANGELOG has Phase 13–15 entries through line 218

### Out of Scope

- **Streaming image previews / partial-image events.** §35.10 — not in any v0.3 phase. If a provider exposes them, they ride in `request.options` and surface (if at all) as adapter-specific telemetry, never as new `ALLM.Event` variants.
- **Vision in system messages.** OpenAI and Anthropic *technically* accept content-block lists in system messages, but the practical user story is rare and would force a wider change to `ALLM.Providers.Anthropic.extract_system/1` (`lib/allm/providers/anthropic.ex:615-623`). For v0.3 we keep system messages text-only; ImagePart in a system message yields a typed `AdapterError` pre-flight rejection (see Error Contract). User can lift the image into a user-role message instead.
- **MIME-sniffing of `{:binary, _}` images without an explicit `mime_type`.** `ALLM.Image.from_binary/2` requires `mime_type` (`lib/allm/image.ex:118-120`); `from_file/1` infers from extension. Adapter does NOT sniff bytes. ImagePart with a missing `:mime_type` on a base64/binary source (constructable but unusual) → typed pre-flight rejection.
- **Streaming-side assistant ImagePart output.** Out of scope. Spec §35.6 ("Assistant responses that contain images deserialize to the same `ALLM.ImagePart` shape") is satisfied via the non-streaming response decoder (Decision #12). Adding a streaming path requires (i) a new `ALLM.Event` variant, (ii) a `StreamCollector.apply_event/2` clause, (iii) a wider `:text_delta` payload, and (iv) re-proving stream-equivalence with structured assistant outputs — all material Layer-A + C surface that doesn't fit Phase 17. Deferred to v0.4. Phasing-doc Phase 7's "deserializer is future-proofing" doc note ships in the non-streaming path's `@doc`.
- **Anthropic prompt caching for image content.** Anthropic supports `cache_control` annotations on image blocks. Spec doesn't scope prompt caching for v0.3 (§35.10 inferred); deferred to v0.4.
- **`mix hex.publish`.** §17.3 ships `mix hex.build` dry-run only; the actual publish is a separate release event with a tag + GitHub release notes.

### Non-obvious Decisions

1. **Eager URL-image download is an adapter choice, not a translator concern.** Both providers accept either a public URL or an embedded data URI for image inputs. The translator passes `{:url, _}` source as a URL string (no fetch), and resolves `{:file, _}` / `{:base64, _}` / `{:binary, _}` to a data URI via `ALLM.Image.to_data_uri/1` (`lib/allm/image.ex:227-251`). For Anthropic, URL sources go through Anthropic's `source: {type: "url", ...}` form; non-URL sources go through `source: {type: "base64", ...}`. This preserves the Phase 13 principle "no eager fetches in constructors" — adapter resolves at request-build time, not at message-construction time.
   - **Why no size-validation for URL sources:** Validating ≤20 MB by `byte_size/1` would force a `Req` GET in the adapter; that's a network call inside an adapter pre-flight. Defer the size check to the provider's API-side validation; CHANGELOG-flag the trade-off.
   - **Docs target:** `@doc ALLM.Providers.OpenAI.generate/2`, `@doc ALLM.Providers.Anthropic.generate/2`.

2. **MIME and size validation for non-URL sources happens at the adapter boundary, not in `ALLM.Validate`.** Provider MIME accept-sets diverge (OpenAI: `image/png`, `image/jpeg`, `image/webp`, `image/gif`; Anthropic: same four). The translator validates MIME via a shared `ALLM.Providers.Support.ImageMime.validate/2` helper (NEW — `lib/allm/providers/support/image_mime.ex`) called from each adapter's pre-flight; the helper takes a per-provider accept-set so future adapters reuse it. Size validation is `byte_size/1` after `to_binary/1` resolution; ≤20 MB per image. URL-source images skip size validation per Decision #1.
   - **Docs target:** `@moduledoc ALLM.Providers.Support.ImageMime`.

3. **`ImagePart.detail` is dropped at the Anthropic boundary, with a one-time `Logger.debug/1` per process.** Anthropic has no `detail` field. A silent drop violates user expectations; a per-call warning is noisy. The compromise: a `Process.put/2`-gated debug log that fires once per process. **Detection mechanism (rule 17):** `Process.get(:allm_anthropic_detail_warned, false)` guard before the log; set after first emit. Process-local because adapter calls in distinct request flows want independent visibility, but within one flow we don't repeat.
   - **Why `Logger.debug/1` not `Logger.warning/1`:** debug matches CLAUDE.md's "deferred form for hot-path Logger" rule; warning would need an opt-in.
   - **Docs target:** `@doc ALLM.Providers.Anthropic.generate/2` includes a `> ## Note` block on detail-field behaviour; CHANGELOG entry flags the silent-drop semantics.

4. **The `:vision_not_in_v0_2` and any analogous `:vision` placeholder atoms are already removed from `ValidationError.@type reason` (Phase 14.4 — verified at `lib/allm/error/validation_error.ex:30-58`).** No further enum surgery needed in §17.1 / §17.2. The new error path uses an *existing* atom (`:unsupported_feature` on `AdapterError`, or `:invalid_message` with a per-field error tuple on `ValidationError`).
   - **Docs target:** internal — no user-facing docs needed.

5. **Vision capability pre-flight extends `ALLM.Capability.preflight/2` with a `:vision` capability check, gated on `llm_db`.** When the resolved model has `capabilities.vision == false` and the request contains any `ImagePart`, return `{:error, %ValidationError{reason: :unsupported_capability, errors: [{[:vision], :vision_disabled}]}}`. When `llm_db` is absent or the model record doesn't list `:vision`, no-op (matches existing `:tools`, `:response_format` gating semantics at `lib/allm/capability.ex`). Adds two atoms to the closed vocabulary: `:vision` (capability key) and `:vision_disabled` (rejection reason). Both are scoped extensions under §35.6.
   - **Why a capability gate at all:** today's gpt-3.5-turbo, claude-3-opus-vision-disabled, and similar non-vision models silently 400 on image content. A pre-flight catches that without a network round-trip, matching `:tools_disabled` / `:json_native_required` precedent.
   - **Docs target:** `@doc ALLM.Capability.preflight/2` extends with the `:vision` row; CHANGELOG entry flags the vocabulary extension.

6. **Extending `ValidationError.@type reason` enumeration is NOT required.** Decision #5 reuses `:unsupported_capability`; per-field tuples carry the granular `:vision_disabled` reason. The closed enum at `lib/allm/error/validation_error.ex:30-58` does NOT grow in this phase. Pre-design audit: `grep -nE ':vision|:image_too_large|:unsupported_image_format' lib/allm/error/` returns no matches; the existing `:unsupported_capability` covers vision; `:invalid_message` with `{[:content, idx], :unsupported_image_format | :image_too_large | :missing_mime_type}` covers per-image-part wire-validation failures.
   - **Docs target:** internal — design-time confirmation only.

7. **Pre-flight order is layered across the runner and the adapter** (corrected 2026-04-30 per Phase 17.1 retro Finding 1): the runner-level step `(2) capability_preflight (vision gate)` runs in `ALLM.StreamRunner.do_run/3` at `lib/allm/stream_runner.ex:122` against the resolved `%ModelRef{}`; the adapter-internal steps `(1) reject_image_in_system_messages → (3) per-part MIME/size validation → (4) translate → (5) HTTP` run in `OpenAI.generate/2` / `OpenAI.stream/2` at `lib/allm/providers/openai.ex:518-522,803-807`. The adapter does NOT (and cannot, per architecture) re-run capability gating: `Request.model` is a `String.t()` at the adapter boundary, and `Capability.preflight/3` is a no-op for string models (`lib/allm/capability.ex:188-189`). Direct `ALLM.Providers.OpenAI.generate/2` calls bypass capability gating by design — callers wanting it go through `ALLM.generate/3`. Each step's failure is typed `ValidationError` (per Q1 lock-in below; mirrors the existing `:tools_disabled` / `:json_native_disabled` precedent at `lib/allm/capability.ex:359-386`). The adapter-internal order `(1) → (3)` is asserted by `test/allm/providers/openai_vision_test.exs:483-511`. The runner-level `(2) → adapter` composition is exercised by `test/allm/capability_vision_test.exs` (8 tests against `Capability.preflight/3` directly) but a facade-level `(2) → (1) → (3)` end-to-end test does NOT exist in 17.1; deferred to a future fix-step.
   - **Q1 lock-in:** system-message-image rejection returns `%ValidationError{reason: :invalid_message, errors: [{[:messages, idx, :content], :image_in_system_message}]}`, NOT `%AdapterError`. Hard-reject (short-circuits remaining content checks). One field-level atom added (`:image_in_system_message`); no top-level `@type reason` change.
   - **Q2 lock-in:** `ImagePart.detail` is always emitted on the wire as `Atom.to_string(detail)` — no omission of `:auto`. Idempotent against server defaults; explicit emission simplifies debugging and round-trip.
   - **Q3 lock-in:** per-part vision validation lives in `ALLM.Providers.Support.ImageMime.validate_request/2`, not duplicated per adapter. See §3.1.
   - **Docs target:** internal — Test Plan asserts the order.

8. **One bundled `_helpers.exs` constant grows: `vision_default_model`.** `examples/_helpers.exs` (`@providers` map at lines 1–146) gains a `:vision_default_model` field per row: `"gpt-4o-mini"` for openai, `"claude-haiku-4-5-20251001"` for anthropic. `engine/1` reads it under a new `vision: true` opt; default `engine/1` behaviour unchanged. Provider-arm runtimes for vision examples use this. CLAUDE.md "every bundled provider adapter ships with an examples entry" satisfied.
   - **Docs target:** `examples/_helpers.exs` `@moduledoc`; `examples/README.md`.

9. **`examples/run_all.exs` provider-arm gating mirrors Phase 15.6's pattern.** Per `RELEASE_0_3_PHASING.md` Phase 9 line 151: OpenAI arm runs `12_vision_input.exs` AND `11_edit_image.exs` AND `13_image_variations.exs`; Anthropic arm runs `12_vision_input.exs` only (no image-gen on Anthropic per §35.7). Each new script gets a `# Provider: openai[, anthropic]` header marker (run_all.exs scanner at `examples/run_all.exs:37`).
   - **Docs target:** `examples/README.md`.

10. **Live-API cost (rule 19):**
    - **§17.1 OpenAI vision smoke** — `gpt-4o-mini` against a small (~50 KB) test PNG; per-call ~250 input tokens + ~50 image tokens + ~50 output tokens; @ $0.15/$0.60 per M tokens → ~$0.0001/run + image-token overhead → ~$0.001/clean-run. First-implementation cost ~3× → ~$0.003.
    - **§17.2 Anthropic vision smoke** — `claude-haiku-4-5-20251001` similar; ~$0.001-0.002/clean-run; ~$0.005 first-implementation.
    - **§17.3 examples/run_all.exs full run** — both arms; openai arm includes `10_generate_image.exs` (dall-e-2, ~$0.018) + `11_edit_image.exs` (gpt-image-1 inpaint, ~$0.04) + `13_image_variations.exs` (dall-e-2, ~$0.018) + `12_vision_input.exs` (~$0.001) → ~$0.08/openai-arm; anthropic arm chat-only-with-vision → ~$0.01. Total ~$0.09/clean-run, ~$0.27 first-implementation. Budget consistent with PHASE_15's ~$0.05–0.20/run estimate.
    - **Docs target:** `examples/README.md` "Cost notes" subsection.

11. **Assistant-side ImagePart decoding is non-streaming-only.** The OpenAI response decoder (in `lib/allm/providers/openai.ex` — the `decode_*` helpers that build `%Response{message: %Message{content: ...}}` from the JSON body) gains a clause: when `choices[0].message.content` is a list of structured blocks, decode `{type: "text", text}` → `%TextPart{}` and `{type: "image_url", ...}` / `{type: "output_image", ...}` → `%ImagePart{}`. Synthesized fixture (Module Tree under `synthesized/vision_assistant_image_output.exs`) exercises this path. **Stream-equivalence consequences:** the chat-equivalence and stream-equivalence properties' new vision fixtures cover ONLY user-side ImagePart input — the assistant returns text in those scripts (no list-shaped `current_text` / `Response.message.content` mismatch between arms). A separate non-streaming-only test asserts the decoder; that test does NOT have a streaming counterpart by design.
    - **Why non-streaming-only:** matches phasing-doc Phase 7's "no current model emits this in our test matrix; deserializer is future-proofing" hedge. Adding streaming-side decoding crosses three scope boundaries (Layer A new event variant, Layer C reducer clause, Layer A `Response`-shape implications); v0.4 picks them up if a real model ships.
    - **Docs target:** `@doc ALLM.Providers.OpenAI.generate/2` includes a `> ## Note` block on the asymmetry; `@moduledoc ALLM.Providers.OpenAI` mentions the gap.

12. **Stream-equivalence relaxation budget (cross-phase).**

    | Relaxation | Justification | Risk |
    |------------|---------------|------|
    | None added | Vision changes only the wire shape of message *content*; all event-emission paths and StreamCollector folds are byte-identical with vs. without `ImagePart`. The chat-equivalence property at `test/allm/chat_equivalence_test.exs` runs *unchanged* with one new fixture row containing an ImagePart; both arms produce the same `%ChatResult{}`. | Tolerable — verified empirically by reading `StreamCollector.apply_event/2`'s `:content_delta`/`:message_completed` clauses (no per-part-type branching) and the adapter chunk-handlers (no `ImagePart`-conditional emission). |

    No `masking-divergence` rows. If implementation surfaces one, that's a contract bug, not a relaxation — surface as a finding/fix in the same sub-phase per AGENT_DESIGN_SPEC.md §6.

---

## 3. Behaviour & Type Contracts

### 3.1 New: `ALLM.Providers.Support.ImageMime` (Layer B helper)

```elixir
defmodule ALLM.Providers.Support.ImageMime do
  @moduledoc """
  Per-provider MIME and size validation for `ALLM.ImagePart` content.
  Used by `ALLM.Providers.OpenAI` and `ALLM.Providers.Anthropic` vision pre-flight.
  See §35.6.
  """

  @type validate_result ::
          :ok
          | {:error,
             {:unsupported_image_format, mime :: String.t() | nil}
             | {:image_too_large, byte_size :: non_neg_integer()}
             | :missing_mime_type
             | :remote_source}

  @max_bytes 20 * 1024 * 1024  # 20 MB — both OpenAI and Anthropic published limit

  @spec validate(ALLM.ImagePart.t(), accept_mimes :: [String.t()]) :: validate_result()
  def validate(%ALLM.ImagePart{image: image}, accept_mimes) when is_list(accept_mimes)

  @spec accept_mimes(provider :: :openai | :anthropic) :: [String.t()]
  def accept_mimes(:openai), do: ~w(image/png image/jpeg image/webp image/gif)
  def accept_mimes(:anthropic), do: ~w(image/png image/jpeg image/webp image/gif)

  @doc """
  Single source of truth for the request-level vision pre-flight: walks
  every ImagePart in `request.messages`, calls `validate/2`, accumulates
  `{[:content, msg_idx, part_idx], reason}` tuples. Returns
  `{:error, %ValidationError{reason: :invalid_message, errors: [...]}}`
  if any part fails, else `:ok`.

  Adapters call this once in pre-flight; per-provider divergence is
  isolated to `accept_mimes/1`.
  """
  @spec validate_request(ALLM.Request.t(), provider :: :openai | :anthropic) ::
          :ok | {:error, ALLM.Error.ValidationError.t()}
  def validate_request(%ALLM.Request{messages: messages}, provider)
      when provider in [:openai, :anthropic]
end
```

**Q3 design lock-in:** the per-image-part fold lives in `ALLM.Providers.Support.ImageMime.validate_request/2` (lifted from per-adapter helpers per AGENT_DESIGN_SPEC.md "consumer/producer symmetry for filter keys" rule §6.B.4). Adapters call `ImageMime.validate_request(request, :openai)` / `(request, :anthropic)`; provider-specific divergence is *only* the accept-set returned by `accept_mimes/1`. The field-error vocabulary atoms (`:unsupported_image_format`, `:image_too_large`, `:missing_mime_type`) are defined here once, not duplicated in each adapter's tests.

**Invariants:**
- `validate/2` skips `byte_size` check when `image.source` is `{:url, _}` (returns `:ok` if MIME is acceptable per the URL's extension or `nil`-MIME passes through to provider; `:remote_source` is *not* an error here — it means "size unverifiable, defer to provider").
- For `{:binary, _}` and `{:base64, _}` and `{:file, _}`, resolve via `ALLM.Image.to_binary/1` then `byte_size/1`.
- Missing `:mime_type` on a non-URL source → `{:error, :missing_mime_type}` (the wire shape requires a media_type).
- Identical accept-set today (both providers); helper preserves per-provider divergence room.

**Test-observable verifications:** `byte_size/1` on a binary produced via `Base.decode64!/1` returns the post-decode count (verified in IEx on 2026-04-29: `byte_size(Base.decode64!(Base.encode64(<<1,2,3>>))) == 3`). `Image.to_binary/1` on `{:url, _}` returns `{:error, :remote_source}` (cited at `lib/allm/image.ex:188-201`).

### 3.2 OpenAI content-part translator (extension to `lib/allm/providers/openai.ex`)

```elixir
# Public translation surface — both endpoints flow through this.
@spec to_openai_content_blocks(ALLM.Message.content(), endpoint :: :chat_completions | :responses) ::
        binary() | [map()]

# Endpoint-specific block shape:
# Chat Completions:  TextPart  → %{"type" => "text",      "text" => t}
#                    ImagePart → %{"type" => "image_url", "image_url" => %{"url" => uri, "detail" => detail_str}}
# Responses:         TextPart  → %{"type" => "input_text",  "text" => t}
#                    ImagePart → %{"type" => "input_image", "image_url" => uri, "detail" => detail_str}
```

**Mirror invariant (rule 6a):** `to_openai_messages/1` (`lib/allm/providers/openai.ex:1616-1641` — Chat Completions) and `to_responses_input/1` (`:1473-1490` — Responses API) BOTH route message content through `to_openai_content_blocks/2` with the right endpoint atom. The implementer's checklist enumerates both call-sites; CI fails (via a Credo custom check or a unit test asserting the translator-call exists in both sites) if either is missed.

**URL fast-path dispatch.** `Image.to_data_uri/1` returns `{:error, :remote_source}` for `{:url, _}` sources (`lib/allm/image.ex:227-251`); the translator MUST short-circuit URL sources before calling it. Reference shape:

```elixir
defp image_part_to_block(%ImagePart{image: %Image{source: {:url, u}}, detail: d}, :chat_completions),
  do: %{"type" => "image_url",
        "image_url" => %{"url" => u, "detail" => Atom.to_string(d)}}

defp image_part_to_block(%ImagePart{image: img, detail: d}, :chat_completions) do
  {:ok, uri} = Image.to_data_uri(img)  # never :remote_source — URL clause matched above
  %{"type" => "image_url", "image_url" => %{"url" => uri, "detail" => Atom.to_string(d)}}
end

defp image_part_to_block(%ImagePart{image: %Image{source: {:url, u}}, detail: d}, :responses),
  do: %{"type" => "input_image", "image_url" => u, "detail" => Atom.to_string(d)}

defp image_part_to_block(%ImagePart{image: img, detail: d}, :responses) do
  {:ok, uri} = Image.to_data_uri(img)
  %{"type" => "input_image", "image_url" => uri, "detail" => Atom.to_string(d)}
end
```

**Cross-function invariant:** The mapping table for the closed `ImagePart.detail :: :auto | :low | :high` set:

| `detail` atom | Wire string |
|---------------|-------------|
| `:auto` | `"auto"` |
| `:low` | `"low"` |
| `:high` | `"high"` |

Implemented as `Atom.to_string/1` since the union is closed and atoms match wire literals. (Sanity-check verified against OpenAI's documented enum on 2026-04-29.)

**Removed contract:** `reject_image_parts/1` at `lib/allm/providers/openai.ex:1675-1691` is deleted in §17.1. The `ArgumentError` catch-all in `stringify_content/1` at `:1666-1669` is also removed; the function is replaced (see Module Tree). 

**Pre-flight order** (Decision #7, corrected 2026-04-30 per 17.1 retro Finding 1):

- **Runner-level** (`ALLM.StreamRunner.do_run/3` at `lib/allm/stream_runner.ex:122`, runs against the resolved `%ModelRef{}` BEFORE adapter dispatch):
  2. `ALLM.Capability.preflight/3` — vision gate per Decision #5; no-op when `Request.model` is a string or the catalog isn't loaded.

- **Adapter-internal** (`generate/2` at `lib/allm/providers/openai.ex:518-522` and `stream/2` at `:803-807`, runs after dispatch):
  1. `reject_image_in_system_messages/1` (NEW helper)
  3. `ALLM.Providers.Support.ImageMime.validate_request(request, :openai)` — lifted helper (Q3); adapter does NOT carry its own `validate_image_parts/1`
  4. `to_openai_content_blocks/2` (translation; pure function, infallible)
  5. HTTP

The adapter does NOT call `Capability.preflight/3` because `Request.model` is `String.t()` at the adapter boundary and `preflight/3` short-circuits to `:ok` for string models (`lib/allm/capability.ex:188-189`). Direct adapter calls bypass capability gating by design.

### 3.3 Anthropic content-part translator (extension to `lib/allm/providers/anthropic.ex`)

```elixir
@spec to_anthropic_content_blocks(ALLM.Message.content()) :: binary() | [map()]

# TextPart  → %{"type" => "text", "text" => t}
# ImagePart with {:url, _}     → %{"type" => "image", "source" => %{"type" => "url",    "url" => u}}
# ImagePart with {:binary, b}, mime → %{"type" => "image", "source" => %{"type" => "base64", "media_type" => mime, "data" => Base.encode64(b)}}
# ImagePart with {:base64, s}, mime → %{"type" => "image", "source" => %{"type" => "base64", "media_type" => mime, "data" => s}}
# ImagePart with {:file, path}, mime → resolve via Image.to_binary/1 → encode64 → base64 source shape
```

**URL fast-path dispatch (Anthropic).** `Image.to_binary/1` returns `{:error, :remote_source}` for `{:url, _}` (`lib/allm/image.ex:188-201`); URL sources route to Anthropic's `source: {type: "url", ...}` shape and never call `to_binary/1`:

```elixir
defp image_part_to_block(%ImagePart{image: %Image{source: {:url, u}}}) do
  %{"type" => "image", "source" => %{"type" => "url", "url" => u}}
end

defp image_part_to_block(%ImagePart{image: %Image{source: {:base64, s}, mime_type: mime}}) do
  %{"type" => "image", "source" => %{"type" => "base64", "media_type" => mime, "data" => s}}
end

defp image_part_to_block(%ImagePart{image: %Image{mime_type: mime} = img}) do
  {:ok, bytes} = Image.to_binary(img)  # :url path matched above; remaining sources resolve cleanly
  %{"type" => "image", "source" => %{"type" => "base64", "media_type" => mime, "data" => Base.encode64(bytes)}}
end
```

**Cross-function invariant:** Anthropic's `system` parameter (built by `extract_system/1` at `lib/allm/providers/anthropic.ex:615-623`) is unchanged. System messages remain text-only by Decision #7 (out-of-scope item). Confirmed integration: `to_anthropic_request_body/1` at `lib/allm/providers/anthropic.ex:536-560` calls `extract_system/1` THEN `to_anthropic_messages/1`; only the latter absorbs the new translator. Implementation walks: `to_anthropic_messages/1` (`:641-693`) → per-message `to_anthropic_message/1` clause for `:user` and `:assistant` → existing `stringify_content/1` (`:695-711`) is REPLACED with `to_anthropic_content_blocks/1` for list-shape content; binary-string content keeps the verbatim path.

**Removed contract:** `reject_image_parts/1` at `lib/allm/providers/anthropic.ex:717-733` is deleted. `stringify_content/1`'s ImagePart raise at `:708-711` is removed (function reused for system messages only via `extract_system/1`; system+ImagePart is rejected at the new `reject_image_in_system_messages/1` pre-flight).

**`detail` field handling** (Decision #3): `ImagePart.detail` is read but not emitted; a one-time `Logger.debug/1` fires (deferred form per CLAUDE.md hot-path rule):

```elixir
defp warn_detail_dropped_once do
  if !Process.get(:allm_anthropic_detail_warned, false) do
    Logger.debug(fn ->
      "ALLM.Providers.Anthropic: ImagePart.detail is not supported by Anthropic; dropping. " <>
      "This warning fires once per process."
    end)
    Process.put(:allm_anthropic_detail_warned, true)
  end
end
```

Tested with `:capture_log` ensuring exactly one debug emission across two ImagePart-bearing calls in the same process; assertions on `Process.get/2` state.

**Cross-adapter divergence note (added 2026-04-30 per Phase 17.2 retro Finding 3):** the assistant + `tool_calls` + `ImagePart` trinary case is handled differently across the two bundled adapters. Anthropic text-flattens the content list via `stringify_content/1` → `materialize_part(%ImagePart{}) -> ""` (image silently dropped to empty string), then emits `tool_use` blocks alongside the text block; see `lib/allm/providers/anthropic.ex:711-731`. OpenAI, by contrast, routes the same content through the full content-block translator and emits image blocks alongside `tool_calls` (`lib/allm/providers/openai.ex:1670` via `assistant_content/2`). The divergence is deliberate for v0.3 — a model echoing back its own multimodal turn while also requesting a tool is genuinely rare, and Anthropic's Messages API may not accept image blocks alongside `tool_use` blocks in an assistant message. v0.4 may canonize one shape across both adapters; until then the inline comment at `lib/allm/providers/anthropic.ex:711-720` cites this note.

### 3.4 Capability extension (`lib/allm/capability.ex`)

```elixir
# New rule appended after :tools_disabled / :json_native_required:
# When request.messages contains any ImagePart and resolved_model.capabilities.vision == false,
# return per-field {[:vision], :vision_disabled} accumulating with other failures.

# Catalog schema additions (tolerated in both atom-keyed and string-keyed shapes,
# per existing pattern at lib/allm/capability.ex:295-318):
#   capabilities.vision :: boolean()
```

**Test-observable:** capability check fires on `ImageRequest`-less chat calls only when content contains `ImagePart`. A request with no images against a vision-disabled model → no rejection, no-op. Verified by reading the gating predicate; tested.

### 3.5 Module Tree

```
lib/allm/
├── providers/
│   ├── openai.ex                                  (MODIFY — 17.1: add to_openai_content_blocks/2,
│   │                                                          rewrite to_openai_messages/1's content
│   │                                                          dispatch, rewrite to_responses_input/1's
│   │                                                          content dispatch, remove reject_image_parts/1
│   │                                                          and stringify_content/1's catch-all,
│   │                                                          add reject_image_in_system_messages/1;
│   │                                                          per-part vision validation lifted to
│   │                                                          ALLM.Providers.Support.ImageMime.validate_request/2)
│   ├── anthropic.ex                               (MODIFY — 17.2: add to_anthropic_content_blocks/1,
│   │                                                          rewrite to_anthropic_messages/1's content
│   │                                                          dispatch, remove reject_image_parts/1,
│   │                                                          remove stringify_content/1 ImagePart raise,
│   │                                                          add reject_image_in_system_messages/1,
│   │                                                          add warn_detail_dropped_once/0;
│   │                                                          per-part vision validation reuses
│   │                                                          ALLM.Providers.Support.ImageMime.validate_request/2)
│   └── support/
│       └── image_mime.ex                          (NEW — 17.1: shared MIME/size validator)
├── capability.ex                                  (MODIFY — 17.1: vision capability gate;
│                                                              extend dual-keyed capability accessor)
└── mix.exs                                        (MODIFY — 17.3: @version 0.2.0 → 0.3.0)

test/allm/providers/
├── openai_vision_test.exs                         (NEW — 17.1: content-block translator unit tests
│                                                              + Chat Completions wire fixtures
│                                                              + Responses API wire fixtures
│                                                              + MIME/size pre-flight tests
│                                                              + system-msg ImagePart rejection
│                                                              + assistant ImagePart-output decoder)
├── anthropic_vision_test.exs                      (NEW — 17.2: content-block translator unit tests
│                                                              + Messages API wire fixtures
│                                                              + URL vs base64 source dispatch
│                                                              + detail-drop debug log assertion
│                                                              + system-msg ImagePart rejection)
└── support/
    └── image_mime_test.exs                        (NEW — 17.1: ImageMime helper unit tests)

test/allm/
├── chat_equivalence_test.exs                      (MODIFY — 17.1+17.2: add 1 vision fixture row)
├── stream_equivalence_test.exs                    (MODIFY — 17.1+17.2: vision script in §31 vocabulary)
└── capability_vision_test.exs                     (NEW — 17.1: vision-gate per-rule pre-flight tests)

test/fixtures/                                    (corrected 2026-04-30 per 17.1 retro Findings 2+4:
                                                    wire fixtures are .json (project convention via
                                                    Jason.decode!/1 in OpenAITestFixtures /
                                                    AnthropicTestFixtures); synthesized fixtures live at
                                                    test/fixtures/<provider>/synthesized/, NOT
                                                    test/fixtures/<provider>/<endpoint>/synthesized/)
├── openai/chat_completions/vision/                (NEW — 17.1: 4 source-shape fixtures × happy-path)
│   ├── single_image_url.json
│   ├── single_image_base64.json
│   ├── single_image_binary.json
│   ├── multi_image.json
│   └── unsupported_format.json
├── openai/responses/vision/                       (NEW — 17.1: same 4 source-shapes against Responses API)
│   ├── single_image_url.json
│   ├── single_image_base64.json
│   ├── single_image_binary.json
│   └── multi_image.json
├── openai/synthesized/
│   └── vision_assistant_image_output.json         (NEW — 17.1: synthesized assistant→ImagePart decoder)
└── anthropic/messages/vision/                     (NEW — 17.2: 4 source-shape fixtures;
                                                    synthesized-pre-record per 17.1 retro
                                                    Finding 6 convention. Each carries
                                                    `_comment: "Synthesized…"`; live recorder at
                                                    scripts/record_anthropic_vision_fixtures.exs
                                                    overwrites in-place — `_comment` is stripped
                                                    on re-record. Loader: AnthropicTestFixtures.messages_vision/1.)
    ├── single_image_url.json
    ├── single_image_base64.json
    ├── single_image_binary.json
    └── multi_image.json

examples/
├── 11_edit_image.exs                              (NEW — 17.3: gpt-image-1 inpaint with mask)
├── 12_vision_input.exs                            (NEW — 17.1+17.2: multi-provider vision script)
├── 13_image_variations.exs                        (NEW — 17.3: dall-e-2-only variations)
├── _helpers.exs                                   (MODIFY — 17.3: add :vision_default_model;
│                                                              add `vision: true` opt to engine/1)
├── run_all.exs                                    (MODIFY — 17.3: register new scripts)
├── README.md                                      (MODIFY — 17.3: vision examples + cost notes)
├── RUN_OUTPUT_OPENAI.md                           (MODIFY — 17.3: regenerate snapshot)
└── RUN_OUTPUT_ANTHROPIC.md                        (MODIFY — 17.3: regenerate snapshot)

scripts/
├── record_openai_vision_fixtures.exs              (NEW — 17.1: live-record happy-path
│                                                          fixtures across 4 source-shapes
│                                                          × 2 endpoints; idempotent per script run)
└── record_anthropic_vision_fixtures.exs           (NEW — 17.2: same, against Messages API)

CHANGELOG.md                                       (MODIFY — 17.1+17.2+17.3: per-phase entries)
README.md                                          (MODIFY — 17.3: Generating images +
                                                              Vision input sections)
mix.exs                                            (MODIFY — 17.3: @version bump)
```

**Module Tree completeness invariant (AGENT_DESIGN_SPEC.md §4):** every diff file is enumerated above with rationale. The `git diff --stat <pre>..<post>` count for §17.1 will be ~7 lib/test/fixture files; for §17.2, ~6; for §17.3, ~9 (CHANGELOG + README + mix.exs + 3 example scripts + 2 RUN_OUTPUT + _helpers/run_all). No "discovered new file mid-phase" surprises expected — the only candidate would be an extension to `lib/allm/error/adapter_error.ex`, which is NOT needed because `:unsupported_feature` is already in its enum (verified at design time).

### 3.6 Wire-field map (rule 15)

| Concern | OpenAI Chat Completions | OpenAI Responses | Anthropic Messages |
|---------|-------------------------|------------------|--------------------|
| **Text content block** | `{type: "text", text: ...}` | `{type: "input_text", text: ...}` | `{type: "text", text: ...}` |
| **Image content block (data URI / base64 / binary)** | `{type: "image_url", image_url: {url: "data:<mime>;base64,...", detail: ...}}` | `{type: "input_image", image_url: "data:<mime>;base64,...", detail: ...}` | `{type: "image", source: {type: "base64", media_type: ..., data: ...}}` |
| **Image content block (URL)** | `{type: "image_url", image_url: {url: "https://...", detail: ...}}` | `{type: "input_image", image_url: "https://...", detail: ...}` | `{type: "image", source: {type: "url", url: "https://..."}}` |
| **Detail field** | inside `image_url` map (`"auto"` \| `"low"` \| `"high"`) | sibling key (`detail: "auto"`) | not supported (dropped + debug log) |
| **System message** | top-level `messages: [{role: "system", content}]` | `instructions:` field | top-level `system:` parameter |
| **Assistant image output** | within `choices[0].message.content` if list-shaped (rare) | `output[].content[]` items with `type: "output_image"` (synthesized fixture; current models don't emit) | not in scope (no Anthropic image output) |
| **MIME accept-set** | `image/png image/jpeg image/webp image/gif` | same | same |
| **Size limit** | 20 MB per image | same | same (per Anthropic docs 2025) |
| **Stop reason on content filter** | `finish_reason: "content_filter"` (unchanged) | `output[].finish_reason` (unchanged) | `stop_reason: "refusal"` (unchanged) |

Each row's wire fact verified at design time against provider docs on **2026-04-29** (OpenAI: Chat Completions vision API + Responses API content-block reference; Anthropic: Messages API image content blocks, including the URL-source addition documented mid-2025). Implementer MUST re-check before recording fixtures — providers change docs without notice. The `detail`-field placement asymmetry (nested in Chat Completions' `image_url` map vs sibling key in Responses) is the most fragile cell and should be confirmed first.

### 3.7 Synthesized vs recorded wire-fixture policy (rule 16)

| Fixture class | Storage | Kind | Asserts |
|---------------|---------|------|---------|
| **Response-shape: happy-path vision** (single image, multi-image) | `test/fixtures/openai/chat_completions/vision/`, `test/fixtures/openai/responses/vision/`, `test/fixtures/anthropic/messages/vision/` | **recorded** via live capture (one-time, scripts under `scripts/record_*_fixtures.exs`) | Decode correctness; provider response shape preserved across replays |
| **Response-shape: assistant-emits-image** | `test/fixtures/openai/chat_completions/synthesized/vision_assistant_image_output.exs` | **synthesized** | Decoder path (no current model emits this; synthesis is forward-compat) |
| **Response-shape: error classes** (400 unsupported MIME, 413 payload too large) | `test/fixtures/<provider>/synthesized/` | **synthesized** | Error-decode path; synthesized because provider rate-limits + cost of triggering deterministically |
| **Request-shape contracts** | live-validation runs (`OPENAI_API_KEY` / `ANTHROPIC_API_KEY` gated; tagged `@tag :live_openai` for §17.1 / `@tag :live_anthropic` for §17.2 per `test/test_helper.exs:9`) | **live** | Adapter sends what provider accepts (the case Phase 10.5 caught three bugs; mandatory per CLAUDE.md "every bundled provider adapter ships with examples + live BLOCKING gate") |

Live-validation: `examples/12_vision_input.exs` is the canonical run; `mix run examples/run_all.exs` with `OPENAI_API_KEY` and `ANTHROPIC_API_KEY` set is the BLOCKING `/review` gate.

### 3.8 Examples helper template (rule 18)

`examples/_helpers.exs` extends to (delta from current shape):

```elixir
@providers %{
  "openai" => %{
    adapter: ALLM.Providers.OpenAI,
    default_model: "gpt-5.4-nano",
    vision_default_model: "gpt-4o-mini",     # NEW (Decision #8)
    key_env: "OPENAI_API_KEY",
    image_adapter: ALLM.Providers.OpenAI.Images,
    image_default_model: "dall-e-2"
  },
  "anthropic" => %{
    adapter: ALLM.Providers.Anthropic,
    default_model: "claude-sonnet-4-6",
    vision_default_model: "claude-haiku-4-5-20251001",   # NEW
    key_env: "ANTHROPIC_API_KEY",
    image_adapter: nil,
    image_default_model: nil
  }
}

# engine/1 grows a `vision: true` opt:
def engine(extra_opts \\ []) do
  vision? = Keyword.get(extra_opts, :vision, false)
  # ... existing lookups ...
  model = if vision?, do: row.vision_default_model || row.default_model, else: row.default_model
  # ... rest unchanged ...
end
```

`12_vision_input.exs` calls `Helpers.engine(vision: true)`. Other scripts unchanged.

---

## 5. Phases

### Sub-phase 17.1 — OpenAI Vision Wiring (Layer B)

**Goal:** A user calling `ALLM.generate/3` or `ALLM.stream_generate/3` with a `Message` whose content is `[TextPart, ImagePart]` against an OpenAI engine receives a response from gpt-4o-mini (or any vision-capable model) without the current `:unsupported_feature` rejection.

**Spec sections:** §35.6, §35.7

**Layer:** B

#### 17.1.1 Test Plan (write first)

`test/allm/providers/openai_vision_test.exs` (NEW):

- `to_openai_content_blocks/2 with :chat_completions endpoint translates [TextPart] to [%{type: "text"}]`
- `to_openai_content_blocks/2 with :chat_completions endpoint translates [ImagePart{:url}] to [%{type: "image_url", image_url: %{url, detail}}]`
- `to_openai_content_blocks/2 with :chat_completions endpoint translates [ImagePart{:base64}] to a data:URI image_url`
- `to_openai_content_blocks/2 with :chat_completions endpoint translates [ImagePart{:binary}] to a data:URI image_url with base64 encoding`
- `to_openai_content_blocks/2 with :chat_completions endpoint reads ImagePart{:file} via Image.to_binary/1 and base64-encodes`
- `to_openai_content_blocks/2 with :chat_completions endpoint maps detail :auto/:low/:high to "auto"/"low"/"high"`
- `to_openai_content_blocks/2 with :responses endpoint translates [TextPart] to [%{type: "input_text"}]`
- `to_openai_content_blocks/2 with :responses endpoint translates [ImagePart] to [%{type: "input_image", image_url, detail}]`
- `to_openai_content_blocks/2 with mixed content emits blocks in original order`
- `to_openai_messages/1 routes list-content messages through to_openai_content_blocks/2 (assert by mock)`
- `to_responses_input/1 routes list-content messages through to_openai_content_blocks/2 (assert by mock)`
- `to_openai_messages/1 with binary-string content remains verbatim (v0.2 backward-compat)`
- `to_responses_input/1 with binary-string content remains verbatim`
- `ImageMime.validate_request(request, :openai) returns :ok for all four valid source shapes with valid MIME`
- `ImageMime.validate_request(request, :openai) returns {:error, %ValidationError{reason: :invalid_message, errors: [{[:content, 0, 1], :unsupported_image_format}]}} for image/svg+xml`
- `ImageMime.validate_request(request, :openai) returns {:error, ...} for a 21 MB image`
- `ImageMime.validate_request(request, :openai) returns :ok for a 21 MB URL-source image (size unverifiable, defer)`
- `ImageMime.validate_request(request, :openai) returns {:error, [{[:content, 0, 1], :missing_mime_type}]} for binary source without MIME`
- `ImageMime.validate_request(request, :openai) accumulates per-image errors across multiple ImagePart violations`
- `reject_image_in_system_messages/1 returns {:error, %ValidationError{reason: :invalid_message, errors: [{[:messages, 0, :content], :image_in_system_message}]}} when ImagePart in system role`
- `reject_image_in_system_messages/1 returns ok when only TextPart in system role`
- `reject_image_in_system_messages/1 returns ok when ImagePart in user role`
- `pre-flight order: system-msg-rejection fires before MIME validation` — fixture has both an ImagePart in system role AND an unsupported-MIME ImagePart in user role; assert system-msg error returned first
- `generate/2 against vision recorded fixture (chat_completions, single_image_url) decodes to %Response{content: text, finish_reason: :stop}`
- `generate/2 against vision recorded fixture (chat_completions, single_image_base64) decodes`
- `generate/2 against vision recorded fixture (chat_completions, multi_image) decodes`
- `generate/2 against vision recorded fixture (responses, single_image_url) decodes`
- `generate/2 against vision recorded fixture (responses, multi_image) decodes`
- `generate/2 against synthesized assistant-image-output fixture decodes to %Response{content: [%TextPart{}, %ImagePart{}]}` — forward-compat decoder
- `stream/2 with vision content emits the same stream-collected response as generate/2 (per fixture)`
- `@tag :live_openai test: gpt-4o-mini against a 50 KB local PNG returns a non-empty response`
- `Capability.preflight/2 with :vision capability false on resolved model and ImagePart in request returns {:error, %ValidationError{reason: :unsupported_capability, errors: [{[:vision], :vision_disabled}]}}`
- `Capability.preflight/2 with :vision absent in catalog and ImagePart in request returns :ok` — graceful degradation
- `Capability.preflight/2 with no ImagePart and any model is unaffected by the vision rule`

`test/allm/providers/support/image_mime_test.exs` (NEW):

- `validate/2 returns :ok for image/png within 20 MB`
- `validate/2 returns {:error, {:unsupported_image_format, "image/svg+xml"}}` for unsupported MIME
- `validate/2 returns {:error, {:image_too_large, 22_000_000}}` for oversize binary
- `validate/2 with URL source skips size check (returns :ok if MIME OK)`
- `validate/2 with missing MIME on non-URL source returns {:error, :missing_mime_type}`
- `accept_mimes(:openai)` and `accept_mimes(:anthropic)` return the documented sets
- Round-trip: encode-decode-validate keeps `byte_size` invariant
- `validate_request/2 returns :ok on a request with no ImagePart`
- `validate_request/2 returns :ok on a request with valid ImageParts across multiple messages`
- `validate_request/2 accumulates errors across messages` — fixture: msg 0 has unsupported MIME, msg 2 has oversize; both errors surface in `errors:` list with correct `[:content, msg_idx, part_idx]` paths
- `validate_request/2 with :openai vs :anthropic produces identical errors today` (accept-sets identical) but tests both arms so future divergence is caught

`test/allm/capability_vision_test.exs` (NEW):

- `preflight/2 with model_ref.capabilities.vision == true accepts ImagePart`
- `preflight/2 with model_ref.capabilities.vision == false rejects ImagePart`
- `preflight/2 with %{"vision" => false} (string-keyed) rejects ImagePart` — schema flexibility per `lib/allm/capability.ex:359-386` (the `check_tools/3` + `check_json_native/3` dual-keyed pattern; the analogous image gate lives at `:411-419`)
- `preflight/2 with no llm_db loaded no-ops on vision`
- `preflight/2 accumulates :vision_disabled with :tools_disabled when both fail`

`test/allm/chat_equivalence_test.exs` (MODIFY): add fixture row 10:
- *Vision-only multi-turn* — user TextPart+ImagePart → assistant text → user follow-up; both `Chat.run/3` and `Chat.stream/3 |> reduce` produce equal `%ChatResult{}`.

`test/allm/stream_equivalence_test.exs` (MODIFY): extend §31 generator vocabulary with one ImagePart-bearing user message; property holds.

#### 17.1.2 Implementation Checklist

- [x] Create `lib/allm/providers/support/image_mime.ex` with `validate/2`, `accept_mimes/1`, `@spec` and `@doc`
- [x] In `lib/allm/providers/openai.ex`: implement `to_openai_content_blocks/2` (NEW private function); rewrite `to_openai_messages/1` and `to_responses_input/1` to delegate list-content to it
- [x] Remove `reject_image_parts/1` (`:1675-1691`) and `stringify_content/1`'s ImagePart catch-all (`:1666-1669`); keep `stringify_content/1`'s string-passthrough for system messages only
- [x] Add `reject_image_in_system_messages/1` private helper; the per-image-part fold lives in `ALLM.Providers.Support.ImageMime.validate_request/2` (NEW public helper — see §3.1)
- [x] Wire pre-flight order in `generate/2` (`lib/allm/providers/openai.ex:490-491`) and `stream/2` (`:773-775`): system-rejection → capability → image-validate → translate → HTTP
- [x] Extend `lib/allm/capability.ex` with `:vision` capability gate (per Decision #5); reuse the existing dual-keyed accessor pattern at `:295-318`
- [x] Record fixtures via `scripts/record_openai_vision_fixtures.exs` (or extend an existing recorder) — 4 source-shapes × 2 endpoints; commit fixtures under `test/fixtures/openai/chat_completions/vision/` and `test/fixtures/openai/responses/vision/` *(synthesized — live re-record deferred; no `OPENAI_API_KEY` in scratch env)*
- [x] Synthesize assistant-image-output fixture under `test/fixtures/openai/chat_completions/synthesized/`
- [x] **Audit prior-phase tests asserting `:unsupported_feature` for ImagePart** (rule 9). Concrete flip-target sites (verified at design time):
    - `test/allm/providers/openai_wire_test.exs:467` — flip to expect happy-path translation against fixture
    - `test/allm/providers/openai_wire_test.exs:557` — flip likewise (Responses-API path)
    - `test/allm/providers/anthropic_wire_test.exs:426-442` — flip the §17.2 audit (Anthropic is §17.2 scope; included here since the flip set is one bookkeeping change)
    - `test/allm/providers/anthropic_wire_test.exs:534` — flip likewise
    - `test/allm/stream_runner_test.exs:113-128` — flip the assertion target: ImagePart content NOW yields a streamed response, not `{:error, :unsupported_feature}`
    - **Keep unchanged** (catalog tests asserting the atom remains in the closed enum, not vision-rejection assertions): `test/allm/error/adapter_error_test.exs:18`, `test/allm/error/image_adapter_error_test.exs:18`, `test/allm/serializer_test.exs:374`
- [x] Write doctest on `ALLM.Providers.OpenAI.generate/2` showing a vision request shape (uses `ALLM.Providers.Fake`, no live network); doctest on `ALLM.Providers.Support.ImageMime.validate/2`
- [x] CHANGELOG entry: `[FEAT] Phase 17.1: vision input wiring in ALLM.Providers.OpenAI per §35.6 (Chat Completions + Responses translators) — replaces Phase 14.4 reject_image_parts/1 guard with full content-block translator`

#### 17.1.3 Verification

```bash
mix test test/allm/providers/openai_vision_test.exs
mix test test/allm/providers/support/image_mime_test.exs
mix test test/allm/capability_vision_test.exs
mix test test/allm/chat_equivalence_test.exs
mix test test/allm/stream_equivalence_test.exs
mix test                                                # full suite green
mix credo --strict lib/allm/providers/openai.ex lib/allm/providers/support/image_mime.ex lib/allm/capability.ex
mix dialyzer
mix format --check-formatted
# Live (gated):
OPENAI_API_KEY=... mix test --include live_openai test/allm/providers/openai_vision_test.exs
```

---

### Sub-phase 17.2 — Anthropic Vision Wiring (Layer B)

**Goal:** Mirror of §17.1 for Anthropic. A user with `[TextPart, ImagePart]` content gets a vision response from `claude-haiku-4-5-20251001` (or any vision-capable Claude).

**Spec sections:** §35.6, §35.7

**Layer:** B

#### 17.2.1 Test Plan (write first)

`test/allm/providers/anthropic_vision_test.exs` (NEW):

- `to_anthropic_content_blocks/1 translates [TextPart] to [%{type: "text", text}]`
- `to_anthropic_content_blocks/1 translates [ImagePart{:url}] to [%{type: "image", source: %{type: "url", url}}]`
- `to_anthropic_content_blocks/1 translates [ImagePart{:binary}] to [%{type: "image", source: %{type: "base64", media_type, data}}]` with `data` being base64 of the bytes
- `to_anthropic_content_blocks/1 translates [ImagePart{:base64}] passing the base64 string verbatim into source.data`
- `to_anthropic_content_blocks/1 reads [ImagePart{:file}] via Image.to_binary/1 and base64-encodes`
- `to_anthropic_content_blocks/1 ignores ImagePart.detail` (any of `:auto`, `:low`, `:high` produce same wire shape)
- `to_anthropic_content_blocks/1 emits one debug log per process when ImagePart.detail is non-nil and dropped`
- `to_anthropic_content_blocks/1 emits the debug log exactly once per process across two calls`  ← detection mechanism (Decision #3)
- `to_anthropic_messages/1 routes list-content messages through to_anthropic_content_blocks/1`
- `to_anthropic_messages/1 with binary-string content remains verbatim (v0.2 backward-compat)`
- `ImageMime.validate_request(request, :anthropic)` — same matrix as §17.1 (ok / unsupported MIME / oversize / missing MIME / URL skips size). Note: validator is shared; `:anthropic` and `:openai` accept-sets are identical today, so per-provider divergence is asserted by the unit tests in `image_mime_test.exs`
- `reject_image_in_system_messages/1` — same as §17.1
- `extract_system/1 with system message containing only TextPart in content list still concatenates text` — backward-compat
- `extract_system/1 with system message containing ImagePart returns the message unchanged` (rejection happens upstream at `reject_image_in_system_messages/1`); test that the eventual `generate/2` call rejects
- Wire fixtures: `single_image_url`, `single_image_base64`, `single_image_binary`, `multi_image` — `generate/2` decodes correctly
- **No HTTP/1 flow-control >64KB fixture is required** (phasing-doc Phase 8 raised it as a candidate). Anthropic chat-side `generate/2` flows through `Req` (`lib/allm/providers/anthropic.ex:351-376`), not `Finch`; the §7.2 HTTP/1 flow-control bug applies only to the Finch streaming path. Streaming-side image messages also use Finch but vision content does not change the HTTP framing relative to non-vision long messages, which the existing Phase 11 streaming tests already cover. Documented here as a deliberate skip rather than an oversight.
- `stream/2 with vision content emits same collected response as generate/2`
- `@tag :live_anthropic test: claude-haiku-4-5-20251001 against a 50 KB local PNG returns non-empty response`
- `Capability.preflight/2 with vision: false against an Anthropic model rejects` — same pathway as §17.1, just covers the Anthropic resolved model

`test/allm/chat_equivalence_test.exs` (already extended in §17.1) — re-run with `ALLM_PROVIDER=anthropic`-style fixture switch.

#### 17.2.2 Implementation Checklist

- [ ] In `lib/allm/providers/anthropic.ex`: implement `to_anthropic_content_blocks/1` (NEW private function); rewrite `to_anthropic_messages/1`'s list-content path to delegate
- [ ] Remove `reject_image_parts/1` (`:717-733`) and `stringify_content/1`'s ImagePart raise (`:708-711`)
- [ ] Add `reject_image_in_system_messages/1` and `warn_detail_dropped_once/0` private helpers; per-part validation calls `ALLM.Providers.Support.ImageMime.validate_request(request, :anthropic)` (helper already shipped in §17.1)
- [ ] Wire pre-flight in `generate/2` (`lib/allm/providers/anthropic.ex:307-308`) and `stream/2` (`:1172-1173`): system-rejection → capability → image-validate → translate → HTTP
- [ ] Reuse `ALLM.Providers.Support.ImageMime` from §17.1 (no duplication; single file shared)
- [ ] Capability vision rule already wired in §17.1 — no further capability work in §17.2
- [ ] Record fixtures via `scripts/record_anthropic_vision_fixtures.exs`; commit under `test/fixtures/anthropic/messages/vision/`
- [ ] **Audit prior tests** for the removed `:vision_not_in_v0_2` placeholder rejection (`git grep ':vision_not_in_v0_2' test/`) — should already be zero hits per Phase 14.4, but re-verify
- [ ] Write doctest on `ALLM.Providers.Anthropic.generate/2` showing vision request (uses Fake)
- [ ] CHANGELOG entry: `[FEAT] Phase 17.2: vision input wiring in ALLM.Providers.Anthropic per §35.6 — Messages API content-block translator with base64/URL source dispatch; ImagePart.detail dropped with one-shot debug log`

#### 17.2.3 Verification

```bash
mix test test/allm/providers/anthropic_vision_test.exs
mix test                                                # full suite green
mix credo --strict lib/allm/providers/anthropic.ex
mix dialyzer
mix format --check-formatted
ANTHROPIC_API_KEY=... mix test --include live_anthropic test/allm/providers/anthropic_vision_test.exs
```

---

### Sub-phase 17.3 — v0.3.0 Release Polish (—)

**Goal:** Ship v0.3.0. Examples cover all v0.3 capabilities; README has Generating-images and Vision-input sections; CHANGELOG is consolidated; version bumped; `mix hex.build` dry-run succeeds.

**Spec sections:** §34, §35.10 (out-of-scope audit)

**Layer:** — (release infra; no source-of-truth library changes beyond the version bump)

#### 17.3.1 Test Plan (write first)

`test/allm/release_polish_test.exs` (NEW, smoke-style):

- `mix.exs @version is 0.3.0`
- `CHANGELOG.md contains a Phase 17.1, 17.2, 17.3 entry for v0.3.0 rollup`
- `examples/_helpers.exs @providers includes :vision_default_model for both providers`
- `examples/run_all.exs registers 11_edit_image.exs, 12_vision_input.exs, 13_image_variations.exs with provider markers`

For the example scripts, no unit tests — they're integration smoke runs gated on real keys. The `run_all.exs` exit-0 against both providers is the BLOCKING gate per CLAUDE.md.

`scripts/check_release.exs` (NEW or extension): asserts `mix hex.build` succeeds; the *.tar package excludes test/fixtures and examples/RUN_OUTPUT_*.md per `mix.exs:files`.

#### 17.3.2 Implementation Checklist

- [ ] Bump `mix.exs:4` `@version` to `"0.3.0"`
- [ ] Write `examples/11_edit_image.exs`: gpt-image-1 inpaint with mask using `ALLM.edit_image/4`; provider marker `# Provider: openai`
- [ ] Polish `examples/12_vision_input.exs` (originally shipped in §17.1): verify provider markers `# Provider: openai, anthropic` and finalize copy/output formatting
- [ ] Write `examples/13_image_variations.exs`: dall-e-2 variation; provider marker `# Provider: openai`
- [ ] Update `examples/_helpers.exs`: add `:vision_default_model` to both `@providers` rows; add `vision: true` opt to `engine/1` (Decision #8)
- [ ] Update `examples/run_all.exs`: include the three new scripts in iteration; provider gating is automatic via marker scanner (`:37`)
- [ ] Run `OPENAI_API_KEY=... mix run examples/run_all.exs` and `ANTHROPIC_API_KEY=... mix run examples/run_all.exs`; commit `examples/RUN_OUTPUT_OPENAI.md` and `examples/RUN_OUTPUT_ANTHROPIC.md` snapshots (full output redirected per Phase 15.6 pattern)
- [ ] Update `examples/README.md`: brief description of each new script; add cost notes table per Decision #10
- [ ] Update `README.md`: add a "Generating images" section (15-line worked example using Fake) and a "Vision input" section (10-line example showing `[TextPart, ImagePart]`); link to `examples/12_vision_input.exs` and `examples/10_generate_image.exs`
- [ ] Roll up CHANGELOG into a v0.3.0 section: one bullet per Phase 13–17 deliverable referencing §35.x
- [ ] Run `mix hex.build` and verify the resulting tarball; commit no artifacts (it's a dry-run)
- [ ] Run final `/review` per `AGENT_REVIEW_SPEC.md`; record review artifact
- [ ] §35.10 audit: grep `lib/`, `test/`, `examples/` for any `streaming_image_preview`, `image_to_video`, `ocr`, `upscale`, `batch_image` — should be zero hits
- [ ] Confirm coverage: `mix test --cover` ≥ 80% global; new code in §17.1+§17.2 ≥ 90%

#### 17.3.3 Verification

```bash
mix test
mix credo --strict
mix dialyzer
mix format --check-formatted
mix test --cover
mix hex.build                               # dry-run; check tarball contents
OPENAI_API_KEY=... mix run examples/run_all.exs    # exit 0 BLOCKING
ANTHROPIC_API_KEY=... mix run examples/run_all.exs # exit 0 BLOCKING
grep -rE 'streaming_image_preview|image_to_video|ocr|upscale|batch_image' lib/ test/ examples/  # expected: empty
```

---

## 6. Test Plan (cross-phase)

Beyond per-sub-phase tests:

- **Doctests:** `ALLM.Providers.OpenAI.generate/2`, `ALLM.Providers.Anthropic.generate/2`, `ALLM.Providers.Support.ImageMime.validate/2` each add one doctest demonstrating vision usage with `ALLM.Providers.Fake` (no real keys required).
- **Stream-equivalence (cross-phase):** existing property test at `test/allm/stream_equivalence_test.exs` runs unchanged with one new fixture row containing an ImagePart.
- **Chat-equivalence:** `test/allm/chat_equivalence_test.exs`'s 9-row matrix (Phase 7.5) grows to 10; the new row is a single-turn vision request.
- **Serializability (cross-phase):** Layer A unchanged; existing `lib/allm/text_part.ex` and `lib/allm/image_part.ex` round-trip tests cover JSON + ETF (already shipped Phase 14.4).
- **Conformance:** `ALLM.Adapter`/`ALLM.StreamAdapter` behaviours are unchanged; `ALLM.Providers.Fake` continues to pass the existing conformance suite (no callback signatures change).

**Coverage:** ≥80% global, ≥90% on new code in §17.1 + §17.2 (`lib/allm/providers/support/image_mime.ex` is small and 100% achievable; the translator helpers are pattern-match-heavy and 90% is a comfortable ceiling).

---

## 7. Error Contract

### Function-level error matrix (per §17.1 + §17.2)

| Function | Error reason | Hard-reject? | Recovery guidance |
|----------|--------------|--------------|---------------------|
| `ALLM.Providers.OpenAI.generate/2` | `%ValidationError{reason: :invalid_message, errors: [{[:messages, idx, :content], :image_in_system_message}]}` | yes | Lift the ImagePart into a user-role message |
| `ALLM.Providers.OpenAI.generate/2` | `%ValidationError{reason: :invalid_message, errors: [{[:content, msg_idx, part_idx], :unsupported_image_format}]}` | no (per-image accumulation) | Convert to `image/png`/`jpeg`/`webp`/`gif` or remove the part |
| `ALLM.Providers.OpenAI.generate/2` | `%ValidationError{reason: :invalid_message, errors: [{[:content, msg_idx, part_idx], :image_too_large}]}` | no | Resize image to <20 MB |
| `ALLM.Providers.OpenAI.generate/2` | `%ValidationError{reason: :invalid_message, errors: [{[:content, msg_idx, part_idx], :missing_mime_type}]}` | no | Construct `Image` via `from_file/1` (auto-MIME) or `from_binary/2` (explicit) |
| `ALLM.Providers.OpenAI.generate/2` | `%ValidationError{reason: :unsupported_capability, errors: [{[:vision], :vision_disabled}]}` | yes (gate fires before HTTP) | Switch to a vision-capable model (e.g., `gpt-4o-mini`) |
| `ALLM.Providers.Anthropic.generate/2` | same matrix as OpenAI, with provider atom `:anthropic` | mirror | mirror |

`@spec`s are tightened: every adapter `generate/2` and `stream/2` `@spec` enumerates `{:error, %ALLM.Error.AdapterError{}} | {:error, %ALLM.Error.ValidationError{}} | …` (existing union extends — no new error struct).

### Field-error vocabulary (validators)

| Field path | Reason atom | Hard-reject? | Fires when |
|------------|-------------|--------------|------------|
| `[:content, msg_idx, part_idx]` | `:unsupported_image_format` | no | ImagePart MIME not in provider accept-set |
| `[:content, msg_idx, part_idx]` | `:image_too_large` | no | resolved binary > 20 MB |
| `[:content, msg_idx, part_idx]` | `:missing_mime_type` | no | non-URL source has `mime_type: nil` |
| `[:messages, msg_idx, :content]` | `:image_in_system_message` | **yes** | ImagePart appears in a system-role message — short-circuits remaining content checks because system is text-only in v0.3 (§Out-of-scope #2) |
| `[:vision]` | `:vision_disabled` | no | model catalog says `vision: false` AND request has any ImagePart |

All atoms confirmed against `lib/allm/error/validation_error.ex:30-58`'s `@type reason` (existing `:invalid_message`, `:unsupported_capability`) — NO enum extension needed. The reason atoms above are field-level (per-tuple in `errors:`) and do NOT belong to the top-level `:reason` enum.

---

## 8. Streaming & Backpressure

No streaming-image-preview events are introduced (§35.10 reaffirmed). Vision input affects only request-side message construction; the response stream emits the same `:content_delta` events it did pre-vision. Cleanup, backpressure, and cancellation invariants from Phase 5 streaming are unchanged. The chat-equivalence and stream-equivalence properties (extended in §17.1+§17.2) re-prove no regression.

If a future provider emits an assistant ImagePart output mid-stream, the adapter's chunk handler emits a `:content_delta` with a list-shaped payload; `StreamCollector.apply_event/2`'s `:content_delta` clause writes the list verbatim into `Response.content`. No new clause needed (verified against `lib/allm/stream_collector.ex` at design time).

---

## 9. Definition of Done

- [ ] All sub-phases (17.1, 17.2, 17.3) marked `Completed`
- [ ] `mix test` zero failures, zero `unused_var` warnings, coverage ≥80% global / ≥90% new code
- [ ] `mix credo --strict` zero issues on changed files
- [ ] `mix dialyzer` zero new warnings vs. prior PLT
- [ ] `mix format --check-formatted` passes
- [ ] Every new public function has `@spec` and `@doc` with at least one runnable doctest
- [ ] Layer-A backward-compat test runs unchanged (no Layer-A change in this phase)
- [ ] `chat_equivalence_test.exs` 10-row matrix (vision row included) passes both `Chat.run/3` and `Chat.stream/3 |> reduce` arms
- [ ] `stream_equivalence_test.exs` property holds with vision in §31 vocabulary
- [ ] `OPENAI_API_KEY=... mix run examples/run_all.exs` exit 0 — BLOCKING
- [ ] `ANTHROPIC_API_KEY=... mix run examples/run_all.exs` exit 0 — BLOCKING
- [ ] `examples/RUN_OUTPUT_OPENAI.md` and `examples/RUN_OUTPUT_ANTHROPIC.md` snapshots committed
- [ ] CHANGELOG.md updated with v0.3.0 rollup
- [ ] `mix.exs @version` is `"0.3.0"`
- [ ] `mix hex.build` succeeds (dry-run)
- [ ] §35.10 audit: zero matches for out-of-scope features
- [ ] `/review` per AGENT_REVIEW_SPEC.md recorded as the phase artifact

---

## What Comes After

v0.4 candidates (per `RELEASE_0_3_PHASING.md`'s post-release section):

- **Audio I/O** — `ALLM.transcribe/3`, `ALLM.synthesize/3` parallel surfaces
- **Embeddings** — `ALLM.embed/3`
- **Streaming image previews** — would widen §3 stream-first invariant or add `ImageEvent` union
- **Prompt caching** as first-class API
- **Anthropic `cache_control` for image content** (deferred from §17.2 Out-of-scope)
- **Middleware (§29)** — `Engine.middleware: []` populated
- **Memory stores** — pluggable conversation memory beyond `Thread`
- **Additional provider adapters** — Gemini (image + chat + vision), Stability/Replicate/fal.ai (image-only), local LLMs (Ollama, llama.cpp)

If a §17.x sub-phase finds itself designing a streaming-image protocol, an audio adapter, or an embeddings surface, the scope is wrong — push the feature into a v0.4 design doc and finish the v0.3 phase with only what §35.6 / §34 require.
