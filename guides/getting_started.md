# Getting started

ALLM is a provider-neutral LLM execution library for Elixir. You write
your workflow once — building a request, picking an engine, calling
`generate/3` or `chat/3` — and run it against OpenAI, Anthropic, Gemini,
or any custom adapter without changing the call site.

This guide walks you from a blank `mix.exs` to a working round-trip
against a real provider in five minutes. We'll use `ALLM.Providers.Fake`
(the deterministic test adapter that ships with the library) for the
first pass — it requires no API key and no network — then swap to a real
provider.

## Install

Add ALLM to your `mix.exs` deps:

```elixir
def deps do
  [
    {:allm, "~> 0.3"}
  ]
end
```

Run `mix deps.get`. ALLM pulls in `req`, `finch`, `jason`, and
`telemetry` as transitive deps; you don't need to declare them yourself.

The toolchain floor is Elixir `~> 1.17` and Erlang/OTP 27+.

## Hello, ALLM (no network)

The simplest possible round-trip uses the fake adapter. Open
`iex -S mix` in your project and paste:

    iex> engine = ALLM.Engine.new(
    ...>   adapter: ALLM.Providers.Fake,
    ...>   adapter_opts: [script: [{:text, "Hello, ALLM!"}, {:finish, :stop}]]
    ...> )
    iex> {:ok, %ALLM.ChatResult{final_response: %ALLM.Response{output_text: text}}} =
    ...>   ALLM.chat(engine, [ALLM.user("Hi.")])
    iex> text
    "Hello, ALLM!"

Three things happened:

1. `ALLM.Engine.new/1` built a runtime engine. Engines hold the
   non-serializable bits — adapter module, adapter opts, optional key
   resolver. They're cheap to construct and safe to share across
   processes.
2. `ALLM.chat/3` ran the auto-loop. With no tools declared, the loop
   completes after a single round-trip and returns an `%ALLM.ChatResult{}`
   wrapping the final `%ALLM.Response{}`.
3. The fake adapter ignored the request entirely and returned the
   scripted reply (`"Hello, ALLM!"`). That's the whole point — Fake is
   for testing orchestration, not provider wire fidelity.

## Building a request explicitly

`ALLM.chat/3` accepts either a list of messages or a `%Request{}`. The
list form is shorthand. Here's the explicit form:

    iex> engine = ALLM.Engine.new(
    ...>   adapter: ALLM.Providers.Fake,
    ...>   adapter_opts: [script: [{:text, "Three primes: 2, 3, 5."}, {:finish, :stop}]]
    ...> )
    iex> req = ALLM.request([
    ...>   ALLM.system("Be concise."),
    ...>   ALLM.user("Name three primes.")
    ...> ])
    iex> {:ok, %ALLM.ChatResult{final_response: %ALLM.Response{output_text: text}}} =
    ...>   ALLM.chat(engine, req)
    iex> text
    "Three primes: 2, 3, 5."

`ALLM.request/2` accepts the same opts you'd set on the request struct
directly: `:model`, `:tools`, `:tool_choice`, `:response_format`,
`:stream`, `:max_tokens`, `:temperature`, `:metadata`.

## When to reach for what

| You want to… | Use this | Returns |
|---|---|---|
| One-shot completion | `ALLM.generate/3` | `{:ok, %Response{}}` |
| One-shot streaming | `ALLM.stream_generate/3` | `{:ok, Enumerable.t}` of events |
| Single round-trip with tool execution | `ALLM.step/3` | `{:ok, %StepResult{}}` |
| Multi-turn auto-loop with tools | `ALLM.chat/3` | `{:ok, %ChatResult{}}` |
| Multi-turn auto-loop, streaming | `ALLM.stream/3` | `{:ok, Enumerable.t}` |
| Multi-turn with persistence between turns | `ALLM.Session.*` | `{:ok, %Session{}}` |
| Generate / edit / vary images | `ALLM.generate_image/3` etc. | `{:ok, %ImageResponse{}}` |

## Swap to a real provider

The engine is the only thing that changes — everything downstream stays
identical. For OpenAI:

```elixir
engine = ALLM.Engine.new(
  adapter: ALLM.Providers.OpenAI,
  model: "gpt-4.1-mini"
)

{:ok, response} = ALLM.generate(engine, ALLM.request([ALLM.user("Hi.")]))
```

For Anthropic:

```elixir
engine = ALLM.Engine.new(
  adapter: ALLM.Providers.Anthropic,
  model: "claude-sonnet-4-6"
)
```

For Gemini:

```elixir
engine = ALLM.Engine.new(
  adapter: ALLM.Providers.Gemini,
  model: "gemini-3-flash-preview"
)
```

Each provider has its own model strings; otherwise the call site is
byte-identical.

## Where do API keys come from?

You have four resolution paths, in priority order:

1. **Per-call** — `ALLM.generate(engine, req, api_key: "sk-...")`. Wins
   over everything. Use this for multi-tenant SaaS where the key changes
   per request.
2. **Engine-level resolver** — `ALLM.Engine.new(adapter: ..., keys: %{my_provider: fn -> System.fetch_env!("MY_KEY") end})`.
3. **Application config** — `config :allm, :keys, openai: "sk-..."`.
4. **Environment variable** — each provider has a default
   (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`).

Engines never persist API keys — they round-trip safely through ETF and
JSON. See `multi_tenant_keys.md` for the full resolution chain.

## Where to next

Pick the path that matches what you're building:

* **Streaming UI** → `streaming.md` — events, filters, cancellation.
* **Tool calls** → `tools.md` — auto loop, manual mode, ask-user.
* **Multi-turn persistence** → `sessions.md` — `%Session{}` and the
  status union.
* **Multi-modal input** → `vision.md` — `TextPart` and `ImagePart`.
* **Image generation** → `image_generation.md` — `generate_image/3`,
  `edit_image/4`, `image_variations/3`.
* **Production hardening** → `errors_and_retries.md` and
  `multi_tenant_keys.md`.

## Testing your integration

`ALLM.Providers.Fake` is the canonical test vehicle. Drop it into your
`config/test.exs`-built engine and write deterministic assertions
against scripted replies — no network, no flakes, no mocking
infrastructure.

    iex> engine = ALLM.Engine.new(
    ...>   adapter: ALLM.Providers.Fake,
    ...>   adapter_opts: [script: [{:text, "ok"}, {:finish, :stop}]]
    ...> )
    iex> {:ok, %ALLM.Response{output_text: text}} =
    ...>   ALLM.generate(engine, ALLM.request([ALLM.user("ping")]))
    iex> text
    "ok"

The `examples/` directory in the repository contains 15 numbered scripts
you can run against any of the bundled providers — see
`examples/README.md`.
