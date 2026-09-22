# Phase 23: Compact Tools — Records

Companion to `steering/2026-09-21_COMPACT_TOOLS_DESIGN.md`. Status, checklist state, deviations and closure notes live here; the design doc is not edited during implementation.

## Status

| Phase | Status | Notes |
|-------|--------|-------|
| 23.1 | Completed | Built 2026-09-22 on `1859dac`. Functional, code and arch/security reviews ran (`.work/*/2026-09-22-phase-23-1-tool-fields*`); fix pass: 0 fixed, 2 deferred to `[CARRY]`, 3 Lows left for polish. |
| 23.2 | Not Started | |
| 23.3 | Not Started | |
| 23.4 | Not Started | |
| 23.5 | Not Started | |

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
