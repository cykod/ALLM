defmodule ALLM.Providers.Anthropic do
  @moduledoc """
  Anthropic provider adapter — Layer B. See spec §6.4, §7.1, §20, §32.1.

  Phase 11.1 ships the non-streaming `ALLM.Adapter` callback set; Phase 11.2
  adds the `ALLM.StreamAdapter` callbacks; Phase 11.3 adds structured-output
  tool-forcing for both arms. This module implements:

    * `generate/2` — fires `POST https://api.anthropic.com/v1/messages` via
      `Req`, wrapped in `ALLM.Retry.run/3` with the Anthropic-specific
      `529 Overloaded` retryable status (Decision #2).
    * `prepare_request/2` — returns an unfired `%Req.Request{}` with the
      API key injected as `x-api-key` and the API version pinned via
      `anthropic-version: 2023-06-01` (Decision #9).
    * `translate_options/2` — identity (Decision #7). Anthropic accepts
      `:max_tokens` natively across all model generations.
    * `requires_structured_finalize?/1` — capability declaration consumed
      by `ALLM.Capability.preflight/2`. Always `false` because Anthropic
      uses tool-forcing (single-pass) for structured output rather than the
      OpenAI-style two-pass dance (Decision #13).

  ## System-message extraction (Decision #1)

  Anthropic's Messages API rejects `{role: "system", ...}` items inside
  `messages:`; the system prompt is a top-level `system:` parameter.
  `extract_system/1` partitions system-role messages out of the thread and
  concatenates their `content` strings with `\\n\\n`. The non-system
  messages flow through unchanged.

  ## Tool-choice translation (Decision #3)

  `to_anthropic_tool_choice/1` returns a sentinel-tagged result so the
  request-builder can decide whether to emit the field at all:

  | ALLM canonical | Returns | Wire effect |
  |----------------|---------|-------------|
  | `nil` / `:auto` | `{:omit}` | field omitted (Anthropic defaults to "auto" when tools present) |
  | `:none` | `{:set, %{type: "none"}}` | `tool_choice: %{type: "none"}` |
  | `:required` | `{:set, %{type: "any"}}` | `tool_choice: %{type: "any"}` (Anthropic's wording) |
  | `"<name>"` | `{:set, %{type: "tool", name: "<name>"}}` | passthrough |
  | `%{type: t, ...}` (`t in ~w(auto any none tool)`) | `{:set, m}` | passthrough verbatim |

  Note the rename `:required → "any"` — Anthropic uses different wording
  than OpenAI for the same semantic.

  ## Stop-reason normalization (total per spec §5.5)

  | Anthropic string | ALLM atom | Notes |
  |------------------|-----------|-------|
  | `"end_turn"` | `:stop` | Natural completion. |
  | `"max_tokens"` | `:length` | `max_tokens` reached. |
  | `"tool_use"` | `:tool_calls` | Tool-use content blocks emitted. |
  | `"stop_sequence"` | `:stop` | A `stop_sequences:` element matched. |
  | `"refusal"` | `:content_filter` | Anthropic policy block. |
  | `"pause_turn"` | `:other` | Long-running pause; raw preserved. |
  | anything else | `:other` | `raw_finish_reason` carries the raw string. |
  | `nil` | `nil` | Mid-stream `message_delta` pre-finish. |

  ## Retry contract (Decision #2)

  `generate/2` wraps the HTTP call in `ALLM.Retry.run(opts[:retry] || :default, …)`.
  The closure adds **`529 Overloaded`** (Anthropic-specific) to the retryable
  set on top of the spec §6.1 default `[429, 500, 502, 503, 504, :timeout]`.
  `Retry-After` honored when present. Streaming never retries (spec §6.1).

  ## Key resolution

  Keys never appear on the engine. `prepare_request/2` and `generate/2` call
  `ALLM.Keys.fetch!(:anthropic, opts)` at request-build time per spec §6.4.
  Per Decision #9, `prepare_request/2` raises
  `%ALLM.Error.EngineError{reason: :missing_key}` when no key resolver
  yields a value.

  ## Structured output via tool-forcing (§5.4 + Decision #4)

  When `request.response_format == %{type: :json_schema, name: n, schema: s,
  strict: b}`, `to_anthropic_request_body/1` injects a synthetic tool
  `%{"name" => "respond_with_json_<n>", "description" => "...",
  "input_schema" => s}` into the wire body's `tools:` array (appending to
  any user tools) AND sets `tool_choice: %{type: "tool", name:
  "respond_with_json_<n>"}` to force the model to call it. The response
  decoder (`from_anthropic_response/2`) calls `lift_structured_output/1`,
  which detects the synthetic call by name prefix
  (`"respond_with_json_"`), replaces `Response.output_text` with
  `Jason.encode!(tool_call.arguments)`, sets `finish_reason: :stop`,
  clears `tool_calls: []`, and stamps `metadata.structured_output_tool ==
  true` for observability. The streaming arm (`stream/2`) wraps its inner
  enumerable in `Stream.transform/3` so the same `lift_structured_output/1`
  helper runs on the accumulated state at completion — both arms produce
  byte-identical `%Response{}` shapes (Decision #5b, invariant 14).

  ### Streamed structured output — event shape

  When `response_format: %{type: :json_schema, ...}` is set, the streaming
  wrapper emits `:text_delta` events for partial JSON and a final
  `:text_completed` event before the terminal `:message_completed`. The
  synthetic `tool_use` round-trip is hidden from the consumer; this matches
  OpenAI's native `:json_schema` streaming behavior so consumers can write
  provider-neutral structured-output streaming code (pattern-match
  `:text_delta` events to display JSON character-by-character).

  Per Decision #5b: `:tool_call_*` events DO NOT fire on this path. The
  shared `lift_structured_output/1` ensures the collected `%Response{}` is
  byte-identical with the non-streaming arm: `output_text` carries the JSON,
  `finish_reason` is `:stop`, `tool_calls` is empty, and `metadata` carries
  `structured_output_tool: true` (invariant 14).

  `requires_structured_finalize?/1` is `false` because tool-forcing is
  single-pass — the OpenAI-style two-pass `structured_finalize` dance is
  unnecessary (Decision #13).

  ### Cross-provider byte-shape carve-out

  `output_text` from Anthropic's structured-output path is
  `Jason.encode!/1` of the parsed map — the bytes are re-encoded from a
  parsed map, so whitespace, key order, number formatting, and Unicode
  escape style may differ from OpenAI's `:json_schema` path (which
  preserves the model's literal output string). The semantic content is
  identical — `Jason.decode!/1` of either yields the same Elixir map.
  Consumers that hash, diff, or store `output_text` as a canonical "the
  model said exactly this" record across providers should canonicalize
  via `Jason.encode!/1` themselves.

  ### Synthetic-tool-name collision

  The synthetic tool's name is `"respond_with_json_<schema_name>"` — the
  schema name embeds the namespace marker. A collision is only possible
  when the user names a tool exactly identical (e.g., a user-defined
  `respond_with_json_person` tool plus `response_format:
  %{type: :json_schema, name: "person", ...}`). In that pathological case
  the body's `tools:` array contains both entries and the response
  decoder's `lift_structured_output/1` only fires when there is exactly
  one tool call whose name starts with the prefix; ambiguous multi-call
  responses surface unchanged (`finish_reason: :tool_calls`). Avoid the
  collision by renaming the user-defined tool.

  ### Multi-turn synthetic-tool de-injection

  After the first turn where the synthetic tool fires, the assistant
  message carries the synthetic `tool_use` call and the next turn's
  thread carries a `:tool` message with `tool_call_id` matching the
  synthetic id. `inject_structured_output_tool/2` detects this by
  scanning `request.messages` for a `:tool` message whose `tool_call_id`
  matches the synthetic prefix; when found, the synthetic injection is
  SKIPPED so user-defined tools remain callable on subsequent turns.

  ## Vision input (Phase 17.2)

  `[%ALLM.TextPart{}, %ALLM.ImagePart{}]` content lists translate to
  Anthropic's Messages-API content-block shape automatically. URL-source
  images flow through `source: %{type: "url", url: u}`; binary, base64,
  and file sources resolve to `source: %{type: "base64", media_type:
  mime, data: ...}`. `ImagePart.detail` is NOT supported by Anthropic and
  is dropped silently with a one-time `Logger.debug/1` per process
  (Decision #3). System messages remain text-only — an `%ImagePart{}` in
  a system role is hard-rejected as
  `%ValidationError{reason: :invalid_message}` before any HTTP call.
  Per-image MIME / 20 MB size validation runs in pre-flight via
  `ALLM.Providers.Support.ImageMime`.
  """

  @behaviour ALLM.Adapter
  @behaviour ALLM.StreamAdapter

  @base_url "https://api.anthropic.com/v1"
  @anthropic_version "2023-06-01"
  # Synthetic-tool name prefix for structured-output tool-forcing (§5.4 +
  # Phase 11 design Decision #4). The full name is
  # `"respond_with_json_<schema_name>"` so the schema name embeds in the
  # synthetic tool name; collisions are only possible when the user names a
  # tool exactly identical (a known footgun documented in the moduledoc).
  @structured_output_tool_prefix "respond_with_json_"

  # Default per-message receive timeout for streaming. Spec §7.2 + StreamAdapter
  # invariant 4. Tunable via opts[:stream_timeout].
  @default_stream_timeout 60_000

  alias ALLM.Error.AdapterError
  alias ALLM.Error.StreamError
  alias ALLM.Error.ValidationError
  alias ALLM.Event
  alias ALLM.Image
  alias ALLM.ImagePart
  alias ALLM.Keys
  alias ALLM.Message
  alias ALLM.Providers.Support.ImageMime
  alias ALLM.Providers.Support.SSE
  alias ALLM.Request
  alias ALLM.Response
  alias ALLM.Retry
  alias ALLM.TextPart
  alias ALLM.ToolCall
  alias ALLM.Usage

  require Logger

  # ---------------------------------------------------------------------------
  # Public API — Adapter callbacks
  # ---------------------------------------------------------------------------

  @impl ALLM.Adapter
  @doc """
  Identity translator — Anthropic accepts `:max_tokens` natively across all
  model generations (Decision #7). Reshape of system messages, tool_choice,
  and tools happens in the request-build helpers, not here.

  ## Examples

      iex> req = ALLM.Request.new([%ALLM.Message{role: :user, content: "x"}], model: "claude-sonnet-4-6")
      iex> ALLM.Providers.Anthropic.translate_options([max_tokens: 100, temperature: 0.7], req)
      [max_tokens: 100, temperature: 0.7]
  """
  @spec translate_options(keyword(), Request.t()) :: keyword()
  def translate_options(opts, %Request{}) when is_list(opts), do: opts

  @doc """
  Capability declaration consumed by `ALLM.Capability.preflight/2`
  (Decision #13).

  Always returns `false`. Anthropic's tool-forcing pattern (Phase 11.3) is
  single-pass — the OpenAI-style two-pass `structured_finalize` dance is
  unnecessary.

  ## Examples

      iex> req = ALLM.Request.new([%ALLM.Message{role: :user, content: "x"}])
      iex> ALLM.Providers.Anthropic.requires_structured_finalize?(req)
      false
  """
  @spec requires_structured_finalize?(Request.t()) :: false
  def requires_structured_finalize?(%Request{}), do: false

  @impl ALLM.Adapter
  @doc """
  Build an unfired `%Req.Request{}` with the resolved API key injected as
  `x-api-key: <key>` AND the API version pinned via
  `anthropic-version: 2023-06-01` (Decision #9).

  Per Decision #9: this function **raises**
  `%ALLM.Error.EngineError{reason: :missing_key}` when no key resolver
  yields a value (via `ALLM.Keys.fetch!/2`).

  ## Examples

      iex> ALLM.Keys.put(:anthropic, "sk-ant-doctest-prep")
      iex> req = ALLM.Request.new([%ALLM.Message{role: :user, content: "hi"}], model: "claude-sonnet-4-6")
      iex> {:ok, %Req.Request{} = http} = ALLM.Providers.Anthropic.prepare_request(req, [])
      iex> {Req.Request.get_header(http, "x-api-key"), Req.Request.get_header(http, "anthropic-version"), http.url.path}
      {["sk-ant-doctest-prep"], ["2023-06-01"], "/v1/messages"}
      iex> ALLM.Keys.delete(:anthropic)
      :ok
  """
  @spec prepare_request(Request.t(), keyword()) ::
          {:ok, Req.Request.t()} | {:error, AdapterError.t()}
  def prepare_request(%Request{} = request, opts) when is_list(opts) do
    api_key = Keys.fetch!(:anthropic, opts)
    body = to_anthropic_request_body(request)
    url = @base_url <> "/messages"

    req =
      Req.new(
        method: :post,
        url: url,
        headers: build_headers(api_key),
        json: body
      )
      |> maybe_apply_req_test_stub(opts)
      |> maybe_apply_request_timeout(opts)

    {:ok, req}
  end

  defp build_headers(api_key) do
    [
      {"x-api-key", api_key},
      {"anthropic-version", @anthropic_version},
      {"content-type", "application/json"}
    ]
  end

  defp maybe_apply_req_test_stub(req, opts) do
    case Keyword.get(opts, :adapter_opts, []) |> Keyword.get(:plug) do
      nil -> req
      plug -> Req.merge(req, plug: plug)
    end
  end

  defp maybe_apply_request_timeout(req, opts) do
    case Keyword.get(opts, :request_timeout) do
      nil -> req
      ms when is_integer(ms) and ms > 0 -> Req.merge(req, receive_timeout: ms)
    end
  end

  @impl ALLM.Adapter
  @doc """
  Execute a non-streaming Messages-API request synchronously.

  Wraps the HTTP call in `ALLM.Retry.run/3`. The closure adds
  `529 Overloaded` (Anthropic-specific — Decision #2) to the spec §6.1
  default retryable set `[429, 500, 502, 503, 504, :timeout]`. Returns
  `{:ok, %Response{}}` on 2xx success or `{:error, %AdapterError{}}` on
  every failure shape.

  ## Vision input (Phase 17.2)

  `[%ALLM.TextPart{}, %ALLM.ImagePart{}]` content lists translate to
  Anthropic's content-block wire shape automatically. URL-source images
  use `source: %{type: "url", url: u}`; base64/binary/file sources
  resolve to `source: %{type: "base64", media_type: mime, data: ...}`.

  > #### Note: `ImagePart.detail` is dropped {: .info}
  >
  > Anthropic's Messages API has no `detail` field. The translator drops
  > the value silently and emits a single `Logger.debug/1` per process
  > the first time an `ImagePart` with `detail: :auto | :low | :high`
  > flows through. The wire shape never carries detail (Decision #3).

  System messages remain text-only — an `%ImagePart{}` in a system role
  is hard-rejected as `%ValidationError{reason: :invalid_message}`
  before any HTTP call. Per-image MIME / 20 MB size validation runs in
  pre-flight via `ALLM.Providers.Support.ImageMime`.

  ## Examples

      iex> ALLM.Keys.put(:anthropic, "sk-ant-doctest-gen")
      iex> req = ALLM.Request.new([%ALLM.Message{role: :user, content: "x"}], model: "claude-sonnet-4-6")
      iex> {:error, %ALLM.Error.AdapterError{reason: :authentication_failed}} =
      ...>   ALLM.Providers.Anthropic.generate(req,
      ...>     retry: false,
      ...>     adapter_opts: [plug: fn conn ->
      ...>       conn
      ...>       |> Plug.Conn.put_resp_content_type("application/json")
      ...>       |> Plug.Conn.resp(401, ~s({"type":"error","error":{"type":"authentication_error","message":"bad"}}))
      ...>     end]
      ...>   )
      iex> ALLM.Keys.delete(:anthropic)
      :ok

      iex> # Vision pre-flight rejects an ImagePart in a system message.
      iex> img = ALLM.Image.from_url("https://example.com/x.png")
      iex> sys = %ALLM.Message{role: :system, content: [%ALLM.ImagePart{image: img}]}
      iex> req = ALLM.Request.new([sys, %ALLM.Message{role: :user, content: "hi"}], model: "claude-sonnet-4-6")
      iex> {:error, %ALLM.Error.ValidationError{reason: :invalid_message}} =
      ...>   ALLM.Providers.Anthropic.generate(req, api_key: "sk-x")
      iex> :ok
      :ok
  """
  @spec generate(Request.t(), keyword()) ::
          {:ok, Response.t()} | {:error, AdapterError.t() | ValidationError.t()}
  def generate(%Request{} = request, opts) when is_list(opts) do
    with :ok <- reject_image_in_system_messages(request),
         :ok <- ImageMime.validate_request(request, :anthropic) do
      do_generate(request, opts)
    end
  end

  defp do_generate(%Request{} = request, opts) do
    {:ok, %Req.Request{} = http_req} = prepare_request(request, opts)

    retry_policy = with_anthropic_retry_on(Keyword.get(opts, :retry, :default))
    telemetry_meta = build_retry_telemetry_meta(opts)

    retry_policy
    |> Retry.run(telemetry_meta, fn -> run_one_attempt(http_req, opts) end)
    |> unwrap_retry_token()
  end

  # Decision #2: ensure 529 is in the policy's retry_on set on top of the
  # spec §6.1 default `[429, 500, 502, 503, 504, :timeout]`. The closure-
  # returned `%AdapterError{reason: status_int_token}` is then
  # `error_matches?` against the widened set so 529 retries fire.
  defp with_anthropic_retry_on(false), do: false
  defp with_anthropic_retry_on(:default), do: with_anthropic_retry_on([])

  defp with_anthropic_retry_on(opts) when is_list(opts) do
    base = Retry.default_policy().retry_on
    requested = Keyword.get(opts, :retry_on, base)
    widened = Enum.uniq(requested ++ [529])
    Keyword.put(opts, :retry_on, widened)
  end

  defp with_anthropic_retry_on(other), do: other

  defp unwrap_retry_token({:ok, _} = ok), do: ok

  defp unwrap_retry_token(
         {:error, %AdapterError{metadata: %{final_error: %AdapterError{} = real}}}
       ),
       do: {:error, real}

  defp unwrap_retry_token({:error, _} = err), do: err

  defp run_one_attempt(http_req, opts) do
    case Req.request(http_req) do
      {:ok, %Req.Response{status: status, body: body}}
      when status in 200..299 ->
        decode_success_body(body, opts)

      {:ok, %Req.Response{status: status, body: body, headers: headers}} ->
        classify_http_error(status, body, headers)

      {:error, %{__struct__: Req.TransportError, reason: :timeout} = cause} ->
        timeout_err = AdapterError.new(:timeout, provider: :anthropic, cause: cause)

        {:retry, 0,
         struct(timeout_err,
           reason: :timeout,
           metadata: Map.put(timeout_err.metadata, :final_error, timeout_err)
         )}

      {:error, %{__struct__: Jason.DecodeError} = cause} ->
        {:error, malformed_error(cause)}

      {:error, exception} ->
        {:error,
         AdapterError.new(:network_error,
           provider: :anthropic,
           message: "transport failure: " <> Exception.message(exception),
           cause: exception
         )}
    end
  end

  defp decode_success_body(body, opts) when is_map(body) do
    {:ok, from_anthropic_response(body, opts)}
  end

  defp decode_success_body(other, _opts) do
    {:error, malformed_error({:unexpected_body_shape, other})}
  end

  defp malformed_error(cause) do
    AdapterError.new(:malformed_response,
      provider: :anthropic,
      message: "Anthropic returned a body that could not be decoded",
      cause: cause
    )
  end

  # 4xx/5xx classifier per the design's Error Contract table. Decision #2
  # adds 529 to the retryable set.
  defp classify_http_error(status, body, headers) do
    decoded = decode_error_body(body)
    classified = from_anthropic_error(status, decoded, headers)

    if classified.reason in [:rate_limited, :provider_unavailable, :timeout] do
      retry_token =
        struct(classified,
          reason: status,
          metadata: Map.put(classified.metadata, :final_error, classified)
        )

      {:retry, retry_after_ms(headers) || 0, retry_token}
    else
      {:error, classified}
    end
  end

  defp decode_error_body(body) when is_map(body), do: body
  defp decode_error_body(_), do: %{}

  @doc false
  @spec from_anthropic_error(non_neg_integer(), map(), Enumerable.t()) :: AdapterError.t()
  def from_anthropic_error(status, body, headers)
      when is_integer(status) and is_map(body) do
    error = Map.get(body, "error", %{})
    type = Map.get(error, "type")
    message = Map.get(error, "message", "Anthropic HTTP #{status}")

    {reason, retry_after} = classify_reason(status, type, message, retry_after_ms(headers))

    AdapterError.new(reason,
      provider: :anthropic,
      status: status,
      retry_after_ms: retry_after,
      message: message,
      metadata: %{anthropic_type: type}
    )
  end

  # Anthropic doc page (accessed 2026-04-26): error.type values include
  # `invalid_request_error`, `authentication_error`, `permission_error`,
  # `not_found_error`, `request_too_large`, `rate_limit_error`,
  # `api_error`, `overloaded_error`. The `prompt is too long` /
  # `max_tokens` markers appear inside `error.message` for 400s that
  # represent context-window-exceeded conditions.
  defp classify_reason(401, _type, _msg, _ra), do: {:authentication_failed, nil}
  defp classify_reason(403, _type, _msg, _ra), do: {:authentication_failed, nil}
  defp classify_reason(429, _type, _msg, ra), do: {:rate_limited, ra}
  defp classify_reason(413, _type, _msg, _ra), do: {:invalid_request, nil}

  defp classify_reason(400, _type, msg, _ra) when is_binary(msg) do
    if context_length_marker?(msg) do
      {:context_length_exceeded, nil}
    else
      {:invalid_request, nil}
    end
  end

  defp classify_reason(400, _type, _msg, _ra), do: {:invalid_request, nil}

  defp classify_reason(status, _type, _msg, ra) when status in [500, 502, 503, 504, 529],
    do: {:provider_unavailable, ra}

  defp classify_reason(_status, _type, _msg, _ra), do: {:unknown, nil}

  defp context_length_marker?(msg) do
    String.contains?(msg, "prompt is too long") or
      String.contains?(msg, "max_tokens") or
      String.contains?(msg, "context window") or
      String.contains?(msg, "context length")
  end

  defp retry_after_ms(headers) do
    case header_value(headers, "retry-after") do
      nil -> nil
      value -> parse_retry_after(value)
    end
  end

  defp header_value(headers, name) when is_map(headers) do
    case Map.get(headers, name) do
      nil -> nil
      value -> header_value_to_string(value)
    end
  end

  defp header_value(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn
      {k, v} when is_binary(k) ->
        if String.downcase(k) == name, do: header_value_to_string(v), else: nil

      _ ->
        nil
    end)
  end

  defp header_value_to_string([v | _]) when is_binary(v), do: v
  defp header_value_to_string(v) when is_binary(v), do: v

  defp parse_retry_after(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> seconds * 1_000
      _ -> nil
    end
  end

  defp build_retry_telemetry_meta(opts) do
    base = %{provider: :anthropic}

    case Keyword.get(opts, :request_id) do
      nil -> base
      value -> Map.put(base, :request_id, value)
    end
  end

  # ---------------------------------------------------------------------------
  # Request-body composition
  # ---------------------------------------------------------------------------

  @doc """
  Compose the JSON request body from a canonical `%Request{}`.

  Performs system-message extraction (Decision #1), message/tool/tool_choice
  translation, and structured-output synthetic-tool injection (Decision #4 —
  see `inject_structured_output_tool/2`).

  ## Examples

      iex> req = ALLM.Request.new(
      ...>   [%ALLM.Message{role: :system, content: "Be concise."},
      ...>    %ALLM.Message{role: :user, content: "Hi"}],
      ...>   model: "claude-sonnet-4-6", max_tokens: 256
      ...> )
      iex> body = ALLM.Providers.Anthropic.to_anthropic_request_body(req)
      iex> {body["model"], body["system"], length(body["messages"])}
      {"claude-sonnet-4-6", "Be concise.", 1}
  """
  @spec to_anthropic_request_body(Request.t()) :: map()
  def to_anthropic_request_body(%Request{} = request) do
    {system_text, non_system} = extract_system(request.messages)

    base = %{
      "model" => request.model,
      "messages" => to_anthropic_messages(non_system),
      "max_tokens" => request.max_tokens || 1024
    }

    base
    |> maybe_put_system(system_text)
    |> maybe_put("temperature", request.temperature)
    |> maybe_put_tools(request.tools)
    |> maybe_put_tool_choice(request.tool_choice, request.tools)
    |> Map.merge(stringify_options(request.options))
    |> then(&inject_structured_output_tool(request, &1))
  end

  defp maybe_put_system(map, nil), do: map
  defp maybe_put_system(map, text) when is_binary(text), do: Map.put(map, "system", text)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_tools(map, []), do: map

  defp maybe_put_tools(map, tools) when is_list(tools) do
    Map.put(map, "tools", to_anthropic_tools(tools))
  end

  defp maybe_put_tool_choice(map, choice, tools) do
    case to_anthropic_tool_choice(choice) do
      {:omit} ->
        map

      {:set, %{} = wire} ->
        # Defense-in-depth: a forced tool selection (`:required`,
        # `"<name>"`, `%{type: "tool", ...}`, `%{type: "any"}`) requires
        # at least one tool. The validator should have caught this
        # upstream; we re-check at the adapter boundary.
        if forced_choice?(wire) and tools == [] do
          raise ArgumentError,
                "tool_choice #{inspect(choice)} requires non-empty tools list"
        end

        Map.put(map, "tool_choice", wire)
    end
  end

  defp forced_choice?(%{"type" => t}) when t in ["any", "tool"], do: true
  defp forced_choice?(%{type: t}) when t in ["any", "tool"], do: true
  defp forced_choice?(_), do: false

  defp stringify_options(options) when is_map(options) do
    Map.new(options, fn {k, v} -> {to_string_key(k), v} end)
  end

  defp to_string_key(k) when is_atom(k), do: Atom.to_string(k)
  defp to_string_key(k) when is_binary(k), do: k

  @doc """
  Partition system-role messages out of `messages`. Returns
  `{system_text_or_nil, non_system_messages}` where `system_text` is the
  concatenation of all system-message contents joined with `"\\n\\n"`
  (Decision #1).

  ## Examples

      iex> ALLM.Providers.Anthropic.extract_system([%ALLM.Message{role: :user, content: "hi"}])
      {nil, [%ALLM.Message{role: :user, content: "hi"}]}

      iex> {sys, rest} = ALLM.Providers.Anthropic.extract_system([
      ...>   %ALLM.Message{role: :system, content: "be brief"},
      ...>   %ALLM.Message{role: :user, content: "hi"}
      ...> ])
      iex> {sys, length(rest)}
      {"be brief", 1}
  """
  @spec extract_system([Message.t()]) :: {String.t() | nil, [Message.t()]}
  def extract_system(messages) when is_list(messages) do
    {systems, others} = Enum.split_with(messages, &(&1.role == :system))

    case systems do
      [] -> {nil, others}
      _ -> {Enum.map_join(systems, "\n\n", &stringify_content(&1.content)), others}
    end
  end

  @doc """
  Map a list of canonical `%Message{}`s to Anthropic's wire shape.

  System messages must already be filtered out by `extract_system/1`;
  passing a system-role message here is a programmer error and is
  silently coerced to a `"user"` role for safety. Tool-result messages
  encode as `{role: "user", content: [{type: "tool_result", tool_use_id, content}]}`
  per Anthropic's documented round-trip shape.

  ## Examples

      iex> ALLM.Providers.Anthropic.to_anthropic_messages([
      ...>   %ALLM.Message{role: :user, content: "hi"}
      ...> ])
      [%{"role" => "user", "content" => "hi"}]
  """
  @spec to_anthropic_messages([Message.t()]) :: [map()]
  def to_anthropic_messages(messages) when is_list(messages) do
    Enum.map(messages, &to_anthropic_message/1)
  end

  defp to_anthropic_message(%Message{role: :tool, content: c, tool_call_id: tcid}) do
    %{
      "role" => "user",
      "content" => [
        %{
          "type" => "tool_result",
          "tool_use_id" => tcid,
          "content" => stringify_content(c)
        }
      ]
    }
  end

  defp to_anthropic_message(%Message{role: :assistant, content: c, metadata: meta}) do
    case Map.get(meta, :tool_calls) do
      nil ->
        %{"role" => "assistant", "content" => user_content(c)}

      [] ->
        %{"role" => "assistant", "content" => user_content(c)}

      calls ->
        # tool_use carries auxiliary blocks; combine with text-only base
        # by materializing list-shaped content to a single text block
        # (multimodal assistant input echoed to a model is rare; mirror
        # OpenAI's `assistant_content/2` text-flatten convention).
        base_text = stringify_content(c)

        text_block =
          case base_text do
            "" -> []
            text -> [%{"type" => "text", "text" => text}]
          end

        tool_blocks =
          Enum.map(calls, fn %ToolCall{id: id, name: name, arguments: args} ->
            %{"type" => "tool_use", "id" => id, "name" => name, "input" => args || %{}}
          end)

        %{"role" => "assistant", "content" => text_block ++ tool_blocks}
    end
  end

  defp to_anthropic_message(%Message{role: :user, content: c}) do
    %{"role" => "user", "content" => user_content(c)}
  end

  defp to_anthropic_message(%Message{role: :system, content: c}) do
    # Defensive: extract_system/1 should have removed these; surface a
    # safe shape rather than crash.
    %{"role" => "user", "content" => stringify_content(c)}
  end

  # Phase 17.2: user-side content emission.
  #   - binary  → forwarded verbatim (v0.2 backward-compat)
  #   - list with any %ImagePart{} → translated to content-block list
  #   - list with only %TextPart{} → flattened to joined text (preserves
  #     Phase 14.4 wire-shape: tests assert `content: "a\nb"`)
  defp user_content(c) when is_binary(c) or is_nil(c), do: stringify_content(c)

  defp user_content(parts) when is_list(parts) do
    if Enum.any?(parts, &match?(%ImagePart{}, &1)) do
      to_anthropic_content_blocks(parts)
    else
      stringify_content(parts)
    end
  end

  defp stringify_content(c) when is_binary(c), do: c
  defp stringify_content(nil), do: ""

  # Flatten a text-only content list (Phase 14.4 Decision #14(b)).
  # Image-bearing lists are routed through `to_anthropic_content_blocks/1`
  # by `user_content/1` BEFORE reaching this helper; tool/system role
  # messages always carry text or text-only lists.
  defp stringify_content(parts) when is_list(parts) do
    Enum.map_join(parts, "\n", &materialize_part/1)
  end

  defp materialize_part(%TextPart{text: t}), do: t
  # Defensive: ImagePart should be filtered upstream for tool/system
  # contexts; render to empty string rather than raising — text-only
  # contexts that accidentally see one degrade gracefully. This mirrors
  # the OpenAI adapter's Phase 17.1 contract — see retro 2026-04-30
  # finding 5 (the symmetry decision).
  defp materialize_part(%ImagePart{}), do: ""

  defp materialize_part(other) do
    raise ArgumentError,
          "stringify_content/1 expects a TextPart; got: #{inspect(other)}"
  end

  # Phase 17.2 — system-message ImagePart rejection (mirror of OpenAI's
  # Phase 17.1 helper; design Decision #7 Q1 lock-in). System messages
  # are text-only in v0.3; an ImagePart in a system role is a hard reject
  # before any other validation runs. See spec §35.6 Out-of-scope #2.
  @spec reject_image_in_system_messages(Request.t()) ::
          :ok | {:error, ValidationError.t()}
  defp reject_image_in_system_messages(%Request{messages: messages}) do
    errors =
      messages
      |> Enum.with_index()
      |> Enum.flat_map(fn {%Message{role: role, content: c}, idx} ->
        if role == :system and system_has_image_part?(c) do
          [{[:messages, idx, :content], :image_in_system_message}]
        else
          []
        end
      end)

    case errors do
      [] ->
        :ok

      list ->
        {:error,
         ValidationError.new(:invalid_message, list,
           message: "image content is not supported in system-role messages"
         )}
    end
  end

  defp system_has_image_part?(content) when is_list(content) do
    Enum.any?(content, &match?(%ImagePart{}, &1))
  end

  defp system_has_image_part?(_), do: false

  # Phase 17.2 — content-block translator (design §3.3). Routes
  # `[TextPart | ImagePart]` content lists to Anthropic's Messages-API
  # content-block shape:
  #
  #   * `TextPart`  → `%{"type" => "text", "text" => t}`
  #   * `ImagePart` with `{:url, _}`     → `source: {type: "url", url}`
  #   * `ImagePart` with `{:base64, _}`  → `source: {type: "base64", media_type, data}`
  #   * `ImagePart` with `{:binary, _}`  → encode64 → base64 source
  #   * `ImagePart` with `{:file, _}`    → to_binary + encode64 → base64 source
  #
  # `ImagePart.detail` is read but NOT emitted on the wire (Anthropic has
  # no `detail` field — Decision #3); a single `Logger.debug/1` per
  # process surfaces the drop.
  @spec to_anthropic_content_blocks([TextPart.t() | ImagePart.t()]) :: [map()]
  defp to_anthropic_content_blocks(parts) when is_list(parts) do
    Enum.map(parts, &part_to_block/1)
  end

  defp part_to_block(%TextPart{text: t}) do
    %{"type" => "text", "text" => t}
  end

  # URL fast-path: forward URL string under Anthropic's url-source shape.
  # Never call `to_binary/1` (returns `{:error, :remote_source}` for URL).
  defp part_to_block(%ImagePart{image: %Image{source: {:url, u}}, detail: d}) do
    detail_drop_check(d)
    %{"type" => "image", "source" => %{"type" => "url", "url" => u}}
  end

  defp part_to_block(%ImagePart{
         image: %Image{source: {:base64, s}, mime_type: mime},
         detail: d
       }) do
    detail_drop_check(d)

    %{
      "type" => "image",
      "source" => %{"type" => "base64", "media_type" => mime, "data" => s}
    }
  end

  defp part_to_block(%ImagePart{image: %Image{mime_type: mime} = img, detail: d}) do
    detail_drop_check(d)
    {:ok, bytes} = Image.to_binary(img)

    %{
      "type" => "image",
      "source" => %{
        "type" => "base64",
        "media_type" => mime,
        "data" => Base.encode64(bytes)
      }
    }
  end

  # Phase 17.2 Decision #3: ImagePart.detail is not supported by Anthropic.
  # When a non-nil detail is observed, fire a single deferred-form
  # `Logger.debug/1` per process and stash a flag in the process dict so
  # subsequent calls in the same process stay silent.
  defp detail_drop_check(nil), do: :ok

  defp detail_drop_check(_detail) do
    warn_detail_dropped_once()
    :ok
  end

  defp warn_detail_dropped_once do
    if !Process.get(:allm_anthropic_detail_warned, false) do
      Logger.debug(fn ->
        "ALLM.Providers.Anthropic: ImagePart.detail is not supported by Anthropic; dropping. " <>
          "This warning fires once per process."
      end)

      Process.put(:allm_anthropic_detail_warned, true)
    end

    :ok
  end

  @doc """
  Map a list of canonical `%ALLM.Tool{}`s to Anthropic's wire shape.

  Anthropic uses `input_schema` (not `parameters`) as the JSON-Schema field
  name.

  ## Examples

      iex> tool = ALLM.Tool.new(name: "get_weather", description: "weather", schema: %{"type" => "object"})
      iex> ALLM.Providers.Anthropic.to_anthropic_tools([tool])
      [%{"name" => "get_weather", "description" => "weather", "input_schema" => %{"type" => "object"}}]
  """
  @spec to_anthropic_tools([ALLM.Tool.t()]) :: [map()]
  def to_anthropic_tools(tools) when is_list(tools) do
    Enum.map(tools, fn %ALLM.Tool{name: n, description: d, schema: s} ->
      %{"name" => n, "description" => d, "input_schema" => s}
    end)
  end

  @doc """
  Translate an ALLM canonical `tool_choice` to Anthropic's sentinel-tagged
  wire shape per Decision #3.

  Returns `{:omit}` to skip the field entirely, or `{:set, map}` to inject it.

  | ALLM canonical | Returns |
  |----------------|---------|
  | `nil` / `:auto` | `{:omit}` |
  | `:none` | `{:set, %{type: "none"}}` |
  | `:required` | `{:set, %{type: "any"}}` (Anthropic's wording) |
  | `"<name>"` (string) | `{:set, %{type: "tool", name: "<name>"}}` |
  | `%{type: t, ...}` where `t in ~w(auto any none tool)` | `{:set, m}` (passthrough) |

  Raises `ArgumentError` on any other shape.

  ## Examples

      iex> ALLM.Providers.Anthropic.to_anthropic_tool_choice(nil)
      {:omit}

      iex> ALLM.Providers.Anthropic.to_anthropic_tool_choice(:auto)
      {:omit}

      iex> ALLM.Providers.Anthropic.to_anthropic_tool_choice(:none)
      {:set, %{"type" => "none"}}

      iex> ALLM.Providers.Anthropic.to_anthropic_tool_choice(:required)
      {:set, %{"type" => "any"}}

      iex> ALLM.Providers.Anthropic.to_anthropic_tool_choice("get_weather")
      {:set, %{"type" => "tool", "name" => "get_weather"}}
  """
  @spec to_anthropic_tool_choice(Request.tool_choice()) ::
          {:omit} | {:set, map()}
  def to_anthropic_tool_choice(nil), do: {:omit}
  def to_anthropic_tool_choice(:auto), do: {:omit}
  def to_anthropic_tool_choice(:none), do: {:set, %{"type" => "none"}}
  def to_anthropic_tool_choice(:required), do: {:set, %{"type" => "any"}}

  def to_anthropic_tool_choice(name) when is_binary(name) do
    {:set, %{"type" => "tool", "name" => name}}
  end

  def to_anthropic_tool_choice(%{"type" => t} = m) when t in ["auto", "any", "none", "tool"] do
    {:set, m}
  end

  def to_anthropic_tool_choice(%{type: t} = m) when t in ["auto", "any", "none", "tool"] do
    {:set, m}
  end

  def to_anthropic_tool_choice(other) do
    raise ArgumentError,
          "unsupported tool_choice for Anthropic: #{inspect(other)} " <>
            "(legal: nil, :auto, :none, :required, name string, %{type: \"auto|any|none|tool\"})"
  end

  @doc """
  Inject the synthetic structured-output tool when `request.response_format`
  is `%{type: :json_schema, ...}` (Phase 11 design Decision #4).

  Branches:

    * `nil` or `%{type: :json_object}` (or anything other than
      `:json_schema`) → returns `body` unchanged.
    * `%{type: :json_schema, name: n, schema: s, strict: _}` AND the
      request has NOT already produced a synthetic-tool result in a
      prior turn → injects a synthetic tool entry into `body["tools"]`
      (preserving any user tools — APPEND, not replace) AND sets
      `body["tool_choice"] = %{type: "tool", name:
      "respond_with_json_<n>"}` to force the model to call it.
    * `%{type: :json_schema, ...}` BUT a prior assistant turn already
      produced the synthetic tool's output (the request's `messages`
      contains a `:tool` message whose `tool_call_id` starts with the
      synthetic prefix `"respond_with_json_"`) → returns `body`
      unchanged so user-defined tools remain callable on subsequent
      turns. See moduledoc "Multi-turn synthetic-tool de-injection".

  ## Examples

      iex> body = %{"model" => "claude-sonnet-4-6"}
      iex> req = ALLM.Request.new([%ALLM.Message{role: :user, content: "x"}])
      iex> ALLM.Providers.Anthropic.inject_structured_output_tool(req, body)
      %{"model" => "claude-sonnet-4-6"}

      iex> rf = %{type: :json_schema, name: "person", schema: %{"type" => "object"}, strict: true}
      iex> req = ALLM.Request.new([%ALLM.Message{role: :user, content: "x"}], response_format: rf)
      iex> body = ALLM.Providers.Anthropic.inject_structured_output_tool(req, %{"tools" => []})
      iex> body["tool_choice"]
      %{type: "tool", name: "respond_with_json_person"}
  """
  @spec inject_structured_output_tool(Request.t(), map()) :: map()
  def inject_structured_output_tool(%Request{response_format: rf} = request, body) do
    case rf do
      %{type: :json_schema, name: name, schema: schema} when is_binary(name) ->
        if synthetic_already_called?(request.messages) do
          body
        else
          do_inject_structured_output_tool(body, name, schema)
        end

      _ ->
        body
    end
  end

  defp do_inject_structured_output_tool(body, name, schema) do
    tool_name = @structured_output_tool_prefix <> name

    synthetic_tool = %{
      "name" => tool_name,
      "description" => "Return the final result as a JSON object matching the schema.",
      "input_schema" => schema
    }

    existing_tools = Map.get(body, "tools", [])

    body
    |> Map.put("tools", existing_tools ++ [synthetic_tool])
    |> Map.put("tool_choice", %{type: "tool", name: tool_name})
  end

  # Detect a follow-up turn after the synthetic tool already fired by
  # scanning `messages` for any assistant message whose metadata carries a
  # tool_call with a name starting with @structured_output_tool_prefix.
  # Suppresses re-injection so user-defined tools remain callable per the
  # moduledoc "Multi-turn synthetic-tool de-injection" note.
  defp synthetic_already_called?(messages) when is_list(messages) do
    Enum.any?(messages, fn
      %Message{role: :assistant, metadata: %{tool_calls: calls}} when is_list(calls) ->
        Enum.any?(calls, fn
          %ToolCall{name: n} when is_binary(n) ->
            String.starts_with?(n, @structured_output_tool_prefix)

          _ ->
            false
        end)

      _ ->
        false
    end)
  end

  defp synthetic_already_called?(_), do: false

  @doc """
  Lift a synthetic structured-output tool call back to `Response.output_text`
  (Phase 11 design Decision #4).

  When the response's `tool_calls` list has exactly one entry whose `name`
  starts with `@structured_output_tool_prefix` ("respond_with_json_"):

    * `output_text` becomes `Jason.encode!(tool_call.arguments)` (the
      parsed input map; per Decision #6, `arguments` already carries the
      parsed map and `raw_arguments` carries the JSON string).
    * `finish_reason` is set to `:stop` (NOT `:tool_calls`).
    * `tool_calls` is cleared to `[]` — the synthetic call is consumed.
    * `metadata.structured_output_tool` is set to `true` for observability.
    * The assistant `message` is rewritten so its `content` carries the
      JSON-encoded text and its `metadata.tool_calls` is dropped.

  In every other shape (zero tool calls, multiple tool calls, single
  non-synthetic tool call) the response is returned unchanged.

  ## Examples

      iex> resp = %ALLM.Response{output_text: "hi", finish_reason: :stop}
      iex> ALLM.Providers.Anthropic.lift_structured_output(resp).output_text
      "hi"

      iex> tc = %ALLM.ToolCall{id: "toolu_x", name: "respond_with_json_person",
      ...>                     arguments: %{"name" => "Alice"}, raw_arguments: ~s({"name":"Alice"})}
      iex> resp = %ALLM.Response{tool_calls: [tc], finish_reason: :tool_calls,
      ...>                       message: %ALLM.Message{role: :assistant, content: ""}}
      iex> lifted = ALLM.Providers.Anthropic.lift_structured_output(resp)
      iex> {Jason.decode!(lifted.output_text), lifted.finish_reason, lifted.tool_calls}
      {%{"name" => "Alice"}, :stop, []}
  """
  @spec lift_structured_output(Response.t()) :: Response.t()
  def lift_structured_output(%Response{tool_calls: [tc]} = response) do
    if synthetic_tool_call?(tc) do
      do_lift(response, tc)
    else
      response
    end
  end

  def lift_structured_output(%Response{} = response), do: response

  defp synthetic_tool_call?(%ToolCall{name: name}) when is_binary(name) do
    String.starts_with?(name, @structured_output_tool_prefix)
  end

  defp synthetic_tool_call?(_), do: false

  defp do_lift(%Response{} = response, %ToolCall{arguments: args}) do
    encoded = Jason.encode!(args || %{})

    new_message =
      case response.message do
        %Message{} = msg ->
          %{msg | content: encoded, metadata: Map.delete(msg.metadata || %{}, :tool_calls)}

        nil ->
          %Message{role: :assistant, content: encoded, metadata: %{}}
      end

    %{
      response
      | output_text: encoded,
        finish_reason: :stop,
        tool_calls: [],
        message: new_message,
        metadata: Map.put(response.metadata || %{}, :structured_output_tool, true)
    }
  end

  # ---------------------------------------------------------------------------
  # Response decoding
  # ---------------------------------------------------------------------------

  @doc """
  Decode an Anthropic Messages-API response body to canonical `%Response{}`.

  Maps `stop_reason` per the table in the moduledoc; preserves the raw
  string on `Response.raw_finish_reason` for non-canonical values.
  Decodes `tool_use` content blocks to `%ToolCall{}` per Decision #6 —
  the `input` map maps to `arguments`, and `raw_arguments` is computed via
  `Jason.encode!/1` for OpenAI parity.

  ## Examples

      iex> body = %{
      ...>   "id" => "msg_test",
      ...>   "model" => "claude-sonnet-4-6",
      ...>   "content" => [%{"type" => "text", "text" => "hi"}],
      ...>   "stop_reason" => "end_turn",
      ...>   "usage" => %{"input_tokens" => 5, "output_tokens" => 1}
      ...> }
      iex> resp = ALLM.Providers.Anthropic.from_anthropic_response(body, [])
      iex> {resp.output_text, resp.finish_reason, resp.usage.input_tokens}
      {"hi", :stop, 5}
  """
  @spec from_anthropic_response(map(), keyword()) :: Response.t()
  def from_anthropic_response(%{} = body, _opts) do
    raw_stop = Map.get(body, "stop_reason")
    {finish_reason, raw_keep} = map_stop_reason(raw_stop)

    content_blocks = Map.get(body, "content", [])
    {output_text, tool_calls} = decode_content_blocks(content_blocks)

    message = %Message{
      role: :assistant,
      content: output_text || "",
      metadata: tool_calls_metadata(tool_calls)
    }

    response = %Response{
      id: Map.get(body, "id"),
      model: Map.get(body, "model"),
      message: message,
      output_text: output_text,
      tool_calls: tool_calls,
      finish_reason: finish_reason,
      raw_finish_reason: raw_keep,
      usage: decode_usage(Map.get(body, "usage", %{})),
      raw: body,
      metadata: %{}
    }

    lift_structured_output(response)
  end

  defp tool_calls_metadata([]), do: %{}
  defp tool_calls_metadata(tool_calls), do: %{tool_calls: tool_calls}

  # Per the moduledoc table; total over Anthropic's documented stop_reason
  # set plus an :other catch-all that preserves the raw string.
  @doc false
  @spec map_stop_reason(String.t() | nil) ::
          {Response.finish_reason() | nil, String.t() | nil}
  def map_stop_reason(nil), do: {nil, nil}
  def map_stop_reason("end_turn"), do: {:stop, nil}
  def map_stop_reason("max_tokens"), do: {:length, nil}
  def map_stop_reason("tool_use"), do: {:tool_calls, nil}
  def map_stop_reason("stop_sequence"), do: {:stop, "stop_sequence"}
  def map_stop_reason("refusal"), do: {:content_filter, "refusal"}
  def map_stop_reason("pause_turn"), do: {:other, "pause_turn"}
  def map_stop_reason(other) when is_binary(other), do: {:other, other}

  # Walk Anthropic's `content: [block, block, ...]` array, separating text
  # blocks (concatenated into output_text) from tool_use blocks (decoded to
  # %ToolCall{}). Per Decision #6, tool_use's `input` is a parsed map; we
  # populate `raw_arguments` via Jason.encode!/1 for OpenAI parity.
  defp decode_content_blocks(blocks) when is_list(blocks) do
    {text_parts, tool_calls} =
      Enum.reduce(blocks, {[], []}, fn block, {texts, calls} ->
        case block do
          %{"type" => "text", "text" => t} when is_binary(t) ->
            {texts ++ [t], calls}

          %{"type" => "tool_use", "id" => id, "name" => name} = tu ->
            input = Map.get(tu, "input", %{})

            tc =
              ToolCall.new(
                id: id,
                name: name,
                arguments: input,
                raw_arguments: Jason.encode!(input)
              )

            {texts, calls ++ [tc]}

          _other ->
            {texts, calls}
        end
      end)

    output_text =
      case text_parts do
        [] -> nil
        parts -> Enum.join(parts, "")
      end

    {output_text, tool_calls}
  end

  defp decode_content_blocks(_), do: {nil, []}

  defp decode_usage(%{} = usage) do
    %Usage{
      input_tokens: Map.get(usage, "input_tokens"),
      output_tokens: Map.get(usage, "output_tokens"),
      total_tokens: maybe_total(usage),
      cached_input_tokens: Map.get(usage, "cache_read_input_tokens"),
      extra:
        Map.drop(usage, [
          "input_tokens",
          "output_tokens",
          "cache_read_input_tokens"
        ])
    }
  end

  defp decode_usage(_), do: %Usage{}

  defp maybe_total(usage) do
    case {Map.get(usage, "input_tokens"), Map.get(usage, "output_tokens")} do
      {i, o} when is_integer(i) and is_integer(o) -> i + o
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # ALLM.StreamAdapter — stream/2
  # ---------------------------------------------------------------------------

  @doc """
  Open a streaming Messages-API request against the Anthropic provider.

  Returns `{:ok, lazy_stream}` on success — no HTTP call fires until the
  consumer reduces over the stream. Pre-flight failures (missing key,
  invalid request shape, request-build raises) surface as `{:error,
  %AdapterError{}}` synchronously.

  Per CLAUDE.md and spec §10.1, mid-stream failures (HTTP 4xx/5xx after
  Finch successfully retrieves headers, transport drops, malformed events)
  emit a terminal `{:error, _}` event INSIDE the stream — the call-site
  tuple stays `{:ok, stream}` and `ALLM.StreamCollector` folds the error
  into `Response.finish_reason: :error`. Streaming never retries
  (spec §6.1 + Phase 11 design Decision #14).

  ## Anthropic SSE event mapping (Decision #14)

  Anthropic uses NAMED SSE events (`event: message_start\\ndata: {...}`).
  The `ALLM.Providers.Support.SSE` decoder carries the `event:` field
  through verbatim so this adapter switches on `sse_msg.event`:

  | Anthropic event | ALLM events emitted |
  |-----------------|----------------------|
  | `message_start` | `:message_started` |
  | `content_block_start` (text) | none — wait for `text_delta` |
  | `content_block_start` (tool_use) | `:tool_call_started` |
  | `content_block_start` (thinking) | `{:raw_chunk, {:thinking_start, _}}` (Decision #8) |
  | `content_block_delta` (text_delta) | `:text_delta` |
  | `content_block_delta` (input_json_delta) | `:tool_call_delta` |
  | `content_block_delta` (thinking_delta) | `{:raw_chunk, {:thinking_delta, _}}` (Decision #8) |
  | `content_block_stop` (text) | `:text_completed` |
  | `content_block_stop` (tool_use) | `:tool_call_completed` (parsed args) |
  | `message_delta` | `{:raw_chunk, {:usage, _}}` if usage present; stores stop_reason |
  | `message_stop` | synthetic `:message_completed` |
  | `ping` | dropped silently |
  | unknown | `{:raw_chunk, {:unknown_event, name, data}}` (forward-compat) |

  ## Options

    * `:stream_timeout` — milliseconds to wait between consecutive Finch
      messages (default `#{@default_stream_timeout}`). Exceeding emits
      a terminal `{:error, %AdapterError{reason: :timeout}}` event.
    * `:finch_module` — overrides `Finch` (test seam — see
      `ALLM.Test.FinchStub`).
    * `:finch_name` — name of the Finch supervisor child (default
      `ALLM.Finch`, started by `ALLM.Application` with `protocol: :http1`).

  ## Examples

      iex> ALLM.Keys.put(:anthropic, "sk-ant-doctest-stream")
      iex> req = ALLM.Request.new([%ALLM.Message{role: :user, content: "x"}], model: "claude-sonnet-4-6")
      iex> {:ok, stream} = ALLM.Providers.Anthropic.stream(req, [])
      iex> Enumerable.impl_for(stream) != nil
      true
      iex> ALLM.Keys.delete(:anthropic)
      :ok
  """
  @impl ALLM.StreamAdapter
  @spec stream(Request.t(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, AdapterError.t() | ValidationError.t()}
  def stream(%Request{} = request, opts) when is_list(opts) do
    with :ok <- reject_image_in_system_messages(request),
         :ok <- ImageMime.validate_request(request, :anthropic) do
      do_stream(request, opts)
    end
  end

  defp do_stream(%Request{} = request, opts) do
    # Pre-flight key resolution. Keys.fetch!/2 raises %EngineError{} on
    # missing key — same Decision #9 contract as prepare_request/2.
    api_key = Keys.fetch!(:anthropic, opts)
    body = request |> to_anthropic_request_body() |> Map.put("stream", true)
    json_body = Jason.encode!(body)
    headers = build_headers(api_key)
    url = @base_url <> "/messages"

    finch_request = Finch.build(:post, url, headers, json_body)

    finch_module = Keyword.get(opts, :finch_module, Finch)
    finch_name = Keyword.get(opts, :finch_name, ALLM.Finch)
    finch_extra_opts = Keyword.take(opts, [:finch_stub_ref])
    stream_timeout = Keyword.get(opts, :stream_timeout, @default_stream_timeout)

    enumerable =
      Stream.resource(
        fn -> stream_start_fun(finch_request, finch_module, finch_name, finch_extra_opts) end,
        fn state -> stream_next_fun(state, stream_timeout) end,
        fn state -> stream_after_fun(state, finch_module) end
      )

    {:ok, maybe_wrap_structured_output(enumerable, request)}
  end

  # Decision #5b: only wrap when response_format is :json_schema (zero
  # overhead for non-structured paths). The wrapper rewrites the synthetic
  # tool's stream into a text-stream so `StreamCollector.to_response/1`
  # produces a clean `%Response{}` matching the non-streaming arm's lift.
  defp maybe_wrap_structured_output(enumerable, %Request{response_format: rf}) do
    case rf do
      %{type: :json_schema, name: name} when is_binary(name) ->
        wrap_structured_output(enumerable, name)

      _ ->
        enumerable
    end
  end

  defp wrap_structured_output(enumerable, schema_name) do
    synthetic_name = @structured_output_tool_prefix <> schema_name

    Stream.transform(
      enumerable,
      fn -> %{synthetic_id: nil, synthetic_name: synthetic_name, raw_args: ""} end,
      &transform_event/2,
      fn _acc -> :ok end
    )
  end

  # Per-event transform: rewrites the synthetic tool's lifecycle events
  # into a clean text-stream and rewrites the terminal `:message_completed`
  # by running `lift_structured_output/1` on a synthesized in-flight
  # `%Response{}`. Non-synthetic events pass through unchanged.
  defp transform_event({:tool_call_started, %{id: id, name: name}} = event, acc) do
    if name == acc.synthetic_name do
      {[], %{acc | synthetic_id: id, raw_args: ""}}
    else
      {[event], acc}
    end
  end

  defp transform_event(
         {:tool_call_delta, %{id: id, arguments_delta: delta}} = event,
         acc
       ) do
    if id == acc.synthetic_id and is_binary(delta) do
      new_acc = %{acc | raw_args: acc.raw_args <> delta}
      {[{:text_delta, %{id: nil, delta: delta}}], new_acc}
    else
      {[event], acc}
    end
  end

  defp transform_event(
         {:tool_call_completed, %{id: id, arguments: args, raw_arguments: raw}} = event,
         acc
       ) do
    if id == acc.synthetic_id do
      # Use the parsed args re-encoded so the on-the-wire text matches
      # what `lift_structured_output/1` will produce for the non-streaming
      # arm (Jason.encode!/1 of the parsed map). Falls back to the raw
      # accumulated JSON when `args` is empty/unparseable.
      text = if is_map(args) and map_size(args) > 0, do: Jason.encode!(args), else: raw
      {[{:text_completed, %{id: nil, text: text}}], acc}
    else
      {[event], acc}
    end
  end

  defp transform_event({:message_completed, payload}, acc) when acc.synthetic_id != nil do
    args =
      case Jason.decode(acc.raw_args) do
        {:ok, %{} = parsed} -> parsed
        _ -> %{}
      end

    encoded = Jason.encode!(args)

    base_msg =
      case payload do
        %{message: %Message{} = m} -> m
        _ -> %Message{role: :assistant, content: "", metadata: %{}}
      end

    new_msg = %{
      base_msg
      | content: encoded,
        metadata: Map.delete(base_msg.metadata || %{}, :tool_calls)
    }

    new_payload =
      payload
      |> Map.put(:message, new_msg)
      |> Map.put(:finish_reason, :stop)
      |> Map.update(
        :metadata,
        %{structured_output_tool: true},
        &Map.put(&1 || %{}, :structured_output_tool, true)
      )

    {[{:message_completed, new_payload}], acc}
  end

  defp transform_event(event, acc), do: {[event], acc}

  defp stream_start_fun(finch_request, finch_module, finch_name, finch_extra_opts) do
    ref = finch_module.async_request(finch_request, finch_name, finch_extra_opts)

    %{
      ref: ref,
      finch_module: finch_module,
      sse_acc: SSE.new(),
      buffered: [],
      status: nil,
      done: false,
      # Per-content-block accumulators keyed by integer index. Each value
      # is %{type: :text | :tool_use | :thinking, ...accumulator fields}.
      content_blocks: %{},
      message_id: nil,
      message_started_emitted?: false,
      message_completed_emitted?: false,
      accumulated_text: "",
      finish_reason: nil,
      raw_finish_reason: nil
    }
  end

  # next_fun: drain buffered events first; then pull one Finch message.
  # On terminal events we set state.done = true so after_fun skips cancel.
  defp stream_next_fun(%{buffered: [event | rest]} = state, _timeout) do
    {[event], %{state | buffered: rest}}
  end

  defp stream_next_fun(%{done: true} = state, _timeout), do: {:halt, state}

  defp stream_next_fun(%{ref: ref} = state, timeout) do
    receive do
      {^ref, payload} -> handle_finch_payload(state, payload)
    after
      timeout ->
        finalize_with_error(state, :timeout, "stream_timeout exceeded between events")
    end
  end

  # Handle one Finch payload. Status / headers gate the rest of the
  # stream — non-2xx terminates with an AdapterError event.
  defp handle_finch_payload(state, {:status, code}) when code in 200..299 do
    {[], %{state | status: code}}
  end

  defp handle_finch_payload(state, {:status, code}) when is_integer(code) and code >= 400 do
    err = from_anthropic_error(code, %{}, [])
    finalize_with_event(state, {:error, err})
  end

  defp handle_finch_payload(state, {:headers, _headers}), do: {[], state}

  defp handle_finch_payload(state, {:data, chunk}) when is_binary(chunk) do
    case decode_sse_chunk(state, chunk) do
      {:ok, events, new_state} -> {events, new_state}
      {:terminal, events, new_state} -> {events, %{new_state | done: true}}
    end
  end

  defp handle_finch_payload(state, :done) do
    state = %{state | done: true}

    if state.message_completed_emitted? do
      {:halt, state}
    else
      {[synthesize_message_completed(state)], %{state | message_completed_emitted?: true}}
    end
  end

  defp handle_finch_payload(state, {:error, exception}) do
    err =
      AdapterError.new(:network_error,
        provider: :anthropic,
        message: "transport failure: " <> Exception.message(exception),
        cause: exception
      )

    finalize_with_event(state, {:error, err})
  end

  defp handle_finch_payload(state, _other), do: {[], state}

  defp finalize_with_error(state, reason, message) do
    err = AdapterError.new(reason, provider: :anthropic, message: message)
    finalize_with_event(state, {:error, err})
  end

  defp finalize_with_event(state, event) do
    {[event], %{state | done: true}}
  end

  # Decode one Finch :data chunk through SSE, then map each parsed message
  # to ALLM events via chunk_to_events/2.
  defp decode_sse_chunk(state, chunk) do
    {messages, new_acc} = SSE.decode_chunk(state.sse_acc, chunk)
    state = %{state | sse_acc: new_acc}
    {events, terminal?, new_state} = messages_to_events(messages, state)
    if terminal?, do: {:terminal, events, new_state}, else: {:ok, events, new_state}
  end

  defp messages_to_events(messages, state) do
    Enum.reduce_while(messages, {[], false, state}, fn msg, {events_acc, _term?, st} ->
      case message_to_events(msg, st) do
        {events, false, new_st} -> {:cont, {events_acc ++ events, false, new_st}}
        {events, true, new_st} -> {:halt, {events_acc ++ events, true, new_st}}
      end
    end)
  end

  # Anthropic's SSE protocol does NOT use the [DONE] sentinel — its
  # `message_stop` named event is the canonical terminator. The SSE
  # decoder still emits the `:done` sentinel for any `data: [DONE]`
  # payload (defensive carry-over from the OpenAI carve-out); we treat
  # it as a no-op.
  defp message_to_events(:done, state), do: {[], false, state}

  defp message_to_events(%{data: data} = sse_msg, state) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{} = decoded} -> chunk_to_events(decoded, sse_msg, state)
      _ -> malformed_event_response(state, data)
    end
  end

  defp malformed_event_response(state, data) do
    err = StreamError.new(:malformed_event, message: "could not parse SSE data: #{inspect(data)}")
    {[{:error, err}], true, %{state | done: true}}
  end

  # Map one parsed SSE chunk JSON to ALLM events; updates state. Dispatches
  # on the named-event field carried on the SSE message. Returns
  # `{events, terminal?, new_state}`.
  @spec chunk_to_events(map(), map(), map()) :: {[Event.t()], boolean(), map()}
  defp chunk_to_events(decoded, %{event: event_name}, state) when is_binary(event_name) do
    anthropic_chunk_to_events(event_name, decoded, state)
  end

  # Defensive: if the SSE message lacks a named event field (shouldn't
  # happen on Anthropic's wire), fall back to the embedded `type` field.
  defp chunk_to_events(decoded, _sse_msg, state) do
    case Map.get(decoded, "type") do
      name when is_binary(name) -> anthropic_chunk_to_events(name, decoded, state)
      _ -> {[], false, state}
    end
  end

  # message_start: register the assistant message; buffer :message_started.
  defp anthropic_chunk_to_events("message_start", decoded, state) do
    msg = Map.get(decoded, "message", %{})
    msg_id = Map.get(msg, "id")

    bookend_msg = %Message{
      role: :assistant,
      content: "",
      metadata: if(is_binary(msg_id), do: %{provider_id: msg_id}, else: %{})
    }

    new_state = %{state | message_id: msg_id, message_started_emitted?: true}
    {[{:message_started, %{message: bookend_msg}}], false, new_state}
  end

  # content_block_start: register the block by index. Tool_use blocks
  # additionally emit the canonical :tool_call_started event.
  defp anthropic_chunk_to_events("content_block_start", decoded, state) do
    index = Map.get(decoded, "index", 0)
    block = Map.get(decoded, "content_block", %{})

    case Map.get(block, "type") do
      "text" ->
        partial = %{type: :text, text: ""}
        new_state = put_in(state.content_blocks[index], partial)
        {[], false, new_state}

      "tool_use" ->
        id = Map.get(block, "id", "")
        name = Map.get(block, "name", "")
        partial = %{type: :tool_use, id: id, name: name, raw_args: ""}
        new_state = put_in(state.content_blocks[index], partial)

        events =
          if is_binary(id) and id != "" and is_binary(name) and name != "" do
            [{:tool_call_started, %{id: id, name: name}}]
          else
            []
          end

        {events, false, new_state}

      "thinking" ->
        partial = %{type: :thinking, text: ""}
        new_state = put_in(state.content_blocks[index], partial)
        {[{:raw_chunk, {:thinking_start, %{index: index}}}], false, new_state}

      _other ->
        partial = %{type: :unknown}
        new_state = put_in(state.content_blocks[index], partial)
        {[], false, new_state}
    end
  end

  # content_block_delta: dispatch on the delta.type to text_delta /
  # input_json_delta / thinking_delta.
  defp anthropic_chunk_to_events("content_block_delta", decoded, state) do
    index = Map.get(decoded, "index", 0)
    delta = Map.get(decoded, "delta", %{})
    handle_block_delta(Map.get(delta, "type"), index, delta, state)
  end

  # content_block_stop: synthesize the canonical close-out event for the
  # block at `index`. Text blocks → :text_completed; tool_use blocks →
  # :tool_call_completed (with the accumulated raw_args parsed via Jason).
  defp anthropic_chunk_to_events("content_block_stop", decoded, state) do
    index = Map.get(decoded, "index", 0)

    case Map.get(state.content_blocks, index) do
      %{type: :text, text: text} ->
        {[{:text_completed, %{id: nil, text: text}}], false, state}

      %{type: :tool_use, id: id, name: name, raw_args: raw} ->
        args =
          case Jason.decode(raw) do
            {:ok, %{} = parsed} -> parsed
            _ -> %{}
          end

        events = [
          {:tool_call_completed, %{id: id, name: name, arguments: args, raw_arguments: raw}}
        ]

        {events, false, state}

      _other ->
        {[], false, state}
    end
  end

  # message_delta: carries terminal stop_reason + usage updates. We store
  # the stop_reason for the synthesized :message_completed event AND emit
  # a {:raw_chunk, {:usage, _}} event when usage is present (so
  # StreamCollector folds onto Response.usage).
  defp anthropic_chunk_to_events("message_delta", decoded, state) do
    delta = Map.get(decoded, "delta", %{})
    raw_stop = Map.get(delta, "stop_reason")
    {finish_reason, raw_keep} = map_stop_reason(raw_stop)

    state =
      if is_nil(raw_stop) do
        state
      else
        %{state | finish_reason: finish_reason, raw_finish_reason: raw_keep}
      end

    case Map.get(decoded, "usage") do
      %{} = usage ->
        pre_mapped = %{
          output_tokens: Map.get(usage, "output_tokens"),
          input_tokens: Map.get(usage, "input_tokens")
        }

        {[{:raw_chunk, {:usage, pre_mapped}}], false, state}

      _ ->
        {[], false, state}
    end
  end

  # message_stop: synthesize the canonical :message_completed event and
  # halt the stream. After_fun's gated cancel skips the Finch cancel
  # because state.done == true.
  defp anthropic_chunk_to_events("message_stop", _decoded, state) do
    if state.message_completed_emitted? do
      {[], true, %{state | done: true}}
    else
      events = [synthesize_message_completed(state)]

      {events, true, %{state | done: true, message_completed_emitted?: true}}
    end
  end

  # ping: keep-alive — drop silently per the Decision #14 mapping table.
  defp anthropic_chunk_to_events("ping", _decoded, state), do: {[], false, state}

  # error: documented Anthropic SSE event for mid-stream errors. Lift
  # the embedded error.type to an %AdapterError{} via the same
  # classifier the non-streaming arm uses.
  defp anthropic_chunk_to_events("error", decoded, state) do
    err =
      AdapterError.new(:provider_unavailable,
        provider: :anthropic,
        message: "Anthropic SSE error event mid-stream",
        cause: Map.get(decoded, "error", decoded)
      )

    {[{:error, err}], true, %{state | done: true}}
  end

  # Unknown event names — emit a :raw_chunk for forward-compat with
  # future Anthropic event additions.
  defp anthropic_chunk_to_events(name, decoded, state) when is_binary(name) do
    {[{:raw_chunk, {:unknown_event, name, decoded}}], false, state}
  end

  # content_block_delta sub-dispatch helpers (extracted to keep the main
  # clause's cyclomatic complexity within Credo's threshold).
  defp handle_block_delta("text_delta", index, delta, state) do
    text = Map.get(delta, "text", "")
    if text == "", do: {[], false, state}, else: emit_text_delta(index, text, state)
  end

  defp handle_block_delta("input_json_delta", index, delta, state) do
    partial_json = Map.get(delta, "partial_json", "")

    case Map.get(state.content_blocks, index) do
      %{type: :tool_use} = block ->
        emit_tool_call_delta(index, block, partial_json, state)

      _ ->
        # Delta arrived before content_block_start — drop defensively.
        {[], false, state}
    end
  end

  defp handle_block_delta("thinking_delta", index, delta, state) do
    text = Map.get(delta, "thinking", Map.get(delta, "text", ""))

    state =
      update_in(state.content_blocks[index], fn
        %{type: :thinking, text: acc} = b -> %{b | text: acc <> text}
        other -> other
      end)

    {[{:raw_chunk, {:thinking_delta, %{index: index, delta: text}}}], false, state}
  end

  defp handle_block_delta(_other, _index, _delta, state), do: {[], false, state}

  defp emit_text_delta(index, text, state) do
    state =
      update_in(state.content_blocks[index], fn
        %{type: :text, text: acc} = b -> %{b | text: acc <> text}
        other -> other
      end)

    new_state = %{state | accumulated_text: state.accumulated_text <> text}
    {[{:text_delta, %{id: nil, delta: text}}], false, new_state}
  end

  defp emit_tool_call_delta(index, %{id: id} = block, partial_json, state) do
    updated = %{block | raw_args: block.raw_args <> partial_json}
    new_state = put_in(state.content_blocks[index], updated)

    events = build_tool_call_delta_event(id, partial_json)
    {events, false, new_state}
  end

  defp build_tool_call_delta_event(id, partial_json)
       when is_binary(id) and id != "" and is_binary(partial_json) and partial_json != "" do
    [{:tool_call_delta, %{id: id, arguments_delta: partial_json}}]
  end

  defp build_tool_call_delta_event(_id, _partial_json), do: []

  # Build the synthetic :message_completed payload from the accumulated
  # state. Walks state.content_blocks in index order, collecting any
  # tool_use blocks into the message metadata so StreamCollector folds
  # them onto Response.tool_calls.
  defp synthesize_message_completed(state) do
    tool_calls =
      state.content_blocks
      |> Enum.sort_by(fn {idx, _} -> idx end)
      |> Enum.flat_map(fn
        {_idx, %{type: :tool_use, id: id, name: name, raw_args: raw}} ->
          args =
            case Jason.decode(raw) do
              {:ok, %{} = parsed} -> parsed
              _ -> %{}
            end

          [
            ToolCall.new(
              id: id,
              name: name,
              arguments: args,
              raw_arguments: raw
            )
          ]

        _ ->
          []
      end)

    metadata = if tool_calls == [], do: %{}, else: %{tool_calls: tool_calls}

    metadata =
      if is_binary(state.message_id) do
        Map.put(metadata, :provider_id, state.message_id)
      else
        metadata
      end

    msg = %Message{
      role: :assistant,
      content: state.accumulated_text,
      metadata: metadata
    }

    finish_reason =
      if state.finish_reason == :stop and tool_calls != [] do
        :tool_calls
      else
        state.finish_reason
      end

    {:message_completed, %{message: msg, finish_reason: finish_reason}}
  end

  # after_fun: cancel only when state.done == false (Phase 10.3
  # Decision #4a — the gated cancel pattern). Defensive rescue:
  # cancel_async_request/1 may raise on an already-completed ref.
  defp stream_after_fun(%{done: true}, _finch_module), do: :ok

  defp stream_after_fun(%{ref: ref, finch_module: finch_module}, _) do
    finch_module.cancel_async_request(ref)
    :ok
  rescue
    _ -> :ok
  end
end
