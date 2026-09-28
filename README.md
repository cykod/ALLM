# ALLM

> Provider-neutral LLM execution and agentic loops for Elixir — one engine surface, swap the adapter to retarget OpenAI, Anthropic, or Gemini without touching call sites. Embeddings, moderation, image generation, and speech in both directions ride the same engine.

## Why ALLM?

- **One surface, many providers.** Pick OpenAI, Anthropic, or Gemini for chat by changing one line. Vision input, structured output, tool use, image generation, embeddings, moderation, and audio all share the same caller code — and capability-only adapters (Voyage embeddings, ElevenLabs speech and transcription) slot in next to any chat provider.
- **Built for agents.** Tool loops run automatically or hand control back to you per tool; `compact: true` shrinks a large tool catalog to one-line stubs the model expands on demand.
- **Streaming is the primitive.** Every non-streaming chat entry point is a reducer over a token-by-token event stream. Drop into deltas when a UI needs them; pop back up when it doesn't. Speech streams the same way — including speaking an LLM's answer while it is still being written, and transcribing audio while it is still arriving.
- **State is plain data.** Threads, requests, and sessions round-trip through `:erlang.term_to_binary/1` and JSON. Persist them, ship them between nodes, resume them tomorrow — no PIDs, refs, funs, or API keys leak in.

ALLM is pre-1.0: a minor release (`0.x` → `0.x+1`) may carry breaking changes, and each one is listed under "Breaking changes" in [`CHANGELOG.md`](CHANGELOG.md). Patch releases do not break.

## Install

Add ALLM to your `mix.exs` deps:

```elixir
def deps do
  [
    {:allm, "~> 0.6"}
  ]
end
```

Run `mix deps.get`. Toolchain floor: Elixir `~> 1.17`, Erlang/OTP 27+.

## Hello, ALLM

Drive a one-shot chat against the deterministic `ALLM.Providers.Fake`
adapter — no API key, no network:

```elixir
engine = ALLM.Engine.new(
adapter: ALLM.Providers.Fake,
adapter_opts: [script: [{:text, "Hello, ALLM!"}, {:finish, :stop}]]
)
{:ok, %ALLM.ChatResult{final_response: %ALLM.Response{output_text: text}}} =
ALLM.chat(engine, [ALLM.user("Hi.")])
text
# => "Hello, ALLM!"
```

The block above is the canonical first-run snippet. The same code lives
as a runnable doctest on the `ALLM` module — both copies are kept in
lock-step by `test/readme_hello_consistency_test.exs`.

## Pick a provider

Construct an engine for any of the three bundled providers. Once an
engine is in hand, **every call site below this section is identical
across providers** — pick once, swap freely.

```elixir
# OpenAI
engine = ALLM.Engine.new(adapter: ALLM.Providers.OpenAI, model: "gpt-4.1-mini")

# Anthropic
engine = ALLM.Engine.new(adapter: ALLM.Providers.Anthropic, model: "claude-sonnet-4-5")

# Gemini
engine = ALLM.Engine.new(adapter: ALLM.Providers.Gemini, model: "gemini-2.5-flash")
```

The shared call site any of those engines drops into:

```elixir
{:ok, response} = ALLM.chat(engine, [ALLM.user("Say hi.")])
```

API keys come from `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, and
`GEMINI_API_KEY` by default — see [Real providers](#real-providers)
below for per-call BYOK and the full resolution chain.

## The 5-minute tour

A grand tour of what ALLM looks like in practice. Every snippet uses the
same `engine` value — pick a provider once, every call site keeps
working when you swap.

### 1. Generate — single round-trip

```elixir
# Synchronous — get the final response
{:ok, %ALLM.Response{output_text: text}} =
  ALLM.generate(engine, ALLM.request([ALLM.user("Name three primes.")]))

# Streaming — same engine, same request, token-by-token
{:ok, stream} =
  ALLM.stream_generate(engine, ALLM.request([ALLM.user("Name three primes.")]))

Enum.each(stream, fn
  {:text_delta, %{delta: t}} -> IO.write(t)
  _other                     -> :ok
end)
```

`generate/3` is implemented as a fold over `stream_generate/3`. Streaming
is the primitive; sync is the convenience. Deeper dive: see
[`guides/streaming.md`](guides/streaming.md).

### 2. Stream — token-by-token

`ALLM.stream_generate/3` (single round-trip) and `ALLM.stream/3`
(multi-turn, including tool calls) both return a lazy enumerable of
`ALLM.Event` tagged tuples. No event fires until you reduce.

```elixir
{:ok, stream} = ALLM.stream(engine, [ALLM.user("Tell me a haiku.")])

