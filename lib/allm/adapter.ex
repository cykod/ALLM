defmodule ALLM.Adapter do
  @moduledoc """
  Non-streaming provider adapter contract.

  Implementations take an `ALLM.Request` plus a keyword opts list (resolved
  via `ALLM.Engine.resolve_params/2` and `ALLM.Engine.resolve_tools/2` at the
  call site) and return either `{:ok, %ALLM.Response{}}` or
  `{:error, %ALLM.Error.AdapterError{}}`.

  ## Minimum impl skeleton

      defmodule MyProvider do
        @behaviour ALLM.Adapter

        @impl true
        def generate(%ALLM.Request{} = req, opts) do
          # 1. Resolve API key: ALLM.Keys.fetch!(:my_provider, opts)
          # 2. Translate request: build provider-specific HTTP body
          # 3. Fire HTTP via Req: Req.post(url, json: body, headers: ...)
          # 4. Translate response: return {:ok, %ALLM.Response{...}}
          # 5. Translate errors: {:error, %ALLM.Error.AdapterError{...}}
          {:ok, %ALLM.Response{}}
        end
      end

  ## HTTP transport guidance

  Use `Req` for non-streaming calls. Streaming belongs in
  `ALLM.StreamAdapter` and must be implemented on top of `Finch` directly
  (HTTP/1, not HTTP/2 — Req's SSE path does not cover every provider's
  chunking quirks, and HTTP/2 flow control breaks for request bodies
  larger than 64 KB).

  ## Invariants

    1. `generate/2` is synchronous: it returns only after the HTTP response
       has been read in full.
    2. `generate/2` never raises for HTTP-shaped failures. A 4xx/5xx
       response is converted to
       `{:error, %AdapterError{status: status, reason: <atom>}}`. Network
       failures (ECONNREFUSED, DNS, TLS) are converted to
       `{:error, %AdapterError{reason: :network_error}}`. Only programmer
       errors (invalid request shape reaching the adapter, which the
       validator should have caught) may raise.
    3. `generate/2` must honor `opts[:request_timeout]` if provided.
       Exceeding the timeout produces
       `{:error, %AdapterError{reason: :timeout}}`.
    4. `prepare_request/2` (optional) returns an unfired `Req.Request`
       configured exactly as `generate/2` would fire it. Callers may mutate
       the returned request before firing.
    5. `translate_options/2` (optional) takes the resolved opts keyword
       and the request, and returns a possibly-renamed keyword; providers
       use it to rename `:max_tokens` → `:max_completion_tokens`, etc. The
       default (when unimplemented) is identity — the caller uses
       `function_exported?(adapter, :translate_options, 2)` to decide
       whether to shim.
  """

  @doc """
  Execute a request against the provider synchronously.

  Returns `{:ok, %ALLM.Response{}}` on success, or
  `{:error, %ALLM.Error.AdapterError{}}` on every failure shape.

  ## Error reasons

  | Reason | HTTP status | Fires when |
  |--------|-------------|------------|
  | `:authentication_failed` | 401 | API key missing or invalid. |
  | `:rate_limited` | 429 | Provider quota exceeded; `:retry_after_ms` populated when `Retry-After` header is present. |
  | `:invalid_request` | 400 | Request shape rejected by provider (unsupported param, schema violation). |
  | `:content_filter` | 400 (provider-specific) | Provider's content filter rejected the prompt or response. |
  | `:context_length_exceeded` | 400 | Request exceeded the model's context window. |
  | `:provider_unavailable` | 500, 502, 503, 504, 529 | Provider server-side failure, retryable. |
  | `:timeout` | — | Request exceeded `opts[:request_timeout]`. |
  | `:network_error` | — | TCP/TLS/DNS failure. |
  | `:malformed_response` | — | Provider returned a 200 with an unparseable body. |
  | `:unsupported_feature` | — | Request combined features the adapter cannot express. |
  | `:unknown` | any | Catch-all for shapes the adapter cannot classify; callers should treat as non-retryable. |
  """
  @callback generate(ALLM.Request.t(), keyword()) ::
              {:ok, ALLM.Response.t()} | {:error, ALLM.Error.AdapterError.t()}

  @doc """
  Escape hatch: return a configured but unfired `Req.Request` that the
  caller can further customize (headers, retries, middleware) before
  firing.

  Optional. When unimplemented, callers must dispatch to `generate/2`
  directly.

  The error branch mirrors `generate/2`; see that callback's reason table.
  """
  @callback prepare_request(ALLM.Request.t(), keyword()) ::
              {:ok, Req.Request.t()} | {:error, ALLM.Error.AdapterError.t()}

  @doc """
  Rename or reshape engine-level params into the provider's API dialect
  (e.g., OpenAI's newer endpoints require `:max_completion_tokens` instead
  of `:max_tokens`; Anthropic uses `:system` as a top-level field rather
  than a system-role message).

  Optional. The default is identity — callers use
  `function_exported?(adapter, :translate_options, 2)` to decide whether
  to shim.
  """
  @callback translate_options(keyword(), ALLM.Request.t()) :: keyword()

  @optional_callbacks prepare_request: 2, translate_options: 2
end
