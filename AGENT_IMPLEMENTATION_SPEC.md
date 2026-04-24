# Implementation Spec Guidelines — ALLM

How to implement design documents in the ALLM Elixir library. The `/implement` skill reads this file automatically.

## Workflow

### 1. Start Green

Before writing any code, confirm the current tree is green:

```bash
mix deps.get
mix compile --warnings-as-errors
mix format --check-formatted
mix test
mix credo --strict
mix dialyzer
```

All six must pass with zero failures and zero warnings. Pre-existing failures blur the signal on new regressions — if anything fails, **stop and ask the user for direction**. Never normalize a failing baseline. "Two pre-existing failures" is the exact state where new failures hide.

If the design touches the streaming runner, also confirm `ALLM.Providers.Fake` passes its conformance suite:

```bash
mix test test/allm/providers/fake_conformance_test.exs
```

**Baseline-repair allowance.** If Start Green fails because of a *pre-existing* scaffolding issue in a file outside the current sub-phase's allowed-edit scope — an unformatted file from the initial commit, a version-constraint typo in `mix.exs`, a broken doctest in an unrelated module — resolving it is **baseline repair**, not "normalizing a failing baseline." Baseline repair is allowed under three conditions:

1. The repair touches only what's necessary to turn a failing gate green. No refactors, no renames, no semantic changes. Only formatting, dep cleanup, and obvious scaffold typos.
2. The repair lands as a separate commit with message `chore: baseline repair for <sub-phase> (<gate>)`, before the sub-phase work begins.
3. The user authorizes each distinct repair category. If Start Green surfaces multiple issues, enumerate them all in one round-trip — don't stop on the first failure and come back for each.

The "never normalize a failing baseline" rule stays in force for *mid-phase* failures (a regression introduced by the current sub-phase's tests is a real regression; don't format around it). Baseline repair is a pre-phase activity with a separate commit; mid-phase normalization is a shortcut that hides bugs.

### 2. Read the Whole Design First

Read the entire design doc before writing any code. Understand:

- The four-layer assignment of every phase (A / B / C / D)
- How phases depend on each other (later phases assume earlier behaviours, structs, and event variants exist)
- The Test Plan for every phase — these are the tests you'll write *before* the implementation
- The Error Contract — every error reason and its recovery guidance
- The Definition of Done

Then implement one phase at a time, in order. Do not skip ahead. Do not implement Phase 3 before Phase 2 — the build order in the spec (§28) is load-bearing.

Check the status table before starting each phase — `Completed` rows are already done.

### 3. Ask When Uncertain

If anything is ambiguous, has multiple valid implementations, or conflicts with the codebase or the spec, **stop and ask the user** via `AskUserQuestion`. A 30-second clarification saves hours of rework. Common cases:

- The design specifies an event variant or callback that conflicts with the spec (`steering/allm_engine_session_streaming_spec_v0_2.md`) — the spec wins, ask before implementing the design.
- A design phase touches more than one layer with no justification.
- An `@spec` in the design uses `term()` for an error type instead of a struct.
- The design adds a `middleware:` field (reserved for v0.3 — spec §29).
- A behaviour callback in the design isn't reflected in `ALLM.Providers.Fake`.
- Two valid implementation strategies exist (e.g., `Stream.resource/3` vs a GenServer-backed stream) and the design doesn't specify.
- A test in the Test Plan can't be written because the API surface it depends on doesn't exist yet (usually means a phase is out of order).

### 4. Per-Phase Loop (TDD)

For each phase, in order:

