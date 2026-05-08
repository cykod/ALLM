# Errors and retries

ALLM exposes a small closed set of error structs (one per
failure-domain) and a configurable retry policy that handles transient
transport-level failures automatically. This guide covers every error
shape you might pattern-match on, the retry-policy slot, the
retryable-reason set, and how to observe both via telemetry.

## The error modules

| Module | When it fires | Recovery |
|---|---|---|
| `ALLM.Error.AdapterError` | Provider HTTP / wire-protocol failure | Pattern-match on `:reason`; some are retryable |
| `ALLM.Error.EngineError` | Engine misconfiguration (missing adapter, invalid `mode:`) | Fix engine construction; not retryable |
| `ALLM.Error.SessionError` | Session-state violation (e.g. continue without pending tools) | Pattern-match on `:reason` |
| `ALLM.Error.StreamError` | Stream-protocol failure (malformed SSE, premature close) | Sometimes retryable |
| `ALLM.Error.ToolError` | Tool execution failed | See `:on_tool_error` policy |
| `ALLM.Error.ValidationError` | Request validation failed pre-flight | Fix request; not retryable |
| `ALLM.Error.ImageAdapterError` | Image provider HTTP / wire-protocol failure | Pattern-match on `:reason` |

Every error struct carries `:reason` (a closed atom set), `:message`
(human-readable), and `:metadata` (provider-specific context like
`:status_code`, `:request_id`, `:retry_after`).

## Adapter errors and retryable reasons

`%ALLM.Error.AdapterError{}` is the most common error you'll
encounter. The closed `:reason` set:

| Reason | Meaning | Retryable |
|---|---|---|
| `:rate_limited` | HTTP 429 | yes |
| `:overloaded` | HTTP 529 (Anthropic) or provider-specific overload | yes |
| `:server_error` | HTTP 5xx other than 503 | yes |
| `:service_unavailable` | HTTP 503 | yes |
| `:timeout` | TCP-level read timeout | yes |
| `:connection_closed` | TCP closed mid-stream | yes |
| `:invalid_request` | HTTP 400, malformed payload, model rejected param | no |
| `:authentication` | HTTP 401 | no |
| `:permission` | HTTP 403 | no |
| `:not_found` | HTTP 404 (model, endpoint) | no |
| `:content_filter` | Provider blocked output | no |
| `:unknown` | Catch-all | no |

The retryable set is the default `ALLM.Retry` policy's
`:retry_on_reasons` list.

## The retry policy

Engines have a `:retry_policy` slot. The default is
`ALLM.Retry.default_policy/0`:

```elixir
%ALLM.Retry{
  max_attempts: 3,
  base_delay_ms: 500,
  max_delay_ms: 8_000,
  jitter: 0.25,
  retry_on_reasons: [:rate_limited, :overloaded, :server_error,
                     :service_unavailable, :timeout, :connection_closed]
}
```

Override per-engine:

```elixir
engine = ALLM.Engine.new(
  adapter: ALLM.Providers.OpenAI,
  model: "gpt-4.1-mini",
  retry_policy: %ALLM.Retry{max_attempts: 5, base_delay_ms: 1_000, jitter: 0.5}
)
```

Disable retries entirely:

```elixir
engine = ALLM.Engine.new(adapter: ..., retry_policy: ALLM.Retry.none())
```

The retry helper applies exponential backoff with full jitter:
attempt N waits `min(base * 2^(N-1), max) * (1 - jitter ± jitter)`. A
`:retry_after` header (if the provider sent one) overrides the computed
delay.

## Pattern-matching errors

    iex> engine = ALLM.Engine.new(
    ...>   adapter: ALLM.Providers.Fake,
    ...>   adapter_opts: [script: [{:error, :rate_limited}]]
    ...> )
    iex> {:error, %ALLM.Error.AdapterError{reason: reason}} =
    ...>   ALLM.generate(engine, ALLM.request([ALLM.user("hi")]))
    iex> reason
    :rate_limited

In application code:

