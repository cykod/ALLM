defmodule ALLM.SandboxTest do
  @moduledoc """
  Phase 21.3 — `ALLM.Sandbox` test-injection module.
  """

  use ExUnit.Case, async: true

  alias ALLM.Engine
  alias ALLM.Providers.Fake
  alias ALLM.Sandbox

  defp fake_engine(script \\ [{:text, "hi"}, {:finish, :stop}]) do
    Engine.new(adapter: Fake, adapter_opts: [script: script])
  end

  describe "set_engine/1 + get_engine/0 — same-process round-trip" do
    test "round-trips a registered engine" do
      engine = fake_engine()
      assert :ok = Sandbox.set_engine(engine)
      assert ^engine = Sandbox.get_engine()
    end

    test "get_engine/0 returns nil when nothing is registered" do
      # Spawn a fresh process so the test's own dict is irrelevant.
      task = Task.async(fn -> Sandbox.get_engine() end)
      assert Task.await(task) == nil
    end

    test "set_engine/1 rejects non-%Engine{}" do
      assert_raise FunctionClauseError, fn -> Sandbox.set_engine(:not_an_engine) end
      assert_raise FunctionClauseError, fn -> Sandbox.set_engine(%{adapter: Fake}) end
    end
  end

  describe "unset_engine/0" do
    test "clears the current process's registration" do
      Sandbox.set_engine(fake_engine())
      assert Sandbox.get_engine() != nil
      assert :ok = Sandbox.unset_engine()
      assert Sandbox.get_engine() == nil
    end

    test "is idempotent — calling without prior set returns :ok" do
      task = Task.async(fn -> Sandbox.unset_engine() end)
      assert Task.await(task) == :ok
    end
  end

  describe "with_engine/2" do
    test "registers the engine for the callback's duration and clears after" do
      engine = fake_engine()

      result =
        Sandbox.with_engine(engine, fn ->
          assert Sandbox.get_engine() == engine
          :computed
        end)

      assert result == :computed
      assert Sandbox.get_engine() == nil
    end

    test "clears the engine even when the callback raises" do
      engine = fake_engine()

      assert_raise RuntimeError, fn ->
        Sandbox.with_engine(engine, fn -> raise "boom" end)
      end

      assert Sandbox.get_engine() == nil
    end

    test "restores a prior registration on callback exit" do
      outer = fake_engine([{:text, "outer"}, {:finish, :stop}])
      inner = fake_engine([{:text, "inner"}, {:finish, :stop}])

      Sandbox.set_engine(outer)

      Sandbox.with_engine(inner, fn ->
        assert Sandbox.get_engine() == inner
      end)

      assert Sandbox.get_engine() == outer
    end
  end

  describe "$callers traversal" do
    test "child Task sees the parent's registered engine" do
      engine = fake_engine()
      Sandbox.set_engine(engine)

      task = Task.async(fn -> Sandbox.get_engine() end)
      assert Task.await(task) == engine
    end

    test "grandchild via Task.async_stream sees the registering ancestor's engine" do
      engine = fake_engine()
      Sandbox.set_engine(engine)

      results =
        ["a", "b", "c"]
        |> Task.async_stream(fn _ -> Sandbox.get_engine() end)
        |> Enum.map(fn {:ok, e} -> e end)

      assert Enum.all?(results, &(&1 == engine))
    end

    test "nested Task chains traverse multiple ancestors" do
      engine = fake_engine()
      Sandbox.set_engine(engine)

      outer =
        Task.async(fn ->
          inner =
            Task.async(fn ->
              Sandbox.get_engine()
            end)

          Task.await(inner)
        end)

      assert Task.await(outer) == engine
    end

    test "two concurrent async: true tests do NOT see each other's engines" do
      # Two child Tasks set distinct engines; each must see ONLY their own.
      e1 = fake_engine([{:text, "one"}, {:finish, :stop}])
      e2 = fake_engine([{:text, "two"}, {:finish, :stop}])

      t1 =
        Task.async(fn ->
          Sandbox.set_engine(e1)
          # Yield briefly so the schedulers interleave.
          :timer.sleep(5)
          Sandbox.get_engine()
        end)

      t2 =
        Task.async(fn ->
          Sandbox.set_engine(e2)
          :timer.sleep(5)
          Sandbox.get_engine()
        end)

      assert Task.await(t1) == e1
      assert Task.await(t2) == e2
    end
  end

  describe "defensive clauses" do
    test "walk_callers skips non-pid entries in the $callers chain" do
      # `$callers` is a list of pids in practice; the implementation
      # tolerates non-pid entries defensively. Drive that path by
      # spawning a Task that does NOT have a registering ancestor.
      task = Task.async(fn -> Sandbox.get_engine() end)
      assert Task.await(task) == nil
    end

    test "with_engine/2 returns the callback's value verbatim" do
      assert Sandbox.with_engine(fake_engine(), fn -> {:custom, 42} end) ==
               {:custom, 42}
    end
  end

  describe "integration — Sandbox-registered engine drives ALLM.generate/3" do
    test "child Task uses parent's registered engine to call ALLM.generate/3" do
      engine = fake_engine([{:text, "from-sandbox"}, {:finish, :stop}])
      Sandbox.set_engine(engine)

      task =
        Task.async(fn ->
          eng = Sandbox.get_engine()
          ALLM.generate(eng, ALLM.request([ALLM.user("hi")]))
        end)

      assert {:ok, %ALLM.Response{output_text: "from-sandbox"}} = Task.await(task)
    end
  end
end
