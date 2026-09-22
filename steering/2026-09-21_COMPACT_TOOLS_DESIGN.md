# Phase 23: Compact Tools — Design Document

*Generated 2026-09-21 · Measured against: `1859dac`*

> **Goal:** Let a caller mark tools `compact: true` so the model is sent a one-line, CLI-style stub (summary + argument names + a bare object schema) instead of the full description and JSON Schema. The model can then pull the full definition on demand through one built-in `tool_help` meta-tool.
> **Outcome:** On the 8-tool fixture measured below, compact mode cuts tool-definition prompt tokens by about half on OpenAI (862 → 447 `prompt_tokens`, incl. the `tool_help` overhead). `request.tools` is `==` on every step of a run (Invariant 2), so provider prompt caches survive. The one exception is Anthropic with `response_format: json_schema`, whose adapter drops its own synthetic tool after it has been called (`inject_structured_output_tool/2`, `lib/allm/providers/anthropic.ex:1014-1024`), and that happens regardless of this design. It needs zero adapter changes, and a real model on each bundled provider completes a task that needs a compact tool (`examples/21_compact_tools.exs` exit 0).
> **Spec sections:** new **§40** (Compact tool disclosure). Amends **§5.2** (`ALLM.Tool` fields), **§16** (validation), **§27** (module tree).
> **Layers touched:** A (23.1), C-internal pure helper (23.2), C (23.3), docs (23.4), `[CHORE]` (23.5). One layer per sub-phase.

**Phase-number check (verified 2026-09-21):** `grep -rn "Phase 23\|PHASE_23\|§40" steering/ CLAUDE.md .work/HANDOFF.md` returns nothing, and `grep -n "^## " steering/allm_engine_session_streaming_spec_v0_2.md | tail -1` → `2678:## 39. v0.6 — Content moderation`. §37/§38 are reserved (audio/batch, per `steering/2026-08-31_PHASE_22_moderation.md:8`). This design takes **Phase 23** and **§40**.

## Status

| Phase | Description | Layer | Status |
|-------|-------------|-------|--------|
| 23.1 | `ALLM.Tool` gains `:compact` + `:summary`; validator + serializer | A | Not Started |
| 23.2 | `ALLM.ToolHelp` pure helper: summary, signature, stub projection, help rendering, required-arg check, meta-tool | C (internal, pure) | Not Started |
| 23.3 | Wire it into the chat loop (both paths) + `ToolRunner` interception | C | Not Started |
| 23.4 | Spec §40, `guides/tools.md` section, `examples/21_compact_tools.exs` live gate, CHANGELOG | docs | Not Started |
| 23.5 | `[CHORE]` sweep for deferrals raised in 23.1–23.4 | — | Not Started |

Per-sub-phase records go to `steering/2026-09-21_COMPACT_TOOLS_DESIGN_RECORDS.md` (created on first need).

---

## Assumptions

