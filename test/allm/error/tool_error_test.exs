defmodule ALLM.Error.ToolErrorTest do
  use ExUnit.Case, async: true

  alias ALLM.Error.ToolError

  doctest ToolError

  @legal_reasons [
    :handler_raised,
    :handler_exit,
    :timeout,
    :invalid_return,
    :not_found,
    :encoding_failed
  ]

  describe "new/2" do
    test "sets every documented field from opts" do
      err =
        ToolError.new(:handler_raised,
          message: "handler blew up",
          tool_name: "search_web",
          tool_call_id: "call_123",
          cause: %RuntimeError{message: "boom"},
          metadata: %{duration_ms: 10}
        )

      assert %ToolError{
               reason: :handler_raised,
               message: "handler blew up",
               tool_name: "search_web",
               tool_call_id: "call_123",
               cause: %RuntimeError{message: "boom"},
               metadata: %{duration_ms: 10}
             } = err
    end

    test "raises ArgumentError when reason is nil (required positional)" do
      assert_raise ArgumentError, ~r/unknown reason/, fn -> ToolError.new(nil) end
    end

    test "raises ArgumentError for unknown reason atom" do
      assert_raise ArgumentError, ~r/unknown reason/, fn ->
        ToolError.new(:not_a_real_tool_reason)
      end
    end

    test "populates :message with the documented default when no tool_name is set" do
      err = ToolError.new(:handler_raised)
      assert err.message == "tool error: handler_raised"
      assert Exception.message(err) == "tool error: handler_raised"
    end

    test "populates :message with tool_name suffix when tool_name is set" do
      err = ToolError.new(:handler_raised, tool_name: "search_web")
      assert err.message == "tool error (search_web): handler_raised"
      assert Exception.message(err) == "tool error (search_web): handler_raised"
    end

    test "defaults metadata to an empty map" do
      err = ToolError.new(:handler_raised)
      assert err.metadata == %{}
    end
  end

  describe "Exception protocol" do
    test "raise/rescue cycle exposes the stored :message" do
      try do
        raise ToolError.new(:timeout, message: "too slow")
      rescue
        e in ToolError ->
          assert Exception.message(e) == "too slow"
      end
    end

    test "raw struct with only :reason yields a non-empty message via fallback" do
      err = %ToolError{reason: :handler_raised}
      assert Exception.message(err) == "tool error: handler_raised"
    end

    test "raw struct with :tool_name but no :message uses tool_name fallback" do
      err = %ToolError{reason: :timeout, tool_name: "search_web"}
      assert Exception.message(err) == "tool error (search_web): timeout"
    end

    test "raw struct with nil reason falls through to a generic message" do
      err = %ToolError{reason: nil}
      assert Exception.message(err) == "tool error"
    end

    test "every legal reason produces a non-empty message via raw struct" do
      for r <- @legal_reasons do
        err = struct!(ToolError, reason: r)
        msg = Exception.message(err)
        assert is_binary(msg)
        assert msg != ""
      end
    end
  end

  describe "term_to_binary round-trip" do
    test "a fully populated ToolError round-trips to equal value" do
      err =
        ToolError.new(:invalid_return,
          message: "bad shape",
          tool_name: "search_web",
          tool_call_id: "call_1",
          cause: {:unexpected, :tuple},
          metadata: %{attempts: 1}
        )

      assert err == err |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end
  end

  # NOTE: ALLM.Serializer JSON round-trip is deferred to sub-phase 1.5.
end