```elixir
case ALLM.generate(engine, request) do
  {:ok, response} ->
    handle(response)

  {:error, %ALLM.Error.AdapterError{reason: :rate_limited, metadata: %{retry_after: secs}}} ->
    {:retry_after, secs}

  {:error, %ALLM.Error.AdapterError{reason: :authentication}} ->
    {:error, :bad_credentials}

  {:error, %ALLM.Error.ValidationError{reason: reason}} ->
    {:error, {:bad_request, reason}}

  {:error, other} ->
    {:error, other}
end
```

## Mid-stream errors fold into the response

Streaming has one quirk worth knowing: a mid-stream provider error
(rate limit kicks in mid-completion, content filter trips, stream
closes early) does NOT surface as `{:error, _}` from
`generate/3`/`step/3`/`chat/3`. Instead the error folds into the
response:

```elixir
{:ok, %ALLM.Response{finish_reason: :error, metadata: %{error: error_struct}}} =
  ALLM.generate(engine, request)
```

Why: the model may have already emitted partial text before the error,
and the response shape preserves that. **Pre-flight** errors (missing
adapter, invalid request, adapter-level pre-flight) still come back as
`{:error, _}` from the call. Only mid-stream errors fold.

The streaming variants surface the error as a `{:error, _}` event in
the stream — see `streaming.md`.

## Tool errors

When a tool's executor returns `{:error, reason}`, the chat loop's
default behaviour is to feed the error back to the model. Override
with the `:on_tool_error` opt:

```elixir
ALLM.chat(engine, request, on_tool_error: :halt)
```

Legal values: `:continue` (default), `:halt`, or a function
`fn tool_call, error -> :continue | :halt end`.

When `:halt` fires, the chat result has `halted_reason: :tool_error`
and the offending tool call + error live in the metadata.

## Telemetry

ALLM emits telemetry events for visibility into errors and retries
without coupling your observer to the call site. Key events:

| Event | Measurements | Metadata |
|---|---|---|
| `[:allm, :adapter, :start]` | `system_time` | `engine_summary`, `request` |
| `[:allm, :adapter, :stop]` | `duration` | `engine_summary`, `response` |
| `[:allm, :adapter, :exception]` | `duration` | `kind`, `reason`, `stacktrace` |
| `[:allm, :adapter, :retry]` | `attempt`, `delay_ms` | `engine_summary`, `error`, `attempt`, `total_attempts` |
| `[:allm, :tool, :start]` | `system_time` | `tool_name`, `tool_call_id` |
| `[:allm, :tool, :stop]` | `duration` | `tool_name`, `result` |
| `[:allm, :stream, :event]` | `count` | `event_type` |

Attach a handler:

```elixir
:telemetry.attach(
  "allm-retries",
  [:allm, :adapter, :retry],
  fn _event, _measurements, %{error: error, attempt: n}, _config ->
    Logger.warning("ALLM retry #{n}: #{inspect(error.reason)}")
  end,
  nil
)
```

The full event surface lives on `ALLM.Telemetry`.

## Error-handling idioms

### Wrap calls with a domain Result

```elixir
defmodule MyApp.LLM do
  def ask(prompt) do
    case ALLM.generate(engine(), ALLM.request([ALLM.user(prompt)])) do
      {:ok, %ALLM.Response{output_text: text}} -> {:ok, text}
      {:ok, %ALLM.Response{finish_reason: :error, metadata: %{error: e}}} -> {:error, e.reason}
      {:error, %{reason: reason}} -> {:error, reason}
    end
  end
end
```

### Quietly degrade on transient failures

```elixir
case ALLM.generate(engine, request) do
  {:ok, response} -> response.output_text
  {:error, %ALLM.Error.AdapterError{reason: r}} when r in [:rate_limited, :timeout] ->
    "Sorry, I'm having trouble right now. Try again in a moment."
end
```

(`ALLM.Retry` already handles those reasons by default — this is for
the case where retries also exhausted.)

## Where to next

* `multi_tenant_keys.md` — credential-resolution failures.
* `streaming.md` — mid-stream error semantics.
* `tools.md` — `:on_tool_error` policy.
* `ALLM.Retry` and `ALLM.Telemetry` module docs for the full reference.
