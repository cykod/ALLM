defmodule ALLM.AudioStream.ChatStreamErrorTest do
  use ExUnit.Case, async: true

  alias ALLM.AudioStream.ChatStreamError
  alias ALLM.Error.AdapterError

  test "an exception with an atom reason keeps the reason and uses its message" do
    err = AdapterError.new(:rate_limited, message: "slow down")

    assert %ChatStreamError{reason: :rate_limited, message: message} =
             ChatStreamError.exception(err)

    assert message == "the chat stream failed (:rate_limited): #{Exception.message(err)}"
  end

  test "a non-exception term falls back to :unknown and its inspect form" do
    assert %ChatStreamError{reason: :unknown, message: message} =
             ChatStreamError.exception(%{reason: "not-an-atom"})

    assert message == ~s|the chat stream failed (:unknown): %{reason: "not-an-atom"}|
  end

  test "a bare map with an atom reason keeps the reason" do
    assert %ChatStreamError{reason: :timeout} = ChatStreamError.exception(%{reason: :timeout})
  end
end
