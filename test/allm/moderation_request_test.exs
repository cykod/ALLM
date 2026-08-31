defmodule ALLM.ModerationRequestTest do
  use ExUnit.Case, async: true

  alias ALLM.{Image, ImagePart, ModerationRequest, Serializer}

  doctest ALLM.ModerationRequest

  @image_part ImagePart.new(Image.from_url("https://example.com/cat.png"), detail: :high)

  describe "new/1" do
    test "defaults input to [], model to nil, options and metadata to %{}" do
      req = ModerationRequest.new()
      assert req.input == []
      assert req.model == nil
      assert req.options == %{}
      assert req.metadata == %{}
    end

    test "opts populate the fields" do
      req =
        ModerationRequest.new(
          input: ["is this ok?"],
          model: "omni-moderation-latest",
          options: %{"user" => "u1"},
          metadata: %{"source" => "signup"}
        )

      assert req.input == ["is this ok?"]
      assert req.model == "omni-moderation-latest"
      assert req.options == %{"user" => "u1"}
      assert req.metadata == %{"source" => "signup"}
    end

    test "with an unknown key raises KeyError" do
      assert_raise KeyError, fn -> ModerationRequest.new(bogus: 1) end
    end

    test "accepts input: [] — the validator, not the constructor, rejects it" do
      # No `@enforce_keys`: `input: []` must be constructible so that
      # `ALLM.Validate.moderation_request/1` is what makes `{:input, :empty}`
      # reachable.
      assert %ModerationRequest{input: []} = ModerationRequest.new(input: [])
    end
  end

  describe "multimodal?/1" do
    test "is false for an all-strings input" do
      refute ModerationRequest.multimodal?(ModerationRequest.new(input: ["a", "b"]))
    end

    test "is true when any element is an %ImagePart{}" do
      assert ModerationRequest.multimodal?(ModerationRequest.new(input: ["a", @image_part]))
      assert ModerationRequest.multimodal?(ModerationRequest.new(input: [@image_part]))
    end

    test "is false for input: []" do
      refute ModerationRequest.multimodal?(ModerationRequest.new(input: []))
    end

    for bad <- [42, %{}, "raw"] do
      test "returns false for a non-list :input (#{inspect(bad)}) without raising" do
        # It runs in the `:start` telemetry metadata, which is built before
        # `ALLM.Validate.moderation_request/1` — so every "not a list" shape
        # must take one behaviour, not two.
        req = %ModerationRequest{input: unquote(Macro.escape(bad))}
        refute ModerationRequest.multimodal?(req)
      end
    end
  end

  describe "__from_tagged__/1" do
    test "missing fields fall back to their defaults" do
      decoded = ModerationRequest.__from_tagged__(%{})
      assert decoded.input == []
      assert decoded.model == nil
      assert decoded.options == %{}
      assert decoded.metadata == %{}
    end

    test "a non-list :input passes through verbatim rather than being repaired" do
      assert ModerationRequest.__from_tagged__(%{"input" => 42}).input == 42
    end

    test "string elements pass through unchanged" do
      assert ModerationRequest.__from_tagged__(%{"input" => ["a", "b"]}).input == ["a", "b"]
    end
  end

  describe "serializability" do
    @request ModerationRequest.new(
               input: ["is this ok?", "and this?"],
               model: "omni-moderation-latest",
               options: %{"user" => "u1"},
               metadata: %{"source" => "signup"}
             )

    test "round-trips through :erlang.term_to_binary/1" do
      assert @request == @request |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end

    test "round-trips through Serializer.to_json!/1 |> from_json/1" do
      assert {:ok, @request} = @request |> Serializer.to_json!() |> Serializer.from_json()
    end

    test "a default-valued request round-trips" do
      req = ModerationRequest.new()
      assert {:ok, ^req} = req |> Serializer.to_json!() |> Serializer.from_json()
    end

    test "an :input containing an %ImagePart{} round-trips through JSON as a struct" do
      req = ModerationRequest.new(input: ["some text", @image_part])
      assert {:ok, ^req} = req |> Serializer.to_json!() |> Serializer.from_json()
      assert {:ok, decoded} = req |> Serializer.to_json!() |> Serializer.from_json()
      assert [_text, %ImagePart{}] = decoded.input
    end

    test "an %ImagePart{}-bearing request round-trips through ETF" do
      req = ModerationRequest.new(input: ["some text", @image_part])
      assert req == req |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end

    test "is dispatchable by an untagged :as hint — proves @known_modules registration" do
      json = Jason.encode!(%{"input" => ["x"]})

      assert {:ok, %ModerationRequest{input: ["x"]}} =
               Serializer.from_json(json, as: ModerationRequest)
    end
  end
end
