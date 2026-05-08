# ALLM

> Provider-neutral LLM execution and agentic loops for Elixir — one engine surface, swap the adapter to retarget OpenAI, Anthropic, or Gemini without touching call sites.

## Why ALLM?

- **One surface, three providers.** Pick OpenAI, Anthropic, or Gemini by changing one line. Vision input, structured output, tool use, and image generation all share the same caller code.
- **Streaming is the primitive.** Every non-streaming entry point is a reducer over a token-by-token event stream. Drop into deltas when a UI needs them; pop back up when it doesn't.
- **State is plain data.** Threads, requests, and sessions round-trip through `:erlang.term_to_binary/1` and JSON. Persist them, ship them between nodes, resume them tomorrow — no PIDs, refs, funs, or API keys leak in.

Public API is stable across minor versions within v0.x; we'll bump major before breaking changes.

## Install

Add ALLM to your `mix.exs` deps:

```elixir
def deps do
  [
    {:allm, "~> 0.3"}
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

The `examples/` directory ships 15 runnable scripts that double as
integration tests. Each is self-asserting and runs against a real
provider. See `examples/README.md` for the full table; the deeper-dive
guides cross-link the relevant scripts at the bottom of each section.

For narrative walkthroughs, jump to a guide:

- [`guides/getting_started.md`](guides/getting_started.md) — install, run the Fake example, swap to a real provider.
- [`guides/streaming.md`](guides/streaming.md) — `stream_generate/3`, `stream/3`, the event union, filters, cancellation.
- [`guides/tools.md`](guides/tools.md) — declaring tools, manual mode, per-tool `manual: true`, ask-user suspension.
- [`guides/sessions.md`](guides/sessions.md) — multi-turn persistence, manual tool round-trips, ask-user resume.
- [`guides/vision.md`](guides/vision.md) — multimodal `[TextPart, ImagePart]` content across all three providers.
- [`guides/image_generation.md`](guides/image_generation.md) — `generate_image/3`, `edit_image/4`, `image_variations/3`.
- [`guides/errors_and_retries.md`](guides/errors_and_retries.md) — every error struct, retry policy, telemetry observability.
- [`guides/multi_tenant_keys.md`](guides/multi_tenant_keys.md) — per-call BYOK and the `ALLM.Keys` resolution chain.

## Real providers

ALLM ships three production adapters:

- **`ALLM.Providers.OpenAI`** — Chat Completions and Responses
  endpoints; auto-routes by model. Image generation via
  `ALLM.Providers.OpenAI.Images` (`dall-e-2`, `dall-e-3`,
  `gpt-image-1`).
- **`ALLM.Providers.Anthropic`** — Messages API; chat and vision input
  (no image generation).
- **`ALLM.Providers.Gemini`** — Google Generative Language API
  (`generateContent` / `streamGenerateContent`); chat and vision input.
  Image generation via `ALLM.Providers.Gemini.Images`.

Configure via env vars (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`,
`GEMINI_API_KEY`) or per-call:

```elixir
{:ok, response} = ALLM.generate(engine, request, api_key: tenant_key)
```

The per-call `:api_key` opt has the highest precedence in `ALLM.Keys`'s
five-level resolution chain — it overrides env vars, app config, and
the runtime store. The engine itself is safe to cache and share across
tenants. See [`guides/multi_tenant_keys.md`](guides/multi_tenant_keys.md)
for the full chain.

To run the bundled live-call examples:

```bash
OPENAI_API_KEY=sk-...     mix run examples/run_all.exs
ANTHROPIC_API_KEY=sk-...  ALLM_PROVIDER=anthropic mix run examples/run_all.exs
GEMINI_API_KEY=...        ALLM_PROVIDER=gemini    mix run examples/run_all.exs
```

## Compatibility

- **Elixir** `~> 1.17`
- **Erlang/OTP** 27+

ALLM follows semantic versioning. Within v0.x, public APIs and on-disk
session shapes are stable across minor releases — we'll bump major
before any breaking change.

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