stream
|> Enum.each(fn
  {:text_delta, %{delta: t}}         -> IO.write(t)
  {:step_completed, %{response: r}}  -> IO.puts("\n[step] #{r.finish_reason}")
  {:chat_completed, %{result: r}}    -> IO.puts("\n[done] #{r.halted_reason}")
  _                                  -> :ok
end)
```

Filter knobs (`:emit_text_deltas`, `:emit_tool_deltas`,
`:include_raw_chunks`, `:on_event`) live on every streaming entry
point. See [`guides/streaming.md`](guides/streaming.md) for the full
event union, cancellation semantics, and observer-callback rules.

### 3. Chat — multi-turn loop

```elixir
{:ok, result} =
  ALLM.chat(engine, [
    ALLM.system("You are a concise assistant."),
    ALLM.user("Hi! Who are you?")
  ])

result.final_response.output_text
# => "I'm a concise assistant. How can I help?"

# Continue the conversation by appending and re-issuing
followup =
  result.thread
  |> ALLM.Thread.add_message(ALLM.user("Tell me a joke."))

{:ok, result} = ALLM.chat(engine, followup)
```

`chat/3` runs the full model-tool loop until completion and returns a
`%ChatResult{}` with the final response, the accumulated thread, and
per-step records. The streaming sibling `ALLM.stream/3` emits the same
lifecycle as events.

### 4. Tools — declare, run, done

```elixir
weather =
  ALLM.tool(
    name: "get_weather",
    description: "Return the current weather for a city.",
    schema: %{
      "type" => "object",
      "properties" => %{"city" => %{"type" => "string"}},
      "required" => ["city"]
    },
    handler: fn %{"city" => city} ->
      {:ok, %{forecast: "sunny", city: city}}
    end
  )

engine = ALLM.Engine.put_tools(engine, [weather])

{:ok, result} =
  ALLM.chat(engine, [ALLM.user("What's the weather in Boston?")])

result.final_response.output_text
# => "It's sunny in Boston."

length(result.steps)
# => 2  — model called the tool, then summarized
```

The handler is a plain Elixir function. The engine runs it, encodes the
result for the next turn, and feeds it back to the model. For
`mode: :manual` (caller computes the tool result), per-tool `manual:
true`, `{:ask_user, _}` suspension, and the full tool-error policy, see
[`guides/tools.md`](guides/tools.md).

### 5. Sessions — pick up where you left off

```elixir
# Earlier — store the session after a turn:
#     binary = :erlang.term_to_binary(session)
#     MyApp.Repo.update!(conversation, session_blob: binary)

# Later, possibly on a different node, in a different request:
session = :erlang.binary_to_term(blob_from_db)

{:ok, session, result} =
  ALLM.Session.reply(engine, session, "What did I just ask?")

