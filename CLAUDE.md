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
- **Adapters MUST document any default they inject for a Layer-A `nil` field that the wire requires.** Anthropic requires `max_tokens`; ALLM Layer A allows `nil`; the adapter injects a default (currently `1024`). The default goes in the public `@doc` of `generate/2` AND the request-builder helper's `@doc false`. Cross-provider divergence on the same field (1024 vs 2048 vs other) is invisible to callers and surprises debugging.
- **Model strings are late-resolved.** Optional `llm_db` provides capability pre-flight and cost population; core must function without it (§6.3).
- **Two orchestration modes.** `:auto` (loop runs tools) and `:manual` (caller submits results). `{:ask_user, ...}` suspension works in both (§12.3).
- **HTTP transport split.** Non-streaming: `Req`. Streaming: `Finch` directly, HTTP/1 (not HTTP/2 — flow-control bug affecting large bodies, spec §7.2).
- **Telemetry is the extension point.** `middleware:` is reserved for later and must stay `[]` in v0.2 (§29). Cross-cutting concerns go through telemetry handlers or adapter wrappers.
- **Mid-stream adapter errors fold into the response, not the call-site tuple.** A mid-stream `{:error, struct}` event surfaces as `{:ok, %Response{finish_reason: :error, metadata: %{error: struct}}}` from `ALLM.generate/3` / `ALLM.step/3` — the call-site tuple stays `{:ok, _}`. Only synchronous pre-flight errors (missing adapter, invalid request, adapter pre-flight failure) surface as `{:error, struct}` at the call site. Callers matching only `{:error, _}` will silently swallow rate limits, content-filter blocks, and stream cancellations. Spec §10.1, PHASE_5 Decision #4.
- **OpenAI has TWO endpoint translators** in `lib/allm/providers/openai.ex` — Chat Completions (`to_openai_messages/1`) and Responses API (`to_responses_input/1`). Anthropic has ONE. Any change to message-content shape, tool-call shape, or system-message handling MUST verify against BOTH OpenAI translators; spec Decisions touching content shape MUST cite both file:lines. Worked example: PHASE_14 Decision #14 cited both translators and shipped zero drift; Phase 10.6's reasoning-control Chat-Completions-only fix needed a Phase 11.x retrofit. PHASE_17 Decision #14 reused the recipe for the Chat-Completions vs Responses content-block divergence (`detail` nested in `image_url` map vs sibling key) — single shared helper `to_openai_content_blocks/2` called from both translators, eight wire fixtures (4 source-shapes × 2 endpoints), zero half-mirror drift. The cross-PROVIDER analogue: when a feature wires in two adapters (e.g., vision input across OpenAI 17.1 + Anthropic 17.2), helper names should align byte-for-byte modulo arity differences driven by per-provider invariants (OpenAI/2 = endpoint atom; Anthropic/1 = single endpoint). 17.1 + 17.2 ship six helper pairs with byte-identical names (`to_<provider>_content_blocks/N`, `part_to_block/N`, `user_content/N`, `reject_image_in_system_messages/1`, `materialize_part(%ImagePart{}) → ""`, `system_has_image_part?/1`); reader pattern-recognition flips immediately between the two files.
- **Capability pre-flight runs in `ALLM.StreamRunner` and `ALLM.*` facade helpers, NOT inside adapter `generate/2` / `stream/2`.** Adapter pre-flight handles wire-shape validation only (system-role rejections, MIME, byte size). Direct adapter calls (`ALLM.Providers.OpenAI.generate(req, opts)`) bypass the capability gate by design — callers wanting capability enforcement go through `ALLM.generate/3`. Spec Decisions describing pre-flight ordering MUST cite the file:line where each step actually lives. Worked example: PHASE_17 Decision #7 specified a five-step adapter ladder `(system → capability → MIME → translate → HTTP)` but capability lives at `lib/allm/stream_runner.ex:122`, not the adapter; 17.1 implementer shipped the in-adapter subset and 17.2 added a runner-level capability test (`test/allm/providers/anthropic_vision_test.exs:618-639`) after the steering doc was amended.

Build order (spec §28): data structs → `Engine` → behaviours → `Event` → stream runner + `ALLM.Providers.Fake` → collectors/reducers → streaming APIs → non-streaming wrappers → session helpers → real provider adapters.

