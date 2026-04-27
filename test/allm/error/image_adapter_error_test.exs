defmodule ALLM.Error.ImageAdapterErrorTest do
  use ExUnit.Case, async: true

  alias ALLM.Error.ImageAdapterError

  doctest ImageAdapterError

  @legal_reasons [
    :authentication_failed,
    :rate_limited,
    :invalid_request,
    :content_filter,
    :context_length_exceeded,
    :provider_unavailable,
    :timeout,
    :network_error,
    :malformed_response,
    :unsupported_feature,
    :unsupported_operation,
    :unknown
  ]

  describe "legal_reasons/0" do
    test "returns the 12-atom closed set including image-specific reasons" do
      reasons = ImageAdapterError.legal_reasons()
      assert length(reasons) == 12
      assert :unsupported_operation in reasons
      assert MapSet.new(reasons) == MapSet.new(@legal_reasons)
    end
  end

  describe "new/2" do
    test ":unsupported_operation succeeds with default message" do
      err = ImageAdapterError.new(:unsupported_operation)

      assert %ImageAdapterError{
               reason: :unsupported_operation,
               message: "image adapter error: unsupported_operation"
             } = err
    end

    test "sets every documented field from opts" do
      err =
        ImageAdapterError.new(:rate_limited,
          message: "slow down",
          provider: :openai,
          status: 429,
          retry_after_ms: 1_500,
          cause: :http_429,
          metadata: %{route: "/v1/images/generations"}
        )

      assert %ImageAdapterError{
               reason: :rate_limited,
               message: "slow down",
               provider: :openai,
               status: 429,
               retry_after_ms: 1_500,
               cause: :http_429,
               metadata: %{route: "/v1/images/generations"}
             } = err
    end

    test "raises ArgumentError when reason is nil (required positional)" do
      assert_raise ArgumentError, ~r/unknown reason/, fn -> ImageAdapterError.new(nil) end
    end

    test "raises ArgumentError for unknown reason atom" do
      assert_raise ArgumentError, ~r/unknown reason/, fn ->
        ImageAdapterError.new(:no_such_reason)
      end
    end

    test "populates :message with provider suffix when provider is set" do
      err = ImageAdapterError.new(:rate_limited, provider: :openai)
      assert err.message == "image adapter error (openai): rate_limited"
      assert Exception.message(err) == "image adapter error (openai): rate_limited"
    end

    test "defaults metadata to an empty map" do
      err = ImageAdapterError.new(:timeout)
      assert err.metadata == %{}
    end

    test ":unsupported_operation carries the rejected operation in metadata" do
      err =
        ImageAdapterError.new(:unsupported_operation,
          metadata: %{operation: :edit},
          message: "operation :edit not supported"
        )

      assert err.metadata.operation == :edit
    end
  end

  describe "Exception protocol" do
    test "raise/rescue cycle exposes the stored :message" do
      try do
        raise ImageAdapterError.new(:authentication_failed, message: "bad key")
      rescue
        e in ImageAdapterError ->
          assert Exception.message(e) == "bad key"
      end
    end

    test "raw struct (:reason only) yields a non-empty message via fallback" do
      err = %ImageAdapterError{reason: :rate_limited}
      assert Exception.message(err) == "image adapter error: rate_limited"
    end

    test "raw struct with :provider but no :message uses provider fallback" do
      err = %ImageAdapterError{reason: :rate_limited, provider: :openai}
      assert Exception.message(err) == "image adapter error (openai): rate_limited"
    end

    test "raw struct with nil reason falls through to a generic message" do
      err = %ImageAdapterError{reason: nil}
      assert Exception.message(err) == "image adapter error"
    end

    test "every legal reason produces a non-empty message via raw struct" do
      for r <- @legal_reasons do
        err = struct!(ImageAdapterError, reason: r)
        msg = Exception.message(err)
        assert is_binary(msg)
        assert msg != ""
      end
    end
  end

  describe "term_to_binary round-trip" do
    test "a fully populated ImageAdapterError round-trips to equal value" do
      err =
        ImageAdapterError.new(:rate_limited,
          message: "slow down",
          provider: :openai,
          status: 429,
          retry_after_ms: 1_500,
          cause: {:http, 429},
          metadata: %{attempt: 2, operation: :generate}
        )

      assert err == err |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end
  end

  describe "JSON round-trip via ALLM.Serializer" do
    test "fully populated ImageAdapterError round-trips through Serializer" do
      err =
        ImageAdapterError.new(:unsupported_operation,
          message: "op :edit not supported",
          provider: :fake,
          metadata: %{operation: "edit"}
        )

      json = ALLM.Serializer.to_json!(err)
      assert {:ok, %ImageAdapterError{} = decoded} = ALLM.Serializer.from_json(json)
      assert decoded.reason == :unsupported_operation
      assert decoded.message == "op :edit not supported"
      assert decoded.provider == :fake
      assert decoded.metadata == %{"operation" => "edit"}
    end

    test "ImageAdapterError is registered in Serializer.@known_modules" do
      err = %ImageAdapterError{reason: :timeout, message: "x"}
      json = ALLM.Serializer.to_json!(err)
      decoded = Jason.decode!(json)
      assert decoded["__type__"] == "ALLM.Error.ImageAdapterError"
    end
  end
end
