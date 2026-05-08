# Vision input

Vision input lets the model see images — a screenshot, a diagram, a
photo — alongside the user's text. ALLM exposes a single multi-modal
content shape that works across OpenAI, Anthropic, and Gemini: a list
of `%TextPart{}` and `%ImagePart{}` values as the message content.

This guide covers the part structs, image-source variants (URL, raw
bytes, file path), provider parity, and detail-level controls.

## Multi-modal content

Instead of a plain string, a `%Message{}` content can be a list of
content parts:

```elixir
import ALLM, only: [user: 1]

msg = user([
  %ALLM.TextPart{text: "What's in this picture?"},
  %ALLM.ImagePart{source: {:url, "https://example.com/photo.png"}}
])
```

The list form drops into `ALLM.request/2` and `ALLM.chat/3` exactly
like a string.

## ImagePart sources

`%ImagePart{}` accepts three source shapes:

```elixir
# Public URL
%ALLM.ImagePart{source: {:url, "https://example.com/photo.png"}}

# Raw bytes (with required mime_type)
bytes = File.read!("/path/to/photo.png")
%ALLM.ImagePart{source: {:bytes, bytes}, mime_type: "image/png"}

# File path (read at adapter time)
%ALLM.ImagePart{source: {:file, "/path/to/photo.png"}}
```

Each adapter chooses the most efficient wire shape automatically:

* **OpenAI** — accepts both URLs and base64 inline data via `image_url`.
* **Anthropic** — accepts URLs and base64 `source` blocks. URL-only
  models fall back to a wire-side fetch + inline.
* **Gemini** — uploads bytes inline via `inlineData`. URL inputs are
  fetched and inlined client-side.

## Round-trip example

    iex> engine = ALLM.Engine.new(
    ...>   adapter: ALLM.Providers.Fake,
    ...>   adapter_opts: [script: [{:text, "A red square."}, {:finish, :stop}]]
    ...> )
    iex> msg = ALLM.user([
    ...>   %ALLM.TextPart{text: "Describe this."},
    ...>   %ALLM.ImagePart{source: {:url, "https://example.com/red.png"}}
    ...> ])
    iex> {:ok, %ALLM.Response{output_text: text}} =
    ...>   ALLM.generate(engine, ALLM.request([msg]))
    iex> text
    "A red square."

Fake doesn't actually look at the image — it just returns the scripted
text. With a real provider, the image content reaches the model.

## Detail levels (OpenAI)

OpenAI's vision models accept a per-image detail hint:

```elixir
%ALLM.ImagePart{
  source: {:url, "https://example.com/photo.png"},
  detail: :high  # :auto | :low | :high
}
```

* `:auto` (default) — model decides based on image dimensions.
* `:low` — fixed 512×512 representation, cheaper.
* `:high` — full resolution, expensive but accurate for fine detail.

Anthropic and Gemini ignore the `:detail` field — their vision tiers
don't expose an equivalent knob. ALLM passes the field along to OpenAI
unchanged and silently drops it for the others (with a `:debug`-level
log on the first drop per process).

## Provider parity

| Feature | OpenAI | Anthropic | Gemini |
|---|---|---|---|
| URL source | yes | yes (some models) | client-side fetch |
| Raw bytes / base64 | yes | yes | yes |
| File path | yes (read client-side) | yes | yes |
| Image in `:system` role | rejected (raises) | rejected | rejected |
| `:detail` field | honored | dropped | dropped |
| Per-message multi-image | yes | yes | yes |

The "image in `:system` role" check is a pre-flight validation in every
adapter — the wire formats reject it (or behave inconsistently), so
ALLM raises a clear `ALLM.Error.ValidationError` before dispatch
instead of letting you debug an opaque 400.

## Common patterns

### Screenshot OCR

```elixir
{:ok, response} = ALLM.generate(engine, ALLM.request([
  ALLM.system("Extract every word visible in the image. Reply with a JSON array of strings."),
  ALLM.user([
    %ALLM.TextPart{text: "Extract text from this screenshot:"},
    %ALLM.ImagePart{source: {:file, "/tmp/screenshot.png"}}
  ])
]))
```

### Multi-image comparison

```elixir
{:ok, response} = ALLM.generate(engine, ALLM.request([
  ALLM.user([
    %ALLM.TextPart{text: "Which of these two images has more red?"},
    %ALLM.ImagePart{source: {:url, "https://example.com/a.png"}},
    %ALLM.ImagePart{source: {:url, "https://example.com/b.png"}}
  ])
]))
```

### Streaming a vision response

`stream_generate/3` works identically with vision input — the request
shape is the same, and you get text deltas back as the model
incrementally describes the image.

## File size and MIME limits

Each provider has its own limits (Anthropic caps base64 image bytes at
~5MB per image; OpenAI caps at 20MB; Gemini at 7MB). Adapters validate
size pre-flight and raise `ALLM.Error.ValidationError` with a clear
reason if you exceed it. Compress or resize before sending.

Supported MIME types (intersection across providers): `image/png`,
`image/jpeg`, `image/gif`, `image/webp`. Adapters reject other types
pre-flight.

## Where to next

* `image_generation.md` — the parallel `:image_adapter` slot for
  generating new images.
* `examples/12_vision_input.exs` — runnable smoke test against any of
  the three providers.
* The `ALLM.Providers.OpenAI`, `ALLM.Providers.Anthropic`, and
  `ALLM.Providers.Gemini` module docs cover the per-provider quirks.
