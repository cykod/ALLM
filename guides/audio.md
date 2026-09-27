# Audio: speech and transcription

ALLM has two audio primitives, one per direction:

  * `ALLM.synthesize/3` turns text into speech (text-to-speech, TTS) and
    returns an `%ALLM.SpeechResponse{}` whose `:audio` holds the bytes.
  * `ALLM.transcribe/3` turns speech into text (speech-to-text, STT) and
    returns an `%ALLM.TranscriptionResponse{}` whose `:text` is the
    transcript.

Both are request/response calls, parallel to images, embeddings and
moderation: the whole clip or the whole transcript arrives in one response.
Each also has a streaming form, covered in "Streaming speech" and "Streaming
transcription" below:

  * `ALLM.stream_synthesize/3` returns the audio in chunks while the
    provider is still generating it.
  * `ALLM.stream_synthesize_input/3` also takes the *text* in chunks, so it
    can speak an LLM's answer while the answer is being written.
  * `ALLM.stream_transcribe/3` takes audio in chunks (a microphone) and
    returns partial and final transcripts while the audio is still arriving.

| Provider | Speech | Transcription |
|----------|--------|---------------|
| OpenAI | `ALLM.Providers.OpenAI.Speech`: `synthesize/2`, `stream_synthesize/2` | `ALLM.Providers.OpenAI.Transcription`: `transcribe/2` |
| ElevenLabs | `ALLM.Providers.ElevenLabs.Speech`: `synthesize/2`, `stream_synthesize/2`, `stream_synthesize_input/3` | `ALLM.Providers.ElevenLabs.Transcription`: `transcribe/2`, `stream_transcribe/3` |
| Gemini | not bundled yet | `ALLM.Providers.Gemini.Transcription`: `transcribe/2` |
| Anthropic | no audio endpoint | no audio endpoint |

ElevenLabs is an audio-only provider in ALLM: it has no chat adapter, so an
engine pairs it with a chat provider (see "One engine, two providers").

The examples below use `ALLM.Providers.FakeSpeech` and
`ALLM.Providers.FakeTranscription`, so they run with no network and no key.
"Testing with the Fakes" at the end covers their scripting grammar.

## Audio values

Audio in both directions is an `%ALLM.Audio{}`: the input you transcribe and
the output you get back from synthesis. It is plain data, so it serializes
like every other ALLM struct (the bytes become base64 in JSON).

    iex> audio = ALLM.Audio.from_file("interview.mp3")
    iex> audio.mime_type
    "audio/mpeg"
    iex> ALLM.Audio.from_binary(<<1, 2, 3>>, "audio/wav").mime_type
    "audio/wav"

`ALLM.Audio.from_file/1` does no I/O. It records the path and guesses the
MIME type from the extension, and the file is read only when an adapter
uploads it. `ALLM.Audio.to_binary/1` returns the bytes, and
`ALLM.Audio.size/1` returns the byte count (a file is measured without being
read).

## A first synthesis

An engine carries its speech adapter in the `:speech_adapter` slot:

    iex> engine = ALLM.Engine.new(speech_adapter: ALLM.Providers.FakeSpeech)
    iex> {:ok, response} = ALLM.synthesize(engine, "Hello there.", format: :wav)
    iex> response.format
    :wav
    iex> response.audio.mime_type
    "audio/wav"
    iex> {:ok, bytes} = ALLM.Audio.to_binary(response.audio)
    iex> bytes
    "FAKE-AUDIO:Hello there."

Against OpenAI, write the bytes to a file you can play:

```elixir
engine = ALLM.Engine.new(speech_adapter: ALLM.Providers.OpenAI.Speech)

{:ok, response} = ALLM.synthesize(engine, "Hello there.", voice: "coral", format: :mp3)
{:ok, bytes} = ALLM.Audio.to_binary(response.audio)
File.write!("hello.mp3", bytes)
```

Besides `:voice` and `:format`, a request takes `:instructions` (a tone or
style hint, for models that support it), `:speed`, and `:options`, which is
passed to the provider's request body as-is for fields ALLM does not model.
`:options` never overrides a field the adapter sets itself.

## A first transcription

The transcription adapter lives in its own `:transcription_adapter` slot:

    iex> engine = ALLM.Engine.new(
    ...>   transcription_adapter: ALLM.Providers.FakeTranscription,
    ...>   adapter_opts: [transcription_script: [{:ok, "The quick brown fox."}]]
    ...> )
    iex> audio = ALLM.Audio.from_binary("ID3...", "audio/mpeg")
    iex> {:ok, response} = ALLM.transcribe(engine, audio, language: "en")
    iex> response.text
    "The quick brown fox."
    iex> %ALLM.Usage{} = response.usage
    iex> :ok
    :ok

`:language` is a hint (an ISO-639-1 code such as `"en"`), and `:prompt`
carries context such as names and spellings. Against OpenAI:

```elixir
engine = ALLM.Engine.new(transcription_adapter: ALLM.Providers.OpenAI.Transcription)

{:ok, response} = ALLM.transcribe(engine, ALLM.Audio.from_file("interview.mp3"))
response.text
```

`response.usage` is always an `%ALLM.Usage{}`, never `nil`. Providers that
bill transcription by the second report `response.duration_seconds` instead
of token counts: OpenAI's `whisper-1` and `gpt-transcribe` do that, while
`gpt-4o-mini-transcribe` and Gemini report tokens. The provider's full body
stays on `response.raw`.

