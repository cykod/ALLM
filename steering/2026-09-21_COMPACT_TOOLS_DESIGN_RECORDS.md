# Phase 23: Compact Tools — Records

Companion to `steering/2026-09-21_COMPACT_TOOLS_DESIGN.md`. Status, checklist state, deviations and closure notes live here; the design doc is not edited during implementation.

## Status

| Phase | Status | Notes |
|-------|--------|-------|
| 23.1 | Completed | Built 2026-09-22 on `1859dac`. Functional, code and arch/security reviews ran (`.work/*/2026-09-22-phase-23-1-tool-fields*`); fix pass: 0 fixed, 2 deferred to `[CARRY]`, 3 Lows left for polish. |
| 23.2 | Completed | Built 2026-09-22 on `9b74416`. Functional, code and arch/security reviews ran (`.work/*/2026-09-22-phase-23-2-tool-help*`; design review N/A); fix pass: 0 fixed (all findings Low), 2 deferred to `[CARRY]` (below), 4 Lows left for polish. |
| 23.3 | Completed | Built 2026-09-22 on `f7a4b87`. Implementer gates green (below); review gates not yet run. |
| 23.4 | Not Started | |
| 23.5 | Not Started | |

## 23.3 — Chat-loop wiring (Layer C)

### Checklist

- [x] `effective_tools/2` added to `lib/allm/chat.ex` (`:2001`) and the six execution sites routed through it: non-streaming `run_auto_tool_calls_step/5`, `run_tools_then_halt/7`, `run_tools_non_streaming/5`; streaming `dispatch_partitioned_stream/3`, `start_phase_b/3`, `start_phase_b_partial/5`. `build_request/4` (shared by both paths) sends `ToolHelp.project(Engine.resolve_tools(engine, opts), Keyword.get(opts, :tool_choice))` (`:2020`). Post-condition `git --no-optional-locks grep -n 'Engine.resolve_tools(' lib/allm/chat.ex | wc -l` → `2` (the `effective_tools/2` body and `build_request/4`).
- [x] `ToolRunner.execute_one_tool/3` interception (`lib/allm/tool_runner.ex:537`): the meta-tool is answered with `ToolHelp.render(ctx.tools, args)` without reaching `ctx.executor`; otherwise the private `execute_checked/4` (`:548`) returns `ToolHelp.check_args/2`'s `{:error, usage}` or runs the executor. Both results go through the unchanged `dispatch_handler_return/3`.
- [x] Contract-flip audit (below): all keep.
- [x] `guides/tools.md` not touched.

### Test Plan coverage

All 16 rows are in `test/allm/chat/compact_tools_test.exs`, and every row loops over both arms (`ALLM.chat/3` and `ALLM.stream/3` folded through `StreamCollector`) inside one test, labelling assertion failures with the arm. Row 11 is Layer D, so it has one test per arm (`Session.start`/`continue` and `Session.stream_start`/`stream_step` folded with `StreamReducer`, re-passing `mode: :manual` each time). Additions beyond the matrix: a pure Invariant-1 name check (row 2, `:190`), the no-compact-tool `tool_help` user tool staying ordinary (row 8, `:339`), the `{:continue, replacement}` half of row 12 (`:538`), and row 10b (`:411`, added by the fix pass below).

`test/allm/tool_runner_test.exs` `describe "compact tools — direct run_tool_calls/3 / stream_tool_calls/3 callers"` (`:1868`) holds 10 unit rows. `test/allm/chat_equivalence_test.exs` gains fixture `:compact_tool_help_round_trip` (the row-3 script) in `@fixture_ids`, plus an absolute-shape test (`:451`) per IMPLEMENTATION.md §4m. The property holds with **no new relaxation row**; the moduledoc fixture list names it.

