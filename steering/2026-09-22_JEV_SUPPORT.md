# Phase 24: Typed Classification (TypeSafe Jev): Design Document

*Generated 2026-09-22 · Measured against: `1859dac`*

> **Goal:** Add a provider-neutral, non-streaming **classification** primitive (`ALLM.classify/3`) and bundle a TypeSafe adapter for it. An ALLM app can then ask Jev typed questions (pick one option, score on a rubric, yes/no) about a piece of state and get calibrated, typed answers back without generating any text.
> **Outcome:** `ALLM.classify(engine, ticket_text, questions: %{"department" => ClassificationQuestion.choice("Which team?", ["billing", "technical", "sales"])})` returns `{:ok, %ALLM.ClassificationResponse{}}` against `POST https://api.typesafe.ai/v1/systemone`, and `ClassificationResponse.answer(resp, "department").choice == "billing"`. Every Jev answer type decodes to a typed `%ALLM.ClassificationAnswer{}`, and `ALLM_PROVIDER=typesafe mix run examples/run_all.exs` exits 0.
> **Spec sections:** new **§41** (Typed classification). Amends **§27** (module tree), **§29** (telemetry), **§35.7** (bundled-adapter rule: third admission criterion), **§35.10** (reconciles the "classification is not a primitive" line).
> **Layers touched:** A, B, C, one layer per sub-phase (24.1 = A, 24.2 = B, 24.3 = C, 24.4 = B, 24.5 = docs, 24.6 = `[CHORE]` sweep).

**Number checks (run 2026-09-22):**
- `grep -rn "Phase 24\|§41" steering/*.md CLAUDE.md` returns nothing.
- `steering/2026-09-21_COMPACT_TOOLS_DESIGN.md` (untracked at `1859dac`) already claims **Phase 23** and **§40**; §37/§38 are reserved for audio and batch.
- This design therefore takes **Phase 24 / §41**. If Phase 23 is abandoned before this builds, the numbers stay as they are, because they are labels and not an ordering.

**Owner decision recorded (2026-09-22).** The user was asked how Jev support should ship, since the §35.7 bundled-adapter rule does not admit a TypeSafe adapter as written (see Alternative A). They chose **"In core, amend spec"**: a provider-neutral behaviour plus a bundled `ALLM.Providers.TypeSafe.Classification`, with §35.7 gaining a third, scoped admission criterion. The design is written against that answer.

## Status

| Phase | Description | Layer | Status |
|-------|-------------|-------|--------|
| 24.1 | Layer A: `ClassificationQuestion`/`Request`/`Answer`/`Response`, `ClassificationAdapterError`, validator, enum + registry edits | A | Not Started |
| 24.2 | `ALLM.ClassificationAdapter`, `Engine.classification_adapter`, `FakeClassification`, conformance suite | B | Not Started |
| 24.3 | `ALLM.classify/3`, `ALLM.classification_request/2`, `:classify` telemetry span | C | Not Started |
| 24.4 | `ALLM.Providers.TypeSafe.Classification` + recorder/live probe + fixtures | B | Not Started |
| 24.5 | Spec §41 + amendments, `guides/classification.md`, examples + `run_all.exs` arm rule, CHANGELOG | docs | Not Started |
| 24.6 | `[CHORE]` sweep | — | Not Started |

**Overall Progress:** 0/6 sub-phases complete. Tick-state is kept in the records file, not here.

Per-sub-phase records (deviations, probe transcripts, closure ledgers) go to `steering/2026-09-22_JEV_SUPPORT_RECORDS.md`, created on first need.

---

## Assumptions

Each assumption is cheap to revisit. The ones marked **★** change the shape of the work.

