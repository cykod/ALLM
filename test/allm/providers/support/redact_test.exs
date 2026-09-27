defmodule ALLM.Providers.Support.RedactTest do
  use ExUnit.Case, async: true

  alias ALLM.Providers.Support.Redact

  # One planted token per provider's credential shape.
  @tokens %{
    openai: ["sk-proj-PLANTED0123", "rk-PLANTED0123", "org-PLANTED0123"],
    anthropic: ["sk-ant-api03-PLANTED0123"],
    gemini: ["AIzaPLANTED0123", "ya29.PLANTED0123"],
    voyage: ["pa-PLANTED0123"],
    elevenlabs: ["sk_PLANTED0123456789ab"]
  }

  @redactors [:openai, :anthropic, :gemini, :voyage, :elevenlabs]

  for provider <- @redactors do
    test "#{provider}/1 redacts its own provider's credential shapes" do
      for token <- @tokens[unquote(provider)] do
        assert apply(Redact, unquote(provider), ["key #{token} end"]) == "key [REDACTED] end"
      end
    end
  end

  # Companion: each pattern is the provider's own. A sibling's token passes
  # through, so a pattern copied from a sibling would fail here rather than
  # silently redact nothing. OpenAI's `sk-` pattern also matches Anthropic's
  # `sk-ant-` keys, the one overlap, so that pair is excluded.
  for provider <- @redactors,
      sibling <- @redactors,
      sibling != provider,
      {provider, sibling} != {:openai, :anthropic} do
    test "#{provider}/1 leaves a #{sibling} token alone" do
      for token <- @tokens[unquote(sibling)] do
        text = "key #{token} end"
        assert apply(Redact, unquote(provider), [text]) == text
      end
    end
  end

  test "text without a credential is returned unchanged" do
    for provider <- @redactors do
      assert apply(Redact, provider, ["Rate limit exceeded."]) == "Rate limit exceeded."
    end
  end

  test "a short prefix-only token is not redacted" do
    assert Redact.openai("sk-abc") == "sk-abc"
    assert Redact.elevenlabs("sk_short") == "sk_short"
  end
end
