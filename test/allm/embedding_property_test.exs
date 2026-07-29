defmodule ALLM.EmbeddingPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ALLM.{Embedding, EmbeddingResponse}

  # `magnitude/1` raises ArithmeticError on float overflow (documented
  # contract, not defended against), so the generator is bounded well below
  # the point where a sum of squares can overflow a double.
  defp component_gen, do: StreamData.float(min: -1.0e6, max: 1.0e6)

  describe "normalize/1" do
    property "yields a unit vector, or leaves a zero-magnitude vector unchanged" do
      check all(components <- StreamData.list_of(component_gen())) do
        embedding = Embedding.new(vector: components)
        magnitude = Embedding.magnitude(embedding)
        normalized = Embedding.normalize(embedding)

        if magnitude == 0.0 do
          # Covers the empty, all-zero, and underflowing-component cases.
          assert normalized == embedding
        else
          assert_in_delta Embedding.magnitude(normalized), 1.0, 1.0e-9
        end
      end
    end

    property "is idempotent within 1.0e-9" do
      check all(components <- StreamData.list_of(component_gen(), min_length: 1)) do
        once = Embedding.normalize(Embedding.new(vector: components))
        twice = Embedding.normalize(once)

        Enum.zip(once.vector, twice.vector)
        |> Enum.each(fn {a, b} -> assert_in_delta a, b, 1.0e-9 end)
      end
    end

    property "preserves :index and :metadata for any input" do
      check all(
              components <- StreamData.list_of(component_gen()),
              index <- StreamData.integer(0..1000)
            ) do
        embedding = Embedding.new(vector: components, index: index, metadata: %{"i" => index})
        normalized = Embedding.normalize(embedding)

        assert normalized.index == index
        assert normalized.metadata == %{"i" => index}
        assert length(normalized.vector) == length(components)
      end
    end
  end

  describe "EmbeddingResponse.vectors/1" do
    property "returns vectors in :index order for any shuffling of the list" do
      check all(count <- StreamData.integer(1..25)) do
        embeddings =
          for index <- 0..(count - 1) do
            Embedding.new(vector: [index * 1.0], index: index)
          end

        response = EmbeddingResponse.new(embeddings: Enum.shuffle(embeddings))
        expected = for index <- 0..(count - 1), do: [index * 1.0]

        assert EmbeddingResponse.vectors(response) == expected
      end
    end
  end
end
