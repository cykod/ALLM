defmodule ALLM.Providers.OpenAI.ImagesConformanceTest do
  @moduledoc """
  `ALLM.Test.ImageAdapterConformance` invocation against
  `ALLM.Providers.OpenAI.Images`.

  Per Phase 15.1 design Decision #20 / Invariant 0, all 9 conformance
  cases pass at this sub-phase via the
  `adapter_opts[:image_script]` test-injection short-circuit — the
  adapter delegates to `ALLM.Providers.FakeImages.generate/2` BEFORE any
  pre-flight gate runs when that key is present. Cases that pass an
  unsupported operation through the harness's `GenerateOnlyImageStub`
  branch are unaffected by this adapter's gates.

  See `conformance/lib/allm/test/image_adapter_conformance.ex` for the
  9-case harness.
  """

  use ExUnit.Case, async: true
  use ALLM.Test.ImageAdapterConformance, image_adapter: ALLM.Providers.OpenAI.Images
end
