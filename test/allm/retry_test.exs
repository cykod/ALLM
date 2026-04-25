defmodule ALLM.RetryTest do
  use ExUnit.Case, async: true

  alias ALLM.Retry
  alias ALLM.Test.TelemetryCapture

  doctest ALLM.Retry

  setup do
    on_exit(fn -> TelemetryCapture.detach() end)
    :ok
  end

  describe "default_policy/0" do
    test "returns the spec §6.1 closed map field-by-field" do
      p = Retry.default_policy()

      assert p.max_attempts == 3
      assert p.base_delay_ms == 500
      assert p.max_delay_ms == 30_000
      assert p.retry_on == [429, 500, 502, 503, 504, :timeout]
      assert p.jitter_ms == 250
      assert p.respect_retry_after == true

      # Closed key set — ensure no extra fields snuck in.
      assert p
             |> Map.keys()
             |> Enum.sort() ==
               [
                 :base_delay_ms,
                 :jitter_ms,
                 :max_attempts,
                 :max_delay_ms,
                 :respect_retry_after,
                 :retry_on
               ]
    end
  end

  describe "materialize/1" do
    test ":default returns default_policy()" do
      assert Retry.materialize(:default) == Retry.default_policy()
    end

    test "false returns :no_retry" do
      assert Retry.materialize(false) == :no_retry
    end

    test "[] returns default_policy()" do
      assert Retry.materialize([]) == Retry.default_policy()
    end

    test "[max_attempts: 5] merges over default" do
      result = Retry.materialize(max_attempts: 5)
      assert result.max_attempts == 5
      assert result.base_delay_ms == 500
      assert result.retry_on == [429, 500, 502, 503, 504, :timeout]
    end

    test "[max_attempts: 0] returns :no_retry" do
      assert Retry.materialize(max_attempts: 0) == :no_retry
    end

    test "unknown key raises ArgumentError (typo guard)" do
      assert_raise ArgumentError, ~r/unknown retry policy key :max_atempts/, fn ->
        Retry.materialize(max_atempts: 3)
      end
    end

    test "merges multiple keys" do
      result = Retry.materialize(max_attempts: 5, base_delay_ms: 100)
      assert result.max_attempts == 5
      assert result.base_delay_ms == 100
      assert result.jitter_ms == 250
    end
  end

  describe "run/3 with :no_retry" do
    test "{:ok, _} passes through" do
      assert Retry.run(:no_retry, %{}, fn -> {:ok, 1} end) == {:ok, 1}
    end

    test "{:retry, _, error} collapses to {:error, error}" do
      assert Retry.run(:no_retry, %{}, fn -> {:retry, 0, :err} end) == {:error, :err}
    end

    test "{:error, error} passes through" do
      assert Retry.run(:no_retry, %{}, fn -> {:error, :nope} end) == {:error, :nope}
    end

    test "false materialises to :no_retry" do
      assert Retry.run(false, %{}, fn -> {:ok, 7} end) == {:ok, 7}
    end
  end

  describe "run/3 with :default policy" do
    setup do
      :ok =
        TelemetryCapture.attach([
          [:allm, :adapter, :retry]
        ])

      :ok
    end

    test "retries (max_attempts - 1)× then succeeds; emits 2× retry events" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      result =
        Retry.run([base_delay_ms: 1, jitter_ms: 0], %{tag: :ok_after_3}, fn ->
          n = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})

          # n is 1, 2, 3, ... — succeed on the 3rd call.
          if n < 3 do
            {:retry, 0, 429}
          else
            {:ok, :woke}
          end
        end)

      assert result == {:ok, :woke}

      events = TelemetryCapture.events()
      retries = Enum.filter(events, &match?({[:allm, :adapter, :retry], _, _}, &1))
      assert length(retries) == 2

      attempts = for {_, _, %{attempt: a}} <- retries, do: a
      assert attempts == [1, 2]

      for {_, _, meta} <- retries do
        assert meta.tag == :ok_after_3
        assert meta.reason == 429
        assert is_integer(meta.delay_ms)
        assert meta.delay_ms >= 0
      end
    end

    test "exhausts max_attempts on persistent retry; emits 2× retry events (final attempt is silent)" do
      result =
        Retry.run([base_delay_ms: 1, jitter_ms: 0], %{}, fn -> {:retry, 0, 429} end)

      assert result == {:error, 429}

      retries =
        TelemetryCapture.events()
        |> Enum.filter(&match?({[:allm, :adapter, :retry], _, _}, &1))

      assert length(retries) == 2
      attempts = for {_, _, %{attempt: a}} <- retries, do: a
      assert attempts == [1, 2]
    end

    test "non-retryable {:error, _} returns immediately, no retry events" do
      assert Retry.run(:default, %{}, fn -> {:error, 400} end) == {:error, 400}

      retries =
        TelemetryCapture.events()
        |> Enum.filter(&match?({[:allm, :adapter, :retry], _, _}, &1))

      assert retries == []
    end

    test "{:retry, _, error} with error not in retry_on collapses to {:error, error}" do
      assert Retry.run(:default, %{}, fn -> {:retry, 0, :unrecognized_atom} end) ==
               {:error, :unrecognized_atom}

      retries =
        TelemetryCapture.events()
        |> Enum.filter(&match?({[:allm, :adapter, :retry], _, _}, &1))

      assert retries == []
    end

    test "respects closure-supplied Retry-After delay (~1500ms ±200ms)" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      start_ms = System.monotonic_time(:millisecond)

      result =
        Retry.run(:default, %{}, fn ->
          n = Agent.get_and_update(counter, &{&1, &1 + 1})
          if n < 1, do: {:retry, 1500, 429}, else: {:ok, :ok}
        end)

      elapsed = System.monotonic_time(:millisecond) - start_ms

      assert result == {:ok, :ok}
      # Allow generous tolerance for CI scheduler jitter.
      assert elapsed >= 1450
      assert elapsed <= 1900

      retries =
        TelemetryCapture.events()
        |> Enum.filter(&match?({[:allm, :adapter, :retry], _, _}, &1))

      assert length(retries) == 1
      [{_, _, %{delay_ms: delay_ms}}] = retries
      assert delay_ms >= 1500
      # Retry-After path: delay_ms = 1500 + jitter (jitter ∈ [0, 250]).
      assert delay_ms <= 1500 + 250
    end

    test "jitter bounds: every retry delay_ms ∈ [base_delay_ms, base_delay_ms + jitter_ms]" do
      # Force the computed-backoff path: closure returns delay 0, so
      # `actual_delay = max(0, base_delay_ms * 2^(attempt-1) + jitter)`.
      # At attempt 1: 100 * 1 + jitter ∈ [100, 150].
      # At attempt 2: 100 * 2 + jitter ∈ [200, 250].
      policy_opts = [
        base_delay_ms: 100,
        jitter_ms: 50,
        max_delay_ms: 30_000,
        max_attempts: 3
      ]

      for _ <- 1..30 do
        :ok = TelemetryCapture.detach()
        :ok = TelemetryCapture.attach([[:allm, :adapter, :retry]])

        _ = Retry.run(policy_opts, %{}, fn -> {:retry, 0, 429} end)

        retries =
          TelemetryCapture.events()
          |> Enum.filter(&match?({[:allm, :adapter, :retry], _, _}, &1))

        assert length(retries) == 2

        for {_, _, %{attempt: a, delay_ms: d}} <- retries do
          expected_base = 100 * Integer.pow(2, a - 1)
          assert d >= expected_base, "attempt #{a}: delay_ms=#{d} < #{expected_base}"
          assert d <= expected_base + 50, "attempt #{a}: delay_ms=#{d} > #{expected_base + 50}"
        end
      end
    end

    test "telemetry measurements include :system_time" do
      _ = Retry.run([base_delay_ms: 1, jitter_ms: 0], %{}, fn -> {:retry, 0, 429} end)

      [{_, measurements, _} | _] =
        TelemetryCapture.events()
        |> Enum.filter(&match?({[:allm, :adapter, :retry], _, _}, &1))

      assert is_integer(measurements.system_time)
    end

    test "telemetry metadata is shallow-merged with caller-supplied metadata" do
      _ =
        Retry.run([base_delay_ms: 1, jitter_ms: 0], %{provider: :fake, request_id: "abc"}, fn ->
          {:retry, 0, 429}
        end)

      [{_, _, meta} | _] =
        TelemetryCapture.events()
        |> Enum.filter(&match?({[:allm, :adapter, :retry], _, _}, &1))

      assert meta.provider == :fake
      assert meta.request_id == "abc"
      assert meta.attempt == 1
      assert meta.reason == 429
    end
  end

  describe "error_matches?/2" do
    test "integer status code membership" do
      assert Retry.error_matches?(429, [429, 500])
      refute Retry.error_matches?(400, [429, 500])
    end

    test "atom membership" do
      assert Retry.error_matches?(:timeout, [429, :timeout])
      refute Retry.error_matches?(:closed, [429, :timeout])
    end

    test "extracts :reason from struct/map for membership" do
      assert Retry.error_matches?(%{reason: :timeout}, [:timeout])
      refute Retry.error_matches?(%{reason: :other}, [:timeout])
    end
  end

  describe "exception propagation (spec §6.1)" do
    setup do
      :ok = TelemetryCapture.attach([[:allm, :adapter, :retry]])
      :ok
    end

    test "closure raise propagates to caller; no telemetry, no retry" do
      assert_raise RuntimeError, "boom", fn ->
        Retry.run(:default, %{}, fn -> raise "boom" end)
      end

      retries =
        TelemetryCapture.events()
        |> Enum.filter(&match?({[:allm, :adapter, :retry], _, _}, &1))

      assert retries == []
    end
  end
end
