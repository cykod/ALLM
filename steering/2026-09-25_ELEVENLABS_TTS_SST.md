# Phase 26: ElevenLabs Audio and Streaming Speech (TTS + STT) — Design Document

*Generated 2026-09-25 · Measured against: `7499917`*

> **Goal:** Extend the Phase 25 audio family (§37) in two ways. Add streaming in both directions: audio out while it is synthesized, text in as an LLM produces it, and transcripts out while audio is still arriving. Also bundle an ElevenLabs adapter pair that implements the family's non-streaming and streaming behaviours.
> **Outcome:**
> - `ALLM.stream_synthesize(engine, "Hello.", voice: v)` returns `{:ok, events}`, and the first `{:audio_delta, bytes}` arrives before the provider has finished synthesizing. This works on OpenAI (chunked HTTP) and ElevenLabs (chunked HTTP).
> - `ALLM.stream_synthesize_input(engine, ALLM.AudioStream.text_deltas(chat_events), voice: v)` turns a live chat stream into audio over an ElevenLabs WebSocket.
> - `ALLM.stream_transcribe(engine, pcm_chunks, sample_rate: 16_000)` yields `{:partial_transcript, _}` / `{:committed_transcript, _}` events over the ElevenLabs realtime WebSocket.
> - `ALLM.synthesize/3` and `ALLM.transcribe/3` work unchanged against the new `ALLM.Providers.ElevenLabs.{Speech,Transcription}`.
> - `ALLM_PROVIDER=elevenlabs mix run examples/run_all.exs` exits 0.
> **Spec sections:** amends **§37** (new §37.11 *Streaming audio*; strike streaming and ElevenLabs from §37.10), **§35.7** (bundled-adapter rule: a scoped audio carve-out), **§27** (module tree) and **§29** (telemetry).
> **Layers touched:** A, B, C, one layer per sub-phase (see Status).

