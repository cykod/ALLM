# Phase 25: Speech Synthesis & Transcription (TTS + STT) — Design Document

*Generated 2026-09-24 · Measured against: `34e3024`*

> **Goal:** Add two provider-neutral, non-streaming audio primitives — `ALLM.synthesize/3` (text-to-speech) and `ALLM.transcribe/3` (speech-to-text) — with bundled OpenAI adapters for both and a Gemini adapter for transcription, shaped so a later ElevenLabs adapter pair drops in without façade or engine changes.
> **Outcome:** `ALLM.synthesize(engine, "Hello.", voice: "alloy")` returns `{:ok, %ALLM.SpeechResponse{audio: %ALLM.Audio{}}}` whose bytes play as MP3, and `ALLM.transcribe(engine, ALLM.Audio.from_file("clip.mp3"))` returns `{:ok, %ALLM.TranscriptionResponse{text: "…"}}` — against OpenAI (`/v1/audio/speech`, `/v1/audio/transcriptions`) and, for transcription, Gemini (`:generateContent`). `ALLM_PROVIDER=openai` runs both new example scripts to exit 0; `ALLM_PROVIDER=gemini` runs the transcription script to exit 0.
> **Spec sections:** new **§37** (Audio: speech synthesis and transcription — the section number reserved for audio since Phase 19). Amends **§27** (module tree), **§29** (telemetry), **§32.5** and **§33** (strike "audio" from out-of-scope).
> **Layers touched:** A, B, C — one layer per sub-phase (25.1 = A, 25.2 = B, 25.3 = C, 25.4–25.5 = B, 25.6 = docs, 25.7 = `[CHORE]` sweep).

**Number checks (run 2026-09-24):**
- `grep -n '^## 3[7-9]\|^## 4[0-9]' steering/allm_engine_session_streaming_spec_v0_2.md` → only `## 39.` (`:2715`) and `## 40.` (`:3103`). **§37 is free.** `steering/PHASE_19_DESIGN.md:4` reserved it for "Audio I/O", and `steering/2026-09-22_JEV_SUPPORT.md` names §37 as reserved for audio. This design takes it.
- `grep -rn 'Phase 25' steering/*.md CLAUDE.md` → nothing. Phase 23 is compact tools (`34e3024`); Phase 24 is claimed by the unbuilt, untracked `steering/2026-09-22_JEV_SUPPORT.md`. **This design is Phase 25.** The numbers are labels, not an ordering: 25 may build before 24.
- `ls examples/` → highest script is `21_compact_tools.exs`, and JEV claims `22_classify_ticket.exs` (`steering/2026-09-22_JEV_SUPPORT.md:1042`). This design takes **23** and **24**.

**Relationship to `steering/PHASE_19_DESIGN.md`.** That design (v0.4 era, all six sub-phases `Not Started`) specified a single `ALLM.AudioAdapter` with `supported_operations/0`, OpenAI-only, and a separate `ALLM.AudioUsage` struct. It predates the embeddings (Phase 20) and moderation (Phase 22) families, which set the per-capability shape this design follows, and it cites line numbers from a tree 400+ commits old (e.g. `engine.ex:395`). **This design supersedes it.** 25.7 adds a one-line superseded banner at its top.

## Sub-phases

| Phase | Description | Layer |
|-------|-------------|-------|
| 25.1 | Layer A: `Audio`, `SpeechRequest/Response`, `TranscriptionRequest/Response`, two adapter errors, validators, enum and registry edits | A |
| 25.2 | Layer B: `SpeechAdapter` + `TranscriptionAdapter`, four `Engine` fields, `FakeSpeech` + `FakeTranscription`, two conformance suites | B |
| 25.3 | Layer C: `synthesize/3`, `transcribe/3`, the two `*_request/2` builders, `:synthesize`/`:transcribe` spans | C |
| 25.4 | `OpenAI.Speech` + `OpenAI.Transcription`, recorder + live probe + fixtures | B |
| 25.5 | `Gemini.Transcription`, recorder + live probe + fixtures | B |
| 25.6 | Spec §37 + amendments, `guides/audio.md`, examples 23–24, `mix.exs`, CHANGELOG | — |
| 25.7 | `[CHORE]` sweep | — |

Tick-state lives in `steering/2026-09-24_SST_SUPPORT_RECORDS.md` (created on first need).

---

## Assumptions

Three change the shape of the work and are marked **★**.

1. **★ Scope: TTS on OpenAI; STT on OpenAI and Gemini.** The request started as "TTS, OpenAI first"; a follow-up added *"ALLM.transcribe - also add support for Gemini's"*, and the owner confirmed (2026-09-24) **Gemini transcription only for now**. Gemini TTS was probed during design and works; its wire facts are kept in **Deferred: Gemini TTS** below for a later phase. ElevenLabs TTS and STT are the owner's stated next providers, so the contracts are checked against that shape (Decision #10) without building it.
2. **★ Non-streaming only.** Both providers can stream TTS audio: OpenAI via chunked transfer and `stream_format: "sse"` (probed: `speech.audio.delta` / `speech.audio.done` events carrying `usage`); Gemini via `streamGenerateContent`. Neither fits the closed `ALLM.Event` union (§8), and adding variants breaks every reducer. It is deferred as its own design. See **Alternative D**.
3. **★ One behaviour per capability, not one `AudioAdapter`.** See **Alternative A**. This follows the two newest families (`EmbeddingAdapter`, `ModerationAdapter`), not Phase 19's image-style operations enum.
4. **Model strings stay late-resolved (§6.3), and no capability pre-flight is added.** `llm_db` is still not a dependency (`mix.exs:39`: *"llm_db: capability pre-flight + cost. Deferred to a future release"*), and no catalog key for audio capabilities exists to check. `preflight_embedding/2` and `preflight_moderation/2` exist but are inert. Adding two more inert helpers with invented capability keys would be speculative vocabulary (agent-spec/DESIGN.md rule 13). Adding them later is additive.
5. **No voice catalogue in the library.** Voice names are provider-shaped strings forwarded verbatim. OpenAI's valid set is per model: `tts-1` rejects `marin` with an enum 400 listing 9 voices (probed), while the API reference lists 13 for the newer models. Gemini's names (`Kore`, `Puck`, …) are disjoint from OpenAI's. A library-side enum would be wrong for at least one model the day it shipped.
6. **Transcription output is text only.** `verbose_json` word/segment timestamps (whisper-1 only), `diarized_json` (`gpt-4o-transcribe-diarize` only), and `srt`/`vtt` are out of scope. Each is model-specific (`gpt-4o-mini-transcribe` rejects `verbose_json` with a 400, probed). The provider's full body stays on `response.raw` for callers who need it.
7. **Release is out of scope for this phase.** At `34e3024`, `mix.exs @version` is `0.5.0` and `git tag` ends at `v0.5.0`, while `CHANGELOG.md:1` already heads `v0.6.0` (moderation + compact tools, unreleased). If v0.6.0 is still unpublished when 25.6 lands, this phase's CHANGELOG lines go inside that entry. Whether and when to publish is the maintainer's call: they run `scripts/release.exs` separately (it calls `mix hex.publish` interactively, which an unattended build must never do). `mix.exs @version` is never hand-edited.

---

## Alternatives Considered

### A. One `AudioAdapter` vs one behaviour per capability

