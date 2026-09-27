defmodule ALLM.Providers.ElevenLabs.SpeechConformanceTest do
  @moduledoc """
  `ALLM.Test.SpeechAdapterConformance`, `ALLM.Test.SpeechStreamAdapterConformance`
  and `ALLM.Test.SpeechInputStreamAdapterConformance` invocations against
  `ALLM.Providers.ElevenLabs.Speech`.

  The **[scripted]** cases pass `adapter_opts[:speech_script]`, which this
  adapter hands to `ALLM.Providers.FakeSpeech` before any gate of its own
  runs. The **[unscripted]** cases are keyless, so they exercise this
  adapter's own gates, which must fire before `ALLM.Keys.fetch!/2`.

  Each suite's `gate_opts:` installs a transport seam that raises: a `Req`
  plug for `synthesize/2`, `ALLM.Test.RaisingFinch` for the HTTP stream and
  `ALLM.Test.RaisingWebSocket` for the WebSocket input stream. A gate moved
  after key resolution, or into the stream, then fails its case even in a
  shell that exports `ELEVENLABS_API_KEY`.

  **What these runs do NOT bind.** The adapter's own decoders, halt-safety
  and `:stream_timeout`: the scripted cases never reach the transport.
  `speech_test.exs`, `speech_wire_test.exs` and `speech_stream_test.exs`
  bind them.
  """

  use ExUnit.Case, async: true

  alias ALLM.Test.{RaisingFinch, RaisingWebSocket}

  use ALLM.Test.SpeechAdapterConformance,
    speech_adapter: ALLM.Providers.ElevenLabs.Speech,
    gate_opts: [adapter_opts: [plug: fn _conn -> raise "gate let the request reach HTTP" end]]

  use ALLM.Test.SpeechStreamAdapterConformance,
    speech_adapter: ALLM.Providers.ElevenLabs.Speech,
    gate_opts: [finch_module: RaisingFinch]

  use ALLM.Test.SpeechInputStreamAdapterConformance,
    speech_adapter: ALLM.Providers.ElevenLabs.Speech,
    gate_opts: [ws_module: RaisingWebSocket]
end
