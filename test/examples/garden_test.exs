defmodule ALLM.Test.Examples.GardenTest do
  @moduledoc """
  Phase 12.2 case-study translation of `steering/examples/garden_example.md`.

  ## Coverage

    * `## 1. The behaviour layer: LLMService` — `### After` snippet
      translated as Engine-with-Fake construction.
    * `## 2. The OpenAI adapter: OpenAIService` — `### After` snippet
      translated as `ALLM.generate/3` with `response_format`.
    * `## 7. Test mock: LLMServiceMock` — `### After` snippet translated
      directly (this IS the Fake-driven testing pattern).
    * `## 8.1 Streaming extraction into Absinthe subscriptions` —
      translated as `ALLM.stream_generate/3` event sweep.
    * `## 8.2 Tool calling for multi-step extraction + validation` —
      translated as `ALLM.chat/3` with one tool.
    * `## 3. Config and API keys` — covered by `ALLM.Keys` unit tests
      under `test/allm/keys_test.exs`; out of scope for this translation.
    * `## 5. Error handling and retries`, `## 6. Telemetry`,
      `## 8.3 Stateful sessions`, `## 8.4 Provider hedging` — covered by
      other translations (meal session, unllmtd multi-provider) and unit
      tests; not duplicated here.
  """

  use ExUnit.Case, async: true

  import ALLM.Test.ExampleFixtures

  alias ALLM.{ChatResult, Engine, Response}
  alias ALLM.Providers.Fake

  describe "garden_example.md / 1. The behaviour layer: LLMService — After (engine construction)" do
    test "Engine.new with Fake adapter and adapter_opts script round-trips intact" do
      eng =
        Engine.new(
          adapter: Fake,
          adapter_opts: [
            script: [
              {:text, ~s({"english_name":"Tomato"})},
              {:finish, :stop}
            ]
          ]
        )

      assert eng.adapter == Fake
      assert eng.adapter_opts[:script] != nil
      # Engine round-trips through term_to_binary cleanly (no PIDs / refs /
      # API keys leak in) — Phase 8 invariant.
      assert eng == eng |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end
  end

  # skipped: garden_example.md "## 3. Config and API keys" — covered by
  # ALLM.Keys unit tests under test/allm/keys_test.exs; out of scope for
  # this case-study translation per Decision #9 idiom (inline comment, not
  # @tag :skip).

  describe "garden_example.md / 2. The OpenAI adapter: OpenAIService — After (generate with structured output)" do
    test "ALLM.generate/3 with response_format yields decodable seed-packet JSON" do
      payload = Jason.encode!(%{"english_name" => "Tomato", "plant_type" => "annual"})

      eng = engine(text_response(payload))

      schema = %{
        type: "object",
        properties: %{
          english_name: %{type: "string"},
          plant_type: %{type: "string"}
        },
        required: ["english_name", "plant_type"]
      }

      request =
        ALLM.request(
          [
            ALLM.system("Extract seed packet fields."),
            ALLM.user("Tomato || Annual || Full sun")
          ],
          response_format: ALLM.json_schema("seed_packet", schema)
        )

      assert {:ok, %Response{output_text: ^payload, finish_reason: :stop}} =
               ALLM.generate(eng, request)

      assert {:ok, %{"english_name" => "Tomato", "plant_type" => "annual"}} =
               Jason.decode(payload)
    end
  end

  describe "garden_example.md / 7. Test mock: LLMServiceMock — After (per-test Fake engines)" do
    test "happy-path engine plus rate-limit engine plus timeout engine fold into Response.error" do
      # Mirrors the case study's three-engine snippet — happy path, rate
      # limit, and timeout — using the §31 / Phase 5 vocabulary.
      #
      # Note on error-tag form: the case study writes
      # `{:error, {:adapter_error, :rate_limited}}` (tagged tuple); the
      # canonical form in ALLM is the bare reason atom `{:error, :rate_limited}`,
      # which Fake's Script.interpret/1 maps to
      # `%AdapterError{reason: :rate_limited}` (see
      # `lib/allm/providers/fake/script.ex:319-323`). Wire tests under
      # `test/allm/providers/{openai,anthropic}_wire_test.exs` assert on
      # `%AdapterError{reason: :rate_limited}` — this test mirrors that
      # canonical shape.
      #
      # Note on timeout: the case study uses `[{:sleep, 35_000}, ...]` with
      # `request_timeout: 1_000` to provoke a real timeout. ALLM's Fake
      # adapter doesn't enforce request-timeouts on scripted entries, so the
      # `:timeout` reason is materialized via the `{:error, :timeout}` script
      # form — which produces the same `%AdapterError{reason: :timeout}` an
      # actual `request_timeout` exceedance would surface. The end-state
      # contract (the error folding into `Response.metadata.error`) is what
      # the case study's test mock actually verifies.
      happy =
        Engine.new(
          adapter: Fake,
          adapter_opts: [
            script: [{:text, ~s({"english_name":"Tomato"})}, {:finish, :stop}]
          ]
        )

      rate_limited =
        Engine.new(
          adapter: Fake,
          adapter_opts: [script: [{:error, :rate_limited}]]
        )

      timed_out =
        Engine.new(
          adapter: Fake,
          adapter_opts: [script: [{:error, :timeout}]]
        )

      assert {:ok, %Response{output_text: text}} =
               ALLM.generate(happy, ALLM.request([ALLM.user("ocr")]))

      assert {:ok, %{"english_name" => "Tomato"}} = Jason.decode(text)

      # Mid-stream errors fold into Response (CLAUDE.md invariant).
      assert {:ok, %Response{finish_reason: :error, metadata: rl_meta}} =
               ALLM.generate(rate_limited, ALLM.request([ALLM.user("ocr")]))

      assert rl_meta.error.reason == :rate_limited

      assert {:ok, %Response{finish_reason: :error, metadata: to_meta}} =
               ALLM.generate(timed_out, ALLM.request([ALLM.user("ocr")]))

      assert to_meta.error.reason == :timeout
    end
  end

  describe "garden_example.md / 8.1 Streaming extraction into Absinthe subscriptions" do
    test "ALLM.stream_generate/3 emits text deltas plus a terminal :message_completed" do
      eng = engine(text_response(~s({"english_name":"Tomato"})))

      assert {:ok, stream} =
               ALLM.stream_generate(eng, ALLM.request([ALLM.user("ocr")]))

      events = Enum.to_list(stream)
      tags = Enum.map(events, &elem(&1, 0))

      assert :text_delta in tags
      assert :message_completed in tags
    end
  end

  describe "garden_example.md / 8.2 Tool calling for multi-step extraction + validation" do
    test "ALLM.tool/1 + Engine.put_tool/2 + ALLM.chat/3 with mode :auto runs the lookup tool" do
      color_tool =
        ALLM.tool(
          name: "lookup_plant_colors",
          description: "Return canonical border/fill hex colors for a plant.",
          schema: %{
            type: "object",
            properties: %{
              plant_type: %{type: "string"},
              english_name: %{type: "string"}
            },
            required: ["plant_type", "english_name"]
          },
          handler: fn _args ->
            {:ok, %{border_color: "#2e7d32", fill_color: "#a5d6a7"}}
          end
        )

      base =
        engine_with_scripts([
          [
            {:tool_call,
             id: "tc_1",
             name: "lookup_plant_colors",
             arguments: %{"plant_type" => "annual", "english_name" => "Tomato"}},
            {:finish, :tool_calls}
          ],
          text_response(
            Jason.encode!(%{
              "english_name" => "Tomato",
              "border_color" => "#2e7d32",
              "fill_color" => "#a5d6a7"
            })
          )
        ])

      eng = Engine.put_tool(base, color_tool)

      assert {:ok, %ChatResult{halted_reason: :completed, thread: thread}} =
               ALLM.chat(eng, [
                 ALLM.system("Extract a seed packet."),
                 ALLM.user("Tomato")
               ])

      # The thread should contain the tool result — proof the loop ran.
      assert Enum.any?(thread.messages, fn
               %ALLM.Message{role: :tool} -> true
               _ -> false
             end)
    end
  end
end
