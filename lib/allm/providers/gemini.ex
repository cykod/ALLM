defmodule ALLM.Providers.Gemini do
  @moduledoc """
  Google Gemini provider adapter — Layer B.
   (bundled adapters).

   ships the non-streaming `ALLM.Adapter` callback set against
  the Generative Language API at
  `https://generativelanguage.googleapis.com/v1beta`. Streaming
  (`ALLM.StreamAdapter`) lands in tools / vision / image-out
  in Phases 16.3/16.4/16.5.

  This module implements:

    * `generate/2` — fires `POST /v1beta/models/{model}:generateContent`
      via `Req`, wrapped in `ALLM.Retry.run/3` with the **default** retry
      policy (the documented contract — Gemini's 429 / 500 / 503 / 504 are already
      covered by the documented contract's default retryable set; no Gemini-specific
      wrapper is needed).
    * `prepare_request/2` — returns an unfired `%Req.Request{}` with the
      API key injected as `x-goog-api-key`.
    * `translate_options/2` — identity. Gemini's
      camelCase rename and `generationConfig` nesting happens inside
      `to_generation_config/1` at request-build time.

  ## Single translator

  Gemini exposes one chat endpoint, `generateContent`, that covers both
  text and image generation — image generation is selected by toggling
  `generationConfig.responseModalities`. The request-builder
  (`to_gemini_request_body/2`) is therefore a single function shared
  across the chat adapter and (in) the image adapter. This
  amortizes the PHASE_10 dual-translator drift class to zero.

  ## Auth header

  The API key flows on the `x-goog-api-key` request header, not the
  documented `?key=...` query parameter. Both forms are equivalent
  server-side; the header form keeps the API key out of HTTP access
  logs and metrics. The same header is reused for the streaming
  endpoint.

  ## Wire field map

  | Concern | Gemini wire field |
  |---------|------------------|
  | Endpoint host | `https://generativelanguage.googleapis.com/v1beta` |
  | Method (chat non-streaming) | `POST /models/{model}:generateContent` |
  | Auth header | `x-goog-api-key: $key` |
  | Roles | `user`, `model` (`:assistant → "model"`) |
  | System prompt | top-level `systemInstruction.parts[].text` |
  | Generation params | nested under `generationConfig.{maxOutputTokens, temperature, topP, topK, stopSequences, responseMimeType, responseSchema}` |
  | `finish_reason` | `candidates[0].finishReason` (UPPER_SNAKE_CASE; mapping table below) |
  | Prompt-blocked path | `promptFeedback.blockReason` (top-level, no candidates) |
  | Usage location | `usageMetadata.{promptTokenCount, candidatesTokenCount, totalTokenCount}` |
  | Error envelope | `{"error": {"code", "status", "message"}}` |

  ## Finish-reason mapping

  Gemini's enum has 19 documented values. ALLM's
  `Response.finish_reason` is a closed 6-atom union; the raw string is
  preserved at `Response.raw_finish_reason` for non-canonical rows.

  | Gemini `finishReason` | ALLM `Response.finish_reason` |
  |-----------------------|-------------------------------|
  | `STOP` | `:stop` |
  | `MAX_TOKENS` | `:length` |
  | `SAFETY` | `:content_filter` |
  | `RECITATION` | `:content_filter` |
  | `LANGUAGE` | `:content_filter` |
  | `BLOCKLIST` | `:content_filter` |
  | `PROHIBITED_CONTENT` | `:content_filter` |
  | `SPII` | `:content_filter` |
  | `IMAGE_SAFETY` | `:content_filter` |
  | `IMAGE_PROHIBITED_CONTENT` | `:content_filter` |
  | `IMAGE_RECITATION` | `:content_filter` |
  | `IMAGE_OTHER` | `:other` |
  | `NO_IMAGE` | `:other` |
  | `MALFORMED_FUNCTION_CALL` | `:error` |
  | `UNEXPECTED_TOOL_CALL` | `:error` |
  | `TOO_MANY_TOOL_CALLS` | `:error` |
  | `MISSING_THOUGHT_SIGNATURE` | `:error` |
  | `MALFORMED_RESPONSE` | `:error` |
  | `OTHER` / `FINISH_REASON_UNSPECIFIED` / unknown | `:other` |

  ## Empty-candidates branches (Decisions #9 + #10)

    * `promptFeedback.blockReason` with empty candidates →
      `{:ok, %Response{finish_reason: :content_filter, content: ""}}`.
      The block reason is preserved at
      `metadata.error.reason = "blocked:<BLOCK_REASON>"`.
    * empty candidates with no `promptFeedback.blockReason` →
      `{:error, %AdapterError{reason: :malformed_response}}`.

  ## Usage decoding

  `usageMetadata.candidatesTokenCount` is canonical;
  `usageMetadata.responseTokenCount` is read as a defensive fallback
  when `candidatesTokenCount` is absent. If both are missing,
  `Usage.output_tokens` is left at `nil` and a one-time
  `Logger.warning/1` fires per call.

  ## Error envelope mapping

  Maps Google's `{error: {code, status, message}}` envelope onto
  `%AdapterError{reason:...}`:

  | HTTP | Google `status` | `AdapterError.reason` |
  |------|-----------------|----------------------|
  | 400 | `INVALID_ARGUMENT` (no marker) | `:invalid_request` |
  | 400 | `INVALID_ARGUMENT` (`exceeds the maximum number of tokens` substring) | `:context_length_exceeded` |
  | 401 | `UNAUTHENTICATED` | `:authentication_failed` |
  | 403 | `PERMISSION_DENIED` | `:authentication_failed` |
  | 404 | `NOT_FOUND` | `:invalid_request` |
  | 429 | `RESOURCE_EXHAUSTED` | `:rate_limited` |
  | 500 | `INTERNAL` | `:provider_unavailable` |
  | 503 | `UNAVAILABLE` | `:provider_unavailable` |
  | 504 | `DEADLINE_EXCEEDED` | `:provider_unavailable` |

  ## Retry policy

  No Gemini-specific retry-policy wrapper. The default policy at
  `lib/allm/retry.ex` already retries HTTP 429, 500, 502, 503, 504,
  and `:timeout` / `:network_error`. Streaming never retries
  .

  ## Key resolution

  Keys never appear on the engine. `prepare_request/2` and `generate/2`
  call `ALLM.Keys.fetch!(:gemini, opts)` at request-build time. The
  `:gemini` provider atom is **not** in `ALLM.Keys`'s `@env_var_table`;
  the unknown-provider fallback at
  `lib/allm/keys.ex:189-194` returns `"GEMINI_API_KEY"`.
  """

  @behaviour ALLM.Adapter
  @behaviour ALLM.StreamAdapter

  @base_url "https://generativelanguage.googleapis.com/v1beta"
  @default_stream_timeout 60_000

  alias ALLM.Error.AdapterError
  alias ALLM.Error.StreamError
  alias ALLM.Error.ValidationError
  alias ALLM.Image
  alias ALLM.ImagePart
  alias ALLM.Keys
  alias ALLM.Message
  alias ALLM.Providers.Gemini.Decode
  alias ALLM.Providers.Support.GeminiHeaders
  alias ALLM.Providers.Support.SSE
  alias ALLM.Request
  alias ALLM.Response
  alias ALLM.Retry
  alias ALLM.TextPart
  alias ALLM.Tool
  alias ALLM.ToolCall
  alias ALLM.Usage

  require Logger

  # ---------------------------------------------------------------------------
  # Public API — Adapter callbacks
  # ---------------------------------------------------------------------------

  @impl ALLM.Adapter
  @doc """
  Identity translator. Gemini accepts ALLM's canonical
  `:max_tokens`, `:temperature`, `:top_p`, etc. — the camelCase rename
  and `generationConfig` nesting happens in `to_generation_config/1` at
  request-build time, not here.

  ## Examples

      iex> req = ALLM.Request.new([%ALLM.Message{role: :user, content: "x"}], model: "gemini-2.5-flash")
      iex> ALLM.Providers.Gemini.translate_options([max_tokens: 100, temperature: 0.7], req)
      [max_tokens: 100, temperature: 0.7]
  """
  @spec translate_options(keyword(), Request.t()) :: keyword()
  def translate_options(opts, %Request{}) when is_list(opts), do: opts

  @impl ALLM.Adapter
  @doc """
  Build an unfired `%Req.Request{}` with the resolved API key injected
  as `x-goog-api-key: <key>`.

  Per `ALLM.Keys.fetch!/2`, this function **raises**
  `%ALLM.Error.EngineError{reason: :missing_key}` when no key resolver
  yields a value.

  Honors `opts[:request_timeout]` (forwarded as `Req`'s
  `:receive_timeout`) and `opts[:adapter_opts][:endpoint]` (URL host
  override, primarily for testing).

  ## Examples

      iex> ALLM.Keys.put(:gemini, "AIza-doctest-prep")
      iex> req = ALLM.Request.new([%ALLM.Message{role: :user, content: "hi"}], model: "gemini-2.5-flash")
      iex> {:ok, %Req.Request{} = http} = ALLM.Providers.Gemini.prepare_request(req, [])
      iex> Req.Request.get_header(http, "x-goog-api-key")
      ["AIza-doctest-prep"]
      iex> ALLM.Keys.delete(:gemini)
      :ok
  """
  @spec prepare_request(Request.t(), keyword()) ::
          {:ok, Req.Request.t()} | {:error, AdapterError.t()}
  def prepare_request(%Request{} = request, opts) when is_list(opts) do
    api_key = Keys.fetch!(:gemini, opts)
    body = to_gemini_request_body(request, opts)
    url = endpoint(opts) <> "/models/#{request.model}:generateContent"

    req =
      Req.new(
        method: :post,
        url: url,
        headers: GeminiHeaders.headers(api_key),
        json: body
      )
      |> maybe_apply_req_test_stub(opts)
      |> maybe_apply_request_timeout(opts)

    {:ok, req}
  end

  defp endpoint(opts) do
    case Keyword.get(opts, :adapter_opts, []) |> Keyword.get(:endpoint) do
      nil -> @base_url
      url when is_binary(url) -> url
    end
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
  Execute a non-streaming `generateContent` request synchronously.

  Wraps the HTTP call in `ALLM.Retry.run/3` with the the documented contract default
  policy. Returns `{:ok, %Response{}}` on 2xx success or
  `{:error, %AdapterError{}}` on every failure shape.

  ## Empty-candidates handling (Decisions #9 + #10)

    * `promptFeedback.blockReason` with empty candidates →
      `{:ok, %Response{finish_reason: :content_filter, content: ""}}`
      (a successful HTTP response is a successful call from the
      adapter's perspective; the content filter is a finish reason).
    * Empty candidates with no `promptFeedback.blockReason` →
      `{:error, %AdapterError{reason: :malformed_response}}`.

  ## Error reasons

  | HTTP | `AdapterError.reason` |
  |------|----------------------|
  | 400 generic | `:invalid_request` |
  | 400 ctx-window | `:context_length_exceeded` |
  | 401 / 403 | `:authentication_failed` |
  | 404 | `:invalid_request` |
  | 429 | `:rate_limited` |
  | 500 / 503 / 504 | `:provider_unavailable` |
  | network drop | `:network_error` |
  | malformed body | `:malformed_response` |

  ## Examples

      iex> ALLM.Keys.put(:gemini, "AIza-doctest-gen")
      iex> req = ALLM.Request.new([%ALLM.Message{role: :user, content: "x"}], model: "gemini-2.5-flash")
      iex> {:error, %ALLM.Error.AdapterError{reason: :authentication_failed}} =
      ...> ALLM.Providers.Gemini.generate(req,
      ...> retry: false,
      ...> adapter_opts: [plug: fn conn ->
      ...> conn
      ...> |> Plug.Conn.put_resp_content_type("application/json")
      ...> |> Plug.Conn.resp(401, ~s({"error":{"code":401,"status":"UNAUTHENTICATED","message":"bad"}}))
      ...> end]
      ...>)
      iex> ALLM.Keys.delete(:gemini)
      :ok
  """
  @spec generate(Request.t(), keyword()) ::
          {:ok, Response.t()} | {:error, AdapterError.t() | ValidationError.t()}
  def generate(%Request{} = request, opts) when is_list(opts) do
    with :ok <- reject_image_in_system_messages(request),
         :ok <- reject_unsupported_image_sources(request) do
      do_generate(request, opts)
    end
  end

  defp do_generate(%Request{} = request, opts) do
    {:ok, %Req.Request{} = http_req} = prepare_request(request, opts)

    retry_policy = Keyword.get(opts, :retry, :default)
    telemetry_meta = build_retry_telemetry_meta(opts)

    retry_policy
    |> Retry.run(telemetry_meta, fn -> run_one_attempt(http_req, opts) end)
    |> unwrap_retry_token()
  end

  defp build_retry_telemetry_meta(opts) do
    base = %{provider: :gemini}

    case Keyword.get(opts, :request_id) do
      nil -> base
      value -> Map.put(base, :request_id, value)
    end
  end

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
        timeout_err = AdapterError.new(:timeout, provider: :gemini, cause: cause)

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
           provider: :gemini,
           message: "transport failure: " <> Exception.message(exception),
           cause: exception
         )}
    end
  end

  defp decode_success_body(body, opts) when is_map(body) do
    {:ok, decode_response(body, opts)}
  rescue
    e in ArgumentError ->
      # Defensive: malformed shape that decode_response/2 cannot handle.
      {:error, malformed_error(e)}
  catch
    :throw, {:malformed_response, cause} ->
      {:error, malformed_error(cause)}
  end

  defp decode_success_body(other, _opts) do
    {:error, malformed_error({:unexpected_body_shape, other})}
  end

  defp malformed_error(cause) do
    AdapterError.new(:malformed_response,
      provider: :gemini,
      message: "Gemini returned a body that could not be decoded",
      cause: cause
    )
  end

  defp classify_http_error(status, body, headers) do
    decoded = decode_error_body(body)
    classified = classify_error(status, decoded, headers)

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
  @spec classify_error(non_neg_integer(), map(), Enumerable.t()) :: AdapterError.t()
  def classify_error(status, body, headers) when is_integer(status) and is_map(body) do
    error = Map.get(body, "error", %{})
    google_status = Map.get(error, "status")
    message = Map.get(error, "message", "Gemini HTTP #{status}")

    reason = classify_reason(status, google_status, message)
    retry_after = retry_after_ms(headers)

    AdapterError.new(reason,
      provider: :gemini,
      status: status,
      retry_after_ms: retry_after,
      message: message,
      metadata: %{google_status: google_status}
    )
  end

  defp classify_reason(401, _gs, _msg), do: :authentication_failed
  defp classify_reason(403, _gs, _msg), do: :authentication_failed
  defp classify_reason(404, _gs, _msg), do: :invalid_request
  defp classify_reason(429, _gs, _msg), do: :rate_limited

  defp classify_reason(400, _gs, msg) when is_binary(msg) do
    if context_length_marker?(msg) do
      :context_length_exceeded
    else
      :invalid_request
    end
  end

  defp classify_reason(400, _gs, _msg), do: :invalid_request

  defp classify_reason(status, _gs, _msg) when status in [500, 502, 503, 504],
    do: :provider_unavailable

  defp classify_reason(_status, _gs, _msg), do: :unknown

  defp context_length_marker?(msg) do
    String.contains?(msg, "exceeds the maximum number of tokens") or
      String.contains?(msg, "input token count")
  end

  # Parse `Retry-After` header per RFC 7231 §7.1.3. Decision #16 amendment:
  # `Retry-After` parsing is a separate concern from the retry-policy
  # wrapper choice — even though Gemini uses the default policy, the
  # adapter still honors server-issued back-off hints. Mirrors
  # `lib/allm/providers/anthropic.ex:515-547` and
  # `lib/allm/providers/openai.ex:690-737`.
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

  defp header_value(_headers, _name), do: nil

  defp header_value_to_string([v | _]) when is_binary(v), do: v
  defp header_value_to_string(v) when is_binary(v), do: v
  defp header_value_to_string(_), do: nil

  defp parse_retry_after(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> seconds * 1_000
      _ -> nil
    end
  end

  defp parse_retry_after(_), do: nil

  # ---------------------------------------------------------------------------
  # Request-body composition (Decision #1 — single translator)
  # ---------------------------------------------------------------------------

  @doc """
  Compose the JSON request body for `generateContent` from a canonical
  `%Request{}`. Pure function; no I/O.

  Performs system-message extraction (hoist into top-level
  `systemInstruction`), role mapping (`:assistant → "model"`), and
  `generationConfig` composition.

   surface only — tools (16.3) and image-out (16.5) extend
  this builder via `opts` flags without changing the text-only path.

  ## Examples

      iex> req = ALLM.Request.new(
      ...> [%ALLM.Message{role: :system, content: "Be concise."},
      ...> %ALLM.Message{role: :user, content: "Hi"}],
      ...> model: "gemini-2.5-flash", max_tokens: 256
      ...>)
      iex> body = ALLM.Providers.Gemini.to_gemini_request_body(req, [])
      iex> {body["systemInstruction"], length(body["contents"]), body["generationConfig"]["maxOutputTokens"]}
      {%{"parts" => [%{"text" => "Be concise."}]}, 1, 256}
  """
  @spec to_gemini_request_body(Request.t(), keyword()) :: map()
  def to_gemini_request_body(%Request{} = request, opts) when is_list(opts) do
    {system_text, non_system} = extract_system(request.messages)

    base = %{"contents" => to_gemini_contents(non_system)}

    base
    |> maybe_put_system_instruction(system_text)
    |> maybe_put_generation_config(request)
    |> maybe_put_tools(request.tools)
    |> maybe_put_tool_config(request.tool_choice, request.tools)
  end

  defp maybe_put_tools(body, []), do: body

  defp maybe_put_tools(body, [_ | _] = tools) do
    Map.put(body, "tools", [%{"functionDeclarations" => to_gemini_tools(tools)}])
  end

  # tool_choice has no Gemini equivalent until tools are declared. Omit
  # toolConfig when tools is empty so the wire payload stays minimal.
  defp maybe_put_tool_config(body, _choice, []), do: body
  defp maybe_put_tool_config(body, nil, _tools), do: body

  defp maybe_put_tool_config(body, choice, _tools) do
    Map.put(body, "toolConfig", %{"functionCallingConfig" => to_gemini_tool_config(choice)})
  end

  defp maybe_put_system_instruction(body, nil), do: body

  defp maybe_put_system_instruction(body, text) when is_binary(text) do
    Map.put(body, "systemInstruction", %{"parts" => [%{"text" => text}]})
  end

  defp maybe_put_generation_config(body, %Request{} = request) do
    case to_generation_config(request) do
      gc when map_size(gc) == 0 -> body
      gc -> Map.put(body, "generationConfig", gc)
    end
  end

  @doc false
  @spec extract_system([Message.t()]) :: {String.t() | nil, [Message.t()]}
  def extract_system(messages) when is_list(messages) do
    {systems, others} = Enum.split_with(messages, &(&1.role == :system))

    case systems do
      [] -> {nil, others}
      _ -> {Enum.map_join(systems, "\n\n", &stringify_content(&1.content)), others}
    end
  end

  # Phase 16.4 — `user_content/1` is the user-side content emitter.
  #
  #   - binary  → forwarded verbatim wrapped in a single text part
  #     (v0.2 backward-compat).
  #   - list with any `%ImagePart{}` → translated to inlineData parts
  #     via `to_gemini_content_blocks/1`.
  #   - list with only `%TextPart{}` → flattened to one joined-text part
  #     (Phase 14.4 backward-compat).
  #   - nil → single text part with empty string.
  #
  # Mirrors the byte-identical helper names in `lib/allm/providers/anthropic.ex`
  # (`user_content/1`, `to_anthropic_content_blocks/1`, `part_to_block/1`,
  # `materialize_part/1`, `system_has_image_part?/1`,
  # `reject_image_in_system_messages/1`) and the OpenAI counterparts at
  # `lib/allm/providers/openai.ex:1694-1798` per CLAUDE.md cross-provider
  # helper-name alignment rule.
  defp user_content(c) when is_binary(c) or is_nil(c) do
    [%{"text" => stringify_content(c)}]
  end

  defp user_content(parts) when is_list(parts) do
    if Enum.any?(parts, &match?(%ImagePart{}, &1)) do
      to_gemini_content_blocks(parts)
    else
      [%{"text" => stringify_content(parts)}]
    end
  end

  defp stringify_content(c) when is_binary(c), do: c
  defp stringify_content(nil), do: ""

  # Flatten a text-only content list. Image-bearing lists are routed
  # through `to_gemini_content_blocks/1` by `user_content/1` BEFORE
  # reaching this helper; system / tool-role messages always carry
  # text or text-only lists.
  defp stringify_content(parts) when is_list(parts) do
    Enum.map_join(parts, "\n", &materialize_part/1)
  end

  defp materialize_part(%TextPart{text: t}), do: t
  # Defensive: ImagePart should be filtered upstream for system / tool
  # contexts; render to empty string rather than raising — text-only
  # contexts that accidentally see one degrade gracefully. Mirrors the
  # OpenAI / Anthropic precedent; see `lib/allm/providers/anthropic.ex:780`.
  defp materialize_part(%ImagePart{}), do: ""

  defp materialize_part(other) do
    raise ArgumentError,
          "stringify_content/1 expects a TextPart; got: #{inspect(other)}"
  end

  # Phase 16.4 — system-message ImagePart rejection. System content is
  # text-only on Gemini's `systemInstruction` field; an ImagePart in a
  # system role is a hard reject before any other validation runs.
  # Mirrors `lib/allm/providers/anthropic.ex:793` and
  # `lib/allm/providers/openai.ex:1752`.
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

  # Phase 16.4 — Gemini does NOT fetch URL-source images; the Files API
  # is out of scope for v0.3. Walk every ImagePart and reject:
  #
  #   * `{:url, _}` → unsupported_feature with pre-fetch guidance.
  #   * `{:file, _}` with `:mime_type == nil` → unsupported_feature
  #     with the path named so callers know to use `Image.from_binary/2`
  #     or `from_file/1` against an extension-bearing path.
  #
  # Returns `AdapterError`, NOT `ValidationError`, because the rejection
  # is a provider-capability gate (Gemini-specific), not a structural
  # validation error.
  @spec reject_unsupported_image_sources(Request.t()) ::
          :ok | {:error, AdapterError.t()}
  defp reject_unsupported_image_sources(%Request{messages: messages}) do
    Enum.reduce_while(messages, :ok, fn %Message{content: c}, _acc ->
      case check_message_image_sources(c) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp check_message_image_sources(content) when is_list(content) do
    Enum.reduce_while(content, :ok, fn part, _acc ->
      case check_part_source(part) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp check_message_image_sources(_other), do: :ok

  defp check_part_source(%ImagePart{image: %Image{source: {:url, _}}}) do
    {:error,
     AdapterError.new(:unsupported_feature,
       provider: :gemini,
       message:
         "Gemini adapter does not fetch URL-source images; pre-fetch and pass as " <>
           "%Image{source: {:binary, _}, mime_type: _}"
     )}
  end

  defp check_part_source(%ImagePart{image: %Image{source: {:file, path}, mime_type: nil}}) do
    {:error,
     AdapterError.new(:unsupported_feature,
       provider: :gemini,
       message:
         "Gemini adapter cannot infer MIME type for file #{inspect(path)}; " <>
           "use ALLM.Image.from_binary/2 or pass an extension-bearing path"
     )}
  end

  defp check_part_source(_other), do: :ok

  # Phase 16.4 — content-block translator. Routes a `[TextPart | ImagePart]`
  # content list to Gemini's `parts` array. Each ALLM part becomes one
  # Gemini Part. URL and nil-mime-file ImageParts MUST be rejected
  # upstream by `reject_unsupported_image_sources/1`; reaching them here
  # raises so the closed-set assumption remains explicit.
  #
  # `ImagePart.detail` is read but NOT emitted on the wire (Gemini has
  # no equivalent field); a single `Logger.debug/1` per process surfaces
  # the drop the first time a non-default value is observed.
  @spec to_gemini_content_blocks([TextPart.t() | ImagePart.t()]) :: [map()]
  defp to_gemini_content_blocks(parts) when is_list(parts) do
    Enum.map(parts, &part_to_block/1)
  end

  defp part_to_block(%TextPart{text: t}) do
    %{"text" => t}
  end

  defp part_to_block(%ImagePart{image: %Image{source: {:base64, data}, mime_type: mime}, detail: d}) do
    detail_drop_check(d)
    %{"inlineData" => %{"mimeType" => mime, "data" => data}}
  end

  defp part_to_block(%ImagePart{image: %Image{source: {:binary, bytes}, mime_type: mime}, detail: d}) do
    detail_drop_check(d)
    %{"inlineData" => %{"mimeType" => mime, "data" => Base.encode64(bytes)}}
  end

  defp part_to_block(%ImagePart{image: %Image{source: {:file, path}, mime_type: mime}, detail: d})
       when is_binary(mime) do
    detail_drop_check(d)
    bytes = File.read!(path)
    %{"inlineData" => %{"mimeType" => mime, "data" => Base.encode64(bytes)}}
  end

  # Phase 16.4 — Gemini's wire shape has no `detail` field. When a
  # non-default detail is observed, fire a single deferred-form
  # `Logger.debug/1` per process and stash a flag in the process dict so
  # subsequent calls in the same process stay silent. Mirrors Anthropic's
  # precedent at `lib/allm/providers/anthropic.ex:884`. `:auto` is the
  # default and does NOT trigger the warning.
  defp detail_drop_check(:auto), do: :ok
  defp detail_drop_check(nil), do: :ok

  defp detail_drop_check(_detail) do
    warn_detail_dropped_once()
    :ok
  end

  defp warn_detail_dropped_once do
    if !Process.get(:allm_gemini_detail_warned, false) do
      Logger.debug(fn ->
        "ALLM.Providers.Gemini: ImagePart.detail is not supported by Gemini; dropping. " <>
          "This warning fires once per process."
      end)

      Process.put(:allm_gemini_detail_warned, true)
    end

    :ok
  end

  @doc false
  @spec to_gemini_contents([Message.t()]) :: [map()]
  def to_gemini_contents(messages) when is_list(messages) do
    name_lookup = build_tool_call_name_lookup(messages)
    Enum.map(messages, &to_gemini_message(&1, name_lookup))
  end

  # Walk the message list and collect a `tool_call_id => tool_name` map from
  # every assistant turn's `metadata.tool_calls`. Used by `:tool`-role
  # rewrite to populate `functionResponse.name`, which ALLM `Message.name`
  # doesn't carry on tool-result messages constructed by the chat
  # orchestrator. Gemini rejects empty `functionResponse.name`.
  defp build_tool_call_name_lookup(messages) do
    Enum.reduce(messages, %{}, fn
      %Message{role: :assistant, metadata: %{tool_calls: calls}}, acc when is_list(calls) ->
        Enum.reduce(calls, acc, fn
          %{id: id, name: n}, a when is_binary(id) and is_binary(n) -> Map.put(a, id, n)
          _, a -> a
        end)

      _, acc ->
        acc
    end)
  end

  defp to_gemini_message(%Message{role: :user, content: c}, _lookup) do
    %{"role" => "user", "parts" => user_content(c)}
  end

  defp to_gemini_message(%Message{role: :assistant, content: c, metadata: meta}, _lookup) do
    # Phase 16.3 — round-trip the model's prior `functionCall` parts back
    # to Gemini when the assistant turn is being re-fed. The chat-loop
    # stashes the tool_calls list under `metadata.tool_calls` per the
    # cross-provider convention (mirrors Anthropic's
    # `to_anthropic_message/1` `:assistant` clause at
    # `lib/allm/providers/anthropic.ex:703-736`).
    case Map.get(meta, :tool_calls) do
      [_ | _] = calls -> assistant_with_tool_calls(c, calls)
      _ -> %{"role" => "model", "parts" => [%{"text" => stringify_content(c)}]}
    end
  end

  defp to_gemini_message(%Message{role: :system, content: c}, _lookup) do
    # Defensive: extract_system/1 should have removed these.
    %{"role" => "user", "parts" => [%{"text" => stringify_content(c)}]}
  end

  # Phase 16.3 — `:tool`-role messages translate to a `user`-role Gemini
  # turn carrying a single `functionResponse` part (Decision #5). The
  # `:tool_call_id` is echoed as `functionResponse.id` when present.
  # `:name` is the function name; absent name surfaces as the empty
  # string and Gemini will reject — the wire-shape is honest about the
  # caller's omission rather than synthesizing a placeholder.
  defp to_gemini_message(%Message{role: :tool} = msg, lookup) do
    %Message{content: c, tool_call_id: tcid, name: name} = msg

    # `Message.name` is `nil` on tool-result messages built by the chat
    # orchestrator; resolve from the prior assistant turn's tool_calls
    # metadata via `lookup` (built in `to_gemini_contents/1`). Empty name
    # is rejected by Gemini, so falling back to "" is a last resort that
    # preserves wire honesty about the caller's omission.
    resolved_name = name || Map.get(lookup, tcid) || ""

    fr =
      %{
        "name" => resolved_name,
        "response" => to_function_response_payload(c)
      }
      |> maybe_put_response_id(tcid)

    %{"role" => "user", "parts" => [%{"functionResponse" => fr}]}
  end

  defp maybe_put_response_id(map, nil), do: map
  defp maybe_put_response_id(map, ""), do: map
  defp maybe_put_response_id(map, id) when is_binary(id), do: Map.put(map, "id", id)

  # Decision #5 prose — `functionResponse.response` is a free-form JSON
  # object. ALLM standardizes binary tool output as
  # `%{"output" => content}` so callers don't need to read provider docs;
  # callers wanting full control pass a map and we passthrough verbatim.
  defp to_function_response_payload(c) when is_binary(c), do: %{"output" => c}
  defp to_function_response_payload(c) when is_map(c), do: c
  defp to_function_response_payload(nil), do: %{"output" => ""}

  # Render an `:assistant`-role message that carried tool-calls metadata
  # back to the wire as a `model`-role turn whose parts hold one
  # `functionCall` per call, optionally preceded by a text part if the
  # turn also carried text (rare but legal — Gemini's mixed text+call
  # response shape).
  defp assistant_with_tool_calls(c, [_ | _] = calls) do
    text = stringify_content(c)

    text_parts =
      case text do
        "" -> []
        _ -> [%{"text" => text}]
      end

    call_parts = Enum.map(calls, &tool_call_to_function_call_part/1)
    %{"role" => "model", "parts" => text_parts ++ call_parts}
  end

  defp tool_call_to_function_call_part(%ToolCall{
         id: id,
         name: name,
         arguments: args,
         metadata: meta
       }) do
    fc_base = %{"name" => name, "args" => args || %{}}

    fc =
      case id do
        nil -> fc_base
        "" -> fc_base
        bin when is_binary(bin) -> Map.put(fc_base, "id", bin)
      end

    # Echo `thoughtSignature` on the part containing functionCall — Gemini 3
    # rejects subsequent turns missing it. Captured on decode by
    # `Gemini.Decode.decode_function_call/2`.
    part = %{"functionCall" => fc}

    case meta do
      %{"thoughtSignature" => sig} when is_binary(sig) and sig != "" ->
        Map.put(part, "thoughtSignature", sig)

      _ ->
        part
    end
  end

  @doc """
  Translate a list of canonical `%ALLM.Tool{}`s to Gemini's
  `functionDeclarations` shape.

  Gemini's `tools` is an array of `%{functionDeclarations: [...]}`
  objects, not a flat array of declarations. Each declaration carries
  `:name`, `:description`, and `:parameters` (Gemini's name for the
  JSON-Schema field — distinct from OpenAI's `parameters` key on the
  tool's `function` sub-map and Anthropic's `input_schema`).

  ## Examples

      iex> tool = ALLM.Tool.new(name: "get_weather", description: "weather", schema: %{"type" => "object"})
      iex> ALLM.Providers.Gemini.to_gemini_tools([tool])
      [%{"name" => "get_weather", "description" => "weather", "parameters" => %{"type" => "object"}}]
  """
  @spec to_gemini_tools([Tool.t()]) :: [map()]
  def to_gemini_tools(tools) when is_list(tools) do
    Enum.map(tools, fn %Tool{name: n, description: d, schema: s} ->
      %{"name" => n, "description" => d, "parameters" => sanitize_schema(s)}
    end)
  end

  # Gemini's `tools[].functionDeclarations[].parameters` and
  # `generationConfig.responseSchema` accept the OpenAPI 3.0 Schema-Object
  # subset, which does NOT include `additionalProperties` (a JSON Schema /
  # OpenAI-strict-mode keyword). Passing it verbatim returns
  # `INVALID_ARGUMENT: Unknown name "additionalProperties"`. Strip it (and
  # `$schema`) recursively so caller schemas authored for OpenAI strict mode
  # are portable across providers. Other unsupported keywords are still
  # rejected by Gemini at request time per design line 197.
  @doc false
  @spec sanitize_schema(any()) :: any()
  def sanitize_schema(schema) when is_map(schema) do
    schema
    |> Map.drop(["additionalProperties", :additionalProperties, "$schema", :"$schema"])
    |> Map.new(fn {k, v} -> {k, sanitize_schema(v)} end)
  end

  def sanitize_schema(list) when is_list(list), do: Enum.map(list, &sanitize_schema/1)
  def sanitize_schema(other), do: other

  @doc """
  Translate an ALLM canonical `tool_choice` to Gemini's
  `functionCallingConfig` map.

  | ALLM canonical | Gemini wire |
  |----------------|-------------|
  | `:auto` | `%{"mode" => "AUTO"}` |
  | `:required` | `%{"mode" => "ANY"}` |
  | `:none` | `%{"mode" => "NONE"}` |
  | `{:tool, "name"}` | `%{"mode" => "ANY", "allowedFunctionNames" => ["name"]}` |
  | `"name"` (string) | shorthand for `{:tool, "name"}` |

  Map shapes (`%{"mode" => "AUTO"}`, etc.) are passed through verbatim
  so callers can hand-craft Gemini-specific extensions.

  ## Examples

      iex> ALLM.Providers.Gemini.to_gemini_tool_config(:auto)
      %{"mode" => "AUTO"}

      iex> ALLM.Providers.Gemini.to_gemini_tool_config({:tool, "set_color"})
      %{"mode" => "ANY", "allowedFunctionNames" => ["set_color"]}
  """
  @spec to_gemini_tool_config(Request.tool_choice() | {:tool, String.t()}) :: map()
  def to_gemini_tool_config(:auto), do: %{"mode" => "AUTO"}
  def to_gemini_tool_config(:required), do: %{"mode" => "ANY"}
  def to_gemini_tool_config(:none), do: %{"mode" => "NONE"}

  def to_gemini_tool_config({:tool, name}) when is_binary(name) do
    %{"mode" => "ANY", "allowedFunctionNames" => [name]}
  end

  def to_gemini_tool_config(name) when is_binary(name) do
    %{"mode" => "ANY", "allowedFunctionNames" => [name]}
  end

  def to_gemini_tool_config(%{} = wire), do: wire

  @doc false
  @spec to_generation_config(Request.t()) :: map()
  def to_generation_config(%Request{} = request) do
    %{}
    |> maybe_put("maxOutputTokens", request.max_tokens)
    |> maybe_put("temperature", request.temperature)
    |> put_response_format(request.response_format)
    |> Map.merge(stringify_options(request.options))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp put_response_format(map, nil), do: map
  defp put_response_format(map, :text), do: map

  defp put_response_format(map, %{type: :json_object}) do
    Map.put(map, "responseMimeType", "application/json")
  end

  defp put_response_format(map, %{type: :json_schema, schema: schema}) do
    map
    |> Map.put("responseMimeType", "application/json")
    |> Map.put("responseSchema", sanitize_schema(schema))
  end

  defp put_response_format(map, _other), do: map

  # Map ALLM's canonical option keys onto Gemini's camelCase
  # `generationConfig` keys. Unknown keys are passed through verbatim
  # (string-coerced) so callers can attach Gemini-specific fields via
  # `request.options` (e.g., `:thinkingConfig` in a future phase).
  defp stringify_options(options) when is_map(options) do
    Map.new(options, fn {k, v} -> {option_key(k), v} end)
  end

  defp option_key(:top_p), do: "topP"
  defp option_key(:top_k), do: "topK"
  defp option_key(:stop), do: "stopSequences"
  defp option_key(:max_tokens), do: "maxOutputTokens"
  defp option_key(:temperature), do: "temperature"
  defp option_key(:response_mime_type), do: "responseMimeType"
  defp option_key(:response_schema), do: "responseSchema"
  defp option_key(k) when is_atom(k), do: Atom.to_string(k)
  defp option_key(k) when is_binary(k), do: k

  # ---------------------------------------------------------------------------
  # Response decoding
  # ---------------------------------------------------------------------------

  @doc false
  @spec decode_response(map(), keyword()) :: Response.t()
  def decode_response(%{} = body, _opts) do
    candidates = Map.get(body, "candidates", [])

    case candidates do
      [_ | _] = list -> decode_with_candidates(body, list)
      [] -> decode_empty_candidates(body)
      _other -> throw({:malformed_response, {:non_list_candidates, candidates}})
    end
  end

  # Phase 16.5 — load-bearing refactor: `Gemini.Decode.candidate_parts/1`
  # is the single shared decoder for `Gemini.generate/2` and
  # `Gemini.Images.generate/2`. The chat path ignores `image_parts` (which
  # Gemini-text models never emit anyway) and the image path ignores
  # `tool_calls` (image models do not emit functionCall parts on
  # generateContent + responseModalities=[TEXT, IMAGE]). See
  # `lib/allm/providers/gemini/decode.ex` and GEMINI_DESIGN.md
  # "Cross-function invariants" lines 217-219.
  defp decode_with_candidates(body, [first | _rest]) do
    {text, tool_calls, _image_parts, raw_finish} = Decode.candidate_parts(first)

    {finish_reason, raw_keep} = parse_finish_reason(raw_finish)

    {final_finish, final_raw} =
      promote_finish_reason_for_tool_calls(finish_reason, raw_keep, tool_calls)

    message = %Message{
      role: :assistant,
      content: text || "",
      metadata: tool_calls_metadata(tool_calls)
    }

    %Response{
      id: nil,
      model: Map.get(body, "modelVersion"),
      message: message,
      output_text: text,
      tool_calls: tool_calls,
      finish_reason: final_finish,
      raw_finish_reason: final_raw,
      usage: parse_usage(Map.get(body, "usageMetadata", %{})),
      raw: body,
      metadata: response_metadata(body)
    }
  end

  defp tool_calls_metadata([]), do: %{}
  defp tool_calls_metadata([_ | _] = tool_calls), do: %{tool_calls: tool_calls}

  # Decision #14 finish-reason override: STOP + functionCall parts ->
  # :tool_calls (the override path matches OpenAI Chat Completions and
  # Anthropic — finish reason follows the *content*, not the wire enum).
  # The raw_finish_reason collapses to nil because :tool_calls IS the
  # canonical row for "stopped to invoke a tool"; callers who need the
  # original "STOP" string can read response.raw["candidates"]....
  defp promote_finish_reason_for_tool_calls(:stop, _raw, [_ | _]), do: {:tool_calls, nil}
  defp promote_finish_reason_for_tool_calls(fr, raw, _tool_calls), do: {fr, raw}

  # Phase 16.5 — `walk_parts/1` is preserved as a public test seam that
  # delegates to `Gemini.Decode.candidate_parts/1`. The original 16.1
  # caller (decode_with_candidates/2) now calls `candidate_parts/1`
  # directly; this helper exists so external test files asserting the
  # shared-helper invariant against a `parts` list (rather than a
  # candidate map) keep working.
  @doc false
  @spec walk_parts([map()]) :: {String.t() | nil, [ToolCall.t()]}
  def walk_parts(parts) when is_list(parts) do
    {text, tool_calls, _image_parts, _raw_finish} =
      Decode.candidate_parts(%{"content" => %{"parts" => parts}})

    {text, tool_calls}
  end

  defp decode_empty_candidates(body) do
    case get_in(body, ["promptFeedback", "blockReason"]) do
      reason when is_binary(reason) ->
        # Decision #9 — prompt-blocked. Successful response shape with
        # finish_reason: :content_filter and empty content.
        %Response{
          model: Map.get(body, "modelVersion"),
          message: %Message{role: :assistant, content: "", metadata: %{}},
          output_text: "",
          tool_calls: [],
          finish_reason: :content_filter,
          raw_finish_reason: reason,
          usage: parse_usage(Map.get(body, "usageMetadata", %{})),
          raw: body,
          metadata: %{
            error: %{reason: "blocked:#{reason}"},
            model_version: Map.get(body, "modelVersion")
          }
        }

      _ ->
        # Decision #10 — empty candidates with no block reason is malformed.
        throw({:malformed_response, :empty_candidates_no_block_reason})
    end
  end

  defp response_metadata(body) do
    case Map.get(body, "modelVersion") do
      nil -> %{}
      version -> %{model_version: version}
    end
  end

  @doc """
  Map a Gemini `finishReason` string to ALLM's closed
  `Response.finish_reason` enum, returning `{atom, raw_string_or_nil}`
  per the documented contract.

  `STOP` collapses to `{:stop, nil}` (the canonical "natural completion"
  row); every other row preserves the raw string at index 1 so callers
  can recover provider fidelity from `Response.raw_finish_reason`.

  ## Examples

      iex> ALLM.Providers.Gemini.parse_finish_reason("STOP")
      {:stop, nil}

      iex> ALLM.Providers.Gemini.parse_finish_reason("MAX_TOKENS")
      {:length, "MAX_TOKENS"}

      iex> ALLM.Providers.Gemini.parse_finish_reason("SAFETY")
      {:content_filter, "SAFETY"}

      iex> ALLM.Providers.Gemini.parse_finish_reason("OTHER")
      {:other, "OTHER"}

      iex> ALLM.Providers.Gemini.parse_finish_reason(nil)
      {nil, nil}
  """
  @spec parse_finish_reason(String.t() | nil) ::
          {Response.finish_reason() | nil, String.t() | nil}
  def parse_finish_reason(nil), do: {nil, nil}
  def parse_finish_reason("STOP"), do: {:stop, nil}
  def parse_finish_reason("MAX_TOKENS"), do: {:length, "MAX_TOKENS"}
  def parse_finish_reason("SAFETY"), do: {:content_filter, "SAFETY"}
  def parse_finish_reason("RECITATION"), do: {:content_filter, "RECITATION"}
  def parse_finish_reason("LANGUAGE"), do: {:content_filter, "LANGUAGE"}
  def parse_finish_reason("BLOCKLIST"), do: {:content_filter, "BLOCKLIST"}

  def parse_finish_reason("PROHIBITED_CONTENT"),
    do: {:content_filter, "PROHIBITED_CONTENT"}

  def parse_finish_reason("SPII"), do: {:content_filter, "SPII"}
  def parse_finish_reason("IMAGE_SAFETY"), do: {:content_filter, "IMAGE_SAFETY"}

  def parse_finish_reason("IMAGE_PROHIBITED_CONTENT"),
    do: {:content_filter, "IMAGE_PROHIBITED_CONTENT"}

  def parse_finish_reason("IMAGE_RECITATION"),
    do: {:content_filter, "IMAGE_RECITATION"}

  def parse_finish_reason("IMAGE_OTHER"), do: {:other, "IMAGE_OTHER"}
  def parse_finish_reason("NO_IMAGE"), do: {:other, "NO_IMAGE"}

  def parse_finish_reason("MALFORMED_FUNCTION_CALL"),
    do: {:error, "MALFORMED_FUNCTION_CALL"}

  def parse_finish_reason("UNEXPECTED_TOOL_CALL"),
    do: {:error, "UNEXPECTED_TOOL_CALL"}

  def parse_finish_reason("TOO_MANY_TOOL_CALLS"),
    do: {:error, "TOO_MANY_TOOL_CALLS"}

  def parse_finish_reason("MISSING_THOUGHT_SIGNATURE"),
    do: {:error, "MISSING_THOUGHT_SIGNATURE"}

  def parse_finish_reason("MALFORMED_RESPONSE"),
    do: {:error, "MALFORMED_RESPONSE"}

  def parse_finish_reason(other) when is_binary(other), do: {:other, other}

  @doc false
  @spec parse_usage(map()) :: Usage.t()
  def parse_usage(%{} = usage) do
    input = Map.get(usage, "promptTokenCount")
    output = output_tokens(usage)
    total = Map.get(usage, "totalTokenCount")

    %Usage{
      input_tokens: input,
      output_tokens: output,
      total_tokens: total,
      extra:
        Map.drop(usage, [
          "promptTokenCount",
          "candidatesTokenCount",
          "responseTokenCount",
          "totalTokenCount"
        ])
    }
  end

  def parse_usage(_), do: %Usage{}

  defp output_tokens(usage) do
    case Map.get(usage, "candidatesTokenCount") do
      n when is_integer(n) -> n
      _ -> output_tokens_fallback(Map.get(usage, "responseTokenCount"))
    end
  end

  defp output_tokens_fallback(n) when is_integer(n) do
    Logger.warning(fn ->
      "ALLM.Providers.Gemini: usageMetadata.candidatesTokenCount absent; " <>
        "falling back to responseTokenCount per Decision #11."
    end)

    n
  end

  defp output_tokens_fallback(_), do: nil

  # ---------------------------------------------------------------------------
  # Streaming (Phase 16.2 — Decision #1, #11, #12, #13, #14)
  # ---------------------------------------------------------------------------

  @impl ALLM.StreamAdapter
  @doc """
  Open an SSE stream against `streamGenerateContent?alt=sse`.

  Returns `{:ok, enumerable}` on success — the enumerable is lazy; the
  HTTP request fires on the first reduce. Returns `{:error, %AdapterError{}}`
  only for synchronous pre-flight failures (key-resolution failure raises
  `%EngineError{}` directly per the `Keys.fetch!/2` contract; that is
  surfaced through the existing `with`-chain at the call site).

  Per CLAUDE.md mid-stream-error invariant, **HTTP-shaped errors observed
  AFTER the consumer starts reducing are folded into a terminating
  `{:error, _}` event** — the call-site tuple stays `{:ok, stream}`. This
  includes 4xx status codes received before the first SSE event (the
  `{:status, code}` Finch frame folds via `handle_finch_payload/2`).

  ## Decision references

    * **the documented contract** — request body byte-equal to `generate/2`'s. Only
      the URL path differs (`:streamGenerateContent?alt=sse` vs
      `:generateContent`).
    * **the documented contract** — `?alt=sse` is the ONLY required query parameter;
      auth still flows via `x-goog-api-key`.
    * **the documented contract** — `usageMetadata` may appear on intermediate
      chunks; the chunk-mapper emits `{:raw_chunk, {:usage, _}}` on
      every appearance and `StreamCollector.apply_event/2` overwrites.
    * **the documented contract** — stream terminates on Finch's `:done` payload,
      not a `data: [DONE]` lookahead. The synthetic `:message_completed`
      event is built from accumulated state.

  ## Options

    * `:stream_timeout` (default 60_000 ms) — receive-loop after-clause
      between chunks. This is the inter-message timer; see
      `:receive_timeout` for the underlying Finch HTTP receive timeout.
    * `:receive_timeout`, `:request_timeout`, `:pool_timeout` —
      forwarded verbatim to `Finch.async_request/3`. Each governs a
      different Finch timer: receive is per-chunk, request is
      end-to-end response receipt, pool is connection acquisition.
      Omit to use Finch's defaults.
    * `:finch_module` (default `Finch`) — test injection seam.
    * `:finch_name` (default `ALLM.Finch`).
    * `:finch_stub_ref` — opaque ref forwarded to the Finch shim
      (used only by `ALLM.Test.FinchStub`).
    * `:adapter_opts[:endpoint]` — endpoint override (testing).
  """
  @spec stream(Request.t(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, AdapterError.t() | ValidationError.t()}
  def stream(%Request{} = request, opts) when is_list(opts) do
    with :ok <- reject_image_in_system_messages(request),
         :ok <- reject_unsupported_image_sources(request) do
      do_stream(request, opts)
    end
  end

  defp do_stream(%Request{} = request, opts) do
    api_key = Keys.fetch!(:gemini, opts)
    body = to_gemini_request_body(request, opts)
    json_body = Jason.encode!(body)
    headers = GeminiHeaders.headers(api_key)

    url =
      endpoint(opts) <>
        "/models/#{request.model}:streamGenerateContent?alt=sse"

    finch_request = Finch.build(:post, url, headers, json_body)

    finch_module = Keyword.get(opts, :finch_module, Finch)
    finch_name = Keyword.get(opts, :finch_name, ALLM.Finch)

    finch_extra_opts =
      Keyword.take(opts, [
        :finch_stub_ref,
        :receive_timeout,
        :request_timeout,
        :pool_timeout
      ])

    stream_timeout = Keyword.get(opts, :stream_timeout, @default_stream_timeout)

    enumerable =
      Stream.resource(
        fn ->
          stream_start_fun(finch_request, finch_module, finch_name, finch_extra_opts)
        end,
        fn state -> stream_next_fun(state, stream_timeout) end,
        fn state -> stream_after_fun(state, finch_module) end
      )

    {:ok, enumerable}
  end

  defp stream_start_fun(finch_request, finch_module, finch_name, finch_extra_opts) do
    ref = finch_module.async_request(finch_request, finch_name, finch_extra_opts)
    bookend_msg = %Message{role: :assistant, content: ""}

    %{
      ref: ref,
      finch_module: finch_module,
      sse_acc: SSE.new(),
      buffered: [{:message_started, %{message: bookend_msg}}],
      done: false,
      status: nil,
      message_completed_emitted?: false,
      accumulated_text: "",
      tool_calls_by_id: %{},
      tool_call_order: [],
      finish_reason: nil,
      raw_finish_reason: nil
    }
  end

  # next_fun: drain buffered events first; then pull one Finch payload.
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

  # ---------------------------------------------------------------------------
  # Finch payload dispatch — one defp per payload class.
  # ---------------------------------------------------------------------------

  defp handle_finch_payload(state, {:status, code}) when code in 200..299 do
    {[], %{state | status: code}}
  end

  defp handle_finch_payload(state, {:status, code}) when is_integer(code) and code >= 400 do
    err = classify_error(code, %{}, [])
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
      events = synthesize_message_completed(state)
      {events, %{state | message_completed_emitted?: true}}
    end
  end

  defp handle_finch_payload(state, {:error, exception}) do
    err =
      AdapterError.new(:network_error,
        provider: :gemini,
        message: "transport failure: " <> Exception.message(exception),
        cause: exception
      )

    finalize_with_event(state, {:error, err})
  end

  defp handle_finch_payload(state, _other), do: {[], state}

  defp finalize_with_error(state, reason, message) do
    err = AdapterError.new(reason, provider: :gemini, message: message)
    finalize_with_event(state, {:error, err})
  end

  defp finalize_with_event(state, event) do
    {[event], %{state | done: true}}
  end

  # Decode one Finch :data chunk through the line-buffered SSE decoder,
  # then map each parsed message through chunk_to_events/2.
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

  # Gemini SSE does NOT use the [DONE] sentinel; the SSE decoder still
  # emits :done for any `data: [DONE]` payload (defensive carve-over from
  # the OpenAI-side support module). When it appears, treat it as a
  # terminal but emit no events — Decision #13 says termination is on
  # connection close, not on a `[DONE]` lookahead, so message_to_events
  # halts but synthesize_message_completed fires later via the Finch
  # `:done` payload path.
  defp message_to_events(:done, state), do: {[], true, %{state | done: true}}

  defp message_to_events(%{data: data}, state) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{} = decoded} -> chunk_to_events(decoded, state)
      _ -> malformed_event_response(state, data)
    end
  end

  defp malformed_event_response(state, data) do
    err = StreamError.new(:malformed_event, message: "could not parse SSE data: #{inspect(data)}")
    {[{:error, err}], true, %{state | done: true}}
  end

  # ---------------------------------------------------------------------------
  # Chunk-to-event mapping — one defp clause per top-level event class
  # (per CLAUDE.md "SSE chunk mappers" rule). Dispatch on the presence of
  # `promptFeedback.blockReason` (terminal content-filter), then on
  # `candidates` and `usageMetadata` keys. Returns
  # `{events, terminal?, new_state}`.
  # ---------------------------------------------------------------------------

  @doc false
  def chunk_to_events(decoded, state) do
    blocked = get_in(decoded, ["promptFeedback", "blockReason"])

    if is_binary(blocked) do
      handle_prompt_blocked(blocked, state)
    else
      handle_candidates_and_usage(decoded, state)
    end
  end

  # Decision #9 streaming variant — promptFeedback.blockReason on a chunk
  # surfaces as a terminating {:error, %AdapterError{:content_filter}}
  # event. Note: the non-streaming arm at decode_empty_candidates/1
  # treats the same wire-shape as :ok with finish_reason: :content_filter
  # because the HTTP request succeeded; on the streaming wire the same
  # signal arrives as a separate SSE event AFTER the consumer started
  # reducing, so per StreamAdapter Invariant 2 it folds to a terminal
  # error event (mirrors OpenAI Chat Completions content_filter handling
  # at lib/allm/providers/openai.ex:1287-1296). The mid-stream-error
  # fold invariant means the call-site tuple stays {:ok, stream}.
  defp handle_prompt_blocked(reason, state) do
    err =
      AdapterError.new(:content_filter,
        provider: :gemini,
        message: "Gemini blocked the prompt: #{reason}",
        metadata: %{block_reason: reason}
      )

    {[{:error, err}], true, %{state | done: true}}
  end

  # Walk the parsed chunk for candidates and usageMetadata, emitting one
  # event group per source. Updates state with accumulated text /
  # tool-calls / finish_reason. Per Decision #12, usage emits whenever it
  # appears (intermediate or terminal) and the StreamCollector overwrites.
  defp handle_candidates_and_usage(decoded, state) do
    {cand_events, cand_terminal?, state} = handle_candidates(decoded, state)
    {usage_events, state} = handle_usage_metadata(decoded, state)

    events = cand_events ++ usage_events

    if cand_terminal? do
      completion = synthesize_message_completed(state)
      state = %{state | done: true, message_completed_emitted?: true}
      {events ++ completion, true, state}
    else
      {events, false, state}
    end
  end

  defp handle_candidates(decoded, state) do
    case decoded["candidates"] do
      [first | _] when is_map(first) -> handle_candidate(first, state)
      _ -> {[], false, state}
    end
  end

  # Walk the parts of the first candidate. Each part dispatches to a
  # dedicated handler (text vs functionCall). The candidate's finishReason
  # — when present — promotes to state.finish_reason and signals terminal
  # so the next-fun synthesizes :message_completed.
  defp handle_candidate(candidate, state) do
    parts = get_in(candidate, ["content", "parts"]) || []

    {events, state} =
      Enum.reduce(parts, {[], state}, fn part, {ev_acc, st} ->
        {ev, st2} = handle_part(part, st)
        {ev_acc ++ ev, st2}
      end)

    case candidate["finishReason"] do
      nil ->
        {events, false, state}

      raw when is_binary(raw) ->
        {fr, raw_keep} = parse_finish_reason(raw)
        state = %{state | finish_reason: fr, raw_finish_reason: raw_keep}
        {events, true, state}
    end
  end

  # ---------------------------------------------------------------------------
  # Per-part handlers (one defp per part-class)
  # ---------------------------------------------------------------------------

  defp handle_part(%{"text" => text}, state) when is_binary(text) and text != "" do
    events = [{:text_delta, %{id: nil, delta: text}}]
    {events, %{state | accumulated_text: state.accumulated_text <> text}}
  end

  defp handle_part(%{"functionCall" => %{} = fc} = part, state) do
    handle_function_call_part(fc, part, state)
  end

  defp handle_part(_other, state), do: {[], state}

  # functionCall parts arrive in a single SSE event (Decision-table row in
  # GEMINI_DESIGN.md "Tool-call delta-field name (streaming)"). The adapter
  # emits :tool_call_started + :tool_call_completed with zero deltas to
  # match the spec §8 event protocol — downstream collectors (StreamCollector
  # + Session) fold the same shape regardless of provider.
  defp handle_function_call_part(%{} = fc, part, state) do
    name = function_call_name(fc)
    args_map = normalize_function_call_args(Map.get(fc, "args"))
    raw_args = encode_function_call_args(args_map)
    id = synthesize_tool_call_id(fc)
    metadata = thought_signature_metadata(part)

    events = build_function_call_events(id, name, args_map, raw_args, fc, metadata)

    partial = %{
      id: id,
      name: name,
      arguments: args_map,
      raw_arguments: raw_args,
      metadata: metadata
    }

    state = %{
      state
      | tool_calls_by_id: Map.put(state.tool_calls_by_id, id, partial),
        tool_call_order: state.tool_call_order ++ [id]
    }

    {events, state}
  end

  # Gemini 3 emits `thoughtSignature` as a sibling field to `functionCall`
  # on the same part. Required to be echoed back on subsequent turns.
  defp thought_signature_metadata(%{"thoughtSignature" => sig}) when is_binary(sig) and sig != "" do
    %{"thoughtSignature" => sig}
  end

  defp thought_signature_metadata(_part), do: %{}

  defp function_call_name(%{"name" => name}) when is_binary(name), do: name
  defp function_call_name(_), do: ""

  defp build_function_call_events(id, name, args_map, raw_args, _fc, metadata)
       when is_binary(id) and id != "" and is_binary(name) and name != "" do
    [
      {:tool_call_started, %{id: id, name: name}},
      {:tool_call_completed,
       %{id: id, name: name, arguments: args_map, raw_arguments: raw_args, metadata: metadata}}
    ]
  end

  defp build_function_call_events(_id, _name, _args_map, _raw_args, fc, _metadata) do
    Logger.debug(fn ->
      "ALLM.Providers.Gemini: dropping malformed functionCall part #{inspect(fc)}"
    end)

    []
  end

  # Gemini's `functionCall.args` is documented as a JSON object (not a
  # string — Decision #4). Real wire shapes have only ever surfaced maps;
  # this defensive coercion drops nil and non-map values to `%{}` so the
  # downstream encoder always sees a clean JSON-encodable map.
  defp normalize_function_call_args(args) when is_map(args), do: args
  defp normalize_function_call_args(_), do: %{}

  defp encode_function_call_args(map) when is_map(map) do
    case Jason.encode(map) do
      {:ok, json} -> json
      _ -> ""
    end
  end

  # Gemini's `functionCall.id` is documented as optional. When absent we
  # synthesize a deterministic id from the name + args hash so collectors
  # don't see an empty-id event. Mirrors Anthropic's id-or-generate
  # behaviour at lib/allm/providers/anthropic.ex:1056-1067.
  defp synthesize_tool_call_id(%{"id" => id}) when is_binary(id) and id != "", do: id

  defp synthesize_tool_call_id(%{"name" => name} = fc) when is_binary(name) do
    args = Map.get(fc, "args") || %{}
    "fc_" <> Integer.to_string(:erlang.phash2({name, args}), 16)
  end

  defp synthesize_tool_call_id(_), do: ""

  # ---------------------------------------------------------------------------
  # usageMetadata handler (Decision #12)
  # ---------------------------------------------------------------------------

  defp handle_usage_metadata(%{"usageMetadata" => %{} = um}, state) do
    usage = parse_usage(um)

    pre_mapped = %{
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      total_tokens: usage.total_tokens,
      extra: usage.extra
    }

    {[{:raw_chunk, {:usage, pre_mapped}}], state}
  end

  defp handle_usage_metadata(_other, state), do: {[], state}

  # ---------------------------------------------------------------------------
  # Synthetic :message_completed on connection close (Decision #13)
  # ---------------------------------------------------------------------------

  defp synthesize_message_completed(state) do
    tool_calls = build_tool_calls_from_state(state)
    finish_reason = promote_finish_reason(state.finish_reason, tool_calls)
    metadata = build_completion_metadata(tool_calls)

    msg = %Message{
      role: :assistant,
      content: state.accumulated_text,
      metadata: metadata
    }

    [{:message_completed, %{message: msg, finish_reason: finish_reason, metadata: metadata}}]
  end

  defp build_completion_metadata([]), do: %{}
  defp build_completion_metadata([_ | _] = tool_calls), do: %{tool_calls: tool_calls}

  defp build_tool_calls_from_state(%{tool_call_order: order, tool_calls_by_id: by_id}) do
    Enum.map(order, fn id ->
      partial = Map.fetch!(by_id, id)

      ToolCall.new(
        id: partial.id,
        name: partial.name,
        arguments: partial.arguments,
        raw_arguments: partial.raw_arguments,
        metadata: Map.get(partial, :metadata, %{})
      )
    end)
  end

  # finish_reason :stop + non-empty tool_calls promotes to :tool_calls
  # (matches Anthropic precedent at lib/allm/providers/anthropic.ex:1879).
  defp promote_finish_reason(:stop, [_ | _]), do: :tool_calls
  defp promote_finish_reason(other, _tool_calls), do: other

  # after_fun: cancel only when state.done == false. Defensive rescue —
  # cancel_async_request/1 may raise if the ref already completed.
  defp stream_after_fun(%{done: true}, _finch_module), do: :ok

  defp stream_after_fun(%{ref: ref, finch_module: finch_module}, _) do
    finch_module.cancel_async_request(ref)
    :ok
  rescue
    _ -> :ok
  end
end
