defmodule ALLM.Providers.OpenAI.SpeechConformanceTest do
  @moduledoc """
  `ALLM.Test.SpeechAdapterConformance` invocation against
  `ALLM.Providers.OpenAI.Speech`.

  Cases 1–3, 5 and 6 are **[scripted]**: they pass
  `adapter_opts[:speech_script]`, which this adapter hands to
  `ALLM.Providers.FakeSpeech.synthesize/2` before any gate of its own runs.
  Case 4 is **[unscripted]** and keyless, so it exercises this adapter's own
  empty-input gate, which must fire before `ALLM.Keys.fetch!/2`.

  `gate_opts:` installs a plug that raises, so a gate moved after key
  resolution fails case 4 even in a shell that exports `OPENAI_API_KEY`
  (otherwise the provider's own 400 would pass it).

  **What this run does NOT bind.** Invariants 2 and 3 (audio shape and
  `:format` membership) for this adapter's own decoder: the scripted success
  path never reaches `decode_response/4`. Those are bound by the decoder tests
  in `speech_test.exs` and the recorded fixtures in `speech_wire_test.exs`.
  Invariant 1 is enforced at the façade and bound by
  `test/allm/allm_synthesize_test.exs`.
  """

  use ExUnit.Case, async: true

  use ALLM.Test.SpeechAdapterConformance,
    speech_adapter: ALLM.Providers.OpenAI.Speech,
    gate_opts: [adapter_opts: [plug: fn _conn -> raise "gate let the request reach HTTP" end]]
end
