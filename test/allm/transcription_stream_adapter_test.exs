defmodule ALLM.TranscriptionStreamAdapterTest do
  @moduledoc """
  Certifies `ALLM.Providers.FakeTranscription` — the reference
  implementation — against the published transcription stream suite, and
  pins the behaviour's callback surface.
  """

  use ExUnit.Case, async: true

  use ALLM.Test.TranscriptionStreamAdapterConformance,
    transcription_adapter: ALLM.Providers.FakeTranscription

  alias ALLM.Providers.FakeTranscription
  alias ALLM.TranscriptionStreamAdapter

  describe "callback surface" do
    test "declares exactly stream_transcribe/3 and stream_sample_rates/0" do
      assert Enum.sort(TranscriptionStreamAdapter.behaviour_info(:callbacks)) ==
               [stream_sample_rates: 0, stream_transcribe: 3]
    end

    test "has no optional callbacks" do
      assert TranscriptionStreamAdapter.behaviour_info(:optional_callbacks) == []
    end

    test "a module implementing both callbacks compiles without warning" do
      source = """
      defmodule ALLM.TranscriptionStreamAdapterTest.MinimalImpl do
        @behaviour ALLM.TranscriptionStreamAdapter

        @impl true
        def stream_sample_rates, do: [16_000]

        @impl true
        def stream_transcribe(_request, _audio, _opts), do: {:ok, []}
      end
      """

      {[{minimal_impl, _bytecode}], captured} =
        ExUnit.CaptureIO.with_io(:stderr, fn -> Code.compile_string(source) end)

      assert captured == ""
      assert minimal_impl.stream_sample_rates() == [16_000]
    end
  end

  describe "FakeTranscription implements the behaviour" do
    test "declares @behaviour ALLM.TranscriptionStreamAdapter alongside ALLM.TranscriptionAdapter" do
      behaviours =
        FakeTranscription.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert TranscriptionStreamAdapter in behaviours
      assert ALLM.TranscriptionAdapter in behaviours
    end
  end
end