An engine without the slot returns an engine error before anything else
runs:

    iex> {:error, error} = ALLM.synthesize(ALLM.Engine.new(), "Hello.")
    iex> error.reason
    :no_speech_adapter
    iex> {:error, error} = ALLM.transcribe(ALLM.Engine.new(), ALLM.Audio.from_file("a.mp3"))
    iex> error.reason
    :no_transcription_adapter

## Formats

`:format` names a file format, not a provider parameter. The closed set is:

    iex> ALLM.SpeechRequest.formats()
    [:mp3, :opus, :aac, :flac, :wav, :pcm]

`nil` means "the provider's default" (MP3 on OpenAI). An unknown format is
rejected before any call:

    iex> engine = ALLM.Engine.new(speech_adapter: ALLM.Providers.FakeSpeech)
    iex> {:error, error} = ALLM.synthesize(engine, "Hello.", format: :ogg)
    iex> error.reason
    :invalid_speech_request

`response.format` reports what actually arrived, read from the response's
content type. It is not copied from the request, so it is set even when you
asked for the default, and it is `nil` if the provider answered with a type
outside the set above.

    iex> ALLM.SpeechResponse.mime_to_format("audio/mpeg")
    :mp3
    iex> ALLM.SpeechResponse.mime_to_format("audio/x-something-else")
    nil

For transcription, the accepted input formats are the provider's:

  * **OpenAI** takes flac, m4a, mp3, mp4, mpeg, mpga, oga, ogg, wav and
    webm. It picks the decoder from the upload's filename extension, so a
    clip built with `ALLM.Audio.from_binary/2` needs a MIME type that maps to
    one of those extensions. Otherwise the adapter refuses it locally rather
    than sending it under a name OpenAI would reject.
  * **Gemini** takes `audio/wav`, `audio/mpeg`, `audio/aiff`, `audio/aac`,
    `audio/ogg`, `audio/opus` and `audio/flac`. Any other MIME type is
    refused locally.
  * **ElevenLabs** detects the format from the audio itself: an MP3 uploaded
    as `audio.bin` with `application/octet-stream` was transcribed
    correctly. The adapter therefore has no MIME check, and a clip with an
    unknown MIME type is uploaded as `audio.bin`.

## Voices are provider strings

`:voice` is a string passed to the provider as-is. ALLM keeps no voice list,
because the valid set differs per provider and per model: OpenAI's `tts-1`
accepts fewer voices than its newer speech models, and Gemini's voice names
share none with OpenAI's. A voice the model does not know comes back from
the provider as an `:invalid_request` adapter error.

When `:voice` is `nil`, `ALLM.Providers.OpenAI.Speech` sends `"alloy"`,
which every OpenAI speech model tried so far accepts.

ElevenLabs voices are **ids**, not names: `"JBFqnCBsd6RMkjVDRZzb"`, not
`"George"`. The id goes in the request URL. When `:voice` is `nil`,
`ALLM.Providers.ElevenLabs.Speech` sends `"JBFqnCBsd6RMkjVDRZzb"`, the voice
ElevenLabs' own quickstart uses, which answered when this was written. Your account's
voice ids are listed in the ElevenLabs dashboard and by its
`GET /v1/voices` endpoint; ALLM does not call it. An unknown voice id comes
back as an `:invalid_request` adapter error.

## Each audio slot has its own model

`engine.model` is the **chat** model, and the audio calls never read it. A
chat model name is not a speech or transcription model name on any
provider. Each audio slot has its own model field instead, `:speech_model`
and `:transcription_model`, so one engine can hold a chat model and both
audio models:

    iex> engine = ALLM.Engine.new(
    ...>   model: "gpt-5.4-nano",
    ...>   speech_adapter: ALLM.Providers.FakeSpeech,
    ...>   speech_model: "tts-1"
    ...> )
    iex> {:ok, response} = ALLM.synthesize(engine, "Hello.")
    iex> response.model
    "tts-1"

The model is resolved in this order: the request's `:model` (set per call
with `model:`), then the slot's engine field, then the adapter's own
default.

    iex> engine = ALLM.Engine.new(
    ...>   speech_adapter: ALLM.Providers.FakeSpeech,
    ...>   speech_model: "tts-1"
    ...> )
    iex> {:ok, response} = ALLM.synthesize(engine, "Hello.", model: "gpt-4o-mini-tts")
    iex> response.model
    "gpt-4o-mini-tts"

The adapter defaults are `gpt-4o-mini-tts` (OpenAI speech), `gpt-transcribe`
(OpenAI transcription), `gemini-flash-latest` (Gemini transcription),
`eleven_flash_v2_5` (ElevenLabs speech, its low-latency model) and
`scribe_v2` (ElevenLabs transcription).

`ALLM.stream_transcribe/3` is the one exception to the resolution order: it
never reads `engine.transcription_model`. ElevenLabs' batch and realtime
transcription models are different models (`scribe_v2` against
`scribe_v2_realtime`), and the realtime endpoint accepts only the latter, so
an engine configured for `transcribe/3` would break the realtime call. It
uses the request's `:model`, else the adapter's realtime default.

The per-slot fields persist with the engine, so a saved engine keeps its
audio models:

    iex> engine = ALLM.Engine.new(
    ...>   speech_adapter: ALLM.Providers.FakeSpeech,
    ...>   speech_model: "tts-1"
    ...> )
    iex> {:ok, restored} = engine |> ALLM.Serializer.to_json!() |> ALLM.Serializer.from_json()
    iex> {restored.speech_adapter, restored.speech_model}
    {ALLM.Providers.FakeSpeech, "tts-1"}

