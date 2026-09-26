defmodule ALLM.Test.SpeechStreamAdapterConformanceTest do
  @moduledoc """
  Self-test of `ALLM.Test.SpeechStreamAdapterConformance` against
  `ALLM.Test.Fixtures.ScriptedSpeechStreamStub`.

  Carries the harness meta-invariants: case-count stability, a
  count-the-injected-tests guard, and a missing-opt `KeyError` guard. The
  fourth — `:gate_opts` reaching every unscripted case — is bound by
  `ALLM.Test.SpeechStreamAdapterConformanceGateOptsTest` below.
  """

  use ExUnit.Case, async: true

  use ALLM.Test.SpeechStreamAdapterConformance,
    speech_adapter: ALLM.Test.Fixtures.ScriptedSpeechStreamStub

  alias ALLM.Test.SpeechStreamAdapterConformance

  @describe_name "ALLM.SpeechStreamAdapter conformance (ALLM.Test.Fixtures.ScriptedSpeechStreamStub)"

  describe "harness meta-invariants" do
    test "the harness declares exactly 6 cases (case-count stability)" do
      assert SpeechStreamAdapterConformance.case_count() == 6
    end

    test "the injected describe block contains exactly case_count/0 tests" do
      injected =
        Enum.filter(__MODULE__.__ex_unit__().tests, &(&1.tags[:describe] == @describe_name))

      assert length(injected) == SpeechStreamAdapterConformance.case_count()
    end

    test "the harness macro raises KeyError when the :speech_adapter opt is missing" do
      quoted =
        quote do
          defmodule __MODULE__.MissingSpeechStreamAdapterOpt do
            use ExUnit.Case, async: true
            use ALLM.Test.SpeechStreamAdapterConformance, wrong_key: SomeModule
          end
        end

      assert_raise KeyError, fn -> Code.compile_quoted(quoted) end
    end
  end

  describe "grammar helpers" do
    test "success_grammar?/1 rejects a stream with no delta, a missing terminal, or an event after it" do
      started = {:speech_started, %{}}
      completed = {:speech_completed, %{}}
      delta = {:audio_delta, "a"}

      assert SpeechStreamAdapterConformance.success_grammar?([started, delta, completed])
      refute SpeechStreamAdapterConformance.success_grammar?([started, completed])
      refute SpeechStreamAdapterConformance.success_grammar?([started, delta])
      refute SpeechStreamAdapterConformance.success_grammar?([started, delta, completed, delta])
      refute SpeechStreamAdapterConformance.success_grammar?([delta, completed])
    end

    test "failure_grammar?/1 accepts an optional started and requires a final error" do
      err = {:error, :x}

      assert SpeechStreamAdapterConformance.failure_grammar?([err])
      assert SpeechStreamAdapterConformance.failure_grammar?([{:speech_started, %{}}, err])
      refute SpeechStreamAdapterConformance.failure_grammar?([{:speech_started, %{}}])
      refute SpeechStreamAdapterConformance.failure_grammar?([err, {:audio_delta, "a"}])
    end
  end
end

defmodule ALLM.Test.SpeechStreamAdapterConformanceTest.PlugRequiredStub do
  @moduledoc false
  # Fails an UNSCRIPTED call that arrives without `:finch_module`, BEFORE its
  # gates run — so a harness that dropped `:gate_opts` turns the unscripted
  # case red instead of passing on the gate.
  @behaviour ALLM.SpeechStreamAdapter

  alias ALLM.Error.SpeechAdapterError
  alias ALLM.Test.Fixtures.ScriptedSpeechStreamStub

  @impl ALLM.SpeechStreamAdapter
  def stream_synthesize(request, opts) do
    scripted? = opts |> Keyword.get(:adapter_opts, []) |> Keyword.has_key?(:speech_script)

    if scripted? or Keyword.has_key?(opts, :finch_module) do
      ScriptedSpeechStreamStub.stream_synthesize(request, opts)
    else
      {:error, SpeechAdapterError.new(:unknown, message: "gate_opts did not reach this case")}
    end
  end
end

defmodule ALLM.Test.SpeechStreamAdapterConformanceGateOptsTest do
  @moduledoc """
  Meta-invariant 4: `:gate_opts` reaches every [unscripted] case. The
  adapter under test fails any unscripted call lacking `:finch_module`, so
  each injected unscripted case passes only if the option arrived.
  """

  use ExUnit.Case, async: true

  use ALLM.Test.SpeechStreamAdapterConformance,
    speech_adapter: ALLM.Test.SpeechStreamAdapterConformanceTest.PlugRequiredStub,
    gate_opts: [finch_module: ALLM.Test.RaisingFinch]

  alias ALLM.Error.SpeechAdapterError
  alias ALLM.Test.SpeechStreamAdapterConformanceTest.PlugRequiredStub

  test "premise: the stub fails an unscripted call that carries no :finch_module" do
    assert {:error, %SpeechAdapterError{reason: :unknown}} =
             PlugRequiredStub.stream_synthesize(ALLM.SpeechRequest.new(input: ""), [])
  end
end