1. **Mark the status table row `In Progress`.**
2. **Write the tests from the Test Plan first.** Every test in the Test Plan goes in before any implementation. Run `mix test path/to/new_test.exs` and confirm they fail with the expected error (usually `UndefinedFunctionError` or assertion failures, not compile errors). A test that fails for the *wrong* reason is not a failing test — it's a broken test.
3. **Implement the minimum code to make the tests pass.** Don't add functions, fields, or branches the tests don't exercise. If the design specifies functionality the tests don't cover, the Test Plan is incomplete — go back to step 2 and add the missing tests.
4. **Run the focused test suite** (`mix test path/to/new_test.exs`) and confirm green.
5. **Run the full suite** (`mix test`) to catch regressions. If anything fails outside your phase, fix it before continuing.
6. **Run quality gates** (`mix format`, `mix credo --strict`, `mix dialyzer`). Zero issues.
7. **Update the doctests.** Every public function added or modified gets an `@doc` with at least one runnable example using `ALLM.Providers.Fake` (Phase 4+) or pure Layer A data construction (Phase 1). One doctest per public function is the floor. Add a second doctest when the function has a meaningfully different branch (default-message vs. `:message` override, happy path vs. common-rejection, empty-input vs. populated-input). Don't add doctests that only vary the input slightly — those belong in the test file. Run `mix test --include doctest` to confirm doctests pass.
8. **Check off `[x]` completed items** in the design doc.
9. **Mark the status table row `Completed`.** A row is `Completed` only when (a) all checkboxes are checked, (b) all tests in the Test Plan pass, (c) all quality gates pass, and (d) the public API is consistent (no half-defined functions). Anything less is `In Progress`.
10. **If you deviated from the design, add a brief Implementation Notes line** explaining why. Deviations happen — undocumented deviations are the problem.
11. **Commit the phase** with a message that cites the spec section: `Phase 4: stream_generate/3 over Fake (§3, §4, §8)`.

### CHANGELOG cadence

During pre-1.0 multi-sub-phase work, group `## Unreleased` entries by sub-phase subheading (`### Phase 1.1 — Error Hierarchy`, `### Phase 1.2 — Layer A Struct Helpers`, …) with Added/Changed/Fixed nested under each. This keeps the `Unreleased` section scannable at mid-phase checkpoints when the flat Keep-a-Changelog form would accumulate 15+ bullets across three categories with no temporal grouping.

Flatten to standard Keep-a-Changelog format post-1.0, when release frequency matches entry frequency and sub-phase grouping stops being the meaningful unit.

### Steady-state velocity rubric

After the first 1–2 batches of a phase establish its conventions, subsequent batches should land in one pass with:

- **No-op Start Green** — pre-flight baseline is green, no repair needed.
- **One-pass implement** — no blockers surfacing that halt the agent mid-flight.
- **≤2 small deviations** — and "small" means tactical per §4a, not structural.
- **Monotone global coverage** — new code lands at ≥90%, global doesn't dip. Small prose-only additions (`@moduledoc` / `@doc` text surrounding doctests) may drift global coverage ±0.1% because excoveralls counts doctest iex lines but not surrounding prose. The load-bearing signal is per-module new-code coverage; an integer-level global dip from prose is noise, not a gate failure.

A batch that exceeds 2 deviations, reports ≥1 structural inference, or causes a global-coverage dip indicates a design-doc gap. Run `/retro` and `/apply-retro` before the next batch starts — compounding gaps across batches is how you get to Batch N with three unfixed issues and no idea which one is the load-bearing problem.

### Combining adjacent sub-phases

When two adjacent sub-phases target the same layer and share no behavioural dependency — Test Plans don't reference each other's types, one's public API doesn't consume the other's output — they may be combined into one implementation batch. Start Green runs once, the CHANGELOG sub-phase subheading covers both, the commit narrative stays coherent. Combining saves one round-trip without hiding dependencies.

Keep sub-phases split when they target different layers or when one's public API is a dependency of the other (e.g., `ALLM.Validate` returns `%ValidationError{}` from `ALLM.Error` — those sub-phases are ordered, not combinable). If in doubt, split; combining a dependency-crossing batch is strictly worse than running two batches in sequence.

### Constructor test pattern

To assert "required positional args raise `ArgumentError`", use `Mod.new(nil)` — not `apply(Mod, :new, [])`. Credo's `Refactor.Apply` rule flags the `apply/3` form; `nil` falls into the function's own reason-validation path and produces the same `ArgumentError` without Credo friction. The function's `@spec` guarantees the arity; no need to use `apply/3` to bypass it.

### 4a. Tactical vs. structural inference

When the design names a rule and its trigger but leaves the specific Elixir-idiom choice to the implementer — atom naming for a `{field, reason}` tuple, defensive clauses for string-keyed vs. atom-keyed maps, which error atom to pick when the design says "out of range" without specifying — pick the idiomatic choice and move on. Log it in your Implementation Notes as `[tactical] <one-line summary>` so the review step can audit. Do not halt the build loop for a design round-trip on tactical naming.

