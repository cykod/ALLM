defmodule ALLM.Test.TranscriptionStreamAdapterConformanceTest do
  @moduledoc """
  Self-test of `ALLM.Test.TranscriptionStreamAdapterConformance` against
  `ALLM.Test.Fixtures.ScriptedTranscriptionStreamStub`.

  Carries the harness meta-invariants: case-count stability, a
  count-the-injected-tests guard, and a missing-opt `KeyError` guard. The
  fourth — `:gate_opts` reaching every unscripted case — is bound by
  `ALLM.Test.TranscriptionStreamAdapterConformanceGateOptsTest` below.
  """

  use ExUnit.Case, async: true

  use ALLM.Test.TranscriptionStreamAdapterConformance,
    transcription_adapter: ALLM.Test.Fixtures.ScriptedTranscriptionStreamStub

  alias ALLM.Test.TranscriptionStreamAdapterConformance

  @describe_name "ALLM.TranscriptionStreamAdapter conformance (ALLM.Test.Fixtures.ScriptedTranscriptionStreamStub)"

  describe "harness meta-invariants" do
    test "the harness declares exactly 6 cases (case-count stability)" do
      assert TranscriptionStreamAdapterConformance.case_count() == 6
    end

    test "the injected describe block contains exactly case_count/0 tests" do
      injected =
        Enum.filter(__MODULE__.__ex_unit__().tests, &(&1.tags[:describe] == @describe_name))

      assert length(injected) == TranscriptionStreamAdapterConformance.case_count()
    end

    test "the harness macro raises KeyError when the :transcription_adapter opt is missing" do
      quoted =
        quote do
          defmodule __MODULE__.MissingTranscriptionStreamAdapterOpt do
            use ExUnit.Case, async: true
            use ALLM.Test.TranscriptionStreamAdapterConformance, wrong_key: SomeModule
          end
        end

      assert_raise KeyError, fn -> Code.compile_quoted(quoted) end
    end
  end

  describe "grammar helpers" do
    test "success_grammar?/1 allows zero segments and rejects a missing or non-final terminal" do
      started = {:transcription_started, %{}}
      completed = {:transcription_completed, %{}}
      partial = {:partial_transcript, %{text: "a"}}

      assert TranscriptionStreamAdapterConformance.success_grammar?([started, completed])
      assert TranscriptionStreamAdapterConformance.success_grammar?([started, partial, completed])
      refute TranscriptionStreamAdapterConformance.success_grammar?([started, partial])
      refute TranscriptionStreamAdapterConformance.success_grammar?([started, completed, partial])
      refute TranscriptionStreamAdapterConformance.success_grammar?([partial, completed])
    end

    test "silence/1 returns exactly n bytes" do
      assert byte_size(TranscriptionStreamAdapterConformance.silence(3_200)) == 3_200
    end
  end
end

defmodule ALLM.Test.TranscriptionStreamAdapterConformanceTest.PlugRequiredStub do
  @moduledoc false
  # Fails an UNSCRIPTED stream_transcribe/3 call that arrives without
  # `:ws_module`, BEFORE its gates run.
  @behaviour ALLM.TranscriptionStreamAdapter

  alias ALLM.Error.TranscriptionAdapterError
  alias ALLM.Test.Fixtures.ScriptedTranscriptionStreamStub

  @impl ALLM.TranscriptionStreamAdapter
  defdelegate stream_sample_rates, to: ScriptedTranscriptionStreamStub

  @impl ALLM.TranscriptionStreamAdapter
  def stream_transcribe(request, input, opts) do
    scripted? =
      opts |> Keyword.get(:adapter_opts, []) |> Keyword.has_key?(:transcription_script)

    if scripted? or Keyword.has_key?(opts, :ws_module) do
      ScriptedTranscriptionStreamStub.stream_transcribe(request, input, opts)
    else
      {:error,
       TranscriptionAdapterError.new(:unknown, message: "gate_opts did not reach this case")}
    end
  end
end

defmodule ALLM.Test.TranscriptionStreamAdapterConformanceGateOptsTest do
  @moduledoc """
  Meta-invariant 4: `:gate_opts` reaches every [unscripted] case that calls
  `stream_transcribe/3`. The adapter under test fails any such call lacking
  `:ws_module`, so each injected case passes only if the option arrived.
  """

  use ExUnit.Case, async: true

  use ALLM.Test.TranscriptionStreamAdapterConformance,
    transcription_adapter: ALLM.Test.TranscriptionStreamAdapterConformanceTest.PlugRequiredStub,
    gate_opts: [ws_module: ALLM.Test.RaisingWebSocket]

  alias ALLM.Error.TranscriptionAdapterError
  alias ALLM.Test.TranscriptionStreamAdapterConformanceTest.PlugRequiredStub

  test "premise: the stub fails an unscripted call that carries no :ws_module" do
    req = ALLM.TranscriptionStreamRequest.new(sample_rate: 1)

    assert {:error, %TranscriptionAdapterError{reason: :unknown}} =
             PlugRequiredStub.stream_transcribe(req, [], [])
  end
end
