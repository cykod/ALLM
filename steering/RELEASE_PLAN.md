# ALLM → Hex Release Plan — Design Document

> **Goal:** Make publishing the first ALLM release (`v0.3.0`) and every subsequent patch/minor/major release to `hex.pm` under the `cykod` account a repeatable, low-ceremony procedure — **driven exclusively by explicit local commands**, with no CI automation.
> **Outcome:** A `scripts/release.exs` Mix script such that any future release reduces to: edit CHANGELOG → run `mix run scripts/release.exs patch` (or `minor` / `major` / `<explicit version>`) → confirm prompts.
> **Spec sections:** §34 (release process — referenced by `RELEASE_0_3_PHASING.md` Phase 9 / `CHANGELOG.md` v0.3.0 rollup line "§34 — release process").
> **Layers touched:** none — this is a build/operations plan, not a code change. No `lib/` modifications.

## Status

| Phase | Description | Status |
|-------|-------------|--------|
| 0 | Pre-flight audit of current package metadata + tarball contents | Not Started |
| 1 | One-time Hex account + ownership setup (cykod) | Not Started |
| 2 | First publish — `v0.3.0` release (manual, no script yet) | Not Started |
| 3 | Author `scripts/release.exs` — version bump + gate + publish + tag | Not Started |
| 4 | Post-publish hardening — package retirement / hotfix runbook | Not Started |

**Overall Progress:** 0/5 phases complete

---

## Overview

ALLM is at `mix.exs:4 @version "0.3.0"` with `package/0` already wired (`mix.exs:65-71`: MIT license, GitHub link, files `lib mix.exs README.md CHANGELOG.md LICENSE .formatter.exs`) and ExDoc configured (`mix.exs:73-149`). The Phase 17.3 commit (`d3caa57`) ran `mix hex.build` as a dry-run; the actual `mix hex.publish` has not happened. The repo therefore has *all the metadata* but none of the *publish actions* completed.

This document covers two distinct concerns:

1. **First-publish bootstrap** (one-time): Hex account `cykod`, package ownership, the very first `mix hex.publish` for `v0.3.0`. Done manually so we can read every prompt before automating.
2. **Steady-state release procedure** (every subsequent release): a `scripts/release.exs` Mix script that bumps the version, runs the quality gates, calls `mix hex.publish` interactively, and creates the git tag. One command per release.

**Deliverables:**

- `scripts/release.exs` — the release script (matches the repo's existing `scripts/record_*_fixtures.exs` convention; not in `package.files`, so it doesn't ship in the tarball).
- A pre-flight audit confirming `mix.exs` `package.files` is correct, no secrets in tarball, CHANGELOG hooks line up, and the deferred BLOCKING live-gate from Phase 17.3 has been resolved.
- An update to `CLAUDE.md` (one-line pointer to `scripts/release.exs`) so future Claude sessions find the procedure.

**Out of scope** (deliberate exclusions):

- **CI release automation.** All publishes are explicit local commands run by a maintainer. No GitHub Actions workflow publishes to Hex; no tag-push triggers a release. Rationale: tight feedback loop, no shared API key footprint, no "did the workflow really run the dialyzer step?" ambiguity, no risk of an accidental tag triggering a publish. The cost (a maintainer must type `mix hex.publish` from their own machine on release day) is acceptable for a low-cadence library.
- Multi-package coordination (`allm_conformance` is a `path:` dep at `mix.exs:51`; publishing it as a separate Hex package is its own design).
- `llm_db` Hex coordination — still a deferred future dep per `mix.exs:39`; not in v0.3.x scope.
- Documentation hosting beyond the default `hexdocs.pm/allm` (which ExDoc + Hex generate automatically).
- Pre-release / RC channels (`0.4.0-rc.1` etc.) — defer until there's a v0.4 candidate.
- Signing / OTP releases — Hex packages are not signed by default and ALLM is a library, not a release artifact.

**Non-obvious decisions:**

