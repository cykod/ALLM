defmodule ALLM.Providers.FakeRetryTest do
  use ExUnit.Case, async: true

  alias ALLM.Providers.Fake
  alias ALLM.Request
  alias ALLM.Test.TelemetryCapture

  setup do
    on_exit(fn -> TelemetryCapture.detach() end)
    :ok
  end

  defp request, do: Request.new([%ALLM.Message{role: :user, content: "hi"}])

  defp script, do: [{:text, "hi"}, {:finish, :stop}]

  describe "Fake.generate/2 with retry_until_call" do
    setup do
      :ok = TelemetryCapture.attach([[:allm, :adapter, :retry]])
      :ok
    end

    test "retry_until_call: 1 succeeds on first call; no retry events" do
      adapter_opts = [script: script(), retry_until_call: 1]
      assert {:ok, response} = Fake.generate(request(), adapter_opts: adapter_opts)
      assert response.output_text == "hi"
      assert response.finish_reason == :stop

      retries = filter_retries()
      assert retries == []
    end

    test "retry_until_call: 3 succeeds on 3rd call; emits 2× retry events with attempts 1 and 2" do
      adapter_opts = [script: script(), retry_until_call: 3]
      assert {:ok, response} = Fake.generate(request(), adapter_opts: adapter_opts)
      assert response.output_text == "hi"

      retries = filter_retries()
      assert length(retries) == 2

      attempts = for {_, _, %{attempt: a}} <- retries, do: a
      assert attempts == [1, 2]

      for {_, _, meta} <- retries do
        assert meta.provider == :fake
        assert meta.reason == :timeout
      end
    end

    test "retry_until_call: 99 with default retry exhausts → {:error, _}" do
      adapter_opts = [script: script(), retry_until_call: 99]
      assert {:error, :timeout} = Fake.generate(request(), adapter_opts: adapter_opts)

      # Default policy max_attempts: 3 → 2 retry events fire (attempts 1 and 2).
      retries = filter_retries()
      assert length(retries) == 2
    end

    test "retry: false short-circuits on first transient → {:error, _}; no retry events" do
      adapter_opts = [script: script(), retry_until_call: 2]
      result = Fake.generate(request(), retry: false, adapter_opts: adapter_opts)
      assert result == {:error, :timeout}

      retries = filter_retries()
      assert retries == []
    end

    test "retry: [max_attempts: 5] with retry_until_call: 4 succeeds on attempt 4" do
      adapter_opts = [script: script(), retry_until_call: 4]
      result = Fake.generate(request(), retry: [max_attempts: 5], adapter_opts: adapter_opts)
      assert {:ok, response} = result
      assert response.output_text == "hi"

      retries = filter_retries()
      assert length(retries) == 3
      attempts = for {_, _, %{attempt: a}} <- retries, do: a
      assert attempts == [1, 2, 3]
    end

    test "request_id from opts propagates onto retry telemetry metadata" do
      adapter_opts = [script: script(), retry_until_call: 2]

      _ =
        Fake.generate(request(),
          adapter_opts: adapter_opts,
          request_id: "rid-xyz"
        )

      [{_, _, meta}] = filter_retries()
      assert meta.request_id == "rid-xyz"
    end

    defp filter_retries do
      TelemetryCapture.events()
      |> Enum.filter(&match?({[:allm, :adapter, :retry], _, _}, &1))
    end
  end

  describe "Fake.stream/2 with retry_until_call (streaming-no-retry, spec §6.1)" do
    setup do
      :ok = TelemetryCapture.attach([[:allm, :adapter, :retry]])
      :ok
    end

    test "retry_until_call: 3 emits a terminal {:error, _} event and ZERO retry events" do
      adapter_opts = [script: script(), retry_until_call: 3]
      assert {:ok, stream} = Fake.stream(request(), adapter_opts: adapter_opts)

      events = Enum.to_list(stream)

      # Streaming did NOT call ALLM.Retry.run/3 — no retry telemetry.
      retries =
        TelemetryCapture.events()
        |> Enum.filter(&match?({[:allm, :adapter, :retry], _, _}, &1))

      assert retries == []

      # The stream surfaces the transient as a terminal {:error, _}
      # mid-stream. Per CLAUDE.md, the consumer reduces this into
      # %Response{finish_reason: :error}.
      assert Enum.any?(events, &match?({:error, %ALLM.Error.AdapterError{}}, &1))
    end

    test "collected response has finish_reason: :error per the mid-stream-error invariant" do
      adapter_opts = [script: script(), retry_until_call: 3]
      assert {:ok, stream} = Fake.stream(request(), adapter_opts: adapter_opts)

      response =
        stream
        |> Enum.reduce(ALLM.StreamCollector.new(), fn event, acc ->
          ALLM.StreamCollector.apply_event(acc, event)
        end)
        |> ALLM.StreamCollector.to_response()

      assert response.finish_reason == :error
      assert %ALLM.Error.AdapterError{} = response.metadata[:error]
    end

    test "retry_until_call: 1 streams normally (no transient injected)" do
      adapter_opts = [script: script(), retry_until_call: 1]
      assert {:ok, stream} = Fake.stream(request(), adapter_opts: adapter_opts)

      events = Enum.to_list(stream)

      assert Enum.any?(events, &match?({:text_delta, %{delta: "hi"}}, &1))
      assert Enum.any?(events, &match?({:message_completed, _}, &1))
      refute Enum.any?(events, &match?({:error, _}, &1))
    end
  end

  describe "Fake.generate/2 + Fake.stream/2 share the per-process counter" do
    setup do
      :ok = TelemetryCapture.attach([[:allm, :adapter, :retry]])
      :ok
    end

    test "stream consuming a transient decrements; subsequent generate proceeds normally" do
      # Set retry_until_call: 2: the first call (stream) gets the
      # transient, the counter decrements to 1, and the second call
      # (generate) proceeds.
      adapter_opts = [script: script(), retry_until_call: 2]

      {:ok, stream} = Fake.stream(request(), adapter_opts: adapter_opts)
      events = Enum.to_list(stream)
      assert Enum.any?(events, &match?({:error, _}, &1))

      # The counter decremented from 2 → 1; the next generate call should
      # succeed (counter was at 1 → :proceed, then deletes the key).
      # We pass retry: false so no retry can hide the result.
      assert {:ok, response} =
               Fake.generate(request(),
                 retry: false,
                 adapter_opts: adapter_opts
               )

      assert response.output_text == "hi"
    end
  end
end
