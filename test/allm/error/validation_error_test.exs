defmodule ALLM.Error.ValidationErrorTest do
  use ExUnit.Case, async: true

  alias ALLM.Error.ValidationError

  doctest ValidationError

  @legal_reasons [
    :invalid_request,
    :invalid_message,
    :invalid_tool,
    :invalid_thread,
    :invalid_session,
    :vision_not_in_v0_2
  ]

  describe "new/3" do
    test "sets every documented field from opts" do
      err =
        ValidationError.new(
          :invalid_request,
          [{:messages, :empty}, {[:messages, 0, :role], :unknown}],
          message: "2 errors",
          cause: :original_term,
          metadata: %{from: :test}
        )

      assert %ValidationError{
               reason: :invalid_request,
               message: "2 errors",
               errors: [{:messages, :empty}, {[:messages, 0, :role], :unknown}],
               cause: :original_term,
               metadata: %{from: :test}
             } = err
    end

    test "raises ArgumentError when reason is nil (required positional)" do
      assert_raise ArgumentError, ~r/unknown reason/, fn ->
        ValidationError.new(nil, [])
      end
    end

    test "raises ArgumentError for unknown reason atom" do
      assert_raise ArgumentError, ~r/unknown reason/, fn ->
        ValidationError.new(:bogus_reason, [])
      end
    end

    test "raises ArgumentError when errors is not a list" do
      assert_raise ArgumentError, ~r/errors must be a list/, fn ->
        ValidationError.new(:invalid_request, :not_a_list)
      end
    end

    test "populates :message with the documented default when omitted" do
      err = ValidationError.new(:invalid_request, [{:messages, :empty}])
      assert err.message == "validation failed: invalid_request (1 error(s))"
      assert Exception.message(err) == "validation failed: invalid_request (1 error(s))"
    end

    test "defaults metadata to an empty map" do
      err = ValidationError.new(:invalid_request, [])
      assert err.metadata == %{}
    end

    test "default message reflects an empty errors list" do
      err = ValidationError.new(:invalid_tool, [])
      assert err.message == "validation failed: invalid_tool (0 error(s))"
    end
  end

  describe "Exception protocol" do
    test "raise/rescue cycle exposes the stored :message" do
      try do
        raise ValidationError.new(:invalid_message, [], message: "custom")
      rescue
        e in ValidationError ->
          assert Exception.message(e) == "custom"
      end
    end

    test "raw struct with only :reason and :errors yields a non-empty message" do
      err = %ValidationError{reason: :invalid_request, errors: [{:x, :y}]}
      assert Exception.message(err) == "validation failed: invalid_request (1 error(s))"
    end

    test "raw struct with :reason only (no errors) still yields a non-empty message" do
      err = %ValidationError{reason: :invalid_thread}
      msg = Exception.message(err)
      assert is_binary(msg)
      assert msg != ""
    end

    test "raw struct with :reason set but :errors nil uses count-0 fallback" do
      # Exercises the message/1 clause that fires when :reason is a non-nil atom
      # but :errors is not a list (typically nil from bypassing .new/3).
      err = %ValidationError{reason: :invalid_request, errors: nil}
      assert Exception.message(err) == "validation failed: invalid_request (0 error(s))"
    end

    test "raw struct with nil reason and nil errors returns a generic fallback" do
      # forces the last message/1 clause (neither message nor atom reason)
      err = %ValidationError{reason: nil, errors: nil}
      assert Exception.message(err) == "validation failed"
    end

    test "every legal reason produces a non-empty message via raw struct" do
      for r <- @legal_reasons do
        err = struct!(ValidationError, reason: r)
        msg = Exception.message(err)
        assert is_binary(msg)
        assert msg != ""
      end
    end
  end

  describe "term_to_binary round-trip" do
    test "a fully populated ValidationError round-trips to equal value" do
      err =
        ValidationError.new(
          :invalid_session,
          [{:pending_question, :required_for_status}],
          message: "explicit",
          cause: :original,
          metadata: %{status: :awaiting_user}
        )

      assert err == err |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end
  end

  # NOTE: ALLM.Serializer JSON round-trip is deferred to sub-phase 1.5.
end
