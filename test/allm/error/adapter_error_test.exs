defmodule ALLM.Error.AdapterErrorTest do
  use ExUnit.Case, async: true

  alias ALLM.Error.AdapterError

  doctest AdapterError

  @legal_reasons [
    :rate_limited,
    :authentication_failed,
    :invalid_request,
    :provider_unavailable,
    :context_length_exceeded,
    :content_filter,
    :timeout,
    :network_error,
    :malformed_response,
    :unsupported_feature,
    :unknown
  ]

  describe "new/2" do
    test "sets every documented field from opts" do
      err =
        AdapterError.new(:rate_limited,
          message: "slow down",
          provider: :openai,
          status: 429,
          retry_after_ms: 1_500,
          request_id: "req_abc",
          cause: :http_429,
          metadata: %{route: "/v1/chat"}
        )

      assert %AdapterError{
               reason: :rate_limited,
               message: "slow down",
               provider: :openai,
               status: 429,
               retry_after_ms: 1_500,
               request_id: "req_abc",
               cause: :http_429,
               metadata: %{route: "/v1/chat"}
             } = err
    end

    test "raises ArgumentError when reason is nil (required positional)" do
      assert_raise ArgumentError, ~r/unknown reason/, fn -> AdapterError.new(nil) end
    end

    test "raises ArgumentError for unknown reason atom" do
      assert_raise ArgumentError, ~r/unknown reason/, fn ->
        AdapterError.new(:no_such_reason)
      end
    end

    test "populates :message with the documented default (no provider)" do
      err = AdapterError.new(:timeout)
      assert err.message == "adapter error: timeout"
      assert Exception.message(err) == "adapter error: timeout"
    end

    test "populates :message with provider suffix when provider is set" do
      err = AdapterError.new(:rate_limited, provider: :openai)
      assert err.message == "adapter error (openai): rate_limited"
      assert Exception.message(err) == "adapter error (openai): rate_limited"
    end

    test "defaults metadata to an empty map" do
      err = AdapterError.new(:timeout)
      assert err.metadata == %{}
    end
  end

  describe "Exception protocol" do
    test "raise/rescue cycle exposes the stored :message" do
      try do
        raise AdapterError.new(:authentication_failed, message: "bad key")
      rescue
        e in AdapterError ->
          assert Exception.message(e) == "bad key"
      end
    end

    test "raw struct (:reason only) yields a non-empty message via fallback" do
      err = %AdapterError{reason: :rate_limited}
      assert Exception.message(err) == "adapter error: rate_limited"
    end

    test "raw struct with :provider but no :message uses provider fallback" do
      err = %AdapterError{reason: :rate_limited, provider: :openai}
      assert Exception.message(err) == "adapter error (openai): rate_limited"
    end

    test "raw struct with nil reason falls through to a generic message" do
      err = %AdapterError{reason: nil}
      assert Exception.message(err) == "adapter error"
    end

    test "every legal reason produces a non-empty message via raw struct" do
      for r <- @legal_reasons do
        err = struct!(AdapterError, reason: r)
        msg = Exception.message(err)
        assert is_binary(msg)
        assert msg != ""
      end
    end
  end

  describe "term_to_binary round-trip" do
    test "a fully populated AdapterError round-trips to equal value" do
      err =
        AdapterError.new(:rate_limited,
          message: "slow down",
          provider: :anthropic,
          status: 429,
          retry_after_ms: 1_500,
          request_id: "req_1",
          cause: {:http, 429},
          metadata: %{attempt: 2}
        )

      assert err == err |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end
  end

  # NOTE: ALLM.Serializer JSON round-trip is deferred to sub-phase 1.5.
end
