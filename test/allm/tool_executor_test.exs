defmodule ALLM.ToolExecutorTest do
  @moduledoc """
  Contract-level tests for the `ALLM.ToolExecutor` behaviour.
  """

  use ExUnit.Case, async: true

  alias ALLM.Test.DocAssertions

  describe "@callback declarations" do
    test "execute/3 is declared" do
      assert {:execute, 3} in ALLM.ToolExecutor.behaviour_info(:callbacks)
    end
  end

  describe "@optional_callbacks" do
    test "is empty" do
      assert Enum.sort(ALLM.ToolExecutor.behaviour_info(:optional_callbacks)) == []
    end
  end

  describe "@moduledoc" do
    test "is present" do
      assert DocAssertions.doc_present?(DocAssertions.module_doc(ALLM.ToolExecutor))
    end
  end

  describe "@doc on every callback" do
    test "execute/3 carries a non-empty @doc" do
      callback_docs = DocAssertions.callback_docs(ALLM.ToolExecutor)
      assert {{:execute, 3}, doc} = Enum.find(callback_docs, &match?({{:execute, 3}, _}, &1))
      assert DocAssertions.doc_present?(doc)
    end
  end
end
