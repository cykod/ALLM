# Phase 21: Guide-Drift Corrections + `Engine.new/1` Fail-Fast Validation — Design Document

> **Goal:** Bring the bundled `guides/*.md` back into agreement with the real 0.4.x API, add fail-fast validation so a malformed engine field can't crash deep in the tool runner, and make guide `iex>` examples execute under `mix test` so the drift cannot silently recur.
> **Outcome ("done"):** Every corrected guide example runs green as a `doctest_file`; `ALLM.Engine.new/1` raises a clear `ArgumentError` on a non-module module-typed field instead of a late crash at `tool_runner.ex`; `mix test`, `mix credo --strict`, `mix dialyzer`, `mix format --check-formatted` all pass.
> **Spec sections:** §5.2 (tool handlers), §6.3/§6.4 (engine fields, param resolution), §8 (event union), §10 (request building / dispatch opts), §12.3 (ask-user / manual flow), §20/§35.4 (`EngineError`), §31 (Fake scripting).
> **Layers touched:** B (Engine runtime — Phase 1), C (orchestration request-builder — Phase 4). Phases 2–3 are **documentation + test-infrastructure**, not library-layer changes.

## Status

| Phase | Description | Layer | Status |
|-------|-------------|-------|--------|
| 1 | `Engine.new/1` fail-fast validation of module-typed fields | B | Completed |
| 2 | Correct the cataloged guide-content drift (sessions, tools, streaming, getting_started, image_generation) | Docs | Completed |
| 3 | Execute Fake-based guide `iex>` blocks via `doctest_file` (recurrence prevention) | Test infra | Completed |
| 4 | Wire `max_tokens`/`temperature`/sampling params from engine params + call opts onto the built `%Request{}` | C | Completed |

**Overall Progress:** 4/4 phases complete

> **Severity note:** Phase 4 is the **highest-severity** item — a silent correctness bug, not a docs/DX issue. Every `chat/3` / `stream/3` / `Session.*` turn currently ships the Anthropic adapter's `max_tokens: 1024` default regardless of `engine.params` or call opts, because the orchestration request-builder drops those params. A multi-tool turn that exceeds 1024 tokens truncates (`finish_reason: :length`) and the loop does not execute tools from a non-`:tool_calls` finish → **zero tool results despite correct model output**. There is no clean caller-side workaround through the chat/session loop today.

---

## Overview

A downstream consumer (MonvieCore) exercised the pinned `allm 0.4.3` package against the Fake adapter and recorded executed-evidence facts in `steering/ALLM_VERIFIED_FACTS.md`. Those facts surfaced that the bundled `guides/*.md` have drifted from the real API in load-bearing ways: session functions are documented session-first / 2-tuple when the code is engine-first / 3-tuple; the tool-executor configuration shown on the engine (`tool_executor: {ALLM.ToolExecutor.Default, tools: %{…}}`) is a shape the code never supported and crashes at `lib/allm/tool_runner.ex:532`; the session status atoms, `StreamReducer` API, JSON round-trip semantics, and streaming event names are all wrong in one or more guides. **The in-module `@doc` examples are already correct** — only the standalone guide markdown drifted, and it drifted silently because `test/guides_test.exs` never executes the `iex>` blocks (it only checks existence, size, banned tokens, presence of ≥1 `iex>` line, and mix.exs wiring).

A separate, higher-severity bug was reported during review and confirmed by execution: the orchestration request-builder silently drops `max_tokens`/`temperature`, so every `chat/3` / `stream/3` / `Session.*` turn runs under the Anthropic adapter's `max_tokens: 1024` default no matter what the caller configures — truncating multi-tool turns and losing tool execution entirely.

This phase does four things: (1) a small, genuine **bug fix** — `Engine.new/1` fails fast on a non-module module-typed field so the documented mistake can't reach `tool_runner.ex:532`; (2) **corrects** the cataloged guide drift; (3) **closes the loop** by wiring the Fake-based guide examples into `doctest_file` so any future drift is a red test, not a silent ship; (4) the **highest-severity fix** — wire resolved sampling params (`max_tokens`, `temperature`) from `engine.params` + call opts onto the built `%Request{}` so the chat/stream/session loops honor them.

- **Deliverables**
  - `lib/allm/engine.ex` — `Engine.new/1` validates `:adapter`, `:tool_executor`, `:tool_result_encoder`, `:image_adapter` are each `nil` or an atom; raises `ArgumentError` otherwise.
  - Corrected `guides/sessions.md`, `guides/tools.md`, `guides/streaming.md`, `guides/getting_started.md` (and any residual `iex>` drift flushed by Phase 3 in the remaining guides).
  - `test/engine_new_validation_test.exs` (NEW) — the bug-fix unit tests.
  - `test/guides_doctest_test.exs` (NEW) — `doctest_file` execution of the Fake-based guides.
  - `lib/allm/chat.ex` — `build_request/4` folds `Engine.resolve_params/2`'s `max_tokens`/`temperature`/opaque params onto the `%Request{}` (fixes the 1024-cap bug for `chat/3`, `stream/3`, and all `Session.*`).
  - `test/allm/chat_request_params_test.exs` (NEW) — proves resolved params reach `request.max_tokens`/`temperature` and the provider body.
- **Spec coverage** — refines documentation of §5.2/§6.4/§8/§12.3/§31; extends the §20/§35.4 `EngineError`/construction-validation surface with a construction-time guard (no new atom — see Decision 3).
- **Layer demonstration** — Layer B only (Phase 1):
  ```elixir
  # Before: silently constructs a booby-trapped engine; crashes later at tool_runner.ex:532
  # After: fails fast at the mistake site
  iex> ALLM.Engine.new(tool_executor: {ALLM.ToolExecutor.Default, tools: %{}})
  ** (ArgumentError) engine field :tool_executor must be a module (atom) or nil, got: {ALLM.ToolExecutor.Default, [tools: %{}]}
  ```
  Layer C (Phase 4) — the same config now reaches the wire on the orchestration paths:
  ```elixir
  engine = ALLM.Engine.new(adapter: ALLM.Providers.Anthropic, model: "claude-sonnet-4-6",
                           params: %{max_tokens: 8192})
  # Before: chat/stream/session shipped max_tokens: 1024 regardless. After: 8192.
  {:ok, %ALLM.ChatResult{}} = ALLM.chat(engine, [ALLM.user("extract every field…")])
  # per-call override still wins: ALLM.chat(engine, thread, max_tokens: 4096)
  ```
  Phases 2–3 touch no library layer — they edit prose/examples and add a test module.
