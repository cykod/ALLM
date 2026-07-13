# ALLM Verified Runtime Facts

Executed-evidence facts about the pinned ALLM Hex package. **Reading source is
not verification** — every fact here was proven by running a script against the
Fake adapter (no keys, no network), and each cites its runnable proof. When a
fact matters to your change, re-run the cited script rather than re-deriving.

Append new facts here (with their proof script) instead of restating them in
phase design docs. Re-verify the load-bearing ones when the pinned version
changes.

**Verified against: allm 0.4.3** (`mix.lock`)

> ⚠️ **The bundled guides (`deps/allm/guides/*.md`) are stale — never treat
> them as authority.** Confirmed wrong in at least four load-bearing places
> (facts 4, 5, and 13 below). Trust only executed facts.

Proof scripts (all runnable via `MIX_ENV=test mix run <script>` from the
umbrella root):

- P1 — Phase 1 notes: `steering/20260711_PHASE_1_CORE_FOUNDATION.md` (Implementation Notes 1.4/1.5)
- B1 — `.work/reviews/2026-07-11-phase2-batch1/exercise/exercise_tools_wiring.exs`
- B2a — `.work/reviews/2026-07-11-phase2-batch2/exercise/exercise_allm_session_facts.exs`
- B2b — `.work/reviews/2026-07-11-phase2-batch2/exercise/exercise_interviewer_turns.exs`
- B3 — `.work/reviews/2026-07-12-phase2-batch3/exercise/exercise_eval_suite.exs`
- B4 — `.work/reviews/2026-07-12-phase3-batch2/exercise/exercise_tool_ack_order.exs`
- B5 — `.work/reviews/2026-07-12-phase3-batch2/exercise/exercise_halted_reason.exs`
- B6 — `.work/reviews/2026-07-12-phase4-batch1/exercise/exercise_no_tools_stream_reply.exs`

## Streaming & events

