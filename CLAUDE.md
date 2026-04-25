# CLAUDE.md

Guidance for Claude Code working in this repository.

## Project goal

ALLM (Agent LLM) is an Elixir library for provider-neutral LLM execution with first-class streaming and serializable conversation state. The canonical spec is `steering/allm_engine_session_streaming_spec_v0_2.md` — source of truth for module names, types, and behaviour. Target application shapes live in `steering/examples/`.

The package is in initial scaffolding; most modules under `lib/allm/` are skeletons pending implementation per spec §28.

## Architecture in one page

Four conceptual layers — crossing a layer boundary usually signals a design mistake:

1. **Layer A — Serializable data.** `ALLM.Message`, `ALLM.ToolCall`, `ALLM.Request`, `ALLM.Response`, `ALLM.Thread`, `ALLM.Session`, `ALLM.StepResult`, `ALLM.ChatResult`, `ALLM.Event`, `ALLM.Usage`. Plain structs; round-trip through `:erlang.term_to_binary/1` and JSON. No PIDs, refs, funs, or API keys.
2. **Layer B — Runtime.** `ALLM.Engine` plus the `ALLM.Adapter`, `ALLM.StreamAdapter`, `ALLM.ToolExecutor`, `ALLM.ToolResultEncoder` behaviours. Holds non-serializable deps (modules, funs, Finch names, keys resolved at call time).
3. **Layer C — Stateless execution.** `ALLM.generate/3`, `stream_generate/3`, `step/3`, `stream_step/3`, `chat/3`, `stream/3`. Engine passed explicitly.
4. **Layer D — Stateful continuation.** `ALLM.Session.start/stream_start/reply/stream_reply/step/stream_step` over a persisted `%ALLM.Session{}`.

Key invariants:

- **Stream-first.** `stream_*` are the primitives; non-streaming variants are reducers via `ALLM.StreamCollector`. Implement streaming paths first (§3, §28).
- **Event protocol is the wire format between runner and consumers.** `ALLM.Event` is a closed tagged-tuple union (§8). Adding a variant is breaking for reducers; adding a key to an *existing* event's payload map is NOT breaking (pattern-matching on payload keys is non-exhaustive). Document new keys in spec §8 and the constructor's `@doc`. Worked example: `:step_completed` payload grew `:mode` (batch 7.3) to carry `:auto | :manual` to `StreamCollector`'s fold.
- **Engines don't carry API keys.** Keys resolve through `ALLM.Keys` at adapter-call time (§6.4). Serialized engine/session must be safe to persist; verify with tests.
- **Model strings are late-resolved.** Optional `llm_db` provides capability pre-flight and cost population; core must function without it (§6.3).
- **Two orchestration modes.** `:auto` (loop runs tools) and `:manual` (caller submits results). `{:ask_user, ...}` suspension works in both (§12.3).
- **HTTP transport split.** Non-streaming: `Req`. Streaming: `Finch` directly, HTTP/1 (not HTTP/2 — flow-control bug affecting large bodies, spec §7.2).
- **Telemetry is the extension point.** `middleware:` is reserved for later and must stay `[]` in v0.2 (§29). Cross-cutting concerns go through telemetry handlers or adapter wrappers.
- **Mid-stream adapter errors fold into the response, not the call-site tuple.** A mid-stream `{:error, struct}` event surfaces as `{:ok, %Response{finish_reason: :error, metadata: %{error: struct}}}` from `ALLM.generate/3` / `ALLM.step/3` — the call-site tuple stays `{:ok, _}`. Only synchronous pre-flight errors (missing adapter, invalid request, adapter pre-flight failure) surface as `{:error, struct}` at the call site. Callers matching only `{:error, _}` will silently swallow rate limits, content-filter blocks, and stream cancellations. Spec §10.1, PHASE_5 Decision #4.

Build order (spec §28): data structs → `Engine` → behaviours → `Event` → stream runner + `ALLM.Providers.Fake` → collectors/reducers → streaming APIs → non-streaming wrappers → session helpers → real provider adapters.

## Where things live

- `steering/allm_engine_session_streaming_spec_v0_2.md` — authoritative spec. Cite section numbers in commits and comments (`# see §12.3 ask-user`).
- `steering/examples/` — target application shapes.
- `lib/allm.ex` — top-level facade (§4).
- `lib/allm/` — module tree mirroring spec §27.
- `lib/allm/providers/fake.ex` — deterministic scripted adapter; primary test vehicle (§31).

## Common commands

Toolchain floor: Elixir `~> 1.17`, Erlang/OTP 27+ (see `mix.exs`).

```bash
mix deps.get              # install deps
mix compile               # compile
mix format                # format
mix test                  # full suite (80% coverage threshold in mix.exs)
mix test test/path/to/file_test.exs:42   # single test by line
mix test --only focus     # tests tagged @tag :focus
mix credo --strict        # linter
mix dialyzer              # type check
iex -S mix                # REPL
```

Test-only helpers live under `test/support/` (in `elixirc_paths` for `:test` only) — home for `ALLM.Providers.Fake` fixtures and other test-only modules.

The dev container ships Node, Go, and Elixir/OTP via the `rabdulwahhab/devcontainer-features` asdf features — keep `erlang-asdf` in the features list because `elixir-asdf` depends on it.

## Working on this codebase

- Cite spec sections (`§6.3`, `§12.3`, …) in commit messages when the change touches behaviour or spec-defined shapes.
- `ALLM.Providers.Fake` is the canonical test vehicle. Don't reach for network mocks except to test a real adapter's wire shape.
- §31 property-style scenarios are the minimum bar for every implementation.
- `optional: true` in `mix.exs` does NOT skip Hex version resolution — it only governs whether *downstream apps* need the dep. A placeholder constraint against a dep with mismatched published versions still breaks `mix deps.get`. Defer future deps as a code comment (`# :llm_db re-added in Phase 9 …`), not a live constraint.