- **Prerequisites** — none. Works against HEAD (`lib/allm/session.ex`, `lib/allm/tool.ex`, `lib/allm/engine.ex`, `lib/allm/event.ex`, `lib/allm/session/stream_reducer.ex` all as-is).
- **Out of scope** (with justification)
  - **Fake `%Response{model: nil}` (fact 15).** Spec'd Fake behavior; changing it risks breaking existing tests that assert `nil`. Consumers already use `engine.model` as `fallback_model`. Document the workaround only if a guide is misleading; no code change.
  - **Mid-stream `{:error, _}` not terminating the stream (fact 3).** This is a *core ALLM invariant* (`CLAUDE.md`: "Mid-stream adapter errors fold into the response, not the call-site tuple"), not a bug. At most a one-line note in `errors_and_retries.md`.
  - **Concurrent multi-tool ack nondeterminism (fact 17).** Spec'd; already order-tolerant by contract. Optional one-line note in `tools.md`; no code change.
  - **Per-engine Fake cursor (fact 13).** Already documented in `Engine.new/1`'s `@doc` and `fakes.md`. No change.
  - **`resolve_executor/1` hardening for hand-built `%Engine{…}` struct literals.** A `%Engine{tool_executor: {…}}` struct literal bypasses `new/1` entirely; guarding that path would introduce a *second* failure shape (`{:error, %EngineError{}}`) for the same error class. The guide path uses `Engine.new/1`; that's what we cover. See Alternative A.
  - **`README.md`.** Not in the Module Tree; per `CLAUDE.md` README is never modified inside a phase that doesn't list it. `git stash README.md` at phase start if it drifts in.
- **Non-obvious decisions**
  1. **The bug fix raises `ArgumentError`, not `{:error, %EngineError{}}`.** `Engine.new/1` returns a bare `%Engine{}` (callers write `engine = Engine.new(...)`); returning an error tuple is a breaking contract change. Construction-time raising is consistent with `struct!/2`'s existing `KeyError` on unknown keys. *Docs target: @doc ALLM.Engine.new/1.*
  2. **The guard is `is_atom/1`, not `Code.ensure_loaded?/1`.** The field type is `module() | nil`, which at the type level is just "atom or nil." A tuple (the actual bug) fails `is_atom/1`; a not-yet-loaded module or a test double defined later still passes. A load check would over-reject legitimate optional-dep / late-defined-module patterns. *Docs target: @doc ALLM.Engine.new/1.*
  3. **No new `EngineError` reason atom.** The construction guard raises `ArgumentError`; it never constructs an `EngineError`. The existing `:invalid_engine` reason (`lib/allm/error/engine_error.ex:19`) stays reserved for adapter-call-time tuple returns. Adding an orphan atom would violate `AGENT_DESIGN_SPEC.md` rule 13. *Docs target: internal — no user-facing docs needed.*
  4. **Guides become executable via `doctest_file` (verified working in IEx on 2026-07-13).** `ExUnit.DocTest.doctest_file/1,2` is a public macro in Elixir 1.17.3 (`macro_exported?(ExUnit.DocTest, :doctest_file, 1) == true`; a minimal markdown+test ran green). Only `iex>` blocks execute; ` ```elixir ` fenced blocks (used for real-provider illustrations) are ignored — so provider-key-dependent snippets stay safe. *Docs target: CHANGELOG entry only.*
  5. **ETF pin-match stays; JSON pin-match goes.** Fact 7: ETF round-trip is `==` (so `sessions.md:167`'s `^session = :erlang.binary_to_term(binary)` is *correct* and stays), but JSON restore is not `==` (so `sessions.md:103`'s `{:ok, ^session} = ALLM.Serializer.from_json(json)` is wrong and must become a field assertion). *Docs target: @doc — guide prose.*
  6. **Phase 4 fixes the request-builder, not the adapters.** The `%Request{}` is the provider-neutral carrier of body params; adapter body-builders already read `request.max_tokens`/`request.temperature`/`request.options` (e.g. `anthropic.ex:581-596`). The bug is that `Chat.build_request/4` never populates them from resolved params. Fixing the single shared builder repairs `chat/3`, `stream/3`, AND `Session.*` at once and is provider-neutral; wiring `translate_options/2` into each adapter body-builder (its intended-but-unused role) would duplicate precedence logic across three adapters (and OpenAI's two translators). See Alternative D. *Docs target: @doc ALLM.chat/3 + CHANGELOG entry.*

---

## Behaviour & Type Contracts

Only Phase 1 changes a contract. Phases 2–3 add no types or callbacks.

### `ALLM.Engine.new/1` (MODIFY — `lib/allm/engine.ex:176-180`)

```elixir
# Layer B — runtime
@module_fields [:adapter, :tool_executor, :tool_result_encoder, :image_adapter]

@spec new(keyword()) :: t()   # unchanged signature and return type
def new(opts \\ []) do
  engine = struct!(__MODULE__, opts)          # unchanged: KeyError on unknown keys
  :ok = validate_module_fields!(engine)       # NEW
  %{engine | id: engine.id || System.unique_integer([:positive])}
end

# Raises ArgumentError naming the first offending field when a module-typed
# field carries a non-atom, non-nil value (nil is an atom -> passes).
@spec validate_module_fields!(t()) :: :ok
defp validate_module_fields!(%__MODULE__{} = engine) do
  Enum.each(@module_fields, fn field ->
    case Map.fetch!(engine, field) do
      value when is_atom(value) -> :ok       # nil and any module both pass
      value ->
        raise ArgumentError,
              "engine field #{inspect(field)} must be a module (atom) or nil, " <>
                "got: #{inspect(value)}"
    end
  end)
  :ok
