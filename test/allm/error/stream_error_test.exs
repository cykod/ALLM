defmodule ALLM.Error.StreamErrorTest do
  use ExUnit.Case, async: true

  alias ALLM.Error.StreamError

  doctest StreamError

  @legal_reasons [
    :adapter_error,
    :cancelled,
    :timeout,
    :malformed_event,
    :unknown
  ]

  describe "new/2" do
    test "sets every documented field from opts" do
      err =
        StreamError.new(:adapter_error,
          message: "wrapped adapter failure",
          provider: :anthropic,
          event_index: 7,
          cause: :underlying_term,
          metadata: %{chunks: 3}
        )

      assert %StreamError{
               reason: :adapter_error,
               message: "wrapped adapter failure",
               provider: :anthropic,
               event_index: 7,
               cause: :underlying_term,
               metadata: %{chunks: 3}
             } = err
    end

    test "raises ArgumentError when reason is nil (required positional)" do
      assert_raise ArgumentError, ~r/unknown reason/, fn -> StreamError.new(nil) end
    end

    test "raises ArgumentError for unknown reason atom" do
      assert_raise ArgumentError, ~r/unknown reason/, fn ->
        StreamError.new(:not_a_real_stream_reason)
      end
    end

    test "populates :message with the documented default when omitted" do
      err = StreamError.new(:cancelled)
      assert err.message == "stream error: cancelled"
      assert Exception.message(err) == "stream error: cancelled"
    end

    test "defaults metadata to an empty map" do
      err = StreamError.new(:cancelled)
      assert err.metadata == %{}
    end
  end

  describe "Exception protocol" do
    test "raise/rescue cycle exposes the stored :message" do
      try do
        raise StreamError.new(:timeout, message: "stream timed out")
      rescue
        e in StreamError ->
          assert Exception.message(e) == "stream timed out"
      end
    end

    test "raw struct with only :reason still yields a non-empty message" do
      err = %StreamError{reason: :malformed_event}
      assert Exception.message(err) == "stream error: malformed_event"
    end

    test "raw struct with nil reason falls through to a generic message" do
      err = %StreamError{reason: nil}
      assert Exception.message(err) == "stream error"
    end

    test "every legal reason produces a non-empty message via raw struct" do
      for r <- @legal_reasons do
        err = struct!(StreamError, reason: r)
        msg = Exception.message(err)
        assert is_binary(msg)
        assert msg != ""
      end
    end
  end

  describe "term_to_binary round-trip" do
    test "a fully populated StreamError round-trips to equal value" do
      err =
        StreamError.new(:adapter_error,
          message: "boom",
          provider: :openai,
          event_index: 12,
          cause: %{stage: :sse},
          metadata: %{ms: 450}
        )

      assert err == err |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end
  end

  # NOTE: ALLM.Serializer JSON round-trip is deferred to sub-phase 1.5.
end
