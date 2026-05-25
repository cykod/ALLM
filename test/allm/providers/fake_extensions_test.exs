defmodule ALLM.Providers.FakeExtensionsTest do
  @moduledoc """
  Phase 21.2: `ALLM.Providers.Fake` accepts two new `adapter_opts`:

    * `:usage` — a `%ALLM.Usage{}` or keyword list folded onto the
      Response's `:usage` field on every call. For streaming, the
      Usage rides on the `:message_completed` payload's `:metadata.usage`
      key (additive payload-key extension — no new event variant).
    * `:record` — a pid that receives `{:allm_fake_record, %Request{}, opts}`
      verbatim at the top of every `generate/2` / `stream/2`.
  """

  use ExUnit.Case, async: true

  alias ALLM.{Message, Request, Response, StreamCollector, Usage}
  alias ALLM.Providers.Fake

  defp simple_request, do: Request.new([%Message{role: :user, content: "hi"}])

  describe ":usage on generate/2" do
    test "Usage struct passed verbatim is set on response.usage" do
      usage = %Usage{input_tokens: 12, output_tokens: 4, total_tokens: 16}

      opts = [
        adapter_opts: [
          script: [{:text, "ok"}, {:finish, :stop}],
          usage: usage
        ]
      ]

      assert {:ok, %Response{} = resp} = Fake.generate(simple_request(), opts)
      assert resp.usage == usage
    end

    test "keyword form is normalized through Usage.new/1" do
      opts = [
        adapter_opts: [
          script: [{:text, "ok"}, {:finish, :stop}],
          usage: [input_tokens: 12, output_tokens: 4]
        ]
      ]

      assert {:ok, resp} = Fake.generate(simple_request(), opts)
      assert resp.usage.input_tokens == 12
      assert resp.usage.output_tokens == 4
    end

    test "adapter-opt :usage overrides a per-script {:usage, _} entry" do
      opts = [
        adapter_opts: [
          script: [
            {:text, "ok"},
            {:usage, %{input_tokens: 99, output_tokens: 99}},
            {:finish, :stop}
          ],
          usage: [input_tokens: 12, output_tokens: 4]
        ]
      ]

      assert {:ok, resp} = Fake.generate(simple_request(), opts)
      assert resp.usage.input_tokens == 12
      assert resp.usage.output_tokens == 4
    end

    test "Usage.total_tokens/1 is non-nil when caller passes input + output tokens" do
      opts = [
        adapter_opts: [
          script: [{:text, "ok"}, {:finish, :stop}],
          usage: [input_tokens: 10, output_tokens: 20]
        ]
      ]

      assert {:ok, resp} = Fake.generate(simple_request(), opts)
      assert Usage.total_tokens(resp.usage) == 30
    end
  end

  describe ":record on generate/2" do
    test "sends {:allm_fake_record, request, opts} to the recording pid" do
      me = self()

      opts = [
        adapter_opts: [
          script: [{:text, "ok"}, {:finish, :stop}],
          record: me
        ]
      ]

      assert {:ok, _resp} = Fake.generate(simple_request(), opts)
      assert_receive {:allm_fake_record, %Request{} = req, recorded_opts}
      assert [%Message{content: "hi"}] = req.messages

      # opts are forwarded verbatim — no scrubbing
      assert Keyword.has_key?(recorded_opts, :adapter_opts)
    end

    test "multiple calls each send one record message" do
      me = self()

      opts = [
        adapter_opts: [
          scripts: [
            [{:text, "a"}, {:finish, :stop}],
            [{:text, "b"}, {:finish, :stop}],
            [{:text, "c"}, {:finish, :stop}]
          ],
          record: me
        ]
      ]

      for _ <- 1..3 do
        assert {:ok, _} = Fake.generate(simple_request(), opts)
      end

      for _ <- 1..3 do
        assert_receive {:allm_fake_record, %Request{}, _}
      end
    end

    test "raises ArgumentError when recording pid is dead" do
      dead =
        spawn(fn -> :ok end)
        |> tap(fn _ -> :timer.sleep(20) end)

      # Ensure the spawned process has terminated
      :timer.sleep(50)
      refute Process.alive?(dead)

      opts = [
        adapter_opts: [
          script: [{:text, "ok"}, {:finish, :stop}],
          record: dead
        ]
      ]

      assert_raise ArgumentError, ~r/record/i, fn ->
        Fake.generate(simple_request(), opts)
      end
    end
  end

  describe ":record on stream/2" do
    test "sends {:allm_fake_record, request, opts} before opening the stream" do
      me = self()

      opts = [
        adapter_opts: [
          script: [{:text, "ok"}, {:finish, :stop}],
          record: me
        ]
      ]

      assert {:ok, stream} = Fake.stream(simple_request(), opts)
      # Recording fires at call time, BEFORE the consumer reduces the stream.
      assert_receive {:allm_fake_record, %Request{}, _opts}
      _ = Enum.to_list(stream)
    end
  end

  describe ":usage on stream/2 — additive :message_completed.metadata.usage" do
    test "lands on :message_completed payload's metadata.usage" do
      opts = [
        adapter_opts: [
          script: [{:text, "ok"}, {:finish, :stop}],
          usage: [input_tokens: 12, output_tokens: 4]
        ]
      ]

      assert {:ok, stream} = Fake.stream(simple_request(), opts)
      events = Enum.to_list(stream)

      assert {:message_completed, payload} =
               Enum.find(events, &match?({:message_completed, _}, &1))

      assert %{usage: %Usage{input_tokens: 12, output_tokens: 4}} = payload.metadata
    end

    test "absent :usage opt does NOT add metadata.usage" do
      opts = [
        adapter_opts: [
          script: [{:text, "ok"}, {:finish, :stop}]
        ]
      ]

      assert {:ok, stream} = Fake.stream(simple_request(), opts)
      events = Enum.to_list(stream)

      {:message_completed, payload} =
        Enum.find(events, &match?({:message_completed, _}, &1))

      refute Map.has_key?(payload, :metadata) and Map.has_key?(payload.metadata || %{}, :usage)
    end

    test "Event.event?/1 still returns true for the augmented payload" do
      opts = [
        adapter_opts: [
          script: [{:text, "ok"}, {:finish, :stop}],
          usage: [input_tokens: 7]
        ]
      ]

      {:ok, stream} = Fake.stream(simple_request(), opts)

      Enum.each(Enum.to_list(stream), fn event ->
        assert ALLM.Event.event?(event)
      end)
    end

    test "StreamCollector.collect-style fold produces Response with usage populated" do
      opts = [
        adapter_opts: [
          script: [{:text, "ok"}, {:finish, :stop}],
          usage: [input_tokens: 12, output_tokens: 4]
        ]
      ]

      {:ok, stream} = Fake.stream(simple_request(), opts)

      state =
        Enum.reduce(stream, StreamCollector.new(), fn evt, s ->
          StreamCollector.apply_event(s, evt)
        end)

      response = StreamCollector.to_response(state)
      assert response.usage.input_tokens == 12
      assert response.usage.output_tokens == 4
    end

    test "consumer matching only :message_completed.message is unaffected" do
      # Pin: adding `metadata.usage` to the payload doesn't break consumers
      # that pattern-match a subset of keys.
      opts = [
        adapter_opts: [
          script: [{:text, "ok"}, {:finish, :stop}],
          usage: [input_tokens: 9]
        ]
      ]

      {:ok, stream} = Fake.stream(simple_request(), opts)

      matched =
        Enum.any?(Enum.to_list(stream), fn
          {:message_completed, %{message: _msg}} -> true
          _ -> false
        end)

      assert matched
    end
  end

  describe "Usage round-trip with :usage opt" do
    test "%Response{} produced by Fake with :usage round-trips through ETF" do
      opts = [
        adapter_opts: [
          script: [{:text, "ok"}, {:finish, :stop}],
          usage: [input_tokens: 10, output_tokens: 20]
        ]
      ]

      {:ok, resp} = Fake.generate(simple_request(), opts)

      decoded = resp |> :erlang.term_to_binary() |> :erlang.binary_to_term()
      assert decoded.usage.input_tokens == 10
      assert decoded.usage.output_tokens == 20
    end
  end
end
