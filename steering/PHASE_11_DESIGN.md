# Phase 11: Anthropic Provider Adapter — Design Document

> **Goal:** Ship `ALLM.Providers.Anthropic` implementing both `ALLM.Adapter` (Messages API over `Req`) and `ALLM.StreamAdapter` (Messages API SSE over `Finch` HTTP/1) against `POST /v1/messages`, normalizing Anthropic's wire shapes onto ALLM's canonical types, reusing the `ALLM.Providers.Support.SSE` helper from Phase 10.1 verbatim, integrating with `ALLM.Retry` (Phase 9.3) for non-streaming retries (including the Anthropic-specific `529 Overloaded` status), and implementing **structured output via the tool-forcing pattern** (spec §5.4) — a synthetic `respond_with_json` tool injected whenever the caller requests `response_format: %{type: :json_schema, ...}` so Claude is forced to emit the schema-shaped JSON as a tool call.
> **Outcome:** A library user with a valid `ANTHROPIC_API_KEY` can construct `ALLM.Engine.new(adapter: ALLM.Providers.Anthropic, model: "claude-sonnet-4-6")` and call every public Layer-C entry point (`ALLM.generate/3`, `ALLM.stream_generate/3`, `ALLM.step/3`, `ALLM.stream_step/3`, `ALLM.chat/3`, `ALLM.stream/3`) plus `ALLM.Session` against the real Anthropic Messages API and receive correctly-typed results. The Phase 10.5 `examples/openai/` directory is migrated up to a **provider-neutral `examples/` framework** (sub-phase 11.4) — the same nine numbered scripts run against either provider via `ALLM_PROVIDER=openai|anthropic mix run examples/<name>.exs`; assertions are tight (per the Phase 10 Q2 philosophy — `temperature: 0`, hard-steered system prompts, explicit `tool_choice` forcing) so `examples/run_all.exs` is a deterministic regression bar suitable as the BLOCKING `/review` validation step (run twice — once per provider). Recorded fixtures cover the wire shape via `Req.Test.stub/1` (non-streaming) and `ALLM.Test.FinchStub` (streaming, the Phase 10.3 helper, reused unchanged) so the full bar runs offline in CI. `mix test`, `mix credo --strict`, `mix dialyzer`, `mix format --check-formatted` all green; ≥ 90 % coverage on every new file. A live-provider smoke test gated on `ANTHROPIC_API_KEY` (skipped in CI by default via `@tag :live_anthropic` + extending the existing exclude list to `[:pending, :live_openai, :live_anthropic]`) exercises one happy-path call per shape.
> **Spec sections:** §5.1 (`ALLM.Message` — system role extraction), §5.4 (`response_format` canonical shape — tool-forcing pattern for `:json_schema`), §6.4 (key resolution at adapter-call time — `:anthropic` already in `lib/allm/keys.ex:48`), §7.1 (`ALLM.Adapter` callbacks: `generate/2`, `prepare_request/2`, `translate_options/2`), §7.2 (`ALLM.StreamAdapter.stream/2` + HTTP/1 streaming guidance), §8 (event protocol), §10.1 (mid-stream errors fold into Response), §20 (error model — every `AdapterError` reason atom mapped including the Anthropic-specific `529 Overloaded` status), §29 (telemetry — `[:allm, :adapter, :retry]`), §32.1 (initial bundled adapters — Anthropic Messages API), §33 (vision rejection — image content parts).
> **Layers touched:** **B (single layer).** Every new module is Layer B. Zero Layer A struct field additions. Zero Layer C / D code changes — the adapter plugs into existing entry points via the existing behaviour contracts. Zero spec amendments — every wire-shape choice is bounded by the spec sections cited above. Examples under `examples/anthropic/` are runnable scripts (no `lib/` or `test/` files); they consume the public Layer C / D API only.
> **Phasing doc:** [`PROJECT_PHASING.md`](PROJECT_PHASING.md) Phase 11.

## Status

| Sub-phase | Description | Layer | Status |
|-----------|-------------|-------|--------|
| 11.1 | `ALLM.Providers.Anthropic` non-streaming `Adapter` impl (`generate/2`, `prepare_request/2`, `translate_options/2`); `to_anthropic_request_body/1` extracts system messages to top-level `system:`; key resolution via `ALLM.Keys.fetch!(:anthropic, opts)`; `x-api-key` + `anthropic-version: 2023-06-01` headers; stop_reason mapping; full `AdapterError` reason mapping including 529; `ALLM.Retry.run/3` integration | B | Not Started |
| 11.2 | `ALLM.Providers.Anthropic` streaming `StreamAdapter` impl (`stream/2`); reuses `ALLM.Providers.Support.SSE` and `ALLM.Test.FinchStub` from Phase 10; SSE chunk → `ALLM.Event` mapping (named events: `message_start`, `content_block_start`, `content_block_delta` with `delta.type ∈ {text_delta, input_json_delta}`, `content_block_stop`, `message_delta`, `message_stop`, `ping`); `Stream.resource/3` cleanup with bounded-time cancellation | B | Not Started |
| 11.3 | Structured output via tool-forcing pattern: `to_anthropic_request_body/1` injects a synthetic `respond_with_json` tool (named-via-schema-name) when `response_format: %{type: :json_schema, ...}` is set; `tool_choice: {:tool, "respond_with_json"}` forces the model to use it; the response decoder lifts the tool-call's `arguments` map back to `Response.output_text` (JSON-encoded) and `finish_reason: :stop`; `requires_structured_finalize?/1` returns `false` so the Phase 10.4 two-pass branch is skipped | B | Not Started |
| 11.4 | **Unify the existing `examples/openai/` directory into a provider-neutral `examples/` framework.** Migrate the nine scripts from `examples/openai/` up to `examples/`; introduce `examples/_helpers.exs` with a provider table (`%{"openai" => {...}, "anthropic" => {...}}`); each script reads `ALLM_PROVIDER` env var (default `"openai"`) and constructs the engine through the helper; `run_all.exs` runs the unified set against `ALLM_PROVIDER`; `/review` runs `run_all.exs` twice (once per provider). Adds the `:anthropic` row + targets `claude-sonnet-4-6`. | B | Not Started |

**Overall Progress:** 0/4 sub-phases complete

## Overview

Phase 11 is the **second real provider adapter**, landing on top of every infrastructure piece Phase 10 settled: `ALLM.Providers.Support.SSE` (the line-buffered SSE decoder; reused verbatim), `ALLM.Test.FinchStub` (the streaming-test seam; reused verbatim), `ALLM.Finch` (the default HTTP/1 pool, started by `ALLM.Application` in Phase 10.1), `ALLM.Retry.run/3` (the spec §6.1 retry helper), `ALLM.Capability.preflight/2` (whose three-shape contract widening from Phase 10.4 is consumed unchanged), and the `examples/openai/`-style runnable-script template (per Phase 10 Q2 — examples-as-validation, not examples-as-documentation).

The phase's load-bearing correctness obligation, like Phase 10's, is **shape coverage of every `AdapterError` / `StreamError` reason atom against the real Anthropic wire format.** Per the Phase 10 Q1 decision (2026-04-26), the Phase 3 conformance harnesses are NOT reused for real adapters; the equivalent shape-coverage bar lives in `anthropic_wire_test.exs` (14 rows, parity with `openai_wire_test.exs`) and `anthropic_stream_wire_test.exs` (13 rows, parity with the OpenAI streaming matrix). Each row's documentation cites the specific Anthropic API doc page or HTTP-status family it models.

The phase's second obligation is **system-message extraction is the single non-identity transformation in `to_anthropic_request_body/1`.** Anthropic's Messages API does NOT accept `{role: "system", content: "..."}` items inside the `messages:` array — the system prompt is a top-level `system:` parameter. The Phase 11 adapter walks the thread, partitions out system-role messages, and concatenates their `content` strings (joined by `\n\n` for multi-message threads — verified against Anthropic's documented behaviour for repeated system messages where applications intend "concatenate"). The extraction is a one-line `Enum.split_with/2` followed by a `system: extracted_text` injection into the request body. **This is the only structural divergence from OpenAI's request shape**; everything else (`messages: [...]`, `tools: [...]`, `tool_choice: ...`, `temperature:`, `max_tokens:`) is shape-equivalent modulo key naming.

The phase's third obligation is **structured output uses the tool-forcing pattern, NOT a two-pass dance.** Spec §5.4 names this explicitly: "Anthropic: prepends a tool-forcing pattern (no native schema enforcement)". Per Phase 10's Decision #14, `requires_structured_finalize?/1` is the capability declaration consumed by `ALLM.Capability.preflight/2`; the Phase 11 adapter implements it returning **`false`** because Anthropic does NOT need the OpenAI-style two-pass dance — the tool-forcing pattern handles structured output in a single round-trip. When `request.response_format` matches `%{type: :json_schema, name: n, schema: s, strict: b}`, `to_anthropic_request_body/1` injects a synthetic tool `%{name: "respond_with_json_#{n}", description: "Return the final result as a JSON object matching the schema.", input_schema: s}` into the `tools:` array AND sets `tool_choice: %{type: "tool", name: "respond_with_json_#{n}"}`. Claude is forced to emit a `tool_use` content block whose `input` (the JSON Schema-conforming map) IS the structured response. The decoder lifts that `input` back to `Response.output_text` (`Jason.encode!/1` of the map) and sets `finish_reason: :stop` instead of `:tool_calls` — the caller sees a structured-output response indistinguishable from OpenAI's `:json_schema` path. (Note: Anthropic shipped a beta `output_config` parameter for native structured output in late 2025 per the SDK helpers, but it remains beta-gated and the tool-forcing pattern is the spec-mandated approach for v0.2; see Decision #5.)

The phase's fourth obligation is **streaming uses `Finch` directly with HTTP/1, NEVER `Req`.** Spec §7.2 + Phase 10.3 + the published `req_llm` issue: HTTP/2 flow control breaks for request bodies >64 KB (Anthropic's threads-with-history can easily exceed this). The `Finch.async_request/3` shape from Phase 10.3 (the `{ref, payload}` 2-tuple message format with `^ref`-pinned receive clauses, `state.done`-gated `cancel_async_request/1`) is consumed unchanged. The default Finch ref is `ALLM.Finch` (started by Phase 10.1 in `ALLM.Application` with `protocol: :http1`); engines may inject a custom name via `adapter_opts: [finch_name: MyApp.Finch]`.

The phase's fifth obligation is **API keys never appear on the engine.** Spec §6.4 + Phase 2 + Phase 10. Both `generate/2` and `stream/2` call `ALLM.Keys.fetch!(:anthropic, opts)` at request-build time (`:anthropic` is already in the env-var table at `lib/allm/keys.ex:48`). The `x-api-key: <key>` header is constructed inside `prepare_request/2` and `build_finch_request/3`. Anthropic also requires `anthropic-version: 2023-06-01` (the stable API version baseline; `2023-06-01` covers all v0.2 features including streaming + tool use); the version string is a module attribute `@anthropic_version "2023-06-01"` so it's bumped in one place when needed. The Phase 11 serializability test (an extension row in `engine_roundtrip_test.exs`) confirms no key-shaped string survives `:erlang.term_to_binary/1` round-trip on an Anthropic-engine.

The phase's sixth obligation is **all retries route through `ALLM.Retry.run/3` (Phase 9.3); no second retry layer.** The Anthropic adapter's retry closure parses the documented set: `429 Too Many Requests` (rate limit), `500 Internal Server Error`, `502 Bad Gateway`, `503 Service Unavailable`, `504 Gateway Timeout`, **and `529 Overloaded`** (Anthropic-specific — applied to the `retry_on` set in the adapter's closure). The default policy from Phase 9.3 (`max_attempts: 3`, jitter, `Retry-After` honored) is used unchanged; Anthropic's `Retry-After` header parses identically to OpenAI's. Streaming never retries — `stream/2` does not wrap in `ALLM.Retry.run/3`; the streaming-no-retry assertion is a meta-row in `anthropic_stream_wire_test.exs`.

The phase's seventh obligation is **stop_reason normalization is total** (every documented Anthropic string maps; unknowns map to `:other` with the raw string preserved on `Response.raw_finish_reason`). Anthropic's documented `stop_reason` values: `"end_turn"`, `"max_tokens"`, `"tool_use"`, `"stop_sequence"`, `"pause_turn"` (newer; for long-running tasks), `"refusal"` (newer; content-filter analog). Mapping table:

| Anthropic string | ALLM atom | Notes |
|------------------|-----------|-------|
| `"end_turn"` | `:stop` | Natural completion. |
| `"max_tokens"` | `:length` | `max_tokens` reached. |
| `"tool_use"` | `:tool_calls` | Model produced one or more tool_use content blocks. |
| `"stop_sequence"` | `:stop` | A `stop_sequences:` element matched. |
| `"refusal"` | `:content_filter` | Anthropic policy block. |
| `"pause_turn"` | `:other` | Long-running pause; raw string preserved. |
| anything else | `:other` | `Response.raw_finish_reason` carries the original string verbatim. |
| `nil` (mid-stream `message_delta` pre-finish) | `nil` | Collector eventually replaces with the terminal value. |

Property-tested with `StreamData.string(:alphanumeric)` plus the documented set; every input produces a value in the closed enum (or `nil`) AND `raw_finish_reason` is populated when the input is non-nil. `:error` is never produced from a successful response — it appears only when `ALLM.StreamCollector` folds a mid-stream `{:error, _}` event per CLAUDE.md's mid-stream-error invariant.

The phase's eighth obligation is **vision content parts are rejected at `ALLM.Validate.request/1` upstream**, not at the adapter. Spec §33 lists vision as out-of-scope for v0.2; `ALLM.Validate.message/1` (Phase 1.4) emits `%ValidationError{reason: :vision_not_in_v0_2, errors: [{[..., :content], :image_part}]}` as a hard-reject when content includes image parts (verified at `lib/allm/validate.ex:113` and `lib/allm/error/validation_error.ex:32` on 2026-04-26 — `:vision_not_in_v0_2` is the reason atom; `:image_part` is the inner path-token tag). The adapter trusts the validator — there's no re-check inside `to_anthropic_request_body/1`. Anthropic *natively* supports vision; ALLM's v0.2 omission is a deliberate scope cut. A future v0.3 phase will relax the validator and the Phase 11 adapter will start accepting `%{type: "image", source: ...}` content blocks; for v0.2, the validator catches the request before the adapter ever sees it.

### Layer demonstration

**Layer B — Engine construction with Anthropic adapter:**

```elixir
engine =
  ALLM.Engine.new(
    adapter: ALLM.Providers.Anthropic,
    model: "claude-sonnet-4-6",
    tool_executor: ALLM.ToolExecutor.Default,
    tool_result_encoder: ALLM.ToolResultEncoder.JSON
  )

req = ALLM.request(
  [ALLM.system("Be concise."), ALLM.user("Name three primes.")],
  max_tokens: 200
)
# `system: "Be concise."` extracted to top-level; messages: contains only the :user item.
{:ok, %ALLM.Response{output_text: text, finish_reason: :stop}} = ALLM.generate(engine, req)
```

**Layer B — Streaming text against Anthropic (named SSE events normalized to `ALLM.Event`):**

```elixir
{:ok, stream} = ALLM.stream_generate(engine, ALLM.request([ALLM.user("Haiku about Elixir.")]))

# Anthropic emits SSE events like `event: content_block_delta` with payload
# `data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"..."}}`.
# The adapter normalizes them into ALLM.Event's `:text_delta` etc. — the consumer sees
# the same event shape as the OpenAI adapter produces.
Enum.each(stream, fn
  {:text_delta, %{delta: d}} -> IO.write(d)
  {:message_completed, _} -> IO.puts("\n[done]")
  _ -> :ok
end)
```

