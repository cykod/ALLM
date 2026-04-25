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

  @doc """
  Assert two `%ALLM.ChatResult{}` values are equivalent modulo a
  `tool_call_id` sort on `:tool`-role thread messages and on each
  step's `:tool_results`.

  Per PHASE_7_DESIGN.md Non-obvious Decision #4 (chat-equivalence by
  construction): both paths construct the `%ChatResult{}` via the same
  `ALLM.Chat.build_chat_result/1` helper, so the values are
  bytewise-identical EXCEPT for the same Phase-6 tool-message
  ordering tolerance (`Task.async_stream/5` non-determinism on
  parallel tool calls).

  Comparison rules:

    * `:halted_reason`, `:pending_question`, `:pending_tool_call_id`,
      `:metadata` — exact `==`.
    * `:final_response` — exact `==` (response tool_calls are in
      adapter-emission order, deterministic).
    * `:thread.messages` — non-`:tool`-role messages compared as a
      list (positional order load-bearing); `:tool`-role messages
      compared after sorting by `tool_call_id`.
    * `:steps` — element-wise via `assert_equivalent_step_result/2`.

  Raises `ExUnit.AssertionError` on mismatch; returns `:ok` on
  success.
  """
  @spec assert_equivalent_chat_result(ALLM.ChatResult.t(), ALLM.ChatResult.t()) :: :ok
  def assert_equivalent_chat_result(%ALLM.ChatResult{} = a, %ALLM.ChatResult{} = b) do
    sort_by_id = fn msgs -> Enum.sort_by(msgs, & &1.tool_call_id) end

    assert a.halted_reason == b.halted_reason
    assert a.pending_question == b.pending_question
    assert a.pending_tool_call_id == b.pending_tool_call_id
    assert a.metadata == b.metadata
    assert a.final_response == b.final_response

    assert Enum.reject(a.thread.messages, &(&1.role == :tool)) ==
             Enum.reject(b.thread.messages, &(&1.role == :tool))

    assert a.thread.messages |> Enum.filter(&(&1.role == :tool)) |> sort_by_id.() ==
             b.thread.messages |> Enum.filter(&(&1.role == :tool)) |> sort_by_id.()

    assert length(a.steps) == length(b.steps)

    a.steps
    |> Enum.zip(b.steps)
    |> Enum.each(fn {sa, sb} -> assert_equivalent_step_result(sa, sb) end)

    :ok
  end

  @doc """
  Assert two `{%Session{}, result}` tuples (where `result` is either a
  `%ChatResult{}` or a `%StepResult{}`) are equivalent.

  Extends `assert_equivalent_chat_result/2` (Phase 7) by additionally
  asserting:

    * `s1.status == s2.status`
    * `s1.thread.messages` equality modulo Phase 6 `tool_call_id` sort on
      `:tool`-role messages
    * `s1.pending_tool_calls == s2.pending_tool_calls`
    * `s1.pending_question == s2.pending_question`
    * `s1.pending_tool_call_id == s2.pending_tool_call_id`
    * `s1.metadata == s2.metadata`

  Per the Phase 8 stream-equivalence relaxation budget (8.4.1):

    * `:id` and `:context` are NOT compared — identical-by-construction
      because both arms receive the same input session.
    * `:metadata` IS compared. The streaming-only metadata divergence (if
      any) is resolved at `Session.apply_chat_result/2` time (no silent
      skip).

  Raises `ExUnit.AssertionError` on mismatch; returns `:ok`.
  """
  @spec assert_equivalent_session_result(
          {ALLM.Session.t(), ALLM.ChatResult.t() | ALLM.StepResult.t()},
          {ALLM.Session.t(), ALLM.ChatResult.t() | ALLM.StepResult.t()}
        ) :: :ok
  def assert_equivalent_session_result({%ALLM.Session{} = s1, r1}, {%ALLM.Session{} = s2, r2}) do
    assert_equivalent_result(r1, r2)

    sort_by_id = fn msgs -> Enum.sort_by(msgs, & &1.tool_call_id) end

    assert s1.status == s2.status,
           "session.status mismatch: #{inspect(s1.status)} vs #{inspect(s2.status)}"

    assert Enum.reject(s1.thread.messages, &(&1.role == :tool)) ==
             Enum.reject(s2.thread.messages, &(&1.role == :tool)),
           "non-:tool thread.messages diverged"

    assert s1.thread.messages |> Enum.filter(&(&1.role == :tool)) |> sort_by_id.() ==
             s2.thread.messages |> Enum.filter(&(&1.role == :tool)) |> sort_by_id.(),
           ":tool-role thread.messages diverged (sorted by tool_call_id)"

    assert s1.pending_tool_calls == s2.pending_tool_calls
    assert s1.pending_question == s2.pending_question
    assert s1.pending_tool_call_id == s2.pending_tool_call_id

    assert s1.metadata == s2.metadata,
           "session.metadata diverged between non-streaming and streaming arms: " <>
             inspect(diff_maps(s1.metadata, s2.metadata))

    :ok
  end

  defp assert_equivalent_result(%ALLM.ChatResult{} = a, %ALLM.ChatResult{} = b) do
    assert_equivalent_chat_result(a, b)
  end

  defp assert_equivalent_result(%ALLM.StepResult{} = a, %ALLM.StepResult{} = b) do
    assert_equivalent_step_result(a, b)
  end

  defp diff_maps(a, b) do
    only_a = Map.drop(a, Map.keys(b))
    only_b = Map.drop(b, Map.keys(a))
    differing = for {k, va} <- a, Map.get(b, k) != va, into: %{}, do: {k, {va, Map.get(b, k)}}
    %{only_in_a: only_a, only_in_b: only_b, differing: differing}
  end

  @doc """
  Assert a `%Session{}` round-trips through `:erlang.term_to_binary/1`
  unconditionally and through `ALLM.Serializer` (JSON) for every field
  except those listed in `opts[:exclude]`.

  Per PHASE_8_DESIGN §8.4.1 Invariants 1: ETF round-trip is unconditional;
  Jason round-trip is parameterised on `:exclude` because `:context` /
  `:metadata` may carry caller-supplied non-JSON-roundtrippable values
  (DateTime, Decimal, custom structs without Jason encoders). Per the
  Phase 1 caller-owned-context contract, this is not the library's bug
  to fix — the helper exposes the escape hatch to test fixtures.

  ## Options

    * `:exclude` — list of `%Session{}` field atoms to skip in the JSON
      round-trip equality check. Default `[]` (full Jason equality).
  """
  @spec assert_session_round_trip(ALLM.Session.t(), keyword()) :: :ok
  def assert_session_round_trip(%ALLM.Session{} = session, opts \\ []) when is_list(opts) do
    exclude = Keyword.get(opts, :exclude, [])

    # ETF round-trip — unconditional.
    assert session == session |> :erlang.term_to_binary() |> :erlang.binary_to_term(),
           "Session ETF round-trip failed"

    # JSON round-trip — equality on every field except those in :exclude.
    json = ALLM.Serializer.to_json!(session)
    {:ok, %ALLM.Session{} = round_tripped} = ALLM.Serializer.from_json(json)

    for {field, _} <- Map.from_struct(session), field not in exclude do
      assert Map.get(session, field) == Map.get(round_tripped, field),
             "Session JSON round-trip diverged at field #{inspect(field)}: " <>
               inspect(Map.get(session, field)) <>
               " vs " <> inspect(Map.get(round_tripped, field))
    end

    :ok
  end
end
