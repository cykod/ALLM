# ALLM runnable examples (provider-neutral)

Self-asserting smoke tests that exercise the public ALLM API against a real
LLM provider — OpenAI by default, or Anthropic via `ALLM_PROVIDER=anthropic`.
Each script ends with `unless <assertion>, do: System.halt(1)`, so a script
that prints `OK: …` and exits `0` is the green signal; any non-zero exit is
a real failure.

These scripts ship under `examples/` and are **not** part of the published
`hex` package (see `mix.exs :files`).

## How provider switching works

`examples/_helpers.exs` defines a tiny `ExamplesHelpers` module with a
provider table:

```elixir
@providers %{
  "openai" => %{
    adapter: ALLM.Providers.OpenAI,
    default_model: "gpt-5.4-nano",
    vision_default_model: "gpt-4o-mini",
    key_env: "OPENAI_API_KEY",
    image_adapter: ALLM.Providers.OpenAI.Images,
    image_default_model: "dall-e-2"
  },
  "anthropic" => %{
    adapter: ALLM.Providers.Anthropic,
    default_model: "claude-sonnet-4-6",
    vision_default_model: "claude-haiku-4-5-20251001",
    key_env: "ANTHROPIC_API_KEY",
    image_adapter: nil,
    image_default_model: nil
  }
}
```

