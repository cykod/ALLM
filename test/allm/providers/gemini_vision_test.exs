defmodule ALLM.Providers.GeminiVisionTest do
  @moduledoc """
  Phase 16.4 — Gemini vision wiring (Layer B).

  Translator + pre-flight tests for `[%ALLM.TextPart{}, %ALLM.ImagePart{}]`
  content lists flowing through the `generateContent` translator. See
  spec §35.6 / §35.7 and Phase 16 design §16.4.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ALLM.Error.{AdapterError, ValidationError}
  alias ALLM.{Image, ImagePart, Message, Request, TextPart}
  alias ALLM.Providers.Gemini
  alias ALLM.Providers.GeminiTestFixtures, as: Fx
  alias ALLM.Test.FinchStub

  setup do
    ALLM.Keys.put(:gemini, "AIza-vision-test")
    on_exit(fn -> ALLM.Keys.delete(:gemini) end)
    stub = String.to_atom("gemini_vision_stub_#{System.unique_integer([:positive])}")
    {:ok, stub: stub}
  end

  defp call(stub, request, opts \\ []) do
    Gemini.generate(
      request,
      Keyword.merge(
        opts,
        adapter_opts: [plug: {Req.Test, stub}]
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
  # Translator: [TextPart, ImagePart] → parts: [{text}, {inlineData}]
  # ---------------------------------------------------------------------------

  describe "to_gemini_content_blocks (request body translator)" do
    test "Message with [TextPart, ImagePart{:base64}] translates to parts: [{text}, {inlineData}]",
         %{stub: stub} do
      body_ok = Fx.generate_content(:happy_text)
      parent = self()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:request_body, Jason.decode!(raw)})
        respond_json(conn, 200, body_ok)
      end)

      encoded = Base.encode64("hello-bytes")
      img = Image.from_base64(encoded, "image/png")

      request =
        Request.new([user_text_image("describe", img)], model: "gemini-2.5-flash")

      assert {:ok, _} = call(stub, request)
      assert_received {:request_body, body}
      assert [%{"role" => "user", "parts" => parts}] = body["contents"]

      assert parts == [
               %{"text" => "describe"},
               %{"inlineData" => %{"mimeType" => "image/png", "data" => encoded}}
             ]
    end

    test ~s(ImagePart with mime_type "image/jpeg" sets inlineData.mimeType = "image/jpeg"),
         %{stub: stub} do
      body_ok = Fx.generate_content(:happy_text)
      parent = self()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:request_body, Jason.decode!(raw)})
        respond_json(conn, 200, body_ok)
      end)

      img = Image.from_binary("jpeg-bytes", "image/jpeg")

      request =
        Request.new([user_text_image("look", img)], model: "gemini-2.5-flash")

      assert {:ok, _} = call(stub, request)
      assert_received {:request_body, body}
      [%{"parts" => [_text_part, image_part]}] = body["contents"]
      assert image_part["inlineData"]["mimeType"] == "image/jpeg"
    end

    test "multiple ImageParts in one message preserve source order",
         %{stub: stub} do
      body_ok = Fx.generate_content(:happy_text)
      parent = self()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:request_body, Jason.decode!(raw)})
        respond_json(conn, 200, body_ok)
      end)

      img1 = Image.from_base64(Base.encode64("first"), "image/png")
      img2 = Image.from_binary("second", "image/jpeg")

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
          model: "gemini-2.5-flash"
        )

      assert {:ok, _} = call(stub, request)
      assert_received {:request_body, body}
      [%{"parts" => parts}] = body["contents"]

      assert [
               %{"text" => "compare"},
               %{"inlineData" => %{"mimeType" => "image/png", "data" => d1}},
               %{"inlineData" => %{"mimeType" => "image/jpeg", "data" => d2}}
             ] = parts

      assert d1 == Base.encode64("first")
      assert d2 == Base.encode64("second")
    end

    test "request with vision message AND tools combined builds both tools[] and contents[]",
         %{stub: stub} do
      body_ok = Fx.generate_content(:happy_text)
      parent = self()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:request_body, Jason.decode!(raw)})
        respond_json(conn, 200, body_ok)
      end)

      tool =
        ALLM.Tool.new(
          name: "get_weather",
          description: "weather",
          schema: %{"type" => "object"}
        )

      img = Image.from_binary("img", "image/png")

      request =
        Request.new(
          [user_text_image("describe and check", img)],
          model: "gemini-2.5-flash",
          tools: [tool]
        )

      assert {:ok, _} = call(stub, request)
      assert_received {:request_body, body}

      # Both tools and contents populated.
      assert [%{"functionDeclarations" => [%{"name" => "get_weather"}]}] = body["tools"]
      assert [%{"role" => "user", "parts" => [_t, _img]}] = body["contents"]
    end

    test "binary-string content remains verbatim (v0.2 backward-compat)",
         %{stub: stub} do
      body_ok = Fx.generate_content(:happy_text)
      parent = self()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:request_body, Jason.decode!(raw)})
        respond_json(conn, 200, body_ok)
      end)

      request = Request.new([%Message{role: :user, content: "hello"}], model: "gemini-2.5-flash")

      assert {:ok, _} = call(stub, request)
      assert_received {:request_body, body}
      assert [%{"role" => "user", "parts" => [%{"text" => "hello"}]}] = body["contents"]
    end

    test "TextPart-only list flattens to joined text (Phase 14.4 backward-compat)",
         %{stub: stub} do
      body_ok = Fx.generate_content(:happy_text)
      parent = self()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:request_body, Jason.decode!(raw)})
        respond_json(conn, 200, body_ok)
      end)

      request =
        Request.new(
          [%Message{role: :user, content: [%TextPart{text: "a"}, %TextPart{text: "b"}]}],
          model: "gemini-2.5-flash"
        )

      assert {:ok, _} = call(stub, request)
      assert_received {:request_body, body}
      assert [%{"role" => "user", "parts" => [%{"text" => "a\nb"}]}] = body["contents"]
    end
  end

  # ---------------------------------------------------------------------------
  # Image.source variants — base64, binary, file, url
  # ---------------------------------------------------------------------------

  describe "Image.source variants — exhaustive coverage" do
    test "{:base64, data} forwards data verbatim under inlineData.data",
         %{stub: stub} do
      body_ok = Fx.generate_content(:happy_text)
      parent = self()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:request_body, Jason.decode!(raw)})
        respond_json(conn, 200, body_ok)
      end)

      encoded = Base.encode64("verbatim-bytes")
      img = Image.from_base64(encoded, "image/png")
      request = Request.new([user_text_image("d", img)], model: "gemini-2.5-flash")

      assert {:ok, _} = call(stub, request)
      assert_received {:request_body, body}
      [%{"parts" => [_t, %{"inlineData" => %{"data" => data}}]}] = body["contents"]
      assert data == encoded
    end

    test "{:binary, bytes} base64-encodes via Base.encode64/1",
         %{stub: stub} do
      body_ok = Fx.generate_content(:happy_text)
      parent = self()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:request_body, Jason.decode!(raw)})
        respond_json(conn, 200, body_ok)
      end)

      bytes = "raw-byte-payload"
      img = Image.from_binary(bytes, "image/png")
      request = Request.new([user_text_image("d", img)], model: "gemini-2.5-flash")

      assert {:ok, _} = call(stub, request)
      assert_received {:request_body, body}
      [%{"parts" => [_t, %{"inlineData" => %{"data" => data}}]}] = body["contents"]
      assert data == Base.encode64(bytes)
    end

    test "{:file, path} reads + base64-encodes happy path with mime_type from extension",
         %{stub: stub} do
      body_ok = Fx.generate_content(:happy_text)
      parent = self()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:request_body, Jason.decode!(raw)})
        respond_json(conn, 200, body_ok)
      end)

      tmp =
        Path.join(
          System.tmp_dir!(),
          "gemini_vision_test_#{System.unique_integer([:positive])}.png"
        )

      File.write!(tmp, "PNG-bytes-on-disk")

      try do
        img = Image.from_file(tmp)
        # from_file/1 infers mime_type from .png extension
        assert img.mime_type == "image/png"

        request = Request.new([user_text_image("d", img)], model: "gemini-2.5-flash")

        assert {:ok, _} = call(stub, request)
        assert_received {:request_body, body}
        [%{"parts" => [_t, %{"inlineData" => inline}]}] = body["contents"]
        assert inline == %{"mimeType" => "image/png", "data" => Base.encode64("PNG-bytes-on-disk")}
      after
        File.rm!(tmp)
      end
    end

    test "{:file, path} with nil mime_type returns AdapterError :unsupported_feature naming the path" do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "gemini_vision_test_noext_#{System.unique_integer([:positive])}"
        )

      File.write!(tmp, "raw")

      try do
        img = Image.from_file(tmp)
        # No extension → mime_type is nil
        assert img.mime_type == nil

        request = Request.new([user_text_image("d", img)], model: "gemini-2.5-flash")

        assert {:error, %AdapterError{reason: :unsupported_feature, message: msg}} =
                 Gemini.generate(request, [])

        assert msg =~ tmp
      after
        File.rm!(tmp)
      end
    end

    test "{:url, _} returns AdapterError :unsupported_feature with pre-fetch guidance" do
      img = Image.from_url("https://example.com/cat.png")
      request = Request.new([user_text_image("d", img)], model: "gemini-2.5-flash")

      assert {:error, %AdapterError{reason: :unsupported_feature, message: msg}} =
               Gemini.generate(request, [])

      # Helpful guidance for callers
      assert msg =~ "Gemini adapter does not fetch URL-source images"
      assert msg =~ "binary"
    end
  end

  # ---------------------------------------------------------------------------
  # System-message ImagePart rejection
  # ---------------------------------------------------------------------------

  describe "Pre-flight: system-role rejection" do
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
          model: "gemini-2.5-flash"
        )

      assert {:error, %ValidationError{reason: :invalid_message, errors: errors}} =
               Gemini.generate(request, [])

      assert {[:messages, 0, :content], :image_in_system_message} in errors
    end

    test "text-only system message does NOT trigger system rejection",
         %{stub: stub} do
      body_ok = Fx.generate_content(:happy_text)
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body_ok) end)

      request =
        Request.new(
          [
            %Message{role: :system, content: "system context"},
            %Message{role: :user, content: "hi"}
          ],
          model: "gemini-2.5-flash"
        )

      assert {:ok, _} = call(stub, request)
    end

    test "ImagePart in user role is NOT system-rejected", %{stub: stub} do
      body_ok = Fx.generate_content(:happy_text)
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body_ok) end)

      img = Image.from_binary("x", "image/png")
      request = Request.new([user_text_image("hi", img)], model: "gemini-2.5-flash")

      assert {:ok, _} = call(stub, request)
    end

    test "stream/2 rejects system ImagePart with %ValidationError{reason: :invalid_message}" do
      img = Image.from_url("https://example.com/x.png")

      request =
        Request.new(
          [
            %Message{role: :system, content: [%TextPart{text: "ctx"}, %ImagePart{image: img}]},
            %Message{role: :user, content: "hi"}
          ],
          model: "gemini-2.5-flash"
        )

      assert {:error, %ValidationError{reason: :invalid_message}} =
               Gemini.stream(request, [])
    end

    test "stream/2 rejects URL-source ImagePart with %AdapterError{reason: :unsupported_feature}" do
      img = Image.from_url("https://example.com/x.png")
      request = Request.new([user_text_image("hi", img)], model: "gemini-2.5-flash")

      assert {:error, %AdapterError{reason: :unsupported_feature}} =
               Gemini.stream(request, [])
    end
  end

  # ---------------------------------------------------------------------------
  # ImagePart.detail one-shot debug log (Gemini ignores detail entirely)
  # ---------------------------------------------------------------------------

  describe "ImagePart.detail one-shot debug log" do
    test "emits exactly one debug log per process across two calls", %{stub: stub} do
      body_ok = Fx.generate_content(:happy_text)
      img = Image.from_binary("x", "image/png")
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body_ok) end)

      log =
        capture_log([level: :debug], fn ->
          # Use Task.async for process-dict isolation; rely on
          # capture_log([level: :debug], ...) for per-process Logger level.
          # Per CLAUDE.md "async:true + Logger.configure/1 is a foot-gun" —
          # do NOT call `Logger.configure(level: :debug)` inside the Task.
          Task.async(fn ->
            request1 =
              Request.new([user_text_image("a", img, :high)], model: "gemini-2.5-flash")

            request2 =
              Request.new([user_text_image("b", img, :low)], model: "gemini-2.5-flash")

            assert {:ok, _} = call(stub, request1)
            assert {:ok, _} = call(stub, request2)
          end)
          |> Task.await(5_000)
        end)

      count =
        log
        |> String.split("\n")
        |> Enum.count(&String.contains?(&1, "ImagePart.detail is not supported by Gemini"))

      assert count == 1, "expected exactly one debug log; saw #{count}\n--- log ---\n#{log}"
    end

    test "emits NO debug log when detail is :auto (the default)" do
      img = Image.from_binary("x", "image/png")

      log =
        capture_log([level: :debug], fn ->
          Task.async(fn ->
            # detail: :auto is the default; Gemini ignores all detail values
            # but only the *explicit non-default* ones surface the warning.
            part = %ImagePart{image: img, detail: :auto}
            msg = %Message{role: :user, content: [%TextPart{text: "x"}, part]}
            request = Request.new([msg], model: "gemini-2.5-flash")
            _ = Gemini.to_gemini_request_body(request, [])
            :ok
          end)
          |> Task.await(5_000)
        end)

      refute String.contains?(log, "ImagePart.detail is not supported by Gemini")
    end
  end

  # ---------------------------------------------------------------------------
  # Streaming with vision input (Phase 16.2 chunk shape unchanged)
  # ---------------------------------------------------------------------------

  describe "stream/2 with vision content" do
    test "stream/2 with vision input streams text deltas as in Phase 16.2" do
      chunks = Fx.stream_chunks(:happy_text_stream)
      stub = FinchStub.install(chunks, [])

      img = Image.from_binary("img", "image/png")
      request = Request.new([user_text_image("describe", img)], model: "gemini-2.5-flash")

      assert {:ok, stream} =
               Gemini.stream(request,
                 finch_module: FinchStub,
                 finch_stub_ref: stub
               )

      events = Enum.to_list(stream)
      assert match?({:message_started, _}, hd(events))
      text_deltas = Enum.filter(events, &match?({:text_delta, _}, &1))
      assert text_deltas != []
      assert match?({:message_completed, _}, List.last(events))
    end

    test "stream/2 happy path with ImagePart goes through the same body builder" do
      # Smoke-test that `stream/2` accepts an ImagePart-bearing request and
      # returns `{:ok, stream}`. The non-streaming translator tests above
      # already pin the `inlineData` body shape via `to_gemini_request_body/2`,
      # which is the same builder used here; this test only confirms the
      # streaming entry point doesn't reject vision input upstream.
      chunks = Fx.stream_chunks(:happy_text_stream)
      stub = FinchStub.install(chunks, [])

      img = Image.from_binary("img-bytes", "image/jpeg")
      request = Request.new([user_text_image("describe", img)], model: "gemini-2.5-flash")

      assert {:ok, _stream} =
               Gemini.stream(request,
                 finch_module: FinchStub,
                 finch_stub_ref: stub
               )
    end
  end

  # ---------------------------------------------------------------------------
  # Capability gate at runner level (CLAUDE.md "Capability pre-flight runs in
  # ALLM.StreamRunner and ALLM.* facade helpers, NOT inside adapter generate/2")
  # ---------------------------------------------------------------------------

  describe "Capability gate (vision) — runner-level integration" do
    test "Capability.preflight/3 with vision: false rejects an ImagePart-bearing request" do
      ref = %ALLM.ModelRef{
        provider: :gemini,
        id: "gemini-2.5-flash",
        capabilities: %{vision: false}
      }

      img = Image.from_binary("x", "image/png")

      request =
        Request.new([user_text_image("look", img)], model: "gemini-2.5-flash")

      assert {:error, %ValidationError{reason: :unsupported_capability, errors: errors}} =
               ALLM.Capability.preflight(ref, request)

      assert {[:vision], :vision_disabled} in errors
    end
  end
end
