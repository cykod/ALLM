# Phase 27: Provider Prompt Caching — Design Document

*Generated: 2026-09-27 · Measured against: `94ffa45` · Provider research refreshed 2026-09-27 (Context7 `/websites/developers_openai_api`, `/websites/platform_claude_en`; OpenAI changelog)*

> **Goal:** ALLM lets a long-lived conversation use each provider's prompt cache correctly, and shows the caller whether the cache hit.
> **Outcome:** On every chat adapter and both OpenAI endpoints, streaming and non-streaming, `%ALLM.Usage{}` reports cache reads and cache writes under the same field names. One provider-neutral `prompt_cache:` option routes and extends caches. A test pins append-prefix stability. A live probe confirms every provider wire claim this design depends on.
> **Spec sections:** §5.4 (`ALLM.Request`), §5.9a (`ALLM.Usage`), §8 (event protocol, `:raw_chunk {:usage, _}` fold), §9 (request building), §7.1 (adapter translation)
> **Layers touched:** B (27.0, 27.2, 27.3), A (27.1), C (27.4), plus a docs/probe sub-phase (27.5). Each sub-phase touches one layer. 27.5 adds no `lib/` code.

## Status

| Phase | Description | Layer | Status |
|-------|-------------|-------|--------|
| 27.0 | Refactor-first: route `gpt-6*` (and later) like `gpt-5*` in the OpenAI adapter | B | see RECORDS |
| 27.1 | `Usage.cache_write_input_tokens` + `Request.prompt_cache` + validation | A | see RECORDS |
| 27.2 | Cache-usage normalization in OpenAI (both endpoints), Anthropic and Gemini, streaming + non-streaming | B | see RECORDS |
| 27.3 | Adapter translation of `Request.prompt_cache` | B | see RECORDS |
| 27.4 | `chat/3` / `Session` wiring, session-id key default, prefix-stability test | C | see RECORDS |
| 27.5 | Live wire probe + recorded fixtures, example `28_prompt_cache.exs`, guide, spec amendments, CHANGELOG | docs / live gate | see RECORDS |

