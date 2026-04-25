defmodule ALLM.Error.SessionErrorTest do
  use ExUnit.Case, async: true

  alias ALLM.Error.SessionError

  doctest SessionError

  @legal_reasons [
    :session_in_error_state,
    :invalid_status_for_operation,
    :no_pending_tool_call,
    :unknown_tool_call_id
  ]

  describe "new/2" do
    test "sets every documented field from opts" do
      err =
        SessionError.new(:unknown_tool_call_id,
          message: "tool call c0 not pending",
          cause: :enoent,
          metadata: %{tool_call_id: "c0"}
        )

      assert %SessionError{
               reason: :unknown_tool_call_id,
               message: "tool call c0 not pending",
               provider: nil,
               cause: :enoent,
               metadata: %{tool_call_id: "c0"}
             } = err
    end

    test "raises ArgumentError when reason is nil (required positional)" do
      assert_raise ArgumentError, ~r/unknown reason/, fn -> SessionError.new(nil) end
    end

    test "raises ArgumentError for unknown reason atom" do
      assert_raise ArgumentError, ~r/unknown reason/, fn ->
        SessionError.new(:not_a_real_reason)
      end
    end

    test "populates :message with the documented default when omitted" do
      err = SessionError.new(:session_in_error_state)
      assert err.message == "session error: session_in_error_state"
      assert Exception.message(err) == "session error: session_in_error_state"
    end

    test "defaults metadata to an empty map" do
      err = SessionError.new(:session_in_error_state)
      assert err.metadata == %{}
    end

    test ":provider is always nil" do
      err = SessionError.new(:unknown_tool_call_id)
      assert err.provider == nil
    end
  end

  describe "Exception protocol" do
    test "raise/rescue cycle exposes the stored :message" do
      try do
        raise SessionError.new(:session_in_error_state, message: "session corrupted")
      rescue
        e in SessionError ->
          assert Exception.message(e) == "session corrupted"
      end
    end

    test "raw struct construction with only :reason still yields a non-empty message" do
      err = %SessionError{reason: :session_in_error_state}
      assert is_binary(Exception.message(err))
      assert Exception.message(err) != ""
    end

    test "raw struct with nil reason falls through to a generic message" do
      err = %SessionError{reason: nil}
      assert Exception.message(err) == "session error"
    end

    test "every legal reason produces a non-empty message via raw struct" do
      for r <- @legal_reasons do
        err = struct!(SessionError, reason: r)
        msg = Exception.message(err)
        assert is_binary(msg)
        assert msg != ""
      end
    end
  end

  describe "term_to_binary/binary_to_term round-trip" do
    test "a fully populated SessionError round-trips to equal value" do
      err =
        SessionError.new(:unknown_tool_call_id,
          message: "tool call x not pending",
          cause: {:down, :normal},
          metadata: %{tool_call_id: "x", attempt: 1}
        )

      assert err == err |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end
  end

  describe "Jason round-trip via ALLM.Serializer" do
    test "encodes and decodes back to an equal value (string-keyed metadata)" do
      # Metadata uses string keys because JSON does not preserve atom keys
      # (same caller-owned contract as the other Phase 1 error structs).
      err =
        SessionError.new(:session_in_error_state,
          message: "boom",
          metadata: %{"step_index" => 2}
        )

      json = ALLM.Serializer.to_json!(err)
      {:ok, decoded} = ALLM.Serializer.from_json(json)
      assert decoded == err
    end
  end
end
