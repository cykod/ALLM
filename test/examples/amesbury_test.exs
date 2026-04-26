defmodule ALLM.Test.Examples.AmesburyTest do
  @moduledoc """
  Phase 12.2 case-study translation of `steering/examples/amesury_example.md`.

  Each `describe` block translates one of the case study's "After" snippets,
  driven against `ALLM.Providers.Fake` (Decision #10) so the suite is
  deterministic, network-free, and key-free.

  ## Coverage

    * `### 1. Simple structured-output completion` — translated.
    * `### 2. HTML extraction convenience` — translated.
    * `### 3. Vision (image analysis)` — skipped (vision deferred to v0.3
      per §33; Decision #9).
    * `### 4. Tool calling (NarrativeGenerator)` — translated (the two-pass
      structured-output pattern using `Engine.put_tools/2` +
      `Engine.put_context/3`).
    * `### 5. Manual tool orchestration (new capability)` — translated.
    * `### 6. Streaming (new capability)` — translated as a sanity sweep
      of `ALLM.stream/3` events.
    * `### 7. Provider portability` — covered by the unllmtd translation
      (Decision #10); not duplicated here.
    * `### 8. Testing` — implicit (this file IS the testing pattern).
  """

  use ExUnit.Case, async: true

  import ALLM.Test.ExampleFixtures

  alias ALLM.{ChatResult, Engine, Response, Session, Thread}

  describe "amesury_example.md / 1. Simple structured-output completion" do
    setup do
      schema = %{
        type: "object",
        properties: %{name: %{type: "string"}},
        required: ["name"]
      }

      payload = Jason.encode!(%{name: "Public Works Committee"})

      engine =
        engine(text_response(payload),
          engine_opts: [model: "gpt-5-mini", params: %{temperature: 0.0}]
        )

      {:ok, engine: engine, schema: schema, payload: payload}
    end

    test "ALLM.generate/3 with response_format JSON-schema returns decodable output_text",
         %{engine: engine, schema: schema, payload: payload} do
      request =
        ALLM.request(
          [ALLM.user("Extract committee fields from the agenda.")],
          response_format: ALLM.json_schema("committee", schema)
        )

      assert {:ok, %Response{output_text: ^payload, finish_reason: :stop}} =
               ALLM.generate(engine, request)

      assert {:ok, %{"name" => "Public Works Committee"}} = Jason.decode(payload)
    end
  end

  describe "amesury_example.md / 2. HTML extraction convenience" do
    test "ALLM.system + ALLM.user collapse the extract/4 entry point into one request" do
      payload = Jason.encode!(%{title: "Ordinance 2024-12"})
      eng = engine(text_response(payload))

      messages = [
        ALLM.system("You are an extraction assistant."),
        ALLM.user("""
        Extract the ordinance.

        HTML Content:
        <html><body><h1>Ordinance 2024-12</h1></body></html>
        """)
      ]

      request =
        ALLM.request(messages,
          response_format: ALLM.json_schema("ordinance", %{type: "object"})
        )

      assert {:ok, %Response{output_text: ^payload}} = ALLM.generate(eng, request)
    end
  end

  # skipped: vision deferred to v0.3 per §33; case study heading
  # "### 3. Vision (image analysis)" — Decision #9.

  describe "amesury_example.md / 4. Tool calling (NarrativeGenerator)" do
    test "two explicit ALLM.chat/3 calls — first with tools, second with response_format and tools: []" do
      # Multi-script: turn 1 emits a tool call to "get_full_document", turn 2
      # emits the assistant's final text. Then a second ALLM.chat/3 call
      # (against a fresh engine) emits the structured JSON pass.
      doc_lookup = %{"doc-staff-report" => "Staff report body."}

      tool =
        ALLM.tool(
          name: "get_full_document",
          description: "Retrieve the full extracted text of a project document.",
          schema: %{
            type: "object",
            properties: %{document_id: %{type: "string"}},
            required: ["document_id"]
          },
          handler: fn %{"document_id" => id}, opts ->
            # Case study models opts[:docs_read_agent] directly, but ALLM
            # threads engine context through opts[:context] (a map) — the
            # ergonomic gap is documented in the report.
            agent = opts[:context][:docs_read_agent]
            Agent.update(agent, &[id | &1])
            {:ok, Map.fetch!(doc_lookup, id)}
          end
        )

      {:ok, docs_agent} = Agent.start_link(fn -> [] end)

      tool_loop_engine =
        engine_with_scripts([
          [
            {:tool_call,
             id: "tc_1",
             name: "get_full_document",
             arguments: %{"document_id" => "doc-staff-report"}},
            {:finish, :tool_calls}
          ],
          text_response("I have read the staff report.")
        ])
        |> Engine.put_tools([tool])
        |> Engine.put_context(:docs_read_agent, docs_agent)

      messages = [
        ALLM.system("Summarize the staff report."),
        ALLM.user("What does the staff report say?")
      ]

      assert {:ok, %ChatResult{thread: thread1, halted_reason: :completed}} =
               ALLM.chat(tool_loop_engine, messages, max_turns: 5)

      assert ["doc-staff-report"] = Agent.get(docs_agent, & &1)

      # Second pass: same Thread, response_format set, tools disabled. The
      # case study models this as "two explicit ALLM.chat/3 calls over the
      # same Thread" — we pass a fresh Fake engine because the tool-loop
      # engine's script cursor is already exhausted.
      structured_payload =
        Jason.encode!(%{
          "rich_description" => "...",
          "summary" => "Staff approved.",
          "preview" => "Staff approved",
          "key_facts" => []
        })

      structured_engine = engine(text_response(structured_payload))

      followup =
        Thread.add_user(thread1, "Now provide your final structured response.")

      assert {:ok, %ChatResult{final_response: %Response{output_text: ^structured_payload}}} =
               ALLM.chat(structured_engine, followup,
                 response_format: ALLM.json_schema("narrative", %{type: "object"}),
                 tools: []
               )

      assert {:ok, %{"summary" => "Staff approved."}} = Jason.decode(structured_payload)

      Agent.stop(docs_agent)
    end
  end

  describe "amesury_example.md / 5. Manual tool orchestration (new capability)" do
    test "Session.start mode: :manual halts on tool calls; submit_tool_result + step completes" do
      # Two-call multi-script: first call emits the tool call, second call
      # (after submit_tool_result) emits the final text. The tool list is
      # empty on the engine — :manual mode halts before any executor runs.
      eng =
        engine_with_scripts([
          [
            {:tool_call, id: "tc_1", name: "weather", arguments: %{"city" => "Amesbury"}},
            {:finish, :tool_calls}
          ],
          text_response("Forecast retrieved.")
        ])

      {:ok, session, %ChatResult{halted_reason: :manual_tool_calls}} =
        Session.start(eng, [ALLM.user("What's the weather?")], mode: :manual)

      assert session.status == :awaiting_tools
      assert [tool_call] = session.pending_tool_calls
      assert tool_call.id == "tc_1"

      session = Session.submit_tool_result(session, "tc_1", %{forecast: "sunny"})

      assert {:ok, %Session{status: :completed} = final, %ChatResult{}} =
               Session.continue(eng, session, nil)

      assert final.status == :completed
    end
  end

  describe "amesury_example.md / 6. Streaming (new capability)" do
    test "ALLM.stream/3 yields a :chat_completed event terminating the loop" do
      eng = engine(text_response("Hello from Amesbury."))

      assert {:ok, stream} = ALLM.stream(eng, [ALLM.user("hi")])
      events = Enum.to_list(stream)

      assert Enum.count(events, &match?({:chat_completed, _}, &1)) == 1
      assert Enum.any?(events, &match?({:text_delta, _}, &1))
    end
  end
end
