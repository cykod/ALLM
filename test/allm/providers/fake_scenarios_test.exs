defmodule ALLM.Providers.FakeScenariosTest do
  @moduledoc """
  Spec §31 property-style scenarios exercised directly against
  `ALLM.Providers.Fake` (Phase 4) plus the Phase 5 streaming-layer
  coverage. `mix test --only spec_31` scopes Phase 12's regression audit
  to one file.

  Active coverage after Phase 5: 6 scenarios (3 Phase 4 + 3 Phase 5).
  Remaining: 4 scenarios tagged `@tag :pending`, deferred to Phases 7/8.

  | # | Scenario | Phase |
  |---|---|---|
  | 1 | pure text streaming with `emit_text_deltas: true` (default) | 4 (active) |
  | 2 | pure text streaming with `emit_text_deltas: false` | 5 (active) |
  | 3 | parallel tool calls in one assistant turn | 4 (active) |
  | 4 | mid-stream adapter error — stream terminates with `{:error, reason}` | 4/5 (active) |
  | 5 | consumer cancellation releases the adapter's HTTP request | 5 (active — `:counters` observer) |
  | 6 | `max_turns` cap | 7 (deferred) |
  | 7 | `halt_when` fires | 7 (deferred) |
  | 8 | tool handler raises — `on_tool_error` policy | 7 (deferred) |
  | 9 | session round-trip | 8 (deferred) |
  """

  use ExUnit.Case, async: true

  @moduletag :spec_31

  alias ALLM.{Engine, Message, Request, Response}
  alias ALLM.Error.AdapterError
  alias ALLM.Providers.Fake

  # Poll a predicate until true or deadline expires. Same shape as
  # `StreamRunner`'s test helper and `StreamAdapterConformance`'s
  # `eventually` helper.
  defp wait_for(fun, timeout_ms) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(10)
        do_wait(fun, deadline)
      end
    end
  end

  defp fake_request(content \\ "x") do
    Request.new([%Message{role: :user, content: content}])
  end

  # ---------------------------------------------------------------------------
  # Phase 4 — covered scenarios
  # ---------------------------------------------------------------------------

  describe "§31 scenario: pure text streaming (emit_text_deltas default-true)" do
    test ~s(script: [{:text, "he"}, {:text, "llo"}, {:finish, :stop}] yields 5 events) do
      opts = [
        adapter_opts: [script: [{:text, "he"}, {:text, "llo"}, {:finish, :stop}]]
      ]

      assert {:ok, stream} = Fake.stream(fake_request(), opts)
      events = Enum.to_list(stream)

      assert [
               {:message_started, _},
               {:text_delta, %{delta: "he"}},
               {:text_delta, %{delta: "llo"}},
               {:text_completed, %{text: "hello"}},
               {:message_completed, _}
             ] = events
    end
  end

  describe "§31 scenario: parallel tool calls in one assistant turn" do
    test "streaming emits two tool_call_started/completed pairs" do
      opts = [
        adapter_opts: [
          script: [
            {:tool_call, id: "c1", name: "a", arguments: %{x: 1}},
            {:tool_call, id: "c2", name: "b", arguments: %{y: 2}},
            {:finish, :tool_calls}
          ]
        ]
      ]

      assert {:ok, stream} = Fake.stream(fake_request(), opts)
      events = Enum.to_list(stream)

      started = for {:tool_call_started, m} <- events, do: m.id
      completed = for {:tool_call_completed, m} <- events, do: m.id

      assert started == ["c1", "c2"]
      assert completed == ["c1", "c2"]
    end

    test "generate/2 folds into Response.tool_calls of length 2" do
      opts = [
        adapter_opts: [
          script: [
            {:tool_call, id: "c1", name: "a", arguments: %{x: 1}},
            {:tool_call, id: "c2", name: "b", arguments: %{y: 2}},
            {:finish, :tool_calls}
          ]
        ]
      ]

      assert {:ok, %Response{tool_calls: tool_calls, finish_reason: :tool_calls}} =
               Fake.generate(fake_request(), opts)

      assert length(tool_calls) == 2
      assert Enum.map(tool_calls, & &1.id) == ["c1", "c2"]
    end
  end

  describe "§31 scenario: mid-stream adapter error terminates stream" do
    test "[{:text, \"h\"}, {:error, :rate_limited}] yields {:error, %AdapterError{reason: :rate_limited}}" do
      opts = [
        adapter_opts: [script: [{:text, "h"}, {:error, :rate_limited}]]
      ]

      assert {:ok, stream} = Fake.stream(fake_request(), opts)
      events = Enum.to_list(stream)

      assert Enum.any?(
               events,
               &match?({:error, %AdapterError{reason: :rate_limited}}, &1)
             )
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 5 — newly active scenarios
  # ---------------------------------------------------------------------------

  describe "§31 scenario: pure text streaming with emit_text_deltas: false" do
    test "stream_generate/3 drops :text_delta but keeps :text_completed + :message_completed" do
      engine =
        Engine.new(
          adapter: Fake,
          adapter_opts: [script: [{:text, "hello"}, {:finish, :stop}]]
        )

      req = Request.new([%Message{role: :user, content: "x"}])

      assert {:ok, stream} = ALLM.stream_generate(engine, req, emit_text_deltas: false)
      events = Enum.to_list(stream)
      tags = Enum.map(events, &elem(&1, 0))

      refute :text_delta in tags
      assert :text_completed in tags
      assert :message_completed in tags
    end

    test "generate/3 on the same engine produces Response with output_text 'hello' (filter doesn't affect non-streaming)" do
      # Non-streaming generate/3 still reduces the full stream through
      # StreamCollector; the filter's only user-visible effect is on the
      # consumer stream ordering, not on the folded %Response{}.
      engine =
        Engine.new(
          adapter: Fake,
          adapter_opts: [script: [{:text, "hello"}, {:finish, :stop}]]
        )

      req = Request.new([%Message{role: :user, content: "x"}])

      assert {:ok, %Response{output_text: "hello", finish_reason: :stop}} =
               ALLM.generate(engine, req, emit_text_deltas: false)
    end
  end

  describe "§31 scenario: mid-stream adapter error through stream_generate/3 and generate/3" do
    test "stream_generate/3 events include terminal {:error, %AdapterError{reason: :rate_limited}}" do
      engine =
        Engine.new(
          adapter: Fake,
          adapter_opts: [script: [{:text, "partial"}, {:error, :rate_limited}]]
        )

      req = Request.new([%Message{role: :user, content: "x"}])

      assert {:ok, stream} = ALLM.stream_generate(engine, req)
      events = Enum.to_list(stream)

      assert Enum.any?(
               events,
               &match?({:error, %AdapterError{reason: :rate_limited}}, &1)
             )
    end

    test "generate/3 folds mid-stream error into %Response{finish_reason: :error, metadata: %{error: _}}" do
      engine =
        Engine.new(
          adapter: Fake,
          adapter_opts: [script: [{:text, "partial"}, {:error, :rate_limited}]]
        )

      req = Request.new([%Message{role: :user, content: "x"}])

      assert {:ok, %Response{output_text: "partial", finish_reason: :error, metadata: meta}} =
               ALLM.generate(engine, req)

      assert %AdapterError{reason: :rate_limited} = meta.error
    end
  end

  describe "§31 scenario: consumer cancellation releases resources" do
    test "Enum.take(stream, 2) on a 10-event script increments :counters observer within 500 ms" do
      ref = :counters.new(1, [:atomics])

      script = [
        {:text, "a"},
        {:text, "b"},
        {:text, "c"},
        {:text, "d"},
        {:text, "e"},
        {:text, "f"},
        {:text, "g"},
        {:text, "h"},
        {:text, "i"},
        {:text, "j"},
        {:finish, :stop}
      ]

      engine =
        Engine.new(
          adapter: Fake,
          adapter_opts: [script: script, cleanup_observer: ref]
        )

      req = Request.new([%Message{role: :user, content: "x"}])

      assert {:ok, stream} = ALLM.stream_generate(engine, req)
      _ = stream |> Enum.take(2)

      assert wait_for(fn -> :counters.get(ref, 1) == 1 end, 500)
    end

    test "halt-safety through filters: emit_text_deltas: false still propagates halt" do
      # Regression test for Phase 5 Non-obvious Decision #6 composition:
      # the Stream.each/Stream.filter pipeline does not break halt
      # propagation, even when filters drop the user-visible events.
      ref = :counters.new(1, [:atomics])

      script = [
        {:text, "a"},
        {:text, "b"},
        {:text, "c"},
        {:text, "d"},
        {:text, "e"},
        {:text, "f"},
        {:text, "g"},
        {:text, "h"},
        {:text, "i"},
        {:text, "j"},
        {:finish, :stop}
      ]

      engine =
        Engine.new(
          adapter: Fake,
          adapter_opts: [script: script, cleanup_observer: ref]
        )

      req = Request.new([%Message{role: :user, content: "x"}])

      assert {:ok, stream} = ALLM.stream_generate(engine, req, emit_text_deltas: false)
      _ = stream |> Enum.take(2)

      assert wait_for(fn -> :counters.get(ref, 1) == 1 end, 500)
    end
  end

  # ---------------------------------------------------------------------------
  # Deferred scenarios — one @tag :pending placeholder per remaining §31
  # bullet. Each test body is `:ok` so the placeholder runs without failure
  # and the test listing shows the deferred work. Phase 12's audit can count
  # these by tag.
  # ---------------------------------------------------------------------------

  @tag :pending
  test "§31 scenario: max_turns cap (Phase 7)" do
    # `max_turns` is a chat-loop bound surfaced through
    # `ALLM.chat/3`; Phase 7 introduces the orchestrator.
    :ok
  end

  @tag :pending
  test "§31 scenario: halt_when fires (Phase 7)" do
    # `halt_when:` predicate is a chat-loop option; Phase 7 wires it through
    # the orchestrator's per-step evaluation.
    :ok
  end

  @tag :pending
  test "§31 scenario: tool handler raises, on_tool_error policy fires (Phase 7)" do
    # `on_tool_error` policy (`:halt` | `:append_error`) is applied by the
    # chat loop; Phase 7 introduces the policy and its tests.
    :ok
  end

  @tag :pending
  test "§31 scenario: session round-trip (Phase 8)" do
    # Session serialization + `ALLM.Session.reply/4` arrive in Phase 8.
    :ok
  end
end