end
```

**Invariants**
- **Nil-safe:** `is_atom(nil) == true`, so every currently-legal engine (all four fields default to `nil`) still constructs unchanged. Verified: `is_atom(nil) → true`, `is_atom(ALLM.ToolExecutor.Default) → true`, `is_atom({ALLM.ToolExecutor.Default, []}) → false` (in IEx on 2026-07-13).
- **Field set is exhaustive over module-typed scalar fields.** The engine's `module() | nil` fields are exactly `:adapter`, `:tool_executor`, `:tool_result_encoder`, `:image_adapter` (`lib/allm/engine.ex:92,96,97,98`). `:middleware` is `[module()]` and must stay `[]` in v0.2 (§29) — not validated here (out of scope; empty-list default is inert).
- **Only the `new/1` path is guarded.** Struct-update helpers (`with_model/2`, `merge_opts/2`, `put_tool/2`) don't touch these fields with untrusted values; hand-built `%Engine{…}` literals bypass the guard by design (see Alternative A).
- **Error class:** `ArgumentError` (stdlib) — verified idiomatic against the existing `struct!/2` `KeyError` posture documented at `lib/allm/engine.ex:148-149`.

### `ALLM.Chat.build_request/4` (MODIFY — `lib/allm/chat.ex:1998-2018`) — Phase 4

```elixir
# Layer C — orchestration request-builder (shared by chat/3 non-streaming @203 and stream/3 @304)
defp build_request(%Thread{messages: msgs}, %Engine{} = engine, opts, flags) do
  # Precedence: call opts > engine.params (Engine.resolve_params/2 owns this; see chat.ex:313).
  params = Engine.resolve_params(engine, opts)            # => map, engine-field keys already denied

  # Route the two typed sampling fields onto typed Request fields; the remainder
  # (top_p, etc.) rides on request.options, which adapter body-builders merge.
  {typed, opaque} = Map.split(params, [:max_tokens, :temperature])

  base =
    [
      tools: Engine.resolve_tools(engine, opts),
      stream: Keyword.get(flags, :stream, false),
      max_tokens: Map.get(typed, :max_tokens),           # nil when unset => adapter default still applies
      temperature: Map.get(typed, :temperature),
      options: drop_request_carried_keys(opaque)         # avoid double-carrying response_format/tool_choice
    ]

  # extra (response_format, tool_choice) and structured unchanged — still read from opts.
  Request.new(msgs, base ++ extra ++ structured)
end
```

**Invariants & required verification**
- **Precedence unchanged:** `Engine.resolve_params/2` already merges `engine.params` with call opts, opts winning (`chat.ex:313` documents "call opts > `engine.params`"). Phase 4 does not re-implement precedence — it consumes the resolved map. **Verify** at impl time exactly which keys `resolve_params/2` returns after its engine-field deny-list (`engine.ex:129-143`) and which it strips, so `opaque` doesn't re-carry `:response_format`/`:tool_choice`/orchestration keys that `extra`/`structured` already handle (that's what `drop_request_carried_keys/1` guards; confirm the key list against the deny-list + `extra`/`structured` keys).
- **`nil`-preserving:** when neither `engine.params` nor opts set `max_tokens`, `typed[:max_tokens]` is absent → `Request.new` sets `max_tokens: nil` → adapter default (Anthropic 1024) still applies. No behavior change for callers who never set it. This keeps the documented "Anthropic injects 1024 if nil" contract (`request.ex:18`) intact as the *floor*, not a *cap*.
- **Fixes both paths + sessions:** `build_request/4` is the single builder for `do_step/4` (non-streaming, `chat.ex:203`) and `do_stream_step_call/3` (streaming, `chat.ex:304`); `Session.*` composes `Chat.run`/`Chat.stream`. One fix repairs all.
- **Provider-neutral:** adapters already read `request.max_tokens`/`temperature`/`options` (Anthropic `anthropic.ex:587,593,595`; verify OpenAI Chat-Completions + Responses and Gemini read the same request fields — cite each at impl time per the two-translator rule).
- **`request.options` merge order:** for Anthropic, `to_anthropic_request_body/1` does `Map.merge(base, stringify_options(request.options))` (`anthropic.ex:595`) — options win on key collision. Since `max_tokens` now lands on the typed field (not in `options`), there is no collision; keep `max_tokens` out of `opaque` (the `Map.split` above guarantees it).

---

## Module Tree

```
lib/allm/
├── engine.ex                          (MODIFY — 1: add validate_module_fields!/1 + @module_fields; extend new/1 @doc)
└── chat.ex                            (MODIFY — 4: build_request/4 folds resolved max_tokens/temperature/opaque params onto %Request{})

guides/
├── sessions.md                        (MODIFY — 2: engine-first 3-tuples, status atoms, StreamReducer API, JSON pin-match, submit_tool_result/continue)
├── tools.md                           (MODIFY — 2: handler-on-tool executor pattern, auto-loop doctest, streaming event names)
├── streaming.md                       (MODIFY — 2: reconcile event-shape table against lib/allm/event.ex)
├── getting_started.md                 (MODIFY — 2: capability-table Session return tuple; flush residual iex> drift via Phase 3)
└── image_generation.md                (MODIFY — 2: replace non-existent image_adapter_opts field + wrong image-script shape)

test/
├── engine_new_validation_test.exs     (NEW — 1: bug-fix unit tests)
├── guides_doctest_test.exs            (NEW — 3: doctest_file execution of Fake-based guides)
└── allm/
    └── chat_request_params_test.exs   (NEW — 4: resolved max_tokens/temperature reach %Request{} and provider body)