## Where things live

- `steering/allm_engine_session_streaming_spec_v0_2.md` — authoritative spec. Cite section numbers in commits and comments (`# see §12.3 ask-user`).
- `steering/examples/` — target application shapes.
- `lib/allm.ex` — top-level facade (§4).
- `lib/allm/` — module tree mirroring spec §27.
- `lib/allm/providers/fake.ex` — deterministic scripted adapter; primary test vehicle (§31).
- **Wire fixtures are stored as `.json`, not `.exs`.** Recorded provider response bodies live under `test/fixtures/<provider>/<endpoint>/<scenario>.json`; synthesized error/edge bodies live under `test/fixtures/<provider>/synthesized/<scenario>.json`. Loaders (`OpenAITestFixtures`, `AnthropicTestFixtures`) read JSON via `Jason.decode!/1`. Design Module Trees specifying `.exs` wire fixtures should be corrected at design time, not by the implementer. Worked example: PHASE_17 §3.5 listed nine `.exs` fixture paths; PHASE_17.1 shipped all nine as `.json` per the Phase 14/15 convention.
- **`mix.exs` `package[:files]` MUST be a superset of `docs[:extras]`.** ExDoc renders `extras:` files into hexdocs at publish time, but the Hex source tarball is gated on `:files` only — a file in `extras:` but not in `:files` ships to hexdocs but NOT to the source download. Verify with `tar -tzf <package>.tar` at release time, not just `mix hex.build` exit-code. Worked example: PHASE_17.3 left `CHANGELOG.md` in `mix.exs:77` `docs.extras` but absent from `mix.exs:69` `package.files`; the v0.3.0 source tarball shipped without CHANGELOG (fixed in v0.3.x patch).

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
- **Every bundled provider adapter ships with an examples entry** in `examples/` (provider-neutral helper + numbered scripts + `run_all.exs` orchestrator) and the `/review` step BLOCKS on `ALLM_PROVIDER=<name> mix run examples/run_all.exs` exit 0. Cost ~$0.05–0.10/provider/run. Catches request-shape, per-model-rejection, and endpoint-override bugs that wire-stub fixtures cannot. Worked example: Phase 10.5's first live-validation surfaced three real `lib/` bugs the 1252-test matrix missed; Phase 11.4 confirmed the pattern works for two providers in parallel.
- **Cross-phase bug discipline.** When a sub-phase uncovers bugs in prior-phase code, document the bugs in the retro and (if a workaround is feasible within scope) record the workaround inline. Do NOT fix the bugs in the current phase unless the design explicitly scopes the fix in. Cross-phase fixes break the per-phase gate's atomicity. Worked example: PHASE_10.5 found three `lib/` bugs from Phases 10.2/10.6 during live validation; implementer correctly worked around in scripts and the README, did NOT modify `lib/` (out of scope), surfaced the bugs in the retro for future-phase pickup.
- **`Logger.debug/1` in adapter / hot-path code MUST use the deferred form** `Logger.debug(fn -> "msg #{inspect(...)}" end)` to skip string interpolation when the level is below `:debug`. Mixed forms across `lib/` today; standardize for new adapter code. Worked example: `lib/allm/providers/openai.ex:373`'s strip-reasoning-control debug log.
- **SSE chunk mappers: one private function per event-type from the start.** Author the dispatch as `defp handle_event("message_start", state, payload)` clauses, not one big `case`. Credo's default `Refactor.CyclomaticComplexity` (threshold 9) and `Refactor.Nesting` (threshold 2) make a single-`case` mapper a forced mid-stream refactor — see Phase 11.2's `chunk_to_events/2` rework.
- **Decision text drift is a known failure mode; amend the steering doc as part of the implementation commit, not as a follow-up.** When implementing a phase, if a Decision's prose contradicts what the code requires, fix the prose in the same commit and cite the divergence in the message body. Don't ship the divergence and queue a doc-only fix-up commit. Worked example: PHASE_14_image_layer_2_5.md Decisions #3, line 294, #9 each shipped with prose-vs-code drift across 14.1/14.2/14.3 — three follow-up commits. Decision #14 was authored with five file:line cites and shipped zero drift.
- **Test-fixture seams discovered in retro N should land in retro-N's fix step, not deferred to N+1.** `:capture_pid` on `FakeImages` was identified in 14.2 retro Finding 3, landed in 14.2 fix step (commit a42d280), then served three new 14.3 test files with zero re-invention. Cross-phase amortization: catch it once, fix it once. Compare with the `:erlang.phash2(script)` cursor footgun (overdue across five retros) — deferred lifts replay verbatim.
- **Phases shipping synthesized wire fixtures MUST commit a recorder script** (`scripts/record_<provider>_<feature>_fixtures.exs`, idempotent per run) AND each synthesized fixture file MUST carry a leading `_comment: "Synthesized…"` marker naming the originating phase. Tests strip the marker via a `drop_comment/1` helper; recorder scripts MUST refuse to overwrite files lacking the marker (i.e., already recorded). Live re-record is a BLOCKING `/review` gate when the implementer's environment lacks the provider key; the phase Verification block MUST list the recorder-script invocation as a discrete step alongside the live-test invocation. CHANGELOG entries claiming live-gate outcomes MUST flag deferral honestly — never paraphrase the future post-record state at commit time. Worked examples: `test/fixtures/openai/images/recorded/` (Phase 15.2 origin), Phase 11.4 / 15.6 / 17.1 / 17.2 / 17.3 — five consecutive deferrals before this rule landed.
- **Snapshot files (e.g., `examples/RUN_OUTPUT_*.md`) MUST be regenerated in the same commit as the live run that produced them, OR not modified at all.** Hand-edited or stale snapshots are worse than missing snapshots — they encode wall-clock timestamps and model output that can't be reproduced from the codebase state at re-run time. When the live BLOCKING gate defers because the implementer's environment lacks the key, snapshot regen also defers. Module Tree rows enumerating snapshot files SHOULD pair them with a "deferred-when-keys-absent" caveat. Worked example: PHASE_17.3 listed `RUN_OUTPUT_*.md` as in-scope; live gate deferred (no keys); implementer correctly skipped snapshot regen.
- **Audit greps for short tokens MUST use `-w` (word-boundary) AND/OR exclude binary-content fixture directories.** A 3-letter substring like `ocr` matches base64-encoded image bytes by chance; design specs proposing `# expected: empty` against a repo with recorded-image fixtures are structurally false unless tightened. Design Verification commands SHOULD be runnable as-written with output matching the repo's actual state. Worked example: PHASE_17 §17.3.3 line 715 proposed `grep -rE '…|ocr|…' lib/ test/ examples/  # expected: empty`; the actual audit hits three recorded-image fixtures (`test/fixtures/openai/images/recorded/*.json`) as base64 noise.
- **`async: true` + `Logger.configure/1` is a foot-gun.** `Logger.configure(level: :debug)` is application-global, not Task-local. Inside a `Task.async/await` wrapper that's there for process-dict isolation, `Logger.configure/1` STILL races with concurrent `async: true` tests — it mutates global Logger state and doesn't restore on Task exit. Use `capture_log([level: :debug], fn -> ... end)` for log-level control (per-process, restored on function exit); reserve `Task.async` for process-dict isolation only. Worked example: PHASE_17.2's detail-drop test at `test/allm/providers/anthropic_vision_test.exs:325, :349` wraps in `Task.async` (correct for the `:allm_anthropic_detail_warned` process-dict latch) but ALSO calls `Logger.configure(level: :debug)` inside the Task — leaks `:debug` globally after the Task exits.
- **Public-test-seam helpers carry `@doc false` + `@spec`.** The combination exposes a function for tests + Dialyzer without surfacing in ExDoc. Reach for this pattern when a helper has nontrivial branching (model-conditional encoding, enum-mapping tables, body-shape dispatch) worth exercising directly without driving the full adapter HTTP round-trip. Worked example: `lib/allm/providers/openai/images.ex` exposes nine such seams across Phase 15.1–15.4 (`endpoint_for/1`, `gate_model_op/2`, `to_size_string/1`, `to_json_body/2`, `to_multipart_body/2`, `resolve_image_bytes/2`, `to_image_adapter_error/4`, `decode_response/4`, `mime_type_for_output_format/1`).
