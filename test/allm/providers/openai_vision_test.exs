defmodule ALLM.Providers.OpenAIVisionTest do
  @moduledoc """
  Phase 17.1 — OpenAI vision wiring (Layer B).

  Translator + pre-flight + decoder tests for `[%ALLM.TextPart{},
  %ALLM.ImagePart{}]` content lists flowing through both the Chat
  Completions and Responses API translators. See spec §35.6 / §35.7 and
  Phase 17 design §17.1.
  """
  use ExUnit.Case, async: true

  alias ALLM.Error.{AdapterError, ValidationError}
  alias ALLM.{Image, ImagePart, Message, Request, TextPart}
  alias ALLM.Providers.OpenAI
  alias ALLM.Providers.OpenAITestFixtures, as: Fx

  setup do
    stub = String.to_atom("openai_vision_stub_#{System.unique_integer([:positive])}")
    {:ok, stub: stub}
  end

  defp call(stub, request, opts \\ []) do
    OpenAI.generate(
      request,
      Keyword.merge(
        [api_key: "sk-vision-test"],
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
  # Chat Completions translator
  # ---------------------------------------------------------------------------

  describe "Chat Completions translator (to_openai_messages/1 + content blocks)" do
    test "translates a [TextPart, ImagePart{:url}] content list to a Chat Completions content-block list",
         %{stub: stub} do
      body_ok = Fx.chat_vision(:single_image_url)
      parent = self()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:request_body, Jason.decode!(raw)})
        respond_json(conn, 200, body_ok)
      end)

      img = Image.from_url("https://example.com/cat.png")

      request =
        Request.new(
          [user_text_image("describe", img, :high)],
          model: "gpt-4o-mini"
        )

      assert {:ok, _} = call(stub, request)
      assert_received {:request_body, body}

      assert [%{"role" => "user", "content" => content}] = body["messages"]

      assert content == [
               %{"type" => "text", "text" => "describe"},
               %{
                 "type" => "image_url",
                 "image_url" => %{
                   "url" => "https://example.com/cat.png",
                   "detail" => "high"
                 }
               }
             ]
    end

    test "ImagePart{:base64} produces a data: URI image_url", %{stub: stub} do
      body_ok = Fx.chat_vision(:single_image_base64)
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
          model: "gpt-4o-mini"
        )

      assert {:ok, _} = call(stub, request)
      assert_received {:request_body, body}
      [%{"content" => [_text, image_block]}] = body["messages"]
      assert image_block["type"] == "image_url"
      assert image_block["image_url"]["url"] == "data:image/png;base64,#{encoded}"
      assert image_block["image_url"]["detail"] == "auto"
    end

    test "ImagePart{:binary} produces a data: URI with base64 encoding", %{stub: stub} do
      body_ok = Fx.chat_vision(:single_image_binary)
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
          model: "gpt-4o-mini"
        )

      assert {:ok, _} = call(stub, request)
      assert_received {:request_body, body}
      [%{"content" => [_text, image_block]}] = body["messages"]

      assert image_block["image_url"]["url"] ==
               "data:image/png;base64,#{Base.encode64(bytes)}"
    end

    test "ImagePart{:file} reads via Image.to_binary/1 and base64-encodes", %{stub: stub} do
      body_ok = Fx.chat_vision(:single_image_url)
      parent = self()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:request_body, Jason.decode!(raw)})
        respond_json(conn, 200, body_ok)
      end)

      tmp = Path.join(System.tmp_dir!(), "vision_test_#{System.unique_integer([:positive])}.png")
      File.write!(tmp, "PNG-bytes")

      try do
        img = Image.from_file(tmp)

        request =
          Request.new(
            [user_text_image("look", img)],
            model: "gpt-4o-mini"
          )

        assert {:ok, _} = call(stub, request)
        assert_received {:request_body, body}
        [%{"content" => [_text, image_block]}] = body["messages"]

        assert image_block["image_url"]["url"] ==
                 "data:image/png;base64,#{Base.encode64("PNG-bytes")}"
      after
        File.rm!(tmp)
      end
    end

    test ~s(detail :auto/:low/:high map to wire strings "auto"/"low"/"high"), %{stub: stub} do
      body_ok = Fx.chat_vision(:single_image_url)

      for detail <- [:auto, :low, :high] do
        Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body_ok) end)

        parent = self()

        Req.Test.stub(stub, fn conn ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          send(parent, {detail, Jason.decode!(raw)})
          respond_json(conn, 200, body_ok)
        end)

        img = Image.from_url("https://example.com/x.png")

        request =
          Request.new(
            [user_text_image("d", img, detail)],
            model: "gpt-4o-mini"
          )

        assert {:ok, _} = call(stub, request)
        assert_received {^detail, body}
        [%{"content" => [_text, image_block]}] = body["messages"]
        assert image_block["image_url"]["detail"] == Atom.to_string(detail)
      end
    end

    test "binary-string content stays verbatim (v0.2 backward-compat)", %{stub: stub} do
      body_ok = Fx.chat_completion(:happy_text)
      parent = self()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:request_body, Jason.decode!(raw)})
        respond_json(conn, 200, body_ok)
      end)

      request = Request.new([%Message{role: :user, content: "hello"}], model: "gpt-4o-mini")

      assert {:ok, _} = call(stub, request)
      assert_received {:request_body, body}
      assert [%{"content" => "hello"}] = body["messages"]
    end

    test "text-only [TextPart] content list still flattens to joined text", %{stub: stub} do
      body_ok = Fx.chat_completion(:happy_text)
      parent = self()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:request_body, Jason.decode!(raw)})
        respond_json(conn, 200, body_ok)
      end)

      request =
        Request.new(
          [%Message{role: :user, content: [%TextPart{text: "a"}, %TextPart{text: "b"}]}],
          model: "gpt-4o-mini"
        )

      assert {:ok, _} = call(stub, request)
      assert_received {:request_body, body}
      assert [%{"content" => "a\nb"}] = body["messages"]
    end

    test "multiple ImageParts: blocks emit in original order", %{stub: stub} do
      body_ok = Fx.chat_vision(:multi_image)
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
          model: "gpt-4o-mini"
        )

      assert {:ok, _} = call(stub, request)
      assert_received {:request_body, body}
      [%{"content" => [b1, b2, b3]}] = body["messages"]
      assert b1["type"] == "text"
      assert b2["image_url"]["url"] == "https://example.com/a.png"
      assert b3["image_url"]["url"] == "https://example.com/b.png"
    end
  end

  # ---------------------------------------------------------------------------
  # Responses API translator
  # ---------------------------------------------------------------------------

  describe "Responses API translator (to_responses_input/1 + content blocks)" do
    test "translates [TextPart] → [{type: input_text}] on the Responses wire", %{stub: stub} do
      body_ok = Fx.responses_vision(:single_image_url)
      parent = self()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:request_body, Jason.decode!(raw)})
        respond_json(conn, 200, body_ok)
      end)

      img = Image.from_url("https://example.com/cat.png")

      request =
        Request.new(
          [user_text_image("look", img, :low)],
          model: "gpt-5.5"
        )

      assert {:ok, _} = call(stub, request)
      assert_received {:request_body, body}
      [%{"content" => content}] = body["input"]

      assert content == [
               %{"type" => "input_text", "text" => "look"},
               %{
                 "type" => "input_image",
                 "image_url" => "https://example.com/cat.png",
                 "detail" => "low"
               }
             ]
    end

    test "ImagePart{:base64} on Responses produces a data: URI image_url", %{stub: stub} do
      body_ok = Fx.responses_vision(:single_image_base64)
      parent = self()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:request_body, Jason.decode!(raw)})
        respond_json(conn, 200, body_ok)
      end)

      encoded = Base.encode64("hi")
      img = Image.from_base64(encoded, "image/png")

      request =
        Request.new([user_text_image("hi", img)], model: "gpt-5.5")

      assert {:ok, _} = call(stub, request)
      assert_received {:request_body, body}
      [%{"content" => [_text, image_block]}] = body["input"]
      assert image_block["type"] == "input_image"
      assert image_block["image_url"] == "data:image/png;base64,#{encoded}"
      assert image_block["detail"] == "auto"
    end

    test "Responses: multi-image emits ordered content-block list", %{stub: stub} do
      body_ok = Fx.responses_vision(:multi_image)
      parent = self()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:request_body, Jason.decode!(raw)})
        respond_json(conn, 200, body_ok)
      end)

      img1 = Image.from_url("https://example.com/1.png")
      img2 = Image.from_url("https://example.com/2.png")

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
          model: "gpt-5.5"
        )

      assert {:ok, _} = call(stub, request)
      assert_received {:request_body, body}
      [%{"content" => [b1, b2, b3]}] = body["input"]
      assert b1["type"] == "input_text"
      assert b2["image_url"] == "https://example.com/1.png"
      assert b3["image_url"] == "https://example.com/2.png"
    end

    test "binary-string content remains verbatim on Responses", %{stub: stub} do
      body_ok = Fx.responses(:happy_text)
      parent = self()

      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:request_body, Jason.decode!(raw)})
        respond_json(conn, 200, body_ok)
      end)

      request = Request.new([%Message{role: :user, content: "hello"}], model: "gpt-5.5")

      assert {:ok, _} = call(stub, request)
      assert_received {:request_body, body}
      assert [%{"content" => "hello"}] = body["input"]
    end
  end

  # ---------------------------------------------------------------------------
  # Pre-flight (system-rejection + ImageMime + ordering)
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
          model: "gpt-4o-mini"
        )

      assert {:error, %ValidationError{reason: :invalid_message, errors: errors}} =
               OpenAI.generate(request, api_key: "sk-x")

      assert {[:messages, 0, :content], :image_in_system_message} in errors
    end

    test "system-message text-only content does NOT trigger system rejection", %{stub: stub} do
      body_ok = Fx.chat_completion(:happy_text)
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body_ok) end)

      request =
        Request.new(
          [
            %Message{role: :system, content: "system context"},
            %Message{role: :user, content: "hi"}
          ],
          model: "gpt-4o-mini"
        )

      assert {:ok, _} = call(stub, request)
    end

    test "ImagePart in user role is NOT system-rejected", %{stub: stub} do
      body_ok = Fx.chat_vision(:single_image_url)
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body_ok) end)

      img = Image.from_url("https://example.com/x.png")

      request =
        Request.new(
          [user_text_image("hi", img)],
          model: "gpt-4o-mini"
        )

      assert {:ok, _} = call(stub, request)
    end

    test "ImageMime: unsupported MIME (image/svg+xml) returns ValidationError" do
      img = Image.from_binary("<svg/>", "image/svg+xml")

      request =
        Request.new(
          [user_text_image("look", img)],
          model: "gpt-4o-mini"
        )

      assert {:error, %ValidationError{reason: :invalid_message, errors: errors}} =
               OpenAI.generate(request, api_key: "sk-x")

      assert {[:content, 0, 1], :unsupported_image_format} in errors
    end

    test "ImageMime: 21 MB image returns :image_too_large" do
      bytes = :binary.copy(<<0>>, 21 * 1024 * 1024)
      img = Image.from_binary(bytes, "image/png")

      request =
        Request.new(
          [user_text_image("look", img)],
          model: "gpt-4o-mini"
        )

      assert {:error, %ValidationError{reason: :invalid_message, errors: errors}} =
               OpenAI.generate(request, api_key: "sk-x")

      assert {[:content, 0, 1], :image_too_large} in errors
    end

    # An unreadable `{:file, path}` used to pass BOTH the MIME and the size gate
    # — `ImageMime.check_byte_size/1` folded "cannot read the bytes" into "no
    # size objection" — and then raise `MatchError` from `part_to_block/2`'s
    # `{:ok, uri} = Image.to_data_uri(img)`, escaping `generate/2`'s documented
    # `{:ok, _} | {:error, _}` contract. Reproduced on this translator, the
    # Responses one, Anthropic and Gemini before the fix.
    test "ImageMime: an unreadable file returns :unresolvable_image, never a raise" do
      img = %Image{source: {:file, "/nonexistent/gone.png"}, mime_type: "image/png"}

      request =
        Request.new(
          [user_text_image("look", img)],
          model: "gpt-4o-mini"
        )

      assert {:error, %ValidationError{reason: :invalid_message, errors: errors}} =
               OpenAI.generate(request, api_key: "sk-x")

      assert {[:content, 0, 1], :unresolvable_image} in errors
    end

    # `ImageMime.validate_request/2` is wired at BOTH of this adapter's entry
    # points — `generate/2` and `stream/2` — and each needs its own case: the
    # `with` chains are separate and deleting the clause from one leaves the
    # other green. (Both OpenAI endpoints, Chat Completions and Responses, are
    # covered by these two: the gate runs ahead of endpoint dispatch, so a
    # request carrying `endpoint: :responses` is rejected by the same clause and
    # a separate case for it would pass without exercising anything new.)
    test "ImageMime: stream/2 carries the same gate as generate/2" do
      img = %Image{source: {:file, "/nonexistent/gone.png"}, mime_type: "image/png"}

      request =
        Request.new(
          [user_text_image("look", img)],
          model: "gpt-4o-mini"
        )

      assert {:error, %ValidationError{reason: :invalid_message, errors: errors}} =
               OpenAI.stream(request, api_key: "sk-x")

      assert {[:content, 0, 1], :unresolvable_image} in errors
    end

    # The gate, NOT the translator, is what holds this — `to_openai_messages/1`
    # and `to_responses_input/1` still resolve bytes with a hard match and still
    # raise if called directly on an unresolvable image. That is the same
    # position `ALLM.Providers.OpenAI.Moderation` takes and it is deliberate:
    # the translators are total over what the gate admits, and pushing
    # `{:ok, _} | {:error, _}` through them would change every caller's shape.
    # Recorded so the gate is not "simplified" away on the belief that the
    # translator is safe on its own.
    test "the translators are total only over what the gate admits" do
      img = %Image{source: {:file, "/nonexistent/gone.png"}, mime_type: "image/png"}
      messages = [user_text_image("look", img)]

      assert_raise MatchError, fn -> OpenAI.to_openai_messages(messages) end
      assert_raise MatchError, fn -> OpenAI.to_responses_input(messages) end
    end

    test "pre-flight order: system-msg-rejection fires before MIME validation" do
      # Fixture violates two rules:
      #   - msg 0 system role with an unsupported-MIME ImagePart
      #   - msg 1 user role with another unsupported-MIME ImagePart
      # System-rejection fires first; the user-side MIME error does NOT
      # appear in the returned :errors.
      bad_img = Image.from_binary("<svg/>", "image/svg+xml")

      request =
        Request.new(
          [
            %Message{
              role: :system,
              content: [%TextPart{text: "x"}, %ImagePart{image: bad_img}]
            },
            user_text_image("y", bad_img)
          ],
          model: "gpt-4o-mini"
        )

      assert {:error, %ValidationError{reason: :invalid_message, errors: errors}} =
               OpenAI.generate(request, api_key: "sk-x")

      # First-rule wins: system-msg error is present; MIME errors are NOT
      # surfaced.
      assert Enum.any?(errors, &match?({[:messages, 0, :content], :image_in_system_message}, &1))

      refute Enum.any?(errors, &match?({[:content, _, _], :unsupported_image_format}, &1))
    end
  end

  # ---------------------------------------------------------------------------
  # Wire-fixture decode tests
  # ---------------------------------------------------------------------------

  describe "decode wire fixtures" do
    test "Chat Completions: single_image_url decodes to text response", %{stub: stub} do
      body_ok = Fx.chat_vision(:single_image_url)
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body_ok) end)

      img = Image.from_url("https://example.com/cat.png")

      request =
        Request.new([user_text_image("describe", img)], model: "gpt-4o-mini")

      assert {:ok, response} = call(stub, request)
      assert response.finish_reason == :stop
      assert response.message.content == "I can see a cat sitting on a windowsill."
    end

    test "Chat Completions: single_image_base64 decodes", %{stub: stub} do
      body_ok = Fx.chat_vision(:single_image_base64)
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body_ok) end)

      img = Image.from_base64(Base.encode64("hi"), "image/png")
      request = Request.new([user_text_image("d", img)], model: "gpt-4o-mini")

      assert {:ok, response} = call(stub, request)
      assert response.finish_reason == :stop
    end

    test "Chat Completions: multi_image decodes", %{stub: stub} do
      body_ok = Fx.chat_vision(:multi_image)
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body_ok) end)

      img1 = Image.from_url("https://example.com/a.png")
      img2 = Image.from_url("https://example.com/b.png")

      request =
        Request.new(
          [
            %Message{
              role: :user,
              content: [%TextPart{text: "x"}, %ImagePart{image: img1}, %ImagePart{image: img2}]
            }
          ],
          model: "gpt-4o-mini"
        )

      assert {:ok, response} = call(stub, request)
      assert response.finish_reason == :stop
    end

    test "Responses: single_image_url decodes", %{stub: stub} do
      body_ok = Fx.responses_vision(:single_image_url)
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body_ok) end)

      img = Image.from_url("https://example.com/cat.png")
      request = Request.new([user_text_image("d", img)], model: "gpt-5.5")

      assert {:ok, response} = call(stub, request)
      assert response.finish_reason == :stop
    end

    test "Responses: multi_image decodes", %{stub: stub} do
      body_ok = Fx.responses_vision(:multi_image)
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body_ok) end)

      img1 = Image.from_url("https://example.com/a.png")
      img2 = Image.from_url("https://example.com/b.png")

      request =
        Request.new(
          [
            %Message{
              role: :user,
              content: [%TextPart{text: "x"}, %ImagePart{image: img1}, %ImagePart{image: img2}]
            }
          ],
          model: "gpt-5.5"
        )

      assert {:ok, response} = call(stub, request)
      assert response.finish_reason == :stop
    end

    test "Synthesized assistant-image-output decodes to %Response{content: [TextPart, ImagePart]}",
         %{stub: stub} do
      body_ok = Fx.synthesized(:vision_assistant_image_output)
      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body_ok) end)

      request = Request.new([%Message{role: :user, content: "draw me a cat"}], model: "gpt-4o-mini")

      assert {:ok, response} = call(stub, request)
      assert [%TextPart{text: text}, %ImagePart{image: %Image{} = img}] = response.message.content
      assert text =~ "image"
      assert img.source == {:url, "https://example.com/result.png"}
    end
  end

  # ---------------------------------------------------------------------------
  # Streaming (request side)
  # ---------------------------------------------------------------------------

  describe "stream/2 with vision content" do
    test "stream/2 accepts an ImagePart-bearing request without pre-flight rejection" do
      img = Image.from_url("https://example.com/x.png")

      request =
        Request.new([user_text_image("hi", img)], model: "gpt-4o-mini")

      # We do NOT actually consume the stream (the stub is for non-streaming
      # only); confirm the pre-flight passes and we get a {:ok, _}
      # enumerable. The stream is lazy — no HTTP fires until reduced.
      assert {:ok, _stream} = OpenAI.stream(request, api_key: "sk-x")
    end

    test "stream/2 rejects ImagePart in system message" do
      img = Image.from_url("https://example.com/x.png")

      request =
        Request.new(
          [
            %Message{role: :system, content: [%TextPart{text: "ctx"}, %ImagePart{image: img}]},
            %Message{role: :user, content: "hi"}
          ],
          model: "gpt-4o-mini"
        )

      assert {:error, %ValidationError{reason: :invalid_message}} =
               OpenAI.stream(request, api_key: "sk-x")
    end

    test "stream/2 rejects oversize image at pre-flight" do
      bytes = :binary.copy(<<0>>, 21 * 1024 * 1024)
      img = Image.from_binary(bytes, "image/png")

      request =
        Request.new([user_text_image("hi", img)], model: "gpt-4o-mini")

      assert {:error, %ValidationError{reason: :invalid_message, errors: errors}} =
               OpenAI.stream(request, api_key: "sk-x")

      assert {[:content, 0, 1], :image_too_large} in errors
    end
  end

  # ---------------------------------------------------------------------------
  # Live test (BLOCKING /review gate; tagged :live_openai)
  # ---------------------------------------------------------------------------

  @tag :live_openai
  test "live: gpt-4o-mini against a 50 KB local PNG returns a non-empty response" do
    api_key = System.fetch_env!("OPENAI_API_KEY")

    # Generate a 50KB-ish synthetic PNG buffer (header + zeros + IEND).
    # This is NOT a valid PNG; the live test SHOULD use a real local PNG
    # if one is available, otherwise OpenAI may reject. We use a small
    # 1x1 PNG payload instead.
    one_pixel_png =
      <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 2,
        0, 0, 0, 144, 119, 83, 222, 0, 0, 0, 12, 73, 68, 65, 84, 8, 153, 99, 248, 207, 192, 0, 0, 0,
        3, 0, 1, 91, 169, 33, 76, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>

    img = Image.from_binary(one_pixel_png, "image/png")

    request =
      Request.new(
        [user_text_image("What color is the pixel?", img)],
        model: "gpt-4o-mini",
        max_tokens: 100
      )

    case OpenAI.generate(request, api_key: api_key, retry: false) do
      {:ok, response} ->
        assert response.finish_reason in [:stop, :length]
        assert is_binary(response.output_text)
        assert byte_size(response.output_text) > 0

      {:error, %AdapterError{} = err} ->
        flunk("Live OpenAI vision test failed: #{inspect(err)}")
    end
  end
end