CHANGELOG.md                           (MODIFY — one line per public-API/behavior change)
```

**Path-existence sanity:** `guides/` and `test/` exist; all four guide targets exist on disk (verified). `test/guides_test.exs` (the structural checker) is left **as-is** — the new `test/guides_doctest_test.exs` complements it (execution) rather than replacing it.

**Completeness note:** Phase 3's `doctest_file` sweep may surface residual `iex>` drift in guides *not* listed as MODIFY above (`vision.md`, `errors_and_retries.md`, `multi_tenant_keys.md`). Fixing that residual drift is in-scope, fix-forward, and expands the MODIFY set for Phase 2's commit — the Module Tree floor, not ceiling. Each such guide, if edited, gets a `(MODIFY — 3 flush)` note in the commit body. (`image_generation.md` is a *known* — not residual — failure and is cataloged explicitly in §2.6.)

---

## Phase 1: `Engine.new/1` fail-fast module-field validation (Layer B)

**Goal:** A non-module value on a module-typed engine field fails at `Engine.new/1` with a clear `ArgumentError`, instead of silently constructing an engine that crashes at `lib/allm/tool_runner.ex:532` (`ctx.executor.execute(...)` on a tuple).

**Spec sections:** §6.4, §20/§35.4.

### 1.1 Test Plan (write first)

`test/engine_new_validation_test.exs` (NEW):

- `new/1 with tool_executor: {ALLM.ToolExecutor.Default, tools: %{}} raises ArgumentError` (the exact guide footgun) — assert with `assert_raise ArgumentError, ~r/:tool_executor/, fn -> … end`. The guard message is `"engine field #{inspect(field)} must be a module (atom) or nil, got: …"`, so `inspect(:tool_executor)` yields `":tool_executor"` (colon included); target the `inspect`ed form in the regex, don't assume a specific surrounding phrase.
- `new/1 with adapter: {Foo, []} raises ArgumentError naming :adapter`.
- `new/1 with tool_result_encoder: "JSON" (a string) raises ArgumentError`.
- `new/1 with image_adapter: %{} raises ArgumentError`.
- `new/1 with all four module fields nil constructs successfully` (regression: default engine unaffected).
- `new/1 with adapter: ALLM.Providers.Fake constructs successfully` (a real module passes).
- `new/1 with a not-yet-loaded module atom passes` — e.g. `adapter: :"Elixir.ALLM.NotLoadedYet"` constructs (guard is `is_atom/1`, not `Code.ensure_loaded?/1`).
- `existing engine doctests still pass` (via full suite in Verification).

### 1.2 Implementation Checklist

- [ ] Add `@module_fields [:adapter, :tool_executor, :tool_result_encoder, :image_adapter]` to `lib/allm/engine.ex`.
- [ ] Add `validate_module_fields!/1` per the contract; call it from `new/1` between `struct!/2` and the `:id` stamp.
- [ ] Extend `new/1`'s `@doc` to document the new raise (name the four fields; state `nil`-or-module rule); add one doctest asserting `ALLM.Engine.new(tool_executor: {…})` raises (`assert_raise ArgumentError` in the test file — doctests can't assert raises inline, so the raise example in `@doc` is prose + a `test/` assertion).
- [ ] Add a CHANGELOG line under an `## [Unreleased]` (pending) header — do **NOT** invent a version number or edit `mix.exs @version`; `scripts/release.exs` assigns both at release time (per `CLAUDE.md`). Line: "`Engine.new/1` now raises `ArgumentError` on a non-module `:adapter`/`:tool_executor`/`:tool_result_encoder`/`:image_adapter` (previously crashed at tool-run time)."
- [ ] Confirm no existing test constructs an engine with a tuple/string module field (grep `tool_executor:\s*{` across `test/` and `lib/` and `guides/` — the guides hits are fixed in Phase 2).

### 1.3 Verification

```bash
mix test test/engine_new_validation_test.exs
mix test                              # full suite green (no engine built with a bad module field anywhere)
mix credo --strict lib/allm/engine.ex
mix dialyzer
mix format --check-formatted
```

**Success criterion:** all four bad-field cases raise `ArgumentError` naming the field; every currently-passing engine construction is unaffected; full suite green.

---

## Phase 2: Correct the cataloged guide-content drift (Docs)

**Goal:** Every wrong signature, return shape, status atom, executor pattern, and event name in the four primary guides is corrected to match the real API. Corrected `iex>` examples must be Fake-based and self-contained so Phase 3 can execute them.

**Spec sections:** §5.2, §8, §12.3, §31.

### 2.1 Test Plan (write first)

Phase 2 has no new test file of its own — its verification is Phase 3's `doctest_file` execution plus the existing `test/guides_test.exs` (banned-token audit + structural checks stay green). During Phase 2, the implementer runs the banned-token audit after each edit:

```bash
mix test test/guides_test.exs
```

The behavioral proof that the corrected examples are *right* lands in Phase 3. Order note: Phase 2 and Phase 3 may be committed together per guide (fix content, then turn on its doctest) — see Phase 3.

**Commit-ordering invariant (binding).** Phase 1's guard turns the *pre-fix* `tools.md` example (lines 69–90, `tool_executor: {ALLM.ToolExecutor.Default, tools: %{…}}`) into a raising `Engine.new/1` call. Therefore **Phase 1 MUST be committed together with the `tools.md` executor fix (§2.3) and its `doctest_file` line (§3.1)** — never commit Phase 1 alone, or the tools.md guide example becomes a booby-trap the guard trips. More generally, a guide's `doctest_file` line (Phase 3) lands only in the same commit that fixes that guide's content (Phase 2); no guide is wired for execution before its content is corrected. This keeps every commit's `mix test` green (the per-phase gate).

### 2.2 `guides/sessions.md` edit table

