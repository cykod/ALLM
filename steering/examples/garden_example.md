# Replacing Garden's hand-built LLM code with ALLM

## Scope

Garden is split into an iOS app (`ui/gardenbox`) and an Elixir/Phoenix
backend (`server/`). The iOS client does not talk to an LLM directly —
it uploads seed packet photos and OCR text via GraphQL, and the server
calls OpenAI. So when we talk about replacing "gardenbox's" LLM code,
we're really talking about the Elixir service layer under
`garden/server/lib/garden/services/`, `config/`, `schemas/`,
`telemetry/`, and the pieces of `workers/` that orchestrate the call.

Today's integration is a well-structured but large hand-rolled stack:

| Concern                          | File                                                | LOC   |
|----------------------------------|-----------------------------------------------------|-------|
| Provider behaviour               | `services/llm_service.ex`                           | ~95   |
| OpenAI adapter                   | `services/openai_service.ex`                        | 238   |
| Config / API key management      | `config/llm_config.ex`                              | 112   |
| Error classification + backoff   | `services/error_handler.ex`                         | 276   |
| Telemetry events                 | `telemetry/processing_metrics.ex`                   | 311   |
| Structured-output schema         | `schemas/seed_packet_schema.ex`                     | 256   |
| Test mock                        | `test/support/llm_service_mock.ex`                  | 199   |
| Dependency: `openai_ex`          | `mix.exs`                                           | —     |

Most of what that code does — request shaping, key resolution, error
mapping, telemetry spans, provider swapping, test doubles — is already
in ALLM's core. The rest (seed-packet-specific schema and prompt)
becomes a thin caller module.

What follows is a concrete before/after walk-through of each layer,
followed by what ALLM unlocks that Garden can't easily do today
(streaming, multi-turn, tool calling, session persistence).

---

## 1. The behaviour layer: `LLMService`

### Before

`garden/server/lib/garden/services/llm_service.ex`

```elixir
defmodule Garden.Services.LLMService do
  @callback process_seed_packet(ocr_text, options) ::
              {:ok, seed_packet_data} | {:error, error_reason}

  def valid_input?(ocr_text) do
    is_binary(ocr_text) and String.trim(ocr_text) != ""
  end

  def normalize_options(opts) do
    opts
    |> Keyword.put_new(:timeout, 30_000)
    |> Keyword.put_new(:model,
         Application.get_env(:garden, :llm)[:openai_model] || "gpt-5-nano")
    |> Keyword.put_new(:max_retries,
         Application.get_env(:garden, :llm)[:openai_max_retries] || 3)
  end
end
```

The behaviour exists so `SeedPacketProcessor` can swap implementations
in tests via `Application.get_env(:garden, :llm_service, OpenAIService)`.

### After

Delete the module. `ALLM.Engine` already encapsulates
"which provider, with which defaults, running which tools" as a plain
value that can be injected per-call or built per-environment:

```elixir
# config/runtime.exs
config :garden, :llm_engine,
  ALLM.Engine.new(
    adapter: ALLM.Providers.OpenAI,
    model: "gpt-5-nano",
    params: %{temperature: 0.2},
    request_timeout: 30_000
  )

# config/test.exs
config :garden, :llm_engine,
  ALLM.Engine.new(
    adapter: ALLM.Providers.Fake,
    adapter_opts: [script: [{:text, ~s({"english_name":"Tomato"})},
                            {:finish, :stop}]]
  )
```

The processor just reads `Application.get_env(:garden, :llm_engine)`
and passes it to `ALLM.generate/3`. No behaviour definition, no
`normalize_options`, no "which implementation" indirection.

---

## 2. The OpenAI adapter: `OpenAIService`

This is the heaviest replacement. The current implementation is 238
lines covering: request building, system prompt, HTTP call via
`openai_ex`, JSON parse, per-error mapping, telemetry spans, and a
request-id generator.

### Before

`garden/server/lib/garden/services/openai_service.ex`