session.status
# => :completed
result.final_response.output_text
# => "You asked about the weather in Boston."
```

A `%ALLM.Session{}` bundles the thread with a status (`:idle`,
`:awaiting_user`, `:awaiting_tools`, `:completed`, `:error`) and any
pending tool calls or ask-user prompt. Round-trip it through ETF or
JSON, hand it to a worker, store it in a database column — when you're
ready, hand it back to `ALLM.Session.reply/4` (or `stream_reply/4`).
Deeper dive: [`guides/sessions.md`](guides/sessions.md).

## Worked examples

The `examples/` directory ships 25 runnable scripts that double as
integration tests. Each is self-asserting and runs against a real
provider. See `examples/README.md` for the full table; the deeper-dive
guides cross-link the relevant scripts at the bottom of each section.

For narrative walkthroughs, jump to a guide:

- [`guides/getting_started.md`](guides/getting_started.md) — install, run the Fake example, swap to a real provider.
- [`guides/streaming.md`](guides/streaming.md) — `stream_generate/3`, `stream/3`, the event union, filters, cancellation.
- [`guides/tools.md`](guides/tools.md) — declaring tools, manual mode, per-tool `manual: true`, ask-user suspension.
- [`guides/sessions.md`](guides/sessions.md) — multi-turn persistence, manual tool round-trips, ask-user resume.
- [`guides/vision.md`](guides/vision.md) — multimodal `[TextPart, ImagePart]` content across all three providers.
- [`guides/image_generation.md`](guides/image_generation.md) — `generate_image/3`, `edit_image/4`.
- [`guides/embeddings.md`](guides/embeddings.md) — `embed/3`, transparent batch chunking, OpenAI / Gemini / Voyage.
- [`guides/moderation.md`](guides/moderation.md) — `moderate/3`, `flagged?/1` versus per-category thresholds, image input.
- [`guides/classification.md`](guides/classification.md) — `classify/3`, choice / score / yes-no questions, confidence routing in caller code, TypeSafe Jev.
- [`guides/audio.md`](guides/audio.md) — `synthesize/3`, `transcribe/3`, streaming speech and realtime transcription, the voice loop.
- [`guides/errors_and_retries.md`](guides/errors_and_retries.md) — every error struct, retry policy, telemetry observability.
- [`guides/multi_tenant_keys.md`](guides/multi_tenant_keys.md) — per-call BYOK and the `ALLM.Keys` resolution chain.
- [`guides/fakes.md`](guides/fakes.md) — testing with the scripted Fake adapters, no network.

## Real providers

ALLM ships three chat adapters and two capability-only providers:

- **`ALLM.Providers.OpenAI`** — Chat Completions and Responses
  endpoints; auto-routes by model.
- **`ALLM.Providers.Anthropic`** — Messages API; chat and vision input.
- **`ALLM.Providers.Gemini`** — Google Generative Language API
  (`generateContent` / `streamGenerateContent`); chat and vision input.
- **Voyage** — embeddings only (Anthropic's recommended partner).
- **ElevenLabs** — speech and transcription only, batch and streaming.

Beyond chat, each capability has its own engine slot, so one engine can
pair providers — say, Anthropic for chat, Voyage for embeddings, and
ElevenLabs for speech:

| Capability | Engine slot | Bundled adapters |
|---|---|---|
| Image generation / editing | `:image_adapter` | `OpenAI.Images` (`gpt-image-1`), `Gemini.Images` |
| Embeddings | `:embed_adapter` | `OpenAI.Embeddings`, `Gemini.Embeddings`, `Voyage.Embeddings` |
| Moderation | `:moderation_adapter` | `OpenAI.Moderation` |
| Text-to-speech | `:speech_adapter` | `OpenAI.Speech`, `ElevenLabs.Speech` |
| Speech-to-text | `:transcription_adapter` | `OpenAI.Transcription`, `Gemini.Transcription`, `ElevenLabs.Transcription` |

Streaming speech (`stream_synthesize/3`) works on `OpenAI.Speech` and
`ElevenLabs.Speech`; speaking a streamed text input
(`stream_synthesize_input/3`) and realtime transcription
(`stream_transcribe/3`) are ElevenLabs-only. All adapter modules live
under `ALLM.Providers.*`.

```elixir
engine =
  ALLM.Engine.new(
    adapter: ALLM.Providers.Anthropic,
    model: "claude-sonnet-4-6",
    embed_adapter: ALLM.Providers.Voyage.Embeddings,
    speech_adapter: ALLM.Providers.ElevenLabs.Speech
  )

# `engine.model` is the chat model, so embeddings name theirs per call;
# speech falls back to the adapter's default model when none is set.
{:ok, embeddings} = ALLM.embed(engine, ["first chunk", "second chunk"], model: "voyage-3.5-lite")
{:ok, speech} = ALLM.synthesize(engine, "Hello there.")
```

Configure via env vars (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`,
`GEMINI_API_KEY`, `VOYAGE_API_KEY`, `ELEVENLABS_API_KEY`) or per-call:

```elixir
{:ok, response} = ALLM.generate(engine, request, api_key: tenant_key)
```

The per-call `:api_key` opt has the highest precedence in `ALLM.Keys`'s
five-level resolution chain — it overrides env vars, app config, and
the runtime store. The engine itself is safe to cache and share across
tenants. See [`guides/multi_tenant_keys.md`](guides/multi_tenant_keys.md)
for the full chain.

To run the bundled live-call examples, put your keys in a `.env` file
at the repository root (see `examples/README.md`) and pick an arm:

```bash
mix run examples/run_all.exs                                # OpenAI (default)
ALLM_PROVIDER=anthropic  mix run examples/run_all.exs       # embeddings scripts also need VOYAGE_API_KEY
ALLM_PROVIDER=gemini     mix run examples/run_all.exs
ALLM_PROVIDER=elevenlabs mix run examples/run_all.exs       # audio scripts only
```

## Compatibility

- **Elixir** `~> 1.17`
- **Erlang/OTP** 27+

ALLM follows semantic versioning for pre-1.0 software: breaking
changes to the public API or to persisted shapes land only in minor
releases, and are always listed under "Breaking changes" in
[`CHANGELOG.md`](CHANGELOG.md).

## Development

```bash
mix deps.get
mix compile
mix test                  # full suite (80% coverage threshold)
mix format
mix credo --strict
mix dialyzer
iex -S mix
```

The included dev container installs a compatible toolchain
automatically.

## License

MIT.
