defmodule ALLM.Test.SpeechAdapterConformanceTest do
  @moduledoc """
  Self-test of `ALLM.Test.SpeechAdapterConformance` against
  `ALLM.Test.Fixtures.ScriptedSpeechStub`.

  Carries the harness meta-invariants: case-count stability, a
  count-the-injected-tests guard, and a missing-opt `KeyError` guard. The
  fourth — `:gate_opts` reaching every unscripted case — is bound by
  `ALLM.Test.SpeechAdapterConformanceGateOptsTest` below.
  """

  use ExUnit.Case, async: true

  use ALLM.Test.SpeechAdapterConformance,
    speech_adapter: ALLM.Test.Fixtures.ScriptedSpeechStub

  alias ALLM.Test.SpeechAdapterConformance

  @describe_name "ALLM.SpeechAdapter conformance (ALLM.Test.Fixtures.ScriptedSpeechStub)"

  describe "harness meta-invariants" do
    test "the harness declares exactly 6 cases (case-count stability)" do
      assert SpeechAdapterConformance.case_count() == 6
    end

    test "the injected describe block contains exactly case_count/0 tests" do
      injected =
        Enum.filter(__MODULE__.__ex_unit__().tests, &(&1.tags[:describe] == @describe_name))

      assert length(injected) == SpeechAdapterConformance.case_count()
    end

    test "the harness macro raises KeyError when the :speech_adapter opt is missing" do
      quoted =
        quote do
          defmodule __MODULE__.MissingSpeechAdapterOpt do
            use ExUnit.Case, async: true
            use ALLM.Test.SpeechAdapterConformance, wrong_key: SomeModule
          end
        end

      assert_raise KeyError, fn -> Code.compile_quoted(quoted) end
    end
  end
end

defmodule ALLM.Test.SpeechAdapterConformanceTest.PlugRequiredStub do
  @moduledoc false
  # Fails an UNSCRIPTED call that arrives without `adapter_opts[:plug]`,
  # BEFORE its gates run — so a harness that dropped `:gate_opts` turns the
  # unscripted cases red instead of passing on the gate.
  @behaviour ALLM.SpeechAdapter

  alias ALLM.Error.SpeechAdapterError
  alias ALLM.Test.Fixtures.ScriptedSpeechStub

  @impl ALLM.SpeechAdapter
  def synthesize(request, opts) do
    adapter_opts = Keyword.get(opts, :adapter_opts, [])

    if Keyword.has_key?(adapter_opts, :speech_script) or
         is_function(Keyword.get(adapter_opts, :plug), 1) do
      ScriptedSpeechStub.synthesize(request, opts)
    else
      {:error, SpeechAdapterError.new(:unknown, message: "gate_opts did not reach this case")}
    end
  end
end

defmodule ALLM.Test.SpeechAdapterConformanceGateOptsTest do
  @moduledoc """
  Meta-invariant 4: `:gate_opts` is deep-merged into every [unscripted] case.
  The adapter under test fails any unscripted call lacking `:plug`, so each
  injected unscripted case passes only if the option arrived.
  """

  use ExUnit.Case, async: true

  use ALLM.Test.SpeechAdapterConformance,
    speech_adapter: ALLM.Test.SpeechAdapterConformanceTest.PlugRequiredStub,
    gate_opts: [adapter_opts: [plug: fn _conn -> raise "gate let the request reach HTTP" end]]

  alias ALLM.Error.SpeechAdapterError
  alias ALLM.Test.SpeechAdapterConformance
  alias ALLM.Test.SpeechAdapterConformanceTest.PlugRequiredStub

  test "premise: the stub fails an unscripted call that carries no :plug" do
    # Without this, the injected cases above could pass on the stub's own
    # gate and :gate_opts would bind nothing.
    assert {:error, %SpeechAdapterError{reason: :unknown}} =
             PlugRequiredStub.synthesize(ALLM.SpeechRequest.new(input: ""), [])
  end
end
