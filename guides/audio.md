# Audio: speech and transcription

ALLM has two audio primitives, one per direction:

  * `ALLM.synthesize/3` turns text into speech (text-to-speech, TTS) and
    returns an `%ALLM.SpeechResponse{}` whose `:audio` holds the bytes.
  * `ALLM.transcribe/3` turns speech into text (speech-to-text, STT) and
    returns an `%ALLM.TranscriptionResponse{}` whose `:text` is the
    transcript.

Both are request/response calls, parallel to images, embeddings and
moderation. Neither streams yet: the whole clip or the whole transcript
arrives in one response.

| Provider | Speech (`synthesize/3`) | Transcription (`transcribe/3`) |
|----------|-------------------------|--------------------------------|
| OpenAI | `ALLM.Providers.OpenAI.Speech` | `ALLM.Providers.OpenAI.Transcription` |
| Gemini | not bundled yet | `ALLM.Providers.Gemini.Transcription` |
| Anthropic | no audio endpoint | no audio endpoint |

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

## Voices are provider strings

`:voice` is a string passed to the provider as-is. ALLM keeps no voice list,
because the valid set differs per provider and per model: OpenAI's `tts-1`
accepts fewer voices than its newer speech models, and Gemini's voice names
share none with OpenAI's. A voice the model does not know comes back from
the provider as an `:invalid_request` adapter error.

When `:voice` is `nil`, `ALLM.Providers.OpenAI.Speech` sends `"alloy"`,
which every OpenAI speech model tried so far accepts.

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
(OpenAI transcription) and `gemini-flash-latest` (Gemini transcription).

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

OpenAI caps the whole upload at 25 MiB, and the adapter keeps 64 KiB of that
for the rest of the form. Gemini caps a request at 20 MB including the
base64 encoding, which leaves room for about 15 MB of audio. Gemini accepted
a slightly larger clip when this was measured, so its cap is on the safe
side. Longer recordings have to be split.

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

`:rate_limited`, `:provider_unavailable`, `:timeout` and `:network_error`
are retried under the engine's retry policy. Every other reason, including
`:content_filter`, comes back immediately. The bundled transcription
adapters make one attempt per call, because each attempt uploads the whole
clip again, so a clip is uploaded at most three times at the default
policy. `ALLM.Providers.OpenAI.Speech` keeps its own retry loop inside the
façade's, so a `:timeout` on synthesis can cost up to nine attempts at the
default policy, against three for the other retryable reasons.

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
    call and then moves on to the next entry.

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
`ALLM.Test.TranscriptionAdapterConformance`.
