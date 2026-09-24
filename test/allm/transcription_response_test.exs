defmodule ALLM.TranscriptionResponseTest do
  use ExUnit.Case, async: true
  doctest ALLM.TranscriptionResponse

  alias ALLM.{Serializer, TranscriptionResponse, Usage}

  describe "new/1" do
    test "defaults: text \"\", usage %ALLM.Usage{} (never nil)" do
      resp = TranscriptionResponse.new()
      assert resp.text == ""
      assert resp.usage == %Usage{}
      assert resp.metadata == %{}
      assert resp.duration_seconds == nil
      assert resp.language == nil
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

    test ~s(a JSON payload without "text" decodes to "") do
      json =
        Jason.encode!(%{"__type__" => "ALLM.TranscriptionResponse", "data" => %{}})

      assert {:ok, %TranscriptionResponse{text: ""}} = Serializer.from_json(json)
    end
  end
end
