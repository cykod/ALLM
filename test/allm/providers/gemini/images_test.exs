defmodule ALLM.Providers.Gemini.ImagesTest do
  @moduledoc """
  Phase 16.5 unit tests for `ALLM.Providers.Gemini.Images`.

  Covers Test Plan §16.5.1 first list:

    * `supported_operations/0 == [:generate, :edit]` (Decision #6).
    * `:variation` rejected with `:unsupported_operation` BEFORE I/O.
    * `:generate` sets `responseModalities: ["TEXT", "IMAGE"]`.
    * Decodes `inlineData` parts to `%Image{source: {:binary, ...}, mime_type: ...}`.
    * `n=2` sets `candidateCount: 2` and decodes two `%Image{}` entries.
    * `:edit` sends parts list with both inlineData and text.
    * `size: "1024x1024"` → `aspectRatio: "1:1"` (Decision #19 mapping rows).
    * `request_timeout` honored.
    * `promptFeedback.blockReason` → `:content_filter` (image flow).
    * Decision #15 error mapping (one row per HTTP status).
    * `request_id` round-trip (invariant 5).
    * `metadata` round-trip (invariant 6).
  """
  use ExUnit.Case, async: false

  doctest ALLM.Providers.Gemini.Images

  alias ALLM.Error.ImageAdapterError
  alias ALLM.{Image, ImageRequest, ImageResponse, ImageUsage}
  alias ALLM.Providers.Gemini.Images
  alias ALLM.Providers.GeminiTestFixtures, as: Fx

  setup do
    on_exit(fn -> ALLM.Keys.delete(:gemini) end)
    :ok
  end

  defp gen_request(opts \\ []) do
    ImageRequest.new(
      Keyword.merge(
        [
          operation: :generate,
          prompt: "a kestrel in flight",
          model: "gemini-3.1-flash-image-preview"
        ],
        opts
      )
    )
  end

  defp edit_request(opts \\ []) do
    img = Image.from_binary(<<137, 80, 78, 71>>, "image/png")

    ImageRequest.new(
      Keyword.merge(
        [
          operation: :edit,
          prompt: "make it blue",
          model: "gemini-3.1-flash-image-preview",
          input_images: [img]
        ],
        opts
      )
    )
  end

  defp stub_json(name_prefix, status, body) do
    stub = String.to_atom("#{name_prefix}_#{System.unique_integer([:positive])}")

    Req.Test.stub(stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end)

    stub
  end

  defp call(stub, request, opts \\ []) do
    ALLM.Keys.put(:gemini, "AIza-test-key")

    Images.generate(
      request,
      Keyword.merge(
        [retry: false],
        Keyword.merge(opts, adapter_opts: merge_adapter_opts(opts, plug: {Req.Test, stub}))
      )
    )
  end

  defp merge_adapter_opts(opts, extra) do
    opts
    |> Keyword.get(:adapter_opts, [])
    |> Keyword.merge(extra)
  end

  # ---------------------------------------------------------------------------
  # supported_operations/0
  # ---------------------------------------------------------------------------

  describe "supported_operations/0" do
    test "returns the closed list [:generate, :edit] (Decision #6)" do
      assert Images.supported_operations() == [:generate, :edit]
    end
  end

  # ---------------------------------------------------------------------------
  # endpoint_for/1
  # ---------------------------------------------------------------------------

  describe "endpoint_for/1" do
    test "returns the generateContent path for the supplied model" do
      assert Images.endpoint_for("gemini-3.1-flash-image-preview") ==
               "/models/gemini-3.1-flash-image-preview:generateContent"

      assert Images.endpoint_for("gemini-3-pro-image-preview") ==
               "/models/gemini-3-pro-image-preview:generateContent"
    end
  end

  # ---------------------------------------------------------------------------
  # Operation gate (Invariant 4) — rejected BEFORE any I/O
  # ---------------------------------------------------------------------------

  describe "operation gate" do
    test ":variation → {:error, :unsupported_operation} BEFORE any HTTP I/O" do
      # No stub registered; if the gate were skipped, a Req.TransportError
      # would surface instead of the typed ImageAdapterError.
      req =
        ImageRequest.new(
          operation: :variation,
          prompt: "x",
          model: "gemini-3.1-flash-image-preview"
        )

      assert {:error, %ImageAdapterError{} = err} = Images.generate(req, retry: false)
      assert err.reason == :unsupported_operation
      assert err.metadata.operation == :variation
      assert err.provider == :gemini
    end

    test "gate_operation/2 returns :ok for :generate" do
      assert :ok == Images.gate_operation(gen_request(), [])
    end

    test "gate_operation/2 returns :ok for :edit" do
      assert :ok == Images.gate_operation(edit_request(), [])
    end

    test "gate_operation/2 stamps metadata.request_id when opts[:request_id] is set" do
      req = ImageRequest.new(operation: :variation, prompt: "x", model: "g")

      assert {:error, %ImageAdapterError{metadata: meta}} =
               Images.gate_operation(req, request_id: "rq-1")

      assert meta.request_id == "rq-1"
    end
  end

  # ---------------------------------------------------------------------------
  # to_aspect_ratio/1 — Decision #19 mapping table
  # ---------------------------------------------------------------------------

  describe "to_aspect_ratio/1" do
    test ~s("1024x1024" → "1:1") do
      assert {:ok, "1:1"} = Images.to_aspect_ratio("1024x1024")
    end

    test ~s("512x512" → "1:1") do
      assert {:ok, "1:1"} = Images.to_aspect_ratio("512x512")
    end

    test ~s({1024, 1024} tuple → "1:1") do
      assert {:ok, "1:1"} = Images.to_aspect_ratio({1024, 1024})
    end

    test ~s("1792x1024" → "16:9") do
      assert {:ok, "16:9"} = Images.to_aspect_ratio("1792x1024")
    end

    test ~s({1280, 720} tuple → "16:9") do
      assert {:ok, "16:9"} = Images.to_aspect_ratio({1280, 720})
    end

    test ~s("1024x1792" → "9:16") do
      # Canonical 9:16 size per Decision #19.
      assert {:ok, "9:16"} = Images.to_aspect_ratio("1024x1792")
    end

    test ~s("720x1280" near-9:16 → "9:16" via 5% tolerance) do
      # Non-canonical but within 5% of 9:16 (720/1280 = 0.5625 == 9/16 exactly).
      assert {:ok, "9:16"} = Images.to_aspect_ratio("720x1280")
    end

    test ~s("1024x768" → "4:3") do
      assert {:ok, "4:3"} = Images.to_aspect_ratio("1024x768")
    end

    test ~s("768x1024" → "3:4") do
      assert {:ok, "3:4"} = Images.to_aspect_ratio("768x1024")
    end

    test "nil → :omit" do
      assert :omit = Images.to_aspect_ratio(nil)
    end

    test ~s(:auto → :omit) do
      assert :omit = Images.to_aspect_ratio(:auto)
    end

    test ~s("999x111" → {:error, :invalid_size}) do
      assert {:error, :invalid_size} = Images.to_aspect_ratio("999x111")
    end

    test "garbage string → {:error, :invalid_size}" do
      assert {:error, :invalid_size} = Images.to_aspect_ratio("not a size")
    end
  end

  # ---------------------------------------------------------------------------
  # Request body shape — :generate
  # ---------------------------------------------------------------------------

  describe "to_image_request_body/2 — :generate" do
    test "sets responseModalities = [TEXT, IMAGE] and has the prompt as a single user message" do
      req = gen_request()
      assert {:ok, body} = Images.to_image_request_body(req, [])

      assert body["generationConfig"]["responseModalities"] == ["TEXT", "IMAGE"]

      assert body["contents"] == [
               %{"role" => "user", "parts" => [%{"text" => "a kestrel in flight"}]}
             ]
    end

    test "n=2 sets candidateCount: 2" do
      req = gen_request(n: 2)
      assert {:ok, body} = Images.to_image_request_body(req, [])
      assert body["generationConfig"]["candidateCount"] == 2
    end

    test "n=1 omits candidateCount" do
      req = gen_request(n: 1)
      assert {:ok, body} = Images.to_image_request_body(req, [])
      refute Map.has_key?(body["generationConfig"], "candidateCount")
    end

    test ~s(size: "1024x1024" → imageConfig.aspectRatio: "1:1") do
      req = gen_request(size: "1024x1024")
      assert {:ok, body} = Images.to_image_request_body(req, [])
      assert body["generationConfig"]["imageConfig"] == %{"aspectRatio" => "1:1"}
    end

    test "size: nil omits imageConfig" do
      req = gen_request(size: nil)
      assert {:ok, body} = Images.to_image_request_body(req, [])
      refute Map.has_key?(body["generationConfig"], "imageConfig")
    end

    test "unmappable size returns {:error, :invalid_request}" do
      req = gen_request(size: "999x111")

      assert {:error, %ImageAdapterError{reason: :invalid_request, message: msg}} =
               Images.to_image_request_body(req, [])

      assert msg =~ "aspect-ratio"
    end
  end

  # ---------------------------------------------------------------------------
  # Request body shape — :edit
  # ---------------------------------------------------------------------------

  describe "to_image_request_body/2 — :edit" do
    test "sends parts list with text and inlineData (binary source)" do
      req = edit_request()
      assert {:ok, body} = Images.to_image_request_body(req, [])

      [content] = body["contents"]
      assert content["role"] == "user"

      assert [%{"text" => "make it blue"}, %{"inlineData" => inline}] = content["parts"]
      assert inline["mimeType"] == "image/png"
      assert is_binary(inline["data"])
      # Round-trip: decoded base64 should equal the original bytes.
      assert {:ok, <<137, 80, 78, 71>>} = Base.decode64(inline["data"])
    end

    test "responseModalities still set to [TEXT, IMAGE] for :edit" do
      req = edit_request()
      assert {:ok, body} = Images.to_image_request_body(req, [])
      assert body["generationConfig"]["responseModalities"] == ["TEXT", "IMAGE"]
    end
  end

  # ---------------------------------------------------------------------------
  # Decode happy path — single inlineData candidate
  # ---------------------------------------------------------------------------

  describe "generate/2 — happy path decode" do
    test "decodes inlineData → %Image{source: {:binary, ...}, mime_type: \"image/png\"}" do
      stub = stub_json("img_single", 200, Fx.synthesized(:image_single))

      assert {:ok, %ImageResponse{} = resp} = call(stub, gen_request())
      assert resp.model == "gemini-3.1-flash-image-preview"

      assert [%Image{source: {:binary, bytes}, mime_type: "image/png"}] = resp.images
      assert is_binary(bytes)
      # base64 "iVBORw0KGgo=" decodes to 8 bytes
      assert byte_size(bytes) == 8
      assert resp.usage == %ImageUsage{images: 1}
    end

    test "n=2 decodes both candidates' inlineData parts" do
      stub = stub_json("img_n2", 200, Fx.synthesized(:image_n2))

      assert {:ok, %ImageResponse{images: imgs}} = call(stub, gen_request(n: 2))
      assert length(imgs) == 2
      assert Enum.all?(imgs, fn %Image{source: {:binary, _}} -> true end)
    end

    test "mixed text + inlineData decodes the image part (text dropped from images)" do
      stub = stub_json("img_text_image", 200, Fx.synthesized(:image_text_and_image))

      assert {:ok, %ImageResponse{images: [%Image{} = img]}} = call(stub, gen_request())
      assert img.mime_type == "image/png"
    end

    test "metadata.model_version is populated from body.modelVersion" do
      stub = stub_json("img_mv", 200, Fx.synthesized(:image_single))

      assert {:ok, %ImageResponse{metadata: meta}} = call(stub, gen_request())
      assert meta.model_version == "gemini-3.1-flash-image-preview"
    end

    test "request.metadata round-trips onto response.metadata (invariant 6)" do
      caller_meta = %{my_key: "my-value"}
      req = gen_request() |> Map.put(:metadata, caller_meta)
      stub = stub_json("img_meta_rt", 200, Fx.synthesized(:image_single))

      assert {:ok, %ImageResponse{metadata: meta}} = call(stub, req)
      assert meta.my_key == "my-value"
    end

    test "opts[:request_id] is preserved on response.request_id (invariant 5)" do
      stub = stub_json("img_rid", 200, Fx.synthesized(:image_single))

      assert {:ok, %ImageResponse{request_id: "rq-image-1"}} =
               call(stub, gen_request(), request_id: "rq-image-1")
    end
  end

  # ---------------------------------------------------------------------------
  # promptFeedback.blockReason → :content_filter
  # ---------------------------------------------------------------------------

  describe "generate/2 — promptFeedback.blockReason" do
    test "returns {:error, %ImageAdapterError{reason: :content_filter}}" do
      stub = stub_json("img_blocked", 200, Fx.synthesized(:image_blocked))

      assert {:error, %ImageAdapterError{reason: :content_filter} = err} = call(stub, gen_request())
      assert err.metadata.block_reason == "SAFETY"
      assert err.provider == :gemini
    end

    test "request_id round-trips onto error metadata" do
      stub = stub_json("img_blocked_rid", 200, Fx.synthesized(:image_blocked))

      assert {:error, %ImageAdapterError{metadata: meta}} =
               call(stub, gen_request(), request_id: "rq-blocked")

      assert meta.request_id == "rq-blocked"
    end
  end

  # ---------------------------------------------------------------------------
  # No-image candidates → :malformed_response
  # ---------------------------------------------------------------------------

  describe "generate/2 — empty image-parts" do
    test "candidates list with no inlineData parts → :malformed_response" do
      body = %{
        "candidates" => [
          %{
            "content" => %{"role" => "model", "parts" => [%{"text" => "no image here"}]},
            "finishReason" => "STOP"
          }
        ],
        "modelVersion" => "gemini-3.1-flash-image-preview"
      }

      stub = stub_json("img_noimg", 200, body)

      assert {:error, %ImageAdapterError{reason: :malformed_response}} = call(stub, gen_request())
    end

    test "completely empty candidates list → :malformed_response" do
      body = %{"candidates" => [], "modelVersion" => "gemini-3.1-flash-image-preview"}
      stub = stub_json("img_empty", 200, body)

      assert {:error, %ImageAdapterError{reason: :malformed_response}} = call(stub, gen_request())
    end
  end

  # ---------------------------------------------------------------------------
  # Error mapping — Decision #15 rows (delegated to Gemini.classify_error/3)
  # ---------------------------------------------------------------------------

  describe "generate/2 — error mapping (Decision #15)" do
    test "401 UNAUTHENTICATED → :authentication_failed" do
      stub = stub_json("img_401", 401, Fx.synthesized(:auth_failed))

      assert {:error, %ImageAdapterError{reason: :authentication_failed, status: 401}} =
               call(stub, gen_request())
    end

    test "403 PERMISSION_DENIED → :authentication_failed" do
      stub = stub_json("img_403", 403, Fx.synthesized(:permission_denied))

      assert {:error, %ImageAdapterError{reason: :authentication_failed, status: 403}} =
               call(stub, gen_request())
    end

    test "404 NOT_FOUND → :invalid_request" do
      stub = stub_json("img_404", 404, Fx.synthesized(:not_found))

      assert {:error, %ImageAdapterError{reason: :invalid_request, status: 404}} =
               call(stub, gen_request())
    end

    test "429 RESOURCE_EXHAUSTED → :rate_limited" do
      stub = stub_json("img_429", 429, Fx.synthesized(:rate_limited))

      # rate_limited is retryable; with retry: false we should still surface it.
      assert {:error, %ImageAdapterError{reason: :rate_limited, status: 429}} =
               call(stub, gen_request())
    end

    test "500 INTERNAL → :provider_unavailable" do
      stub = stub_json("img_500", 500, Fx.synthesized(:server_error))

      assert {:error, %ImageAdapterError{reason: :provider_unavailable, status: 500}} =
               call(stub, gen_request())
    end

    test "503 UNAVAILABLE → :provider_unavailable" do
      stub = stub_json("img_503", 503, Fx.synthesized(:unavailable))

      assert {:error, %ImageAdapterError{reason: :provider_unavailable, status: 503}} =
               call(stub, gen_request())
    end

    test "504 DEADLINE_EXCEEDED → :provider_unavailable" do
      stub = stub_json("img_504", 504, Fx.synthesized(:deadline_exceeded))

      assert {:error, %ImageAdapterError{reason: :provider_unavailable, status: 504}} =
               call(stub, gen_request())
    end

    test "400 generic → :invalid_request" do
      stub = stub_json("img_400", 400, Fx.synthesized(:invalid_argument))

      assert {:error, %ImageAdapterError{reason: :invalid_request, status: 400}} =
               call(stub, gen_request())
    end

    test "400 context-window → :context_length_exceeded" do
      stub = stub_json("img_400_ctx", 400, Fx.synthesized(:context_length_exceeded))

      assert {:error, %ImageAdapterError{reason: :context_length_exceeded, status: 400}} =
               call(stub, gen_request())
    end

    test "request_id round-trips onto HTTP-error metadata" do
      stub = stub_json("img_400_rid", 400, Fx.synthesized(:invalid_argument))

      assert {:error, %ImageAdapterError{metadata: meta}} =
               call(stub, gen_request(), request_id: "rq-400")

      assert meta.request_id == "rq-400"
    end
  end

  # ---------------------------------------------------------------------------
  # request_timeout
  # ---------------------------------------------------------------------------

  describe "generate/2 — request_timeout" do
    test "request_timeout opt is accepted (Req.merge plumbing)" do
      # Just confirms the option is accepted without crashing — Req.Test
      # doesn't actually time out, so the response is the happy fixture.
      # Mirrors the OpenAI Images precedent at
      # `test/allm/providers/openai/images_test.exs:request_timeout`.
      stub = stub_json("img_timeout_ok", 200, Fx.synthesized(:image_single))

      assert {:ok, %ImageResponse{}} = call(stub, gen_request(), request_timeout: 60_000)
    end

    test "Req.TransportError reason: :timeout maps to %ImageAdapterError{reason: :timeout}" do
      # Simulate a real timeout via a stub that raises the transport error.
      # Mirrors Req's actual error shape on receive_timeout exhaustion.
      stub = String.to_atom("img_timeout_err_#{System.unique_integer([:positive])}")

      Req.Test.stub(stub, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      ALLM.Keys.put(:gemini, "AIza-test-key")

      assert {:error, %ImageAdapterError{reason: :timeout}} =
               Images.generate(gen_request(),
                 retry: false,
                 adapter_opts: [plug: {Req.Test, stub}]
               )
    end
  end

  # ---------------------------------------------------------------------------
  # Test-injection escape hatch (Decision #20 — image_script delegates to FakeImages)
  # ---------------------------------------------------------------------------

  describe "generate/2 — image_script escape hatch" do
    test "delegates to FakeImages when image_script is set" do
      img = Image.from_binary(<<1, 2, 3>>, "image/png")
      script = [{:ok, [img]}]

      assert {:ok, %ImageResponse{images: [^img]}} =
               Images.generate(gen_request(), adapter_opts: [image_script: script])
    end

    test "FakeImages enforces its own operation gate independently" do
      # FakeImages allows :variation; the script path bypasses Gemini.Images's
      # own gate by design (Decision #20). This test pins that semantics.
      img = Image.from_binary(<<1>>, "image/png")
      req = ImageRequest.new(operation: :variation, prompt: "x", model: "g", input_images: [img])

      assert {:ok, %ImageResponse{}} =
               Images.generate(req, adapter_opts: [image_script: [{:ok, [img]}]])
    end
  end

  # ---------------------------------------------------------------------------
  # prepare_request/2
  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # resolve_image_bytes/2 — public seam coverage
  # ---------------------------------------------------------------------------

  describe "resolve_image_bytes/2" do
    test ":binary source returns bytes verbatim" do
      img = Image.from_binary(<<1, 2, 3>>, "image/png")
      assert {:ok, <<1, 2, 3>>, "image/png"} = Images.resolve_image_bytes(img, [])
    end

    test ":binary source with no mime defaults to image/png" do
      img = %Image{source: {:binary, <<1>>}, mime_type: nil}
      assert {:ok, <<1>>, "image/png"} = Images.resolve_image_bytes(img, [])
    end

    test ":base64 source decodes to bytes" do
      img = Image.from_base64(Base.encode64(<<1, 2, 3>>), "image/png")
      assert {:ok, <<1, 2, 3>>, "image/png"} = Images.resolve_image_bytes(img, [])
    end

    test ":base64 source with no mime defaults to image/png" do
      img = %Image{source: {:base64, Base.encode64(<<1>>)}, mime_type: nil}
      assert {:ok, <<1>>, "image/png"} = Images.resolve_image_bytes(img, [])
    end

    test ":base64 source with invalid base64 → :invalid_request" do
      img = %Image{source: {:base64, "not!valid!base64!"}, mime_type: "image/png"}

      assert {:error, %ImageAdapterError{reason: :invalid_request, message: msg}} =
               Images.resolve_image_bytes(img, [])

      assert msg =~ "Base64-decode"
    end

    test ":file source reads from disk" do
      path =
        Path.join(System.tmp_dir!(), "gemini_images_test_#{System.unique_integer([:positive])}.png")

      File.write!(path, <<1, 2, 3>>)
      on_exit(fn -> File.rm(path) end)

      img = %Image{source: {:file, path}, mime_type: "image/png"}
      assert {:ok, <<1, 2, 3>>, "image/png"} = Images.resolve_image_bytes(img, [])
    end

    test ":file source with read error → :invalid_request" do
      img = %Image{source: {:file, "/nonexistent/path/foo.png"}, mime_type: "image/png"}

      assert {:error, %ImageAdapterError{reason: :invalid_request, metadata: meta}} =
               Images.resolve_image_bytes(img, [])

      assert meta.posix == :enoent
    end

    test ":url source → :unsupported_feature" do
      img = Image.from_url("https://example.com/x.png")

      assert {:error, %ImageAdapterError{reason: :unsupported_feature, message: msg}} =
               Images.resolve_image_bytes(img, [])

      assert msg =~ "URL-source"
    end
  end

  # ---------------------------------------------------------------------------
  # to_aspect_ratio/1 — non-binary fallthrough
  # ---------------------------------------------------------------------------

  describe "to_aspect_ratio/1 — fallthrough" do
    test "atom that's not :auto → {:error, :invalid_size}" do
      assert {:error, :invalid_size} = Images.to_aspect_ratio(:weird)
    end
  end

  # ---------------------------------------------------------------------------
  # endpoint override
  # ---------------------------------------------------------------------------

  describe "generate/2 — endpoint override" do
    test "honors opts[:adapter_opts][:endpoint]" do
      stub = stub_json("img_endpoint", 200, Fx.synthesized(:image_single))

      # When custom endpoint is set, the request still goes to it (Req.Test
      # plug intercepts regardless). This pins the override path is exercised.
      assert {:ok, %ImageResponse{}} =
               call(stub, gen_request(),
                 adapter_opts: [endpoint: "https://custom.example.com/v1beta"]
               )
    end
  end

  # ---------------------------------------------------------------------------
  # to_image_adapter_error/4 — direct seam test
  # ---------------------------------------------------------------------------

  describe "to_image_adapter_error/4" do
    test "401 body → ImageAdapterError{reason: :authentication_failed}" do
      body = Fx.synthesized(:auth_failed)
      err = Images.to_image_adapter_error(401, body, [], [])

      assert %ImageAdapterError{reason: :authentication_failed, status: 401} = err
      assert err.metadata.status == 401
    end

    test "with opts[:request_id] stamps metadata.request_id" do
      err =
        Images.to_image_adapter_error(500, Fx.synthesized(:server_error), [], request_id: "rq-x")

      assert %ImageAdapterError{metadata: %{request_id: "rq-x"}} = err
    end
  end

  # ---------------------------------------------------------------------------
  # Key-material redaction and error-struct hygiene (Phase 22.7).
  #
  # `%ImageAdapterError{}` derives `Jason.Encoder` and downstream apps persist
  # it, so nothing that reaches it may carry credential material or a slice of
  # the raw response body. Unlike OpenAI, Gemini's real 401 text does NOT echo
  # the key back (`synthesized/auth_failed.json` is the recorded shape), so this
  # is defence in depth: the untrusted channel is `body["error"]["message"]` off
  # any non-2xx, which a proxy or gateway in front of the API populates freely.
  # `synthesized/image_auth_failed_key_echo.json` plants the token so the
  # redactor has a target at all.
  # ---------------------------------------------------------------------------

  describe "redaction" do
    @planted_key "AIzaSyFAKEKEY000111222333444555666777"

    test "an AIza token in a 401 message never reaches the error struct" do
      body = Fx.synthesized(:image_auth_failed_key_echo)
      assert body["error"]["message"] =~ @planted_key, "fixture must carry a key-shaped string"

      stub = stub_json("img_401_key", 401, body)

      assert {:error, %ImageAdapterError{reason: :authentication_failed} = err} =
               call(stub, gen_request())

      refute inspect(err) =~ @planted_key
      refute Jason.encode!(err) =~ @planted_key
      assert err.message =~ "[REDACTED]"
      assert err.message =~ "API key not valid"
    end

    test "redaction sits at the single funnel, so every non-2xx status is covered" do
      body = Fx.synthesized(:image_auth_failed_key_echo)

      for status <- [400, 401, 403, 404, 429, 500, 503, 418] do
        err = Images.to_image_adapter_error(status, body, [], [])

        refute inspect(err) =~ @planted_key,
               "status #{status} leaked key material — redaction must be structural, " <>
                 "not conditional on the classified reason"
      end
    end

    # CLAUDE.md's companion-test rule. Each provider needs its OWN pattern;
    # inheriting a sibling's is a silent no-op that redacts nothing while
    # looking correct. Asserting the siblings MISS is what makes an inherited
    # regex fail loudly here rather than pass vacuously.
    test "the OpenAI and Voyage key patterns match nothing in the same 401 fixture" do
      message = Fx.synthesized(:image_auth_failed_key_echo)["error"]["message"]

      refute message =~ ~r/\b(?:sk|rk|org)-[A-Za-z0-9_\-]{6,}/
      refute message =~ ~r/\bpa-[A-Za-z0-9_\-]{6,}/
      assert message =~ ~r/\b(?:AIza[A-Za-z0-9_\-]{6,}|ya29\.[A-Za-z0-9_\-.]{6,})/
    end

    test "a ya29. OAuth access token is redacted too" do
      body = %{
        "error" => %{
          "code" => 401,
          "status" => "UNAUTHENTICATED",
          "message" => "Invalid credential: ya29.A0ARFAKE000111222333"
        }
      }

      err = Images.to_image_adapter_error(401, body, [], [])

      refute inspect(err) =~ "ya29.A0ARFAKE000111222333"
      assert err.message =~ "[REDACTED]"
    end

    test "a non-binary provider message degrades to a static string" do
      err = Images.to_image_adapter_error(400, %{"error" => %{"message" => 123}}, [], [])

      assert err.message == "Gemini images error"
    end

    # `promptFeedback.blockReason` is an unvalidated binary off a **200** body,
    # so it never reaches `classify_http_error/4` and the non-2xx funnel cannot
    # cover it. `decode_image_response/4` redacts it at the site instead; this
    # pins that, because a comment claiming coverage is exactly what this
    # sub-phase exists to stop shipping.
    test "a blocked-prompt reason off a 200 body is redacted at its own site" do
      body = %{"promptFeedback" => %{"blockReason" => "SAFETY " <> @planted_key}}

      assert {:error, %ImageAdapterError{reason: :content_filter} = err} =
               Images.decode_image_response(body, [], gen_request(), [])

      refute inspect(err) =~ @planted_key
      refute Jason.encode!(err) =~ @planted_key
      assert err.message =~ "[REDACTED]"
      assert err.metadata[:block_reason] =~ "[REDACTED]"
    end

    test "no error struct carries a body preview" do
      stub =
        String.to_atom("img_nonjson_#{System.unique_integer([:positive])}")

      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!("a bare JSON string, not an object"))
      end)

      assert {:error, %ImageAdapterError{reason: :malformed_response} = err} =
               call(stub, gen_request())

      refute Map.has_key?(err.metadata, :body_preview)
      refute inspect(err) =~ "body_preview"
    end

    test ":cause never smuggles the undecodable payload out" do
      stub = String.to_atom("img_baddecode_#{System.unique_integer([:positive])}")

      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, "{not json #{@planted_key}")
      end)

      assert {:error, %ImageAdapterError{reason: :malformed_response} = err} =
               call(stub, gen_request())

      # `Jason.DecodeError` carries the whole undecodable payload on `:data`;
      # `sanitize_cause/1` blanks it so the persisted struct cannot smuggle a
      # response body out through `:cause`, and the message no longer
      # interpolates `inspect(cause)`.
      refute inspect(err) =~ @planted_key
      refute inspect(err) =~ "not json"
    end
  end

  describe "prepare_request/2" do
    test "returns an unfired Req.Request configured like generate/2" do
      ALLM.Keys.put(:gemini, "AIza-test-key")
      req = gen_request()

      assert {:ok, %Req.Request{} = http} = Images.prepare_request(req, [])
      assert http.method == :post
      assert URI.parse(http.url).path =~ ~r{/models/.+:generateContent}
    end

    test "rejects :variation pre-flight without resolving keys" do
      req = ImageRequest.new(operation: :variation, prompt: "x", model: "g")

      # Even with no key in the environment, the gate fires first.
      assert {:error, %ImageAdapterError{reason: :unsupported_operation}} =
               Images.prepare_request(req, [])
    end

    test "rejects unmappable size pre-flight" do
      ALLM.Keys.put(:gemini, "AIza-test-key")
      req = gen_request(size: "999x111")

      assert {:error, %ImageAdapterError{reason: :invalid_request}} =
               Images.prepare_request(req, [])
    end
  end
end
