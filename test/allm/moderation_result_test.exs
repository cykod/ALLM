defmodule ALLM.ModerationResultTest do
  use ExUnit.Case, async: true

  alias ALLM.{ModerationResult, Serializer}

  doctest ALLM.ModerationResult

  # A 13-key omni-shaped category map with no `nil` values — the adapter drops
  # null-valued keys at decode time, so a `%ModerationResult{}` never carries
  # one.
  @categories %{
    "harassment" => false,
    "harassment/threatening" => false,
    "hate" => false,
    "hate/threatening" => false,
    "illicit" => false,
    "illicit/violent" => false,
    "self-harm" => false,
    "self-harm/instructions" => false,
    "self-harm/intent" => false,
    "sexual" => true,
    "sexual/minors" => false,
    "violence" => true,
    "violence/graphic" => false
  }

  @scores %{
    "sexual" => 0.37701736389561064,
    "violence" => 0.9412,
    "hate" => 1.2e-5
  }

  describe "new/1" do
    test "without :flagged raises ArgumentError" do
      # `@enforce_keys [:flagged]` — enforcement is on key absence.
      assert_raise ArgumentError, fn -> ModerationResult.new(categories: %{}) end
    end

    test "defaults every other field" do
      result = ModerationResult.new(flagged: false)
      assert result.categories == %{}
      assert result.category_scores == %{}
      assert result.applied_input_types == %{}
      assert result.index == 0
      assert result.metadata == %{}
    end

    test "with an unknown key raises KeyError" do
      assert_raise KeyError, fn -> ModerationResult.new(flagged: false, bogus: 1) end
    end
  end

  describe "flagged_categories/1" do
    test "returns only true-valued keys, sorted" do
      result = ModerationResult.new(flagged: true, categories: @categories)
      assert ModerationResult.flagged_categories(result) == ["sexual", "violence"]
    end

    test "returns [] when nothing is flagged" do
      categories = Map.new(@categories, fn {k, _v} -> {k, false} end)
      result = ModerationResult.new(flagged: false, categories: categories)
      assert ModerationResult.flagged_categories(result) == []
    end

    test "returns [] for an empty category map" do
      assert ModerationResult.flagged_categories(ModerationResult.new(flagged: false)) == []
    end
  end

  describe "score/2" do
    test "returns the float for a present category" do
      result = ModerationResult.new(flagged: true, category_scores: @scores)
      assert ModerationResult.score(result, "violence") == 0.9412
    end

    test "returns nil for an absent category" do
      result = ModerationResult.new(flagged: true, category_scores: @scores)
      assert ModerationResult.score(result, "harassment") == nil
    end

    test "returns nil for an empty score map" do
      assert ModerationResult.score(ModerationResult.new(flagged: false), "violence") == nil
    end
  end

  describe "__from_tagged__/1" do
    test "a payload whose \"flagged\" key is absent decodes to false, not nil" do
      # Fail-closed repair — the one place in this family where a decoder
      # repairs rather than passing through.
      assert ModerationResult.__from_tagged__(%{}).flagged == false
    end

    test "a non-boolean \"flagged\" value is repaired to false" do
      assert ModerationResult.__from_tagged__(%{"flagged" => "yes"}).flagged == false
      assert ModerationResult.__from_tagged__(%{"flagged" => nil}).flagged == false
    end

    # The repair is SILENT: `:categories` and `:category_scores` decode
    # independently of `:flagged`, so nothing in the struct marks a repaired
    # verdict. The moduledoc and spec §39.4 both claimed the empty category
    # maps were the honest signal that something had gone wrong; both were
    # measured false and corrected in Phase 22.7. This test is what keeps the
    # claim from coming back.
    test "a repaired :flagged leaves a fully populated category map beside it" do
      decoded =
        ModerationResult.__from_tagged__(%{
          "flagged" => "true",
          "categories" => %{"violence" => true},
          "category_scores" => %{"violence" => 0.91}
        })

      assert decoded.flagged == false
      assert decoded.categories == %{"violence" => true}
      assert decoded.category_scores == %{"violence" => 0.91}
    end

    test "a true \"flagged\" value is preserved" do
      assert ModerationResult.__from_tagged__(%{"flagged" => true}).flagged == true
    end

    test "missing collection fields fall back to their defaults" do
      decoded = ModerationResult.__from_tagged__(%{})
      assert decoded.categories == %{}
      assert decoded.category_scores == %{}
      assert decoded.applied_input_types == %{}
      assert decoded.index == 0
      assert decoded.metadata == %{}
    end

    test "category maps decode as identity — no atom conversion, no coercion" do
      decoded =
        ModerationResult.__from_tagged__(%{
          "flagged" => true,
          "categories" => @categories,
          "category_scores" => @scores
        })

      assert decoded.categories == @categories
      assert decoded.category_scores == @scores
    end
  end

  describe "serializability" do
    @result ModerationResult.new(
              flagged: true,
              categories: @categories,
              category_scores: @scores,
              applied_input_types: %{"violence" => ["image"], "sexual" => ["text", "image"]},
              index: 2,
              metadata: %{"note" => "batch entry"}
            )

    test "round-trips through :erlang.term_to_binary/1" do
      assert @result == @result |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end

    test "a non-integral score and a 13-key category map round-trip identically" do
      assert {:ok, @result} = @result |> Serializer.to_json!() |> Serializer.from_json()
      assert {:ok, decoded} = @result |> Serializer.to_json!() |> Serializer.from_json()
      assert decoded.category_scores["sexual"] == 0.37701736389561064
      assert map_size(decoded.categories) == 13

      assert decoded.applied_input_types == %{
               "violence" => ["image"],
               "sexual" => ["text", "image"]
             }
    end

    test "a minimal result round-trips" do
      result = ModerationResult.new(flagged: false)
      assert {:ok, ^result} = result |> Serializer.to_json!() |> Serializer.from_json()
    end

    test "is dispatchable by an untagged :as hint — proves @known_modules registration" do
      json = Jason.encode!(%{"flagged" => true})

      assert {:ok, %ModerationResult{flagged: true}} =
               Serializer.from_json(json, as: ModerationResult)
    end
  end
end
