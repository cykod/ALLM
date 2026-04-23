defmodule ALLM.Error.EngineErrorTest do
  use ExUnit.Case, async: true

  alias ALLM.Error.EngineError

  doctest EngineError

  @legal_reasons [
    :missing_adapter,
    :missing_stream_adapter,
    :missing_model,
    :missing_key,
    :unknown_tool,
    :invalid_engine,
    :unsupported_response_format
  ]

  describe "new/2" do
    test "sets every documented field from opts" do
      err =
        EngineError.new(:missing_adapter,
          message: "no adapter configured",
          provider: :openai,
          cause: :enoent,
          metadata: %{engine_id: "abc"}
        )

      assert %EngineError{
               reason: :missing_adapter,
               message: "no adapter configured",
               provider: :openai,
               cause: :enoent,
               metadata: %{engine_id: "abc"}
             } = err
    end

    test "raises ArgumentError when reason is nil (required positional)" do
      assert_raise ArgumentError, ~r/unknown reason/, fn -> EngineError.new(nil) end
    end

    test "raises ArgumentError for unknown reason atom" do
      assert_raise ArgumentError, ~r/unknown reason/, fn ->
        EngineError.new(:not_a_real_reason)
      end
    end

    test "populates :message with the documented default when omitted" do
      err = EngineError.new(:missing_adapter)
      assert err.message == "engine error: missing_adapter"
      assert Exception.message(err) == "engine error: missing_adapter"
    end

    test "defaults metadata to an empty map" do
      err = EngineError.new(:missing_adapter)
      assert err.metadata == %{}
    end
  end

  describe "Exception protocol" do
    test "raise/rescue cycle exposes the stored :message" do
      try do
        raise EngineError.new(:missing_key, message: "key not set")
      rescue
        e in EngineError ->
          assert Exception.message(e) == "key not set"
      end
    end

    test "raw struct construction with only :reason still yields a non-empty message" do
      err = %EngineError{reason: :missing_adapter}
      assert Exception.message(err) |> is_binary()
      assert Exception.message(err) != ""
    end

    test "raw struct with nil reason falls through to a generic message" do
      err = %EngineError{reason: nil}
      assert Exception.message(err) == "engine error"
    end

    test "every legal reason produces a non-empty message via raw struct" do
      for r <- @legal_reasons do
        err = struct!(EngineError, reason: r)
        msg = Exception.message(err)
        assert is_binary(msg)
        assert msg != ""
      end
    end
  end

  describe "term_to_binary/binary_to_term round-trip" do
    test "a fully populated EngineError round-trips to equal value" do
      err =
        EngineError.new(:missing_model,
          message: "model not set",
          provider: :anthropic,
          cause: {:down, :normal},
          metadata: %{attempt: 1}
        )

      assert err == err |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end
  end

  # NOTE: ALLM.Serializer JSON round-trip is deferred to sub-phase 1.5.
end
