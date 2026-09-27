# Errors and retries

ALLM exposes a small closed set of error structs (one per
failure-domain) and a configurable retry policy that handles transient
failures automatically on the calls that can safely be repeated. This
guide covers every error shape you might pattern-match on, which calls
retry, the retry-policy slot, and how to observe both via telemetry.

## The error modules

| Module | When it fires | Recovery |
|---|---|---|
| `ALLM.Error.AdapterError` | Chat provider HTTP / wire-protocol failure | Pattern-match on `:reason`; see the table below |
| `ALLM.Error.EngineError` | Engine misconfiguration: `:missing_adapter`, `:missing_stream_adapter`, `:missing_model`, `:missing_key`, `:unknown_tool`, `:invalid_engine`, `:unsupported_response_format`, or an empty capability slot (`:no_image_adapter`, `:no_embed_adapter`, `:no_moderation_adapter`, `:no_speech_adapter`, `:no_transcription_adapter`) | Fix engine construction or key setup; not retryable |
| `ALLM.Error.SessionError` | Session-state violation (`:session_in_error_state`, `:invalid_status_for_operation`, `:no_pending_tool_call`, `:unknown_tool_call_id`) | Pattern-match on `:reason` |
| `ALLM.Error.StreamError` | Stream-protocol failure (`:adapter_error`, `:cancelled`, `:timeout`, `:malformed_event`, `:unknown`) | Inspect `:cause` for `:adapter_error` |
| `ALLM.Error.ToolError` | Tool execution failed | See the `:on_tool_error` policy |
| `ALLM.Error.ValidationError` | Request validation failed pre-flight, e.g. `:invalid_request`, `:invalid_message`, `:invalid_tool`, `:unsupported_capability`, or a capability-specific reason (`:invalid_image_request`, `:invalid_embedding_request`, `:invalid_moderation_request`, `:invalid_speech_request`, `:invalid_transcription_request`) | Fix the request; not retryable. `:errors` lists the failing fields |
| `ALLM.Error.ImageAdapterError` | Image provider failure | Pattern-match on `:reason` |
| `ALLM.Error.EmbeddingAdapterError` | Embedding provider failure | Pattern-match on `:reason` |
| `ALLM.Error.ModerationAdapterError` | Moderation provider failure | Pattern-match on `:reason` |
| `ALLM.Error.SpeechAdapterError` | Text-to-speech provider failure | Pattern-match on `:reason` |
| `ALLM.Error.TranscriptionAdapterError` | Speech-to-text provider failure | Pattern-match on `:reason` |

Every error struct carries `:reason` (a closed atom set), `:message`
(human-readable), `:cause` (the underlying term, when there is one) and
`:metadata` (a map of extra context). Provider context lives in
top-level fields, not in `:metadata`:

* `:provider` — the provider atom, on the adapter-error family and on
  `EngineError` / `StreamError`.
* `:status` — the HTTP status, when there was one, on every
  `*AdapterError`.
* `:retry_after_ms` — the provider's `Retry-After` hint in
  milliseconds, on every `*AdapterError`.
* `:request_id` — the provider's request id, on `AdapterError` only.

## Adapter errors

`%ALLM.Error.AdapterError{}` is the chat-side error you'll encounter
most. Its closed `:reason` set:

| Reason | Meaning |
|---|---|
| `:rate_limited` | The provider sent a rate-limit signal (HTTP 429) |
| `:authentication_failed` | Credentials rejected (HTTP 401 / 403) |
| `:invalid_request` | The provider rejected the request shape (HTTP 400) |
| `:provider_unavailable` | Provider-side outage (HTTP 5xx, connection refused) |
| `:context_length_exceeded` | Prompt plus expected output exceeds the context window |
| `:content_filter` | The provider refused the content on policy grounds |
| `:timeout` | The request or stream timed out |
| `:network_error` | Transport-level failure (DNS, TCP, TLS) |
| `:malformed_response` | The provider returned a body ALLM could not parse |
| `:unsupported_feature` | The model or provider cannot express a requested feature |
| `:no_scripted_response` | A Fake adapter ran out of script; never produced by real providers |
| `:unknown` | Catch-all; the original term is kept in `:cause` |

