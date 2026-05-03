defmodule ALLM.Providers.GeminiWireTest do
  @moduledoc """
  Phase 16.1 wire-shape pin tests for `ALLM.Providers.Gemini`.

  These tests exercise `to_gemini_request_body/2` directly and assert the
  emitted JSON wire shape against pinned expected values. They guard
  against drift in the request translator across future sub-phases.

  See spec §32.1, §35.7 (Gemini wire-field map in
  `steering/GEMINI_DESIGN.md`).
  """
  use ExUnit.Case, async: true

  alias ALLM.Message
  alias ALLM.Providers.Gemini
  alias ALLM.Request

  defp req(messages, opts \\ []) do
    Request.new(messages, Keyword.merge([model: "gemini-2.5-flash"], opts))
  end

  describe "to_gemini_request_body/2 — text-only request shapes" do
    test "single user message" do
      body =
        Gemini.to_gemini_request_body(
          req([%Message{role: :user, content: "hi"}]),
          []
        )

      assert body == %{
               "contents" => [
                 %{"role" => "user", "parts" => [%{"text" => "hi"}]}
               ]
             }
    end

    test "system + user → systemInstruction at top level, user-only contents" do
      body =
        Gemini.to_gemini_request_body(
          req([
            %Message{role: :system, content: "Be brief."},
            %Message{role: :user, content: "hi"}
          ]),
          []
        )

      assert body == %{
               "systemInstruction" => %{"parts" => [%{"text" => "Be brief."}]},
               "contents" => [
                 %{"role" => "user", "parts" => [%{"text" => "hi"}]}
               ]
             }
    end

    test "multiple system messages joined with \\n\\n into a single systemInstruction" do
      body =
        Gemini.to_gemini_request_body(
          req([
            %Message{role: :system, content: "a"},
            %Message{role: :system, content: "b"},
            %Message{role: :system, content: "c"},
            %Message{role: :user, content: "hi"}
          ]),
          []
        )

      assert body["systemInstruction"] == %{"parts" => [%{"text" => "a\n\nb\n\nc"}]}
      assert length(body["contents"]) == 1
    end

    test "multi-turn user/assistant maps :assistant → \"model\"" do
      body =
        Gemini.to_gemini_request_body(
          req([
            %Message{role: :user, content: "What is 2+2?"},
            %Message{role: :assistant, content: "It is 4."},
            %Message{role: :user, content: "again?"}
          ]),
          []
        )

      assert body["contents"] == [
               %{"role" => "user", "parts" => [%{"text" => "What is 2+2?"}]},
               %{"role" => "model", "parts" => [%{"text" => "It is 4."}]},
               %{"role" => "user", "parts" => [%{"text" => "again?"}]}
             ]
    end
  end

  describe "to_gemini_request_body/2 — generationConfig" do
    test "max_tokens only → maxOutputTokens" do
      body =
        Gemini.to_gemini_request_body(
          req([%Message{role: :user, content: "hi"}], max_tokens: 256),
          []
        )

      assert body["generationConfig"] == %{"maxOutputTokens" => 256}
    end

    test "temperature + top_p (via options)" do
      body =
        Gemini.to_gemini_request_body(
          req([%Message{role: :user, content: "hi"}],
            temperature: 0.7,
            options: %{top_p: 0.9}
          ),
          []
        )

      assert body["generationConfig"] == %{"temperature" => 0.7, "topP" => 0.9}
    end

    test "all four — max_tokens + temperature + top_p + stop (via options)" do
      body =
        Gemini.to_gemini_request_body(
          req([%Message{role: :user, content: "hi"}],
            max_tokens: 100,
            temperature: 1.0,
            options: %{top_p: 0.95, stop: ["END"]}
          ),
          []
        )

      assert body["generationConfig"] == %{
               "maxOutputTokens" => 100,
               "temperature" => 1.0,
               "topP" => 0.95,
               "stopSequences" => ["END"]
             }
    end

    test "no params → no generationConfig key" do
      body =
        Gemini.to_gemini_request_body(
          req([%Message{role: :user, content: "hi"}]),
          []
        )

      refute Map.has_key?(body, "generationConfig")
    end

    test "response_format :json_object → responseMimeType only" do
      body =
        Gemini.to_gemini_request_body(
          req([%Message{role: :user, content: "x"}],
            response_format: %{type: :json_object}
          ),
          []
        )

      assert body["generationConfig"] == %{"responseMimeType" => "application/json"}
    end

    test "response_format :json_schema → responseMimeType + responseSchema" do
      schema = %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}}

      body =
        Gemini.to_gemini_request_body(
          req([%Message{role: :user, content: "x"}],
            response_format: %{type: :json_schema, name: "person", schema: schema}
          ),
          []
        )

      assert body["generationConfig"] == %{
               "responseMimeType" => "application/json",
               "responseSchema" => schema
             }
    end
  end
end