| Line(s) | Wrong | Corrected |
|---------|-------|-----------|
| 5, 62–67 | Status union `:halted_for_tools` / `:halted_for_user` / `:terminated` | Real union `:idle \| :awaiting_user \| :awaiting_tools \| :completed \| :error` (`lib/allm/session.ex:131`). Map: tools→`:awaiting_tools`, user→`:awaiting_user`, terminated→`:completed` (+ add `:error` row: "fatal error; `ChatResult.halted_reason: :error`"). |
| 32 | `{:ok, session} = ALLM.Session.start(engine, …)` | `{:ok, session, _chat_result} = ALLM.Session.start(engine, …)` (3-tuple, `session.ex:234`). |
| 51–52 | `{:ok, session} = …start`; `{:ok, session} = ALLM.Session.reply(session, engine, "Bye.")` | `{:ok, session, _} = …start`; `{:ok, session, _} = ALLM.Session.reply(engine, session, "Bye.")` (engine-first 3-tuple, `session.ex:271`). |
| 56 | "Note `Session.reply/4` takes the engine again" | Keep the intent, but state engine is the **first** arg: "`reply/4` takes the engine as its first argument again — engines aren't persisted on the session." |
| 73 | `session.status == :halted_for_tools` | `session.status == :awaiting_tools`. |
| 78–79 | `{:ok, session} = submit_tool_result(session, "call_1", %{ok: true})`; `{:ok, session} = continue(session, engine)` | `session = ALLM.Session.submit_tool_result(session, "call_1", %{ok: true})` (returns bare `%Session{}` or `{:error, %SessionError{}}`, `session.ex:544`); `{:ok, session, _} = ALLM.Session.continue(engine, session, nil)` (engine-first 3-tuple, `session.ex:322`). |
| 103 | `{:ok, ^session} = ALLM.Serializer.from_json(json)` | `{:ok, restored} = ALLM.Serializer.from_json(json)` + assert a stable scalar field (e.g. `restored.status == session.status`), never a pin match — JSON restore is not `==` (fact 7; map-typed metadata/context return string-keyed). |
| 128–129 | `{:ok, session} = from_json(...)`; `{:ok, session} = reply(session, engine, user_input)` | `{:ok, session} = from_json(...)` (from_json IS a 2-tuple — correct); `{:ok, session, _} = ALLM.Session.reply(engine, session, user_input)`. |
| 134–147 | `ALLM.Session.StreamReducer.run(stream, fn event -> … end)` returning `{:ok, session, events}` | No `run/2` exists — only `new/2`, `apply_event/2`, `finalize/1` (`stream_reducer.ex:75,113,147`). Show the real fold (skeleton below). Keep the `Phoenix.PubSub` call inside a ` ```elixir ` fence (not `iex>`), AND add a **runnable Fake-based `iex>`** StreamReducer example. |
| 141 | `{:ok, stream} = ALLM.Session.stream_reply(session, engine, "Hello?")` | `{:ok, stream} = ALLM.Session.stream_reply(engine, session, "Hello?")` (engine-first, returns `{:ok, stream}`). |
| 160–168 | `{:ok, session} = ALLM.Session.start(engine, …)` inside the ETF round-trip doctest | `{:ok, session, _} = ALLM.Session.start(engine, …)`. **Keep** `^session = :erlang.binary_to_term(binary)` — ETF round-trip IS `==` (fact 7). |

**StreamReducer fold skeleton** (for the new runnable `iex>` block; note the reduce arg-order footgun — `apply_event/2` is `(reducer, event)`, `stream_reducer.ex:113`, but `Enum.reduce`'s fn is `(element, acc)`, so the fn is `fn event, reducer -> … apply_event(reducer, event) end`):

```elixir
iex> {:ok, stream} = ALLM.Session.stream_reply(engine, session, "Hello?")
iex> reducer = ALLM.Session.StreamReducer.new(session)
iex> reducer =
...>   Enum.reduce(stream, reducer, fn event, acc ->
...>     ALLM.Session.StreamReducer.apply_event(acc, event)   # side effects go here too
...>   end)
iex> {session, _result} = ALLM.Session.StreamReducer.finalize(reducer)
iex> session.status
:idle
```

The stream must be consumed **in full** before `finalize/1` — a fully-folded `:chat` stream normalizes `status` to `:completed`/`:idle` with `halted_reason: :completed`; a partially-consumed fold reports `halted_reason: :cancelled` (`stream_reducer.ex:148-151`). Assert a field that holds under full consumption, not `:cancelled`.

### 2.3 `guides/tools.md` edit table

| Line(s) | Wrong | Corrected |
|---------|-------|-----------|
| 40–54 | "The default tool executor … takes a map of tool-name → 1-arity function" + `tool_executor: {ALLM.ToolExecutor.Default, tools: %{…}}` | Handlers live **on the tool**: `ALLM.tool(name:, description:, schema:, handler: fn args -> {:ok, term} end)` (`lib/allm/tool.ex`, `tool_executor/default.ex:65-69`). Engine `:tool_executor` is a bare `module() \| nil` used only to *override* the default executor module; you never pass a `tools:` map to it. Rewrite the section around `handler:`; drop the `{module, tools: %{}}` tuple entirely. |
| 69–90 | Auto-loop doctest: `tool_executor: {ALLM.ToolExecutor.Default, tools: %{…}}` + tool_call script `{:tool_call, %{id:, name:, args:}}` (map, `args:`) | Move the handler onto the tool via `handler:`; drop `tool_executor:` from the engine. **The tool-call script must be the keyword form** `{:tool_call, id: "call_1", name: "get_weather", arguments: %{"city" => "Boston"}}` — `lib/allm/providers/fake/script.ex:290` guards `when is_list(kw)` (a **map** payload fails outright) and reads `Keyword.fetch!(kw, :id)`, `Keyword.fetch!(kw, :name)`, `Keyword.get(kw, :arguments, %{})` (script.ex:291-294). The guide's `%{…, args:}` map is doubly wrong: it's not a keyword list, and `args:` is never read (silently defaults to `%{}`). `arguments` must be **string-keyed** (fact 14). Phase 3 executes this block, so the shape is enforced by `mix test`. |
| 108–112 | `ALLM.Engine.new(adapter: …, model: …, mode: :manual)` | `:mode` is **not** an `%Engine{}` field (would raise `KeyError` from `struct!/2`) — it's a per-call opt (`session.ex` `session_opts`, `~L149`). Move `mode: :manual` to the call site (`ALLM.chat(engine, req, mode: :manual)`), or describe it as a call opt. Fenced ` ```elixir ` block, so not doctested — but still wrong content in a guide this phase edits. |
| 145 | `metadata.manual_tool_calls` / `Session.pending_tool_calls` prose | Verify field paths against `lib/allm/chat.ex` and `session.ex` (fact 9: tool calls live in `metadata.tool_calls`; pending on `session.pending_tool_calls`). Correct if drifted. |
| 190–196 | Streaming tool events `:tool_call_delta` → `:tool_call` → `:tool_result` | Reconcile against `lib/allm/event.ex` closed union: `:tool_call_completed` (not `:tool_call`); tool execution surfaces as `:tool_execution_completed` + `:tool_result_encoded` (no `:tool_result`). Cross-reference `streaming.md` (2.4). |

### 2.4 `guides/streaming.md` edit

Reconcile the event-shape table **row by row** against the closed union in `lib/allm/event.ex` (cite `event.ex:81-88` for the tag set). The implementer verifies each row against the source constructors — do **not** transcribe from memory or from the audit summary. Known-suspect rows to check: any `:request_started`, `:tool_call` (vs `:tool_call_completed`), `:tool_result` (vs `:tool_execution_completed`/`:tool_result_encoded`), `:halted` (vs `:step_completed`/`:chat_completed`). The real closed set (per `event.ex`): `:message_started, :text_delta, :text_completed, :tool_call_started, :tool_call_delta, :tool_call_completed, :tool_execution_started, :tool_execution_completed, :tool_result_encoded, :ask_user_requested, :tool_halt, :message_completed, :step_completed, :chat_completed, :raw_chunk, :error`. Any `iex>` block in the guide must remain Fake-based and runnable.

### 2.5 `guides/getting_started.md` edit

