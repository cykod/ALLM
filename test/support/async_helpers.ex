defmodule ALLM.Test.AsyncHelpers do
  @moduledoc """
  Async-test helpers shared across the streaming test suite.

  Layer B (test support) — lives under `test/support/` and is not part of
  the published Hex package. Extracted from inline copies in
  `fake_stream_test.exs`, `fake_scenarios_test.exs`, and
  `stream_runner_test.exs` ahead of Phase 7.4 (Chat.stream/3) testing,
  whose consumer-halt cleanup tests share the same polling shape.
  """

  @doc """
  Poll a 0-arity predicate until it returns truthy or `timeout_ms`
  milliseconds elapse.

  Returns `true` on success and `false` on timeout. The polling cadence
  is 10 ms, matching the prior inline copies (`StreamRunnerTest`,
  `Providers.FakeStreamTest`, `Providers.FakeScenariosTest`).

  Used for halt-safety assertions where an `:counters` increment (or
  similar observer) is expected to land shortly after a consumer halts —
  a fixed `Process.sleep/1` would be flaky on a loaded CI runner.
  """
  @spec wait_for((-> boolean()), pos_integer()) :: boolean()
  def wait_for(fun, timeout_ms)
      when is_function(fun, 0) and is_integer(timeout_ms) and timeout_ms > 0 do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for(fun, deadline)
  end

  defp do_wait_for(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(10)
        do_wait_for(fun, deadline)
      end
    end
  end
end