```elixir
def process_seed_packet(ocr_text, opts \\ []) do
  request_id = generate_request_id()
  start_time = System.monotonic_time(:millisecond)
  context = %{service: :openai_service, ...}

  ProcessingMetrics.emit_llm_request_start(request_id, context.metadata)

  try do
    with :ok <- validate_input(ocr_text),
         {:ok, request_params} <- build_request_params(ocr_text, opts),
         {:ok, response} <- call_openai_api(request_params, opts),
         {:ok, parsed_data} <- parse_response(response) do
      duration = System.monotonic_time(:millisecond) - start_time
      ProcessingMetrics.emit_llm_request_stop(request_id, duration, context.metadata)
      {:ok, parsed_data}
    else
      {:error, reason} ->
        duration = System.monotonic_time(:millisecond) - start_time
        ProcessingMetrics.emit_llm_request_exception(request_id, duration, :error, reason, context.metadata)
        categorized_error = categorize_openai_error(reason)
        ErrorHandler.handle_error(categorized_error, context)
        categorized_error
    end
  rescue
    exception -> ...
  end
end

defp build_request_params(ocr_text, opts) do
  {:ok, %{
    model: opts[:model] || "gpt-5-nano",
    messages: [%{role: "system", content: system_prompt()},
               %{role: "user",   content: ocr_text}],
    response_format: SeedPacketSchema.openai_format()
  }}
end

defp call_openai_api(request_params, opts) do
  timeout = opts[:timeout] || 60_000
  client  = client_with_timeout(timeout)
  chat    = OpenaiEx.Chat.Completions.new(request_params)
  OpenaiEx.Chat.Completions.create(client, chat)
end

defp parse_response(%{"choices" => [%{"message" => %{"content" => content}} | _]}) do
  Jason.decode(content)
end

defp categorize_openai_error(%{"error" => %{"code" => "rate_limit_exceeded"}}),
  do: {:error, :rate_limited}
defp categorize_openai_error(%{"error" => %{"code" => "invalid_api_key"}}),
  do: {:error, :invalid_api_key}
defp categorize_openai_error(%HTTPoison.Error{reason: :timeout}),
  do: {:error, :timeout}
# ... ~10 more clauses
```

### After

A single caller module around `ALLM.generate/3`. No telemetry
bookkeeping — ALLM emits `[:llm, :generate, :start|:stop|:exception]`
spans for free (spec §29). No manual error mapping — adapter errors
arrive as `{:error, {:adapter_error, term()}}` with the raw token
preserved in `finish_reason`/`metadata`:

```elixir
defmodule Garden.Services.SeedPacketExtractor do
  alias Garden.Schemas.SeedPacketSchema

  @system_prompt """
  All the text from a seed packet (both front and back) is provided, with
  each line separated by ` || `. Generate a seed_packet output using the
  provided schema, leaving elements as null if they are not visible on the
  packet.
  ...
  """

  def extract(ocr_text, opts \\ []) when is_binary(ocr_text) and ocr_text != "" do
    engine = Application.fetch_env!(:garden, :llm_engine)

    request =
      ALLM.request(
        [ALLM.system(@system_prompt), ALLM.user(ocr_text)],
        response_format: SeedPacketSchema.openai_format(),
        metadata: %{user_id: opts[:user_id]}
      )

    with {:ok, %ALLM.Response{output_text: content}} <- ALLM.generate(engine, request),
         {:ok, parsed} <- Jason.decode(content) do
      {:ok, parsed}
    end
  end

  def extract(_, _), do: {:error, :invalid_ocr_text}
end
```

What disappeared:

- `generate_request_id/0` → ALLM emits `request_id` on every
  telemetry event and on `ALLM.Response.request_id`.
- `ProcessingMetrics.emit_llm_request_*` calls → replaced by the
  built-in `[:llm, :generate, :start|:stop|:exception]` events, which
  include `:model`, `:engine`, `:request`, and `:response` in metadata.
- `client_with_timeout/1` and the whole `openai_ex` dependency → the
  adapter owns transport. Timeouts are configured on the engine.
- `categorize_openai_error/1` → the handful of categories that drive
  retry decisions (`:timeout`, `:rate_limited`, `:invalid_api_key`) are
  either returned by ALLM directly or live in one place in
  `ErrorHandler` (§5 of this doc).
- `parse_response/1` pattern-matching on OpenAI's `choices` shape →
  gone. ALLM normalizes to `ALLM.Response.output_text`.

