defmodule ALLM.ToolResultEncoderTest do
  @moduledoc """
  Contract-level tests for the `ALLM.ToolResultEncoder` behaviour.
  """

  use ExUnit.Case, async: true

  alias ALLM.Test.DocAssertions

  describe "@callback declarations" do
    test "encode/1 is declared" do
      assert {:encode, 1} in ALLM.ToolResultEncoder.behaviour_info(:callbacks)
    end
  end

  describe "@optional_callbacks" do
    test "is empty" do
      assert Enum.sort(ALLM.ToolResultEncoder.behaviour_info(:optional_callbacks)) == []
    end
  end

  describe "@moduledoc" do
    test "is present" do
      assert DocAssertions.doc_present?(DocAssertions.module_doc(ALLM.ToolResultEncoder))
    end
  end

  describe "@doc on every callback" do
    test "encode/1 carries a non-empty @doc" do
      callback_docs = DocAssertions.callback_docs(ALLM.ToolResultEncoder)
      assert {{:encode, 1}, doc} = Enum.find(callback_docs, &match?({{:encode, 1}, _}, &1))
      assert DocAssertions.doc_present?(doc)
    end
  end
end
