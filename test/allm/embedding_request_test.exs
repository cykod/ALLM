defmodule ALLM.EmbeddingRequestTest do
  use ExUnit.Case, async: true
  doctest ALLM.EmbeddingRequest

  alias ALLM.EmbeddingRequest

  @task_types [:search_document, :search_query, :classification, :clustering, :similarity]

  describe "new/1" do
    test "defaults input to [], truncate to true, task_type to nil" do
      req = EmbeddingRequest.new()
      assert req.input == []
      assert req.truncate == true
      assert req.task_type == nil
      assert req.model == nil
      assert req.dimensions == nil
      assert req.options == %{}
      assert req.metadata == %{}
    end

    test "no @enforce_keys — an empty input list is constructible" do
      # Divergence D10: the validator, not `struct!/2`, is what rejects
      # `input: []`, which is what makes `{:input, :empty}` reachable.
      assert %EmbeddingRequest{input: []} = EmbeddingRequest.new([])
    end

    test "opts populate the fields" do
      req =
        EmbeddingRequest.new(
          input: ["a", "b"],
          model: "text-embedding-3-small",
          dimensions: 512,
          truncate: false,
          options: %{"user" => "u1"},
          metadata: %{"source" => "ingest"}
        )

      assert req.input == ["a", "b"]
      assert req.model == "text-embedding-3-small"
      assert req.dimensions == 512
      assert req.truncate == false
      assert req.options == %{"user" => "u1"}
      assert req.metadata == %{"source" => "ingest"}
    end

    for tt <- @task_types do
      test "with task_type: #{inspect(tt)} round-trips through the struct" do
        req = EmbeddingRequest.new(input: ["x"], task_type: unquote(tt))
        assert req.task_type == unquote(tt)
      end
    end

    test "with an unknown key raises KeyError" do
      assert_raise KeyError, fn -> EmbeddingRequest.new(bogus: 1) end
    end
  end

  describe "__from_tagged__/1" do
    test "restores :task_type as an atom" do
      decoded = EmbeddingRequest.__from_tagged__(%{"task_type" => "search_query"})
      assert decoded.task_type == :search_query
    end

    test "a missing :truncate defaults to true" do
      assert EmbeddingRequest.__from_tagged__(%{}).truncate == true
    end

    test "an explicit false :truncate is preserved, not flipped to the default" do
      # The `data["truncate"] || true` idiom would be wrong here.
      assert EmbeddingRequest.__from_tagged__(%{"truncate" => false}).truncate == false
    end

    test "missing collection fields fall back to their defaults" do
      decoded = EmbeddingRequest.__from_tagged__(%{})
      assert decoded.input == []
      assert decoded.options == %{}
      assert decoded.metadata == %{}
    end
  end
end
