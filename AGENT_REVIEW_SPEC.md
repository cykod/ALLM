# Agent Review Spec — ALLM

Project-specific instructions for the `/review` skill. How to verify changes to this Elixir LLM library — by exercising the public API in IEx, running the quality-gate stack, and (when applicable) hitting real provider endpoints.

## Golden Rule

**A review must exercise the library, not just read the diff.** A green `mix test` proves the implementer's tests pass. A review proves *a user* can pick up the public API, call it the documented way, and get sensible behavior — including on error paths.

ALLM has no UI, no HTTP server, no database. The "live system" is the REPL. Every review must:

1. Run the full quality-gate stack (`mix format`, `mix test`, `mix credo --strict`, `mix dialyzer`).
2. Open `iex -S mix` and exercise every public function the change touches, against `ALLM.Providers.Fake`.
3. Verify every documented `@doc` example actually works (doctests run under `mix test`, but a manual paste catches stale prose).
4. For real-provider adapter changes: run a tagged `:integration` smoke test with a user-supplied API key.
5. For Layer A struct changes: prove the round-trip (`:erlang.term_to_binary/1` and JSON).

Skip live REPL verification only for genuinely non-functional changes (typo in `@moduledoc`, formatting-only, CHANGELOG edit).

---

## 1. Prerequisites

- Elixir `~> 1.17` and Erlang/OTP 27+ — confirm with `elixir --version`. Stop if wrong.
- `mix deps.get` if `mix.lock` changed.
- `mix compile --warnings-as-errors` clean. Any warning blocks the review.
- Dialyzer PLT built (first run takes 1–2 min; subsequent runs are seconds).

---

## 2. Quality Gate Stack

- **Full-suite `mix test` exits 0** before phase commit — not just the new phase's test files. Flaky-in-aggregate failures (test passes in isolation but fails in full-suite mode) are first-class regressions and MUST be triaged before commit. Worked example: PHASE_16.1 through 16.4 each shipped with focused-test gates green but full-suite reporting `1 failure` (`readme_getting_started_test.exs` MatchError); plus PHASE_16.4's full-suite surfaced an `AnthropicStreamWireTest` flake invisible to the focused gate.

