# Multi-tenant keys (BYOK)

In a multi-tenant SaaS — every customer brings their own LLM API key —
the engine must NOT hold a key. Engines round-trip through ETF and
JSON, so a key on the engine becomes a key in your job queue, your
session store, your audit log. ALLM's resolution chain pushes
credentials to call time and lets you swap per request.

This guide covers `ALLM.Keys`'s five-level resolution chain, the
per-call `:api_key` opt, app config, environment variables, custom
resolvers, and the BYOK pattern in practice.

## Resolution order

When an adapter needs an API key, `ALLM.Keys.get/2` walks five
sources in priority order. The first that returns a value wins:

1. **Per-call** — `ALLM.generate(engine, request, api_key: "sk-...")`
2. **Engine `:keys` resolver** — function or map on the engine
3. **`ALLM.Keys.put/2` runtime store** — global Agent (use sparingly)
4. **Application config** — `config :allm, :keys, [openai: "sk-..."]`
5. **Environment variable** — provider-specific default

If none match, the adapter raises `ALLM.Error.AdapterError{reason: :authentication}`.

## Per-call (the BYOK primitive)

The highest-priority source is the per-call `:api_key` opt:

```elixir
engine = ALLM.Engine.new(adapter: ALLM.Providers.OpenAI, model: "gpt-4.1-mini")

{:ok, response} = ALLM.generate(engine, request, api_key: tenant.openai_key)
```

The engine itself never sees the key. Cache the engine, share it
across processes, persist it — the key flows in per request.

Available on every entry point: `generate/3`, `stream_generate/3`,
`step/3`, `stream_step/3`, `chat/3`, `stream/3`, `Session.start/3`,
`Session.reply/4`, `Session.continue/3`, `generate_image/3`,
`edit_image/4`, `image_variations/3`.

## Engine resolver

For static deployments where one engine maps to one provider with one
key, set the resolver at engine construction:

```elixir
engine = ALLM.Engine.new(
  adapter: ALLM.Providers.OpenAI,
  model: "gpt-4.1-mini",
  keys: %{openai: System.fetch_env!("OPENAI_API_KEY")}
)
```

Or with a function (re-evaluated per call — useful for rotating
credentials):

```elixir
engine = ALLM.Engine.new(
  adapter: ALLM.Providers.OpenAI,
  model: "gpt-4.1-mini",
  keys: fn :openai -> MyApp.Vault.fetch!(:openai_key) end
)
```

The resolver receives the provider's key tag (`:openai`, `:anthropic`,
`:gemini`, or whatever a custom adapter declares) and must return a
binary key.

## Application config

Library-wide defaults belong in `config/runtime.exs`:

```elixir
config :allm, :keys,
  openai: System.fetch_env!("OPENAI_API_KEY"),
  anthropic: System.fetch_env!("ANTHROPIC_API_KEY"),
  gemini: System.fetch_env!("GEMINI_API_KEY")
```

Single-tenant apps where all calls use the same key — this is the
shape you want. Multi-tenant apps should NOT use this; per-call
override is the right primitive.

## Environment variables

Each provider has a default env var:

* OpenAI → `OPENAI_API_KEY`
* Anthropic → `ANTHROPIC_API_KEY`
* Gemini → `GEMINI_API_KEY`

If nothing higher in the chain matches, `ALLM.Keys` reads the env var
at call time. Adequate for scripts and one-shot tools; insufficient for
production multi-tenant.

## Custom resolver behaviour

For non-trivial cases — Vault integration, dynamic key rotation,
per-tenant override on a shared engine — implement the
`ALLM.Keys.Resolver` behaviour:

```elixir
defmodule MyApp.LLMKeys do
  @behaviour ALLM.Keys.Resolver

  @impl true
  def fetch(:openai, _opts) do
    case Process.get(:current_tenant) do
      nil -> :error
      tenant -> {:ok, MyApp.Vault.openai_key(tenant)}
    end
  end

  def fetch(:anthropic, _opts), do: {:ok, System.fetch_env!("ANTHROPIC_API_KEY")}
end
```

Wire it on the engine:

```elixir
engine = ALLM.Engine.new(
  adapter: ALLM.Providers.OpenAI,
  model: "gpt-4.1-mini",
  keys: MyApp.LLMKeys
)
```

`fetch/2` returns `{:ok, binary}` on hit or `:error` to fall through to
the next chain link.

## The BYOK pattern in practice

A canonical multi-tenant SaaS using ALLM looks like this:

```elixir
defmodule MyApp.Chat do
  @engine ALLM.Engine.new(
    adapter: ALLM.Providers.OpenAI,
    model: "gpt-4.1-mini"
  )

  def ask(tenant_id, message) do
    tenant = MyApp.Tenants.get!(tenant_id)

    ALLM.chat(@engine, [ALLM.user(message)], api_key: tenant.openai_key)
  end
end
```

The engine is module-level (built once, cached in beam memory). The
key per call. Crashes won't leak keys to crash dumps; ETF dumps of the
engine won't carry credentials; logs won't accidentally print them.

## What NOT to do

```elixir
# DON'T put per-tenant keys on the engine.
engine = ALLM.Engine.new(
  adapter: ALLM.Providers.OpenAI,
  keys: %{openai: tenant.openai_key}  # leaks into ETF, JSON, crash dumps
)
```

```elixir
# DON'T use ALLM.Keys.put/2 for BYOK.
ALLM.Keys.put(:openai, tenant.openai_key)
# ^^ this is a globally-named Agent. Two concurrent requests for two
# different tenants race — request B reads request A's key.
```

`ALLM.Keys.put/2` is for development and single-tenant scripts. For
multi-tenant production, ALWAYS use the per-call opt or a custom
resolver.

## Verifying keys aren't on engines

ALLM's tests verify this invariant — if you persist an engine, no key
material appears in the binary. You can verify locally:

    iex> engine = ALLM.Engine.new(
    ...>   adapter: ALLM.Providers.Fake,
    ...>   adapter_opts: [script: [{:text, "ok"}, {:finish, :stop}]]
    ...> )
    iex> binary = :erlang.term_to_binary(engine)
    iex> String.contains?(inspect(binary), "sk-")
    false

(With Fake there's no key to leak. With a real provider, do the same
check after constructing the engine — there should be no key material
in the term.)

## Where to next

* `getting_started.md` — the quick install + first-call tour.
* `errors_and_retries.md` — `:authentication` reason and recovery.
* `examples/README.md` § "SaaS bring-your-own-key (BYOK)" — runnable
  pattern.
* `ALLM.Keys` module docs for the full API reference.
