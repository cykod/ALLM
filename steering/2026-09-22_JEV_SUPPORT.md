# Phase 24: Typed Classification (TypeSafe Jev): Design Document

*Generated 2026-09-22 · Measured against: `1859dac` · Cites refreshed against `9510ed9` (2026-09-27), after Phases 23 and 25–27 landed*

> **Goal:** Add a provider-neutral, non-streaming **classification** primitive (`ALLM.classify/3`) and bundle a TypeSafe adapter for it. An ALLM app can then ask Jev typed questions (pick one option, score on a rubric, yes/no) about a piece of state and get calibrated, typed answers back without generating any text.
> **Outcome:** `ALLM.classify(engine, ticket_text, questions: %{"department" => ClassificationQuestion.choice("Which team?", ["billing", "technical", "sales"])})` returns `{:ok, %ALLM.ClassificationResponse{}}` against `POST https://api.typesafe.ai/v1/systemone`, and `ClassificationResponse.answer(resp, "department").choice == "billing"`. Every Jev answer type decodes to a typed `%ALLM.ClassificationAnswer{}`, and `ALLM_PROVIDER=typesafe mix run examples/run_all.exs` exits 0.
> **Spec sections:** new **§41** (Typed classification). Amends **§27** (module tree), **§29** (telemetry), **§35.7** (bundled-adapter rule: third admission criterion), **§35.10** (reconciles the "classification is not a primitive" line).
> **Layers touched:** A, B, C, one layer per sub-phase (24.1 = A, 24.2 = B, 24.3 = C, 24.4 = B, 24.5 = docs, 24.6 = `[CHORE]` sweep).

**Number checks (run 2026-09-22):**
- `grep -rn "Phase 24\|§41" steering/*.md CLAUDE.md` returns nothing.
- Phase 23 shipped **§40** (compact tool disclosure, `steering/allm_engine_session_streaming_spec_v0_2.md:3617`); §37 is audio and §38 is reserved for batch. Phases 25–27 (audio, streaming audio/ElevenLabs, prompt caching) built before this one and left Phase 24 / §41 reserved for it (`steering/2026-09-24_SST_SUPPORT.md:12`, `steering/2026-09-25_ELEVENLABS_TTS_SST.md:21-22`). Re-run 2026-09-27: `grep -n '^## 4[1-9]' steering/allm_engine_session_streaming_spec_v0_2.md` → nothing.
- This design therefore takes **Phase 24 / §41**. The §41 heading is `## 41. v0.6 — Typed classification`, matching the sibling `## 39. v0.6 — Content moderation`.

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
7. **`TYPESAFE_API_KEY` is provisioned in the project-root `.env`** (`grep -c TYPESAFE .env` → 1, run 2026-09-27). The 24.4 recorder/probe and the 24.5 live gate therefore run for real; there is no key-absent deferral route. Per CLAUDE.md, the recorder must load `.env` itself (via `EnvLoader`), or be invoked as `set -a; . ./.env; set +a; mix run …`.
8. **`llm_db` is still not a dependency** (`mix.exs:39` comment), and it has no TypeSafe catalog entry in any case. Model strings stay late-resolved (§6.3).

---

## Alternatives Considered

### A. Where the TypeSafe adapter ships (resolved by the owner)

§35.7 currently has four rules:

- The Phase 20 amendment admits an adapter when *"**either** (a) its maintenance overlaps with its provider's already-bundled chat adapter, **or** (b) it is the provider's own officially-recommended path for a capability that provider does not itself offer"* (`steering/allm_engine_session_streaming_spec_v0_2.md:2424`, restated at `:3540`).
- The Phase 22 amendment adds a family-shape carve-out (`:2430-2440`): *"A capability family may be bundled with **exactly one** provider adapter when that provider is already bundled for chat, and the capability's absence on the other bundled providers is documented rather than backfilled with a proxy."*
- The Phase 26 amendment adds a **third** scoped carve-out (`:2442-2452`) admitting ElevenLabs, a provider with no bundled chat adapter, into the audio family — and *"It admits nothing outside §37"*.

TypeSafe fails all four. There is no bundled TypeSafe chat adapter, no bundled provider names TypeSafe as a partner, a one-adapter classification family's only provider is *not* bundled for chat, and the Phase 26 carve-out is scoped to §37. Separately, §35.10 lists *"image classification / object detection as distinct primitives — users build these on top of chat + vision"* as out of scope (`:2483`).