Run all six. Capture output verbatim — a review without command output is unverifiable.

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test --cover --include doctest
mix credo --strict
mix dialyzer
```

Record the command, the full output (test count + coverage summary for `mix test`), and pass/fail. Coverage ≥80% global, ≥90% on changed files; new files dropping global below 90% is a finding.

Pre-existing dialyzer warnings: note but don't block. New warnings on changed lines: blocker.

---

## 3. IEx Verification — The Heart of the Review

```bash
iex -S mix
```

For every public function in the diff, do a **complete round-trip**:

1. Construct inputs via public constructors (`ALLM.user/1`, `ALLM.tool/1`, `ALLM.request/2`, `ALLM.Engine.new/1`) — never reach into struct internals.
2. Build an engine via `ALLM.Providers.Fake.engine/1` with a script that exercises the function.
3. Call the function; inspect the result.
4. Verify result matches docs and spec.
5. Trigger at least one Error Contract path; confirm error struct shape.

Capture the IEx session as a fenced `elixir` block with a 1–2 sentence narration of what it proves.

````markdown
```elixir
iex(1)> engine = ALLM.Providers.Fake.engine(stream: [
...(1)>   {:message_start, :assistant},
...(1)>   {:content_delta, "hello"},
...(1)>   {:content_delta, " world"},
...(1)>   {:message_end, :stop}
...(1)> ])
iex(2)> {:ok, response} = ALLM.generate(engine, ALLM.request([ALLM.user("hi")]))
iex(3)> response.content
"hello world"
```

Verifies `generate/3` reduces a streamed Fake script into a `%ALLM.Response{}`
with concatenated content and the correct finish_reason.
````

### What to exercise per layer

#### Layer A — Serializable data

For every struct touched:

```elixir
iex> msg = ALLM.user("hello")
iex> ^msg = msg |> :erlang.term_to_binary() |> :erlang.binary_to_term()
iex> ^msg = msg |> Jason.encode!() |> Jason.decode!() |> ALLM.Message.from_json!()
```

Either round-trip failing is a Layer A invariant violation — blocker. For tagged unions (`ALLM.Event`), exercise one constructor per variant the change touches.

#### Layer B — Runtime

```elixir
iex> engine = ALLM.Providers.Fake.engine(reply: "ok")
iex> :erlang.term_to_binary(engine)              # engine itself must be serializable
```

A fun, anonymous closure, or Finch ref directly on the struct will fail to round-trip. Spec §6.4 — keys resolve at adapter-call time.

#### Layer C — Stateless execution

For `generate/3`, `step/3`, `chat/3` and streaming variants:

1. Stateless call against Fake — happy path returns documented shape.
2. Streaming call against the same script — events match.
3. **Stream-equivalence**: collected stream equals the non-streaming result.

```elixir
iex> {:ok, stream} = ALLM.stream_generate(engine, request)
iex> {:ok, response} = ALLM.generate(engine, request)
iex> ^response = ALLM.StreamCollector.collect(Enum.to_list(stream))
```

4. Trigger one Error Contract path:

```elixir
iex> bad = ALLM.Providers.Fake.engine(error: {:authentication_failed, "no key"})
iex> {:error, %ALLM.Error.AdapterError{reason: :authentication_failed}} = ALLM.generate(bad, request)
```

5. **Cleanup check** for any new stream — early halt releases resources:

```elixir
iex> {:ok, ref} = ALLM.Providers.Fake.tracked_engine()
iex> {:ok, stream} = ALLM.stream_generate(ref.engine, request)
iex> _ = stream |> Enum.take(1)
iex> Process.sleep(100)
iex> ALLM.Providers.Fake.released?(ref)    # true
```

#### Layer D — Stateful continuation

1. Start, call, inspect returned session.
2. Round-trip the session through `:erlang.term_to_binary/1`.
3. Resume from the round-tripped session; next operation works.
4. For `{:ask_user, ...}` (§12.3): trigger, persist, resume, continue.
5. Exercise both `:auto` and `:manual` modes if the change touches the loop.

```elixir
iex> {:ok, session} = ALLM.Session.start(engine, [ALLM.user("hello")])
iex> ^session = session |> :erlang.term_to_binary() |> :erlang.binary_to_term()
iex> {:ok, next} = ALLM.Session.reply(session, "follow-up")
iex> next.thread.messages |> Enum.map(& &1.role)
[:user, :assistant, :user, :assistant]
```

---

## 4. Doctest Verification

For every `@doc` block touched: open the source, copy `iex>` lines into the running session, confirm output matches the prose. Drift between prose and behavior is a finding. Touched files are exactly where stale docs hide; paste-check even untouched doctests in modified files.

---

## 5. Behaviour Conformance

If the change adds/modifies an `@callback` in `ALLM.Adapter`, `ALLM.StreamAdapter`, `ALLM.ToolExecutor`, or `ALLM.ToolResultEncoder`:

1. `ALLM.Providers.Fake` implements the new/changed callback.
2. The conformance suite (`test/support/<behaviour>_conformance.ex`) has a test for the new behaviour.
3. Every real adapter in `lib/allm/providers/` implements it or has a documented reason it doesn't.

A behaviour change that lands without updating Fake is a blocker.

---

## 6. Real Provider Smoke Tests

For changes to `lib/allm/providers/openai.ex`, `lib/allm/providers/anthropic.ex`, etc.:

```bash
export OPENAI_API_KEY=sk-...
mix test --only integration test/allm/providers/openai_integration_test.exs
```

Integration tests are tagged `@tag :integration`, excluded by default. They hit the real provider with a minimal request (cheapest model, < $0.001/run), verify wire format, and **don't run in CI** without a key. If the user can't provide a key, document the test as not run with explicit risk.

**Never commit API keys.** A key in a fixture is a blocker — flag and rotate.

---

## 7. Streaming-Specific Checks

For changes to `lib/allm/stream/` or any function returning `Stream.t()`:

### SSE Parser

If `lib/allm/stream/sse.ex` changed, exercise edge cases:

```elixir
iex> ALLM.Stream.SSE.decode("data: hello\n\n")
[%{data: "hello"}]
iex> ALLM.Stream.SSE.decode("data: hel")    # split across chunks
{:incomplete, "data: hel"}
iex> ALLM.Stream.SSE.decode_continue("lo\n\n", "data: hel")
[%{data: "hello"}]
iex> ALLM.Stream.SSE.decode("data: a\n\ndata: b\n\n")   # multiple events in one chunk
[%{data: "a"}, %{data: "b"}]
```

### Cleanup

Every new `Stream.resource/3` gets the §3 cleanup test. No exceptions.

### Backpressure

Document characteristics: slow consumer (events buffer in producer), slow network (Finch stream blocks), both slow (slowest dominates). HTTP/1, not HTTP/2 — spec §7.2. Changing this requires a spec amendment.

---

## 8. Spec Drift Check

For every spec section listed in the design's Overview: read it, compare to the implementation, note drift. Deliberate deviation requires a design-doc justification AND a same-PR spec amendment — undocumented deviation is a blocker. Implementation matching the spec but exercising a spec gap (e.g., spec doesn't say what happens on `{:error, :timeout}` from a tool, impl chose a behavior) is a finding — spec should lock the choice.

---

## 9. CHANGELOG and Documentation

For every public-API change:

- [ ] `CHANGELOG.md` entry under unreleased
- [ ] Every new public function has a `@doc` with a runnable doctest using `ALLM.Providers.Fake`
- [ ] Every new behaviour callback has a `@doc` on the callback itself
- [ ] Every new error reason documented in the function's `@doc` Errors section
- [ ] `README.md` examples still work
- [ ] `mix docs` renders without warnings

---

## 10. Review Document Format

The review doc IS the artifact. Self-contained evidence:

1. **Summary** — what changed (1–2 sentences), spec sections, layers.
2. **Quality Gate Stack** — every command from §2 with full output.
3. **IEx Sessions** — every session from §3 in fenced blocks, each with 1–2 sentence narration.
4. **Doctest Verification** — files re-pasted, drift findings.
5. **Behaviour Conformance** — Fake implements every changed callback, conformance output.
6. **Integration Tests** — command, output, cost (when applicable).
7. **Spec Drift** — section-by-section comparison.
8. **Findings** — bulleted, severity (Blocker / Finding / Nit), file:line, proposed fix.
9. **Checklist** — §11, each box checked or N/A.

Every IEx session needs narration explaining what it proves. A session block without narration is decoration; narration without a session is unverifiable.

---

## 11. Review Checklist

- [ ] `mix format --check-formatted` passes
- [ ] `mix compile --warnings-as-errors` passes
- [ ] `mix test --cover --include doctest` passes; coverage ≥80% global, ≥90% on changed files
- [ ] `mix credo --strict` zero issues on changed files
- [ ] `mix dialyzer` zero new warnings
- [ ] Every public function in the diff exercised in IEx (happy path)
- [ ] Every Error Contract reason triggered in IEx
- [ ] Every Layer A struct round-trips through `:erlang.term_to_binary/1` and JSON
- [ ] Every new `Stream.resource/3` has a cleanup test on early halt
- [ ] Every non-streaming wrapper has a stream-equivalence check
- [ ] Every touched `@doc` re-pasted into IEx; prose matches behavior
- [ ] Every `@callback` change reflected in `ALLM.Providers.Fake`
- [ ] Every spec section from the design diff-checked against implementation
- [ ] CHANGELOG.md updated for every public-API change
- [ ] No API keys, secrets, or PII in fixtures or doctests
- [ ] Integration tests run (or explicitly skipped with documented risk)
- [ ] All findings tagged Blocker / Finding / Nit with proposed fixes

---

## 12. Common Blockers

| Blocker | Resolution |
|---------|-----------|
| `mix dialyzer` slow on first run | Wait it out (1–2 min PLT build). Don't skip. |
| Coverage <90% on new code | Add tests. If genuinely untestable, document why inline. |
| Doctest drifts from prose | Update prose. Behavior is the source of truth. |
| `:erlang.term_to_binary/1` fails on Layer A struct | Find the offending field (fun/ref/PID/closure). Refactor to module + atom. §6.4. |
| Engine round-trip fails | Same root cause as Layer A. |
| Stream-equivalence fails | Wrapper isn't reducing correctly OR streaming variant emits unhandled events. Either is a blocker. |
| Behaviour callback added but Fake not updated | Update Fake — it's the reference implementation. |
| Real-provider integration test fails | Did the provider change wire format? If so, design issue, not test issue. Stop and ask. |
| Spec drift | Justify in design + spec amendment in same PR. Else blocker. |
| API key in fixture or commit | Rotate immediately. Block merge. |
| `middleware:` field added | Reserved for v0.3 (§29). Reject. |
| HTTP/2 used for streaming | Change to HTTP/1 (§7.2 documents the Finch flow-control bug). |
| `term()` in `@spec` for an error type | Replace with the error struct type. |
| `Bypass`/HTTP mocks for orchestration logic | Replace with `ALLM.Providers.Fake`. Forbidden by CLAUDE.md. |
