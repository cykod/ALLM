defmodule ALLM.Providers.Gemini.Images do
  @moduledoc """
  Google Gemini native image-out adapter — implements `ALLM.ImageAdapter`
  against `generateContent` with `responseModalities: ["TEXT", "IMAGE"]`
  on the Gemini-native image preview models (`gemini-3.1-flash-image-preview`
  / "Nano Banana 2", `gemini-3-pro-image-preview` / "Nano Banana Pro").
  See spec §35.3, §35.7 and `steering/GEMINI_DESIGN.md` Phase 16.5.

  Layer B — runtime. Consumed through the `ALLM.generate_image/3` façade.
  Keys resolve via `ALLM.Keys.fetch!(:gemini, opts)` at request-build
  time per spec §6.4 — no key ever lives on the engine.

  ## Single translator (Decision #7)

  Image generation is `generateContent` with `responseModalities`
  toggled to `["TEXT", "IMAGE"]`. The request body is built by
  `ALLM.Providers.Gemini.to_gemini_request_body/2` (the same translator
  the chat adapter uses). The image adapter then overrides
  `generationConfig.responseModalities` and adds
  `generationConfig.imageConfig.aspectRatio` from the Decision #19
  size-mapping table. The `:edit` operation reuses Phase 16.4's
  `part_to_block/1` for source-image translation by synthesizing a
  user-role message with `[%TextPart{}, %ImagePart{}, ...]` content.

  ## Aspect-ratio mapping (Decision #19)

  | ALLM `ImageRequest.size` | Gemini `imageConfig.aspectRatio` |
  |--------------------------|----------------------------------|
  | `"1024x1024"`, `"512x512"`, `"256x256"`, any square | `"1:1"` |
  | `"1792x1024"`, any 16:9 | `"16:9"` |
  | `"1024x1792"`, any 9:16 | `"9:16"` |
  | `"1024x768"`, any 4:3 | `"4:3"` |
  | `"768x1024"`, any 3:4 | `"3:4"` |
  | `nil` | omit `imageConfig` (Gemini default) |
  | anything else | `{:error, %ImageAdapterError{reason: :invalid_request}}` |

  Pixel sizing (`imageSize: "1K"|"2K"|"4K"`) is not exposed in v0.2's
  `ImageRequest.size` field; deferred. Aspect-ratio is the only knob.

  ## Operation gate (Decision #6)

  `supported_operations/0` returns `[:generate, :edit]`. `:variation` is
  rejected with `:unsupported_operation` BEFORE any HTTP I/O per
  `ImageAdapter` invariant 4.

  ## Test-injection escape hatch

  `opts[:adapter_opts][:image_script]`, when present, delegates to
  `ALLM.Providers.FakeImages.generate/2` BEFORE any pre-flight gate
  runs. Mirrors the OpenAI.Images precedent at
  `lib/allm/providers/openai/images.ex:251` (Phase 14.3 Decision #20).

  ## Shared response decoder (Cross-function invariant)

  Response bodies are decoded via `ALLM.Providers.Gemini.Decode.candidate_parts/1`
  — the same helper `Gemini.generate/2` calls (see
  `lib/allm/providers/gemini.ex:991` post-Phase-16.5 refactor). The image
  adapter consumes the `image_parts` element of the returned tuple while
  the chat adapter consumes `text` + `tool_calls`; both walk the parts
  list once. Per `steering/GEMINI_DESIGN.md` cross-function invariants
  lines 217-219.
  """

  @behaviour ALLM.ImageAdapter

  alias ALLM.Error.ImageAdapterError

  alias ALLM.{
    Image,
    ImagePart,
    ImageRequest,
    ImageResponse,
    ImageUsage,
    Keys,
    Message,
    Request,
    Retry,
    TextPart
  }

  alias ALLM.Providers.{FakeImages, Gemini}
  alias ALLM.Providers.Gemini.Decode
  alias ALLM.Providers.Support.GeminiHeaders

  @base_url "https://generativelanguage.googleapis.com/v1beta"

  # ---------------------------------------------------------------------------
  # ALLM.ImageAdapter callbacks
  # ---------------------------------------------------------------------------

  @doc """
  Return the closed list of operations Gemini's image adapter supports.

  Per Decision #6 — `[:generate, :edit]`. `:variation` is not supported
  by the Gemini-native image models and is rejected pre-flight.

  ## Examples

      iex> ALLM.Providers.Gemini.Images.supported_operations()
      [:generate, :edit]
  """
  @impl ALLM.ImageAdapter
  @spec supported_operations() :: [:generate | :edit]
  def supported_operations, do: [:generate, :edit]

  @doc """
  Execute an image-generation or edit request synchronously.

  ## Pre-flight gates (per ImageAdapter invariant 4)

  Before any HTTP I/O, `generate/2` checks (in order):

    1. **Test-injection escape hatch.** When
       `opts[:adapter_opts][:image_script]` is non-nil, the call delegates
       to `ALLM.Providers.FakeImages.generate/2`.
    2. **Operation gate.** `request.operation in supported_operations()`.
       Failure → `:unsupported_operation` with
       `metadata: %{operation: op}`.
    3. **Aspect-ratio gate.** `request.size`, when non-nil, must map to
       one of `"1:1" | "16:9" | "9:16" | "4:3" | "3:4"`. Failure →
       `:invalid_request`.

  Key resolution (`ALLM.Keys.fetch!/2`) runs AFTER the gates — a request
  rejected pre-flight does not require a valid key.

  ## Request-id / metadata round-trip (invariants 5 + 6)

  `opts[:request_id]` is reflected onto `response.request_id`.
  `request.metadata` round-trips onto `response.metadata` unchanged.
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

  Same gate ordering as `generate/2`. Returns `{:error, %ImageAdapterError{}}`
  for any pre-flight failure.
  """
  @impl ALLM.ImageAdapter
  @spec prepare_request(ImageRequest.t(), keyword()) ::
          {:ok, Req.Request.t()} | {:error, ImageAdapterError.t()}
  def prepare_request(%ImageRequest{} = request, opts) when is_list(opts) do
    with :ok <- gate_operation(request, opts),
         {:ok, _aspect} <- to_aspect_ratio(request.size) |> wrap_aspect_error(opts),
         {:ok, body} <- to_image_request_body(request, opts) do
      build_http_request(body, request, opts)
    end
  end

  # ---------------------------------------------------------------------------
  # Public testing seams (`@doc false` + `@spec` per CLAUDE.md
  # "Public-test-seam helpers" rule). Names ALIGN with
  # `ALLM.Providers.OpenAI.Images` modulo arity (cross-PROVIDER analogue
  # of CLAUDE.md byte-identical helper-name rule), with documented
  # divergences for per-provider invariants:
  #
  #   IDENTICAL (byte-for-byte modulo arity):
  #   * `endpoint_for/1`              ↔ openai/images.ex:311
  #   * `to_image_adapter_error/4`    ↔ openai/images.ex:1065
  #   * `resolve_image_bytes/2`       ↔ openai/images.ex:856
  #   * `to_aspect_ratio/1`           — Gemini-only (Decision #19; no
  #                                     OpenAI counterpart, OpenAI takes
  #                                     literal pixel sizes).
  #
  #   DIVERGENT NAMES (per-provider invariants):
  #   * `to_image_request_body/2`     ↔ openai/images.ex:613 `to_json_body/2`.
  #     Diverges because the Gemini body is built by delegating to
  #     `Gemini.to_gemini_request_body/2` (Decision #7) — the helper
  #     synthesizes a chat-equivalent `%Request{}` rather than directly
  #     materializing JSON like OpenAI does. The "request_body" name is
  #     accurate for both; OpenAI's `to_json_body` reflects that the
  #     OpenAI helper only handles the JSON-bodied endpoint (the
  #     `to_multipart_body/2` sibling handles edits/variations).
  #   * `decode_image_response/4`     ↔ openai/images.ex:1189 `decode_response/4`.
  #     Diverges because Gemini's image decode shares a `Gemini.Decode.candidate_parts/1`
  #     helper with the chat decoder (response-decoder symmetry decision);
  #     the `_image_` infix disambiguates from the chat-side decoder
  #     reachable in the same provider tree.
  #   * `gate_operation/2`            ↔ openai/images.ex:362.
  #     Identical name; only the visibility differs (Gemini exposes via
  #     `@doc false` test seam; OpenAI keeps it private). Defensible per
  #     CLAUDE.md "Public-test-seam helpers" rule given Gemini's smaller
  #     operation gate (`:variation` rejected, vs OpenAI's per-model
  #     matrix) makes the seam useful to exercise directly.
  # ---------------------------------------------------------------------------

  @doc """
  Return the Gemini endpoint path (relative to the API base URL) for the
  image-generation operation.

  Both `:generate` and `:edit` route through `generateContent` (the
  request body shape differs, the URL path does not). `:variation` is
  rejected pre-flight by `gate_operation/2`.

  ## Examples

      iex> ALLM.Providers.Gemini.Images.endpoint_for("gemini-3.1-flash-image-preview")
      "/models/gemini-3.1-flash-image-preview:generateContent"
  """
  @doc since: "0.3.0"
  @spec endpoint_for(String.t()) :: String.t()
  def endpoint_for(model) when is_binary(model) do
    "/models/#{model}:generateContent"
  end

  @doc false
  @spec gate_operation(ImageRequest.t(), keyword()) ::
          :ok | {:error, ImageAdapterError.t()}
  def gate_operation(%ImageRequest{operation: op}, opts) when is_list(opts) do
    if op in supported_operations() do
      :ok
    else
      {:error,
       ImageAdapterError.new(:unsupported_operation,
         provider: :gemini,
         message: "operation #{inspect(op)} not supported by adapter",
         metadata: build_metadata(%{operation: op}, opts)
       )}
    end
  end

  @doc """
  Map `ImageRequest.size` to Gemini's `imageConfig.aspectRatio` per
  Decision #19. Returns the raw aspect-ratio string, `:omit` for `nil`,
  or `{:error, :invalid_size}` for an unmappable size.

  Square sizes (`"NxN"` or `{n, n}`) collapse to `"1:1"`. Non-square
  sizes use exact ratio comparison rather than substring matching so
  `"768x1024"` (3:4) and `"1024x1792"` (~9:16) are disambiguated.

  ## Examples

      iex> ALLM.Providers.Gemini.Images.to_aspect_ratio("1024x1024")
      {:ok, "1:1"}

      iex> ALLM.Providers.Gemini.Images.to_aspect_ratio({1792, 1024})
      {:ok, "16:9"}

      iex> ALLM.Providers.Gemini.Images.to_aspect_ratio(nil)
      :omit

      iex> ALLM.Providers.Gemini.Images.to_aspect_ratio("999x111")
      {:error, :invalid_size}
  """
  @doc since: "0.3.0"
  @spec to_aspect_ratio(ImageRequest.size() | nil) ::
          {:ok, String.t()} | :omit | {:error, :invalid_size}
  def to_aspect_ratio(nil), do: :omit
  def to_aspect_ratio(:auto), do: :omit

  def to_aspect_ratio({w, h}) when is_integer(w) and is_integer(h) and w > 0 and h > 0 do
    classify_ratio(w, h)
  end

  def to_aspect_ratio(s) when is_binary(s) do
    case parse_size_string(s) do
      {:ok, w, h} -> classify_ratio(w, h)
      :error -> {:error, :invalid_size}
    end
  end

  def to_aspect_ratio(_), do: {:error, :invalid_size}

  defp parse_size_string(s) do
    with [w_s, h_s] <- String.split(s, "x", parts: 2),
         {w, ""} <- Integer.parse(w_s),
         {h, ""} <- Integer.parse(h_s),
         true <- w > 0 and h > 0 do
      {:ok, w, h}
    else
      _ -> :error
    end
  end

  # Compare width/height ratio to the closed Gemini set:
  # 1:1, 16:9, 9:16, 4:3, 3:4. Per Decision #19 the table accepts "any
  # 16:9 ratio" — including the canonical OpenAI-shaped `1792x1024`
  # which is not exact 16:9 (1792:1024 = 7:4 exactly, 1024 × 16/9 ≈ 1820).
  # We use a tolerance: the actual w/h ratio is within 5% of the target
  # ratio. The 1:1 row catches every square via exact compare; the
  # non-square rows use float-tolerance against `target_ratio`.
  @ratio_tolerance 0.05
  @target_ratios [
    {"16:9", 16 / 9},
    {"9:16", 9 / 16},
    {"4:3", 4 / 3},
    {"3:4", 3 / 4}
  ]

  defp classify_ratio(w, h) when w == h, do: {:ok, "1:1"}

  defp classify_ratio(w, h) do
    actual = w / h

    Enum.find_value(@target_ratios, {:error, :invalid_size}, fn {label, target} ->
      if abs(actual - target) / target <= @ratio_tolerance do
        {:ok, label}
      end
    end)
  end

  @doc """
  Build the JSON request body for an image request.

  Synthesizes a chat-equivalent `%Request{}` (single user message
  whose content is the prompt for `:generate`, or
  `[%TextPart{}, %ImagePart{}, ...]` for `:edit`) and delegates to
  `Gemini.to_gemini_request_body/2` per Decision #7. Then overrides
  `generationConfig.responseModalities = ["TEXT", "IMAGE"]` and (when the
  size maps to a known aspect ratio) adds
  `generationConfig.imageConfig.aspectRatio`. `:n > 1` adds
  `generationConfig.candidateCount: n`.

  Returns `{:error, %ImageAdapterError{reason: :invalid_request}}` for
  unmappable sizes per Decision #19's closed table.
  """
  @doc since: "0.3.0"
  @spec to_image_request_body(ImageRequest.t(), keyword()) ::
          {:ok, map()} | {:error, ImageAdapterError.t()}
  def to_image_request_body(%ImageRequest{} = request, opts) when is_list(opts) do
    with {:ok, aspect_or_omit} <- to_aspect_ratio(request.size) |> wrap_aspect_error(opts),
         {:ok, chat_request} <- to_chat_equivalent_request(request) do
      body =
        chat_request
        |> Gemini.to_gemini_request_body([])
        |> override_generation_config(request, aspect_or_omit)

      {:ok, body}
    end
  end

  # `to_aspect_ratio/1`'s 3-shape return (`{:ok, _} | :omit | {:error,
  # :invalid_size}`) collapses into the with-friendly 2-shape
  # (`{:ok, _ | :omit} | {:error, ImageAdapterError}`).
  defp wrap_aspect_error({:ok, ratio}, _opts), do: {:ok, ratio}
  defp wrap_aspect_error(:omit, _opts), do: {:ok, :omit}

  defp wrap_aspect_error({:error, :invalid_size}, opts) do
    {:error,
     ImageAdapterError.new(:invalid_request,
       provider: :gemini,
       message: "Gemini requires aspect-ratio sizes (1:1, 16:9, 9:16, 4:3, 3:4)",
       metadata: build_metadata(%{}, opts)
     )}
  end

  defp to_chat_equivalent_request(%ImageRequest{operation: :generate} = req) do
    {:ok,
     Request.new(
       [%Message{role: :user, content: req.prompt || ""}],
       model: req.model
     )}
  end

  defp to_chat_equivalent_request(%ImageRequest{operation: :edit} = req) do
    image_parts =
      Enum.map(req.input_images, fn %Image{} = img ->
        %ImagePart{image: img, detail: :auto}
      end)

    content = [%TextPart{text: req.prompt || ""} | image_parts]

    {:ok,
     Request.new(
       [%Message{role: :user, content: content}],
       model: req.model
     )}
  end

  defp override_generation_config(body, %ImageRequest{} = request, aspect_or_omit)
       when is_map(body) do
    base = Map.get(body, "generationConfig", %{})

    base
    |> Map.put("responseModalities", ["TEXT", "IMAGE"])
    |> maybe_put_image_config(aspect_or_omit)
    |> maybe_put_candidate_count(request.n)
    |> then(&Map.put(body, "generationConfig", &1))
  end

  defp maybe_put_image_config(gc, :omit), do: gc

  defp maybe_put_image_config(gc, ratio) when is_binary(ratio) do
    Map.put(gc, "imageConfig", %{"aspectRatio" => ratio})
  end

  defp maybe_put_candidate_count(gc, n) when is_integer(n) and n > 1 do
    Map.put(gc, "candidateCount", n)
  end

  defp maybe_put_candidate_count(gc, _n), do: gc

  @doc """
  Resolve an `%Image{}` source to raw bytes. Mirrors the OpenAI seam at
  `lib/allm/providers/openai/images.ex:858`.

  For Gemini, this helper exists for parity with the OpenAI image-adapter
  testing surface. The actual `:edit` request build delegates source
  translation to `Gemini.part_to_block/1` (Phase 16.4) via the chat
  translator, which handles `:binary`, `:base64`, and `:file` sources;
  `:url` is rejected by `Gemini.reject_unsupported_image_sources/1`.
  """
  @doc since: "0.3.0"
  @spec resolve_image_bytes(Image.t(), keyword()) ::
          {:ok, binary(), String.t()} | {:error, ImageAdapterError.t()}
  def resolve_image_bytes(%Image{source: {:binary, bytes}, mime_type: mime}, _opts)
      when is_binary(bytes) do
    {:ok, bytes, mime || "image/png"}
  end

  def resolve_image_bytes(%Image{source: {:base64, encoded}, mime_type: mime}, _opts)
      when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, bytes} ->
        {:ok, bytes, mime || "image/png"}

      :error ->
        {:error,
         ImageAdapterError.new(:invalid_request,
           provider: :gemini,
           message: "could not Base64-decode image source"
         )}
    end
  end

  def resolve_image_bytes(%Image{source: {:file, path}, mime_type: mime}, _opts)
      when is_binary(path) and is_binary(mime) do
    case File.read(path) do
      {:ok, bytes} ->
        {:ok, bytes, mime}

      {:error, posix} ->
        {:error,
         ImageAdapterError.new(:invalid_request,
           provider: :gemini,
           message: "could not read image source from path: " <> Atom.to_string(posix),
           metadata: %{path: path, posix: posix}
         )}
    end
  end

  def resolve_image_bytes(%Image{source: {:url, _}}, _opts) do
    {:error,
     ImageAdapterError.new(:unsupported_feature,
       provider: :gemini,
       message:
         "Gemini adapter does not fetch URL-source images; pre-fetch and pass as " <>
           "%Image{source: {:binary, _}, mime_type: _}"
     )}
  end

  def resolve_image_bytes(%Image{source: {:file, path}, mime_type: nil}, _opts) do
    {:error,
     ImageAdapterError.new(:invalid_request,
       provider: :gemini,
       message: "missing MIME type for file source: #{inspect(path)}"
     )}
  end

  # ---------------------------------------------------------------------------
  # Internals — :generate + :edit JSON path
  # ---------------------------------------------------------------------------

  defp do_generate(%ImageRequest{} = request, opts) do
    with :ok <- gate_operation(request, opts),
         {:ok, body} <- to_image_request_body(request, opts),
         {:ok, http_req} <- build_http_request(body, request, opts) do
      retry_policy = Keyword.get(opts, :retry, :default)
      telemetry_meta = build_retry_telemetry_meta(opts)

      Retry.run(retry_policy, telemetry_meta, fn ->
        run_one_attempt(http_req, request, opts)
      end)
    end
  end

  defp build_http_request(body, %ImageRequest{} = request, opts) do
    api_key = Keys.fetch!(:gemini, opts)
    url = endpoint_url(request, opts)

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

  defp endpoint_url(%ImageRequest{model: model}, opts) do
    base =
      case Keyword.get(opts, :adapter_opts, []) |> Keyword.get(:endpoint) do
        nil -> @base_url
        url when is_binary(url) -> url
      end

    base <> endpoint_for(model || "gemini-3.1-flash-image-preview")
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

  defp run_one_attempt(http_req, request, opts) do
    case Req.request(http_req) do
      {:ok, %Req.Response{status: status, body: body, headers: headers}}
      when status in 200..299 ->
        decode_image_response(body, headers, request, opts)

      {:ok, %Req.Response{status: status, body: body, headers: headers}} ->
        classify_http_error(status, body, headers, opts)

      {:error, %{__struct__: Req.TransportError, reason: :timeout} = cause} ->
        err =
          ImageAdapterError.new(:timeout,
            provider: :gemini,
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
            provider: :gemini,
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
  # Error mapping — reuses Gemini.classify_error/3 and rewraps as
  # %ImageAdapterError{}. Mirrors the OpenAI Images approach where the
  # image adapter has its own classify table (it doesn't go through chat),
  # but Gemini's chat classifier is a clean closed table and we reuse it
  # by translating the AdapterError reason to the ImageAdapterError reason
  # (the closed enums overlap exactly for HTTP-shaped errors).
  # ---------------------------------------------------------------------------

  @doc false
  @spec to_image_adapter_error(non_neg_integer(), map(), Enumerable.t() | map(), keyword()) ::
          ImageAdapterError.t()
  def to_image_adapter_error(status, body, headers, opts)
      when is_integer(status) and is_map(body) do
    chat_err = Gemini.classify_error(status, body, headers)

    base_metadata =
      build_metadata(
        Map.merge(chat_err.metadata, %{status: status}),
        opts
      )

    ImageAdapterError.new(chat_err.reason,
      provider: :gemini,
      status: chat_err.status,
      retry_after_ms: chat_err.retry_after_ms,
      message: chat_err.message,
      cause: chat_err.cause,
      metadata: base_metadata
    )
  end

  defp malformed_error(cause, opts) do
    ImageAdapterError.new(:malformed_response,
      provider: :gemini,
      message: "could not parse Gemini response: " <> inspect(cause),
      cause: cause,
      metadata: build_metadata(%{}, opts)
    )
  end

  # ---------------------------------------------------------------------------
  # Response decoder — uses the shared Gemini.Decode.candidate_parts/1
  # helper (Cross-function invariant) and then filters the image_parts
  # tuple element. n=2 walks every candidate, accumulating images.
  # ---------------------------------------------------------------------------

  @doc false
  @spec decode_image_response(term(), Enumerable.t() | map(), ImageRequest.t(), keyword()) ::
          {:ok, ImageResponse.t()} | {:error, ImageAdapterError.t()}
  def decode_image_response(body, headers, request, opts)

  def decode_image_response(%{} = body, _headers, %ImageRequest{} = request, opts) do
    case classify_image_response(body) do
      {:blocked, reason} ->
        {:error,
         ImageAdapterError.new(:content_filter,
           provider: :gemini,
           status: 200,
           message: "Gemini blocked the prompt: #{reason}",
           metadata: build_metadata(%{block_reason: reason}, opts)
         )}

      {:candidates, []} ->
        {:error,
         ImageAdapterError.new(:malformed_response,
           provider: :gemini,
           status: 200,
           message: "Gemini response carried no candidates",
           metadata: build_metadata(%{}, opts)
         )}

      {:candidates, candidates} ->
        decode_candidate_list(candidates, body, request, opts)
    end
  end

  def decode_image_response(body, _headers, _request, opts) do
    {:error,
     ImageAdapterError.new(:malformed_response,
       provider: :gemini,
       message: "Gemini returned a non-JSON body",
       metadata: build_metadata(%{body_preview: body_preview(body)}, opts)
     )}
  end

  defp classify_image_response(%{} = body) do
    case get_in(body, ["promptFeedback", "blockReason"]) do
      reason when is_binary(reason) ->
        {:blocked, reason}

      _ ->
        {:candidates, Map.get(body, "candidates", [])}
    end
  end

  defp decode_candidate_list(candidates, body, %ImageRequest{} = request, opts) do
    images =
      candidates
      |> Enum.flat_map(fn cand ->
        {_text, _tool_calls, image_parts, _raw_finish} = Decode.candidate_parts(cand)
        Enum.map(image_parts, & &1.image)
      end)

    case images do
      [] ->
        {:error,
         ImageAdapterError.new(:malformed_response,
           provider: :gemini,
           status: 200,
           message: "Gemini response carried no inlineData parts",
           metadata: build_metadata(%{}, opts)
         )}

      [_ | _] = imgs ->
        {:ok, build_response(imgs, body, request, opts)}
    end
  end

  defp build_response(images, body, %ImageRequest{} = request, opts) do
    request_id = Keyword.get(opts, :request_id)
    base_metadata = request.metadata || %{}

    metadata =
      case Map.get(body, "modelVersion") do
        nil -> base_metadata
        v -> Map.put_new(base_metadata, :model_version, v)
      end

    %ImageResponse{
      id: nil,
      request_id: request_id,
      model: request.model,
      images: images,
      usage: %ImageUsage{images: length(images)},
      raw: body,
      metadata: metadata
    }
  end

  defp body_preview(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp body_preview(body), do: body |> inspect() |> String.slice(0, 200)

  # ---------------------------------------------------------------------------
  # Internals — opts plumbing
  # ---------------------------------------------------------------------------

  defp fetch_image_script(opts) do
    opts
    |> Keyword.get(:adapter_opts, [])
    |> Keyword.get(:image_script)
  end

  # Per `ImageAdapter` invariant 5: when `opts[:request_id]` is present,
  # every error surfaced from this adapter carries it on
  # `metadata[:request_id]`.
  defp build_metadata(metadata, opts) when is_map(metadata) do
    case Keyword.get(opts, :request_id) do
      nil -> metadata
      request_id -> Map.put(metadata, :request_id, request_id)
    end
  end

  defp build_retry_telemetry_meta(opts) do
    base = %{provider: :gemini}

    case Keyword.get(opts, :request_id) do
      nil -> base
      value -> Map.put(base, :request_id, value)
    end
  end
end
