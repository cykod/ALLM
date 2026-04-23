# ALLM

Provider-neutral LLM execution for Elixir.

ALLM splits an LLM call into four layers:

1. **Serializable data** — `ALLM.Message`, `ALLM.Request`, `ALLM.Response`, `ALLM.Thread`, `ALLM.Session`, `ALLM.Event`, …
2. **Runtime** — `ALLM.Engine` + `ALLM.Adapter` / `ALLM.StreamAdapter` / `ALLM.ToolExecutor` behaviours
3. **Stateless execution** (Phase 5+) — ALLM.generate/3, ALLM.stream_generate/3, ALLM.chat/3, ALLM.stream/3
4. **Stateful continuation** (Phase 8) — ALLM.Session.start/3, ALLM.Session.reply/4, streaming variants

Streaming is the primitive execution model: non-streaming functions are reducers over an `ALLM.Event` stream.

See `steering/allm_engine_session_streaming_spec_v0_2.md` in the source tree for the full design.

## Status

Pre-release scaffolding. Data structs and behaviour signatures are being laid down; execution paths and provider adapters are in progress.

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
