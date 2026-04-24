defmodule ALLM.StreamAdapterTest do
  @moduledoc """
  Contract-level tests for the `ALLM.StreamAdapter` behaviour.
  """

  use ExUnit.Case, async: true

  alias ALLM.Test.DocAssertions

  describe "@callback declarations" do
    test "stream/2 is declared" do
      assert {:stream, 2} in ALLM.StreamAdapter.behaviour_info(:callbacks)
    end
  end

  describe "@optional_callbacks" do
    test "is empty" do
      assert Enum.sort(ALLM.StreamAdapter.behaviour_info(:optional_callbacks)) == []
    end
  end

  describe "@moduledoc" do
    test "is present" do
      assert DocAssertions.doc_present?(DocAssertions.module_doc(ALLM.StreamAdapter))
    end
  end

  describe "@doc on every callback" do
    test "stream/2 carries a non-empty @doc" do
      callback_docs = DocAssertions.callback_docs(ALLM.StreamAdapter)
      assert {{:stream, 2}, doc} = Enum.find(callback_docs, &match?({{:stream, 2}, _}, &1))
      assert DocAssertions.doc_present?(doc)
    end
  end
end
