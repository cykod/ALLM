defmodule ALLM.TranscriptionAdapterTest do
  @moduledoc """
  Certifies `ALLM.Providers.FakeTranscription` — the reference
  implementation — against the published
  `ALLM.Test.TranscriptionAdapterConformance` suite, and pins the behaviour's
  callback surface.
  """

  use ExUnit.Case, async: true

  use ALLM.Test.TranscriptionAdapterConformance,
    transcription_adapter: ALLM.Providers.FakeTranscription

  alias ALLM.Providers.FakeTranscription
  alias ALLM.TranscriptionAdapter

  describe "callback surface" do
    test "declares exactly transcribe/2, max_audio_bytes/0 and prepare_request/2" do
      assert Enum.sort(TranscriptionAdapter.behaviour_info(:callbacks)) ==
               [max_audio_bytes: 0, prepare_request: 2, transcribe: 2]
    end

    test "prepare_request/2 is the only optional callback" do
      assert TranscriptionAdapter.behaviour_info(:optional_callbacks) == [prepare_request: 2]
    end

    test "a module implementing only transcribe/2 + max_audio_bytes/0 compiles without warning" do
      source = """
      defmodule ALLM.TranscriptionAdapterTest.MinimalImpl do
        @behaviour ALLM.TranscriptionAdapter

        @impl true
        def transcribe(_request, _opts), do: {:ok, %ALLM.TranscriptionResponse{}}

        @impl true
        def max_audio_bytes, do: 2048
      end
      """

      {[{minimal_impl, _bytecode}], captured} =
        ExUnit.CaptureIO.with_io(:stderr, fn -> Code.compile_string(source) end)

      assert captured == ""
      assert minimal_impl.max_audio_bytes() == 2048
    end
  end

  describe "FakeTranscription implements the behaviour" do
    test "declares @behaviour ALLM.TranscriptionAdapter" do
      behaviours =
        FakeTranscription.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert TranscriptionAdapter in behaviours
    end
  end
end