1. **★ Jev is not an LLM and is never wired as one.** The TypeSafe docs say so directly: *"Jev is **not** a drop-in replacement for the LLM behind Claude Code … It does not generate text, write code, or hold a conversation."* ([docs.typesafe.ai/introduction/coding-agents](https://docs.typesafe.ai/introduction/coding-agents.md), fetched 2026-09-22). Jev therefore implements a **new** behaviour and never `ALLM.Adapter` / `ALLM.StreamAdapter`. See Alternative B.
2. **★ One endpoint, three question types, one call.** All three types go to `POST https://api.typesafe.ai/v1/systemone`. A request is `{state, model, questions: map<id, Question>}` and a response is `{model, answers: map<id, Answer>, usage}` ([docs.typesafe.ai/api](https://docs.typesafe.ai/api.md), fetched 2026-09-22; quoted in the wire-field map). All question types can be mixed in one request, and *"every question is evaluated in parallel and in isolation against the same state"* ([docs.typesafe.ai/introduction](https://docs.typesafe.ai/introduction.md)). The ALLM request mirrors that shape: one state and N named questions per call.
3. **★ The library does not decide thresholds.** It returns the probabilities, score position and confidence that Jev reports. There is no default confidence floor, no `yes?/2` with a baked-in 0.5, and no routing DSL. TypeSafe itself says *"The thresholds live in your code"* (Noul page), and the moderation family (§39.1 goal 4) takes the same stance.
4. **Classification is non-streaming.** It is request/response with no token stream, so there is no `stream_classify/3` and no `ClassificationStreamAdapter`, following §35.1 item 2, §36 and §39.1 goal 2.
5. **Text-only state.** *"Text only. String, JSON object, or array of text values. No image, audio, or video input."* ([docs.typesafe.ai/models](https://docs.typesafe.ai/models.md)). `%ALLM.ImagePart{}` is therefore not part of the state union.
6. **Key atom `:typesafe` → env var `TYPESAFE_API_KEY`.** This needs no `ALLM.Keys` edit, because `env_var_for/1` falls back to `String.upcase("#{provider}") <> "_API_KEY"` (`lib/allm/keys.ex:200-205`). Verified in `mix run` on 2026-09-22: `ALLM.Keys.env_var_for(:typesafe)` → `"TYPESAFE_API_KEY"`. That name is the same one TypeSafe's own SDK reads (`API_KEY_ENV = 'TYPESAFE_API_KEY'`, [sdk/python/api/constants](https://docs.typesafe.ai/sdk/python/api/constants.md)).
7. **No `TYPESAFE_API_KEY` exists in this checkout yet.** `grep -c TYPESAFE .env` returned 0 on 2026-09-22. The 24.4 recorder/probe and the 24.5 live gate need the maintainer to add one to the project-root `.env` first. This is a prerequisite, not a deferral licence: per CLAUDE.md, "key absent" means absent *after* sourcing `.env`.
8. **`llm_db` is still not a dependency** (`mix.exs:39` comment), and it has no TypeSafe catalog entry in any case. Model strings stay late-resolved (§6.3).

---

## Alternatives Considered

### A. Where the TypeSafe adapter ships (resolved by the owner)

§35.7 currently has three rules:

- The Phase 20 amendment admits an adapter when *"**either** (a) its maintenance overlaps with its provider's already-bundled chat adapter, **or** (b) it is the provider's own officially-recommended path for a capability that provider does not itself offer"* (`steering/allm_engine_session_streaming_spec_v0_2.md:2275`, restated at `:2989`).
- The Phase 22 amendment adds a family-shape carve-out (`:2280-2292`): *"A capability family may be bundled with **exactly one** provider adapter when that provider is already bundled for chat, and the capability's absence on the other bundled providers is documented rather than backfilled with a proxy."*

TypeSafe fails all three. There is no bundled TypeSafe chat adapter, no bundled provider names TypeSafe as a partner, and a one-adapter classification family's only provider is *not* bundled for chat. Separately, §35.10 lists *"image classification / object detection as distinct primitives — users build these on top of chat + vision"* as out of scope (`:2322`).

| Option | Trade-off |
|--------|-----------|
| **A1: in core, amend §35.7 (chosen by owner)** | One package and one release train. Needs a new scoped **capability-only-provider** carve-out that covers both admission and family shape (Decision #10), plus a §35.10 reconciliation paragraph modelled on §39's *"Why a classification primitive is admitted where object detection is not"*. |
| A2: behaviour in core, adapter as a separate Hex package | No spec amendment, but two packages to version and release, and a `conformance/` dependency across them. |
| A3: A1 plus an LLM-backed generic classification adapter | Would make `classify/3` work without a TypeSafe key by reproducing choice/score/yes-no through structured output on any chat model. Roughly two more sub-phases, and the probabilities would be *invented* from logprobs or self-reports, not calibrated, which undercuts the reason to have the primitive. Declined for this phase. The behaviour does not foreclose it. |

### B. A new capability versus reusing `generate/3`

| Option | Trade-off |
|--------|-----------|
| **B1: new capability (`classify/3`, `ClassificationAdapter`) (chosen)** | Same shape as images/embeddings/moderation: its own Layer A pair, behaviour, `Engine` field, façade, Fake and conformance suite. Typed answers are data, not parsed text. |
| B2: TypeSafe as an `ALLM.Adapter` that serialises answers into `Response.output_text` | Every chat invariant would be a lie: no messages, no tools, no stream, no `finish_reason` semantics. Callers would parse JSON back out of a string, which is exactly the coercion Jev exists to remove ("No text generation, no parsing", introduction page). |
| B3: extend `generate/3` with a `:classification` request mode | Widens `ALLM.Request` and every chat adapter's accept set for one provider's benefit, and breaks the "separate types, parallel pipeline" rule §39.1 goal 1 set for non-chat capabilities. |

### C. Question-type vocabulary

TypeSafe's three types are `choice`, `score` and `noul` ("noul" is TypeSafe's coined word for a yes/no probability).

| Option | Trade-off |
|--------|-----------|
| **C1: `:choice \| :score \| :yes_no`, with `:yes_no` ↔ wire `"noul"` (chosen)** | Neutral and self-describing in a provider-neutral library. The mapping is stated once, in the wire-field map, and the TypeSafe adapter's moduledoc repeats it for readers coming from the TypeSafe docs. **Cost:** someone reading TypeSafe's docs has to learn one alias. |
| C2: keep `:noul` | Zero translation, but it puts a vendor coinage into a Layer A type that a future second classification adapter would have to adopt. |

`choice` and `score` are generic words and are kept unchanged.

### D. Score answer representation

The wire keys score `probabilities` and `legend` by level index as a **string** (`{"0": 0.0, "1": 0.95, "2": 0.05}`). TypeSafe's Python SDK re-keys them by integer (*"The SDK keys `probabilities` and `legend` by integer level rather than by string"*, Score page).

| Option | Trade-off |
|--------|-----------|
| **D1: ordered lists, where index = level (chosen)** | `probabilities: [0.0, 0.95, 0.05]`, `legend: ["Calm", "Frustrated", "Very angry"]`. JSON round-trips as identity, and `Enum.at(probabilities, level)` reads naturally. |
| D2: integer-keyed maps (the Python SDK shape) | An integer-keyed map does **not** survive `Jason.encode!/1 \|> Jason.decode!/1`, because keys come back as strings. That would need a decode hook, and the Layer A round-trip would be a trap. |
| D3: string-keyed maps (the wire shape) | Lossless and hook-free, but `probabilities["1"]` is an awkward read for an ordinal scale. |

Choice `probabilities` stay a **string-keyed map**, since option names are caller strings with no order (see Decision #4).

### E. Chunking and question caps

**Chosen: no chunking and no `max_questions/0` callback.** Unlike moderation, splitting questions across calls *would* be well-defined, because answers are independent per question. But each extra call re-bills the whole state, and TypeSafe's own guidance is that *"batching every question into one TypeSafe call is 12.2x cheaper and 10.0x faster"* (Parallel questions cookbook, index description). The documented limits are per-request token budgets (*"64k tokens per request; 32k tokens for `state` plus the longest question"*, Models page), not a question count. A question-count cap, if one exists, is found by the 24.4 probe ladder and documented. It is not enforced client-side, because a provider 422 already maps to `:invalid_request`.

---

## Overview

ALLM can generate text, images, embeddings and moderation verdicts. It has no way to ask a fast, calibrated model a closed-form question ("which team owns this ticket?", "how frustrated is this customer, 0–2?", "is a refund being requested?") and get a typed answer. Today an app has two routes. It can hand-roll an HTTP client against TypeSafe, or it can prompt a chat model to "return JSON" and parse it back, which is slow, not calibrated, and fragile. This phase adds the typed route as a first-class capability.

Structurally it is the moderation family again (Phase 22): a Layer A request/response pair, a dedicated behaviour with its own closed error enum, one `Engine` field, one façade function, one telemetry span, one `Fake*` adapter and one conformance suite. It differs in three places, and those are where a reviewer should look hardest:

- The **request carries typed questions**, not an input list, so the validator's vocabulary is per-question-type (see the validator vocabulary table).
- The **answer is a tagged union** carried in one struct, with a per-type field-population table.
- The **provider is capability-only**: it has no chat adapter. That forces the §35.7 amendment and a small change to how `examples/run_all.exs` picks scripts for an arm (Decision #14).

### Deliverables

**Layer A (new):** `ALLM.ClassificationQuestion`, `ALLM.ClassificationRequest`, `ALLM.ClassificationAnswer`, `ALLM.ClassificationResponse`, `ALLM.Error.ClassificationAdapterError`.
**Layer A (modified):** `ALLM.Error.EngineError` (+`:no_classification_adapter`), `ALLM.Error.ValidationError` (+`:invalid_classification_request`), `ALLM.Serializer` (+5 `@known_modules`), `ALLM.Validate` (+`classification_request/1`).
**Layer B (new):** `ALLM.ClassificationAdapter`, `ALLM.Providers.FakeClassification`, `ALLM.Providers.TypeSafe.Classification`, `ALLM.Test.ClassificationAdapterConformance`.
**Layer B (modified):** `ALLM.Engine` (+`:classification_adapter` at every site in the Engine-extension table), `ALLM.Telemetry` (+`:classify` span name; lands in 24.3 with its only caller).
**Layer C (new):** `ALLM.classify/3`, `ALLM.classification_request/2`.

### Spec coverage

Implements new **§41**. Amends **§27** (module tree), **§29** (event names), **§35.7** (Decision #10) and **§35.10** (a reconciliation paragraph in §41's intro, modelled on §39's).

### Layer demonstration

**Layer A:** build, validate and serialize a request with no engine and no network:

```elixir
q = ALLM.ClassificationQuestion.choice("Which team should handle this?", ["billing", "technical"])
req = ALLM.classification_request("My payouts failed.", questions: %{"department" => q})
:ok = ALLM.Validate.classification_request(req)
{:ok, ^req} = req |> ALLM.Serializer.to_json!() |> ALLM.Serializer.from_json()
```

**Layer B:** call the adapter directly and bypass the façade:

```elixir
{:ok, %ALLM.ClassificationResponse{} = resp} =
  ALLM.Providers.TypeSafe.Classification.classify(req, api_key: key)
resp.answers["department"].probabilities  #=> %{"billing" => 0.88, "technical" => 0.12}
```

**Layer C:** the façade, with its gates, retry and span:

```elixir
engine = ALLM.Engine.new(classification_adapter: ALLM.Providers.TypeSafe.Classification)
{:ok, resp} = ALLM.classify(engine, ticket, questions: questions)
%{choice: team, confidence: c} = ALLM.ClassificationResponse.answer(resp, "department")
```

There is deliberately **no Layer D**. A classification carries no conversation state, and `ALLM.Session` is untouched.

### Prerequisites

- The Phase 22 moderation family is the structural template throughout. Its files at `1859dac`: `lib/allm/moderation_adapter.ex`, `lib/allm/moderation_request.ex`, `lib/allm/moderation_response.ex`, `lib/allm/error/moderation_adapter_error.ex`, `lib/allm/providers/fake_moderation.ex`, `lib/allm/providers/openai/moderation.ex`, `conformance/lib/allm/test/moderation_adapter_conformance.ex`, and the façade block in `lib/allm.ex`: public `moderation_request/2` (`:1193`) and `moderate/3` (`:1364-1376`); internals `do_moderate/3` through `moderate_stop_extras/1` (`:1744-1936`).
- A `TYPESAFE_API_KEY` in the project-root `.env` before 24.4 (Assumption 7).
- No new deps. `Req` handles the synchronous JSON POST.

### Out of scope

| Excluded | Why |
|----------|-----|
| An LLM-backed generic classification adapter | Alternative A3, declined by the owner's choice of A1. |
| A default threshold, `yes?/2`, or a routing/policy DSL | Assumption 3. |
| Client-side chunking of questions across calls | Alternative E. |
| Image/audio in `state` | Assumption 5. Jev is text-only. |
| `GET /v1/models` listing | No ALLM capability lists models. The response's `model` field already reports the versioned ID that answered. |
| Streaming | Assumption 4. |
| Cost population (`Usage.input_cost` / `output_cost` / `total_cost`) | Needs `llm_db` (Assumption 8). `input_tokens` is populated, and pricing is per input token, so a caller can compute cost. |
| Capability pre-flight (`Capability.preflight_classification/2`) | Decision #7. |
| Session integration, or automatic classification inside `chat/3` | No conversation state; a hidden second call per turn (the same reasoning as §39.1 goal 1). |
| `jev-preview` / version-pin helpers | A model string is a model string. The guide shows pinning `jev-1.13.0` (Models page, "Aliases"). |

### Non-obvious decisions

1. **Classification is its own capability, and TypeSafe implements only that.** See Alternative B. *Docs target: `@moduledoc ALLM.ClassificationAdapter` + spec §41.1.*
2. **`:yes_no` is the neutral name for TypeSafe's `noul`.** See Alternative C. The mapping lives in the wire-field map and the adapter moduledoc. *Docs target: `@moduledoc ALLM.Providers.TypeSafe.Classification` + `@moduledoc ALLM.ClassificationQuestion`.*
3. **Question IDs are non-empty binaries. The builder stringifies atom IDs; the struct does not.** `ClassificationRequest.new/1` stays a bare `struct!/2` pass-through, which is CLAUDE.md's Layer-A constructor default. `ALLM.classification_request/2` converts atom keys with `Atom.to_string/1` for ergonomics. The validator rejects any non-binary key left on a directly constructed struct. The reason is that atom keys do not survive a JSON round-trip, so a struct holding them would violate the Layer A invariant silently. *Docs target: `@doc ALLM.classification_request/2`.*
4. **One answer struct, with a per-type field-population table. Score lists are index = level; choice probabilities are a string-keyed map.** See Alternative D. *Docs target: `@moduledoc ALLM.ClassificationAnswer`.*
5. **The engine's `:model` is NOT stamped onto a classification request. This deliberately diverges from moderation.** `do_moderate_body/5` stamps `request.model || resolved_model`, where `resolved_model = Engine.resolve_model(engine, opts)` falls back to `engine.model` (`lib/allm.ex:1766`, `:1823`, and `lib/allm/engine.ex:405-406`: `chosen = Keyword.get(opts, :model) || engine.model`). On an engine that carries a chat model and a classification adapter together, that would send `"gpt-…"` to TypeSafe and get a guaranteed 4xx. What classification does instead: effective model = `request.model || opts[:model]`. When both are nil, the adapter injects its documented default `"jev-latest"`. *Docs target: `@doc ALLM.classify/3` "Model resolution" + adapter `@doc classify/2`.*
6. **No chunking and no question-count callback.** See Alternative E. *Docs target: `@doc ALLM.classify/3` "One call, many questions".*
7. **No `Capability.preflight_classification/2`. This diverges from §39.1 goal 5.** Its only possible input is an `llm_db` catalog entry. `llm_db` is not a dependency (Assumption 8), and no catalog carries TypeSafe models. Moderation's preflight is inert in practice for the same reason (`lib/allm/capability.ex:400-411`, which returns `:ok` without a catalog). Adding a sixth inert helper would be speculative surface. If a catalog ever carries Jev, it gets added then. *Docs target: spec §41.4 (one sentence).*
8. **HTTP 529 maps to `:provider_unavailable`, so it is retried.** TypeSafe documents `529 Overloaded` (API reference, Errors table). The committed precedent is Anthropic chat, `lib/allm/providers/anthropic.ex:504-505`:
   ```elixir
   defp classify_reason(status, _type, _msg, ra) when status in [500, 502, 503, 504, 529],
     do: {:provider_unavailable, ra}
   ```
   No other non-chat adapter maps 529 (it falls through to `:unknown` there). Because the façade retries on reason atoms (`augment_retry_policy/2`, `lib/allm.ex:1526-1536`), no status-level `retry_on` widening is needed. *Docs target: `@moduledoc ALLM.Error.ClassificationAdapterError` status table.*
9. **Confidence is reported, never computed. `:yes_no` answers carry `confidence: nil`.** TypeSafe: *"Noul has no separate `confidence`"* (Primitives page). The Fake invents its own deterministic confidence and says so in its moduledoc (the Fake contract below); the real adapter never does. *Docs target: `@moduledoc ALLM.ClassificationAnswer`.*
10. **§35.7 gains a third scoped carve-out, the "capability-only provider" rule (owner decision).** Alternative A quotes the rules it sits beside. It is deliberately **not** labelled "(c)", because criteria (a)/(b) are about admission and the Phase 22 addition is about family shape. This one has to cover both. Proposed text:

    > *An adapter from a provider with no bundled chat adapter may be bundled, as the **sole** member of its capability family, when (i) no bundled provider offers the capability through a dedicated endpoint, (ii) the provider's API for it is a single, documented HTTP surface, and (iii) the capability's absence on every bundled chat provider is documented rather than backfilled with a proxy.*

    It explicitly exempts the family from the Phase 22 carve-out's *"already bundled for chat"* condition, and from nothing else. Like the §36 and §39 amendments, it is a carve-out and not a widening. It does not license a second TypeSafe-shaped provider for a capability that a bundled provider already serves. The §41 intro also reconciles §35.10 in the §39 style: typed classification has a dedicated single-call endpoint with calibrated per-option probabilities, which chat composition cannot reproduce. *Docs target: spec §35.7 amendment + §41 intro. §41 also records that Decisions #5 and #7 depart from §39.1 goal 5 ("model resolution and capability pre-flight … apply identically").*
11. **The Fake returns default answers when there is no script, and errors when a script is exhausted.** This copies the moderation split (`lib/allm/providers/fake_moderation.ex:24-28`, `:40-42`), not FakeEmbeddings' "no script is an error". *Docs target: `@moduledoc ALLM.Providers.FakeClassification`.*
12. **`usage` is populated; `cost` stays nil.** The wire returns `usage: {input_tokens, output_tokens}` (API reference), which maps onto the existing `ALLM.Usage` fields (`lib/allm/usage.ex:29-30`). *Docs target: `@moduledoc ALLM.ClassificationResponse`.*
13. **`:provider_request_id` is a dedicated response field, not a metadata key.** TypeSafe's SDK surfaces *"The `x-typesafe-request-id` response header"* (SDK Exceptions page), which is what a user sends to TypeSafe support. Putting it in `:metadata` would break conformance invariant 7 (`request.metadata` round-trips unchanged). `:request_id` stays ALLM's own correlation id, with **no** header fallback. This diverges on purpose from Voyage (`lib/allm/providers/voyage/embeddings.ex:621`: `request_id: Keyword.get(opts, :request_id) || header_value(headers, "x-request-id")`), whose moduledoc admits the fallback *"is unreachable through `ALLM.embed/3`"* (`:148`). Two fields remove the ambiguity. **Prune path:** if probe arm 1 observes no `x-typesafe-request-id` header, the field is removed in 24.4 (struct, type, decoder, tests), and that is recorded as a RECORDS deviation. *Docs target: `@moduledoc ALLM.ClassificationResponse`.*
14. **A capability-only provider arm in `examples/`.** `run_all.exs` currently runs every marker-less script on every arm (`examples/run_all.exs:59`: `if allowed_providers == :any or provider in allowed_providers do`). A `typesafe` arm would therefore run the chat scripts and fail. The change: marker-less scripts run only on arms whose `@providers` row has a non-nil `:adapter`, via a new `ExamplesHelpers.chat_provider?/1`. The classify script carries `# Provider: typesafe`. `classification_engine/1` is its own function, **not** a `capability_engine/2` call. That helper always writes the row's default model onto the engine's `:model` (`examples/_helpers.exs:291-316`: `base = [{spec.adapter_key, adapter}, {:model, model}]`), and Decision #5 makes `classify/3` ignore it. So `classification_engine/1` builds an engine with only `classification_adapter:`, and `classification_opts/0` returns `[model: System.get_env("ALLM_CLASSIFICATION_MODEL", row.classification_default_model)]` for the script to pass per call. *Docs target: `examples/README.md` + `@moduledoc ExamplesHelpers`.*
15. **The adapter injects `model: "jev-latest"` when the effective model is nil, and documents that.** This satisfies CLAUDE.md's rule that an adapter MUST document any default it injects for a Layer-A nil the wire requires (the API marks `model` required). The default goes in the public `@doc classify/2` AND in `to_json_body/2`'s `@doc false`. `jev-latest` is an alias that moves; the guide says to pin `jev-1.13.0` when tuning thresholds (Models page, "Aliases"). *Docs target: adapter `@doc classify/2` + `guides/classification.md`.*
16. **Redaction removes the literal resolved key as well as a pattern.** TypeSafe does not document its key format, so no prefix regex can be written honestly at design time. `redact_key_material/2` receives the resolved key and replaces that exact string. It also applies a `ts-`-style prefix pattern **only if** the 24.4 probe (a) confirms that prefix from the maintainer's key without printing it, and (b) is recorded in RECORDS. Otherwise the literal-key pass is the whole defence. The companion test asserts that the OpenAI (`sk-|rk-|org-`), Gemini and Voyage (`pa-`) patterns match nothing in the planted fixture (CLAUDE.md: inheriting a sibling's regex is a silent no-op). *Docs target: internal.*
17. **JSON-encodability is checked twice: by the validator, and again in the adapter as a second line of defence. Neither check may raise.** `Jason.encode/1` does **not** always return an error tuple. Verified in `mix run` on 2026-09-22:
    - `Jason.encode(%{"a" => {1, 2}})` returns `{:error, %Protocol.UndefinedError{}}`.
    - `Jason.encode(%{{1, 2} => "x"})` **raises** `Protocol.UndefinedError` (String.Chars, from `Jason.Encode.key/2`).

    Both call sites therefore use a shared shape: `try Jason.encode(term) rescue Protocol.UndefinedError -> :error`, treating `{:error, _}` and the rescue alike. The validator's version reports `{:state, :not_json_encodable}` or `[:questions, id, :instructions | :criteria], :not_json_encodable`. The adapter's version returns `%ClassificationAdapterError{reason: :invalid_request, metadata: %{cause: :unencodable_body}}` before key resolution. The exception is **never** stored in `:cause`, because it carries user data or pids that would break the error struct's `Jason.Encoder`. *Docs target: `@doc ALLM.classify/3` "Validation" + adapter `@doc classify/2`.*
18. **Provider limits live in the adapter, not the validator.** TypeSafe's documented caps (255 choice options; 10 score levels) are wire facts about one provider, so they are enforced by `ALLM.Providers.TypeSafe.Classification`'s pre-flight gates as `:invalid_request` with `metadata: %{question: id, limit: n}`, **before key resolution**. This follows the moderation precedent: *"Per-item MIME and byte-size rules are not here: they are provider-specific and live in the adapter"* (`steering/2026-08-31_PHASE_22_moderation.md`, Validate section). A future second adapter does not inherit TypeSafe's numbers. The validator keeps only provider-neutral semantic rules, such as a 1-level score being meaningless. *Docs target: adapter `@moduledoc` "Limits" section.*
19. **The TypeSafe adapter has no inner retry loop; the façade's `Retry.run/3` is the only one.** The moderation and embeddings adapters wrap each attempt in their own `ALLM.Retry.run/3`, so `:timeout` costs 3 × 3 = 9 attempts through the façade (`lib/allm/providers/openai/moderation.ex:245-253`, which calls this *"a pre-existing library-wide characteristic"* tracked in ASKS). A new adapter doesn't need to inherit that. So a direct `classify/2` call makes exactly one HTTP attempt, and `retry_after_ms` is populated for callers that retry themselves. *Docs target: adapter `@moduledoc` "Retry integration".*

---

## Behaviour & Type Contracts

Every signature, wire shape and invariant is stated normatively **once**, here. Later sections cite it.

### Layer A: `ALLM.ClassificationQuestion`

```elixir
defmodule ALLM.ClassificationQuestion do
  @type question_type :: :choice | :score | :yes_no
  @typedoc "String, JSON object, or JSON array: TypeSafe's structured instructions/criteria."
  @type structured :: String.t() | map() | list()

  @type t :: %__MODULE__{
          type: question_type() | nil,
          instructions: structured() | nil,
          criteria: %{String.t() => structured() | nil} | [structured()] | map() | nil
        }

  defstruct [:type, :instructions, :criteria]

  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc "Choice over options. `options` is a list of names (descriptions nil) or a map name => description; atom names are stringified."
  @spec choice(structured(), [String.t() | atom()] | %{(String.t() | atom()) => structured() | nil}) :: t()
  def choice(instructions, options)

  @doc "Score on ordered levels, low to high. Level N is `Enum.at(levels, N)`."
  @spec score(structured(), [structured()]) :: t()
  def score(instructions, levels)

  @doc "Yes/no. Optional `true:` / `false:` describe what each answer means."
  @spec yes_no(structured(), keyword()) :: t()
  def yes_no(instructions, opts \\ [])

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data)
end
```

**Criteria shape by type (normative):**

| Type | `criteria` | Built by |
|------|-----------|----------|
| `:choice` | `%{String.t() => structured() \| nil}`, one key per option | `choice/2`. A list of names becomes `Map.new(names, &{to_string(&1), nil})`; atom map keys are stringified |
| `:score` | `[structured()]`, where index = level | `score/2`, verbatim |
| `:yes_no` | `nil`, or a map whose keys ⊆ `["true", "false"]` | `yes_no/2`. Keys are present only for the opts given |

**The builders raise; `new/1` does not.**
- `choice/2` with a non-list, non-map `options` raises `FunctionClauseError`. The head is guarded `when is_list(options) or is_map(options)`, and there is no catch-all clause.
- `score/2` with a non-list raises `FunctionClauseError`, for the same reason.
- `yes_no/2` with an unknown opt key raises `ArgumentError` via `Keyword.validate!(opts, [:true, :false])`. The message reads `the allowed keys are: [true, false]` (verified in `mix run` on 2026-09-22), so tests assert the exception module and the offending key only. Nothing else is checked at build time: counts, emptiness and caps belong to the validator, so a directly built struct and a builder-made struct are judged by the same rules.

**`__from_tagged__/1`:** `type` decodes through `ALLM.Serializer.to_atom_field/1` (`lib/allm/serializer.ex:202-204`, `String.to_existing_atom/1`). `instructions` and `criteria` pass through verbatim, because JSON already yields string keys and lists, so the round trip is identity for every builder-produced value. There is no `||` default (all defaults are `nil`).

### Layer A: `ALLM.ClassificationRequest`

```elixir
defmodule ALLM.ClassificationRequest do
  @type state :: String.t() | map() | list()

  @type t :: %__MODULE__{
          state: state() | nil,
          questions: %{String.t() => ALLM.ClassificationQuestion.t()},
          model: String.t() | nil,
          options: map(),
          metadata: map()
        }

  defstruct [:state, :model, questions: %{}, options: %{}, metadata: %{}]

  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data)
end
```

**Constructor discipline:** a bare `struct!/2`, with no `@enforce_keys` and no guards, matching `ModerationRequest.new/1`. `state: nil` and `questions: %{}` must be constructible, so that the validator rows `{:state, :empty}` and `{:questions, :empty}` are reachable. An unknown key raises `KeyError` (the `struct!/2` behaviour stated at `lib/allm/embedding.ex:56-57`).

**`__from_tagged__/1`:** `questions` needs a decode hook, `decode_questions/1`. It maps each value through `ALLM.Serializer.hydrate/1` to rebuild `%ClassificationQuestion{}`, passes a non-map through verbatim, and leaves keys untouched (they are already strings). `state` passes through verbatim. `model` uses `data["model"]`. `options` and `metadata` use the `|| %{}` idiom, which is safe because no default is truthy (CLAUDE.md's `decode_<field>` rule).

**State encoding caveat (normative):** a map `state` with atom keys is sent with string keys and comes back from a JSON round trip with string keys. This is the same property every `metadata: map()` field in the tree already has. The Layer A round-trip tests use string-keyed state, and the moduledoc states the caveat.

`options` is forwarded to the wire **nowhere** in 24.4. It exists for parity with every sibling request struct (`ModerationRequest` and `EmbeddingRequest` both carry it) and for third-party adapters. The adapter ignores it and says so in its moduledoc.

### Layer A: `ALLM.ClassificationAnswer`

```elixir
defmodule ALLM.ClassificationAnswer do
  @type t :: %__MODULE__{
          type: ALLM.ClassificationQuestion.question_type(),
          choice: String.t() | nil,
          score: float() | nil,
          yes_probability: float() | nil,
          probabilities: %{String.t() => float()} | [float()] | nil,
          legend: [term()] | nil,
          confidence: float() | nil,
          metadata: map()
        }

  @enforce_keys [:type]
  defstruct [:type, :choice, :score, :yes_probability, :probabilities, :legend, :confidence, metadata: %{}]

  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc "The headline value: choice → option name, score → position, yes_no → P(yes)."
  @spec value(t()) :: String.t() | float()
  def value(answer)

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data)
end
```

**Field population by type (the normative home; conformance cases 2–5 bind it):**

| Field | `:choice` | `:score` | `:yes_no` |
|-------|-----------|----------|-----------|
| `choice` | option name, ∈ question criteria keys | `nil` | `nil` |
| `score` | `nil` | float, `0.0 ≤ x ≤ n_levels − 1` | `nil` |
| `yes_probability` | `nil` | `nil` | float, `0.0 ≤ x ≤ 1.0` (wire `noul`) |
| `probabilities` | `%{option => float}`, keys == criteria keys | `[float]`, `length == n_levels` | `nil` |
| `legend` | `nil` | `[term]`, `length == n_levels` | `nil` |
| `confidence` | float, `0.0 ≤ x ≤ 1.0` | float, `0.0 ≤ x ≤ 1.0` | `nil` |

Bounds are written as inequalities because a `0.0..1.0` Range is not valid Elixir for floats. Tests assert with `is_float(x) and x >= 0.0 and x <= 1.0`.

`@enforce_keys [:type]`, so `new/1` without `:type` raises `ArgumentError` (the `struct!/2` + `@enforce_keys` behaviour stated at `lib/allm/embedding.ex:56-57`). `value/1` is a three-clause function on `type`.

**Floats.** JSON `1` and `0` decode as integers. The **adapter** coerces every probability, score, `noul` and confidence with `* 1.0` (the same hazard `Embedding.decode_component/1` handles). `__from_tagged__/1` does **not** coerce: the maps and lists round-trip as identity, and the 24.1 serializability fixture pins a non-integral value.

**`__from_tagged__/1`:** `type` goes through `Serializer.to_atom_field/1`. Every other field passes through verbatim, with `metadata || %{}`.

### Layer A: `ALLM.ClassificationResponse`

```elixir
defmodule ALLM.ClassificationResponse do
  @type t :: %__MODULE__{
          request_id: String.t() | nil,
          provider_request_id: String.t() | nil,
          model: String.t() | nil,
          provider: atom() | nil,
          answers: %{String.t() => ALLM.ClassificationAnswer.t()},
          usage: ALLM.Usage.t(),
          raw: term(),
          metadata: map()
        }

  defstruct [:request_id, :provider_request_id, :model, :provider, :raw,
             answers: %{}, usage: %ALLM.Usage{}, metadata: %{}]

  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc "The answer for `id`, or nil. Atom ids are stringified."
  @spec answer(t(), String.t() | atom()) :: ALLM.ClassificationAnswer.t() | nil
  def answer(response, id)

  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data)
end
```

**`__from_tagged__/1`:**
- `answers` → `Map.new(data["answers"] || %{}, fn {k, v} -> {k, Serializer.hydrate(v)} end)`.
- `usage` → `Serializer.hydrate/1`, mirroring `EmbeddingResponse`'s `:usage`.
- `provider` → `Serializer.to_atom_field/1`. A bare `String.to_atom/1` would be untrusted-input atom growth.

**`usage` population:** the adapter sets `input_tokens` and `output_tokens` from the wire, sets `total_tokens` to their sum when both are integers, and leaves every cost field (`input_cost`, `output_cost`, `total_cost`) `nil`.

`model` is the **versioned** ID the provider reports (`"jev-1.13.0"`), not the alias that was sent. That is the documented reason for echoing it (Models page: *"The response's `model` field reports the versioned ID that answered"*).

### Layer A: `ALLM.Error.ClassificationAdapterError`

**Nine reasons.** This is the moderation enum (`lib/allm/error/moderation_adapter_error.ex:57-69`) **minus** `:unsupported_feature` and `:batch_too_large`, which have no use site here (agent-spec/DESIGN.md rule 13):

```elixir
@type reason ::
        :authentication_failed | :rate_limited | :invalid_request
        | :context_length_exceeded | :provider_unavailable | :timeout
        | :network_error | :malformed_response | :unknown
```

| Reason | Fires when | Use site |
|--------|-----------|----------|
| `:authentication_failed` | HTTP 401, 403 | `classify_classification_reason/3` |
| `:rate_limited` | 429 | same |
| `:invalid_request` | 400, 404, 422 (other than context length); empty questions before I/O; unencodable body (Decision #17); over a provider limit (Decision #18) | same + adapter gates |
| `:context_length_exceeded` | the 422 body the 24.4 oversized-state arm records | same. **Conditional:** if that arm shows no distinguishable signal, the atom is **pruned in 24.4** (both lists plus the doctest count), recorded as a RECORDS deviation |
| `:provider_unavailable` | 500, 502, 503, 504, **529** | same (Decision #8) |
| `:timeout` / `:network_error` | transport errors | `do_request/2` rescue |
| `:malformed_response` | 200 body not decodable, missing `answers`, an answer id not requested, a requested id missing, or an answer `type` ≠ question type | `decode_response/4` |
| `:unknown` | any other status | fallback |

The structure copies the moderation sibling exactly: moduledoc reason table, `@type reason`, a duplicate runtime `@legal_reasons ~w(…)a`, `legal_reasons/0` with a doctest asserting its length, `defexception [:reason, :message, :provider, :status, :retry_after_ms, :cause, metadata: %{}]`, `new/2` raising `ArgumentError` on an off-enum reason, three-clause `message/1`, `__from_tagged__/1`, and a trailing `defimpl Jason.Encoder` (not `@derive`). See `lib/allm/error/moderation_adapter_error.ex`.

### Layer A: closed-enum extensions and registration

| Module | Committed enum | Addition | Use site |
|--------|----------------|----------|----------|
| `ALLM.Error.EngineError` | `lib/allm/error/engine_error.ex` `@type reason` (last member `:no_moderation_adapter` at `:23`) and `@legal_reasons` (`:43`) | `:no_classification_adapter` | `do_classify_body/4` nil-adapter clause (24.3) |
| `ALLM.Error.ValidationError` | `lib/allm/error/validation_error.ex:41` and `:61` | `:invalid_classification_request` | `Validate.classification_request/1` (24.1) |
| `ALLM.Telemetry` | `lib/allm/telemetry.ex:94` (`@type span_name`) and `:96` (`@valid_span_names`) | `:classify` | `do_classify/3` span (24.3) |

**Both** declarations must change in each module (type union and runtime list). Neither `EngineError` nor `ValidationError` exposes `legal_reasons/0`. Their `@legal_reasons` is private and is read only by `new/2`'s guard (`lib/allm/error/engine_error.ex:74`, `lib/allm/error/validation_error.ex:93`), and `ALLM.Error.EngineError.legal_reasons()` raises `UndefinedFunctionError`. So the pin goes through `new/2`: `EngineError.new(:no_classification_adapter)` and `ValidationError.new(:invalid_classification_request, [])` must not raise, while an off-enum control does. Those tests go in the existing `test/allm/error/engine_error_test.exs` and `validation_error_test.exs` in **24.1**. The `EngineError` atom therefore lands with a test before its first caller in 24.3 (agent-spec/DESIGN.md rule 31).

**Serializer registration (part of the contract):** `@known_modules` (`lib/allm/serializer.ex:65-99`) gains `ALLM.Error.ClassificationAdapterError`, `ALLM.ClassificationQuestion`, `ALLM.ClassificationRequest`, `ALLM.ClassificationAnswer` and `ALLM.ClassificationResponse`, all five in 24.1 alongside their modules.

### Layer A: `ALLM.Validate.classification_request/1`

```elixir
@spec classification_request(ClassificationRequest.t()) :: :ok | {:error, ValidationError.t()}
```

The head clause hard-rejects a non-map `:questions`. The body accumulates per-field errors through the shared `finalize/3`, in the same shape as `moderation_request/1` (`lib/allm/validate.ex:385-396`).

Per-question rule scoping, so errors don't cascade:
- `:type` and `:instructions` rules run for every entry whose value is a `%ClassificationQuestion{}`.
- `:criteria` rules run only when `:type` is one of the three known atoms, because criteria shape is type-dependent.

**Field-error vocabulary: exhaustive.** The implementer never invents an atom. `id` below is the map key as given.

| Field path | Reason | Hard-reject? | Fires when |
|------------|--------|--------------|------------|
| `:questions` | `:invalid_shape` | **yes** | not a map |
| `:questions` | `:empty` | no | `%{}` |
| `:state` | `:invalid_shape` | no | non-nil and not a binary, map or list; **or** a struct; **or** a non-empty keyword list (`Keyword.keyword?/1`), which is almost always misplaced opts |
| `:state` | `:empty` | no | `nil`, `""`, `%{}` or `[]` (`nil` gets `:empty`, not `:invalid_shape`) |
| `:state` | `:not_json_encodable` | no | shape is fine but encoding fails (Decision #17) |
| `:model` | `:invalid_shape` | no | neither `nil` nor a binary |
| `[:questions, id]` | `:invalid_id` | no | key is not a non-empty binary |
| `[:questions, id]` | `:invalid_question` | no | value is not a `%ClassificationQuestion{}` |
| `[:questions, id, :type]` | `:invalid_type` | no | not `:choice`, `:score` or `:yes_no` |
| `[:questions, id, :instructions]` | `:empty` | no | `nil`, `""`, `%{}` or `[]` |
| `[:questions, id, :instructions]` | `:invalid_shape` | no | non-nil and not a binary, map or list |
| `[:questions, id, :criteria]` | `:invalid_shape` | no | choice: not a map. score: not a list. yes_no: neither nil nor a map with keys ⊆ `["true","false"]` |
| `[:questions, id, :criteria]` | `:empty` | no | choice `%{}` or score `[]` |
| `[:questions, id, :criteria]` | `:too_few_levels` | no | score with exactly 1 level. A provider-neutral semantic rule: one level always scores 0 |
| `[:questions, id, :criteria, option]` | `:invalid_option` | no | a choice key that is not a non-empty binary |
| `[:questions, id, :instructions]` / `[:questions, id, :criteria]` | `:not_json_encodable` | no | shape is fine but encoding fails (Decision #17) |

`:state` fires at most one of its three rows. They are evaluated in order: empty, then shape, then encodability, and encodability runs only when shape passes. Provider caps (255 options, 10 levels) are deliberately **absent** from this table (Decision #18).

### Layer B: `ALLM.ClassificationAdapter`

```elixir
@callback classify(ALLM.ClassificationRequest.t(), keyword()) ::
            {:ok, ALLM.ClassificationResponse.t()}
            | {:error, ALLM.Error.ClassificationAdapterError.t()}

@callback prepare_request(ALLM.ClassificationRequest.t(), keyword()) ::
            {:ok, Req.Request.t()} | {:error, ALLM.Error.ClassificationAdapterError.t()}

@optional_callbacks prepare_request: 2
```

That is two callbacks, one optional. There is no `max_batch_size/0` (Alternative E). Each callback traces to a user operation: `classify/2` is `ALLM.classify/3`'s dispatch target, and `prepare_request/2` is the escape hatch every adapter behaviour in the tree carries.

The moduledoc structure copies `lib/allm/moderation_adapter.ex`: summary → `## Minimum impl skeleton` (compilable) → `## HTTP transport guidance` → `## Invariants` (numbered) → a bold **"Cleanup invariant: none."** paragraph.

**Numbered invariants (normative; cited by number everywhere else):**

1. `classify/2` returns exactly `{:ok, %ClassificationResponse{}}` or `{:error, %ClassificationAdapterError{}}`. **Enforced:** `ALLM.classify/3` raises `ArgumentError` naming the adapter on any other shape, with the same wording and raise as `dispatch_moderate_attempt/3` (`lib/allm.ex:1878-1898`).
2. On `{:ok, _}`, `Map.keys(response.answers)` equals `Map.keys(request.questions)` as sets.
3. Each answer's `:type` equals its question's `:type`, and its fields follow the field-population table.
4. A `:choice` answer's `choice` is a key of that question's `criteria`, and its `probabilities` keys equal the criteria keys.
5. A `:score` answer's `probabilities` and `legend` each have length `length(criteria)`.
6. Empty questions (`questions == %{}`) are rejected with `:invalid_request` **before any I/O and before `ALLM.Keys.fetch!/2`**, so a keyless environment sees the rejection rather than `%EngineError{reason: :missing_key}`. This is Phase 20.2's ordering constraint (`lib/allm/moderation_adapter.ex:42-45`).
7. `request.metadata` round-trips onto `response.metadata` unchanged, and `opts[:request_id]` is reflected onto `response.request_id` unchanged.
8. `opts[:request_timeout]` is honoured. Exceeding it yields `:timeout`.
9. `prepare_request/2` (optional) returns an unfired `Req.Request` configured exactly as `classify/2` would fire it.

### Layer B: `ALLM.Engine` extension

**This table is the single source of truth for the site count.** Sites were located at `1859dac` by `grep -n moderation_adapter lib/allm/engine.ex`.

| # | Site | File:line | What |
|---|------|-----------|------|
| 1 | moduledoc serializability bullet | `lib/allm/engine.ex:41` | add to the module-typed field list |
| 2 | `@type t` | `:103` | `classification_adapter: module() \| nil` |
| 3 | `defstruct` | `:119` | nil-default group |
| 4 | `@engine_field_keys` | `:145` | `resolve_params/2` deny-list |
| 5 | `@module_fields` | `:165` | `new/1` module validation |
| 6 | `new/1` `@doc` prose | `:177` | sentence enumerating module fields |
| 7 | `resolve_params/2` `@doc` prose | `:468` | hand-written deny-list prose (the site a grep for the attribute misses) |
| 8 | `__from_tagged__/1` | `:510` | `restore_module(data["classification_adapter"])` |

That is eight sites: four code, three documentation, one decoder. The field name follows the noun rule Phase 22 set (`:moderation_adapter` matches `ModerationAdapter` and `:no_moderation_adapter`). The façade pattern-matches `%Engine{classification_adapter: adapter}` directly; there is no accessor.

### Layer C: façade

```elixir
@spec classification_request(ClassificationRequest.state(), keyword()) :: ClassificationRequest.t()

@spec classify(Engine.t(), ClassificationRequest.state() | ClassificationRequest.t(), keyword()) ::
        {:ok, ClassificationResponse.t()}
        | {:error, EngineError.t() | ValidationError.t() | ClassificationAdapterError.t()}
```

`classify/3` has a head with `opts \\ []` and two clauses. A `%ClassificationRequest{}` is dispatched verbatim, and it matches first (it is a map). Any binary, map or list is treated as state and routed through `classification_request/2`.

Two ambiguous inputs are routed deliberately:
- **Any other struct** (e.g. a mistakenly passed `%ModerationRequest{}`) enters as state and is rejected by the validator's `{:state, :invalid_shape}` struct rule. It is never serialized as ALLM's tagged envelope and sent to the provider.
- **A keyword list in the state position** (`classify(engine, [questions: q])`) is rejected by the keyword-list arm of the same row.

Both return `{:error, %ValidationError{}}` rather than raising `FunctionClauseError`. Anything else (`42`, `nil`) raises `FunctionClauseError` from the guarded clauses, matching `moderate/3`.

**Opt-lifting allow-list:** `@classification_request_field_opts [:questions, :model, :options, :metadata]`. **Symmetry invariant:** this list equals the `%ClassificationRequest{}` field set minus `:state`, and 24.3 pins that with a test comparing it against `Map.keys(%ClassificationRequest{}) -- [:__struct__, :state]`. `drop_classification_request_opts/1` strips the same keys from the adapter's opts. `classification_request/2` stringifies atom question IDs (Decision #3) and does nothing else to the questions.

**Model resolution (Decision #5):** `effective_model = request.model || Keyword.get(opts, :model)`. `Engine.resolve_model/2` is **not** called. Note that `:model` is in the allow-list, so on the state path `opts[:model]` is already on the struct; the `||` matters only for a prebuilt request plus a call-site `:model`. Stamping writes `effective_model` onto the request when it is non-nil.

**Gate order inside the span (normative):**
1. Adapter presence: a **pattern match** on `%Engine{classification_adapter: nil}` in the first `do_classify_body/4` clause, giving `EngineError.new(:no_classification_adapter)`.
2. Model stamping, placed **before** validation so that a call-site `:model` on a prebuilt request is validated too (a tuple `:model` gives `{:model, :invalid_shape}`, not a Fake-green, provider-red pass).
3. `ALLM.Validate.classification_request/1`.
4. `ALLM.Retry.run/3`-wrapped dispatch, with the wrap in `do_classify_body/4` following the moderation/image convention (`lib/allm.ex:1835-1842`). The policy is `augment_retry_policy(engine.retry, @retryable_classification_reasons)` with `@retryable_classification_reasons [:rate_limited, :provider_unavailable, :timeout, :network_error]`. That is the same four as the moderation list at `lib/allm.ex:1744`, and it reuses the existing shared helper unchanged.

**Dispatch opts:** `build_classify_dispatch_opts/3` mirrors `build_moderate_dispatch_opts/3` (`lib/allm.ex:1846-1864`), including the final `Engine.put_cursor_key(engine)`. **Omitting that call makes every façade-driven Fake script share one cursor across content-equal engines, silently.** The per-attempt closure `dispatch_classify_attempt/3` maps a retryable reason to `{:retry, err.retry_after_ms || 0, err}` and raises `ArgumentError` on invariant-1 violations.

**`:stream` is silently dropped**, matching `moderate/3` and `embed/3`. Key resolution is not done at the façade: `:api_key` is forwarded, and the adapter calls `ALLM.Keys.fetch!(:typesafe, opts)` after its own gates.

**A missing key is raised, not returned.** `Keys.fetch!/2` raises `%EngineError{reason: :missing_key}` and no sibling rescues it (`lib/allm/providers/openai/moderation.ex:820`). `@doc classify/3` states this in a "Raises" section. The Error Contract lists it as raised.

**Telemetry: `[:allm, :classify, :start | :stop | :exception]`.**

| Key | Kind | `:start` | `:stop` ok | `:stop` error |
|-----|------|----------|------------|---------------|
| `request_id`, `engine`, `model` (effective, may be nil) | metadata | ✓ | ✓ | ✓ |
| `question_count` | metadata | ✓ | ✓ | ✓ |
| `usage` | metadata | — | `response.usage` | `nil` |
| `response` / `error` | metadata | — | response / `nil` | `nil` / error |
| `answer_count` | measurement | — | `map_size(answers)` | `0` |

`question_count/1` is a two-clause private: `map_size` for a map, `0` otherwise. It has to tolerate a non-map because `:start` metadata is built **before** validation, the same hazard `moderation_input_count/1` is written around (`lib/allm.ex:1793-1796`).

### Wire-field map: TypeSafe

**Endpoint:** `POST https://api.typesafe.ai/v1/systemone` (not overridable, matching Voyage's fixed `@base_url`, `lib/allm/providers/voyage/embeddings.ex:220-221`). **Auth:** `Authorization: Bearer <key>`, `Content-Type: application/json`. **Key atom:** `:typesafe`.

Every row is **confirmed** (quoted from TypeSafe docs fetched 2026-09-22) or **inferred** (it gets a 24.4 probe arm).

| Concern | Wire | Status |
|---------|------|--------|
| Request envelope | `{"state": …, "model": "jev-latest", "questions": {"<id>": Question}}` (all three required) | **confirmed** (API reference) |
| `state` | string, object or array | **confirmed** |
| Question `type` | `"choice"` \| `"score"` \| `"noul"`. ALLM `:yes_no` ↔ `"noul"` | **confirmed** |
| `instructions` | string, object or array | **confirmed** |
| choice `criteria` | `map<option, string\|object\|array\|null>`, max 255 | **confirmed** |
| score `criteria` | ordered array, *"should have at least two levels; the API accepts up to 10"* | **confirmed** |
| noul `criteria` | optional `{"true": …, "false": …}` | **confirmed** |
| Question id | caller key, *"not sent to the underlying model"* | **confirmed** |
| Response envelope | `{"model": "jev-1.13.0", "answers": {…}, "usage": {"input_tokens", "output_tokens"}}` | **confirmed** |
| Choice answer | `{"type":"choice","choice","probabilities":{opt: f},"confidence"}` | **confirmed** |
| Score answer | `{"type":"score","score","legend":{"0": desc},"probabilities":{"0": f},"confidence"}` | **confirmed** |
| Noul answer | `{"type":"noul","noul": f}`, no confidence | **confirmed** |
| Score `legend` value for **object** criteria | a string (the API types `legend` as `map<string, string>`) or the object echoed back | **inferred**: probe arm 2 |
| Error statuses | 401, 422, 429, 529 | **confirmed** (Errors table) |
| 400/403/404 | the SDK maps these to exception classes | **inferred**: arm 7 (bad model) |
| Error body envelope | *"a JSON body describing what went wrong"*; exact shape undocumented | **inferred**: arms 3, 7, 8 record it. `extract_error_message/1` tries `detail` (string, or a list of `%{"msg"}`), then `error.message`, then `message`, then a fixed fallback, and narrows to what is observed |
| Context-length signal | undocumented | **inferred**: arm 9 |
| Correlation header | `x-typesafe-request-id` | **inferred** (SDK doc only): arm 1 |
| `Retry-After` / `retry-after-ms` | the SDK honours both | **inferred**: parsed if present, never required |
| Unknown-field handling | undocumented | **inferred**: arm 11 (negative control) |
| Question-count cap | undocumented | **inferred**: arm 10 (ladder) |
| Pricing | *"$0.042 / Mtok … Charged per input token. Output tokens are free."* | **confirmed** (Models page) |

### Layer B: `ALLM.Providers.TypeSafe.Classification`

```elixir
@behaviour ALLM.ClassificationAdapter
@base_url "https://api.typesafe.ai/v1"
@endpoint "/systemone"
@default_model "jev-latest"
```

**`classify/2` order:**
1. **Script short-circuit.** Any non-nil `opts[:adapter_opts][:classification_script]`, **including `[]`**, delegates to `FakeClassification.classify/2`. This copies `OpenAI.Moderation`'s escape hatch (`lib/allm/providers/openai/moderation.ex:351-355`).
2. `prepare_request/2`, which runs:
   1. the empty-questions gate;
   2. the provider-limit gates (Decision #18);
   3. the encodability check and body build (Decisions #15, #17);
   4. `ALLM.Keys.fetch!(:typesafe, opts)`;
   5. `Req.new/1` with `:receive_timeout` from `opts[:request_timeout]` and the `:plug` stub from `adapter_opts`.
3. One `Req.request/1`. There is no inner retry (Decision #19).
4. Decode, or build the error.

**`prepare_request/2` is implemented, and `classify/2` is built on it.** Under a script it returns `{:error, %ClassificationAdapterError{reason: :unknown, metadata: %{cause: :scripted_adapter}}}`, mirroring moderation's `stub_error/1` (`lib/allm/providers/openai/moderation.ex:787-793`, reason `:unknown`). Invariant 8 is bound by asserting `prepared.options[:receive_timeout]`. A `Req.Test` plug never consults `:receive_timeout` (`test/allm/providers/voyage/embeddings_test.exs:412-420`), so a stub-driven "expiry" test cannot bind it.

`@doc false` + `@spec` test seams (following the moderation family's naming banner):

| Function | Contract |
|----------|----------|
| `to_json_body/2` | `(request, opts) → map()`. Injects `@default_model` when `request.model` is nil (Decision #15). `:yes_no` → `"noul"`. Omits `criteria` for a yes_no question whose criteria is nil. Returns a bare `map()` (the capability family's shape) |
| `gate_limits/2` | `(request, opts) → :ok \| {:error, ClassificationAdapterError.t()}`. `@max_choice_options 255`, `@max_score_levels 10` (Decision #18) |
| `decode_response/4` | `(body, headers, request, opts) → {:ok, ClassificationResponse.t()} \| {:error, ClassificationAdapterError.t()}`. Enforces invariants 2–5, and any violation is `:malformed_response`. Converts the score maps to lists by integer-parsing the keys `"0".."n-1"`, with any gap giving `:malformed_response`. Coerces floats. `provider: :typesafe`, `provider_request_id` from the header, `usage` per the response contract |
| `to_classification_adapter_error/5` | `(status, body, headers, key, opts)`. The family's argument order plus the **resolved key**, because `redact_key_material/2` needs it and `opts[:api_key]` is nil whenever the key came from the environment (agent-spec/DESIGN.md rule 23) |
| `classify_classification_reason/3` | `(status, message, retry_after_ms) → {reason, retry_after_ms \| nil}`, the same tuple shape as Voyage's `classify_embedding_reason/3` (`lib/allm/providers/voyage/embeddings.ex:905-922`) |
| `redact_key_material/2` | `(message, key)`. Decision #16 |

`sanitize_cause/1` blanks `Jason.DecodeError`'s `:data`. There is no `body_preview` field (CLAUDE.md: ship no less safe than the embeddings siblings). `:options` on the request is ignored and documented as such.

### Layer B: `ALLM.Providers.FakeClassification`

```elixir
@type script_entry ::
        {:answers, %{String.t() => String.t() | number() | ALLM.ClassificationAnswer.t()}}
        | {:error, ALLM.Error.ClassificationAdapterError.t()}
        | {:retry_until_call, pos_integer()}
```

- **With no script** (`:classification_script` absent or `[]`), every question gets a deterministic default. For a choice: the lexicographically first option, probability `1.0` on it and `0.0` on the others, confidence `1.0`. For a score: `score: 0.0`, probabilities `[1.0, 0.0, …]`, `legend` = criteria, confidence `1.0`. For a yes_no: `yes_probability: 0.0`.
- **`{:answers, map}`** overrides per id, and any id not listed gets its default. The value is interpreted by the question's type. Each row below that says "raise" raises `ArgumentError` naming the question id and what it accepts, because it is a test-author bug and should not pass green.

  | Value \ question type | `:choice` | `:score` (n levels) | `:yes_no` |
  |---|---|---|---|
  | binary | must be a criteria key, else raise | raise | raise |
  | number | raise | `x * 1.0`, must be in `0..n−1`, else raise. `lo = floor(x)`, `hi = ceil(x)`: if `lo == hi`, probability `1.0` at `lo`; otherwise `hi − x` at `lo` and `x − lo` at `hi`. `confidence` = the max probability | `x * 1.0`, must be in `0..1`, else raise |
  | `%ClassificationAnswer{}` | verbatim | verbatim | verbatim |

  An id in the map that is **not** a question raises.
- **Response fields:**
  - `model: request.model || "fake-classification"`
  - `provider: :fake`
  - `usage: %ALLM.Usage{input_tokens: 0, output_tokens: 0, total_tokens: 0}`
  - `request_id: opts[:request_id]`
  - `metadata: request.metadata`
  - `provider_request_id: nil`
  - `raw: nil`
- **`:capture_pid` seam:** when `adapter_opts[:capture_pid]` is set, the Fake sends `{ALLM.Providers.FakeClassification, :call, %{request: request, opts: opts}}` to that pid first, even for gate-rejected calls. This is the FakeModeration message shape (`maybe_capture/2`, `lib/allm/providers/fake_moderation.ex:351-356`), and it is what lets 24.3 assert the request the adapter actually received.
- **A non-empty script that has been exhausted** returns `{:error, %ClassificationAdapterError{reason: :unknown, metadata: %{cause: :classification_script_exhausted}}}`.
- **Cursor:** `adapter_opts[:script_cursor]` → `adapter_opts[:cursor_key]` → `:erlang.phash2(script)`, with the moduledoc text copied from `fake_moderation.ex`'s `## Cursor behaviour`.
- **Pre-flight:** the empty-questions gate (invariant 6) runs before the script is consumed.
- **The moduledoc states outright that the Fake's confidence convention is its own and is NOT TypeSafe's formula** (Decision #9).

### Layer B: `ALLM.Test.ClassificationAdapterConformance`

This lives in `conformance/`, which is a **second Mix project** with its own gates. The structure copies `conformance/lib/allm/test/moderation_adapter_conformance.ex`: `use ExUnit.CaseTemplate`, `@case_count`, `case_count/0`, a `using/1` that injects one `describe/2`, and a compilation constraint that every `ALLM.*` call sits inside the quote. Every case asserts unconditionally, and none is gated on an optional fixture (agent-spec/DESIGN.md rule 26). The request each case sends is built inline, with one question of each type.

**Script contract (a `## Script contract` moduledoc section):**
- Cases 1–5 and 7–9 each pass an explicit `adapter_opts: [classification_script: [{:answers, %{}}]]`, meaning one entry that yields defaults.
- Case 6 passes **no** script.
- An adapter under test therefore either answers the scripted call itself, or short-circuits it (any non-nil `:classification_script` value) to a Fake.
- Without this contract, the script-less cases would reach `Keys.fetch!/2` and the network for every short-circuiting adapter.

**`@case_count 9`:**
1. answer keys equal question keys (invariant 2)
2. each answer's type equals its question's type (invariant 3)
3. choice answer fields (invariant 4 + table)
4. score answer fields (invariant 5 + table)
5. yes_no answer fields, `confidence == nil` (table)
6. `questions: %{}` with no script and no `:api_key` is rejected with `:invalid_request` (invariant 6). The harness cannot unset env vars from an async case, so this case binds the *outcome* only. The "before I/O and before the key" ordering is bound per adapter: for TypeSafe, by 24.4's test that plugs a `Req.Test` stub failing on any request and runs with the env var unset in an `async: false` module
7. `request.metadata` round-trips (invariant 7)
8. `opts[:request_id]` is preserved (invariant 7)
9. `response.usage` is a `%ALLM.Usage{}`

**`## What this suite does NOT bind`:**
- Invariant 1, which the façade enforces and which is bound by `allm_classify_test.exs`.
- Invariant 8 (timeouts).
- For an adapter that short-circuits to a script (FakeClassification, `TypeSafe.Classification`), cases 1–5 and 7–9 exercise the **Fake**, not that adapter's decoder. For TypeSafe, the decoder's invariants 2–5 are bound by 24.4's `decode_response/4` fixture tests. *Do not read a green run of this suite as evidence that a provider's decoder is correct.*

**Companion files** (copying the moderation family): `conformance/test/support/fixtures/scripted_classification_stub.ex`, whose gates run ahead of its script; `conformance/test/allm/test/classification_adapter_conformance_test.exs`, with three meta-invariants (`case_count/0 == 9`, the injected describe has exactly that many tests, and `using/1` raises `KeyError` without `:classification_adapter`); and `test/allm/providers/typesafe/classification_conformance_test.exs`, the main-repo two-liner.

---

## Module Tree

```
lib/allm/
├── classification_question.ex                 (NEW — 24.1)
├── classification_request.ex                  (NEW — 24.1)
├── classification_answer.ex                   (NEW — 24.1)
├── classification_response.ex                 (NEW — 24.1)
├── classification_adapter.ex                  (NEW — 24.2)
├── error/
│   ├── classification_adapter_error.ex        (NEW — 24.1)
│   ├── engine_error.ex                        (MODIFY — 24.1, +:no_classification_adapter in both lists)
│   └── validation_error.ex                    (MODIFY — 24.1, +:invalid_classification_request in both lists)
├── serializer.ex                              (MODIFY — 24.1, +5 @known_modules)
├── validate.ex                                (MODIFY — 24.1, +classification_request/1 + rule block)
├── engine.ex                                  (MODIFY — 24.2, every site in the Engine-extension table)
├── telemetry.ex                               (MODIFY — 24.3, +:classify span name in both lists + moduledoc row)
└── providers/
    ├── fake_classification.ex                 (NEW — 24.2)
    └── typesafe/
        └── classification.ex                  (NEW — 24.4)

lib/allm.ex                                    (MODIFY — 24.3, classify/3 + classification_request/2 + internals + moduledoc capability-table row)

conformance/
├── lib/allm/test/classification_adapter_conformance.ex        (NEW — 24.2)
└── test/
    ├── support/fixtures/scripted_classification_stub.ex       (NEW — 24.2)
    └── allm/test/classification_adapter_conformance_test.exs  (NEW — 24.2)

test/allm/
├── classification_question_test.exs           (NEW — 24.1)
├── classification_request_test.exs            (NEW — 24.1)
├── classification_answer_test.exs             (NEW — 24.1)
├── classification_response_test.exs           (NEW — 24.1)
├── error/classification_adapter_error_test.exs (NEW — 24.1)
├── validate_classification_request_test.exs   (NEW — 24.1)
├── error/engine_error_test.exs                (MODIFY — 24.1, new/2 accepts :no_classification_adapter)
├── error/validation_error_test.exs            (MODIFY — 24.1, new/2 accepts :invalid_classification_request)
├── examples_helpers_test.exs                  (MODIFY — 24.5, chat_provider?/1 + classification_engine/1 + classification_opts/0)
├── classification_adapter_test.exs            (NEW — 24.2, behaviour surface + Fake conformance invocation)
├── engine_test.exs                            (MODIFY — 24.2, :classification_adapter accept/reject/round-trip/deny-list)
├── allm_classify_test.exs                     (NEW — 24.3)
└── providers/
    ├── fake_classification_test.exs           (NEW — 24.2)
    └── typesafe/
        ├── classification_test.exs            (NEW — 24.4, seam units + decoder fixtures)
        ├── classification_wire_test.exs       (NEW — 24.4, Req.Test + raw-bytes provenance)
        └── classification_conformance_test.exs (NEW — 24.4)

test/support/
├── fake_classification_fixtures.ex            (NEW — 24.2)
└── typesafe_fixtures.ex                       (NEW — 24.4, recorded/1 + synthesized/1 + drop_comment/1)

test/fixtures/typesafe/classification/
├── recorded/                                  (NEW — 24.4, recorder-written; files listed in 24.4.2)
└── synthesized/
    ├── error_401.json                         (NEW — 24.4, `_comment`, planted literal test key)
    ├── error_429.json                         (NEW — 24.4, `_comment`, retry-after header in test)
    ├── error_529.json                         (NEW — 24.4, `_comment`)
    ├── answer_id_missing.json                 (NEW — 24.4, `_comment`, → :malformed_response)
    └── integer_probabilities.json             (NEW — 24.4, `_comment`, pins * 1.0 coercion)

scripts/record_typesafe_classification_fixtures.exs   (NEW — 24.4, loads project-root .env via EnvLoader)

test/
├── layer_a_docs_test.exs                      (MODIFY — 24.1, +4 @layer_a)
├── allm_facade_doctest_inventory_test.exs     (MODIFY — 24.3, +classify: 3, classification_request: 2)
├── guides_test.exs                            (MODIFY — 24.5, +classification.md)
└── guides_doctest_test.exs                    (MODIFY — 24.5, +doctest_file/1)

guides/classification.md                       (NEW — 24.5)
examples/
├── 22_classify_ticket.exs                     (NEW — 24.5, `# Provider: typesafe`; number = next free at build time)
├── _helpers.exs                               (MODIFY — 24.5, "typesafe" row, classification_engine/1, chat_provider?/1, nil rows)
├── run_all.exs                                (MODIFY — 24.5, marker-less scripts only on chat arms — Decision #14)
├── README.md                                  (MODIFY — 24.5, key table + typesafe arm)
└── RUN_OUTPUT_TYPESAFE.md                     (NEW — 24.5, from the live run only; deferred-when-key-absent)

mix.exs                                        (MODIFY — 24.1/24.2/24.4/24.5, see gate table)
CHANGELOG.md                                   (MODIFY — 24.5)
steering/allm_engine_session_streaming_spec_v0_2.md   (MODIFY — 24.5, §41 + §27/§29/§35.7 amendments)
```

`ALLM.Keys` is **not** modified (Assumption 6). `README.md` is **not** in the tree for any sub-phase. At 24.1 start, run `git stash push -- README.md` if README has local edits.

### Repo-wide audit-gate obligations

| Gate | Fails | Sub-phase | Row |
|------|-------|-----------|-----|
| `test/groups_for_modules_audit_test.exs` | closed, bidirectional | 24.1, 24.2, 24.4 | `mix.exs` `groups_for_modules`. 24.1: four structs → "Data types" (near `:168-170`), the error → Errors (near `:198`). 24.2: `ALLM.ClassificationAdapter` → Behaviours (near `:119`), `FakeClassification` → Providers (near `:135`). 24.4: `ALLM.Providers.TypeSafe.Classification` → Providers (near `:125`). Register each module only in the sub-phase that creates it |
| `test/layer_a_docs_test.exs` | **open** | 24.1 | `@layer_a` (after `:36-38`): the four structs |
| `test/allm_facade_doctest_inventory_test.exs` | **open**, one-directional | 24.3 | `classification_request: 2` (after `:26`), `classify: 3` (after `:42`) |
| `test/package_files_extras_consistency_test.exs` | closed | 24.5 | `mix.exs` `@guides` (`:65-77`); `package.files` already ships `guides` |
| `test/guides_test.exs` + `test/guides_doctest_test.exs` | closed for `@guides` (parity meta-tests vs `mix.exs` and `guides/`); open for `doctest_file/1` registration | 24.5 | `@guides` (`:23-35`) and a `doctest_file("guides/classification.md")` line (near `:19`) |

### Path-existence sanity check

`ls -d lib/allm lib/allm/error lib/allm/providers conformance/lib/allm/test conformance/test/support/fixtures conformance/test/allm/test test/allm test/allm/error test/allm/providers test/support test/fixtures scripts guides examples` was run on 2026-09-22 and all exist. **New directories:** `lib/allm/providers/typesafe/`, `test/allm/providers/typesafe/`, `test/fixtures/typesafe/classification/{recorded,synthesized}/`. Fixtures are `.json`.

---

## Phases

Every sub-phase's Verification includes the uniform gate block below (agent-spec/DESIGN.md rule 31). It is written out once here and referenced as **[G]**. **Before 24.1's first edit**, capture the docs-audit baseline: `mix run scripts/audit_user_docs.exs | sed -E 's/:[0-9]+:/:/' | sort > .work/phase24_audit_baseline.txt`. Line numbers are stripped so that pre-existing hits whose lines shift don't show up as diffs. The script already exits 1 at `1859dac` on pre-existing hits, and a `grep classif` filter would miss a banned token in `lib/allm.ex`, `engine.ex`, `validate.ex` or `telemetry.ex` on a line that doesn't mention classification.

```bash
mix test && mix test --seed 0
mix format --check-formatted && mix credo --strict && mix dialyzer
mix run scripts/audit_user_docs.exs | sed -E 's/:[0-9]+:/:/' | sort > /tmp/audit_after.txt; diff .work/phase24_audit_baseline.txt /tmp/audit_after.txt  # must be empty
grep -rl 'Keys.put(\|Logger.configure(\|System.put_env(\|:telemetry.attach' test/  # only async: false modules
```

### Phase 24.1: Layer A classification data (Layer A)

**Goal:** four structs, one error, one validator, and the enum and registry edits, with no adapter, engine field or façade.

#### 24.1.1 Test Plan (write first)

`classification_question_test.exs`:
- `new/1` defaults every field to nil. An unknown key raises `KeyError`.
- `choice/2` with a list of names builds a string-keyed map with nil descriptions.
- `choice/2` with atom-keyed map options stringifies the keys.
- `choice/2` with a binary `options` raises `FunctionClauseError`.
- `score/2` keeps the level order. `score/2` with a map raises `FunctionClauseError`.
- `yes_no/2` with no opts has `criteria: nil`. With `true:`/`false:` it has a `%{"true" => …, "false" => …}` subset. An unknown opt raises `ArgumentError`.

`classification_request_test.exs`:
- Defaults (`state: nil`, `questions: %{}`, …).
- An unknown key raises `KeyError`.
- `questions: %{}` is constructible.

`classification_answer_test.exs`:
- `new/1` without `:type` raises `ArgumentError`.
- `value/1` for each of the three types.

`classification_response_test.exs`:
- `answer/2` by string id, by atom id, and for a missing id (nil).

`error/classification_adapter_error_test.exs`:
- `ClassificationAdapterError.legal_reasons/0` has 9 entries (8 after 24.4 if it prunes `:context_length_exceeded`).
- An off-enum reason raises `ArgumentError`.
- The default message and the raw-struct `message/1` fallback.

`validate_classification_request_test.exs`:
- **One test per vocabulary-table row** (re-read the table at write time; don't count from memory).
- A valid request with one question of each type returns `:ok`.
- Hard-reject: `questions: []` yields exactly `[{:questions, :invalid_shape}]`.
- Accumulation of two independent violations.
- `state: nil` yields `:empty`, not `:invalid_shape`.
- `state: %ALLM.ModerationRequest{}` and `state: [questions: %{}]` each yield `{:state, :invalid_shape}`.
- `state: %{"a" => {1, 2}}` and `state: %{{1, 2} => "x"}` each yield `{:state, :not_json_encodable}`. The second must not raise (Decision #17).
- A choice with 300 options passes the validator, because the cap lives in the adapter (Decision #18).

`test/allm/error/engine_error_test.exs` and `validation_error_test.exs` (MODIFY): `EngineError.new(:no_classification_adapter)` and `ValidationError.new(:invalid_classification_request, [])` do not raise. Their off-enum controls still raise `ArgumentError`. These are the enum pins described in the enum-extension section.

**Serializability (blocking):**
- Each of the five modules round-trips through `:erlang.term_to_binary/1` and through `Serializer.to_json!/1 |> from_json/1`.
- A request carrying one question of each type, with a string-keyed **map** state and a structured-object `instructions`, round-trips with the questions still `%ClassificationQuestion{}` (pins `decode_questions/1`).
- A response whose answers map holds all three types, with a non-integral probability `0.3770173638956106` and score lists, round-trips as identity (pins Alternative D and the no-coercion rule).
- `provider: :typesafe` survives as an atom.
- A question's `type` survives as an atom.

#### 24.1.2 Implementation Checklist

- [ ] Five modules per the contract blocks, including `decode_questions/1` and the builders' guarded heads
- [ ] `EngineError`/`ValidationError` enums: **both** declarations each
- [ ] `Validate.classification_request/1` + a `# Internal: classification_request rules` block
- [ ] `Serializer.@known_modules` +5
- [ ] `@layer_a` +4 (fail-open: verify by the generated-test count moving from its pre-edit value, which you measure first)
- [ ] `mix.exs` `groups_for_modules` for the five modules (fail-closed)

#### 24.1.3 Verification

`mix test test/allm/classification_*_test.exs test/allm/error/classification_adapter_error_test.exs test/allm/validate_classification_request_test.exs`, then **[G]**.

**Success criterion:** the six new test files pass. `groups_for_modules_audit_test.exs` passes with the new modules registered. The `layer_a_docs_test.exs` test count rose by exactly the four `@layer_a` entries' generated tests.

#### 24.1.4 Binding on later sub-phases
- **Score probabilities/legend are lists, with index = level.** This binds 24.4's `decode_response/4`, which converts the wire's string-keyed maps. It binds 24.2's Fake too.
- **`:yes_no` is the only Layer A spelling. `"noul"` appears only inside `ALLM.Providers.TypeSafe.Classification`.** This binds 24.4 and 24.5: the guide may *mention* the alias, but no Layer A doc may use it as a type.

### Phase 24.2: Behaviour, engine field, Fake, conformance (Layer B)

**Goal:** the runtime contract and its reference implementation, with no façade.

#### 24.2.1 Test Plan (write first)

`classification_adapter_test.exs`:
- `use ALLM.Test.ClassificationAdapterConformance, classification_adapter: ALLM.Providers.FakeClassification`, so all 9 cases pass.
- `behaviour_info(:callbacks)` contains `classify/2` and `prepare_request/2`.
- `optional_callbacks == [prepare_request: 2]`.
- A module implementing only `classify/2` compiles without warnings (`capture_io(:stderr, …)` around `Code.compile_string/1`).

`fake_classification_test.exs`, driving `classify/2` **directly** with an explicit `adapter_opts[:cursor_key]`:
- The no-script defaults for each type match the Fake contract, including lexicographically-first option selection over options `["zeta", "alpha"]`.
- `{:answers, %{"d" => "billing"}}` sets the choice, and other ids get defaults.
- `{:answers, %{"s" => 1.25}}` gives score `1.25` with probabilities `[0.0, 0.75, 0.25]`.
- `{:answers, %{"y" => 0.9}}` gives `yes_probability: 0.9`, `confidence: nil`.
- A choice value that is not an option raises `ArgumentError` naming the options.
- `{:error, err}` is returned verbatim.
- The script `[{:answers, %{}}, {:retry_until_call, 3}, {:answers, %{}}]` gives: call 1 succeeds; calls 2–3 are `:rate_limited`; call 4 succeeds from the third entry. (The leading entry forces `advance` to WRITE the slot that `peek` READS; see CLAUDE.md. Without a trailing entry, call 4 would be `:classification_script_exhausted`.)
- An exhausted non-empty script gives `:classification_script_exhausted`.
- `questions: %{}` gives `:invalid_request` before any script entry is consumed.
- Numeric shorthand edge cases each raise `ArgumentError`: score `3` on 3 levels; yes_no `1.5`; a number for a choice; a binary for a score; an id that isn't a question. Integer score `1` gives `score: 1.0` with probability `1.0` at level 1.
- `:capture_pid` receives the request, including for a gate-rejected call.

`engine_test.exs` (MODIFY):
- `new/1` accepts `classification_adapter: Mod`.
- `{Mod, []}` raises `ArgumentError`.
- A JSON round-trip preserves the module.
- `resolve_params/2` does not leak the key.

Conformance self-test (`conformance/`, driven by `ScriptedClassificationStub`): the three meta-invariants.

#### 24.2.2 Implementation Checklist

- [ ] `classification_adapter.ex`: callbacks, numbered invariants, skeleton, "Cleanup invariant: none."
- [ ] `engine.ex`: **every** row of the Engine-extension table, including prose site 7
- [ ] `fake_classification.ex` + `test/support/fake_classification_fixtures.ex`
- [ ] Conformance harness + stub + self-test; `@case_count 9`; the "does NOT bind" section
- [ ] `mix.exs` groups: behaviour → Behaviours, Fake → Providers

#### 24.2.3 Verification

The targeted tests, then **[G]**, then `cd conformance && mix test && mix credo --strict && mix format --check-formatted`.

**Success criterion:** FakeClassification passes 9/9. Both Mix projects are green on all gates.

#### 24.2.4 Binding on later sub-phases
- **Invariant 6 requires the empty-questions gate (and, per Decision #18, the limit gates) ahead of `ALLM.Keys.fetch!/2`.** This binds 24.4. Conformance case 6 cannot enforce the ordering (a sourced `.env` masks it), so 24.4's `async: false` gate-ordering test with a flunking plug is what binds it.
- **`build_classify_dispatch_opts/3` must call `Engine.put_cursor_key/2`.** This binds 24.3.
- **`@case_count 9` is frozen.** A new case is appended at 10 and bumps the attribute.

### Phase 24.3: Façade and telemetry (Layer C)

**Goal:** `ALLM.classify/3` end to end over FakeClassification.

#### 24.3.1 Test Plan (write first)

`allm_classify_test.exs`:
- A binary state plus `questions:` returns `{:ok, resp}` with an answer per id.
- Map state and list state are accepted.
- A prebuilt `%ClassificationRequest{}` is dispatched verbatim.
- Atom question ids are stringified by the builder, and the response is keyed by strings.
- A missing adapter gives `:no_classification_adapter`, **and** that fires ahead of an invalid request (both conditions present at once).
- An invalid request gives `%ValidationError{reason: :invalid_classification_request}`, and the adapter is never called (the Fake script is not consumed).
- **Model resolution (Decision #5), asserted via the Fake's `:capture_pid`:**
  - An engine with `model: "gpt-x"` and no request model reaches the adapter with `request.model == nil`.
  - `opts[:model]` is stamped.
  - An explicit `request.model` wins over `opts[:model]`.
  - A prebuilt request plus call-site `model: {:bad}` gives `{:model, :invalid_shape}`, and the adapter is never called (stamp-before-validate).
- **Cursor injection (24.2.4 binding):** two content-equal engines with distinct `:id`s, driven by interleaved `ALLM.classify/3` calls against the same two-entry script, each receive entry 1 on their first call.
- `classify(engine, [questions: q])` returns `{:error, %ValidationError{}}` with `{:state, :invalid_shape}`.
- A retryable scripted error is retried and then succeeds (façade-level, asserting the final result only).
- `retry: false` surfaces the first error.
- An adapter returning a bare map raises `ArgumentError` naming invariant 1.
- `stream: true` is ignored.
- `:request_id` is propagated onto the response.
- The allow-list equals the struct fields minus `:state` (the symmetry test).
- **Telemetry**, via `test/support/telemetry_capture.ex` (a per-process filter; never a global `:telemetry.attach` in an async module):
  - `:start` carries `question_count`.
  - `:stop` ok carries `answer_count` and `usage`.
  - `:stop` error carries `answer_count: 0` and `usage: nil`.
  - `question_count` is `0` for a non-map `questions` (it must not raise).
- Doctests for `classify/3` and `classification_request/2`.

#### 24.3.2 Implementation Checklist

- [ ] `lib/allm.ex`: the block per the façade contract, placed after the moderation block
- [ ] `telemetry.ex`: `:classify` in both lists + the moduledoc event row
- [ ] `lib/allm.ex` moduledoc capability table (the rows at `:59-61`): add "Answer typed questions about text (choice / score / yes-no)" → `classify/3` → `{:ok, %ALLM.ClassificationResponse{}}`
- [ ] `@doc classify/3` sections: Model resolution, One call many questions, Validation, Raises (`:missing_key`)
- [ ] `@public_facade` +2 (fail-open)

#### 24.3.3 Verification

`mix test test/allm/allm_classify_test.exs test/allm_facade_doctest_inventory_test.exs`, then **[G]**.

**Success criterion:** every bullet passes, and the facade inventory test count rose by 2.

### Phase 24.4: `ALLM.Providers.TypeSafe.Classification` (Layer B)

**Goal:** the real adapter, a recorder with a live four-part probe, and fixtures.

**Prerequisite:** `TYPESAFE_API_KEY` is in `.env` (Assumption 7). Invocation: `set -a; . ./.env; set +a; mix run scripts/record_typesafe_classification_fixtures.exs`.

#### 24.4.1 Test Plan (write first)

`classification_test.exs` (seams, with no HTTP):
- `to_json_body/2` maps `:yes_no` → `"noul"`, injects `"jev-latest"` when the model is nil, keeps an explicit model, and omits nil yes_no criteria.
- Unencodable state (a tuple value, and a tuple **key**) gives `:invalid_request` with `cause: :unencodable_body` and nothing in `:cause`, **before key resolution**. It is driven by `classify/2` directly, since the façade validator would catch it first.
- `gate_limits/2`: 255 options is `:ok` and 256 is `:invalid_request`; 10 levels is `:ok` and 11 is `:invalid_request`. Both fire before key resolution.
- **Gate ordering** (an `async: false` module; `TYPESAFE_API_KEY` deleted in `setup` and restored `on_exit`; a `Req.Test` plug that flunks on any request): empty questions and over-limit questions each return `:invalid_request` without raising `:missing_key` and without reaching the plug.
- `prepare_request/2` sets `options[:receive_timeout]` from `request_timeout:` (binds invariant 8). Under a script it returns the `:scripted_adapter` stub error.
- `decode_response/4` on each `recorded/` fixture produces the field-population table. Score maps become ordered lists. `provider: :typesafe`. `model` is the versioned id. `usage` is populated.
- `decode_response/4` on `answer_id_missing.json` gives `:malformed_response`. An extra id gives `:malformed_response`. A type mismatch gives `:malformed_response`.
- `integer_probabilities.json` gives floats.
- `classify_classification_reason/3`: 401 and 403 → auth, 429 → rate_limited (with `retry_after_ms` from the header), 422 → invalid_request, 529 and 503 → provider_unavailable, 418 → unknown, plus the context-length signal if arm 9 found one.
- `redact_key_material/2` removes the literal key from `error_401.json`. The companion test asserts the OpenAI, Gemini and Voyage regexes (copied from their adapters) match **nothing** in the same fixture.

`classification_wire_test.exs` (`Req.Test` via `adapter_opts[:plug]`):
- The emitted request body matches the wire-field map.
- The `Authorization: Bearer` header is sent.
- A `Req.Test.transport_error(conn, :timeout)` gives `:timeout`, and `:econnrefused` gives `:network_error`. These bind the error mapping only; the plumbing is bound by the `prepare_request/2` test.
- Exactly one HTTP attempt on a 503 through `classify/2` directly (no inner retry, Decision #19).
- **Provenance:** one test per `recorded/` file reads the raw bytes with `File.read!/1 |> Jason.decode!/1` and asserts `refute Map.has_key?(raw, "_comment")`, with a failure message naming the recorder invocation. One test per `synthesized/` file asserts the marker is present.

`classification_conformance_test.exs`: the harness two-liner with an `@moduledoc` stating which invariants it does and does not bind for this adapter.

#### 24.4.2 The live wire probe (four required parts)

These are CLAUDE.md's four parts, with `scripts/record_voyage_embeddings_fixtures.exs` as the model:
- **Overwrite guard first:** check every target path, so a fully recorded tree costs zero calls.
- **Assert, don't narrate:** any want/got mismatch prints a table to stderr and `System.halt(1)`s before any fixture is written.
- **Record bodies, error envelopes included.**
- **A negative control.**

| Arm | Request | Expected | Records |
|-----|---------|----------|---------|
| 1 | one choice + one score + one noul, string state | 200; `x-typesafe-request-id` present | `recorded/mixed_questions.json` + a header note in RECORDS |
| 2 | object state, object `instructions`, object score levels | 200 | `recorded/structured_state.json`; settles the `legend`-for-object row |
| 3 | question `type: "ranking"` | 422 | `recorded/error_422_bad_type.json` |
| 4 | choice with 256 options | 422 | `recorded/error_422_too_many_options.json` |
| 4b | choice with **255** options | 200 | `recorded/choice_255_options.json`; binds `@max_choice_options` from the accepting side |
| 5 | score with 11 levels | 422 | `recorded/error_422_too_many_levels.json` |
| 5b | score with **10** levels | 200 | `recorded/score_10_levels.json`; binds `@max_score_levels` from the accepting side |
| 7 | `model: "jev-allm-probe-nonexistent"` | status in 400/404/422 | `recorded/error_bad_model.json` |
| 8 | bogus key | 401 | `recorded/error_401_live.json`; the probe asserts the body does not contain the sent key |
| 9 | ~40k-token state | 4xx | `recorded/error_context_length.json`; decides whether `:context_length_exceeded` is kept |
| 10 | question ladder `[1, 32, 128, 512]` of trivial nouls, stopping at the first non-200 | each step is 200 **or** a 4xx; a 5xx or transport error halts | `recorded/probe_question_ladder.json`: `{"max_ok": n, "first_failure": {"size", "status", "body"} \| null}`. The finding goes into the adapter moduledoc. It does not become a gate (Alternative E) |
| 11 | **negative control:** arm 1 plus an invented question field `"allm_probe_field": "x"` | 422 (*inferred*) | `recorded/negative_control.json` (status + body). **A 200 is a legitimate finding.** The implementer amends this row's expectation and the wire map's "unknown-field handling" row, then reruns, and notes that acceptance-based evidence is weakened for this endpoint |

(There is no arm 6. Numbering is kept stable against the wire map's cross-references.)

**Cost:** arms 1–8 and 11 are about 300 input tokens each, except 4/4b, which are about 3k each. Arm 9 is about 40k tokens. Arm 10 is about 15k tokens. That totals under 60k tokens, which is **< $0.003 per clean run** at $0.042/Mtok. First implementation is budgeted at 4× that, **< $0.02**. The implementer's report cites actuals (rule 19).

#### 24.4.3 Implementation Checklist

- [ ] The adapter per the contract, including the moduledoc wire-field table and the `noul` alias note
- [ ] The recorder + probe, loading the project-root `.env` through `EnvLoader` before reading the key, modelled on `scripts/record_voyage_embeddings_fixtures.exs` (it is the recorder that does). Without that, a bare `mix run` reports "key not set" in a provisioned checkout (CLAUDE.md); `test/support/typesafe_fixtures.ex` (a `drop_comment/1` of its own, or the existing one reused if it is already shared, which you check first)
- [ ] The synthesized fixtures, each with `_comment: "Synthesized — Phase 24.4 …"`
- [ ] Prune `:provider_request_id` if arm 1 observed no `x-typesafe-request-id` header (Decision #13)
- [ ] Narrow `extract_error_message/1` and the wire-map "inferred" rows to what the probe observed; record the transcript in RECORDS
- [ ] Prune `:context_length_exceeded` if arm 9 shows no signal (both lists, the doctest count, and the 24.1 test)
- [ ] `mix.exs` groups: the adapter → Providers

#### 24.4.4 Verification

The recorder invocation (a discrete step). Then `mix test test/allm/providers/typesafe/`, then **[G]**.

**Success criterion:** the probe exits 0 with every recorded fixture free of `_comment`. A second recorder run makes zero HTTP calls, because every arm, including 10 and 11, now writes a guarded file. The adapter passes 9/9 conformance. `grep -rn '"noul"' lib/ | grep -v providers/typesafe` is empty.

### Phase 24.5: Spec §41, guide, examples, wiring

#### 24.5.1 Test Plan

- `guides/classification.md` is registered in all three lists, passes `guides_test.exs`'s structural gates (more than 2 KB, at least one `iex>`, zero audit hits), and every `iex>` block runs under FakeClassification.
- The guide sections are: engine slot; the three question types and when to use each (citing TypeSafe's guidance); confidence routing done in caller code; model pinning; one call with many questions; errors and retries; telemetry; testing with FakeClassification.
- `examples/22_classify_ticket.exs` asserts a typed answer per question type and prints confidence.
- **The live gate is BLOCKING:** `ALLM_PROVIDER=typesafe mix run examples/run_all.exs` exits 0 and runs **only** script 22. `ALLM_PROVIDER=openai mix run examples/run_all.exs` shows `[SKIP] 22_…` and its prior script set is unchanged (compare the pre/post `--- NN_` line list).

#### 24.5.2 Implementation Checklist

- [ ] Spec §41 (sections mirroring §39: goals, data model, behaviour, engine integration, public API, one-call guidance, provider adapter, testing, telemetry, out of scope). §27 and §29 amendments. The §35.7 capability-only-provider carve-out per Decision #10, placed after the Phase 22 amendment block. Each amendment block opens with `> **Phase 24 amendment (commits <first>..<last>).**`
- [ ] Guide + `mix.exs` `@guides` + `guides_test.exs` + `guides_doctest_test.exs`
- [ ] Examples: the typesafe row (`adapter: nil`, `classification_adapter`, `classification_default_model: "jev-latest"`, `key_env: "TYPESAFE_API_KEY"`); `classification_adapter: nil` on the other rows; `classification_engine/1` + `classification_opts/0` per Decision #14; `chat_provider?/1`; the `run_all.exs` rule; the README key table
- [ ] `test/allm/examples_helpers_test.exs`: `chat_provider?/1` is true for openai/anthropic/gemini and false for typesafe; `classification_engine/1` sets no `:model`; `classification_opts/0` honours `ALLM_CLASSIFICATION_MODEL` (an `async: false` describe, since it touches env)
- [ ] `RUN_OUTPUT_TYPESAFE.md` regenerated from the live run in this commit, or not created at all
- [ ] CHANGELOG entries derived from `git diff <prior-tag>..HEAD lib/`, never from this design's prose

#### 24.5.3 Verification

**[G]**, then `mix run scripts/check_guide_fences.exs | head -1`, then both `run_all` invocations above.

### Phase 24.6: `[CHORE]` sweep

**Module Tree:** whatever deferrals 24.1–24.5 filed. Each one is filed with a self-scoring predicate and closed here, or explicitly re-filed with a reason. **Known candidate:** none at design time.

**Verification:** **[G]**, plus every filed ticket's predicate run with its exit code pasted.

---

## Error Contract

| Function | Reason | Recovery guidance |
|----------|--------|-------------------|
| `classify/3` | `EngineError :no_classification_adapter` | Set `classification_adapter:` on the engine. |
| `classify/3` | `EngineError :missing_key`, **raised** (not returned) | Set `TYPESAFE_API_KEY` or pass `api_key:`. Callers matching `{:error, _}` do not catch it. |
| `classify/3` | `ValidationError :invalid_classification_request` | Fix the field named in `errors`; nothing was sent. |
| `classify/3` | `ClassificationAdapterError :authentication_failed` | Bad or revoked key; do not retry. |
| `classify/3` | `:rate_limited` / `:provider_unavailable` (incl. 529) | Retried automatically per `engine.retry`; surfaced after the attempts are exhausted. |
| `classify/3` | `:invalid_request` | The provider rejected the body (e.g. an unknown model); do not retry. |
| `classify/3` | `:context_length_exceeded` (if kept in 24.4) | Shrink the state; the 32k budget covers state plus the longest question. |
| `classify/3` | `:malformed_response` | Provider/decoder contract breach; report with `provider_request_id` if one was captured. |
| `classify/3` | `:timeout` / `:network_error` | Retried automatically. |

---

## Definition of Done

- [ ] Sub-phases 24.1–24.6 each pass their own Verification block
- [ ] `mix test` has zero failures and zero warnings; coverage is ≥ 80% global and ≥ 90% on new modules
- [ ] `mix credo --strict`, `mix dialyzer` and `mix format --check-formatted` are clean in **both** Mix projects
- [ ] Every new public function has an `@spec` and a runnable doctest
- [ ] Every Layer A module has term and JSON round-trip tests
- [ ] FakeClassification and TypeSafe.Classification both pass the conformance suite (every case in its `@case_count`)
- [ ] The live probe and `ALLM_PROVIDER=typesafe mix run examples/run_all.exs` are green, with actual cost reported against the 24.4.2 estimate
- [ ] Every fail-open gate in the audit table is registered, verified by test-count deltas
- [ ] Spec §41 and the amendments carry commit-range provenance
- [ ] CHANGELOG is derived from `git diff`, and `README.md` is untouched

## Records

Per-sub-phase records: `steering/2026-09-22_JEV_SUPPORT_RECORDS.md` (created on first need).
