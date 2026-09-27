defmodule ALLM.Error.ClassificationAdapterErrorTest do
  use ExUnit.Case, async: true

  alias ALLM.Error.ClassificationAdapterError

  doctest ClassificationAdapterError

  @legal_reasons [
    :authentication_failed,
    :rate_limited,
    :invalid_request,
    :context_length_exceeded,
    :provider_unavailable,
    :timeout,
    :network_error,
    :malformed_response,
    :unknown
  ]

  describe "legal_reasons/0" do
    test "returns the 9-atom closed set" do
      reasons = ClassificationAdapterError.legal_reasons()
      assert length(reasons) == 9
      assert MapSet.new(reasons) == MapSet.new(@legal_reasons)
    end

    test "drops :unsupported_feature and :batch_too_large" do
      reasons = ClassificationAdapterError.legal_reasons()
      refute :unsupported_feature in reasons
      refute :batch_too_large in reasons
    end
  end

  describe "new/2" do
    for reason <- @legal_reasons do
      test "#{inspect(reason)} builds the struct with a default message" do
        reason = unquote(reason)
        err = ClassificationAdapterError.new(reason)

        assert %ClassificationAdapterError{reason: ^reason} = err
        assert err.message == "classification adapter error: #{reason}"
      end
    end

    test "sets every documented field from opts" do
      err =
        ClassificationAdapterError.new(:rate_limited,
          message: "slow down",
          provider: :typesafe,
          status: 429,
          retry_after_ms: 1_500,
          cause: :http_429,
          metadata: %{route: "/v1/systemone"}
        )

      assert %ClassificationAdapterError{
               reason: :rate_limited,
               message: "slow down",
               provider: :typesafe,
               status: 429,
               retry_after_ms: 1_500,
               cause: :http_429,
               metadata: %{route: "/v1/systemone"}
             } = err
    end

    test "with an off-enum reason raises ArgumentError naming the legal set" do
      assert_raise ArgumentError, ~r/unknown reason .*legal:/s, fn ->
        ClassificationAdapterError.new(:no_such_reason)
      end
    end

    test "with :batch_too_large raises ArgumentError" do
      assert_raise ArgumentError, ~r/unknown reason/, fn ->
        ClassificationAdapterError.new(:batch_too_large)
      end
    end

    test "raises ArgumentError when reason is nil (required positional)" do
      assert_raise ArgumentError, ~r/unknown reason/, fn ->
        ClassificationAdapterError.new(nil)
      end
    end

    test "with :provider set produces the provider-suffixed default message" do
      err = ClassificationAdapterError.new(:rate_limited, provider: :typesafe)
      assert err.message == "classification adapter error (typesafe): rate_limited"
    end

    test "defaults metadata to an empty map" do
      assert ClassificationAdapterError.new(:timeout).metadata == %{}
    end
  end

  describe "Exception protocol" do
    test "raise/rescue cycle exposes the stored :message" do
      try do
        raise ClassificationAdapterError.new(:authentication_failed, message: "bad key")
      rescue
        e in ClassificationAdapterError ->
          assert Exception.message(e) == "bad key"
      end
    end

    test "a raw struct built without :message returns the reason-derived default" do
      err = %ClassificationAdapterError{reason: :rate_limited, message: nil}
      assert Exception.message(err) == "classification adapter error: rate_limited"
    end

    test "a raw struct with a :provider set includes the provider in the default" do
      err = %ClassificationAdapterError{reason: :rate_limited, provider: :typesafe}
      assert Exception.message(err) == "classification adapter error (typesafe): rate_limited"
    end

    test "a raw struct with a nil reason returns the catch-all fallback" do
      assert Exception.message(%ClassificationAdapterError{reason: nil}) ==
               "classification adapter error"
    end
  end

  describe "serializability" do
    test "a fully populated error round-trips through :erlang.term_to_binary/1" do
      err =
        ClassificationAdapterError.new(:rate_limited,
          provider: :typesafe,
          status: 429,
          retry_after_ms: 1_500,
          cause: {:http, 429},
          metadata: %{attempt: 2}
        )

      assert err == err |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end

    test "a fully populated error round-trips through Serializer" do
      err =
        ClassificationAdapterError.new(:invalid_request,
          message: "too many options",
          provider: :typesafe,
          status: 422,
          cause: "unencodable_body",
          metadata: %{"question" => "department", "limit" => 255}
        )

      assert {:ok, ^err} = err |> ALLM.Serializer.to_json!() |> ALLM.Serializer.from_json()
    end

    test "is registered in Serializer.@known_modules" do
      err = %ClassificationAdapterError{reason: :timeout, message: "x"}
      decoded = err |> ALLM.Serializer.to_json!() |> Jason.decode!()
      assert decoded["__type__"] == "ALLM.Error.ClassificationAdapterError"
    end
  end
end
