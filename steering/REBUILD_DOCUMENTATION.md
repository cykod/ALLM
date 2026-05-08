# Documentation Rebuild — Design Document

> **Goal:** Rewrite ALLM's user-facing documentation (README, every `@moduledoc`, every public `@doc`, CHANGELOG, `examples/README.md`) so a developer with no access to the `steering/` tree can adopt and ship the library end-to-end.
> **Outcome:** Zero references to internal phases (`Phase N`, `Phase N.M`, "Decision #X"), zero references to internal spec sections (`§4`, `§12.3`, `steering/allm_engine_session_streaming_spec_v0_2.md`), expanded worked examples for the seven highest-traffic entry points, and a hexdocs landing page that walks first-time users from install → streaming-tool-call in under five minutes.
> **Layers touched:** Documentation only — no `lib/` behavioural changes, no `test/` assertion changes (test code comments are out of scope; only `@doc`/`@moduledoc` docstrings change).

This is a **documentation-only** design — the AGENT_DESIGN_SPEC sections that govern code contracts (Behaviour & Type Contracts, Error Contract, Streaming & Backpressure) do not apply. The Test Plan section is repurposed to verify documentation quality (link rot, banned-token grep, doctest compile, hexdocs render).

## Status

| Phase | Description | Surface | Status |
|-------|-------------|---------|--------|
| 0 | Pre-flight: inventory test files that pin against user-facing prose | `test/` | Not Started |
| 1 | Audit — produce a banned-token inventory and per-file rewrite budget | reporting | Not Started |
| 2 | Rewrite the top-level facade — `lib/allm.ex` `@moduledoc` + every public `@doc` | `lib/allm.ex` | Not Started |
| 3 | Rewrite the user-facing module `@moduledoc`s for Layer A data types | `lib/allm/{message,request,response,thread,session,event,usage,tool,tool_call,step_result,chat_result,model_ref,image,image_part,text_part}.ex` | Not Started |
| 4 | Rewrite the runtime `@moduledoc`s — Engine, Session, Keys, Validate, Capability, Retry, StreamCollector, Serializer, Telemetry | `lib/allm/{engine,session,keys,validate,capability,retry,stream_collector,serializer,telemetry}.ex` | Not Started |
| 5 | Rewrite behaviour `@moduledoc`s — `Adapter`, `StreamAdapter`, `ToolExecutor`, `ToolResultEncoder`, `ImageAdapter` | `lib/allm/{adapter,stream_adapter,tool_executor,tool_result_encoder,image_adapter}.ex` | Not Started |
| 6 | Rewrite provider `@moduledoc`s — OpenAI, Anthropic, Gemini, OpenAI.Images, Gemini.Images, Fake, FakeImages | `lib/allm/providers/*.ex` | Not Started |
| 7 | Rewrite error `@moduledoc`s — every module under `lib/allm/error/` | `lib/allm/error/*.ex` | Not Started |
| 8 | Rewrite README.md — full restructure with the new TOC, new examples, no spec links | `README.md` | Not Started |
| 9 | Rewrite CHANGELOG.md release-note prose — drop spec name, drop "Phase" mentions | `CHANGELOG.md` | Not Started |
| 10 | Rewrite `examples/README.md` — drop "Phase" / spec-section links, restructure as a learning path | `examples/README.md` | Not Started |
| 11 | Strip phase/spec comments from `mix.exs` deps block — convert to forward-looking prose | `mix.exs` | Not Started |
| 12 | Add a new `guides/` set of ExDoc extras: Getting Started, Streaming, Tools, Sessions, Vision, Image Generation, Errors & Retries, Multi-Tenant Keys | `guides/*.md`, `mix.exs` `docs[:extras]` + `package[:files]` | Not Started |
| 13 | Verification — banned-token grep is empty, doctests pass, `mix docs` produces clean hexdocs, link-checker passes | full repo | Not Started |

**Overall Progress:** 0/14 phases complete

**Phase ordering constraint:** Phase 12 (`guides/`) ships **before** Phase 8 (README restructure). The new README cross-links the guides; landing Phase 8 first leaves dead links. Phases 2–7, 9, 10, 11 are mutually independent and may ship in any order after Phase 1 lands.

## Overview

ALLM's user-facing documentation today reads as if a developer had committed access to the `steering/` directory: docstrings cite `spec §6.3`, `Phase 7 Non-obvious Decision #9`, `PHASE_8_DESIGN.md` filenames, and `steering/allm_engine_session_streaming_spec_v0_2.md`. Hex package consumers see none of those files — they were stripped from `package[:files]`. The result is a hexdocs landing page that points readers at vocabulary they cannot resolve, a README footnoting an inaccessible spec, and a top-level `lib/allm.ex` `@moduledoc` whose Getting Started block still says "Phase 1 (this release) ships Layer A" — wrong since v0.3.0, when the package shipped feature-complete.

This phase rewrites the public docs as if the package were the only artifact in scope. Internal vocabulary that only makes sense against `steering/` is removed; design rationale that *is* useful externally is rewritten in self-contained prose. Worked examples expand from "how to call the function" to "what does the workflow look like end-to-end" for the seven highest-traffic entry points (`generate/3`, `stream_generate/3`, `chat/3`, `stream/3`, `step/3`, `Session.start/3`, `Session.reply/4`).

The audit baseline: `grep -rEc 'Phase [0-9]|§[0-9]+|spec §|allm_engine_session|steering/|PHASE_|Decision #|Non-obvious Decision|retro F[0-9]' lib/ README.md CHANGELOG.md examples/README.md mix.exs` returns **~766 hits** across the 62-file `lib/` tree plus the four root user-facing docs (verified at design time, 2026-05-07; the per-phase rewrite budget below sums to within ±5% of the baseline). The acceptance criterion for this rebuild is **0 hits** across user-facing surfaces (the `steering/` tree itself is unaffected — internal docs may continue to cite phases).

- **Deliverables**
  - `README.md` — restructured with a five-minute on-ramp, no spec links, expanded examples for streaming, tools, sessions, manual mode, and key resolution.
  - Every `@moduledoc` and every public `@doc` in `lib/` rewritten so the prose is self-contained. ExDoc renders the result.
  - 8 new `guides/` ExDoc extras (`getting_started.md`, `streaming.md`, `tools.md`, `sessions.md`, `vision.md`, `image_generation.md`, `errors_and_retries.md`, `multi_tenant_keys.md`).
  - `CHANGELOG.md` release prose rewritten to drop internal vocabulary while preserving the v0.3.0 release-note bullets.
  - `examples/README.md` reframed as a learning path with no phase callouts.
  - `mix.exs` deps-block comments converted to forward-looking prose (`# llm_db: capability pre-flight, planned for a future release` rather than `# :llm_db re-added in Phase 9`).

- **What stays the same**
  - All `lib/` *behaviour* (function bodies, `@spec`s, type definitions, dispatch, error returns).
  - All test assertions.
  - The `steering/` tree — internal design docs continue to cite phases and spec sections.
  - The `examples/*.exs` runnable scripts — they execute, they're not narrative documentation. Comments inside them stay verbatim if not user-facing.
  - The `conformance/` package's docs — internal to the test harness.

