# Phase 8: `ALLM.Session` — Stateful Continuation (Layer D) — Design Document

> **Goal:** Ship the Layer D session API that wraps Phase 7's `ALLM.Chat.run/3` and `ALLM.Chat.stream/3` in a serializable `%ALLM.Session{}` continuation, with explicit status transitions for `:awaiting_user` (ask-user suspend) and `:awaiting_tools` (manual-mode tool calls), and a `Session.StreamReducer` that folds chat-stream events into both the updated session and a `%ChatResult{}`.
> **Outcome:** A caller starts a session with `ALLM.Session.start(engine, messages)`, persists it via `:erlang.term_to_binary/1`, deserializes it in a fresh process, calls `Session.reply/4` (or `Session.submit_tool_result/3 + Session.continue/3` for manual mode, or `Session.reply/4` again for ask-user resume), and the resulting thread is identical to what an in-memory run would have produced. Streaming variants (`stream_start/3`, `stream_step/3`, `stream_reply/4`) emit every Phase-5/6/7 event plus the terminal `:chat_completed` event; consumers fold the stream through `ALLM.Session.StreamReducer` to get back `{updated_session, chat_result}`. A session-equivalence property asserts `start/3 ≡ stream_start/3 |> StreamReducer.finalize/1` across every multi-turn Fake fixture. The §31 session round-trip scenario activates here. `mix test`, `mix credo --strict`, `mix dialyzer`, `mix format --check-formatted` all green; coverage ≥ 90 % on every new file.
> **Spec sections:** §2 (Layer D), §5.7 (`%Session{}` shape + status union), §11 (Session API surface), §12 (manual vs auto), §12.3 (ask-user suspension — Session caller branch is the canonical one), §13.2 (`Session.StreamReducer` — `finalize/1` shape), §31 (session round-trip property scenario activated this phase).
> **Layers touched:** D (stateful continuation). No Layer A struct changes — `%Session{}` already ships with the full closed-status union from Phase 1. No Layer B changes — engine/keys/adapter surfaces are reused verbatim. No Layer C changes — `ALLM.Chat.run/3` and `ALLM.Chat.stream/3` are the dispatch targets and stay as-is. No new `ALLM.Event` variants.
> **Phasing doc:** [`PROJECT_PHASING.md`](PROJECT_PHASING.md) Phase 8.

## Status

| Sub-phase | Description | Layer | Status |
|-----------|-------------|-------|--------|
| 8.1 | `ALLM.Session.StreamReducer` — fold events into `{session, chat_result}` (spec §13.2) | D | Not Started |
| 8.2 | `ALLM.Session.start/3 · step/3 · continue/3 · reply/4 · submit_tool_result/3 · submit_tool_results/2` (non-streaming) | D | Not Started |
| 8.3 | `ALLM.Session.stream_start/3 · stream_step/3 · stream_reply/4` (streaming) | D | Not Started |
| 8.4 | §31 session round-trip scenario activation + session-equivalence property + status-transition matrix | D | Not Started |

**Overall Progress:** 0/4 sub-phases complete

## Overview

Phase 8 lands the Layer D continuation API: a `%ALLM.Session{}` is a serializable carrier for "everything a multi-turn chat needs to resume across processes, nodes, or disk." The struct already exists (`lib/allm/session.ex`, shipped in Phase 1) with the full closed status union (`:idle | :awaiting_user | :awaiting_tools | :completed | :error`) and the four `pending_*` fields; what Phase 8 adds is the **operation set that drives status transitions** by composing Phase 7's `ALLM.Chat.run/3` and `ALLM.Chat.stream/3`. Nothing under Layer C changes — Phase 8 is glue between the persistence boundary (the `%Session{}` struct) and the orchestration layer (the chat module). The whole phase is a thin wrapper plus the small `ALLM.Session.StreamReducer` that folds chat-stream events into both an updated session and a chat result in one pass (spec §13.2).

The phase's load-bearing correctness obligation is **session round-trip equivalence**: serialize a session mid-run, deserialize in a fresh process, resume with `reply/4` or `continue/3`, and the resulting thread must match what an in-memory run would have produced. This is the §31 session round-trip property scenario — it has been gated by `@tag :pending` since Phase 4 (`test/allm/providers/fake_scenarios_test.exs`); Phase 8 activates it. The invariant is established by construction: every Phase-8 entry point validates `:erlang.term_to_binary(session)` round-trip equality at test boundaries (`assert session == session |> ETF |> deETF`), and `%Session{}` carries no PIDs, refs, or funs by spec §2 / §5.7. The `:context` field is caller-owned plain data per the existing `lib/allm/session.ex` `@moduledoc` — Phase 8 inherits that contract verbatim and does not deep-walk caller-supplied context.

The phase's second obligation is **explicit status transitions**. Each Phase-8 operation is a state-machine arrow over the closed status union; the design specifies every legal arrow and rejects every illegal one with a typed error. The exhaustive transition matrix (5 statuses × 6 operations + `submit_tool_results/2` ≡ `submit_tool_result/3`):

