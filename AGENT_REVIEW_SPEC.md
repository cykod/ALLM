# Agent Review Spec — ALLM

Project-specific instructions for the `/review` skill. Tells an AI agent how to verify changes to this Elixir LLM library — by exercising the public API in IEx, running the full quality-gate stack, and (when applicable) hitting real provider endpoints with smoke tests.

## Golden Rule

**A review must exercise the library, not just read the diff.** A green `mix test` proves the tests the implementer wrote pass. A review proves that *a user* can pick up the public API, call it the way the docs say to, and get sensible behavior — including on the error paths.

ALLM has no UI, no HTTP server, no database. The "live system" is the Elixir REPL. Every review must:

1. Run the full quality-gate stack (`mix format`, `mix test`, `mix credo --strict`, `mix dialyzer`).
2. Open `iex -S mix` and exercise every public function the change touches, against `ALLM.Providers.Fake`.
3. Verify every documented `@doc` example actually works (doctests run under `mix test`, but a manual paste in IEx catches stale prose around the example).
4. For changes touching real provider adapters: run a tagged `:integration` smoke test against the real provider with a user-supplied API key.
5. For changes touching Layer A structs: prove the round-trip — `:erlang.term_to_binary/1` and JSON.

Skip live REPL verification only if the change is genuinely non-functional (typo in `@moduledoc`, formatting-only change, CHANGELOG edit). When in doubt, fire up IEx.

---

## 1. Prerequisites

