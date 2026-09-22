# Phase 23: Compact Tools — Records

Companion to `steering/2026-09-21_COMPACT_TOOLS_DESIGN.md`. Status, checklist state, deviations and closure notes live here; the design doc is not edited during implementation.

## Status

| Phase | Status | Notes |
|-------|--------|-------|
| 23.1 | Completed | Built 2026-09-22 on `1859dac`. Functional, code and arch/security reviews ran (`.work/*/2026-09-22-phase-23-1-tool-fields*`); fix pass: 0 fixed, 2 deferred to `[CARRY]`, 3 Lows left for polish. |
| 23.2 | Completed | Built 2026-09-22 on `9b74416`. Functional, code and arch/security reviews ran (`.work/*/2026-09-22-phase-23-2-tool-help*`; design review N/A); fix pass: 0 fixed (all findings Low), 2 deferred to `[CARRY]` (below), 4 Lows left for polish. |
| 23.3 | Not Started | |
| 23.4 | Not Started | |
| 23.5 | Not Started | |

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
