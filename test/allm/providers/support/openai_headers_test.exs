defmodule ALLM.Providers.Support.OpenAIHeadersTest do
  @moduledoc """
  Unit tests for `ALLM.Providers.Support.OpenAIHeaders` (Phase 15.1
  Decision #11).

  The module is a tiny pure builder; the bulk of behavior coverage lives
  in moduledoc doctests. This file pulls those in via `doctest` and adds
  a few targeted assertions on edge cases — empty `opts`, non-binary
  `:organization` (treated as absent per the helper's match clauses),
  and `adapter_opts` absent entirely.
  """

  use ExUnit.Case, async: true

  alias ALLM.Providers.Support.OpenAIHeaders

  doctest OpenAIHeaders

  describe "json_headers/2" do
    test "with empty opts returns just authorization + content-type" do
      assert OpenAIHeaders.json_headers("sk-x", []) == [
               {"authorization", "Bearer sk-x"},
               {"content-type", "application/json"}
             ]
    end

    test "with adapter_opts: [] returns the same as empty opts" do
      assert OpenAIHeaders.json_headers("sk-x", adapter_opts: []) == [
               {"authorization", "Bearer sk-x"},
               {"content-type", "application/json"}
             ]
    end

    test "prefixes openai-organization when adapter_opts[:organization] is a binary" do
      headers = OpenAIHeaders.json_headers("sk-x", adapter_opts: [organization: "org-1"])

      assert headers == [
               {"openai-organization", "org-1"},
               {"authorization", "Bearer sk-x"},
               {"content-type", "application/json"}
             ]
    end

    test "ignores adapter_opts[:organization] when nil" do
      headers = OpenAIHeaders.json_headers("sk-x", adapter_opts: [organization: nil])

      assert headers == [
               {"authorization", "Bearer sk-x"},
               {"content-type", "application/json"}
             ]
    end
  end

  describe "multipart_headers/2" do
    test "with empty opts returns just authorization (no content-type)" do
      assert OpenAIHeaders.multipart_headers("sk-x", []) == [
               {"authorization", "Bearer sk-x"}
             ]
    end

    test "with adapter_opts: [] returns the same as empty opts" do
      assert OpenAIHeaders.multipart_headers("sk-x", adapter_opts: []) == [
               {"authorization", "Bearer sk-x"}
             ]
    end

    test "prefixes openai-organization when adapter_opts[:organization] is a binary" do
      headers = OpenAIHeaders.multipart_headers("sk-x", adapter_opts: [organization: "org-2"])

      assert headers == [
               {"openai-organization", "org-2"},
               {"authorization", "Bearer sk-x"}
             ]
    end

    test "never includes content-type — Req's :form_multipart step stamps the boundary" do
      headers = OpenAIHeaders.multipart_headers("sk-x", adapter_opts: [organization: "org-3"])
      refute Enum.any?(headers, fn {k, _v} -> k == "content-type" end)
    end
  end
end
