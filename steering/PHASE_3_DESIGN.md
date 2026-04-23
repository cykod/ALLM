# Phase 3: Behaviours + Default Implementations + Conformance Harness — Design Document

> **Goal:** Harden the four Layer B behaviours (`ALLM.Adapter`, `ALLM.StreamAdapter`, `ALLM.ToolExecutor`, `ALLM.ToolResultEncoder`) into contracts precise enough to swap implementations against, ship the two default implementations every adapter composes with (`ALLM.ToolExecutor.Default`, `ALLM.ToolResultEncoder.JSON`), and publish a four-part conformance harness that every current and future implementation (Fake in Phase 4, OpenAI in Phase 10, Anthropic in Phase 11) must pass verbatim.
> **Outcome:** Each behaviour declares a full `@callback` signature with `@doc`, uses `%ALLM.Error.AdapterError{}` / `%ALLM.Error.ToolError{}` / `%ALLM.Error.EngineError{}` structs instead of bare `term()` in error positions, and documents required vs. optional callbacks. `ALLM.ToolExecutor.Default` dispatches both arity-1 and arity-2 tool handlers, returns all four `handler_result()` shapes unchanged, and converts handler raises / exits / timeouts / invalid returns to `%ALLM.Error.ToolError{}`. `ALLM.ToolResultEncoder.JSON` passes binaries through unchanged, encodes `{:ok, value}` / `{:error, reason}` / maps as documented, and exposes a single `encode/1` entry point. Four `ALLM.Test.*Conformance` modules under `test/support/` provide `use`-able macros that inject a full test suite into any adapter/executor/encoder test file; `ALLM.Providers.Fake` (Phase 4) and every real provider (Phases 10–11) plug in unchanged. `mix test`, `mix credo --strict`, `mix dialyzer`, and `mix format --check-formatted` all green.
> **Spec sections:** §7.1–§7.4 (behaviours), §18 (defaults), §20 (error reasons), §31 (conformance test surface)
> **Layers touched:** B (Runtime). No Layer A struct shape changes. No Layer C/D execution surface is added — this phase ships the contract and the defaults that stateless execution (Phase 5+) will depend on.
> **Phasing doc:** [`PROJECT_PHASING.md`](PROJECT_PHASING.md) Phase 3.

## Status

| Sub-phase | Description | Layer | Status |
|-----------|-------------|-------|--------|
| 3.1 | `ALLM.Adapter` + `ALLM.StreamAdapter` contract hardening (typespec + `@doc` + tightened error shape) | B | Not Started |
| 3.2 | `ALLM.ToolExecutor` + `ALLM.ToolResultEncoder` contract hardening | B | Not Started |
| 3.3 | `ALLM.ToolExecutor.Default` implementation | B | Not Started |
| 3.4 | `ALLM.ToolResultEncoder.JSON` implementation | B | Not Started |
| 3.5 | `ALLM.Test.*Conformance` harness (four modules under `test/support/`) | B | Not Started |

**Overall Progress:** 0/5 sub-phases complete

## Overview

Phase 3 completes Layer B's **contract surface**. Today every behaviour file is three lines: a bare `@callback` with `term()` in every error slot, no `@doc`, no `@optional_callbacks` annotations beyond `ALLM.Adapter`, and no reference implementation that future adapters can pattern-match against. Phase 4 (Fake) and Phases 10/11 (real providers) cannot be built against a behaviour that doesn't document how `{:error, _}` is shaped or what `execute/3` is expected to do when a handler raises. This phase answers both questions in the behaviour module itself (the contract) and in the conformance harness (the executable verification) — so every implementation that ships passes the same test suite, and users writing their own adapters `use` the same harness.

This design **refines spec §7 by replacing `{:error, term()}` in callback return types with the Phase 1 error structs**. The spec was written before the Phase 1 error contract landed; `AGENT_DESIGN_SPEC.md` §7 already calls out `{:error, term()}` as "a code smell that says the error contract isn't designed." Phase 3 tightens the callbacks:

- `ALLM.Adapter.generate/2` returns `{:ok, %Response{}} | {:error, %ALLM.Error.AdapterError{}}` (was `{:error, term()}`).
- `ALLM.StreamAdapter.stream/2` returns `{:ok, Enumerable.t()} | {:error, %ALLM.Error.AdapterError{}}`. The stream itself may terminate with `{:error, %ALLM.Error.AdapterError{} | %ALLM.Error.StreamError{}}` events per spec §8 — `StreamError` for transport-level failures (truncated SSE, malformed chunk, `Finch` connection drop) and `AdapterError` for HTTP-level failures surfaced mid-stream (e.g. a 429 mid-response). The distinction is declared in the conformance suite so the test matrix is explicit.
- `ALLM.ToolExecutor.execute/3`'s `@callback` stays `ALLM.Tool.handler_result()` — this is **not** a typespec tightening because `t:ALLM.Tool.handler_result/0` remains `{:error, term()}` in `lib/allm/tool.ex` (narrowing it would be a Layer A change Phase 3 disavows). Instead Phase 3 establishes a **runtime contract**: when an error originates in the executor itself (raise, exit, invalid return shape, missing handler), the executor emits `{:error, %ALLM.Error.ToolError{}}`; handler-originated `{:error, reason}` returns pass through unchanged. The conformance suite enforces this runtime contract via pattern-match assertions — Dialyzer does not verify it. Tightening `handler_result()` to narrow the executor-originated branch is a v0.3 candidate (a Layer A amendment with its own Phase 1-style design).
- `ALLM.ToolResultEncoder.encode/1` stays `term() -> String.t()` — this is a pure function over plain data. The conformance suite verifies round-trip through `Jason.decode!/1` for every shape the default encoder claims to handle.

No spec amendment is required because §20 already enumerates every atom used in these structs. The adapter changes are a **typespec narrowing** of `term()` (Dialyzer-verifiable); the executor change is a **runtime convention** enforced by tests. The spec's `{:error, term()}` examples remain correct under both; `%ALLM.Error.*{}` is a `term()`.

This design **ships the conformance harness as a sibling Hex package, `allm_conformance`, developed in an in-repo sub-project at `conformance/`**. See Non-obvious Decision #1 for the full tradeoff. The short version: the harness needs `ExUnit.CaseTemplate` and (for future extensions) `StreamData` — test-framework deps that would leak into the main package's runtime if shipped from `lib/`, and which create real ergonomic tax if shipped from `test/support/` (consumers having to add a path to `elixirc_paths`, transitively picking up `stream_data` as a test dep they didn't opt into, `mix hex.publish` lint warnings on unused-in-`lib` files). Shipping as a separate Hex package gives a one-line install for consumers (`{:allm_conformance, "~> 0.2", only: :test}`), a clean dep graph (published dep direction is `allm_conformance -> allm`, acyclic), and no surgery to consumer `elixirc_paths`. The main `allm` package itself depends on `allm_conformance` via a `path: "conformance", only: :test` dev-time path dep so that `lib/allm/tool_executor/default.ex` can certify against the harness during Phase 3 verification — the circular dep only exists at development time (path deps) and is flattened in the published graph (Hex publishes the two packages separately, neither carrying the cycle).

### Deliverables

- **Modified modules**: `ALLM.Adapter`, `ALLM.StreamAdapter`, `ALLM.ToolExecutor`, `ALLM.ToolResultEncoder` — each gets a `@moduledoc` expanded to match the spec §7 narrative, a `@doc` on every `@callback`, full type signatures matching the error structs from Phase 1, and `@optional_callbacks` clarified.
- **New modules**: `ALLM.ToolExecutor.Default` (default executor — invokes `Tool.handler`), `ALLM.ToolResultEncoder.JSON` (default encoder — `Jason`-backed).
- **New sibling Hex package** (`allm_conformance`, developed in `conformance/`): ships four `ALLM.Test.*Conformance` modules (`AdapterConformance`, `StreamAdapterConformance`, `ToolExecutorConformance`, `ToolResultEncoderConformance`), each an `ExUnit.CaseTemplate` that injects `describe/2` blocks via a `using/1` macro (see §3.5 for the exact shape). Each conformance module publishes to Hex under the `allm_conformance` package. Consumers install with one line: `{:allm_conformance, "~> 0.2", only: :test}`.
- **New test-fixture modules shipped with `allm_conformance`**: `ALLM.Test.Fixtures.StubAdapter` — a permanent ~40–50-line minimum-viable adapter that the conformance suite's self-tests run against to prove the suite passes a known-good implementation. Lives in `conformance/test/support/fixtures/stub_adapter.ex` — *not* shipped in the `lib/` of `allm_conformance` because it's a fixture for the harness's own tests, not a public helper.
- **New main-package tests**: `test/allm/tool_executor/default_test.exs`, `test/allm/tool_result_encoder/json_test.exs`, plus behaviour-level contract tests at `test/allm/adapter_test.exs`, `test/allm/stream_adapter_test.exs`, `test/allm/tool_executor_test.exs`, `test/allm/tool_result_encoder_test.exs` that verify the contract shape (e.g., `@callback`s are declared with the documented arity, `@optional_callbacks` lists what the spec says is optional). The two default-impl test files `use ALLM.Test.ToolExecutorConformance` / `ALLM.Test.ToolResultEncoderConformance` via the path dep to certify the defaults against the harness.
- **`mix.exs` changes (main project)**: add `{:allm_conformance, path: "conformance", only: :test}` to `deps()`. The `package: files:` list is **not** extended — `test/support/` stays local to `allm`.
- **New `conformance/mix.exs`**: declares `app: :allm_conformance`, `deps: [{:allm, "~> 0.2"} || {:allm, path: ".."}]` (path dep at development, Hex dep at publish time), `package: ...` metadata for Hex publish.

### Spec coverage

