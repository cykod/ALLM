defmodule ALLM.Providers.Support.TranscriptionAdapterTest do
  @moduledoc """
  Unit tests for `ALLM.Providers.Support.TranscriptionAdapter`. Every helper
  is exercised once per bundled transcription adapter, so a helper that
  hard-codes one provider atom into `:provider` or a message fails for the
  other.
  """

  use ExUnit.Case, async: true

  alias ALLM.{Audio, TranscriptionRequest, TranscriptionResponse}
  alias ALLM.Error.TranscriptionAdapterError
  alias ALLM.Providers.Gemini
  alias ALLM.Providers.OpenAI
  alias ALLM.Providers.Support.TranscriptionAdapter, as: Support

  @providers [
    {:openai, OpenAI.Transcription, "sk-support-test", %{"text" => "hello"}},
    {:gemini, Gemini.Transcription, "AIza-support-test",
     %{
       "candidates" => [
         %{"content" => %{"parts" => [%{"text" => "hello"}]}, "finishReason" => "STOP"}
       ]
     }}
  ]

  defp mp3, do: Audio.from_binary("ID3", "audio/mpeg")

  for {provider, adapter, key, ok_body} <- @providers do
    describe "#{provider}" do
      @provider provider
      @adapter adapter
      @key key
      @ok_body ok_body

      setup do
        {:ok,
         stub: String.to_atom("stt_support_#{@provider}_#{System.unique_integer([:positive])}")}
      end

      test "fetch_transcription_script/1 reads adapter_opts[:transcription_script]" do
        assert Support.fetch_transcription_script(adapter_opts: [transcription_script: [:x]]) ==
                 [:x]

        assert Support.fetch_transcription_script([]) == nil
      end

      test "with_own_cap/2 sets the adapter's cap and keeps the other adapter_opts" do
        opts =
          Support.with_own_cap(
            [api_key: @key, adapter_opts: [transcription_script: [:x]]],
            @adapter.max_audio_bytes()
          )

        assert opts[:api_key] == @key
        assert opts[:adapter_opts][:transcription_script] == [:x]
        assert opts[:adapter_opts][:max_audio_bytes] == @adapter.max_audio_bytes()
      end

      test "measure/3 counts resolvable audio and reports unresolvable audio" do
        assert Support.measure(mp3(), @provider, []) == {:ok, 3}

        assert {:error, %TranscriptionAdapterError{provider: @provider} = err} =
                 Support.measure(Audio.from_file("/nonexistent.mp3"), @provider, request_id: "r1")

        assert err.metadata == %{field: :audio, cause: :enoent, request_id: "r1"}

        assert {:error,
                %TranscriptionAdapterError{provider: @provider, metadata: %{cause: :invalid_source}}} =
                 Support.measure(:not_audio, @provider, [])
      end

      test "gate_size/4 passes at the cap and refuses one byte over it" do
        assert Support.gate_size(10, 10, @provider, []) == :ok

        assert {:error, %TranscriptionAdapterError{reason: :invalid_request} = err} =
                 Support.gate_size(11, 10, @provider, request_id: "r1")

        assert err.provider == @provider
        assert err.message == "audio is 11 bytes, over max_audio_bytes 10"
        assert err.metadata == %{field: :audio, count: 11, max: 10, request_id: "r1"}
      end

      test "unresolvable_error/3 names the cause and the provider" do
        err = Support.unresolvable_error(:eisdir, @provider, [])
        assert %TranscriptionAdapterError{reason: :invalid_request, provider: @provider} = err
        assert err.message == "audio bytes could not be resolved (:eisdir)"
        assert err.metadata == %{field: :audio, cause: :eisdir}
      end

      test "stub_error/2 is an :unknown error for the provider" do
        assert %TranscriptionAdapterError{reason: :unknown, provider: @provider} =
                 err = Support.stub_error(@provider, request_id: "r1")

        assert err.metadata == %{request_id: "r1"}
      end

      test "transport_error/5 builds the provider's error and sanitises a decode cause" do
        {:error, cause} = Jason.decode("{secret")
        err = Support.transport_error(:network_error, "boom", cause, @provider, [])

        assert %TranscriptionAdapterError{reason: :network_error, provider: @provider} = err
        assert %Jason.DecodeError{data: "", position: 0} = err.cause
      end

      test "resolve_bytes/3 returns the bytes or the provider's unresolvable error" do
        assert Support.resolve_bytes(mp3(), @provider, []) == {:ok, "ID3"}

        assert {:error,
                %TranscriptionAdapterError{provider: @provider, metadata: %{cause: :enoent}}} =
                 Support.resolve_bytes(Audio.from_file("/nonexistent.mp3"), @provider, [])
      end

      test "do_transcribe/4 runs the adapter's gates before key resolution" do
        request = TranscriptionRequest.new(audio: Audio.from_file("/nonexistent.mp3"))

        assert {:error,
                %TranscriptionAdapterError{provider: @provider, metadata: %{cause: :enoent}}} =
                 Support.do_transcribe(@adapter, @provider, request, [])
      end

      test "do_transcribe/4 makes exactly one attempt and decodes through the adapter", %{
        stub: stub
      } do
        parent = self()

        Req.Test.stub(stub, fn conn ->
          send(parent, :attempt)
          Req.Test.json(conn, @ok_body)
        end)

        opts = [api_key: @key, adapter_opts: [plug: {Req.Test, stub}]]

        assert {:ok, %TranscriptionResponse{text: "hello", provider: @provider}} =
                 Support.do_transcribe(
                   @adapter,
                   @provider,
                   TranscriptionRequest.new(audio: mp3()),
                   opts
                 )

        assert_received :attempt
        refute_received :attempt
      end

      test "run_one_attempt/5 classifies non-2xx, transport and undecodable responses", %{
        stub: stub
      } do
        request = TranscriptionRequest.new(audio: mp3())
        http = Req.new(url: "https://example.invalid", retry: false, plug: {Req.Test, stub})

        Req.Test.stub(stub, &Plug.Conn.send_resp(&1, 503, ""))

        assert {:error,
                %TranscriptionAdapterError{reason: :provider_unavailable, provider: @provider}} =
                 Support.run_one_attempt(@adapter, @provider, http, request, [])

        Req.Test.stub(stub, &Req.Test.transport_error(&1, :timeout))

        assert {:error, %TranscriptionAdapterError{reason: :timeout, provider: @provider}} =
                 Support.run_one_attempt(@adapter, @provider, http, request, [])

        Req.Test.stub(stub, &Req.Test.transport_error(&1, :econnrefused))

        assert {:error, %TranscriptionAdapterError{reason: :network_error, provider: @provider}} =
                 Support.run_one_attempt(@adapter, @provider, http, request, [])

        Req.Test.stub(stub, fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, "{not json")
        end)

        assert {:error, %TranscriptionAdapterError{reason: :malformed_response} = err} =
                 Support.run_one_attempt(@adapter, @provider, http, request, [])

        assert err.provider == @provider
        assert %Jason.DecodeError{data: "", position: 0} = err.cause
      end
    end
  end
end
