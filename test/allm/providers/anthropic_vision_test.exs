defmodule ALLM.Providers.AnthropicVisionTest do
  @moduledoc """
  Phase 17.2 — Anthropic vision wiring (Layer B).

  Translator + pre-flight + decoder tests for `[%ALLM.TextPart{},
  %ALLM.ImagePart{}]` content lists flowing through the Messages-API
  translator. See spec §35.6 / §35.7 and Phase 17 design §17.2.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ALLM.Error.ValidationError
  alias ALLM.{Image, ImagePart, Message, Request, TextPart}
  alias ALLM.Providers.Anthropic
  alias ALLM.Providers.AnthropicTestFixtures, as: Fx

  setup do
    stub = String.to_atom("anthropic_vision_stub_#{System.unique_integer([:positive])}")
    {:ok, stub: stub}
  end

  defp call(stub, request, opts \\ []) do
    Anthropic.generate(
      request,
      Keyword.merge(
        [api_key: "sk-ant-vision-test"],
        Keyword.merge(opts, adapter_opts: [plug: {Req.Test, stub}])
      )
    )
  end

  defp respond_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  defp user_text_image(text, image, detail \\ :auto) do
    %Message{
      role: :user,
      content: [
        %TextPart{text: text},
        %ImagePart{image: image, detail: detail}
      ]
    }
  end

  # ---------------------------------------------------------------------------
  # Translator: to_anthropic_messages/1 routes list-content through translator
  # ---------------------------------------------------------------------------

  describe "Messages translator (to_anthropic_messages/1 + content blocks)" do
    test "translates [TextPart] to [%{type: \"text\", text}]", %{stub: stub} do
      body_ok = Fx.messages_response(:happy_text)
      parent = self()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:request_body, Jason.decode!(raw)})
        respond_json(conn, 200, body_ok)
      end)

      # Pure-TextPart list still flattens to joined text (Phase 14.4
      # backward-compat); list-shape with images takes the new translator.
      request =
        Request.new(
          [%Message{role: :user, content: [%TextPart{text: "a"}, %TextPart{text: "b"}]}],
          model: "claude-sonnet-4-6"
        )

      assert {:ok, _} = call(stub, request)
      assert_received {:request_body, body}
      assert [%{"role" => "user", "content" => "a\nb"}] = body["messages"]
    end

    test "translates [ImagePart{:url}] to image source: {type: url, url}", %{stub: stub} do
      body_ok = Fx.messages_vision(:single_image_url)
      parent = self()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:request_body, Jason.decode!(raw)})
        respond_json(conn, 200, body_ok)
      end)

      img = Image.from_url("https://example.com/cat.png")

      request =
        Request.new(
          [user_text_image("describe", img, :auto)],
          model: "claude-haiku-4-5-20251001"
        )

      assert {:ok, _} = call(stub, request)
      assert_received {:request_body, body}
      assert [%{"role" => "user", "content" => content}] = body["messages"]

      assert content == [
               %{"type" => "text", "text" => "describe"},
               %{
                 "type" => "image",
                 "source" => %{
                   "type" => "url",
                   "url" => "https://example.com/cat.png"
                 }
               }
             ]
    end

    test "translates [ImagePart{:base64}] passing the base64 string verbatim into source.data",
         %{stub: stub} do
      body_ok = Fx.messages_vision(:single_image_base64)
      parent = self()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:request_body, Jason.decode!(raw)})
        respond_json(conn, 200, body_ok)
      end)

      encoded = Base.encode64("hello")
      img = Image.from_base64(encoded, "image/png")

      request =
        Request.new(
          [user_text_image("look", img)],
          model: "claude-haiku-4-5-20251001"
        )

      assert {:ok, _} = call(stub, request)
      assert_received {:request_body, body}
      [%{"content" => [_text, image_block]}] = body["messages"]

      assert image_block == %{
               "type" => "image",
               "source" => %{
                 "type" => "base64",
                 "media_type" => "image/png",
                 "data" => encoded
               }
             }
    end

    test "translates [ImagePart{:binary}] via base64 encoding", %{stub: stub} do
      body_ok = Fx.messages_vision(:single_image_binary)
      parent = self()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:request_body, Jason.decode!(raw)})
        respond_json(conn, 200, body_ok)
      end)

      bytes = "raw-bytes"
      img = Image.from_binary(bytes, "image/png")

      request =
        Request.new(
          [user_text_image("look", img)],
          model: "claude-haiku-4-5-20251001"
        )

      assert {:ok, _} = call(stub, request)
      assert_received {:request_body, body}
      [%{"content" => [_text, image_block]}] = body["messages"]

      assert image_block["source"] == %{
               "type" => "base64",
               "media_type" => "image/png",
               "data" => Base.encode64(bytes)
             }
    end

    test "reads [ImagePart{:file}] via Image.to_binary/1 and base64-encodes", %{stub: stub} do
      body_ok = Fx.messages_vision(:single_image_url)
      parent = self()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:request_body, Jason.decode!(raw)})
        respond_json(conn, 200, body_ok)
      end)

      tmp =
        Path.join(
          System.tmp_dir!(),
          "anthropic_vision_test_#{System.unique_integer([:positive])}.png"
        )

      File.write!(tmp, "PNG-bytes")

      try do
        img = Image.from_file(tmp)

        request =
          Request.new(
            [user_text_image("look", img)],
            model: "claude-haiku-4-5-20251001"
          )

        assert {:ok, _} = call(stub, request)
        assert_received {:request_body, body}
        [%{"content" => [_text, image_block]}] = body["messages"]

        assert image_block["source"] == %{
                 "type" => "base64",
                 "media_type" => "image/png",
                 "data" => Base.encode64("PNG-bytes")
               }
      after
        File.rm!(tmp)
      end
    end

    test "ignores ImagePart.detail (any of :auto, :low, :high produce same wire shape)",
         %{stub: stub} do
      body_ok = Fx.messages_vision(:single_image_url)

      img = Image.from_url("https://example.com/x.png")
      shapes = []

      shapes =
        for detail <- [:auto, :low, :high] do
          parent = self()

          Req.Test.stub(stub, fn conn ->
            {:ok, raw, conn} = Plug.Conn.read_body(conn)
            send(parent, {detail, Jason.decode!(raw)})
            respond_json(conn, 200, body_ok)
          end)

          request =
            Request.new(
              [user_text_image("d", img, detail)],
              model: "claude-haiku-4-5-20251001"
            )

          assert {:ok, _} = call(stub, request)
          assert_received {^detail, body}
          [%{"content" => [_text, image_block]}] = body["messages"]
          # `detail` MUST NOT appear anywhere in the wire shape
          refute Map.has_key?(image_block, "detail")
          refute Map.has_key?(image_block["source"], "detail")
          image_block
        end ++ shapes

      [b1, b2, b3] = shapes
      assert b1 == b2
      assert b2 == b3
    end

    test "multi-image emits ordered content-block list", %{stub: stub} do
      body_ok = Fx.messages_vision(:multi_image)
      parent = self()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:request_body, Jason.decode!(raw)})
        respond_json(conn, 200, body_ok)
      end)

      img1 = Image.from_url("https://example.com/a.png")
      img2 = Image.from_url("https://example.com/b.png")

      request =
        Request.new(
          [
            %Message{
              role: :user,
              content: [
                %TextPart{text: "compare"},
                %ImagePart{image: img1},
                %ImagePart{image: img2}
              ]
            }
          ],
          model: "claude-haiku-4-5-20251001"
        )

      assert {:ok, _} = call(stub, request)
      assert_received {:request_body, body}
      [%{"content" => [b1, b2, b3]}] = body["messages"]
      assert b1["type"] == "text"
      assert b2["source"]["url"] == "https://example.com/a.png"
      assert b3["source"]["url"] == "https://example.com/b.png"
    end

    test "binary-string content remains verbatim (v0.2 backward-compat)", %{stub: stub} do
      body_ok = Fx.messages_response(:happy_text)
      parent = self()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:request_body, Jason.decode!(raw)})
        respond_json(conn, 200, body_ok)
      end)

      request = Request.new([%Message{role: :user, content: "hello"}], model: "claude-sonnet-4-6")

      assert {:ok, _} = call(stub, request)
      assert_received {:request_body, body}
      assert [%{"role" => "user", "content" => "hello"}] = body["messages"]
    end
  end

  # ---------------------------------------------------------------------------
  # Detail-drop debug log (Decision #3)
  # ---------------------------------------------------------------------------

  describe "ImagePart.detail one-shot debug log (Decision #3)" do
    test "emits exactly one debug log per process across two calls", %{stub: stub} do
      body_ok = Fx.messages_vision(:single_image_url)

      img = Image.from_url("https://example.com/x.png")

      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body_ok) end)

      log =
        capture_log([level: :debug], fn ->
          # Run BOTH calls in a Task so this test runs in its own process
          # — the once-per-process flag is keyed on the calling process
          # dictionary; running in the test process would leak state.
          Task.async(fn ->
            Logger.configure(level: :debug)
            request1 = Request.new([user_text_image("a", img, :high)], model: "claude-sonnet-4-6")
            request2 = Request.new([user_text_image("b", img, :low)], model: "claude-sonnet-4-6")
            assert {:ok, _} = call(stub, request1)
            assert {:ok, _} = call(stub, request2)
          end)
          |> Task.await(5_000)
        end)

      # Count occurrences of the once-per-process drop message
      count =
        log
        |> String.split("\n")
        |> Enum.count(&String.contains?(&1, "ImagePart.detail is not supported by Anthropic"))

      assert count == 1, "expected exactly one debug log; saw #{count}\n--- log ---\n#{log}"
    end

    test "emits NO debug log when detail is nil" do
      img = Image.from_url("https://example.com/x.png")

      log =
        capture_log([level: :debug], fn ->
          Task.async(fn ->
            Logger.configure(level: :debug)
            # detail: nil → no warning fires.
            part = %ImagePart{image: img, detail: nil}
            msg = %Message{role: :user, content: [%TextPart{text: "x"}, part]}
            request = Request.new([msg], model: "claude-sonnet-4-6")
            # The pre-flight + translator path runs even when the HTTP plug
            # is missing — but to keep the test independent of HTTP we just
            # call to_anthropic_request_body directly.
            _ = ALLM.Providers.Anthropic.to_anthropic_request_body(request)
            :ok
          end)
          |> Task.await(5_000)
        end)

      refute String.contains?(log, "ImagePart.detail is not supported by Anthropic")
    end
  end

  # ---------------------------------------------------------------------------
  # Pre-flight (system rejection + ImageMime)
  # ---------------------------------------------------------------------------

  describe "Pre-flight" do
    test "system-message ImagePart returns %ValidationError{reason: :invalid_message}" do
      img = Image.from_url("https://example.com/x.png")

      request =
        Request.new(
          [
            %Message{
              role: :system,
              content: [%TextPart{text: "ctx"}, %ImagePart{image: img}]
            },
            %Message{role: :user, content: "hi"}
          ],
          model: "claude-sonnet-4-6"
        )

      assert {:error, %ValidationError{reason: :invalid_message, errors: errors}} =
               Anthropic.generate(request, api_key: "sk-x")

      assert {[:messages, 0, :content], :image_in_system_message} in errors
    end

    test "system-message text-only content does NOT trigger system rejection", %{stub: stub} do
      body_ok = Fx.messages_response(:happy_text)
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body_ok) end)

      request =
        Request.new(
          [
            %Message{role: :system, content: "system context"},
            %Message{role: :user, content: "hi"}
          ],
          model: "claude-sonnet-4-6"
        )

      assert {:ok, _} = call(stub, request)
    end

    test "ImagePart in user role is NOT system-rejected", %{stub: stub} do
      body_ok = Fx.messages_vision(:single_image_url)
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body_ok) end)

      img = Image.from_url("https://example.com/x.png")

      request =
        Request.new(
          [user_text_image("hi", img)],
          model: "claude-haiku-4-5-20251001"
        )

      assert {:ok, _} = call(stub, request)
    end

    test "ImageMime: unsupported MIME (image/svg+xml) returns ValidationError" do
      img = Image.from_binary("<svg/>", "image/svg+xml")

      request =
        Request.new(
          [user_text_image("look", img)],
          model: "claude-haiku-4-5-20251001"
        )

      assert {:error, %ValidationError{reason: :invalid_message, errors: errors}} =
               Anthropic.generate(request, api_key: "sk-x")

      assert {[:content, 0, 1], :unsupported_image_format} in errors
    end

    test "ImageMime: 21 MB image returns :image_too_large" do
      bytes = :binary.copy(<<0>>, 21 * 1024 * 1024)
      img = Image.from_binary(bytes, "image/png")

      request =
        Request.new(
          [user_text_image("look", img)],
          model: "claude-haiku-4-5-20251001"
        )

      assert {:error, %ValidationError{reason: :invalid_message, errors: errors}} =
               Anthropic.generate(request, api_key: "sk-x")

      assert {[:content, 0, 1], :image_too_large} in errors
    end

    test "ImageMime.validate_request(:anthropic) parity with :openai for unsupported MIME" do
      img = Image.from_binary("<svg/>", "image/svg+xml")

      request =
        Request.new(
          [user_text_image("look", img)],
          model: "claude-haiku-4-5-20251001"
        )

      anthropic_result = ALLM.Providers.Support.ImageMime.validate_request(request, :anthropic)
      openai_result = ALLM.Providers.Support.ImageMime.validate_request(request, :openai)

      # Same input → identical errors today (accept-sets match).
      assert {:error, %ValidationError{reason: :invalid_message, errors: e1}} = anthropic_result
      assert {:error, %ValidationError{reason: :invalid_message, errors: e2}} = openai_result
      assert e1 == e2
    end
  end

  # ---------------------------------------------------------------------------
  # extract_system: text-only invariant (out-of-scope for ImagePart)
  # ---------------------------------------------------------------------------

  describe "extract_system/1 invariants" do
    test "text-only system message stays intact" do
      messages = [
        %Message{role: :system, content: "be brief"},
        %Message{role: :user, content: "hi"}
      ]

      assert {"be brief", non_system} = Anthropic.extract_system(messages)
      assert length(non_system) == 1
    end

    test "system+ImagePart is rejected at generate/2 boundary, not extract_system/1" do
      img = Image.from_url("https://example.com/x.png")
      sys = %Message{role: :system, content: [%TextPart{text: "ctx"}, %ImagePart{image: img}]}
      messages = [sys, %Message{role: :user, content: "hi"}]

      # extract_system/1 doesn't enforce text-only; the rejection lives
      # upstream at reject_image_in_system_messages/1 in generate/2.
      assert {sys_text, _rest} = Anthropic.extract_system(messages)
      # stringify_content drops ImagePart silently per the graceful empty
      # string contract; system text is just the TextPart's text.
      assert sys_text == "ctx\n"

      request = Request.new(messages, model: "claude-sonnet-4-6")

      assert {:error, %ValidationError{reason: :invalid_message}} =
               Anthropic.generate(request, api_key: "sk-x")
    end
  end

  # ---------------------------------------------------------------------------
  # Wire-fixture decode tests
  # ---------------------------------------------------------------------------

  describe "decode wire fixtures" do
    test "single_image_url decodes to text response", %{stub: stub} do
      body_ok = Fx.messages_vision(:single_image_url)
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body_ok) end)

      img = Image.from_url("https://example.com/cat.png")
      request = Request.new([user_text_image("describe", img)], model: "claude-haiku-4-5-20251001")

      assert {:ok, response} = call(stub, request)
      assert response.finish_reason == :stop
      assert response.message.content == "I can see a cat sitting on a windowsill."
    end

    test "single_image_base64 decodes", %{stub: stub} do
      body_ok = Fx.messages_vision(:single_image_base64)
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body_ok) end)

      img = Image.from_base64(Base.encode64("hi"), "image/png")
      request = Request.new([user_text_image("d", img)], model: "claude-haiku-4-5-20251001")

      assert {:ok, response} = call(stub, request)
      assert response.finish_reason == :stop
    end

    test "single_image_binary decodes", %{stub: stub} do
      body_ok = Fx.messages_vision(:single_image_binary)
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body_ok) end)

      img = Image.from_binary("raw", "image/png")
      request = Request.new([user_text_image("d", img)], model: "claude-haiku-4-5-20251001")

      assert {:ok, response} = call(stub, request)
      assert response.finish_reason == :stop
    end

    test "multi_image decodes", %{stub: stub} do
      body_ok = Fx.messages_vision(:multi_image)
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body_ok) end)

      img1 = Image.from_url("https://example.com/a.png")
      img2 = Image.from_binary("y", "image/png")

      request =
        Request.new(
          [
            %Message{
              role: :user,
              content: [%TextPart{text: "x"}, %ImagePart{image: img1}, %ImagePart{image: img2}]
            }
          ],
          model: "claude-haiku-4-5-20251001"
        )

      assert {:ok, response} = call(stub, request)
      assert response.finish_reason == :stop
    end
  end

  # ---------------------------------------------------------------------------
  # Streaming (request side) — pre-flight only; HTTP not exercised
  # ---------------------------------------------------------------------------

  describe "stream/2 with vision content" do
    test "stream/2 accepts an ImagePart-bearing request without pre-flight rejection" do
      img = Image.from_url("https://example.com/x.png")

      request =
        Request.new([user_text_image("hi", img)], model: "claude-haiku-4-5-20251001")

      assert {:ok, _stream} = Anthropic.stream(request, api_key: "sk-x")
    end

    test "stream/2 rejects ImagePart in system message" do
      img = Image.from_url("https://example.com/x.png")

      request =
        Request.new(
          [
            %Message{role: :system, content: [%TextPart{text: "ctx"}, %ImagePart{image: img}]},
            %Message{role: :user, content: "hi"}
          ],
          model: "claude-haiku-4-5-20251001"
        )

      assert {:error, %ValidationError{reason: :invalid_message}} =
               Anthropic.stream(request, api_key: "sk-x")
    end

    test "stream/2 rejects oversize image at pre-flight" do
      bytes = :binary.copy(<<0>>, 21 * 1024 * 1024)
      img = Image.from_binary(bytes, "image/png")

      request =
        Request.new([user_text_image("hi", img)], model: "claude-haiku-4-5-20251001")

      assert {:error, %ValidationError{reason: :invalid_message, errors: errors}} =
               Anthropic.stream(request, api_key: "sk-x")

      assert {[:content, 0, 1], :image_too_large} in errors
    end
  end

  # ---------------------------------------------------------------------------
  # Capability gate against an Anthropic resolved model (runner-level)
  # ---------------------------------------------------------------------------

  describe "Capability gate (vision) — runner-level integration" do
    test "Capability.preflight/3 with vision: false rejects an ImagePart-bearing request" do
      # Direct exercise of the runner-level gate against a vision-disabled
      # Anthropic model. Mirrors test/allm/capability_vision_test.exs but
      # asserts the gate sees an Anthropic %ModelRef{}.
      ref = %ALLM.ModelRef{
        provider: :anthropic,
        id: "claude-sonnet-4-6",
        capabilities: %{vision: false}
      }

      img = Image.from_url("https://example.com/x.png")

      request =
        Request.new([user_text_image("look", img)], model: "claude-sonnet-4-6")

      assert {:error, %ValidationError{reason: :unsupported_capability, errors: errors}} =
               ALLM.Capability.preflight(ref, request)

      assert {[:vision], :vision_disabled} in errors
    end
  end

  # ---------------------------------------------------------------------------
  # Live test (BLOCKING /review gate; tagged :live_anthropic)
  # ---------------------------------------------------------------------------

  @tag :live_anthropic
  test "live: claude-haiku-4-5-20251001 against a 50 KB local PNG returns a non-empty response" do
    api_key = System.fetch_env!("ANTHROPIC_API_KEY")

    one_pixel_png =
      <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 2,
        0, 0, 0, 144, 119, 83, 222, 0, 0, 0, 12, 73, 68, 65, 84, 8, 153, 99, 248, 207, 192, 0, 0, 0,
        3, 0, 1, 91, 169, 33, 76, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>

    img = Image.from_binary(one_pixel_png, "image/png")

    request =
      Request.new(
        [user_text_image("What color is the pixel?", img)],
        model: "claude-haiku-4-5-20251001",
        max_tokens: 100
      )

    case Anthropic.generate(request, api_key: api_key, retry: false) do
      {:ok, response} ->
        assert response.finish_reason in [:stop, :length]
        assert is_binary(response.output_text)
        assert byte_size(response.output_text) > 0

      {:error, err} ->
        flunk("Live Anthropic vision test failed: #{inspect(err)}")
    end
  end
end