The capability errors (`ImageAdapterError`, `EmbeddingAdapterError`,
`ModerationAdapterError`, `SpeechAdapterError`,
`TranscriptionAdapterError`) share most of this vocabulary —
`:rate_limited`, `:authentication_failed`, `:invalid_request`,
`:context_length_exceeded`, `:provider_unavailable`, `:timeout`,
`:network_error`, `:malformed_response`, `:unsupported_feature`,
`:unknown` — plus a few of their own, such as `:batch_too_large`
(embeddings, moderation) and `:unsupported_operation` (images). Each
module's docs list its full set.

## Which calls retry

Only calls that can be repeated without showing you anything twice are
retried:

* **Retried:** the capability façades — `ALLM.generate_image/3`,
  `ALLM.edit_image/4`, `ALLM.embed/3`, `ALLM.moderate/3`,
  `ALLM.synthesize/3` and `ALLM.transcribe/3`. They retry
  `:rate_limited`, `:provider_unavailable`, `:timeout` and
  `:network_error`; every other reason comes back immediately.
  `ALLM.embed/3` retries each batch chunk under its own budget.
* **Not retried:** the chat calls — `ALLM.generate/3`, `ALLM.step/3`,
  `ALLM.chat/3` and every `stream_*` variant, plus the `ALLM.Session`
  helpers built on them. They all run over the provider's streaming
  path, where partial output may already have reached you, so a failure
  is reported rather than replayed.
* **Not retried:** the streaming audio calls — `ALLM.stream_synthesize/3`,
  `ALLM.stream_synthesize_input/3` and `ALLM.stream_transcribe/3`.

For a chat call, a provider failure before the stream opens returns
`{:error, %ALLM.Error.AdapterError{}}` straight away; retry it yourself
if you want to.

A retried call is invisible from the call site when a later attempt
succeeds:

    iex> engine = ALLM.Engine.new(
    ...>   transcription_adapter: ALLM.Providers.FakeTranscription,
    ...>   adapter_opts: [transcription_script: [{:retry_until_call, 2}, {:ok, "second try"}]],
    ...>   retry: [base_delay_ms: 1, jitter_ms: 0]
    ...> )
    iex> {:ok, response} = ALLM.transcribe(engine, ALLM.Audio.from_binary("ID3...", "audio/mpeg"))
    iex> response.text
    "second try"

## The retry policy

Engines have a `:retry` slot (`:default | false | keyword`). The
default policy is a plain map returned by `ALLM.Retry.default_policy/0`
(there is no `%ALLM.Retry{}` struct — `ALLM.Retry` is a module of
functions):

```elixir
%{
  max_attempts: 3,
  base_delay_ms: 500,
  max_delay_ms: 30_000,
  retry_on: [429, 500, 502, 503, 504, :timeout],
  jitter_ms: 250,
  respect_retry_after: true
}
```

`retry_on` holds HTTP status codes (integers) and atoms, matched against
the failure via `ALLM.Retry.error_matches?/2`. The capability façades
append their four retryable reason atoms (`:rate_limited`,
`:provider_unavailable`, `:timeout`, `:network_error`) to this list at
call time, so you don't need to add them yourself.

Override per-engine by passing a keyword list under `:retry` — it is
shallow-merged over the default policy via `ALLM.Retry.materialize/1`:

```elixir
engine = ALLM.Engine.new(
  image_adapter: ALLM.Providers.OpenAI.Images,
  retry: [max_attempts: 5, base_delay_ms: 1_000]
)
```

Disable retries entirely with `retry: false`:

<!-- fence-check: skip — `image_adapter: ...` is an elision for the reader, not a literal argument -->
```elixir
engine = ALLM.Engine.new(image_adapter: ..., retry: false)
```

The retry helper applies exponential backoff with **additive** jitter:
attempt N waits `min(base_delay_ms * 2^(N-1), max_delay_ms)` plus a
random jitter in `[0, jitter_ms]` (never subtractive). When
`respect_retry_after: true` and the provider sent a `Retry-After`
header, that value (plus jitter) overrides the computed delay.

Some bundled adapters also keep a retry loop of their own inside their
non-streaming callbacks. That matters in two places: calling such an
adapter's `generate/2` directly (outside the façade) can retry, and a
`:timeout` on `ALLM.embed/3` or on synthesis with the OpenAI or
ElevenLabs speech adapters can cost up to nine attempts at the default
policy (three façade attempts, each running three adapter attempts),
against three for the other retryable reasons.

## Pattern-matching errors

    iex> engine = ALLM.Engine.new(
    ...>   adapter: ALLM.Providers.Fake,
    ...>   adapter_opts: [script: [{:preflight_error, :rate_limited, []}]]
    ...> )
    iex> {:error, %ALLM.Error.AdapterError{reason: reason}} =
    ...>   ALLM.generate(engine, ALLM.request([ALLM.user("hi")]))
    iex> reason
    :rate_limited

A **pre-flight** adapter error surfaces as `{:error, _}` at the call
site (above), and — being a chat call — is not retried. A
**mid-stream** error is different — it folds into the response; see
"Mid-stream errors fold into the response" below.

In application code:

<!-- fence-check: skip — `handle/1` stands in for an application function the reader supplies -->
```elixir
case ALLM.generate(engine, request) do
  {:ok, %ALLM.Response{finish_reason: :error, metadata: %{error: error}}} ->
    {:error, error}

  {:ok, response} ->
    handle(response)

  {:error, %ALLM.Error.AdapterError{reason: :rate_limited, retry_after_ms: ms}} ->
    {:retry_after, ms}

  {:error, %ALLM.Error.AdapterError{reason: :authentication_failed}} ->
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

    iex> engine = ALLM.Engine.new(
    ...>   adapter: ALLM.Providers.Fake,
    ...>   adapter_opts: [stream_script: [[{:text_delta, "par"}, {:error, :rate_limited}]]]
    ...> )
    iex> {:ok, response} = ALLM.generate(engine, ALLM.request([ALLM.user("hi")]))
    iex> {response.output_text, response.finish_reason, response.metadata.error.reason}
    {"par", :error, :rate_limited}

Why: the model may have already emitted partial text before the error,
and the response shape preserves that. **Pre-flight** errors (missing
adapter, invalid request, adapter-level pre-flight) still come back as
`{:error, _}` from the call. Only mid-stream errors fold. Code that
matches only `{:error, _}` will miss rate limits and content-filter
blocks that arrive mid-stream — check `finish_reason: :error` too.

The streaming variants surface the error as a `{:error, _}` event in
the stream — see `streaming.md`.

### Audio streams are the exception

The streaming audio calls do not fold. A `ALLM.stream_synthesize/3`,
`ALLM.stream_synthesize_input/3` or `ALLM.stream_transcribe/3` stream
that fails after it opened ends with a terminal `{:error, err}` event,
and `ALLM.AudioStream.collect_speech/1` /
`ALLM.AudioStream.collect_transcription/1` return `{:error, err}` — a
speech response has no finish reason, and half a clip is not a clip:

    iex> error = ALLM.Error.SpeechAdapterError.new(:provider_unavailable)
    iex> engine = ALLM.Engine.new(
    ...>   speech_adapter: ALLM.Providers.FakeSpeech,
    ...>   adapter_opts: [speech_script: [{:error, error}]]
    ...> )
    iex> {:ok, stream} = ALLM.stream_synthesize(engine, "Hello.")
    iex> {:error, error} = ALLM.AudioStream.collect_speech(stream)
    iex> {error.reason, error.metadata.bytes_received}
    {:provider_unavailable, 0}

What did arrive is described on the error's `:metadata`
(`bytes_received` for speech, `committed_text` for transcription), and a
failure raised by your own input enumerable is marked with
`metadata.cause: :input_raised` or `:input_crashed`; the
`ALLM.AudioStream` module docs have the details. Problems found before
the stream opens still return synchronously — for example
`{:error, %ALLM.Error.EngineError{reason: :missing_stream_adapter}}`
when the slot's adapter cannot stream.

## Tool errors

When a tool's executor returns `{:error, reason}`, the chat loop's
default behaviour is to feed the error back to the model. Override
with the `:on_tool_error` opt:

```elixir
ALLM.chat(engine, request, on_tool_error: :halt)
```

Legal values: `:continue` (default), `:halt`, or a function
`fn tool_call, error -> {:continue, replacement} | :halt end`, where
`replacement` is sent to the model as the tool result.

When `:halt` fires, the chat result has `halted_reason: :tool_error`
and the offending tool call + error live in the metadata.

## Telemetry

ALLM emits telemetry events for visibility into errors and retries
without coupling your observer to the call site. The ones most useful
here:

| Event | Measurements | Metadata |
|---|---|---|
| `[:allm, :adapter, :retry]` | `system_time` | the calling façade's metadata (e.g. `request_id`, `model`) + `attempt`, `delay_ms`, `reason` (the error being retried) |
| `[:allm, :generate \| :stream \| :step \| :chat, :stop]` | `duration`, `monotonic_time` | `request_id`, `engine`, `model` + the result (`response: nil` on `:stream`, which closes before the stream drains) |
| `[:allm, :<span>, :exception]` | `duration`, `monotonic_time` | start metadata + `kind`, `reason`, `stacktrace` |
| `[:allm, :tool, :start \| :stop \| :exception]` | `duration` on `:stop` | `tool`, `tool_call`, `engine`, `model`, `request_id`, + `result` on `:stop` |
| `[:allm, :image \| :embed \| :moderate \| :synthesize \| :transcribe, :stop]` | `duration` + per-capability counts | `request_id`, `engine`, `model`, `usage`, `response`, `error` |

`[:allm, :adapter, :retry]` fires once per retry, before the sleep —
so from the capability façades, never from a chat call. Attach a
handler:

```elixir
require Logger

:telemetry.attach(
  "allm-retries",
  [:allm, :adapter, :retry],
  fn _event, _measurements, %{reason: error, attempt: n}, _config ->
    Logger.warning("ALLM retry #{n}: #{inspect(error)}")
  end,
  nil
)
```

The full event surface, including the streaming-audio spans and
`[:allm, :audio, :first_chunk]`, lives on `ALLM.Telemetry`.

## Error-handling idioms

### Wrap calls with a domain Result

```elixir
defmodule MyApp.LLM do
  def ask(prompt) do
    case ALLM.generate(engine(), ALLM.request([ALLM.user(prompt)])) do
      {:ok, %ALLM.Response{finish_reason: :error, metadata: %{error: e}}} -> {:error, e.reason}
      {:ok, %ALLM.Response{output_text: text}} -> {:ok, text}
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

(Chat calls are not retried for you, so this is the place to decide
whether to try again. On the capability façades the same clause only
runs once the retry policy's attempts are used up.)

## Where to next

* `multi_tenant_keys.md` — credential-resolution failures.
* `streaming.md` — mid-stream error semantics.
* `tools.md` — `:on_tool_error` policy.
* `audio.md` — speech and transcription errors, and how a failed audio
  stream ends.
* `moderation.md` — moderation errors and batch limits.
* `embeddings.md` — embedding errors and per-chunk retries.
* `ALLM.Retry` and `ALLM.Telemetry` module docs for the full reference.