## One engine, two providers

The two audio slots are independent of each other and of the chat
`:adapter`, so one engine can use a different provider for each direction.
A common pairing transcribes with Gemini and speaks with OpenAI:

```elixir
engine =
  ALLM.Engine.new(
    adapter: ALLM.Providers.Anthropic,
    model: "claude-sonnet-4-6",
    transcription_adapter: ALLM.Providers.Gemini.Transcription,
    speech_adapter: ALLM.Providers.OpenAI.Speech,
    speech_model: "gpt-4o-mini-tts"
  )

{:ok, %{text: question}} = ALLM.transcribe(engine, ALLM.Audio.from_file("question.mp3"))
{:ok, answer} = ALLM.generate(engine, ALLM.request([ALLM.user(question)]))
{:ok, %{audio: reply}} = ALLM.synthesize(engine, answer.output_text, voice: "coral")
```

Keys resolve at call time through `ALLM.Keys`, one per provider, and never
live on the engine. The engine above needs Anthropic, Gemini and OpenAI keys
to be resolvable.

## Size and length limits

Each transcription adapter declares the largest clip it will upload, in
bytes, through `max_audio_bytes/0`:

    iex> ALLM.Providers.OpenAI.Transcription.max_audio_bytes()
    26148864
    iex> ALLM.Providers.Gemini.Transcription.max_audio_bytes()
    15679488
    iex> ALLM.Providers.ElevenLabs.Transcription.max_audio_bytes()
    4999999999

OpenAI caps the whole upload at 25 MiB, and the adapter keeps 64 KiB of that
for the rest of the form. Gemini caps a request at 20 MB including the
base64 encoding, which leaves room for about 15 MB of audio. Gemini accepted
a slightly larger clip when this was measured, so its cap is on the safe
side. ElevenLabs documents its limit as "less than 5.0 GB"; that cap was
not probed, and the adapter uploads the clip from memory, so a clip that
large needs that much memory. Longer recordings have to be split.

A clip over the cap is refused before the upload, as an `:invalid_request`
adapter error carrying the byte count and the cap. `FakeTranscription`'s
cap is 1024 bytes, which makes the check cheap to try:

    iex> engine = ALLM.Engine.new(transcription_adapter: ALLM.Providers.FakeTranscription)
    iex> audio = ALLM.Audio.from_binary(:binary.copy(<<0>>, 2048), "audio/mpeg")
    iex> {:error, error} = ALLM.transcribe(engine, audio)
    iex> {error.reason, error.metadata.count, error.metadata.max}
    {:invalid_request, 2048, 1024}

To check before calling, compare `ALLM.Audio.size/1` with the adapter's cap:

    iex> engine = ALLM.Engine.new(transcription_adapter: ALLM.Providers.FakeTranscription)
    iex> {:ok, bytes} = ALLM.Audio.size(ALLM.Audio.from_binary(<<0, 1, 2>>, "audio/mpeg"))
    iex> bytes <= engine.transcription_adapter.max_audio_bytes()
    true

OpenAI speech takes at most 4096 characters of input, counted as Unicode
code points. The adapter checks this before the key is even looked up, so
an over-long input costs no request:

    iex> engine = ALLM.Engine.new(speech_adapter: ALLM.Providers.OpenAI.Speech)
    iex> {:error, error} = ALLM.synthesize(engine, String.duplicate("a", 4097))
    iex> {error.reason, error.metadata.count, error.metadata.max}
    {:context_length_exceeded, 4097, 4096}

Split long text on sentence boundaries and synthesize each piece.

`ALLM.Providers.ElevenLabs.Speech` has no local length check, because
ElevenLabs' limit differs per model (it documents 40,000 characters for
`eleven_flash_v2_5` and 5,000 for `eleven_v3`, though a 5,001-character
`eleven_v3` request was accepted, and billed, when this was checked). An
over-long input comes back from the provider; its documented
`text_too_long` error maps to `:context_length_exceeded`.

## Transcription fidelity on Gemini

Gemini has no transcription endpoint. `ALLM.Providers.Gemini.Transcription`
sends the audio to a chat model with a fixed instruction to produce a
verbatim transcript. The result is a language model's answer, not the
output of a dedicated speech model, and that has consequences:

  * **It can paraphrase.** The transcript is usually verbatim, but the model
    can tidy disfluencies, fix grammar, or rephrase. A Whisper-family model
    such as OpenAI's cannot. When exact wording matters (legal, medical,
    quotation), use `ALLM.Providers.OpenAI.Transcription`.
  * **Silence is not an empty transcript.** Given several minutes of pure
    silence, the model returned fluent, invented speech rather than `""`.
    Do not treat non-empty text as proof that a clip contained speech. If
    that matters, check for silence before transcribing.
  * **It can be blocked.** A safety or recitation stop returns a
    `:content_filter` adapter error. Transcribing well-known recited material
    such as song lyrics or famous speeches can trigger it.
  * **It can be truncated.** When the model hits its output limit, the
    partial transcript comes back as a success with
    `response.metadata.finish_reason == :length`. Check for it on long
    clips.

On the other hand, Gemini costs less per minute of audio, and `:prompt` is
useful context for it: names, spellings and subject matter.

## Errors and retries