| Option | Trade-off |
|--------|-----------|
| **A1: in core, amend §35.7 (chosen by owner)** | One package and one release train. Needs a fourth scoped carve-out, family-scoped to §41 in the Phase 26 style, covering both admission and family shape (Decision #10), plus a §35.10 reconciliation paragraph modelled on §39's *"Why a classification primitive is admitted where object detection is not"*. |
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
**Layer B (modified):** `ALLM.Engine` (+`:classification_adapter` and `:classification_model` at every site in the Engine-extension table), `ALLM.Telemetry` (+`:classify` span name; lands in 24.3 with its only caller).
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
engine = ALLM.Engine.new(classification_adapter: ALLM.Providers.TypeSafe.Classification, classification_model: "jev-1.13.0")
{:ok, resp} = ALLM.classify(engine, ticket, questions: questions)
%{choice: team, confidence: c} = ALLM.ClassificationResponse.answer(resp, "department")
```

There is deliberately **no Layer D**. A classification carries no conversation state, and `ALLM.Session` is untouched.

### Prerequisites

- The Phase 22 moderation family is the structural template for the Layer A pair, error enum, Fake and conformance suite: `lib/allm/moderation_adapter.ex`, `lib/allm/moderation_request.ex`, `lib/allm/moderation_response.ex`, `lib/allm/error/moderation_adapter_error.ex`, `lib/allm/providers/fake_moderation.ex`, `lib/allm/providers/openai/moderation.ex`, `conformance/lib/allm/test/moderation_adapter_conformance.ex`, and the façade block in `lib/allm.ex`: public `moderation_request/2` (`:1213`) and `moderate/3` (`:1384-1398`); internals `do_moderate/3` through `moderate_stop_extras/1` (`:2296-2470`).
- The Phase 25 audio family is the closer template for the façade and the adapter's HTTP shape: slot model, no capability pre-flight, one HTTP attempt, provider id in `:id`, and the shared `build_capability_dispatch_opts/3` / `fill_request_id/2`. See `lib/allm.ex`'s audio internals block (`:2472-2692`) and `lib/allm/providers/support/transcription_adapter.ex`.
- The shared adapter helpers in `lib/allm/providers/support/http_response.ex` and `lib/allm/providers/support/redact.ex` (consolidated in `6167d79` and `a09c32f`) are reused, not re-implemented (see the adapter contract).
- `TYPESAFE_API_KEY` in the project-root `.env` (Assumption 7: present).
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
5. **Classification carries its own engine slot model, `:classification_model`, and never reads `engine.model`.** This follows the Phase 25 audio precedent, spec §37.4 (`steering/allm_engine_session_streaming_spec_v0_2.md:2995`): *"Each audio slot carries its own model, and the audio façades never read `engine.model`."* Moderation's rule would be wrong here: `do_moderate_body/5` stamps `request.model || resolved_model`, where `Engine.resolve_model/2` falls back to `engine.model` (`lib/allm.ex:2326`, `:2378`; `lib/allm/engine.ex:429-430`). On an engine that carries a chat model and a classification adapter together, that would send `"gpt-…"` to TypeSafe and get a guaranteed 4xx. Resolution, normative, copying §37.4: `request.model || engine.classification_model`, then the adapter's documented default `"jev-latest"` when still nil. On the state call shape `opts[:model]` reaches `request.model` through the opt-lifting allow-list; a prebuilt `%ClassificationRequest{}` is authoritative and `opts[:model]` is not merged onto it (the audio rule). The per-slot field keeps the Jev model persisted with its adapter, so a serialized engine pairing a chat provider with TypeSafe round-trips intact, and the examples build the engine through the shared `capability_engine/2` spec map with `engine_model_field: :classification_model` (Decision #14). *Docs target: `@doc ALLM.classify/3` "Model resolution" + adapter `@doc classify/2` + `@moduledoc ALLM.Engine`.*
6. **No chunking and no question-count callback.** See Alternative E. *Docs target: `@doc ALLM.classify/3` "One call, many questions".*
7. **No `Capability.preflight_classification/2`.** This follows the audio family, which has no capability pre-flight either (spec §37.1 item 5, `:2860`); it departs from §39.1 goal 5. Its only possible input is an `llm_db` catalog entry. `llm_db` is not a dependency (Assumption 8), and no catalog carries TypeSafe models. Moderation's preflight is inert in practice for the same reason (`lib/allm/capability.ex`'s `preflight_moderation/2`, which returns `:ok` without a catalog). Adding a sixth inert helper would be speculative surface. If a catalog ever carries Jev, it gets added then. *Docs target: spec §41.4 (one sentence).*
8. **HTTP 529 maps to `:provider_unavailable`, so it is retried.** TypeSafe documents `529 Overloaded` (API reference, Errors table). The committed precedent is Anthropic chat, `lib/allm/providers/anthropic.ex:541-542`:
   ```elixir
   defp classify_reason(status, _type, _msg, ra) when status in [500, 502, 503, 504, 529],
     do: {:provider_unavailable, ra}
   ```
   No other non-chat adapter maps 529 (it falls through to `:unknown` there). Because the façade retries on reason atoms (`augment_retry_policy/2`, `lib/allm.ex:2104-2114`), no status-level `retry_on` widening is needed. *Docs target: `@moduledoc ALLM.Error.ClassificationAdapterError` status table.*
9. **Confidence is reported, never computed. `:yes_no` answers carry `confidence: nil`.** TypeSafe: *"Noul has no separate `confidence`"* (Primitives page). The Fake invents its own deterministic confidence and says so in its moduledoc (the Fake contract below); the real adapter never does. *Docs target: `@moduledoc ALLM.ClassificationAnswer`.*
10. **§35.7 gains a fourth scoped carve-out, family-scoped to §41 (owner decision).** Alternative A quotes the rules it sits beside. It is deliberately **not** labelled "(c)", because criteria (a)/(b) are about admission and the Phase 22 addition is about family shape; this one has to cover both, as the Phase 26 carve-out does for §37. It is placed after the Phase 26 amendment block and written in that block's family-scoped style, so it sits **alongside** the Phase 26 carve-out and does not generalise it. Proposed text:

    > *An adapter from a provider with no bundled chat adapter may be bundled into the classification family (§41), as its **sole** member, when (i) no bundled provider offers typed classification through a dedicated endpoint, (ii) the provider's API for it is a single, documented HTTP surface, and (iii) the capability's absence on every bundled chat provider is documented rather than backfilled with a proxy.*

    Its one beneficiary is `ALLM.Providers.TypeSafe.Classification`. It exempts the family from the Phase 22 carve-out's *"already bundled for chat"* condition, and from nothing else. Like the §36, §39 and Phase 26 amendments, it is a carve-out and not a widening: it does not license a second TypeSafe-shaped provider for a capability that a bundled provider already serves, and **it admits nothing outside §41** — TypeSafe gets no chat, image, embedding, moderation or audio adapter by this route. The §41 intro also reconciles §35.10 in the §39 style: typed classification has a dedicated single-call endpoint with calibrated per-option probabilities, which chat composition cannot reproduce. *Docs target: spec §35.7 amendment + §41 intro. §41 also records that Decisions #5 and #7 depart from §39.1 goal 5 ("model resolution and capability pre-flight … apply identically").*
11. **The Fake returns default answers when there is no script, and errors when a script is exhausted.** This copies the moderation split (`lib/allm/providers/fake_moderation.ex:24-28`, `:40-42`), not FakeEmbeddings' "no script is an error". *Docs target: `@moduledoc ALLM.Providers.FakeClassification`.*
12. **`usage` is populated; `cost` stays nil.** The wire returns `usage: {input_tokens, output_tokens}` (API reference), which maps onto the existing `ALLM.Usage` fields (`lib/allm/usage.ex:55-56`). *Docs target: `@moduledoc ALLM.ClassificationResponse`.*
13. **The provider's request id goes in `ClassificationResponse.id`, not a metadata key.** TypeSafe's SDK surfaces *"The `x-typesafe-request-id` response header"* (SDK Exceptions page), which is what a user sends to TypeSafe support. The field name follows the capability family: every response struct pairs the provider's id in `:id` with ALLM's `:request_id` (`Response`, `ImageResponse`, `EmbeddingResponse`, `ModerationResponse`, `SpeechResponse`, `TranscriptionResponse`), and ElevenLabs already puts its `request-id` header into `SpeechResponse.id` (`lib/allm/providers/elevenlabs/speech.ex:634-635`). Putting it in `:metadata` would break conformance invariant 7 (`request.metadata` round-trips unchanged). `:request_id` stays ALLM's own correlation id, with **no** header fallback — diverging on purpose from Voyage's `request_id: Keyword.get(opts, :request_id) || header_value(headers, "x-request-id")`, whose moduledoc admits the fallback is unreachable through `ALLM.embed/3`. If probe arm 1 observes no `x-typesafe-request-id` header, `:id` stays in the struct (family shape) and is always `nil` from this adapter; the moduledoc says so and RECORDS notes the finding. *Docs target: `@moduledoc ALLM.ClassificationResponse`.*
14. **A capability-only provider arm in `examples/`, following the Phase 26 ElevenLabs precedent.** The mechanism already exists: marker-less scripts run only on arms where `ExamplesHelpers.chat_provider?/1` is true (`examples/_helpers.exs:399-411`, used by `examples/run_all.exs:143-147`, header comment `:21-31`), and the `"elevenlabs"` row (`examples/_helpers.exs:164-182`) is the model for a row with `adapter: nil`. So the typesafe arm needs **no** `run_all.exs` logic change. What 24.5 adds: a `"typesafe"` row copying the elevenlabs row's shape (every key present, `adapter: nil`, `default_model: nil`, `vision_default_model: nil`, every other capability key nil) plus `classification_adapter: ALLM.Providers.TypeSafe.Classification`, `classification_default_model: "jev-latest"`, `key_env: "TYPESAFE_API_KEY"`; `classification_adapter: nil` and `classification_default_model: nil` on all four existing rows (elevenlabs included); and `classification_engine/1` as a `capability_engine/2` spec map with `adapter_key: :classification_adapter`, `model_key: :classification_default_model`, `engine_model_field: :classification_model`, `key_env_key: nil` and `model_env: "ALLM_CLASSIFICATION_MODEL"` (Decision #5; `examples/_helpers.exs:423-429`: a new capability is a spec map, not a new copy). There is no `classification_opts/0`. The classify script carries `# Provider: typesafe`. The comment-only widening of "an audio-only arm" to "a capability-only arm (audio: elevenlabs; classification: typesafe)" lands at `run_all.exs:27-31`, the `## The audio-only arm` moduledoc section of `_helpers.exs` (`:76-82`) and `examples/README.md:119`. *Docs target: `examples/README.md` + `@moduledoc ExamplesHelpers`.*
15. **The adapter injects `model: "jev-latest"` when the effective model is nil, and documents that.** This satisfies CLAUDE.md's rule that an adapter MUST document any default it injects for a Layer-A nil the wire requires (the API marks `model` required). The default goes in the public `@doc classify/2` AND in `to_json_body/2`'s `@doc false`. `jev-latest` is an alias that moves; the guide says to pin `jev-1.13.0` when tuning thresholds (Models page, "Aliases"). *Docs target: adapter `@doc classify/2` + `guides/classification.md`.*
16. **Redaction removes the literal resolved key as well as a pattern.** TypeSafe does not document its key format, so no prefix regex can be written honestly at design time. `redact_key_material/2` receives the resolved key and replaces that exact string — **only when `byte_size(key) >= 8`**, so a short test key cannot rewrite ordinary substrings of the message. A prefix pattern is added **only if** the 24.4 probe (a) confirms a prefix from the maintainer's key without printing it, and (b) records it in RECORDS; it then lives in `ALLM.Providers.Support.Redact.typesafe/1` (that module's one-function-per-provider rule, `lib/allm/providers/support/redact.ex`), and `redact_key_material/2` adds only the literal-key pass on top. Otherwise the literal-key pass is the whole defence. The companion test calls `Support.Redact.openai/1`, `.anthropic/1`, `.gemini/1`, `.voyage/1` and `.elevenlabs/1` **directly** (never copied regexes) and asserts each leaves the planted fixture unchanged (CLAUDE.md: inheriting a sibling's regex is a silent no-op). The planted key in `synthesized/error_401.json` is realistic-length (≥ 32 chars). *Docs target: internal.*

    > CORRECTED 2026-09-28 (24.4 probe): the maintainer's key has the prefix `apikey_` (108 chars, `[A-Za-z0-9_-]`; checked without printing it). `Support.Redact.typesafe/1` (`\bapikey_[A-Za-z0-9_\-]{16,}`) was therefore added, and `redact_key_material/2` runs the literal pass then that pattern. The recorded live 401 does not echo the key. See RECORDS 24.4.
17. **JSON-encodability is checked twice: by the validator, and again in the adapter as a second line of defence. Neither check may raise.** `Jason.encode/1` does **not** always return an error tuple. Verified in `mix run` on 2026-09-22:
    - `Jason.encode(%{"a" => {1, 2}})` returns `{:error, %Protocol.UndefinedError{}}`.
    - `Jason.encode(%{{1, 2} => "x"})` **raises** `Protocol.UndefinedError` (String.Chars, from `Jason.Encode.key/2`).

    Both call sites therefore use a shared shape: `try Jason.encode(term) rescue Protocol.UndefinedError -> :error`, treating `{:error, _}` and the rescue alike. The validator's version reports `{:state, :not_json_encodable}` or `[:questions, id, :instructions | :criteria], :not_json_encodable`. The adapter's version returns `%ClassificationAdapterError{reason: :invalid_request, metadata: %{cause: :unencodable_body}}` before key resolution. The exception is **never** stored in `:cause`, because it carries user data or pids that would break the error struct's `Jason.Encoder`. *Docs target: `@doc ALLM.classify/3` "Validation" + adapter `@doc classify/2`.*

    > CORRECTED 2026-09-27 (24.1 fix): `rescue Protocol.UndefinedError` is not enough. `Jason.encode(%{"a" => [1 | 2]})` **raises** `FunctionClauseError` (from `Jason.Encode.list_loop/3`) for an improper list, measured with `mix run` on jason 1.4.4. The shared shape is `rescue _ -> :error`. See RECORDS 24.1.
18. **Provider limits live in the adapter, not the validator.** TypeSafe's documented caps (255 choice options; 10 score levels) are wire facts about one provider, so they are enforced by `ALLM.Providers.TypeSafe.Classification`'s pre-flight gates as `:invalid_request` with `metadata: %{question: id, limit: n}`, **before key resolution**. This follows the moderation precedent: *"Per-item MIME and byte-size rules are not here: they are provider-specific and live in the adapter"* (`steering/2026-08-31_PHASE_22_moderation.md`, Validate section). A future second adapter does not inherit TypeSafe's numbers. The validator keeps only provider-neutral semantic rules, such as a 1-level score being meaningless. *Docs target: adapter `@moduledoc` "Limits" section.*
19. **The TypeSafe adapter has no inner retry loop; the façade's `Retry.run/3` is the only one.** The moderation and embeddings adapters wrap each attempt in their own `ALLM.Retry.run/3`, so `:timeout` costs 3 × 3 = 9 attempts through the façade (CLAUDE.md's `embed/3` corollary). The audio transcription adapters already dropped that: `Support.TranscriptionAdapter` makes *"One HTTP attempt per call, with no retry loop"* (`lib/allm/providers/support/transcription_adapter.ex:14`, `:152-160`), and that is the precedent followed here. A direct `classify/2` call makes exactly one HTTP attempt — `prepare_request/2` passes `retry: false` to `Req.new/1` explicitly, as every sibling does (`lib/allm/providers/openai/transcription.ex:429`, `lib/allm/providers/elevenlabs/transcription.ex:541`), so the one-attempt test does not depend on Req's defaults — and `retry_after_ms` is populated for callers that retry themselves. *Docs target: adapter `@moduledoc` "Retry integration".*

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

