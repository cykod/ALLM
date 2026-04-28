defmodule ALLM.Providers.OpenAI.Images do
  @moduledoc """
  OpenAI Images provider adapter — implements `ALLM.ImageAdapter` against
  OpenAI's `/v1/images/generations`, `/v1/images/edits`, and
  `/v1/images/variations` endpoints. See spec §35.7.

  Layer B — runtime. Constructed via
  `ALLM.Engine.new(image_adapter: ALLM.Providers.OpenAI.Images, model: "dall-e-2")`
  and consumed through the `ALLM.generate_image/3 · edit_image/4 ·
  image_variations/3` façade (Phase 14.2). Keys resolve via
  `ALLM.Keys.fetch!(:openai, opts)` at request-build time per spec §6.4 —
  no key ever lives on the engine.

  ## Status

  The JSON `:generate` HTTP path is wired for `dall-e-2`, `dall-e-3`, and
  `gpt-image-1`. The gpt-image-1 path applies forced-base64 normalization
  (gpt-image-1 ignores `response_format` at the wire), token-based usage
  (`input_tokens` / `output_tokens`), and `output_format` → `:mime_type`
  mapping per Decision #19. The multipart `:edit` HTTP path is wired for
  `dall-e-2` and `gpt-image-1`, including URL-source eager-download per
  Decision #8. The `:variation` path is wired for `dall-e-2` via the same
  multipart machinery as `:edit` — variation drops `prompt` and `mask`
  fields and otherwise mirrors `:edit`'s wire shape.

  ## Model × Operation matrix

  | Model         | `:generate` | `:edit` | `:variation` | Wire format       | Usage shape                              |
  |---------------|:-----------:|:-------:|:------------:|-------------------|------------------------------------------|
  | `dall-e-2`    |     yes     |   yes   |     yes      | `url` or `b64_json` per caller | `images = length(data)`           |
  | `dall-e-3`    |     yes     |   no    |     no       | `url` or `b64_json` per caller | `images = length(data)`           |
  | `gpt-image-1` |     yes     |   yes   |     no       | `b64_json` ALWAYS (forced)     | `images` + `input_tokens` + `output_tokens` |

  Cells marked "no" produce
  `{:error, %ImageAdapterError{reason: :unsupported_operation,
  metadata: %{operation: op, model: model}}}` BEFORE any HTTP I/O. Unknown
  models (any string not in the matrix) fall through to the provider —
  see Decision #3 of `steering/PHASE_15_image_layer_6.md`.

  ## gpt-image-1 specifics

  * **Body fields.** When `request.model == "gpt-image-1"`, `to_json_body/2`
    OMITS `response_format`, includes `quality` / `background` per the
    wire-field map, and includes `output_format` from
    `request.options[:output_format]` (`"png" | "jpeg" | "webp"`). When
    `:output_format` is absent the adapter OMITS the field and the OpenAI
    API applies its server-side default of `"png"`. Per CLAUDE.md
    "Adapters MUST document any default they inject for a Layer-A `nil`
    field that the wire requires" — gpt-image-1's `output_format` does
    NOT need an adapter-side default because the provider-default and the
    project's response `:mime_type` default both resolve to PNG.
  * **Response decode.** gpt-image-1 always returns `b64_json` per image.
    For `:binary` callers the adapter Base64-decodes server-side; for
    `:base64` callers the b64 is forwarded verbatim. `:url` callers are
    rejected pre-flight (Decision #6).
  * **Response `:mime_type`.** Driven by `request.options[:output_format]`
    via `mime_type_for_output_format/1`: `"png"|:png` → `"image/png"`,
    `"jpeg"|:jpeg|:jpg` → `"image/jpeg"`, `"webp"|:webp` → `"image/webp"`,
    absent → `"image/png"`.
  * **Token usage.** `ImageUsage.input_tokens` / `output_tokens` from
    `body.usage`; `ImageUsage.images = length(data)` as elsewhere.
    `body.usage.input_tokens_details` (when present) lands on
    `response.metadata[:usage_details]` without overwriting caller keys.

  ## Multipart vs JSON dispatch (Decision #7)

  The `:generate` operation uses an `application/json` body via
  `Req.new(json: ...)` and `OpenAIHeaders.json_headers/2`. The `:edit`
  and `:variation` operations require an actual image upload, so they
  use `multipart/form-data` via `Req.new(form_multipart: ...)` and
  `OpenAIHeaders.multipart_headers/2` (which elides `content-type` so
  Req's `:form_multipart` step stamps it with the boundary).

  Both paths flow through the same `Retry.run/3` integration and share
  the same `decode_response/4` and `to_image_adapter_error/4` helpers —
  the response shape is identical to `:generate` (a `data: [...]` array
  of url/b64_json items, optional `usage` on gpt-image-1).

  ## URL-source resolution (Decision #8)

  `:edit` / `:variation` requests carrying `Image.from_url/1` images are
  eagerly fetched at request-build time. The `Req.get/2` call honors a 30 s
  default `receive_timeout` (override via `opts[:request_timeout]`), a
  5-redirect cap, and a 25 MB body-size cap. Failure modes (closed):

  * **Non-2xx HTTP status** → `:invalid_request` with
    `metadata: %{url: u, status: status}`.
  * **Non-image content-type** (must prefix-match
    `~r{^image/(png|jpeg|jpg|webp|gif)$}`) → `:invalid_request` with
    `metadata: %{url: u, content_type: ct}`.
  * **Body > 25 MB** → `:invalid_request` with
    `metadata: %{url: u, size: bytes}`.
  * **More than 5 redirects** (`Req.TooManyRedirectsError`) →
    `:invalid_request` with `metadata: %{url: u}`.
  * **Timeout / network error** (`Req.TransportError`, etc.) →
    `:network_error` with `metadata: %{url: u}` and the underlying
    exception on `:cause`.

  URL fetches are stubbable in tests via `Req.Test.stub/2`; pass the same
  `adapter_opts: [plug: {Req.Test, stub}]` used for the API stub and the
  fetch will route through the stub.

  ## Test-injection escape hatch

  Per Decision #20, `generate/2` honors
  `opts[:adapter_opts][:image_script]` as a documented test-only short-
  circuit: when present, the call delegates to
  `ALLM.Providers.FakeImages.generate/2` BEFORE any pre-flight gate runs
  and returns its result verbatim. This is the same pattern
  `ALLM.Test.ImageAdapterConformance` uses to script adapters under test.
  Production callers do not populate this key.

  ## Retry integration

  HTTP error closures return `{:retry, delay_ms, error}` for 429 +
  `Retry-After`, 5xx, and timeouts; `ALLM.Retry.run/3` is wired against
  the engine's policy. Phase 14.3 augmented the retry vocabulary with the
  four image-error atoms (`:rate_limited`, `:provider_unavailable`,
  `:timeout`, `:network_error`) at the façade call site.

  ## URL-mode expiry warning

  Per Decision #5, OpenAI documents that image URLs returned via
  `response_format: :url` expire ~60 minutes after creation. Callers
  persisting `Image{source: {:url, _}}` beyond that window should
  download the bytes themselves before persisting, or request `:base64` /
  `:binary` upfront. The adapter does NOT proactively materialize
  URL-mode responses to bytes.

  ## Closed-enum mapping table caveat

  `:context_length_exceeded` is reserved in `ImageAdapterError`'s closed
  enum but is NOT actively mapped — long-prompt rejections from OpenAI
  surface as `:invalid_request` per Decision #21.
  `:unsupported_feature` is not produced by this adapter (Decision #22).
  """

  @behaviour ALLM.ImageAdapter

  alias ALLM.Error.ImageAdapterError
  alias ALLM.{Image, ImageRequest, ImageResponse, ImageUsage, Keys, Retry}
  alias ALLM.Providers.FakeImages
  alias ALLM.Providers.Support.OpenAIHeaders

  @base_url "https://api.openai.com/v1"

  @model_ops %{
    "dall-e-2" => [:generate, :edit, :variation],
    "dall-e-3" => [:generate],
    "gpt-image-1" => [:generate, :edit]
  }

  # ---------------------------------------------------------------------------
  # ALLM.ImageAdapter callbacks
  # ---------------------------------------------------------------------------

  @doc """
  Return the per-module union of operations the adapter can ever perform.

  Per Phase 14.1 Decision #3, this is a per-MODULE list, not a per-call
  function of `model`. Per-model gating lives in `gate_model_op/2`.

  ## Examples

      iex> ALLM.Providers.OpenAI.Images.supported_operations()
      [:generate, :edit, :variation]
  """
  @impl ALLM.ImageAdapter
  @spec supported_operations() :: [:generate | :edit | :variation]
  def supported_operations, do: [:generate, :edit, :variation]

  @doc """
  Execute an image-generation request synchronously against OpenAI.

  ## Pre-flight gates

  Before any HTTP I/O, `generate/2` checks four gates in order (per
  Invariant 1 of the design):

    1. **Operation gate.** `request.operation in supported_operations()`.
       Failure → `:unsupported_operation`.
    2. **Model gate.** When `request.model` is in the known matrix
       (`dall-e-2`, `dall-e-3`, `gpt-image-1`), the operation must be
       allowed for that model. Failure → `:unsupported_operation` with
       `metadata: %{operation: op, model: model}`. Unknown models fall
       through.
    3. **gpt-image-1 + `:url` rejection.** When `request.model ==
       "gpt-image-1"` and `request.response_format == :url`, the request
       is rejected with `:invalid_request` because gpt-image-1 only
       returns base64 (Decision #6).
    4. **URL-source resolution** — `:edit` / `:variation` requests with
       `{:url, _}` source images are eagerly fetched. Not implemented yet
       (lands with the multipart body builder).

  Key resolution (`ALLM.Keys.fetch!/2`) runs AFTER the gates per
  Invariant 2 — a request that's going to be rejected pre-flight does
  not require a valid API key.

  ## Adapter-injected defaults

  When `request.size` is `nil`, the adapter OMITS the `size` field from
  the wire body and lets OpenAI apply its server-side default
  (`"1024x1024"` for dall-e-3 / gpt-image-1; `"1024x1024"` for dall-e-2).
  Per the wire-field map row, `nil → omit`. Other size shapes encode as:
  `{w, h}` → `"<w>x<h>"`; `:auto` → `"auto"`; binary → passthrough.

  ## Test-injection short-circuit (Decision #20 / Invariant 0)

  When `opts[:adapter_opts][:image_script]` is non-nil, `generate/2`
  delegates to `ALLM.Providers.FakeImages.generate/2` with the same opts
  BEFORE any pre-flight gate runs. This is the documented test-only
  escape hatch the conformance suite uses; production callers do not
  populate this key.

  ## Response-format normalization (Decision #5)

  The provider response carries either `url:` or `b64_json:` per image.
  The adapter materializes the caller's requested form:

    * caller asked `:url` → response carries `{:url, url}` source.
    * caller asked `:base64` → response carries `{:base64, b64}` source.
    * caller asked `:binary` → adapter Base64-decodes the `b64_json`
      field server-side and produces `{:binary, bytes}` source.

  For `dall-e-2` / `dall-e-3` the response `:mime_type` defaults to
  `"image/png"`. For `gpt-image-1` the MIME type is driven by
  `request.options[:output_format]` per Decision #19:
  `"png"|:png` → `"image/png"`, `"jpeg"|:jpeg|:jpg` → `"image/jpeg"`,
  `"webp"|:webp` → `"image/webp"`. When `:output_format` is absent the
  default is `"image/png"` (matching OpenAI's server-side default). The
  adapter OMITS the `output_format` field from the wire body when
  `:output_format` is absent and lets the provider default apply.

  ## Request-id preservation (Invariant 3)

  `opts[:request_id]` is reflected onto `response.request_id`
  unchanged. The OpenAI response's `x-request-id` header is preserved
  separately on `response.metadata[:openai_request_id]` (Decision #18).

  ## Retry contract

  Wraps the HTTP call in `ALLM.Retry.run(opts[:retry] || :default, ...)`.
  The closure parses `Retry-After` (seconds form), returns
  `{:retry, delay_ms, error}` for 429/5xx/`:timeout`/`:network_error`,
  `{:ok, response}` for 2xx, and `{:error, error}` for everything else.
  """
  @impl ALLM.ImageAdapter
  @spec generate(ImageRequest.t(), keyword()) ::
          {:ok, ImageResponse.t()} | {:error, ImageAdapterError.t()}
  def generate(%ImageRequest{} = request, opts) when is_list(opts) do
    case fetch_image_script(opts) do
      nil -> do_generate(request, opts)
      _script -> FakeImages.generate(request, opts)
    end
  end

  @doc """
  Return an unfired `Req.Request` configured exactly as `generate/2`
  would fire it.

  Mirrors the chat-adapter `prepare_request/2` shape at
  `lib/allm/providers/openai.ex:411-435`. The `:generate`, `:edit`, and
  `:variation` operations are all supported; `:variation` shares the
  multipart machinery with `:edit` (variation drops `prompt` / `mask`).

  When `opts[:adapter_opts][:image_script]` is set, `prepare_request/2`
  returns the same stub error rather than delegating to `FakeImages` —
  the script path has no `Req.Request` analogue, so `prepare_request/2`
  intentionally diverges from `generate/2` (which DOES delegate to
  `FakeImages.generate/2` under the script key per Invariant 0).
  """
  @impl ALLM.ImageAdapter
  @spec prepare_request(ImageRequest.t(), keyword()) ::
          {:ok, Req.Request.t()} | {:error, ImageAdapterError.t()}
  def prepare_request(%ImageRequest{} = request, opts) when is_list(opts) do
    case fetch_image_script(opts) do
      nil ->
        case run_gates(request, opts) do
          :ok -> do_prepare(request, opts)
          {:error, %ImageAdapterError{}} = err -> err
        end

      _script ->
        # `prepare_request/2` has no analogue under the script path; fall
        # back to the stub error to keep contract uniform.
        {:error, stub_error(opts)}
    end
  end

  # ---------------------------------------------------------------------------
  # Public testing seams (@doc false but @spec'd for Dialyzer)
  # ---------------------------------------------------------------------------

  @doc """
  Return the OpenAI endpoint path (relative to the API base URL) for an
  image operation.

  ## Examples

      iex> ALLM.Providers.OpenAI.Images.endpoint_for(:generate)
      "/images/generations"

      iex> ALLM.Providers.OpenAI.Images.endpoint_for(:edit)
      "/images/edits"

      iex> ALLM.Providers.OpenAI.Images.endpoint_for(:variation)
      "/images/variations"
  """
  @doc since: "0.3.0"
  @spec endpoint_for(ImageRequest.operation()) :: String.t()
  def endpoint_for(:generate), do: "/images/generations"
  def endpoint_for(:edit), do: "/images/edits"
  def endpoint_for(:variation), do: "/images/variations"

  @doc false
  @spec gate_model_op(String.t() | nil, ImageRequest.operation()) ::
          :ok | {:error, ImageAdapterError.t()}
  def gate_model_op(nil, _operation), do: :ok

  def gate_model_op(model, operation) when is_binary(model) and is_atom(operation) do
    case Map.fetch(@model_ops, model) do
      :error ->
        # Unknown model — fall through to the provider per Decision #3.
        :ok

      {:ok, ops} ->
        if operation in ops do
          :ok
        else
          {:error,
           ImageAdapterError.new(:unsupported_operation,
             provider: :openai,
             message: "operation #{inspect(operation)} not supported by model #{inspect(model)}",
             metadata: %{operation: operation, model: model}
           )}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Internals — gates
  # ---------------------------------------------------------------------------

  defp fetch_image_script(opts) do
    opts
    |> Keyword.get(:adapter_opts, [])
    |> Keyword.get(:image_script)
  end

  # Pre-HTTP gate ordering per Invariant 1:
  #   1. operation gate
  #   2. model gate
  #   3. gpt-image-1 + :url rejection
  #   4. URL-source resolution (handled downstream in multipart builder)
  defp run_gates(%ImageRequest{} = request, opts) do
    with :ok <- gate_operation(request, opts),
         :ok <- gate_model(request, opts) do
      gate_gpt_image_1_url(request, opts)
    end
  end

  defp gate_operation(%ImageRequest{operation: op}, opts) do
    if op in supported_operations() do
      :ok
    else
      {:error,
       ImageAdapterError.new(:unsupported_operation,
         provider: :openai,
         message: "operation #{inspect(op)} not supported by adapter",
         metadata: build_metadata(%{operation: op}, opts)
       )}
    end
  end

  defp gate_model(%ImageRequest{model: model, operation: op}, opts) do
    case gate_model_op(model, op) do
      :ok ->
        :ok

      {:error, %ImageAdapterError{} = err} ->
        # Stamp request_id onto metadata uniformly per Invariant 3.
        {:error, %{err | metadata: build_metadata(err.metadata, opts)}}
    end
  end

  defp gate_gpt_image_1_url(%ImageRequest{model: "gpt-image-1", response_format: :url}, opts) do
    {:error,
     ImageAdapterError.new(:invalid_request,
       provider: :openai,
       message: "gpt-image-1 only returns base64; request response_format: :base64 or :binary",
       metadata: build_metadata(%{model: "gpt-image-1", response_format: :url}, opts)
     )}
  end

  defp gate_gpt_image_1_url(%ImageRequest{}, _opts), do: :ok

  defp stub_error(opts) do
    ImageAdapterError.new(:unknown,
      provider: :openai,
      message: "operation pending implementation",
      metadata: build_metadata(%{}, opts)
    )
  end

  # Per Invariant 3: when `opts[:request_id]` is present, every error
  # surfaced from this adapter carries it on `metadata[:request_id]` —
  # whether the failure is a pre-flight gate or an HTTP path.
  defp build_metadata(metadata, opts) when is_map(metadata) do
    case Keyword.get(opts, :request_id) do
      nil -> metadata
      request_id -> Map.put(metadata, :request_id, request_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Internals — :generate JSON path
  # ---------------------------------------------------------------------------

  defp do_generate(%ImageRequest{operation: :generate} = request, opts) do
    with :ok <- run_gates(request, opts),
         {:ok, http_req} <- build_request(request, opts) do
      retry_policy = Keyword.get(opts, :retry, :default)
      telemetry_meta = build_retry_telemetry_meta(opts)

      Retry.run(retry_policy, telemetry_meta, fn ->
        run_one_attempt(http_req, request, opts)
      end)
    end
  end

  defp do_generate(%ImageRequest{operation: op} = request, opts)
       when op in [:edit, :variation] do
    with :ok <- run_gates(request, opts),
         {:ok, http_req} <- build_multipart_request(request, opts) do
      retry_policy = Keyword.get(opts, :retry, :default)
      telemetry_meta = build_retry_telemetry_meta(opts)

      Retry.run(retry_policy, telemetry_meta, fn ->
        run_one_attempt(http_req, request, opts)
      end)
    end
  end

  # Catch-all for operation atoms not in `supported_operations()` (e.g.
  # `:foo`). The operation gate at `gate_operation/2` rejects pre-flight
  # so we always surface its typed error here — `run_gates/2` returns
  # `{:error, %ImageAdapterError{}}` for any op not in the closed
  # supported set.
  defp do_generate(%ImageRequest{} = request, opts) do
    run_gates(request, opts)
  end

  defp do_prepare(%ImageRequest{operation: :generate} = request, opts) do
    build_request(request, opts)
  end

  defp do_prepare(%ImageRequest{operation: op} = request, opts)
       when op in [:edit, :variation] do
    build_multipart_request(request, opts)
  end

  # Catch-all symmetric to `do_generate/2` for unknown operations — the
  # operation gate rejects pre-flight, surfacing the typed error here.
  defp do_prepare(%ImageRequest{} = request, opts) do
    run_gates(request, opts)
  end

  # `Keys.fetch!/2` raises `%EngineError{reason: :missing_key}` on miss
  # per spec §6.4 — we deliberately do not rescue. Mirrors chat-adapter
  # `do_prepare/3` ordering.
  defp build_request(%ImageRequest{} = request, opts) do
    api_key = Keys.fetch!(:openai, opts)
    body = to_json_body(request, opts)
    url = @base_url <> endpoint_for(request.operation)

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
  # Internals — Multipart request builder
  # ---------------------------------------------------------------------------

  # Builds a `Req.Request` for `:edit` / `:variation`. Returns
  # `{:error, %ImageAdapterError{}}` when `to_multipart_body/2` rejects an
  # input image (URL fetch failures, missing source bytes, etc.). The
  # `Req.Test.stub` and `:request_timeout` are applied identically to the
  # JSON path; `multipart_headers/2` is used so `Req`'s `:form_multipart`
  # step stamps `content-type: multipart/form-data; boundary=...`.
  @spec build_multipart_request(ImageRequest.t(), keyword()) ::
          {:ok, Req.Request.t()} | {:error, ImageAdapterError.t()}
  defp build_multipart_request(%ImageRequest{} = request, opts) do
    api_key = Keys.fetch!(:openai, opts)

    case to_multipart_body(request, opts) do
      {:ok, form} ->
        url = @base_url <> endpoint_for(request.operation)

        req =
          Req.new(
            method: :post,
            url: url,
            headers: OpenAIHeaders.multipart_headers(api_key, opts),
            form_multipart: form
          )
          |> maybe_apply_req_test_stub(opts)
          |> maybe_apply_request_timeout(opts)

        {:ok, req}

      {:error, %ImageAdapterError{}} = err ->
        err
    end
  end

  # ---------------------------------------------------------------------------
  # Internals — Field applicability predicate (15.4 retro Finding 2 lift)
  # ---------------------------------------------------------------------------

  # Per-(operation × model) field list. The list is the union of fields
  # the wire MAY carry for the cell; per-field encoders skip `nil` values
  # at the leaf so a populated request only emits the fields it actually
  # carries. File fields (`:image`, `:mask`) are skipped by the JSON
  # serializer and only emitted by the multipart serializer.
  #
  # The `:image` / `:mask` placeholders precede the plain fields so the
  # multipart payload places file parts before form parts (a
  # presentation-only nicety; OpenAI does not care about ordering).
  @spec fields_for(ImageRequest.operation(), String.t() | nil) :: [atom()]
  defp fields_for(:generate, "dall-e-2"),
    do: [:prompt, :model, :n, :size, :response_format, :user]

  defp fields_for(:generate, "dall-e-3"),
    do: [:prompt, :model, :n, :size, :response_format, :quality, :style, :user]

  defp fields_for(:generate, "gpt-image-1"),
    do: [:prompt, :model, :n, :size, :quality, :background, :output_format, :user]

  defp fields_for(:edit, "dall-e-2"),
    do: [:image, :mask, :prompt, :model, :n, :size, :response_format, :user]

  defp fields_for(:edit, "gpt-image-1"),
    do: [:image, :mask, :prompt, :model, :n, :size, :quality, :background, :output_format, :user]

  defp fields_for(:variation, "dall-e-2"),
    do: [:image, :model, :n, :size, :response_format, :user]

  # Unknown model fallback — emit the union of all plain fields and let
  # the provider reject anything it does not recognize, per Decision #3.
  # For `:edit` / `:variation` the file fields are still required, so we
  # include them.
  defp fields_for(:generate, _model),
    do: [
      :prompt,
      :model,
      :n,
      :size,
      :response_format,
      :quality,
      :style,
      :background,
      :output_format,
      :user
    ]

  defp fields_for(:edit, _model),
    do: [
      :image,
      :mask,
      :prompt,
      :model,
      :n,
      :size,
      :response_format,
      :quality,
      :background,
      :output_format,
      :user
    ]

  defp fields_for(:variation, _model),
    do: [:image, :model, :n, :size, :response_format, :user]

  # ---------------------------------------------------------------------------
  # Internals — JSON body builder
  # ---------------------------------------------------------------------------

  @doc false
  @spec to_json_body(ImageRequest.t(), keyword()) :: map()
  def to_json_body(%ImageRequest{} = request, _opts) do
    request.operation
    |> fields_for(request.model)
    |> Enum.reduce(%{}, fn field, acc ->
      case json_field(field, request) do
        nil -> acc
        {name, value} -> Map.put(acc, name, value)
      end
    end)
  end

  # `json_field/2` returns the wire `{"name", value}` for a plain field, or
  # `nil` to omit it. File fields (`:image`, `:mask`) are intercepted by
  # `multipart_field/3` and never reach this helper; the JSON serializer
  # never sees them because `to_json_body/2` only fires on `:generate`,
  # whose `fields_for/2` row excludes file fields.
  @spec json_field(atom(), ImageRequest.t()) :: {String.t(), term()} | nil
  defp json_field(:prompt, %ImageRequest{prompt: nil}), do: nil
  defp json_field(:prompt, %ImageRequest{prompt: p}) when is_binary(p), do: {"prompt", p}

  defp json_field(:model, %ImageRequest{model: nil}), do: nil
  defp json_field(:model, %ImageRequest{model: m}) when is_binary(m), do: {"model", m}

  defp json_field(:n, %ImageRequest{n: nil}), do: nil
  defp json_field(:n, %ImageRequest{n: n}) when is_integer(n), do: {"n", n}

  defp json_field(:size, %ImageRequest{size: nil}), do: nil
  defp json_field(:size, %ImageRequest{size: size}), do: {"size", to_size_string(size)}

  defp json_field(:response_format, request), do: response_format_pair(request)
  defp json_field(:quality, request), do: quality_pair(request)
  defp json_field(:style, request), do: style_pair(request)
  defp json_field(:background, request), do: background_pair(request)
  defp json_field(:output_format, request), do: output_format_pair(request)
  defp json_field(:user, request), do: user_pair(request)

  # `gpt-image-1` rejects `response_format` at the wire (Decision #5); OMIT
  # the field for that model. dall-e-2 / dall-e-3 / unknown models encode
  # `:url` → `"url"` and `:base64`/`:binary` → `"b64_json"`.
  @spec response_format_pair(ImageRequest.t()) :: {String.t(), String.t()} | nil
  defp response_format_pair(%ImageRequest{model: "gpt-image-1"}), do: nil
  defp response_format_pair(%ImageRequest{response_format: :url}), do: {"response_format", "url"}

  defp response_format_pair(%ImageRequest{response_format: rf}) when rf in [:base64, :binary],
    do: {"response_format", "b64_json"}

  defp response_format_pair(_request), do: nil

  @spec quality_pair(ImageRequest.t()) :: {String.t(), String.t()} | nil
  defp quality_pair(%ImageRequest{quality: nil}), do: nil

  defp quality_pair(%ImageRequest{quality: value}) when is_atom(value),
    do: {"quality", Atom.to_string(value)}

  defp quality_pair(%ImageRequest{quality: value}) when is_binary(value), do: {"quality", value}

  @spec style_pair(ImageRequest.t()) :: {String.t(), String.t()} | nil
  defp style_pair(%ImageRequest{style: nil}), do: nil

  defp style_pair(%ImageRequest{style: value}) when is_atom(value),
    do: {"style", Atom.to_string(value)}

  # `background` ("transparent"|"opaque") is gpt-image-1-only per the
  # wire-field map. The struct field accepts atoms `:transparent | :opaque`
  # or a binary; we encode atoms verbatim and pass binaries through.
  @spec background_pair(ImageRequest.t()) :: {String.t(), String.t()} | nil
  defp background_pair(%ImageRequest{model: "gpt-image-1", background: nil}), do: nil

  defp background_pair(%ImageRequest{model: "gpt-image-1", background: bg}) when is_atom(bg),
    do: {"background", Atom.to_string(bg)}

  defp background_pair(%ImageRequest{model: "gpt-image-1", background: bg})
       when is_binary(bg),
       do: {"background", bg}

  defp background_pair(_request), do: nil

  # `output_format` ("png"|"jpeg"|"webp") is gpt-image-1-only per the
  # wire-field map. Sourced from `request.options[:output_format]`. Per
  # Decision #19, when the key is absent the adapter OMITS the field and
  # OpenAI's server-side default ("png") applies.
  @spec output_format_pair(ImageRequest.t()) :: {String.t(), String.t()} | nil
  defp output_format_pair(%ImageRequest{model: "gpt-image-1", options: options})
       when is_map(options) do
    case Map.get(options, :output_format) do
      nil -> nil
      value when is_atom(value) -> {"output_format", Atom.to_string(value)}
      value when is_binary(value) -> {"output_format", value}
      _ -> nil
    end
  end

  defp output_format_pair(_request), do: nil

  @spec user_pair(ImageRequest.t()) :: {String.t(), String.t()} | nil
  defp user_pair(%ImageRequest{options: options}) when is_map(options) do
    case Map.get(options, :user) do
      nil -> nil
      user when is_binary(user) -> {"user", user}
      _ -> nil
    end
  end

  defp user_pair(_request), do: nil

  # ---------------------------------------------------------------------------
  # Internals — Multipart body builder
  # ---------------------------------------------------------------------------

  @doc """
  Build a multipart/form-data field list for `:edit` / `:variation`.

  Returns `{:ok, [{name, content}, ...]}` ready to hand to `Req.new(...,
  form_multipart: form)`. Plain fields are `{name, value}` 2-tuples;
  file fields (`:image`, `:mask`) use Req's `{body, opts}` shape:
  `{name, {bytes, filename: "image.png", content_type: <mime>}}`. See
  `deps/req/lib/req/steps.ex:446-468` for the encoding contract.

  All fields are emitted as strings (multipart fields are always strings on
  the wire); integer / atom values are stringified.

  URL-source images on `:edit` / `:variation` are eagerly fetched per
  Decision #8. Failure modes (closed): non-2xx, non-image content-type,
  body > 25 MB, > 5 redirects, timeout / network error. Each maps to a
  typed `%ImageAdapterError{}` with metadata describing the URL and the
  failure detail. The `Req.get/2` call honors `opts[:adapter_opts][:plug]`
  so URL fetches are stubbable in tests via `Req.Test.stub/2`.
  """
  @doc since: "0.3.0"
  @spec to_multipart_body(ImageRequest.t(), keyword()) ::
          {:ok, [{String.t(), term()}]} | {:error, ImageAdapterError.t()}
  def to_multipart_body(%ImageRequest{} = request, opts) when is_list(opts) do
    fields = fields_for(request.operation, request.model)

    # `Enum.reduce_while/3` — the first field that fails (URL fetch, base
    # decode, etc.) halts and surfaces the error. On success the list is
    # accumulated in reverse and reversed before return.
    Enum.reduce_while(fields, {:ok, []}, fn field, {:ok, acc} ->
      case multipart_field(field, request, opts) do
        :skip -> {:cont, {:ok, acc}}
        {:ok, tuple} -> {:cont, {:ok, [tuple | acc]}}
        {:error, %ImageAdapterError{}} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, list} ->
        {:ok, Enum.reverse(list)}

      {:error, %ImageAdapterError{} = err} ->
        {:error, %{err | metadata: build_metadata(err.metadata, opts)}}
    end
  end

  # Per-field multipart serializer. Returns one of:
  #   :skip                                           — field does not apply
  #   {:ok, {name, value | {bytes, filename:, ct:}}} — emit this tuple
  #   {:error, %ImageAdapterError{}}                  — abort the build
  @spec multipart_field(atom(), ImageRequest.t(), keyword()) ::
          :skip | {:ok, {String.t(), term()}} | {:error, ImageAdapterError.t()}
  defp multipart_field(:image, %ImageRequest{input_images: [base | _]} = _request, opts) do
    case resolve_image_bytes(base, opts) do
      {:ok, bytes, mime_type, filename} ->
        {:ok, {"image", {bytes, filename: filename, content_type: mime_type}}}

      {:error, %ImageAdapterError{}} = err ->
        err
    end
  end

  defp multipart_field(:image, %ImageRequest{input_images: []}, _opts) do
    {:error,
     ImageAdapterError.new(:invalid_request,
       provider: :openai,
       message: "multipart request requires at least one input image"
     )}
  end

  # `:mask` is constrained to `Image.t() | nil` by the `ImageRequest.t()`
  # typespec (see `lib/allm/image_request.ex`), so the two clauses below
  # are exhaustive over the well-typed domain. A hand-rolled `%ImageRequest{}`
  # carrying a non-Image mask would fall through to the catch-all
  # `multipart_field/3` clause and `FunctionClauseError` out of `json_field/2`
  # — that's the desired loud failure for a constructor-bypassing caller.
  defp multipart_field(:mask, %ImageRequest{mask: nil}, _opts), do: :skip

  defp multipart_field(:mask, %ImageRequest{mask: %Image{} = mask}, opts) do
    case resolve_image_bytes(mask, opts) do
      {:ok, bytes, mime_type, _filename} ->
        # Per the wire-field map: mask filename is `"mask.png"` regardless of
        # the source. OpenAI treats the filename as cosmetic.
        {:ok, {"mask", {bytes, filename: "mask.png", content_type: mime_type}}}

      {:error, %ImageAdapterError{}} = err ->
        err
    end
  end

  # Plain fields delegate to the JSON encoder; multipart strings are the
  # JSON values stringified at the leaf (`n` integer → `"4"`, atoms →
  # `Atom.to_string/1`). Skipped fields (`json_field/2` returned `nil`)
  # surface as `:skip` here.
  defp multipart_field(field, request, _opts) do
    case json_field(field, request) do
      nil -> :skip
      {name, value} -> {:ok, {name, multipart_stringify(value)}}
    end
  end

  # `multipart_stringify/1` covers exactly the value shapes `json_field/2`
  # ever returns: binary, integer, or atom. The Dialyzer-narrowed type is
  # `nil | binary() | integer()` (atom values are constrained to `nil` by
  # the encoders) so we keep the binary / integer clauses and let `nil`
  # fall through (it never reaches here — `json_field/2` returns `nil`
  # only as the "skip" sentinel and `multipart_field/3` halts before
  # calling this helper).
  @spec multipart_stringify(binary() | integer()) :: String.t()
  defp multipart_stringify(value) when is_binary(value), do: value
  defp multipart_stringify(value) when is_integer(value), do: Integer.to_string(value)

  # ---------------------------------------------------------------------------
  # Internals — Image source → bytes resolution (Decision #8)
  # ---------------------------------------------------------------------------

  # 25 MB cap on URL-fetched bodies per OpenAI's documented edit-input
  # ceiling (Decision #8).
  @url_byte_cap 25 * 1024 * 1024

  @url_image_content_types ~r{^image/(png|jpeg|jpg|webp|gif)$}

  @doc """
  Resolve an `%Image{}` source to raw bytes for multipart upload.

  Returns `{:ok, bytes, mime_type, filename}` on success or a typed
  `%ImageAdapterError{}` for URL-source failures (non-2xx, non-image
  content-type, oversized body, too many redirects, timeout / network
  error) and base64 / file decode failures.

  Filename is always `"image.png"` for `{:binary, _}` / `{:base64, _}` /
  `{:url, _}` sources (OpenAI ignores the filename for content-type
  resolution); `{:file, path}` sources use `Path.basename(path)` so the
  uploaded filename matches the local file for human readability.
  """
  @doc since: "0.3.0"
  @spec resolve_image_bytes(Image.t(), keyword()) ::
          {:ok, binary(), String.t(), String.t()} | {:error, ImageAdapterError.t()}
  def resolve_image_bytes(%Image{source: {:binary, bytes}} = image, _opts) when is_binary(bytes) do
    {:ok, bytes, image.mime_type || "image/png", "image.png"}
  end

  def resolve_image_bytes(%Image{source: {:base64, encoded}} = image, _opts)
      when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, bytes} ->
        {:ok, bytes, image.mime_type || "image/png", "image.png"}

      :error ->
        {:error,
         ImageAdapterError.new(:invalid_request,
           provider: :openai,
           message: "could not Base64-decode image source"
         )}
    end
  end

  def resolve_image_bytes(%Image{source: {:file, path}} = image, _opts) when is_binary(path) do
    case File.read(path) do
      {:ok, bytes} ->
        {:ok, bytes, image.mime_type || "image/png", Path.basename(path)}

      {:error, posix} ->
        {:error,
         ImageAdapterError.new(:invalid_request,
           provider: :openai,
           message: "could not read image source from path: " <> Atom.to_string(posix),
           metadata: %{path: path, posix: posix}
         )}
    end
  end

  def resolve_image_bytes(%Image{source: {:url, url}}, opts) when is_binary(url) do
    fetch_url_bytes(url, opts)
  end

  # `Req.get/2` against the URL with a 30 s default receive_timeout and the
  # 5-redirect cap. The plug stub from `opts[:adapter_opts][:plug]` is
  # forwarded so URL fetches are stubbable in tests via `Req.Test.stub/2`.
  # Failure modes are exhaustive per Decision #8; anything not in the
  # closed set (e.g., a 1xx / 3xx that Req surfaces as a 2xx after redirect
  # following) flows through the 2xx branch below and is screened by
  # content-type + size checks.
  defp fetch_url_bytes(url, opts) do
    timeout = Keyword.get(opts, :request_timeout) || 30_000
    plug = opts |> Keyword.get(:adapter_opts, []) |> Keyword.get(:plug)

    req_opts =
      [
        receive_timeout: timeout,
        max_redirects: 5,
        decode_body: false,
        retry: false
      ]
      |> maybe_put(:plug, plug)

    case Req.get(url, req_opts) do
      {:ok, %Req.Response{status: status, body: body, headers: headers}}
      when status in 200..299 ->
        classify_url_response(url, body, headers)

      {:ok, %Req.Response{status: status}} ->
        {:error,
         ImageAdapterError.new(:invalid_request,
           provider: :openai,
           message: "could not fetch URL-source image: #{status}",
           metadata: %{url: url, status: status}
         )}

      {:error, %{__struct__: Req.TooManyRedirectsError} = cause} ->
        {:error,
         ImageAdapterError.new(:invalid_request,
           provider: :openai,
           message: "URL-source image fetch exceeded max redirects",
           cause: cause,
           metadata: %{url: url}
         )}

      {:error, %{__struct__: Req.TransportError, reason: :timeout} = cause} ->
        {:error,
         ImageAdapterError.new(:network_error,
           provider: :openai,
           message: "URL-source image fetch timed out",
           cause: cause,
           metadata: %{url: url}
         )}

      {:error, exception} ->
        {:error,
         ImageAdapterError.new(:network_error,
           provider: :openai,
           message: "URL-source image fetch failed: " <> Exception.message(exception),
           cause: exception,
           metadata: %{url: url}
         )}
    end
  end

  defp classify_url_response(url, body, headers) when is_binary(body) do
    content_type = header_value(headers, "content-type") || ""
    normalized_ct = content_type |> String.split(";") |> List.first() |> String.trim()

    cond do
      not Regex.match?(@url_image_content_types, normalized_ct) ->
        {:error,
         ImageAdapterError.new(:invalid_request,
           provider: :openai,
           message: "URL did not return a supported image content-type",
           metadata: %{url: url, content_type: normalized_ct}
         )}

      byte_size(body) > @url_byte_cap ->
        {:error,
         ImageAdapterError.new(:invalid_request,
           provider: :openai,
           message: "URL-source image exceeds 25 MB cap",
           metadata: %{url: url, size: byte_size(body)}
         )}

      true ->
        {:ok, body, normalized_ct, "image.png"}
    end
  end

  defp classify_url_response(url, _body, _headers) do
    {:error,
     ImageAdapterError.new(:invalid_request,
       provider: :openai,
       message: "URL-source response body was not a binary",
       metadata: %{url: url}
     )}
  end

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, value), do: Keyword.put(kw, key, value)

  @doc false
  @spec to_size_string(ImageRequest.size() | nil) :: String.t() | nil
  def to_size_string(nil), do: nil
  def to_size_string(:auto), do: "auto"
  def to_size_string({w, h}) when is_integer(w) and is_integer(h), do: "#{w}x#{h}"
  def to_size_string(s) when is_binary(s), do: s

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
        err =
          ImageAdapterError.new(:timeout,
            provider: :openai,
            message: "request timed out",
            cause: cause,
            metadata: build_metadata(%{}, opts)
          )

        {:retry, 0, err}

      {:error, %{__struct__: Jason.DecodeError} = cause} ->
        {:error, malformed_error(cause, opts)}

      {:error, exception} ->
        err =
          ImageAdapterError.new(:network_error,
            provider: :openai,
            message: "transport failure: " <> Exception.message(exception),
            cause: exception,
            metadata: build_metadata(%{}, opts)
          )

        {:retry, 0, err}
    end
  end

  defp classify_http_error(status, body, headers, opts) do
    decoded = decode_error_body(body)
    classified = to_image_adapter_error(status, decoded, headers, opts)

    if classified.reason in [:rate_limited, :provider_unavailable] do
      delay = classified.retry_after_ms || 0
      {:retry, delay, classified}
    else
      {:error, classified}
    end
  end

  defp decode_error_body(body) when is_map(body), do: body
  defp decode_error_body(_), do: %{}

  # ---------------------------------------------------------------------------
  # Internals — error mapping (error contract table)
  # ---------------------------------------------------------------------------

  @doc false
  @spec to_image_adapter_error(non_neg_integer(), map(), Enumerable.t() | map(), keyword()) ::
          ImageAdapterError.t()
  def to_image_adapter_error(status, body, headers, opts)
      when is_integer(status) and is_map(body) do
    error = Map.get(body, "error", %{})
    code = Map.get(error, "code")
    type = Map.get(error, "type")
    message = Map.get(error, "message", "OpenAI HTTP #{status}")

    base_metadata =
      build_metadata(
        %{status: status, openai_code: code, openai_type: type},
        opts
      )

    {reason, retry_after} = classify_image_reason(status, code, type, retry_after_ms(headers))

    ImageAdapterError.new(reason,
      provider: :openai,
      status: status,
      retry_after_ms: retry_after,
      message: message,
      metadata: base_metadata
    )
  end

  defp classify_image_reason(401, _code, _type, _ra), do: {:authentication_failed, nil}
  defp classify_image_reason(403, _code, _type, _ra), do: {:authentication_failed, nil}
  defp classify_image_reason(429, _code, _type, ra), do: {:rate_limited, ra}

  defp classify_image_reason(400, "content_policy_violation", _type, _ra),
    do: {:content_filter, nil}

  defp classify_image_reason(400, _code, type, _ra) when is_binary(type) do
    if String.contains?(type, "content_filter"),
      do: {:content_filter, nil},
      else: {:invalid_request, nil}
  end

  defp classify_image_reason(400, _code, _type, _ra), do: {:invalid_request, nil}

  defp classify_image_reason(status, _code, _type, ra) when status in [500, 502, 503, 504],
    do: {:provider_unavailable, ra}

  defp classify_image_reason(_status, _code, _type, _ra), do: {:unknown, nil}

  defp malformed_error(cause, opts) do
    ImageAdapterError.new(:malformed_response,
      provider: :openai,
      message: "could not parse OpenAI response: " <> inspect(cause),
      cause: cause,
      metadata: build_metadata(%{}, opts)
    )
  end

  # ---------------------------------------------------------------------------
  # Internals — Retry-After header parsing
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
  defp header_value_to_string(_), do: nil

  # Per RFC 7231 §7.1.3, Retry-After is either delta-seconds (integer) or
  # an HTTP-date. OpenAI returns delta-seconds in practice (per the live
  # API docs accessed 2026-04-26); we accept the integer form and route
  # the HTTP-date form through `parse_http_date/1` for structural parity
  # with the chat adapter (`lib/allm/providers/openai.ex:700-709`).
  # Unparseable values return `nil` and the retry loop falls back to its
  # computed exponential backoff.
  defp parse_retry_after(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> seconds * 1_000
      _ -> parse_http_date(value)
    end
  end

  defp parse_retry_after(_), do: nil

  # IMF-fixdate parser stub — same shape as the chat adapter's
  # `parse_http_date/1` at `lib/allm/providers/openai.ex:709`. v0.3 returns
  # `nil` for HTTP-date forms on both adapters; future work can fill in
  # `:calendar`-based parsing without changing the surrounding contract.
  defp parse_http_date(_value), do: nil

  defp build_retry_telemetry_meta(opts) do
    %{provider: :openai}
    |> maybe_put_meta(:request_id, Keyword.get(opts, :request_id))
  end

  defp maybe_put_meta(meta, _key, nil), do: meta
  defp maybe_put_meta(meta, key, value), do: Map.put(meta, key, value)

  # ---------------------------------------------------------------------------
  # Internals — Response decoder
  # ---------------------------------------------------------------------------

  @doc false
  @spec decode_response(term(), Enumerable.t() | map(), ImageRequest.t(), keyword()) ::
          {:ok, ImageResponse.t()} | {:error, ImageAdapterError.t()}
  def decode_response(body, headers, request, opts)

  def decode_response(%{"data" => data} = body, headers, %ImageRequest{} = request, opts)
      when is_list(data) do
    case decode_data_list(data, request) do
      {:ok, []} ->
        # Empty `data: []` on a 200 maps to `:content_filter` per
        # Decision #5b.
        {:error,
         ImageAdapterError.new(:content_filter,
           provider: :openai,
           status: 200,
           message: "OpenAI returned no images (likely content-policy filter)",
           metadata: build_metadata(%{status: 200}, opts)
         )}

      {:ok, images} ->
        usage = build_usage(images, body, request)
        metadata = build_response_metadata(headers, body, request)
        request_id = Keyword.get(opts, :request_id)

        {:ok,
         %ImageResponse{
           id: Map.get(body, "id"),
           request_id: request_id,
           model: request.model,
           images: images,
           usage: usage,
           raw: body,
           metadata: metadata
         }}

      {:error, %ImageAdapterError{} = err} ->
        {:error, err}
    end
  end

  def decode_response(body, _headers, _request, opts) when is_map(body) do
    {:error,
     ImageAdapterError.new(:malformed_response,
       provider: :openai,
       message: "could not parse OpenAI response: missing or non-list :data field",
       metadata: build_metadata(%{body_preview: body_preview(body)}, opts)
     )}
  end

  def decode_response(body, _headers, _request, opts) do
    {:error,
     ImageAdapterError.new(:malformed_response,
       provider: :openai,
       message: "could not parse OpenAI response: non-JSON body",
       metadata: build_metadata(%{body_preview: body_preview(body)}, opts)
     )}
  end

  defp decode_data_list(data, %ImageRequest{} = request) do
    Enum.reduce_while(data, {:ok, []}, fn entry, {:ok, acc} ->
      case decode_image_entry(entry, request) do
        {:ok, image} -> {:cont, {:ok, [image | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      {:error, _} = err -> err
    end
  end

  # Per Decision #5: normalize the wire shape into the caller's requested
  # response_format. The provider always returns either `url:` or
  # `b64_json:`; we materialize the source variant the caller asked for.
  defp decode_image_entry(%{"url" => url} = entry, %ImageRequest{response_format: :url} = request)
       when is_binary(url) do
    {:ok, build_image(%Image{source: {:url, url}, mime_type: default_mime(request)}, entry)}
  end

  defp decode_image_entry(
         %{"b64_json" => b64} = entry,
         %ImageRequest{response_format: :base64} = request
       )
       when is_binary(b64) do
    {:ok, build_image(%Image{source: {:base64, b64}, mime_type: default_mime(request)}, entry)}
  end

  defp decode_image_entry(
         %{"b64_json" => b64} = entry,
         %ImageRequest{response_format: :binary} = request
       )
       when is_binary(b64) do
    case Base.decode64(b64) do
      {:ok, bytes} ->
        {:ok,
         build_image(%Image{source: {:binary, bytes}, mime_type: default_mime(request)}, entry)}

      :error ->
        {:error,
         ImageAdapterError.new(:malformed_response,
           provider: :openai,
           message: "could not Base64-decode b64_json image data"
         )}
    end
  end

  # The wire returned a different shape than the caller's :response_format
  # requested (e.g., dall-e-3 ignored the request and returned a URL). Map
  # gracefully: if `b64_json` is present, treat as base64 (or decode for
  # :binary callers); if only `url` is present, treat as URL. This is
  # defense-in-depth — OpenAI's documented behaviour matches the requested
  # format for dall-e-2/3.
  defp decode_image_entry(%{"b64_json" => b64} = entry, %ImageRequest{} = request)
       when is_binary(b64) do
    {:ok, build_image(%Image{source: {:base64, b64}, mime_type: default_mime(request)}, entry)}
  end

  defp decode_image_entry(%{"url" => url} = entry, %ImageRequest{} = request) when is_binary(url) do
    {:ok, build_image(%Image{source: {:url, url}, mime_type: default_mime(request)}, entry)}
  end

  defp decode_image_entry(_entry, _request) do
    {:error,
     ImageAdapterError.new(:malformed_response,
       provider: :openai,
       message: "OpenAI image entry missing both :url and :b64_json fields"
     )}
  end

  defp build_image(%Image{} = image, entry) do
    case Map.get(entry, "revised_prompt") do
      nil -> image
      revised when is_binary(revised) -> %{image | revised_prompt: revised}
    end
  end

  # dall-e-2 / dall-e-3 default to PNG. gpt-image-1 mime is driven by
  # `request.options[:output_format]` per Decision #19 — `mime_type_for_output_format/1`
  # resolves the value (atom or string) to a wire MIME type.
  defp default_mime(%ImageRequest{model: "gpt-image-1", options: options}) when is_map(options) do
    mime_type_for_output_format(Map.get(options, :output_format))
  end

  defp default_mime(%ImageRequest{model: "gpt-image-1"}), do: "image/png"
  defp default_mime(%ImageRequest{}), do: "image/png"

  @doc false
  @spec mime_type_for_output_format(atom() | String.t() | nil) :: String.t()
  def mime_type_for_output_format(nil), do: "image/png"
  def mime_type_for_output_format(:png), do: "image/png"
  def mime_type_for_output_format(:jpeg), do: "image/jpeg"
  def mime_type_for_output_format(:jpg), do: "image/jpeg"
  def mime_type_for_output_format(:webp), do: "image/webp"

  def mime_type_for_output_format(value) when is_binary(value) do
    case String.downcase(value) do
      "png" -> "image/png"
      "jpeg" -> "image/jpeg"
      "jpg" -> "image/jpeg"
      "webp" -> "image/webp"
      _ -> "image/png"
    end
  end

  def mime_type_for_output_format(_), do: "image/png"

  # `build_usage/3` populates `ImageUsage` per the wire-field map. For
  # gpt-image-1, `body.usage` carries `input_tokens` / `output_tokens`;
  # dall-e-2 / dall-e-3 omit `usage` entirely (image-count only).
  defp build_usage(images, body, %ImageRequest{model: "gpt-image-1"}) when is_map(body) do
    case Map.get(body, "usage") do
      usage when is_map(usage) ->
        %ImageUsage{
          images: length(images),
          input_tokens: get_non_neg_int(usage, "input_tokens"),
          output_tokens: get_non_neg_int(usage, "output_tokens")
        }

      _ ->
        %ImageUsage{images: length(images)}
    end
  end

  defp build_usage(images, _body, _request) do
    %ImageUsage{images: length(images)}
  end

  defp get_non_neg_int(map, key) do
    case Map.get(map, key) do
      n when is_integer(n) and n >= 0 -> n
      _ -> nil
    end
  end

  defp build_response_metadata(headers, body, %ImageRequest{metadata: caller_metadata}) do
    base = caller_metadata || %{}

    base
    |> maybe_put_openai_request_id(headers)
    |> maybe_put_usage_details(body)
  end

  defp maybe_put_openai_request_id(map, headers) do
    case header_value(headers, "x-request-id") do
      nil -> map
      value when is_binary(value) -> Map.put_new(map, :openai_request_id, value)
    end
  end

  # gpt-image-1 carries `usage.input_tokens_details` (a small map with
  # text / image token breakdowns). Surface verbatim on
  # `response.metadata[:usage_details]` without overwriting caller-supplied
  # `:usage_details` (Invariant 4 — adapter never overwrites caller keys).
  # `body` is always a map at this call site — it flows in from the
  # `decode_response/4` 2xx clause which matched `%{"data" => data} = body`.
  defp maybe_put_usage_details(map, body) when is_map(body) do
    with usage when is_map(usage) <- Map.get(body, "usage"),
         details when is_map(details) <- Map.get(usage, "input_tokens_details") do
      Map.put_new(map, :usage_details, details)
    else
      _ -> map
    end
  end

  defp body_preview(body) when is_binary(body) do
    String.slice(body, 0, 200)
  end

  defp body_preview(body) do
    body |> inspect() |> String.slice(0, 200)
  end
end
