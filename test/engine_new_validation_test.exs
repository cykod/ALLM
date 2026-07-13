defmodule EngineNewValidationTest do
  use ExUnit.Case, async: true

  # Phase 1 (§6.4): `Engine.new/1` fails fast with `ArgumentError` on a
  # non-module value for a module-typed field, instead of silently constructing
  # a booby-trapped engine that crashes at `tool_runner.ex`.

  describe "new/1 module-field validation" do
    test "tool_executor as {ALLM.ToolExecutor.Default, tools: %{}} raises ArgumentError (the guide footgun)" do
      assert_raise ArgumentError, ~r/:tool_executor/, fn ->
        ALLM.Engine.new(tool_executor: {ALLM.ToolExecutor.Default, tools: %{}})
      end
    end

    test "adapter as a tuple raises ArgumentError naming :adapter" do
      assert_raise ArgumentError, ~r/:adapter/, fn ->
        ALLM.Engine.new(adapter: {Foo, []})
      end
    end

    test "tool_result_encoder as a string raises ArgumentError" do
      assert_raise ArgumentError, ~r/:tool_result_encoder/, fn ->
        ALLM.Engine.new(tool_result_encoder: "JSON")
      end
    end

    test "image_adapter as a map raises ArgumentError" do
      assert_raise ArgumentError, ~r/:image_adapter/, fn ->
        ALLM.Engine.new(image_adapter: %{})
      end
    end
  end

  describe "new/1 module-field validation — good cases" do
    test "all four module fields nil constructs successfully (default engine)" do
      engine = ALLM.Engine.new()
      assert engine.adapter == nil
      assert engine.tool_executor == nil
      assert engine.tool_result_encoder == nil
      assert engine.image_adapter == nil
    end

    test "a real adapter module constructs successfully" do
      engine = ALLM.Engine.new(adapter: ALLM.Providers.Fake)
      assert engine.adapter == ALLM.Providers.Fake
    end

    test "a not-yet-loaded module atom passes (guard is is_atom/1, not Code.ensure_loaded?/1)" do
      engine = ALLM.Engine.new(adapter: :"Elixir.ALLM.NotLoadedYet")
      assert engine.adapter == :"Elixir.ALLM.NotLoadedYet"
    end
  end
end
