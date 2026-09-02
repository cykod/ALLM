defmodule ALLM.Providers.OpenAI.Moderation do
  # Attribute block sits ABOVE the @moduledoc because the moduledoc
  # interpolates `@default_model` and `@adapter_max_batch_size`, and a module
  # attribute has to be defined before it is read. Interpolating rather than
  # re-typing the numbers is what keeps the wire-field map and the batch-size
  # section from drifting away from the constants they describe.

  @base_url "https://api.openai.com/v1"
  @endpoint "/moderations"

  # Documentation-only. The adapter injects NO default model (a `nil` `:model`
  # is omitted from the body per Decision #1) — this records the model OpenAI's
  # own server default resolved to when the recorder's `model`-omitted arm ran
  # on 2026-08-31, and is interpolated into the wire-field map below.
  @default_model "omni-moderation-latest"

  # Set from the recorder's ladder arm, not from documentation: OpenAI publishes
  # no maximum `input` array length. Every rung of `[1, 32, 100, 128, 1000]` was
  # accepted on 2026-08-31, so no upper bound was found and this is the top rung
  # — a demonstrated floor rather than a discovered cap. See the moduledoc.
  @adapter_max_batch_size 1000

  @moduledoc """
  OpenAI content-moderation provider adapter — implements
  `ALLM.ModerationAdapter` against OpenAI's `POST /v1/moderations` endpoint.

  Layer B — runtime. Constructed via
  `ALLM.Engine.new(moderation_adapter: ALLM.Providers.OpenAI.Moderation)` and
  consumed through `ALLM.moderate/3`. Keys resolve via
  `ALLM.Keys.fetch!(:openai, opts)` at request-build time — no key ever lives
  on the engine.

      req = ALLM.ModerationRequest.new(input: ["hello"], model: "omni-moderation-latest")
      {:ok, resp} = ALLM.Providers.OpenAI.Moderation.moderate(req, api_key: "sk-...")
      false = ALLM.ModerationResponse.flagged?(resp)

  ## Wire-field map

  Every row below was observed live on **2026-08-31** by
  `scripts/record_openai_moderation_fixtures.exs`, whose probe halts the
  recording pass on a mismatch.

  | Concern | OpenAI |
  |---------|--------|
  | Endpoint | `POST https://api.openai.com/v1/moderations` (not overridable) |
  | Auth | `authorization: Bearer <key>` |
  | Input (text) | `input` — always sent as an **array**, even for one string |
  | Input (multimodal) | `input` — an array of content blocks: `{"type":"text","text":…}` and `{"type":"image_url","image_url":{"url":…}}`. Sent when `ALLM.ModerationRequest.multimodal?/1` is true |
  | Image source | a `{:url, _}` `ALLM.Image` forwards its URL verbatim; every other source is inlined as a `data:` URI |
  | `detail` | **never sent.** `ALLM.ImagePart.detail` is dropped with a one-per-process `Logger.debug/1` — see below |
  | Model | `model` — **omitted** when `nil`; OpenAI's own server default resolved to `#{@default_model}` |
  | Options | `ALLM.ModerationRequest.options` is merged onto the body under the structural fields |
  | Verdict | `results[].flagged` |
  | Categories | `results[].categories` — 13 slash-named keys, provider-shaped and string-keyed |
  | Scores | `results[].category_scores` — 13 float keys |
  | Applied types | `results[].category_applied_input_types` → `:applied_input_types` (prefix dropped) |
  | Index | **absent from the wire** — assigned from array position (invariant 4) |
  | Usage | **none.** The endpoint is free and returns no usage object |
  | Response id | top-level `id` (`"modr-…"`), one per HTTP call |
  | Correlation | `x-request-id` response header |
  | Error envelope | `{"error": {"message", "type", "param", "code"}}` |
  | Batch cap | see `max_batch_size/0` |

  ## Models

  `omni-moderation-latest` and `omni-moderation-2024-09-26` only. The
  `text-moderation-*` family was **shut down on 2025-10-27** and answers a
  400 (`"Invalid value for 'model' = text-moderation-latest"`, recorded at
  `test/fixtures/openai/moderations/recorded/error_400_bad_model.json`),
  surfaced as `%ALLM.Error.ModerationAdapterError{reason: :invalid_request}`.
  The adapter forwards whatever `:model` the caller sets rather than
  maintaining a denylist that goes stale the moment a new model ships.

  ## Adapter-injected defaults

  **None.** A `nil` `:model` is OMITTED from the body, letting OpenAI apply its
  own current default rather than pinning a name ALLM would have to chase.
  `ALLM.moderate/3` stamps the engine's resolved model onto the request before
  dispatch, so a `nil` model only arises on a direct adapter call.

  ## Batch size

  `max_batch_size/0` is `#{@adapter_max_batch_size}`. This is a **floor, not a
  documented cap**: OpenAI documents no maximum `input` array length, and the
  ladder arm of the recorder (`n ∈ [1, 32, 100, 128, 1000]`, run 2026-08-31)
  found every rung accepted — no upper bound was observed. The number is the
  ladder's top rung, chosen so the adapter never promises more than has been
  demonstrated.

  Unlike `ALLM.embed/3`, `ALLM.moderate/3` does **not** chunk transparently: one
  HTTP call yields exactly one provider `id`, and merging N chunks would produce
  N ids with nowhere to put them. Callers who need more chunk with
  `Enum.chunk_every/2` against this function.

  ## Unknown fields are IGNORED, not rejected

  The recorder's negative-control arm found `/v1/moderations` returning **200**
  for an invented top-level field, unlike Voyage's embeddings endpoint or
  OpenAI's own Chat Completions. Two consequences worth knowing:

    * an unrecognised `ALLM.ModerationRequest.options` key is silently dropped
      by the provider rather than surfacing a 400 — the caller gets a normal
      verdict and no signal that the knob did nothing;
    * "the API accepted it" is therefore **not** evidence that a field is part
      of this endpoint's schema.

  ## Pre-flight gates

  Before any HTTP I/O — and, deliberately, before `ALLM.Keys.fetch!/2`, so a
  request that is going to be rejected never needs a valid API key:

    1. **Empty input.** `input: []` → `:invalid_request`
       (`ALLM.ModerationAdapter` invariant 6).
    2. **Batch size.** item count `> max_batch_size/0` → `:batch_too_large`
       with `metadata: %{count: n, max: max}` (invariant 5). The gate measures
       the **item** count invariant 3 defines, not the raw list length: an
       `:input` carrying any `ALLM.ImagePart` is exactly **one** multimodal
       item. An `:input` that is not a list at all is rejected here as
       `:invalid_request` with `metadata: %{field: :input}` rather than raising.
    3. **Images.** Every `ALLM.ImagePart` in `:input` is validated by
       `ALLM.Providers.Support.ImageMime.validate/2` against
       `ALLM.Providers.Support.ImageMime.accept_mimes/1` for `:openai` and the
       shared 20 MB ceiling — which is exactly OpenAI's documented moderation
       image limit — and then for whether its bytes can actually be produced.
       Every failure shape converts to `:invalid_request` rather than widening
       this callback's error union to include `ALLM.Error.ValidationError` —
       `moderate/2` returns `%ALLM.Error.ModerationAdapterError{}` and nothing
       else. Each carries the offending item's position on `metadata.index`:

       | Failure | `metadata` adds |
       |---|---|
       | MIME outside OpenAI's accept set | `%{image_error: :unsupported_image_format, mime_type: mime}` |
       | image over 20 MB | `%{image_error: :image_too_large, byte_size: bytes}` |
       | `%ALLM.Image{}` with no `:mime_type` | `%{image_error: :missing_mime_type}` |
       | image bytes unresolvable (missing file, bad base64) | `%{image_error: :unresolvable_image, cause: reason}` |
       | item is neither a string nor an `ALLM.ImagePart`, in a multimodal request | `%{image_error: :untranslatable_item}` |

       The last two rows exist because the translator is total only over
       resolvable images and known item types: without them a missing file
       raises `MatchError` and an off-shape item raises `FunctionClauseError`
       from inside `moderate/2`, violating `ALLM.ModerationAdapter`
       invariant 2. An off-shape item in an **all-strings** `:input` is still
       forwarded to the provider untouched — it reaches the wire there, and
       OpenAI answers the 400.

       The gate is fail-fast: the first failing item is reported, not all of
       them. A URL-sourced image is not fetched, so its bytes are never
       weighed here — OpenAI does that itself and answers a 400.

  Capability pre-flight against a model catalog is NOT performed here — it lives
  in `ALLM.moderate/3`. A direct adapter call bypasses it by design.

  ## Result cardinality and `:index`

  The wire's `results` array carries **no** `index` field, so `:index` is
  assigned from array position — which makes `ALLM.ModerationAdapter`
  invariant 4 this adapter's responsibility rather than the provider's. For an
  all-strings `:input` that yields `length(input)` results with indices
  `0..n-1`, matching `ALLM.ModerationRequest`'s cardinality rule.

  An `:input` carrying any `ALLM.ImagePart` is a **single multimodal item** —
  the text and the images are judged together — so the provider answers with
  exactly **one** `results` entry and `:index` is `0`, however many elements the
  list had. This is a property of OpenAI's wire, not an ALLM choice: the
  documented multimodal example posts a text block plus an image block and gets
  one verdict back. `ALLM.ModerationRequest.multimodal?/1` makes the cardinality
  derivable before the call. Recorded at
  `test/fixtures/openai/moderations/recorded/multimodal_text_image.json`.

  ## `ALLM.ImagePart.detail` is dropped

  OpenAI's documented moderation request shape carries no `detail` key inside
  `image_url`, and no OpenAI documentation mentions detail control on this
  endpoint, so the translator omits it and fires a single deferred-form
  `Logger.debug/1` per process when a part carries one.

  The disposition is **inferred from the documented request shape, not
  confirmed on the wire**, and it cannot be confirmed here: this endpoint
  ignores unknown fields (see above), so a `detail`-bearing request coming back
  200 is evidence of nothing. Only a response-observable difference could
  promote the row, and the recorder's paired arm found none.

  ## Decoding the category maps

  Three fields, three deliberately different treatments:

    * `categories` keeps only **boolean** values. OpenAI's reference types
      `illicit` and `illicit/violent` as `"boolean or null"`, and
      `ALLM.ModerationResult.categories` is typed `%{String.t() => boolean()}`,
      so a null-valued key is **dropped** rather than propagated as `nil` into
      a typed map. `ALLM.ModerationResult.flagged_categories/1` and
      `ALLM.ModerationResult.score/2` already handle an absent key.
    * `category_scores` **coerces** numbers with `* 1.0`, because a JSON `0`
      decodes to an integer and would break the declared `float()` type.
    * `category_applied_input_types` passes through unchanged under the
      prefix-dropped name `:applied_input_types`, defaulting to `%{}` when the
      provider omits it.

  A `results` entry whose `flagged` is missing or non-boolean is
  `:malformed_response`. The verdict is never coerced or defaulted here: a
  moderation result that silently reads "clean" because the payload was
  truncated is the one failure mode worth an error.

  ## Request-id preservation

  `opts[:request_id]` is reflected onto `response.request_id` unchanged. When it
  is absent, the adapter falls back to OpenAI's `x-request-id` response header.
  `request.metadata` round-trips onto `response.metadata` untouched.

  > #### The `x-request-id` fallback is unreachable through `ALLM.moderate/3` {: .warning}
  >
  > The façade always supplies `opts[:request_id]` (it generates one when the
  > caller does not), so on that path the left branch always wins and OpenAI's
  > own correlation id is never observed. It surfaces only on a direct
  > `moderate/2` / `decode_response/4` call that omits `opts[:request_id]`.
  > Identical to `ALLM.Providers.OpenAI.Embeddings`, deliberately.

  ## Error-struct hygiene

  `%ALLM.Error.ModerationAdapterError{}` derives `Jason.Encoder` and is commonly
  logged and persisted, so this adapter never copies a raw response body, a
  request header, or any `Authorization` value into `:cause`, `:metadata`, or
  `:message`. There is no `body_preview`. Provider error messages pass through
  a redactor that replaces key-shaped tokens with `[REDACTED]`.

  The live 2026-08-31 probe found OpenAI **masking** the key in its real
  moderation 401 text (`sk-proj-*****…9900`), so no provider-authored message
  from this endpoint is currently known to carry key material. The redactor is
  defence in depth, and its test target is the deliberately-planted token in
  `test/fixtures/openai/moderations/synthesized/error_401.json`.

  ## Retry integration

  HTTP-error closures return `{:retry, delay_ms, error}` for 429 (honouring
  `Retry-After`), 5xx, timeouts, and transport failures; `ALLM.Retry.run/3` is
  wrapped around each attempt. The closure returns real reason atoms rather
  than swapping in HTTP status codes, so for `:rate_limited`,
  `:provider_unavailable`, and `:network_error` the façade's widened `retry_on`
  list is what decides — **none of them appears in this adapter's own
  `opts[:retry]` policy**, which defaults to `:default` and whose `retry_on` is
  `[429, 500, 502, 503, 504, :timeout]`. A 500 is therefore *not* retried by
  the adapter's own loop; that is pinned by
  `test/allm/providers/openai/moderation_wire_test.exs:373-381`.

  `:timeout` is the documented exception: it is a member of **both** lists, so
  through `ALLM.moderate/3` the adapter's inner `ALLM.Retry.run/3` and the
  façade's outer one both retry it and the attempt budgets multiply
  (3 × 3 = 9 HTTP attempts at the default policy, against 3 for every other
  retryable reason). A direct `moderate/2` call takes the inner loop only and
  makes 3 for `:timeout`; a reason the adapter's own policy does not retry
  costs 1. `ALLM.Providers.OpenAI.Embeddings` has the byte-identical shape
  through `ALLM.embed/3`, so this is a pre-existing library-wide characteristic
  rather than a moderation one; it is tracked in `ASKS.md`.

  ## Test-injection escape hatch

  `moderate/2` honours `opts[:adapter_opts][:moderation_script]` as a documented
  test-only short-circuit: when the key is present, the call delegates to
  `ALLM.Providers.FakeModeration.moderate/2` BEFORE any pre-flight gate runs and
  returns its result verbatim. This is what lets the injectable
  `ALLM.ModerationAdapter` conformance suite drive a real adapter without an
  HTTP stub library — and it is why conformance cases 3 and 4 pass **no** script.

  The switch keys on the presence of that per-call key and **nothing else** — no
  environment variable, no application config, no `:persistent_term` — so it
  stays confined to an explicit argument. Production callers do not populate it.

  `prepare_request/2` deliberately does NOT delegate under the same key: a
  scripted response has no `Req.Request` analogue, so it returns a stub error
  instead.
  """

  @behaviour ALLM.ModerationAdapter

  require Logger

  alias ALLM.Error.ModerationAdapterError

  alias ALLM.{
    Image,
    ImagePart,
    Keys,
    ModerationRequest,
    ModerationResponse,
    ModerationResult,
    Retry
  }

  alias ALLM.Providers.FakeModeration
  alias ALLM.Providers.Support.ImageMime
  alias ALLM.Providers.Support.OpenAIHeaders

  # OpenAI carries the per-request token-budget discriminator on `type` and the
  # per-input one on `code`, so the classifier checks both fields against this
  # list rather than composing a boolean guard. Inherited from
  # `ALLM.Providers.OpenAI.Embeddings` — same provider, same envelope.
  @context_length_markers ["max_tokens_per_request", "context_length_exceeded"]

  # ---------------------------------------------------------------------------
  # ALLM.ModerationAdapter callbacks
  # ---------------------------------------------------------------------------

  @doc """
  Return the maximum number of inputs this adapter will send in one
  `/v1/moderations` call.

  Per-module and constant, not per-model. OpenAI documents no cap; this number
  is the top rung of the recorder's ladder arm, every rung of which was accepted
  on 2026-08-31 — a demonstrated floor rather than a discovered maximum.

  ## Examples

      iex> ALLM.Providers.OpenAI.Moderation.max_batch_size
      1000
  """
  @impl ALLM.ModerationAdapter
  @spec max_batch_size() :: pos_integer()
  def max_batch_size, do: @adapter_max_batch_size

  @doc """
  Classify a moderation request synchronously against OpenAI.

  Returns `{:ok, %ALLM.ModerationResponse{}}` or
  `{:error, %ALLM.Error.ModerationAdapterError{}}`; every HTTP-shaped failure
  converts, including transport errors. The one documented exception is
  `ALLM.Keys.fetch!/2`, which raises
  `%ALLM.Error.EngineError{reason: :missing_key}` by design and is not rescued
  here — both pre-flight gates run ahead of it, so a request rejected pre-flight
  never needs a key.

  See the module documentation for the gate order, the wire-field map, the
  no-injected-defaults policy for a `nil` `:model`, and the
  `adapter_opts[:moderation_script]` test-injection short-circuit.

  ## Examples

      iex> req = ALLM.ModerationRequest.new(input: ["is this ok?"])
      iex> opts = [adapter_opts: [moderation_script: [{:flagged, ["violence"]}]]]
      iex> {:ok, resp} = ALLM.Providers.OpenAI.Moderation.moderate(req, opts)
      iex> ALLM.ModerationResponse.flagged_categories(resp)
      ["violence"]

      iex> req = ALLM.ModerationRequest.new(input: [])
      iex> {:error, err} = ALLM.Providers.OpenAI.Moderation.moderate(req, [])
      iex> err.reason
      :invalid_request
  """
  @impl ALLM.ModerationAdapter
  @spec moderate(ModerationRequest.t(), keyword()) ::
          {:ok, ModerationResponse.t()} | {:error, ModerationAdapterError.t()}
  def moderate(%ModerationRequest{} = request, opts) when is_list(opts) do
    case fetch_moderation_script(opts) do
      nil -> do_moderate(request, opts)
      _script -> FakeModeration.moderate(request, opts)
    end
  end

  @doc """
  Return an unfired `Req.Request` configured exactly as `moderate/2` would fire
  it, for callers who need to add headers, middleware, or their own retry
  wrapper before dispatch.

  The pre-flight gates run first, so this is defined only for a request whose
  input is non-empty and whose item count is no greater than `max_batch_size/0`
  (`ALLM.ModerationAdapter` invariant 10).

  Under `opts[:adapter_opts][:moderation_script]` this returns a stub error
  rather than delegating to `ALLM.Providers.FakeModeration` — a scripted
  response has no `Req.Request` analogue. That asymmetry with `moderate/2` is
  deliberate.

  ## Examples

      iex> req = ALLM.ModerationRequest.new(input: ["hi"], model: "omni-moderation-latest")
      iex> {:ok, http} = ALLM.Providers.OpenAI.Moderation.prepare_request(req, api_key: "sk-x")
      iex> URI.to_string(http.url)
      "https://api.openai.com/v1/moderations"
  """
  @impl ALLM.ModerationAdapter
  @spec prepare_request(ModerationRequest.t(), keyword()) ::
          {:ok, Req.Request.t()} | {:error, ModerationAdapterError.t()}
  def prepare_request(%ModerationRequest{} = request, opts) when is_list(opts) do
    case fetch_moderation_script(opts) do
      nil ->
        case run_gates(request, opts) do
          :ok -> build_request(request, opts)
          {:error, %ModerationAdapterError{}} = err -> err
        end

      _script ->
        {:error, stub_error(opts)}
    end
  end

  # ---------------------------------------------------------------------------
  # Public testing seams (`@doc false` + `@spec` per the public-test-seam rule).
  #
  # Names ALIGN across the OpenAI adapter family modulo arity, so reader
  # pattern-recognition flips between `openai/moderation.ex`,
  # `openai/embeddings.ex` and `openai/images.ex`:
  #
  #   IDENTICAL to both siblings (byte-for-byte modulo arity):
  #   * `decode_response/4`             — arg order `(body, headers, request, opts)`
  #   * `to_json_body/2`                — returns a bare `map()`
  #   * private `build_metadata/2`, `run_one_attempt/3`, `classify_http_error/4`,
  #     `retry_after_ms/1`, `stub_error/1`, `maybe_apply_req_test_stub/2`,
  #     `maybe_apply_request_timeout/2`, `header_value/2`
  #
  #   IDENTICAL to `openai/embeddings.ex` ONLY — `openai/images.ex` has NEITHER
  #   function, which is the subject of the standing ticket at `ASKS.md:249`
  #   ("grep -rn 'redact' lib/ hits only the new embeddings module"). Do not
  #   read this block as a claim that the image adapter redacts key material:
  #   it does not:
  #   * `redact_key_material/1`  — `embeddings.ex:695-699` (differs only in the
  #                                fail-closed fallback string:
  #                                `"OpenAI moderation error"` here vs
  #                                `"OpenAI embeddings error"` there)
  #   * `sanitize_cause/1`       — `embeddings.ex:689-690`, byte-for-byte
  #
  #   RENAMED for the moderation family (per-capability, not per-provider):
  #   * `to_moderation_adapter_error/4` ↔ embeddings' `to_embedding_adapter_error/4`
  #                                     ↔ images' `to_image_adapter_error/4`
  #   * `classify_moderation_reason/4`  ↔ embeddings' `classify_embedding_reason/4`
  #   * `fetch_moderation_script/1`     ↔ embeddings' `fetch_embedding_script/1`
  #   * `max_batch_size/0`              — shared with embeddings in the same
  #                                       "per-module constant" role images
  #                                       fills with `supported_operations/0`.
  #
  #   DIVERGENT, with justification:
  #   * `parse_retry_after/1` returns `nil` INLINE for an unparseable value,
  #     matching `embeddings.ex:738-745`, where `openai/images.ex:1159-1172`
  #     falls through to a `parse_http_date/1` stub that also returns `nil`
  #     today (`defp parse_http_date(_value), do: nil`). Behaviour is identical;
  #     the seam is deliberately omitted here so there is no dead private
  #     function. If that stub is ever implemented, this clause has to be
  #     updated with it.
  #   * `redact_key_material/1`'s pattern is inherited from
  #     `openai/embeddings.ex` VERBATIM, which is correct here and only here:
  #     the provider is the same one, so the `sk-`/`rk-`/`org-` prefixes are the
  #     right shapes. The Gemini (`AIza…`/`ya29.…`) and Voyage (`pa-…`) siblings
  #     had to widen; a companion test in `moderation_wire_test.exs` asserts
  #     THEIR patterns match nothing here, so an inherited-verbatim regex would
  #     fail loudly rather than redact nothing.
  #   * There is no `build_usage/1`. The endpoint is free and returns no usage
  #     object, and `%ALLM.ModerationResponse{}` has no `:usage` field.
  #   * `decode_response/4` assigns `:index` from array position — the wire
  #     carries none, where `/v1/embeddings` carries `data[].index` and its
  #     sibling therefore sorts on it.
  #   * `to_openai_content_blocks/1` and `part_to_block/1` (22.5) are named for
  #     the CHAT translator's pair at `lib/allm/providers/openai.ex:1839-1893`,
  #     modulo arity: chat's are `/2` because Chat Completions and the Responses
  #     API disagree on the block shape, and moderation has one endpoint. Per
  #     CLAUDE.md's cross-provider alignment rule the names align byte-for-byte
  #     and the arity difference is driven by that invariant, exactly as
  #     `ALLM.Providers.Anthropic`'s `/1` forms align with the OpenAI `/2` ones.
  #     This is NOT a second-caller promotion trigger: the bodies differ (no
  #     `detail`, no `:responses` arm, and a bare binary rather than a
  #     `%ALLM.TextPart{}` on the text arm, because moderation's item union is
  #     `String.t() | ALLM.ImagePart.t()`), so the semantic-clone test in
  #     `agent-spec/IMPLEMENTATION.md` fails and no extraction is owed. Design
  #     Decision #9 records this so it is not re-litigated.
  #   * `gate_images/2` (22.5) takes `opts` where the design's seam table wrote
  #     `reject_oversized_images/1`: every error this adapter surfaces carries
  #     `opts[:request_id]` via `build_metadata/2`, which the sibling gates
  #     `gate_empty_input/2` and `gate_batch_size/2` also need `opts` for. Both
  #     the arity and the name were corrected in the design's table in the same
  #     commit as the change — size is one of five things the gate rejects.
  #   * `detail_drop_check/1` / `warn_detail_dropped_once/0` are the THIRD copy
  #     of this pair, after `lib/allm/providers/anthropic.ex:883-899` and
  #     `lib/allm/providers/gemini.ex:755-773` — same one-shot-per-process
  #     shape, different process-dictionary key and log string.
  #     `agent-spec/IMPLEMENTATION.md:68` sets the extraction trigger at TWO
  #     implementations; consolidation is deferred because it would edit two
  #     released adapters outside this sub-phase's Module Tree, and is filed as
  #     a `[DEFERRED-DRY]` ticket in `ASKS.md`.
  # ---------------------------------------------------------------------------

  @doc false
  # Adapter-injected defaults: NONE. A `nil` `:model` is OMITTED rather than
  # defaulted (the public `@moduledoc` states why). `request.options` merges
  # UNDER the structural fields, so `input` and `model` always win.
  @spec to_json_body(ModerationRequest.t(), keyword()) :: map()
  def to_json_body(%ModerationRequest{} = request, _opts) do
    body =
      %{"input" => wire_input(request)}
      |> put_pair(model_pair(request))

    request.options
    |> stringify_option_keys()
    |> Map.merge(body)
  end

  @doc false
  # `[item()] -> [map()]`. Called ONLY when `ModerationRequest.multimodal?/1` is
  # true — an all-strings `:input` goes to the wire as the bare string array
  # OpenAI documents for the batch shape, which is why the 22.4 `to_json_body/2`
  # tests still pass unchanged. See the seam banner above for why this pair is
  # local to the moderation adapter rather than extracted from the chat
  # translator.
  @spec to_openai_content_blocks([String.t() | ImagePart.t()]) :: [map()]
  def to_openai_content_blocks(items) when is_list(items) do
    Enum.map(items, &part_to_block/1)
  end

  @doc false
  # One item -> one wire block. `ALLM.ImagePart.detail` is read but NEVER
  # emitted (Decision #8); `detail_drop_check/1` surfaces the drop once per
  # process at `:debug`.
  @spec part_to_block(String.t() | ImagePart.t()) :: map()
  def part_to_block(text) when is_binary(text) do
    %{"type" => "text", "text" => text}
  end

  # URL fast-path: forward the URL string. Never call `ALLM.Image.to_data_uri/1`
  # here — it returns `{:error, :remote_source}` for a `{:url, _}` source
  # (`lib/allm/image.ex:297`), so the `{:ok, uri}` match below would raise.
  def part_to_block(%ImagePart{image: %Image{source: {:url, u}}, detail: d}) do
    detail_drop_check(d)
    %{"type" => "image_url", "image_url" => %{"url" => u}}
  end

  def part_to_block(%ImagePart{image: %Image{} = img, detail: d}) do
    detail_drop_check(d)
    {:ok, uri} = Image.to_data_uri(img)
    %{"type" => "image_url", "image_url" => %{"url" => uri}}
  end

  @doc false
  # Gate 3. Walks `:input` and converts every way an item can fail to reach the
  # wire into `%ModerationAdapterError{reason: :invalid_request}` — Decision #7:
  # this callback's error union is never widened to `%ValidationError{}`.
  #
  # Named `gate_images/2` rather than the design's original
  # `reject_oversized_images/2` (corrected in the same commit as this rename):
  # size is one of FIVE things it rejects, and the name now matches its
  # `gate_empty_input/2` / `gate_batch_size/2` siblings in `run_gates/2`.
  #
  # Five failure shapes, three from `ImageMime.validate/2` and two this gate
  # adds:
  #
  #   * `{:unsupported_image_format, mime}` / `{:image_too_large, bytes}` —
  #     ImageMime's accept-set and shared 20 MB ceiling.
  #   * `:missing_mime_type` — reachable via `ALLM.Image.from_file/1` on an
  #     unrecognised extension (`lib/allm/image.ex:98-101` leaves `:mime_type`
  #     `nil`), or a hand-built `%ALLM.Image{}`. NOT reachable via
  #     `ALLM.Image.from_url/1`, whose `{:url, _}` source takes `validate/2`'s
  #     first clause and returns `:ok` with a `nil` mime.
  #   * `{:unresolvable_image, reason}` — the image's BYTES cannot be produced.
  #     `ImageMime.check_byte_size/1` deliberately returns `:ok` when
  #     `Image.to_binary/1` fails (`image_mime.ex:126-129`: it cannot prove the
  #     image is oversized without bytes), so a `{:file, path}` whose file is
  #     missing sails through MIME and size validation and would then reach
  #     `part_to_block/1`'s `{:ok, uri} = Image.to_data_uri(img)` and raise a
  #     `MatchError`. Checked HERE, where the item's index is in hand.
  #   * `{:untranslatable_item, item}` — an element that is neither a binary nor
  #     an `%ImagePart{}`, in a request that is multimodal and therefore routes
  #     through `part_to_block/1`, which has no catch-all clause.
  #
  # The last two exist because `moderate/2` must return
  # `{:ok, _} | {:error, %ModerationAdapterError{}}` and nothing else
  # (`ALLM.ModerationAdapter` invariant 2). Letting either reach the translator
  # surfaces a raised exception from inside `moderate/2`, i.e. ALLM's own
  # bundled adapter violating the behaviour it ships the conformance suite for.
  #
  # Fail-fast on the first offending item; `metadata.index` names its position
  # in `:input`.
  @spec gate_images(ModerationRequest.t(), keyword()) ::
          :ok | {:error, ModerationAdapterError.t()}
  def gate_images(%ModerationRequest{input: input} = request, opts)
      when is_list(input) and is_list(opts) do
    accept = ImageMime.accept_mimes(:openai)
    multimodal? = ModerationRequest.multimodal?(request)

    input
    |> Enum.with_index()
    |> Enum.find_value(:ok, fn {item, index} ->
      case validate_item(item, accept, multimodal?) do
        :ok -> nil
        {:error, reason} -> {:error, image_gate_error(reason, index, opts)}
      end
    end)
  end

  def gate_images(%ModerationRequest{}, opts) when is_list(opts), do: :ok

  @doc false
  @spec to_moderation_adapter_error(
          non_neg_integer(),
          map(),
          Enumerable.t() | map(),
          keyword()
        ) :: ModerationAdapterError.t()
  def to_moderation_adapter_error(status, body, headers, opts)
      when is_integer(status) and is_map(body) do
    error = Map.get(body, "error", %{})
    code = Map.get(error, "code")
    type = Map.get(error, "type")

    message =
      error
      |> Map.get("message", "OpenAI HTTP #{status}")
      |> redact_key_material()

    {reason, retry_after} = classify_moderation_reason(status, code, type, retry_after_ms(headers))

    ModerationAdapterError.new(reason,
      provider: :openai,
      status: status,
      retry_after_ms: retry_after,
      message: message,
      metadata: build_metadata(%{status: status, openai_code: code, openai_type: type}, opts)
    )
  end

  @doc false
  @spec decode_response(term(), Enumerable.t() | map(), ModerationRequest.t(), keyword()) ::
          {:ok, ModerationResponse.t()} | {:error, ModerationAdapterError.t()}
  def decode_response(body, headers, request, opts)

  def decode_response(%{"results" => results} = body, headers, %ModerationRequest{} = request, opts)
      when is_list(results) do
    case decode_results(results, opts) do
      {:ok, decoded} ->
        {:ok,
         %ModerationResponse{
           id: Map.get(body, "id"),
           request_id: Keyword.get(opts, :request_id) || header_value(headers, "x-request-id"),
           model: Map.get(body, "model") || request.model,
           provider: :openai,
           results: decoded,
           raw: body,
           metadata: request.metadata
         }}

      {:error, %ModerationAdapterError{}} = err ->
        err
    end
  end

  def decode_response(body, _headers, _request, opts) when is_map(body) do
    {:error,
     malformed_error(
       "missing or non-list \"results\" field",
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

  defp fetch_moderation_script(opts) do
    opts
    |> Keyword.get(:adapter_opts, [])
    |> Keyword.get(:moderation_script)
  end

  # Gate ordering: :invalid_request -> :batch_too_large, BOTH ahead of
  # `Keys.fetch!/2`. Key resolution happening after the gates is what keeps the
  # two unscripted conformance cases green in a keyless environment.
  defp run_gates(%ModerationRequest{} = request, opts) do
    with :ok <- gate_empty_input(request, opts),
         :ok <- gate_batch_size(request, opts) do
      gate_images(request, opts)
    end
  end

  defp gate_empty_input(%ModerationRequest{input: []}, opts) do
    {:error,
     ModerationAdapterError.new(:invalid_request,
       provider: :openai,
       message: "input must not be empty",
       metadata: build_metadata(%{field: :input}, opts)
     )}
  end

  defp gate_empty_input(%ModerationRequest{}, _opts), do: :ok

  # Invariant 5 measures the ITEM count invariant 3 defines, NOT the raw list
  # length: an `:input` carrying any `%ALLM.ImagePart{}` is exactly one
  # multimodal item, so a multimodal request never trips this gate. Writing it
  # against `length(request.input)` would put invariants 3 and 5 in
  # contradiction at `max_batch_size() == 1`.
  defp gate_batch_size(%ModerationRequest{input: input} = request, opts) when is_list(input) do
    count = item_count(request)
    max = max_batch_size()

    if count > max do
      {:error,
       ModerationAdapterError.new(:batch_too_large,
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
  # direct-adapter mistake, and it must convert rather than raise: the façade's
  # `dispatch_moderate_attempt/3` raises `ArgumentError` on any return outside
  # the `{:ok, _} | {:error, _}` union.
  defp gate_batch_size(%ModerationRequest{}, opts) do
    {:error,
     ModerationAdapterError.new(:invalid_request,
       provider: :openai,
       message: "input must be a list of items",
       metadata: build_metadata(%{field: :input}, opts)
     )}
  end

  defp item_count(%ModerationRequest{} = request) do
    if ModerationRequest.multimodal?(request), do: 1, else: length(request.input)
  end

  # An `%ImagePart{}` is validated by `ImageMime.validate/2` and then, because
  # that function passes an unresolvable image (see `gate_images/2`), for
  # byte-resolvability — the exact question `part_to_block/1` asks next.
  defp validate_item(%ImagePart{} = part, accept, _multimodal?) do
    with :ok <- ImageMime.validate(part, accept), do: resolvable?(part)
  end

  # A bare string carries nothing to validate.
  defp validate_item(item, _accept, _multimodal?) when is_binary(item), do: :ok

  # Anything else is `Validate.moderation_request/1`'s business and the adapter
  # passes it through to the provider rather than inventing a second opinion —
  # but ONLY on the all-strings path, where `wire_input/1` forwards `:input`
  # verbatim and OpenAI answers the 400. In a MULTIMODAL request every element
  # goes through `part_to_block/1`, which has two heads and no catch-all, so
  # passing it through raises `FunctionClauseError` from inside `moderate/2`
  # instead of reaching any provider. Reject it here so invariant 2 holds.
  defp validate_item(_item, _accept, false), do: :ok
  defp validate_item(item, _accept, true), do: {:error, {:untranslatable_item, item}}

  # `part_to_block/1` forwards a `{:url, _}` source verbatim and never resolves
  # bytes, so only the inlined sources are asked this question.
  defp resolvable?(%ImagePart{image: %Image{source: {:url, _}}}), do: :ok

  defp resolvable?(%ImagePart{image: %Image{} = image}) do
    case Image.to_data_uri(image) do
      {:ok, _uri} -> :ok
      {:error, reason} -> {:error, {:unresolvable_image, reason}}
    end
  end

  defp image_gate_error(reason, index, opts) do
    {message, metadata} = image_gate_detail(reason, index)

    ModerationAdapterError.new(:invalid_request,
      provider: :openai,
      message: message,
      metadata: build_metadata(metadata, opts)
    )
  end

  # One clause per failure shape, returning BOTH the message and the metadata —
  # a single table rather than two parallel ones, so a new shape costs one
  # clause and cannot be added to one table and forgotten in the other.
  defp image_gate_detail({:unsupported_image_format, mime}, index) do
    {"input[#{index}]: unsupported image MIME type #{inspect(mime)}",
     %{field: :input, index: index, image_error: :unsupported_image_format, mime_type: mime}}
  end

  defp image_gate_detail({:image_too_large, bytes}, index) do
    {"input[#{index}]: image of #{bytes} bytes exceeds OpenAI's 20 MB moderation limit",
     %{field: :input, index: index, image_error: :image_too_large, byte_size: bytes}}
  end

  defp image_gate_detail(:missing_mime_type, index) do
    {"input[#{index}]: image has no :mime_type",
     %{field: :input, index: index, image_error: :missing_mime_type}}
  end

  defp image_gate_detail({:unresolvable_image, reason}, index) do
    {"input[#{index}]: image bytes could not be resolved (#{inspect(reason)})",
     %{field: :input, index: index, image_error: :unresolvable_image, cause: reason}}
  end

  defp image_gate_detail({:untranslatable_item, item}, index) do
    {"input[#{index}]: #{inspect(item, limit: 5)} is neither a string nor an %ALLM.ImagePart{} " <>
       "and cannot be translated into a multimodal content block",
     %{field: :input, index: index, image_error: :untranslatable_item}}
  end

  defp stub_error(opts) do
    ModerationAdapterError.new(:unknown,
      provider: :openai,
      message: "prepare_request/2 has no analogue under the moderation_script short-circuit",
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

  defp do_moderate(%ModerationRequest{} = request, opts) do
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
  defp build_request(%ModerationRequest{} = request, opts) do
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

  # Invariant 9: `opts[:request_timeout]` is honoured, and its expiry surfaces
  # as `%ModerationAdapterError{reason: :timeout}` from `run_one_attempt/3`.
  defp maybe_apply_request_timeout(req, opts) do
    case Keyword.get(opts, :request_timeout) do
      nil -> req
      ms when is_integer(ms) and ms > 0 -> Req.merge(req, receive_timeout: ms)
    end
  end

  # ---------------------------------------------------------------------------
  # Internals — JSON body builder
  # ---------------------------------------------------------------------------

  # The all-strings shape is the 22.4 branch and stays byte-identical: only a
  # request `ModerationRequest.multimodal?/1` calls true routes through the
  # content-block translator.
  #
  # The predicate is INLINED rather than delegated, which is a deliberate clone
  # of `ALLM.ModerationRequest.multimodal?/1`'s one-line body and needs its
  # reason recorded. That function is specced `t() :: boolean()`, so calling it
  # on `to_json_body/2`'s binding refines that binding to the FULL declared
  # `ModerationRequest.t()` — which in turn makes `model_pair/1`'s and
  # `stringify_option_keys/1`'s catch-all clauses provably dead and turns
  # `mix dialyzer` red with two `pattern_match_cov` errors. Those clauses are
  # dead by type but alive by test: `to_json_body/2` is a public `@doc false`
  # seam, and `test/allm/providers/openai/moderation_test.exs`'s "an off-shape
  # :options is ignored rather than raising" drives exactly the shape the type
  # says cannot exist. Deleting them to satisfy dialyzer would break a released
  # test and remove a real defence at a public entry point, so the clone stays
  # and `moderation_vision_test.exs`'s "to_json_body/2 branches on exactly what
  # multimodal?/1 reports" pins the two against drift.
  defp wire_input(%ModerationRequest{input: input}) when is_list(input) do
    if Enum.any?(input, &match?(%ImagePart{}, &1)) do
      to_openai_content_blocks(input)
    else
      input
    end
  end

  defp wire_input(%ModerationRequest{input: input}), do: input

  # Decision #8: `ALLM.ImagePart.detail` has no place in OpenAI's documented
  # moderation request shape, so it is dropped. A single deferred-form
  # `Logger.debug/1` per process surfaces the drop — the deferred form skips
  # the interpolation entirely when the level is above `:debug`. Mirrors
  # `lib/allm/providers/anthropic.ex:883-899`.
  # `:auto` is `ALLM.ImagePart`'s DEFAULT (`lib/allm/image_part.ex:39`), so it
  # means "the caller expressed no preference" — nothing was really dropped and
  # logging it would fire on every plainly-constructed `ImagePart.new/1`.
  # Matches `lib/allm/providers/gemini.ex:755`, which excludes `:auto` for the
  # same reason. (`lib/allm/providers/anthropic.ex:883` does NOT, and is the
  # noisier outlier — see the `[DEFERRED-DRY]` ticket in `ASKS.md`.)
  defp detail_drop_check(:auto), do: :ok
  defp detail_drop_check(nil), do: :ok

  defp detail_drop_check(_detail) do
    warn_detail_dropped_once()
    :ok
  end

  defp warn_detail_dropped_once do
    if !Process.get(:allm_openai_moderation_detail_warned, false) do
      Logger.debug(fn ->
        "ALLM.Providers.OpenAI.Moderation: ImagePart.detail is not part of the " <>
          "/v1/moderations request shape; dropping. This message fires once per process."
      end)

      Process.put(:allm_openai_moderation_detail_warned, true)
    end

    :ok
  end

  defp put_pair(body, nil), do: body
  defp put_pair(body, {key, value}), do: Map.put(body, key, value)

  defp model_pair(%ModerationRequest{model: nil}), do: nil
  defp model_pair(%ModerationRequest{model: m}) when is_binary(m), do: {"model", m}
  defp model_pair(_request), do: nil

  # `:options` is the documented home for provider-specific opaque opts. Keys
  # are normalized to strings so a body never mixes atom and string keys, and
  # the merge in `to_json_body/2` puts the structural fields on top. Note the
  # provider IGNORES unknown fields (see the moduledoc), so a typo here is
  # silent rather than a 400.
  defp stringify_option_keys(options) when is_map(options) do
    Map.new(options, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp stringify_option_keys(_options), do: %{}

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
         ModerationAdapterError.new(:timeout,
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
         ModerationAdapterError.new(:network_error,
           provider: :openai,
           message: "transport failure: " <> Exception.message(exception),
           cause: sanitize_cause(exception),
           metadata: build_metadata(%{}, opts)
         )}
    end
  end

  defp classify_http_error(status, body, headers, opts) do
    classified = to_moderation_adapter_error(status, decode_error_body(body), headers, opts)

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

  defp classify_moderation_reason(401, _code, _type, _ra), do: {:authentication_failed, nil}
  defp classify_moderation_reason(403, _code, _type, _ra), do: {:authentication_failed, nil}
  defp classify_moderation_reason(429, _code, _type, ra), do: {:rate_limited, ra}

  defp classify_moderation_reason(400, code, _type, _ra) when code in @context_length_markers,
    do: {:context_length_exceeded, nil}

  defp classify_moderation_reason(400, _code, type, _ra) when type in @context_length_markers,
    do: {:context_length_exceeded, nil}

  defp classify_moderation_reason(400, _code, _type, _ra), do: {:invalid_request, nil}

  defp classify_moderation_reason(status, _code, _type, ra) when status in [500, 502, 503, 504],
    do: {:provider_unavailable, ra}

  defp classify_moderation_reason(_status, _code, _type, _ra), do: {:unknown, nil}

  defp malformed_error(detail, metadata, opts, cause \\ nil) do
    ModerationAdapterError.new(:malformed_response,
      provider: :openai,
      message: "could not parse OpenAI moderations response: " <> detail,
      cause: cause,
      metadata: build_metadata(metadata, opts)
    )
  end

  # `%ModerationAdapterError{}` derives `Jason.Encoder` and is routinely logged
  # and persisted, so `:cause` must never smuggle a raw response body through.
  # `Jason.DecodeError` carries the whole undecodable payload on `:data`;
  # everything else (transport errors) carries only a reason atom.
  defp sanitize_cause(%{__struct__: Jason.DecodeError} = cause), do: %{cause | data: ""}
  defp sanitize_cause(cause), do: cause

  # Inherited VERBATIM from `ALLM.Providers.OpenAI.Embeddings` — same provider,
  # same key shapes. See the seam banner above for why that is correct here and
  # would be a silent no-op if carried to another provider.
  defp redact_key_material(message) when is_binary(message) do
    String.replace(message, ~r/\b(?:sk|rk|org)-[A-Za-z0-9_\-]{6,}/, "[REDACTED]")
  end

  defp redact_key_material(_message), do: "OpenAI moderation error"

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

  # `:index` is assigned from array position: the wire carries no `index` field
  # on a moderation result (verified live 2026-08-31), unlike `/v1/embeddings`.
  defp decode_results(results, opts) do
    results
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, acc} ->
      case decode_result_entry(entry, index, opts) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      {:error, _} = err -> err
    end
  end

  defp decode_result_entry(%{"flagged" => flagged} = entry, index, _opts)
       when is_boolean(flagged) do
    {:ok,
     %ModerationResult{
       flagged: flagged,
       categories: decode_categories(Map.get(entry, "categories")),
       category_scores: decode_scores(Map.get(entry, "category_scores")),
       applied_input_types: Map.get(entry, "category_applied_input_types") || %{},
       index: index
     }}
  end

  defp decode_result_entry(_entry, index, opts) do
    {:error,
     malformed_error(
       ~s(results entry #{index} is missing a boolean "flagged"),
       %{index: index},
       opts
     )}
  end

  # `ALLM.ModerationResult.categories` is typed `%{String.t() => boolean()}` and
  # OpenAI types `illicit` / `illicit/violent` as "boolean or null", so a
  # non-boolean value is DROPPED rather than propagated into a typed map. An
  # absent key is already handled by `flagged_categories/1` and `score/2`.
  defp decode_categories(categories) when is_map(categories) do
    for {name, value} <- categories, is_boolean(value), into: %{}, do: {name, value}
  end

  defp decode_categories(_categories), do: %{}

  # A JSON `0` decodes to an integer and would break the declared `float()`
  # type, so numbers are coerced with `* 1.0`. Anything non-numeric is dropped
  # for the same reason a non-boolean category is.
  defp decode_scores(scores) when is_map(scores) do
    for {name, value} <- scores, is_number(value), into: %{}, do: {name, value * 1.0}
  end

  defp decode_scores(_scores), do: %{}
end
