defmodule ALLM.Providers.GeminiConformanceTest do
  @moduledoc """
  Phase 16.6 — `ALLM.Test.ImageAdapterConformance` invocation against
  `ALLM.Providers.Gemini.Images`, plus targeted assertions on
  `supported_operations/0` and `:variation` rejection per design lines
  566–567.

  ## Why the chat-adapter conformance is NOT wired here

  The Phase 16.6 design names `ALLM.Test.AdapterConformance` and
  `ALLM.Test.StreamAdapterConformance` against `ALLM.Providers.Gemini` as
  in-scope. In practice both harnesses drive the adapter via
  `adapter_opts[:script]` — a test-injection seam present on
  `ALLM.Providers.Fake` (and on `ALLM.Providers.Gemini.Images` via
  `:image_script`) but NOT on `ALLM.Providers.Gemini`'s chat path. The
  same constraint applies to OpenAI and Anthropic, which is why neither
  ships `*_conformance_test.exs` files invoking those harnesses against
  the real chat adapter (only `OpenAI.Images` is wired today, mirroring
  this file's pattern).

  Running `use ALLM.Test.AdapterConformance, adapter: ALLM.Providers.Gemini`
  here would attempt live network calls with placeholder keys for every
  case — not deterministic. The deterministic chat-shape coverage lives
  in `test/allm/providers/gemini_test.exs`, `gemini_stream_test.exs`,
  `gemini_tools_test.exs`, `gemini_vision_test.exs`, and the wire-pin
  tests. Live coverage lives in `test/allm/providers/gemini_live_test.exs`
  (`@moduletag :live_gemini`).
  """

  use ExUnit.Case, async: true
  use ALLM.Test.ImageAdapterConformance, image_adapter: ALLM.Providers.Gemini.Images

  alias ALLM.Error.ImageAdapterError
  alias ALLM.ImageRequest
  alias ALLM.Providers.Gemini.Images

  describe "Gemini.Images supported_operations contract" do
    test "supported_operations/0 returns [:generate, :edit] (no :variation)" do
      assert Images.supported_operations() == [:generate, :edit]
    end

    test ":variation is rejected with %ImageAdapterError{reason: :unsupported_operation}" do
      # Uses a 1×1 transparent PNG as the input image (matches the
      # ImageAdapterConformance harness's variation-case fixture shape).
      png_bytes = <<137, 80, 78, 71, 13, 10, 26, 10>>

      base = ALLM.Image.from_binary(png_bytes, "image/png")

      req = ImageRequest.new(operation: :variation, prompt: nil, input_images: [base])

      assert {:error, %ImageAdapterError{reason: :unsupported_operation}} =
               Images.generate(req, adapter_opts: [api_key: "test-key"])
    end
  end
end