Binding checks: 6 of the 10 `tool_runner_test.exs` rows failed before `tool_runner.ex` changed, each for the expected reason (executor reached, `:not_found` from the default executor, un-decodable content); the other 4 pin behaviour that must stay unchanged (`:1922`, `:1941`, `:1989`, `:1998`). 11 of the 20 `compact_tools_test.exs` tests failed before `chat.ex` changed. Reverting only `effective_tools/2` to a bare `Engine.resolve_tools/2` turns 9 tests red across `compact_tools_test.exs` and `chat_equivalence_test.exs`.

### `[CARRY]` from 23.2: the four `ALLM.ToolHelp` moduledoc claims, now pinned

| Claim (`lib/allm/tool_help.ex`) | Pinning test(s) |
|---|---|
| Usage error replaces the handler (`:46-47`, `check_args/2` `@doc` `:277-279`) | `test/allm/chat/compact_tools_test.exs:228` (row 4), `test/allm/tool_runner_test.exs:1954`, `:1965` |
| Usage error routed through `on_tool_error` (`:277-279`) | `compact_tools_test.exs:252` (row 5, `:halt`), `:516` and `:538` (row 12, fun/2), `tool_runner_test.exs:1979` |
| `{:tools, :duplicate_name}` for a user tool named `tool_help` beside a compact tool (`:74-76`) | `compact_tools_test.exs:322` (row 8, both arms) |
| Direct `ToolRunner.run_tool_calls/3` / `stream_tool_calls/3` callers get `check_args` and `tool_help` answered only when their list holds `meta_tool/0` (`:92-95`) | `tool_runner_test.exs:1897`, `:1908` (answered), `:1922` (list without `meta_tool/0` → `:unknown_tool`), `:1954`, `:1965` (check_args on both entry points) |

The `[CARRY]` line in §"`[CARRY]` lines filed by the 23.2 fix pass" is discharged by this table.

### Security carry from 23.2: `render/2` sees exactly the resolved list

Verified. `render/2` reads `ctx.tools` (`tool_runner.ex:537`), which is the `tools` argument of `run_tool_calls/3` / `stream_tool_calls/3`. In the chat loop every such call passes the `tools` bound by `effective_tools(engine, opts)` at the six sites above. `effective_tools/2` is `with_meta_tool(Engine.resolve_tools(engine, opts))`, and the wire list is `project(Engine.resolve_tools(engine, opts), tool_choice)`: the same resolved list with the same `engine` and `opts` on the same step. `project/2` keeps every name and appends the meta-tool under exactly the condition `with_meta_tool/1` does, so the two lists name the same tools (Invariant 1). `compact_tools_test.exs:176` pins the wire side through the chat loop; `:190` pins only the helper-level name equality (`project/2` vs `with_meta_tool/1`) and cannot fail if a `chat.ex` site regresses. The execution side is bound through the chat loop at five of the six sites (see §"Fix pass" below); `:1389` is defensive and not observable for `tool_help`. No other tool source reaches `ctx.tools`: `grep -n 'run_tool_calls(\|stream_tool_calls(' lib/allm/chat.ex` shows only calls taking that local `tools`, and `ALLM.Session` stores no tools. Residual: structured_finalize pass 2 re-resolves call-level `:tools` (the pre-existing `[BUG]` below), but on pass 2 the wire and execution lists are still derived from the same resolved list, so `tool_help` still cannot describe a tool the model was not sent.

### Contract-flip audit (Invariant 3)

`git --no-optional-locks grep -n 'request.tools\|resolve_tools' test/` (run 2026-09-22, 15 hits). No assertion inverts, because no existing test uses a compact tool.

- `test/allm/engine_integration_test.exs:7` — keep (moduledoc prose naming `resolve_tools/2`).
- `test/allm/engine_integration_test.exs:105`, `:120`, `:182` — keep (`Engine.resolve_tools/2` public contract, unchanged).
- `test/allm/engine_property_test.exs:153`, `:166` — keep (`resolve_tools/2` dedup property, unchanged).
- `test/allm/engine_test.exs:181`, `:184`, `:189`, `:194`, `:204`, `:213`, `:224`, `:230` — keep (`resolve_tools/2` unit tests and describe header, unchanged; the meta-tool is injected only inside `ALLM.Chat`).
- `test/allm/providers/openai_test.exs:298` — keep (adapter encodes a caller-built `request.tools`; no chat loop).