- **Local-only publishing, no CI automation.** Every publish is a maintainer running `scripts/release.exs` from their workstation against an authenticated `~/.hex/hex.config`. This is the user's explicit constraint, not an "until-CI-is-ready" placeholder. *Docs target: `scripts/release.exs` header docstring.*
- **The `allm_conformance` path-dep needs no rewrite at publish time.** `mix.exs:51` is `only: :test`, and `mix hex.build` strips all `only: :dev | :test` deps from the published `metadata.config` automatically (verified 2026-05-01: a local `mix hex.build` produces a tarball whose `requirements` list contains only `req`, `finch`, `jason`, `telemetry` — none of `allm_conformance`, `plug`, `env_loader`, `ex_doc`, `credo`, `dialyxir`, `stream_data` appear). The comment at `mix.exs:50` predates a verification of this behavior; treat the rewrite step as obsolete, not pending. *Docs target: `mix.exs:50` comment update only — script doesn't need to know about it.*
- **The Phase 17.3 deferred BLOCKING live-gate is a publish prerequisite, not a release-day decision.** `OPENAI_API_KEY=… mix run examples/run_all.exs` and the Anthropic counterpart must run green AND `RUN_OUTPUT_*.md` snapshots regenerated in the same commit BEFORE `mix hex.publish` is invoked. The script does NOT enforce this gate (false-positive risk dominates — most patches don't touch image code); the maintainer is responsible. *Docs target: `scripts/release.exs` header docstring + a one-line warning printed by the script when image-touching files appear in `git diff` since the last release tag.*
- **Hex auth lives in `~/.hex/hex.config` on each maintainer's machine.** Created by `mix hex.user auth` (interactive — username + password + 2FA if enrolled). No `HEX_API_KEY` env var, no GitHub Actions secret, no key in any secrets manager. If the workstation is lost, re-run `mix hex.user auth` on a new one; revoke compromised keys via the hex.pm web UI. *Docs target: `scripts/release.exs` header docstring (setup section).*
- **Tag format is `v<MAJOR>.<MINOR>.<PATCH>`.** Matches `mix.exs:76` `source_ref: "v#{@version}"` already wired into ExDoc → `[source]` links from hexdocs. The script enforces this format. No detached tags, no `release/` prefix, no `allm-v…` prefix. *Docs target: hardcoded in `scripts/release.exs`.*
- **Don't `--amend` past a release tag.** Once `v0.3.0` is tagged and pushed, the commit is immutable; any fix is a `v0.3.1` patch. The script's idempotent-re-run path (Phase 3.3) handles the "publish failed mid-flight, fix and re-run" scenario without amending. *Docs target: `scripts/release.exs` header docstring.*

---

## Pre-flight Audit (Phase 0 detail)

Before the first publish, walk this checklist once. Many items are already green — the audit confirms in writing.

### Package metadata (`mix.exs`)

- [x] `@version "0.3.0"` (`mix.exs:4`).
- [x] `@source_url "https://github.com/cykod/ALLM"` (`mix.exs:5`) — matches GitHub repo.
- [x] `description/0` — non-empty, single sentence (`mix.exs:61-63`).
- [x] `package.licenses` — `["MIT"]` (`mix.exs:67`); `LICENSE` file exists at repo root.
- [x] `package.links` — `%{"GitHub" => @source_url}` (`mix.exs:68`).
- [x] `package.files` — `~w(lib mix.exs README.md CHANGELOG.md LICENSE .formatter.exs)` (`mix.exs:69`).
- [x] `docs.extras` — `["README.md", "CHANGELOG.md"]` (`mix.exs:77`); both files are also in `package.files` (subset invariant from CLAUDE.md, satisfied).
- [x] `docs.source_ref` — `"v#{@version}"` (`mix.exs:76`); the `v0.3.0` git tag must exist before docs source links resolve.
- [ ] **Action:** Confirm by running `mix hex.build` (already validated in Phase 17.3, re-run as part of Phase 0 to refresh the local tarball preview).

### Tarball contents

- [ ] **Action:** `mix hex.build && tar -tzf allm-0.3.0.tar | sort` and confirm:
  - `lib/` present, no `test/`, no `examples/`, no `steering/`, no `scripts/`, no `conformance/`.
  - No `.env`, no `*.secret.exs`, no `erl_crash.dump`, no `tmp/`.
  - `README.md`, `CHANGELOG.md`, `LICENSE`, `mix.exs`, `.formatter.exs` all present.
- [ ] **Action:** Delete the stale `allm-0.2.0.tar` from the repo root (`*.tar` is gitignored per `.gitignore:9`, so it's an untracked leftover from a v0.2 dry-run; safe to `rm`).

### Hex preview

- [ ] **Action:** `mix hex.publish --dry-run` — runs the full publish pipeline locally (build + checks + metadata preview) without uploading. Confirm description, licenses, links, and the included file list match `mix.exs`. Pair with `mix hex.build --unpack` to inspect the unpacked tarball contents (Hex's own recommendation per `mix help hex.publish`).
- [ ] **Action:** `tar -xf allm-0.3.0.tar -O metadata.config | grep -A40 requirements` — confirm the published dependencies list contains ONLY the four runtime deps (`req`, `finch`, `jason`, `telemetry`). If `plug`, `env_loader`, `ex_doc`, `credo`, `dialyxir`, `stream_data`, or `allm_conformance` appear, something has broken Hex's automatic stripping of `only: :dev | :test` deps — investigate before publishing.

### Documentation

- [ ] **Action:** `mix docs` — generates `doc/` locally; spot-check `doc/index.html` opens cleanly with the README rendered, module groups (`mix.exs:78-147`) populated, and `[source]` links present (these will 404 locally because the tag doesn't exist yet — confirm only that the link target matches `https://github.com/cykod/ALLM/blob/v0.3.0/...`).

### Live-gate resolution (carried from Phase 17.3)

- [ ] **Action:** With `OPENAI_API_KEY` and `ANTHROPIC_API_KEY` present in `.env`, run `mix run examples/run_all.exs` and `ALLM_PROVIDER=anthropic mix run examples/run_all.exs`. Confirm exit 0 on both. Cost ≈ $0.09–0.27 per `CHANGELOG.md` v0.3.0 disclosure.
- [ ] **Action:** Regenerate `examples/RUN_OUTPUT_OPENAI.md` and `examples/RUN_OUTPUT_ANTHROPIC.md` *in the same commit* as the run that produced them. CLAUDE.md "Snapshot files" rule: hand-edited or stale snapshots are worse than missing snapshots.
- [ ] **Action:** Update `CHANGELOG.md` v0.3.0 section to flip "Live BLOCKING gate: **deferred**" → "Live BLOCKING gate: **passed on YYYY-MM-DD**" with the actual date.

### Static checks

- [ ] **Action:** `mix format --check-formatted` — clean.
- [ ] **Action:** `mix credo --strict` — zero issues.
- [ ] **Action:** `mix dialyzer` — zero new warnings vs. prior PLT.
- [ ] **Action:** `mix test` — full suite green, ≥80% coverage.

---

## Phase 1: One-time Hex Account + Ownership Setup

**Goal:** Provision the `cykod` Hex account locally and prepare for first publish.

This phase runs **once per maintainer workstation**. After it completes, the local Hex install at `~/.hex/hex.config` carries auth for `cykod` and Phase 2's `mix hex.publish` succeeds without re-prompting for credentials. There is no API key generation, no secrets manager step, no GitHub Actions secret — releases are local-only by design.

### 1.1 Account check / register

```bash
mix hex.user whoami
```

Three branches:

- **If output is `cykod`:** account already authenticated locally — proceed to 1.2.
- **If output is a different username:** the local Hex install is logged in to another account. `mix hex.user auth` prompts for `cykod`'s username + password (and 2FA if enabled).
- **If error "no user authenticated":** run `mix hex.user register` if the `cykod` account does not yet exist on hex.pm, OR `mix hex.user auth` if it already exists. Registration prompts for username (`cykod`), email, and password. Hex emails a confirmation link — must be clicked before publishing.

### 1.2 (Optional) Enroll 2FA on the cykod account

Recommended but not required. Enroll via the hex.pm web UI under Account → Two-factor authentication. There is no Mix task for 2FA enrollment. After enrollment, `mix hex.user auth` and `mix hex.publish` will prompt for a TOTP code on each invocation.

### 1.3 Verify ownership scope (after first publish)

ALLM has not been published yet, so there are no existing owners. After the first publish (Phase 2), `cykod` becomes the sole owner. To add co-maintainers later:

```bash
# After first publish only:
mix hex.owner add allm <email>
mix hex.owner list allm
```

For now, the only action is to confirm the account email matches the one used to verify hex.pm.

### 1.4 Verification

```bash
mix hex.user whoami           # prints "cykod"
```

---

## Phase 2: First Publish — v0.3.0

**Goal:** Publish `allm 0.3.0` to hex.pm under the `cykod` account.

Prerequisite: Phase 0 audit complete + Phase 1 authenticated.

### 2.1 Final pre-publish gate

Run **all** of these from a clean working tree (`git status` clean, on `main`):

```bash
mix deps.get
mix format --check-formatted
mix test
mix credo --strict
mix dialyzer
mix hex.build                  # produces allm-0.3.0.tar locally for inspection
tar -tzf allm-0.3.0.tar | sort # confirm contents per Phase 0 audit
```

Any failure here is a stop. Do not proceed.

### 2.2 Publish (before tagging)

```bash
mix hex.publish
```

Interactive — prompts twice:

1. Confirms package metadata (name, version, description, licenses, links, files). **Read every line.** This is the last chance to catch a wrong file in `package.files` or a typo in description.
2. Confirms publish to hex.pm. Type `Y` to commit.

Hex uploads the tarball, generates docs from `mix docs`, and publishes both. Within 30 seconds:

- `https://hex.pm/packages/allm` — package landing page.
- `https://hexdocs.pm/allm/0.3.0/` — generated docs.

If `mix hex.publish` fails (network, validation rejection, 2FA timeout), no tag has been pushed and there is nothing to revert. Fix the cause and re-run.

### 2.3 Tag and push (after publish succeeds)

```bash
git tag -a v0.3.0 -m "v0.3.0 — Multimodal foundation"
git push origin v0.3.0
```

The annotated tag is what `mix.exs:76 source_ref: "v#{@version}"` resolves to in hexdocs `[source]` links. Until the tag is on GitHub, hexdocs `[source]` links resolve to a 404 — expected, gone within seconds of pushing the tag.

The publish-then-tag order is deliberate: a failed publish with a pre-pushed tag is messy to recover (force-delete from origin + re-coordinate with consumers who pulled the tag). The local-only flow keeps publish-first as the steady-state ordering for every release.

### 2.4 Smoke-test the published package

The goal is to confirm the published tarball compiles and loads cleanly in a fresh project — catching missing-file bugs that local `mix test` doesn't (the local checkout has every file; the published tarball has only `package.files`).

```bash
cd /tmp && mix new allm_smoke && cd allm_smoke
# Edit mix.exs deps to add: {:allm, "~> 0.3"}
mix deps.get
iex -S mix
```

In the IEx prompt, run these load checks:

```elixir
# Fake ships in lib/ (per AGENT_DESIGN_SPEC: "The Fake is part of the library, not test-only")
true = Code.ensure_loaded?(ALLM.Providers.Fake)
true = Code.ensure_loaded?(ALLM.Providers.OpenAI)
true = Code.ensure_loaded?(ALLM.Providers.Anthropic)
true = Code.ensure_loaded?(ALLM.Providers.OpenAI.Images)
true = Code.ensure_loaded?(ALLM.Providers.FakeImages)
# Test-support fixtures must NOT ship — these live under test/support
false = Code.ensure_loaded?(ALLM.Providers.Fake.Fixtures)
# Public facade compiles
[generate: 3, stream_generate: 3, chat: 3, stream: 3, generate_image: 3] =
  Enum.filter(ALLM.__info__(:functions), fn {n, _} ->
    n in [:generate, :stream_generate, :chat, :stream, :generate_image]
  end) |> Enum.uniq()
```

A live end-to-end smoke (a real `ALLM.generate/3` call against a Fake-driven engine) is optional — it duplicates `test/` coverage that already passed locally. The load checks are sufficient to catch tarball-shape regressions.

### 2.5 Post-publish

- [ ] Add any co-maintainers via `mix hex.owner add allm <email>`.
- [ ] Update GitHub repo description / topics if Hex shows them in a different shape than expected.
- [ ] Open `hexdocs.pm/allm/0.3.0/` in a browser, confirm module groups render, confirm at least one `[source]` link in a public function (`ALLM.generate/3`) resolves to `github.com/cykod/ALLM/blob/v0.3.0/...`.
- [ ] Announce / link from README badges (optional — see Open questions).

---

## Phase 3: Authoring `scripts/release.exs`

**Goal:** A single script that takes a version-bump argument, runs every quality gate, asks for confirmation at the irreversible step, calls `mix hex.publish` interactively, and creates the git tag on success. So that v0.3.1, v0.3.2, v0.4.0 all follow the same path with no manual checklist.

### 3.1 Script invocation

```bash
mix run scripts/release.exs patch          # 0.3.0 → 0.3.1
mix run scripts/release.exs minor          # 0.3.0 → 0.4.0
mix run scripts/release.exs major          # 0.3.0 → 1.0.0
mix run scripts/release.exs 0.4.0-rc.1     # explicit version (validated as SemVer)
mix run scripts/release.exs --help         # usage
```

Optional flags:
- `--skip-dialyzer` — skip the `mix dialyzer` step (PLT build is slow; useful for patch releases where you've already run dialyzer locally moments before).
- `--dry-run` — run every gate including `mix hex.publish --dry-run`, but stop before the real publish + tag. No working-tree mutations.
- `--allow-dirty` — bypass the "git working tree is clean" check (escape hatch; the script warns loudly).

### 3.2 Script flow (stepwise)

The script is a single `scripts/release.exs` file run via `mix run` (so it has access to deps and the project's `Mix.Project` config). Steps:

1. **Parse argument** — `patch | minor | major | <semver>` → compute new version from `Mix.Project.config()[:version]`. Reject if argument is missing or unrecognized.
2. **Git working-tree check** — `git status --porcelain` must be empty. Reject otherwise (unless `--allow-dirty`).
3. **Branch check** — `git rev-parse --abbrev-ref HEAD` must be `main`. Reject otherwise.
4. **Up-to-date check** — `git fetch origin main && git rev-list --count HEAD..origin/main` must be 0. Reject otherwise.
5. **Tag-doesn't-exist check** — `git rev-parse v<X.Y.Z>` must fail. Reject if the tag already exists locally or on origin (`git ls-remote --tags origin v<X.Y.Z>`).
6. **CHANGELOG check** — `CHANGELOG.md` must contain a `## ` heading line whose text includes the literal `v<X.Y.Z>` (e.g., `## v0.3.0 — Multimodal foundation`, or the bare form `## v0.3.1`). The maintainer runs the `/changelog` skill BEFORE invoking this script; that skill regenerates `CHANGELOG.md` with one succinct entry per shipped version. The release script verifies the entry exists, then commits the file as part of the release commit (step 12) — there is no `## [Unreleased]` auto-rewrite. Reject otherwise. Rationale: per-commit history lives in `HISTORY.md` (dev-only, NOT in `package.files`); `CHANGELOG.md` is the consumer-facing succinct release-notes file generated by `/changelog`, and is what ships in the Hex tarball + hexdocs.
7. **Quality gates** — run in order, abort on first failure:
   - `mix format --check-formatted`
   - `mix deps.get` (idempotent; ensures lock matches)
   - `mix test`
   - `mix credo --strict`
   - `mix dialyzer` (skippable via `--skip-dialyzer`)
   - `mix hex.build` — produces `allm-<old-version>.tar` for inspection.
8. **Bump `mix.exs @version`** — atomic edit of the `@version "X.Y.Z"` line. Show diff.
9. *(removed — no CHANGELOG auto-rewrite; the maintainer writes the final heading directly per step 6.)*
10. **Confirmation prompt #1** — display the proposed version, the `mix.exs` diff, the CHANGELOG diff, the tarball file list (`tar -tzf allm-<new>.tar`). Prompt: `Publish allm <new-version> to Hex? [y/N]` — reject unless answer is `y` or `yes`.
11. **`mix hex.publish`** — invoke via `Mix.Task.run("hex.publish", [])` so prompts pass through stdin/stdout (never `--yes`). The Hex prompts are the second safety check; the script does NOT bypass them.
12. **On publish success** — commit + tag + push:
    - `git add mix.exs CHANGELOG.md`
    - `git commit -m "Release v<X.Y.Z>"`
    - `git tag -a v<X.Y.Z> -m "v<X.Y.Z>"`
    - `git push origin main v<X.Y.Z>`
13. **Print success summary** — `https://hex.pm/packages/allm/<new>` and `https://hexdocs.pm/allm/<new>/` URLs, plus a reminder to run the smoke test from Phase 2.4 if this is a major bump.

### 3.3 Failure modes the script handles

| Failure point | Script behavior |
|--|--|
| Working tree dirty | Abort before any mutation; print `git status` |
| Wrong branch | Abort; print current branch + required branch |
| Behind origin/main | Abort; print `git pull` reminder |
| Tag already exists | Abort; print existing-tag SHA |
| CHANGELOG missing entry | Abort; print suggestion to run the `/changelog` skill (which regenerates `CHANGELOG.md` with the missing version's heading + body) before re-invoking the release script |
| Quality gate fails | Abort; print which step failed; no working-tree mutation |
| `mix hex.publish` fails (network, validation, 2FA timeout) | The `mix.exs` and `CHANGELOG.md` edits ARE on disk but NOT committed. Print clear "publish failed; mix.exs/CHANGELOG edits left in working tree; investigate, fix, and re-run" message. Re-running with the same arg detects the version is already bumped (`mix.exs:4` already at target) and skips step 8 — idempotent re-run path. |
| User answers `n` at confirmation #1 | Roll back the `mix.exs` edit via `git checkout -- mix.exs` (CHANGELOG.md is maintainer-written and never touched by the script — must NOT be reverted, or unstaged release notes under `--allow-dirty` would be lost). Working tree returns to pre-script state. |

### 3.4 What the script does NOT do

- Does NOT skip the `mix hex.publish` interactive confirmation — never passes `--yes`. The Hex prompts ARE part of the safety story.
- Does NOT publish from CI — there is no `--non-interactive` mode by design.
- Does NOT auto-edit CHANGELOG content. The maintainer writes the release-notes heading + body by hand before running the script; the script only verifies that a `## ` heading containing `v<X.Y.Z>` is present.
- Does NOT auto-rewrite `[Unreleased]` headings — the consumer-facing `CHANGELOG.md` is regenerated by the `/changelog` skill, which the maintainer runs manually before invoking this script. Per-commit history (`HISTORY.md`) is dev-only and never edited or shipped by the release flow.
- Does NOT push to origin before the publish succeeds — the order is publish-first, commit+tag+push-after, so a failed publish leaves no stranded artifacts.
- Does NOT run the live-API gate from Phase 17.3 / Phase 0 (`examples/run_all.exs`) — those cost real money. The maintainer runs them manually before invoking the script when image/vision code has changed; the script does NOT enforce this (false-positive risk would dominate). The CHANGELOG-edit step is the prompt to think about whether live-gate runs are needed.

### 3.5 `CLAUDE.md` pointer

Add one line under "Common commands" (around `CLAUDE.md:75-95` — see existing structure):

> Releases run via `mix run scripts/release.exs <patch|minor|major|version>`. The script enforces clean git, runs all quality gates, bumps `mix.exs @version`, calls `mix hex.publish` interactively, and tags on success. Future Claude sessions MUST NOT manually edit `mix.exs @version` — use the script.

This is the same convention as the existing CLAUDE.md pointers (`steering/allm_engine_session_streaming_spec_v0_2.md` for spec, `AGENT_DESIGN_SPEC.md` for design docs).

### 3.6 Verification

- [ ] `scripts/release.exs` exists, runnable via `mix run scripts/release.exs --help`.
- [ ] `mix run scripts/release.exs patch --dry-run` from a clean working tree on `main` runs every gate, shows the proposed diff, and exits cleanly without mutating `mix.exs` or creating a tag.
- [ ] `mix run scripts/release.exs patch --dry-run` from a dirty tree aborts with a clear error before running any gate.
- [ ] `mix run scripts/release.exs patch --dry-run` from a non-main branch aborts with a clear error.
- [ ] `CLAUDE.md` references `scripts/release.exs` at least once.
- [ ] `mix.exs` `package.files` does NOT include `scripts/` (the script must not ship in the tarball).
- [ ] A patch-release dress rehearsal (against a throwaway feature branch tagged `v0.3.0-test`, with `--dry-run`) walks the script end-to-end and exits successfully without publishing.

---

## Phase 4: Post-publish Hardening

**Goal:** Document the operational tail of release management — what to do when a release is broken, when a co-maintainer joins, when the next major comes.

### 4.1 Hotfix runbook (in `scripts/release.exs` header docstring)

For a broken `v0.3.0` discovered post-publish:

1. **Within 24 hours of the first-ever publish of `allm`** (per `mix help hex.publish`: "A new package can be reverted or updated within 24 hours of its initial publish"): `mix hex.publish --revert 0.3.0` fully removes from hex.pm. Use only if the package is dangerously broken (corrupted `.beam`, accidentally-included secret).
2. **For any subsequent version** (e.g., `0.3.1`, `0.4.0`): the revert window narrows to **1 hour** after that version's publish.
3. **After the applicable revert window:** Cannot revert. Choices are:
   - **Soft retire:** `mix hex.retire allm 0.3.0 invalid --message "Use 0.3.1, contains <bug>"`. Package stays installable but Hex displays a warning. `--message` is required (≤140 chars). Valid reasons: `renamed`, `deprecated`, `security`, `invalid`, `other`.
   - **Patch forward:** ship `0.3.1` with the fix, mark `0.3.0` retired.

### 4.2 Co-maintainer onboarding

Documented in `scripts/release.exs` header docstring:

```bash
# Run by current owner (cykod):
mix hex.owner add allm <new-maintainer-email>
# New maintainer runs Phase 1.1–1.4 from their workstation
# (mix hex.user auth into their own ~/.hex/hex.config — no shared key),
# then runs `mix run scripts/release.exs <bump>` from their workstation.
```

### 4.3 Major-version bump checklist (`v1.0.0`)

When the time comes:

- [ ] CHANGELOG entry enumerates every closed-union variant added (CLAUDE.md "Adding a new variant…"), every behaviour signature changed, every struct field removed/renamed.
- [ ] README "Getting Started" updates `~> 0.X` to `~> 1.0`.
- [ ] Open a deprecation policy doc (`DEPRECATION.md`) — what `0.x` users get for migration time.
- [ ] Optional: tag `v1.0.0-rc.1` first, sit on it for two weeks, gather feedback.

### 4.4 Verification

- [ ] `scripts/release.exs` header docstring covers revert + retire + patch-forward (`mix help` style).
- [ ] `scripts/release.exs` header docstring covers co-maintainer onboarding.
- [ ] Major-bump checklist lives in `scripts/release.exs` header docstring (or its own `MAJOR_BUMP.md` if the section grows past ~30 lines).

---

## File Tree

```
scripts/release.exs                   (NEW — Phase 3, the release script)
CLAUDE.md                             (MODIFY — Phase 3, one-line pointer to scripts/release.exs)
mix.exs                               (MODIFY — Phase 0, line 50 comment update; Phase 3 runtime mutation by the script via @version bump)
CHANGELOG.md                          (MODIFY — Phase 0, flip "deferred" → "passed YYYY-MM-DD" once live gate runs; Phase 3 runtime mutation by the script via [Unreleased] → v<X.Y.Z>)
examples/RUN_OUTPUT_OPENAI.md         (MODIFY — Phase 0, regenerate same commit as live run)
examples/RUN_OUTPUT_ANTHROPIC.md      (MODIFY — Phase 0, regenerate same commit as live run)
allm-0.2.0.tar                        (DELETE — Phase 0, untracked stale dry-run artifact)
```

No `.github/workflows/` files. No `RELEASING.md` — the script's header docstring is the only documentation of the release procedure. Releases are local-only by user constraint.

No `lib/` changes. No `test/` additions — `test/allm/release_polish_test.exs` was deleted as part of this plan's implementation: every assertion it carried was either pinned to the v0.3.0 ship (would rot on every bump) or duplicated a check the release script's tarball audit + live-gate already cover. The release flow itself is the test.

---

## Definition of Done

- [ ] Phase 0 audit complete; `allm-0.2.0.tar` deleted; tarball contents verified.
- [ ] Phase 17.3 deferred BLOCKING live-gate resolved: `run_all.exs` exit 0 on both providers, `RUN_OUTPUT_*.md` regenerated in the same commit, CHANGELOG flipped.
- [ ] `cykod` Hex account authenticated locally (`mix hex.user whoami` prints `cykod`).
- [ ] First publish (Phase 2): `mix hex.publish` run manually from a maintainer workstation, `v0.3.0` tag pushed afterwards, `https://hex.pm/packages/allm/0.3.0` reachable.
- [ ] Smoke test from a fresh `mix new` project against `{:allm, "~> 0.3"}` succeeds.
- [ ] `scripts/release.exs` exists, `--help` works, `--dry-run` from a clean working tree on `main` exits cleanly without mutating state.
- [ ] `scripts/release.exs` is NOT in `mix.exs` `package.files` (verified via `tar -tzf` — script must not ship in the published tarball).
- [ ] `CLAUDE.md` points to `scripts/release.exs` and explicitly forbids manual `mix.exs @version` edits.
- [ ] `scripts/release.exs` header docstring covers hotfix (revert / retire / patch-forward), co-maintainer onboarding, the major-bump checklist, and contains zero references to GitHub Actions, CI, `HEX_API_KEY`, `--yes`, or tag-triggered publishes.
- [ ] First non-bootstrap release (e.g., v0.3.1) goes through `scripts/release.exs` end-to-end as the validation that the script works.

---

## Open questions

These are minor decisions that can be made at any point; everything in Phases 0–4 is mechanical.

1. **2FA on `cykod` Hex account.** Recommended. Enroll via the hex.pm web UI under Account → Two-factor authentication (there is no Mix task for 2FA enrollment). With 2FA on, every `mix hex.publish` prompts for a TOTP code — small friction, large account-takeover protection.
2. **README badges.** Optional — Hex version badge (`https://img.shields.io/hexpm/v/allm.svg`), docs badge (`https://img.shields.io/badge/hex.pm-docs-blue`), license badge. Cosmetic; defer if not wanted.
