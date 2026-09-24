defmodule ALLM.Error.TranscriptionAdapterErrorTest do
  use ExUnit.Case, async: true

  alias ALLM.Error.{EngineError, SpeechAdapterError, TranscriptionAdapterError}

  doctest TranscriptionAdapterError

  @legal_reasons [
    :authentication_failed,
    :rate_limited,
    :invalid_request,
    :context_length_exceeded,
    :provider_unavailable,
    :timeout,
    :network_error,
    :malformed_response,
    :content_filter,
    :unknown
  ]

  describe "legal_reasons/0" do
    test "returns the 10-atom closed set" do
      reasons = TranscriptionAdapterError.legal_reasons()
      assert length(reasons) == 10
      assert MapSet.new(reasons) == MapSet.new(@legal_reasons)
    end

    test "drops :batch_too_large and :unsupported_feature" do
      reasons = TranscriptionAdapterError.legal_reasons()
      refute :batch_too_large in reasons
      refute :unsupported_feature in reasons
    end

    test "carries :content_filter, which the speech sibling does not" do
      assert :content_filter in TranscriptionAdapterError.legal_reasons()
      refute :content_filter in SpeechAdapterError.legal_reasons()
    end
  end

  describe "new/2" do
    for reason <- @legal_reasons do
      test "#{inspect(reason)} builds the struct with a default message" do
        reason = unquote(reason)
        err = TranscriptionAdapterError.new(reason)

        assert %TranscriptionAdapterError{reason: ^reason} = err
        assert err.message == "transcription adapter error: #{reason}"
      end
    end

    test "sets every documented field from opts" do
      err =
        TranscriptionAdapterError.new(:rate_limited,
          message: "slow down",
          provider: :openai,
          status: 429,
          retry_after_ms: 1_500,
          cause: :http_429,
          metadata: %{route: "/v1/audio/transcriptions"}
        )

      assert %TranscriptionAdapterError{
               reason: :rate_limited,
               message: "slow down",
               provider: :openai,
               status: 429,
               retry_after_ms: 1_500,
               cause: :http_429,
               metadata: %{route: "/v1/audio/transcriptions"}
             } = err
    end

    test "with an off-enum reason raises ArgumentError naming the legal set" do
      assert_raise ArgumentError, ~r/unknown reason .*legal:/s, fn ->
        TranscriptionAdapterError.new(:no_such_reason)
      end
    end

    test "with :batch_too_large raises ArgumentError" do
      assert_raise ArgumentError, ~r/unknown reason/, fn ->
        TranscriptionAdapterError.new(:batch_too_large)
      end
    end

    test "raises ArgumentError when reason is nil" do
      assert_raise ArgumentError, ~r/unknown reason/, fn -> TranscriptionAdapterError.new(nil) end
    end

    test "with :provider set produces the provider-suffixed default message" do
      err = TranscriptionAdapterError.new(:rate_limited, provider: :openai)
      assert err.message == "transcription adapter error (openai): rate_limited"
    end

    test "defaults metadata to an empty map" do
      assert TranscriptionAdapterError.new(:timeout).metadata == %{}
    end
  end

  describe "Exception protocol" do
    test "raise/rescue cycle exposes the stored :message" do
      try do
        raise TranscriptionAdapterError.new(:authentication_failed, message: "bad key")
      rescue
        e in TranscriptionAdapterError -> assert Exception.message(e) == "bad key"
      end
    end

    test "a struct built without :message returns the reason-derived default" do
      err = %TranscriptionAdapterError{reason: :rate_limited, message: nil}
      assert Exception.message(err) == "transcription adapter error: rate_limited"
    end

    test "a raw struct with a :provider set includes the provider in the default" do
      err = %TranscriptionAdapterError{reason: :rate_limited, provider: :openai}
      assert Exception.message(err) == "transcription adapter error (openai): rate_limited"
    end

    test "a raw struct with a nil reason returns the catch-all fallback" do
      assert Exception.message(%TranscriptionAdapterError{reason: nil}) ==
               "transcription adapter error"
    end

    test "every legal reason produces a non-empty message via a raw struct" do
      for r <- @legal_reasons do
        msg = Exception.message(struct!(TranscriptionAdapterError, reason: r))
        assert is_binary(msg) and msg != ""
      end
    end
  end

  describe "serializability" do
    test "a fully populated error round-trips through :erlang.term_to_binary/1" do
      err =
        TranscriptionAdapterError.new(:rate_limited,
          message: "slow down",
          provider: :openai,
          status: 429,
          retry_after_ms: 1_500,
          cause: {:http, 429},
          metadata: %{attempt: 2}
        )

      assert err == err |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end

    test "a fully populated error round-trips through Serializer" do
      err =
        TranscriptionAdapterError.new(:context_length_exceeded,
          message: "too long",
          provider: :openai,
          status: 400,
          metadata: %{"count" => 4097, "max" => 4096}
        )

      assert {:ok, ^err} = err |> ALLM.Serializer.to_json!() |> ALLM.Serializer.from_json()
    end
  end

  describe "EngineError enum extension" do
    test ":no_transcription_adapter is a legal EngineError reason" do
      assert %EngineError{reason: :no_transcription_adapter} =
               EngineError.new(:no_transcription_adapter)
    end
  end
end
