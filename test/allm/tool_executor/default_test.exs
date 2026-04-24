defmodule ALLM.ToolExecutor.DefaultTest do
  @moduledoc """
  Unit tests for `ALLM.ToolExecutor.Default`.

  Covers the two sides of the handler-originated-vs-executor-originated
  error distinction (Non-obvious Decision #3): handler-returned
  `{:error, _}` values pass through unchanged, while raises/exits/throws/
  invalid returns/nil handlers become `%ALLM.Error.ToolError{}`.

  The conformance-suite plug-in is wired up in Sub-phase 3.5 (Batch 3):

      use ALLM.Test.ToolExecutorConformance, executor: ALLM.ToolExecutor.Default
  """

  use ExUnit.Case, async: true

  alias ALLM.Error.ToolError
  alias ALLM.Tool
  alias ALLM.ToolExecutor.Default

  doctest Default

  # ---------------------------------------------------------------------------
  # Happy path — arity-1 handlers
  # ---------------------------------------------------------------------------

  describe "arity-1 handler happy path" do
    test "{:ok, value} passes through unchanged" do
      tool = Tool.new(name: "t", description: "", schema: %{}, handler: fn _ -> {:ok, 42} end)
      assert Default.execute(tool, %{}, []) == {:ok, 42}
    end

    test "handler-returned {:error, reason} passes through unchanged (NOT converted)" do
      tool =
        Tool.new(
          name: "lookup",
          description: "",
          schema: %{},
          handler: fn _ -> {:error, :user_not_found} end
        )

      result = Default.execute(tool, %{}, [])
      assert result == {:error, :user_not_found}
      refute match?({:error, %ToolError{}}, result)
    end

    test "{:ask_user, question} passes through unchanged" do
      tool =
        Tool.new(
          name: "ask",
          description: "",
          schema: %{},
          handler: fn _ -> {:ask_user, "which one?"} end
        )

      assert Default.execute(tool, %{}, []) == {:ask_user, "which one?"}
    end

    test "{:ask_user, question, opts} passes through unchanged" do
      tool =
        Tool.new(
          name: "ask",
          description: "",
          schema: %{},
          handler: fn _ -> {:ask_user, "which one?", multi: true} end
        )

      assert Default.execute(tool, %{}, []) == {:ask_user, "which one?", multi: true}
    end

    test "{:halt, reason, result} passes through unchanged" do
      tool =
        Tool.new(
          name: "plan",
          description: "",
          schema: %{},
          handler: fn _ -> {:halt, :plan_submitted, %{steps: 3}} end
        )

      assert Default.execute(tool, %{}, []) == {:halt, :plan_submitted, %{steps: 3}}
    end
  end

  # ---------------------------------------------------------------------------
  # Happy path — arity-2 handlers
  # ---------------------------------------------------------------------------

  describe "arity-2 handler happy path" do
    test "handler receives arguments and opts (all §5.2 keys preserved)" do
      ref = make_ref()
      test_pid = self()

      handler = fn args, opts ->
        send(test_pid, {ref, args, opts})
        {:ok, :recorded}
      end

      tool = Tool.new(name: "t", description: "", schema: %{}, handler: handler)

      opts = [
        context: %{user: "alice"},
        session_id: "sess_1",
        request_id: "req_1",
        tool_call: %{id: "call_1"},
        engine: :engine_placeholder
      ]

      assert Default.execute(tool, %{"x" => 1}, opts) == {:ok, :recorded}
      assert_receive {^ref, %{"x" => 1}, received_opts}
      assert Keyword.get(received_opts, :context) == %{user: "alice"}
      assert Keyword.get(received_opts, :session_id) == "sess_1"
      assert Keyword.get(received_opts, :request_id) == "req_1"
      assert Keyword.get(received_opts, :tool_call) == %{id: "call_1"}
      assert Keyword.get(received_opts, :engine) == :engine_placeholder
    end

    test "arity-2 {:ok, value} passes through unchanged" do
      tool =
        Tool.new(
          name: "t",
          description: "",
          schema: %{},
          handler: fn args, _opts -> {:ok, Map.put(args, "extra", true)} end
        )

      assert Default.execute(tool, %{"a" => 1}, []) ==
               {:ok, %{"a" => 1, "extra" => true}}
    end
  end

  # ---------------------------------------------------------------------------
  # Executor-originated errors — raises, exits, throws, invalid returns, nil
  # ---------------------------------------------------------------------------

  describe "executor-originated errors" do
    test "RuntimeError raise → %ToolError{reason: :handler_raised, cause: %RuntimeError{}}" do
      tool =
        Tool.new(
          name: "boomer",
          description: "",
          schema: %{},
          handler: fn _ -> raise "kaboom" end
        )

      assert {:error, %ToolError{reason: :handler_raised} = err} = Default.execute(tool, %{}, [])
      assert %RuntimeError{message: "kaboom"} = err.cause
      assert err.tool_name == "boomer"
    end

    test "ArgumentError raise → %ToolError{reason: :handler_raised, cause: %ArgumentError{}}" do
      tool =
        Tool.new(
          name: "bad_arg",
          description: "",
          schema: %{},
          handler: fn _ -> raise ArgumentError, "nope" end
        )

      assert {:error, %ToolError{reason: :handler_raised} = err} = Default.execute(tool, %{}, [])
      assert %ArgumentError{message: "nope"} = err.cause
      assert err.tool_name == "bad_arg"
    end

    test "exit/1 → %ToolError{reason: :handler_exit, cause: _exit_term}" do
      tool =
        Tool.new(
          name: "exiter",
          description: "",
          schema: %{},
          handler: fn _ -> exit(:bye) end
        )

      assert {:error, %ToolError{reason: :handler_exit} = err} = Default.execute(tool, %{}, [])
      assert err.cause == :bye
      assert err.tool_name == "exiter"
    end

    test "throw/1 of a tagged tuple → %ToolError{reason: :handler_raised, cause: {:throw, _}}" do
      tool =
        Tool.new(
          name: "thrower",
          description: "",
          schema: %{},
          handler: fn _ -> throw({:early_exit, :oops}) end
        )

      assert {:error, %ToolError{reason: :handler_raised} = err} = Default.execute(tool, %{}, [])
      assert err.cause == {:throw, {:early_exit, :oops}}
      assert err.tool_name == "thrower"
    end

    test "bare atom return → %ToolError{reason: :invalid_return, cause: :bare}" do
      tool =
        Tool.new(
          name: "bare",
          description: "",
          schema: %{},
          handler: fn _ -> :bare end
        )

      assert {:error, %ToolError{reason: :invalid_return, cause: :bare} = err} =
               Default.execute(tool, %{}, [])

      assert err.tool_name == "bare"
    end

    test "bare map return → %ToolError{reason: :invalid_return, cause: map}" do
      tool =
        Tool.new(
          name: "mapper",
          description: "",
          schema: %{},
          handler: fn _ -> %{foo: :bar} end
        )

      assert {:error, %ToolError{reason: :invalid_return, cause: %{foo: :bar}}} =
               Default.execute(tool, %{}, [])
    end

    test "%Tool{handler: nil} → %ToolError{reason: :not_found}" do
      tool = Tool.new(name: "nop", description: "", schema: %{})
      assert tool.handler == nil

      assert {:error, %ToolError{reason: :not_found, tool_name: "nop"}} =
               Default.execute(tool, %{}, [])
    end
  end

  # ---------------------------------------------------------------------------
  # Invalid handler arity / shape — bypass Tool.new/1's arity gate
  # ---------------------------------------------------------------------------

  describe "invalid handler shape (bypassing Tool.new/1)" do
    test "arity-3 handler raises ArgumentError" do
      # Construct the struct directly to skip Tool.new/1's arity gate.
      tool = %Tool{
        name: "arity3",
        description: "",
        schema: %{},
        handler: fn _a, _b, _c -> {:ok, :never} end,
        metadata: %{}
      }

      assert_raise ArgumentError, fn -> Default.execute(tool, %{}, []) end
    end

    test "MFA-tuple handler raises FunctionClauseError" do
      tool = %Tool{
        name: "mfa",
        description: "",
        schema: %{},
        handler: {Kernel, :length},
        metadata: %{}
      }

      assert_raise FunctionClauseError, fn -> Default.execute(tool, %{}, []) end
    end
  end

  # Conformance suite plug-in (Sub-phase 3.5): certify the default
  # executor against every case in the shipped conformance harness.
  use ALLM.Test.ToolExecutorConformance, executor: ALLM.ToolExecutor.Default
end
