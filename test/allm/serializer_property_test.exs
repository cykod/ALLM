defmodule ALLM.SerializerPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ALLM.Serializer
  alias ALLM.Test.Generators

  @moduletag :roundtrip

  describe "to_json!/1 |> from_json/1 round-trip" do
    property "Message generator round-trips equal" do
      check all(msg <- Generators.message_gen()) do
        assert {:ok, ^msg} = msg |> Serializer.to_json!() |> Serializer.from_json()
      end
    end

    property "Tool generator round-trips equal" do
      check all(tool <- Generators.tool_gen()) do
        assert {:ok, ^tool} = tool |> Serializer.to_json!() |> Serializer.from_json()
      end
    end

    property "Request generator round-trips equal (covers nested Message and Tool)" do
      check all(req <- Generators.request_gen()) do
        assert {:ok, ^req} = req |> Serializer.to_json!() |> Serializer.from_json()
      end
    end
  end
end
