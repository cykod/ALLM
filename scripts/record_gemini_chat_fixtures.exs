# scripts/record_gemini_chat_fixtures.exs
#
# One-time fixture recorder for `test/fixtures/gemini/generate_content/`.
# Runs against the live Google Generative Language API; gated on
# `GEMINI_API_KEY`. Refuses to overwrite anything under
# `test/fixtures/gemini/synthesized/`.
#
# Usage:
#
#     GEMINI_API_KEY=... mix run scripts/record_gemini_chat_fixtures.exs
#
# Optional model override:
#
#     GEMINI_API_KEY=... ALLM_MODEL=gemini-2.5-pro mix run scripts/record_gemini_chat_fixtures.exs
#
# Per Phase 16 design's Decision #11, the canonical model is
# `gemini-2.5-flash` for Phase 16.1 fixtures (fast, cheap baseline).
# Phase 16.5 image fixtures will use `gemini-3.1-flash-image-preview`.
#
# Per CLAUDE.md "Phases shipping synthesized wire fixtures": the
# script is idempotent — files that already exist (the synthesized
# baseline shipped in 16.1) are NEVER overwritten. To re-record,
# delete the target file first.
#
# This script is NOT included in the published Hex package — `mix.exs`
# excludes `scripts/`.

defmodule RecordGeminiChatFixtures do
  @moduledoc false

  @generate_content_dir "test/fixtures/gemini/generate_content"
  @synthesized_dir "test/fixtures/gemini/synthesized"
  @synthesized_marker "Synthesized for Phase"
  @synthesized_marker_legacy "Synthesized"
  @model_default "gemini-2.5-flash"
  @image_model_default "gemini-3.1-flash-image-preview"
  @endpoint "https://generativelanguage.googleapis.com/v1beta"

  def run do
    unless System.get_env("GEMINI_API_KEY") do
      IO.puts(:stderr, "GEMINI_API_KEY not set — refusing to record.")
      System.halt(1)
    end

    File.mkdir_p!(@generate_content_dir)
    model = System.get_env("ALLM_MODEL", @model_default)

    record(:happy_text, model, %{
      "contents" => [
        %{"role" => "user", "parts" => [%{"text" => "Reply with the single word: hello"}]}
      ],
      "generationConfig" => %{"maxOutputTokens" => 64}
    })

    record(:multi_turn, model, %{
      "contents" => [
        %{"role" => "user", "parts" => [%{"text" => "What is 2+2?"}]},
        %{"role" => "model", "parts" => [%{"text" => "It is 4."}]},
        %{"role" => "user", "parts" => [%{"text" => "What is 2+2 again?"}]}
      ],
      "generationConfig" => %{"maxOutputTokens" => 64}
    })

    record(:max_tokens, model, %{
      "contents" => [
        %{"role" => "user", "parts" => [%{"text" => "Write a long lorem ipsum paragraph."}]}
      ],
      "generationConfig" => %{"maxOutputTokens" => 16}
    })

    # ----- Phase 16.3 tool-calling fixtures ---------------------------------
    weather_decl = %{
      "name" => "get_weather",
      "description" => "fetch weather for a city",
      "parameters" => %{
        "type" => "object",
        "properties" => %{"city" => %{"type" => "string"}},
        "required" => ["city"]
      }
    }

    color_decl = %{
      "name" => "set_color",
      "description" => "set the color preference",
      "parameters" => %{
        "type" => "object",
        "properties" => %{"color" => %{"type" => "string"}},
        "required" => ["color"]
      }
    }

    # Single functionCall with STOP — Decision #14 override → :tool_calls.
    record(:tool_call_one, model, %{
      "contents" => [
        %{"role" => "user", "parts" => [%{"text" => "What is the weather in Boston?"}]}
      ],
      "tools" => [%{"functionDeclarations" => [weather_decl]}],
      "toolConfig" => %{
        "functionCallingConfig" => %{"mode" => "ANY", "allowedFunctionNames" => ["get_weather"]}
      },
      "generationConfig" => %{"maxOutputTokens" => 64}
    })

    # Two parallel functionCalls.
    record(:tool_call_parallel, model, %{
      "contents" => [
        %{
          "role" => "user",
          "parts" => [
            %{
              "text" =>
                "Call BOTH get_weather(city='Boston') and set_color(color='red') in this single response."
            }
          ]
        }
      ],
      "tools" => [%{"functionDeclarations" => [weather_decl, color_decl]}],
      "toolConfig" => %{"functionCallingConfig" => %{"mode" => "ANY"}},
      "generationConfig" => %{"maxOutputTokens" => 128}
    })

    # Mixed text + functionCall — model emits a brief preface then the call.
    record(:tool_call_mixed, model, %{
      "contents" => [
        %{
          "role" => "user",
          "parts" => [
            %{
              "text" =>
                "Briefly say what you're about to do, then call get_weather(city='Boston')."
            }
          ]
        }
      ],
      "tools" => [%{"functionDeclarations" => [weather_decl]}],
      "toolConfig" => %{
        "functionCallingConfig" => %{"mode" => "ANY", "allowedFunctionNames" => ["get_weather"]}
      },
      "generationConfig" => %{"maxOutputTokens" => 128}
    })

    # MALFORMED_FUNCTION_CALL — provoke by demanding the call but leaving
    # the schema mismatched. May or may not record cleanly; the
    # synthesized fallback under test/fixtures/gemini/synthesized/ stays
    # the canonical reference.
    record(:malformed_function_call, model, %{
      "contents" => [
        %{
          "role" => "user",
          "parts" => [
            %{"text" => "Call get_weather but pass a number for city."}
          ]
        }
      ],
      "tools" => [
        %{
          "functionDeclarations" => [
            %{
              "name" => "get_weather",
              "description" => "weather",
              "parameters" => %{
                "type" => "object",
                "properties" => %{"city" => %{"type" => "string"}},
                "required" => ["city"]
              }
            }
          ]
        }
      ],
      "toolConfig" => %{"functionCallingConfig" => %{"mode" => "ANY"}},
      "generationConfig" => %{"maxOutputTokens" => 64}
    })

    # ----- Phase 16.5 image-out fixtures (gemini-3.1-flash-image-preview) ---
    image_model = System.get_env("ALLM_IMAGE_MODEL", @image_model_default)

    record_image(:image_single, image_model, %{
      "contents" => [
        %{"role" => "user", "parts" => [%{"text" => "Generate a small abstract image."}]}
      ],
      "generationConfig" => %{
        "responseModalities" => ["TEXT", "IMAGE"],
        "imageConfig" => %{"aspectRatio" => "1:1"}
      }
    })

    record_image(:image_text_and_image, image_model, %{
      "contents" => [
        %{
          "role" => "user",
          "parts" => [
            %{"text" => "Briefly describe the image you're about to make, then make it."}
          ]
        }
      ],
      "generationConfig" => %{
        "responseModalities" => ["TEXT", "IMAGE"],
        "imageConfig" => %{"aspectRatio" => "1:1"}
      }
    })

    record_image(:image_n2, image_model, %{
      "contents" => [
        %{"role" => "user", "parts" => [%{"text" => "Generate two different abstract images."}]}
      ],
      "generationConfig" => %{
        "responseModalities" => ["TEXT", "IMAGE"],
        "imageConfig" => %{"aspectRatio" => "1:1"},
        "candidateCount" => 2
      }
    })

    IO.puts(
      "Done. Recorded fixtures live under #{@generate_content_dir}/ and #{@synthesized_dir}/. Update README's snapshot date."
    )
  end

  # Phase 16.5 image fixtures live under synthesized/ rather than
  # generate_content/ because the synthesized hand-rolled baseline shipped
  # there. The recorder targets the same files for re-record in
  # synthesized/, gated on the same _comment marker check. This is
  # deliberate: the image_* fixtures are stable wire-shapes that tests
  # pin against drift, and re-recording during 16.6 verification
  # overwrites the hand-rolled baselines with actual provider bytes.
  defp record_image(name, model, body) do
    path = Path.join(@synthesized_dir, "#{name}.json")

    cond do
      not File.exists?(path) ->
        do_record(name, model, body, path)

      synthesized_marker?(path) ->
        do_record(name, model, body, path)

      true ->
        IO.puts(
          "- #{path} already recorded (no synth marker) — refusing to overwrite. Delete first to re-record."
        )
    end
  end

  defp record(name, model, body) do
    path = Path.join(@generate_content_dir, "#{name}.json")

    cond do
      not File.exists?(path) ->
        do_record(name, model, body, path)

      synthesized_marker?(path) ->
        do_record(name, model, body, path)

      true ->
        IO.puts("- #{path} already recorded (no synth marker) — refusing to overwrite. Delete first to re-record.")
    end
  end

  defp synthesized_marker?(path) do
    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{"_comment" => c}} when is_binary(c) ->
            String.contains?(c, @synthesized_marker) or
              String.contains?(c, @synthesized_marker_legacy)

          _ ->
            false
        end

      _ ->
        false
    end
  end

  defp do_record(name, model, body, path) do
    key = System.get_env("GEMINI_API_KEY")
    url = @endpoint <> "/models/#{model}:generateContent"

    response =
      Req.post!(
        url,
        headers: [
          {"x-goog-api-key", key},
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

RecordGeminiChatFixtures.run()