Both calls return three error types, checked in this order:

  1. `%ALLM.Error.EngineError{}` when the slot is empty
     (`:no_speech_adapter`, `:no_transcription_adapter`).
  2. `%ALLM.Error.ValidationError{}` when the request is malformed
     (`:invalid_speech_request`, `:invalid_transcription_request`), for
     example empty input text.
  3. An adapter error, `%ALLM.Error.SpeechAdapterError{}` or
     `%ALLM.Error.TranscriptionAdapterError{}`, for everything the provider
     or the adapter's own checks reject.

`:unsupported_feature` is the adapter error for a request field the
provider cannot express. ElevenLabs has no `:instructions` field, no AAC or
FLAC output and no transcription `:prompt`, and OpenAI's PCM and WAV are
fixed at 24,000 Hz, so each of those is refused before any request, and
before the key lookup:

    iex> engine = ALLM.Engine.new(speech_adapter: ALLM.Providers.ElevenLabs.Speech)
    iex> {:error, error} = ALLM.synthesize(engine, "Hello.", format: :aac)
    iex> {error.reason, error.metadata.field}
    {:unsupported_feature, :format}
    iex> engine = ALLM.Engine.new(speech_adapter: ALLM.Providers.OpenAI.Speech)
    iex> {:error, error} = ALLM.synthesize(engine, "Hello.", format: :pcm, sample_rate: 16_000)
    iex> error.reason
    :unsupported_feature

`:rate_limited`, `:provider_unavailable`, `:timeout` and `:network_error`
are retried under the engine's retry policy. Every other reason, including
`:content_filter`, comes back immediately. The bundled transcription
adapters make one attempt per call, because each attempt uploads the whole
clip again, so a clip is uploaded at most three times at the default
policy. `ALLM.Providers.OpenAI.Speech` and `ALLM.Providers.ElevenLabs.Speech`
keep their own retry loop inside the façade's, so a `:timeout` on synthesis
can cost up to nine attempts at the default policy, against three for the
other retryable reasons. The streaming calls are never retried; see "A
failed stream ends with an error".

A missing API key is the one exception to the error tuples:
`ALLM.Keys.fetch!/2` **raises** `%ALLM.Error.EngineError{reason: :missing_key}`
by design, and the adapters do not rescue it. The adapters' local checks
(size, MIME type, input length) run before the key lookup, so a request
they reject returns an error tuple even without a key.

    iex> engine = ALLM.Engine.new(
    ...>   transcription_adapter: ALLM.Providers.FakeTranscription,
    ...>   adapter_opts: [transcription_script: [{:retry_until_call, 2}, {:ok, "second try"}]]
    ...> )
    iex> {:ok, response} = ALLM.transcribe(engine, ALLM.Audio.from_binary("ID3...", "audio/mpeg"))
    iex> response.text
    "second try"

## Streaming speech

`ALLM.stream_synthesize/3` takes the same arguments as `ALLM.synthesize/3`
and returns `{:ok, events}`, a lazy stream of `t:ALLM.SpeechEvent.t/0`
values: one `:speech_started`, then `:audio_delta` events carrying the next
bytes of audio, then one `:speech_completed`. Nothing is requested until
the stream is reduced, and the first bytes can be played before the rest
exist. `ALLM.AudioStream.collect_speech/1` folds the events into the
`%ALLM.SpeechResponse{}` that `synthesize/3` would have returned:

    iex> engine = ALLM.Engine.new(
    ...>   speech_adapter: ALLM.Providers.FakeSpeech,
    ...>   adapter_opts: [chunk_bytes: 8]
    ...> )
    iex> {:ok, stream} = ALLM.stream_synthesize(engine, "Hello there.", format: :pcm, sample_rate: 24_000)
    iex> events = Enum.to_list(stream)
    iex> Enum.map(events, &elem(&1, 0))
    [:speech_started, :audio_delta, :audio_delta, :audio_delta, :speech_completed]
    iex> for {:audio_delta, bytes} <- events, do: bytes
    ["FAKE-AUD", "IO:Hello", " there."]
    iex> {:ok, response} = ALLM.AudioStream.collect_speech(events)
    iex> {response.format, response.sample_rate, ALLM.Audio.to_binary(response.audio)}
    {:pcm, 24000, {:ok, "FAKE-AUDIO:Hello there."}}

Reduce a stream **once**: each reduction of a real adapter's stream makes
its own request. To play the audio and keep the result, keep the events as
they go by (the example above keeps them in a list) and collect them
afterwards.

In an application, forward each delta as it arrives:

```elixir
engine = ALLM.Engine.new(speech_adapter: ALLM.Providers.ElevenLabs.Speech)

{:ok, stream} = ALLM.stream_synthesize(engine, "Hello there.", format: :pcm)

Enum.each(stream, fn
  {:speech_started, %{sample_rate: rate}} -> MyApp.Speaker.open(rate)
  {:audio_delta, pcm} -> MyApp.Speaker.play(pcm)
  {:speech_completed, _} -> MyApp.Speaker.close()
  {:error, error} -> MyApp.Speaker.abort(error)
end)
```

Halting the stream early (`Enum.take/2`, a `Stream.take_while/2` that
stops) closes the provider connection.

Streaming uses the same `:speech_adapter` slot. An adapter opts in by also
implementing `ALLM.SpeechStreamAdapter`; `ALLM.Providers.OpenAI.Speech` and
`ALLM.Providers.ElevenLabs.Speech` both do. OpenAI streams the same
`/v1/audio/speech` request as chunked HTTP; ElevenLabs uses its `/stream`
endpoint.

### Streaming text in