**Structural inferences** — `@enforce_keys`, `defexception` fallback clauses, `@derive` vs. `defimpl`, `String.to_existing_atom/1` vs. `String.to_atom/1`, `Stream.resource/3` vs. `Stream.unfold/2`, or a change to a documented deny-list / allow-list (e.g., adding a key to `@engine_field_keys`, removing a reason from a closed-reason-atom enum) — are NOT tactical. They're test-observable invariants that belong in the design's Behaviour & Type Contracts section (per `AGENT_DESIGN_SPEC.md §3`). If you find yourself inferring one, stop and request a design amendment — the contract section is incomplete.

### 5. Quality Gates After Every Phase

Every phase must pass all of:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test                              # zero failures, ≥80% coverage globally
mix test --cover --include doctest    # confirm doctests run and contribute coverage
mix credo --strict                    # zero issues on changed files
mix dialyzer                          # zero new warnings vs. the prior PLT
```

If `mix dialyzer` reports a warning that existed before your change, document it in the phase's Implementation Notes — but don't normalize it. Pre-existing dialyzer noise is the exact thing that hides new type errors.

**Coverage:** the global threshold (`mix.exs`) is 80%. New code in a phase should land at ≥90% line coverage. Use `mix test --cover` and inspect `cover/excoveralls.html` (or the summary table) to verify.

### 6. When All Phases Are Complete

Summarize at the end:

- Files created / modified (exact paths)
- Deviations from the design and why
- Public-API additions (functions, behaviours, structs, event variants) — each gets a CHANGELOG entry
- Test count delta (`mix test` reports total tests; record before/after)
- Coverage delta
- How to manually verify in IEx:

```elixir
iex -S mix
iex> engine = ALLM.Providers.Fake.engine(messages: [...])
iex> {:ok, response} = ALLM.generate(engine, ALLM.request([ALLM.user("hello")]))
iex> response.content
```

If a real provider adapter is involved, include a smoke-test recipe (gated behind `@tag :integration`) that the user can run with their own API key.

## TDD: The Non-Negotiables

ALLM is built TDD-first. The four rules:

1. **No production code without a failing test.** If you find yourself writing a function with no test, stop. Write the test, watch it fail, then write the function.
2. **The test must fail for the right reason.** A test that fails because the module doesn't exist is good. A test that fails because of a typo in the test itself is broken. Read the failure message before "fixing" anything.
3. **Make the test pass with the minimum code.** Don't anticipate the next test by adding extra branches. The next test will tell you what's missing. This is how the API stays minimal.
4. **Refactor with the test green.** Once the test passes, look at what you wrote. Extract helpers, rename, simplify — but only with tests green. If a refactor breaks a test, the refactor is wrong.

These four rules are not aspirational — they are how the codebase is built. PRs that ship implementations without tests are blocked.

## Test Patterns Per Layer

### Test file organization

Every `lib/allm/<path>.ex` gets a matching `test/allm/<path>_test.exs`. Do not combine tests for multiple modules into one test file. Shared fixtures go in `test/support/`, not in a shared test module. Property tests for a module live alongside the unit test file as `test/allm/<path>_property_test.exs`.

The 1:1 mapping keeps test-file lookup trivial (the test file for `ALLM.Validate` is `test/allm/validate_test.exs` — no cross-file search needed) and prevents one test file from accumulating every "it's related" test across modules. A module that doesn't justify its own test file usually doesn't justify its own source file either.

### Property tests

`:stream_data` (test-only dep) is the house property-testing library. Every property test module uses `use ExUnitProperties` and lives alongside its unit test file as `test/allm/<path>_property_test.exs`.

Generators for Layer A structs live in `test/support/generators.ex` — shared across property files that need them. Inline generators are fine for a single-use test; promote to `test/support/generators.ex` the moment a second property file references the same shape.

Prefer generator-level invariants (e.g., `StreamData.bind/2` + `StreamData.filter/2` chains for unique-by-field constraints) over post-filter inside `check all`. Post-filter works but shrinks incorrectly — a shrunk counterexample that violates the post-filter will silently pass the test, hiding coverage of the constrained case.

### Layer A — Serializable data

Every Layer A struct gets:

- A **construction test** for every public constructor (e.g., `ALLM.system/1`, `ALLM.user/1`).
- A **validation test** for every invariant (e.g., `ALLM.Message` with `role: :tool` requires `tool_call_id`).
- A **`:erlang.term_to_binary/1` round-trip test**:

  ```elixir
  test "Message round-trips through :erlang.term_to_binary/1" do
    msg = ALLM.user("hello")
    assert msg == msg |> :erlang.term_to_binary() |> :erlang.binary_to_term()
  end
  ```

- A **JSON round-trip test** (with the codec the public API uses):

  ```elixir
  test "Message round-trips through Jason" do
    msg = ALLM.user("hello")
    encoded = Jason.encode!(msg)
    decoded = encoded |> Jason.decode!() |> ALLM.Message.from_json!()
    assert msg == decoded
  end
  ```

- For tagged-union types (`ALLM.Event`), a test per variant + a property test asserting the closed union is exhaustive (use a helper that pattern-matches every variant and fails on `_unknown`).

**No PIDs, no refs, no funs, no anonymous functions on Layer A.** A test that constructs a struct, calls `:erlang.term_to_binary/1` on it, and asserts the result is a binary catches accidental leaks.

### Layer B — Runtime

Every behaviour gets a **conformance suite**. The design doc chooses one of two shipping shapes per behaviour; an implementer must read the design's Non-obvious Decisions section to know which one is in use before placing the files.

**Shape A — main-project-internal (`test/support/`).** The suite lives in the main `allm` package at `test/support/<behaviour>_conformance.ex`, uses `ExUnit.CaseTemplate` or `defmacro __using__/1`, and is available only inside the main project's test tree. Use this when the suite has no external consumers and doesn't need to be published. Lower coordination cost, no second `mix.exs`.

**Shape B — sibling Hex package (`conformance/`).** The suite lives in a sibling sub-project at `conformance/lib/allm/test/<behaviour>_conformance.ex` and is published as a separate Hex package (e.g., `allm_conformance`) that external adapter authors depend on with a one-line `{:allm_conformance, "~> 0.2", only: :test}` entry in their `deps/0`. Use this when (a) external users are expected to write their own implementations of the behaviour and need the harness, (b) the harness pulls in test-framework deps (`ExUnit.CaseTemplate`, future `StreamData` generators) that would leak into the main runtime package, or (c) consumers would otherwise need to add `"deps/allm/test/support"` to their `elixirc_paths`. The main `allm` package depends on the sibling via a `path:` dev-time dep so its own defaults can certify against the harness.

**Shape B PLT gotcha.** A sibling-package harness built on `ExUnit.CaseTemplate` expands to a call to `ExUnit.CaseTemplate.__proxy__/2`, which Dialyzer can only resolve if `:ex_unit` is in the sub-project's PLT. Add `dialyzer: [plt_add_apps: [:ex_unit]]` to the sibling's `mix.exs` `project/0` block — otherwise `mix dialyzer` fails with an unresolved-call warning against `__proxy__/2`. This is an undocumented cost of Shape B; the design's cost-tradeoff analysis for Shape B should include it.

Regardless of shape, the suite is parameterized by the implementation module:

```elixir
# Shape A (test/support/):
defmodule ALLM.AdapterConformance do
  defmacro __using__(opts) do
    impl = Keyword.fetch!(opts, :impl)
    quote do
      use ExUnit.Case, async: true
      @impl unquote(impl)

      describe "Adapter conformance" do
        test "generate/3 with a minimal request returns {:ok, %ALLM.Response{}}", do: ...
        # ... one test per spec'd behaviour
      end
    end
  end
