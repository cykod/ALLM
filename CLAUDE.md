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
- **Event protocol is the wire format between the stream runner and consumers.** `ALLM.Event` is a closed tagged-tuple union (§8). Adding a new event type is a breaking change for reducers. Adding a key to an *existing* event's payload map is NOT breaking — pattern-matching on payload keys is non-exhaustive, so existing reducers ignore the new key. When extending payload, document the new key in spec §8 and the event constructor's `@doc`. Worked example: `:step_completed` payload grew a `:mode` key in batch 7.3 to carry `:auto | :manual` from `Chat.stream_step/3` to `StreamCollector`'s fold.
- **Engines don't carry API keys.** Keys resolve through `ALLM.Keys` at adapter-call time (§6.4). A serialized engine/session is safe to persist; verify with tests.
- **Model strings are late-resolved.** Optional `llm_db` dependency provides capability pre-flight and cost population; core must function without it (§6.3).
- **Two orchestration modes.** `:auto` (loop executes tools automatically) and `:manual` (caller submits tool results). Ask-user suspension via `{:ask_user, ...}` handler return works in both modes (§12.3).
- **HTTP transport split.** Non-streaming: `Req`. Streaming: `Finch` directly (HTTP/1, not HTTP/2 — documented in spec §7.2 due to a flow-control bug affecting large request bodies).
- **Telemetry is the extension point.** `middleware:` is reserved for a later version and must stay `[]` in v0.2 (§29). Cross-cutting concerns go through telemetry handlers or adapter wrappers.
- **Mid-stream adapter errors fold into the response, not the call-site tuple.** A mid-stream `{:error, struct}` event from the adapter surfaces as `{:ok, %Response{finish_reason: :error, metadata: %{error: struct}}}` from `ALLM.generate/3` / `ALLM.step/3` — the call-site tuple stays `{:ok, _}`. Only synchronous pre-flight errors (missing adapter, invalid request, adapter-reported pre-flight failure) surface as `{:error, struct}` at the call site. Callers pattern-matching on `{:error, _}` and falling through on any other shape will silently swallow mid-stream errors like rate limits, content-filter blocks, and stream cancellations. Spec §10.1, PHASE_5 Non-obvious Decision #4.

Build order recommended by the spec (§28): data structs → `Engine` → behaviours → `Event` → stream runner + `ALLM.Providers.Fake` → collectors/reducers → streaming APIs → non-streaming wrappers → session helpers → real provider adapters (OpenAI, Anthropic).

## Where things live

- `steering/allm_engine_session_streaming_spec_v0_2.md` — authoritative spec. Section numbers are stable; reference them in commit messages and code comments when the design is non-obvious (e.g., `# see §12.3 ask-user`).
- `steering/examples/` — target application shapes the library must support. Consult when choosing ergonomics.
- `lib/allm.ex` — top-level facade (§4).
- `lib/allm/` — module tree mirroring §27 of the spec.
- `lib/allm/providers/fake.ex` — deterministic scripted adapter; the primary test vehicle (§31).

## Common commands

Toolchain floor: Elixir `~> 1.17`, Erlang/OTP 27+ (see `mix.exs`).

```bash
mix deps.get              # install deps
mix compile               # compile
mix format                # format
mix test                  # full suite (80% coverage threshold configured in mix.exs)
mix test test/path/to/file_test.exs:42   # single test by line number
mix test --only focus     # run tests tagged @tag :focus
mix credo --strict        # linter
mix dialyzer              # type check
iex -S mix                # REPL with project loaded
```

Test-only helpers live under `test/support/` (added to `elixirc_paths` in the `:test` env only) — this is the right home for `ALLM.Providers.Fake` fixtures and other test-only modules.

The dev container (`.devcontainer/devcontainer.json`) ships with Node, Go, and Elixir/OTP (installed via the `rabdulwahhab/devcontainer-features` asdf-based features — `erlang-asdf` must stay in the features list because `elixir-asdf` depends on it).

## Working on this codebase

- When a change touches behaviour or spec-defined shapes, cite the section (`§6.3`, `§12.3`, etc.) in the commit message so reviewers can diff intent against the spec.
- `ALLM.Providers.Fake` is the canonical way to test orchestration. Do not reach for network mocks unless you're testing a real provider adapter's wire shape.
- Property-style scenarios listed in §31 are the minimum bar — every implementation must pass them.
- `optional: true` in `mix.exs` does NOT skip Hex version resolution — it only governs whether *downstream applications* need the dep. For *this* project, Hex still has to resolve the version constraint, so a placeholder like `{:llm_db, "~> 0.1", optional: true}` against a dep whose published versions are `2026.x` will break `mix deps.get`. Defer future deps as a code comment (`# :llm_db re-added in Phase 9 …`), not as a live constraint with an invented version.