`ALLM.stream_synthesize_input/3` takes the text as an enumerable of
strings, so speech can start on the first words of an answer that is still
being written. It takes the request fields as options (there is no text
argument to attach them to), or a whole `%ALLM.SpeechRequest{}` as
`request:`.

    iex> engine = ALLM.Engine.new(speech_adapter: ALLM.Providers.FakeSpeech)
    iex> {:ok, stream} = ALLM.stream_synthesize_input(engine, ["Hel", "", "lo."])
    iex> for {:audio_delta, bytes} <- stream, do: bytes
    ["FAKE-AUDIO:Hel", "FAKE-AUDIO:lo."]

Empty strings are skipped. Only `ALLM.Providers.ElevenLabs.Speech`
implements it (over a WebSocket); OpenAI's text-in streaming is its Realtime
API, which ALLM does not wrap. An adapter that streams whole texts only is
refused before anything runs:

    iex> engine = ALLM.Engine.new(speech_adapter: ALLM.Providers.OpenAI.Speech)
    iex> {:error, error} = ALLM.stream_synthesize_input(engine, ["Hi."])
    iex> error.reason
    :missing_stream_adapter

`ALLM.AudioStream.text_deltas/1` turns a chat stream into those text chunks:
it keeps the text of each `:text_delta` event and drops the rest.

    iex> engine = ALLM.Engine.new(
    ...>   adapter: ALLM.Providers.Fake,
    ...>   speech_adapter: ALLM.Providers.FakeSpeech,
    ...>   adapter_opts: [stream_script: [[{:text_delta, "Hi "}, {:text_delta, "there."}, {:finish, :stop}]]]
    ...> )
    iex> {:ok, chat} = ALLM.stream(engine, [ALLM.user("Say hi.")])
    iex> {:ok, spoken} = ALLM.stream_synthesize_input(engine, ALLM.AudioStream.text_deltas(chat))
    iex> for {:audio_delta, bytes} <- spoken, do: bytes
    ["FAKE-AUDIO:Hi ", "FAKE-AUDIO:there."]

The adapter reduces the text enumerable in a separate process, so the
chat request is made from there. An input that reads the calling process's
mailbox or process dictionary does not see them; see "Feeding a live
source" below.

## Streaming transcription

`ALLM.stream_transcribe/3` takes an enumerable of raw audio chunks: PCM,
16-bit little-endian, mono, at `:sample_rate` (default 16,000 Hz). It
returns a stream of `t:ALLM.TranscriptionEvent.t/0` values:

  * `:transcription_started`;
  * `:partial_transcript`, a provisional text for the segment being heard.
    Each partial **replaces** the previous one;
  * `:committed_transcript`, a final segment. Committed segments are
    **appended**;
  * `:transcription_completed`, whose `:text` is every committed segment,
    trimmed and joined with one space.

<!-- -->

    iex> engine = ALLM.Engine.new(
    ...>   transcription_adapter: ALLM.Providers.FakeTranscription,
    ...>   adapter_opts: [transcription_script: [{:ok, "the quick fox"}]]
    ...> )
    iex> pcm = :binary.copy(<<0, 0>>, 16_000)
    iex> {:ok, stream} = ALLM.stream_transcribe(engine, [pcm], sample_rate: 16_000)
    iex> events = Enum.to_list(stream)
    iex> for {:partial_transcript, %{text: text}} <- events, do: text
    ["the", "the quick", "the quick fox"]
    iex> {:ok, response} = ALLM.AudioStream.collect_transcription(events)
    iex> {response.text, response.duration_seconds}
    {"the quick fox", 1.0}

`duration_seconds` on a stream is computed from the bytes sent
(`bytes / (sample_rate * 2)`), not reported by the provider.

Chunk sizes are yours to choose, and a chunk may end in the middle of a
sample: the adapter carries the odd byte into the next chunk. An input whose
total length is odd ends the stream with an `:invalid_request` error. The
atom `:commit` in the input forces a segment boundary, under either
`:commit_strategy` (`:vad`, the default, lets the provider decide where
segments end; `:manual` commits only on `:commit` and at the end of input).

Each adapter lists the sample rates it accepts. Check before you open a
microphone:

    iex> ALLM.Providers.ElevenLabs.Transcription.stream_sample_rates()
    [8000, 16000, 22050, 24000, 44100, 48000]

A rate outside that list is refused before anything runs. Only
`ALLM.Providers.ElevenLabs.Transcription` implements
`ALLM.TranscriptionStreamAdapter`; OpenAI's and Gemini's transcription
adapters are request/response only.

### Feeding a live source

The adapter reduces your input enumerable in a helper process, so it can
keep reading the provider's messages while your input waits for its next
chunk. That has one consequence: an enumerable that `receive`s messages
sent to *your* process never sees them. Subscribe from inside the stream
instead. A `Stream.resource/3` start function runs in the process that
reduces the stream, so a subscription made there delivers the chunks to the
right place:

```elixir
mic_chunks =
  Stream.resource(
    fn -> MyApp.Microphone.subscribe(self()) end,
    fn ref ->
      receive do
        {^ref, :eof} -> {:halt, ref}
        {^ref, pcm} -> {[pcm], ref}
      end
    end,
    fn ref -> MyApp.Microphone.unsubscribe(ref) end
  )

{:ok, heard} = ALLM.stream_transcribe(engine, mic_chunks, sample_rate: 16_000)
```

When the stream is halted, the helper process is killed. A killed process
runs no cleanup code, so the `unsubscribe` above does not run then; a
subscription that monitors its subscriber is released when the helper
exits.

