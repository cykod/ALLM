defmodule ALLM.Providers.OpenAI.ModerationConformanceTest do
  @moduledoc """
  `ALLM.Test.ModerationAdapterConformance` invocation against
  `ALLM.Providers.OpenAI.Moderation`.

  Eight of the ten cases drive the adapter through the
  `adapter_opts[:moderation_script]` test-injection short-circuit, which
  delegates to `ALLM.Providers.FakeModeration.moderate/2` BEFORE any pre-flight
  gate runs. Cases 3 and 4 pass no script and therefore assert against this
  adapter's own `:batch_too_large` / `:invalid_request` gates — which is why
  those gates must fire ahead of `ALLM.Keys.fetch!/2`, so a keyless CI
  environment still observes the rejection rather than
  `%ALLM.Error.EngineError{reason: :missing_key}`.

  **What this run does and does not bind for this adapter.**

    * **Binds:** invariants 1, 5 and 6 — `max_batch_size/0`'s shape and both
      pre-flight gates, all three evaluated inside
      `ALLM.Providers.OpenAI.Moderation` itself.
    * **Does not bind:** invariants 3, 4, 7 and 8. The scripted success path
      returns the harness's own `%ALLM.ModerationResult{}` values verbatim and
      never reaches this adapter's `decode_response/4`, so a green run here is
      not evidence that the OpenAI decoder indexes or round-trips its response
      correctly. Those are bound instead by the `decode_response/4` fixture
      tests in `test/allm/providers/openai/moderation_test.exs` and the
      end-to-end fixtures in
      `test/allm/providers/openai/moderation_wire_test.exs`.
    * **Cannot bind:** invariant 2. Its enforcement lives at the façade
      (`ALLM.moderate/3` raises `ArgumentError`), not inside any adapter. It is
      bound by `test/allm/allm_moderate_test.exs`.
    * **Case 10 (multimodal) is bound only as far as the script short-circuit
      reaches** — image translation lands in Phase 22.5.
  """

  use ExUnit.Case, async: true

  use ALLM.Test.ModerationAdapterConformance,
    moderation_adapter: ALLM.Providers.OpenAI.Moderation
end
