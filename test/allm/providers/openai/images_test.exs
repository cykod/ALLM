defmodule ALLM.Providers.OpenAI.ImagesTest do
  @moduledoc """
  Wire-shape tests for `ALLM.Providers.OpenAI.Images`.

  Phase 15.1 covered the pre-HTTP gating layer. Phase 15.2 extends this
  file with `Req.Test.stub`-driven HTTP fixture rows for the JSON
  `:generate` path (dall-e-2 / dall-e-3) plus the closed-enum error
  matrix mirroring `test/allm/providers/openai_wire_test.exs`.
  """

  use ExUnit.Case, async: true

  import ALLM.Providers.OpenAI.ImagesTestHelpers

  alias ALLM.Error.ImageAdapterError
  alias ALLM.{Image, ImageRequest, ImageResponse, ImageUsage}
  alias ALLM.Providers.OpenAI.Images

  @recorded_dir "test/fixtures/openai/images/recorded"
  @synthesized_dir "test/fixtures/openai/images/synthesized"

  setup ctx do
    stub = String.to_atom("openai_images_stub_#{System.unique_integer([:positive])}")
    {:ok, stub: stub, ctx: ctx}
  end

  defp call(stub, request, opts \\ []) do
    Images.generate(
      request,
      Keyword.merge(
        [api_key: "sk-images-test", retry: false],
        Keyword.merge(opts, adapter_opts: merge_adapter_opts(opts, plug: {Req.Test, stub}))
      )
    )
  end

  defp recorded(name), do: recorded(@recorded_dir, name)
  defp synthesized(name), do: synthesized(@synthesized_dir, name)

  # ---------------------------------------------------------------------------
  # supported_operations/0
  # ---------------------------------------------------------------------------

  describe "supported_operations/0" do
    test "returns the closed list [:generate, :edit, :variation]" do
      assert Images.supported_operations() == [:generate, :edit, :variation]
    end
  end

  # ---------------------------------------------------------------------------
  # endpoint_for/1
  # ---------------------------------------------------------------------------

  describe "endpoint_for/1" do
    test "returns the correct path for each operation" do
      assert Images.endpoint_for(:generate) == "/images/generations"
      assert Images.endpoint_for(:edit) == "/images/edits"
      assert Images.endpoint_for(:variation) == "/images/variations"
    end
  end

  # ---------------------------------------------------------------------------
  # gate_model_op/2 — table-driven coverage of @model_ops
  # ---------------------------------------------------------------------------

  describe "gate_model_op/2" do
    @legal_pairs [
      {"dall-e-2", :generate},
      {"dall-e-2", :edit},
      {"dall-e-2", :variation},
      {"dall-e-3", :generate},
      {"gpt-image-1", :generate},
      {"gpt-image-1", :edit}
    ]

    @illegal_pairs [
      {"dall-e-3", :edit},
      {"dall-e-3", :variation},
      {"gpt-image-1", :variation}
    ]

    for {model, op} <- @legal_pairs do
      test "#{inspect(model)} + #{inspect(op)} → :ok" do
        assert Images.gate_model_op(unquote(model), unquote(op)) == :ok
      end
    end

    for {model, op} <- @illegal_pairs do
      test "#{inspect(model)} + #{inspect(op)} → :unsupported_operation with metadata model + operation" do
        assert {:error, %ImageAdapterError{} = err} =
                 Images.gate_model_op(unquote(model), unquote(op))

        assert err.reason == :unsupported_operation
        assert err.metadata.model == unquote(model)
        assert err.metadata.operation == unquote(op)
        assert err.provider == :openai
      end
    end

    test "model: nil → :ok (passthrough; provider decides)" do
      assert Images.gate_model_op(nil, :generate) == :ok
      assert Images.gate_model_op(nil, :edit) == :ok
      assert Images.gate_model_op(nil, :variation) == :ok
    end

    test "unknown model string → :ok (passthrough; provider decides)" do
      assert Images.gate_model_op("dall-e-4-preview", :generate) == :ok
      assert Images.gate_model_op("dall-e-4-preview", :variation) == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # generate/2 — pre-HTTP gates (Invariant 1)
  # ---------------------------------------------------------------------------

  describe "generate/2 — operation gate" do
    test "operation: :foo (atom not in supported_operations) → :unsupported_operation" do
      req = %ImageRequest{operation: :foo, prompt: "x"}

      assert {:error, %ImageAdapterError{reason: :unsupported_operation} = err} =
               Images.generate(req, [])

      assert err.metadata.operation == :foo
      assert err.provider == :openai
    end
  end

  describe "generate/2 — model gate" do
    test "operation: :variation + model: dall-e-3 → :unsupported_operation with model + operation" do
      base = Image.from_binary(<<1>>, "image/png")

      req =
        ImageRequest.new(
          operation: :variation,
          prompt: nil,
          model: "dall-e-3",
          input_images: [base]
        )

      assert {:error, %ImageAdapterError{reason: :unsupported_operation} = err} =
               Images.generate(req, [])

      assert err.metadata.model == "dall-e-3"
      assert err.metadata.operation == :variation
    end

    test "operation: :edit + model: dall-e-3 → :unsupported_operation" do
      base = Image.from_binary(<<1>>, "image/png")

      req =
        ImageRequest.new(
          operation: :edit,
          prompt: "tweak",
          model: "dall-e-3",
          input_images: [base]
        )

      assert {:error, %ImageAdapterError{reason: :unsupported_operation} = err} =
               Images.generate(req, [])

      assert err.metadata.model == "dall-e-3"
      assert err.metadata.operation == :edit
    end

    test "operation: :variation + model: gpt-image-1 → :unsupported_operation" do
      base = Image.from_binary(<<1>>, "image/png")

      req =
        ImageRequest.new(
          operation: :variation,
          prompt: nil,
          model: "gpt-image-1",
          input_images: [base]
        )

      assert {:error, %ImageAdapterError{reason: :unsupported_operation} = err} =
               Images.generate(req, [])

      assert err.metadata.model == "gpt-image-1"
      assert err.metadata.operation == :variation
    end
  end

  describe "generate/2 — gpt-image-1 + :url rejection (Decision #6)" do
    test "model: gpt-image-1 + response_format: :url → :invalid_request with metadata" do
      req =
        ImageRequest.new(
          operation: :generate,
          prompt: "a kestrel",
          model: "gpt-image-1",
          response_format: :url
        )

      assert {:error, %ImageAdapterError{reason: :invalid_request} = err} =
               Images.generate(req, [])

      assert err.metadata.model == "gpt-image-1"
      assert err.metadata.response_format == :url

      assert err.message =~ "gpt-image-1"
      assert err.message =~ "base64"
    end
  end

  # ---------------------------------------------------------------------------
  # Invariant 3: opts[:request_id] is reflected on every error's metadata,
  # including pre-flight gate failures.
  # ---------------------------------------------------------------------------

  describe "generate/2 — opts[:request_id] reflection (Invariant 3)" do
    test "operation gate failure carries metadata[:request_id]" do
      req = %ImageRequest{operation: :foo, prompt: "x"}

      assert {:error, %ImageAdapterError{} = err} =
               Images.generate(req, request_id: "rid-op-gate")

      assert err.metadata.request_id == "rid-op-gate"
    end

    test "model gate failure carries metadata[:request_id]" do
      req = ImageRequest.new(operation: :variation, prompt: nil, model: "dall-e-3")

      assert {:error, %ImageAdapterError{} = err} =
               Images.generate(req, request_id: "rid-model-gate")

      assert err.metadata.request_id == "rid-model-gate"
      assert err.metadata.model == "dall-e-3"
      assert err.metadata.operation == :variation
    end

    test "gpt-image-1 + :url rejection carries metadata[:request_id]" do
      req =
        ImageRequest.new(
          operation: :generate,
          prompt: "x",
          model: "gpt-image-1",
          response_format: :url
        )

      assert {:error, %ImageAdapterError{} = err} =
               Images.generate(req, request_id: "rid-url-gate")

      assert err.metadata.request_id == "rid-url-gate"
      assert err.metadata.model == "gpt-image-1"
    end

    test "HTTP-error path carries metadata[:request_id]", %{stub: stub} do
      body = synthesized("auth_failed.json") |> drop_comment()
      Req.Test.stub(stub, fn conn -> respond_json(conn, 401, body) end)

      req = ImageRequest.new(operation: :generate, prompt: "x", model: "dall-e-2")

      assert {:error, %ImageAdapterError{reason: :authentication_failed} = err} =
               call(stub, req, request_id: "rid-http")

      assert err.metadata.request_id == "rid-http"
    end
  end

  # ---------------------------------------------------------------------------
  # Invariant 0: adapter_opts[:image_script] short-circuit (Decision #20)
  # ---------------------------------------------------------------------------

  describe "generate/2 — adapter_opts[:image_script] short-circuit (Decision #20)" do
    test "delegates to FakeImages and returns its {:ok, response}" do
      out = Image.from_binary(<<2, 3>>, "image/png")
      req = ImageRequest.new(operation: :generate, prompt: "x")
      opts = [adapter_opts: [image_script: [{:ok, [out]}]]]

      assert {:ok, %ImageResponse{images: [^out]}} = Images.generate(req, opts)
    end

    test "fires BEFORE pre-flight gates (an unsupported operation under :image_script does NOT hit the operation gate)" do
      out = Image.from_binary(<<1>>, "image/png")
      base = Image.from_binary(<<2>>, "image/png")

      req =
        ImageRequest.new(
          operation: :variation,
          prompt: nil,
          model: "dall-e-3",
          input_images: [base]
        )

      opts = [adapter_opts: [image_script: [{:ok, [out]}]]]

      assert {:ok, %ImageResponse{images: [^out]}} = Images.generate(req, opts)
    end

    test "preserves opts[:request_id] onto response.request_id via FakeImages delegation" do
      out = Image.from_binary(<<1>>, "image/png")
      req = ImageRequest.new(operation: :generate, prompt: "x")

      opts = [
        adapter_opts: [image_script: [{:ok, [out]}]],
        request_id: "rid-script"
      ]

      assert {:ok, %ImageResponse{request_id: "rid-script"}} = Images.generate(req, opts)
    end

    test "round-trips request.metadata via FakeImages delegation" do
      out = Image.from_binary(<<1>>, "image/png")
      metadata = %{trace_id: "abc"}
      req = ImageRequest.new(operation: :generate, prompt: "x", metadata: metadata)
      opts = [adapter_opts: [image_script: [{:ok, [out]}]]]

      assert {:ok, %ImageResponse{metadata: ^metadata}} = Images.generate(req, opts)
    end

    test "{:error, %ImageAdapterError{}} script entries pass through verbatim" do
      err = ImageAdapterError.new(:rate_limited, retry_after_ms: 1000)
      req = ImageRequest.new(operation: :generate, prompt: "x")
      opts = [adapter_opts: [image_script: [{:error, err}]]]

      assert {:error, ^err} = Images.generate(req, opts)
    end
  end

  # ---------------------------------------------------------------------------
  # generate/2 — Phase 15.2 wire-shape happy paths (recorded fixtures)
  # ---------------------------------------------------------------------------

  describe "generate/2 — wire happy paths" do
    test "dall-e-2 :base64 happy path → {:ok, %ImageResponse{}} with {:base64, _} source", %{
      stub: stub
    } do
      body = recorded("generate_dall_e_2_happy.json") |> drop_comment()
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body) end)

      req =
        ImageRequest.new(
          operation: :generate,
          prompt: "a kestrel",
          model: "dall-e-2",
          response_format: :base64,
          size: {256, 256}
        )

      assert {:ok, %ImageResponse{} = resp} = call(stub, req)
      assert [%Image{source: {:base64, b64}, mime_type: "image/png"}] = resp.images
      assert is_binary(b64) and b64 != ""
      assert resp.usage.images == 1
      assert resp.model == "dall-e-2"
    end

    test "dall-e-2 :binary happy path → bytes are Base64-decoded", %{stub: stub} do
      body = recorded("generate_dall_e_2_happy.json") |> drop_comment()
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body) end)

      req =
        ImageRequest.new(
          operation: :generate,
          prompt: "a kestrel",
          model: "dall-e-2",
          response_format: :binary,
          size: {256, 256}
        )

      assert {:ok, %ImageResponse{} = resp} = call(stub, req)
      assert [%Image{source: {:binary, bytes}, mime_type: "image/png"}] = resp.images

      # PNG signature - first 8 bytes are 137 80 78 71 13 10 26 10
      assert <<137, 80, 78, 71, _::binary>> = bytes
    end

    test "dall-e-2 :url happy path → response carries {:url, url}", %{stub: stub} do
      body = recorded("generate_dall_e_2_url_happy.json") |> drop_comment()
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body) end)

      req =
        ImageRequest.new(
          operation: :generate,
          prompt: "a kestrel",
          model: "dall-e-2",
          response_format: :url,
          size: {256, 256}
        )

      assert {:ok, %ImageResponse{images: [%Image{source: {:url, url}}]}} = call(stub, req)
      assert is_binary(url)
      assert String.starts_with?(url, "https://")
    end

    test "dall-e-3 happy path → revised_prompt populated and usage.images == 1", %{stub: stub} do
      body = recorded("generate_dall_e_3_happy.json") |> drop_comment()
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body) end)

      req =
        ImageRequest.new(
          operation: :generate,
          prompt: "a kestrel",
          model: "dall-e-3",
          response_format: :base64,
          size: {1024, 1024},
          quality: :hd,
          style: :vivid
        )

      assert {:ok, %ImageResponse{} = resp} = call(stub, req)
      assert [%Image{revised_prompt: rp}] = resp.images
      assert is_binary(rp) and rp != ""
      assert resp.usage.images == 1
    end

    test "multi-image batch (n: 4) → response.images has 4 entries, usage.images == 4", %{
      stub: stub
    } do
      body = recorded("generate_dall_e_2_n4_happy.json") |> drop_comment()
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body) end)

      req =
        ImageRequest.new(
          operation: :generate,
          prompt: "kestrel variations",
          model: "dall-e-2",
          response_format: :base64,
          size: {256, 256},
          n: 4
        )

      assert {:ok, %ImageResponse{images: images, usage: %ImageUsage{images: 4}}} =
               call(stub, req)

      assert length(images) == 4
    end
  end

  # ---------------------------------------------------------------------------
  # generate/2 — Phase 15.2 wire-shape error paths (synthesized fixtures)
  # ---------------------------------------------------------------------------

  describe "generate/2 — wire error paths" do
    setup ctx do
      req =
        ImageRequest.new(
          operation: :generate,
          prompt: "x",
          model: "dall-e-2",
          response_format: :base64
        )

      Map.put(ctx, :req, req)
    end

    test "401 → :authentication_failed with status populated", %{stub: stub, req: req} do
      body = synthesized("auth_failed.json") |> drop_comment()
      Req.Test.stub(stub, fn conn -> respond_json(conn, 401, body) end)

      assert {:error, %ImageAdapterError{} = err} = call(stub, req)
      assert err.reason == :authentication_failed
      assert err.status == 401
      assert err.provider == :openai
      assert err.message =~ "API key"
    end

    test "429 → :rate_limited with retry_after_ms parsed", %{stub: stub, req: req} do
      body = synthesized("rate_limited.json") |> drop_comment()
      Req.Test.stub(stub, fn conn -> respond_with(conn, 429, body, [{"retry-after", "1"}]) end)

      assert {:error, %ImageAdapterError{} = err} = call(stub, req)
      assert err.reason == :rate_limited
      assert err.status == 429
      assert err.retry_after_ms == 1_000
    end

    test "429 + Retry-After: 1 — under retry, second call against happy stub succeeds" do
      # Two-call scenario: first call returns 429 with Retry-After, second
      # call returns the happy fixture. Use a shared counter agent and a
      # fresh stub atom; max_attempts: 2 with base_delay_ms: 1 so the
      # retry is fast. retry_on must include 429 (default).
      stub = String.to_atom("openai_images_retry_#{System.unique_integer([:positive])}")

      {:ok, agent} = Agent.start_link(fn -> 0 end)
      err_body = synthesized("rate_limited.json") |> drop_comment()
      ok_body = recorded("generate_dall_e_2_happy.json") |> drop_comment()

      Req.Test.stub(stub, fn conn ->
        n = Agent.get_and_update(agent, &{&1 + 1, &1 + 1})

        if n == 1 do
          respond_with(conn, 429, err_body, [{"retry-after", "0"}])
        else
          respond_json(conn, 200, ok_body)
        end
      end)

      req =
        ImageRequest.new(
          operation: :generate,
          prompt: "x",
          model: "dall-e-2",
          response_format: :base64
        )

      # Adapter-direct call uses the materialized retry policy verbatim;
      # the image-side retry_on augmentation lives in the façade per
      # PHASE 14 Decision #9. We supply retry_on with the image atom set
      # directly so the closed-enum atom matches.
      assert {:ok, %ImageResponse{}} =
               Images.generate(req,
                 api_key: "sk-images-test",
                 retry: [
                   max_attempts: 2,
                   base_delay_ms: 1,
                   jitter_ms: 0,
                   retry_on: [:rate_limited, :provider_unavailable, :timeout, :network_error]
                 ],
                 adapter_opts: [plug: {Req.Test, stub}]
               )

      Agent.stop(agent)
    end

    test "500 → :provider_unavailable", %{stub: stub, req: req} do
      body = synthesized("server_error.json") |> drop_comment()
      Req.Test.stub(stub, fn conn -> respond_json(conn, 500, body) end)

      assert {:error, %ImageAdapterError{reason: :provider_unavailable, status: 500}} =
               call(stub, req)
    end

    test "400 (generic) → :invalid_request", %{stub: stub, req: req} do
      body = synthesized("invalid_request.json") |> drop_comment()
      Req.Test.stub(stub, fn conn -> respond_json(conn, 400, body) end)

      assert {:error, %ImageAdapterError{reason: :invalid_request, status: 400} = err} =
               call(stub, req)

      assert err.message =~ "size"
    end

    test "400 with code: content_policy_violation → :content_filter", %{stub: stub, req: req} do
      body = synthesized("content_filter.json") |> drop_comment()
      Req.Test.stub(stub, fn conn -> respond_json(conn, 400, body) end)

      assert {:error, %ImageAdapterError{reason: :content_filter, status: 400}} = call(stub, req)
    end

    test "200 with empty data: [] → :content_filter (Decision #5b)", %{stub: stub, req: req} do
      body = synthesized("content_filter_empty_data.json") |> drop_comment()
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body) end)

      assert {:error, %ImageAdapterError{reason: :content_filter} = err} = call(stub, req)
      assert err.message =~ "no images"
    end

    test "200 with malformed body (missing :data) → :malformed_response", %{stub: stub, req: req} do
      body = synthesized("malformed.json") |> drop_comment()
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body) end)

      assert {:error, %ImageAdapterError{reason: :malformed_response} = err} = call(stub, req)
      assert err.metadata[:body_preview]
    end

    test "403 → :authentication_failed", %{stub: stub, req: req} do
      body = synthesized("auth_failed.json") |> drop_comment()
      Req.Test.stub(stub, fn conn -> respond_json(conn, 403, body) end)

      assert {:error, %ImageAdapterError{reason: :authentication_failed, status: 403}} =
               call(stub, req)
    end

    test "418 (unmapped status) → :unknown", %{stub: stub, req: req} do
      Req.Test.stub(stub, fn conn ->
        respond_json(conn, 418, %{"error" => %{"message" => "tea"}})
      end)

      assert {:error, %ImageAdapterError{reason: :unknown, status: 418}} = call(stub, req)
    end

    test "400 with type containing content_filter → :content_filter", %{stub: stub, req: req} do
      body = %{"error" => %{"message" => "filtered", "type" => "content_filter_violation"}}
      Req.Test.stub(stub, fn conn -> respond_json(conn, 400, body) end)

      assert {:error, %ImageAdapterError{reason: :content_filter, status: 400}} = call(stub, req)
    end

    test "200 carrying x-request-id header populates response.metadata[:openai_request_id]",
         %{stub: stub} do
      ok_body = recorded("generate_dall_e_2_happy.json") |> drop_comment()

      Req.Test.stub(stub, fn conn ->
        respond_with(conn, 200, ok_body, [{"x-request-id", "rid-from-openai"}])
      end)

      req =
        ImageRequest.new(
          operation: :generate,
          prompt: "x",
          model: "dall-e-2",
          response_format: :base64
        )

      assert {:ok, %ImageResponse{metadata: meta}} = call(stub, req)
      assert meta[:openai_request_id] == "rid-from-openai"
    end

    test ":binary caller + invalid base64 b64_json → :malformed_response", %{stub: stub} do
      bad_body = %{"created" => 1, "data" => [%{"b64_json" => "not-valid-base64!!!"}]}
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, bad_body) end)

      req =
        ImageRequest.new(
          operation: :generate,
          prompt: "x",
          model: "dall-e-2",
          response_format: :binary
        )

      assert {:error, %ImageAdapterError{reason: :malformed_response}} = call(stub, req)
    end

    test "data entry missing both :url and :b64_json → :malformed_response", %{stub: stub, req: req} do
      bad_body = %{"created" => 1, "data" => [%{"unexpected" => "field"}]}
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, bad_body) end)

      assert {:error, %ImageAdapterError{reason: :malformed_response}} = call(stub, req)
    end

    test "request_timeout opt is honored (Req.merge plumbing)", %{stub: stub} do
      ok_body = recorded("generate_dall_e_2_happy.json") |> drop_comment()
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, ok_body) end)

      req =
        ImageRequest.new(
          operation: :generate,
          prompt: "x",
          model: "dall-e-2",
          response_format: :base64
        )

      # Just confirms the option is accepted without crashing — Req.Test
      # doesn't actually time out, so the response is the happy fixture.
      assert {:ok, %ImageResponse{}} = call(stub, req, request_timeout: 60_000)
    end
  end

  # ---------------------------------------------------------------------------
  # to_size_string/1 — coverage of all four branches
  # ---------------------------------------------------------------------------

  describe "to_size_string/1" do
    test "tuple → \"WxH\"" do
      assert Images.to_size_string({1024, 768}) == "1024x768"
    end

    test ":auto → \"auto\"" do
      assert Images.to_size_string(:auto) == "auto"
    end

    test "binary passthrough" do
      assert Images.to_size_string("256x256") == "256x256"
    end

    test "nil → nil (omit)" do
      assert Images.to_size_string(nil) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # to_json_body/2 — covers the body-builder branches not exercised by wire tests
  # ---------------------------------------------------------------------------

  describe "to_json_body/2 — branch coverage" do
    test "omits :prompt when request.prompt is nil" do
      req = %ImageRequest{operation: :generate, prompt: nil, model: "dall-e-2"}
      body = Images.to_json_body(req, [])
      refute Map.has_key?(body, "prompt")
    end

    test "omits :size when request.size is nil" do
      req = ImageRequest.new(operation: :generate, prompt: "x", model: "dall-e-2")
      body = Images.to_json_body(req, [])
      refute Map.has_key?(body, "size")
    end

    test "omits response_format when :response_format is unknown atom" do
      # Bypass ImageRequest.new/1 (closed enum) by constructing the struct
      # literally with an out-of-set value.
      req = %ImageRequest{
        operation: :generate,
        prompt: "x",
        model: "dall-e-2",
        response_format: :weird
      }

      body = Images.to_json_body(req, [])
      refute Map.has_key?(body, "response_format")
    end

    test "encodes :auto size" do
      req = ImageRequest.new(operation: :generate, prompt: "x", model: "dall-e-2", size: :auto)
      body = Images.to_json_body(req, [])
      assert body["size"] == "auto"
    end

    test "passes through string :quality verbatim" do
      req =
        ImageRequest.new(
          operation: :generate,
          prompt: "x",
          model: "dall-e-3",
          quality: "experimental"
        )

      body = Images.to_json_body(req, [])
      assert body["quality"] == "experimental"
    end

    test "ignores :user when options[:user] is non-binary" do
      req =
        ImageRequest.new(
          operation: :generate,
          prompt: "x",
          model: "dall-e-2",
          options: %{user: 42}
        )

      body = Images.to_json_body(req, [])
      refute Map.has_key?(body, "user")
    end

    test "ignores :user when options is not a map (defensive)" do
      # `request.options` is documented as `map()` but the put_user helper
      # has a defensive `defp put_user(map, _)` clause for non-map values.
      req = %ImageRequest{operation: :generate, prompt: "x", model: "dall-e-2", options: nil}
      body = Images.to_json_body(req, [])
      refute Map.has_key?(body, "user")
    end
  end

  # ---------------------------------------------------------------------------
  # generate/2 — Phase 15.3: gpt-image-1 (forced base64 + token usage)
  # ---------------------------------------------------------------------------

  describe "generate/2 — gpt-image-1 happy paths" do
    test ":binary caller force-decodes b64_json into {:binary, bytes}", %{stub: stub} do
      body = recorded("generate_gpt_image_1_happy.json") |> drop_comment()
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body) end)

      req =
        ImageRequest.new(
          operation: :generate,
          prompt: "a kestrel",
          model: "gpt-image-1",
          response_format: :binary,
          size: {1024, 1024}
        )

      assert {:ok, %ImageResponse{} = resp} = call(stub, req)
      [%Image{source: {:binary, bytes}, mime_type: "image/png"}] = resp.images
      [first | _] = body["data"]
      assert bytes == Base.decode64!(first["b64_json"])
    end

    test ":base64 caller forwards b64_json verbatim (no decode)", %{stub: stub} do
      body = recorded("generate_gpt_image_1_happy.json") |> drop_comment()
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body) end)

      req =
        ImageRequest.new(
          operation: :generate,
          prompt: "a kestrel",
          model: "gpt-image-1",
          response_format: :base64,
          size: {1024, 1024}
        )

      assert {:ok, %ImageResponse{} = resp} = call(stub, req)
      [%Image{source: {:base64, b64}, mime_type: "image/png"}] = resp.images
      [first | _] = body["data"]
      assert b64 == first["b64_json"]
    end

    test ":url caller is rejected BEFORE HTTP per Decision #6 (sanity-test 15.1 gate)" do
      req =
        ImageRequest.new(
          operation: :generate,
          prompt: "x",
          model: "gpt-image-1",
          response_format: :url
        )

      assert {:error, %ImageAdapterError{reason: :invalid_request} = err} =
               Images.generate(req, [])

      assert err.metadata.model == "gpt-image-1"
      assert err.metadata.response_format == :url
    end

    test "request body OMITS response_format (sanity-test 15.2 wiring)", %{stub: stub} do
      parent = self()
      body = recorded("generate_gpt_image_1_happy.json") |> drop_comment()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:body, Jason.decode!(raw)})
        respond_json(conn, 200, body)
      end)

      req =
        ImageRequest.new(
          operation: :generate,
          prompt: "x",
          model: "gpt-image-1",
          response_format: :base64
        )

      assert {:ok, _} = call(stub, req)
      assert_receive {:body, sent}, 500
      refute Map.has_key?(sent, "response_format")
    end

    test "populates usage.input_tokens / output_tokens / images", %{stub: stub} do
      body = recorded("generate_gpt_image_1_happy.json") |> drop_comment()
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body) end)

      req =
        ImageRequest.new(
          operation: :generate,
          prompt: "a kestrel",
          model: "gpt-image-1",
          response_format: :base64
        )

      assert {:ok, %ImageResponse{usage: %ImageUsage{} = usage}} = call(stub, req)

      assert usage.images == 1
      assert usage.input_tokens == body["usage"]["input_tokens"]
      assert usage.output_tokens == body["usage"]["output_tokens"]
      assert is_integer(usage.input_tokens) and usage.input_tokens > 0
      assert is_integer(usage.output_tokens) and usage.output_tokens > 0
    end

    test "options[:output_format] = \"webp\" → response.images[0].mime_type == \"image/webp\"",
         %{stub: stub} do
      body = recorded("generate_gpt_image_1_happy.json") |> drop_comment()
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body) end)

      req =
        ImageRequest.new(
          operation: :generate,
          prompt: "x",
          model: "gpt-image-1",
          response_format: :base64,
          options: %{output_format: "webp"}
        )

      assert {:ok, %ImageResponse{images: [%Image{mime_type: "image/webp"}]}} = call(stub, req)
    end

    test "options[:output_format] = \"jpeg\" → response.images[0].mime_type == \"image/jpeg\"",
         %{stub: stub} do
      body = recorded("generate_gpt_image_1_happy.json") |> drop_comment()
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body) end)

      req =
        ImageRequest.new(
          operation: :generate,
          prompt: "x",
          model: "gpt-image-1",
          response_format: :base64,
          options: %{output_format: "jpeg"}
        )

      assert {:ok, %ImageResponse{images: [%Image{mime_type: "image/jpeg"}]}} = call(stub, req)
    end

    test "options[:output_format] absent → response.images[0].mime_type defaults to \"image/png\"",
         %{stub: stub} do
      body = recorded("generate_gpt_image_1_happy.json") |> drop_comment()
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body) end)

      req =
        ImageRequest.new(
          operation: :generate,
          prompt: "x",
          model: "gpt-image-1",
          response_format: :base64
        )

      assert {:ok, %ImageResponse{images: [%Image{mime_type: "image/png"}]}} = call(stub, req)
    end

    test "populates response.metadata[:usage_details] when input_tokens_details is present",
         %{stub: stub} do
      body = recorded("generate_gpt_image_1_happy.json") |> drop_comment()
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body) end)

      req =
        ImageRequest.new(
          operation: :generate,
          prompt: "x",
          model: "gpt-image-1",
          response_format: :base64
        )

      assert {:ok, %ImageResponse{metadata: meta}} = call(stub, req)

      details = meta[:usage_details]
      assert is_map(details)
      # Round-trip the exact wire shape — keys are strings on the JSON path.
      assert details["text_tokens"] == body["usage"]["input_tokens_details"]["text_tokens"]
      assert details["image_tokens"] == body["usage"]["input_tokens_details"]["image_tokens"]
    end

    test "does NOT overwrite caller-supplied :usage_details on request.metadata", %{stub: stub} do
      body = recorded("generate_gpt_image_1_happy.json") |> drop_comment()
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body) end)

      caller_meta = %{usage_details: %{caller: "supplied"}}

      req =
        ImageRequest.new(
          operation: :generate,
          prompt: "x",
          model: "gpt-image-1",
          response_format: :base64,
          metadata: caller_meta
        )

      assert {:ok, %ImageResponse{metadata: meta}} = call(stub, req)
      # Caller key wins (Map.put_new semantics — Invariant 4).
      assert meta[:usage_details] == %{caller: "supplied"}
    end
  end

  describe "generate/2 — gpt-image-1 request shape (Phase 15.3)" do
    test "body INCLUDES quality, background, output_format when supplied", %{stub: stub} do
      parent = self()
      body = recorded("generate_gpt_image_1_happy.json") |> drop_comment()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:body, Jason.decode!(raw)})
        respond_json(conn, 200, body)
      end)

      req =
        ImageRequest.new(
          operation: :generate,
          prompt: "kestrel",
          model: "gpt-image-1",
          response_format: :base64,
          size: {1024, 1024},
          quality: :high,
          background: :transparent,
          options: %{output_format: "webp"}
        )

      assert {:ok, _} = call(stub, req)
      assert_receive {:body, sent}, 500
      assert sent["model"] == "gpt-image-1"
      assert sent["quality"] == "high"
      assert sent["background"] == "transparent"
      assert sent["output_format"] == "webp"
      refute Map.has_key?(sent, "response_format")
    end

    test "body OMITS output_format when request.options[:output_format] is absent", %{
      stub: stub
    } do
      parent = self()
      body = recorded("generate_gpt_image_1_happy.json") |> drop_comment()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:body, Jason.decode!(raw)})
        respond_json(conn, 200, body)
      end)

      req =
        ImageRequest.new(
          operation: :generate,
          prompt: "x",
          model: "gpt-image-1",
          response_format: :base64
        )

      assert {:ok, _} = call(stub, req)
      assert_receive {:body, sent}, 500
      refute Map.has_key?(sent, "output_format")
    end

    test "background field is gpt-image-1-only — dall-e-2 OMITS even when supplied" do
      # Direct unit test on `to_json_body/2` — dall-e-2 must not carry
      # `background` even when the struct field is set.
      req =
        ImageRequest.new(
          operation: :generate,
          prompt: "x",
          model: "dall-e-2",
          background: :transparent
        )

      sent = Images.to_json_body(req, [])
      refute Map.has_key?(sent, "background")
    end

    test "atom :output_format value (atom shape) wires to its string equivalent" do
      req =
        ImageRequest.new(
          operation: :generate,
          prompt: "x",
          model: "gpt-image-1",
          options: %{output_format: :webp}
        )

      sent = Images.to_json_body(req, [])
      assert sent["output_format"] == "webp"
    end
  end

  describe "prepare_request/2 — gpt-image-1 (Phase 15.3)" do
    test "returns Req.Request whose body OMITS response_format and INCLUDES gpt-image-1 fields" do
      req =
        ImageRequest.new(
          operation: :generate,
          prompt: "kestrel",
          model: "gpt-image-1",
          response_format: :base64,
          size: {1024, 1024},
          quality: :low,
          background: :opaque,
          options: %{output_format: "png"}
        )

      assert {:ok, %Req.Request{} = http} =
               Images.prepare_request(req, api_key: "sk-prep")

      body = http.options.json
      assert body["model"] == "gpt-image-1"
      assert body["quality"] == "low"
      assert body["background"] == "opaque"
      assert body["output_format"] == "png"
      refute Map.has_key?(body, "response_format")
      assert http.url.path == "/v1/images/generations"
    end
  end

  describe "mime_type_for_output_format/1" do
    test "maps known atom and string output_format values" do
      assert Images.mime_type_for_output_format(:png) == "image/png"
      assert Images.mime_type_for_output_format(:jpeg) == "image/jpeg"
      assert Images.mime_type_for_output_format(:jpg) == "image/jpeg"
      assert Images.mime_type_for_output_format(:webp) == "image/webp"
      assert Images.mime_type_for_output_format("png") == "image/png"
      assert Images.mime_type_for_output_format("PNG") == "image/png"
      assert Images.mime_type_for_output_format("jpeg") == "image/jpeg"
      assert Images.mime_type_for_output_format("jpg") == "image/jpeg"
      assert Images.mime_type_for_output_format("webp") == "image/webp"
      assert Images.mime_type_for_output_format("WebP") == "image/webp"
    end

    test "nil and unknown values default to image/png" do
      assert Images.mime_type_for_output_format(nil) == "image/png"
      assert Images.mime_type_for_output_format("avif") == "image/png"
      assert Images.mime_type_for_output_format(:gif) == "image/png"
      assert Images.mime_type_for_output_format(42) == "image/png"
    end
  end

  describe "generate/2 — gpt-image-1 missing usage in body (defensive)" do
    test "returns ImageUsage with image-count only when body.usage is absent", %{stub: stub} do
      # gpt-image-1 spec says usage is always present, but cover the
      # defensive code path that drops back to image-count when usage is
      # missing from the body.
      body = %{"created" => 1, "data" => [%{"b64_json" => Base.encode64(<<1, 2, 3>>)}]}
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body) end)

      req =
        ImageRequest.new(
          operation: :generate,
          prompt: "x",
          model: "gpt-image-1",
          response_format: :base64
        )

      assert {:ok, %ImageResponse{usage: %ImageUsage{} = usage}} = call(stub, req)
      assert usage.images == 1
      assert usage.input_tokens == nil
      assert usage.output_tokens == nil
    end
  end

  # ---------------------------------------------------------------------------
  # generate/2 — :variation routes through the multipart HTTP path (Phase 15.5)
  # ---------------------------------------------------------------------------

  describe "generate/2 — :variation routes through multipart HTTP path (Phase 15.5)" do
    # `:edit` was wired in Phase 15.4 and `:variation` in Phase 15.5 —
    # both flow through the same multipart machinery. Wire-shape tests
    # for both ops live in `images_multipart_test.exs`; this test
    # confirms the post-gate path actually reaches HTTP dispatch (not
    # the prior pending-implementation stub).
    test ":variation + dall-e-2 (legal model gate) flows through the multipart HTTP path (Phase 15.5)" do
      # Phase 15.5 wired :variation through the same multipart machinery
      # as :edit. Stub Req.Test to confirm the path actually reaches HTTP
      # dispatch rather than returning `:unknown` / "pending implementation"
      # pre-flight as the 15.4 stub did. The stub responds 200 with the
      # variation fixture's JSON envelope.
      stub = String.to_atom("openai_images_variation_routed_#{System.unique_integer([:positive])}")

      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "created" => 1,
            "data" => [%{"b64_json" => Base.encode64(<<1, 2, 3>>)}]
          })
        )
      end)

      base = Image.from_binary(<<1>>, "image/png")

      req =
        ImageRequest.new(
          operation: :variation,
          prompt: nil,
          model: "dall-e-2",
          input_images: [base]
        )

      assert {:ok, %ALLM.ImageResponse{}} =
               Images.generate(req,
                 api_key: "sk-test",
                 retry: false,
                 adapter_opts: [plug: {Req.Test, stub}]
               )
    end
  end

  # ---------------------------------------------------------------------------
  # to_image_adapter_error/4 — direct unit tests for the closed-enum table
  # ---------------------------------------------------------------------------

  describe "to_image_adapter_error/4 (direct)" do
    test "401 → :authentication_failed" do
      err = Images.to_image_adapter_error(401, %{"error" => %{"message" => "x"}}, [], [])
      assert err.reason == :authentication_failed
      assert err.status == 401
    end

    test "429 with list-form retry-after parses" do
      headers = [{"Retry-After", "5"}]
      err = Images.to_image_adapter_error(429, %{"error" => %{"message" => "x"}}, headers, [])
      assert err.reason == :rate_limited
      assert err.retry_after_ms == 5_000
    end

    test "429 with malformed retry-after value returns nil retry_after_ms" do
      headers = [{"retry-after", "not-a-number"}]
      err = Images.to_image_adapter_error(429, %{"error" => %{"message" => "x"}}, headers, [])
      assert err.reason == :rate_limited
      assert err.retry_after_ms == nil
    end

    test "503 → :provider_unavailable" do
      err = Images.to_image_adapter_error(503, %{}, [], [])
      assert err.reason == :provider_unavailable
      assert err.status == 503
    end

    test "non-string Retry-After value gracefully returns nil" do
      headers = [{"retry-after", 5}]
      err = Images.to_image_adapter_error(429, %{}, headers, [])
      assert err.retry_after_ms == nil
    end

    test "headers as map honor x-request-id lookup" do
      # exercise header_value/2 map-form clause (production Req returns a map)
      headers = %{"retry-after" => ["3"]}
      err = Images.to_image_adapter_error(429, %{}, headers, [])
      assert err.retry_after_ms == 3_000
    end
  end

  # ---------------------------------------------------------------------------
  # generate/2 — request-shape (assert on body sent to the stub)
  # ---------------------------------------------------------------------------

  describe "generate/2 — request shape" do
    test "dall-e-2 sends {model, prompt, n, size, response_format}", %{stub: stub} do
      parent = self()
      ok_body = recorded("generate_dall_e_2_happy.json") |> drop_comment()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:body, Jason.decode!(raw)})
        respond_json(conn, 200, ok_body)
      end)

      req =
        ImageRequest.new(
          operation: :generate,
          prompt: "a kestrel",
          model: "dall-e-2",
          response_format: :base64,
          size: {256, 256},
          n: 1
        )

      assert {:ok, _} = call(stub, req)
      assert_receive {:body, body}, 500
      assert body["model"] == "dall-e-2"
      assert body["prompt"] == "a kestrel"
      assert body["n"] == 1
      assert body["size"] == "256x256"
      assert body["response_format"] == "b64_json"
    end

    test "dall-e-3 sends quality + style fields when populated", %{stub: stub} do
      parent = self()
      ok_body = recorded("generate_dall_e_3_happy.json") |> drop_comment()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:body, Jason.decode!(raw)})
        respond_json(conn, 200, ok_body)
      end)

      req =
        ImageRequest.new(
          operation: :generate,
          prompt: "a kestrel",
          model: "dall-e-3",
          response_format: :base64,
          size: {1024, 1024},
          quality: :hd,
          style: :vivid
        )

      assert {:ok, _} = call(stub, req)
      assert_receive {:body, body}, 500
      assert body["quality"] == "hd"
      assert body["style"] == "vivid"
      assert body["size"] == "1024x1024"
    end

    test "sends user field when request.options[:user] is set", %{stub: stub} do
      parent = self()
      ok_body = recorded("generate_dall_e_2_happy.json") |> drop_comment()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:body, Jason.decode!(raw)})
        respond_json(conn, 200, ok_body)
      end)

      req =
        ImageRequest.new(
          operation: :generate,
          prompt: "x",
          model: "dall-e-2",
          response_format: :base64,
          options: %{user: "user-42"}
        )

      assert {:ok, _} = call(stub, req)
      assert_receive {:body, body}, 500
      assert body["user"] == "user-42"
    end

    test "Authorization is `Bearer <api_key>` from ALLM.Keys.fetch!", %{stub: stub} do
      parent = self()
      ok_body = recorded("generate_dall_e_2_happy.json") |> drop_comment()

      Req.Test.stub(stub, fn conn ->
        send(parent, {:headers, conn.req_headers})
        respond_json(conn, 200, ok_body)
      end)

      req =
        ImageRequest.new(
          operation: :generate,
          prompt: "x",
          model: "dall-e-2",
          response_format: :base64
        )

      assert {:ok, _} = call(stub, req, api_key: "sk-from-opts")
      assert_receive {:headers, headers}, 500
      assert {"authorization", "Bearer sk-from-opts"} in headers
    end

    test "openai-organization header is set when adapter_opts[:organization] supplied", %{
      stub: stub
    } do
      parent = self()
      ok_body = recorded("generate_dall_e_2_happy.json") |> drop_comment()

      Req.Test.stub(stub, fn conn ->
        send(parent, {:headers, conn.req_headers})
        respond_json(conn, 200, ok_body)
      end)

      req =
        ImageRequest.new(
          operation: :generate,
          prompt: "x",
          model: "dall-e-2",
          response_format: :base64
        )

      assert {:ok, _} =
               Images.generate(req,
                 api_key: "sk-images-test",
                 retry: false,
                 adapter_opts: [plug: {Req.Test, stub}, organization: "org-abc"]
               )

      assert_receive {:headers, headers}, 500
      assert {"openai-organization", "org-abc"} in headers
    end

    test "gpt-image-1 OMITS response_format from the body", %{stub: stub} do
      parent = self()
      ok_body = recorded("generate_dall_e_2_happy.json") |> drop_comment()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:body, Jason.decode!(raw)})
        respond_json(conn, 200, ok_body)
      end)

      req =
        ImageRequest.new(
          operation: :generate,
          prompt: "x",
          model: "gpt-image-1",
          response_format: :base64
        )

      assert {:ok, _} = call(stub, req)
      assert_receive {:body, body}, 500
      refute Map.has_key?(body, "response_format")
    end
  end

  # ---------------------------------------------------------------------------
  # generate/2 — telemetry sanity-check (façade-side)
  # ---------------------------------------------------------------------------

  @doc false
  def __forward_telemetry__(event, _measurements, meta, %{parent: parent, ref: ref}) do
    send(parent, {ref, event, meta})
    :ok
  end

  describe "telemetry — façade emits :start/:stop on generate_image/3" do
    test "ALLM.generate_image/3 emits [:allm, :image, :start | :stop] with request_id" do
      stub = String.to_atom("openai_images_tel_#{System.unique_integer([:positive])}")

      ok_body = recorded("generate_dall_e_2_happy.json") |> drop_comment()
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, ok_body) end)

      parent = self()
      ref = make_ref()

      :telemetry.attach_many(
        "test-images-#{inspect(ref)}",
        [[:allm, :image, :start], [:allm, :image, :stop]],
        &__MODULE__.__forward_telemetry__/4,
        %{parent: parent, ref: ref}
      )

      engine =
        ALLM.Engine.new(
          image_adapter: ALLM.Providers.OpenAI.Images,
          model: "dall-e-2",
          adapter_opts: [plug: {Req.Test, stub}],
          retry: false
        )

      # Per spec §6.4 keys never live on the engine; populate via the
      # in-process Keys.Store for the duration of this test.
      ALLM.Keys.put(:openai, "sk-tel-test")

      try do
        assert {:ok, %ImageResponse{}} = ALLM.generate_image(engine, "kestrel")

        assert_receive {^ref, [:allm, :image, :start], %{}}, 500
        assert_receive {^ref, [:allm, :image, :stop], %{}}, 500
      after
        ALLM.Keys.delete(:openai)
        :telemetry.detach("test-images-#{inspect(ref)}")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # prepare_request/2 — Phase 15.2: builds an unfired Req.Request for :generate
  # ---------------------------------------------------------------------------

  describe "prepare_request/2" do
    test "happy path returns an unfired Req.Request with correct URL + body + auth header" do
      req =
        ImageRequest.new(
          operation: :generate,
          prompt: "a kestrel",
          model: "dall-e-2",
          response_format: :base64,
          size: {256, 256}
        )

      assert {:ok, %Req.Request{} = http} =
               Images.prepare_request(req, api_key: "sk-prep")

      assert http.url.path == "/v1/images/generations"
      assert http.method == :post

      auth = Req.Request.get_header(http, "authorization")
      assert auth == ["Bearer sk-prep"]

      # The :json field is set to the unencoded body map.
      body = http.options.json
      assert body["model"] == "dall-e-2"
      assert body["prompt"] == "a kestrel"
      assert body["size"] == "256x256"
      assert body["response_format"] == "b64_json"
    end

    test "operation-gate failure surfaces from prepare_request/2 too" do
      req = %ImageRequest{operation: :foo, prompt: "x"}

      assert {:error, %ImageAdapterError{reason: :unsupported_operation} = err} =
               Images.prepare_request(req, [])

      assert err.metadata.operation == :foo
    end

    test "model-gate failure surfaces from prepare_request/2 too" do
      req = ImageRequest.new(operation: :variation, prompt: nil, model: "dall-e-3")

      assert {:error, %ImageAdapterError{reason: :unsupported_operation} = err} =
               Images.prepare_request(req, [])

      assert err.metadata.model == "dall-e-3"
    end

    test "gpt-image-1 + :url rejection surfaces from prepare_request/2 too" do
      req =
        ImageRequest.new(
          operation: :generate,
          prompt: "x",
          model: "gpt-image-1",
          response_format: :url
        )

      assert {:error, %ImageAdapterError{reason: :invalid_request} = err} =
               Images.prepare_request(req, [])

      assert err.metadata.model == "gpt-image-1"
      assert err.metadata.response_format == :url
    end

    test ":variation returns an unfired Req.Request with multipart body (Phase 15.5)" do
      base = Image.from_binary(<<1>>, "image/png")

      req =
        ImageRequest.new(
          operation: :variation,
          prompt: nil,
          model: "dall-e-2",
          input_images: [base]
        )

      assert {:ok, %Req.Request{} = http_req} =
               Images.prepare_request(req, api_key: "sk-prep")

      assert URI.parse(http_req.url).path == "/v1/images/variations"
      assert http_req.method == :post
      assert is_list(http_req.options[:form_multipart])
    end

    test "image_script + prepare_request/2 returns the stub (no Req.Request analogue)" do
      out = Image.from_binary(<<1>>, "image/png")
      req = ImageRequest.new(operation: :generate, prompt: "x")
      opts = [adapter_opts: [image_script: [{:ok, [out]}]]]

      assert {:error,
              %ImageAdapterError{reason: :unknown, message: "operation pending implementation"}} =
               Images.prepare_request(req, opts)
    end

    test "image_script + prepare_request/2 stub error metadata reflects opts[:request_id]" do
      out = Image.from_binary(<<1>>, "image/png")
      req = ImageRequest.new(operation: :generate, prompt: "x")

      opts = [
        adapter_opts: [image_script: [{:ok, [out]}]],
        request_id: "rid-prepare-stub"
      ]

      assert {:error, %ImageAdapterError{} = err} = Images.prepare_request(req, opts)
      assert err.metadata[:request_id] == "rid-prepare-stub"
    end
  end
end
