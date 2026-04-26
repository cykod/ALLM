defmodule ALLM.Providers.OpenAILiveTest do
  @moduledoc """
  Live OpenAI provider smoke tests (`@moduletag :live_openai`).

  Excluded by default in `test/test_helper.exs`. Opt-in via:

      OPENAI_API_KEY=sk-... mix test --include live_openai \\
        test/allm/providers/openai_live_test.exs

  Per Phase 10 design Decision #10, when `OPENAI_API_KEY` is unset the entire
  module is skipped (rather than failing) so opportunistic local runs do not
  fail noisily.
  """
  use ExUnit.Case, async: false

  @moduletag :live_openai

  if System.get_env("OPENAI_API_KEY") in [nil, ""] do
    @moduletag :skip
  end

  alias ALLM.Providers.OpenAI

  test "Phase 10.6: gpt-5.5 with reasoning_effort: :low populates Usage.reasoning_tokens" do
    # `:minimal` was removed from `@effort_atoms` after Phase 10.5 live
    # validation surfaced `Unsupported value: 'minimal' is not supported with
    # the 'gpt-5.5' model`. `:low` is the cheapest legal effort on the model.
    engine =
      ALLM.Engine.new(
        adapter: OpenAI,
        model: "gpt-5.5",
        params: %{reasoning_effort: :low}
      )

    request =
      ALLM.request(
        [ALLM.user("What is 2+2? Answer with one digit.")],
        max_tokens: 50
      )

    {:ok, response} = ALLM.generate(engine, request)

    # Trivial questions may yield 0 reasoning tokens; the field must be
    # populated (not nil) per Phase 10.6 Test Plan.
    assert is_integer(response.usage.reasoning_tokens)
    assert response.usage.reasoning_tokens >= 0
  end
end
