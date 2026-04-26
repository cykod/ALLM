## [DOC] Apply 11 retros into design + implementation spec docs
*Sunday, April 26th at 7pm*
Lifted 12 high-priority findings from 11 unapplied retros (Phase 9 through 
Phase 11.4) into the canonical agent docs. AGENT_DESIGN_SPEC.md gains six new 
Behaviour design-doc checklist rules (14-19) covering Layer-C reducer-touch 
enumeration, per-provider wire-field maps, synthesized-vs-recorded fixture 
policy, detection-mechanism for state-conditioned behavioural deltas, the 
provider-neutral examples _helpers.exs template, and live-API cost estimation. 
AGENT_IMPLEMENTATION_SPEC.md adds wall-clock timing assertion guidance under 
Layer C tests and a new sub-section 4i on closed-enum dual-validation (protocol 
vs provider acceptance). CLAUDE.md gains an 
adapter-default-for-required-wire-field invariant plus four 
Working-on-this-codebase rules: BLOCKING per-provider live-validation, 
cross-phase bug discipline, Logger deferred form for hot paths, and SSE 
chunk-mapper one-function-per-event-type pattern. All 11 retros renamed to 
_applied.md (gitignored, not staged).

---

## [FEAT] Phase 11.4: provider-neutral examples framework + Anthropic enrollment
*Sunday, April 26th at 5pm*
Migrates the nine runnable example scripts from examples/openai/ up to a
unified provider-neutral examples/ directory and introduces examples/_helpers.exs
with a provider table keyed by ALLM_PROVIDER (default "openai"; "anthropic"
added as the second row per spec §32.1). Each script's first lines are now
Code.require_file("_helpers.exs", __DIR__) + engine = ExamplesHelpers.engine()
(or .engine(tools: [...])); the helper centralizes EnvLoader-based .env
auto-load, validates the per-provider *_API_KEY env, honors ALLM_MODEL
override, and bakes params: %{temperature: 0} for cross-provider determinism.
06_structured_output.exs now branches on ALLM_PROVIDER to assert
metadata.structured_output_tool == true only for Anthropic per Phase 11
Decision #4 (OpenAI's native :json_schema response carries no equivalent
marker). examples/run_all.exs is the BLOCKING /review validation gate — it
must exit 0 against BOTH providers; per-provider RUN_OUTPUT_OPENAI.md and
RUN_OUTPUT_ANTHROPIC.md snapshots are committed alongside.

---

