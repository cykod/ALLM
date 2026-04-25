defmodule ALLM.DepFreeTest do
  @moduledoc """
  Phase 9.4 dep-free smoke test — exercises a representative subset of
  the public surface with `Application.put_env(:allm,
  :force_capability_absent, true)` set, proving every path no-ops the
  optional `LLMDB` integration. Per Phase 9.4 design Decision #5 and the
  Definition-of-Done dep-free row.

  `async: false` because `Application.put_env/3` mutates global state.
  """

  use ExUnit.Case, async: false

  alias ALLM.{Capability, Message, Providers.Fake, Request, Session, Thread, Usage}
  alias ALLM.Test.FakeFixtures

  setup do
    Application.put_env(:allm, :force_capability_absent, true)
    on_exit(fn -> Application.delete_env(:allm, :force_capability_absent) end)
    :ok
  end

  describe "Capability helpers in dep-free mode" do
    test "catalog_loaded?/0 returns false under override" do
      assert Capability.catalog_loaded?() == false
    end

    test "preflight/2 is a no-op pass-through under override" do
      ref =
        ALLM.ModelRef.new(
          provider: :local,
          id: "no-tools",
          capabilities: %{tools: %{enabled: false}, json_native: false}
        )

      tool = ALLM.Tool.new(name: "echo", description: "x", schema: %{})

      req =
        Request.new([%Message{role: :user, content: "hi"}],
          tools: [tool],
          response_format: %{type: :json_schema, name: "x", schema: %{}, strict: true}
        )

      assert Capability.preflight(ref, req) == :ok
    end

    test "populate_costs/2 returns input usage unchanged under override" do
      ref =
        ALLM.ModelRef.new(
          provider: :openai,
          id: "x",
          pricing: %{input: 0.15, output: 0.6}
        )

      usage = %Usage{input_tokens: 1_000, output_tokens: 500}
      assert Capability.populate_costs(usage, ref) == usage
    end

    test "select/1 returns {:error, :catalog_not_loaded} under override" do
      assert Capability.select(require: [:tools]) == {:error, :catalog_not_loaded}
    end
  end

  describe "public Layer C/D paths under override" do
    test "ALLM.generate/3 happy path runs without raising and without populating costs" do
      engine =
        FakeFixtures.engine([{:text, "hi"}, {:finish, :stop}],
          engine_opts: [model: "openai:gpt-4.1-mini"]
        )

      req = ALLM.request([ALLM.user("say hi")])

      assert {:ok, response} = ALLM.generate(engine, req)
      assert response.output_text == "hi"
      # Cost fields stay nil because populate_costs/2 no-ops under override
      assert response.usage.input_cost == nil
      assert response.usage.output_cost == nil
      assert response.usage.total_cost == nil
    end

    test "ALLM.chat/3 happy path runs without raising under override" do
      engine =
        FakeFixtures.engine_with_scripts(
          [
            [{:text, "hi"}, {:finish, :stop}]
          ],
          engine_opts: [model: "openai:gpt-4.1-mini"]
        )

      thread = Thread.new() |> Thread.add_message(%Message{role: :user, content: "say hi"})

      assert {:ok, result} = ALLM.chat(engine, thread)
      assert result.final_response.output_text == "hi"
    end

    test "ALLM.Session.start/3 happy path runs without raising under override" do
      engine =
        FakeFixtures.engine_with_scripts(
          [
            [{:text, "hi"}, {:finish, :stop}]
          ],
          engine_opts: [model: "openai:gpt-4.1-mini"]
        )

      thread = Thread.new() |> Thread.add_message(%Message{role: :user, content: "say hi"})

      result = Session.start(engine, thread)
      session = elem(result, 1)
      assert :ok == elem(result, 0)
      assert %Session{} = session
      assert session.status in [:idle, :running, :completed, :awaiting_tools, :awaiting_user]
    end

    test "retry happy path: Fake adapter retry round-trip works under override" do
      # retry_until_call: 1 => succeeds on first call, no actual retry needed,
      # which keeps this assertion focused on dep-free observability.
      engine =
        FakeFixtures.engine([{:text, "ok"}, {:finish, :stop}],
          adapter_opts: [retry_until_call: 1],
          engine_opts: [model: "openai:gpt-4.1-mini"]
        )

      assert {:ok, response} = ALLM.generate(engine, ALLM.request([ALLM.user("hi")]))
      assert response.finish_reason == :stop
    end
  end

  describe "reversibility" do
    test "after on_exit clears the override, catalog_loaded?/0 returns to true" do
      # Inside this test the setup already set the override, so we observe it,
      # then clear it manually and assert reversibility (mirrors what on_exit
      # does post-suite).
      assert Capability.catalog_loaded?() == false
      Application.delete_env(:allm, :force_capability_absent)
      assert Capability.catalog_loaded?() == true
    end
  end

  # Reference Fake to keep its alias used (suppresses Credo's unused alias).
  @doc false
  def _refs, do: Fake
end
