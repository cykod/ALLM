defmodule ALLM.ModerationResponseTest do
  use ExUnit.Case, async: true

  alias ALLM.{ModerationResponse, ModerationResult, Serializer}

  doctest ALLM.ModerationResponse

  @clean ModerationResult.new(
           flagged: false,
           categories: %{"violence" => false, "hate" => false},
           index: 0
         )

  @flagged_violence ModerationResult.new(
                      flagged: true,
                      categories: %{"violence" => true, "hate" => false},
                      category_scores: %{"violence" => 0.9412},
                      index: 1
                    )

  @flagged_hate ModerationResult.new(
                  flagged: true,
                  categories: %{"violence" => true, "hate" => true},
                  index: 2
                )

  describe "new/1" do
    test "defaults results to [], metadata to %{}, everything else to nil" do
      resp = ModerationResponse.new()
      assert resp.id == nil
      assert resp.request_id == nil
      assert resp.model == nil
      assert resp.provider == nil
      assert resp.raw == nil
      assert resp.results == []
      assert resp.metadata == %{}
    end

    test "with an unknown key raises KeyError" do
      assert_raise KeyError, fn -> ModerationResponse.new(bogus: 1) end
    end
  end

  describe "flagged?/1" do
    test "is true when any result is flagged" do
      assert ModerationResponse.flagged?(
               ModerationResponse.new(results: [@clean, @flagged_violence])
             )
    end

    test "is false when no result is flagged" do
      refute ModerationResponse.flagged?(ModerationResponse.new(results: [@clean]))
    end

    test "is false for an empty results list" do
      refute ModerationResponse.flagged?(ModerationResponse.new())
    end
  end

  describe "flagged_categories/1" do
    test "unions across results, deduplicated and sorted" do
      resp = ModerationResponse.new(results: [@clean, @flagged_violence, @flagged_hate])
      assert ModerationResponse.flagged_categories(resp) == ["hate", "violence"]
    end

    test "returns [] when nothing is flagged" do
      assert ModerationResponse.flagged_categories(ModerationResponse.new(results: [@clean])) == []
    end

    test "returns [] for an empty results list" do
      assert ModerationResponse.flagged_categories(ModerationResponse.new()) == []
    end
  end

  describe "__from_tagged__/1" do
    test "missing fields fall back to their defaults" do
      decoded = ModerationResponse.__from_tagged__(%{})
      assert decoded.results == []
      assert decoded.metadata == %{}
      assert decoded.provider == nil
    end

    test ":provider decodes through to_atom_field/1, not String.to_atom/1" do
      assert ModerationResponse.__from_tagged__(%{"provider" => "openai"}).provider == :openai
    end
  end

  describe "serializability" do
    @response ModerationResponse.new(
                id: "modr-970d409ef3bef3b70c73d8232df86e7d",
                request_id: "req-1",
                model: "omni-moderation-latest",
                provider: :openai,
                results: [@clean, @flagged_violence],
                raw: %{"id" => "modr-1"},
                metadata: %{"source" => "signup"}
              )

    test "round-trips through :erlang.term_to_binary/1" do
      assert @response == @response |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end

    test "two nested %ModerationResult{} structs round-trip as structs, not raw maps" do
      assert {:ok, @response} = @response |> Serializer.to_json!() |> Serializer.from_json()
      assert {:ok, decoded} = @response |> Serializer.to_json!() |> Serializer.from_json()
      assert [%ModerationResult{}, %ModerationResult{}] = decoded.results
    end

    test ":provider survives the JSON round-trip as an atom" do
      assert {:ok, decoded} = @response |> Serializer.to_json!() |> Serializer.from_json()
      assert decoded.provider == :openai
      assert is_atom(decoded.provider)
    end

    test "a default-valued response round-trips" do
      resp = ModerationResponse.new()
      assert {:ok, ^resp} = resp |> Serializer.to_json!() |> Serializer.from_json()
    end

    test "is dispatchable by an untagged :as hint — proves @known_modules registration" do
      json = Jason.encode!(%{"model" => "omni-moderation-latest"})

      assert {:ok, %ModerationResponse{model: "omni-moderation-latest"}} =
               Serializer.from_json(json, as: ModerationResponse)
    end

    test "a non-encodable :raw raises at encode time" do
      resp = ModerationResponse.new(raw: %{pid: self()})
      assert_raise Protocol.UndefinedError, fn -> Serializer.to_json!(resp) end
    end
  end
end