| From \ Op | `start/3` | `reply/4` | `continue/3` | `step/3` | `submit_tool_result/3` |
|-----------|-----------|-----------|--------------|----------|------------------------|
| `:idle` | n/a (only on fresh session) → see post-call status | legal → post-call status | legal → post-call status | legal → post-call status | **illegal: `ArgumentError`** ("no pending tool calls") |
| `:awaiting_user` | n/a (start/3 is for fresh sessions) | legal — clears pending_*, appends user msg → post-call status | **illegal: `ArgumentError`** ("call reply/4") | **illegal: `ArgumentError`** ("call reply/4") | **illegal: `ArgumentError`** ("call reply/4") |
| `:awaiting_tools` | n/a | **illegal: `ArgumentError`** ("call submit_tool_result + continue") | legal IFF message == nil AND `pending_tool_calls == []`; otherwise **`ArgumentError`** | **illegal: `ArgumentError`** ("call submit_tool_result + continue") | legal — appends tool msg, drops from pending_tool_calls; status flips to `:idle` when last submitted; data error `{:error, %SessionError{reason: :unknown_tool_call_id}}` for unknown id |
| `:completed` | n/a | legal — treated as `:idle` (Decision #5) → post-call status | legal — treated as `:idle` → post-call status | legal — treated as `:idle` → post-call status | **illegal: `ArgumentError`** ("no pending tool calls") |
| `:error` | n/a | `{:error, %SessionError{reason: :session_in_error_state}}` | `{:error, %SessionError{reason: :session_in_error_state}}` | `{:error, %SessionError{reason: :session_in_error_state}}` | `{:error, %SessionError{reason: :session_in_error_state}}` |

`start/3` operates on a fresh `%Session{status: :idle}` (or a `%Thread{}` / `[Message.t()]` coerced via `coerce_session_input/1`); it has no "from" status because the session is constructed at entry. Post-call status for any legal arrow is computed by `apply_chat_result/2` (multi-turn ops) or `apply_step_result/2` (`step/3`) on the returned `%ChatResult{}` / `%StepResult{}` — see the Decision #3 mapping table below.

Test count: 22 cells (4 starts + 5 statuses × 4 operations + `:error` × 5 = 22 unit tests in `test/allm/session_status_transition_test.exs`, plus a `start/3 → fresh session` test = 23 total). Each cell maps to one test row.

Every operation enforces the legal-precondition status (e.g., `submit_tool_result/3` raises `ArgumentError` on `:idle`); enforcement is in Phase 8, not in the `%Session{}` struct itself.

The phase's third obligation is **stream-first composition**: `start/3 ≡ stream_start/3 |> StreamReducer.finalize/1` for every Fake-script + chat-opts combination. This mirrors Phase 5's `generate ≡ stream_generate |> collect`, Phase 6's `step ≡ stream_step |> collect_step`, and Phase 7's `chat ≡ stream |> to_chat_result`. The non-streaming Session API is implemented as a direct call to `ALLM.Chat.run/3` (mirroring Phase 7's "drive, don't wrap" rule from Non-obvious Decision #2 — a Session reducer over `Chat.stream/3` is rejected for the same reasons the Phase 7 design lists). Equivalence is established because **both paths consume the same `%ChatResult{}` value** (returned by `Chat.run/3` non-streaming; observed via `:chat_completed` event streaming) and project it through the **same `Session.apply_chat_result/2` helper** to produce the post-call session. Phase 7's private `Chat.build_chat_result/1` (`lib/allm/chat.ex:535`) constructs the `%ChatResult{}` value once per call and is reused by both paths internally — Session is a downstream consumer of that value, not a co-constructor.

The phase's fourth obligation is **`StreamReducer.finalize/1` returning the two-output tuple `{session, chat_result}`**. The phasing document calls this out as a key decision (8.a). Chosen: tuple form (`{updated_session, chat_result}`). Rationale below in Non-obvious Decision #1.

The phase's fifth obligation is **manual-mode tool-call submission**. Phase 7's `chat/3` halts with `halted_reason: :manual_tool_calls` when `mode: :manual` and the response carries `finish_reason: :tool_calls`; the `ChatResult.thread` carries the assistant message with the tool_calls but no tool-role results. Session translates that ChatResult into `%Session{status: :awaiting_tools, pending_tool_calls: response.tool_calls}`. The caller then submits results via `submit_tool_result/3` (single) or `submit_tool_results/2` (batch); each call appends a `:tool`-role message to `session.thread`, removes the tool-call from `pending_tool_calls`, and — when `pending_tool_calls == []` — flips the status back to `:idle`. The caller then calls `continue/3` to run the next adapter turn. Per spec §11, both `submit_tool_result/3` and `continue/3` are public. **Submission is in-process state mutation only**; no engine call, no halt detection — the caller drives the loop boundary explicitly.

The phase's sixth obligation is **mode flow through Session calls**. The session struct does not carry `:mode` (per spec §5.7); each operation accepts `:mode` as a per-call opt that flows verbatim to `ALLM.Chat.run/3` / `ALLM.Chat.stream/3`. This matches the Layer-C contract exactly. The downstream consequence: a session that started in `:auto` can switch to `:manual` mid-conversation by passing `mode: :manual` on the next `reply/4`. This is intentional flexibility — the tests cover both the sticky and the switching cases.

The phase's seventh obligation is **`session_id` propagation to arity-2 tool handlers**. Per spec §5.2, the `:session_id` opt is one of the keys injected into a handler's second argument. In Layer C, `step/3`/`chat/3` thread `:session_id` through `opts → ToolRunner.run_tool_calls/3 → handler` only when the caller explicitly passes `session_id:` in opts. Phase 8 makes this automatic: every Session-bound entry point sets `session_id: session.id` on the opts passed to `Chat.run/3` (or `Chat.stream/3`) — but only when the caller hasn't already passed `session_id:` (caller-wins per the engine resolution chain in spec §10).

### Layer demonstration

**Layer D — Session-bound multi-turn:**

```elixir
{:ok, session, _result} = ALLM.Session.start(engine, [ALLM.user("plan a trip")])
serialized = :erlang.term_to_binary(session)
# ... persist to disk, send across nodes, restart the BEAM ...
session = :erlang.binary_to_term(serialized)
{:ok, session, _result} = ALLM.Session.reply(engine, session, "yes, book it")
```

**Layer D — Manual tool-call cycle:**

```elixir
{:ok, %Session{status: :awaiting_tools, pending_tool_calls: [tc]} = s, _r} =
  ALLM.Session.start(engine, [ALLM.user("weather?")], mode: :manual)
s = ALLM.Session.submit_tool_result(s, tc.id, %{forecast: "sunny"})
{:ok, %Session{status: :completed} = s, _r} = ALLM.Session.continue(engine, s)
```

**Layer D — Ask-user suspension:**

```elixir
{:ok, %Session{status: :awaiting_user, pending_question: q} = s, _r} =
  ALLM.Session.start(engine, [ALLM.user("delete files in /tmp")])
IO.puts("ALLM asks: #{q}")
{:ok, session, _r} = ALLM.Session.reply(engine, s, "yes, proceed")
```

**Layer D — Streaming + reducer:**

```elixir
{:ok, stream} = ALLM.Session.stream_start(engine, [ALLM.user("hi")])
state =
  Enum.reduce(stream, ALLM.Session.StreamReducer.new(session), fn ev, s ->
    ALLM.Session.StreamReducer.apply_event(s, ev)
  end)
{updated_session, %ChatResult{} = chat_result} = ALLM.Session.StreamReducer.finalize(state)
```

### Deliverables

- **Modified modules:**
  - `lib/allm/session.ex` — adds `start/3`, `stream_start/3`, `reply/4`, `stream_reply/4`, `step/3`, `stream_step/3`, `submit_tool_result/3`, `submit_tool_results/2`, `continue/3`. The struct stays unchanged. Existing helpers (`new/1`, `append/2`, `append_user/2`, `append_tool_result/3`, `pending_tool_calls/1`, `messages/1`, `__from_tagged__/1`) are preserved verbatim.
- **New modules:**
  - `lib/allm/session/stream_reducer.ex` — `ALLM.Session.StreamReducer` (spec §13.2). Wraps a `%ALLM.StreamCollector{}` plus the originating `%Session{}`; `finalize/1` returns `{Session.t(), ChatResult.t()}`.
  - `lib/allm/error/session_error.ex` — `ALLM.Error.SessionError` for status-precondition violations (`:session_in_error_state`, `:invalid_status_for_operation`, `:no_pending_tool_call`, `:unknown_tool_call_id`). Closed reason set per spec §20.
- **Modified facade:** none. Phase 8 does not add anything to `lib/allm.ex` — Sessions live under `ALLM.Session.*`, not on the top-level facade.
- **New tests:** `test/allm/session_test.exs` (non-streaming), `test/allm/session_stream_test.exs` (streaming), `test/allm/session_stream_reducer_test.exs` (reducer unit tests), `test/allm/session_equivalence_test.exs` (`start ≡ stream_start |> finalize` property), `test/allm/session_status_transition_test.exs` (the full transition matrix), `test/allm/error/session_error_test.exs`. Activations in `test/allm/providers/fake_scenarios_test.exs` (the §31 round-trip scenario).
- **Test support:** `test/support/fake_fixtures.ex` — adds two new fixtures (verified absent from the current inventory at design time: `single_tool_call/2`, `parallel_tool_calls/1`, `multi_turn_conversation/1`, `mid_stream_error/1`, `delayed_text/2`, `tool_call_with_streamed_args/2`, `empty_response/0`, `plain_text/1` are present; ask-user and manual-multi-turn fixtures are not):
  - `manual_multi_turn/1` — accepts a list of `{tool_name, arguments, tool_result}` triples and produces a multi-script engine where script 1 emits `{:tool_call, ...}` followed by `{:finish, :tool_calls}`, and subsequent scripts produce continuation responses. Designed to be driven via `start(mode: :manual) → submit_tool_result × N → continue(nil)`.
  - `ask_user_then_resume/1` — accepts `{question, answer_text}` and produces a two-script engine: script 1 emits `{:tool_call, name: "ask_user_tool"}` whose handler returns `{:ask_user, question}`; script 2 emits `{:text, _}, {:finish, :stop}` for the post-resume turn. Designed to be driven via `start → reply(answer)`.
- **CHANGELOG:** one line per public Session function added, plus one line for `ALLM.Session.StreamReducer` and `ALLM.Error.SessionError`.

### Spec coverage

| Spec § | Phase 8 implements |
|--------|--------------------|
| §2 (Layer D) | `%Session{}` is a Layer D struct; this phase ships the operations that drive its state. |
| §5.7 (Session struct + status union) | No struct change. Phase 8 enforces the closed status union as state-machine arrows. |
| §11 (Session API) | Implemented in full: 12 public functions per the spec listing (`new/1`, `start/3`, `stream_start/3`, `reply/4`, `stream_reply/4`, `step/3`, `stream_step/3`, `submit_tool_result/3`, `submit_tool_results/2`, `continue/3`, `pending_tool_calls/1`, `messages/1`, plus the Phase-1 `append*` helpers). |
| §12 (manual vs auto) | `:mode` is a per-call opt; `:manual` produces `:awaiting_tools`. |
| §12.3 (ask-user) | Session caller branch fully implemented: `status: :awaiting_user`, `pending_question`, `pending_tool_call_id` populated; `reply/4` is the canonical resume. |
| §13.2 (`StreamReducer`) | `new/1`, `apply_event/2`, `finalize/1` with `{session, chat_or_step_result}` return shape. |
| §31 (property scenarios) | Activates the session round-trip scenario (`@tag :pending` → active). |

### Prerequisites

- Phase 7 complete (Phase 7's status table all DONE) — `ALLM.Chat.run/3`, `ALLM.Chat.stream/3`, and `ALLM.StreamCollector` `:step_completed` / `:chat_completed` fold clauses are load-bearing dependencies.
- `lib/allm/session.ex` Phase-1 helpers (`new/1`, `append/2`, `append_user/2`, `append_tool_result/3`, `pending_tool_calls/1`, `messages/1`, `__from_tagged__/1`) — already shipped.
- `ALLM.Error.SessionError` reason atoms — added in 8.2 as a scoped Phase-1 vocabulary extension (per `agent-spec/DESIGN.md` §3 rule 5: design must explicitly extend the prior phase's enum). The four reason atoms are listed in §Error Contract below.
- `ALLM.Error.ValidationError.@type reason` — extended with `:invalid_session_input` (one new atom) in 8.2 as a scoped Phase-1 enum extension. The committed enum lives at `lib/allm/error/validation_error.ex:22-28` (`:invalid_request | :invalid_message | :invalid_tool | :invalid_thread | :invalid_session | :vision_not_in_v0_2`); 8.2 adds the new atom there AND to the `@legal_reasons` word-list at `lib/allm/error/validation_error.ex:38-45` (the `validate_reason!/1` raise-list). Without both edits, `ValidationError.new(:invalid_session_input, [...])` raises `ArgumentError` at construction time.

### Out of scope

- **Telemetry events for sessions.** Phase 9 (spec §29). The `[:allm, :session, :start | :stop | :exception]` event family lands with the broader telemetry rollout. Phase 8 does not emit telemetry.
- **Session-level retries.** Phase 9 (spec §20). Phase 8 inherits Phase 7's per-step error handling verbatim.
- **`reset_error/1` to clear an `:error` status.** Deferred. Callers in Phase 8 must construct a fresh session if `status: :error`.
- **Capability pre-flight (`llm_db`).** Phase 9 (spec §6.3). No new `llm_db` code path.
- **`structured_finalize` two-pass.** Phase 9/10 (spec §5.4). Sessions are agnostic to structured output.
- **Session timeouts.** Not in spec v0.2. A persisted session is timeless; the application owns liveness.
- **Concurrent operations on the same session.** Sessions are caller-owned; the caller is responsible for not driving the same session from two processes simultaneously. Phase 8 does not add a lock or a serialisation queue. Tests document this contract.
- **`Session.cancel/1` for cancelling a streaming run.** Spec §11 does not list this. Streaming consumers cancel by halting the enumerable (per Phase 5/6/7's stream-cancellation contract); the caller can then re-derive a session from the partial reducer state via `StreamReducer.finalize/1` if needed.
- **`Session.middleware`.** Empty in v0.2 per spec §29. Phase 8 does not surface a session-level middleware hook.
- **Persistence behaviours.** Phase 8 ships `:erlang.term_to_binary/1` round-trip and `Jason` round-trip (via the existing `ALLM.Serializer` — Sessions already encode through it). It does NOT ship a `Session.Storage` behaviour or a default storage backend; persistence is the application's responsibility.

### Non-obvious decisions

1. **`StreamReducer.finalize/1` returns `{Session.t(), ChatResult.t() | StepResult.t()}` (tuple), not `%Session{last_result: ...}` (embedded).** The phasing document flags this as a key decision (8.a). Chosen: tuple. Rationale: (a) the two outputs have different lifetimes — the session is what the caller persists across calls, the chat-result is what they observe for *this* call (and may discard); embedding makes the session struct's serialisation envelope grow with every call's chat result; (b) matches the existing return shape of `Session.start/3`, `step/3`, `reply/4`, etc. which already return `{:ok, session, result}` tuples (per spec §11), so reducer finalisation is the same shape minus the `:ok` tag; (c) the result type varies between `%ChatResult{}` (for `stream_start`/`stream_reply`) and `%StepResult{}` (for `stream_step`) — embedding both as a single union field on `%Session{}` is messier than dispatching at finalisation time. Cost: callers who want to keep the result on the session do `%{session | metadata: Map.put(session.metadata, :last_result, result)}` themselves; this is two lines and explicit. `Docs target: @doc ALLM.Session.StreamReducer.finalize/1` (the "two-output tuple" paragraph).

2. **`Session.start/3` and `Session.stream_start/3` accept either an existing `%Session{}` (when the caller wants to seed `:context` or `:id`) or a list of messages (in which case Phase 8 constructs a fresh `Session.new(thread: Thread.from_messages(messages))`).** The spec §11 signature is `start(engine, [Message.t()], opts)` — messages-only — but real callers want to pass a pre-constructed session with `:id` and `:context` set. We accept both via a normalising helper `coerce_session_input/1`: a `%Session{}` passes through; a `[Message.t()]` (or `%Thread{}`) is wrapped in `Session.new/1`; anything else is `{:error, %ValidationError{reason: :invalid_session_input}}`. The spec is preserved by message-list-only being a valid call shape; `%Session{}` input is the additional ergonomic. Per `agent-spec/DESIGN.md` §3 rule 7, this is a contract addition that's tested with one row per accepted shape. `Docs target: @doc ALLM.Session.start/3`.

3. **`submit_tool_result/3` is in-process state mutation only — it does NOT call the adapter.** The spec §11 listing places `submit_tool_result/3` alongside `step/3` and `continue/3`, which suggests it might dispatch. It does not. `submit_tool_result/3` (a) appends a `:tool`-role message to `session.thread` with the supplied `tool_call_id` and `result`, (b) removes the matching `%ToolCall{}` from `session.pending_tool_calls`, (c) when `pending_tool_calls` becomes `[]`, sets `session.status = :idle`. No adapter call; no encoder call; **the caller passes the already-encoded result content** (a binary or a JSON-serialisable map) — same shape as the existing `Session.append_tool_result/3` from Phase 1. To run the next adapter turn, the caller calls `Session.continue/3`. This separation matches spec §11's two-function shape and gives the caller an explicit re-entry boundary; bundling submission with the engine call collapses the two events into one and prevents callers from batching multiple `submit_tool_result/3` calls before resuming. `Docs target: @doc ALLM.Session.submit_tool_result/3` (the "in-process only" paragraph).

4. **`continue/3`'s `Message.t()` argument is the canonical "drive the loop with this message" entry point — `reply/4` is a sugared form of `continue/3`.** Per spec §11, `continue(engine, session, message, opts)` accepts an arbitrary message; `reply(engine, session, user_text, opts)` is equivalent to `continue(engine, session, ALLM.user(user_text), opts)`. Implementation: `reply/4` calls `continue/3` after building the user message. The asymmetry between the two functions is purely ergonomic. `continue/3` is also the entry point for the manual-tool-cycle resumption: after `submit_tool_result/3` calls have brought the session back to `:idle`, the caller invokes `continue/3` with `nil` as the message (or with `Session.last_assistant_message/1` for re-prompting) — the case `message == nil` means "do not append any new message; just call the engine on `session.thread` as-is." This `nil` form is needed for manual resumption because the model already produced its assistant message in the previous turn; appending another `:user` message would corrupt the conversation. Implementation: `continue/3` pattern-matches on `nil` and skips the append step. Test case at 8.2.4 covers each branch explicitly. `Docs target: @doc ALLM.Session.continue/3` (the "nil message" paragraph).

5. **A `:completed` session is reusable.** The spec §5.7 lists `:completed` as a normal terminal state but does not say what happens on a subsequent call. Decision: treat `:completed` exactly like `:idle` for the next operation. Concretely, `reply/4` on a `:completed` session appends the user message, flips status to `:idle`, and runs the engine. Rationale: a chat is a long-running conversation; the natural flow is "the model said `:stop` after a complete answer, now the user asks a follow-up." Forcing the caller to construct a new session loses the `:context`, `:id`, and accumulated `:metadata`. The `:error` status is the only terminal state in v0.2. `Docs target: @moduledoc ALLM.Session` ("Status transitions" section, table updated to show `:completed → :idle` arrow).

6. **`Session.step/3` and `Session.stream_step/3` are single-turn entry points that bypass the multi-turn loop.** Per spec §11, these exist alongside the multi-turn operations. They dispatch to `ALLM.Chat.step/3` / `ALLM.Chat.stream_step/3` (NOT `Chat.run/3` / `Chat.stream/3`), apply the resulting `%StepResult{}` to the session via a dedicated `apply_step_result/2` helper (mirroring `apply_chat_result/2`), and return `{:ok, session, %StepResult{}}`. The status transition for `step/3` follows Phase 6's rules **exactly**:

   | Step outcome | `StepResult.done?` | `session.status` |
   |--------------|---------------------|-------------------|
   | `:auto` + terminal `finish_reason` (`:stop` / `:length` / `:content_filter`) | `true` | `:completed` |
   | `:auto` + `finish_reason: :tool_calls` (tools executed inline) | `false` | `:idle` (caller calls `step/3` again to drive the next turn) |
   | `:auto` + handler `{:ask_user, _}` | `true` | `:awaiting_user` |
   | `:auto` + handler `{:halt, reason, _}` (custom atom) | `true` | `:completed` (carries `metadata.halted_reason`) |
   | `:auto` + `on_tool_error: :halt` fired | `true` | `:error` |
   | `:auto` + `finish_reason: :error` | `true` | `:error` |
   | `:manual` + `finish_reason: :tool_calls` | `false` | `:awaiting_tools` |
   | `:manual` + non-tool finish | `true` | `:completed` |
   | Pre-flight error (missing adapter, validation) | n/a | session not constructed; returns `{:error, struct}` |

   The `:auto + :tool_calls + done?: false` row is load-bearing — `Session.step/3` does NOT loop, so an `:auto`-mode step that produces tool calls returns with `done?: false` and `status: :idle`; the caller invokes `step/3` again (or switches to `continue/3` / `reply/4` for multi-turn) to drive the next turn. This matches Phase 6's `Chat.step/3` semantics exactly; Session is a thin wrapper. `Docs target: @doc ALLM.Session.step/3` ("Status transition table" section).

7. **Status-precondition violations raise `ArgumentError`, not `{:error, %SessionError{}}`.** This deviates from the Phase 1 / Phase 5 / Phase 7 pattern of "errors are first-class data, never raises." Rationale: a status precondition is a programmer error (the caller asked for `submit_tool_result/3` on an `:idle` session — they didn't read the docs, they didn't pattern-match on the prior return tuple's status), not a runtime condition. `agent-spec/DESIGN.md` §Elixir-specific permits `raise` for "programmer errors"; status-precondition violations are exactly that class. The four `%SessionError{}` reason atoms still exist for cases where the validation is data-driven rather than caller-flow-driven (e.g., `submit_tool_result/3` for an unknown `tool_call_id` is a `%SessionError{reason: :unknown_tool_call_id}` because the data could legitimately be wrong even if the session is in the correct status). The rule of thumb: **status mismatches raise; data mismatches return `{:error, %SessionError{}}`**.

   **`:tool_error → :error` retry note.** Decision #3's mapping table sends `chat_result.halted_reason: :tool_error` to `session.status: :error`, which (per Decision #5's rule that `:error` is terminal until cleared) renders the session unusable. This is intentional: `:tool_error` only fires when the caller passed `on_tool_error: :halt` (or the function-form returned `:halt`) — the default `on_tool_error: :continue` (`lib/allm.ex:255`) means tool errors are encoded as tool-result content and the loop continues. A caller who wants tool-error retries uses `on_tool_error: :continue`; a caller who wants the session to dead-letter on tool error uses `on_tool_error: :halt` (or the function form). The `:error` mapping respects the caller's explicit `:halt` intent. `Docs target: @moduledoc ALLM.Session` ("Errors" section).

8. **Session round-trip is verified per-operation, not just at session boundaries.** The §31 property scenario tests one round-trip (start → ETF → resume); Phase 8's test plan tests every operation produces a session that round-trips via ETF AND `Jason`. This is mechanical (`assert s == s |> :erlang.term_to_binary() |> :erlang.binary_to_term()` after every call) and catches accidental fun-on-session leaks the moment they're introduced. The Jason round-trip uses `ALLM.Serializer.to_json!/1 |> ALLM.Serializer.from_json!/1` and the existing `ALLM.Session.__from_tagged__/1` hydrator (already shipping). `Docs target: internal — no user-facing docs`.

9. **`session_id` is automatically threaded into `opts` as `session_id: session.id` UNLESS the caller has passed `session_id:` already.** Per spec §5.2 the arity-2 tool handler form receives `:session_id` as one of the injected opts. Layer C does not auto-thread this — the caller has to set `opts[:session_id]` themselves. Phase 8 closes the gap: every Session-bound entry point sets `session_id: session.id` on the opts forwarded to `Chat.run/3` / `Chat.stream/3`, but only when the caller hasn't already specified it. This is the same caller-wins precedence as the engine-resolution chain. When `session.id == nil` (the caller didn't bother to set one), no opt is added — the handler sees `nil` for `session_id`. `Docs target: @moduledoc ALLM.Session` ("session_id propagation" paragraph).

10. **`:context` from `session.context` is automatically threaded into opts as `context: session.context` UNLESS the caller has passed `context:` already.** Same rule as `session_id` (Decision #9). Layer C resolves `:context` from `engine.context` by default; Phase 8 lets the session carry a per-conversation `:context` that overrides the engine default. Caller-passed `:context` still wins at the topmost layer.

   **Resolution chain (load-bearing — file:line cite):** `caller_opts > session.context > engine.context`. `merge_session_opts/2` runs at every Session entry point BEFORE the `Chat.run/3` / `Chat.stream/3` call (i.e., before `lib/allm/chat.ex:1349-1368`'s `build_runner_opts/3` resolves `engine.context`). Concretely:

       merge_session_opts(session, opts) =
         opts
         |> Keyword.put_new(:context, session.context)
         |> Keyword.put_new(:session_id, session.id)

   When session.context was already injected by `merge_session_opts/2`, `Chat`'s own `Keyword.put_new(:context, engine.context)` at `lib/allm/chat.ex:1363` becomes a no-op — engine.context is shadowed. Reordering this chain (e.g., resolving engine.context first and using `session.context` only as a fallback) silently demotes session.context below engine.context. The order is part of the contract.

   Test row: `engine.context: %{a: 1, b: 1}` + `session.context: %{b: 2, c: 2}` + `caller opts: [context: %{c: 3}]` → handler sees `%{c: 3}` (call wins; no merge). Without caller opts, handler sees `session.context = %{b: 2, c: 2}` (session wins; engine shadowed; no auto-merge — a single-source replacement). `Docs target: @moduledoc ALLM.Session` ("context propagation" paragraph).

11. **`stream_step/3` (the Session-level streaming single-turn) terminates with a `:step_completed` event, NOT a `:chat_completed` event.** Phase 7 reserved `:chat_completed` as the multi-turn terminal event; Phase 6 ships `:step_completed` as the single-turn terminal. Session's `stream_step/3` composes `Chat.stream_step/3`, so it inherits Phase 6's terminal contract verbatim. `StreamReducer.apply_event/2` handles both `:step_completed` and `:chat_completed` — the former produces a `%StepResult{}`, the latter a `%ChatResult{}`. `finalize/1`'s second tuple element is whichever was observed (or, when neither, builds a `%ChatResult{halted_reason: :cancelled}` from the partial state — same fallback as Phase 7's `StreamCollector.to_chat_result/1`). `Docs target: @doc ALLM.Session.StreamReducer.apply_event/2`.

12. **`Session.StreamReducer.new/1` accepts a `%Session{}`, NOT a `%Thread{}`.** The reducer needs the originating session because (a) it owns `:context`, `:id`, and `:metadata` that flow into the post-call session; (b) `apply_chat_result/2` needs the original session as its first argument. Internal: the reducer wraps a `%StreamCollector{}` seeded with `session.thread` plus a reference to the `%Session{}`. `apply_event/2` delegates to `StreamCollector.apply_event/2` for the event fold; only `finalize/1` does session-specific work. This keeps the reducer thin — almost all logic lives in the existing `StreamCollector`. `Docs target: @doc ALLM.Session.StreamReducer.new/1`.

15. **`StreamReducer.new/1` carries a `:mode` flag (`:chat | :step`) that selects `finalize/1`'s dispatch shape.** Naively dispatching on `collector.chat_result != nil` vs `collector.steps != []` collides with the fact that `StreamCollector.apply_event/2`'s `:step_completed` clause unconditionally pushes the step onto `state.steps` (verified at `lib/allm/stream_collector.ex:387-407` — the fold appends regardless of whether more steps follow). After folding a single `:step_completed` event from `Chat.stream_step/3`, `state.steps == [_one_]` AND `state.chat_result == nil` — indistinguishable from "I cancelled mid-multi-step after one step completed."

   Resolution: `StreamReducer.new/1` accepts `mode: :chat` (default, used by `stream_start/3` / `stream_reply/4`) or `mode: :step` (used by `stream_step/3`); the flag is stored on the reducer struct and read at `finalize/1` time to pick the dispatch shape:

   - `mode: :step` AND `state.steps == [one]` AND `state.chat_result == nil` → returns `{Session.apply_step_result(session, hd(state.steps)), hd(state.steps)}`. The single observed step IS the result; this is the natural terminus.
   - `mode: :step` AND `state.steps == []` AND `state.chat_result == nil` → returns `{session, %ChatResult{halted_reason: :cancelled, thread: session.thread, steps: [], final_response: nil, metadata: %{}}}`. Consumer halted before any step completed; the result is a `%ChatResult{}` (not a `%StepResult{}`) because there's no observed step to project.
   - `mode: :chat` AND `state.chat_result != nil` → returns `{Session.apply_chat_result(session, stored), stored}`.
   - `mode: :chat` AND `state.chat_result == nil` → returns `{Session.apply_chat_result(session, fallback), fallback}` where `fallback = StreamCollector.to_chat_result(state.collector)` (Phase 7's `:cancelled` fallback path).

   The default `mode: :chat` matches the most common usage (consuming `stream_start/3` / `stream_reply/4` output). Session's three streaming entry points pass the right mode at construction:

   - `stream_start/3`, `stream_reply/4`, `stream_continue/3` → `StreamReducer.new(session, mode: :chat)`.
   - `stream_step/3` → `StreamReducer.new(session, mode: :step)`.

   Documented constructor signature: `@spec new(Session.t(), keyword()) :: t()` with `mode: :chat | :step` accepted; default `:chat`. `Docs target: @doc ALLM.Session.StreamReducer.new/2` ("Mode dispatch" paragraph).

14. **`submit_tool_result/3` and `submit_tool_results/2` widen spec §11's return type to `t() | {:error, SessionError.t()}`.** Spec §11 declares the return as `t()` (non-erroring). Phase 8 widens because the unknown-`tool_call_id` case is genuinely data-validation, not programmer error: a caller who has serialized a session, sent the `pending_tool_calls` list to a UI, and re-deserialized may receive a stale or hand-crafted id that doesn't match. Raising `ArgumentError` for that case forces the caller to wrap every submission in a `try/rescue`, which is awkward — the error tuple is the canonical Layer A shape for data validation. Status-precondition violations remain raises per Decision #7 (calling on `:idle` is a programmer flow bug; calling with a wrong id is a data bug). Cited in commit messages as `§11 amendment`. `Docs target: @doc ALLM.Session.submit_tool_result/3` and `@doc ALLM.Session.submit_tool_results/2` (the "Errors" section paragraph).

13. **A streaming Session call that observes `:chat_completed` carrying `halted_reason: :error` produces an `:error`-status session, not an `:idle` one.** Mirrors the non-streaming path: `Chat.run/3`'s `{:ok, %ChatResult{halted_reason: :error}}` becomes `{:ok, %Session{status: :error}, chat_result}` — the `{:ok, _}` tuple stays because the call returned a result; the error is on the session and on `chat_result.halted_reason`. The `metadata.error` key is populated on both. This is consistent with CLAUDE.md's "Mid-stream adapter errors fold into the response, not the call-site tuple" invariant — `chat_result.halted_reason: :error` is the load-bearing fold; Phase 8 just projects it onto `session.status`. `Docs target: @moduledoc ALLM.Session` ("Mid-stream errors" paragraph).

## Behaviour & Type Contracts

### `ALLM.Session` (Layer D — Phase 8 additions)

```elixir
defmodule ALLM.Session do
  # Phase 1 helpers (already shipping) preserved verbatim:
  #   new/1, append/2, append_user/2, append_tool_result/3,
  #   pending_tool_calls/1, messages/1, __from_tagged__/1.
  # Phase 8 additions below.

  @typedoc """
  Options accepted by `start/3`, `reply/4`, `continue/3`, `step/3`, and the
  streaming variants. A superset of `ALLM.Chat.chat_opts/0`; everything not
  listed below flows verbatim to `ALLM.Chat.run/3` / `ALLM.Chat.stream/3`.

    * `:mode` — `:auto` (default) or `:manual`. Per-call; not sticky on the
      session struct.
    * `:max_turns` — `pos_integer()`; same precedence as Phase 7.
    * `:halt_when` — `(StepResult.t() -> boolean())`; runtime fun, NEVER
      stored on `%Session{}`.
    * `:on_tool_error`, `:tool_timeout`, `:tool_executor`,
      `:tool_result_encoder` — Phase 6/7 pass-through.
    * `:emit_text_deltas`, `:emit_tool_deltas`, `:include_raw_chunks`,
      `:on_event` — Phase 5 stream filter pass-through.
    * `:session_id`, `:context` — caller-wins overrides; default to
      `session.id` and `session.context` respectively.
  """
  @type session_opts :: keyword()

  @typedoc """
  Input shape accepted where the spec calls for `[Message.t()]`. A
  `%Session{}` passes through; a `%Thread{}` or `[Message.t()]` is wrapped
  in `Session.new/1`.
  """
  @type session_input :: t() | Thread.t() | [Message.t()]

  @spec start(Engine.t(), session_input(), session_opts()) ::
          {:ok, t(), ChatResult.t()}
          | {:error,
             EngineError.t()
             | AdapterError.t()
             | ValidationError.t()
             | SessionError.t()}
  def start(engine, session_input, opts \\ [])

  @spec stream_start(Engine.t(), session_input(), session_opts()) ::
          {:ok, Enumerable.t()}
          | {:error,
             EngineError.t()
             | AdapterError.t()
             | ValidationError.t()
             | SessionError.t()}
  def stream_start(engine, session_input, opts \\ [])

  @spec reply(Engine.t(), t(), String.t(), session_opts()) ::
          {:ok, t(), ChatResult.t()}
          | {:error,
             EngineError.t() | AdapterError.t() | ValidationError.t() | SessionError.t()}
  def reply(engine, session, user_text, opts \\ [])

  @spec stream_reply(Engine.t(), t(), String.t(), session_opts()) ::
          {:ok, Enumerable.t()}
          | {:error,
             EngineError.t() | AdapterError.t() | ValidationError.t() | SessionError.t()}
  def stream_reply(engine, session, user_text, opts \\ [])

  @spec step(Engine.t(), t(), session_opts()) ::
          {:ok, t(), StepResult.t()}
          | {:error,
             EngineError.t() | AdapterError.t() | ValidationError.t() | SessionError.t()}
  def step(engine, session, opts \\ [])

  @spec stream_step(Engine.t(), t(), session_opts()) ::
          {:ok, Enumerable.t()}
          | {:error,
             EngineError.t() | AdapterError.t() | ValidationError.t() | SessionError.t()}
  def stream_step(engine, session, opts \\ [])

  @spec continue(Engine.t(), t(), Message.t() | nil, session_opts()) ::
          {:ok, t(), ChatResult.t()}
          | {:error,
             EngineError.t() | AdapterError.t() | ValidationError.t() | SessionError.t()}
  def continue(engine, session, message, opts \\ [])

  @spec submit_tool_result(t(), String.t(), String.t() | map()) ::
          t() | {:error, SessionError.t()}
  def submit_tool_result(session, tool_call_id, content)

  @spec submit_tool_results(t(), [{String.t(), String.t() | map()}]) ::
          t() | {:error, SessionError.t()}
  def submit_tool_results(session, results)
end
```

**Spec §11 deviation note.** Spec §11 declares `@spec submit_tool_result(t(), String.t(), term()) :: t()` (non-erroring). Phase 8 widens the return to `t() | {:error, SessionError.t()}` so an unknown `tool_call_id` surfaces as data error rather than crashing. This is a scoped contract amendment, surfaced explicitly in Non-obvious Decision #14 below. Status-precondition violations (calling on `:idle`/`:awaiting_user`) still raise `ArgumentError` per Decision #7's status-vs-data rule — only data-validation paths return the error tuple.

**Invariants:**

1. **Round-trip after every operation.** For every successful return `{:ok, session, _}`, `session == session |> :erlang.term_to_binary() |> :erlang.binary_to_term()` (unconditional). The Jason round-trip is non-equality-preserving for `DateTime` / `Decimal` values in `:context` per the existing Phase 1 contract (`lib/allm/session.ex:33-38` documents the caller-owned escape hatch). Phase 8's Jason invariant uses an explicit exclude list on the test helper:

       assert_session_round_trip(session, exclude: [:context, :metadata])
       # ETF: full equality.
       # JSON: equality on every field except those in :exclude.

   The `:exclude` list defaults to `[]` (full Jason equality). Test fixtures that populate `:context` or `:metadata` with caller types (DateTime, Decimal, custom structs without Jason encoders) pass `exclude: [:context, :metadata]`; fixtures with empty `:context`/`:metadata` pass `exclude: []`. Both surfaces (excluded and unexcluded) are covered in the test plan. This makes the "round-trip after every operation" claim an unconditional ETF invariant plus a parameterized Jason invariant — no silent skips.

2. **No PIDs / refs / funs / anonymous functions on `%Session{}` after any operation.** Inherited from spec §2. The closed-set invariant is enforced by Phase 1's `:erlang.term_to_binary/1` round-trip test in `test/allm/session_roundtrip_test.exs`; Phase 8 extends the test matrix to cover every operation's post-call session.

3. **Status-transition correctness.** For every legal transition in the matrix above, a unit test in `test/allm/session_status_transition_test.exs` exercises it. For every illegal transition (e.g., `submit_tool_result/3` on `:idle`), a unit test asserts the precondition raise.

4. **`session.thread` post-call equals `chat_result.thread` post-call.** Per spec §11, the Session's thread mirrors the chat-result's thread — there is no per-Session thread-mutation logic that could diverge. The `apply_chat_result/2` helper writes `chat_result.thread` to `session.thread` verbatim.

5. **`session.id` and `session.context` are preserved across operations** — they're never written by Phase 8 unless explicitly invoked via `Session.new/1` or hydrated by `__from_tagged__/1`. `metadata` is monotonic (never overwritten, only merged).

6. **`session_id` and `context` propagation is caller-wins** (Non-obvious Decisions #9, #10). The `merge_session_opts/2` helper is the single place where this happens; it's the symmetric inverse of Phase 7's `terminal_condition/4` (single dispatch point preventing drift across functions).

7. **`pending_tool_calls` and `pending_question` / `pending_tool_call_id` are mutually exclusive on a single session** — the closed status union prevents both from being populated at the same time (`:awaiting_tools` ⇒ pending_tool_calls != [] ∧ pending_question == nil; `:awaiting_user` ⇒ pending_question != nil ∧ pending_tool_calls == []). Phase 8's `apply_chat_result/2` writes both fields together based on `chat_result.halted_reason`, so the invariant is established by construction.

8. **`Session.continue/3` with `nil` message and `:idle` status drives the engine using `session.thread` as-is.** Used for the manual-tool-cycle resumption (after `submit_tool_result/3` calls have populated all tool-role messages).

9. **`Session.step/3` does not loop.** It calls `Chat.step/3` exactly once and applies the `%StepResult{}` to the session. Distinct from `Session.continue/3` which calls `Chat.run/3` (multi-turn). Both are explicit per spec §11.

### `ALLM.Session.StreamReducer` (Layer D — new module, spec §13.2)

```elixir
defmodule ALLM.Session.StreamReducer do
  alias ALLM.{ChatResult, Session, StepResult, StreamCollector}

  @type mode :: :chat | :step

  @type t :: %__MODULE__{
          session: Session.t(),
          collector: StreamCollector.state(),
          mode: mode()
        }

  defstruct [:session, :collector, mode: :chat]

  @spec new(Session.t(), keyword()) :: t()
  def new(%Session{} = session, opts \\ [])

  @spec apply_event(t(), ALLM.Event.t()) :: t()
  def apply_event(state, event)

  @spec finalize(t()) :: {Session.t(), ChatResult.t() | StepResult.t()}
  def finalize(state)
end
```

**Invariants:**

1. **`new/2` seeds `collector` with `StreamCollector.new(session.thread)` and stores `mode` from opts (default `:chat`).** The collector is thread-aware so `to_step_result/1` and `to_chat_result/1` work without further setup.
2. **`apply_event/2` is total over the 16-tag closed event union.** Delegates to `StreamCollector.apply_event/2` for every tag; the reducer never short-circuits on its own.
3. **`finalize/1` dispatches on `state.mode` (per Decision #15):**
   - `mode: :chat` AND `collector.chat_result != nil` (a `:chat_completed` event was folded): returns `{Session.apply_chat_result(session, chat_result), chat_result}`.
   - `mode: :chat` AND `collector.chat_result == nil`: builds the fallback ChatResult via `StreamCollector.to_chat_result(collector)` (Phase 7's `:cancelled` fallback) and returns `{Session.apply_chat_result(session, fallback), fallback}`.
   - `mode: :step` AND `collector.steps == [one_step]` AND `collector.chat_result == nil`: returns `{Session.apply_step_result(session, hd(steps)), hd(steps)}`.
   - `mode: :step` AND `collector.steps == []`: returns `{session, %ChatResult{halted_reason: :cancelled, thread: session.thread, steps: [], final_response: nil, metadata: %{}}}` — consumer halted before any step completed; the result is a `%ChatResult{}` because no `%StepResult{}` exists to project.
4. **`finalize/1` is idempotent.** Calling it twice with the same state returns equal tuples.
5. **Mode is set at construction, never inferred from event content.** Decision #15's discriminant lives on the reducer struct, not on the collector; this keeps the dispatch deterministic regardless of how many `:step_completed` events were folded.

### `ALLM.Error.SessionError` (Layer A — new struct, scoped Phase 1 vocabulary extension)

```elixir
defmodule ALLM.Error.SessionError do
  @moduledoc """
  Session-state error. Raised internally by Phase 8's status-precondition
  helpers OR returned as `{:error, %SessionError{}}` from the data-validation
  branches.
  """

  @type reason ::
          :session_in_error_state
          | :invalid_status_for_operation
          | :no_pending_tool_call
          | :unknown_tool_call_id

  @type t :: %__MODULE__{
          reason: reason(),
          message: String.t(),
          provider: nil,
          cause: term() | nil,
          metadata: map()
        }

  defstruct [:reason, :message, :provider, :cause, metadata: %{}]

  @spec new(reason(), keyword()) :: t()
  def new(reason, opts \\ [])
end
```

**Invariants:**

1. The four reason atoms above are the closed set; every code path that surfaces a `%SessionError{}` uses exactly one.
2. The struct mirrors the existing `%EngineError{}` / `%AdapterError{}` shape (per Phase 1's error-struct convention).
3. **Implements `Jason.Encoder` via `ALLM.Serializer.encode_tagged/2`** — same pattern as the other error structs. Registered in `ALLM.Serializer.@known_modules` so `from_json/1` round-trips.

### Atom vocabulary additions

This phase adds **four new reason atoms** (`:session_in_error_state`, `:invalid_status_for_operation`, `:no_pending_tool_call`, `:unknown_tool_call_id`) to the project's closed reason-atom set. Per `agent-spec/DESIGN.md` §3 rule 5, this is a scoped extension of Phase 1's `@type reason :: ...` enum on `ALLM.Error.*`, declared explicitly here. `lib/allm/error/session_error.ex` ships with the four atoms in its `@type reason :: ...`; no other reason atoms are added.

The reason atoms in `ALLM.Session.@type status :: ...` (`:idle`, `:awaiting_user`, `:awaiting_tools`, `:completed`, `:error`) are **not extended** — they're the existing closed set from Phase 1.

The reason atoms in `ALLM.ChatResult.@type halted_reason :: ...` (`:completed`, `:max_turns`, `:halt_when`, `:ask_user`, `:tool_error`, `:cancelled`, plus `atom()` tail for handler-supplied) are **not extended** — Phase 7 already declared the closed set.

### Idiomatic Elixir requirements

- **Pattern-matching function heads** for the status-precondition checks — `defp ensure_status!(%Session{status: :idle}, _ops), do: :ok` plus a catch-all that raises. Matches the `cond do ... end` in Phase 7's `terminal_condition/4` for branch shape; pattern-matching on the struct is more idiomatic when the discriminant is a single field.
- **`with`-chains** at the entry of `start/3`, `reply/4`, `continue/3`, etc. for `coerce_session_input → ensure_status! → merge_session_opts → Chat.run` — mirrors the Phase 6 / Phase 7 pattern.
- **`Stream.resource/3`** is NOT introduced at this layer. The streaming Session functions wrap `Chat.stream/3`'s enumerable; the consumer drives the same enumerable, and the Session's `StreamReducer` is fold state, not a producer.
- **`Keyword.put_new/3`** for the caller-wins precedence in `merge_session_opts/2` (per Decision #9, #10).
- **`is_function(halt_when, 1)` guard** before stuffing `:halt_when` into opts — but `:halt_when` is a runtime fun and is never stored on `%Session{}` (per the Out-of-scope clause; matches Phase 7's "halt_when is Layer C only" rule).

## Module Tree

```
lib/allm/
├── session.ex                                 (MODIFY — add 9 public functions; status-precondition helpers; merge_session_opts/2; apply_chat_result/2; apply_step_result/2; coerce_session_input/1)
├── session/
│   └── stream_reducer.ex                      (NEW — ALLM.Session.StreamReducer; new/1, apply_event/2, finalize/1)
└── error/
    └── session_error.ex                       (NEW — ALLM.Error.SessionError + reason atoms)

lib/allm/serializer.ex                         (MODIFY — add ALLM.Error.SessionError to @known_modules; verify round-trip)

test/allm/
├── session_test.exs                           (NEW — non-streaming Session API: start/3, reply/4, continue/3, step/3, submit_tool_result/3, submit_tool_results/2)
├── session_stream_test.exs                    (NEW — streaming Session API: stream_start/3, stream_reply/4, stream_step/3)
├── session_stream_reducer_test.exs            (NEW — StreamReducer unit tests; finalize/1's four branches)
├── session_equivalence_test.exs               (NEW — property: start ≡ stream_start |> finalize; per-operation round-trip)
├── session_status_transition_test.exs         (NEW — full status-transition matrix: legal arrows + illegal raises)
├── session_roundtrip_test.exs                 (MODIFY — add post-operation round-trip rows for every Phase 8 operation)
├── error/
│   └── session_error_test.exs                 (NEW — construction, round-trip, JSON encode/decode)
└── providers/
    └── fake_scenarios_test.exs                (MODIFY — flip §31 session round-trip @tag :pending → active)

test/support/
├── fake_fixtures.ex                           (MODIFY — add :manual_multi_turn and :ask_user_then_resume fixtures only if not already present; verify at sub-phase 8.4 start)
└── assertions.ex                              (MODIFY — add assert_equivalent_session_result/2 helper)

CHANGELOG.md                                   (MODIFY — one line per new public symbol + scenario activation)
```

Test files mirror source files 1:1 per `agent-spec/IMPLEMENTATION.md` §Test file organization.

## Phases

### Sub-phase 8.1: `ALLM.Session.StreamReducer` (Layer D)

**Goal:** Implement `ALLM.Session.StreamReducer` per spec §13.2 — wraps a `%StreamCollector{}` plus the originating `%Session{}`; `finalize/1` returns `{updated_session, chat_or_step_result}`.

**Spec sections:** §13.2.

#### 8.1.1 Test Plan (write first)

`test/allm/session_stream_reducer_test.exs` (NEW):

**`new/2`:**
- `new(%Session{})` returns `%StreamReducer{session: session, collector: %StreamCollector{thread: session.thread}, mode: :chat}` (default mode).
- `new(%Session{}, mode: :step)` returns the same shape with `mode: :step`.
- `new(%Session{}, mode: :bogus)` raises `ArgumentError` — the `:mode` opt is validated against the closed `[:chat, :step]` set at construction.
- `new/2` rejects non-Session input via the type signature (Dialyzer-time, not runtime).

**`apply_event/2`:**
- Dispatches to `StreamCollector.apply_event/2` and updates `state.collector` with the result. Verify by folding three events (`:text_delta`, `:text_completed`, `:message_completed`) and asserting `state.collector.current_text == "..."` matches the expected `StreamCollector` shape.
- Total over the closed 16-tag event union (mirrors `StreamCollector` totality test). One row per known tag; one row for a malformed event (catch-all no-op).
- Does NOT mutate `state.session` — the session is preserved verbatim through every fold, mutated only at `finalize/1`.

**`finalize/1` — four branches (per Decision #15 & invariant 3a-d):**

`mode: :chat` branches:
- **Stored chat_result.** Build reducer with `mode: :chat`; fold a `:chat_completed` event with a populated `%ChatResult{halted_reason: :completed, thread: t}`; `finalize/1` returns `{Session.apply_chat_result(session, cr), cr}`. The session's status reflects `:completed`; `session.thread == cr.thread`.
- **Inter-step cancellation (chat).** Build reducer with `mode: :chat`; fold two `:step_completed` events but no `:chat_completed`; `finalize/1` returns `{updated_session, %ChatResult{halted_reason: :cancelled, steps: [_, _]}}`. The session reflects the partial state.
- **Empty collector (chat).** Build reducer with `mode: :chat`; fold no events; `finalize/1` returns `{session, %ChatResult{halted_reason: :cancelled, thread: session.thread, steps: [], final_response: nil, metadata: %{}}}`.

`mode: :step` branches:
- **Single-step terminus.** Build reducer with `mode: :step`; fold the events for one complete adapter turn (terminating in `:step_completed`); `finalize/1` returns `{Session.apply_step_result(session, sr), sr}` where `sr == hd(collector.steps)`. Session status follows step semantics.
- **Empty collector (step).** Build reducer with `mode: :step`; fold no events; `finalize/1` returns `{session, %ChatResult{halted_reason: :cancelled, ...}}` (note: ChatResult, not StepResult — there's no step to project).

**Idempotency:**
- `finalize/1` called twice on the same state returns equal tuples (no internal state mutation).

**Per-operation round-trip:**
- After `apply_event/2` is called any number of times, the wrapped `state.session` round-trips through `:erlang.term_to_binary/1`. (The collector is also serializable but contains transient ToolCall maps; we test both.)

#### 8.1.2 Implementation Checklist

- [ ] Create `lib/allm/session/stream_reducer.ex` with `defstruct [:session, :collector, mode: :chat]`, `@moduledoc`, type spec, and the three public functions.
- [ ] `new/2` invokes `StreamCollector.new(session.thread)` and stores all three fields. Validate `opts[:mode]` against `[:chat, :step]` — raise `ArgumentError` on unknown.
- [ ] `apply_event/2` delegates to `StreamCollector.apply_event/2` and updates `state.collector`.
- [ ] `finalize/1` dispatches on `state.mode`, then on collector shape per Decision #15. Each branch calls the matching `Session.apply_chat_result/2` or `Session.apply_step_result/2` helper (added in 8.2).
- [ ] Add `@spec` matching the contracts section verbatim.
- [ ] Add `@doc` doctests for `new/2` (one for each mode), `apply_event/2`, `finalize/1` using `ALLM.Providers.Fake`.

**Dependency note:** 8.1's `finalize/1` calls `Session.apply_chat_result/2` and `Session.apply_step_result/2`, which are added in 8.2. Implementation order: write 8.1's tests with `apply_chat_result/2` stubbed, land 8.2's helpers, then make 8.1's tests pass. **Or** — combine 8.1 and 8.2 into a single batch per `agent-spec/IMPLEMENTATION.md` "Combining adjacent sub-phases" rule (same layer + cross-dependency). **Recommended: combine** so the two helpers are landed together.

**Visibility decision (load-bearing for the combine):** when combined, `Session.apply_chat_result/2` and `Session.apply_step_result/2` ship as `@doc false def` (not `defp`) on `ALLM.Session`. Public-but-undocumented visibility is required because `ALLM.Session.StreamReducer` (a different module) calls them. Per `agent-spec/IMPLEMENTATION.md` "Don't use `@opaque` on `@moduledoc false` structs" pitfall, `def @doc false` keeps Dialyzer happy across the module boundary while signalling "internal — not part of the public API." The two helpers are added to a private internal section of `lib/allm/session.ex` with a `@doc false` comment block above them naming the cross-module caller. If the implementer chooses NOT to combine, they must inline the helpers' logic into `StreamReducer.finalize/1` — which duplicates the field-source map of Decision #3. The combine + `@doc false def` pair is strictly better.

#### 8.1.3 Verification

```bash
mix test test/allm/session_stream_reducer_test.exs
mix test                              # full suite still green
mix credo --strict lib/allm/session/stream_reducer.ex
mix dialyzer
```

### Sub-phase 8.2: Non-streaming Session API (Layer D)

**Goal:** Implement `start/3`, `reply/4`, `continue/3`, `step/3`, `submit_tool_result/3`, `submit_tool_results/2` on `ALLM.Session`. Plus the internal helpers `apply_chat_result/2`, `apply_step_result/2`, `coerce_session_input/1`, `merge_session_opts/2`, `ensure_status!/2`. Plus `ALLM.Error.SessionError`.

**Spec sections:** §11, §12, §12.3, §20.

#### 8.2.1 Test Plan (write first)

`test/allm/error/session_error_test.exs` (NEW):

- `SessionError.new(:session_in_error_state)` returns a populated struct with default message; `metadata` is `%{}`.
- `SessionError.new(:unknown_tool_call_id, metadata: %{tool_call_id: "x"})` carries the metadata.
- ETF round-trip succeeds; Jason round-trip via `ALLM.Serializer.to_json!/1 |> from_json!/1` succeeds.
- An unknown reason atom raises `ArgumentError` (verified in IEx on OTP 27 — `struct!/2` accepts the field but `validate_reason!/1` does not).

`test/allm/session_test.exs` (NEW) — one describe block per public function:

**`start/3`:**
- Happy path: `start(engine, [ALLM.user("hi")])` returns `{:ok, %Session{status: :completed}, %ChatResult{halted_reason: :completed}}` for a Fake script that ends in `:stop`.
- `start/3` accepts a `%Thread{}` input (per Decision #2): `start(engine, %Thread{messages: [user_msg]})`.
- `start/3` accepts a pre-constructed `%Session{}` input: `start(engine, Session.new(id: "s1", context: %{user: 42}))` — id and context preserved on the returned session.
- `start/3` with `mode: :manual` and a tool-call script returns `{:ok, %Session{status: :awaiting_tools, pending_tool_calls: [_]}, %ChatResult{halted_reason: :manual_tool_calls}}`.
- `start/3` with an ask-user fixture returns `{:ok, %Session{status: :awaiting_user, pending_question: q, pending_tool_call_id: id}, %ChatResult{halted_reason: :ask_user}}`.
- `start/3` with a Fake script that produces `finish_reason: :error` returns `{:ok, %Session{status: :error, metadata: %{error: %AdapterError{}}}, %ChatResult{halted_reason: :error}}`.
- `start/3` with `engine` missing `:adapter` returns `{:error, %EngineError{reason: :missing_adapter}}`; the session is not constructed.
- `start/3` with `:invalid_session_input` (e.g., a tuple) returns `{:error, %ValidationError{reason: :invalid_session_input}}`.
- After `start/3`, the returned session round-trips via ETF AND Jason.

**`reply/4`:**
- `reply(engine, %Session{status: :idle, thread: t}, "hello")` appends `:user` message and dispatches; the returned session reflects the new turn.
- `reply/4` on `:awaiting_user` clears `:pending_question` and `:pending_tool_call_id`, appends the user message, and resumes orchestration. The returned session may be in any non-`:awaiting_user` status.
- `reply/4` on `:completed` is treated as `:idle` (per Decision #5) — appends, runs.
- `reply/4` on `:awaiting_tools` raises `ArgumentError` (per Decision #7) — caller should call `submit_tool_result/3 + continue/3` instead.
- `reply/4` on `:error` returns `{:error, %SessionError{reason: :session_in_error_state}}`.
- After `reply/4` (any successful return), the session round-trips.

**`continue/3`:**
- `continue(engine, session, %Message{role: :user, content: "x"})` appends and runs (equivalent to `reply/4`).
- `continue(engine, session, nil)` (per Decision #4) skips the append and runs on `session.thread` as-is. Used for manual-tool-cycle resumption.
- `continue/3` on `:awaiting_tools` with `nil` message raises `ArgumentError` (call `submit_tool_result/3` first; the session must reach `:idle` before `continue/3` is legal).
- `continue/3` on `:awaiting_user` raises `ArgumentError` (call `reply/4`).
- `continue/3` on `:error` returns `{:error, %SessionError{reason: :session_in_error_state}}`.
- After `continue/3`, the session round-trips.

**`step/3`:**
- `step(engine, %Session{status: :idle, thread: t})` calls `Chat.step/3` exactly once and returns `{:ok, session, %StepResult{}}`. Per Decision #6's status transition table, one row per outcome:
  - `:auto` + terminal `:stop` → `done?: true`, `status: :completed`.
  - `:auto` + `:tool_calls` (tools executed) → `done?: false`, `status: :idle`. Caller observes both the tool-result messages on `session.thread` AND the `:idle` status; calling `step/3` again drives the next adapter turn.
  - `:auto` + handler `{:ask_user, _}` → `done?: true`, `status: :awaiting_user`, `pending_question` populated.
  - `:auto` + `on_tool_error: :halt` halt → `done?: true`, `status: :error`.
  - `:manual` + `:tool_calls` → `done?: false`, `status: :awaiting_tools`, `pending_tool_calls` populated.
- `step/3` does NOT loop — verifiable by passing a multi-turn fixture and asserting that calling `step/3` once advances the thread by exactly ONE adapter round-trip's worth of messages (one assistant message + zero or more tool-result messages from inline tool execution).

**`submit_tool_result/3`:**
- `submit_tool_result(%Session{status: :awaiting_tools, pending_tool_calls: [%ToolCall{id: "c0"}]}, "c0", %{ok: true})` returns a session with `:tool` message appended, `pending_tool_calls: []`, `status: :idle`.
- Submit-then-submit on multiple pending tool calls: status stays `:awaiting_tools` until the last one is submitted, then flips to `:idle`.
- `submit_tool_result/3` on `:idle` raises `ArgumentError` (per Decision #7).
- `submit_tool_result/3` for an unknown `tool_call_id` returns `{:error, %SessionError{reason: :unknown_tool_call_id, metadata: %{tool_call_id: "bogus"}}}`. Does NOT raise — this is a data-validation case (per Decision #7's "data mismatches return SessionError" rule).
- After `submit_tool_result/3`, the session round-trips.

**`submit_tool_results/2`:**
- Batch form: `submit_tool_results(session, [{"c0", r0}, {"c1", r1}])` is equivalent to two sequential `submit_tool_result/3` calls. Verify by asserting equality.
- Empty batch: `submit_tool_results(session, [])` is identity (returns the session unchanged). Documented as a no-op.
- A batch containing an unknown id returns `{:error, %SessionError{reason: :unknown_tool_call_id}}` for the FIRST unknown id; the session is unchanged from the input (no partial mutations land). This matches the `Validate` short-circuit semantics from Phase 1.

**Manual-mode end-to-end:**
- `start(engine, [user_msg], mode: :manual)` → session with `:awaiting_tools`; `submit_tool_result/3` for each pending call → session `:idle`; `continue(engine, session, nil)` → session with the next-turn assistant message. Round-trip the session at every boundary.
- **Thread-shape composition (Finding 11):** After the `submit_tool_result × N` calls, `session.thread.messages` ends in `[..., %Message{role: :assistant, metadata: %{tool_calls: [...]}}, %Message{role: :tool, ...}, %Message{role: :tool, ...}]`. Calling `continue(engine, session, nil)` invokes `Chat.run/3` with this thread; assert (a) `Chat.run/3`'s adapter call sees the full thread including the trailing tool-role messages; (b) the next adapter turn is invoked exactly once (no double-execute, no short-circuit); (c) the resulting session's thread equals the thread an `:auto`-mode equivalent run would have produced for the same script. Use a custom Fake fixture whose script asserts the thread tail matches the expected manual-mode shape on its first message.
- **`:auto`-mode equivalence:** Build identical scripts; run one in `:auto` mode (single `start/3`), one in `:manual` mode with the manual-submit cycle. Assert `auto_session.thread.messages == manual_session.thread.messages` modulo the tool-result message ordering relaxation (Phase 6 Non-obvious Decision #9). This is the load-bearing manual-mode interop test.

**Ask-user end-to-end:**
- `start(engine, [user_msg])` against an ask-user fixture → session `:awaiting_user` with `pending_question`; `reply(engine, session, "yes")` → session `:idle` or `:completed`. Round-trip at every boundary.

**`session_id` propagation (Decision #9):**
- A tool handler with arity 2 receives `opts[:session_id] == session.id` when the caller didn't pass `session_id:`.
- A tool handler with arity 2 receives `opts[:session_id] == "caller-supplied"` when the caller passed `session_id: "caller-supplied"`.
- When `session.id == nil`, `opts[:session_id]` is `nil` (default).

**`context` propagation (Decision #10):**
- Same matrix as `session_id` propagation but for `:context`.

#### 8.2.2 Implementation Checklist

- [ ] Create `lib/allm/error/session_error.ex` with the four reason atoms, the `defexception`-style struct (matches the existing error structs' shape), `@spec new/2`, `Jason.Encoder` impl via `ALLM.Serializer.encode_tagged/2`, and `__from_tagged__/1`. Add `validate_reason!/1` private helper that raises `ArgumentError` on unknown atoms.
- [ ] Add `ALLM.Error.SessionError` to `lib/allm/serializer.ex` `@known_modules` list.
- [ ] Extend `lib/allm/error/validation_error.ex`: add `:invalid_session_input` to `@type reason` (line 22) AND to `@legal_reasons` (line 38). Update the moduledoc enumerating legal reasons. Add a unit test in `test/allm/error/validation_error_test.exs` asserting `ValidationError.new(:invalid_session_input, [{:session_input, :invalid_type}])` constructs successfully.
- [ ] Add to `lib/allm/session.ex`:
  - `coerce_session_input/1` — handles `%Session{}`, `%Thread{}`, `[Message.t()]`, anything-else.
  - `ensure_status!/2` — pattern-match on legal status; raise `ArgumentError` on illegal; return `{:error, %SessionError{reason: :session_in_error_state}}` on `:error`.
  - `merge_session_opts/2` — `Keyword.put_new(opts, :context, session.context) |> Keyword.put_new(:session_id, session.id)` (caller-wins; only adds when caller didn't).
  - `apply_chat_result/2` — pattern-match on `chat_result.halted_reason` and produce a session with the right status / pending fields. Field-source map (load-bearing — implementer must hit each row exactly):

    | `chat_result.halted_reason` | `session.status` | `session.pending_tool_calls` | `session.pending_question` | `session.pending_tool_call_id` | `session.metadata` merge |
    |-----------------------------|-------------------|------------------------------|----------------------------|--------------------------------|--------------------------|
    | `:completed`, `:max_turns`, `:halt_when`, custom-atom from handler | `:completed` | `[]` | `nil` | `nil` | `chat_result.metadata` |
    | `:ask_user` | `:awaiting_user` | `[]` | `chat_result.pending_question` | `chat_result.pending_tool_call_id` | `chat_result.metadata` |
    | `:manual_tool_calls` | `:awaiting_tools` | `chat_result.final_response.tool_calls` | `nil` | `nil` | `chat_result.metadata` |
    | `:tool_error` | `:error` | `[]` | `nil` | `nil` | `Map.merge(chat_result.metadata, %{error: chat_result.metadata[:on_tool_error_exception] \|\| chat_result.metadata})` |
    | `:error` | `:error` | `[]` | `nil` | `nil` | `Map.merge(chat_result.metadata, %{error: chat_result.metadata[:error]})` |

    Always sets `session.thread = chat_result.thread`. The `chat_result.final_response.tool_calls` source for `:manual_tool_calls` is per `lib/allm/chat_result.ex:32-50` (the only place tool calls live on `%ChatResult{}`). Pending fields are CLEARED on every non-`:ask_user`/non-`:manual_tool_calls` halt — this is a hard invariant from Decision #7's "pending fields are mutually exclusive" rule.
  - `apply_step_result/2` — same shape as `apply_chat_result/2` but for `%StepResult{}` (used by `step/3` and the StreamReducer single-step branch). Status follows: `done?: true` + no halt → `:completed`; `done?: true` + `halted_reason: :tool_error` → `:error`; etc.
  - The eight public functions per the contracts section.
- [ ] Wire `start/3` → `with` chain: `coerce_session_input → ensure_status! → merge_session_opts → Chat.run → apply_chat_result`.
- [ ] Wire `reply/4` → `continue/3` after building the user message.
- [ ] Wire `continue/3` → `with` chain: `ensure_status! → append (or skip if message == nil) → merge_session_opts → Chat.run → apply_chat_result`.
- [ ] Wire `step/3` → `with` chain: `ensure_status! → merge_session_opts → Chat.step → apply_step_result`.
- [ ] Wire `submit_tool_result/3` → in-process state mutation only: `ensure_status!(session, :awaiting_tools) → find tool_call by id → append tool_result message → drop from pending_tool_calls → flip status to :idle if pending empty`.
- [ ] Wire `submit_tool_results/2` → fold over the batch, propagating the first `{:error, _}`.
- [ ] Update `lib/allm/session.ex` `@moduledoc` to document the status transitions, `:context` propagation, `:session_id` propagation, and the manual-tool-cycle pattern.
- [ ] Add `@spec` matching the contracts section verbatim.
- [ ] Add `@doc` doctests for every public function using `ALLM.Providers.Fake`. **Doctest exception**: `submit_tool_result/3` and `submit_tool_results/2` may construct an `:awaiting_tools` session by hand (e.g. `Session.new(status: :awaiting_tools, pending_tool_calls: [%ToolCall{id: "c0", name: "x", arguments: %{}}], thread: ...)`) instead of driving through `start/3 + Fake`. Document this exception in the function's `@doc` with a one-line note; the Fake-driven setup overwhelms the doc otherwise.

#### 8.2.3 Verification

```bash
mix test test/allm/session_test.exs
mix test test/allm/error/session_error_test.exs
mix test test/allm/session_status_transition_test.exs
mix test                                          # full suite still green
mix credo --strict lib/allm/session.ex
mix credo --strict lib/allm/error/session_error.ex
mix dialyzer
```

### Sub-phase 8.3: Streaming Session API (Layer D)

**Goal:** Implement `stream_start/3`, `stream_reply/4`, `stream_step/3` on `ALLM.Session`. Composes `ALLM.Chat.stream/3` and `ALLM.Chat.stream_step/3`.

**Spec sections:** §11, §13.2.

#### 8.3.1 Test Plan (write first)

`test/allm/session_stream_test.exs` (NEW):

**`stream_start/3`:**
- Happy path: `stream_start(engine, [user_msg])` returns `{:ok, stream}`; consuming the stream yields adapter events plus exactly one `:chat_completed` terminal event whose `result` is a `%ChatResult{}`.
- Pre-flight error (missing adapter) returns `{:error, %EngineError{}}` synchronously; no stream is constructed.
- Pre-flight error from `coerce_session_input/1` returns `{:error, %ValidationError{}}` synchronously.
- Stream events include the Phase 5/6/7 filter pass-throughs (`:emit_text_deltas: false` drops text deltas).

**`stream_reply/4`:**
- Happy path: builds the user message, dispatches via `Chat.stream/3`. Same event shape as `stream_start/3`.
- `stream_reply/4` on `:awaiting_user` clears the pending fields BEFORE constructing the stream (the synchronous step happens at call site; the streaming begins after).
- `stream_reply/4` on `:awaiting_tools` raises `ArgumentError` synchronously.
- `stream_reply/4` on `:error` returns `{:error, %SessionError{}}` synchronously.

**`stream_step/3`:**
- Happy path: returns `{:ok, stream}`; consuming yields adapter events plus exactly one `:step_completed` terminal event (NOT `:chat_completed` — per Decision #11). The stream represents one adapter turn.
- The accompanying `StreamReducer.new/2` call in the test uses `mode: :step` (per Decision #15); `finalize/1` returns `{session, %StepResult{}}` (StepResult, not ChatResult). Verify by asserting `match?({_session, %StepResult{}}, finalize(...))`.

**Stream-cancellation:**
- `Enum.take(stream, 1)` halts the stream early; the upstream Finch ref / Fake adapter is released within 500ms (verified via `assert_receive {:fake_resource_released, _}, 500` against the Phase 4 tracked-engine fixture).

**Reducer integration (cross-test):**
- Build a stream with `stream_start/3`, fold via `StreamReducer`, finalise: the resulting `{updated_session, chat_result}` matches `{Session.start/3 result session, Session.start/3 result chat_result}` for the same input. (This is a sub-test of the equivalence property; the full property test lives in 8.4.)

**Mid-stream error:**
- A Fake script with a mid-stream `:error` event produces `{:chat_completed, %{result: %ChatResult{halted_reason: :error}}}`; `StreamReducer.finalize/1` produces `{%Session{status: :error}, chat_result}`.

**Ask-user thread asymmetry (inherited from Phase 7):**
- `stream_start/3` against an ask-user fixture: `:step_completed.thread` does NOT include the assistant question message; `:chat_completed.result.thread` DOES; `StreamReducer.finalize/1`'s session has `thread == chat_completed.result.thread` (with the question).

#### 8.3.2 Implementation Checklist

- [ ] Add `stream_start/3`, `stream_reply/4`, `stream_step/3` to `lib/allm/session.ex`.
- [ ] `stream_start/3` is `with` chain: `coerce_session_input → ensure_status! → merge_session_opts → Chat.stream/3`. Returns the inner stream verbatim — no extra wrapping. The consumer drives `StreamReducer` themselves; the session-side state updates happen at `finalize/1`, not inside the stream.
- [ ] `stream_reply/4` builds the user message synchronously, calls `stream_start/3`-equivalent path with the user message appended to `session.thread`. Synchronous error paths (status mismatch, error state) return `{:error, _}` BEFORE the stream is constructed.
- [ ] `stream_step/3` is `with` chain: `ensure_status! → merge_session_opts → Chat.stream_step/3`.
- [ ] Document the "pre-flight errors are synchronous; mid-stream errors fold into `:chat_completed`" contract on each function's `@doc` (mirrors Phase 7 invariant).
- [ ] Add `@spec` and a doctest for each.

#### 8.3.3 Verification

```bash
mix test test/allm/session_stream_test.exs
mix test test/allm/session_stream_reducer_test.exs
mix test                                          # full suite still green
mix credo --strict lib/allm/session.ex
mix dialyzer
```

### Sub-phase 8.4: Cross-cutting tests + §31 activation (Layer D)

**Goal:** Activate the §31 session round-trip property scenario. Land the session-equivalence property (`start ≡ stream_start |> finalize`). Land the full status-transition matrix test. Round-trip every operation.

**Spec sections:** §31.

#### 8.4.1 Test Plan (write first)

`test/allm/providers/fake_scenarios_test.exs` (MODIFY) — flip the `@tag :pending` `§31 session round-trip` test to active. Body:

```elixir
test "§31 scenario: session round-trip via term_to_binary" do
  engine = FakeFixtures.engine(scripts: [...])
  {:ok, s1, _} = ALLM.Session.start(engine, [ALLM.user("hi")])
  serialized = :erlang.term_to_binary(s1)
  s1_restored = :erlang.binary_to_term(serialized)
  assert s1 == s1_restored
  {:ok, s2_inproc, _} = ALLM.Session.reply(engine, s1, "more")
  {:ok, s2_resumed, _} = ALLM.Session.reply(engine, s1_restored, "more")
  assert s2_inproc.thread.messages == s2_resumed.thread.messages
end
```

`test/allm/session_equivalence_test.exs` (NEW) — property test:

```elixir
property "Session.start/3 ≡ stream_start/3 |> StreamReducer.finalize/1" do
  check all(script <- multi_turn_script_generator()) do
    engine = FakeFixtures.engine(scripts: script)
    input = [ALLM.user("hi")]
    # In-process isolation per agent-spec/IMPLEMENTATION.md §Property tests.
    {:ok, s1, r1} =
      Task.async(fn -> ALLM.Session.start(engine, input) end) |> Task.await()
    {:ok, stream} =
      Task.async(fn -> ALLM.Session.stream_start(engine, input) end) |> Task.await()
    {s2, r2} =
      stream
      |> Enum.reduce(StreamReducer.new(Session.new()), &StreamReducer.apply_event(&2, &1))
      |> StreamReducer.finalize()
    assert_equivalent_session_result({s1, r1}, {s2, r2})
  end
end
```

The `assert_equivalent_session_result/2` helper extends `assert_equivalent_chat_result/2` (Phase 7) by also asserting `s1.status == s2.status`, `s1.thread.messages == s2.thread.messages` (modulo the existing tool-result ordering relaxation), and `s1.pending_tool_calls == s2.pending_tool_calls`, `s1.pending_question == s2.pending_question`, `s1.pending_tool_call_id == s2.pending_tool_call_id`. `s1.id` and `s1.context` and `s1.metadata` are NOT compared — those are caller-supplied and identical-by-construction.

`test/allm/session_status_transition_test.exs` (NEW) — one test per transition matrix cell (23 tests, per the denormalised matrix in the Overview). For every legal arrow: setup → operation → assert post-status (using `apply_chat_result/2` / `apply_step_result/2`'s field-source map). For every illegal arrow: setup → operation → `assert_raise ArgumentError` (or assert `{:error, %SessionError{reason: :session_in_error_state}}` for the `:error` start state, or `{:error, %SessionError{reason: :unknown_tool_call_id}}` for the data-mismatch case).

`test/allm/session_roundtrip_test.exs` (MODIFY) — add post-operation rows: after `start/3`, `reply/4`, `continue/3`, `step/3`, `submit_tool_result/3` × N, `submit_tool_results/2`, the session round-trips via ETF AND via Jason. One test per operation × scenario shape (≈ 10 tests added).

**Stream-equivalence relaxation budget** (per `agent-spec/DESIGN.md` §6 "Stream-equivalence relaxation budget"):

| Relaxation | Justification | Risk |
|------------|---------------|------|
| Sort `:tool` messages by `tool_call_id` within each step | Phase 6 baseline (parallel `Task.async_stream/5` non-determinism on streaming path; non-streaming path sorts by input index). | tolerable |
| Skip `s1.id` and `s1.context` equality | Identical-by-construction (both paths receive the same input session). Asserting equality would just be a tautology. | tolerable |
| Skip `s1.metadata` / `s2.metadata` equality | Streaming path's collector accumulates per-step adapter metadata; non-streaming `Chat.run/3` does not observe equivalent state. **This relaxation MASKS a divergence between the two paths' `%Session{}` outputs and must be retired before Phase 8.4 ships.** | **masking-divergence** |

**Masking-divergence resolution (load-bearing, blocks 8.4 ship):** the `:metadata` relaxation is recorded as a known divergence with a fix planned during 8.4 implementation. Two candidate fixes (pick at implementation time):

1. **`Session.apply_chat_result/2` strips streaming-only metadata keys** before persisting on `session.metadata`. Identify the divergent keys empirically by running both paths against a multi-turn fixture and diffing the resulting sessions; add the divergent keys to a `@streaming_only_keys` list and drop them at `apply_chat_result/2` time. This is the conservative fix.
2. **Phase 7's `Chat.run/3` is amended to populate the same per-step metadata** that the streaming path observes. This is the cleaner fix but requires touching Phase 7 code; flag it as a Phase 7 amendment if chosen.

Neither fix can ship as a silent skip; the design treats this row as a TODO that 8.4's implementation must close. If the property test passes only with the relaxation in place, the implementation is incomplete.

**Property-test process isolation** is mandatory — per `agent-spec/IMPLEMENTATION.md` "Fake-per-process cursor isolation in equivalence properties," wrap each call in `Task.async/Task.await` so the Fake's process-dictionary cursor doesn't shared-cursor between the streaming and non-streaming arms.

#### 8.4.2 Implementation Checklist

- [ ] Activate the §31 session round-trip scenario in `test/allm/providers/fake_scenarios_test.exs` — flip `@tag :pending` to active, replace the `:ok` body with the actual test.
- [ ] Add `test/allm/session_equivalence_test.exs` with the property test and the `multi_turn_script_generator/0` helper. Use `Task.async`/`Task.await` for cursor isolation (cite `agent-spec/IMPLEMENTATION.md` rule).
- [ ] Add `test/allm/session_status_transition_test.exs` with one test per transition matrix row.
- [ ] Add post-operation round-trip rows to `test/allm/session_roundtrip_test.exs`.
- [ ] Add `assert_equivalent_session_result/2` to `test/support/assertions.ex` (extends `assert_equivalent_chat_result/2` from Phase 7).
- [ ] Add `FakeFixtures.manual_multi_turn/1` and `FakeFixtures.ask_user_then_resume/1` to `test/support/fake_fixtures.ex` per the §Deliverables fixture-shape spec. The existing inventory (verified at design time) does not cover these shapes; both are required by 8.2 / 8.3 / 8.4.
- [ ] Verify the §31 scenario activation hasn't broken any other test by running `mix test --only spec_31` after the flip.
- [ ] Update CHANGELOG with the §31 scenario activation line.

#### 8.4.3 Verification

```bash
mix test --only spec_31                  # the activated scenario
mix test test/allm/session_equivalence_test.exs --include property
mix test test/allm/session_status_transition_test.exs
mix test test/allm/session_roundtrip_test.exs --include roundtrip
mix test                                 # full suite still green
mix test --cover                         # confirm ≥90% on new code; global ≥80%
mix credo --strict
mix dialyzer
mix format --check-formatted
```

## Test Plan (cross-phase summary)

Inherits every Phase 1-7 test plan rule; below is the Phase 8 delta.

- **Per-operation round-trip**: every successful `{:ok, session, _}` return triggers an ETF round-trip assertion in the test. Mechanical, applied via the `assert_session_round_trip/1` helper (added in 8.4 to `test/support/assertions.ex`).
- **Status-transition matrix**: the 23-cell table in §Overview is encoded as 23 unit tests in `test/allm/session_status_transition_test.exs`. Each cell has its own `test "transition: <from> --<op>--> <to | error>" do ... end`. Per `agent-spec/DESIGN.md` §6 "Cross-option × cross-path test matrix" rule, this matrix is exhaustive over the closed status union × the public Phase-8 operation set.
- **Equivalence property**: `Session.start/3 ≡ Session.stream_start/3 |> StreamReducer.finalize/1` for every multi-turn Fake script. Established by construction (both paths call `Session.apply_chat_result/2` at the same boundary); the property test catches drift.
- **§31 activation**: `@tag :pending` flipped to active in `test/allm/providers/fake_scenarios_test.exs` for the session round-trip scenario.
- **Behaviour conformance**: no new behaviour. The Layer-B conformance suites (Phase 3) are unchanged.
- **Doctests**: every new public function has at least one doctest using `ALLM.Providers.Fake`. Per `agent-spec/IMPLEMENTATION.md` §Per-Phase Loop step 7, a second doctest is added when the function has a meaningfully different branch (e.g., `continue/3` with `nil` message vs. with `%Message{}`).
- **Coverage**: ≥90% on every new file (`session/stream_reducer.ex`, `error/session_error.ex`); ≥90% on Phase-8 modifications to `session.ex`. Global ≥80%.

## Error Contract

| Function | Error reason | Recovery guidance |
|----------|--------------|--------------------|
| `start/3`, `stream_start/3` | `%ValidationError{reason: :invalid_session_input}` | Pass a `%Session{}`, `%Thread{}`, or `[Message.t()]`. |
| `start/3`, `reply/4`, `continue/3`, `step/3`, `stream_*` | `%EngineError{reason: :missing_adapter}` | Construct engine with `:adapter`. Inherited from Phase 5. |
| `start/3`, `reply/4`, `continue/3`, `step/3`, `stream_*` | `%EngineError{reason: :missing_stream_adapter}` | Adapter doesn't implement `ALLM.StreamAdapter`. Inherited from Phase 5. |
| `start/3`, `reply/4`, `continue/3`, `step/3`, `stream_*` | `%EngineError{reason: :unknown_tool, metadata: %{tool_name: name}}` | Inherited from Phase 6. |
| `start/3`, `reply/4`, `continue/3`, `step/3`, `stream_*` | `%ValidationError{reason: :invalid_thread \| :invalid_request}` | Inherited from Phase 6. |
| `start/3`, `reply/4`, `continue/3`, `step/3`, `stream_*` | `%AdapterError{reason: _}` | Adapter pre-flight error. Inherited from Phase 5. |
| `start/3`, `reply/4`, `continue/3`, `step/3`, `stream_*` | `%SessionError{reason: :session_in_error_state}` | Session has `status: :error`. Caller must inspect `session.metadata.error` and construct a fresh session. (`reset_error/1` is Phase 9.) |
| `submit_tool_result/3`, `submit_tool_results/2` | `%SessionError{reason: :unknown_tool_call_id, metadata: %{tool_call_id: id}}` | The id doesn't match any `%ToolCall{}` in `session.pending_tool_calls`. Caller bug; verify the id from the prior return tuple's `pending_tool_calls`. |
| `submit_tool_result/3`, `submit_tool_results/2` (no pending) | `%SessionError{reason: :no_pending_tool_call}` | Session has `pending_tool_calls: []`. The session is `:idle` or `:awaiting_user`; this raises before reaching the SessionError path (per Decision #7 status-vs-data split). The atom is reserved for future contexts (e.g., a Phase 9 `submit_tool_result/3` that auto-detects pending status). |
| `submit_tool_result/3` on `:idle` / `:completed` / `:awaiting_user` / `:error` | `ArgumentError` (raise — programmer error per Decision #7) | The session is not in `:awaiting_tools`. Caller pattern-matched on the wrong status. |
| `reply/4` on `:awaiting_tools` | `ArgumentError` | Use `submit_tool_result/3 + continue/3`. |
| `continue/3` on `:awaiting_user` | `ArgumentError` | Use `reply/4`. |
| `continue/3` on `:awaiting_tools` with `nil` message | `ArgumentError` | Caller must complete tool submissions before `continue/3` (per Decision #4). |
| `continue/3` with non-Message non-nil first arg | `FunctionClauseError` | The `@spec` declares `Message.t() | nil`. |
| Bad `max_turns` | `ArgumentError` | Inherited from Phase 7 (`Chat.run/3`'s validation). |

`{:error, term()}` is never returned. Every error is a struct from the closed union `EngineError | AdapterError | ValidationError | SessionError`.

### Field-error atom vocabulary (Phase 8 additions)

| Field path | Reason atom | Hard-reject? | Fires when |
|------------|-------------|--------------|------------|
| `[:session_input]` | `:invalid_session_input` | yes | `coerce_session_input/1` received neither `%Session{}` nor `%Thread{}` nor `[Message.t()]` |

The `:invalid_session_input` atom is added to `ALLM.Validate`'s vocabulary as a scoped Phase 1 extension (one row added to the Phase 1 vocabulary table). No other `Validate.*` reasons are added.

### Hard-reject semantics

Every Phase-8 status precondition is a hard-reject (raise) — there is no accumulating validator at this layer because the operations are point-in-time, not multi-field.

## Streaming & Backpressure

Inherits Phase 5 / 6 / 7's contract verbatim — Phase 8's streaming functions return the same enumerable shapes Phase 7's `Chat.stream/3` and `Chat.stream_step/3` produce. No new `Stream.resource/3` is introduced.

- **Cleanup is mandatory.** The inner `Chat.stream/3` / `Chat.stream_step/3` resource owns its own `after_fun`; Phase 8 doesn't wrap it. Consumer halt → upstream cancellation in ≤500ms (verified by re-using Phase 7's cancellation tests against `Session.stream_*` entry points).
- **Backpressure model.** Same as Phase 5's: consumer-controlled. Phase 8's `StreamReducer` is fold state, not a producer; it doesn't change the backpressure model.
- **Cancellation.** Halting the consumer's enumerable triggers the chain `Session.stream_*` → `Chat.stream/3` → adapter resource. Phase 8 has no own resource to halt.

## Definition of Done

- [ ] All sub-phases marked `Completed` in the status table.
- [ ] `mix test` passes with zero failures; coverage ≥80% globally and ≥90% on every Phase-8 file (`session.ex`, `session/stream_reducer.ex`, `error/session_error.ex`).
- [ ] `mix credo --strict` passes with zero issues on changed files.
- [ ] `mix dialyzer` passes with zero new warnings versus the prior PLT.
- [ ] `mix format --check-formatted` passes.
- [ ] Every new public function has an `@spec` and an `@doc` with at least one runnable doctest using `ALLM.Providers.Fake`.
- [ ] Every Phase-8 operation's post-call session passes the ETF round-trip assertion.
- [ ] Jason round-trip via `ALLM.Serializer` passes for every Phase-8 post-call session (excluding caller-supplied non-roundtrippable types in `:context` per the Phase 1 contract).
- [ ] §31 session round-trip property scenario activated (`@tag :pending` flipped, body populated, passing).
- [ ] Session-equivalence property (`start ≡ stream_start |> finalize`) passes with ≥100 StreamData iterations against the multi-turn fixture set.
- [ ] Status-transition matrix exhaustively tested (24 rows, one test each).
- [ ] CHANGELOG.md updated with one line per public symbol added (12 functions + `StreamReducer` + `SessionError`).
- [ ] Spec section references in commit messages match the §-numbers in the Overview (`§5.7`, `§11`, `§12`, `§12.3`, `§13.2`, `§31`).
- [ ] Reviewed via `/review` per `agent-spec/REVIEW.md`.

**Ticked-with-caveats requires a linked finding.** If the equivalence property ships with any masking-divergence relaxation in its budget table, that tick must link to a retro finding tracking the resolution. As of design-time, none are predicted; implementation-time discoveries get logged as findings, not silent caveats.
