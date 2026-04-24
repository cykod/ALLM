defmodule ALLM.Test.Assertions do
  @moduledoc """
  Test-only assertion helpers for Phase 6+ step-equivalence properties.

  Test-only infrastructure: compiled only under `Mix.env() == :test` via
  `elixirc_paths/1` in `mix.exs`.
  """

  import ExUnit.Assertions

  @doc """
  Assert two `%ALLM.StepResult{}` values are equivalent modulo a
  `tool_call_id` sort on `:tool_results` and on `:tool`-role thread
  messages.

  Per PHASE_6_DESIGN.md Non-obvious Decision #9: the step-equivalence
  property tolerates `tool_results` order variation. `ALLM.step/3`'s
  non-streaming path returns `tool_results` sorted by input index, while
  `ALLM.stream_step/3` emits tool-execution completion events in
  `Task.async_stream/5`'s completion order. Every other field is
  compared by exact equality.

  Comparison rules:

    * `:tool_results` — sorted by `tool_call_id` on both sides, then `==`.
    * `:response` — exact `==`.
    * `:done?` — exact `==`.
    * `:thread.messages` — non-`:tool`-role messages compared as a list
      (positional order load-bearing); `:tool`-role messages compared
      after sorting by `tool_call_id`.
    * `:metadata` — exact `==`.

  Raises `ExUnit.AssertionError` on mismatch; returns `:ok` on success.
  """
  @spec assert_equivalent_step_result(ALLM.StepResult.t(), ALLM.StepResult.t()) :: :ok
  def assert_equivalent_step_result(%ALLM.StepResult{} = a, %ALLM.StepResult{} = b) do
    sort_by_id = fn msgs -> Enum.sort_by(msgs, & &1.tool_call_id) end

    assert sort_by_id.(a.tool_results) == sort_by_id.(b.tool_results)
    assert a.response == b.response
    assert a.done? == b.done?

    assert Enum.reject(a.thread.messages, &(&1.role == :tool)) ==
             Enum.reject(b.thread.messages, &(&1.role == :tool))

    assert a.thread.messages |> Enum.filter(&(&1.role == :tool)) |> sort_by_id.() ==
             b.thread.messages |> Enum.filter(&(&1.role == :tool)) |> sort_by_id.()

    assert a.metadata == b.metadata
    :ok
  end
end
