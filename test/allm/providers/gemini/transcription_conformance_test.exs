defmodule ALLM.Providers.Gemini.TranscriptionConformanceTest do
  @moduledoc """
  `ALLM.Test.TranscriptionAdapterConformance` invocation against
  `ALLM.Providers.Gemini.Transcription`.

  Cases 2, 5 and 6 are **[scripted]**: they pass
  `adapter_opts[:transcription_script]`, which this adapter hands to
  `ALLM.Providers.FakeTranscription.transcribe/2` (with its own cap as
  `adapter_opts[:max_audio_bytes]`) before any gate of its own runs. Cases 1,
  3 and 4 are **[unscripted]** and keyless, so they exercise this adapter's
  own `max_audio_bytes/0` and its resolvable and size gates.

  `gate_opts:` installs a plug that raises, so a gate moved after key
  resolution fails cases 3 and 4 even in a shell that exports
  `GEMINI_API_KEY` (otherwise case 4 would upload about 15 MB).

  Case 4 allocates `max_audio_bytes() + 1` bytes (about 15 MB) once per run;
  it measured well under 2 s, so it is not tagged `:slow`.

  **What this run does NOT bind.** Invariant 2 for this adapter's own
  decoder (the scripted success path never reaches `decode_response/4`; the
  decoder tests in `transcription_test.exs` and the recorded fixtures in
  `transcription_wire_test.exs` bind it). Invariant 1 is enforced at the
  façade and bound by `test/allm/allm_transcribe_test.exs`.
  """

  use ExUnit.Case, async: true

  use ALLM.Test.TranscriptionAdapterConformance,
    transcription_adapter: ALLM.Providers.Gemini.Transcription,
    gate_opts: [adapter_opts: [plug: fn _conn -> raise "gate let the request reach HTTP" end]]
end