1. **★ The goal is fewer tokens in the model's context per step, not smaller HTTP bodies.** The two coincide for the client-side mechanism chosen here. They diverge for provider-native deferral, which still ships every full definition on the wire (Research §R1).
2. **★ Provider-neutral first.** ALLM has four wire translators: OpenAI Chat Completions (`to_openai_tool/2`, `lib/allm/providers/openai.ex:1631-1640`), OpenAI Responses (`:1642-1649`), Anthropic (`to_anthropic_tools/1`, `lib/allm/providers/anthropic.ex:916-920`) and Gemini (`to_gemini_tools/1`, `lib/allm/providers/gemini.ex:947-951`). Only two of those four have a native deferral feature, and each is gated by model (Research §R1, §R2). The opt-in must behave identically on all four, so the core mechanism is client-side. Native deferral is a possible later adapter optimisation over the same per-tool bit (Alternative A).
3. **The model sees every compact tool's name.** This design *compresses* tools. It does not *hide* them. A hidden tier (names withheld, reachable only through search) suits catalogs of hundreds of tools and is deliberately out of scope (Alternative C). The motivating example, `steering/examples/unllmtd_example.md` (a 1234-line tool registry, per-node generated tools at `:431`), needs compression before it needs search.
4. **Opt-in is per tool.** This follows the `:manual` precedent (Phase 18, `lib/allm/tool.ex:116-119`). A default of `false` leaves every existing caller byte-identical on the wire. No engine-wide or call-level switch is added (Alternative D).
5. **ALLM does not validate tool arguments against the schema today.** `grep -rn "ex_json_schema\|validate_args" lib/ mix.exs` returns nothing, and `ToolRunner.execute_one_tool/3` passes `tc.arguments || %{}` straight to the executor (`lib/allm/tool_runner.ex:530-534`). Compact mode adds only a top-level required-key check, and only for compact tools (Decision #5). It does not add a JSON Schema validator.
6. **Next minor release (expected v0.7.0) via `scripts/release.exs minor`.** The change is additive: two new defaulted struct fields and one new public module. No closed union changes.

---

## Research summary

This summarises a survey dated 2026-09-21. Every claim was taken from the linked primary source unless it is marked UNVERIFIED.

**R1. Anthropic tool search (native, GA).** Tools carry `"defer_loading": true`, and you add `{"type":"tool_search_tool_regex_20251119"}` or the `bm25` variant. The model sees only the non-deferred tools plus the search tool. The API then expands `tool_reference` blocks inline in the same response. A custom client-side search tool may return `[{"type":"tool_reference","tool_name":…}]` as a normal `tool_result`. Deferred definitions are still sent on every request. The docs say "the API excludes deferred tools from the system-prompt prefix … prompt caching is preserved." Support: Sonnet/Haiku/Opus 4.5 and later. The beta header was dropped on 2026-02-17. The Nov 2025 engineering post reports ~77K → ~8.7K tool tokens and selection accuracy of 49% → 74% (Opus 4) and 79.5% → 88.1% (Opus 4.5). A related beta, `mid-conversation-tool-changes-2026-07-01`, adds host-driven `tool_addition`/`tool_removal` system blocks.
Sources: [tool-search-tool](https://platform.claude.com/docs/en/agents-and-tools/tool-use/tool-search-tool), [caching](https://platform.claude.com/docs/en/agents-and-tools/tool-use/tool-use-with-prompt-caching), [advanced-tool-use](https://www.anthropic.com/engineering/advanced-tool-use), [release notes](https://platform.claude.com/docs/en/release-notes/overview), [mid-conversation system messages](https://platform.claude.com/docs/en/build-with-claude/mid-conversation-system-messages).

**R2. OpenAI tool search (native, Responses API only, gpt-5.4+).** This uses `{"type":"tool_search"}` plus per-function `defer_loading`, and optionally `namespace` grouping. For a lone deferred function "the model still sees the function name and description, so in practice tool search is mostly deferring the parameter schema." That is the same compression this design performs client-side. A client-executed variant returns full definitions in `tool_search_output`. Discovered tools are "injected at the end of the context window" so the cache survives. The docs don't mention Chat Completions, so treat it as unsupported there.
Sources: [tools-tool-search](https://developers.openai.com/api/docs/guides/tools-tool-search), [Agents SDK tools](https://openai.github.io/openai-agents-python/tools/).

**R3. Gemini has no native deferral.** The function-calling docs have none, and there is an open feature request.
Sources: [function-calling](https://ai.google.dev/gemini-api/docs/function-calling), [python-genai#2185](https://github.com/googleapis/python-genai/issues/2185).

**R4. Claude Code / Agent SDK.** Deferred tools are listed by name, and a `ToolSearch` meta-tool loads full schemas (`select:A,B` exact-name fetch, or keyword search). `ENABLE_TOOL_SEARCH=auto` turns it on at 10% of context. It is disabled behind non-first-party proxies because they drop `tool_reference` blocks. The docs name the cost: "one extra round-trip each time Claude searches."
Source: [agent-sdk/tool-search](https://code.claude.com/docs/en/agent-sdk/tool-search).

**R5. Agent Skills.** Level 1 is name + description (~100 tokens per skill) in the system prompt. Level 2 is the SKILL.md body, loaded when triggered. Level 3 is bundled files read on demand. This is progressive disclosure over a filesystem, and it needs bash.
Source: [agent-skills overview](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview).

**R6. MCP.** The spec has no lazy-schema primitive; SEP-1821 (a `query` parameter on `tools/list`) is still a draft. The official client best-practices page recommends a three-layer `search_tools` → `get_tool_details({name})` → execute flow. On caching it is explicit: adding tools mid-conversation "invalidates that cache, and the resulting miss can cost more tokens than the definitions you removed." Its remedies are to append definitions after the cache breakpoint or to keep the tools array stable.
Sources: [client best practices](https://modelcontextprotocol.io/docs/2026-07-28/develop/clients/client-best-practices), [SEP-1821](https://github.com/modelcontextprotocol/modelcontextprotocol/issues/1821).

**R7. Frameworks.**
- Pydantic AI marks tools per-tool with `defer_loading=True` and auto-injects a `ToolSearch` capability. It uses the native mechanism on Anthropic/OpenAI Responses and a local `search_tools` elsewhere. Its docs state plainly: "Native search preserves prompt caching; local search fallbacks invalidate the cached prefix on each discovery round."
- Spring AI 2.0 has a `ToolSearchToolCallingAdvisor`; discovered definitions are "added to the next request."
- `langgraph-bigtool` uses a `retrieve_tools` meta-tool.
- Vercel AI SDK provides `activeTools`/`prepareStep` for host-side subsetting.
- CLI-style: Zechner replaced 47 MCP tools (~32k tokens) with four CLIs plus a 225-token README.
- Code mode (Anthropic "code execution with MCP", Cloudflare) claims 98.7%+ savings but needs a sandbox.

Sources: [Pydantic AI tool search](https://pydantic.dev/docs/ai/capabilities/tool-search/), [Spring AI](https://docs.spring.io/spring-ai/reference/guides/dynamic-tool-search.html), [bigtool](https://github.com/langchain-ai/langgraph-bigtool), [AI SDK](https://ai-sdk.dev/docs/ai-sdk-core/tools-and-tool-calling), [Zechner](https://mariozechner.at/posts/2025-11-02-what-if-you-dont-need-mcp/), [code execution with MCP](https://www.anthropic.com/engineering/code-execution-with-mcp), [Cloudflare Code Mode](https://blog.cloudflare.com/code-mode/).

**R8. Accuracy evidence.**
- Anthropic says selection "degrades once you exceed 30–50 available tools" (R1).
- RAG-MCP (arXiv 2505.03275): retrieval reached 43.13% vs a 13.62% all-tools baseline.
- "How Many Tools Should an LLM Agent See?" (arXiv 2605.24660): adaptive shortlists averaged about 7 tools.
- No primary source measures how often models call a stub without first reading its schema. That risk is what Decision #5's usage-error feedback exists for, and the 23.4 live gate is the first measurement of it.

### Taxonomy of approaches

| | Pattern | Examples | Cache | Provider-neutral | Cost |
|---|---|---|---|---|---|
| A | Native deferral + server search | Anthropic `tool_search_tool_*`, OpenAI `tool_search` | kept | no (2 of 4 translators, new models only) | new Layer A content blocks (`tool_reference`, `tool_search_call`) in history |
| B | Client search meta-tool; discovered defs appended to the next request's `tools` | Spring AI, bigtool, Pydantic AI fallback | **broken on every discovery** | yes | array grows; extra round trip |
| **C** | **Stubs stay callable; a describe meta-tool returns the schema as text** | MCP `get_tool_details`, CLI `--help` | **kept** (array never changes) | **yes** | no provider-side schema enforcement for stubs |
| D | Single dispatcher `call_tool({name, args})` | MCP best practice, bash + `--help` | kept | yes | loses native tool calling; events and `:manual` see only the dispatcher name |
| E | Code mode | Cloudflare, Anthropic PTC | kept | no | needs a sandbox runtime |

**This design is pattern C.** It is the only row that is cache-stable, works on all four translators, and keeps every compact tool a first-class `%Tool{}`: its own `:tool_call_*` events, per-tool `:manual`, `on_tool_error`, and `ask_user`.

### Measured: what a stub saves (OpenAI, 2026-09-21)

The fixture is 8 GitHub-style tools, realistic descriptions, 3–7 params each. It was sent to `gpt-5.4-nano` Chat Completions with the user message `"hi"`, and `usage.prompt_tokens` was read back. The measuring script was a throwaway. The committed replacement is the fixture `examples/fixtures/compact_tools.exs` plus the step-1 token comparison in `examples/21_compact_tools.exs` (23.4), which re-measures every provider on every run. `none` is the no-tools baseline.

| Variant | Wire tools | `prompt_tokens` | vs full |
|---|---|---|---|
| none | — | 7 | |
| full | 8 full defs | 862 | — |
| shallow stub (top-level `{type}` per prop, no descriptions) + `tool_help` | 9 | 598 | −31% |
| **signature stub (summary + `Args: a, b [c, d]`, schema `{"type":"object"}`) + `tool_help`** | 9 | **447** | **−49%** |
| bare stub (summary, `{"type":"object"}`) + `tool_help` | 9 | 344 | −61% |
| `tool_help` alone | 1 | 172 | |

The per-tool marginal cost is roughly 94 tokens full, 53 shallow, 34 signature and 21 bare. This is derived from the rows above and assumes a ~105-token fixed OpenAI tool preamble plus ~60 tokens for `tool_help`. The preamble split is UNVERIFIED; the totals are measured. The saving grows with tool count and with description length. This fixture's descriptions are short relative to typical MCP tools.

### Measured: which stub schemas the providers accept (2026-09-21)

| Schema | Gemini `gemini-2.5-flash` / `gemini-3-flash-preview` | OpenAI `gpt-5.4-nano` Chat + Responses | Anthropic |
|---|---|---|---|
| `{"type":"object"}` (top level, no properties) | 200 / 200 | 200 / 200 | **UNVERIFIED** (account had no API credit, so the request returned 400 "credit balance is too low") |
| nested `{"type":"object"}` property | — / 200 | 200 | UNVERIFIED |
| `array` property without `items` | 400 `properties[b].items: missing field` | 200 | UNVERIFIED |
| invented key `bogusField` in parameters (negative control) | 400 `Unknown name "bogusField"` | — | — |

Gemini validates parameter schemas (the control proves it); OpenAI accepted even the array-without-items case, so OpenAI acceptance is weak evidence. **The chosen stub schema is exactly `{"type":"object"}`, the one shape accepted everywhere it was tested.** Anthropic's acceptance is the one inferred-not-confirmed row, and the 23.4 live gate is its falsifier.

### Measured: whether models fill in arguments on a bare-schema stub (2026-09-21)

Acceptance (HTTP 200) doesn't show that the model will fill in arguments when the schema declares no properties. So the 8 signature stubs plus `tool_help` were sent with the user message *"File an issue in acme/web titled 'Login button broken' with label bug."*:

| Model | Calls | `create_issue` arguments returned |
|---|---|---|
| `gpt-5.4-nano` (Chat Completions) | 3 | `{"repo":"acme/web","title":"Login button broken","labels":["bug"]}` ×2; the same plus `"body":""` ×1 |
| `gemini-3-flash-preview` | 2 | `{repo, title, labels: ["bug"]}` ×2 |
| `gemini-2.5-flash` | 2 | `{repo, title, labels: ["bug"]}` ×2 |

Results:
- All 7 calls went straight to the stub, without `tool_help`.
- All 7 had every required argument filled in.
- All 7 sent `labels` as an array, although the stub carries no type information.

Gemini does *not* strip arguments that a bare `{"type":"object"}` doesn't declare. Anthropic is UNVERIFIED (no credit), and the 23.4 gate re-measures it together with the others. This is a single easy prompt; the gate also records whether `tool_help` was called.

---

## Alternatives Considered

### A. Native provider deferral (pattern A) instead of client-side stubs

| Option | Trade-off |
|---|---|
| A1: native only | Works on 2 of 4 translators and only for newer models (Anthropic 4.5+; OpenAI Responses + gpt-5.4+). Needs new Layer A content-block types for `tool_reference` / `tool_search_call` / `tool_search_output` so they round-trip in `%Thread{}`, which crosses Layer A and every translator. It is a larger change than this whole design. |
| **A2: client-side stubs everywhere (chosen)** | Uniform behaviour, zero adapter changes, cache-stable. Costs one extra round trip when the model needs `tool_help`. |
| A3: A2 now; adapters later map `compact: true` onto native deferral where supported | **Explicitly left open.** The per-tool bit is named for the neutral concept, not a provider feature. A later adapter phase can honour it natively without an API change. The semantics differ, though: a natively deferred tool is *invisible* until searched, while a compact stub is visible. So that phase owns its own Decision. Not designed here. |

### B. How much of the schema a stub keeps

The measured options are in the table above. **The signature stub is chosen.** It is the CLI "usage line": the model knows the argument names, and which are required, before its first call, so most calls need no `tool_help` round trip. It costs about 13 tokens per tool more than bare. A shallow schema buys provider-side type structure for about 19 more tokens per tool. It also re-exposes the Gemini `items` rejection, since each `array` property must carry `items`. That cost is not justified when full-tool arguments aren't validated by ALLM either (Assumption 5).

### C. A hidden tier: names withheld, keyword search (pattern B/A′)

Out of scope. It needs a search strategy (regex, BM25 or embeddings, all product decisions). Done client-side it either grows the tools array (breaking the cache, R6/R7) or needs D-style dispatch. A later phase can add `disclosure: :hidden` beside `compact` if a consumer needs catalogs larger than ~50 tools (R8).

### D. Where the opt-in lives

| Option | Trade-off |
|---|---|
| **D1: per-tool `compact: true` (chosen)** | Mirrors `:manual`. Callers keep their 3–5 hottest tools full, following the R1 guidance "keep your 3–5 most-used tools non-deferred", and compact the long tail. It is a single channel, so no opts forwarding is needed through `build_runner_opts/…` (`lib/allm/chat.ex:2116-2135` forwards a closed key list). |
| D2: call- or engine-level `tool_disclosure: :compact` | This would be a second channel that must reach both `build_request/4` and `ToolRunner`, which means extending that closed forwarding list and `Engine.resolve_params/2`'s deny-list. `Enum.map(tools, &%{&1 \| compact: true})` gives the same result today. It can be added later without breaking anything. |

### E. How `tool_help` executes

| Option | Trade-off |
|---|---|
| E1: a `fn` handler closing over the tool list | Not serializable. It routes through the *configured* executor, and a custom executor that dispatches by name (the unllmtd registry shape) would see an unknown `tool_help`. |
| **E2: marker-identified built-in, intercepted in `ToolRunner` (chosen)** | The meta-tool is plain data (`handler: nil`, marker in `:metadata`), so it round-trips. `ToolRunner` already holds the full resolved list in `ctx.tools` (`lib/allm/tool_runner.ex:344`). It bypasses any custom executor. |

---

## Overview

A compact tool is an ordinary `%ALLM.Tool{}` with `compact: true`. When the chat loop builds a request, the resolved tool list goes through `ALLM.ToolHelp`. Every compact tool is replaced on the wire by a stub with the same name, a one-line description that ends in an argument hint, and the schema `{"type":"object"}`. One built-in `tool_help` tool is appended whenever at least one compact tool is present. Execution still uses the full `%Tool{}`: a model call to `tool_help` gets back the full descriptions and schemas as text, and a call to a compact tool that is missing required arguments gets back a usage error carrying that tool's help. This is the CLI analogue of printing usage on misuse. Nothing about the wire array changes between steps, so provider prompt caches hold.

### Deliverables

- `ALLM.Tool`: new fields `:compact` (boolean, default `false`) and `:summary` (`String.t() | nil`, default `nil`).
- `ALLM.Validate.tool/1` gains the rule `{:summary, :not_a_string}`.
- New public module `ALLM.ToolHelp`: stub projection, help rendering, the meta-tool, and a manual-mode helper `answer/2`.
- `ALLM.Chat` routes the six execution-side tool resolutions through one private `effective_tools/2`; `build_request/4` projects the wire list with `ToolHelp.project/2`.
- `ALLM.ToolRunner.execute_one_tool/3` intercepts the meta-tool and runs the required-key check for compact tools.
- Spec §40, a `guides/tools.md` section, `examples/21_compact_tools.exs`, and a CHANGELOG entry.

### Spec coverage

- New §40 (Compact tool disclosure).
- §5.2 gains the two fields.
- §16 gains the validation row.
- §27 gains `tool_help.ex`.

### Layer demonstration

**Layer A (serializable data):**

```elixir
tool = ALLM.Tool.new(name: "create_issue", description: long_text, schema: schema, compact: true)
tool |> :erlang.term_to_binary() |> :erlang.binary_to_term() == tool   # true
```

**Pure helper (no engine, no adapter):**

```elixir
[stub, meta] = ALLM.ToolHelp.project([tool], nil)
stub.description   # "Create a new issue in a repository. Args: repo, title [assignees, body, labels, milestone] [compact]"
meta.name          # "tool_help"
```

**Layer C (stateless execution):**

```elixir
engine = ALLM.Engine.new(adapter: ALLM.Providers.Fake, adapter_opts: [scripts: [...]], tools: [tool])
{:ok, result} = ALLM.chat(engine, [ALLM.user("File a bug about the login page in acme/web")])
# the model may call tool_help first; the loop runs it like any other tool
```

**Layer D:** unchanged. `ALLM.Session` stores no tools (`lib/allm/session.ex:170-179`), and `tool_help` exchanges live in `session.thread` as ordinary `:tool` messages, which already serialize.

### Prerequisites

None. This builds on HEAD `1859dac`.

### Out of scope

- **Native provider deferral** (Alternative A3).
- **A hidden or search tier** (Alternative C).
- **Call-level or engine-level switches** (Alternative D2).
- **Full JSON Schema argument validation** (Assumption 5). Only the required-key check ships.
- **`ALLM.generate/3` / `stream_generate/3` with a caller-built `%Request{}`.** These paths run no tools and never pass through `build_request/4`, so a caller who hand-builds `request.tools` gets exactly what they built. Compact projection is a chat-loop feature (`step`, `stream_step`, `chat`, `stream`, `Session.*`).
- **Changing the unknown-tool-name path.** `EngineError :unknown_tool` still fails the step (`lib/allm/chat.ex:1550-1562`). Compact mode adds no new exposure, because every compact tool's name is on the wire.
- **Telemetry additions.** The `tool_help` call already emits the standard `:tool_execution_*` events.
- **An issue that predates this design: call-level `:tools` leak into `structured_finalize` pass 2.** Pass 2 zeroes `engine.tools` (`lib/allm/chat.ex:487`, `:749`), but `pass_2_opts` keeps `opts[:tools]`, and `Engine.resolve_tools/2` puts them back (`lib/allm/engine.ex:451-458`). Compact mode inherits this behaviour (pass 2 would carry stubs + `tool_help`). It doesn't cause it. 23.3 files an `/asks` `[BUG]` with a reproducer; the fix is out of this Module Tree. Test row 16 therefore puts compact tools on the engine.
- **`check_args/2` for caller-executed tools.** Under whole-loop or per-tool manual, compact tools that go to the caller never pass through `ToolRunner`, so they get no usage-error safety net. Callers can call the public `ALLM.ToolHelp.check_args/2` themselves; the moduledoc says so.

### Non-obvious decisions

1. **Stubs keep their real names and stay directly callable.** The model can skip `tool_help` whenever the argument hint is enough. The first-call cost is zero extra round trips in the common case, compared with one round trip per discovery in patterns A/B.
   `Docs target: @moduledoc ALLM.ToolHelp`
2. **The wire `tools` array is a pure function of (resolved tools, `tool_choice`)**, so it is identical on every step of a run. This is the cache-preservation invariant (R6). Pattern B would break it on every discovery.
   `Docs target: @moduledoc ALLM.ToolHelp`
3. **A `tool_choice` naming a compact tool sends that one tool in full.** Forcing a call to a stub with a bare schema would make the model guess arguments with no chance to ask first. The forced name is taken from every single-tool shape an adapter accepts:
   - a binary name (`@type tool_choice`, `lib/allm/request.ex:48`);
   - `{:tool, name}`, which the OpenAI (`maybe_put_tool_choice`, `lib/allm/providers/openai.ex:1651-1681`) and Gemini (`to_gemini_tool_config/1`, `lib/allm/providers/gemini.ex:995-1011`) adapters accept although it is outside the `@type`;
   - Anthropic's `%{"type" => "tool", "name" => n}` / `%{type: "tool", name: n}` (`to_anthropic_tool_choice/1`, `lib/allm/providers/anthropic.ex:957-978`);
   - OpenAI Chat's `%{"type" => "function", "function" => %{"name" => n}}` and Responses' flat `%{"type" => "function", "name" => n}`, in string or atom keys;
   - Gemini's native `%{"mode" => "ANY", "allowedFunctionNames" => [n]}` with exactly one name, in string or atom keys (passed through verbatim by `to_gemini_tool_config(%{} = wire)`, `lib/allm/providers/gemini.ex:1008`).

   `:auto`/`:none`/`:required`, and any other map, leave every stub compact. A Gemini `allowedFunctionNames` list with more than one name that omits `"tool_help"` leaves stubs compact *and* makes `tool_help` unreachable; the `ALLM.ToolHelp` moduledoc documents this.
   `Docs target: @doc ALLM.ToolHelp.project/2`
4. **The meta-tool is recognised by a metadata marker, not by name.** When no compact tool is present, a user tool named `tool_help` is an ordinary tool. When one is present, the user's tool and the injected one collide, and the existing duplicate-name rule rejects the request pre-flight: `{:tools, :duplicate_name}`, `lib/allm/validate.ex:417-425`, run at `lib/allm/stream_runner.ex:131`. No new validation code is needed.
   `Docs target: @moduledoc ALLM.ToolHelp`
5. **A compact tool called without a required top-level argument returns a usage error instead of running the handler.** The error content carries the tool's full help, so the model self-corrects in one round trip even if it never called `tool_help`. It is routed as a handler `{:error, _}`, so the caller's `on_tool_error` policy applies unchanged: `:continue` (the default) feeds it back; `:halt` stops the loop. Full (non-compact) tools are untouched, so their behaviour is byte-identical to today.
   `Docs target: @doc ALLM.ToolHelp.check_args/2`
6. **Under whole-loop `mode: :manual`, `tool_help` calls surface to the caller like any other call.** The loop does not auto-run them, because whole-loop manual means "the caller runs everything" (§12). `ALLM.ToolHelp.answer/2` builds the content string to submit. Under per-tool manual (§12.4) the meta-tool has `manual: false`, so it is partitioned into the auto bucket and runs.
   `Docs target: @doc ALLM.ToolHelp.answer/2`

---

## Behaviour & Type Contracts

### Layer A: `ALLM.Tool` (MODIFY, 23.1)

```elixir
@type t :: %__MODULE__{
        name: String.t(),
        description: String.t(),
        schema: schema(),
        handler: handler() | nil,
        manual: boolean(),
        compact: boolean(),          # NEW, default false
        summary: String.t() | nil,   # NEW, default nil
        metadata: map()
      }

@enforce_keys [:name, :description, :schema]          # unchanged
defstruct [:name, :description, :schema, :handler, manual: false, compact: false, summary: nil, metadata: %{}]
```

- **`new/1` guards `:compact`.** It follows the `:manual` guard form (`lib/allm/tool.ex:116-119`: `unless is_boolean(tool.manual) do raise ArgumentError, …`). `Tool.new(compact: nil)` and `Tool.new(compact: "yes")` raise `ArgumentError` with the message `"ALLM.Tool :compact must be a boolean, got: <inspect>"`. The guard is needed because `struct!/2` accepts an explicit `nil` over a default (CLAUDE.md, type-contract-vs-test-plan drift).
- **`new/1` does NOT guard `:summary`.** A non-string summary is caught by `Validate.tool/1` (below). This matches the default "Layer-A constructors are `struct!/2` pass-throughs" rule.
- **`__from_tagged__/1`** adds `compact: data["compact"] || false` and `summary: data["summary"]`. The `||` idiom is safe here because both defaults are falsy (CLAUDE.md `__from_tagged__` rule).
- `ALLM.Tool` is already registered in `ALLM.Serializer` `@known_modules` (`lib/allm/serializer.ex:67`) and `@layer_a` (`test/layer_a_docs_test.exs:22`). No registration change is needed. The new `@moduledoc`/field prose must pass that file's banned-token audit (no `§`, no `Phase N`).

### Layer A: `ALLM.Validate.tool/1` rule (MODIFY, 23.1)

| Field path | Reason atom | Hard-reject? | Fires when |
|---|---|---|---|
| `[:summary]` (via `Validate.tool/1`); `[:tools, idx, :summary]` (via `Validate.request/1`, prefixed by `collect_tool_errors/2`, `lib/allm/validate.ex:563-578`) | `:not_a_string` | no | `summary` is neither `nil` nor a binary |

`:compact` gets no validator rule, mirroring `:manual`, which has none either (`grep -n manual lib/allm/validate.ex` → no hits). The constructor guard is its only gate. A hand-built `%Tool{compact: :yes}` passes validation. `ToolHelp` then treats every value except `true` as not-compact (`compact == true` checks, below), so the failure mode is "sent in full", which is the safe direction.

### `ALLM.ToolHelp` (NEW, 23.2): pure, public

```elixir
defmodule ALLM.ToolHelp do
  @meta_tool_name "tool_help"
  # marker: metadata %{"allm_builtin" => "tool_help"}; string-keyed so it survives a JSON round-trip

  # Public, documented (@doc + @spec + doctest):
  @spec meta_tool() :: ALLM.Tool.t()
  @spec meta_tool?(ALLM.Tool.t()) :: boolean()
  @spec compact?(ALLM.Tool.t()) :: boolean()                 # tool.compact == true
  @spec project([ALLM.Tool.t()], ALLM.Request.tool_choice() | {:tool, String.t()}) :: [ALLM.Tool.t()]
  @spec render([ALLM.Tool.t()], map()) :: String.t()
  @spec answer([ALLM.Tool.t()], ALLM.ToolCall.t()) :: String.t()
  @spec check_args(ALLM.Tool.t(), map()) :: :ok | {:error, String.t()}

  # Test seams (@doc false + @spec, per the CLAUDE.md public-test-seam pattern):
  @spec summary(ALLM.Tool.t()) :: String.t()
  @spec signature(ALLM.Tool.t()) :: String.t() | nil
  @spec stub(ALLM.Tool.t()) :: ALLM.Tool.t()
  @spec with_meta_tool([ALLM.Tool.t()]) :: [ALLM.Tool.t()]
end
```

These are the normative semantics. Each is pinned by the 23.2 Test Plan row of the same name.

- **`meta_tool/0`** returns:

  ```elixir
  %Tool{
    name: "tool_help",
    description: @meta_description,
    schema: %{
      "type" => "object",
      "properties" => %{"names" => %{"type" => "array", "items" => %{"type" => "string"}}},
      "required" => ["names"]
    },
    handler: nil,
    manual: false,
    compact: false,
    metadata: %{"allm_builtin" => "tool_help"}
  }
  ```

  `@meta_description` is exactly: `"Tools whose description ends in [compact] are summarised. Call tool_help with their names to get each one's full description and JSON parameter schema before calling it, unless the Args hint is enough."`
  - The `items` key is required by Gemini (measured above).
- **`meta_tool?/1`** is `match?(%Tool{metadata: %{"allm_builtin" => "tool_help"}}, tool)`. It never raises, even on a hand-built `%Tool{metadata: nil}`: after 23.3 it runs on every tool call, compact or not, ahead of the executor's rescue (`lib/allm/tool_runner.ex:530-534`), so a raise here would break invariant 3. The marker is string-keyed because `Tool.__from_tagged__/1` hydrates `metadata` verbatim from JSON (`lib/allm/tool.ex:138`). An atom-keyed marker would come back as strings, and `meta_tool?/1` would go false after a JSON round-trip.
- **`summary/1`** returns `tool.summary` when it is a non-empty binary. Otherwise it derives one from `tool.description`, in this order:
  1. Trim.
  2. Take the text up to and including the first `.`, `!` or `?` that is followed by whitespace or end of string. Stop earlier if a newline comes first.
  3. If the result exceeds 160 graphemes, take the first 157 plus `"..."`.
  4. An empty description yields `""`.
- **`signature/1`** returns `nil` unless `tool.schema["properties"]` is a map. Otherwise it returns `"Args: " <> required <> optional`, where:
  - `required` is the names in `schema["required"]` order (a list, else `[]`), joined by `", "`, keeping only names present in `properties`;
  - `optional` is the remaining property names sorted with `Enum.sort/1`, joined by `", "` and wrapped as `" [" <> … <> "]"`, and omitted when there are none;
  - an empty `properties` map yields `"Args: none"`.
  - Property order is sorted because an Elixir map never preserves authoring or JSON-source order. Maps with ≤32 keys iterate in key order; larger maps iterate in hash order. An explicit sort makes the output a function of the key *set*, which is what invariant 2 needs.
- **`stub/1`** returns `%{tool | description: Enum.join(Enum.reject([summary(tool), signature(tool), "[compact]"], &(&1 in [nil, ""])), " "), schema: %{"type" => "object"}, handler: nil}`. It keeps `name`, `compact`, `manual`, `summary` and `metadata`.
  - `handler: nil` keeps the wire list fun-free.
  - **Measured:** `{"type":"object"}` is accepted by Gemini and OpenAI; Anthropic is UNVERIFIED (Research).
- **`with_meta_tool/1`** is the input unchanged when no element is `compact?/1`. Otherwise it is the input `++ [meta_tool()]`.
  - It is idempotent: if a `meta_tool?/1` element is already present, it returns the input unchanged. This keeps it safe to call on an already-expanded list.
- **`project/2`** is `with_meta_tool(tools)` with each `compact?/1` tool replaced by `stub/1`. The exception is the tool whose name equals the forced name that the private `forced_name/1` extracts from `tool_choice` (the shapes are listed under Decision #3). That tool is sent unchanged, in full.
  - Order is preserved.
  - **Invariant: `project/2` is deterministic.** Equal inputs give equal outputs. This is the cache invariant (Decision #2).
- **`render/2`** takes the full tool list and the raw `tool_help` arguments.
  - **Normalising `names`:** accept `%{"names" => [binary]}`, `%{"names" => binary}` (wrapped into a one-element list), and the atom-keyed equivalents. Anything else yields the string `"tool_help expects {\"names\": [\"tool_name\", ...]}. Compact tools: " <> comma-joined compact names`.
  - **Output:** one section per requested name, in request order, deduplicated, joined by `"\n\n"`.
  - **Known tool:** `"## <name>\n<description>\nParameters (JSON Schema): <Jason.encode!(schema)>"`. The encoding is compact, not pretty-printed, to save tokens. It works for any tool in the list, compact or not.
  - **Unknown name:** `"## <name>\nUnknown tool. Compact tools: <comma-joined compact names>"`.
  - **Never raises.** `Jason.encode!/1` on a schema can raise, because `Validate.tool/1` only checks `is_map` (`lib/allm/validate.ex:509-510`). On `Jason.EncodeError` or `Protocol.UndefinedError`, the section falls back to `inspect(schema)`.
  - It never includes the meta-tool itself in the "Compact tools" list.
- **`answer/2`** is `render(tools, tool_call.arguments || %{})`. It is the manual-mode helper (Decision #6).
- **`check_args/2`**:
  - Returns `:ok` unless `compact?(tool)`.
  - For a compact tool, it returns `{:error, "missing required argument(s): a, b\n\n" <> render([tool], %{"names" => [tool.name]})}` when any name in `schema["required"]` (a list, else `[]`) is absent from `args`. A name counts as present if either the string key or an existing atom with the same name (`String.to_existing_atom/1`, rescuing `ArgumentError`) is a key. This matters because `Fake` passes scripted atom-keyed arguments through verbatim (e.g. `test/allm/providers/fake_stream_test.exs:44`). Missing names are listed in `required` order. Otherwise it returns `:ok`.
  - **The reason is a binary, not a map, because of the encoder.** The default `ToolResultEncoder.JSON` encodes `{:error, binary}` as `Jason.encode!(%{error: reason})`, but a non-binary reason as `%{error: inspect(reason)}` (`lib/allm/tool_result_encoder/json.ex:61-62`, reached via `ToolRunner.encode_error/2` at `lib/allm/tool_runner.ex:813-818`). A map would reach the model as an inspected Elixir term. With a binary, the `:tool` content is `{"error":"missing required argument(s): …\n\n## <name>\n…"}`.
  - It checks key presence only: no types, no nesting, no unknown-key rejection.
  - **Never raises.** Non-map `args` is treated as `%{}`; a non-map `schema` (or a non-list `required`) has no required keys.

Every value above has one home: this block. Test Plans and checklists reference it by function name.

### Layer C wiring (23.3)

- **`ALLM.Chat` private `effective_tools(engine, opts)`** is `engine |> Engine.resolve_tools(opts) |> ToolHelp.with_meta_tool()`. This is the **execution-side** list.
  - At `1859dac`, `git grep -n 'Engine.resolve_tools(' lib/allm/chat.ex` (call form; the bare name also matches a comment at `:485`) gives 7 hits: `:1087`, `:1177`, `:1222`, `:1388`, `:1416`, `:1471`, `:2010`.
  - The six execution sites route through `effective_tools/2`: non-streaming `run_auto_tool_calls_step/5` (`:1087`), `run_tools_then_halt/7` (`:1177`), `run_tools_non_streaming/5` (`:1222`); streaming `dispatch_partitioned_stream/3` (`:1388`), `start_phase_b/3` (`:1416`), `start_phase_b_partial/5` (`:1471`). The streaming pure-manual arm (`start_phase_c_manual_only`) resolves no tools and runs no unknown-tool preflight, which is correct because every name there is a known manual tool.
- **`build_request/4`** (the seventh hit, `:2010`) is shared by both paths; the function spans `lib/allm/chat.ex:1999-2031`. It builds the **wire-side** list: `tools: ToolHelp.project(Engine.resolve_tools(engine, opts), Keyword.get(opts, :tool_choice))`. `project/2` performs `with_meta_tool` itself.
  - Post-condition: the grep returns exactly **2** hits, one inside `effective_tools/2` and one inside `build_request/4`.
- **`Engine.resolve_tools/2`'s public contract is unchanged.** Its doctest at `lib/allm/engine.ex:441-448` still holds. The meta-tool is injected only inside `ALLM.Chat`, so a caller of `Engine.resolve_tools/2`, and `Engine.merge_opts/2`'s `maybe_put_tools/2` (`lib/allm/engine.ex:575-580`), never see it.
- **`ToolRunner.execute_one_tool/3`** (the private `defp` beneath its `@spec`, ~`lib/allm/tool_runner.ex:528-537`) becomes:
  1. If `ToolHelp.meta_tool?(tool)`, then `result = {:ok, ToolHelp.render(ctx.tools, args)}`. This is not routed to `ctx.executor`.
  2. Otherwise, if `ToolHelp.check_args(tool, args)` returns `{:error, usage}`, then `result = {:error, usage}`.
  3. Otherwise, run the existing executor call.
  4. In every case, `dispatch_handler_return(result, tc, ctx)` follows, unchanged.

  Here `args = tc.arguments || %{}`. The `ctx.tools` field already exists (`build_ctx/3`, `:344`).
  - This also applies to direct callers of the public `ToolRunner.run_tool_calls/3` / `stream_tool_calls/3`: a compact tool gets `check_args` there too. `tool_help` is intercepted only if the caller's list contains `meta_tool/0`. Document this in the `ALLM.ToolHelp` moduledoc.
  - **Encoding (read at design time):** `render/2` returns a binary, and the JSON encoder passes binaries through verbatim (`lib/allm/tool_result_encoder/json.ex:59-63`), so with the default encoder the `:tool` message content is exactly the rendered text. A custom `tool_result_encoder` receives the same binary and may wrap it. The usage text follows the existing `{:error, _}` → `route_error` path (`lib/allm/tool_runner.ex:645-705`).
- **No change to `ALLM.Event`**, `StreamCollector`, adapters, `Fake`, `Engine`, `Session`, or `Request`. The `tool_help` call rides the existing `:tool_call_*`/`:tool_execution_*`/`:tool_result_encoded` variants. No closed union changes.

### Cross-function invariants

1. **Wire/execution split.** `build_request/4` sends `project/2` output. Every execution site sees `with_meta_tool/1` output, which is the *full* tools. For any tool name `n`, the wire and execution lists both contain `n` or both lack it. This is why the `:unknown_tool` preflight (`lib/allm/chat.ex:1550-1562`) never rejects `tool_help` or a stub's name.
2. **Cache stability.** On a multi-step `chat/3` run with fixed `opts`, `request.tools` is equal (`==`) on every step. Follows from `project/2`'s determinism plus the fact that `opts` and the engine are fixed across steps (`lib/allm/chat.ex:827-831` non-streaming; `:1846` streaming).
3. **Compact-off is a no-op.** With no `compact: true` tool, `project/2` and `with_meta_tool/1` return their input unchanged (`==`), and `check_args/2` is `:ok`. Every existing test stays green unmodified. The contract-flip audit (DESIGN.md rule 9) therefore has no inverted assertions to find. 23.3 records the `git grep` that confirms this.

---

## Error Contract

| Function | Result | Recovery guidance |
|---|---|---|
| `Tool.new/1` with non-boolean `:compact` | raises `ArgumentError` | Programming error; pass a boolean. |
| `Validate.request/1` (pre-flight, `stream_runner.ex:131`) with non-binary `summary` | `{:error, %ValidationError{errors: [{[:tools, i, :summary], :not_a_string}]}}` | Fix the tool definition. |
| `chat/3` & friends when a user tool is named `tool_help` and ≥1 compact tool is present | `{:error, %ValidationError{errors: [{:tools, :duplicate_name}]}}` at the call site (pre-flight) | Rename the user tool. Documented in the `ALLM.ToolHelp` moduledoc. |
| Model calls a compact tool without a required argument | `{:error, <usage text>}` (per `check_args/2`), routed through `on_tool_error` | `:continue` feeds it back to the model; `:halt` stops with `halted_reason: :tool_error`. |
| Model calls `tool_help` with malformed args or unknown names | `{:ok, <explanatory text>}` | None needed; this is not an error. |

No new error reason atoms (DESIGN.md rule 13).

---

## Module Tree

```
lib/allm/
├── tool.ex                         (MODIFY — 23.1, :compact + :summary fields, guard, __from_tagged__, moduledoc)
├── validate.ex                     (MODIFY — 23.1, {:summary, :not_a_string} rule in tool/1)
├── tool_help.ex                    (NEW — 23.2)
├── chat.ex                         (MODIFY — 23.3, effective_tools/2 at 6 sites + project/2 in build_request/4)
└── tool_runner.ex                  (MODIFY — 23.3, execute_one_tool/3 interception + check_args)

test/allm/
├── tool_test.exs                   (MODIFY — 23.1, new-field defaults, guard, round-trip)
├── validate_test.exs               (MODIFY — 23.1, :summary rule; `git grep -ln 'Validate.tool(' test/` → this file, 2026-09-21)
├── tool_help_test.exs              (NEW — 23.2)
├── chat/compact_tools_test.exs     (NEW — 23.3, non-streaming + streaming matrix, cache invariant)
├── tool_runner_test.exs            (MODIFY — 23.3, interception + usage error + custom-executor bypass)
└── chat_equivalence_test.exs       (MODIFY — 23.3, one compact-tools scripted fixture row)

examples/fixtures/compact_tools.exs (NEW — 23.2, the 8-tool fixture from Research as plain data: `CompactToolsFixture.tools/0` → list of `%{name, description, schema}` maps; `mix run` examples cannot see `test/support` because `elixirc_paths(_) → ["lib"]` at `mix.exs:30-31`)
test/test_helper.exs                (MODIFY — 23.2, `Code.require_file("../examples/fixtures/compact_tools.exs", __DIR__)` once, so test modules don't redefine it)

guides/tools.md                     (MODIFY — 23.4, "Compact tools" section, iex> blocks over Fake)
steering/allm_engine_session_streaming_spec_v0_2.md (MODIFY — 23.4, §40 + §5.2/§16/§27 amendments)
examples/21_compact_tools.exs       (NEW — 23.4, live gate, all three providers)
examples/README.md                  (MODIFY — 23.4, list script 21)
mix.exs                             (MODIFY — 23.2, ALLM.ToolHelp in groups_for_modules `Runtime:` group, mix.exs:172)
CHANGELOG.md                        (MODIFY — 23.4)
```

### Repo-wide audit-gate obligations

| Gate | Fires on | Sub-phase row |
|---|---|---|
| `test/groups_for_modules_audit_test.exs` (closed) | new public module `ALLM.ToolHelp` | 23.2 `mix.exs` row |
| `test/layer_a_docs_test.exs` (open) | `ALLM.Tool` already listed (`:22`); new doc prose must be banned-token clean | 23.1 |
| `test/allm_facade_doctest_inventory_test.exs` (open) | no new `ALLM.*` facade function, so it does not fire | — |
| `test/guides_test.exs` / `test/guides_doctest_test.exs` / fence-compile gate | `guides/tools.md` already registered; new `iex>` blocks run, new fences compile | 23.4 |
| `test/package_files_extras_consistency_test.exs` | no new guide, so it does not fire | — |

### Path-existence sanity check (run 2026-09-21)

`ls lib/allm/ test/allm/ test/allm/chat/ examples/ guides/` all exist. `test/allm/chat/` exists per the Explore listing. `examples/21_*` is free: the last script is `20_moderate_image.exs`, and `examples/run_all.exs:40` discovers scripts by the wildcard `[0-9][0-9]_*.exs`, so no registration is needed.

---

## Phases

### Phase 23.1: `ALLM.Tool` fields + validation (Layer A)

**Test Plan (write first)**, `test/allm/tool_test.exs`:
- `new/1` defaults: `compact == false`, `summary == nil`.
- `new(compact: true)` sets it; `new(compact: nil)` and `new(compact: "yes")` raise `ArgumentError` with the contract message.
- `new(summary: 123)` does **not** raise (no guard, per contract).
- ETF and JSON round-trip (`Jason.encode!/1` → `ALLM.Serializer` hydrate) of a tool with `compact: true, summary: "s"` returns an equal struct. Pin both **non-default** values.
- JSON decoding of a pre-23.1 encoded tool, with no `compact`/`summary` keys, yields `compact: false, summary: nil`.

Validator tests:
- `Validate.tool/1` on `summary: 123` → `{:error, %ValidationError{errors: [{:summary, :not_a_string}]}}`.
- `summary: nil` and `summary: "x"` are both `:ok`.
- `Validate.request/1` prefixes the path as `[:tools, i, :summary]`.

**Implementation checklist**
- [ ] Add the fields, `@type`, guard, and `__from_tagged__/1` lines per the contract block.
- [ ] Add `validate_tool_summary/2` to `tool/1`'s pipeline (`lib/allm/validate.ex:175-177`), with its definition beside `validate_tool_schema/2` (`:509-510`).
- [ ] `@moduledoc` paragraph on compact tools pointing to `ALLM.ToolHelp` (banned-token clean).

**Verification**
```bash
mix test test/allm/tool_test.exs && mix test
mix test --seed 0
mix format --check-formatted && mix credo --strict && mix dialyzer
```
Success: all green; `mix test test/layer_a_docs_test.exs` green.

### Phase 23.2: `ALLM.ToolHelp` (pure helper)

**Test Plan (write first)**, `test/allm/tool_help_test.exs`. Every row asserts against the contract block's semantics for the named function:
- `summary/1`:
  - explicit summary wins;
  - first-sentence derivation (period + space);
  - `!` / `?` terminators;
  - newline before period;
  - no terminator → whole trimmed text;
  - a 200-char single sentence → 157 graphemes + `"..."`;
  - `"v1.2 is great. More."` → `"v1.2 is great."` (a period not followed by whitespace doesn't split);
  - empty description → `""`;
  - `"Use e.g. this. More."` → `"Use e.g."`. This pins the documented limitation that abbreviations split. Callers who mind set `:summary`.
- `signature/1`:
  - required in `required` order + sorted optional;
  - no required;
  - no optional (no bracket group);
  - empty properties → `"Args: none"`;
  - missing properties → `nil`;
  - a `required` name absent from properties is dropped;
  - a 40-property schema whose `properties` map is built from a reversed key list lists its optional names in `Enum.sort/1` order.
- `stub/1`: the exact description for the 8-tool fixture's `create_issue` (use the Layer demonstration string); schema `%{"type" => "object"}`; handler nil; name/compact/manual/metadata preserved; a tool with an empty description and no properties → description `"[compact]"`.
- `with_meta_tool/1`: no compact → `==` input; one compact → appended once; idempotent on already-expanded input.
- `project/2`:
  - order preserved;
  - non-compact tools `==` untouched;
  - `{:tool, name}` and binary `name` naming a compact tool → that tool full, the others stubbed;
  - `:auto` / `:required` / map → all stubbed;
  - a StreamData property (tools from `ALLM.Test.Generators`' tool generator, `test/support/generators.ex:74`, mapped with `StreamData.boolean()` onto `:compact`): for any generated tool list, `project(l, c) == project(l, c)` and `length(project(l, c)) == length(l) + (if Enum.any?(l, &compact?/1), do: 1, else: 0)`.
- `render/2`:
  - known name, with the exact format and the schema JSON decoding back `==` to the tool's schema;
  - multiple names in request order;
  - duplicate names deduplicated;
  - unknown name;
  - binary `names`;
  - atom-keyed args;
  - malformed args (`%{}`, `%{"names" => 3}`) → usage string;
  - the meta-tool is never listed among the "Compact tools".
- Robustness: `meta_tool?/1` and `check_args/2` never raise on a `%Tool{metadata: nil}`, non-map args, or a non-map schema.
- `answer/2`: equals `render/2` on `tool_call.arguments`; `arguments: nil` → the usage string.
- `check_args/2`:
  - non-compact → `:ok` regardless of args;
  - compact with all required present → `:ok`;
  - two missing → `{:error, s}`, where `s` starts with `"missing required argument(s): a, b\n\n"` (in `required` order) and ends with `render([tool], %{"names" => [name]})`;
  - no `required` key → `:ok`;
  - `ToolResultEncoder.JSON.encode({:error, s})` decodes back to `%{"error" => s}`.
- `meta_tool/0`:
  - passes `Validate.tool/1`;
  - `meta_tool?/1` is true for it and false for a user tool named `"tool_help"`;
  - an ETF round-trip is equal (no funs);
  - after a JSON round-trip (`Jason.encode!/1` → `ALLM.Serializer` hydrate), it is still `meta_tool?/1` and `with_meta_tool/1` stays idempotent on the hydrated list.
- Doctests on every documented public function (the seven above the test-seam line in the contract block).

**Implementation checklist**
- [ ] `lib/allm/tool_help.ex` per the contract, with `@moduledoc` covering Decisions #1–#4 and #6 described in prose (no `Decision #N`, `§`, or `Phase N` tokens — `scripts/audit_user_docs.exs`), the manual-mode note (Decision #6), and the direct-`ToolRunner` note. `@doc` + `@spec` + doctest on the seven documented functions; `@doc false` + `@spec` on the four seams.
- [ ] `mix.exs` `groups_for_modules`: add `ALLM.ToolHelp` to the `Runtime:` group (`mix.exs:172`). It is a runtime helper, not a data type.
- [ ] Commit the 8-tool fixture `examples/fixtures/compact_tools.exs` and load it from `test/test_helper.exs` (Module Tree rows).

**Verification:** as 23.1, plus `mix test test/allm/tool_help_test.exs test/groups_for_modules_audit_test.exs` and `mix run scripts/audit_user_docs.exs lib/allm/tool_help.ex` → 0 hits (`test/layer_a_docs_test.exs` does not cover this non-Layer-A module).

### Phase 23.3: Chat-loop wiring (Layer C)

**Test Plan (write first)**, `test/allm/chat/compact_tools_test.exs`:
- **Vehicle:** `ALLM.Providers.Fake`, capturing each step's `%Request{}` via the `:record` adapter option (`lib/allm/providers/fake.ex:800-814`, which sends `{:allm_fake_record, request, opts}`).
- Every row runs on **both** `ALLM.chat/3` and `ALLM.stream/3 |> collect` (DESIGN.md rule 10 matrix):

| # | Scenario | Assertion |
|---|---|---|
| 1 | No compact tools | the recorded `request.tools` `==` resolved tools; no `tool_help` present |
| 2 | Two compact + one full tool | recorded `request.tools` = `ToolHelp.project/2` of the resolved list |
| 3 | Script: `tool_help(names: ["x"])` → `x(valid args)` → text | the `tool_help` `:tool` message content `== ToolHelp.render/2`; `x`'s handler received the args; `ChatResult` completes |
| 4 | Script: compact `x` with a required arg missing, then a valid call, then text | the first `:tool` message's content `Jason.decode!`s to `%{"error" => s}` with `{:error, s} == ToolHelp.check_args(x, bad_args)`; the handler ran exactly once |
| 5 | Row 4 with `on_tool_error: :halt` | `halted_reason: :tool_error`; the handler never ran |
| 6 | 3-step run (row 3) | the recorded `request.tools` are `==` across all 3 steps (cache invariant) |
| 7 | `tool_choice` naming compact `x`, one row per Decision #3 shape (binary, `{:tool, "x"}`, Anthropic map string- and atom-keyed, OpenAI Chat map, Responses flat map, Gemini single-name `allowedFunctionNames` map) | the recorded wire `x` is the full tool; the other compact tools are stubs |
| 8 | User tool named `tool_help` + a compact tool | both `ALLM.chat/3` and `ALLM.stream/3` return `{:error, %ValidationError{}}` synchronously (pre-flight; `lib/allm/chat.ex:616-618` for streaming), containing `{:tools, :duplicate_name}` |
| 9 | Engine with a custom `tool_executor`: a test-local module implementing `ALLM.ToolExecutor` whose `execute/3` raises (`resolve_executor/1` takes a module, `lib/allm/tool_runner.ex:844-857`) | a `tool_help` call still succeeds (bypass) |
| 10 | Per-tool manual: compact `x` has `manual: true`; the script calls `tool_help` then `x` | `tool_help` auto-runs; the loop halts `:manual_tool_calls` on `x` |
| 11 | Whole-loop `mode: :manual` via `ALLM.Session`: `Session.start(engine, msgs, mode: :manual)` (`lib/allm/session.ex:234`), with the script calling `tool_help` | `session.status == :awaiting_tools`; `session.pending_tool_calls` holds the `tool_help` call; `Session.submit_tool_result(session, tc.id, ToolHelp.answer(tools, tc))` (`:544`), where `tools` is the caller's own list plus `meta_tool/0`, returns a `%Session{}`; `Session.continue(engine, session, nil, mode: :manual)` (`:322`) then proceeds. `:mode` must be re-passed: the Session does not store it (`merge_session_opts/2`, `:914-918`). Streaming mirror: `{:ok, s} = Session.stream_start(engine, msgs, mode: :manual)` (`:409`), folded with `ALLM.Session.StreamReducer` to recover the session → the same submit → `Session.stream_step(engine, session, mode: :manual)`, folded the same way. |
| 12 | `on_tool_error` as a `fun/2`, with a required argument missing on compact `x` | the fun receives the binary usage text as the reason, and its return decides continue/halt as today |
| 13 | `halt_when: fn sr -> sr.tool_results != [] end` with a `tool_help`-only first step | halts after the `tool_help` step. Pins the documented consequence that `tool_help` results count as tool results. |
| 14 | `max_turns: 2` with the script `tool_help` → `x` → text | halts with `halted_reason: :max_turns` before the text. Pins that each `tool_help` round trip uses a turn. |
| 15 | One assistant turn calling both `tool_help(["x"])` and `x(valid args)` in parallel | both execute in that turn; `x` ran with the supplied arguments (no ordering dependency between them) |
| 16 | `structured_finalize: true` + `response_format` with compact tools on the **engine** | the recorded pass-2 `request.tools == []` (`finalize_engine`, `lib/allm/chat.ex:487`, `:749`); no `tool_help` on pass 2 |

- `test/allm/chat_equivalence_test.exs`: add the row-3 script as a fixture. The existing `non-streaming ≡ streaming |> collect` property must hold with **no new relaxation row**.
- `test/allm/tool_runner_test.exs`: interception and `check_args` unit rows at the `run_tool_calls/3` level (`lib/allm/tool_runner.ex:182`).

**Implementation checklist**
- [ ] Add `effective_tools/2` and route the six execution-site calls through it. Change `build_request/4` per the contract. Post-condition: `git grep -n 'Engine.resolve_tools(' lib/allm/chat.ex | wc -l` → `2`.
- [ ] `execute_one_tool/3` interception per the contract.
- [ ] Contract-flip audit (invariant 3): run `git grep -n 'request.tools\|resolve_tools' test/` and record a one-line keep disposition per hit in RECORDS. Expected: all keep.
- [ ] `guides/tools.md` is **not** touched here; that is 23.4.

**Verification:** as 23.1, plus `mix test test/allm/chat/compact_tools_test.exs test/allm/chat_equivalence_test.exs test/allm/tool_runner_test.exs`.

### Phase 23.4: Spec §40, guide, live example (docs)

**Test Plan**
- `guides/tools.md` gains a `## Compact tools` section, with at least one `iex>` block over `Fake` that shows `ToolHelp.project/2` output and a `tool_help` round trip. `test/guides_doctest_test.exs` executes it. The fence-compile gate stays green (`mix run scripts/check_guide_fences.exs`).
- `mix run scripts/audit_user_docs.exs guides/tools.md` → 0 hits.

**`examples/21_compact_tools.exs` (the BLOCKING live gate)**
- **Setup:** the 23.2 fixture's tools, all `compact: true`, with handlers returning canned JSON. Prompt: "File an issue in acme/web titled 'Login button broken' with label bug."
- **Asserts** (each `System.halt(1)`s with a want/got line on mismatch):
  - (a) the run completes;
  - (b) `create_issue`'s handler ran with `"repo"` and `"title"` present;
  - (c) the same prompt is also run with `compact: false`, and both runs' `usage.input_tokens` for step 1 are printed. Assert compact < full.
- **Recorded, not asserted** (per provider, in RECORDS):
  - whether the model called `tool_help` first (the first measurement of the R8 open question);
  - the run-total summed `input_tokens` for compact vs full, since `tool_help` output stays in the thread;
  - whether `labels` arrived as an array (type conformance, which `check_args/2` doesn't check).
- **Run:** `set -a; . ./.env; set +a; ALLM_PROVIDER=<p> mix run examples/21_compact_tools.exs` for `openai`, `anthropic`, `gemini`.
- **Anthropic caveat:** on 2026-09-21 the Anthropic key returned `credit balance is too low`. That is an account condition, not the CLAUDE.md blocked-arm case (no prior-phase commit documents it, and it blocks every Anthropic script, not just 21). If credit is still absent at 23.4: run the other two arms, file a new `/asks` `[BUG]` naming the 400 body, flag the deferral in the commit and RECORDS, and leave `RUN_OUTPUT_ANTHROPIC.md` untouched. The `{"type":"object"}` acceptance row stays UNVERIFIED until it runs.
- **Cost:** ~2 runs × 2–4 steps × ~1.5k input tokens is ~6–12k input tokens plus <1k output tokens per provider per clean run on the `examples/_helpers.exs` default models (`gpt-5.4-nano`, `claude-sonnet-4-6`, `gemini-3-flash-preview`). The per-1M-token prices are UNVERIFIED here; the implementer quotes them from each provider's pricing page and reports actuals against this token budget (DESIGN.md rule 19). First-implementation cost is 2–4× a clean run.

**Implementation checklist**
- [ ] Spec §40 "Compact tool disclosure" (motivation, the stub/meta-tool contract by reference to `ALLM.ToolHelp` docs, cache invariant, the manual-mode rule, the research taxonomy in ≤10 lines). Amend §5.2 (fields), §16 (the `:summary` row) and §27 (`tool_help.ex`), each opening with `> **Phase 23 amendment (commits <first>..<last>).**` (DESIGN.md rule 21).
- [ ] Guide section; `examples/README.md` row; CHANGELOG entry derived from `git diff <prior-tag>..HEAD lib/` (CLAUDE.md release rule).
- [ ] Regenerate `examples/RUN_OUTPUT_*.md` only for arms run in full in the same commit; otherwise leave them untouched (snapshot rule).

**Verification:** as 23.1, plus `mix test test/guides_test.exs test/guides_doctest_test.exs` and the live runs above.

### Phase 23.5: `[CHORE]` sweep

Module Tree: whatever `/asks` tickets and RECORDS `[CARRY]` lines 23.1–23.4 filed against this phase. Enumerate them with `grep -n "Phase 23\|23\.[1-4]" .work/ASKS.md steering/2026-09-21_COMPACT_TOOLS_DESIGN_RECORDS.md`. Each ticket is either closed in-tree or re-filed with an explicit later owner.

**Success:** the grep's ticket list is fully dispositioned in RECORDS; `mix test`, `mix test --seed 0`, credo, dialyzer and format are all green.

---

## Definition of Done

- [ ] All sub-phases done per RECORDS.
- [ ] `mix test` and `mix test --seed 0`: zero failures; coverage ≥80% globally and ≥90% on `lib/allm/tool_help.ex`.
- [ ] `mix credo --strict`, `mix dialyzer` and `mix format --check-formatted` are clean.
- [ ] Every documented function in `ALLM.ToolHelp` has `@spec`, `@doc` and a doctest; the test seams have `@doc false` + `@spec`.
- [ ] The `ALLM.Tool` round-trip test pins non-default `compact`/`summary`.
- [ ] `chat_equivalence_test.exs` holds with the compact fixture and no new relaxation row.
- [ ] Cross-function invariants 1–3 are each pinned by a named test (23.3 rows 2/3, 6, 1).
- [ ] `examples/21_compact_tools.exs` exits 0 on every provider whose arm is not blocked; blocked arms are recorded per the CLAUDE.md blocked-arm rule.
- [ ] The Research table's Anthropic `{"type":"object"}` row is resolved to measured, or its deferral is recorded.
- [ ] Spec §40 plus the amendments have landed, the CHANGELOG is updated, and `guides/tools.md` has been extended.

## Records

`steering/2026-09-21_COMPACT_TOOLS_DESIGN_RECORDS.md`: created on first need.