### Implementation notes

- `[tactical]` **The usage-error branch lives in a private `execute_checked/4`** rather than a three-arm `cond` in `execute_one_tool/3`, so each function makes one decision.
- **Row 12's fun receives `(tool_call, reason)`**, the existing `on_tool_error` arity-2 order (`invoke_on_tool_error/5`), not `(reason, …)`.
- **Row 11 streaming uses `StreamReducer.new(session, mode: :step)` for the `stream_step` fold**, since `finalize/1` dispatches on the reducer mode; the `stream_start` fold uses the default `:chat`.
- **Filed** the `/asks` `[BUG]` the design's Out-of-scope section requires: call-level `:tools` leak into structured_finalize pass 2 (`run_finalize_pass/4`, `lib/allm/chat.ex:488` non-streaming, `:750` streaming). Reproduced 2026-09-22: the ticket's `mix run -e` one-liner prints `[1, 1]` (tools on pass 1, pass 2). **DONE WHEN** it prints `[1, 0]`. Not fixed here; outside the Module Tree.
- `HANDOFF.md`: the one Open item addressed to 23.3 (pin the four `ALLM.ToolHelp` claims) is discharged by the table above.
- No deviations from the contract block.

### Gate results (implementer run, 2026-09-22)

| Command | Exit |
|---|---|
| `mix test test/allm/chat/compact_tools_test.exs test/allm/chat_equivalence_test.exs test/allm/tool_runner_test.exs` (2 doctests, 1 property, 119 tests, 0 failures) | 0 |
| `mix test` (443 doctests, 32 properties, 3563 tests, 0 failures, 14 excluded; baseline 443 / 32 / 3532) | 0 |
| `mix test --seed 0` (same counts) | 0 |
| `mix format --check-formatted` | 0 |
| `mix credo --strict` | 0 |
| `mix compile --warnings-as-errors --force` | 0 |
| `mix dialyzer` | 0 |
| `git --no-optional-locks grep -n 'Engine.resolve_tools(' lib/allm/chat.ex \| wc -l` → `2` | 0 |
| `grep -rl 'Keys.put(\|Logger.configure(\|System.put_env(\|:telemetry.attach' test/allm/chat/compact_tools_test.exs` → empty | 1 (no match) |

### Fix pass (2026-09-22, delegated)

Inputs: `.work/reviews/2026-09-22-phase-23-3-chat-wiring/overview.md`, `.work/code-reviews/2026-09-22-phase-23-3-chat-wiring.md`, `.work/security-reviews/2026-09-22-phase-23-3-chat-wiring.md` (clean), design review N/A.

