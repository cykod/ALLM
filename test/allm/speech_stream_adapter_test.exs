defmodule ALLM.SpeechStreamAdapterTest do
  @moduledoc """
  Certifies `ALLM.Providers.FakeSpeech` — the reference implementation —
  against both published speech stream suites, and pins the behaviour's
  callback surface.
  """

  use ExUnit.Case, async: true
  use ALLM.Test.SpeechStreamAdapterConformance, speech_adapter: ALLM.Providers.FakeSpeech
  use ALLM.Test.SpeechInputStreamAdapterConformance, speech_adapter: ALLM.Providers.FakeSpeech

  alias ALLM.Providers.FakeSpeech
  alias ALLM.SpeechStreamAdapter

  describe "callback surface" do
    test "declares exactly stream_synthesize/2 and stream_synthesize_input/3" do
      assert Enum.sort(SpeechStreamAdapter.behaviour_info(:callbacks)) ==
               [stream_synthesize: 2, stream_synthesize_input: 3]
    end

    test "stream_synthesize_input/3 is the only optional callback" do
      assert SpeechStreamAdapter.behaviour_info(:optional_callbacks) ==
               [stream_synthesize_input: 3]
    end

    test "a module implementing only stream_synthesize/2 compiles without warning" do
      source = """
      defmodule ALLM.SpeechStreamAdapterTest.MinimalImpl do
        @behaviour ALLM.SpeechStreamAdapter

        @impl true
        def stream_synthesize(_request, _opts), do: {:ok, []}
      end
      """

      {[{minimal_impl, _bytecode}], captured} =
        ExUnit.CaptureIO.with_io(:stderr, fn -> Code.compile_string(source) end)

      assert captured == ""
      assert {:ok, []} = minimal_impl.stream_synthesize(nil, [])
    end
  end

  describe "FakeSpeech implements the behaviour" do
    test "declares @behaviour ALLM.SpeechStreamAdapter alongside ALLM.SpeechAdapter" do
      behaviours =
        FakeSpeech.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert SpeechStreamAdapter in behaviours
      assert ALLM.SpeechAdapter in behaviours
    end
  end
end
