defmodule ALLM.Providers.ElevenLabs.SpeechStreamTest do
  @moduledoc """
  Wire tests for `ALLM.Providers.ElevenLabs.Speech`'s two stream paths:

    * `stream_synthesize/2` (HTTP `/stream`) over `ALLM.Test.FinchStub`;
    * `stream_synthesize_input/3` (WebSocket `/stream-input`) over
      `ALLM.Test.WebSocketStub`, plus two end-to-end rows over the real
      `ALLM.Providers.Support.WebSocket.Mint` and `ALLM.Test.WSTestServer`,
      which bind the socket's own `:tcp` message tags.

  Recorded frames (`test/fixtures/elevenlabs/speech_stream/recorded/`) are
  replayed through the stub. Keyless gate tests pass a raising
  `:finch_module` / `:ws_module`, so a gate moved after key resolution or
  into the stream fails even in a shell that exports `ELEVENLABS_API_KEY`.
  """

  use ExUnit.Case, async: true

  alias ALLM.Error.SpeechAdapterError
  alias ALLM.Providers.ElevenLabs.Speech
  alias ALLM.Providers.ElevenLabsTestFixtures, as: Fixtures
  alias ALLM.Providers.OpenAITestFixtures
  alias ALLM.SpeechEvent
  alias ALLM.SpeechRequest
  alias ALLM.Test.{FinchStub, RaisingFinch, RaisingWebSocket, WebSocketStub, WSTestServer}

  @moduletag timeout: 20_000

  @voice "JBFqnCBsd6RMkjVDRZzb"
  @key "sk_streamtest0123456789abcdef"

  # Delivers every frame synchronously inside `async_request/3`, so all of
  # them are queued in the caller's mailbox before the stream reads one.
  defmodule BurstFinch do
    @moduledoc false
    def async_request(_req, _name, opts) do
      ref = make_ref()
      send(self(), {ref, {:status, 200}})
      send(self(), {ref, {:headers, [{"content-type", "audio/pcm"}]}})
      for chunk <- Keyword.fetch!(opts, :finch_stub_ref), do: send(self(), {ref, {:data, chunk}})
      send(self(), {ref, :done})
      Process.put(:burst_ref, ref)
      ref
    end

    def cancel_async_request(ref) do
      Process.put({:burst_cancel, ref}, Process.get({:burst_cancel, ref}, 0) + 1)
      :ok
    end
  end

  # Tells the reducing process which request it was asked for, then
  # forwards to FinchStub.
  defmodule CapturingFinch do
    @moduledoc false
    def async_request(req, name, opts) do
      send(self(), {:finch_request, req, name})
      FinchStub.async_request(req, name, opts)
    end

    defdelegate cancel_async_request(ref), to: FinchStub
  end

  @pcm_headers [
    {"content-type", "audio/pcm"},
    {"request-id", "req_el_1"},
    {"character-cost", "6"}
  ]

  defp req(opts \\ []), do: SpeechRequest.new(Keyword.merge([input: "Hello."], opts))
  defp input_req(opts \\ []), do: SpeechRequest.new(Keyword.merge([input: "", format: :pcm], opts))

  defp http_opts(stub_ref, opts \\ []) do
    Keyword.merge([api_key: @key, finch_module: FinchStub, finch_stub_ref: stub_ref], opts)
  end

  defp ws_opts(stub, opts \\ []) do
    Keyword.merge([api_key: @key, ws_module: WebSocketStub, ws_stub: stub], opts)
  end

  defp audio(bytes), do: {:json, %{"audio" => Base.encode64(bytes), "isFinal" => nil}}
  defp final, do: {:json, %{"audio" => nil, "isFinal" => true}}

  # The client's end-of-input message (`{"text": ""}`, not the flush).
  @close_text %{"text" => ""}

  defp text_frames(stub) do
    for {:text, json} <- WebSocketStub.sent_frames(stub), do: Jason.decode!(json)
  end

  # ===========================================================================
  # HTTP /stream
  # ===========================================================================

  describe "stream_synthesize/2 (HTTP /stream)" do
    test "200 + audio/pcm + chunks -> started, one delta per chunk, completed with the request-id" do
      ref = FinchStub.install(["a", "bb", "ccc"], initial_headers: @pcm_headers)

      assert {:ok, stream} =
               Speech.stream_synthesize(
                 req(format: :pcm, metadata: %{"k" => "v"}),
                 http_opts(ref, request_id: "rid-1")
               )

      assert [
               {:speech_started, started},
               {:audio_delta, "a"},
               {:audio_delta, "bb"},
               {:audio_delta, "ccc"},
               {:speech_completed, completed}
             ] = Enum.to_list(stream)

      assert started == %{
               request_id: "rid-1",
               model: "eleven_flash_v2_5",
               provider: :elevenlabs,
               format: :pcm,
               mime_type: "audio/pcm",
               sample_rate: 24_000
             }

      assert completed == %{
               request_id: "rid-1",
               id: "req_el_1",
               usage: %ALLM.Usage{},
               metadata: %{"k" => "v"}
             }
    end

    test "the request is POST /v1/text-to-speech/{voice}/stream with the non-streaming body and xi-api-key" do
      ref = FinchStub.install(["a"], initial_headers: @pcm_headers)
      request = req(format: :pcm, speed: 1.1)

      {:ok, stream} =
        Speech.stream_synthesize(request, http_opts(ref, finch_module: CapturingFinch))

      Enum.to_list(stream)

      assert_received {:finch_request, %Finch.Request{} = finch_req, ALLM.Finch}
      assert finch_req.method == "POST"
      assert finch_req.host == "api.elevenlabs.io"
      assert finch_req.path == "/v1/text-to-speech/#{@voice}/stream"
      assert URI.decode_query(finch_req.query) == %{"output_format" => "pcm_24000"}
      assert {"xi-api-key", @key} in finch_req.headers
      assert {"content-type", "application/json"} in finch_req.headers
      assert Jason.decode!(finch_req.body) == Speech.to_json_body(request, [])
    end

    test "stream_url/2 is url/2 with /stream after the voice" do
      request = req(format: :mp3, sample_rate: 22_050, voice: "v1")

      assert Speech.stream_url(request, []) ==
               String.replace(Speech.url(request, []), "/v1?", "/v1/stream?")
    end

    test "no transport call is made until the stream is reduced" do
      assert {:ok, _stream} =
               Speech.stream_synthesize(req(), api_key: @key, finch_module: RaisingFinch)
    end

    test "an mp3 stream reports the requested sample rate" do
      ref = FinchStub.install(["ID3"], initial_headers: [{"content-type", "audio/mpeg"}])
      {:ok, stream} = Speech.stream_synthesize(req(), http_opts(ref))

      assert [{:speech_started, %{format: :mp3, sample_rate: 44_100, mime_type: "audio/mpeg"}} | _] =
               Enum.to_list(stream)
    end
  end

  describe "stream_synthesize/2 pre-flight gates (keyless, raising :finch_module)" do
    for {label, fields, reason, field} <- [
          {"instructions", [instructions: "x"], :unsupported_feature, :instructions},
          {"format :aac", [format: :aac], :unsupported_feature, :format},
          {"opus at 24_000", [format: :opus, sample_rate: 24_000], :unsupported_feature,
           :sample_rate},
          {"empty input", [input: ""], :invalid_request, :input}
        ] do
      test "#{label} -> synchronous #{reason}" do
        assert {:error, %SpeechAdapterError{reason: unquote(reason)} = err} =
                 Speech.stream_synthesize(req(unquote(fields)), finch_module: RaisingFinch)

        assert err.metadata.field == unquote(field)
      end
    end
  end

  describe "stream_synthesize/2 failures" do
    test "the recorded 401 bad-key body -> :authentication_failed, status 401" do
      env = Fixtures.speech_recorded(:error_401_bad_key)

      ref =
        FinchStub.install([],
          initial_status: env["status"],
          initial_headers: [{"content-type", "application/json"}],
          error_body: Jason.encode!(env["body"])
        )

      {:ok, stream} = Speech.stream_synthesize(req(), http_opts(ref))

      assert [{:error, %SpeechAdapterError{reason: :authentication_failed} = err}] =
               Enum.to_list(stream)

      assert err.status == 401
    end

    test "the recorded 403 tier gate -> :unsupported_feature" do
      env = Fixtures.speech_recorded(:error_403_tier)

      ref =
        FinchStub.install([], initial_status: 403, error_body: Jason.encode!(env["body"]))

      {:ok, stream} =
        Speech.stream_synthesize(req(format: :pcm, sample_rate: 44_100), http_opts(ref))

      assert [{:error, %SpeechAdapterError{reason: :unsupported_feature}}] = Enum.to_list(stream)
    end

    test "a 429 honours Retry-After on the terminal error" do
      ref =
        FinchStub.install([],
          initial_status: 429,
          initial_headers: [{"retry-after", "2"}],
          error_body: ~s({"detail":{"status":"rate_limit_exceeded","message":"slow down"}})
        )

      {:ok, stream} = Speech.stream_synthesize(req(), http_opts(ref))

      assert [{:error, %SpeechAdapterError{reason: :rate_limited, retry_after_ms: 2_000}}] =
               Enum.to_list(stream)
    end

    test "200 with a non-audio content type -> :malformed_response, and the request is cancelled" do
      ref = FinchStub.install(["{}"], initial_headers: [{"content-type", "application/json"}])
      {:ok, stream} = Speech.stream_synthesize(req(), http_opts(ref))

      assert [{:error, %SpeechAdapterError{reason: :malformed_response}}] = Enum.to_list(stream)
      assert FinchStub.cancel_count(ref) == 1
    end

    test "200 with no audio bytes -> :invalid_request, cause :empty_input" do
      ref = FinchStub.install([], initial_headers: @pcm_headers)
      {:ok, stream} = Speech.stream_synthesize(req(format: :pcm), http_opts(ref))

      assert [
               {:speech_started, _},
               {:error,
                %SpeechAdapterError{reason: :invalid_request, metadata: %{cause: :empty_input}}}
             ] = Enum.to_list(stream)
    end
  end

  describe "stream_synthesize/2 halt-safety and stream_timeout" do
    test "Enum.take/2 halts the stream and cancels the request once" do
      ref = FinchStub.install(["a", "b", "c", "d"], initial_headers: @pcm_headers, delay_ms: 20)
      {:ok, stream} = Speech.stream_synthesize(req(format: :pcm), http_opts(ref))

      assert [{:speech_started, _}, {:audio_delta, "a"}] = Enum.take(stream, 2)
      assert FinchStub.cancel_count(ref) == 1
    end

    # Every frame is queued before the first is read, so chunks are still in
    # the mailbox when `Enum.take/2` halts. Falsifier: an after function that
    # cancels without draining.
    test "a halt drains the request's queued messages from the mailbox" do
      {:ok, stream} =
        Speech.stream_synthesize(req(format: :pcm),
          api_key: @key,
          finch_module: BurstFinch,
          finch_stub_ref: ["1", "2", "3", "4", "5"]
        )

      assert [{:speech_started, _}, {:audio_delta, "1"}] = Enum.take(stream, 2)

      ref = Process.get(:burst_ref)
      assert Process.get({:burst_cancel, ref}) == 1
      refute_received {^ref, _}
    end

    test "stream_timeout: 50 with 200 ms between chunks -> terminal :timeout" do
      ref = FinchStub.install(["a"], initial_headers: @pcm_headers, delay_ms: 200)

      {:ok, stream} =
        Speech.stream_synthesize(req(format: :pcm), http_opts(ref, stream_timeout: 50))

      assert [{:speech_started, _}, {:error, %SpeechAdapterError{reason: :timeout}}] =
               Enum.to_list(stream)

      assert FinchStub.cancel_count(ref) == 1
    end
  end

  describe "stream_synthesize/2 recorded fixture" do
    test "stream_chunked: one delta per recorded chunk, concatenating to the recorded body" do
      env = Fixtures.speech_stream_recorded(:stream_chunked)
      chunks = OpenAITestFixtures.speech_stream_chunks(env)

      # The recorded response really streamed.
      assert length(env["chunks"]) >= 2
      assert hd(env["chunks"])["t_ms"] < List.last(env["chunks"])["t_ms"]

      ref = FinchStub.install(chunks, initial_headers: Enum.to_list(env["headers"]), delay_ms: 0)
      {:ok, stream} = Speech.stream_synthesize(req(format: :pcm), http_opts(ref))
      events = Enum.to_list(stream)

      assert {:speech_started, %{format: :pcm, sample_rate: 24_000}} = hd(events)
      assert {:speech_completed, %{id: id}} = List.last(events)
      assert id == env["headers"]["request-id"]

      deltas = for {:audio_delta, bytes} <- events, do: bytes
      assert length(deltas) == length(chunks)
      assert IO.iodata_to_binary(deltas) == OpenAITestFixtures.envelope_bytes(env)
    end
  end

  describe "stream_synthesize/2 script hand-off" do
    test "with speech_script set, the Fake stream runs and Finch is never called" do
      {:ok, stream} =
        Speech.stream_synthesize(req(),
          finch_module: RaisingFinch,
          adapter_opts: [speech_script: [{:ok, "FAKE"}]]
        )

      assert "FAKE" == for({:audio_delta, b} <- stream, into: "", do: b)
    end
  end

  # ===========================================================================
  # WebSocket /stream-input
  # ===========================================================================

  describe "ws_url/2 and init_message/2" do
    test "wss host, path and query; the key is in neither the URL nor an authorization parameter" do
      url = Speech.ws_url(input_req(), api_key: @key)
      uri = URI.parse(url)

      assert uri.scheme == "wss"
      assert uri.host == "api.elevenlabs.io"
      assert uri.path == "/v1/text-to-speech/#{@voice}/stream-input"

      assert URI.decode_query(uri.query) == %{
               "model_id" => "eleven_flash_v2_5",
               "output_format" => "pcm_24000",
               "inactivity_timeout" => "60",
               "auto_mode" => "true"
             }

      refute url =~ @key
      refute url =~ "authorization"
    end

    for {stream_timeout, want} <- [{300_000, "180"}, {1_500, "2"}, {100, "1"}, {:infinity, "180"}] do
      test "inactivity_timeout for stream_timeout #{inspect(stream_timeout)} is #{want}" do
        query =
          input_req() |> Speech.ws_url(stream_timeout: unquote(stream_timeout)) |> URI.parse()

        assert URI.decode_query(query.query)["inactivity_timeout"] == unquote(want)
      end
    end

    test "options[\"query\"] sets auto_mode and extra parameters, but not the structural ones" do
      request =
        input_req(
          model: "eleven_multilingual_v2",
          options: %{
            "query" => %{"auto_mode" => false, "model_id" => "x", "enable_logging" => false}
          }
        )

      query =
        request |> Speech.ws_url([]) |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert query["auto_mode"] == "false"
      assert query["enable_logging"] == "false"
      assert query["model_id"] == "eleven_multilingual_v2"
    end

    test "an http base URL gives a ws:// URL, and base_url picks the host" do
      assert "ws://127.0.0.1:4000/v1/text-to-speech/" <> _ =
               Speech.ws_url(input_req(), base_url: "http://127.0.0.1:4000")

      assert "wss://api.eu.residency.elevenlabs.io/" <> _ =
               Speech.ws_url(input_req(), base_url: "https://api.eu.residency.elevenlabs.io")
    end

    test "the initial message is a single space plus voice_settings and options, without model_id" do
      request =
        input_req(
          speed: 1.1,
          options: %{
            "voice_settings" => %{"stability" => 0.3},
            "generation_config" => %{"chunk_length_schedule" => [50]},
            "model_id" => "dropped",
            "query" => %{"auto_mode" => false}
          }
        )

      assert Speech.init_message(request, []) == %{
               "text" => " ",
               "voice_settings" => %{"stability" => 0.3, "speed" => 1.1},
               "generation_config" => %{"chunk_length_schedule" => [50]}
             }
    end
  end

  describe "stream_synthesize_input/3 wire (WebSocketStub)" do
    test "the upgrade carries xi-api-key; the URL carries neither the key nor authorization=" do
      stub = WebSocketStub.install([{:after_client, @close_text, [audio("A"), final()]}])
      {:ok, stream} = Speech.stream_synthesize_input(input_req(), ["Hi."], ws_opts(stub))
      Enum.to_list(stream)

      assert [{url, headers}] = WebSocketStub.connects(stub)
      assert {"xi-api-key", @key} in headers
      refute url =~ @key
      refute url =~ "authorization="
    end

    test "auto_mode off: the init message, one {\"text\": c} per non-empty chunk with no appended space, flush, close" do
      stub = WebSocketStub.install([{:after_client, @close_text, [audio("A"), final()]}])

      {:ok, stream} =
        Speech.stream_synthesize_input(
          input_req(options: %{"query" => %{"auto_mode" => false}}),
          ["Hel", "", "lo", " world", "."],
          ws_opts(stub)
        )

      Enum.to_list(stream)
      assert WebSocketStub.connects(stub) |> hd() |> elem(0) =~ "auto_mode=false"

      assert text_frames(stub) == [
               %{"text" => " "},
               %{"text" => "Hel"},
               %{"text" => "lo"},
               %{"text" => " world"},
               %{"text" => "."},
               %{"text" => "", "flush" => true},
               %{"text" => ""}
             ]
    end

    # Owner decision 2026-09-27: auto_mode stays the default, and the text
    # is buffered to word boundaries so sub-word deltas are never voiced as
    # separate clips. Falsifier: "Hel" or "lo" on the wire as its own frame.
    test "auto_mode (default): sub-word chunks are sent at word boundaries" do
      stub = WebSocketStub.install([{:after_client, @close_text, [audio("A"), final()]}])

      {:ok, stream} =
        Speech.stream_synthesize_input(input_req(), ["Hel", "lo", " world", "."], ws_opts(stub))

      assert {:speech_completed, _} = stream |> Enum.to_list() |> List.last()
      assert WebSocketStub.connects(stub) |> hd() |> elem(0) =~ "auto_mode=true"

      assert text_frames(stub) == [
               %{"text" => " "},
               %{"text" => "Hello "},
               %{"text" => "world."},
               %{"text" => "", "flush" => true},
               %{"text" => ""}
             ]
    end

    test "auto_mode (default): a trailing partial word is sent at the end of input, before the flush" do
      stub = WebSocketStub.install([{:after_client, @close_text, [audio("A"), final()]}])

      {:ok, stream} =
        Speech.stream_synthesize_input(
          input_req(),
          ["Good", " morn", "ing, wor", "ld"],
          ws_opts(stub)
        )

      assert {:speech_completed, _} = stream |> Enum.to_list() |> List.last()

      assert text_frames(stub) == [
               %{"text" => " "},
               %{"text" => "Good "},
               %{"text" => "morning, "},
               %{"text" => "world"},
               %{"text" => "", "flush" => true},
               %{"text" => ""}
             ]
    end

    test "auto_mode (default): a chunk with no boundary is held, and the keep-alive still goes out" do
      stub = WebSocketStub.install([{:after_client, @close_text, [audio("A"), final()]}])

      input =
        Stream.map(["Hel", "lo"], fn
          "lo" -> Process.sleep(700) && "lo"
          chunk -> chunk
        end)

      {:ok, stream} =
        Speech.stream_synthesize_input(input_req(), input, ws_opts(stub, stream_timeout: 1_000))

      assert {:speech_completed, _} = stream |> Enum.to_list() |> List.last()
      texts = stub |> text_frames() |> Enum.map(& &1["text"])
      assert [" ", " ", "Hello", "", ""] = texts
    end

    for {text, want} <- [
          {"Hel", {"", "Hel"}},
          {"Hello wor", {"Hello ", "wor"}},
          {"Hello world.", {"Hello ", "world."}},
          {"pi is 3.14", {"pi is ", "3.14"}},
          {"don't", {"", "don't"}},
          {"Really?", {"Really?", ""}},
          {"a\nb", {"a\n", "b"}},
          {"こんにちは。元気", {"こんにちは。", "元気"}},
          {"", {"", ""}}
        ] do
      test "split_at_word_boundary(#{inspect(text)}) is #{inspect(want)}" do
        assert Speech.split_at_word_boundary(unquote(text)) == unquote(Macro.escape(want))
      end
    end

    test "server audio frames decode to deltas and isFinal ends with :speech_completed" do
      stub =
        WebSocketStub.install([
          {:after_client, %{"text" => "Hi."}, [audio("one"), audio("two")]},
          {:after_client, @close_text,
           [{:json, %{"audio" => "", "isFinal" => nil}}, audio("three"), final()]}
        ])

      {:ok, stream} =
        Speech.stream_synthesize_input(
          input_req(metadata: %{"k" => "v"}),
          ["Hi."],
          ws_opts(stub, request_id: "rid-ws")
        )

      assert [
               {:speech_started, started},
               {:audio_delta, "one"},
               {:audio_delta, "two"},
               {:audio_delta, "three"},
               {:speech_completed, completed}
             ] = Enum.to_list(stream)

      assert started == %{
               request_id: "rid-ws",
               model: "eleven_flash_v2_5",
               provider: :elevenlabs,
               format: :pcm,
               mime_type: "audio/pcm",
               sample_rate: 24_000
             }

      assert completed == %{
               request_id: "rid-ws",
               id: nil,
               usage: %ALLM.Usage{},
               metadata: %{"k" => "v"}
             }
    end

    test "every emitted element is a SpeechEvent" do
      stub = WebSocketStub.install([{:after_client, @close_text, [audio("A"), final()]}])
      {:ok, stream} = Speech.stream_synthesize_input(input_req(), ["Hi."], ws_opts(stub))
      assert Enum.all?(Enum.to_list(stream), &SpeechEvent.event?/1)
    end

    test "a server ping produces a client pong and no event" do
      stub =
        WebSocketStub.install([
          {:after_client, %{"text" => "Hi."}, [{:ping, "p1"}]},
          {:after_client, @close_text, [audio("A"), final()]}
        ])

      {:ok, stream} = Speech.stream_synthesize_input(input_req(), ["Hi."], ws_opts(stub))

      assert [{:speech_started, _}, {:audio_delta, "A"}, {:speech_completed, _}] =
               Enum.to_list(stream)

      assert {:pong, "p1"} in WebSocketStub.sent_frames(stub)
    end
  end

  describe "stream_synthesize_input/3 server errors" do
    test ~s(a {"message_type": "auth_error"} frame -> terminal :authentication_failed) do
      stub =
        WebSocketStub.install([
          {:after_client, :any, [{:json, %{"message_type" => "auth_error"}}]}
        ])

      {:ok, stream} = Speech.stream_synthesize_input(input_req(), ["Hi."], ws_opts(stub))

      assert [{:speech_started, _}, {:error, %SpeechAdapterError{reason: :authentication_failed}}] =
               Enum.to_list(stream)
    end

    for {name, reason, code} <- [
          {:ws_bad_key, :authentication_failed, "invalid_api_key"},
          {:ws_bad_voice, :invalid_request, "voice_id_does_not_exist"}
        ] do
      test "recorded #{name}: the error frame -> #{reason}, and nothing after it" do
        env = Fixtures.speech_stream_recorded(unquote(name))
        stub = WebSocketStub.install([{:after_client, :any, Fixtures.ws_server_frames(env)}])

        {:ok, stream} = Speech.stream_synthesize_input(input_req(), ["Hi."], ws_opts(stub))

        assert [{:speech_started, _}, {:error, %SpeechAdapterError{} = err}] = Enum.to_list(stream)
        assert err.reason == unquote(reason)
        assert err.provider == :elevenlabs
        assert err.metadata.code == unquote(code)
        assert err.metadata.close_code == 1008
        assert is_binary(err.message) and err.message != ""
      end
    end

    test "close code 1011 before isFinal -> :network_error" do
      stub = WebSocketStub.install([{:after_client, :any, [{:close, 1011, "internal"}]}])
      {:ok, stream} = Speech.stream_synthesize_input(input_req(), ["Hi."], ws_opts(stub))

      assert [{:speech_started, _}, {:error, %SpeechAdapterError{reason: :network_error} = err}] =
               Enum.to_list(stream)

      assert err.metadata.close_code == 1011
    end

    test "an orderly close 1000 before isFinal still ends with :network_error" do
      stub = WebSocketStub.install([{:after_client, @close_text, [audio("A"), {:close, 1000, ""}]}])
      {:ok, stream} = Speech.stream_synthesize_input(input_req(), ["Hi."], ws_opts(stub))

      assert [_, {:audio_delta, "A"}, {:error, %SpeechAdapterError{reason: :network_error}}] =
               Enum.to_list(stream)
    end

    test "a transport close without a close frame -> :network_error" do
      stub = WebSocketStub.install([{:after_client, :any, [:closed]}])
      {:ok, stream} = Speech.stream_synthesize_input(input_req(), ["Hi."], ws_opts(stub))

      assert [_, {:error, %SpeechAdapterError{reason: :network_error}}] = Enum.to_list(stream)
    end

    test "a server frame that is not JSON -> :malformed_response" do
      stub = WebSocketStub.install([{:after_client, :any, [{:text, "not json"}]}])
      {:ok, stream} = Speech.stream_synthesize_input(input_req(), ["Hi."], ws_opts(stub))

      assert [_, {:error, %SpeechAdapterError{reason: :malformed_response}}] = Enum.to_list(stream)
    end

    test "audio that is not base64 -> :malformed_response" do
      stub = WebSocketStub.install([{:after_client, :any, [{:json, %{"audio" => "!!"}}]}])
      {:ok, stream} = Speech.stream_synthesize_input(input_req(), ["Hi."], ws_opts(stub))

      assert [_, {:error, %SpeechAdapterError{reason: :malformed_response}}] = Enum.to_list(stream)
    end

    test "isFinal with no audio at all -> :invalid_request, cause :empty_input" do
      stub = WebSocketStub.install([{:after_client, @close_text, [final()]}])
      {:ok, stream} = Speech.stream_synthesize_input(input_req(), ["Hi."], ws_opts(stub))

      assert [
               _,
               {:error,
                %SpeechAdapterError{reason: :invalid_request, metadata: %{cause: :empty_input}}}
             ] = Enum.to_list(stream)
    end

    test "a server that never answers -> :timeout after stream_timeout" do
      stub = WebSocketStub.install([])

      {:ok, stream} =
        Speech.stream_synthesize_input(input_req(), ["Hi."], ws_opts(stub, stream_timeout: 50))

      assert [_, {:error, %SpeechAdapterError{reason: :timeout}}] = Enum.to_list(stream)
      assert WebSocketStub.close_count(stub) == 1
    end
  end

  describe "stream_synthesize_input/3 transport edge cases" do
    test "a failed send of the initial message -> :network_error, and the input is never started" do
      stub = WebSocketStub.install([], send_error: %{"text" => " "})
      {:ok, stream} = Speech.stream_synthesize_input(input_req(), [123], ws_opts(stub))

      assert [{:error, %SpeechAdapterError{reason: :network_error}}] = Enum.to_list(stream)
      assert WebSocketStub.close_count(stub) == 1
    end

    test "a failed send of a text chunk -> :network_error" do
      stub = WebSocketStub.install([], send_error: %{"text" => "Hi."})
      {:ok, stream} = Speech.stream_synthesize_input(input_req(), ["Hi."], ws_opts(stub))

      assert [{:speech_started, _}, {:error, %SpeechAdapterError{reason: :network_error}}] =
               Enum.to_list(stream)
    end

    test "a failed send of the flush -> :network_error" do
      stub = WebSocketStub.install([], send_error: %{"text" => "", "flush" => true})
      {:ok, stream} = Speech.stream_synthesize_input(input_req(), ["Hi."], ws_opts(stub))

      assert [_, {:error, %SpeechAdapterError{reason: :network_error}}] = Enum.to_list(stream)
    end

    test "a transport error while reading -> :network_error with a sanitised cause" do
      stub = WebSocketStub.install([{:after_client, :any, [{:transport_error, :econnreset}]}])
      {:ok, stream} = Speech.stream_synthesize_input(input_req(), ["Hi."], ws_opts(stub))

      assert [_, {:error, %SpeechAdapterError{reason: :network_error}}] = Enum.to_list(stream)
    end

    test "a tagged message the transport does not recognise is skipped" do
      stub =
        WebSocketStub.install([
          {:after_client, @close_text, [:unknown, {:binary, <<1>>}, audio("A"), final()]}
        ])

      {:ok, stream} = Speech.stream_synthesize_input(input_req(), ["Hi."], ws_opts(stub))

      assert [{:speech_started, _}, {:audio_delta, "A"}, {:speech_completed, _}] =
               Enum.to_list(stream)
    end

    test "a close frame with no code before isFinal -> :network_error" do
      stub = WebSocketStub.install([{:after_client, :any, [{:close, nil, ""}]}])
      {:ok, stream} = Speech.stream_synthesize_input(input_req(), ["Hi."], ws_opts(stub))

      assert [_, {:error, %SpeechAdapterError{reason: :network_error}}] = Enum.to_list(stream)
    end

    test "audio that is not a string -> :malformed_response" do
      stub = WebSocketStub.install([{:after_client, :any, [{:json, %{"audio" => 1}}]}])
      {:ok, stream} = Speech.stream_synthesize_input(input_req(), ["Hi."], ws_opts(stub))

      assert [_, {:error, %SpeechAdapterError{reason: :malformed_response}}] = Enum.to_list(stream)
    end

    test "stream_timeout: :infinity completes normally and asks for inactivity_timeout=180" do
      stub = WebSocketStub.install([{:after_client, @close_text, [audio("A"), final()]}])

      {:ok, stream} =
        Speech.stream_synthesize_input(
          input_req(),
          ["Hi."],
          ws_opts(stub, stream_timeout: :infinity)
        )

      assert {:speech_completed, _} = stream |> Enum.to_list() |> List.last()
      assert [{url, _}] = WebSocketStub.connects(stub)
      assert url =~ "inactivity_timeout=180"
    end

    test "a base URL that is already ws:// or wss:// is kept" do
      assert "wss://edge.example/v1/" <> _ =
               Speech.ws_url(input_req(), base_url: "wss://edge.example")
    end
  end

  describe "stream_synthesize_input/3 upgrade failures never reduce the input" do
    defp reduced_input(chunks) do
      test_pid = self()
      Stream.map(chunks, fn chunk -> send(test_pid, :reduced) && chunk end)
    end

    test "{:upgrade_status, 401, body} -> :authentication_failed, and the input is never reduced" do
      body = %{"detail" => %{"type" => "authentication_error", "status" => "invalid_api_key"}}
      stub = WebSocketStub.install([], connect: {:error, {:upgrade_status, 401, body}})

      {:ok, stream} =
        Speech.stream_synthesize_input(input_req(), reduced_input(["Hi."]), ws_opts(stub))

      assert [{:error, %SpeechAdapterError{reason: :authentication_failed, status: 401}}] =
               Enum.to_list(stream)

      refute_received :reduced
      assert WebSocketStub.close_count(stub) == 0
    end

    test "recorded ws_v3: eleven_v3 is refused at the upgrade with a 400 -> :invalid_request" do
      env = Fixtures.speech_stream_recorded(:ws_v3)
      assert env["status"] == 400
      body = hd(env["frames"])["upgrade_body"]
      stub = WebSocketStub.install([], connect: {:error, {:upgrade_status, 400, body}})

      {:ok, stream} =
        Speech.stream_synthesize_input(
          input_req(model: "eleven_v3"),
          reduced_input(["Hi."]),
          ws_opts(stub)
        )

      assert [{:error, %SpeechAdapterError{reason: :invalid_request} = err}] = Enum.to_list(stream)
      assert err.metadata.code == "unsupported_model"
      refute_received :reduced
    end

    test "a transport failure at connect -> :network_error" do
      stub = WebSocketStub.install([], connect: {:error, {:transport, :econnrefused}})

      {:ok, stream} =
        Speech.stream_synthesize_input(input_req(), reduced_input(["Hi."]), ws_opts(stub))

      assert [{:error, %SpeechAdapterError{reason: :network_error}}] = Enum.to_list(stream)
      refute_received :reduced
    end
  end

  describe "stream_synthesize_input/3 input failures" do
    test "input [123] -> terminal :invalid_input_chunk" do
      stub = WebSocketStub.install([])
      {:ok, stream} = Speech.stream_synthesize_input(input_req(), [123], ws_opts(stub))

      assert [
               {:speech_started, _},
               {:error,
                %SpeechAdapterError{
                  reason: :invalid_request,
                  metadata: %{cause: :invalid_input_chunk}
                }}
             ] = Enum.to_list(stream)
    end

    test "a chunk that is not UTF-8 -> terminal :invalid_input_chunk" do
      stub = WebSocketStub.install([])
      {:ok, stream} = Speech.stream_synthesize_input(input_req(), [<<0xFF>>], ws_opts(stub))

      assert [_, {:error, %SpeechAdapterError{metadata: %{cause: :invalid_input_chunk}}}] =
               Enum.to_list(stream)
    end

    test "an input that raises -> terminal :input_raised, the consumer alive, err.cause a kind/message map" do
      stub = WebSocketStub.install([])
      input = Stream.map([1], fn _ -> raise "boom" end)
      {:ok, stream} = Speech.stream_synthesize_input(input_req(), input, ws_opts(stub))

      assert [_, {:error, %SpeechAdapterError{metadata: %{cause: :input_raised}} = err}] =
               Enum.to_list(stream)

      assert Process.alive?(self())
      assert %{kind: :error, message: message} = err.cause
      assert message =~ "boom"
      assert {:ok, _} = Jason.encode(err)
    end

    test "input [\"\"] -> terminal :empty_input, and the socket is closed once" do
      stub = WebSocketStub.install([])
      {:ok, stream} = Speech.stream_synthesize_input(input_req(), [""], ws_opts(stub))

      assert [
               {:speech_started, _},
               {:error,
                %SpeechAdapterError{reason: :invalid_request, metadata: %{cause: :empty_input}}}
             ] = Enum.to_list(stream)

      assert WebSocketStub.close_count(stub) == 1
      assert text_frames(stub) == [%{"text" => " "}]
    end
  end

  describe "stream_synthesize_input/3 timers" do
    # The stub stays silent until the end of input, so only pump messages
    # can keep the timer alive. Falsifier: a timer reset only by transport
    # messages ends the stream with :timeout.
    # The design's row is 60 ms gaps under 100 ms; the margins are widened
    # (100 ms gaps under 250 ms) so scheduler jitter under a loaded full
    # suite cannot eat the headroom. The input still takes 500 ms in all,
    # twice the timeout, so a whole-stream deadline fails it.
    test "slow input under a short stream_timeout: five chunks 100 ms apart under 250 ms completes" do
      stub = WebSocketStub.install([{:after_client, @close_text, [audio("A"), final()]}])
      input = Stream.map(1..5, fn i -> Process.sleep(100) && "w#{i} " end)

      {:ok, stream} =
        Speech.stream_synthesize_input(input_req(), input, ws_opts(stub, stream_timeout: 250))

      events = Enum.to_list(stream)
      refute Enum.any?(events, &match?({:error, _}, &1)), inspect(events)
      assert {:speech_completed, _} = List.last(events)
    end

    test ~s(keep-alive: a 700 ms pause under inactivity_timeout=1 sends {"text": " "} between the two chunks) do
      stub = WebSocketStub.install([{:after_client, @close_text, [audio("A"), final()]}])

      input =
        Stream.map(["one ", "two"], fn
          "two" -> Process.sleep(700) && "two"
          chunk -> chunk
        end)

      {:ok, stream} =
        Speech.stream_synthesize_input(input_req(), input, ws_opts(stub, stream_timeout: 1_000))

      events = Enum.to_list(stream)
      refute Enum.any?(events, &match?({:error, _}, &1)), inspect(events)

      texts = stub |> text_frames() |> Enum.map(& &1["text"])
      assert ["one ", " ", "two"] = texts |> Enum.drop(1) |> Enum.take(3)
    end

    test "no keep-alive is sent after the end of input" do
      stub =
        WebSocketStub.install([
          {:after_client, @close_text, []},
          {:after_client, :any, []}
        ])

      {:ok, stream} =
        Speech.stream_synthesize_input(input_req(), ["Hi."], ws_opts(stub, stream_timeout: 1_000))

      assert [_, {:error, %SpeechAdapterError{reason: :timeout}}] = Enum.to_list(stream)
      assert List.last(text_frames(stub)) == %{"text" => ""}
    end
  end

  describe "stream_synthesize_input/3 halt-safety" do
    test "Enum.take/2 closes the socket, and the pump and its input are dead within 500 ms" do
      test_pid = self()

      stub =
        WebSocketStub.install([{:after_client, %{"text" => "Hi "}, [audio("A"), audio("B")]}])

      input =
        Stream.concat(
          Stream.map(["Hi "], fn chunk -> send(test_pid, {:pump, self()}) && chunk end),
          Stream.repeatedly(fn -> Process.sleep(:infinity) end)
        )

      {:ok, stream} = Speech.stream_synthesize_input(input_req(), input, ws_opts(stub))

      assert [{:speech_started, _}, {:audio_delta, "A"}] = Enum.take(stream, 2)
      assert_received {:pump, pump}

      assert WebSocketStub.close_count(stub) == 1
      assert wait_until(fn -> not Process.alive?(pump) end, 500)

      # Stream-owned messages left in the consumer's mailbox: none.
      refute_received {WebSocketStub, _, _}
      refute_received {_ref, {:input, _}}
      refute_received {:DOWN, _, :process, ^pump, _}
    end

    test "composition behaviour 1: every resource function runs in the reducing process" do
      stub = WebSocketStub.install([{:after_client, @close_text, [audio("A"), final()]}])
      {:ok, stream} = Speech.stream_synthesize_input(input_req(), ["Hi."], ws_opts(stub))

      task = Task.async(fn -> {self(), Enum.to_list(stream)} end)
      {reducer, events} = Task.await(task)

      assert {:speech_completed, _} = List.last(events)
      calls = WebSocketStub.calls(stub)

      assert Enum.map(calls, &elem(&1, 0)) |> Enum.uniq() |> Enum.sort() ==
               [:close, :connect, :flush_messages, :handle_message, :send_frame]

      assert Enum.all?(calls, fn {_name, pid} -> pid == reducer end)
      refute reducer == self()
    end
  end

  describe "stream_synthesize_input/3 end to end over WebSocket.Mint and WSTestServer" do
    defp server_audio(bytes),
      do: {:send, {:text, Jason.encode!(%{"audio" => Base.encode64(bytes), "isFinal" => nil})}}

    test "a full session: frames on the wire, then started, deltas and completed" do
      server =
        WSTestServer.start([
          :recv,
          :recv,
          :recv,
          :recv,
          server_audio("pcm-1"),
          server_audio("pcm-2"),
          {:send, {:text, ~s({"audio":null,"isFinal":true})}},
          {:send, {:close, 1000, ""}}
        ])

      {:ok, stream} =
        Speech.stream_synthesize_input(input_req(), ["Hi."],
          api_key: @key,
          base_url: "http://127.0.0.1:#{server.port}"
        )

      assert [
               {:speech_started, _},
               {:audio_delta, "pcm-1"},
               {:audio_delta, "pcm-2"},
               {:speech_completed, _}
             ] = Enum.to_list(stream)

      ref = server.ref
      assert_receive {WSTestServer, ^ref, {:handshake, target, headers}}
      assert {"xi-api-key", @key} in headers
      assert target =~ "/v1/text-to-speech/#{@voice}/stream-input?"
      refute target =~ @key

      assert_receive {WSTestServer, ^ref, {:frame, {:text, ~s({"text":" "})}}}
      assert_receive {WSTestServer, ^ref, {:frame, {:text, ~s({"text":"Hi."})}}}
      refute_received {:tcp, _, _}
      refute_received {:tcp_closed, _}
    end

    # Realistic frame sizes: 6 KB of PCM is an 8 KB base64 JSON frame (a
    # 16-bit extended length) that arrives over several TCP reads.
    test "audio frames of several KB decode intact end to end" do
      big = :binary.copy(<<1, 2, 3, 4, 5, 6>>, 1_024)
      assert byte_size(big) >= 4_096

      server =
        WSTestServer.start([
          :recv,
          :recv,
          :recv,
          :recv,
          server_audio(big),
          server_audio(big),
          {:send, {:text, ~s({"audio":null,"isFinal":true})}},
          {:send, {:close, 1000, ""}}
        ])

      {:ok, stream} =
        Speech.stream_synthesize_input(input_req(), ["Hi."],
          api_key: @key,
          base_url: "http://127.0.0.1:#{server.port}"
        )

      assert [
               {:speech_started, _},
               {:audio_delta, ^big},
               {:audio_delta, ^big},
               {:speech_completed, _}
             ] = Enum.to_list(stream)
    end

    # The live wire (RECORDS §26.7, ws_bad_key): a bad key is upgraded with
    # 101 and rejected by an error frame and a close 1008, so the stream has
    # already emitted :speech_started and started reducing the input. This
    # row pins that behaviour, which the adapter's doc states; the server
    # waits for the first text frame so the reduction is deterministic.
    test "a bad key upgraded with 101, then an error frame and close 1008: started, then :authentication_failed, after the input was reduced" do
      error = ~s({"code":1008,"error":"invalid_api_key","message":"Invalid API key"})

      server =
        WSTestServer.start([
          :recv,
          :recv,
          {:send, {:text, error}},
          {:send, {:close, 1008, "Invalid API key"}}
        ])

      test_pid = self()
      input = Stream.map(["Hi ", "there."], fn w -> send(test_pid, {:reduced, w}) && w end)

      {:ok, stream} =
        Speech.stream_synthesize_input(input_req(), input,
          api_key: @key,
          base_url: "http://127.0.0.1:#{server.port}"
        )

      assert [{:speech_started, _}, {:error, %SpeechAdapterError{} = err}] = Enum.to_list(stream)
      assert err.reason == :authentication_failed
      assert err.metadata.code == "invalid_api_key"
      assert err.metadata.close_code == 1008
      assert_received {:reduced, "Hi "}

      ref = server.ref
      assert_receive {WSTestServer, ^ref, {:frame, {:text, ~s({"text":"Hi "})}}}
      refute_received {:tcp, _, _}
      refute_received {:tcp_closed, _}
    end

    test "a halt closes the socket and leaves no :tcp message in the consumer's mailbox" do
      frames = for i <- 1..5, do: server_audio("chunk-#{i}")
      server = WSTestServer.start([:recv, :recv | frames])

      {:ok, stream} =
        Speech.stream_synthesize_input(
          input_req(),
          Stream.concat(["Hi "], Stream.repeatedly(fn -> Process.sleep(:infinity) end)),
          api_key: @key,
          base_url: "http://127.0.0.1:#{server.port}"
        )

      assert [{:speech_started, _}, {:audio_delta, "chunk-1"}] = Enum.take(stream, 2)

      # The server sees the connection end (a close frame, or a reset when
      # its unread audio frames were discarded).
      ref = server.ref
      assert_receive {WSTestServer, ^ref, :closed}, 2_000
      refute_received {:tcp, _, _}
      refute_received {:tcp_closed, _}
      refute_received {:tcp_error, _, _}
    end
  end

  describe "stream_synthesize_input/3 with an LLM-shaped input" do
    test "an ALLM.stream_generate/3 stream through AudioStream.text_deltas/1 is spoken in order (behaviour 6)" do
      engine = ALLM.Engine.new(adapter: ALLM.Providers.OpenAI, model: "gpt-4o-mini")

      chat_stream = fn ->
        agent =
          FinchStub.install_shared(OpenAITestFixtures.stream_chunks(:happy_text_stream),
            delay_ms: 5
          )

        {:ok, chat} =
          ALLM.stream_generate(engine, ALLM.request([ALLM.user("hi")]),
            api_key: "sk-test",
            finch_module: FinchStub,
            finch_stub_ref: agent
          )

        chat
      end

      # The same chat stream reduced here, for the expected order.
      deltas = chat_stream.() |> ALLM.AudioStream.text_deltas() |> Enum.reject(&(&1 == ""))
      assert length(deltas) >= 2
      chat = chat_stream.()

      stub = WebSocketStub.install([{:after_client, @close_text, [audio("A"), final()]}])

      {:ok, stream} =
        Speech.stream_synthesize_input(
          input_req(),
          ALLM.AudioStream.text_deltas(chat),
          ws_opts(stub)
        )

      assert {:speech_completed, _} = stream |> Enum.to_list() |> List.last()

      # Under the default auto_mode the deltas are regrouped into whole
      # words: the same text, in order, every frame but the last ending at a
      # boundary.
      spoken = stub |> text_frames() |> Enum.map(& &1["text"]) |> Enum.slice(1..-3//1)
      assert Enum.join(spoken) == Enum.join(deltas)
      assert Enum.all?(Enum.drop(spoken, -1), &(Speech.split_at_word_boundary(&1) == {&1, ""}))
      refute_received {_, {:data, _}}
    end
  end

  describe "stream_synthesize_input/3 pre-flight gates (keyless, raising :ws_module)" do
    test "format :bogus -> synchronous :invalid_request before any connect or input reduction" do
      test_pid = self()
      input = Stream.map(["Hi."], fn c -> send(test_pid, :reduced) && c end)

      assert {:error, %SpeechAdapterError{reason: :invalid_request} = err} =
               Speech.stream_synthesize_input(input_req(format: :bogus), input,
                 ws_module: RaisingWebSocket
               )

      assert is_list(err.metadata.errors)
      refute_received :reduced
    end

    test "instructions -> synchronous :unsupported_feature" do
      assert {:error, %SpeechAdapterError{reason: :unsupported_feature}} =
               Speech.stream_synthesize_input(input_req(instructions: "x"), ["Hi."],
                 ws_module: RaisingWebSocket
               )
    end

    test "wav at 44_100 passes the gate; flac is refused" do
      assert {:error, %SpeechAdapterError{reason: :unsupported_feature}} =
               Speech.stream_synthesize_input(input_req(format: :flac), ["Hi."],
                 ws_module: RaisingWebSocket
               )

      assert {:ok, _lazy} =
               Speech.stream_synthesize_input(input_req(format: :wav, sample_rate: 44_100), ["Hi."],
                 api_key: @key,
                 ws_module: RaisingWebSocket
               )
    end

    test "with speech_script set, the Fake runs and no socket is opened" do
      {:ok, stream} =
        Speech.stream_synthesize_input(input_req(), ["a", "b"],
          ws_module: RaisingWebSocket,
          adapter_opts: [speech_script: [{:ok, "FAKE"}]]
        )

      assert "FAKE" == for({:audio_delta, b} <- stream, into: "", do: b)
    end
  end

  describe "recorded WebSocket sessions (replayed through the stub)" do
    for name <- [:ws_tokens, :ws_tokens_auto_mode, :ws_end, :ws_control] do
      test "#{name}: the recorded server frames decode to the recorded audio and one completion" do
        env = Fixtures.speech_stream_recorded(unquote(name))
        assert env["status"] == 101
        assert env["summary"]["audio_frames"] >= 1

        stub = WebSocketStub.install([{:after_client, @close_text, Fixtures.ws_server_frames(env)}])
        {:ok, stream} = Speech.stream_synthesize_input(input_req(), ["Hi."], ws_opts(stub))
        events = Enum.to_list(stream)

        assert {:speech_completed, _} = List.last(events)
        deltas = for {:audio_delta, b} <- events, do: b
        assert length(deltas) == env["summary"]["audio_frames"]
        assert deltas |> IO.iodata_to_binary() |> byte_size() == env["summary"]["audio_bytes"]
      end
    end

    test "the recorded URLs carry no key and the adapter's structural parameters" do
      for name <- [
            :ws_tokens,
            :ws_tokens_auto_mode,
            :ws_end,
            :ws_control,
            :ws_bad_voice,
            :ws_bad_key
          ] do
        url = Fixtures.speech_stream_recorded(name)["url"]
        refute url =~ "sk_", "#{name} URL carries key material"
        assert url =~ "/stream-input?"
        assert url =~ "output_format=pcm_24000"
      end
    end
  end

  describe "recorded fixture provenance (raw bytes)" do
    @recorded ~w(stream_chunked ws_bad_key ws_bad_voice ws_control ws_end ws_tokens ws_tokens_auto_mode ws_v3)

    test "@recorded enumerates every file under speech_stream/recorded/" do
      assert Fixtures.names_on_disk("speech_stream/recorded") == @recorded
    end

    for name <- @recorded do
      test "speech_stream/recorded/#{name}.json carries no _comment marker" do
        raw = Fixtures.raw("speech_stream/recorded", unquote(name))

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
