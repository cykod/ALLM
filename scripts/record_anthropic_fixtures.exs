# scripts/record_anthropic_fixtures.exs
#
# One-time fixture recorder for `test/fixtures/anthropic/messages/`. Runs
# against the live Anthropic Messages API; gated on `ANTHROPIC_API_KEY`.
# Refuses to overwrite anything under `test/fixtures/anthropic/synthesized/`.
#
# Usage:
#
#     ANTHROPIC_API_KEY=sk-ant-... mix run scripts/record_anthropic_fixtures.exs
#
# Optional model override:
#
#     ANTHROPIC_API_KEY=sk-ant-... ALLM_MODEL=claude-haiku-4-5 mix run scripts/record_anthropic_fixtures.exs
#
# Per Phase 11 design Decision #11, the canonical model is
# `claude-sonnet-4-6` (spec §steering reference). Approximate cost:
# ~$3/M input + ~$15/M output for Sonnet 4.6 (verify against the current
# Anthropic pricing page at recording time).
#
# This script is NOT included in the published Hex package — `mix.exs:60`
# excludes `scripts/`.

defmodule RecordAnthropicFixtures do
  @moduledoc false

  @messages_dir "test/fixtures/anthropic/messages"
  @model_default "claude-sonnet-4-6"

  def run do
    unless System.get_env("ANTHROPIC_API_KEY") do
      IO.puts(:stderr, "ANTHROPIC_API_KEY not set — refusing to record.")
      System.halt(1)
    end

    File.mkdir_p!(@messages_dir)
    model = System.get_env("ALLM_MODEL", @model_default)

    record(:happy_text, model, %{
      "model" => model,
      "max_tokens" => 64,
      "messages" => [%{"role" => "user", "content" => "Reply with the single word: hello"}]
    })

    record(:single_tool_use, model, %{
      "model" => model,
      "max_tokens" => 256,
      "tools" => [
        %{
          "name" => "get_weather",
          "description" => "Get current weather by city.",
          "input_schema" => %{
            "type" => "object",
            "properties" => %{"city" => %{"type" => "string"}},
            "required" => ["city"]
          }
        }
      ],
      "tool_choice" => %{"type" => "tool", "name" => "get_weather"},
      "messages" => [%{"role" => "user", "content" => "What is the weather in Boston?"}]
    })

    record(:parallel_tool_use, model, %{
      "model" => model,
      "max_tokens" => 512,
      "tools" => [
        %{
          "name" => "get_weather",
          "description" => "Get current weather by city.",
          "input_schema" => %{
            "type" => "object",
            "properties" => %{"city" => %{"type" => "string"}},
            "required" => ["city"]
          }
        }
      ],
      "messages" => [
        %{
          "role" => "user",
          "content" => "Call get_weather twice in parallel — once for Boston, once for Seattle."
        }
      ]
    })

    record_stream(:happy_text, model, %{
      "model" => model,
      "max_tokens" => 64,
      "stream" => true,
      "messages" => [%{"role" => "user", "content" => "Reply with the single word: hello"}]
    })

    # Phase 11.3 — structured output via tool-forcing. Records the
    # `respond_with_json_person` synthetic tool call response (single-pass).
    person_schema = %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string"},
        "age" => %{"type" => "integer"}
      },
      "required" => ["name", "age"]
    }

    record(:structured_output, model, %{
      "model" => model,
      "max_tokens" => 256,
      "tools" => [
        %{
          "name" => "respond_with_json_person",
          "description" => "Return the final result as a JSON object matching the schema.",
          "input_schema" => person_schema
        }
      ],
      "tool_choice" => %{"type" => "tool", "name" => "respond_with_json_person"},
      "messages" => [
        %{
          "role" => "user",
          "content" => "Make up a person named Alice who is 30. Reply via the tool."
        }
      ]
    })

    record_stream(:structured_output_stream, model, %{
      "model" => model,
      "max_tokens" => 256,
      "stream" => true,
      "tools" => [
        %{
          "name" => "respond_with_json_person",
          "description" => "Return the final result as a JSON object matching the schema.",
          "input_schema" => person_schema
        }
      ],
      "tool_choice" => %{"type" => "tool", "name" => "respond_with_json_person"},
      "messages" => [
        %{
          "role" => "user",
          "content" => "Make up a person named Alice who is 30. Reply via the tool."
        }
      ]
    })

    record_stream(:tool_use_deltas, model, %{
      "model" => model,
      "max_tokens" => 256,
      "stream" => true,
      "tools" => [
        %{
          "name" => "get_weather",
          "description" => "Get current weather by city.",
          "input_schema" => %{
            "type" => "object",
            "properties" => %{"city" => %{"type" => "string"}},
            "required" => ["city"]
          }
        }
      ],
      "tool_choice" => %{"type" => "tool", "name" => "get_weather"},
      "messages" => [%{"role" => "user", "content" => "What is the weather in Boston?"}]
    })

    IO.puts("Done. Recorded fixtures live under #{@messages_dir}/. Update README's snapshot date.")
  end

  # Record a streaming SSE fixture by issuing a real streaming request and
  # capturing the raw chunked bytes off the wire. Per Phase 11 design
  # Decision #11, recorded SSE fixtures live under messages/ alongside
  # the JSON fixtures.
  defp record_stream(name, _model, body) do
    path = Path.join(@messages_dir, "#{name}.sse")

    if File.exists?(path) do
      IO.puts("- #{path} already exists — refusing to overwrite. Delete first to re-record.")
    else
      key = System.get_env("ANTHROPIC_API_KEY")

      acc = :ets.new(:sse_acc, [:set, :public])
      :ets.insert(acc, {:bytes, ""})

      Req.post!(
        "https://api.anthropic.com/v1/messages",
        headers: [
          {"x-api-key", key},
          {"anthropic-version", "2023-06-01"},
          {"content-type", "application/json"}
        ],
        json: body,
        into: fn {:data, chunk}, {req, resp} ->
          [{:bytes, current}] = :ets.lookup(acc, :bytes)
          :ets.insert(acc, {:bytes, current <> chunk})
          {:cont, {req, resp}}
        end
      )

      [{:bytes, bytes}] = :ets.lookup(acc, :bytes)
      :ets.delete(acc)

      File.write!(path, bytes)
      IO.puts("✓ recorded #{path} (#{byte_size(bytes)} bytes)")
    end
  end

  defp record(name, _model, body) do
    path = Path.join(@messages_dir, "#{name}.json")

    if File.exists?(path) do
      IO.puts("- #{path} already exists — refusing to overwrite. Delete first to re-record.")
    else
      key = System.get_env("ANTHROPIC_API_KEY")

      response =
        Req.post!(
          "https://api.anthropic.com/v1/messages",
          headers: [
            {"x-api-key", key},
            {"anthropic-version", "2023-06-01"},
            {"content-type", "application/json"}
          ],
          json: body
        )

      case response.status do
        200 ->
          File.write!(path, Jason.encode!(response.body, pretty: true) <> "\n")
          IO.puts("✓ recorded #{path}")

        other ->
          IO.puts(:stderr, "✗ #{name} failed: HTTP #{other} — #{inspect(response.body)}")
      end
    end
  end

  @doc false
  def refuse_synthesized_overwrite! do
    # Defensive — reads happen via record/3 which only writes under @messages_dir.
    # Document the contract so anyone editing this file knows it's intentional.
    :ok
  end
end

RecordAnthropicFixtures.run()
