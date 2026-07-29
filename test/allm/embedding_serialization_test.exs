defmodule ALLM.EmbeddingSerializationTest do
  use ExUnit.Case, async: true

  alias ALLM.{Embedding, EmbeddingRequest, EmbeddingResponse, Serializer, Usage}

  @embedding Embedding.new(vector: [0.1, 0.2], index: 3, metadata: %{"k" => "v"})
  @request EmbeddingRequest.new(
             input: ["a kestrel", "a cedar branch"],
             model: "text-embedding-3-small",
             dimensions: 512,
             task_type: :search_document,
             truncate: false,
             options: %{"user" => "u1"},
             metadata: %{"source" => "ingest"}
           )
  @response EmbeddingResponse.new(
              id: "emb-1",
              request_id: "req-1",
              model: "text-embedding-3-small",
              embeddings: [Embedding.new(vector: [0.1, 0.2], index: 0)],
              usage: Usage.new(input_tokens: 4, total_tokens: 4),
              raw: %{"object" => "list"},
              metadata: %{"chunk_count" => 1}
            )

  describe "ETF round-trip" do
    test "%Embedding{} round-trips" do
      assert @embedding == @embedding |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end

    test "%EmbeddingRequest{} round-trips" do
      assert @request == @request |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end

    test "%EmbeddingResponse{} round-trips" do
      assert @response == @response |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end
  end

  describe "JSON round-trip via ALLM.Serializer" do
    test "%Embedding{} round-trips" do
      assert {:ok, @embedding} = @embedding |> Serializer.to_json!() |> Serializer.from_json()
    end

    test "%EmbeddingRequest{} round-trips" do
      assert {:ok, @request} = @request |> Serializer.to_json!() |> Serializer.from_json()
    end

    test "%EmbeddingResponse{} round-trips, nested %Embedding{} and %Usage{} included" do
      assert {:ok, @response} = @response |> Serializer.to_json!() |> Serializer.from_json()
    end

    test "the phase success criterion: a one-embedding response survives unchanged" do
      resp = %EmbeddingResponse{embeddings: [%Embedding{index: 0, vector: [0.1, 0.2]}]}
      assert {:ok, ^resp} = resp |> Serializer.to_json!() |> Serializer.from_json()
    end

    test "default-valued structs round-trip" do
      for value <- [EmbeddingRequest.new(), EmbeddingResponse.new()] do
        assert {:ok, ^value} = value |> Serializer.to_json!() |> Serializer.from_json()
      end
    end
  end

  describe "@known_modules registry" do
    test "all three structs are dispatchable by an untagged :as hint" do
      # `from_json/2`'s `:as` path gates on `module in @known_modules`, so a
      # successful untagged dispatch proves registration.
      for mod <- [Embedding, EmbeddingRequest, EmbeddingResponse] do
        json = Jason.encode!(%{"vector" => [1.0]})
        assert {:ok, %^mod{}} = Serializer.from_json(json, as: mod)
      end
    end

    test "tagged dispatch routes through each module's __from_tagged__/1" do
      json = Serializer.to_json!(@request)
      assert Jason.decode!(json)["__type__"] == "ALLM.EmbeddingRequest"
      assert {:ok, %EmbeddingRequest{}} = Serializer.from_json(json)
    end
  end

  describe "decode-time coercions" do
    test "%Embedding{vector: [0, 1]} (integer elements) decodes to [0.0, 1.0]" do
      # Decision #8 — the decoder applies `* 1.0` so the `[float()]` type holds
      # for hand-built payloads. Consequence: an integer-valued vector is NOT
      # JSON-equality-preserving, by design.
      encoded = Serializer.to_json!(%Embedding{vector: [0, 1]})
      assert {:ok, decoded} = Serializer.from_json(encoded)
      assert decoded.vector == [0.0, 1.0]
      # `==` coerces `0 == 0.0`, so assert float-ness explicitly.
      assert Enum.all?(decoded.vector, &is_float/1)
    end

    test "an out-of-float-range integer vector element keeps from_json/2 on its contract" do
      # from_json/2 promises {:ok, struct()} | {:error, ValidationError.t()}.
      # hydrate_with/2 rescues ValidationError and ArgumentError only, so an
      # ArithmeticError raised while coercing a bignum would escape both.
      json =
        Jason.encode!(%{
          "__type__" => "ALLM.Embedding",
          "data" => %{"vector" => [10 ** 400]}
        })

      assert {:ok, %Embedding{}} = Serializer.from_json(json)
    end

    test "%EmbeddingRequest{task_type: :search_query} restores the atom, not the string" do
      req = EmbeddingRequest.new(input: ["x"], task_type: :search_query)
      assert {:ok, decoded} = req |> Serializer.to_json!() |> Serializer.from_json()
      assert decoded.task_type == :search_query
      assert is_atom(decoded.task_type)
    end

    test ~s(a "task_type" => "nonsense" payload surfaces {:_unknown, :atom_decode_failed}) do
      json =
        Jason.encode!(%{
          "__type__" => "ALLM.EmbeddingRequest",
          "data" => %{"input" => ["x"], "task_type" => "nonsense_task_type_never_defined"}
        })

      assert {:error, err} = Serializer.from_json(json)
      assert {:_unknown, :atom_decode_failed} in err.errors
    end

    test ~s(an "usage" => null payload hydrates to %ALLM.Usage{}, not nil) do
      json =
        Jason.encode!(%{
          "__type__" => "ALLM.EmbeddingResponse",
          "data" => %{"model" => "m", "usage" => nil, "embeddings" => []}
        })

      assert {:ok, decoded} = Serializer.from_json(json)
      assert decoded.usage == %Usage{}
    end
  end

  describe "raw-field contract" do
    test "a non-encodable :raw raises at encode time" do
      # Same caller-responsibility contract as `ALLM.Response.raw` /
      # `ALLM.ImageResponse.raw`.
      resp = EmbeddingResponse.new(raw: %{pid: self()})
      assert_raise Protocol.UndefinedError, fn -> Serializer.to_json!(resp) end
    end
  end
end
