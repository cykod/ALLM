defmodule ALLM.ChatStepTest do
  use ExUnit.Case, async: true

  alias ALLM.{Chat, Engine, Message, StepResult, Thread, Tool, ToolCall}
  alias ALLM.Error.{EngineError, ValidationError}
  alias ALLM.Test.FakeFixtures

  doctest Chat

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp echo_tool do
    Tool.new(
      name: "echo",
      description: "",
      schema: %{},
      handler: fn args -> {:ok, args} end
    )
  end

  defp user_thread, do: Thread.from_messages([ALLM.user("hi")])

  # ---------------------------------------------------------------------------
  # Happy path — no tool call
  # ---------------------------------------------------------------------------

  describe "step/3 — no tool call" do
    test "plain text response produces done?: true, empty tool_results" do
      engine = FakeFixtures.engine([{:text, "Hello"}, {:finish, :stop}])

      assert {:ok, %StepResult{} = sr} = Chat.step(engine, user_thread())
      assert sr.done? == true
      assert sr.tool_results == []
      assert sr.response.output_text == "Hello"
      assert sr.response.finish_reason == :stop
    end

    test "assistant message has finish_reason metadata, no tool_calls metadata" do
      engine = FakeFixtures.engine([{:text, "Hi"}, {:finish, :stop}])

      {:ok, sr} = Chat.step(engine, user_thread())
      assistant = List.last(sr.thread.messages)

      assert assistant.role == :assistant
      assert assistant.content == "Hi"
      assert assistant.metadata == %{finish_reason: :stop}
      refute Map.has_key?(assistant.metadata, :tool_calls)
    end
  end

  # ---------------------------------------------------------------------------
  # Single tool call (mode: :auto)
  # ---------------------------------------------------------------------------

  describe "step/3 — single tool call, mode: :auto (default)" do
    test "appends assistant message with tool_calls metadata + tool-role message" do
      engine =
        FakeFixtures.engine(
          [
            {:tool_call, id: "c0", name: "echo", arguments: %{"x" => 1}},
            {:finish, :tool_calls}
          ],
          tools: [echo_tool()]
        )

      {:ok, sr} = Chat.step(engine, user_thread())

      assert sr.done? == false
      assert length(sr.tool_results) == 1
      assert [%Message{role: :tool, tool_call_id: "c0", content: content}] = sr.tool_results
      assert Jason.decode!(content) == %{"x" => 1}

      # Thread shape: [user, assistant, tool]
      [user, assistant, tool] = sr.thread.messages
      assert user.role == :user
      assert assistant.role == :assistant
      assert tool.role == :tool
      assert tool.tool_call_id == "c0"

      # Assistant message carries tool_calls as a list of %ToolCall{}.
      tool_calls = assistant.metadata[:tool_calls]
      assert [%ToolCall{id: "c0", name: "echo"}] = tool_calls
    end

    test "assistant message content uses response.output_text (empty here because no :text script)" do
      engine =
        FakeFixtures.engine(
          [
            {:tool_call, id: "c0", name: "echo", arguments: %{}},
            {:finish, :tool_calls}
          ],
          tools: [echo_tool()]
        )

      {:ok, sr} = Chat.step(engine, user_thread())
      assistant = Enum.find(sr.thread.messages, &(&1.role == :assistant))
      # Fake emits no text, so output_text is "".
      assert assistant.content == ""
    end
  end

  # ---------------------------------------------------------------------------
  # Parallel tool calls
  # ---------------------------------------------------------------------------

  describe "step/3 — parallel tool calls, mode: :auto" do
    test "returns tool_results in input (tool_call_id) order" do
      tool =
        Tool.new(
          name: "echo",
          description: "",
          schema: %{},
          handler: fn %{"n" => n} ->
            # Make the first tool slower so it tends to finish AFTER the
            # second; ToolRunner must still return results in input order.
            if n == 0, do: Process.sleep(30)
            {:ok, n}
          end
        )

      engine =
        FakeFixtures.engine(
          [
            {:tool_call, id: "c0", name: "echo", arguments: %{"n" => 0}},
            {:tool_call, id: "c1", name: "echo", arguments: %{"n" => 1}},
            {:finish, :tool_calls}
          ],
          tools: [tool]
        )

      {:ok, sr} = Chat.step(engine, user_thread())

      [msg0, msg1] = sr.tool_results
      assert msg0.tool_call_id == "c0"
      assert msg1.tool_call_id == "c1"
    end
  end

  # ---------------------------------------------------------------------------
  # mode: :manual
  # ---------------------------------------------------------------------------

  describe "step/3 — mode: :manual" do
    test "surfaces tool calls without executing handlers" do
      handler_called = :manual_handler_called

      tool =
        Tool.new(
          name: "echo",
          description: "",
          schema: %{},
          handler: fn args ->
            Process.put(handler_called, true)
            {:ok, args}
          end
        )

      engine =
        FakeFixtures.engine(
          [
            {:tool_call, id: "c0", name: "echo", arguments: %{"x" => 1}},
            {:finish, :tool_calls}
          ],
          tools: [tool]
        )

      {:ok, sr} = Chat.step(engine, user_thread(), mode: :manual)

      assert sr.done? == false
      assert sr.tool_results == []
      assert sr.metadata[:mode] == :manual
      refute Map.has_key?(sr.metadata, :halted_reason)
      # Handler must not be invoked.
      refute Process.get(handler_called)

      # Response still carries the tool calls for the caller to handle.
      assert [%ToolCall{id: "c0", name: "echo"}] = sr.response.tool_calls
    end
  end

  # ---------------------------------------------------------------------------
  # on_tool_error: :halt
  # ---------------------------------------------------------------------------

  describe "step/3 — on_tool_error" do
    test ":halt sets done?: true, halted_reason: :tool_error" do
      tool =
        Tool.new(
          name: "echo",
          description: "",
          schema: %{},
          handler: fn _ -> {:error, :bad} end
        )

      engine =
        FakeFixtures.engine(
          [
            {:tool_call, id: "c0", name: "echo", arguments: %{}},
            {:finish, :tool_calls}
          ],
          tools: [tool]
        )

      {:ok, sr} = Chat.step(engine, user_thread(), on_tool_error: :halt)

      assert sr.done? == true
      assert sr.metadata[:halted_reason] == :tool_error
      assert sr.metadata[:halt_tool_call_id] == "c0"
      assert length(sr.tool_results) == 1
    end

    test ":continue (default) produces done?: false with error encoded into tool_results" do
      tool =
        Tool.new(
          name: "echo",
          description: "",
          schema: %{},
          handler: fn _ -> {:error, :bad} end
        )

      engine =
        FakeFixtures.engine(
          [
            {:tool_call, id: "c0", name: "echo", arguments: %{}},
            {:finish, :tool_calls}
          ],
          tools: [tool]
        )

      {:ok, sr} = Chat.step(engine, user_thread())

      assert sr.done? == false
      refute Map.has_key?(sr.metadata, :halted_reason)
      assert [%Message{role: :tool, content: content}] = sr.tool_results
      assert content =~ "error"
    end

    test "function form that raises surfaces exception under step.metadata.on_tool_error_exception" do
      # Phase 7 design Non-obvious Decision #8: when an `on_tool_error`
      # function raises, the captured exception is lifted into the
      # ToolRunner halt_metadata and propagates to `step.metadata` so
      # the chat layer can read it directly without fishing through
      # `tool_results`.
      tool =
        Tool.new(
          name: "echo",
          description: "",
          schema: %{},
          handler: fn _ -> {:error, :bad} end
        )

      engine =
        FakeFixtures.engine(
          [
            {:tool_call, id: "c-raise", name: "echo", arguments: %{}},
            {:finish, :tool_calls}
          ],
          tools: [tool]
        )

      {:ok, sr} =
        ALLM.step(engine, user_thread(),
          on_tool_error: fn _tc, _err -> raise "boom from on_tool_error" end
        )

      assert sr.done? == true
      assert sr.metadata[:halted_reason] == :tool_error
      assert sr.metadata[:halt_tool_call_id] == "c-raise"

      assert %RuntimeError{message: "boom from on_tool_error"} =
               sr.metadata[:on_tool_error_exception]
    end
  end

  # ---------------------------------------------------------------------------
  # Handler halt / ask-user
  # ---------------------------------------------------------------------------

  describe "step/3 — handler {:halt, reason, result}" do
    test "sets done?: true, halted_reason, halt_tool_call_id, halt_result" do
      tool =
        Tool.new(
          name: "echo",
          description: "",
          schema: %{},
          handler: fn _ -> {:halt, :budget_exceeded, %{used: 100}} end
        )

      engine =
        FakeFixtures.engine(
          [
            {:tool_call, id: "c0", name: "echo", arguments: %{}},
            {:finish, :tool_calls}
          ],
          tools: [tool]
        )

      {:ok, sr} = Chat.step(engine, user_thread())

      assert sr.done? == true
      assert sr.metadata[:halted_reason] == :budget_exceeded
      assert sr.metadata[:halt_tool_call_id] == "c0"
      assert sr.metadata[:halt_result] == %{used: 100}

      # Tool message content is the encoded result.
      assert [%Message{content: content}] = sr.tool_results
      assert Jason.decode!(content) == %{"used" => 100}
    end
  end

  describe "step/3 — handler {:ask_user, question}" do
    test "sets ask_user metadata and does NOT append a trailing :assistant with ask_user: true" do
      tool =
        Tool.new(
          name: "echo",
          description: "",
          schema: %{},
          handler: fn _ -> {:ask_user, "which?"} end
        )

      engine =
        FakeFixtures.engine(
          [
            {:tool_call, id: "c0", name: "echo", arguments: %{}},
            {:finish, :tool_calls}
          ],
          tools: [tool]
        )

      {:ok, sr} = Chat.step(engine, user_thread())

      assert sr.done? == true
      assert sr.metadata[:halted_reason] == :ask_user
      assert sr.metadata[:pending_question] == "which?"
      assert sr.metadata[:pending_tool_call_id] == "c0"
      assert sr.metadata[:ask_user_opts] == []

      # Tool message content is the spec §12.3 placeholder.
      assert [%Message{content: "<awaiting user response>"}] = sr.tool_results

      # Non-obvious Decision #6: no trailing :assistant with ask_user: true.
      last = List.last(sr.thread.messages)
      assert last.role == :tool

      refute Enum.any?(sr.thread.messages, fn
               %Message{role: :assistant, metadata: %{ask_user: true}} -> true
               _ -> false
             end)
    end
  end

  # ---------------------------------------------------------------------------
  # Unknown tool pre-flight
  # ---------------------------------------------------------------------------

  describe "step/3 — unknown tool" do
    test "returns {:error, %EngineError{reason: :unknown_tool}}" do
      # No `missing` tool registered.
      engine =
        FakeFixtures.engine([
          {:tool_call, id: "c0", name: "missing", arguments: %{}},
          {:finish, :tool_calls}
        ])

      assert {:error, %EngineError{reason: :unknown_tool, metadata: %{tool_name: "missing"}}} =
               Chat.step(engine, user_thread())
    end
  end

  # ---------------------------------------------------------------------------
  # Pre-flight errors
  # ---------------------------------------------------------------------------

  describe "step/3 — pre-flight errors" do
    test "missing adapter returns %EngineError{reason: :missing_adapter}" do
      engine = Engine.new(adapter: nil)

      assert {:error, %EngineError{reason: :missing_adapter}} = Chat.step(engine, user_thread())
    end

    test "invalid thread (tool message missing tool_call_id) returns %ValidationError{}" do
      bad_msg = %Message{role: :tool, content: "x", tool_call_id: nil}
      thread = Thread.from_messages([bad_msg])
      engine = FakeFixtures.engine([{:text, "ok"}, {:finish, :stop}])

      assert {:error, %ValidationError{reason: :invalid_thread}} = Chat.step(engine, thread)
    end
  end

  # ---------------------------------------------------------------------------
  # List-of-messages normalisation
  # ---------------------------------------------------------------------------

  describe "step/3 — list-of-messages input normalisation" do
    test "list of %Message{} is wrapped via Thread.from_messages/1" do
      engine = FakeFixtures.engine([{:text, "ok"}, {:finish, :stop}])
      msgs = [ALLM.user("hi")]

      {:ok, sr} = Chat.step(engine, msgs)
      # Thread comes back with the user message + the assistant message.
      assert length(sr.thread.messages) == 2
    end

    test "invalid input (neither Thread nor list) returns %ValidationError{}" do
      engine = FakeFixtures.engine([{:text, "ok"}, {:finish, :stop}])
      assert {:error, %ValidationError{reason: :invalid_thread}} = Chat.step(engine, :bogus)
    end
  end

  describe "step/3 — engine-level tool_result_encoder override" do
    test "engine.tool_result_encoder is honoured when set" do
      # When an engine-level encoder is set, ToolRunner uses it.
      # Use the shipping default so the test is deterministic.
      engine =
        Engine.new(
          adapter: ALLM.Providers.Fake,
          adapter_opts: [
            script: [
              {:tool_call, id: "c0", name: "echo", arguments: %{"x" => 1}},
              {:finish, :tool_calls}
            ]
          ],
          tools: [echo_tool()],
          tool_result_encoder: ALLM.ToolResultEncoder.JSON
        )

      {:ok, sr} = Chat.step(engine, user_thread())
      assert [%Message{content: content}] = sr.tool_results
      assert Jason.decode!(content) == %{"x" => 1}
    end
  end

  # ---------------------------------------------------------------------------
  # Serializability round-trip
  # ---------------------------------------------------------------------------

  describe "step/3 — serializability of StepResult.thread" do
    test "assistant message metadata.tool_calls round-trips through term_to_binary" do
      engine =
        FakeFixtures.engine(
          [
            {:tool_call, id: "c0", name: "echo", arguments: %{"x" => 1}},
            {:finish, :tool_calls}
          ],
          tools: [echo_tool()]
        )

      {:ok, sr} = Chat.step(engine, user_thread())

      bin = :erlang.term_to_binary(sr.thread)
      recovered = :erlang.binary_to_term(bin)

      assistant = Enum.find(recovered.messages, &(&1.role == :assistant))
      assert [%ToolCall{id: "c0", name: "echo"}] = assistant.metadata[:tool_calls]
    end
  end
end