**Progress:** tracked in `steering/2026-09-27_PROMPT_CACHING_DESIGN_RECORDS.md` (this table's status column is not maintained).

---

## Overview

The meal app's cook mode keeps one `ALLM.Session` open for a whole recipe. Its prefix is long and stable: the system prompt, the recipe and the tool list. Chef questions arrive minutes apart, for example during a braise. Whether that prefix is served from the provider's prompt cache decides both latency to first token and input cost. Today ALLM can't show whether it hit, and gives no provider-neutral way to ask for it:

- **Cache hits are invisible on most paths.** OpenAI Chat Completions leaves `prompt_tokens_details.cached_tokens` in `usage.extra` on the non-streaming path (`lib/allm/providers/openai.ex:2020-2033`, `decode_usage/1`). Its streaming path never asks for usage (§"Wire-field map" row O-5) and would drop the details anyway (`openai.ex:1341-1348`, `maybe_append_usage/3` keeps three keys). OpenAI Responses leaves `input_tokens_details.cached_tokens` in `extra` on both paths: `decode_responses_usage/1` at `openai.ex:2178-2192` (non-streaming) and `responses_usage_events/1` at `openai.ex:1212-1227` (streaming). Gemini leaves `cachedContentTokenCount` in `extra` on both paths (`lib/allm/providers/gemini.ex:1176-1194` `parse_usage/1`, reused by the streaming `handle_usage_metadata/2` at `gemini.ex:1634-1645`). Anthropic maps `cache_read_input_tokens` on its non-streaming path only (`lib/allm/providers/anthropic.ex:1205-1217` `decode_usage/1`). Its streaming path reads usage from `message_delta` alone and keeps two keys (`anthropic.ex:1690-1698`). It ignores `message_start.message.usage` entirely (`anthropic.ex:1585-1597`), so on the committed fixture `test/fixtures/anthropic/messages/happy_text.sse` (`message_start` carries `"input_tokens":10`, `message_delta` carries only `"output_tokens":2`) a streamed Anthropic response reports `input_tokens: nil`.
- **No neutral cache option exists.** `grep -rn prompt_cache lib/` returns nothing (run 2026-09-27). Opaque params already reach the wire: `Chat.build_request/4` puts every non-typed param on `request.options` (`lib/allm/chat.ex:2009-2025`), and the OpenAI and Anthropic body builders merge it last at the top level (`openai.ex:1406` Chat Completions, `openai.ex:1427` Responses, `anthropic.ex:547`). (Gemini's exception: its `request.options` merge lands inside `generationConfig`, `gemini.ex:956` `to_generation_config/1`, not at the body's top level.) So a caller can already send a raw `prompt_cache_key`. But the spelling is per provider, Anthropic's equivalent is a structurally different field, and nothing ties the key to the session.

- **GPT-6 models are mis-routed today.** OpenAI released `gpt-6-astra` on 2026-09-03 and `gpt-6-sol` / `gpt-6-luna` on 2026-09-22 (OA-8). The adapter's model-family tables key on `^gpt-5` (`openai.ex:127-136`: `@endpoint_dispatch`, `@chat_completions_new_max_tokens_models`, `@chat_completions_reasoning_models`), so every `gpt-6*` id falls through to Chat Completions, is sent the legacy `max_tokens`, and has its reasoning controls stripped. Measured with a `mix run` script against `94ffa45` on 2026-09-27: `dispatch_endpoint("gpt-6-luna", [])` and `dispatch_endpoint("gpt-6-astra", [])` both return `:chat_completions`, the body is `%{"max_tokens" => 100}`, and the adapter logs `reasoning controls ignored for non-reasoning model "gpt-6-luna"`. `gpt-6-astra` additionally "requires Responses API" for tool calling (OA-8). A cook mode moved to GPT-6, which is half the price of the 5.6 tier with a 90 % cached-read discount (OA-10), would fail before caching matters. Sub-phase 27.0 fixes this first (DESIGN.md guideline 10, refactor-first).

This phase is the smallest change that closes these gaps. It is sized for cook mode, not a caching framework.

- **Deliverables**
  - `gpt-6*` and later OpenAI families are routed like `gpt-5*`: Responses endpoint, `max_completion_tokens` on Chat Completions, and reasoning controls kept (27.0).
  - `ALLM.Usage.cache_write_input_tokens`: a new field. Also a documented, cross-provider meaning for `input_tokens` (inclusive of cached tokens) and `cached_input_tokens`.
  - `ALLM.Request.prompt_cache`: a new typed field, `nil | %{key: String.t() | nil, retention: :short | :long}`.
  - A `prompt_cache` rule in `ALLM.Validate.request/1`.
  - Normalized cache usage in `ALLM.Providers.OpenAI` (both endpoints), `ALLM.Providers.Anthropic` and `ALLM.Providers.Gemini`, on both paths. The Chat Completions streaming body gains `stream_options.include_usage`.
  - Adapter translation of `request.prompt_cache` (see the Wire-field map).
  - `prompt_cache:` accepted as a call opt and in `engine.params` by `chat/3`, `stream/3`, `step/3`, `stream_step/3` and `Session.*` (everything that goes through `Chat.build_request/4`). `generate/3` / `stream_generate/3` take a caller-built `%Request{}`, so those callers set `Request.prompt_cache` directly. When `key` is nil and a `:session_id` is present, the key defaults to that id.
  - A prefix-stability test across the four translators.
  - `scripts/record_prompt_cache_fixtures.exs`: a live probe with a negative control, plus recorded fixtures. Also `examples/28_prompt_cache.exs`, a guide section and spec amendments.
- **Spec coverage:** refines §5.4, §5.9a and §9. Amendments land in 27.5 (rule 21 commit-range stamp).
- **Layer demonstration**

  *Layer A:* build and inspect data with no adapter.
  ```elixir
  req = ALLM.Request.new([%ALLM.Message{role: :user, content: "hi"}],
          prompt_cache: %{key: "recipe-42", retention: :long})
  :ok = ALLM.Validate.request(req)
  %ALLM.Usage{cached_input_tokens: 4096, cache_write_input_tokens: 0}
  ```
  *Layer B:* a direct adapter call translates the field.
  ```elixir
  body = ALLM.Providers.Anthropic.to_anthropic_request_body(req)
  body["cache_control"]   #=> %{"type" => "ephemeral", "ttl" => "1h"}
  ```
  *Layer C:* stateless chat with an engine-level default.
  ```elixir
  engine = ALLM.Engine.new(adapter: ALLM.Providers.OpenAI, model: "gpt-5.6",
                           params: %{prompt_cache: %{retention: :long}})
  {:ok, result} = ALLM.chat(engine, thread, session_id: "recipe-42")
  result.final_response.usage.cached_input_tokens
  ```
  *Layer D:* no new API. `Session` already forwards `session.id` as `:session_id` (`lib/allm/session.ex:917-923`, `put_session_id_if_set/2`), so the key default applies automatically.
  ```elixir
  {:ok, session, result} = ALLM.Session.reply(engine, %{session | id: "recipe-42"}, "Now what?")
  ```
- **Prerequisites:** none beyond HEAD `94ffa45`.
- **Out of scope**
  - *Cache-aware costing.* `Capability.apply_pricing/2` prices `input_tokens` at one rate (`lib/allm/capability.ex:700-716`). Discounted cache-read and premium cache-write rates would need catalog pricing fields this design has not verified exist in `llm_db`. The data this phase adds (`cached_input_tokens`, `cache_write_input_tokens`) is what such a change would consume.
  - *Per-block cache breakpoints.* This covers Anthropic block-level `cache_control` and OpenAI `prompt_cache_breakpoint` / `prompt_cache_options.mode: "explicit"`. Anthropic's top-level automatic mode and OpenAI's implicit mode cover cook mode's "cache the growing conversation" shape without touching the message translators. Block breakpoints need a Layer-A marker on `Message`/content parts, which is a separate design.
  - *Gemini explicit caching.* This means the `cachedContents` resource plus `cachedContent` on `generateContent`. It is a stateful server-side resource with its own lifecycle: create, TTL, delete, storage billing. It is not a request option.
  - *OpenAI `prompt_cache_options` (gpt-5.6+) and `prewarm` / `comparison_response_id`.* Its only documented `ttl` is `"30m"`, which is also the default (OA-3), so a neutral mapping would send the default. Callers can still pass it raw through `request.options`.
  - *Changes to `ALLM.StreamCollector`.* Its `:raw_chunk {:usage, map}` fold stays a wholesale replace (`lib/allm/stream_collector.ex:291-292`). Anthropic and OpenAI emit one usage chunk per response (Decision #6). Gemini emits usage on every chunk that carries `usageMetadata` (cumulative, last wins, `gemini.ex:1478-1481`). The replace-fold is correct for both patterns.
- **Non-obvious decisions**
  1. **`Usage.input_tokens` is normalized to *total* prompt tokens, including cached reads and cache writes. This changes Anthropic's value.** OpenAI's input count includes cached tokens (OA-7, inferred for Chat Completions). So does Gemini's (G-3, inferred for implicit hits). Anthropic's excludes them: its docs define total input as `cache_read + cache_creation + input_tokens` (AN-6). Without normalization, `cached_input_tokens / input_tokens`, the hit ratio cook mode wants, would mean different things per provider. Anthropic's value is unchanged for any request without cache activity, which is every ALLM request today unless a caller passed raw `cache_control` in `request.options`. The raw provider count is kept as `extra["uncached_input_tokens"]` on Anthropic only. Alternative considered: leave `input_tokens` provider-native and document the difference per adapter. Rejected because the portability of `Usage` is the point of Layer A. Anthropic's `total_tokens` follows: it becomes normalized `input_tokens + output_tokens` (`anthropic.ex:1221-1226` `maybe_total/1` today sums the raw value). **Consequence for costing:** `Capability.apply_pricing/2` (`capability.ex:700-716`) prices `input_tokens` at the plain input rate, so Anthropic's reported `input_cost` rises on cache-active requests. That matches how OpenAI and Gemini are already priced, and cache-aware pricing is out of scope. *Docs target: @moduledoc ALLM.Usage + CHANGELOG entry (flagged as a semantic change, naming `input_tokens`, `total_tokens` and `input_cost`).*
  2. **`prompt_cache` is a typed `%Request{}` field, not an opaque option.** A typed field has one validated shape, survives JSON round-trips with atoms restored, and can be translated per provider. An opaque `request.options` key would reach every wire body verbatim, where OpenAI rejects unknown top-level parameters (O-6, inferred). This follows the `:response_format` / `:tool_choice` precedent (`chat.ex:2064-2067`, "handled by `extra`"). *Docs target: @moduledoc ALLM.Request.*
  3. **Anthropic uses the top-level automatic `cache_control`, not per-block breakpoints.** In the documented top-level mode, "the system automatically places the cache breakpoint on the last cacheable block and moves it forward as conversations grow" (AN-2). That is exactly cook mode's shape. It needs no change to `to_anthropic_messages/1` or the `system` string encoding (`anthropic.ex:552`, `maybe_put_system/2`). *Docs target: @doc ALLM.Providers.Anthropic.generate/2.*
  4. **The typed field is translated before `request.options` is merged, so raw options win.** The OpenAI and Anthropic body builders merge `stringify_options(request.options)` after their typed fields (`openai.ex:1406`, `:1427`; `anthropic.ex:547`). Gemini merges into `generationConfig` (`gemini.ex:956`) and gets no `prompt_cache` translation (Decision #8). A caller who sends raw `prompt_cache_key` or `prompt_cache_options` alongside `prompt_cache:` gets the raw value on the wire. This keeps `options` as the escape hatch for provider features this phase leaves out. *Docs target: @moduledoc ALLM.Request.*
  5. **The key defaults to `:session_id` in `Chat.build_request/4`, not in `ALLM.Session`.** `Session` already puts `:session_id` on the chat opts (`session.ex:917-923`), and `chat/3` callers pass it directly. Defaulting in one place makes Layers C and D behave identically, and `session.ex` is not modified. The default applies only when the caller asked for caching (`prompt_cache` non-nil): turning caching on is opt-in, and deriving the key is not. *Docs target: @moduledoc ALLM.Session "`session_id` propagation" + @doc ALLM.chat/3.*
  6. **Anthropic streaming usage is merged inside the adapter and emitted once, from `message_delta`.** `message_start.message.usage` carries input and cache counts (AN-7). `message_delta.usage` is documented as cumulative (AN-8), but the committed fixture shows it carrying only `output_tokens`. The adapter stores the `message_start` usage in its stream state and merges it with the `message_delta` usage, with non-nil `message_delta` keys winning (a `null` in the delta never wipes a `message_start` integer). It then emits one `{:raw_chunk, {:usage, _}}`. Emitting twice would lose the first, because the collector fold replaces (`stream_collector.ex:291-292`). *Docs target: internal — no user-facing docs needed.*
  7. **Streaming Chat Completions requests now carry `"stream_options" => %{"include_usage" => true}`.** Without it OpenAI sends no usage on a stream (O-5). The key is added with `Map.put_new/3` after the body is built, so a caller-supplied `stream_options` in `request.options` wins. This applies to `:chat_completions` streaming only. The Responses stream already delivers usage in `response.completed` (`openai.ex:1212`). *Docs target: @doc ALLM.Providers.OpenAI.stream/2 (an adapter-injected default) + CHANGELOG entry.*
  8. **Gemini ignores `prompt_cache` without error.** Implicit caching is automatic on Gemini 2.5+ (G-1), and there is no per-request key or TTL. Raising would make provider-neutral code, like cook mode's engine `params`, fail when the provider is switched. *Docs target: @doc ALLM.Providers.Gemini.generate/2.*
  9. **`retention: :long` maps to the longest per-request retention each provider offers:** Anthropic `ttl: "1h"` and OpenAI `prompt_cache_retention: "24h"`. The OpenAI field is marked Deprecated but is still documented on both endpoints (OA-4). 27.5 probe arm OA-P2 confirms that gpt-5.6 and gpt-6-luna accept it. The OA-P1/OA-P2 acceptance arms run early, as a 27.3 Verification step (`--only acceptance`, no fixtures written), before 27.3 commits the `"24h"` wire value. If OA-P2 fails there, the build halts and the OpenAI arm of this decision is escalated to the user; the implementer does not ship around it. On gpt-5.6+ the default lifetime is already 30 minutes after last use (OA-3), which covers the braise case without `:long`. Whether GPT-6 inherits the "GPT-5.6 and later" behaviour is undocumented (OA-9): OpenAI's caching guide, fetched 2026-09-27, still names no GPT-6 model, so OA-P4 runs on `gpt-6-luna` as well. *Docs target: @moduledoc ALLM.Request.*

---

## Assumptions

1. **Cook mode runs a gpt-5.6-class or GPT-6-class OpenAI model through the Responses endpoint.** `dispatch_endpoint/2` routes `gpt-5*` to `:responses` (`openai.ex:217-224`, over the `@endpoint_dispatch` table at `:127-136`), and after 27.0 `gpt-6*` too. This design still covers Chat Completions and the other adapters, because provider neutrality is the product.
2. **Provider caching stays best-effort.** No provider guarantees a hit (OA-2: "Keys influence routing; they do not pin requests to a machine or guarantee a cache hit"). The design makes hits *observable* and *more likely*. Every assertion about a real hit lives in the live probe, which allows retries (27.5), never in the unit suite.
3. **Cook mode's cached prefix is at least 4,096 tokens, or the caller accepts misses below each provider's minimum.** Minimums: OpenAI 1,024 on gpt-5.6+ (OA-5). Anthropic 512 to 4,096 depending on model (AN-4). Gemini 2,048 to 4,096 (G-2). ALLM does not pad prompts.
4. **The session id the meal app assigns is not personal data.** It becomes a value sent to OpenAI. See the Security note under 27.4.

## Alternatives Considered

| Alternative | Why not |
|---|---|
| Document the raw options (`prompt_cache_key`, `cache_control`) and change nothing in `lib/` | Leaves observability broken, which is the part cook mode cannot work around. Provider-specific engine params also break `ALLM_PROVIDER` switching. |
| A Layer-A `ALLM.PromptCache` struct instead of a map field | Needs registration in `ALLM.Serializer`, `@layer_a` and `groups_for_modules` for two keys. A validated map with a `decode_prompt_cache/1` pair is the smaller contract. Revisit if the option grows beyond two keys. |
| Default `prompt_cache` on for every `Session` with an id | It is a wire change for every existing Session caller, and would break every wire test that asserts an exact body. Opt-in keeps existing bodies byte-identical (27.3 Test Plan pins this). |
| Sum usage across multiple `{:usage, _}` chunks in `StreamCollector` | That changes a Layer-C fold every adapter relies on, to fix one adapter's emission pattern. Adapter-local merging (Decision #6) is surgical. |

---

## Wire-field map

This table is the single normative home for provider wire facts. Every row is **Confirmed** (quoted docs *and* the claim is not one ALLM computes with), **Inferred** (docs are silent or ambiguous), or **Probe** (a 27.5 arm asserts it before any fixture is written). Research date for every row: 2026-09-27. A row marked Inferred or Probe must not be cited as settled in guides until 27.5 records it.

### OpenAI (Chat Completions + Responses)

| ID | Claim | Source | Status |
|---|---|---|---|
| OA-1 | `prompt_cache_key: string \| null` is accepted on both endpoints | Chat + Responses create references (developers.openai.com/api/reference/…/create) | Probe (OA-P1) |
| OA-2 | The key influences routing only. On gpt-5.6+ "OpenAI handles cache routing automatically; the key is not needed … You can use separate keys to maintain separate cache accounting" | developers.openai.com/api/docs/guides/prompt-caching | Confirmed |
| OA-3 | gpt-5.6+: "A cached prefix remains eligible for reuse for 30 minutes after its most recent write or reuse". Earlier `in_memory`: "around 5 to 10 minutes of inactivity, up to one hour" | same guide | Confirmed (docs); not computed with |
| OA-4 | `prompt_cache_retention: "in_memory" \| "24h" \| null` is "Deprecated. Use `prompt_cache_options.ttl` instead"; gpt-5.5+ supports only `24h` | Chat + Responses references | Probe (OA-P2, gpt-5.6 acceptance) |
| OA-5 | Minimum cacheable prompt is 1,024 tokens on gpt-5.6+ | guide | Confirmed; probe prefix sized well above it |
| OA-6 | Usage: Chat `usage.prompt_tokens_details.{cached_tokens, cache_write_tokens}`; Responses `usage.input_tokens_details.{cached_tokens, cache_write_tokens}` | both references | Probe (OA-P4 records both) |
| OA-7 | `input_tokens` / `prompt_tokens` include cached tokens (the guide computes `ordinary_input_tokens = input_tokens - cached_tokens - cache_write_tokens`) | guide (Responses, by arithmetic); Chat not stated | Inferred |
| O-5 | Streaming Chat Completions sends usage only with `stream_options: {"include_usage": true}`, in a last chunk with `choices: []` | Chat streaming-events reference | Confirmed; the final chunk carrying `prompt_tokens_details` is Probe (OA-P5) |
| OA-8 | GPT-6 ids: `gpt-6-astra` (2026-09-03), `gpt-6-sol`, `gpt-6-luna` (2026-09-22). Sol/Luna: "reasoning models" on "Responses and Chat Completions". Astra: "no `none` reasoning effort, no custom temperature/top_p values, tool calling requires Responses API". All 1.05M context | developers.openai.com/api/docs/changelog; developers.openai.com/api/docs/models | Confirmed (docs) |
| OA-9 | GPT-6 prompt-caching behaviour (30-min TTL, 1,024-token minimum, `prompt_cache_options`, `prompt_cache_retention` acceptance) matches "GPT-5.6 and later" | the caching guide names no GPT-6 model (fetched 2026-09-27) | Probe (OA-P1/P2/P4 on `gpt-6-luna`) |
| OA-10 | Pricing: gpt-6-sol $2 / $10 per MTok, gpt-6-luna $0.10 / $0.50; cached reads 90 % off (secondary source); gpt-5.6+ cache writes cost 1.25× uncached input | changelog + models page (list prices); VentureBeat 2026-09-22 (cached discount); Context7 guide ("charge 1.25x the uncached input rate for cache writes") | Confirmed list prices; cached discount Inferred |
| OA-11 | gpt-5.6+ supports explicit caching: up to 4 `prompt_cache_breakpoint`s, `prompt_cache_options.mode: "explicit"`, lookback over the 80 most recent breakpoints; "Prompt Cache Diagnostics" is GA in Responses for gpt-5.6+ (2026-09-08) | Context7 `/websites/developers_openai_api` (Responses create + deployment checklist); changelog | Confirmed; out of scope |
| O-6 | Unknown top-level parameters are rejected with 4xx | not in official docs; `scripts/record_openai_moderation_fixtures.exs:60` comment claims it for Chat Completions with no recorded fixture | Probe (OA-C control) |

> CORRECTED 2026-09-27 (27.5 probe, `scripts/record_prompt_cache_fixtures.exs`, one full run): OA-1, OA-4 (acceptance on gpt-5.6, gpt-6-luna, gpt-5.4-nano Responses and gpt-4o-mini Chat Completions), OA-9 and O-6 (Responses `unknown_parameter` 400, recorded `openai/responses/recorded/prompt_cache_unknown_field.json`; Chat Completions 400 too) are **Confirmed**. OA-7 is **Confirmed on both endpoints**: `input_tokens` / `prompt_tokens` stayed 6,263 on the miss and on the hit while `cached_tokens` went 0 → 6,260 (Responses) and 0 → 5,888 (Chat), so the input count includes cached tokens. OA-6 is **Confirmed for Responses only**: `input_tokens_details` carries both `cached_tokens` and `cache_write_tokens` on gpt-5.6 and gpt-6-luna. On **Chat Completions with gpt-5.4-nano** the final stream chunk's `prompt_tokens_details` carried `cached_tokens` and `audio_tokens` but **no `cache_write_tokens`** (`openai/chat_completions/recorded/prompt_cache_stream.sse`); the adapter already leaves an absent counter `nil`, so no code change. O-5's final usage chunk (`choices: []`) is Confirmed by the same fixture.

### Anthropic (Messages)

| ID | Claim | Source | Status |
|---|---|---|---|
| AN-1 | Block-level `cache_control: {"type": "ephemeral", "ttl": "5m" \| "1h"}`, `"5m"` default | platform.claude.com/docs/en/build-with-claude/prompt-caching | Confirmed (not used this phase) |
| AN-2 | Top-level `cache_control: {"type": "ephemeral"}` enables automatic caching, placing the breakpoint on the last cacheable block | same page | Probe (AN-P1) |
| AN-3 | Top-level `cache_control` accepts `"ttl": "1h"`: "cache_control: optional CacheControlEphemeral { type: \"ephemeral\", ttl } … ttl: optional \"5m\" or \"1h\" … Defaults to `5m`" | platform.claude.com/docs/en/api/http/messages/create (via Context7 `/websites/platform_claude_en`) | Confirmed; AN-P2 kept as a regression arm |
| AN-4 | Minimum cacheable length per current model: 512 for `claude-fable-5-1`, `claude-opus-5`; 1,024 for `claude-sonnet-5`, Sonnet 4.6/4.5, Opus 4.8; 4,096 for `claude-haiku-4-5`, Opus 4.6/4.5. Shorter prompts are "processed without caching, and no error is returned". Max 4 breakpoints | prompt-caching page, "Cache limitations" (via Context7) | Confirmed; probe prefix sized above 4,096 |
| AN-5 | No `anthropic-beta` header is needed for caching | the prompt-caching page's automatic-caching `curl` example sends only `x-api-key`, `anthropic-version: 2023-06-01` and `content-type` (via Context7). The earlier `prompt-caching-2024-07-31` claim came from a *beta* endpoint page | Confirmed; every AN arm still runs without the header |
| AN-6 | Usage: `cache_read_input_tokens`, `cache_creation_input_tokens`; `input_tokens` counts only tokens after the last breakpoint; "Total input tokens = cache_read + cache_creation + input_tokens" | prompt-caching page | Confirmed (this is the Decision #1 basis) |
| AN-7 | `message_start.message.usage` carries `input_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`, `output_tokens` | platform.claude.com/docs/en/build-with-claude/streaming | Probe (AN-P3 records SSE) |
| AN-8 | `message_delta.usage` is "cumulative" and may repeat the input/cache fields | streaming page; contradicted in shape by committed `happy_text.sse` (output only) | Inferred; Decision #6 handles both shapes |
| AN-10 | Usage also carries `cache_creation: {ephemeral_5m_input_tokens, ephemeral_1h_input_tokens}`; "`cache_creation_input_tokens` … equals the sum of the values in the `cache_creation` object". Write pricing: 5m 1.25×, 1h 2× input; reads 0.1× on Opus 5 ("some models use a different multiplier") | prompt-caching page + cost-optimization page (via Context7) | Confirmed; the object stays in `extra` (Usage decoding table) |
| AN-11 | Current models: `claude-fable-5-1`, `claude-opus-5`, `claude-sonnet-5`, `claude-haiku-4-5`. On Fable 5.x, Opus 5, Opus 4.8/4.7 and Sonnet 5, "non-default `temperature`, `top_p`, or `top_k` values return a 400 error on every request" | platform.claude.com/docs/en/home; build-with-claude/thinking (via Context7) | Confirmed; not caching scope, see "Adjacent findings" |
| AN-12 | "A cache entry only becomes available after the first response begins", so parallel first requests all miss | prompt-caching page (via Context7) | Confirmed; documented in the guide |
| AN-9 | Changing tools invalidates the whole cache; changing `tool_choice` or images invalidates the message cache | prompt-caching page | Confirmed; documented in the guide |
| AN-C | Unknown top-level fields are rejected with 400 | not in fetched docs | Probe (AN-C control) |

> CORRECTED 2026-09-27 (27.5 probe): AN-2 (automatic caching: first call `cache_creation_input_tokens` 7,308 / 9,483 / 7,309, second call reads the same count, on haiku-4-5, sonnet-5, sonnet-4-6), AN-5 (no beta header on any arm), AN-7 (`message_start.message.usage.cache_read_input_tokens` 7,308 on the stream) and AN-C (`"totallyNotAField: Extra inputs are not permitted"`, 400) are **Confirmed**. AN-8 is **Confirmed in its cumulative shape**: on the live haiku-4-5 stream `message_delta.usage` repeated `input_tokens`, both cache counters and `output_tokens` (`anthropic/messages/recorded/prompt_cache_stream.sse`), unlike the older committed `happy_text.sse`; Decision #6's merge handles both. AN-11 is **wider than stated**: claude-sonnet-5 answered 400 `` "`temperature` is deprecated for this model." `` for `temperature: 0` as well as `0.5` (raw request, 2026-09-27), so ANY `temperature` fails, not only non-default values.

### Gemini (generateContent)

| ID | Claim | Source | Status |
|---|---|---|---|
| G-1 | Implicit caching is on by default for Gemini 2.5+; no request field | ai.google.dev/gemini-api/docs/caching | Confirmed |
| G-2 | Implicit minimum 2,048 (2.5 Flash/Pro) to 4,096 (3.x) tokens | same | Confirmed; probe prefix sized above 4,096 |
| G-3 | `usageMetadata.cachedContentTokenCount`; `promptTokenCount` is inclusive (stated for explicit caching only) | ai.google.dev/api/generate-content | Inferred for implicit; Probe (GE-P1 records) |
| G-C | Unknown top-level fields are rejected with 400 "Unknown name" | indirect: `test/fixtures/gemini/embeddings/recorded/error_400_unknown_field.json` (sub-request, not top level) | Informational (GE-C). ALLM sends no top-level Gemini field this phase, and `request.options` merges into `generationConfig`, so no acceptance arm depends on it |

> CORRECTED 2026-09-27 (27.5 probe): G-3 is **Confirmed for implicit caching**: on gemini-3-flash-preview `promptTokenCount` stayed 6,719 on the miss and on the hit while `cachedContentTokenCount` went absent → 4,079, so the prompt count is inclusive (`gemini/generate_content/recorded/prompt_cache_hit.json`). On a miss the field is absent, not `0`. G-C is **Confirmed** at the top level: 400 `Invalid JSON payload received. Unknown name "totallyNotAField"` (`gemini/generate_content/recorded/prompt_cache_unknown_field.json`).

---

## Behaviour & Type Contracts

### `ALLM.Usage` (Layer A) — 27.1

```elixir
@type t :: %__MODULE__{
        input_tokens: non_neg_integer() | nil,          # TOTAL prompt tokens incl. cached reads + writes (Decision #1)
        output_tokens: non_neg_integer() | nil,
        cached_input_tokens: non_neg_integer() | nil,   # tokens served FROM the provider cache
        cache_write_input_tokens: non_neg_integer() | nil,  # NEW — tokens WRITTEN to the cache this call
        reasoning_tokens: non_neg_integer() | nil,
        total_tokens: non_neg_integer() | nil,
        input_cost: cost() | nil, output_cost: cost() | nil, total_cost: cost() | nil,
        tool_usage: map(), extra: map()
      }
```

- The new field goes in `defstruct` with default `nil`. `__from_tagged__/1` reads `data["cache_write_input_tokens"]`. A nil default makes the bare `data["key"]` read safe (CLAUDE.md `__from_tagged__` rule).
- **Registration:** `ALLM.EmbeddingBatch`'s `@summed_usage_fields` (`lib/allm/embedding_batch.ex:202-211`) gains `:cache_write_input_tokens`. The comment there says `test/allm/embedding_batch_test.exs` "fails if it is not" added to one of the two lists.
- **Invariant (cross-provider):** when both are integers, `cached_input_tokens + (cache_write_input_tokens || 0) <= input_tokens`. Falsifier: an adapter that leaves Anthropic's `input_tokens` exclusive reports `cached_input_tokens > input_tokens` on the AN-P1 recorded fixture.
- `nil` means the provider did not report the counter. `0` means it reported zero. Adapters never replace a missing wire field with `0`.

### `ALLM.Request` (Layer A) — 27.1

```elixir
@type prompt_cache :: nil | %{key: String.t() | nil, retention: :short | :long}

# added to @type t and defstruct:
prompt_cache: prompt_cache()      # default nil
```

- `Request.new/2` stays a `struct!/2` pass-through, with no runtime guard (CLAUDE.md Layer-A constructor rule). Shape discipline lives in `Validate.request/1`.
- `__from_tagged__/1` decodes with explicit clauses: `decode_prompt_cache(nil) -> nil`, `decode_prompt_cache(%{"key" => k, "retention" => r}) -> %{key: k, retention: decode_retention(r)}`, and `decode_prompt_cache(other) -> other`. The fallthrough mirrors `decode_response_format/1` (`request.ex:125-127,153`): a persisted partial map decodes without raising and `Validate` rejects it. `decode_retention/1` maps `"short" -> :short` and `"long" -> :long` and passes any other value through unchanged, so `Validate` rejects it. It never calls `String.to_atom/1`.
- **`:short`** means the provider's default lifetime, with no retention field sent. **`:long`** means the longest per-request lifetime the provider offers (Decision #9).

### `ALLM.Validate.request/1` — 27.1

New `validate_prompt_cache/2`, placed next to `validate_response_format/2` (`lib/allm/validate.ex:604-609`). It reuses the existing `:invalid_shape` atom (committed at `validate.ex:609`).

| Field path | Reason atom | Hard-reject? | Fires when |
|---|---|---|---|
| `:prompt_cache` | `:invalid_shape` | no | value is not `nil` and not a map with exactly the keys `:key` and `:retention` |
| `:prompt_cache` | `:invalid_shape` | no | `:key` is neither `nil` nor a non-empty binary |
| `:prompt_cache` | `:invalid_shape` | no | `:retention` is not `:short` or `:long` |

Errors use the existing flat `{field, reason}` accumulation shape (`validate.ex:609`). `validate_prompt_cache/2` adds exactly one `{:prompt_cache, :invalid_shape}`, even when several rows fail.

### Call-opt normalization — 27.4

`prompt_cache:` is accepted as a call opt and in `engine.params` (the precedence is `call opts > engine.params`, `Engine.resolve_params/2`). `Chat.build_request/4` normalizes the value it resolves:

| Input | Normalized `request.prompt_cache` |
|---|---|
| absent / `nil` / `false` | `nil` |
| `true` | `%{key: <session_id or nil>, retention: :short}` |
| map or keyword with `:key` and/or `:retention` (including `%{}` / `[]`, which behave like `true`) | missing `:retention` becomes `:short`; missing or nil `:key` becomes `opts[:session_id]` when that is a binary, else `nil`; any other keys are kept, so `Validate` rejects them (exactly-two-keys rule) |
| string-keyed map with `"key"` and/or `"retention"` (what a JSON round-tripped engine's `params` holds: `engine.ex:584-585` `restore_atom_keyed_map/1` restores top-level keys only) | converted to atom keys, `retention` through the same `decode_retention/1`, then treated as the row above |
| anything else | passed through unchanged, so `Validate.request/1` returns `{:error, %ValidationError{}}` (`stream_runner.ex:131`) |

- **Filter symmetry (DESIGN.md filter rule):** `:prompt_cache` is added to `@local_request_carried_keys` (`chat.ex:2064-2083`), because `build_request/4` consumes it into a typed field. The drift guard in `test/allm/chat_request_params_test.exs` folds a carried-key union through a real `chat/3` call and asserts that nothing reaches `request.options`. That union is a hand-written literal (`chat_request_params_test.exs:151-163`), so `:prompt_cache` must be added to it, together with `defp probe_value(:prompt_cache), do: true` (the fallthrough `:__probe__` would fail `Validate.request/1`).

### Adapter translation — 27.3

Each translation is a private helper that runs **before** the `Map.merge(stringify_options(request.options))` step (Decision #4). Its output is normative here and nowhere else:

| Adapter / endpoint | `prompt_cache: nil` | `%{key: k, retention: :short}` | `%{key: k, retention: :long}` |
|---|---|---|---|
| OpenAI `:chat_completions` | body unchanged | `"prompt_cache_key" => k` (omitted when `k` is nil) | same plus `"prompt_cache_retention" => "24h"` |
| OpenAI `:responses` | body unchanged | same as above | same as above |
| Anthropic | body unchanged | `"cache_control" => %{"type" => "ephemeral"}`; `k` is not sent | `"cache_control" => %{"type" => "ephemeral", "ttl" => "1h"}` |
| Gemini | body unchanged | body unchanged (Decision #8) | body unchanged |

- **Helper names follow the cross-provider alignment rule:** `put_prompt_cache/2` in every adapter. OpenAI's is `put_prompt_cache/2` over `(body, prompt_cache)` and is endpoint-independent, so it is called from both `to_openai_request_body/3` clauses (`openai.ex:1394`, `:1415`). It is one helper, not two, so the two translators cannot half-mirror (CLAUDE.md two-translators rule). Gemini gets no helper: a no-op helper is not written.
- Keys are sent verbatim. ALLM does not hash or transform them.

### Usage decoding — 27.2

A single shared mapping per adapter, used by both the streaming and the non-streaming decoder of that adapter:

| Adapter / endpoint | `input_tokens` | `cached_input_tokens` | `cache_write_input_tokens` | removed from `extra` |
|---|---|---|---|---|
| OpenAI Chat | `prompt_tokens` | `prompt_tokens_details.cached_tokens` | `prompt_tokens_details.cache_write_tokens` | `prompt_tokens_details` (the whole object, only when both of its keys above were read) |
| OpenAI Responses | `input_tokens` | `input_tokens_details.cached_tokens` | `input_tokens_details.cache_write_tokens` | `input_tokens_details` (same rule) |
| Anthropic | `input_tokens + cache_read + cache_creation` (nil when `input_tokens` is nil; each absent cache field counts 0) | `cache_read_input_tokens` | `cache_creation_input_tokens` | `input_tokens`, both cache keys; adds `"uncached_input_tokens"` = raw `input_tokens` |
| Gemini | `promptTokenCount` | `cachedContentTokenCount` | `nil` (not reported) | `cachedContentTokenCount` |

- **Correction to the "removed from `extra`" rule:** an object like `prompt_tokens_details` also carries `audio_tokens` and other keys (OA-6). The object stays in `extra` *minus* the two keys that were lifted. It is dropped only if it becomes empty. Nothing the provider sent is lost. Anthropic's `cache_creation` object (AN-10, the 5m/1h split) stays in `extra` untouched: `cache_write_input_tokens` already holds its sum, and the split matters only to cache-aware costing, which is out of scope.
- **One helper per adapter, shared by both paths.** Today OpenAI keeps two parallel shapes: `decode_usage/1` against `maybe_append_usage/3`, and `decode_responses_usage/1` against `responses_usage_events/1`. The comment at `openai.ex:1210-1211` reads:
  ```elixir
  # keys MUST be `%Usage{}` field names. Shape matches `decode_responses_usage/1`
  # so streaming and non-streaming paths produce identical `%Usage{}` structs.
  ```
  That comment promises equality by convention. 27.2 makes each streaming site call the non-streaming decoder and convert the struct with `Map.from_struct/1`, so equality holds by construction. Gemini calls `parse_usage/1` in `handle_usage_metadata/2` (`gemini.ex:1634-1645`) but re-projects only four fields (`input_tokens`, `output_tokens`, `total_tokens`, `extra`); 27.2 replaces that projection with `Map.from_struct(parse_usage(um))`, the same fix.
- **Anthropic streaming state:** the stream state map (built in `stream_start_fun/4`, `anthropic.ex:1438-1458`) gains `start_usage: nil`. The `message_start` clause stores `decoded["message"]["usage"]`. The `message_delta` clause computes `Map.merge(start_usage || %{}, Map.reject(delta_usage || %{}, fn {_, v} -> is_nil(v) end))` and runs the result through the shared `decode_usage/1`. It emits whenever either side is non-nil, including a `message_delta` with no `usage` key (today that clause emits nothing, `anthropic.ex:1690-1698`). If the stream ends without `message_delta`, no usage is emitted, as today.
- **Chat Completions streaming body:** in `do_stream/2`, after the existing `Map.put("stream", true)` at `openai.ex:762`, add `Map.put_new("stream_options", %{"include_usage" => true})` when `endpoint == :chat_completions` (Decision #7).

---

## Module Tree

```
lib/allm/
├── usage.ex                               (MODIFY — 27.1, add :cache_write_input_tokens; document inclusive input_tokens)
├── request.ex                             (MODIFY — 27.1, add :prompt_cache field + decode_prompt_cache/1 pair)
├── validate.ex                            (MODIFY — 27.1, validate_prompt_cache/2)
├── embedding_batch.ex                     (MODIFY — 27.1, register field in @summed_usage_fields)
├── chat.ex                                (MODIFY — 27.4, resolve/normalize :prompt_cache in build_request/4; add to @local_request_carried_keys)
├── allm.ex                                (MODIFY — 27.4, @doc for chat/3, stream/3, step/3, stream_step/3 lists prompt_cache:)
└── providers/
    ├── openai.ex                          (MODIFY — 27.0 model-family regexes; 27.2 usage decoders + include_usage; 27.3 put_prompt_cache/2)
    ├── anthropic.ex                       (MODIFY — 27.2 usage decode + stream start_usage; 27.3 put_prompt_cache/2)
    └── gemini.ex                          (MODIFY — 27.2 parse_usage/1; 27.3 @doc note only)

test/allm/
├── usage_test.exs                         (MODIFY — 27.1)
├── request_test.exs                       (MODIFY — 27.1)
├── validate_test.exs                      (MODIFY — 27.1)
├── embedding_batch_test.exs               (MODIFY — 27.1, summed-field fixture includes the new field)
├── chat_request_params_test.exs           (MODIFY — 27.4, add :prompt_cache to the carried-key literal + probe_value/1 clause)
├── prompt_cache_chat_test.exs             (NEW — 27.4, opt/param/session-id resolution over Fake)
├── prompt_cache_prefix_stability_test.exs (NEW — 27.4)
└── providers/
    ├── openai_test.exs                    (MODIFY — 27.0 dispatch/max-tokens/reasoning rows for gpt-6 ids)
    ├── openai_wire_test.exs               (MODIFY — 27.2 usage, 27.3 translation)
    ├── openai_stream_wire_test.exs        (MODIFY — 27.2 include_usage + streamed cache usage)
    ├── anthropic_wire_test.exs            (MODIFY — 27.2, 27.3)
    ├── anthropic_stream_wire_test.exs     (MODIFY — 27.2 start_usage merge)
    ├── gemini_wire_test.exs               (MODIFY — 27.2, 27.3)
    ├── gemini_stream_test.exs             (MODIFY — 27.2, extend the streaming ≡ non-streaming harness at :348-425)
    └── cache_usage_family_test.exs        (NEW — 27.2, table-driven streaming ≡ non-streaming usage per adapter)

test/fixtures/
├── openai/synthesized/cache_usage_chat.json          (NEW — 27.2, `_comment: "Synthesized — Phase 27.2"`)
├── openai/synthesized/cache_usage_chat_stream.sse    (NEW — 27.2)
├── openai/synthesized/cache_usage_responses.json     (NEW — 27.2)
├── openai/synthesized/cache_usage_responses.sse      (NEW — 27.2)
├── anthropic/synthesized/cache_usage.json            (NEW — 27.2)
├── anthropic/synthesized/cache_usage_stream.sse      (NEW — 27.2, message_start with cache fields + output-only message_delta)
├── anthropic/synthesized/cache_usage_stream_cumulative.sse (NEW — 27.2, message_delta repeating cache fields — AN-8)
├── gemini/synthesized/cache_usage.json               (NEW — 27.2)
├── openai/responses/recorded/prompt_cache_*.json     (NEW — 27.5, written by the recorder)
├── openai/chat_completions/recorded/prompt_cache_stream.sse (NEW — 27.5)
├── anthropic/messages/recorded/prompt_cache_*.{json,sse}    (NEW — 27.5)
└── gemini/generate_content/recorded/prompt_cache_*.json     (NEW — 27.5)

test/support/
├── cache_usage_fixtures.ex                (NEW — 27.2, thin table over the existing per-provider loaders + raw-bytes provenance helper; no duplicated loading code)
└── finch_stub.ex                          (MODIFY — 27.2, capture the %Finch.Request{} in both install modes; add captured_request/1)

scripts/
└── record_prompt_cache_fixtures.exs       (NEW — 27.3 `--only acceptance` arms; 27.5 completes the recording arms)

examples/
├── 28_prompt_cache.exs                    (NEW — 27.5)
└── README.md                              (MODIFY — 27.5, list example 28)

guides/sessions.md                         (MODIFY — 27.5, "Prompt caching" section)
steering/allm_engine_session_streaming_spec_v0_2.md  (MODIFY — 27.5, §5.4, §5.9a, §9 amendments)
CHANGELOG.md                               (MODIFY — 27.5)
```

- **Path check (run 2026-09-27):** these parent directories exist: `test/fixtures/{openai,anthropic,gemini}/synthesized/`, `test/fixtures/openai/{responses,chat_completions}/`, `test/fixtures/anthropic/messages/`, `test/fixtures/gemini/generate_content/`. The four `recorded/` subdirectories are new. Fixtures are `.json` / `.sse`, never `.exs` (CLAUDE.md wire-fixture rule).
- **Audit gates (DESIGN.md table):** no new public module, so `groups_for_modules` does not fire. No new guide file, so `package.files` / `@guides` do not fire. There is no new Layer-A struct (the fields are added to structs already in `@layer_a`, `test/layer_a_docs_test.exs:14-17`). There is no new `ALLM` facade function. **The one gate that fires:** new `@moduledoc` / `@doc` prose on `ALLM.Usage` and `ALLM.Request` is scanned by `test/layer_a_docs_test.exs` for banned tokens. Write it with no `§` and no `Phase N`.
- **`README.md` is not in this tree.** Stash it at phase start (`git stash push -- README.md`) if it is dirty (CLAUDE.md README rule). At build start, `git --no-optional-locks status --short` shows five pre-existing modified files outside this tree (`lib/allm/providers/{elevenlabs/transcription,fake_speech,openai/speech}.ex`, `test/support/{openai_fixtures,pcm}.ex`: the user's in-flight `binary-size(^…)` edits). They are not this phase's. Never stage them into a phase commit, and do not modify them. `test/support/openai_fixtures.ex` is why the 27.2 loader is a new module rather than an extension of the OpenAI loader.

---

## Phases

### 27.0 GPT-6 model-family routing (Layer B, refactor-first)

**Goal:** Every `gpt-6*` id, and any later `gpt-<N>` family, is treated like `gpt-5*` by the OpenAI adapter. The same change covers endpoint dispatch, the Chat Completions max-tokens field name and reasoning-control handling. Without this, 27.5's GPT-6 probe arms cannot run through ALLM.

**Contract:** the three regexes at `openai.ex:127-136` (`@endpoint_dispatch`'s `gpt-5` row, `@chat_completions_new_max_tokens_models`, `@chat_completions_reasoning_models`) match "gpt-5 and every later numbered family". One shared module attribute, for example `@gpt5_or_later ~r/^gpt-([5-9]|[1-9]\d)/i`, feeds all three, so a future `gpt-7` cannot be fixed in one table and missed in another. The `gpt-(4o|4\.1)` alternation in `@chat_completions_new_max_tokens_models` is kept. (Regex verified with `elixir` 1.17.3 on 2026-09-27: true for `gpt-5`, `gpt-5.6-luna`, `gpt-6-astra`, `gpt-6-sol`, `gpt-6-luna`, `gpt-10-x`; false for `gpt-4o`, `gpt-4.1`, `gpt-3.5-turbo`, `gpt-image-2`.) The docs table at `openai.ex:274` is updated in the same commit.

#### 27.0 Test Plan (write first)

- `openai_test.exs`: a table over `["gpt-5", "gpt-5.6", "gpt-5.6-luna", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna", "gpt-10-x"]` asserts `dispatch_endpoint/2 == :responses`. Falsifier: the pre-27.0 tree returns `:chat_completions` for the three gpt-6 ids (measured 2026-09-27).
- Negative rows: `["gpt-4o", "gpt-4.1", "gpt-3.5-turbo", "gpt-image-2"]` keep their current endpoints. Falsifier: an over-broad regex routes `gpt-4o` to Responses. `"gpt-image-2"` must not match, because the regex requires a digit after `gpt-`.
- With `endpoint: :chat_completions` forced by opts, a `gpt-6-sol` body uses `max_completion_tokens`, and `reasoning_effort: :low` survives onto the wire instead of being logged as ignored.
- Existing `gpt-5*` routing tests still pass unchanged. Run `git grep -n 'gpt-5' test/allm/providers/openai*_test.exs` and give every hit a keep disposition.

#### 27.0 Verification

```bash
mix test test/allm/providers/openai_test.exs test/allm/providers/openai_wire_test.exs
mix test && mix test --seed 0
mix credo --strict && mix dialyzer && mix format --check-formatted
```

### 27.1 Layer-A fields and validation (Layer A)

**Goal:** Add `Usage.cache_write_input_tokens` and `Request.prompt_cache`, both serializable and validated. No adapter reads them yet.

#### 27.1 Test Plan (write first)

- `usage_test.exs`: `Usage.new(cache_write_input_tokens: 5)` sets the field. A `%Usage{}` with **non-nil** values in every cache field round-trips through `:erlang.term_to_binary/1` and through `Jason.encode!/1 |> ALLM.Serializer.from_json/1`. Falsifier: a `__from_tagged__/1` missing the key returns `nil` for `5`.
- `request_test.exs`: `%Request{prompt_cache: %{key: "k", retention: :long}}` round-trips JSON with atom `:long` restored. Falsifier: the round-tripped value equals `%{key: "k", retention: "long"}`. `prompt_cache: nil` round-trips as `nil`.
- `validate_test.exs`: one test per row of the `Validate` table (3 rows, 2 inputs each: good and bad). A bad input returns `{:error, %ValidationError{}}` whose `errors` contain `{:prompt_cache, :invalid_shape}`. `%{key: nil, retention: :short}` validates `:ok`.
- `embedding_batch_test.exs`: the summed-field test includes `cache_write_input_tokens` across two chunks (e.g. `2 + 4 == 6`).

#### 27.1 Implementation Checklist

- [ ] Add the field, `@type`, moduledoc table row and inclusive-`input_tokens` sentence to `usage.ex`, per the `ALLM.Usage` contract.
- [ ] Add `prompt_cache` to `request.ex` (`@type`, `defstruct`, moduledoc table row, `decode_prompt_cache/1` + `decode_retention/1`).
- [ ] `validate_prompt_cache/2` in `validate.ex`, called from `request/1`'s pipeline (`validate.ex:96-107`).
- [ ] Register the field in `embedding_batch.ex` `@summed_usage_fields`.

#### 27.1 Verification

```bash
mix test test/allm/usage_test.exs test/allm/request_test.exs test/allm/validate_test.exs test/allm/embedding_batch_test.exs test/layer_a_docs_test.exs
mix test && mix test --seed 0
mix credo --strict && mix dialyzer && mix format --check-formatted
```

### 27.2 Cache-usage normalization (Layer B)

**Goal:** Every chat adapter reports cache reads and writes in the normalized fields on both paths, per the Usage decoding contract.

#### 27.2 Test Plan (write first)

All vehicles are synthesized fixtures through the existing wire-test seams, `Req.Test` for non-streaming and `test/support/finch_stub.ex` for streaming. The public decode seams `OpenAI.from_openai_response/2` (`openai.ex:1893`), `Anthropic.from_anthropic_response/2` and `Gemini.decode_response/2` (`gemini.ex:1001`) are the family test's non-streaming vehicle. Every new wire and family test passes the key per call (`api_key:`), never `ALLM.Keys.put/2` (CLAUDE.md process-global rule; pattern at `gemini_stream_wire_test.exs:22-33`). **Contract flip (DESIGN.md rule 9):** run `git grep -n 'extra' test/allm/providers/*usage* test/allm/providers/openai*_test.exs test/allm/providers/anthropic*_test.exs test/allm/providers/gemini*_test.exs | grep -iE 'cache|prompt_tokens_details|input_tokens_details|cachedContent'` and triage every hit as keep or flip. Any test that asserts a cache key sits in `usage.extra` becomes `(MODIFY — semantic change)`. Also triage every test asserting Anthropic `usage.input_tokens` on a fixture that carries cache fields (Decision #1).

- `cache_usage_family_test.exs`: a table with one row per `{adapter, endpoint}`: OpenAI Chat, OpenAI Responses, Anthropic, Gemini. Each row pairs a non-streaming fixture with a streaming fixture of the *same* counts. Assert:
  1. The non-streaming `response.usage` has `cached_input_tokens`, `cache_write_input_tokens` and `input_tokens` equal to the fixture's documented values (literal integers in the row, not recomputed by the helper under test).
  2. The streaming-collected `response.usage` equals the non-streaming one field-for-field, including `extra`. Falsifier: the pre-27.2 OpenAI Chat streaming path yields `cached_input_tokens: nil`.
  3. The invariant `cached + write <= input` holds.
- `anthropic_stream_wire_test.exs`:
  - `cache_usage_stream.sse` (output-only `message_delta`) yields `input_tokens == raw_input + read + creation`.
  - `cache_usage_stream_cumulative.sse` yields the same `%Usage{}`. Falsifier: double counting when both events carry the cache fields.
  - The existing `happy_text.sse` now yields `input_tokens: 10`, not `nil`. `(MODIFY — semantic change)` if an existing test asserts `nil`.
  - A `message_delta` carrying `"input_tokens": null` keeps `message_start`'s integer. A `message_delta` with no `usage` key still emits the `message_start` usage.
- `anthropic_wire_test.exs`: non-streaming `cache_usage.json` gives inclusive `input_tokens`, `total_tokens == input_tokens + output_tokens` (normalized), and `extra["uncached_input_tokens"] == raw`. A fixture with **no** cache fields gives `input_tokens` equal to the raw value, `cached_input_tokens: nil` and `cache_write_input_tokens: nil`. Falsifier: `0`s appear.
- `openai_stream_wire_test.exs`: decoding `FinchStub.captured_request(stub).body`, the Chat Completions streaming request body contains `"stream_options" => %{"include_usage" => true}`. With `request.options = %{stream_options: %{include_usage: false}}` the caller's value is sent. A Responses streaming body has **no** `stream_options` key.
- `openai_wire_test.exs`: `prompt_tokens_details` holding `audio_tokens` plus the two cache keys leaves `extra["prompt_tokens_details"] == %{"audio_tokens" => n}`.
- `gemini_wire_test.exs` / `gemini_stream_test.exs`: `cachedContentTokenCount` becomes `cached_input_tokens`, `cache_write_input_tokens` is `nil`, and the key no longer appears in `extra`. The streamed value is non-nil. Falsifier: today's four-key `pre_mapped` projection in `handle_usage_metadata/2` drops it.

#### 27.2 Implementation Checklist

- [ ] OpenAI: lift the cache keys in `decode_usage/1` and `decode_responses_usage/1`. Make `maybe_append_usage/3` and `responses_usage_events/1` build their payloads *from* those decoders (the Usage decoding contract's "one helper" rule).
- [ ] OpenAI: add `stream_options` with `put_new` in `do_stream/2` for `:chat_completions` only.
- [ ] Anthropic: inclusive `decode_usage/1`, `start_usage` stream state, a single emission from `message_delta`.
- [ ] Gemini: lift `cachedContentTokenCount` in `parse_usage/1`, and change `handle_usage_metadata/2` (`gemini.ex:1634-1645`) to emit `Map.from_struct(parse_usage(um))` instead of its four-key `pre_mapped` map, which drops every other field.
- [ ] `test/support/finch_stub.ex`: store the `%Finch.Request{}` in both install modes and expose `captured_request/1`.
- [ ] Add the synthesized fixtures, each with a leading `_comment` naming Phase 27.2 (`.sse` files open with the lowercase comment line `: synthesized — Phase 27.2 …`, matching `test/fixtures/openai/synthesized/usage_chunk.sse:1`), and the `test/support/cache_usage_fixtures.ex` loader.
- [ ] Update each generate/2 `@doc` that describes usage fields, in all three adapters, and `OpenAI.stream/2`'s `@doc` for the injected `stream_options` default (Decision #7).

#### 27.2 Verification

```bash
mix test test/allm/providers/
mix test && mix test --seed 0
mix credo --strict && mix dialyzer && mix format --check-formatted
```

### 27.3 Adapter translation of `prompt_cache` (Layer B)

**Goal:** A `%Request{prompt_cache: ...}` sent directly to an adapter produces the wire fields in the Adapter translation table, and nothing else changes.

#### 27.3 Test Plan (write first)

- For each of the 4 adapter/endpoint rows × 3 columns in the Adapter translation table, one wire test asserts the exact added keys. Headcount: 4 × 3 = 12 cells, programmatic in a `for` comprehension over the table literal.
- **Byte-identical opt-out:** for each adapter/endpoint, `Jason.encode!(body)` with `prompt_cache: nil` equals the same encoding built from a request constructed without the field at all. Falsifier: any helper that writes `nil`-valued keys.
- **Raw options win (Decision #4):** `prompt_cache: %{key: "a", retention: :short}` plus `options: %{prompt_cache_key: "b"}` puts `"b"` on the OpenAI wire, asserted on **both** `:chat_completions` and `:responses` bodies. The same with `options: %{cache_control: %{type: "ephemeral", ttl: "5m"}}` on Anthropic sends the raw map.
- **Key sent verbatim:** a key with mixed case, spaces and non-ASCII (e.g. `"Recipe 42/é"`) appears byte-for-byte as `"prompt_cache_key"` on both OpenAI endpoints. Falsifier: any hashing, trimming or downcasing.
- `key: nil` with `:short` on OpenAI adds no key at all. Falsifier: `"prompt_cache_key" => nil` in the body.
- The Anthropic request never carries the key string anywhere in the encoded body (`refute body_json =~ "recipe-42"`). This is the privacy half of Decision #3.
- **Direct-adapter invalid shape (Error Contract):** `prompt_cache: :bogus` sent straight to each adapter's body builder leaves the body byte-identical to the `nil` case.

#### 27.3 Implementation Checklist

- [ ] `put_prompt_cache/2` in `openai.ex`, called from both `to_openai_request_body/3` clauses before the options merge.
- [ ] `put_prompt_cache/2` in `anthropic.ex`, called in `to_anthropic_request_body/1` before the options merge.
- [ ] Gemini: `@doc` note on `generate/2` (Decision #8). No code change.
- [ ] Create `scripts/record_prompt_cache_fixtures.exs` with at least its `--only acceptance` mode (the OA-P1, OA-P2 and AN-P2 arms, no fixture writes). 27.5 completes the rest of the recorder.
- [ ] Document in each adapter's `generate/2` `@doc` the retention value it sends. This parallels the CLAUDE.md "adapters MUST document injected defaults" rule.

#### 27.3 Verification

```bash
mix test test/allm/providers/openai_wire_test.exs test/allm/providers/anthropic_wire_test.exs test/allm/providers/gemini_wire_test.exs
set -a; . ./.env; set +a; mix run scripts/record_prompt_cache_fixtures.exs --only acceptance   # OA-P1/OA-P2 (+ AN-P2) live acceptance, no fixtures written; Decision #9 escalation point
mix test && mix test --seed 0
mix credo --strict && mix dialyzer && mix format --check-formatted
```

### 27.4 Chat/Session wiring and prefix stability (Layer C)

**Goal:** `prompt_cache:` set on the engine or the call reaches `%Request{}`. The key defaults to the session id. A test pins the append-prefix property that makes caching work across turns.

#### 27.4 Test Plan (write first)

The test vehicle is `ALLM.Providers.Fake` with `adapter_opts: [script: ..., record: self()]`. Fake sends `{:allm_fake_record, %Request{}, opts}` before interpreting the script (`lib/allm/providers/fake.ex:228-232`), and the tests assert on it as `test/allm/chat_request_params_test.exs:48-51` `recorded_request/0` does. No wrapper adapter.

| Case | Setup | Expected `request.prompt_cache` | Path |
|---|---|---|---|
| R1 | no opt anywhere | `nil` | chat/3 **and** stream/3 |
| R2 | `engine.params.prompt_cache = %{retention: :long}`, call `session_id: "s1"` | `%{key: "s1", retention: :long}` | both |
| R3 | engine param as R2, call `prompt_cache: %{key: "x"}` | `%{key: "x", retention: :short}` (call opts win) | both |
| R4 | `prompt_cache: true`, no session_id | `%{key: nil, retention: :short}` | both |
| R5 | `prompt_cache: :bogus` | `{:error, %ValidationError{}}` with `{:prompt_cache, :invalid_shape}` | both |
| R6 | `Session.reply/4` on `%Session{id: "sess-9"}` with engine param `prompt_cache: true` | `%{key: "sess-9", retention: :short}` | reply **and** stream_reply |
| R7 | R6 with `%Session{id: nil}` | `%{key: nil, retention: :short}` | reply and stream_reply |
| R8 | engine with `params.prompt_cache = %{retention: :long}` → `ALLM.Serializer.to_json!/1` → `from_json/1`, then call `session_id: "s1"` | `%{key: "s1", retention: :long}` | chat/3 |
| R9 | `prompt_cache: %{key: "x", foo: 1}` | `{:error, %ValidationError{}}` with `{:prompt_cache, :invalid_shape}` | chat/3 |
| R10 | `ALLM.step/3` and `stream_step/3` with the R2 setup | as R2 | step and stream_step |

- `chat_request_params_test.exs`: the carried-key drift guard passes with `:prompt_cache` added to its literal union (`:151-163`) and `probe_value(:prompt_cache)` returning `true`. Add an explicit assertion that `request.options` has no `:prompt_cache` key under R2.
- **`prompt_cache_prefix_stability_test.exs`**:
  - Drive a Session through three turns over Fake: plain text, then a tool call with its tool result, then plain text.
  - After each turn, take `session.thread.messages` and build a request body with each of the four translators: `OpenAI.to_openai_request_body/3` for `:chat_completions` and `:responses`, `Anthropic.to_anthropic_request_body/1`, and `Gemini.to_gemini_request_body/2`. Use the same tools and `prompt_cache: %{key: "s", retention: :long}`.
  - Assert for each consecutive pair (N, N+1) and each translator:
    - (a) the body with the message-array key removed is byte-identical after `Jason.encode!/1`;
    - (b) the decoded message array of N is an element-wise prefix of N+1's.
  - The bodies are built from **separately constructed** requests. The same term is never compared with itself.
  - Named falsifier: a negative-control test in the same file injects a translator wrapper that stamps the current turn index into the system text. It asserts that the helper under test *reports* the violation.
  - Measured on the current tree: for all four translators, (a) and (b) hold for every append step of an 8-message thread with a tool round trip. That measurement was a `mix run` script on 2026-09-27 against `94ffa45`; every pair returned `{n, true, true}`. So this test is expected green at 27.4. It is a regression pin, not a bug hunt.

**Security note:** with `prompt_cache` on, `session.id` becomes a value sent to OpenAI. It is never an API key and never a URL component (CLAUDE.md WebSocket/URL rule, applied to HTTP bodies). The `@moduledoc` "`session_id` propagation" section of `ALLM.Session` gains one sentence: callers whose ids carry personal data should pass an explicit `prompt_cache: %{key: ...}`.

#### 27.4 Implementation Checklist

- [ ] `build_request/4`: read `:prompt_cache` from the resolved params map (not `Keyword.get(opts, …)`, so engine params apply). Normalize it per the Call-opt normalization table and set it on `Request.new/2`.
- [ ] Add `:prompt_cache` to `@local_request_carried_keys` (`chat.ex:2063-2079`).
- [ ] `@doc` for `ALLM.chat/3`, `stream/3`, `step/3` and `stream_step/3` in `lib/allm.ex` (and a sentence on `generate/3` / `stream_generate/3`: set `Request.prompt_cache` directly), plus the `ALLM.Session` moduledoc sentence.
- [ ] Add `:prompt_cache` to the literal carried-key list and a `probe_value/1` clause in `chat_request_params_test.exs`.
- [ ] The two new test files.

#### 27.4 Verification

```bash
mix test test/allm/prompt_cache_chat_test.exs test/allm/prompt_cache_prefix_stability_test.exs test/allm/chat_request_params_test.exs
mix test && mix test --seed 0
mix credo --strict && mix dialyzer && mix format --check-formatted
```

### 27.5 Live probe, example, docs (live gate)

**Goal:** Every Probe row in the Wire-field map is asserted against the live API and its body recorded. Cook mode's usage pattern runs end to end in an example. Users can find the feature.

#### 27.5 Recorder: `scripts/record_prompt_cache_fixtures.exs`

The four CLAUDE.md probe parts, modelled on `scripts/record_voyage_embeddings_fixtures.exs:1-60`:

1. **Overwrite guard first.** Check every target path. A fully recorded tree makes zero HTTP calls.
2. **Load `.env` first:** `EnvLoader` guarded, as in the Voyage script. Invocation: `set -a; . ./.env; set +a; mix run scripts/record_prompt_cache_fixtures.exs`.
3. **Assert, don't narrate.** Each arm declares its expected status and, for repeat arms, `cached > 0`. Any mismatch prints a want/got table to stderr and calls `System.halt(1)` before any fixture is written.
4. **Record the body** of every arm whose shape a fixture asserts, error envelopes included.

A shared prefix of about 5,000 tokens, which clears every minimum (OA-5, AN-4, G-2), is built in the script from repeated recipe text, opened by a per-run nonce (`System.unique_integer/1` plus a timestamp) so every run's first call is a cache write, even when an earlier run within the hour wrote the same text with a 1h TTL. The script supports `--only acceptance` (the OA-P1, OA-P2 and AN-P2 arms, no fixture writes), which 27.3 runs. **Repeat arms** send the identical request up to 3 times, 2 s apart, and pass when any call after the first reports `cached > 0`. Hits are best-effort (Assumption 2); three misses halt.

| Arm | Provider / model (env-overridable) | Request | Expect | Records |
|---|---|---|---|---|
| OA-P1 | OpenAI `gpt-5.6`, `gpt-6-luna` **and** `gpt-5.4-nano` (the examples default), Responses | prefix + `prompt_cache_key` | 200 | — |
| OA-P2 | OpenAI `gpt-5.6`, `gpt-6-luna` **and** `gpt-5.4-nano`, Responses | + `prompt_cache_retention: "24h"` | 200 (else escalate, Decision #9) | — |
| OA-P4 | OpenAI `gpt-5.6` **and** `gpt-6-luna`, Responses | repeat with key | `input_tokens_details.cached_tokens > 0` | `openai/responses/recorded/prompt_cache_hit.json` (gpt-5.6), `prompt_cache_hit_gpt6.json` (gpt-6-luna) |
| OA-P6 | OpenAI `gpt-6-luna`, through `ALLM.generate/3` (not a raw request), twice: default dispatch, then `endpoint: :chat_completions`. The engine is built directly, not via `_helpers.exs` (whose `params` set `temperature: 0`) | plain request with `max_tokens: 64` | 200 both times; proves 27.0's routing and `max_completion_tokens` field against the live API | — |
| OA-P5 | OpenAI `gpt-5.4-nano`, Chat, stream | repeat with `include_usage` | final chunk `prompt_tokens_details.cached_tokens > 0` | `openai/chat_completions/recorded/prompt_cache_stream.sse` |
| OA-C | OpenAI `gpt-5.6`, Responses | `totallyNotAField: {}` | 400 | `openai/responses/recorded/prompt_cache_unknown_field.json` |
| AN-P1 | Anthropic `claude-haiku-4-5-20251001`, `claude-sonnet-5` **and** `claude-sonnet-4-6` (the examples default) | top-level `cache_control: {type: ephemeral}`, repeat | first call `cache_creation > 0`, a later call `cache_read > 0`, no beta header (AN-5) | `anthropic/messages/recorded/prompt_cache_hit_<model>.json`, one per model |
| AN-P2 | Anthropic, same models | top-level `cache_control` with `ttl: "1h"` | 200 | — |
| AN-P3 | Anthropic, same model, stream | repeat of AN-P1 | `message_start.message.usage.cache_read_input_tokens > 0` | `anthropic/messages/recorded/prompt_cache_stream.sse` |
| AN-C | Anthropic | `totallyNotAField: {}` | 400 | `anthropic/messages/recorded/prompt_cache_unknown_field.json` |
| GE-P1 | Gemini `gemini-3-flash-preview` | repeat, no cache field | `usageMetadata.cachedContentTokenCount > 0` | `gemini/generate_content/recorded/prompt_cache_hit.json` |
| GE-C | Gemini (informational, G-C) | top-level `totallyNotAField: {}` | 400 | `gemini/generate_content/recorded/prompt_cache_unknown_field.json` |

- Tests that consume the recorded fixtures are added to `cache_usage_family_test.exs`. For each recorded response body, the decoded `%Usage{}` satisfies `cached + write <= input` (the Decision #1 falsifier on real data).
- **Negative provenance, one test per recorded fixture:** `File.read!/1 |> Jason.decode!/1` then `refute Map.has_key?(raw, "_comment")`, with a failure message naming the recorder invocation. `.sse` files are checked with `refute raw =~ ~r/^:\s*synthesized/im` (CLAUDE.md recorded-fixture rule; the existing marker is lowercase).
- **Model names are env-overridable** (`ALLM_PROBE_OPENAI_MODELS`, `ALLM_PROBE_ANTHROPIC_MODELS`, comma-separated). The defaults above cover the current cook-mode candidates (gpt-5.6, gpt-6-luna, claude-sonnet-5) plus the models the example gate runs (`gpt-5.4-nano`, `_helpers.exs:101`; `claude-sonnet-4-6`, `_helpers.exs:118`). Probe requests are raw bodies built in the script, except OA-P6, and none sends `temperature` (AN-11).
- **Cost:** the prefix is about 5k input tokens. Counting repeats, there are about 11 OpenAI, 12 Anthropic and 5 Gemini calls, so about 140k input tokens in total, most of them cached reads after the first call per model. gpt-6-luna is $0.10/MTok input and claude-sonnet-5 is the most expensive arm (writes at 1.25× input, AN-10). The estimate is **about $0.25 per clean run** and **$0.50–1.00 for first implementation** (2–4×). gpt-5.6 and claude-sonnet-5 list prices are UNVERIFIED here. The implementer report cites actuals (DESIGN.md rule 19).

#### 27.5 Example, docs, spec

- **`examples/28_prompt_cache.exs`:**
  - Build a provider-neutral engine via `_helpers.exs` with `params: %{prompt_cache: %{retention: :long}}`.
  - Run a `Session` with an id and a roughly 5k-token system prompt through two replies.
  - Print `result.final_response.usage.input_tokens`, `cached_input_tokens` and `cache_write_input_tokens` per turn (`%ChatResult{}` has `:final_response`, not `:response`).
  - `System.halt(1)` if turn 2 reports `cached_input_tokens` of `nil` on OpenAI or Anthropic. On Gemini, `nil` is allowed when no hit occurred (G-3).
  - Listed in `examples/README.md`.
  - BLOCKING gate: `ALLM_PROVIDER=<p> mix run examples/run_all.exs` for openai, anthropic and gemini. A blocked arm is re-characterized script by script (CLAUDE.md live-gate rule). `RUN_OUTPUT_*.md` is regenerated only in the same commit as a full green run.
- **`guides/sessions.md` "Prompt caching" section:**
  - An `iex>` block showing `Request.new(..., prompt_cache: ...)`, `Validate.request/1` and a `%Usage{}` with cache fields.
  - One ` ```elixir ` fence showing the cook-mode engine. It must compile under `scripts/check_guide_fences.exs`.
  - A short per-provider behaviour list citing only the Wire-field map rows that 27.5 moved to Confirmed.
  - No `§` or `Phase` tokens (`mix run scripts/audit_user_docs.exs guides/sessions.md` → 0 hits).
- **Spec amendments to §5.4, §5.9a and §9,** each opening with `> **Phase 27 amendment (commits <first>..<last>).**`.
- **CHANGELOG:** derived from `git diff <prior-tag>..HEAD lib/` (CLAUDE.md release rule). It names Decision #1 as a behaviour change for Anthropic `input_tokens`, and Decision #7's new wire key.
- **Sweep:** the `[CARRY]` / ticket search is `grep -n 'prompt_cache\|cached_input\|cache_control' .work/ASKS.md`. It returns two hits at design time (the ask this design answers, and its `[DSGN]` entry). Anything it finds after the design locks is filed, per DESIGN.md rule 32.

#### 27.5 Verification

```bash
set -a; . ./.env; set +a; mix run scripts/record_prompt_cache_fixtures.exs     # exit 0, all arms asserted
set -a; . ./.env; set +a; mix run scripts/record_prompt_cache_fixtures.exs     # second run: zero HTTP calls
mix test test/allm/providers/cache_usage_family_test.exs test/guides_test.exs test/guides_doctest_test.exs
mix run scripts/check_guide_fences.exs | head -1
for p in openai anthropic gemini; do ALLM_PROVIDER=$p mix run examples/run_all.exs || echo "ARM $p FAILED"; done
mix test && mix test --seed 0
mix credo --strict && mix dialyzer && mix format --check-formatted
```

---

## Adjacent findings (not in this design's scope)

These came out of the 2026-09-27 model research. They do not block caching, and 27.5's sweep files each as an `ASKS.md` ticket naming the grep that proves it fixed:

1. **Anthropic 5-series rejects non-default sampling parameters.** `claude-sonnet-5`, `claude-opus-5` and `claude-fable-5-1` return 400 for any non-default `temperature` (AN-11). The Anthropic adapter forwards whatever is set (`anthropic.ex:544`), and `examples/_helpers.exs:214-221` sets `params: %{temperature: 0}` by default. So the examples break the moment the Anthropic row's `default_model` moves to a 5-series model. Today it is `claude-sonnet-4-6` (`_helpers.exs:118`), which is unaffected. Cook mode must not set `temperature` on these models.
   > CORRECTED 2026-09-27 (27.5 sweep): ANY `temperature` fails on claude-sonnet-5, `0` included (raw request → 400 "`temperature` is deprecated for this model."), and `_helpers.exs` sets `temperature: 0`, so the chat/Session examples already fail when `ALLM_MODEL=claude-sonnet-5` (`examples/08_session_round_trip.exs` exit 1). `examples/01_plain_text.exs` passes only because `generate/3` never reads `engine.params`. Filed as a `[BUG]` in `.work/ASKS.md`; the same holds for `gpt-6-astra` (finding 2, filed separately).
2. **`gpt-6-astra` rejects custom `temperature` / `top_p` and `reasoning_effort: :none`** (OA-8). 27.0 routes it correctly, but ALLM still forwards a caller's `temperature`. The same examples default applies.

## Error Contract

| Function | Error | Recovery |
|---|---|---|
| `ALLM.chat/3`, `stream/3`, `generate/3`, `Session.*` | `{:error, %ValidationError{errors: [{:prompt_cache, :invalid_shape}]}}` (pre-flight, `stream_runner.ex:131`) | Fix the option shape. Not retryable. |
| Direct adapter call with an invalid `prompt_cache` | No pre-flight validation (CLAUDE.md: capability and validation gates live in the runner). `put_prompt_cache/2` pattern-matches only the valid shapes and leaves the body unchanged otherwise. | Call through the facade for validation. |
| Provider rejects a translated field (e.g. OA-P2 fails on some model) | Surfaces as today's adapter 400 → `%AdapterError{reason: :invalid_request}` | 27.5 probe exists to catch this before release. |

No new reason atoms.

## Definition of Done

- [ ] 27.1–27.5 Verification blocks green, with exit codes pasted in `_RECORDS.md`.
- [ ] Every Probe row in the Wire-field map is Confirmed by a recorded fixture, or escalated; the per-row outcome is recorded in `_RECORDS.md`.
- [ ] Streaming ≡ non-streaming usage holds for every row of `cache_usage_family_test.exs`, with no relaxations.
- [ ] Coverage ≥ 90% on new code; `mix credo --strict`, `mix dialyzer` and `mix format --check-formatted` are clean.
- [ ] CHANGELOG flags the Anthropic `input_tokens` semantic change.
- [ ] Live example gate green on all three providers, or deferred per the CLAUDE.md blocked-arm rule with the per-script line.