---

## 3. Config and API keys: `LLMConfig`

### Before

`garden/server/lib/garden/config/llm_config.ex` — 112 lines that
mostly exist to read `Application.get_env/2`, validate the key starts
with `sk-`, and provide per-field defaults.

```elixir
def openai_api_key do
  case Application.get_env(:garden, :openai)[:api_key] do
    key when is_binary(key) and key != "" -> key
    _ -> nil
  end
end

def validate_config! do
  api_key = openai_api_key()
  cond do
    is_nil(api_key) -> raise "OPENAI_API_KEY environment variable is required"
    not String.starts_with?(api_key, "sk-") -> raise "OPENAI_API_KEY must start with 'sk-'"
    true -> :ok
  end
end
```

### After

Delete most of it. ALLM.Keys (spec §6.4) resolves in this order:

1. explicit per-call `api_key:` opt
2. `ALLM.Keys.put/2` in-process override
3. `config :llm, keys: %{openai: "..."}`
4. `OPENAI_API_KEY` env var
5. optional `.env` at project root

Garden's `config/runtime.exs` becomes:

```elixir
config :llm, keys: %{
  openai: System.fetch_env!("OPENAI_API_KEY")
}
```

The `validate_config!/0` sanity check collapses to a one-liner called
in `application.ex`:

```elixir
ALLM.Keys.fetch!(:openai)
```

Timeouts, model, retries are engine params, not bespoke config
accessors.

---

## 4. Structured output schema

`garden/server/lib/garden/schemas/seed_packet_schema.ex` stays almost
untouched — it's domain content, not infrastructure. The only change
is where it's plugged in:

```elixir
# Before
%{response_format: SeedPacketSchema.openai_format(), ...}
|> OpenaiEx.Chat.Completions.new()
|> OpenaiEx.Chat.Completions.create(client)

# After
ALLM.request(messages, response_format: SeedPacketSchema.openai_format())
|> then(&ALLM.generate(engine, &1))
```

If Garden adopts the optional `llm_db` dependency (spec §6.3), ALLM
will pre-flight the request and reject it with
`{:error, {:unsupported_capability, :json_native}}` *before* the
network call whenever the configured model can't do JSON schema — a
safety check Garden currently doesn't have.

---

## 5. Error handling and retries: `ErrorHandler`

This one is partial, not full, replacement. Garden's `ErrorHandler`
does three things:

1. Categorize errors as `:transient` / `:user_error` /
   `:configuration_error` to drive retry decisions.
2. Compute exponential backoff with jitter.
3. Scrub sensitive data (API keys, tokens) from error messages.

ALLM does **not** own retry policy — by design, retries are an
application-level concern (think: Oban's `max_attempts`, the caller's
circuit breaker, etc.). So ErrorHandler survives, but it shrinks:

- Categorization input changes from a mix of `HTTPoison.Error`,
  `{:error, :timeout}`, and `%{"error" => %{"code" => ...}}` to just
  the atoms ALLM returns: `:timeout`, `{:adapter_error, ...}`,
  `{:validation_error, ...}`, `{:unsupported_capability, ...}`.
- The sensitive-data scrubbing keeps all its value (logs, crash
  reports).
- The backoff math stays put.

The ~90 lines of `categorize_error/1` clauses that match provider
shapes can be deleted.

---

## 6. Telemetry: `ProcessingMetrics`

### Before

`garden/server/lib/garden/telemetry/processing_metrics.ex` defines
three LLM-specific events and attaches handlers for them:

```elixir
def emit_llm_request_start(request_id, metadata \\ %{}) do
  :telemetry.execute(
    [:garden, :llm, :request, :start],
    %{system_time: System.system_time()},
    Map.put(metadata, :request_id, request_id)
  )
end
# + emit_llm_request_stop/3 and emit_llm_request_exception/5
```

Every caller has to remember to wrap its work in start/stop/exception
and hand-construct metadata.

### After

Remove the three `emit_llm_request_*` functions and their call sites.
ALLM emits equivalent events natively (spec §29):

```elixir
[:llm, :generate, :start | :stop | :exception]
[:llm, :stream,   :start | :stop | :exception]
[:llm, :step,     :start | :stop]
[:llm, :chat,     :start | :stop]
[:llm, :tool,     :start | :stop | :exception]
```

