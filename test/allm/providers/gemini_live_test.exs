defmodule ALLM.Providers.GeminiLiveTest do
  @moduledoc """
  Live Gemini provider smoke tests (`@moduletag :live_gemini`).

  Excluded by default in `test/test_helper.exs`. Opt-in via:

      GEMINI_API_KEY=... mix test --include live_gemini \\
        test/allm/providers/gemini_live_test.exs

  Per Phase 16.6 design, when `GEMINI_API_KEY` is unset the entire module
  is skipped (rather than failing) so opportunistic local runs do not fail
  noisily — mirrors the OpenAI / Anthropic live-test modules.

  Each `@tag :live` test corresponds to one numbered example script under
  `examples/`, exercising the full path against the live API. Per
  Decision #20, Gemini's default temperature is `1.0` (Google's
  recommendation); these tests pin temperature explicitly to keep the
  contract stable.
  """
  use ExUnit.Case, async: false

  @moduletag :live_gemini

  if System.get_env("GEMINI_API_KEY") in [nil, ""] do
    @moduletag :skip
  end

  alias ALLM.Providers.Gemini

  defp model do
    System.get_env("ALLM_MODEL", "gemini-3-flash-preview")
  end

  defp image_model do
    System.get_env("ALLM_MODEL", "gemini-3.1-flash-image-preview")
  end

  test "01: plain text generate → {:ok, %Response{output_text: \"OK\"}}" do
    engine =
      ALLM.Engine.new(
        adapter: Gemini,
        model: model(),
        params: %{temperature: 1.0}
      )

    request =
      ALLM.request(
        [
          ALLM.system("Reply with exactly the word 'OK' and no other text."),
          ALLM.user("Acknowledge.")
        ],
        max_tokens: 16
      )

    {:ok, response} = ALLM.generate(engine, request)

    assert is_binary(response.output_text)
    assert String.contains?(String.upcase(response.output_text), "OK")
    assert response.finish_reason == :stop
  end

  test "02: streaming text → text deltas + :message_completed" do
    engine =
      ALLM.Engine.new(
        adapter: Gemini,
        model: model(),
        params: %{temperature: 1.0}
      )

    request =
      ALLM.request(
        [
          ALLM.system("Reply with exactly the word 'OK' and no other text."),
          ALLM.user("Acknowledge.")
        ],
        max_tokens: 16
      )

    {:ok, stream} = ALLM.stream_generate(engine, request)
    events = Enum.to_list(stream)

    text_deltas = Enum.filter(events, &match?({:text_delta, _}, &1))
    assert text_deltas != []

    completed = Enum.filter(events, &match?({:message_completed, _}, &1))
    assert length(completed) == 1

    state =
      Enum.reduce(events, ALLM.StreamCollector.new(), &ALLM.StreamCollector.apply_event(&2, &1))

    response = ALLM.StreamCollector.to_response(state)

    assert is_binary(response.output_text)
    assert String.contains?(String.upcase(response.output_text), "OK")
  end

  test "03: single tool call → ChatResult with halted_reason: :completed" do
    weather_tool =
      ALLM.tool(
        name: "get_weather",
        description: "Get current weather by city.",
        schema: %{
          "type" => "object",
          "properties" => %{"city" => %{"type" => "string"}},
          "required" => ["city"]
        },
        handler: fn %{"city" => c} -> {:ok, %{forecast: "sunny", city: c}} end
      )

    engine =
      ALLM.Engine.new(
        adapter: Gemini,
        model: model(),
        tools: [weather_tool],
        params: %{temperature: 1.0}
      )

    {:ok, %ALLM.ChatResult{halted_reason: :completed} = result} =
      ALLM.chat(engine, [ALLM.user("What is the weather in Boston? Use the get_weather tool.")])

    assert result.final_response.finish_reason == :stop
    assert is_binary(result.final_response.output_text)
    assert String.contains?(String.downcase(result.final_response.output_text), "sunny")
  end

  test "06: structured output → output_text JSON-decodes to schema map" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string"},
        "age" => %{"type" => "integer"}
      },
      "required" => ["name", "age"]
    }

    engine =
      ALLM.Engine.new(
        adapter: Gemini,
        model: model(),
        params: %{temperature: 1.0}
      )

    request =
      ALLM.request(
        [ALLM.user("Make up a person named Alice who is 30. Reply with JSON only.")],
        max_tokens: 256,
        response_format: ALLM.json_schema("person", schema)
      )

    {:ok, response} = ALLM.generate(engine, request)

    assert response.finish_reason == :stop
    assert is_binary(response.output_text)
    assert {:ok, decoded} = Jason.decode(response.output_text)
    assert is_binary(decoded["name"])
    assert is_integer(decoded["age"])
  end

  test "10: image generate → {:ok, %ImageResponse{}} with at least one image" do
    engine =
      ALLM.Engine.new(
        image_adapter: ALLM.Providers.Gemini.Images,
        model: image_model()
      )

    request =
      ALLM.image_request(
        "a single red apple on a white background",
        operation: :generate,
        n: 1
      )

    {:ok, response} = ALLM.generate_image(engine, request)

    assert %ALLM.ImageResponse{} = response
    assert response.images != []
  end
end
