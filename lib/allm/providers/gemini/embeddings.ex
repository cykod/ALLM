defmodule ALLM.Providers.Gemini.Embeddings do
  @moduledoc """
  Google Gemini text-embeddings provider adapter — implements
  `ALLM.EmbeddingAdapter` against `batchEmbedContents`.

  Layer B — runtime. Constructed via
  `ALLM.Engine.new(embed_adapter: ALLM.Providers.Gemini.Embeddings, model: "gemini-embedding-001")`
  and consumed through `ALLM.embed/3`. Keys resolve via
  `ALLM.Keys.fetch!(:gemini, opts)` at request-build time — no key ever lives
  on the engine.

      req = ALLM.EmbeddingRequest.new(input: ["hello"], model: "gemini-embedding-001")
      {:ok, resp} = ALLM.Providers.Gemini.Embeddings.embed(req, api_key: "AIza...")
      [[_ | _]] = ALLM.EmbeddingResponse.vectors(resp)

  ## Wire-field map

  | Concern | Gemini |
  |---------|--------|
  | Endpoint | `POST {base}/models/<model>:batchEmbedContents` |
  | Base URL | `https://generativelanguage.googleapis.com/v1beta`, overridable via `adapter_opts[:endpoint]` |
  | Auth | `x-goog-api-key` **header**, not a `?key=` query parameter |
  | Body | `{"requests": [{"model": ..., "content": {"parts": [{"text": ...}]}, ...}]}` |
  | Model | **required on every sub-request**, prefixed `models/` |
  | Dimensions | `outputDimensionality` (camelCase), per sub-request |
  | Task type | `taskType`, per sub-request |
  | Truncate | `embedContentConfig.autoTruncate`, per sub-request — see "Truncation" |
  | Vectors | `embeddings[].values` — `values`, **not** `embedding` |
  | Index | **none** — order is positional; see "Positional indexing" |
  | Usage | `usageMetadata.promptTokenCount` when present — see "Usage" |
  | Batch cap | 100 sub-requests (`max_batch_size/0`) |

  ## Per-sub-request `model` is required, and must be prefixed

  Unlike OpenAI's single top-level `model`, every element of `requests` carries
  its own. Omitting it answers
  `"BatchEmbedContentsRequest.requests[0].model: model is not specified"`, and
  passing a bare model id without the `models/` prefix answers
  `"unexpected model name format"` — both 400s. The prefix is applied
  idempotently, so a caller who already wrote `"models/gemini-embedding-001"`
  is not double-prefixed.

  ## Adapter-injected defaults

  **None**, and the `nil` `:model` case is an outright rejection rather than a
  substitution. Both the URL and every sub-request's required `model` field
  derive from `request.model`, so a request with `model: nil` cannot be
  expressed on this wire at all; it is rejected pre-flight with
  `%ALLM.Error.EmbeddingAdapterError{reason: :invalid_request,
  metadata: %{field: :model}}`.

  This deliberately diverges from `ALLM.Providers.Gemini.Images`, which
  substitutes a hardcoded default model. A wrong image model yields a wrong
  picture; a wrong embedding model yields vectors in a *different vector
  space*, which is unrecoverable once they are written to a vector column
  alongside vectors from the intended model. `ALLM.embed/3` stamps the
  engine's resolved model onto the request before dispatch, so this only
  arises on a direct adapter call.

  ## Positional indexing

  Gemini's response carries no index field: `embeddings[]` is positional, and
  the adapter assigns `:index` from list position. There is consequently no
  sort step and no way to detect a dropped sub-response — one missing entry
  shifts every subsequent index silently. That is why this adapter's decoder
  carries an explicit cardinality test against a recorded batch fixture rather
  than relying on the conformance suite, which never reaches the decoder.

  ## Normalization

  `dimensions` other than `nil` and `3072` are L2-normalized in-adapter,
  **unconditionally across models**. Google returns pre-normalized vectors at
  `gemini-embedding-001`'s native 3072 dimensions but not at truncated
  dimensionalities (a recorded 768-wide response measures ~0.585, not 1.0),
  while newer models auto-normalize truncated output too.

  The rule does not branch on model id on purpose. Re-normalizing an
  already-unit vector is a no-op to within `1.0e-9`, so the unconditional form
  is safe on the models that self-normalize, correct on the ones that do not,
  and does not go stale when Google ships the next model — where a hard-coded
  model allow-list would silently mis-handle it. Mixed-normalization data is
  unrecoverable after the fact: cosine distance tolerates unnormalized input
  but inner-product operators silently return wrong rankings.

  Normalization is a scale, not a reshuffle — `ALLM.Embedding.normalize/1`
  leaves a zero-magnitude vector unchanged rather than producing `NaN`.

  ## Truncation

  `truncate: false` is emitted as `embedContentConfig: {"autoTruncate": false}`
  **on each sub-request**. `truncate: true` is the provider-side default and is
  omitted from the wire entirely.

  The nesting is load-bearing and was resolved empirically, not from the
  published schema: the flat sub-request form and the top-level form are both
  400s, and so is an invented field name — which is what establishes that the
  nested form's acceptance reflects schema membership rather than tolerance of
  unknown keys. `scripts/record_gemini_embeddings_fixtures.exs` re-runs that
  four-way discrimination on every recording pass.

  ## Usage

  `ALLM.Usage` is populated from `usageMetadata.promptTokenCount` onto **both**
  `:input_tokens` and `:total_tokens`; `:output_tokens` is always `nil`,
  because embeddings produce no completion tokens.

  In practice `batchEmbedContents` returns **no** `usageMetadata` — a 200 body
  carries exactly `{"embeddings": [{"values": [...]}, ...]}` — so `:usage` is
  an all-`nil` `%ALLM.Usage{}` today. It is never `nil` itself. The decoder
  reads the field defensively so that token counts appear automatically if
  Google starts reporting them, and callers who need per-request token costs
  should not depend on this provider supplying them.

  ## Pre-flight gates

  Before any HTTP I/O — and, deliberately, before `ALLM.Keys.fetch!/2`, so a
  request that is going to be rejected never needs a valid API key:

    1. **Empty input.** `input: []` → `:invalid_request`.
    2. **Batch size.** `length(input) > 100` → `:batch_too_large` with
       `metadata: %{count: n, max: 100}`. An `:input` that is not a list at all
       is rejected here as `:invalid_request` with `metadata: %{field: :input}`
       rather than raising.
    3. **Input elements.** An `:input` list containing a non-string element →
       `:invalid_request` with `metadata: %{field: :input}`. Also a conversion
       rather than a raise: the elements reach the request-body builder, and a
       raise there would surface as an `ArgumentError` from
       `ALLM.EmbeddingBatch.dispatch_chunk/2` two layers up.
    4. **Model.** A missing or non-binary `:model` → `:invalid_request` with
       `metadata: %{field: :model}`.

  Capability pre-flight against a model catalog is NOT performed here — it
  lives in `ALLM.embed/3`. A direct adapter call bypasses it by design.

  ## Request-id preservation

  `opts[:request_id]` is reflected onto `response.request_id`.
  `request.metadata` round-trips onto `response.metadata` untouched.

  > #### There is no provider-side request id to fall back to {: .info}
  >
  > `ALLM.Providers.OpenAI.Embeddings` falls back to OpenAI's `x-request-id`
  > response header when `opts[:request_id]` is absent.
  > `batchEmbedContents` emits no correlation header of any kind, so this
  > adapter has nothing to fall back to and leaves `response.request_id` `nil`.
  > Pass your own `opts[:request_id]` — which `ALLM.embed/3` always does, and
  > generates when the caller omits it.

  ## Error-struct hygiene

  `%ALLM.Error.EmbeddingAdapterError{}` derives `Jason.Encoder` and is commonly
  logged and persisted, so this adapter never copies a raw response body, a
  request header, or any API-key value into `:cause`, `:metadata`, or
  `:message`. Provider error messages pass through a redactor that replaces
  Google-shaped credentials (`AIza…` API keys and `ya29.…` OAuth tokens) with
  `[REDACTED]`.

  The HTTP status → reason table is **not** duplicated here: the chat adapter
  `ALLM.Providers.Gemini` owns it and this adapter delegates to it, translating
  the resulting reason atom into the narrower embeddings error enum.

  ## Retry integration

  HTTP-error closures return `{:retry, delay_ms, error}` for 429 (honouring
  `Retry-After`), 5xx, timeouts, and transport failures; `ALLM.Retry.run/3` is
  wrapped around each attempt. The closure returns real reason atoms rather
  than swapping in HTTP status codes, so for `:rate_limited`,
  `:provider_unavailable`, and `:network_error` the façade's widened
  `retry_on` list is what decides — none of them appears in this adapter's own
  `opts[:retry]` policy, which defaults to `:default`.

  `:timeout` is the documented exception: it is a member of **both** lists, so
  through `ALLM.embed/3` the adapter's inner `ALLM.Retry.run/3` and the
  façade's outer one both retry it and the attempt budgets multiply
  (3 × 3 = 9 HTTP attempts at the default policy, against 3 for every other
  retryable reason). A direct `embed/2` call takes the inner loop only and
  makes 3. Every bundled image and embeddings adapter has the identical shape,
  so this is a library-wide characteristic rather than a Gemini one, and
  correcting it per-adapter would make the adapters diverge from each other.

  ## Test-injection escape hatch

  `embed/2` honours `opts[:adapter_opts][:embedding_script]` as a documented
  test-only short-circuit: when the key is present, the call delegates to
  `ALLM.Providers.FakeEmbeddings.embed/2` BEFORE any pre-flight gate runs and
  returns its result verbatim. This is what lets the injectable
  `ALLM.EmbeddingAdapter` conformance suite drive a real adapter without an
  HTTP stub library.

  The switch keys on the presence of that per-call key and **nothing else** —
  no environment variable, no application config, no `:persistent_term` — so it
  stays confined to an explicit argument. Setting `adapter_opts` already
  implies full control of the call. Production callers do not populate it.

  `prepare_request/2` deliberately does NOT delegate under the same key: a
  scripted response has no `Req.Request` analogue, so it returns a stub error
  instead.
  """

  @behaviour ALLM.EmbeddingAdapter

  require Logger

  alias ALLM.{Embedding, EmbeddingRequest, EmbeddingResponse, Keys, Retry, Usage}
  alias ALLM.Error.EmbeddingAdapterError
  alias ALLM.Providers.{FakeEmbeddings, Gemini}
  alias ALLM.Providers.Support.GeminiHeaders

  @base_url "https://generativelanguage.googleapis.com/v1beta"
  @adapter_max_batch_size 100

  # `gemini-embedding-001`'s native width, at which Google returns
  # pre-normalized vectors. Any OTHER non-nil dimensionality is normalized
  # in-adapter — see the "Normalization" moduledoc section for why this is
  # deliberately not a per-model table.
  @pre_normalized_dimensions 3072

  # The closed provider-neutral task-type enum, mapped exhaustively onto
  # Gemini's wire enum. Anything outside it is OMITTED rather than stringified:
  # `ALLM.Serializer.to_atom_field/1` is `String.to_existing_atom/1`, so a
  # decoded `:task_type` may be any already-loaded atom, and
  # `Atom.to_string/1` would put it on the wire.
  @task_types %{
    search_document: "RETRIEVAL_DOCUMENT",
    search_query: "RETRIEVAL_QUERY",
    classification: "CLASSIFICATION",
    clustering: "CLUSTERING",
    similarity: "SEMANTIC_SIMILARITY"
  }

  # Shared by all three sites that reject an off-shape `:input` — the container
  # gate, the element gate, and `to_batch_body/2`'s seam-level defence — so the
  # three cannot drift apart into different text for the same rejection.
  @input_shape_message "input must be a list of strings"

  # `ALLM.Error.AdapterError`'s enum is wider than
  # `ALLM.Error.EmbeddingAdapterError`'s (it carries `:content_filter` and
  # others that have no embeddings meaning). Anything outside this set
  # collapses to `:unknown` rather than raising out of
  # `EmbeddingAdapterError.new/2`, which would violate behaviour invariant 2.
  @translatable_reasons ~w(
    authentication_failed rate_limited invalid_request context_length_exceeded
    provider_unavailable timeout network_error malformed_response unsupported_feature
  )a

  # ---------------------------------------------------------------------------
  # ALLM.EmbeddingAdapter callbacks
  # ---------------------------------------------------------------------------

  @doc """
  Return the maximum number of inputs Gemini accepts in one
  `batchEmbedContents` call.

  Per-module and constant, not per-model.

  ## Examples

      iex> ALLM.Providers.Gemini.Embeddings.max_batch_size
      100
  """
  @impl ALLM.EmbeddingAdapter
  @spec max_batch_size() :: pos_integer()
  def max_batch_size, do: @adapter_max_batch_size

  @doc """
  Execute a text-embedding request synchronously against Gemini.

  Returns `{:ok, %ALLM.EmbeddingResponse{}}` or
  `{:error, %ALLM.Error.EmbeddingAdapterError{}}`; every HTTP-shaped failure
  converts, including transport errors. The one documented exception is
  `ALLM.Keys.fetch!/2`, which raises
  `%ALLM.Error.EngineError{reason: :missing_key}` by design and is not rescued
  here — all three pre-flight gates run ahead of it, so a request rejected
  pre-flight never needs a key.

  See the module documentation for the gate order, the wire-field map, the
  no-injected-defaults policy for a `nil` `:model`, the normalization rule, and
  the `adapter_opts[:embedding_script]` test-injection short-circuit.

  ## Examples

      iex> e = ALLM.Embedding.new(vector: [0.1, 0.2])
      iex> req = ALLM.EmbeddingRequest.new(input: ["a kestrel"])
      iex> opts = [adapter_opts: [embedding_script: [{:ok, [e]}]]]
      iex> {:ok, resp} = ALLM.Providers.Gemini.Embeddings.embed(req, opts)
      iex> ALLM.EmbeddingResponse.vectors(resp)
      [[0.1, 0.2]]

      iex> req = ALLM.EmbeddingRequest.new(input: [], model: "gemini-embedding-001")
      iex> {:error, err} = ALLM.Providers.Gemini.Embeddings.embed(req, [])
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
  input is a non-empty list no longer than `max_batch_size/0` and whose
  `:model` is set.

  Under `opts[:adapter_opts][:embedding_script]` this returns a stub error
  rather than delegating to `ALLM.Providers.FakeEmbeddings` — a scripted
  response has no `Req.Request` analogue. That asymmetry with `embed/2` is
  deliberate.

  ## Examples

      iex> req = ALLM.EmbeddingRequest.new(input: ["hi"], model: "gemini-embedding-001")
      iex> {:ok, http} = ALLM.Providers.Gemini.Embeddings.prepare_request(req, api_key: "AIza-x")
      iex> URI.to_string(http.url)
      "https://generativelanguage.googleapis.com/v1beta/models/gemini-embedding-001:batchEmbedContents"
  """
  @impl ALLM.EmbeddingAdapter
  @spec prepare_request(EmbeddingRequest.t(), keyword()) ::
          {:ok, Req.Request.t()} | {:error, EmbeddingAdapterError.t()}
  def prepare_request(%EmbeddingRequest{} = request, opts) when is_list(opts) do
    case fetch_embedding_script(opts) do
      nil ->
        with :ok <- run_gates(request, opts),
             {:ok, body} <- to_batch_body(request, opts) do
          build_request(body, request, opts)
        end

      _script ->
        {:error, stub_error(opts)}
    end
  end

  # ---------------------------------------------------------------------------
  # Naming parity with `ALLM.Providers.OpenAI.Embeddings`.
  #
  # This block binds `ALLM.Providers.Voyage.Embeddings` (20.6) to the same names
  # so reader pattern-recognition flips between the three files. Per CLAUDE.md,
  # cross-provider alignment governs NAMES, not visibility, arity, or body — so
  # the three lists below are partitioned on exactly that axis and are mutually
  # exclusive. A function appears in one list and one list only.
  #
  # Everything named here is a `defp` unless marked `SEAM`, which means
  # `@doc false` + `@spec` per the public-test-seam rule.
  #
  # ---- 1. IDENTICAL NAME, IDENTICAL BODY (modulo arity) ---------------------
  #   Copy these verbatim into 20.6.
  #   * SEAM `to_embedding_adapter_error/4`, SEAM `max_batch_size/0`
  #   * `build_metadata/2`, `run_one_attempt/3`, `classify_http_error/4`,
  #     `stub_error/1`, `fetch_embedding_script/1`, `maybe_apply_req_test_stub/2`,
  #     `maybe_apply_request_timeout/2`, `gate_empty_input/2`, `gate_batch_size/2`,
  #     `sanitize_cause/1`, `malformed_error/3`, `build_retry_telemetry_meta/1`
  #
  # ---- 2. IDENTICAL NAME, DIVERGENT BODY -----------------------------------
  #   Keep the NAME in 20.6; re-derive the body for the provider.
  #   * SEAM `decode_response/4` ignores its `headers` argument. Gemini's
  #     `batchEmbedContents` returns no correlation-id header, so there is no
  #     provider-side `request_id` to fall back to (the OpenAI sibling reads
  #     `x-request-id` there). The argument is kept for family alignment.
  #     20.6 MUST check Voyage's actual response headers rather than porting
  #     either branch on faith.
  #   * `redact_key_material/1` matches Google credential shapes (`AIza…`,
  #     `ya29.…`). The OpenAI sibling's `sk-`/`rk-`/`org-` pattern catches
  #     NOTHING here; inheriting it verbatim would be a redactor that redacts
  #     nothing. `ALLM.Providers.Voyage.Embeddings` (`pa-…`) must widen it in
  #     turn rather than copying either.
  #   * `log_dropped_task_type/1` is arity 1 in both adapters, but takes a
  #     different argument and returns a different value. Here it takes the
  #     `:task_type` ATOM and returns `nil` as a pipeline value from
  #     `task_type_pair/1`'s `case`, so the caller treats "dropped" and "absent"
  #     identically. The OpenAI sibling takes the whole `%EmbeddingRequest{}`
  #     and returns `:ok` for side effect only. Keep the name; pick the argument
  #     and return that suit the call position, and say which in a comment.
  #
  # ---- 3. DIVERGENT NAME ----------------------------------------------------
  #   Present here under a name the OpenAI sibling does not use. Each entry says
  #   whether 20.6 should adopt the name or leave it Gemini's alone.
  #   * `gate_input/2` is NEW in 20.5 and has no OpenAI counterpart — the
  #     sibling passes `request.input` through to `Jason`, which encodes a
  #     non-string element and earns a provider 400. Gemini's body builder
  #     reaches inside each element, so an unvalidated one used to raise
  #     `Protocol.UndefinedError` (invariant-2 violation, see `sub_request/3`).
  #     **20.6 SHOULD adopt this name** under the same `gate_*/2` prefix if its
  #     body builder likewise inspects elements.
  #   * SEAM `to_batch_body/2` vs the OpenAI sibling's `to_json_body/2`. Two
  #     reasons. The name: Gemini's body is an array of per-item sub-requests,
  #     not one request with an array-valued field, and "batch body" is what
  #     that is. The RETURN TYPE: `{:ok, map()} | {:error, _}` rather than a
  #     bare `map()`, because the `nil`-model rejection has nowhere else to
  #     live — the model is required per sub-request AND in the URL, so it is
  #     the body builder that discovers it is missing. This matches the Gemini
  #     image adapter's `to_image_request_body/2`, which is likewise
  #     tuple-returning, so the divergence is with the embeddings capability
  #     family and the alignment is with the Gemini provider family. Voyage has
  #     no `Voyage.Images` sibling and so has only the capability axis: 20.6
  #     returns a bare `map()` from `to_json_body/2` unless a per-provider
  #     invariant forces otherwise.
  #   * SEAM `endpoint_url/2` is Gemini-only. `@base_url` is overridable via
  #     `adapter_opts[:endpoint]` here and hardcoded on the OpenAI adapters;
  #     this is the one place the two are expected to differ.
  #   * SEAM `maybe_normalize/2` is Gemini-only — no other provider returns
  #     unnormalized vectors at truncated dimensionalities.
  #   * SEAM `to_gemini_task_type/1` — the per-provider member of the family's
  #     `to_<provider>_task_type/1` trio. OpenAI ships none at all (no wire
  #     field); Voyage's is lossy (two members, three omissions).
  #   * SEAM `translate_reason/1` is Gemini-only. OpenAI classifies inline, so
  #     it has no foreign reason enum to narrow. This exists because
  #     `ALLM.Providers.Gemini.classify_error/3` is owned by the chat adapter
  #     and its `AdapterError` enum is wider than the embeddings one; it is a
  #     seam rather than a `defp` because the branch it guards (invariant 2 —
  #     never raise) is not otherwise reachable from a test. The seam is only
  #     worth its widened surface if a test USES it: see the
  #     `describe "translate_reason/1"` block in
  #     `test/allm/providers/gemini/embeddings_test.exs`, which pins the
  #     `@translatable_reasons ⊆ EmbeddingAdapterError.legal_reasons/0` subset
  #     property across both enums. 20.6: promote to a seam only alongside that
  #     test, otherwise leave it `defp`.
  #   * `provider_message/2` is Gemini-only, and exists because this adapter
  #     delegates classification. The OpenAI sibling redacts the message it
  #     extracted itself; here the message arrives on a typed
  #     `%ALLM.Error.AdapterError{}` whose `:message` is declared `String.t()`,
  #     which is optimistic enough that Dialyzer proves `redact_key_material/1`'s
  #     non-binary arm unreachable. Re-reading the message off the raw body is
  #     what keeps that defensive arm reachable and visible to Dialyzer, and it
  #     is the more honest seam anyway — redaction operates on untrusted
  #     provider text, not on a typed struct field.
  #   * `parse_retry_after/1` does not exist here at all: `Retry-After` parsing
  #     is inherited from `ALLM.Providers.Gemini.classify_error/3`, which
  #     already reads the header. The OpenAI embeddings adapter carries its own
  #     because it classifies inline.
  # ---------------------------------------------------------------------------

  @doc false
  # Adapter-injected defaults: NONE. A `nil` `:model` is REJECTED rather than
  # defaulted (the public `@moduledoc` states why), `:truncate` is emitted only
  # when `false`, and `:task_type` outside the closed enum is omitted.
  @spec to_batch_body(EmbeddingRequest.t(), keyword()) ::
          {:ok, map()} | {:error, EmbeddingAdapterError.t()}
  def to_batch_body(request, opts)

  def to_batch_body(%EmbeddingRequest{model: model, input: input} = request, _opts)
      when is_binary(model) and is_list(input) do
    prefixed = prefix_model(model)
    {:ok, %{"requests" => Enum.map(input, &sub_request(&1, request, prefixed))}}
  end

  # Unreachable through `embed/2` and `prepare_request/2` — `gate_input/2` runs
  # first on both paths. Kept as seam-level defence because `to_batch_body/2` is
  # a public `@doc false` seam that tests and future callers invoke directly,
  # and a `FunctionClauseError` out of it would surface as an `ArgumentError`
  # from `ALLM.EmbeddingBatch.dispatch_chunk/2` two layers up. Pinned by a
  # direct-call test so the clause is not merely asserted to exist.
  def to_batch_body(%EmbeddingRequest{model: model}, opts) when is_binary(model) do
    {:error, invalid_request(@input_shape_message, %{field: :input}, opts)}
  end

  def to_batch_body(%EmbeddingRequest{}, opts) do
    {:error,
     invalid_request(
       "model is required: Gemini needs it in the URL and on every sub-request",
       %{field: :model},
       opts
     )}
  end

  @doc false
  @spec to_gemini_task_type(atom()) :: String.t() | nil
  def to_gemini_task_type(task_type) when is_atom(task_type) do
    Map.get(@task_types, task_type)
  end

  @doc false
  @spec endpoint_url(EmbeddingRequest.t(), keyword()) :: String.t()
  def endpoint_url(%EmbeddingRequest{model: model}, opts) when is_binary(model) do
    base_url(opts) <> "/models/" <> strip_model_prefix(model) <> ":batchEmbedContents"
  end

  @doc false
  @spec maybe_normalize([Embedding.t()], pos_integer() | nil) :: [Embedding.t()]
  def maybe_normalize(embeddings, dimensions)

  def maybe_normalize(embeddings, nil), do: embeddings
  def maybe_normalize(embeddings, @pre_normalized_dimensions), do: embeddings

  def maybe_normalize(embeddings, dimensions) when is_integer(dimensions) do
    Enum.map(embeddings, &Embedding.normalize/1)
  end

  def maybe_normalize(embeddings, _dimensions), do: embeddings

  @doc false
  @spec translate_reason(atom()) :: EmbeddingAdapterError.reason()
  def translate_reason(reason) when reason in @translatable_reasons, do: reason
  def translate_reason(_reason), do: :unknown

  @doc false
  @spec to_embedding_adapter_error(
          non_neg_integer(),
          map(),
          Enumerable.t() | map(),
          keyword()
        ) :: EmbeddingAdapterError.t()
  def to_embedding_adapter_error(status, body, headers, opts)
      when is_integer(status) and is_map(body) do
    # The status -> reason table is the chat adapter's, deliberately not a
    # second copy. `:cause` is NOT propagated: it is a `Jason.Encoder`-derived
    # field that downstream apps persist.
    chat_error = Gemini.classify_error(status, body, headers)

    EmbeddingAdapterError.new(translate_reason(chat_error.reason),
      provider: :gemini,
      status: chat_error.status,
      retry_after_ms: chat_error.retry_after_ms,
      message: body |> provider_message(chat_error.message) |> redact_key_material(),
      metadata: build_metadata(Map.put(chat_error.metadata, :status, status), opts)
    )
  end

  @doc false
  @spec decode_response(term(), Enumerable.t() | map(), EmbeddingRequest.t(), keyword()) ::
          {:ok, EmbeddingResponse.t()} | {:error, EmbeddingAdapterError.t()}
  def decode_response(body, headers, request, opts)

  def decode_response(%{"embeddings" => list} = body, _headers, %EmbeddingRequest{} = request, opts)
      when is_list(list) do
    case decode_embeddings_list(list, opts) do
      {:ok, embeddings} ->
        {:ok,
         %EmbeddingResponse{
           # No provider id and no correlation header on this endpoint — see
           # the "Request-id preservation" moduledoc section.
           request_id: Keyword.get(opts, :request_id),
           model: request.model,
           embeddings: maybe_normalize(embeddings, request.dimensions),
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
       ~s(missing or non-list "embeddings" field),
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

  # Gate ordering: :invalid_request -> :batch_too_large, then the model gate
  # inside `to_batch_body/2` — ALL of them ahead of `Keys.fetch!/2`. Key
  # resolution happening after the gates is what keeps the two unscripted
  # conformance cases green in a keyless environment.
  defp run_gates(%EmbeddingRequest{} = request, opts) do
    with :ok <- gate_empty_input(request, opts),
         :ok <- gate_batch_size(request, opts) do
      gate_input(request, opts)
    end
  end

  defp gate_empty_input(%EmbeddingRequest{input: []}, opts) do
    {:error, invalid_request("input must not be empty", %{field: :input}, opts)}
  end

  defp gate_empty_input(%EmbeddingRequest{}, _opts), do: :ok

  defp gate_batch_size(%EmbeddingRequest{input: input}, opts) when is_list(input) do
    count = length(input)
    max = max_batch_size()

    if count > max do
      {:error,
       EmbeddingAdapterError.new(:batch_too_large,
         provider: :gemini,
         message: "input count #{count} exceeds max_batch_size #{max}",
         metadata: build_metadata(%{count: count, max: max}, opts)
       )}
    else
      :ok
    end
  end

  # `gate_empty_input/2`'s catch-all passes any non-`[]` term through, so this
  # is where a non-list `:input` is caught. It must convert rather than
  # raise: `ALLM.EmbeddingBatch.dispatch_chunk/2` raises `ArgumentError` on any
  # return outside the `{:ok, _} | {:error, _}` union, so a
  # `FunctionClauseError` here would surface as a batcher bug two layers up.
  defp gate_batch_size(%EmbeddingRequest{}, opts) do
    {:error, invalid_request(@input_shape_message, %{field: :input}, opts)}
  end

  # The container gate above defends the LIST; this defends its ELEMENTS, for
  # the same invariant-2 reason and against the same `dispatch_chunk/2`
  # consequence. A JSON-sourced `:input` yields maps and lists as readily as
  # strings, and every one of them reaches the request-body builder — where
  # anything non-binary would previously raise `Protocol.UndefinedError` out of
  # `to_string/1`, i.e. a raise from the one adapter that documents the
  # container shape as explicitly defended. `ALLM.Validate.embedding_request/1`
  # catches this at the façade; a direct Layer-B call has only this gate.
  # One total clause rather than a guarded clause plus a catch-all: the
  # container half is already the previous gate's job, so a second clause for it
  # would be dead code. `and` short-circuits, so `Enum.all?/2` never sees a
  # non-list.
  defp gate_input(%EmbeddingRequest{input: input}, opts) do
    if is_list(input) and Enum.all?(input, &is_binary/1) do
      :ok
    else
      {:error, invalid_request(@input_shape_message, %{field: :input}, opts)}
    end
  end

  defp invalid_request(message, metadata, opts) do
    EmbeddingAdapterError.new(:invalid_request,
      provider: :gemini,
      message: message,
      metadata: build_metadata(metadata, opts)
    )
  end

  defp stub_error(opts) do
    EmbeddingAdapterError.new(:unknown,
      provider: :gemini,
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
         {:ok, body} <- to_batch_body(request, opts),
         {:ok, http_req} <- build_request(body, request, opts) do
      retry_policy = Keyword.get(opts, :retry, :default)
      telemetry_meta = build_retry_telemetry_meta(opts)

      Retry.run(retry_policy, telemetry_meta, fn ->
        run_one_attempt(http_req, request, opts)
      end)
    end
  end

  # `Keys.fetch!/2` raises `%EngineError{reason: :missing_key}` on a miss by
  # documented design — deliberately not rescued, mirroring the sibling
  # adapters. It runs here, AFTER every gate.
  defp build_request(body, %EmbeddingRequest{} = request, opts) do
    api_key = Keys.fetch!(:gemini, opts)

    req =
      Req.new(
        method: :post,
        url: endpoint_url(request, opts),
        headers: GeminiHeaders.headers(api_key),
        json: body
      )
      |> maybe_apply_req_test_stub(opts)
      |> maybe_apply_request_timeout(opts)

    {:ok, req}
  end

  # Unlike the OpenAI adapters, the base URL is overridable — the Gemini
  # adapters honour `adapter_opts[:endpoint]` so callers can point at a proxy.
  # A non-binary value falls back to the default rather than raising a
  # `CaseClauseError`.
  defp base_url(opts) do
    case opts |> Keyword.get(:adapter_opts, []) |> Keyword.get(:endpoint) do
      url when is_binary(url) -> url
      _ -> @base_url
    end
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
  # Internals — request body builder
  # ---------------------------------------------------------------------------

  # Idempotent on both sides so a caller who already wrote the fully-qualified
  # name is neither double-prefixed on the wire nor doubled in the URL path.
  defp prefix_model("models/" <> _rest = model), do: model
  defp prefix_model(model), do: "models/" <> model

  defp strip_model_prefix("models/" <> rest), do: rest
  defp strip_model_prefix(model), do: model

  # `text` is passed through verbatim, exactly as
  # `ALLM.Providers.OpenAI.Embeddings.to_json_body/2` passes `request.input`.
  # It is a binary on every reachable path — `gate_input/2` rejects anything
  # else ahead of here — and on a direct `to_batch_body/2` seam call a
  # non-binary encodes to JSON and earns a provider 400, which is a converted
  # `{:error, _}`. An earlier `materialize_text/1` called `to_string/1` here and
  # raised `Protocol.UndefinedError` on a map element instead: that is the
  # invariant-2 violation the gate now prevents, and stringifying was never the
  # safer option, only the earlier one.
  defp sub_request(text, %EmbeddingRequest{} = request, prefixed_model) do
    %{
      "model" => prefixed_model,
      "content" => %{"parts" => [%{"text" => text}]}
    }
    |> put_pair(dimensions_pair(request))
    |> put_pair(task_type_pair(request))
    |> put_pair(auto_truncate_pair(request))
  end

  defp put_pair(map, nil), do: map
  defp put_pair(map, {key, value}), do: Map.put(map, key, value)

  defp dimensions_pair(%EmbeddingRequest{dimensions: nil}), do: nil

  defp dimensions_pair(%EmbeddingRequest{dimensions: d}) when is_integer(d),
    do: {"outputDimensionality", d}

  defp dimensions_pair(_request), do: nil

  defp task_type_pair(%EmbeddingRequest{task_type: nil}), do: nil

  defp task_type_pair(%EmbeddingRequest{task_type: task_type}) when is_atom(task_type) do
    case to_gemini_task_type(task_type) do
      nil -> log_dropped_task_type(task_type)
      wire -> {"taskType", wire}
    end
  end

  defp task_type_pair(_request), do: nil

  defp log_dropped_task_type(task_type) do
    Logger.debug(fn ->
      "ALLM.Providers.Gemini.Embeddings: task_type #{inspect(task_type)} is outside the " <>
        "provider-neutral enum; omitting taskType."
    end)

    nil
  end

  # `truncate: true` is the provider-side default and is omitted entirely.
  # The nesting under `embedContentConfig` is load-bearing — see the
  # "Truncation" moduledoc section and the placement probe in
  # `scripts/record_gemini_embeddings_fixtures.exs`.
  defp auto_truncate_pair(%EmbeddingRequest{truncate: false}),
    do: {"embedContentConfig", %{"autoTruncate" => false}}

  defp auto_truncate_pair(_request), do: nil

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
           provider: :gemini,
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
           provider: :gemini,
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
  # Internals — error hygiene
  # ---------------------------------------------------------------------------

  defp malformed_error(detail, metadata, opts, cause \\ nil) do
    EmbeddingAdapterError.new(:malformed_response,
      provider: :gemini,
      message: "could not parse Gemini embeddings response: " <> detail,
      cause: cause,
      metadata: build_metadata(metadata, opts)
    )
  end

  # `%EmbeddingAdapterError{}` derives `Jason.Encoder` and is routinely logged
  # and persisted, so `:cause` must never smuggle a raw response body through.
  # `Jason.DecodeError` carries the whole undecodable payload on `:data`;
  # a `%Req.TransportError{}`'s CONTENTS are only a reason atom.
  #
  # Confidentiality is therefore intact, but note what this does NOT fix: the
  # sanitized cause is still a `%Req.TransportError{}` / `%Jason.DecodeError{}`
  # STRUCT, and neither implements `Jason.Encoder`, so `Jason.encode!/1` on the
  # surrounding error raises `Protocol.UndefinedError` on all three
  # transport/decode paths. The struct is where the defect hides, not its
  # contents. This is library-wide — the committed 20.4 OpenAI sibling and the
  # shipped v0.4 `ALLM.Providers.Gemini.Images` fail identically — so per
  # cross-phase bug discipline it is ticketed in `ASKS.md` and fixed across all
  # adapters at once, not diverged here.
  defp sanitize_cause(%{__struct__: Jason.DecodeError} = cause), do: %{cause | data: ""}
  defp sanitize_cause(cause), do: cause

  # Read off the RAW decoded body rather than off `chat_error.message`, which
  # `ALLM.Error.AdapterError` types as `String.t()`. That declaration is
  # optimistic: `classify_error/3` populates the field with
  # `Map.get(error, "message", default)` straight off the body, so a provider
  # or proxy answering `{"error": {"message": 123}}` puts a non-binary there.
  # Sourcing from the body keeps the non-binary arm below both reachable AND
  # visible to Dialyzer, and it is the more honest seam anyway — redaction is a
  # property of untrusted provider text, not of a typed struct field.
  defp provider_message(body, fallback) do
    case body do
      %{"error" => %{"message" => message}} -> message
      _ -> fallback
    end
  end

  # Google credential shapes: `AIza…` API keys and `ya29.…` OAuth access
  # tokens. The OpenAI sibling's `sk-`/`rk-`/`org-` pattern matches neither, so
  # this is widened rather than inherited.
  defp redact_key_material(message) when is_binary(message) do
    String.replace(
      message,
      ~r/\b(?:AIza[A-Za-z0-9_\-]{6,}|ya29\.[A-Za-z0-9_\-.]{6,})/,
      "[REDACTED]"
    )
  end

  defp redact_key_material(_message), do: "Gemini embeddings error"

  defp build_retry_telemetry_meta(opts) do
    case Keyword.get(opts, :request_id) do
      nil -> %{provider: :gemini}
      request_id -> %{provider: :gemini, request_id: request_id}
    end
  end

  # ---------------------------------------------------------------------------
  # Internals — response decoder
  # ---------------------------------------------------------------------------

  # `:index` comes from list position — Gemini's response has no index field.
  # `Enum.with_index/1` before the fold is what makes the position the index;
  # there is deliberately no sort afterwards, because there is nothing to sort
  # by that is not already the order we assigned.
  defp decode_embeddings_list(list, opts) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, acc} ->
      case decode_embedding_entry(entry, index, opts) do
        {:ok, embedding} -> {:cont, {:ok, [embedding | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      {:error, _} = err -> err
    end
  end

  defp decode_embedding_entry(%{"values" => values}, index, opts) when is_list(values) do
    cond do
      values == [] ->
        {:error, malformed_error("entry #{index} carries an empty vector", %{index: index}, opts)}

      not Enum.all?(values, &is_number/1) ->
        {:error,
         malformed_error("entry #{index} carries a non-numeric component", %{index: index}, opts)}

      true ->
        {:ok, %Embedding{vector: Enum.map(values, &(&1 * 1.0)), index: index}}
    end
  end

  defp decode_embedding_entry(_entry, index, opts) do
    {:error,
     malformed_error(
       ~s(entry #{index} is missing a list-valued "values" field),
       %{index: index},
       opts
     )}
  end

  # `:output_tokens` is always `nil` — embeddings produce no completion tokens.
  # `usageMetadata` is absent from every `batchEmbedContents` 200 observed so
  # far, so this normally yields an all-nil (but never `nil`) `%Usage{}`.
  defp build_usage(body) do
    prompt_tokens = body |> Map.get("usageMetadata") |> non_neg_int("promptTokenCount")

    %Usage{
      input_tokens: prompt_tokens,
      output_tokens: nil,
      total_tokens: prompt_tokens
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