- **§7.1** `ALLM.Adapter` — tightened to `%AdapterError{}` on the `generate/2` error branch; `prepare_request/2` stays `@optional_callbacks` (documented escape hatch, Phase 10 exercises it); `translate_options/2` stays optional with a documented default-identity semantics (§7.1 paragraph 3).
- **§7.2** `ALLM.StreamAdapter` — tightened to `%AdapterError{}` on the `stream/2` synchronous error branch, with mid-stream error events typed as `%AdapterError{}` (HTTP-shaped) or `%StreamError{}` (transport-shaped). HTTP transport guidance quoted verbatim in the `@moduledoc`.
- **§7.3** `ALLM.ToolExecutor` — `execute/3` narrowed per the Overview; the conformance suite exercises every handler-result variant from spec §5.2 (`{:ok, _}`, `{:error, _}`, `{:ask_user, _}`, `{:ask_user, _, _}`, `{:halt, _, _}`) **plus** the failure modes the executor itself produces (`:handler_raised`, `:handler_exit`, `:timeout`, `:invalid_return`).
- **§7.4** `ALLM.ToolResultEncoder` — `encode/1` signature unchanged; the conformance suite exercises binary, map, keyword-list, number, boolean, `nil`, `{:ok, _}`, `{:error, _}` inputs.
- **§18** Default implementations — `ALLM.ToolExecutor.Default` and `ALLM.ToolResultEncoder.JSON` ship per the spec's 3-line skeletons, with full `@doc` + doctests + the documented arity-1 / arity-2 handler dispatch.
- **§20** Error model — every `{:error, _}` in a Phase 3 @spec names a struct; no `term()` remains in behaviour error positions.
- **§31** Testing — the four conformance modules **are** the "every implementation must pass them" contract. Phase 4 plugs Fake into all four; Phase 10–11 plug each real adapter into the relevant pair.

### Layer demonstration

Phase 3 is entirely Layer B. A user building an adapter of their own can write and test it against the published harness without ever running a real HTTP call or a real provider key:

```elixir
# Layer B: a user's custom adapter (say, a proxy that wraps a cached backend).
defmodule MyApp.CachedAdapter do
  @behaviour ALLM.Adapter
  @impl true
  def generate(%ALLM.Request{} = req, opts), do: # ... cache hit, else delegate
end

# Layer B: that adapter's test file uses the shipped harness unchanged.
# Consumer mix.exs:
#   defp deps, do: [
#     {:allm, "~> 0.2"},
#     {:allm_conformance, "~> 0.2", only: :test}
#   ]
defmodule MyApp.CachedAdapterTest do
  use ExUnit.Case, async: true
  use ALLM.Test.AdapterConformance, adapter: MyApp.CachedAdapter

  # The harness injects the full conformance suite. Additional app-specific
  # cases live below alongside it.
  describe "cache hit" do
    test "returns the cached response without calling upstream" do
      # ...
    end
  end
end
```

No Layer A struct shape changes; no Layer C/D execution function exists yet. Phase 3 lets a user write and certify a Layer B adapter without waiting for Phase 5 (`ALLM.generate/3`) to ship, using a single extra `:test`-env dep.

### Prerequisites

- **Phase 1 complete.** Phase 3 depends on the `ALLM.Error.{AdapterError, EngineError, StreamError, ToolError, ValidationError}` structs (Phase 1), `ALLM.Tool` (`handler` and `handler_result` types, `@enforce_keys`), and `ALLM.ToolCall` (the conformance suite builds `%ToolCall{}` values as inputs).
- **Phase 2 complete.** `ALLM.Engine` resolver functions (`resolve_params/2`, `resolve_tools/2`) are the shape `opts` takes when it reaches an executor or adapter in Phase 5+; the conformance suite's input fixtures mirror that shape.
- **No dependency on Phase 4 or later.** Phase 3 lands before `ALLM.Providers.Fake`. `ALLM.Test.Fixtures.StubAdapter` is a **permanent** test-support fixture (inside `conformance/test/support/`) that self-verifies the conformance suite; Phase 4 adds `ALLM.Providers.Fake` in the main `allm` package and adds a *second* self-test file in the main project that runs the same conformance suite against Fake. The stub remains as the harness's primary self-test subject. Phase 4 adds, never replaces.
- **New sub-project scaffolding.** Phase 3 introduces the `conformance/` sub-project — the first time this repo has contained more than one Mix project. Tooling (CI scripts, `.gitignore`, editor config) must be updated to run `mix test` and `mix hex.build` in both roots. The Phase 3 verification block (§3.5.3) is explicit about `cd conformance && mix test` vs. root-level `mix test`.

### Out of scope

- **`ALLM.Providers.Fake`.** Phase 4. Phase 3 ships the harness but not the implementation that will be the primary conformance subject. `ALLM.Test.Fixtures.StubAdapter` is a permanent ~30-line test-support adapter that (a) self-verifies the harness in Phase 3, (b) remains as a minimum-viable reference for users writing their own adapters. Phase 4 adds `ALLM.Providers.Fake` in parallel; it does not replace the stub.
- **`ALLM.Adapter.prepare_request/2` customization.** The escape hatch stays `@optional_callbacks`; no default implementation is shipped, and no orchestration code consumes it in Phase 3. Phase 10 (OpenAI) implements it concretely and adds a test asserting callers can add Req headers without losing orchestration.
- **`ALLM.Adapter.translate_options/2` default.** The behaviour declares it optional; the spec says "default implementation is identity" (§7.1). No `use ALLM.Adapter` macro ships in Phase 3 — providers that don't implement `translate_options/2` get `@optional_callbacks` semantics (the caller must handle `function_exported?/3`). Phase 5 (`ALLM.generate/3`) is where the call site decides whether to shim identity or require providers to implement it. Phase 3 documents the convention but does not ship the shim. **Phase 5 handoff:** Phase 5's design **must** include a test asserting that calling into an adapter that does not implement `translate_options/2` succeeds without raising `UndefinedFunctionError` — i.e., Phase 5's executor correctly uses `function_exported?/3` before dispatch. The Phase 3 conformance suite cannot verify this (it tests the behaviour, not the caller); the responsibility transfers to Phase 5's test plan. `StubAdapter` intentionally omits `translate_options/2` so that when Phase 5 wires its executor against the conformance suite, a missing `function_exported?/3` guard surfaces immediately.
- **Retry-aware executor.** `ALLM.ToolExecutor.Default` does not retry handler failures. Retries are an engine-level concern (spec §6.1 `retry:` applies to adapter calls, not tool execution) and tool-level retries are a user-side concern (wrap the handler).
- **Timeout enforcement inside the executor.** `ALLM.ToolExecutor.Default` does **not** spawn a `Task` and wait with `Task.yield/2`. That lands in Phase 6 (`ALLM.ToolRunner`) where parallel tool execution requires task supervision anyway. Phase 3's default executor is synchronous: call the handler, rescue, exit-trap, convert to `%ToolError{}`. The conformance suite's `:timeout` test case is exercised via a handler that returns `{:error, %ToolError{reason: :timeout}}` directly — Phase 6 wires the real `Task.yield/2` clock and the conformance assertion survives unchanged.
- **Structured-output tool-forcing (Anthropic).** Spec §5.4 mentions that Anthropic implements structured output via tool-forcing; that is an adapter-level concern (Phase 11), not a behaviour concern. The conformance suite does not assert on structured-output tool-forcing.
- **Capability pre-flight.** Phase 9. `ALLM.Engine.capability?/2` does not exist yet; the conformance suite does not reference it.
- **Multiplexed executors / custom encoders in v0.2.** Only one default of each ships. Users may plug in their own `ALLM.ToolExecutor` / `ALLM.ToolResultEncoder` module by setting `engine.tool_executor` / `engine.tool_result_encoder`; the conformance suite certifies their implementations against the same contract.

### Non-obvious decisions

