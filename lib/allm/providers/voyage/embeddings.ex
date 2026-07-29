defmodule ALLM.Providers.Voyage.Embeddings do
  @moduledoc """
  Voyage AI text-embeddings provider adapter — **and the Anthropic track**.

  Anthropic ships no embeddings endpoint. It never has, and the Messages API
  exposes nothing analogous; Anthropic instead names Voyage AI as its
  recommended embeddings partner and publishes a cookbook for it
  ([`how_to_create_embeddings.md`](https://github.com/anthropics/claude-cookbooks/blob/main/third_party/VoyageAI/how_to_create_embeddings.md)).
  This module is therefore what an Anthropic-stack application uses for
  embeddings, and there is deliberately **no** `ALLM.Providers.Anthropic.Embeddings`:
  that name would assert a wire that does not exist, and the key resolves from
  `VOYAGE_API_KEY`, not `ANTHROPIC_API_KEY`.

  Layer B — runtime. Constructed via
  `ALLM.Engine.new(embed_adapter: ALLM.Providers.Voyage.Embeddings, model: "voyage-3.5-lite")`
  and consumed through `ALLM.embed/3`. Keys resolve via
  `ALLM.Keys.fetch!(:voyage, opts)` at request-build time — no key ever lives on
  the engine.

      req = ALLM.EmbeddingRequest.new(input: ["hello"], model: "voyage-3.5-lite")
      {:ok, resp} = ALLM.Providers.Voyage.Embeddings.embed(req, api_key: "pa-...")
      [[_ | _]] = ALLM.EmbeddingResponse.vectors(resp)

  Nothing about this adapter is Anthropic-specific beyond that recommendation:
  a caller with no Anthropic involvement at all can use it, and an
  Anthropic-stack caller is free to point `:embed_adapter` at OpenAI or Gemini
  instead. The pairing is a default, not a coupling.

  ## Wire-field map

  | Concern | Voyage |
  |---------|--------|
  | Endpoint | `POST https://api.voyageai.com/v1/embeddings` (not overridable) |
  | Auth | `authorization: Bearer <key>` — OpenAI-shaped |
  | Input | `input` — always sent as an **array**, even for one input |
  | Model | `model` |
  | Dimensions | `output_dimension` — **snake_case**, and `256` / `512` / `1024` / `2048` on the models that support it |
  | Task type | `input_type` — `"query"` / `"document"` only; see "Task types are lossy" |
  | Truncate | `truncation` (boolean, provider default `true`) |
  | Vectors | `data[].embedding` |
  | Index | `data[].index` |
  | Usage | top-level `usage` → `total_tokens` **only**; see "Usage" |
  | Response id | **none** — no live 200 body carries a top-level `"id"`, so `%ALLM.EmbeddingResponse{}`'s `:id` is always `nil`. Correlation comes from the `x-request-id` response header instead |
  | Errors | `{"detail": "<message>"}` — a single top-level string, **not** an `{"error": {...}}` object |
  | Batch cap | 1000 array items (`max_batch_size/0`) |

  ## Adapter-injected defaults

  **None.** The wire requires `model`, and `ALLM.EmbeddingRequest` permits
  `model: nil`. This adapter does **not** invent a default model: a `nil`
  `:model` is OMITTED from the body and Voyage answers with a 400, surfaced as
  `%ALLM.Error.EmbeddingAdapterError{reason: :invalid_request}`. Guessing an
  embedding model would silently produce vectors of an unexpected
  dimensionality — or from a different vector space entirely — into a caller's
  vector column, which is unrecoverable after the fact. `ALLM.embed/3` stamps
  the engine's resolved model onto the request before dispatch, so this only
  arises on a direct adapter call.

  ## Task types are lossy, and the loss is documented rather than errored

  `ALLM.EmbeddingRequest`'s provider-neutral `:task_type` enum has five members;
  Voyage's `input_type` has two.

  | `:task_type` | `input_type` |
  |--------------|--------------|
  | `:search_document` | `"document"` |
  | `:search_query` | `"query"` |
  | `:classification` | **omitted** |
  | `:clustering` | **omitted** |
  | `:similarity` | **omitted** |

  The three omissions are not a degradation. Voyage documents an absent (null)
  `input_type` as "no retrieval prompt is prepended", which is exactly the right
  semantic for a symmetric task — classification, clustering, and
  similarity all compare embeddings against each other rather than queries
  against documents, and prepending an asymmetric retrieval prompt to one side
  would be wrong. The drop is logged at `:debug`.

  ## Usage

  Voyage reports **`usage.total_tokens` and nothing else** — there is no
  `prompt_tokens` counter, which is the one place this adapter's `ALLM.Usage`
  mapping diverges from its OpenAI sibling's:

      %ALLM.Usage{input_tokens: nil, output_tokens: nil, total_tokens: 4}

  `:input_tokens` is `nil` because Voyage does not report it, not because the
  value is zero. `:output_tokens` is `nil` because embeddings produce no
  completion tokens. `:usage` itself is never `nil`. Callers doing per-request
  cost accounting should read `:total_tokens`; on this provider every input
  token is a total token, since there is no output side.

  ## Truncation

  `truncate: true` is the provider-side default and is omitted from the wire
  entirely; `truncate: false` is emitted as `truncation: false`. Under the
  default, an over-length input is silently truncated to the model's context
  window and billed at the full window. With `truncation: false` the same input
  is a 400 naming the window size, which this adapter maps to
  `%ALLM.Error.EmbeddingAdapterError{reason: :context_length_exceeded}` — so
  setting `truncate: false` is how a caller finds out that their chunks are too
  long instead of silently embedding a prefix of each.

  ## Pre-flight gates

  Before any HTTP I/O — and, deliberately, before `ALLM.Keys.fetch!/2`, so a
  request that is going to be rejected never needs a valid API key:

    1. **Empty input.** `input: []` → `:invalid_request`.
    2. **Batch size.** `length(input) > 1000` → `:batch_too_large` with
       `metadata: %{count: n, max: 1000}`. An `:input` that is not a list at all
       — Voyage's own wire accepts a bare string, so it is the likeliest
       direct-adapter mistake — is rejected here as `:invalid_request` with
       `metadata: %{field: :input}` rather than raising.
    3. **Input elements.** An `:input` list containing a non-string element →
       `:invalid_request` with `metadata: %{field: :input}`. Also a conversion
       rather than a raise; see "Why the element gate exists here" below.

  Capability pre-flight against a model catalog is NOT performed here — it lives
  in `ALLM.embed/3`. A direct adapter call bypasses it by design.

  ### Why the element gate exists here

  The request-body builder passes `:input` to the JSON encoder verbatim, so a
  map or integer element would merely earn a provider 400 — a converted
  `{:error, _}`, which is fine. A **tuple** element is not: `Jason` has no
  encoder for it and raises `Protocol.UndefinedError` from inside
  `Req.request/1`, past every gate, which is a breach of
  `ALLM.EmbeddingAdapter` invariant 2 and surfaces two layers up as an
  `ArgumentError` out of the batcher. Rejecting every non-binary element
  up-front closes that hole and costs a round-trip nothing, since the
  alternative outcome for the encodable cases was a 400 anyway.

  ## Response ordering

  `data[]` is sorted by `:index` before it becomes `:embeddings`. Voyage
  publishes that field for the same reason OpenAI does — array order is not
  contractual — and `ALLM.EmbeddingResponse`'s order-correspondence invariant
  depends on it.

  ## Request-id preservation

  `opts[:request_id]` is reflected onto `response.request_id` unchanged. When it
  is absent, the adapter falls back to Voyage's `x-request-id` response header,
  which this endpoint emits on both success and error responses.
  `request.metadata` round-trips onto `response.metadata` untouched.

  > #### The `x-request-id` fallback is unreachable through `ALLM.embed/3` {: .warning}
  >
  > The façade always supplies `opts[:request_id]` (it generates one when the
  > caller does not), so on that path the left branch always wins and Voyage's
  > own correlation id is never observed. It surfaces only on a direct
  > `embed/2` / `decode_response/4` call that omits `opts[:request_id]`.
  > Stamping it into `response.metadata` instead would contradict
  > `ALLM.EmbeddingAdapter` invariant 7's requirement that `request.metadata`
  > round-trip **unchanged**, so the divergence is deliberate. Callers who need
  > Voyage's request id for a support ticket should pass their own
  > `opts[:request_id]` and correlate on that.

  ## Error-struct hygiene

  `%ALLM.Error.EmbeddingAdapterError{}` derives `Jason.Encoder` and is commonly
  logged and persisted, so this adapter never copies a raw response body, a
  request header, or any `Authorization` value into `:cause`, `:metadata`, or
  `:message`. Provider error messages pass through a redactor that replaces
  Voyage-shaped credentials (`pa-…`) with `[REDACTED]`.

  Voyage's real 401 text is `"Provided API key is invalid."` and does **not**
  echo the offending key back, so the redactor here is defence in depth rather
  than a response to observed leakage — but the error `detail` is untrusted
  provider prose either way, and the OpenAI sibling's `sk-`/`rk-`/`org-` pattern
  would match nothing on this provider.

  ## Retry integration

  HTTP-error closures return `{:retry, delay_ms, error}` for 429 (honouring
  `Retry-After`), 5xx, timeouts, and transport failures; `ALLM.Retry.run/3` is
  wrapped around each attempt. The closure returns real reason atoms rather than
  swapping in HTTP status codes, so for `:rate_limited`, `:provider_unavailable`,
  and `:network_error` the façade's widened `retry_on` list is what decides —
  none of them appears in this adapter's own `opts[:retry]` policy, which
  defaults to `:default`.

  `:timeout` is the documented exception: it is a member of **both** lists, so
  through `ALLM.embed/3` the adapter's inner `ALLM.Retry.run/3` and the façade's
  outer one both retry it and the attempt budgets multiply (3 × 3 = 9 HTTP
  attempts at the default policy, against 3 for every other retryable reason). A
  direct `embed/2` call takes the inner loop only and makes 3. Every bundled
  image and embeddings adapter has the identical shape, so this is a
  library-wide characteristic rather than a Voyage one, and correcting it
  per-adapter would make the adapters diverge from each other.

  ## Test-injection escape hatch

  `embed/2` honours `opts[:adapter_opts][:embedding_script]` as a documented
  test-only short-circuit: when the key is present, the call delegates to
  `ALLM.Providers.FakeEmbeddings.embed/2` BEFORE any pre-flight gate runs and
  returns its result verbatim. This is what lets the injectable
  `ALLM.EmbeddingAdapter` conformance suite drive a real adapter without an HTTP
  stub library.

  The switch keys on the presence of that per-call key and **nothing else** — no
  environment variable, no application config, no `:persistent_term` — so it
  stays confined to an explicit argument. Setting `adapter_opts` already implies
  full control of the call. Production callers do not populate it.

  `prepare_request/2` deliberately does NOT delegate under the same key: a
  scripted response has no `Req.Request` analogue, so it returns a stub error
  instead.
  """

  @behaviour ALLM.EmbeddingAdapter

  require Logger

  alias ALLM.{Embedding, EmbeddingRequest, EmbeddingResponse, Keys, Retry, Usage}
  alias ALLM.Error.EmbeddingAdapterError
  alias ALLM.Providers.FakeEmbeddings

  @base_url "https://api.voyageai.com/v1"
  @endpoint "/embeddings"
  @adapter_max_batch_size 1000

  # The closed provider-neutral task-type enum, mapped onto Voyage's two-member
  # `input_type`. Anything outside this map is OMITTED rather than stringified:
  # `ALLM.Serializer.to_atom_field/1` is `String.to_existing_atom/1`, so a
  # decoded `:task_type` may be any already-loaded atom, and `Atom.to_string/1`
  # would put it on the wire. The three enum members with no entry here
  # (`:classification`, `:clustering`, `:similarity`) are symmetric tasks for
  # which an omitted `input_type` is the CORRECT semantic, not a fallback —
  # see the "Task types are lossy" moduledoc section.
  @task_types %{
    search_document: "document",
    search_query: "query"
  }

  # Shared by both sites that reject an off-shape `:input` — the container gate
  # and the element gate — so the two cannot drift apart into different text for
  # the same rejection.
  @input_shape_message "input must be a list of strings"

  # Voyage carries no structured error code: the envelope is a single
  # `{"detail": "<prose>"}` string, so the context-window rejection can only be
  # recognised from its text. Both markers appear in the live 400 recorded at
  # `test/fixtures/voyage/embeddings/recorded/error_400_context_length.json`.
  #
  # Prose matching is brittle by nature, and deliberately so here: a wording
  # change degrades to `:invalid_request`, which is where a 400 lands without
  # this list at all, so the failure mode is loss of specificity rather than a
  # wrong answer. The recorded fixture is what makes a wording change visible.
  @context_length_markers ["context window", "too many tokens"]

  # ---------------------------------------------------------------------------
  # ALLM.EmbeddingAdapter callbacks
  # ---------------------------------------------------------------------------

  @doc """
  Return the maximum number of inputs Voyage accepts in one `/v1/embeddings`
  call.

  Per-module and constant, not per-model.

  ## Examples

      iex> ALLM.Providers.Voyage.Embeddings.max_batch_size
      1000
  """
  @impl ALLM.EmbeddingAdapter
  @spec max_batch_size() :: pos_integer()
  def max_batch_size, do: @adapter_max_batch_size

  @doc """
  Execute a text-embedding request synchronously against Voyage AI.

  Returns `{:ok, %ALLM.EmbeddingResponse{}}` or
  `{:error, %ALLM.Error.EmbeddingAdapterError{}}`; every HTTP-shaped failure
  converts, including transport errors. The one documented exception is
  `ALLM.Keys.fetch!/2`, which raises
  `%ALLM.Error.EngineError{reason: :missing_key}` by design and is not rescued
  here — all three pre-flight gates run ahead of it, so a request rejected
  pre-flight never needs a key.

  See the module documentation for the gate order, the wire-field map, the
  lossy `:task_type` mapping, the `usage.total_tokens`-only asymmetry, and the
  `adapter_opts[:embedding_script]` test-injection short-circuit.

  ## Examples

      iex> e = ALLM.Embedding.new(vector: [0.1, 0.2])
      iex> req = ALLM.EmbeddingRequest.new(input: ["a kestrel"])
      iex> opts = [adapter_opts: [embedding_script: [{:ok, [e]}]]]
      iex> {:ok, resp} = ALLM.Providers.Voyage.Embeddings.embed(req, opts)
      iex> ALLM.EmbeddingResponse.vectors(resp)
      [[0.1, 0.2]]

      iex> req = ALLM.EmbeddingRequest.new(input: [])
      iex> {:error, err} = ALLM.Providers.Voyage.Embeddings.embed(req, [])
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
  Return an unfired `Req.Request` configured exactly as `embed/2` would fire it,
  for callers who need to add headers, middleware, or their own retry wrapper
  before dispatch.

  The pre-flight gates run first, so this is defined only for a request whose
  input is a non-empty list of strings no longer than `max_batch_size/0`.

  Under `opts[:adapter_opts][:embedding_script]` this returns a stub error
  rather than delegating to `ALLM.Providers.FakeEmbeddings` — a scripted
  response has no `Req.Request` analogue. That asymmetry with `embed/2` is
  deliberate.

  ## Examples

      iex> req = ALLM.EmbeddingRequest.new(input: ["hi"], model: "voyage-3.5-lite")
      iex> {:ok, http} = ALLM.Providers.Voyage.Embeddings.prepare_request(req, api_key: "pa-x")
      iex> URI.to_string(http.url)
      "https://api.voyageai.com/v1/embeddings"
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
  # Naming parity across the embeddings adapter family.
  #
  # This is the THIRD and last member (`ALLM.Providers.OpenAI.Embeddings`,
  # `ALLM.Providers.Gemini.Embeddings`, this), so the lists below are stated as
  # closing the family rather than binding a successor. Per CLAUDE.md,
  # cross-provider alignment governs NAMES, not visibility, arity, or body.
  #
  # HOW TO READ THIS, and what "identical body" means. Every membership claim
  # below is mechanically checkable (`grep -n "defp <name>(" ` across the three
  # files, then diff the clauses) and every one WAS checked. "Identical body"
  # means byte-identical after normalising the provider atom (`:voyage` vs
  # `:openai` vs `:gemini`) and the provider's name inside message strings —
  # nothing else. The lists are NOT a mutually-exclusive partition: a helper can
  # be body-identical with one sibling and divergent from the other, and those
  # entries are cross-referenced in both places rather than forced into one.
  # Pretending otherwise is what made the first draft of this block wrong in
  # four places.
  #
  # Voyage's wire is OpenAI-shaped (Bearer auth, `data[].embedding`,
  # `data[].index`, a hardcoded base URL), so the OpenAI sibling is the closer
  # structural match and most of this module is list 1 against it. The
  # `gate_*` chain is the one systematic exception: it follows Gemini.
  #
  # Everything named here is a `defp` unless marked SEAM, which means
  # `@doc false` + `@spec` per the public-test-seam rule. The three
  # `ALLM.EmbeddingAdapter` callbacks are excluded from the lists — their names
  # are fixed by the behaviour, so parity is not a choice: `max_batch_size/0`
  # (identical shape in all three, different constant), `embed/2` (body
  # identical with both siblings), `prepare_request/2` (body identical with
  # OpenAI's; Gemini's differs).
  #
  # ---- 1. IDENTICAL NAME, IDENTICAL BODY (modulo arity) ---------------------
  #   Identical with BOTH siblings:
  #   * `build_metadata/2`, `build_retry_telemetry_meta/1`,
  #     `classify_http_error/4`, `decode_error_body/1`,
  #     `fetch_embedding_script/1`, `malformed_error/4`,
  #     `maybe_apply_req_test_stub/2`, `maybe_apply_request_timeout/2`,
  #     `non_neg_int/2`, `put_pair/2`, `run_one_attempt/3`, `sanitize_cause/1`,
  #     `stub_error/1`
  #     (`put_pair/2` differs from Gemini's only in its first parameter's name.)
  #
  #   Identical with the OpenAI sibling; Gemini has NO function of this name:
  #   * `decode_data_list/2`, `model_pair/1`, `parse_retry_after/1`,
  #     `retry_after_ms/1`, `header_value/2`, `header_value_to_string/1`
  #     Gemini's model rides the URL path, so it carries `prefix_model/1` +
  #     `strip_model_prefix/1` where this module and OpenAI's carry
  #     `model_pair/1`; and Gemini reads no `Retry-After` header at all, so the
  #     four retry-header helpers have no Gemini counterpart. Voyage sends
  #     `Retry-After` in delta-seconds and this adapter classifies inline, as
  #     OpenAI's does. Like the OpenAI sibling, `parse_retry_after/1` returns
  #     `nil` INLINE for an unparseable value rather than falling through to the
  #     `parse_http_date/1` stub that `openai/images.ex` and `openai.ex` carry.
  #     Behaviour is identical today; if that stub is ever implemented, all
  #     three embeddings adapters have to be revisited together.
  #
  #   Identical with the OpenAI sibling; Gemini shares the NAME with a divergent
  #   body (cross-referenced in list 2):
  #   * `decode_embedding_entry/2` — reads `data[].embedding` / `data[].index`;
  #     Gemini's reads `embedding.values` off a per-input sub-response.
  #   * `do_embed/2` — Gemini's carries an extra `with` clause for its
  #     model-prefix normalisation.
  #
  #   Identical with the GEMINI sibling; OpenAI diverges or has none:
  #   * `gate_empty_input/2`, `gate_batch_size/2` — this module and Gemini's
  #     delegate to the local `invalid_request/3`; OpenAI's inline
  #     `EmbeddingAdapterError.new/2` at each site. Same name in all three,
  #     same body only with Gemini.
  #   * `run_gates/2` — same `with` shape in all three; the third clause is
  #     `gate_input/2` here and in Gemini, `gate_dimensions_support/2` in
  #     OpenAI.
  #   * `invalid_request/3` — the constructor wrapper the two gates above
  #     delegate to. OpenAI has no counterpart under any name; it inlines. A
  #     fourth adapter should take this one from here rather than re-deriving
  #     it, which is what the inlining amounts to.
  #   * `gate_input/2` — adopted from the Gemini sibling, which introduced it.
  #     Its 20.5 note said to adopt it "if the body builder likewise inspects
  #     elements" — this one does not, it hands `:input` to the encoder
  #     verbatim like OpenAI's. It is adopted anyway for a reason that note did
  #     not cover: a TUPLE element is unencodable, so `Jason` raises
  #     `Protocol.UndefinedError` from inside `Req.request/1` past every gate.
  #     Passing elements through verbatim closes the map/integer hole (those
  #     encode and earn a 400) but not the tuple one. See the "Why the element
  #     gate exists here" moduledoc section. OpenAI ships no element gate at
  #     all and therefore still raises on that input — filed, not fixed here.
  #
  # ---- 2. IDENTICAL NAME, DIVERGENT BODY -----------------------------------
  #   * SEAM `to_json_body/2` — name shared with the OpenAI sibling (Gemini's
  #     is `to_batch_body/2`), body divergent: OpenAI's opens with
  #     `log_dropped_task_type(request)` and pipes
  #     `model_pair → dimensions_pair → user_pair`, this one pipes
  #     `model_pair → dimensions_pair → task_type_pair → truncation_pair` and
  #     logs from inside `task_type_pair/1`. What IS shared with OpenAI is the
  #     RETURN TYPE: a bare `map()`, NOT Gemini's `{:ok, map()} | {:error, _}`.
  #     Gemini's tuple is forced by a per-provider invariant (its model is
  #     required in the URL path AND on every sub-request, so the body builder
  #     is what discovers a nil model); Voyage has no such constraint and no
  #     `Voyage.Images` sibling to align with, so the CAPABILITY family wins and
  #     the shape matches OpenAI's.
  #   * `build_request/2` — arity matches OpenAI's (Gemini's is `/3`, taking the
  #     request separately because its URL embeds the model). Body diverges from
  #     both: the URL is a constant here, and the headers come from the local
  #     `headers/1` rather than `Support.OpenAIHeaders.json_headers/2`.
  #   * `decode_embedding_entry/2`, `do_embed/2` — divergent from Gemini only;
  #     see list 1 for the OpenAI relation.
  #   * `task_type_pair/1` — shared with Gemini (OpenAI has no wire slot at all
  #     and drops the field unconditionally). Emits `"input_type"` against
  #     Gemini's `"taskType"`, and its lossy `@task_types` table omits the three
  #     symmetric task types rather than erroring.
  #   * SEAM `decode_response/4` reads `data[].embedding` / `data[].index` and
  #     SORTS by index — the OpenAI shape, not Gemini's positional
  #     `embeddings[].values`. Its `headers` argument IS used: Voyage emits an
  #     `x-request-id` response header (verified live, alongside `alt-svc`,
  #     `content-type`, `date`, `server`, `via`, `x-api-warning`), so the
  #     OpenAI-style fallback is implementable here where Gemini's adapter had
  #     nothing to fall back to. This was checked against real response headers
  #     rather than ported on faith.
  #   * SEAM `to_embedding_adapter_error/4` reads the message off a single
  #     top-level `"detail"` STRING. Voyage's envelope is FastAPI-shaped —
  #     `{"detail": "..."}` — not OpenAI's `{"error": {message, type, code}}`
  #     nor Google's `{"error": {code, message, status}}`, so there is no
  #     provider code or type to forward onto `:metadata`.
  #   * `classify_embedding_reason/3` (arity 3, vs OpenAI's
  #     `classify_embedding_reason/4`): Voyage has no `code`/`type` pair, so the
  #     discriminator is the `detail` prose. The `:context_length_exceeded` arm
  #     matches `@context_length_markers` against it.
  #   * `redact_key_material/1` matches Voyage's `pa-…` key shape. The OpenAI
  #     sibling's `sk-`/`rk-`/`org-` pattern and the Gemini sibling's
  #     `AIza…`/`ya29.…` pattern each catch NOTHING here; inheriting either
  #     verbatim would be a redactor that redacts nothing. It is also SINGLE-
  #     CLAUSE here where both siblings carry a non-binary fall-through, because
  #     `default_message/2` does that narrowing first and a second guard is a
  #     clause Dialyzer proves unreachable.
  #   * `build_usage/1` populates `:total_tokens` ONLY. Voyage reports no
  #     `prompt_tokens`, so `:input_tokens` stays `nil` where the OpenAI sibling
  #     fills it and the Gemini sibling fills both from `promptTokenCount`.
  #     This is the family's one genuine `ALLM.Usage` asymmetry.
  #   * `log_dropped_task_type/1` takes the `:task_type` ATOM and returns `nil`
  #     as a pipeline value from `task_type_pair/1`'s `case`, matching Gemini's
  #     call position rather than OpenAI's (which takes the whole
  #     `%EmbeddingRequest{}` and returns `:ok` for side effect only, because
  #     OpenAI drops the field unconditionally and has no wire slot at all).
  #   * `dimensions_pair/1` emits `output_dimension` (snake_case), against
  #     OpenAI's `dimensions` and Gemini's `outputDimensionality`. All three
  #     spellings are different; the helper name is not.
  #
  # ---- 3. VOYAGE-ONLY NAMES, AND SIBLING NAMES ABSENT HERE ------------------
  #   Present only in this module:
  #   * `headers/1` — the inline-headers decision, and the one worth reading
  #     first. Both siblings call a `ALLM.Providers.Support.*Headers` module;
  #     this one builds the two-header list at its single call site. There is
  #     exactly one caller and no branches, so a `VoyageHeaders` module at n = 1
  #     is the abstraction the Rule of 3 warns about — and reusing
  #     `Support.OpenAIHeaders` would couple this adapter to its
  #     `openai-organization` branch, which Voyage rejects as an unknown
  #     argument (established by the recorder's CONTROL arm). Full reasoning at
  #     the function site. Promote if and when a second Voyage capability lands.
  #   * `default_message/2` — the shape-narrowing seam neither sibling has under
  #     any name. OpenAI reaches its default through
  #     `Map.get(error, "message", "OpenAI HTTP #{status}")`; Gemini's
  #     `provider_message/2` re-reads the message off the raw body to keep its
  #     redactor's non-binary arm reachable. Voyage's envelope is a bare string
  #     rather than a nested object, so neither shape ports: this is where a
  #     non-binary `detail` becomes `"Voyage HTTP <status>"`. It is also what
  #     makes `redact_key_material/1` safe as a single clause — see list 2.
  #   * `context_length?/1` — the prose discriminator
  #     `classify_embedding_reason/3`'s 400 arm calls. Voyage signals a
  #     context-window overflow in the `detail` string with no machine-readable
  #     code, so this is a case-insensitive `@context_length_markers` scan.
  #     Both siblings discriminate on a structured field instead (OpenAI's
  #     `code`/`type`, Gemini's `status`), so neither has a counterpart.
  #   * `truncation_pair/1` — OpenAI has no truncation field at all; Gemini's
  #     equivalent is `auto_truncate_pair/1`, named for its `autoTruncate` wire
  #     key the same way this one is named for `truncation`.
  #   * SEAM `to_voyage_task_type/1` — the per-provider member of the family's
  #     `to_<provider>_task_type/1` pair, alongside `to_gemini_task_type/1`.
  #     OpenAI ships none at all, having no wire field. Named for the
  #     provider-neutral CONCEPT it converts from rather than for Voyage's
  #     `input_type` wire spelling, which is what keeps the pair recognisable;
  #     the wire spelling lives in `task_type_pair/1` next to every other
  #     field name.
  #
  #   Named in a sibling, absent here:
  #   * `user_pair/1` does NOT exist here. It is OpenAI's request-level end-user
  #     identifier, forwarded from `options[:user]`; Voyage's schema has no such
  #     argument and rejects unknown ones with a 400 (established by the
  #     recorder's CONTROL arm), so forwarding it would break every call that
  #     set it.
  #   * `translate_reason/1` does NOT exist here. It is Gemini-only, because
  #     that adapter delegates classification to the chat adapter's wider
  #     `AdapterError` enum. This adapter classifies inline, as OpenAI's does,
  #     so there is no foreign enum to narrow. Per the 20.5 note, a reason
  #     translator is promoted to a seam only alongside its subset test; there
  #     is no translator here to promote.
  #   * `gate_dimensions_support/2` does NOT exist here. It is OpenAI-only and
  #     encodes the `text-embedding-3`-and-later `dimensions` rule. Voyage's
  #     per-model `output_dimension` support would need a hard-coded model
  #     allow-list to gate, which would reject every model Voyage ships next;
  #     an unsupported combination earns a provider 400 instead. This is why
  #     `:unsupported_feature` has no use site in this module.
  # ---------------------------------------------------------------------------

  @doc false
  # Adapter-injected defaults: NONE. A `nil` `:model` is OMITTED rather than
  # defaulted (the public `@moduledoc` states why), `:truncate` is emitted only
  # when `false`, and a `:task_type` outside Voyage's two-member `input_type`
  # is omitted.
  #
  # Returns a bare `map()`, matching `ALLM.Providers.OpenAI.Embeddings` — see
  # the naming-parity block for why the capability family wins over the
  # tuple-returning Gemini shape.
  @spec to_json_body(EmbeddingRequest.t(), keyword()) :: map()
  def to_json_body(%EmbeddingRequest{} = request, _opts) do
    %{"input" => request.input}
    |> put_pair(model_pair(request))
    |> put_pair(dimensions_pair(request))
    |> put_pair(task_type_pair(request))
    |> put_pair(truncation_pair(request))
  end

  @doc false
  @spec to_voyage_task_type(atom()) :: String.t() | nil
  def to_voyage_task_type(task_type) when is_atom(task_type) do
    Map.get(@task_types, task_type)
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
    detail = Map.get(body, "detail")
    {reason, retry_after} = classify_embedding_reason(status, detail, retry_after_ms(headers))

    message =
      detail
      |> default_message(status)
      |> redact_key_material()

    EmbeddingAdapterError.new(reason,
      provider: :voyage,
      status: status,
      retry_after_ms: retry_after,
      message: message,
      # Structural only — never a body preview. Voyage's envelope carries no
      # provider code or type to forward, so `:status` is all there is.
      metadata: build_metadata(%{status: status}, opts)
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
           # Always `nil` in practice: no Voyage 200 body carries an `"id"`
           # key (see the wire-field map). The read is kept rather than
           # dropped so the field is populated for free if Voyage ever adds
           # one, and because deleting it would make this decoder the only
           # member of the family that silently ignores a top-level response
           # id. Distinguishing "the provider does not report it" from "we did
           # not read it" is the same discipline `build_usage/1` applies to
           # `:input_tokens`.
           id: Map.get(body, "id"),
           request_id: Keyword.get(opts, :request_id) || header_value(headers, "x-request-id"),
           model: Map.get(body, "model") || request.model,
           # Sorted here, not at the call site: Voyage publishes `index`
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
       ~s(missing or non-list "data" field),
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

  # Gate ordering: :invalid_request -> :batch_too_large -> element shape, ALL of
  # them ahead of `Keys.fetch!/2`. Key resolution happening after the gates is
  # what keeps the two unscripted conformance cases green in a keyless
  # environment.
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
         provider: :voyage,
         message: "input count #{count} exceeds max_batch_size #{max}",
         metadata: build_metadata(%{count: count, max: max}, opts)
       )}
    else
      :ok
    end
  end

  # `gate_empty_input/2`'s catch-all passes any non-`[]` term through, so this is
  # where a non-list `:input` is caught. It must convert rather than raise:
  # `ALLM.EmbeddingBatch.dispatch_chunk/2` raises `ArgumentError` on any return
  # outside the `{:ok, _} | {:error, _}` union, so a `FunctionClauseError` here
  # would surface as a batcher bug two layers up.
  defp gate_batch_size(%EmbeddingRequest{}, opts) do
    {:error, invalid_request(@input_shape_message, %{field: :input}, opts)}
  end

  # The container gate above defends the LIST; this defends its ELEMENTS. A
  # JSON-sourced `:input` yields maps and lists as readily as strings, and a
  # tuple element is unencodable — `Jason` raises `Protocol.UndefinedError` from
  # inside `Req.request/1`, past every gate, which is the invariant-2 breach
  # `dispatch_chunk/2` re-frames as an `ArgumentError`. One total clause rather
  # than a guarded clause plus a catch-all: the container half is already the
  # previous gate's job, so a second clause for it would be dead code. `and`
  # short-circuits, so `Enum.all?/2` never sees a non-list.
  defp gate_input(%EmbeddingRequest{input: input}, opts) do
    if is_list(input) and Enum.all?(input, &is_binary/1) do
      :ok
    else
      {:error, invalid_request(@input_shape_message, %{field: :input}, opts)}
    end
  end

  defp invalid_request(message, metadata, opts) do
    EmbeddingAdapterError.new(:invalid_request,
      provider: :voyage,
      message: message,
      metadata: build_metadata(metadata, opts)
    )
  end

  defp stub_error(opts) do
    EmbeddingAdapterError.new(:unknown,
      provider: :voyage,
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
  # documented design — deliberately not rescued, mirroring the sibling
  # adapters. It runs here, AFTER `run_gates/2`.
  defp build_request(%EmbeddingRequest{} = request, opts) do
    api_key = Keys.fetch!(:voyage, opts)

    req =
      Req.new(
        method: :post,
        url: @base_url <> @endpoint,
        headers: headers(api_key),
        json: to_json_body(request, opts)
      )
      |> maybe_apply_req_test_stub(opts)
      |> maybe_apply_request_timeout(opts)

    {:ok, req}
  end

  # Inlined rather than extracted into a shared `VoyageHeaders` support module:
  # there is exactly one caller. `ALLM.Providers.Support.OpenAIHeaders` earns
  # its existence by serving the OpenAI chat, image, AND embeddings adapters and
  # by carrying the `openai-organization` branch; a support module at n = 1 with
  # no branches is the abstraction the Rule of 3 warns about. Voyage's headers
  # are OpenAI-SHAPED but not OpenAI's — reusing `OpenAIHeaders` here would
  # couple this adapter to a module whose org-header behaviour it must never
  # inherit, since Voyage rejects unknown arguments.
  defp headers(api_key) when is_binary(api_key) do
    [
      {"authorization", "Bearer " <> api_key},
      {"content-type", "application/json"}
    ]
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
    do: {"output_dimension", d}

  defp dimensions_pair(_request), do: nil

  defp task_type_pair(%EmbeddingRequest{task_type: nil}), do: nil

  defp task_type_pair(%EmbeddingRequest{task_type: task_type}) when is_atom(task_type) do
    case to_voyage_task_type(task_type) do
      nil -> log_dropped_task_type(task_type)
      wire -> {"input_type", wire}
    end
  end

  defp task_type_pair(_request), do: nil

  defp log_dropped_task_type(task_type) do
    Logger.debug(fn ->
      "ALLM.Providers.Voyage.Embeddings: task_type #{inspect(task_type)} has no Voyage " <>
        "input_type equivalent; omitting input_type (no retrieval prompt is prepended, " <>
        "which is the correct semantic for a symmetric task)."
    end)

    nil
  end

  # `truncate: true` is the provider-side default and is omitted entirely.
  defp truncation_pair(%EmbeddingRequest{truncate: false}), do: {"truncation", false}
  defp truncation_pair(_request), do: nil

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
           provider: :voyage,
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
           provider: :voyage,
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

  # Arity 3, not the OpenAI sibling's 4: Voyage's envelope has no `code`/`type`
  # pair, so the only discriminator below the status line is the `detail` prose.
  defp classify_embedding_reason(401, _detail, _ra), do: {:authentication_failed, nil}
  defp classify_embedding_reason(403, _detail, _ra), do: {:authentication_failed, nil}
  defp classify_embedding_reason(429, _detail, ra), do: {:rate_limited, ra}

  defp classify_embedding_reason(400, detail, _ra) when is_binary(detail) do
    if context_length?(detail) do
      {:context_length_exceeded, nil}
    else
      {:invalid_request, nil}
    end
  end

  defp classify_embedding_reason(400, _detail, _ra), do: {:invalid_request, nil}

  defp classify_embedding_reason(status, _detail, ra) when status in [500, 502, 503, 504],
    do: {:provider_unavailable, ra}

  defp classify_embedding_reason(_status, _detail, _ra), do: {:unknown, nil}

  defp context_length?(detail) do
    downcased = String.downcase(detail)
    Enum.any?(@context_length_markers, &String.contains?(downcased, &1))
  end

  # Voyage's `detail` is a plain string on every envelope observed. A non-binary
  # value is a proxy or a schema change rather than the provider, and must not
  # be interpolated into `:message`.
  defp default_message(detail, _status) when is_binary(detail), do: detail
  defp default_message(_detail, status), do: "Voyage HTTP #{status}"

  defp malformed_error(detail, metadata, opts, cause \\ nil) do
    EmbeddingAdapterError.new(:malformed_response,
      provider: :voyage,
      message: "could not parse Voyage embeddings response: " <> detail,
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

  # Voyage API keys are `pa-` prefixed. The OpenAI sibling's `sk-`/`rk-`/`org-`
  # pattern and the Gemini sibling's `AIza…`/`ya29.…` pattern each match nothing
  # here, so this is widened for this provider rather than inherited. Voyage's
  # real 401 text does not echo the key back, which makes this defence in depth
  # — the `detail` string is untrusted provider prose either way.
  #
  # Single-clause and unguarded, where both siblings carry a non-binary
  # fall-through: this adapter's off-shape narrowing lives in
  # `default_message/2`, which runs first and is total, so a second guard here
  # would be a clause Dialyzer proves unreachable (`pattern_match_cov`) — the
  # same warning the Gemini sibling hit from the other direction. One function
  # owns the shape, one owns the redaction.
  defp redact_key_material(message) do
    String.replace(message, ~r/\bpa-[A-Za-z0-9_\-]{6,}/, "[REDACTED]")
  end

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

  # Per RFC 7231 §7.1.3 `Retry-After` is delta-seconds or an HTTP-date. An
  # unparseable value returns `nil` and the retry loop falls back to its
  # computed exponential backoff.
  defp parse_retry_after(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> seconds * 1_000
      _ -> nil
    end
  end

  defp parse_retry_after(_value), do: nil

  defp build_retry_telemetry_meta(opts) do
    case Keyword.get(opts, :request_id) do
      nil -> %{provider: :voyage}
      request_id -> %{provider: :voyage, request_id: request_id}
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

  # A missing or non-integer `"index"` is rejected rather than falling back to
  # list position: synthesizing an index would silently defeat the
  # order-correspondence invariant the sort exists to protect.
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

  # THE Voyage asymmetry: `usage` carries `total_tokens` and nothing else — no
  # `prompt_tokens` counter exists on this wire, so `:input_tokens` is `nil`
  # because the provider does not report it, not because it is zero.
  # `:output_tokens` is always `nil` — embeddings produce no completion tokens.
  defp build_usage(body) do
    usage = Map.get(body, "usage") || %{}

    %Usage{
      input_tokens: nil,
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
