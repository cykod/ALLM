defmodule ALLM.Providers.OpenAI.SpeechStreamConformanceTest do
  @moduledoc """
  `ALLM.Test.SpeechStreamAdapterConformance` invocation against
  `ALLM.Providers.OpenAI.Speech`.

  Cases 1–3, 5 and 6 are **[scripted]**: they pass
  `adapter_opts[:speech_script]`, which this adapter hands to
  `ALLM.Providers.FakeSpeech.stream_synthesize/2` before any gate of its own
  runs. Case 4 is **[unscripted]** and keyless, so it exercises this
  adapter's own empty-input gate, which must fire before
  `ALLM.Keys.fetch!/2`.

  `gate_opts:` passes a `:finch_module` that raises, so a gate moved after
  key resolution or into the stream fails case 4 even in a shell that
  exports `OPENAI_API_KEY`.

  Only the speech stream suite runs: OpenAI's text-in streaming is a
  different API, so this adapter does not export the optional
  `stream_synthesize_input/3` and `ALLM.Test.SpeechInputStreamAdapterConformance`
  does not apply. The test below pins that.

  **What this run does NOT bind.** Halt-safety, `:stream_timeout` and the
  adapter's own event decoding: the scripted cases never reach the
  transport. Those are bound by `speech_stream_test.exs`.
  """

  use ExUnit.Case, async: true

  alias ALLM.Test.RaisingFinch

  use ALLM.Test.SpeechStreamAdapterConformance,
    speech_adapter: ALLM.Providers.OpenAI.Speech,
    gate_opts: [finch_module: RaisingFinch]

  test "OpenAI.Speech does not export the optional input callback" do
    assert Code.ensure_loaded?(ALLM.Providers.OpenAI.Speech)
    assert function_exported?(ALLM.Providers.OpenAI.Speech, :stream_synthesize, 2)
    refute function_exported?(ALLM.Providers.OpenAI.Speech, :stream_synthesize_input, 3)
  end
end
