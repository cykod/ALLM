defmodule ALLM.Providers.ElevenLabs.TranscriptionConformanceTest do
  @moduledoc """
  `ALLM.Test.TranscriptionAdapterConformance` and
  `ALLM.Test.TranscriptionStreamAdapterConformance` invocations against
  `ALLM.Providers.ElevenLabs.Transcription`.

  Cases 2, 5 and 6 are **[scripted]**: they pass
  `adapter_opts[:transcription_script]`, which this adapter hands to
  `ALLM.Providers.FakeTranscription.transcribe/2` (with its own cap as
  `adapter_opts[:max_audio_bytes]`) before any gate of its own runs. Cases 1
  and 3 are **[unscripted]** and keyless, so they exercise this adapter's own
  `max_audio_bytes/0` and its resolvable gate (case 4, the size gate, is
  skipped here; see below).

  `gate_opts:` installs a plug that raises, so a gate moved after key
  resolution fails case 3 even in a shell that exports
  `ELEVENLABS_API_KEY`.

  **Case 4 is skipped here (owner decision, 2026-09-27).** The suite sizes
  its oversized clip from the adapter's own cap, and ElevenLabs' cap is
  `4_999_999_999` bytes ("less than 5.0GB"), so the case allocated 5 GB and
  took about 22 s per `mix test` (measured 2026-09-26: 22.1 s, peak RSS
  about 4.99 GB). The cap stays 5 GB and the case stays in the harness for
  every other adapter. The size gate itself is bound cheaply in
  `transcription_test.exs` ("audio over max_audio_bytes/0 ..."), which
  measures a sparse file one byte over the cap. Do not re-add the case here
  without a smaller way to build the oversized clip.

  **What these runs do NOT bind.** The adapter's own decoder (the scripted
  success path never reaches `decode_response/4`); the decoder tests in
  `transcription_test.exs` and the recorded fixtures in
  `transcription_wire_test.exs` bind it. The realtime path's halt-safety,
  `:stream_timeout`, frame handling and end-of-input commit: the scripted
  stream cases hand off to `ALLM.Providers.FakeTranscription` before the
  socket, so `transcription_stream_test.exs` binds them.
  """

  use ExUnit.Case, async: true

  # OWNER DECISION 2026-09-27: case 4 is skipped for this adapter only. Its
  # oversize clip is max_audio_bytes() + 1 = 5 GB of memory and ~22 s per
  # run. The size gate is bound by a sparse-file test in
  # transcription_test.exs instead. Do not remove this skip.
  use ALLM.Test.TranscriptionAdapterConformance,
    transcription_adapter: ALLM.Providers.ElevenLabs.Transcription,
    gate_opts: [adapter_opts: [plug: fn _conn -> raise "gate let the request reach HTTP" end]],
    skip_cases: %{
      4 =>
        "owner decision 2026-09-27: a 5 GB cap makes the oversize clip cost 5 GB of memory; " <>
          "the size gate is bound by a sparse-file test in transcription_test.exs"
    }

  # All six cases run for the realtime path. Its [unscripted] cases are
  # keyless and pass a transport that raises, so a gate moved after key
  # resolution, or into the stream, fails even with ELEVENLABS_API_KEY set.
  use ALLM.Test.TranscriptionStreamAdapterConformance,
    transcription_adapter: ALLM.Providers.ElevenLabs.Transcription,
    gate_opts: [ws_module: ALLM.Test.RaisingWebSocket]
end
