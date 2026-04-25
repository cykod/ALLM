defmodule ALLM.ToolRunnerTest do
  use ExUnit.Case, async: true

  alias ALLM.{Engine, Event, Message, Tool, ToolCall, ToolRunner}
  alias ALLM.Error.{EngineError, ToolError}

  doctest ToolRunner

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp engine(ctx \\ %{}), do: Engine.new(adapter: ALLM.Providers.Fake, context: ctx)

  defp echo_tool do
    Tool.new(
      name: "echo",
      description: "echoes its argument",
      schema: %{},
      handler: fn args -> {:ok, args} end
    )
  end

  defp echo_call(id, args \\ %{x: 1}) do
    ToolCall.new(id: id, name: "echo", arguments: args)
  end

  # ---------------------------------------------------------------------------
  # Non-streaming — happy path
  # ---------------------------------------------------------------------------

  describe "run_tool_calls/3 — happy path (non-streaming)" do
    test "single tool call returns one :tool message with encoded content" do
      tc = ToolCall.new(id: "c0", name: "echo", arguments: %{"text" => "hi"})

      tool =
        Tool.new(
          name: "echo",
          description: "",
          schema: %{},
          handler: fn %{"text" => t} -> {:ok, t} end
        )

      assert {:ok, [msg]} = ToolRunner.run_tool_calls([tc], [tool], engine: engine())
      assert msg.role == :tool
      assert msg.tool_call_id == "c0"
      # ToolRunner unwraps `{:ok, value}` before handing `value` to the encoder;
      # the default JSON encoder passes binaries through unchanged.
      assert msg.content == "hi"
    end

    test "two tool calls return messages in INPUT order (sorted by index)" do
      a = ToolCall.new(id: "aaa", name: "echo", arguments: %{"n" => 1})
      b = ToolCall.new(id: "bbb", name: "echo", arguments: %{"n" => 2})

      tool =
        Tool.new(
          name: "echo",
          description: "",
          schema: %{},
          handler: fn %{"n" => n} ->
            # Make B slow so it tends to finish AFTER A; order must still be input order.
            if n == 1, do: Process.sleep(30)
            {:ok, n}
          end
        )

      assert {:ok, [msg_a, msg_b]} =
               ToolRunner.run_tool_calls([a, b], [tool], engine: engine())

      assert msg_a.tool_call_id == "aaa"
      assert msg_b.tool_call_id == "bbb"
    end

    test "arity-1 handler receives arguments" do
      me = self()

      tool =
        Tool.new(
          name: "echo",
          description: "",
          schema: %{},
          handler: fn args ->
            send(me, {:arity_1, args})
            {:ok, args}
          end
        )

      tc = ToolCall.new(id: "c0", name: "echo", arguments: %{"a" => 1})
      assert {:ok, [_msg]} = ToolRunner.run_tool_calls([tc], [tool], engine: engine())
      assert_received {:arity_1, %{"a" => 1}}
    end

    test "arity-2 handler receives engine.context via opts[:context]" do
      me = self()

      tool =
        Tool.new(
          name: "echo",
          description: "",
          schema: %{},
          handler: fn args, opts ->
            send(me, {:arity_2, args, Keyword.get(opts, :context)})
            {:ok, Keyword.get(opts, :context)}
          end
        )

      tc = ToolCall.new(id: "c0", name: "echo", arguments: %{})
      ctx = %{user_id: 42}
      eng = engine(ctx)

      assert {:ok, [msg]} = ToolRunner.run_tool_calls([tc], [tool], engine: eng)
      assert_received {:arity_2, %{}, ^ctx}
      # Handler returns `{:ok, ctx}`; ToolRunner unwraps and the encoder
      # JSON-encodes the context map directly (no `{:ok, ...}` wrapper).
      assert msg.content == Jason.encode!(ctx)
    end

    test "arity-2 handler receives tool_call and engine in opts" do
      me = self()

      tool =
        Tool.new(
          name: "echo",
          description: "",
          schema: %{},
          handler: fn _args, opts ->
            send(
              me,
              {:opts_seen, Keyword.take(opts, [:tool_call, :engine, :session_id, :request_id])}
            )

            {:ok, :seen}
          end
        )

      tc = ToolCall.new(id: "c0", name: "echo", arguments: %{})
      eng = engine()

      {:ok, _} = ToolRunner.run_tool_calls([tc], [tool], engine: eng, request_id: "req-7")
      assert_received {:opts_seen, opts}
      assert Keyword.get(opts, :tool_call) == tc
      assert Keyword.get(opts, :engine) == eng
      assert Keyword.get(opts, :session_id) == nil
      assert Keyword.get(opts, :request_id) == "req-7"
    end
  end

  # ---------------------------------------------------------------------------
  # Streaming — happy path
  # ---------------------------------------------------------------------------

  describe "stream_tool_calls/3 — happy path (streaming)" do
    test "single tool call emits started → completed → encoded in order" do
      tc = echo_call("c0")

      events =
        [tc]
        |> ToolRunner.stream_tool_calls([echo_tool()], engine: engine())
        |> Enum.to_list()

      assert Enum.map(events, &elem(&1, 0)) ==
               [:tool_execution_started, :tool_execution_completed, :tool_result_encoded]

      assert Enum.all?(events, &Event.event?/1)
    end

    test "two tool calls emit 6 total events; per-id ordering preserved" do
      tc_a = echo_call("a")
      tc_b = echo_call("b")

      events =
        [tc_a, tc_b]
        |> ToolRunner.stream_tool_calls([echo_tool()], engine: engine())
        |> Enum.to_list()

      assert length(events) == 6

      # Group by id and assert the per-id trio order is preserved regardless
      # of cross-id interleaving.
      for id <- ["a", "b"] do
        per_id_tags =
          events
          |> Enum.filter(fn
            {tag, %{id: ^id}}
            when tag in [:tool_execution_started, :tool_execution_completed, :tool_result_encoded] ->
              true

            _ ->
              false
          end)
          |> Enum.map(&elem(&1, 0))

        assert per_id_tags ==
                 [:tool_execution_started, :tool_execution_completed, :tool_result_encoded]
      end
    end

    test "no :step_completed event — that is the caller's concern" do
      events =
        [echo_call("c0")]
        |> ToolRunner.stream_tool_calls([echo_tool()], engine: engine())
        |> Enum.to_list()

      refute Enum.any?(events, &match?({:step_completed, _}, &1))
    end
  end

  # ---------------------------------------------------------------------------
  # Unknown tool
  # ---------------------------------------------------------------------------

  describe "unknown tool pre-flight" do
    test "run_tool_calls/3 returns {:error, %EngineError{reason: :unknown_tool}} synchronously" do
      tc = ToolCall.new(id: "c0", name: "missing", arguments: %{})

      assert {:error, %EngineError{reason: :unknown_tool, metadata: %{tool_name: "missing"}}} =
               ToolRunner.run_tool_calls([tc], [], engine: engine())
    end

    test "run_tool_calls/3 does NOT execute any tool when one is unknown" do
      me = self()

      tool =
        Tool.new(
          name: "echo",
          description: "",
          schema: %{},
          handler: fn args ->
            send(me, :handler_ran)
            {:ok, args}
          end
        )

      good = ToolCall.new(id: "g", name: "echo", arguments: %{})
      bad = ToolCall.new(id: "b", name: "missing", arguments: %{})

      assert {:error, %EngineError{reason: :unknown_tool}} =
               ToolRunner.run_tool_calls([good, bad], [tool], engine: engine())

      refute_received :handler_ran
    end

    test "stream_tool_calls/3 emits a single {:error, %EngineError{}} element and terminates" do
      tc = ToolCall.new(id: "c0", name: "missing", arguments: %{})

      events =
        [tc]
        |> ToolRunner.stream_tool_calls([], engine: engine())
        |> Enum.to_list()

      assert [{:error, %EngineError{reason: :unknown_tool}}] = events
    end
  end

  # ---------------------------------------------------------------------------
  # Handler {:error, _}
  # ---------------------------------------------------------------------------

  describe "handler returns {:error, reason} — on_tool_error :continue" do
    test "error is encoded and returned as a tool message; batch continues" do
      tool =
        Tool.new(
          name: "boom",
          description: "",
          schema: %{},
          handler: fn _ -> {:error, :bad_arg} end
        )

      tc = ToolCall.new(id: "c0", name: "boom", arguments: %{})

      assert {:ok, [msg]} =
               ToolRunner.run_tool_calls([tc], [tool],
                 engine: engine(),
                 on_tool_error: :continue
               )

      assert msg.tool_call_id == "c0"
      decoded = Jason.decode!(msg.content)
      assert Map.has_key?(decoded, "error")
    end
  end

  describe "handler returns {:error, reason} — on_tool_error :halt" do
    test "halt metadata returned with :tool_error; message still in list" do
      tool =
        Tool.new(
          name: "boom",
          description: "",
          schema: %{},
          handler: fn _ -> {:error, :bad_arg} end
        )

      tc = ToolCall.new(id: "c0", name: "boom", arguments: %{})

      assert {:ok, [msg], meta} =
               ToolRunner.run_tool_calls([tc], [tool],
                 engine: engine(),
                 on_tool_error: :halt
               )

      assert meta.halted_reason == :tool_error
      assert meta.halt_tool_call_id == "c0"
      assert msg.tool_call_id == "c0"
    end

    test "streaming emits :tool_halt with payload :content when on_tool_error: :halt fires (Phase 7.6 B3)" do
      # Phase 7.6 cleanup B3: on_tool_error: :halt on a `{:error, _}` return
      # MUST surface as a `:tool_halt` event (was `:tool_result_encoded`).
      # The payload carries the encoded error content via the optional
      # `:content` key so `StreamCollector`'s `:tool_halt` fold populates
      # `state.tool_results` without re-running the encoder.
      tool =
        Tool.new(
          name: "boom",
          description: "",
          schema: %{},
          handler: fn _ -> {:error, :bad_arg} end
        )

      tc = ToolCall.new(id: "c0", name: "boom", arguments: %{})

      events =
        [tc]
        |> ToolRunner.stream_tool_calls([tool], engine: engine(), on_tool_error: :halt)
        |> Enum.to_list()

      tags = Enum.map(events, &elem(&1, 0))
      assert tags == [:tool_execution_started, :tool_execution_completed, :tool_halt]

      assert Enum.all?(events, &Event.event?/1)

      assert Enum.any?(events, fn
               {:tool_execution_completed, %{result: {:error, :bad_arg}}} -> true
               _ -> false
             end)

      assert Enum.any?(events, fn
               {:tool_halt, %{tool_call_id: "c0", reason: :tool_error, content: content}}
               when is_binary(content) ->
                 Map.has_key?(Jason.decode!(content), "error")

               _ ->
                 false
             end)
    end
  end

  # ---------------------------------------------------------------------------
  # Handler raises — ToolError{:handler_raised}
  # ---------------------------------------------------------------------------

  describe "handler raises" do
    test "executor catches raise → %ToolError{reason: :handler_raised}; on_tool_error :continue encodes" do
      tool =
        Tool.new(
          name: "boom",
          description: "",
          schema: %{},
          handler: fn _ -> raise "kapow" end
        )

      tc = ToolCall.new(id: "c0", name: "boom", arguments: %{})

      assert {:ok, [msg]} =
               ToolRunner.run_tool_calls([tc], [tool],
                 engine: engine(),
                 on_tool_error: :continue
               )

      decoded = Jason.decode!(msg.content)
      assert Map.has_key?(decoded, "error")
    end

    test "streaming emits :tool_execution_completed with {:error, %ToolError{reason: :handler_raised}}" do
      tool =
        Tool.new(
          name: "boom",
          description: "",
          schema: %{},
          handler: fn _ -> raise "kapow" end
        )

      tc = ToolCall.new(id: "c0", name: "boom", arguments: %{})

      events =
        [tc]
        |> ToolRunner.stream_tool_calls([tool], engine: engine(), on_tool_error: :continue)
        |> Enum.to_list()

      assert Enum.any?(events, fn
               {:tool_execution_completed, %{result: {:error, %ToolError{reason: :handler_raised}}}} ->
                 true

               _ ->
                 false
             end)
    end
  end

  # ---------------------------------------------------------------------------
  # Handler {:halt, reason, result}
  # ---------------------------------------------------------------------------

  describe "handler returns {:halt, reason, result}" do
    test "custom reason — halt metadata carries reason + result" do
      tool =
        Tool.new(
          name: "finalize",
          description: "",
          schema: %{},
          handler: fn _ -> {:halt, :plan_submitted, %{status: "ok"}} end
        )

      tc = ToolCall.new(id: "c0", name: "finalize", arguments: %{})

      assert {:ok, [msg], meta} =
               ToolRunner.run_tool_calls([tc], [tool], engine: engine())

      assert meta == %{
               halted_reason: :plan_submitted,
               halt_tool_call_id: "c0",
               halt_result: %{status: "ok"}
             }

      assert msg.tool_call_id == "c0"
      assert Jason.decode!(msg.content) == %{"status" => "ok"}
    end

    test "reserved reason like :tool_error is rejected (Phase 7 — spec §5.2)" do
      # Phase 7: reserved halt atoms are wrapped as %ToolError{:invalid_return}
      # and routed via on_tool_error. With default :continue, the error is
      # encoded as the tool message content; the batch does NOT halt with
      # :tool_error because the reserved-atom rejection is treated as a
      # tool error, not as the handler's halt request.
      tool =
        Tool.new(
          name: "finalize",
          description: "",
          schema: %{},
          handler: fn _ -> {:halt, :tool_error, %{manual: true}} end
        )

      tc = ToolCall.new(id: "c0", name: "finalize", arguments: %{})

      assert {:ok, [msg]} =
               ToolRunner.run_tool_calls([tc], [tool], engine: engine())

      decoded = Jason.decode!(msg.content)
      assert Map.has_key?(decoded, "error")
      assert decoded["error"] =~ "reserved"
    end

    test "streaming emits :tool_halt tail event" do
      tool =
        Tool.new(
          name: "finalize",
          description: "",
          schema: %{},
          handler: fn _ -> {:halt, :budget_exceeded, %{used: 100}} end
        )

      tc = ToolCall.new(id: "c0", name: "finalize", arguments: %{})

      events =
        [tc]
        |> ToolRunner.stream_tool_calls([tool], engine: engine())
        |> Enum.to_list()

      tags = Enum.map(events, &elem(&1, 0))
      assert :tool_halt in tags
      refute :tool_result_encoded in tags

      assert Enum.any?(events, fn
               {:tool_halt, %{tool_call_id: "c0", reason: :budget_exceeded, result: %{used: 100}}} ->
                 true

               _ ->
                 false
             end)
    end
  end

  # ---------------------------------------------------------------------------
  # Handler {:ask_user, ...}
  # ---------------------------------------------------------------------------

  describe "handler returns {:ask_user, question}" do
    test "content is '<awaiting user response>'; halt metadata carries question" do
      tool =
        Tool.new(
          name: "ask",
          description: "",
          schema: %{},
          handler: fn _ -> {:ask_user, "which city?"} end
        )

      tc = ToolCall.new(id: "c0", name: "ask", arguments: %{})

      assert {:ok, [msg], meta} =
               ToolRunner.run_tool_calls([tc], [tool], engine: engine())

      assert msg.content == "<awaiting user response>"

      assert meta == %{
               halted_reason: :ask_user,
               pending_question: "which city?",
               pending_tool_call_id: "c0",
               ask_user_opts: []
             }
    end

    test "{:ask_user, question, opts} threads opts into metadata" do
      tool =
        Tool.new(
          name: "ask",
          description: "",
          schema: %{},
          handler: fn _ -> {:ask_user, "which?", choices: ["A", "B"]} end
        )

      tc = ToolCall.new(id: "c0", name: "ask", arguments: %{})

      assert {:ok, [_msg], meta} =
               ToolRunner.run_tool_calls([tc], [tool], engine: engine())

      assert meta.ask_user_opts == [choices: ["A", "B"]]
    end

    test "streaming emits :ask_user_requested tail event" do
      tool =
        Tool.new(
          name: "ask",
          description: "",
          schema: %{},
          handler: fn _ -> {:ask_user, "which?"} end
        )

      tc = ToolCall.new(id: "c0", name: "ask", arguments: %{})

      events =
        [tc]
        |> ToolRunner.stream_tool_calls([tool], engine: engine())
        |> Enum.to_list()

      assert Enum.any?(events, fn
               {:ask_user_requested,
                %{tool_call_id: "c0", tool_name: "ask", question: "which?", opts: []}} ->
                 true

               _ ->
                 false
             end)
    end
  end

  # ---------------------------------------------------------------------------
  # Tool timeout
  # ---------------------------------------------------------------------------

  describe "tool timeout" do
    test "handler that sleeps past tool_timeout → %ToolError{reason: :timeout}" do
      tool =
        Tool.new(
          name: "slow",
          description: "",
          schema: %{},
          handler: fn _ ->
            Process.sleep(200)
            {:ok, :never_reached}
          end
        )

      tc = ToolCall.new(id: "c0", name: "slow", arguments: %{})

      assert {:ok, [msg]} =
               ToolRunner.run_tool_calls([tc], [tool],
                 engine: engine(),
                 tool_timeout: 50,
                 on_tool_error: :continue
               )

      decoded = Jason.decode!(msg.content)
      assert Map.has_key?(decoded, "error")
    end

    test "streaming surfaces timeout as :tool_execution_completed with :timeout" do
      tool =
        Tool.new(
          name: "slow",
          description: "",
          schema: %{},
          handler: fn _ ->
            Process.sleep(200)
            {:ok, :never}
          end
        )

      tc = ToolCall.new(id: "c0", name: "slow", arguments: %{})

      events =
        [tc]
        |> ToolRunner.stream_tool_calls([tool],
          engine: engine(),
          tool_timeout: 50,
          on_tool_error: :continue
        )
        |> Enum.to_list()

      assert Enum.any?(events, fn
               {:tool_execution_completed, %{result: {:error, %ToolError{reason: :timeout}}}} ->
                 true

               _ ->
                 false
             end)
    end
  end

  # ---------------------------------------------------------------------------
  # Encoder failure
  # ---------------------------------------------------------------------------

  describe "encoder failure" do
    test "handler returns a make_ref() → encoder raises → wrapped as :encoding_failed; :continue encodes" do
      ref = make_ref()

      tool =
        Tool.new(
          name: "bad",
          description: "",
          schema: %{},
          handler: fn _ -> {:ok, ref} end
        )

      tc = ToolCall.new(id: "c0", name: "bad", arguments: %{})

      assert {:ok, [msg]} =
               ToolRunner.run_tool_calls([tc], [tool],
                 engine: engine(),
                 on_tool_error: :continue
               )

      decoded = Jason.decode!(msg.content)
      assert Map.has_key?(decoded, "error")
      assert is_binary(decoded["error"])
    end

    test "encoder failure with on_tool_error: :halt returns halt metadata" do
      ref = make_ref()

      tool =
        Tool.new(
          name: "bad",
          description: "",
          schema: %{},
          handler: fn _ -> {:ok, ref} end
        )

      tc = ToolCall.new(id: "c0", name: "bad", arguments: %{})

      assert {:ok, [_msg], meta} =
               ToolRunner.run_tool_calls([tc], [tool],
                 engine: engine(),
                 on_tool_error: :halt
               )

      assert meta.halted_reason == :tool_error
      assert meta.halt_tool_call_id == "c0"
    end
  end

  # ---------------------------------------------------------------------------
  # max_concurrency
  # ---------------------------------------------------------------------------

  describe "max_concurrency" do
    test "with 20 tool calls and max_concurrency: 2, peak concurrency ≤ 2" do
      ref = :counters.new(2, [:write_concurrency])
      # slot 1 = current concurrency, slot 2 = observed peak.

      tool =
        Tool.new(
          name: "t",
          description: "",
          schema: %{},
          handler: fn _ ->
            :counters.add(ref, 1, 1)
            current = :counters.get(ref, 1)
            peak = :counters.get(ref, 2)
            if current > peak, do: :counters.put(ref, 2, current)
            Process.sleep(20)
            :counters.sub(ref, 1, 1)
            {:ok, :done}
          end
        )

      tool_calls =
        for i <- 0..19 do
          ToolCall.new(id: "c#{i}", name: "t", arguments: %{})
        end

      assert {:ok, msgs} =
               ToolRunner.run_tool_calls(tool_calls, [tool],
                 engine: engine(),
                 max_concurrency: 2
               )

      assert length(msgs) == 20
      peak = :counters.get(ref, 2)
      assert peak <= 2
      assert peak >= 1
    end
  end

  # ---------------------------------------------------------------------------
  # on_tool_error function-form rejection
  # ---------------------------------------------------------------------------

  describe "on_tool_error validation" do
    test "passing a non-atom, non-function raises ArgumentError" do
      tc = echo_call("c0")

      assert_raise ArgumentError, fn ->
        ToolRunner.run_tool_calls([tc], [echo_tool()],
          engine: engine(),
          on_tool_error: :not_an_atom_policy
        )
      end
    end

    test "passing a function of arity 1 raises ArgumentError mentioning the (tool_call, error) signature" do
      tc = echo_call("c0")

      assert_raise ArgumentError, ~r/tool_call, error/, fn ->
        ToolRunner.run_tool_calls([tc], [echo_tool()],
          engine: engine(),
          on_tool_error: fn _err -> :halt end
        )
      end

      assert_raise ArgumentError, ~r/tool_call, error/, fn ->
        ToolRunner.stream_tool_calls([tc], [echo_tool()],
          engine: engine(),
          on_tool_error: fn _err -> :halt end
        )
      end
    end

    test "passing a function of arity 3 raises ArgumentError" do
      tc = echo_call("c0")

      assert_raise ArgumentError, ~r/arity 2/, fn ->
        ToolRunner.run_tool_calls([tc], [echo_tool()],
          engine: engine(),
          on_tool_error: fn _tc, _err, _extra -> :halt end
        )
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Empty tool_calls short-circuit
  # ---------------------------------------------------------------------------

  describe "empty tool_calls short-circuit" do
    test "run_tool_calls([], _, _) → {:ok, []}" do
      assert ToolRunner.run_tool_calls([], [], engine: engine()) == {:ok, []}
    end

    test "stream_tool_calls([], _, _) returns an empty enumerable" do
      assert Enum.to_list(ToolRunner.stream_tool_calls([], [], engine: engine())) == []
    end

    test "empty short-circuit does NOT raise (guards against max_concurrency: 0)" do
      # No tools at all + empty calls — we must not touch Task.async_stream.
      assert ToolRunner.run_tool_calls([], [], []) == {:ok, []}
      assert Enum.to_list(ToolRunner.stream_tool_calls([], [], [])) == []
    end
  end

  # ---------------------------------------------------------------------------
  # Sibling drain on halt
  # ---------------------------------------------------------------------------

  describe "sibling drain on halt" do
    test "when one handler halts, completed sibling messages are still present" do
      # Tool 'finalize' halts immediately; tool 'echo' is slow but completes.
      finalize =
        Tool.new(
          name: "finalize",
          description: "",
          schema: %{},
          handler: fn _ ->
            # Short delay so 'echo' also runs in parallel.
            Process.sleep(20)
            {:halt, :done, %{}}
          end
        )

      echo =
        Tool.new(
          name: "echo",
          description: "",
          schema: %{},
          handler: fn args ->
            Process.sleep(10)
            {:ok, args}
          end
        )

      calls = [
        ToolCall.new(id: "f", name: "finalize", arguments: %{}),
        ToolCall.new(id: "e", name: "echo", arguments: %{"n" => 1})
      ]

      assert {:ok, msgs, _meta} =
               ToolRunner.run_tool_calls(calls, [finalize, echo],
                 engine: engine(),
                 max_concurrency: 4
               )

      # Both messages present in input order.
      assert length(msgs) == 2
      assert Enum.map(msgs, & &1.tool_call_id) == ["f", "e"]
    end
  end

  # ---------------------------------------------------------------------------
  # Engine tool_executor / tool_result_encoder resolution
  # ---------------------------------------------------------------------------

  describe "executor / encoder resolution" do
    test "opts override engine executor" do
      defmodule CustomExecutor do
        @moduledoc false
        @behaviour ALLM.ToolExecutor

        @impl true
        def execute(%Tool{}, _args, _opts), do: {:ok, "custom_path"}
      end

      tool = echo_tool()
      tc = echo_call("c0")

      assert {:ok, [msg]} =
               ToolRunner.run_tool_calls([tc], [tool],
                 engine: engine(),
                 tool_executor: CustomExecutor
               )

      # CustomExecutor returns `{:ok, "custom_path"}`; ToolRunner unwraps and
      # the default encoder passes the binary through unchanged.
      assert msg.content == "custom_path"
    end
  end

  # ---------------------------------------------------------------------------
  # Engine-field fallbacks for executor / encoder
  # ---------------------------------------------------------------------------

  describe "engine-field fallbacks" do
    test "engine.tool_executor used when no opts override" do
      defmodule EngineScopedExecutor do
        @moduledoc false
        @behaviour ALLM.ToolExecutor

        @impl true
        def execute(%Tool{}, _args, _opts), do: {:ok, "from_engine_executor"}
      end

      tool = echo_tool()
      tc = echo_call("c0")
      eng = Engine.new(adapter: ALLM.Providers.Fake, tool_executor: EngineScopedExecutor)

      assert {:ok, [msg]} = ToolRunner.run_tool_calls([tc], [tool], engine: eng)
      assert msg.content == "from_engine_executor"
    end

    test "engine.tool_result_encoder used when no opts override" do
      defmodule EngineScopedEncoder do
        @moduledoc false
        @behaviour ALLM.ToolResultEncoder

        @impl true
        def encode(_value), do: "ENCODED_BY_ENGINE"
      end

      tool = echo_tool()
      tc = echo_call("c0")
      eng = Engine.new(adapter: ALLM.Providers.Fake, tool_result_encoder: EngineScopedEncoder)

      assert {:ok, [msg]} = ToolRunner.run_tool_calls([tc], [tool], engine: eng)
      assert msg.content == "ENCODED_BY_ENGINE"
    end

    test "no engine at all — default executor + encoder kick in" do
      tool = echo_tool()
      tc = echo_call("c0")

      # No :engine key at all.
      assert {:ok, [msg]} = ToolRunner.run_tool_calls([tc], [tool], [])
      assert is_binary(msg.content)
    end

    test "opts[:context] overrides engine.context for arity-2 handlers" do
      me = self()

      tool =
        Tool.new(
          name: "ctx",
          description: "",
          schema: %{},
          handler: fn _, opts ->
            send(me, {:ctx_seen, Keyword.get(opts, :context)})
            {:ok, :ok}
          end
        )

      tc = ToolCall.new(id: "c0", name: "ctx", arguments: %{})
      eng = engine(%{origin: :engine})

      {:ok, _} =
        ToolRunner.run_tool_calls([tc], [tool],
          engine: eng,
          context: %{origin: :opts_override}
        )

      assert_received {:ctx_seen, %{origin: :opts_override}}
    end

    test "no engine — arity-2 handler sees context: %{} default" do
      me = self()

      tool =
        Tool.new(
          name: "ctx",
          description: "",
          schema: %{},
          handler: fn _, opts ->
            send(me, {:ctx_seen, Keyword.get(opts, :context)})
            {:ok, :ok}
          end
        )

      tc = ToolCall.new(id: "c0", name: "ctx", arguments: %{})

      {:ok, _} = ToolRunner.run_tool_calls([tc], [tool], [])
      assert_received {:ctx_seen, %{}}
    end
  end

  # ---------------------------------------------------------------------------
  # Custom encoder raising (encoder not in default happy path)
  # ---------------------------------------------------------------------------

  describe "custom encoder error-path recovery" do
    test "encoder that raises on {:error, _} falls back to Exception.message form" do
      defmodule AlwaysRaisingEncoder do
        @moduledoc false
        @behaviour ALLM.ToolResultEncoder

        @impl true
        def encode(value) when is_binary(value), do: value

        def encode(_other) do
          raise Protocol.UndefinedError,
            protocol: Jason.Encoder,
            value: make_ref(),
            description: "test"
        end
      end

      tool =
        Tool.new(
          name: "err",
          description: "",
          schema: %{},
          handler: fn _ -> {:error, %RuntimeError{message: "oh no"}} end
        )

      tc = ToolCall.new(id: "c0", name: "err", arguments: %{})

      assert {:ok, [msg]} =
               ToolRunner.run_tool_calls([tc], [tool],
                 engine: engine(),
                 tool_result_encoder: AlwaysRaisingEncoder,
                 on_tool_error: :continue
               )

      decoded = Jason.decode!(msg.content)
      assert decoded["error"] =~ "oh no"
    end

    test "encoder that raises on plain-reason {:error, _} falls back to inspect form" do
      defmodule AlwaysRaisingEncoder2 do
        @moduledoc false
        @behaviour ALLM.ToolResultEncoder

        @impl true
        def encode(value) when is_binary(value), do: value

        def encode(_other) do
          raise Jason.EncodeError, message: "boom"
        end
      end

      tool =
        Tool.new(
          name: "err",
          description: "",
          schema: %{},
          handler: fn _ -> {:error, {:weird, make_ref()}} end
        )

      tc = ToolCall.new(id: "c0", name: "err", arguments: %{})

      assert {:ok, [msg]} =
               ToolRunner.run_tool_calls([tc], [tool],
                 engine: engine(),
                 tool_result_encoder: AlwaysRaisingEncoder2,
                 on_tool_error: :continue
               )

      decoded = Jason.decode!(msg.content)
      assert is_binary(decoded["error"])
    end

    test "encoder raises on ToolError wrap — fallback path produces Exception.message" do
      defmodule AlwaysRaisingEncoder3 do
        @moduledoc false
        @behaviour ALLM.ToolResultEncoder

        @impl true
        def encode(value) when is_binary(value), do: value

        def encode(_other) do
          raise Protocol.UndefinedError,
            protocol: Jason.Encoder,
            value: make_ref(),
            description: "nope"
        end
      end

      tool =
        Tool.new(
          name: "t",
          description: "",
          schema: %{},
          handler: fn _ -> raise "kapow" end
        )

      tc = ToolCall.new(id: "c0", name: "t", arguments: %{})

      assert {:ok, [msg]} =
               ToolRunner.run_tool_calls([tc], [tool],
                 engine: engine(),
                 tool_result_encoder: AlwaysRaisingEncoder3,
                 on_tool_error: :continue
               )

      decoded = Jason.decode!(msg.content)
      assert is_binary(decoded["error"])
    end
  end

  # ---------------------------------------------------------------------------
  # Halt + encoder failure: encoder-raise-on-halt-result is rerouted
  # ---------------------------------------------------------------------------

  describe "halt with encoder failure" do
    test "handler {:halt, reason, non_encodable_ref} routes encoder failure through on_tool_error" do
      ref = make_ref()

      tool =
        Tool.new(
          name: "bad_halt",
          description: "",
          schema: %{},
          handler: fn _ -> {:halt, :done, ref} end
        )

      tc = ToolCall.new(id: "c0", name: "bad_halt", arguments: %{})

      # With :continue, we get an error msg (encoder-failed routed through policy)
      # and NO halt metadata since the halt was rerouted as a :continue error.
      assert {:ok, [msg]} =
               ToolRunner.run_tool_calls([tc], [tool],
                 engine: engine(),
                 on_tool_error: :continue
               )

      decoded = Jason.decode!(msg.content)
      assert Map.has_key?(decoded, "error")
    end
  end

  # ---------------------------------------------------------------------------
  # First-halt-wins across parallel halting handlers
  # ---------------------------------------------------------------------------

  describe "first-halt-wins" do
    test "earliest input-index halt metadata wins when multiple handlers halt" do
      # Both tools halt; index 0 should win.
      tool_a =
        Tool.new(
          name: "a",
          description: "",
          schema: %{},
          handler: fn _ -> {:halt, :first_halt, %{}} end
        )

      tool_b =
        Tool.new(
          name: "b",
          description: "",
          schema: %{},
          handler: fn _ -> {:halt, :second_halt, %{}} end
        )

      calls = [
        ToolCall.new(id: "a", name: "a", arguments: %{}),
        ToolCall.new(id: "b", name: "b", arguments: %{})
      ]

      assert {:ok, _msgs, meta} =
               ToolRunner.run_tool_calls(calls, [tool_a, tool_b], engine: engine())

      assert meta.halted_reason == :first_halt
      assert meta.halt_tool_call_id == "a"
    end
  end

  # ---------------------------------------------------------------------------
  # Invalid-return fallback (custom executor returns something unexpected)
  # ---------------------------------------------------------------------------

  describe "invalid-return dispatch fallback" do
    test "custom executor returning an unexpected shape is wrapped as :invalid_return" do
      defmodule WeirdExecutor do
        @moduledoc false
        @behaviour ALLM.ToolExecutor

        @impl true
        def execute(%Tool{}, _args, _opts), do: :totally_unexpected
      end

      tool = echo_tool()
      tc = echo_call("c0")

      assert {:ok, [msg]} =
               ToolRunner.run_tool_calls([tc], [tool],
                 engine: engine(),
                 tool_executor: WeirdExecutor,
                 on_tool_error: :continue
               )

      decoded = Jason.decode!(msg.content)
      assert decoded["error"] =~ "invalid_return"
    end
  end

  # ---------------------------------------------------------------------------
  # Handler exit (non-timeout) via zip_input_on_exit path
  # ---------------------------------------------------------------------------

  describe "handler exit" do
    test "handler calling exit/1 results in %ToolError{reason: :handler_exit} via executor catch" do
      # Note: the default executor catches `:exit` as :handler_exit (via catch),
      # so this surfaces at the executor boundary, not the async_stream exit
      # boundary. Still exercises the route_error path for %ToolError{}s.
      tool =
        Tool.new(
          name: "exiter",
          description: "",
          schema: %{},
          handler: fn _ -> exit(:goodbye) end
        )

      tc = ToolCall.new(id: "c0", name: "exiter", arguments: %{})

      # Streaming variant exposes the %ToolError{} directly on
      # :tool_execution_completed, so we assert the reason there rather than
      # relying on the encoded error string.
      events =
        [tc]
        |> ToolRunner.stream_tool_calls([tool], engine: engine(), on_tool_error: :continue)
        |> Enum.to_list()

      assert Enum.any?(events, fn
               {:tool_execution_completed, %{result: {:error, %ToolError{reason: :handler_exit}}}} ->
                 true

               _ ->
                 false
             end)

      assert {:ok, [msg]} =
               ToolRunner.run_tool_calls([tc], [tool],
                 engine: engine(),
                 on_tool_error: :continue
               )

      decoded = Jason.decode!(msg.content)
      assert Map.has_key?(decoded, "error")
    end
  end

  # ---------------------------------------------------------------------------
  # Messages returned are plain, serializable structs
  # ---------------------------------------------------------------------------

  describe "returned messages are plain serializable structs" do
    test "%Message{role: :tool} has metadata: %{} and no PIDs/refs" do
      tc = echo_call("c0")

      assert {:ok, [msg]} =
               ToolRunner.run_tool_calls([tc], [echo_tool()], engine: engine())

      assert %Message{role: :tool, tool_call_id: "c0", metadata: %{}} = msg
      # Round-trip via ETF to confirm no non-serializable terms.
      assert msg == msg |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 7: on_tool_error function form
  # ---------------------------------------------------------------------------

  defp boom_tool do
    Tool.new(
      name: "boom",
      description: "",
      schema: %{},
      handler: fn _ -> {:error, :bad_arg} end
    )
  end

  defp boom_call(id), do: ToolCall.new(id: id, name: "boom", arguments: %{})

  describe "on_tool_error function form — {:continue, replacement}" do
    test "encoded replacement is the tool message content; batch continues" do
      tc = boom_call("c0")

      assert {:ok, [msg]} =
               ToolRunner.run_tool_calls([tc], [boom_tool()],
                 engine: engine(),
                 on_tool_error: fn _tc, _err -> {:continue, %{fallback: "ok"}} end
               )

      assert msg.tool_call_id == "c0"
      assert Jason.decode!(msg.content) == %{"fallback" => "ok"}
    end

    test "function receives (tool_call, error_term)" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      tc = boom_call("c0")

      record = fn t, err ->
        Agent.update(agent, fn calls -> calls ++ [{t, err}] end)
        {:continue, %{}}
      end

      assert {:ok, [_msg]} =
               ToolRunner.run_tool_calls([tc], [boom_tool()],
                 engine: engine(),
                 on_tool_error: record
               )

      [{recv_tc, recv_err}] = Agent.get(agent, & &1)
      assert recv_tc.id == "c0"
      assert recv_tc.name == "boom"
      # error_term is the raw error (atom from `{:error, :bad_arg}`) or a %ToolError{}.
      assert recv_err == :bad_arg or match?(%ToolError{}, recv_err)
    end
  end

  describe "on_tool_error function form — :halt" do
    test "batch drains; halt metadata returned with :tool_error" do
      tc = boom_call("c0")

      assert {:ok, [msg], meta} =
               ToolRunner.run_tool_calls([tc], [boom_tool()],
                 engine: engine(),
                 on_tool_error: fn _tc, _err -> :halt end
               )

      assert meta.halted_reason == :tool_error
      assert meta.halt_tool_call_id == "c0"
      assert msg.tool_call_id == "c0"
    end
  end

  describe "on_tool_error function form — encoder failure on replacement" do
    test "non-encodable replacement → %ToolError{:encoding_failed} routed as :halt (no recursion)" do
      tc = boom_call("c0")

      assert {:ok, [msg], meta} =
               ToolRunner.run_tool_calls([tc], [boom_tool()],
                 engine: engine(),
                 on_tool_error: fn _tc, _err -> {:continue, make_ref()} end
               )

      assert meta.halted_reason == :tool_error
      assert meta.halt_tool_call_id == "c0"
      decoded = Jason.decode!(msg.content)
      assert Map.has_key?(decoded, "error")
    end
  end

  describe "on_tool_error function form — invalid return" do
    test "non-{:continue, _}, non-:halt return wrapped as %ToolError{:invalid_return} routed :halt" do
      tc = boom_call("c0")

      assert {:ok, [msg], meta} =
               ToolRunner.run_tool_calls([tc], [boom_tool()],
                 engine: engine(),
                 on_tool_error: fn _tc, _err -> :something_else end
               )

      assert meta.halted_reason == :tool_error
      assert meta.halt_tool_call_id == "c0"
      decoded = Jason.decode!(msg.content)
      assert Map.has_key?(decoded, "error")
    end
  end

  describe "on_tool_error function form — function raises" do
    test "raise caught; routed :halt with metadata.on_tool_error_exception" do
      tc = boom_call("c0")

      assert {:ok, [msg], meta} =
               ToolRunner.run_tool_calls([tc], [boom_tool()],
                 engine: engine(),
                 on_tool_error: fn _tc, _err -> raise "oops" end
               )

      assert meta.halted_reason == :tool_error
      assert msg.tool_call_id == "c0"

      # Phase 7 design Non-obvious Decision #8: the captured exception is
      # lifted into the top-level halt_metadata so the chat layer can read
      # it directly from `step.metadata` without fishing through tool_results.
      assert %RuntimeError{message: "oops"} = meta.on_tool_error_exception
    end

    test "single-invocation invariant (Agent counter)" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      tc = boom_call("c0")

      counting_fn = fn _tc, _err ->
        Agent.update(counter, &(&1 + 1))
        raise "oops"
      end

      assert {:ok, [_msg], _meta} =
               ToolRunner.run_tool_calls([tc], [boom_tool()],
                 engine: engine(),
                 on_tool_error: counting_fn
               )

      # MUST be exactly 1 — proves recursion-avoidance call path is correct.
      assert Agent.get(counter, & &1) == 1
    end

    test "single-invocation invariant for invalid-return path" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      tc = boom_call("c0")

      counting_fn = fn _tc, _err ->
        Agent.update(counter, &(&1 + 1))
        :something_invalid
      end

      assert {:ok, [_msg], _meta} =
               ToolRunner.run_tool_calls([tc], [boom_tool()],
                 engine: engine(),
                 on_tool_error: counting_fn
               )

      assert Agent.get(counter, & &1) == 1
    end

    test "single-invocation invariant for encoder-failure-on-replacement path" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      tc = boom_call("c0")

      counting_fn = fn _tc, _err ->
        Agent.update(counter, &(&1 + 1))
        {:continue, make_ref()}
      end

      assert {:ok, [_msg], _meta} =
               ToolRunner.run_tool_calls([tc], [boom_tool()],
                 engine: engine(),
                 on_tool_error: counting_fn
               )

      assert Agent.get(counter, & &1) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 7: reserved-halt-atom rejection (spec §5.2)
  # ---------------------------------------------------------------------------

  describe "reserved-halt-atom rejection" do
    test "@reserved_halt_atoms equals exactly the spec §5.2 set" do
      assert ToolRunner.__reserved_halt_atoms__() ==
               [:ask_user, :max_turns, :halt_when, :tool_error, :cancelled, :completed]
    end

    for reserved <- [:ask_user, :max_turns, :halt_when, :tool_error, :cancelled, :completed] do
      @reserved reserved

      test "handler {:halt, #{inspect(reserved)}, _} → on_tool_error :continue encodes error with metadata.reserved_halt_atom" do
        tool =
          Tool.new(
            name: "x",
            description: "",
            schema: %{},
            handler: fn _ -> {:halt, @reserved, %{r: 1}} end
          )

        tc = ToolCall.new(id: "c0", name: "x", arguments: %{})

        assert {:ok, [msg]} =
                 ToolRunner.run_tool_calls([tc], [tool],
                   engine: engine(),
                   on_tool_error: :continue
                 )

        decoded = Jason.decode!(msg.content)
        assert Map.has_key?(decoded, "error")
      end

      test "handler {:halt, #{inspect(reserved)}, _} → on_tool_error :halt halts batch with :tool_error" do
        tool =
          Tool.new(
            name: "x",
            description: "",
            schema: %{},
            handler: fn _ -> {:halt, @reserved, %{r: 1}} end
          )

        tc = ToolCall.new(id: "c0", name: "x", arguments: %{})

        assert {:ok, [_msg], meta} =
                 ToolRunner.run_tool_calls([tc], [tool],
                   engine: engine(),
                   on_tool_error: :halt
                 )

        assert meta.halted_reason == :tool_error
      end

      test "handler {:halt, #{inspect(reserved)}, _} → on_tool_error fun receives ToolError with metadata.reserved_halt_atom" do
        tool =
          Tool.new(
            name: "x",
            description: "",
            schema: %{},
            handler: fn _ -> {:halt, @reserved, %{r: 1}} end
          )

        tc = ToolCall.new(id: "c0", name: "x", arguments: %{})
        {:ok, agent} = Agent.start_link(fn -> nil end)
        reserved = @reserved

        record = fn _tc, err ->
          Agent.update(agent, fn _ -> err end)
          {:continue, %{}}
        end

        assert {:ok, [_msg]} =
                 ToolRunner.run_tool_calls([tc], [tool],
                   engine: engine(),
                   on_tool_error: record
                 )

        captured = Agent.get(agent, & &1)
        assert %ToolError{reason: :invalid_return, metadata: meta} = captured
        assert meta.reserved_halt_atom == reserved
      end
    end

    test "non-reserved atom continues to produce halt with the user-supplied atom" do
      tool =
        Tool.new(
          name: "x",
          description: "",
          schema: %{},
          handler: fn _ -> {:halt, :plan_submitted, %{r: 1}} end
        )

      tc = ToolCall.new(id: "c0", name: "x", arguments: %{})

      assert {:ok, [_msg], meta} =
               ToolRunner.run_tool_calls([tc], [tool], engine: engine())

      assert meta.halted_reason == :plan_submitted
      assert meta.halt_result == %{r: 1}
    end
  end
end
