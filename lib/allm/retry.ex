defmodule ALLM.Retry do
  @moduledoc """
  Internal — Layer B retry helper consumed by adapters.

  Wraps a non-streaming adapter call in a bounded retry loop with
  exponential backoff and additive jitter, per spec §6.1. Adapters
  call `run/3` with their own per-attempt closure; the closure returns
  one of `{:ok, term}`, `{:retry, delay_ms, error}`, or `{:error, term}`
  (Phase 9 design Non-obvious Decision #4) — the helper handles the
  loop, the sleep, and the per-attempt `[:allm, :adapter, :retry]`
  telemetry emission (Decision #16).

  Streaming adapters do **not** call `run/3`: spec §6.1 is explicit
  that "Streaming calls are not retried automatically (partial output
  has already been delivered to the consumer)." The
  `ALLM.StreamAdapter` behaviour-doc surfaces this contract;
  enforcement is by code review, not by the helper.

  Tested end-to-end via `ALLM.Providers.Fake`'s
  `adapter_opts: [retry_until_call: n]` plumbing; the same helper is
  consumed by real-provider adapters in Phase 10/11.

  Phase 14.3 added a second caller class: the image-side façade
  (`ALLM.generate_image/3 · edit_image/4 · image_variations/3`) wraps
  the adapter dispatch in `Retry.run/3` with the same default policy
  (`default_policy/0`) — image generation reuses chat retry semantics
  unchanged (design Decision #9). Image-side closures emit `{:retry,
  delay_ms, %ALLM.Error.ImageAdapterError{}}` for the four
  retry-engaging reasons (`:rate_limited`, `:provider_unavailable`,
  `:timeout`, `:network_error`); other reasons surface verbatim with no
  retry attempt.

  ## v0.2 surface caveat — public-API retry visibility

  In v0.2 the public Layer-C entry points (`ALLM.generate/3`,
  `ALLM.step/3`, `ALLM.chat/3`) all route through `ALLM.StreamRunner`,
  which calls the adapter's `c:ALLM.StreamAdapter.stream/2` — the
  streaming path. Per spec §6.1, **streaming calls are not retried**,
  so `[:allm, :adapter, :retry]` events do NOT fire from any public
  Layer-C call in v0.2. The retry round-trip is exercised in v0.2 only
  by direct adapter calls
  (`ALLM.Providers.Fake.generate(req, adapter_opts: [retry_until_call:
  n])`, mirroring how real-provider adapters call `Retry.run/3` from
  their non-streaming `c:ALLM.Adapter.generate/3` callbacks). Per the
  Phase 9 design's Decision #14, real-provider Phase 10/11 adapters'
  non-streaming `generate/2` callbacks reuse this same helper; until a
  non-streaming Layer-C path lands (or a real-provider integration
  ships and is invoked through one), retry telemetry observed via the
  public façade requires the adapter to be reachable through a path
  that exercises `c:ALLM.Adapter.generate/3`.

  ## `:request_id` on retry events

  `:request_id` appears on `[:allm, :adapter, :retry]` metadata only
  when the adapter call's `opts` carry a `:request_id` (typically
  threaded from a wrapping `Runner` / `StreamRunner` span). Direct
  adapter calls (e.g., the Fake retry round-trip) emit retry events
  without `:request_id` because no wrapping span generated one. This
  is a soft-promise rather than a hard invariant — see review Finding
  #3 for the v0.2 surface notes.

  ## Default policy

  See `default_policy/0` for the spec §6.1 closed map. Materialised
  via `materialize/1` from the engine's `:retry` field
  (`:default | false | keyword()`).

  ## Closure contract

  The closure passed to `run/3` is invoked up to `policy.max_attempts`
  times. It must return one of:

    * `{:ok, value}` — success; loop returns `{:ok, value}`.
    * `{:retry, delay_ms, error}` — retryable failure. When
      `delay_ms > 0`, that value (plus jitter) is the delay; otherwise
      the computed exponential backoff (with jitter) is used. The
      `error` term is checked against `policy.retry_on` for membership;
      a non-matching error returns `{:error, error}` immediately.
    * `{:error, error}` — non-retryable failure; loop returns
      `{:error, error}` immediately, no telemetry, no sleep.

  Closure-raised exceptions propagate to the caller of `run/3`
  unchanged (no rescue, no telemetry — spec §6.1's "exception is not
  retryable" rule).

  ## Telemetry

  `[:allm, :adapter, :retry]` is emitted per retry attempt, **before**
  sleeping, with measurements `%{system_time: System.system_time()}`
  and metadata `Map.merge(telemetry_metadata, %{attempt: attempt,
  delay_ms: actual_delay, reason: error})`. The final attempt (when
  `attempt == max_attempts`) emits no retry event — the surrounding
  `[:allm, :adapter, :stop]` (or `:exception`) span fires instead.
  """

  alias ALLM.Telemetry

  @typedoc "Closure return: success, retry-with-delay, or non-retryable error."
  @type closure_result(ok) :: {:ok, ok} | {:retry, non_neg_integer(), term()} | {:error, term()}

  @typedoc "Materialised retry policy after merging `:default | false | keyword()`."
  @type policy :: %{
          max_attempts: non_neg_integer(),
          base_delay_ms: pos_integer(),
          max_delay_ms: pos_integer(),
          retry_on: [pos_integer() | atom()],
          jitter_ms: non_neg_integer(),
          respect_retry_after: boolean()
        }

  @typedoc "Engine-side retry shapes accepted by `materialize/1`."
  @type engine_retry :: :default | false | keyword()

  # Closed key set for `materialize/1` — every keyword opt must be one
  # of these. An unknown key raises `ArgumentError` so a typo
  # (`max_atempts:`) fails loudly at engine construction or first call.
  @policy_keys [
    :max_attempts,
    :base_delay_ms,
    :max_delay_ms,
    :retry_on,
    :jitter_ms,
    :respect_retry_after
  ]

  @doc """
  Return the spec §6.1 default retry policy.

  Field-by-field cited against
  `steering/allm_engine_session_streaming_spec_v0_2.md` §6.1
  (`max_attempts: 3`, `base_delay_ms: 500`, `max_delay_ms: 30_000`,
  `retry_on: [429, 500, 502, 503, 504, :timeout]`, `jitter_ms: 250`,
  `respect_retry_after: true`).

  ## Examples

      iex> p = ALLM.Retry.default_policy()
      iex> p.max_attempts
      3
      iex> p.retry_on
      [429, 500, 502, 503, 504, :timeout]
  """
  @spec default_policy() :: policy()
  def default_policy do
    %{
      max_attempts: 3,
      base_delay_ms: 500,
      max_delay_ms: 30_000,
      retry_on: [429, 500, 502, 503, 504, :timeout],
      jitter_ms: 250,
      respect_retry_after: true
    }
  end

  @doc """
  Materialise an engine `:retry` field into a `policy()` or `:no_retry`.

    * `false` → `:no_retry`.
    * `:default` → `default_policy()`.
    * `[]` → `default_policy()`.
    * `keyword()` → `Map.merge(default_policy(), Map.new(kw))`.
    * `[max_attempts: 0]` → `:no_retry` (zero attempts is indistinguishable
      from "no retry").
    * Unknown keys raise `ArgumentError` (a typo like `max_atempts:` fails
      loudly).

  ## Examples

      iex> ALLM.Retry.materialize(:default).max_attempts
      3

      iex> ALLM.Retry.materialize(false)
      :no_retry

      iex> ALLM.Retry.materialize(max_attempts: 5).max_attempts
      5

      iex> ALLM.Retry.materialize(max_attempts: 0)
      :no_retry
  """
  @spec materialize(engine_retry()) :: policy() | :no_retry
  def materialize(false), do: :no_retry
  def materialize(:default), do: default_policy()

  def materialize(opts) when is_list(opts) do
    Enum.each(opts, fn
      {k, _v} when k in @policy_keys ->
        :ok

      {k, _v} ->
        raise ArgumentError,
              "ALLM.Retry.materialize/1: unknown retry policy key #{inspect(k)}; " <>
                "expected one of #{inspect(@policy_keys)}"
    end)

    case Keyword.get(opts, :max_attempts, :unset) do
      0 ->
        :no_retry

      _ ->
        Map.merge(default_policy(), Map.new(opts))
    end
  end

  @doc """
  Run `fun` under the given retry policy.

  Accepts a materialised `policy()`, `:no_retry`, or any of the engine
  shapes (`:default | false | keyword()`); the engine shape is
  materialised internally via `materialize/1`.

  Behaviour:

    * `:no_retry` — `fun` is invoked once. `{:ok, _}` is returned
      verbatim; `{:error, error}` and `{:retry, _, error}` collapse to
      `{:error, error}` so the caller doesn't have to handle the third
      shape.

    * `policy()` — `fun` is invoked up to `policy.max_attempts` times.
      `telemetry_metadata` is shallow-merged with `%{attempt: attempt,
      delay_ms: actual_delay, reason: error}` per attempt and emitted
      under `[:allm, :adapter, :retry]` **before** sleeping. The final
      attempt (when `attempt == max_attempts`) emits no retry event
      because the caller's surrounding `[:allm, :adapter, :stop]` /
      `:exception` span fires instead.

      `actual_delay = max(closure_delay_ms, computed_backoff)` where
      `computed_backoff = min(max_delay_ms,
      base_delay_ms * (2 ** (attempt - 1))) + jitter`. When
      `respect_retry_after: true` AND `closure_delay_ms > 0`,
      `actual_delay = closure_delay_ms + jitter` (the closure-supplied
      `Retry-After` value wins).

  Jitter bounds: jitter is **additive** in `[0, jitter_ms]`
  inclusive, never subtractive — the spec §6.1 `+ jitter(0..250ms)`
  notation is load-bearing. Implementation:
  `:rand.uniform(jitter_ms + 1) - 1`. Verified on OTP 27 in IEx
  2026-04-25: `:rand.uniform/1` returns `1..N` inclusive, and
  `:rand.uniform(1) - 1 == 0` when `jitter_ms == 0` (no jitter,
  deterministic delay).

  Closure-raised exceptions propagate to the caller unchanged — no
  rescue, no telemetry, no retry (spec §6.1 "exception is not
  retryable").

  ## Examples

      iex> {:ok, v} = ALLM.Retry.run(:no_retry, %{}, fn -> {:ok, 42} end)
      iex> v
      42

      iex> ALLM.Retry.run(:no_retry, %{}, fn -> {:retry, 0, :transient} end)
      {:error, :transient}

      iex> {:ok, _pid} = Agent.start(fn -> 0 end, name: :doctest_retry_counter)
      iex> {:ok, v} =
      ...>   ALLM.Retry.run(
      ...>     [base_delay_ms: 1, jitter_ms: 0],
      ...>     %{},
      ...>     fn ->
      ...>       n = Agent.get_and_update(:doctest_retry_counter, &{&1 + 1, &1 + 1})
      ...>       if n < 2, do: {:retry, 0, 429}, else: {:ok, n}
      ...>     end
      ...>   )
      iex> Agent.stop(:doctest_retry_counter)
      iex> v
      2
  """
  @spec run(policy() | :no_retry | engine_retry(), map(), (-> closure_result(ok))) ::
          {:ok, ok} | {:error, term()}
        when ok: var
  def run(policy_or_retry, telemetry_metadata, fun)
      when is_map(telemetry_metadata) and is_function(fun, 0) do
    case to_policy(policy_or_retry) do
      :no_retry -> run_once(fun)
      %{} = policy -> run_loop(policy, telemetry_metadata, fun, 1)
    end
  end

  @doc """
  Return `true` if `error` is a member of `retry_on`.

  Integers match HTTP status codes (`429 ∈ [429, 500, ...]`); atoms
  match error atoms (`:timeout`). For opaque error structs carrying a
  `:reason` field, the reason is extracted before membership check.

  ## Examples

      iex> retry_on = [429, 500, :timeout]
      iex> ALLM.Retry.error_matches?(429, retry_on)
      true
      iex> ALLM.Retry.error_matches?(400, retry_on)
      false
      iex> ALLM.Retry.error_matches?(%{reason: :timeout}, retry_on)
      true
  """
  @spec error_matches?(term(), [pos_integer() | atom()]) :: boolean()
  def error_matches?(%{reason: reason}, retry_on), do: reason in retry_on
  def error_matches?(error, retry_on), do: error in retry_on

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  @spec to_policy(policy() | :no_retry | engine_retry()) :: policy() | :no_retry
  defp to_policy(:no_retry), do: :no_retry
  defp to_policy(:default), do: default_policy()
  defp to_policy(false), do: :no_retry
  defp to_policy(opts) when is_list(opts), do: materialize(opts)
  defp to_policy(%{} = policy), do: policy

  @spec run_once((-> closure_result(any()))) :: {:ok, any()} | {:error, term()}
  defp run_once(fun) do
    case fun.() do
      {:ok, value} -> {:ok, value}
      {:retry, _delay_ms, error} -> {:error, error}
      {:error, error} -> {:error, error}
    end
  end

  @spec run_loop(policy(), map(), (-> closure_result(any())), pos_integer()) ::
          {:ok, any()} | {:error, term()}
  defp run_loop(%{max_attempts: max} = policy, telemetry_metadata, fun, attempt)
       when attempt <= max do
    case fun.() do
      {:ok, value} ->
        {:ok, value}

      {:error, error} ->
        {:error, error}

      {:retry, _delay_ms, error} when attempt == max ->
        # Final attempt — no further retry, no retry telemetry.
        # The caller's surrounding `[:allm, :adapter, :stop]` span fires.
        {:error, error}

      {:retry, delay_ms, error} ->
        if error_matches?(error, policy.retry_on) do
          actual_delay = compute_delay(policy, attempt, delay_ms)
          emit_retry_event(telemetry_metadata, attempt, actual_delay, error)
          Process.sleep(actual_delay)
          run_loop(policy, telemetry_metadata, fun, attempt + 1)
        else
          {:error, error}
        end
    end
  end

  # `actual_delay = max(closure_delay_ms, computed_backoff)`. When
  # `respect_retry_after: true` AND the closure supplied a positive
  # delay (e.g. parsed from a `Retry-After` header), the closure value
  # wins — `closure_delay_ms + jitter`. Otherwise compute exponential
  # backoff capped at `max_delay_ms`, plus additive jitter.
  @spec compute_delay(policy(), pos_integer(), non_neg_integer()) :: non_neg_integer()
  defp compute_delay(policy, attempt, closure_delay_ms) do
    jitter = jitter_amount(policy.jitter_ms)

    if policy.respect_retry_after and closure_delay_ms > 0 do
      closure_delay_ms + jitter
    else
      backoff = min(policy.max_delay_ms, policy.base_delay_ms * Integer.pow(2, attempt - 1))
      max(closure_delay_ms, backoff + jitter)
    end
  end

  # Additive jitter in `[0, jitter_ms]` inclusive (Decision #8).
  # `:rand.uniform/1` returns `1..N` on OTP 27; `:rand.uniform(jitter_ms + 1) - 1`
  # yields `[0, jitter_ms]`. When `jitter_ms == 0`, `:rand.uniform(1) - 1 == 0`
  # (no jitter, deterministic). Verified in IEx 2026-04-25.
  @spec jitter_amount(non_neg_integer()) :: non_neg_integer()
  defp jitter_amount(jitter_ms) when is_integer(jitter_ms) and jitter_ms >= 0 do
    :rand.uniform(jitter_ms + 1) - 1
  end

  @spec emit_retry_event(map(), pos_integer(), non_neg_integer(), term()) :: :ok
  defp emit_retry_event(telemetry_metadata, attempt, delay_ms, error) do
    Telemetry.execute(
      [:adapter, :retry],
      %{system_time: System.system_time()},
      Map.merge(telemetry_metadata, %{
        attempt: attempt,
        delay_ms: delay_ms,
        reason: error
      })
    )
  end
end