| Option | Trade-off |
|--------|-----------|
| A1 — one `ALLM.AudioAdapter` with `transcribe/2` + `synthesize/2` + `supported_operations/0` (Phase 19's shape) | Mirrors `ImageAdapter`'s multi-operation pattern. **Cost:** one engine slot has to serve two unrelated models. A caller wanting Gemini STT and OpenAI TTS (a realistic pairing: Gemini STT is cheap, OpenAI TTS has the voices) cannot express it on one engine. Every adapter also needs an `:unsupported_operation` path. |
| **A2 — `ALLM.SpeechAdapter` + `ALLM.TranscriptionAdapter`, two engine slots (chosen)** | Matches the Phase 20/22 families, which are each one capability per behaviour. Each slot resolves independently, so the pairing above is one `Engine.new/1` call. **Cost:** two conformance suites, two Fakes, two error types — more files, all mechanical. |

### B. How audio bytes appear on the response

| Option | Trade-off |
|--------|-----------|
| B1 — `SpeechResponse.audio :: binary()` plus a custom `Jason.Encoder` doing base64 | Smallest. But a second base64 encoder alongside `ALLM.Image`'s, and STT still needs an input value type. |
| **B2 — a shared `ALLM.Audio` value type, used as STT input and TTS output (chosen)** | The `ALLM.Image` precedent: one value type is both the vision *input* and the generation *output* (`lib/allm/image.ex:1-8`: *"A serializable image value used by image generation, editing, and vision inputs"*). Base64-on-JSON lives in exactly one encoder, copied from `lib/allm/image.ex:354-369`. |

### C. Error types — shared vs per-capability

The two reason enums below are identical in membership. One `ALLM.Error.AudioAdapterError` would save a module. **Chosen: per-capability** (`SpeechAdapterError`, `TranscriptionAdapterError`), because the façade's invariant-2 raise and each conformance suite pattern-match on the error *module*. Every existing capability carries its own error type (`ls lib/allm/error/` → `image_`, `embedding_`, `moderation_adapter_error.ex`), and a shared type would let a transcription adapter return a speech-flavoured error the type system cannot catch. The duplication is a module header plus a reason table.

### D. Streaming TTS

Deferred. The value is real, because first-audio latency is what voice apps optimize. But the shape is undecided: a new `ALLM.Event` variant (breaking, §8), a separate `Enumerable.t()` of raw byte chunks outside the event protocol, or a `SpeechStreamAdapter` behaviour. OpenAI's SSE mode also carries `usage` that the non-streaming body lacks (probed: `{"type":"speech.audio.done","usage":{"input_tokens":2,"output_tokens":43,"total_tokens":45}}`). Nothing here forecloses it: `SpeechRequest` has no `:stream` field, and `synthesize/3` drops `stream: true` silently, like `embed/3` and `moderate/3`.

---

## Overview

ALLM covers chat, images, embeddings, and moderation, but not audio. Spec §32.5 still reads *"audio — callers drop down to a provider SDK directly"* (`steering/allm_engine_session_streaming_spec_v0_2.md:1970`). This phase adds the two request/response audio primitives both bundled multimodal providers expose. Structurally it is the moderation family twice over: Layer A request/response pair, per-capability behaviour + error enum, engine slot, façade, telemetry span, Fake, and published conformance suite. It adds four things that family does not have:
- a **binary payload** crossing the serializer (`ALLM.Audio`, Alternative B);
- a **multipart upload** on the OpenAI STT side (the image-edit precedent at `lib/allm/providers/openai/images.ex:744-756`);
- a **second provider whose transcription is prompted chat** (Gemini `:generateContent`), whose output is an LLM's answer rather than a dedicated model's transcript (Decision #8);
- **per-slot models on the engine** (Decision #10), because an audio slot's model namespace never matches the chat model's.

### Deliverables

**Layer A (new):** `ALLM.Audio`, `ALLM.SpeechRequest`, `ALLM.SpeechResponse`, `ALLM.TranscriptionRequest`, `ALLM.TranscriptionResponse`, `ALLM.Error.SpeechAdapterError`, `ALLM.Error.TranscriptionAdapterError`.
**Layer A (modified):** `EngineError`, `ValidationError`, `Serializer` (`@known_modules`), `Validate` (`speech_request/1`, `transcription_request/1`), per the enum-extension table.
**Layer B (new):** `ALLM.SpeechAdapter`, `ALLM.TranscriptionAdapter`, `ALLM.Providers.FakeSpeech`, `ALLM.Providers.FakeTranscription`, `ALLM.Providers.OpenAI.Speech`, `ALLM.Providers.OpenAI.Transcription`, `ALLM.Providers.Gemini.Transcription`, `ALLM.Test.SpeechAdapterConformance`, `ALLM.Test.TranscriptionAdapterConformance`.
**Layer B (modified):** `ALLM.Engine` (four fields: two adapter slots and their two per-slot models, every site in the Engine-extension table); `ALLM.Telemetry` (two span names, landed in 25.3 with their only caller).
**Layer C (new):** `ALLM.synthesize/3`, `ALLM.speech_request/2`, `ALLM.transcribe/3`, `ALLM.transcription_request/2`.

### Spec coverage

New **§37**. Amends §27, §29, §32.5 (strike "audio"), and §33 (`:1986` "audio input/output" plus its Phase 20 note at `:1994`, *"Audio input/output remains a genuine non-goal."*). §35.7 (bundled-adapter rule) is **not** amended: both providers are already bundled for chat, so every new adapter qualifies under criterion (a), the maintenance-overlap criterion quoted at `:3026`.

### Layer demonstration

**Layer A**, with no engine and no network:

```elixir
req = ALLM.speech_request("Hello.", voice: "alloy", format: :mp3)
:ok = ALLM.Validate.speech_request(req)
{:ok, ^req} = req |> ALLM.Serializer.to_json!() |> ALLM.Serializer.from_json()
treq = ALLM.transcription_request(ALLM.Audio.from_file("clip.mp3"), language: "en")
```

**Layer B**, calling an adapter directly and bypassing the façade:

```elixir
{:ok, %ALLM.SpeechResponse{audio: audio}} =
  ALLM.Providers.OpenAI.Speech.synthesize(ALLM.SpeechRequest.new(input: "Hi.", model: "tts-1"), api_key: "sk-…")
{:ok, bytes} = ALLM.Audio.to_binary(audio)
```

**Layer C**, the façade with its gates and spans. Two slots, two providers, one engine:

```elixir
engine = ALLM.Engine.new(speech_adapter: ALLM.Providers.OpenAI.Speech,
                         transcription_adapter: ALLM.Providers.Gemini.Transcription)
{:ok, %{text: text}} = ALLM.transcribe(engine, ALLM.Audio.from_file("question.mp3"))
{:ok, %{audio: reply}} = ALLM.synthesize(engine, answer_to(text), voice: "coral")
```

There is **no Layer D**. Audio carries no conversation state, and `ALLM.Session` is untouched.

### Prerequisites

- Phase 22 moderation family, the structural template: `lib/allm/moderation_adapter.ex`, `lib/allm/error/moderation_adapter_error.ex`, `lib/allm/providers/openai/moderation.ex`, `lib/allm/providers/fake_moderation.ex`, `conformance/lib/allm/test/moderation_adapter_conformance.ex`, and the façade: public functions at `lib/allm.ex:1140-1380`, internals at `:1740-1941`.
- `ALLM.Image` (`lib/allm/image.ex`), the value-type template for `ALLM.Audio`.
- `OpenAIHeaders.json_headers/2` and `multipart_headers/2` (`lib/allm/providers/support/openai_headers.ex:46`, `:63`); `GeminiHeaders.headers/1` (`lib/allm/providers/support/gemini_headers.ex:30`).
- `OPENAI_API_KEY` and `GEMINI_API_KEY` in the project-root `.env` (`grep -o '^[A-Z_]*KEY' .env` lists both, 2026-09-24).
- No new deps. `Req` handles JSON and `form_multipart:`.

### Out of scope

| Excluded | Why |
|----------|-----|
| Streaming TTS / real-time STT | Alternative D. |
| OpenAI `/v1/audio/translations` | English-only, `whisper-1`-only per OpenAI's guide; a caller-visible second operation for one model on one provider. Reachable later as a `TranscriptionRequest` option. |
| Timestamps, diarization, `srt`/`vtt` | Assumption 6. `response.raw` carries the body. |
| OpenAI custom voices (`{"id": "voice_…"}`) | Gated behind OpenAI's consent/approval process per their TTS guide. `SpeechRequest.voice` is a string. A voice-object passthrough can come later through `:options`. |
| Gemini TTS | Owner decision 2026-09-24: transcription only for now. Probed facts in **Deferred: Gemini TTS**. |
| ElevenLabs TTS / STT | The owner's stated next providers. Not bundled for chat, so admission needs a §35.7 criterion (the JEV design proposes a third one; `steering/2026-09-22_JEV_SUPPORT.md`). The contracts here are checked against its shape: voice ids are strings (Decision #5), formats are file formats (Decision #3), models are per slot (Decision #10). |
| Gemini Files API for audio > 20 MB | A second upload-then-reference round trip. The 20 MB inline gate names the limit. |
| Anthropic | No audio endpoint. |
| Capability pre-flight | Assumption 4. |
| A voice catalogue | Assumption 5. |
| `ALLM.Audio.from_url/1` | Neither provider accepts a URL for audio input. `ALLM.Image`'s `{:url, _}` variant exists because vision providers do. |
| Audio as a chat `Message` content part | A chat-adapter change (a new `AudioPart` in `Message.content`) touching both OpenAI translators and Gemini's. Separate design. |
| `ALLM.Session` integration | No conversation state. |

### Non-obvious decisions

1. **Two behaviours, two engine slots** (`:speech_adapter`, `:transcription_adapter`). Alternative A. *Docs target: `@moduledoc ALLM.SpeechAdapter`, `@moduledoc ALLM.TranscriptionAdapter`, spec §37.*
2. **`ALLM.Audio` is one value type for both directions.** Alternative B. TTS output is `%Audio{source: {:binary, bytes}, mime_type: …}`. *Docs target: `@moduledoc ALLM.Audio`.*
3. **`SpeechRequest.format` is a closed atom enum, and `nil` means "provider default".** `:mp3 | :opus | :aac | :flac | :wav | :pcm`: exactly OpenAI's six `response_format` values (API reference, fetched 2026-09-24; each probed 200 with a matching `content-type`). The atoms name file formats, not OpenAI parameters, so a future adapter maps them onto its own wire (ElevenLabs encodes format and bitrate in one `output_format` string) or refuses the ones it cannot produce. *Docs target: `@moduledoc ALLM.SpeechRequest` + each adapter's wire table.*
4. **`SpeechResponse.format` is derived from the response, not echoed from the request.** It comes from the response `content-type` header via one mime→atom table. It is `nil` when the mime is not in the table. The request says what was asked for; the response says what arrived, and they differ whenever a request leaves `format: nil`. *Docs target: `@moduledoc ALLM.SpeechResponse`.*
5. **Voices are strings, never validated by ALLM** (Assumption 5). OpenAI requires `voice`, so the OpenAI adapter defaults `nil` to `"alloy"`, the one name accepted by every model probed. ElevenLabs puts an opaque voice id in the URL path, and a string field carries that unchanged. *Docs target: per CLAUDE.md's injected-default rule, the `"alloy"` default and each adapter's `@default_model` go in the public `@doc` of `synthesize/2` / `transcribe/2` **and** the body builder's `@doc false`, not only the moduledoc.*
6. **The OpenAI TTS adapter gates input at 4096 characters *before* key resolution, as `:context_length_exceeded`.** 4096 is documented (*"The maximum length is 4096 characters."*) and the provider enforces it (4097 `a`s → 400 `string_too_long`, probed). The gate turns a paid round-trip into a local error with `metadata.count`/`metadata.max`. "Character" is measured in **code points** (`input |> String.codepoints() |> length()`), because the provider's validator is pydantic, which counts Python `str` code points. That rationale is inferred from the error text's `('body', 'input')` pydantic shape, so the 25.4 probe carries two arms that settle it. The classifier also maps the provider's own 400 whose message contains `string_too_long` to `:context_length_exceeded`, so a caller who bypasses the gate (e.g. a different limit on a future model) sees the same reason. Gemini documents no per-request character limit and gets no gate. *Docs target: `@doc ALLM.Providers.OpenAI.Speech.synthesize/2`.*
7. **`TranscriptionResponse.usage` is an `%ALLM.Usage{}`, never `nil`; billed audio seconds get their own typed field.** This follows `EmbeddingResponse` (`lib/allm/embedding_response.ex:22`: *"`:usage` is an `t:ALLM.Usage.t/0` and is never `nil`"*). OpenAI reports usage in two shapes depending on model (probed): `{"type":"duration","seconds":3}` (whisper-1, gpt-transcribe) or `{"type":"tokens","input_tokens":27,…}` (gpt-4o-mini-transcribe). Tokens populate `Usage`; seconds populate `TranscriptionResponse.duration_seconds`. `Usage.extra` is not used for this, because a typed field survives JSON round-trip without atom/string key drift. `SpeechResponse.usage` follows the same never-`nil` rule: all-`nil` counts for OpenAI (its non-streaming TTS body is raw audio with no usage). *Docs target: `@moduledoc ALLM.TranscriptionResponse`.*
8. **Gemini transcription is prompted chat, and its output is not guaranteed verbatim.** Gemini has no transcription endpoint. The adapter sends a fixed instruction, `@transcription_instruction` ("Generate a verbatim transcript of this audio. Output only the transcript."), plus the inline audio (probed: 200, exact text back). `request.prompt` is appended as a context block and `request.language` as a one-sentence hint. The guide says plainly that an LLM transcript can paraphrase, where Whisper-family models cannot. Text is the concatenation of `text` parts, **excluding** parts marked `"thought": true`. The probe body carried a `thoughtSignature` on the answer part itself, which is not a thought part and is kept. **The decoder does not reuse `ALLM.Providers.Gemini.Decode.candidate_parts/1`** (`lib/allm/providers/gemini/decode.ex:40`): that walker turns every `inlineData` into an `%ImagePart{}` and does not drop thought parts, and extending it for audio would change the chat and image paths it serves. The divergence is named in both new decoders' `@doc false` so a reviewer does not re-litigate it. **Finish reasons** go through the chat adapter's `parse_finish_reason/1` (`lib/allm/providers/gemini.ex:1198-1200`): `MAX_TOKENS` (`{:length, _}`) returns `{:ok, resp}` with the partial text, `raw` intact and `metadata.finish_reason: :length`, so a truncated transcript is detectable without being an error. `SAFETY`/`RECITATION` (`:content_filter`) return `{:error, %TranscriptionAdapterError{reason: :content_filter}}`. The guide notes that transcribing well-known recited material can trip `RECITATION`. *Docs target: `@moduledoc ALLM.Providers.Gemini.Transcription`.*
9. **`options` is a raw provider-body passthrough, merged *under* the structural fields.** This is the `ModerationRequest.options` precedent, where `to_json_body/2` (`lib/allm/providers/openai/moderation.ex:477-490`) merges options first so `input`/`model` always win. It lets callers reach provider fields ALLM does not model (e.g. Gemini `generationConfig.temperature`, OpenAI `include[]`) without a library release, but it can never override a field the adapter sets. That matters because two fields change the response *shape* the decoder relies on: OpenAI STT's `response_format` (always `json`) and OpenAI TTS's `stream_format` (never sent). Both are therefore **also** listed as reserved and dropped from `options`, with a deferred `Logger.debug/1`. Placement per adapter: OpenAI TTS is top-level JSON; OpenAI STT has one multipart form field per entry; Gemini STT is deep-merged into `generationConfig`. *Docs target: each request struct's `@moduledoc` and each adapter's wire table.*
10. **Each audio slot carries its own model on the engine: `:speech_model` and `:transcription_model`. The audio façades never read `engine.model`.** `engine.model` is the chat model, and an audio model never shares its namespace: a Gemini chat model sent to a TTS request returns 200 *with a text part* instead of audio (`gemini-flash-latest`, probed), and ElevenLabs' `eleven_multilingual_v2` / `scribe_v1` exist only on that provider. Per-slot fields keep each adapter's model persisted with its adapter, so a serialized engine pairing OpenAI chat, ElevenLabs speech and Gemini transcription round-trips intact. Resolution (normative, stated once here): `request.model || engine.<slot>_model`, then the adapter's `@default_model` when still `nil`. For the string/`%Audio{}` call shapes, `opts[:model]` reaches `request.model` through the allow-list; a request struct is authoritative and is not merged. This is the one place the audio façades differ from `generate_image/3`, `embed/3` and `moderate/3`, which fall back to `engine.model` via `Engine.resolve_model/2` (`lib/allm/engine.ex:405`). *Docs target: `@moduledoc ALLM.Engine` field table, `@doc ALLM.synthesize/3` and `ALLM.transcribe/3` "Model resolution" sections, `guides/audio.md`.*
11. **No batching and no `max_batch_size/0`.** Both endpoints take one input per call, and neither documents a multi-input form. The error enums therefore drop `:batch_too_large`. *Docs target: internal.*
12. **Unknown fields are accepted by OpenAI and rejected by Gemini (both probed), so the probe controls differ per provider.** OpenAI `/audio/speech` and `/audio/transcriptions` both 200 with `not_a_real_field`, the same permissive behaviour Phase 22.4 recorded for `/moderations`. Gemini returns 400 `Unknown name "notARealField"`. On OpenAI, request acceptance confirms nothing and only response observables promote a wire-field-map row. On Gemini, acceptance is evidence. *Docs target: internal (recorder header comments).*

---

## Behaviour & Type Contracts

Every signature, wire shape, and invariant is stated normatively **once**, here. Later sections cite it.

### Layer A — `ALLM.Audio`

```elixir
defmodule ALLM.Audio do
  @type source :: {:binary, binary()} | {:base64, String.t()} | {:file, Path.t()}
  @type t :: %__MODULE__{source: source(), mime_type: String.t() | nil, metadata: map()}

  @enforce_keys [:source]
  defstruct [:source, :mime_type, metadata: %{}]

  @spec from_file(Path.t()) :: t()                      # no I/O; mime from extension, else nil
  @spec from_binary(binary(), String.t()) :: t()
  @spec from_base64(String.t(), String.t()) :: t()
  @spec to_binary(t()) :: {:ok, binary()} | {:error, :invalid_base64 | :invalid_source | File.posix()}
  @spec size(t()) :: {:ok, non_neg_integer()} | {:error, :invalid_base64 | :invalid_source | File.posix()}
  @doc false
  @spec __from_tagged__(map()) :: t()
end
```

- **Structure mirrors `ALLM.Image`** minus `{:url, _}` and the image-only fields. Encoder: `source_to_map/1` pre-pass, then `Serializer.encode_tagged/2`, with the `{:binary, b}` arm base64-encoding. Quoted from `lib/allm/image.ex:366`: `defp source_to_map({:binary, b}), do: %{"type" => "binary", "value" => Base.encode64(b)}`. Decode: `decode_source/1`. Invalid base64 in a `"binary"` source **raises a pre-built `ValidationError`** `{[:source], :invalid_base64}`, so the field path survives `Serializer.hydrate_with/2`'s `ArgumentError` rescue (the reasoning at `lib/allm/image.ex:334-337`). An unknown source type raises `ArgumentError`, which becomes `{:_unknown, :atom_decode_failed}`.
- **`@ext_to_mime`** (lowercase extension → mime): `.mp3 audio/mpeg`, `.mp4 audio/mp4`, `.m4a audio/mp4`, `.mpeg audio/mpeg`, `.mpga audio/mpeg`, `.wav audio/wav`, `.webm audio/webm`, `.ogg audio/ogg`, `.oga audio/ogg`, `.flac audio/flac`, `.aac audio/aac`, `.opus audio/opus`, `.aiff audio/aiff`. The set is the union of OpenAI's accepted list (probed error text: `['flac', 'm4a', 'mp3', 'mp4', 'mpeg', 'mpga', 'oga', 'ogg', 'wav', 'webm']`) and OpenAI's TTS output formats. Gemini's accepted audio mimes are an adapter concern (wire map).
- **`size/1`** exists so both STT adapters' size gates share one resolver. It is **not** named `byte_size/1`: a local `byte_size/1` conflicts with the auto-imported `Kernel.byte_size/1` at every unqualified call site in the module, guards included (compile error *"imported Kernel.byte_size/1 conflicts with local function"*). `{:binary, b}` → `Kernel.byte_size(b)`; `{:base64, s}` decodes; `{:file, path}` uses `File.stat/1` (`.size`) and never reads the file; any other `:source` shape → `{:error, :invalid_source}`. A missing file → `{:error, :enoent}`. Those errors are what the gates convert to `:invalid_request` (the missing-file hazard Phase 22.5 hit: `ImageMime.check_byte_size/1` returned `:ok` on unresolvable bytes).
- **Constructor discipline:** `from_*` builders only; no `new/1` (`ALLM.Image` has none). `@enforce_keys [:source]` makes `struct!(Audio, [])` raise `ArgumentError`.
- **`defimpl Inspect, for: ALLM.Audio`** renders the payload as a size, never the bytes: `{:binary, <<N bytes>>}` / `{:base64, <<N chars>>}`, while `{:file, path}` shows the path. Without it, the façade's invariant-1 `raise ArgumentError, "… #{inspect(other)}"` (counterpart `lib/allm.ex:1896-1899`), ExUnit failure diffs, `Logger` calls and telemetry handlers would print megabytes of audio (`grep -rn 'defimpl Inspect' lib` is empty at `34e3024`, so this is the first).

### Layer A — `ALLM.SpeechRequest`

```elixir
@type format :: :mp3 | :opus | :aac | :flac | :wav | :pcm
@type t :: %__MODULE__{
        input: String.t(), model: String.t() | nil, voice: String.t() | nil,
        format: format() | nil, instructions: String.t() | nil, speed: number() | nil,
        options: map(), metadata: map()
      }
defstruct [:model, :voice, :format, :instructions, :speed, input: "", options: %{}, metadata: %{}]
@spec new(keyword()) :: t()          # bare struct!/2 — no guards, no @enforce_keys
@spec formats() :: [format()]        # the closed list; single source for Validate + adapters
```

- `input: ""` is constructible, so `Validate.speech_request/1` (not `struct!/2`) rejects it.
- **`__from_tagged__/1`:** `format` decodes through `Serializer.to_atom_field/1` (`lib/allm/serializer.ex:202-204`: `String.to_existing_atom/1`, `nil` pass-through). Every other field uses `data["k"] || default`. That is safe because no default is truthy (CLAUDE.md `decode_<field>` rule).

### Layer A — `ALLM.SpeechResponse`

```elixir
@type t :: %__MODULE__{
        audio: ALLM.Audio.t() | nil, format: ALLM.SpeechRequest.format() | nil,
        id: String.t() | nil, request_id: String.t() | nil, model: String.t() | nil,
        provider: atom() | nil, usage: ALLM.Usage.t(), raw: term(), metadata: map()
      }
defstruct [:audio, :format, :id, :request_id, :model, :provider, :raw, usage: %ALLM.Usage{}, metadata: %{}]
@spec new(keyword()) :: t()
@spec mime_to_format(String.t() | nil) :: ALLM.SpeechRequest.format() | nil
@spec format_to_mime(ALLM.SpeechRequest.format()) :: String.t()
```

- `mime_to_format/1` is Decision #4's one table. `audio/mpeg`→`:mp3`, `audio/opus`→`:opus`, `audio/aac`→`:aac`, `audio/flac`→`:flac`, `audio/wav`→`:wav`, `audio/pcm`→`:pcm` (all six OpenAI content-types probed 2026-09-24). Anything else → `nil`. Parameters after `;` are stripped before lookup. `format_to_mime/1` is the forward table: each format → its OpenAI content-type. The two are kept as separate functions so a future provider's extra mime (e.g. Gemini's historical `audio/L16`→`:pcm`) extends only `mime_to_format/1`.
- **`raw`:** OpenAI's TTS 200 has no JSON body, so `raw` is `nil`. **An adapter must never put the audio bytes in `raw`**: bytes live once, in `:audio`, so a persisted response does not store the audio twice. A future adapter whose body carries base64 audio replaces it with `"<N bytes>"` in `raw`.
- Decode: `audio` via `Serializer.hydrate/1`; `format` via `to_atom_field/1`; `provider` via `to_atom_field/1`; `usage` via hydrate with a `%Usage{}` fallback, the pattern `EmbeddingResponse.hydrate_usage/1` implements at `lib/allm/embedding_response.ex:135`.

### Layer A — `ALLM.TranscriptionRequest` / `ALLM.TranscriptionResponse`

```elixir
# TranscriptionRequest
@type t :: %__MODULE__{audio: ALLM.Audio.t() | nil, model: String.t() | nil,
                       language: String.t() | nil, prompt: String.t() | nil,
                       options: map(), metadata: map()}
defstruct [:audio, :model, :language, :prompt, options: %{}, metadata: %{}]
@spec new(keyword()) :: t()

# TranscriptionResponse
@type t :: %__MODULE__{text: String.t(), language: String.t() | nil,
                       duration_seconds: number() | nil, id: String.t() | nil,
                       request_id: String.t() | nil, model: String.t() | nil,
                       provider: atom() | nil, usage: ALLM.Usage.t(), raw: term(), metadata: map()}
defstruct [:language, :duration_seconds, :id, :request_id, :model, :provider, :raw,
           text: "", usage: %ALLM.Usage{}, metadata: %{}]
@spec new(keyword()) :: t()
```

- `audio: nil` is constructible, so the validator's `{:audio, :invalid_shape}` row is reachable.
- `language` is a string as the provider reports it. OpenAI `gpt-transcribe` returns `"languages":[{"code":"en"}]` (probed), and the adapter takes the first `code`. `whisper-1` `verbose_json` says `"english"`, but that format is out of scope. Not normalized.
- Request decode: `audio` via `Serializer.hydrate/1`. Response decode: `provider` via `to_atom_field/1`, `usage` hydrated with fallback.

### Layer A — errors

`ALLM.Error.SpeechAdapterError` has **nine reasons**: the `ModerationAdapterError` enum (`lib/allm/error/moderation_adapter_error.ex`, `@type reason`) **minus `:batch_too_large`** (Decision #11) **and minus `:unsupported_feature`**; no speech adapter in this design refuses a request field (`OpenAI.Speech` forwards all of them). `ALLM.Error.TranscriptionAdapterError` has **ten**: the same nine **plus `:content_filter`**, produced by `Gemini.Transcription` (precedent `ImageAdapterError`, `lib/allm/error/image_adapter_error.ex:35`). A later adapter that must refuse a field (ElevenLabs has no `instructions`) adds `:unsupported_feature` to its capability's enum in its own phase; adding a reason is additive for callers who match on `%SpeechAdapterError{}`.

```elixir
# SpeechAdapterError (9)
@type reason :: :authentication_failed | :rate_limited | :invalid_request
              | :context_length_exceeded | :provider_unavailable
              | :timeout | :network_error | :malformed_response | :unknown
# TranscriptionAdapterError (10) = the above | :content_filter
```

Use sites: `:context_length_exceeded` is OpenAI TTS's 4096 gate (Decision #6), and for STT it is `Gemini.Transcription`'s arm for a 400 containing `exceeds the maximum number of tokens` (the chat adapter's rule, `lib/allm/providers/gemini.ex:110`). No probe arm can produce that 400 with inline audio (wire map), so the arm is pinned by a synthesized fixture and marked inferred. It stays because it is the sibling's documented rule and becomes reachable if a Files-API path is added. `:content_filter` is used by `Gemini.Transcription` (`parse_finish_reason/1` returning `{:content_filter, _}`, or `promptFeedback.blockReason`), and every other reason by the HTTP classifiers.

Structural shape copies `lib/allm/error/moderation_adapter_error.ex`: reason table in the moduledoc, `@type reason`, duplicate `@legal_reasons ~w(…)a`, `legal_reasons/0` with a `length == 9` (speech) / `length == 10` (transcription) doctest, `defexception [:reason, :message, :provider, :status, :retry_after_ms, :cause, metadata: %{}]`, `new/2` raising `ArgumentError` off-enum, three-clause `message/1`, `__from_tagged__/1`, trailing `defimpl Jason.Encoder`.

### Layer A — enum extensions and registration

| Module | Committed enum | Additions | Use site |
|--------|----------------|-----------|----------|
| `EngineError` | `lib/allm/error/engine_error.ex:23` (`@type`) and `:43` (`@legal_reasons`) | `:no_speech_adapter`, `:no_transcription_adapter` | façade nil-adapter clauses (25.3) |
| `ValidationError` | `lib/allm/error/validation_error.ex:41` and `:61` | `:invalid_speech_request`, `:invalid_transcription_request` | the two validators (25.1) |
| `Telemetry` | `lib/allm/telemetry.ex:94` (`@type span_name`) and `:96` (`@valid_span_names`) | `:synthesize`, `:transcribe` | the two façade spans (25.3) |

Both the type union and the runtime list are edited each time. **Serializer `@known_modules`** (`lib/allm/serializer.ex:65-99`) gains seven entries in 25.1: `ALLM.Audio`, the four request/response structs, and the two errors. All seven land in one sub-phase (rule 25).

### Layer A — validators

```elixir
@spec speech_request(SpeechRequest.t()) :: :ok | {:error, ValidationError.t()}
@spec transcription_request(TranscriptionRequest.t()) :: :ok | {:error, ValidationError.t()}
```

Shape: a hard-reject head clause, then accumulating rules through the shared `finalize/3`, mirroring `moderation_request/1` (`lib/allm/validate.ex:387-391`). **Exhaustive vocabulary:**

| Validator | Field | Atom | Hard? | Fires when |
|-----------|-------|------|-------|-----------|
| speech | `:input` | `:invalid_shape` | **yes** | not a binary |
| speech | `:input` | `:empty` | no | `""` |
| speech | `:input` | `:invalid_encoding` | no | binary but `not String.valid?/1` (a non-UTF-8 input would otherwise raise inside `Jason` in the adapter, breaking invariant 1) |
| speech | `:model` / `:voice` / `:instructions` | `:invalid_shape` | no | neither `nil` nor binary |
| speech | `:format` | `:unknown` | no | not `nil` and not in `SpeechRequest.formats/0` (existing off-enum vocabulary: `{:response_format, :unknown}`, `lib/allm/validate.ex:654`) |
| speech | `:speed` | `:out_of_range` | no | not `nil` and not a number `> 0` |
| transcription | `:audio` | `:invalid_shape` | **yes** | not an `%ALLM.Audio{}` |
| transcription | `[:audio, :source]` | `:invalid_shape` | no | not one of the three `Audio.source()` tuple shapes (with a binary payload); caught here so a hand-built bad source never reaches an adapter and trips the invariant-1 raise |
| transcription | `:model` / `:language` / `:prompt` | `:invalid_shape` | no | neither `nil` nor binary |

Provider ranges (OpenAI speed `0.25..4.0`, probed 400 at 5) are **not** validated. They are per-provider, and the provider's own 400 maps to `:invalid_request`. Audio byte size and mime are adapter gates (below), because they differ per provider and need file I/O.

### Layer B — `ALLM.SpeechAdapter`

```elixir
@callback synthesize(ALLM.SpeechRequest.t(), keyword()) ::
            {:ok, ALLM.SpeechResponse.t()} | {:error, ALLM.Error.SpeechAdapterError.t()}
@callback prepare_request(ALLM.SpeechRequest.t(), keyword()) ::
            {:ok, Req.Request.t()} | {:error, ALLM.Error.SpeechAdapterError.t()}
@optional_callbacks prepare_request: 2
```

**Numbered invariants (normative):**
1. `synthesize/2` returns exactly `{:ok, %SpeechResponse{}}` or `{:error, %SpeechAdapterError{}}`. **Enforced** by the façade raise (25.3).
2. On success, `response.audio` is an `%ALLM.Audio{source: {:binary, bytes}}` with `byte_size(bytes) > 0` and a binary `:mime_type` beginning `audio/`. A 200 whose payload is not audio is `:malformed_response`.
3. `response.format` is `nil` or a member of `SpeechRequest.formats/0`.
4. Empty input (`""`) is rejected with `:invalid_request` **before any I/O and before `ALLM.Keys.fetch!/2`** (the Phase 20.2 ordering, `lib/allm/embedding_adapter.ex:39-43`).
5. `opts[:request_id]` is reflected onto `response.request_id` when supplied.
6. `request.metadata` round-trips onto `response.metadata`.
7. `opts[:request_timeout]` is honoured; expiry → `:timeout`. When absent, the adapter applies its own documented default (below).
8. `prepare_request/2` returns an unfired `Req.Request` configured as `synthesize/2` would fire it.

**Cleanup invariant: none.** `Req` owns the connection.

### Layer B — `ALLM.TranscriptionAdapter`

```elixir
@callback transcribe(ALLM.TranscriptionRequest.t(), keyword()) ::
            {:ok, ALLM.TranscriptionResponse.t()} | {:error, ALLM.Error.TranscriptionAdapterError.t()}
@callback max_audio_bytes() :: pos_integer()
@callback prepare_request(ALLM.TranscriptionRequest.t(), keyword()) ::
            {:ok, Req.Request.t()} | {:error, ALLM.Error.TranscriptionAdapterError.t()}
@optional_callbacks prepare_request: 2
```

`max_audio_bytes/0` is the size cap the gate measures against and the guide quotes (the `max_batch_size/0` role in the sibling families). It traces to a user story: a caller checking a file before upload.

**Numbered invariants:**
1. `transcribe/2` returns exactly `{:ok, %TranscriptionResponse{}}` or `{:error, %TranscriptionAdapterError{}}`. Enforced by the façade raise.
2. On success, `response.text` is a binary (possibly `""` for silence), and `response.usage` is an `%ALLM.Usage{}`.
3. Audio whose bytes cannot be resolved (missing file, invalid base64) → `:invalid_request` with `metadata.cause`, **before I/O and before `Keys.fetch!/2`**.
4. Audio over `max_audio_bytes/0` → `:invalid_request` with `metadata.count` (bytes) and `metadata.max`, same ordering.
5. `max_audio_bytes/0` returns a `pos_integer()`.
6. `opts[:request_id]` → `response.request_id`.
7. `request.metadata` round-trips.
8. `opts[:request_timeout]` honoured → `:timeout`.
9. `prepare_request/2` as for speech, defined only for audio that passes invariants 3–4.

MIME acceptance is **not** a behaviour invariant: accepted sets differ per provider. Each adapter gates its own (wire maps). **Gate order in every transcription adapter is fixed: resolvable (3) → size (4) → mime (adapter-specific) → `Keys.fetch!/2`.** Conformance cases use `audio/mpeg`, so a mime gate can never pre-empt cases 3–4's expected metadata.

**Cleanup invariant: none.**

### Layer B — `ALLM.Engine` extension

This table is the single source for the site count, measured at `34e3024` by locating `moderation_adapter` and `model` in `lib/allm/engine.ex`. The **adapter** fields (`:speech_adapter`, `:transcription_adapter`, `module() | nil`) go at every site below. The **model** fields (`:speech_model`, `:transcription_model`, `String.t() | nil`, Decision #10) go at sites 2, 3, 4, 7 and 8, plus the moduledoc field table where `:model` is described. They are plain strings, so they are not in `@module_fields` and decode as `data["speech_model"]` with no `restore_module/1`.

| # | Site | Line | What |
|---|------|------|------|
| 1 | moduledoc serializability bullet | `:41` | module-typed field list |
| 2 | `@type t` | `:103` | `module() \| nil` ×2 |
| 3 | `defstruct` | `:119` | `nil`-default group |
| 4 | `@engine_field_keys` | `:145` | `resolve_params/2` deny-list |
| 5 | `@module_fields` | `:165` | `new/1` module validation |
| 6 | `new/1` `@doc` prose | `:177` | module-typed field sentence |
| 7 | `resolve_params/2` `@doc` prose | `:468` | hand-maintained deny-list prose |
| 8 | `__from_tagged__/1` | `:510` | `restore_module(data["…"])` ×2 |
| 9 | `new/1` `@doc` Fake-cursor prose | `:188-191` | `Fake`/`FakeImages`/`FakeEmbeddings`/`FakeModeration` list gains `FakeSpeech`/`FakeTranscription` |
| 10 | `put_cursor_key/2` comment | `:240-242` | same list |
| 11 | moduledoc `:id` bullet Fake list | `:36-39` | same list |

Five code sites and six prose sites. Sites 9, 10 and 11 (the Fake lists) are the ones a grep for the field name misses.

### Layer C — façade

```elixir
@spec speech_request(String.t(), keyword()) :: SpeechRequest.t()
@spec synthesize(Engine.t(), String.t() | SpeechRequest.t(), keyword()) ::
        {:ok, SpeechResponse.t()} | {:error, EngineError.t() | ValidationError.t() | SpeechAdapterError.t()}

@spec transcription_request(Audio.t(), keyword()) :: TranscriptionRequest.t()
@spec transcribe(Engine.t(), Audio.t() | TranscriptionRequest.t(), keyword()) ::
        {:ok, TranscriptionResponse.t()}
        | {:error, EngineError.t() | ValidationError.t() | TranscriptionAdapterError.t()}
```

Both façades are **the moderation façade (public `lib/allm.ex:1140-1380`, internals `:1740-1941`) transcribed per capability**. Each element below names its moderation counterpart:

- **Opt allow-lists.** `@speech_request_field_opts [:model, :voice, :format, :instructions, :speed, :options, :metadata]` and `@transcription_request_field_opts [:model, :language, :prompt, :options, :metadata]` (counterpart `@moderation_request_field_opts`, `lib/allm.ex:1151`). **Symmetry invariant:** each equals its struct's field set minus the positional field (`:input` / `:audio`). Pinned by a test computing from `Map.keys/1`. The outbound `drop_*_request_opts/1` strip the same keys (counterpart `:1755`).
- **Clauses.** `synthesize/3`: head + `%SpeechRequest{}` verbatim clause + `is_binary` clause. `transcribe/3`: head + `%TranscriptionRequest{}` clause + `%Audio{}` clause.
- **Gate order inside the span:** (1) nil-adapter **pattern match** (counterpart `do_moderate_body/5`'s first clause, `:1802`); (2) validator; (3) model stamping per Decision #10 (`request.model || engine.speech_model` / `engine.transcription_model`, never `engine.model`); (4) `Retry.run/3` with a local policy from the existing `augment_retry_policy/2` (`:1530-1532`) and `@retryable_speech_reasons` / `@retryable_transcription_reasons`, each equal to `[:rate_limited, :provider_unavailable, :timeout, :network_error]` (counterpart `:1748`). No capability step (Assumption 4).
- **Dispatch opts.** `build_*_dispatch_opts/3` **must** apply `Engine.put_cursor_key/2` to the merged `adapter_opts` (counterpart `:1850-1866`; without it the Fakes' cursor is shared across content-equal engines silently). No `:retry_policy` key. `stream` dropped.
- **Per-attempt closure** with the invariant-1 `raise ArgumentError` naming the adapter (counterpart `dispatch_moderate_attempt/3`, `:1882-1900`).
- **`fill_*_request_id/2`** (counterpart `:1902-1908`).
- **Retry nesting.** The speech adapters run their own `Retry.run/3` (as `openai/moderation.ex:812-816` does), so a reason retryable at both layers costs up to 9 synthesis attempts. The transcription adapters do not retry at all (see **Default timeouts** below), so `transcribe/3` uploads at most 3 times. Both numbers go in each façade's `## Retry` `@doc`, per 22.3.4's binding.

**Telemetry:**

| Span | `:start` metadata | `:stop` measurements (ok / error) | `:stop` metadata |
|------|-------------------|-----------------------------------|------------------|
| `[:allm, :synthesize, …]` | `request_id`, `engine`, `model`, `input_length` | `audio_bytes`: `byte_size` / `0` | `usage`, `response`, `error` |
| `[:allm, :transcribe, …]` | `request_id`, `engine`, `model`, `audio_mime` | `text_length`: `String.length(text)` / `0` | `usage`, `response`, `error` |

`input_length` is computed by a two-clause private tolerant of a non-binary `:input`, because `:start` metadata is built before validation (the hazard `moderation_input_count/1` handles, `lib/allm.ex:1797-1800`). `audio_mime` reads `request.audio.mime_type` through the same kind of tolerant private (`nil` for a non-`%Audio{}`). **`:stop` metadata for `:synthesize` carries the response struct, which holds the audio bytes.** A telemetry handler that logs `metadata.response` with `inspect/1` will print them. The `@moduledoc ALLM.Telemetry` row says so.

### Wire-field map — OpenAI

Auth: `Authorization: Bearer` via `OpenAIHeaders` (`json_headers/2` for TTS, `multipart_headers/2` for STT). Key atom `:openai`, fetched after the gates. **CONFIRMED** means observed in the 2026-09-24 design-time probe (curl, transcripts in RECORDS on first need) and re-asserted by the 25.4 recorder. **inferred** means the recorder must settle it.

| Concern | Wire | Status |
|---------|------|--------|
| TTS endpoint | `POST /v1/audio/speech`, JSON body | CONFIRMED |
| TTS body | `{"model","input","voice", "response_format"?, "instructions"?, "speed"?}` | CONFIRMED (API reference) |
| TTS `model` omitted | 400 *"you must provide a model parameter"* → adapter fills `@default_model "gpt-4o-mini-tts"` | CONFIRMED |
| TTS `voice` omitted | required per API reference → adapter defaults `"alloy"` | CONFIRMED (reference); `alloy` 200 on `tts-1` probed |
| TTS 200 body | raw audio bytes; `content-type: audio/{mpeg,wav,pcm,opus,aac,flac}` per format | CONFIRMED, all six |
| TTS default format | `mp3` (`audio/mpeg`) | CONFIRMED |
| TTS usage | none in the non-streaming response | CONFIRMED (binary body, no usage headers) |
| TTS `instructions` on `tts-1` | **accepted silently (200)** despite *"Does not work with `tts-1`"* | CONFIRMED. Forwarded, not gated. The adapter cannot know which models honour it |
| TTS input limit | 4096; 4097 → 400 `string_too_long` | CONFIRMED |
| TTS limit unit | **code points** (neither graphemes nor bytes) | **CONFIRMED 2026-09-24** by the 25.4 probe: 2049 × `e`+U+0301 (4098 code points) → 400 `string_too_long`; 4096 × U+00E9 (8192 bytes) → 200 |
| Unknown top-level field | **accepted (200)**, both endpoints | CONFIRMED (Decision #12) |
| Bad voice / bad format / speed 5 / `""` input | 400 `invalid_request_error` | CONFIRMED |
| Bad model | **404** `code: "model_not_found"` → `:invalid_request` | CONFIRMED |
| 401 | **`content-type: text/plain`** with a JSON body; message echoes a masked key (`sk-proj-****…7890`) | CONFIRMED. Req will not JSON-decode it, so the new adapters' `decode_error_body/1` must `Jason.decode/1` a binary body and fall back to `%{}` on failure. That differs from `openai/moderation.ex:987-988`, which returns `%{}` for every binary and so would drop the 401 message before the redactor sees it; that gap is a `[CARRY]` for 25.7. The wire test stubs the 401 with `put_resp_content_type("text/plain")` + `send_resp`, not `Req.Test.json/2` |
| Correlation header | `x-request-id` | CONFIRMED on both endpoints |
| STT endpoint | `POST /v1/audio/transcriptions`, multipart `file`, `model`, `language`?, `prompt`?, `response_format=json` | CONFIRMED |
| STT response | `{"text", "usage": {"type":"duration","seconds"} \| {"type":"tokens",…}, "languages"?: [{"code"}]}` | CONFIRMED (whisper-1, gpt-4o-mini-transcribe, gpt-transcribe) |
| STT default model | `@default_model "gpt-transcribe"`, which the guide recommends | CONFIRMED 200 |
| STT `language` on `gpt-transcribe` | singular `language=en` → 200 (guide says `languages` plural) | CONFIRMED (both forms 200). The adapter sends singular because it works on every model probed |
| STT size limit | **25 MiB (26,214,400 bytes) on the whole multipart body** | **CONFIRMED 2026-09-24** by the 25.4 ladder: file parts of 24,934,464 and 26,148,864 bytes → 200; 26,214,401 → 413 *"Maximum content size limit (26214400) exceeded (26214850 bytes read)"*. `max_audio_bytes/0` = **26,148,864** (`25 * 1024 * 1024 - 64 * 1024`), the largest accepted rung |
| STT duration limit | **none found**: an 1800 s clip → 200 on `gpt-transcribe` | **CONFIRMED 2026-09-24** (25.4 probe; 8 kHz 8-bit WAV silence, since no ffmpeg was available for the planned mp3). `@doc transcribe/2` says no duration cap was found. No local gate |
| Over-size status | **413** (body `type: "server_error"`, `code: null`) → `:invalid_request`, classified by status | **CONFIRMED 2026-09-24**; recorded at `transcriptions/recorded/error_413.json` |
| STT accepted formats | flac m4a mp3 mp4 mpeg mpga oga ogg wav webm | CONFIRMED (400 error text for junk bytes) |
| STT mime gate | **filename gate**: a non-file source whose mime is `nil` or outside the adapter's mime→extension table → `:invalid_request` (`metadata.mime_type`), after the size gate and before `Keys.fetch!/2`. A `{:file, path}` source is sent under its basename and not gated | **CONFIRMED 2026-09-24**: valid mp3 bytes named `audio.bin` → 400 `unsupported_value` *"Unsupported file format bin"*, so the provider trusts the filename extension. Per this row's own outcome rule, `audio.bin` is replaced by the gate (an unknown mime would also have been named `audio.bin`, so it is gated too) |

> CORRECTED 2026-09-24: the five rows above that were **inferred** (TTS limit unit, STT size limit, STT duration limit, over-size status, STT mime gate) were settled by the 25.4 live probe (`scripts/record_openai_audio_fixtures.exs`) and are rewritten in place as observed. The 401 row re-observed: `text/plain`, masked echo `sk-proj-*****************************9900` of the probe's own fake key (`recorded/error_401_bad_key.json` on both endpoints). The "STT accepted formats" row's list comes from the design-time probe; the 25.4 junk-bytes arm sent `junk.mp3` and got *"Audio file might be corrupted or unsupported"* instead, so the list was not re-observed. Full transcript in RECORDS §25.4.

### Wire-field map — Gemini

Endpoint `POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent`, headers `GeminiHeaders.headers/1` (`x-goog-api-key`), key atom `:gemini`.

| Concern | Wire | Status |
|---------|------|--------|
| Correlation header | neither `x-request-id` nor `x-goog-request-id` returned; body `responseId` → `response.id` | CONFIRMED for those two names only (the 25.5 recorder kept only named headers; a full header-name record awaits the next re-record) |
| Unknown field | **400** `Unknown name` | CONFIRMED (Decision #12) |
| Bad key | **400** `API_KEY_INVALID` (not 401) | CONFIRMED. The new adapters map `details[].reason == "API_KEY_INVALID"` → `:authentication_failed`. **This is safer than the released siblings:** `lib/allm/providers/gemini.ex:109` maps every unmarked 400 `INVALID_ARGUMENT` to `:invalid_request`, and `grep -rn API_KEY_INVALID lib/` is empty at `34e3024`, so a bad Gemini key is `:invalid_request` in chat, images and embeddings today. The new rule is a `[CARRY]` against those three (25.7) |
| STT body | `parts: [{"text": @transcription_instruction ⧺ hints}, {"inlineData": {"mimeType", "data": base64}}]`. camelCase, matching the chat adapter (`lib/allm/providers/gemini.ex:756-761`); the design-time probe used snake_case, which the API also accepts | CONFIRMED (mp3) |
| STT default model | `@default_model "gemini-flash-latest"` | CONFIRMED 200 |
| STT response | text in `candidates[0].content.parts[].text`; `thoughtsTokenCount` in usage | CONFIRMED |
| STT over-long audio | 400 `INVALID_ARGUMENT` containing `exceeds the maximum number of tokens` → `:context_length_exceeded` | the chat adapter's rule, `lib/allm/providers/gemini.ex:110`. **Inferred, and not reachable with inline audio:** at ~32 audio tokens/s (UNVERIFIED rate), 20 MB of audio is far below a 1M-token window. Pinned by a synthesized fixture only; no probe arm |
| STT inline limit | 20 MB **request** (Gemini docs), which the base64-encoded audio counts against → `max_audio_bytes/0 == div((20 * 1024 * 1024 - 64 * 1024) * 3, 4)` = **15,679,488** raw bytes | **CONFIRMED conservative 2026-09-24** by the 25.5 probe: a WAV at the cap → 200, and a 15,831,040-byte WAV (≈21.1 MB base64, over 20 MiB) → **200** too. The documented 20 MB is not enforced at that size; the cap is kept unchanged (design's outcome rule) and a `[CARRY]` is in RECORDS §25.5 |
| STT accepted mimes | `audio/wav, audio/mpeg, audio/aiff, audio/aac, audio/ogg, audio/opus, audio/flac`, matched after `Audio.normalize_mime/1` and sent in that normalised form | **CONFIRMED 2026-09-24** by the 25.5 probe for `audio/mpeg`, `audio/wav`, `audio/flac`, `audio/aac`, and the Ogg-encapsulated `.opus` clip sent as **both** `audio/opus` and `audio/ogg` (each 200, exact text) → `audio/opus` joins the set and there is **no alias table**. `audio/aiff` stays from the docs (no source clip, not probed); `audio/webm` not probed and stays rejected. `nil` mime → `:invalid_request` |
| Key redaction | `AIza…` / `ya29.…` pattern, verbatim from `lib/allm/providers/gemini/embeddings.ex:891-897` | same provider, correct to inherit; companion test asserts the OpenAI pattern matches nothing in the Gemini fixture |

> CORRECTED 2026-09-24: the two **inferred** rows above (STT inline limit, STT accepted mimes) were settled by the 25.5 live probe (`scripts/record_gemini_audio_fixtures.exs`) and are rewritten in place as observed. Re-observed on the same run: unknown field → 400 `Unknown name "notARealField"` (`recorded/error_400_unknown_field.json`); bad key → 400 `INVALID_ARGUMENT` with `details[].reason == "API_KEY_INVALID"` and **no key echo** (`recorded/error_400_bad_key.json`); neither `x-request-id` nor `x-goog-request-id` came back (the recorder kept only those two names plus `content-type`, so no other header was observed either way); the default model `gemini-flash-latest` answered as `modelVersion: "gemini-3.8-flash"`; the answer part carries a `thoughtSignature`. New observation, not in the design: eight minutes of digital silence produced a fluent **invented** transcript, not `""`. The STT-over-long-audio row stays inferred (synthesized fixture only). Full transcript in RECORDS §25.5.

### Deferred: Gemini TTS (probed 2026-09-24, not built)

Kept so the later phase starts from observations, not docs. Endpoint and headers are as above; body `{"contents":[{"parts":[{"text": input}]}], "generationConfig":{"responseModalities":["AUDIO"], "speechConfig":{"voiceConfig":{"prebuiltVoiceConfig":{"voiceName": "Kore"}}}}}`. TTS models listed: `gemini-3.8-flash-tts`, `gemini-3.8-flash-lite-tts`, `gemini-3.1-flash-tts-preview`, `gemini-2.5-{flash,pro}-preview-tts`. Findings:
- Output is `inlineData{mimeType: "audio/wav"}` (RIFF) on three models, with `usageMetadata` token counts. There is no format choice: `responseMimeType: "audio/mp3"` → 400.
- `systemInstruction` → 400 *"Developer instruction is not enabled for this model"*. Style goes into the spoken text, so `instructions` / `speed` would be `:unsupported_feature`, which the speech enum would gain then.
- A non-TTS model with `responseModalities: ["AUDIO"]` → **200 with a text part**, which must be decoded as an error.
- `gemini-2.5-flash-preview-tts` rejects the bare text `"Hello."` with 400 *"Model tried to generate text…"*.
- A bad voice → 400 `INVALID_ARGUMENT`.

### Provider adapters — script contract

Each real adapter's public entry points **hand off to its Fake before running any of their own gates** when a script is present. This is the `openai/moderation.ex:351-356` shape: `case fetch_moderation_script(opts) do nil -> do_moderate(request, opts); _script -> FakeModeration.moderate(request, opts) end`.

| Capability | Script key | Fetcher | Hand-off target |
|------------|-----------|---------|-----------------|
| speech | `adapter_opts[:speech_script]` | `fetch_speech_script/1` | `FakeSpeech.synthesize/2` |
| transcription | `adapter_opts[:transcription_script]` | `fetch_transcription_script/1` | `FakeTranscription.transcribe/2` |

With a script present, `prepare_request/2` returns `{:error, stub_error(opts)}` (counterpart `openai/moderation.ex:382-393`). Consequences: (a) a scripted run exercises the **Fake's** gates, but the transcription hand-off passes the real adapter's cap as `adapter_opts[:max_audio_bytes]` (below), so a user scripting `OpenAI.Transcription` with a real multi-KB clip is not rejected by the Fake's 1024-byte default; (b) a scripted run never reaches the real adapter's decoder.

### Provider adapters — seams

All three adapters follow `openai/moderation.ex`'s layout. Script short-circuit first (the contract above), then `run_gates/2`, `Keys.fetch!/2`, `Req`, `Retry.run/3` (`:808-817`), `run_one_attempt/3` (`:944-975`). Plus per-adapter `redact_key_material/1` + `sanitize_cause/1`, **no `body_preview`**, `maybe_apply_req_test_stub/2` via `adapter_opts[:plug]`, and the family test-seam naming banner. Public `@doc false` seams with `@spec`:

| Adapter | Seams |
|---------|-------|
| `OpenAI.Speech` | `to_json_body/2` → `map()`; `decode_response/4` `(body, headers, request, opts)`; `to_speech_adapter_error/4` `(status, body, headers, opts)`; `gate_input_length/2` |
| `OpenAI.Transcription` | `to_multipart_body/2` → `{:ok, [field]} \| {:error, _}` (fails on unresolvable audio, so it returns a tuple: capability family `openai/images.ex:744`); `decode_response/4`; `to_transcription_adapter_error/4`; `gate_audio/2` |
| `Gemini.Transcription` | `to_json_body/2` → `{:ok, map()} \| {:error, _}` (base64 of an unresolvable file fails); `decode_response/4`; `to_transcription_adapter_error/4`; `gate_audio/2` |

**Default timeouts.** `Req`'s `receive_timeout` default (15 s) is too short for a 25 MB upload or a 4096-character synthesis. Every adapter applies a default when `opts[:request_timeout]` is absent: **60 s** for TTS and **120 s** for STT. The value goes in the public `@doc` of `synthesize/2` / `transcribe/2` (CLAUDE.md's injected-default rule). **Retry arithmetic for STT:** every retryable reason (`:rate_limited`, `:provider_unavailable`, `:timeout`, `:network_error`) is retryable at both adapter and façade, so nested loops would upload a 25 MB file up to 9 times. The transcription adapters therefore **do not retry**: `run_one_attempt/3` returns every classified error as `{:error, _}` (never `{:retry, …}`) and there is no adapter-level `Retry.run/3`. The façade's 3-attempt loop is the only STT retry, capping an upload at 3 attempts. Direct Layer-B callers who want retries wrap the call themselves; `transcribe/2`'s `@doc` says so and `transcribe/3`'s `## Retry` states 3. The speech adapters keep the moderation shape (adapter `Retry.run/3`, up to 9 attempts), because a TTS request body is at most 4096 characters.

Return-shape adjudication (CLAUDE.md): capability family wins by default. The two STT body builders return tuples because building them requires resolving audio bytes, which can fail. That is the forcing invariant, and it is named in each `@doc false`.

### Layer B — Fakes

**`FakeSpeech`** script entries: `{:ok, binary()}` (bytes, `mime_type` from `format_to_mime(request.format || :mp3)`), `{:ok, SpeechResponse.t()}` (verbatim), `{:error, SpeechAdapterError.t()}`, `{:retry_until_call, pos_integer()}`. **No script:** bytes are the deterministic `"FAKE-AUDIO:" <> input`, with `format: request.format || :mp3` and the mime from `SpeechResponse.format_to_mime/1`. **Empty input gate fires before the script** (invariant 4). An exhausted non-empty script → `:unknown` with `metadata.cause: :speech_script_exhausted` (the Phase 22.2 F4 split). Cursor: the three-source contract (`adapter_opts[:script_cursor]` Agent → `adapter_opts[:cursor_key]` → `:erlang.phash2(script)`), moduledoc copied from `lib/allm/providers/fake_moderation.ex:85-97`.

**`FakeTranscription`** entries: `{:ok, String.t()}` (the text), `{:ok, TranscriptionResponse.t()}`, `{:error, _}`, `{:retry_until_call, n}`. **No script:** `text: ""`, `usage: %Usage{}`. `max_audio_bytes/0` returns `1024`: small, so conformance case 4 crosses it cheaply. The size gate measures against `adapter_opts[:max_audio_bytes] || max_audio_bytes()`; real adapters set that key on hand-off to their own `max_audio_bytes()`. Gates fire before the script.

### Layer B — conformance suites

`conformance/` is a second Mix project. Each suite copies `conformance/lib/allm/test/moderation_adapter_conformance.ex`: `@case_count`, `case_count/0`, `using/1`, no `ALLM.*` references outside the `quote`, a `## What this suite does NOT bind` section (invariant 1 is bound by the façade tests, and script-short-circuiting adapters never reach their decoders), and **no case body gated on an optional fixture** (rule 26).

**Each suite moduledoc carries a `## Script contract` section** naming its script key and hand-off rule, and tags every case **[scripted]** (the case passes `adapter_opts[:<cap>_script]` with a one-entry script, so real adapters never touch the network) or **[unscripted]** (no script, keyless: only gates are reached). `## What this suite does NOT bind` states that for script-short-circuiting adapters, speech invariants 2–3 and transcription invariant 2 are bound by each adapter's `decode_response/4` fixture tests, not by this suite.

**Keyless means keyless even in a keyed shell.** Each suite's `using/1` accepts `:gate_opts` (keyword, default `[]`), deep-merged into the opts of every [unscripted] case. The main-repo invocations for real adapters pass `gate_opts: [adapter_opts: [plug: fn _conn -> raise "gate let the request reach HTTP" end]]`, so a gate placed after key resolution fails the case even when `OPENAI_API_KEY` is exported. Otherwise speech case 4 would pass on the provider's own 400, and transcription case 4 would upload 25 MB. `## Script contract` documents the option.

`ALLM.Test.SpeechAdapterConformance`, **`@case_count 6`**. Each case below names what differs when it breaks:
1. [scripted] `"Hello."` → `{:ok, resp}` whose audio source is `{:binary, b}` with `b != ""`. Falsifier: a nil or empty audio.
2. [scripted] `resp.audio.mime_type` is a binary. Falsifier: `nil`.
3. [scripted] `resp.format in [nil | SpeechRequest.formats()]` (invariant 3). Falsifier: an off-enum atom.
4. [unscripted] `input: ""` → `:invalid_request` with **no key in the environment** (invariant 4). Falsifier: `%EngineError{reason: :missing_key}` instead.
5. [scripted] `opts[:request_id]` lands on the response (invariant 5).
6. [scripted] `metadata: %{"k" => "v"}` round-trips (invariant 6).

`ALLM.Test.TranscriptionAdapterConformance`, **`@case_count 6`**:
1. [unscripted] `max_audio_bytes/0` is a `pos_integer()`.
2. [scripted] a **≤ 512-byte** `Audio.from_binary(bytes, "audio/mpeg")` → `{:ok, resp}` with a binary `text` and `%Usage{}` usage. The size bound keeps the case under `FakeTranscription`'s 1024-byte cap, which the hand-off runs.
3. [unscripted] `Audio.from_file("/nonexistent.mp3")` → `:invalid_request` keyless (invariant 3).
4. [unscripted] `max_audio_bytes() + 1` bytes, `audio/mpeg` → `:invalid_request` with `metadata.count` and `metadata.max`, keyless (invariant 4). **Sized from the callback, never a literal.**
5. [scripted] `request_id` round-trip.
6. [scripted] `metadata` round-trip.

Companion files per suite (the moderation trio): `conformance/test/support/fixtures/scripted_{speech,transcription}_stub.ex` (gates ahead of script), `conformance/test/allm/test/{speech,transcription}_adapter_conformance_test.exs` (four meta-invariants: `case_count/0` value, injected-describe test count, `using/1` `KeyError` without the adapter opt, and `:gate_opts` reaching an unscripted case — a stub adapter that fails when a `:plug` is absent), and one main-repo invocation per real adapter.

---

## Module Tree

```
lib/allm/
├── audio.ex                                   (NEW — 25.1)
├── speech_request.ex                          (NEW — 25.1)
├── speech_response.ex                         (NEW — 25.1)
├── transcription_request.ex                   (NEW — 25.1)
├── transcription_response.ex                  (NEW — 25.1)
├── speech_adapter.ex                          (NEW — 25.2)
├── transcription_adapter.ex                   (NEW — 25.2)
├── error/
│   ├── speech_adapter_error.ex                (NEW — 25.1)
│   ├── transcription_adapter_error.ex         (NEW — 25.1)
│   ├── engine_error.ex                        (MODIFY — 25.1, +2 reasons, both lists)
│   └── validation_error.ex                    (MODIFY — 25.1, +2 reasons, both lists)
├── serializer.ex                              (MODIFY — 25.1, +7 @known_modules)
├── validate.ex                                (MODIFY — 25.1, +2 validators + rule blocks)
├── engine.ex                                  (MODIFY — 25.2, four fields at every site in the Engine-extension table)
├── telemetry.ex                               (MODIFY — 25.3, +2 span names + moduledoc rows)
└── providers/
    ├── fake_speech.ex                         (NEW — 25.2)
    ├── fake_transcription.ex                  (NEW — 25.2)
    ├── openai/speech.ex                       (NEW — 25.4)
    ├── openai/transcription.ex                (NEW — 25.4)
    └── gemini/transcription.ex                (NEW — 25.5)

lib/allm.ex                                    (MODIFY — 25.3, 4 public fns + internals + "When to reach for what" rows)

conformance/lib/allm/test/
├── speech_adapter_conformance.ex              (NEW — 25.2)
└── transcription_adapter_conformance.ex       (NEW — 25.2)
conformance/test/support/fixtures/
├── scripted_speech_stub.ex                    (NEW — 25.2)
└── scripted_transcription_stub.ex             (NEW — 25.2)
conformance/test/allm/test/
├── speech_adapter_conformance_test.exs        (NEW — 25.2)
└── transcription_adapter_conformance_test.exs (NEW — 25.2)

test/allm/
├── audio_test.exs                             (NEW — 25.1)
├── speech_request_test.exs                    (NEW — 25.1)
├── speech_response_test.exs                   (NEW — 25.1)
├── transcription_request_test.exs             (NEW — 25.1)
├── transcription_response_test.exs            (NEW — 25.1)
├── error/speech_adapter_error_test.exs        (NEW — 25.1)
├── error/transcription_adapter_error_test.exs (NEW — 25.1)
├── validate_speech_request_test.exs           (NEW — 25.1)
├── validate_transcription_request_test.exs    (NEW — 25.1)
├── speech_adapter_test.exs                    (NEW — 25.2, FakeSpeech conformance + behaviour surface)
├── transcription_adapter_test.exs             (NEW — 25.2, FakeTranscription conformance + surface)
├── engine_test.exs                            (MODIFY — 25.2, both fields accept/reject/round-trip/deny-list)
├── allm_synthesize_test.exs                   (NEW — 25.3)
├── allm_transcribe_test.exs                   (NEW — 25.3)
└── providers/
    ├── fake_speech_test.exs                   (NEW — 25.2)
    ├── fake_transcription_test.exs            (NEW — 25.2)
    ├── openai/speech_test.exs                 (NEW — 25.4, seams)
    ├── openai/speech_wire_test.exs            (NEW — 25.4, Req.Test + provenance)
    ├── openai/speech_conformance_test.exs     (NEW — 25.4)
    ├── openai/transcription_test.exs          (NEW — 25.4)
    ├── openai/transcription_wire_test.exs     (NEW — 25.4)
    ├── openai/transcription_conformance_test.exs (NEW — 25.4)
    ├── gemini/transcription_test.exs          (NEW — 25.5)
    ├── gemini/transcription_wire_test.exs     (NEW — 25.5)
    └── gemini/transcription_conformance_test.exs (NEW — 25.5)

test/support/
├── fake_audio_fixtures.ex                     (NEW — 25.2, engine + script builders for both Fakes)
├── openai_fixtures.ex                         (MODIFY — 25.4, speech_*/transcription_* loaders delegating to drop_comment/1)
└── gemini_fixtures.ex                         (MODIFY — 25.5, same)

test/fixtures/audio/quick_brown_fox.{mp3,wav,flac,aac,opus} (NEW — 25.4, recorder-written STT input clips; binary INPUT assets, not wire bodies)
examples/fixtures/quick_brown_fox.mp3          (NEW — 25.4, recorder copy for example 24; `kestrel_256.png` precedent)
test/fixtures/openai/speech/{recorded,synthesized}/*.json         (NEW — 25.4)
test/fixtures/openai/transcriptions/{recorded,synthesized}/*.json (NEW — 25.4)
test/fixtures/gemini/transcriptions/{recorded,synthesized}/*.json (NEW — 25.5)
test/fixtures/openai/README.md                  (MODIFY — 25.4, speech + transcriptions sections)

scripts/
├── record_openai_audio_fixtures.exs           (NEW — 25.4)
└── record_gemini_audio_fixtures.exs           (NEW — 25.5)

test/
├── layer_a_docs_test.exs                      (MODIFY — 25.1, +5 @layer_a entries)
├── allm_facade_doctest_inventory_test.exs     (MODIFY — 25.3, +4 @public_facade entries)
├── guides_test.exs                            (MODIFY — 25.6, +audio.md)
└── guides_doctest_test.exs                    (MODIFY — 25.6, +doctest_file line)

guides/audio.md                                 (NEW — 25.6)
examples/23_synthesize_speech.exs              (NEW — 25.6, `# Provider: openai`)
examples/24_transcribe_audio.exs               (NEW — 25.6, `# Provider: openai, gemini`)
examples/_helpers.exs                          (MODIFY — 25.6, speech/transcription keys + two engine builders)
examples/README.md                             (MODIFY — 25.6)
mix.exs                                        (MODIFY — 25.1/25.2/25.4/25.5/25.6, gate table)
CHANGELOG.md                                   (MODIFY — 25.6)
steering/allm_engine_session_streaming_spec_v0_2.md (MODIFY — 25.6)
steering/PHASE_19_DESIGN.md                    (MODIFY — 25.7, superseded banner)
```

**Recorded fixtures for binary bodies.** OpenAI TTS returns raw audio, not JSON. The fixture convention is `.json` (CLAUDE.md), and the provenance test reads raw JSON. So each `recorded/` TTS fixture is a JSON envelope: `{"status", "headers": {"content-type", "x-request-id"}, "body_base64", "byte_size", "sha256"}`. Tests stub `Req.Test` with the decoded bytes and the recorded `content-type`. Gemini TTS bodies are JSON already, and the recorder uses a ≤5-word input to keep them near 50–80 KB (probed: `"Hello there."` → 77 KB base64).

### Repo-wide audit-gate obligations

| Gate | Fails | Fires in | Row |
|------|-------|----------|-----|
| `test/groups_for_modules_audit_test.exs` | closed, bidirectional | 25.1, 25.2, 25.4, 25.5 | `mix.exs` `groups_for_modules`: 5 structs → `"Data types"`; 2 errors → `Errors`; 2 behaviours → `Behaviours` (`mix.exs:112-120`); 2 Fakes + 3 adapters → `Providers` (`:121-141`). Register each module in the sub-phase that creates it, never earlier |
| `test/layer_a_docs_test.exs` | **open** | 25.1 | `@layer_a` (`:14`), +5 structs (`Audio`, 2 requests, 2 responses) |
| `test/allm_facade_doctest_inventory_test.exs` | **open** (one-directional) | 25.3 | `@public_facade` (`:16`), +`speech_request: 2`, `synthesize: 3`, `transcription_request: 2`, `transcribe: 3` |
| `test/package_files_extras_consistency_test.exs` | closed | 25.6 | `mix.exs` `@guides` (`:65-77`) |
| `test/guides_test.exs` + `test/guides_doctest_test.exs` | open, but parity-meta-tested since 22.7 (`guides_test.exs:125`) | 25.6 | `@guides` (`:23`) + `doctest_file/1` |

### Path-existence sanity check

```bash
ls -d lib/allm/error lib/allm/providers/openai lib/allm/providers/gemini \
      conformance/lib/allm/test conformance/test/support/fixtures conformance/test/allm/test \
      test/allm/error test/allm/providers/openai test/allm/providers/gemini \
      test/support test/fixtures/openai test/fixtures/gemini scripts guides examples
```

Run 2026-09-24 at `34e3024`: all exist (`ls lib/allm/providers/gemini` → `decode.ex embeddings.ex images.ex`; `ls test/fixtures/gemini` → `embeddings generate_content synthesized`). New directories: `test/fixtures/audio/`, `test/fixtures/{openai,gemini}/{speech,transcriptions}/{recorded,synthesized}/`.

---

## Phases

**`README.md` is out of tree for all seven sub-phases.** At 25.1 start: `git stash push -- README.md` if it is dirty.

Every sub-phase's Verification includes the uniform block (rule 31):

```bash
mix test && mix test --seed 0
mix format --check-formatted && mix credo --strict && mix dialyzer
mix run scripts/audit_user_docs.exs <each NEW lib/ or guides/ file of this sub-phase>   # must report 0 hits per file
# (the bare script exits 1 on a pre-existing baseline, and a keyword filter misses lines without the keyword)
grep -rl 'Keys.put(\|Logger.configure(\|System.put_env(\|:telemetry.attach' test/  # async: false modules only
```

and, when the sub-phase touches `conformance/`: `cd conformance && mix test && mix credo --strict && mix format --check-formatted`.

### Phase 25.1 — Layer A data (Layer A)

**Goal:** Seven serializable modules, two validators, and the enum and registry edits. No adapter, no engine field, no façade.

#### 25.1.1 Test Plan (write first)

`audio_test.exs`:
- `from_file/1 does not touch the filesystem` (a nonexistent path builds fine) and infers the mime for each `@ext_to_mime` row. Falsifier: a `File.read` raise, or a `nil` mime on a listed extension.
- `from_file("x.xyz").mime_type == nil`
- `to_binary/1` on `{:file, missing}` → `{:error, :enoent}`; on bad base64 → `{:error, :invalid_base64}`
- `size/1` on each source variant equals `Kernel.byte_size/1` of the bytes (computed separately via `File.read!/1`, not from `to_binary/1`); `%Audio{source: {:url, "x"}}` → `{:error, :invalid_source}`
- `struct!(ALLM.Audio, [])` raises `ArgumentError`
- `inspect(Audio.from_binary(:binary.copy(<<0>>, 10_000), "audio/wav"))` is under 200 bytes and contains `10000 bytes` (falsifier: the default struct inspect printing the payload)
- **JSON round-trip of `{:binary, <<0, 255, 1>>}` returns the same bytes**, and the encoded JSON contains `Base.encode64(<<0, 255, 1>>)` (the falsifier for a missing base64 pre-pass is `Jason.EncodeError` on invalid UTF-8)
- a JSON payload with `"source": {"type": "binary", "value": "%%%"}` → `Serializer.from_json/1` error whose field errors include `{[:source], :invalid_base64}`

`speech_request_test.exs` / `transcription_request_test.exs`:
- defaults; unknown key → `KeyError`; `input: ""` / `audio: nil` constructible
- `SpeechRequest.formats() == [:mp3, :opus, :aac, :flac, :wav, :pcm]`
- ETF + JSON round-trip with every field non-default, including `format: :opus` (still an atom after JSON) and a `%Audio{}` in `TranscriptionRequest.audio` (a struct, not a map, after JSON)

`speech_response_test.exs` / `transcription_response_test.exs`:
- `format_to_mime/1`: one row per format; `mime_to_format(format_to_mime(f)) == f` for every `f` in `formats/0`
- `mime_to_format/1`: one row per table entry, plus `"audio/wav; codecs=1"` → `:wav` (parameter strip), `"video/mp4"` → `nil`, `nil` → `nil`
- JSON round-trip with `provider: :openai`, `usage: %Usage{input_tokens: 27}`, `duration_seconds: 2.78`, and `audio` holding non-UTF-8 bytes. Falsifiers: `provider` becomes a string; `usage` becomes a map
- a JSON payload without `"usage"` decodes to `%Usage{}`, not `nil`

`error/*_adapter_error_test.exs` (per error): `legal_reasons/0` has 9 atoms (speech) / 10 (transcription), neither includes `:batch_too_large` or `:unsupported_feature`, and only transcription includes `:content_filter`; off-enum `new/2` → `ArgumentError`; `Exception.message/1` default and raw-struct fallback; round-trip.

`validate_*_test.exs`: one test per vocabulary row. The hard-reject rows assert the error list is **exactly** that one entry, plus one accumulation test per validator.

#### 25.1.2 Implementation Checklist

- [ ] The five structs + `Audio` per the contract blocks (encoder pre-pass and decode hooks as specified)
- [ ] The two error modules, shaped after `moderation_adapter_error.ex`
- [ ] Enum extensions (both lists each) + seven `@known_modules` entries
- [ ] `Validate.speech_request/1`, `transcription_request/1` + rule blocks
- [ ] `@layer_a` +5 (**fail-open**); `groups_for_modules` for the seven modules
- [ ] Doctests on every public function

#### 25.1.3 Verification

`mix test test/allm/audio_test.exs test/allm/speech_*_test.exs test/allm/transcription_*_test.exs test/allm/error/speech_adapter_error_test.exs test/allm/error/transcription_adapter_error_test.exs test/allm/validate_speech_request_test.exs test/allm/validate_transcription_request_test.exs`, plus the uniform block.

**Success criterion:** all new tests green; `test/layer_a_docs_test.exs`'s generated test count rises by exactly 5 (fail-open, so count, don't remove-and-watch); `groups_for_modules_audit_test.exs` green.

#### 25.1.4 Binding on later sub-phases

- `SpeechResponse.mime_to_format/1` and `format_to_mime/1` are the **only** mime↔format tables. Binds 25.2 (`FakeSpeech` uses `format_to_mime/1`), 25.4, and 25.5. An adapter-local table is a review finding.
- `Audio.size/1` is the only byte resolver the STT gates use. Binds 25.4 and 25.5.
- `TranscriptionAdapterError`'s `:context_length_exceeded` is produced by `Gemini.Transcription`'s token-limit arm. Binds 25.5.

### Phase 25.2 — Behaviours, engine fields, Fakes, conformance (Layer B)

#### 25.2.1 Test Plan

- `speech_adapter_test.exs` / `transcription_adapter_test.exs`: the Fake passes its conformance suite; `behaviour_info(:callbacks)` / `(:optional_callbacks)` exact lists; a module implementing only the required callbacks compiles without warning (`capture_io(:stderr, …)` around `Code.compile_string/1`, the `embedding_adapter_test.exs:28-45` pattern).
- `fake_speech_test.exs`: no-script bytes equal `"FAKE-AUDIO:" <> input` for two different inputs (falsifier: constant bytes); `format: :wav` → `mime_type "audio/wav"`; each script entry kind; exhausted script → `:speech_script_exhausted`; empty input rejected before consuming an entry (next call still gets entry 1); `{:retry_until_call, 3}` driven against `synthesize/2` **directly** with explicit `adapter_opts[:cursor_key]` and a leading non-error entry (CLAUDE.md); two engines with distinct `:id`s do not share a cursor.
- `fake_transcription_test.exs`: the same matrix, plus `max_audio_bytes() + 1` → `:invalid_request` with `metadata.count == 1025`, and a missing-file audio → `:invalid_request` with `metadata.cause == :enoent`.
- `engine_test.exs`: per adapter field, accept a module; reject `{Mod, []}` with `ArgumentError`; JSON round-trip; `resolve_params/2` excludes it. Per model field, accept a string; JSON round-trip preserves it; `resolve_params/2` excludes it (falsifier: `speech_model` leaks into chat params).
- Conformance meta-tests (per suite): `case_count/0 == 6`; injected describe defines exactly 6 tests; `using/1` without the adapter opt → `KeyError`; `:gate_opts` reaches every [unscripted] case.
- `fake_transcription_test.exs` also: `adapter_opts: [max_audio_bytes: 4096]` lets a 2048-byte clip through (falsifier: the gate ignoring the override).

#### 25.2.2 Implementation Checklist

- [ ] Both behaviours: callbacks, numbered invariants, `## Minimum impl skeleton`, "Cleanup invariant: none."
- [ ] `Engine`: all four fields at every site in the Engine-extension table
- [ ] `FakeSpeech`, `FakeTranscription`, `test/support/fake_audio_fixtures.ex`
- [ ] Two conformance suites + stubs + meta-tests (no fixture-gated case bodies)
- [ ] `groups_for_modules` (behaviours + Fakes)

#### 25.2.3 Verification

Targeted files + uniform block + the `conformance/` block.

**Success criterion:** both Fakes pass all 6 cases of their suite; both Mix projects green on all gates.

#### 25.2.4 Binding on later sub-phases

- Gates (empty input / over-length input / unresolvable / oversized / mime) run **ahead of `Keys.fetch!/2`**. Binds 25.4 and 25.5. Their conformance invocations run keyless: `speech_conformance_test.exs` etc. must not set a key, and `Keys.put/2` is banned from `async: true` modules anyway.
- `build_*_dispatch_opts/3` must call `Engine.put_cursor_key/2`. Binds 25.3.
- Case 4 of the transcription suite sizes from `max_audio_bytes/0`. Binds 25.4 and 25.5: a real adapter's case 4 allocates 20–25 MB once per run. Acceptable (measured precedent: none. Record the run time in RECORDS; if > 2 s, tag the invocation `@tag :slow` rather than weakening the case).

### Phase 25.3 — Façades and spans (Layer C)

#### 25.3.1 Test Plan

`allm_synthesize_test.exs` and `allm_transcribe_test.exs`, over the Fakes. Rows are identical per façade unless noted:

*Input shapes:* binary (synthesize) / `%Audio{}` (transcribe) is wrapped; a request struct dispatches verbatim (except the Decision #10 fill of a nil `model`) and is **not** merged with opts (falsifier: an opt-supplied `:voice` appears on the dispatched request).
*Gate order:* nil adapter → `:no_speech_adapter` / `:no_transcription_adapter`; nil adapter **plus** an invalid request still yields the adapter error; an invalid request → `:invalid_speech_request` / `:invalid_transcription_request`; `:start` fires in both cases; `:start` with a non-binary `input` / non-`%Audio{}` `audio` does not raise.
*Opts:* each allow-list key lifts onto the request; the symmetry test against `Map.keys(%Struct{}) -- [:__struct__, <positional>]`; request-field opts are not forwarded; unknown opts are; `stream: true` dropped; `request_id` precedence (opt wins over generated; adapter-set preserved).
*Model resolution (Decision #10):* `engine.speech_model` fills a nil `request.model`; a set `request.model` wins; **an engine with `model: "chat-x"` and `speech_model: nil` dispatches `request.model == nil`** (falsifier: `"chat-x"` reaches the adapter); `opts[:model]` on the string shape lands on the request; the `:start` metadata `model` equals the resolved slot model, or `nil`. Same rows for transcription.
*Retry:* `:rate_limited` retries then succeeds; `:invalid_request` does not retry; a bare-map return raises `ArgumentError` naming the adapter and "invariant 1".
*Telemetry* (via `test/support/telemetry_capture.ex`): `audio_bytes` / `text_length` equal the Fake's known output size on ok and `0` on error; `usage` is present on both paths; `:exception` fires on adapter raise.
*Cursor:* two content-equal engines with distinct ids driven through the façade get independent script cursors (falsifier: the second engine receives entry 2).

#### 25.3.2 Implementation Checklist

- [ ] The four public functions with `@doc` sections (input shapes, gate order, retry nesting, the "no streaming yet" note, telemetry-bytes caution for synthesize) and doctests over the Fakes
- [ ] Internals per the Layer C contract, reusing `augment_retry_policy/2` (no new variant)
- [ ] `Telemetry`: both span names in both lists + moduledoc rows
- [ ] `@public_facade` +4 (**fail-open**); "When to reach for what" rows in `lib/allm.ex`

#### 25.3.3 Verification

Targeted + uniform. **Success criterion:** every gate-order test passes alone and in combination; the symmetry tests compute from `Map.keys/1`.

### Phase 25.4 — OpenAI adapters (Layer B)

#### 25.4.1 Test Plan

`openai/speech_test.exs` (seams, no HTTP):
- `to_json_body/2`: fills `model` from `@default_model` when nil and `voice` `"alloy"` when nil; `format: :pcm` → `"response_format" => "pcm"`; nil `format` / `instructions` / `speed` are **absent** (not `null`); `options` merged **under** structural fields (`options: %{"input" => "x"}` does not replace the input); `options: %{"stream_format" => "sse"}` is dropped
- `decode_response/4` with a non-`audio/*` content-type on a 200 (e.g. `text/event-stream`) → `:malformed_response`
- `decode_response/4` with bytes + `content-type: audio/wav` → `format: :wav`, `audio.mime_type == "audio/wav"`, `raw == nil`, `request_id` from `x-request-id` when the opt is absent
- `to_speech_adapter_error/4`: 401 (binary `text/plain` body), 404 `model_not_found`, 400, 429 with `Retry-After`, 500 map to the reasons in the Error Contract
- `gate_input_length/2`: 4096 code points ok, 4097 → `:context_length_exceeded` with count/max, **keyless**; 2049 × `"e\u0301"` (4098 code points, 2049 graphemes) is **rejected** (the falsifier for a grapheme count, which would pass it); 4096 × precomposed `"\u00e9"` (4096 code points, 8192 bytes) passes (the falsifier for a byte count)
- `to_speech_adapter_error/4` on a 400 whose message contains `string_too_long` → `:context_length_exceeded`

`openai/transcription_test.exs`:
- `options: %{"response_format" => "srt"}` is dropped; the form still carries `response_format=json`
- `to_multipart_body/2` yields `file` as `{bytes, filename: <name>, content_type: <mime or "application/octet-stream">}`: for `{:file, path}` the name is `Path.basename(path)`; otherwise `"audio." <> ext` from the mime (`audio.mp3` for `audio/mpeg`), and `"audio.bin"` when the mime is nil or unknown, `model`, `response_format: "json"`, `language` / `prompt` only when set, `options` as extra fields
  > CORRECTED 2026-09-24: there is no `"audio.bin"` case. The probe showed OpenAI rejects `audio.bin` (400 *"Unsupported file format bin"*), so a non-file source with a nil or unknown mime is rejected by a keyless filename gate instead (wire map, "STT mime gate" row).
- missing-file audio → `{:error, %TranscriptionAdapterError{reason: :invalid_request}}`, keyless
- oversized → `:invalid_request`, count/max, keyless
- `decode_response/4`: duration-shape usage → `duration_seconds: 3`, `usage.input_tokens == nil`; token-shape usage → `usage.input_tokens == 27`, `output_tokens == 12`, `total_tokens == 39`, `duration_seconds == nil`; `languages: [%{"code" => "en"}]` → `language: "en"`; missing `"text"` → `:malformed_response`
- `max_audio_bytes()` equals the moduledoc-stated, probe-settled value
- `to_transcription_adapter_error/4` maps 413 → `:invalid_request`
- a 429 stub through `transcribe/2` is hit **exactly once** (the adapter does not retry; falsifier: a stub call count of 3)
- scripted `transcribe/2` with the 4 KB-plus `quick_brown_fox.mp3` clip returns the scripted text (falsifier: the Fake's 1024-byte default rejecting it on hand-off)
- a 401 stubbed as `text/plain` with a JSON body carrying a planted `sk-` token → `:authentication_failed` whose message and `metadata` contain no `sk-` token (falsifier: `decode_error_body/1` dropping binaries, which leaves the message generic and never exercises the redactor)

**Keyless gate tests pass `adapter_opts[:plug]` with a stub that calls `flunk("gate let the request reach HTTP")`**, so a gate placed after key resolution fails even in a shell with a key exported. This applies to every "keyless" bullet in 25.4 and 25.5.

`*_wire_test.exs`: URL, method, auth header, content-type (`multipart/form-data; boundary=` for STT); each `recorded/` fixture decodes; the redactor replaces the planted `sk-` token in `synthesized/error_401.json`; **the Gemini and Voyage patterns match nothing in the same fixture**; **one raw-bytes negative provenance test per `recorded/` file** (`refute Map.has_key?(raw, "_comment")`) and a positive one per `synthesized/` file.

`*_conformance_test.exs`: the two-liner invocations, passing `gate_opts:` with the raising `:plug` (conformance-suites section), with moduledocs naming what they do not bind.

#### 25.4.2 Live probe — `scripts/record_openai_audio_fixtures.exs`

Four parts (CLAUDE.md): control arm, assert-don't-narrate halt before any write, record bodies including errors, and an overwrite guard. **The control arm expects 200** (Decision #12). Its job is to fail the day OpenAI starts rejecting unknown fields.

**Every arm has a write target, so the overwrite guard covers all of them.** An assert-only arm writes its outcome to `<endpoint>/recorded/probe_<arm>.json` (`{"status", "expected", "error_body"?}`: status plus a trimmed error body, never audio). When every target exists, the recorder prints `0 live calls` and exits 0. Each `probe_*.json` gets the same raw-bytes provenance test as any recorded fixture. Without this, every re-run would re-upload the size ladder and re-bill the 4096-character TTS arms.

| Arm | Asserts | Writes |
|-----|---------|--------|
| control (unknown field) | 200 | `probe_control.json` |
| tts default | 200, `audio/mpeg`, bytes > 0, `x-request-id` | `speech/recorded/mp3_default.json` |
| tts wav / pcm | content-type `audio/wav` / `audio/pcm` | `wav.json`, `pcm.json` |
| tts 2049 × `e+U+0301` (4098 code points, 2049 graphemes) | **400** `string_too_long` if the unit is code points; a 200 means graphemes, and the recorder halts | `probe_unit_graphemes.json` |
| tts 4096 × precomposed `é` (4096 code points, 8192 bytes) | **200** if code points; a 400 means bytes, and the recorder halts | `probe_unit_bytes.json` |
| tts 4097 ASCII | 400 | `error_400_too_long.json` |
| tts bad model | 404, `code: model_not_found` | `error_404_model.json` |
| stt input clips | writes `test/fixtures/audio/quick_brown_fox.{mp3,wav,flac,aac,opus}` from five tts calls (once each, overwrite-guarded) and copies the mp3 to `examples/fixtures/quick_brown_fox.mp3` | the clips |
| stt gpt-transcribe | 200, `text` non-empty, duration usage | `transcriptions/recorded/gpt_transcribe.json` |
| stt gpt-4o-mini-transcribe | 200, token usage | `mini_tokens.json` |
| stt junk bytes | 400 | `error_400_format.json` |
| stt valid mp3 as `audio.bin` | 200 (content sniffing) or 400 (filename trusted), both recorded; settles the nil-mime row | `probe_audio_bin.json` |
| stt size ladder (`whisper-1`, 16 kHz mono silence WAV) | three rungs: `25_000_000 - 64 * 1024`, `25 * 1024 * 1024 - 64 * 1024`, `25 * 1024 * 1024 + 1` file-part bytes. The first must be 200 and the last 400 or 413 (either violation halts with the want/got table); the middle rung settles decimal vs binary MB. `max_audio_bytes/0` is set to the largest accepted rung | `probe_size_ladder.json` (per-rung status) + `error_413.json` or `error_400_size.json` |
| stt duration (`gpt-transcribe`, > 1500 s low-bitrate mono mp3 under the byte cap) | 200 or 400; both are recorded, and a 400 documents the duration limit in `@doc transcribe/2` | `probe_duration.json` |
| bad key (both endpoints) | 401 | `error_401_*.json` |

**Cost (UNVERIFIED pricing, from memory; the implementer quotes the pricing page in RECORDS):** TTS ≈ 4,200 × 2 + ~100 chars at ≈$15–30/1M chars ≈ **$0.25**; STT ≈ 3 short clips at ≈$0.006/min plus two accepted ~25 MB silent WAVs (~13 min each at 16 kHz mono) and one ~25 min duration clip ≈ **$0.35**. Per clean run ≈ **$0.60**; first implementation 2–4× ≈ **$2.00**. A fully recorded tree costs $0.00 (overwrite guard).

#### 25.4.3 Implementation Checklist

- [ ] `openai/speech.ex`, `openai/transcription.ex`: gate order `empty/length (TTS) | resolvable/size (STT) → Keys.fetch!(:openai) → Req → decode`
- [ ] Redactor verbatim from `openai/moderation.ex:1031`; `sanitize_cause/1`; no `body_preview`
- [ ] Recorder + fixtures + loaders in `openai_fixtures.ex` delegating to the existing `drop_comment/1`
- [ ] Update the wire map rows the probe settles, in the same commit
- [ ] `groups_for_modules`; `test/fixtures/openai/README.md` sections

#### 25.4.4 Verification

Targeted + uniform + conformance block + **BLOCKING** `( set -a; . ./.env; set +a; mix run scripts/record_openai_audio_fixtures.exs )`. The subshell matters: with `.env` exported into the parent shell, a later `mix test` finds a key through `ALLM.Keys`'s `System.get_env` fallback (`lib/allm/keys.ex:13`), and every "keyless" gate test stops proving its ordering.

**Success criterion:** recorder exits 0 with every arm matched; every `recorded/` file passes raw-bytes provenance; `max_audio_bytes/0` and the TTS unit are stated in the moduledocs with the probe date.

### Phase 25.5 — Gemini transcription adapter (Layer B)

#### 25.5.1 Test Plan

`gemini/transcription_test.exs`:
- body: the first part's text starts with `@transcription_instruction`; `prompt` / `language` hints appear only when set; second part `inlineData` (camelCase) with the audio's `mimeType` and base64 of its bytes; a `nil` mime → `:invalid_request`, keyless
- mime gate: `audio/webm` (not in Gemini's inferred set) → `:invalid_request`, keyless. **If the 25.5 probe shows webm is accepted, this row flips with the set**
- decode: text parts concatenated; a part with `"thought": true` excluded (synthesized fixture); usage from `usageMetadata`, `thoughtsTokenCount` → `usage.reasoning_tokens`
- size/unresolvable gates as for OpenAI

Wire tests, provenance, conformance invocations, and the redactor companion test (the OpenAI `sk-` pattern matches nothing in `gemini/.../synthesized/error_400_key.json`) as in 25.4.

#### 25.5.2 Live probe — `scripts/record_gemini_audio_fixtures.exs`

Control arm **expects 400** (Gemini rejects unknown fields; Decision #12), so acceptance arms are evidence here. As in 25.4.2, every arm has a write target (`probe_<arm>.json` for assert-only arms) so a fully recorded tree makes zero live calls.

| Arm | Asserts |
|-----|---------|
| control | 400 `Unknown name` |
| stt mp3 clip (the 25.4 clip) | 200, text contains `"quick brown fox"` case-insensitively; record |
| stt wav / flac / aac (the 25.4 clips) | each 200 with "fox" in the text → settles the accept set; any 400 removes that mime from the gate and amends the wire map. **webm is not probed** (no source clip) and stays rejected |
| stt opus clip, twice: `mimeType: audio/opus` and `audio/ogg` | settles the opus alias row: both 200 → `audio/opus` joins the set; only `audio/ogg` 200 → alias table; neither → opus stays rejected |
| stt near-20 MB boundary (16-bit 16 kHz mono WAV) | `max_audio_bytes()` raw → must be 200 (a 400 halts: the cap is too high). ~15.1 MB raw (≈20.1 MB base64) → 400 confirms the cap; a 200 means the cap is conservative, which is recorded as a `[CARRY]` in RECORDS with the cap unchanged (no halt) |
| bad key | 400 `API_KEY_INVALID`; record |

> CORRECTED 2026-09-24: "~15.1 MB raw (≈20.1 MB base64)" only sits above the cap read as **MiB** (15.1 decimal MB is below `max_audio_bytes()` = 15,679,488, so it could not 400 while the cap rung returns 200). The 25.5 recorder sends 15,831,040 raw bytes (15 MiB + 100 KiB, ≈21.1 MB base64). Observed: the cap rung and this rung both 200; the opus arms both 200 (`audio/opus` joins the set).

**Cost (UNVERIFIED rates; the implementer quotes Google's pricing page in RECORDS):** the two ~15 MB boundary arms dominate. Recorded as 16-bit 16 kHz mono WAV, 15 MB ≈ 8 min ≈ 15k audio tokens at ~32 tokens/s, which is cents per arm at ~$1/M audio-input tokens. Low-bitrate audio would be ~an hour (≈115k tokens ≈ $0.12 per arm), so the recorder must use WAV. Per clean run ≈ **$0.05**; first implementation 2–4× ≈ **$0.20**.

#### 25.5.3 Implementation Checklist

- [ ] `gemini/transcription.ex` per the wire map and Decisions #8, #12
- [ ] Redactor verbatim from `gemini/embeddings.ex:891-897`
- [ ] Recorder + fixtures + `gemini_fixtures.ex` loaders
- [ ] The `exceeds the maximum number of tokens` → `:context_length_exceeded` arm (25.1.4), unit-tested against a synthesized fixture
- [ ] `groups_for_modules`

#### 25.5.4 Verification

Targeted + uniform + conformance + **BLOCKING** `( set -a; . ./.env; set +a; mix run scripts/record_gemini_audio_fixtures.exs )` (subshell, as in 25.4.4).

**Success criterion:** recorder exits 0; the inferred Gemini rows are settled and amended in the wire map in the same commit; provenance tests green.

### Phase 25.6 — Spec, guide, examples, release wiring

#### 25.6.1 Test Plan

`guides_test.exs` (+`audio.md` in `@guides`, inheriting the structural gates); `guides_doctest_test.exs` (+`doctest_file("guides/audio.md")`); `package_files_extras_consistency_test.exs` passes once `mix.exs @guides` gains the entry.

#### 25.6.2 Implementation Checklist

- [ ] Spec **§37**: data types, the two behaviours, engine slots, façade, provider matrix (OpenAI: speech + transcription; Gemini: transcription; Gemini TTS deferred), testing, telemetry, out of scope. Amend §27, §29, §32.5, §33 with `> **Phase 25 amendment (commits <first>..<last>).**`
- [ ] `guides/audio.md`: `iex>` blocks over `FakeSpeech` / `FakeTranscription` wherever runnable; fences only for live-key snippets. Sections: quick start (both directions); formats; voices are provider strings; per-slot models (Decision #10); transcription fidelity on Gemini (Decision #8); size limits via `max_audio_bytes/0` in an `iex>` block; the one-engine-two-providers pairing; testing with the Fakes
- [ ] `examples/_helpers.exs`'s shared `capability_engine/2` (`:292`) routes the default model onto the single `:model` field (its comment at `:266`). Extend its spec map with `:engine_model_field` (default `:model`; `:speech_model` / `:transcription_model` for the new helpers) and update the comment block. This touches a released helper and is recorded as a `[structural, documented]` deviation
- [ ] `examples/23_synthesize_speech.exs` (writes the audio to a temp file, asserts `byte_size > 0` and the format; `# Provider: openai`) and `24_transcribe_audio.exs` (transcribes `examples/fixtures/quick_brown_fox.mp3`, asserts the text contains "fox"; `# Provider: openai, gemini`)
- [ ] `_helpers.exs`: `speech_adapter` / `speech_model` / `transcription_adapter` / `transcription_model` on all three `@providers` rows (`speech_adapter: nil` for gemini and anthropic; `transcription_adapter: nil` for anthropic), and `speech_engine/1` / `transcription_engine/1` shaped like `moderation_engine/1`, setting the slot's adapter **and** its per-slot model field (Decision #10), never `:model`
- [ ] `mix.exs @guides`; `CHANGELOG.md` from `git diff <latest-tag>..HEAD lib/`, where `<latest-tag>` is `git describe --tags --abbrev=0` at 25.6 time (`v0.5.0` on 2026-09-24)

#### 25.6.3 Verification

Uniform block, `mix docs` (zero broken autolinks), then BLOCKING `( set -a; . ./.env; set +a; ALLM_PROVIDER=openai mix run examples/23_synthesize_speech.exs )`, and `examples/24_transcribe_audio.exs` under both `ALLM_PROVIDER=openai` and `ALLM_PROVIDER=gemini` (same subshell form), and `run_all.exs` per arm with the **blocked-arm re-characterization** rule: a per-script result line, never an inherited one. `RUN_OUTPUT_*.md` is regenerated only with a clean full run.

**Success criterion:** the three script runs print `OK:` and exit 0; `guides/audio.md` passes all structural gates and its `iex>` blocks execute.

### Phase 25.7 — `[CHORE]` sweep

**Module Tree:** `steering/PHASE_19_DESIGN.md` (superseded banner pointing here); `ASKS.md` (including the `[CARRY]` that `lib/allm/providers/gemini.ex:109`, `gemini/images.ex` and `gemini/embeddings.ex` classify a bad key as `:invalid_request`, with the predicate `grep -L API_KEY_INVALID lib/allm/providers/gemini.ex lib/allm/providers/gemini/{images,embeddings,transcription}.ex` must be empty; `decode.ex` is excluded because it classifies no errors), the `[CARRY]` that `openai/moderation.ex:987-988` `decode_error_body/1` drops binary error bodies (predicate: the binary clause calls `Jason.decode`) (close or file the phase's tickets, each with a self-scoring predicate); any `[CARRY]` the 25.4/25.5 reviews raise.

**Checklist:**
- [ ] Superseded banner on PHASE_19
- [ ] Every ticket this phase filed is closed or re-filed with a grep predicate
- [ ] `grep -rn 'body_preview:' lib/allm/providers/` is empty

**Verification:** uniform block + both predicates. **Success criterion:** predicates clean; no ticket re-dated.

---

## Error Contract

| Function | Reason | Recovery |
|----------|--------|----------|
| `synthesize/3` / `transcribe/3` | `EngineError :no_speech_adapter` / `:no_transcription_adapter` | Set the engine slot. |
| same | `ValidationError :invalid_speech_request` / `:invalid_transcription_request` | Fix per `:errors`; no retry. |
| same | `ArgumentError` (**raised**) | Adapter broke invariant 1; not caller-recoverable. |
| adapters | `:authentication_failed` | OpenAI 401 / Gemini 400 `API_KEY_INVALID`. No retry. |
| `Gemini.Transcription` | `:context_length_exceeded` | Audio exceeds the model's token window. Shorten the clip. |
| adapters | `:rate_limited` | 429; `retry_after_ms` from `Retry-After`. Retried. |
| adapters | `:invalid_request` | 400/404/413; empty input; unresolvable/oversized audio (`metadata.count`/`max`/`cause`); Gemini mime gate. No retry. |
| `OpenAI.Speech` | `:context_length_exceeded` | Input over 4096 code points. Split the text. |
| `Gemini.Transcription` | `:content_filter` | Safety block. No retry. |
| adapters | `:provider_unavailable`, `:timeout`, `:network_error` | Retried. |
| adapters | `:malformed_response` | 200 without the expected payload (TTS non-`audio/*` body; STT without `text`). No retry. |
| adapters | `:unknown` | Unclassifiable. No retry. |

`{:error, term()}` appears in no `@spec`.

---

## Definition of Done

- [ ] All seven sub-phases complete (tracked in RECORDS)
- [ ] `mix test`, `mix test --seed 0` green; ≥90% coverage on new files; credo, dialyzer, format clean
- [ ] `conformance/` green on all three gates
- [ ] Every new public function has `@spec` + `@doc` + a runnable doctest
- [ ] Every Layer A struct round-trips ETF and JSON, including non-UTF-8 audio bytes
- [ ] Both Fakes and all three real adapters pass their conformance suite
- [ ] Every audit gate in the obligations table passes with the artifacts registered (fail-open gates checked by count delta)
- [ ] Every inferred wire-map row settled by a probe arm and amended in the same commit
- [ ] Every `recorded/` fixture passes raw-bytes negative provenance
- [ ] Live gates ran on both arms with per-script result lines
- [ ] `git diff --stat HEAD -- README.md` empty throughout
- [ ] CHANGELOG from `git diff <prior-tag>..HEAD lib/`; spec §37 with a commit-range stamp

## Records

Deviations, probe transcripts, and closure ledgers go to `steering/2026-09-24_SST_SUPPORT_RECORDS.md`, created on first need. The 2026-09-24 design-time curl probe (≈20 OpenAI calls, ≈12 Gemini calls, < $0.05) is summarized in the two wire maps. Its raw transcripts were not kept.