## A failed stream ends with an error

A streaming call returns `{:error, _}` synchronously only for problems found
before anything is sent: an empty slot, an adapter that does not stream, an
invalid request, or an adapter's own checks. Anything that goes wrong after
the stream has opened (a rejected key, a dropped connection, a timeout)
arrives as the stream's **last event**, `{:error, adapter_error}`, and
nothing follows it. `collect_speech/1` and `collect_transcription/1` then
return that error:

    iex> error = ALLM.Error.SpeechAdapterError.new(:network_error)
    iex> engine = ALLM.Engine.new(
    ...>   speech_adapter: ALLM.Providers.FakeSpeech,
    ...>   adapter_opts: [speech_script: [{:error, error}]]
    ...> )
    iex> {:ok, stream} = ALLM.stream_synthesize(engine, "Hello.")
    iex> {:error, error} = ALLM.AudioStream.collect_speech(stream)
    iex> {error.reason, error.metadata.bytes_received}
    {:network_error, 0}

This is deliberately different from chat, where a mid-stream error folds
into a response with `finish_reason: :error`. A speech response has no
finish reason, and half a clip is not a clip. What arrived is described on
the error instead: `metadata.bytes_received` for speech,
`metadata.committed_text` for transcription. The audio itself is never put
on an error.

When the failure came from your input enumerable rather than the provider,
`metadata.cause` is `:input_raised` or `:input_crashed`, and a chunk that is
not a string (speech) or not a binary or `:commit` (transcription) gives
`:invalid_input_chunk`. A chat error inside `text_deltas/1` raises in the
input, so speaking a failed chat answer ends with `:input_raised` and never
finishes as a successful clip of the truncated text.

Streams are never retried by ALLM, and `opts[:stream_timeout]` (default
60,000 ms) bounds the silence between two messages, where a provider
message and an input chunk both count; it ends the stream with `:timeout`.

## PCM and sample rates

`:pcm` is raw 16-bit little-endian mono samples with no header, so it
cannot be played without knowing the sample rate. It is also the cheapest
format to start playing: there is nothing to decode. `SpeechRequest` and
`SpeechResponse` carry a `:sample_rate`, and every stream's
`:speech_started` event reports the rate that applies. `nil` on the request
means "the adapter's default for the format", and **the PCM default is
24,000 Hz on every bundled adapter**, so switching providers never changes
the playback rate silently.

| Adapter | `:pcm` and `:wav` rates | Other formats |
|---------|-------------------------|---------------|
| OpenAI | 24,000 only | `:sample_rate` must be `nil` |
| ElevenLabs | 8,000, 16,000, 22,050, **24,000**, 32,000, 44,100, 48,000 | `:mp3` 22,050, 24,000, **44,100**; `:opus` **48,000** |

Bold marks the default. A rate an adapter cannot produce is
`:unsupported_feature`. On ElevenLabs, 44,100 Hz PCM and WAV need its Pro
tier; on a lower tier the provider's refusal also comes back as
`:unsupported_feature`.

## The voice loop

The latency-sensitive loop is: microphone audio in, a transcript, a chat
answer, speech out. With ElevenLabs for both audio directions and any chat
provider:

```elixir
engine =
  ALLM.Engine.new(
    adapter: ALLM.Providers.OpenAI,
    model: "gpt-5.4-nano",
    transcription_adapter: ALLM.Providers.ElevenLabs.Transcription,
    speech_adapter: ALLM.Providers.ElevenLabs.Speech
  )

{:ok, heard} = ALLM.stream_transcribe(engine, mic_chunks, sample_rate: 16_000)
{:ok, %{text: question}} = ALLM.AudioStream.collect_transcription(heard)

{:ok, chat} = ALLM.stream(engine, [ALLM.user(question)])
{:ok, spoken} = ALLM.stream_synthesize_input(engine, ALLM.AudioStream.text_deltas(chat), format: :pcm)

Enum.each(spoken, fn
  {:audio_delta, pcm} -> MyApp.Speaker.play(pcm)
  _ -> :ok
end)
```

`mic_chunks` is the subscription stream from "Feeding a live source". The
chat call needs the whole question, so it waits for the transcript to
complete; after that the answer streams straight into speech, and the first
words are spoken while the rest is still being written.
`examples/27_voice_loop.exs` runs this loop against the live providers.

## Choosing for latency

A few settings decide how soon the first audio plays:

  * **Model.** `ALLM.Providers.ElevenLabs.Speech` defaults to
    `eleven_flash_v2_5`, which ElevenLabs positions as its low-latency model.
    `eleven_multilingual_v2` is its higher-quality default, and slower. Pick
    with `speech_model:` on the engine or `model:` per call.
  * **Format.** `:pcm` needs no decoding before playback. MP3 is smaller on
    the wire.
  * **Text-in buffering on ElevenLabs.** By default
    `stream_synthesize_input/3` turns on ElevenLabs' `auto_mode`, which
    starts generating on each text message instead of waiting for about 120
    characters. In one measurement of the four chunks `"Hel"`, `"lo"`,
    `" world"`, `"."`, the first audio came 238 ms after the first chunk
    with `auto_mode`, against 563 ms without. `auto_mode` also voices each
    message as its own clip, and an LLM's token deltas split words
    (`"Hel"`, `"lo"`), so while it is on the adapter buffers the text and
    sends whole words only: a word boundary is whitespace, `!`, `?`, `;` or
    a full-width CJK mark. To turn both off, pass
    `options: %{"query" => %{"auto_mode" => false}}`; ElevenLabs then
    buffers by its `chunk_length_schedule`, which
    `options: %{"generation_config" => %{"chunk_length_schedule" => [...]}}`
    tunes.
  * **Measure it.** `[:allm, :audio, :first_chunk]` (see "Telemetry") reports
    the time from the call to the first audio or first partial transcript,
    per stream.

