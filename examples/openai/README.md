# ALLM × OpenAI runnable examples

Self-asserting smoke tests that exercise the public ALLM API against the real
OpenAI provider. Each script ends with `unless <assertion>, do: System.halt(1)`,
so a script that prints `OK: …` and exits `0` is the green signal; any non-zero
exit is a real failure.

These scripts ship under `examples/` and are **not** part of the published
`hex` package (see `mix.exs :files`).

## Prerequisites

The example scripts use the [`:env_loader`](https://hexdocs.pm/env_loader/EnvLoader.html) Hex package as a `dev`-only dependency to load `OPENAI_API_KEY` from a project-root `.env` file (gitignored) when the env var isn't already set. So either:

1. Drop a `.env` file at the repository root with `OPENAI_API_KEY=sk-...` and just run `mix run examples/openai/run_all.exs` — no further setup.
2. Or export the var directly: `export OPENAI_API_KEY=sk-... && mix run examples/openai/run_all.exs`.

The loader is a one-liner at the top of each script — open `01_plain_text.exs` to see it. It's a no-op if `OPENAI_API_KEY` is already in the environment. The `:env_loader` dep is declared `only: [:dev]` in `mix.exs`, so it does NOT ship in the published Hex package (the `examples/` directory itself is also excluded from the package per `mix.exs :files`).

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

Avoid `ALLM.Keys.put/2` for BYOK — it stores the key in a
globally-named Agent, so concurrent requests from different tenants
would race.

`ALLM.Keys` reads the env var at request time — engines never carry the
key.

## Models

Default model: `gpt-5.4-nano` (a `gpt-5*`-family reasoning model that
routes to OpenAI's Responses API; chosen as the v0.2 primary target for
its low cost while still exercising the Responses-API code path).

Override at runtime:

```bash
ALLM_MODEL=gpt-4.1-mini mix run examples/openai/run_all.exs
```

`gpt-4.1-mini` is a non-reasoning model on the Chat Completions endpoint
and is a useful escape hatch when reviewers want to bypass the Responses
API entirely. It's also a useful sanity check for any provider regression
isolated to the Responses path.

### Reasoning effort

The bundled adapter accepts `:reasoning_effort` ∈ `[:none, :low, :medium,
:high, :xhigh]` — the closed enum surfaced by `gpt-5*` models in practice.
The scripts use `:none` for the cheapest reasoning-model call where
reasoning controls are exercised at all (`:low` for tool-using scripts —
slightly better steering on tool selection at marginal extra cost).
(`:minimal` was previously in the closed enum and was removed in the
Phase 10.5 live-validation retro after `gpt-5.5` rejected it with
`Unsupported value: 'minimal' is not supported`.)

## Running

Single script:

```bash
OPENAI_API_KEY=sk-... mix run examples/openai/01_plain_text.exs
```

Full suite (the canonical `/review` validation step):

```bash
OPENAI_API_KEY=sk-... mix run examples/openai/run_all.exs
```

`run_all.exs` exits `0` iff every script printed `OK:` and exited `0`.

## Scripts

| Script | Strategy | What it covers |
|--------|----------|----------------|
| `01_plain_text.exs` | tight | `ALLM.generate/3` non-streaming round-trip |
| `02_streaming_text.exs` | tight | `ALLM.stream_generate/3` SSE consumption |
| `03_single_tool_call.exs` | tight | `ALLM.chat/3` with one tool, two turns |
| `04_parallel_tool_calls.exs` | tight | two tools called within one chat loop |
| `05_multi_turn_chat.exs` | loose | thread accumulation across two `chat/3` calls |
| `06_structured_output.exs` | tight | `response_format: ALLM.json_schema(...)` |
| `07_manual_tool_round_trip.exs` | tight | `mode: :manual` halt + caller-supplied tool result |
| `08_session_round_trip.exs` | tight | `Session` survives `:erlang.term_to_binary/1` round-trip |
| `09_ask_user.exs` | loose | `{:ask_user, _, _}` halt and follow-up turn |

## Steering strategy

Scripts marked **tight** use three knobs to squeeze out model variance so the
assertion can be exact:

1. A hard system prompt that constrains the assistant to a narrow shape (e.g.
   `"Reply with exactly the word 'OK' and no other text."`).
2. Forced tool use via `tool_choice:` where applicable (`:auto` with a tool-
   forcing system prompt; `:required` for the parallel-tools script).
3. `params: %{reasoning_effort: :none}` for cheap, deterministic reasoning-
   model output where reasoning controls are exercised.

Scripts marked **loose** demonstrate natural model behaviour (multi-turn
chat, ask-user). Their assertions are shape-only — e.g. "the thread grew",
"the loop halted with `:completed`" — not exact-content matches.

Each script's header comment names its steering strategy and shows a "natural
alternative" line for users who want to swap the steering for a free-form
prompt once they understand the example.

## Cost expectation

Rough estimate, ~$0.005 USD to run `run_all.exs` once on `gpt-5.4-nano`
with the suite's mixed `:none` / `:low` reasoning effort. Switching to
`ALLM_MODEL=gpt-4.1-mini` keeps cost at the same order of magnitude on the
Chat Completions path but skips the Responses-API plumbing entirely.

Costs at OpenAI's published 2026-04 catalog (subject to drift):

- `gpt-5.4-nano`: roughly an order of magnitude cheaper than `gpt-5.5` per
  token (reasoning models bill reasoning tokens at the output rate;
  `gpt-5.5` was historically ~$1.25 / 1M input, ~$10 / 1M output).
- `gpt-4.1-mini`: ~$0.15 / 1M input, ~$0.60 / 1M output.

The runtime budget per script is 60 seconds (enforced by `run_all.exs`'s
`Task.yield/2`). A full suite typically runs in 60–120 s on `gpt-5.4-nano`
with `:none` reasoning.

## Tool-using scripts run natively on the Responses API

Scripts 03, 04, 07, and 09 previously declared
`adapter_opts: [endpoint: :chat_completions]` on the engine to work around
a gap in the Responses-API tool-call decoder (Bug #5). That gap was closed
in this revision — both `from_responses_response/2` and the streaming SSE
handler now surface tool calls from the `output[]` array
(`%{"type" => "function_call", ...}` items) and from the corresponding
streaming events (`response.output_item.added` /
`response.function_call_arguments.delta` / `response.output_item.done`).
The workaround has been lifted, so tool-using scripts now exercise the
Responses-API path end-to-end on `gpt-5.4-nano`, with
`params: %{reasoning_effort: :low}` for reliable steering on tool
selection.

## Failure modes

- **Missing `OPENAI_API_KEY`.** First script halts with
  `%ALLM.Error.EngineError{reason: :missing_key}`; the orchestrator logs
  `[FAIL] 01_plain_text.exs` and exits `1`.
- **HTTP 5xx or `:rate_limited`.** `ALLM.Retry` retries up to 3 attempts
  per spec §6.1. After exhaustion the script halts. Re-run once.
- **Model unavailable.** If `gpt-5.4-nano` is decommissioned, override via
  `ALLM_MODEL=gpt-4.1-mini`.
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
3. Run it standalone, then run `run_all.exs` end-to-end, before opening a
   PR.
