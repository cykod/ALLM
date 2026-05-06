# Phase 19: Audio I/O — `ALLM.transcribe/3` and `ALLM.synthesize/3` — Design Document

> **Goal:** Ship the audio surface as a third pipeline parallel to chat (Layer C `generate/3`/`chat/3`) and image (`generate_image/3`/`edit_image/4`/`image_variations/3`). Add `ALLM.transcribe/3` (speech-to-text — STT) and `ALLM.synthesize/3` (text-to-speech — TTS) on top of a new `ALLM.AudioAdapter` behaviour and an `audio_adapter:` field on `%ALLM.Engine{}`. The first real provider is `ALLM.Providers.OpenAI.Audio` against Whisper (`/v1/audio/transcriptions`, `/v1/audio/translations`) and the OpenAI TTS endpoints (`/v1/audio/speech`).
> **Outcome:** A caller constructs `engine = ALLM.Engine.new(audio_adapter: ALLM.Providers.OpenAI.Audio, model: "whisper-1")` and calls `{:ok, %ALLM.TranscriptionResponse{text: t}} = ALLM.transcribe(engine, ALLM.Audio.from_file("clip.mp3"))`, or `{:ok, %ALLM.SynthesisResponse{audio: bytes, format: :mp3}} = ALLM.synthesize(engine, "Hello, world.", voice: "alloy", model: "tts-1")`. The audio surface is opt-in per engine — an engine without `audio_adapter:` returns `{:error, %ALLM.Error.EngineError{reason: :no_audio_adapter}}` from audio calls and is otherwise unchanged. Existing chat and image surfaces are unaffected. Two new live examples (`16_transcribe.exs`, `17_synthesize.exs`) ship under `examples/` and run green against OpenAI (Anthropic has no audio APIs — both scripts are OpenAI-only via the `# Provider: openai` header marker, mirroring `10_generate_image.exs`'s pattern). `mix test`, `mix credo --strict`, `mix dialyzer`, `mix format --check-formatted` all green; coverage ≥ 90 % on every new file.
> **Spec sections:** §32.5 (post-v0.3 candidates — audio listed), §35.10 (out-of-scope items eligible for v0.4+). Phase 19 ALSO amends §35 to add §36 "Audio I/O" with the canonical surface; the amendment is part of sub-phase 19.7 alongside the v0.4 release polish.
> **Layers touched:** A (seven new structs incl. `TranscriptionJob`) + B (one new behaviour with three required + four optional callbacks + one new Fake + one new real provider) + C (five new facade functions: `transcribe/3`, `synthesize/3`, `submit_transcription/3`, `fetch_transcription/3`, `await_transcription/3`). Three layers — split into sub-phases 19.1 (A — sync structs), 19.2 (B — behaviour + Fake), 19.3 (C — sync facade), 19.4 (B — cross-cutting telemetry/retry/preflight), 19.5 (B — OpenAI sync provider), 19.6 (A+B+C — async/batch STT surface), 19.7 (release polish + spec amendment) so each is independently shippable per the AGENT_DESIGN_SPEC "one layer per phase" rule.
> **Phasing doc:** [`RELEASE_0_3_PHASING.md`](RELEASE_0_3_PHASING.md) "What Comes After" → "Audio input/output". This is a v0.4 candidate; phase numbering continues from Phase 18 (per-tool manual) which is post-v0.3.0.

## Status

| Sub-phase | Description | Layer | Status |
|-----------|-------------|-------|--------|
| 19.1 | Layer A — `ALLM.Audio`, `ALLM.TranscriptionRequest`, `ALLM.TranscriptionResponse`, `ALLM.SynthesisRequest`, `ALLM.SynthesisResponse`, `ALLM.AudioUsage`; facade constructors `audio/2`, `transcription_request/2`, `synthesis_request/2`; validators | A | Not Started |
| 19.2 | `ALLM.AudioAdapter` behaviour (`transcribe/2`, `synthesize/2`, `supported_operations/0`) + conformance suite + `ALLM.Providers.FakeAudio` | B | Not Started |
| 19.3 | Engine wiring + `ALLM.transcribe/3` + `ALLM.synthesize/3` facade against `FakeAudio` | C | Not Started |
| 19.4 | Telemetry (`[:allm, :audio, :start \| :stop]` spans) + capability pre-flight + retry integration | B (cross-cutting) | Not Started |
| 19.5 | `ALLM.Providers.OpenAI.Audio` — real provider against `/v1/audio/transcriptions`, `/v1/audio/translations`, `/v1/audio/speech` | B | Not Started |
| 19.6 | Async/batch STT surface — `%ALLM.TranscriptionJob{}` Layer A struct, three optional `AudioAdapter` callbacks (`submit_transcription/2`, `fetch_transcription/2`, `cancel_transcription/2`), `:transcribe_async` operation, three new facade functions (`ALLM.submit_transcription/3`, `ALLM.fetch_transcription/3`, `ALLM.await_transcription/3`), `FakeAudio` script extension. Behaviour-only — no real-provider async impl in this phase (no built-in OpenAI sync→async path; defers to a future provider package, e.g., AssemblyAI / AWS Transcribe). | A/B/C | Not Started |
| 19.7 | Spec amendment (new §36 "Audio I/O" incl. async/batch surface) + `examples/16_transcribe.exs` + `examples/17_synthesize.exs` + CHANGELOG + README "Audio" section | A/B/C | Not Started |

**Overall Progress:** 0/7 sub-phases complete

## Overview

Audio I/O completes the multimodal foundation started by v0.3's image extension. Voice-driven applications (transcription pipelines, voice assistants, audiobook generators, accessibility tooling) need a provider-neutral surface that mirrors what the library already delivers for chat and image. `RELEASE_0_3_PHASING.md` lines 165-167 explicitly name `ALLM.transcribe/3` and `ALLM.synthesize/3` as the v0.4 audio entry points.

Phase 19 is **structurally a sister to Phase 13–17 (image)**. The image phasing's eight principles (`RELEASE_0_3_PHASING.md` lines 11-18) all transfer verbatim to audio, with one renamed concept (`Audio` instead of `Image`) and one principle-2 echo: streaming does not apply to v0.4 audio. The OpenAI TTS endpoint *can* stream chunked audio (`stream: true` + chunked transfer encoding) and Whisper has a websocket-based real-time API in beta — both are explicitly deferred to v0.5+ behind a separate `AudioStreamAdapter` behaviour, mirroring how v0.3's image path stays sync-only.

The pipeline is **opt-in per engine**: a v0.3 caller constructing `engine = ALLM.Engine.new(adapter: OpenAI, image_adapter: OpenAI.Images)` continues to work unchanged. Adding `audio_adapter: ALLM.Providers.OpenAI.Audio` is the only surface change, and an engine that omits it returns a typed `:no_audio_adapter` error from `transcribe/3` and `synthesize/3`. The existing serializability invariant on `%ALLM.Engine{}` (Phase 1 / Phase 8) extends to the new field — `audio_adapter:` is a `module() | nil`, restored on JSON decode via `String.to_existing_atom/1` per the existing pattern at `lib/allm/engine.ex:395`.

### Why a single `ALLM.AudioAdapter` (not separate `STTAdapter` + `TTSAdapter`)

Same shape as `ALLM.ImageAdapter`'s "one behaviour, multiple operations" pattern (`lib/allm/image_adapter.ex:55-82`): one `audio_adapter:` engine field, `supported_operations/0` declares which subset of `[:transcribe, :translate, :synthesize]` the adapter implements, and per-call dispatch routes to either `transcribe/2` or `synthesize/2`. Providers in the wild ship STT and TTS as one API surface — OpenAI groups them under `/v1/audio/*`, Eleven Labs publishes both under one auth boundary, AWS Polly + Transcribe share an SDK. A single behaviour mirrors the provider topology and avoids forcing a caller to construct two adapter modules per provider.

### Streaming is out of scope (v0.4)

Per phasing principle #2 transferred from images: streaming does not apply to v0.4 audio. TTS-side chunked streaming and STT-side websocket real-time both require widening the v0.2 §3 stream-first invariant or introducing a parallel `ALLM.AudioStreamAdapter` behaviour with its own event union — neither belongs in this phase. See the "Out of scope" list below.

### Layer demonstration

**Layer A — Audio data:**

```elixir
clip = ALLM.Audio.from_file("hello.mp3")
clip.source        # => {:file, "hello.mp3"}
clip.mime_type     # => "audio/mpeg"

req = ALLM.transcription_request(clip, model: "whisper-1", language: "en")
:ok = ALLM.Validate.transcription_request(req)
^req = req |> :erlang.term_to_binary() |> :erlang.binary_to_term()
```

**Layer B — Adapter behaviour + Fake:**

```elixir
ALLM.Providers.FakeAudio.script(transcribe: [
  {:ok, %ALLM.TranscriptionResponse{text: "hello world"}}
])

engine = ALLM.Engine.new(audio_adapter: ALLM.Providers.FakeAudio)
{:ok, %ALLM.TranscriptionResponse{text: "hello world"}} =
  ALLM.transcribe(engine, ALLM.Audio.from_binary(<<>>, "audio/mpeg"))
```

**Layer C — Stateless transcribe/synthesize:**

```elixir
engine =
  ALLM.Engine.new(
    audio_adapter: ALLM.Providers.OpenAI.Audio,
    model: "whisper-1"
  )

# Speech-to-text
{:ok, %ALLM.TranscriptionResponse{text: text, language: "en"}} =
  ALLM.transcribe(engine, ALLM.Audio.from_file("interview.mp3"))

# Text-to-speech
{:ok, %ALLM.SynthesisResponse{audio: mp3_bytes, format: :mp3}} =
  ALLM.synthesize(engine, "Welcome to ALLM.", voice: "alloy", model: "tts-1")

File.write!("welcome.mp3", mp3_bytes)
```

**Layer D — Sessions are unchanged.** `%ALLM.Session{}` is conversation state for chat; audio operations are stateless single-shot calls (no continuation). A caller using `transcribe/3` to build a transcript then feeding that text into `Session.reply/4` is the natural pattern; nothing on `%Session{}` needs to change.

### Deliverables

- **New Layer A modules:**
  - `lib/allm/audio.ex` — `%ALLM.Audio{source, mime_type, metadata}` with `from_file/1`, `from_binary/2`, `from_url/1`, `from_base64/2`, `to_binary/1`. Sister to `lib/allm/image.ex`. NO HTTP at construction time (per principle #8).
  - `lib/allm/transcription_request.ex` — `%ALLM.TranscriptionRequest{audio, model, operation, language, prompt, response_format, temperature, options, metadata}`.
  - `lib/allm/transcription_response.ex` — `%ALLM.TranscriptionResponse{text, language, duration, segments, words, usage, request_id, metadata}`.
  - `lib/allm/transcription_job.ex` (sub-phase 19.6) — `%ALLM.TranscriptionJob{id, status, provider, model, request, created_at, completed_at, result, error, webhook_url, metadata}`. Round-trips ETF + JSON; `:provider` is the adapter atom (decoded via `restore_module/1`); `:created_at`/`:completed_at` are ISO-8601 strings on the wire (DateTime.t() in memory) — matches the `Session.created_at` precedent at `lib/allm/session.ex` for safe JSON round-trip.
  - `lib/allm/synthesis_request.ex` — `%ALLM.SynthesisRequest{text, model, voice, format, speed, instructions, options, metadata}`.
  - `lib/allm/synthesis_response.ex` — `%ALLM.SynthesisResponse{audio, format, usage, request_id, metadata}`.
  - `lib/allm/audio_usage.ex` — `%ALLM.AudioUsage{input_seconds, output_seconds, character_count, input_cost, output_cost, total_cost}`.
- **New Layer B modules:**
  - `lib/allm/audio_adapter.ex` — `ALLM.AudioAdapter` behaviour: three required callbacks (`transcribe/2`, `synthesize/2`, `supported_operations/0`) + four optional (`prepare_request/2`, `submit_transcription/2`, `fetch_transcription/2`, `cancel_transcription/2` — async surface from sub-phase 19.6).
  - `lib/allm/providers/fake_audio.ex` — `ALLM.Providers.FakeAudio` reference impl + scripted-response store. Sub-phase 19.6 extends with a `submit_transcription:` queue + process-local job-id store.
  - `lib/allm/providers/openai/audio.ex` — `ALLM.Providers.OpenAI.Audio` (sub-phase 19.5). Sync-only — does NOT implement async callbacks (OpenAI Batch API does not support `/v1/audio/*` per Decision #14).
- **Modified Layer B:**
  - `lib/allm/engine.ex` — add `audio_adapter: module() | nil` field with `__from_tagged__/1` decode at the existing `restore_module/1` site (`engine.ex:395`).
  - `lib/allm/capability.ex` — extend with `preflight_audio/2` for the optional `llm_db` capability gate.
- **Modified Layer C:**
  - `lib/allm.ex` — sync facade: `transcribe/3`, `synthesize/3`, `audio/2`, `transcription_request/2`, `synthesis_request/2` (sub-phases 19.3 / 19.4). Async facade (sub-phase 19.6): `submit_transcription/3`, `fetch_transcription/3`, `await_transcription/3` (the last being a polling helper, not a behaviour callback). Telemetry span wrapper (`:audio` spans) wraps every dispatch — async spans carry `:operation` ∈ `[:transcribe_async, :fetch_transcription, :cancel_transcription]` plus `:job_id` metadata.
- **Modified validators:**
  - `lib/allm/validate.ex` — add `transcription_request/1` and `synthesis_request/1` returning `:ok | {:error, %ValidationError{}}`. Sub-phase 19.6 adds `transcription_job/1` (validates job-id non-empty + status enum).
- **New error type:**
  - `lib/allm/error/audio_adapter_error.ex` — `ALLM.Error.AudioAdapterError` with closed reason enum (mirrors `ImageAdapterError`): `:rate_limited`, `:provider_unavailable`, `:timeout`, `:network_error`, `:unsupported_operation`, `:unsupported_format`, `:audio_too_large`, `:invalid_request`, `:authentication_failed`, `:internal_error`, `:no_scripted_response` (FakeAudio exhausted-script signal — closed-set member, not a wire error). Sub-phase 19.6 adds `:job_not_found` (provider returned 404 on `fetch_transcription`/`cancel_transcription`) and `:job_expired` (provider returned a "result has expired" terminal state) — both closed-set members.
- **Modified `EngineError` enum:**
  - `lib/allm/error/engine_error.ex` — add `:no_audio_adapter` reason.
- **Test support:**
  - `test/support/audio_adapter_conformance.ex` — conformance macro suite. Sub-phase 19.6 adds an opt-in `:async` mode invoked by adapters that advertise `:transcribe_async` (mirrors `image_adapter_conformance.ex`'s `:edit` opt-in mode at `test/support/image_adapter_conformance.ex` if present, or the chat-side equivalent).
  - `test/support/fake_audio_fixtures.ex` — at least nine scripted scenarios (single-text transcribe, multilingual, segments-included, words-with-timestamp-granularities, diarize-with-speakers, exhausted-script, model-aware unsupported_operation, `gpt-4o-mini-transcribe` token-usage shape, TTS round-trip). Sub-phase 19.6 adds three more: `submit→fetch(processing)→fetch(completed)` happy path, `submit→fetch(failed)`, `submit→cancel`.
- **New tests:** see Test Plan section.
- **New examples:**
  - `examples/16_transcribe.exs` (NEW — OpenAI-only) — synthesizes a tiny audio fixture (`test/fixtures/audio/hello_world.mp3`, 5 seconds, ~50 KB), transcribes it, asserts the text contains "hello".
  - `examples/17_synthesize.exs` (NEW — OpenAI-only) — synthesizes "ALLM is a provider neutral library" via `gpt-4o-mini-tts` (Decision #6a — newest TTS model with `instructions` support; falls back to `tts-1` if the engine's `audio_synthesize_default_model` is overridden), writes to tmp file, asserts the file starts with the MP3 magic header `<<0xFF, 0xFB>>` (or `<<0xFF, 0xF3>>`/`<<0xFF, 0xF2>>` for MPEG layer 3 variants — see test plan).
  - NOTE: no `18_submit_transcription.exs` example in v0.4 — the OpenAI bundled adapter does NOT implement async, and ALLM does NOT bundle AssemblyAI / AWS / GCP / Azure / Deepgram. The async surface ships with conformance tests against `FakeAudio` only; a follow-on third-party-adapter package (or v0.5 phase) authors the live-gate example.
- **CHANGELOG.md** — seven bullets: data structs (19.1), behaviour + Fake (19.2), sync facade (19.3), telemetry/retry/preflight (19.4), real OpenAI provider (19.5), async/batch STT surface (19.6 — contract-only, no real adapter), examples + spec amendment (19.7).
- **Spec amendment** — new §36 "Audio I/O" added to `steering/allm_engine_session_streaming_spec_v0_2.md` (covers §36.1 design goals, §36.2 data structs, §36.3 `ALLM.AudioAdapter` (sync + async callbacks), §36.4 Engine wiring, §36.5 public API (sync), §36.6 public API (async/batch), §36.7 OpenAI Audio adapter, §36.8 `FakeAudio`, §36.9 telemetry, §36.10 out-of-scope).

### Spec coverage

| Spec § (NEW) | Phase 19 implements |
|--------------|--------------------|
| §36.1 design goals | Four goals — opt-in per engine, parallel pipelines, sync + async-job surfaces (one behaviour, two surfaces), streaming deferred to v0.5+. |
| §36.2 data structs | Seven structs — `Audio`, `TranscriptionRequest`, `TranscriptionResponse`, `TranscriptionJob` (async — sub-phase 19.6), `SynthesisRequest`, `SynthesisResponse`, `AudioUsage`. |
| §36.3 `ALLM.AudioAdapter` | Behaviour with three required callbacks (`transcribe/2`, `synthesize/2`, `supported_operations/0`) + four optional (`prepare_request/2`, `submit_transcription/2`, `fetch_transcription/2`, `cancel_transcription/2`). |
| §36.4 Engine wiring | `audio_adapter:` field; `:no_audio_adapter` engine error; capability pre-flight. |
| §36.5 public API (sync) | `ALLM.transcribe/3`, `ALLM.synthesize/3`, `ALLM.audio/2`, `ALLM.transcription_request/2`, `ALLM.synthesis_request/2`. |
| §36.6 public API (async) | `ALLM.submit_transcription/3`, `ALLM.fetch_transcription/3`, `ALLM.await_transcription/3`. Adapters that lack `submit_transcription/2` surface `{:error, %AudioAdapterError{reason: :unsupported_operation}}`. OpenAI sync adapter does NOT implement async (OpenAI Batch API does not currently support `/v1/audio/*`); the surface is contract-only here, with the first concrete async implementation deferred to a future provider package (AssemblyAI / AWS Transcribe / GCP `LongRunningRecognize` / Azure Speech Batch). |
| §36.7 `ALLM.Providers.OpenAI.Audio` | Transcription: `whisper-1`, `gpt-4o-mini-transcribe`, `gpt-4o-mini-transcribe-2025-12-15`, `gpt-4o-transcribe`, `gpt-4o-transcribe-diarize` (native speaker labels). Synthesis: `tts-1`, `tts-1-hd`, `gpt-4o-mini-tts`, `gpt-4o-mini-tts-2025-12-15`. Sync only (no async/batch path on `/v1/audio/*` — verified via context7 against OpenAI Batch API endpoint enumeration on 2026-05-06). |
| §36.8 `ALLM.Providers.FakeAudio` | Scripted-response Fake; passes the conformance suite for both sync and async surfaces (sub-phase 19.6 extends the Fake's script store with a `submit_transcription:` queue and a process-local job-id store keyed on `:erlang.unique_integer([:positive])`). |
| §36.9 telemetry | `[:allm, :audio, :start \| :stop]` spans with `:operation` (now incl. `:transcribe_async`, `:fetch_transcription`, `:cancel_transcription`), `:model`, `:duration_ms`, `:audio_bytes`, `:job_id` measurements. |
| §36.10 out-of-scope | Streaming TTS (`stream_format: "audio"`), websocket STT (Realtime API), audio message parts (deferred to v0.5 alongside future Gemini chat-audio support), Anthropic audio adapter (no API yet), Eleven Labs / AWS Polly / AssemblyAI / Deepgram / Azure adapters (separate packages per §32 — async behaviour contract ships in 19.6 so they slot in unchanged). |

### Prerequisites

- v0.3.0 codebase shipped (current at HEAD as of `2026-05-03`).
- Phase 18 (per-tool manual) shipped or deferred — Phase 19 has no functional dependency on Phase 18.
- `Req` HTTP client (already in `mix.exs` for chat / image non-streaming paths) — same library; no new deps.
- `Finch` is NOT required for Phase 19 (no streaming).
- No `llm_db` dependency required — capability pre-flight is a no-op when the catalog is absent (existing pattern at `lib/allm/capability.ex`).

### Out of scope

- **Streaming TTS** (`stream: true` + chunked transfer encoding on `/v1/audio/speech`). *Justification:* would require widening the §3 stream-first invariant or adding a parallel `ALLM.AudioStreamAdapter` behaviour with its own event union; neither fits a v0.4 single-phase scope. Defer to v0.5 with a separate phasing doc.
- **Real-time STT websocket** (OpenAI's `gpt-4o-realtime-preview`, AssemblyAI streaming). *Justification:* websocket transport is orthogonal to the v0.2 `Req` + `Finch` HTTP-stack assumption baked into every adapter; bringing in a fourth transport (e.g., `Mint.WebSocket` or `Fresh`) is a separate piece of work. Defer to v0.5.
- **Audio message parts** (`%ALLM.AudioPart{audio: %Audio{}, transcript: nil}` analogous to `%ALLM.ImagePart{}` for vision-capable models like `gpt-4o-audio-preview`). *Justification:* mirrors v0.3's image phasing — image generation shipped first, vision-via-message-parts shipped in a separate phase (Phase 7/8). Audio gets the same split: transcribe/synthesize first (Phase 19), then `AudioPart` in a v0.5 phase that touches the chat adapters.
- **Anthropic audio adapter.** Anthropic exposes no audio APIs as of `2026-05-03`. *Justification:* nothing to wrap.
- **Third-party adapters** — Eleven Labs (TTS), AssemblyAI (STT), Google Cloud Speech, AWS Polly + Transcribe, Azure Speech. *Justification:* each is a separate package per §32 (one provider, one Hex package). Phase 19 ships the behaviour + conformance suite so third parties can implement against a stable contract.
- **Audio editing** (trim, splice, format conversion). *Justification:* the library is an LLM execution surface, not an audio processing toolkit. Callers pre-process via `ffmpeg` / `:wave_file` / their tool of choice and pass the resulting bytes to `ALLM.Audio.from_binary/2`.
- **Voice cloning / custom voices.** *Justification:* provider-specific concerns (OpenAI doesn't support custom voices on `/v1/audio/speech`; Eleven Labs does via separate endpoints). Custom-voice configuration rides in `SynthesisRequest.options` (the existing free-form map) and adapter-specific helpers.
- **Speaker diarization** beyond what the provider returns natively in `segments`. *Justification:* Whisper's verbose JSON includes per-segment timing + (optionally) speaker labels via post-processing tools; raw passthrough lives in `TranscriptionResponse.segments`. Multi-speaker assignment is a downstream concern.

### Non-obvious decisions

1. **One `ALLM.AudioAdapter` behaviour with two distinct callbacks (`transcribe/2`, `synthesize/2`), NOT one `dispatch/2` with a discriminator.** The image surface uses one `generate/2` discriminating on `request.operation` because all three image operations return `%ImageResponse{}`. Audio's transcribe and synthesize return *different* response types (`%TranscriptionResponse{}` vs `%SynthesisResponse{}`), so a single `dispatch/2` would have a `{:ok, TranscriptionResponse.t() | SynthesisResponse.t()}` typespec — Dialyzer-hostile and ergonomically confusing. Two callbacks keep each return type narrow. *Docs target:* `@moduledoc ALLM.AudioAdapter`; spec §36.3.

2. **`supported_operations/0` returns subset of `[:transcribe, :translate, :synthesize, :transcribe_async]`.** Whisper supports `:transcribe` + `:translate` (translate→English via `/v1/audio/translations`); OpenAI TTS supports only `:synthesize`; the OpenAI bundled adapter does NOT advertise `:transcribe_async` (verified against OpenAI Batch API endpoint enumeration via context7 on 2026-05-06 — `/v1/batches` accepts `/v1/chat/completions`, `/v1/embeddings`, `/v1/completions`, `/v1/responses` only, NOT `/v1/audio/*`). Each operation gates dispatch BEFORE any HTTP I/O via the conformance suite's `:unsupported_operation` rejection — same pattern as `ImageAdapter`'s op gate. The `:translate` operation routes through `transcribe/2` with `request.operation == :translate` (not a third callback) — the wire shape is nearly identical to `:transcribe`, just a different endpoint URL. **`:translate` ignores `request.language`** (Whisper's translations endpoint always outputs English regardless of input language). The `transcription_request/2` `@doc` carries an explicit warning paragraph: "When `operation: :translate`, any `language:` opt is silently dropped at the adapter boundary — Whisper's translate endpoint always outputs English. Set `operation: :transcribe` if you want to preserve the source language." `:transcribe_async` is the async-job analog of `:transcribe` — adapters that advertise it implement `submit_transcription/2` + `fetch_transcription/2` + `cancel_transcription/2` (sub-phase 19.6); adapters that do NOT advertise it surface `{:error, %AudioAdapterError{reason: :unsupported_operation}}` from `ALLM.submit_transcription/3` BEFORE I/O. *Docs target:* `@callback ALLM.AudioAdapter.supported_operations/0`; `@doc ALLM.transcription_request/2`; spec §36.3.

3. **`%ALLM.Audio{source: ...}` mirrors `%ALLM.Image{source: ...}` byte-for-byte at the type level.** Reuse the four-shape source enum verbatim: `{:binary, bytes}`, `{:base64, str}`, `{:url, url}`, `{:file, path}`. Same constructors (`from_file/1`, `from_binary/2`, etc.). Same eager-fetch ban (`from_url/1` does NOT download — adapter is responsible). `mime_type` defaults to `nil` (matches `lib/allm/image.ex:64`); `from_file/1` derives it from the lowercased extension via a closed `@ext_to_mime` lookup table (mirrors `lib/allm/image.ex:68`). Unknown extensions leave `mime_type` as `nil` and the adapter is responsible for resolving — same contract as Image. The audio extension table:

   ```elixir
   @ext_to_mime %{
     ".mp3"  => "audio/mpeg",
     ".wav"  => "audio/wav",
     ".flac" => "audio/flac",
     ".ogg"  => "audio/ogg",
     ".oga"  => "audio/ogg",
     ".opus" => "audio/opus",
     ".aac"  => "audio/aac",
     ".m4a"  => "audio/mp4",
     ".mp4"  => "audio/mp4",
     ".webm" => "audio/webm"
   }
   ```

   *Docs target:* `@moduledoc ALLM.Audio`; spec §36.2.

4. **`SynthesisResponse.audio` is always raw bytes — `format` field carries the encoding atom.** OpenAI returns the audio as the response body with a `Content-Type` header naming the format. Adapters MUST decode the format header into `format: :mp3 | :opus | :aac | :flac | :wav | :pcm` and surface raw bytes on `:audio`. Callers wanting base64 or a data-URI build it from `:audio` + `:format` themselves — mirrors `ImageResponse.images` (which is `[%Image{}]` with the source-shape choice on each). *Docs target:* `@moduledoc ALLM.SynthesisResponse`; spec §36.2.

5. **`TranscriptionRequest.response_format` default is `:json` (text only); `:verbose_json` opts in to segments.** Whisper's `verbose_json` response is ~10× the size of `json` and fills `TranscriptionResponse.segments` with per-segment timing. Default to the cheapest shape; let the caller opt in. The closed-enum at the contract level: `:json | :verbose_json | :text | :srt | :vtt`. The adapter validates the requested format is in the model's supported set BEFORE dispatch (per §36.3 invariant 4). *Docs target:* `@type response_format`; spec §36.2.

6. **`SynthesisRequest.format` default is `:mp3`.** Most-compatible format across players. The closed enum: `:mp3 | :opus | :aac | :flac | :wav | :pcm`. `:pcm` is raw 16-bit signed little-endian at 24 kHz per OpenAI's spec — no header bytes; callers needing playable audio should choose `:mp3` or `:wav`. *Docs target:* `@type format`; spec §36.2.

6a. **`SynthesisRequest.instructions: String.t() | nil` is a top-level field, not buried in `options`.** OpenAI's `gpt-4o-mini-tts` (and the `2025-12-15` snapshot) accepts an `instructions` parameter for steering voice characteristics ("speak in a cheerful tone", "whisper softly", "sound excited and energetic") — this is a first-class public-API control and treating it as a free-form options map entry would obscure it from callers reading the typespec. Adapters whose model doesn't support it (legacy `tts-1`, `tts-1-hd`) silently drop the field at request-build time AND emit a Logger.debug (deferred form per CLAUDE.md `Logger.debug(fn -> ... end)` rule) the first time per process per model — same one-shot warn pattern as Phase 17.2's detail-drop latch. *Docs target:* `@moduledoc ALLM.SynthesisRequest`; `@doc ALLM.synthesize/3` (mention drop behavior); spec §36.2.

7. **`AudioUsage` carries BOTH `input_seconds` (transcription billing) AND `character_count` (synthesis billing).** Whisper bills per-minute of input audio (rounded to nearest second by OpenAI); TTS bills per-character of input text. One `%AudioUsage{}` struct serves both — fields are nullable so the irrelevant ones stay `nil`. `output_seconds` is reserved for streaming/real-time STT (v0.5+) and stays `nil` in Phase 19. Cost fields (`input_cost`, `output_cost`, `total_cost`) are typed `float() | nil` (NOT `Decimal.t()`) — matches the precedent established by `ImageUsage` at `lib/allm/image_usage.ex:38-40` and the chat-side `Usage.cost` at `lib/allm/usage.ex:11`, both of which chose `float()` over `Decimal.t()` to avoid splitting the cost type across structs. Cost fields populate from `llm_db` when loaded; `nil` otherwise — same pattern as `%ALLM.Usage{cost: nil}` (chat) and `%ImageUsage{}`. *Docs target:* `@moduledoc ALLM.AudioUsage`; spec §36.2.

8. **Audio-side retryable reasons mirror the image-side enum verbatim.** The `[:rate_limited, :provider_unavailable, :timeout, :network_error]` retry set ships unchanged. `lib/allm.ex`'s `do_generate_image/3` retry-augmenter pattern at `lib/allm.ex:921-933` (`augment_image_retry_policy/1`) is copy-paste-renamed to `augment_audio_retry_policy/1`. *What the implementation does to maintain this:* Phase 19.4 adds `@retryable_audio_reasons` module attribute mirroring `@retryable_image_reasons` at `lib/allm.ex:787` and an analogous `dispatch_audio_attempt/3` per-attempt closure. *Docs target:* `@doc false` on `augment_audio_retry_policy/1`; spec §36.9.

9. **Telemetry spans use the atom `:audio` (single span family covering both operations) with `:operation` as a metadata field.** Mirrors how `:image` is one span family even though there are three operations (`generate`, `edit`, `variation`). `[:allm, :audio, :start]` measurements: `system_time`. `:start` metadata: `request_id`, `operation` (`:transcribe | :translate | :synthesize`), `model`, `audio_bytes` (input bytes for STT — `nil` for TTS), `text_length` (input chars for TTS — `nil` for STT). `[:allm, :audio, :stop]` measurements: `duration` (microseconds), `output_bytes` (TTS only). `:stop` metadata: same `:start` keys plus `usage`, `response`, `error`. *Docs target:* `@moduledoc ALLM.Telemetry`; spec §36.9.

10. **Examples are OpenAI-only — Anthropic and Gemini gate skip via header marker.** Phase 19's `examples/16_*` and `examples/17_*` carry the `# Provider: openai` header marker (existing convention from `examples/10_generate_image.exs`). `run_all.exs` skips them on `ALLM_PROVIDER=anthropic` AND `ALLM_PROVIDER=gemini` (the third row in `examples/_helpers.exs:46`), printing `[SKIP] 16_transcribe.exs (provider gate)`. The `@providers` extension in `examples/_helpers.exs` adds `audio_adapter:` + `audio_default_model:` keys to the OpenAI row only — both Anthropic and Gemini rows get explicit `audio_adapter: nil, audio_default_model: nil` so `audio_engine/1` raises a clear `ArgumentError` with the same shape as `image_engine/1` does for Anthropic when called under those providers. (Gemini chat is shipped at HEAD — Phases 16.4/16.5 — but Gemini exposes audio only as `Part`-shaped inline data inside `generateContent`, which collapses into the deferred "audio message parts" bucket — not a dedicated `transcribe`/`synthesize` API. Google's standalone Cloud Speech-to-Text / Cloud TTS APIs are separate products and would land as a `Providers.Google.Audio` package in a follow-on phase, batch-first because GCP `LongRunningRecognize` is mandatory for files >60s — the async surface from sub-phase 19.6 is exactly what they slot into.) *What the implementation does to maintain this:* Phase 19.7 implementation checklist explicitly cites the header-marker convention at `examples/10_generate_image.exs` line 1 as the precedent; verifies `examples/run_all.exs`'s skip-detection is unchanged; adds explicit Anthropic + Gemini row updates with `audio_adapter: nil`. *Docs target:* `examples/README.md` Phase-19 row.

11. **Test fixtures: a real 5-second MP3 ships under `test/fixtures/audio/hello_world.mp3`.** Generated once at design time via `say "hello world" -o test/fixtures/audio/hello_world.aiff && ffmpeg -i test/fixtures/audio/hello_world.aiff test/fixtures/audio/hello_world.mp3 && rm test/fixtures/audio/hello_world.aiff` (or any equivalent). The fixture is committed to git (~50 KB). Synthesized fixtures (silent or generated tones) exist for unit tests against `FakeAudio`, but the live `examples/16_transcribe.exs` MUST use the real fixture so the Whisper round-trip is meaningful. The recorder script at `scripts/record_openai_audio_fixtures.exs` (shipped per CLAUDE.md "Phases shipping synthesized wire fixtures MUST commit a recorder script") regenerates the wire-recorded transcription/synthesis response fixtures under `test/fixtures/openai/audio/recorded/`. *Docs target:* `test/fixtures/audio/README.md` (NEW — explains the source).

12. **MP3 magic-number assertion in `examples/17_synthesize.exs` accepts three byte sequences.** MP3 frame headers begin with `<<0xFF, 0xFB>>` (MPEG-1 Layer 3), `<<0xFF, 0xF3>>` (MPEG-2 Layer 3), or `<<0xFF, 0xF2>>` (MPEG-2.5 Layer 3) depending on sampling rate. The assertion is a `case` over the first two bytes that succeeds on any of the three. Some MP3 files prepend an ID3v2 header (`<<"ID3", _, _, _>>`) before the first MP3 frame — handle that by reading the ID3v2 header length and skipping it before the magic check. *Docs target:* `examples/17_synthesize.exs` header comment; spec §36.7.

13. **Diarization is opt-in via model selection, not a separate operation.** OpenAI's `gpt-4o-transcribe-diarize` (verified via context7 against the OpenAI API reference on 2026-05-06) is a *model* that returns the same response shape as `gpt-4o-transcribe` plus per-segment and per-word `speaker` fields. The Layer A `TranscriptionResponse.segment` map carries an optional `:speaker` key (typed `String.t() | nil`) populated by adapters whose model returned diarization data; `nil` for non-diarize models. Callers don't pass `diarize: true` — they set `model: "gpt-4o-transcribe-diarize"` (or whichever provider-specific diarize model). This keeps the Layer A surface model-agnostic: a future Deepgram adapter that supports diarize via a `diarize: true` *parameter* on a single model would set the same `:speaker` field on segments without callers having to learn a parallel API. *Docs target:* `@type ALLM.TranscriptionResponse.segment`; spec §36.7.

14. **Async/batch STT is one optional callback set per provider, not a separate behaviour.** AssemblyAI is async-only; AWS Transcribe + GCP `LongRunningRecognize` + Azure Speech Batch are batch-first; Deepgram exposes both sync and async (callback URL). Modeling these as a separate `BatchAudioAdapter` behaviour would force callers to construct two adapter modules per provider AND would force engines to carry two adapter fields. Instead: extend `ALLM.AudioAdapter` with three optional callbacks (`submit_transcription/2`, `fetch_transcription/2`, `cancel_transcription/2`) that return `%TranscriptionJob{}` — providers declare `:transcribe_async` in `supported_operations/0` if they support it. This matches Decision #1's "one behaviour, multiple operations" precedent (which already supports `:transcribe` + `:translate` + `:synthesize`) and the image-side `ImageAdapter`'s pattern. **OpenAI Batch API does NOT support `/v1/audio/*`** (verified via context7 against `developers.openai.com/api/reference/resources/batches/methods/create` on 2026-05-06 — supported endpoints are `/v1/chat/completions`, `/v1/embeddings`, `/v1/completions`, `/v1/responses` only) — Phase 19.6 ships the contract; the first concrete async implementation lands in a follow-on phase or a third-party provider package. The async surface MUST land in v0.4 (not v0.5) because adding an optional callback to an existing `AudioAdapter` is non-breaking, but flipping a sync-only adapter contract to require async support later breaks every downstream third-party package. *Docs target:* `@callback ALLM.AudioAdapter.submit_transcription/2`; spec §36.6; Phase 19.6 sub-phase.

## Behaviour & Type Contracts

### `ALLM.Audio` (Layer A)

```elixir
defmodule ALLM.Audio do
  @type source ::
          {:binary, binary()}
          | {:base64, String.t()}
          | {:url, String.t()}
          | {:file, Path.t()}

  @type t :: %__MODULE__{
          source: source(),
          mime_type: String.t() | nil,
          metadata: map()
        }

  @enforce_keys [:source]
  defstruct [:source, :mime_type, metadata: %{}]

  @spec from_binary(binary(), String.t()) :: t()
  @spec from_base64(String.t(), String.t()) :: t()
  @spec from_url(String.t()) :: t()
  @spec from_file(Path.t()) :: t()
  @spec to_binary(t()) :: {:ok, binary()} | {:error, atom()}
end
```

**Invariants:**

- `mime_type` accepts `"audio/mpeg"` (mp3), `"audio/wav"`, `"audio/x-wav"`, `"audio/flac"`, `"audio/ogg"`, `"audio/opus"`, `"audio/aac"`, `"audio/mp4"` (m4a), `"audio/webm"`. Validators do NOT enforce this list — adapters reject unsupported formats per provider.
- `from_file/1` derives `mime_type` from extension via the `@ext_to_mime` table (Decision #3). Unmatched extensions yield `mime_type: nil`; adapters resolve.
- `from_binary/2` requires explicit `mime_type` (raises `ArgumentError` if `nil` per `@enforce_keys` semantics on the constructor pattern from `lib/allm/image.ex:from_binary/2`).
- `to_binary({:url, _})` returns `{:error, :remote_source}` — eager fetches forbidden (matches `ALLM.Image.to_binary/1`).
- `to_binary({:file, path})` reads via `File.read/1`; surfaces `{:error, :enoent}` etc. verbatim from `File.read/1`.
- ETF + JSON round-trip preserved (mirrors `ALLM.Image` tests).

### `ALLM.TranscriptionRequest` (Layer A)

```elixir
defmodule ALLM.TranscriptionRequest do
  @type operation :: :transcribe | :translate
  @type response_format :: :json | :verbose_json | :text | :srt | :vtt

  @type t :: %__MODULE__{
          audio: ALLM.Audio.t(),
          model: String.t() | nil,
          operation: operation(),
          language: String.t() | nil,
          prompt: String.t() | nil,
          response_format: response_format(),
          temperature: float() | nil,
          options: map(),
          metadata: map()
        }

  @enforce_keys [:audio]
  defstruct [
    :audio,
    :model,
    :language,
    :prompt,
    :temperature,
    operation: :transcribe,
    response_format: :json,
    options: %{},
    metadata: %{}
  ]

  @spec new(keyword()) :: t()
end
```

**Invariants:**

- `language` is an ISO 639-1 code (`"en"`, `"es"`, etc.) when set; validator rejects non-strings. `nil` lets the model auto-detect.
- `temperature` is `0.0..1.0` per Whisper's range; validator coerces to float and rejects out-of-range.
- `:translate` operation forces `language: "en"` at the adapter boundary — Whisper's translate endpoint always outputs English.

### `ALLM.TranscriptionResponse` (Layer A)

```elixir
@type segment :: %{
        id: non_neg_integer(),
        start: float(),
        end: float(),
        text: String.t(),
        speaker: String.t() | nil,
        avg_logprob: float() | nil,
        compression_ratio: float() | nil,
        no_speech_prob: float() | nil
      }

@type word :: %{
        start: float(),
        end: float(),
        text: String.t(),
        speaker: String.t() | nil
      }

@type t :: %__MODULE__{
        text: String.t(),
        language: String.t() | nil,
        duration: float() | nil,
        segments: [segment()] | nil,
        words: [word()] | nil,
        usage: ALLM.AudioUsage.t() | nil,
        request_id: String.t() | nil,
        metadata: map()
      }
```

**Invariants:**

- `text` is ALWAYS populated (concatenation of segments when verbose_json was used; raw text otherwise).
- `segments` is `nil` when `request.response_format != :verbose_json`; populated as a list when it was. `segment.speaker` is `nil` for `whisper-1` / `gpt-4o-transcribe`; populated as `"speaker_0" | "speaker_1" | ...` (or provider-native string) for `gpt-4o-transcribe-diarize`.
- `words` is `nil` unless the request's `options[:timestamp_granularities]` includes `:word`; populated when it does. Each `word.speaker` follows the same rule as `segment.speaker` (diarize-only).
- `language` is the model's detected language (or the request's language echo if explicit).
- `duration` in seconds (float).

### `ALLM.SynthesisRequest` (Layer A)

```elixir
defmodule ALLM.SynthesisRequest do
  @type format :: :mp3 | :opus | :aac | :flac | :wav | :pcm

  @type t :: %__MODULE__{
          text: String.t(),
          model: String.t() | nil,
          voice: String.t() | nil,
          format: format(),
          speed: float() | nil,
          instructions: String.t() | nil,
          options: map(),
          metadata: map()
        }

  @enforce_keys [:text]
  defstruct [
    :text,
    :model,
    :voice,
    :speed,
    :instructions,
    format: :mp3,
    options: %{},
    metadata: %{}
  ]
end
```

**Invariants:**

- `text` is non-empty; validator rejects `""`.
- `voice` is provider-specific. For OpenAI's `/v1/audio/speech` as of 2026-05-06 (verified via context7), the built-in voice set is `"alloy" | "ash" | "ballad" | "coral" | "echo" | "fable" | "marin" | "cedar" | "nova" | "onyx" | "sage" | "shimmer" | "verse"` (13 voices; `marin` and `cedar` are recommended for best quality on `gpt-4o-mini-tts`). Custom-voice IDs ride via the `options` map (OpenAI accepts `voice` as either a string or an object `{"id": "voice_…"}` — the Layer A field stays a flat `String.t() | nil` and adapters wrap into the object form when an `options[:custom_voice_id]` is set; matches Decision #6's "free-form options carry provider-specific extensions" pattern). Defaults to `nil` so the adapter's per-model default fires.
- `speed` is `0.25..4.0` per OpenAI's `/v1/audio/speech` range (verified via context7 against `developers.openai.com/api/reference/resources/audio/subresources/speech` on 2026-05-06; the Realtime API's `output.speed` caps at `0.25..1.5` but the standard speech endpoint allows the full `0.25..4.0` range); validator rejects out-of-range floats.
- `instructions` (NEW field, see Decision #6a) is provider-specific voice-steering free text; `nil` for legacy `tts-1` / `tts-1-hd`; populated for `gpt-4o-mini-tts` callers wanting tone/affect control. Adapters silently drop on models that don't support it.

### `ALLM.SynthesisResponse` (Layer A)

```elixir
@type t :: %__MODULE__{
        audio: binary(),
        format: ALLM.SynthesisRequest.format(),
        usage: ALLM.AudioUsage.t() | nil,
        request_id: String.t() | nil,
        metadata: map()
      }
```

**Invariants:**

- `audio` is raw bytes — never base64 or a data URI. Caller wraps to whatever shape they need.
- `format` echoes the request's format (or what the provider actually returned, when those differ — `gpt-4o-mini-tts` may downgrade `:flac` to `:mp3` silently; the adapter surfaces what the wire said).

### `ALLM.AudioUsage` (Layer A)

```elixir
@type t :: %__MODULE__{
        input_seconds: float() | nil,
        output_seconds: float() | nil,
        character_count: non_neg_integer() | nil,
        input_cost: float() | nil,
        output_cost: float() | nil,
        total_cost: float() | nil
      }
```

**Invariants:**

- `input_seconds` populated for `:transcribe` / `:translate` (audio length).
- `character_count` populated for `:synthesize` (input text length).
- `output_seconds` reserved for v0.5 streaming; always `nil` in Phase 19.
- Cost fields are `nil` unless `llm_db` is loaded AND has the model.

### `ALLM.TranscriptionJob` (Layer A — sub-phase 19.6)

```elixir
defmodule ALLM.TranscriptionJob do
  @type status :: :queued | :processing | :completed | :failed | :cancelled

  @type t :: %__MODULE__{
          id: String.t(),
          status: status(),
          provider: module(),
          model: String.t() | nil,
          request: ALLM.TranscriptionRequest.t() | nil,
          created_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          result: ALLM.TranscriptionResponse.t() | nil,
          error: ALLM.Error.AudioAdapterError.t() | nil,
          webhook_url: String.t() | nil,
          metadata: map()
        }

  @enforce_keys [:id, :status, :provider]
  defstruct [
    :id,
    :status,
    :provider,
    :model,
    :request,
    :created_at,
    :completed_at,
    :result,
    :error,
    :webhook_url,
    metadata: %{}
  ]

  @spec new(keyword()) :: t()
end
```

**Invariants:**

- `id` is the provider's job identifier — opaque string. Callers persist this and pass it to `ALLM.fetch_transcription/3` to resume across process restarts.
- `status` is closed-enum: `:queued` (submitted, not yet processing), `:processing` (in-flight), `:completed` (terminal — `:result` populated), `:failed` (terminal — `:error` populated), `:cancelled` (terminal).
- `provider` is the adapter module atom; round-tripped through `restore_module/1` on JSON decode (matches `Engine.audio_adapter` decode pattern).
- `request` snapshot is OPTIONAL — adapters MAY populate it on `submit_transcription/2` for round-trip diagnostics; `fetch_transcription/2` MAY return it as `nil` if the adapter doesn't echo the original request. Callers wanting the request shape persisted across restarts MUST snapshot it themselves.
- `result` is `nil` UNLESS `status == :completed`. `error` is `nil` UNLESS `status == :failed`. Both cannot be populated simultaneously (validator enforces).
- ETF + JSON round-trip preserved (DateTime fields encoded as ISO-8601 strings on JSON; preserved as `DateTime.t()` on ETF).
- `webhook_url` is informational only — ALLM does NOT host the callback receiver; that's an application-layer concern. Set when the caller passed `opts[:webhook_url]` to `submit_transcription/3` and the provider supports webhooks (AssemblyAI, Deepgram, Rev.ai do; AWS does via SNS topics; the field is `nil` for providers that don't).

### `ALLM.AudioAdapter` (Layer B)

```elixir
defmodule ALLM.AudioAdapter do
  @callback transcribe(ALLM.TranscriptionRequest.t(), keyword()) ::
              {:ok, ALLM.TranscriptionResponse.t()}
              | {:error, ALLM.Error.AudioAdapterError.t()}

  @callback synthesize(ALLM.SynthesisRequest.t(), keyword()) ::
              {:ok, ALLM.SynthesisResponse.t()}
              | {:error, ALLM.Error.AudioAdapterError.t()}

  @callback supported_operations() ::
              [:transcribe | :translate | :synthesize | :transcribe_async]

  @callback prepare_request(
              ALLM.TranscriptionRequest.t() | ALLM.SynthesisRequest.t(),
              keyword()
            ) :: {:ok, Req.Request.t()} | {:error, ALLM.Error.AudioAdapterError.t()}

  # Async/batch transcription — sub-phase 19.6. Optional; providers that don't
  # advertise :transcribe_async in supported_operations/0 are not required to
  # implement these. ALLM.submit_transcription/3 short-circuits with
  # {:error, %AudioAdapterError{reason: :unsupported_operation}} BEFORE I/O
  # when the adapter omits :transcribe_async.

  @callback submit_transcription(ALLM.TranscriptionRequest.t(), keyword()) ::
              {:ok, ALLM.TranscriptionJob.t()}
              | {:error, ALLM.Error.AudioAdapterError.t()}

  @callback fetch_transcription(
              ALLM.TranscriptionJob.t() | String.t(),
              keyword()
            ) ::
              {:ok, ALLM.TranscriptionJob.t()}
              | {:error, ALLM.Error.AudioAdapterError.t()}

  @callback cancel_transcription(
              ALLM.TranscriptionJob.t() | String.t(),
              keyword()
            ) ::
              {:ok, ALLM.TranscriptionJob.t()}
              | {:error, ALLM.Error.AudioAdapterError.t()}

  @optional_callbacks prepare_request: 2,
                      submit_transcription: 2,
                      fetch_transcription: 2,
                      cancel_transcription: 2
end
```

**Invariants** (mirror `ImageAdapter`):

1. Both `transcribe/2` and `synthesize/2` are synchronous (HTTP response read in full before return).
2. Neither callback raises for HTTP-shaped failures; all surface as `{:error, %AudioAdapterError{}}`.
3. Both honor `opts[:request_timeout]` if provided.
4. `transcribe/2` rejects `request.operation not in supported_operations()` BEFORE HTTP I/O with `{:error, %AudioAdapterError{reason: :unsupported_operation, metadata: %{operation: op}}}`. Same for `synthesize/2` against `:synthesize`.
5. Both preserve `opts[:request_id]` onto `response.request_id`.
6. Both round-trip `request.metadata` onto `response.metadata` UNCHANGED when the adapter has no use for it.
7. `prepare_request/2` (optional) returns an unfired `Req.Request`.

### `drop_audio_request_opts/1` filter contract (Layer C, internal)

Mirrors `drop_request_opts/1` at `lib/allm.ex:794-805`. Drops eight call-control opts that would collide with `TranscriptionRequest` / `SynthesisRequest` struct fields when merged via `new/1`:

```elixir
defp drop_audio_request_opts(opts) when is_list(opts) do
  Keyword.drop(opts, [
    :request_id,
    :stream,
    :adapter_opts,
    :request_timeout,
    :retry,
    :api_key,
    :telemetry_metadata,
    :on_event
  ])
end
```

**Symmetry invariant** (per AGENT_DESIGN_SPEC item 11): the keys dropped here are exactly the call/dispatch-site keys consumed downstream by `Telemetry.span/3`, `Retry.run/3`, `Engine.resolve_*`, and the adapter's `opts` parameter. They MUST NOT collide with any field on `%TranscriptionRequest{}` or `%SynthesisRequest{}` struct (`struct!/2` would `KeyError`). The image-side counterpart at `lib/allm.ex:794-805` drops the same set minus `:on_event` plus `:mask` (image-edit-specific). Audio-side drops `:on_event` because some users wire it through call opts even on non-streaming paths for uniform telemetry plumbing.

### `ALLM.transcribe/3` and `ALLM.synthesize/3` (Layer C)

```elixir
@spec transcribe(Engine.t(), Audio.t() | TranscriptionRequest.t(), keyword()) ::
        {:ok, TranscriptionResponse.t()}
        | {:error, EngineError.t() | ValidationError.t() | AudioAdapterError.t()}

@spec synthesize(Engine.t(), String.t() | SynthesisRequest.t(), keyword()) ::
        {:ok, SynthesisResponse.t()}
        | {:error, EngineError.t() | ValidationError.t() | AudioAdapterError.t()}
```

**Dispatch invariants** (mirror `generate_image/3`):

- Adapter-presence gate fires FIRST: `engine.audio_adapter == nil → {:error, %EngineError{reason: :no_audio_adapter}}`.
- Capability pre-flight runs SECOND (no-op when `llm_db` absent).
- Per-attempt `Retry.run/3` wraps the dispatch with the audio-side retry policy.
- `request_id` precedence: `opts[:request_id] > ALLM.Telemetry.request_id()`. Forwarded to the adapter via `opts[:request_id]`. After the call, `response.request_id` is filled from the forwarded id IFF the adapter left it `nil`.
- `:stream` opt is silently dropped (out of scope per phasing principle #2).
- Telemetry `:audio` span ALWAYS fires (start event even when adapter missing or pre-flight rejects).

### `ALLM.submit_transcription/3`, `ALLM.fetch_transcription/3`, `ALLM.await_transcription/3` (Layer C — sub-phase 19.6)

```elixir
@spec submit_transcription(Engine.t(), Audio.t() | TranscriptionRequest.t(), keyword()) ::
        {:ok, TranscriptionJob.t()}
        | {:error, EngineError.t() | ValidationError.t() | AudioAdapterError.t()}

@spec fetch_transcription(Engine.t(), TranscriptionJob.t() | String.t(), keyword()) ::
        {:ok, TranscriptionJob.t()}
        | {:error, EngineError.t() | ValidationError.t() | AudioAdapterError.t()}

@spec await_transcription(Engine.t(), TranscriptionJob.t() | String.t(), keyword()) ::
        {:ok, TranscriptionJob.t()}
        | {:error, EngineError.t() | ValidationError.t() | AudioAdapterError.t()}
```

**Dispatch invariants:**

- All three gate FIRST on `engine.audio_adapter == nil → {:error, %EngineError{reason: :no_audio_adapter}}`.
- All three gate SECOND on `:transcribe_async not in adapter.supported_operations() → {:error, %AudioAdapterError{reason: :unsupported_operation}}` BEFORE I/O. (For `submit_transcription/3` only — `fetch_transcription/3` and `cancel_transcription/3` resolve against the in-hand job's `:provider` field rather than the engine's adapter, so a caller can hold a job from one engine and resolve it via another engine that points at the same adapter module.)
- All three fire telemetry `:audio` spans with `:operation` ∈ `[:transcribe_async, :fetch_transcription, :cancel_transcription]` and `:job_id` metadata.
- `await_transcription/3` is the ONLY one that's a polling helper, NOT a behaviour callback. Implemented in pure `lib/allm.ex` as a `Stream.iterate(...) |> Enum.find(...)` loop calling `fetch_transcription/3` with backoff. Default backoff: `[1_000, 2_000, 5_000, 10_000, 30_000]` ms then steady-state 30s. Default cap: 1 hour wall-clock. Both overridable via `opts[:poll_intervals_ms]` and `opts[:timeout_ms]`. Surfaces `{:error, %AudioAdapterError{reason: :timeout}}` on cap exceed.
- `await_transcription/3` short-circuits when `job.status` lands in `[:completed, :failed, :cancelled]` (terminal states).
- When a caller passes a `String.t()` (raw job id) to `fetch_transcription/3` / `cancel_transcription/3` / `await_transcription/3`, the `engine.audio_adapter` is used as the resolver — the caller is asserting "this id belongs to the engine's adapter."

**Why a polling helper, not a callback:** Polling intervals are application-level policy (a real-time captioning UI polls every 1s; a nightly batch job polls every 60s). Folding policy into the adapter is wrong. `await_transcription/3` lives at Layer C so callers can override it without forking the adapter — same pattern as `chat/3` being a Layer C reducer over `step/3` rather than an adapter callback.

### Test-observable claims

| Claim | Verification |
|-------|--------------|
| `lib/allm/image_adapter.ex` exists and defines `generate/2` + `supported_operations/0` (the pattern `AudioAdapter` mirrors) | Verified against committed source on 2026-05-03 (file present at the cited path). |
| `lib/allm/engine.ex:395` has the `restore_module/1` decode site for `image_adapter` (pattern `audio_adapter` extends) | Verified on 2026-05-03 (`grep image_adapter lib/allm/engine.ex` confirms line 395 is the `__from_tagged__/1` site). |
| `lib/allm.ex` has `do_generate_image/3` retry-augmenter at line ~815 + `@retryable_image_reasons` at line 787 | Verified on 2026-05-03. |
| `examples/10_generate_image.exs` uses `# Provider: openai` header marker for the `run_all.exs` skip gate | Verified on 2026-05-03 against committed source. |
| MP3 magic-number byte sequences (`<<0xFF, 0xFB>>`, `<<0xFF, 0xF3>>`, `<<0xFF, 0xF2>>`) | Verified per [MPEG-1/2/2.5 Layer 3 frame header spec](http://www.mp3-tech.org/programmer/frame_header.html). ID3v2 header prefix per [id3.org spec](https://id3.org/id3v2.3.0). |
| OpenAI Whisper response `verbose_json` shape includes `segments[]` with `id`, `start`, `end`, `text`, `avg_logprob`, `compression_ratio`, `no_speech_prob` | Verified per OpenAI docs `https://platform.openai.com/docs/api-reference/audio/createTranscription` as of 2026-05-03. |
| OpenAI TTS `Content-Type` headers per format: `audio/mpeg` (mp3), `audio/opus`, `audio/aac`, `audio/flac`, `audio/wav`, `audio/pcm` | Verified per OpenAI docs as of 2026-05-03. |
| Whisper supports `:transcribe` (`/v1/audio/transcriptions`) + `:translate` (`/v1/audio/translations`); TTS supports `:synthesize` (`/v1/audio/speech`) | Verified per OpenAI API reference as of 2026-05-03. |

## Module Tree

```
lib/allm/
├── audio.ex                              (NEW — 19.1, %Audio{} struct + constructors)
├── transcription_request.ex              (NEW — 19.1)
├── transcription_response.ex             (NEW — 19.1, incl. `words` field)
├── transcription_job.ex                  (NEW — 19.6, async job struct)
├── synthesis_request.ex                  (NEW — 19.1, incl. `instructions` field)
├── synthesis_response.ex                 (NEW — 19.1)
├── audio_usage.ex                        (NEW — 19.1)
├── audio_adapter.ex                      (NEW — 19.2, behaviour; 19.6 adds 3 optional async callbacks)
├── engine.ex                             (MODIFY — 19.1, add :audio_adapter field + decode)
├── validate.ex                           (MODIFY — 19.1, transcription_request/1 + synthesis_request/1; 19.6 adds transcription_job/1)
├── capability.ex                         (MODIFY — 19.4, add preflight_audio/2)
├── allm.ex                               (MODIFY — 19.3 sync facade; 19.6 async facade — submit/fetch/await)
├── error/
│   ├── audio_adapter_error.ex            (NEW — 19.2, closed-reason error type; 19.6 adds :job_not_found, :job_expired)
│   └── engine_error.ex                   (MODIFY — 19.3, add :no_audio_adapter reason)
└── providers/
    ├── fake_audio.ex                     (NEW — 19.2; 19.6 extends with submit_transcription queue + job-id store)
    └── openai/
        └── audio.ex                      (NEW — 19.5, sync only — does NOT implement async callbacks)

test/allm/
├── audio_test.exs                        (NEW — 19.1)
├── transcription_request_test.exs        (NEW — 19.1)
├── transcription_response_test.exs       (NEW — 19.1, incl. words + speaker fields)
├── transcription_job_test.exs            (NEW — 19.6, ETF/JSON round-trip + status enum + result/error mutual-exclusion validator)
├── synthesis_request_test.exs            (NEW — 19.1, incl. instructions field)
├── synthesis_response_test.exs           (NEW — 19.1)
├── audio_usage_test.exs                  (NEW — 19.1)
├── allm_audio_facade_test.exs            (NEW — 19.3, transcribe/3 + synthesize/3)
├── allm_audio_async_facade_test.exs      (NEW — 19.6, submit/fetch/await/cancel against FakeAudio)
├── capability_audio_test.exs             (NEW — 19.4)
├── error/
│   └── audio_adapter_error_test.exs      (NEW — 19.2)
└── providers/
    ├── fake_audio_test.exs               (NEW — 19.2; 19.6 extends with async-script tests)
    └── openai/
        └── audio_test.exs                (NEW — 19.5, wire fixtures + live smoke)

test/support/
├── audio_adapter_conformance.ex          (NEW — 19.2; 19.6 adds opt-in :async conformance suite)
└── fake_audio_fixtures.ex                (NEW — 19.2, ≥9 named fixtures; 19.6 adds 3 async fixtures)

test/fixtures/
├── audio/
│   ├── README.md                         (NEW — 19.5/19.7, fixture provenance)
│   └── hello_world.mp3                   (NEW — 19.5/19.7, ~50 KB committed binary)
└── openai/
    └── audio/
        ├── recorded/                     (NEW — 19.5, recorded wire response fixtures, incl. diarize sample)
        └── synthesized/                  (NEW — 19.5, synthesized error/edge fixtures)

scripts/
└── record_openai_audio_fixtures.exs      (NEW — 19.5, recorder script per CLAUDE.md)

examples/
├── 16_transcribe.exs                     (NEW — 19.7, OpenAI-only)
├── 17_synthesize.exs                     (NEW — 19.7, OpenAI-only, uses gpt-4o-mini-tts)
├── _helpers.exs                          (MODIFY — 19.7, add `audio_engine/1` helper analogous to `image_engine/1`)
└── README.md                             (MODIFY — 19.7, append two table rows)

steering/
└── allm_engine_session_streaming_spec_v0_2.md   (MODIFY — 19.7, NEW §36 "Audio I/O" incl. §36.6 async/batch surface)

CHANGELOG.md                              (MODIFY — 19.7, seven bullets)
```

**Path-existence check:** `ls test/allm/error/`, `ls test/allm/providers/openai/`, `ls test/support/`, `ls test/fixtures/openai/`, `ls scripts/`, `ls examples/` all exist at HEAD on 2026-05-03. `test/fixtures/audio/` is NEW (parent `test/fixtures/` exists).

**Module Tree completeness:** 36 entries (29 from 19.1–19.5/19.7 + 7 added by 19.6's async surface: `transcription_job.ex` + `allm_audio_async_facade_test.exs` + `transcription_job_test.exs` + four extends to existing files); expected `git diff --stat` count of 36 ± 1 (CHANGELOG is the typical off-by-one).

## Phases

### Phase 19.1: Layer A — Audio data structs + facade constructors

**Goal:** Ship six new Layer A structs plus the engine `:audio_adapter` field and validators. Zero behavior change for v0.3 callers.

**Spec sections:** §36.2 (data structs), §36.4 (engine field).

#### 19.1.1 Test Plan (write first)

`test/allm/audio_test.exs`:
- `Audio.from_file/1 sets source: {:file, path} and mime_type from extension`
- `Audio.from_binary/2 sets source: {:binary, bytes} and explicit mime_type`
- `Audio.from_url/1 does NOT fetch — returns {:url, _}` (bans eager I/O)
- `Audio.to_binary({:file, path}) reads via File.read/1`
- `Audio.to_binary({:url, _}) returns {:error, :remote_source}`
- `Audio struct round-trips through :erlang.term_to_binary/1` (all four source shapes)
- `Audio struct round-trips through Jason.encode!/1 → Serializer.from_json!/1`

`test/allm/transcription_request_test.exs`:
- happy-path construction + ETF/JSON round-trip
- defaults: `operation: :transcribe`, `response_format: :json`, `temperature: nil`
- `Validate.transcription_request/1` accepts a valid request
- `Validate.transcription_request/1` rejects `temperature: 1.5` with `:invalid_temperature`
- `Validate.transcription_request/1` rejects non-string `language`

`test/allm/synthesis_request_test.exs`:
- happy-path + ETF/JSON round-trip
- defaults: `format: :mp3`, `voice: nil`, `speed: nil`
- `Validate.synthesis_request/1` rejects empty `text`
- `Validate.synthesis_request/1` rejects `speed: 0.1` with `:invalid_speed` (OpenAI's range is 0.25–4.0)

`test/allm/transcription_response_test.exs` + `synthesis_response_test.exs` + `audio_usage_test.exs` — happy-path construction + ETF/JSON round-trip + nullable-field handling.

`test/allm/engine_test.exs` (extend existing):
- `Engine.new(audio_adapter: ALLM.Providers.FakeAudio)` populates the field
- `Engine` round-trips through ETF + JSON with `audio_adapter:` populated
- `Engine` round-trips with `audio_adapter: nil` (default; backwards-compatible)
- `Engine.__from_tagged__/1` decodes `"audio_adapter"` via `restore_module/1` at the existing site

#### 19.1.2 Implementation Checklist

- [ ] Create `lib/allm/audio.ex` mirroring `lib/allm/image.ex` (constructors, `to_binary/1`, `defstruct`, `__from_tagged__/1`, Jason encoder)
- [ ] Create `lib/allm/transcription_request.ex` + `transcription_response.ex` + `synthesis_request.ex` + `synthesis_response.ex` + `audio_usage.ex` (full Layer A pattern: typespec, defstruct, `new/1`, `__from_tagged__/1`, Jason encoder)
- [ ] Add `audio_adapter: module() | nil` field to `lib/allm/engine.ex` (`@type t`, `defstruct`, `__from_tagged__/1` at the existing `restore_module/1` site at `engine.ex:395`)
- [ ] Add `transcription_request/1` and `synthesis_request/1` clauses to `lib/allm/validate.ex` returning `:ok | {:error, %ValidationError{}}`
- [ ] Add Engine `@moduledoc` bullet about `:audio_adapter`
- [ ] Add `audio/2`, `transcription_request/2`, `synthesis_request/2` constructor sugar to `lib/allm.ex` (no dispatch — these are pure Layer A facades). Sub-phase 19.3 wires `transcribe/3` and `synthesize/3`.

#### 19.1.3 Verification

```bash
mix test test/allm/audio_test.exs test/allm/transcription_request_test.exs test/allm/synthesis_request_test.exs test/allm/transcription_response_test.exs test/allm/synthesis_response_test.exs test/allm/audio_usage_test.exs
mix test test/allm/engine_test.exs   # existing tests must still pass
mix test                              # full suite
mix credo --strict
mix dialyzer
mix format --check-formatted
```

### Phase 19.2: `ALLM.AudioAdapter` behaviour + `FakeAudio` + conformance

**Goal:** Behaviour declaration, conformance suite, and the deterministic `ALLM.Providers.FakeAudio` reference implementation.

**Spec sections:** §36.3 (behaviour), §36.8 (FakeAudio).

#### 19.2.1 Test Plan (write first)

`test/support/audio_adapter_conformance.ex` — assertions per Decision #1 / §36.3 invariants:
- `transcribe/2 with operation not in supported_operations() returns {:error, %AudioAdapterError{reason: :unsupported_operation}} BEFORE any I/O`
- `synthesize/2 against an adapter without :synthesize in supported_operations() rejects pre-I/O`
- `transcribe/2 preserves opts[:request_id] onto response.request_id`
- `transcribe/2 round-trips request.metadata onto response.metadata when adapter has no use for it`
- Same three for `synthesize/2`
- `transcribe/2 honors opts[:request_timeout] producing {:error, %AudioAdapterError{reason: :timeout}}` on exceed (FakeAudio simulates with `:timer.sleep/1` in script)

`test/allm/providers/fake_audio_test.exs`:
- `FakeAudio.script(transcribe: [{:ok, %TranscriptionResponse{text: "hi"}}])` then `transcribe/2` returns the scripted response
- `FakeAudio.script(synthesize: [...])` similarly
- exhausted-script case returns `{:error, %AudioAdapterError{reason: :no_scripted_response}}`
- model-aware unsupported_operation simulation
- script supports both `:transcribe` and `:synthesize` queues independently
- `FakeAudio.supported_operations/0` returns `[:transcribe, :translate, :synthesize]` by default; `script(supported_operations: [:transcribe])` overrides

`test/allm/error/audio_adapter_error_test.exs`:
- closed-reason enum has 10 atoms (per the deliverable list)
- `new/2` constructs with reason + opts
- ETF/JSON round-trip preserves the struct

#### 19.2.2 Implementation Checklist

- [ ] Create `lib/allm/audio_adapter.ex` with three required callbacks + one optional (`prepare_request/2`)
- [ ] Create `lib/allm/error/audio_adapter_error.ex` mirroring `lib/allm/error/image_adapter_error.ex` (closed reason enum, defexception, ETF/JSON round-trip)
- [ ] Create `lib/allm/providers/fake_audio.ex` with process-local script store (matches `FakeImages` pattern at `lib/allm/providers/fake_images.ex` — Process.put under namespaced key)
- [ ] Create `test/support/audio_adapter_conformance.ex` as a `defmacro __using__/1` macro suite (matches `test/support/image_adapter_conformance.ex` pattern)
- [ ] Create `test/support/fake_audio_fixtures.ex` with ≥7 named scripted fixtures
- [ ] Wire `FakeAudio` into the conformance suite — it MUST pass unchanged

#### 19.2.3 Verification

```bash
mix test test/allm/providers/fake_audio_test.exs
mix test test/allm/error/audio_adapter_error_test.exs
mix test                              # full suite (conformance via FakeAudio runs here)
mix credo --strict lib/allm/audio_adapter.ex lib/allm/providers/fake_audio.ex lib/allm/error/audio_adapter_error.ex
mix dialyzer
```

### Phase 19.3: `ALLM.transcribe/3` + `ALLM.synthesize/3` facade + `:no_audio_adapter`

**Goal:** Layer C dispatch — engine + request → adapter call → typed response. Drives `FakeAudio` end-to-end.

**Spec sections:** §36.4 (engine wiring), §36.5 (public API).

#### 19.3.1 Test Plan (write first)

`test/allm/allm_audio_facade_test.exs`:
- `transcribe/3 with engine.audio_adapter == nil returns {:error, %EngineError{reason: :no_audio_adapter}}`
- `transcribe/3 with FakeAudio script returns the scripted %TranscriptionResponse{}`
- `transcribe/3 accepts %Audio{} as second arg → constructs default request internally`
- `transcribe/3 accepts %TranscriptionRequest{} as second arg → dispatches verbatim`
- `transcribe/3 forwards opts[:model] override onto request.model when caller didn't set it on the request`
- `transcribe/3 silently drops opts[:stream] (Decision: no streaming in v0.4)`
- `synthesize/3 with engine.audio_adapter == nil returns :no_audio_adapter`
- `synthesize/3 accepts String.t() text → constructs default request`
- `synthesize/3 accepts %SynthesisRequest{} → dispatches verbatim`
- `synthesize/3 honors opts[:request_id]; otherwise generates one via Telemetry.request_id/0`
- `synthesize/3 fills response.request_id from opts[:request_id] when adapter left it nil`

#### 19.3.2 Implementation Checklist

- [ ] Add `:no_audio_adapter` to `lib/allm/error/engine_error.ex` reason enum (closed)
- [ ] Add `transcribe/3` and `synthesize/3` to `lib/allm.ex` mirroring `do_generate_image/3` shape: telemetry span wrapper → adapter-presence gate → capability pre-flight (sub-phase 19.4 lands the actual gate; for now it's `:ok` placeholder) → retry-wrapped dispatch
- [ ] `drop_audio_request_opts/1` private helper analogous to `drop_request_opts/1` at `lib/allm.ex:794`
- [ ] Both dispatch functions use the same `with`-chain as `do_generate_image_body/4`
- [ ] Doctests on `transcribe/3` and `synthesize/3` against `FakeAudio` (no API key)

#### 19.3.3 Verification

```bash
mix test test/allm/allm_audio_facade_test.exs
mix test                              # full suite
mix credo --strict lib/allm.ex
mix dialyzer
```

### Phase 19.4: Telemetry + capability pre-flight + retry

**Goal:** Cross-cutting concerns mirror image-side patterns from `lib/allm.ex:776-973` verbatim, renamed `:image → :audio`.

**Spec sections:** §36.9 (telemetry), §36.4 (capability gate via `supported_operations/0`).

#### 19.4.1 Test Plan (write first)

- `[:allm, :audio, :start]` event fires on every `transcribe/3` / `synthesize/3` call (success + error paths)
- `[:allm, :audio, :stop]` event fires after the call with `:duration` measurement
- start metadata includes `:request_id, :operation, :model, :audio_bytes` for STT (`:text_length` for TTS)
- stop metadata includes `:usage, :response, :error` (mirrors image-side at `lib/allm.ex:954-973`)
- `Capability.preflight_audio/2` returns `:ok` when `llm_db` absent (no-op smoke test)
- `Capability.preflight_audio/2` returns `{:error, %ValidationError{reason: :unsupported_capability}}` when `llm_db` is loaded AND model lacks the operation
- `Retry.run/3` engages on `:rate_limited`, `:provider_unavailable`, `:timeout`, `:network_error` `AudioAdapterError`s (FakeAudio's `retry_until_call: n` simulates)

#### 19.4.2 Implementation Checklist

- [ ] Wrap `transcribe/3` body in `Telemetry.span(:audio, ...)` — every Telemetry-span exit produces `{result, measurements, extras}` (matches `do_generate_image/3` at `lib/allm.ex:827-832`)
- [ ] `audio_stop_extras/1` private helper (mirrors `image_stop_extras/1`)
- [ ] `@retryable_audio_reasons` module attribute mirroring `@retryable_image_reasons` at `lib/allm.ex:787`
- [ ] `augment_audio_retry_policy/1` mirroring `augment_image_retry_policy/1` at `lib/allm.ex:921-933`
- [ ] `dispatch_audio_attempt/3` per-attempt closure mirroring `dispatch_image_attempt/3` at `lib/allm.ex:935-948`
- [ ] Add `preflight_audio/2` clause to `lib/allm/capability.ex` — when `llm_db` absent: `:ok`; when present: dispatch to catalog's audio capability lookup
- [ ] Update `transcribe/3` / `synthesize/3` dispatch chain to call `preflight_audio/2` between adapter-presence gate and retry-wrapped dispatch (mirrors image at `lib/allm.ex:855`)

#### 19.4.3 Verification

```bash
mix test test/allm/allm_audio_facade_test.exs   # extends with telemetry + retry assertions
mix test test/allm/capability_audio_test.exs
mix test                              # full suite
mix credo --strict
mix dialyzer
```

### Phase 19.5: `ALLM.Providers.OpenAI.Audio` real adapter

**Goal:** First real network adapter — Whisper STT + OpenAI TTS.

**Spec sections:** §36.7.

#### 19.5.1 Test Plan (write first)

`test/allm/providers/openai/audio_test.exs`:
- `transcribe/2` against `whisper-1`: happy path with `response_format: :json` returns `%TranscriptionResponse{text: ...}`
- `transcribe/2` with `response_format: :verbose_json` populates `segments` + `language` + `duration`
- `transcribe/2` with `operation: :translate` hits `/v1/audio/translations` (URL distinct from `/transcriptions`)
- `transcribe/2` against `gpt-4o-mini-transcribe` populates `usage` with token fields (this model bills per token; whisper-1 bills per second)
- `synthesize/2` against `tts-1`: happy path returns `%SynthesisResponse{audio: bytes, format: :mp3}`
- `synthesize/2` with `format: :wav`, `:opus`, `:flac`, `:aac`, `:pcm` — five separate fixtures
- 429 with `Retry-After`: surfaces `%AudioAdapterError{reason: :rate_limited, retry_after_ms: N}`
- 5xx: `%AudioAdapterError{reason: :provider_unavailable}`
- malformed response (non-audio body when audio expected): `:internal_error`
- multipart/form-data construction for `/transcriptions`: file payload + form fields
- URL-source `Audio` for `transcribe/2`: adapter eagerly downloads (per principle #8 — boundary I/O OK)
- conformance suite passes unchanged

`test/fixtures/openai/audio/recorded/` — wire fixtures recorded once via `scripts/record_openai_audio_fixtures.exs`. ~10 fixtures total.

`test/fixtures/openai/audio/synthesized/` — synthesized error fixtures with `_comment: "Synthesized — Phase 19.5..."` markers per CLAUDE.md.

**LIVE smoke test** (gated on `OPENAI_API_KEY`, `@tag :live_openai`):
- `transcribe/2` against `whisper-1` using `test/fixtures/audio/hello_world.mp3` — asserts `text` contains `"hello"` (case-insensitive). Cost: ~$0.001/run.
- `synthesize/2` against `tts-1` with text `"hello world"` and `voice: "alloy"` — asserts `audio` starts with the MP3 magic header. Cost: ~$0.001/run.

#### 19.5.2 Implementation Checklist

- [ ] Create `lib/allm/providers/openai/audio.ex` implementing `ALLM.AudioAdapter`
- [ ] `transcribe/2` dispatches on `request.operation` to `/v1/audio/transcriptions` or `/v1/audio/translations`
- [ ] **Pre-flight `:audio_too_large` check** in `transcribe/2` BEFORE multipart construction: resolve `request.audio` to bytes via `Audio.to_binary/1` (or eager URL download), then `byte_size(bytes) > 25 * 1024 * 1024 → {:error, %AudioAdapterError{reason: :audio_too_large, metadata: %{byte_size: n, limit: 26214400}}}`. Whisper's documented hard limit per OpenAI docs (verified 2026-05-03). Mapped from provider 413 responses as defense-in-depth at the wire layer.
- [ ] Multipart/form-data builder for the audio file payload + form fields (`model`, `language`, `prompt`, `response_format`, `temperature`)
- [ ] URL-source eager download via `Req.get!/2` at request-build time (boundary I/O — principle #8). On fetch failure: `{:error, %AudioAdapterError{reason: :network_error, metadata: %{stage: :url_fetch, url: url, cause: term}}}` — distinguishes from generic transport errors via the `:stage` discriminator.
- [ ] Response decoder handles `:json`, `:verbose_json`, `:text`, `:srt`, `:vtt` formats — `verbose_json` populates `segments`
- [ ] `synthesize/2` POSTs JSON body to `/v1/audio/speech` with `model`, `input` (text), `voice`, `response_format` (mapping `:mp3 → "mp3"`, `:pcm → "pcm"`, etc.), `speed`
- [ ] Response body is raw audio bytes; `Content-Type` header maps to `format` atom
- [ ] `usage` mapping: Whisper response carries no usage by default but `verbose_json` includes `duration` — surface as `input_seconds`. For `gpt-4o-mini-transcribe` parse `usage.input_tokens` + `usage.output_tokens` if present (deferred billing concern). TTS has no usage in response — compute `character_count` from `request.text` length client-side.
- [ ] HTTP error mapping table: 401 → `:authentication_failed`; 429 → `:rate_limited`; 5xx → `:provider_unavailable`; timeout → `:timeout`; transport error → `:network_error`
- [ ] Conformance suite invocation in the test file (one-line `use ALLM.Test.AudioAdapterConformance, adapter: ALLM.Providers.OpenAI.Audio`)
- [ ] Recorder script `scripts/record_openai_audio_fixtures.exs` — refuses to overwrite files lacking the `_comment: "Synthesized..."` marker (per CLAUDE.md)

#### 19.5.3 Verification

```bash
mix test test/allm/providers/openai/audio_test.exs
mix test test/allm/providers/openai/audio_test.exs --include live_openai   # live smoke
mix test                              # full suite
mix credo --strict lib/allm/providers/openai/audio.ex
mix dialyzer
```

### Phase 19.6: Async/batch STT surface — `TranscriptionJob` + 3 optional adapter callbacks + 3 facade functions

**Goal:** Ship the contract that lets future third-party adapters (AssemblyAI, AWS Transcribe, GCP `LongRunningRecognize`, Azure Speech Batch, Deepgram with callback URL, Rev.ai) implement async/batch STT against a stable `ALLM.AudioAdapter` extension. **No real-provider implementation in this sub-phase** — the OpenAI bundled adapter from 19.5 stays sync-only because OpenAI Batch does not support `/v1/audio/*` (Decision #14, verified via context7 against the Batch endpoint enumeration on 2026-05-06). The `FakeAudio` adapter implements the async surface so the conformance suite, facade tests, and downstream packages have a working reference.

**Why ship this in v0.4 and not v0.5?** Adding optional callbacks to an already-shipped behaviour is non-breaking; flipping a sync-only contract to require async support later is breaking for every downstream third-party package built against v0.4. Per Decision #14, the contract MUST land in the same v-number as the behaviour itself.

**Spec sections:** §36.6 (public async API), §36.3 (behaviour callback extensions), §36.8 (FakeAudio async script extension).

#### 19.6.1 Test Plan (write first)

`test/allm/transcription_job_test.exs`:
- happy-path construction with all five status atoms; `@enforce_keys [:id, :status, :provider]` raises on missing
- ETF round-trip preserves all fields (DateTime, error struct, request struct, result struct)
- JSON round-trip via Jason.encode!/Serializer.from_json! — DateTime fields serialize as ISO-8601, decode back to DateTime; provider atom serializes as string + decodes via `restore_module/1`
- Validator: `status: :completed` with `result: nil` rejected with `:result_missing`
- Validator: `status: :failed` with `error: nil` rejected with `:error_missing`
- Validator: `status: :completed` with both `result:` AND `error:` rejected with `:result_error_conflict`

`test/allm/providers/fake_audio_test.exs` (extended):
- `FakeAudio.script(submit_transcription: [{:ok, %TranscriptionJob{id: "job_1", status: :queued, provider: ALLM.Providers.FakeAudio}}])` — submit returns the scripted job
- `FakeAudio.script(fetch_transcription: %{"job_1" => [{:ok, queued_job}, {:ok, processing_job}, {:ok, completed_job}]})` — three sequential fetches transition the job through the lifecycle. The map-keyed-by-id form (vs. a flat queue) lets one process script multiple concurrent jobs.
- exhausted fetch script returns `{:error, %AudioAdapterError{reason: :no_scripted_response}}`
- `FakeAudio.cancel_transcription/2` against an unknown id returns `{:error, %AudioAdapterError{reason: :job_not_found}}`
- `FakeAudio.supported_operations/0` returns `[:transcribe, :translate, :synthesize, :transcribe_async]` by default; `script(supported_operations: [:transcribe])` overrides to drop async

`test/support/audio_adapter_conformance.ex` (extended with opt-in `:async` mode):
- `submit_transcription/2 returns {:ok, %TranscriptionJob{}} with non-empty :id and :status ∈ [:queued, :processing]`
- `submit_transcription/2 with operation: :translate routes through if adapter supports both translate AND transcribe_async`
- `fetch_transcription/2 with raw String.t() id resolves the same as with %TranscriptionJob{}`
- `fetch_transcription/2 on a nonexistent id returns :job_not_found pre-I/O if adapter has a local job store, OR maps provider 404 → :job_not_found`
- `cancel_transcription/2 transitions status to :cancelled`
- `cancel_transcription/2 on a terminal-state job (:completed, :failed, :cancelled) returns the job unchanged with no error` — idempotency
- adapter that does NOT advertise `:transcribe_async` short-circuits `submit_transcription/2` calls with `{:error, %AudioAdapterError{reason: :unsupported_operation}}` BEFORE I/O

`test/allm/allm_audio_async_facade_test.exs`:
- `submit_transcription/3 with engine.audio_adapter == nil → {:error, %EngineError{reason: :no_audio_adapter}}`
- `submit_transcription/3 with adapter that doesn't advertise :transcribe_async → {:error, %AudioAdapterError{reason: :unsupported_operation}}` (verified against `OpenAI.Audio` from sub-phase 19.5)
- `submit_transcription/3 with FakeAudio script → {:ok, %TranscriptionJob{}}`
- `submit_transcription/3 accepts `%Audio{}` second arg (default request) and `%TranscriptionRequest{}` second arg (verbatim dispatch)
- `fetch_transcription/3 with raw id resolves via engine.audio_adapter`
- `fetch_transcription/3 with %TranscriptionJob{}` resolves via the in-hand `:provider` field — even when `engine.audio_adapter` differs (cross-engine resume)
- `await_transcription/3 polls until terminal state` (FakeAudio script returns `:queued` → `:processing` → `:completed` across three fetches)
- `await_transcription/3 honors opts[:timeout_ms]` — surfaces `:timeout` AudioAdapterError when cap exceeded
- `await_transcription/3 honors opts[:poll_intervals_ms]` — accepts `[100, 100, 100]` for fast tests; FakeAudio's clock isn't real-time but `Process.sleep/1` is honored
- telemetry `:audio` span with `:operation = :transcribe_async` fires on `submit_transcription/3`; `:fetch_transcription` on `fetch_transcription/3`; `:cancel_transcription` on `cancel_transcription/3`
- telemetry stop metadata includes `:job_id` and `:job_status`

#### 19.6.2 Implementation Checklist

- [ ] Create `lib/allm/transcription_job.ex` with `defstruct`, `@enforce_keys [:id, :status, :provider]`, `new/1`, `__from_tagged__/1` Jason encoder, DateTime ISO-8601 round-trip
- [ ] Add `:job_not_found` and `:job_expired` to `lib/allm/error/audio_adapter_error.ex` reason enum (closed)
- [ ] Add `transcription_job/1` clause to `lib/allm/validate.ex` enforcing `result`/`error`/`status` mutual exclusion
- [ ] Add three optional callbacks to `lib/allm/audio_adapter.ex`: `submit_transcription/2`, `fetch_transcription/2`, `cancel_transcription/2`
- [ ] Add `:transcribe_async` to the `supported_operations/0` callback's spec union type
- [ ] Extend `lib/allm/providers/fake_audio.ex` with `submit_transcription:` queue + `fetch_transcription:` map (keyed by job id) + a process-local job store
  - default `supported_operations/0` adds `:transcribe_async`
  - `submit_transcription/2` pulls from the queue, inserts the returned job into the local store under its id
  - `fetch_transcription/2` consumes from the per-id queue
  - `cancel_transcription/2` updates the local store to `:cancelled`; idempotent on terminal states; `:job_not_found` when id absent
- [ ] Add `submit_transcription/3`, `fetch_transcription/3`, `cancel_transcription/3`, `await_transcription/3` to `lib/allm.ex` mirroring sync-side dispatch (Telemetry span → engine gate → `:transcribe_async` op gate via `supported_operations/0` → adapter call)
- [ ] `await_transcription/3` is a polling loop: `Stream.iterate(0, & &1 + 1) |> Enum.reduce_while(...)` calling `fetch_transcription/3` with `Process.sleep(interval_ms)` between attempts; defaults `[1_000, 2_000, 5_000, 10_000, 30_000]` ms then steady-state 30s; `opts[:timeout_ms]` default 3_600_000 (1h); short-circuit on terminal status
- [ ] `dispatch_async_audio_attempt/3` per-attempt closure pattern matching `dispatch_audio_attempt/3` from 19.4; same `@retryable_audio_reasons` set applies (rate_limited, provider_unavailable, timeout, network_error)
- [ ] Telemetry: `[:allm, :audio, :start \| :stop]` carries `:operation` ∈ `[:transcribe_async, :fetch_transcription, :cancel_transcription]` plus `:job_id` and `:job_status` (`:job_status` on stop only); audio_stop_extras/1 helper extended to handle `%TranscriptionJob{}` results
- [ ] Extend `test/support/audio_adapter_conformance.ex` with an opt-in `:async` mode invoked as `use ALLM.Test.AudioAdapterConformance, adapter: MyAdapter, modes: [:async]` (default `modes: [:sync]` for adapters that don't support async)
- [ ] Doctests on `submit_transcription/3` + `fetch_transcription/3` + `await_transcription/3` against `FakeAudio` (no API key)

#### 19.6.3 Verification

```bash
mix test test/allm/transcription_job_test.exs
mix test test/allm/providers/fake_audio_test.exs
mix test test/allm/allm_audio_async_facade_test.exs
mix test                              # full suite — conformance via FakeAudio + sync-only OpenAI.Audio
mix credo --strict lib/allm/transcription_job.ex lib/allm.ex lib/allm/audio_adapter.ex lib/allm/providers/fake_audio.ex
mix dialyzer
```

**No live-API gate in 19.6** — there is no bundled async-capable adapter. The first live-gate of the async surface lands in a follow-on phase or third-party provider package.

### Phase 19.7: Examples + spec amendment + CHANGELOG

**Goal:** Live `examples/16_*` + `examples/17_*`, README "Audio" section, spec amendment introducing §36, CHANGELOG.

**Spec sections:** new §36.

#### 19.7.1 Test Plan (write first)

- `examples/16_transcribe.exs` — assert exit 0; assert printed output contains `OK: transcribe`. Provider gate: `# Provider: openai`.
- `examples/17_synthesize.exs` — assert exit 0; assert printed output contains `OK: synthesize`; assert MP3 magic header on the on-disk file.
- `examples/run_all.exs` — extend the script glob picks up `16_*` and `17_*` automatically (existing globbing pattern at `examples/run_all.exs` already does numeric-order discovery — verify at design time).
- `mix run examples/run_all.exs` exit 0 (BLOCKING `/review` gate per CLAUDE.md).

#### 19.7.2 Implementation Checklist

- [ ] Author `examples/16_transcribe.exs` — uses `ExamplesHelpers.audio_engine/1` with `:operation = :transcribe`, transcribes the committed `test/fixtures/audio/hello_world.mp3`, asserts `text` contains `"hello"` (case-insensitive). Default model: `whisper-1` (cheapest, broadest support); a commented-out `# model: "gpt-4o-transcribe"` line shows the upgrade path.
- [ ] Author `examples/17_synthesize.exs` — synthesizes `"ALLM is a provider neutral library"` via `gpt-4o-mini-tts` (Decision #6a — newest TTS model with `instructions:` support), writes to `System.tmp_dir!() <> "/17_synthesize_<ts>.mp3"`, asserts MP3 magic header (per Decision #12 — three-byte-sequence check + ID3v2 prefix skip). Demonstrates `instructions: "Speak in a calm, professional tone."`
- [ ] Add `audio_engine/1` helper to `examples/_helpers.exs` (sister to `image_engine/1`; reads `:audio_adapter` + `:audio_transcribe_default_model` + `:audio_synthesize_default_model` from the `@providers` table; OpenAI defaults `whisper-1` for STT and `gpt-4o-mini-tts` for TTS; user passes `:operation` opt to discriminate which model default to apply)
- [ ] Extend the `@providers` map in `examples/_helpers.exs` with `audio_adapter:`, `audio_transcribe_default_model:`, `audio_synthesize_default_model:` keys on ALL THREE rows (`openai`, `anthropic`, `gemini` per `_helpers.exs:30/38/46`) — OpenAI gets real values; Anthropic and Gemini get explicit `nil` so `audio_engine/1` raises a clear `ArgumentError` when called under those providers (matches how `image_engine/1` handles Anthropic today)
- [ ] Update `examples/README.md` script table with two new rows
- [ ] Commit `test/fixtures/audio/hello_world.mp3` (~50 KB) + `test/fixtures/audio/README.md` documenting the source (`say "hello world"` on macOS, converted via `ffmpeg` to MP3)
- [ ] BLOCKING live-validation: `OPENAI_API_KEY=… mix run examples/run_all.exs` exit 0 (Anthropic arm runs unchanged, skips audio scripts via header gate)
- [ ] Capture stdout into `examples/RUN_OUTPUT_OPENAI.md` IFF the live run succeeded (per CLAUDE.md snapshot policy)
- [ ] Amend `steering/allm_engine_session_streaming_spec_v0_2.md` adding §36 (sub-sections per the spec coverage table — incl. §36.6 async/batch surface from 19.6). Cite Phase 19 commit at the inline amendment marker.
- [ ] Update README.md "Real providers" section to mention `ALLM.Providers.OpenAI.Audio` for STT + TTS, AND a "Async/batch STT" subsection naming the third-party adapter targets (AssemblyAI / AWS Transcribe / GCP / Azure / Deepgram / Rev.ai) without claiming any are bundled
- [ ] Update `CHANGELOG.md` with seven bullets under `## [Unreleased]`: data structs (19.1), behaviour + Fake (19.2), sync facade (19.3), telemetry/retry (19.4), real OpenAI provider (19.5), async/batch STT contract (19.6 — flagged as "behaviour-only, no real adapter"), examples + spec (19.7)

#### 19.7.3 Verification

```bash
mix test                                  # full suite
mix credo --strict
mix dialyzer
mix format --check-formatted
OPENAI_API_KEY=...     mix run examples/run_all.exs
ANTHROPIC_API_KEY=...  ALLM_PROVIDER=anthropic mix run examples/run_all.exs   # audio scripts skip; existing scripts unchanged
GEMINI_API_KEY=...     ALLM_PROVIDER=gemini    mix run examples/run_all.exs   # audio scripts skip; Gemini chat/image scripts run if present
# Per-clean-run cost projection: ~$0.003 OpenAI (one Whisper round-trip ~$0.001 + one gpt-4o-mini-tts round-trip ~$0.002 — slightly higher than tts-1).
```

## Test Plan (cross-phase summary)

- **Unit tests** — seven Layer A struct round-trip tests (19.1 + 19.6's `TranscriptionJob`); `FakeAudio` script + behaviour tests (19.2 + 19.6's async-script extension); sync facade dispatch (19.3); telemetry + capability + retry (19.4); OpenAI Audio wire fixtures (19.5); async facade dispatch + polling (19.6).
- **Behaviour conformance** — `ALLM.AudioAdapter` conformance suite (19.2); `FakeAudio` passes both `:sync` and `:async` modes; `OpenAI.Audio` passes `:sync` only (does not advertise `:transcribe_async`).
- **Integration tests** — `transcribe/3` + `synthesize/3` end-to-end against `FakeAudio` (19.3); against OpenAI live (19.5 BLOCKING). `submit_transcription/3` + `fetch_transcription/3` + `await_transcription/3` against `FakeAudio` only (19.6) — no live gate (no bundled async adapter).
- **Property tests** — none new (audio is not stream-equivalent — see Out-of-scope).
- **Doctests** — every new public function on `ALLM` (8 functions: 5 sync + 3 async + cancel) + `ALLM.Audio` constructors carry runnable doctests against `FakeAudio` (no API key).
- **Serializability** — every Layer A struct round-trips ETF + JSON (19.1 + `TranscriptionJob` 19.6).
- **Live examples** — `examples/16_*` + `examples/17_*` against OpenAI (19.7 BLOCKING).

**Cross-option × cross-path test matrix:**

| Row | `transcribe/3` cell | `synthesize/3` cell |
|-----|---------------------|---------------------|
| Default (`:json` STT / `:mp3` TTS) | 19.5 STT-1 | 19.5 TTS-1 |
| `:verbose_json` STT / `:wav` TTS | 19.5 STT-2 | 19.5 TTS-2 |
| `:text` STT / `:opus` TTS | 19.5 STT-3 | 19.5 TTS-3 |
| `:srt` STT / `:flac` TTS | 19.5 STT-4 | 19.5 TTS-4 |
| `:vtt` STT / `:aac` TTS | 19.5 STT-5 | 19.5 TTS-5 |
| `:translate` STT / `:pcm` TTS | 19.5 STT-6 | 19.5 TTS-6 |

12 distinct cells × one wire fixture each (six STT + six TTS). Per AGENT_DESIGN_SPEC item 10 (cross-option × cross-path): both surfaces enumerate every legal `response_format` / `format`. Per AGENT_DESIGN_SPEC item 7 (case-count discipline): the count is `2 paths × 6 formats = 12` and matches the row enumeration.

**Async surface lifecycle matrix (sub-phase 19.6, FakeAudio only):**

| Row | Lifecycle | Test cell |
|-----|-----------|-----------|
| Submit → fetch returns `:queued` | `submit_transcription/3` then immediate `fetch_transcription/3` | 19.6 ASYNC-1 |
| Submit → fetch progresses `:queued → :processing → :completed` | three sequential fetches | 19.6 ASYNC-2 |
| Submit → fetch returns `:failed` (provider error) | one fetch lands terminal :failed with populated `:error` | 19.6 ASYNC-3 |
| Submit → cancel → fetch confirms `:cancelled` | cancel during `:queued` | 19.6 ASYNC-4 |
| Cancel on terminal-state job is idempotent | cancel after `:completed` | 19.6 ASYNC-5 |
| `fetch_transcription/3` on unknown id → `:job_not_found` | bare-string id route | 19.6 ASYNC-6 |
| `await_transcription/3` polls then returns terminal | three fetches with backoff `[100, 100, 100]` | 19.6 ASYNC-7 |
| `await_transcription/3` `opts[:timeout_ms]` exceeded → `:timeout` | poll loop exits with cap | 19.6 ASYNC-8 |

## Error Contract

`ALLM.Error.AudioAdapterError` reason enum (closed):

| Reason | Recovery guidance |
|--------|--------------------|
| `:rate_limited` | Provider 429; retry with backoff via `ALLM.Retry`. Surface `:retry_after_ms` if header present. |
| `:provider_unavailable` | 5xx; retry with backoff. |
| `:timeout` | Per-call timeout exceeded (default 60s for transcribe, 30s for synthesize). |
| `:network_error` | `Mint.TransportError` etc. Retry. |
| `:unsupported_operation` | Operation not in `supported_operations()`. Caller bug — fix dispatch. |
| `:unsupported_format` | Format not supported by model (e.g., `tts-1` doesn't support `:flac`). Caller bug. |
| `:audio_too_large` | Input audio exceeds provider limit (Whisper: 25 MB). Caller pre-processes (`ffmpeg` chunk). Fired BEFORE multipart construction by an explicit pre-flight check in `OpenAI.Audio.transcribe/2` (sub-phase 19.5 implementation checklist) AND mapped from provider 413 responses as a defense-in-depth backstop. |
| `:invalid_request` | 400 — request shape rejected by provider. Inspect `metadata.cause`. |
| `:authentication_failed` | 401 — key invalid. |
| `:internal_error` | Catch-all for malformed responses or unexpected adapter state. |
| `:network_error` (URL-source variant) | URL-source `Audio` download in `OpenAI.Audio.transcribe/2` failed. `metadata: %{stage: :url_fetch, url: url, cause: term}` discriminates from generic transport failures. |
| `:no_scripted_response` | `FakeAudio` script queue exhausted. Test-only — the Fake adapter emits this when `script(transcribe: [])` runs out of responses; production adapters never produce this reason. |
| `:job_not_found` | (sub-phase 19.6) `fetch_transcription/2` or `cancel_transcription/2` against an unknown job id. Provider 404, OR FakeAudio's local store rejected the id pre-I/O. Caller bug or job-id corruption. |
| `:job_expired` | (sub-phase 19.6) Provider's job retention window expired before the caller fetched the result (AssemblyAI: 30 days; AWS: configurable). Terminal — re-submit if the source audio is still available. |

`ALLM.Error.EngineError` enum extension:

| Reason | When |
|--------|------|
| `:no_audio_adapter` | `engine.audio_adapter == nil` and `transcribe/3`, `synthesize/3`, `submit_transcription/3`, `fetch_transcription/3`, or `cancel_transcription/3` called. |

`ALLM.Error.ValidationError` extensions for audio:

| Field path | Reason atom | Hard-reject? | Fires when |
|------------|-------------|--------------|------------|
| `[:transcription, :audio]` | `:missing` | yes | `request.audio == nil` |
| `[:transcription, :temperature]` | `:invalid_temperature` | no | `temperature < 0.0 or > 1.0` |
| `[:transcription, :language]` | `:invalid_type` | no | `language` not a binary |
| `[:synthesis, :text]` | `:empty` | yes | `text == ""` |
| `[:synthesis, :speed]` | `:invalid_speed` | no | `speed < 0.25 or > 4.0` |
| `[:synthesis, :voice]` | `:invalid_type` | no | `voice` not a binary |
| `[:synthesis, :instructions]` | `:invalid_type` | no | `instructions` not a binary |
| `[:transcription_job, :id]` | `:empty` | yes | `id == ""` (sub-phase 19.6) |
| `[:transcription_job, :status]` | `:invalid_status` | yes | `status` not in `[:queued, :processing, :completed, :failed, :cancelled]` (sub-phase 19.6) |
| `[:transcription_job, :result]` | `:result_missing` | yes | `status == :completed and result == nil` (sub-phase 19.6) |
| `[:transcription_job, :error]` | `:error_missing` | yes | `status == :failed and error == nil` (sub-phase 19.6) |
| `[:transcription_job, :result]` | `:result_error_conflict` | yes | both `result` and `error` populated simultaneously (sub-phase 19.6) |

## Streaming & Backpressure

Non-applicable to Phase 19 — no streaming. Per phasing principle #2 (transferred from images): streaming TTS and websocket STT are explicitly out of scope and deferred to v0.5. The v0.2 §3 stream-first invariant does NOT apply here.

## Definition of Done

- [ ] All 7 sub-phases marked `Completed`
- [ ] `mix test` zero failures, zero warnings, coverage ≥ 80 % global / ≥ 90 % on new files
- [ ] `mix credo --strict` zero issues on changed files
- [ ] `mix dialyzer` zero new warnings vs. v0.3.x PLT baseline
- [ ] `mix format --check-formatted` passes
- [ ] Every new public function has `@spec` and `@doc` with at least one runnable doctest using `FakeAudio` (no API key) — sync facade (5 fns: `transcribe/3`, `synthesize/3`, `audio/2`, `transcription_request/2`, `synthesis_request/2`) AND async facade (3 fns: `submit_transcription/3`, `fetch_transcription/3`, `await_transcription/3`, plus `cancel_transcription/3`)
- [ ] Every Layer A struct round-trips ETF + JSON (Audio, TranscriptionRequest, TranscriptionResponse, TranscriptionJob, SynthesisRequest, SynthesisResponse, AudioUsage)
- [ ] `ALLM.AudioAdapter` conformance suite passes against `FakeAudio` (sync + async modes) and `OpenAI.Audio` (sync mode only — does not advertise `:transcribe_async`)
- [ ] BLOCKING live-validation: `examples/run_all.exs` exit 0 against OpenAI (Anthropic arm unchanged, audio scripts skip; Gemini arm unchanged, audio scripts skip). Async surface has NO live gate (no bundled async-capable adapter).
- [ ] `examples/RUN_OUTPUT_OPENAI.md` regenerated in the same commit as the live run (per CLAUDE.md snapshot policy)
- [ ] **If live gate deferred** (implementer environment lacks `OPENAI_API_KEY`): CHANGELOG entry says verbatim "live-validation deferred to follow-up commit; recorder script ran offline" — NEVER paraphrase the future post-record state at commit time (per CLAUDE.md "five consecutive deferrals" pattern)
- [ ] Spec § amendment commit references the Phase 19 commit and cites file:lines
- [ ] CHANGELOG.md updated with seven bullets
- [ ] `test/fixtures/audio/hello_world.mp3` committed alongside `test/fixtures/audio/README.md` documenting provenance
- [ ] `scripts/record_openai_audio_fixtures.exs` committed and idempotent per CLAUDE.md
- [ ] Reviewed via `/review` (see `AGENT_REVIEW_SPEC.md` if present)

## Live-API cost estimation

Per `examples/16_transcribe.exs` + `examples/17_synthesize.exs`, OpenAI only. Async surface (sub-phase 19.6) has NO live cost — there is no bundled async-capable adapter.

| Provider | Per-script cost | Both scripts | Per-clean-run total | First-implementation (4× retry) |
|----------|-----------------|--------------|---------------------|----------------------------------|
| OpenAI Whisper (`whisper-1`) — 5-second clip | ~$0.0006 | — | — | — |
| OpenAI TTS (`gpt-4o-mini-tts`) — ~40 chars | ~$0.002 | — | — | — |
| **Both scripts (OpenAI arm only)** | — | ~$0.0026 | **~$0.003** | **~$0.012** |
| Anthropic arm — audio scripts skipped | — | — | $0 | $0 |
| Gemini arm — audio scripts skipped | — | — | $0 | $0 |

Adds ~$0.003 to the multi-provider `/review` pass; cumulative `/review` cost rises from ~$0.14 (post-Phase-18) to ~$0.143 per clean run. First-implementation cost uses 4× retry per AGENT_DESIGN_SPEC item 19. `gpt-4o-mini-tts` pricing as of 2026-05-06 (verified via context7 against OpenAI API reference); switch to `tts-1` (~$0.001) if cost-floor matters more than the `instructions:` parameter coverage.

## Cross-phase consistency check

- Every new struct + behaviour mirrors the image-side analogue's pattern (Phases 13–17), reducing reviewer cognitive load. Sub-phase 19.6's async surface is the one piece without an image-side analogue; its pattern (optional callbacks + Layer A job struct + Layer C polling helper) is justified independently in Decision #14 and is the natural Elixir-idiomatic shape for the AssemblyAI-class providers it's designed to slot under.
- Every spec § amendment cites a file:line in `lib/` (Decision text — `lib/allm.ex:787`, `lib/allm.ex:794`, `lib/allm.ex:815`, `lib/allm.ex:921-933`, `lib/allm/engine.ex:395`, `lib/allm/image_adapter.ex:55-82`)
- Hedge-word audit on this design — none found (every "should X" claim carries a citation or `(verified ... 2026-05-06)` annotation). Decisions #2, #14, #6a, #13, and the SynthesisRequest voice list and live-cost table all carry explicit `verified via context7 ... on 2026-05-06` annotations against the OpenAI API reference, the OpenAI Batch API endpoint enumeration, and the `/v1/audio/speech` voice catalog.
- Test-observable claims table at end of "Behaviour & Type Contracts" verified against committed source on 2026-05-06 (OpenAI Batch endpoint list, latest STT/TTS model IDs, voice catalog all confirmed via context7).
- Provider-neutral examples helper extension follows the canonical pattern at `examples/_helpers.exs` per CLAUDE.md item 18
- §31-style property scenarios DO NOT apply (audio is not stream-equivalent) — explicit non-applicability stated under "Streaming & Backpressure"
- **Async surface ships as contract-only in v0.4** (Decision #14): the OpenAI bundled adapter does NOT implement async because OpenAI Batch does not support `/v1/audio/*`; FakeAudio implements both modes; the first concrete async provider lands in a follow-on phase or third-party package. CHANGELOG entry MUST flag this honestly per CLAUDE.md "five consecutive deferrals" pattern — wording: "Async/batch STT contract shipped (TranscriptionJob struct + 3 optional AudioAdapter callbacks + 3 facade functions). No real-provider implementation in this release; OpenAI bundled adapter is sync-only because OpenAI Batch API does not support /v1/audio/* endpoints. Third-party adapters (AssemblyAI, AWS Transcribe, GCP, Azure, Deepgram, Rev.ai) implement against the stable contract."