**Layer B — Tool call against Anthropic (auto mode, Phase 6+ orchestration):**

```elixir
engine =
  engine
  |> ALLM.Engine.put_tool(
    ALLM.tool(
      name: "get_weather",
      description: "Get current weather by city.",
      schema: %{type: "object", properties: %{city: %{type: "string"}}, required: ["city"]},
      handler: fn %{"city" => c} -> {:ok, %{forecast: "sunny", city: c}} end
    )
  )

{:ok, %ALLM.ChatResult{halted_reason: :completed} = result} =
  ALLM.chat(engine, [ALLM.user("What's the weather in Boston?")])
```

**Layer B — Structured output via tool-forcing (sub-phase 11.3):**

```elixir
schema = %{
  type: "object",
  properties: %{name: %{type: "string"}, age: %{type: "integer"}},
  required: ["name", "age"]
}

req = ALLM.request(
  [ALLM.user("Make up a person.")],
  response_format: ALLM.json_schema("person", schema)
)

# Adapter injects synthetic respond_with_json_person tool + tool_choice forcing.
# `requires_structured_finalize?/1` returns false → the Phase 10.4 two-pass branch is skipped.
{:ok, result} = ALLM.chat(engine, req.messages, response_format: req.response_format)

result.final_response.output_text
# => ~s({"name": "Alice", "age": 30})
result.final_response.finish_reason
# => :stop      # NOT :tool_calls — the synthetic tool's output is lifted to output_text
```

**Layer B — Live-provider smoke (`ANTHROPIC_API_KEY` required, opt-in tag):**

```bash
ANTHROPIC_API_KEY=sk-ant-... mix test --include live_anthropic test/allm/providers/anthropic_live_test.exs
```

**Sub-phase 11.4 — Runnable example against real Anthropic:**

```bash
ANTHROPIC_API_KEY=sk-ant-... mix run examples/anthropic/01_plain_text.exs
# => prints "OK" and exits 0
```

### Deliverables

