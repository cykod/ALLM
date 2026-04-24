defmodule ALLM.AdapterTest do
  @moduledoc """
  Contract-level tests for the `ALLM.Adapter` behaviour.

  These tests do not exercise a subject implementation — they assert the
  module-level shape (callback declarations, optional-callbacks set, doc
  presence) so behaviour drift (e.g., renaming `generate/2` to `run/2`)
  surfaces as a failing test. See Phase 3 Non-obvious Decision #9.
  """

  use ExUnit.Case, async: true

  alias ALLM.Test.DocAssertions

  doctest DocAssertions

  describe "@callback declarations" do
    test "generate/2 is declared" do
      assert {:generate, 2} in ALLM.Adapter.behaviour_info(:callbacks)
    end

    test "prepare_request/2 is declared" do
      assert {:prepare_request, 2} in ALLM.Adapter.behaviour_info(:callbacks)
    end

    test "translate_options/2 is declared" do
      assert {:translate_options, 2} in ALLM.Adapter.behaviour_info(:callbacks)
    end
  end

  describe "@optional_callbacks" do
    test "is set-equal to [prepare_request: 2, translate_options: 2]" do
      optional = ALLM.Adapter.behaviour_info(:optional_callbacks)
      assert Enum.sort(optional) == Enum.sort(prepare_request: 2, translate_options: 2)
    end
  end

  describe "@moduledoc" do
    test "is present" do
      assert DocAssertions.doc_present?(DocAssertions.module_doc(ALLM.Adapter))
    end
  end

  describe "@doc on every callback" do
    test "every declared callback carries a non-empty @doc" do
      callback_docs = DocAssertions.callback_docs(ALLM.Adapter)
      declared = ALLM.Adapter.behaviour_info(:callbacks)

      # Every declared callback must have a docs entry (Code.fetch_docs/1
      # emits one `{{:callback, _, _}, _, _, doc, _}` tuple per @callback).
      assert Enum.sort(Enum.map(callback_docs, fn {{n, a}, _} -> {n, a} end)) ==
               Enum.sort(declared)

      for {nameity, doc} <- callback_docs do
        assert DocAssertions.doc_present?(doc),
               "@doc missing on #{inspect(nameity)} in ALLM.Adapter"
      end
    end
  end
end
