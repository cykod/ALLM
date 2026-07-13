# Image generation

Image generation lives on a parallel surface to the text APIs.
`%ALLM.ImageRequest{}` and `%ALLM.ImageResponse{}` mirror the
`Request`/`Response` shape; the engine has a separate `:image_adapter`
slot; and the entry points (`ALLM.generate_image/3`,
`ALLM.edit_image/4`, `ALLM.image_variations/3`) take the same engine
and return image responses.

This guide covers what each entry point does, the parallel adapter
slot, OpenAI vs Gemini coverage, and the `FakeImages` adapter for
deterministic testing.

## Three operations

| Operation | Function | What it does |
|---|---|---|
| Generate | `ALLM.generate_image/3` | Produces a new image from a text prompt |
| Edit (inpaint) | `ALLM.edit_image/4` | Modifies an existing image, optionally masked |
| Variations | `ALLM.image_variations/3` | Produces visual variations of an existing image |

Each returns `{:ok, %ALLM.ImageResponse{}}` with `:images` (list of
`%ALLM.Image{}`) and `:usage` (provider-reported counts).

## The image-adapter engine slot

An engine has two adapter slots: `:adapter` for chat and
`:image_adapter` for images. Set whichever you need:

```elixir
engine = ALLM.Engine.new(
  adapter: ALLM.Providers.OpenAI,             # for chat, optional here
  image_adapter: ALLM.Providers.OpenAI.Images,
  model: "dall-e-2"
)
```

The image model comes from the engine's `:model` field, or from a
per-call `model:` opt (`ALLM.generate_image(engine, prompt, model: "dall-e-3")`)
which overrides it.

If you only generate images (no chat), the `:adapter` slot can stay
unset.

## Generating an image

    iex> engine = ALLM.Engine.new(
    ...>   image_adapter: ALLM.Providers.FakeImages,
    ...>   adapter_opts: [
    ...>     image_script: [
    ...>       {:ok, [%ALLM.Image{source: {:bytes, <<137, 80, 78, 71>>}, mime_type: "image/png"}]}
    ...>     ]
    ...>   ]
    ...> )
    iex> {:ok, %ALLM.ImageResponse{images: [%ALLM.Image{} = img]}} =
    ...>   ALLM.generate_image(engine, "a watercolor kestrel")
    iex> img.mime_type
    "image/png"

`ALLM.generate_image/3` accepts opts:

* `:model` — override the engine's default.
* `:size` — `"512x512"`, `"1024x1024"`, or a `{w, h}` tuple. Provider
  capabilities differ; OpenAI's `dall-e-2` only supports `256×256`,
  `512×512`, and `1024×1024`.
* `:n` — number of images to generate.
* `:response_format` — `:url` (default for OpenAI 1.x) or `:b64_json`
  (default for newer models).

## Editing an image (inpaint)

`ALLM.edit_image/4` takes the engine, the base image, the prompt, and
optionally a mask:

```elixir
base = File.read!("base.png")
mask = File.read!("mask.png")  # white = paint here, transparent = keep

{:ok, response} = ALLM.edit_image(engine, base, "add a fountain", mask: mask)
```

The base and mask can be raw bytes, a file path
(`{:file, "/path/to/x.png"}`), or an `%ALLM.Image{}`.

## Variations

`ALLM.image_variations/3` produces visual variations of an existing
image — no prompt:

```elixir
{:ok, response} = ALLM.image_variations(engine, base_image, n: 3)
```

OpenAI is the only bundled provider with native variation support, on
`dall-e-2` at 256×256.

## Provider coverage

| Operation | OpenAI | Gemini |
|---|---|---|
| Generate (`generate_image/3`) | yes (`dall-e-2`, `dall-e-3`, `gpt-image-1`) | yes (`gemini-2.5-flash-image-preview`) |
| Edit (`edit_image/4`) | yes (`dall-e-2`, `gpt-image-1`) | yes |
| Variations (`image_variations/3`) | yes (`dall-e-2` only) | no |

Anthropic does not ship an image adapter — set `:image_adapter` to
OpenAI's or Gemini's even when your chat adapter is Anthropic.

## Materializing the result

A `%ALLM.Image{}` carries a `:source` (either `{:bytes, binary}` or
`{:url, string}`) and a `:mime_type`. To get raw bytes regardless of
source:

```elixir
{:ok, bytes} = ALLM.Image.to_binary(image)
```

This handles the URL fetch transparently if needed.

To write to disk:

```elixir
{:ok, bytes} = ALLM.Image.to_binary(image)
File.write!("output.png", bytes)
```

## Testing with `FakeImages`

`ALLM.Providers.FakeImages` is the canonical test vehicle for image
flows — same idea as `ALLM.Providers.Fake` for chat. Build a scripted
response and assert against it:

    iex> engine = ALLM.Engine.new(
    ...>   image_adapter: ALLM.Providers.FakeImages,
    ...>   adapter_opts: [
    ...>     image_script: [
    ...>       {:ok, [%ALLM.Image{source: {:bytes, <<137, 80, 78, 71, 0, 0>>}, mime_type: "image/png"}]}
    ...>     ]
    ...>   ]
    ...> )
    iex> {:ok, %ALLM.ImageResponse{images: images}} =
    ...>   ALLM.generate_image(engine, "anything")
    iex> length(images)
    1

Fake replies are deterministic, async-test-safe (per-process cursor),
and require no network or API key.

## Common patterns

### Generate + persist

```elixir
{:ok, %ALLM.ImageResponse{images: [image]}} =
  ALLM.generate_image(engine, prompt, size: "1024x1024")

{:ok, bytes} = ALLM.Image.to_binary(image)
File.write!(target_path, bytes)
```

### Edit with progress

`generate_image/3` and friends are non-streaming. Long generations
block until the provider returns the bytes. Set a longer timeout via
the engine's `:request_options` if needed.

### Multi-tenant key resolution

Image-adapter calls go through the same `ALLM.Keys` resolution chain as
chat calls. Pass `:api_key` per-call for BYOK SaaS:

```elixir
ALLM.generate_image(engine, prompt, api_key: tenant.openai_key)
```

## Where to next

* `vision.md` — sending images TO the model, vs generating new ones.
* `examples/10_generate_image.exs` — runnable smoke test.
* `examples/11_edit_image.exs` — inpaint with mask.
* `examples/13_image_variations.exs` — OpenAI-only variation flow.