**`__from_tagged__/1`:** `type` decodes through `ALLM.Serializer.to_atom_field/1` (`lib/allm/serializer.ex:210-212`, `String.to_existing_atom/1`). `instructions` and `criteria` pass through verbatim, because JSON already yields string keys and lists, so the round trip is identity for every builder-produced value. There is no `||` default (all defaults are `nil`).

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
          id: String.t() | nil,
          request_id: String.t() | nil,
          model: String.t() | nil,
          provider: atom() | nil,
          answers: %{String.t() => ALLM.ClassificationAnswer.t()},
          usage: ALLM.Usage.t(),
          raw: term(),
          metadata: map()
        }

  defstruct [:id, :request_id, :model, :provider, :raw,
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
- `usage` → a private `hydrate_usage/1` copying `EmbeddingResponse`'s: `nil → %ALLM.Usage{}`, a tagged map → `Serializer.hydrate/1`. A bare `Serializer.hydrate/1` is wrong here, because `Serializer.hydrate(nil)` returns `nil` (`lib/allm/serializer.ex:203`) and would break `usage: Usage.t()` for a payload without the key. This knowingly adds the **sixth** private copy that the open `[DEFERRED-DRY]` ticket (`.work/ASKS.md:179`, owner: a stand-alone `[REFACTOR]`) tracks; 24.6 updates that ticket's measured count.
- `provider` → `Serializer.to_atom_field/1`. A bare `String.to_atom/1` would be untrusted-input atom growth.

**`usage` population:** the adapter sets `input_tokens` and `output_tokens` from the wire, sets `total_tokens` to their sum when both are integers (the same arithmetic `ALLM.Usage.total_tokens/1` does, `lib/allm/usage.ex:114-120`), and leaves every cost field (`input_cost`, `output_cost`, `total_cost`) and both prompt-cache counters (`cached_input_tokens`, `cache_write_input_tokens`) `nil`.

**`id`:** the provider's request id from the `x-typesafe-request-id` response header (Decision #13), `nil` when absent.

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

> CORRECTED 2026-09-28 (24.4 probe): the oversized-state arm gets **400** with `{"detail": {"error_type": "max_tokens_exceeded"}}` (no message) — a distinguishable signal, so `:context_length_exceeded` is **kept**, keyed on that `error_type`. TypeSafe also answers **400**, not 422, for an unknown question type, an unknown model and a limit breach; **422** is only FastAPI schema validation (e.g. `questions: {}`). The `ClassificationAdapterError` moduledoc's status cell for `:context_length_exceeded` was corrected from 422 to 400. See RECORDS 24.4.

The structure copies the moderation sibling exactly: moduledoc reason table, `@type reason`, a duplicate runtime `@legal_reasons ~w(…)a`, `legal_reasons/0` with a doctest asserting its length, `defexception [:reason, :message, :provider, :status, :retry_after_ms, :cause, metadata: %{}]`, `new/2` raising `ArgumentError` on an off-enum reason, three-clause `message/1`, `__from_tagged__/1`, and a trailing `defimpl Jason.Encoder` (not `@derive`). See `lib/allm/error/moderation_adapter_error.ex`.

### Layer A: closed-enum extensions and registration

| Module | Committed enum | Addition | Use site |
|--------|----------------|----------|----------|
| `ALLM.Error.EngineError` | `lib/allm/error/engine_error.ex` `@type reason` (`:23-25`) and `@legal_reasons` (`:45-47`) | `:no_classification_adapter` | `do_classify_body/4` nil-adapter clause (24.3) |
| `ALLM.Error.ValidationError` | `lib/allm/error/validation_error.ex` `@type reason` (`:41-43`) and `@legal_reasons` (`:63-65`) | `:invalid_classification_request` | `Validate.classification_request/1` (24.1) |
| `ALLM.Telemetry` | `lib/allm/telemetry.ex` `@type span_name` (`:131`) and `@valid_span_names` (`:145`) | `:classify` | `do_classify/3` span (24.3) |

**Both** declarations must change in each module (type union and runtime list). Neither `EngineError` nor `ValidationError` exposes `legal_reasons/0`. Their `@legal_reasons` is private and is read only by `new/2`'s guard (`lib/allm/error/engine_error.ex:77-78`, `lib/allm/error/validation_error.ex:96-97`), and `ALLM.Error.EngineError.legal_reasons()` raises `UndefinedFunctionError`. So the pin goes through `new/2`: `EngineError.new(:no_classification_adapter)` and `ValidationError.new(:invalid_classification_request, [])` must not raise, while an off-enum control does. Those tests go in the existing `test/allm/error/engine_error_test.exs` and `validation_error_test.exs` in **24.1**. The `EngineError` atom therefore lands with a test before its first caller in 24.3 (agent-spec/DESIGN.md rule 31).

**Serializer registration (part of the contract):** `@known_modules` (`lib/allm/serializer.ex:65-107`) gains `ALLM.Error.ClassificationAdapterError`, `ALLM.ClassificationQuestion`, `ALLM.ClassificationRequest`, `ALLM.ClassificationAnswer` and `ALLM.ClassificationResponse`, all five in 24.1 alongside their modules.

### Layer A: `ALLM.Validate.classification_request/1`

```elixir
@spec classification_request(ClassificationRequest.t()) :: :ok | {:error, ValidationError.t()}
```

The head clause hard-rejects a non-map `:questions`. The body accumulates per-field errors through the shared `finalize/3`, in the same shape as `moderation_request/1` (`lib/allm/validate.ex:397-410`). The `{:model, :invalid_shape}` row reuses the existing `validate_model_field/2` (`lib/allm/validate.ex:897-899`).

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

> CORRECTED 2026-09-27 (24.1 fix): the `[:questions, id, :instructions]` `:invalid_shape` row now reads like the `:state` row — it also fires for a struct and for a non-empty keyword list. The literal "not a binary, map or list" accepted any struct with a `Jason.Encoder` (every Layer A struct), which then reached the provider as a `{"__type__": ...}` object. Both fields share one shape predicate in `ALLM.Validate`. See RECORDS 24.1.

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

1. `classify/2` returns exactly `{:ok, %ClassificationResponse{}}` or `{:error, %ClassificationAdapterError{}}`. **Enforced:** `ALLM.classify/3` raises `ArgumentError` naming the adapter on any other shape, with the same wording and raise as `dispatch_moderate_attempt/3` (`lib/allm.ex:2420-2440`).
2. On `{:ok, _}`, `Map.keys(response.answers)` equals `Map.keys(request.questions)` as sets.
3. Each answer's `:type` equals its question's `:type`, and its fields follow the field-population table.
4. A `:choice` answer's `choice` is a key of that question's `criteria`, and its `probabilities` keys equal the criteria keys.
5. A `:score` answer's `probabilities` and `legend` each have length `length(criteria)`.
6. Empty questions (`questions == %{}`) are rejected with `:invalid_request` **before any I/O and before `ALLM.Keys.fetch!/2`**, so a keyless environment sees the rejection rather than `%EngineError{reason: :missing_key}`. This is Phase 20.2's ordering constraint (`lib/allm/moderation_adapter.ex:42-45`).
7. `request.metadata` round-trips onto `response.metadata` unchanged, and `opts[:request_id]` is reflected onto `response.request_id` unchanged.
8. `opts[:request_timeout]` is honoured. Exceeding it yields `:timeout`.
9. `prepare_request/2` (optional) returns an unfired `Req.Request` configured exactly as `classify/2` would fire it.

### Layer B: `ALLM.Engine` extension

**This table is the single source of truth for the site count.** Sites were located at `9510ed9` by `grep -nE 'moderation_adapter|FakeModeration|transcription_model' lib/allm/engine.ex`; the helper/section name is the load-bearing locator (agent-spec/DESIGN.md rule 20), line numbers are for first reading.

| # | Site | File:line | What |
|---|------|-----------|------|
| 1 | moduledoc cursor-key Fake list | `lib/allm/engine.ex:36-40` | add `ALLM.Providers.FakeClassification` |
| 2 | moduledoc module-field bullet | `:41-43` | add `:classification_adapter` |
| 3 | moduledoc slot-model bullet | `:62-66` | add `:classification_model` beside `:speech_model`, `:transcription_model` |
| 4 | `@type t` | `:111-115` | `classification_adapter: module() \| nil`, `classification_model: String.t() \| nil` |
| 5 | `defstruct` | `:131-135` | both fields in the nil-default group |
| 6 | `@engine_field_keys` | `:161-165` | both fields (`resolve_params/2` deny-list) |
| 7 | `@module_fields` | `:185-187` | `:classification_adapter` only (`new/1` module validation; `:classification_model` is a string) |
| 8 | `new/1` `@doc` module list | `:199-200` | add `:classification_adapter` |
| 9 | `new/1` `@doc` cursor Fake list | `:212-213` | add `FakeClassification` |
| 10 | `put_cursor_key/2` comment | `:264-265` | add `FakeClassification` |
| 11 | `resolve_params/2` `@doc` prose | `:491-493` | both fields (the hand-written deny-list prose a grep for the attribute misses) |
| 12 | `__from_tagged__/1` | `:535-539` | `classification_adapter: restore_module(data["classification_adapter"])`, `classification_model: data["classification_model"]` |

That is twelve sites. The field names follow the noun rule Phase 22 set (`:moderation_adapter` matches `ModerationAdapter` and `:no_moderation_adapter`) and the Phase 25 slot-model rule (`:speech_model`). The façade pattern-matches `%Engine{classification_adapter: adapter}` directly; there is no accessor. `test/allm/engine_test.exs`'s slot-model loop (`for field <- [:speech_model, :transcription_model]`, near `:424`) gains `:classification_model`.

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

**Model resolution (Decision #5, copying `do_synthesize_body/4`):** `effective_model = request.model || engine.classification_model`. Neither `Engine.resolve_model/2` nor `engine.model` is read. `:model` is in the allow-list, so on the state path `opts[:model]` reaches `request.model`; a prebuilt request is authoritative and `opts[:model]` is not merged onto it (spec §37.4). The audio shape being copied (`lib/allm.ex`, `do_synthesize_body/4`):

```elixir
with :ok <- ALLM.Validate.speech_request(request) do
  request = %{request | model: request.model || engine.speech_model}
```

When `effective_model` is still nil, the adapter injects `"jev-latest"` (Decision #15). `:start` telemetry metadata carries `model: request.model || engine.classification_model`.

**Gate order inside the span (normative, the audio order):**
1. Adapter presence: a **pattern match** on `%Engine{classification_adapter: nil}` in the first `do_classify_body/4` clause, giving `EngineError.new(:no_classification_adapter)`.
2. `ALLM.Validate.classification_request/1` (validates the caller's `request.model`, including an `opts[:model]` lifted onto it on the state path; `engine.classification_model` is a string by construction).
3. Slot-model stamping.
4. `ALLM.Retry.run/3`-wrapped dispatch, with the wrap in `do_classify_body/4` following the audio convention (`do_synthesize_body/4`, `lib/allm.ex:2526-2540`). The policy is `augment_retry_policy(engine.retry, @retryable_classification_reasons)` with `@retryable_classification_reasons [:rate_limited, :provider_unavailable, :timeout, :network_error]`. That is the same four as `@retryable_moderation_reasons` (`lib/allm.ex:2304`), and it reuses the existing shared helper unchanged.

`do_classify_body/4` is `(engine, request, opts, request_id)`, the same arity as `do_synthesize_body/4`; `request_id` is computed once in `do_classify/3` and threaded through.

**Dispatch opts:** reuse the shared `build_capability_dispatch_opts(engine, drop_classification_request_opts(opts), request_id)` (`lib/allm.ex:2597-2606`), which already drops `:stream` and calls `Engine.put_cursor_key/2`, and pipe the `Retry.run/3` result through the shared `fill_request_id/2` (`:2657-2660`). No classification-specific dispatch-opts builder is written. **Bypassing the shared builder makes every façade-driven Fake script share one cursor across content-equal engines, silently.** The per-attempt closure `dispatch_classify_attempt/3` maps a retryable reason to `{:retry, err.retry_after_ms || 0, err}` and raises `ArgumentError` on invariant-1 violations, with the same wording shape as `dispatch_synthesize_attempt/3` (`lib/allm.ex:2613-2631`).

**`:stream` is silently dropped**, matching `moderate/3` and `embed/3`. Key resolution is not done at the façade: `:api_key` is forwarded, and the adapter calls `ALLM.Keys.fetch!(:typesafe, opts)` after its own gates.

**A missing key is raised, not returned.** `Keys.fetch!/2` raises `%EngineError{reason: :missing_key}` and no sibling rescues it (see `ALLM.Providers.OpenAI.Moderation`'s `prepare_request/2`). `@doc classify/3` states this in a "Raises" section. The Error Contract lists it as raised.

**Telemetry: `[:allm, :classify, :start | :stop | :exception]`.**

| Key | Kind | `:start` | `:stop` ok | `:stop` error |
|-----|------|----------|------------|---------------|
| `request_id`, `engine`, `model` (`request.model \|\| engine.classification_model`, may be nil) | metadata | ✓ | ✓ | ✓ |
| `question_count` | metadata | ✓ | ✓ | ✓ |
| `usage` | metadata | — | `response.usage` | `nil` |
| `response` / `error` | metadata | — | response / `nil` | `nil` / error |
| `answer_count` | measurement | — | `map_size(answers)` | `0` |

`question_count/1` is a two-clause private: `map_size` for a map, `0` otherwise. It has to tolerate a non-map because `:start` metadata is built **before** validation, the same hazard `moderation_input_count/1` is written around (`lib/allm.ex:2353-2356`).

### Wire-field map: TypeSafe

**Endpoint:** `POST https://api.typesafe.ai/v1/systemone` (not overridable, matching Voyage's fixed `@base_url`, `lib/allm/providers/voyage/embeddings.ex:222`). **Auth:** `Authorization: Bearer <key>`, `Content-Type: application/json`. **Key atom:** `:typesafe`.

Every row is **confirmed** (quoted from TypeSafe docs fetched 2026-09-22) or **inferred** (it gets a 24.4 probe arm).

| Concern | Wire | Status |
|---------|------|--------|
| Request envelope | `{"state": …, "model": "jev-latest", "questions": {"<id>": Question}}` (all three required) | **confirmed** (API reference) |
| `state` | string, object or array (*"array of text values"*, Models page) | **confirmed**; a list element that is not a binary is rejected by the adapter's pre-flight (see `gate_state/1`) |
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
| Error body envelope | *"a JSON body describing what went wrong"*; exact shape undocumented | **inferred**: arms 3, 7, 8 record it. `extract_error_message/1` tries `detail` (string, or a list of `%{"msg"}`), then `error.message`, then `message`, then a fixed fallback, and narrows to what is observed. Before writing it, compare the recorded envelope with the two existing private FastAPI `detail` extractors (`ALLM.Providers.Voyage.Embeddings`, `ALLM.Providers.Support.ElevenLabs`) and with `Support.HTTPResponse.body_error_message/2`; reuse whichever matches rather than writing a third |
| Context-length signal | undocumented | **inferred**: arm 9 |
| Correlation header | `x-typesafe-request-id` | **inferred** (SDK doc only): arm 1 |
| `Retry-After` / `retry-after-ms` | the SDK honours both | **inferred**: parsed if present, never required. The shared `Support.HTTPResponse.retry_after_ms/1` reads `Retry-After` only; `retry-after-ms` is not honoured unless arm 1/8 observes it and RECORDS justifies a Support extension |
| Unknown-field handling | undocumented | **inferred**: arm 11 (negative control) |
| Question-count cap | undocumented | **inferred**: arm 10 (ladder) |
| Pricing | *"$0.042 / Mtok … Charged per input token. Output tokens are free."* | **confirmed** (Models page) |

> CORRECTED 2026-09-28 (24.4 probe, all arms recorded under `test/fixtures/typesafe/classification/recorded/`): the inferred rows resolve as follows.
> - **`state` list elements:** the API accepts a list with a non-text element (`["a", 1]` → 200, arm 12). `gate_state/1` is kept: it enforces the *documented* contract ("array of text values"), and the finding is stated in RECORDS.
> - **Score `legend` for object criteria:** the object is echoed back (arm 2), so `legend` entries are strings or objects.
> - **400/403/404:** an unknown model is **400** `{"detail": {"error_type": "api_usage_error", "message": "Unknown model: …"}}` (arm 7). 403/404 were not observed.
> - **Error body envelope:** always `{"detail": …}` in three shapes — a string (limit breaches, arms 4/5), an object with `error_type` and usually `message` (arms 3, 7, 8, 9), or a FastAPI list of `{"loc", "msg", "type", "input", …}` on 422 (arm 13). `extract_error_message/1` handles exactly these three and never reads `input` (it echoes caller data). Neither sibling extractor covers all three and both are private to released adapters, so a TypeSafe-private one was written.
> - **Context-length signal:** 400 with `detail.error_type == "max_tokens_exceeded"` (arm 9).
> - **Correlation header:** `x-typesafe-request-id` (`req_…`) is present on **every** arm, success and error. `ClassificationResponse.id` is populated from it; error metadata carries it as `typesafe_request_id`.
> - **`Retry-After` / `retry-after-ms`:** neither was observed on any arm (no 429 was provoked). Only `Retry-After` is parsed, via the shared helper.
> - **Unknown-field handling:** **ignored** — an invented question field → 200 (arm 11), as is an invented top-level field (exploratory call). Acceptance is therefore not evidence of schema membership on this endpoint.
> - **Question-count cap:** none observed; 1, 32, 128 and 512 trivial questions were all 200 (arm 10).

### Layer B: `ALLM.Providers.TypeSafe.Classification`

```elixir
@behaviour ALLM.ClassificationAdapter
@base_url "https://api.typesafe.ai/v1"
@endpoint "/systemone"
@default_model "jev-latest"
```

**`classify/2` order:**
1. **Script short-circuit.** Any non-nil `opts[:adapter_opts][:classification_script]`, **including `[]`**, delegates to `FakeClassification.classify/2`. This copies `OpenAI.Moderation`'s escape hatch (`lib/allm/providers/openai/moderation.ex:354`).
2. `prepare_request/2`, which runs:
   1. the empty-questions gate;
   2. the provider-limit gates (Decision #18) and `gate_state/1` (a list `state` whose elements are not all binaries → `:invalid_request`, `metadata: %{field: :state}`; the Models page's *"array of text values"* is a TypeSafe wire fact, so it lives here and not in the validator);
   3. the encodability check and body build (Decisions #15, #17);
   4. `ALLM.Keys.fetch!(:typesafe, opts)`;
   5. `Req.new/1` with `retry: false` (Decision #19), `:receive_timeout` via `Support.HTTPResponse.maybe_apply_request_timeout/2`, and the `:plug` stub via `Support.HTTPResponse.maybe_apply_req_test_stub/2`.
3. One `Req.request/1`. There is no inner retry (Decision #19).
4. Decode, or build the error.

**`prepare_request/2` is implemented, and `classify/2` is built on it.** Under a script it returns `{:error, %ClassificationAdapterError{reason: :unknown, metadata: %{cause: :scripted_adapter}}}`, mirroring moderation's `stub_error/1` (`lib/allm/providers/openai/moderation.ex:792-797`, reason `:unknown`). Invariant 8 is bound by asserting `prepared.options[:receive_timeout]`. A `Req.Test` plug never consults `:receive_timeout` (`test/allm/providers/voyage/embeddings_test.exs:412-420`), so a stub-driven "expiry" test cannot bind it.

`@doc false` + `@spec` test seams (following the moderation family's naming banner):

| Function | Contract |
|----------|----------|
| `to_json_body/2` | `(request, opts) → map()`. Injects `@default_model` when `request.model` is nil (Decision #15). `:yes_no` → `"noul"`. Omits `criteria` for a yes_no question whose criteria is nil. Returns a bare `map()` (the capability family's shape) |
| `gate_limits/2` | `(request, opts) → :ok \| {:error, ClassificationAdapterError.t()}`. `@max_choice_options 255`, `@max_score_levels 10` (Decision #18) |
| `gate_state/1` | `(request) → :ok \| {:error, ClassificationAdapterError.t()}`. List-element text check (step 2.2 above) |
| `decode_response/4` | `(body, headers, request, opts) → {:ok, ClassificationResponse.t()} \| {:error, ClassificationAdapterError.t()}`. Enforces invariants 2–5, and any violation is `:malformed_response`. Converts the score maps to lists by integer-parsing the keys `"0".."n-1"`, with any gap giving `:malformed_response`. Coerces floats. `provider: :typesafe`, `id` from the `x-typesafe-request-id` header via `Support.HTTPResponse.header_value/2`, `usage` per the response contract |
| `to_classification_adapter_error/5` | `(status, body, headers, key, opts)`. The family's argument order plus the **resolved key**, because `redact_key_material/2` needs it and `opts[:api_key]` is nil whenever the key came from the environment (agent-spec/DESIGN.md rule 23) |
| `classify_classification_reason/3` | `(status, message, retry_after_ms) → {reason, retry_after_ms \| nil}`, the same tuple shape as Voyage's private `classify_embedding_reason/3` (`lib/allm/providers/voyage/embeddings.ex:885-899`) |
| `redact_key_material/2` | `(message, key)`. Literal-key pass (only when `byte_size(key) >= 8`), then `Support.Redact.typesafe/1` if the probe confirmed a prefix. Decision #16 |

**Shared helpers reused, not re-implemented** (`lib/allm/providers/support/http_response.ex`): `header_value/2`, `retry_after_ms/1`, `decode_error_body/1` (or `decode_json_error_body/1` for a binary body), `sanitize_cause/1` (blanks `Jason.DecodeError`'s `:data`), `build_metadata/2`, `maybe_apply_req_test_stub/2`, `maybe_apply_request_timeout/2`. There is no `body_preview` field (CLAUDE.md: ship no less safe than the embeddings siblings). `:options` on the request is ignored and documented as such.

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
  - `id: nil`
  - `raw: nil`
- **`:capture_pid` seam:** when `adapter_opts[:capture_pid]` is set, the Fake sends `{ALLM.Providers.FakeClassification, :call, %{request: request, opts: opts}}` to that pid first, even for gate-rejected calls. This is the FakeModeration message shape (`maybe_capture/2`, `lib/allm/providers/fake_moderation.ex:351-356`), and it is what lets 24.3 assert the request the adapter actually received.
- **A non-empty script that has been exhausted** returns `{:error, %ClassificationAdapterError{reason: :unknown, metadata: %{cause: :classification_script_exhausted}}}`.
- **Cursor:** `adapter_opts[:script_cursor]` → `adapter_opts[:cursor_key]` → `:erlang.phash2(script)`, with the moduledoc text copied from `fake_moderation.ex`'s `## Cursor behaviour`.
- **Pre-flight:** the empty-questions gate (invariant 6) runs before the script is consumed.
- **The moduledoc states outright that the Fake's confidence convention is its own and is NOT TypeSafe's formula** (Decision #9).
- **A 1-level score question** (which the validator rejects as `:too_few_levels`, but a direct `classify/2` call can still send) gets the ordinary default: `score: 0.0`, `probabilities: [1.0]`, `legend` = criteria, `confidence: 1.0`. The Fake does not re-validate.
- **Cursor code** (`cursor_key_id/1` and friends) is a private copy of `fake_moderation.ex`'s, knowingly the **sixth** copy tracked by `.work/ASKS.md:179` (owner: a stand-alone `[REFACTOR]`); 24.6 updates that ticket's measured count.

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
├── examples_helpers_test.exs                  (MODIFY — 24.5, semantic change: the :125-135 chat_provider?/1 predicate becomes `name not in ~w(elevenlabs typesafe)`; + a typesafe-row data test modelled on the elevenlabs row test at :143-151)
├── classification_adapter_test.exs            (NEW — 24.2, behaviour surface + Fake conformance invocation)
├── engine_test.exs                            (MODIFY — 24.2, :classification_adapter + :classification_model accept/reject/round-trip/deny-list; slot-model loop near :424)
├── allm_classify_test.exs                     (NEW — 24.3)
└── providers/
    ├── fake_classification_test.exs           (NEW — 24.2)
    └── typesafe/
        ├── classification_test.exs            (NEW — 24.4, seam units + decoder fixtures)
        ├── classification_wire_test.exs       (NEW — 24.4, Req.Test + raw-bytes provenance)
        └── classification_conformance_test.exs (NEW — 24.4)

test/support/
├── fake_classification_fixtures.ex            (NEW — 24.2)
└── typesafe_fixtures.ex                       (NEW — 24.4, recorded/1 + synthesized/1; reuses OpenAITestFixtures.drop_comment/1 as voyage_fixtures.ex:71 and elevenlabs_fixtures.ex:130 do)

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
guides/fakes.md                                (MODIFY — 24.5, Fake / slot / script-key table near :248-254)
guides/errors_and_retries.md                   (MODIFY — 24.5, error table near :17-25, :59-60, :74, and the stop-event span table near :282)
examples/
├── 22_classify_ticket.exs                     (NEW — 24.5, `# Provider: typesafe`; 22 is the number examples/README.md:355-356 reserves for it)
├── _helpers.exs                               (MODIFY — 24.5, "typesafe" row, classification_adapter/classification_default_model on every row, classification_engine/1 as a capability_engine/2 spec map, capability-only-arm moduledoc wording — Decision #14)
├── run_all.exs                                (MODIFY — 24.5, comments only: "audio-only arm" → "capability-only arm" at :27-31; no logic change — Decision #14)
├── README.md                                  (MODIFY — 24.5, key table + typesafe arm + :119 wording + strike the :355-356 "skip 22" reservation sentence)
└── RUN_OUTPUT_TYPESAFE.md                     (NEW — 24.5, regenerated from the live run in the same commit)

mix.exs                                        (MODIFY — 24.1/24.2/24.4/24.5, see gate table)
CHANGELOG.md                                   (MODIFY — 24.5)
steering/allm_engine_session_streaming_spec_v0_2.md   (MODIFY — 24.5, §41 + §27/§29/§35.7 amendments)
```

`ALLM.Keys` is **not** modified (Assumption 6). `README.md` is **not** in the tree for any sub-phase. At 24.1 start, run `git stash push -- README.md` if README has local edits. README's guide list (`README.md:227-228`) and capability rows would gain classification entries; that is a `[DOC]` ticket filed in 24.5 with the predicate `grep -c classification README.md` (must be ≥ 1 when done), not a phase edit.

### Repo-wide audit-gate obligations

| Gate | Fails | Sub-phase | Row |
|------|-------|-----------|-----|
| `test/groups_for_modules_audit_test.exs` | closed, bidirectional | 24.1, 24.2, 24.4 | `mix.exs` `groups_for_modules`. 24.1: four structs → "Data types" (starts near `:170`), the error → Errors (starts near `:223`). 24.2: `ALLM.ClassificationAdapter` → Behaviours (`:116-128`, beside `ALLM.ModerationAdapter` at `:123`), `FakeClassification` → Providers (`:129-164`). 24.4: `ALLM.Providers.TypeSafe.Classification` → Providers. Register each module only in the sub-phase that creates it |
| `test/layer_a_docs_test.exs` | **open** | 24.1 | `@layer_a` (`:14-47`; append after `ALLM.TranscriptionEvent`): the four structs |
| `test/allm_facade_doctest_inventory_test.exs` | **open**, one-directional | 24.3 | `classification_request: 2` (after `transcription_request: 2`), `classify: 3` (after the `# Audio` group) |
| `test/package_files_extras_consistency_test.exs` | closed | 24.5 | `mix.exs` `@guides` (`:68-81`); `package.files` already ships `guides` |
| `test/guides_test.exs` + `test/guides_doctest_test.exs` | closed for `@guides` (parity meta-tests vs `mix.exs` and `guides/`); open for `doctest_file/1` registration | 24.5 | `@guides` (`:23-36`) and a `doctest_file("guides/classification.md")` line (after `:21`) |

### Path-existence sanity check

`ls -d lib/allm lib/allm/error lib/allm/providers conformance/lib/allm/test conformance/test/support/fixtures conformance/test/allm/test test/allm test/allm/error test/allm/providers test/support test/fixtures scripts guides examples` was run on 2026-09-22 and all exist. **New directories:** `lib/allm/providers/typesafe/`, `test/allm/providers/typesafe/`, `test/fixtures/typesafe/classification/{recorded,synthesized}/`. Fixtures are `.json`.

---

## Phases

Every sub-phase's Verification includes the uniform gate block below (agent-spec/DESIGN.md rule 31). It is written out once here and referenced as **[G]**. **Before 24.1's first edit**, capture the docs-audit baseline: `mix run scripts/audit_user_docs.exs | sed -E 's/:[0-9]+:/:/' | sort > .work/phase24_audit_baseline.txt`. Line numbers are stripped so that pre-existing hits whose lines shift don't show up as diffs. The script still exits 1 at `9510ed9` on pre-existing hits, and a `grep classif` filter would miss a banned token in `lib/allm.ex`, `engine.ex`, `validate.ex` or `telemetry.ex` on a line that doesn't mention classification. The comparison is `comm -13` (**new** hits only), not `diff`: 24.2 must edit engine.ex lines that already carry pre-existing hits (the Fake lists at Engine-table sites 1 and 9), and rewording or removing an old hit is not a regression.

```bash
SP=<scratchpad dir>
mix test > "$SP/full.log" 2>&1; echo "exit=$?"; tail -5 "$SP/full.log"
mix test --seed 0 > "$SP/seed0.log" 2>&1; echo "exit=$?"; tail -5 "$SP/seed0.log"
mix format --check-formatted && mix credo --strict && mix dialyzer
mix run scripts/audit_user_docs.exs | sed -E 's/:[0-9]+:/:/' | sort > "$SP/audit_after.txt"; comm -13 .work/phase24_audit_baseline.txt "$SP/audit_after.txt"  # must be empty
grep -rlE '^[^#`]*(Keys\.put\(|Logger\.configure\(|System\.put_env\()' test/  # every file listed must be async: false
# :telemetry.attach in any new async: true module: checked by reading (filters on self()/request_id or uses TelemetryCapture), not by grep
```

> CORRECTED 2026-09-27 (24.1): the `comm -13` line is not empty whenever a sub-phase adds `lib/` files, because the audit's `Files scanned:    N` summary line changes (24.1: `132` → `137`, from five new modules). Read the output as "no line other than `Files scanned:` and, for a file with a new hit, its `Per-file summary` row"; the gate is that no new **hit** line (`<path>:<rule>: …`) appears. See RECORDS 24.1.

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
- A JSON payload with no `"usage"` key (and one with `"usage": null`) decodes to `usage: %ALLM.Usage{}`, never nil.

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
- A choice with 300 options passes the validator, because the cap lives in the adapter (Decision #18). Likewise `state: [1, %{}]` passes the validator (list-element text checks live in the adapter's `gate_state/1`).

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
- A 1-level score question sent directly (bypassing the validator) gets `score: 0.0`, `probabilities: [1.0]`, `confidence: 1.0` (the Fake contract).
- `:capture_pid` receives the request, including for a gate-rejected call.

`engine_test.exs` (MODIFY):
- `new/1` accepts `classification_adapter: Mod` and `classification_model: "jev-1.13.0"`.
- `{Mod, []}` for `:classification_adapter` raises `ArgumentError`.
- A JSON round-trip preserves the module and the model string.
- `resolve_params/2` does not leak either key (both are in `@engine_field_keys`).
- The slot-model loop near `engine_test.exs:424` covers `:classification_model`.

Conformance self-test (`conformance/`, driven by `ScriptedClassificationStub`): the three meta-invariants.

#### 24.2.2 Implementation Checklist

- [ ] `classification_adapter.ex`: callbacks, numbered invariants, skeleton, "Cleanup invariant: none."
- [ ] `engine.ex`: **every** row of the Engine-extension table (12 sites), including the prose sites 1, 3, 8, 9, 10 and 11
- [ ] `fake_classification.ex` + `test/support/fake_classification_fixtures.ex`
- [ ] Conformance harness + stub + self-test; `@case_count 9`; the "does NOT bind" section
- [ ] `mix.exs` groups: behaviour → Behaviours, Fake → Providers

#### 24.2.3 Verification

The targeted tests, then **[G]**, then `cd conformance && mix test && mix credo --strict && mix format --check-formatted`.

**Success criterion:** FakeClassification passes 9/9. Both Mix projects are green on all gates.

#### 24.2.4 Binding on later sub-phases
- **Invariant 6 requires the empty-questions gate (and, per Decision #18, the limit gates) ahead of `ALLM.Keys.fetch!/2`.** This binds 24.4. Conformance case 6 cannot enforce the ordering (a sourced `.env` masks it), so 24.4's `async: false` gate-ordering test with a flunking plug is what binds it.
- **`classify/3` must dispatch through the shared `build_capability_dispatch_opts/3`** (which calls `Engine.put_cursor_key/2`). This binds 24.3; the 24.3 cursor-injection test pins it.
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
  - An engine with `model: "gpt-x"`, no `classification_model` and no request model reaches the adapter with `request.model == nil` (`engine.model` is never read).
  - An engine with `classification_model: "jev-1.13.0"` stamps it onto a request with no model.
  - On the state path, `opts[:model]` wins over `engine.classification_model`.
  - A prebuilt request with its own `model` wins over `engine.classification_model`; a prebuilt request plus a call-site `model:` reaches the adapter with the prebuilt request's model unchanged (prebuilt is authoritative).
  - State path with `model: {:bad}` gives `{:model, :invalid_shape}`, and the adapter is never called.
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

- [ ] `lib/allm.ex`: the block per the façade contract — public functions after the audio public API (ends near `:1966`), internals after the audio internals (ends near `:2693`); reuse `build_capability_dispatch_opts/3` and `fill_request_id/2`
- [ ] `telemetry.ex`: `:classify` in both lists + the moduledoc event row
- [ ] `lib/allm.ex` moduledoc capability table (rows `:59-67`; insert after the `moderate/3` row at `:61`): add "Answer typed questions about text (choice / score / yes-no)" → `classify/3` → `{:ok, %ALLM.ClassificationResponse{}}`
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
- `gate_state/1`: `state: ["a", "b"]` is `:ok`; `state: ["a", 1]` is `:invalid_request` with `metadata: %{field: :state}`, before key resolution.
- **Gate ordering** (an `async: false` module; `TYPESAFE_API_KEY` deleted in `setup` and restored `on_exit`; a `Req.Test` plug that flunks on any request): empty questions and over-limit questions each return `:invalid_request` without raising `:missing_key` and without reaching the plug.
- `prepare_request/2` sets `options[:receive_timeout]` from `request_timeout:` (binds invariant 8). Under a script it returns the `:scripted_adapter` stub error.
- `decode_response/4` on each `recorded/` fixture produces the field-population table. Score maps become ordered lists. `provider: :typesafe`. `model` is the versioned id. `usage` is populated.
- `decode_response/4` on `answer_id_missing.json` gives `:malformed_response`. An extra id gives `:malformed_response`. A type mismatch gives `:malformed_response`.
- `integer_probabilities.json` gives floats.
- `classify_classification_reason/3`, table-driven over every row of the error table: 401 and 403 → auth; 429 → rate_limited (with `retry_after_ms` from the `Retry-After` header); 400, 404 and 422 → invalid_request; 500, 502, 503, 504 and 529 → provider_unavailable; 418 → unknown; plus the context-length signal if arm 9 found one.
- `redact_key_material/2` removes the literal (realistic-length) key from `error_401.json`, and leaves a message unchanged when the key is shorter than 8 bytes. The companion test calls `Support.Redact.openai/1`, `.anthropic/1`, `.gemini/1`, `.voyage/1` and `.elevenlabs/1` directly and asserts each leaves the same fixture unchanged.

`classification_wire_test.exs` (`Req.Test` via `adapter_opts[:plug]`):
- The emitted request body matches the wire-field map.
- The `Authorization: Bearer` header is sent.
- A `Req.Test.transport_error(conn, :timeout)` gives `:timeout`, and `:econnrefused` gives `:network_error`. These bind the error mapping only; the plumbing is bound by the `prepare_request/2` test.
- Exactly one HTTP attempt on a 503 through `classify/2` directly (no inner retry, Decision #19).
- **Provenance:** one test per `recorded/` file reads the raw bytes with `File.read!/1 |> Jason.decode!/1` and asserts `refute Map.has_key?(raw, "_comment")`, with a failure message naming the recorder invocation. One test per `synthesized/` file asserts the marker is present. The subjects are **discovered** with `Path.wildcard/1` (the ElevenLabs `names_on_disk/1` shape), and a meta-test asserts the discovered `recorded/` set equals the 24.4.2 arm table's file list, so an unrecorded arm is a failure rather than silence.

`classification_conformance_test.exs`: the harness two-liner with an `@moduledoc` stating which invariants it does and does not bind for this adapter.

#### 24.4.2 The live wire probe (four required parts)

These are CLAUDE.md's four parts, with `scripts/record_voyage_embeddings_fixtures.exs` as the model:
- **Overwrite guard first:** check every target path, so a fully recorded tree costs zero calls.
- **Assert, don't narrate:** any want/got mismatch prints a table to stderr and `System.halt(1)`s before any fixture is written.
- **Record bodies, error envelopes included.**
- **A negative control.**

| Arm | Request | Expected | Records |
|-----|---------|----------|---------|
| 1 | one choice + one score + one noul, string state | 200. Whether `x-typesafe-request-id` is present is **recorded, not asserted** (an absent header is a legitimate finding under Decision #13, not a halt) | `recorded/mixed_questions.json` + a header note (present/absent, and whether `retry-after-ms`/`Retry-After` appear on any arm) in RECORDS |
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

> CORRECTED 2026-09-28 (24.4 probe): observed statuses differ from this table's first guesses, and the recorder asserts the observed ones. Arm 3 → **400**, recorded as `error_400_bad_type.json`; arm 4 → **400**, `error_400_too_many_options.json`; arm 5 → **400**, `error_400_too_many_levels.json`; arm 7 → **400**; arm 9 → **400** (`max_tokens_exceeded`); arm 11 (negative control) → **200**, a legitimate finding: TypeSafe ignores unknown fields. Two arms were added: **12** (list state with a non-text element → 200, `probe_state_list_any.json`) and **13** (`questions: {}` → 422, `error_422_empty_questions.json`, the only genuine FastAPI-list envelope). Every recorded file except the ladder is an envelope `{"status", "headers", "header_names", "body"}` (the ElevenLabs recorder's shape), so tests read the status and the request-id header from the recording. Actual cost: see RECORDS 24.4.

**Cost:** arms 1–8 and 11 are about 300 input tokens each, except 4/4b, which are about 3k each. Arm 9 is about 40k tokens. Arm 10 is about 15k tokens. That totals under 60k tokens, which is **< $0.003 per clean run** at $0.042/Mtok. First implementation is budgeted at 4× that, **< $0.02**. The implementer's report cites actuals (rule 19).

#### 24.4.3 Implementation Checklist

- [ ] The adapter per the contract, including the moduledoc wire-field table and the `noul` alias note
- [ ] The recorder + probe, loading the project-root `.env` through `EnvLoader` before reading the key, modelled on `scripts/record_voyage_embeddings_fixtures.exs` (all four probe parts) and `scripts/record_elevenlabs_audio_fixtures.exs` (the most recent capability-only provider). Without that, a bare `mix run` reports "key not set" in a provisioned checkout (CLAUDE.md); `test/support/typesafe_fixtures.ex`, reusing `OpenAITestFixtures.drop_comment/1`
- [ ] The synthesized fixtures, each with `_comment: "Synthesized — Phase 24.4 …"`
- [ ] If arm 1 observed no `x-typesafe-request-id` header, document in the moduledoc that `ClassificationResponse.id` is always nil from this adapter and record the finding in RECORDS (Decision #13)
- [ ] Narrow `extract_error_message/1` and the wire-map "inferred" rows to what the probe observed; record the transcript in RECORDS
- [ ] Prune `:context_length_exceeded` if arm 9 shows no signal (both lists, the doctest count, and the 24.1 test)
- [ ] `mix.exs` groups: the adapter → Providers

#### 24.4.4 Verification

The recorder invocation (a discrete step). Then `mix test test/allm/providers/typesafe/`, then **[G]**.

**Success criterion:** the probe exits 0 with every recorded fixture free of `_comment`. A second recorder run makes zero HTTP calls, because every arm, including 10 and 11, now writes a guarded file. The adapter passes 9/9 conformance. `grep -rn '"noul"' lib/ | grep -v providers/typesafe` is empty.

> CORRECTED 2026-09-28 (24.4): that grep is not empty and cannot be: Decision #2's docs target puts the alias note in `@moduledoc ALLM.ClassificationQuestion`, which reads `TypeSafe calls it "noul"` (`lib/allm/classification_question.ex:21`, from 24.1). The predicate measured a *mention*, not a wire use. The binding predicate is `grep -rnE '(=>|:) *"noul"|"noul" *=>|:noul\b' lib/ | grep -v providers/typesafe` → empty (exit 1), with the positive control `… | grep -c providers/typesafe` → 3.

### Phase 24.5: Spec §41, guide, examples, wiring

#### 24.5.1 Test Plan

- `guides/classification.md` is registered in all three lists, passes `guides_test.exs`'s structural gates (more than 2 KB, at least one `iex>`, zero audit hits), and every `iex>` block runs under FakeClassification.
- The guide sections are: engine slot; the three question types and when to use each (citing TypeSafe's guidance); confidence routing done in caller code; model pinning; one call with many questions; errors and retries; telemetry; testing with FakeClassification.
- `examples/22_classify_ticket.exs` asserts a typed answer per question type and prints confidence.
- **The live gate is BLOCKING:** `ALLM_PROVIDER=typesafe mix run examples/run_all.exs` exits 0 and runs **only** script 22. `ALLM_PROVIDER=openai mix run examples/run_all.exs` shows `[SKIP] 22_…` and its prior script set is unchanged (compare the pre/post `--- NN_` line list). The openai arm's own pre-existing failures, if any, are characterised per CLAUDE.md's blocked-arm rule (scripts run individually past the halt), not inherited.
- `test/allm/examples_helpers_test.exs`: the existing row-iterating `chat_provider?/1` test (`:125-135`) is a **semantic change** — its predicate becomes `name not in ~w(elevenlabs typesafe)`; a new data test on `provider_rows()["typesafe"]`, modelled on the elevenlabs row test (`:143-151`), asserts `key_env == "TYPESAFE_API_KEY"`, `adapter == nil`, `classification_adapter == ALLM.Providers.TypeSafe.Classification`, `classification_default_model == "jev-latest"`; and every row carries the `:classification_adapter` and `:classification_default_model` keys. No env-driven engine-builder test (the builder reads `ALLM_PROVIDER` and `System.halt/1`s on a missing key, and the test VM does not load `.env`).

#### 24.5.2 Implementation Checklist

- [ ] Spec §41 (sections mirroring §39: goals, data model, behaviour, engine integration, public API, one-call guidance, provider adapter, testing, telemetry, out of scope). §27 and §29 amendments. The §35.7 fourth carve-out per Decision #10, placed after the Phase 26 amendment block. §41's heading is `## 41. v0.6 — Typed classification`, placed after §40. Each amendment block opens with `> **Phase 24 amendment (commits <first>..<last>).**`
- [ ] Guide + `mix.exs` `@guides` + `guides_test.exs` + `guides_doctest_test.exs`
- [ ] `guides/fakes.md` (Fake / slot / script-key table) and `guides/errors_and_retries.md` (error table, retry prose, stop-event span table) gain their classification rows
- [ ] Examples per Decision #14: the typesafe row; `classification_adapter`/`classification_default_model` nil on the other four rows; `classification_engine/1` as a `capability_engine/2` spec map; the capability-only-arm comment/moduledoc/README wording; the README key table; strike the `examples/README.md:355-356` "skip 22" reservation
- [ ] `test/allm/examples_helpers_test.exs` per the 24.5.1 bullet
- [ ] File the README `[DOC]` ticket (Module Tree note) in `.work/ASKS.md` with its predicate
- [ ] `RUN_OUTPUT_TYPESAFE.md` regenerated from the live run in this commit, or not created at all
- [ ] CHANGELOG entries derived from `git diff v0.5.0..HEAD lib/` (the latest tag; `git tag` → `v0.5.0`), never from this design's prose. They go into the top `## [REL] v0.6.0` section while it is still untagged; if `v0.6.0` has been tagged by then, a new section derived from `git diff v0.6.0..HEAD lib/`

#### 24.5.3 Verification

**[G]**, then `mix run scripts/check_guide_fences.exs | head -1`, then both `run_all` invocations above.

### Phase 24.6: `[CHORE]` sweep

**Module Tree:** whatever deferrals 24.1–24.5 filed. Each one is filed with a self-scoring predicate and closed here, or explicitly re-filed with a reason. **Known at design time:**
- `.work/ASKS.md:179` `[DEFERRED-DRY]` (hydrate_usage/1 and Fake cursor copies): **re-filed, not closed** — its named owner is a stand-alone `[REFACTOR]`. 24.6 appends a measurement line with both predicates re-run (`grep -l 'defp hydrate_usage' lib/allm/*.ex | wc -l` and `grep -l 'defp cursor_key_id' lib/allm/providers/*.ex | wc -l`, each expected 6 after this phase).
- The README `[DOC]` ticket filed in 24.5: re-filed (README is outside every sub-phase's tree).

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
| `classify/3` | `:malformed_response` | Provider/decoder contract breach; report to TypeSafe with the provider request id if one was captured (the error's `metadata`, or `ClassificationResponse.id` on earlier successes). |
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
