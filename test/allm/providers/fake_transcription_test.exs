defmodule ALLM.Providers.FakeTranscriptionTest do
  use ExUnit.Case, async: true

  alias ALLM.{Audio, Engine, TranscriptionRequest, TranscriptionResponse, Usage}
  alias ALLM.Error.TranscriptionAdapterError
  alias ALLM.Providers.FakeTranscription
  alias ALLM.Test.FakeAudioFixtures, as: Fixtures

  doctest FakeTranscription

  defp request(opts \\ []),
    do: TranscriptionRequest.new(Keyword.put_new(opts, :audio, Fixtures.clip(16)))

  describe "max_audio_bytes/0" do
    test "returns 1024 — small, so the size boundary is cheap to cross" do
      assert FakeTranscription.max_audio_bytes() == 1024
    end
  end

  describe "transcribe/2 default (no script)" do
    test "returns an empty transcript with %Usage{}" do
      assert {:ok, %TranscriptionResponse{text: "", usage: %Usage{}}} =
               FakeTranscription.transcribe(request(), [])
    end

    test "an explicit empty script also yields the default" do
      assert {:ok, %TranscriptionResponse{text: ""}} =
               FakeTranscription.transcribe(request(), adapter_opts: [transcription_script: []])
    end

    test "propagates request_id, model, metadata and provider" do
      req = request(model: "fake-stt", metadata: %{"k" => "v"})
      assert {:ok, resp} = FakeTranscription.transcribe(req, request_id: "rid-1")

      assert resp.request_id == "rid-1"
      assert resp.model == "fake-stt"
      assert resp.metadata == %{"k" => "v"}
      assert resp.provider == :fake
    end
  end

  describe "transcribe/2 scripted entries" do
    test "{:ok, text} returns that transcript" do
      opts = [adapter_opts: Fixtures.transcript("The quick brown fox.")]

      assert {:ok, %TranscriptionResponse{text: "The quick brown fox.", usage: %Usage{}}} =
               FakeTranscription.transcribe(request(), opts)
    end

    test "{:ok, %TranscriptionResponse{}} is returned verbatim" do
      scripted = TranscriptionResponse.new(text: "verbatim", duration_seconds: 3)
      opts = [adapter_opts: [transcription_script: [{:ok, scripted}]]]

      assert {:ok, ^scripted} = FakeTranscription.transcribe(request(), opts)
    end

    test "{:error, %TranscriptionAdapterError{}} is returned verbatim" do
      opts = [adapter_opts: Fixtures.transcription_rate_limited()]

      assert {:error, %TranscriptionAdapterError{reason: :rate_limited, retry_after_ms: 250}} =
               FakeTranscription.transcribe(request(), opts)
    end

    test "successive calls advance through the script" do
      cursor = FakeTranscription.start_script_cursor()

      opts = [
        adapter_opts: [transcription_script: [{:ok, "a"}, {:ok, "b"}], script_cursor: cursor]
      ]

      assert {:ok, %{text: "a"}} = FakeTranscription.transcribe(request(), opts)
      assert {:ok, %{text: "b"}} = FakeTranscription.transcribe(request(), opts)
      assert FakeTranscription.cursor_index(cursor) == 2
    end

    test "running past the end of a NON-EMPTY script errors with :transcription_script_exhausted" do
      cursor = FakeTranscription.start_script_cursor()
      opts = [adapter_opts: Fixtures.transcript("a") ++ [script_cursor: cursor]]

      assert {:ok, _} = FakeTranscription.transcribe(request(), opts)

      assert {:error, %TranscriptionAdapterError{reason: :unknown, metadata: meta}} =
               FakeTranscription.transcribe(request(), opts)

      assert meta.cause == :transcription_script_exhausted
    end
  end

  describe "transcribe/2 gates" do
    test "max_audio_bytes() + 1 is rejected with metadata.count and metadata.max" do
      req = request(audio: Fixtures.clip(FakeTranscription.max_audio_bytes() + 1))

      assert {:error, %TranscriptionAdapterError{reason: :invalid_request, metadata: meta}} =
               FakeTranscription.transcribe(req, [])

      assert meta.count == 1025
      assert meta.max == 1024
    end

    test "exactly max_audio_bytes() passes the gate" do
      req = request(audio: Fixtures.clip(FakeTranscription.max_audio_bytes()))
      assert {:ok, _} = FakeTranscription.transcribe(req, [])
    end

    test "adapter_opts[:max_audio_bytes] overrides the cap" do
      req = request(audio: Fixtures.clip(2048))

      assert {:error, %TranscriptionAdapterError{reason: :invalid_request}} =
               FakeTranscription.transcribe(req, [])

      assert {:ok, _} = FakeTranscription.transcribe(req, adapter_opts: [max_audio_bytes: 4096])
    end

    test "a missing file is rejected with metadata.cause == :enoent" do
      req = request(audio: Audio.from_file("/nonexistent/allm-fake-transcription.mp3"))

      assert {:error, %TranscriptionAdapterError{reason: :invalid_request, metadata: meta}} =
               FakeTranscription.transcribe(req, [])

      assert meta.cause == :enoent
      assert meta.field == :audio
    end

    test "invalid base64 is rejected with metadata.cause == :invalid_base64" do
      req = request(audio: Audio.from_base64("%%%", "audio/mpeg"))

      assert {:error, %TranscriptionAdapterError{reason: :invalid_request, metadata: meta}} =
               FakeTranscription.transcribe(req, [])

      assert meta.cause == :invalid_base64
    end

    test "a non-%Audio{} :audio is rejected rather than raising" do
      assert {:error, %TranscriptionAdapterError{reason: :invalid_request, metadata: meta}} =
               FakeTranscription.transcribe(TranscriptionRequest.new(audio: nil), [])

      assert meta.cause == :invalid_source
    end

    test "gates fire before consuming a script entry" do
      cursor = FakeTranscription.start_script_cursor()
      opts = [adapter_opts: Fixtures.transcript("first") ++ [script_cursor: cursor]]
      bad = request(audio: Fixtures.clip(FakeTranscription.max_audio_bytes() + 1))

      assert {:error, %TranscriptionAdapterError{reason: :invalid_request}} =
               FakeTranscription.transcribe(bad, opts)

      assert FakeTranscription.cursor_index(cursor) == 0
      assert {:ok, %{text: "first"}} = FakeTranscription.transcribe(request(), opts)
    end
  end

  describe "cursor precedence" do
    test "two content-equal engines with distinct :id values do not share a cursor" do
      a = Fixtures.transcription_engine(Fixtures.transcript("only"))
      b = Fixtures.transcription_engine(Fixtures.transcript("only"))

      assert a.adapter_opts == b.adapter_opts
      refute a.id == b.id

      opts_a = [adapter_opts: Engine.put_cursor_key(a.adapter_opts, a)]
      opts_b = [adapter_opts: Engine.put_cursor_key(b.adapter_opts, b)]

      assert {:ok, %{text: "only"}} = FakeTranscription.transcribe(request(), opts_a)
      assert {:ok, %{text: "only"}} = FakeTranscription.transcribe(request(), opts_b)
    end

    test "content-equal scripts with no cursor_key DO share the phash2 cursor" do
      opts = [adapter_opts: Fixtures.transcript("only")]

      assert {:ok, _} = FakeTranscription.transcribe(request(), opts)

      assert {:error,
              %TranscriptionAdapterError{metadata: %{cause: :transcription_script_exhausted}}} =
               FakeTranscription.transcribe(request(), opts)
    end
  end

  describe "capture_pid seam" do
    test "sends the request to :capture_pid before any gate" do
      req = request(audio: nil)
      opts = [adapter_opts: [capture_pid: self()]]

      assert {:error, _} = FakeTranscription.transcribe(req, opts)
      assert_receive {FakeTranscription, :call, %{request: ^req, opts: ^opts}}
    end
  end

  describe "{:retry_until_call, n}" do
    test "returns :rate_limited until the budget is spent, then succeeds" do
      # Direct call with an explicit :cursor_key and a leading non-error
      # entry — see the FakeSpeech counterpart for why both matter.
      script = [{:ok, "lead"}, {:retry_until_call, 3}, {:ok, "after"}]
      opts = [adapter_opts: [transcription_script: script, cursor_key: :stt_retry_case]]

      assert {:ok, %{text: "lead"}} = FakeTranscription.transcribe(request(), opts)

      assert {:error, %TranscriptionAdapterError{reason: :rate_limited, retry_after_ms: 0}} =
               FakeTranscription.transcribe(request(), opts)

      assert {:error, %TranscriptionAdapterError{reason: :rate_limited}} =
               FakeTranscription.transcribe(request(), opts)

      assert {:ok, %{text: "after"}} = FakeTranscription.transcribe(request(), opts)
    end

    test "consecutive retry entries chain into a layered budget instead of raising" do
      cursor = FakeTranscription.start_script_cursor()
      script = [{:retry_until_call, 2}, {:retry_until_call, 2}, {:ok, "done"}]
      assert :ok = FakeTranscription.script(script)
      opts = [adapter_opts: [transcription_script: script, script_cursor: cursor]]

      assert {:error, %{reason: :rate_limited}} = FakeTranscription.transcribe(request(), opts)
      assert {:error, %{reason: :rate_limited}} = FakeTranscription.transcribe(request(), opts)
      assert {:ok, %{text: "done"}} = FakeTranscription.transcribe(request(), opts)
    end

    test "a retry budget that runs off the end errors rather than reporting success" do
      cursor = FakeTranscription.start_script_cursor()

      opts = [
        adapter_opts: [transcription_script: [{:retry_until_call, 1}], script_cursor: cursor]
      ]

      assert {:error, %TranscriptionAdapterError{reason: :unknown, metadata: meta}} =
               FakeTranscription.transcribe(request(), opts)

      assert meta.cause == :transcription_script_exhausted
    end

    test "two content-equal-script engines with distinct :id values do not share a retry budget" do
      e1 = Fixtures.transcription_engine(Fixtures.transcription_retry_until_call(2, "ok"))
      e2 = Fixtures.transcription_engine(Fixtures.transcription_retry_until_call(2, "ok"))

      refute e1.id == e2.id

      opts1 = [adapter_opts: Engine.put_cursor_key(e1.adapter_opts, e1)]
      opts2 = [adapter_opts: Engine.put_cursor_key(e2.adapter_opts, e2)]

      assert {:error, %{reason: :rate_limited}} = FakeTranscription.transcribe(request(), opts1)
      assert {:ok, %{text: "ok"}} = FakeTranscription.transcribe(request(), opts1)

      # A retry counter keyed on :erlang.phash2(script) alone would let
      # engine 2 skip straight to the success entry.
      assert {:error, %{reason: :rate_limited}} = FakeTranscription.transcribe(request(), opts2)
      assert {:ok, %{text: "ok"}} = FakeTranscription.transcribe(request(), opts2)
    end
  end

  describe "script/1" do
    test "accepts every documented entry shape" do
      assert :ok =
               FakeTranscription.script([
                 {:ok, "text"},
                 {:ok, TranscriptionResponse.new()},
                 {:error, TranscriptionAdapterError.new(:content_filter)},
                 {:retry_until_call, 2}
               ])
    end

    test "raises ArgumentError on an unrecognized entry" do
      assert_raise ArgumentError, ~r/invalid FakeTranscription script entry/, fn ->
        FakeTranscription.script([{:nope, 1}])
      end
    end
  end
end