| Line | Wrong | Corrected |
|------|-------|-----------|
| 128 | Capability table: "Multi-turn … `ALLM.Session.*` … `{:ok, %Session{}}`" | `{:ok, %Session{}, %ChatResult{}}` (3-tuple). |

Its three `iex>` blocks (ten `iex>` lines: ~36–43, ~102–113, ~207–214) are Fake-based; Phase 3 flushes any residual issue. Real-provider "Swap to a real provider" snippets (lines 137+) are ` ```elixir ` fences and stay untouched.

### 2.6 `guides/image_generation.md` edit (known Phase-3 blocker)

Both `iex>` blocks (~43–54 and ~129–142) construct the engine with a **non-existent field** and a **wrong script shape** — as written they raise `KeyError` from `struct!/2` before `generate_image/3` runs, so Phase 3 cannot go green without this fix.

| Wrong | Corrected |
|-------|-----------|
| `ALLM.Engine.new(image_adapter: FakeImages, image_adapter_opts: [scripts: [[{:ok, %{images: [%ALLM.Image{…}]}}]]])` | `ALLM.Engine.new(image_adapter: ALLM.Providers.FakeImages, adapter_opts: [image_script: [{:ok, [%ALLM.Image{…}]}]])` |

Two corrections: (1) `image_adapter_opts:` is not an `%Engine{}` field — image-adapter options ride on **`adapter_opts:`** with the **`image_script:`** key; (2) the `FakeImages` script body is a bare **list of `%ALLM.Image{}`** (`{:ok, [img]}`), not a `%{images: […]}` map. Mirror the canonical shape in `lib/allm.ex:769-771` and `test/allm/allm_generate_image_test.exs:69`. Verify the corrected block against the `FakeImages` script contract at impl time (Phase 3 executes it).

### 2.7 Verification

```bash
mix test test/guides_test.exs        # banned-token audit + structural checks stay green
mix format --check-formatted
```

**Success criterion:** every row in 2.2–2.6 is applied; no `iex>` block in the edited guides references a real provider (all such examples are ` ```elixir ` fences); `guides_test.exs` green. Behavioral correctness is proven by Phase 3.

---

## Phase 3: Execute Fake-based guide `iex>` blocks via `doctest_file` (Test infra)

**Goal:** Wire the Fake-based guides into `doctest_file` so their `iex>` examples run under `mix test`. This is the durable fix: from now on, a wrong signature in a guide is a failing test, not a silent ship.

**Spec sections:** §31 (Fake is the canonical test vehicle).

### 3.1 Test Plan (write first)

`test/guides_doctest_test.exs` (NEW):

```elixir
defmodule GuidesDoctestTest do
  use ExUnit.Case, async: true
  # doctest_file runs every `iex>` block in the referenced markdown as a doctest.
  # Only Fake-based guides are wired here; real-provider snippets in these guides
  # are ```elixir fences and are ignored by doctest_file.
  doctest_file "guides/getting_started.md"
  doctest_file "guides/sessions.md"
  doctest_file "guides/tools.md"
  doctest_file "guides/streaming.md"
  doctest_file "guides/vision.md"
  doctest_file "guides/image_generation.md"
  doctest_file "guides/errors_and_retries.md"
  doctest_file "guides/multi_tenant_keys.md"
end
```

- Each `doctest_file` line contributes N doctests (one per `iex>` block). The test module must compile and run green.
- **Fix-forward:** any guide whose `iex>` blocks were not in Phase 2's catalog but still fail (residual drift) is corrected in this phase; the guide is added to Phase 2's commit-body MODIFY list.
- Guard against unrunnable blocks: any `iex>` block that *cannot* be made to run with Fake (e.g. needs `Phoenix.PubSub`, a real key, or external state) must be **converted to a ` ```elixir ` fence** in Phase 2 rather than left as a failing doctest. `doctest_file` has no per-block skip; the lever is the `iex>`-vs-fence choice.

### 3.2 Implementation Checklist

