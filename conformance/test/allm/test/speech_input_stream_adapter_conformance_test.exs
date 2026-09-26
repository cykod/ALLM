defmodule ALLM.Test.SpeechInputStreamAdapterConformanceTest do
  @moduledoc """
  Self-test of `ALLM.Test.SpeechInputStreamAdapterConformance` against
  `ALLM.Test.Fixtures.ScriptedSpeechInputStreamStub`.

  Carries the harness meta-invariants: case-count stability, a
  count-the-injected-tests guard, and a missing-opt `KeyError` guard. The
  fourth — `:gate_opts` reaching the unscripted case — is bound by
  `ALLM.Test.SpeechInputStreamAdapterConformanceGateOptsTest` below.
  """

  use ExUnit.Case, async: true

  use ALLM.Test.SpeechInputStreamAdapterConformance,
    speech_adapter: ALLM.Test.Fixtures.ScriptedSpeechInputStreamStub

  alias ALLM.Test.SpeechInputStreamAdapterConformance

  @describe_name "ALLM.SpeechStreamAdapter input conformance (ALLM.Test.Fixtures.ScriptedSpeechInputStreamStub)"

  describe "harness meta-invariants" do
    test "the harness declares exactly 6 cases (case-count stability)" do
      assert SpeechInputStreamAdapterConformance.case_count() == 6
    end

    test "the injected describe block contains exactly case_count/0 tests" do
      injected =
        Enum.filter(__MODULE__.__ex_unit__().tests, &(&1.tags[:describe] == @describe_name))

      assert length(injected) == SpeechInputStreamAdapterConformance.case_count()
    end

    test "the harness macro raises KeyError when the :speech_adapter opt is missing" do
      quoted =
        quote do
          defmodule __MODULE__.MissingSpeechInputAdapterOpt do
            use ExUnit.Case, async: true
            use ALLM.Test.SpeechInputStreamAdapterConformance, wrong_key: SomeModule
          end
        end

      assert_raise KeyError, fn -> Code.compile_quoted(quoted) end
    end
  end
end

defmodule ALLM.Test.SpeechInputStreamAdapterConformanceTest.PlugRequiredStub do
  @moduledoc false
  # Fails an UNSCRIPTED call that arrives without `:ws_module`, BEFORE its
  # gates run.
  @behaviour ALLM.SpeechStreamAdapter

  alias ALLM.Error.SpeechAdapterError
  alias ALLM.Test.Fixtures.ScriptedSpeechInputStreamStub

  @impl ALLM.SpeechStreamAdapter
  defdelegate stream_synthesize(request, opts), to: ScriptedSpeechInputStreamStub

  @impl ALLM.SpeechStreamAdapter
  def stream_synthesize_input(request, input, opts) do
    scripted? = opts |> Keyword.get(:adapter_opts, []) |> Keyword.has_key?(:speech_script)

    if scripted? or Keyword.has_key?(opts, :ws_module) do
      ScriptedSpeechInputStreamStub.stream_synthesize_input(request, input, opts)
    else
      {:error, SpeechAdapterError.new(:unknown, message: "gate_opts did not reach this case")}
    end
  end
end

defmodule ALLM.Test.SpeechInputStreamAdapterConformanceGateOptsTest do
  @moduledoc """
  Meta-invariant 4: `:gate_opts` reaches the [unscripted] case. The adapter
  under test fails any unscripted call lacking `:ws_module`, so the
  injected unscripted case passes only if the option arrived.
  """

  use ExUnit.Case, async: true

  use ALLM.Test.SpeechInputStreamAdapterConformance,
    speech_adapter: ALLM.Test.SpeechInputStreamAdapterConformanceTest.PlugRequiredStub,
    gate_opts: [ws_module: ALLM.Test.RaisingWebSocket]

  alias ALLM.Error.SpeechAdapterError
  alias ALLM.Test.SpeechInputStreamAdapterConformanceTest.PlugRequiredStub

  test "premise: the stub fails an unscripted call that carries no :ws_module" do
    req = ALLM.SpeechRequest.new(input: "", format: :bogus)

    assert {:error, %SpeechAdapterError{reason: :unknown}} =
             PlugRequiredStub.stream_synthesize_input(req, ["x"], [])
  end
end
