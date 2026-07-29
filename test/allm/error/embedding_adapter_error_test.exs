defmodule ALLM.Error.EmbeddingAdapterErrorTest do
  use ExUnit.Case, async: true

  alias ALLM.Error.EmbeddingAdapterError

  doctest EmbeddingAdapterError

  @legal_reasons [
    :authentication_failed,
    :rate_limited,
    :invalid_request,
    :context_length_exceeded,
    :provider_unavailable,
    :timeout,
    :network_error,
    :malformed_response,
    :unsupported_feature,
    :batch_too_large,
    :unknown
  ]

  describe "legal_reasons/0" do
    test "returns the 11-atom closed set" do
      reasons = EmbeddingAdapterError.legal_reasons()
      assert length(reasons) == 11
      assert MapSet.new(reasons) == MapSet.new(@legal_reasons)
    end

    test "carries the embeddings-specific :batch_too_large atom" do
      assert :batch_too_large in EmbeddingAdapterError.legal_reasons()
    end

    test "drops the two image-only atoms" do
      reasons = EmbeddingAdapterError.legal_reasons()
      refute :content_filter in reasons
      refute :unsupported_operation in reasons
    end
  end

  describe "new/2" do
    for reason <- @legal_reasons do
      test "#{inspect(reason)} builds the struct with a default message" do
        reason = unquote(reason)
        err = EmbeddingAdapterError.new(reason)

        assert %EmbeddingAdapterError{reason: ^reason} = err
        assert err.message == "embedding adapter error: #{reason}"
      end
    end

    test "sets every documented field from opts" do
      err =
        EmbeddingAdapterError.new(:rate_limited,
          message: "slow down",
          provider: :openai,
          status: 429,
          retry_after_ms: 1_500,
          cause: :http_429,
          metadata: %{route: "/v1/embeddings"}
        )

      assert %EmbeddingAdapterError{
               reason: :rate_limited,
               message: "slow down",
               provider: :openai,
               status: 429,
               retry_after_ms: 1_500,
               cause: :http_429,
               metadata: %{route: "/v1/embeddings"}
             } = err
    end

    test "raises ArgumentError for an unknown reason atom" do
      assert_raise ArgumentError, ~r/unknown reason/, fn ->
        EmbeddingAdapterError.new(:no_such_reason)
      end
    end

    test "raises ArgumentError for an image-only reason atom" do
      assert_raise ArgumentError, ~r/unknown reason/, fn ->
        EmbeddingAdapterError.new(:unsupported_operation)
      end
    end

    test "raises ArgumentError when reason is nil (required positional)" do
      assert_raise ArgumentError, ~r/unknown reason/, fn -> EmbeddingAdapterError.new(nil) end
    end

    test "populates :message with a provider suffix when provider is set" do
      err = EmbeddingAdapterError.new(:rate_limited, provider: :voyage)
      assert err.message == "embedding adapter error (voyage): rate_limited"
      assert Exception.message(err) == "embedding adapter error (voyage): rate_limited"
    end

    test "defaults metadata to an empty map" do
      assert EmbeddingAdapterError.new(:timeout).metadata == %{}
    end

    test ":batch_too_large carries :count and :max in metadata" do
      err = EmbeddingAdapterError.new(:batch_too_large, metadata: %{count: 3_000, max: 2_048})
      assert err.metadata == %{count: 3_000, max: 2_048}
    end
  end

  describe "Exception protocol" do
    test "raise/rescue cycle exposes the stored :message" do
      try do
        raise EmbeddingAdapterError.new(:authentication_failed, message: "bad key")
      rescue
        e in EmbeddingAdapterError ->
          assert Exception.message(e) == "bad key"
      end
    end

    test "hand-built struct with message: nil falls back to the reason-derived default" do
      err = %EmbeddingAdapterError{reason: :rate_limited, message: nil}
      assert Exception.message(err) == "embedding adapter error: rate_limited"
    end

    test "hand-built struct with a :provider set includes the provider in the default" do
      err = %EmbeddingAdapterError{reason: :rate_limited, provider: :gemini}
      assert Exception.message(err) == "embedding adapter error (gemini): rate_limited"
    end

    test "hand-built struct with nil reason falls through to a generic message" do
      assert Exception.message(%EmbeddingAdapterError{reason: nil}) == "embedding adapter error"
    end

    test "every legal reason produces a non-empty message via a raw struct" do
      for r <- @legal_reasons do
        msg = Exception.message(struct!(EmbeddingAdapterError, reason: r))
        assert is_binary(msg)
        assert msg != ""
      end
    end
  end

  describe "term_to_binary round-trip" do
    test "a fully populated EmbeddingAdapterError round-trips to an equal value" do
      err =
        EmbeddingAdapterError.new(:rate_limited,
          message: "slow down",
          provider: :openai,
          status: 429,
          retry_after_ms: 1_500,
          cause: {:http, 429},
          metadata: %{attempt: 2, count: 100}
        )

      assert err == err |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end
  end

  describe "JSON round-trip via ALLM.Serializer" do
    test "fully populated EmbeddingAdapterError round-trips through Serializer" do
      err =
        EmbeddingAdapterError.new(:batch_too_large,
          message: "too many inputs",
          provider: :fake,
          metadata: %{"count" => 3_000, "max" => 2_048}
        )

      json = ALLM.Serializer.to_json!(err)
      assert {:ok, %EmbeddingAdapterError{} = decoded} = ALLM.Serializer.from_json(json)
      assert decoded.reason == :batch_too_large
      assert decoded.message == "too many inputs"
      assert decoded.provider == :fake
      assert decoded.metadata == %{"count" => 3_000, "max" => 2_048}
    end

    test "EmbeddingAdapterError is registered in Serializer.@known_modules" do
      err = %EmbeddingAdapterError{reason: :timeout, message: "x"}
      decoded = err |> ALLM.Serializer.to_json!() |> Jason.decode!()
      assert decoded["__type__"] == "ALLM.Error.EmbeddingAdapterError"
    end
  end
end