The map-shaped row replaced the original 3-tuple in Phase 15.6 (Decision
#14) so future fields (`:image_adapter`, `:image_default_model`, …) don't
churn the destructure pattern in the helper.

Every script's first lines are:

```elixir
Application.ensure_all_started(:allm)
Code.require_file("_helpers.exs", __DIR__)

engine = ExamplesHelpers.engine()  # or ExamplesHelpers.engine(tools: [...])
```

The helper reads `ALLM_PROVIDER` (default `"openai"`), looks up the adapter
+ default model + key env var name, validates that the corresponding
`*_API_KEY` env var is set, and returns a configured `%ALLM.Engine{}`. The
helper bakes in `params: %{temperature: 0}` for determinism on both providers
and merges any per-script `extra_opts` (`tools:`, `tool_executor:`, etc.) on
top.

Future providers (Phase 12+) add a single row to the `@providers` table and
existing scripts pick them up unchanged.

## Prerequisites

The example scripts use the [`:env_loader`](https://hexdocs.pm/env_loader/EnvLoader.html)
Hex package as a `dev`-only dependency to load API keys from a project-root
`.env` file (gitignored). The helper auto-loads `.env` centrally — individual
scripts no longer carry their own `EnvLoader.load(...)` preamble.

So either:

1. Drop a `.env` file at the repository root with both
   `OPENAI_API_KEY=sk-...` and `ANTHROPIC_API_KEY=sk-ant-...` and just run
   `mix run examples/run_all.exs` (or `ALLM_PROVIDER=anthropic mix run examples/run_all.exs`)
   — no further setup. Reviewers running the dual-provider `/review` step
   need both keys present.
2. Or export the vars directly:
   `export OPENAI_API_KEY=sk-... ANTHROPIC_API_KEY=sk-ant-... && mix run examples/run_all.exs`.

The `:env_loader` dep is declared `only: [:dev]` in `mix.exs`, so it does
NOT ship in the published Hex package (the `examples/` directory itself is
also excluded from the package per `mix.exs :files`).

## Running

Single script (default — OpenAI):

```bash
OPENAI_API_KEY=sk-... mix run examples/01_plain_text.exs
```

Single script against Anthropic:

```bash
ANTHROPIC_API_KEY=sk-ant-... ALLM_PROVIDER=anthropic mix run examples/01_plain_text.exs
```

Full suite — the canonical `/review` validation step (run TWICE, once per provider):

```bash
OPENAI_API_KEY=sk-... ALLM_PROVIDER=openai mix run examples/run_all.exs
echo "openai exit: $?"   # must be 0

ANTHROPIC_API_KEY=sk-ant-... ALLM_PROVIDER=anthropic mix run examples/run_all.exs
echo "anthropic exit: $?"   # must be 0
```

`run_all.exs` exits `0` iff every script printed `OK:` and exited `0`. Both
runs must pass for the `/review` gate to be considered green. The most-recent
captured stdouts are committed as `RUN_OUTPUT_OPENAI.md` and
`RUN_OUTPUT_ANTHROPIC.md` next to this README.

## Scripts

| Script | Strategy | What it covers |
|--------|----------|----------------|
| `01_plain_text.exs` | tight | `ALLM.generate/3` non-streaming round-trip |
| `02_streaming_text.exs` | tight | `ALLM.stream_generate/3` SSE consumption |
| `03_single_tool_call.exs` | tight | `ALLM.chat/3` with one tool, two turns |
| `04_parallel_tool_calls.exs` | tight | two tools called within one chat loop |
| `05_multi_turn_chat.exs` | loose | thread accumulation across two `chat/3` calls |
| `06_structured_output.exs` | tight | `response_format: ALLM.json_schema(...)` (Anthropic exercises tool-forcing per Decision #4) |
| `07_manual_tool_round_trip.exs` | tight | `mode: :manual` halt + caller-supplied tool result |
| `08_session_round_trip.exs` | tight | `Session` survives `:erlang.term_to_binary/1` round-trip |
| `09_ask_user.exs` | loose | `{:ask_user, _, _}` halt and follow-up turn |
| `10_generate_image.exs` | tight | `ALLM.generate_image/3` against `dall-e-2` 256×256 (OpenAI-only) |
| `11_edit_image.exs` | tight | `ALLM.edit_image/4` against `gpt-image-1` with mask (inpaint) (OpenAI-only) |
| `12_vision_input.exs` | loose | `ALLM.generate/3` with `[%TextPart{}, %ImagePart{}]` content (OpenAI + Anthropic) |
| `13_image_variations.exs` | tight | `ALLM.image_variations/3` against `dall-e-2` 256×256 (OpenAI-only) |

## Image generation

Phase 15.6 adds `10_generate_image.exs` — a tight smoke test for
`ALLM.generate_image/3` against OpenAI's `dall-e-2` model at 256×256.
The script:

1. Builds an image-adapter engine via `ExamplesHelpers.image_engine/0`
   (sister to `ExamplesHelpers.engine/0` — looks up `:image_adapter` /
   `:image_default_model` from the provider table).
2. Calls `ALLM.generate_image(engine, "a watercolor kestrel in flight", size: "256x256")`.
3. Materializes `response.images |> hd() |> ALLM.Image.to_binary/1`.
4. Writes the bytes to `System.tmp_dir!() <> "/10_generate_image_<ts>.png"`.
5. Asserts the on-disk bytes start with the PNG magic number
   `<<137, 80, 78, 71>>`.

The script is **OpenAI-only**: a `# Provider: openai` header marker tells
`run_all.exs` to skip it on `ALLM_PROVIDER=anthropic` (Anthropic has no
image adapter — see Phase 15.6 Decision #15). Skipped scripts print
`[SKIP] 10_generate_image.exs (provider gate)` and do not count toward
`failed`.

Per-clean-run cost: roughly **~$0.016 USD** (one `dall-e-2` 256×256
generate). Adds ~$0.016 to the OpenAI arm of the dual-provider
`/review` pass; the Anthropic arm is unaffected.

## Image editing (inpaint)

Phase 17.3 adds `11_edit_image.exs` — `ALLM.edit_image/4` against
OpenAI's `gpt-image-1` model with a base image + mask (inpainting).
The script synthesizes a tiny 1×1 PNG for both the base and mask, calls
`ALLM.edit_image(engine, base, prompt, mask: mask, size: "1024x1024")`,
materializes the resulting image to bytes, and asserts the PNG magic
number on the on-disk bytes. **OpenAI-only** (`# Provider: openai`
header marker). Per-clean-run cost: roughly **~$0.04 USD**.

## Image variations

Phase 17.3 adds `13_image_variations.exs` — `ALLM.image_variations/3`
against `dall-e-2` 256×256 (the only OpenAI image model that supports
the variation operation). Same shape as `10_generate_image.exs`: tiny
synthesized base PNG, byte-prefix assertion. **OpenAI-only**
(`# Provider: openai`). Per-clean-run cost: roughly **~$0.018 USD**.

## Vision input

Phase 17.3 adds `12_vision_input.exs` — `ALLM.generate/3` with a
multimodal user message
(`[%ALLM.TextPart{}, %ALLM.ImagePart{}]` content). The script uses
`ExamplesHelpers.engine(vision: true)` to route to the row's
`:vision_default_model` (`gpt-4o-mini` on OpenAI;
`claude-haiku-4-5-20251001` on Anthropic per Phase 17.3 Decision #8),
sends a 1×1 transparent PNG with a "describe this image" prompt, and
asserts a non-empty `output_text` and `finish_reason: :stop`. **Runs on
both providers** (`# Provider: openai, anthropic`). Per-clean-run cost:
roughly **~$0.001 USD** on either arm.

## Cost notes (Phase 17.3, full `run_all.exs` pass)

| Script | OpenAI arm | Anthropic arm |
|--------|-----------|---------------|
| `10_generate_image.exs` | ~$0.016 | skipped |
| `11_edit_image.exs` | ~$0.04 | skipped |
| `12_vision_input.exs` | ~$0.001 | ~$0.001 |
| `13_image_variations.exs` | ~$0.018 | skipped |
| **Phase-17.3 subtotal** | **~$0.075** | **~$0.001** |

Combined v0.3.0 `/review` pass (OpenAI + Anthropic): **~$0.09 USD per
clean run**, **~$0.27 USD first-implementation** (per Phase 17.3
Decision #10 — first-impl includes ~3× retry overhead from
fixture-recording and per-script debugging).

## SaaS bring-your-own-key (BYOK)

The engine itself never carries an API key — engines round-trip through
`:erlang.term_to_binary/1` and JSON, so keys must not be persisted on
them (spec §6.4, CLAUDE.md). For multi-tenant SaaS, pass the tenant's
key per-call:

    engine = ALLM.Engine.new(adapter: ALLM.Providers.OpenAI, model: "gpt-5.4-nano")
    {:ok, response} = ALLM.generate(engine, request, api_key: tenant.openai_key)

The per-call `:api_key` opt has the highest precedence in `ALLM.Keys`'s
five-level resolution chain — it overrides any env var, app config, or
runtime store. The engine remains safe to cache, share across tenants,
and persist.

Avoid `ALLM.Keys.put/2` for BYOK — it stores the key in a globally-named
Agent, so concurrent requests from different tenants would race.

## Models

- **OpenAI default:** `gpt-5.4-nano` (a `gpt-5*`-family reasoning model that
  routes to OpenAI's Responses API; chosen as the v0.2 primary target for
  its low cost while still exercising the Responses-API code path).
- **Anthropic default:** `claude-sonnet-4-6` (the canonical Sonnet model
  named in the spec).

Override the model at runtime independent of provider:

```bash
ALLM_MODEL=gpt-4.1-mini mix run examples/run_all.exs
ALLM_MODEL=claude-haiku-4-5 ALLM_PROVIDER=anthropic mix run examples/run_all.exs
```

`gpt-4.1-mini` is a non-reasoning model on the Chat Completions endpoint
and is a useful escape hatch when reviewers want to bypass the Responses
API entirely. `claude-haiku-4-5` is roughly 5× cheaper than Sonnet for
reviewers concerned about Anthropic costs.

## Steering strategy

Scripts marked **tight** use three knobs to squeeze out model variance so the
assertion can be exact:

1. A hard system prompt that constrains the assistant to a narrow shape (e.g.
   `"Reply with exactly the word 'OK' and no other text."`).
2. Forced tool use via `tool_choice:` where applicable (`:auto` with a tool-
   forcing system prompt; `:required` for the parallel-tools script).
3. `params: %{temperature: 0}` baked into the helper for both providers.

Scripts marked **loose** demonstrate natural model behaviour (multi-turn
chat, ask-user). Their assertions are shape-only — e.g. "the thread grew",
"the loop halted with `:completed`" — not exact-content matches.

Each script's header comment names its steering strategy and shows a "natural
alternative" line for users who want to swap the steering for a free-form
prompt once they understand the example.

## Cost expectation (per `run_all.exs` invocation)

- **`ALLM_PROVIDER=openai` (`gpt-5.4-nano`)** — roughly **~$0.05 USD** per
  full run on `gpt-5.4-nano` with the suite's mixed reasoning effort.
  Switching to `ALLM_MODEL=gpt-4.1-mini` keeps cost on the same order of
  magnitude on the Chat Completions path.
- **`ALLM_PROVIDER=anthropic` (`claude-sonnet-4-6`)** — roughly **~$0.08 USD**
  per full run on Sonnet 4.6 (~$3 / 1M input + ~$15 / 1M output, ~500
  input + ~500 output tokens × 9 scripts). Switch to
  `ALLM_MODEL=claude-haiku-4-5` to drop the leg to ~$0.01.
- **Combined `/review` cost: ~$0.13 USD per pass** (one OpenAI run + one
  Anthropic run). Anthropic pricing is volatile — verify against the current
  Anthropic pricing page at impl time.

The runtime budget per script is 60 seconds (enforced by `run_all.exs`'s
`Task.yield/2`). A full suite typically runs in 60–120 s per provider; ~3
minutes total for the dual-provider `/review` pass.

## Tool-using scripts run natively on the Responses API (OpenAI)

Scripts 03, 04, 07, and 09 exercise tool calls. On OpenAI they run through
the Responses-API path that `gpt-5.4-nano` selects by default; the
Responses-API tool-call decoder gap (Bug #5 from Phase 10.5) was closed —
both `from_responses_response/2` and the streaming SSE handler now surface
tool calls from the `output[]` array. On Anthropic these scripts route
through the Messages API with `tool_use` content blocks decoded via
`from_anthropic_response/2`.

## Structured output (script 06)

OpenAI's `:json_schema` response format uses native enforcement with
`strict: true`; the model's literal output bytes are returned in
`Response.output_text`.

Anthropic's structured-output path uses the **tool-forcing pattern** per
spec §5.4 + Phase 11 Decision #4: a synthetic `respond_with_json_<name>`
tool is injected, `tool_choice` forces it, and the tool-call's `input` map
is lifted to `Response.output_text` via `Jason.encode!/1` with
`finish_reason: :stop` and `metadata.structured_output_tool: true`. The
script asserts on the latter marker only when `ALLM_PROVIDER == "anthropic"`
since OpenAI carries no equivalent flag. The semantic content is identical
across providers; the byte string may differ (whitespace, key order, number
formatting) — see the `@moduledoc ALLM.Providers.Anthropic` paragraph
"Structured output `output_text` — semantic vs. byte equality".

## /review validation step

The `/review` step for sub-phase 11.4 is BLOCKING on `run_all.exs` exit
status `0` for **both** providers:

1. Run `mix test` (full suite, deterministic, default exclusions).
2. Run `mix test --include live_anthropic test/allm/providers/anthropic_live_test.exs`
   (live smoke; skipped if no `ANTHROPIC_API_KEY`; informational).
3. **BLOCKING:** `OPENAI_API_KEY=… ALLM_PROVIDER=openai mix run examples/run_all.exs`
   (records stdout as `RUN_OUTPUT_OPENAI.md`).
4. **BLOCKING:** `ANTHROPIC_API_KEY=… ALLM_PROVIDER=anthropic mix run examples/run_all.exs`
   (records stdout as `RUN_OUTPUT_ANTHROPIC.md`).
5. Capture per-provider `[OK]` / `[FAIL]` summaries in the review's
   `Findings` section.

The review FAILS if step (3) OR step (4) exits non-zero.

## Failure modes

- **Missing `*_API_KEY`.** `ExamplesHelpers.engine/0` checks the env var
  name from the provider table BEFORE constructing the engine and exits
  with a clear error message naming the missing variable.
- **Unknown `ALLM_PROVIDER`.** `ExamplesHelpers.engine/0` raises
  `ArgumentError` listing the legal provider names.
- **Adapter module not loaded** (e.g., a future scenario where Phase 11 is
  rolled back). `Code.ensure_loaded?(adapter)` in the helper returns false;
  the helper exits with a clear message.
- **HTTP 5xx, `:rate_limited`, OR `529 Overloaded` (Anthropic).**
  `ALLM.Retry` retries up to 3 attempts per spec §6.1 (529 included per
  Phase 11 Decision #2). After exhaustion the script halts. Re-run once.
- **Model unavailable.** If the configured model is decommissioned, the
  `:invalid_request` reason fires. Override via
  `ALLM_MODEL=<current-model> mix run …`.
- **Quota exceeded.** `:rate_limited` after retry exhaustion. Wait or use
  a different key.
- **Per-script timeout.** `run_all.exs` enforces a 60-second budget per
  script via `Task.yield(task, 60_000) || Task.shutdown(task, :brutal_kill)`.
  A timed-out script counts as `[FAIL]`.

## Contributing

Each example is its own test fixture. When adding a new script:

1. Number it in two-digit form (`10_<name>.exs`); `run_all.exs` picks them
   up by glob in numeric order.
2. Follow the common header-comment / engine / body / assertion-or-halt
   layout (see any of the existing scripts).
3. Use `engine = ExamplesHelpers.engine(extra_opts)` — never call
   `ALLM.Engine.new/1` directly so the script stays provider-neutral.
4. Run it standalone against BOTH providers, then run `run_all.exs`
   end-to-end against BOTH, before opening a PR.