1. **`ALLM.stream_generate/3` emits `message_started → text_delta →
   text_completed → message_completed` and no `:step_completed`.** Only
   `ALLM.stream/3`'s chat loop emits `{:step_completed, %{response:
   %ALLM.Response{}}}` (payload also carries `:thread`/`:mode`/
   `:manual_tool_calls`). [P1, B2a]
2. **Event order for a tool-calling streamed turn (auto mode):**
   `message_started → tool_call_started → tool_call_completed →
   message_completed → tool_execution_started → tool_execution_completed →
   tool_result_encoded → step_completed → message_started → text_delta →
   text_completed → message_completed → step_completed →
   chat_completed{result: %ALLM.ChatResult{}}`. The loop runs the follow-up
   LLM step automatically after tool results; `chat_completed` is terminal —
   its absence in consumed events means the turn was cancelled. [B2a]
3. **Fake streams do not terminate at `{:error, _}` events** — the error
   surfaces mid-stream and the stream continues. Scan collected events for
   `{:error, _}` before folding deltas (`MonvieCore.LLM.find_error_event/1` /
   `error_from_adapter/1` / `text_from_events/1` own this). [P1, B2a]
19. **A no-tools `ALLM.Session.stream_reply` turn under `max_turns: 1`**
    emits text deltas (join == the scripted text), a `{:step_completed,
    %{response: %ALLM.Response{model: nil}}}` (fact 15's fallback applies),
    and a **terminal** `{:chat_completed, %{result: %ChatResult{
    halted_reason: :completed}}}`; `StreamReducer` finalize over the same
    events reports `:completed` with `final_response.output_text` == the
    text and a `[:user, :assistant]` thread (`session.thread.messages` — the
    thread is a struct, not enumerable). **`max_turns: 1` is honored**
    (discriminating case): a step finishing `{:finish, :tool_calls}` spends
    the turn budget → `halted_reason: :max_turns`, in two shapes: a ghost
    `{:tool_call, ...}` entry with no `tools:` passed **also surfaces an
    `{:error, %{reason: :unknown_tool}}` event** (the error path wins for
    fact-3-scanning consumers), while a **bare** `{:finish, :tool_calls}`
    with no tool_call entry is the *clean* truncation — `:max_turns`, no
    error event, the step's partial text preserved in the deltas (the
    deterministic scripting shape for an abnormally-halted no-tools turn).
    Error paths: pre-flight errors return `{:error, %{reason: _}}`
    synchronously; a mid-stream `{:error, _}` event does not terminate the
    stream (fact 3 holds on this path). [B6]

## Sessions

4. **Session calls are engine-first and return 3-tuples**:
   `ALLM.Session.start/3`, `reply(engine, session, text, opts)`, `continue/4`
   → `{:ok, %Session{}, %ChatResult{}}`. There is **no** top-level
   `ALLM.stream_reply`; the streaming entry is
   `ALLM.Session.stream_reply(engine, session, text, opts)` → `{:ok, stream}`
   (pre-flight failures return `{:error, _}` synchronously). The guides show
   session-first and 2-tuples — wrong. [B2a]
5. **Tool handlers live on the tool**: `ALLM.tool(name:, description:,
   schema:, handler: fn args -> ... end)` (arity-1 or arity-2 with a ctx
   keyword list). The guides' `tool_executor: {ALLM.ToolExecutor.Default,
   tools: %{...}}` engine form **crashes** at `tool_runner.ex:532`. Handler
   returns: `{:ok, term}`, `{:error, reason}`, `{:ask_user, prompt, meta}`,
   `{:halt, reason, result}`. [B1, B2a]
6. **Stream fold pattern**: `ALLM.Session.StreamReducer.new(session)` /
   `apply_event/2` / `finalize/1` → `{session_after, %ChatResult{}}` — works
   identically for full consumption and mid-stream abandonment. [B2a]
7. **ETF round-trip is lossless** (`binary_to_term(term_to_binary(s)) == s`);
   **JSON (`ALLM.Serializer.to_json!/1` / `from_json/1`) is functional but
   not `==`** — map-typed `metadata`/`context` come back string-keyed with
   tagged maps (`metadata["tool_calls"]`), so never read `message.metadata`
   by atom key after a JSON restore. ETF is the canonical `SessionStore`
   blob shape. [B2a, B2b]
8. **Cancellation = stop consuming; there is no cancel API.** Stream-resource
   cleanup runs; `finalize/1` returns `halted_reason: :cancelled` and drops
   the turn wholesale (the just-sent user message is NOT retained; partial
   text only in `result.final_response.output_text`). `finalize/1` normalizes
   `status` to `:completed`, so a first-turn cancel on an `:idle` session
   changes `status` — assert **thread equality + resumability**, never
   whole-struct `==`. [B2a, B2b]
9. **Thread history after a tool turn**: `:user` msg; `:assistant` msg with
   `content: ""` and tool calls in **`metadata.tool_calls`** (not a top-level
   field); `:tool` msg with JSON content + `tool_call_id`; final `:assistant`
   text msg. [B2a]

## Tool errors

10. **A handler's `{:error, term}` feeds back to the model and the loop
    continues** (default `on_tool_error: :continue`) — no `{:error, _}`
    event. A raising handler is wrapped as `%ALLM.Error.ToolError{reason:
    :handler_raised}` and likewise fed back. `on_tool_error: :halt` emits
    `{:tool_halt, ...}` and ends the turn with `halted_reason: :tool_error`.
    [B1, B2a]
11. **Handler error terms reach the model as inspected strings** —
    `{"error": "<inspect(term)>"}`, not structured JSON. Never assert
    structured-JSON error content in `:tool` messages; put the
    self-correction hint in the term's text. [B1]
12. **`ALLM.Error.AdapterError` reasons are a closed enum** — check
    `ALLM.Error.AdapterError.legal_reasons/0` before scripting
    `{:error_event, reason, []}` / `{:preflight_error, reason, []}`
    (e.g. `:overloaded` raises `ArgumentError`; use `:provider_unavailable`).
    [B2a]

## Fake adapter scripting

13. **Fake script cursors are per-engine** (`ALLM.Engine.new/1` assigns a
    unique id keying the cursor): a deterministic script spanning multiple
    turns requires threading **one engine** through the conversation — a
    fresh engine per turn silently restarts the script. (An earlier
    "shared-by-script-hash" claim was falsified by executing the
    discriminating two-engine case.) [B2a, B3]
14. **Fake tool-call `arguments:` maps must be string-keyed** — live
    providers JSON-decode to string keys; atom-keyed scripts test a shape
    that never occurs live. Multi-step turns script as `stream_script:`
    list-of-lists (one list per LLM step), tool calls as keyword entries:
    `{:tool_call, id: "c1", name: "...", arguments: %{"k" => v}}` +
    `{:finish, :tool_calls}`. [B1, B2a]
15. **The Fake `%ALLM.Response{}` has `model: nil`** — always pass
    `engine.model` as `Provenance.stamp/6`'s `fallback_model`; extract
    streamed responses with `MonvieCore.LLM.response_from_events/1` (returns
    `nil` for `stream_generate/3` streams). [P1]

17. **Multiple tool calls in ONE step execute concurrently — their
    `{:tool_execution_completed, _}` ack order is nondeterministic** (200
    loaded runs of a 3-call step produced 5 distinct orders). One tool call
    per step executes in step order (200 runs, exactly one order).
    Deterministic tests that depend on ack order must script **one tool
    call per `stream_script` step**; ack-consuming builders must be
    order-tolerant. [B4]
18. **`ALLM.ChatResult.halted_reason` is `:completed` on a normally
    completed turn — never `nil`** — and `:max_turns` when the turn-loop
    budget truncated the run (`:cancelled` / `:tool_error` per facts 8/10).
    Consumers detecting abnormal halts must treat `:completed` as "not
    halted" rather than testing for `nil`
    (`MonvieCore.LLM.halted_reason/1` owns this mapping). [B5]

## Missing APIs

16. **ALLM has no embeddings API** (checked against 0.4.3) — the in-memory
    `RetrievalStore` uses deterministic lexical scoring; embeddings are a
    Phase 3/7 concern outside ALLM. [P1]

## Verification discipline (how facts earn a row here)

A check must be able to fail if the claim is false: include the discriminating
case that would falsify it (a second engine, a fresh `:idle` session, the
error path), and assert the specific fields the contract needs — never
whole-struct `==`. Two Phase 2 checks passed for the wrong reason before this
rule (facts 8 and 13).
