defmodule ALLM.SpeechAdapterTest do
  @moduledoc """
  Certifies `ALLM.Providers.FakeSpeech` — the reference implementation —
  against the published `ALLM.Test.SpeechAdapterConformance` suite, and pins
  the behaviour's callback surface.
  """

  use ExUnit.Case, async: true
  use ALLM.Test.SpeechAdapterConformance, speech_adapter: ALLM.Providers.FakeSpeech

  alias ALLM.Providers.FakeSpeech
  alias ALLM.SpeechAdapter

  describe "callback surface" do
    test "declares exactly synthesize/2 and prepare_request/2" do
      assert Enum.sort(SpeechAdapter.behaviour_info(:callbacks)) ==
               [prepare_request: 2, synthesize: 2]
    end

    test "prepare_request/2 is the only optional callback" do
      assert SpeechAdapter.behaviour_info(:optional_callbacks) == [prepare_request: 2]
    end

    test "a module implementing only synthesize/2 compiles without warning" do
      source = """
      defmodule ALLM.SpeechAdapterTest.MinimalImpl do
        @behaviour ALLM.SpeechAdapter

        @impl true
        def synthesize(_request, _opts), do: {:ok, %ALLM.SpeechResponse{}}
      end
      """

      # `with_io/2` binds the compiled module from `compile_string/1`'s
      # return, so no alias to the not-yet-compiled module leaks a deferred
      # undefined-remote warning into the capture.
      {[{minimal_impl, _bytecode}], captured} =
        ExUnit.CaptureIO.with_io(:stderr, fn -> Code.compile_string(source) end)

      assert captured == ""
      assert {:ok, %ALLM.SpeechResponse{}} = minimal_impl.synthesize(nil, [])
    end
  end

  describe "FakeSpeech implements the behaviour" do
    test "declares @behaviour ALLM.SpeechAdapter" do
      behaviours =
        FakeSpeech.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert SpeechAdapter in behaviours
    end
  end
end
