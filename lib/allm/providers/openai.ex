defmodule ALLM.Providers.OpenAI do
  @moduledoc """
  OpenAI provider adapter — Layer B.

  Implements both OpenAI HTTP endpoints:

    * `generate/2` — fires `POST /v1/chat/completions` OR `POST /v1/responses`
      via `Req`, wrapped in `ALLM.Retry.run/3` for 429/5xx retries with
      `Retry-After` parsing.
    * `prepare_request/2` — returns an unfired `%Req.Request{}` with the API
      key already injected as `Authorization: Bearer <key>`.
    * `translate_options/2` — endpoint-aware `:max_tokens` rename per design
      the documented contract (`:max_completion_tokens` for `gpt-4o*`/`gpt-4.1*`/`gpt-5*`
      on Chat Completions, `:max_output_tokens` on Responses, passthrough for
      older models). Also handles reasoning controls per the documented contract.
    * `requires_structured_finalize?/1` — capability declaration consumed by
      `ALLM.Capability.preflight/2` returns `true` when a
      request combines tools and a `json_schema` response_format.

  ## Endpoint dispatch

  `dispatch_endpoint/2` selects between `:chat_completions` and `:responses`
  by (in order): explicit `opts[:endpoint]`, explicit
  `adapter_opts[:endpoint]`, the `@endpoint_dispatch` model-family regex
  table (`gpt-5*` and `o[1-9]*` → `:responses`; `gpt-4*`/`gpt-3.5*` →
  `:chat_completions`), and a default fallback of `:chat_completions`.

   lifts the prior unsupported-feature guard for `:responses`;
  `gpt-5*` and o-series models now route to the Responses API end-to-end.

  ## Reasoning controls

  `:reasoning_effort` (`:none | :low | :medium | :high | :xhigh`),
  `:reasoning_summary` (`:auto | :concise | :detailed`), and `:verbosity`
  (`:low | :medium | :high`) are routed by `translate_options/2`:

    * On `:responses`: nested under `reasoning: %{effort:..., summary:...}`
      (effort + summary share one sub-map); `verbosity:` passes through as a
      bare key.
    * On `:chat_completions` for `gpt-5*`: `:reasoning_effort` and
      `:verbosity` pass through as bare keys; `:reasoning_summary` is
      stripped (Chat Completions does not surface it).
    * On `:chat_completions` for non-reasoning models: reasoning keys are
      silently stripped with a `Logger.debug/1` line.

  Unknown effort/summary/verbosity atoms raise `ArgumentError`.

  ## Status mapping for Responses API

  | Responses status | `incomplete_details.reason` | `Response.finish_reason` |
  |------------------|------------------------------|--------------------------|
  | `"completed"` | n/a | `:stop` |
  | `"incomplete"` | `"max_output_tokens"` | `:length` |
  | `"incomplete"` | `"content_filter"` | `:content_filter` |
  | `"incomplete"` | other | `:other` |

  When status is `"incomplete"`, the raw reason is preserved on
  `Response.metadata.incomplete_details.reason`. `Response.metadata.reasoning`
  carries `effort` / `summary` from the response body's `reasoning` block.

  ## Key resolution

  Keys never appear on the engine. `prepare_request/2` and `generate/2` call
  `ALLM.Keys.fetch!(:openai, opts)` at request-build time per the documented contract.
  Per the documented contract, `prepare_request/2` raises
  `%ALLM.Error.EngineError{reason: :missing_key}` when no key resolver
  yields a value — a programmer error best surfaced loudly rather than
  threaded through every `with` chain.

  ## Retry contract

  `generate/2` wraps the HTTP call in `ALLM.Retry.run(opts[:retry] || :default, …)`.
  The closure parses `Retry-After` (both seconds and HTTP-date formats),
  returns `{:retry, delay_ms, error}` for 429/5xx/`:timeout`, `{:ok, response}`
  for 2xx, and `{:error, error}` for everything else (e.g. 4xx that aren't
  rate-limit). Streaming does NOT retry per the documented contract.

  ## Finch transport defaults

  Streaming uses `Finch.async_request/3` against the singleton
  `ALLM.Finch` (started by the library's OTP application with
  `protocol: :http1` per the documented contract). Engines that want a
  custom Finch ref inject via
  `adapter_opts: [finch_name: MyApp.Finch]`.

  ## Capability declarations

  `requires_structured_finalize?/1` returns `true` when a request combines
  `tools != []` AND `response_format = %{type: :json_schema,...}`
  OpenAI's API does not support that combination natively, so
  `ALLM.Capability.preflight/2` rewrites the request with
  `structured_finalize: true` and `ALLM.Chat.run/3` runs a two-pass tool
  loop + final-shape pass.

  ## response_format translation

  `to_openai_response_format/2` (called from `to_openai_request_body/3`)
  translates the canonical `%Request{}.response_format` to OpenAI's wire
  shape. Per the documented contract, the encoding is endpoint-aware:

  | ALLM canonical | `:chat_completions` wire | `:responses` wire |
  |----------------|--------------------------|-------------------|
  | `nil` | omitted (`nil`) | omitted (`nil`) |
  | `:text` | omitted (`nil`) | `{:text, %{format: %{type: "text"}}}` |
  | `%{type: :json_object}` | `{:response_format, %{type: "json_object"}}` | `{:text, %{format: %{type: "json_object"}}}` |
  | `%{type: :json_schema, name:, schema:, strict:}` | `{:response_format, %{type: "json_schema", json_schema: %{name:, schema:, strict:}}}` | `{:text, %{format: %{type: "json_schema", name:, schema:, strict:}}}` |

  The function returns either `nil` (omit the field) OR a
  `{wire_key, wire_value}` 2-tuple where `wire_key` is the JSON body key
  the caller must merge into the request body (`:response_format` for
  Chat Completions; `:text` for Responses).
  """

  @behaviour ALLM.Adapter
  @behaviour ALLM.StreamAdapter

  @base_url "https://api.openai.com/v1"

  # Default per-message receive timeout for streaming. Spec §7.2 + Invariant 10.
  @default_stream_timeout 60_000

  # Endpoint dispatch (Decision #1) — model-family regex → endpoint atom.
  # Walked in order; first match wins. `gpt-5*` and `o[1-9]*` route to
  # `:responses`; `gpt-(4|3.5)*` route to `:chat_completions`. Anything
  # else falls through to the `:chat_completions` default in
  # `dispatch_endpoint/2`.
  @endpoint_dispatch [
    {~r/^gpt-5/i, :responses},
    {~r/^o[1-9]/i, :responses},
    {~r/^gpt-(4|3\.5)/i, :chat_completions}
  ]

  # max-tokens parameter rename (Decision #6).
  @responses_max_tokens_key :max_output_tokens
  @chat_completions_new_max_tokens_models ~r/^gpt-(4o|4\.1|5)/
  @chat_completions_reasoning_models ~r/^gpt-5/

  # Reasoning-control closed enums (Decision #5). Used by Phase 10.6's
  # full reasoning-control plumbing; landed early so the closed sets are
  # in one place. `translate_options/2` does not yet branch on them.
  #
  # Note: `:minimal` was removed after live validation surfaced
  # `Unsupported value: 'minimal' is not supported with the 'gpt-5.5' model`.
  # Supported per OpenAI: 'none', 'low', 'medium', 'high', 'xhigh'.
  @effort_atoms ~w(none low medium high xhigh)a
  @summary_atoms ~w(auto concise detailed)a
  @verbosity_atoms ~w(low medium high)a

  # Reasoning-control call opts consumed by `merge_reasoning_opts/4` — these
  # are read from `opts` and re-shaped onto the wire (endpoint-aware), so they
  # must NOT ALSO ride `request.options` or they double-route and orphan a raw
  # atom-valued key on the Responses body. `ALLM.Chat.@request_carried_keys`
  # DERIVES its strip-set from `reasoning_opts/0` so this list stays the single
  # source of truth. See merge_reasoning_opts/4 and chat.ex.
  @reasoning_opts [:reasoning_effort, :reasoning_summary, :verbosity]

  require Logger

  alias ALLM.Error.AdapterError
  alias ALLM.Error.StreamError
  alias ALLM.Error.ValidationError
  alias ALLM.Event
  alias ALLM.Image
  alias ALLM.ImagePart
  alias ALLM.Keys
  alias ALLM.Message
  alias ALLM.Providers.Support.ImageMime
  alias ALLM.Providers.Support.OpenAIHeaders
  alias ALLM.Providers.Support.SSE
  alias ALLM.Providers.Support.Transport
  alias ALLM.Request
  alias ALLM.Response
  alias ALLM.Retry
  alias ALLM.TextPart
  alias ALLM.ToolCall
  alias ALLM.Usage

  @typedoc "Endpoint atom; chosen by `dispatch_endpoint/2`."
  @type endpoint :: :responses | :chat_completions

  # ---------------------------------------------------------------------------
  # Public API — Adapter callbacks
  # ---------------------------------------------------------------------------

  @doc """
  Resolve the endpoint for a model + opts pair.

  Resolution order:

    1. Explicit `opts[:endpoint]` (if `:responses` or `:chat_completions`).
    2. Explicit `adapter_opts[:endpoint]` (same shape).
    3. `@endpoint_dispatch` regex table — first match wins.
    4. Default fallback: `:chat_completions`.

  ## Examples

      iex> ALLM.Providers.OpenAI.dispatch_endpoint("gpt-4o", [])
      :chat_completions

      iex> ALLM.Providers.OpenAI.dispatch_endpoint("gpt-5.5", [])
      :responses

      iex> ALLM.Providers.OpenAI.dispatch_endpoint("o3", [])
      :responses

      iex> ALLM.Providers.OpenAI.dispatch_endpoint(nil, [])
      :chat_completions

      iex> ALLM.Providers.OpenAI.dispatch_endpoint("gpt-4o", endpoint: :responses)
      :responses

      iex> ALLM.Providers.OpenAI.dispatch_endpoint("gpt-5.5", adapter_opts: [endpoint: :chat_completions])
      :chat_completions
  """
  @spec dispatch_endpoint(String.t() | nil, keyword()) :: endpoint()
  def dispatch_endpoint(model, opts) when is_list(opts) do
    cond do
      ep = explicit_endpoint(opts) -> ep
      ep = explicit_endpoint(Keyword.get(opts, :adapter_opts, [])) -> ep
      is_binary(model) -> regex_dispatch(model)
      true -> :chat_completions
    end
  end

  defp explicit_endpoint(opts) do
    case Keyword.get(opts, :endpoint) do
      :responses -> :responses
      :chat_completions -> :chat_completions
      _ -> nil
    end
  end

  defp regex_dispatch(model) do
    Enum.find_value(@endpoint_dispatch, :chat_completions, fn {regex, ep} ->
      if Regex.match?(regex, model), do: ep, else: false
    end)
  end

  @doc """
  Capability declaration consumed by `ALLM.Capability.preflight/2`
  .

  Returns `true` when a request combines tools and a json_schema response
  format — the only combination that requires the structured-finalize
  two-pass dance.

  ## Examples

      iex> req = ALLM.Request.new([%ALLM.Message{role: :user, content: "x"}])
      iex> ALLM.Providers.OpenAI.requires_structured_finalize?(req)
      false

      iex> tool = ALLM.Tool.new(name: "t", description: "d", schema: %{})
      iex> rf = %{type: :json_schema, name: "p", schema: %{}, strict: true}
      iex> req = ALLM.Request.new([%ALLM.Message{role: :user, content: "x"}], tools: [tool], response_format: rf)
      iex> ALLM.Providers.OpenAI.requires_structured_finalize?(req)
      true
  """
  @spec requires_structured_finalize?(Request.t()) :: boolean()
  def requires_structured_finalize?(%Request{tools: tools, response_format: rf}) do
    tools != [] and match?(%{type: :json_schema}, rf)
  end

  @impl ALLM.Adapter
  @doc """
  Endpoint-aware translation of caller opts to OpenAI wire keys.

  ## `:max_tokens` rename matrix

  | Endpoint | Model regex | Output key |
  |----------|-------------|------------|
  | `:responses` | any | `:max_output_tokens` |
  | `:chat_completions` | `~r/^gpt-(4o\|4\\.1\|5)/` | `:max_completion_tokens` |
  | `:chat_completions` | anything else | `:max_tokens` (passthrough) |

  ## Reasoning controls

  `:reasoning_effort` (`#{inspect(~w(none low medium high xhigh)a)}`),
  `:reasoning_summary` (`#{inspect(~w(auto concise detailed)a)}`), and
  `:verbosity` (`#{inspect(~w(low medium high)a)}`) are routed by endpoint:

    * `:responses` — `:reasoning_effort` and `:reasoning_summary` merge into
      a single `reasoning: %{effort:..., summary:...}` sub-map; `:verbosity`
      passes through as `verbosity: "<atom>"`.
    * `:chat_completions` for `gpt-5*` — `:reasoning_effort` and
      `:verbosity` pass through as bare `reasoning_effort: "<atom>"` and
      `verbosity: "<atom>"`. `:reasoning_summary` is stripped (Chat
      Completions does not surface it).
    * `:chat_completions` for non-reasoning models — all three keys are
      stripped with a `Logger.debug/1` line.

  Unknown effort/summary/verbosity atoms raise `ArgumentError`.

  All other opts pass through unchanged.

  ## Examples

      iex> req = ALLM.Request.new([%ALLM.Message{role: :user, content: "x"}], model: "gpt-4o-mini")
      iex> ALLM.Providers.OpenAI.translate_options([max_tokens: 100], req)
      [max_completion_tokens: 100]

      iex> req = ALLM.Request.new([%ALLM.Message{role: :user, content: "x"}], model: "gpt-3.5-turbo")
      iex> ALLM.Providers.OpenAI.translate_options([max_tokens: 100], req)
      [max_tokens: 100]

      iex> req = ALLM.Request.new([%ALLM.Message{role: :user, content: "x"}], model: "gpt-5.5")
      iex> ALLM.Providers.OpenAI.translate_options([reasoning_effort: :medium], req)
      [reasoning: %{effort: "medium"}]
  """
  @spec translate_options(keyword(), Request.t()) :: keyword()
  def translate_options(opts, %Request{} = request) when is_list(opts) do
    endpoint = dispatch_endpoint(request.model, opts)
    # Validate reasoning-control atoms up-front (defense in depth — raises
    # ArgumentError on any illegal value before the endpoint-aware routing).
    validate_reasoning_opts!(opts)

    {reasoning_opts, rest} =
      Keyword.split(opts, [:reasoning_effort, :reasoning_summary, :verbosity])

    base = Enum.map(rest, &rename_option(&1, endpoint, request.model))
    base ++ encode_reasoning_opts(reasoning_opts, endpoint, request.model)
  end

  defp rename_option({:max_tokens, value}, :responses, _model) do
    {@responses_max_tokens_key, value}
  end

  defp rename_option({:max_tokens, value}, :chat_completions, model) when is_binary(model) do
    if Regex.match?(@chat_completions_new_max_tokens_models, model) do
      {:max_completion_tokens, value}
    else
      {:max_tokens, value}
    end
  end

  defp rename_option(other, _endpoint, _model), do: other

  # Validates :reasoning_effort / :reasoning_summary / :verbosity atoms
  # against their closed enums (Decision #5). Raises ArgumentError on any
  # illegal value; passes silently when the keys are absent.
  defp validate_reasoning_opts!(opts) do
    Enum.each(opts, fn
      {:reasoning_effort, value} -> validate_atom!(:reasoning_effort, value, @effort_atoms)
      {:reasoning_summary, value} -> validate_atom!(:reasoning_summary, value, @summary_atoms)
      {:verbosity, value} -> validate_atom!(:verbosity, value, @verbosity_atoms)
      _ -> :ok
    end)
  end

  defp validate_atom!(key, value, allowed) when is_atom(value) do
    if value in allowed do
      :ok
    else
      raise ArgumentError,
            "unknown #{key} #{inspect(value)} (legal: #{inspect(allowed)})"
    end
  end

  defp validate_atom!(key, value, allowed) do
    raise ArgumentError,
          "unknown #{key} #{inspect(value)} (legal: #{inspect(allowed)})"
  end

  # Encode the (already-validated) reasoning opts into the wire shape per
  # Decision #5's endpoint-aware routing.
  defp encode_reasoning_opts([], _endpoint, _model), do: []

  defp encode_reasoning_opts(reasoning_opts, :responses, _model) do
    effort = Keyword.get(reasoning_opts, :reasoning_effort)
    summary = Keyword.get(reasoning_opts, :reasoning_summary)
    verbosity = Keyword.get(reasoning_opts, :verbosity)

    sub_map =
      %{}
      |> maybe_atom_to_string(:effort, effort)
      |> maybe_atom_to_string(:summary, summary)

    reasoning = if sub_map == %{}, do: [], else: [reasoning: sub_map]
    verb = if verbosity, do: [verbosity: Atom.to_string(verbosity)], else: []
    reasoning ++ verb
  end

  defp encode_reasoning_opts(reasoning_opts, :chat_completions, model) do
    if is_binary(model) and Regex.match?(@chat_completions_reasoning_models, model) do
      effort = Keyword.get(reasoning_opts, :reasoning_effort)
      verbosity = Keyword.get(reasoning_opts, :verbosity)
      # :reasoning_summary is silently stripped on Chat Completions per
      # Decision #5; the wire does not surface it.
      effort_kv = if effort, do: [reasoning_effort: Atom.to_string(effort)], else: []
      verbosity_kv = if verbosity, do: [verbosity: Atom.to_string(verbosity)], else: []
      effort_kv ++ verbosity_kv
    else
      Logger.debug(fn ->
        "OpenAI: reasoning controls ignored for non-reasoning model #{inspect(model)}"
      end)

      []
    end
  end

  defp maybe_atom_to_string(map, _key, nil), do: map
  defp maybe_atom_to_string(map, key, value), do: Map.put(map, key, Atom.to_string(value))

  @impl ALLM.Adapter
  @doc """
  Build an unfired `%Req.Request{}` with the resolved API key injected as
  `Authorization: Bearer <key>`.

  Per the documented contract: this function **raises**
  `%ALLM.Error.EngineError{reason: :missing_key}` when no key resolver
  yields a value (via `ALLM.Keys.fetch!/2`). Returns
  `{:error, %AdapterError{}}` only for non-key failures (e.g. an o-series
  model routed to `:responses`).

  ## Examples

      iex> ALLM.Keys.put(:openai, "sk-doctest-prep")
      iex> req = ALLM.Request.new([%ALLM.Message{role: :user, content: "hi"}], model: "gpt-4o-mini")
      iex> {:ok, %Req.Request{} = http} = ALLM.Providers.OpenAI.prepare_request(req, [])
      iex> {Req.Request.get_header(http, "authorization"), http.url.path}
      {["Bearer sk-doctest-prep"], "/v1/chat/completions"}
      iex> ALLM.Keys.delete(:openai)
      :ok
  """
  @spec prepare_request(Request.t(), keyword()) ::
          {:ok, Req.Request.t()} | {:error, AdapterError.t()}
  def prepare_request(%Request{} = request, opts) when is_list(opts) do
    endpoint = dispatch_endpoint(request.model, opts)
    do_prepare(request, endpoint, opts)
  end

  defp do_prepare(%Request{} = request, endpoint, opts) do
    # `ALLM.Keys.fetch!/2` raises `%EngineError{reason: :missing_key}` per
    # Decision #16; we deliberately do not rescue.
    api_key = Keys.fetch!(:openai, opts)

    body = to_openai_request_body(request, endpoint, opts)
    url = @base_url <> path_for(endpoint)

    req =
      Req.new(
        method: :post,
        url: url,
        headers: OpenAIHeaders.json_headers(api_key, opts),
        json: body
      )
      |> maybe_apply_req_test_stub(opts)
      |> maybe_apply_request_timeout(opts)

    {:ok, req}
  end

  defp path_for(:chat_completions), do: "/chat/completions"
  defp path_for(:responses), do: "/responses"

  # `Req.Test.stub` integration: if `adapter_opts[:plug]` is supplied (a
  # `Req.Test` stub atom or `{Req.Test, atom}` tuple), wire it into the
  # request via `Req.merge/2`. Used exclusively by
  # `test/allm/providers/openai_wire_test.exs`.
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
  Execute a non-streaming OpenAI Chat Completions request synchronously.

  Wraps the HTTP call in `ALLM.Retry.run/3`; the closure parses
  `Retry-After` headers and returns `{:retry, delay_ms, error}` for
  429/5xx/`:timeout`. Returns `{:ok, %Response{}}` on 2xx success or
  `{:error, %AdapterError{}}` on every failure shape.

  Routes models matching `gpt-5*` or `o[1-9]*` to the Responses API
  (`POST /v1/responses`); other models route to Chat Completions
  (`POST /v1/chat/completions`). Both endpoints return canonical
  `%Response{}` shapes so callers do not need to know which wire ran.

  ## Vision input

  `[%ALLM.TextPart{}, %ALLM.ImagePart{}]` content lists translate to
  OpenAI's content-block wire shape automatically. URL-source images
  pass through verbatim; binary/base64/file sources resolve to a
  `data:<mime>;base64,...` URI via `ALLM.Image.to_data_uri/1`.
  `ImagePart.detail` (`:auto | :low | :high`) maps to the wire string
  via `Atom.to_string/1` and is always emitted. System
  messages remain text-only — an `%ImagePart{}` in a system role is
  hard-rejected as `%ValidationError{reason: :invalid_message}` before
  any HTTP call. Per-image MIME / 20 MB size validation runs in
  pre-flight via `ALLM.Providers.Support.ImageMime`.

  ## Examples

      iex> ALLM.Keys.put(:openai, "sk-doctest-gen")
      iex> req = ALLM.Request.new([%ALLM.Message{role: :user, content: "x"}], model: "gpt-4o-mini")
      iex> {:error, %ALLM.Error.AdapterError{reason: :authentication_failed}} =
      ...> ALLM.Providers.OpenAI.generate(req,
      ...> retry: false,
      ...> adapter_opts: [plug: fn conn ->
      ...> conn
      ...> |> Plug.Conn.put_resp_content_type("application/json")
      ...> |> Plug.Conn.resp(401, ~s({"error":{"message":"bad"}}))
      ...> end]
      ...>)
      iex> ALLM.Keys.delete(:openai)
      :ok

      iex> # Vision pre-flight rejects an ImagePart in a system message.
      iex> img = ALLM.Image.from_url("https://example.com/x.png")
      iex> sys = %ALLM.Message{role: :system, content: [%ALLM.ImagePart{image: img}]}
      iex> req = ALLM.Request.new([sys, %ALLM.Message{role: :user, content: "hi"}], model: "gpt-4o-mini")
      iex> {:error, %ALLM.Error.ValidationError{reason: :invalid_message}} =
      ...> ALLM.Providers.OpenAI.generate(req, api_key: "sk-x")
      iex> :ok
      :ok
  """
  @spec generate(Request.t(), keyword()) ::
          {:ok, Response.t()} | {:error, AdapterError.t() | ValidationError.t()}
  def generate(%Request{} = request, opts) when is_list(opts) do
    with :ok <- reject_image_in_system_messages(request),
         :ok <- ImageMime.validate_request(request, :openai) do
      do_generate(request, opts)
    end
  end

  defp do_generate(%Request{} = request, opts) do
    endpoint = dispatch_endpoint(request.model, opts)
    {:ok, %Req.Request{} = http_req} = prepare_request(request, opts)

    retry_policy = Keyword.get(opts, :retry, :default)
    telemetry_meta = build_retry_telemetry_meta(opts)

    retry_policy
    |> Retry.run(telemetry_meta, fn -> run_one_attempt(http_req, endpoint, opts) end)
    |> unwrap_retry_token()
  end

  # Restore the proper AdapterError reason atom from the retry token's
  # `metadata.final_error` (set by `classify_http_error/3`). When the loop
  # exhausts retries the token surfaces as `{:error, status_int_struct}`;
  # we swap in the original error so callers see the documented reason.
  defp unwrap_retry_token({:ok, _} = ok), do: ok

  defp unwrap_retry_token(
         {:error, %AdapterError{metadata: %{final_error: %AdapterError{} = real}}}
       ),
       do: {:error, real}

  defp unwrap_retry_token({:error, _} = err), do: err

  # One HTTP attempt. Returns one of `{:ok, response}` |
  # `{:retry, delay_ms, error}` | `{:error, error}` per the Retry closure
  # contract (Phase 9.3 Decision #4).
  defp run_one_attempt(http_req, endpoint, opts) do
    case Req.request(http_req) do
      {:ok, %Req.Response{status: status, body: body, headers: _headers}}
      when status in 200..299 ->
        decode_success_body(body, endpoint, opts)

      {:ok, %Req.Response{status: status, body: body, headers: headers}} ->
        classify_http_error(status, body, headers)

      {:error, %{__struct__: Req.TransportError, reason: :timeout} = cause} ->
        timeout_err = AdapterError.new(:timeout, provider: :openai, cause: cause)

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
           provider: :openai,
           message: "transport failure: " <> Exception.message(exception),
           cause: exception
         )}
    end
  end

  # Req auto-decodes `application/json` response bodies so the body is
  # already a map by the time we get here. Malformed JSON surfaces via the
  # `Jason.DecodeError` arm of `run_one_attempt/3`. A non-map body (the
  # provider returned `application/x-empty` or similar) is treated as a
  # malformed response.
  defp decode_success_body(body, :chat_completions, _opts) when is_map(body) do
    {:ok, from_openai_response(body, :chat_completions)}
  end

  defp decode_success_body(body, :responses, opts) when is_map(body) do
    {:ok, from_responses_response(body, opts)}
  end

  defp decode_success_body(other, _endpoint, _opts) do
    {:error, malformed_error({:unexpected_body_shape, other})}
  end

  defp malformed_error(cause) do
    AdapterError.new(:malformed_response,
      provider: :openai,
      message: "OpenAI returned a body that could not be decoded",
      cause: cause
    )
  end

  # 4xx/5xx classifier per the Error Contract table (design §1003-1015).
  # Argument order is `(status, body, headers)` per the Implementation
  # Checklist (`from_openai_error/3`).
  #
  # Retry-token shape: when the failure is retryable we return
  # `{:retry, delay_ms, %AdapterError{reason: status_int_token, ...}}`
  # where `status_int_token` is the literal HTTP status integer (`429`,
  # `500`, ...) so it matches the default `retry_on: [429, 500, 502, 503,
  # 504, :timeout]` set per `ALLM.Retry.error_matches?/2`'s `%{reason:
  # reason}` clause. The "real" `AdapterError` reason atom (`:rate_limited`,
  # `:provider_unavailable`) is restored on the FINAL attempt's `{:error, _}`
  # surface via the `final_error:` metadata key.
  defp classify_http_error(status, body, headers) do
    decoded = decode_error_body(body)
    classified = from_openai_error(status, decoded, headers)

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

  # Req auto-decodes JSON error bodies, so we usually receive a map. Any
  # non-map (empty body, plain-text error page, malformed JSON Req surfaced
  # via its content-type fallback) collapses to `%{}` so `from_openai_error/3`
  # can apply its status-only classifier without crashing.
  defp decode_error_body(body) when is_map(body), do: body
  defp decode_error_body(_), do: %{}

  @doc false
  @spec from_openai_error(non_neg_integer(), map(), Enumerable.t()) :: AdapterError.t()
  def from_openai_error(status, body, headers)
      when is_integer(status) and is_map(body) do
    error = Map.get(body, "error", %{})
    code = Map.get(error, "code")
    type = Map.get(error, "type")
    message = Map.get(error, "message", "OpenAI HTTP #{status}")

    {reason, retry_after} =
      classify_reason(status, code, type, retry_after_ms(headers))

    AdapterError.new(reason,
      provider: :openai,
      status: status,
      retry_after_ms: retry_after,
      message: message,
      metadata: %{openai_code: code, openai_type: type}
    )
  end

  defp classify_reason(401, _code, _type, _ra), do: {:authentication_failed, nil}
  defp classify_reason(403, _code, _type, _ra), do: {:authentication_failed, nil}
  defp classify_reason(429, _code, _type, ra), do: {:rate_limited, ra}

  defp classify_reason(400, "context_length_exceeded", _type, _ra),
    do: {:context_length_exceeded, nil}

  defp classify_reason(400, _code, "content_filter", _ra), do: {:content_filter, nil}

  defp classify_reason(400, _code, type, _ra) when is_binary(type) do
    if String.contains?(type, "content_filter"),
      do: {:content_filter, nil},
      else: {:invalid_request, nil}
  end

  defp classify_reason(400, _code, _type, _ra), do: {:invalid_request, nil}

  defp classify_reason(status, _code, _type, ra) when status in [500, 502, 503, 504],
    do: {:provider_unavailable, ra}

  defp classify_reason(_status, _code, _type, _ra), do: {:unknown, nil}

  # Parse `Retry-After` header per RFC 7231 §7.1.3. Accepts seconds (int)
  # or HTTP-date; returns ms-from-now or `nil` when absent/unparseable.
  defp retry_after_ms(headers) do
    case header_value(headers, "retry-after") do
      nil -> nil
      value -> parse_retry_after(value)
    end
  end

  # Req 0.5+ exposes response headers as `%{lowercase_name => [value, ...]}`;
  # raw transport callbacks may hand us a kwlist or a 2-tuple list. Both
  # shapes are handled.
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

  # Req's header-map values are lists of binaries; raw HTTP libs may hand
  # us a single binary. Take the first when it's a list.
  defp header_value_to_string([v | _]) when is_binary(v), do: v
  defp header_value_to_string(v) when is_binary(v), do: v

  # Per RFC 7231 §7.1.3, Retry-After is either delta-seconds (integer) or
  # an HTTP-date. OpenAI returns delta-seconds in practice (per the live
  # API docs accessed 2026-04-26); we accept the integer form and parse
  # the HTTP-date form via Erlang's `:calendar` if a future provider
  # adopts the date form. Unparseable values return `nil` and the retry
  # loop falls back to its computed exponential backoff.
  defp parse_retry_after(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> seconds * 1_000
      _ -> parse_http_date(value)
    end
  end

  # IMF-fixdate parser without `:inets` dep — handles the most common
  # `"Sun, 06 Nov 1994 08:49:37 GMT"` form. Unrecognized formats → nil.
  defp parse_http_date(_value), do: nil

  defp build_retry_telemetry_meta(opts) do
    %{provider: :openai}
    |> maybe_put_meta(:request_id, Keyword.get(opts, :request_id))
  end

  defp maybe_put_meta(meta, _key, nil), do: meta
  defp maybe_put_meta(meta, key, value), do: Map.put(meta, key, value)

  # ---------------------------------------------------------------------------
  # ALLM.StreamAdapter — stream/2
  # ---------------------------------------------------------------------------

  @impl ALLM.StreamAdapter
  @doc """
  Open a streaming Chat Completions request against the OpenAI provider.

  Returns `{:ok, lazy_enumerable}` on successful pre-flight; the underlying
  `Finch.async_request/3` does NOT fire until the consumer reduces. Returns
  `{:error, %AdapterError{}}` synchronously when pre-flight fails (key
  missing, o-series model, invalid request, etc.). Streaming never wraps in
  `ALLM.Retry.run/3` per the documented contract — partial output may already have been
  delivered before any failure surfaces.

  Per CLAUDE.md and the documented contract, mid-stream failures emit a terminal
  `{:error, _}` event into the enumerable; the consumer's reducer (typically
  `ALLM.StreamCollector`) folds it into `Response.finish_reason: :error`.
  The call-site tuple stays `{:ok, stream}`.

  ## Event sequence

  Happy-path streams emit, in order:

      {:message_started, %{message: %ALLM.Message{role: :assistant, content: ""}}}
      {:text_delta, %{id: id, delta: "..."}} # one or more
      {:tool_call_delta, %{...}} # zero or more (interleaved with text)
      {:tool_call_completed, %{...}} # one per tool call (synthesized at stream end)
      {:message_completed, %{message: msg, finish_reason: reason}}

  The leading `:message_started` is a bookend — `ALLM.StreamCollector` folds
  it as a no-op. Mid-stream errors append a terminal `{:error, _}` event in
  place of (or after) `:message_completed`.

  ## Options

    * `:api_key` / `:adapter_opts[:plug]` — see `prepare_request/2`.
    * `:stream_timeout` — milliseconds to wait between consecutive Finch
      messages. Default `60_000`. Exceeding it emits a terminal
      `{:error, %AdapterError{reason: :timeout}}` event. This is the
      inter-message timer; see `:receive_timeout` for the underlying
      Finch HTTP receive timeout.
    * `:receive_timeout`, `:request_timeout`, `:pool_timeout` —
      forwarded verbatim to `Finch.async_request/3`. Each governs a
      different Finch timer: receive is per-chunk, request is end-to-end
      response receipt, pool is connection acquisition. `:receive_timeout`
      defaults to `stream_timeout + 30_000` — **not** to Finch's 15,000 ms,
      which a reasoning model routinely spends thinking before the first
      SSE chunk — so `:stream_timeout` is the single knob to raise. See
      `ALLM.Providers.Support.Transport`. The other two omit to Finch's
      defaults.
    * `:finch_name` — the registered Finch name (default `ALLM.Finch`).
    * `:finch_module` — the module used to call `async_request/3` and
      `cancel_async_request/1`. Defaults to `Finch`. Tests inject
      `ALLM.Test.FinchStub` here.
    * `:finch_stub_ref` — when `:finch_module` is `ALLM.Test.FinchStub`,
      this ref selects the per-test stub state.

  ## Examples

      iex> req = ALLM.Request.new([%ALLM.Message{role: :user, content: "x"}], model: "gpt-4o-mini")
      iex> {:ok, stream} = ALLM.Providers.OpenAI.stream(req, api_key: "sk-x")
      iex> match?(%Stream{}, stream)
      true
  """
  @spec stream(Request.t(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, AdapterError.t() | ValidationError.t()}
  def stream(%Request{} = request, opts) when is_list(opts) do
    with :ok <- reject_image_in_system_messages(request),
         :ok <- ImageMime.validate_request(request, :openai) do
      do_stream(request, opts)
    end
  end

  defp do_stream(%Request{} = request, opts) do
    # Pre-flight key resolution. `Keys.fetch!/2` raises `%EngineError{}` on
    # missing key — same Decision #16 contract as `prepare_request/2`. We
    # build the streaming body inline (no `Req` involvement on this path).
    endpoint = dispatch_endpoint(request.model, opts)
    api_key = Keys.fetch!(:openai, opts)
    body = to_openai_request_body(request, endpoint, opts) |> Map.put("stream", true)
    json_body = Jason.encode!(body)
    headers = OpenAIHeaders.json_headers(api_key, opts)
    url = @base_url <> path_for(endpoint)

    finch_request = Finch.build(:post, url, headers, json_body)

    finch_module = Keyword.get(opts, :finch_module, Finch)
    finch_name = Keyword.get(opts, :finch_name, ALLM.Finch)

    stream_timeout = Keyword.get(opts, :stream_timeout, @default_stream_timeout)
    finch_extra_opts = Transport.finch_opts(opts, stream_timeout)

    enumerable =
      Stream.resource(
        fn ->
          stream_start_fun(finch_request, finch_module, finch_name, finch_extra_opts, endpoint)
        end,
        fn state -> stream_next_fun(state, stream_timeout) end,
        fn state -> stream_after_fun(state, finch_module) end
      )

    {:ok, enumerable}
  end

  defp stream_start_fun(finch_request, finch_module, finch_name, finch_extra_opts, endpoint) do
    ref = finch_module.async_request(finch_request, finch_name, finch_extra_opts)
    bookend_msg = %Message{role: :assistant, content: ""}

    %{
      ref: ref,
      finch_module: finch_module,
      endpoint: endpoint,
      sse_acc: SSE.new(),
      buffered: [{:message_started, %{message: bookend_msg}}],
      done: false,
      status: nil,
      tool_calls_by_index: %{},
      tool_call_order: [],
      # Bug #5 fix: Responses-API tool-call accumulator. Keys are the
      # provider-assigned `item_id` (e.g. "fc_xxx") rather than integer
      # indices used by Chat Completions, so we keep the maps separate to
      # avoid namespace collisions.
      responses_tool_calls_by_item_id: %{},
      responses_tool_call_item_order: [],
      finish_reason: nil,
      message_completed_emitted?: false,
      accumulated_text: "",
      reasoning_summary: ""
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
      timeout -> finalize_with_error(state, :timeout, "stream_timeout exceeded between events")
    end
  end

  # Handle one Finch payload, returning the next-fun shape.
  # Unknown payload shapes drop through and we recurse to the receive loop
  # via re-buffering an empty list (defensive — Finch's documented shapes
  # are exhaustive).
  defp handle_finch_payload(state, {:status, code}) when code in 200..299 do
    {[], %{state | status: code}}
  end

  defp handle_finch_payload(state, {:status, code}) when is_integer(code) and code >= 400 do
    err = from_openai_error(code, %{}, [])
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
      events = synthesize_tool_call_completions(state) ++ [synthesize_message_completed(state)]
      {events, %{state | message_completed_emitted?: true}}
    end
  end

  defp handle_finch_payload(state, {:error, exception}) do
    err =
      AdapterError.new(:network_error,
        provider: :openai,
        message: "transport failure: " <> Exception.message(exception),
        cause: exception
      )

    finalize_with_event(state, {:error, err})
  end

  defp handle_finch_payload(state, _other), do: {[], state}

  defp finalize_with_error(state, reason, message) do
    err = AdapterError.new(reason, provider: :openai, message: message)
    finalize_with_event(state, {:error, err})
  end

  defp finalize_with_event(state, event) do
    {[event], %{state | done: true}}
  end

  # Decode one Finch :data chunk through SSE, then map each parsed message
  # to ALLM events via chunk_to_events/2. Aggregates the text/tool-call
  # accumulator on the state map. Returns either `{:ok, events, state}`
  # (continue) or `{:terminal, events, state}` (halt next reduce).
  defp decode_sse_chunk(state, chunk) do
    {messages, new_acc} = SSE.decode_chunk(state.sse_acc, chunk)
    state = %{state | sse_acc: new_acc}
    {events, terminal?, new_state} = messages_to_events(messages, state)
    if terminal?, do: {:terminal, events, new_state}, else: {:ok, events, new_state}
  end

  defp messages_to_events(messages, state) do
    Enum.reduce_while(messages, {[], false, state}, fn msg, {events_acc, _term?, st} ->
      case message_to_events(msg, st) do
        {events, false, new_st} ->
          {:cont, {events_acc ++ events, false, new_st}}

        {events, true, new_st} ->
          {:halt, {events_acc ++ events, true, new_st}}
      end
    end)
  end

  # The :done sentinel from SSE.decode_chunk → synthetic :message_completed
  # (when not already emitted), then halt the message stream.
  defp message_to_events(:done, state) do
    if state.message_completed_emitted? do
      {[], true, %{state | done: true}}
    else
      events = synthesize_tool_call_completions(state) ++ [synthesize_message_completed(state)]
      {events, true, %{state | done: true, message_completed_emitted?: true}}
    end
  end

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
  # on `state.endpoint` because Responses uses semantic SSE event names
  # (consumed via `sse_msg.event`) while Chat Completions emits one
  # delta-shape per `data:` payload. Returns `{events, terminal?, new_state}`.
  @doc false
  @spec chunk_to_events(map(), map(), map()) :: {[Event.t()], boolean(), map()}
  def chunk_to_events(decoded, sse_msg, %{endpoint: :responses} = state) do
    responses_chunk_to_events(sse_msg.event, decoded, state)
  end

  def chunk_to_events(decoded, _sse_msg, state) do
    chat_completions_chunk_to_events(decoded, state)
  end

  defp chat_completions_chunk_to_events(%{} = decoded, state) do
    usage = decoded["usage"]
    choices = decoded["choices"] || []

    {events, state} = process_choice(List.first(choices), state)
    {events, state} = maybe_append_usage(events, state, usage)

    terminal? = state.finish_reason == :content_filter
    {events, terminal?, state}
  end

  # Responses-API SSE event mapping (Decision #5 + Phase 10.6).
  # The named event types we recognize:
  #   * response.output_text.delta          → :text_delta
  #   * response.reasoning_summary.delta    → accumulate into state.reasoning_summary
  #   * response.completed                  → synthesize :message_completed
  #   * response.error                      → terminal {:error, _}
  # Unknown event names are dropped (defensive — OpenAI may add new ones).
  defp responses_chunk_to_events("response.output_text.delta", decoded, state) do
    delta = decoded["delta"] || ""

    if delta == "" do
      {[], false, state}
    else
      events = [{:text_delta, %{id: nil, delta: delta}}]
      new_state = %{state | accumulated_text: state.accumulated_text <> delta}
      {events, false, new_state}
    end
  end

  defp responses_chunk_to_events("response.reasoning_summary.delta", decoded, state) do
    delta = decoded["delta"] || ""
    new_state = %{state | reasoning_summary: state.reasoning_summary <> delta}
    {[], false, new_state}
  end

  defp responses_chunk_to_events("response.completed", decoded, state) do
    # Pull final status / incomplete_details / usage off the embedded
    # response object when present — provides the canonical finish_reason
    # for the synthetic :message_completed event.
    response_obj = decoded["response"] || %{}
    {finish_reason, _raw} = map_responses_status(response_obj)
    state = Map.put(state, :finish_reason, finish_reason)
    usage_events = responses_usage_events(response_obj)

    if state.message_completed_emitted? do
      {usage_events, true, %{state | done: true}}
    else
      events = usage_events ++ synthesize_responses_completed(state)
      {events, true, %{state | done: true, message_completed_emitted?: true}}
    end
  end

  defp responses_chunk_to_events("response.error", decoded, state) do
    err =
      AdapterError.new(:provider_unavailable,
        provider: :openai,
        message: "OpenAI Responses API surfaced response.error mid-stream",
        cause: decoded["error"] || decoded
      )

    {[{:error, err}], true, %{state | done: true}}
  end

  # Bug #5 fix — Responses-API streaming tool calls (Phase 10 retro).
  # OpenAI's Responses streaming wraps function calls in a three-phase
  # lifecycle that does NOT mirror Chat Completions:
  #
  #   * `response.output_item.added` — a new output item is opening; the
  #     embedded `item.type` tells us whether it's a `function_call` (start
  #     of a tool call) or a `message` (start of an assistant text item).
  #     For function_call items we register the item_id and emit
  #     `:tool_call_started`.
  #   * `response.function_call_arguments.delta` — incremental JSON-string
  #     fragments for one in-flight function_call; we identify which call
  #     by the `item_id` (or `output_index`) field.
  #   * `response.output_item.done` — the item has reached its final form;
  #     the embedded `item` carries the full `arguments` string. We use it
  #     as the canonical source for the close-out event payload.
  defp responses_chunk_to_events("response.output_item.added", decoded, state) do
    item = decoded["item"] || %{}

    if item["type"] == "function_call" do
      handle_responses_function_call_added(item, decoded, state)
    else
      {[], false, state}
    end
  end

  defp responses_chunk_to_events("response.function_call_arguments.delta", decoded, state) do
    item_id = decoded["item_id"] || decoded["output_index"] || ""
    delta = decoded["delta"] || ""

    case Map.get(state.responses_tool_calls_by_item_id, item_id) do
      nil ->
        # Delta arrived before the corresponding `output_item.added` (or for
        # an item we don't track) — drop defensively.
        {[], false, state}

      partial ->
        handle_responses_function_call_delta(item_id, delta, partial, state)
    end
  end

  defp responses_chunk_to_events("response.output_item.done", decoded, state) do
    item = decoded["item"] || %{}

    if item["type"] == "function_call" do
      handle_responses_function_call_done(item, decoded, state)
    else
      {[], false, state}
    end
  end

  defp responses_chunk_to_events(_event, _decoded, state), do: {[], false, state}

  # Bug #5 fix: register a freshly-opened function_call item AND emit the
  # canonical `:tool_call_started` event when the wire surfaced both a
  # binary call_id AND a binary name (defensive — partial frames are dropped
  # silently rather than emitting a malformed event).
  defp handle_responses_function_call_added(item, decoded, state) do
    item_id = item["id"] || decoded["item_id"] || ""
    call_id = item["call_id"] || item_id
    name = item["name"] || ""

    partial = %{call_id: call_id, name: name, raw_args: ""}

    new_state = %{
      state
      | responses_tool_calls_by_item_id:
          Map.put(state.responses_tool_calls_by_item_id, item_id, partial),
        responses_tool_call_item_order: state.responses_tool_call_item_order ++ [item_id]
    }

    events =
      if is_binary(call_id) and call_id != "" and is_binary(name) and name != "" do
        [{:tool_call_started, %{id: call_id, name: name}}]
      else
        []
      end

    {events, false, new_state}
  end

  defp handle_responses_function_call_delta(item_id, delta, partial, state) do
    %{call_id: call_id, raw_args: raw_args} = partial
    updated = %{partial | raw_args: raw_args <> (delta || "")}

    new_state = %{
      state
      | responses_tool_calls_by_item_id:
          Map.put(state.responses_tool_calls_by_item_id, item_id, updated)
    }

    events =
      if is_binary(call_id) and call_id != "" and is_binary(delta) and delta != "" do
        [{:tool_call_delta, %{id: call_id, arguments_delta: delta}}]
      else
        []
      end

    {events, false, new_state}
  end

  # Per spec §8 the canonical close-out event for a tool call is
  # `:tool_call_completed` — emitted lazily from
  # `synthesize_responses_completed/1` when the response finishes,
  # mirroring the Chat-Completions close-out path. We emit nothing here so
  # the close-out remains a single batch at end-of-stream.
  defp handle_responses_function_call_done(item, decoded, state) do
    item_id = item["id"] || decoded["item_id"] || ""
    call_id = item["call_id"] || item_id
    name = item["name"] || ""
    raw_args = item["arguments"] || ""

    existing = Map.get(state.responses_tool_calls_by_item_id, item_id, %{})

    merged = %{
      call_id: call_id,
      name: existing[:name] || name,
      # Prefer the final-form arguments string when present; fall back to
      # whatever we accumulated from the delta stream.
      raw_args: pick_responses_raw_args(raw_args, existing)
    }

    item_order =
      if item_id in state.responses_tool_call_item_order do
        state.responses_tool_call_item_order
      else
        state.responses_tool_call_item_order ++ [item_id]
      end

    new_state = %{
      state
      | responses_tool_calls_by_item_id:
          Map.put(state.responses_tool_calls_by_item_id, item_id, merged),
        responses_tool_call_item_order: item_order
    }

    {[], false, new_state}
  end

  defp pick_responses_raw_args(raw_args, _existing) when is_binary(raw_args) and raw_args != "",
    do: raw_args

  defp pick_responses_raw_args(_raw_args, existing), do: existing[:raw_args] || ""

  # Build a synthetic :message_completed event for the Responses path that
  # carries any accumulated reasoning summary on the message.metadata so
  # StreamCollector folds it onto Response.metadata.reasoning.summary.
  #
  # Bug #5 fix: when the stream surfaced one or more `function_call` output
  # items, prepend the canonical `:tool_call_completed` events (one per
  # item, in the order they appeared on the wire) AND promote the
  # finish_reason to `:tool_calls` if the stream's status mapped to
  # `:stop` — mirrors the non-streaming path and the Chat-Completions
  # close-out (Phase 10.3).
  defp synthesize_responses_completed(state) do
    tool_call_events = synthesize_responses_tool_call_completions(state)

    finish_reason =
      if state.finish_reason == :stop and tool_call_events != [] do
        :tool_calls
      else
        state.finish_reason
      end

    msg = %Message{role: :assistant, content: state.accumulated_text}

    metadata =
      if state.reasoning_summary == "" do
        %{}
      else
        %{reasoning: %{summary: state.reasoning_summary}}
      end

    tool_call_events ++
      [{:message_completed, %{message: msg, finish_reason: finish_reason, metadata: metadata}}]
  end

  # Emit one `:tool_call_completed` event per accumulated Responses-API
  # `function_call` item, in wire-order. Each event carries the parsed
  # arguments map AND the raw arguments string so StreamCollector can fold
  # them onto `Response.tool_calls` with full fidelity.
  defp synthesize_responses_tool_call_completions(state) do
    Enum.flat_map(state.responses_tool_call_item_order, fn item_id ->
      partial = Map.fetch!(state.responses_tool_calls_by_item_id, item_id)

      raw = partial.raw_args || ""
      call_id = partial.call_id || ""
      name = partial.name || ""

      args =
        case Jason.decode(raw) do
          {:ok, %{} = parsed} -> parsed
          _ -> %{}
        end

      [{:tool_call_completed, %{id: call_id, name: name, arguments: args, raw_arguments: raw}}]
    end)
  end

  # Emit a `:raw_chunk {:usage, _}` event when the `response.completed` payload
  # carries a `usage` block (gpt-5* and other modern Responses models include
  # it). `StreamCollector` folds the map through `struct!(%Usage{}, _)`, so
  # keys MUST be `%Usage{}` field names. Shape matches `decode_responses_usage/1`
  # so streaming and non-streaming paths produce identical `%Usage{}` structs.
  defp responses_usage_events(%{"usage" => %{} = usage}) do
    pre_mapped = %{
      input_tokens: usage["input_tokens"],
      output_tokens: usage["output_tokens"],
      total_tokens: usage["total_tokens"],
      reasoning_tokens: extract_reasoning_tokens(usage, "output_tokens_details"),
      extra:
        Map.drop(usage, [
          "input_tokens",
          "output_tokens",
          "total_tokens",
          "output_tokens_details"
        ])
    }

    [{:raw_chunk, {:usage, pre_mapped}}]
  end

  defp responses_usage_events(_), do: []

  defp process_choice(nil, state), do: {[], state}

  defp process_choice(%{} = choice, state) do
    delta = choice["delta"] || %{}
    finish_raw = choice["finish_reason"]

    {events, state} = append_text_delta([], delta, state)
    {events, state} = append_tool_call_events(events, delta, state)

    apply_finish_reason(events, state, finish_raw)
  end

  defp apply_finish_reason(events, state, nil), do: {events, state}

  defp apply_finish_reason(events, state, finish_raw) do
    {fr, _raw} = map_chat_finish_reason(finish_raw)

    if fr == :content_filter do
      err =
        AdapterError.new(:content_filter,
          provider: :openai,
          message: "OpenAI signalled content_filter mid-stream"
        )

      {events ++ [{:error, err}], %{state | finish_reason: :content_filter}}
    else
      {events, %{state | finish_reason: fr}}
    end
  end

  defp append_text_delta(events, delta, state) do
    case delta["content"] do
      content when is_binary(content) and content != "" ->
        {events ++ [{:text_delta, %{id: nil, delta: content}}],
         %{state | accumulated_text: state.accumulated_text <> content}}

      _ ->
        {events, state}
    end
  end

  defp append_tool_call_events(events, delta, state) do
    case delta["tool_calls"] do
      list when is_list(list) -> Enum.reduce(list, {events, state}, &fold_tool_call_delta/2)
      _ -> {events, state}
    end
  end

  defp fold_tool_call_delta(%{} = tc, {events, state}) do
    index = tc["index"] || 0
    existing = Map.get(state.tool_calls_by_index, index)
    parts = extract_tool_call_parts(tc)

    if is_nil(existing) do
      first_tool_call_appearance(events, state, index, parts)
    else
      subsequent_tool_call_delta(events, state, index, existing, parts)
    end
  end

  defp extract_tool_call_parts(%{} = tc) do
    function = tc["function"] || %{}
    %{id: tc["id"], name: function["name"], args_fragment: function["arguments"]}
  end

  defp first_tool_call_appearance(events, state, index, parts) do
    %{id: id, name: name, args_fragment: args_fragment} = parts
    partial = %{id: id, name: name, raw_args: args_fragment || ""}

    state = %{
      state
      | tool_calls_by_index: Map.put(state.tool_calls_by_index, index, partial),
        tool_call_order: state.tool_call_order ++ [index]
    }

    events =
      events
      |> append_started(id, name)
      |> append_delta(id, args_fragment)

    {events, state}
  end

  defp subsequent_tool_call_delta(events, state, index, existing, parts) do
    %{id: id, name: name, args_fragment: args_fragment} = parts
    new_id = existing.id || id
    new_name = existing.name || name
    new_raw = (existing.raw_args || "") <> (args_fragment || "")

    partial = %{id: new_id, name: new_name, raw_args: new_raw}
    state = %{state | tool_calls_by_index: Map.put(state.tool_calls_by_index, index, partial)}

    events = append_delta(events, new_id, args_fragment)
    {events, state}
  end

  defp append_started(events, id, name) when is_binary(id) and is_binary(name),
    do: events ++ [{:tool_call_started, %{id: id, name: name}}]

  defp append_started(events, _id, _name), do: events

  defp append_delta(events, id, fragment)
       when is_binary(id) and is_binary(fragment) and fragment != "",
       do: events ++ [{:tool_call_delta, %{id: id, arguments_delta: fragment}}]

  defp append_delta(events, _id, _fragment), do: events

  defp maybe_append_usage(events, state, nil), do: {events, state}

  defp maybe_append_usage(events, state, %{} = usage_map) do
    pre_mapped = %{
      input_tokens: usage_map["prompt_tokens"],
      output_tokens: usage_map["completion_tokens"],
      total_tokens: usage_map["total_tokens"]
    }

    {events ++ [{:raw_chunk, {:usage, pre_mapped}}], state}
  end

  # after_fun: cancel only when state.done == false (Decision #4a).
  defp stream_after_fun(%{done: true}, _finch_module), do: :ok

  defp stream_after_fun(%{ref: ref, finch_module: finch_module}, _) do
    finch_module.cancel_async_request(ref)
    :ok
  rescue
    _ -> :ok
  end

  # Synthesize :tool_call_completed events for every accumulated tool-call
  # index. Called from the :done-sentinel and Finch-:done paths so consumers
  # see the canonical close-out shape regardless of whether OpenAI sent
  # explicit tool_call completion frames (it doesn't — only finish_reason).
  defp synthesize_tool_call_completions(state) do
    Enum.flat_map(state.tool_call_order, fn idx ->
      partial = Map.fetch!(state.tool_calls_by_index, idx)

      raw = partial.raw_args || ""
      id = partial.id || ""
      name = partial.name || ""

      args =
        case Jason.decode(raw) do
          {:ok, %{} = parsed} -> parsed
          _ -> %{}
        end

      [{:tool_call_completed, %{id: id, name: name, arguments: args, raw_arguments: raw}}]
    end)
  end

  defp synthesize_message_completed(state) do
    msg = %Message{role: :assistant, content: state.accumulated_text}
    {:message_completed, %{message: msg, finish_reason: state.finish_reason}}
  end

  # ---------------------------------------------------------------------------
  # Body composition (Chat Completions; Responses lands in Phase 10.6)
  # ---------------------------------------------------------------------------

  @doc false
  @spec to_openai_request_body(Request.t(), endpoint(), keyword()) :: map()
  def to_openai_request_body(%Request{} = request, :chat_completions, opts) do
    base = %{
      "model" => request.model,
      "messages" => to_openai_messages(request.messages)
    }

    base
    |> maybe_put("temperature", request.temperature)
    |> maybe_put_max_tokens(request, :chat_completions, opts)
    |> maybe_put_tools(request.tools, :chat_completions)
    |> maybe_put_tool_choice(request.tool_choice, :chat_completions)
    |> maybe_put_response_format(request, :chat_completions)
    |> Map.merge(stringify_options(request.options))
    |> merge_reasoning_opts(request, :chat_completions, opts)
  end

  # Phase 10.6 — Responses-API body builder. The wire shape differs from
  # Chat Completions: `input:` (array of `{role, content}` items, NOT
  # `messages:`); `text:` carries response_format; `reasoning:` and
  # `verbosity:` carry reasoning controls; `max_output_tokens:` (renamed
  # from `:max_tokens` per Decision #6).
  def to_openai_request_body(%Request{} = request, :responses, opts) do
    base = %{
      "model" => request.model,
      "input" => to_responses_input(request.messages)
    }

    base
    |> maybe_put("temperature", request.temperature)
    |> maybe_put_max_tokens(request, :responses, opts)
    |> maybe_put_tools(request.tools, :responses)
    |> maybe_put_tool_choice(request.tool_choice, :responses)
    |> maybe_put_response_format(request, :responses)
    |> Map.merge(stringify_options(request.options))
    |> merge_reasoning_opts(request, :responses, opts)
  end

  # Read reasoning controls from the caller-supplied `opts` keyword
  # (engine `params:` flattens into `opts` per
  # `ALLM.Engine.resolve_params/2`); route them through the (already
  # resolved) `endpoint` so the wire shape per Decision #5 is endpoint-aware.
  #
  # Threaded through from `to_openai_request_body/3` so we never re-resolve
  # the endpoint here — Bug #3 (Phase 10.5 retro): the prior implementation
  # called `translate_options/2` with only the reasoning kwlist, which
  # stripped the caller's `adapter_opts: [endpoint: ...]` override, so an
  # explicit `:chat_completions` request on `gpt-5*` still emitted the
  # Responses-shaped `reasoning: %{effort: ...}` map.
  @doc false
  # Accessor so `ALLM.Chat.@request_carried_keys` can DERIVE (not re-type) the
  # reasoning-control keys it must strip from `request.options`. Promoting this
  # inline `Keyword.take/2` list to a named, referenced attribute closes the
  # blind spot behind the Phase 21.4 Responses double-route leak.
  @spec reasoning_opts() :: [atom()]
  def reasoning_opts, do: @reasoning_opts

  defp merge_reasoning_opts(body, %Request{} = request, endpoint, opts) when is_list(opts) do
    relevant = Keyword.take(opts, @reasoning_opts)

    case relevant do
      [] ->
        body

      _ ->
        validate_reasoning_opts!(relevant)
        wire = encode_reasoning_opts(relevant, endpoint, request.model)
        Map.merge(body, stringify_options(Map.new(wire)))
    end
  end

  # Convert a list of `%Message{}` to the Responses-API `input:` array
  # shape (Decision #1 + Invariant #13). Roles are mostly unchanged from
  # Chat Completions, but tool round-trips use a different shape: assistant
  # tool_calls become `{"type":"function_call","call_id":...,...}` items
  # and the eventual `:tool` reply becomes a
  # `{"type":"function_call_output","call_id":...,"output":...}` item.
  # See spec §6 + Bug #5 (Phase 10 retro).
  @doc false
  @spec to_responses_input([Message.t()]) :: [map()]
  def to_responses_input(messages) when is_list(messages) do
    Enum.flat_map(messages, &to_responses_input_items/1)
  end

  defp to_responses_input_items(%Message{role: :tool, content: c, tool_call_id: tcid}) do
    [%{"type" => "function_call_output", "call_id" => tcid, "output" => stringify_content(c)}]
  end

  defp to_responses_input_items(%Message{role: :assistant, content: c, metadata: meta} = msg) do
    case Map.get(meta, :tool_calls) do
      nil -> [responses_simple_input_item(msg)]
      [] -> [responses_simple_input_item(msg)]
      calls -> responses_assistant_with_tool_calls(c, calls)
    end
  end

  defp to_responses_input_items(%Message{} = msg) do
    [responses_simple_input_item(msg)]
  end

  defp responses_simple_input_item(%Message{role: :user, content: c}) do
    %{"role" => "user", "content" => user_content(c, :responses)}
  end

  defp responses_simple_input_item(%Message{role: :assistant, content: c}) do
    %{"role" => "assistant", "content" => assistant_content(c, :responses)}
  end

  defp responses_simple_input_item(%Message{role: role, content: c}) do
    %{"role" => Atom.to_string(role), "content" => stringify_content(c)}
  end

  # An assistant turn that produced tool_calls splits into (optionally) a
  # message item carrying any free text the model emitted alongside the
  # tool calls, followed by one `function_call` item per call. Empty-string
  # content is omitted to keep parity with the Chat Completions wire shape.
  defp responses_assistant_with_tool_calls(content, calls) do
    text_item =
      case stringify_content(content) do
        "" -> []
        text -> [%{"role" => "assistant", "content" => text}]
      end

    call_items =
      Enum.map(calls, fn %ToolCall{id: id, name: name, raw_arguments: raw, arguments: args} ->
        %{
          "type" => "function_call",
          "call_id" => id,
          "name" => name,
          "arguments" => raw || Jason.encode!(args)
        }
      end)

    text_item ++ call_items
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_max_tokens(map, %Request{max_tokens: nil}, _endpoint, _opts), do: map

  defp maybe_put_max_tokens(map, %Request{max_tokens: mt} = req, endpoint, _opts) do
    # Phase 10.5 retro fix: project the rename using the resolved
    # `endpoint` directly rather than re-resolving via `translate_options/2`
    # (which would otherwise re-call `dispatch_endpoint/2` without the
    # caller's `adapter_opts: [endpoint: ...]` override in scope).
    {key, value} = rename_option({:max_tokens, mt}, endpoint, req.model)
    Map.put(map, Atom.to_string(key), value)
  end

  defp maybe_put_tools(map, [], _endpoint), do: map

  defp maybe_put_tools(map, tools, endpoint) when is_list(tools) do
    Map.put(map, "tools", Enum.map(tools, &to_openai_tool(&1, endpoint)))
  end

  # Endpoint-aware tool envelope (Phase 10.5 retro Bug #2):
  #
  #   * `:chat_completions` — nests under `function:` per the Chat Completions
  #     wire (`{"type":"function","function":{"name":...,"parameters":...}}`).
  #   * `:responses` — flat top-level keys per the Responses wire
  #     (`{"type":"function","name":...,"parameters":...}`); the nested form
  #     is rejected with `Missing required parameter: 'tools[0].name'`.
  defp to_openai_tool(%ALLM.Tool{name: name, description: desc, schema: schema}, :chat_completions) do
    %{
      "type" => "function",
      "function" => %{
        "name" => name,
        "description" => desc,
        "parameters" => schema
      }
    }
  end

  defp to_openai_tool(%ALLM.Tool{name: name, description: desc, schema: schema}, :responses) do
    %{
      "type" => "function",
      "name" => name,
      "description" => desc,
      "parameters" => schema
    }
  end

  defp maybe_put_tool_choice(map, nil, _endpoint), do: map
  defp maybe_put_tool_choice(map, :auto, _endpoint), do: Map.put(map, "tool_choice", "auto")
  defp maybe_put_tool_choice(map, :none, _endpoint), do: Map.put(map, "tool_choice", "none")

  defp maybe_put_tool_choice(map, :required, _endpoint),
    do: Map.put(map, "tool_choice", "required")

  # `{:tool, name}` tuple form (Phase 10.5 retro Bug #4): a forced-tool
  # selection by name. Wire shape mirrors `to_openai_tool/2`'s endpoint
  # split — Chat Completions nests under `function:`; Responses uses flat
  # top-level `name:`.
  defp maybe_put_tool_choice(map, {:tool, name}, endpoint) when is_binary(name) do
    maybe_put_tool_choice(map, name, endpoint)
  end

  defp maybe_put_tool_choice(map, name, :chat_completions) when is_binary(name) do
    Map.put(map, "tool_choice", %{
      "type" => "function",
      "function" => %{"name" => name}
    })
  end

  defp maybe_put_tool_choice(map, name, :responses) when is_binary(name) do
    Map.put(map, "tool_choice", %{
      "type" => "function",
      "name" => name
    })
  end

  defp maybe_put_tool_choice(map, %{} = explicit, _endpoint),
    do: Map.put(map, "tool_choice", explicit)

  defp maybe_put_response_format(map, %Request{response_format: rf}, endpoint) do
    case to_openai_response_format(endpoint, rf) do
      nil -> map
      {key, value} when is_atom(key) -> Map.put(map, Atom.to_string(key), value)
    end
  end

  defp stringify_options(options) when is_map(options) do
    Map.new(options, fn {k, v} -> {to_string_key(k), v} end)
  end

  defp to_string_key(k) when is_atom(k), do: Atom.to_string(k)
  defp to_string_key(k) when is_binary(k), do: k

  @doc false
  @spec to_openai_messages([Message.t()]) :: [map()]
  def to_openai_messages(messages) when is_list(messages) do
    Enum.map(messages, &to_openai_message/1)
  end

  defp to_openai_message(%Message{role: :tool, content: c, tool_call_id: tcid}) do
    # Tool-result content is text-only on OpenAI's wire (no multimodal
    # tool results in v0.3); use `stringify_content/1` to flatten any
    # text-only content list.
    %{
      "role" => "tool",
      "content" => stringify_content(c),
      "tool_call_id" => tcid
    }
  end

  defp to_openai_message(%Message{role: :assistant, content: c, metadata: meta}) do
    base = %{"role" => "assistant", "content" => assistant_content(c, :chat_completions)}

    case Map.get(meta, :tool_calls) do
      nil -> base
      [] -> base
      calls -> Map.put(base, "tool_calls", Enum.map(calls, &tool_call_to_wire/1))
    end
  end

  defp to_openai_message(%Message{role: :system, content: c}) do
    # System messages remain text-only by Phase 17 design Out-of-scope #2;
    # `reject_image_in_system_messages/1` guards upstream of the wire.
    %{"role" => "system", "content" => stringify_content(c)}
  end

  defp to_openai_message(%Message{role: :user, content: c}) do
    %{"role" => "user", "content" => user_content(c, :chat_completions)}
  end

  # User-side content emission (Phase 17.1):
  #   - binary  → forwarded verbatim (v0.2 backward-compat)
  #   - list with any %ImagePart{} → translated to content-block list
  #   - list with only %TextPart{} → flattened to joined text (preserves
  #     Phase 14.4 wire-shape: tests assert `content: "a\nb"`)
  defp user_content(c, _endpoint) when is_binary(c) or is_nil(c), do: stringify_content(c)

  defp user_content(parts, endpoint) when is_list(parts) do
    if Enum.any?(parts, &match?(%ImagePart{}, &1)) do
      to_openai_content_blocks(parts, endpoint)
    else
      stringify_content(parts)
    end
  end

  # Assistant-side content for a request (i.e. `messages[]` echoed back to
  # the model from `Thread.messages`). Multi-turn vision typically only
  # carries images in the user role; assistant content remains text in
  # practice. Mirror `user_content/2` for safety.
  defp assistant_content(c, endpoint), do: user_content(c, endpoint)

  defp tool_call_to_wire(%ToolCall{id: id, name: name, raw_arguments: raw, arguments: args}) do
    arg_string = raw || Jason.encode!(args)

    %{
      "id" => id,
      "type" => "function",
      "function" => %{"name" => name, "arguments" => arg_string}
    }
  end

  defp stringify_content(c) when is_binary(c), do: c
  defp stringify_content(nil), do: ""

  # Flatten a text-only content list (Phase 14.4 Decision #14(b)).
  # Image-bearing lists are routed through `to_openai_content_blocks/2`
  # by `user_content/2`/`assistant_content/2` BEFORE reaching this helper;
  # tool/system role messages always carry text or text-only lists.
  defp stringify_content(parts) when is_list(parts) do
    Enum.map_join(parts, "\n", &materialize_part/1)
  end

  defp materialize_part(%TextPart{text: t}), do: t
  # Defensive: ImagePart should be filtered upstream for tool/system
  # contexts; render to empty string rather than raising — text-only
  # contexts that accidentally see one degrade gracefully.
  # Cross-adapter divergence note: Anthropic still raises here as of
  # Phase 17.1 (out of 17.1 scope per Phase 17 design). See retro
  # 2026-04-30 finding 5 — Phase 17.2 should adopt this same
  # graceful-empty-string contract for symmetry.
  defp materialize_part(%ImagePart{}), do: ""

  defp materialize_part(other) do
    raise ArgumentError,
          "stringify_content/1 expects a TextPart; got: #{inspect(other)}"
  end

  # Phase 17.1 — system-message ImagePart rejection (design Decision #7,
  # Q1 lock-in). System messages are text-only in v0.3; an ImagePart in
  # a system role is a hard reject before any other validation runs.
  # See spec §35.6 Out-of-scope #2.
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

  # Phase 17.1 — content-block translator (design §3.2). Both endpoints
  # flow list-shaped content lists through this; the endpoint atom
  # selects the wire-shape divergence:
  #
  #   * `:chat_completions` — `{type: "image_url", image_url: %{url, detail}}`
  #     (detail nested in image_url map).
  #   * `:responses` — `{type: "input_image", image_url, detail}`
  #     (detail at sibling level).
  #
  # Mirror invariant: `to_openai_message/1` (Chat Completions) and
  # `responses_simple_input_item/1` (Responses) BOTH route list content
  # through `user_content/2` → `to_openai_content_blocks/2`.
  @spec to_openai_content_blocks(
          [TextPart.t() | ImagePart.t()],
          :chat_completions | :responses
        ) :: [map()]
  defp to_openai_content_blocks(parts, endpoint) when is_list(parts) do
    Enum.map(parts, &part_to_block(&1, endpoint))
  end

  defp part_to_block(%TextPart{text: t}, :chat_completions),
    do: %{"type" => "text", "text" => t}

  defp part_to_block(%TextPart{text: t}, :responses),
    do: %{"type" => "input_text", "text" => t}

  # URL fast-path: forward as a URL string; never call `to_data_uri/1`
  # (which returns `{:error, :remote_source}` for `{:url, _}` sources).
  defp part_to_block(
         %ImagePart{image: %Image{source: {:url, u}}, detail: d},
         :chat_completions
       ) do
    %{
      "type" => "image_url",
      "image_url" => %{"url" => u, "detail" => Atom.to_string(d)}
    }
  end

  defp part_to_block(%ImagePart{image: img, detail: d}, :chat_completions) do
    {:ok, uri} = Image.to_data_uri(img)

    %{
      "type" => "image_url",
      "image_url" => %{"url" => uri, "detail" => Atom.to_string(d)}
    }
  end

  defp part_to_block(
         %ImagePart{image: %Image{source: {:url, u}}, detail: d},
         :responses
       ) do
    %{
      "type" => "input_image",
      "image_url" => u,
      "detail" => Atom.to_string(d)
    }
  end

  defp part_to_block(%ImagePart{image: img, detail: d}, :responses) do
    {:ok, uri} = Image.to_data_uri(img)

    %{
      "type" => "input_image",
      "image_url" => uri,
      "detail" => Atom.to_string(d)
    }
  end

  # Phase 10.6 will land the Responses-API `input:` encoder; the design
  # called for a Phase 10.2 stub but the dead branch trips dialyzer's
  # pattern-coverage analysis. Re-introduced in 10.6 with full reasoning
  # control plumbing.

  @doc """
  Endpoint-aware translation of a canonical `response_format` shape to
  OpenAI's wire format.and design the documented contract.

  Returns either `nil` (omit the field on the wire) OR a
  `{wire_key, wire_value}` 2-tuple where `wire_key` is the JSON body key
  to merge into the request body (`:response_format` on Chat Completions,
  `:text` on Responses).

  Raises `FunctionClauseError` on any other canonical shape — defense in
  depth: `ALLM.Validate.request/1` should have rejected the shape upstream.

  ## Examples

      iex> ALLM.Providers.OpenAI.to_openai_response_format(:chat_completions, nil)
      nil

      iex> ALLM.Providers.OpenAI.to_openai_response_format(:chat_completions, %{type: :json_object})
      {:response_format, %{type: "json_object"}}

      iex> rf = %{type: :json_schema, name: "g", schema: %{type: "object"}, strict: true}
      iex> ALLM.Providers.OpenAI.to_openai_response_format(:chat_completions, rf)
      {:response_format, %{type: "json_schema", json_schema: %{name: "g", schema: %{type: "object"}, strict: true}}}

      iex> ALLM.Providers.OpenAI.to_openai_response_format(:responses, :text)
      {:text, %{format: %{type: "text"}}}
  """
  @spec to_openai_response_format(endpoint(), Request.response_format()) ::
          {atom(), map()} | nil
  def to_openai_response_format(_endpoint, nil), do: nil

  # `:text` canonical: Chat Completions defaults to text, so we omit;
  # Responses requires explicit `text: %{format: %{type: "text"}}`.
  def to_openai_response_format(:chat_completions, :text), do: nil

  def to_openai_response_format(:responses, :text),
    do: {:text, %{format: %{type: "text"}}}

  def to_openai_response_format(:chat_completions, %{type: :json_object}),
    do: {:response_format, %{type: "json_object"}}

  def to_openai_response_format(:responses, %{type: :json_object}),
    do: {:text, %{format: %{type: "json_object"}}}

  def to_openai_response_format(
        :chat_completions,
        %{type: :json_schema, name: name, schema: schema, strict: strict}
      ) do
    {:response_format,
     %{
       type: "json_schema",
       json_schema: %{name: name, schema: schema, strict: strict}
     }}
  end

  def to_openai_response_format(
        :responses,
        %{type: :json_schema, name: name, schema: schema, strict: strict}
      ) do
    {:text, %{format: %{type: "json_schema", name: name, schema: schema, strict: strict}}}
  end

  # ---------------------------------------------------------------------------
  # Response decoding
  # ---------------------------------------------------------------------------

  @doc false
  @spec from_openai_response(map(), endpoint()) :: Response.t()
  def from_openai_response(%{} = body, :chat_completions) do
    choices = Map.get(body, "choices", [])
    first = List.first(choices) || %{}
    message_map = Map.get(first, "message", %{})
    raw_finish = Map.get(first, "finish_reason")

    {finish_reason, raw_keep} = map_chat_finish_reason(raw_finish)

    tool_calls = decode_tool_calls(Map.get(message_map, "tool_calls", []))
    raw_content = Map.get(message_map, "content")
    content = decode_assistant_content(raw_content)

    message = %Message{
      role: :assistant,
      content: content || "",
      metadata: tool_calls_metadata(tool_calls)
    }

    %Response{
      id: Map.get(body, "id"),
      model: Map.get(body, "model"),
      message: message,
      output_text: assistant_output_text(content),
      tool_calls: tool_calls,
      finish_reason: finish_reason,
      raw_finish_reason: raw_keep,
      usage: decode_usage(Map.get(body, "usage", %{})),
      raw: body,
      metadata: %{}
    }
  end

  # Phase 17.1 (Decision #11) — assistant-side ImagePart decoding.
  # Chat Completions's `choices[0].message.content` is usually a string,
  # but the decoder accepts a list-shaped content block array for forward
  # compat with multimodal-output models. Each block decodes to a
  # `%TextPart{}` or `%ImagePart{}`; unknown block types fall through to
  # an empty TextPart so the decode is total.
  defp decode_assistant_content(content) when is_binary(content), do: content
  defp decode_assistant_content(nil), do: nil

  defp decode_assistant_content(blocks) when is_list(blocks) do
    Enum.map(blocks, &decode_assistant_block/1)
  end

  defp decode_assistant_block(%{"type" => "text", "text" => t}) when is_binary(t),
    do: %TextPart{text: t}

  defp decode_assistant_block(%{"type" => "image_url", "image_url" => %{"url" => u}})
       when is_binary(u) do
    %ImagePart{image: image_from_assistant_url(u)}
  end

  defp decode_assistant_block(%{"type" => "image_url", "image_url" => u}) when is_binary(u) do
    %ImagePart{image: image_from_assistant_url(u)}
  end

  defp decode_assistant_block(%{"type" => "output_image"} = block) do
    url = Map.get(block, "image_url") || Map.get(block, "url")

    if is_binary(url) do
      %ImagePart{image: image_from_assistant_url(url)}
    else
      %TextPart{text: ""}
    end
  end

  defp decode_assistant_block(_other), do: %TextPart{text: ""}

  # Build an Image from an assistant-emitted URL string. `data:` URIs are
  # stored verbatim (not parsed into base64+mime today — keeps the decode
  # path total; consumers wanting bytes can call `Image.to_binary/1` on a
  # `{:url, "data:..."}` source which returns `:remote_source` — accepted
  # asymmetry).
  defp image_from_assistant_url(url) when is_binary(url),
    do: Image.from_url(url)

  # `output_text` is a flattened string convenience. When `content` is a
  # list of TextPart/ImagePart, join the text parts; image parts emit
  # nothing.
  defp assistant_output_text(content) when is_binary(content), do: content
  defp assistant_output_text(nil), do: nil

  defp assistant_output_text(parts) when is_list(parts) do
    Enum.map_join(parts, "", fn
      %TextPart{text: t} -> t
      _ -> ""
    end)
  end

  defp tool_calls_metadata([]), do: %{}
  defp tool_calls_metadata(tool_calls), do: %{tool_calls: tool_calls}

  # Per the Phase 10 Overview finish_reason mapping table.
  defp map_chat_finish_reason(nil), do: {nil, nil}
  defp map_chat_finish_reason("stop"), do: {:stop, nil}
  defp map_chat_finish_reason("length"), do: {:length, nil}
  defp map_chat_finish_reason("tool_calls"), do: {:tool_calls, nil}
  defp map_chat_finish_reason("content_filter"), do: {:content_filter, nil}
  # Legacy alias (deprecated by OpenAI but still emitted by older models).
  defp map_chat_finish_reason("function_call"), do: {:tool_calls, "function_call"}
  defp map_chat_finish_reason(other) when is_binary(other), do: {:other, other}

  defp decode_tool_calls(nil), do: []
  defp decode_tool_calls([]), do: []

  defp decode_tool_calls(list) when is_list(list) do
    Enum.map(list, &decode_tool_call/1)
  end

  defp decode_tool_call(%{"id" => id, "function" => %{"name" => name} = fun}) do
    raw_args = Map.get(fun, "arguments", "{}")

    args =
      case Jason.decode(raw_args) do
        {:ok, %{} = parsed} -> parsed
        _ -> %{}
      end

    ToolCall.new(
      id: id,
      name: name,
      arguments: args,
      raw_arguments: raw_args
    )
  end

  defp decode_usage(%{} = usage) do
    %Usage{
      input_tokens: Map.get(usage, "prompt_tokens"),
      output_tokens: Map.get(usage, "completion_tokens"),
      total_tokens: Map.get(usage, "total_tokens"),
      reasoning_tokens: extract_reasoning_tokens(usage, "completion_tokens_details"),
      extra:
        Map.drop(usage, [
          "prompt_tokens",
          "completion_tokens",
          "total_tokens",
          "completion_tokens_details"
        ])
    }
  end

  defp decode_usage(_), do: %Usage{}

  # Pull `reasoning_tokens` out of either Chat Completions'
  # `completion_tokens_details` sub-map or the Responses-API
  # `output_tokens_details` sub-map. Returns `nil` when absent.
  defp extract_reasoning_tokens(usage, key) do
    case Map.get(usage, key) do
      %{"reasoning_tokens" => rt} when is_integer(rt) -> rt
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Responses-API decoder (Phase 10.6)
  # ---------------------------------------------------------------------------

  @doc false
  @spec from_responses_response(map(), keyword()) :: Response.t()
  def from_responses_response(%{} = body, opts) when is_list(opts) do
    {finish_reason_initial, raw_keep} = map_responses_status(body)
    tool_calls = decode_responses_tool_calls(body)

    # Bug #5 fix: when status is :stop AND we surfaced tool calls from
    # output[], promote finish_reason to :tool_calls (mirrors Chat
    # Completions where `finish_reason: "tool_calls"` is the canonical
    # close-out for a tool-bearing turn). Keep raw_finish_reason consistent.
    finish_reason =
      if finish_reason_initial == :stop and tool_calls != [] do
        :tool_calls
      else
        finish_reason_initial
      end

    output_text = Map.get(body, "output_text", "")

    message = %Message{
      role: :assistant,
      content: output_text || "",
      metadata: tool_calls_metadata(tool_calls)
    }

    metadata =
      %{}
      |> maybe_put_metadata(:incomplete_details, decode_incomplete_details(body))
      |> maybe_put_metadata(:reasoning, decode_reasoning_metadata(body))

    %Response{
      id: Map.get(body, "id"),
      model: Map.get(body, "model"),
      message: message,
      output_text: output_text,
      tool_calls: tool_calls,
      finish_reason: finish_reason,
      raw_finish_reason: raw_keep,
      usage: decode_responses_usage(Map.get(body, "usage", %{})),
      raw: body,
      metadata: metadata
    }
  end

  # Bug #5 fix (Phase 10 retro): the Responses API returns function calls as
  # items in the top-level `output[]` array with `type: "function_call"`.
  # Each item carries its own `call_id` (the id the model uses to bind the
  # eventual `tool` message back) and `arguments` (a JSON-encoded string).
  # We surface them as `%ToolCall{}`s the same way the Chat Completions
  # decoder does for `message.tool_calls[]`.
  defp decode_responses_tool_calls(body) do
    body
    |> Map.get("output", [])
    |> Enum.filter(&match?(%{"type" => "function_call"}, &1))
    |> Enum.map(fn item ->
      raw = item["arguments"] || ""

      args =
        case Jason.decode(raw) do
          {:ok, %{} = parsed} -> parsed
          _ -> %{}
        end

      ToolCall.new(
        id: item["call_id"] || item["id"] || "",
        name: item["name"] || "",
        arguments: args,
        raw_arguments: raw
      )
    end)
  end

  defp maybe_put_metadata(map, _key, nil), do: map
  defp maybe_put_metadata(map, key, value), do: Map.put(map, key, value)

  defp decode_incomplete_details(%{"incomplete_details" => %{"reason" => reason}})
       when is_binary(reason),
       do: %{reason: reason}

  defp decode_incomplete_details(_), do: nil

  defp decode_reasoning_metadata(%{"reasoning" => %{} = r}) do
    effort = Map.get(r, "effort")
    summary = Map.get(r, "summary")

    sub =
      %{}
      |> maybe_put_metadata(:effort, effort)
      |> maybe_put_metadata(:summary, summary)

    if sub == %{}, do: nil, else: sub
  end

  defp decode_reasoning_metadata(_), do: nil

  # Responses-API status mapping per Decision #19. Returns
  # `{finish_reason, raw_finish_reason}` where the second element preserves
  # the raw status string when the mapping is anything other than `:stop`.
  defp map_responses_status(%{"status" => "completed"}), do: {:stop, nil}

  defp map_responses_status(%{
         "status" => "incomplete",
         "incomplete_details" => %{"reason" => "max_output_tokens"}
       }),
       do: {:length, "max_output_tokens"}

  defp map_responses_status(%{
         "status" => "incomplete",
         "incomplete_details" => %{"reason" => "content_filter"}
       }),
       do: {:content_filter, "content_filter"}

  defp map_responses_status(%{
         "status" => "incomplete",
         "incomplete_details" => %{"reason" => other}
       })
       when is_binary(other),
       do: {:other, other}

  defp map_responses_status(%{"status" => "incomplete"}), do: {:other, "incomplete"}
  defp map_responses_status(%{"status" => "in_progress"}), do: {nil, nil}
  defp map_responses_status(%{"status" => "failed"}), do: {:error, "failed"}
  defp map_responses_status(%{"status" => "cancelled"}), do: {:error, "cancelled"}
  defp map_responses_status(%{"status" => other}) when is_binary(other), do: {:other, other}
  defp map_responses_status(_), do: {nil, nil}

  defp decode_responses_usage(%{} = usage) do
    %Usage{
      input_tokens: Map.get(usage, "input_tokens"),
      output_tokens: Map.get(usage, "output_tokens"),
      total_tokens: Map.get(usage, "total_tokens"),
      reasoning_tokens: extract_reasoning_tokens(usage, "output_tokens_details"),
      extra:
        Map.drop(usage, [
          "input_tokens",
          "output_tokens",
          "total_tokens",
          "output_tokens_details"
        ])
    }
  end

  defp decode_responses_usage(_), do: %Usage{}

  # ---------------------------------------------------------------------------
  # Module-attribute getters (silence unused-attribute warnings; expose for
  # Phase 10.6 reasoning-control tests).
  # ---------------------------------------------------------------------------

  @doc false
  @spec __reasoning_atoms__() :: %{
          effort: [atom()],
          summary: [atom()],
          verbosity: [atom()],
          chat_completions_reasoning_models: Regex.t(),
          responses_max_tokens_key: atom()
        }
  def __reasoning_atoms__ do
    %{
      effort: @effort_atoms,
      summary: @summary_atoms,
      verbosity: @verbosity_atoms,
      chat_completions_reasoning_models: @chat_completions_reasoning_models,
      responses_max_tokens_key: @responses_max_tokens_key
    }
  end
end
