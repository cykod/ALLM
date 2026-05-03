defmodule ALLM.Providers.AnthropicLiveTest do
  @moduledoc """
  Live Anthropic provider smoke tests (`@moduletag :live_anthropic`).

  Excluded by default in `test/test_helper.exs`. Opt-in via:

      ANTHROPIC_API_KEY=sk-ant-... mix test --include live_anthropic \\
        test/allm/providers/anthropic_live_test.exs

  Per Phase 11 design Decision #10, when `ANTHROPIC_API_KEY` is unset the
  entire module is skipped (rather than failing) so opportunistic local
  runs do not fail noisily.

  Phase 11.2 ships TWO rows: plain-text generate + streaming text.
  Phase 11.3 adds the single-tool-call + structured-output rows. The
  session-round-trip row lands in Phase 11.4.
  """
  use ExUnit.Case, async: false

  @moduletag :live_anthropic

  if System.get_env("ANTHROPIC_API_KEY") in [nil, ""] do
    @moduletag :skip
  end

  alias ALLM.Providers.Anthropic

  defp model do
    System.get_env("ALLM_MODEL", "claude-sonnet-4-6")
  end

  test "plain text generate → {:ok, %Response{output_text: \"OK\", finish_reason: :stop}}" do
    engine =
      ALLM.Engine.new(
        adapter: Anthropic,
        model: model(),
        params: %{temperature: 0}
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
    assert String.trim(response.output_text) == "OK"
    assert response.finish_reason == :stop
  end

  test "streaming text → text deltas + :message_completed; collected output is 'OK'" do
    engine =
      ALLM.Engine.new(
        adapter: Anthropic,
        model: model(),
        params: %{temperature: 0}
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
    assert String.trim(response.output_text) == "OK"
    assert response.finish_reason == :stop
  end

  test "single tool call → ChatResult with halted_reason: :completed and weather text" do
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
        adapter: Anthropic,
        model: model(),
        tools: [weather_tool],
        params: %{temperature: 0}
      )

    {:ok, %ALLM.ChatResult{halted_reason: :completed} = result} =
      ALLM.chat(engine, [ALLM.user("What is the weather in Boston? Use the get_weather tool.")])

    assert result.final_response.finish_reason == :stop
    assert is_binary(result.final_response.output_text)
    assert String.contains?(String.downcase(result.final_response.output_text), "sunny")
  end

  test "structured output (tool-forcing) → output_text JSON-decodes to schema map" do
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
        adapter: Anthropic,
        model: model(),
        params: %{temperature: 0}
      )

    request =
      ALLM.request(
        [ALLM.user("Make up a person named Alice who is 30. Reply with JSON only.")],
        max_tokens: 256,
        response_format: ALLM.json_schema("person", schema)
      )

    {:ok, response} = ALLM.generate(engine, request)

    assert response.finish_reason == :stop
    assert response.tool_calls == []
    assert response.metadata.structured_output_tool == true
    assert is_binary(response.output_text)
    assert {:ok, decoded} = Jason.decode(response.output_text)
    assert is_binary(decoded["name"])
    assert is_integer(decoded["age"])
  end
end