**Owner decisions recorded (2026-09-25).** These three questions went to the owner before the design was written. The design is written against their answers.
1. **Admission:** *"In core, amend §35.7."* ElevenLabs fails every current §35.7 criterion (Alternative H), so the design carries a new scoped carve-out (Decision #1).
2. **Streaming reach:** *"Full: HTTP + WebSocket."* This covers chunked-HTTP TTS, WebSocket text-in TTS, and WebSocket realtime STT. It adds the `:mint_web_socket` dependency and a new transport rule (Decision #3).
3. **Providers:** *"ElevenLabs + OpenAI TTS stream."* ElevenLabs gets every streaming path. `OpenAI.Speech` gains HTTP streaming. OpenAI STT streaming and OpenAI Realtime are out of scope.

**Number checks (run 2026-09-25 at `7499917`):**
- `grep -rn 'Phase 26' steering/*.md CLAUDE.md` → nothing. Phase 25 is audio (`da277bf..e66ca44`). Phase 24 belongs to the untracked, unbuilt `steering/2026-09-22_JEV_SUPPORT.md`. **This is Phase 26.**
- `grep -n '^## ' steering/allm_engine_session_streaming_spec_v0_2.md | tail -4` → `## 37.` (`:2757`), `## 39.` (`:2993`), `## 40.` (`:3381`). Streaming audio is a §37 extension, not a new section. JEV claims §41.
- `ls examples/` → the highest script is `24_transcribe_audio.exs`, and JEV claims `22`. This design takes **25, 26, 27**.
- `grep -o '^[A-Z_]*KEY[A-Z_]*' .env` → `OPENAI_API_KEY ANTHROPIC_API_KEY GEMINI_API_KEY VOYAGE_API_KEY`. **There is no `ELEVENLABS_API_KEY`.** Every ElevenLabs wire fact below therefore comes from docs, not from a probe (Prerequisites).

## Status

| Phase | Description | Layer | Status |
|-------|-------------|-------|--------|
| 26.1 | Refactor: extract `ALLM.Providers.Support.HTTPResponse` (the byte-identical provider HTTP helpers) and `ALLM.Providers.Support.TranscriptionAdapter` (the cloned STT-contract helpers), and migrate every copy | B | Not Started |
| 26.2 | Layer A: `SpeechEvent`, `TranscriptionEvent`, `TranscriptionStreamRequest`, `sample_rate` fields, `:unsupported_feature` reasons, validators | A | Not Started |
| 26.3 | Layer B: `SpeechStreamAdapter` + `TranscriptionStreamAdapter`, `Support.InputPump`, Fake streaming, three conformance suites | B | Not Started |
| 26.4 | Layer C: `stream_synthesize/3`, `stream_synthesize_input/3`, `stream_transcribe/3`, `ALLM.AudioStream`, spans + first-chunk event | C | Not Started |
| 26.5 | `OpenAI.Speech` HTTP streaming + recorder arms | B | Not Started |
| 26.6 | `ElevenLabs.Speech` + `ElevenLabs.Transcription` (non-streaming) + `Support.ElevenLabs` + recorder. **Hard stop: needs `ELEVENLABS_API_KEY` in `.env`** (26.6–26.9) | B | Not Started |
| 26.7 | WebSocket transport (`Support.WebSocket`) + ElevenLabs TTS streaming (HTTP and WebSocket input) | B | Not Started |
| 26.8 | ElevenLabs realtime STT (`stream_transcribe/3`) | B | Not Started |
| 26.9 | Spec §37.11 + §35.7 carve-out, guide, examples 25–27, `run_all.exs` chat-arm filter, `CLAUDE.md` transport rule, CHANGELOG | — | Not Started |
| 26.10 | `[CHORE]` sweep | — | Not Started |

Deviations, probe transcripts and closure ledgers go to `steering/2026-09-25_ELEVENLABS_TTS_SST_RECORDS.md`, which is created on first need.

---

## Assumptions

Assumptions that change the shape of the work are marked **★**.

1. **★ Streaming is additive. The non-streaming façades are not re-routed through it.** `synthesize/3` and `transcribe/3` shipped in Phase 25 as independent request/response paths. Every bundled provider uses a *different endpoint* for streaming (OpenAI: the same URL with chunked transfer, which is equivalent; ElevenLabs: `/stream`, `/stream-input` and `/speech-to-text/realtime`), and `Gemini.Transcription` has no streaming form at all. Stream-first (§3, `CLAUDE.md`) is honoured in its testable form: an equivalence property over the Fakes (26.4). See Alternative D.
2. **★ Streaming uses the same engine slot as its non-streaming sibling.** This is the chat precedent: one `:adapter` slot, and streaming is detected at `lib/allm/stream_runner.ex:173-174`: `defp check_stream_adapter(adapter) when is_atom(adapter) do` / `if Code.ensure_loaded?(adapter) and function_exported?(adapter, :stream, 2) do`. Streaming speech therefore uses `engine.speech_adapter`, and a module opts in by also implementing `ALLM.SpeechStreamAdapter`. **`ALLM.Engine` is not modified.** See Alternative C.
3. **★ Input-streaming arguments are enumerables, never struct fields.** A text chunk stream or a microphone PCM stream is not serializable (Layer A forbids funs and PIDs). It is a positional argument of the façade. The *configuration* of the session (model, voice, sample rate, commit strategy) is a Layer A struct.
4. **Every ElevenLabs wire fact is doc-sourced until the 26.6–26.8 probes run.** No key exists in `.env` (number checks). Each wire-map row carries `documented <URL>`, `UNVERIFIED`, or `inferred`, and every non-`CONFIRMED` row has a probe arm. The BLOCKING live gates in 26.6–26.9 need the owner to add `ELEVENLABS_API_KEY` to `.env` first.
5. **ElevenLabs API docs as fetched 2026-09-25.** Local markdown copies are in the session scratchpad and are not committed. Each wire-map row cites the doc URL.
6. **Default models favour latency.** `ElevenLabs.Speech` defaults to `eleven_flash_v2_5`, which ElevenLabs positions as its low-latency model (documented, https://elevenlabs.io/docs/models). The alternative `eleven_multilingual_v2` is the provider default and higher quality, but slower. The owner asked for *"as fast as possible"*. Callers pick quality with `speech_model:`.
7. **Release is out of scope.** `CHANGELOG.md:1` heads `[REL] v0.6.0`, unreleased; `mix.exs:4` `@version "0.5.0"`, and `git tag` ends at `v0.5.0`. If v0.6.0 is still unpublished at 26.9, this phase's lines join that entry. Publishing is the maintainer's `scripts/release.exs` run.

---

## Alternatives Considered

### A. How streamed audio reaches the caller

| Option | Trade-off |
|--------|-----------|
| A1: new variants on `ALLM.Event` (`{:audio_delta, _}`, …) | One event protocol. **Breaking for every reducer** (§8, `CLAUDE.md` "Adding a variant is breaking"): `StreamCollector`, `Session.StreamReducer`, and every user fold would have to handle audio variants that chat never emits. |
| A2: a bare `Enumerable.t(binary())` of audio bytes | Smallest. But there is nowhere to put the mime/sample rate before the first byte, the terminal usage/request id, or a mid-stream error except by raising. It also has no transcript shape. |
| **A3: two new closed unions, `ALLM.SpeechEvent` and `ALLM.TranscriptionEvent` (chosen)** | Non-breaking: nothing existing reduces them. Each carries a start envelope, deltas, one terminal, and a typed `{:error, _}`, which mirrors the `ALLM.Event` discipline. **Cost:** two more closed unions whose future variants are breaking for *their* reducers, a rule stated in both moduledocs. |

### B. WebSocket client

| Option | Trade-off |
|--------|-----------|
| **B1: `:mint_web_socket` (chosen)** | Process-less, so the Mint connection is owned by whichever process reduces the `Stream.resource/3`. That is the same ownership model as `Finch.async_request/3` on the chat path (`lib/allm/providers/openai.ex:862-863`), and the same cleanup story. Its one dependency, `mint ~> 1.4 and >= 1.4.1` (`mix hex.info mint_web_socket 1.0.6`, run 2026-09-25), is already locked at `1.7.1` via Finch (`mix.lock`), so no new transitive deps. Maintained by Mint's author; 1.0.6 released 2026-08-12. |
| B2: `:websockex` | Spawns its own GenServer per socket. Frames arrive in *its* process, so the stream would need a second hop and a second cleanup path. |
| B3: `:gun` | A full second HTTP stack beside Finch/Mint. |
| B4: hand-rolled RFC 6455 on `:ssl` | Framing, masking and close handshake re-implemented. Not worth it. |

### C. Where a streaming adapter plugs in

| Option | Trade-off |
|--------|-----------|
| **C1: same slot, opt-in behaviour, `function_exported?` gate (chosen)** | The chat precedent (Assumption 2). No engine change, and a serialized engine is unchanged. **Cost:** an engine cannot pair *non-streaming* OpenAI TTS with *streaming* ElevenLabs TTS. Nobody has asked for that. |
| C2: new slots `:speech_stream_adapter`, `:transcription_stream_adapter` | Maximum pairing freedom, but 11 engine sites each (the Phase 25 site table) and a serialization change, for a pairing with no user story. |

### D. Stream-first for the audio family

| Option | Trade-off |
|--------|-----------|
| D1: re-route `synthesize/3` / `transcribe/3` as reducers over the stream path | Literal §3 compliance. But `Gemini.Transcription` cannot stream, OpenAI STT streaming is out of scope, and a released façade's wire behaviour would change (a different ElevenLabs endpoint and different error timing). |
| **D2: independent paths plus a Fake-driven equivalence property (chosen)** | The released paths are untouched. `ALLM.AudioStream.collect_speech/1` / `collect_transcription/1` are the reducers, and a StreamData property asserts `synthesize ≡ stream_synthesize |> collect_speech` over `FakeSpeech` (26.4). The spec amendment says so explicitly. |

### E. OpenAI streaming framing

The owner's option text described OpenAI's SSE mode (`stream_format: "sse"`). **This design uses raw chunked audio instead, which is the endpoint's default `stream_format: "audio"`.**

| Option | Trade-off |
|--------|-----------|
| E1: `stream_format: "sse"` | Carries `usage` in `speech.audio.done` (Phase 25 design-time probe: `{"type":"speech.audio.done","usage":{"input_tokens":2,"output_tokens":43,"total_tokens":45}}`, `steering/2026-09-24_SST_SUPPORT.md:69`). **Costs:** base64 inflates every audio byte by 4/3; `"sse is not supported for tts-1 or tts-1-hd"` (OpenAI API reference, fetched 2026-09-25) would force model-name gating; and `stream_format` is a reserved option today (`lib/allm/providers/openai/speech.ex:27`). |
| **E2: raw chunked body (chosen)** | Fewer bytes on the wire, which serves the owner's latency goal. Works on every model, needs no SSE decode, and keeps `stream_format` reserved. Usage stays all-`nil`, exactly as on non-streaming OpenAI TTS (§37.2). The 26.5 probe must show the body really arrives in more than one chunk (arm `stream_chunked`). **If it does not, E1 becomes the fallback** and the probe halts for a design amendment. |

### F. Config for a realtime transcription session

| Option | Trade-off |
|--------|-----------|
| F1: reuse `TranscriptionRequest` with `audio: nil` + new fields | One struct. But `Validate.transcription_request/1` hard-rejects a nil audio (`lib/allm/validate.ex:486`), and batch-only fields (`prompt`) sit next to realtime-only ones (`sample_rate`, `commit_strategy`). |
| **F2: new `ALLM.TranscriptionStreamRequest` (chosen)** | Exactly the realtime fields. Serializable. Its own validator. |

### G. Text-in TTS API shape

| Option | Trade-off |
|--------|-----------|
| G1: one `stream_synthesize/3` clause per input shape (binary → HTTP, enumerable → WebSocket) | Fewer names. But a clause chosen by `Enumerable.impl_for/1` makes a list of strings and a single string two different transports, a charlist silently takes the WebSocket path, and the error for a non-input-streaming adapter differs by argument shape. |
| **G2: `stream_synthesize/3` (whole text) + `stream_synthesize_input/3` (enumerable) (chosen)** | Each function has one transport and one gate. It also mirrors ElevenLabs' own `/stream` vs `/stream-input` naming. |

### H. ElevenLabs admission (resolved by the owner: in core)

§35.7 has three admission rules (`steering/allm_engine_session_streaming_spec_v0_2.md:2336`, `:2354`, `:2366`). ElevenLabs fails all of them:
- **(a)** It has no bundled chat adapter.
- **(b)** No bundled provider names it as a partner.
- **The Phase 22 family-shape rule** requires the provider to be bundled for chat.

JEV's proposed *capability-only provider* carve-out (`steering/2026-09-22_JEV_SUPPORT.md:191-195`, unbuilt) also fails, on its condition (i): *"no bundled provider offers the capability through a dedicated endpoint"*. OpenAI does offer it (`/v1/audio/speech`, `/v1/audio/transcriptions`).

The owner chose in-core with a new carve-out (Decision #1) over a separate `allm_elevenlabs` Hex package.

---

## Overview

Phase 25 shipped request/response audio and deferred streaming because *"the shape is undecided"* (`steering/2026-09-24_SST_SUPPORT.md:67-69`). This phase decides that shape. The decision is Alternative A3: two closed event unions outside `ALLM.Event`, opted into per adapter through a second behaviour on the same engine slot.

It also adds the provider the Phase 25 contracts were checked against: string voice ids, file-format atoms, and per-slot models (`steering/2026-09-24_SST_SUPPORT.md:140`).

The latency-critical voice loop the owner asked for is this sequence:
1. Microphone PCM goes to `stream_transcribe/3`.
2. The committed transcript goes to `ALLM.stream/3`.
3. The chat text deltas go to `stream_synthesize_input/3`.
4. Audio chunks come back.

Steps 1 and 3–4 stream. Step 2 needs the committed question, so it waits for the transcript (the Layer C demo collects it); within a turn, TTS starts on the first chat delta rather than the finished answer.

### Deliverables

**Layer A (new):** `ALLM.SpeechEvent`, `ALLM.TranscriptionEvent`, `ALLM.TranscriptionStreamRequest`.

**Layer A (modified):**
- `ALLM.SpeechRequest` and `ALLM.SpeechResponse` gain `:sample_rate`.
- `SpeechAdapterError` and `TranscriptionAdapterError` gain `:unsupported_feature`.
- `Validate` gains `speech_request/2` and `transcription_stream_request/1`.
- `Serializer` gains one `@known_modules` entry.

**Layer B (new):**
- Behaviours: `ALLM.SpeechStreamAdapter`, `ALLM.TranscriptionStreamAdapter`.
- ElevenLabs adapters: `ALLM.Providers.ElevenLabs.Speech`, `ALLM.Providers.ElevenLabs.Transcription`.
- Support modules: `ALLM.Providers.Support.HTTPResponse`, `.TranscriptionAdapter`, `.ElevenLabs`, `.WebSocket` (behaviour), `.WebSocket.Mint` (its default implementation), `.InputPump`.
- Conformance suites: `ALLM.Test.SpeechStreamAdapterConformance`, `SpeechInputStreamAdapterConformance`, `TranscriptionStreamAdapterConformance`.

**Layer B (modified):**
- `FakeSpeech` and `FakeTranscription` implement the streaming behaviours.
- `OpenAI.Speech` implements `SpeechStreamAdapter`.
- Every provider file holding a byte-identical HTTP helper migrates to `Support.HTTPResponse`, and both transcription adapters migrate their cloned STT-contract helpers to `Support.TranscriptionAdapter` (26.1).

**Layer C (new):** `ALLM.stream_synthesize/3`, `ALLM.stream_synthesize_input/3`, `ALLM.stream_transcribe/3`, and `ALLM.AudioStream` (`collect_speech/1`, `collect_transcription/1`, `text_deltas/1`).

**Dependency:** `{:mint_web_socket, "~> 1.0"}`.

### Spec coverage

- **§37.11 (new): Streaming audio.** Event unions, streaming behaviours, façades, transport, the equivalence property, and telemetry.
- **§37.7:** the provider matrix gains ElevenLabs.
- **§37.10:** strike *"streaming TTS / real-time STT"* and *"ElevenLabs TTS / STT"* (`steering/allm_engine_session_streaming_spec_v0_2.md:2978`, `:2983`).
- **§35.7:** Decision #1's carve-out.
- **§27:** the module tree.
- **§29:** two span names and one event.

### Layer demonstration

**Layer A**, with no engine and no network:

```elixir
cfg = ALLM.TranscriptionStreamRequest.new(sample_rate: 16_000, language: "en")
:ok = ALLM.Validate.transcription_stream_request(cfg)
[{:audio_delta, "ab"}, {:audio_delta, "c"}] |> Enum.all?(&ALLM.SpeechEvent.event?/1)
{:ok, ^cfg} = cfg |> ALLM.Serializer.to_json!() |> ALLM.Serializer.from_json()
```

**Layer B**, calling an adapter directly and bypassing the façade:

```elixir
req = ALLM.SpeechRequest.new(input: "Hi.", voice: "JBFqnCBsd6RMkjVDRZzb", format: :pcm, sample_rate: 24_000)
{:ok, events} = ALLM.Providers.ElevenLabs.Speech.stream_synthesize(req, api_key: key)
events |> Stream.each(fn {:audio_delta, b} -> Port.command(player, b); _ -> :ok end) |> Stream.run()
```

**Layer C**, the voice loop (the transcript is collected, then chat and TTS stream together):

```elixir
{:ok, heard} = ALLM.stream_transcribe(engine, mic_chunks, sample_rate: 16_000)
{:ok, %{text: question}} = ALLM.AudioStream.collect_transcription(heard)
{:ok, chat} = ALLM.stream(engine, [ALLM.user(question)])
{:ok, spoken} = ALLM.stream_synthesize_input(engine, ALLM.AudioStream.text_deltas(chat), format: :pcm)
```

There is **no Layer D**. `ALLM.Session` is untouched.

### Prerequisites

- **Phase 25**, the audio family: `lib/allm/speech_adapter.ex`, `lib/allm/transcription_adapter.ex`, the façade block `lib/allm.ex:1351-1640` plus internals `:2138-2300`, the Fakes, and the two conformance suites under `conformance/lib/allm/test/`.
- **The chat streaming machinery** this design copies: `Stream.resource/3` over `Finch.async_request/3` (`lib/allm/providers/openai.ex:824-930`), `ALLM.Providers.Support.Transport.finch_opts/2` (`lib/allm/providers/support/transport.ex:67`), and `ALLM.Test.FinchStub` (`test/support/finch_stub.ex`).
- **`ELEVENLABS_API_KEY` in the project-root `.env`, added by the owner before 26.6.** `ALLM.Keys.env_var_for(:elevenlabs)` resolves to `"ELEVENLABS_API_KEY"` through the fallback (`lib/allm/keys.ex:198-203`: `String.upcase("#{provider}") <> "_API_KEY"`), so no `Keys` change is needed.

### Out of scope

| Excluded | Why |
|----------|-----|
| OpenAI STT streaming (`stream=true`) and OpenAI Realtime | Owner decision 3. The `TranscriptionStreamAdapter` contract is checked against OpenAI Realtime's shape (append-audio, commit, delta/completed events; research notes 2026-09-25), so it can come later as an adapter-only phase. |
| Gemini streaming (TTS or STT) | Gemini TTS itself is still deferred (§37.10). Gemini STT is prompted chat. |
| `ulaw`/`alaw` formats (telephony) | `SpeechRequest.formats/0` is a closed enum. Adding telephony encodings is additive to it but needs its own Test Plan for OpenAI (which cannot produce them). The obvious next ask; filed in 26.10. |
| Word/character alignment (`sync_alignment`, `/with-timestamps`) | Needs a new `SpeechEvent` variant, which is breaking for that union's reducers. Better designed once, with a caption/lip-sync user story. |
| ElevenLabs multi-context WebSocket (`/multi-stream-input`) | Interruption/barge-in. A stateful multi-utterance API; separate design. |
| Single-use tokens for browser clients | Server-side library; keys resolve via `ALLM.Keys`. |
| Voice cloning, voice library CRUD, dubbing, sound effects | Not TTS/STT. |
| Batch STT extras: diarization, `keyterms`, timestamps, entity redaction | §37.10 (text-only output). Reachable via `options`; the body stays on `raw`. |
| Connection pre-warming / WebSocket pooling | A socket opens per call. Measure first (the first-chunk event gives the number). |
| Retrying a stream after it has opened | Chat precedent: streams are not retried once the enumerable is returned (`lib/allm/stream_runner.ex`, no `Retry.run/3` on the stream path). |
| `ALLM.Session` integration | No conversation state. |

### Non-obvious decisions

1. **§35.7 gains a scoped audio carve-out (owner decision).** Proposed text, placed after the Phase 22 amendment block (and after JEV's if that lands first; the two are independent):
   > *An adapter from a provider with no bundled chat adapter may be bundled into the audio family (§37) when it is the family's first bundled implementation of an input-streaming audio callback — `c:ALLM.SpeechStreamAdapter.stream_synthesize_input/3` or `c:ALLM.TranscriptionStreamAdapter.stream_transcribe/3` — so that a published streaming behaviour ships with a real provider behind it. An adapter so admitted may also implement the family's other audio behaviours.*

   This is a carve-out, not a widening. Its one beneficiary is ElevenLabs. It admits no second specialist for a callback that already has a bundled implementation (Deepgram, Cartesia, AssemblyAI stay out of core), and it admits nothing outside §37. *Docs target: spec §35.7 amendment + §37.11.*
2. **Streaming opts in through a second behaviour on the same slot** (Assumption 2, Alternative C). A slot adapter that does not export `stream_synthesize/2` produces `{:error, %EngineError{reason: :missing_stream_adapter}}`. That atom is **reused** from chat (`lib/allm/error/engine_error.ex:15`) with a capability-naming message, rather than minting `:missing_speech_stream_adapter`: the caller always knows which façade they called, and a reused atom needs no enum extension. *Docs target: `@doc ALLM.stream_synthesize/3`, `@moduledoc ALLM.SpeechStreamAdapter`.*
3. **WebSocket transport rule (new `CLAUDE.md` bullet in 26.9):** *WebSocket paths use `Mint.WebSocket` over an HTTP/1 connection opened in the process that reduces the stream, through `ALLM.Providers.Support.WebSocket`; the API key goes in the upgrade request's headers, never the URL.* HTTP/1 matches the existing Finch rule (§7.2). The header-not-URL rule matters because ElevenLabs also accepts a `?authorization=` query parameter (documented, https://elevenlabs.io/docs/api-reference/text-to-speech/v-1-text-to-speech-voice-id-stream-input), and URLs end up in logs and telemetry. *Docs target: `CLAUDE.md` + `@moduledoc ALLM.Providers.Support.WebSocket`.*
4. **Input is pumped by a helper process; the socket stays with the consumer.** A mic or LLM enumerable blocks while it waits for its next element, and the consumer must keep reading server frames during that wait. `Support.InputPump` reduces the input in a separate, **unlinked, monitored** helper process and sends elements to the owner under a credit window. The owner is the only process that writes the socket. **Consequence for callers:** the input is reduced in another process, so an input that depends on the caller's mailbox (`Stream.repeatedly(fn -> receive … end)`) or process dictionary must be relayed (the guide shows a relay). The Fakes reduce input through the same pump, so a Fake-driven test fails the same way production would. The composition behaviours are enumerated in the Layer B contract and each one is a test. *Docs target: `@moduledoc ALLM.Providers.Support.InputPump`.*
5. **`sample_rate` is a first-class field on speech request and response.** PCM is headerless, so without a rate the bytes cannot be played. OpenAI PCM is fixed at 24 kHz (OpenAI TTS guide: *"raw samples in 24kHz (16-bit signed, low-endian), without the header"*, fetched 2026-09-25), while ElevenLabs offers 8–48 kHz per format. `nil` means "the adapter's default for the format", and every adapter reports the actual rate on `SpeechResponse.sample_rate` and on `:speech_started`. **The cross-provider PCM default is 24,000 Hz**, so switching providers never silently changes the playback rate. *Docs target: `@moduledoc ALLM.SpeechRequest`, each adapter's format table.*
6. **`stream_transcribe/3` never falls back to `engine.transcription_model`.** Batch and realtime model namespaces are disjoint on ElevenLabs (`scribe_v2` vs `scribe_v2_realtime`; the realtime `model_id` accepts only the latter, documented, https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime). An engine configured for batch would therefore break realtime. Resolution is `request.model || adapter default`. `stream_synthesize*/3` *does* use `engine.speech_model` (Phase 25 Decision #10), because the three ElevenLabs endpoints (`/stream`, `/stream-input`, non-streaming) take the same `model_id` parameter on their doc pages. That every model works on `/stream-input` is **inferred** (a model may be HTTP-only); arm `ws_v3` settles it, and a rejection there becomes a documented limitation, not a fallback to another model. *Docs target: `@doc ALLM.stream_transcribe/3` "Model resolution".*
7. **A stream that errors after opening ends with `{:error, err}`, and `collect_*` returns `{:error, err}`.** This deliberately differs from chat's fold-into-response rule (`CLAUDE.md` "Mid-stream adapter errors fold into the response"). `SpeechResponse` has no `finish_reason`, and the speech invariant 2 (bytes > 0) cannot describe a half-rendered clip. The error's `metadata.bytes_received` (speech) or `metadata.committed_text` (transcription) carries what arrived. The audio bytes themselves never enter the error: errors derive `Jason.Encoder`, and raw audio is not UTF-8. For the same reason, an input failure is described in two places and only two: `metadata.cause` is the atom (`:input_raised` or `:input_crashed`), and the error struct's `cause` field (`err.cause`) is a string-only map, `%{kind: kind, message: Exception.format_banner(kind, reason)}`, never the raw exception, throw or exit term (which can carry pids and refs, forbidden on Layer A, and which `Jason.encode!/1` cannot encode: the existing `sanitize_cause/1` copies handle only `Jason.DecodeError`, e.g. `lib/allm/providers/gemini/embeddings.ex:870`). *Docs target: `@moduledoc ALLM.AudioStream`.*
   > CORRECTED 2026-09-26 (26.4 fix pass): "string-only map" here and below is inexact. `kind` is the atom `:error`, `:throw` or `:exit` (`InputPump`'s `@type input_error`), and only `message` is a string. The map is still JSON-encodable, but `kind` reads back as a string after a round-trip.
8. **The first-audio latency is measured, not guessed.** A non-span event `[:allm, :audio, :first_chunk]` fires once per stream with `%{latency: native_time}` from façade call to first `:audio_delta` or `:partial_transcript`. It uses `ALLM.Telemetry.execute/3` (`lib/allm/telemetry.ex:286-290`). Stream spans stop when the enumerable is *returned*, not when it drains (the chat carve-out at `lib/allm/stream_runner.ex:110-125`: *"`:stop` metadata's `:response` is intentionally `nil` for streaming spans"*). So without this event the one number the owner cares about is invisible. *Docs target: `@moduledoc ALLM.Telemetry` event table.*
9. **ElevenLabs refuses what it cannot express with `:unsupported_feature`, keyless.** The cases are `instructions` (no ElevenLabs field), `format: :aac | :flac` (no output format), a `sample_rate` outside the format's set, and `TranscriptionRequest.prompt` (no batch prompt field). OpenAI accepts `sample_rate` `nil` or 24,000 for `:pcm` and `:wav` (both are 24 kHz PCM16) and refuses any other value, and refuses any non-nil `sample_rate` on other formats. These are the use sites that justify adding the atom to both enums (agent-spec/DESIGN.md rule 13). *Docs target: each adapter's `@doc`.*
10. **Every default an ElevenLabs adapter injects is documented where it is injected**, per `CLAUDE.md`'s injected-default rule: in the public `@doc` of each entry point that injects it **and** the `@doc false` of the builder that writes it to the wire. The defaults are:
    - `@default_voice` for a nil voice (`synthesize/2`, `stream_synthesize/2`, `stream_synthesize_input/3`; builders `url/2` and the WebSocket URL builder). ElevenLabs puts the voice in the URL path, so there is no request without one.
    - `model_id`: `@default_model` (`ElevenLabs.Speech`, all three entry points) and `@default_model` / `@default_stream_model` (`ElevenLabs.Transcription`, `transcribe/2` / `stream_transcribe/3`); builders `to_json_body/2`, the multipart builder and both WebSocket URL builders.
    - `output_format` `mp3_44100_128` for a nil `format`, and the per-format sample-rate default (the **bold** cells of the Format table) for a nil `sample_rate`; builder `Support.ElevenLabs.output_format/2`.
    - `inactivity_timeout` derived from `stream_timeout` (WebSocket TTS wire map); builder: the `/stream-input` URL builder.
    - Whatever latency setting arm `ws_tokens` selects (Decision #11), if it selects one.

    The voice default's candidate is `JBFqnCBsd6RMkjVDRZzb` (the voice ElevenLabs' quickstart uses; **UNVERIFIED** as a permanent premade voice). Probe arm `default_voice` must 200, otherwise the recorder halts and the implementer picks a `category: "premade"` id from `GET /v1/voices` and amends. *Docs target: as stated.*
11. **ElevenLabs' `options` placement.** HTTP TTS: JSON body, deep-merged under the structural fields; `voice_settings` is deep-merged, so `options: %{"voice_settings" => %{"stability" => 0.3}}` coexists with `speed`. WebSocket TTS: into the initial message (`voice_settings`, `generation_config`). Batch STT: one multipart field per entry. Realtime STT: query parameters. Query parameters ALLM does not model on the HTTP/TTS-WS paths go in `options["query"]` (a map), merged under structural ones. **Reserved and dropped with a deferred `Logger.debug/1`:** `output_format` (derived from `format` + `sample_rate`), `model_id`, `text`, and on realtime `audio_format` and `commit_strategy`. Each changes a shape the decoder relies on or duplicates a modelled field. **The WebSocket TTS latency default is chosen by measurement, and the owner's criterion is the fastest first audio.** Arm `ws_tokens` measures time to first audio frame twice on the same input: under the provider's documented default `chunk_length_schedule` (`[120,160,250,290]`, no `generation_config` and no `auto_mode` sent) and under `auto_mode=true` (query parameter). Whichever has the lower first-audio `t_ms` becomes the adapter default. If it is `auto_mode=true`, the adapter sends it unless `options["query"]` sets `auto_mode` itself, and that injected default joins Decision #10's list. The two numbers and the choice go in RECORDS; this Decision and the WebSocket TTS wire map are rewritten in place in 26.7's commit, and the guide quotes both numbers. Callers still tune with `options: %{"generation_config" => %{"chunk_length_schedule" => […]}}` or `options["query"]["auto_mode"]`. *Docs target: `@moduledoc` of both ElevenLabs adapters.*

---

## Behaviour & Type Contracts

Every signature, wire shape and invariant is stated normatively **once**, here. Later sections cite it.

### Layer A — `ALLM.SpeechEvent`

```elixir
defmodule ALLM.SpeechEvent do
  @type started :: %{request_id: String.t() | nil, model: String.t() | nil, provider: atom() | nil,
                     format: ALLM.SpeechRequest.format() | nil, mime_type: String.t(),
                     sample_rate: pos_integer() | nil}
  @type completed :: %{request_id: String.t() | nil, id: String.t() | nil,
                       usage: ALLM.Usage.t(), metadata: map()}
  @type t ::
          {:speech_started, started()}
          | {:audio_delta, binary()}
          | {:speech_completed, completed()}
          | {:error, ALLM.Error.SpeechAdapterError.t()}

  @spec speech_started(started()) :: t()        # constructors validate required keys
  @spec audio_delta(binary()) :: t()            # raises ArgumentError on ""
  @spec speech_completed(completed()) :: t()
  @spec event?(term()) :: boolean()
end
```

**Stream grammar (normative):**
- A successful stream is `speech_started · audio_delta+ · speech_completed`.
- **Empty input:** a `stream_synthesize_input/3` stream whose input yields no non-empty chunk before it ends, and any stream that reaches its provider's end-of-audio with zero audio bytes, ends with `{:error, %SpeechAdapterError{reason: :invalid_request, metadata: %{cause: :empty_input}}}`. A successful stream therefore always has ≥ 1 delta.
- A failed stream is `speech_started? · audio_delta* · error`.
- Nothing follows a terminal event.
- The concatenation of every `:audio_delta` payload is a valid file of `format` (or raw PCM at `sample_rate` for `:pcm`).
- `mime_type` begins `audio/`.

**Serializability:** events round-trip `:erlang.term_to_binary/1`. They are **not** JSON-encoded, because `:audio_delta` carries raw bytes. The moduledoc says so, and so does the `ALLM.Event` precedent note. **Adding a variant is breaking for reducers of this union**, the same rule as §8. Constructors mirror `ALLM.Event`'s style (`lib/allm/event.ex:12`, *"variant constructors (`text_delta/2`, …)"*).

### Layer A — `ALLM.TranscriptionEvent`

```elixir
@type started :: %{request_id: String.t() | nil, model: String.t() | nil, provider: atom() | nil,
                   session_id: String.t() | nil}
@type completed :: %{text: String.t(), language: String.t() | nil, duration_seconds: number() | nil,
                     request_id: String.t() | nil, usage: ALLM.Usage.t(), metadata: map()}
@type t ::
        {:transcription_started, started()}
        | {:partial_transcript, %{text: String.t()}}
        | {:committed_transcript, %{text: String.t(), language: String.t() | nil}}
        | {:transcription_completed, completed()}
        | {:error, ALLM.Error.TranscriptionAdapterError.t()}
```

**Grammar:**
- Success is `transcription_started · (partial_transcript* · committed_transcript)* · partial_transcript* · transcription_completed`.
- Failure is `…· error`, and nothing follows a terminal.

**Semantics:**
- A `:partial_transcript` **replaces** the previous partial of the current segment. It is not appended.
- A `:committed_transcript` is final and is appended.
- `completed.text` is the normative join: each committed `text` is `String.trim/1`-ed, empties are dropped, and the rest are joined with one space. The adapter computes it; the collector does not recompute it.
- `duration_seconds` on the streaming path is **computed** as `bytes_sent / (sample_rate * 2)` (PCM16 mono). It is not provider-reported, and the moduledoc says so.

ETF-only serializability, and the breaking-variant rule, as for `SpeechEvent`.

### Layer A — `ALLM.TranscriptionStreamRequest`

```elixir
@type commit_strategy :: :vad | :manual
@type t :: %__MODULE__{model: String.t() | nil, language: String.t() | nil,
                       sample_rate: pos_integer(), commit_strategy: commit_strategy(),
                       options: map(), metadata: map()}
defstruct [:model, :language, sample_rate: 16_000, commit_strategy: :vad, options: %{}, metadata: %{}]
@spec new(keyword()) :: t()          # bare struct!/2, no guards
@spec commit_strategies() :: [commit_strategy()]
```

- **`__from_tagged__/1` must NOT use `data["k"] || default` for `sample_rate` or `commit_strategy`.** Both defaults are truthy (`CLAUDE.md` `__from_tagged__` rule). Use `decode_sample_rate(nil) -> 16_000; (n) -> n` and `decode_commit_strategy(nil) -> :vad; (s) -> Serializer.to_atom_field(s)`. The serialization fixture pins `sample_rate: 8_000, commit_strategy: :manual`, whose falsifier is a round-trip that returns the defaults.
- The input element type for `stream_transcribe/3` is `binary() | :commit`: PCM16 little-endian mono bytes at `sample_rate`, or a manual commit marker. That type lives in the `TranscriptionStreamAdapter` contract, not on this struct.

### Layer A — modified structs and enums

| Module | Change | Decode |
|--------|--------|--------|
| `SpeechRequest` (`lib/allm/speech_request.ex:47`, `:58`) | `+ sample_rate: pos_integer() \| nil`, default `nil` | `data["sample_rate"]`, nil default is safe |
| `SpeechResponse` (`lib/allm/speech_response.ex:36`, `:48`) | `+ sample_rate: pos_integer() \| nil`, default `nil` | same |
| `SpeechAdapterError` (`lib/allm/error/speech_adapter_error.ex:53`, `@type reason` above it) | `+ :unsupported_feature` (9 → 10) | — |
| `TranscriptionAdapterError` (`lib/allm/error/transcription_adapter_error.ex:54`) | `+ :unsupported_feature` (10 → 11) | — |
| `Serializer` `@known_modules` (`lib/allm/serializer.ex:65-99`) | `+ ALLM.TranscriptionStreamRequest` (events are ETF-only, **not** registered) | — |

**Contract flip (agent-spec/DESIGN.md rule 9).** These prior-phase assertions invert:
- `test/allm/error/speech_adapter_error_test.exs:8` (the `@legal_reasons` literal compared as a MapSet), `:23` (`== 9`) and `:27-30` (`refute :unsupported_feature`); the same three sites in the transcription sibling.
- The moduledoc reason-count sentences (`speech_adapter_error.ex:6` *"nine reasons"*, and the transcription sibling's *"ten reasons … the nine that"*).
- `test/allm/error/transcription_adapter_error_test.exs:24` (`== 10`) and `:28-31`.
- The `legal_reasons/0` doctests at `lib/allm/error/speech_adapter_error.ex:73` and `transcription_adapter_error.ex:75`.
- The moduledoc sentences at `speech_adapter_error.ex:10` and `transcription_adapter_error.ex:11`, which say no bundled adapter refuses a field.

Discovery predicate: `git grep -n 'unsupported_feature' test/allm/error/ lib/allm/error/speech_adapter_error.ex lib/allm/error/transcription_adapter_error.ex`. Every hit gets a keep/flip disposition in RECORDS.

### Layer A — validators

```elixir
@spec speech_request(SpeechRequest.t(), keyword()) :: :ok | {:error, ValidationError.t()}
# speech_request/1 stays, delegating with []. opts: [input: :streamed] skips the three :input rows.
@spec transcription_stream_request(TranscriptionStreamRequest.t()) :: :ok | {:error, ValidationError.t()}
```

New vocabulary rows. The existing `speech_request` rows are unchanged (`steering/2026-09-24_SST_SUPPORT.md:288-300`).

| Validator | Field | Atom | Hard? | Fires when |
|-----------|-------|------|-------|-----------|
| speech | `:sample_rate` | `:out_of_range` | no | not `nil` and not a `pos_integer()` |
| speech, `input: :streamed` | `:input` | — | — | the three `:input` rows are skipped; any other `:input` value is ignored |
| transcription_stream | `:sample_rate` | `:out_of_range` | no | not a `pos_integer()` |
| transcription_stream | `:commit_strategy` | `:unknown` | no | not in `commit_strategies/0` |
| transcription_stream | `:model` / `:language` | `:invalid_shape` | no | neither `nil` nor binary |
| transcription_stream | `:options` / `:metadata` | `:invalid_shape` | no | not a map |

The `ValidationError` reason reuses `:invalid_speech_request` / `:invalid_transcription_request` (`lib/allm/error/validation_error.ex`), so no enum extension is needed. Per-provider sample-rate sets are adapter gates, not validator rows.

### Layer B — `ALLM.SpeechStreamAdapter`

```elixir
@type text_chunk :: String.t()
@callback stream_synthesize(ALLM.SpeechRequest.t(), keyword()) ::
            {:ok, Enumerable.t(ALLM.SpeechEvent.t())} | {:error, ALLM.Error.SpeechAdapterError.t()}
@callback stream_synthesize_input(ALLM.SpeechRequest.t(), Enumerable.t(text_chunk()), keyword()) ::
            {:ok, Enumerable.t(ALLM.SpeechEvent.t())} | {:error, ALLM.Error.SpeechAdapterError.t()}
@optional_callbacks stream_synthesize_input: 3
```

**Invariants (normative):**
1. The synchronous return is exactly `{:ok, enumerable}` or `{:error, %SpeechAdapterError{}}`. The `Keys.fetch!/2` raise is the one exception, as in `ALLM.SpeechAdapter` invariant 1.
2. **Lazy:** no I/O happens until the enumerable is reduced. Pre-flight gates run synchronously and return `{:error, _}` **before `Keys.fetch!/2`**:
   - `stream_synthesize/2`: empty input, then per-adapter gates.
   - `stream_synthesize_input/3`: `Validate.speech_request(req, input: :streamed)`-level shape checks, then per-adapter gates.
3. The enumerable obeys the `SpeechEvent` grammar.
4. **Halt-safe:** a consumer halt (`Enum.take/2`) releases the transport (Finch ref cancelled, or WebSocket closed and pump stopped) within 500 ms (agent-spec/DESIGN.md §8), and leaves no stream-owned message in the consumer's mailbox: the after function demonitors the pump with `[:flush]` and drains `{pump_ref, _}` and the socket's `:ssl`/`:ssl_closed`/`:tcp*` messages. The input's *own* resources are released by process exit, not by its after functions (InputPump behaviour 3).
5. `opts[:stream_timeout]` (ms of silence, default 60,000) is honoured. The timer resets on every transport message **and** every pump message, so a slow input (an LLM thinking) does not time out a socket whose server is waiting for text, and a silent server does not time out while input still flows. On expiry the stream ends with `{:error, %SpeechAdapterError{reason: :timeout}}`.
6. `opts[:request_id]` appears on `:speech_started` and `:speech_completed`. `request.metadata` appears on `:speech_completed.metadata` unchanged.
7. **Input chunks** (`stream_synthesize_input/3`):
   - A non-binary or non-UTF-8 element ends the stream with `{:error, %SpeechAdapterError{reason: :invalid_request, metadata: %{cause: :invalid_input_chunk}}}`.
   - An empty string element is skipped.
   - An input enumerable that raises, throws or exits ends the stream with `:invalid_request`, `metadata.cause: :input_raised`. If the pump dies from an exit signal (a process linked inside the input crashed) the cause is `:input_crashed`. Either way `err.cause` is the string-only `%{kind, message}` map of Decision #7. The consumer process is never killed.
8. The concatenation of every `:audio_delta` payload satisfies `ALLM.SpeechAdapter` invariant 2 (non-empty; `mime_type` from `:speech_started` begins `audio/`).
9. **Ordering of I/O:** key resolution (`Keys.fetch!/2`) runs synchronously after the gates and before the enumerable is returned (the chat precedent, `lib/allm/providers/openai.ex:836`). On a WebSocket path the start function connects, waits for the 101, sends the init message (TTS) or waits for `session_started` (STT), and **only then** starts the input pump. A failed upgrade therefore never reduces the input (no LLM call is made for a bad key).

### Layer B — `ALLM.TranscriptionStreamAdapter`

```elixir
@type audio_chunk :: binary() | :commit
@callback stream_transcribe(ALLM.TranscriptionStreamRequest.t(), Enumerable.t(audio_chunk()), keyword()) ::
            {:ok, Enumerable.t(ALLM.TranscriptionEvent.t())} | {:error, ALLM.Error.TranscriptionAdapterError.t()}
@callback stream_sample_rates() :: [pos_integer()]
```

**Invariants:**
1–2. As speech invariants 1–2. The per-adapter gate is `request.sample_rate in stream_sample_rates()`, else `:invalid_request` with `metadata.sample_rate`. It runs before `Keys.fetch!/2`.
3. The enumerable obeys the `TranscriptionEvent` grammar.
4–6. Halt-safety, `:stream_timeout`, and `request_id`/`metadata`, as for speech.
7. **Input:**
   - A non-binary, non-`:commit` element, or an input that raises or crashes, ends the stream with `:invalid_request` and `metadata.cause` in `[:invalid_input_chunk, :input_raised, :input_crashed]`.
   - **Chunk boundaries are the caller's, not the protocol's.** A chunk may split a PCM16 sample: the adapter carries a 1-byte remainder into the next chunk and sends only whole samples. A remainder left at end of input ends the stream with `:invalid_input_chunk`. A chunk longer than the adapter's documented maximum frame (`@max_chunk_ms`, 1,000 ms of audio at `sample_rate`; **inferred**, arm `rt_big_chunk`) is split. The invariant is on content: the concatenated audio the provider receives equals the concatenated input.
   - `:commit` forces a segment commit under either strategy.
8. **End of input:** when the input enumerable is exhausted, the adapter commits any uncommitted audio and waits up to `:stream_timeout` for the final `:committed_transcript`. Only then does it emit `:transcription_completed` and close.

`stream_sample_rates/0` plays the same role as `max_audio_bytes/0`: a caller checks it before opening a mic.

### Layer B — `ALLM.Providers.Support.WebSocket`

This is a behaviour plus its Mint implementation, so the adapters can take `opts[:ws_module]` exactly as the chat adapters take `opts[:finch_module]` (`lib/allm/providers/openai.ex:844`).

**Layout: one module per file.** The behaviour `ALLM.Providers.Support.WebSocket` lives in `lib/allm/providers/support/web_socket.ex`. The default implementation `ALLM.Providers.Support.WebSocket.Mint` (the `opts[:ws_module]` default) lives in `lib/allm/providers/support/web_socket/mint.ex`. Each has its own moduledoc and its own `groups_for_modules` row. Two `defmodule`s in one file would put both behind the whole-file `@moduledoc false` check of `test/groups_for_modules_audit_test.exs` (its moduledoc's "Multi-module files" limitation), so a later `@moduledoc false` on either would silently hide the other from the audit.

```elixir
@type conn :: term()
@type frame :: {:text, String.t()} | {:binary, binary()} | {:close, non_neg_integer() | nil, String.t()}
@callback connect(url :: String.t(), headers :: [{String.t(), String.t()}], opts :: keyword()) ::
            {:ok, conn()} | {:error, {:upgrade_status, pos_integer(), map() | binary()} | {:transport, term()}}
@callback send_frame(conn(), frame()) :: {:ok, conn()} | {:error, conn(), term()}
@callback handle_message(conn(), message :: term()) ::
            {:ok, conn(), [frame() | :closed]} | :unknown | {:error, conn(), term()}
@callback close(conn()) :: :ok
@callback flush_messages(conn()) :: :ok      # drain this connection's transport messages from the mailbox
```

- **`connect/3` (Mint impl).** It derives scheme, host and port from the URL: `wss://` → `Mint.HTTP.connect(:https, host, port || 443, protocols: [:http1])` and `Mint.WebSocket.upgrade(:wss, …)`; `ws://` → `:http`, `port || 80` and `:ws`. The plain scheme exists for the offline test server (`test/support/ws_test_server.ex`); the adapters always build `wss://` URLs. It then drives the handshake to completion in the calling process with a **selective** `receive` on its own socket (so no other message is consumed). It respects `opts[:connect_timeout]` (default 10,000 ms).
- **Control frames never leave the module.** `handle_message/2` answers a server `{:ping, data}` with `{:pong, data}` itself (`Mint.WebSocket` does not auto-reply) and drops pongs, so `frame()` has no control variants.
- **A non-101 upgrade response** returns `{:upgrade_status, status, decoded_body_or_binary}`, so the adapter can classify it (401 bad key, 429, …) with the same table as HTTP.
- **`handle_message/2`** returns `:unknown` for messages that are not this connection's, so the owner's `receive` can also accept pump messages.
- **`close/1`** is idempotent and never raises. It sends a best-effort close frame and then calls `Mint.HTTP.close/1`.

### Layer B — `ALLM.Providers.Support.InputPump`

```elixir
@spec start(Enumerable.t(), owner :: pid(), window :: pos_integer()) :: {pid(), reference()}
@spec ack(pid(), reference()) :: :ok
@spec stop(pid(), reference()) :: :ok   # demonitor(ref, [:flush]); Process.exit(pid, :kill); drain {ref, _}; idempotent
# owner receives: {ref, {:input, element}} | {ref, :input_done}
#               | {ref, {:input_error, %{kind: atom(), message: String.t()}}}
#               | {:DOWN, ref, :process, pid, reason}   (the monitor ref is the message ref)
```

The pump is **not linked** to the owner. `start/3` spawns it with `spawn_monitor/1`, so its exit is a `:DOWN` message, never an exit signal. Inside, the pump spawns a linked watchdog that monitors the owner and kills the pump on the owner's `:DOWN`. The pump wraps the reduce in `try/rescue/catch` and reports failures as a string-only `:input_error` (Decision #7), which the adapter places on `err.cause`.

**Composition behaviours (agent-spec/DESIGN.md "composition verification"). Behaviours 2–7 are named tests in `input_pump_test.exs` (26.3); behaviour 1 is in `elevenlabs/speech_stream_test.exs` (26.7), because it needs a socket-owning resource:**
1. `Stream.resource/3`'s start, next and after functions all run in the reducing process. So the Mint socket's controlling process is the consumer. Test: capture `self()` in each function.
2. An input that raises becomes `{ref, {:input_error, %{kind: :error, message: _}}}`, and the owner does not crash. Falsifier: the consumer exits.
3. `stop/2` kills the pump without affecting the owner: no link, and the monitor is flushed. **A killed pump runs no after functions**, so an input's own `Stream.resource/3` cleanup does not run; its resources are released because processes linked to the pump (e.g. Finch's request process, which Finch's HTTP/1 pool `spawn_link`s to its caller) exit with it. Test: after halt, the pump and every process linked to it are dead within 500 ms, and `refute_received {^ref, _}`.
4. At most `window` elements are unacknowledged. The pump blocks until `ack/2` (default window 8, `adapter_opts[:input_window]`). Test: a 1,000-element input with no acks delivers exactly 8 messages.
5. If the consumer process is killed rather than halted, the watchdog kills the pump. Test: `Process.exit(consumer, :kill)`, then the pump is `Process.alive?/1 == false` within 500 ms.
6. An input that is itself an `ALLM.stream_generate/3` enumerable works. Its `Finch.async_request/3` messages go to the pump, which reduces it, and never to the owner. Test with `FinchStub` in its Agent-backed mode (26.3 Module Tree row). In that mode the stub's frame sender is `spawn_link`ed to the `async_request/3` caller, as real Finch's request process is (`deps/finch/lib/finch/http1/pool.ex:115`), so behaviour 3's release-by-exit holds under the stub too. The test pins it: `Process.info(pump, :links)` contains the sender pid while the input is being reduced.
7. A process linked inside the input that exits with `:boom` kills the pump; the owner receives `:DOWN` with `:boom` and stays alive. Falsifier: the consumer exits with `:boom`.

### Layer B — Fakes (streaming)

**Script entries** reuse the Phase 25 keys and cursor (`adapter_opts[:speech_script]`, `[:transcription_script]`). The contract lives in `lib/allm/providers/fake_speech.ex` moduledoc.

**Cursor timing.** A stream callback resolves its script entry and advances the cursor **at call time**, before it returns `{:ok, stream}`, not when the stream is reduced. This is the chat precedent (`lib/allm/providers/fake.ex:291-318`: `stream/2` resolves its scripts before `open_stream/2`). So two stream calls consume two entries even if neither stream is reduced, and a halted stream never replays its entry.

**`{:retry_until_call, n}` on a stream path.** Streams are never retried (the façades have no `Retry.run/3`), so the entry behaves as in chat (`fake.ex:298-307`): while the entry's visit counter is below `n`, the call returns `{:ok, stream}` whose only event is `{:error, %…AdapterError{reason: :rate_limited, retry_after_ms: 0}}`, and the cursor stays on the entry. The `n`-th call advances past it and emits the next entry. The visit counter is shared with the non-streaming path, keyed on the same cursor identity.

**`FakeSpeech.stream_synthesize/2`**
- Entry `{:ok, bytes}`, or no script (`"FAKE-AUDIO:" <> input`): emits `speech_started` (format `request.format || :mp3`, mime from `SpeechResponse.format_to_mime/1`, `sample_rate: request.sample_rate`), then `bytes` split into `adapter_opts[:chunk_bytes]` pieces (default 1,024), then `speech_completed`.
- Entry `{:error, e}`: emits `speech_started`, then `{:error, e}`.
- New entry `{:events, [SpeechEvent.t()]}`: emitted verbatim, which is how mid-stream-error tests are written. The non-streaming `synthesize/2` treats it as `:unknown` with `metadata.cause: :stream_only_script_entry`.

**`FakeSpeech.stream_synthesize_input/3`**
- Reduces the input through `Support.InputPump`, exactly as a real adapter does, so a mailbox-dependent input fails under the Fake too (Decision #4).
- No script: one `:audio_delta` of `"FAKE-AUDIO:" <> chunk` per non-empty chunk. The falsifier for this is a Fake that collapses the chunks.
- `{:ok, bytes}`: consumes all input, then emits the chunked bytes.

**`FakeTranscription.stream_transcribe/3`**
- `stream_sample_rates/0 == [8_000, 16_000, 24_000]`.
- Reduces the input through `Support.InputPump` and validates each element (invariant 7), including the odd-byte remainder rule.
- `{:ok, text}`: emits one `:partial_transcript` per cumulative word prefix, then one `:committed_transcript`, then `:transcription_completed` whose `duration_seconds` is computed from the bytes consumed.
- No script: `:transcription_completed` with `text: ""`.
- `{:events, _}` and `{:error, _}` behave as for speech.

Every gate still fires before the script.

### Layer B — conformance suites

Each suite copies the Phase 25 suite shape (`conformance/lib/allm/test/speech_adapter_conformance.ex`):
- `@case_count` and `case_count/0`;
- a `## Script contract` section;
- `[scripted]` / `[unscripted]` tags;
- `:gate_opts` deep-merged into unscripted cases, which the main-repo invocations use to pass a raising `:plug`, `:finch_module` and `:ws_module`;
- a `## What this suite does NOT bind` section (halt-safety and `:stream_timeout` are bound by each adapter's wire tests, because a scripted hand-off never reaches the transport);
- no case body gated on an optional fixture (agent-spec/DESIGN.md rule 26).

`SpeechStreamAdapterConformance`, **`@case_count 6`**:
1. [scripted] the event list obeys the grammar. Falsifier: `:speech_completed` missing, or not last.
2. [scripted] the concatenation of every delta (`for {:audio_delta, b} <- events, into: "", do: b`, inline; the suite does not depend on `ALLM.AudioStream`) equals the bytes the script supplied. Falsifier: a dropped delta.
3. [scripted] every `:audio_delta` is a non-empty binary.
4. [unscripted] `input: ""` gives a synchronous `{:error, %SpeechAdapterError{reason: :invalid_request}}` with **no key in the environment**. Falsifier: `%EngineError{reason: :missing_key}`.
5. [scripted] `request_id` appears on both envelope events.
6. [scripted] `metadata` round-trips.

`SpeechInputStreamAdapterConformance`, **`@case_count 6`**. It is invoked only for adapters that export the optional callback:
1. `function_exported?(impl, :stream_synthesize_input, 3)`. This is an unconditional premise guard.
2. [scripted] `["Hel", "lo."]` input gives a grammar-conformant stream.
3. [scripted] an input containing `123` ends in `:invalid_request` with `cause: :invalid_input_chunk`.
4. [scripted] an input that raises ends in `:input_raised`, and **the calling process is alive afterwards**.
5. [scripted] an input of only `[""]` ends with `:invalid_request`, `cause: :empty_input`. A falsifier is a hang (bounded by an ExUnit `@tag timeout: 5_000`) or a successful terminal.
6. [unscripted] a request with `format: :bogus` gives a synchronous `{:error, %SpeechAdapterError{reason: :invalid_request}}` from `stream_synthesize_input/3` with **no key in the environment**, before the input is reduced (the input sends `:reduced` to the test process; `refute_received :reduced`). Falsifier: `%EngineError{reason: :missing_key}`, or a returned stream.

`TranscriptionStreamAdapterConformance`, **`@case_count 6`**:
1. [unscripted] `stream_sample_rates/0` is a non-empty list of `pos_integer()`.
2. [scripted] 3,200 bytes of silence at the first supported rate give a grammar-conformant stream.
3. [unscripted] a sample rate not in `stream_sample_rates()` gives a synchronous `:invalid_request` with `metadata.sample_rate`, keyless.
4. [scripted] an input whose total length is odd (e.g. `[<<1, 2, 3>>]`) ends with `:invalid_request`, `cause: :invalid_input_chunk`, at end of input. An odd-length chunk followed by one that completes the sample is not an error (invariant 7).
5. [scripted] `request_id`, and 6. [scripted] `metadata`.

Companion files per suite follow the Phase 25 trio: a stub under `conformance/test/support/fixtures/`, and a meta-test file with four meta-invariants (the `case_count/0` value, the injected test count, a `using/1` `KeyError`, and `:gate_opts` reachability).

### Layer C — façades

```elixir
@spec stream_synthesize(Engine.t(), String.t() | SpeechRequest.t(), keyword()) ::
        {:ok, Enumerable.t(SpeechEvent.t())}
        | {:error, EngineError.t() | ValidationError.t() | SpeechAdapterError.t()}
@spec stream_synthesize_input(Engine.t(), Enumerable.t(String.t()), keyword()) ::
        {:ok, Enumerable.t(SpeechEvent.t())}
        | {:error, EngineError.t() | ValidationError.t() | SpeechAdapterError.t()}
@spec stream_transcribe(Engine.t(), Enumerable.t(binary() | :commit), keyword()) ::
        {:ok, Enumerable.t(TranscriptionEvent.t())}
        | {:error, EngineError.t() | ValidationError.t() | TranscriptionAdapterError.t()}
```

- **Request construction.**
  - `stream_synthesize/3` reuses `speech_request/2` and its allow-list `@speech_request_field_opts` (`lib/allm.ex:1351`).
  - `stream_synthesize_input/3` builds the request with `speech_request("", opts)`, or takes `opts[:request]` (a `%SpeechRequest{}`, authoritative, whose `:input` is ignored).
  - `stream_transcribe/3` builds from `@transcription_stream_request_field_opts [:model, :language, :sample_rate, :commit_strategy, :options, :metadata]`, or takes `opts[:request]`.
  - **Symmetry invariant:** each allow-list equals its struct's fields minus the positional field. `TranscriptionStreamRequest` has no positional field, so its allow-list equals all its fields. This is pinned by a `Map.keys/1` test.
- **Gate order inside the span.** `stream_synthesize*` and `stream_transcribe` each run these gates in order:
  1. Nil slot → `:no_speech_adapter` / `:no_transcription_adapter`.
  2. Slot lacks the callback, checked as `Code.ensure_loaded?(adapter) and function_exported?(adapter, name, arity)` (the `stream_runner.ex:174` form; without the load call a not-yet-loaded module reports missing) → `EngineError :missing_stream_adapter` (Decision #2). For `stream_synthesize_input/3`, this also fires when the slot exports `stream_synthesize/2` but not `stream_synthesize_input/3`, with a message saying so.
  3. (input forms only) The positional input is not an enumerable (`is_binary(input) or is_nil(Enumerable.impl_for(input))`) → synchronous `ValidationError` with `{:input, :invalid_shape}` (the error-tuple convention of `lib/allm/validate.ex:440`) under the capability's reason. Without it, a string passed to `stream_transcribe/3` would surface only when reduced, as `:input_raised`. It sits after the slot gates, like every other validation, so a misconfigured engine is reported first.
  4. Validator (`speech_request(req, input: :streamed)` for the input form).
  5. Model stamping (Decision #6).
  6. Dispatch through `build_capability_dispatch_opts/3` (`lib/allm.ex:2254`, which applies `Engine.put_cursor_key/2`), plus `stream_timeout` passed through.
- **No `Retry.run/3`.** A synchronous `{:error, _}` from the adapter is returned as-is (Out of scope: stream retry).
- **Wrapping.** The returned enumerable is wrapped once by a façade-private `Stream.transform/4` that:
  - (a) emits `[:allm, :audio, :first_chunk]` at the first `:audio_delta` / `:partial_transcript`;
  - (b) raises `ArgumentError` naming the adapter and "invariant 3" if an element is not `SpeechEvent.event?/1` / `TranscriptionEvent.event?/1`. This counterpart of the Phase 25 invariant-1 raise is how the grammar binds third-party adapters at the façade.

**`ALLM.AudioStream` (Layer C, pure):**

```elixir
@spec collect_speech(Enumerable.t(SpeechEvent.t())) :: {:ok, SpeechResponse.t()} | {:error, SpeechAdapterError.t()}
@spec collect_transcription(Enumerable.t(TranscriptionEvent.t())) ::
        {:ok, TranscriptionResponse.t()} | {:error, TranscriptionAdapterError.t()}
@spec text_deltas(Enumerable.t(ALLM.Event.t())) :: Enumerable.t(String.t())   # lazy
```

- **`collect_speech/1`** builds `%SpeechResponse{audio: Audio.from_binary(IO.iodata_to_binary(deltas), mime_type), format:, sample_rate:, model:, provider:, usage:, id:, request_id:, metadata:, raw: nil}`, taking `model`/`provider`/`format`/`sample_rate`/`mime_type` from `:speech_started` and the rest from `:speech_completed`. An `{:error, e}` returns `{:error, %{e | metadata: Map.put(e.metadata, :bytes_received, n)}}`. A stream that ends without a terminal event returns `:malformed_response`.
- **`collect_transcription/1`** takes `text`, `language`, `duration_seconds`, `usage`, `request_id` and `metadata` from `:transcription_completed`, and `model`, `provider` and `id` (the realtime `session_id`) from `:transcription_started`.
- **`text_deltas/1`** maps `{:text_delta, %{delta: d}}` (`lib/allm/event.ex:41`) to `d` and drops everything else. A chat `{:error, err}` event **raises** `ALLM.AudioStream.ChatStreamError` (a private exception carrying `err`'s reason and message, never the struct itself), so the TTS stream ends with `{:error, _}`, `metadata.cause: :input_raised`, and the chat error's reason and message inside `err.cause`'s string-only `%{kind, message}` map. That is Decision #7's rule applied one hop earlier. A truncated answer must never finish as a successful `:speech_completed`; a caller that prefers to speak what arrived filters the chat stream before `text_deltas/1`. *(Owner decision, 2026-09-26.)*

**Telemetry** (26.4 adds the span names to `lib/allm/telemetry.ex`, `@type span_name` `:116` and `@valid_span_names` `:128`):

| Span / event | `:start` metadata | `:stop` |
|--------------|-------------------|---------|
| `[:allm, :stream_synthesize, …]` | `request_id`, `engine`, `model`, `input_length` (`nil` for the input form) | `response: nil` (the chat carve-out, Decision #8) |
| `[:allm, :stream_transcribe, …]` | `request_id`, `engine`, `model`, `sample_rate` | `response: nil` |
| `[:allm, :audio, :first_chunk]` (event) | — | measurements `%{latency: native}`; metadata `%{request_id, capability: :speech \| :transcription, provider_model}` |

`stream_synthesize_input/3` shares the `:stream_synthesize` span name, with `input_length: nil`.

### Wire-field map — OpenAI streaming TTS (26.5)

| Concern | Wire | Status |
|---------|------|--------|
| Endpoint and body | `POST /v1/audio/speech`, **the same JSON body as non-streaming** (`to_json_body/2`, `lib/allm/providers/openai/speech.ex:263`). `stream_format` is not sent (it stays reserved, `:27`) | CONFIRMED (Phase 25 wire map) |
| Framing | chunked transfer of raw audio; `content-type: audio/*` in the headers before the first byte | **inferred** from OpenAI's TTS guide ("supports real-time audio streaming using chunk transfer encoding"). Arm `stream_chunked` asserts ≥ 2 `{:data, _}` messages for a ~400-character input, and that first-byte time is less than total time. **A single-chunk body halts the recorder** (Alternative E fallback) |
| Transport | `Finch.async_request/3` on `ALLM.Finch`, `Transport.finch_opts/2`, `FinchStub` in tests | the chat precedent |
| Gates | the 4096-code-point gate (`gate_input_length/2`, `:287-291`) plus Decision #9's `sample_rate` gate, all before `Keys.fetch!/2` | — |
| Mid-stream HTTP error | `{:status, code >= 400}`, then the body in `{:data, _}` frames. Buffer the data until `:done`, then classify with `to_speech_adapter_error/4` (`:350`) | the chat adapter classifies from `%{}` (`lib/allm/providers/openai.ex:912-915`). **This adapter buffers the body instead**, so the 401 redactor and the `string_too_long` rule see the message |
| `sample_rate` reported | `24_000` for `:pcm` and `:wav`; `nil` otherwise | OpenAI guide (Decision #5) |
| `stream_synthesize_input/3` | **not implemented** (OpenAI's text-in streaming is the Realtime API; out of scope) | — |

> CORRECTED 2026-09-26 (26.5 probe): the Framing row is **CONFIRMED**, no longer inferred. `scripts/record_openai_audio_fixtures.exs` arm `stream_chunked` (gpt-4o-mini-tts, 405 characters, pcm) received `content-type: audio/pcm`, `transfer-encoding: chunked`, 1,600,800 bytes in 90 `{:data, _}` messages, first at 1,728 ms and last at 6,735 ms; arm `stream_mp3_tts1` (tts-1, mp3) 402,048 bytes in 278 messages, 1,353 ms to 2,137 ms. The streaming 401 is `text/plain` JSON with a masked key. Alternative E2 stands; no SSE fallback.

### Wire-field map — ElevenLabs HTTP (26.6, 26.7)

Base URL: `opts[:base_url] || "https://api.elevenlabs.io"`. Documented residency hosts: `api.us.elevenlabs.io`, `api.eu.residency.elevenlabs.io`, `api.in.residency.elevenlabs.io`, `api.sg.residency.elevenlabs.io` (https://elevenlabs.io/docs/api-reference/text-to-speech/convert). Auth: the `xi-api-key` header (https://elevenlabs.io/docs/api-reference/authentication). Key atom `:elevenlabs`, fetched after every gate.

| Concern | Wire | Status / probe arm |
|---------|------|--------------------|
| TTS endpoint | `POST /v1/text-to-speech/{voice_id}?output_format=…`, JSON | documented (convert page) |
| TTS body | `{"text", "model_id", "language_code"?, "voice_settings"?: {"speed"?, …}, "seed"?}`. `speed` → `voice_settings.speed` (documented range 0.7–1.2, WebSocket page; **not** validated locally) | documented |
| Default model | `@default_model "eleven_flash_v2_5"` | documented model id; arm `tts_default` 200 |
| Default voice | `@default_voice "JBFqnCBsd6RMkjVDRZzb"` | **UNVERIFIED**; arm `default_voice` (Decision #10) |
| Format map | the **Format table** below | documented list; per-row content-type arms |
| 200 content-type | `audio/mpeg` for mp3, and so on | **UNVERIFIED**. Arms `tts_mp3`, `tts_pcm`, `tts_wav`, `tts_opus` record it. **Outcome rule:** if any format's content-type is not `audio/*`, or does not map through `SpeechResponse.mime_to_format/1`, then for ElevenLabs only the adapter derives mime and format from the requested `output_format` (the Format table's mime column). This is a recorded deviation from §37 Decision #4 (derive from the response), justified by the probe and stated in the adapter `@doc` |
| Correlation | `request-id` response header → `response.id`; `character-cost` header → `raw` (`%{"character_cost" => n}`) | documented only in the SDK examples (https://elevenlabs.io/docs/api-reference/introduction). **UNVERIFIED** header names; arm `tts_default` records every response header name (not only named ones: the lesson in the Phase 25.5 RECORDS correction) |
| Unknown body field | ignored or 422 | **UNVERIFIED**. Arm `control` asserts `status in [200, 422]` and records which. **A 200 means acceptance arms prove nothing** (the OpenAI rule, §37 Decision #12): every row confirmed only by acceptance stays **inferred**, without halting. 422 makes them evidence. The two WebSocket paths get their own controls (`ws_control`, `rt_control`: an invented init field / query parameter) under the same rule |
| HTTP stream TTS | `POST /v1/text-to-speech/{voice_id}/stream?output_format=…`, same body, raw chunked | documented ("Streaming audio data"); framing **UNVERIFIED**. Arm `stream_chunked`, as for OpenAI |
| Input limit | per model: flash 40,000; multilingual_v2 10,000; v3 5,000 | documented (https://elevenlabs.io/docs/models). **No local gate** (model table drift). The provider's 400 `text_too_long` → `:context_length_exceeded`. Arm `too_long` (40,001 characters on flash is ≈$2, **too expensive**, so the arm uses `eleven_v3` at 5,001 characters ≈ $0.50. Cost table) |
| STT endpoint | `POST /v1/speech-to-text`, multipart `file`, `model_id`, `language_code`? | documented (https://elevenlabs.io/docs/api-reference/speech-to-text/convert) |
| STT default model | `@default_model "scribe_v2"` (`scribe_v1` is deprecated, https://elevenlabs.io/docs/models) | arm `stt_default` |
| STT response | `{"text", "language_code", "language_probability", "audio_duration_secs", "transcription_id", "words"}` → `text`, `language`, `duration_seconds`, `id`. `usage` is all-`nil` (there is no billing field) | documented; arm `stt_default` records it |
| STT size | "less than 5.0GB", minimum 100 ms | documented. `max_audio_bytes/0 = 4_999_999_999`, **not probed** (a GB-scale upload arm is prohibitively slow). `@doc` warns that the Req multipart path holds the bytes in memory |
| STT mime gate | the filename-extension rule, as in `OpenAI.Transcription` (Phase 25 wire map, "STT mime gate") | **inferred** (ElevenLabs may sniff content). Arm `stt_audio_bin`, with the outcome rule copied from 25.4 |
| Error envelope | `{"detail": {"type", "code", "message", "status", "request_id", "param"}}`; a 422 has `detail` as an array | documented (https://elevenlabs.io/docs/eleven-api/resources/errors). Arms `error_401`, `error_404_voice`, `error_422` |
| Key redaction | pattern `sk_[A-Za-z0-9]{16,}` (ElevenLabs key prefix) | **UNVERIFIED** prefix. Arm `error_401` records whether the body echoes the key. The planted-subject fixture plants `sk_…`, and the companion test asserts the OpenAI `sk-` pattern matches nothing in it and vice versa (`CLAUDE.md` redaction rule) |

**Format table** (`ALLM.Providers.Support.ElevenLabs.output_format/2`, the only home of this mapping):

| `format` | `sample_rate` accepted (nil → default) | `output_format` | mime |
|----------|----------------------------------------|-----------------|------|
| `:mp3` | 22050, 24000, **44100** | `mp3_22050_32`, `mp3_24000_48`, `mp3_44100_128` | `audio/mpeg` |
| `:opus` | **48000** | `opus_48000_64` | `audio/opus` |
| `:pcm` | 8000, 16000, 22050, **24000**, 32000, 44100, 48000 | `pcm_<rate>` | `audio/pcm` |
| `:wav` | 8000, 16000, 22050, **24000**, 32000, 44100, 48000 | `wav_<rate>` | `audio/wav` |
| `:aac`, `:flac` | — | `:unsupported_feature` | — |
| `nil` | — | `mp3_44100_128` (the provider default) | `audio/mpeg` |

The values come from the documented `output_format` list (convert page). **Bold** marks the default. Rates at 44.1 kHz for PCM/WAV need the Pro tier and 192 kbps MP3 needs Creator ("MP3 with 192kbps bitrate requires you to be subscribed to Creator tier or above. PCM and WAV formats with 44.1kHz sample rate requires you to be subscribed to Pro tier or above.", convert page). The provider's 403 is classified as `:unsupported_feature` (Error classification). The 24 kHz defaults avoid that tier gate.

### Wire-field map — ElevenLabs WebSocket TTS (26.7)

`wss://<host>/v1/text-to-speech/{voice_id}/stream-input?model_id=…&output_format=…` (https://elevenlabs.io/docs/api-reference/text-to-speech/v-1-text-to-speech-voice-id-stream-input). The `xi-api-key` goes in the **upgrade header** (Decision #3).

| Concern | Wire | Status |
|---------|------|--------|
| Init message | `{"text": " ", "voice_settings"?: {…}, "generation_config"?: {…}}` plus `options` (Decision #11) | documented |
| Text message | `{"text": chunk}`, forwarded verbatim. **No trailing space is injected**, although the docs say text "should end with a space": LLM deltas carry their own spacing, and injecting one would double it. Arm `ws_tokens` sends `["Hel", "lo", " world", "."]` and asserts 200-equivalent audio | **inferred** |
| End of input | `{"text": "", "flush": true}`, then `{"text": ""}` (close). Wait for `isFinal: true` | documented `flush` and close message; the combination is **inferred**. Arm `ws_end` |
| Server audio | `{"audio": base64, "isFinal"?, "normalizedAlignment"?, "alignment"?}` → `Base.decode64!` → `:audio_delta` (skip `nil`/`""` audio) | documented |
| Final | `{"isFinal": true}` with `audio: null` → `:speech_completed` | documented |
| Error frames | **undocumented**. Any server JSON with an `error` or `message_type` ending in `error`, or a close code ≠ 1000 → classified by Error classification (close-code rows) | **UNVERIFIED**. Arms `ws_bad_voice`, `ws_bad_key` record the actual shape. The classifier's WebSocket rows are rewritten in place from them |
| Upgrade failure | a non-101 status → HTTP classification table | inferred; arm `ws_bad_key` |
| Inactivity | `inactivity_timeout` query param (default 20 s, **max 180 s**) | documented. ALLM sends `inactivity_timeout = min(180, ceil(stream_timeout / 1000))`, and `180` when `stream_timeout` is `:infinity`, so the server does not close a slow LLM's socket before ALLM would. Because the cap is 180 s and ALLM's own timer resets on pump messages too (speech invariant 5), a `stream_timeout` above 180 s (or `:infinity`) would otherwise let the server close first |
| Keep-alive | when no client frame has been sent for half of `inactivity_timeout`, the adapter sends `{"text": " "}`, the documented keep-alive (a single space). The timer restarts on every client frame | documented (stream-input page, "send a single space character"); **inferred** that the space is not voiced mid-sentence. Arm `ws_end` includes one keep-alive and records the audio |

### Wire-field map — ElevenLabs realtime STT (26.8)

`wss://<host>/v1/speech-to-text/realtime?model_id=scribe_v2_realtime&audio_format=pcm_<rate>&commit_strategy=<vad|manual>&language_code=…` (https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime). `xi-api-key` in the upgrade header.

| Concern | Wire | Status |
|---------|------|--------|
| `stream_sample_rates/0` | `[8_000, 16_000, 22_050, 24_000, 44_100, 48_000]` (`pcm_*` values of `audio_format`) | documented |
| Default model | `@default_stream_model "scribe_v2_realtime"`, the only accepted value | documented |
| Client chunk | `{"message_type": "input_audio_chunk", "audio_base_64": b64, "commit": bool, "sample_rate": rate}`. A `:commit` element sets `commit: true` on an empty-audio chunk | documented fields. **An empty-audio commit is inferred**; arm `rt_manual_commit` |
| End of input | a final chunk with `commit: true`, then wait for `committed_transcript`, then close | **inferred**; arm `rt_end` |
| Server messages | `session_started{session_id}` → `:transcription_started`; `partial_transcript{text}` → `:partial_transcript`; `committed_transcript{text}` → `:committed_transcript`; the `warning` type → `Logger.warning/1` (deferred form), no event | documented |
| Timestamped commits | `committed_transcript_with_timestamps{text, language_code, words}` never emits an event of its own. It only attaches `language` to the pending segment (the next `:committed_transcript` to be emitted). A timestamped frame whose `text` equals the last emitted segment's text is that segment's late twin and is dropped, so its language never leaks onto a later segment. Each segment is therefore emitted exactly once, on its `committed_transcript` frame, so a provider that sends both frames never produces a duplicate segment | documented message names; **inferred** that both frames are sent per segment and in which order. Arm `rt_fox` records the order of both frame types |
| Partial semantics | replace, not append (`TranscriptionEvent` contract) | **inferred**. Arm `rt_fox` records every partial for the RECORDS transcript |
| Pacing | unpaced (faster than realtime) upload of a file | **UNVERIFIED** whether it is accepted. Arm `rt_fox` sends unpaced first. A `rate_limited`/`chunk_size_exceeded`/`queue_overflow` error flips the arm to 1× pacing and records that; the adapter never paces (the caller's mic does), and the guide states the finding |
| Error types | the `message_type` table in Error classification | documented names; mapping is design |

### Error classification (ElevenLabs, `Support.ElevenLabs.classify/2`, shared by both adapters)

This returns `{reason_atom, metadata}`, and each adapter wraps the result in its own error module.

| Source | Match | Reason |
|--------|-------|--------|
| body, any status | `detail.status` or `detail.code` is `quota_exceeded` / `insufficient_credits` (checked **before** the status rows; ElevenLabs has reportedly used 401 for quota, **UNVERIFIED**, arm `error_401` records the real shape) | `:invalid_request`, `metadata.code` |
| HTTP / upgrade | 401 | `:authentication_failed` |
| HTTP / upgrade | 402 (`insufficient_credits`, `payment_required`) | `:invalid_request`, `metadata.code`. Not retryable; quota is not rate |
| HTTP / upgrade | 403 `feature_not_available` / `insufficient_permissions` | `:unsupported_feature` |
| HTTP / upgrade | other 403 | `:authentication_failed` |
| HTTP / upgrade | 400 `text_too_long` | `:context_length_exceeded` |
| HTTP / upgrade | 400 / 404 / 409 / 422 (other) | `:invalid_request` |
| HTTP / upgrade | 429 (`rate_limit_*`, `concurrent_limit_exceeded`, `system_busy`) | `:rate_limited`, `retry_after_ms` from `Retry-After` |
| HTTP / upgrade | 500, 502, 503, 504 | `:provider_unavailable` |
| WS `message_type` | `auth_error`, `unaccepted_terms` | `:authentication_failed` |
| WS `message_type` | `quota_exceeded` | `:invalid_request` |
| WS `message_type` | `rate_limited`, `commit_throttled`, `queue_overflow`, `resource_exhausted` | `:rate_limited` |
| WS `message_type` | `session_time_limit_exceeded` | `:context_length_exceeded` |
| WS `message_type` | `input_error`, `invalid_request`, `chunk_size_exceeded`, `insufficient_audio_activity` | `:invalid_request` |
| WS `message_type` | `error`, `transcriber_error` | `:provider_unavailable` |
| WS close | code 1008 (policy) | `:authentication_failed` (**inferred**) |
| WS close | any other code ≠ 1000 before a terminal event | `:network_error` |
| transport | Mint/Finch error | `:network_error` |
| timer | `:stream_timeout` expiry | `:timeout` |
| anything else | — | `:unknown` |

The HTTP 400/401/404/422 rows are **documented** codes. The WS rows are **documented names with a designed mapping**. The close-code rows are **inferred**, and the arms above settle them.

### Script contract (streaming)

Real adapters hand off to their Fake when a script is present, **before their own gates**. This is the Phase 25 rule (`steering/2026-09-24_SST_SUPPORT.md:467-476`), extended to `stream_synthesize/2 → FakeSpeech.stream_synthesize/2`, `stream_synthesize_input/3 → FakeSpeech.stream_synthesize_input/3` and `stream_transcribe/3 → FakeTranscription.stream_transcribe/3`, with the same script keys. `ElevenLabs.Transcription` passes its `stream_sample_rates()` to the Fake as `adapter_opts[:stream_sample_rates]`, the counterpart of the Phase 25 `max_audio_bytes` hand-off.

---

## Module Tree

```
mix.exs                                        (MODIFY — 26.1/26.2/26.3/26.4/26.6/26.7 groups_for_modules; 26.7 +{:mint_web_socket, "~> 1.0"})
mix.lock                                       (MODIFY — 26.7)
conformance/mix.lock                           (MODIFY — 26.7, `cd conformance && mix deps.get` picks up :mint_web_socket through the path dep on allm)
lib/allm.ex                                    (MODIFY — 26.2, +:sample_rate in @speech_request_field_opts :1351 (the fail-closed symmetry test test/allm/allm_synthesize_test.exs:143-162 goes red otherwise); 26.4, 3 public fns + internals + "When to reach for what" rows; strike both "## No streaming yet" sections :1467, :1605)
lib/allm/
├── speech_event.ex                            (NEW — 26.2)
├── transcription_event.ex                     (NEW — 26.2)
├── transcription_stream_request.ex            (NEW — 26.2)
├── speech_request.ex                          (MODIFY — 26.2, +sample_rate)
├── speech_response.ex                         (MODIFY — 26.2, +sample_rate)
├── serializer.ex                              (MODIFY — 26.2, +1 @known_modules)
├── validate.ex                                (MODIFY — 26.2, speech_request/2 + transcription_stream_request/1)
├── error/speech_adapter_error.ex              (MODIFY — 26.2, +:unsupported_feature, moduledoc :10, doctest :73)
├── error/transcription_adapter_error.ex       (MODIFY — 26.2, same, :11, :75)
├── speech_stream_adapter.ex                   (NEW — 26.3)
├── transcription_stream_adapter.ex            (NEW — 26.3)
├── speech_adapter.ex                          (MODIFY — 26.3, "HTTP transport guidance" no longer says "there is no streaming counterpart")
├── audio_stream.ex                            (NEW — 26.4)
├── telemetry.ex                               (MODIFY — 26.4, +2 span names both lists, event table row)
└── providers/
    ├── fake_speech.ex                         (MODIFY — 26.3, both stream callbacks, {:events,_} entry)
    ├── fake_transcription.ex                  (MODIFY — 26.3, stream_transcribe/3, stream_sample_rates/0)
    ├── openai/speech.ex                       (MODIFY — 26.1 helper migration; 26.5 stream_synthesize/2)
    ├── elevenlabs/speech.ex                   (NEW — 26.6; MODIFY — 26.7 streaming)
    ├── elevenlabs/transcription.ex            (NEW — 26.6, built on Support.TranscriptionAdapter; MODIFY — 26.8 stream_transcribe/3)
    ├── openai.ex, anthropic.ex, gemini.ex     (MODIFY — 26.1, helper migration)
    ├── openai/{embeddings,images,moderation,transcription}.ex (MODIFY — 26.1, helper migration; transcription.ex also → Support.TranscriptionAdapter)
    ├── gemini/{embeddings,images,transcription}.ex (MODIFY — 26.1, helper migration; transcription.ex also → Support.TranscriptionAdapter)
    ├── voyage/embeddings.ex                   (MODIFY — 26.1, helper migration)
    └── support/
        ├── http_response.ex                   (NEW — 26.1)
        ├── transcription_adapter.ex           (NEW — 26.1, @doc false defs parameterised by provider atom: the cloned STT-contract helpers)
        ├── elevenlabs.ex                      (NEW — 26.6, headers/base_url/output_format/classify/redact_key_material)
        ├── web_socket.ex                      (NEW — 26.7, behaviour ALLM.Providers.Support.WebSocket only)
        ├── web_socket/mint.ex                 (NEW — 26.7, ALLM.Providers.Support.WebSocket.Mint, the default impl)
        └── input_pump.ex                      (NEW — 26.3, first used by the Fakes)

conformance/lib/allm/test/
├── speech_stream_adapter_conformance.ex       (NEW — 26.3)
├── speech_input_stream_adapter_conformance.ex (NEW — 26.3)
└── transcription_stream_adapter_conformance.ex (NEW — 26.3)
conformance/test/support/fixtures/scripted_{speech_stream,speech_input_stream,transcription_stream}_stub.ex (NEW — 26.3)
conformance/test/allm/test/{speech_stream,speech_input_stream,transcription_stream}_adapter_conformance_test.exs (NEW — 26.3)

test/allm/
├── speech_event_test.exs                      (NEW — 26.2)
├── transcription_event_test.exs               (NEW — 26.2)
├── transcription_stream_request_test.exs      (NEW — 26.2)
├── speech_request_test.exs, speech_response_test.exs (MODIFY — 26.2, sample_rate round-trip)
├── validate_speech_request_test.exs           (MODIFY — 26.2, sample_rate + input: :streamed rows)
├── validate_transcription_stream_request_test.exs (NEW — 26.2)
├── error/speech_adapter_error_test.exs        (MODIFY — 26.2, contract flip :23, :27-30)
├── error/transcription_adapter_error_test.exs (MODIFY — 26.2, contract flip :24, :28-31)
├── speech_stream_adapter_test.exs             (NEW — 26.3, FakeSpeech vs both speech stream suites + behaviour surface)
├── transcription_stream_adapter_test.exs      (NEW — 26.3)
├── audio_stream_test.exs                      (NEW — 26.4)
├── allm_stream_synthesize_test.exs            (NEW — 26.4, both façades)
├── allm_stream_transcribe_test.exs            (NEW — 26.4)
├── audio_stream_equivalence_property_test.exs (NEW — 26.4)
└── providers/
    ├── fake_speech_test.exs, fake_transcription_test.exs (MODIFY — 26.3, stream rows)
    ├── support/http_response_test.exs         (NEW — 26.1)
    ├── support/transcription_adapter_test.exs (NEW — 26.1)
    ├── support/input_pump_test.exs            (NEW — 26.3, composition behaviours 2–7)
    ├── support/web_socket_test.exs            (NEW — 26.7, WebSocket.Mint against the local ws_test_server: handshake, upgrade status, ping/pong, close)
    ├── openai/speech_stream_test.exs          (NEW — 26.5, FinchStub wire + halt + timeout)
    ├── openai/speech_stream_conformance_test.exs (NEW — 26.5)
    ├── elevenlabs/speech_test.exs             (NEW — 26.6, seams)
    ├── elevenlabs/speech_wire_test.exs        (NEW — 26.6, Req.Test + provenance)
    ├── elevenlabs/speech_conformance_test.exs (NEW — 26.6; MODIFY — 26.7 +2 stream suites)
    ├── elevenlabs/speech_stream_test.exs      (NEW — 26.7, FinchStub + WebSocketStub)
    ├── elevenlabs/transcription_test.exs      (NEW — 26.6)
    ├── elevenlabs/transcription_wire_test.exs (NEW — 26.6)
    ├── elevenlabs/transcription_conformance_test.exs (NEW — 26.6; MODIFY — 26.8 +stream suite)
    └── elevenlabs/transcription_stream_test.exs (NEW — 26.8, WebSocketStub)

test/support/
├── fake_audio_fixtures.ex                     (MODIFY — 26.3, stream script builders)
├── finch_stub.ex                              (MODIFY — 26.3 Agent-backed install mode (state in an Agent whose pid rides in opts; frames sent to the `async_request/3` caller, not the installer, by a sender `spawn_link`ed to that caller as in real Finch) for pump-reduced inputs; 26.5 `:initial_headers` + `:error_body` options)
├── web_socket_stub.ex                         (NEW — 26.7, Agent-backed from the start)
├── ws_test_server.ex                          (NEW — 26.7, minimal :gen_tcp RFC 6455 server for WebSocket.Mint; no new dependency)
├── elevenlabs_fixtures.ex                     (NEW — 26.6, loaders delegating to a drop_comment/1)
├── pcm.ex                                     (NEW — 26.8, `wav_pcm_chunks/2`: WAV → data-chunk PCM16 slices; a `0xFFFFFFFF` data size means "to end of file")
└── openai_fixtures.ex                         (MODIFY — 26.5, stream fixture loaders)

test/fixtures/openai/speech/recorded/stream_*.json       (NEW — 26.5)
test/fixtures/elevenlabs/{speech,transcriptions,speech_stream,realtime}/{recorded,synthesized}/*.json (NEW — 26.6/26.7/26.8)
test/fixtures/elevenlabs/README.md             (NEW — 26.6)

scripts/
├── record_openai_audio_fixtures.exs           (MODIFY — 26.5, +stream arms behind the existing overwrite guard)
└── record_elevenlabs_audio_fixtures.exs       (NEW — 26.6; MODIFY — 26.7 WS TTS arms; 26.8 realtime arms)

test/
├── layer_a_docs_test.exs                      (MODIFY — 26.2, +3 @layer_a)
└── allm_facade_doctest_inventory_test.exs     (MODIFY — 26.4, +3 @public_facade)

guides/audio.md                                (MODIFY — 26.9, streaming + ElevenLabs sections)
examples/25_stream_speech.exs                  (NEW — 26.9, `# Provider: openai, elevenlabs`)
examples/26_stream_transcribe.exs              (NEW — 26.9, `# Provider: elevenlabs`)
examples/27_voice_loop.exs                     (NEW — 26.9, `# Provider: elevenlabs`; chat hop on an explicit OpenAI engine, skip line when that key is absent)
examples/23_synthesize_speech.exs              (MODIFY — 26.9, marker +elevenlabs; body: voice from the provider row's `speech_voice` key, mime assertion follows the 26.6 content-type outcome)
examples/24_transcribe_audio.exs               (MODIFY — 26.9, marker +elevenlabs)
examples/_helpers.exs                          (MODIFY — 26.9, elevenlabs @providers row with adapter: nil; `speech_voice` on the openai and elevenlabs rows; chat_provider?/1)
examples/fixtures/quick_brown_fox.wav          (NEW — 26.9, copy of test/fixtures/audio/quick_brown_fox.wav: streaming WAV, RIFF and data sizes 0xFFFFFFFF, 24 kHz mono s16, 182,400 data bytes)
examples/run_all.exs                           (MODIFY — 26.9, marker-less scripts run only when chat_provider?/1)
examples/README.md                             (MODIFY — 26.9)
test/allm/examples_helpers_test.exs            (MODIFY — 26.9, chat_provider?/1 per row; elevenlabs row shape)
CHANGELOG.md                                   (MODIFY — 26.9)
CLAUDE.md                                      (MODIFY — 26.9, WebSocket transport rule, Decision #3; the audio-stream exception to the fold-into-response invariant, Decision #7)
steering/allm_engine_session_streaming_spec_v0_2.md (MODIFY — 26.9)
.work/ASKS.md                                  (MODIFY — 26.1 both DEFERRED-DRY tickets: HTTP helpers narrowed, transcription helpers closed; 26.10)
```

**Recorded fixtures for binary and streamed bodies.** These use the Phase 25 envelope (`{"status", "headers", "body_base64", "byte_size", "sha256"}`, `steering/2026-09-24_SST_SUPPORT.md:626`), extended for streams with `"chunks": [{"byte_size", "t_ms"}]`, where `t_ms` is the arrival time since request. WebSocket sessions record `"frames": [{"dir": "in" | "out", "t_ms", "text"}]`. Audio payload bytes are replaced by `"<N bytes>"` in `out` frames, **except** the first frame (kept whole, so a decode test has real base64), and `in` audio is never stored. The raw-bytes provenance test applies to every file.

### Repo-wide audit-gate obligations

| Gate | Fails | Fires in | Row |
|------|-------|----------|-----|
| `test/groups_for_modules_audit_test.exs` | closed | 26.1, 26.2, 26.3, 26.4, 26.6, 26.7 | `mix.exs` `groups_for_modules` (`:111-148`): events + stream request → `"Data types"`; 2 behaviours → `Behaviours`; `AudioStream` → the group holding `ALLM.StreamCollector` (the implementer greps `mix.exs`); 2 adapters + 6 support modules (`HTTPResponse` and `TranscriptionAdapter` in 26.1, `InputPump` in 26.3, `ElevenLabs` in 26.6, `WebSocket` and `WebSocket.Mint` in 26.7, one row each) → `Providers`. Register in the creating sub-phase only |
| `test/layer_a_docs_test.exs` | **open** | 26.2 | `@layer_a` +3 (`SpeechEvent`, `TranscriptionEvent`, `TranscriptionStreamRequest`); count delta asserted |
| `test/allm_facade_doctest_inventory_test.exs` | **open** | 26.4 | `@public_facade` +`stream_synthesize: 3`, `stream_synthesize_input: 3`, `stream_transcribe: 3` |
| `test/package_files_extras_consistency_test.exs`, `test/guides_test.exs`, `test/guides_doctest_test.exs` | — | 26.9 | no new guide (`guides/audio.md` exists), so no row. The modified guide's `iex>` blocks are still executed and its new fences compiled by `scripts/check_guide_fences.exs` |

### Path-existence sanity check

```bash
ls -d lib/allm/providers lib/allm/providers/support conformance/lib/allm/test \
      conformance/test/support/fixtures conformance/test/allm/test test/allm/providers \
      test/allm/providers/openai test/support test/fixtures scripts guides examples/fixtures
```

Run 2026-09-25 at `7499917`: all exist. New directories: `lib/allm/providers/elevenlabs/`, `lib/allm/providers/support/web_socket/`, `test/allm/providers/elevenlabs/`, `test/fixtures/elevenlabs/…`.

---

## Phases

**`README.md` is out of tree for all ten sub-phases.** At 26.1 start: `git stash push -- README.md` if it is dirty.

**Uniform Verification block**, part of every sub-phase (rule 31):

```bash
mix test && mix test --seed 0
mix format --check-formatted && mix credo --strict && mix dialyzer
mix run scripts/audit_user_docs.exs <each NEW lib/ or guides/ file of this sub-phase>   # 0 hits per file
grep -rl 'Keys.put(\|Logger.configure(\|System.put_env(\|:telemetry.attach' test/  # async: false modules only
```

When a sub-phase touches `conformance/`, the block also runs `cd conformance && mix test && mix credo --strict && mix format --check-formatted`.

**Live-gate invocation form** (subshell, per the 25.4.4 reasoning: an exported key defeats every keyless gate test): `( set -a; . ./.env; set +a; mix run scripts/<recorder>.exs )`.

### Phase 26.1 — Refactor: `Support.HTTPResponse` + `Support.TranscriptionAdapter` (Layer B)

**Why first:** the ElevenLabs adapters would otherwise become the 13th and 14th copies of the provider HTTP helpers. The Phase 25 `[DEFERRED-DRY]` predicate at `7499917`:

```
grep -roE 'defp (header_value|…|apply_receive_timeout)\(' lib/allm/providers/ | sort -u | cut -d: -f2 | sort | uniq -c | awk '$1>1'
```

(full alternation in `steering/2026-09-24_SST_SUPPORT_RECORDS.md:242`) → 13 lines: `decode_error_body` 12, `maybe_apply_req_test_stub` 12, and 9 each for `header_value`, `header_value_to_string`, `maybe_apply_request_timeout`, `parse_retry_after`, `retry_after_ms`, `build_metadata`, `sanitize_cause`. agent-spec/DESIGN.md's cloned-helper-family rule requires a support-module row, and `agent-spec/IMPLEMENTATION.md:235` ("Migration on extraction") requires every copy to migrate in the same commit.

**The transcription-helper ticket binds here too.** `.work/ASKS.md:155` (the 25.5 `[DEFERRED-DRY]`) lists the STT-contract helpers cloned between `lib/allm/providers/openai/transcription.ex` and `lib/allm/providers/gemini/transcription.ex`, byte-identical once the provider atom is abstracted: `fetch_transcription_script/1`, `with_own_cap/1`, `measure/2`, `gate_size/2`, `unresolvable_error/2`, `stub_error/1`, `do_transcribe/2`, `run_one_attempt/3`, `transport_error/4`, `resolve_bytes/2` (and `build_metadata/2`, which the HTTP ticket also scores). They encode the STT contract: gate order ahead of `Keys.fetch!/2`, the Fake hand-off with `adapter_opts[:max_audio_bytes]`, one attempt, `Jason.DecodeError` sanitisation. Its re-filed disposition (`.work/ASKS.md:169`) names *"the first commit that adds a third transcription adapter (e.g. ElevenLabs) … — a third copy must not land"* as owner. `ElevenLabs.Transcription` (26.6) is that third adapter, so the extraction lands here, ahead of it. Predicate at `7499917` (the ticket's own, run 2026-09-26): 10 lines (`gate_size` and `measure` 4 each, the other eight 2 each).

**Scope, `Support.TranscriptionAdapter`:** `@doc false` + `@spec` defs, parameterised by provider atom. Where a body reads a module attribute (`@max_audio_bytes`) or calls a provider-private function (`gate_audio/2`, `build_request/2`, `decode_response/4`, `to_transcription_adapter_error/4`), the value or the calling adapter module is a further argument. Both transcription adapters migrate every copy in this commit. `ElevenLabs.Transcription` uses the module from its first commit.

**Scope, `Support.HTTPResponse`:** extract only the helpers whose copies are **byte-identical** across files. Discovery works like this: for each helper name, collect the function bodies across `lib/allm/providers/**` with a throwaway script, and group them by normalized text. A body group of size ≥ 2 moves. Variant bodies (e.g. `decode_error_body/1`'s JSON-decoding variant vs `openai/moderation.ex:987-988`'s `%{}` variant) stay put, and each variant is listed in RECORDS with a one-line reason. **Hand-edit; the discovery script is not committed.** This is rule 30's explicit statement: a bulk transform is not in scope, only a bulk *inventory*.

> CORRECTED 2026-09-26: the JSON-decoding `decode_error_body/1` body is not a lone variant. It has three identical copies (`openai/speech.ex`, `openai/transcription.ex`, `gemini/transcription.ex`), so the size ≥ 2 rule moves it, as `HTTPResponse.decode_json_error_body/1`. Two groups of `sanitize_cause/1` had ≥ 2 copies as well; only the offset-resetting group moved (see RECORDS §26.1).

#### 26.1.1 Test Plan
- `test/allm/providers/support/http_response_test.exs`: one test per extracted public helper (`@doc false` + `@spec` seams). For example, `retry_after_ms/1` on `[{"retry-after", "2"}]` → `2000`, and on an HTTP-date → a positive integer; `header_value/2` is case-insensitive.

  > CORRECTED 2026-09-26: an HTTP-date `Retry-After` returns `nil`, not a positive integer. Every pre-extraction copy returned `nil` for it: the two that routed it through `parse_http_date/1` (`openai.ex`, `openai/images.ex`) hit a stub that was `defp parse_http_date(_value), do: nil`. Returning a number would have changed behaviour, which a refactor may not do. See RECORDS §26.1.
- `test/allm/providers/support/transcription_adapter_test.exs`: one test per extracted helper, each run for both `:openai` and `:gemini` (falsifier: a helper that hard-codes one provider atom in `provider:` or a message).
- **Every prior-phase provider test stays green unmodified.** That is the behaviour-preservation pin. **Mutation check, per helper group:** for each moved helper (in either module), break it in the new module and run the suite of every file that migrated *that* helper; at least one test in each such suite must fail. A mutant is only meaningful against a file that actually called the helper (e.g. 3 of the 12 `maybe_apply_req_test_stub` files define no `retry_after_ms/1`, so a `retry_after_ms/1` mutant says nothing about them). Record the helper × provider failure-count table in RECORDS. A cell with 0 failures means that copy was unpinned, and a pinning test is added to that provider's existing test file in this sub-phase (listed in RECORDS; the Module Tree's `test/` rows gain it at that point).

#### 26.1.2 Implementation Checklist
- [ ] `lib/allm/providers/support/http_response.ex` with the identical-body helpers
- [ ] `lib/allm/providers/support/transcription_adapter.ex` with the STT-contract helpers; migrate `openai/transcription.ex` and `gemini/transcription.ex`
- [ ] Migrate every copy of each moved helper (the discovery output is the file list)
- [ ] `groups_for_modules` rows (both modules)
- [ ] Update the ASKS `[DEFERRED-DRY]` tickets: HTTP helpers — moved helpers are closed; variants remain, with a predicate narrowed to the variant names. Transcription helpers (`.work/ASKS.md:155`, `:169`) — closed, with the predicate's empty output pasted

#### 26.1.3 Verification
Uniform block, plus two predicates:
- **HTTP helpers** (must print only variant-group helpers, each named in RECORDS): the Phase 25 predicate above.
- **Transcription helpers** (`.work/ASKS.md:169`; must print nothing, exit code pasted):

  ```
  grep -roE 'defp (with_own_cap|fetch_transcription_script|do_transcribe|run_one_attempt|transport_error|unresolvable_error|gate_size|measure|resolve_bytes|stub_error)\(' lib/allm/providers/*/transcription.ex | cut -d: -f2 | sort | uniq -c | awk '$1>1'
  ```

**Success criterion:** zero changes to existing test assertions (new pinning tests are allowed and listed in RECORDS); the per-group mutation check fails every file that migrated the mutated helper; the HTTP predicate's output equals the RECORDS variant list; the transcription predicate prints nothing.

### Phase 26.2 — Layer A: events, stream request, fields, reasons (Layer A)

#### 26.2.1 Test Plan
`speech_event_test.exs` / `transcription_event_test.exs`:
- One test per variant: its constructor, and `event?/1` true on it. `event?/1` is false on `{:audio_delta, 1}`, `{:unknown, %{}}` and `{:text_delta, %{…}}`. The last is a chat event, and the falsifier is a union that accepts chat events.
- `audio_delta("")` raises `ArgumentError`.
- ETF round-trip of a non-UTF-8 `:audio_delta`.
- A moduledoc-stated grammar check: `SpeechEvent.valid_sequence?/1` is **not** added (YAGNI); the grammar is bound in the conformance suites.

`transcription_stream_request_test.exs`:
- Defaults are `16_000` / `:vad`.
- An unknown key raises `KeyError`.
- ETF + JSON round-trip with `sample_rate: 8_000, commit_strategy: :manual`. The falsifier is a decode that returns `16_000` / `:vad`.
- A JSON payload lacking both keys decodes to the defaults.
- `commit_strategies() == [:vad, :manual]`.

`speech_request_test.exs` / `speech_response_test.exs`: `sample_rate: 24_000` survives JSON; an absent key decodes to `nil`. **`SpeechRequest.sample_rate`: bare `struct!/2`, no guard; validator row only** (`SpeechRequest.new(sample_rate: -1)` constructs, and `Validate.speech_request/1` reports `{:sample_rate, :out_of_range}`). `SpeechResponse.sample_rate` is likewise unguarded (no validator: adapters build it), and every `TranscriptionStreamRequest` field is unguarded with its validator rows (`CLAUDE.md` Layer-A constructor rule).

`validate_*`: one test per new vocabulary row, plus `speech_request(%SpeechRequest{input: ""}, input: :streamed) == :ok` (the falsifier is an `:empty` error) and `speech_request(%SpeechRequest{input: ""}) != :ok` (the default is unchanged).

Error tests: the contract flip (Layer A enum table). `legal_reasons` lengths become 10 and 11; `:unsupported_feature` is a member of both.

#### 26.2.2 Implementation Checklist
- [ ] Three new modules, the two struct fields, and the two reason additions (type + `@legal_reasons` + moduledoc reason table + doctests)
- [ ] `Validate.speech_request/2`, `transcription_stream_request/1`
- [ ] `lib/allm.ex` `@speech_request_field_opts` gains `:sample_rate` (falsifier: `test/allm/allm_synthesize_test.exs:143-162`, the fail-closed symmetry test, red at this sub-phase's gate otherwise)
- [ ] `@known_modules` +1; `@layer_a` +3 (**fail-open**); `groups_for_modules`
- [ ] Contract-flip audit dispositions in RECORDS

#### 26.2.3 Verification
Targeted files + uniform block. **Success criterion:** `layer_a_docs_test.exs`'s generated test count rises by exactly the three entries' tests; the contract-flip grep hits all carry dispositions.

### Phase 26.3 — Behaviours, Fake streaming, conformance (Layer B)

#### 26.3.1 Test Plan
- **Behaviour surface.** `behaviour_info(:callbacks)` and `(:optional_callbacks)` return the exact lists. A module implementing only `stream_synthesize/2` compiles without warning, using the `embedding_adapter_test.exs:28-45` pattern.
- **`FakeSpeech` passes both speech stream suites. `FakeTranscription` passes the transcription stream suite.**
- **`fake_speech_test.exs` stream rows:**
  - `chunk_bytes: 4` on `"FAKE-AUDIO:hi"` (13 bytes) gives 4 deltas of sizes `[4, 4, 4, 1]`. The falsifier is one delta.
  - The `{:events, _}` entry is emitted verbatim.
  - The same entry through `synthesize/2` gives `:stream_only_script_entry`.
  - Input form with `["a", "", "b"]` gives exactly two deltas, `"FAKE-AUDIO:a"` and `"FAKE-AUDIO:b"`.
  - An empty input is rejected before a script entry is consumed.
- **Stream cursor timing (both Fakes):** two stream calls on a two-entry script, neither reduced, consume both entries (a third call finds the script exhausted); `{:retry_until_call, 2}` on a stream path gives a first call whose stream is exactly `[{:error, %{reason: :rate_limited}}]` and a second call that emits the next entry.
- **`fake_transcription_test.exs` stream rows:**
  - Script `{:ok, "the quick fox"}` gives partials `["the", "the quick", "the quick fox"]`, then one committed segment with that text.
  - 32,000 bytes at 16 kHz gives `duration_seconds == 1.0`.
  - Script `{:ok, " the quick "}` gives `completed.text == "the quick"` on the stream path, where the non-streaming path returns `" the quick "` (the normative trim-and-join; the equivalence property's masking-divergence row).
  - An input whose total length is odd (e.g. `[<<1, 2, 3>>]`) ends with `:invalid_input_chunk` at end of input; `[<<1, 2, 3>>, <<4>>]` succeeds (the remainder carries).
  - `sample_rate: 44_100` gives a synchronous `:invalid_request`.
  - `adapter_opts[:stream_sample_rates]` overrides the rate set.
- **Conformance meta-tests** per suite: four invariants.
- **`input_pump_test.exs`:** composition behaviours 2–7, one named test each (the Layer B pump contract).
- **`finch_stub.ex` Agent-backed mode:** an `ALLM.stream_generate/3` Fake-over-`FinchStub` input reduced inside a spawned process receives its frames (falsifier: `"no stub installed for ref"`, `test/support/finch_stub.ex:119`). The frame sender is `spawn_link`ed to the `async_request/3` caller (pinned in `input_pump_test.exs`, behaviour 6). A test pins that the default install mode is unchanged.
- **Non-streaming `FakeSpeech.synthesize/2`** reports `sample_rate: request.sample_rate` (the equivalence property compares it).
- **Mailbox-dependent input:** `stream_synthesize_input` over `FakeSpeech` with `Stream.repeatedly(fn -> receive do {:t, x} -> x end end)` and `stream_timeout: 100` ends with `:timeout` even though the test process sends `{:t, "a"}` to itself (Decision #4; falsifier: a Fake that reduces input in the caller and succeeds).

#### 26.3.2 Implementation Checklist
- [ ] Two behaviours with moduledocs carrying the invariants, a minimum skeleton, and the cleanup invariant as a numbered invariant (not prose)
- [ ] `Support.InputPump` (spawn_monitor + watchdog + credit window + string-only errors); `finch_stub.ex` Agent-backed mode
- [ ] Fake stream callbacks (input reduced through the pump) + `{:events, _}` entry + moduledoc script table; non-streaming `FakeSpeech` reports `sample_rate`
- [ ] Three suites + stubs + meta-tests; `speech_adapter.ex` transport-guidance edit
- [ ] `groups_for_modules`

#### 26.3.3 Verification
Targeted + uniform + conformance block. **Success criterion:** each Fake passes 6/6 (speech), 6/6 (input), 6/6 (transcription).

#### 26.3.4 Binding on later sub-phases
- Stream pre-flight gates run before `Keys.fetch!/2` **and before the enumerable is returned**. Binds 26.5–26.8. Each adapter's conformance invocation runs keyless with a raising `:plug`/`:finch_module`/`:ws_module` in `:gate_opts`.
- Script hand-off precedes gates. Binds 26.5–26.8.

### Phase 26.4 — Façades, `AudioStream`, telemetry (Layer C)

#### 26.4.1 Test Plan
In `allm_stream_synthesize_test.exs` / `allm_stream_transcribe_test.exs`, over the Fakes. Rows mirror the Phase 25 façade matrix (`steering/2026-09-24_SST_SUPPORT.md:754-762`) **for every one of the three façades**. This is agent-spec/DESIGN.md rule 10, the matrix across both paths.

- **Input shapes:**
  - A binary or request struct for `stream_synthesize`.
  - An enumerable plus `opts[:request]` for the input forms. `opts[:request]` is authoritative: an opt-supplied `:voice` alongside it does not reach the adapter.
- **Gate order:**
  - Nil slot → `:no_*_adapter`.
  - A slot with only `synthesize/2` (a Phase 25-style adapter defined in the test) → `:missing_stream_adapter`. The falsifier is `UndefinedFunctionError`.
  - A slot with `stream_synthesize/2` but not the input callback → `:missing_stream_adapter` from `stream_synthesize_input/3`.
  - An invalid request → `ValidationError`.
  - Nil slot plus an invalid request → still the slot error.
  - Nil slot plus a non-enumerable input → still the slot error; a streaming slot plus a non-enumerable input → the input-shape `ValidationError` (gate 3).
- **Model:**
  - `engine.speech_model` fills a nil `request.model` for both speech façades.
  - `stream_transcribe/3` with `engine.transcription_model: "scribe_v2"` dispatches `request.model == nil`. The falsifier is `"scribe_v2"` reaching the Fake (Decision #6).
- **Opts:**
  - The allow-list symmetry test is computed from `Map.keys/1` (all three).
  - `stream: true` is dropped.
  - The cursor isolation test uses two content-equal engines.
- **Laziness:** `stream_synthesize/3` returns before any adapter I/O. Tested with a test-local streaming adapter whose `Stream.resource/3` start function sends `:started` to the test process: `refute_received :started` after the façade returns, `assert_received :started` after `Enum.take(events, 1)`.
- **Wrapper cleanup:** when the invariant-3 `ArgumentError` fires, the inner stream's after function still runs (the same test adapter sends `:cleaned_up` from it).
- **Input shape (gate 3):** `stream_transcribe(engine, "pcm-bytes", [])` and `stream_synthesize_input(engine, 42, [])` return a synchronous `ValidationError` whose errors include `{:input, :invalid_shape}`.
- **Wrapper:**
  - An adapter emitting `{:text_delta, _}` raises `ArgumentError` naming the adapter and "invariant 3" when reduced.
  - `[:allm, :audio, :first_chunk]` fires exactly once, with `latency > 0`, on a 3-delta stream (`test/support/telemetry_capture.ex`). It fires zero times on a stream that errors before any delta.
- **Spans:** `:start` and `:stop` fire for each façade, `:stop` metadata `response` is `nil`, and `stream_synthesize_input/3` uses `:stream_synthesize` with `input_length: nil`.

`audio_stream_test.exs`:
- `collect_speech/1`: the grammar-happy path. `{:error, e}` after 2 deltas of 5 bytes → `{:error, %{metadata: %{bytes_received: 10}}}`. A truncated stream (no terminal) → `:malformed_response`.
- `collect_transcription/1` takes the terminal's `text`.
- `text_deltas/1` over a scripted `ALLM.stream_generate/3` Fake stream returns exactly the scripted deltas; a script ending in `{:error, rate_limited}` after two deltas makes `ALLM.stream_synthesize_input/3` over the Fake end with `{:error, %{metadata: %{cause: :input_raised}}}`, and `err.cause.message` contains `rate_limited`. `collect_speech/1` returns `{:error, _}`, never `{:ok, _}`, and the calling process is alive. Falsifier: a halting implementation yields `{:ok, %SpeechResponse{}}`.
- An input-failure error round-trips `Jason.encode!/1`, with `metadata.cause == :input_raised` and `err.cause == %{kind: :error, message: _}` (falsifier: the raw exception on `err.cause`, Decision #7).

`audio_stream_equivalence_property_test.exs` (StreamData, ≥100 runs):
- For a random script of bytes and a random `chunk_bytes`: `synthesize(engine, req)` bytes == `stream_synthesize(engine, req) |> collect_speech` bytes, and `format`, `sample_rate` and `metadata` are equal.
- For a random transcript: `transcribe(...).text == stream_transcribe(...) |> collect_transcription |> .text`. The generator produces **non-empty words joined by single spaces** (no leading, trailing or repeated whitespace), because `completed.text` is a trimmed single-space join of committed segments (`TranscriptionEvent` semantics) while the non-streaming Fake returns its script text verbatim. Both engines are built with `transcription_model: nil`, because `transcribe/3` stamps `engine.transcription_model` onto a nil `request.model` (`lib/allm.ex:2235`) and `stream_transcribe/3` deliberately does not (Decision #6).
- **Relaxation budget** (every `SpeechResponse`/`TranscriptionResponse` field not compared, with its mechanism):

  | Field | Why not compared | Risk |
  |-------|------------------|------|
  | `raw` | `collect_*` always sets `nil`; `FakeSpeech.synthesize/2` also sets `nil`, but the field is provider-shaped by contract | tolerable |
  | `id` | the streaming Fake emits no provider id; the non-streaming Fake sets none either. Not compared so a Fake change on one path does not fail an unrelated property | tolerable |
  | `duration_seconds` (transcription) | the non-streaming `FakeTranscription` never sets it (`build_response/3`, `lib/allm/providers/fake_transcription.ex:381-390`), while the streaming Fake computes `bytes / (rate * 2)`. Pinned instead by the 26.3 row "32,000 bytes at 16 kHz gives `duration_seconds == 1.0`" | tolerable |
  | `model` (transcription) | compared, but only because both engines carry `transcription_model: nil`. With a non-nil engine model the two paths differ **by design** (Decision #6); that divergence is pinned by the 26.4 façade row "`stream_transcribe/3` with `engine.transcription_model: \"scribe_v2\"` dispatches `request.model == nil`" | tolerable |

  **Masking divergence:**

  | Divergence | Why the property cannot see it | Where it is pinned |
  |------------|--------------------------------|--------------------|
  | whitespace in `text` | the generator emits only single-space-joined words, so the streaming path's trim-and-join and the non-streaming path's verbatim text agree by construction. A script with `" a b "` would differ between paths, correctly | `fake_transcription_test.exs` (26.3): a padded script text gives the trimmed `completed.text` on the stream path |

  Every other field (`audio` bytes, `format`, `sample_rate`, `model`, `provider`, `usage`, `request_id`, `metadata`, and `text`/`language` for transcription) is compared.

#### 26.4.2 Implementation Checklist
- [ ] Three façades + `@doc` sections: input shapes, gate order, model resolution, no retry after open, halting, the first-chunk event, and "Telemetry carries no audio"; doctests over the Fakes
- [ ] `ALLM.AudioStream` + doctests
- [ ] `Telemetry` span names (both lists) + moduledoc event-table row
- [ ] `@public_facade` +3 (**fail-open**); strike "## No streaming yet" (`lib/allm.ex:1467`, `:1605`) in favour of a "Streaming" pointer

#### 26.4.3 Verification
Targeted + uniform. **Success criterion:** the equivalence property passes ≥100 runs; every gate-order row passes both alone and in combination.

### Phase 26.5 — `OpenAI.Speech` streaming (Layer B)

#### 26.5.1 Test Plan
`openai/speech_stream_test.exs`, over `FinchStub` (`test/support/finch_stub.ex`):
- **Happy path:** status 200 plus headers `content-type: audio/pcm`, then three data chunks. The events are `speech_started{format: :pcm, sample_rate: 24_000}`, three deltas and `speech_completed`.
  - **`FinchStub` extension:** it currently sends `{:headers, []}`, and a status ≥ 400 sends no data frames (`test/support/finch_stub.ex` moduledoc, "Chunk vocabulary"). Add `:initial_headers` and `:error_body` (status ≥ 400 → headers → body chunks → `:done`) install options (Module Tree row). A test pins that the defaults leave existing callers' frame sequences unchanged.
- `stream_synthesize/2` does not call `async_request` until the stream is reduced. The falsifier is a stub `captured_opts/1` present right after the call.
- **Gates:** a 4,097-code-point input returns a synchronous `:context_length_exceeded` before any Finch call. `format: :pcm, sample_rate: 16_000` → `:unsupported_feature`. `format: :mp3, sample_rate: 24_000` → `:unsupported_feature`. All are keyless with a raising `:finch_module`. The accepting side is pinned too: `format: :pcm, sample_rate: 24_000` and `format: :wav, sample_rate: 24_000` pass the gate and reach the stub (falsifier: a gate that accepts 24,000 only for `:pcm`).
- **Mid-stream errors:**
  - status 401 with a JSON body carrying a planted `sk-` token → the terminal `:authentication_failed` whose message and metadata carry no `sk-` token.
  - a 400 `string_too_long` body → `:context_length_exceeded`.
- **Halt:** `Enum.take(events, 2)` → `cancel_count(ref) == 1`.
- **Halt drain:** the stub delivers five data chunks with no delay, so chunks are still queued in the mailbox when `Enum.take(events, 2)` halts. After the halt, `refute_received {^ref, _}` (the after function drains leftover `{ref, _}` messages in a `receive … after 0` loop after `cancel_async_request/1`). Falsifier: an after function that cancels without draining.
- **`stream_timeout: 50`** with `delay_ms: 200` → a terminal `:timeout`.
- **200 with `content-type: application/json`** → a terminal `:malformed_response`.
- **Script hand-off:** with `speech_script` set, the Fake stream runs and Finch is never called.

`openai/speech_stream_conformance_test.exs`: `SpeechStreamAdapterConformance` only. OpenAI does not export the input callback, which is pinned by `refute function_exported?(OpenAI.Speech, :stream_synthesize_input, 3)`.

#### 26.5.2 Live probe — new arms in `scripts/record_openai_audio_fixtures.exs`
These arms sit behind the existing overwrite guard, so a re-run fires only the new arms.

| Arm | Asserts | Writes |
|-----|---------|--------|
| `stream_chunked` (gpt-4o-mini-tts, ~400 chars, pcm) | 200, `audio/pcm`, **≥ 2 data messages**, and first-chunk `t_ms` < last-chunk `t_ms` (halt otherwise: Alternative E) | `speech/recorded/stream_pcm.json` (chunk timings) |
| `stream_mp3_tts1` (tts-1) | the same framing on a legacy model | `stream_mp3_tts1.json` |
| `stream_401` | status 401 on the streaming path; `text/plain` body (Phase 25 CONFIRMED) | `stream_error_401.json` |

**Cost** (pricing from the Phase 25 RECORDS quote; the implementer re-quotes): about 1,000 characters, under $0.05 per clean run, and ≈$0.15 on the first implementation.

#### 26.5.3 Implementation Checklist
- [ ] `stream_synthesize/2`, with the pre-flight gates shared with `synthesize/2` (one `run_gates/2`, `lib/allm/providers/openai/speech.ex:378`)
- [ ] Buffered-error-body classification (wire map row); `Transport.finch_opts/2`; `@doc` default `stream_timeout`
- [ ] `test/support/finch_stub.ex` `:initial_headers` + `:error_body`; recorder arms; the stream fixture decode test
- [ ] Non-streaming `synthesize/2` shares the new `sample_rate` gates through `run_gates/2` and reports `sample_rate: 24_000` for `:pcm` and `:wav` from `decode_response/4`. This changes released behaviour, so `openai/speech_test.exs` (MODIFY — 26.5) gains the same gate and reporting rows as the stream test (agent-spec/DESIGN.md rule 10)

#### 26.5.4 Verification
Targeted + uniform + conformance + **BLOCKING** recorder (subshell form). **Success criterion:** the recorder exits 0 with `stream_chunked` matched; every new recorded file passes raw-bytes provenance.

### Phase 26.6 — ElevenLabs non-streaming adapters (Layer B)

**Precondition (hard stop):** `ELEVENLABS_API_KEY` is present in `.env`. The owner committed on 2026-09-26 to adding it before 26.6 starts. If it is absent when 26.6 starts, the build **pauses and asks the owner**. It does not proceed on synthesized fixtures, ship `recorded/` placeholders, or claim a deferral: 26.6's `decode_response/4` behaviour is decided by the probe.

#### 26.6.1 Test Plan
`elevenlabs/speech_test.exs` (seams, no HTTP):
- **`to_json_body/2`:**
  - Fills `model_id` from `@default_model`.
  - `speed: 1.1` → `voice_settings.speed`.
  - `options: %{"voice_settings" => %{"stability" => 0.3}}` coexists with that speed.
  - `options: %{"text" => "x"}` does not replace the text.
  - `options: %{"output_format" => "pcm_8000"}` is dropped.
  - nil fields are absent, not `null`.
- **`url/2`:** the default voice goes in the path. `options["query"]` merges under `output_format`. `base_url:` overrides the host.
- **`Support.ElevenLabs.output_format/2`:** one test per Format-table row, including every `:unsupported_feature` cell and the nil default.
- **Gates, all keyless with a flunking `:plug`:**
  - `instructions: "x"` → `:unsupported_feature`.
  - `format: :aac` → `:unsupported_feature`.
  - `format: :opus, sample_rate: 24_000` → `:unsupported_feature`.
  - `input: ""` → `:invalid_request`.
- **`decode_response/4`:** it follows the content-type probe outcome rule, and its test is written after the probe. `request-id` → `id`; `character-cost` → `raw`.
- **`Support.ElevenLabs.classify/2`:** one test per HTTP row of Error classification, driven from `synthesized/` fixtures in the documented envelope, plus the 422-array shape.
- **Retry:** `ElevenLabs.Speech.synthesize/2` keeps an adapter-level `ALLM.Retry.run/3` loop exactly as `OpenAI.Speech` does (`lib/allm/providers/openai/speech.ex:109-118`, `:422`): each attempt marks `:rate_limited` (honouring `Retry-After`), `:provider_unavailable`, `:timeout` and `:network_error` retryable, and the policy decides. Call-count rows over a counting `Req.Test` plug: a 429 (`Retry-After: 0`) then 200 under an `opts[:retry]` policy that lists `:rate_limited` hits the plug **twice** and succeeds; the same script under the default policy hits it **once** and returns `:rate_limited` (the default `retry_on` retries only `:timeout`, as the `OpenAI.Speech` moduledoc states). The streaming entry points have no retry loop (Out of scope).

`elevenlabs/transcription_test.exs`:
- The multipart body carries `file`, `model_id` and `language_code` only when set.
- `prompt: "x"` → `:unsupported_feature`, keyless.
- The decode maps `audio_duration_secs → duration_seconds`, `transcription_id → id` and `language_code → language`. Missing `text` → `:malformed_response`.
- The filename/mime gate follows the `stt_audio_bin` outcome.
- A 429 is hit **once**: the transcription adapters do not retry (the Phase 25 STT rule, `steering/2026-09-24_SST_SUPPORT.md:488`).

`*_wire_test.exs`:
- URL, method, `xi-api-key` header, content-type.
- Each recorded fixture decodes.
- The redactor strips the planted `sk_` token, and the OpenAI, Gemini and Voyage patterns match nothing in that fixture.
- Raw-bytes provenance, one test per recorded file.

`*_conformance_test.exs`: Phase 25's `SpeechAdapterConformance` / `TranscriptionAdapterConformance` with `:gate_opts`.

#### 26.6.2 Live probe — `scripts/record_elevenlabs_audio_fixtures.exs`
This probe has four parts (`CLAUDE.md`): a control arm, assertions checked before any write, recorded bodies including errors, and an overwrite guard in which every arm has a write target. Canonical shape: `scripts/record_voyage_embeddings_fixtures.exs`.

| Arm | Asserts | Settles |
|-----|---------|---------|
| `control` (unknown body field) | status ∈ {200, 422}, recorded; a 200 leaves acceptance-only rows inferred (no halt) | evidential weight of the acceptance arms |
| `default_voice` / `tts_default` | 200; records **all** header names | Decision #10; correlation-header row |
| `tts_mp3` / `tts_pcm` / `tts_wav` / `tts_opus` | 200; content-type per format | the content-type outcome rule |
| `too_long` (`eleven_v3`, 5,001 chars) | 400 with `text_too_long` | classification row |
| `error_401` (fake `sk_…` key) | 401; echo recorded | redaction row |
| `error_404_voice` | 400 or 404, recorded | voice error row |
| `stt_default` (fox mp3, `test/fixtures/audio/quick_brown_fox.mp3`) | 200, text contains "fox" | STT response row |
| `stt_audio_bin` | 200 or 400, recorded | STT mime gate |

**Cost** (ElevenLabs pricing page, fetched 2026-09-25: flash $0.05 per 1K characters, v3 $0.10 per 1K characters, Scribe v2 $0.22 per hour):
- TTS: about 5,300 characters ≈ $0.55. The `too_long` arm dominates.
- STT: 2 × 3 s, negligible.
- Per clean run ≈ **$0.55**; the first implementation ≈ **$1.50**.
- The free tier (10K credits/month, https://elevenlabs.io/pricing) covers a single run, but **not** a first implementation with the `too_long` arm plus the 26.7–26.8 arms.

#### 26.6.3 Implementation Checklist
- [ ] `Support.ElevenLabs` (headers, base URL, `output_format/2`, `classify/2`, `redact_key_material/1`); both adapters use `Support.HTTPResponse`, and `ElevenLabs.Transcription` uses `Support.TranscriptionAdapter` for its gates, Fake hand-off and single attempt (no local copy of any helper the 26.1 transcription predicate names)
- [ ] Both adapters, with script hand-off, gates, the injected-default `@doc`s (every default Decision #10 lists, plus the 60 s/120 s timeouts per the Phase 25 rule); `ElevenLabs.Speech.synthesize/2`'s adapter-level `Retry.run/3` and its `@doc` "Retry" paragraph
- [ ] Recorder + fixtures + `elevenlabs_fixtures.ex` + `test/fixtures/elevenlabs/README.md`; rewrite the wire-map rows the probe settles **in this design doc, in the same commit** (the Phase 25 `CORRECTED` convention)
- [ ] `groups_for_modules`

#### 26.6.4 Verification
Targeted + uniform + conformance + **BLOCKING** recorder, plus the 26.1 transcription predicate (it must still print nothing with three `*/transcription.ex` files). **Success criterion:** the recorder exits 0 with every arm matched; the re-run prints `0 live calls`; both adapters pass their Phase 25 suite; the transcription predicate prints nothing.

### Phase 26.7 — WebSocket transport + ElevenLabs TTS streaming (Layer B)

**Precondition (hard stop):** as 26.6, which is `ELEVENLABS_API_KEY` in `.env`. This sub-phase's BLOCKING live gates need it, and a missing key pauses the build for the owner rather than deferring.

#### 26.7.1 Test Plan
- (`input_pump_test.exs` shipped in 26.3.) Composition behaviour 1 and the mailbox-drain half of invariant 4 are tested here, in `elevenlabs/speech_stream_test.exs`, because they need a socket-owning resource: after `Enum.take/2`, `refute_received` any `{:ssl, _, _}`/`{:ssl_closed, _}`/pump message.
- A failed upgrade (stub returns `{:upgrade_status, 401, _}`) never starts the pump: an input whose first element sends `:reduced` to the test process produces `refute_received :reduced` (invariant 9).
- A server ping produces a client pong in `sent_frames/1`, and no event.
- **`web_socket_test.exs` (`Support.WebSocket.Mint`)**, against `ALLM.Test.WSTestServer` (`test/support/ws_test_server.ex`): a minimal RFC 6455 server on `:gen_tcp`, listening on port 0 on loopback. It answers the upgrade with `Sec-WebSocket-Accept` (base64 of SHA-1 over key + the RFC GUID), unmasks client frames, sends unmasked server frames, and scripts text, ping and close frames; it reports every frame it receives to the test process. It needs no new dependency. `connect/3` reaches it through a `ws://127.0.0.1:<port>/…` URL. Rows:
  - A 101 handshake gives `{:ok, conn}`, and a server text frame arrives as `{:text, _}` from `handle_message/2`.
  - A 401 upgrade response with a JSON body gives `{:error, {:upgrade_status, 401, body}}`, with `body` decoded.
  - A server ping produces a client pong **observed by the server** with the same payload, and no frame reaches the caller.
  - A server close with code 1011 surfaces as `{:close, 1011, reason}`.
  - `close/1` called twice returns `:ok` both times and raises nothing.
  - After the owner stops the stream, the test process's mailbox holds no `{:tcp, _, _}` / `{:tcp_closed, _}` message for that socket (`flush_messages/1`).
  - The URL builder: `wss` host/path/query, **no key in the URL**.
  TLS (`wss://`) is exercised only by the live recorder, the same split as Finch vs `FinchStub`; the moduledoc says so.
- **`elevenlabs/speech_stream_test.exs`:**
  - **HTTP `/stream`:** the same matrix as 26.5 over `FinchStub`: happy path, gates, mid-stream error classification, halt → `cancel_count == 1`, the halt-drain row (chunks queued at halt, then `refute_received {^ref, _}`), and timeout.
  - **WebSocket `stream_synthesize_input/3` over `ALLM.Test.WebSocketStub`:**
    - The upgrade headers contain `xi-api-key`. The URL contains neither the key nor `authorization=`. The falsifier is the key in the URL.
    - The client frames are exactly the init message, one `{"text": c}` per non-empty chunk **with no appended space**, then `{"text":"","flush":true}` and `{"text":""}`.
    - Server `audio` frames decode to deltas, and `isFinal` produces `:speech_completed`.
    - A server `{"message_type":"auth_error"}` frame → the terminal `:authentication_failed`.
    - Close code 1011 before `isFinal` → `:network_error`.
    - `Enum.take(events, 1)` → the stub records `close/1` and the pump is dead within 500 ms.
    - Behaviour 1: every resource function sees the same `self()`.
    - An LLM-shaped input (`FinchStub`-backed `ALLM.stream_generate/3` through `text_deltas/1`) is spoken in order. This is behaviour 6 end-to-end.
    - The `inactivity_timeout` query equals `min(180, ceil(stream_timeout / 1000))`, with `stream_timeout: 300_000` → `180`.
    - **Slow input, short timeout:** an input that yields five chunks 60 ms apart under `stream_timeout: 100`, while the stub stays silent until the flush, completes without `:timeout` (the timer resets on pump messages, invariant 5). Falsifier: a timer reset only by transport messages.
    - **Keep-alive:** with `stream_timeout: 1_000` (so `inactivity_timeout=1`), an input that pauses 700 ms between two chunks produces a `{"text":" "}` frame in `sent_frames/1` between them, and no `:timeout`.
    - **Input failures:** input `[123]` → the terminal `:invalid_input_chunk`; an input that raises → the terminal `:input_raised`, the consumer alive, and `err.cause` a string-only map; `[""]` → the terminal `:empty_input`, with `close_count/1 == 1` (the socket is closed).
    - **Synchronous gates** (keyless, raising `:ws_module`): `format: :bogus` → `:invalid_request` before any connect (conformance case 6).
- **`ALLM.Test.WebSocketStub`:** it implements `Support.WebSocket`. Its script is a list of `{:after_client, matcher, [server_frame]}` steps. It exposes `sent_frames/1` and `close_count/1`. Its state lives in an Agent whose pid rides in the opts (the Agent-backed `FinchStub` mode), because the consumer under test can be a different process from the test (behaviour 5); the Agent is per-install, so `async: true` stays safe.

#### 26.7.2 Live probe arms (same recorder)

| Arm | Asserts |
|-----|---------|
| `stream_chunked` (`/stream`, flash, ~400 chars, pcm_24000) | ≥ 2 chunks, first `t_ms` < last `t_ms` |
| `ws_tokens` | the socket opens (101); `["Hel", "lo", " world", "."]` → ≥ 1 audio frame + `isFinal`; records `t_ms` to the first audio frame twice, under the default `chunk_length_schedule` and under `auto_mode=true`; the lower one sets the adapter default (Decision #11) |
| `ws_end` | the flush-then-close sequence yields `isFinal` within 10 s; one `{"text": " "}` keep-alive sent mid-input, with the audio recorded (keep-alive row) |
| `ws_bad_voice` / `ws_bad_key` | record the error shape (upgrade status or frame, and close code); the classifier rows are rewritten in place |
| `ws_control` | invented init-message field: accepted or rejected, recorded (the control rule) |
| `ws_v3` | `model_id=eleven_v3` on `/stream-input`: audio or error, recorded; settles Decision #6's inferred claim |

Cost: about 600 characters, under $0.05.

#### 26.7.3 Implementation Checklist
- [ ] `mix.exs` `{:mint_web_socket, "~> 1.0"}`; `mix deps.get`; `mix.lock`
- [ ] `cd conformance && mix deps.get` after adding `:mint_web_socket`; commit `conformance/mix.lock`
- [ ] `Support.WebSocket` behaviour (`support/web_socket.ex`) and `Support.WebSocket.Mint` (`support/web_socket/mint.ex`: `ws`/`wss` scheme from the URL, ping/pong, selective handshake receive, `flush_messages/1`), `test/support/web_socket_stub.ex`, `test/support/ws_test_server.ex`
- [ ] `ElevenLabs.Speech.stream_synthesize/2` (Finch) and `stream_synthesize_input/3` (WebSocket); both suites added to `elevenlabs/speech_conformance_test.exs`
- [ ] Recorder arms; wire-map rows rewritten in place
- [ ] `groups_for_modules` (`Support.WebSocket`, `Support.WebSocket.Mint`: one row each)

#### 26.7.4 Verification
Targeted + uniform + conformance (after `cd conformance && mix deps.get`) + **BLOCKING** recorder. **Success criterion:** composition behaviour 1 and the invariant-4/9 tests pass; every `web_socket_test.exs` row passes against the local server; the recorder's `ws_*` arms match; `mix hex.build` succeeds with the new dependency listed.

### Phase 26.8 — ElevenLabs realtime STT (Layer B)

**Precondition (hard stop):** as 26.6, which is `ELEVENLABS_API_KEY` in `.env`. This sub-phase's BLOCKING live gates need it, and a missing key pauses the build for the owner rather than deferring.

#### 26.8.1 Test Plan
`elevenlabs/transcription_stream_test.exs` (over `WebSocketStub`):
- **URL:** it carries `model_id=scribe_v2_realtime`, `audio_format=pcm_16000` and `commit_strategy=vad`. `options["audio_format"]` is dropped (reserved).
- **Chunk frames:** the concatenation of every `audio_base_64` payload decoded equals the concatenation of the input. Falsifiers: a dropped byte, or a split sample (every frame's decoded length is even).
- An input of `[<<1, 2, 3>>, <<4>>]` sends whole samples only (frames decode to `<<1, 2>>` then `<<3, 4>>`).
- An input whose total length is odd (e.g. `[<<1, 2, 3>>]`) ends with `:invalid_input_chunk` at end of input, after the whole samples were sent.
- A 3-second chunk at 16 kHz is split into frames of ≤ `@max_chunk_ms` of audio.
- **`:commit`** produces a `commit: true` frame with empty audio; `[<<0, 0>>, :commit, <<0, 0>>]` sends audio, commit, audio in that order.
- **Input failures:** input `[123]` → the terminal `:invalid_input_chunk`; a non-`:commit` atom (`[:flush]`) → the terminal `:invalid_input_chunk`; an input that raises → the terminal `:input_raised`, the consumer alive, and `err.cause` a string-only map.
- **End of input:** a final commit is sent, and `:transcription_completed` waits for the stub's `committed_transcript`.
- **Server messages** map to their events. `warning` produces a log line (`capture_log`) and no event.
- **Timestamped commits:** the stub sends `committed_transcript_with_timestamps{language_code: "en"}` then `committed_transcript` for one segment, and for a second segment the reverse order. Exactly two `:committed_transcript` events are emitted; the first carries `language: "en"`; the late timestamped frame of the second produces nothing, and a third segment sent afterwards without a timestamped frame carries `language: nil`. Falsifier: three events for two segments, a duplicate segment in `completed.text`, or a leaked language.
- **Error types:** each `message_type` in Error classification maps to its reason (a table-driven test).
- **Gates** (keyless, with a raising `:ws_module`):
  - `sample_rate: 11_025` returns a synchronous `:invalid_request`.
- **Duration:** `duration_seconds` equals `bytes / (rate * 2)`.
- **Halt / timeout:** as in 26.7.

`test/support/pcm.ex` (`wav_pcm_chunks/2`): the RIFF `data` chunk of `test/fixtures/audio/quick_brown_fox.wav` sliced into N-ms pieces. **The fixture is a streaming WAV:** its RIFF size and `data` size fields are both `0xFFFFFFFF` (24 kHz mono s16, 182,400 data bytes in a 182,444-byte file). `wav_pcm_chunks/2` treats a `0xFFFFFFFF` data size as "to end of file". Its test asserts the rate read from the header (24,000), a total of 182,400 bytes (falsifier: a slice taken at the declared `0xFFFFFFFF` length, or a raise), and that every piece but the last is exactly `rate * 2 * ms / 1000` bytes.

`elevenlabs/transcription_conformance_test.exs` gains `TranscriptionStreamAdapterConformance`.

#### 26.8.2 Live probe arms

| Arm | Asserts |
|-----|---------|
| `rt_fox` (the fox WAV at its native rate, read from the WAV header; the recorder halts if that rate is not in `stream_sample_rates/0`. No resampling) | `session_started`; ≥ 1 `committed_transcript` containing "fox"; records every partial; records every `committed_transcript` **and** `committed_transcript_with_timestamps` frame in arrival order (settles the timestamped-commits row); the pacing outcome rule |
| `rt_manual_commit` (`commit_strategy: :manual`, two halves split by `:commit`) | two committed segments |
| `rt_end` | the final commit yields a committed segment before close |
| `rt_bad_key` | the upgrade status or error frame, recorded |
| `rt_control` | an invented query parameter: accepted or rejected, recorded (the control rule) |
| `rt_big_chunk` | one 1,000 ms chunk accepted; settles `@max_chunk_ms` (a `chunk_size_exceeded` lowers it, and the recorder retries at half) |

Cost: under 1 minute of audio at $0.39/h, which is negligible.

#### 26.8.3 Implementation Checklist
- [ ] `ElevenLabs.Transcription.stream_transcribe/3` + `stream_sample_rates/0`, over `Support.WebSocket` + `InputPump`
- [ ] `test/support/pcm.ex`; recorder arms; wire-map rows rewritten in place

#### 26.8.4 Verification
Targeted + uniform + conformance + **BLOCKING** recorder. **Success criterion:** `rt_fox` and `rt_end` match; the adapter passes 6/6 on the stream suite.

### Phase 26.9 — Spec, guide, examples, transport rule

**Precondition (hard stop):** as 26.6, which is `ELEVENLABS_API_KEY` in `.env`. This sub-phase's BLOCKING live gates need it, and a missing key pauses the build for the owner rather than deferring.

#### 26.9.1 Test Plan
- `guides/audio.md`'s new `iex>` blocks execute (`test/guides_doctest_test.exs`), and its new fences compile (`scripts/check_guide_fences.exs`).
- `test/allm/examples_helpers_test.exs` (MODIFY; it already loads `examples/_helpers.exs` with `Code.require_file/1`):
  - `ExamplesHelpers.chat_provider?/1` is `false` for `"elevenlabs"` and `true` for every other `@providers` row (the test iterates the rows, so a new chat row needs no test edit).
  - The `elevenlabs` row has `key_env: "ELEVENLABS_API_KEY"` and no `:adapter` (`nil`), and carries `speech_voice`. The `openai` row carries `speech_voice: "alloy"`.
- `examples/run_all.exs`'s use of `chat_provider?/1` is verified by the live run below: `ALLM_PROVIDER=elevenlabs` runs only `23`–`27`, and every chat script prints nothing for that arm.

#### 26.9.2 Implementation Checklist
- [ ] **Spec §37.11** (the event unions, both streaming behaviours, the façades, the transport rule, the pump, the equivalence property, telemetry). **§37.7** provider matrix (ElevenLabs: speech + transcription + all three streams; OpenAI speech: + HTTP stream). **§37.10** strikes. **§35.7** carve-out (Decision #1). **§27** and **§29**. Each block opens `> **Phase 26 amendment (commits <first>..<last>).**`
- [ ] `guides/audio.md`:
  - streaming quick start (`iex>` over the Fakes);
  - the voice loop (a fence, since it needs live keys);
  - PCM and `sample_rate`;
  - choosing a latency model;
  - realtime pacing (from the `rt_fox` outcome);
  - an ElevenLabs section (voices are ids, the format table, tier-gated rates);
  - `[:allm, :audio, :first_chunk]`.
- [ ] `examples/_helpers.exs`: an `elevenlabs` `@providers` row with `adapter: nil`, `key_env: "ELEVENLABS_API_KEY"` (`capability_engine/2` does `Map.fetch!(row, :key_env)`), `speech_adapter`/`transcription_adapter` set, default models, and `speech_voice` (the ElevenLabs default voice id Decision #10 settles); `speech_voice: "alloy"` on the `openai` row; update `speech_engine/1`'s *"this script is OpenAI-only"* message; add `chat_provider?/1` (the JEV Decision #14 shape, `steering/2026-09-22_JEV_SUPPORT.md:196`; whichever phase lands first adds it, and the other reuses it).
- [ ] `examples/run_all.exs`: marker-less scripts run only when `chat_provider?/1` (the gate at `examples/run_all.exs:124`).
- [ ] `examples/25_stream_speech.exs`: asserts ≥ 2 deltas and prints first-chunk latency.
- [ ] `examples/23_synthesize_speech.exs` body: the hard-coded `voice: "alloy"` (`:39`) becomes the provider row's `speech_voice`, and the `mime_type != "audio/mpeg"` assertion (`:50-51`) follows the 26.6 content-type outcome (for ElevenLabs, the mime the adapter reports for `format: :mp3`, per the Format table or the recorded content-type), not a literal
- [ ] `examples/fixtures/quick_brown_fox.wav`: a copy of `test/fixtures/audio/quick_brown_fox.wav` (examples read only `examples/fixtures/`, as `24_transcribe_audio.exs:32` does). The script header notes the quirk: a streaming WAV whose RIFF and `data` sizes are `0xFFFFFFFF`, so a reader must take the data chunk to end of file (24 kHz mono s16, 182,400 data bytes; 24,000 is in `stream_sample_rates/0`)
- [ ] `examples/26_stream_transcribe.exs`: fox WAV → 100 ms PCM chunks → the text contains "fox".
- [ ] `examples/27_voice_loop.exs`: `# Provider: elevenlabs`. The chat hop needs a chat adapter, and the `elevenlabs` arm has none, so the script builds its chat engine from `OPENAI_API_KEY` explicitly and prints a skip line (exit 0) when that key is absent. That branch is stated in the script header.
- [ ] Markers on 23/24; `examples/README.md`; `CLAUDE.md` transport bullet (Decision #3), which also records Decision #7's exception to the "Mid-stream adapter errors fold into the response" invariant: an audio stream (`SpeechEvent` / `TranscriptionEvent`) that errors after opening ends with a terminal `{:error, err}` event and `AudioStream.collect_*` returns `{:error, err}`, because `SpeechResponse` has no `finish_reason` (the chat invariant's bullet gains a one-line pointer to it); CHANGELOG from `git diff $(git describe --tags --abbrev=0)..HEAD lib/`

#### 26.9.3 Verification
- Uniform block, then `mix docs` (zero broken autolinks).
- **BLOCKING**, subshell form: `ALLM_PROVIDER=elevenlabs mix run examples/run_all.exs`.
- The `openai` arm of `run_all.exs`, with the blocked-arm **re-characterization** rule applied: a per-script result line, never an inherited one.
- `RUN_OUTPUT_*.md` is regenerated only with a clean full run. There is no `RUN_OUTPUT_ELEVENLABS.md` unless the run is clean.

**Success criterion:** the elevenlabs arm exits 0; scripts 25–27 print `OK:`; the guide gates are green.

### Phase 26.10 — `[CHORE]` sweep

**Module Tree:**
- `.work/ASKS.md`.
- `steering/2026-09-24_SST_SUPPORT.md`: one pointer line under Alternative D, *"Decided in Phase 26"*.
- Any `lib/`/`test/` file named by a `[CARRY]` raised in 26.1–26.9. Each is listed as `(MODIFY — 26.10)` when that `[CARRY]` is raised, by amending this sub-phase's tree in RECORDS.

**Known tickets at design time:**
- The `ulaw`/`alaw` telephony formats. File this with a self-scoring predicate: `grep -n ':ulaw' lib/allm/speech_request.ex` must match.
- The narrowed `[DEFERRED-DRY]` variants from 26.1, with the predicate carried from RECORDS.

**Checklist:**
- [ ] Every ticket this phase filed is closed or re-filed with a grep predicate
- [ ] Wire maps carry no remaining `UNVERIFIED` row that a probe arm settled: `grep -c UNVERIFIED steering/2026-09-25_ELEVENLABS_TTS_SST.md` counts only rows whose probe was impossible (the 5 GB STT cap), each named in RECORDS

**Verification:** uniform block + both predicates.

---

## Error Contract

| Function | Reason | Recovery |
|----------|--------|----------|
| stream façades | `EngineError :no_speech_adapter` / `:no_transcription_adapter` | Set the slot. |
| stream façades | `EngineError :missing_stream_adapter` | The slot adapter does not stream (or does not take streamed input). Use a streaming adapter. |
| stream façades | `ValidationError :invalid_speech_request` / `:invalid_transcription_request` | Fix per `:errors`. |
| stream façades | `ArgumentError` (**raised when reduced**) | The adapter emitted a non-event (invariant 3). Not recoverable by the caller. |
| adapters | `:unsupported_feature` | A field the provider cannot express (Decision #9) or a tier-gated format (403). Change the request. |
| adapters (sync or terminal event) | `:invalid_request` (`metadata.cause`: `:invalid_input_chunk`, `:input_raised`, `:input_crashed`, `:empty_input`, or `metadata.sample_rate`) | Fix the input. No retry. |
| adapters | `:authentication_failed`, `:rate_limited`, `:provider_unavailable`, `:network_error`, `:timeout`, `:context_length_exceeded`, `:malformed_response`, `:unknown` | As in §37 (`steering/2026-09-24_SST_SUPPORT.md:923-938`). **A stream is never retried by ALLM after it opens.** |
| `AudioStream.collect_*` | the terminal error, with `metadata.bytes_received` / `committed_text` | Decision #7. |

`{:error, term()}` appears in no `@spec`.

## Streaming & Backpressure

- **Cleanup:** every stream is a `Stream.resource/3` whose after function cancels the Finch ref, or closes the socket, calls `InputPump.stop/2` and drains the stream's messages from the mailbox (invariant 4). Each is tested with `Enum.take/2`, and release is asserted within 500 ms.
- **Inbound backpressure:** Finch and Mint deliver in active mode to the owner's mailbox. A slow consumer grows the mailbox at the provider's generation rate. This is the same property as the chat path, and it is stated in both behaviours' moduledocs.
- **Outbound backpressure:** the pump credit window (default 8, `adapter_opts[:input_window]`) bounds unsent input held in the owner's mailbox.
- **Cancellation:** a halt kills the pump. A killed process runs no code, so an LLM input stream being reduced by the pump does **not** run its own after function; its resources are released by process exit (Finch's HTTP/1 request process is linked to its caller, the pump, and dies with it). This is composition behaviour 3, asserted as "the pump and every process linked to it are dead within 500 ms", not via `FinchStub.cancel_count/1`.

## Definition of Done

- [ ] Every sub-phase in the Status table is complete (tick-state in RECORDS)
- [ ] `mix test` and `mix test --seed 0` are green; new files are ≥90% covered; credo, dialyzer and format are clean; `conformance/` is green on all three gates
- [ ] Every new public function has `@spec` and `@doc`; the Layer A and Layer C public API (event constructors, `TranscriptionStreamRequest`, the three façades, `ALLM.AudioStream`) and pure helpers (e.g. `Support.ElevenLabs.output_format/2`) each carry a runnable doctest. Adapter entry points, behaviours and I/O-bound support modules (`Support.WebSocket.Mint`, `Support.InputPump`) are covered by their test files instead
- [ ] Every new or changed Layer A struct round-trips ETF and JSON; both event unions round-trip ETF
- [ ] The Fakes pass all three stream suites; `OpenAI.Speech` passes the speech stream suite; both ElevenLabs adapters pass every suite they implement
- [ ] The equivalence property passes ≥100 runs
- [ ] Every audit gate in the obligations table passes with its artifacts registered (fail-open gates are checked by count delta)
- [ ] Every probe-settleable wire-map row is rewritten as observed, in the commit of the sub-phase that settled it
- [ ] Every `recorded/` fixture passes raw-bytes negative provenance
- [ ] Live gates ran for the `openai` and `elevenlabs` arms, with per-script result lines
- [ ] `git diff --stat HEAD -- README.md` is empty throughout
- [ ] CHANGELOG is derived from `git diff <prior-tag>..HEAD lib/`; spec amendments carry commit ranges