- **New modules:**
  - `lib/allm/providers/anthropic.ex` — `ALLM.Providers.Anthropic`. Implements `ALLM.Adapter` (`generate/2`, `prepare_request/2`, `translate_options/2`) and `ALLM.StreamAdapter` (`stream/2`). Exposes `requires_structured_finalize?/1` returning `false` (per Decision #4). Approx. 380 LOC including request-build helpers (`to_anthropic_request_body/1`, `to_anthropic_messages/1`, `to_anthropic_tools/1`, `inject_structured_output_tool/2`, `extract_system/1`), response decoders (`from_anthropic_response/2`, `from_anthropic_error/3`), stop_reason mapper, and the streaming chunk-to-event mapper. **No SSE decoder of its own** — reuses `ALLM.Providers.Support.SSE` from Phase 10.1 verbatim.
- **Modified modules:**
  - `lib/allm/keys.ex` — no change. `:anthropic → "ANTHROPIC_API_KEY"` already in the table at `lib/allm/keys.ex:48`.
  - `mix.exs` — no change. `req`, `finch`, `jason` already in deps.
  - `test/test_helper.exs` — extend the existing `:exclude` list to `[:pending, :live_openai, :live_anthropic]` (Phase 10's `:live_openai` row is preserved; this adds the second live tag).
- **Test support:**
  - `test/support/anthropic_fixtures.ex` — `ALLM.Providers.AnthropicTestFixtures`. Loads recorded JSON fixture bodies from `test/fixtures/anthropic/`. Exposes `messages_response(name)` and `stream_chunks(name)` for the test suites. Approx. 60 LOC. Mirrors `test/support/openai_fixtures.ex` from Phase 10.
  - `test/support/finch_stub.ex` — **no change**. Reused unchanged from Phase 10.3 (per-test SSE chunk replay; provider-agnostic).
- **New tests:**
  - `test/allm/providers/anthropic_test.exs` — pure unit tests for the helpers: stop_reason mapping (every documented Anthropic string + property test for unknowns); request-build (system extraction; messages array shape; `tools` field including the structured-output synthetic tool injection; tool_choice translation per Decision #6); `translate_options/2` (Anthropic accepts `:max_tokens` natively — no rename per Decision #7); key resolution at request-build time; response decoding (text content blocks, tool_use content blocks, structured-output tool-call lifting per Decision #4); structured-output tool-forcing round-trip.
  - `test/allm/providers/anthropic_wire_test.exs` — recorded-fixture HTTP-shape tests using `Req.Test.stub`. 14 rows: happy text, single tool_use, parallel tool_use, structured output (tool-forcing), 429, 529 (Anthropic-specific overloaded — Decision #2), 500, 401, 400, 413 (request too large per Anthropic docs), malformed body, system-extraction round-trip, vision rejection (verifies the upstream `Validate` error path), streaming-no-retry meta.
  - `test/allm/providers/anthropic_stream_wire_test.exs` — recorded-fixture streaming tests using `ALLM.Test.FinchStub` (Phase 10.3 helper). 13 rows, parity with the Phase 10.3 `openai_stream_wire_test.exs` matrix: happy text streaming, tool_use deltas, parallel tool_use deltas, `:authentication_failed` pre-flight, `:invalid_request` pre-flight, mid-stream 5xx, mid-stream 529 (overloaded mid-stream), mid-stream `:content_filter`, mid-stream TCP drop, malformed event, consumer-halt cancellation (≤500ms via `state.done`-gated cancel from Phase 10.3 Decision #4a), `:usage` raw chunk (Anthropic's `message_delta` event carries `usage`), structured-output tool-forcing streamed end-to-end.
  - `test/allm/providers/anthropic_live_test.exs` — `@moduletag :live_anthropic`. Five rows, parity with the OpenAI live-test surface: plain text generate, streaming text, single tool call (round-trip), structured output (tool-forcing), session round-trip. Skipped by default; opt-in via `--include live_anthropic`.
  - Modified — `test/allm/engine_roundtrip_test.exs`: add an Anthropic-engine row asserting no key-shaped string survives `:erlang.term_to_binary/1` (parity with the Phase 10 OpenAI row).
- **Examples (sub-phase 11.4 — UNIFICATION):**
  - **Migrate** `examples/openai/01_plain_text.exs` through `09_ask_user.exs` UP to `examples/01_plain_text.exs` … `09_ask_user.exs` (verbatim move, then a per-script edit replacing inline engine construction with a call to `ExamplesHelpers.engine/0|1` from a new `examples/_helpers.exs`).
  - **`examples/_helpers.exs` (NEW)** — defines a tiny `ExamplesHelpers` module with a `@providers` map keyed by the env-var string and an `engine/1` constructor that reads `ALLM_PROVIDER` (default `"openai"`), looks up the entry, and returns a configured `%ALLM.Engine{}`. Provider-table rows: `%{"openai" => {ALLM.Providers.OpenAI, "gpt-5.4-nano", "OPENAI_API_KEY"}, "anthropic" => {ALLM.Providers.Anthropic, "claude-sonnet-4-6", "ANTHROPIC_API_KEY"}}`. The helper raises with a clear error when (a) `ALLM_PROVIDER` is set to an unknown value, (b) the corresponding `*_API_KEY` env var is unset, or (c) the adapter module is not loaded (Anthropic absent before Phase 11 lands). Each script's first lines are `Code.require_file("_helpers.exs", __DIR__)` then `engine = ExamplesHelpers.engine()`. The `ALLM_MODEL` override (already present in the Phase 10 helper convention) continues to win over the provider table's default.
  - **Update `examples/run_all.exs`** — moved up from `examples/openai/run_all.exs`; the wildcard re-rooted to `examples/[0-9][0-9]_*.exs`. The orchestrator passes `ALLM_PROVIDER` through to each script's environment unchanged.
  - **Update `examples/README.md`** — moved up from `examples/openai/README.md`; rewritten to describe the provider-neutral framework. Documents both invocation forms: `OPENAI_API_KEY=sk-… ALLM_PROVIDER=openai mix run examples/01_plain_text.exs` and `ANTHROPIC_API_KEY=sk-ant-… ALLM_PROVIDER=anthropic mix run examples/run_all.exs`. Per-provider cost expectations are listed side-by-side. The Q2 examples-as-validation philosophy carries over verbatim.
  - **Delete the now-empty `examples/openai/` directory** (everything moved up). The migration is git-mv-friendly so authorship history is preserved.
  - **Per-script audit:** the nine scripts' bodies need no logic changes — TIGHT/LOOSE assertions are provider-agnostic (e.g., `01_plain_text.exs`'s "trimmed output_text equals 'OK'" works for both providers given temperature 0 + hard-steered system prompt; `06_structured_output.exs`'s `Jason.decode(output_text) |> match?({:ok, _})` works for both per Q1 — semantic content is the same, byte shape may differ but that's invisible to the assertion). Sub-phase 11.4's verification step runs `run_all.exs` against BOTH providers and confirms exit-status 0 for each.
- **Fixtures:**
  - `test/fixtures/anthropic/README.md` — fixture-recording instructions; one-time gated on `ANTHROPIC_API_KEY`. Mirrors `test/fixtures/openai/README.md` shape with the recorded-vs-synthesized split per Phase 10 Decision #11.
  - `test/fixtures/anthropic/messages/*.json` — recorded from live API against `claude-sonnet-4-6`: `happy_text.json`, `single_tool_use.json`, `parallel_tool_use.json`, `structured_output.json`, `happy_text.sse`, `tool_use_deltas.sse`. Snapshot date 2026-04-26.
  - `test/fixtures/anthropic/synthesized/*.json` — hand-crafted with leading-comment provenance: `auth_failed.json` (401), `rate_limited.json` (429 + `Retry-After: 1` sidecar), `overloaded.json` (529 — Decision #2), `server_error.json` (500), `bad_request.json` (400), `request_too_large.json` (413), `malformed.json`, `mid_stream_error.sse`, `mid_stream_overloaded.sse` (529 mid-stream).
  - `scripts/record_anthropic_fixtures.exs` — one-time recorder; gated on `ANTHROPIC_API_KEY`; refuses to overwrite anything under `test/fixtures/anthropic/synthesized/`. Not in the published Hex package (verified `mix.exs:60` excludes `scripts/`).
- **CHANGELOG:** one line per public sub-phase (4 lines total); each cites its spec §-number.

### Spec coverage

| Spec § | Phase 11 implements |
|--------|---------------------|
| §5.1 (`ALLM.Message` system role) | 11.1 — `extract_system/1` partitions system messages out of `messages:` and concatenates them onto the top-level `system:` parameter. |
| §5.4 (`response_format` canonical → wire shape; tool-forcing pattern) | 11.3 — synthetic `respond_with_json_<schema_name>` tool injection + `tool_choice: {:tool, name}` forcing + tool-call-output lifted to `Response.output_text`; `requires_structured_finalize?/1 == false`. |
| §6.4 (key resolution at adapter-call time) | 11.1 — `ALLM.Keys.fetch!(:anthropic, opts)` inside `prepare_request/2` and `build_finch_request/3`. |
| §7.1 (`Adapter` callbacks) | 11.1 — `generate/2`, `prepare_request/2`, `translate_options/2`. |
| §7.2 (`StreamAdapter.stream/2` + HTTP/1) | 11.2 — `Finch.async_request/3` with `:http1`; reuses Phase 10.3 patterns. |
| §8 (event protocol) | 11.2 — Anthropic SSE events (`message_start`, `content_block_start`, `content_block_delta`, `content_block_stop`, `message_delta`, `message_stop`, `ping`) → `:text_delta`, `:tool_call_started`, `:tool_call_delta`, `:tool_call_completed`, `:message_completed`, `:raw_chunk`, `:error`. |
| §10.1 (mid-stream error fold) | 11.2 — adapter emits terminal `{:error, %AdapterError{}}` event; collector folds into `Response.finish_reason: :error`. |
| §20 (error model — including `529 Overloaded`) | 11.1 + 11.2 — every `AdapterError.@type reason` atom mapped from a documented Anthropic failure mode; `529 → :provider_unavailable`. |
| §29 (telemetry — `[:allm, :adapter, :retry]`) | 11.1 — `ALLM.Retry.run/3` integration; emits per attempt. |
| §32.1 (initial bundled adapters — Anthropic Messages API) | 11.1–11.4. |
| §33 (vision out of scope) | 11.1 — adapter trusts `ALLM.Validate.request/1`'s upstream `:image_part` hard-reject; no re-check. |

### Prerequisites

- Phases 1–10 complete. Phase 11 reuses Phase 10's `ALLM.Providers.Support.SSE`, `ALLM.Test.FinchStub`, `ALLM.Finch` default supervisor child, the `Capability.preflight/2` three-shape contract, and the `examples/openai/` script template.
- `req ~> 0.5` already in `mix.exs:36`. No dep change.
- `finch ~> 0.19` already in `mix.exs:37`. No dep change.
- `jason ~> 1.4` already in `mix.exs:38`. No dep change.
- `ALLM.Retry.run/3` exists from Phase 9.3. No change.
- `ALLM.Keys.fetch!/2` exists from Phase 2 with `:anthropic` already in the env-var table at `lib/allm/keys.ex:48`. No `Keys` change.
- `ALLM.Capability.preflight/2`'s widened contract `:ok | {:ok, Request.t()} | {:error, _}` from Phase 10.4 is consumed unchanged — Anthropic's `requires_structured_finalize?/1` returns `false` so the rewrite branch never fires for this adapter.
- `ALLM.Validate.message/1`'s `:image_part` hard-reject from Phase 1.4 catches vision content upstream of the adapter.

### Out of scope

- **Anthropic's beta `output_config` native structured output.** Decision #5. The SDK helpers (`zodOutputFormat`, `jsonSchemaOutputFormat`) and the `output_config` request parameter ship in the official SDKs but require beta opt-in via `anthropic-beta:` headers; per spec §5.4 the v0.2 approach is the tool-forcing pattern. A future phase can lift to native once Anthropic GAs the feature.
- **Prompt caching.** Anthropic's `cache_control` annotations on message content parts. Out of scope for v0.2 — exposing it requires a Layer A change to `ALLM.Message.content` (per `CLAUDE.md` reasoning). Spec §33 amendment candidate for v0.3.
- **Extended thinking blocks.** Anthropic's `thinking` content blocks for Claude reasoning models (analogous to OpenAI's reasoning tokens). The Anthropic streaming protocol emits `content_block_delta` events with `delta.type: "thinking_delta"` for these. The Phase 11 adapter passes them through as `:raw_chunk` events (so a power-user reducer can inspect them) but does NOT lift thinking content into `Response.metadata.reasoning` the way Phase 10.6 does for the OpenAI Responses API — Anthropic's thinking-block surface is sufficiently different (separate content-block index, no `reasoning_summary` analog) that proper integration is a v0.3 design. The `:raw_chunk` pass-through is a documented carve-out per Decision #8.
- **Vision (image content blocks).** Spec §33 hard-reject via `%ValidationError{reason: :vision_not_in_v0_2}` (path-token `:image_part` per `lib/allm/validate.ex:113`); lifted in v0.3.
- **Citations / web search.** Anthropic's web-search tool and citation-aware response decoding. Out of scope for v0.2.
- **Files API.** Anthropic's file-upload + reference-by-ID system. Out of scope.
- **Batches API.** Anthropic's `/v1/messages/batches` async batching endpoint. Out of scope; ALLM's design is per-request.
- **Streaming for the structured-output tool-forcing path.** Decision #5b. When `response_format` is `:json_schema`, the adapter forces the `respond_with_json_<name>` tool but the consumer-visible event sequence is rewritten by an adapter-owned `Stream.transform/3` wrapper to `:message_started → :text_delta+ → :text_completed → :message_completed` — matching OpenAI's native `:json_schema` streaming behavior. The non-streaming `generate/3` path lifts the tool-call output to `Response.output_text` post-decode via `lift_structured_output/1`; the streaming path runs the SAME helper inside the `Stream.transform/3`'s rewrite of the terminal `:message_completed`. Sub-phase 11.3.1 includes the streamed-structured-output test row.
- **Retry on streaming.** Spec §6.1 + Phase 10.3 streaming-no-retry rule. The Phase 11 streaming adapter does NOT call `ALLM.Retry.run/3`; the assertion is a meta-row in `anthropic_stream_wire_test.exs`.

### Non-obvious decisions

1. **The `system:` extraction joins multiple system messages with `\n\n`.** When a thread carries more than one system-role message (which the validator allows but is unusual in practice), the extractor concatenates their `content` strings separated by `\n\n`. Rationale: (a) Anthropic's API rejects an array `system:` parameter — it must be a string OR a content-blocks array; (b) the simpler string form covers every v0.2 use case (the example apps in `steering/examples/` use single-string system prompts); (c) `\n\n` is the conventional Markdown paragraph separator and matches how Anthropic's own docs concatenate multi-paragraph system prompts. The function is `extract_system/1`; property test: a thread with N≥1 system messages produces a `system:` string equal to `Enum.map_join(systems, "\n\n", & &1.content)`. The non-system messages flow through unchanged. `Docs target: @doc ALLM.Providers.Anthropic.extract_system/1`.

2. **`529 Overloaded` is added to the `retry_on` set for the Anthropic adapter's retry closure.** Anthropic documents `529 Overloaded` as the response code when its API is at capacity. Spec §6.1's default `retry_on` is `[429, 500, 502, 503, 504, :timeout]` — Phase 11's retry closure unconditionally treats 529 as retryable regardless of the policy's `retry_on` set (since the closure owns provider-specific error mapping); the engine-level `retry: [retry_on: ...]` opt is a *minimum* set the closure may extend. The `AdapterError.reason` for a 529 is `:provider_unavailable` (verified against the closed enum at `lib/allm/error/adapter_error.ex:55-68` on 2026-04-26 — the existing enum already covers 5xx-class outages including 529). `Docs target: @doc ALLM.Providers.Anthropic.generate/2` ("529 Overloaded handling" paragraph).

3. **Tool-choice translation returns a sentinel-tagged result `{:omit} | {:set, map()}` so the request-builder can decide whether to emit the `tool_choice` field at all.** ALLM's canonical `tool_choice` per spec §5.4 + `lib/allm/request.ex:277` accepts `:auto | :none | :required | String.t() | map() | nil`. The Anthropic wire shapes:

    | ALLM canonical | `to_anthropic_tool_choice/1` returns | Resulting wire |
    |----------------|---------------------------------------|-----------------|
    | `nil` | `{:omit}` | `tool_choice` field omitted (Anthropic defaults to "auto" when tools are present) |
    | `:auto` | `{:omit}` | omitted — same effect |
    | `:none` | `{:set, %{type: "none"}}` | `tool_choice: %{type: "none"}` |
    | `:required` | `{:set, %{type: "any"}}` | `tool_choice: %{type: "any"}` (Anthropic's name for "must call SOME tool") |
    | `"<tool_name>"` (string) | `{:set, %{type: "tool", name: "<tool_name>"}}` | `tool_choice: %{type: "tool", name: "<tool_name>"}` |
    | `%{type: t, name: _} = m` where `t in ~w(auto any none tool)` | `{:set, m}` (passthrough) | passthrough verbatim |

    Phase 11's `to_anthropic_tool_choice/1` is exhaustive over the canonical shapes; raises `ArgumentError` on any other shape (defense-in-depth — the validator should have caught it). Note the rename `:required → "any"` — Anthropic uses different wording than OpenAI for the same semantic. The request-builder's body-assembly logic pattern-matches the return: `{:omit}` skips the `tool_choice` field; `{:set, map}` injects it. `Docs target: @doc ALLM.Providers.Anthropic.to_anthropic_tool_choice/1` ("tool_choice translation table" paragraph).

4. **Structured-output tool-forcing lifts the synthetic tool-call back to `Response.output_text` AND sets `finish_reason: :stop`. The lift lives ENTIRELY adapter-side — `ALLM.StreamCollector` is provider-agnostic and remains untouched.** **Cross-provider byte-shape carve-out:** `output_text` from Anthropic's structured-output path is `Jason.encode!(tool_call.input)` — the bytes are re-encoded from a parsed map, so whitespace, key order, number formatting (`1.0` vs `1`), and Unicode escape style may differ from OpenAI's `:json_schema` path (which preserves the model's literal output string). The semantic content is identical (`Jason.decode!/1` of either yields the same Elixir map); the byte string is not. Practical impact is narrow — affects only consumers who hash, diff, or store `output_text` as a canonical "the model said exactly this" record across providers. The `@moduledoc ALLM.Providers.Anthropic` carries a one-paragraph note titled "Structured output `output_text` — semantic vs. byte equality" pointing readers to canonicalize via `Jason.encode!/1` themselves if byte-level cross-provider parity matters. Per spec §5.4 the caller of `ALLM.chat/3` with `response_format: %{type: :json_schema, ...}` expects a structured-output response — `Response.output_text` populated with JSON-encoded content matching the schema, `Response.finish_reason: :stop`, NOT `:tool_calls`. The Phase 11 decoder detects the synthetic tool call by name prefix (`"respond_with_json_"`) and rewrites the response: `output_text = Jason.encode!(tool_call.input)`, `finish_reason = :stop`, `tool_calls = []` (the synthetic tool is consumed and not surfaced to the caller), `metadata.structured_output_tool = true` (observability). The non-streaming arm runs the lift inside `from_anthropic_response/2`. The streaming arm wraps the inner `Stream.resource/3`-backed enumerable in a `Stream.transform/3` outer enumerable that intercepts the terminal `:message_completed` event, runs the same `lift_structured_output/1` helper on the in-flight response state, and re-emits a rewritten `:message_completed` carrying the lifted message. `ALLM.StreamCollector` (`lib/allm/stream_collector.ex`) is provider-agnostic and gets no changes; the lift is a pure-adapter concern. **The non-streaming and streaming arms share `lift_structured_output/1` so they produce byte-identical `%Response{}` shapes.** `requires_structured_finalize?/1` returns `false` so the Phase 10.4 two-pass branch is skipped. The synthetic tool name is `"respond_with_json_<schema_name>"` to avoid collision with a user-defined tool named `"respond_with_json"`; the prefix is the namespace marker the decoder pattern-matches on. `Docs target: @moduledoc ALLM.Providers.Anthropic` ("Structured output via tool-forcing") + `@doc from_anthropic_response/2` + `@doc stream/2` ("Structured-output stream-wrap").

5. **Anthropic's beta `output_config` native structured output is deferred to v0.3.** The Anthropic SDK ships `zodOutputFormat` / `jsonSchemaOutputFormat` helpers that call the beta `/v1/messages?beta=true` endpoint with an `output_config:` parameter for native JSON Schema enforcement (without the tool-forcing intermediate). Out of scope for v0.2 because (a) the spec §5.4 mandates the tool-forcing pattern; (b) the beta surface requires a `beta=true` query param and an `anthropic-beta:` header that ALLM's `prepare_request/2` doesn't currently plumb; (c) the tool-forcing pattern works on every Claude model since 2024 while `output_config` is gated to newer ones. A v0.3 phase can lift to native once GA. `Docs target: @moduledoc ALLM.Providers.Anthropic` ("Why tool-forcing, not output_config") + CHANGELOG entry.

5b. **Streamed structured output emits text deltas during the stream and the lift happens at the adapter's `Stream.transform/3` wrapper on completion — `StreamCollector` is untouched.** A consumer of `ALLM.stream_generate/3` against an Anthropic engine with `response_format: :json_schema` sees the events `[:message_started, :text_delta+, :text_completed, :message_completed]` — the synthetic `respond_with_json_<name>` tool's argument JSON arrives as `:text_delta` events carrying partial JSON as the model emits it. The `:tool_call_*` events DO NOT fire on this path; the wrapper suppresses them and rewrites tool-argument deltas as text deltas so `StreamCollector.to_response/1` produces the canonical `%Response{output_text: encoded_json, finish_reason: :stop, tool_calls: [], metadata: %{structured_output_tool: true}}` shape, matching the non-streaming arm byte-for-byte. **Cross-provider rationale:** this matches OpenAI's native `:json_schema` streaming behavior (which also emits `:text_delta` events) so consumers can write provider-neutral structured-output streaming code that pattern-matches `:text_delta`. The lift is implemented as an adapter-owned outer wrapper: `Anthropic.stream/2` returns `Stream.transform(inner_resource_stream, %{state...}, &transform_event/2)` — `transform_event/2` watches for the synthetic `respond_with_json_` tool's lifecycle events and rewrites them into text-stream events; when the terminal `:message_completed` arrives it rewrites the payload's `:message` to a synthesized assistant message whose `content` is `Jason.encode!(parsed_args)`, sets `:finish_reason` to `:stop`, and stamps `metadata.structured_output_tool: true`. Downstream `StreamCollector` then folds the rewritten event identically to a normal text-stream completion — no provider awareness in the collector. The README documents this carve-out; `06_structured_output.exs`'s assertion handles both paths transparently (it asserts on the final `Response.output_text` regardless of whether the consumer streamed it).

6. **`tool_use` content blocks decode to `%ALLM.ToolCall{}` with the `input` map mapped to `arguments`.** Anthropic's response carries `content: [{type: "tool_use", id: "toolu_...", name: "...", input: %{...}}, ...]` — `input` is the parsed-arguments map. ALLM's canonical `%ToolCall{id, name, arguments, raw_arguments}` (`lib/allm/tool_call.ex:11-21`) requires `:arguments` to be the parsed map; `:raw_arguments` carries the original JSON string when available. Anthropic's API returns `input` already-parsed (no raw string), so `raw_arguments = Jason.encode!(input)` is computed by the decoder for round-trip parity with OpenAI's behaviour (where `arguments` arrives as a string and is parsed). The synthetic `respond_with_json_<name>` tool's input is consumed during the structured-output lift (Decision #4) and never surfaces as a `%ToolCall{}`. `Docs target: @doc ALLM.Providers.Anthropic.from_anthropic_response/2` ("tool_use → ToolCall mapping").

7. **`translate_options/2` is identity for Anthropic.** Unlike OpenAI's three-way max-tokens-rename matrix (Phase 10 Decision #6), Anthropic's Messages API uses `max_tokens` natively across all model generations. `temperature`, `stop_sequences`, `top_p`, `top_k` all pass through unchanged. `tool_choice` is reshaped by `to_anthropic_tool_choice/1` (Decision #3) at request-build time, NOT in `translate_options/2`. `system:` is extracted at request-build time, NOT in `translate_options/2`. The `translate_options/2` callback returns its input keyword unchanged — the implementation is `def translate_options(opts, _request), do: opts`. Documented in `@doc translate_options/2` ("identity for Anthropic; reshape happens in request-build helpers"). `Docs target: @doc ALLM.Providers.Anthropic.translate_options/2`.

8. **Extended-thinking content blocks (Claude reasoning models) pass through as `:raw_chunk` events; structured integration is deferred to v0.3.** Anthropic's reasoning-model output stream emits `content_block_delta` events with `delta.type: "thinking_delta"` carrying `thinking` text — separate from `text_delta` content blocks. Phase 11.2's chunk-to-event mapper recognizes the `thinking_delta` type and emits `{:raw_chunk, {:thinking_delta, %{index: i, delta: text}}}` (using the existing `:raw_chunk` event variant from `ALLM.Event`'s closed union — additive payload keys are non-breaking per CLAUDE.md). Power-users who want to display thinking can pattern-match on `:raw_chunk` with the `:thinking_delta` payload tag; the default `StreamCollector` ignores it (no `Response` field carries thinking content in v0.2). The structured integration analogous to Phase 10.6's `Response.metadata.reasoning` for OpenAI is deferred to v0.3 because Anthropic's thinking-block surface (separate index, no `summary` analog, beta-gated `extended-thinking-2025-05-14` header) is materially different and deserves its own design pass. `Docs target: @moduledoc ALLM.Providers.Anthropic` ("Extended thinking") + CHANGELOG entry.

9. **`prepare_request/2` returns the unfired `%Req.Request{}` with the API key already injected as `x-api-key: <key>`.** Per Phase 10 Decision #16's pattern: the most common reason to use `prepare_request/2` is to insert middleware before the request fires, at which point the key is already needed. `prepare_request/2` calls `ALLM.Keys.fetch!/2` and may raise `%EngineError{reason: :missing_key}` (the canonical raise per Phase 2). The deviation from spec §7.1's "`{:ok, _}` | `{:error, _}`" return type is documented (matches Phase 10's pattern exactly). The `anthropic-version: 2023-06-01` header is also injected by `prepare_request/2`. `Docs target: @doc ALLM.Providers.Anthropic.prepare_request/2` ("Key + version header injection").

10. **Live-test hygiene reuses Phase 10's idiom.** The test_helper change extends the existing exclude list: `ExUnit.start(exclude: [:pending, :live_openai, :live_anthropic])` — both Phase 10's `:live_openai` and Phase 11's `:live_anthropic` are excluded by default. Opt-in via `mix test --include live_anthropic`. Missing-key handling uses the same canonical idiom from Phase 10: `if System.get_env("ANTHROPIC_API_KEY") in [nil, ""], do: @moduletag(:skip)` at the top of `anthropic_live_test.exs`. `Docs target: CHANGELOG entry only` (test infra change).

11. **Recorded fixtures use `claude-sonnet-4-6` as the canonical model — the value named in the canonical spec at `steering/allm_engine_session_streaming_spec_v0_2.md:1953`.** Recorded fixtures issue requests against `claude-sonnet-4-6`; live tests target the same model. The fixture-recording script and live tests honor `ALLM_MODEL` env-var override for callers who want to test against `claude-haiku-4-5` (cheaper) or future model versions. Approximate pricing (subject to change — reviewer to verify against the current Anthropic pricing page at impl time): ~$3/M input, ~$15/M output for Sonnet 4.6. `Docs target: `examples/anthropic/README.md` + `test/fixtures/anthropic/README.md`.

12. **The fixture-recording helper script lives at `scripts/record_anthropic_fixtures.exs`** — same out-of-package convention as Phase 10's `scripts/record_openai_fixtures.exs`. Not in `mix.exs:60`'s `:files` list. Gated on `ANTHROPIC_API_KEY`. Refuses to overwrite anything under `test/fixtures/anthropic/synthesized/`. Records 6 happy-path fixtures from `claude-sonnet-4-6` against the live API; the 9 error/synthesized fixtures are hand-crafted with leading-comment provenance per Phase 10 Decision #11's pattern.

13. **`requires_structured_finalize?/1` is a regular module function returning `false` for every input.** Per Phase 10 Decision #14, the function is consulted by `ALLM.Capability.preflight/2` via `function_exported?(adapter, :requires_structured_finalize?, 1)`. Anthropic's tool-forcing pattern is single-pass; the OpenAI-style two-pass dance is unnecessary. **`Capability.preflight/2` is invoked by Layer-C `ALLM.Runner.run/3` / `ALLM.Chat.run/3` (the call site shipped in Phase 9.4 and widened in Phase 10.4); Phase 11 makes no new call into it.** The Anthropic adapter is passive — it just exposes `requires_structured_finalize?/1` for the existing call site to consult. The function is implemented for symmetry (so future capability checks that pattern-match on `function_exported?` find it) but always returns `false`. Documented in `@doc requires_structured_finalize?/1` ("Always false for Anthropic — tool-forcing handles structured output in one pass"). `Docs target: @doc ALLM.Providers.Anthropic.requires_structured_finalize?/1`.

14. **The Anthropic streaming SSE protocol uses NAMED events** (`event: message_start\ndata: {...}\n\n`) — NOT a single anonymous data stream like OpenAI Chat Completions. The `ALLM.Providers.Support.SSE` decoder from Phase 10.1 already supports `event:` field parsing (Phase 10.1 invariant: "messages carry `:event` field through verbatim" — verified at `lib/allm/providers/support/sse.ex` per Phase 10.1 contract). The Phase 11 chunk-to-event mapper switches on the parsed `message.event` field directly — no JSON-body type-switching like OpenAI Chat Completions requires. Mapping table:

    | Anthropic SSE event | ALLM events emitted |
    |---------------------|----------------------|
    | `message_start` | `{:message_started, %{message: Message.new(role: :assistant, content: "", metadata: %{provider_id: msg_id})}}` (constructed via `ALLM.Event.message_started/1` per `lib/allm/event.ex:307-309` — the closed payload shape is `%{message: Message.t()}`; the Anthropic message id rides on `Message.metadata.provider_id` because adding an `:id` key directly would deviate from the closed event payload) |
    | `content_block_start` with `content_block.type == "text"` | (none — wait for `text_delta`) |
    | `content_block_start` with `content_block.type == "tool_use"` | `{:tool_call_started, %{id: tu_id, name: tu_name}}` |
    | `content_block_start` with `content_block.type == "thinking"` | `{:raw_chunk, {:thinking_start, %{index: i}}}` (Decision #8) |
    | `content_block_delta` with `delta.type == "text_delta"` | `{:text_delta, %{delta: text}}` |
    | `content_block_delta` with `delta.type == "input_json_delta"` | `{:tool_call_delta, %{id: tu_id, arguments_delta: partial_json}}` |
    | `content_block_delta` with `delta.type == "thinking_delta"` | `{:raw_chunk, {:thinking_delta, %{index: i, delta: text}}}` (Decision #8) |
    | `content_block_stop` (text block) | `{:text_completed, %{text: full_text}}` |
    | `content_block_stop` (tool_use block) | `{:tool_call_completed, %{id: tu_id, name: tu_name, arguments: parsed_input, raw_arguments: raw_json}}` |
    | `message_delta` | `{:raw_chunk, {:usage, usage_map}}` (carries `usage.output_tokens` updates) |
    | `message_stop` | `{:message_completed, %{message: ...}}` |
    | `ping` | (silently dropped — keep-alive only) |
    | `error` (a documented Anthropic SSE event for mid-stream errors) | terminal `{:error, %AdapterError{...}}` event |

    The mapper is exhaustive over the documented event set; an unrecognized event type emits a `{:raw_chunk, {:unknown_event, name, data}}` for forward-compatibility with future Anthropic event additions. The pattern-match raises only on programming errors (malformed accumulator state). `Docs target: @moduledoc ALLM.Providers.Anthropic` ("Streaming event mapping").

## Behaviour & Type Contracts

### `ALLM.Providers.Anthropic` (Layer B — new module)

```elixir
defmodule ALLM.Providers.Anthropic do
  @behaviour ALLM.Adapter
  @behaviour ALLM.StreamAdapter

  @base_url "https://api.anthropic.com/v1"
  @anthropic_version "2023-06-01"
  @retry_on_anthropic [429, 500, 502, 503, 504, 529, :timeout]
  @structured_output_tool_prefix "respond_with_json_"

  alias ALLM.{Keys, Message, Request, Response, Retry, Telemetry, Tool, ToolCall, Usage}
  alias ALLM.Error.{AdapterError, StreamError}
  alias ALLM.Providers.Support.SSE

  @impl ALLM.Adapter
  @spec generate(Request.t(), keyword()) :: {:ok, Response.t()} | {:error, AdapterError.t()}
  def generate(request, opts)

  @impl ALLM.Adapter
  @spec prepare_request(Request.t(), keyword()) :: {:ok, Req.Request.t()} | {:error, AdapterError.t()}
  def prepare_request(request, opts)

  @impl ALLM.Adapter
  @spec translate_options(keyword(), Request.t()) :: keyword()
  def translate_options(opts, request)

  @impl ALLM.StreamAdapter
  @spec stream(Request.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, AdapterError.t()}
  def stream(request, opts)

  @doc "Capability declaration consumed by ALLM.Capability.preflight/2 (Phase 10 Decision #14). Always false for Anthropic — tool-forcing pattern is single-pass."
  @spec requires_structured_finalize?(Request.t()) :: false
  def requires_structured_finalize?(_request), do: false

  # Internal helpers (private — listed here for cross-reference; see Module Tree)
  # to_anthropic_request_body/1, to_anthropic_messages/1, to_anthropic_tools/1,
  # to_anthropic_tool_choice/1, extract_system/1, inject_structured_output_tool/2,
  # from_anthropic_response/2, from_anthropic_error/3, lift_structured_output/1,
  # chunk_to_events/2 (streaming).
end
```

**Invariants:**

1. **`generate/2` is total** over `Request.t() × keyword()`. Returns `{:ok, %Response{}}` on success or `{:error, %AdapterError{}}` on every failure shape — never raises for HTTP-shaped failures (per `@callback ALLM.Adapter.generate/2` invariant 2 from `lib/allm/adapter.ex`). Programmer errors may raise.
2. **`generate/2` calls `ALLM.Retry.run(opts[:retry] || :default, telemetry_meta, closure)`.** Closure returns `{:ok, response}` on 2xx, `{:retry, delay_ms, %AdapterError{}}` on 429/5xx/529, `{:error, %AdapterError{}}` otherwise. `delay_ms` extracted from `Retry-After` header when present (parses both seconds and HTTP-date formats).
3. **`generate/2` calls `ALLM.Keys.fetch!(:anthropic, opts)` at request-build time, never at engine construction.** Key injected as `x-api-key: <key>` header on the `Req.Request`. Verified by the engine_roundtrip_test.exs Anthropic-engine row.
4. **Both `generate/2` and `stream/2` set `anthropic-version: 2023-06-01` header** via `@anthropic_version`. The version is a module attribute — bumped in one place when Anthropic introduces a breaking version.
5. **`prepare_request/2` returns `{:ok, %Req.Request{}}` on success** (key resolved, headers injected, body encoded). Calls `ALLM.Keys.fetch!/2` and may raise `%EngineError{reason: :missing_key}` per Decision #9. Returns `{:error, %AdapterError{}}` only for non-key failures.
6. **`translate_options/2` is identity per Decision #7.** No model-conditional renames.
7. **`stream/2` returns `{:ok, lazy_enumerable}` on success.** No HTTP call fires until the consumer reduces. Pre-flight failures return `{:error, %AdapterError{}}` synchronously.
8. **`stream/2` returns a `Stream.resource/3`-backed enumerable** with the same shape as Phase 10.3: `start_fun` opens `Finch.async_request/3`; `next_fun` uses `^ref`-pinned receive on the `{ref, payload}` 2-tuple shape; `state.done` flag set on `{ref, :done}`; `after_fun` calls `Finch.cancel_async_request/1` only when `state.done == false`. Cancellation bounded ≤ 500 ms (CI-asserted).
9. **`stream/2` honors `opts[:stream_timeout]`** via the `receive` block's after-clause. Exceeding emits a terminating `{:error, %AdapterError{reason: :timeout}}` event.
10. **`requires_structured_finalize?/1` always returns `false`** per Decision #13.
11. **Stop-reason mapping is total per the Overview table.** Property test: any string input produces a value in `Response.finish_reason()`; `Response.raw_finish_reason` carries the original.
12. **System message extraction is exhaustive.** All `role: :system` messages are partitioned out of the `messages:` payload and concatenated onto the top-level `system:` parameter per Decision #1. The validator is upstream of this and ensures `messages` has no `:tool` results without preceding tool calls etc.; the adapter trusts the validator.
13. **Vision content parts are rejected at `ALLM.Validate.request/1` upstream** per spec §33; the adapter trusts the validator and does not re-check.
14. **The structured-output lift is adapter-owned and shared between arms.** Non-streaming `generate/2` calls `lift_structured_output/1` inside `from_anthropic_response/2` post-decode. Streaming `stream/2` wraps its inner `Stream.resource/3`-backed enumerable in a `Stream.transform/3` outer enumerable that calls the SAME `lift_structured_output/1` helper when the terminal `:message_completed` arrives. `ALLM.StreamCollector` (`lib/allm/stream_collector.ex`) is provider-agnostic and gets no Anthropic-specific code. Stream-equivalence is preserved by the shared lift helper — both arms run the identical pure function on equivalent state. The shared `lift_structured_output/1` is invoked by the non-streaming arm post-decode AND by the streaming wrapper's `:message_completed` rewrite; both arms produce byte-identical `%Response{}` shapes including `metadata.structured_output_tool: true`.

### `ALLM.Providers.Support.SSE` (Layer B — REUSED unchanged from Phase 10.1)

No changes. The decoder's `event:` field carry-through (an existing invariant from Phase 10.1) is the load-bearing feature for Anthropic's named-event SSE protocol.

### `ALLM.Test.FinchStub` (Layer B test support — REUSED unchanged from Phase 10.3)

No changes. Provider-agnostic per-test SSE chunk replay. The Phase 10.3 contract supports Anthropic fixtures verbatim.

### Atom vocabulary additions

This phase adds **zero** new closed-enum atoms. Every error reason fired by the Anthropic adapter is already in `ALLM.Error.AdapterError.@type reason` (`lib/allm/error/adapter_error.ex:32-43`):

| AdapterError reason | Anthropic HTTP situation |
|---------------------|---------------------------|
| `:authentication_failed` | 401 (invalid or missing API key) |
| `:rate_limited` | 429 |
| `:invalid_request` | 400 (bad shape, unknown param) |
| `:content_filter` | response with `stop_reason: "refusal"` (Decision: see Overview's stop_reason table) |
| `:context_length_exceeded` | 400 with `error.type == "invalid_request_error"` and message containing the documented `"max_tokens"` or `"prompt is too long"` markers |
| `:provider_unavailable` | 500, 502, 503, 504, **529 (Anthropic-specific overloaded)** |
| `:timeout` | request_timeout / stream_timeout exceeded |
| `:network_error` | TCP/TLS/DNS failure |
| `:malformed_response` | 200 with unparseable JSON body |
| `:unsupported_feature` | (unused by Phase 11 — Anthropic accepts everything ALLM v0.2 emits) |
| `:unknown` | catch-all for unclassifiable shapes |

`StreamError` reasons (existing per `lib/allm/error/stream_error.ex:14-19`) used by the streaming adapter:

| StreamError reason | Anthropic streaming situation |
|--------------------|-------------------------------|
| `:adapter_error` | mid-stream wrap of an `%AdapterError{}` (e.g., 5xx mid-response) |
| `:cancelled` | consumer halted the stream |
| `:timeout` | transport-level timeout between chunks |
| `:malformed_event` | SSE line could not be parsed |
| `:unknown` | catch-all |

### Idiomatic Elixir requirements

- **`Req.Test.stub/1` for non-streaming wire tests** — same canonical Req test seam from Phase 10.2; per-test process-isolated.
- **`Finch.async_request/3` + `Finch.cancel_async_request/1` for streaming** — same Finch 0.19 API from Phase 10.3.
- **`Stream.resource/3` (NEVER `Stream.unfold/2`)** — per `AGENT_DESIGN_SPEC.md` § Elixir-specific.
- **`receive` blocks with `after` clauses** for the streaming `next_fun` — `:stream_timeout` is the after-value.
- **`String.to_existing_atom/1`** for stop_reason strings only when the input is in the documented closed set; unknown strings map to `:other` directly via case-clause.
- **`Jason.encode!/1` + `Jason.decode!/1`** for request/response body and for the structured-output tool-call's `input` map → `output_text` lift.
- **`@behaviour` + `@impl`** for both `ALLM.Adapter` and `ALLM.StreamAdapter` — dialyzer flags missing or extra callbacks.
- **`Enum.split_with/2`** for `extract_system/1` — clean partition between system and non-system messages.

## Module Tree

```
lib/allm/
└── providers/
    └── anthropic.ex                              (NEW — ALLM.Providers.Anthropic; both behaviours)

test/allm/
└── providers/
    ├── anthropic_test.exs                        (NEW — unit tests for helpers; stop_reason mapping property; system extraction; tool-forcing lift)
    ├── anthropic_wire_test.exs                   (NEW — Req.Test.stub-backed wire-shape tests; 14 rows)
    ├── anthropic_stream_wire_test.exs            (NEW — ALLM.Test.FinchStub-backed streaming wire tests; 13 rows)
    └── anthropic_live_test.exs                   (NEW — @moduletag :live_anthropic; five live-provider rows; skipped by default)

test/
└── test_helper.exs                               (MODIFY — extend :exclude list to [:pending, :live_openai, :live_anthropic])

test/support/
└── anthropic_fixtures.ex                         (NEW — ALLM.Providers.AnthropicTestFixtures; loads JSON + SSE fixtures)

test/fixtures/anthropic/
├── README.md                                     (NEW — fixture-recording instructions; one-time gated on ANTHROPIC_API_KEY)
├── messages/
│   ├── happy_text.json                           (NEW — recorded claude-sonnet-4-6 response)
│   ├── single_tool_use.json                      (NEW)
│   ├── parallel_tool_use.json                    (NEW)
│   ├── structured_output.json                    (NEW — tool-forcing pattern recording)
│   ├── happy_text.sse                            (NEW — recorded streaming, named events)
│   └── tool_use_deltas.sse                       (NEW)
└── synthesized/
    ├── auth_failed.json                          (NEW — 401 body)
    ├── rate_limited.json                         (NEW — 429 + Retry-After: 1 sidecar)
    ├── overloaded.json                           (NEW — 529 body, Anthropic-specific)
    ├── server_error.json                         (NEW — 500)
    ├── bad_request.json                          (NEW — 400)
    ├── request_too_large.json                    (NEW — 413)
    ├── malformed.json                            (NEW — 200 with broken JSON)
    ├── mid_stream_error.sse                      (NEW — happy chunks then 5xx event)
    └── mid_stream_overloaded.sse                 (NEW — happy chunks then 529 event)

examples/
├── _helpers.exs                                  (NEW — ExamplesHelpers; provider table; engine/1 constructor)
├── README.md                                     (MODIFY — moved up from examples/openai/README.md; rewritten as provider-neutral)
├── 01_plain_text.exs                             (MODIFY — moved up from examples/openai/; engine via ExamplesHelpers)
├── 02_streaming_text.exs                         (MODIFY — same)
├── 03_single_tool_call.exs                       (MODIFY — same)
├── 04_parallel_tool_calls.exs                    (MODIFY — same)
├── 05_multi_turn_chat.exs                        (MODIFY — same)
├── 06_structured_output.exs                      (MODIFY — works for both providers — Anthropic via tool-forcing, OpenAI via native schema)
├── 07_manual_tool_round_trip.exs                 (MODIFY — same)
├── 08_session_round_trip.exs                     (MODIFY — same)
├── 09_ask_user.exs                               (MODIFY — same)
└── run_all.exs                                   (MODIFY — moved up; wildcard re-rooted; passes ALLM_PROVIDER through)

examples/openai/                                  (DELETE — entire directory removed after migration)

scripts/
└── record_anthropic_fixtures.exs                 (NEW — one-time fixture recorder; gated on ANTHROPIC_API_KEY; not in mix package files)
```

## Phases

### Phase 11.1: `ALLM.Providers.Anthropic` non-streaming `Adapter` impl (Layer B)

**Goal:** Implement `generate/2`, `prepare_request/2`, `translate_options/2` against Anthropic Messages API; integrate `ALLM.Retry.run/3` with the `529 Overloaded` retryable status added; map every documented Anthropic error shape to an `%AdapterError{}` reason atom.

**Spec sections:** §6.4 (key resolution), §7.1 (callbacks), §20 (error model — including 529), §32.1, §33 (vision out of scope — adapter trusts upstream validator).

**Layer:** B.

#### 11.1.1 Test Plan

`test/allm/providers/anthropic_test.exs` (NEW):

- `extract_system/1` with no system messages returns `{nil, original_messages}`.
- `extract_system/1` with one system message returns `{system_text, [non_system_messages]}`.
- `extract_system/1` with three system messages returns `{joined_text, [non_system_messages]}` where `joined_text == "a\n\nb\n\nc"`.
- `to_anthropic_messages/1` produces an array of `%{role: "user" | "assistant" | "tool", content: ...}` items; system messages already filtered out by `extract_system/1`.
- `to_anthropic_tool_choice/1` covers all six canonical → wire shapes per Decision #3 (one row per ALLM canonical input × the `{:omit}` / `{:set, map}` return contract); raises `ArgumentError` on unknown shape.
- `to_anthropic_tool_choice/1` accepts `%{type: "auto"}`, `%{type: "any"}`, `%{type: "none"}`, `%{type: "tool", name: "x"}` already-shaped maps as `{:set, m}` passthrough; rejects unknown `type` values (`%{type: "unknown"}`) with `ArgumentError`.
- `to_anthropic_request_body/1` with `tool_choice: :auto, tools: []` produces a body with NO `tool_choice` field (per Decision #3's `{:omit}` row).
- `to_anthropic_request_body/1` with `tool_choice: :required, tools: []` raises `ArgumentError` ("tool_choice :required requires non-empty tools list — defense-in-depth; the validator should have caught it"). Property test: any `tool_choice ∈ [:required, "<name>"]` with `tools: []` raises.
- Structured-output collision: a request with a user-defined tool literally named `respond_with_json_person` AND `response_format: %{type: :json_schema, name: "person", ...}` produces a body whose `tools:` array contains BOTH the user tool AND the synthetic `respond_with_json_person` (the prefix-match in `lift_structured_output/1` is per-request — the synthetic name embeds the schema name, so collisions are only possible when the user names a tool exactly identical to the synthetic; documented as a known footgun in `@moduledoc`). The lift in `lift_structured_output/1` matches the FIRST tool call whose name starts with the prefix; if a user-named tool happens to match the prefix, the lift's behaviour is undefined and a runtime warning is logged.
- `lift_structured_output/1` with `tool_calls: [synthetic, user_tool]` (length 2): does NOT lift (Decision #4's "exactly one entry" guard); the response surfaces both tool calls and `finish_reason: :tool_calls` (the caller orchestrates them through the normal tool loop).
- Structured output + user tools (multi-turn): `chat/3` with `response_format: :json_schema` AND user-defined `tools` runs the tool loop normally; the synthetic forcing fires only on the FIRST adapter call (where `tool_choice` is set); subsequent turns drop the synthetic tool from the request body so user tools are callable. Tested via a multi-step Anthropic Fake fixture in 11.3.1.
- Stop-reason mapping: every documented Anthropic string (`"end_turn"`, `"max_tokens"`, `"tool_use"`, `"stop_sequence"`, `"refusal"`, `"pause_turn"`) maps per the Overview table.
- Property test (stop_reason): 100 random strings — every output ∈ `Response.finish_reason()` ∪ `[nil]`; `Response.raw_finish_reason` populated when input non-nil.
- `requires_structured_finalize?/1` returns `false` for every input shape.
- `prepare_request/2` returns `%Req.Request{}` with `x-api-key` AND `anthropic-version: 2023-06-01` headers when `ALLM.Keys.Store.put(:anthropic, "sk-ant-test")` is set.
- `prepare_request/2` raises `%EngineError{reason: :missing_key}` when no key resolver yields a value.
- `translate_options/2` is identity (same opts in, same opts out).

`test/allm/providers/anthropic_wire_test.exs` (NEW — `Req.Test.stub`-backed):

- Happy-path 200: returns `{:ok, %Response{output_text: "hello", finish_reason: :stop}}`.
- 401: returns `{:error, %AdapterError{reason: :authentication_failed, status: 401}}`.
- 400 (invalid request): returns `{:error, %AdapterError{reason: :invalid_request, status: 400}}`.
- 400 with documented "prompt is too long" body marker: returns `{:error, %AdapterError{reason: :context_length_exceeded}}`.
- 413 (request too large): returns `{:error, %AdapterError{reason: :invalid_request, status: 413}}` (no specialized atom for 413; the body shape carries the detail).
- 429 with `Retry-After: 1`: `ALLM.Retry.run/3` retries after 1000 ms; emits one `[:allm, :adapter, :retry]` event; second attempt's stub returns 200 → `{:ok, %Response{}}`.
- 429 exhausting retries: `{:error, %AdapterError{reason: :rate_limited}}` after two retry events.
- 500: `ALLM.Retry.run/3` retries; second attempt 200 → `{:ok, %Response{}}`.
- **529 Overloaded** (Anthropic-specific): `ALLM.Retry.run/3` retries; second attempt 200 → `{:ok, %Response{}}` (per Decision #2). Telemetry confirms one retry event with the closure-supplied error structurally containing `status: 529`.
- 529 exhausting: `{:error, %AdapterError{reason: :provider_unavailable}}` after two retry events.
- 200 with malformed JSON: `{:error, %AdapterError{reason: :malformed_response}}`.
- TCP/connection-refused: `{:error, %AdapterError{reason: :network_error}}`.
- Single tool_use: returns `%Response{tool_calls: [%ToolCall{}]}` with `finish_reason: :tool_calls`.
- Parallel tool_use: returns `%Response{tool_calls: [tc1, tc2]}` with both ids preserved (Anthropic uses `id: "toolu_..."` shape).
- System-extraction round-trip: a request with `[system, user]` messages produces a stub-recorded request body whose `system: "..."` top-level field equals the system message content AND whose `messages: [...]` contains only the user item.
- Vision rejection: a request with image content fails at `ALLM.Validate.request/1` BEFORE the adapter is invoked (verified by attaching a Req.Test.stub that asserts no request body was sent).
- Key threading: setting `opts[:api_key] = "sk-ant-override"` overrides the env-var key; the stub asserts the `x-api-key` header value.

#### 11.1.2 Implementation Checklist

- [ ] Create `lib/allm/providers/anthropic.ex` with the module shape from the Behaviour & Type Contracts section.
- [ ] Implement `generate/2`: build `%Req.Request{}` via `prepare_request/2`, wrap `Req.request/1` in `ALLM.Retry.run/3` with the closure parsing 429/500/502/503/504/**529**/`:timeout` per Decision #2, decode the response body to `%Response{}`.
- [ ] Implement `prepare_request/2`: resolve key via `ALLM.Keys.fetch!(:anthropic, opts)`, build URL (`@base_url <> "/messages"`), set headers (`x-api-key: <key>`, `anthropic-version: 2023-06-01`, `Content-Type: application/json`), encode body via `to_anthropic_request_body/1` (composes `extract_system/1` + `to_anthropic_messages/1` + `to_anthropic_tools/1` + `to_anthropic_tool_choice/1` + `inject_structured_output_tool/2` per Decision #4 + identity `translate_options/2`).
- [ ] Implement `translate_options/2`: identity (`def translate_options(opts, _request), do: opts`).
- [ ] Implement `requires_structured_finalize?/1`: returns `false` always.
- [ ] Implement `extract_system/1`: `Enum.split_with(thread.messages, &(&1.role == :system))`; return `{joined_system_text_or_nil, non_system_messages}`.
- [ ] Implement `to_anthropic_messages/1`: map `%Message{role: :user | :assistant | :tool, content: c, tool_call_id: tcid}` to the wire shape. Tool-result messages encode as `{role: "user", content: [{type: "tool_result", tool_use_id: tcid, content: c}]}` per Anthropic's documented tool-result format.
- [ ] Implement `to_anthropic_tools/1`: map `%Tool{name: n, description: d, schema: s}` to `%{name: n, description: d, input_schema: s}` (Anthropic uses `input_schema` not `parameters`).
- [ ] Implement `to_anthropic_tool_choice/1` per Decision #3.
- [ ] Implement `from_anthropic_response/2`: decode `%{"id" => id, "content" => content_blocks, "stop_reason" => sr, "usage" => u, ...}` to `%Response{}`. Map stop_reason per the table; populate `raw_finish_reason` for non-canonical values; build `%Usage{}` from `input_tokens` / `output_tokens`. Walk content_blocks: text → `output_text` accumulator; tool_use → `%ToolCall{}` list. After collection, call `lift_structured_output/1` (Decision #4).
- [ ] Implement `lift_structured_output/1`: when `length(response.tool_calls) == 1 AND String.starts_with?(hd(response.tool_calls).name, @structured_output_tool_prefix)`, replace with `output_text = Jason.encode!(tool_call.input)`, `finish_reason = :stop`, `tool_calls = []`, `metadata.structured_output_tool = true`.
- [ ] Implement `from_anthropic_error/3`: classify a 4xx/5xx response into `%AdapterError{}`. Argument order: `(status, body, headers)`. Includes the 529 → `:provider_unavailable` mapping.
- [ ] Record happy-path fixtures via `scripts/record_anthropic_fixtures.exs` (one-time, gated on `ANTHROPIC_API_KEY`).
- [ ] Hand-craft synthesized error fixtures with leading-comment provenance.
- [ ] Write `test/allm/providers/anthropic_test.exs` and `test/allm/providers/anthropic_wire_test.exs`.
- [ ] Verify the 14-row wire matrix covers every `AdapterError.@type reason` atom this adapter can produce (per Phase 10 Q1's shape-coverage bar).
- [ ] Add an Anthropic-engine row to `test/allm/engine_roundtrip_test.exs` confirming key-string serializability hygiene.

#### 11.1.3 Verification

```bash
mix test test/allm/providers/anthropic_test.exs
mix test test/allm/providers/anthropic_wire_test.exs
mix test                        # full suite still green
mix credo --strict lib/allm/providers/anthropic.ex
mix dialyzer
```

### Phase 11.2: `ALLM.Providers.Anthropic` streaming `StreamAdapter` impl (Layer B)

**Goal:** Implement `stream/2` against Anthropic Messages API streaming endpoint via `Finch.async_request/3`; reuse `ALLM.Providers.Support.SSE` from Phase 10.1 verbatim; map Anthropic's named-event SSE protocol to `ALLM.Event` values per the Decision #14 table; honor consumer-halt cancellation within 500 ms.

**Spec sections:** §7.2 (HTTP/1 streaming), §8 (event protocol), §10.1 (mid-stream error fold).

**Layer:** B.

#### 11.2.1 Test Plan

`test/allm/providers/anthropic_stream_wire_test.exs` (NEW — `ALLM.Test.FinchStub`-backed; 13 rows):

- Happy text streaming: `chunks` from `happy_text.sse` → events: `[{:message_started, _}, {:text_delta, _}, …, {:message_completed, _}]`. The collector folds to `%Response{output_text: full_text, finish_reason: :stop}`.
- Tool_use deltas: `chunks` from `tool_use_deltas.sse` → events: `[{:tool_call_started, _}, {:tool_call_delta, _}, …, {:tool_call_completed, _}, {:message_completed, _}]`. Final response carries `tool_calls: [%ToolCall{arguments: parsed_map, raw_arguments: raw_json}]`.
- Parallel tool_use deltas: chunks interleave deltas for two distinct tool_use ids → final response carries `tool_calls: [%ToolCall{id: "toolu_a", ...}, %ToolCall{id: "toolu_b", ...}]` with both `arguments` fully reassembled.
- `:authentication_failed` first chunk: stub responds 401 before any `data:` chunk; the `next_fun`'s `{ref, {:headers, headers}}` clause classifies the non-2xx status and emits a single terminal `{:error, %AdapterError{reason: :authentication_failed, status: 401}}` event. `stream/2`'s call-site tuple stays `{:ok, stream}` per CLAUDE.md's mid-stream-error invariant; `StreamCollector` folds the error into `Response.finish_reason: :error`. (Note: `Anthropic.stream/2` returns synchronous `{:error, _}` only for cases where the request never reaches Finch — missing API key, validator rejection, illegal request shape — NOT for HTTP-level 4xx/5xx that Finch successfully retrieves.)
- `:invalid_request` first chunk: stub responds 400; same shape — terminal `{:error, %AdapterError{reason: :invalid_request, status: 400}}` event; call-site tuple `{:ok, stream}`.
- Mid-stream 5xx: chunks switch from text deltas to a 503 mid-stream → terminal `{:error, %AdapterError{reason: :provider_unavailable}}` event; call-site tuple stays `{:ok, stream}`.
- **Mid-stream 529**: chunks switch from text deltas to a 529 mid-stream → terminal `{:error, %AdapterError{reason: :provider_unavailable, status: 529}}` event.
- Mid-stream `:content_filter`: stub emits two text deltas then a `message_delta` with `stop_reason: "refusal"` → final event is `{:message_completed, _}` with the response carrying `finish_reason: :content_filter`. (Note: this is a normal terminal, not an error event; `:content_filter` is signaled via `stop_reason`, not via a mid-stream `:error`.)
- Mid-stream `:network_error` (TCP drop): stub closes the socket after two chunks without sending `message_stop` → terminal `{:error, %StreamError{reason: :unknown}}` (or `:adapter_error` wrapping `%AdapterError{reason: :network_error}` per Phase 10.3 verification at impl time against Finch's transport-failure shape).
- Mid-stream malformed event: chunks include an unparseable line → terminal `{:error, %StreamError{reason: :malformed_event}}` event.
- Consumer halt: `Stream.take(stream, 2)` halts after 2 events; `ALLM.Test.FinchStub`'s cancellation-observer counter increments within 500 ms (assertion via monotonic-time per Phase 10.3).
- `:usage` raw chunk: chunks include Anthropic's `message_delta` event with `usage.output_tokens` updates → `%Response.usage` populated post-collection.
- Streaming-no-retry meta-row: attach `[:allm, :adapter, :retry]` handler; consume a stream that observes a 5xx (or 529) mid-stream; assert zero retry events fire.
- Streamed structured-output (tool-forcing): chunks emit a single `tool_use` content block whose `input_json_delta` chunks accumulate the schema-shaped JSON; the adapter's `Stream.transform/3` wrapper rewrites the consumer-visible event sequence to `[:message_started, :text_delta+, :text_completed, :message_completed]` (the synthetic `:tool_call_*` events are suppressed). `StreamCollector.to_response/1` then produces `%Response{output_text: encoded_json, finish_reason: :stop, tool_calls: [], metadata: %{structured_output_tool: true}}` — byte-identical with the non-streaming arm per Decision #5b and invariant 14.

#### 11.2.2 Implementation Checklist

- [ ] Implement `stream/2` in `lib/allm/providers/anthropic.ex`: pre-flight (key, validate request, structured-output tool injection per Decision #4); build `Finch.Request` via `Finch.build/4` with `:http1`; return `{:ok, Stream.resource(start_fun, next_fun, after_fun)}`.
- [ ] `start_fun`: `Finch.async_request(req, finch_name, [])` returns `request_ref`; initialize state `%{ref: ref, sse_acc: SSE.new(), buffered: [], status: nil, done: false, content_blocks: %{}, message_id: nil}`.
- [ ] `next_fun`: same shape as Phase 10.3 — `^ref`-pinned receive on `{ref, payload}` 2-tuple; on `{ref, {:data, chunk}}` call `SSE.decode_chunk/2`, run each parsed message through `chunk_to_events/2`, push to buffered, emit head; on `{ref, :done}` set `state.done = true` and synthesize `{:message_completed, _}` if not already emitted; on `{ref, {:headers, headers}}` validate 2xx (4xx/5xx → terminal `{:error, %AdapterError{}}`); on receive timeout emit terminal `{:error, %AdapterError{reason: :timeout}}`.
- [ ] `after_fun`: `if state.done, do: :ok, else: Finch.cancel_async_request(state.ref)` per Phase 10.3 Decision #4a (gated cancel).
- [ ] Implement `chunk_to_events/2` per Decision #14's table. Track per-content-block state in `state.content_blocks` (keyed by index) so `content_block_stop` can synthesize the right `:text_completed` / `:tool_call_completed` event with the accumulated text/JSON.
- [ ] Verify cancellation timing: a `Stream.take(stream, 2)` halts within 500 ms (CI tolerance asserted via `System.monotonic_time(:millisecond)`).
- [ ] Verify streamed structured-output lift produces identical `%Response{}` shape as the non-streaming path (stream-equivalence).
- [ ] Record streaming fixtures via `scripts/record_anthropic_fixtures.exs`.
- [ ] Write `test/allm/providers/anthropic_stream_wire_test.exs` per the test plan.

#### 11.2.3 Verification

```bash
mix test test/allm/providers/anthropic_stream_wire_test.exs
mix test                        # full suite still green
mix credo --strict lib/allm/providers/anthropic.ex
mix dialyzer
```

### Phase 11.3: Structured output via tool-forcing pattern (Layer B)

**Goal:** Implement the spec §5.4 tool-forcing pattern for `response_format: %{type: :json_schema, ...}` requests; verify stream-equivalence holds for the structured-output path; verify the Phase 10.4 `structured_finalize` two-pass branch is skipped (since `requires_structured_finalize?/1` returns `false`).

**Spec sections:** §5.4 (response_format + tool-forcing).

**Layer:** B.

#### 11.3.1 Test Plan

`test/allm/providers/anthropic_test.exs` (extends 11.1.1 with):

- `inject_structured_output_tool(request, body)` with `request.response_format == %{type: :json_schema, name: "person", schema: %{...}, strict: true}`: `body` gains a tool entry `%{name: "respond_with_json_person", description: "...", input_schema: %{...}}` AND `tool_choice: %{type: "tool", name: "respond_with_json_person"}`.
- `inject_structured_output_tool(request, body)` with `request.response_format == nil`: `body` unchanged (no injection).
- `inject_structured_output_tool(request, body)` with `request.response_format == %{type: :json_object}`: `body` unchanged (the json_object shape doesn't trigger tool-forcing — it's a softer capability documented as forwarded-to-provider with no Anthropic-specific handling; the model is asked to produce JSON via a system prompt convention OR the caller adds it themselves).
- `lift_structured_output/1` with `tool_calls: [%ToolCall{name: "respond_with_json_person", input: %{name: "Alice", age: 30}}]`: returns response with `output_text == ~s({"name":"Alice","age":30})`, `finish_reason: :stop`, `tool_calls: []`, `metadata.structured_output_tool: true`.
- `lift_structured_output/1` with `tool_calls: [%ToolCall{name: "user_tool", input: %{...}}]` (NOT a structured-output synthetic): returns the response unchanged.
- `lift_structured_output/1` with `tool_calls: []`: returns the response unchanged.
- Stream-equivalence row: a streamed structured-output run produces the SAME `%Response{}` shape as a non-streaming run for the same scripted fixture. Asserted via `chat/3 ≡ stream/3 |> StreamCollector.to_chat_result/1`.
- `Capability.preflight/2` with an Anthropic engine + `tools: [user_tool]` + `response_format: %{type: :json_schema, ...}`: returns `:ok` (NOT `{:ok, request}` with `structured_finalize: true` — the rewrite branch is skipped because `requires_structured_finalize?/1 == false`).

`test/allm/providers/anthropic_wire_test.exs` (extends 11.1.1 with the structured-output row):

- Recorded `structured_output.json` fixture: `chat/3` with `response_format: ALLM.json_schema("person", schema)` returns `result.final_response.output_text` parseable by `Jason.decode!/1` to the schema shape; `result.final_response.finish_reason == :stop`; `result.final_response.metadata.structured_output_tool == true`.

#### 11.3.2 Implementation Checklist

- [ ] Implement `inject_structured_output_tool/2` per Decision #4. The synthetic tool name is `@structured_output_tool_prefix <> request.response_format.name`.
- [ ] Implement `lift_structured_output/1` per Decision #4 + #5b as a pure helper. Called from `from_anthropic_response/2` (non-streaming) AND from the streaming `Stream.transform/3` wrapper's `lift_completion_event/2` reducer (streaming). `ALLM.StreamCollector` gets no changes.
- [ ] Wire the streaming arm's lift inside `stream/2`: wrap the inner `Stream.resource/3` enumerable in `Stream.transform/3` whose accumulator tracks per-stream tool-call state; on the terminal `:message_completed`, run `lift_structured_output/1` over the accumulated state and emit the rewritten event in place of the original. Pre-completion events pass through unchanged so consumers still see `:tool_call_delta` events for character-by-character JSON streaming.
- [ ] Verify `Capability.preflight/2` (already shipped in Phase 10.4 with the widened contract) returns `:ok` for Anthropic engines because `requires_structured_finalize?/1` returns `false`.
- [ ] Record the `structured_output.json` fixture (one-time, against `claude-sonnet-4-6`).
- [ ] Write the test rows in `test/allm/providers/anthropic_test.exs` and `test/allm/providers/anthropic_wire_test.exs`.

#### 11.3.3 Verification

```bash
mix test test/allm/providers/anthropic_test.exs test/allm/providers/anthropic_wire_test.exs
mix test                        # full suite still green; stream-equivalence holds
mix credo --strict lib/allm/providers/anthropic.ex
mix dialyzer
```

### Phase 11.4: Unify examples to a provider-neutral `examples/` framework + add Anthropic to the provider table (Layer B — runnable scripts)

**Goal:** Migrate the nine scripts shipped in Phase 10.5 from `examples/openai/` up to a unified `examples/` directory; introduce `examples/_helpers.exs` carrying the provider-switcher table; add the `:anthropic` row alongside the existing `:openai` row; verify all nine scripts pass against BOTH providers. The Phase 11 `/review` step runs `run_all.exs` against each provider and validates non-error exit per provider.

**Spec sections:** §32.1.

**Layer:** B (runnable scripts; consume the public Layer C / D API only).

#### 11.4.1 Test Plan

The examples themselves are the test plan — each script is a self-asserting smoke test, mirroring Phase 10.5's TIGHT/LOOSE philosophy. Per-script TIGHT/LOOSE assignments are identical to Phase 10's; the script bodies are provider-neutral via `ExamplesHelpers.engine/1` and run against EITHER `ALLM_PROVIDER=openai` (default — `gpt-5.4-nano`) OR `ALLM_PROVIDER=anthropic` (`claude-sonnet-4-6`):

- **`01_plain_text.exs` (TIGHT)** — system: `"Reply with exactly the word 'OK' and no other text."`; assertion: `String.trim(response.output_text) == "OK" AND response.finish_reason == :stop`.
- **`02_streaming_text.exs` (TIGHT)** — same prompt; streamed; assertion: text-delta count > 0 AND exactly one `:message_completed` AND reduced text trims to `"OK"`.
- **`03_single_tool_call.exs` (TIGHT)** — `tool_choice: "get_weather"` (canonical string form, translates to Anthropic's `%{type: "tool", name: "get_weather"}` per Decision #3 OR OpenAI's `%{type: "function", function: %{name: "get_weather"}}`; both providers honor the canonical string form); assertion: `halted_reason == :completed AND length(steps) == 2 AND text contains "sunny"`.
- **`04_parallel_tool_calls.exs` (TIGHT)** — `tool_choice: :required` (translates to Anthropic's `%{type: "any"}`); two tools; assertion: `length(tool_messages) == 2 AND halted_reason == :completed`.
- **`05_multi_turn_chat.exs` (LOOSE)** — natural multi-turn; shape-only assertion.
- **`06_structured_output.exs` (TIGHT)** — provider-agnostic. Anthropic exercises tool-forcing (Decision #4); OpenAI exercises native `:json_schema` enforcement. Assertion: `Jason.decode(output_text)` succeeds (both providers); `metadata.structured_output_tool == true` is asserted ONLY when `ALLM_PROVIDER == "anthropic"` (it's an Anthropic-specific marker; OpenAI's response carries no equivalent — the script's assertion branches on the provider env var).
- **`07_manual_tool_round_trip.exs` (TIGHT)** — `mode: :manual` with `tool_choice: "get_weather"`.
- **`08_session_round_trip.exs` (TIGHT)** — `Session.start → ETF round-trip → Session.reply`; `temperature: 0` makes responses deterministic.
- **`09_ask_user.exs` (LOOSE)** — handler returns `{:ask_user, "Which city?", []}`; first-turn assertion exact, second-turn assertion shape-only.

`run_all.exs` orchestration: identical to Phase 10's pattern (path wildcard `examples/[0-9][0-9]_*.exs` + per-script `Task.async + Task.yield(60_000)` + summary table + non-zero exit on any failure). The orchestrator inherits `ALLM_PROVIDER` from its environment and passes it through unchanged; reviewers run the orchestrator twice — once per provider.

`examples/README.md`: documents both provider invocation forms; cost expectations side-by-side. Anthropic Sonnet ~$0.08 USD per full run; reviewer to verify against the current Anthropic pricing page at impl time. Reviewers can override with `ALLM_MODEL=claude-haiku-4-5 ALLM_PROVIDER=anthropic mix run examples/run_all.exs` (Haiku is roughly 5× cheaper than Sonnet).

#### 11.4.2 Implementation Checklist

- [ ] Create `examples/_helpers.exs` with the `ExamplesHelpers` module: `@providers` map (two rows: `:openai`, `:anthropic` per the deliverables section), `engine/1` constructor that reads `ALLM_PROVIDER` env (default `"openai"`), validates the provider key + the corresponding `*_API_KEY` env var, and returns `%ALLM.Engine{}`. Raises `ArgumentError` (with a clear message) on unknown provider; raises `%EngineError{reason: :missing_key}` via `ALLM.Keys.fetch!/2` if the key is unset.
- [ ] Migrate `examples/openai/01_plain_text.exs` → `examples/01_plain_text.exs` (git mv to preserve history); replace the inline engine construction (lines that build `ALLM.Engine.new(...)`) with `Code.require_file("_helpers.exs", __DIR__); engine = ExamplesHelpers.engine()`. Repeat for `02` through `09`.
- [ ] Migrate `examples/openai/run_all.exs` → `examples/run_all.exs`; update the `Path.wildcard/1` glob to `examples/[0-9][0-9]_*.exs` (re-rooted at `examples/`).
- [ ] Migrate `examples/openai/README.md` → `examples/README.md`; rewrite the prerequisites + invocation sections to describe the provider-neutral framework with `ALLM_PROVIDER`. Per-provider cost / model expectations side-by-side.
- [ ] `git rm -r examples/openai/` after the migration (verifies the directory is empty and removes it from the tree).
- [ ] Update `06_structured_output.exs`'s assertion to branch on `ALLM_PROVIDER`: when `"anthropic"`, additionally assert `metadata.structured_output_tool == true`; when `"openai"`, skip that check (no Anthropic-specific marker in OpenAI responses).
- [ ] Run `OPENAI_API_KEY=… ALLM_PROVIDER=openai mix run examples/run_all.exs` locally; record output as `examples/RUN_OUTPUT_OPENAI.md`.
- [ ] Run `ANTHROPIC_API_KEY=… ALLM_PROVIDER=anthropic mix run examples/run_all.exs` locally; record output as `examples/RUN_OUTPUT_ANTHROPIC.md`.
- [ ] Add a `Decisions and live-run validation` section to the Phase 11 `/review` artifact with BOTH captured outputs.

#### 11.4.3 Verification

```bash
# Each script individually (Anthropic)
ANTHROPIC_API_KEY=sk-ant-... ALLM_PROVIDER=anthropic mix run examples/01_plain_text.exs
# … through 09_ask_user.exs

# All in one go, both providers (the canonical /review validation step — runs twice)
OPENAI_API_KEY=sk-... ALLM_PROVIDER=openai mix run examples/run_all.exs
echo $?    # must be 0

ANTHROPIC_API_KEY=sk-ant-... ALLM_PROVIDER=anthropic mix run examples/run_all.exs
echo $?    # must be 0

# Confirms the examples directory is NOT in the published Hex package
mix hex.build --unpack /tmp/allm-build && find /tmp/allm-build -path '*examples*'   # must return empty
rm -rf /tmp/allm-build

# Confirms the legacy examples/openai/ is gone post-migration
test ! -d examples/openai
```

The `/review` step for sub-phase 11.4 is BLOCKING on `run_all.exs` exit status `0` for **both** providers. Per Phase 10 Decision #13's pattern, the captured stdouts (one per provider) become part of the review artifact.

## Test Plan (cross-phase)

### Unit tests

- **`ALLM.Providers.Anthropic`** — `extract_system/1` (3 rows + property), `to_anthropic_messages/1` (role mapping, tool-result shape), `to_anthropic_tools/1` (input_schema mapping), `to_anthropic_tool_choice/1` (5 canonical shapes per Decision #3 + raise on unknown), stop_reason mapping (6 documented + property over unknowns), `requires_structured_finalize?/1` (always false), `prepare_request/2` (key resolution, header injection, missing-key raise), `inject_structured_output_tool/2` (3 rows per Decision #4), `lift_structured_output/1` (3 rows).

### Integration tests

- `anthropic_wire_test.exs` — 14 rows × `Req.Test.stub` per Phase 11.1.1 (including the Anthropic-specific 529 row, the 413 row, the system-extraction round-trip, the vision-rejection upstream verification).
- `anthropic_stream_wire_test.exs` — 13 rows × `ALLM.Test.FinchStub` per Phase 11.2.1 (parity with OpenAI's matrix; including mid-stream-529, streamed structured-output).
- `anthropic_live_test.exs` — 5 live-provider rows; `@moduletag :live_anthropic`; skipped by default.
- `engine_roundtrip_test.exs` — extended with one Anthropic-engine row asserting key serializability hygiene.

### Property tests

- Stop-reason mapping totality: 100 random strings → every output ∈ closed enum ∪ `[nil]`; `raw_finish_reason` populated for non-nil inputs.
- `extract_system/1` over random message lists: every input produces `{system_str_or_nil, non_system_msgs}` such that `non_system_msgs` is a strict subsequence of the input AND the count of system messages dropped equals the count input minus the count output.
- `to_anthropic_tool_choice/1` totality over canonical shapes: every shape in the closed canonical set produces the documented wire shape.

### Doctests

- `ALLM.Providers.Anthropic.requires_structured_finalize?/1` — pattern matches.
- `ALLM.Providers.Anthropic.translate_options/2` — identity demonstration.

(Other helper functions remain `@doc false`-private; doctests live on the public surface only.)

### Stream-equivalence

| Path | Relaxations | Justification | Risk |
|------|-------------|---------------|------|
| `Chat.run/3 ≡ Chat.stream/3 |> StreamCollector.to_chat_result/1` for Anthropic requests | none | both paths construct `%Response{}` via the shared `from_anthropic_response/2` AND `lift_structured_output/1`; equivalence by construction | tolerable |
| `generate/3 ≡ stream_generate/3 |> StreamCollector.to_response/1` for Anthropic requests | none | streaming is the primitive; non-streaming reduces it; the structured-output lift fires identically on both arms | tolerable |

No new masking-divergence rows.

### Coverage threshold

`mix test --cover` — ≥ 80 % global, ≥ 90 % on every NEW file (`anthropic.ex`, the wire test files, `anthropic_fixtures.ex`).

## Error Contract

All Phase 11 errors use existing `%AdapterError{}` and `%StreamError{}` reason atoms. No vocabulary additions.

| Function | Error reason | Recovery guidance |
|----------|--------------|-------------------|
| `Anthropic.generate/2` | `:authentication_failed` | ANTHROPIC_API_KEY invalid or missing; recoverable by setting the key. No retry. |
| `Anthropic.generate/2` | `:rate_limited` | 429; `ALLM.Retry` retries up to 3 attempts. After exhaustion, surface to caller. |
| `Anthropic.generate/2` | `:invalid_request` | 400 / 413; programmer error; no retry. |
| `Anthropic.generate/2` | `:context_length_exceeded` | 400 with prompt-too-long marker; reduce thread or increase model context window; no retry. |
| `Anthropic.generate/2` | `:content_filter` | `stop_reason: "refusal"` from Anthropic; surface to caller; no retry. |
| `Anthropic.generate/2` | `:provider_unavailable` | 5xx OR **529 (Anthropic-specific)**; `ALLM.Retry` retries up to 3 times. After exhaustion, surface. |
| `Anthropic.generate/2` | `:timeout` | `request_timeout` exceeded; recoverable via `opts[:request_timeout]` increase. |
| `Anthropic.generate/2` | `:network_error` | TCP/TLS/DNS failure; recoverable by retrying; ALLM does NOT auto-retry network errors. |
| `Anthropic.generate/2` | `:malformed_response` | 200 with broken body; surface to caller; no retry. |
| `Anthropic.prepare_request/2` | raises `%EngineError{reason: :missing_key}` | `ALLM.Keys.fetch!/2` found no key (Decision #9); fix at app boot. |
| `Anthropic.stream/2` synchronous | `:authentication_failed` (missing key — raised by `ALLM.Keys.fetch!/2`), `:unsupported_feature` (illegal request shape that escaped validator), `:invalid_request` (request build raises) | Pre-flight failures that occur BEFORE Finch is invoked. HTTP-level 4xx/5xx are NOT in this category (see next row). |
| `Anthropic.stream/2` mid-stream `{:error, _}` event | `AdapterError.reason ∈ {:authentication_failed, :rate_limited, :invalid_request, :context_length_exceeded, :content_filter, :provider_unavailable, :timeout, :network_error}` OR `StreamError.reason ∈ {:cancelled, :timeout, :malformed_event, :adapter_error, :unknown}` | Any error that arrives via Finch's async-message stream (including 401/400 as the first headers-event response) folds into `Response.finish_reason: :error` per CLAUDE.md mid-stream-error invariant; the call-site tuple stays `{:ok, stream}`. |

The `%ValidationError{reason: :vision_not_in_v0_2}` (with path-token `:image_part`) hard-reject from Phase 1.4 is fired upstream of the adapter; Phase 11 does not produce it.

## Streaming & Backpressure

Phase 11.2 ships streaming via `Finch.async_request/3` per spec §7.2 — same shape as Phase 10.3.

- **Cleanup is mandatory.** `Stream.resource/3`'s `after_fun` calls `Finch.cancel_async_request/1` only when `state.done == false` (the Phase 10.3 Decision #4a gate). The `ALLM.Test.FinchStub` cancellation-observer counter validates this in `anthropic_stream_wire_test.exs`.
- **Backpressure.** Same as Phase 10.3 — Finch's per-connection HTTP/1 message queue applies natural backpressure.
- **Cancellation timing.** Bounded ≤ 500 ms in CI (Phase 11.2.1 row asserts via monotonic-time).
- **`stream_timeout` honored.** `receive` block has `after opts[:stream_timeout]` clause.
- **Mid-stream errors fold into Response.** Per CLAUDE.md invariant.

## Definition of Done

- [ ] All four sub-phases marked `Completed` in the Status table.
- [ ] `mix test` zero failures, zero `unused_var` warnings (with `:live_anthropic` excluded by default per Decision #10).
- [ ] Coverage ≥ 80 % globally; ≥ 90 % on every NEW file (`providers/anthropic.ex`, the wire test files, `support/anthropic_fixtures.ex`).
- [ ] `mix credo --strict` zero issues on changed files.
- [ ] `mix dialyzer` zero new warnings (vs. pre-Phase-11 PLT).
- [ ] `mix format --check-formatted` passes (including `examples/anthropic/*.exs`).
- [ ] Every new public function in `ALLM.Providers.Anthropic` has `@spec` and `@doc` with at least one runnable doctest.
- [ ] All 14 wire-test rows in `anthropic_wire_test.exs` pass with `Req.Test.stub`-injected responses; covers every `AdapterError.@type reason` atom this adapter produces (per Phase 10 Q1's shape-coverage bar).
- [ ] All 13 streaming wire-test rows in `anthropic_stream_wire_test.exs` pass with `ALLM.Test.FinchStub`-replayed chunks; cancellation row asserts ≤ 500 ms via monotonic-time.
- [ ] `[:allm, :adapter, :retry]` events fire from `Anthropic.generate/2` per attempt — including for 529 Overloaded; zero events fire from `Anthropic.stream/2` (streaming-no-retry assertion).
- [ ] System-message extraction: Anthropic's top-level `system:` parameter equals the concatenated content of all `:system`-role messages (joined by `\n\n`); the `messages:` array contains no `:system`-role items (verified by inspecting the stub-recorded request body).
- [ ] Structured-output tool-forcing: when `response_format: %{type: :json_schema, ...}`, `to_anthropic_request_body/1` injects the synthetic tool AND `tool_choice` forces it; the response decoder lifts the tool-call output to `Response.output_text` AND sets `finish_reason: :stop`. Stream-equivalence holds.
- [ ] `requires_structured_finalize?/1` returns `false` for every input.
- [ ] `Capability.preflight/2` (Phase 10.4) returns `:ok` (no rewrite) for Anthropic engines.
- [ ] `:live_anthropic` excluded by default in `test/test_helper.exs` (extending the existing `:exclude` list to `[:pending, :live_openai, :live_anthropic]`); opt-in via `--include live_anthropic`.
- [ ] All nine unified `examples/*.exs` scripts run successfully against BOTH providers — i.e., `OPENAI_API_KEY=… ALLM_PROVIDER=openai mix run examples/run_all.exs` exits 0 AND `ANTHROPIC_API_KEY=… ALLM_PROVIDER=anthropic mix run examples/run_all.exs` exits 0. Both per-provider `RUN_OUTPUT_*.md` snapshots committed.
- [ ] Legacy `examples/openai/` directory removed post-migration (`test ! -d examples/openai` succeeds).
- [ ] `examples/_helpers.exs` carries both `:openai` and `:anthropic` rows in `@providers`; `ExamplesHelpers.engine/1` validates env-var + adapter loading per the contract.
- [ ] `examples/` directory is NOT in the published Hex package — verified via `mix hex.build --unpack` returning no `examples/` paths.
- [ ] CHANGELOG.md updated with one line per public sub-phase (4 lines total); each cites its spec §-number.
- [ ] Reviewed via `/review` per `AGENT_REVIEW_SPEC.md` AND the additional sub-phase 11.4 validation step: the reviewer runs `ANTHROPIC_API_KEY=… mix run examples/anthropic/run_all.exs` and records the output in the review artifact. The review is BLOCKING on `run_all.exs` exit-status 0.

## Examples (sub-phase 11.4 — provider-neutral migration + Anthropic enrollment)

Following the Phase 10.5 Q2 examples-as-validation philosophy, retrofitted as a provider-neutral framework.

### Directory layout (post-migration)

```
examples/
├── _helpers.exs                                  (NEW — ExamplesHelpers; provider table; engine/1 constructor)
├── README.md                                     (MIGRATED — describes the provider-neutral framework)
├── 01_plain_text.exs                             (MIGRATED — engine via ExamplesHelpers.engine/0)
├── 02_streaming_text.exs                         (MIGRATED)
├── 03_single_tool_call.exs                       (MIGRATED)
├── 04_parallel_tool_calls.exs                    (MIGRATED)
├── 05_multi_turn_chat.exs                        (MIGRATED)
├── 06_structured_output.exs                      (MIGRATED — assertion branches on ALLM_PROVIDER for the metadata.structured_output_tool check)
├── 07_manual_tool_round_trip.exs                 (MIGRATED)
├── 08_session_round_trip.exs                     (MIGRATED)
├── 09_ask_user.exs                               (MIGRATED)
├── run_all.exs                                   (MIGRATED — wildcard re-rooted; ALLM_PROVIDER passed through)
├── RUN_OUTPUT_OPENAI.md                          (committed snapshot — most recent ALLM_PROVIDER=openai run)
└── RUN_OUTPUT_ANTHROPIC.md                       (committed snapshot — most recent ALLM_PROVIDER=anthropic run)
```

### `_helpers.exs` shape

```elixir
defmodule ExamplesHelpers do
  @providers %{
    "openai"    => {ALLM.Providers.OpenAI,    "gpt-5.4-nano",       "OPENAI_API_KEY"},
    "anthropic" => {ALLM.Providers.Anthropic, "claude-sonnet-4-6",  "ANTHROPIC_API_KEY"}
  }

  def engine(extra_opts \\ []) do
    provider = System.get_env("ALLM_PROVIDER", "openai")

    {adapter, default_model, key_env} =
      case Map.fetch(@providers, provider) do
        {:ok, row} -> row
        :error -> raise(ArgumentError, "Unknown ALLM_PROVIDER #{inspect(provider)}; legal: #{inspect(Map.keys(@providers))}")
      end

    unless Code.ensure_loaded?(adapter) do
      IO.puts(:stderr, "FAIL: #{inspect(adapter)} not compiled — is the provider's phase included in this build?")
      System.halt(1)
    end

    if System.get_env(key_env) in [nil, ""] do
      IO.puts(:stderr, "FAIL: #{key_env} not set (required for ALLM_PROVIDER=#{provider})")
      System.halt(1)
    end

    model = System.get_env("ALLM_MODEL", default_model)

    base = [
      adapter: adapter,
      model: model,
      tool_executor: ALLM.ToolExecutor.Default,
      tool_result_encoder: ALLM.ToolResultEncoder.JSON,
      params: %{temperature: 0}
    ]

    ALLM.Engine.new(Keyword.merge(base, extra_opts))
  end
end
```

The helper is intentionally minimal — provider table + env-var check + engine construction. Future providers (Phase 12+) add a single row to `@providers`; existing scripts pick them up with no edits.

### Common script template (post-migration)

```elixir
# examples/0X_<name>.exs
#
# Demonstrates: <one-sentence purpose>
# Spec section: §X.Y
# Steering strategy: <"tight"> OR <"loose">
# Natural alternative (commented out below): <one-line free-form prompt>
# Run with:    OPENAI_API_KEY=sk-... mix run examples/0X_<name>.exs                     # default
#         OR:  ANTHROPIC_API_KEY=sk-ant-... ALLM_PROVIDER=anthropic mix run examples/0X_<name>.exs

Application.ensure_all_started(:allm)
Code.require_file("_helpers.exs", __DIR__)

engine = ExamplesHelpers.engine()

# ... per-example body — uses tool_choice: "<name>" or :required when tight ...

result = ...

unless <self-assertion>, do: (IO.puts(:stderr, "FAIL: <reason>"); System.halt(1))

IO.puts("OK: <one-line summary>")
```

### `run_all.exs` orchestrator

Migrated up from `examples/openai/run_all.exs`; `Path.wildcard/1` re-rooted to `examples/[0-9][0-9]_*.exs`. 60-second per-script timeout via `Task.async/1` + `Task.yield/2`. Exit-status 0 if all OK, 1 on any failure. `ALLM_PROVIDER` is inherited from the orchestrator's environment and passes through unchanged to each child script (each script reads it independently via `ExamplesHelpers.engine/0`).

### `/review` validation step (BLOCKING, two providers)

1. Run `mix test` (full suite, deterministic, default exclusions).
2. Run `mix test --include live_anthropic test/allm/providers/anthropic_live_test.exs` (live smoke; skipped if no `ANTHROPIC_API_KEY`; informational).
3. Run `OPENAI_API_KEY=… ALLM_PROVIDER=openai mix run examples/run_all.exs` (BLOCKING; records stdout as `RUN_OUTPUT_OPENAI.md`).
4. Run `ANTHROPIC_API_KEY=… ALLM_PROVIDER=anthropic mix run examples/run_all.exs` (BLOCKING; records stdout as `RUN_OUTPUT_ANTHROPIC.md`).
5. Capture per-provider `[OK]` / `[FAIL]` summaries in the review's `Findings` section.
6. Tag the review with `phase-11-validation: passed` (or `failed:openai`, `failed:anthropic`, or `failed:both` with the failing script names).

The review FAILS if step (3) OR step (4) exits non-zero.

### Example fixture cost (per provider)

Running `run_all.exs` once per provider:

- **`ALLM_PROVIDER=openai` (`gpt-5.4-nano`)** — see Phase 10's cost note (~$0.05 USD per full run).
- **`ALLM_PROVIDER=anthropic` (`claude-sonnet-4-6`)**:
  - 9 scripts × ~500 input tokens × ~$3 / 1M = ~$0.014
  - 9 scripts × ~500 output tokens × ~$15 / 1M = ~$0.068
  - **Total: approximately $0.08 USD per full run** (Anthropic's pricing is volatile — reviewer to verify against the current Anthropic pricing page at impl time).
- **Combined `/review` cost: ~$0.13 USD per pass** (one OpenAI run + one Anthropic run).

Reviewers concerned about cost can override the model: `ALLM_MODEL=claude-haiku-4-5 ALLM_PROVIDER=anthropic mix run examples/run_all.exs` drops the Anthropic leg to ~$0.01. Runtime budget: typically 60–90 seconds wall-clock per provider for the full nine-script run; ~3 minutes total for the dual-provider `/review` pass.

### Failure modes

- **`*_API_KEY` missing.** `ExamplesHelpers.engine/0` checks the env var name from the provider table BEFORE constructing the engine and exits with a clear error message naming the missing variable.
- **Unknown `ALLM_PROVIDER`.** `ExamplesHelpers.engine/0` raises `ArgumentError` listing the legal provider names.
- **Adapter module not loaded** (Anthropic absent before Phase 11 lands, or in a future scenario where Phase 11 is rolled back). `Code.ensure_loaded?(adapter)` in the helper returns false; the helper exits with a clear "ALLM.Providers.Anthropic not compiled — is Phase 11 included in this build?" message.
- **Real provider 5xx OR 529.** `ALLM.Retry` retries up to 3 attempts (529 included per Decision #2). After exhaustion, the script fails; reviewer may rerun once.
- **Model unavailable.** If the configured model is decommissioned, the `:invalid_request` reason fires. Override via `ALLM_MODEL=<current-model> mix run …`.
- **Quota exceeded.** `:rate_limited` after retry exhaustion. Reviewer waits or uses a different key.

These failure modes are documented in `examples/README.md` so reviewers don't need to read this design doc to interpret a failure.
