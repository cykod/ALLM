# Skill Notes

Proposed changes to the pipeline skills in `~/.claude/skills/`. This project cannot apply them itself. Each entry stays here until the user copies it across (or rejects it), then moves to `## Discharged`.

## Pending

### 1. `/build`: gate the status-agreement check before each batch commit
*Raised 2026-09-22, Phase 23 `/auto-build` run (`.work/retro/2026-09-22-phase-23-compact-tools_applied.md` F1).*
**Target:** `~/.claude/skills/build/SKILL.md`, Step 5d "Precondition — verify the review artifacts exist", and the implement brief's status bullet.
**Evidence:** the design doc and `_RECORDS.md` status tables disagreed in 3 of 5 commits (`9b74416`, `f7a4b87`, `fa1d3c6`). Two RECORDS Notes cells said "review gates not yet run" on rows marked Completed. Each pre-commit check was an ad-hoc `sed`/`grep` joined with `;`, so a mismatch printed nothing and did not block the commit.
**Proposed wording:** "Before `git add`, run one *gating* status-agreement check joined with `&&`: every completed row reads `Completed` in both `_RECORDS.md` and any embedded design Status table, and no completed row's Notes cell contains `gates pending` or `not yet run`. For a pre-convention doc with an embedded table, the implement brief passes `/implement`'s lockstep rule verbatim and never says 'do not change the Status table'."
**Argument against:** it adds a step to every batch for a pre-convention layout that new designs don't use. The 23.1 and 23.2 failures came from skipping an exception the skill already states (`build/SKILL.md:87`).

### 2. `/build`: pass known shapes to the implementer, not only the reviewers
*Raised 2026-09-22, same run (retro F2).*
**Target:** `~/.claude/skills/build/SKILL.md`, the implement brief in Step 5a.
**Evidence:** three shapes named by the 23.1 and 23.2 reviews came back in 23.3: tests under an unrelated comment, prose describing change over time, and an assertion comparing a value with itself. The review briefs carried the known-shapes list. The implement briefs carried none of it.
**Proposed wording:** "Pass the previous batches' fix-pass patterns to the implement agent too, labelled 'known shapes — avoid; no conclusion about this diff', the same list the review briefs carry."
**Argument against:** a longer brief, and an implementer primed on shapes may over-fit to them. Reviewers remain the backstop either way.

### 3. `/build`: the fix brief quotes the carve-outs and leaves classification to `/fix`
*Raised 2026-09-22, same run (retro F4).*
**Target:** `~/.claude/skills/build/SKILL.md` Step 5c, the severity-floor reminder in the fix brief.
**Evidence:** the 23.4 brief widened "governed document" to cover the guide and the CHANGELOG, beyond `/fix`'s own definition. The 23.5 brief ruled a Low to be gate logic before `/fix` saw it. The 23.2 and 23.3 fix agents drew the "test that can't fail" line in different places for the same shape.
**Proposed wording:** "Quote the two carve-outs verbatim and leave classification to `/fix`. The brief may name a Low the orchestrator suspects qualifies, phrased as a question, never as a ruling or a prescribed remedy direction."
**Argument against:** the orchestrator's pre-read made those fix passes fast, and every in-batch Low they fixed was real.

### 4. `_shared/handoff.md` + `/retro`: a re-filed row is not a discharged row
*Raised 2026-09-24, Phase 25 `/auto-build` run (`.work/retro/2026-09-24-2026-09-24_SST_SUPPORT_applied.md`, "Pipeline note").*
**Target:** `~/.claude/skills/_shared/handoff.md` (discharge rule) and `~/.claude/skills/retro/SKILL.md` (phase-scope rule that counts carried-and-discharged items as successes).
**Evidence:** the 25.7 sweep moved HANDOFF rows to `## Discharged` by re-filing them as ASKS tickets. It filed 14 entries and closed 0 code tickets. A retro trusting the "discharged = success" rule would read those re-filings as wins.
**Proposed wording:** "Discharge a row only when its DONE WHEN predicate passes; a row re-filed to ASKS stays Open with the ASKS pointer."
**Argument against:** `## Open` then grows across phases, and the phase-end gate counts open non-Low rows, so a phase could fail its gate on debt it correctly filed.

## Discharged

(none)
