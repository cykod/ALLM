defmodule ALLM.Test.Examples.UnllmtdTest do
  @moduledoc """
  Phase 12.2 case-study translation of `steering/examples/unllmtd_example.md`.

  Per Decision #10 this is the **load-bearing multi-provider proof**. We
  construct two `ALLM.Providers.Fake`-backed engines labeled "openai" and
  "anthropic" (differing only in `:adapter_opts`), demonstrating the
  engine-construction pattern the case study advocates without invoking
  real OpenAI / Anthropic adapters (those are exercised by recorded-fixture
  wire tests under `test/allm/providers/`).

  ## Why two Fake engines, not real OpenAI + Anthropic

  Fake is the deterministic, network-free vehicle for proving Layer C
  call sites compile and behave. The translation's job is to prove the
  *engine selection pattern* works against the public API, not to revalidate
  adapter wire shapes.

  ## Coverage

    * `## Side-by-side 1: The low-level LLMAdapter.complete/3` — `### After`
      snippet translated as `Engines.orchestrator/2`-style helper construction
      against two Fake engines.
    * `## Side-by-side 2: run_llm_loop/5 orchestration in agent_generator.ex`
      — `### After` snippet translated as `ALLM.chat/3` mode `:auto`.
    * `## Side-by-side 2 (continued)` — manual-mode halt + tool result
      submission via `Session.submit_tool_result/3`.
    * `## Side-by-side 2 (continued)` — ask-user halt + follow-up turn
      (modeled as the synthetic `ask_user` tool per Decision #9).
    * `## Side-by-side 3: user-LLM-node Executor` — translated as
      `ALLM.chat/3` with tools-from-node-ids equivalent.
    * `## Side-by-side 4: Streaming` — translated as `ALLM.stream/3`
      event sweep.
    * `## What ALLM would need that isn't in v0.2` — out of scope per §33.
  """

  use ExUnit.Case, async: true

  import ALLM.Test.ExampleFixtures

  alias ALLM.{ChatResult, Response, Session}
  alias ALLM.Providers.Fake

  # Helper builds a Fake-backed engine labeled by provider — the
  # case-study `Engines.orchestrator/2` shape collapsed for testing.
  # Delegates to `engine_with_scripts/2` (which delegates to
  # `ALLM.Test.FakeFixtures.engine_with_scripts/2`) so each engine
  # automatically allocates an Agent-backed cursor — two engines built
  # with content-equal scripts don't collide on the default
  # `:erlang.phash2/1`-keyed process-dictionary cursor (Fake moduledoc
  # "Cursor behaviour"). See Phase 12.2 retro Finding 3.
  defp fake_engine_for(:openai, script) do
    engine_with_scripts([script],
      engine_opts: [model: "gpt-5.2-2025-12-11", params: %{temperature: 0.2}]
    )
  end

  defp fake_engine_for(:anthropic, script) do
    engine_with_scripts([script],
      engine_opts: [model: "claude-sonnet-4-5-20250929", params: %{temperature: 0.2}]
    )
  end

  describe "unllmtd_example.md / Side-by-side 1: low-level LLMAdapter.complete — multi-provider engine selection" do
    test "two Fake engines (labeled openai + anthropic) produce equivalent Response shapes" do
      script = text_response(~s({"plan":"do the thing"}))

      openai_engine = fake_engine_for(:openai, script)
      anthropic_engine = fake_engine_for(:anthropic, script)

      assert openai_engine.adapter == Fake
      assert anthropic_engine.adapter == Fake
      assert openai_engine.model != anthropic_engine.model

      request = ALLM.request([ALLM.user("Plan the agent.")])

      assert {:ok, %Response{output_text: text_a, finish_reason: :stop}} =
               ALLM.generate(openai_engine, request)

      assert {:ok, %Response{output_text: text_b, finish_reason: :stop}} =
               ALLM.generate(anthropic_engine, request)

      assert text_a == text_b
      assert {:ok, %{"plan" => "do the thing"}} = Jason.decode(text_a)
    end
  end

  describe "unllmtd_example.md / Side-by-side 2: run_llm_loop — auto-mode multi-turn loop" do
    test "ALLM.chat/3 mode :auto with multi-script Fake terminates with halted_reason :completed" do
      tool = weather_tool()

      eng =
        engine_with_scripts(
          [
            [
              {:tool_call, id: "tc_1", name: "weather", arguments: %{"city" => "Boston"}},
              {:finish, :tool_calls}
            ],
            text_response("It is sunny in Boston.")
          ],
          tools: [tool]
        )

      assert {:ok, %ChatResult{halted_reason: :completed, steps: steps}} =
               ALLM.chat(eng, [ALLM.user("Weather in Boston?")],
                 mode: :auto,
                 max_turns: 5
               )

      assert length(steps) == 2
    end
  end

  describe "unllmtd_example.md / Side-by-side 2 (continued): manual-mode halt + Session.submit_tool_result" do
    test "Session.start mode :manual halts on tool calls; submit_tool_result + continue completes" do
      eng =
        engine_with_scripts([
          [
            {:tool_call, id: "tc_42", name: "plan_agent", arguments: %{"goal" => "ship v0.2"}},
            {:finish, :tool_calls}
          ],
          text_response("Plan submitted.")
        ])

      assert {:ok, %Session{status: :awaiting_tools} = s1,
              %ChatResult{halted_reason: :manual_tool_calls}} =
               Session.start(eng, [ALLM.user("Plan it.")], mode: :manual)

      assert [tc] = s1.pending_tool_calls
      assert tc.id == "tc_42"

      s2 = Session.submit_tool_result(s1, "tc_42", %{accepted: true})

      assert {:ok, %Session{status: :completed} = s3, %ChatResult{}} =
               Session.continue(eng, s2, nil)

      assert s3.status == :completed
    end
  end

  describe "unllmtd_example.md / Side-by-side 2 (continued): ask-user halt + follow-up turn" do
    test "Session.start halts on ask_user tool; Session.continue with user message completes" do
      tool = ask_user_tool()

      # Decision #9: case studies model ask-user via a synthetic tool whose
      # handler returns {:ask_user, q}. The model emits a tool_call to
      # "ask_user"; ALLM's tool runner converts that into a session
      # status: :awaiting_user.
      eng =
        engine_with_scripts(
          [
            ask_user("Should I include the budget breakdown?"),
            text_response("Final plan with budget breakdown.")
          ],
          tools: [tool]
        )

      assert {:ok, %Session{status: :awaiting_user} = s1, %ChatResult{halted_reason: :ask_user}} =
               Session.start(eng, [ALLM.user("Plan a feature.")])

      assert s1.pending_question == "Should I include the budget breakdown?"

      assert {:ok, %Session{status: :completed} = s2, %ChatResult{}} =
               Session.continue(eng, s1, ALLM.user("Yes, include it."))

      assert s2.status == :completed
    end
  end

  describe "unllmtd_example.md / Side-by-side 3: user-LLM-node Executor — chat with node-derived tools" do
    test "ALLM.chat/3 with one node-derived tool produces a final response" do
      # tools_from_node_ids/2 in the case study returns a list of
      # ALLM.tool/1 values; we collapse to one tool here.
      node_tool =
        ALLM.tool(
          name: "tool_node_42",
          description: "Execute node 42",
          schema: %{type: "object", properties: %{x: %{type: "integer"}}},
          handler: fn _ -> {:ok, %{result: 42}} end
        )

      eng =
        engine_with_scripts(
          [
            [
              {:tool_call, id: "tc_1", name: "tool_node_42", arguments: %{"x" => 1}},
              {:finish, :tool_calls}
            ],
            text_response("Done.")
          ],
          tools: [node_tool]
        )

      assert {:ok, %ChatResult{final_response: %Response{output_text: "Done."}}} =
               ALLM.chat(
                 eng,
                 [
                   ALLM.system("Run the node."),
                   ALLM.user("Execute tool_node_42")
                 ],
                 max_turns: 10
               )
    end
  end

  describe "unllmtd_example.md / Side-by-side 4: Streaming — After" do
    test "ALLM.stream/3 mode :auto emits text deltas and a single :chat_completed terminator" do
      eng =
        engine_with_scripts([
          text_response("Hello from the stream.")
        ])

      assert {:ok, stream} = ALLM.stream(eng, [ALLM.user("hi")], mode: :auto, max_turns: 10)
      events = Enum.to_list(stream)

      assert Enum.count(events, &match?({:chat_completed, _}, &1)) == 1
      assert Enum.any?(events, &match?({:text_delta, _}, &1))
    end
  end
end