Metadata on every span includes `:engine`, `:request_id`, `:model`,
plus `:request`/`:response`/`:step_result`/`:chat_result` depending on
the span. Garden just attaches the handlers it already has (for
logging, dashboards, etc.) to the `[:llm, ...]` namespace instead of
`[:garden, :llm, :request, ...]`.

Job-level events (`[:garden, :job, :start|:stop|:exception]`) stay —
those are Oban-level, not LLM-level.

---

## 7. Test mock: `LLMServiceMock`

### Before

`test/support/llm_service_mock.ex` — 199 lines of `Agent`-backed
pattern-matched responses keyed on OCR text ("timeout", "network",
"rate_limit", …) for different test scenarios. It also has to
re-emit the same telemetry events as the real service so metrics
tests pass.

### After

Use `ALLM.Providers.Fake` (spec §31). Scripts are deterministic and
map 1:1 to emitted events, so tests assert exact event sequences:

```elixir
# Happy path
engine =
  ALLM.Engine.new(
    adapter: ALLM.Providers.Fake,
    adapter_opts: [
      script: [
        {:text, ~s({"english_name":"Tomato","plant_type":"annual"})},
        {:finish, :stop}
      ]
    ]
  )

# Rate-limit path
engine_rate_limit =
  ALLM.Engine.new(
    adapter: ALLM.Providers.Fake,
    adapter_opts: [script: [{:error, {:adapter_error, :rate_limited}}]]
  )

# Timeout path
engine_timeout =
  ALLM.Engine.new(
    adapter: ALLM.Providers.Fake,
    adapter_opts: [script: [{:sleep, 35_000}, {:finish, :stop}]],
    request_timeout: 1_000
  )
```

The 199-line mock collapses to per-test engine construction.
Telemetry still fires because the Fake adapter runs through the same
`ALLM.Runner` that OpenAI does.

---

## 8. What ALLM unlocks that Garden can't cheaply do today

Beyond "same behavior with less code," swapping to ALLM opens four
capabilities the current hand-rolled stack doesn't have:

### 8.1 Streaming extraction into Absinthe subscriptions

Garden already has `EventBroadcaster` publishing seed-packet status
changes over Absinthe subscriptions, but the LLM call itself is a
single blocking round-trip — users see `pending → processing →
completed` as discrete states. With ALLM.stream/3 the partial
response can be broadcast as it arrives:

```elixir
{:ok, stream} = ALLM.stream_generate(engine, request)

Enum.each(stream, fn
  {:text_delta, %{delta: delta}} ->
    EventBroadcaster.broadcast_extraction_delta(seed_packet.id, delta)

  {:message_completed, %{message: msg}} ->
    Jason.decode!(msg.content) |> persist_seed_packet(seed_packet)

  _ -> :ok
end)
```

The front-end could render fields appearing one by one as the model
produces them — especially useful when `gpt-5-nano` is slow on dense
seed packets.

### 8.2 Tool calling for multi-step extraction + validation

The current prompt asks the model to pick `border_color`/`fill_color`
hex values. That's fragile — the model guesses, and `ensure_colors/1`
in `SeedPacketProcessor` is already second-guessing the output. With
tools, you expose `PlantColors.default_colors/2` as a callable
function:

```elixir
color_tool =
  ALLM.tool(
    name: "lookup_plant_colors",
    description: "Return canonical border/fill hex colors for a plant.",
    schema: %{
      type: "object",
      properties: %{
        plant_type: %{type: "string"},
        english_name: %{type: "string"}
      },
      required: ["plant_type", "english_name"]
    },
    handler: fn %{"plant_type" => t, "english_name" => n} ->
      {:ok, Garden.PlantColors.default_colors(t, n)}
    end
  )

engine = ALLM.Engine.put_tool(base_engine, color_tool)

{:ok, result} = ALLM.chat(engine, [ALLM.system(prompt), ALLM.user(ocr_text)])
```

ALLM orchestrates the "model calls tool → tool runs → result goes
back → model finalizes response" loop. Garden's `ensure_colors/1`
hack disappears.