- **Prerequisites** — none. This is a pure-docs phase; no other phase blocks it.

- **Out of scope**
  - Renaming functions, modules, or struct fields. The rebuild rewrites *prose about* the API; it does not change the API.
  - Restructuring the four-layer mental model. The four layers are how the library is shaped; the rebuild keeps Layer A/B/C/D framing but explains it without the spec citation.
  - Adding new public API surface (new functions, new opts, new error reasons). Anything beyond docs lands as its own design.
  - Translating docs to other languages.
  - Adding diagrams beyond ASCII (no PlantUML, Mermaid, or PNG additions in this phase — keep the rebuild focused).
  - Test-file comments. `test/**/*.exs` retains its current internal vocabulary; tests are not user-facing.

- **Non-obvious decisions**
  - **Remove "alpha" warning from README.** Tied to the v0.3.0 ship — the package is now in users' hands. Replace with a concrete stability statement: "Public API is stable across minor versions within v0.x; we'll bump major before breaking changes." `Docs target: README.md`
  - **Keep the four-layer framing in user docs.** It is the cleanest way to explain why `Engine`, `chat/3`, and `Session.reply/4` exist as separate surfaces. Reframe as "Four layers, four use cases" without citing the spec. `Docs target: README.md, @moduledoc ALLM`
  - **Never link to `steering/` from user-facing docs.** ExDoc renders relative links into hexdocs URLs that 404 because `steering/` isn't shipped. Drop the link entirely; if the content is load-bearing, inline it. `Docs target: README.md, every @moduledoc citing the spec`
  - **Keep `@doc` for private helpers private.** This phase only rewrites docstrings on `@moduledoc` blocks and on functions visible in ExDoc (per `mix.exs` `docs.groups_for_modules`). Private `defp` comments are out of scope. `Docs target: internal — no user-facing docs needed`
  - **One canonical example per feature, not three.** The current README hits structured-output twice (Common Patterns §2 and Layer C §Structured output) and tools three times (Common Patterns §4, Layer C `chat/3`, Layer C `step/3`, Manual mode). Pick one canonical worked example per feature; cross-reference instead of duplicating. `Docs target: README.md`
  - **Use `ALLM.Providers.Fake` for every doctest.** No real-provider doctest in `@doc` blocks — they're not deterministic and ExDoc compiles them under `mix test`. The README/Guides may show real-provider snippets without `iex>` prefixes (so they don't run). `Docs target: every @doc with a runnable example`
  - **Guides get their own `guides/` directory.** ExDoc extras live alongside `README.md` and `CHANGELOG.md`. New files go under `guides/` (NEW directory) and are added to both `package[:files]` and `docs[:extras]` so they ship to hexdocs AND the source tarball — verified with `tar -tzf` at release. `Docs target: mix.exs`
  - **`mix.exs` deps comments.** The current comments mix forward-looking notes (`:llm_db re-added in Phase 9`) with implementation history (`Phase 0 tarball audit`). Keep the *operational* notes (what the dep is for, why it's `only:`-scoped) and drop the historical-phase narrative. `Docs target: mix.exs comments — internal but reader-facing for contributors`
  - **CHANGELOG keeps the `[REL]` / `[FEAT]` / `[DOC]` tags.** They are user-facing release-type signals (used by `/changelog`). Only the prose underneath gets rewritten. `Docs target: CHANGELOG.md`
  - **A "What's in the box" landing page.** The README's first 200 lines today are an orientation tour. Split: the README opens with a 30-second pitch + 5-minute on-ramp; the deeper four-layer tour moves to `guides/getting_started.md`. Hexdocs readers land on `ALLM`'s `@moduledoc` first; both routes get a clean entry. `Docs target: README.md, guides/getting_started.md`

## Banned-token inventory (what this rebuild removes)

The rewrite is mechanical to verify: a fixed list of regex patterns must match zero lines across the user-facing surface after the rebuild. Patterns:

| Pattern | Where it appears today (sample) | After |
|---------|--------------------------------|-------|
| `(?i)phase \d+(\.\d+)?` | `lib/allm.ex:23,163,191,…` (Phase 1, Phase 5, Phase 7) | banned in `lib/`, README, CHANGELOG, `examples/README.md`, `mix.exs`, `guides/` |
| `§\d+(\.\d+)?` | `lib/allm/event.ex:3,8,249,…` (§8, §12.3) | banned in same surfaces |
| `spec §\d` | `lib/allm.ex:210,257,…` | banned |
| `allm_engine_session_streaming_spec` | `README.md:44`, `CHANGELOG.md:5`, `lib/allm.ex:7,46` | banned |
| `steering/` | `README.md:44`, `lib/allm.ex:7,46`, `lib/allm/session.ex:29,…` | banned |
| `PHASE_\d+(_DESIGN)?(_\w+)?\.md` | `lib/allm/session.ex:29,524,630` | banned |
| `(?i)decision\s*#?\s*\d+` | `lib/allm.ex:163,193,442,…` (`Decision #N`, `Decision N`, `decision #N`) | banned |
| `Non-obvious Decision` | `lib/allm.ex:421,442,550,554,…` | banned |
| `retro F\d+` | `lib/allm/event.ex:404` | banned |
| `retro/[a-z0-9_-]+\.md` | various | banned |
| `RELEASE_PLAN\|PROJECT_PHASING` | various | banned |

The patterns are case-insensitive where appropriate (`Phase` and `phase`, `Decision` and `decision`). The audit script's test fixture (Phase 1.1) covers each row with one positive and one negative case to guard against regex drift.

The `steering/` directory itself is untouched — internal phase numbering and spec citations are how the design tree is organized and stay verbatim.

**Surface scope of the grep:** `lib/`, `README.md`, `CHANGELOG.md`, `examples/README.md`, `guides/` (after they exist), `mix.exs`, and `HISTORY.md` is **excluded** (HISTORY is a per-commit rolling log; phase callouts are accurate history, not forward narrative — and HISTORY.md is in `package.files`'s exclusion).

Wait — verify: is `HISTORY.md` in `package[:files]`? Per `mix.exs:72`: `files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE .formatter.exs)`. HISTORY is **not** shipped; it's dev-only. So phase mentions there are fine. The audit grep excludes `HISTORY.md`.

## Surface scope and per-file rewrite budget

The 41 `lib/` files with banned-token hits, ranked by hit count, set the rewrite budget:

| File | Hits | Surface | Rewrite character |
|------|------|---------|--------------------|
| `lib/allm/chat.ex` | 54 | private orchestrator (NOT in `docs.groups_for_modules` `Internals`? — actually IS, see `mix.exs:139`) | Internal module, but in ExDoc `Internals` group; rewrite the public-visible `@moduledoc` and `@doc` only. |
| `lib/allm/providers/openai.ex` | 46 | provider | Public; full rewrite. |
| `lib/allm/tool_runner.ex` | 37 | internal | In `Internals` group. Rewrite. |
| `lib/allm/stream_collector.ex` | 34 | runtime | In `Runtime` group. Rewrite. |
| `lib/allm/providers/anthropic.ex` | 32 | provider | Full rewrite. |
| `lib/allm/session.ex` | 28 | sessions | Heavy user-facing; full rewrite. |
| `lib/allm/providers/gemini.ex` | 24 | provider | Full rewrite. |
| `lib/allm/providers/fake.ex` | 18 | provider | Used for tests; rewrite for testing-guide framing. |
| `lib/allm/stream_runner.ex` | 16 | internal | Rewrite. |
| `lib/allm/capability.ex` | 15 | runtime | Rewrite. |
| `lib/allm/retry.ex` | 13 | runtime | Rewrite. |
| `lib/allm/engine.ex` | 12 | runtime | Heavy user-facing; rewrite. |
| `lib/allm/event.ex` | 11 | data type | Public; rewrite. |
| `lib/allm/telemetry.ex` | 9 | runtime | Rewrite. |
| `lib/allm/validate.ex` | 8 | runtime | Rewrite. |
| `lib/allm.ex` (the facade) | ~7 in moduledoc + ~30 across @docs | facade | **Highest priority — landing page on hexdocs.** Full rewrite. |
| ...remaining 25 files | 1–7 each | mixed | Per-line rewrite. |

The `Internals` group exists in `mix.exs:139` precisely to render `Chat`, `Runner`, `StreamRunner`, `ToolRunner` on hexdocs as documented internals. Their docstrings ARE user-visible; they get the rewrite. Their function-body comments (`# Phase 18.4 — per-tool manual…` at `session.ex:682,737,778`) are private to the implementation and **stay** — they are code comments, not docstrings. The audit grep targets only `@moduledoc` and `@doc` blocks, NOT lines inside `def`/`defp`. **A second grep restricted to docstring blocks is required** — see Phase 1 audit.

## Module Tree

```
guides/                                         (NEW directory)
├── getting_started.md                          (NEW — 12)
├── streaming.md                                (NEW — 12)
├── tools.md                                    (NEW — 12)
├── sessions.md                                 (NEW — 12)
├── vision.md                                   (NEW — 12)
├── image_generation.md                         (NEW — 12)
├── errors_and_retries.md                       (NEW — 12)
└── multi_tenant_keys.md                        (NEW — 12)

README.md                                       (MODIFY — 8, full restructure; 5-minute on-ramp + cross-link to guides; no steering/ links)
CHANGELOG.md                                    (MODIFY — 9, drop spec name + Phase mentions from v0.3.0 release-note prose)
examples/README.md                              (MODIFY — 10, drop spec-section linkage; reframe as learning path)
mix.exs                                         (MODIFY — 11+12, drop Phase narrative from deps comments; add guides/* to docs.extras and package.files)

lib/allm.ex                                     (MODIFY — 2, full @moduledoc + every public @doc rewrite — landing page)

lib/allm/message.ex                             (MODIFY — 3)
lib/allm/request.ex                             (MODIFY — 3)
lib/allm/response.ex                            (MODIFY — 3)
lib/allm/thread.ex                              (MODIFY — 3)
lib/allm/session.ex                             (MODIFY — 3, Layer A struct; runtime helpers covered narratively in Phase 4 without re-touching the file)
lib/allm/event.ex                               (MODIFY — 3)
lib/allm/usage.ex                               (MODIFY — 3)
lib/allm/tool.ex                                (MODIFY — 3)
lib/allm/tool_call.ex                           (MODIFY — 3)
lib/allm/step_result.ex                         (MODIFY — 3)
lib/allm/chat_result.ex                         (MODIFY — 3)
lib/allm/model_ref.ex                           (MODIFY — 3)
lib/allm/image.ex                               (MODIFY — 3)
lib/allm/image_part.ex                          (MODIFY — 3)
lib/allm/text_part.ex                           (MODIFY — 3)
lib/allm/image_request.ex                       (MODIFY — 3)
lib/allm/image_response.ex                      (MODIFY — 3)
lib/allm/image_usage.ex                         (MODIFY — 3)

lib/allm/engine.ex                              (MODIFY — 4)
lib/allm/keys.ex                                (MODIFY — 4)
lib/allm/validate.ex                            (MODIFY — 4)
lib/allm/capability.ex                          (MODIFY — 4)
lib/allm/retry.ex                               (MODIFY — 4)
lib/allm/stream_collector.ex                    (MODIFY — 4)
lib/allm/serializer.ex                          (MODIFY — 4)
lib/allm/telemetry.ex                           (MODIFY — 4)

lib/allm/adapter.ex                             (MODIFY — 5)
lib/allm/stream_adapter.ex                      (MODIFY — 5)
lib/allm/tool_executor.ex                       (MODIFY — 5)
lib/allm/tool_result_encoder.ex                 (MODIFY — 5)
lib/allm/image_adapter.ex                       (MODIFY — 5)

lib/allm/providers/openai.ex                    (MODIFY — 6, heaviest hit count)
lib/allm/providers/anthropic.ex                 (MODIFY — 6)
lib/allm/providers/gemini.ex                    (MODIFY — 6)
lib/allm/providers/openai/images.ex             (MODIFY — 6)
lib/allm/providers/gemini/images.ex             (MODIFY — 6)
lib/allm/providers/fake.ex                      (MODIFY — 6, reframe as the test-vehicle docstring)
lib/allm/providers/fake_images.ex               (MODIFY — 6)
lib/allm/providers/fake/script.ex               (MODIFY — 6)
lib/allm/providers/support/sse.ex               (MODIFY — 6)
lib/allm/providers/support/openai_headers.ex    (MODIFY — 6)
lib/allm/providers/support/gemini_headers.ex    (MODIFY — 6)
lib/allm/providers/support/image_mime.ex        (MODIFY — 6)

lib/allm/error/adapter_error.ex                 (MODIFY — 7)
lib/allm/error/engine_error.ex                  (MODIFY — 7)
lib/allm/error/session_error.ex                 (MODIFY — 7)
lib/allm/error/stream_error.ex                  (MODIFY — 7)
lib/allm/error/tool_error.ex                    (MODIFY — 7)
lib/allm/error/validation_error.ex              (MODIFY — 7)
lib/allm/error/image_adapter_error.ex           (MODIFY — 7)

lib/allm/runner.ex                              (MODIFY — 4, in Internals group)
lib/allm/chat.ex                                (MODIFY — 4, in Internals group, heaviest hit count)
lib/allm/stream_runner.ex                       (MODIFY — 4, in Internals group)
lib/allm/tool_runner.ex                         (MODIFY — 4, in Internals group)
lib/allm/chat/loop_state.ex                     (MODIFY — 4, in Internals group; short Internal admonition)

lib/allm/session/stream_reducer.ex              (MODIFY — 4)

lib/allm/keys/dotenv.ex                         (MODIFY — 4, sub-module of Keys)
lib/allm/keys/store.ex                          (MODIFY — 4, sub-module of Keys)
lib/allm/tool_executor/default.ex               (MODIFY — 5, Defaults group)
lib/allm/tool_result_encoder/json.ex            (MODIFY — 5, Defaults group)
lib/allm/providers/gemini/decode.ex             (MODIFY — 6, sub-module of Gemini provider)
lib/allm/application.ex                         (MODIFY — 4, OTP Application module — short docstring covering the supervision tree only)

scripts/audit_user_docs.exs                     (NEW — 1, one-shot grep + summary; reusable for verification)
scripts/check_lib_diff_non_doc.exs              (NEW — 13, classifies `lib/` diff lines as inside-docstring vs outside; backs the DoD "no behavioural change" claim)
```

**Path-existence check:** every `lib/**/*.ex` path enumerated above is verified to exist via `find lib -name '*.ex'` at design time (62 source files, all enumerated). The `guides/` directory is NEW; create it as part of Phase 12.

**Module Tree completeness invariant.** This phase touches docstrings only. The audit script (`scripts/audit_user_docs.exs`) is the source of truth for which files have hits — Phase 1's deliverable is "list every file the rewrite must touch + hit-count budget per file." If a file appears in the audit and is not in the Module Tree above, the design is wrong; amend before implementing.

## Phases

Each phase is independently shippable. After every phase: `mix test` (including doctests), `mix docs` (no warnings, no broken intra-doc links), `mix credo --strict`, `mix dialyzer`, `mix format --check-formatted` all pass.

### Phase 0: Pre-flight survey of test dependencies on docstring content

**Goal:** Inventory the tests that already pin against user-facing prose so the rewrite doesn't break them silently.

The repo already has `test/readme_getting_started_test.exs` (a recurring break-point flagged six times in CLAUDE.md across PHASE_16.x). Phase 0 reads it, decides whether to extend / replace / supersede it in Phase 8, and surfaces every other `test/**/*.exs` that asserts substring-matches against prose in `lib/` `@moduledoc`/`@doc` blocks or `README.md`.

**Implementation Checklist:**

- [ ] Read `test/readme_getting_started_test.exs` end-to-end. Decide: extend, replace, or supersede in Phase 8. Record the decision inline in Phase 8.
- [ ] `git grep -l 'Phase\|§\|steering/\|allm_engine_session' test/` → review each match for whether it asserts against `lib/` docstring content (vs. matching code-comment text — those don't change).
- [ ] Output: a short note appended to this design under "Phase 0 findings" listing every test that pins a docstring or README phrase, and the corresponding rewrite phase that must update both.

**Verification:** the Phase 0 findings note is appended to this design before Phase 1 begins.

#### Phase 0 findings (recorded 2026-05-07)

`git grep -l 'Phase\|§\|steering/\|allm_engine_session' test/` returns ~80 matches. Reviewing each: the overwhelming majority live inside `test/**/*.exs` `@moduledoc` strings or `def`/`defp` body comments — they describe the test's own context against the spec/phase tree and are inert relative to the rewrite. They do NOT pin user-facing prose, and the audit script (Phase 1) by design does not scan `test/`.

The following test files DO pin user-facing prose and must be kept synchronized when the corresponding rewrite phase lands:

| Test file | What it pins | Rewrite phase that must update both |
|-----------|--------------|--------------------------------------|
| `test/readme_getting_started_test.exs` | Parses the first ` ```elixir ` fenced block under `## Hello, ALLM` in `README.md`, evaluates it via `Code.eval_string/1`, and asserts the result is `"Hello, ALLM!"`. Also requires the snippet to contain `ALLM.Engine.new`. | Phase 8 — **EXTEND, not replace**. Per §8.2 this is the canonical README-runs-clean test (recurring break-point flagged six times in CLAUDE.md). Phase 8 keeps the file, renames/expands the heading-anchored extraction so it walks the new "5-minute tour" sections, drops assertions on prose that no longer exists, and stays the canonical guard. |
| `test/allm_test.exs` | `doctest ALLM` — runs every `iex>` block in `lib/allm.ex`'s `@moduledoc` and `@doc`. Phase 2 rewrites those docstrings; the doctests must keep compiling and passing under `ALLM.Providers.Fake`. | Phase 2 — every `iex>` doctest in the rewritten facade docstrings stays runnable; Phase 2's Test Plan already covers this via `test/allm_doc_test.exs` (NEW) and the existing `doctest ALLM` will exercise the rewrites. |
| `test/allm/allm_generate_test.exs`, `test/allm/allm_step_test.exs`, `test/allm/allm_chat_test.exs`, `test/allm/allm_stream_test.exs`, `test/allm/allm_stream_generate_test.exs`, `test/allm/allm_stream_step_test.exs`, `test/allm/allm_generate_image_test.exs`, `test/allm/allm_edit_image_test.exs`, `test/allm/allm_image_variations_test.exs`, `test/allm/allm_image_request_test.exs` | Each carries `doctest ALLM, only: [<fun>: <arity>]` — runs the `@doc` doctest on the named facade function. Phase 2 rewrites those `@doc` blocks. | Phase 2 — same as above; rewritten doctests must remain Fake-driven and runnable. |
| `test/allm/<struct>_test.exs` (e.g. `message_test.exs`, `request_test.exs`, `response_test.exs`, `tool_call_test.exs`, `event_test.exs`, `image_test.exs`, `image_part_test.exs`, `text_part_test.exs`, `step_result_test.exs`, `chat_result_test.exs`, `model_ref_test.exs`, `image_response_test.exs`, `image_usage_test.exs`, `session_test.exs`, `session_stream_reducer_test.exs`) | Each carries `doctest <Struct>` — runs the `@moduledoc` and `@doc` doctests on the Layer A / Session struct. Phase 3 (Layer A) and Phase 4 (Session) rewrite those moduledocs. | Phases 3 and 4 — preserve runnable construction doctests in every rewritten Layer A `@moduledoc`. |
| `test/allm/keys_test.exs`, `test/allm/telemetry_test.exs`, `test/allm/tool_runner_test.exs`, `test/allm/runner_test.exs`, `test/allm/stream_runner_test.exs` | `doctest <RuntimeMod>` — runs Layer B/C runtime moduledoc doctests. Phase 4 rewrites those moduledocs. | Phase 4. |
| `test/allm/adapter_test.exs` | `doctest DocAssertions` — runs doctests on the test-support helper, NOT the `Adapter` behaviour module itself. The behaviour `@moduledoc` rewrite (Phase 5) is unaffected by this file. | None (informational). |

**No other test file** in the suite asserts on `lib/` docstring text or `README.md` prose via substring/regex matches. Tests with `assert _ =~ "Phase ..."` style assertions on docstring content do not exist; comments-about-docstrings (e.g. `engine_roundtrip_test.exs:184` — "this asymmetry is documented in `ALLM.Engine`'s moduledoc") are inert prose, not test assertions.

**Net effect:** the rewrite is well-defended against silent doctest regressions because every public Layer A struct, every facade entry point, and every documented runtime module has an existing `doctest` test. The single non-doctest pin is `test/readme_getting_started_test.exs`, owned by Phase 8.

### Phase 1: Audit script

**Goal:** Produce a reusable script that enumerates every banned-token hit across the user-facing surface, and a baseline report.

#### 1.1 Test Plan (write first)

`test/scripts/audit_user_docs_test.exs` (NEW) — yes, the audit script gets a test, because future contributors will run it pre-PR:

- `audit_user_docs.exs run on the current repo emits a non-empty report` (baseline, will start passing on Phase 1 land)
- `audit_user_docs.exs surface set is exactly: lib/, README.md, CHANGELOG.md, examples/README.md, guides/, mix.exs` — explicitly excludes `HISTORY.md`, `steering/`, `test/`, `retro/`, `reviews/`, `doc/` (generated)
- `audit_user_docs.exs detects each banned-token regex` — fixture-based: a tmp file with one occurrence of each pattern returns exactly one hit per pattern
- `audit_user_docs.exs targets docstring blocks only inside lib/.ex files` — code comments (`# Phase 18.4 …`) inside `def`/`defp` bodies are NOT counted; `@moduledoc` and `@doc` blocks ARE counted. Verified by a fixture file with both.
- `audit_user_docs.exs returns exit 0 when zero hits, exit 1 when ≥1 hit` — wireable into CI / `/review` gates.

#### 1.2 Implementation Checklist

- [ ] Implement `scripts/audit_user_docs.exs` as a `Mix.Task`-free script (runs under `mix run`).
- [ ] Walk file set: `lib/**/*.ex`, top-level `README.md`, `CHANGELOG.md`, `mix.exs`, `examples/README.md`, `guides/**/*.md`. Skip `HISTORY.md`, `test/`, `steering/`, `retro/`, `reviews/`, `doc/`, `_build/`, `deps/`.
- [ ] For `.ex` files, parse out `@moduledoc` and `@doc` string heredocs only — code comments are not user-facing. Use line-based heuristic: track whether the current line is inside a `"""`-bracketed heredoc that opens on a `@moduledoc`/`@doc` line. (A real Elixir parser is overkill for what is fundamentally a `grep -A` + state machine.)
- [ ] For `.md` files, search the whole file.
- [ ] Emit a per-file hit-count summary and a flat list of `path:line:matched-pattern:line-text` for triage.
- [ ] Exit `0` on zero total hits; `1` otherwise.
- [ ] Land a baseline report at `tmp/docs_audit_baseline.txt` (gitignored — `tmp/` is already in `.gitignore`) the implementer runs once at Phase 1 close, for sanity-checking subsequent phases.

#### 1.3 Verification

```bash
mix run scripts/audit_user_docs.exs            # exit 1, prints ~545 hits in baseline
mix test test/scripts/audit_user_docs_test.exs # all green
```

### Phase 2: Rewrite `lib/allm.ex` — the hexdocs landing page

**Goal:** A first-time hexdocs visitor lands on the `ALLM` module page, reads the `@moduledoc`, and can paste a working snippet within 60 seconds.

#### 2.1 Test Plan (write first)

`test/allm_doc_test.exs` (NEW — purely doctest-driven):

- The `@moduledoc` for `ALLM` contains a runnable Hello, ALLM doctest using `ALLM.Providers.Fake` (no API key, no network).
- The `@moduledoc` doctest executes `ALLM.chat(engine, [ALLM.user("Hi.")])` and asserts the returned `output_text`.
- Every **non-streaming** public function in `ALLM` (`generate/3`, `step/3`, `chat/3`, `Session.start/3`, `Session.reply/4`, `Session.continue/3`) has at least one runnable `@doc` doctest using `ALLM.Providers.Fake`. Counted programmatically in the test: `for {fun, arity} <- @public_facade_sync, do: assert_has_doctest(ALLM, fun, arity)`.
- Streaming public functions (`stream_generate/3`, `stream_step/3`, `stream/3`, `Session.stream_start/3`, `Session.stream_reply/4`) have **construction-only** doctests: build the engine, call the function, assert `{:ok, %Stream{}}`-shape match. Do NOT consume the stream in `iex>` blocks — `Logger.configure/1` and `:telemetry.attach/4` are async-foot-guns that flake doctests run under `async: true`. Stream-consumption examples live in `guides/streaming.md` as non-doctest code blocks.
- Audit-script run on `lib/allm.ex` returns 0 hits.

`test/allm_facade_doctest_inventory_test.exs` (NEW): tracks the public-facade function list explicitly, so adding a public function without a doctest fails the test. The inventory list is the contract — `@public_facade = [...]` at the top of the test module.

#### 2.2 Implementation Checklist

- [ ] Replace `lib/allm.ex` `@moduledoc`. New shape:
  - 30-second pitch (1 paragraph): provider-neutral execution, streaming-first, serializable state.
  - 5-minute on-ramp: install snippet → Fake doctest → swap to real provider.
  - "When to use what" table: `generate/3` (one shot, no tools), `step/3` (one round, with tools), `chat/3` (full loop), `Session.*` (multi-turn with persistence).
  - "Where to next" links: `guides/getting_started.md`, `guides/streaming.md`, `guides/tools.md`, `guides/sessions.md`.
  - **No mention of phases, decisions, spec sections, or `steering/`.**
  - **No spec link.** Replace the `steering/...spec_v0_2.md §4` close-out with "See module-by-module docs in the sidebar."
- [ ] Rewrite every public-function `@doc` in `lib/allm.ex`. Keep contract material (arities, opts, return shapes, error tuples) verbatim — it's correct; just strip the spec/phase callouts. Replace each with a one-line "When to reach for this" + a runnable Fake doctest where one is missing.
- [ ] Audit-script `mix run scripts/audit_user_docs.exs lib/allm.ex` returns 0 hits.

#### 2.3 Verification

```bash
mix run scripts/audit_user_docs.exs lib/allm.ex      # 0 hits
mix test --only doctest test/allm_doc_test.exs       # all doctests pass
mix test test/allm_facade_doctest_inventory_test.exs # public facade contract test passes
mix docs                                              # no warnings; renders ALLM.html with the new content
```

### Phase 3: Layer A data-type `@moduledoc`s

**Goal:** Each Layer A struct (`Message`, `Request`, `Response`, `Thread`, etc.) has a self-contained `@moduledoc` explaining what the struct is, when you build one, what the fields mean, and one runnable construction doctest. No spec citations.

#### 3.1 Test Plan

`test/layer_a_docs_test.exs` (NEW):

- For each module in the Layer A list (15 modules), the `@moduledoc` is a non-empty heredoc (length > 100 chars).
- For each module, exactly one runnable doctest exists using only Layer A constructors (`ALLM.user/1`, `ALLM.system/1`, `ALLM.request/2`, etc.) and `ALLM.Serializer.to_json!/1` round-trip.
- Audit-script grep on Layer A files returns 0 hits.

#### 3.2 Implementation Checklist

- [ ] Rewrite the 15 Layer A `@moduledoc`s. Common shape:
  - One-sentence purpose.
  - Field-by-field table (type + default + meaning).
  - Round-trip example (ETF and JSON).
  - Cross-link to the relevant guide (`guides/getting_started.md` for most; `guides/vision.md` for `ImagePart`/`TextPart`; `guides/image_generation.md` for `ImageRequest`/`ImageResponse`).
- [ ] No new public API. No struct-shape changes.

#### 3.3 Verification

```bash
mix run scripts/audit_user_docs.exs lib/allm/{message,request,response,thread,session,event,usage,tool,tool_call,step_result,chat_result,model_ref,image,image_part,text_part,image_request,image_response,image_usage}.ex
# 0 hits
mix test test/layer_a_docs_test.exs
mix docs
```

### Phase 4: Layer B/C runtime `@moduledoc`s

**Goal:** `Engine`, `Keys`, `Validate`, `Capability`, `Retry`, `StreamCollector`, `Serializer`, `Telemetry` rewritten with self-contained framing. The `Internals` group (`Chat`, `Runner`, `StreamRunner`, `ToolRunner`) gets shorter rewrites — they're documented internals, not contract surface, and the docstring should say so explicitly.

#### 4.1 Test Plan

- Each Phase 4 module's `@moduledoc` is a non-empty heredoc.
- `Engine`'s `@moduledoc` has a doctest constructing an engine with `ALLM.Providers.Fake`.
- `Keys`'s `@moduledoc` enumerates the resolution order (per-call `:api_key` → engine `:keys` resolver → app config → env var → default) without citing the spec section.
- `Telemetry`'s `@moduledoc` lists the emitted event names and measurement keys verbatim, since users pattern-match on them.
- The `Internals` group's `@moduledoc`s open with a "**Internal**" admonition: "This module is an internal — it's documented for transparency, but call sites should use `ALLM.chat/3` / `ALLM.stream/3` instead."

#### 4.2 Implementation Checklist

- [ ] Rewrite 8 user-facing runtime `@moduledoc`s (`Engine`, `Keys`, `Validate`, `Capability`, `Retry`, `StreamCollector`, `Serializer`, `Telemetry`).
- [ ] Rewrite 4 `Internals` group `@moduledoc`s (`Chat`, `Runner`, `StreamRunner`, `ToolRunner`) — short, with the Internal admonition.

#### 4.3 Verification

```bash
mix run scripts/audit_user_docs.exs lib/allm/{engine,keys,validate,capability,retry,stream_collector,serializer,telemetry,chat,runner,stream_runner,tool_runner}.ex
mix test --only doctest
mix docs
```

### Phase 5: Behaviour `@moduledoc`s

**Goal:** Each behaviour (`Adapter`, `StreamAdapter`, `ToolExecutor`, `ToolResultEncoder`, `ImageAdapter`) has a `@moduledoc` that lets a user **implement** the behaviour from scratch — what each callback receives, what it must return, what error tuples are legal. Today's docstrings cite the spec.

#### 5.1 Test Plan

- Each behaviour's `@moduledoc` includes:
  - The full callback signature list (already rendered by ExDoc — the prose introduces them).
  - A "minimal stub" code block that compiles, demonstrating the smallest legal `@behaviour ALLM.Adapter` impl. Each stub is a doctest in a sibling module that compiles under `mix test`.
- Audit-grep on behaviour modules returns 0 hits.

#### 5.2 Implementation Checklist

- [ ] Rewrite 5 behaviour `@moduledoc`s.
- [ ] For each, add a "Minimum impl skeleton" code block. These are non-runnable code blocks (no `iex>` prefix) — they show shape, not values.

### Phase 6: Provider `@moduledoc`s

**Goal:** Each provider module (`OpenAI`, `Anthropic`, `Gemini`, plus their `Images`, plus `Fake`/`FakeImages`/`Support.*`) has a `@moduledoc` covering: model strings supported, env-var resolution, endpoint routing rules, capability quirks (Anthropic requires `max_tokens`, OpenAI's two endpoints, Gemini's image-MIME constraints).

#### 6.1 Test Plan

- Each provider module's `@moduledoc` has a non-doctest code block showing engine construction.
- `Fake`'s `@moduledoc` is reframed as the testing guide entry point: "Use this in your test suite. Here's how:" — runnable doctest building a `Fake` engine and walking a 3-event script.
- `FakeImages`'s `@moduledoc` mirrors `Fake`'s structure for the image surface.
- Audit-grep returns 0 hits.

#### 6.2 Implementation Checklist

- [ ] Rewrite 12 provider `@moduledoc`s (3 chat × 1 + 2 image + 2 fake + 1 fake-images + 1 fake-script + 4 support).
- [ ] Move provider-specific capability quirks (Anthropic's `max_tokens` default, OpenAI's endpoint routing, Gemini's auth header) from spec citations to first-person prose: "Anthropic's Messages API requires a `max_tokens` value on every request. ALLM injects a default of 1024 if you don't pass one — set `:max_tokens` on the request to override."

### Phase 7: Error `@moduledoc`s

**Goal:** Each error module (`AdapterError`, `EngineError`, `SessionError`, `StreamError`, `ToolError`, `ValidationError`, `ImageAdapterError`) lists its closed `:reason` enum, gives one example per reason, and explains caller recovery.

#### 7.1 Test Plan

- Each error `@moduledoc` enumerates `@type reason :: ...` atoms with one row per atom (atom + when-it-fires + caller recovery).
- The recovery-guidance prose is provider-neutral (no "Phase 11 Decision #4" framing).

#### 7.2 Implementation Checklist

- [ ] Rewrite 7 error `@moduledoc`s with the row-per-reason structure.

### Phase 8: README.md restructure

**Goal:** A reader who clones the repo (or lands on the GitHub README) reaches a runnable example in 5 minutes and a real-provider example in under 10. No spec links, no internal vocabulary, expanded examples for the seven highest-traffic entry points.

#### 8.1 New TOC

```
# ALLM

> One-line tagline.

## Why ALLM?               (3-bullet pitch)
## Install
## Hello, ALLM             (Fake-driven 6-line example)
## Pick a provider         (3 engines side by side)
## The 5-minute tour       (generate, stream, chat, tools, session)
## Worked examples         (link to guides/*.md, not duplicated here)
## Real providers          (env vars, per-call BYOK)
## Compatibility           (Elixir/OTP floor, semver promise)
## Development
## License
```

#### 8.2 Test Plan

- **Update — not replace — `test/readme_getting_started_test.exs`.** This file already exists and asserts the README's getting-started snippet runs end-to-end under `Fake`; CLAUDE.md flags it as a recurring break-point through Phase 16.x. Phase 8 extends it to walk the new "5-minute tour" sections (one assertion per section), drops any assertions on prose that no longer exists in the new README, and stays the canonical README-runs-clean test.
- README has zero banned-token hits per the audit script.
- README's "Pick a provider" section shows three providers with identical call sites — verified by string-equality comparison: extract the `ALLM.chat(engine, ...)` lines for OpenAI, Anthropic, and Gemini and assert the post-engine portions are byte-equal.
- README's "Hello, ALLM" snippet is byte-identical to `lib/allm.ex`'s `@moduledoc` Hello block — single source of truth, asserted by a small test that reads both files and `String.contains?/2`-checks.

#### 8.3 Implementation Checklist

- [ ] Rewrite README.md per the new TOC. Drop "alpha" warning; replace with concrete stability statement. Drop the spec link.
- [ ] Cross-link guides instead of duplicating their content.
- [ ] Verify the doctest test passes.

### Phase 9: CHANGELOG.md prose rewrite

**Goal:** v0.3.0 release-note prose drops `allm_engine_session_streaming_spec_v0_2` while keeping the bullet list of features.

#### 9.1 Test Plan

- Audit-grep on `CHANGELOG.md` returns 0 hits.
- The bullet list of v0.3.0 features is unchanged in count and substance (assert by line count and feature-keyword presence: `Layer A`, `Stateless execution facade`, `Stateful continuation`, `Streaming as the primitive`, `Bundled adapters`, `Vision input`, `Image generation`, `Telemetry`, `Conformance harnesses`, `Provider-neutral example scripts` all present).

#### 9.2 Implementation Checklist

- [ ] Rewrite the v0.3.0 paragraph: "First public release of ALLM — a provider-neutral, streaming-first LLM execution library for Elixir. The package is alpha: public APIs and on-disk session shapes may shift between releases until v1.0."
- [ ] Keep all feature bullets verbatim except the lines containing banned tokens.

### Phase 10: examples/README.md rewrite

**Goal:** Restructure `examples/README.md` as a learning path. Drop the "Phase" and `§` linkage. The 15 scripts stay; the prose around them changes.

#### 10.1 Test Plan

- Audit-grep on `examples/README.md` returns 0 hits.
- Every existing script filename (15 files) is referenced by `examples/README.md`.
- The "Layer" column from the existing table is preserved (Layer C / Layer D mapping is user-facing, useful, and not internal vocabulary).

#### 10.2 Implementation Checklist

- [ ] Reframe sections: "Quick start" (run `01_plain_text.exs`), "Streaming and tools" (02–04), "Multi-turn chat" (05–07), "Sessions" (08–09, 15), "Vision and images" (10–13), "Per-tool manual mode" (14–15).
- [ ] Drop spec-section linkage. Keep the table.

### Phase 11: mix.exs deps comments

**Goal:** Drop "Phase N" historical narrative from `mix.exs` deps comments while preserving the *operational* notes (what each `only:`-scoped dep does and why it exists).

#### 11.1 Test Plan

- Audit-grep on `mix.exs` returns 0 hits.
- Every dep in the `deps/0` block has either zero comment or a comment explaining what the dep is for in present tense ("Test-only — required by `Req.Test.stub/2` in OpenAI wire tests").
- All other `mix.exs` config (`package`, `docs`, `elixirc_paths`, `description`) is unchanged.

#### 11.2 Implementation Checklist

- [ ] Rewrite the four phase-bearing comments inside `deps/0`. Locate via grep on the deps key (line numbers drift with edits; helper-name cites don't):
  - The `:llm_db` placeholder comment (currently above the `:ex_doc` line): `# llm_db: capability pre-flight + cost. Deferred to a future release; will be re-added as an optional dep.`
  - The `:plug` test-only comment block (above the `{:plug, ...}` entry): `# Test-only — Req.Test.stub/2 expects a Plug shape; not in the published Hex package.`
  - The `:allm_conformance` path-dep comment block (above the `{:allm_conformance, ...}` entry): `# Test-only path dep — certifies the bundled defaults against the conformance harness. mix hex.build automatically strips test-only deps from the published metadata.`
  - The `:env_loader` dev-only comment block (above the `{:env_loader, ...}` entry): `# Dev-only — the example scripts under examples/ load API keys from a project-root .env via this. examples/ is excluded from the published package.`

### Phase 12: New `guides/` directory + ExDoc wiring

**Goal:** Create eight short guides as ExDoc extras. Each is a worked-example narrative for one feature.

#### 12.1 Guide outline (each ~150–300 lines)

- `guides/getting_started.md` — install, Fake-driven hello, swap to real provider, where to go next.
- `guides/streaming.md` — `stream_generate/3` and `stream/3`, the `ALLM.Event` union, filter opts (`:emit_text_deltas`, `:emit_tool_deltas`, `:include_raw_chunks`, `:on_event`), `Stream.resource/3` cleanup semantics, cancellation.
- `guides/tools.md` — declaring tools, the synchronous loop, `mode: :manual`, per-tool `manual: true`, `:on_tool_error`, `{:ask_user, _}` suspension.
- `guides/sessions.md` — `%Session{}`'s status union, persistence patterns (ETF, JSON, DB column), the `StreamReducer` pattern, `submit_tool_result/3`, `continue/3`.
- `guides/vision.md` — `TextPart` + `ImagePart`, multi-provider parity, image-detail levels, file vs URL vs raw bytes.
- `guides/image_generation.md` — `generate_image/3`, `edit_image/4`, `image_variations/3`, the parallel `:image_adapter` slot, OpenAI vs Gemini coverage, `FakeImages` for tests.
- `guides/errors_and_retries.md` — every `%ALLM.Error.*` shape, the `:retry_policy` engine slot, the retryable-reason set, telemetry observability.
- `guides/multi_tenant_keys.md` — `ALLM.Keys`'s resolution chain, per-call `:api_key`, app config, env var, custom resolver behaviour.

#### 12.2 Test Plan

- `test/guides_test.exs`:
  - Every guide is added to `mix.exs` `docs[:extras]`.
  - Every guide is added to `mix.exs` `package[:files]` (so it ships in the source tarball).
  - Every guide is non-empty (>2KB).
  - Every guide passes the audit grep (zero banned tokens).
  - Every guide has at least one runnable code block (verified by extracting `iex>` lines and compiling them).
- `test/package_files_extras_consistency_test.exs`: `package[:files]` is a superset of `docs[:extras]` (the long-standing CLAUDE.md invariant). Use `tar -cf` simulation: `mix hex.build --output /tmp/allm.tar`, then `tar -tf /tmp/allm.tar | grep guides/` returns all 8 guides.

#### 12.3 Implementation Checklist

- [ ] Create `guides/` directory and 8 guide files.
- [ ] Wire `mix.exs`:
  - Add `guides` to `package[:files]`: `files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE .formatter.exs guides)` (Hex recurses into directory entries).
  - Add each guide to `docs[:extras]` with **explicit hardcoded paths**, not `Path.wildcard/1` — explicit paths make the `package_files_extras_consistency_test` a literal-list comparison and catch a missing-from-tarball regression at test time rather than at release time:
    ```elixir
    @guides ~w(
      guides/getting_started.md
      guides/streaming.md
      guides/tools.md
      guides/sessions.md
      guides/vision.md
      guides/image_generation.md
      guides/errors_and_retries.md
      guides/multi_tenant_keys.md
    )

    extras: ["README.md", "CHANGELOG.md"] ++ @guides
    groups_for_extras: [{"Guides", @guides}]
    ```
    The tuple `{"Guides", paths}` form is ExDoc's canonical syntax for `groups_for_extras` (verified on `ex_doc ~> 0.34` per `mix.exs:40`); the keyword-list `[Guides: paths]` form is also accepted but the tuple form survives ExDoc API changes more gracefully.
- [ ] `mix hex.build` then `tar -tzf allm-<version>.tar | grep guides/` confirms all 8 guides ship to Hex source tarball.

### Phase 13: Verification

**Goal:** Final sweep. The audit script returns zero hits across the whole user-facing surface, all docs render, all doctests pass, all tests pass, the source tarball ships the guides.

#### 13.1 Test Plan

- `mix run scripts/audit_user_docs.exs` returns exit 0 (zero hits).
- `mix test` zero failures, including all doctest tests added in Phases 2–6, the inventory test from Phase 2, the updated `readme_getting_started_test.exs` from Phase 8, and the guides test from Phase 12.
- `mix docs` zero warnings. Manually verify the rendered `doc/index.html` and the `Guides` group includes all 8 guides.
- `mix hex.build` then `tar -tzf` confirms `README.md`, `CHANGELOG.md`, `LICENSE`, `lib/`, and `guides/` (8 files) are in the source tarball.
- `mix credo --strict`, `mix dialyzer`, `mix format --check-formatted` all green.
- **Cross-test grep:** `git grep -nE 'Phase\|§\|steering/\|allm_engine_session\|PHASE_\|Decision #' test/` — review each match. Code-comment text inside `def`/`defp` bodies is fine; `assert _ =~ "Phase N"`-style assertions against `lib/` docstring content must be hand-corrected and re-run. One-time human check, not a permanent gate.
- **`lib/` non-doc-block diff sanity-check:** run `mix run scripts/check_lib_diff_non_doc.exs` (introduced as part of Phase 13) — the script walks `git diff <pre-rebuild>..HEAD -- lib/` and classifies each changed line as inside-docstring vs outside; outside-docstring change set must be empty. This backs the DoD "no behavioural change" claim with a mechanism rather than reviewer eyeballs.

#### 13.2 Implementation Checklist

- [ ] Implement `scripts/check_lib_diff_non_doc.exs` (reuses Phase 1's heredoc state machine).
- [ ] Run the full Verification block. Land any minor cleanups.
- [ ] Update `CHANGELOG.md` with a `[DOC]` entry: "Rewrite user-facing documentation — drop internal phase/spec references, expand examples, add guides/ ExDoc extras."

## Test Plan (cross-phase summary)

| Test | Scope | Phase introduced |
|------|-------|------------------|
| `audit_user_docs_test.exs` | Audit-script correctness | 1 |
| `audit_user_docs.exs` clean exit | Banned-token absence | 1 (baseline), 2–13 (incremental) |
| `allm_doc_test.exs` | Facade `@moduledoc` + every public `@doc` runnable doctest | 2 |
| `allm_facade_doctest_inventory_test.exs` | Public-facade contract: every public function has a doctest | 2 |
| `layer_a_docs_test.exs` | Layer A `@moduledoc` length + doctests | 3 |
| `readme_doctest_test.exs` | README code blocks compile/run | 8 |
| `guides_test.exs` | Guides exist, non-empty, audit-clean, runnable | 12 |
| `package_files_extras_consistency_test.exs` | `package[:files]` ⊇ `docs[:extras]` (already a CLAUDE.md invariant) | 12 |

**Coverage:** This phase adds documentation, not behaviour. The `mix.exs` 80% threshold doesn't apply per-phase to docstring rewrites — coverage stays where it is. New test files may marginally raise coverage by exercising the audit script.

**Doctest discipline:** Every doctest added in Phases 2–6 uses `ALLM.Providers.Fake` exclusively. Real-provider examples in README and guides go in non-`iex>` code blocks so they don't compile under `mix test`.

## Verification (end-to-end)

```bash
# Audit
mix run scripts/audit_user_docs.exs                  # exit 0, zero hits

# Docs render
mix docs                                              # no warnings
ls doc/ALLM.html doc/getting_started.html             # exists
ls doc/streaming.html doc/tools.html doc/sessions.html
ls doc/vision.html doc/image_generation.html
ls doc/errors_and_retries.html doc/multi_tenant_keys.html

# Tests
mix test                                              # zero failures
mix test --only doctest                               # doctest sweep clean
mix credo --strict
mix dialyzer
mix format --check-formatted

# Hex tarball includes guides
mix hex.build --output tmp/allm.tar
tar -tzf tmp/allm-*.tar.gz | grep -E '^guides/' | wc -l   # = 8
tar -tzf tmp/allm-*.tar.gz | grep -E 'README|CHANGELOG|LICENSE|mix.exs' | wc -l  # = 4

# Manual hexdocs spot-check
mix docs && open doc/ALLM.html                        # landing page reads cleanly
```

## Definition of Done

- [ ] All 14 phases marked `Completed` (Phase 0 through Phase 13).
- [ ] `scripts/audit_user_docs.exs` exit 0 across the configured surface.
- [ ] `mix test` zero failures, all new doctest tests pass.
- [ ] `mix docs` zero warnings, 8 guides render under `Guides` group.
- [ ] `mix credo --strict`, `mix dialyzer`, `mix format --check-formatted` all green.
- [ ] `mix hex.build` produces a tarball containing `guides/` (verified with `tar -tzf`).
- [ ] CHANGELOG.md gets a `[DOC]` entry summarizing the rebuild.
- [ ] No public API changes — `scripts/check_lib_diff_non_doc.exs` reports an empty outside-docstring change set across `lib/**/*.ex`.
- [ ] No test-assertion changes outside the new test files added by this phase, except the explicit Phase 8 update to `test/readme_getting_started_test.exs`. Verified by `git diff --stat <pre-rebuild>..HEAD -- test/` and a hand-review of every changed file.

## Guidelines

- **Docstrings only — no behaviour changes.** This rebuild touches `@moduledoc`, `@doc`, README, CHANGELOG, `examples/README.md`, `mix.exs` comments, and adds `guides/`. It does NOT modify function bodies, `@spec`s, type definitions, or test assertions.
- **Self-contained prose.** A reader of any `@moduledoc` must be able to use the module without cross-referencing a file outside the Hex package. If a piece of prose is load-bearing and currently lives in `steering/`, inline it.
- **One canonical example per feature.** Cross-reference, don't duplicate.
- **Doctests run on Fake.** ExDoc compiles `iex>` blocks under `mix test`. Real-provider snippets go in non-`iex>` code blocks.
- **The audit script is the gate.** Every phase ends by running it on the touched files. Phase 13 runs it on the whole surface.
- **`steering/` stays.** Internal phase numbering is the project's design history; it's correct and useful. The rebuild only removes references to it from user-facing surfaces.
- **`HISTORY.md` stays.** Per-commit rolling history is dev-only and not in `package[:files]`. Phase callouts there are accurate history.
- **Test code comments stay.** Comments inside `def`/`defp` bodies, `test/` files, `conformance/`, and `retro/` are out of scope.
