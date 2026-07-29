defmodule ALLM.Providers.OpenAI.Embeddings do
  @moduledoc """
  OpenAI text-embeddings provider adapter — implements `ALLM.EmbeddingAdapter`
  against OpenAI's `POST /v1/embeddings` endpoint.

  Layer B — runtime. Constructed via
  `ALLM.Engine.new(embed_adapter: ALLM.Providers.OpenAI.Embeddings, model: "text-embedding-3-small")`
  and consumed through `ALLM.embed/3`. Keys resolve via
  `ALLM.Keys.fetch!(:openai, opts)` at request-build time — no key ever lives
  on the engine.

      req = ALLM.EmbeddingRequest.new(input: ["hello"], model: "text-embedding-3-small")
      {:ok, resp} = ALLM.Providers.OpenAI.Embeddings.embed(req, api_key: "sk-...")
      [[_ | _]] = ALLM.EmbeddingResponse.vectors(resp)

  ## Wire-field map

  | Concern | OpenAI |
  |---------|--------|
  | Endpoint | `POST https://api.openai.com/v1/embeddings` (not overridable) |
  | Auth | `authorization: Bearer <key>` |
  | Input | `input` — always sent as an **array**, even for one input |
  | Model | `model` |
  | Dimensions | `dimensions` — `text-embedding-3` and later only |
  | Task type | **none** — `:task_type` is dropped (logged at `:debug`) |
  | Truncate | **none** — see "Truncation" below |
  | Vectors | `data[].embedding` |
  | Index | `data[].index` |
  | Usage | top-level `usage` → `input_tokens ← prompt_tokens`, `total_tokens ← total_tokens`, `output_tokens = nil` |
  | Batch cap | 2048 array items (`max_batch_size/0`) |

  ## Adapter-injected defaults

  **None.** The wire requires `model`, and `ALLM.EmbeddingRequest` permits
  `model: nil`. This adapter does **not** invent a default model: a `nil`
  `:model` is OMITTED from the body and OpenAI answers with a 400, surfaced as
  `%ALLM.Error.EmbeddingAdapterError{reason: :invalid_request}`. Guessing an
  embedding model would silently produce vectors of an unexpected
  dimensionality into a caller's vector column, which is unrecoverable after
  the fact. `ALLM.embed/3` stamps the engine's resolved model onto the request
  before dispatch, so this only arises on a direct adapter call.

  ## `:task_type` is dropped

  `ALLM.EmbeddingRequest`'s provider-neutral `:task_type` enum has no OpenAI
  equivalent. The adapter drops the field rather than erroring, and logs the
  drop at `:debug`. A caller who needs asymmetric query/document embedding
  should use a provider that supports it.

  ## Truncation

  `:truncate` is a **no-op** here, in both directions: OpenAI answers an
  over-length input with a 400 rather than silently truncating it, so there is
  no wire field to carry either value. The field is neither sent nor treated
  as an error.

  ## Token budget vs. batch size

  `max_batch_size/0` is `2048` — the array-item cap. OpenAI *separately* caps
  a single request at 300,000 tokens summed across all inputs, which is
  reachable far below 2048 items when the inputs are long. That rejection
  arrives as a 400 and maps to
  `%ALLM.Error.EmbeddingAdapterError{reason: :context_length_exceeded}`.
  ALLM ships no tokenizer and will not guess token counts, so the recovery is
  yours: lower your effective batch size and re-drive `ALLM.embed/3`, or chunk
  against `max_batch_size/0` yourself with a smaller stride.

  ## Reduced dimensions

  `dimensions:` is supported only on `text-embedding-3` and later. Setting it
  on `text-embedding-ada-002` is rejected pre-flight with
  `%ALLM.Error.EmbeddingAdapterError{reason: :unsupported_feature,
  metadata: %{feature: :dimensions, model: model}}` — the adapter can see the
  request is malformed without spending a round-trip.

  ## Pre-flight gates

  Before any HTTP I/O — and, deliberately, before `ALLM.Keys.fetch!/2`, so a
  request that is going to be rejected never needs a valid API key:

    1. **Empty input.** `input: []` → `:invalid_request`.
    2. **Batch size.** `length(input) > 2048` → `:batch_too_large` with
       `metadata: %{count: n, max: 2048}`. An `:input` that is not a list at
       all — OpenAI's own wire accepts a bare string, so it is the likeliest
       direct-adapter mistake — is rejected here as `:invalid_request` with
       `metadata: %{field: :input}` rather than raising.
    3. **Feature support.** `dimensions:` on a model with no such knob →
       `:unsupported_feature`.

  Capability pre-flight against a model catalog is NOT performed here — it
  lives in `ALLM.embed/3`. A direct adapter call bypasses it by design.

  ## Response ordering

  `data[]` is sorted by `:index` before it becomes `:embeddings`. OpenAI
  documents that field precisely because array order is not contractual, and
  `ALLM.EmbeddingResponse`'s order-correspondence invariant depends on it.

  ## Request-id preservation

  `opts[:request_id]` is reflected onto `response.request_id` unchanged. When
  it is absent, the adapter falls back to OpenAI's `x-request-id` response
  header. `request.metadata` round-trips onto `response.metadata` untouched.

  > #### The `x-request-id` fallback is unreachable through `ALLM.embed/3` {: .warning}
  >
  > The façade always supplies `opts[:request_id]` (it generates one when the
  > caller does not), so on that path the left branch always wins and OpenAI's
  > own correlation id is never observed. It surfaces only on a direct
  > `embed/2` / `decode_response/4` call that omits `opts[:request_id]`.
  > Stamping it into `response.metadata` the way
  > `ALLM.Providers.OpenAI.Images` does would contradict `ALLM.EmbeddingAdapter`
  > invariant 7's requirement that `request.metadata` round-trip **unchanged**,
  > so the divergence is deliberate. Callers who need OpenAI's request id for a
  > support ticket should pass their own `opts[:request_id]` and correlate on
  > that. Binding on 20.5 / 20.6.

  ## Error-struct hygiene

  `%ALLM.Error.EmbeddingAdapterError{}` derives `Jason.Encoder` and is
  commonly logged and persisted, so this adapter never copies a raw response
  body, a request header, or any `Authorization` value into `:cause`,
  `:metadata`, or `:message`. Provider error messages pass through a redactor
  that replaces key-shaped tokens with `[REDACTED]` — OpenAI echoes a prefix
  of the offending key back in its 401 text.

  ## Retry integration

  HTTP-error closures return `{:retry, delay_ms, error}` for 429 (honouring
  `Retry-After`), 5xx, timeouts, and transport failures; `ALLM.Retry.run/3` is
  wrapped around each attempt. The closure returns real reason atoms rather
  than swapping in HTTP status codes, so for `:rate_limited`,
  `:provider_unavailable`, and `:network_error` the façade's widened `retry_on`
  list is what decides — none of them appears in this adapter's own
  `opts[:retry]` policy, which defaults to `:default`.

  `:timeout` is the documented exception: it is a member of **both** lists, so
  through `ALLM.embed/3` the adapter's inner `ALLM.Retry.run/3` and the
  façade's outer one both retry it and the attempt budgets multiply
  (3 × 3 = 9 HTTP attempts at the default policy, against 3 for every other
  retryable reason). A direct `embed/2` call takes the inner loop only and
  makes 3. `ALLM.Providers.OpenAI.Images` has the byte-identical shape through
  `ALLM.generate_image/3`, so this is a pre-existing library-wide
  characteristic rather than an embeddings one; it is tracked in `ASKS.md` and
  **binding on 20.5 / 20.6** — do not "fix" it per-adapter, because the
  correction has to land in the façade and both image adapters at once.

  ## Test-injection escape hatch

  `embed/2` honours `opts[:adapter_opts][:embedding_script]` as a documented
  test-only short-circuit: when the key is present, the call delegates to
  `ALLM.Providers.FakeEmbeddings.embed/2` BEFORE any pre-flight gate runs and
  returns its result verbatim. This is what lets the injectable
  `ALLM.EmbeddingAdapter` conformance suite drive a real adapter without an
  HTTP stub library.

  The switch keys on the presence of that per-call key and **nothing else** —
  no environment variable, no application config, no `:persistent_term` — so
  it stays confined to an explicit argument. Setting `adapter_opts` already
  implies full control of the call. Production callers do not populate it.

  `prepare_request/2` deliberately does NOT delegate under the same key: a
  scripted response has no `Req.Request` analogue, so it returns a stub error
  instead.
  """

  @behaviour ALLM.EmbeddingAdapter

  require Logger

  alias ALLM.{Embedding, EmbeddingRequest, EmbeddingResponse, Keys, Retry, Usage}
  alias ALLM.Error.EmbeddingAdapterError
  alias ALLM.Providers.FakeEmbeddings
  alias ALLM.Providers.Support.OpenAIHeaders

  @base_url "https://api.openai.com/v1"
  @endpoint "/embeddings"
  @adapter_max_batch_size 2048

  # Models predating `text-embedding-3`, on which OpenAI documents `dimensions`
  # as unsupported. An unknown model falls THROUGH this gate to the provider —
  # a hard-coded allow-list would reject every model OpenAI ships next.
  @no_dimensions_models ["text-embedding-ada-002"]

  # OpenAI carries the per-request token-budget discriminator on `type` and
  # the per-input one on `code`, so the classifier checks both fields against
  # this list rather than composing a boolean guard.
  @context_length_markers ["max_tokens_per_request", "context_length_exceeded"]

  # ---------------------------------------------------------------------------
  # ALLM.EmbeddingAdapter callbacks
  # ---------------------------------------------------------------------------

  @doc """
  Return the maximum number of inputs OpenAI accepts in one `/v1/embeddings`
  call.

  Per-module and constant, not per-model. Note the separate 300,000-token
  per-request cap described in the module documentation, which can be hit well
  below this number.

  ## Examples

      iex> ALLM.Providers.OpenAI.Embeddings.max_batch_size
      2048
  """
  @impl ALLM.EmbeddingAdapter
  @spec max_batch_size() :: pos_integer()
  def max_batch_size, do: @adapter_max_batch_size

  @doc """
  Execute a text-embedding request synchronously against OpenAI.

  Returns `{:ok, %ALLM.EmbeddingResponse{}}` or
  `{:error, %ALLM.Error.EmbeddingAdapterError{}}`; every HTTP-shaped failure
  converts, including transport errors. The one documented exception is
  `ALLM.Keys.fetch!/2`, which raises
  `%ALLM.Error.EngineError{reason: :missing_key}` by design and is not
  rescued here — the three pre-flight gates all run ahead of it, so a request
  rejected pre-flight never needs a key.

  See the module documentation for the gate order, the wire-field map, the
  no-injected-defaults policy for a `nil` `:model`, and the
  `adapter_opts[:embedding_script]` test-injection short-circuit.

  ## Examples

      iex> e = ALLM.Embedding.new(vector: [0.1, 0.2])
      iex> req = ALLM.EmbeddingRequest.new(input: ["a kestrel"])
      iex> opts = [adapter_opts: [embedding_script: [{:ok, [e]}]]]
      iex> {:ok, resp} = ALLM.Providers.OpenAI.Embeddings.embed(req, opts)
      iex> ALLM.EmbeddingResponse.vectors(resp)
      [[0.1, 0.2]]

      iex> req = ALLM.EmbeddingRequest.new(input: [])
      iex> {:error, err} = ALLM.Providers.OpenAI.Embeddings.embed(req, [])
      iex> err.reason
      :invalid_request
  """
  @impl ALLM.EmbeddingAdapter
  @spec embed(EmbeddingRequest.t(), keyword()) ::
          {:ok, EmbeddingResponse.t()} | {:error, EmbeddingAdapterError.t()}
  def embed(%EmbeddingRequest{} = request, opts) when is_list(opts) do
    case fetch_embedding_script(opts) do
      nil -> do_embed(request, opts)
      _script -> FakeEmbeddings.embed(request, opts)
    end
  end

  @doc """
  Return an unfired `Req.Request` configured exactly as `embed/2` would fire
  it, for callers who need to add headers, middleware, or their own retry
  wrapper before dispatch.

  The pre-flight gates run first, so this is defined only for a request whose
  input is non-empty and no longer than `max_batch_size/0`.

  Under `opts[:adapter_opts][:embedding_script]` this returns a stub error
  rather than delegating to `ALLM.Providers.FakeEmbeddings` — a scripted
  response has no `Req.Request` analogue. That asymmetry with `embed/2` is
  deliberate.

  ## Examples

      iex> req = ALLM.EmbeddingRequest.new(input: ["hi"], model: "text-embedding-3-small")
      iex> {:ok, http} = ALLM.Providers.OpenAI.Embeddings.prepare_request(req, api_key: "sk-x")
      iex> URI.to_string(http.url)
      "https://api.openai.com/v1/embeddings"
  """
  @impl ALLM.EmbeddingAdapter
  @spec prepare_request(EmbeddingRequest.t(), keyword()) ::
          {:ok, Req.Request.t()} | {:error, EmbeddingAdapterError.t()}
  def prepare_request(%EmbeddingRequest{} = request, opts) when is_list(opts) do
    case fetch_embedding_script(opts) do
      nil ->
        case run_gates(request, opts) do
          :ok -> build_request(request, opts)
          {:error, %EmbeddingAdapterError{}} = err -> err
        end

      _script ->
        {:error, stub_error(opts)}
    end
  end

  # ---------------------------------------------------------------------------
  # Public testing seams (`@doc false` + `@spec` per the public-test-seam rule).
  #
  # Names ALIGN across the embeddings adapter family modulo arity, and align
  # with `ALLM.Providers.OpenAI.Images` where the concept is shared. Bind
  # `ALLM.Providers.Gemini.Embeddings` and `ALLM.Providers.Voyage.Embeddings`
  # to the same names so reader pattern-recognition flips between the files:
  #
  #   IDENTICAL to the image adapter (byte-for-byte modulo arity):
  #   * `decode_response/4`            ↔ openai/images.ex `decode_response/4`
  #   * `to_json_body/2`               ↔ openai/images.ex `to_json_body/2`
  #   * private `build_metadata/2`, `run_one_attempt/3`, `classify_http_error/4`,
  #     `retry_after_ms/1`, `stub_error/1`, `maybe_apply_req_test_stub/2`,
  #     `maybe_apply_request_timeout/2`, `user_pair/1`
  #
  #   RENAMED for the embeddings family (per-capability, not per-provider):
  #   * `to_embedding_adapter_error/4` ↔ images' `to_image_adapter_error/4`
  #   * `classify_embedding_reason/4`  ↔ images' `classify_image_reason/4`
  #   * `fetch_embedding_script/1`     ↔ images' `fetch_image_script/1`
  #   * `max_batch_size/0`             — embeddings-only; images has
  #                                      `supported_operations/0` in the same
  #                                      "per-module constant" role.
  #
  #   DIVERGENT, with per-provider justification (for 20.5 / 20.6):
  #   * `@base_url` is a module attribute and is NOT overridable, matching the
  #     OpenAI image adapter. Only the Gemini adapters honour
  #     `adapter_opts[:endpoint]`, so `ALLM.Providers.Gemini.Embeddings` is
  #     expected to diverge here and nowhere else in this list.
  #   * `gate_dimensions_support/2` is OpenAI-only — it encodes the
  #     `text-embedding-3`-and-later `dimensions` rule. Gemini and Voyage
  #     express their own feature gates under the same `gate_*/2` prefix.
  #   * `parse_retry_after/1` returns `nil` INLINE for an unparseable value,
  #     where `openai/images.ex` and `openai.ex` fall through to a
  #     `parse_http_date/1` stub that also returns `nil` today. Behaviour is
  #     identical; the seam is deliberately omitted here so there is no dead
  #     private function. If that stub is ever implemented, this clause has to
  #     be updated with it — same for 20.5 / 20.6.
  #   * `redact_key_material/1`'s pattern is OpenAI-prefix-specific
  #     (`sk-` / `rk-` / `org-`), which is correct scoping because the redacted
  #     text comes from OpenAI. `ALLM.Providers.Gemini.Embeddings` (`AIza…`)
  #     and `ALLM.Providers.Voyage.Embeddings` (`pa-…`) MUST widen the pattern
  #     for their own provider's key shapes rather than inheriting these
  #     prefixes verbatim — an inherited pattern redacts nothing on either.
  #   * `to_openai_task_type/1` deliberately does NOT exist: OpenAI has no
  #     task-type wire field at all. Gemini and Voyage each ship an exhaustive
  #     `to_<provider>_task_type/1` over the closed five-member enum, falling
  #     through to omit — never `Atom.to_string/1` on the field, which admits
  #     any already-loaded atom that survived decoding.
  # ---------------------------------------------------------------------------

  @doc false
  # Adapter-injected defaults: NONE. A `nil` `:model` is OMITTED rather than
  # defaulted (the public `@moduledoc` states why), `:task_type` is dropped
  # with a `:debug` log, and `:truncate` has no wire representation in either
  # direction.
  @spec to_json_body(EmbeddingRequest.t(), keyword()) :: map()
  def to_json_body(%EmbeddingRequest{} = request, _opts) do
    log_dropped_task_type(request)

    %{"input" => request.input}
    |> put_pair(model_pair(request))
    |> put_pair(dimensions_pair(request))
    |> put_pair(user_pair(request))
  end

  @doc false
  @spec to_embedding_adapter_error(
          non_neg_integer(),
          map(),
          Enumerable.t() | map(),
          keyword()
        ) :: EmbeddingAdapterError.t()
  def to_embedding_adapter_error(status, body, headers, opts)
      when is_integer(status) and is_map(body) do
    error = Map.get(body, "error", %{})
    code = Map.get(error, "code")
    type = Map.get(error, "type")

    message =
      error
      |> Map.get("message", "OpenAI HTTP #{status}")
      |> redact_key_material()

    {reason, retry_after} = classify_embedding_reason(status, code, type, retry_after_ms(headers))

    EmbeddingAdapterError.new(reason,
      provider: :openai,
      status: status,
      retry_after_ms: retry_after,
      message: message,
      metadata: build_metadata(%{status: status, openai_code: code, openai_type: type}, opts)
    )
  end

  @doc false
  @spec decode_response(term(), Enumerable.t() | map(), EmbeddingRequest.t(), keyword()) ::
          {:ok, EmbeddingResponse.t()} | {:error, EmbeddingAdapterError.t()}
  def decode_response(body, headers, request, opts)

  def decode_response(%{"data" => data} = body, headers, %EmbeddingRequest{} = request, opts)
      when is_list(data) do
    case decode_data_list(data, opts) do
      {:ok, embeddings} ->
        {:ok,
         %EmbeddingResponse{
           id: Map.get(body, "id"),
           request_id: Keyword.get(opts, :request_id) || header_value(headers, "x-request-id"),
           model: Map.get(body, "model") || request.model,
           # Sorted here, not at the call site: OpenAI documents `index`
           # precisely because array order is not contractual.
           embeddings: Enum.sort_by(embeddings, & &1.index),
           usage: build_usage(body),
           raw: body,
           metadata: request.metadata
         }}

      {:error, %EmbeddingAdapterError{}} = err ->
        err
    end
  end

  def decode_response(body, _headers, _request, opts) when is_map(body) do
    {:error,
     malformed_error(
       "missing or non-list \"data\" field",
       %{body_keys: body |> Map.keys() |> Enum.sort()},
       opts
     )}
  end

  def decode_response(_body, _headers, _request, opts) do
    {:error, malformed_error("non-JSON body", %{}, opts)}
  end

  # ---------------------------------------------------------------------------
  # Internals — gates
  # ---------------------------------------------------------------------------

  defp fetch_embedding_script(opts) do
    opts
    |> Keyword.get(:adapter_opts, [])
    |> Keyword.get(:embedding_script)
  end

  # Gate ordering: :invalid_request -> :batch_too_large -> :unsupported_feature,
  # ALL of them ahead of `Keys.fetch!/2`. Key resolution happening after the
  # gates is what keeps the two unscripted conformance cases green in a
  # keyless environment.
  defp run_gates(%EmbeddingRequest{} = request, opts) do
    with :ok <- gate_empty_input(request, opts),
         :ok <- gate_batch_size(request, opts) do
      gate_dimensions_support(request, opts)
    end
  end

  defp gate_empty_input(%EmbeddingRequest{input: []}, opts) do
    {:error,
     EmbeddingAdapterError.new(:invalid_request,
       provider: :openai,
       message: "input must not be empty",
       metadata: build_metadata(%{field: :input}, opts)
     )}
  end

  defp gate_empty_input(%EmbeddingRequest{}, _opts), do: :ok

  defp gate_batch_size(%EmbeddingRequest{input: input}, opts) when is_list(input) do
    count = length(input)
    max = max_batch_size()

    if count > max do
      {:error,
       EmbeddingAdapterError.new(:batch_too_large,
         provider: :openai,
         message: "input count #{count} exceeds max_batch_size #{max}",
         metadata: build_metadata(%{count: count, max: max}, opts)
       )}
    else
      :ok
    end
  end

  # `:input` is the one off-shape field with no defensive clause upstream —
  # `gate_empty_input/2`'s catch-all passes any non-`[]` term through. OpenAI's
  # own wire accepts a bare string for `input`, so this is the likeliest
  # direct-adapter mistake, and it must convert rather than raise: 20.3's
  # `ALLM.EmbeddingBatch.dispatch_chunk/2` raises `ArgumentError` on any return
  # outside the `{:ok, _} | {:error, _}` union. Binding on 20.5 / 20.6 under
  # the same `gate_*/2` prefix.
  defp gate_batch_size(%EmbeddingRequest{}, opts) do
    {:error,
     EmbeddingAdapterError.new(:invalid_request,
       provider: :openai,
       message: "input must be a list of strings",
       metadata: build_metadata(%{field: :input}, opts)
     )}
  end

  defp gate_dimensions_support(%EmbeddingRequest{dimensions: nil}, _opts), do: :ok

  defp gate_dimensions_support(%EmbeddingRequest{model: model}, opts)
       when model in @no_dimensions_models do
    {:error,
     EmbeddingAdapterError.new(:unsupported_feature,
       provider: :openai,
       message: "model #{inspect(model)} does not support reduced output dimensions",
       metadata: build_metadata(%{feature: :dimensions, model: model}, opts)
     )}
  end

  defp gate_dimensions_support(%EmbeddingRequest{}, _opts), do: :ok

  defp stub_error(opts) do
    EmbeddingAdapterError.new(:unknown,
      provider: :openai,
      message: "prepare_request/2 has no analogue under the embedding_script short-circuit",
      metadata: build_metadata(%{}, opts)
    )
  end

  # Every error this adapter surfaces carries `opts[:request_id]` on its
  # metadata, whether it came from a pre-flight gate or from the HTTP path.
  defp build_metadata(metadata, opts) when is_map(metadata) do
    case Keyword.get(opts, :request_id) do
      nil -> metadata
      request_id -> Map.put(metadata, :request_id, request_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Internals — dispatch
  # ---------------------------------------------------------------------------

  defp do_embed(%EmbeddingRequest{} = request, opts) do
    with :ok <- run_gates(request, opts),
         {:ok, http_req} <- build_request(request, opts) do
      retry_policy = Keyword.get(opts, :retry, :default)
      telemetry_meta = build_retry_telemetry_meta(opts)

      Retry.run(retry_policy, telemetry_meta, fn ->
        run_one_attempt(http_req, request, opts)
      end)
    end
  end

  # `Keys.fetch!/2` raises `%EngineError{reason: :missing_key}` on a miss by
  # documented design — deliberately not rescued, mirroring the image adapter.
  # It runs here, AFTER `run_gates/2`.
  defp build_request(%EmbeddingRequest{} = request, opts) do
    api_key = Keys.fetch!(:openai, opts)

    req =
      Req.new(
        method: :post,
        url: @base_url <> @endpoint,
        headers: OpenAIHeaders.json_headers(api_key, opts),
        json: to_json_body(request, opts)
      )
      |> maybe_apply_req_test_stub(opts)
      |> maybe_apply_request_timeout(opts)

    {:ok, req}
  end

  defp maybe_apply_req_test_stub(req, opts) do
    case opts |> Keyword.get(:adapter_opts, []) |> Keyword.get(:plug) do
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

  # ---------------------------------------------------------------------------
  # Internals — JSON body builder
  # ---------------------------------------------------------------------------

  defp put_pair(body, nil), do: body
  defp put_pair(body, {key, value}), do: Map.put(body, key, value)

  defp model_pair(%EmbeddingRequest{model: nil}), do: nil
  defp model_pair(%EmbeddingRequest{model: m}) when is_binary(m), do: {"model", m}
  defp model_pair(_request), do: nil

  defp dimensions_pair(%EmbeddingRequest{dimensions: nil}), do: nil

  defp dimensions_pair(%EmbeddingRequest{dimensions: d}) when is_integer(d),
    do: {"dimensions", d}

  defp dimensions_pair(_request), do: nil

  # OpenAI's request-level end-user identifier. `ALLM.EmbeddingRequest` carries
  # it under `:options` rather than as a first-class field because it is
  # OpenAI-only. Byte-identical to the image adapter's `user_pair/1`.
  defp user_pair(%EmbeddingRequest{options: options}) when is_map(options) do
    case Map.get(options, :user) do
      user when is_binary(user) -> {"user", user}
      _ -> nil
    end
  end

  defp user_pair(_request), do: nil

  defp log_dropped_task_type(%EmbeddingRequest{task_type: nil}), do: :ok

  defp log_dropped_task_type(%EmbeddingRequest{task_type: task_type}) do
    Logger.debug(fn ->
      "ALLM.Providers.OpenAI.Embeddings: task_type #{inspect(task_type)} is not supported " <>
        "by OpenAI's /v1/embeddings endpoint; dropping."
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Internals — HTTP attempt
  # ---------------------------------------------------------------------------

  defp run_one_attempt(http_req, request, opts) do
    case Req.request(http_req) do
      {:ok, %Req.Response{status: status, body: body, headers: headers}}
      when status in 200..299 ->
        decode_response(body, headers, request, opts)

      {:ok, %Req.Response{status: status, body: body, headers: headers}} ->
        classify_http_error(status, body, headers, opts)

      {:error, %{__struct__: Req.TransportError, reason: :timeout} = cause} ->
        {:retry, 0,
         EmbeddingAdapterError.new(:timeout,
           provider: :openai,
           message: "request timed out",
           cause: sanitize_cause(cause),
           metadata: build_metadata(%{}, opts)
         )}

      {:error, %{__struct__: Jason.DecodeError} = cause} ->
        {:error,
         malformed_error("response body is not valid JSON", %{}, opts, sanitize_cause(cause))}

      {:error, exception} ->
        {:retry, 0,
         EmbeddingAdapterError.new(:network_error,
           provider: :openai,
           message: "transport failure: " <> Exception.message(exception),
           cause: sanitize_cause(exception),
           metadata: build_metadata(%{}, opts)
         )}
    end
  end

  defp classify_http_error(status, body, headers, opts) do
    classified = to_embedding_adapter_error(status, decode_error_body(body), headers, opts)

    if classified.reason in [:rate_limited, :provider_unavailable] do
      {:retry, classified.retry_after_ms || 0, classified}
    else
      {:error, classified}
    end
  end

  defp decode_error_body(body) when is_map(body), do: body
  defp decode_error_body(_body), do: %{}

  # ---------------------------------------------------------------------------
  # Internals — error mapping
  # ---------------------------------------------------------------------------

  defp classify_embedding_reason(401, _code, _type, _ra), do: {:authentication_failed, nil}
  defp classify_embedding_reason(403, _code, _type, _ra), do: {:authentication_failed, nil}
  defp classify_embedding_reason(429, _code, _type, ra), do: {:rate_limited, ra}

  defp classify_embedding_reason(400, code, _type, _ra) when code in @context_length_markers,
    do: {:context_length_exceeded, nil}

  defp classify_embedding_reason(400, _code, type, _ra) when type in @context_length_markers,
    do: {:context_length_exceeded, nil}

  defp classify_embedding_reason(400, _code, _type, _ra), do: {:invalid_request, nil}

  defp classify_embedding_reason(status, _code, _type, ra) when status in [500, 502, 503, 504],
    do: {:provider_unavailable, ra}

  defp classify_embedding_reason(_status, _code, _type, _ra), do: {:unknown, nil}

  defp malformed_error(detail, metadata, opts, cause \\ nil) do
    EmbeddingAdapterError.new(:malformed_response,
      provider: :openai,
      message: "could not parse OpenAI embeddings response: " <> detail,
      cause: cause,
      metadata: build_metadata(metadata, opts)
    )
  end

  # `%EmbeddingAdapterError{}` derives `Jason.Encoder` and is routinely logged
  # and persisted, so `:cause` must never smuggle a raw response body through.
  # `Jason.DecodeError` carries the whole undecodable payload on `:data`;
  # everything else (transport errors) carries only a reason atom.
  defp sanitize_cause(%{__struct__: Jason.DecodeError} = cause), do: %{cause | data: ""}
  defp sanitize_cause(cause), do: cause

  # OpenAI echoes a prefix of the offending key back in its 401 text
  # ("Incorrect API key provided: sk-..."), and that message lands on
  # `:message`. Strip anything key-shaped before it reaches the struct.
  defp redact_key_material(message) when is_binary(message) do
    String.replace(message, ~r/\b(?:sk|rk|org)-[A-Za-z0-9_\-]{6,}/, "[REDACTED]")
  end

  defp redact_key_material(_message), do: "OpenAI embeddings error"

  # ---------------------------------------------------------------------------
  # Internals — headers
  # ---------------------------------------------------------------------------

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
  defp header_value_to_string(_v), do: nil

  # Per RFC 7231 §7.1.3 `Retry-After` is delta-seconds or an HTTP-date. OpenAI
  # sends delta-seconds; an unparseable value returns `nil` and the retry loop
  # falls back to its computed exponential backoff.
  defp parse_retry_after(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> seconds * 1_000
      _ -> nil
    end
  end

  defp parse_retry_after(_value), do: nil

  defp build_retry_telemetry_meta(opts) do
    case Keyword.get(opts, :request_id) do
      nil -> %{provider: :openai}
      request_id -> %{provider: :openai, request_id: request_id}
    end
  end

  # ---------------------------------------------------------------------------
  # Internals — response decoder
  # ---------------------------------------------------------------------------

  defp decode_data_list(data, opts) do
    data
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case decode_embedding_entry(entry, opts) do
        {:ok, embedding} -> {:cont, {:ok, [embedding | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      {:error, _} = err -> err
    end
  end

  defp decode_embedding_entry(%{"embedding" => vector, "index" => index}, opts)
       when is_list(vector) and is_integer(index) and index >= 0 do
    cond do
      vector == [] ->
        {:error, malformed_error("entry #{index} carries an empty vector", %{index: index}, opts)}

      not Enum.all?(vector, &is_number/1) ->
        {:error,
         malformed_error("entry #{index} carries a non-numeric component", %{index: index}, opts)}

      true ->
        {:ok, %Embedding{vector: Enum.map(vector, &(&1 * 1.0)), index: index}}
    end
  end

  defp decode_embedding_entry(_entry, opts) do
    {:error, malformed_error(~s(a "data" entry is missing "embedding" or "index"), %{}, opts)}
  end

  # `:output_tokens` is always `nil` — embeddings produce no completion
  # tokens, and `ALLM.Usage` documents every counter as optional.
  defp build_usage(body) do
    usage = Map.get(body, "usage") || %{}

    %Usage{
      input_tokens: non_neg_int(usage, "prompt_tokens"),
      output_tokens: nil,
      total_tokens: non_neg_int(usage, "total_tokens")
    }
  end

  defp non_neg_int(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_integer(value) and value >= 0 -> value
      _ -> nil
    end
  end

  defp non_neg_int(_map, _key), do: nil
end
