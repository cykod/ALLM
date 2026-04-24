defmodule ALLM.StreamAdapter do
  @moduledoc """
  Streaming provider adapter contract. See spec §7.2.

  `stream/2` returns an `Enumerable.t()` of `ALLM.Event` values. The
  enumerable is lazy — no HTTP call fires until the caller starts
  reducing over it — and must be resource-safe: if the consumer halts
  early (`Stream.take/2`), the underlying HTTP request must be cancelled.

  ## HTTP transport guidance

  Use `Finch` directly with HTTP/1. `Req`'s SSE path does not cover every
  provider's chunking quirks, and HTTP/2 flow control breaks for request
  bodies larger than 64 KB (the same issue documented in `req_llm`).
  Engines may inject a custom Finch name via
  `adapter_opts: [finch_name: MyApp.Finch]`.

  Implementations should use `Stream.resource/3` (not `Stream.unfold/2`) —
  `resource/3` has an explicit `after_fun` which is the canonical place
  to cancel the `Finch` ref.

  ## Invariants

    1. The synchronous `{:error, _}` branch returns `%AdapterError{}` for
       pre-flight failures (missing key, invalid request shape, immediate
       HTTP error like 401 before the first event).
    2. The stream itself may terminate with either
       `{:error, %AdapterError{}}` (HTTP-shaped failure mid-response — the
       provider returned a 4xx/5xx after streaming started) or
       `{:error, %ALLM.Error.StreamError{}}` (transport-shaped failure —
       stream cancelled, timed out, malformed event). Both variants are
       emitted via the `ALLM.Event` `{:error, _}` tag per spec §8.
    3. The stream must be halt-safe: a consumer halt within 500 ms must
       cancel the `Finch` ref.
    4. `opts[:stream_timeout]` (time between consecutive events) is
       honored by the adapter; exceeding it emits a terminating
       `{:error, %AdapterError{reason: :timeout}}` event.
    5. Adapters emitting `{:raw_chunk, {:usage, _}}` events must pre-map
       provider-wire usage keys to `%ALLM.Usage{}` field names before
       emitting; see `ALLM.StreamCollector`'s usage-fold contract.
  """

  @doc """
  Open a streaming request against the provider.

  Returns `{:ok, enumerable}` on success (the enumerable is lazy — no HTTP
  call has fired yet) or `{:error, %ALLM.Error.AdapterError{}}` on
  pre-flight failure.

  ## Synchronous error reasons (same as `ALLM.Adapter.generate/2`)

  | Reason | HTTP status | Fires when |
  |--------|-------------|------------|
  | `:authentication_failed` | 401 | API key missing or invalid. |
  | `:rate_limited` | 429 | Provider quota exceeded; `:retry_after_ms` populated when `Retry-After` header is present. |
  | `:invalid_request` | 400 | Request shape rejected by provider. |
  | `:content_filter` | 400 (provider-specific) | Provider's content filter rejected the prompt. |
  | `:context_length_exceeded` | 400 | Request exceeded the model's context window. |
  | `:provider_unavailable` | 500, 502, 503, 504, 529 | Provider server-side failure, retryable. |
  | `:timeout` | — | Pre-flight request exceeded `opts[:request_timeout]`. |
  | `:network_error` | — | TCP/TLS/DNS failure before the first event. |
  | `:malformed_response` | — | Provider returned a non-SSE response body to the streaming endpoint. |
  | `:unsupported_feature` | — | Request combined features the adapter cannot express. |
  | `:unknown` | any | Catch-all for shapes the adapter cannot classify. |

  ## Mid-stream `{:error, _}` event reasons

  The enumerable may emit a terminating `{:error, _}` event carrying
  either an `%AdapterError{}` (HTTP-shaped) or a `%StreamError{}`
  (transport-shaped):

  | Struct type | Reason | Fires when |
  |-------------|--------|------------|
  | `AdapterError` | `:rate_limited` | Provider returned 429 after SSE began. |
  | `AdapterError` | `:provider_unavailable` | Provider returned 5xx after SSE began. |
  | `AdapterError` | `:content_filter` | Provider interrupted the stream with a content-filter signal. |
  | `AdapterError` | `:timeout` | `opts[:stream_timeout]` elapsed between events. |
  | `StreamError` | `:cancelled` | Consumer halted the stream early. |
  | `StreamError` | `:timeout` | Transport-level timeout between chunks (distinct from adapter-level request timeout). |
  | `StreamError` | `:malformed_event` | An SSE line could not be parsed. |
  | `StreamError` | `:adapter_error` | Wraps an underlying `%AdapterError{}` (see `:cause` field). |
  | `StreamError` | `:unknown` | Catch-all for transport failures the adapter cannot classify. |
  """
  @callback stream(ALLM.Request.t(), keyword()) ::
              {:ok, Enumerable.t()} | {:error, ALLM.Error.AdapterError.t()}
end
