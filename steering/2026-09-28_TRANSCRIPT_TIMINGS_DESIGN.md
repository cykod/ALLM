# Phase 28: Opt-in transcript spans — word/token timings and logprobs — Design Document

*Generated 2026-09-28 · Measured against: `d3bcb3b`*

> **Goal:** Let a caller opt in to typed, provider-neutral per-word / per-token timings and log-probabilities on a transcription, batch and streaming, without changing the default response shape.
> **Outcome:** `ALLM.transcribe(engine, audio, timestamps: true, logprobs: true)` returns `%TranscriptionResponse{spans: [%ALLM.TranscriptSpan{}, …]}` on ElevenLabs; `logprobs: true` returns token spans on OpenAI (and on Gemini iff the 28.3 probe confirms support); every flag a provider cannot honour is refused with `:unsupported_feature` before any I/O; with both flags off every existing test and fixture is unchanged.
> **Spec sections:** §37.2.3, §37.2.5, §37.2.6, §37.10, §37.11.1, §37.11.2 (all amended in 28.6)
> **Layers touched:** A (28.1), B (28.2–28.5 adapters + Fake), C (28.2 `AudioStream.collect_transcription/1`, façade allow-lists in 28.1). Two sub-phases cross a layer, each forced: 28.1's two façade allow-list lines (the fail-closed symmetry tests go red the moment the struct fields land), and 28.2's collector change (the Fake and the collector are pinned together by the stream-equivalence property, which cannot be green with only one side changed).

## Status

| Phase | Description | Layer | Status |
|-------|-------------|-------|--------|
| 28.1 | `ALLM.TranscriptSpan`, request flags, `TranscriptionResponse.spans` + `mean_logprob/1`, event `/3` constructor, validation, registrations | A | Completed |
| 28.2 | Shared span/gate helpers, `FakeTranscription` spans, `collect_transcription/1`, equivalence property | B/C | Completed |
| 28.3 | Live wire probes in three recorder scripts (decides the Gemini branch and the realtime time base) | — (scripts, fixtures) | Completed |
| 28.4 | ElevenLabs batch + realtime spans | B | Completed |
| 28.5 | OpenAI + Gemini spans / refusals | B | Completed |
| 28.6 | Spec amendments, `guides/audio.md`, CHANGELOG | docs | Completed |
| 28.7 | `[CHORE]` sweep: `FakeTranscription` malformed `{:retry_until_call, n}` | B | Completed |

**Overall Progress:** 7/7 phases complete

---

## Overview

A downstream silence probe needs per-word confidence and timing from a transcription. ElevenLabs already returns both on every batch response (`words[]` with `start`/`end`/`logprob`, `test/fixtures/elevenlabs/transcriptions/recorded/scribe_v2.json:8-30`) and, when opted in, on every realtime committed segment (`test/fixtures/elevenlabs/realtime/recorded/rt_fox.json:226`). ALLM leaves the batch data on `:raw` (`lib/allm/providers/elevenlabs/transcription.ex:501`) and **discards** the realtime data (`on_message("committed_transcript_with_timestamps", …)` reads only `language_code`, `:990-994`). OpenAI's `gpt-4o*-transcribe` family returns token logprobs when asked (`include[]=logprobs`, UNVERIFIED on this repo's wire — no fixture; 28.3 settles it), and Gemini's `generationConfig.responseLogprobs` may (UNVERIFIED — 28.3 settles it). Spec §37.10 lists "timestamps" as out of scope because they are model-specific; this phase brings the **word/token-level** slice in scope behind two opt-in flags, and leaves segments, diarization and subtitle formats out.

`whisper-1` and `verbose_json` are **not** supported: `response_format` stays reserved (`lib/allm/providers/openai/transcription.ex:25`).

- **Deliverables**
  - NEW Layer A struct `ALLM.TranscriptSpan` (text, kind, start/end seconds, logprob).
  - `TranscriptionRequest` and `TranscriptionStreamRequest` gain `timestamps: false` and `logprobs: false`.
  - `TranscriptionResponse` gains `spans: nil` and `mean_logprob/1`.
  - `TranscriptionEvent.committed_transcript/3` adds a `:spans` payload key (the `/2` form is unchanged and emits no `:spans` key); `:transcription_completed` gains an **optional** `:spans` key holding the adapter's concatenation, the same way `completed.text` is the adapter's join.
  - `AudioStream.collect_transcription/1` copies `completed.spans` onto the response.
  - `FakeTranscription` honours both flags; ElevenLabs (batch + realtime), OpenAI and Gemini adapters honour or refuse them.
