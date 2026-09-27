defmodule ALLM.Providers.Support.Redact do
  @moduledoc """
  Per-provider credential redactors shared by the bundled adapters.

  Layer B helper. Each function replaces the credential shapes of ONE
  provider with `[REDACTED]` in a provider-authored string (an error
  message, an error code, a block reason) before it reaches an error
  struct. The patterns are deliberately separate: a pattern borrowed from
  a sibling provider matches nothing in the other provider's text, so it
  would redact nothing without failing. Every adapter of a provider calls
  that provider's function here instead of carrying its own copy of the
  pattern.

  Each function takes a binary. An adapter that can see a non-binary
  value keeps its own fallback clause in front of the call.

  The functions are `@doc false` seams with a `@spec`: callable from tests,
  not part of the public API.
  """

  @redacted "[REDACTED]"

  @doc false
  # OpenAI: `sk-` (including `sk-proj-`) and `rk-` keys, and `org-` ids.
  # OpenAI's 401 text echoes a prefix of the key it rejected.
  @spec openai(String.t()) :: String.t()
  def openai(text) when is_binary(text),
    do: String.replace(text, ~r/\b(?:sk|rk|org)-[A-Za-z0-9_\-]{6,}/, @redacted)

  @doc false
  # Anthropic: `sk-ant-` keys (`sk-ant-api03-…`, `sk-ant-admin01-…`).
  # Narrower than the OpenAI `sk-` pattern on purpose.
  @spec anthropic(String.t()) :: String.t()
  def anthropic(text) when is_binary(text),
    do: String.replace(text, ~r/\bsk-ant-[A-Za-z0-9_\-]{6,}/, @redacted)

  @doc false
  # Google (Gemini): `AIza…` API keys and `ya29.…` OAuth access tokens.
  @spec gemini(String.t()) :: String.t()
  def gemini(text) when is_binary(text) do
    String.replace(
      text,
      ~r/\b(?:AIza[A-Za-z0-9_\-]{6,}|ya29\.[A-Za-z0-9_\-.]{6,})/,
      @redacted
    )
  end

  @doc false
  # Voyage: `pa-` keys. Voyage's 401 text does not echo the key; this is
  # defence in depth for untrusted provider prose.
  @spec voyage(String.t()) :: String.t()
  def voyage(text) when is_binary(text),
    do: String.replace(text, ~r/\bpa-[A-Za-z0-9_\-]{6,}/, @redacted)

  @doc false
  # ElevenLabs: `sk_` followed by at least 16 alphanumerics. ElevenLabs'
  # error bodies did not echo the key when recorded; defence in depth.
  @spec elevenlabs(String.t()) :: String.t()
  def elevenlabs(text) when is_binary(text),
    do: String.replace(text, ~r/\bsk_[A-Za-z0-9]{16,}/, @redacted)
end
