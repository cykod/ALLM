defmodule ALLM.Error.ModerationAdapterErrorTest do
  use ExUnit.Case, async: true

  alias ALLM.Error.ModerationAdapterError

  doctest ModerationAdapterError

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
      reasons = ModerationAdapterError.legal_reasons()
      assert length(reasons) == 11
      assert MapSet.new(reasons) == MapSet.new(@legal_reasons)
    end

    test "carries :batch_too_large — max_batch_size() is enforced by adapters" do
      assert :batch_too_large in ModerationAdapterError.legal_reasons()
    end

    test "drops :content_filter and :unsupported_operation" do
      reasons = ModerationAdapterError.legal_reasons()
      # A moderation call is never itself content-filtered — classifying
      # harmful text is the endpoint's purpose — and there is no operations
      # enum to be unsupported.
      refute :content_filter in reasons
      refute :unsupported_operation in reasons
    end
  end

  describe "new/2" do
    for reason <- @legal_reasons do
      test "#{inspect(reason)} builds the struct with a default message" do
        reason = unquote(reason)
        err = ModerationAdapterError.new(reason)

        assert %ModerationAdapterError{reason: ^reason} = err
        assert err.message == "moderation adapter error: #{reason}"
      end
    end

    test "sets every documented field from opts" do
      err =
        ModerationAdapterError.new(:rate_limited,
          message: "slow down",
          provider: :openai,
          status: 429,
          retry_after_ms: 1_500,
          cause: :http_429,
          metadata: %{route: "/v1/moderations"}
        )

      assert %ModerationAdapterError{
               reason: :rate_limited,
               message: "slow down",
               provider: :openai,
               status: 429,
               retry_after_ms: 1_500,
               cause: :http_429,
               metadata: %{route: "/v1/moderations"}
             } = err
    end

    test "with an off-enum reason raises ArgumentError naming the legal set" do
      assert_raise ArgumentError, ~r/unknown reason .*legal:/s, fn ->
        ModerationAdapterError.new(:no_such_reason)
      end
    end

    test "with :content_filter raises ArgumentError" do
      assert_raise ArgumentError, ~r/unknown reason/, fn ->
        ModerationAdapterError.new(:content_filter)
      end
    end

    test "raises ArgumentError when reason is nil (required positional)" do
      assert_raise ArgumentError, ~r/unknown reason/, fn -> ModerationAdapterError.new(nil) end
    end

    test "with :provider set produces the provider-suffixed default message" do
      err = ModerationAdapterError.new(:rate_limited, provider: :openai)
      assert err.message == "moderation adapter error (openai): rate_limited"
      assert Exception.message(err) == "moderation adapter error (openai): rate_limited"
    end

    test "defaults metadata to an empty map" do
      assert ModerationAdapterError.new(:timeout).metadata == %{}
    end

    test ":batch_too_large carries :count and :max in metadata" do
      err = ModerationAdapterError.new(:batch_too_large, metadata: %{count: 500, max: 32})
      assert err.metadata == %{count: 500, max: 32}
    end
  end

  describe "Exception protocol" do
    test "raise/rescue cycle exposes the stored :message" do
      try do
        raise ModerationAdapterError.new(:authentication_failed, message: "bad key")
      rescue
        e in ModerationAdapterError ->
          assert Exception.message(e) == "bad key"
      end
    end

    test "a struct built without :message returns the reason-derived default" do
      err = %ModerationAdapterError{reason: :rate_limited, message: nil}
      assert Exception.message(err) == "moderation adapter error: rate_limited"
    end

    test "a raw struct with a :provider set includes the provider in the default" do
      err = %ModerationAdapterError{reason: :rate_limited, provider: :openai}
      assert Exception.message(err) == "moderation adapter error (openai): rate_limited"
    end

    test "a raw struct with a nil reason returns the catch-all fallback" do
      assert Exception.message(%ModerationAdapterError{reason: nil}) == "moderation adapter error"
    end

    test "every legal reason produces a non-empty message via a raw struct" do
      for r <- @legal_reasons do
        msg = Exception.message(struct!(ModerationAdapterError, reason: r))
        assert is_binary(msg)
        assert msg != ""
      end
    end
  end

  describe "serializability" do
    test "a fully populated error round-trips through :erlang.term_to_binary/1" do
      err =
        ModerationAdapterError.new(:rate_limited,
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
        ModerationAdapterError.new(:batch_too_large,
          message: "too many inputs",
          provider: :openai,
          metadata: %{"count" => 500, "max" => 32}
        )

      json = ALLM.Serializer.to_json!(err)
      assert {:ok, %ModerationAdapterError{} = decoded} = ALLM.Serializer.from_json(json)
      assert decoded.reason == :batch_too_large
      assert decoded.message == "too many inputs"
      assert decoded.provider == :openai
      assert decoded.metadata == %{"count" => 500, "max" => 32}
    end

    test "is registered in Serializer.@known_modules" do
      err = %ModerationAdapterError{reason: :timeout, message: "x"}
      decoded = err |> ALLM.Serializer.to_json!() |> Jason.decode!()
      assert decoded["__type__"] == "ALLM.Error.ModerationAdapterError"
    end
  end
end