1. **Conformance modules ship as a sibling Hex package, `allm_conformance`, developed in an in-repo sub-project at `conformance/`.** Three-way tradeoff:
   - **`lib/` in the main `allm` package** — user deps `{:allm, "~> 0.2"}` in `deps()` and imports the harness. Cost: `ExUnit.CaseTemplate`, and any future `StreamData` generators the harness wants, become compile-time deps of the main runtime package. `ExUnit.CaseTemplate` only resolves cleanly when `:ex_unit` is started, which adds startup cost for users who never test. `Code.ensure_loaded?` guards get ugly fast. Rejected.
   - **`test/support/` shipped via `package: files: [..., "test/support"]`** (the `ecto_sql` pattern) — the harness is in the Hex tarball but not on the runtime load path. Consumers add `"deps/allm/test/support"` to their `elixirc_paths(:test)`. Cost: (a) consumers pick up `stream_data`/harness transitive test deps they didn't opt into; (b) `mix hex.publish` warns on `test/support` files not declared in any `elixirc_paths` configuration for the main package; (c) consumer tooling (static analyzers, docs generators) sometimes chokes on unusual load paths; (d) upgrade-path for the harness is coupled to the main `allm` version, forcing a main-package release for harness-only fixes. Rejected after the review question.
   - **Sibling Hex package `allm_conformance`, in-repo sub-project at `conformance/`** — consumers add one line, `{:allm_conformance, "~> 0.2", only: :test}`, to their `:test`-only deps. Cost: (a) we maintain a second `mix.exs` and publish two packages in lockstep; (b) the sub-project has a `path: ".."` dep on `allm` for local dev, and a `"~> 0.2"` Hex dep post-publish; (c) the main `allm` has a `{:allm_conformance, path: "conformance", only: :test}` dev-time dep so it can certify its own defaults against the harness. The cycle exists only at path-dep time (Mix permits it because path deps aren't in the Hex graph); published, the graph is `allm_conformance → allm`, acyclic.

   Decision: **sibling Hex package.** The ergonomic cost of the `test/support/` pattern falls on every consumer and surfaces in unpredictable places (static analyzers, docs tools, transitive test deps); the maintenance cost of a sibling package falls on the library authors in one predictable place (release coordination). Consumer-facing simplicity wins. Two published packages, clean dep graph, one line of consumer install, no `elixirc_paths` surgery. The lockstep-publish discipline is absorbed in the release checklist (see Sub-phase 3.5.3 verification). `Docs target: @moduledoc ALLM.Test.AdapterConformance` (one paragraph on installation — no path-manipulation required).

2. **Callback error shapes are narrowed to error structs, and the narrowing is declared both in the behaviour's `@callback` and in a `@doc` table.** The `@callback generate/2 :: ... | {:error, %ALLM.Error.AdapterError{}}` line is machine-verifiable by Dialyzer. The `@doc` table below each callback lists every `AdapterError.reason()` atom the callback is expected to produce and when — a human-readable error-contract index adapters can pattern-match against. The table is the spec's §20 atoms (`:rate_limited`, `:authentication_failed`, `:invalid_request`, `:provider_unavailable`, `:context_length_exceeded`, `:content_filter`, `:timeout`, `:network_error`, `:malformed_response`, `:unsupported_feature`, `:unknown`) plus a one-line "fires when" per row. Conformance test cases are named after the reason atoms so a failure points directly at the row. `Docs target: @doc ALLM.Adapter.generate/2`.

3. **`ALLM.ToolExecutor.Default` converts a handler raise to `{:error, %ALLM.Error.ToolError{reason: :handler_raised, cause: exception}}`; the handler's **own** `{:error, reason}` return is passed through unchanged.** The distinction is "did the handler crash, or did it report a failure?" — both are failures, but the orchestrator handles them differently (the orchestrator may apply `on_tool_error: :continue` to a raised failure but pattern-match on a specific handler-returned `{:error, :user_not_found}` for business logic). Converting every failure into the same `%ToolError{}` would erase that distinction. The conformance suite has separate cases for both. `Docs target: @doc ALLM.ToolExecutor.Default.execute/3` (a short paragraph making the distinction explicit).

4. **`ALLM.ToolResultEncoder.JSON.encode/1` passes binaries through unchanged but wraps maps / lists / `{:ok, _}` / `{:error, _}` in a Jason round-trip.** Rationale: a handler that returns `"text already ready for the model"` should not be re-encoded into `"\"text already ready for the model\""` (double-quoted) — the spec §18 says "JSON-encodes the result" but the reference implementation has to be friendly to handlers that pre-format. Non-binary inputs go through `Jason.encode!/1`. `{:ok, inner}` maps to `Jason.encode!(%{ok: inner})`; `{:error, reason}` maps to `Jason.encode!(%{error: inspect(reason)})` (the spec phases this as "encodes `{:error, reason}` as `%{"error" => inspect(reason)}`" — §3 of the phasing doc's Phase 3 paragraph). A user who wants a different encoding plugs in their own encoder module. `Docs target: @doc ALLM.ToolResultEncoder.JSON.encode/1` (one table of input-shape → output-shape).

5. **`ALLM.ToolExecutor.Default` handles both arity-1 and arity-2 tool handlers via `Function.info/1`-based dispatch, not a separate callback.** The handler's arity is discovered at call time with `:erlang.fun_info(handler, :arity)`; arity 1 is called with `arguments`, arity 2 is called with `arguments, opts`. The `opts` keyword list contains every key listed in spec §5.2 (`:context`, `:session_id`, `:request_id`, `:tool_call`, `:engine`) — the executor populates whatever its caller passes in and passes `nil` for keys the caller didn't provide. This matches the spec's handler-type declaration (`(map() -> _) | (map(), keyword() -> _)`). A `{Module, :function}` handler is a v0.3 enhancement not covered in Phase 3; the conformance suite asserts that the default executor raises `FunctionClauseError` (or the equivalent) on an MFA-tuple handler, which is the honest failure mode until Phase 8+ extends the dispatch. `Docs target: @doc ALLM.ToolExecutor.Default.execute/3`.

6. **The conformance harness is an `ExUnit.CaseTemplate` with `using/1`, not a plain `__using__/1` macro.** `ExUnit.CaseTemplate` gives us `setup/1` blocks, `describe/2` support, and tag inheritance — the three features the conformance suite needs. A raw macro would require re-implementing those primitives. The `use ALLM.Test.AdapterConformance, adapter: MyModule` call passes the subject module as a compile-time attribute; the template's `setup/1` builds a base `%ALLM.Request{}` fixture and stores the subject in the test context so every injected test reads `context.adapter`. `Docs target: @moduledoc ALLM.Test.AdapterConformance`.

7. **The conformance suite is deterministic and does not make network calls.** Every input is a scripted `%ALLM.Request{}` value; every expected output is a shape assertion (struct pattern match) or a reason-atom equality. There is no `StreamData` property testing inside the conformance suite itself — property tests belong in per-implementation test files where the author picks a sensible scenario budget. This keeps the harness a cheap smoke test: ~40 cases per behaviour, each taking <1ms. `Docs target: internal — no user-facing docs needed`.

8. **`ALLM.Test.*Conformance` modules live under `ALLM.Test.*` (matching `test/support/` layout), not `ALLM.Conformance.*`.** The `ALLM.Test` namespace in `test/support/` already houses `ALLM.Test.Generators` (Phase 1 property-test generators); keeping all test-only modules under the same namespace avoids confusion about which modules ship in the runtime dispatcher. A consumer reading `ALLM.Test.AdapterConformance` in their own deps sees the `Test` prefix and knows the module is test-only. `Docs target: internal — no user-facing docs needed`.

9. **Behaviour tests (`test/allm/adapter_test.exs` etc.) are separate from conformance tests and do not run a subject — they assert the contract at the module level.** Specifically: the behaviour test asserts that `ALLM.Adapter.__info__(:attributes)` declares the expected `@callback`s at the expected arities, that `@optional_callbacks` lists exactly what the spec declares optional, and that each callback has a non-empty `@doc`. This is a cheap regression test that catches behaviour drift (e.g., someone renaming `generate/2` to `run/2` without updating the spec). `Docs target: internal — no user-facing docs needed`.

10. **`ALLM.ToolExecutor.Default` is the documented default when `engine.tool_executor` is `nil`, but no macro "installs" it.** Phase 5+ (`ALLM.step/3`, etc.) contains the single line `engine.tool_executor || ALLM.ToolExecutor.Default` at the point of use. Phase 3 does **not** pre-populate `engine.tool_executor` in `Engine.new/1`; an engine with `tool_executor: nil` is still valid and the later-phase executor dispatch resolves to the default. Same for `ALLM.ToolResultEncoder.JSON`. This keeps `Engine.new/1` a pure struct constructor and matches Phase 2's resolver-at-call-time pattern. `Docs target: @moduledoc ALLM.ToolExecutor.Default` and `@moduledoc ALLM.ToolResultEncoder.JSON`.

## Behaviour & Type Contracts

### `ALLM.Adapter` (Layer B — behaviour)

```elixir
defmodule ALLM.Adapter do
  @moduledoc """
  Non-streaming provider adapter contract. See spec §7.1.

  Implementations take an `ALLM.Request` plus a keyword opts list (resolved
  via `ALLM.Engine.resolve_params/2` and `ALLM.Engine.resolve_tools/2` at the
  call site) and return either `{:ok, %ALLM.Response{}}` or
  `{:error, %ALLM.Error.AdapterError{}}`.

  HTTP transport guidance: use `Req` for non-streaming calls. Streaming
  belongs in `ALLM.StreamAdapter`.
  """

  @callback generate(ALLM.Request.t(), keyword()) ::
              {:ok, ALLM.Response.t()} | {:error, ALLM.Error.AdapterError.t()}

  @callback prepare_request(ALLM.Request.t(), keyword()) ::
              {:ok, Req.Request.t()} | {:error, ALLM.Error.AdapterError.t()}

  @callback translate_options(keyword(), ALLM.Request.t()) :: keyword()

  @optional_callbacks prepare_request: 2, translate_options: 2
end
```

**Invariants:**

1. `generate/2` is synchronous: it returns only after the HTTP response has been read in full.
2. `generate/2` never raises for HTTP-shaped failures. A 4xx/5xx response is converted to `{:error, %AdapterError{status: status, reason: <atom>}}`. Network failures (ECONNREFUSED, DNS, TLS) are converted to `{:error, %AdapterError{reason: :network_error}}`. Only programmer errors (invalid request shape reaching the adapter, which the validator should have caught) may raise.
3. `generate/2` must honor `opts[:request_timeout]` if provided (propagates to the `Req` call). Exceeding the timeout produces `{:error, %AdapterError{reason: :timeout}}`.
4. `prepare_request/2` (optional) returns an unfired `Req.Request` configured exactly as `generate/2` would fire it. Callers may mutate the returned request before firing.
5. `translate_options/2` (optional) takes the resolved opts keyword and the request, and returns a possibly-renamed keyword; providers use it to rename `:max_tokens` → `:max_completion_tokens`, etc. The default (when unimplemented) is identity — the caller uses `function_exported?(adapter, :translate_options, 2)` to decide whether to shim.

**Error reason table (`generate/2`):**

| Reason | HTTP status | Fires when |
|--------|-------------|------------|
| `:authentication_failed` | 401 | API key missing / invalid. |
| `:rate_limited` | 429 | Provider quota exceeded; `:retry_after_ms` populated when `Retry-After` header is present. |
| `:invalid_request` | 400 | Request shape rejected by provider (unsupported param, schema violation). |
| `:content_filter` | 400 (provider-specific) | Provider's content filter rejected the prompt/response. |
| `:context_length_exceeded` | 400 | Request exceeded the model's context window. |
| `:provider_unavailable` | 500, 502, 503, 504, 529 | Provider server-side failure, retryable. |
| `:timeout` | — | Request exceeded `opts[:request_timeout]`. |
| `:network_error` | — | TCP/TLS/DNS failure. |
| `:malformed_response` | — | Provider returned a 200 with an unparseable body. |
| `:unsupported_feature` | — | Request combined features the adapter cannot express (e.g., OpenAI `tools` + `response_format` without `structured_finalize`). |
| `:unknown` | any | Catch-all for shapes the adapter can't classify; callers should treat as non-retryable. |

**Idiomatic Elixir requirements:**

- `@callback` lines reference `t:ALLM.Error.AdapterError.t/0` — the type must be published by `ALLM.Error.AdapterError` (already true per Phase 1).
- `@optional_callbacks prepare_request: 2, translate_options: 2` — exactly those two, unchanged from today.
- `@moduledoc` quotes the §7.1 narrative verbatim (the "HTTP transport guidance" paragraph) so the contract is self-contained when viewed in `iex> h ALLM.Adapter`.

### `ALLM.StreamAdapter` (Layer B — behaviour)

```elixir
defmodule ALLM.StreamAdapter do
  @moduledoc """
  Streaming provider adapter contract. See spec §7.2.

  `stream/2` returns an `Enumerable.t()` of `ALLM.Event` values. The enumerable
  is lazy — no HTTP call fires until the caller starts reducing over it —
  and must be resource-safe: if the consumer halts early (`Stream.take/2`),
  the underlying HTTP request must be cancelled. Use `Finch` directly with
  HTTP/1; `Req`'s SSE path does not cover every provider's chunking quirks
  and HTTP/2 flow control breaks for request bodies >64KB.
  """

  @callback stream(ALLM.Request.t(), keyword()) ::
              {:ok, Enumerable.t()} | {:error, ALLM.Error.AdapterError.t()}
end
```

**Invariants:**

1. The synchronous `{:error, _}` branch returns `%AdapterError{}` for pre-flight failures (missing key, invalid request shape, immediate HTTP error like 401 before the first event).
2. The stream itself may terminate with either `{:error, %AdapterError{}}` (HTTP-shaped failure mid-response — the provider returned a 4xx/5xx after streaming started) or `{:error, %ALLM.Error.StreamError{}}` (transport-shaped failure — truncated SSE, malformed chunk, connection drop). The distinction is declared in the conformance suite. Both event types are emitted as an `ALLM.Event` variant `{:error, _}` per spec §8.
3. The stream must be halt-safe: consumer halt within 500ms must cancel the `Finch` ref. Enforced by a conformance-suite test that drops the stream after N events and asserts no leaked process.
4. `opts[:stream_timeout]` (time between consecutive events) is honored by the adapter; exceeding it emits a terminating `{:error, %AdapterError{reason: :timeout}}` event.

**Error reason table (`stream/2` synchronous error):** same as `ALLM.Adapter.generate/2` above.

**Error reason table (mid-stream `{:error, _}` event):**

| Struct type | Reason | Fires when |
|-------------|--------|------------|
| `AdapterError` | `:rate_limited` | Provider returned 429 after SSE began. |
| `AdapterError` | `:provider_unavailable` | Provider returned 5xx after SSE began. |
| `AdapterError` | `:content_filter` | Provider interrupted the stream with a content-filter signal. |
| `AdapterError` | `:timeout` | `opts[:stream_timeout]` elapsed between events. |
| `StreamError` | `:truncated` | The response body closed before a terminal chunk was seen. |
| `StreamError` | `:malformed_chunk` | An SSE line could not be parsed. |
| `StreamError` | `:connection_dropped` | The underlying `Finch` connection dropped mid-stream. |

**Idiomatic Elixir requirements:**

- Implementations should use `Stream.resource/3` (not `Stream.unfold/2`) — `resource/3` has an explicit `after_fun` which is the canonical place to cancel the `Finch` ref.
- The conformance suite's halt-safety case reduces the stream with `Stream.take/2` and asserts that the `after_fun` ran (observable via a `Process.put/2` side-channel in the test fixture's `StubAdapter`).

### `ALLM.ToolExecutor` (Layer B — behaviour)

```elixir
defmodule ALLM.ToolExecutor do
  @moduledoc """
  Tool-handler invocation contract. See spec §7.3 and §5.2.

  `execute/3` takes a `%ALLM.Tool{}`, the parsed arguments map, and a keyword
  opts list carrying call context (`:context`, `:session_id`, `:request_id`,
  `:tool_call`, `:engine`). It invokes the tool's handler and returns the
  handler's return value unchanged — with two exceptions that belong to the
  executor, not the handler:

  1. A handler raise / exit / bad return is converted to
     `{:error, %ALLM.Error.ToolError{}}` with a `:reason` atom drawn from the
     closed set `:handler_raised | :handler_exit | :timeout | :invalid_return |
     :encoding_failed | :not_found`.

  2. A `nil` handler (the `%Tool{}` was declared for manual-mode use) is
     converted to `{:error, %ALLM.Error.ToolError{reason: :not_found}}` —
     the executor cannot invoke a tool with no handler.

  Handler-returned `{:error, _}` values are NOT converted; they pass through
  unchanged so the orchestrator can pattern-match on them (`on_tool_error`
  policy, spec §12.3 / §30).
  """

  @callback execute(ALLM.Tool.t(), arguments :: map(), opts :: keyword()) ::
              ALLM.Tool.handler_result()
end
```

**Invariants:**

1. `execute/3` receives a `%Tool{}` whose `name` was looked up by the caller; executors do not consult a registry.
2. `execute/3` returns one of the five `t:ALLM.Tool.handler_result/0` variants unchanged for handler-returned values; executor-originated failures are `{:error, %ToolError{}}` structs.
3. `opts` is populated by the caller; executors do not synthesize `:session_id` / `:request_id` / etc. Missing keys read as `nil` when the executor forwards them to an arity-2 handler.
4. Handler arity dispatch: `:erlang.fun_info(handler, :arity)` — `1` calls `handler.(arguments)`; `2` calls `handler.(arguments, opts)`. Any other arity is an invalid handler and raises `ArgumentError` from the executor (never reached in practice because `ALLM.Tool.new/1` only accepts arity-1 or arity-2 funs, but defensive for the non-struct path).

**Error reason table (`execute/3` executor-originated errors):**

| Reason | Fires when |
|--------|------------|
| `:handler_raised` | Handler raised; `:cause` carries the `%RuntimeError{}` (or other exception struct). |
| `:handler_exit` | Handler `exit/1`-ed or the process died; `:cause` carries the exit reason term. |
| `:timeout` | Emitted by Phase 6's `ALLM.ToolRunner` under `tool_timeout`. Phase 3's default executor does not produce this directly — conformance tests that need it use a handler that returns the struct. |
| `:invalid_return` | Handler returned a value that is not one of the five `handler_result()` variants. |
| `:not_found` | `%Tool{handler: nil}` — the tool is not executable. |
| `:encoding_failed` | Reserved for encoders; executors do not produce this reason. |

**Idiomatic Elixir requirements:**

- Handler invocation is wrapped in `try/rescue/catch` so raises, exits, **and throws** are all captured. The correct form is:

  ```elixir
  try do
    invoke_handler(tool.handler, arguments, opts)
  rescue
    e -> {:error, ToolError.new(:handler_raised, cause: e, tool_name: tool.name)}
  catch
    :exit, reason ->
      {:error, ToolError.new(:handler_exit, cause: reason, tool_name: tool.name)}
    :throw, value ->
      {:error, ToolError.new(:handler_raised, cause: {:throw, value}, tool_name: tool.name)}
  end
  ```

  A single-clause `catch reason -> ...` (kind-less) catches both `:throw` and `:exit` but **not** `:error` (which `rescue` handles) — it does not allow distinguishing throws from exits, so the two-clause form is preferred for the different `ToolError.reason` mappings.
- `:erlang.fun_info(handler, :arity)` is preferred over `Function.info(handler, :arity)` to avoid the struct wrap (micro-optimization but idiomatic in hot paths).
- The executor is **synchronous**; it does not spawn a `Task`. Parallel execution and timeout enforcement are the orchestrator's responsibility (Phase 6).

### `ALLM.ToolResultEncoder` (Layer B — behaviour)

```elixir
defmodule ALLM.ToolResultEncoder do
  @moduledoc """
  Serialize a tool's return value into a string the model can consume. See
  spec §7.4 and §18.

  The encoder is called with the raw value from `ALLM.ToolExecutor.execute/3`
  (after the orchestrator has pattern-matched any `{:ok, _}` / `{:error, _}`
  wrapper — see `ALLM.ToolResultEncoder.JSON` for the default's exact
  unwrapping rules).
  """

  @callback encode(term()) :: String.t()
end
```

**Invariants:**

1. `encode/1` is total over the types the encoder documents in its `@moduledoc`. A value outside the documented shapes may raise — the caller guards with `try/rescue`.
2. `encode/1` is pure: no IO, no state, no side effects. Conformance suite asserts determinism (same input, same output, byte-for-byte).
3. `encode/1` never emits a bare Elixir term (tuple, pid, ref) in its output — the return is always a `String.t()`.

**Idiomatic Elixir requirements:**

- No `@optional_callbacks` — `encode/1` is the only callback and it's required.

### `ALLM.ToolExecutor.Default` (Layer B — default implementation)

```elixir
defmodule ALLM.ToolExecutor.Default do
  @moduledoc """
  Default `ALLM.ToolExecutor` — invokes the tool's `:handler` function
  directly, dispatching on arity (1 or 2). Converts raises / exits /
  invalid returns to `%ALLM.Error.ToolError{}`; passes handler-returned
  values (ok, error, ask_user, halt) through unchanged.

  Used when `engine.tool_executor` is `nil` — the call site resolves to this
  module via `engine.tool_executor || ALLM.ToolExecutor.Default`.
  """

  @behaviour ALLM.ToolExecutor

  @impl true
  @spec execute(ALLM.Tool.t(), map(), keyword()) :: ALLM.Tool.handler_result()
  def execute(tool, arguments, opts)
end
```

### `ALLM.ToolResultEncoder.JSON` (Layer B — default implementation)

```elixir
defmodule ALLM.ToolResultEncoder.JSON do
  @moduledoc """
  Default `ALLM.ToolResultEncoder` — JSON-encodes the tool return value via
  `Jason.encode!/1`, with two passthrough shortcuts:

  * Binaries pass through unchanged (the handler already produced a string
    for the model).
  * `{:ok, inner}` maps to `Jason.encode!(%{ok: inner})`.
  * `{:error, reason}` maps to `Jason.encode!(%{error: inspect(reason)})`.

  All other values go through `Jason.encode!/1` directly. A value Jason
  cannot encode (e.g., a PID, a fun) raises `Protocol.UndefinedError`; the
  orchestrator wraps the call in `try/rescue` and surfaces
  `%ALLM.Error.ToolError{reason: :encoding_failed}` to the model.

  Used when `engine.tool_result_encoder` is `nil`.
  """

  @behaviour ALLM.ToolResultEncoder

  @impl true
  @spec encode(term()) :: String.t()
  def encode(value)
end
```

**Input-shape → output-shape table:**

| Input | Output |
|-------|--------|
| `"already a string"` | `"already a string"` (unchanged) |
| `%{a: 1}` | `~s({"a":1})` |
| `[1, 2, 3]` | `"[1,2,3]"` |
| `{:ok, %{a: 1}}` | `~s({"ok":{"a":1}})` |
| `{:error, :not_found}` | `~s({"error":":not_found"})` |
| `{:error, %RuntimeError{}}` | `~s({"error":"%RuntimeError{...}"})` |
| `nil` | `"null"` |
| `42` | `"42"` |
| `true` | `"true"` |

### Conformance harness modules (Layer B — test-support)

```elixir
defmodule ALLM.Test.AdapterConformance do
  @moduledoc """
  Injectable conformance suite for `ALLM.Adapter` implementations. Use:

      defmodule MyAdapterTest do
        use ExUnit.Case, async: true
        use ALLM.Test.AdapterConformance, adapter: MyAdapter
      end

  Injects a `describe "ALLM.Adapter conformance"` block with ~40 cases
  covering every documented error reason and every spec §5 request shape.

  **Installation for library consumers:** ALLM ships this module in the
  Hex package under `test/support/`. Consumers add `"deps/allm/test/support"`
  to their `elixirc_paths` for the `:test` environment:

      defp elixirc_paths(:test), do: ["lib", "test/support", "deps/allm/test/support"]
      defp elixirc_paths(_),     do: ["lib"]
  """

  use ExUnit.CaseTemplate

  using opts do
    quote do
      # Namespaced attribute — avoids collisions with the caller's own
      # module attributes and makes the provenance obvious when a test
      # fails. The `:adapter` opt must be a module literal at the `use`
      # site; passing a variable (`use ALLM.Test.AdapterConformance,
      # @conformance_opts`) is unsupported and raises
      # `CompileError` because `Keyword.fetch!/2` evaluates at the
      # quoted-expansion site.
      @__allm_conformance_adapter__ Keyword.fetch!(unquote(opts), :adapter)

      describe "ALLM.Adapter conformance (\#{inspect(@__allm_conformance_adapter__)})" do
        test "generate/2 with a minimal text request returns {:ok, %Response{}}", _context do
          # ...
        end

        # ... ~12 more cases, grouped by reason atom.
      end
    end
  end
end
```

The three peer modules (`ALLM.Test.StreamAdapterConformance`, `ALLM.Test.ToolExecutorConformance`, `ALLM.Test.ToolResultEncoderConformance`) follow the same shape, each using its own namespaced attribute (`@__allm_conformance_stream_adapter__`, `@__allm_conformance_executor__`, `@__allm_conformance_encoder__`). The injected cases are listed per-module in the phase Test Plans below.

**`async:` default.** Each conformance template declares `use ExUnit.CaseTemplate` without forcing `async:` — the caller's `use ExUnit.Case, async: true | false` wins. Conformance cases must therefore be safe under both. Tests that observe cleanup side-effects use the `:counters` ref mechanism described under "StubAdapter script shape" below, not `Process.put/2` (which is process-local and invisible across async boundaries).

### `ALLM.Test.Fixtures.StubAdapter` script shape (Layer B — test-support contract)

The stub's scripted input contract is explicit so conformance tests don't have to reverse-engineer it. A script is a keyword-list field on `adapter_opts`:

```elixir
adapter_opts: [
  # Non-streaming: one entry per call. `:ok` → happy path; `:error` → error.
  script: [
    {:ok, %{text: "hi", usage: %{prompt_tokens: 1, completion_tokens: 1}}},
    {:error, :rate_limited, retry_after_ms: 500, request_id: "req_1"},
    {:error, :authentication_failed, status: 401}
  ],

  # Streaming: one inner list per call, one event spec per list entry.
  stream_script: [
    [
      {:text_delta, "hel"},
      {:text_delta, "lo"},
      {:finish, :stop}
    ],
    [
      {:error_event, :rate_limited, retry_after_ms: 500}
    ],
    [
      {:stream_error, :truncated}
    ]
  ],

  # Observation channel for halt-safety: caller supplies a `:counters` ref
  # (atomic, cross-process-safe); the stub's Stream.resource/3 after_fun
  # increments index 1 on cleanup. Tests assert :counters.get(ref, 1) == 1.
  cleanup_observer: :counters.new(1, [:atomics])
]
```

**Error-event contract:**

- `{:error, reason_atom, keyword()}` — synchronous `generate/2` / `stream/2` error. Maps 1:1 to `%AdapterError{reason: reason_atom, ...opts}`.
- `{:error_event, reason_atom, keyword()}` — mid-stream `{:error, %AdapterError{...}}` event (HTTP-shaped mid-stream failure).
- `{:stream_error, reason_atom, keyword()}` — mid-stream `{:error, %StreamError{...}}` event (transport-shaped).

**Happy-path event contract:**

- `{:text_delta, String.t()}` → `{:text_delta, %{id: nil, delta: _}}`
- `{:tool_call, keyword()}` → `{:tool_call_started, _} + {:tool_call_completed, _}` pair (the stub emits both so downstream tests see the full lifecycle)
- `{:usage, map()}` → `{:usage, _}` (not in spec §8's core union — deferred to Phase 5 when `ALLM.StreamCollector` lands; Phase 3 stub omits `:usage`)
- `{:finish, atom()}` → `{:message_completed, _} + {:step_completed, _}`

**Cleanup observation.** The halt-safety test does:

```elixir
ref = :counters.new(1, [:atomics])
adapter = fresh_stub(stream_script: [...], cleanup_observer: ref)
adapter |> StreamAdapter.stream(req, []) |> elem(1) |> Enum.take(2)
# after_fun increments ref[1]
assert eventually(fn -> :counters.get(ref, 1) == 1 end, 500)
```

`:counters` is shared-memory and survives the `async: true` process boundary — `Process.put/2` does not. `eventually/2` is a tiny test helper (poll with 10ms interval up to `timeout` ms).

## Module Tree

```
lib/allm/
├── adapter.ex                          (MODIFY — expand @moduledoc, add @doc per callback, tighten error shape)
├── stream_adapter.ex                   (MODIFY — same)
├── tool_executor.ex                    (MODIFY — same, add executor-error reason table in @moduledoc)
├── tool_result_encoder.ex              (MODIFY — same)
├── tool_executor/
│   └── default.ex                      (NEW — ALLM.ToolExecutor.Default)
└── tool_result_encoder/
    └── json.ex                         (NEW — ALLM.ToolResultEncoder.JSON)

test/allm/
├── adapter_test.exs                    (NEW — contract test, asserts @callback arities + @optional_callbacks)
├── stream_adapter_test.exs             (NEW)
├── tool_executor_test.exs              (NEW)
├── tool_result_encoder_test.exs        (NEW)
├── tool_executor/
│   └── default_test.exs                (NEW — unit tests + doctests + conformance plug-in)
└── tool_result_encoder/
    └── json_test.exs                   (NEW — unit tests + doctests + conformance plug-in)

test/support/
└── doc_assertions.ex                   (NEW — ALLM.Test.DocAssertions; Code.fetch_docs/1 shape helpers — main-project only)

mix.exs                                 (MODIFY — add {:allm_conformance, path: "conformance", only: :test} to deps)
CHANGELOG.md                            (MODIFY — one line per public-API change, including the sibling package release)

conformance/                            (NEW — sibling Hex package sub-project)
├── mix.exs                             (NEW — app: :allm_conformance, deps: {:allm, ...})
├── README.md                           (NEW — install + usage for consumers)
├── CHANGELOG.md                        (NEW)
├── lib/
│   └── allm/
│       └── test/
│           ├── adapter_conformance.ex           (NEW — ALLM.Test.AdapterConformance)
│           ├── stream_adapter_conformance.ex    (NEW — ALLM.Test.StreamAdapterConformance)
│           ├── tool_executor_conformance.ex     (NEW — ALLM.Test.ToolExecutorConformance)
│           └── tool_result_encoder_conformance.ex (NEW — ALLM.Test.ToolResultEncoderConformance)
├── test/
│   ├── allm/
│   │   └── test/
│   │       ├── adapter_conformance_test.exs           (NEW — self-test against StubAdapter)
│   │       ├── stream_adapter_conformance_test.exs    (NEW)
│   │       ├── tool_executor_conformance_test.exs     (NEW — self-test against a local stub executor)
│   │       └── tool_result_encoder_conformance_test.exs (NEW — self-test against a local stub encoder)
│   ├── test_helper.exs                 (NEW)
│   └── support/
│       └── fixtures/
│           └── stub_adapter.ex         (NEW — ALLM.Test.Fixtures.StubAdapter, permanent, test-only)
└── .formatter.exs                      (NEW)
```

Main-project test files mirror main-project source files 1:1. The conformance sub-project's test tree mirrors its own `lib/` 1:1. The main `allm` package certifies its two defaults against `allm_conformance` via the path dep; the sub-project self-certifies its harness against `StubAdapter` and minimal stub executors/encoders defined inline in its test files (they don't need to be exported — they are strictly for harness self-verification).

## Phases

### Sub-phase 3.1: `ALLM.Adapter` + `ALLM.StreamAdapter` contract hardening (Layer B)

**Goal:** Expand the two adapter behaviours from bare `@callback` lists into full contracts: rich `@moduledoc`, `@doc` on every callback with an error-reason table, tightened return types referencing `%ALLM.Error.AdapterError{}` instead of `term()`.

**Spec sections:** §7.1, §7.2, §20

#### 3.1.1 Test Plan (write first)

`test/allm/adapter_test.exs` (NEW):

- `@callback generate/2 is declared on ALLM.Adapter` (asserts `{:generate, 2} in ALLM.Adapter.behaviour_info(:callbacks)`).
- `@callback prepare_request/2 is declared and is in @optional_callbacks`.
- `@callback translate_options/2 is declared and is in @optional_callbacks`.
- `@optional_callbacks lists exactly [prepare_request: 2, translate_options: 2]` (set equality, order-insensitive).
- `@moduledoc is present and non-`:none`` (asserts `Code.fetch_docs(ALLM.Adapter)`'s module-doc position is a `String.t()` or a locale-keyed map — not `:none` / `:hidden`). No length threshold; the assertion is a shape assertion, not a length assertion.
- `@doc is present on every callback` (iterates `Code.fetch_docs/1`'s `:docs` list, filtering to `{{:callback, name, arity}, _, _, doc, _}` tuples and asserting `doc != :none and doc != :hidden`). No substring content matching — those assertions belong in doctests, not in behaviour-contract tests.

`test/allm/stream_adapter_test.exs` (NEW):

- `@callback stream/2 is declared on ALLM.StreamAdapter`.
- `no optional callbacks (@optional_callbacks is empty or absent — verify via `Keyword.get(ALLM.StreamAdapter.__info__(:attributes), :optional_callbacks, []) == []`)`.
- `@moduledoc is present and non-`:none``.
- `@doc on stream/2 is present and non-`:none``.

**Elixir-version compatibility note.** `Code.fetch_docs/1` returns a 7-element tuple `{:docs_v1, _anno, :elixir, _format, module_doc, _metadata, docs}`. The `module_doc` and per-function docs can be `:none`, `:hidden`, a `String.t()`, or a locale-keyed map (`%{"en" => "..."}`) depending on the compiler path. The test helper uses a single pattern-match helper `doc_present?/1` that accepts all of `String.t()`, non-empty map, and rejects `:none`/`:hidden` — shipped in `test/support/doc_assertions.ex` as part of Sub-phase 3.1. CLAUDE.md declares `elixir ~> 1.17`; the helper is tested against 1.17 and 1.18.

#### 3.1.2 Implementation Checklist

- [ ] Create `test/support/doc_assertions.ex` — `ALLM.Test.DocAssertions` with a `doc_present?/1` helper that pattern-matches `Code.fetch_docs/1`'s `:none | :hidden | String.t() | %{optional(String.t()) => String.t()}` shape. Used by every `test/allm/*_test.exs` contract test in 3.1 and 3.2.
- [ ] Expand `lib/allm/adapter.ex` `@moduledoc` with the §7.1 narrative (transport guidance, prepare_request escape hatch, translate_options default-identity semantics).
- [ ] Add `@doc` above each `@callback` including the error-reason table for `generate/2`.
- [ ] Tighten `@callback generate/2` return type to `{:ok, ALLM.Response.t()} | {:error, ALLM.Error.AdapterError.t()}`.
- [ ] Tighten `@callback prepare_request/2` error branch to `{:error, ALLM.Error.AdapterError.t()}`.
- [ ] Leave `@callback translate_options/2` unchanged (return is `keyword()`).
- [ ] Expand `lib/allm/stream_adapter.ex` `@moduledoc` with the §7.2 narrative (verbatim HTTP transport guidance + mid-stream-error contract).
- [ ] Add `@doc` above `@callback stream/2` including both error-reason tables.
- [ ] Tighten `@callback stream/2` error branch to `{:error, ALLM.Error.AdapterError.t()}`.
- [ ] Verify `mix format --check-formatted` and `mix credo --strict` on both files.

#### 3.1.3 Verification

```bash
mix test test/allm/adapter_test.exs
mix test test/allm/stream_adapter_test.exs
mix dialyzer          # tightened types must not introduce new warnings
mix credo --strict lib/allm/adapter.ex lib/allm/stream_adapter.ex
mix format --check-formatted
```

### Sub-phase 3.2: `ALLM.ToolExecutor` + `ALLM.ToolResultEncoder` contract hardening (Layer B)

**Goal:** Same shape as 3.1, applied to the other two behaviours. Document the handler-originated-vs-executor-originated error distinction (Non-obvious Decision #3).

**Spec sections:** §7.3, §7.4, §5.2, §20

#### 3.2.1 Test Plan (write first)

`test/allm/tool_executor_test.exs` (NEW):

- `@callback execute/3 is declared on ALLM.ToolExecutor` (via `behaviour_info(:callbacks)` set membership).
- `no optional callbacks` (`Keyword.get(__info__(:attributes), :optional_callbacks, []) == []`).
- `@moduledoc is present and non-`:none`` (shape assertion only — content is the design doc's responsibility, not the test's).
- `@doc on execute/3 is present and non-`:none``.

`test/allm/tool_result_encoder_test.exs` (NEW):

- `@callback encode/1 is declared on ALLM.ToolResultEncoder`.
- `no optional callbacks`.
- `@moduledoc is present and non-`:none``.
- `@doc on encode/1 is present and non-`:none``.

#### 3.2.2 Implementation Checklist

- [ ] Expand `lib/allm/tool_executor.ex` `@moduledoc` per the Behaviour & Type Contracts section above.
- [ ] Add `@doc` above `@callback execute/3` including the executor-error reason table.
- [ ] Leave the callback signature `(ALLM.Tool.t(), map(), keyword()) :: ALLM.Tool.handler_result()` (handler_result already includes the error-struct-narrowed variant via Phase 1's types).
- [ ] Expand `lib/allm/tool_result_encoder.ex` `@moduledoc` per the contract.
- [ ] Add `@doc` above `@callback encode/1`.

#### 3.2.3 Verification

```bash
mix test test/allm/tool_executor_test.exs
mix test test/allm/tool_result_encoder_test.exs
mix dialyzer
mix credo --strict lib/allm/tool_executor.ex lib/allm/tool_result_encoder.ex
mix format --check-formatted
```

### Sub-phase 3.3: `ALLM.ToolExecutor.Default` implementation (Layer B)

**Goal:** Ship the default executor — the only tool executor in v0.2. Dispatches arity-1 / arity-2 handlers, rescues raises/exits, validates return shape against `t:ALLM.Tool.handler_result/0`.

**Spec sections:** §7.3, §18, §5.2

#### 3.3.1 Test Plan (write first)

`test/allm/tool_executor/default_test.exs` (NEW):

Happy-path (arity-1 handlers):
- `arity-1 handler returning {:ok, value} passes {:ok, value} through unchanged`
- `arity-1 handler returning {:error, :user_not_found} passes {:error, :user_not_found} through unchanged (handler-originated error — NOT converted to ToolError)`
- `arity-1 handler returning {:ask_user, "question"} passes through unchanged`
- `arity-1 handler returning {:ask_user, "question", opts} passes through unchanged`
- `arity-1 handler returning {:halt, :plan_submitted, result} passes through unchanged`

Happy-path (arity-2 handlers):
- `arity-2 handler receives arguments and opts; opts includes :context, :session_id, :request_id, :tool_call, :engine keys from the caller's opts`
- `arity-2 handler's returned {:ok, value} passes through unchanged`

Executor-originated errors (verified in IEx on 2026-04-21 — `raise RuntimeError` yields `%RuntimeError{}`, `exit/1` surfaces to `catch :exit, _` with the raw exit term, `throw/1` surfaces to `catch :throw, _` with the thrown value):
- `handler that raises RuntimeError returns {:error, %ToolError{reason: :handler_raised, cause: %RuntimeError{}}}`
- `handler that raises ArgumentError returns {:error, %ToolError{reason: :handler_raised, cause: %ArgumentError{}}}`
- `handler that exit()s returns {:error, %ToolError{reason: :handler_exit, cause: _exit_term}}`
- `handler that throws a tagged tuple returns {:error, %ToolError{reason: :handler_raised, cause: {:throw, _thrown_value}}}` (caught by the `catch :throw, value` clause, wrapped so the cause distinguishes throws from raises)
- `handler returning :bare_atom (not one of the five legal shapes) returns {:error, %ToolError{reason: :invalid_return, cause: :bare_atom}}`
- `handler returning %{foo: :bar} (bare map, not a legal handler_result) returns {:error, %ToolError{reason: :invalid_return}}`
- `%Tool{handler: nil} returns {:error, %ToolError{reason: :not_found}}`

Invalid-handler arity / shape (Non-obvious Decision #5):
- `handler with arity 3 (constructed by bypassing Tool.new/1 and building %Tool{} directly) causes execute/3 to raise ArgumentError` — the executor only dispatches arity 1 or 2.
- `handler that is an {Module, :function} MFA tuple (also bypassing Tool.new/1) causes execute/3 to raise FunctionClauseError` — MFA handler support is a v0.3 enhancement (Non-obvious Decision #5).

Doctest:
- `ALLM.ToolExecutor.Default.execute/3` carries a runnable doctest: construct a `%Tool{handler: fn args -> {:ok, args} end}`, invoke, assert the return.

Conformance plug-in:
- `test/allm/tool_executor/default_test.exs` includes `use ALLM.Test.ToolExecutorConformance, executor: ALLM.ToolExecutor.Default` as its last line. The harness is not yet shipped at this sub-phase — the plug-in line is added in 3.5 as part of wiring up the full harness. Flag: `# added in 3.5`.

#### 3.3.2 Implementation Checklist

- [ ] Create `lib/allm/tool_executor/default.ex` with the `@moduledoc` from the contract section.
- [ ] Implement `execute/3`:
  - Pattern-match `%Tool{handler: nil}` → `{:error, %ToolError{reason: :not_found, tool_name: name}}`.
  - Dispatch arity via `:erlang.fun_info(handler, :arity)` — `1` calls `handler.(arguments)`, `2` calls `handler.(arguments, opts)`.
  - Wrap the call in `try do ... rescue e -> ... catch :exit, reason -> ... end`.
  - Validate the return shape against `t:handler_result/0` — pattern-match on the five legal shapes; any other value returns `{:error, %ToolError{reason: :invalid_return, cause: value}}`.
  - For raises, build `%ToolError{reason: :handler_raised, tool_name: tool.name, cause: exception}`.
  - For exits, build `%ToolError{reason: :handler_exit, tool_name: tool.name, cause: exit_reason}`.
- [ ] Doctest `execute/3`.
- [ ] `@spec execute(Tool.t(), map(), keyword()) :: Tool.handler_result()`.
- [ ] `@impl true` on the callback implementation.

#### 3.3.3 Verification

```bash
mix test test/allm/tool_executor/default_test.exs
mix test --cover                         # assert ≥90% coverage on lib/allm/tool_executor/default.ex
mix dialyzer
mix credo --strict lib/allm/tool_executor/default.ex
```

### Sub-phase 3.4: `ALLM.ToolResultEncoder.JSON` implementation (Layer B)

**Goal:** Ship the default encoder. Passes binaries through unchanged; Jason-encodes everything else; provides documented unwrapping for `{:ok, _}` and `{:error, _}`.

**Spec sections:** §7.4, §18

#### 3.4.1 Test Plan (write first)

`test/allm/tool_result_encoder/json_test.exs` (NEW):

Passthrough:
- `encode("already a string") == "already a string"` (no double-encoding)
- `encode("") == ""` (empty string passes through unchanged)

Jason encoding:
- `encode(%{a: 1, b: 2}) |> Jason.decode! == %{"a" => 1, "b" => 2}` (round-trip)
- `encode([1, 2, 3]) == "[1,2,3]"`
- `encode(nil) == "null"`
- `encode(42) == "42"`
- `encode(true) == "true"`
- `encode(false) == "false"`

Tuple unwrapping:
- `encode({:ok, %{a: 1}}) |> Jason.decode! == %{"ok" => %{"a" => 1}}`
- `encode({:ok, "inner"}) |> Jason.decode! == %{"ok" => "inner"}`
- `encode({:error, :not_found}) |> Jason.decode! == %{"error" => ":not_found"}`
- `encode({:error, %RuntimeError{message: "boom"}}) |> Jason.decode! == %{"error" => "%RuntimeError{message: \"boom\"}"}`

Raises (verified in IEx on 2026-04-21 — `Jason.encode!/1` dispatches through the `Jason.Encoder` protocol and a missing impl raises `Protocol.UndefinedError`, not `Jason.EncodeError`):
- `encode(self())` raises `Protocol.UndefinedError` (documented: the orchestrator wraps this in `try/rescue`).
- `encode({1, 2, 3})` raises `Protocol.UndefinedError` (bare tuples have no `Jason.Encoder` impl).
- `encode({:ok, {1, 2, 3}})` raises `Protocol.UndefinedError` — the `{:ok, inner}` head unwraps to `Jason.encode!(%{ok: {1, 2, 3}})`, and the inner tuple is still unencodable. The conformance suite covers this to prevent a future implementer from "being clever" about nested tuples.

Doctest:
- `ALLM.ToolResultEncoder.JSON.encode/1` carries a runnable doctest covering the three main shapes.

Conformance plug-in:
- `use ALLM.Test.ToolResultEncoderConformance, encoder: ALLM.ToolResultEncoder.JSON` (added in 3.5).

#### 3.4.2 Implementation Checklist

- [ ] Create `lib/allm/tool_result_encoder/json.ex` with the `@moduledoc` + input-shape table.
- [ ] Implement `encode/1`:
  - `encode(value) when is_binary(value), do: value`
  - `encode({:ok, inner}), do: Jason.encode!(%{ok: inner})`
  - `encode({:error, reason}) when is_binary(reason), do: Jason.encode!(%{error: reason})`
  - `encode({:error, reason}), do: Jason.encode!(%{error: inspect(reason)})`
  - `encode(value), do: Jason.encode!(value)`
- [ ] Doctest `encode/1`.
- [ ] `@spec encode(term()) :: String.t()`.
- [ ] `@impl true`.

#### 3.4.3 Verification

```bash
mix test test/allm/tool_result_encoder/json_test.exs
mix test --cover                         # ≥90% on lib/allm/tool_result_encoder/json.ex
mix dialyzer
mix credo --strict lib/allm/tool_result_encoder/json.ex
```

### Sub-phase 3.5: `allm_conformance` sibling package + harness wiring (Layer B — published)

**Goal:** Ship the four `ALLM.Test.*Conformance` modules as the public API of a new sibling Hex package `allm_conformance`, developed in an in-repo sub-project at `conformance/`. Wire the main `allm` project's two default-impl test files into the harness via a path-dep on the sub-project. Prove end-to-end that the harness certifies both (a) a scripted stub (the harness's own self-test) and (b) the Phase 3 defaults in the main project.

**Spec sections:** §7, §31

#### 3.5.1 Test Plan (write first)

`conformance/test/allm/test/adapter_conformance_test.exs` (NEW — self-test of the harness, runs from the sub-project):

- `the harness declares exactly N cases (N = known-at-landing count, e.g. 12)` — asserts the injected `test/2` count is stable so future additions are explicit.
- `running the harness against ALLM.Test.Fixtures.StubAdapter passes` — exercises the shipped harness against a deliberately-minimal implementation.
- `the harness macro raises CompileError when :adapter opt is missing` — `use ALLM.Test.AdapterConformance` without an `:adapter` must not compile.

`conformance/test/allm/test/stream_adapter_conformance_test.exs` (NEW — same shape for StreamAdapter; exercises the stub's `stream/2` + `Stream.resource/3` cleanup path).

`conformance/test/allm/test/tool_executor_conformance_test.exs` (NEW):

- `running the harness against a local stub executor passes` — self-test. The stub executor is a ~10-line module defined inline in the test file, **not** exported from the sub-project's `lib/`, because the real Phase 3 default (`ALLM.ToolExecutor.Default`) lives in the main `allm` package and is certified from there.

`conformance/test/allm/test/tool_result_encoder_conformance_test.exs` (NEW):

- `running the harness against a local stub encoder passes`. Same rationale — the real default (`ALLM.ToolResultEncoder.JSON`) is in the main package.

**Main-project integration (in the main `allm` project's test tree, via the path dep):**

- `test/allm/tool_executor/default_test.exs` (from Sub-phase 3.3) adds at the bottom: `use ALLM.Test.ToolExecutorConformance, executor: ALLM.ToolExecutor.Default`. Runs under `mix test` in the main project because `{:allm_conformance, path: "conformance", only: :test}` makes the harness available in `:test`.
- `test/allm/tool_result_encoder/json_test.exs` (from Sub-phase 3.4) adds: `use ALLM.Test.ToolResultEncoderConformance, encoder: ALLM.ToolResultEncoder.JSON`.

**Injected case lists** (shipped in each conformance module's `using/1` block):

`ALLM.Test.AdapterConformance` injected cases (against `%StubAdapter{}` or user module):
- generates a response for a minimal text request
- returns `%AdapterError{reason: :authentication_failed}` when the stub is scripted to fail auth
- returns `%AdapterError{reason: :rate_limited}` with `retry_after_ms` populated when scripted
- returns `%AdapterError{reason: :timeout}` when the stub is scripted to exceed `request_timeout`
- returns `%AdapterError{reason: :network_error}` when the stub raises a `Finch.Error`-shape
- returns `%AdapterError{reason: :invalid_request}` when scripted with a 400
- returns `%AdapterError{reason: :context_length_exceeded}` when scripted
- returns `%AdapterError{reason: :content_filter}` when scripted
- returns `%AdapterError{reason: :provider_unavailable}` when scripted with a 503
- returns `%AdapterError{reason: :malformed_response}` when scripted with unparseable body
- passes `opts[:request_timeout]` through to the HTTP client (verified via the stub recording it)
- populates `%AdapterError.request_id` when the stub attaches one (observability contract)

`ALLM.Test.StreamAdapterConformance` injected cases:
- synchronous `{:error, %AdapterError{}}` for each spec §20 pre-flight error atom
- streams `[:message_started, :text_delta+, :text_completed, :message_completed, :step_completed]` for a plain text script
- streams a mid-stream `{:error, %AdapterError{reason: :rate_limited}}` event when scripted
- streams a mid-stream `{:error, %StreamError{reason: :truncated}}` event when scripted
- halt-safety: consumer `Stream.take(events, 2)` cancels the upstream within 500ms (observable via the stub's `Process.put`-based side channel)
- `opts[:stream_timeout]` honored: a scripted 10s gap emits `%AdapterError{reason: :timeout}` within the timeout budget

`ALLM.Test.ToolExecutorConformance` injected cases:
- handler `{:ok, _}` passes through
- handler `{:error, :biz}` passes through (handler-originated)
- handler `{:ask_user, _}` / `{:ask_user, _, _}` pass through
- handler `{:halt, _, _}` passes through
- handler raise → `{:error, %ToolError{reason: :handler_raised}}`
- handler exit → `{:error, %ToolError{reason: :handler_exit}}`
- handler throw → `{:error, %ToolError{reason: :handler_raised}}` (normalized)
- handler invalid return → `{:error, %ToolError{reason: :invalid_return}}`
- `%Tool{handler: nil}` → `{:error, %ToolError{reason: :not_found}}`
- arity-2 handler receives `opts` verbatim (includes `:context`, `:session_id`, `:request_id`, `:tool_call`, `:engine`)

`ALLM.Test.ToolResultEncoderConformance` injected cases:
- binary passthrough (non-empty and empty)
- map round-trips through `Jason.decode!/1`
- list round-trips
- `nil`, integer, float, boolean encode to their JSON scalar forms
- `{:ok, _}` unwrap produces `%{"ok" => _}` shape
- `{:error, atom}` unwrap produces `%{"error" => inspected_atom}` shape
- determinism: `encode(x) == encode(x)` byte-equal (no random ordering)

#### 3.5.2 Implementation Checklist

**Sub-project scaffold (`conformance/`):**

- [ ] Create `conformance/mix.exs` — `app: :allm_conformance`, `version: "0.2.0"`, `elixir: "~> 1.17"`, `deps: [{:allm, path: "..", only: [:dev, :test]}, {:ex_unit, ...}]` during development; rewrite to `{:allm, "~> 0.2"}` at Hex-publish time (use a `Mix.env()`-gated `deps/0` or a release-checklist rewrite). `package:` block declares `licenses: ["MIT"]`, `links:`, `files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md .formatter.exs)`.
- [ ] Create `conformance/README.md` — installation (one-line deps entry), quickstart, link back to the main `allm` README.
- [ ] Create `conformance/.formatter.exs`.
- [ ] Create `conformance/CHANGELOG.md` with an initial `0.2.0` entry listing the four conformance modules.
- [ ] Create `conformance/test/test_helper.exs` — one line: `ExUnit.start()`.

**Harness implementations (`conformance/lib/allm/test/*.ex`):**

- [ ] Create `conformance/lib/allm/test/adapter_conformance.ex` — `ALLM.Test.AdapterConformance` as an `ExUnit.CaseTemplate` with `using opts do ... end` that injects the 12 cases enumerated in 3.5.1. Each injected case reads `@__allm_conformance_adapter__` and scripts a request against it.
- [ ] Create `conformance/lib/allm/test/stream_adapter_conformance.ex` — same shape for `ALLM.StreamAdapter`.
- [ ] Create `conformance/lib/allm/test/tool_executor_conformance.ex` — same shape for `ALLM.ToolExecutor`.
- [ ] Create `conformance/lib/allm/test/tool_result_encoder_conformance.ex` — same shape for `ALLM.ToolResultEncoder`.
- [ ] Add `@moduledoc` installation-for-consumers note on every conformance module: one line, `{:allm_conformance, "~> 0.2", only: :test}` — no path manipulation required.

**Harness self-tests (`conformance/test/` and `conformance/test/support/`):**

- [ ] Create `conformance/test/support/fixtures/stub_adapter.ex` — `ALLM.Test.Fixtures.StubAdapter` implementing both `ALLM.Adapter` and `ALLM.StreamAdapter` with the script shape defined in §Behaviour & Type Contracts → "StubAdapter script shape". ~40–50 lines. Permanent — remains in the sub-project's `test/support/` indefinitely as the harness's primary self-test subject.
- [ ] Ensure the stub's `StreamAdapter.stream/2` uses `Stream.resource/3` with an `after_fun` that, when `adapter_opts[:cleanup_observer]` is a `:counters` ref, calls `:counters.add(ref, 1, 1)`. This is the observable mechanism the halt-safety conformance test asserts against.
- [ ] Create `conformance/test/allm/test/adapter_conformance_test.exs` — `use ALLM.Test.AdapterConformance, adapter: ALLM.Test.Fixtures.StubAdapter`, plus two meta-tests (declared-case count, missing-`:adapter`-raises).
- [ ] Create `conformance/test/allm/test/stream_adapter_conformance_test.exs` — same shape; exercises `StubAdapter`'s streaming path.
- [ ] Create `conformance/test/allm/test/tool_executor_conformance_test.exs` — `use ALLM.Test.ToolExecutorConformance, executor: InlineStubExecutor`, where `InlineStubExecutor` is a ~10-line stub defined in the test file (not exported).
- [ ] Create `conformance/test/allm/test/tool_result_encoder_conformance_test.exs` — same shape with an inline stub encoder.

**Main-project wiring (`allm/`):**

- [ ] Before touching `mix.exs`: verify that `LICENSE` and `.formatter.exs` exist at the repo root (main project's `package.files:` already references both; `.formatter.exs` is confirmed present, `LICENSE` is confirmed missing as of 2026-04-21). Add a minimal MIT `LICENSE` file to the repo root matching the Hex metadata's declared license. Ditto for `conformance/LICENSE`.
- [ ] Add `{:allm_conformance, path: "conformance", only: :test}` to the main `allm` `mix.exs` `deps/0`. Do **not** modify the main `package: files:` list.
- [ ] Append `use ALLM.Test.ToolExecutorConformance, executor: ALLM.ToolExecutor.Default` to `test/allm/tool_executor/default_test.exs`.
- [ ] Append `use ALLM.Test.ToolResultEncoderConformance, encoder: ALLM.ToolResultEncoder.JSON` to `test/allm/tool_result_encoder/json_test.exs`.
- [ ] Main `CHANGELOG.md` entry noting the new `{:allm_conformance, ..., only: :test}` dev-dep and the two defaults (`ALLM.ToolExecutor.Default`, `ALLM.ToolResultEncoder.JSON`).

#### 3.5.3 Verification

```bash
# --- conformance sub-project: harness self-tests ---
cd conformance
mix deps.get
mix format --check-formatted
mix test                                               # self-tests against StubAdapter + inline stubs
mix credo --strict
mix dialyzer
mix hex.build                                          # publishable tarball smoke-check
# note: mix hex.publish --dry-run surfaces warnings mix hex.build does not
mix hex.publish --dry-run                              # verifies metadata + files list
cd ..

# --- main `allm` project: defaults certified against the harness ---
mix deps.get                                           # pulls allm_conformance via path dep
mix test test/allm/tool_executor/default_test.exs      # full default suite + conformance plug-in
mix test test/allm/tool_result_encoder/json_test.exs   # full default suite + conformance plug-in
mix test                                               # full main-project suite
mix test --cover                                       # ≥90% on lib/allm/tool_executor/default.ex and lib/allm/tool_result_encoder/json.ex
mix credo --strict
mix dialyzer
mix format --check-formatted
mix hex.build                                          # main package still clean (does NOT include conformance/)
mix hex.publish --dry-run                              # main package publication metadata
```

**Lockstep-publish discipline** (captured in the `CHANGELOG.md` release checklist, not a Phase 3 task but recorded as Phase-3 output): when the sub-project adds a new conformance case that asserts a new behaviour invariant, the main `allm` package must bump the behaviour's `@moduledoc` / `@doc` in lockstep. The dev-time path-dep (`path: "conformance"`) catches this at `mix test` time — if the main package's impl doesn't satisfy the new conformance case, main-project tests fail.

## Test Plan (cross-phase)

**Unit tests** — every public function in `ALLM.ToolExecutor.Default` and `ALLM.ToolResultEncoder.JSON` has at least one happy-path and one error-path test. The contract tests (`adapter_test.exs`, etc.) exercise the behaviour metadata (callback list, `@optional_callbacks`, docs).

**Behaviour conformance tests** — the four shipped conformance modules ARE the conformance suite for this and every future phase. They are exercised against Phase 3's two defaults (`ToolExecutorConformance` against `ToolExecutor.Default`, `ToolResultEncoderConformance` against `ToolResultEncoder.JSON`) and against the self-test `StubAdapter` (for the two adapter conformance modules, which have no Phase 3 subject). Phase 4 plugs Fake into all four. Phases 10/11 plug OpenAI/Anthropic into the adapter pair.

**Integration tests** — none in Phase 3. No Layer C execution function exists; there is nothing multi-module to wire up yet. Phase 5 (`stream_generate/3`) is the first phase with a legitimate integration test.

**Property tests** — none in Phase 3. Deterministic scripted inputs suffice for the conformance suite (Non-obvious Decision #7). Property-style scenarios from spec §31 land naturally in Phase 5 where event sequences are validated.

**Doctests** — `ALLM.ToolExecutor.Default.execute/3` and `ALLM.ToolResultEncoder.JSON.encode/1` each carry one runnable doctest using a small fixture. Every modified behaviour module (`ALLM.Adapter` etc.) gets a `@moduledoc` example showing a minimal `@behaviour` declaration — these are **not** doctests (they don't run) but they compile under `ex_doc`.

**Serializability tests** — none in Phase 3. No Layer A struct changes.

**Stream-equivalence tests** — none in Phase 3. No Layer C wrapper yet.

**Coverage threshold:** `mix.exs` configures 80% globally; Phase 3 targets ≥90% on all new code (`lib/allm/tool_executor/default.ex`, `lib/allm/tool_result_encoder/json.ex`). The behaviour modules themselves have near-zero lines of executable code (they're contracts) so coverage is reported but not meaningful — `mix.exs`'s per-file ignore list already excludes behaviour-only modules.

## Error Contract

| Function | Error reason | Recovery guidance |
|----------|--------------|--------------------|
| `ALLM.ToolExecutor.Default.execute/3` | `%ToolError{reason: :handler_raised}` | Handler raised; `:cause` carries the exception. Orchestrator applies `on_tool_error` policy (Phase 6). |
| `ALLM.ToolExecutor.Default.execute/3` | `%ToolError{reason: :handler_exit}` | Handler called `exit/1` or process died; orchestrator applies `on_tool_error`. |
| `ALLM.ToolExecutor.Default.execute/3` | `%ToolError{reason: :invalid_return}` | Handler returned a value outside `t:handler_result/0`; programmer error, usually not recoverable — orchestrator should halt. |
| `ALLM.ToolExecutor.Default.execute/3` | `%ToolError{reason: :not_found}` | `%Tool{handler: nil}` passed to the executor — the tool has no handler. Caller error, usually a manual-mode tool invoked in auto-mode. |
| `ALLM.ToolResultEncoder.JSON.encode/1` | raises `Protocol.UndefinedError` | Value not JSON-encodable (PID, ref, fun, bare tuple); orchestrator wraps in `try/rescue` and surfaces `%ToolError{reason: :encoding_failed}` to the model. Not caller-recoverable — user must convert the value before returning. |

**Field-error atom vocabulary:** not applicable — Phase 3 ships no validator-shaped module. The only error struct surfaces are `%ToolError{}` (whose reason vocabulary is already closed in `lib/allm/error/tool_error.ex`) and `%AdapterError{}` (whose vocabulary is already closed in `lib/allm/error/adapter_error.ex`). Both were declared in Phase 1.

**Hard-reject semantics:** not applicable — same reason.

## Streaming & Backpressure

Phase 3 does not ship any Layer C streaming or stream-consumption code. The `StreamAdapterConformance` harness declares the halt-safety and `stream_timeout` cases so every future StreamAdapter implementation is held to the contract, but Phase 3 itself has no `Stream.resource/3` to clean up — the `StubAdapter` fixture uses `Stream.resource/3` to demonstrate the halt-safety contract works as documented, and its `after_fun` sets a `Process.put/2` flag the conformance test reads. Phase 5 is where real streaming cleanup lands.

## Definition of Done

**Main `allm` project:**

- [ ] All five sub-phases marked `Completed` in the status table.
- [ ] `mix test` passes with zero failures, zero `unused_var` warnings; coverage ≥80% globally and ≥90% on `lib/allm/tool_executor/default.ex` + `lib/allm/tool_result_encoder/json.ex`.
- [ ] `mix credo --strict` passes with zero issues on changed files.
- [ ] `mix dialyzer` passes with zero new warnings against the prior PLT.
- [ ] `mix format --check-formatted` passes.
- [ ] Every new public function has an `@spec` and a non-empty `@doc`; every public function whose `@doc` contains a code block has a runnable doctest.
- [ ] Every modified behaviour file has an `@doc` on every `@callback`.
- [ ] The two defaults are certified by the conformance harness via the `{:allm_conformance, path: "conformance", only: :test}` dev-dep.
- [ ] `LICENSE` file exists at the repo root (MIT).
- [ ] `mix hex.build` + `mix hex.publish --dry-run` succeed with the main package NOT including `conformance/`.
- [ ] Main `CHANGELOG.md` has one entry per new public module (`ALLM.ToolExecutor.Default`, `ALLM.ToolResultEncoder.JSON`) plus one entry noting the new `allm_conformance` sibling package.

**`allm_conformance` sibling project (`conformance/`):**

- [ ] `cd conformance && mix test` passes; harness self-tests against `ALLM.Test.Fixtures.StubAdapter` (and inline stub executor/encoder) pass end-to-end.
- [ ] `cd conformance && mix credo --strict` passes.
- [ ] `cd conformance && mix dialyzer` passes against its own PLT.
- [ ] `cd conformance && mix format --check-formatted` passes.
- [ ] `cd conformance && mix hex.build` + `mix hex.publish --dry-run` succeed.
- [ ] `conformance/LICENSE` file exists (MIT).
- [ ] `conformance/README.md` has installation instructions (`{:allm_conformance, "~> 0.2", only: :test}`).
- [ ] `conformance/CHANGELOG.md` has the `0.2.0` initial release entry listing the four conformance modules.
- [ ] Every conformance module has `@moduledoc` installation note (one-line deps entry — no path manipulation).

**Both:**

- [ ] Commit messages reference §7, §18, §20, §31 as appropriate.
- [ ] Reviewed via `/review` per `AGENT_REVIEW_SPEC.md`.
