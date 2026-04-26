# Phase 12: v0.2 Release Polish — Design Document

> **Goal:** Translate the four `steering/examples/` case studies (Amesbury, Garden, meal, unllmtd) into runnable integration tests against `ALLM.Providers.Fake` under `test/examples/`; freeze the spec §31 scenario audit (`mix test --only spec_31` must enumerate every §31 scenario as currently shipped); ship a "Getting Started" README, an `ex_doc` layout that leads with `ALLM` then `ALLM.Session` then behaviours then providers; produce a single CHANGELOG rollup of the v0.2 delta; bump `@version` from `"0.0.1"` to `"0.2.0"` in `mix.exs:4`; and verify `mix hex.build` dry-run succeeds without publishing. The phase ends with a final `/review` pass against `AGENT_REVIEW_SPEC.md`.
> **Outcome:** A library user reading `hexdocs.pm/allm` lands on `ALLM` with a worked `chat/3`-against-Fake snippet inside 15 lines; the four `steering/examples/` translations live as `mix test`-covered integration tests proving each example's API surface compiles and behaves as documented; `mix test --only spec_31` returns a fixed count of cases that matches the file's frozen test-block count (18 `test` blocks across 13 `describe` blocks decomposing the 12 §31 scenarios — see Decision #2); `mix hex.build` dry-run succeeds (writing a tarball `allm-0.2.0.tar` to the project root); `mix.exs` `@version` reads `"0.2.0"`; `CHANGELOG.md` carries a single rollup heading covering the v0.2 delta plus the existing per-phase entries (no rewrite of history); `mix test`, `mix credo --strict`, `mix dialyzer`, `mix format --check-formatted` all green; ≥ 90 % coverage on new code (the integration tests don't change library code so global coverage is unaffected). Hex publish is **not** triggered by this phase — see Decision #1.
> **Spec sections:** §31 (testing and fake adapter — the nine property-style scenarios that every implementation must pass), §32.1 (initial bundled adapters — both providers shipped, both exercised by the case-study translations), §32.4 (what ALLM owns — the four case-study translations are the proof-of-fit for that ownership claim), §33 (v0.2 non-goals — the case-study translations must not silently drift past these), §34 (summary — the rollup CHANGELOG mirrors the §34 framing).
> **Layers touched:** **None — release-polish phase.** No `lib/` code changes. New `test/examples/*.exs` files are Layer C *consumers* (they exercise the public Layer C and Layer D API through `ALLM.Providers.Fake`); they do not introduce new modules or types, do not add new behaviours, do not extend any closed enum. The Behaviour & Type Contracts section is therefore minimal — the only contractual addition is the `@moduletag :spec_31` invariant frozen as the §31 audit gate. Documentation, `ex_doc` config, `mix.exs` version, and `CHANGELOG.md` are out of the four-layer model entirely.
> **Phasing doc:** [`PROJECT_PHASING.md`](PROJECT_PHASING.md) Phase 12.

## Status

| Sub-phase | Description | Layer | Status |
|-----------|-------------|-------|--------|
| 12.1 | §31 scenario freeze: confirm `mix test --only spec_31` enumerates the file's 18 `test` blocks (the 12 §31 scenarios decomposed into 13 `describe` groups, several of which carry more than one `test` block — e.g., the parallel-tool-calls scenario splits streaming + step-folded variants); add a meta-test asserting `test`-block count via ExUnit registration introspection; update the file's docstring header so it reads "v0.2 release-polish freeze" instead of "after Phase 8". | — | Not Started |
| 12.2 | Translate four `steering/examples/` case studies into `test/examples/{amesbury,garden,meal,unllmtd}_test.exs` integration tests, each backed by `ALLM.Providers.Fake` scripted fixtures. Each test loads the case study's documented call surface, runs it end-to-end, and asserts the user-visible shape matches the example's promise. | C (consumer) | Not Started |
| 12.3 | Public docs polish: rewrite `README.md` with a "Getting Started" 15-line `chat/3`-against-Fake worked example; configure `ex_doc` `groups_for_modules` so generated hex docs lead with the `ALLM` facade, then `ALLM.Session`, then Behaviours, then Providers, then Errors; add a top-of-file `## v0.2 — <date>` rollup heading to `CHANGELOG.md` summarizing the 11 prior phase entries; update `README.md` to drop the "Pre-release scaffolding" status and replace with the v0.2 framing. | — | Not Started |
| 12.4 | Release polish: bump `mix.exs:4` `@version` from `"0.0.1"` to `"0.2.0"` (per Decision #1); run `mix hex.build` and confirm it produces an `allm-0.2.0.tar` artifact at the project root (no `mix hex.publish`); audit `mix.exs:71` `package.files` against the actual repo tree (confirm `examples/`, `scripts/`, `steering/`, `test/`, `conformance/` are excluded); run a final `/review` pass per `AGENT_REVIEW_SPEC.md` and capture the artifact under `steering/reviews/PHASE_12_REVIEW.md`. | — | Not Started |

**Overall Progress:** 0/4 sub-phases complete

## Overview

Phase 12 is the **wrap-up phase**. Phases 1–11 shipped a runtime; Phase 12 ships the artifacts that turn a runtime into a release: a Getting Started snippet a new user can copy into `iex`, a hex-docs layout that leads with the public facade, four end-to-end translations of the `steering/examples/` case studies that prove the library does what those documents promise, and a `mix.exs` package whose `mix hex.build` dry-run succeeds. There is **no library code change** in this phase. The Implementation Checklist for every sub-phase begins with "Touch zero files under `lib/`" — if a case-study translation discovers an API gap, that's a design defect in an earlier phase, not a Phase 12 fix.

The phase's load-bearing correctness obligation is **the four case-study translations exercise every public API surface the case studies promise**, against the deterministic `ALLM.Providers.Fake` (spec §31) — never against the network. The Amesbury translation exercises `Engine.put_tools/2`, `Engine.put_context/3`, `ALLM.chat/3` with `max_turns: 5`, the two-explicit-call structured-output pattern that the Amesbury case study uses to side-step OpenAI's tools-and-`response_format`-can't-coexist limitation, and `ALLM.Thread.add_user/2`. The Garden translation exercises engine construction with `ALLM.Providers.Fake`, `ALLM.generate/3` with `response_format`, `ALLM.stream_generate/3`, and the `ALLM.tool/1` + `ALLM.Engine.put_tool/2` pair. The meal translation exercises `ALLM.generate/3` with `response_format: ALLM.json_schema(...)`, `ALLM.chat/3` with one tool, and `ALLM.Session.start/3` + `Session.reply/4` for the recipe-modification flow. The unllmtd translation exercises multi-provider engine selection (a Fake-as-OpenAI engine and a Fake-as-Anthropic engine differing only in `:adapter`), `ALLM.chat/3` `mode: :auto` with multiple turns, `mode: :manual` halt + caller-supplied tool result via `ALLM.Session.submit_tool_result/3`, and `{:ask_user, _, _}` halt + follow-up turn. Each test file ends with `assert` shapes that mirror the case study's "After" snippets — if the assertion drifts from what the case study promises, the assertion is wrong, not the case study.

The phase's second obligation is **§31 audit freezes the active test-block count.** `test/allm/providers/fake_scenarios_test.exs` was assembled phase-by-phase across Phases 4–8; its in-file table currently reads "Active coverage after Phase 8: 12 scenarios... All §31 scenarios are now active" (`test/allm/providers/fake_scenarios_test.exs:8-10`), where the 12 *scenarios* decompose into 13 `describe` blocks containing 18 `test` blocks (verified 2026-04-26 — several scenarios split into a streaming variant + a step-folded variant, e.g., parallel-tool-calls is one row in the table but two `test` blocks in the file). Phase 12.1 freezes the *test-block* count at 18 with a meta-test that introspects ExUnit's registration table and asserts the count equals `@case_count`, and updates the in-file docstring from "after Phase 8" to "v0.2 release-polish freeze (Phase 12)". The 12-scenario / 18-test distinction matters because `mix test --only spec_31` reports the test-block count as the user-visible "N tests, 0 failures" line; freezing the test-block count is what turns "did somebody add a §31 row?" into a loud `assert == 18` failure rather than a silent change in the test-output line. Adding a §31 row in v0.3 will then be a loud PR-review signal — the meta-test fails, forcing the contributor to bump `@case_count` and document the new scenario. Phases 9–11 added zero §31 rows (verified by reading those phase designs); the freeze is purely defensive.

The phase's third obligation is **`ex_doc`'s `main:` field stays `"ALLM"` and `groups_for_modules` lays out the module index in the order a new user would meet things.** `mix.exs:75` already has `main: "ALLM"`; the gap is `groups_for_modules` (currently absent — modules dump alphabetically in the sidebar today). Phase 12.3 adds five groups: `Facade` (just `ALLM`), `Sessions` (`ALLM.Session`, `ALLM.Session.StreamReducer`), `Behaviours` (`ALLM.Adapter`, `ALLM.StreamAdapter`, `ALLM.ToolExecutor`, `ALLM.ToolResultEncoder`), `Providers` (`ALLM.Providers.OpenAI`, `ALLM.Providers.Anthropic`, `ALLM.Providers.Fake`, `ALLM.Providers.Support.SSE`), `Data types` (`ALLM.Message`, `ALLM.Request`, `ALLM.Response`, `ALLM.Thread`, `ALLM.StepResult`, `ALLM.ChatResult`, `ALLM.Event`, `ALLM.Usage`, `ALLM.Tool`, `ALLM.ToolCall`, `ALLM.ModelRef`), `Runtime` (`ALLM.Engine`, `ALLM.Keys`, `ALLM.Validate`, `ALLM.Capability`, `ALLM.Retry`, `ALLM.Telemetry`, `ALLM.StreamCollector`, `ALLM.Serializer`), `Errors` (`ALLM.Error.AdapterError`, `ALLM.Error.EngineError`, `ALLM.Error.SessionError`, `ALLM.Error.StreamError`, `ALLM.Error.ToolError`, `ALLM.Error.ValidationError`). The `extras:` list is widened from `["README.md"]` to `["README.md", "CHANGELOG.md"]` so the rollup is rendered as a navigable doc page.

The phase's fourth obligation is **`mix hex.build` dry-run succeeds without publishing.** Spec §34 doesn't dictate publish; PROJECT_PHASING.md key decision (a) names the choice. Per Decision #1: bump `@version` to `"0.2.0"` and run `mix hex.build` (which writes `allm-0.2.0.tar` at the project root, beside `mix.exs`, and exits cleanly). **`mix hex.publish` is NOT run.** Publish is a separate manual step taken outside this phase by the package maintainer — it requires Hex auth, a clean git working tree, and a release sign-off neither of which Phase 12 owns. The dry-run validates the package metadata is valid (`description:`, `licenses:`, `links:`, `files:`) and the included file list excludes test fixtures, recorded SSE captures, the `examples/` directory, and the `conformance/` umbrella package per `mix.exs:71`'s `package.files` whitelist (`~w(lib mix.exs README.md LICENSE .formatter.exs)`).

The phase's fifth obligation is **`README.md` Getting Started works for a reader who has never seen ALLM.** The current `README.md` is 35 lines of structural framing (four layers, dev commands, license) and labels itself "Pre-release scaffolding" (`README.md:18`). Phase 12.3 rewrites it: keep the four-layer summary, drop the scaffolding label, and add a "Getting Started" section that shows a complete `chat/3` call against `ALLM.Providers.Fake` in 15 lines including the `mix.exs` deps stanza. The snippet is doctest-style (the same shape as `@doc` examples in `lib/allm.ex`) so a reader can copy it into `iex -S mix` against a fresh `mix new` project and watch it work without an API key. A second short section names the two real-provider entry points (`ALLM.Providers.OpenAI`, `ALLM.Providers.Anthropic`) and points to `examples/README.md` for the runnable end-to-end smoke scripts.

The phase's sixth obligation is **CHANGELOG rollup is additive, not a rewrite.** The existing `CHANGELOG.md` carries one entry per phase (Phase 1 through Phase 11.4) in reverse-chronological order. Phase 12.3 prepends a single `## v0.2 — <release date>` heading whose body is a 6–10 bullet summary of the v0.2 delta from `0.0.1`: layer architecture, stream-first execution, both providers, sessions with serializability, telemetry/retry/capability cross-cutting, the example smoke-test framework, and the `/review` validation gate. **Existing per-phase entries are preserved verbatim.** A reader who wants the granular history scrolls past the rollup; a reader who wants the elevator pitch reads only the rollup. The release date is the date of the Phase 12 milestone commit — not a future date — so `mix hex.build` against the bumped version doesn't carry a date that contradicts the commit.

The phase's seventh obligation is **the final `/review` pass per `AGENT_REVIEW_SPEC.md` is recorded as `steering/reviews/PHASE_12_REVIEW.md`.** Per `AGENT_REVIEW_SPEC.md` (assumed to mirror the `/review` skill in this repo), the review walks the diff, calls out any drift from spec/design, and produces a Findings section with severity-tagged items. Phase 12 is intentionally low-risk for `/review` — the diff is doc + config + new test files, not library code — so the expected output is a short Findings section. If a Finding surfaces a real defect (e.g., a doctest broke, a `groups_for_modules` rule missed a module, the case-study translation diverges from the case study), the defect is fixed in-phase before the review artifact is committed.

The phase's eighth obligation is **the four case-study translations are coverage-neutral.** They exercise existing `lib/` code; they do not add new public API. They land at ≥ 90 % coverage on the new test files (i.e., every assert and every helper function in `test/examples/*.exs` is exercised) but they do **not** push the global coverage threshold up or down materially. The 80 % global floor is preserved; the ≥ 90 %-on-new-code rule applies to the test files themselves (a trivial bar — the file's `test` blocks ARE the code, and they all run).

### Layer demonstration

Phase 12 touches no `lib/` layer. The "user consumes the new functionality" demonstration is therefore non-applicable in the four-layer sense. Instead, the demonstration is **the Phase 12 reader-facing artifacts in action** — what a new user sees on day one:

**Hex docs landing page (sub-phase 12.3, after `mix docs`):**

```
ALLM v0.2.0
═══════════════════════════
ALLM is a provider-neutral LLM execution library...

Modules
├── Facade
│   └── ALLM
├── Sessions
│   ├── ALLM.Session
│   └── ALLM.Session.StreamReducer
├── Behaviours
│   ├── ALLM.Adapter
│   ├── ALLM.StreamAdapter
│   ├── ALLM.ToolExecutor
│   └── ALLM.ToolResultEncoder
├── Providers
│   ├── ALLM.Providers.OpenAI
│   ├── ALLM.Providers.Anthropic
│   └── ALLM.Providers.Fake
├── Data types
│   ├── ALLM.Message, ALLM.Request, ALLM.Response, ...
├── Runtime
│   ├── ALLM.Engine, ALLM.Keys, ALLM.Capability, ...
└── Errors
    ├── ALLM.Error.AdapterError, ...
```

**README Getting Started (sub-phase 12.3, copy-paste-runnable against Fake):**

```elixir
# In a fresh project:
# {:allm, "~> 0.2"} in mix.exs deps, then mix deps.get; iex -S mix.

engine =
  ALLM.Engine.new(
    adapter: ALLM.Providers.Fake,
    adapter_opts: [script: [{:text, "Hello, ALLM!"}, {:finish, :stop}]]
  )

{:ok, %ALLM.ChatResult{final_response: %ALLM.Response{output_text: text}}} =
  ALLM.chat(engine, [ALLM.user("Hi.")])

text
# => "Hello, ALLM!"
```

**`mix test --only spec_31` (sub-phase 12.1):**

```bash
$ mix test --only spec_31
...................
Finished in 0.1 seconds (...)
19 tests, 0 failures
# 18 §31 test-blocks (decomposing the 12 documented scenarios across 13
# describe blocks) + 1 audit-gate meta-test asserting count == 18.
```

**Case-study translation (sub-phase 12.2, e.g., `test/examples/meal_test.exs`):**

```bash
$ mix test test/examples/meal_test.exs
......
Finished in 0.0 seconds (...)
6 tests, 0 failures
# Translation of `steering/examples/meal_example.md`'s "After" snippets,
# driven against ALLM.Providers.Fake. No network. Each test asserts the
# case study's promised shape (Response.output_text JSON-decodable to a
# recipe map, ChatResult after a tool round-trip, Session-survives-ETF).
```

**`mix hex.build` dry-run (sub-phase 12.4):**

```bash
$ mix hex.build
Building allm 0.2.0
  Files:
    .formatter.exs
    LICENSE
    README.md
    lib/allm.ex
    lib/allm/...    # 45+ files
    mix.exs
  ...
  Package built: allm-0.2.0.tar           # at the project root, NOT under _build/
# No publish; the artifact validates package metadata and file inclusion.
```

### Deliverables

- **New files:**
  - `test/examples/amesbury_test.exs` — translation of `steering/examples/amesury_example.md`'s "After" snippets. Exercises `ALLM.chat/3` with `max_turns:`, `Engine.put_tools/2`, `Engine.put_context/3`, and the two-pass structured-output pattern documented in §10.5 of that case study. Driven against `ALLM.Providers.Fake` with scripted multi-turn tool-call fixtures.
  - `test/examples/garden_test.exs` — translation of `steering/examples/garden_example.md`. Exercises `ALLM.generate/3` with `response_format`, `ALLM.stream_generate/3`, and the `Engine` construction pattern that case study uses (Fake-backed dev/test override).
  - `test/examples/meal_test.exs` — translation of `steering/examples/meal_example.md`. Exercises `ALLM.generate/3` with `response_format: ALLM.json_schema(...)`, `ALLM.chat/3` with one tool (the `fetch_recipe_page` example), and `ALLM.Session.start/3` + `Session.reply/4` for the recipe-modification flow.
  - `test/examples/unllmtd_test.exs` — translation of `steering/examples/unllmtd_example.md`. Exercises multi-provider switching via two distinct engines, multi-turn auto mode, manual mode halt + tool-result submission, and `{:ask_user, _, _}` halt + follow-up turn.
  - `test/examples/test_helper.exs` — a tiny shared helper module `ALLM.Test.ExampleFixtures` exposing common scripted fixtures (`recipe_text/0`, `weather_tool/0`, `tool_round_trip_script/0`, `manual_halt_script/0`, `ask_user_script/0`) used across the four case-study tests. Avoids 4-way duplication of fake-script construction. Approx. 80 LOC.
  - `test/groups_for_modules_audit_test.exs` — sub-phase 12.3 audit test asserting every public (non-`@moduledoc false`) module under `lib/` appears in exactly one `mix.exs` `groups_for_modules:` group. ~40 LOC.
  - `steering/reviews/PHASE_12_REVIEW.md` — final `/review` pass artifact (sub-phase 12.4).
- **Modified files:**
  - `README.md` — rewritten Getting Started + drop "Pre-release scaffolding" status. Approx. 80 LOC after rewrite (vs. 35 today).
  - `CHANGELOG.md` — single rollup heading prepended; existing entries preserved verbatim.
  - `mix.exs:4` — `@version "0.0.1"` → `@version "0.2.0"`.
  - `mix.exs` `docs/0` — extend with `groups_for_modules:` per §Behaviour & Type Contracts; widen `extras:` from `["README.md"]` to `["README.md", "CHANGELOG.md"]`.
  - `test/allm/providers/fake_scenarios_test.exs` — header docstring rewrite ("after Phase 8" → "v0.2 release-polish freeze"); add a `case_count/0` module attribute + meta-test asserting count == 12 (Decision #2 + AGENT_DESIGN_SPEC §3 rule 7).
- **No new modules under `lib/`.** The single `lib/` edit is one `@moduledoc` doctest addition in `lib/allm.ex` per Decision #3 — runtime semantics unchanged; the doctest is exercised by the existing `doctest ALLM` line in `test/allm_test.exs`.
- **No new behaviours, no struct changes, no `@callback` additions, no closed-enum extensions.**
- **No `mix.exs` deps changes.**
- **CHANGELOG entry — single rollup line per public artifact in this phase (5 lines total): one for the §31 freeze, one for each of the four case-study translations, one for the `ex_doc` layout + Getting Started, one for the version bump, one for the `mix hex.build` validation. Per `AGENT_DESIGN_SPEC.md` "one-line entry per public-API change."**

### Spec coverage

| Spec § | Phase 12 implements |
|--------|---------------------|
| §31 (testing and fake adapter — nine property-style scenarios) | 12.1 — frozen audit; `--only spec_31` enumerates the 12-row matrix at `test/allm/providers/fake_scenarios_test.exs`; meta-test asserts count == 12. |
| §32.1 (initial bundled adapters — OpenAI + Anthropic) | 12.2 — case-study translations exercise both adapters' surfaces *via Fake* (the unllmtd translation specifically constructs two engines differing only in `:adapter` to demonstrate provider-neutrality); 12.3 — `groups_for_modules:` Providers section names both. |
| §32.4 (what ALLM owns) | 12.2 — every "After" snippet in the four case studies maps into a test that runs end-to-end against the public surface. |
| §33 (v0.2 non-goals) | 12.2 — case-study translations must not silently exercise an out-of-scope feature (vision, prompt caching, embeddings, etc.). The Phase 11 vision-rejection invariant (`%ValidationError{reason: :vision_not_in_v0_2}`) is preserved by translations that include image content; if a case study calls for vision, the translation explicitly skips that snippet with a `# vision deferred to v0.3 per §33` comment. |
| §34 (summary) | 12.3 — the CHANGELOG rollup mirrors §34's framing (Engine = runtime, Session = persisted state, Thread = history, Event = streaming protocol, stream\* primitive, generate/step/chat reducers). |

### Prerequisites

- Phases 1–11 complete and merged. Phase 12 reads their landed surfaces; it does not add to them.
- `test/allm/providers/fake_scenarios_test.exs` exists and is currently passing under `mix test --only spec_31` (verified at `test/allm/providers/fake_scenarios_test.exs:1-100` on 2026-04-26 — 12 active rows).
- `mix.exs` has `package`, `docs`, and `description` configured (verified at `mix.exs:64-77` on 2026-04-26).
- `examples/` directory exists with provider-neutral runnable scripts (verified at `examples/README.md:1` on 2026-04-26 — Phase 11.4 unification landed).
- `ALLM.Providers.Fake` supports the script vocabulary the case-study translations require: `:text`, `:tool_call`, `:tool_call_delta`, `:finish`, `:error`, `:delay`, multi-script `scripts:` for multi-call flows (verified at spec §31 lines 1610–1650 on 2026-04-26 — full vocabulary supported per `lib/allm/providers/fake.ex`).

### Out of scope

- **Hex publish.** Decision #1. The bump-and-build is a dry-run; `mix hex.publish` is a maintainer step taken outside the phase. Reason: publish requires Hex auth, a tagged release commit, and an out-of-band sign-off this phase doesn't model.
- **`0.2.0-rc.1` staging.** Decision #1. The version bumps directly to `0.2.0` (not `0.2.0-rc.1`) because v0.2 has been validated by /review on every phase and the rc-tag would bottleneck downstream `{:allm, "~> 0.2"}` users.
- **Examples-translation tests against the real provider.** Out of scope. The runnable real-provider smoke is `examples/run_all.exs` (Phase 11.4); it stays where it is. The case-study translations under `test/examples/` are deterministic Fake-driven tests by design.
- **A `getting_started.md` extra doc.** Decision #3. The Getting Started snippet lives inside `README.md` so a hex-docs reader gets it on the landing page, not on a sibling extra. Adding a separate file would split the entry-point surface.
- **`mix.exs` deps changes.** No new deps. `ex_doc ~> 0.34` is already in `mix.exs:40` and supports `groups_for_modules:` since 0.27.
- **`steering/examples/` body rewrites.** The four case studies are inputs to Phase 12, not outputs. If a translation discovers a case study claiming a non-existent API, the case study is annotated with a "See `test/examples/<name>_test.exs` for the canonical translation" pointer — but the markdown body is not rewritten in this phase. **Carve-out:** the implementer MAY add a markdown `###`-level heading to a case study at the start of an "After" snippet that lacks one, solely so the corresponding `test/examples/*_test.exs` `describe` block can name a stable anchor instead of a brittle line range (see §12.2.1 cross-translation invariants). Heading additions are no-op semantic changes; body rewrites of any kind remain out of scope.
- **`AGENT_REVIEW_SPEC.md` itself.** Phase 12 invokes the spec; it does not edit it.
- **A v0.2 → v0.3 migration guide.** Out of scope. v0.3 doesn't exist yet; PROJECT_PHASING.md "What Comes After" enumerates the candidates but each is its own phase.
- **`ex_doc`'s nested-modules feature (`nest_modules_by_prefix:`).** Decision #4. `groups_for_modules:` is sufficient; `nest_modules_by_prefix:` would visually nest e.g. `ALLM.Error.*` under `ALLM.Error`, but the Errors group already does this semantically. Avoid double-grouping.
- **A "version policy" section in README.** Out of scope. Project's versioning policy (semver, breaking change discipline) is implicit and undocumented; an explicit policy is a v0.3 concern.

### Non-obvious decisions

1. **Bump `@version` to `"0.2.0"` directly — no `0.2.0-rc.1` staging step.** PROJECT_PHASING.md key decision (a) raises this. Chosen: direct bump to `0.2.0`. Rationale: (a) every phase has been validated by `/review` on the way in, including Phase 10's BLOCKING `examples/run_all.exs` against real OpenAI and Phase 11.4's BLOCKING dual-provider variant against both providers; the release candidate would be testing what the per-phase review already tests; (b) downstream consumers writing `{:allm, "~> 0.2"}` against a published `0.2.0-rc.1` would see Hex's pre-release-resolution behavior (rc versions are excluded from `~>` resolution by default), creating friction at zero benefit; (c) if a post-publish defect surfaces, `0.2.1` is the answer, not a yanked `0.2.0`. **Hex publish itself is NOT triggered by this phase.** The bump + `mix hex.build` dry-run validates the package; the actual `mix hex.publish` is an out-of-band maintainer action requiring Hex auth, a tagged commit, and explicit sign-off. The CHANGELOG rollup heading carries the date of the Phase 12 milestone commit, which is the same date the maintainer would publish if they choose to do so the same day; if publish is delayed, the heading still reads correctly because it's the design-locked date. `Docs target: CHANGELOG entry only.`

2. **§31 audit freezes at exactly 18 `test` blocks (decomposing 12 documented scenarios across 13 `describe` blocks); the count is enforced by a meta-test over `test`-block registration.** `test/allm/providers/fake_scenarios_test.exs:8-10` documents 12 active scenarios after Phase 8 and explicitly states "All §31 scenarios are now active." That file's 12 *scenarios* (the documented prose-table rows) live across 13 `describe` blocks containing 18 `test` blocks (verified 2026-04-26 via `grep -cE '^\s*test [~"]' test/allm/providers/fake_scenarios_test.exs == 18` and `grep -c '^\s*describe "' == 13` — note the wider `[~"]` character class is required to match both `test "..."` and `test ~s(...)` heredoc forms; a narrow `'^\s*test "'` pattern undercounts by missing the `~s(...)` form). The `test`-block count is what `mix test --only spec_31` reports as "N tests, 0 failures", so the freeze is over `test` blocks (18), not over scenarios (12). Phase 12.1 sets `@case_count 18` plus a `case_count/0` introspection function; a meta-test introspects ExUnit's registration via `__MODULE__.__info__(:functions)` filtered on `String.starts_with?(name_string, "test ")` and asserts the count equals `@case_count`. Verified idiom (Decision #12) — ExUnit registers each `test` block as a public 1-arity function whose name starts with `"test "`. Spec §31's nine prose-listed scenarios decompose to 12 documented scenarios because (a) "pure text streaming with and without `emit_text_deltas: false`" is two scenarios, (b) "single tool call with `mode: :auto` and `mode: :manual`" is two scenarios, (c) "parallel tool calls" exercises both the adapter-level scenario and the step/3 wrap (two scenarios); those 12 scenarios further split into 18 `test` blocks where a single scenario (e.g., parallel tool calls) carries multiple verification angles. The decomposition is documented in the file's table at `test/allm/providers/fake_scenarios_test.exs:11-25`. **Application-of-§3-rule-7 framing.** AGENT_DESIGN_SPEC §3 rule 7 specifies the `@case_count` + `case_count/0` + meta-test pattern for *injected-`describe/2`* conformance suites where a macro generates the cases at expand time. `fake_scenarios_test.exs` is a hand-written file with manually-authored `describe`/`test` blocks — there is no macro injection. Phase 12 applies the same discipline (loud failure on count drift) to a manually-authored matrix as a defensive extension; the introspection mechanism (`__info__(:functions)` at runtime) differs from a macro-injected suite (where the count is known at expand time) but the contract is identical. `Docs target: @moduledoc ALLM.Providers.FakeScenariosTest` (the freeze gate's how-it-works paragraph).

3. **README "Getting Started" lives inline in `README.md`, with a parallel iex-prompt-formatted doctest inside `lib/allm.ex`'s `@moduledoc`.** Rationale: hex-docs renders the `README.md` extra as a navigable extras page (`docs.main: "ALLM"` is the *module* main; the `extras:` list determines which markdown files render as sibling pages). A reader landing on hexdocs.pm/allm sees the `ALLM` moduledoc; a reader landing on the GitHub repo sees `README.md`. Both surfaces carry the Getting Started snippet but in different formats: README.md uses plain Elixir code blocks (better for copy-paste into a fresh `iex -S mix`); `ALLM`'s `@moduledoc` carries an `iex>`-prompt-prefixed doctest variant of the same flow (`iex> engine = ALLM.Engine.new(...)`, `iex> {:ok, %ALLM.ChatResult{...} = result} = ALLM.chat(engine, ...)`, etc.) so it runs under `mix test`'s doctest mechanism. The two snippets are parallel sources kept in sync by visual review, NOT a single-source-of-truth. Phase 12.3's implementation checklist includes an explicit "extract the README snippet, transcribe to iex-prompt format, place in `ALLM.@moduledoc`" step. ExUnit's `doctest ALLM` line in `test/allm_test.exs` (Phase 1) already runs the moduledoc doctests, so the iex variant is automatically validated by `mix test`. The README snippet is plain code (no `iex>` prefix) — readers expect README code to be copy-pasteable as-is. `Docs target: README.md + @moduledoc ALLM`.

4. **`groups_for_modules:` is the only `ex_doc` grouping mechanism used; `nest_modules_by_prefix:` is intentionally NOT added.** ExDoc supports both. `groups_for_modules:` partitions the sidebar into named sections; `nest_modules_by_prefix:` collapses sub-modules under a parent. Using both produces visually-redundant nesting (e.g., `ALLM.Error.AdapterError` would appear in the "Errors" group AND nested under "ALLM.Error"). Pick one. Chosen: `groups_for_modules:`. Reason: the architectural narrative is "facade → sessions → behaviours → providers → data → runtime → errors", which is a flat partitioning, not a hierarchy. Nesting would imply a composition relation (sub-modules belong to their parent) that the architecture doesn't have (`ALLM.Error.AdapterError` is not "owned by" `ALLM.Error` in any runtime sense — `ALLM.Error` is just the namespace prefix). `Docs target: @moduledoc ALLM` (top-of-file note explaining the group structure).

5. **The four case-study translations live under `test/examples/`, NOT under `examples/` at the repo root.** PROJECT_PHASING.md key decision (b) raises this. Chosen: `test/examples/`. Rationale: (a) the existing `examples/` directory is the runnable real-provider smoke set (Phase 10.5 + 11.4) — it's gated on real API keys and has a different audience (reviewers running `examples/run_all.exs` for the BLOCKING `/review` step); the case-study translations are deterministic, no-network, no-key tests that should run on every `mix test`; conflating the two would force every commit through real-provider invocations and would produce conflict between the two when CI runs. (b) Living under `test/examples/` makes them part of the regression suite — `mix test` catches a case-study drift the same way it catches any test failure. (c) The `test/` tree already excludes from the published Hex package per `mix.exs:71`, so the translations don't bloat the artifact. The case-study translations are TEST FIXTURES that prove the case-study claims; they are not user-facing example scripts. `Docs target: internal — no user-facing docs needed` (test files are self-describing via their `@moduledoc`).

6. **The four case-study translations are coverage-neutral but are still required to land at ≥ 90 % coverage on the new test file itself.** Per `AGENT_DESIGN_SPEC.md` rule "new code lands at ≥ 90 % line coverage" — the test files ARE code, and every test/helper function in them runs as part of `mix test`. The 90 % rule is therefore trivially satisfied (test files have no unreachable code). The phase explicitly states this so a future reviewer reading the coverage report doesn't read "test/examples/ at 100 %" as suspicious. Global coverage stays around the post-Phase-11 baseline (≥ 90 %) because the case-study translations don't exercise any previously-unexercised library code (every translated snippet is composed of public API already covered by the unit tests added in Phases 1–11). `Docs target: internal.`

7. **The CHANGELOG rollup is a single `## v0.2 — <release date>` heading, NOT a renumbering of existing entries.** Rationale: the per-phase entries (`Phase 1` through `Phase 11.4`) are git-grade history — they document what landed when, and `git blame`-style traceability against them depends on their stability. Renumbering or rewriting them would invalidate every PR description that linked to "the Phase 7 entry on 2026-04-25". The rollup is *additive*: prepended to the file, references the existing entries by phase number, and provides the elevator-pitch that "what is in v0.2" reading a 423-line per-phase log doesn't supply. The rollup body is 6–10 bullets covering: the layered architecture (Phase 1+2), stream-first execution + Fake (Phases 4–5), tool orchestration + manual mode + ask-user (Phases 6–7), sessions with serializability (Phase 8), telemetry/retry/capability cross-cutting (Phase 9), OpenAI + Anthropic adapters with structured output (Phases 10–11), provider-neutral runnable examples (Phase 11.4), and the §31 testing harness (Phase 4). The release date is the date of the Phase 12 milestone commit; the actual hex publish (out of scope per Decision #1) might occur on a later date — both dates are valid pieces of release-history. `Docs target: CHANGELOG entry only.`

8. **`mix hex.build` is run; `mix hex.publish` is NOT.** Per Decision #1. The Phase 12 verification step explicitly runs `mix hex.build` and confirms exit-status 0 + presence of `allm-0.2.0.tar` at the project root (Hex's documented output location — beside `mix.exs`, NOT under `_build/`). The `mix hex.publish` invocation is documented as an out-of-band maintainer step in `steering/reviews/PHASE_12_REVIEW.md` (the review artifact) but is NOT executed by the phase's checklist. Reason: publish is irreversible (a published version cannot be re-uploaded with different content; only `mix hex.retire` can mark it deprecated, and `mix hex.publish` against a yanked version still requires a version bump). Phase 12's job is to make publish *safe*, not to execute it. `Docs target: internal — no user-facing docs.`

9. **The case-study translations skip case-study snippets that exercise out-of-scope features.** Each translation walks the case study's "After" section and translates every snippet that exercises a v0.2-supported feature. Snippets that exercise vision (`steering/examples/amesury_example.md` line 124+ shows `complete_with_vision`-equivalent), prompt caching, embeddings, or any other §33 non-goal are SKIPPED with an in-line comment `# vision content — deferred to v0.3 per §33; case study line N`. The skip is documented as a `# skipped:` comment in the test file body, NOT as a `@tag :skip` (which would suggest "currently broken, will be re-enabled later" — that's not the meaning here). The case-study translation is therefore a *partial* translation: it covers every v0.2-supported snippet and is silent about §33 non-goals. `Docs target: @moduledoc` of each `test/examples/*_test.exs` (a "Coverage" paragraph naming which case-study sections are translated and which are deferred).

10. **The unllmtd translation is the load-bearing multi-provider proof.** Three of the four case studies (Amesbury, Garden, meal) are single-provider (OpenAI). Unllmtd is multi-provider (OpenAI + Anthropic) and exercises the `model_tier`/multi-engine pattern explicitly (`steering/examples/unllmtd_example.md:67`). The unllmtd translation constructs **two `ALLM.Providers.Fake`-backed engines** with different `adapter_opts:` — one labeled as "the Anthropic engine" and one as "the OpenAI engine" — to prove the cross-provider switching pattern works end-to-end against the public API surface. The translation does NOT actually invoke `ALLM.Providers.OpenAI` or `ALLM.Providers.Anthropic` (those are exercised by the recorded-fixture wire tests in `test/allm/providers/openai_wire_test.exs` and `anthropic_wire_test.exs`); instead, it proves that the *engine-construction shape* the unllmtd case study advocates is supported by the public API. `Docs target: @moduledoc ALLM.Test.Examples.Unllmtd` (a "Why two Fake engines, not real OpenAI + Anthropic" paragraph).

11. **The `extras:` list grows from `["README.md"]` to `["README.md", "CHANGELOG.md"]`.** Both render as navigable pages in hex-docs. The CHANGELOG rendering gives readers a single place to see "what landed in v0.2" without leaving hex-docs. Adding `LICENSE` (which is included in the package per `mix.exs:71`) as an extra is intentionally NOT done — LICENSE is a legal artifact, not narrative documentation, and rendering it as a sibling extra implies it's content readers should browse. `Docs target: README.md + CHANGELOG.md` (the pages themselves).

12. **The §31 meta-test idiom uses `__MODULE__.__info__(:functions)` to enumerate registered test cases.** ExUnit registers each `test` block under `:"test " <> "<describe> <name>"`; the count of those functions matches the active test count (verified empirically against `ExUnit.Case` source: `lib/ex_unit/lib/ex_unit/case.ex` defines `register_test/4` which `def`s a function per test). The meta-test reads `length(for {name, 1} <- __MODULE__.__info__(:functions), Atom.to_string(name) =~ ~r/^test /, do: name)` and asserts it equals `@case_count`. Verified-in-IEx-on 2026-04-26 idiom — running this expression in `iex -S mix` against `ALLM.Providers.FakeScenariosTest` returns exactly the `@case_count` integer. `Docs target: @moduledoc ALLM.Providers.FakeScenariosTest` (the "How the count freeze works" paragraph).

## Behaviour & Type Contracts

Phase 12 introduces no new behaviours, no struct changes, no `@callback` additions, no public-function signatures, and no closed-enum extensions. The only contractual addition is the §31 meta-test invariant frozen as a module-attribute-plus-introspection pair on `ALLM.Providers.FakeScenariosTest`. Below: the meta-test contract, the `ex_doc` configuration contract, and the `mix.exs` package-files-list contract — those are what Phase 12 is contractually binding the project to.

### `ALLM.Providers.FakeScenariosTest` meta-test (test/) — Layer C consumer

```elixir
# test/allm/providers/fake_scenarios_test.exs (MODIFY: header docstring + new attribute + meta-test)
defmodule ALLM.Providers.FakeScenariosTest do
  @moduledoc """
  Spec §31 property-style scenarios — v0.2 release-polish freeze (Phase 12).

  ...12-row matrix table preserved verbatim from Phase 8 freeze...

  ## Count freeze

  `@case_count 18` plus the meta-test below freeze the `test`-block count at 18
  (decomposing the 12 documented §31 scenarios across 13 `describe` blocks). A
  v0.3 contributor adding a `test` block will fail the meta-test until they
  bump `@case_count`, forcing acknowledgment of the audit gate.
  """

  use ExUnit.Case, async: true

  @moduletag :spec_31

  # 18 §31 test-blocks across 13 describe blocks, decomposing the 12
  # documented scenarios. Bump together with the audit-gate count below
  # whenever the file gains or loses a `test` block.
  @case_count 18

  # Tests in the §31 audit-gate describe block (currently just the
  # count-equality meta-test below). Subtracted from the introspection
  # count so the meta-test's own registration doesn't inflate the total.
  @audit_gate_test_count 1

  @spec case_count() :: pos_integer()
  def case_count, do: @case_count

  # ...existing 13 describe blocks / 18 test blocks unchanged...

  describe "§31 audit gate (Phase 12 meta-test)" do
    test "registered test count equals @case_count" do
      registered =
        for {name, 1} <- __MODULE__.__info__(:functions),
            String.starts_with?(Atom.to_string(name), "test "),
            do: name

      assert length(registered) - @audit_gate_test_count == @case_count
    end
  end
end
```

**Invariants:**
- Adding a §31 `test` block requires bumping `@case_count`; either change alone fails the meta-test.
- Adding a *second* audit-gate test (alongside the count-equality meta-test) requires bumping `@audit_gate_test_count` in lock-step. The two attributes encode the rule mechanically — no comment-archaeology needed when the numbers move.
- ExUnit registers each `test` block as a 1-arity public function named `"test " <> describe_name <> " " <> test_name`; the introspection filter is therefore exhaustive over the file's `test` blocks (verified 2026-04-26).

### `mix.exs` `docs/0` (MODIFY)

```elixir
defp docs do
  [
    main: "ALLM",
    source_ref: "v#{@version}",
    extras: ["README.md", "CHANGELOG.md"],
    groups_for_modules: [
      Facade: [ALLM],
      Sessions: [ALLM.Session, ALLM.Session.StreamReducer],
      Behaviours: [
        ALLM.Adapter,
        ALLM.StreamAdapter,
        ALLM.ToolExecutor,
        ALLM.ToolResultEncoder
      ],
      Providers: [
        ALLM.Providers.OpenAI,
        ALLM.Providers.Anthropic,
        ALLM.Providers.Fake,
        ALLM.Providers.Fake.Script,
        ALLM.Providers.Support.SSE
      ],
      Defaults: [
        ALLM.ToolExecutor.Default,
        ALLM.ToolResultEncoder.JSON
      ],
      "Data types": [
        ALLM.Message,
        ALLM.Request,
        ALLM.Response,
        ALLM.Thread,
        ALLM.StepResult,
        ALLM.ChatResult,
        ALLM.Event,
        ALLM.Usage,
        ALLM.Tool,
        ALLM.ToolCall,
        ALLM.ModelRef
      ],
      Runtime: [
        ALLM.Engine,
        ALLM.Keys,
        ALLM.Validate,
        ALLM.Capability,
        ALLM.Retry,
        ALLM.Telemetry,
        ALLM.StreamCollector,
        ALLM.Serializer
      ],
      Internals: [
        ALLM.Chat,
        ALLM.Runner,
        ALLM.StreamRunner,
        ALLM.ToolRunner
      ],
      Errors: [
        ALLM.Error.AdapterError,
        ALLM.Error.EngineError,
        ALLM.Error.SessionError,
        ALLM.Error.StreamError,
        ALLM.Error.ToolError,
        ALLM.Error.ValidationError
      ]
    ]
  ]
end
```

**Invariants:**
- Every public module under `lib/` (i.e., every module NOT carrying `@moduledoc false`) appears in exactly one group. Modules currently marked `@moduledoc false` and intentionally excluded from the index: `ALLM.Application`, `ALLM.Chat.LoopState`, `ALLM.Keys.Dotenv`, `ALLM.Keys.Store` (verified 2026-04-26). Non-`@moduledoc false` modules NOT covered by the proposed groups must either be added to a group or marked `@moduledoc false` before `mix docs` runs.
- The `Internals` group covers Layer-C dispatch and orchestration runners (`ALLM.Chat`, `ALLM.Runner`, `ALLM.StreamRunner`, `ALLM.ToolRunner`) — these are public modules with public `@doc`'d functions consumed by the `ALLM` facade, but they are not entry points users construct directly. Grouping them under "Internals" surfaces them in hex-docs (so a user debugging a stack trace can read the moduledoc) without front-loading them as entry points.
- The `Defaults` group covers the two shipped behaviour-default implementations (`ALLM.ToolExecutor.Default`, `ALLM.ToolResultEncoder.JSON`) — placed below `Behaviours` so a reader who has just read the behaviour callback contracts immediately sees the canonical default impls.
- The order of groups in the list is the order the sidebar renders them. Order was chosen for narrative entry-point flow (Decision #4).

### `mix.exs` `package/0` (UNCHANGED — verified)

```elixir
defp package do
  [
    licenses: ["MIT"],
    links: %{"GitHub" => @source_url},
    files: ~w(lib mix.exs README.md LICENSE .formatter.exs)
  ]
end
```

**Invariants:**
- `files:` whitelist is intentionally minimal. `examples/`, `test/`, `scripts/`, `steering/`, `conformance/` are NOT included — verified by sub-phase 12.4.2's `mix hex.build` dry-run output, which lists every file in the artifact and the audit confirms none of those directories appear.
- `description:` is set at `mix.exs:62` (verified 2026-04-26).
- `licenses: ["MIT"]` matches the actual `LICENSE` file (verified — `LICENSE` exists at repo root).

### `mix.exs` `@version` (MODIFY)

```elixir
@version "0.2.0"   # was "0.0.1" pre-Phase 12
```

**Invariants:**
- The version is a single source of truth used by `version: @version` and `source_ref: "v#{@version}"`. No other file references the version literal (verified `grep -r '"0\.0\.1"' /workspaces/ALLM` returns only `mix.exs:4` on 2026-04-26).
- `0.2.0` follows semver. The previous public version was `0.0.1` (the scaffolding placeholder). The jump from `0.0.1` to `0.2.0` (skipping `0.1.x`) reflects that v0.1 was never released; v0.2 is the first published version.

### Atom vocabulary additions

**None.** Phase 12 introduces no new atoms in any closed enum. The case-study translations consume existing atoms (`:stop`, `:tool_calls`, `:length`, `:awaiting_user`, `:awaiting_tools`, `:completed`, `:no_scripted_response`, etc.) — all from prior-phase enums verified at their committed source on 2026-04-26.

### Idiomatic Elixir requirements

- **`__MODULE__.__info__(:functions)` for the §31 meta-test count.** The idiom returns a list of `{atom, arity}` tuples for every public function in the compiled module. ExUnit registers each `test` block as a function with name `:"test #{describe} #{name}"`, so `String.starts_with?(name_string, "test ")` filters down to the registered tests. Verified-in-IEx 2026-04-26 — running `iex -S mix` then `ALLM.Providers.FakeScenariosTest.__info__(:functions) |> Enum.count(&match?({n, 1} when is_atom(n), &1))` returns the expected count.
- **`Code.ensure_compiled/1` is NOT used.** The `groups_for_modules:` list uses module-name atoms directly; ExDoc resolves them at `mix docs` time without requiring runtime compilation. Verified via `ex_doc ~> 0.34`'s documented behavior.
- **`@moduletag :spec_31`** on the FakeScenariosTest module — the existing tag stays unchanged; Phase 12 adds the meta-test as a sibling within the same module (so it inherits the same tag and runs under `--only spec_31`).
- **No `Mix.env()` checks in `lib/`.** Phase 12 doesn't touch `lib/` at all, so this is trivially preserved.

## Module Tree

```
test/examples/
├── test_helper.exs                        (NEW — shared fake-script fixtures, ~80 LOC)
├── amesbury_test.exs                      (NEW — translation of steering/examples/amesury_example.md)
├── garden_test.exs                        (NEW — translation of steering/examples/garden_example.md)
├── meal_test.exs                          (NEW — translation of steering/examples/meal_example.md)
└── unllmtd_test.exs                       (NEW — translation of steering/examples/unllmtd_example.md)

test/
└── groups_for_modules_audit_test.exs      (NEW — every lib/ module ∈ exactly one ex_doc group)

test/allm/providers/
└── fake_scenarios_test.exs                (MODIFY — header docstring rewrite, @case_count + @audit_gate_test_count attributes, meta-test added)

mix.exs                                    (MODIFY — @version bump, docs/0 groups_for_modules + extras)
README.md                                  (MODIFY — Getting Started rewrite, drop scaffolding label)
CHANGELOG.md                               (MODIFY — prepend v0.2 rollup heading)
.gitignore                                 (MODIFY — add allm-*.tar)
lib/allm.ex                                (MODIFY — @moduledoc gains an iex-prompt-formatted Getting Started doctest, parallel to README; runs under `doctest ALLM` in test/allm_test.exs)

steering/reviews/
└── PHASE_12_REVIEW.md                     (NEW — final /review pass artifact)
```

**The only `lib/` edit is one `@moduledoc` doctest addition in `lib/allm.ex`** (Decision #3 — the iex-prompt-formatted Getting Started doctest, parallel to the README snippet). No new modules; no behavioural code changes; no `@callback`/struct/enum changes. The diff is overwhelmingly doc + config + test additions; the moduledoc doctest is the sole exception and carries zero runtime semantics.

## Phases

### Phase 12.1: §31 Audit Freeze (no layer)

**Goal:** Freeze the `mix test --only spec_31` enumeration at 12 rows; add the meta-test gate; rewrite the file's header docstring to read "v0.2 release-polish freeze (Phase 12)".

**Spec sections:** §31 (testing and fake adapter — the nine property-style scenarios).

#### 12.1.1 Test Plan

`test/allm/providers/fake_scenarios_test.exs` (MODIFY):

- Existing 18 `describe/test` blocks (decomposing the 12 documented §31 scenarios) pass unchanged under `mix test --only spec_31`.
- New describe `"§31 audit gate (Phase 12 meta-test)"` with one test:
  - `test "registered test count equals @case_count"` — asserts `length(filter(__info__(:functions), starts_with("test "))) - @audit_gate_test_count == 18`.
  - The `@audit_gate_test_count` (currently `1`) accounts for the meta-test itself being a registered test.
- Adding any `describe`/`test` to the file (without bumping `@case_count`) MUST fail the meta-test — verified empirically by adding a stub `describe "drift detection" do test "…" do assert true end end`, running `mix test`, and observing the meta-test fails with a message of the form `Expected 18, got 19`. After verification, the stub is reverted.
- Removing any `describe`/`test` from the file (without lowering `@case_count`) MUST fail the meta-test — verified by commenting out one case (e.g., `§31 scenario: max_turns cap`), running `mix test`, observing failure, then reverting.

#### 12.1.2 Implementation Checklist

- [ ] Touch zero `lib/` files (Phase 12.1, 12.2, 12.4 only — Phase 12.3 makes a single `@moduledoc` doctest addition in `lib/allm.ex` per Decision #3).
- [ ] Edit `test/allm/providers/fake_scenarios_test.exs:1-25`:
  - Replace "Active coverage after Phase 8: 12 scenarios..." with "Active coverage at v0.2 release-polish freeze: 12 scenarios. Frozen at Phase 12; the meta-test in `describe \"§31 audit gate (Phase 12 meta-test)\"` enforces the count."
  - Add `@case_count 18` and `@audit_gate_test_count 1` after the existing `@moduletag :spec_31` line. The first encodes the 18 §31 `test` blocks (decomposing 12 documented scenarios across 13 `describe` blocks); the second encodes the count of audit-gate tests to subtract from the introspection count (currently 1: the count-equality meta-test). Both attributes are bumped in lock-step when the file's structure changes.
  - Add `@spec case_count() :: pos_integer()` and `def case_count, do: @case_count` immediately after the attribute (introspection helper).
  - Append a new `describe "§31 audit gate (Phase 12 meta-test)" do ... end` block at the end of the file with the single meta-test described in §12.1.1.
- [ ] Verify no other file references `case_count/0` (it's introspection-only).

#### 12.1.3 Verification

```bash
mix test --only spec_31                                                    # 18 §31 test-blocks + 1 meta-test = 19 tests, 0 failures
mix test test/allm/providers/fake_scenarios_test.exs                       # full file green
mix credo --strict test/allm/providers/fake_scenarios_test.exs
```

The output of `mix test --only spec_31` must read `19 tests, 0 failures` (18 §31 test blocks + 1 audit-gate meta-test).

---

### Phase 12.2: Case-Study Translations (Layer C — consumers)

**Goal:** Translate the four `steering/examples/` case studies into deterministic `mix test`-covered integration tests under `test/examples/`, each driven against `ALLM.Providers.Fake`.

**Spec sections:** §31 (Fake), §32.1 (initial bundled adapters — the case-study translations exercise both adapters' surfaces by name), §32.4 (what ALLM owns), §33 (v0.2 non-goals — translations skip out-of-scope snippets per Decision #9).

#### 12.2.1 Test Plan

**`test/examples/test_helper.exs` (NEW — shared module):**

Defines `ALLM.Test.ExampleFixtures` with reusable fake-script constructors:

- `text_response(text)` — `[{:text, text}, {:finish, :stop}]`
- `tool_call_response(name, args)` — `[{:tool_call, id: "tc_1", name: name, arguments: args}, {:finish, :tool_calls}]`
- `tool_round_trip(name, args, follow_up_text)` — `scripts: [tool_call_response, text_response]`
- `manual_halt(name, args)` — single-script tool call (caller halts manually)
- `ask_user(question)` — `[{:tool_call, id: "tc_1", name: "ask_user", arguments: %{question: question}}, {:finish, :tool_calls}]` (case studies model ask-user as a tool)
- `recipe_text/0` — a fixture map for the meal translation
- `weather_tool/0` — an `ALLM.Tool` with a deterministic handler

Imported via `import ALLM.Test.ExampleFixtures` in each `test/examples/*_test.exs`. Approx. 80 LOC.

**`test/examples/amesbury_test.exs` (NEW):**

Walks `steering/examples/amesury_example.md`'s "After" snippets in order. Each `describe` block names the case-study line range it translates.

- `describe "amesury_example.md:62-90 — Engine + plain generate"` — constructs an Anthropic-like Fake engine, runs `ALLM.generate/3` with a plain prompt, asserts `Response.output_text == "..."`.
- `describe "amesury_example.md:99-120 — structured output"` — `ALLM.generate/3` with `response_format: ALLM.json_schema(...)`, asserts the response decodes via `Jason.decode!/1` to a map matching the schema.
- `describe "amesury_example.md:185-260 — tool loop with two-pass structured output"` — multi-script Fake (one tool call, then a final structured response), `Engine.put_tools/2` + `Engine.put_context/3`, two explicit `ALLM.chat/3` calls, asserts the second response carries the structured shape. Decision #9 — the case study's vision/`complete_with_vision/4` snippet at line 124 is skipped with an inline `# vision deferred to v0.3 per §33` comment.
- `describe "amesury_example.md:262-280 — manual mode + Session"` — `ALLM.Session.start/3` with `mode: :manual`, halts on tool calls, `Session.submit_tool_result/3`, `Session.continue/3`, asserts final `Session.status == :completed`.

Approx. 6 tests, ~150 LOC.

**`test/examples/garden_test.exs` (NEW):**

- `describe "garden_example.md:62-100 — Engine construction"` — Fake-backed engine with `adapter_opts: [script: ...]`, asserts construction round-trip (no API call yet).
- `describe "garden_example.md:175-220 — generate with structured output"` — `ALLM.generate/3` with `response_format`, asserts `output_text` JSON-decodes to a seed-packet map.
- `describe "garden_example.md:380-420 — Fake adapter for tests"` — exercises `ALLM.Providers.Fake` directly in the same shape Garden's test code would use.
- `describe "garden_example.md:435-490 — streaming + tool"` — `ALLM.stream_generate/3`, asserts event sequence; then `ALLM.chat/3` with one tool, asserts the chat-result thread accumulated.

Approx. 4 tests, ~120 LOC.

**`test/examples/meal_test.exs` (NEW):**

- `describe "meal_example.md:99-145 — single-turn structured generate"` — recipe-from-prompt, asserts JSON-decodable `output_text` shape.
- `describe "meal_example.md:155-195 — tool-using parse_from_url flow"` — `ALLM.chat/3` with one fetch tool, asserts the chat-result reaches `:completed` and the final response carries the recipe JSON.
- `describe "meal_example.md:200-260 — Session-backed recipe modification"` — `Session.start/3` + `Session.reply/4` + ETF round-trip mid-flow, asserts the deserialized session continues and the final thread carries both turns.
- Out-of-scope snippets (any vision content) skipped per Decision #9.

Approx. 5 tests, ~140 LOC.

**`test/examples/unllmtd_test.exs` (NEW):**

- `describe "unllmtd_example.md:140-180 — multi-provider engine selection"` — constructs two Fake engines labeled "openai" and "anthropic" (differing only in `adapter_opts:` script vocabulary), asserts both produce equivalent `Response.output_text` shape from the same request. Decision #10 — proves the multi-provider engine-construction pattern; does NOT invoke real OpenAI/Anthropic adapters.
- `describe "unllmtd_example.md:155-180 — auto-mode multi-turn loop"` — `ALLM.chat/3` `mode: :auto` with `max_turns: 5`, multi-script Fake (tool call → text), asserts loop terminates with `halted_reason: :completed`.
- `describe "unllmtd_example.md:185-220 — manual-mode halt + tool result submission"` — `ALLM.Session.start/3` `mode: :manual`, halts on tool calls, `Session.submit_tool_result/3`, `Session.continue/3`, asserts `Session.status` transitions through `:awaiting_tools → :completed`.
- `describe "unllmtd_example.md:225-260 — ask-user halt + follow-up turn"` — `Session.start/3`, halts on `{:ask_user, _, _}` (modeled as the synthetic `ask_user` tool — see Decision #9), `Session.reply/4` with the user's response, asserts `Session.status` transitions through `:awaiting_user → :completed`.

Approx. 6 tests, ~180 LOC.

**Cross-translation invariants:**
- Every test's first `setup` block constructs a Fake engine with `adapter: ALLM.Providers.Fake` plus `adapter_opts:` — never `ALLM.Providers.OpenAI` or `ALLM.Providers.Anthropic`. Decision #10.
- Every translation imports `ALLM.Test.ExampleFixtures` for shared script construction — no per-file fixture duplication.
- Every `describe` block's name explicitly references the case-study **section heading** (e.g., `"amesury_example.md / Tool loop with two-pass structured output"`) — NOT a line range. Section headings survive markdown edits; line ranges drift the moment the case study gains a paragraph. The line ranges in §12.2.1's per-test enumeration above are *approximate at design time* (verified against the case-study files on 2026-04-26); the implementer re-anchors each `describe` name to the closest matching markdown heading at translation time. If the case study lacks a heading at the target snippet, the implementer adds one in a minimal markdown edit before translating (this is the only allowed `steering/examples/` edit in this phase — see "Out of scope" — and it's a heading addition only, never a body rewrite).

#### 12.2.2 Implementation Checklist

- [ ] Touch zero `lib/` files (Phase 12.1, 12.2, 12.4 only — Phase 12.3 makes a single `@moduledoc` doctest addition in `lib/allm.ex` per Decision #3).
- [ ] Create `test/examples/test_helper.exs` with `ALLM.Test.ExampleFixtures` per §12.2.1.
- [ ] Create the four `test/examples/<name>_test.exs` files per §12.2.1, each with `@moduledoc` documenting (a) which case-study sections are translated and (b) which sections are skipped per Decision #9.
- [ ] For each translation, walk the corresponding `steering/examples/<name>_example.md` "After" section in order; for every code snippet, either (a) write a `describe`/`test` block translating it, or (b) add an inline `# skipped: <reason> per §33` comment naming the line range.
- [ ] Verify each translation file's `@moduledoc` "Coverage" paragraph lists every "After" section by line range (translated or skipped).
- [ ] Run each translation file in isolation: `mix test test/examples/<name>_test.exs` — must be green.
- [ ] Run the full `test/examples/` suite: `mix test test/examples/` — must be green.

#### 12.2.3 Verification

```bash
mix test test/examples/                                             # full case-study suite green
mix test test/examples/amesbury_test.exs                            # individual files green
mix test test/examples/garden_test.exs
mix test test/examples/meal_test.exs
mix test test/examples/unllmtd_test.exs
mix test                                                            # full suite still green
mix credo --strict test/examples/
mix format --check-formatted test/examples/
```

The full `mix test` run after this sub-phase reads roughly `≈ 1424 tests, 0 failures` (1401 baseline from Phase 11 CHANGELOG + 12.1's 1 audit-gate meta-test + 12.2's ~21 case-study tests + ~1 helper-related sanity test = 1424; exact count depends on case-study translation cardinality which the implementer finalizes during 12.2).

---

### Phase 12.3: Public Documentation Polish (no layer)

**Goal:** Rewrite `README.md` with a copy-paste-runnable Getting Started; configure `ex_doc` `groups_for_modules` per §Behaviour & Type Contracts; add the v0.2 rollup heading to `CHANGELOG.md`.

**Spec sections:** §32.4 (what ALLM owns — the README narrative), §34 (summary — the rollup mirrors §34's framing).

#### 12.3.1 Test Plan

- `mix docs` (after the `groups_for_modules:` change) produces an `doc/index.html` that opens with `ALLM`'s moduledoc; the sidebar lists modules in the named groups in the order: Facade, Sessions, Behaviours, Providers, Data types, Runtime, Errors. Verified by reading `doc/index.html` after `mix docs` — the `<nav>` element's `<li class="modules-list-heading">` headings appear in that order.
- Every module under `lib/` appears in exactly one group. Verified by the audit script in §12.3.2 step 3 (a one-liner that reads `mix.exs`'s `groups_for_modules:`, dedupes the values, and asserts the dedup count equals the count of files under `lib/` returning `defmodule`).
- The Getting Started snippet in `README.md` runs as a doctest in `iex -S mix` against a fresh checkout. Verified by extracting the snippet, evaluating it in `Code.eval_string/1`, and asserting `text == "Hello, ALLM!"`.
- `mix docs` exit-status 0; `mix docs` writes `doc/CHANGELOG.html` (extras list expanded).
- `CHANGELOG.md` rendering test: open `doc/CHANGELOG.html` in a browser and confirm the v0.2 rollup heading is the first H2 and the existing per-phase entries follow unchanged.

#### 12.3.2 Implementation Checklist

- [ ] Touch zero `lib/` files (Phase 12.1, 12.2, 12.4 only — Phase 12.3 makes a single `@moduledoc` doctest addition in `lib/allm.ex` per Decision #3).
- [ ] Rewrite `README.md`:
  - Drop the "Status: Pre-release scaffolding" paragraph.
  - Keep the four-layer summary verbatim.
  - Add a `## Getting Started` section with the 15-line `chat/3`-against-Fake snippet from §Layer demonstration.
  - Add a `## Real Providers` section pointing to `ALLM.Providers.OpenAI` and `ALLM.Providers.Anthropic` plus a one-line link to `examples/README.md` for the runnable smoke set.
  - Keep `## License` verbatim.
- [ ] Edit `mix.exs:74-78` (the `docs/0` body):
  - Widen `extras: ["README.md"]` → `extras: ["README.md", "CHANGELOG.md"]`.
  - Add `groups_for_modules: [...]` per §Behaviour & Type Contracts.
- [ ] Run an audit test (added as `test/groups_for_modules_audit_test.exs`, NEW — preferred over a shell one-liner because `Mix.Project.config()` requires Mix to be loaded, which `elixir -e` does not provide and `mix run --no-start -e` makes brittle to quote — a test file always runs under Mix). The test reads `Mix.Project.config()[:docs][:groups_for_modules]`, flattens every group's module list, computes the symmetric difference against the set of public (non-`@moduledoc false`) modules under `lib/`, and asserts the difference is empty. Public-module discovery: walk `lib/` for `.ex` files, parse out `defmodule X do` headers, exclude any whose module body contains `@moduledoc false`. The test is a one-shot regression — when it fires, a `lib/` module was added without grouping (or a group references a non-existent module), and the test message names the offending modules. Approx. 40 LOC.
- [ ] Prepend `## v0.2 — <YYYY-MM-DD>` heading to `CHANGELOG.md` with 6–10 bullets summarizing the v0.2 delta per §Overview obligation 6. Existing entries below the heading are preserved verbatim (no edits).
- [ ] Run `mix docs`; open `doc/index.html` and confirm the sidebar group order; open `doc/CHANGELOG.html` and confirm the rollup is the first H2.
- [ ] Extract the README Getting Started snippet, run it in `iex -S mix`, confirm `text == "Hello, ALLM!"`.

#### 12.3.3 Verification

```bash
mix docs                                                            # exit 0; writes doc/
mix format --check-formatted                                        # README.md and CHANGELOG.md format-clean
mix test                                                            # full suite still green (README iex doctest + audit test pass)
mix test test/groups_for_modules_audit_test.exs                     # standalone — zero diff against lib/ defmodule list
```

The `doc/index.html` sidebar must show the seven groups in the documented order. The `doc/CHANGELOG.html` page must lead with the `## v0.2 — <date>` rollup.

---

### Phase 12.4: Release Polish (no layer)

**Goal:** Bump `@version` to `"0.2.0"`; verify `mix hex.build` dry-run; audit the package files list; record the final `/review` pass.

**Spec sections:** §32.1 (initial bundled adapters — the artifact ships both); §34 (summary).

#### 12.4.1 Test Plan

- `mix.exs:4` reads `@version "0.2.0"` (was `"0.0.1"`).
- `grep -r '"0\.0\.1"' /workspaces/ALLM` returns no matches outside `_build/` and `deps/`.
- `mix hex.build` exits 0 and writes `allm-0.2.0.tar` at the project root (Hex's documented behavior — the tarball lands beside `mix.exs`, NOT under `_build/`). The artifact contains `lib/`, `mix.exs`, `README.md`, `LICENSE`, `.formatter.exs` and **nothing else** (verified via `tar tf allm-0.2.0.tar` — no `examples/`, `test/`, `scripts/`, `steering/`, `conformance/` paths).
- `mix hex.publish` is **NOT** run.
- `steering/reviews/PHASE_12_REVIEW.md` exists and carries the `/review` artifact.

#### 12.4.2 Implementation Checklist

- [ ] Touch zero `lib/` files (Phase 12.1, 12.2, 12.4 only — Phase 12.3 makes a single `@moduledoc` doctest addition in `lib/allm.ex` per Decision #3).
- [ ] Edit `mix.exs:4`: `@version "0.0.1"` → `@version "0.2.0"`.
- [ ] Run `grep -rn '"0\.0\.1"' --include='*.ex*' lib/ test/ mix.exs` and confirm zero matches (the only place the string lives is `mix.exs:4`, which is now `"0.2.0"`).
- [ ] Run `mix deps.get && mix hex.build` and confirm:
  - Exit code 0.
  - Artifact at the project root: `allm-0.2.0.tar` (Hex writes the tarball beside `mix.exs`).
  - `tar tf allm-0.2.0.tar | sort` lists exactly the files under the `package.files` whitelist (`lib/...`, `mix.exs`, `README.md`, `LICENSE`, `.formatter.exs`); no `test/`, `examples/`, `scripts/`, `steering/`, `conformance/`.
  - Add `allm-*.tar` to `.gitignore` if not already covered, so the build artifact doesn't accidentally land in commits.
- [ ] Run a final `/review` pass per `AGENT_REVIEW_SPEC.md`. Capture the artifact under `steering/reviews/PHASE_12_REVIEW.md`. The artifact must include a "Findings" section; if any Finding is High or Medium severity, fix it in-phase and re-run `/review`. Low-severity Findings are documented but may be deferred to v0.3 with an explicit pointer.
- [ ] Confirm `mix test`, `mix credo --strict`, `mix dialyzer`, `mix format --check-formatted` all green after every change.
- [ ] DO NOT run `mix hex.publish`.

#### 12.4.3 Verification

```bash
grep -n '@version' mix.exs                                          # @version "0.2.0"
mix deps.get
mix hex.build                                                       # exit 0; writes allm-0.2.0.tar at the project root
tar tf allm-0.2.0.tar | sort                                        # whitelist match; no test/, examples/, etc.
mix test                                                            # full suite green at 0.2.0
mix credo --strict
mix dialyzer
mix format --check-formatted
mix docs                                                            # generated docs at v0.2.0
```

The phase ends with `steering/reviews/PHASE_12_REVIEW.md` committed; the package artifact `allm-0.2.0.tar` is **not** committed (covered by the `.gitignore` `allm-*.tar` entry added in 12.4.2).

---

## Cross-Phase Test Plan

### Unit / integration tests

| Suite | What it covers | Phase introducing it |
|-------|----------------|----------------------|
| `mix test --only spec_31` | 18 §31 test-blocks + 1 audit-gate meta-test (count freeze) | 12.1 |
| `mix test test/examples/` | 4 case-study translations × ~5 tests each = ~21 tests | 12.2 |
| `mix test test/examples/amesbury_test.exs` | Translation of `steering/examples/amesury_example.md` "After" sections | 12.2 |
| `mix test test/examples/garden_test.exs` | Translation of `steering/examples/garden_example.md` | 12.2 |
| `mix test test/examples/meal_test.exs` | Translation of `steering/examples/meal_example.md` | 12.2 |
| `mix test test/examples/unllmtd_test.exs` | Translation of `steering/examples/unllmtd_example.md` (multi-provider proof) | 12.2 |
| `mix test` (full) | Full regression including 12.1 + 12.2 additions | 12.1, 12.2 |

### Doctests

- The README Getting Started snippet is implemented as a doctest inside `ALLM`'s `@moduledoc` (a 15-line example block ending with `# => "Hello, ALLM!"`). The doctest runs under `mix test` and is therefore self-validating; if the README's snippet drifts from the doctest, `mix format --check-formatted` doesn't catch it but `mix test` does. Per AGENT_DESIGN_SPEC §6 "Doctests are tests" — keeping the README and the doctest in sync is a single-source-of-truth invariant.

### Conformance suites

- **None added.** Phase 12 introduces no new behaviours.

### Property tests

- **None added.** Phase 12 introduces no new closed unions.

### Serializability tests

- **None added.** No Layer A struct changes.

### Stream-equivalence tests

- **None added.** No new streaming functions.

### Stream-equivalence relaxation budget

| Relaxation | Justification | Risk |
|------------|---------------|------|
| (no rows) | Phase 12 does not introduce or modify any non-streaming-≡-streaming property test. | n/a |

### Coverage

- Global ≥ 80 % preserved (Phase 11 baseline).
- New code (the four `test/examples/*.exs` files + the `test_helper.exs` shared module + the §31 meta-test) at ≥ 90 %. Trivially satisfied — test files have no unreachable code.

## Error Contract

**No new error paths.** Phase 12 introduces no new public functions, no new fallible operations, no new error reasons. The case-study translations consume existing error contracts (e.g., asserting a `mode: :manual` flow halts with `halted_reason: :manual_tool_calls`, asserting a Session round-trip preserves `Session.status`, asserting a `max_turns` cap fires `halted_reason: :max_turns`) — every reason atom asserted against is already in a closed enum committed in Phases 1–11.

## Streaming & Backpressure

**Out of scope for this phase.** Phase 12 does not modify any streaming code path. The case-study translations exercise `ALLM.stream_generate/3` (Garden translation) but only at the user-API level — they consume the public stream as an `Enumerable.t()` and assert event-sequence shapes, never reaching into Finch internals or `Stream.resource/3` cleanup mechanics. Cancellation correctness is tested in Phase 4 (consumer-cancel scenario in `fake_scenarios_test.exs`); Phase 12 reuses but does not extend that coverage.

## Definition of Done

- [ ] All 4 sub-phases marked `Completed`.
- [ ] `mix test --only spec_31` reports 19 tests (18 §31 test-blocks + 1 audit-gate meta-test), 0 failures.
- [ ] `mix test test/examples/` reports ~21 tests, 0 failures.
- [ ] `mix test` (full) reports ≈ 1424 tests (exact count finalized during 12.2), 0 failures, ≥ 80 % global coverage, ≥ 90 % on new code.
- [ ] `mix credo --strict` zero issues on changed files.
- [ ] `mix dialyzer` zero new warnings (vs. Phase 11 PLT).
- [ ] `mix format --check-formatted` passes.
- [ ] `mix docs` exit 0; `doc/index.html` sidebar shows the seven groups in documented order; `doc/CHANGELOG.html` leads with the v0.2 rollup; the README Getting Started doctest renders.
- [ ] `mix.exs:4` reads `@version "0.2.0"`; `grep -r '"0\.0\.1"'` outside `_build/`/`deps/` returns zero matches.
- [ ] `mix hex.build` exit 0; artifact `allm-0.2.0.tar` at the project root; `tar tf allm-0.2.0.tar` lists only `lib/...`, `mix.exs`, `README.md`, `LICENSE`, `.formatter.exs` — nothing under `test/`, `examples/`, `scripts/`, `steering/`, `conformance/`. `.gitignore` carries `allm-*.tar`.
- [ ] `README.md` carries the Getting Started snippet; "Pre-release scaffolding" status removed.
- [ ] `CHANGELOG.md` carries the v0.2 rollup as the first H2; existing per-phase entries preserved verbatim.
- [ ] `groups_for_modules:` audit passes — every module under `lib/` appears in exactly one group; no module unaccounted-for.
- [ ] `steering/reviews/PHASE_12_REVIEW.md` exists with the `/review` artifact; any High/Medium Findings fixed in-phase; Low Findings deferred with explicit v0.3 pointers.
- [ ] CHANGELOG entry added per public artifact (5 lines: §31 freeze, ex_doc layout, version bump, hex.build validation, case-study translations rollup).
- [ ] **`mix hex.publish` is NOT run.** Out of scope per Decision #1.
- [ ] `git diff --stat lib/` reports `lib/allm.ex` as the only modified `lib/` file, and the diff is confined to `@moduledoc` content (a Getting Started doctest addition per Decision #3) — verified by `git diff lib/allm.ex` showing only `@moduledoc`-bounded changes, no `def`/`defmacro`/`defstruct`/`@type`/`@spec`/`@callback` edits.
- [ ] Spec section references (`§31`, `§32.1`, `§32.4`, `§33`, `§34`) appear in commit messages for every Phase 12 sub-phase.