For reference, single measurements taken while the adapters were built: the
first audio from ElevenLabs' `/stream` came 425 ms after the request for a
44-character input, and OpenAI's chunked `/v1/audio/speech` sent its first
bytes after 1,728 ms (`gpt-4o-mini-tts`, 405 characters, PCM) and 1,353 ms
(`tts-1`, MP3). These are one run each, not benchmarks.

## Realtime transcription on ElevenLabs

`ALLM.Providers.ElevenLabs.Transcription.stream_transcribe/3` uses
ElevenLabs' realtime endpoint and its `scribe_v2_realtime` model. What was
observed while it was built:

  * **Pacing.** Audio does not have to arrive in real time. A 3.8-second
    clip sent as fast as the socket took it (about 0.3 s) was accepted and
    transcribed. A microphone paces itself; a file does not need to be
    slowed down.
  * **Partials can arrive after their commit.** A `:partial_transcript` can
    follow the `:committed_transcript` of the same segment. A display should
    stop showing a partial once its segment is committed.
  * **A commit needs audio.** ElevenLabs refuses a `:commit` covering less
    than 0.3 s of new audio, then closes the session; mid-stream that ends
    the stream with `:rate_limited`. At the end of input the adapter commits
    only if audio was sent since the last commit, so the final segment never
    trips it.
  * **Language.** `:language` sets the expected language. A detected
    language is reported only when `options` sets both
    `"include_timestamps" => true` and `"include_language_detection" => true`,
    and it arrives in a separate message that ElevenLabs sends either before
    or after its segment. Setting *either* option makes the adapter hold
    each `:committed_transcript` until that message arrives, for at most
    1,000 ms (tunable with `adapter_opts: [language_hold_ms: ms]`, a
    positive integer; anything else is refused before the socket opens),
    and then
    emit it with the language, or with `nil` if only `"include_timestamps"`
    is set. With neither option, segments are emitted at once and
    `:language` is `nil`.
    The realtime language is a two-letter code (`"en"`), while batch
    `transcribe/3` reports ElevenLabs' three-letter code (`"eng"`).
  * **A bad key opens the socket.** ElevenLabs accepts the WebSocket and then
    rejects the session, so the error arrives as the stream's last event
    (`:authentication_failed`), not as a synchronous `{:error, _}`. The
    adapter starts reducing your input only after the session has started,
    so a rejected session never consumes it.

## ElevenLabs

`ALLM.Providers.ElevenLabs.Speech` and
`ALLM.Providers.ElevenLabs.Transcription` resolve their key as
`:elevenlabs`, from `ELEVENLABS_API_KEY` by default (see `ALLM.Keys`). On
the WebSocket endpoints the key travels in a request header, never in the
URL. `opts[:base_url]` or `adapter_opts: [base_url: ...]` selects one of
ElevenLabs' data-residency hosts.

Formats map onto ElevenLabs' `output_format` values:

| `:format` | `output_format` sent | Default when `:sample_rate` is `nil` |
|-----------|----------------------|--------------------------------------|
| `nil` or `:mp3` | `mp3_22050_32`, `mp3_24000_48`, `mp3_44100_128` | `mp3_44100_128` |
| `:opus` | `opus_48000_64` | `opus_48000_64` |
| `:pcm` | `pcm_<rate>` | `pcm_24000` |
| `:wav` | `wav_<rate>` | `wav_24000` |
| `:aac`, `:flac` | refused, `:unsupported_feature` | — |

Other differences from OpenAI:

  * `:speed` is sent as `voice_settings.speed`. Other voice settings go in
    `options: %{"voice_settings" => %{"stability" => 0.3}}`, merged with it.
  * `:instructions` (speech) and `:prompt` (transcription) have no
    ElevenLabs field and are refused as `:unsupported_feature`.
  * ElevenLabs ignores body fields it does not know, so a mistyped
    `:options` key does nothing and raises no error.
  * `response.id` is ElevenLabs' `request-id` header for speech and its
    `transcription_id` for transcription; the per-request character cost is
    on `response.raw` as `%{"character_cost" => n}`. `response.usage` is
    all-`nil`: ElevenLabs reports no token counts.
  * Not every model serves every endpoint: `eleven_v3` is refused by the
    text-in WebSocket (`stream_synthesize_input/3`) with an
    `:invalid_request` error naming `unsupported_model`. ALLM does not fall
    back to another model.
  * An out-of-credit or quota error is `:invalid_request`, not
    `:rate_limited`, and is never retried.

## Telemetry

Each call runs in a span: `[:allm, :synthesize, :start | :stop | :exception]`
and `[:allm, :transcribe, :start | :stop | :exception]`. The `:stop` event
measures `audio_bytes` (synthesis) or `text_length` (transcription).
`:exception` is emitted instead of `:stop` when the call raises, and a
missing API key is the usual way to get there. Attach a handler for it as
well as `:stop`.

The synthesis `:stop` metadata includes the whole response, which includes
the audio bytes. A handler that logs `metadata.response` wholesale logs the
entire clip on every call. Read the `audio_bytes` measurement instead.