## [FEAT] Phase 11: Anthropic provider (non-streaming + streaming + structured output)
*Sunday, April 26th at 4pm*
Lands ALLM.Providers.Anthropic implementing both Adapter and StreamAdapter 
behaviours with non-streaming generate/2 (Req-backed, Retry integration 
including 529 Overloaded per spec §6.4), streaming stream/2 (Finch HTTP/1 + 
SSE → ALLM.Event mapper per §7.2 §8 Decision #14), and structured output 
via the tool-forcing pattern (§5.4) sharing lift_structured_output/1 between 
both arms. Decision #5b is amended: streamed structured-output now emits 
:text_delta events (matching OpenAI's native :json_schema streaming) so 
consumers can write provider-neutral structured-output streaming code; the 
stream wrapper additionally stamps metadata.structured_output_tool: true on the 
rewritten :message_completed payload so invariant 14's byte-identical 
%Response{} guarantee holds across arms (M1 fix from the Phase 11.3 review). 
Coverage on the new adapter is 91.10%; full suite 1401 tests / 0 failures, 
credo and dialyzer clean.

---

## [FEAT] Phase 10: OpenAI provider (both endpoints) + BYOK fix
*Sunday, April 26th at 1pm*
Ships ALLM.Providers.OpenAI implementing both ALLM.Adapter and
ALLM.StreamAdapter against /v1/chat/completions and /v1/responses,
including endpoint dispatch (gpt-5* and o-series → Responses, gpt-4*
→ Chat Completions), reasoning controls (reasoning_effort,
reasoning_summary, verbosity), structured_finalize two-pass
orchestration in ALLM.Chat, ALLM.Capability.preflight contract
widened to optionally rewrite the request, ALLM.Providers.Support.SSE
line-buffered decoder shared with future Anthropic adapter, and
default ALLM.Finch HTTP/1 pool started by ALLM.Application. Adds 9
runnable example scripts under examples/openai/ targeting
gpt-5.4-nano with a run_all.exs orchestrator validated live against
the real provider — the BLOCKING /review gate caught and led to
fixes for five wire-shape bugs (tool envelope per endpoint,
reasoning-opts endpoint override, Responses input encoder for tool
round-trips, Responses output[] tool-call decoder, streaming
function_call SSE handlers). Also fixes a per-call api_key leak in
StreamRunner.build_dispatch_opts/2 so SaaS BYOK works end-to-end via
ALLM.generate(engine, req, api_key: tenant_key), and stops Chat from
forwarding orchestration opts (:mode, :max_turns, :halt_when) into
the runner. 1272 tests / 0 failures across 6 sub-phases (10.1
through 10.6).

---

## [FEAT] Phase 9: telemetry, retry, capability, ModelRef
*Saturday, April 25th at 11pm*
Ships Phase 9 in four sub-phases: ALLM.Telemetry wraps every Layer C entry 
point with :telemetry.span/3 and threads a per-call request_id through 
generate/stream/step/chat plus per-tool spans inside ToolRunner (spec §29); 
ALLM.Retry runs the spec §6.1 default policy with bounded additive jitter and 
emits [:allm, :adapter, :retry] per attempt, integrated end-to-end via the Fake 
adapter's retry_until_call: opt; ALLM.Capability adds 
preflight/populate_costs/select gated on Code.ensure_loaded?(LLMDB) with an 
Application.put_env override-based dep-free smoke test, plus the ALLM.ModelRef 
Layer A struct (spec §6.3) and the :unsupported_capability ValidationError 
vocabulary extension. Test suite grows from 1054 to 1095 tests (0 failures); 
coverage 94.79 percent global with 100/97/95 percent on the new modules; mix 
credo --strict and mix dialyzer remain clean. The :allm event prefix is used 
throughout in deliberate deviation from spec §29's [:llm, ...] (Decision #15) 
— a non-blocking spec-amendment ticket follows.

---

## [FEAT] Phase 8: ALLM.Session stateful continuation
*Saturday, April 25th at 7pm*
Implements Layer D ALLM.Session stateful continuation per spec §11 and §13.2. 
Adds Session.start/3, reply/4, continue/3, step/3, submit_tool_result/3, and 
submit_tool_results/2 over a persisted %ALLM.Session{} with a 5-status state 
machine (:idle, :running, :awaiting_tools, :awaiting_user, :completed, :error). 
Adds ALLM.Session.StreamReducer wrapping StreamCollector with a :chat | :mode 
flag for streaming Layer D, ALLM.Error.SessionError as a new Layer A error 
struct (closed :reason enum), and extends ValidationError with 
:invalid_session_input. Phase 8.4 cross-cutting tests include a StreamData 
property asserting Session.start ≡ stream_start |> finalize, an exhaustive 
25-row status-transition matrix, post-operation ETF + Jason round-trip rows, 
and activation of the §31 session round-trip scenario (all 12 §31 scenarios 
now active). Empirical verification of the masking-divergence row in 
PHASE_8_DESIGN.md §8.4.1 found no metadata divergence between streaming and 
non-streaming arms; assert_equivalent_session_result/2 asserts :metadata 
unconditionally.

---

## [FEAT] Phase 7: chat/3 + stream/3 multi-turn orchestration loop
*Saturday, April 25th at 5pm*
Ships the first Layer C surface that orchestrates the full multi-turn loop. 
ALLM.chat/3 repeatedly runs step/3, appending results to the thread until a 
terminal condition fires (adapter finish_reason, :max_turns exhausted, 
:halt_when callback, handler-requested {:halt, _, _} or {:ask_user, _}, 
on_tool_error: :halt, or :manual mode surfacing tool calls). ALLM.stream/3 
emits every Phase-5/6 event across every turn plus exactly one terminal 
:chat_completed event carrying the final %ChatResult{}. Adds StreamCollector 
:step_completed/:chat_completed fold clauses, the ToolRunner on_tool_error 
function form, ask-user thread mutation at the turn boundary (spec §12.3), and 
a chat-equivalence property asserting chat/3 ≡ stream/3 |> 
StreamCollector.to_chat_result/1 across every multi-turn Fake fixture. 
Activates §31 max_turns/halt_when/manual scenarios; all 857 tests + 18 
properties green.

---

## [FEAT] Phase 6: step/3 + stream_step/3 with parallel tool execution
*Friday, April 24th at 10pm*
Implements Phase 6 sub-phases 6.1-6.4 across three batches: ALLM.ToolRunner 
(parallel Task.async_stream dispatch + on_tool_error policy), ALLM.Chat.step/3 
+ stream_step/3 (three-phase Stream.resource state machine), the ALLM.step/3 + 
stream_step/3 facade, and a 100-iteration step-equivalence property proving 
step ≡ stream_step |> collect. Extends StreamCollector with :tool_results and 
:halt fields plus three fold clauses, activates three §31 scenarios (single 
tool call auto, parallel tool calls, handler raises), and renames @phase_7_opts 
to @orchestration_opts. Folds nine retro findings into AGENT_DESIGN_SPEC, 
AGENT_IMPLEMENTATION_SPEC, and CLAUDE.md (sub-phase retro cadence, shared test 
helpers threshold, primitive-vs-composition verification, struct-field 
structural rule, mid-stream error contract, and others). Test suite: 140 
doctests, 17 properties, 726 tests, 0 failures.

---

## [FEAT] Phase 4+5: Fake adapter + generate/stream_generate facade
*Friday, April 24th at 6pm*
Ships Phase 4 (ALLM.Providers.Fake scripted adapter implementing both
ALLM.Adapter and ALLM.StreamAdapter, plus ALLM.Providers.Fake.Script helper
and ALLM.Test.FakeFixtures test-support fixtures) and Phase 5 (Layer C
execution: ALLM.StreamCollector fold state, ALLM.StreamRunner and ALLM.Runner
internal runners, and the ALLM.generate/3 + ALLM.stream_generate/3 public
facade). The :message_completed event payload additively gains an optional
:finish_reason key (tag count stays at 16). The stream-equivalence property
exercises 100 random §31 fixtures asserting generate ≡ stream_generate |>
collect, and three §31 scenarios previously tagged :pending are now active.
622 tests / 132 doctests / 15 properties green; credo --strict, dialyzer,
format, hex.build all clean. See steering/PHASE_4_DESIGN.md, PHASE_5_DESIGN.md,
and spec §3, §4, §8, §10.1, §10.2, §13.1, §17, §19, §20, §30, §31.

---

## [FEAT] Phase 3: Behaviour contracts, defaults, conformance harness
*Friday, April 24th at 1pm*
Hardens the four Layer B behaviours (ALLM.Adapter, StreamAdapter, ToolExecutor, 
ToolResultEncoder) with rich moduledocs, per-callback docs, and 
error-struct-tightened return types. Ships two default implementations — 
ALLM.ToolExecutor.Default with arity-1/2 dispatch and raise/exit/throw 
conversion to %ToolError{}, and ALLM.ToolResultEncoder.JSON with binary 
passthrough plus Jason-backed encoding — both at 100% coverage. Publishes the 
allm_conformance sibling Hex package under conformance/ with four 
ExUnit.CaseTemplate harnesses (47 injected cases across 
Adapter/StreamAdapter/ToolExecutor/ToolResultEncoder), a permanent StubAdapter 
fixture implementing both adapter behaviours, and harness self-tests; main 
project certifies its defaults via a path-dep on the sibling. Three accumulated 
retros drove AGENT_DESIGN_SPEC and AGENT_IMPLEMENTATION_SPEC refinements: §3 
consolidated into a five-class empirical-verification rule (stdlib exceptions, 
project closed-atom enums, stdlib function failure modes on OTP floor, 
macro-expansion-wrapped raises, opaque-term returns) plus hedge-word guidance, 
and §16 now names both conformance shipping shapes with the Shape-B PLT gotcha 
(plt_add_apps: [:ex_unit]) documented. Main suite: 323 → 393 tests, 0 
failures, 0 credo issues, 0 dialyzer errors; conformance sub-project: 55 tests.

---

## [FEAT] Phase 1 + 2: Layer A data, Engine resolver, Keys chain
*Thursday, April 23rd at 12pm*
Ship Phase 1 and Phase 2 of the ALLM library end-to-end: Layer A data structs 
(Message, Request, Response, Thread, Session, StepResult, ChatResult, Event, 
Tool, ToolCall, Usage) with term_to_binary + Jason round-trip, the 
ALLM.Validate validator, the ALLM.Serializer tagged-JSON encoder/decoder, the 
full Phase 1 error hierarchy under ALLM.Error.*, and the lib/allm.ex facade 
with doctests (Phase 1). On top of that, Phase 2 adds ALLM.Engine's resolver 
API (merge_opts/2, resolve_model/2, resolve_tools/2, resolve_params/2), engine 
serializability via __from_tagged__/1 + Jason.Encoder, the five-level ALLM.Keys 
resolution chain (opts -> runtime Agent -> app_config -> env -> .env), and 
ALLM.Application supervising ALLM.Keys.Store. Suite stands at 323 tests, 96 
doctests, 12 properties, 0 failures, global coverage 96.59%. Also captures the 
process artifacts (AGENT_*_SPEC.md, steering design docs, retros, reviews, 
CHANGELOG) built via the retro-driven build discipline across both phases.

---

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Phase 9.4 — `ALLM.Capability` + `ALLM.ModelRef` + LLMDB optional gate (spec §6.3)

#### Added
- `ALLM.ModelRef` — new Layer A struct (spec §6.3 lines 637-648). Carries the catalog's view of a single model: `:provider`, `:id`, `:capabilities`, `:limits`, `:pricing` (per-million-token rates), and an opaque `:metadata` bag. Plain serializable data; ETF round-trip is byte-identical, JSON round-trip preserves the outer struct shape with the documented Layer-A nested-map asymmetry (opaque map fields keep STRING keys post-`Jason.encode!/1` → `Serializer.from_json/1`, matching the Phase 1 `Engine.metadata` carve-out). Registered in `ALLM.Serializer.@known_modules`. `__from_tagged__/1` restores `:provider` via `String.to_existing_atom/1`; opaque map fields hydrate as-is.
- `ALLM.Capability` — new Layer B helper (spec §6.3). Three public functions, all gated on the optional `LLMDB` Hex package's load state: `preflight/2` (rejects `request.tools != []` against tools-disabled models with `{[:tools], :tools_disabled}`; rejects `response_format: %{type: :json_schema, ...}` against non-`json_native` models with `{[:response_format], :json_native_disabled}`; both errors accumulate in a single `%ValidationError{reason: :unsupported_capability}`). Pattern-matches both atom-keyed and string-keyed `:capabilities` shapes so JSON-rehydrated `%ModelRef{}` values pre-flight identically to in-process ones. `populate_costs/2` fills `Usage.{input_cost, output_cost, total_cost}` from per-million-token pricing (never overwrites a non-nil cost); tolerates string-keyed pricing maps. `select/1` delegates to `LLMDB.select/1` for capability-based selection. `catalog_loaded?/0` checks `Application.get_env(:allm, :force_capability_absent, false)` BEFORE `Code.ensure_loaded?(Module.concat(["LLMDB"]))` so the dep-free smoke test can simulate catalog absence.
- `ALLM.Error.ValidationError.@type reason` and `@legal_reasons` extended with `:unsupported_capability` (one new atom; surfaces from `Capability.preflight/2` only).
- `test/support/llm_db.ex` — test-only fake catalog mimicking the published `:llm_db` Hex package surface verbatim (no `ALLM.` prefix). Compiled only in `:test` via `elixirc_paths(:test)`. Provides a small fixture catalog covering `openai:gpt-4.1-mini` (tools + json_native + pricing), `local:no-tools` (tools-disabled), and `local:no-json-native` (non-`json_native`).

#### Changed
- `ALLM.StreamRunner.run/3` — pre-flight chain now calls `Capability.preflight(resolved_request.model, request)` after `ALLM.Validate.request/1` and after `Engine.resolve_model/2`. The resolved `%ModelRef{}` (or bare string/tuple) is threaded into opts as `:resolved_model` for downstream `Capability.populate_costs/2` calls. `@phase_5_layer_opts` strip-list extended with `:resolved_model` and `:request_id` (Phase 9 internal — must not leak to adapters).
- `ALLM.Runner.do_run/3` and `ALLM.Chat.transition_a_to_b/1` — populate `Usage` cost fields via `Capability.populate_costs/2` post-collection (not in `StreamCollector` — keeps the collector Layer-A/pure and avoids an LLMDB-loaded conditional inside the fold). Phase 9 design Decision #5.
- `mix.exs` — no `{:llm_db, ...}` line added per Phase 9 design Decision #6 / DoD line 745. Detection is via `Code.ensure_loaded?(Module.concat(["LLMDB"]))` at runtime.

### Phase 9.3 — `ALLM.Retry` (spec §6.1)

#### Added
- `ALLM.Retry` — new internal Layer B helper. `default_policy/0` returns the spec §6.1 closed map (`max_attempts: 3`, `base_delay_ms: 500`, `max_delay_ms: 30_000`, `retry_on: [429, 500, 502, 503, 504, :timeout]`, `jitter_ms: 250`, `respect_retry_after: true`). `materialize/1` accepts `:default | false | keyword()`; unknown keys raise `ArgumentError` (a typo like `max_atempts:` fails loudly). `run/3` invokes a closure under a materialised policy with bounded exponential backoff and additive `[0, jitter_ms]` jitter; emits `[:allm, :adapter, :retry]` per attempt with measurements `%{system_time}` and metadata `%{attempt, delay_ms, reason}` plus caller-supplied `:request_id` / `:provider`. Closure-raised exceptions propagate unchanged (spec §6.1 "exception is not retryable"). The final attempt emits no retry event — the surrounding `[:allm, :adapter, :stop]` span fires instead.
- `ALLM.Providers.Fake` — non-streaming `generate/2` now wraps adapter dispatch in `Retry.run/3` when `adapter_opts: [retry_until_call: n]` is set, returning `{:retry, 0, :timeout}` until the n-th call; the streaming `stream/2` arm does NOT call `Retry.run/3` (spec §6.1 prohibits streaming retries).

#### Notes
- **v0.2 surface caveat** — the public Layer-C entry points (`ALLM.generate/3`, `ALLM.step/3`, `ALLM.chat/3`) all route through `ALLM.StreamRunner` which calls the adapter's streaming callback. Per spec §6.1 streaming calls are not retried, so retry telemetry does not fire from any public façade in v0.2; it fires only when adapters are invoked directly (the Fake retry round-trip). Real-provider Phase 10/11 adapters reuse `Retry.run/3` from their non-streaming `c:ALLM.Adapter.generate/3` callbacks. Documented inline in `ALLM.Retry` and `ALLM.Runner` `@moduledoc`s. See review Finding #3.

### Phase 9.2 — Tool spans (spec §29)

#### Added
- `ALLM.ToolRunner` — per-tool `[:allm, :tool, :start | :stop | :exception]` spans wrap `execute_one_tool/3` inside the `Task.async_stream/5` worker process so `:duration` reflects only that tool's execution and the auto-exception trap captures only that tool's raise (Phase 9 design Decision #9). Metadata: `:tool` (`%ALLM.Tool{}`), `:tool_call` (`%ToolCall{}`), `:engine`, `:model` (lifted from the engine for parity with the other Layer-C spans — review Finding #4 fix), `:request_id` (threaded from the wrapping `:step`/`:chat` span via `opts[:request_id]`); `:stop` adds `:result` (the dispatch tuple). For `Task.async_stream/5`-killed timeouts (`:on_timeout: :kill_task`), the parent process synthesises `[:allm, :tool, :exception]` with `%{kind: :exit, reason: :timeout, duration: 0}` since the killed worker can't reach its `:stop` arm.

### Phase 9.1 — Telemetry spans + `:request_id` correlation (spec §29)

#### Added
- `ALLM.Telemetry` — new internal Layer B helper. `event_prefix/0` returns `[:allm]` (Phase 9 design Decision #15 — uses the project namespace, not the spec §29 `[:llm, ...]` prefix; spec amendment slated as non-blocking follow-up). `request_id/0` produces a 22-character URL-safe Base64 id from 16 cryptographic random bytes. `span/3` wraps a closure in `:telemetry.span/3` under `[:allm, name]` for `name in [:generate, :stream, :step, :chat, :tool]`; raises `ArgumentError` on unrecognised names (typo guard). `execute/3` emits a single non-span event under `[:allm | suffix_path]` (used by `ALLM.Retry`).
- `ALLM.Runner.run/3` and `ALLM.StreamRunner.run/3` — wrapped in `Telemetry.span(:generate, ...)` / `Telemetry.span(:stream, ...)`. Common metadata: `:request_id`, `:engine`, `:model`. `:generate :stop` carries `:response` (the reduced `%Response{}`); `:stream :stop` carries `:response => nil` per the documented carve-out (materialising the wrapped enumerable would defeat consumer-driven laziness — see review Finding #2 and `ALLM.Telemetry.span/3` `@doc`).
- `ALLM.Chat.run/3`, `ALLM.Chat.stream/3`, `ALLM.Chat.step/3`, `ALLM.Chat.stream_step/3` — wrapped in `Telemetry.span(:chat, ...)` / `Telemetry.span(:step, ...)`. `:request_id` is generated at the outermost call and threaded into inner calls via `opts[:request_id]` (Phase 9 Decision #7). `Response.request_id` is populated post-collection so a consumer who never attaches a telemetry handler still has the correlation id on the response.

#### Changed
- `ALLM.Response` — `:request_id` populated post-collection in every Phase-5/6/7/8 path (DoD line 741). The id matches the outermost span's `:request_id` metadata; populated only when the underlying span generated a fresh id (i.e., not when an adapter set `request_id` on the response itself).
- `ALLM.StreamRunner` `@phase_5_layer_opts` — extended with `:request_id` so the telemetry-correlation id is read by this module but stripped from adapter-facing opts.

### Phase 8.4 — Cross-cutting tests + §31 session round-trip activation

#### Added
- `test/allm/session_equivalence_test.exs` — new `StreamData` property test (`@moduletag :property`) asserting `ALLM.Session.start/3 ≡ ALLM.Session.stream_start/3 |> StreamReducer.finalize/1` across 100 iterations over a multi-turn fixture generator (0–2 tool-calls turns + a terminating text turn against the `echo` tool). Each iteration isolates Fake's per-process cursor via `Task.async/Task.await` per `AGENT_IMPLEMENTATION_SPEC.md` §Property tests. Uses the new `assert_equivalent_session_result/2` helper.
- `test/allm/session_status_transition_test.exs` — exhaustive 25-row status-transition matrix test covering every `(status, op)` cell from `PHASE_8_DESIGN.md` §Overview: legal arrows assert post-status; illegal status mismatches assert `ArgumentError` raise; `:error`-state cells assert `{:error, %SessionError{reason: :session_in_error_state}}`; the data-mismatch row asserts `{:error, %SessionError{reason: :unknown_tool_call_id}}` for `submit_tool_result/3` with a stale id.
- `ALLM.Test.Assertions.assert_equivalent_session_result/2` — new test-support helper. Extends `assert_equivalent_chat_result/2` with `s1.status == s2.status`, thread equality (modulo Phase 6 tool-result `tool_call_id` sort), and `pending_*` field equality. `:metadata` is asserted unconditionally — no silent skip. `:id` and `:context` are excluded as identical-by-construction. Accepts both `{Session, ChatResult}` and `{Session, StepResult}` tuple shapes.
- `ALLM.Test.Assertions.assert_session_round_trip/2` — new test-support helper. ETF round-trip asserted unconditionally; Jason round-trip asserted on every `%Session{}` field except those listed in `opts[:exclude]`. `:exclude` defaults to `[]` (full Jason equality) per `PHASE_8_DESIGN.md` §8.4.1 Invariants 1.
- `ALLM.Test.FakeFixtures.manual_multi_turn/2` — new test-support fixture. Accepts a list of `{tool_name, args, tool_result_text}` triples and produces a multi-script Fake-adapter engine driven via `start(mode: :manual) → submit_tool_result × N → continue(nil)`.
- `ALLM.Test.FakeFixtures.ask_user_then_resume/2` — new test-support fixture. Accepts `{question, answer_text}` and produces a two-script engine for the `start → reply(answer)` flow. Caller supplies the ask-user tool handler via `:tools` opt.
- `test/allm/session_roundtrip_test.exs` — added 10 post-operation round-trip rows covering `start/3`, `reply/4`, `continue/3` (with both `%Message{}` and `nil` message), `step/3`, `submit_tool_result/3` (final + intermediate), `submit_tool_results/2`, `:awaiting_user → reply/4` cycle, and `:error`-status mid-stream-error session. ETF round-trip asserted unconditionally; Jason round-trip excludes `:thread` / `:metadata` for post-`Chat.run/3` cases (Message metadata atom keys are not restored on JSON round-trip per the Phase 1 caller-owned-metadata contract).

#### Changed
- `test/allm/providers/fake_scenarios_test.exs` — flipped the §31 session round-trip scenario from `@tag :pending` to active. The activated test exercises `Session.start/3 → :erlang.term_to_binary → :erlang.binary_to_term → Session.reply/4` across a two-script Fake fixture and asserts the resumed thread matches the in-process thread. All 12 §31 scenarios are now active; the moduledoc table is updated.

#### Notes
- **Masking-divergence resolution.** `PHASE_8_DESIGN.md` §8.4.1 reserved a `masking-divergence` row in the relaxation table for `:metadata` between the streaming and non-streaming paths and required a load-bearing fix before Batch 3 ships. Empirical verification (multi-turn / max_turns / manual / ask_user / adapter-error / halt_when fixtures, both arms diffed) found **no metadata divergence**: both paths construct the `%ChatResult{}` via the same `ALLM.Chat.build_chat_result/1` helper (`lib/allm/chat.ex:535`), and `Session.apply_chat_result/2` projects bytewise-identical `cr.metadata` onto both sides. The row is therefore not needed; `assert_equivalent_session_result/2` asserts `:metadata` unconditionally.

### Phase 8.1 + 8.2 — Non-streaming Session API + `ALLM.Session.StreamReducer` + `ALLM.Error.SessionError`

#### Added
- `ALLM.Session.start/3` — new public Layer D function (spec §11). Coerces a `%Session{}` / `%Thread{}` / `[Message.t()]` input via `coerce_session_input/1`, dispatches to `ALLM.Chat.run/3`, and projects the resulting `%ChatResult{}` onto a fresh `%Session{}` via `apply_chat_result/2`. Returns `{:ok, %Session{}, %ChatResult{}}` or `{:error, %EngineError{} | %AdapterError{} | %ValidationError{} | %SessionError{}}`. Phase 8 Decision #2.
- `ALLM.Session.reply/4` — new public Layer D function (spec §11). Sugar for `continue/3` with a `%Message{role: :user}` built from the supplied text. Legal on `:idle`, `:awaiting_user` (clears pending fields), `:completed`. Phase 8 Decision #4.
- `ALLM.Session.continue/3` — new public Layer D function (spec §11). Drives the next adapter turn; accepts `Message.t() | nil`. The `nil` form skips the append and runs on `session.thread` as-is — used for manual-tool-cycle resumption (Phase 8 Decision #4).
- `ALLM.Session.step/3` — new public Layer D function (spec §11). Single-turn entry point dispatching to `ALLM.Chat.step/3`; does NOT loop. Status follows Phase 6 step semantics via `apply_step_result/2`. Phase 8 Decision #6.
- `ALLM.Session.submit_tool_result/3` — new public Layer D function (spec §11, return-type widened per Decision #14). In-process state mutation only — no adapter call. Appends a `:tool`-role message to `session.thread` (encoding map content via `Jason.encode!/1` so the resulting thread passes `ALLM.Validate.thread/1`), drops the matched `%ToolCall{}` from `pending_tool_calls`, flips `status` to `:idle` when the last pending call is submitted. Returns `t()` on success or `{:error, %SessionError{reason: :unknown_tool_call_id}}` on a stale id. Phase 8 Decision #3.
- `ALLM.Session.submit_tool_results/2` — new public Layer D function (spec §11). Batch form folding `submit_tool_result/3` over `[{id, content}]` pairs; first-error-wins short-circuit (no partial mutations) matches `ALLM.Validate`'s hard-reject semantics. Empty list is identity.
- `ALLM.Session.apply_chat_result/2` and `ALLM.Session.apply_step_result/2` — new internal `@doc false def` helpers projecting `%ChatResult{}` / `%StepResult{}` onto a session. Cross-module visibility is required because `ALLM.Session.StreamReducer.finalize/1` calls them (per Phase 8.1.2 "Visibility decision"). Field-source map matches the table in `steering/PHASE_8_DESIGN.md` §8.2.2.
- `ALLM.Session.StreamReducer` — new Layer D module (spec §13.2). Wraps a `%StreamCollector{}` plus the originating `%Session{}` and a `:mode` flag (`:chat | :step`). `new/2` validates `:mode` against the closed set; `apply_event/2` delegates to `StreamCollector.apply_event/2` and never short-circuits; `finalize/1` dispatches per Phase 8 Decision #15 — `:chat` returns `{Session.apply_chat_result(session, cr), %ChatResult{}}` (using `StreamCollector.to_chat_result/1`'s `:cancelled` fallback when no `:chat_completed` was folded), `:step` returns `{Session.apply_step_result(session, sr), %StepResult{}}` for the first observed step or `{session, %ChatResult{halted_reason: :cancelled}}` when no step completed.
- `ALLM.Error.SessionError` — new Layer A error struct (spec §20 atom-vocabulary extension). Closed `:reason` enum: `:session_in_error_state | :invalid_status_for_operation | :no_pending_tool_call | :unknown_tool_call_id`. Mirrors the existing `EngineError` / `AdapterError` shape: `:reason`, `:message`, `:provider` (always `nil`), `:cause`, `:metadata`. Implements `Jason.Encoder` via `ALLM.Serializer.encode_tagged/2` and `__from_tagged__/1`; registered in `ALLM.Serializer.@known_modules` so JSON round-trips. `validate_reason!/1` private helper raises `ArgumentError` on unknown atoms.

#### Changed
- `ALLM.Error.ValidationError.@type reason` and `@legal_reasons` extended with `:invalid_session_input` (one new atom). Surfaces as `{:error, %ValidationError{reason: :invalid_session_input}}` from `ALLM.Session.start/3` and `stream_start/3` (Batch 2) when the second arg is neither `%Session{}` nor `%Thread{}` nor a list of `%Message{}`. Per Phase 8 §Prerequisites — scoped Phase 1 vocabulary extension.
- `ALLM.Session` — `@moduledoc` rewritten to document the Phase-8 status-transition matrix (5 statuses × 5 operations, with status-mismatch raise vs. data-mismatch error tuple), mid-stream error projection (`halted_reason: :error` → `status: :error` + `metadata.error`), the manual-tool-cycle pattern (start `:manual` → `submit_tool_result/3 × N` → `continue/3 nil`), `:context` propagation (caller-wins via `merge_session_opts/2`), and `:session_id` propagation (caller-wins; no opt added when `session.id == nil`). Phase 1 helpers (`new/1`, `append/2`, `append_user/2`, `append_tool_result/3`, `pending_tool_calls/1`, `messages/1`, `__from_tagged__/1`) preserved verbatim.

### Phase 7.5 — `ALLM.chat/3` + `ALLM.stream/3` facade + chat-equivalence property + §31 activations

#### Added
- `ALLM.chat/3` — new public facade function (spec §4, §10.5). Pure one-line delegation to `ALLM.Chat.run/3`; multi-turn non-streaming orchestration. `@doc` covers `:mode`, `:max_turns` precedence chain (Phase 7 Non-obvious Decision #9), `:halt_when` semantics (Decision #11), `:on_tool_error` including the function form (Decision #8), the halt-reason table, and the `:on_event` adapter-only scope (Decision #13). One runnable Fake two-turn doctest.
- `ALLM.stream/3` — new public facade function (spec §4, §10.6). Pure one-line delegation to `ALLM.Chat.stream/3`; multi-turn streaming orchestration emitting exactly one terminal `:chat_completed` event (Decision #3) carrying a `%ChatResult{}` constructed via the same `ALLM.Chat.build_chat_result/1` helper as `ALLM.chat/3` (Decision #4 — chat-equivalence by construction). `@doc` covers single-terminal-event invariant, ask-user thread asymmetry (Invariant 8), and `:on_event` scope. One runnable Fake two-turn doctest asserting exactly one `:chat_completed`.
- `ALLM.Test.Assertions.assert_equivalent_chat_result/2` — new test-support helper. Compares two `%ChatResult{}` values: `:halted_reason`, `:pending_question`, `:pending_tool_call_id`, and `:final_response` exact; `:metadata` modulo `:halt_result` (documented Phase 6/7 streaming-vs-non-streaming gap — see test moduledoc); thread split into non-`:tool` (positional) and `:tool`-role (sorted by `:tool_call_id`); `:steps` element-wise via a private `assert_equivalent_chat_step/2` that strips halt-induced sentinel tool messages from `:tool_results` before comparison.
- `test/allm/chat_equivalence_test.exs` — `StreamData` property test (`@moduletag :property`) asserting `ALLM.Chat.run(engine, thread, opts) ≡ ALLM.Chat.stream(engine, thread, opts) |> Enum.reduce(StreamCollector.new(thread), &apply_event/2) |> StreamCollector.to_chat_result/1` across 100 iterations over eight named fixtures (happy multi-turn, `max_turns: 1`, single-turn text, `halt_when` at step 1, manual mode, ask-user mid-loop, custom halt atom, `on_tool_error: fn _, _ -> {:continue, %{ok: 1}} end`). Each iteration isolates Fake's per-process cursor via `Task.async/1`. The `:on_tool_error_halt` fixture from Phase 7 design 7.5.1 is excluded — see BLOCKER notes in test moduledoc and Batch 4 report.
- `test/allm/allm_chat_test.exs`, `test/allm/allm_stream_test.exs` — facade-level tests covering happy paths, `%EngineError{reason: :missing_adapter}` pre-flight, list-of-messages normalisation, and delegation-invariant equality (both facades under `Task.async/1` to isolate cursor state). Each module registers its own `doctest ALLM` so the `@doc` example runs as part of the test suite.
- `test/allm/providers/fake_scenarios_test.exs` — three §31 scenarios activated: "max_turns cap" (three-turn tool-call script + `chat/3` with `max_turns: 2` → `halted_reason: :max_turns`, `metadata.max_turns == 2`, `length(steps) == 2`), "halt_when fires" (two-turn fixture + `halt_when: fn sr -> sr.tool_results != [] end` → `halted_reason: :halt_when`, `metadata.halt_when_step_index == 0`, `length(steps) == 1`), and "single tool call with `mode: :manual` — partial flow via `chat/3`" (newly added; single-turn tool-call script + `mode: :manual` → `halted_reason: :manual_tool_calls`, `metadata.manual_turn_index == 0`, empty `tool_results`). The two `@tag :pending` placeholders for `max_turns` and `halt_when` were flipped to active. The "session round-trip (Phase 8)" placeholder remains pending. Scenario table in the moduledoc updated to 12 active / 1 pending.

### Phase 7.4 — `ALLM.Chat.stream/3` (multi-turn streaming, internal)

#### Added
- `ALLM.Chat.stream/3` — new internal Layer C entry point (spec §17). Composes `Chat.stream_step/3` enumerables sequentially via a two-phase `Stream.resource/3` state machine (Phase 7 Non-obvious Decision #1) driven by the same `Enumerable.reduce/3` continuation idiom as Phase 6's `stream_step/3`. Emits adapter events + tool events for each turn, one `:step_completed` per turn, then exactly one terminal `:chat_completed` event (Decision #3) carrying a `%ChatResult{}` constructed via `build_chat_result/1` (Decision #4). Ask-user thread asymmetry per Invariant 8: `:step_completed.thread` lacks the question; only `:chat_completed.result.thread` includes it. Cleanup chain: outer `after_fun` halts the active step's continuation, which triggers `stream_step/3`'s own cleanup chain.

### Phase 7.3 — `ALLM.Chat.run/3` (multi-turn non-streaming, internal)

#### Added
- `ALLM.Chat.run/3` — new internal Layer C entry point (spec §17). Multi-turn non-streaming orchestrator composing `Chat.step/3` calls via `Enum.reduce_while/3` over a `%Chat.LoopState{}`. Honours `:max_turns` (call-opts > `engine.params` > `Application.get_env(:allm, :max_turns)` > library default 8 — Phase 7 Non-obvious Decision #9), `:halt_when` (Decision #11), `:on_tool_error` (atom + function forms — Decision #8), and the seven-entry `terminal_condition/5` total order (Decision #5). Halt-reason vocabulary: `:completed`, `:max_turns`, `:halt_when`, `:ask_user`, `:tool_error`, `:manual_tool_calls`, `:error`, plus user custom atoms.
- `ALLM.Chat.LoopState` — new internal Layer C struct (Phase 7 Non-obvious Decision #4). Carries the loop's accumulator (`engine`, `opts`, `initial_thread`, `thread`, `max_turns`, `steps`, `step_index`, `halted_reason`, `halt_metadata`, `pending_question`, `pending_tool_call_id`, `last_response`). Both `Chat.run/3` and `Chat.stream/3` build their `%ChatResult{}` via the single `build_chat_result/1` helper, which takes a `%LoopState{}` — chat-equivalence is established by construction.

### Phase 7.2 — `ALLM.ToolRunner` `on_tool_error` function form

#### Changed
- `ALLM.ToolRunner.run_tool_calls/3` / `stream_tool_calls/3` — `:on_tool_error` `(ToolCall.t(), term() -> {:continue, term()} | :halt)` function form is now active (Phase 6's `ArgumentError` guard relaxed). Function is invoked synchronously inside the per-tool `Task.async_stream/5` task after the handler's return / encoder failure resolves to an error term (Phase 7 Non-obvious Decision #8); `{:continue, replacement}` encodes `replacement` as the tool-result content, `:halt` halts the batch with `halted_reason: :tool_error`. Invalid return shapes and function raises are wrapped as `%ToolError{reason: :invalid_return}` and treated as `:halt` (recursion-avoidance — function not re-invoked on its own failure). Function-arity validation (`is_function(fun, 2)`) raises `ArgumentError` at validation time on wrong arity.

### Phase 7.1 — `ALLM.StreamCollector` extension

#### Changed
- `ALLM.StreamCollector` — struct gains a `:chat_result` field (`ChatResult.t() | nil`). Two new fold clauses (`:step_completed`, `:chat_completed`) inserted immediately before the catch-all per Phase 5 Non-obvious Decision #5: `:step_completed` appends a computed `%StepResult{}` to `state.steps` and resets per-step sub-state (`:current_text`, `:current_tool_calls`, `:tool_call_order`, `:tool_results`, `:halt`, `:finish_reason`, `:raw_finish_reason`, `:error`) so the next step folds cleanly (Phase 7 Non-obvious Decision #6). `:chat_completed` stores the payload's `:result` on `state.chat_result` and sets `state.done? = true`. `to_chat_result/1` extended to prefer the stored `:chat_result` when present and to compute a Phase-7-aware fallback (`:cancelled` for consumer-halted streams, `:error` for mid-stream adapter errors) when absent. `step_done?/1` and `merge_halt_metadata/2` promoted from `defp` to `def` (`@doc false`) for cross-module reuse from `Chat.step_result_from_outer_collector/4` (Phase 7 retro F2).

### Phase 6.3 + 6.4 — `ALLM.step/3` + `ALLM.stream_step/3` facade + step-equivalence property + §31 activation

#### Added
- `ALLM.step/3` — new public facade function (spec §4, §10.3). Pure one-line delegation to `ALLM.Chat.step/3`; accepts either an `%ALLM.Thread{}` or a list of `%ALLM.Message{}` as the second arg. `@doc` carries a runnable Fake + inline tool doctest.
- `ALLM.stream_step/3` — new public facade function (spec §4, §10.4). Pure one-line delegation to `ALLM.Chat.stream_step/3`; returns `{:ok, stream}` where the stream emits adapter events → tool-execution event groups → exactly one terminal `:step_completed`. `@doc` carries a runnable Fake + inline tool doctest.
- `ALLM.Test.Assertions` — new test-support module (`test/support/assertions.ex`, not shipped in the Hex package). Exports `assert_equivalent_step_result/2` which compares two `%StepResult{}` values modulo a `tool_call_id` sort on `:tool_results` and on `:tool`-role thread messages (per PHASE_6_DESIGN.md Non-obvious Decision #9). Every other field (`:response`, `:done?`, non-tool-role thread messages, `:metadata`) is compared by exact `==`.
- `test/allm/step_equivalence_test.exs` — `StreamData` property test (`@moduletag :property`) asserting `ALLM.step(engine, thread, mode: :auto) ≡ ALLM.stream_step(engine, thread, mode: :auto) |> reduce(collector) |> to_step_result/1` across 100 randomly generated tool-call-bearing Fake scripts. A second property at 25 iterations covers mid-execution handler failures (`on_tool_error: :continue`). Each iteration isolates Fake's per-process cursor via `Task.async/1` so the two paths see fresh process-dict cursors. Thread extraction from the `:step_completed` event payload compensates for the `StreamCollector` catch-all no-op on that tag (Phase 7 may add explicit handling).
- `test/allm/providers/fake_scenarios_test.exs` — three Phase 6 §31 scenarios activated as new describe blocks: "single tool call with `mode: :auto`" (through `ALLM.step/3` with an echo tool), "parallel tool calls through `ALLM.step/3`" (two tools, order-independent tool_results assertion), "tool handler raises, `on_tool_error` policy fires" (covers atom forms `:continue` and `:halt`; function form deferred to Phase 7 with an inline comment). The existing `@tag :pending` placeholder for the handler-raises scenario was removed; three `@tag :pending` placeholders remain for Phase 7/8 (max_turns, halt_when, session round-trip). Moduledoc scenario table updated to reflect the 9-active / 3-pending split.
- `test/allm/allm_step_test.exs`, `test/allm/allm_stream_step_test.exs` — facade-level tests covering happy paths, pre-flight `%EngineError{reason: :missing_adapter}`, list-of-messages normalisation, and delegation-invariant equality (both facades under `Task.async/1` to isolate cursor state).

### Phase 6.2 — `ALLM.Chat.step/3` + `ALLM.Chat.stream_step/3` + `StreamCollector` extension

#### Added
- `ALLM.Chat` — new internal Layer C module (spec §17). Ships `step/3` (non-streaming single-turn orchestrator) and `stream_step/3` (streaming variant). Normalises `thread_or_messages` (list of `%Message{}` → `ALLM.Thread.from_messages/1`), validates the thread via `ALLM.Validate.thread/1`, dispatches the adapter call via `ALLM.Runner.run/3` / `ALLM.StreamRunner.run/3`, then branches on `:mode` and `response.finish_reason`. `mode: :manual` + `:tool_calls` surfaces tool calls without executing handlers and sets `StepResult.metadata.mode: :manual` (NOT a halt — Finding F2). `mode: :auto` + `:tool_calls` dispatches to `ALLM.ToolRunner.run_tool_calls/3` / `ALLM.ToolRunner.stream_tool_calls/3`, appends tool-role messages to the thread, and surfaces halt metadata (`:tool_error`, `{:halt, reason, result}`, `{:ask_user, ...}`) via `StepResult.metadata`. Assistant-message construction uses `response.output_text` (collector-authoritative) per PHASE_6_DESIGN.md Non-obvious Decision #10. Ask-user handler returns do NOT append an `:assistant` message with `metadata.ask_user: true` in Phase 6 (Non-obvious Decision #6); that thread mutation is Phase 7's concern. `stream_step/3` composes via a single three-phase `Stream.resource/3` state machine (Phase A drives the adapter stream, Phase B drives `ToolRunner.stream_tool_calls/3`, Phase C emits exactly one `:step_completed` event) — one outer resource, no wrapping (Non-obvious Decision #1). Event sequence invariant: all adapter events → zero-to-N tool-execution event groups → exactly one terminal `:step_completed`. No new `ALLM.Event` variants added. No new error-reason atoms added. Error table inherited from Phase 5 plus `%EngineError{reason: :unknown_tool}` from Phase 6.1.

#### Changed
- `ALLM.StreamCollector` — struct gains two fields (`:tool_results: []`, `:halt: nil`) and three new fold clauses (`:tool_result_encoded`, `:tool_halt`, `:ask_user_requested`) inserted immediately before the catch-all per Phase 5 Non-obvious Decision #5. `:tool_result_encoded` appends a `%Message{role: :tool, tool_call_id: id, content: content, metadata: %{}}` to `:tool_results`; `:tool_halt` and `:ask_user_requested` set `:halt` on first observation (first-halt-wins via `halt: nil` guard on the clause head — subsequent halts fall to the catch-all no-op). `to_step_result/1` now reads `:tool_results` from the struct (was hardcoded `[]`), computes `done?` via `step_done?/1` (`halt != nil or finish_reason in [:stop, :length, :content_filter, :error]` — was derived from `:finish_reason` alone), and merges halt metadata into `StepResult.metadata` via `merge_halt_metadata/2` (`{:halt, reason, id}` → `%{halted_reason: reason, halt_tool_call_id: id}`; `{:ask_user, :ask_user, id, q, o}` → `%{halted_reason: :ask_user, pending_tool_call_id: id, pending_question: q, ask_user_opts: o}`). Per PHASE_6_DESIGN.md §StreamCollector extension, Non-obvious Decision #11, and Invariants 1–7. `:tool_execution_started`, `:tool_execution_completed`, and `:step_completed` stay in the catch-all; Phase 7 may add explicit clauses for `:step_completed`. Totality property still holds across the 16-tag closed union.

### Phase 6.1 — `ALLM.ToolRunner` + `StreamRunner` attribute rename

#### Added
- `ALLM.ToolRunner` — new internal Layer C module (spec §17). Ships `run_tool_calls/3` (non-streaming, returns `{:ok, [Message.t()]} | {:ok, [Message.t()], halt_metadata} | {:error, %EngineError{}}`) and `stream_tool_calls/3` (streaming, returns an enumerable of `ALLM.Event` values — Phase 6 extension to spec §17 per PHASE_6_DESIGN.md Non-obvious Decision #2). Both variants share `execute_one_tool/3` for dispatch + encoding + `on_tool_error` policy. Parallel execution via `Task.async_stream/5` with `ordered: false`, `max_concurrency: max(1, min(length(tool_calls), System.schedulers_online() * 2))` default, `on_timeout: :kill_task`, `zip_input_on_exit: true`; per-tool `tool_timeout` (default 30_000 ms). Unknown-tool pre-flight returns `{:error, %EngineError{reason: :unknown_tool, metadata: %{tool_name: name}}}` synchronously (non-streaming) or a single-element error stream (streaming); no tools execute. Empty `tool_calls` short-circuits to `{:ok, []}` / `Stream.concat([])` to guard against `Task.async_stream/5`'s `ArgumentError` on `max_concurrency: 0`. Handler-return dispatch covers all five spec §5.2 shapes: `{:ok, _}`, `{:error, _}` (policy-routed), `{:ask_user, _}` / `{:ask_user, _, _}` (content `"<awaiting user response>"` per spec §12.3; halt with ask-user metadata), `{:halt, reason, result}` (halt with tool_halt metadata). Encoder failures (`Protocol.UndefinedError`, `Jason.EncodeError`) caught and wrapped as `%ToolError{reason: :encoding_failed}`, then routed through `on_tool_error` (Non-obvious Decision #3). Function form of `on_tool_error` raises `ArgumentError` mentioning Phase 7. Sibling-drain on halt (Invariant 3): `Task.async_stream/5` runs to natural exhaustion on handler halt; first-halt-wins (earliest input-index) for `halt_metadata`. No new `ALLM.Event` variants added. No new error-reason atoms added.

#### Changed
- `ALLM.StreamRunner` — internal module-attribute rename (no behavioural change): `@phase_7_opts` → `@orchestration_opts`, `strip_phase_7_opts/1` → `strip_orchestration_opts/1`, `Logger.debug/1` message "Phase 7 opt" → "orchestration opt", `@moduledoc` section heading "Phase 7 opts are stripped" → "Orchestration opts are stripped". Contents unchanged (`[:mode, :max_turns, :halt_when]`). Phase 6 consumes `:mode` at the `ALLM.Chat` layer (Phase 6.2); StreamRunner's deny-list remains as the safety-net before adapter dispatch. Per PHASE_6_DESIGN.md Non-obvious Decision #5.

### Phase 5.4 — Stream-equivalence property + §31 scenario wiring

#### Added
- `test/allm/stream_equivalence_test.exs` — `StreamData` property test module (`@moduletag :property`) asserting `ALLM.generate/3 == ALLM.stream_generate/3 |> reduce(StreamCollector) |> to_response` across 100 randomly generated §31 scripts. Separate property covers mid-stream `{:error, reason}` equivalence (finish_reason and metadata.error agreement). Each iteration runs `generate/3` and `stream_generate/3` in isolated `Task.async/1` processes so Fake's per-process cursor doesn't collide across the two calls.
- `test/allm/providers/fake_scenarios_test.exs` — flipped three `@tag :pending` placeholders to active tests: pure text streaming with `emit_text_deltas: false`, mid-stream adapter error through `stream_generate/3` + `generate/3`, and consumer cancellation releasing Fake's `:counters` observer. Added a halt-safety-through-filters regression assertion (same 10-event fixture + `emit_text_deltas: false` + `Enum.take(stream, 2)` → observer increments within 500 ms) pinning Phase 5 Non-obvious Decision #6.

### Phase 5.3 — `ALLM.Runner` + `ALLM.generate/3`

#### Added
- `ALLM.Runner` — new internal Layer C module (spec §17). `run/3` delegates to `ALLM.StreamRunner.run/3`, folds the returned stream through `ALLM.StreamCollector.new/0 |> apply_event/2` and emits `{:ok, %Response{}}` via `to_response/1`. Pre-flight errors bubble verbatim; mid-stream `{:error, _}` events fold into `%Response{finish_reason: :error, metadata: %{error: struct}}` per Non-obvious Decision #4 — `run/3` still returns `{:ok, _}` in that case. The `include_raw_chunks: false` filter's usage carve-out (§StreamRunner Decision #9) means the collector always sees `{:raw_chunk, {:usage, _}}` regardless of caller intent, so no Runner-side filter override is needed. `@moduledoc` begins with "Internal — use `ALLM.generate/3` instead." (Non-obvious Decision #10).
- `ALLM.generate/3` — new public facade function (spec §4, §10.1). Pure delegation to `ALLM.Runner.run/3`; `@doc` carries a runnable Fake doctest demonstrating the non-streaming path.

### Phase 5.2 — `ALLM.StreamRunner` + `ALLM.stream_generate/3`

#### Added
- `ALLM.StreamRunner` — new internal Layer C module (spec §17). `run/3` validates (`:missing_adapter` → `:missing_stream_adapter` via `Code.ensure_loaded?/1 + function_exported?(adapter, :stream, 2)` → `ALLM.Validate.request/1`), resolves model/params via `ALLM.Engine`, dispatches to `engine.adapter.stream/2`, and post-processes the returned stream. Post-processing composes `Stream.each/2` (for `:on_event`) with `Stream.filter/2` (for `:emit_text_deltas`, `:emit_tool_deltas`, `:include_raw_chunks`) — no extra `Stream.resource/3` wrap (per PHASE_5_DESIGN Non-obvious Decision #6). `{:raw_chunk, {:usage, _}}` events always pass the filter regardless of `:include_raw_chunks` (usage carve-out per Non-obvious Decision #9). `:on_event` exceptions surface in the consumer's reducing process — no `try/rescue` (per Non-obvious Decision #7). `@moduledoc` begins with "Internal — use `ALLM.stream_generate/3` instead." (per Non-obvious Decision #10).
- `ALLM.stream_generate/3` — new public facade function (spec §4, §10.2). Pure delegation to `ALLM.StreamRunner.run/3`; `@doc` carries a runnable Fake doctest.

#### Changed
- Phase 7 orchestration opts (`:mode`, `:max_turns`, `:halt_when`) are deny-listed at the `StreamRunner` boundary and never reach the adapter — prevents a future `Jason.encode!` trip on a `:halt_when` fun when real provider adapters land (per Non-obvious Decision #11). `Logger.debug/1` fires once per stripped key.

### Phase 5.1 — `:message_completed` finish_reason + `ALLM.StreamCollector`

#### Added
- `ALLM.StreamCollector` — new Layer C module (spec §13.1). Reduces an `ALLM.Event` stream into a `%Response{}` (`to_response/1`, thread-less), `%StepResult{}` (`to_step_result/1`), or `%ChatResult{}` (`to_chat_result/1`). Ships `new/0` (Phase 5 extension per PHASE_5_DESIGN Non-obvious Decision #3), `new/1` (accepts `nil` or `%Thread{}` per Non-obvious Decision #3), and `apply_event/2` with nine explicit per-tag clauses plus a catch-all (per Non-obvious Decision #12). Mid-stream `{:error, _}` events fold into `finish_reason: :error` + `metadata.error: struct` so `to_response/1` never returns `{:error, _}` (per Non-obvious Decision #4). `{:raw_chunk, {:usage, map}}` applies `struct!(ALLM.Usage, map)` — documented pass-through that raises `KeyError` on unknown fields (adapter-side contract).
- `ALLM.Event.message_completed/2` — new arity adding an explicit `finish_reason` argument (`is_atom(fr) or is_nil(fr)` guard). `message_completed/1` now emits `finish_reason: nil` for back-compat.

#### Changed
- `:message_completed` event payload additively gains an optional `:finish_reason` key (`Response.finish_reason() | nil`). Tag count stays at 16; `event?/1` accepts both shapes (with and without the key). See PHASE_5_DESIGN Non-obvious Decision #1 for the back-compat guarantee. `ALLM.Providers.Fake` threads the reason from `{:finish, reason}` script entries into the terminal `:message_completed` event.

### Phase 4 — `ALLM.Providers.Fake` scripted adapter

#### Added
- `ALLM.Providers.Fake` — deterministic scripted adapter (Layer B) implementing both `ALLM.Adapter` and `ALLM.StreamAdapter`. Accepts two disjoint script shapes on `adapter_opts` (spec §31 user-facing and Phase 3 harness), supports multi-call sequencing via a per-process cursor with an explicit Agent-backed override (`start_script_cursor/0` / `cursor_index/1`), honours `{:delay, ms}` / `{:sleep, ms}` for backpressure testing, and exposes a `:cleanup_observer` (`:counters` ref) hook for halt-safety assertions. Passes the 13-case `ALLM.Test.AdapterConformance` and 14-case `ALLM.Test.StreamAdapterConformance` harnesses unchanged. See spec §7.1, §7.2, §8, §20, §30, §31.
- `ALLM.Providers.Fake.Script` — pure helper module (Layer B) for shape detection (`detect_shape/1`), boundary validation (`validate!/1`), non-streaming fold (`fold_to_response/1`), and per-entry event translation (`interpret/1`). Shared interpreter for `:finish` / `:tool_call` tags across both script vocabularies; `:error` disambiguates by tuple arity.
- `ALLM.Test.FakeFixtures` — test-support library (`test/support/fake_fixtures.ex`, not shipped in the Hex package) with eight named `adapter_opts` fixtures: `plain_text/1`, `single_tool_call/2`, `parallel_tool_calls/1`, `multi_turn_conversation/1`, `mid_stream_error/1`, `empty_response/0`, `tool_call_with_streamed_args/2` (codepoint-safe split), and `delayed_text/2`. Per Phase 4 design Non-obvious Decision #10.
- `:no_scripted_response` added to `ALLM.Error.AdapterError.@legal_reasons` (12th reason atom, scoped to testing adapters). Spec §31 preserves the bare-atom form; Phase 1's narrowed `{:error, %AdapterError{}}` behaviour contract carries it on the struct's `:reason` field.
- `test/allm/providers/fake_scenarios_test.exs` — three spec §31 scenarios covered today (pure text streaming with `emit_text_deltas: true`, parallel tool calls, mid-stream adapter error) plus six `@tag :pending` placeholders naming the phase that will cover each deferred scenario. `@moduletag :spec_31` allows `mix test --only spec_31` to scope the audit.

### Phase 3.5 — `allm_conformance` Sibling Package + Harness Wiring

#### Added
- `allm_conformance` — new sibling Hex package (in-repo sub-project at `conformance/`, app `:allm_conformance`, version `0.2.0`). Ships four `ExUnit.CaseTemplate`-based harnesses under the `ALLM.Test.*` namespace (`ALLM.Test.AdapterConformance`, `ALLM.Test.StreamAdapterConformance`, `ALLM.Test.ToolExecutorConformance`, `ALLM.Test.ToolResultEncoderConformance`). Consumer install is one line (`{:allm_conformance, "~> 0.2", only: :test}`); no `elixirc_paths` surgery. See `conformance/README.md` for usage and release checklist. Per PHASE_3_DESIGN.md §Non-obvious Decision #1.
- `ALLM.Test.Fixtures.StubAdapter` — permanent scripted test fixture (in `conformance/test/support/`, not exported) implementing both `ALLM.Adapter` and `ALLM.StreamAdapter`. Drives the harness's own self-tests; script shape documented in its `@moduledoc`.
- 43 conformance self-tests across the sub-project (12 + 6 + 10 + 7 injected cases plus 8 meta-tests covering case-count stability and missing-opt `KeyError`).
- Main project `mix.exs` now declares `{:allm_conformance, path: "conformance", only: :test}` so the two default implementations (`ALLM.ToolExecutor.Default`, `ALLM.ToolResultEncoder.JSON`) certify against the harness: `test/allm/tool_executor/default_test.exs` and `test/allm/tool_result_encoder/json_test.exs` each plug in via `use ALLM.Test.<...>Conformance, ...`.
- `LICENSE` files at the repo root and in `conformance/` (MIT, Pascal Rettig) — prerequisite for `mix hex.build`.

#### Notes
- The design doc's `StreamError` mid-stream reason table named `:truncated | :malformed_chunk | :connection_dropped`, but the Phase 1 committed `ALLM.Error.StreamError` enum is `:adapter_error | :cancelled | :timeout | :malformed_event | :unknown`. The conformance suite uses the committed atoms (`:cancelled` in the self-test case) per `AGENT_DESIGN_SPEC.md §3`'s empirical-verification rule.

### Phase 2.4 — Engine Integration Test

#### Added
- `test/allm/engine_integration_test.exs` — four end-to-end scenarios proving the Phase 2 surface composes: (1) serialize → fresh process → deserialize → resolve identically; (2) runtime keys (`ALLM.Keys.put/2`) do not leak into the serialized engine (structural walk, not substring search on the ETF binary); (3) opts-win precedence end-to-end across `resolve_model/2`, `resolve_tools/2`, `resolve_params/2`; (4) `{Module, :function}` MFA tool handlers round-trip through `:erlang.term_to_binary/1` regardless of whether the module is loaded at decode time. Tagged `@moduletag :integration` so the suite can be scoped via `mix test --only integration`.

#### Changed
- `ALLM.Engine.@engine_field_keys` deny-list now includes `:params`. Without this, `resolve_params/2` would have attempted to merge a caller-supplied `opts[:params]` value (including `nil`) into `engine.params` via the opts pathway, contradicting Invariant 6's prose "opts with engine-field keys excluded." Surfaced by Sub-phase 2.4 Scenario 3; see PHASE_2_DESIGN.md Non-obvious decision #5 implementation note.

### Phase 2.2 — Keys + Application

#### Added
- `ALLM.Keys` module with five-level resolution chain (opts → runtime store → app config → env → `.env`) per spec §6.4. `get/1,2` returns `{:ok, key, source}` or `{:error, :missing}`; `fetch!/2` raises `%ALLM.Error.EngineError{reason: :missing_key}` with `:checked_sources` metadata. Empty-string values at every level are treated as missing.
- `ALLM.Keys.Store` — `Agent`-backed in-process key store (Non-obvious decision #1), caches the lazy `.env` load in the same Agent (Decision #10). `clear/0` resets both runtime keys and the dotenv cache.
- `ALLM.Keys.Dotenv` — built-in `.env` parser (Non-obvious decision #2) supporting `KEY=VALUE`, `# comment`, blank lines, `export KEY=VALUE`, and surrounding double-quote stripping. Single quotes are intentionally not stripped (documented limitation).
- `ALLM.Application` supervises `ALLM.Keys.Store`; `mix.exs` `application/0` now sets `mod: {ALLM.Application, []}` so the store starts with the `:allm` OTP app.
- `test/fixtures/sample.env` fixture plus unit + integration tests in `test/allm/keys_test.exs`, `test/allm/keys/store_test.exs`, `test/allm/keys/dotenv_test.exs`.

### Added
- `ALLM.Error.*` struct hierarchy (`EngineError`, `AdapterError`, `StreamError`, `ValidationError`, `ToolError`) — first-class serializable errors with `Exception` impls and default `:message` fallbacks. Per design sub-phase 1.1.
- `.new/1` constructors, `@spec`s, and `@doc` doctests on every Layer A struct (`ALLM.Message`, `ALLM.ToolCall`, `ALLM.Request`, `ALLM.Response`, `ALLM.StepResult`, `ALLM.ChatResult`, `ALLM.Usage`); `@doc` + doctest coverage expanded on the pre-existing `ALLM.Thread` and `ALLM.Tool` helpers; `@moduledoc` rewrite on `ALLM.Session` documenting the `metadata[:error]` convention and the caller-owned `context` contract. Per design sub-phase 1.2.
- Accessor functions `ALLM.Response.text/1`, `ALLM.ChatResult.halted?/1`, and `ALLM.Usage.total_tokens/1` with the documented fallback semantics. Per design sub-phase 1.2.
- `@enforce_keys` on `ALLM.Message` (`:role`, `:content`), `ALLM.ToolCall` (`:id`, `:name`, `:arguments`), and `ALLM.Tool` (`:name`, `:description`, `:schema`) so required-field omission raises `ArgumentError` at construction time. Per design sub-phase 1.2.
- `ALLM.Event.event?/1` guard function with payload-shape checks (map-typed payload required for every tag except the opaque `:raw_chunk` / `:error`), `ALLM.Event.tags/0` returning the closed 16-atom union, and 14 variant constructors (`text_delta/2`, `text_completed/2`, `tool_call_started/2`, `tool_call_delta/2`, `tool_call_completed/4`, `tool_execution_started/3`, `tool_execution_completed/3`, `tool_result_encoded/2`, `ask_user_requested/4`, `tool_halt/3`, `message_started/1`, `message_completed/1`, `step_completed/2`, `chat_completed/1`). Per design sub-phase 1.3.
- `ALLM.Validate` module with five validators (`request/1`, `message/1`, `tool/1`, `thread/1`, `session/1`). Returns structured `%ALLM.Error.ValidationError{}` with field-level error lists. Per sub-phase 1.4.
- `ALLM.Test.Generators` test-support module extracting Layer A struct generators (`role_gen/0`, `text_gen/0`, `tool_name_gen/0`, `message_gen/0`, `tool_gen/0`, `request_gen/0`) for reuse across property tests. Per retro 2026-04-19-phase1-1.4.
- `ALLM.Serializer` with `encode_tagged/2`, `to_json!/1`, `to_iodata!/1`, and `from_json/2` — tagged JSON encoding (`%{"__type__" => ..., "data" => ...}`) with `Jason` round-trip for every Layer A struct. `from_json/2` returns `{:error, %ValidationError{}}` with the closed field-error vocabulary (`:malformed`, `:missing_type_tag`, `:unknown_type_tag`, `:missing`, `:malformed_struct`, `:atom_decode_failed`) from sub-phase 1.5.
- `defimpl Jason.Encoder` and private `__from_tagged__/1` hydrators on every Layer A struct (`ALLM.Message`, `ALLM.Tool`, `ALLM.ToolCall`, `ALLM.Request`, `ALLM.Response`, `ALLM.Thread`, `ALLM.Session`, `ALLM.StepResult`, `ALLM.ChatResult`, `ALLM.Usage`) and every `ALLM.Error.*` struct. Atom-typed fields (`Message.role`, `Request.tool_choice`, `Request.response_format`, `Response.finish_reason`, `Session.status`, `ChatResult.halted_reason`, every error `:reason` and `:provider`) are restored via `String.to_existing_atom/1` per the tagged-encoding design (§1.5).
- `@doc` with runnable doctests on every public constructor in `ALLM` (`system/1`, `user/1`, `assistant/1`, `tool_result/2`, `tool/1`, `json_schema/3`, `request/2`) plus expanded `@moduledoc` with a Layer-A end-to-end worked example. Per sub-phase 1.6.

### Changed
- Removed `:llm_db` dependency from `mix.exs` (pinned to non-existent `~> 0.1`). Will be re-added in Phase 9 when capability pre-flight / cost population (spec §6.3) need it.
- `mix.exs` — added `:stream_data` (`~> 1.1`, test-only) for property-style tests on closed-union types (`ALLM.Event` variants).
- `ALLM.Serializer` now round-trips `response_format` map shapes (`%{type: :json_object}` and `%{type: :json_schema, name: _, schema: _, strict: _}`), preserving atom-keyed form on decode via a new `ALLM.Request.restore_response_format/1` helper. Escape-hatch maps with other string keys pass through unchanged (spec §5.4). Per sub-phase 1.5 review Finding 2.
- `ALLM.Validate.tool/1` now rejects tool names `"auto"`, `"none"`, `"required"` with `{:name, :reserved_tool_name}` to prevent collision with `tool_choice` atom restoration in the Serializer. Per sub-phase 1.5 review Finding 3; vocabulary table in sub-phase 1.4 updated accordingly.
- `ALLM.request/2` rewritten as a thin wrapper around `ALLM.Request.new/2` (semantically identical; internal cleanup so both facade and struct module have independent doctests). Per sub-phase 1.6.

### Fixed
- Normalized `lib/allm/event.ex` formatting (scaffolding commit had unformatted lines).
- `mix docs` warnings resolved — `README.md` and `ALLM.Validate` `@moduledoc` references restructured to avoid ExDoc cross-reference failures (forward-looking `ALLM.generate/3`, `ALLM.Session.reply/4` references phrased as plain text tagged with target phase; spec-path link converted to plain prose; `ALLM.Validate.*/1` glob replaced with an explicit enumeration of the five validators). Per sub-phase 1.6 review Finding 1.