- Elixir `~> 1.17` and Erlang/OTP 27+ — confirm with `elixir --version`. If wrong, stop and ask the user (the dev container ships the right versions; if it's wrong, something is misconfigured).
- Dependencies installed: `mix deps.get`. If `mix.lock` changed in the diff, re-run `mix deps.get` before reviewing.
- Compiled clean: `mix compile --warnings-as-errors`. Any warning is a blocker for the review.
- Dialyzer PLT built: first-time PLT build takes 1-2 minutes. If `mix dialyzer` reports "Starting PLT build", wait it out — incremental runs are seconds.

---

## 2. Quality Gate Stack

Run all six. Every one must pass. Capture the output verbatim into the review document — a review without command output is unverifiable.

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test --cover --include doctest
mix credo --strict
mix dialyzer
```

For each command, record:
- The full command line
- The full output (including the test count and coverage summary for `mix test`)
- Pass / fail status

Coverage summary should show ≥80% globally (the `mix.exs` threshold) and ≥90% on files touched by the change. If new files dropped overall coverage below 90%, that's a finding — call it out.

If `mix dialyzer` reports a warning that existed before the change, note it but don't block — those are pre-existing tech debt the implementer didn't own. New warnings on changed lines are blockers.

---

## 3. IEx Verification — The Heart of the Review

Open the REPL:

```bash
iex -S mix
```

For every public function the change touches, perform a **complete round-trip** in IEx:

1. Construct the inputs using the public constructors (`ALLM.user/1`, `ALLM.tool/1`, `ALLM.request/2`, `ALLM.Engine.new/1`, etc. — never reach into struct internals).
2. Build an engine using `ALLM.Providers.Fake.engine/1` with a script that exercises the function's behavior.
3. Call the function. Inspect the result with `IO.inspect/2` or just print it.
4. Verify the result matches what the docs and the spec say it should.
5. Trigger at least one error path documented in the function's Error Contract. Confirm the error struct shape matches the spec.

Capture the IEx session as a fenced code block in the review doc. Example:

````markdown
```elixir
iex(1)> engine = ALLM.Providers.Fake.engine(stream: [
...(1)>   {:message_start, :assistant},
...(1)>   {:content_delta, "hello"},
...(1)>   {:content_delta, " world"},
...(1)>   {:message_end, :stop}
...(1)> ])
%ALLM.Engine{...}

iex(2)> {:ok, response} = ALLM.generate(engine, ALLM.request([ALLM.user("hi")]))
{:ok, %ALLM.Response{content: "hello world", finish_reason: :stop, ...}}

iex(3)> response.content
"hello world"
```

Verifies that `generate/3` reduces a streamed Fake script into a `%ALLM.Response{}`
with the concatenated content and the correct finish_reason.
````

### What to exercise per layer

#### Layer A — Serializable data

For every struct touched, in IEx:

```elixir
iex> msg = ALLM.user("hello")
iex> bin = :erlang.term_to_binary(msg)
iex> ^msg = :erlang.binary_to_term(bin)         # round-trips through ETF
iex> json = Jason.encode!(msg)
iex> ^msg = json |> Jason.decode!() |> ALLM.Message.from_json!()   # round-trips through JSON
```

If either round-trip fails, that's a Layer A invariant violation — blocking finding.

For tagged unions (`ALLM.Event`), exercise at least one constructor for every variant the change touches.

#### Layer B — Runtime

For every behaviour or engine change, in IEx:

```elixir
iex> engine = ALLM.Providers.Fake.engine(reply: "ok")
iex> :erlang.term_to_binary(engine)              # engine itself must be serializable
iex> # ... use the engine in a Layer C call ...
```

If the engine carries a fun, an anonymous function, or a Finch ref directly, `:erlang.term_to_binary/1` will fail (or succeed and then fail to round-trip across nodes). Spec §6.4 — keys resolve at adapter-call time, never on the engine.

#### Layer C — Stateless execution

For every `generate/3`, `step/3`, `chat/3` and their streaming variants:

1. Stateless call against Fake — confirm the happy path returns the documented shape.
2. Streaming call against the same Fake script — confirm the events match.
3. **Stream-equivalence check**: collect the streaming result and compare to the non-streaming result. They must match exactly.

```elixir
iex> {:ok, stream} = ALLM.stream_generate(engine, request)
iex> events = Enum.to_list(stream)
iex> {:ok, response} = ALLM.generate(engine, request)
iex> ^response = ALLM.StreamCollector.collect(events)
```

4. Trigger one error from the Error Contract:

```elixir
iex> bad_engine = ALLM.Providers.Fake.engine(error: {:authentication_failed, "no key"})
iex> {:error, %ALLM.Error.AdapterError{reason: :authentication_failed}} =
...>   ALLM.generate(bad_engine, request)
```

5. **Cleanup check** for any new stream:

```elixir
iex> {:ok, ref} = ALLM.Providers.Fake.tracked_engine()
iex> {:ok, stream} = ALLM.stream_generate(ref.engine, request)
iex> _ = stream |> Enum.take(1)            # halt early
iex> Process.sleep(100)
iex> ALLM.Providers.Fake.released?(ref)    # must be true
true
```

#### Layer D — Stateful continuation

For every `Session` operation:

1. Start a session, call the operation, inspect the returned session.
2. **Round-trip the session** through `:erlang.term_to_binary/1`.
3. Resume from the round-tripped session and confirm the next operation works.
4. For `{:ask_user, ...}` suspension (spec §12.3): trigger it, persist the suspended session, resume it, confirm the loop continues correctly.
5. Exercise both `:auto` and `:manual` orchestration modes if the change touches the orchestration loop.

```elixir
iex> {:ok, session} = ALLM.Session.start(engine, [ALLM.user("hello")])
iex> persisted = :erlang.term_to_binary(session)
iex> ^session = :erlang.binary_to_term(persisted)
iex> {:ok, next} = ALLM.Session.reply(session, "follow-up")
iex> next.thread.messages |> Enum.map(& &1.role)
[:user, :assistant, :user, :assistant]
```

---

## 4. Doctest Verification

Doctests run under `mix test` (already covered by §2), but they're easy to miss when reviewing prose around the example. For every `@doc` block touched in the diff:

1. Open the source file. Read the `@doc`.
2. Copy the `iex>` lines into the running IEx session.
3. Confirm the output matches what the doc claims.

If the doc has prose like "this returns a list of messages" and the doctest shows `{:ok, [...]}`, the prose is wrong. Find every drift between prose and behavior.

A doctest that hasn't been touched by the diff but is in a file the change modifies is still worth a quick paste — touched files are exactly where stale docs hide.

---

## 5. Behaviour Conformance

If the change adds or modifies an `@callback` in a behaviour module (`ALLM.Adapter`, `ALLM.StreamAdapter`, `ALLM.ToolExecutor`, `ALLM.ToolResultEncoder`):

1. Confirm `ALLM.Providers.Fake` implements the new/changed callback.
2. Confirm the conformance test suite (`test/support/<behaviour>_conformance.ex`) has a test for the new behaviour.
3. Confirm every real provider adapter in `lib/allm/providers/` either implements the callback or has a documented reason it doesn't (e.g., "Anthropic doesn't support function calling at v1, returns `{:error, :unsupported}`").

A behaviour change that lands without updating Fake is a blocker — the Fake is the reference implementation.

---

## 6. Real Provider Smoke Tests (when applicable)

For changes touching `lib/allm/providers/openai.ex`, `lib/allm/providers/anthropic.ex`, or other real-provider adapters, run the integration tests:

```bash
# Set the API key the test expects
export OPENAI_API_KEY=sk-...
mix test --only integration test/allm/providers/openai_integration_test.exs
```

Integration tests are tagged `@tag :integration` and excluded by default in `mix.exs`. They:

- Hit the real provider endpoint.
- Make a minimal request (cheapest model, short prompt — typically < $0.001 per run).
- Verify the wire format matches what the adapter expects.
- **Are not run in CI** without a configured key. Don't merge a change that requires an integration test pass without confirming the user has the key and is willing to spend the cents.

If the user can't or won't provide a key, document the integration test as not run and explain the risk: "wire format change in OpenAI adapter; integration test not run because no key available; recommend running before deploying to a downstream app".

**Never commit API keys.** If a key appeared in a test fixture, that's a blocker — flag it and tell the user to rotate.

---

## 7. Streaming-Specific Checks

For any change to `lib/allm/stream/` or any function that returns a `Stream.t()`:

### SSE Parser

If `lib/allm/stream/sse.ex` changed, exercise it directly in IEx with edge cases:

```elixir
iex> ALLM.Stream.SSE.decode("data: hello\n\n")
[%{data: "hello"}]
iex> ALLM.Stream.SSE.decode("data: hel")    # event split across chunks
{:incomplete, "data: hel"}
iex> ALLM.Stream.SSE.decode_continue("lo\n\n", "data: hel")
[%{data: "hello"}]
iex> ALLM.Stream.SSE.decode("data: a\n\ndata: b\n\n")   # multiple events in one chunk
[%{data: "a"}, %{data: "b"}]
```

### Cleanup

Every new `Stream.resource/3` gets the cleanup test from §3 above. No exceptions.

### Backpressure

If the change affects how chunks are buffered or how the consumer drives the stream, document the backpressure characteristics in the review:

- What happens when the consumer is slow (events buffer in the producer process)?
- What happens when the network is slow (the Finch stream blocks)?
- What happens when both are slow (the slowest dominates)?

Spec §7.2 — HTTP/1, not HTTP/2. If the diff changed this, that's a blocker (requires a spec amendment).

---

## 8. Spec Drift Check

Open `steering/allm_engine_session_streaming_spec_v0_2.md`. For every spec section the change touches (the design doc lists them in the Overview):

1. Read the relevant section.
2. Compare to the implementation.
3. Note any drift in the review doc.

If the implementation deviates from the spec deliberately, the design doc must justify it AND there must be a spec amendment in the same PR. An undocumented deviation is a blocker.

If the implementation matches the spec but the spec has a gap (e.g., the spec doesn't say what happens when a tool returns `{:error, :timeout}` and the impl chose a behavior), that's a finding — the spec should be amended to lock in the choice.

---

## 9. CHANGELOG and Documentation

For every public-API change:

- [ ] `CHANGELOG.md` has a one-line entry under the unreleased section
- [ ] Every new public function has an `@doc` with a runnable doctest using `ALLM.Providers.Fake`
- [ ] Every new behaviour callback has a `@doc` (not just on the behaviour module — on the callback itself)
- [ ] Every new error reason is documented in the function's `@doc` under an "Errors" section
- [ ] `README.md` examples still work (paste them into IEx)
- [ ] ExDoc renders without warnings: `mix docs` and inspect `doc/` output for malformed sections

---

## 10. Review Document Format

The review doc IS the artifact. It must be self-contained evidence. Include:

1. **Summary** — what changed (1-2 sentences), which spec sections (§-numbers), which layers (A/B/C/D).
2. **Quality Gate Stack** — every command from §2 with its full output.
3. **IEx Sessions** — every session from §3, in fenced `elixir` code blocks, each with a 1-2 sentence narration of what it proves.
4. **Doctest Verification** — list of files whose `@doc` blocks were re-pasted into IEx, with any drift findings.
5. **Behaviour Conformance** — confirmation that Fake implements every changed callback, with the conformance test output.
6. **Integration Tests** (if applicable) — command, output, cost incurred.
7. **Spec Drift** — section-by-section comparison for every §-number the change touches.
8. **Findings** — bulleted list of issues, each with severity (Blocker / Finding / Nit), file path, line number, proposed fix.
9. **Checklist** — copy from §11, with each box checked or explicitly marked N/A.

### Narration Format

Every IEx session needs a one-to-two-sentence narration explaining what it proves. A session block without narration is decoration; narration without a session is unverifiable.

````markdown
```elixir
iex(1)> {:ok, session} = ALLM.Session.start(engine, [ALLM.user("hi")])
iex(2)> persisted = :erlang.term_to_binary(session)
iex(3)> resumed = :erlang.binary_to_term(persisted)
iex(4)> {:ok, next} = ALLM.Session.reply(resumed, "follow-up")
iex(5)> length(next.thread.messages)
4
```

Proves that a `Session` survives a binary round-trip mid-conversation and that
`reply/4` correctly extends the resumed thread (4 messages: initial user,
assistant reply, follow-up user, assistant reply). Confirms Layer D
serializability invariant holds across the new `reply/4` change.
````

---

## 11. Review Checklist

Before completing a review:

- [ ] `mix format --check-formatted` passes
- [ ] `mix compile --warnings-as-errors` passes
- [ ] `mix test --cover --include doctest` passes; coverage ≥80% global, ≥90% on changed files
- [ ] `mix credo --strict` passes with zero issues on changed files
- [ ] `mix dialyzer` passes with zero new warnings
- [ ] Every public function in the diff was exercised in IEx with the happy path
- [ ] Every error reason in the function's Error Contract was triggered in IEx
- [ ] Every Layer A struct touched round-trips through `:erlang.term_to_binary/1` and JSON
- [ ] Every new `Stream.resource/3` has a cleanup test that fires on early consumer halt
- [ ] Every non-streaming wrapper has a stream-equivalence check (collected stream == direct call)
- [ ] Every `@doc` block in the diff was re-pasted into IEx; prose matches behavior
- [ ] Every `@callback` change is reflected in `ALLM.Providers.Fake`
- [ ] Every spec section listed in the design doc was diff-checked against the implementation
- [ ] CHANGELOG.md updated for every public-API change
- [ ] No API keys, secrets, or PII in test fixtures or doctests
- [ ] Integration tests run (or explicitly skipped with documented risk) for real-provider changes
- [ ] All findings in the review doc are tagged Blocker / Finding / Nit with proposed fixes

---

## 12. Common Blockers

| Blocker | Resolution |
|---------|-----------|
| `mix dialyzer` slow on first run | Wait it out (1-2 min PLT build). Don't skip. Subsequent runs are seconds. |
| Coverage dropped below 90% on new code | Add tests for the uncovered lines. If a line is genuinely untestable, document why with a comment. |
| Doctest drifts from prose | Update the prose. The behavior is the source of truth. |
| `:erlang.term_to_binary/1` fails on a Layer A struct | Find the offending field — it's a fun, ref, PID, or anonymous closure. Refactor to a module + atom. Spec §6.4. |
| Engine round-trip fails | Same root cause as Layer A. Engines must be serializable too. |
| Stream-equivalence check fails | The non-streaming wrapper isn't reducing the stream correctly, OR the streaming variant emits events the reducer doesn't handle. Either is a blocker. |
| Behaviour callback added but `Fake` not updated | Update `ALLM.Providers.Fake`. The Fake is the reference implementation. |
| Real-provider integration test fails | Check the spec — did the provider change their wire format? If so, this is a design issue, not a test issue. Stop and ask the user. |
| Spec drift | The design doc must justify it AND a spec amendment must be in the same PR. Otherwise blocker. |
| API key in a test fixture or commit | Rotate the key immediately. Tell the user. Block the merge. |
| `middleware:` field added | Reserved for v0.3 (spec §29). Reject the change. |
| HTTP/2 used for streaming | Change to HTTP/1 (spec §7.2 documents the Finch HTTP/2 flow-control bug). |
| `term()` in an `@spec` for an error type | Replace with the error struct type. `term()` says the error contract isn't designed. |
| Test uses `Bypass` or HTTP mocks for orchestration logic | Replace with `ALLM.Providers.Fake`. Network mocks for orchestration are forbidden by CLAUDE.md. |