The streaming calls run in `[:allm, :stream_synthesize, …]` (both speech
forms; `input_length` is `nil` for `stream_synthesize_input/3`) and
`[:allm, :stream_transcribe, …]` spans. Those spans stop when the stream is
**returned**, before any audio has arrived, so their `:stop` metadata has
`response: nil` and they carry no audio. The number that matters for a
stream is the time to the first audio, and a separate event reports it:

  * `[:allm, :audio, :first_chunk]` fires once per stream, at the first
    `:audio_delta` (speech) or `:partial_transcript` (transcription), with
    `measurements.latency` in native time units since the façade call, and
    metadata `request_id`, `capability` (`:speech` or `:transcription`) and
    `provider_model`. It does not fire for a stream that fails before its
    first chunk.

```elixir
:telemetry.attach(
  "log-first-audio",
  [:allm, :audio, :first_chunk],
  fn _event, %{latency: latency}, %{capability: capability}, _config ->
    ms = System.convert_time_unit(latency, :native, :millisecond)
    IO.puts("first #{capability} chunk after #{ms} ms")
  end,
  nil
)
```

## Testing with the Fakes

`ALLM.Providers.FakeSpeech` and `ALLM.Providers.FakeTranscription` implement
the two adapter behaviours with scripted answers, so application tests need
no network and no key.

With no script, `FakeSpeech` returns the bytes `"FAKE-AUDIO:" <> input` and
`FakeTranscription` returns an empty transcript. A script is a list of
entries under `adapter_opts`, consumed one per call:

    iex> engine = ALLM.Engine.new(
    ...>   speech_adapter: ALLM.Providers.FakeSpeech,
    ...>   adapter_opts: [speech_script: [{:ok, "first"}, {:ok, "second"}]]
    ...> )
    iex> {:ok, one} = ALLM.synthesize(engine, "a")
    iex> {:ok, two} = ALLM.synthesize(engine, "b")
    iex> {ALLM.Audio.to_binary(one.audio), ALLM.Audio.to_binary(two.audio)}
    {{:ok, "first"}, {:ok, "second"}}

Script an error by giving the adapter error struct:

    iex> error = ALLM.Error.TranscriptionAdapterError.new(:content_filter)
    iex> engine = ALLM.Engine.new(
    ...>   transcription_adapter: ALLM.Providers.FakeTranscription,
    ...>   adapter_opts: [transcription_script: [{:error, error}]]
    ...> )
    iex> {:error, error} = ALLM.transcribe(engine, ALLM.Audio.from_binary("ID3...", "audio/mpeg"))
    iex> error.reason
    :content_filter

The entries are:

  * `{:ok, bytes}` or `{:ok, %ALLM.SpeechResponse{}}` (speech), and
    `{:ok, text}` or `{:ok, %ALLM.TranscriptionResponse{}}` (transcription);
  * `{:error, adapter_error}`;
  * `{:retry_until_call, n}`, which answers `:rate_limited` until the `n`th
    call and then moves on to the next entry;
  * `{:events, events}`, streaming calls only: the events are emitted
    verbatim, which is how a test scripts a stream that fails half-way. A
    non-streaming call given this entry returns an `:unknown` error.

The same scripts drive the streaming calls, one entry per call. On a stream,
`{:ok, bytes}` is split into `adapter_opts[:chunk_bytes]` pieces (default
1,024), and `{:ok, text}` becomes one partial per word, one committed
segment, and the completion. With no script, `stream_synthesize_input/3`
answers each text chunk with `"FAKE-AUDIO:" <> chunk`. An error scripted
for a stream arrives as the stream's last event, as it would from a
provider.

The Fakes reduce a streamed input in a helper process, exactly as the real
adapters do, so a test whose input reads the test process's mailbox fails
under the Fake the same way it would in production.

A script that runs out returns an `:unknown` adapter error with
`metadata.cause` set to `:speech_script_exhausted` or
`:transcription_script_exhausted`, rather than a default answer. A test that
scripts two entries therefore fails loudly if the code under test calls a
third time.

The real OpenAI and Gemini adapters also accept these script keys: with
`speech_script` or `transcription_script` in `adapter_opts`, they hand the
call to the matching Fake before any of their own checks run. The
transcription adapters pass their own `max_audio_bytes/0` to the Fake, so
the size cap is the real one. Nothing else of the real adapter runs: not
the MIME check, not the speech adapters' 4096-code-point input limit, and
not the request builder. A clip in a format the provider would refuse
still gets the scripted answer:

    iex> engine = ALLM.Engine.new(
    ...>   transcription_adapter: ALLM.Providers.OpenAI.Transcription,
    ...>   adapter_opts: [transcription_script: [{:ok, "scripted"}]]
    ...> )
    iex> {:ok, response} = ALLM.transcribe(engine, ALLM.Audio.from_binary("x", "audio/x-foo"))
    iex> {response.text, response.provider}
    {"scripted", :fake}

To test that a real adapter refuses a clip, call it without a script key.
Its local checks run before the key lookup, so no key is needed.

If you write your own adapter, check it against the published conformance
suites, `ALLM.Test.SpeechAdapterConformance` and
`ALLM.Test.TranscriptionAdapterConformance`, and for a streaming adapter
`ALLM.Test.SpeechStreamAdapterConformance`,
`ALLM.Test.SpeechInputStreamAdapterConformance` and
`ALLM.Test.TranscriptionStreamAdapterConformance`.
