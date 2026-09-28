defmodule ALLM.Providers.TypeSafe.ClassificationConformanceTest do
  @moduledoc """
  `ALLM.Test.ClassificationAdapterConformance` invocation against
  `ALLM.Providers.TypeSafe.Classification`.

  Eight of the nine cases pass `adapter_opts[:classification_script]`, which
  this adapter short-circuits to `ALLM.Providers.FakeClassification` before
  any gate runs. Case 6 passes no script and no key, so it exercises this
  adapter's own empty-questions gate — which is why that gate must run ahead
  of `ALLM.Keys.fetch!/2`.

  **This suite does not bind invariants 2–5 for this adapter.** The scripted
  cases answer from the Fake and never reach `decode_response/4`; the decoder
  is bound by the recorded-fixture tests in `classification_test.exs`. The
  gate-before-key ordering is bound there too, with the key env var unset.
  Invariant 8 (timeouts) is bound by the `prepare_request/2` test.
  """

  use ExUnit.Case, async: true

  use ALLM.Test.ClassificationAdapterConformance,
    classification_adapter: ALLM.Providers.TypeSafe.Classification
end
