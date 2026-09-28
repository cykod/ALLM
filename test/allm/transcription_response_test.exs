defmodule ALLM.TranscriptionResponseTest do
  use ExUnit.Case, async: true
  doctest ALLM.TranscriptionResponse

  alias ALLM.{Serializer, TranscriptionResponse, TranscriptSpan, Usage}

  describe "new/1" do
    test "defaults: text \"\", usage %ALLM.Usage{} (never nil)" do
      resp = TranscriptionResponse.new()
      assert resp.text == ""
      assert resp.usage == %Usage{}
      assert resp.metadata == %{}
      assert resp.duration_seconds == nil
      assert resp.language == nil
      assert resp.spans == nil
    end

    test "an unknown key raises KeyError" do
      assert_raise KeyError, fn -> TranscriptionResponse.new(bogus: 1) end
    end
  end

  describe "serializability" do
    defp full_response do
      TranscriptionResponse.new(
        text: "The quick brown fox.",
        language: "en",
        duration_seconds: 2.78,
        id: "tr-1",
        request_id: "req-1",
        model: "gpt-4o-mini-transcribe",
        provider: :openai,
        usage: %Usage{input_tokens: 27},
        raw: %{"text" => "The quick brown fox."},
        metadata: %{"trace" => "abc"}
      )
    end

    test "round-trips through :erlang.term_to_binary/1" do
      resp = full_response()
      assert resp == resp |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end

    test "round-trips through JSON; provider stays an atom, usage a struct" do
      resp = full_response()
      assert {:ok, decoded} = resp |> Serializer.to_json!() |> Serializer.from_json()
      assert decoded.provider == :openai
      assert %Usage{input_tokens: 27} = decoded.usage
      assert decoded.duration_seconds == 2.78
      assert decoded == resp
    end

    test ~s("usage": null, or a tagged non-Usage value, decodes to %Usage{}) do
      for usage <- [nil, %{"__type__" => "ALLM.Message", "data" => %{"role" => "user"}}] do
        json =
          Jason.encode!(%{
            "__type__" => "ALLM.TranscriptionResponse",
            "data" => %{"usage" => usage, "metadata" => %{}}
          })

        assert {:ok, %TranscriptionResponse{usage: %Usage{}}} = Serializer.from_json(json)
      end
    end

    test "an untagged usage value passes through verbatim" do
      json =
        Jason.encode!(%{
          "__type__" => "ALLM.TranscriptionResponse",
          "data" => %{"usage" => %{"input_tokens" => 3}}
        })

      assert {:ok, %TranscriptionResponse{usage: %{"input_tokens" => 3}}} =
               Serializer.from_json(json)
    end

    test ~s(a JSON payload without "usage" decodes to %Usage{}, not nil) do
      json =
        Jason.encode!(%{
          "__type__" => "ALLM.TranscriptionResponse",
          "data" => %{"text" => "hi", "metadata" => %{}}
        })

      assert {:ok, %TranscriptionResponse{usage: %Usage{}, text: "hi"}} =
               Serializer.from_json(json)
    end

    test "round-trips through JSON with spans: nil" do
      resp = %{full_response() | spans: nil}
      assert {:ok, ^resp} = resp |> Serializer.to_json!() |> Serializer.from_json()
    end

    test "round-trips through JSON with a two-span list, hydrated to %TranscriptSpan{}" do
      spans = [
        TranscriptSpan.new(text: "The", kind: :word, start_seconds: 0.0, end_seconds: 0.25),
        TranscriptSpan.new(text: " ", kind: :spacing, logprob: -0.5)
      ]

      resp = %{full_response() | spans: spans}
      assert {:ok, decoded} = resp |> Serializer.to_json!() |> Serializer.from_json()
      assert [%TranscriptSpan{kind: :word}, %TranscriptSpan{kind: :spacing}] = decoded.spans
      assert decoded == resp
    end

    test ~s(a JSON payload without "text" decodes to "") do
      json =
        Jason.encode!(%{"__type__" => "ALLM.TranscriptionResponse", "data" => %{}})

      assert {:ok, %TranscriptionResponse{text: ""}} = Serializer.from_json(json)
    end

    test ~s(a malformed persisted "spans" passes through instead of raising out of from_json/1) do
      for bad <- [%{}, "oops", %{"a" => 1}] do
        json =
          Jason.encode!(%{
            "__type__" => "ALLM.TranscriptionResponse",
            "data" => %{"text" => "a", "spans" => bad}
          })

        assert {:ok, %TranscriptionResponse{spans: ^bad} = resp} = Serializer.from_json(json)
        assert TranscriptionResponse.mean_logprob(resp) == nil
      end
    end
  end

  describe "mean_logprob/1" do
    defp span(kind, logprob), do: TranscriptSpan.new(text: "x", kind: kind, logprob: logprob)

    defp mean(spans),
      do: TranscriptionResponse.mean_logprob(TranscriptionResponse.new(spans: spans))

    test "nil spans -> nil" do
      assert TranscriptionResponse.mean_logprob(TranscriptionResponse.new()) == nil
    end

    test "[] -> nil" do
      assert mean([]) == nil
    end

    test "only :spacing and :audio_event spans -> nil" do
      assert mean([span(:spacing, -0.5), span(:audio_event, -0.25)]) == nil
    end

    test "spacing is excluded: [word -0.2, spacing -0.2, word -0.4] -> -0.3, not -0.2667" do
      assert_in_delta mean([span(:word, -0.2), span(:spacing, -0.2), span(:word, -0.4)]),
                      -0.3,
                      1.0e-9
    end

    test ":token spans are counted" do
      assert mean([span(:token, -1.0), span(:token, -0.5)]) == -0.75
    end

    test "a span with logprob: nil is skipped, not counted as zero" do
      assert mean([span(:word, -1.0), span(:word, nil)]) == -1.0
      assert mean([span(:word, nil)]) == nil
    end

    test ":other spans are excluded" do
      assert mean([span(:word, -1.0), span(:other, -3.0)]) == -1.0
    end
  end
end
