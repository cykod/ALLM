defmodule ALLM.TranscriptSpanTest do
  use ExUnit.Case, async: true
  doctest ALLM.TranscriptSpan

  alias ALLM.{Serializer, TranscriptSpan}

  describe "new/1" do
    test "builds a span; unset attributes are nil" do
      assert %TranscriptSpan{
               text: "fox",
               kind: :word,
               start_seconds: nil,
               end_seconds: nil,
               logprob: nil
             } = TranscriptSpan.new(text: "fox", kind: :word)
    end

    test "a missing :text or :kind raises ArgumentError (@enforce_keys via struct!/2)" do
      assert_raise ArgumentError, ~r/:text/, fn -> TranscriptSpan.new(kind: :word) end
      assert_raise ArgumentError, ~r/:kind/, fn -> TranscriptSpan.new(text: "fox") end
    end

    test "an unknown key raises KeyError" do
      assert_raise KeyError, fn -> TranscriptSpan.new(text: "a", kind: :word, bogus: 1) end
    end

    test "field values are not checked" do
      span = TranscriptSpan.new(text: "a", kind: :nonsense, start_seconds: 2, end_seconds: 1)
      assert %TranscriptSpan{kind: :nonsense, start_seconds: 2, end_seconds: 1} = span
    end
  end

  describe "kinds/0" do
    test "is the five kinds in contract order" do
      assert TranscriptSpan.kinds() == [:word, :spacing, :audio_event, :token, :other]
    end
  end

  describe "serializability" do
    defp one_of_every_kind do
      for {kind, i} <- Enum.with_index(TranscriptSpan.kinds()) do
        TranscriptSpan.new(
          text: "t#{i}",
          kind: kind,
          start_seconds: if(i == 0, do: nil, else: i * 0.5),
          end_seconds: i * 0.5 + 0.25,
          logprob: if(i == 1, do: 0.0, else: -0.125 * i)
        )
      end
    end

    test "round-trips through :erlang.term_to_binary/1, one span of every kind" do
      for span <- one_of_every_kind() do
        assert span == span |> :erlang.term_to_binary() |> :erlang.binary_to_term()
      end
    end

    test "round-trips through JSON, one span of every kind, including logprob 0.0 and nil start" do
      spans = one_of_every_kind()
      # Premise guard: the set actually holds the edge values the name claims.
      assert Enum.any?(spans, &(&1.logprob == 0.0))
      assert Enum.any?(spans, &is_nil(&1.start_seconds))

      for span <- spans do
        assert {:ok, ^span} = span |> Serializer.to_json!() |> Serializer.from_json()
      end
    end

    test ~s(an unknown "kind" string decodes to :other rather than raising) do
      json =
        Jason.encode!(%{
          "__type__" => "ALLM.TranscriptSpan",
          "data" => %{"text" => "x", "kind" => "bogus"}
        })

      assert {:ok, %TranscriptSpan{text: "x", kind: :other}} = Serializer.from_json(json)
    end

    test ~s(a missing or non-string "kind" decodes to :other) do
      for data <- [%{"text" => "x"}, %{"text" => "x", "kind" => 7}] do
        assert %TranscriptSpan{kind: :other} = TranscriptSpan.__from_tagged__(data)
      end
    end
  end
end