- [ ] Add `test/guides_doctest_test.exs` with one `doctest_file` per guide (start with the Phase-2-cataloged guides — sessions, tools, streaming, getting_started, image_generation; add the rest incrementally, fixing residual drift as each turns red).
- [ ] For each red block: fix the guide (Phase 2 fix-forward) OR convert to a ` ```elixir ` fence if it's inherently unrunnable; never leave a `@tag`-less failing doctest.
- [ ] Confirm `async: true` is safe — Fake adapter uses per-engine cursor keys (fact 13), so parallel guide doctests don't share cursor state. If any guide relies on a shared process-dict cursor, set that module `async: false` (unlikely; note in commit if needed).
- [ ] Do **not** delete or weaken `test/guides_test.exs` — the two are complementary (structure vs execution).

### 3.3 Verification

```bash
mix test test/guides_doctest_test.exs
mix test                              # full suite green
mix format --check-formatted
```

**Success criterion:** every `iex>` block in every wired guide runs green under `mix test`; the number of doctests reported is ≥ the sum of `grep -c 'iex>'` across the wired guides (blocks may split); zero failures.

---

## Phase 4: Wire sampling params onto the built `%Request{}` (Layer C)

**Goal:** `engine.params` and call opts for `max_tokens`/`temperature` reach the provider request body on the `chat/3`, `stream/3`, and `Session.*` paths — so a caller who sets `max_tokens: 8192` gets 8192, not the Anthropic adapter's 1024 default. Eliminates the silent-truncation → lost-tool-execution failure.

**Spec sections:** §6.3 (param resolution), §10 (request building / dispatch opts).

**Root cause (verified in IEx on 2026-07-13):** `Chat.build_request/4` (`chat.ex:1998-2018`) builds the `%Request{}` from only `tools`/`stream`/`response_format`/`tool_choice`/`structured_finalize` — never `max_tokens`/`temperature`. `StreamRunner.build_dispatch_opts/2` (`stream_runner.ex:222-245`) *does* resolve `engine.params` into `params_kw` but forwards them to `adapter.stream(request, dispatch_opts)` as **opts**, and no adapter reads opts into the body (`translate_options/2` is defined on every adapter but has **no call site** in the dispatch path — `grep -n "translate_options" lib/` shows only defs and docs). The Anthropic body-builder reads `request.max_tokens || 1024` (`anthropic.ex:587`). Reproduction: `engine = Engine.new(adapter: Anthropic, model: "…", params: %{max_tokens: 4096})`; the chat-built request has `max_tokens: nil` and `to_anthropic_request_body/1` emits `"max_tokens" => 1024`.

**Downstream symptom (verified):** a truncated turn returns `finish_reason: :length`; `Chat`'s step logic runs tools only on `:tool_calls` (`chat.ex:143, 1038-1045`) and the terminal condition treats `:length` as `{:halt, :completed}` (`chat.ex:943`). So a multi-tool turn that blows past 1024 tokens truncates and executes **zero** tools even though the emitted content was correct.

### 4.1 Test Plan (write first)

`test/allm/chat_request_params_test.exs` (NEW) — driven by `ALLM.Providers.Fake` for orchestration + a direct Anthropic body-builder assertion for the wire proof:

- `build_request via chat/3 puts engine.params[:max_tokens] onto request.max_tokens` — construct `Engine.new(adapter: Fake, params: %{max_tokens: 4096})`, run a scripted `chat/3`, and assert the request the Fake adapter received carried `max_tokens: 4096`. (Expose via a Fake capture hook, or assert on `to_anthropic_request_body/1` in the wire sub-test below.)
- `call-opt max_tokens overrides engine.params[:max_tokens]` — `chat(engine, thread, max_tokens: 2048)` with `engine.params.max_tokens == 4096` → request carries `2048` (precedence: opts > engine.params).
- `temperature flows the same way` — `engine.params[:temperature]` and call-opt `temperature:` both reach `request.temperature`.
- `unset max_tokens leaves request.max_tokens == nil` — no `engine.params`, no opt → `nil` (adapter default still applies; regression guard).
- `stream/3 path carries max_tokens identically to chat/3` — matrix-identical assertion on `do_stream_step_call/3`'s built request (streaming ≡ non-streaming for param coverage, per `AGENT_DESIGN_SPEC.md` rule 10).
- `Session.reply carries max_tokens` — one `Session.*` case proving the fix reaches the stateful path.
- **Wire proof (Anthropic body-builder, no network):** build the request via `build_request` (or `Request.new` mirroring it with `max_tokens: 4096`) and assert `ALLM.Providers.Anthropic.to_anthropic_request_body(req)["max_tokens"] == 4096` (not `1024`). This is the executed falsifier for the reported bug.
- **Opaque param routing:** `engine.params[:top_p]` reaches `request.options["top_p"]` in the body (proves non-typed params aren't dropped) — confirm the key survives `resolve_params/2`'s deny-list at impl time.

### 4.2 Implementation Checklist

- [ ] In `Chat.build_request/4`, compute `params = Engine.resolve_params(engine, opts)`; `Map.split` out `:max_tokens`/`:temperature`; pass them plus `options: <remaining opaque params>` into `Request.new/2` (per Behaviour & Type Contracts).
- [ ] Add `drop_request_carried_keys/1` (or inline `Map.drop`) so `options` doesn't re-carry `:response_format`/`:tool_choice`/orchestration keys already handled by `extra`/`structured`. **Verify** the exact key set against `Engine.resolve_params/2`'s deny-list (`engine.ex:129-143`) and the `@orchestration_opts`/`@phase_5_layer_opts` lists — a leaked orchestration key on the wire is a bug.
- [ ] Confirm the non-streaming `Runner.run` path and the streaming `StreamRunner.run` path both see the populated request (both build via `build_request`; the fix is upstream of both).
- [ ] Verify all bundled adapters read the typed fields: Anthropic (`anthropic.ex:587,593`), OpenAI **both** translators (Chat Completions + Responses — cite each), Gemini. Do not change adapters; just confirm they consume `request.max_tokens`/`temperature`/`options` (they do — this is why the single-site builder fix suffices).
- [ ] Add a `getting_started.md` / `sessions.md` prose note (Phase 2 fix-forward): "`max_tokens` defaults to the provider's floor (Anthropic 1024) — raise it via `Engine.new(params: %{max_tokens: N})` or a per-call `max_tokens:` opt." Keep any example Fake-based/`iex>`-runnable or a fenced block.
- [ ] CHANGELOG line under `## [Unreleased]`: "`chat/3`, `stream/3`, and `Session.*` now honor `max_tokens`/`temperature` from `engine.params` and call opts (previously silently capped at the adapter default, e.g. Anthropic 1024)."

### 4.3 Verification

```bash
mix test test/allm/chat_request_params_test.exs
mix test                              # full suite green; no existing test asserted the buggy 1024 cap
mix credo --strict lib/allm/chat.ex
mix dialyzer
mix format --check-formatted
```

**Success criterion:** `engine.params[:max_tokens]` and call-opt `max_tokens:` reach `request.max_tokens` and the Anthropic body on chat/stream/session paths; opts override engine params; unset stays `nil`; the wire-proof sub-test asserts `to_anthropic_request_body/1` emits the configured value, not `1024`; full suite green.

---

## Test Plan (cross-phase)

- **Unit (Phase 1):** `test/engine_new_validation_test.exs` — the four bad-field raises + three good-field regressions (see 1.1). Every case asserts either `assert_raise ArgumentError, ~r/:field_name/, fn -> … end` or successful construction with a field read-back.
- **Doctest (Phases 2–3):** `test/guides_doctest_test.exs` executes all Fake-based guide `iex>` blocks. This is the behavioral proof for Phase 2's corrections — the corrected examples ARE the tests.
- **Structural (unchanged):** `test/guides_test.exs` keeps enforcing existence, >2KB, banned-token audit, ≥1 `iex>` block, and mix.exs wiring.
- **Unit (Phase 4):** `test/allm/chat_request_params_test.exs` — engine-params + call-opt `max_tokens`/`temperature` reach `request.*` and the Anthropic body; opts override engine params; unset stays `nil`; opaque params route to `request.options`; one `Session.*` case (see 4.1).
- **Stream-equivalence (Phase 4):** the `max_tokens`-coverage assertions are matrix-identical for `chat/3` (non-streaming) and `stream/3` (streaming) per `AGENT_DESIGN_SPEC.md` rule 10 — one row per path, no relaxations (both consume the same `build_request/4`).
- **Regression:** full `mix test` after each phase — no existing doctest (the correct in-module `@doc` examples) or Fake-scripted test may break. Phase 4 specifically greps for any test asserting the buggy `1024` cap through the chat/stream path (`git grep -n "1024" test/`) and re-points it to the intended default-vs-configured distinction.

