defmodule ALLM.Providers.Gemini.ImagesTranslatorParityTest do
  @moduledoc """
  Phase 16.5 byte-equal request-builder parity test.

  Witnesses Decision #7 — `Gemini.Images.generate/2` reuses
  `Gemini.to_gemini_request_body/2` (the single chat translator). The
  parity test asserts the image and chat request bodies are byte-equal
  modulo the `responseModalities` override.

  Also pins the cross-function invariant per `steering/GEMINI_DESIGN.md`
  lines 217-219: a response containing both text AND inlineData parts
  decodes consistently via `Gemini.Decode.candidate_parts/1` regardless
  of which entry point calls into it.
  """
  use ExUnit.Case, async: true

  alias ALLM.{Image, ImagePart, ImageRequest, Message, Request, TextPart}
  alias ALLM.Providers.Gemini
  alias ALLM.Providers.Gemini.Decode
  alias ALLM.Providers.Gemini.Images
  alias ALLM.Providers.GeminiTestFixtures, as: Fx

  describe ":generate parity — byte-equal request body modulo responseModalities" do
    test "single-prompt :generate body == chat body (gen_config minus responseModalities)" do
      prompt = "a kestrel in flight"
      model = "gemini-3.1-flash-image-preview"

      img_req =
        ImageRequest.new(
          operation: :generate,
          prompt: prompt,
          model: model
        )

      chat_req =
        Request.new(
          [%Message{role: :user, content: prompt}],
          model: model
        )

      assert {:ok, img_body} = Images.to_image_request_body(img_req, [])
      chat_body = Gemini.to_gemini_request_body(chat_req, [])

      # Contents must be byte-equal — same prompt, same role, same single text part.
      assert img_body["contents"] == chat_body["contents"]

      # Modulo: image adds responseModalities into generationConfig.
      img_gc = img_body["generationConfig"] || %{}
      chat_gc = chat_body["generationConfig"] || %{}

      assert Map.delete(img_gc, "responseModalities") == chat_gc
      assert img_gc["responseModalities"] == ["TEXT", "IMAGE"]

      # Top-level keys outside generationConfig must agree exactly.
      assert Map.delete(img_body, "generationConfig") == Map.delete(chat_body, "generationConfig")
    end
  end

  describe ":edit parity — byte-equal request body modulo responseModalities" do
    test ":edit body == chat body for [TextPart + ImagePart] content (Phase 16.4 part_to_block reuse)" do
      prompt = "make it red"
      model = "gemini-3.1-flash-image-preview"
      src_img = Image.from_binary(<<137, 80, 78, 71>>, "image/png")

      img_req =
        ImageRequest.new(
          operation: :edit,
          prompt: prompt,
          model: model,
          input_images: [src_img]
        )

      chat_req =
        Request.new(
          [
            %Message{
              role: :user,
              content: [
                %TextPart{text: prompt},
                %ImagePart{image: src_img, detail: :auto}
              ]
            }
          ],
          model: model
        )

      assert {:ok, img_body} = Images.to_image_request_body(img_req, [])
      chat_body = Gemini.to_gemini_request_body(chat_req, [])

      # `contents` must be byte-equal — pins that Images.generate/2 routes
      # source-image translation through Gemini.part_to_block/1 (Phase 16.4)
      # rather than re-implementing the inlineData encoding.
      assert img_body["contents"] == chat_body["contents"]

      img_gc = img_body["generationConfig"] || %{}
      chat_gc = chat_body["generationConfig"] || %{}

      assert Map.delete(img_gc, "responseModalities") == chat_gc
      assert img_gc["responseModalities"] == ["TEXT", "IMAGE"]
    end
  end

  describe "shared response decoder — Gemini.Decode.candidate_parts/1" do
    test "fixture with both text and inlineData parts decodes the same tuple regardless of caller" do
      # Use the synthesized 16.5 fixture with mixed parts.
      body = Fx.synthesized(:image_text_and_image)
      [candidate] = body["candidates"]

      {text, tool_calls, image_parts, raw_finish} = Decode.candidate_parts(candidate)

      assert text == "Here is your image:"
      assert tool_calls == []
      assert raw_finish == "STOP"
      assert [%ImagePart{image: %Image{source: {:binary, _}, mime_type: "image/png"}}] = image_parts
    end

    test "candidate with only inlineData → text is nil and tool_calls is empty" do
      body = Fx.synthesized(:image_single)
      [candidate] = body["candidates"]

      {text, tool_calls, image_parts, _raw_finish} = Decode.candidate_parts(candidate)

      assert text == nil
      assert tool_calls == []
      assert length(image_parts) == 1
    end

    test "inlineData with invalid base64 is dropped (returns nil from decoder)" do
      candidate = %{
        "content" => %{
          "parts" => [
            %{"inlineData" => %{"mimeType" => "image/png", "data" => "not!base64!"}}
          ]
        }
      }

      {_text, _tool_calls, image_parts, _raw_finish} = Decode.candidate_parts(candidate)
      assert image_parts == []
    end

    test "inlineData missing mimeType is dropped" do
      candidate = %{
        "content" => %{
          "parts" => [
            %{"inlineData" => %{"data" => "aGk="}}
          ]
        }
      }

      {_text, _tool_calls, image_parts, _raw_finish} = Decode.candidate_parts(candidate)
      assert image_parts == []
    end

    test "unknown part shapes are silently skipped" do
      candidate = %{
        "content" => %{
          "parts" => [
            %{"someUnknownPart" => %{"foo" => "bar"}},
            %{"text" => "kept"}
          ]
        }
      }

      {text, _tool_calls, _image_parts, _raw_finish} = Decode.candidate_parts(candidate)
      assert text == "kept"
    end

    test "decode_function_call with no name and no id falls back to empty id" do
      tc = Decode.decode_function_call(%{"args" => %{"x" => 1}})
      assert tc.id == ""
      assert tc.name == ""
      assert tc.arguments == %{"x" => 1}
    end

    test "decode_function_call with non-map args coerces to %{}" do
      tc = Decode.decode_function_call(%{"name" => "f", "args" => "not a map"})
      assert tc.arguments == %{}
    end

    test "Gemini.generate/2's chat decode path returns content text matching candidate_parts/1" do
      # The chat path's Response.content should equal the text element
      # from Gemini.Decode.candidate_parts/1's tuple, witnessing the
      # shared-helper invariant.
      body = Fx.generate_content(:happy_text)
      [candidate] = body["candidates"]

      {text, _tool_calls, _image_parts, _raw_finish} = Decode.candidate_parts(candidate)

      response = Gemini.decode_response(body, [])
      assert response.output_text == text
    end
  end
end