A second candidate is an `lookup_usda_zone_for_plant/1` tool so the
model can verify its USDA zone guesses against a reference table
rather than hallucinating.

### 8.3 Stateful sessions for user correction flows

Today, if a user corrects an extracted seed packet in the iOS app
("no, this is `Solanum lycopersicum`, not `Solanum tuberosum`"), the
only option is to re-OCR or re-extract from scratch. With
`ALLM.Session`, the extraction conversation becomes a persisted value
keyed by seed packet:

```elixir
# First extraction
{:ok, session, _result} =
  ALLM.Session.start(engine,
    [ALLM.system(@system_prompt), ALLM.user(ocr_text)],
    id: "seed_packet:#{seed_packet.id}")

Garden.ChatStore.save!(session)

# User sends correction later
session = Garden.ChatStore.load!("seed_packet:#{seed_packet.id}")

{:ok, session, result} =
  ALLM.Session.reply(engine, session,
    "The latin name is Solanum lycopersicum, not tuberosum. Please redo the extraction with that constraint.")
```

Sessions are plain serializable structs (spec §5.7), so they fit a
new Ecto column on `SeedPacket` or a small `Garden.ChatStore`
GenServer+DB combo. The whole `:pending → :processing → :completed`
state machine in `SeedPacketProcessor` (~90 lines) can be replaced by
the session's own status: `:idle | :awaiting_user | :awaiting_tools |
:completed | :error`.

### 8.4 Provider hedging / swapping without rewriting

Garden's behaviour-based abstraction technically allows swapping to
Anthropic, but in practice nobody has written
`Garden.Services.AnthropicService` because it would mean
re-implementing 238 lines. With ALLM, adding Claude is literally one
line at engine construction:

```elixir
# OpenAI (current)
ALLM.Engine.new(adapter: ALLM.Providers.OpenAI, model: "gpt-5-nano")

# Claude
ALLM.Engine.new(adapter: ALLM.Providers.Anthropic, model: "claude-haiku-4-5")

# Or let the optional llm_db catalog pick by capability
ALLM.request(messages,
  select: [require: [json_native: true, tools: true],
           prefer: [:anthropic, :openai]])
```

Useful for A/B testing extraction quality, or for fallback when
OpenAI rate-limits.

---

## 9. Summary of the migration

| Module                                     | Before (LOC) | After (LOC) | Notes                                           |
|--------------------------------------------|--------------|-------------|-------------------------------------------------|
| `services/llm_service.ex`                  | ~95          | 0           | Engine replaces the behaviour.                  |
| `services/openai_service.ex`               | 238          | ~30         | Becomes `SeedPacketExtractor` wrapping ALLM.    |
| `config/llm_config.ex`                     | 112          | ~10         | ALLM.Keys + two config keys.                    |
| `services/error_handler.ex`                | 276          | ~150        | Keep scrub + backoff, drop provider matches.    |
| `telemetry/processing_metrics.ex` (LLM)    | ~80          | 0           | Built-in `[:llm, :generate, …]` spans.          |
| `test/support/llm_service_mock.ex`         | 199          | 0           | Per-test `ALLM.Providers.Fake` engines.         |
| `schemas/seed_packet_schema.ex`            | 256          | 256         | Unchanged — it's domain content.                |
| `workers/seed_packet_processor.ex`         | 489          | ~350        | LLM call is one line; status machine can shrink.|
| `mix.exs` deps: `openai_ex`, `httpoison`   | —            | removed     | ALLM ships with Req+Finch.                      |

Roughly **800+ lines of infrastructure code deleted** while gaining
streaming, tool calling, sessions, multi-provider support, and
deterministic scripted testing that Garden would otherwise have to
build itself.

The migration is also mechanically staged:

1. Add ALLM as a dep, build the engine, leave `OpenAIService` in place.
2. Port `SeedPacketProcessor`'s one LLM call site to `ALLM.generate/3`
   under a feature flag. Compare results against the old path in
   production for a week.
3. Delete `OpenAIService`, `LLMServiceMock`, the LLM half of
   `ProcessingMetrics`, and the provider-shape clauses in
   `ErrorHandler`.
4. Optional follow-ups (tools, streaming to subscriptions, sessions)
   become incremental features, not rewrites.
