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
    {:allm, "~> 0.3"}
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

- `ALLM.Providers.OpenAI` — OpenAI Chat Completions and Responses endpoints; OpenAI Images (`ALLM.Providers.OpenAI.Images`) for `dall-e-2`/`dall-e-3`/`gpt-image-1`.
- `ALLM.Providers.Anthropic` — Anthropic Messages API; chat-vision input only (no image generation per spec §35.7).

See [`examples/README.md`](examples/README.md) for the runnable smoke set
(`ALLM_PROVIDER=openai|anthropic mix run examples/run_all.exs`).

## Generating images

ALLM ships an image-generation surface (spec §35.4–§35.7) parallel to
the chat surface. Generation, editing (inpaint), and variations are all
served via `ALLM.generate_image/3`, `ALLM.edit_image/4`, and
`ALLM.image_variations/3` against an engine carrying an `:image_adapter`.

```elixir
img = ALLM.Image.from_binary(<<137, 80, 78, 71, 13, 10, 26, 10>>, "image/png")

engine =
  ALLM.Engine.new(
    image_adapter: ALLM.Providers.FakeImages,
    adapter_opts: [image_script: [{:ok, [img]}]]
  )

{:ok, %ALLM.ImageResponse{images: [image | _]}} =
  ALLM.generate_image(engine, "a watercolor kestrel in flight", size: "256x256")

{:ok, png_bytes} = ALLM.Image.to_binary(image)
```

Switch `:image_adapter` to `ALLM.Providers.OpenAI.Images` and supply
`OPENAI_API_KEY` to run against the real provider; see
[`examples/10_generate_image.exs`](examples/10_generate_image.exs) for
a full live-call worked example.

## Vision input

`ALLM.Message.content` accepts a list of content parts —
`[%ALLM.TextPart{}, %ALLM.ImagePart{}]` — for vision-capable models
(spec §35.6). Both `ALLM.Providers.OpenAI` (Chat Completions and
Responses) and `ALLM.Providers.Anthropic` (Messages API) translate
the part list to their respective wire shapes:

```elixir
img = ALLM.Image.from_file("arch.png")

msg = %ALLM.Message{
  role: :user,
  content: [
    %ALLM.TextPart{text: "What's the failure mode in this diagram?"},
    %ALLM.ImagePart{image: img, detail: :high}
  ]
}

{:ok, %ALLM.Response{output_text: text}} =
  ALLM.generate(engine, ALLM.request([msg]))
```

The same engine + message shape works against either provider. See
[`examples/12_vision_input.exs`](examples/12_vision_input.exs) for a
runnable multi-provider smoke test.

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