- **Fixed (functional Known Issue 1, Medium): row 10b** (`test/allm/chat/compact_tools_test.exs:411`, both arms). One assistant turn calls `tool_help`, auto compact `y` with a missing argument, and per-tool-manual compact `x`; asserts `:manual_tool_calls` on `x` only, `tool_help`'s rendered content, and `y`'s usage error. Mutation check on a scratchpad copy, one site at a time reverted to `Engine.resolve_tools(engine, opts)`, `mix test test/allm/chat/compact_tools_test.exs`: `lib/allm/chat.ex:1178` (`run_tools_then_halt/7`, non-streaming) → 1 failure, row 10b, `{:error, %EngineError{reason: :unknown_tool}}` on the `:chat` arm; `:1472` (`start_phase_b_partial/5`, streaming) → 1 failure, row 10b, `"arm stream: tool_help result missing"`; `:1389` (`dispatch_partitioned_stream/3`, streaming) → 0 failures, as the functional review predicted (an unknown name partitions as auto, so the site is defensive for `tool_help`). Invariant 1 is now bound through the chat loop at 5 of 6 sites (`:1088`, `:1178`, `:1223`, `:1417`, `:1472`).
- **Fixed (functional Known Issue 2 / code review F1, both Low): row 11's self-comparison.** Adjudication: both lanes were seeded with the "value compared with itself" shape, so double-reporting is not an independence signal. Taken under the gate carve-out: the replaced line (`answer/2 == render/2` of the same list) could not fail, and the row's own claim (the submitted answer reaches the model) was unasserted. Replaced with `tc.arguments == %{"names" => ["x"]}` plus an absolute content anchor, and added `Enum.any?(r2.messages, &(&1.role == :tool and &1.content == content))` to both arms (`:451`, `:477`). Mutation check: `lib/allm/session.ex` `do_submit_tool_result/3` storing `encode_tool_content("")` instead of the submitted content → both row-11 tests fail.
- **Left for the phase-end polish pass (Low):** code review F2, F3, F4, F5 (test move / oracle helper), F6 (`ToolRunner` moduledoc sentence). F5's RECORDS half (the `:190` pin claim) was corrected above as a governed-document sentence.
- Gates after the pass: `mix test` (443 doctests, 32 properties, 3564 tests, 0 failures) 0; `mix test --seed 0` 0; `mix format --check-formatted` 0; `mix credo --strict` 0; `mix compile --warnings-as-errors --force` 0; `mix dialyzer` 0; `git --no-optional-locks grep -n 'Engine.resolve_tools(' lib/allm/chat.ex | wc -l` → `2`.

## 23.2 — `ALLM.ToolHelp` (pure helper)

### Checklist

- [x] `lib/allm/tool_help.ex` per the contract block. Its `@moduledoc` covers, in prose, stubs staying callable, the stable wire list, forcing a compact tool (including the Gemini multi-name `allowedFunctionNames` caveat), the metadata marker and the duplicate-name consequence, manual mode, caller-executed `check_args/2`, and the direct-`ToolRunner` note. The seven documented functions have `@doc` + `@spec` + doctest; the four seams have `@doc false` + `@spec`. `mix run scripts/audit_user_docs.exs lib/allm/tool_help.ex` gives `No banned-token matches.` (exit 0).
- [x] `mix.exs` `groups_for_modules`: `ALLM.ToolHelp` added to `Runtime:`.
- [x] `examples/fixtures/compact_tools.exs` (`CompactToolsFixture.tools/0`, 8 plain maps, 3–7 params each, every `array` property carries `items`) is loaded once from `test/test_helper.exs`. `create_issue`'s stub description equals the Layer demonstration string exactly (pinned by test `stub/1` "the fixture's create_issue stub description is exact").

### Implementation notes

- `[tactical]` **`signature/1` with no required names renders `"Args: [a, b]"`, not `"Args:  [a, b]"`.** The contract's literal concatenation (`"Args: " <> required <> optional`, with optional wrapped as `" [" <> … <> "]"`) produces a double space when `required` is empty. The parts are joined with a single space instead. Pinned by test `signature/1` "no required names".
- `[tactical]` **`render/2` returns the usage string for `%{"names" => []}` and for a list containing a non-binary.** The contract accepts `[binary]`; an empty list would otherwise render `""` to the model. Pinned by test `render/2` "malformed args yield the usage string".
- `[tactical]` **Non-binary entries in a schema's `"required"` list are ignored** by both `signature/1` and `check_args/2`. This keeps `check_args/2`'s never-raise contract, since `String.to_existing_atom/1` and `Enum.join/2` need binaries. Pinned by test `robustness` "check_args/2 never raises…".
- **`compact?/1` is `tool.compact == true` exactly** (carried from the 23.1 review). Pinned by the `compact?/1` tests, including a JSON-hydrated `"compact": "yes"` tool that `project/2` returns unchanged. Verified binding by mutation: `compact not in [false, nil]` turns 4 tests red.
- **The JSON round-trip test for the meta-tool hydrates a list** with `Jason.decode!/1 |> ALLM.Serializer.hydrate/1`, because `Serializer.from_json/2` dispatches a single value.
- **The Test Plan's StreamData property lives in `tool_help_test.exs`**, as the Module Tree lists, not in a separate `_property_test.exs`. It maps `Generators.tool_gen/0` with `StreamData.boolean()` onto `:compact`.
- **The moduledoc describes chat-loop behaviour that 23.3 wires in** (projection in `build_request/4`, `tool_help` interception, and the usage-error routing). Until 23.3 lands, the module is callable but the chat loop does not use it.
- `HANDOFF.md`: no Open item addresses 23.2. The two 23.1 items target 23.4/23.5 and are left Open.

