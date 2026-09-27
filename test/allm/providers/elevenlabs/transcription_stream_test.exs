defmodule ALLM.Providers.ElevenLabs.TranscriptionStreamTest do
  @moduledoc """
  Wire tests for `ALLM.Providers.ElevenLabs.Transcription.stream_transcribe/3`
  (the realtime WebSocket `/v1/speech-to-text/realtime`) over
  `ALLM.Test.WebSocketStub`, plus end-to-end rows over the real
  `ALLM.Providers.Support.WebSocket.Mint` and `ALLM.Test.WSTestServer`.

  Recorded sessions (`test/fixtures/elevenlabs/realtime/recorded/`) are
  replayed through the stub. Keyless gate tests pass
  `ALLM.Test.RaisingWebSocket`, so a gate moved after key resolution or into
  the stream fails even in a shell that exports `ELEVENLABS_API_KEY`.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ALLM.Error.TranscriptionAdapterError
  alias ALLM.Providers.ElevenLabs.Transcription
  alias ALLM.Providers.ElevenLabsTestFixtures, as: Fixtures
  alias ALLM.Test.{PCM, RaisingWebSocket, WebSocketStub, WSTestServer}
  alias ALLM.TranscriptionEvent
  alias ALLM.TranscriptionStreamRequest

  @moduletag timeout: 20_000

  @key "sk_rtstreamtest0123456789abcdef"
  @fox_wav "test/fixtures/audio/quick_brown_fox.wav"

  defp req(opts \\ []), do: TranscriptionStreamRequest.new(opts)

  defp ws_opts(stub, opts \\ []) do
    Keyword.merge([api_key: @key, ws_module: WebSocketStub, ws_stub: stub], opts)
  end

  defp started(id \\ "sess_1"),
    do: {:json, %{"message_type" => "session_started", "session_id" => id}}

  defp committed(text), do: {:json, %{"message_type" => "committed_transcript", "text" => text}}
  defp partial(text), do: {:json, %{"message_type" => "partial_transcript", "text" => text}}

  defp stamped(text, language) do
    {:json,
     %{
       "message_type" => "committed_transcript_with_timestamps",
       "text" => text,
       "language_code" => language,
       "words" => []
     }}
  end

  # Accepts a client commit frame.
  defp commit?({:text, json}), do: match?(%{"commit" => true}, Jason.decode!(json))
  defp commit?(_frame), do: false

  # A stub whose server greets with session_started and answers the first
  # client commit with `on_commit`.
  defp stub(on_commit, opts \\ []) do
    WebSocketStub.install([{:after_client, &commit?/1, on_commit}],
      greeting: Keyword.get(opts, :greeting, [started()])
    )
  end

  defp client_messages(stub) do
    for {:text, json} <- WebSocketStub.sent_frames(stub), do: Jason.decode!(json)
  end

  defp audio_frames(stub) do
    for %{"commit" => false, "audio_base_64" => b64} <- client_messages(stub),
        do: Base.decode64!(b64)
  end

  defp terminal(events), do: List.last(events)

  defp endless(chunks),
    do: Stream.concat(chunks, Stream.repeatedly(fn -> Process.sleep(:infinity) end))

  # ===========================================================================
  # URL and client frames
  # ===========================================================================

  describe "stream_url/2" do
    test "model_id, audio_format and commit_strategy; the reserved audio_format option is dropped" do
      url =
        Transcription.stream_url(
          req(options: %{"audio_format" => "ulaw_8000", "include_timestamps" => true}),
          []
        )

      uri = URI.parse(url)
      query = URI.decode_query(uri.query)

      assert uri.scheme == "wss"
      assert uri.host == "api.elevenlabs.io"
      assert uri.path == "/v1/speech-to-text/realtime"

      assert query == %{
               "model_id" => "scribe_v2_realtime",
               "audio_format" => "pcm_16000",
               "commit_strategy" => "vad",
               "include_timestamps" => "true"
             }
    end

    test "manual strategy, a language, an explicit model, and an atom-keyed option" do
      query =
        req(
          sample_rate: 8_000,
          commit_strategy: :manual,
          language: "en",
          model: "scribe_v2_realtime",
          options: %{commit_strategy: "vad", vad_silence_threshold_secs: 0.5}
        )
        |> Transcription.stream_url([])
        |> URI.parse()
        |> Map.fetch!(:query)
        |> URI.decode_query()

      assert query == %{
               "model_id" => "scribe_v2_realtime",
               "audio_format" => "pcm_8000",
               "commit_strategy" => "manual",
               "language_code" => "en",
               "vad_silence_threshold_secs" => "0.5"
             }
    end

    test "an http base URL gives ws://; the key is never in the URL" do
      url = Transcription.stream_url(req(), base_url: "http://127.0.0.1:4000", api_key: @key)
      assert url =~ ~r{^ws://127\.0\.0\.1:4000/v1/speech-to-text/realtime\?}
      refute url =~ @key
    end

    test "the upgrade carries xi-api-key; the URL carries neither the key nor authorization=" do
      stub = stub([committed("hi")])

      {:ok, events} =
        Transcription.stream_transcribe(req(), [<<0::size(19_200)-unit(8)>>], ws_opts(stub))

      Enum.to_list(events)

      assert [{url, headers}] = WebSocketStub.connects(stub)
      assert {"xi-api-key", @key} in headers
      refute url =~ @key
      refute url =~ "authorization="
    end
  end

  describe "client audio frames (WebSocketStub)" do
    test "the decoded audio equals the concatenated input, and every frame holds whole samples" do
      input = [<<1, 2, 3>>, <<4, 5>>, <<6>>, "", <<7, 8, 9, 10, 11>>, <<12>>]
      stub = stub([committed("x")])
      {:ok, events} = Transcription.stream_transcribe(req(), input, ws_opts(stub))

      assert {:transcription_completed, _} = events |> Enum.to_list() |> terminal()
      frames = audio_frames(stub)
      assert IO.iodata_to_binary(frames) == IO.iodata_to_binary(input)
      assert Enum.all?(frames, &(rem(byte_size(&1), 2) == 0))
    end

    test "[<<1, 2, 3>>, <<4>>] sends whole samples only: <<1, 2>> then <<3, 4>>" do
      stub = stub([committed("x")])
      {:ok, events} = Transcription.stream_transcribe(req(), [<<1, 2, 3>>, <<4>>], ws_opts(stub))
      Enum.to_list(events)

      assert audio_frames(stub) == [<<1, 2>>, <<3, 4>>]
    end

    test "each frame names input_audio_chunk and the sample rate" do
      stub = stub([committed("x")])

      {:ok, events} =
        Transcription.stream_transcribe(req(sample_rate: 24_000), [<<0, 0>>], ws_opts(stub))

      Enum.to_list(events)

      assert [
               %{
                 "message_type" => "input_audio_chunk",
                 "audio_base_64" => "AAA=",
                 "commit" => false,
                 "sample_rate" => 24_000
               },
               %{"audio_base_64" => "", "commit" => true}
             ] = client_messages(stub)
    end

    test "a 3-second chunk at 16 kHz is split into frames of at most 1,000 ms of audio" do
      chunk = :binary.copy(<<1, 0>>, 16_000 * 3)
      stub = stub([committed("x")])
      {:ok, events} = Transcription.stream_transcribe(req(), [chunk], ws_opts(stub))
      Enum.to_list(events)

      frames = audio_frames(stub)
      assert Enum.map(frames, &byte_size/1) == [32_000, 32_000, 32_000]
      assert IO.iodata_to_binary(frames) == chunk
    end

    test ":commit sends a commit frame with empty audio, in input order" do
      stub =
        WebSocketStub.install(
          [
            {:after_client, &commit?/1, [committed("one")]},
            {:after_client, &commit?/1, [committed("two")]}
          ],
          greeting: [started()]
        )

      {:ok, events} =
        Transcription.stream_transcribe(
          req(commit_strategy: :manual),
          [<<0, 0>>, :commit, <<0, 0>>],
          ws_opts(stub)
        )

      assert {:transcription_completed, %{text: "one two"}} = events |> Enum.to_list() |> terminal()

      assert [
               %{"commit" => false, "audio_base_64" => "AAA="},
               %{"commit" => true, "audio_base_64" => ""},
               %{"commit" => false, "audio_base_64" => "AAA="},
               %{"commit" => true, "audio_base_64" => ""}
             ] = client_messages(stub)
    end
  end

  # ===========================================================================
  # Input failures (invariant 7)
  # ===========================================================================

  describe "input failures (WebSocketStub)" do
    test "an odd total length ends with :invalid_input_chunk at end of input, after the whole samples were sent" do
      stub = stub([committed("x")])
      {:ok, events} = Transcription.stream_transcribe(req(), [<<1, 2, 3>>], ws_opts(stub))

      assert [
               {:transcription_started, _},
               {:error,
                %TranscriptionAdapterError{
                  reason: :invalid_request,
                  metadata: %{cause: :invalid_input_chunk}
                }}
             ] = Enum.to_list(events)

      assert audio_frames(stub) == [<<1, 2>>]
      refute Enum.any?(client_messages(stub), &(&1["commit"] == true))
    end

    for {label, input} <- [{"[123]", [123]}, {"a stray atom [:flush]", [:flush]}] do
      test "input #{label} -> terminal :invalid_input_chunk" do
        stub = stub([])
        {:ok, events} = Transcription.stream_transcribe(req(), unquote(input), ws_opts(stub))

        assert [
                 {:transcription_started, _},
                 {:error,
                  %TranscriptionAdapterError{
                    reason: :invalid_request,
                    metadata: %{cause: :invalid_input_chunk}
                  }}
               ] = Enum.to_list(events)
      end
    end

    test "an input that raises -> terminal :input_raised, the consumer alive, err.cause a kind/message map" do
      stub = stub([])
      input = Stream.map([1], fn _ -> raise "mic unplugged" end)
      {:ok, events} = Transcription.stream_transcribe(req(), input, ws_opts(stub))

      assert [_, {:error, %TranscriptionAdapterError{metadata: %{cause: :input_raised}} = err}] =
               Enum.to_list(events)

      assert Process.alive?(self())
      assert %{kind: :error, message: message} = err.cause
      assert message =~ "mic unplugged"
      assert {:ok, _} = Jason.encode(err)
    end
  end

  # ===========================================================================
  # Server messages
  # ===========================================================================

  describe "server messages (WebSocketStub)" do
    test "session_started, partials, a committed segment and the completion, in order" do
      stub = stub([partial("hel"), partial("hello"), committed(" hello ")])

      {:ok, events} =
        Transcription.stream_transcribe(
          req(metadata: %{"trace" => "t1"}),
          [<<0::size(32_000)-unit(8)>>],
          ws_opts(stub, request_id: "rid_1")
        )

      events = Enum.to_list(events)
      assert Enum.all?(events, &TranscriptionEvent.event?/1)

      assert [
               {:transcription_started,
                %{
                  session_id: "sess_1",
                  model: "scribe_v2_realtime",
                  provider: :elevenlabs,
                  request_id: "rid_1"
                }},
               {:partial_transcript, %{text: "hel"}},
               {:partial_transcript, %{text: "hello"}},
               {:committed_transcript, %{text: " hello ", language: nil}},
               {:transcription_completed, completed}
             ] = events

      assert completed.text == "hello"
      assert completed.request_id == "rid_1"
      assert completed.metadata == %{"trace" => "t1"}
      assert completed.usage == %ALLM.Usage{}
    end

    test "duration_seconds is bytes / (sample_rate * 2)" do
      stub = stub([committed("x")])

      {:ok, events} =
        Transcription.stream_transcribe(
          req(sample_rate: 8_000),
          [<<0::size(4_000)-unit(8)>>, <<0::size(2_000)-unit(8)>>],
          ws_opts(stub)
        )

      assert {:transcription_completed, %{duration_seconds: 0.375}} =
               events |> Enum.to_list() |> terminal()
    end

    test "a warning frame is logged and emits no event" do
      stub =
        WebSocketStub.install(
          [
            {:after_client, :any,
             [{:json, %{"message_type" => "warning", "warning" => "audio is quiet"}}]},
            {:after_client, &commit?/1, [committed("x")]}
          ],
          greeting: [started()]
        )

      log =
        capture_log([level: :warning], fn ->
          {:ok, events} = Transcription.stream_transcribe(req(), [<<0, 0>>], ws_opts(stub))
          send(self(), {:events, Enum.to_list(events)})
        end)

      assert_received {:events, events}
      assert log =~ "server warning"
      assert log =~ "audio is quiet"

      assert [:transcription_started, :committed_transcript, :transcription_completed] =
               Enum.map(events, &elem(&1, 0))
    end

    # Falsifiers: three events for two segments, a duplicate segment in the
    # completed text, or a leaked language.
    test "timestamped commits attach a language once, in either order, and never duplicate a segment" do
      stub =
        WebSocketStub.install(
          [
            # Segment 1: the timestamped frame first.
            {:after_client, &commit?/1, [stamped("one", "en"), committed("one")]},
            # Segment 2: the plain frame first, then its late timestamped twin.
            {:after_client, &commit?/1, [committed("two"), stamped("two", "fr")]},
            # Segment 3: no timestamped frame at all.
            {:after_client, &commit?/1, [committed("three")]}
          ],
          greeting: [started()]
        )

      input = [<<0, 0>>, :commit, <<0, 0>>, :commit, <<0, 0>>]

      {:ok, events} =
        Transcription.stream_transcribe(req(commit_strategy: :manual), input, ws_opts(stub))

      events = Enum.to_list(events)

      assert [
               {:committed_transcript, %{text: "one", language: "en"}},
               {:committed_transcript, %{text: "two", language: nil}},
               {:committed_transcript, %{text: "three", language: nil}}
             ] = for({:committed_transcript, _} = e <- events, do: e)

      assert {:transcription_completed, completed} = terminal(events)
      assert completed.text == "one two three"
      # The late twin (and its language) is dropped entirely.
      assert completed.language == "en"
    end

    # Default path (not opted in), keyed by commit order: segment 2's
    # timestamped frame arrives first with the same text as segment 1.
    # Falsifier: a text-equality twin check misreads it as segment 1's late
    # twin and drops "fr".
    test "default path: two identical consecutive texts pair by commit order, not by text" do
      stub =
        WebSocketStub.install(
          [
            {:after_client, &commit?/1, [committed("Yes."), stamped("Yes.", "en")]},
            {:after_client, &commit?/1, [stamped("Yes.", "fr"), committed("Yes.")]}
          ],
          greeting: [started()]
        )

      {:ok, events} =
        Transcription.stream_transcribe(
          req(commit_strategy: :manual),
          [<<0, 0>>, :commit, <<0, 0>>],
          ws_opts(stub)
        )

      assert [
               {:committed_transcript, %{text: "Yes.", language: nil}},
               {:committed_transcript, %{text: "Yes.", language: "fr"}}
             ] = for({:committed_transcript, _} = e <- Enum.to_list(events), do: e)
    end

    test "a committed segment's empty text is emitted and dropped from the completed text" do
      stub =
        WebSocketStub.install(
          [
            {:after_client, &commit?/1, [committed("one")]},
            {:after_client, &commit?/1, [committed("")]}
          ],
          greeting: [started()]
        )

      {:ok, events} =
        Transcription.stream_transcribe(
          req(commit_strategy: :manual),
          [<<0, 0>>, :commit, <<0, 0>>],
          ws_opts(stub)
        )

      events = Enum.to_list(events)
      assert Enum.any?(events, &match?({:committed_transcript, %{text: ""}}, &1))
      assert {:transcription_completed, %{text: "one"}} = terminal(events)
    end
  end

  # Owner decision 2026-09-27 "hold when requested": with include_timestamps
  # or include_language_detection set, a segment waits (bounded) for its
  # timestamped frame. Frames pair by commit order.
  describe "language hold when opted in (WebSocketStub)" do
    @opted %{"include_timestamps" => true, "include_language_detection" => true}

    # One scripted server answer per client commit; the input is one audio
    # chunk per answer, with a :commit between two (the final commit is the
    # adapter's own, at the end of input).
    defp commits(answers) do
      script = Enum.map(answers, fn frames -> {:after_client, &commit?/1, frames} end)
      stub = WebSocketStub.install(script, greeting: [started()])
      input = answers |> Enum.map(fn _ -> <<0, 0>> end) |> Enum.intersperse(:commit)
      {stub, input}
    end

    defp run(stub, input, request_opts, opts \\ []) do
      request = req([commit_strategy: :manual] ++ request_opts)
      t0 = System.monotonic_time(:millisecond)
      {:ok, events} = Transcription.stream_transcribe(request, input, ws_opts(stub, opts))
      events = Enum.to_list(events)
      {events, System.monotonic_time(:millisecond) - t0}
    end

    defp segments(events), do: for({:committed_transcript, s} <- events, do: {s.text, s.language})

    test "plain then timestamped: one segment, emitted with the language" do
      {stub, input} = commits([[committed("one"), stamped("one", "en")]])
      {events, _ms} = run(stub, input, options: @opted)

      assert segments(events) == [{"one", "en"}]
      assert {:transcription_completed, %{text: "one", language: "en"}} = terminal(events)
    end

    test "timestamped then plain: one segment, emitted with the language" do
      {stub, input} = commits([[stamped("one", "en"), committed("one")]])
      {events, _ms} = run(stub, input, options: @opted)

      assert segments(events) == [{"one", "en"}]
      assert {:transcription_completed, %{language: "en"}} = terminal(events)
    end

    test "include_language_detection alone (a \"true\" string) also opts in" do
      {stub, input} = commits([[committed("one"), stamped("one", "de")]])
      {events, _ms} = run(stub, input, options: %{include_language_detection: "true"})

      assert segments(events) == [{"one", "de"}]
    end

    # Default bound (about 1,000 ms), no adapter_opts override. Falsifiers:
    # no hold (elapsed near 0), an unbounded hold (:timeout at 10 s, or the
    # segment lost).
    test "the timestamped frame never arrives: released after the bound, language nil, no loss" do
      {stub, input} = commits([[committed("one")]])
      {events, ms} = run(stub, input, [options: @opted], stream_timeout: 10_000)

      refute Enum.any?(events, &match?({:error, _}, &1)), inspect(events)
      assert segments(events) == [{"one", nil}]
      assert {:transcription_completed, %{text: "one", language: nil}} = terminal(events)
      assert ms >= 950, "released after #{ms} ms"
      assert ms < 5_000, "released after #{ms} ms"
    end

    test "adapter_opts[:language_hold_ms] sets the bound" do
      {stub, input} = commits([[committed("one")]])

      {events, ms} =
        run(stub, input, [options: @opted], adapter_opts: [language_hold_ms: 2_500])

      refute Enum.any?(events, &match?({:error, _}, &1)), inspect(events)
      assert segments(events) == [{"one", nil}]
      # A lower bound only, so load cannot flake it; the default is 1,000 ms.
      assert ms >= 2_450, "released after #{ms} ms"
    end

    # stream_timeout shorter than the hold: the silence deadline passes first
    # on a session that is otherwise complete. Falsifier: `on_wake/1`
    # consulting `timed_out?/1` before releasing and completing, which ends
    # a clean session with {:error, :timeout} (unreviewed-fixpass review F1).
    test "stream_timeout shorter than the hold: the held segment is released and the session completes" do
      {stub, input} = commits([[committed("one")]])
      {events, _ms} = run(stub, input, [options: @opted], stream_timeout: 300)

      refute Enum.any?(events, &match?({:error, _}, &1)), inspect(events)
      assert segments(events) == [{"one", nil}]
      assert {:transcription_completed, %{text: "one", language: nil}} = terminal(events)
    end

    # Falsifier: waiting out the 5 s bound, or dropping "one".
    test "the next segment's committed frame releases a held segment at once, in order" do
      {stub, input} =
        commits([[committed("one")], [committed("two"), stamped("one", "en"), stamped("two", "fr")]])

      {events, ms} =
        run(stub, input, [options: @opted], adapter_opts: [language_hold_ms: 5_000])

      # "one"'s late frame is consumed by commit order, so "two" keeps "fr".
      assert segments(events) == [{"one", nil}, {"two", "fr"}]
      assert ms < 2_000, "took #{ms} ms"
    end

    # The F3 order: segment 1 plain-first, segment 2 timestamped-first, the
    # same text. Falsifier: a text-keyed pairing gives segment 2 nil.
    test "two identical consecutive texts each keep their own language" do
      {stub, input} =
        commits([
          [committed("Yes."), stamped("Yes.", "en")],
          [stamped("Yes.", "fr"), committed("Yes.")]
        ])

      {events, _ms} = run(stub, input, options: @opted)

      assert segments(events) == [{"Yes.", "en"}, {"Yes.", "fr"}]
      assert {:transcription_completed, %{text: "Yes. Yes.", language: "fr"}} = terminal(events)
    end

    test "an error while a segment is held emits the segment before the error" do
      {stub, input} = commits([[committed("one"), {:close, 1011, "boom"}]])
      {events, _ms} = run(stub, input, [options: @opted], adapter_opts: [language_hold_ms: 5_000])

      assert [{:committed_transcript, %{text: "one", language: nil}}, {:error, err}] =
               Enum.drop_while(events, &(not match?({:committed_transcript, _}, &1)))

      assert err.reason == :network_error
    end

    # Default path: nothing is held. Falsifier: a hold applied without the
    # options (elapsed near the 5 s bound).
    test "not opted in: the segment is emitted on its plain frame, without waiting" do
      {stub, input} = commits([[committed("one")]])
      {events, ms} = run(stub, input, [], adapter_opts: [language_hold_ms: 5_000])

      assert segments(events) == [{"one", nil}]
      assert {:transcription_completed, _} = terminal(events)
      assert ms < 2_000, "took #{ms} ms"
    end
  end

  describe "server errors (WebSocketStub)" do
    for {type, reason} <- [
          {"auth_error", :authentication_failed},
          {"unaccepted_terms", :authentication_failed},
          {"quota_exceeded", :invalid_request},
          {"rate_limited", :rate_limited},
          {"commit_throttled", :rate_limited},
          {"queue_overflow", :rate_limited},
          {"resource_exhausted", :rate_limited},
          {"session_time_limit_exceeded", :context_length_exceeded},
          {"input_error", :invalid_request},
          {"invalid_request", :invalid_request},
          {"chunk_size_exceeded", :invalid_request},
          {"insufficient_audio_activity", :invalid_request},
          {"error", :provider_unavailable},
          {"transcriber_error", :provider_unavailable}
        ] do
      test "a #{type} frame mid-stream -> terminal #{reason}" do
        stub =
          WebSocketStub.install(
            [
              {:after_client, :any,
               [{:json, %{"message_type" => unquote(type), "error" => "provider said no"}}]}
            ],
            greeting: [started()]
          )

        # An input that never ends, so the frame is always read mid-stream
        # (after the end of input a commit_throttled completes the stream).
        {:ok, events} = Transcription.stream_transcribe(req(), endless([<<0, 0>>]), ws_opts(stub))

        assert [{:transcription_started, _}, {:error, %TranscriptionAdapterError{} = err}] =
                 Enum.to_list(events)

        assert err.reason == unquote(reason)
        assert err.provider == :elevenlabs
        assert err.metadata.code == unquote(type)
        assert err.message == "provider said no"
      end
    end

    test "recorded rt_bad_key: auth_error before session_started -> :authentication_failed, input never reduced" do
      env = Fixtures.realtime_recorded(:rt_bad_key)
      stub = WebSocketStub.install([], greeting: Fixtures.ws_server_frames(env))
      test_pid = self()
      input = Stream.map([<<0, 0>>], fn c -> send(test_pid, :reduced) && c end)

      {:ok, events} = Transcription.stream_transcribe(req(), input, ws_opts(stub))

      assert [
               {:error,
                %TranscriptionAdapterError{reason: :authentication_failed, metadata: meta} = err}
             ] = Enum.to_list(events)

      assert meta.code == "auth_error"
      assert err.message =~ "authenticated"
      refute_received :reduced
      assert WebSocketStub.close_count(stub) == 1
    end

    test "close code 1011 before the end -> :network_error" do
      stub =
        WebSocketStub.install([{:after_client, :any, [{:close, 1011, "internal"}]}],
          greeting: [started()]
        )

      {:ok, events} = Transcription.stream_transcribe(req(), [<<0, 0>>], ws_opts(stub))

      assert [_, {:error, %TranscriptionAdapterError{reason: :network_error} = err}] =
               Enum.to_list(events)

      assert err.metadata.close_code == 1011
    end

    test "an orderly close 1000 before the final segment still ends with :network_error" do
      stub = stub([{:close, 1000, ""}])
      {:ok, events} = Transcription.stream_transcribe(req(), [<<0, 0>>], ws_opts(stub))

      assert [_, {:error, %TranscriptionAdapterError{reason: :network_error}}] =
               Enum.to_list(events)
    end

    test "a transport close without a close frame -> :network_error" do
      stub = stub([:closed])
      {:ok, events} = Transcription.stream_transcribe(req(), [<<0, 0>>], ws_opts(stub))

      assert [_, {:error, %TranscriptionAdapterError{reason: :network_error}}] =
               Enum.to_list(events)
    end

    test "a server frame that is not JSON -> :malformed_response" do
      stub = stub([{:text, "not json"}])
      {:ok, events} = Transcription.stream_transcribe(req(), [<<0, 0>>], ws_opts(stub))

      assert [_, {:error, %TranscriptionAdapterError{reason: :malformed_response}}] =
               Enum.to_list(events)
    end

    test "a committed_transcript without a string text -> :malformed_response" do
      stub = stub([{:json, %{"message_type" => "committed_transcript", "text" => 1}}])
      {:ok, events} = Transcription.stream_transcribe(req(), [<<0, 0>>], ws_opts(stub))

      assert [_, {:error, %TranscriptionAdapterError{reason: :malformed_response}}] =
               Enum.to_list(events)
    end

    test "a transport error while reading -> :network_error with a sanitised cause" do
      stub = stub([{:transport_error, :econnreset}])
      {:ok, events} = Transcription.stream_transcribe(req(), [<<0, 0>>], ws_opts(stub))

      assert [_, {:error, %TranscriptionAdapterError{reason: :network_error} = err}] =
               Enum.to_list(events)

      assert {:ok, _} = Jason.encode(err)
    end

    test "a failed send of an audio frame -> :network_error" do
      stub = WebSocketStub.install([], greeting: [started()], send_error: :any)
      {:ok, events} = Transcription.stream_transcribe(req(), [<<0, 0>>], ws_opts(stub))

      assert [_, {:error, %TranscriptionAdapterError{reason: :network_error}}] =
               Enum.to_list(events)

      assert WebSocketStub.close_count(stub) == 1
    end

    test "unknown message types and tagged messages the transport does not recognise are skipped" do
      stub =
        stub([
          {:json, %{"message_type" => "something_new"}},
          :unknown,
          {:binary, <<1>>},
          committed("x")
        ])

      {:ok, events} = Transcription.stream_transcribe(req(), [<<0, 0>>], ws_opts(stub))
      assert {:transcription_completed, %{text: "x"}} = events |> Enum.to_list() |> terminal()
    end
  end

  # ===========================================================================
  # End of input (invariant 8)
  # ===========================================================================

  describe "end of input (WebSocketStub)" do
    test "a final commit is sent, and :transcription_completed waits for its committed segment" do
      stub = stub([partial("hi"), committed("hi there")])
      {:ok, events} = Transcription.stream_transcribe(req(), [<<0, 0>>], ws_opts(stub))

      assert [
               {:transcription_started, _},
               {:partial_transcript, _},
               {:committed_transcript, %{text: "hi there"}},
               {:transcription_completed, %{text: "hi there"}}
             ] = Enum.to_list(events)

      assert List.last(client_messages(stub)) == %{
               "message_type" => "input_audio_chunk",
               "audio_base_64" => "",
               "commit" => true,
               "sample_rate" => 16_000
             }
    end

    test "with no committed segment arriving, the wait ends with :timeout, not a completion" do
      stub = stub([])

      {:ok, events} =
        Transcription.stream_transcribe(req(), [<<0, 0>>], ws_opts(stub, stream_timeout: 100))

      assert [_, {:error, %TranscriptionAdapterError{reason: :timeout}}] = Enum.to_list(events)
      assert WebSocketStub.close_count(stub) == 1
    end

    test "no audio after the last :commit: no second commit, and the wait covers the caller's commit" do
      stub = stub([committed("done")])

      {:ok, events} =
        Transcription.stream_transcribe(
          req(commit_strategy: :manual),
          [<<0, 0>>, :commit],
          ws_opts(stub)
        )

      assert {:transcription_completed, %{text: "done"}} = events |> Enum.to_list() |> terminal()
      assert Enum.count(client_messages(stub), &(&1["commit"] == true)) == 1
    end

    test "an empty input completes at once with empty text, sending nothing" do
      stub = stub([])
      {:ok, events} = Transcription.stream_transcribe(req(), [], ws_opts(stub))

      assert [
               {:transcription_started, _},
               {:transcription_completed, %{text: "", duration_seconds: +0.0}}
             ] = Enum.to_list(events)

      assert client_messages(stub) == []
    end

    test "recorded rt_end: commit_throttled after the end of input completes the stream normally" do
      env = Fixtures.realtime_recorded(:rt_end)
      frames = Fixtures.ws_server_frames(env)
      assert [{:text, greeting} | rest] = frames
      assert %{"message_type" => "session_started"} = Jason.decode!(greeting)

      # The committed segment answers the caller's commit; the throttled
      # frame and the close answer the adapter's final commit.
      {answer, [throttled | tail]} =
        Enum.split_while(rest, fn
          {:text, json} -> Jason.decode!(json)["message_type"] != "commit_throttled"
          _ -> true
        end)

      stub =
        WebSocketStub.install(
          [{:after_client, &commit?/1, answer}, {:after_client, &commit?/1, [throttled | tail]}],
          greeting: [{:text, greeting}]
        )

      {:ok, events} =
        Transcription.stream_transcribe(
          req(sample_rate: 24_000),
          [<<0::size(9_600)-unit(8)>>, :commit, <<0, 0>>],
          ws_opts(stub)
        )

      events = Enum.to_list(events)
      refute Enum.any?(events, &match?({:error, _}, &1)), inspect(events)
      assert {:transcription_completed, %{text: "The quick brown fox jump-"}} = terminal(events)
    end
  end

  # ===========================================================================
  # Gates, hand-off, upgrade failures
  # ===========================================================================

  describe "pre-flight gates (keyless, raising :ws_module)" do
    test "sample_rate 11_025 -> synchronous :invalid_request with metadata.sample_rate" do
      assert {:error, %TranscriptionAdapterError{reason: :invalid_request} = err} =
               Transcription.stream_transcribe(req(sample_rate: 11_025), [<<0, 0>>],
                 ws_module: RaisingWebSocket
               )

      assert err.metadata.sample_rate == 11_025
      assert err.provider == :elevenlabs
    end

    test "a request the validator refuses -> synchronous :invalid_request with metadata.errors" do
      assert {:error, %TranscriptionAdapterError{reason: :invalid_request} = err} =
               Transcription.stream_transcribe(req(commit_strategy: :bogus), [<<0, 0>>],
                 ws_module: RaisingWebSocket
               )

      assert [_ | _] = err.metadata.errors
    end

    # Falsifier: no gate, so `:infinity` returns {:ok, stream} and raises
    # ArithmeticError inside enumeration (unreviewed-fixpass review F3).
    test "adapter_opts[:language_hold_ms] that is not a positive integer -> synchronous :invalid_request" do
      for bad <- [:infinity, 0, -5, 1.5, "1000", nil] do
        assert {:error, %TranscriptionAdapterError{reason: :invalid_request} = err} =
                 Transcription.stream_transcribe(req(), [<<0, 0>>],
                   ws_module: RaisingWebSocket,
                   adapter_opts: [language_hold_ms: bad]
                 ),
               "language_hold_ms: #{inspect(bad)}"

        assert err.metadata.field == :language_hold_ms
        assert err.metadata.language_hold_ms == bad
      end
    end

    test "every rate in stream_sample_rates/0 passes the gate" do
      stub = WebSocketStub.install([], connect: {:error, {:transport, :nxdomain}})

      for rate <- Transcription.stream_sample_rates() do
        assert {:ok, _events} =
                 Transcription.stream_transcribe(req(sample_rate: rate), [], ws_opts(stub))
      end
    end

    test "with transcription_script set, the Fake runs with this adapter's rates and no socket is opened" do
      opts = [ws_module: RaisingWebSocket, adapter_opts: [transcription_script: [{:ok, "hi"}]]]

      {:ok, events} = Transcription.stream_transcribe(req(sample_rate: 22_050), [<<0, 0>>], opts)
      assert {:transcription_completed, %{text: "hi"}} = events |> Enum.to_list() |> terminal()
    end
  end

  describe "upgrade failures never reduce the input" do
    setup do
      test_pid = self()
      %{input: Stream.map([<<0, 0>>], fn c -> send(test_pid, :reduced) && c end)}
    end

    test "{:upgrade_status, 401, body} -> :authentication_failed", %{input: input} do
      body = %{"detail" => %{"type" => "authentication_error", "code" => "unauthorized"}}
      stub = WebSocketStub.install([], connect: {:error, {:upgrade_status, 401, body}})

      {:ok, events} = Transcription.stream_transcribe(req(), input, ws_opts(stub))

      assert [{:error, %TranscriptionAdapterError{reason: :authentication_failed, status: 401}}] =
               Enum.to_list(events)

      refute_received :reduced
    end

    test "a transport failure at connect -> :network_error", %{input: input} do
      stub = WebSocketStub.install([], connect: {:error, {:transport, :econnrefused}})
      {:ok, events} = Transcription.stream_transcribe(req(), input, ws_opts(stub))

      assert [{:error, %TranscriptionAdapterError{reason: :network_error}}] = Enum.to_list(events)
      refute_received :reduced
    end

    test "no session_started within stream_timeout -> :timeout", %{input: input} do
      stub = WebSocketStub.install([], greeting: [])

      {:ok, events} =
        Transcription.stream_transcribe(req(), input, ws_opts(stub, stream_timeout: 50))

      assert [{:error, %TranscriptionAdapterError{reason: :timeout}}] = Enum.to_list(events)
      refute_received :reduced
    end
  end

  # ===========================================================================
  # Timers and halt-safety
  # ===========================================================================

  describe "timers" do
    # The stub stays silent until the final commit, so only pump messages
    # can keep the timer alive. Falsifier: a timer reset only by transport
    # messages ends the stream with :timeout.
    test "slow input under a short stream_timeout: five chunks 100 ms apart under 250 ms completes" do
      stub = stub([committed("slow")])
      input = Stream.map(1..5, fn _ -> Process.sleep(100) && <<0, 0>> end)

      {:ok, events} =
        Transcription.stream_transcribe(req(), input, ws_opts(stub, stream_timeout: 250))

      events = Enum.to_list(events)
      refute Enum.any?(events, &match?({:error, _}, &1)), inspect(events)
      assert {:transcription_completed, %{text: "slow"}} = terminal(events)
    end

    # The gap between chunks (150 ms) is longer than any plausible keep-alive
    # and shorter than stream_timeout. Falsifier: a finite keepalive_ms passed
    # to InputLoop.loop_state/3 wakes the loop with no keep-alive to send, so
    # it either ends the stream or spins (the reductions bound).
    test "no keep-alive is ever sent: only audio and commit frames go out, and no wake ends the stream" do
      stub = stub([committed("x")])
      input = Stream.map(1..2, fn _ -> Process.sleep(150) && <<0, 0>> end)

      {:ok, events} =
        Transcription.stream_transcribe(req(), input, ws_opts(stub, stream_timeout: 1_000))

      {:reductions, r0} = Process.info(self(), :reductions)
      events = Enum.to_list(events)
      {:reductions, r1} = Process.info(self(), :reductions)
      # A finite keep-alive that is never reset wakes the loop at once, over
      # and over: measured 2026-09-27, ~28M reductions spinning against ~3k
      # for the whole stream with keepalive_ms :infinity.
      assert r1 - r0 < 1_000_000, "the owner loop spun: #{r1 - r0} reductions"
      refute Enum.any?(events, &match?({:error, _}, &1)), inspect(events)
      assert {:transcription_completed, %{text: "x"}} = terminal(events)
      assert Enum.all?(client_messages(stub), &(&1["message_type"] == "input_audio_chunk"))
      assert length(client_messages(stub)) == 3
    end
  end

  describe "halt-safety" do
    test "Enum.take/2 closes the socket, and the pump is dead within 500 ms with no message left" do
      test_pid = self()

      stub =
        WebSocketStub.install([{:after_client, :any, [partial("a"), partial("ab")]}],
          greeting: [started()]
        )

      input =
        Stream.concat(
          Stream.map([<<0, 0>>], fn chunk -> send(test_pid, {:pump, self()}) && chunk end),
          Stream.repeatedly(fn -> Process.sleep(:infinity) end)
        )

      {:ok, events} = Transcription.stream_transcribe(req(), input, ws_opts(stub))

      assert [{:transcription_started, _}, {:partial_transcript, %{text: "a"}}] =
               Enum.take(events, 2)

      assert_received {:pump, pump}
      assert WebSocketStub.close_count(stub) == 1
      assert wait_until(fn -> not Process.alive?(pump) end, 500)

      refute_received {WebSocketStub, _, _}
      refute_received {_ref, {:input, _}}
      refute_received {:DOWN, _, :process, ^pump, _}
    end

    test "every resource function runs in the reducing process" do
      stub = stub([committed("x")])
      {:ok, events} = Transcription.stream_transcribe(req(), [<<0, 0>>], ws_opts(stub))

      {reducer, list} = Task.await(Task.async(fn -> {self(), Enum.to_list(events)} end))

      assert {:transcription_completed, _} = terminal(list)
      calls = WebSocketStub.calls(stub)
      assert Enum.all?(calls, fn {_name, pid} -> pid == reducer end)
      refute reducer == self()
    end
  end

  # ===========================================================================
  # End to end over WebSocket.Mint and WSTestServer
  # ===========================================================================

  describe "end to end over WebSocket.Mint and WSTestServer" do
    test "a session: started on the greeting, audio and the final commit on the wire, then the segment" do
      server =
        WSTestServer.start([
          {:send, {:text, ~s({"message_type":"session_started","session_id":"e2e"})}},
          :recv,
          :recv,
          {:send, {:text, ~s({"message_type":"committed_transcript","text":"over the wire"})}}
        ])

      {:ok, events} =
        Transcription.stream_transcribe(req(), [<<1, 2, 3, 4>>],
          api_key: @key,
          base_url: "http://127.0.0.1:#{server.port}"
        )

      assert [
               {:transcription_started, %{session_id: "e2e"}},
               {:committed_transcript, %{text: "over the wire"}},
               {:transcription_completed, %{text: "over the wire"}}
             ] = Enum.to_list(events)

      ref = server.ref
      assert_receive {WSTestServer, ^ref, {:handshake, target, headers}}
      assert {"xi-api-key", @key} in headers
      assert target =~ "/v1/speech-to-text/realtime?"
      refute target =~ @key

      assert_receive {WSTestServer, ^ref, {:frame, {:text, audio}}}
      assert %{"audio_base_64" => b64, "commit" => false} = Jason.decode!(audio)
      assert Base.decode64!(b64) == <<1, 2, 3, 4>>
      assert_receive {WSTestServer, ^ref, {:frame, {:text, commit}}}
      assert %{"commit" => true} = Jason.decode!(commit)
      refute_received {:tcp, _, _}
      refute_received {:tcp_closed, _}
    end
  end

  # ===========================================================================
  # Recorded sessions and the PCM fixture
  # ===========================================================================

  describe "recorded realtime sessions (replayed through the stub)" do
    test "rt_fox: the fox WAV's own PCM, replayed frames -> a committed segment with \"fox\"" do
      env = Fixtures.realtime_recorded(:rt_fox)
      assert env["status"] == 101
      [greeting | rest] = Fixtures.ws_server_frames(env)
      stub = WebSocketStub.install([{:after_client, &commit?/1, rest}], greeting: [greeting])

      {24_000, chunks} = PCM.wav_pcm_chunks(@fox_wav, 100)

      {:ok, events} =
        Transcription.stream_transcribe(req(sample_rate: 24_000), chunks, ws_opts(stub))

      events = Enum.to_list(events)
      assert {:transcription_completed, completed} = terminal(events)
      assert completed.text =~ "fox"
      assert_in_delta completed.duration_seconds, 3.8, 0.001
      assert IO.iodata_to_binary(audio_frames(stub)) == IO.iodata_to_binary(chunks)
      # Recorded order: the plain frame, then its timestamped twin. Not opted
      # in (the default path), the segment goes out on the plain frame and
      # the twin is dropped with its language ("en" in the recording).
      assert env["summary"]["commit_frame_order"] ==
               ["committed_transcript", "committed_transcript_with_timestamps"]

      assert completed.language == nil
    end

    test "rt_fox opted in, as recorded: the segment is held for its twin and carries \"en\"" do
      env = Fixtures.realtime_recorded(:rt_fox)
      assert env["url"] =~ "include_timestamps=true"
      [greeting | rest] = Fixtures.ws_server_frames(env)
      stub = WebSocketStub.install([{:after_client, &commit?/1, rest}], greeting: [greeting])
      {24_000, chunks} = PCM.wav_pcm_chunks(@fox_wav, 100)

      request =
        req(
          sample_rate: 24_000,
          options: %{"include_timestamps" => true, "include_language_detection" => true}
        )

      {:ok, events} = Transcription.stream_transcribe(request, chunks, ws_opts(stub))
      events = Enum.to_list(events)

      assert [{:committed_transcript, %{text: text, language: "en"}}] =
               for({:committed_transcript, _} = e <- events, do: e)

      assert text =~ "fox"
      assert {:transcription_completed, %{language: "en"}} = terminal(events)
    end

    test "rt_manual_commit: two commits, two committed segments" do
      env = Fixtures.realtime_recorded(:rt_manual_commit)
      [greeting | rest] = Fixtures.ws_server_frames(env)

      {first, second} =
        Enum.split_while(rest, fn
          {:text, json} -> Jason.decode!(json)["message_type"] != "committed_transcript"
          _ -> true
        end)

      {segment_1, rest_2} = Enum.split(second, 1)

      stub =
        WebSocketStub.install(
          [
            {:after_client, &commit?/1, first ++ segment_1},
            {:after_client, &commit?/1, rest_2}
          ],
          greeting: [greeting]
        )

      {:ok, events} =
        Transcription.stream_transcribe(
          req(sample_rate: 24_000, commit_strategy: :manual),
          [<<0::size(4_800)-unit(8)>>, :commit, <<0::size(4_800)-unit(8)>>],
          ws_opts(stub)
        )

      events = Enum.to_list(events)
      assert length(for({:committed_transcript, _} <- events, do: 1)) == 2
      assert {:transcription_completed, %{text: text}} = terminal(events)
      assert text == Enum.join(env["summary"]["committed"], " ")
    end

    test "the recorded URLs carry no key and the adapter's structural parameters" do
      for name <- ~w(rt_fox rt_manual_commit rt_end rt_control rt_big_chunk rt_bad_key)a do
        url = Fixtures.realtime_recorded(name)["url"]
        refute url =~ "sk_", "#{name} URL carries key material"
        assert url =~ "/v1/speech-to-text/realtime?"
        assert url =~ "model_id=scribe_v2_realtime"
        assert url =~ "audio_format=pcm_24000"
      end
    end

    test "recorded client frames never store audio" do
      for name <- ~w(rt_fox rt_manual_commit rt_end rt_control rt_big_chunk rt_bad_key)a,
          %{"dir" => "in", "text" => text} <- Fixtures.realtime_recorded(name)["frames"] do
        assert Jason.decode!(text)["audio_base_64"] =~ ~r/^<\d+ bytes>$/
      end
    end
  end

  describe "ALLM.Test.PCM.wav_pcm_chunks/2 over the streaming fox WAV" do
    test "reads the rate from the header and the data chunk to end of file" do
      # The fixture's RIFF and data sizes are 0xFFFFFFFF (a streaming WAV).
      assert <<"RIFF", 0xFFFFFFFF::little-32, _::binary-size(32), 0xFFFFFFFF::little-32, _::binary>> =
               File.read!(@fox_wav)

      {rate, chunks} = PCM.wav_pcm_chunks(@fox_wav, 100)
      assert rate == 24_000
      assert chunks |> IO.iodata_to_binary() |> byte_size() == 182_400

      {full, [last]} = Enum.split(chunks, -1)
      assert Enum.all?(full, &(byte_size(&1) == 4_800))
      assert byte_size(last) in 1..4_800
    end

    test "a WAV whose data size is declared exactly is sliced to that size" do
      pcm = :binary.copy(<<1, 0>>, 800)

      wav =
        <<"RIFF", 36 + byte_size(pcm)::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16,
          1::little-16, 8_000::little-32, 16_000::little-32, 2::little-16, 16::little-16, "LIST",
          4::little-32, "INFO", "data", byte_size(pcm)::little-32, pcm::binary, "trailing">>

      path = Path.join(System.tmp_dir!(), "allm_pcm_#{System.unique_integer([:positive])}.wav")
      File.write!(path, wav)
      on_exit(fn -> File.rm(path) end)

      assert {8_000, chunks} = PCM.wav_pcm_chunks(path, 50)
      assert IO.iodata_to_binary(chunks) == pcm
      assert Enum.map(chunks, &byte_size/1) == [800, 800]
    end
  end

  describe "recorded fixture provenance (raw bytes)" do
    @recorded ~w(rt_bad_key rt_big_chunk rt_control rt_end rt_fox rt_manual_commit)

    test "@recorded enumerates every file under realtime/recorded/" do
      assert Fixtures.names_on_disk("realtime/recorded") == @recorded
    end

    for name <- @recorded do
      test "realtime/recorded/#{name}.json carries no _comment marker" do
        raw = Fixtures.raw("realtime/recorded", unquote(name))

        refute Map.has_key?(raw, "_comment"),
               "#{unquote(name)} is a placeholder; re-record with " <>
                 "( set -a; . ./.env; set +a; mix run scripts/record_elevenlabs_audio_fixtures.exs )"
      end
    end
  end

  defp wait_until(fun, budget) do
    cond do
      fun.() ->
        true

      budget <= 0 ->
        false

      true ->
        Process.sleep(10)
        wait_until(fun, budget - 10)
    end
  end
end
