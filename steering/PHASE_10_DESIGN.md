# Phase 10: OpenAI Provider Adapter — Design Document

> **Goal:** Ship `ALLM.Providers.OpenAI` implementing both `ALLM.Adapter` and `ALLM.StreamAdapter` against **two** OpenAI endpoints — `POST /v1/responses` (the **default** for GPT-5/5.5/o-series reasoning models, which are the v0.2 primary target) and `POST /v1/chat/completions` (legacy path for GPT-4* and any caller passing `endpoint: :chat_completions` explicitly) — normalizing OpenAI's wire shapes onto ALLM's canonical types, integrating with the `ALLM.Retry` helper from Phase 9.3 for non-streaming retries, plumbing reasoning controls (`reasoning_effort`, `verbosity`, `max_output_tokens`) through the request → adapter → response chain, and implementing the spec §5.4 `structured_finalize` two-pass dance with `requires_structured_finalize?/1` capability declaration. The Phase 3 conformance harnesses are NOT reused for real adapters (they were built for `ALLM.Providers.Fake`'s scripted shape and reusing them on real adapters is a category error per Q1 — the equivalent shape-coverage bar lives in `openai_wire_test.exs` instead).
> **Outcome:** A library user with a valid `OPENAI_API_KEY` can construct `ALLM.Engine.new(adapter: ALLM.Providers.OpenAI, model: "gpt-5.5")` and call every public Layer-C entry point (`ALLM.generate/3`, `ALLM.stream_generate/3`, `ALLM.step/3`, `ALLM.stream_step/3`, `ALLM.chat/3`, `ALLM.stream/3`) plus `ALLM.Session` against the real OpenAI Responses API and receive correctly-typed results carrying reasoning-token counts on `Usage`, the `output_text` field on `Response`, and the `incomplete_details.reason` on `Response.metadata` when applicable. Runnable example scripts under `examples/openai/` exercise nine end-to-end shapes against `gpt-5.5` (or whatever `ALLM_MODEL` overrides) when invoked as `OPENAI_API_KEY=sk-… mix run examples/openai/<name>.exs`; assertions are tight (per Q2 — `temperature: 0`, hard-steered system prompts, explicit `tool_choice` forcing) so `examples/openai/run_all.exs` is a deterministic regression bar suitable as the BLOCKING `/review` validation step. Recorded fixtures cover both endpoints' wire shapes via `Req.Test.stub/1` (non-streaming) and a custom `Finch` plug stub (streaming) so the full bar runs offline in CI. `mix test`, `mix credo --strict`, `mix dialyzer`, `mix format --check-formatted` all green; ≥ 90 % coverage on every new file. A live-provider smoke test gated on `OPENAI_API_KEY` (skipped in CI by default via `@tag :live_openai` + extending the existing `:exclude` list) exercises one happy-path call per endpoint shape.
> **Spec sections:** §5.4 (`response_format` canonical shape + `structured_finalize`), §6.4 (key resolution at adapter-call time), §7.1 (`ALLM.Adapter` callbacks: `generate/2`, `prepare_request/2`, `translate_options/2`), §7.2 (`ALLM.StreamAdapter.stream/2` + HTTP/1 streaming guidance), §8 (event protocol — `:text_delta` / `:tool_call_delta` / `:message_completed` / `:raw_chunk` / `:error`), §10.1 (`generate/3` — mid-stream errors fold into Response), §20 (error model — every `AdapterError` reason atom with provider mapping), §29 (telemetry — adapter retries emit `[:allm, :adapter, :retry]`), §32.1 (initial bundled adapters — OpenAI Chat Completions + Responses).
> **Layers touched:** **B (single layer).** Every new module is Layer B (runtime; carries non-serializable Finch refs and key resolvers). Zero Layer A struct field additions (reasoning-token counts ride the existing `Usage.reasoning_tokens` field shipped in Phase 1; `output_text` is the existing `Response.output_text` field; `incomplete_details` is metadata-only). Zero Layer C / D code changes — the adapter plugs into existing `ALLM.Runner.run/3`, `ALLM.StreamRunner.run/3`, `ALLM.Chat.*`, `ALLM.Session.*` entry points via the existing behaviour contracts. Examples under `examples/openai/` are runnable scripts (no `lib/` or `test/` files); they consume the public Layer C / D API only.
> **Phasing doc:** [`PROJECT_PHASING.md`](PROJECT_PHASING.md) Phase 10.

## Status

| Sub-phase | Description | Layer | Status |
|-----------|-------------|-------|--------|
| 10.1 | `ALLM.Providers.Support.SSE` — line-buffered SSE decoder shared with Phase 11 (Anthropic); `decode_chunk/2` accumulator; comment-line handling; multi-line `data:` reassembly; named SSE event types (`event: response.output_text.delta` etc. for Responses API); `[DONE]` sentinel for Chat Completions | B | Completed |
| 10.2 | `ALLM.Providers.OpenAI` non-streaming `Adapter` impl (`generate/2`, `prepare_request/2`, `translate_options/2`); endpoint dispatch (`:responses` for GPT-5/o-series, `:chat_completions` for GPT-4*); request-build via `Req`; key resolution via `ALLM.Keys.fetch!/2`; finish_reason / status mapping (covers `incomplete` + `incomplete_details.reason`); full `AdapterError` reason mapping; `ALLM.Retry.run/3` integration | B | Completed |
| 10.3 | `ALLM.Providers.OpenAI` streaming `StreamAdapter` impl (`stream/2`); `Finch` HTTP/1 streaming via `Finch.async_request/3`; SSE chunk → `ALLM.Event` mapping for BOTH endpoints (Chat Completions delta-shape AND Responses semantic-event-shape); `Stream.resource/3` cleanup with bounded-time cancellation | B | Completed |
| 10.4 | `response_format` translation (canonical → wire shape per endpoint); `structured_finalize: true` two-pass execution wired into `ALLM.Chat.run/3` / `ALLM.Chat.stream/3`; `requires_structured_finalize?/1` capability declaration; capability pre-flight integration | B | Completed |
| 10.5 | Runnable examples under `examples/openai/` (nine scripts) targeting `gpt-5.4-nano` with tight per-script assertions per Q2; `run_all.exs` orchestrator; README; `/review` validation step that runs every example against the real provider and asserts non-error exit | B | Completed |
| 10.6 | Reasoning-controls plumbing: `reasoning_effort`, `verbosity`, `max_output_tokens`, `reasoning.summary`; `Response.metadata.reasoning` carries `effort` / `summary` round-trip; `Usage.reasoning_tokens` populated from `usage.completion_tokens_details.reasoning_tokens` (Chat) and `usage.output_tokens_details.reasoning_tokens` (Responses); `incomplete` status mapping | B | Completed |

**Overall Progress:** 6/6 sub-phases complete

## Overview

Phase 10 is the **first real provider adapter**. Every prior phase (1–9) has tested orchestration, streaming, sessions, telemetry, retries, and capability pre-flight against `ALLM.Providers.Fake` — a deterministic scripted adapter that ignores the request body. Phase 10 proves the abstractions hold against an actual HTTPS endpoint with real wire shapes, real error responses, real SSE framing, and real authentication. The adapter is intentionally narrow: Chat Completions only (the Responses API and o-series `reasoning` blocks are out of scope per Decision #1 and Decision #5 below); two callbacks per behaviour; one shared SSE helper that Phase 11 (Anthropic) will reuse verbatim.

The phase's load-bearing correctness obligation is **shape coverage of every `AdapterError` / `StreamError` reason atom against the real OpenAI wire format.** Per Q1 (2026-04-26): the Phase 3 `ALLM.Test.AdapterConformance` and `ALLM.Test.StreamAdapterConformance` harnesses are NOT reused for real provider adapters. They were built around `adapter_opts: [script: …]` — a Fake-style scripted shape that a real OpenAI adapter cannot meaningfully consume (the alternatives are either ignoring the script and failing every assertion, or implementing a hidden script-interpretation backdoor that defeats the conformance bar). Reusing them on real adapters is a category error. The equivalent shape-coverage bar is the **expanded `openai_wire_test.exs` matrix** (sub-phase 10.2) plus **`openai_stream_wire_test.exs`** (sub-phase 10.3), which exercise every documented `AdapterError.@type reason` and `StreamError.@type reason` atom against `Req.Test.stub`-injected (non-streaming) or `ALLM.Test.FinchStub`-replayed (streaming) fixture responses. The matrix is tabulated explicitly in 10.2.1 (14 rows) and 10.3.1 (13 rows); each row's documentation cites the specific OpenAI API doc page or HTTP-status family it models. The Phase 3 harnesses continue to live under `:allm_conformance` for adapter authors who write their own scripted-style adapters; they remain useful for the Fake and for any third-party adapter that adopts the script-shape convention.

The phase's second obligation is **the live-provider smoke test is opt-in only.** Per `AGENT_DESIGN_SPEC.md` §10 — "network mocks reserved for real adapter wire shape" — Phase 10 is the only phase in v0.2 where network mocks are legal *inside* `test/`. The recorded-fixture wire tests live in `test/allm/providers/openai_wire_test.exs` and `test/allm/providers/openai_stream_wire_test.exs` and use stubbed transports (no network). The live-provider smoke test lives in `test/allm/providers/openai_live_test.exs`, is `@tag :live_openai`, and is excluded by default in `test/test_helper.exs` (`ExUnit.start(exclude: [:live_openai])`); CI runs it on a separate manually-triggered job that holds the `OPENAI_API_KEY` secret. Local dev opt-in is `mix test --include live_openai test/allm/providers/openai_live_test.exs` (verified `ExUnit.configure/1` honors `--include` overriding `exclude:` per OTP 27 docs).

The phase's third obligation is **the Chat Completions API is the v0.2 default; the Responses API is deferred.** The phasing doc raises this as key decision (a). Chosen: **Chat Completions only.** Rationale below in Non-obvious Decision #1. The OpenAI adapter ships with `@endpoint :chat_completions` baked in; selecting `:responses` is a v0.3 phase. This narrows the wire-format surface from two to one and keeps the `response_format` translation (sub-phase 10.4) to a single shape (`%{type: "json_schema", json_schema: %{name:, schema:, strict:}}`) instead of two.

The phase's fourth obligation is **`structured_finalize` is implemented as a two-pass orchestration over the existing `ALLM.Chat.run/3` / `ALLM.Chat.stream/3` loops, not as a magic adapter feature.** The wiring lives at the *chat-runner* layer (sub-phase 10.4), not inside `ALLM.Providers.OpenAI`. The adapter's only contribution is `requires_structured_finalize?/1` which Phase 9.4's `ALLM.Capability.preflight/2` consults to auto-set `structured_finalize: true` when a caller passes both `tools: [...]` and `response_format: %{type: :json_schema, ...}` against an OpenAI engine. The two-pass execution itself (run the tool loop with `response_format: nil`; then issue a tools-disabled final call with the original `response_format` and a user-nudge message) is implemented in `ALLM.Chat.run/3` and `ALLM.Chat.stream/3` as a top-level conditional branch. Same code path for both endpoints; same code path for OpenAI and any future provider that flags `requires_structured_finalize?/1 == true`.

The phase's fifth obligation is **streaming uses `Finch` directly, NEVER `Req`.** Spec §7.2 is explicit and `lib/allm/stream_adapter.ex:8-13` re-states the rule: HTTP/2 flow control breaks for request bodies > 64 KB, and Req's SSE path does not cover OpenAI's chunking quirks. The OpenAI streaming adapter calls `Finch.build/4` with `:http1` transport, then `Finch.stream/4` with a per-chunk callback; the callback feeds `ALLM.Providers.Support.SSE.decode_chunk/2`'s line-buffered accumulator and emits ALLM events from the resulting parsed SSE messages. The `Stream.resource/3` `after_fun` calls `Finch.cancel/1` on the streaming ref to honor the consumer-halt → upstream-cancel contract within 500 ms (verified per the Phase 4 cancellation test pattern). The default Finch name is `ALLM.Finch` (Phase 10.1 starts the singleton in `ALLM.Application`); engines may inject their own via `adapter_opts: [finch_name: MyApp.Finch]`.

The phase's sixth obligation is **API keys never appear on the engine.** Spec §6.4 + Phase 2 design Non-obvious Decision #8 require `ALLM.Keys.fetch!/2` to be called at request-prep time inside the adapter, not at engine construction. Both `generate/2` and `stream/2` call `ALLM.Keys.fetch!(:openai, opts)` (the `opts` arg passes `:api_key` through if the caller supplied one per-call). The `Authorization: Bearer <key>` header is constructed inside `prepare_request/2` and `build_finch_request/3`; the key string is never assigned to a struct field that round-trips through `:erlang.term_to_binary/1` — verified in the Phase 10.2 serializability row of `test/allm/engine_roundtrip_test.exs` (an existing test extended with an OpenAI-engine row).

The phase's seventh obligation is **all retries route through `ALLM.Retry.run/3` (Phase 9.3); no second retry layer.** Spec §6.1 + Phase 9.3 Decision #14 require the engine's `:retry` field (`:default | false | keyword()`) to be the single source of truth. `ALLM.Providers.OpenAI.generate/2` wraps its HTTP loop in `ALLM.Retry.run(opts[:retry], telemetry_meta, closure)` exactly as the Phase 9.3 layer-demonstration snippet shows. Per spec §6.1 + Phase 9.3 Decision #4, the closure returns `{:ok, response} | {:retry, delay_ms, error} | {:error, error}`; the OpenAI closure parses 429 `Retry-After` headers (when present) into `delay_ms`, returns `{:retry, _, _}` for 429 / 5xx / `:timeout` per the closed `retry_on` set, and returns `{:error, _}` for everything else. **Streaming never retries** — `ALLM.Providers.OpenAI.stream/2` does not wrap in `ALLM.Retry.run/3`; per spec §6.1 the partial-output-already-delivered rule rules it out. The streaming-no-retry assertion is a meta-row in `test/allm/providers/openai_stream_wire_test.exs` (telemetry handler attached, asserts zero `[:allm, :adapter, :retry]` events fire across a stream that observes a 5xx mid-stream).

The phase's eighth obligation is **finish_reason normalization is total (every documented OpenAI string maps; unknowns map to `:other` with the raw string preserved on `Response.raw_finish_reason`).** OpenAI's documented `finish_reason` values for Chat Completions are `"stop"`, `"length"`, `"tool_calls"`, `"content_filter"`, `"function_call"` (legacy alias of `"tool_calls"`). ALLM's `Response.finish_reason` closed enum is `:stop | :length | :tool_calls | :content_filter | :error | :other` (`lib/allm/response.ex:34-40`). Mapping:

| OpenAI string | ALLM atom | Notes |
|---------------|-----------|-------|
| `"stop"` | `:stop` | Natural completion. |
| `"length"` | `:length` | `max_tokens` reached. |
| `"tool_calls"` | `:tool_calls` | Model produced one or more tool calls. |
| `"content_filter"` | `:content_filter` | OpenAI policy block. |
| `"function_call"` | `:tool_calls` | Legacy alias (deprecated by OpenAI; the wire shape carries it for older models). |
| anything else | `:other` | `Response.raw_finish_reason` carries the original string verbatim. |
| `nil` (mid-stream chunk pre-finish) | `nil` | The collector eventually replaces with the terminal value. |

The mapping is property-tested with `StreamData.string(:alphanumeric)` plus the documented set; every input produces a value in the closed enum (or `nil`) AND `raw_finish_reason` is populated when the input is non-nil. `:error` is **never** produced from a successful OpenAI response — it appears only when `ALLM.StreamCollector` folds a mid-stream `{:error, _}` event per CLAUDE.md's mid-stream-error invariant.

### Layer demonstration

**Layer B — Engine construction with OpenAI adapter (Responses API by default for GPT-5/5.5):**

```elixir
engine =
  ALLM.Engine.new(
    adapter: ALLM.Providers.OpenAI,
    model: "gpt-5.5",                              # routes to :responses per Decision #1 dispatch table
    tool_executor: ALLM.ToolExecutor.Default,
    tool_result_encoder: ALLM.ToolResultEncoder.JSON,
    params: %{reasoning_effort: :medium}           # forwarded as `reasoning: %{effort: "medium"}` per Decision #5
  )

req = ALLM.request([ALLM.user("Name three primes.")], max_tokens: 200)
# `:max_tokens` translates to `:max_output_tokens` on the Responses wire per Decision #6
{:ok, %ALLM.Response{output_text: text, finish_reason: :stop, usage: %{reasoning_tokens: rt}}} =
  ALLM.generate(engine, req)
```

**Layer B — Streaming text against OpenAI (Responses semantic events normalized to `ALLM.Event`):**

```elixir
{:ok, stream} = ALLM.stream_generate(engine, ALLM.request([ALLM.user("Haiku about Elixir.")]))

# OpenAI emits SSE events like `event: response.output_text.delta` on the Responses path
# and chunked `data: {choices:[{delta:...}]}` on the Chat-Completions path. The adapter
# normalizes BOTH into ALLM.Event's `:text_delta` etc. — the consumer sees one shape.
Enum.each(stream, fn
  {:text_delta, %{delta: d}} -> IO.write(d)
  {:message_completed, _} -> IO.puts("\n[done]")
  _ -> :ok
end)
```

**Layer B — Tool call against OpenAI (auto mode, Phase 6+ orchestration):**

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

result.final_response.output_text
# => "It's sunny in Boston."
```

**Layer B — Structured output via `structured_finalize` two-pass (sub-phase 10.4):**

```elixir
schema = %{
  type: "object",
  properties: %{name: %{type: "string"}, age: %{type: "integer"}},
  required: ["name", "age"]
}

req =
  ALLM.request(
    [ALLM.user("Make up a person and call get_weather to test.")],
    response_format: ALLM.json_schema("person", schema)
  )

# structured_finalize: true is auto-set by ALLM.Capability.preflight/2
# when LLMDB is loaded and the model lacks native (tools + json_schema) support.
{:ok, result} = ALLM.chat(engine, req.messages,
  response_format: req.response_format, structured_finalize: true)

result.final_response.message.content
# => ~s({"name": "Alice", "age": 30})
```

**Layer B — Live-provider smoke (`OPENAI_API_KEY` required, opt-in tag):**

```bash
OPENAI_API_KEY=sk-... mix test --include live_openai test/allm/providers/openai_live_test.exs
```

**Sub-phase 10.5 — Runnable example against real OpenAI:**

```bash
OPENAI_API_KEY=sk-... mix run examples/openai/01_plain_text.exs
# => prints "Hello, world." and exits 0
```

### Deliverables

- **New modules:**
  - `lib/allm/providers/openai.ex` — `ALLM.Providers.OpenAI`. Implements `ALLM.Adapter` (`generate/2`, `prepare_request/2`, `translate_options/2`) and `ALLM.StreamAdapter` (`stream/2`). Exposes `requires_structured_finalize?/1` (an extra arity-1 module function consumed by `ALLM.Capability.preflight/2`; not a `@callback` per Decision #14). All three behaviour callbacks return `%AdapterError{}` on every error path (no atom-tuple errors). Approx. 350 LOC including request-build helpers, response decoder, and finish-reason mapper.
  - `lib/allm/providers/support/sse.ex` — `ALLM.Providers.Support.SSE`. Stateless line-buffered SSE decoder. `new/0` returns an empty accumulator (binary buffer + parsed-event queue); `decode_chunk/2` takes an accumulator and an incoming chunk and returns `{events, new_accumulator}` where `events` is a list of `%{event: String.t() | nil, data: String.t(), id: String.t() | nil, retry: pos_integer() | nil}` parsed messages plus an in-band `:done` sentinel for OpenAI's `[DONE]` terminator. Approx. 120 LOC. Used by Phase 11 unchanged.
- **Modified modules:**
  - `lib/allm/application.ex` — start a default `Finch` named `ALLM.Finch` with `pool: [protocol: :http1]` so the OpenAI streaming adapter has a Finch ref out-of-the-box (engines that want a custom name still inject via `adapter_opts: [finch_name: MyApp.Finch]`).
  - `lib/allm/chat.ex` — wire the `structured_finalize: true` two-pass branch. When the resolved request has `structured_finalize == true` and `response_format != nil`, the chat-runner: (a) clones the request with `tools: [...] AND response_format: nil` and runs the existing tool loop via the unchanged `Chat.run/3` / `Chat.stream/3` machinery; (b) on natural completion (`halted_reason ∈ {:completed, :max_turns, :halt_when}`), appends the user nudge message (`Application.get_env(:allm, :structured_finalize_nudge)` || `"Now provide your final structured response."`) plus a final-shaped clone of the request with `tools: [], response_format: original_response_format`, and runs one additional adapter call; (c) returns a single `%ChatResult{}` whose `final_response` is the structured one and whose `:steps` carries every step from both passes. Roughly +60 LOC localized to two new private functions; existing happy paths take a `false` branch and remain unchanged.
  - `lib/allm/capability.ex` — extend `preflight/2` with a third rule: when `request.tools != [] AND request.response_format` matches `%{type: :json_schema, ...} AND function_exported?(adapter, :requires_structured_finalize?, 1) AND adapter.requires_structured_finalize?(request) == true`, return `{:ok, %Request{request | structured_finalize: true}}`. The contract change: `preflight/2` now returns `:ok | {:ok, Request.t()} | {:error, ValidationError.t()}` — a third success shape carrying a request rewrite (Decision #2). Existing callers of `preflight/2` who pattern-match on `:ok` get a compile-time dialyzer hint for the new shape; the runner sites (`StreamRunner.run/3`, the upcoming `Chat.run/3` / `Chat.stream/3` wire-up) handle both shapes.
  - `mix.exs` — leave `req` and `finch` deps as-is (already declared at lines 36-37). No new deps. The `:allm_conformance` path dep at line 51 is consumed by Phase 10's conformance test wrappers.
- **Test support:**
  - `test/support/openai_fixtures.ex` — `ALLM.Providers.OpenAITestFixtures`. Loads recorded JSON fixture bodies from `test/fixtures/openai/`. Exposes `chat_completion(name)` and `stream_chunks(name)` for the test suites. Eight named fixtures cover happy text, single tool call, parallel tool calls, structured output, 429 with `Retry-After`, 500, 401, malformed body. Approx. 60 LOC.
  - `test/fixtures/openai/*.json` — eight JSON files for non-streaming responses; eight `*.sse` text files for streaming chunks. Recorded once at design-doc time via the live API and committed (Decision #11).
- **New tests:**
  - `test/allm/providers/openai_test.exs` — pure unit tests for the helpers: finish-reason mapping (every OpenAI string + property test for unknowns); request-build (Chat Completions: system stays inline; Responses: `input` array shape); `translate_options/2` (the three-way endpoint × model matrix from Decision #6, plus reasoning-controls); endpoint dispatch (`gpt-5*` → `:responses`, `gpt-4*` → `:chat_completions`, `o[1-9]*` → `:responses`, explicit `adapter_opts[:endpoint]` override); key resolution at request-build time (passing `api_key:` opt overrides the env var); response decoding (Chat Completions `choices[0].message` shape AND Responses `output_text` shape); `incomplete` status mapping (Decision #19).
  - `test/allm/providers/openai_wire_test.exs` — recorded-fixture HTTP-shape tests using `Req.Test.stub`. Eight rows: happy text, single tool call, parallel tool calls, 429 with `Retry-After`, 500, 401 (`:authentication_failed`), 400 (`:invalid_request`), malformed body (`:malformed_response`). One row per documented `AdapterError` reason atom that this adapter can produce.
  - `test/allm/providers/openai_stream_wire_test.exs` — recorded-fixture streaming tests using a custom Finch transport stub that replays SSE chunks from a fixture file. Eight rows: happy text streaming, tool-call argument deltas, mid-stream 5xx, mid-stream malformed event, consumer-halt cancellation (asserts the stub's stop counter increments within 500 ms), `:usage` raw chunk pass-through, `:done` sentinel handling, structured-output two-pass.
  - `test/allm/providers/openai_live_test.exs` — `@moduletag :live_openai`. Five rows: plain text generate, streaming text, single tool call (round-trip), structured output with `structured_finalize`, session round-trip. Skipped by default; opt-in via `--include live_openai`.
  - `test/allm/providers/support/sse_test.exs` — `ALLM.Providers.Support.SSE` unit tests. Twelve rows: empty chunk, single complete event, event split across two chunks, comment line, multi-line `data:`, `[DONE]` sentinel, `id:` field, `retry:` field, multiple events in one chunk, malformed line (no `:`), CR vs LF vs CRLF line terminators, accumulator state preservation across chunks.
- **Examples (sub-phase 10.5):**
  - `examples/openai/README.md` — running instructions, key prerequisite, model expectations, expected output sketches for each script.
  - `examples/openai/01_plain_text.exs` — minimal `ALLM.generate/3` against `gpt-4.1-mini`. Asserts non-empty `output_text`.
  - `examples/openai/02_streaming_text.exs` — `ALLM.stream_generate/3` printing tokens as they arrive. Asserts at least one `:text_delta` event was observed and a single `:message_completed` event.
  - `examples/openai/03_single_tool_call.exs` — `ALLM.chat/3` with one tool (`get_weather`); asserts `halted_reason: :completed` AND `length(result.steps) >= 2`.
  - `examples/openai/04_parallel_tool_calls.exs` — `ALLM.chat/3` with two tools requested in one assistant turn; asserts both tool-result messages appear in the thread.
  - `examples/openai/05_multi_turn_chat.exs` — `ALLM.chat/3` followed by a second `ALLM.chat/3` over the augmented thread; asserts the second response references the first.
  - `examples/openai/06_structured_output.exs` — `response_format: ALLM.json_schema(...)` with `structured_finalize: true`; asserts `Jason.decode!(result.final_response.output_text)` matches the schema.
  - `examples/openai/07_manual_tool_round_trip.exs` — `ALLM.chat(engine, ..., mode: :manual)` returning `halted_reason: :manual_tool_calls` (per `lib/allm/chat.ex:644`; `:awaiting_tools` is a `Session` *status*, not a `ChatResult.halted_reason`), then a fresh `ALLM.chat/3` with the augmented thread; asserts `halted_reason: :completed` on the second call.
  - `examples/openai/08_session_round_trip.exs` — `ALLM.Session.start/3` → `:erlang.term_to_binary/1` → `:erlang.binary_to_term/1` → `ALLM.Session.reply/4`; asserts the final thread tail equals an in-memory comparison run.
  - `examples/openai/09_ask_user.exs` — tool handler returns `{:ask_user, "Which city?", []}`; asserts `halted_reason: :ask_user` AND `pending_question == "Which city?"`. Then a second turn supplies the answer; asserts `halted_reason: :completed`.
  - `examples/openai/run_all.exs` — orchestration script that invokes each numbered example in turn, collects per-script `{:ok, _}` / `{:error, _}` outcomes, and exits with a non-zero status if any failed. Used by the `/review` validation step.
- **CHANGELOG:** one line per public sub-phase (5 lines total); each cites its spec §-number.

### Spec coverage

| Spec § | Phase 10 implements |
|--------|---------------------|
| §5.4 (`response_format` canonical → wire shape; `structured_finalize`) | 10.4 — endpoint-aware translation per Decision #17; two-pass orchestration in `Chat.run/3` / `Chat.stream/3`. |
| §5.5 (`Response` shape — `id`, `output_text`, `finish_reason`, `usage`, `metadata`) | 10.2 + 10.6 — populated for both endpoints; `metadata.incomplete_details`, `metadata.reasoning` added for Responses. |
| §5.9a (`Usage` — `reasoning_tokens`) | 10.6 — populated from both endpoints' usage shapes. |
| §6.4 (key resolution at adapter-call time) | 10.2 — `ALLM.Keys.fetch!(:openai, opts)` inside `prepare_request/2` and `build_finch_request/3`. |
| §7.1 (`Adapter` callbacks) | 10.2 — `generate/2`, `prepare_request/2`, `translate_options/2`. |
| §7.2 (`StreamAdapter.stream/2` + HTTP/1) | 10.3 — `Finch.async_request/3` with `:http1`. |
| §8 (event protocol) | 10.3 — SSE chunks (both Chat Completions delta-shape AND Responses semantic-event-shape) → `:text_delta`, `:tool_call_delta`, `:message_completed`, `:raw_chunk`, `:error`. |
| §10.1 (mid-stream error fold) | 10.3 — adapter emits terminal `{:error, %AdapterError{}}` event; collector folds into `Response.finish_reason: :error`. |
| §20 (error model) | 10.2 + 10.3 — every `AdapterError.@type reason` atom mapped from a documented OpenAI failure mode (both endpoints). |
| §29 (telemetry — `[:allm, :adapter, :retry]`) | 10.2 — `ALLM.Retry.run/3` integration; emits per attempt. |
| §32.1 (initial bundled adapters — OpenAI Chat Completions + Responses) | 10.1–10.6. |

### Prerequisites

- Phases 1–9 complete. Phase 10 is purely additive at Layer B; nothing in 10 lands without the public Layer C / D entry points and the `ALLM.Retry` / `ALLM.Capability` helpers from Phase 9.
- `req ~> 0.5` already in `mix.exs:36`. No dep change.
- `finch ~> 0.19` already in `mix.exs:37`. No dep change.
- `jason ~> 1.4` already in `mix.exs:38`. No dep change.
- `ALLM.Retry.run/3` exists from Phase 9.3. The OpenAI adapter consumes it verbatim.
- `ALLM.Keys.fetch!/2` exists from Phase 2 with `:openai` already in the env-var table at `lib/allm/keys.ex:51`. No `Keys` change.
- `ALLM.Capability.preflight/2` exists from Phase 9.4 with the two `:unsupported_capability` rejection rules. Phase 10.4 extends it with the third rule (request rewrite for `structured_finalize`); the contract widens to `:ok | {:ok, Request.t()} | {:error, _}`.
- `ALLM.Test.AdapterConformance` and `ALLM.Test.StreamAdapterConformance` exist from Phase 3 and the `:allm_conformance` path dep at `mix.exs:51`. Per Q1 (2026-04-26), Phase 10 does NOT reuse them for the real OpenAI adapter; they remain in place for Fake-style scripted adapters and for third-party adapters that adopt the `adapter_opts: [script: ...]` convention. Phase 10's equivalent shape-coverage bar lives in `openai_wire_test.exs` and `openai_stream_wire_test.exs`.

### Out of scope

- **Embeddings, audio, image generation, vision input.** Spec §32.5 + §33 (out of scope for v0.2 entirely).
- **Assistants / Threads / Runs API** (`/v1/threads/{id}/runs`). Distinct from the Responses API. Out of scope for v0.2 — ALLM owns the orchestration loop via `ALLM.Chat.run/3` and `ALLM.Session`; the Assistants API would duplicate that surface.
- **`reasoning.encrypted_content`** (the optional opaque reasoning blob OpenAI returns for verification). Out of scope; the visible `reasoning.summary` (when requested via `reasoning_summary: :auto | :concise | :detailed`) is sufficient for v0.2.
- **Prompt caching.** OpenAI's prompt-caching feature uses the `cache_key` field on Chat Completions; not exposed in v0.2. A future phase may add `Request.options[:cache_key]` plumbing.
- **Logprobs.** OpenAI's `logprobs: true` toggle is not exposed; advanced users can pass it via `request.options` and it forwards through `translate_options/2` unchanged. Recovery: the field surfaces on `Response.metadata[:logprobs]` only when the caller asked for it.
- **`function_call` (legacy) request shape.** OpenAI deprecated it in favor of `tool_calls` in 2024-Q3. The adapter generates only the modern `tools` shape on the request side; the response-side legacy `"function_call"` finish_reason maps to `:tool_calls` per the table above.
- **Custom `Finch` pool tuning.** The default `ALLM.Finch` pool uses Finch defaults (`pools: %{default: [protocol: :http1]}`). Engines that need throughput tuning inject their own Finch name; ALLM does not ship a tuned pool. Documented in `@moduledoc ALLM.Providers.OpenAI`.
- **Anthropic adapter.** Phase 11. Phase 10's `ALLM.Providers.Support.SSE` is the shared helper; the Anthropic adapter consumes it without modification.
- **Real-provider conformance bar.** The Phase 3 conformance suites use stubbed transports for OpenAI in Phase 10. A future "live conformance" tag could run the same harness against the real provider with a recorded-vs-actual diff; out of scope for v0.2.

### Non-obvious decisions

1. **The adapter dispatches to one of two endpoints (`:responses` or `:chat_completions`) based on the model family; Responses is the default for GPT-5/5.5 and o-series.** Per Q3 user direction (2026-04-26: "we're up to GPT 5.5 and most models include reasoning … we mostly want support for the gpt 5 series of models"), the v0.2 OpenAI adapter ships BOTH endpoints. Endpoint selection: (a) explicit `adapter_opts[:endpoint] = :responses | :chat_completions` wins; else (b) model-family regex — `gpt-5*` AND `o[1-9]*` route to `:responses`; `gpt-4*`, `gpt-3.5*`, and any other shape route to `:chat_completions`; (c) the default-route table is a `@endpoint_dispatch` module attribute so additions (`gpt-6`, future families) are a single-line edit. Rationale: (a) GPT-5/5.5 are reasoning models and their Chat-Completions wire shape is degraded (no `reasoning.summary`, reasoning-token usage incomplete, no `incomplete_details`); the Responses API is the canonical surface; (b) the ALLM facade — `ALLM.generate/3`, `ALLM.chat/3` etc. — is endpoint-agnostic, so the dispatcher hides the wire-format split entirely from callers; (c) GPT-4* and the Amesbury/Garden/meal/unllmtd example apps continue to work via the Chat-Completions branch with zero behaviour change. **Verified against current OpenAI documentation** (context7 `/websites/developers_openai_api_reference` + `/websites/developers_openai_api`, accessed 2026-04-26): Responses API endpoint is `POST /v1/responses` with `input:` (array of `{role, content}` items, NOT `messages:`); reasoning models like `gpt-5.5` accept `reasoning: %{effort: "minimal" | "low" | "medium" | "high" | "xhigh"}` (effort levels are model-dependent — `none` is also accepted on some); response carries `output_text` directly plus `incomplete_details.reason` for token-limit halts. Chat Completions remains supported by OpenAI indefinitely and is the right surface for older model families. `Docs target: @moduledoc ALLM.Providers.OpenAI` ("Endpoint dispatch table" paragraph) + CHANGELOG entry.

2. **`ALLM.Capability.preflight/2`'s contract widens to a three-shape return.** Sub-phase 10.4 extends the Phase 9.4 contract from `:ok | {:error, ValidationError.t()}` to `:ok | {:ok, Request.t()} | {:error, ValidationError.t()}`. The new shape carries a request rewrite (currently only used for setting `structured_finalize: true`). Rationale: pre-flight is the right layer to make the auto-finalize decision because (a) it already inspects the catalog for capability; (b) it runs before adapter dispatch; (c) the alternative — a separate `Capability.rewrite_request/2` step — adds a chain link to every runner's `with` chain for one decision. The runner update is mechanical: pattern-match `{:ok, request}` and rebind, OR `:ok` and pass through. **Verified call sites as of 2026-04-26:**
    - **Production:** `lib/allm/capability.ex:146` (the function itself), `lib/allm/stream_runner.ex:120` (the only production caller — uses `:ok <-` in a `with` chain that must be widened to handle both `:ok` and `{:ok, %Request{} = request}`, rebinding the request variable in the second arm).
    - **Tests asserting the `:ok` shape exactly:** `test/allm/capability_test.exs:43, 55, 60, 77, 101` (5 rows; each must be re-asserted as `assert match?(:ok, _) or match?({:ok, %Request{}}, _)` OR pinned to `assert :ok = ...` for inputs that the rewrite branch will not touch — Phase 10.4's checklist enumerates which is which).
    - **Tests asserting `{:error, ...}`:** `test/allm/capability_test.exs:68, 88, 124, 169` and `test/allm/dep_free_test.exs:44` — unchanged by the widening.
    The Phase 10.4.2 implementation checklist's "Modify call sites" item explicitly lists each line to update; the audit is mechanical. `Docs target: @doc ALLM.Capability.preflight/2` ("Three return shapes" paragraph) + CHANGELOG entry for the contract widening.

3. **The OpenAI adapter ships a default `ALLM.Finch` started by `ALLM.Application`.** Per spec §7.2 + Phase 4 design, engines pass `adapter_opts: [finch_name: MyApp.Finch]` to inject a custom Finch ref. Without a default, first-time users would face a confusing startup error from Finch's pool registry — surprising and easily avoidable. Phase 10.1 starts `Finch.start_link(name: ALLM.Finch, pools: %{default: [protocol: :http1]})` from `ALLM.Application.start/2`. The default pool uses Finch defaults (size 50, count 1); apps that need different tuning inject a custom name. The `:http1` pin is load-bearing per spec §7.2 (HTTP/2 flow control bug for >64KB request bodies). `Docs target: @moduledoc ALLM.Providers.OpenAI` ("Finch transport defaults" paragraph) + CHANGELOG entry.

4. **The streaming adapter uses `Finch.async_request/3` with a per-chunk receive loop.** The `Stream.resource/3` `start_fun` opens the Finch ref via `Finch.async_request(req, finch_name, [])` which returns an opaque `request_ref` (a `{pool_mod, cancel_ref}` 2-tuple per `deps/finch/lib/finch.ex:617`); `next_fun` blocks on `receive` for the documented Finch message shape `{ref, {:status, status_int}} | {ref, {:headers, headers}} | {ref, {:data, chunk}} | {ref, :done}` (verified against `deps/finch/lib/finch.ex:596-604` doc-block on 2026-04-26 — note: this is a 2-tuple `{ref, payload}` with the ref as the first element, NOT the flat 3-tuple a casual reader of "async stream" might expect; the `next_fun` `receive` clauses must use the pin operator `^ref` on the captured ref to filter cross-talk from sibling Finch requests in the same process). `next_fun` decodes chunks via `ALLM.Providers.Support.SSE.decode_chunk/2`, maps parsed messages into `ALLM.Event` values, and emits them one at a time; `after_fun` calls `Finch.cancel_async_request/1` on the ref **only when the request has not already completed** — Phase 10.3 tracks `state.done` (set on receipt of `{ref, :done}`) and skips cancel for completed refs (Decision #4a) since `Finch.cancel_async_request/1` carries no documented idempotency contract. The `receive` block has a `:stream_timeout` after-clause that emits `{:error, %AdapterError{reason: :timeout}}` when no chunk arrives in the configured window. `Finch.async_request/3` is available in Finch 0.19 (verified against `mix.exs:37` constraint and `deps/finch/lib/finch.ex:607-610` on 2026-04-26). `Docs target: @doc ALLM.Providers.OpenAI.stream/2` ("Stream resource lifecycle" paragraph).

4a. **`Finch.cancel_async_request/1` is gated on `state.done == false`.** The Finch docs do not document idempotency for cancel-after-done; defensive Phase 10.3 implementation tracks completion in the `Stream.resource/3` accumulator (`state.done` flag flips on `{ref, :done}` receipt or terminal-error event) and `after_fun` calls cancel only when the flag is `false`. This avoids relying on undocumented Finch behaviour for an edge case that fires every time a stream completes naturally (every successful run hits `after_fun` with `state.done == true`). `Docs target: @doc ALLM.Providers.OpenAI.stream/2` ("after_fun cancellation contract" paragraph).

5. **Reasoning models (GPT-5*, o-series) are first-class citizens via the Responses-API branch.** Per Q3 reframe (Decision #1), reasoning models route to `:responses` automatically. Reasoning-model-specific request keys flow through `translate_options/2` per Decision #6: `reasoning_effort: :minimal | :low | :medium | :high | :xhigh` translates to `reasoning: %{effort: "<atom-as-string>"}` on the Responses wire (`reasoning_effort` is a verified Responses + Chat-Completions request key per OpenAI docs accessed 2026-04-26); `reasoning_summary: :auto | :concise | :detailed | nil` translates to `reasoning: %{summary: "<atom>"}` and is preserved on `Response.metadata.reasoning.summary` post-decode; `verbosity: :low | :medium | :high` translates to `verbosity: "<atom>"` (verified Responses + Chat-Completions key for GPT-5 family). Unknown effort/summary/verbosity atoms raise `ArgumentError` at `translate_options/2` time (defense-in-depth — the validator should have caught it). Reasoning-token counts are populated from `usage.output_tokens_details.reasoning_tokens` (Responses) or `usage.completion_tokens_details.reasoning_tokens` (Chat) into the existing `Usage.reasoning_tokens` field shipped in Phase 1 — no struct addition. The Phase 10.6 sub-phase ships the full reasoning-controls plumbing as its own deliverable so the wire-up is reviewable in isolation. `Docs target: @moduledoc ALLM.Providers.OpenAI` ("Reasoning-model support") + `@doc ALLM.Providers.OpenAI.translate_options/2`.

6. **`translate_options/2`'s `:max_tokens` rename is endpoint-aware, three-way.** OpenAI's max-tokens parameter name diverges across endpoints AND model generations. Per OpenAI docs accessed 2026-04-26 + verified against context7's published API reference:
    - **Responses API (`/v1/responses`)**: parameter is `max_output_tokens`. Used by GPT-5/5.5 and o-series.
    - **Chat Completions, newer models (`gpt-4o*`, `gpt-4.1*`, `gpt-5*` if explicitly routed)**: parameter is `max_completion_tokens`.
    - **Chat Completions, older models (`gpt-3.5-turbo`, `gpt-4`, `gpt-4-turbo`)**: parameter is `max_tokens`.
    `translate_options/2` consults two inputs: (a) the resolved endpoint (from Decision #1's dispatch), and (b) the model-string regex when on Chat Completions. The decision matrix:

    | Endpoint | Model regex | Output key |
    |----------|-------------|------------|
    | `:responses` | any | `:max_output_tokens` |
    | `:chat_completions` | `~r/^gpt-(4o|4\.1|5)/` | `:max_completion_tokens` |
    | `:chat_completions` | anything else | `:max_tokens` (passthrough) |

    Reasoning controls (`:reasoning_effort`, `:reasoning_summary`, `:verbosity`) are passed through on `:responses` (renamed into the `reasoning:` sub-map per Decision #5) and on `:chat_completions` ONLY for `gpt-5*` model families (Chat Completions accepts `reasoning_effort` + `verbosity` for GPT-5 per OpenAI docs accessed 2026-04-26); for older Chat-Completions models, those keys are silently stripped with a `Logger.debug/1` ("reasoning_effort ignored for non-reasoning model `<model>`"). Property test: 100 random `(endpoint, model, opts)` triples — every output keyword survives only if it's legal for that combination. Module attributes `@responses_max_tokens_key`, `@chat_completions_new_max_tokens_models`, `@chat_completions_reasoning_models` keep the dispatch table editable without touching the function logic. `Docs target: @doc ALLM.Providers.OpenAI.translate_options/2` ("Endpoint-aware parameter rename" paragraph).

7. **`structured_finalize: true` two-pass execution lives in `ALLM.Chat.run/3` / `ALLM.Chat.stream/3`, NOT inside `ALLM.Providers.OpenAI`.** Rationale: (a) the two-pass dance is provider-agnostic — any adapter that flags `requires_structured_finalize?/1 == true` benefits from the same orchestration; (b) putting the loop in the adapter would require adapter authors to re-implement chat-runner machinery; (c) the existing `Chat.run/3` already owns the multi-turn loop, the thread-mutation contract, and the `%ChatResult{}` build path. The wire-up is two private functions in `Chat.run/3` (and mirror in `Chat.stream/3`): `maybe_structured_finalize_branch/3` (returns the rewritten request set or passes through) and `run_finalize_pass/3` (runs the second tools-disabled call and merges the result). The unchanged tool-loop path takes the false branch and runs identically. The wire-up adds ~60 LOC across the two files; existing tests (Phase 6, 7) take the false branch and continue to pass. `Docs target: @doc ALLM.Chat.run/3` ("structured_finalize semantics" paragraph) + `@moduledoc ALLM.Providers.OpenAI` cross-reference.

8. **The `structured_finalize` user nudge defaults to `"Now provide your final structured response."` and is overridable via `Application.get_env(:allm, :structured_finalize_nudge)` AND `opts[:structured_finalize_nudge]`.** Spec §5.4 mentions the nudge is appended automatically and overridable via "`structured_finalize_nudge:` on the chat opts." Phase 10 honors both override paths: per-call opts win, then app config, then library default. The nudge is appended as a `%Message{role: :user, content: nudge}` to the thread before the second pass. Empty-string nudge is treated as "no nudge"; the second pass just re-issues the unmodified thread + the structured response_format. `Docs target: @doc ALLM.Chat.run/3` ("structured_finalize_nudge override chain" paragraph).

9. **Wire tests use `Req.Test.stub` for non-streaming and a custom Finch plug for streaming.** Rationale: `Req.Test` is the canonical Req test seam (verified against `req` 0.5+ docs); for `Finch`, there is no built-in test seam, so Phase 10 ships a `test/support/finch_stub.ex` module that registers a `Finch.HTTP1.Pool`-mock and replays SSE chunks from a fixture file. The stub honors per-test isolation via the process dictionary (`Process.put({:allm_finch_stub, ref}, chunks)`). Per-test setup is two lines: `chunks = ALLM.Providers.OpenAITestFixtures.stream_chunks(:happy_text); ALLM.Test.FinchStub.install(chunks)`. The stub is not part of the published package — `test/support/` only. `Docs target: @moduledoc ALLM.Test.FinchStub` (internal).

10. **The live-provider smoke test is `@tag :live_openai` AND is excluded by default in `test/test_helper.exs`.** Rationale: CI shouldn't burn API credits per build; local dev shouldn't fail when `OPENAI_API_KEY` isn't set. The default `mix test` invocation skips the live tests entirely. Opt-in is `mix test --include live_openai` (the CLI `--include` flag removes the named tag from the effective exclude set for that invocation; canonical ExUnit behaviour, no `ExUnit.configure/1` involved). The test_helper change **extends** the existing exclude list — verified at `test/test_helper.exs:9` the current line is `ExUnit.start(exclude: [:pending])`; Phase 10 changes it to `ExUnit.start(exclude: [:pending, :live_openai])` (do NOT replace — clobbering would silently re-enable every `@tag :pending` test in the suite). The live test file's first line is `@moduletag :live_openai` so the exclusion is module-wide. Missing-key handling uses the canonical idiom: a top-of-module conditional `if System.get_env("OPENAI_API_KEY") in [nil, ""], do: @moduletag(:skip)`, which causes ExUnit to skip the entire module without raising. `Docs target: CHANGELOG entry only` (test infra change).

11. **Fixtures are split three ways by directory: `chat_completions/`, `responses/`, `synthesized/`.** Not every wire-test scenario can be elicited from a working API key (you can't reliably induce a 401 against a valid key, can't synchronously force a 429 without burning quota, can't make the real provider return malformed JSON). Phase 10 splits fixtures into three classes:
    - **`chat_completions/` — recorded from live API against `gpt-4.1-mini`** (gated on `OPENAI_API_KEY`, one-time, via `scripts/record_openai_fixtures.exs --endpoint chat`): `happy_text.json`, `single_tool_call.json`, `parallel_tool_calls.json`, `structured_output.json`, `happy_text.sse`, `tool_call_deltas.sse`, `usage_chunk.sse`. Snapshot date 2026-04-26.
    - **`responses/` — recorded from live API against `gpt-5.5`** (gated on `OPENAI_API_KEY`, one-time, via `scripts/record_openai_fixtures.exs --endpoint responses`): `happy_text.json` (with `reasoning_effort: :minimal` to keep the recording small), `reasoning_response.json` (with `reasoning_effort: :medium` to populate `Usage.reasoning_tokens`), `single_tool_call.json`, `parallel_tool_calls.json`, `structured_output.json`, `happy_text.sse`, `tool_call_deltas.sse`, `reasoning_stream.sse`. Snapshot date 2026-04-26.
    - **`synthesized/` — hand-crafted, committed with leading-comment provenance:** `auth_failed.json` (OpenAI 401 body), `rate_limited.json` (429 + `Retry-After: 1` sidecar), `server_error.json` (500), `invalid_request.json` (400), `malformed.json` (truncated JSON), `incomplete_response.json` (Responses-API `status: "incomplete"` per Decision #19), `mid_stream_error.sse` (3 happy chunks + synthetic 5xx frame), `done_only.sse` (minimal Chat-Completions stream).
    The recorder script's `@moduledoc` enumerates the three classes and refuses to overwrite anything under `synthesized/` (it only touches `chat_completions/` and `responses/`). Each synthesized file's leading JSON `_comment` field (or SSE leading `:`-comment line) names its OpenAI doc reference and the date it was modeled. `Docs target: `test/fixtures/openai/README.md` + `scripts/record_openai_fixtures.exs` `@moduledoc`.

12. **Examples are runnable scripts under `examples/openai/`, NOT integration tests under `test/examples/`.** The phasing doc raises this as key decision (b) for Phase 12. Phase 10 chooses scripts. Rationale: (a) examples are user-facing documentation; users are likelier to read and copy `examples/openai/01_plain_text.exs` than to grep `test/`; (b) scripts run via `mix run examples/openai/<name>.exs` are self-contained and don't require the test framework — exactly how a user would invoke them; (c) the `/review` validation step shells out to `examples/openai/run_all.exs` which exits non-zero on any failure — that's the regression bar; (d) the Phase 12 example-translation tests (Amesbury / Garden / meal / unllmtd) are *separate* from these provider examples and live under `test/examples/` per the Phase 12 design. The two surfaces don't conflict. Each example script follows the same template: header comment, engine construction, single API call, assertion via `unless ..., do: System.halt(1)`. `Docs target: `examples/openai/README.md`.

13. **The `/review` validation step runs every example in `examples/openai/` against the real provider and asserts non-error exit.** Per the user's requirement, the Phase 10 review step is more involved than `/review`'s default. The reviewer (a) runs `mix test` (full suite, deterministic), (b) runs `mix test --include live_openai test/allm/providers/openai_live_test.exs` (smoke test, requires `OPENAI_API_KEY`), (c) runs `OPENAI_API_KEY=... mix run examples/openai/run_all.exs` (the orchestrator script that runs all nine numbered examples and exits non-zero on any failure), (d) records the full stdout of step (c) in the review artifact for archival. The review is BLOCKING on (a) and (c); (b) is informational only (the live test surface is narrower than the example coverage). Sub-phase 10.5's Definition of Done item explicitly references this validation flow. `Docs target: `examples/openai/README.md` + `CHANGELOG.md` entry for sub-phase 10.5.

14. **`requires_structured_finalize?/1` is a regular module function, NOT a `@callback` on `ALLM.Adapter`.** Rationale: only one v0.2 provider (OpenAI) needs the two-pass dance, and Anthropic (Phase 11) implements structured output via tool-forcing instead. Adding the callback to `ALLM.Adapter` would force every adapter author to implement it, which is overhead for a feature most providers don't need. Instead, `ALLM.Capability.preflight/2` calls `function_exported?(adapter, :requires_structured_finalize?, 1)` before invoking it; absent implementations behave as `false` and pre-flight does not auto-set `structured_finalize`. Documented in both `@moduledoc ALLM.Providers.OpenAI` ("Capability declarations") and `@doc ALLM.Capability.preflight/2` (so adapter authors discover the convention). `Docs target: @moduledoc ALLM.Providers.OpenAI` + `@doc ALLM.Capability.preflight/2`.

15. **The streaming SSE decoder lives in `ALLM.Providers.Support.SSE`, not `ALLM.Providers.OpenAI.SSE`.** Phase 11 (Anthropic) reuses it verbatim; co-locating with one provider invites an Anthropic-shipping engineer to copy-paste it. The `Support` namespace is for cross-provider helpers — analogous to `ALLM.Providers.Fake.Script` (Phase 4). The decoder is provider-agnostic: it parses the SSE wire format (per `https://html.spec.whatwg.org/multipage/server-sent-events.html`) and returns parsed message records; provider-specific interpretation of `data:` payloads happens in each adapter's chunk-to-event mapper. `Docs target: @moduledoc ALLM.Providers.Support.SSE` ("Reused by all SSE-streaming providers" paragraph).

16. **`prepare_request/2` returns the unfired `%Req.Request{}` with the API key already injected as `Authorization: Bearer <key>`.** Per spec §7.1: "the low-level escape hatch" returns a configured `Req.Request` the caller can further customize. The contract decision: should the returned request carry the resolved key, or leave it for the caller to add? Phase 10 chooses: carry the key. Rationale: (a) the most common reason to use `prepare_request/2` is to insert middleware (custom logging, tracing) BEFORE the request fires — at that point the key is already needed; (b) requiring the caller to call `ALLM.Keys.fetch!/2` themselves leaks the implementation detail of which key resolver to use; (c) callers who want to swap keys at the prepare-stage can `Req.Request.put_header(req, "authorization", "Bearer #{custom}")`. The downside: `prepare_request/2` calls `ALLM.Keys.fetch!/2` (which raises on missing key) — making `prepare_request/2` raise on missing key, NOT return `{:error, _}`. This deviates from spec §7.1's "`{:ok, Req.Request.t()} | {:error, term()}`" but matches the documented "`{:ok | :error}`" only when the failure is non-key-related (invalid request shape, etc.). `Docs target: @doc ALLM.Providers.OpenAI.prepare_request/2` ("Key resolution + raise behaviour" paragraph) + CHANGELOG entry.

17. **`response_format` translation is endpoint-aware** with a different wire-shape per endpoint, per OpenAI docs accessed 2026-04-26:

    | ALLM canonical | Chat Completions wire (`/v1/chat/completions`) | Responses wire (`/v1/responses`) |
    |----------------|------------------------------------------------|----------------------------------|
    | `nil` | omitted | omitted |
    | `:text` | omitted (OpenAI default) | `text: %{format: %{type: "text"}}` |
    | `%{type: :json_object}` | `response_format: %{type: "json_object"}` | `text: %{format: %{type: "json_object"}}` |
    | `%{type: :json_schema, name: n, schema: s, strict: b}` | `response_format: %{type: "json_schema", json_schema: %{name: n, schema: s, strict: b}}` | `text: %{format: %{type: "json_schema", name: n, schema: s, strict: b}}` |

    The translation function is `to_openai_response_format/2` (now arity-2 — takes endpoint + canonical shape); it pattern-matches each canonical shape exhaustively and raises `FunctionClauseError` on any other shape (which `ALLM.Validate.request/1` from Phase 1 should have rejected upstream — defense in depth). Property test covers all four canonical shapes round-trip-encoding through `Jason.encode!/1` for BOTH endpoints. `Docs target: @doc ALLM.Providers.OpenAI` ("response_format translation table" paragraph).

18. **The fixture-recording helper script is `scripts/record_openai_fixtures.exs` — kept out of `lib/` and `test/` to avoid adding it to the published package.** Per Phase 9.4's pattern (the test/support/llm_db.ex fake), code that only runs in dev (and never in production, never in CI's default flow) lives outside both `lib/` and `test/`. The script is not in the `:files` list at `mix.exs:60` — verified by reading `mix.exs:55-61`. It's gated on `OPENAI_API_KEY` and prints clear errors when the key is absent; it overwrites every file under `test/fixtures/openai/` in one pass. The recorder issues each canonical request against BOTH `gpt-5.5` (Responses API) and `gpt-4.1-mini` (Chat Completions API) so the fixture set covers both endpoints' wire shapes. `Docs target: `scripts/record_openai_fixtures.exs` `@moduledoc` (script-level doc).

19. **The Responses API's `incomplete` status maps to `Response.finish_reason: :length` when `incomplete_details.reason == "max_output_tokens"`, and `:other` otherwise; the raw reason is preserved on `Response.metadata.incomplete_details.reason` for inspection.** Per OpenAI Responses-API docs accessed 2026-04-26: a response carrying `status: "incomplete"` includes an `incomplete_details: %{reason: <string>}` object describing why generation stopped early. Documented reasons include `"max_output_tokens"` (token-budget exhaustion — semantically identical to Chat Completions' `finish_reason: "length"`) and `"content_filter"` (semantically identical to Chat Completions' `"content_filter"`). The mapping table:

    | Responses status | `incomplete_details.reason` | `Response.finish_reason` | `Response.metadata.incomplete_details.reason` |
    |------------------|------------------------------|--------------------------|-----------------------------------------------|
    | `"completed"` | n/a | `:stop` | (omitted) |
    | `"incomplete"` | `"max_output_tokens"` | `:length` | `"max_output_tokens"` |
    | `"incomplete"` | `"content_filter"` | `:content_filter` | `"content_filter"` |
    | `"incomplete"` | other string | `:other` | original string |
    | `"in_progress"` | n/a | `nil` (mid-stream chunk) | (omitted) |
    | `"failed"` | n/a | `:error` (folds via mid-stream-error path) | (omitted; `Response.metadata.error` carries the struct) |
    | `"cancelled"` | n/a | `:error` with `%StreamError{reason: :cancelled}` | (omitted) |

    Reasoning models can return `incomplete` with **no `output_text`** when the token budget was consumed entirely by reasoning tokens; in that case `Response.output_text == ""` AND `Response.usage.reasoning_tokens > 0`. The `:length` mapping correctly signals a budget-truncation halt to the caller; the empty `output_text` is honest about the missing content. `Docs target: @moduledoc ALLM.Providers.OpenAI` ("Status mapping for Responses API") + `@doc Response.finish_reason` cross-reference.

20. **`Response.id` carries the OpenAI response identifier from BOTH endpoints.** Chat Completions returns `id: "chatcmpl-..."` at the top level; Responses returns `id: "resp_..."` at the top level. Both populate the existing `Response.id` field shipped in Phase 1 (`lib/allm/response.ex:21`). No struct change. The `Response.request_id` field (also shipped in Phase 1, populated by Phase 9.1's telemetry layer) remains the ALLM-generated correlation id, distinct from the provider-side identifier on `Response.id`. `Docs target: @doc Response.id`.

## Behaviour & Type Contracts

### `ALLM.Providers.Support.SSE` (Layer B — new module)

```elixir
defmodule ALLM.Providers.Support.SSE do
  @typedoc "Parsed SSE message per https://html.spec.whatwg.org/multipage/server-sent-events.html."
  @type message :: %{
          event: String.t() | nil,
          data: String.t(),
          id: String.t() | nil,
          retry: pos_integer() | nil
        }

  @typedoc "Parser accumulator: pending byte buffer + queue of completed messages."
  @type accumulator :: %{
          buffer: binary(),
          partial: %{
            event: String.t() | nil,
            data: [String.t()],
            id: String.t() | nil,
            retry: pos_integer() | nil
          }
        }

  @typedoc "Sentinel emitted in-band for OpenAI's `[DONE]` terminator (provider-specific carve-out)."
  @type done_marker :: :done

  @spec new() :: accumulator()
  def new

  @spec decode_chunk(accumulator(), binary()) :: {[message() | done_marker()], accumulator()}
  def decode_chunk(acc, chunk) when is_binary(chunk)
end
```

**Invariants:**

1. **`new/0` returns an empty accumulator.** `%{buffer: "", partial: %{event: nil, data: [], id: nil, retry: nil}}`. Pure; no IO.
2. **`decode_chunk/2` is total over `binary() × accumulator()`.** Returns `{[messages_or_done_markers], new_accumulator}`. Never raises on malformed input — malformed lines are silently dropped (per the SSE spec's "ignore unrecognized fields" rule). Verified against the SSE spec's parser pseudocode.
3. **A complete event ends with `\n\n` (or `\r\n\r\n`).** Empty line is the dispatch trigger; partial events stay in `:partial` until completed.
4. **Multi-line `data:` fields are joined with `\n`.** Per the SSE spec; verified against OpenAI's tool-call deltas which sometimes split JSON across multiple `data:` lines.
5. **Comment lines (start with `:`) are silently dropped.** Per the SSE spec; OpenAI sends `:` keep-alive lines during long-running calls.
6. **Lines without a `:` are dropped.** Per the SSE spec; defensive against malformed transport.
7. **The `[DONE]` sentinel is provider-specific to OpenAI, but the decoder still returns it as `:done` in the message list** because Anthropic's analogous terminator (`event: message_stop`) is a regular SSE event the adapter handles by name. The `:done` carve-out is documented in `@moduledoc` so Anthropic-side reviewers don't blanket-pattern-match on it.
8. **The accumulator is stateless across calls** in the sense that it carries no PID or ref; it's a plain map and round-trips through `:erlang.term_to_binary/1` (verified at impl time — important for the `Stream.resource/3` `start_fun → next_fun` state thread).

### `ALLM.Providers.OpenAI` (Layer B — new module)

```elixir
defmodule ALLM.Providers.OpenAI do
  @behaviour ALLM.Adapter
  @behaviour ALLM.StreamAdapter

  @base_url "https://api.openai.com/v1"

  # Endpoint dispatch (Decision #1) — model-family regex → endpoint atom.
  @endpoint_dispatch [
    {~r/^gpt-5/i, :responses},
    {~r/^o[1-9]/i, :responses},
    {~r/^gpt-(4|3\.5)/i, :chat_completions}
  ]

  # max-tokens parameter rename (Decision #6).
  @responses_max_tokens_key :max_output_tokens
  @chat_completions_new_max_tokens_models ~r/^gpt-(4o|4\.1|5)/
  @chat_completions_reasoning_models ~r/^gpt-5/

  # Reasoning-control closed enums (Decision #5).
  @effort_atoms ~w(none minimal low medium high xhigh)a
  @summary_atoms ~w(auto concise detailed)a
  @verbosity_atoms ~w(low medium high)a

  alias ALLM.{Keys, Request, Response, Retry, Telemetry, ToolCall, Usage}
  alias ALLM.Error.{AdapterError, StreamError}
  alias ALLM.Providers.Support.SSE

  @typedoc "Endpoint atom; chosen by `dispatch_endpoint/2`."
  @type endpoint :: :responses | :chat_completions

  @spec dispatch_endpoint(String.t() | nil, keyword()) :: endpoint()
  def dispatch_endpoint(model, opts)

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

  @doc "Capability declaration consumed by ALLM.Capability.preflight/2 (Decision #14)."
  @spec requires_structured_finalize?(Request.t()) :: boolean()
  def requires_structured_finalize?(request)
end
```

**Invariants:**

1. **`generate/2` is total** over `Request.t() × keyword()`. Returns `{:ok, %Response{}}` on success or `{:error, %AdapterError{}}` on every failure shape — never raises for HTTP-shaped failures (per `@callback ALLM.Adapter.generate/2` invariant 2). Programmer errors (invalid request shape that escaped `Validate.request/1`) may raise.
2. **`generate/2` calls `ALLM.Retry.run(opts[:retry] || :default, telemetry_meta, closure)`.** Closure returns `{:ok, response}` on 2xx, `{:retry, delay_ms, %AdapterError{}}` on 429/5xx, `{:error, %AdapterError{}}` otherwise. `delay_ms` extracted from `Retry-After` header when present (parses both seconds and HTTP-date formats; HTTP-date converted to absolute milliseconds-from-now).
3. **`generate/2` calls `ALLM.Keys.fetch!(:openai, opts)` at request-build time, never at engine construction.** The key is injected as `Authorization: Bearer <key>` header on the `Req.Request`. Verified by the `engine_roundtrip_test.exs` row that constructs an OpenAI engine, ETF-round-trips it, and confirms no key-shaped string appears in the binary.
4. **`dispatch_endpoint/2` is total over `(model_string | nil) × keyword()`.** Resolution order: (a) explicit `opts[:endpoint] in [:responses, :chat_completions]` wins; (b) `adapter_opts[:endpoint]` next; (c) the `@endpoint_dispatch` regex table walks in order, first match wins; (d) default fallback is `:chat_completions` when no regex matches. `nil` model defaults to `:chat_completions`. Documented in `@doc dispatch_endpoint/2` with the table.
5. **`prepare_request/2` returns `{:ok, %Req.Request{}}` on success** (key resolved, headers injected, body encoded for the dispatched endpoint). Calls `ALLM.Keys.fetch!/2` and may raise `%EngineError{reason: :missing_key}` per Decision #16. Returns `{:error, %AdapterError{}}` only for non-key failures (invalid request shape, illegal reasoning-effort atom, etc.).
6. **`translate_options/2` is endpoint-aware per Decision #6.** Receives the dispatched endpoint via the `request.options[:endpoint]` field (Phase 10.2 sets this during `prepare_request/2`'s endpoint-resolution step) and applies the three-way max-tokens-rename matrix; reasoning controls follow Decision #5.
7. **`stream/2` returns `{:ok, lazy_enumerable}` on success.** No HTTP call fires until the consumer reduces. Pre-flight failures (key missing, invalid request, illegal reasoning-effort) return `{:error, %AdapterError{}}` synchronously.
8. **`stream/2` returns a `Stream.resource/3`-backed enumerable** with: `start_fun` opens `Finch.async_request/3`; `next_fun` pulls one event at a time from the Finch message queue using `^ref`-pinned `receive` clauses on the documented `{ref, payload}` 2-tuple shape (per Decision #4), decoding via `SSE.decode_chunk/2` and mapping via `chunk_to_events/2`, and tracks `state.done` (set on `{ref, :done}` receipt or terminal-error event); `after_fun` calls `Finch.cancel_async_request/1` **only when `state.done == false`** to honor consumer-halt cancellation within 500 ms (CI-asserted) without relying on undocumented Finch idempotency behaviour for cancel-after-done.
9. **`stream/2`'s enumerable terminates on a synthesized `:message_completed` event after the SSE `[DONE]` sentinel, OR a terminal `{:error, _}` event for any mid-stream failure.** Per spec §10.1 + CLAUDE.md mid-stream-error invariant. The collector folds `{:error, _}` into `Response.finish_reason: :error` with the error struct under `Response.metadata.error`; the call-site tuple stays `{:ok, _}`.
10. **`stream/2` honors `opts[:stream_timeout]`** via the `receive` block's after-clause. Exceeding it emits a terminating `{:error, %AdapterError{reason: :timeout}}` event.
11. **`requires_structured_finalize?/1` returns `true` when `request.tools != [] AND match?(%{type: :json_schema, ...}, request.response_format)`** — the only condition under which OpenAI's API rejects the combined call. Returns `false` otherwise.
12. **Finish-reason mapping is total per the Overview table AND per Decision #19's Responses-status table.** Property test: any string input produces a value in `Response.finish_reason()`; `Response.raw_finish_reason` carries the original string for Chat Completions; `Response.metadata.incomplete_details.reason` carries the original Responses-API string when the status was `"incomplete"`.
13. **System message handling is endpoint-aware.** Chat Completions accepts `%{role: "system", content: "..."}` inline in `messages`; pass-through unchanged. Responses API takes `input` as an array of `{role, content}` items where `system` is encoded as `{role: "system", content: <text>}` per OpenAI Responses docs accessed 2026-04-26 — the Phase 10.2 `to_responses_input/1` helper handles the conversion (it's a near-identity mapping — same role names, same content strings; only the wrapper key changes from `messages:` to `input:`). The Anthropic adapter (Phase 11) is the only one that extracts system to a top-level `system:` field.
14. **Vision content parts are rejected at `Validate.request/1` upstream** per spec §33; the adapter trusts the validator and does not re-check.

### `ALLM.Capability` (Layer B — modified contract)

```elixir
@spec preflight(ALLM.Engine.resolved_model() | nil, ALLM.Request.t()) ::
        :ok
        | {:ok, ALLM.Request.t()}
        | {:error, ALLM.Error.ValidationError.t()}
def preflight(model_ref_or_string, request)
```

**Invariants (delta from Phase 9.4):**

1. **The new `{:ok, Request.t()}` shape is returned ONLY when a request rewrite is needed.** v0.2 rewrites: `structured_finalize: true` auto-set when `request.tools != [] AND match?(%{type: :json_schema, ...}, request.response_format) AND function_exported?(adapter, :requires_structured_finalize?, 1) AND adapter.requires_structured_finalize?(request) == true`.
2. **The rewrite is idempotent.** If `request.structured_finalize == true` already, return `:ok` (no-op rewrite).
3. **The `model_ref_or_string` argument is unchanged.** Pre-flight already used it; the rewrite branch consults the catalog (when loaded) to decide whether to set `structured_finalize` based on `model_ref.capabilities.structured_finalize_required` (a new optional capability field; absent capabilities default to `function_exported?` fallback).
4. **All Phase 9.4 invariants 1–9 carry forward.** `:ok` is still the no-rewrite success shape; existing call sites that pattern-match `:ok` get the dialyzer hint for the new `{:ok, Request.t()}` arm and update their handler.

### `ALLM.Chat` (Layer C — modified)

```elixir
# New private function in ALLM.Chat
@spec maybe_structured_finalize/3 :: (ALLM.Engine.t(), ALLM.Request.t(), keyword()) ::
        {:ok, ALLM.ChatResult.t()}
        | {:error, ALLM.Error.AdapterError.t() | ALLM.Error.EngineError.t() | ALLM.Error.ValidationError.t()}
defp maybe_structured_finalize(engine, request, opts)
```

**Invariants:**

1. **The two-pass branch fires only when `request.structured_finalize == true AND request.response_format != nil`.** Both conditions are required; setting one without the other passes through unchanged.
2. **Pass 1 clones the request with `response_format: nil`** (tools preserved). Runs `Chat.run/3` (or `Chat.stream/3`) verbatim. Halts naturally on `:completed`, `:max_turns`, or `:halt_when`.
3. **Pass 2 fires only when pass 1 halted on `{:completed, :max_turns, :halt_when}`.** Halts on `{:ask_user, :tool_error, atom()}` skip pass 2 — return the pass-1 result with `final_response` from pass 1. Documented in the halt-reason table extension below.
4. **Pass 2 appends `%Message{role: :user, content: nudge}` to the thread** before issuing the second adapter call. `nudge` is resolved as `opts[:structured_finalize_nudge] || Application.get_env(:allm, :structured_finalize_nudge) || "Now provide your final structured response."` (Decision #8). Empty-string nudge skips the append step.
5. **Pass 2 issues the request with `tools: [], response_format: original_response_format, structured_finalize: false`.** Single adapter round-trip; no tool loop on pass 2.
6. **The merged `%ChatResult{}` carries `:steps` from BOTH passes,** `:final_response` from pass 2, `:halted_reason` from pass 2 (typically `:completed`), and `:thread` from pass 2. The `:metadata` map carries `%{structured_finalize: %{pass_1_halted: pass_1_halted_reason}}` for observability.
7. **Stream-equivalence** still holds: `Chat.run/3 ≡ Chat.stream/3 |> StreamCollector.to_chat_result/1` for `structured_finalize: true` requests, because both paths run the same two-pass orchestration. The stream variant emits an `{:chat_completed, ...}` event after each pass internally (the first pass's `chat_completed` is suppressed; only the second pass's bubbles up to the consumer per Phase 7's single-terminal invariant).

### Atom vocabulary additions

This phase adds **zero** new closed-enum atoms. Every error reason fired by the OpenAI adapter is already in `ALLM.Error.AdapterError.@type reason` (`lib/allm/error/adapter_error.ex:32-43`):

| AdapterError reason | OpenAI HTTP situation |
|---------------------|------------------------|
| `:authentication_failed` | 401 (invalid or missing API key) |
| `:rate_limited` | 429 |
| `:invalid_request` | 400 (bad shape, unknown param) |
| `:content_filter` | 400 with content-policy body marker |
| `:context_length_exceeded` | 400 with `code: "context_length_exceeded"` body marker |
| `:provider_unavailable` | 500, 502, 503, 504 |
| `:timeout` | request_timeout / stream_timeout exceeded |
| `:network_error` | TCP/TLS/DNS failure |
| `:malformed_response` | 200 with unparseable JSON body |
| `:unsupported_feature` | o-series model rejection (Decision #5) |
| `:unknown` | catch-all for unclassifiable shapes |

`StreamError` reasons (existing per `lib/allm/error/stream_error.ex:14-19`) used by the streaming adapter:

| StreamError reason | OpenAI streaming situation |
|--------------------|----------------------------|
| `:adapter_error` | mid-stream wrap of an `%AdapterError{}` (e.g., 5xx mid-response) |
| `:cancelled` | consumer halted the stream |
| `:timeout` | transport-level timeout between chunks |
| `:malformed_event` | SSE line could not be parsed |
| `:unknown` | catch-all |

Verified against committed `@legal_reasons` in both error modules on 2026-04-25.

### Idiomatic Elixir requirements

- **`Req.Test.stub/1` for non-streaming wire tests** — verified canonical Req test seam per `req` 0.5+ docs (https://hexdocs.pm/req/Req.Test.html); per-test process-isolated.
- **`Finch.async_request/3` + `Finch.cancel_async_request/1` for streaming** — verified Finch 0.19 API. The async-request shape returns `Finch.async_request_id()` (an opaque term) which the `Stream.resource/3` `after_fun` passes to `cancel_async_request/1`. Verified at impl time on the project's `finch ~> 0.19` constraint.
- **`Stream.resource/3` (NEVER `Stream.unfold/2`)** — per `AGENT_DESIGN_SPEC.md` § Elixir-specific. `resource/3` has explicit `after_fun` cleanup; `unfold/2` does not.
- **`receive` blocks with `after` clauses** for the streaming `next_fun` — `:stream_timeout` is the after-value; exceeding emits a terminating `:error` event.
- **`String.to_existing_atom/1`** for finish-reason strings only when the input is in the documented closed set; unknown strings map to `:other` directly via case-clause (no atom creation from untrusted input).
- **`Jason.encode!/1` + `Jason.decode!/1`** for request/response body — same idiom as the rest of the codebase. JSON encoding errors raise (caller's mistake — schema validation should have caught it upstream).
- **`@behaviour` + `@impl`** for both `ALLM.Adapter` and `ALLM.StreamAdapter` — dialyzer flags missing or extra callbacks.
- **`function_exported?/3`** for the `requires_structured_finalize?/1` capability check inside `ALLM.Capability` — same idiom as `Adapter.translate_options/2`'s optional-callback pattern.

## Module Tree

```
lib/allm/
├── application.ex                                (MODIFY — start ALLM.Finch with HTTP/1 pool)
├── chat.ex                                       (MODIFY — wire structured_finalize two-pass branch in run/3 and stream/3)
├── capability.ex                                 (MODIFY — extend preflight/2 with structured_finalize auto-set; widen contract to :ok | {:ok, Request.t()} | {:error, _})
└── providers/
    ├── openai.ex                                 (NEW — ALLM.Providers.OpenAI; both behaviours)
    └── support/
        └── sse.ex                                (NEW — ALLM.Providers.Support.SSE; line-buffered SSE decoder)

test/allm/
├── chat_run_test.exs                             (MODIFY — add structured_finalize two-pass row)
├── chat_stream_test.exs                          (MODIFY — add structured_finalize two-pass stream-equivalence row)
├── capability_test.exs                           (MODIFY — add preflight rewrite shape rows)
└── providers/
    ├── openai_test.exs                           (NEW — unit tests for helpers; finish-reason mapping property)
    ├── openai_wire_test.exs                      (NEW — Req.Test.stub-backed wire-shape tests; eight error-reason rows)
    ├── openai_stream_wire_test.exs               (NEW — Finch-stub streaming wire tests; eight rows including cancellation timing)
    ├── openai_live_test.exs                      (NEW — @moduletag :live_openai; five live-provider rows; skipped by default)
    └── support/
        └── sse_test.exs                          (NEW — twelve SSE-decoder unit rows)

test/support/
├── openai_fixtures.ex                            (NEW — ALLM.Providers.OpenAITestFixtures; loads JSON + SSE fixtures)
└── finch_stub.ex                                 (NEW — ALLM.Test.FinchStub; per-test SSE chunk replay)

test/fixtures/openai/
├── README.md                                     (NEW — fixture-recording instructions; one-time gated on OPENAI_API_KEY)
├── chat_completions/
│   ├── happy_text.json                           (NEW — recorded gpt-4.1-mini response)
│   ├── single_tool_call.json                     (NEW)
│   ├── parallel_tool_calls.json                  (NEW)
│   ├── structured_output.json                    (NEW)
│   ├── happy_text.sse                            (NEW — recorded streaming chunks)
│   ├── tool_call_deltas.sse                      (NEW)
│   └── usage_chunk.sse                           (NEW — `usage:` event per modern Chat Completions streaming)
├── responses/
│   ├── happy_text.json                           (NEW — recorded gpt-5.5 response, reasoning_effort: :minimal)
│   ├── reasoning_response.json                   (NEW — recorded gpt-5.5 with reasoning_effort: :medium and Usage.reasoning_tokens populated)
│   ├── single_tool_call.json                     (NEW)
│   ├── parallel_tool_calls.json                  (NEW)
│   ├── structured_output.json                    (NEW)
│   ├── happy_text.sse                            (NEW — recorded streaming with `event: response.output_text.delta`)
│   ├── tool_call_deltas.sse                      (NEW — `event: response.function_call_arguments.delta` + `.done`)
│   └── reasoning_stream.sse                      (NEW — `event: response.reasoning_summary.delta` chunks)
├── synthesized/                                  (synthesized — leading comment cites OpenAI doc reference)
│   ├── rate_limited.json                         (NEW — 429 body + Retry-After: 1 in `.headers.json` sidecar)
│   ├── server_error.json                         (NEW — 500 body)
│   ├── auth_failed.json                          (NEW — 401 body)
│   ├── invalid_request.json                      (NEW — 400 body)
│   ├── malformed.json                            (NEW — 200 with broken JSON)
│   ├── incomplete_response.json                  (NEW — Responses-API `status: "incomplete"` shape per Decision #19)
│   ├── mid_stream_error.sse                      (NEW — happy chunks then 5xx event)
│   └── done_only.sse                             (NEW — minimal Chat Completions: just [DONE])

test/
└── test_helper.exs                               (MODIFY — exclude :live_openai by default)

examples/openai/
├── README.md                                     (NEW — running instructions, key prereq, expected outputs)
├── 01_plain_text.exs                             (NEW)
├── 02_streaming_text.exs                         (NEW)
├── 03_single_tool_call.exs                       (NEW)
├── 04_parallel_tool_calls.exs                    (NEW)
├── 05_multi_turn_chat.exs                        (NEW)
├── 06_structured_output.exs                      (NEW)
├── 07_manual_tool_round_trip.exs                 (NEW)
├── 08_session_round_trip.exs                     (NEW)
├── 09_ask_user.exs                               (NEW)
└── run_all.exs                                   (NEW — orchestrator script; exits non-zero on any failure)

scripts/
└── record_openai_fixtures.exs                    (NEW — one-time fixture recorder; gated on OPENAI_API_KEY; not in mix package files)
```

Test files mirror source 1:1 under `test/allm/providers/` and `test/allm/providers/support/`. The `test/support/` additions register under `elixirc_paths(:test)` automatically. The `test/fixtures/openai/` directory is plain data — Elixir doesn't compile it. The `examples/` directory is plain `.exs` scripts — runnable via `mix run` but not part of `mix test`. The `scripts/` directory is dev-only and not in the `mix.exs` `:files` list (verified at `mix.exs:60`).

## Phases

### Phase 10.1: `ALLM.Providers.Support.SSE` — line-buffered SSE decoder + `ALLM.Finch` default (Layer B)

**Goal:** Ship `ALLM.Providers.Support.SSE` as a stateless, provider-agnostic SSE decoder; start `ALLM.Finch` from `ALLM.Application` so the OpenAI streaming adapter has a default Finch ref.

**Spec sections:** §7.2 (HTTP/1 streaming guidance).

**Layer:** B.

#### 10.1.1 Test Plan

`test/allm/providers/support/sse_test.exs` (NEW):

- `new/0` returns the empty accumulator shape per Invariant 1.
- `decode_chunk(acc, "")` returns `{[], acc}`.
- `decode_chunk/2` with one complete event (`"data: hello\n\n"`) returns `[%{event: nil, data: "hello", id: nil, retry: nil}]` and an empty accumulator.
- `decode_chunk/2` with an event split across two chunks (`"data: he"` then `"llo\n\n"`) returns `[]` then `[%{data: "hello", ...}]`.
- `decode_chunk/2` with a comment line (`": keep-alive\n"`) drops it.
- `decode_chunk/2` with multi-line `data:` (`"data: line1\ndata: line2\n\n"`) joins with `\n` → `"line1\nline2"`.
- `decode_chunk/2` with `[DONE]` sentinel (`"data: [DONE]\n\n"`) returns `[:done]`.
- `decode_chunk/2` with `id:` field carries it through.
- `decode_chunk/2` with `retry:` field parses to `pos_integer()`.
- `decode_chunk/2` with multiple events in one chunk returns them in order.
- `decode_chunk/2` with malformed line (no `:`) drops it silently.
- `decode_chunk/2` accepts CR, LF, and CRLF terminators (per the SSE spec).
- Accumulator round-trips through `:erlang.term_to_binary/1` (Invariant 8).

`test/allm/application_test.exs` (NEW):

- `Application.started_applications/0` lists `:allm` and `:finch`.
- `Process.whereis(ALLM.Finch)` returns a non-nil pid after app start.
- The `ALLM.Finch` pool uses `protocol: :http1` (verified by inspecting Finch's pool registry).

#### 10.1.2 Implementation Checklist

- [ ] Create `lib/allm/providers/support/sse.ex` with `new/0` and `decode_chunk/2` per the contract.
- [ ] Modify `lib/allm/application.ex`: add `Finch.child_spec(name: ALLM.Finch, pools: %{default: [protocol: :http1]})` to the supervisor children list.
- [ ] Write `test/allm/providers/support/sse_test.exs` per the test plan.
- [ ] Write `test/allm/application_test.exs` per the test plan.

#### 10.1.3 Verification

```bash
mix test test/allm/providers/support/sse_test.exs test/allm/application_test.exs
mix test                        # full suite still green
mix credo --strict lib/allm/providers/support/sse.ex lib/allm/application.ex
mix dialyzer
```

### Phase 10.2: `ALLM.Providers.OpenAI` non-streaming `Adapter` impl (Layer B)

**Goal:** Implement `generate/2`, `prepare_request/2`, and `translate_options/2` against OpenAI Chat Completions; integrate `ALLM.Retry.run/3`; map every documented OpenAI error shape to an `%AdapterError{}` reason atom; pass the Phase 3 `AdapterConformance` harness.

**Spec sections:** §6.4 (key resolution), §7.1 (callbacks), §20 (error model), §32.1 (initial bundled adapters).

**Layer:** B.

#### 10.2.1 Test Plan

`test/allm/providers/openai_test.exs` (NEW):

- `translate_options([max_tokens: 100], %Request{model: "gpt-4o-mini"})` returns `[max_completion_tokens: 100]`.
- `translate_options([max_tokens: 100], %Request{model: "gpt-4.1-mini"})` returns `[max_completion_tokens: 100]`.
- `translate_options([max_tokens: 100], %Request{model: "gpt-3.5-turbo"})` returns `[max_tokens: 100]` (unchanged).
- `translate_options([temperature: 0.7], %Request{model: "gpt-4o"})` returns `[temperature: 0.7]` (only `:max_tokens` is renamed).
- Property test: 100 random model strings × random `:max_tokens` values; gpt-4o/4.1 inputs rename, others pass through.
- Finish-reason mapping: every documented OpenAI string (`"stop"`, `"length"`, `"tool_calls"`, `"content_filter"`, `"function_call"`) maps per the table.
- Property test (finish-reason): 100 random strings — every output ∈ `Response.finish_reason()` ∪ `[nil]`; `Response.raw_finish_reason` populated when input non-nil.
- `requires_structured_finalize?/1` returns `true` for `%Request{tools: [tool], response_format: %{type: :json_schema, ...}}`; `false` for any other shape.
- `prepare_request/2` returns `%Req.Request{}` with `Authorization: Bearer <key>` header when `ALLM.Keys.Store.put(:openai, "sk-test")` is set.
- `prepare_request/2` raises `%EngineError{reason: :missing_key}` when no key resolver yields a value.
- `prepare_request/2` for an o-series model returns `{:error, %AdapterError{reason: :unsupported_feature}}`.

`test/allm/providers/openai_wire_test.exs` (NEW — `Req.Test.stub`-backed):

- Happy-path 200: returns `{:ok, %Response{output_text: "hello", finish_reason: :stop}}`.
- 401: returns `{:error, %AdapterError{reason: :authentication_failed, status: 401}}`.
- 400 (invalid request): returns `{:error, %AdapterError{reason: :invalid_request, status: 400}}`.
- 400 with `code: "context_length_exceeded"` body: returns `{:error, %AdapterError{reason: :context_length_exceeded}}`.
- 400 with content-filter body marker: returns `{:error, %AdapterError{reason: :content_filter}}`.
- 429 with `Retry-After: 1`: `ALLM.Retry.run/3` retries after 1000 ms; emits one `[:allm, :adapter, :retry]` event; second attempt's stub returns 200 → `{:ok, %Response{}}`.
- 429 exhausting retries (3 attempts): `{:error, %AdapterError{reason: :rate_limited}}` after two retry events.
- 500: `ALLM.Retry.run/3` retries; second attempt 200 → `{:ok, %Response{}}`.
- 500 exhausting: `{:error, %AdapterError{reason: :provider_unavailable}}`.
- 200 with malformed JSON: `{:error, %AdapterError{reason: :malformed_response}}`.
- TCP/connection-refused (stub raises `Mint.TransportError`): `{:error, %AdapterError{reason: :network_error}}`.
- Single tool call: returns a `%Response{tool_calls: [%ToolCall{}]}` with `finish_reason: :tool_calls`.
- Parallel tool calls: returns `%Response{tool_calls: [tc1, tc2]}` with both ids preserved.
- Key threading: setting `opts[:api_key] = "sk-override"` overrides the env-var key; the stub asserts the `Authorization` header value.

`test/allm/providers/openai_conformance_test.exs` (NEW):

- `use ALLM.Test.AdapterConformance, adapter: ALLM.Providers.OpenAI, opts: [...stub_setup...]`. The harness's full case matrix runs and passes.

#### 10.2.2 Implementation Checklist

- [ ] Create `lib/allm/providers/openai.ex` with the module shape from the contract section.
- [ ] Implement `generate/2`: build `%Req.Request{}` via `prepare_request/2`, wrap `Req.request/1` in `ALLM.Retry.run/3` with the closure parsing 429/5xx/`:timeout` per the retry table, decode the response body to `%Response{}`.
- [ ] Implement `prepare_request/2`: resolve key via `ALLM.Keys.fetch!/2`, build URL (`@base_url <> "/chat/completions"`), set headers (`Authorization: Bearer <key>`, `Content-Type: application/json`), encode body via `to_openai_request_body/1` (composes `to_openai_messages/1` + `to_openai_tools/1` + `to_openai_response_format/1` + `translate_options/2`).
- [ ] Implement `translate_options/2`: rename `:max_tokens` → `:max_completion_tokens` for `@new_max_tokens_models` matches; pass through everything else.
- [ ] Implement `requires_structured_finalize?/1`: pattern-match for `tools != [] AND match?(%{type: :json_schema, ...}, response_format)`.
- [ ] Implement `from_openai_response/2`: decode `%{"choices" => [%{"message" => …, "finish_reason" => …}], "usage" => …, "id" => …}` to `%Response{}`. Map finish_reason per the table; populate `raw_finish_reason` for non-canonical values; build `%Usage{}` from `prompt_tokens` / `completion_tokens` / `total_tokens`.
- [ ] Implement `from_openai_error/3`: classify a 4xx/5xx response into `%AdapterError{}`. Argument order: `(status, body, headers)`.
- [ ] Add o-series rejection at the top of both `generate/2` and `stream/2`.
- [ ] Record fixtures via `scripts/record_openai_fixtures.exs` (one-time, gated on `OPENAI_API_KEY`).
- [ ] Write `test/allm/providers/openai_test.exs` and `test/allm/providers/openai_wire_test.exs` per the test plans.
- [ ] Verify the 14-row wire matrix covers every `AdapterError.@type reason` atom that this adapter can produce (per Decision #18).

#### 10.2.3 Verification

```bash
mix test test/allm/providers/openai_test.exs
mix test test/allm/providers/openai_wire_test.exs
mix test                        # full suite still green
mix credo --strict lib/allm/providers/openai.ex
mix dialyzer
```

### Phase 10.3: `ALLM.Providers.OpenAI` streaming `StreamAdapter` impl (Layer B)

**Goal:** Implement `stream/2` against OpenAI Chat Completions streaming endpoint via `Finch.async_request/3`; map SSE chunks to `ALLM.Event` values; honor consumer-halt cancellation within 500 ms; pass the Phase 3 `StreamAdapterConformance` harness.

**Spec sections:** §7.2 (HTTP/1 streaming), §8 (event protocol), §10.1 (mid-stream error fold).

**Layer:** B.

#### 10.3.1 Test Plan

`test/allm/providers/openai_stream_wire_test.exs` (NEW — `ALLM.Test.FinchStub`-backed):

- Happy text streaming: `chunks` from `happy_text.sse` → events: `[{:text_delta, _}, …, {:message_completed, _}]`. The collector folds to `%Response{output_text: full_text, finish_reason: :stop}`.
- Tool call deltas: `chunks` from `tool_call_deltas.sse` → events: `[{:tool_call_started, _}, {:tool_call_delta, _}, …, {:tool_call_completed, _}, {:message_completed, _}]`. Final response carries `tool_calls: [%ToolCall{arguments: parsed_map}]`.
- **Parallel tool-call deltas** (parity with the non-streaming parallel-tool-calls row in 10.2.1): `chunks` interleave deltas for two distinct tool-call ids → final response carries `tool_calls: [%ToolCall{id: "call_a", ...}, %ToolCall{id: "call_b", ...}]` with both arguments fully reassembled.
- **`:authentication_failed` pre-flight** (parity with the non-streaming 401 row): the stub responds 401 BEFORE any `data:` chunk is sent → `stream/2` returns `{:error, %AdapterError{reason: :authentication_failed, status: 401}}` synchronously (no stream opened).
- **`:invalid_request` pre-flight** (parity with the non-streaming 400 row): stub responds 400 with the documented body marker → `{:error, %AdapterError{reason: :invalid_request, status: 400}}` synchronously.
- Mid-stream 5xx: `chunks` switch from text deltas to a 503 SSE event mid-stream → terminal `{:error, %AdapterError{reason: :provider_unavailable}}` event; the call-site tuple is `{:ok, stream}` (per CLAUDE.md mid-stream-error rule).
- **`:content_filter` mid-stream**: stub emits two text deltas then a content-filter terminal frame (per OpenAI's documented streaming content-filter shape) → terminal `{:error, %AdapterError{reason: :content_filter}}` event.
- **Mid-stream `:network_error` (TCP drop)**: stub closes the underlying socket after two chunks without sending `[DONE]` → terminal `{:error, %StreamError{reason: :unknown}}` (or `:adapter_error` wrapping a `%AdapterError{reason: :network_error}` — the exact mapping is verified at impl time against `Finch`'s `{ref, :error, reason}` shape, which is how Finch reports transport-level failures distinct from `:done`).
- Mid-stream malformed event: `chunks` include an unparseable line → terminal `{:error, %StreamError{reason: :malformed_event}}` event.
- Consumer halt: `Stream.take(stream, 2)` halts after 2 events; `ALLM.Test.FinchStub`'s cancellation-observer counter increments within 500 ms of halt (asserted with `assert_receive` + monotonic-time ≤ 500). Confirms the `state.done`-gated cancel path (Decision #4a) actually fires.
- `:usage` raw chunk: `chunks` include OpenAI's `usage:` event (modern Chat Completions streaming) → `%Response.usage` populated post-collection.
- `[DONE]` sentinel: any stream ending in `data: [DONE]\n\n` produces a `:message_completed` event before stream end.
- `:stream_timeout: 100` with a stub that delays > 100 ms between chunks: terminal `{:error, %AdapterError{reason: :timeout}}`.
- Streaming-no-retry meta-row: attach `[:allm, :adapter, :retry]` handler; consume a stream that observes a 5xx mid-stream; assert zero retry events fire (per the spec §6.1 streaming-no-retry rule).

Total: 13 streaming wire rows (parity with the 14 non-streaming rows; the missing one is `:context_length_exceeded`, which OpenAI rejects pre-flight at the request validator and never produces mid-stream — the non-streaming row exercises that pre-flight path which is shared with the streaming adapter and would duplicate coverage).

`test/allm/providers/openai_stream_conformance_test.exs` (NEW):

- `use ALLM.Test.StreamAdapterConformance, stream_adapter: ALLM.Providers.OpenAI, opts: [finch_plug: ALLM.Test.FinchStub]`. Full conformance matrix passes.

`test/support/finch_stub.ex` (NEW):

- `install(chunks)` registers a per-test stub that replays `chunks` (a list of binaries) when the test's process makes a Finch async request.
- Replay timing: each chunk arrives ~1 ms apart by default; `install(chunks, delay_ms: ms)` overrides for timeout tests.
- Cancellation observer: `cancel_count(ref)` returns the number of times `Finch.cancel_async_request/1` was called against the stub's ref. Used by halt-time tests.

#### 10.3.2 Implementation Checklist

- [ ] Implement `stream/2` in `lib/allm/providers/openai.ex`: pre-flight (key, o-series rejection, validate request); build a `Finch.Request` via `Finch.build/4` with `:http1`; return `{:ok, Stream.resource(start_fun, next_fun, after_fun)}`.
- [ ] `start_fun`: `Finch.async_request(req, finch_name, [])` returns `{:ok, ref}`; initialize state `%{ref: ref, sse_acc: SSE.new(), buffered: [], status: nil}`.
- [ ] `next_fun`: if `state.buffered != []`, emit head; else `receive` Finch messages with `after opts[:stream_timeout]` clause; on `{:data, ref, chunk}` call `SSE.decode_chunk/2`, run each parsed message through `chunk_to_events/2`, push to buffered, emit head; on `{:done, ref}` synthesize `{:message_completed, _}` if not already emitted; on `{:headers, ref, headers}` validate 2xx (4xx/5xx → terminal `{:error, %AdapterError{}}`); on receive timeout emit terminal `{:error, %AdapterError{reason: :timeout}}`.
- [ ] `after_fun`: `Finch.cancel_async_request(state.ref)` (idempotent — safe even if the ref already completed).
- [ ] Implement `chunk_to_events/2`: pattern-match the parsed SSE message's `data` JSON shape (`%{"choices" => [%{"delta" => …, "finish_reason" => fr}]}`); emit `{:text_delta, %{delta: text}}` for content fragments; emit `{:tool_call_started, _}` / `{:tool_call_delta, _}` / `{:tool_call_completed, _}` per the OpenAI streaming tool-call shape; emit `{:raw_chunk, {:usage, usage_map}}` for `usage:` events. The `[DONE]` marker triggers a synthetic `:message_completed`.
- [ ] Create `test/support/finch_stub.ex` per the contract.
- [ ] Write `test/allm/providers/openai_stream_wire_test.exs` per the test plan; verify all 13 rows cover the `AdapterError` + `StreamError` reason atoms producible mid-stream (per Q1 — this matrix replaces the streaming-conformance harness for real adapters).
- [ ] Verify cancellation timing: a `Stream.take(stream, 2)` halts within 500 ms of consumer halt (CI tolerance asserted via `System.monotonic_time(:millisecond)`).

#### 10.3.3 Verification

```bash
mix test test/allm/providers/openai_stream_wire_test.exs
mix test                        # full suite still green
mix credo --strict lib/allm/providers/openai.ex
mix dialyzer
```

### Phase 10.4: `response_format` translation + `structured_finalize` two-pass + capability auto-set (Layer B)

**Goal:** Translate ALLM's canonical `response_format` shapes to OpenAI's wire format; implement the two-pass `structured_finalize` orchestration in `ALLM.Chat.run/3` / `ALLM.Chat.stream/3`; extend `ALLM.Capability.preflight/2` to auto-set `structured_finalize: true` based on `requires_structured_finalize?/1`.

**Spec sections:** §5.4 (response_format + structured_finalize).

**Layer:** B.

#### 10.4.1 Test Plan

`test/allm/providers/openai_test.exs` (extends 10.2.1 with):

- `to_openai_response_format(nil)` returns `nil` (omitted from request body).
- `to_openai_response_format(:text)` returns `nil`.
- `to_openai_response_format(%{type: :json_object})` returns `%{type: "json_object"}`.
- `to_openai_response_format(%{type: :json_schema, name: "foo", schema: %{...}, strict: true})` returns `%{type: "json_schema", json_schema: %{name: "foo", schema: %{...}, strict: true}}`.
- `to_openai_response_format(%{type: :unknown})` raises `FunctionClauseError` (defense in depth — `Validate.request/1` should have caught it).

`test/allm/capability_test.exs` (MODIFY — extends 9.4.1 with):

- `preflight/2` with `engine.adapter = ALLM.Providers.OpenAI`, `request.tools = [tool]`, `request.response_format = %{type: :json_schema, ...}`, AND `request.structured_finalize = false`: returns `{:ok, %Request{request | structured_finalize: true}}`.
- `preflight/2` with the same but `request.structured_finalize = true` already: returns `:ok` (idempotent rewrite).
- `preflight/2` with `engine.adapter = ALLM.Providers.Fake` (no `requires_structured_finalize?/1` exported): returns `:ok` (no rewrite).
- `preflight/2` shape preservation: existing `:ok` and `{:error, _}` rows continue to pass with no change.

`test/allm/chat_run_test.exs` (MODIFY — add):

- `chat/3` with a Fake engine scripted for two passes (pass 1 emits a tool call; pass 2 emits structured JSON), `tools: [tool]`, `response_format: %{type: :json_schema, ...}`, `structured_finalize: true`: returns `%ChatResult{halted_reason: :completed, final_response: %Response{output_text: ~s({...})}, steps: [step1_tool, step1_after_tool, step2_finalize]}`.
- Pass 1 halt on `:ask_user` skips pass 2: result carries `halted_reason: :ask_user`, `final_response` is from pass 1.
- Pass 1 halt on `:tool_error` skips pass 2: result carries `halted_reason: :tool_error`.
- `:max_turns` is consumed by pass 1; pass 2's single call does NOT decrement the budget (it's outside the loop).
- `opts[:structured_finalize_nudge] = "Custom nudge"` overrides the default; the second pass's thread-tail `:user` message has the custom content.
- `Application.put_env(:allm, :structured_finalize_nudge, "App default")` honored when no per-call opt.
- Empty-string nudge skips the user message append; pass 2 issues the un-augmented thread.
- `metadata.structured_finalize.pass_1_halted == :completed` on the final result.

`test/allm/chat_stream_test.exs` (MODIFY — add):

- `stream/3` with the same two-pass Fake setup: events flow `{adapter events for pass 1, …, step_completed, adapter events for pass 2, …, step_completed, chat_completed}`. The stream emits exactly one `:chat_completed` (pass 1's is suppressed).
- Stream-equivalence row: `chat/3 ≡ stream/3 |> StreamCollector.to_chat_result/1` for `structured_finalize: true` requests, no relaxation.

#### 10.4.2 Implementation Checklist

- [ ] Implement `to_openai_response_format/1` in `lib/allm/providers/openai.ex` per the table in Decision #17.
- [ ] Implement `maybe_structured_finalize/3` in `lib/allm/chat.ex` per Decision #7. Wire into `Chat.run/3` and `Chat.stream/3` as a top-level branch.
- [ ] Implement `run_finalize_pass/3` in `lib/allm/chat.ex`. Resolves the nudge (per Decision #8), appends to thread, issues a single adapter call with `tools: []` and the original `response_format`, returns the merged `%ChatResult{}`.
- [ ] Modify `lib/allm/capability.ex`'s `preflight/2`: add the third branch per Phase 10.4 contract; widen the return type and `@spec`. Update the `@type preflight_result` alias.
- [ ] Modify the single production call site at `lib/allm/stream_runner.ex:120`: replace `:ok <- Capability.preflight(resolved_request.model, request)` with a `{:ok, request} <- normalize_preflight(...)` pattern (where `normalize_preflight/2` upgrades `:ok` to `{:ok, request}` for the no-rewrite case so the `with` chain rebinds uniformly). The rebound `request` flows into `dispatch/3` as the (possibly-rewritten) request for adapter dispatch.
- [ ] Audit and update `test/allm/capability_test.exs` per the call-site enumeration in Decision #2: 5 rows asserting `:ok` exactly (lines 43, 55, 60, 77, 101) — keep `:ok` for inputs the rewrite branch does NOT touch (pure model-only assertions, dep-absent path); convert any row whose inputs satisfy the rewrite predicate (`tools != [] AND json_schema response_format AND OpenAI adapter`) to `match?({:ok, %Request{structured_finalize: true}}, _)`.
- [ ] Audit `test/allm/dep_free_test.exs:44` (asserts `:ok` under override-absent path): unchanged — the rewrite branch only fires when the catalog is loaded.
- [ ] Update `ALLM.Chat`'s halt-reason table doc (`@doc ALLM.Chat.run/3`) with the `:metadata.structured_finalize.pass_1_halted` key.
- [ ] Write `test/allm/providers/openai_test.exs` extension rows; `test/allm/capability_test.exs` extension rows; `test/allm/chat_run_test.exs` and `test/allm/chat_stream_test.exs` extension rows.
- [ ] Verify stream-equivalence: `chat/3 ≡ stream/3 |> StreamCollector.to_chat_result/1` for the new `structured_finalize: true` paths.

#### 10.4.3 Verification

```bash
mix test test/allm/providers/openai_test.exs
mix test test/allm/capability_test.exs
mix test test/allm/chat_run_test.exs test/allm/chat_stream_test.exs
mix test                        # full suite still green
mix credo --strict lib/allm/providers/openai.ex lib/allm/chat.ex lib/allm/capability.ex
mix dialyzer
```

### Phase 10.5: Runnable examples under `examples/openai/` + `/review` validation step (Layer B — runnable scripts)

**Goal:** Ship nine runnable example scripts under `examples/openai/` exercising the full OpenAI adapter surface against the real provider; ship `run_all.exs` as the orchestration harness; document in `examples/openai/README.md`; the Phase 10 `/review` step runs `run_all.exs` against the real provider and validates non-error exit.

**Spec sections:** §32.1 (initial bundled adapters — provides the integration target).

**Layer:** B (runnable scripts; consume the public Layer C / D API only — no `lib/` or `test/` files).

#### 10.5.1 Test Plan

The examples themselves are the test plan — each script is a self-asserting smoke test. The `/review` validation step runs `OPENAI_API_KEY=… mix run examples/openai/run_all.exs` and asserts exit-status 0.

Per-script assertions (each script ends with `unless <condition>, do: System.halt(1)`). **TIGHT** rows are the deterministic regression bar; **LOOSE** rows are shape-only checks for examples whose teaching value is natural model behaviour.

- **`01_plain_text.exs` (TIGHT)** — system prompt: `"Reply with exactly the word 'OK' and no other text."`; user: `"Acknowledge."`. Assertion: `String.trim(response.output_text) == "OK" AND response.finish_reason == :stop`.
- **`02_streaming_text.exs` (TIGHT)** — same prompt as 01 but consumed via `stream_generate/3`. Assertion: `(events |> Enum.filter(&match?({:text_delta, _}, &1)) |> length()) > 0 AND Enum.count(events, &match?({:message_completed, _}, &1)) == 1 AND String.trim(reduced_text) == "OK"`.
- **`03_single_tool_call.exs` (TIGHT)** — `tool_choice: {:tool, "get_weather"}` forces the tool call; the tool handler returns `%{forecast: "sunny", city: "Boston"}`; system prompt: `"After the tool returns, repeat its forecast verbatim."`. Assertion: `result.halted_reason == :completed AND length(result.steps) == 2 AND Enum.any?(result.thread.messages, &(&1.role == :tool)) AND String.contains?(result.final_response.output_text, "sunny")`.
- **`04_parallel_tool_calls.exs` (TIGHT)** — `tool_choice: :required` plus a system prompt that names two tools (`get_weather`, `get_time`) and asks for both; the request asks for both Boston and Tokyo so a parallel call is the natural shape. Assertion: `length(Enum.filter(result.thread.messages, &(&1.role == :tool))) == 2 AND result.halted_reason == :completed`. Note: OpenAI may serialize the tool calls in two consecutive turns instead of one parallel turn; the assertion tolerates either orchestration shape (it counts tool messages, not parallel-turn step indices).
- **`05_multi_turn_chat.exs` (LOOSE)** — natural multi-turn dialogue, `temperature: 0`, no `tool_choice` forcing. Assertion: shape-only. `length(result1.thread.messages) >= 2 AND length(result2.thread.messages) > length(result1.thread.messages) AND result2.halted_reason == :completed`. The README documents this as a loose example whose value is the round-trip pattern, not deterministic content.
- **`06_structured_output.exs` (TIGHT)** — `response_format: ALLM.json_schema("greeting", %{type: "object", properties: %{message: %{type: "string"}}, required: ["message"], additionalProperties: false}, strict: true)`; system prompt: `"Always emit valid JSON conforming to the schema."`; user: `"Greet me with the word 'OK'."`. Assertion: `{:ok, %{"message" => msg}} = Jason.decode(result.final_response.output_text); String.contains?(msg, "OK")` AND `result.metadata.structured_finalize.pass_1_halted in [:completed, nil]` (nil because pass-1 is skipped when no tools requested).
- **`07_manual_tool_round_trip.exs` (TIGHT)** — `mode: :manual` with `tool_choice: {:tool, "get_weather"}` to guarantee the tool-call response. Assertion: first call returns `halted_reason: :manual_tool_calls AND length(result.pending_tool_calls) == 1`; after submitting tool result and re-issuing `chat/3`, second call returns `halted_reason: :completed AND String.contains?(result2.final_response.output_text, "sunny")`.
- **`08_session_round_trip.exs` (TIGHT)** — `Session.start/3` → `:erlang.term_to_binary/1` → `:erlang.binary_to_term/1` → `Session.reply/4` with the same content under both paths. Assertion: in-memory and round-tripped sessions yield byte-identical `final_response.output_text` values (achievable because `temperature: 0` makes responses deterministic and the reply prompt is fixed).
- **`09_ask_user.exs` (LOOSE)** — tool handler returns `{:ask_user, "Which city?", []}`; assertion: `halted_reason: :ask_user AND pending_question == "Which city?"`. Then a second turn supplies the answer; assertion: `halted_reason: :completed`. The first-turn assertion is exact (handler-controlled); the second-turn assertion is shape-only because the model's final-response phrasing is variable.

`run_all.exs` orchestration:

- Iterates over `01..09` in order.
- For each, runs `Code.eval_file/1` and captures the exit status (via a sandboxed `try/rescue` that converts `System.halt(1)` to `{:error, script_name}`).
- Prints per-script `[OK]` / `[FAIL]` lines.
- Exits `0` if all OK, `1` if any failed.
- Total runtime budget per script: 60 seconds (timeout via `Task.async/1` + `Task.yield/2`).

`examples/openai/README.md`:

- Prerequisite: `OPENAI_API_KEY` env var.
- Recommended model: `gpt-4.1-mini` (covers all v0.2 features; cost-efficient).
- Total cost expectation: ~$0.05 USD to run all nine scripts once on `gpt-4.1-mini` (estimated based on token counts in fixture recordings).
- Per-script invocation: `OPENAI_API_KEY=sk-... mix run examples/openai/01_plain_text.exs`.
- Full suite: `OPENAI_API_KEY=sk-... mix run examples/openai/run_all.exs`.
- Failure modes: missing key (clear error), provider 5xx (retry up to 3 attempts per `ALLM.Retry`), wrong model (script uses `engine = ALLM.Engine.new(model: "gpt-4.1-mini", …)` — override via `ALLM_MODEL` env var).

#### 10.5.2 Implementation Checklist

- [ ] Create `examples/openai/README.md` with the contents above.
- [ ] Create `examples/openai/01_plain_text.exs` through `09_ask_user.exs` per the per-script assertions above. Each file is self-contained: starts with a header comment naming the example and the spec section it demonstrates; uses `ALLM.Engine.new/1` to construct the engine; uses the appropriate Layer C / D entry point; ends with the `unless ..., do: System.halt(1)` assertion.
- [ ] Create `examples/openai/run_all.exs` per the orchestration contract.
- [ ] Run `OPENAI_API_KEY=... mix run examples/openai/run_all.exs` locally; record the output; commit the output as `examples/openai/RUN_OUTPUT.md` (a snapshot dated 2026-04-25; informational, not a test artifact).
- [ ] Add a `Decisions and live-run validation` section to the Phase 10 `/review` artifact (per Decision #13) with the captured `run_all.exs` output.

#### 10.5.3 Verification

```bash
# Each script individually
OPENAI_API_KEY=sk-... mix run examples/openai/01_plain_text.exs
# … through 09_ask_user.exs

# All in one go (the canonical /review validation step)
OPENAI_API_KEY=sk-... mix run examples/openai/run_all.exs
echo $?    # must be 0

# Confirms the examples directory is NOT in the published Hex package
mix hex.build --unpack /tmp/allm-build && find /tmp/allm-build -path '*examples*'   # must return empty
rm -rf /tmp/allm-build
```

The `/review` step for sub-phase 10.5 is BLOCKING on the `run_all.exs` exit status. Per Decision #13, the captured stdout becomes part of the review artifact.

### Phase 10.6: Reasoning controls + `incomplete` status mapping (Layer B)

**Goal:** Plumb the GPT-5/o-series reasoning-control parameters (`reasoning_effort`, `reasoning_summary`, `verbosity`, `max_output_tokens`) end-to-end through the request → adapter → response chain; populate `Usage.reasoning_tokens` from both endpoint shapes; map the Responses-API `incomplete` status per Decision #19; preserve `Response.metadata.reasoning` for inspection.

**Spec sections:** §5.5 (Response shape), §5.9a (Usage). All field additions ride existing Phase-1 fields — zero Layer A changes.

**Layer:** B.

#### 10.6.1 Test Plan

`test/allm/providers/openai_test.exs` (extends 10.2.1 with):

- `translate_options([reasoning_effort: :medium], %Request{model: "gpt-5.5"})` (endpoint resolves to `:responses`) returns `[reasoning: %{effort: "medium"}]`.
- `translate_options([reasoning_effort: :medium, reasoning_summary: :concise], ...)` returns `[reasoning: %{effort: "medium", summary: "concise"}]`.
- `translate_options([verbosity: :low], %Request{model: "gpt-5.5"})` returns `[verbosity: "low"]`.
- `translate_options([reasoning_effort: :medium], %Request{model: "gpt-5"})` (forced to `:chat_completions` via `endpoint: :chat_completions`) returns `[reasoning_effort: "medium"]` (Chat-Completions wire is the bare key, not nested under `reasoning:`).
- `translate_options([reasoning_effort: :medium], %Request{model: "gpt-4.1-mini"})` (legacy, non-reasoning model on `:chat_completions`) silently strips the key with a `Logger.debug/1` line.
- `translate_options([reasoning_effort: :illegal], _)` raises `ArgumentError` ("unknown reasoning_effort `:illegal` (legal: `[:none, :minimal, :low, :medium, :high, :xhigh]`)").
- `translate_options([reasoning_summary: :illegal], _)` raises `ArgumentError`.
- `translate_options([verbosity: :illegal], _)` raises `ArgumentError`.
- Response-decode (Responses): `from_responses_response(%{"status" => "completed", "output_text" => "hi", "usage" => %{"output_tokens_details" => %{"reasoning_tokens" => 42}}}, opts)` returns a `%Response{output_text: "hi", finish_reason: :stop, usage: %Usage{reasoning_tokens: 42}}`.
- Response-decode (Responses, incomplete + max_output_tokens): `from_responses_response(%{"status" => "incomplete", "incomplete_details" => %{"reason" => "max_output_tokens"}, "output_text" => "", "usage" => %{"output_tokens_details" => %{"reasoning_tokens" => 1024}}}, opts)` returns `%Response{output_text: "", finish_reason: :length, metadata: %{incomplete_details: %{reason: "max_output_tokens"}}, usage: %Usage{reasoning_tokens: 1024}}` per Decision #19.
- Response-decode (Responses, incomplete + content_filter): same shape with `finish_reason: :content_filter`.
- Response-decode (Responses, incomplete + unknown reason): `finish_reason: :other` with the raw string preserved.
- Response-decode (Chat Completions, GPT-5): `from_chat_completions_response(%{"choices" => [%{"message" => …, "finish_reason" => "stop"}], "usage" => %{"completion_tokens_details" => %{"reasoning_tokens" => 30}}}, opts)` populates `Usage.reasoning_tokens: 30`.
- Round-trip: `Response.metadata.reasoning.summary` survives `:erlang.term_to_binary/1` (Layer A invariant — but Response is already serializable).

`test/allm/providers/openai_wire_test.exs` (extends 10.2.1 with):

- Add a `reasoning_response.json` fixture (recorded from `gpt-5.5` with `reasoning_effort: :medium`); test asserts `Usage.reasoning_tokens > 0` and `Response.metadata.reasoning.effort == "medium"`.
- Add an `incomplete_response.json` fixture (synthesized from OpenAI's documented `status: "incomplete"` shape); test asserts `Response.finish_reason == :length AND Response.metadata.incomplete_details.reason == "max_output_tokens"`.

`test/allm/providers/openai_stream_wire_test.exs` (extends 10.3.1 with):

- Add a `reasoning_stream.sse` fixture: stream emits `event: response.reasoning_summary.delta` (verified Responses-API event name per OpenAI docs accessed 2026-04-26) chunks before any `response.output_text.delta`; test asserts the final `Response.metadata.reasoning.summary` is the concatenated reasoning-summary text AND the `output_text` is the concatenated output-text deltas (the two streams DO NOT cross-contaminate).

`test/allm/providers/openai_live_test.exs` (extends with):

- One live row: `engine = ALLM.Engine.new(adapter: ALLM.Providers.OpenAI, model: "gpt-5.5", params: %{reasoning_effort: :minimal})`; `{:ok, response} = ALLM.generate(engine, ALLM.request([ALLM.user("What is 2+2? Answer with one digit.")], max_tokens: 50))`; assert `response.usage.reasoning_tokens >= 0` (the live model may report `0` for trivial questions; the field must be populated, not `nil`).

#### 10.6.2 Implementation Checklist

- [ ] Implement `translate_options/2`'s reasoning-control branches per Decision #5 + #6. Validate atoms against the closed enums (`@effort_atoms`, `@summary_atoms`, `@verbosity_atoms`); raise `ArgumentError` on illegal values.
- [ ] Implement `from_responses_response/2`: decode `%{"id" => id, "status" => status, "output_text" => text, "usage" => usage_map, "incomplete_details" => incomplete_map_or_nil, ...}` into `%Response{}`. Map status per Decision #19's table; populate `Response.metadata.reasoning` from request-side opts (echoed back by OpenAI on the response).
- [ ] Implement `from_chat_completions_response/2`: existing decoder from Phase 10.2; extend to populate `Usage.reasoning_tokens` from `usage.completion_tokens_details.reasoning_tokens` when present.
- [ ] In the streaming path, recognize the Responses-API `event: response.reasoning_summary.delta` semantic-event (per Phase 10.3 SSE mapping) and accumulate the reasoning-summary text separately from `output_text` deltas; surface as `Response.metadata.reasoning.summary` post-collection.
- [ ] Record / synthesize the `reasoning_response.json`, `incomplete_response.json`, `reasoning_stream.sse` fixtures per Decision #11's recorded-vs-synthesized split.
- [ ] Write the test rows above in `openai_test.exs`, `openai_wire_test.exs`, `openai_stream_wire_test.exs`, and `openai_live_test.exs`.

#### 10.6.3 Verification

```bash
mix test test/allm/providers/openai_test.exs
mix test test/allm/providers/openai_wire_test.exs
mix test test/allm/providers/openai_stream_wire_test.exs
mix test --include live_openai test/allm/providers/openai_live_test.exs   # requires OPENAI_API_KEY
mix test                        # full suite still green
mix credo --strict lib/allm/providers/openai.ex
mix dialyzer
```

## Test Plan (cross-phase)

### Unit tests

- **`ALLM.Providers.Support.SSE`** — 12 rows per Phase 10.1.1.
- **`ALLM.Providers.OpenAI`** — `translate_options/2` (4 rows + property), finish-reason mapping (5 documented + property over unknowns), `requires_structured_finalize?/1` (true/false rows), `prepare_request/2` (key resolution, header injection, o-series rejection, missing-key raise), `to_openai_response_format/1` (4 canonical shapes + raise on unknown), `to_openai_messages/1` (role mapping verification), `to_openai_tools/1` (tool-shape mapping).
- **`ALLM.Application`** — `ALLM.Finch` started; pool uses HTTP/1.
- **`ALLM.Chat.maybe_structured_finalize/3`** — 8 rows per Phase 10.4.1.
- **`ALLM.Capability.preflight/2`** — 4 new rows per Phase 10.4.1 (extending Phase 9.4's 8 rows).

### Integration tests

- `openai_wire_test.exs` — 14 rows × `Req.Test.stub` per Phase 10.2.1.
- `openai_stream_wire_test.exs` — 13 rows × `ALLM.Test.FinchStub` per Phase 10.3.1.
- `openai_live_test.exs` — 5 live-provider rows; `@moduletag :live_openai`; skipped by default.

### Property tests

- Finish-reason mapping totality: 100 random strings → every output ∈ closed enum ∪ `[nil]`; `raw_finish_reason` populated for non-nil inputs.
- `translate_options/2` model-conditional rename: 100 random `(model, opts)` pairs → gpt-4o/4.1 inputs renamed; others unchanged.
- `to_openai_response_format/1` round-trip: every canonical shape encodes via `Jason.encode!/1` to the documented OpenAI wire shape; the wire shape decodes back via `Jason.decode!/1`.
- SSE accumulator round-trip: any `accumulator()` value `:erlang.term_to_binary/1`-round-trips byte-identical (Invariant 8).

### Doctests

- `ALLM.Providers.OpenAI.translate_options/2` — uses a fake `%Request{model: "gpt-4o-mini"}`.
- `ALLM.Providers.OpenAI.requires_structured_finalize?/1` — uses pattern matches on inline `%Request{}` shapes.
- `ALLM.Providers.Support.SSE.decode_chunk/2` — uses a literal `"data: hello\n\n"` chunk.
- `ALLM.Capability.preflight/2` extension — uses an `ALLM.Providers.OpenAI` engine + json-schema request; runnable under `mix test` because OpenAI is in `lib/`.

### Stream-equivalence

| Path | Relaxations | Justification | Risk |
|------|-------------|---------------|------|
| `Chat.run/3 ≡ Chat.stream/3 |> StreamCollector.to_chat_result/1` for `structured_finalize: true` requests | none | both paths use the same `maybe_structured_finalize/3` orchestration | tolerable |
| `generate/3 ≡ stream_generate/3 |> StreamCollector.to_response/1` for OpenAI requests | none | streaming is the primitive; non-streaming reduces it | tolerable |

No new masking-divergence rows. Phase 10's wire-format addition does not affect equivalence — both paths consume the same adapter callbacks; equivalence holds by construction (per the existing Phase 5 + Phase 7 invariants).

### Coverage threshold

`mix test --cover` — ≥ 80 % global, ≥ 90 % on every NEW file (`openai.ex`, `support/sse.ex`, the conformance test wrappers, the wire test files). Verified per-file.

## Error Contract

All Phase 10 errors use existing `%AdapterError{}` and `%StreamError{}` reason atoms. No vocabulary additions.

| Function | Error reason | Recovery guidance |
|----------|--------------|-------------------|
| `OpenAI.generate/2` | `:authentication_failed` | OPENAI_API_KEY invalid or missing; recoverable by setting the key. No retry. |
| `OpenAI.generate/2` | `:rate_limited` | 429; `ALLM.Retry` already retries up to 3 attempts per spec §6.1. After exhaustion, surface to caller. |
| `OpenAI.generate/2` | `:invalid_request` | 400 — request shape rejected by OpenAI. Programmer error; no retry. |
| `OpenAI.generate/2` | `:context_length_exceeded` | Reduce `max_tokens` or trim the thread; no retry. |
| `OpenAI.generate/2` | `:content_filter` | OpenAI policy block; surface to caller; no retry. |
| `OpenAI.generate/2` | `:provider_unavailable` | 5xx; `ALLM.Retry` retries up to 3 times. After exhaustion, surface. |
| `OpenAI.generate/2` | `:timeout` | `request_timeout` exceeded; recoverable via `opts[:request_timeout]` increase. |
| `OpenAI.generate/2` | `:network_error` | TCP/TLS/DNS failure; recoverable by retrying; ALLM does NOT auto-retry network errors (not in the default `retry_on` set). |
| `OpenAI.generate/2` | `:malformed_response` | OpenAI returned 200 with broken body; surface to caller; no retry. |
| `OpenAI.generate/2` | `:unsupported_feature` | o-series model passed to Chat Completions adapter; recoverable by switching to a supported model OR waiting for the v0.3 Responses API adapter. |
| `OpenAI.prepare_request/2` | raises `%EngineError{reason: :missing_key}` | `ALLM.Keys.fetch!/2` found no key (Decision #16); programmer error — fix at app boot. |
| `OpenAI.stream/2` synchronous | every `AdapterError` reason above | Same shape as `generate/2` for pre-flight failures. |
| `OpenAI.stream/2` mid-stream `{:error, _}` event | `AdapterError.reason ∈ {:rate_limited, :provider_unavailable, :content_filter, :timeout}` OR `StreamError.reason ∈ {:cancelled, :timeout, :malformed_event, :adapter_error, :unknown}` | Mid-stream errors fold into `Response.finish_reason: :error` per CLAUDE.md invariant; the call-site tuple stays `{:ok, _}`. |

The `:tools_disabled` and `:json_native_disabled` field-error atoms (added in Phase 9.4 inside `%ValidationError{reason: :unsupported_capability}`) are NOT fired by Phase 10 — those rejections happen in `ALLM.Capability.preflight/2`, not in the adapter.

## Streaming & Backpressure

Phase 10.3 ships streaming via `Finch.async_request/3` per spec §7.2.

- **Cleanup is mandatory.** `Stream.resource/3`'s `after_fun` calls `Finch.cancel_async_request/1` on the stored ref. The `ALLM.Test.FinchStub` cancellation-observer counter validates this in `openai_stream_wire_test.exs`.
- **Backpressure.** Finch's per-connection HTTP/1 message queue applies natural backpressure: if the consumer is slow, the `receive` block in `next_fun` simply doesn't pull the next chunk, and Finch's TCP read loop fills the OS buffer. No additional buffering layer.
- **Cancellation timing.** Bounded ≤ 500 ms in CI (Phase 10.3.1 row asserts via monotonic-time). Real-world cancellation depends on TLS shutdown + TCP teardown but `Finch.cancel_async_request/1` is non-blocking and returns immediately; the actual socket close happens asynchronously via the Finch pool's connection handler.
- **`stream_timeout` honored.** `receive` block has `after opts[:stream_timeout]` clause; exceeding emits a terminating `{:error, %AdapterError{reason: :timeout}}` event before stream end.
- **Mid-stream errors fold into Response.** Per CLAUDE.md invariant. The terminal `{:error, _}` event becomes `Response.finish_reason: :error`; `Response.metadata.error` carries the struct. The `{:ok, stream}` call-site tuple is preserved.

## Definition of Done

- [ ] All six sub-phases marked `Completed` in the Status table.
- [ ] `mix test` zero failures, zero `unused_var` warnings (with `:live_openai` excluded by default per Decision #10).
- [ ] Coverage ≥ 80 % globally; ≥ 90 % on every NEW file (`providers/openai.ex`, `providers/support/sse.ex`, the wire test files, `support/finch_stub.ex`, `support/openai_fixtures.ex`).
- [ ] `mix credo --strict` zero issues on changed files (`lib/allm/providers/openai.ex`, `lib/allm/providers/support/sse.ex`, `lib/allm/application.ex`, `lib/allm/chat.ex`, `lib/allm/capability.ex`).
- [ ] `mix dialyzer` zero new warnings (vs. pre-Phase-10 PLT).
- [ ] `mix format --check-formatted` passes (including `examples/openai/*.exs`).
- [ ] Every new public function in `ALLM.Providers.OpenAI`, `ALLM.Providers.Support.SSE` has `@spec` and `@doc` with at least one runnable doctest.
- [ ] `openai_wire_test.exs` (14 rows) AND `openai_stream_wire_test.exs` (13 rows) cover every documented `AdapterError.@type reason` and `StreamError.@type reason` atom. Per Q1, this matrix replaces the conformance harness obligation for real adapters.
- [ ] `ALLM.Capability.preflight/2` contract widening (`:ok | {:ok, Request.t()} | {:error, _}`) wired into every existing call site without regression — verified by full-suite green.
- [ ] All eight wire-test rows in `openai_wire_test.exs` pass with `Req.Test.stub`-injected responses.
- [ ] All 13 streaming wire-test rows in `openai_stream_wire_test.exs` pass with `ALLM.Test.FinchStub`-replayed chunks; cancellation row asserts ≤ 500 ms via monotonic-time.
- [ ] `[:allm, :adapter, :retry]` events fire from `OpenAI.generate/2` per attempt; zero events fire from `OpenAI.stream/2` (streaming-no-retry assertion).
- [ ] `structured_finalize: true` two-pass orchestration produces the correct `%ChatResult{}` shape (per Phase 10.4.1 rows); stream-equivalence holds.
- [ ] Endpoint dispatch: `gpt-5*` and `o[1-9]*` route to `:responses`; `gpt-4*` and `gpt-3.5*` route to `:chat_completions`; explicit `adapter_opts[:endpoint]` overrides; default fallback is `:chat_completions` (per Decision #1's `dispatch_endpoint/2` table).
- [ ] Reasoning controls: `reasoning_effort`, `reasoning_summary`, `verbosity` translate to the correct wire shape per endpoint per Decision #5; illegal atoms raise `ArgumentError`; `Usage.reasoning_tokens` populated from `usage.output_tokens_details.reasoning_tokens` (Responses) or `usage.completion_tokens_details.reasoning_tokens` (Chat Completions).
- [ ] Responses-API `status: "incomplete"` mapping per Decision #19: `max_output_tokens` → `:length`, `content_filter` → `:content_filter`, others → `:other`; `incomplete_details.reason` preserved on `Response.metadata.incomplete_details.reason`.
- [ ] `ALLM.Finch` started by `ALLM.Application` with `protocol: :http1` (verified by `application_test.exs`).
- [ ] `:live_openai` excluded by default in `test/test_helper.exs`; opt-in via `--include live_openai`.
- [ ] All nine `examples/openai/*.exs` scripts run successfully against the real OpenAI provider with `OPENAI_API_KEY` set; `examples/openai/run_all.exs` exits `0`. The captured `RUN_OUTPUT.md` is committed and dated.
- [ ] `examples/` directory is NOT in the published Hex package — verified by `mix hex.build --unpack` returning no `examples/` paths (the Definition-of-Done verification command in 10.5.3).
- [ ] CHANGELOG.md updated with one line per public sub-phase (6 lines total); each cites its spec §-number.
- [ ] Reviewed via `/review` per `AGENT_REVIEW_SPEC.md` AND the additional sub-phase 10.5 validation step (Decision #13): the reviewer runs `OPENAI_API_KEY=… mix run examples/openai/run_all.exs` and records the output in the review artifact. The review is BLOCKING on `run_all.exs` exit-status 0.

## Examples (sub-phase 10.5 — runnable against the real OpenAI provider)

This section makes the user's "examples/ that can be run against the actual OpenAI provider and validated in review" requirement load-bearing for the design.

### Directory layout

```
examples/openai/
├── README.md
├── 01_plain_text.exs
├── 02_streaming_text.exs
├── 03_single_tool_call.exs
├── 04_parallel_tool_calls.exs
├── 05_multi_turn_chat.exs
├── 06_structured_output.exs
├── 07_manual_tool_round_trip.exs
├── 08_session_round_trip.exs
├── 09_ask_user.exs
├── run_all.exs
└── RUN_OUTPUT.md   (committed snapshot of the latest live run; dated 2026-04-25 at design time)
```

### Validation philosophy (Q2 — examples-as-validation, not examples-as-documentation)

Per Q2 (2026-04-26): the examples are written as **deterministic regression bars**, not loose demonstrations. Every script squeezes out model variance via three knobs so `run_all.exs` can serve as a reliable BLOCKING `/review` gate:

1. **`temperature: 0`** on every request via `Engine.put_param/3`.
2. **Hard-steered system prompts** that constrain the assistant to a narrow output shape, e.g., `"You are a test fixture. When asked to greet, reply with exactly the word 'OK'."`. Each script's header comment names the steering it uses.
3. **Explicit `tool_choice`** on tool-calling scripts: `tool_choice: {:tool, "get_weather"}` for `03_single_tool_call.exs` (forces the model to call that specific tool); `tool_choice: :required` for `04_parallel_tool_calls.exs` (forces ANY tool call); `tool_choice: :auto` only on `05_multi_turn_chat.exs` and `09_ask_user.exs` where natural model behaviour is the demonstration.

A side-comment in each script's header shows the "natural" prompt the user might write, so a copy-paster can swap the steering for the looser form once they understand the example. The README enumerates the steering strategies and the rationale; reviewer reproducibility wins.

When a script's primary teaching value is *natural* model behaviour (multi-turn, ask-user), the assertion is loosened to a contract-shape check (`Enum.any?(thread.messages, &(&1.role == :tool))`) rather than an exact-content match. The four shape-only examples are documented as "loose-assertion" in the README; the other five are tight.

### Common script template

Every numbered script follows this template so users can read one and predict the others:

```elixir
# examples/openai/0X_<name>.exs
#
# Demonstrates: <one-sentence purpose>
# Spec section: §X.Y
# Steering strategy: <"tight" — temperature: 0 + hard system prompt + tool_choice forcing>
#                    OR <"loose" — natural prompt; assertion is shape-only>
# Natural alternative (commented out below): <one-line free-form prompt>
# Run with:    OPENAI_API_KEY=sk-... mix run examples/openai/0X_<name>.exs

Application.ensure_all_started(:allm)

engine =
  ALLM.Engine.new(
    adapter: ALLM.Providers.OpenAI,
    model: System.get_env("ALLM_MODEL", "gpt-5.5"),
    tool_executor: ALLM.ToolExecutor.Default,
    tool_result_encoder: ALLM.ToolResultEncoder.JSON,
    params: %{temperature: 0}                      # tight scripts only
  )

# ... per-example body — uses tool_choice: {:tool, "<name>"} or :required when tight ...

result = ...

unless <self-assertion>, do: (IO.puts(:stderr, "FAIL: <reason>"); System.halt(1))

IO.puts("OK: <one-line summary>")
```

The header comment, `Application.ensure_all_started(:allm)` (so `ALLM.Finch` and `ALLM.Keys.Store` are running), the engine construction, the steering strategy line, and the trailing assertion-or-halt are uniform across every script. Users skim one, then jump to the body of the example they're interested in. The `ALLM_MODEL` override lets users substitute a different model without editing the script (defaults to `gpt-5.5` per Q3 — the v0.2 primary target).

### `run_all.exs` orchestrator

```elixir
# examples/openai/run_all.exs
#
# Runs every numbered example under examples/openai/ in order.
# Exits 0 if all succeed, 1 if any failed.
# Used by the Phase 10 /review validation step.

Application.ensure_all_started(:allm)

scripts =
  Path.wildcard("examples/openai/[0-9][0-9]_*.exs")
  |> Enum.sort()

results =
  Enum.map(scripts, fn path ->
    IO.puts("--- #{Path.basename(path)} ---")
    task = Task.async(fn -> Code.eval_file(path) end)

    case Task.yield(task, 60_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, _} -> {path, :ok}
      {:exit, reason} -> {path, {:error, reason}}
      nil -> {path, {:error, :timeout}}
    end
  end)

failed = Enum.filter(results, fn {_, status} -> status != :ok end)

IO.puts("\n=== Summary ===")
Enum.each(results, fn {path, status} ->
  marker = if status == :ok, do: "[OK]  ", else: "[FAIL]"
  IO.puts("#{marker} #{Path.basename(path)}")
end)

if failed != [], do: System.halt(1)
```

Per-script timeout 60 seconds covers OpenAI's worst-case latency for `gpt-4.1-mini` on a parallel-tool-call request (typically 5–15 s).

### `/review` validation step

The Phase 10 review step is more involved than the default `/review`. The reviewer:

1. Runs `mix test` (full suite, deterministic, default exclusions).
2. Runs `mix test --include live_openai test/allm/providers/openai_live_test.exs` (live smoke; skipped if no `OPENAI_API_KEY`; informational).
3. Runs `OPENAI_API_KEY=… mix run examples/openai/run_all.exs` (live full-coverage; BLOCKING; records stdout in the review artifact as `RUN_OUTPUT.md`).
4. Captures the per-script `[OK]` / `[FAIL]` summary in the review's `Findings` section.
5. Tags the review with `phase-10-validation: passed` (or `failed` with the failing script names).

The review FAILS if step (3) exits non-zero. The reviewer may request a specific script to be re-run with diagnostic logging if a failure is intermittent (real provider responses can vary; an `09_ask_user.exs` failure is more interesting than a `05_multi_turn_chat.exs` one).

### Example fixture cost

Running `run_all.exs` against `gpt-5.5` (the v0.2 default) with `reasoning_effort: :minimal` to keep costs down (per Q3):

- 9 scripts × ~500 input tokens average × ~$1.25 / 1M = ~$0.006
- 9 scripts × ~500 output tokens average (including reasoning tokens at `:minimal`) × ~$10 / 1M = ~$0.045
- **Total: ~$0.05 USD per full run** (reasoning models are roughly 10× the per-token cost of `gpt-4.1-mini`; pricing as of OpenAI's 2026-01 catalog and may shift).

A reviewer running the validation step burns ~$0.05 per review pass. Reviewers concerned about cost can override with `ALLM_MODEL=gpt-4.1-mini mix run examples/openai/run_all.exs` to drop to ~$0.005 per run (Chat Completions path). The runtime cost is the more meaningful budget — typically 90–180 seconds wall-clock for the full nine-script run on `gpt-5.5` with `:minimal` reasoning (longer than 60s on `gpt-4.1-mini` because reasoning models think before responding).

### Failure modes

- **`OPENAI_API_KEY` missing.** `run_all.exs` fails on the first script's `ALLM.Keys.fetch!/2` raise. The error message is clear; reviewer documents and aborts.
- **Real provider 5xx.** `ALLM.Retry` retries up to 3 attempts per script. After exhaustion, the script fails; the reviewer may rerun once.
- **Model unavailable.** If `gpt-4.1-mini` is decommissioned, the `:invalid_request` reason fires. Override via `ALLM_MODEL=gpt-4o-mini mix run examples/openai/run_all.exs`.
- **Quota exceeded.** `:rate_limited` after retry exhaustion. Reviewer waits or uses a different key.

These failure modes are documented in `examples/openai/README.md` so reviewers don't need to read this design doc to interpret a failure.
