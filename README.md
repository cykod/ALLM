# ALLM

Provider-neutral LLM execution for Elixir.

ALLM splits an LLM call into four layers:

1. **Serializable data** — `ALLM.Message`, `ALLM.Request`, `ALLM.Response`, `ALLM.Thread`, `ALLM.Session`, `ALLM.Event`, …
2. **Runtime** — `ALLM.Engine` + `ALLM.Adapter` / `ALLM.StreamAdapter` / `ALLM.ToolExecutor` behaviours
3. **Stateless execution** (Phase 5+) — ALLM.generate/3, ALLM.stream_generate/3, ALLM.chat/3, ALLM.stream/3
4. **Stateful continuation** (Phase 8) — ALLM.Session.start/3, ALLM.Session.reply/4, streaming variants

Streaming is the primitive execution model: non-streaming functions are reducers over an `ALLM.Event` stream.

See `steering/allm_engine_session_streaming_spec_v0_2.md` in the source tree for the full design.

## Getting Started

Add ALLM to your `mix.exs` deps:

```elixir
def deps do
  [
    {:allm, "~> 0.2"}
  ]
end
```

Run `mix deps.get`, then drop into `iex -S mix` and try a `chat/3` call against
the deterministic `ALLM.Providers.Fake` adapter — no API key, no network:

```elixir
engine =
  ALLM.Engine.new(
    adapter: ALLM.Providers.Fake,
    adapter_opts: [script: [{:text, "Hello, ALLM!"}, {:finish, :stop}]]
  )

{:ok, %ALLM.ChatResult{final_response: %ALLM.Response{output_text: text}}} =
  ALLM.chat(engine, [ALLM.user("Hi.")])

text
# => "Hello, ALLM!"
```

## Real Providers

For real-provider execution, use one of the bundled adapters:

- `ALLM.Providers.OpenAI` — OpenAI Chat Completions and Responses endpoints.
- `ALLM.Providers.Anthropic` — Anthropic Messages API.

See [`examples/README.md`](examples/README.md) for the runnable smoke set
(`ALLM_PROVIDER=openai|anthropic mix run examples/run_all.exs`).

## Development

Requires Elixir ~> 1.17 and Erlang/OTP 27+.

```bash
mix deps.get
mix compile
mix test
mix format
```

The included dev container installs a compatible toolchain automatically.

## License

MIT.