### Gate results (implementer run, 2026-09-22)

| Command | Exit |
|---|---|
| `mix test test/allm/tool_help_test.exs test/groups_for_modules_audit_test.exs` (8 doctests, 1 property, 61 tests, 0 failures) | 0 |
| `mix test` (443 doctests, 32 properties, 3532 tests, 0 failures, 14 excluded; baseline 435 / 31 / 3472) | 0 |
| `mix test --seed 0` | 0 |
| `mix format --check-formatted` | 0 |
| `mix credo --strict` | 0 |
| `mix compile --warnings-as-errors --force` | 0 |
| `mix dialyzer` | 0 |
| `mix run scripts/audit_user_docs.exs lib/allm/tool_help.ex` | 0 |
| `mix test --cover` → `ALLM.ToolHelp` 97.26% | 0 |

### `[CARRY]` lines filed by the 23.2 fix pass

Both are Low. The 23.2 fix pass filed them here so that 23.3's implementer and 23.5's enumeration predicate find them.

- `[CARRY]` (from 23.2 code review F4, receiver: 23.3) `ALLM.ToolHelp`'s docs state chat-loop and tool-runner behaviour that 23.3 wires in: the usage error replaces the handler and is routed through `on_tool_error` (`lib/allm/tool_help.ex:46-47`, `:277-279`), a user tool named `tool_help` beside a compact tool is rejected with `{:tools, :duplicate_name}` (`:74-76`), and `ALLM.ToolRunner.run_tool_calls/3` / `stream_tool_calls/3` check compact args and answer `tool_help` (`:92-95`). 23.3 pins each of the four claims with a test and records each test's `file:line` in its own RECORDS section. The direct-`ToolRunner` claim is the one a chat-loop-shaped Test Plan misses.
- `[CARRY]` (from 23.2 code review F3, receiver: a `[CHORE]` outside Phase 23) `tool_help.ex`'s private `stringify_keys/1` (`:409-414`) repeats shallow atom-to-string key normalisation that also sits privately in `lib/allm/providers/openai.ex:1690-1695`, `lib/allm/providers/anthropic.ex:635-640` and `lib/allm/providers/openai/moderation.ex:930-935`. That is four copies, not the review's five: `gemini.ex:1049-1054`'s `option_key/1` also renames keys and is not a copy (`grep -rn 'Atom.to_string(k)' lib/` → 6 lines, read 2026-09-22). Extracting one shared `@doc false` helper touches released adapter code, so it is a separate commit. **DONE WHEN** `grep -lE 'defp (stringify_keys|stringify_option_keys|to_string_key)\b' lib/allm/tool_help.ex lib/allm/providers/openai.ex lib/allm/providers/anthropic.ex lib/allm/providers/openai/moderation.ex` prints nothing (measured 2026-09-22: all four files). `lib/allm/json_schema.ex`'s `to_string_key/1` also stringifies non-atom keys with `inspect/1`, so it is not a copy and is left out of the predicate.

