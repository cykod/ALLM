# Multi-tenant keys (BYOK)

In a multi-tenant SaaS — every customer brings their own LLM API key —
the engine must NOT hold a key. Engines round-trip through ETF and
JSON, so a key on the engine becomes a key in your job queue, your
session store, your audit log. `%ALLM.Engine{}` therefore has no key
field at all: ALLM resolves credentials at call time and lets you swap
them per request.

This guide covers `ALLM.Keys`'s resolution chain, the per-call
`:api_key` opt, app config, environment variables, the optional `.env`
fallback, and the BYOK pattern in practice.

## Resolution order

When an adapter needs an API key, it calls `ALLM.Keys.fetch!/2`, which
walks these sources in priority order. The first that yields a
non-empty string wins:

1. **Per-call** — `ALLM.generate(engine, request, api_key: "sk-...")`
2. **`ALLM.Keys.put/2` runtime store** — a global Agent (use sparingly)
3. **Application config** — `config :allm, :keys, openai: "sk-..."`
4. **Environment variable** — `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, …
5. **`.env` file** — consulted only when `config :allm, load_dotenv: true`
   (path from `config :allm, :dotenv_path`, default `.env` in the
   current working directory)

An empty string at any level counts as missing, so an exported-but-blank
`OPENAI_API_KEY=` falls through to the next source.

The per-call opt wins over everything else:

    iex> ALLM.Keys.get(:byok_guide_provider, api_key: "sk-tenant-a")
    {:ok, "sk-tenant-a", :opts}

If no source matches, `ALLM.Keys.fetch!/2` raises
`%ALLM.Error.EngineError{reason: :missing_key}`. Its
`metadata.checked_sources` lists the chain links that were walked
(`:dotenv` appears only when the `.env` fallback is enabled):

    iex> try do
    ...>   ALLM.Keys.fetch!(:byok_guide_provider)
    ...> rescue
    ...>   e in ALLM.Error.EngineError -> {e.reason, e.metadata.checked_sources}
    ...> end
    {:missing_key, [:opts, :runtime, :app_config, :env]}

This is a raise, not an `{:error, _}` tuple — a missing key is a
deployment bug, not a runtime condition to branch on. A key that *is*
found but rejected by the provider is different: that comes back as
`%ALLM.Error.AdapterError{reason: :authentication_failed}` (HTTP 401).

## Per-call (the BYOK primitive)

The highest-priority source is the per-call `:api_key` opt:

```elixir
engine = ALLM.Engine.new(adapter: ALLM.Providers.OpenAI, model: "gpt-4.1-mini")
request = ALLM.request([ALLM.user("Hello")])

{:ok, response} = ALLM.generate(engine, request, api_key: tenant.openai_key)
```

The engine itself never sees the key. Cache the engine, share it
across processes, persist it — the key flows in per request.

Available on every entry point:

* Chat — `generate/3`, `stream_generate/3`, `step/3`, `stream_step/3`,
  `chat/3`, `stream/3`
* Sessions — `Session.start/3`, `Session.stream_start/3`,
  `Session.reply/4`, `Session.stream_reply/4`, `Session.continue/4`
* Images — `generate_image/3`, `edit_image/4`
* Embeddings and moderation — `embed/3`, `moderate/3`
* Audio — `synthesize/3`, `stream_synthesize/3`,
  `stream_synthesize_input/3`, `transcribe/3`, `stream_transcribe/3`

## Resolving the tenant's key yourself

There is no key-resolver hook on the engine. When the key comes from a
vault, a tenant table, or a rotating secret, look it up in your own code
and pass it per call:

```elixir
defmodule MyApp.LLM do
  # Returns the tenant's key for the provider, or raises.
  def api_key!(tenant, :openai), do: MyApp.Vault.fetch!(tenant, :openai_key)
  def api_key!(tenant, :anthropic), do: MyApp.Vault.fetch!(tenant, :anthropic_key)

  def generate(engine, request, tenant) do
    ALLM.generate(engine, request, api_key: api_key!(tenant, :openai))
  end
end
```

Because the lookup runs on every call, rotation is free: the next call
picks up the new secret.

## Application config

Library-wide defaults belong in `config/runtime.exs`:

<!-- fence-check: skip — a `config/runtime.exs` snippet: `config/3` exists only inside a Mix config file -->
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

Each provider's key tag maps to an env var:

| Provider tag | Env var |
|---|---|
| `:openai` | `OPENAI_API_KEY` |
| `:anthropic` | `ANTHROPIC_API_KEY` |
| `:gemini` | `GEMINI_API_KEY` |
| `:voyage` | `VOYAGE_API_KEY` |
| `:elevenlabs` | `ELEVENLABS_API_KEY` |

Any tag without a fixed mapping follows the `<PROVIDER>_API_KEY`
convention (`ALLM.Keys.env_var_for/1` is the single source of truth), so
a custom adapter that calls `ALLM.Keys.fetch!(:acme, opts)` reads
`ACME_API_KEY`:

    iex> ALLM.Keys.env_var_for(:elevenlabs)
    "ELEVENLABS_API_KEY"

If nothing higher in the chain matches, `ALLM.Keys` reads the env var
at call time. Adequate for scripts and one-shot tools; insufficient for
production multi-tenant.

## The `.env` fallback

For local development, set `config :allm, load_dotenv: true` and ALLM
reads the same `<PROVIDER>_API_KEY` names from a `.env` file (default:
`.env` in the current working directory; override with
`config :allm, :dotenv_path`). The parser is deliberately small:
`KEY=VALUE`, `export KEY=VALUE`, `# comments`, blank lines, and
surrounding double quotes. No interpolation, multi-line values, or
escape sequences. Leave it off in production.

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
# DON'T use ALLM.Keys.put/2 for BYOK.
ALLM.Keys.put(:openai, tenant.openai_key)
# ^^ this is a globally-named Agent. Two concurrent requests for two
# different tenants race — request B reads request A's key.
```

`ALLM.Keys.put/2` is for development and single-tenant scripts. For
multi-tenant production, ALWAYS pass the key with the per-call
`:api_key` opt.

Don't smuggle keys onto the engine through `adapter_opts:` or
`metadata:` either — those fields serialize with the engine, which is
exactly what the per-call opt exists to avoid.

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
* `errors_and_retries.md` — the `:authentication_failed` reason (a key the
  provider rejected) and recovery.
* `examples/README.md` § "SaaS bring-your-own-key (BYOK)" — runnable
  pattern.
* `ALLM.Keys` module docs for the full API reference.
