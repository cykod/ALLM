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

      # `Code.with_diagnostics/1` collects only the diagnostics of the compile
      # this process runs, where a `:stderr` capture sees every process's
      # output: in an async module, a warning from any file compiling
      # concurrently would fail this test.
      {[{minimal_impl, _bytecode}], diagnostics} =
        Code.with_diagnostics(fn -> Code.compile_string(source) end)

      assert diagnostics == []
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
