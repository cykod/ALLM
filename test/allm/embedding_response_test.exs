defmodule ALLM.EmbeddingResponseTest do
  use ExUnit.Case, async: true
  doctest ALLM.EmbeddingResponse

  alias ALLM.{Embedding, EmbeddingResponse, Usage}

  describe "new/1" do
    test "defaults usage to %ALLM.Usage{} not nil" do
      resp = EmbeddingResponse.new()
      assert resp.usage == %Usage{}
      refute is_nil(resp.usage)
    end

    test "defaults embeddings to [], metadata to %{}, raw to nil" do
      resp = EmbeddingResponse.new()
      assert resp.embeddings == []
      assert resp.metadata == %{}
      assert resp.raw == nil
      assert resp.id == nil
      assert resp.request_id == nil
      assert resp.model == nil
    end

    test "opts populate the fields" do
      resp =
        EmbeddingResponse.new(
          id: "emb-1",
          request_id: "req-1",
          model: "text-embedding-3-small",
          embeddings: [Embedding.new(vector: [1.0])],
          usage: Usage.new(input_tokens: 4, total_tokens: 4)
        )

      assert resp.id == "emb-1"
      assert resp.request_id == "req-1"
      assert resp.model == "text-embedding-3-small"
      assert resp.usage.total_tokens == 4
    end

    test "with an unknown key raises KeyError" do
      assert_raise KeyError, fn -> EmbeddingResponse.new(bogus: 1) end
    end
  end

  describe "vectors/1" do
    test "returns vectors sorted by :index" do
      resp =
        EmbeddingResponse.new(
          embeddings: [
            Embedding.new(vector: [2.0], index: 2),
            Embedding.new(vector: [0.0], index: 0),
            Embedding.new(vector: [1.0], index: 1)
          ]
        )

      assert EmbeddingResponse.vectors(resp) == [[0.0], [1.0], [2.0]]
    end

    test "on an empty response returns []" do
      assert EmbeddingResponse.vectors(EmbeddingResponse.new()) == []
    end

    test "handles non-contiguous indices left by a chunk merge" do
      resp =
        EmbeddingResponse.new(
          embeddings: [
            Embedding.new(vector: [9.0], index: 200),
            Embedding.new(vector: [5.0], index: 100)
          ]
        )

      assert EmbeddingResponse.vectors(resp) == [[5.0], [9.0]]
    end
  end

  describe "dimensions/1" do
    test "returns the length of the first vector" do
      resp = EmbeddingResponse.new(embeddings: [Embedding.new(vector: [1.0, 2.0, 3.0])])
      assert EmbeddingResponse.dimensions(resp) == 3
    end

    test "on an empty response returns nil" do
      assert EmbeddingResponse.dimensions(EmbeddingResponse.new()) == nil
    end

    test "a hand-built empty first vector returns 0, not nil" do
      # The @spec is non_neg_integer() | nil, not pos_integer() | nil: adapters
      # reject vector: [] as :malformed_response, but %EmbeddingResponse{} is
      # public Layer A data a caller can build directly. Pinned so 0 stays
      # deliberate and nil keeps its single meaning ("no embeddings").
      resp = EmbeddingResponse.new(embeddings: [Embedding.new(vector: [])])
      assert EmbeddingResponse.dimensions(resp) == 0
    end

    test "reads list order, not :index order" do
      resp =
        EmbeddingResponse.new(
          embeddings: [
            Embedding.new(vector: [1.0, 2.0, 3.0], index: 1),
            Embedding.new(vector: [9.0], index: 0)
          ]
        )

      assert EmbeddingResponse.dimensions(resp) == 3
      assert length(hd(EmbeddingResponse.vectors(resp))) == 1
    end
  end

  describe "__from_tagged__/1 — hydrate_usage/1 arms" do
    test "nil arm produces a default %ALLM.Usage{}" do
      assert EmbeddingResponse.__from_tagged__(%{"usage" => nil}).usage == %Usage{}
    end

    test "missing-key arm produces a default %ALLM.Usage{}" do
      assert EmbeddingResponse.__from_tagged__(%{}).usage == %Usage{}
    end

    test "untagged-other arm passes the value through verbatim" do
      data = %{"usage" => %{"total_tokens" => 5}}
      assert EmbeddingResponse.__from_tagged__(data).usage == %{"total_tokens" => 5}
    end

    test "tagged-but-non-Usage payload falls back to the default" do
      tagged = %{
        "__type__" => "ALLM.Embedding",
        "data" => %{"vector" => [1.0], "index" => 0, "metadata" => %{}}
      }

      assert EmbeddingResponse.__from_tagged__(%{"usage" => tagged}).usage == %Usage{}
    end

    test "hydrates a tagged %ALLM.Usage{} payload" do
      tagged = ALLM.Serializer.to_json!(Usage.new(input_tokens: 7)) |> Jason.decode!()
      decoded = EmbeddingResponse.__from_tagged__(%{"usage" => tagged})
      assert decoded.usage == Usage.new(input_tokens: 7)
    end

    test "missing collection fields fall back to their defaults" do
      decoded = EmbeddingResponse.__from_tagged__(%{})
      assert decoded.embeddings == []
      assert decoded.metadata == %{}
    end
  end
end
