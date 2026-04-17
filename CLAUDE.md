# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project goal

ALLM (Agent LLM) is an Elixir library for provider-neutral LLM execution with first-class streaming and serializable conversation state. The canonical design document is `steering/allm_engine_session_streaming_spec_v0_2.md` — treat it as the source of truth for module names, types, and behaviour. Concrete application examples that the library must support live in `steering/examples/`.

The package is still in initial scaffolding; most modules under `lib/allm/` are struct/behaviour skeletons pending implementation per §28 of the spec.

## Architecture in one page

Four conceptual layers — changes that cross a layer boundary usually signal a design mistake:

1. **Serializable data** (Layer A) — `ALLM.Message`, `ALLM.ToolCall`, `ALLM.Request`, `ALLM.Response`, `ALLM.Thread`, `ALLM.Session`, `ALLM.StepResult`, `ALLM.ChatResult`, `ALLM.Event`, `ALLM.Usage`. Plain structs; must round-trip through `:erlang.term_to_binary/1` and JSON. No PIDs, refs, funs, or API keys on these.
2. **Runtime** (Layer B) — `ALLM.Engine` plus the `ALLM.Adapter`, `ALLM.StreamAdapter`, `ALLM.ToolExecutor`, `ALLM.ToolResultEncoder` behaviours. Holds the non-serializable dependencies (modules, funs, Finch names, keys resolved at call time).
3. **Stateless execution** (Layer C) — `ALLM.generate/3`, `stream_generate/3`, `step/3`, `stream_step/3`, `chat/3`, `stream/3` on the top-level `ALLM` module. Everything takes an engine explicitly.
4. **Stateful continuation** (Layer D) — `ALLM.Session.start/stream_start/reply/stream_reply/step/stream_step`, operating over a persisted `%ALLM.Session{}`.

Key invariants:

- **Stream-first.** `stream_*` functions are the primitives. Non-streaming variants are reducers over the event stream via `ALLM.StreamCollector`. Implement streaming paths first (§3, §28).
- **Event protocol is the wire format between the stream runner and consumers.** `ALLM.Event` is a closed tagged-tuple union (§8). Adding a new event type is a breaking change for reducers.
- **Engines don't carry API keys.** Keys resolve through `ALLM.Keys` at adapter-call time (§6.4). A serialized engine/session is safe to persist; verify with tests.
- **Model strings are late-resolved.** Optional `llm_db` dependency provides capability pre-flight and cost population; core must function without it (§6.3).
- **Two orchestration modes.** `:auto` (loop executes tools automatically) and `:manual` (caller submits tool results). Ask-user suspension via `{:ask_user, ...}` handler return works in both modes (§12.3).
- **HTTP transport split.** Non-streaming: `Req`. Streaming: `Finch` directly (HTTP/1, not HTTP/2 — documented in spec §7.2 due to a flow-control bug affecting large request bodies).
- **Telemetry is the extension point.** `middleware:` is reserved for a later version and must stay `[]` in v0.2 (§29). Cross-cutting concerns go through telemetry handlers or adapter wrappers.

Build order recommended by the spec (§28): data structs → `Engine` → behaviours → `Event` → stream runner + `ALLM.Providers.Fake` → collectors/reducers → streaming APIs → non-streaming wrappers → session helpers → real provider adapters (OpenAI, Anthropic).

## Where things live

- `steering/allm_engine_session_streaming_spec_v0_2.md` — authoritative spec. Section numbers are stable; reference them in commit messages and code comments when the design is non-obvious (e.g., `# see §12.3 ask-user`).
- `steering/examples/` — target application shapes the library must support. Consult when choosing ergonomics.
- `lib/allm.ex` — top-level facade (§4).
- `lib/allm/` — module tree mirroring §27 of the spec.
- `lib/allm/providers/fake.ex` — deterministic scripted adapter; the primary test vehicle (§31).

## Common commands

```bash
mix deps.get              # install deps
mix compile               # compile
mix format                # format
mix test                  # full suite
mix test test/path/to/file_test.exs:42   # single test by line number
mix test --only focus     # run tests tagged @tag :focus
mix credo --strict        # linter (once credo is added)
mix dialyzer              # type check (once dialyxir is added)
iex -S mix                # REPL with project loaded
```

The dev container (`.devcontainer/devcontainer.json`) ships with Node and Go but **not Elixir** — Elixir/OTP need to be installed separately (e.g., via `asdf` or the Erlang Solutions repo) before `mix` commands work.

## Working on this codebase

- When a change touches behaviour or spec-defined shapes, cite the section (`§6.3`, `§12.3`, etc.) in the commit message so reviewers can diff intent against the spec.
- `ALLM.Providers.Fake` is the canonical way to test orchestration. Do not reach for network mocks unless you're testing a real provider adapter's wire shape.
- Property-style scenarios listed in §31 are the minimum bar — every implementation must pass them.