**Coverage:** Phase 1 adds a small private guard exercised by 7 unit cases; Phase 4 modifies one private builder exercised by the new param tests — both new-code paths land ≥90%. Global floor stays 80% (unchanged). Phases 2–3 add no `lib/` code (coverage-neutral).

**No serializability rows** — Phase 4 populates existing Layer-A `%Request{}` fields (`max_tokens`/`temperature`/`options`), adds no new field; Phase 1 adds no Layer-A field.

---

## Error Contract

Phase 1 is the only error-surface change. It raises a stdlib exception at construction time; it introduces **no** new `{:error, %ALLM.Error._{}}` path and **no** new reason atom.

| Function | Failure | Class | Recovery guidance |
|----------|---------|-------|-------------------|
| `Engine.new/1` | `:adapter` / `:tool_executor` / `:tool_result_encoder` / `:image_adapter` is a non-atom, non-nil value | `ArgumentError` (raised) | Programmer error at construction. Pass a bare module atom (or `nil`); put tool handlers on the tool via `ALLM.tool(handler: …)`, not on the engine. Message names the offending field and shows the bad value. |

The existing `EngineError` closed enum (`lib/allm/error/engine_error.ex:31-40`) is **unchanged**; `:invalid_engine` stays reserved for its current adapter-call-time use.

---

## Alternatives Considered

- **Alternative A — also harden `resolve_executor/1` (`tool_runner.ex:844`) for hand-built struct literals.** A `%ALLM.Engine{tool_executor: {…}}` struct literal bypasses `new/1`, so the Phase-1 guard doesn't catch it; it would still crash at `tool_runner.ex:532`. *Rejected for the minimal design:* it introduces a second failure shape (`{:error, %EngineError{reason: :invalid_engine}}`) for the same class of mistake, and the documented/guide path is `Engine.new/1`. If the team wants belt-and-suspenders, it's a clean follow-up ticket, not a scope expansion here. **(Candidate user question.)**
- **Alternative B — docs-only, skip the Engine guard.** The `{module, tools: %{}}` tuple form was never a supported shape; fixing `guides/tools.md` removes the only known source of the mistake, so arguably no code change is needed. *Rejected:* the crash at `tool_runner.ex:532` is a genuinely bad developer experience for *any* future non-module value (typo, wrong var), and the guard is ~10 lines, `nil`-safe, and non-breaking. Cheap defense-in-depth. **(Candidate user question — the parent explicitly asked to "consider" the fix.)**
- **Alternative D — fix the bug in the adapters (wire `translate_options/2`) instead of `build_request/4`.** Each adapter body-builder could call its `translate_options/2` on the dispatch opts and merge the result into the wire body. *Rejected:* the resolved params are already computed once in `StreamRunner`/`Runner`; re-reading them per adapter duplicates precedence logic across three adapters (and OpenAI's two translators — the Chat-Completions/Responses split), and diverges from the existing design where the body reads `request.*` fields. The `%Request{}` is the provider-neutral param carrier; populating it once in the shared builder is strictly simpler and fixes all providers + both paths + sessions at a single site. (If the team later wants dispatch-opt params to also reach the body as a defense-in-depth channel, that's a separate adapter-layer ticket, not this fix.)
- **Alternative C — custom `iex>` extractor instead of `doctest_file`.** Write a test that greps `iex>` blocks and `Code.eval_string/1`s them. *Rejected:* `doctest_file` is a first-class ExUnit macro (verified working on 2026-07-13), gives real doctest semantics (multi-line bindings, exception matching, `...>` continuations) for free, and needs no bespoke parser.

---

## Assumptions

1. The **in-module `@doc` examples are correct** (they're already executed by `test/allm_test.exs` `doctest ALLM`, `test/allm/allm_stream_generate_test.exs`, etc.) — only the standalone guide markdown drifted. Verified against `lib/allm/session.ex` docstrings (engine-first 3-tuple examples).
2. Every real-provider example in the guides is a ` ```elixir ` fence, not an `iex>` block (verified for `getting_started.md`, `tools.md`, `multi_tenant_keys.md`) — so `doctest_file` won't attempt to run key-dependent code. Phase 2 must preserve this invariant when rewriting.
3. The Fake adapter's per-engine cursor (fact 13) makes `async: true` safe for the guide doctest module. If a specific guide relies on shared cursor state, that module drops to `async: false` (flagged in the commit).
4. `steering/ALLM_VERIFIED_FACTS.md`'s facts about the pinned 0.4.3 package hold on HEAD (the repo the guides ship from). Phase 1/2 verification re-proves the load-bearing ones by execution; if HEAD diverges from 0.4.3 on any cited signature, the source is authority and the design line is corrected in-commit.

---

## Definition of Done

- [ ] All four phases marked `Completed`.
- [ ] `mix test` zero failures; `test/engine_new_validation_test.exs`, `test/guides_doctest_test.exs`, and `test/allm/chat_request_params_test.exs` green; coverage ≥80% global, ≥90% on the new `Engine` guard and the `build_request/4` change.
- [ ] Phase 4 wire-proof passes: `to_anthropic_request_body/1` emits the configured `max_tokens` (not `1024`) for a chat/stream/session request built from `engine.params`/opts; opts override engine params; unset stays `nil`.
- [ ] `mix credo --strict` zero issues on changed files.
- [ ] `mix dialyzer` zero new warnings.
- [ ] `mix format --check-formatted` passes.
- [ ] `Engine.new/1` `@doc` documents the new raise; no other public `@doc` regressed.
- [ ] Every `iex>` block in every wired guide executes green under `doctest_file`; no real-provider `iex>` blocks remain (converted to fences where needed).
- [ ] `test/guides_test.exs` still green (structure + banned-token audit).
- [ ] `CHANGELOG.md` updated under `## [Unreleased]` (no hand-picked version, no `mix.exs @version` edit): one line for the `Engine.new/1` raise; one line for "guide examples now executed as doctests"; one line for "`chat/3`/`stream/3`/`Session.*` now honor `max_tokens`/`temperature` from engine params + call opts."
- [ ] `README.md` untouched (not in Module Tree).
- [ ] Commit messages cite spec §-numbers (§5.2, §6.4, §8, §12.3, §31) and reference `steering/ALLM_VERIFIED_FACTS.md`.
- [ ] Reviewed via `/review`.
```