## 23.1 — `ALLM.Tool` fields + validation (Layer A)

### Checklist

- [x] Fields, `@type`, `:compact` guard and `__from_tagged__/1` lines per the contract block (`lib/allm/tool.ex`).
- [x] `validate_tool_summary/2` added to `tool/1`'s pipeline after `validate_tool_schema/2`, and defined beside it (`lib/allm/validate.ex`).
- [x] `@moduledoc` "Compact tools" section pointing to `ALLM.ToolHelp`; `mix run scripts/audit_user_docs.exs lib/allm/tool.ex` gives 0 hits.

### Implementation notes

- **Forward reference to `ALLM.ToolHelp` (a 23.2 module).** It is written as plain backticked `ALLM.ToolHelp`. `mix docs` (run 2026-09-22) printed no warning, and ExDoc rendered it as unlinked code. Once 23.2 lands the module, it becomes a link automatically. No edit is needed.
- **Additive doc edits beyond the checklist**, all inside the Module Tree files:
  - The `Tool.new/1` `@doc` now describes the `:compact` guard and the unguarded `:summary`, and adds one doctest (`compact: true`, `summary: nil`), per IMPLEMENTATION.md §4 step 7.
  - The `Validate.tool/1` `@doc` gains one sentence naming the `{:summary, :not_a_string}` rule.
- **Legacy-JSON test.** Test Plan row 5 ("pre-23.1 encoded tool") builds its payload by encoding a current tool, then dropping `compact`/`summary` from the tagged envelope's `"data"` map (`Map.update!("data", …)`). A regex refutation confirms that neither key survives in the encoded string.
- **Validator test shape.** The `tool/1` test matches the exact list `errors: [{:summary, :not_a_string}]`, as the Test Plan asks. The `request/1` prefix test uses `in errors`, following the neighbouring `:name` prefix test.
- No deviations from the design's contract block.

### Gate results (implementer run, 2026-09-22)

| Command | Exit |
|---|---|
| `mix test test/allm/tool_test.exs test/allm/validate_test.exs test/layer_a_docs_test.exs` (19 doctests, 1 property, 120 tests, 0 failures) | 0 |
| `mix test` (435 doctests, 31 properties, 3472 tests, 0 failures, 14 excluded; baseline 434 / 3459) | 0 |
| `mix test --seed 0` | 0 |
| `mix format --check-formatted` | 0 |
| `mix credo --strict` | 0 |
| `mix compile --warnings-as-errors --force` | 0 |
| `mix dialyzer` | 0 |

### `[CARRY]` lines filed by 23.1 (receiver: 23.5 sweep)

Both are Low and sit outside 23.1's Module Tree. The 23.1 fix pass filed them here so that 23.5's enumeration predicate finds them (`grep -n "Phase 23\|23\.[1-4]" … _RECORDS.md`).

- `[CARRY]` (from 23.1 code review F3) `ALLM.tool/1`'s `@doc` in `lib/allm.ex` names `manual: true` but not `compact:` / `summary:`, which the facade forwards to `Tool.new/1`. Add one sentence pointing to `ALLM.Tool` / `ALLM.ToolHelp` once 23.2 exists to link to. It is 23.4's docs pass if that Module Tree is widened, else 23.5. **DONE WHEN** `grep -c compact lib/allm.ex` is ≥1 (measured 2026-09-22: `0`).
- `[CARRY]` (from 23.1 functional review O2) This one predates 23.1. A banned `phase_n` token sits in `ALLM.Validate`'s `@moduledoc` at `lib/allm/validate.ex:19` ("Phase 21.1 carries the structured detail…"). It is identical at base `1859dac` (`git show 1859dac:lib/allm/validate.ex | sed -n 19p`). **DONE WHEN** `mix run scripts/audit_user_docs.exs lib/allm/validate.ex` prints `No banned-token matches.` (measured 2026-09-22: 1 hit).