- **Spec coverage:** refines §37.2.3 / §37.2.6 / §37.11.1 / §37.11.2 and narrows §37.10 (amendment text lands in 28.6 with a commit-range stamp per DESIGN.md rule 21).
- **Layer demonstration**
  - Layer A — construct and inspect without any adapter:
    ```elixir
    span = ALLM.TranscriptSpan.new(text: "fox", kind: :word, start_seconds: 1.2, end_seconds: 1.5, logprob: -0.02)
    resp = ALLM.TranscriptionResponse.new(text: "fox", spans: [span])
    ALLM.TranscriptionResponse.mean_logprob(resp)   #=> -0.02
    ```
  - Layer C batch:
    ```elixir
    {:ok, resp} = ALLM.transcribe(engine, audio, timestamps: true, logprobs: true)
    for %{kind: :word} = s <- resp.spans, do: {s.text, s.start_seconds, s.logprob}
    ```
  - Layer C streaming (a user's own reducer, no collector):
    ```elixir
    {:ok, events} = ALLM.stream_transcribe(engine, pcm_chunks, timestamps: true)
    for {:committed_transcript, %{spans: spans}} <- events, s <- spans || [], do: s
    ```
  - Layer D: none — transcription has no `ALLM.Session` integration (§37.10).
- **Prerequisites:** Phase 26 streaming audio (`lib/allm/transcription_event.ex`, `lib/allm/audio_stream.ex`); nothing unmerged.
- **Out of scope**
  - `whisper-1` / `verbose_json` segments (`avg_logprob`, `no_speech_prob`) — user decision 2026-09-28; the older model.
  - Character-level timings (`characters[]` on realtime words, `timestamps_granularity: "character"` on batch) — no consumer; a later additive field on `TranscriptSpan`.
  - Speaker / channel labels (`speaker_id`, `channel_index`) — diarization stays out per §37.10.
  - Segment-level structs — ElevenLabs has none; OpenAI's only come from `verbose_json`.
  - Top-k alternative tokens (OpenAI `logprobs[].top_logprobs` if present, Gemini `topCandidates`) — no consumer.
  - A silence / no-speech detector — the consumer builds it from spans; ALLM ships data, not heuristics.
  - `ALLM.Session` integration — §37.10.
- **Non-obvious decisions**
  1. **Two flags, not one.** Providers split along the two axes (ElevenLabs: both; OpenAI/Gemini: logprobs only), so one flag would either over-promise timings on OpenAI or force a refusal there that the caller did not need. `Docs target: @moduledoc ALLM.TranscriptionRequest`.
  2. **One list, not two.** Timings and logprobs attach to the same unit on every provider that has both, so they share `%TranscriptSpan{}`; an unrequested attribute is `nil` on every span even when the provider sent it (ElevenLabs always sends both), so output is a function of the request, not the provider. `Docs target: @moduledoc ALLM.TranscriptSpan`.
  3. **`spans: nil` means "not requested"; `[]` means "requested, nothing spoken".** A requested flag never yields `nil` on a successful response, batch **or** collected stream (sole exception: a scripted `%TranscriptionResponse{}` returned verbatim by `FakeTranscription`, 28.2) — a silent stream collects to `[]`, which is the case the motivating silence probe reads. This is why decision 6 exists. `Docs target: @moduledoc ALLM.TranscriptionResponse`.
  4. **Refusal is `:unsupported_feature`, before key resolution**, reusing the Phase 26 precedent (ElevenLabs `:prompt`, `gate_prompt` in `lib/allm/providers/elevenlabs/transcription.ex:605-612`; reason documented at `lib/allm/error/transcription_adapter_error.ex:25`). After I/O, a 200 body lacking the source key is `{:ok, resp}` with `spans: []` **when `resp.text` is blank** (a silent clip must not cost the caller a paid transcript), and `:unsupported_feature` with `metadata.cause: :absent_from_response` and `metadata.text: resp.text` otherwise (the caller keeps the transcript it paid for) — the one post-I/O use of the reason, which the §37.2.5 amendment records. The silent-clip probe arms (28.3 E3/O4/G2) confirm or refine the blank-text rule before 28.4. `Docs target: @doc ALLM.transcribe/3`.
  5. **The streaming key is omitted, not `nil`, when unrequested.** `committed_transcript/2` keeps emitting `%{text, language}` exactly, so no third-party reducer changes; `/3` always writes the key. Existing tests match committed payloads as map *patterns*, which ignore extra keys, so they cannot falsify this — 28.2 and 28.4 add explicit `refute Map.has_key?(payload, :spans)` tests. `Docs target: @moduledoc ALLM.TranscriptionEvent`.
  6. **`:transcription_completed` gains an optional `:spans` key, outside `@completed_keys`.** When a flag is set the adapter writes the concatenation of its committed spans (`[]` when nothing was committed), exactly as it already writes `completed.text` as the join of committed texts (§37.11.1). The collector copies it; it does not fold committed events, so "silent" (`[]`) and "not requested" (key absent → `nil`) stay distinguishable. Keeping it out of `@completed_keys` (`lib/allm/transcription_event.ex:86`) means no third-party `transcription_completed/1` call breaks. `Docs target: @doc ALLM.AudioStream.collect_transcription/1`.
  7. **A scripted real adapter refuses what its provider would.** The script hand-off runs before an adapter's own gates, so without help `OpenAI.Transcription` scripted with `timestamps: true` would return timed spans that the live provider refuses. Following the `with_own_cap/2` precedent (`lib/allm/providers/support/transcription_adapter.ex:74`), each adapter passes its supported-flag list into the Fake's opts on hand-off and the Fake applies the same refusal. `Docs target: @moduledoc ALLM.Providers.FakeTranscription`.
  8. **No model allow-list on OpenAI.** Which OpenAI models return logprobs is decided by the provider; a local allow-list goes stale. The adapter sends the include and treats an absent `logprobs` key as decision 4's post-I/O `:unsupported_feature`. `Docs target: @moduledoc ALLM.Providers.OpenAI.Transcription`.

## Assumptions

1. ElevenLabs batch `scribe_v2` returns `words[]` by default with `timestamps_granularity` defaulting to `"word"` — CONFIRMED for the default request (`scribe_v2.json`, no granularity option sent, recorder `stt/4` at `scripts/record_elevenlabs_audio_fixtures.exs:1306-1323`); the adapter will still send `timestamps_granularity=word` explicitly when a flag is set so a caller's `options` cannot switch it off (28.3 arm E1 confirms acceptance).
2. ElevenLabs realtime word times are relative to the **session** audio start, not the segment — UNVERIFIED (`rt_fox.json` has one segment). 28.3 arm E2 decides; see 28.4's branch rule.
3. Every realtime committed segment gets a timestamped twin when `include_timestamps=true` — UNVERIFIED; the existing hold machinery already tolerates a *late* twin (`on_committed/4` hold → release on next commit / wake / finish, `:1016-1021`, `release_held/1` `:1037-1040`). It does **not** tolerate a *skipped* twin: pairing is by count (`index = state.stamps_seen`, `:991`), so one skipped twin shifts every later twin onto the wrong segment. Today that mislabels a language; with spans it would attach one segment's words to another's text. Empty commits are the likeliest skip (`test/allm/providers/elevenlabs/transcription_stream_test.exs:437` is a stub test with a `committed_transcript` frame of `text: ""`; E2 supplies the live evidence). Mitigation (contract below): with a flag set, a twin whose trimmed `text` differs from its paired segment's trimmed text yields `spans: nil` for that segment — a sanity check on the pairing, not the pairing key, so the existing "paired by commit order, never by text" rule (`:349`) stands. 28.3 arm E2 asserts twin count == commit count over a session that includes an empty commit.
4. OpenAI `include[]=logprobs` on `gpt-transcribe` (the adapter default, `lib/allm/providers/openai/transcription.ex:10`) and `gpt-4o-mini-transcribe` returns top-level `"logprobs": [{"token", "logprob", "bytes"}]` — UNVERIFIED (published-docs recollection; no fixture). The existing option test sends the key as bare `include` (`test/allm/providers/openai/transcription_test.exs:97-101`), and OpenAI ignores unknown fields with a 200 (moduledoc `:67`), so **which key spelling works is itself unverified** and 28.3 arm O1/O2 settle it from the response body.
5. Gemini `generationConfig.responseLogprobs: true` on `gemini-flash-latest` returns `candidates[0].logprobsResult.chosenCandidates[] = {token, logProbability}` — UNVERIFIED. Gemini rejects an unknown **top-level** field with 400 (the existing control, `scripts/record_gemini_audio_fixtures.exs:133`, header `:19-23`); whether it also rejects an unknown field **inside `generationConfig`** is UNVERIFIED, so 28.3 adds control arm G0 before G1's 200 counts as schema evidence.
6. Gemini's logprob tokens exclude thought parts — UNVERIFIED; 28.3 arm G1 records the body and 28.5 asserts on it.

## Alternatives Considered

| Alternative | Why not |
|---|---|
| Surface `verbose_json` for `whisper-1` (`avg_logprob`, `no_speech_prob`) | User ruled out `whisper-1` (2026-09-28). |
| Keep everything on `:raw`, document per-provider paths | The ElevenLabs realtime path has no `:raw`; the data is dropped (`:990-994`). And three provider shapes is what ALLM exists to hide. |
| One `detail: :none \| :logprobs \| :timestamps \| :full` enum | Same information as two booleans with a worse `||`-safe decode story and an extra closed enum to maintain. |
| `timestamps: :word \| :character \| nil` | Character granularity has no consumer (Out of scope); a boolean can widen later by a new field. |
| Add `:spans` to `:transcription_completed` as a **required** key | Breaks third-party `transcription_completed/1` callers via `require_keys!/3` (`lib/allm/transcription_event.ex:86`, `:176-185`). Adopted instead as an optional key (decision 6). |
| Collector folds committed-event spans instead of reading `completed.spans` | A silent stream has no committed event, so the fold cannot tell "requested, silent" from "not requested" — exactly the silence-probe case. |
| Always emit `spans: nil` on `committed_transcript` | Changes the exact payload the constructor doctest asserts (`lib/allm/transcription_event.ex`, `committed_transcript/2` doctest). Omission is invisible to every reducer. |

---

## Behaviour & Type Contracts

This section is the **one normative home** for every shape below; phases reference it.

### `ALLM.TranscriptSpan` (NEW, Layer A)

```elixir
defmodule ALLM.TranscriptSpan do
  @type kind :: :word | :spacing | :audio_event | :token | :other

  @type t :: %__MODULE__{
          text: String.t(),
          kind: kind(),
          start_seconds: number() | nil,
          end_seconds: number() | nil,
          logprob: number() | nil
        }

  @enforce_keys [:text, :kind]
  defstruct [:text, :kind, :start_seconds, :end_seconds, :logprob]

  @spec new(keyword()) :: t()          # struct!/2 pass-through; @enforce_keys → ArgumentError on missing :text/:kind
  @spec kinds() :: [kind()]            # [:word, :spacing, :audio_event, :token, :other]
  @doc false
  @spec __from_tagged__(map()) :: t()  # kind via a literal string→atom map built from kinds/0; unknown → :other
end
defimpl Jason.Encoder, for: ALLM.TranscriptSpan  # ALLM.Serializer.encode_tagged/2, as every sibling
```

- `new/1` is a bare `struct!/2` pass-through (CLAUDE.md Layer-A constructor rule); `@enforce_keys` makes a missing `:text`/`:kind` raise `ArgumentError` from `struct!/2` — verify the exact exception in IEx on OTP 27 before writing the test (DESIGN.md test-observable class 1). No runtime guard on field types.
- `kind` values: `:word` / `:spacing` / `:audio_event` map ElevenLabs `type` strings of the same name; `:token` is every OpenAI / Gemini unit; `:other` is any ElevenLabs `type` string not in that list (use site: `ElevenLabs.Transcription` span decoder, 28.4). No `String.to_atom/1` on provider input — map through a literal table. `__from_tagged__/1` uses the same kind of table (`Map.new(kinds(), &{Atom.to_string(&1), &1})`, unknown → `:other`) rather than `Serializer.to_atom_field/1` (`lib/allm/serializer.ex:215-217`, `String.to_existing_atom/1`), so a hand-edited persisted span never raises `ArgumentError` on decode. Pinned by a decode test with `"kind" => "bogus"` → `:other`.
- `start_seconds <= end_seconds` when both are non-nil is **not** enforced (provider data); documented, not guarded.
- `logprob` is `<= 0` in every recorded fixture but not guarded. **Never** pattern-match a literal `0.0` (CLAUDE.md; `scribe_v2.json` contains `"logprob": 0.0` at `:74`).
- Registration is part of the contract: `ALLM.Serializer` `@known_modules` (`lib/allm/serializer.ex:65-111`), `test/layer_a_docs_test.exs` `@layer_a` (`:14-46`), `mix.exs` `docs.groups_for_modules` beside `ALLM.TranscriptionResponse` (`mix.exs:203`).

### Request flags (MODIFY, Layer A)

```elixir
# ALLM.TranscriptionRequest   (lib/allm/transcription_request.ex:46)
defstruct [:audio, :model, :language, :prompt,
           timestamps: false, logprobs: false, options: %{}, metadata: %{}]

# ALLM.TranscriptionStreamRequest   (lib/allm/transcription_stream_request.ex:58-65)
defstruct [:model, :language, sample_rate: 16_000, commit_strategy: :vad,
           timestamps: false, logprobs: false, options: %{}, metadata: %{}]
```

- `@type t` gains `timestamps: boolean(), logprobs: boolean()` on both.
- `__from_tagged__/1`: `data["timestamps"] || false` is safe (default is `false`, CLAUDE.md `||` rule); the serialization test pins a **`true`** value round-tripping on both structs.
- `ALLM.Validate.transcription_request/1` (`lib/allm/validate.ex:510-520`) and `transcription_stream_request/1` (`:551-563`) gain `{:timestamps, :invalid_shape}` / `{:logprobs, :invalid_shape}` when the value is not a boolean. Accumulating, not hard-reject. Both reuse `:invalid_transcription_request`.
- Façade allow-lists `@transcription_request_field_opts` (`lib/allm.ex:1561`) and `@transcription_stream_request_field_opts` (`:1878`) gain `:timestamps, :logprobs`. Forced in 28.1 by the fail-closed symmetry tests `test/allm/allm_transcribe_test.exs:147-163` and `test/allm/allm_stream_transcribe_test.exs:320-…`, which iterate `Map.keys/1` of the struct. The stream test also asserts `Map.has_key?(@field_values, field)` for every struct key (`:324-325`), so its `@field_values` literal gains `timestamps: true, logprobs: true` in 28.1 too.
- Adapters test a flag with `== true`, never truthiness: a direct adapter call skips `Validate`, and `timestamps: "no"` must not switch timings on.

### `ALLM.TranscriptionResponse` (MODIFY, Layer A)

```elixir
defstruct [:language, :duration_seconds, :id, :request_id, :model, :provider, :raw, :spans,
           text: "", usage: %Usage{}, metadata: %{}]

@type t :: %__MODULE__{..., spans: [ALLM.TranscriptSpan.t()] | nil}

@spec mean_logprob(t()) :: float() | nil
```

- `__from_tagged__/1` hydrates `data["spans"]`: `nil` → `nil`, a list → `Enum.map(&ALLM.Serializer.hydrate/1)`. Pinned by a round-trip test with a two-span list and one with `nil`.
- `mean_logprob/1`: arithmetic mean of `logprob` over spans whose `kind in [:word, :token]` and whose `logprob` is a number; `nil` when `spans` is `nil` or no span qualifies. `:spacing` and `:audio_event` are excluded on both paths because they are not spoken units; on batch ElevenLabs also duplicates the next word's logprob onto the spacing entry (`scribe_v2.json:18-25`), which would double-weight it (realtime does not — `rt_fox.json:226` spacing `-0.7177` vs next word `-0.6433`). Falsifier: a response with spans `[word -0.2, spacing -0.2, word -0.4]` returns `-0.3`, not `-0.2667`.

**Population invariant (every adapter, batch):** on `{:ok, resp}`,
- `resp.spans == nil` iff neither flag is `true` (except a scripted `%TranscriptionResponse{}` the Fake returns verbatim);
- for every span, `start_seconds`/`end_seconds` are non-nil **only if** `request.timestamps`, and `logprob` is non-nil **only if** `request.logprobs` (the adapter **drops** an unrequested attribute the provider sent). "Only if", not "iff": a provider may omit an attribute on some unit, and that span then carries `nil`. The stronger "every span has it" holds only where a recorded fixture shows it, and the 28.4/28.5 wire tests assert it per fixture.
Falsifier: ElevenLabs batch with `logprobs: true, timestamps: false` over the recorded `scribe_v2.json` body yields spans whose `start_seconds` are all `nil`.

**Decode only when asked.** An adapter reads its span source key only when a flag is `true`. With both flags off, a malformed or absent `words` / `logprobs` / `logprobsResult` is ignored exactly as today.

### `ALLM.TranscriptionEvent` (MODIFY, Layer A)

```elixir
@type committed :: %{required(:text) => String.t(),
                     required(:language) => String.t() | nil,
                     optional(:spans) => [ALLM.TranscriptSpan.t()] | nil}

@typedoc "Payload of `:transcription_completed`."
@type completed :: %{required(:text) => String.t(), ...existing required keys...,
                     optional(:spans) => [ALLM.TranscriptSpan.t()]}

@type t :: ... | {:committed_transcript, committed()} | ...

@spec committed_transcript(String.t(), String.t() | nil, [ALLM.TranscriptSpan.t()] | nil) :: t()
def committed_transcript(text, language, spans)   # always writes the :spans key
# committed_transcript/1,2 unchanged: %{text:, language:} with NO :spans key
# transcription_completed/1 unchanged: @completed_keys (:86) does NOT gain :spans
```

- The default-argument head stays `committed_transcript(text, language \\ nil)`; `/3` is a separate clause with no default, guarded `is_list(spans) or is_nil(spans)`.
- `event?/1` (`:168-174`) is unchanged; it matches on `%{text: text}` only.
- **Streaming population invariant** (normative for every stream adapter; restated as a numbered invariant in the `ALLM.TranscriptionStreamAdapter` moduledoc contract list, `lib/allm/transcription_stream_adapter.ex:85-102`):
  1. Either flag `true` → every `:committed_transcript` is built with `/3`. Its `:spans` is a list, or `nil` when the adapter has no trustworthy timing data for that segment (ElevenLabs: twin never arrived before release, twin text mismatch, or twin `words` malformed — Assumption 3).
  2. Either flag `true` → `:transcription_completed` carries `:spans` = the concatenation, in commit order, of every committed segment's non-`nil` `:spans`; `[]` when there were none.
  3. Both flags off → `/2` everywhere, and neither event carries `:spans`.
  4. Per-span attribute dropping as batch.
- Additive payload keys → non-breaking per the CLAUDE.md event-protocol rule; no existing `Fake` script-entry tag changes its emission with flags off.
- Dialyzer: the optional-key map types are compatible with every existing `%{text: _, language: _}` construction; confirmed by `mix dialyzer` in 28.1, not assumed.

### `ALLM.AudioStream.collect_transcription/1` (MODIFY, Layer C)

- The response build in `transcription_step({:transcription_completed, completed}, acc)` (`lib/allm/audio_stream.ex:198-215`) adds `spans: Map.get(completed, :spans)`. No accumulator change; committed events are not folded for spans.
- So `resp.spans` is `nil` iff the completed payload had no `:spans` key, and `[]` for a flagged stream that committed nothing (decision 3).
- Error path unchanged (`metadata.committed_text` only).
- Stream-equivalence: `transcribe(req_with_flags) ≡ stream_transcribe(...) |> collect_transcription/1` on `spans` for the Fake (28.2), **including empty text** (batch `[]` ↔ stream completed `spans: []`). Relaxation budget: none added.

### Adapter wire-field map

Normative for 28.4/28.5. `C` = confirmed by a cited recorded fixture; `I` = inferred, owned by the 28.3 arm named.

| Provider / path | `timestamps: true` | `logprobs: true` | Response source | Span mapping | Status |
|---|---|---|---|---|---|
| ElevenLabs batch `/v1/speech-to-text` | send form field `timestamps_granularity=word` | same field (logprobs are always on each word) | `body["words"][]` = `{text, type, start, end, logprob}` | `text`→`text`, `type`→`kind` via table, `start`/`end`→`*_seconds`, `logprob` | response shape **C** (`scribe_v2.json:8-30`); explicit `timestamps_granularity=word` acceptance **I** (arm E1) |
| ElevenLabs realtime WS | query `include_timestamps=true` | same query | `committed_transcript_with_timestamps.words[]` = `{text, type, start, end, logprob, characters, speaker_id, channel_index}` | as batch; `characters`/`speaker_id`/`channel_index` dropped | frame shape **C** (`rt_fox.json:226`); time base **I** (arm E2) |
| OpenAI `/v1/audio/transcriptions` | refuse `:unsupported_feature`, `metadata.field: :timestamps` | form field `include[]=logprobs` (spelling **I**, arm O1/O2) | `body["logprobs"][]` = `{token, logprob, bytes}` | `token`→`text`, `kind: :token`, times `nil`, `logprob` | **I** (arms O1–O4) |
| Gemini `generateContent` | refuse `:unsupported_feature`, `metadata.field: :timestamps` | `generationConfig.responseLogprobs = true` **or** refuse (28.3 G1 decides) | `candidates[0].logprobsResult.chosenCandidates[]` = `{token, logProbability}` | `token`→`text`, `kind: :token`, `logProbability`→`logprob` | **I** (arms G0–G2) |
| `FakeTranscription` | honoured | honoured | see 28.2 | see 28.2 | n/a |

**Structural-field rule:** when a flag is set, the wire field in column 2/3 is **structural** for that call — merged over `request.options`, so a caller's option can never switch it off. With both flags off, `options` passthrough is byte-identical to today (pinned by the existing option tests staying green unmodified).

### Error contract

| Function | Reason | When | Before key? | Metadata |
|---|---|---|---|---|
| `OpenAI.Transcription.transcribe/2` | `:unsupported_feature` | `timestamps: true` | yes | `%{field: :timestamps}` |
| `Gemini.Transcription.transcribe/2` | `:unsupported_feature` | `timestamps: true`; also `logprobs: true` iff 28.3 G1 shows unsupported | yes | `%{field: :timestamps \| :logprobs}` |
| any bundled adapter (batch) | `:unsupported_feature` | flag passed pre-flight, 200 body lacks the source key (column "Response source"), and `text` is **not** blank | no (post-I/O) | `%{field: …, cause: :absent_from_response, text: <transcript>}` |
| any bundled adapter (batch) | — (success, `spans: []`) | as above but `String.trim(text) == ""` | — | — |
| any bundled adapter (batch) | `:malformed_response` | source key present but not a list, or an element lacks a binary `text` | no | existing `malformed_error/2` |
| `ElevenLabs.Transcription.stream_transcribe/3` | — | flags never refused (both supported); malformed/absent twin `words` → that segment's `spans: nil` (streaming invariant 1), never a stream error | — | — |
| `FakeTranscription` (scripted real adapter) | `:unsupported_feature` | a set flag not in the hand-off's supported list (decision 7) | yes | `%{field: …}` as the real adapter; `provider: nil` (Fake-originated) |
| `Validate.transcription_request/1`, `…_stream_request/1` | `:invalid_transcription_request` | non-boolean flag | yes | `errors: [{:timestamps \| :logprobs, :invalid_shape}]` |

- Shared helper (NEW, 28.2): `TranscriptionAdapter.gate_flags(request :: TranscriptionRequest.t() | TranscriptionStreamRequest.t(), supported :: [:timestamps | :logprobs], provider :: atom() | nil, opts :: keyword()) :: :ok | {:error, TranscriptionAdapterError.t()}`. First unsupported set flag in the order `:timestamps`, `:logprobs` → `TranscriptionAdapterError.new(:unsupported_feature, provider: provider, metadata: HTTPResponse.build_metadata(%{field: flag}, opts), message: …)`, the sibling shape of `gate_prompt` (`lib/allm/providers/elevenlabs/transcription.ex:605-612`).
- Gate ordering: called as the **last** step inside each adapter's `gate_audio/2` (OpenAI `lib/allm/providers/openai/transcription.ex:276-284`; Gemini `lib/allm/providers/gemini/transcription.ex:310`), i.e. after the resolvable, size and MIME gates and before `Keys.fetch!` (CLAUDE.md gates-before-key rule). The Fake script hand-off (`fetch_transcription_script/1`, `lib/allm/providers/support/transcription_adapter.ex:64`) still runs first, but carries the supported list (`with_span_flags/2`, NEW beside `with_own_cap/2` at `:74`) so the Fake's own gate refuses identically (decision 7). ElevenLabs passes `[:timestamps, :logprobs]` and never refuses.
- No new reason atom. The §37.2.5 amendment widens `:unsupported_feature`'s doc from "refused locally" to include the post-I/O absent case (`lib/allm/error/transcription_adapter_error.ex:25` doc text edited in 28.4, the first sub-phase to return it post-I/O).

---

## Module Tree

```
lib/allm/
├── transcript_span.ex                     (NEW — 28.1)
├── transcription_request.ex               (MODIFY — 28.1, flags + decode)
├── transcription_stream_request.ex        (MODIFY — 28.1, flags + decode)
├── transcription_response.ex              (MODIFY — 28.1, :spans + mean_logprob/1 + hydrate)
├── transcription_event.ex                 (MODIFY — 28.1, committed_transcript/3, optional completed :spans, types)
├── transcription_adapter.ex               (MODIFY — 28.2, moduledoc: batch population invariant for third-party adapters)
├── transcription_stream_adapter.ex        (MODIFY — 28.2, moduledoc contract list :85-102 gains the streaming population invariant)
├── validate.ex                            (MODIFY — 28.1, boolean flag rules on both validators)
├── serializer.ex                          (MODIFY — 28.1, @known_modules += ALLM.TranscriptSpan)
├── allm.ex                                (MODIFY — 28.1 two field-opt allow-lists; 28.6 @doc transcribe/3 + stream_transcribe/3 paragraph)
├── audio_stream.ex                        (MODIFY — 28.2, collect_transcription/1 copies completed.spans)
├── error/transcription_adapter_error.ex   (MODIFY — 28.4, :unsupported_feature doc widened to the post-I/O case — 28.4 ships its first post-I/O use)
└── providers/
    ├── fake_transcription.ex              (MODIFY — 28.2 spans + flag gate; 28.7 retry_until_call validation)
    ├── support/transcription_adapter.ex   (MODIFY — 28.2 span_from/6, gate_flags/4, with_span_flags/2)
    ├── elevenlabs/transcription.ex        (MODIFY — 28.4, batch field + decode, realtime query + hold + stamps widening + completed spans)
    ├── openai/transcription.ex            (MODIFY — 28.5, hand-off flags + gate + include + decode)
    └── gemini/transcription.ex            (MODIFY — 28.5, hand-off flags + gate + responseLogprobs-or-refuse + decode)

mix.exs                                    (MODIFY — 28.1, groups_for_modules += ALLM.TranscriptSpan)

test/allm/
├── transcript_span_test.exs               (NEW — 28.1)
├── transcription_request_test.exs         (MODIFY — 28.1)
├── transcription_stream_request_test.exs  (MODIFY — 28.1)
├── transcription_response_test.exs        (MODIFY — 28.1)
├── transcription_event_test.exs           (MODIFY — 28.1)
├── validate_transcription_request_test.exs        (MODIFY — 28.1)
├── validate_transcription_stream_request_test.exs (MODIFY — 28.1)
├── allm_transcribe_test.exs               (MODIFY — 28.2, façade flag pass-through via Fake)
├── allm_stream_transcribe_test.exs        (MODIFY — 28.1 @field_values += flags (:324-325); 28.2 façade flag pass-through via Fake)
├── audio_stream_test.exs                  (MODIFY — 28.2)
├── audio_stream_equivalence_property_test.exs (MODIFY — 28.2, flags + spans in equivalence, empty text included)
└── providers/
    ├── fake_transcription_test.exs        (MODIFY — 28.2; 28.7)
    ├── support/transcription_adapter_test.exs   (MODIFY — 28.2, span_from/6, gate_flags/4, with_span_flags/2)
    ├── elevenlabs/transcription_test.exs        (MODIFY — 28.4)
    ├── elevenlabs/transcription_wire_test.exs   (MODIFY — 28.3 provenance; 28.4)
    ├── elevenlabs/transcription_stream_test.exs (MODIFY — 28.3 provenance; 28.4)
    ├── openai/transcription_test.exs            (MODIFY — 28.5)
    ├── openai/transcription_wire_test.exs       (MODIFY — 28.3 provenance; 28.5)
    ├── gemini/transcription_test.exs            (MODIFY — 28.5)
    └── gemini/transcription_wire_test.exs       (MODIFY — 28.3 provenance; 28.5)
test/layer_a_docs_test.exs                 (MODIFY — 28.1, @layer_a += ALLM.TranscriptSpan)

test/fixtures/
├── elevenlabs/transcriptions/recorded/words_explicit.json   (NEW — 28.3, arm E1)
├── elevenlabs/transcriptions/recorded/silence.json          (NEW — 28.3, arm E3)
├── elevenlabs/realtime/recorded/rt_two_segments.json        (NEW — 28.3, arm E2)
├── openai/transcriptions/recorded/logprobs_include_brackets.json   (NEW — 28.3, arm O1)
├── openai/transcriptions/recorded/probe_logprobs_include_bare.json (NEW — 28.3, arm O2)
├── openai/transcriptions/recorded/logprobs_mini.json        (NEW — 28.3, arm O3)
├── openai/transcriptions/recorded/logprobs_silence.json     (NEW — 28.3, arm O4)
├── gemini/transcriptions/recorded/probe_generation_config_control.json (NEW — 28.3, arm G0)
├── gemini/transcriptions/recorded/probe_logprobs.json       (NEW — 28.3, arm G1)
└── gemini/transcriptions/recorded/probe_logprobs_silence.json (NEW — 28.3, arm G2; support branch only)

scripts/
├── record_elevenlabs_audio_fixtures.exs   (MODIFY — 28.3, arms E1–E3)
├── record_openai_audio_fixtures.exs       (MODIFY — 28.3, arms O1–O4)
└── record_gemini_audio_fixtures.exs       (MODIFY — 28.3, arms G0–G2)

examples/
├── 24_transcribe_audio.exs                (MODIFY — 28.4/28.5, a flagged call per the wire-field map: spans non-empty, or the documented refusal)
└── 26_stream_transcribe.exs               (MODIFY — 28.4, ElevenLabs flagged stream: completed spans non-empty)

steering/allm_engine_session_streaming_spec_v0_2.md (MODIFY — 28.6)
guides/audio.md                            (MODIFY — 28.6, new "Word timings and confidence" section + "Realtime transcription on ElevenLabs" (:733-739) hold paragraph gains the flags)
CHANGELOG.md                               (MODIFY — 28.6)
```

Parent directories verified to exist (`ls` at `d3bcb3b`): `lib/allm/`, `test/allm/`, `test/allm/providers/{support,elevenlabs,openai,gemini}/`, `test/fixtures/{elevenlabs/transcriptions,elevenlabs/realtime,openai/transcriptions,gemini/transcriptions}/recorded/`, `scripts/`, `examples/`. `test/allm/providers/support/transcription_adapter_test.exs` exists. Both `examples/24_transcribe_audio.exs` and `examples/26_stream_transcribe.exs` exist at `d3bcb3b`.

**Conformance suites are deliberately untouched** (`@case_count` stays 6). Their `[scripted]` cases hand off to `FakeTranscription` by contract (`conformance/lib/allm/test/transcription_adapter_conformance.ex:25-33`), so a flags case would only re-test the Fake, which `fake_transcription_test.exs` covers. The behaviour-level obligation on third-party adapters is carried by the two behaviour moduledocs instead.

**Audit-gate rows** (DESIGN.md table, re-derived for this phase):

| Gate | Fires in | Row |
|---|---|---|
| `test/groups_for_modules_audit_test.exs` (closed) | 28.1 (new public module) | `mix.exs` MODIFY — 28.1 |
| `test/layer_a_docs_test.exs` (open) | 28.1 | `test/layer_a_docs_test.exs` MODIFY — 28.1 |
| `test/allm_facade_doctest_inventory_test.exs` (open) | — | no new `ALLM` function |
| `test/package_files_extras_consistency_test.exs`, `test/guides_test.exs`, `test/guides_doctest_test.exs`, `test/readme_getting_started_test.exs` | — | no new guide; `guides/audio.md` is already registered |

README is **not** in any tree: `git stash push -- README.md` at each sub-phase start if it is dirty.

---

## Phases

### 28.1 Layer A: span struct, flags, response field, event constructors (Layer A)

**Test Plan (write first)**

`test/allm/transcript_span_test.exs` (NEW):
- `new/1` builds a span; missing `:text` or `:kind` raises (exception module verified in IEx first).
- `kinds/0` returns the five atoms in contract order.
- Round-trips `:erlang.term_to_binary/1` and the JSON round-trip helper `test/allm/transcription_response_test.exs` already uses, for one span of every kind, including `logprob: 0.0` and `start_seconds: nil`.
- `__from_tagged__/1` with `"kind" => "bogus"` → `:other`, no raise.

`test/allm/transcription_request_test.exs`, `transcription_stream_request_test.exs` (MODIFY):
- defaults are `false`; a persisted `timestamps: true, logprobs: true` survives a JSON round-trip (non-default pin).

`test/allm/transcription_response_test.exs` (MODIFY):
- `spans` defaults `nil`; round-trips with `nil` and with a two-span list (hydrated to `%TranscriptSpan{}`).
- `mean_logprob/1`: `nil` spans → `nil`; `[]` → `nil`; only `:spacing` → `nil`; the contract falsifier `[word -0.2, spacing -0.2, word -0.4]` → `-0.3`; `:token` spans counted; a span with `logprob: nil` skipped.

`test/allm/transcription_event_test.exs` (MODIFY):
- `committed_transcript("hi", "en")` → `refute Map.has_key?(payload, :spans)` (decision 5's falsifier; a map pattern would not bind it).
- `committed_transcript("hi", nil, [])` and `committed_transcript("hi", nil, nil)` both carry the `:spans` key.
- `/3` with a non-list, non-nil spans raises `FunctionClauseError`.
- `transcription_completed/1` accepts a payload with and without `:spans`, and still raises on a missing required key.
- `event?/1` true on a `/3` event.

`test/allm/validate_transcription_request_test.exs`, `validate_transcription_stream_request_test.exs` (MODIFY):
- `timestamps: "yes"` → `{:timestamps, :invalid_shape}`; `logprobs: nil` → `{:logprobs, :invalid_shape}`; both accumulate with an existing error — pair with `language: 1` (valid audio), **not** bad audio: `transcription_request/1`'s bad-audio clause short-circuits to `[{:audio, :invalid_shape}]` alone (`lib/allm/validate.ex:505-507`).

The fail-closed symmetry tests (`allm_transcribe_test.exs:147`, `allm_stream_transcribe_test.exs:320`) go red when the struct fields land and green once the allow-lists and the stream test's `@field_values` grow — they are the falsifier for those rows.

**Implementation Checklist**
- [ ] `lib/allm/transcript_span.ex` per contract, with `@moduledoc` examples (no banned `§`/`Phase N` tokens — `test/layer_a_docs_test.exs` audits them).
- [ ] Both request structs: fields, `@type`, `@moduledoc` field bullets, `__from_tagged__/1`.
- [ ] `TranscriptionResponse`: field, type, hydrate, `mean_logprob/1` with doctest; replace the moduledoc sentence "Timestamps … stay on `:raw`" (`:11-13`) with the opt-in description.
- [ ] `TranscriptionEvent`: `committed/0` and `completed/0` types, `/3` clause + doctest, moduledoc bullets.
- [ ] `Validate`: two rules on each validator + doc lines.
- [ ] Registrations: `Serializer` `@known_modules`, `@layer_a`, `mix.exs` groups, both façade allow-lists, stream test `@field_values`.

**Verification**
```bash
mix test test/allm/transcript_span_test.exs test/allm/transcription_*_test.exs test/allm/validate_transcription_*_test.exs test/allm/allm_transcribe_test.exs test/allm/allm_stream_transcribe_test.exs test/layer_a_docs_test.exs test/groups_for_modules_audit_test.exs
mix test > "$SP/28_1.log" 2>&1; echo "exit=$?"
mix test --seed 0
mix credo --strict && mix dialyzer && mix format --check-formatted
```

### 28.2 Shared helpers, Fake, collector, equivalence (Layer B/C)

`FakeTranscription` is the test vehicle every later sub-phase and every application test uses, so it lands before any real adapter, and the three shared helpers land here with it as their first caller (DESIGN.md: a same-design second caller puts the shared module in the first sub-phase's tree).

**Shared helpers** (`lib/allm/providers/support/transcription_adapter.ex`, `@doc false` + `@spec`):
- `span_from(text, kind, start, end_, logprob, request :: TranscriptionRequest.t() | TranscriptionStreamRequest.t()) :: TranscriptSpan.t()` — applies the attribute-dropping rule once (times kept only if `request.timestamps == true`, logprob only if `request.logprobs == true`).
- `gate_flags/4` — per the Error contract.
- `with_span_flags(opts, supported) :: keyword()` — puts `supported` into the opts the Fake receives on hand-off, beside `with_own_cap/2` (`:74`).

**Fake contract** (`lib/allm/providers/fake_transcription.ex`):
- Gate: `with_span_flags/2` stores the list at `adapter_opts[:span_flags]`. If present, the Fake calls `gate_flags(request, supported, nil, opts)` inside its `gate/2` (batch) and `gate_sample_rate/2` (stream) — **before** `resolve_script/1`, so a refusal never advances the cursor. `provider: nil` matches today's Fake-originated errors; decision-7 tests therefore assert `reason` and `metadata.field` only, not `:provider`. With no list (the Fake used directly), both flags are supported.
- Batch `{:ok, text}` (`build_response/3`, `:704-714`) and the no-script default: when either flag is `true`, `spans` = one `:word` span per `String.split(text)` word, in order, built with `span_from/6`: word *i* gets `start_seconds: i * 0.5, end_seconds: (i + 1) * 0.5` and `logprob: -0.1`, then dropped per the request. Both flags off → `spans: nil`. Blank text with a flag → `spans: []`.
- Batch `{:ok, %TranscriptionResponse{}}` is returned verbatim (`interpret_entry`, `:658-673`) — the scripted `spans` wins, flags are not applied (documented: a scripted struct is the escape hatch).
- Stream `{:ok, text}` (`on_input_done`, `:478-490` → `segment_events/2`, `:394-406`): with a flag set, the one committed event (if any — blank text emits none, `:394-398`) is `/3` carrying the batch builder's spans for that text, and the completed event carries `spans:` = those spans, or `[]` when nothing was committed. Flags off → unchanged.
- Stream `{:ok, %TranscriptionResponse{}}` (`stream_entry_events`, `:354-376`): if `response.spans` is non-nil, the committed event is `/3` with those spans and completed carries them; else unchanged.
- `{:events, events}` verbatim, unchanged.

**Collector:** per the `collect_transcription/1` contract.

**Behaviour docs:** `ALLM.TranscriptionAdapter` moduledoc gains the batch population invariant; `ALLM.TranscriptionStreamAdapter`'s numbered contract (`:85-102`) gains streaming invariants 1–3. Both reference `ALLM.TranscriptSpan`.

**Test Plan (write first)**
- `support/transcription_adapter_test.exs`: `span_from/6` over the four flag cells; `gate_flags/4` refusal order (`:timestamps` before `:logprobs`), error `provider`/`metadata.field`, and `:ok` for a flag set to a non-`true` value (`== true` rule); `with_span_flags/2` round-trip.
- `fake_transcription_test.exs`: the four batch flag cells × `{:ok, text}` / struct; the same on the stream path; exact span lists for `"the quick fox"` per cell; blank text → batch `spans: []`, stream completed `spans: []` and no committed event; flags off → `refute Map.has_key?` on every committed and completed payload; hand-off opts with `[:logprobs]` + `timestamps: true` → `:unsupported_feature` `field: :timestamps`, and `cursor_index/1` is unchanged after the refusal.
- `audio_stream_test.exs`: completed without `:spans` → `resp.spans == nil`; completed with `spans: []` → `[]`; completed with two spans → those spans; committed events' spans are **not** folded (a committed `/3` plus a completed without `:spans` → `nil`).
- `audio_stream_equivalence_property_test.exs`: widen the generator with the two booleans and allow empty text; assert `spans` equal between `transcribe/3` and `stream_transcribe/3 |> collect_transcription/1`. Falsifier: mutate the stream path's completed spans to drop the last word → property red.
- `allm_transcribe_test.exs` / `allm_stream_transcribe_test.exs`: `ALLM.transcribe(engine, audio, timestamps: true)` and `ALLM.stream_transcribe(engine, pcm, timestamps: true)` over the Fake return timed spans (the allow-lists reach the adapter end to end).

**Implementation Checklist**
- [ ] Three shared helpers + tests.
- [ ] Fake gate, span builder, four call sites, `@moduledoc` table rows.
- [ ] Collector build + doc paragraph.
- [ ] Two behaviour moduledocs.
- [ ] Equivalence property widened.

**Verification**
```bash
mix test test/allm/providers/support/transcription_adapter_test.exs test/allm/providers/fake_transcription_test.exs test/allm/audio_stream_test.exs test/allm/audio_stream_equivalence_property_test.exs test/allm/allm_transcribe_test.exs test/allm/allm_stream_transcribe_test.exs
mix test > "$SP/28_2.log" 2>&1; echo "exit=$?"
mix test --seed 0
mix credo --strict && mix dialyzer && mix format --check-formatted
(cd conformance && mix test && mix credo --strict && mix format --check-formatted)
```

### 28.3 Live wire probes (scripts + fixtures)

Every row marked **I** in the wire-field map gets an arm here, **before** any adapter code, because three rows decide the shape of 28.4/28.5. All three recorders already implement the four-part probe (CLAUDE.md): assert-then-write with `halt_unless_all_ok` (ElevenLabs `:898-927`, OpenAI `:551-574`, Gemini `:274-294`) and the `_comment` overwrite guard (`pending?`, ElevenLabs `:1244-1255`, OpenAI `:817-828`, Gemini `:402-416`). Invocation always sources `.env`: `set -a; . ./.env; set +a; mix run scripts/record_<provider>_audio_fixtures.exs`.

The silent clip for E3/O4/G2 is built in-script (2 s of 16-bit mono zeros at 16 kHz behind a 44-byte WAV header), not committed as a binary fixture.

| Arm | Request | Expect (status) | Verify (body) — halts on mismatch unless marked *record* | Writes |
|---|---|---|---|---|
| E1 | ElevenLabs batch `scribe_v2`, fox mp3, `timestamps_granularity=word` | 200 | `words` non-empty; each has numeric `start`, `end`, `logprob`, binary `type` | `words_explicit.json` |
| E2 | ElevenLabs realtime `scribe_v2_realtime`, `include_timestamps=true`, `commit_strategy=manual`: fox clip, `commit`, ≥1 s silence, `commit`, fox clip, `commit` (every commit follows ≥0.3 s of uncommitted audio, else `commit_throttled` closes the session — `rt_end.json`) | 101 | twin frames == `committed_transcript` frames **received** (halts otherwise, verdict names Assumption 3); for each pair `String.trim(twin.text) == String.trim(committed.text)` (halts otherwise — this is 28.4's sanity check probed live); *record* `summary.time_base`: over the first and last segments with non-empty `words`, `:session` if the last's first `start` ≥ the first's last `end`, else `:segment` | `rt_two_segments.json` |
| E3 | ElevenLabs batch, silent WAV | 200 | *record* whether `words` is absent, `[]`, or non-empty, and `text` | `silence.json` |
| O1 | OpenAI `gpt-transcribe`, field `include[]=logprobs` | 200 | *record* whether top-level `logprobs` is a non-empty list of `{token, logprob}` | `logprobs_include_brackets.json` |
| O2 | OpenAI `gpt-transcribe`, field `include=logprobs` (bare) | 200 | *record* as O1 | `probe_logprobs_include_bare.json` |
| O3 | OpenAI `gpt-4o-mini-transcribe`, the spelling O1/O2 proved | 200 | `logprobs` non-empty list | `logprobs_mini.json` |
| O4 | OpenAI `gpt-transcribe`, silent WAV, the proved spelling | 200 | *record* `logprobs` absent / `[]` / non-empty, and `text` | `logprobs_silence.json` |
| G0 | Gemini, `generationConfig.notARealField=true` | 200 **or** 400 | *record* status and body — 400 naming the field makes G1's 200 schema evidence; 200 means Gemini ignores unknown `generationConfig` fields (decision 2 → refuse) | `probe_generation_config_control.json` |
| G1 | Gemini `gemini-flash-latest`, `generationConfig.responseLogprobs=true` | 200 **or** 400 | 200 → `candidates[0].logprobsResult.chosenCandidates` non-empty list of `{token, logProbability}`; *record* whether any `thought` part exists and whether token texts concatenate to the transcript. 400 → *record* the error body | `probe_logprobs.json` |
| G2 | Gemini, silent WAV, `responseLogprobs=true` (only if G1 was 200) | 200 | *record* as O4 | `probe_logprobs_silence.json` |

**Two passes.** The recorders run all pending arms before asserting, so dependent arms cannot read an earlier arm's result in one run. Pass 1 records O1, O2, G0, G1 (plus the independent E-arms). The implementer then hard-codes the proved OpenAI spelling and the Gemini branch in the scripts, each with a comment citing the fixture that proves it; pass 2 adds O3, O4 and (support branch only) G2. A partial re-run reads nothing dynamically.

O1–O2 together must show **at least one** spelling returning `logprobs`; if neither does, the run halts (OpenAI logprobs would then be unsupported and 28.5 would refuse it — ask before proceeding). Controls: G0 is Gemini's in-`generationConfig` negative control. OpenAI and ElevenLabs batch **ignore** unknown fields with 200 (OpenAI recorder header `:29-31`; ElevenLabs moduledoc `:99`), so only response observables settle their rows — which is why O1/O2/E1 verify bodies. E2's control is the existing `rt_fox` family: without `include_timestamps` no timestamped frames arrive (`rt_manual_commit` / `rt_end` summaries).

**Decisions this sub-phase hands forward** (recorded in `_RECORDS.md` §28.3 with the fixture path that proves each):
1. OpenAI include spelling = whichever of O1/O2 carries `logprobs` (if both, `include[]`, OpenAI's documented array form).
2. Gemini branch = **support** iff G0 returned 400 **and** G1 returned 200 with `logprobsResult`; else **refuse**.
3. Realtime time base = E2's `summary.time_base`. `:session` → 28.4 passes times through. `:segment` → **stop and ask the user** before 28.4: an offset needs the byte count at each commit, which `:vad` cannot know exactly.
4. Blank-text rule (decision 4) per provider: if E3/O4/G2 show a non-empty span source on silence, the rule is moot for that provider; if they show the key absent, the rule is exercised by a recorded fixture in 28.4/28.5.

**Cost:** ≈ 10 live calls on ≤ 3.7 s clips: OpenAI 4 × ~$0.001, Gemini 3 × <$0.001, ElevenLabs 2 batch + ~10 s realtime. Per-clean-run ≈ $0.01–0.02; first-implementation ≈ $0.05 (DESIGN.md rule 19). A re-run over a fully recorded tree makes zero live calls.

**Test Plan:** per-file negative provenance test for each NEW recorded fixture — raw `File.read!/1 |> Jason.decode!/1`, `refute Map.has_key?(raw, "_comment")`, failure message naming the recorder invocation — in the provider's `*_wire_test.exs` (realtime: `transcription_stream_test.exs`) (CLAUDE.md recorded-fixture rule). `probe_logprobs_silence.json` and its test exist only on the Gemini support branch.

**Verification**
```bash
set -a; . ./.env; set +a
mix run scripts/record_elevenlabs_audio_fixtures.exs; echo "exit=$?"
mix run scripts/record_openai_audio_fixtures.exs; echo "exit=$?"
mix run scripts/record_gemini_audio_fixtures.exs; echo "exit=$?"
for p in elevenlabs openai gemini; do mix run scripts/record_${p}_audio_fixtures.exs | grep -q '^0 live calls' && echo "$p ok"; done   # re-run: zero live calls each
mix test test/allm/providers/*/transcription_wire_test.exs test/allm/providers/elevenlabs/transcription_stream_test.exs
mix test --seed 0 && mix format --check-formatted && mix credo --strict
```

### 28.4 ElevenLabs batch + realtime (Layer B)

**Batch** (`lib/allm/providers/elevenlabs/transcription.ex`):
- Hand-off: the script branch passes `with_span_flags(opts, [:timestamps, :logprobs])`.
- `to_multipart_body/2` (`:463-481`): with either flag `true`, add `{"timestamps_granularity", "word"}` to the structural list and drop `"timestamps_granularity"` from `options` for this call (the module attribute `@structural_fields`, `:52`, is unchanged; the call-time drop list grows). Flags off → identical form.
- `decode_response/4` (`:489-505`): with either flag, `spans` from `body["words"]` via `span_from/6`, with the `type` → `kind` literal table (`"word"`, `"spacing"`, `"audio_event"`; anything else `:other`). Absent `words` → decision 4 (blank text → `[]`, else `:unsupported_feature` `:absent_from_response`); non-list or an element without binary `text` → `:malformed_response`.

**Realtime:**
- `stream_url/2` (`:572-584`): with either flag, `include_timestamps=true` joins the structural map (overrides `options`).
- Hold: `hold_language?/1` (`:1047-1050`) becomes "hold for the twin" — true when either flag is `true` **or** a `@hold_options` key is set. Flags off → exactly today's predicate. With a flag set every segment may wait up to `@language_hold_ms` (1,000 ms, `:40`) for its twin; the guide and the adapter moduledoc say so.
- `committed_transcript_with_timestamps` (`:990-994`): with a flag set, also decode `payload["words"]` via `span_from/6`; malformed or absent → `nil` spans for that segment (streaming invariant 1), never a stream error. `state.stamps` (today `index => language`) widens to `index => {language, twin_text, spans}`.
- Pairing sanity check (Assumption 3): when a twin pairs with a segment, `String.trim(twin_text) != String.trim(segment_text)` → emit that segment with `spans: nil` (language kept as today).
- `segment/3` (`:1042-1045`) gains a spans argument: with a flag set, emit `committed_transcript(text, language, spans)` and append non-`nil` spans to a new `state.spans` accumulator; `release_held/1` (`:1037-1040`) and the no-twin `on_committed/4` clause (`:1021`) pass `nil`. Flags off → `/2` exactly as today.
- `completed_event/1` (`:1056-1070`): with a flag set, add `spans: Enum.reverse(state.spans) |> List.flatten()` (or the equivalent in-order concat); flags off → no key.
- Time base per 28.3 decision 3.

**Test Plan (write first)**
- `transcription_test.exs`: form contains `timestamps_granularity=word` iff a flag is `true`; a caller's `options: %{"timestamps_granularity" => "none"}` is overridden when a flag is set, passed through when not; scripted call with both flags returns Fake spans (ElevenLabs supports both).
- `transcription_wire_test.exs`: recorded `scribe_v2.json` and `words_explicit.json` decode to as many spans as each fixture's `words` list has (count derived from the fixture, not hard-coded); flag matrix (`{t, l}` ∈ `{f,f}`, `{t,f}`, `{f,t}`, `{t,t}`) asserts the population invariant; `kind` sequence begins `[:word, :spacing, :word]`; a body with `"type": "laughter_event"` → `:other`; body without `words` + flag + non-blank text → `:unsupported_feature` `:absent_from_response`; same with blank text → `{:ok, %{spans: []}}`; `words: "x"` → `:malformed_response`; flags off + `words: "x"` → `{:ok, %{spans: nil}}` (decode only when asked); `silence.json` decodes per 28.3 decision 4.
- `transcription_stream_test.exs`: `stream_url` has `include_timestamps=true` iff a flag is set; rt_fox replay with `logprobs: true` → the committed event carries spans with logprobs and nil times, and completed carries the same list; with `timestamps: true` times are non-nil; **flags off, including `options: %{"include_timestamps" => true}`** → `refute Map.has_key?` on every committed and completed payload (decision 5's falsifier); the existing hold tests (`:445-575`, `stamped/2` helper `:42-50` with `"words" => []`) stay green unmodified; new tests cover twin-first, twin-late, twin-never (→ `spans: nil`), twin text mismatch (→ `spans: nil`), and malformed twin `words` (→ `spans: nil`, stream continues); `rt_two_segments.json` replay asserts the empty middle segment and non-decreasing `start_seconds` across segments; a flagged stream with zero commits ends with completed `spans: []`.
- `examples/24_…`, `examples/26_…`: flagged calls per the wire-field map.

**Implementation Checklist**
- [ ] Batch hand-off, form, decode.
- [ ] Realtime URL, hold predicate, stamps widening, sanity check, `segment/3`, completed spans.
- [ ] Moduledoc: response row (`:93`), hold paragraph, twin pairing note (`:349-355`).
- [ ] `TranscriptionAdapterError` `:unsupported_feature` doc (`lib/allm/error/transcription_adapter_error.ex:25`) widened to the post-I/O `cause: :absent_from_response` case.
- [ ] Examples.

**Verification**
```bash
mix test test/allm/providers/elevenlabs/
mix test > "$SP/28_4.log" 2>&1; echo "exit=$?"
mix test --seed 0
mix credo --strict && mix dialyzer && mix format --check-formatted
(cd conformance && mix test)
set -a; . ./.env; set +a; ALLM_PROVIDER=elevenlabs mix run examples/run_all.exs; echo "exit=$?"
```

### 28.5 OpenAI + Gemini (Layer B)

- Both adapters: the script hand-off passes `with_span_flags(opts, supported)`; `gate_flags/4` is the last step of `gate_audio/2` (Error contract).
- **OpenAI:** supported `[:logprobs]`. With `logprobs`, `to_multipart_body/2` (`:292-312`) adds the 28.3-decided include field to the structural list and drops that key from `options` for this call. `decode_response/4` (`:318-340`): with `logprobs`, map `body["logprobs"]` via `span_from/6` (`kind: :token`, `token` → `text`); absent → decision 4 (this is where `whisper-1` lands, if a caller sends it).
- **Gemini:** supported per 28.3 decision 2 — `[:logprobs]` or `[]`. If supported: `to_json_body/2` sets `generationConfig.responseLogprobs = true` **after** `put_generation_config` (`lib/allm/providers/gemini/transcription.ex:511-516`), through a path that also runs when `options` is empty (today's clause returns the body unchanged for an empty map), so structural wins either way. `build_response` (`:525-536`) today returns a bare struct; with the absent-key error it returns `{:ok, resp} | {:error, err}`, and `decode_response/4`'s `{finish, _raw}` arm (`:351-373`) is updated to pass it through. Map `candidate["logprobsResult"]["chosenCandidates"]` (`logProbability` → `logprob`). If G1 recorded thought tokens inside `chosenCandidates`, stop and ask rather than guess a filter.

**Test Plan (write first)**
- OpenAI `transcription_test.exs`: `timestamps: true` → `:unsupported_feature` `field: :timestamps` with **no key configured** (ordering before `Keys.fetch!`); **scripted** call with `timestamps: true` → the same refusal (decision 7); scripted with `logprobs: true` → Fake token spans; form has the include field iff `logprobs == true`; a caller's `options` include is overridden when `logprobs` is set, passed through when not.
- OpenAI `transcription_wire_test.exs`: O1/O3 fixtures decode to non-empty `:token` spans with nil times; `mini_tokens.json` (no `logprobs` key, non-blank text) + `logprobs: true` → `:unsupported_feature` `:absent_from_response`; flags off over O1 → `spans: nil`; `logprobs_silence.json` per 28.3 decision 4.
- Gemini: the same `timestamps` refusal / ordering / scripted tests; branch-dependent `logprobs` tests (support: G1 decodes; the body has `responseLogprobs: true` both with empty `options` and with `options: %{"responseLogprobs" => false}`; refuse: `:unsupported_feature` `field: :logprobs`, keyless and scripted).
- Family-consistency test (CLAUDE.md: the sub-phase closing a multi-provider family owns its internal consistency): one table-driven test over `[ElevenLabs, OpenAI, Gemini]` × the four flag cells asserting refusal-or-pass exactly per the wire-field map, with **no I/O**: batch cells drive each adapter's `prepare_request(req, api_key: "test-key")` (gates + build, no send) and assert `{:ok, %Req.Request{}}` for pass / `{:error, %{reason: :unsupported_feature}}` for refuse (refusal cells additionally run keyless through `transcribe/2` to pin gate-before-key); the ElevenLabs realtime column uses the existing raising `:ws_module` stub (`transcription_stream_test.exs:817`). An ambient `*_API_KEY` in the shell must not change the outcome. Lives in `test/allm/providers/support/transcription_adapter_test.exs` (the shared module's test file).
- `examples/24_…`: OpenAI logprobs call; Gemini per branch.

**Verification**
```bash
mix test test/allm/providers/openai/ test/allm/providers/gemini/ test/allm/providers/support/
mix test > "$SP/28_5.log" 2>&1; echo "exit=$?"
mix test --seed 0
mix credo --strict && mix dialyzer && mix format --check-formatted
(cd conformance && mix test)
set -a; . ./.env; set +a
ALLM_PROVIDER=openai mix run examples/run_all.exs; echo "exit=$?"
ALLM_PROVIDER=gemini mix run examples/run_all.exs; echo "exit=$?"
```
(Blocked arms follow CLAUDE.md's re-characterization rule: run past the halt individually and record per-script results.)

### 28.6 Spec, guide, CHANGELOG (docs)

- Spec amendments, each opening `> **Phase 28 amendment (commits <first>..<last>).**`:
  - §37.2.3: the two request flags, `:spans`, the population invariant (reference `ALLM.TranscriptSpan`'s moduledoc rather than restating the attribute rules).
  - §37.2.5: `:unsupported_feature` post-I/O `cause: :absent_from_response`, and the blank-text success case.
  - §37.2.6 / §37.11.2: the two `:invalid_shape` rows.
  - §37.10: strike "timestamps" → "segment-level timestamps, character timings, diarization, `srt`/`vtt`"; add `whisper-1`/`verbose_json` with the reason.
  - §37.11.1: `committed_transcript` `:spans` key and `/3`; the optional completed `:spans` key; streaming invariants 1–3 by reference.
- `guides/audio.md`: new `## Word timings and confidence` section after `## Streaming transcription` (`:504`) — a per-provider support table (confirmed rows only; anything 28.3 left inferred is labelled so) and an `iex>` block driven by `FakeTranscription` showing `transcribe(…, timestamps: true, logprobs: true)` and `mean_logprob/1`. The "Realtime transcription on ElevenLabs" hold paragraph (`:733-739`) names the flags as a third hold trigger. No fenced real-provider example unless it compiles under `scripts/check_guide_fences.exs`.
- `ALLM.transcribe/3` and `stream_transcribe/3` `@doc`: a "Timings and log-probabilities" paragraph pointing at `ALLM.TranscriptSpan`.
- CHANGELOG entry derived from `git diff d3bcb3b..HEAD lib/` (CLAUDE.md), not from this document.

**Verification**
```bash
mix test test/guides_test.exs test/guides_doctest_test.exs
mix run scripts/audit_user_docs.exs guides/audio.md; echo "exit=$?"
mix run scripts/check_guide_fences.exs | head -1
mix docs && mix test --seed 0 && mix format --check-formatted
```

### 28.7 `[CHORE]` sweep (Layer B)

Known ticket on a file this phase already touches: `FakeTranscription` accepts a malformed `{:retry_until_call, n}` (`.work/ASKS.md:553` item 3, re-filed at Phase 24.6). Scope: `lib/allm/providers/fake_transcription.ex` only; the ticket stays open for the other four Fakes with a `[DISPOSITION]` line recording the narrowed remainder.

- The defect is at **runtime**, not in `script/1`: `validate_entry!` (`:757-768`) already rejects malformed budgets, but validation is opt-in and `transcribe/2` / `stream_transcribe/3` bypass it; `resolve_script/1`'s `{:retry_until_call, n} ->` (`:625`) and the chained `{:retry_until_call, m} ->` (`:647`) are unguarded, so `:x` returns `:rate_limited` forever and `0` skips. Fix: guard both arms `when is_integer(n) and n >= 1` (mirroring `FakeClassification`, `lib/allm/providers/fake_classification.ex:301`) and raise `ArgumentError` naming the entry otherwise.
- Done predicate is **behavioural**: a test in `fake_transcription_test.exs` driving each malformed entry (`{:retry_until_call, 0}`, `{:retry_until_call, -1}`, `{:retry_until_call, :x}`) through `transcribe/2` **and** `stream_transcribe/3` (not `script/1`) asserting a raise naming the entry; red before the fix. Companion predicate: `grep -nE '\{:retry_until_call, [nm]\} ->' lib/allm/providers/fake_transcription.ex` → empty.
- Not swept: the `:cause` exception-struct ticket (`.work/ASKS.md:533`). Fixing it for transcription alone would make the transcription family's error `:cause` diverge from speech/embeddings/images; its owner is the stand-alone family-wide `[CHORE]` it names. Recorded here so its omission is a decision, not an oversight.

**Verification:** as 28.2, plus the new test's name in `_RECORDS.md`.

---

## Cross-phase Test Matrix

Option × path coverage (DESIGN.md rule 10). Each cell names the sub-phase and test file that owns it.

| Flags `{timestamps, logprobs}` | Fake batch | Fake stream | EL batch | EL realtime | OpenAI | Gemini |
|---|---|---|---|---|---|---|
| `{f, f}` | 28.2 fake | 28.2 fake (`refute :spans`) | 28.4 wire | 28.4 stream (`refute :spans`) | 28.5 wire | 28.5 wire |
| `{t, f}` | 28.2 | 28.2 | 28.4 wire | 28.4 stream | 28.5 refuse | 28.5 refuse |
| `{f, t}` | 28.2 | 28.2 | 28.4 wire | 28.4 stream | 28.5 wire | 28.5 branch |
| `{t, t}` | 28.2 | 28.2 | 28.4 wire | 28.4 stream | 28.5 refuse (timestamps first) | 28.5 refuse |

`6 paths × 4 flag cells = 24` cells, all owned; the family test in 28.5 re-asserts the three real-adapter columns keyless.

## Definition of Done

- [ ] Every sub-phase `Completed` in `_RECORDS.md`.
- [ ] `mix test` (random and `--seed 0`) zero failures; coverage ≥ 80% global, ≥ 90% on new code.
- [ ] `mix credo --strict`, `mix dialyzer`, `mix format --check-formatted` clean; `conformance/` gates clean.
- [ ] Every new public function has `@spec` + `@doc` with a runnable doctest.
- [ ] `ALLM.TranscriptSpan` and all three modified request/response structs round-trip term and JSON with non-default values.
- [ ] Stream-equivalence property covers `spans`, including empty text.
- [ ] Each 28.3 arm's recorded fixture has its negative provenance test; the four decisions are in `_RECORDS.md` with fixture paths.
- [ ] Live `examples/run_all.exs` gates run for ElevenLabs, OpenAI and Gemini with flagged calls, any blocked arm re-characterized per CLAUDE.md.
- [ ] Spec amendments carry the commit range; CHANGELOG derived from `git diff`.
- [ ] README untouched.
