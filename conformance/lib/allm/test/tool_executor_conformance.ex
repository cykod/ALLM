defmodule ALLM.Test.ToolExecutorConformance do
  @moduledoc """
  Injectable conformance suite for `ALLM.ToolExecutor` implementations.

  ## Installation

      {:allm_conformance, "~> 0.2", only: :test}

  ## Usage

      defmodule MyExecutorTest do
        use ExUnit.Case, async: true
        use ALLM.Test.ToolExecutorConformance, executor: MyExecutor
      end

  Injects a `describe "ALLM.ToolExecutor conformance (MyExecutor)"` block
  with 11 deterministic cases covering every
  `ALLM.Tool.handler_result/0` shape, every executor-originated
  `ALLM.Error.ToolError` reason atom that the default executor produces
  (`:handler_raised`, `:handler_exit`, `:invalid_return`, `:not_found`),
  and the arity-2 handler `opts`-verbatim invariant (executor must pass
  the full `opts` keyword — `:context`, `:session_id`, `:request_id`,
  `:tool_call`, `:engine` — through unchanged).

  `:timeout` and `:encoding_failed` are outside the default executor's
  responsibilities (`:timeout` lands in Phase 6's `ALLM.ToolRunner`;
  `:encoding_failed` is produced by the encoder, not the executor). The
  harness does not inject cases for them.
  """

  use ExUnit.CaseTemplate

  @case_count 11

  @doc """
  Return the number of cases injected by `using/1`.
  """
  @spec case_count() :: pos_integer()
  def case_count, do: @case_count

  using opts do
    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote location: :keep do
      @__allm_conformance_executor__ Keyword.fetch!(unquote(opts), :executor)

      describe "ALLM.ToolExecutor conformance (#{inspect(@__allm_conformance_executor__)})" do
        alias ALLM.Error.ToolError
        alias ALLM.Tool

        test "handler {:ok, _} passes through unchanged" do
          tool =
            Tool.new(
              name: "ok",
              description: "",
              schema: %{},
              handler: fn _ -> {:ok, 42} end
            )

          assert @__allm_conformance_executor__.execute(tool, %{}, []) == {:ok, 42}
        end

        test "handler {:error, :biz} passes through unchanged (handler-originated)" do
          tool =
            Tool.new(
              name: "biz",
              description: "",
              schema: %{},
              handler: fn _ -> {:error, :biz} end
            )

          result = @__allm_conformance_executor__.execute(tool, %{}, [])
          assert result == {:error, :biz}
          refute match?({:error, %ToolError{}}, result)
        end

        test "handler {:ask_user, question} passes through unchanged" do
          tool =
            Tool.new(
              name: "ask",
              description: "",
              schema: %{},
              handler: fn _ -> {:ask_user, "which one?"} end
            )

          assert @__allm_conformance_executor__.execute(tool, %{}, []) ==
                   {:ask_user, "which one?"}
        end

        test "handler {:ask_user, question, opts} passes through unchanged" do
          tool =
            Tool.new(
              name: "ask",
              description: "",
              schema: %{},
              handler: fn _ -> {:ask_user, "which one?", multi: true} end
            )

          assert @__allm_conformance_executor__.execute(tool, %{}, []) ==
                   {:ask_user, "which one?", multi: true}
        end

        test "handler {:halt, reason, result} passes through unchanged" do
          tool =
            Tool.new(
              name: "plan",
              description: "",
              schema: %{},
              handler: fn _ -> {:halt, :done, :ok} end
            )

          assert @__allm_conformance_executor__.execute(tool, %{}, []) ==
                   {:halt, :done, :ok}
        end

        test "handler raise → {:error, %ToolError{reason: :handler_raised}}" do
          tool =
            Tool.new(
              name: "boom",
              description: "",
              schema: %{},
              handler: fn _ -> raise "kaboom" end
            )

          assert {:error, %ToolError{reason: :handler_raised}} =
                   @__allm_conformance_executor__.execute(tool, %{}, [])
        end

        test "handler exit → {:error, %ToolError{reason: :handler_exit}}" do
          tool =
            Tool.new(
              name: "exiter",
              description: "",
              schema: %{},
              handler: fn _ -> exit(:bye) end
            )

          assert {:error, %ToolError{reason: :handler_exit}} =
                   @__allm_conformance_executor__.execute(tool, %{}, [])
        end

        test "handler throw → {:error, %ToolError{reason: :handler_raised}} (normalized)" do
          tool =
            Tool.new(
              name: "thrower",
              description: "",
              schema: %{},
              handler: fn _ -> throw(:oops) end
            )

          assert {:error, %ToolError{reason: :handler_raised}} =
                   @__allm_conformance_executor__.execute(tool, %{}, [])
        end

        test "handler invalid return → {:error, %ToolError{reason: :invalid_return}}" do
          tool =
            Tool.new(
              name: "bare",
              description: "",
              schema: %{},
              handler: fn _ -> :bare_atom end
            )

          assert {:error, %ToolError{reason: :invalid_return}} =
                   @__allm_conformance_executor__.execute(tool, %{}, [])
        end

        test "%Tool{handler: nil} → {:error, %ToolError{reason: :not_found}}" do
          tool = Tool.new(name: "nop", description: "", schema: %{})
          assert tool.handler == nil

          assert {:error, %ToolError{reason: :not_found}} =
                   @__allm_conformance_executor__.execute(tool, %{}, [])
        end

        test "arity-2 handler receives opts verbatim (:context, :session_id, :request_id, :tool_call, :engine)" do
          # Design case 10: executor must pass the full opts keyword
          # through to an arity-2 handler unchanged. This locks the
          # invariant at the behaviour level so any custom executor is
          # held to the same contract.
          test_pid = self()
          ref = make_ref()

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

          assert @__allm_conformance_executor__.execute(tool, %{"x" => 1}, opts) ==
                   {:ok, :recorded}

          assert_receive {^ref, %{"x" => 1}, received_opts}
          assert Keyword.get(received_opts, :context) == %{user: "alice"}
          assert Keyword.get(received_opts, :session_id) == "sess_1"
          assert Keyword.get(received_opts, :request_id) == "req_1"
          assert Keyword.get(received_opts, :tool_call) == %{id: "call_1"}
          assert Keyword.get(received_opts, :engine) == :engine_placeholder
        end
      end
    end
  end
end
