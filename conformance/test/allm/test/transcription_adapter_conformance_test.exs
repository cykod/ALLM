defmodule ALLM.Test.TranscriptionAdapterConformanceTest do
  @moduledoc """
  Self-test of `ALLM.Test.TranscriptionAdapterConformance` against
  `ALLM.Test.Fixtures.ScriptedTranscriptionStub`.

  Carries the harness meta-invariants: case-count stability, a
  count-the-injected-tests guard, and a missing-opt `KeyError` guard. The
  fourth — `:gate_opts` reaching every unscripted case — is bound by
  `ALLM.Test.TranscriptionAdapterConformanceGateOptsTest` below.
  """

  use ExUnit.Case, async: true

  use ALLM.Test.TranscriptionAdapterConformance,
    transcription_adapter: ALLM.Test.Fixtures.ScriptedTranscriptionStub

  alias ALLM.Test.TranscriptionAdapterConformance

  @describe_name "ALLM.TranscriptionAdapter conformance (ALLM.Test.Fixtures.ScriptedTranscriptionStub)"

  describe "harness meta-invariants" do
    test "the harness declares exactly 6 cases (case-count stability)" do
      assert TranscriptionAdapterConformance.case_count() == 6
    end

    test "the injected describe block contains exactly case_count/0 tests" do
      injected =
        Enum.filter(__MODULE__.__ex_unit__().tests, &(&1.tags[:describe] == @describe_name))

      assert length(injected) == TranscriptionAdapterConformance.case_count()
    end

    test "the harness macro raises KeyError when the :transcription_adapter opt is missing" do
      quoted =
        quote do
          defmodule __MODULE__.MissingTranscriptionAdapterOpt do
            use ExUnit.Case, async: true
            use ALLM.Test.TranscriptionAdapterConformance, wrong_key: SomeModule
          end
        end

      assert_raise KeyError, fn -> Code.compile_quoted(quoted) end
    end
  end
end

defmodule ALLM.Test.TranscriptionAdapterConformanceTest.PlugRequiredStub do
  @moduledoc false
  # Fails an UNSCRIPTED transcribe/2 call that arrives without
  # `adapter_opts[:plug]`, BEFORE its gates run.
  @behaviour ALLM.TranscriptionAdapter

  alias ALLM.Error.TranscriptionAdapterError
  alias ALLM.Test.Fixtures.ScriptedTranscriptionStub

  @impl ALLM.TranscriptionAdapter
  defdelegate max_audio_bytes, to: ScriptedTranscriptionStub

  @impl ALLM.TranscriptionAdapter
  def transcribe(request, opts) do
    adapter_opts = Keyword.get(opts, :adapter_opts, [])

    if Keyword.has_key?(adapter_opts, :transcription_script) or
         is_function(Keyword.get(adapter_opts, :plug), 1) do
      ScriptedTranscriptionStub.transcribe(request, opts)
    else
      {:error,
       TranscriptionAdapterError.new(:unknown, message: "gate_opts did not reach this case")}
    end
  end
end

defmodule ALLM.Test.TranscriptionAdapterConformanceGateOptsTest do
  @moduledoc """
  Meta-invariant 4: `:gate_opts` is deep-merged into every [unscripted] case
  that calls `transcribe/2`. The adapter under test fails any such call
  lacking `:plug`, so each injected case passes only if the option arrived.
  """

  use ExUnit.Case, async: true

  use ALLM.Test.TranscriptionAdapterConformance,
    transcription_adapter: ALLM.Test.TranscriptionAdapterConformanceTest.PlugRequiredStub,
    gate_opts: [adapter_opts: [plug: fn _conn -> raise "gate let the request reach HTTP" end]]

  alias ALLM.Error.TranscriptionAdapterError
  alias ALLM.Test.TranscriptionAdapterConformance
  alias ALLM.Test.TranscriptionAdapterConformanceTest.PlugRequiredStub

  test "premise: the stub fails an unscripted call that carries no :plug" do
    req = ALLM.TranscriptionRequest.new(audio: ALLM.Audio.from_file("/nonexistent.mp3"))

    assert {:error, %TranscriptionAdapterError{reason: :unknown}} =
             PlugRequiredStub.transcribe(req, [])
  end

  test "clip_bytes/1 returns exactly n bytes" do
    assert byte_size(TranscriptionAdapterConformance.clip_bytes(601)) == 601
  end
end
