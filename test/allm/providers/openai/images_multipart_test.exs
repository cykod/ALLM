defmodule ALLM.Providers.OpenAI.ImagesMultipartTest do
  @moduledoc """
  Multipart-builder unit tests + `:edit` wire tests for
  `ALLM.Providers.OpenAI.Images`. Phase 15.4.

  The multipart-builder unit tests assert directly on the tuple list
  `to_multipart_body/2` returns — per Decision #13, the wire-shape
  contract is "the adapter constructs the right tuples" and Req is
  responsible for encoding them to bytes. The `:edit` wire tests use
  `Req.Test.stub/2` for the API response only; the multipart payload
  goes out unmolested through Req's `:form_multipart` step.

  URL-source eager-download tests (Decision #8) inject a separate
  `Req.Test.stub` through `opts[:adapter_opts][:plug]` so URL fetches
  resolve to fixture bytes without touching the network.
  """

  use ExUnit.Case, async: true

  import ALLM.Providers.OpenAI.ImagesTestHelpers

  alias ALLM.Error.ImageAdapterError
  alias ALLM.{Image, ImageRequest, ImageResponse, ImageUsage}
  alias ALLM.Providers.OpenAI.Images

  @recorded_dir "test/fixtures/openai/images/recorded"
  @sample_png_path "test/fixtures/openai/images/inputs/sample_256.png"

  setup do
    stub = String.to_atom("openai_images_multipart_stub_#{System.unique_integer([:positive])}")
    {:ok, stub: stub}
  end

  defp call(stub, request, opts \\ []) do
    Images.generate(
      request,
      Keyword.merge(
        [api_key: "sk-images-multipart-test", retry: false],
        Keyword.merge(opts, adapter_opts: merge_adapter_opts(opts, plug: {Req.Test, stub}))
      )
    )
  end

  defp recorded(name), do: recorded(@recorded_dir, name)

  defp tiny_png_bytes do
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
    |> Base.decode64!()
  end

  defp base_image, do: Image.from_binary(tiny_png_bytes(), "image/png")

  defp edit_request(model, base, opts \\ []) do
    fields =
      [
        operation: :edit,
        prompt: Keyword.get(opts, :prompt, "make it more vibrant"),
        model: model,
        input_images: [base],
        response_format: Keyword.get(opts, :response_format, :base64)
      ]
      |> Keyword.merge(Keyword.drop(opts, [:prompt, :response_format]))

    ImageRequest.new(fields)
  end

  # ---------------------------------------------------------------------------
  # to_multipart_body/2 — unit tests on the BUILT body (Decision #13)
  # ---------------------------------------------------------------------------

  describe "to_multipart_body/2 — file source variants" do
    test "binary-source base image emits {\"image\", {bytes, filename:, content_type:}}" do
      base = base_image()
      req = edit_request("dall-e-2", base)

      assert {:ok, fields} = Images.to_multipart_body(req, [])

      assert {"image", {bytes, fopts}} = List.keyfind(fields, "image", 0)
      assert is_binary(bytes)
      assert byte_size(bytes) > 0
      assert Keyword.get(fopts, :filename) == "image.png"
      assert Keyword.get(fopts, :content_type) == "image/png"
    end

    test "base64-source image Base64-decodes and includes bytes" do
      encoded = "aGVsbG8="
      base = Image.from_base64(encoded, "image/png")
      req = edit_request("dall-e-2", base)

      assert {:ok, fields} = Images.to_multipart_body(req, [])
      assert {"image", {"hello", _fopts}} = List.keyfind(fields, "image", 0)
    end

    test "base64-source with invalid base64 → :invalid_request" do
      base = %Image{source: {:base64, "this is not valid base64 ==="}, mime_type: "image/png"}
      req = edit_request("dall-e-2", base)

      assert {:error, %ImageAdapterError{reason: :invalid_request} = err} =
               Images.to_multipart_body(req, [])

      assert err.message =~ "Base64-decode"
    end

    test "file-source image reads File.read/1 and includes bytes" do
      base = Image.from_file(@sample_png_path)
      req = edit_request("dall-e-2", base)

      assert {:ok, fields} = Images.to_multipart_body(req, [])
      assert {"image", {bytes, fopts}} = List.keyfind(fields, "image", 0)
      assert is_binary(bytes)
      assert byte_size(bytes) > 0
      # `from_file/1` populates mime from the extension, here ".png".
      assert Keyword.get(fopts, :content_type) == "image/png"
      # File-source filenames preserve the basename.
      assert Keyword.get(fopts, :filename) == "sample_256.png"
    end

    test "file-source with missing file → :invalid_request with metadata.path" do
      base = Image.from_file("/tmp/does_not_exist__phase_15_4.png")
      req = edit_request("dall-e-2", base)

      assert {:error, %ImageAdapterError{reason: :invalid_request} = err} =
               Images.to_multipart_body(req, [])

      assert err.metadata.path == "/tmp/does_not_exist__phase_15_4.png"
      assert err.metadata.posix == :enoent
    end
  end

  # ---------------------------------------------------------------------------
  # to_multipart_body/2 — mask handling
  # ---------------------------------------------------------------------------

  describe "to_multipart_body/2 — mask" do
    test "mask present → emits mask field with filename: \"mask.png\"" do
      base = base_image()
      mask = Image.from_binary(tiny_png_bytes(), "image/png")

      req =
        ImageRequest.new(
          operation: :edit,
          prompt: "x",
          model: "dall-e-2",
          input_images: [base],
          mask: mask,
          response_format: :base64
        )

      assert {:ok, fields} = Images.to_multipart_body(req, [])
      assert {"mask", {bytes, fopts}} = List.keyfind(fields, "mask", 0)
      assert is_binary(bytes)
      assert Keyword.get(fopts, :filename) == "mask.png"
      assert Keyword.get(fopts, :content_type) == "image/png"
    end

    test "mask absent → omits mask field" do
      base = base_image()
      req = edit_request("dall-e-2", base)

      assert {:ok, fields} = Images.to_multipart_body(req, [])
      refute List.keymember?(fields, "mask", 0)
    end

    test "mask URL fetch error halts the build (mask source failure surfaces)" do
      base = base_image()
      bad_mask = %Image{source: {:base64, "@@@not-base64@@@"}, mime_type: "image/png"}

      req =
        ImageRequest.new(
          operation: :edit,
          prompt: "x",
          model: "dall-e-2",
          input_images: [base],
          mask: bad_mask,
          response_format: :base64
        )

      assert {:error, %ImageAdapterError{reason: :invalid_request}} =
               Images.to_multipart_body(req, [])
    end
  end

  # ---------------------------------------------------------------------------
  # to_multipart_body/2 — URL-source eager-download (Decision #8)
  # ---------------------------------------------------------------------------

  describe "to_multipart_body/2 — URL source (Decision #8)" do
    test "happy path — Req.get returns 200 + image/png + small body → bytes included", %{
      stub: stub
    } do
      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("image/png")
        |> Plug.Conn.resp(200, tiny_png_bytes())
      end)

      base = Image.from_url("https://example.test/cat.png")
      req = edit_request("dall-e-2", base)

      assert {:ok, fields} =
               Images.to_multipart_body(req, adapter_opts: [plug: {Req.Test, stub}])

      assert {"image", {bytes, fopts}} = List.keyfind(fields, "image", 0)
      assert byte_size(bytes) > 0
      assert Keyword.get(fopts, :content_type) == "image/png"
    end

    test "URL returns 404 → :invalid_request with metadata.url + metadata.status", %{stub: stub} do
      Req.Test.stub(stub, fn conn -> Plug.Conn.resp(conn, 404, "not found") end)

      base = Image.from_url("https://example.test/missing.png")
      req = edit_request("dall-e-2", base)

      assert {:error, %ImageAdapterError{reason: :invalid_request} = err} =
               Images.to_multipart_body(req, adapter_opts: [plug: {Req.Test, stub}])

      assert err.metadata.url == "https://example.test/missing.png"
      assert err.metadata.status == 404
    end

    test "URL returns non-image content-type → :invalid_request with metadata.content_type", %{
      stub: stub
    } do
      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.resp(200, "<html>not an image</html>")
      end)

      base = Image.from_url("https://example.test/page.html")
      req = edit_request("dall-e-2", base)

      assert {:error, %ImageAdapterError{reason: :invalid_request} = err} =
               Images.to_multipart_body(req, adapter_opts: [plug: {Req.Test, stub}])

      assert err.metadata.url == "https://example.test/page.html"
      assert err.metadata.content_type == "text/html"
    end

    test "URL body > 25 MB → :invalid_request with metadata.size", %{stub: stub} do
      # A 26 MB binary is an oversized body.
      huge = :binary.copy(<<0>>, 26 * 1024 * 1024)

      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("image/png")
        |> Plug.Conn.resp(200, huge)
      end)

      base = Image.from_url("https://example.test/huge.png")
      req = edit_request("dall-e-2", base)

      assert {:error, %ImageAdapterError{reason: :invalid_request} = err} =
               Images.to_multipart_body(req, adapter_opts: [plug: {Req.Test, stub}])

      assert err.metadata.url == "https://example.test/huge.png"
      assert is_integer(err.metadata.size)
      assert err.metadata.size > 25 * 1024 * 1024
    end

    test "URL fetch network error → :network_error with metadata.url + :cause", %{stub: stub} do
      # Req.Test allows raising a transport error from the stub via
      # `Req.Test.transport_error/2`.
      Req.Test.stub(stub, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      base = Image.from_url("https://example.test/refused.png")
      req = edit_request("dall-e-2", base)

      assert {:error, %ImageAdapterError{reason: :network_error} = err} =
               Images.to_multipart_body(req, adapter_opts: [plug: {Req.Test, stub}])

      assert err.metadata.url == "https://example.test/refused.png"
      assert err.cause != nil
    end
  end

  # ---------------------------------------------------------------------------
  # to_multipart_body/2 — plain-field encoding
  # ---------------------------------------------------------------------------

  describe "to_multipart_body/2 — plain-field encoding" do
    test "n is stringified for the multipart wire" do
      base = base_image()

      req =
        ImageRequest.new(
          operation: :edit,
          prompt: "x",
          model: "dall-e-2",
          input_images: [base],
          n: 4,
          response_format: :base64
        )

      assert {:ok, fields} = Images.to_multipart_body(req, [])
      assert {"n", "4"} = List.keyfind(fields, "n", 0)
    end

    test "size is encoded via to_size_string/1" do
      base = base_image()

      req =
        ImageRequest.new(
          operation: :edit,
          prompt: "x",
          model: "dall-e-2",
          input_images: [base],
          size: {512, 512},
          response_format: :base64
        )

      assert {:ok, fields} = Images.to_multipart_body(req, [])
      assert {"size", "512x512"} = List.keyfind(fields, "size", 0)
    end

    test "n: nil is OMITTED from the multipart body" do
      base = base_image()

      req = %ImageRequest{
        operation: :edit,
        prompt: "x",
        model: "dall-e-2",
        input_images: [base],
        n: nil,
        response_format: :base64,
        options: %{},
        metadata: %{}
      }

      assert {:ok, fields} = Images.to_multipart_body(req, [])
      refute List.keymember?(fields, "n", 0)
    end

    test "user is forwarded from request.options[:user]" do
      base = base_image()

      req =
        ImageRequest.new(
          operation: :edit,
          prompt: "x",
          model: "dall-e-2",
          input_images: [base],
          response_format: :base64,
          options: %{user: "u-123"}
        )

      assert {:ok, fields} = Images.to_multipart_body(req, [])
      assert {"user", "u-123"} = List.keyfind(fields, "user", 0)
    end

    test "gpt-image-1 :edit OMITS response_format field (Decision #5)" do
      base = base_image()

      req =
        ImageRequest.new(
          operation: :edit,
          prompt: "x",
          model: "gpt-image-1",
          input_images: [base],
          response_format: :base64
        )

      assert {:ok, fields} = Images.to_multipart_body(req, [])
      refute List.keymember?(fields, "response_format", 0)
    end

    test "gpt-image-1 :edit forwards quality / background / output_format" do
      base = base_image()

      req =
        ImageRequest.new(
          operation: :edit,
          prompt: "x",
          model: "gpt-image-1",
          input_images: [base],
          response_format: :base64,
          quality: :high,
          background: :transparent,
          options: %{output_format: "webp"}
        )

      assert {:ok, fields} = Images.to_multipart_body(req, [])
      assert {"quality", "high"} = List.keyfind(fields, "quality", 0)
      assert {"background", "transparent"} = List.keyfind(fields, "background", 0)
      assert {"output_format", "webp"} = List.keyfind(fields, "output_format", 0)
    end
  end

  # ---------------------------------------------------------------------------
  # generate/2 — :edit wire happy paths
  # ---------------------------------------------------------------------------

  describe "generate/2 :edit — wire happy paths" do
    test "dall-e-2 :edit happy path → {:ok, %ImageResponse{}}", %{stub: stub} do
      body = recorded("edit_dall_e_2_happy.json") |> drop_comment()
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body) end)

      base = base_image()
      req = edit_request("dall-e-2", base, response_format: :base64)

      assert {:ok, %ImageResponse{} = resp} = call(stub, req)
      assert [%Image{source: {:base64, b64}, mime_type: "image/png"}] = resp.images
      assert is_binary(b64) and b64 != ""
      assert resp.usage.images == 1
      assert resp.model == "dall-e-2"
    end

    test "dall-e-2 :edit happy path with :binary → bytes are Base64-decoded", %{stub: stub} do
      body = recorded("edit_dall_e_2_happy.json") |> drop_comment()
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body) end)

      base = base_image()
      req = edit_request("dall-e-2", base, response_format: :binary)

      assert {:ok, %ImageResponse{images: [%Image{source: {:binary, bytes}}]}} = call(stub, req)
      # PNG signature
      assert <<137, 80, 78, 71, _::binary>> = bytes
    end

    test "gpt-image-1 :edit happy path → {:ok, %ImageResponse{}} with token usage", %{stub: stub} do
      body = recorded("edit_gpt_image_1_happy.json") |> drop_comment()
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body) end)

      base = base_image()
      req = edit_request("gpt-image-1", base, response_format: :base64)

      assert {:ok, %ImageResponse{} = resp} = call(stub, req)
      assert %ImageUsage{} = resp.usage
      assert resp.usage.images == 1
      assert is_integer(resp.usage.input_tokens) and resp.usage.input_tokens > 0
      assert is_integer(resp.usage.output_tokens) and resp.usage.output_tokens > 0
      assert is_integer(resp.metadata[:usage_details]["text_tokens"])
      assert resp.metadata[:usage_details]["text_tokens"] > 0
    end
  end

  # ---------------------------------------------------------------------------
  # generate/2 :edit — pre-flight gates (smoke-test integration)
  # ---------------------------------------------------------------------------

  describe "generate/2 :edit — pre-flight gates" do
    test "dall-e-3 :edit → :unsupported_operation BEFORE HTTP" do
      base = base_image()

      req =
        ImageRequest.new(
          operation: :edit,
          prompt: "x",
          model: "dall-e-3",
          input_images: [base]
        )

      # No stub — if the gate doesn't fire pre-HTTP, Req would attempt a
      # real HTTP request and we'd see a transport error rather than the
      # expected :unsupported_operation atom.
      assert {:error, %ImageAdapterError{reason: :unsupported_operation} = err} =
               Images.generate(req, api_key: "sk-test")

      assert err.metadata.operation == :edit
      assert err.metadata.model == "dall-e-3"
    end
  end

  # ---------------------------------------------------------------------------
  # generate/2 :edit — request-shape assertions
  # ---------------------------------------------------------------------------

  describe "generate/2 :edit — request shape" do
    test "dall-e-2 :edit sends content-type: multipart/form-data (Req sets boundary)", %{
      stub: stub
    } do
      parent = self()
      body = recorded("edit_dall_e_2_happy.json") |> drop_comment()

      Req.Test.stub(stub, fn conn ->
        ct =
          conn
          |> Plug.Conn.get_req_header("content-type")
          |> List.first()

        send(parent, {:content_type, ct})
        respond_json(conn, 200, body)
      end)

      base = base_image()
      req = edit_request("dall-e-2", base)

      assert {:ok, _} = call(stub, req)
      assert_receive {:content_type, ct}, 500
      assert is_binary(ct)
      assert ct =~ "multipart/form-data"
      # Req appends the boundary; the substring is the load-bearing part.
      assert ct =~ "boundary="
    end

    test "gpt-image-1 :edit body OMITS response_format field", %{stub: stub} do
      parent = self()
      body = recorded("edit_gpt_image_1_happy.json") |> drop_comment()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:raw_body, raw})
        respond_json(conn, 200, body)
      end)

      base = base_image()
      req = edit_request("gpt-image-1", base, response_format: :base64)

      assert {:ok, _} = call(stub, req)
      assert_receive {:raw_body, raw}, 500
      # The multipart body is bytes; assert no field literal `response_format`.
      refute raw =~ ~s|name="response_format"|
    end

    test "dall-e-2 :edit body INCLUDES response_format field", %{stub: stub} do
      parent = self()
      body = recorded("edit_dall_e_2_happy.json") |> drop_comment()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:raw_body, raw})
        respond_json(conn, 200, body)
      end)

      base = base_image()
      req = edit_request("dall-e-2", base, response_format: :base64)

      assert {:ok, _} = call(stub, req)
      assert_receive {:raw_body, raw}, 500
      assert raw =~ ~s|name="response_format"|
      assert raw =~ "b64_json"
    end

    test "dall-e-2 :edit URL → /v1/images/edits", %{stub: stub} do
      parent = self()
      body = recorded("edit_dall_e_2_happy.json") |> drop_comment()

      Req.Test.stub(stub, fn conn ->
        send(parent, {:path, conn.request_path})
        respond_json(conn, 200, body)
      end)

      base = base_image()
      req = edit_request("dall-e-2", base)

      assert {:ok, _} = call(stub, req)
      assert_receive {:path, "/v1/images/edits"}, 500
    end
  end

  # ---------------------------------------------------------------------------
  # endpoint_for/1 sanity (already covered in images_test.exs; double-checked)
  # ---------------------------------------------------------------------------

  describe "endpoint_for/1" do
    test ":edit → \"/images/edits\"" do
      assert Images.endpoint_for(:edit) == "/images/edits"
    end
  end

  # ---------------------------------------------------------------------------
  # to_multipart_body/2 — additional coverage rows
  # ---------------------------------------------------------------------------

  describe "to_multipart_body/2 — additional coverage" do
    test "missing input_images on :edit → :invalid_request" do
      req =
        ImageRequest.new(
          operation: :edit,
          prompt: "x",
          model: "dall-e-2",
          input_images: []
        )

      assert {:error, %ImageAdapterError{reason: :invalid_request} = err} =
               Images.to_multipart_body(req, [])

      assert err.message =~ "at least one input image"
    end

    test "unknown model on :edit falls through to the union field list" do
      base = base_image()

      req =
        ImageRequest.new(
          operation: :edit,
          prompt: "x",
          model: "dall-e-4-preview",
          input_images: [base],
          response_format: :base64
        )

      # Unknown model — fields_for/:edit catch-all kicks in. The image
      # field is required, so it is still emitted; plain fields follow.
      assert {:ok, fields} = Images.to_multipart_body(req, [])
      assert List.keymember?(fields, "image", 0)
      assert List.keymember?(fields, "prompt", 0)
      assert List.keymember?(fields, "model", 0)
    end

    test "build_multipart error path stamps metadata[:request_id] (Invariant 3)" do
      base = %Image{source: {:base64, "@@@"}, mime_type: "image/png"}
      req = edit_request("dall-e-2", base)

      assert {:error, %ImageAdapterError{} = err} =
               Images.to_multipart_body(req, request_id: "rid-multipart")

      assert err.metadata[:request_id] == "rid-multipart"
    end
  end

  # ---------------------------------------------------------------------------
  # resolve_image_bytes/2 — direct unit tests
  # ---------------------------------------------------------------------------

  describe "resolve_image_bytes/2" do
    test "{:binary, _} returns the bytes verbatim with explicit mime" do
      img = Image.from_binary(<<1, 2, 3>>, "image/png")
      assert {:ok, <<1, 2, 3>>, "image/png", "image.png"} = Images.resolve_image_bytes(img, [])
    end

    test "URL fetch with TooManyRedirectsError → :invalid_request" do
      # Simulating a redirect loop by stubbing each request to redirect
      # back to itself; Req.Test cannot forge `Req.TooManyRedirectsError`
      # directly, so we exercise the branch by raising the typed error
      # from the stub via `Plug.Conn.send_resp/3` chained with a 302
      # location header that points back. Req's max_redirects: 5 then
      # halts.
      stub = String.to_atom("openai_images_redirect_#{System.unique_integer([:positive])}")

      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "/again")
        |> Plug.Conn.resp(302, "")
      end)

      img = Image.from_url("https://example.test/start.png")

      assert {:error, %ImageAdapterError{reason: :invalid_request} = err} =
               Images.resolve_image_bytes(img, adapter_opts: [plug: {Req.Test, stub}])

      assert err.metadata.url == "https://example.test/start.png"
      # Either max-redirects message OR could be a 302 response without
      # the location header — assert the URL is preserved on metadata.
      assert is_binary(err.message)
    end

    test "{:binary, _} with nil mime_type defaults to image/png" do
      img = %Image{source: {:binary, <<1, 2>>}, mime_type: nil}
      assert {:ok, <<1, 2>>, "image/png", "image.png"} = Images.resolve_image_bytes(img, [])
    end

    test "{:base64, _} with nil mime_type defaults to image/png" do
      img = %Image{source: {:base64, "aGVsbG8="}, mime_type: nil}
      assert {:ok, "hello", "image/png", "image.png"} = Images.resolve_image_bytes(img, [])
    end

    test "{:url, u} routes through fetch_url_bytes/2 with stub", %{stub: stub} do
      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("image/jpeg")
        |> Plug.Conn.resp(200, "fake jpeg bytes")
      end)

      img = Image.from_url("https://example.test/photo.jpg")

      assert {:ok, "fake jpeg bytes", "image/jpeg", "image.png"} =
               Images.resolve_image_bytes(img, adapter_opts: [plug: {Req.Test, stub}])
    end
  end

  # ---------------------------------------------------------------------------
  # prepare_request/2 :edit — unfired Req.Request inspection
  # ---------------------------------------------------------------------------

  describe "prepare_request/2 :edit" do
    test "returns an unfired Req.Request with multipart body and edits URL" do
      base = base_image()
      req_struct = edit_request("dall-e-2", base)

      assert {:ok, %Req.Request{} = req} =
               Images.prepare_request(req_struct, api_key: "sk-prep")

      assert URI.parse(req.url).path == "/v1/images/edits"
      assert req.method == :post
      # Form-multipart option is set; Req encodes to bytes only at request time.
      assert is_list(req.options[:form_multipart])
    end

    test "missing api_key raises EngineError per Keys.fetch! contract" do
      base = base_image()
      req_struct = edit_request("dall-e-2", base)

      assert_raise ALLM.Error.EngineError, fn ->
        Images.prepare_request(req_struct, [])
      end
    end

    # Covers 15.2 retro Finding 5 for the :edit operation — the
    # prepare_request/2 vs generate/2 :image_script divergence is doc'd at
    # `lib/allm/providers/openai/images.ex:283-285`. The :generate variant
    # is exercised in `images_test.exs:1474`; this asserts the same
    # short-circuit holds for :edit (where the multipart wire path makes
    # the divergence more load-bearing).
    test "image_script + prepare_request/2 :edit returns the stub error (no Req.Request analogue)" do
      base = base_image()
      req = edit_request("dall-e-2", base)
      out = Image.from_binary(<<1>>, "image/png")
      opts = [api_key: "sk-prep", adapter_opts: [image_script: [{:ok, [out]}]]]

      assert {:error,
              %ImageAdapterError{reason: :unknown, message: "operation pending implementation"}} =
               Images.prepare_request(req, opts)
    end
  end

  # ---------------------------------------------------------------------------
  # generate/2 :variation — Phase 15.5
  # ---------------------------------------------------------------------------

  defp variation_request(model, base, opts \\ []) do
    fields =
      [
        operation: :variation,
        prompt: nil,
        model: model,
        input_images: [base],
        response_format: Keyword.get(opts, :response_format, :base64)
      ]
      |> Keyword.merge(Keyword.drop(opts, [:response_format]))

    ImageRequest.new(fields)
  end

  describe "generate/2 :variation — happy path" do
    test "dall-e-2 :variation happy path → {:ok, %ImageResponse{}}", %{stub: stub} do
      body = recorded("variation_dall_e_2_happy.json") |> drop_comment()
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body) end)

      base = base_image()
      req = variation_request("dall-e-2", base)

      assert {:ok, %ImageResponse{} = resp} = call(stub, req)
      assert [%Image{source: {:base64, b64}, mime_type: "image/png"}] = resp.images
      assert is_binary(b64) and b64 != ""
      assert resp.usage.images == 1
      assert resp.model == "dall-e-2"
    end
  end

  describe "generate/2 :variation — pre-flight gates" do
    test "dall-e-3 :variation → :unsupported_operation BEFORE HTTP" do
      base = base_image()

      req =
        ImageRequest.new(
          operation: :variation,
          prompt: nil,
          model: "dall-e-3",
          input_images: [base]
        )

      # No stub — if the gate doesn't fire pre-HTTP, Req would attempt
      # a real HTTP request.
      assert {:error, %ImageAdapterError{reason: :unsupported_operation} = err} =
               Images.generate(req, api_key: "sk-test")

      assert err.metadata.operation == :variation
      assert err.metadata.model == "dall-e-3"
    end

    test "gpt-image-1 :variation → :unsupported_operation BEFORE HTTP" do
      base = base_image()

      req =
        ImageRequest.new(
          operation: :variation,
          prompt: nil,
          model: "gpt-image-1",
          input_images: [base]
        )

      assert {:error, %ImageAdapterError{reason: :unsupported_operation} = err} =
               Images.generate(req, api_key: "sk-test")

      assert err.metadata.operation == :variation
      assert err.metadata.model == "gpt-image-1"
    end
  end

  describe "generate/2 :variation — request shape" do
    test "dall-e-2 :variation sends multipart/form-data with image field, no prompt", %{
      stub: stub
    } do
      parent = self()
      body = recorded("variation_dall_e_2_happy.json") |> drop_comment()

      Req.Test.stub(stub, fn conn ->
        ct =
          conn
          |> Plug.Conn.get_req_header("content-type")
          |> List.first()

        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:content_type, ct})
        send(parent, {:raw_body, raw})
        send(parent, {:path, conn.request_path})
        respond_json(conn, 200, body)
      end)

      base = base_image()
      req = variation_request("dall-e-2", base)

      assert {:ok, _} = call(stub, req)
      assert_receive {:content_type, ct}, 500
      assert is_binary(ct)
      assert ct =~ "multipart/form-data"
      assert ct =~ "boundary="

      assert_receive {:raw_body, raw}, 500
      # The image field is present (multipart file part header).
      assert raw =~ ~s|name="image"|
      # No prompt field (variation drops prompt).
      refute raw =~ ~s|name="prompt"|
      # No mask field either.
      refute raw =~ ~s|name="mask"|

      assert_receive {:path, "/v1/images/variations"}, 500
    end
  end

  describe "prepare_request/2 :variation" do
    test "returns an unfired Req.Request with multipart body and variations URL" do
      base = base_image()
      req_struct = variation_request("dall-e-2", base)

      assert {:ok, %Req.Request{} = req} =
               Images.prepare_request(req_struct, api_key: "sk-prep")

      assert URI.parse(req.url).path == "/v1/images/variations"
      assert req.method == :post
      assert is_list(req.options[:form_multipart])
    end

    # Mirrors `images_multipart_test.exs:704` (the :edit variant) and
    # `images_test.exs:1477` (the :generate variant). Closes the
    # documented Decision #20 / Invariant 0 contract for the :image_script
    # + prepare_request/2 divergence on :variation — the script path has
    # no Req.Request analogue, so prepare_request/2 short-circuits to the
    # stub error rather than returning an unfired Req.Request.
    # Surfaced as overdue across 15.3/15.4/15.5 retros; landed here in
    # the 15.5 fix step.
    test "image_script + prepare_request/2 :variation returns the stub error (no Req.Request analogue)" do
      base = base_image()
      req = variation_request("dall-e-2", base)
      out = Image.from_binary(<<1>>, "image/png")
      opts = [api_key: "sk-prep", adapter_opts: [image_script: [{:ok, [out]}]]]

      assert {:error,
              %ImageAdapterError{reason: :unknown, message: "operation pending implementation"}} =
               Images.prepare_request(req, opts)
    end
  end

  # ---------------------------------------------------------------------------
  # Defensive: :variation + non-nil mask is a programmer error per spec
  # (variation has no mask). The field-applicability layer (`fields_for/2`)
  # is the gate — `fields_for(:variation, "dall-e-2")` does NOT include
  # `:mask`, so a hand-rolled `%ImageRequest{operation: :variation, mask: ...}`
  # silently has its mask dropped from the multipart body. This test asserts
  # that contract on the BUILT body so a future refactor that, e.g., switches
  # to a permissive "include all non-nil fields" strategy would fail loudly.
  # ---------------------------------------------------------------------------

  describe "to_multipart_body/2 — :variation defensive (mask omission)" do
    test ":variation request with non-nil mask omits name=\"mask\" from multipart body" do
      base = base_image()
      mask = Image.from_binary(tiny_png_bytes(), "image/png")

      # Build directly via struct%{} to bypass any future constructor
      # validation — the test's purpose is to assert the field-applicability
      # gate at `fields_for/2` even when the caller misuses the struct.
      req = %ImageRequest{
        operation: :variation,
        prompt: nil,
        model: "dall-e-2",
        input_images: [base],
        mask: mask,
        response_format: :base64
      }

      assert {:ok, fields} = Images.to_multipart_body(req, [])

      names = Enum.map(fields, fn {name, _value} -> name end)
      refute "mask" in names
      refute "prompt" in names
      assert "image" in names
    end
  end
end
