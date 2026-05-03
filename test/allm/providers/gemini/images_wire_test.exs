defmodule ALLM.Providers.Gemini.ImagesWireTest do
  @moduledoc """
  Phase 16.5 recorded-response decode tests for `Gemini.Images.generate/2`.

  Pins the `inlineData` decode path against drift. The fixtures live
  under `test/fixtures/gemini/synthesized/image_*.json` (recorded
  variants land when `scripts/record_gemini_chat_fixtures.exs` runs
  against a live image-preview model in Phase 16.6).
  """
  use ExUnit.Case, async: false

  alias ALLM.{Image, ImageRequest, ImageResponse}
  alias ALLM.Providers.Gemini.Images
  alias ALLM.Providers.GeminiTestFixtures, as: Fx

  setup do
    on_exit(fn -> ALLM.Keys.delete(:gemini) end)
    :ok
  end

  defp call(stub_name, body, request) do
    stub = String.to_atom("img_wire_#{stub_name}_#{System.unique_integer([:positive])}")

    Req.Test.stub(stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)

    ALLM.Keys.put(:gemini, "AIza-wire-test")

    Images.generate(request,
      retry: false,
      adapter_opts: [plug: {Req.Test, stub}]
    )
  end

  defp gen_request(opts \\ []) do
    ImageRequest.new(
      Keyword.merge(
        [
          operation: :generate,
          prompt: "test",
          model: "gemini-3.1-flash-image-preview"
        ],
        opts
      )
    )
  end

  describe "image_single fixture" do
    test "decodes one inlineData candidate to one %Image{}" do
      assert {:ok, %ImageResponse{} = resp} =
               call(:single, Fx.synthesized(:image_single), gen_request())

      assert [%Image{source: {:binary, bytes}, mime_type: "image/png"}] = resp.images
      assert byte_size(bytes) == 8
      assert resp.usage.images == 1
      assert resp.metadata.model_version == "gemini-3.1-flash-image-preview"
    end
  end

  describe "image_text_and_image fixture" do
    test "extracts the image part and ignores the text part for response.images" do
      assert {:ok, %ImageResponse{images: [%Image{} = img]}} =
               call(:mixed, Fx.synthesized(:image_text_and_image), gen_request())

      assert img.mime_type == "image/png"
      assert match?({:binary, _}, img.source)
    end
  end

  describe "image_n2 fixture" do
    test "decodes both candidates' inlineData parts in order" do
      assert {:ok, %ImageResponse{images: imgs}} =
               call(:n2, Fx.synthesized(:image_n2), gen_request(n: 2))

      assert length(imgs) == 2
      assert Enum.all?(imgs, &match?(%Image{source: {:binary, _}}, &1))
      # Distinct base64 inputs in the fixture → distinct decoded byte tails.
      [%Image{source: {:binary, b1}}, %Image{source: {:binary, b2}}] = imgs
      refute b1 == b2
    end
  end

  describe "image_blocked fixture (promptFeedback.blockReason)" do
    test "surfaces {:error, %ImageAdapterError{reason: :content_filter}}" do
      assert {:error, %ALLM.Error.ImageAdapterError{reason: :content_filter} = err} =
               call(:blocked, Fx.synthesized(:image_blocked), gen_request())

      assert err.metadata.block_reason == "SAFETY"
    end
  end
end