end

# Shape B (conformance/lib/allm/test/):
defmodule ALLM.Test.AdapterConformance do
  use ExUnit.CaseTemplate

  using opts do
    quote do
      @__allm_conformance_adapter__ Keyword.fetch!(unquote(opts), :adapter)

      describe "ALLM.Adapter conformance" do
        test "generate/2 with a minimal request returns {:ok, %ALLM.Response{}}", _context do
          # reads @__allm_conformance_adapter__
        end
        # ... one test per spec'd behaviour
      end
    end
  end
end
```

`ALLM.Providers.Fake` is the reference implementation; every real provider adapter (OpenAI, Anthropic) reuses the same suite via `use ALLM.AdapterConformance, impl: ALLM.Providers.OpenAI` (Shape A) or `use ALLM.Test.AdapterConformance, adapter: ALLM.Providers.OpenAI` (Shape B).

The engine itself gets a **serializability test**: `:erlang.term_to_binary/1` on a constructed engine succeeds, and the round-tripped engine produces equivalent results. This catches accidentally storing a fun or a Finch ref on the struct.

### Layer C — Stateless execution

- **Streaming primitive first.** Write tests for `stream_generate/3` against `ALLM.Providers.Fake` before writing tests for `generate/3`. The non-streaming variant is a reducer over the streaming variant.
- **Stream-equivalence test** for every non-streaming wrapper:

  ```elixir
  property "generate/3 equals stream_generate/3 |> StreamCollector.collect/1" do
    check all(script <- fake_event_script_generator()) do
      engine = Fake.engine(stream: script)
      {:ok, response} = ALLM.generate(engine, ALLM.request([ALLM.user("x")]))
      {:ok, stream} = ALLM.stream_generate(engine, ALLM.request([ALLM.user("x")]))
      collected = ALLM.StreamCollector.collect(stream)
      assert response == collected
    end
  end
  ```

- **Cleanup test** for every stream resource:

  ```elixir
  test "stream_generate/3 cleans up when the consumer halts early" do
    {:ok, ref} = Fake.tracked_engine()
    {:ok, stream} = ALLM.stream_generate(ref.engine, ALLM.request([ALLM.user("x")]))
    _ = stream |> Enum.take(1)
    assert_receive {:fake_resource_released, ^ref}, 500
  end
  ```

- **Error contract tests.** Every `{:error, %ALLM.Error.X{reason: r}}` documented in the Error Contract gets a test that triggers `r` via the Fake adapter.

### Layer D — Stateful continuation

- **State-transition tests.** For every `Session` operation, assert (a) the returned session has the expected `thread.messages` ending; (b) `usage` is accumulated correctly; (c) the session round-trips through `:erlang.term_to_binary/1` after every operation.
- **`{:ask_user, ...}` suspension tests** in both `:auto` and `:manual` modes (spec §12.3). Suspended sessions must be persistable and resumable.
- **Tool execution tests** in `:auto` mode (loop runs tools) and `:manual` mode (caller submits tool results). The session-level Test Plan must cover both.

## Mocking Policy

- **Use `ALLM.Providers.Fake` for all orchestration tests.** This is non-negotiable (CLAUDE.md and `AGENT_DESIGN_SPEC.md` both state this). Network mocks are forbidden for orchestration logic — they couple tests to provider wire formats and break the layer boundary.
- **Use `Bypass` or `Plug.Test` for real provider adapter wire-format tests only.** These tests live in `test/allm/providers/<provider>_wire_test.exs` and are tagged `@tag :wire`. They confirm the adapter sends the right request bytes and parses the right response bytes — nothing else.
- **Use `Mox` only for behaviours that don't have a Fake.** Currently this is `ALLM.Keys` (key resolvers) and rare cases. Prefer adding to the Fake over introducing a Mox.

## Error Handling

Errors are first-class data, never strings. Every public function returns `{:ok, result}` or `{:error, %ALLM.Error.X{}}` where `X` is one of:

- `ALLM.Error.AdapterError` — provider-side failures (auth, rate limit, content filter, etc.)
- `ALLM.Error.EngineError` — engine misconfiguration (no adapter, no key, invalid model)
- `ALLM.Error.StreamError` — streaming-specific failures (chunk parse error, stream truncation)
- `ALLM.Error.ToolError` — tool execution failures (handler raised, ask-user without prompt, etc.)
- `ALLM.Error.SessionError` — session-state corruption (thread invariant violated, etc.)

Each error struct has at minimum `:reason` (atom from a closed set), `:message` (human-readable, no secrets), `:provider` (atom or `nil`), `:cause` (the underlying term).

**Discipline:**

- **No `{:error, term()}` in `@spec`.** Use the struct type. `term()` says the contract isn't designed.
- **No `raise` in public functions.** Public functions return error tuples. Internal helpers may raise on programmer errors (use `ALLM.ArgumentError` and similar).
- **No swallowed errors.** Every `try/rescue` has either a `Logger` call or an error tuple return — never both silent.
- **Errors include `:cause` for debugging.** Don't drop the underlying exception; chain it via `:cause` so users can `inspect/1` it during debugging.

## Streaming Discipline

- **Every `Stream.resource/3` has a cleanup function.** No exceptions. Test it with an early consumer halt.
- **Backpressure is the consumer's responsibility.** Producer streams emit as fast as the network delivers; consumers using `Stream.take/2`, `Enum.into/3`, etc., control the rate. Document this in `@doc` for every public stream-returning function.
- **HTTP/1, not HTTP/2** for streaming (spec §7.2). Don't change this without a spec amendment.
- **SSE parsing is line-buffered.** Events can span chunks; the parser must buffer until it sees `\n\n`. Test with chunks split mid-event.

## Common Commands

```bash
mix deps.get                           # install
mix compile --warnings-as-errors       # compile (CI uses this exact flag)
mix format                             # autoformat
mix format --check-formatted           # CI gate
mix test                               # full suite
mix test --cover                       # with coverage summary
mix test --include doctest             # include doctests (default config in mix.exs)
mix test test/path/to/file_test.exs    # single file
mix test test/path/to/file_test.exs:42 # single test by line
mix test --only focus                  # tagged @tag :focus
mix test --only integration            # real provider smoke tests (require API keys)
mix credo --strict                     # linter
mix credo --strict lib/allm.ex         # linter on a single file
mix dialyzer                           # type checker
mix dialyzer --plt                     # rebuild PLT
iex -S mix                             # REPL with project loaded
```

## Project Conventions

### Module organization

- `lib/allm.ex` — top-level facade (spec §4). One function per public operation, dispatching to internal modules.
- `lib/allm/<struct>.ex` — Layer A structs. One module per struct.
- `lib/allm/engine.ex` — Layer B engine struct.
- `lib/allm/<behaviour>.ex` — Layer B behaviour modules (`Adapter`, `StreamAdapter`, `ToolExecutor`, `ToolResultEncoder`).
- `lib/allm/session.ex` — Layer D session module.
- `lib/allm/stream/` — internal streaming machinery (runner, collector, SSE parser). Not part of the public API; do not reference these modules from outside `lib/allm/`.
- `lib/allm/providers/<name>.ex` — adapter implementations. `Fake` is part of the library proper, not test-only.
- `lib/allm/error/<name>.ex` — error structs.

**Single-file threshold.** Utility surfaces (`ALLM.Validate`, future `ALLM.Serializer`, `ALLM.Keys`) live in single files by default. Split into multiple files only when (a) two public functions share no private helpers, OR (b) private-helper count exceeds public-function count by more than 4x and the file becomes hard to read. Line count alone isn't a trigger — Elixir's `File`, `Map`, `Enum` are all single files with 30+ public functions because their surfaces are coherent. If the module's *surface* is one concept ("validate a Layer A value", "encode/decode tagged JSON"), keep it in one file.

### Naming

- Streaming variants are `stream_<name>/n` (e.g., `stream_generate/3`, `stream_step/3`).
- Behaviour callback names match the function they back (`generate/3` calls `c:Adapter.generate/3`).
- Internal modules use `ALLM.Internal.X` if they exist outside `lib/allm/stream/`. Avoid them; prefer making the module non-public via `@moduledoc false`.

### Documentation

- Every public module has a `@moduledoc` describing the layer (A/B/C/D), the role, and a runnable example.
- Every public function has a `@doc` with at least one runnable doctest using `ALLM.Providers.Fake`.
- Every behaviour callback has a `@callback` and a `@doc` on the callback (not just the behaviour module).
- ExDoc groups follow the four layers — see `mix.exs` `:docs` config.

### Telemetry

Telemetry events follow the spec §29 convention:

- `[:allm, :request, :start | :stop | :exception]` — non-streaming requests
- `[:allm, :stream_request, :start | :stop | :exception]` — streaming requests
- `[:allm, :tool, :start | :stop | :exception]` — tool execution
- `[:allm, :session, :start | :stop | :exception]` — session operations

Measurements include `:duration` (native units), `:input_tokens`, `:output_tokens`, `:cost` (when `llm_db` is present). Metadata includes `:provider`, `:model`, `:engine_id` (when set).

**Don't add new telemetry events without a spec amendment.** Telemetry is a public contract; downstream observability code subscribes to specific event names.

### Logger usage

- `Logger.warning/1` for ops-visible degradations (rate limits, retries).
- `Logger.error/1` for errors that propagate to the caller (with the same struct attached as `error: %ALLM.Error.X{}` metadata).
- No `Logger.debug/1` in hot paths (per-event, per-chunk). Use telemetry instead.
- Never log API keys, request bodies with PII, or response bodies with PII. Log structural metadata only (model, token counts, durations).

## Common Pitfalls

- **Don't put a fun on the engine struct.** Engines must be serializable. Use a module + atom (`{MyKeys, :resolve_openai}`) instead of an anonymous function. Spec §6.4.
- **Don't put an API key on the engine.** Resolve at adapter-call time via `ALLM.Keys`. Spec §6.4.
- **Don't add a new event variant without updating every reducer.** `ChatResult`, `StepResult`, `Session` all reduce events — adding a variant without updating all three breaks downstream consumers. Spec §8.
- **Don't reach for HTTP mocks for orchestration tests.** Use `ALLM.Providers.Fake`. Network mocks couple tests to provider wire formats and defeat the layer abstraction.
- **Don't write a non-streaming function that doesn't reduce its streaming counterpart.** This violates spec §3 (stream-first execution) and creates two implementations to maintain.
- **Don't use `Stream.unfold/2` for IO-backed streams.** Use `Stream.resource/3` so cleanup is explicit.
- **Don't use HTTP/2 for streaming.** Spec §7.2 documents a Finch HTTP/2 flow-control bug affecting large request bodies. HTTP/1 is the correct choice.
- **Don't add `middleware:` support.** Reserved for v0.3 (spec §29). Cross-cutting concerns go through telemetry handlers or adapter wrappers.
- **Don't depend on `llm_db` from core modules.** It's optional. Core must function without it (spec §6.3). Capability checks degrade gracefully when `llm_db` is absent.
- **Don't forget the `@spec`.** Dialyzer relies on it. CI's `mix dialyzer` step will fail on a missing spec for a public function.
- **Don't widen an `@spec` to silence Dialyzer.** A widened spec hides real type errors. Fix the implementation, not the spec.
- **Don't `if Mix.env() == :test` in `lib/`.** Test-only code lives in `test/support/`, which is in `elixirc_paths` only for `:test`. Conditional compilation in `lib/` is a code smell.
- **Don't normalize Dialyzer warnings.** Each warning is real. If a warning is genuinely false, suppress it inline with a comment explaining why and link to a spec section if relevant.
- **Don't change the public API without a CHANGELOG entry.** Even pre-1.0, downstream applications (the four examples in `steering/examples/`) depend on the API. Document every change.
- **Don't merge a phase with `In Progress` status.** A phase is `Completed` or it's not done. "Mostly done" hides incomplete error contracts and missing tests.
- **Don't skip `mix dialyzer` because it's slow.** Run it locally before pushing. The first run builds the PLT (~1-2 min); subsequent runs are seconds. CI runs it on every PR.

### Elixir serialization exception shapes

These three observed behaviors surprise most Elixir developers writing Layer A/B serializability tests:

- **`:erlang.term_to_binary/1` silently encodes anonymous functions and funs-in-keyword-lists.** The unsafety is at decode-time across BEAM reloads or nodes (`:badfun`), not at encode. Do not write tests that `assert_raise ArgumentError, fn -> :erlang.term_to_binary(…fn…) end` — they will never fire.
- **Jason raises `Protocol.UndefinedError`, not `Jason.EncodeError`, when no encoder exists for a value.** `Jason.EncodeError` is for cases where an encoder is defined but rejects its input. A function, tuple, or struct without a `Jason.Encoder` impl produces `Protocol.UndefinedError` at protocol dispatch.
- **`DateTime` and `Decimal` have Jason encoders (ISO-8601 / string) but no matching decoders in this library.** A metadata map containing `%DateTime{}` round-trips through `term_to_binary` cleanly, but the JSON round-trip is **non-equality-preserving** — the decoded value is an ISO-8601 binary, not a `%DateTime{}`. Tests assert `refute decoded == original`, not encode-time raises.

### Optional-dep detection

To reference an optional dependency at runtime without a compile-time binding (e.g., the optional `llm_db` catalog from spec §6.3), use:

```elixir
mod = Module.concat(["OptionalMod"])
if Code.ensure_loaded?(mod) do
  mod.some_fun(arg)
else
  fallback(arg)
end
```

Three approaches that **don't work** and you'll hit first:

- **Direct reference** (`OptionalMod.some_fun(arg)`): trips `--warnings-as-errors` when the dep is absent (unknown-module compile warning).
- **`apply/3`** (`apply(OptionalMod, :some_fun, [arg])`): trips Credo's `Refactor.Apply` rule.
- **Bound variable** (`mod = OptionalMod`): same compile warning as the direct reference — the literal atom in the source triggers it.

`Module.concat(["OptionalMod"])` produces the atom at runtime from a compile-time literal string. Exactly one atom is ever created, so it's not the atom-table-exhaustion vector that the same call is when applied to untrusted JSON — see AGENT_DESIGN_SPEC.md "scope stdlib bans to their threat model".
