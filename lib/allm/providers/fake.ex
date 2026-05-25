defmodule ALLM.Providers.Fake do
  @moduledoc """
  Deterministic, scripted adapter for testing. Implements both `ALLM.Adapter`
  and `ALLM.StreamAdapter`.

  Layer B — runtime. Fake is the canonical testing adapter that every
  orchestration phase (5, 6, 7, 8) tests against. It carries serializable
  plain data in `adapter_opts` and passes both the adapter- and
  stream-adapter conformance harnesses.

  ## What Fake is (and isn't)

  Fake **ignores the `%ALLM.Request{}`** passed to `generate/2` and `stream/2`.
  It never inspects the request's `:messages`, `:tools`, `:tool_choice`,
  `:temperature`, `:max_tokens`, or any other field. The scripted response is
  produced irrespective of the request. This is intentional: Fake is for
  testing orchestration, not provider-wire fidelity. Testing tool orchestration
  happens at (ToolRunner) and (Chat) — Fake's scripts directly
  emit `{:tool_call, _}` entries to simulate what the model would return; the
  caller sets up an engine with `tools: [...]` and a `{:tool_call,...}`
  script, and the orchestrator dispatches to the tool executor exactly as it
  would with a real provider.

  ## Script shapes

  Fake accepts two disjoint script shapes on `adapter_opts`. See
  `ALLM.Providers.Fake.Script` for the full tag-to-shape table.

  ### Spec (user-facing)

      adapter_opts: [
        script: [
          {:text, "Hello "},
          {:text, "world"},
          {:finish, :stop}
        ]
      ]

  Entry tags: `:text`, `:tool_call`, `:tool_call_delta`, `:usage`,
  `:raw_chunk`, `:finish`, `:error` (2-tuple), `:delay`, `:sleep`
  (deprecated alias of `:delay`).

  ### harness

      adapter_opts: [
        script: [{:ok, %{output_text: "hi"}}],
        stream_script: [[{:text_delta, "hel"}, {:text_delta, "lo"}, {:finish, :stop}]]
      ]

  Entry tags (non-streaming, on `:script`): `{:ok, map}`, `{:error, reason_atom, keyword}`.
  Entry tags (streaming, on `:stream_script`): `:text_delta`, `:finish`,
  `:preflight_error`, `:error_event`, `:stream_error`, shared-semantics
  `:tool_call` / `:finish`.

  ### Per-entry-point key precedence

  | Entry point | Key precedence |
  |-------------|----------------|
  | `generate/2` | `:scripts` > `:script` (wrapped as `[script]`). `:stream_script` is not consulted; if only `:stream_script` is set, `generate/2` returns `:no_scripted_response`. |
  | `stream/2` | `:stream_script` > `:scripts` > `:script` (wrapped as `[script]`). |

  Multi-call scripting uses `:scripts` / `:stream_script` as a list of lists
  each call consumes one inner list and advances the cursor.

  ### Disambiguation

  For `generate/2`, both shapes share the `:script` key and are disambiguated
  by leading entry tag. The `:error` tag disambiguates by `tuple_size/1`
  (2 →, 3 → harness). For `stream/2`, distinct keys disambiguate.

  ## Cursor behaviour

  Multi-call scripts (`:scripts` / `:stream_script`) advance a per-process
  cursor on every call. By default the cursor lives in the process dictionary
  at `{:allm_fake_cursor, :erlang.phash2(scripts)}` — isolated per ExUnit test
  process (`async: true`), GC'd on pid-down, zero-setup for the common case.

  **Two engines built with content-equal `:scripts` values in the same
  process share a cursor.** This is a documented footgun: the cursor key is
  `:erlang.phash2(scripts)`, so identical script contents collide. A test
  that constructs two Fake engines simulating two distinct providers with the
  same fixture script finds the second engine's first call already at index 1.
  Workaround: pass distinct `adapter_opts[:script_cursor]` Agent pids,
  obtained from `start_script_cursor/0`.

  The explicit-Agent override also supports cross-process cursor sharing
  (`Task.async/1` over the adapter call) and mitigates the rare hash-collision
  case (`:erlang.phash2/1` is a 27-bit hash).

  ## Testing patterns

  **Use `start_script_cursor/0` for multi-call tests.** Reach for the explicit
  Agent cursor whenever a test (a) runs multiple Fake calls with a `:scripts`
  or `:stream_script` list AND (b) another test in the same `async: true`
  module could share content-equal script entries, OR (c) the test dispatches
  the adapter call across processes (`Task.async/1`). The default
  process-dict cursor is fine for one-shot `:script` calls and for
  single-multi-call tests whose script content is unique in the module; for
  everything else, the explicit cursor is load-bearing:

      cursor = ALLM.Providers.Fake.start_script_cursor
      opts = [adapter_opts: [scripts: [...]] ++ [script_cursor: cursor]]

  Worked examples: `test/allm/providers/fake_test.exs:143` and
  `test/allm/providers/fake/fixtures_test.exs:66`.

  ## Cleanup observation

  When `adapter_opts[:cleanup_observer]` is a `:counters` ref (as created by
  `:counters.new(1, [:atomics])`), the `Stream.resource/3` `after_fun`
  increments index 1 on every normal termination path — consumer
  `Enum.take/N`, `Stream.take_while/2` returning false, `Stream.run/1` scope
  exit, throws from the reducer, consumer process exit with a trappable
  reason. The counter increments at most once per stream (not once-per-event).

  Halt-safety test shape:

      ref = :counters.new(1, [:atomics])
      {:ok, stream} = ALLM.Providers.Fake.stream(req,
        adapter_opts: [script: [...], cleanup_observer: ref])
      _ = Enum.take(stream, 2)
      # :counters.get(ref, 1) == 1 within 500 ms

  **Brutal-kill caveat.** `Stream.resource/3`'s `after_fun` does NOT run when
  the consumer is killed with `Process.exit(pid, :kill)` — brutal exits skip
  all cleanup by OTP design. Real provider adapters address this
  via Finch's own monitor-based connection cleanup; Fake has no HTTP ref to
  leak so the caveat is purely documentary. Tests assert cleanup on normal
  halts only; no test should simulate `:kill`.

  ## Adapter event vocabulary (streaming)

  **Emitted** :
  `:message_started`, `:text_delta`, `:text_completed`, `:tool_call_started`,
  `:tool_call_delta`, `:tool_call_completed`, `:message_completed`,
  `:raw_chunk`, `:error`.

  **Not emitted** (orchestrator-owned — /7):
  `:tool_execution_started`, `:tool_execution_completed`, `:tool_result_encoded`,
  `:ask_user_requested`, `:tool_halt`, `:step_completed`, `:chat_completed`.

  ## Backpressure and delays

  `{:delay, ms}` entries call `Process.sleep/1` inside the `next_fun` of the
  `Stream.resource/3` — the delay blocks the consumer's reducing process, not
  a simulated provider. `{:delay, _}` is **front-loaded**: the interpreter
  sleeps before consuming the NEXT entry, so placing `{:delay, ms}` as the
  FIRST entry delays `:message_started`. Timing tests measure the wall-clock
  interval between the emit preceding the `{:delay, _}` entry and the emit
  following it.

  `{:sleep, ms}` is a deprecated alias for `{:delay, ms}` — one `Logger.warning/1`
  fires per BEAM lifetime when `{:sleep, _}` is used. Deletion target: v0.3.

  ## Examples

      iex> req = ALLM.Request.new([%ALLM.Message{role: :user, content: "hi"}])
      iex> opts = [adapter_opts: [script: [{:text, "hi"}, {:finish, :stop}]]]
      iex> {:ok, resp} = ALLM.Providers.Fake.generate(req, opts)
      iex> {resp.output_text, resp.finish_reason}
      {"hi", :stop}
  """

  @behaviour ALLM.Adapter
  @behaviour ALLM.StreamAdapter

  alias ALLM.Error.AdapterError
  alias ALLM.Message
  alias ALLM.Providers.Fake.Script

  # ---------------------------------------------------------------------------
  # ALLM.Adapter — generate/2
  # ---------------------------------------------------------------------------

  @doc """
  Execute a scripted non-streaming request.

  Reads the script from `opts[:adapter_opts]`, validates via
  `ALLM.Providers.Fake.Script.validate!/1`, resolves the cursor, folds the
  current call's entries into a `%ALLM.Response{}` via
  `ALLM.Providers.Fake.Script.fold_to_response/1`, and advances the cursor.

  Ignores the `%Request{}` entirely — the scripted response is produced
  irrespective of the request's messages, tools, or params (see "What Fake is
  (and isn't)" in the moduledoc).

  Returns `{:ok, %ALLM.Response{}}` on a scripted success (including
  harness-shape `{:ok, _}` entries), `{:error, %AdapterError{}}` on a scripted
  failure or a script-exhausted cursor. `adapter_opts[:request_id]` is
  propagated onto `response.request_id` verbatim.

  ## Examples

      iex> req = ALLM.Request.new([%ALLM.Message{role: :user, content: "x"}])
      iex> opts = [adapter_opts: [script: [{:text, "hello"}, {:finish, :stop}]]]
      iex> {:ok, resp} = ALLM.Providers.Fake.generate(req, opts)
      iex> resp.output_text
      "hello"
  """
  @impl ALLM.Adapter
  @spec generate(ALLM.Request.t(), keyword()) ::
          {:ok, ALLM.Response.t()} | {:error, AdapterError.t()}
  def generate(request, opts) do
    adapter_opts = Keyword.get(opts, :adapter_opts, [])
    :ok = Script.validate!(adapter_opts)

    # Phase 21.2 (F2): when `adapter_opts[:record]` is a pid, send
    # `{:allm_fake_record, request, opts}` verbatim BEFORE the script
    # interpretation runs. Fire-and-forget; a dead pid raises ArgumentError
    # — a dead recording pid is a test bug, not Fake's problem.
    :ok = maybe_send_record(adapter_opts, request, opts)

    # Phase 9.3: wrap the per-call work in `ALLM.Retry.run/3` so the
    # `retry_until_call: n` opt drives a real retry loop and emits
    # `[:allm, :adapter, :retry]` per attempt. Outside of retry tests
    # the closure returns `{:ok, response}` on first call (the counter
    # absent path is a no-op).
    retry_policy = Keyword.get(opts, :retry, :default)
    telemetry_meta = build_retry_telemetry_meta(opts)

    ALLM.Retry.run(retry_policy, telemetry_meta, fn ->
      generate_attempt(adapter_opts)
    end)
  end

  # ---------------------------------------------------------------------------
  # ALLM.StreamAdapter — stream/2
  # ---------------------------------------------------------------------------

  @doc """
  Open a scripted streaming request.

  Reads the script from `opts[:adapter_opts]`, validates via
  `ALLM.Providers.Fake.Script.validate!/1`, resolves the cursor, and returns
  a lazy `Enumerable.t` of `ALLM.Event` values. No event fires until the
  consumer reduces.

  Key precedence: `:stream_script` > `:scripts` > `:script` (wrapped as
  `[script]`). Empty opts return `{:error, script_exhausted_error}` (no
  stream opened).

  When the first entry of the current call is a harness-shape
  `{:preflight_error, reason, opts}`, returns synchronously as
  `{:error, %AdapterError{reason: ^reason,...opts}}` — no stream is opened.

  The returned stream emits `:message_started` on open, per-entry events via
  `ALLM.Providers.Fake.Script.interpret/1`, and closes with
  `:message_completed` (prepended by `:text_completed` if any `:text`/`:text_delta`
  was emitted). `{:delay, ms}` / `{:sleep, ms}` entries call `Process.sleep/1`
  and yield no events. `after_fun` increments `adapter_opts[:cleanup_observer]`
  (a `:counters` ref, when present).

  Ignores the `%Request{}` (see "What Fake is (and isn't)" in the moduledoc).

  ## Examples

      iex> req = ALLM.Request.new([%ALLM.Message{role: :user, content: "x"}])
      iex> opts = [adapter_opts: [script: [{:text, "hi"}, {:finish, :stop}]]]
      iex> {:ok, stream} = ALLM.Providers.Fake.stream(req, opts)
      iex> events = Enum.to_list(stream)
      iex> Enum.any?(events, &match?({:text_delta, %{delta: "hi"}}, &1))
      true
  """
  @impl ALLM.StreamAdapter
  @spec stream(ALLM.Request.t(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, AdapterError.t()}
  def stream(request, opts) do
    adapter_opts = Keyword.get(opts, :adapter_opts, [])
    :ok = Script.validate!(adapter_opts)

    # Phase 21.2 (F2): record at call-open time (before the stream is built).
    :ok = maybe_send_record(adapter_opts, request, opts)

    # Phase 9.3: spec §6.1 — streaming calls are NOT retried. We do
    # NOT call `ALLM.Retry.run/3` here. Instead, when
    # `retry_until_call: n` is set we share the same per-process
    # counter as `generate/2` and, on the first n-1 calls, surface the
    # transient failure as a terminal `{:error, _}` event mid-stream.
    # The consumer reduces it to `%Response{finish_reason: :error}`
    # per CLAUDE.md's "mid-stream errors fold into the response, not
    # the call-site tuple" invariant.
    case maybe_retry_transient(adapter_opts) do
      :retry ->
        {:ok, transient_error_stream()}

      :proceed ->
        case resolve_scripts_for_stream(adapter_opts) do
          :empty ->
            {:error, script_exhausted_error()}

          {:ok, scripts} ->
            open_stream(scripts, adapter_opts)
        end
    end
  end

  # A minimal stream that emits `:message_started` and a terminal
  # `{:error, %AdapterError{}}` event. Used when `retry_until_call:` is
  # set and the counter says this call should fail transiently; the
  # downstream collector folds the terminal error into
  # `%Response{finish_reason: :error}`.
  defp transient_error_stream do
    err = AdapterError.new(:timeout, message: "scripted transient stream failure")

    Stream.resource(
      fn ->
        [{:message_started, %{message: %Message{role: :assistant, content: ""}}}, {:error, err}]
      end,
      fn
        [] -> {:halt, []}
        events -> {events, []}
      end,
      fn _ -> :ok end
    )
  end

  # ---------------------------------------------------------------------------
  # Public helpers
  # ---------------------------------------------------------------------------

  @doc """
  Return the canonical `%AdapterError{}` for a script-exhausted call.

  Spec phrases this as `{:error, :no_scripted_response}`; the atom is
  preserved as the struct's `:reason` field via the enum amendment.

  ## Examples

      iex> err = ALLM.Providers.Fake.script_exhausted_error
      iex> err.reason
      :no_scripted_response
      iex> err.message
      "no scripted response"
  """
  @spec script_exhausted_error() :: AdapterError.t()
  def script_exhausted_error do
    %AdapterError{reason: :no_scripted_response, message: "no scripted response"}
  end

  @doc """
  Start an Agent-backed script cursor for cross-process multi-call scripting
  and for disambiguating content-equal scripts in the same process (see
  moduledoc "Cursor behaviour").

  Pass the returned pid as `adapter_opts[:script_cursor]`; subsequent calls
  increment the cursor on the Agent rather than on the process dictionary.

  ## Examples

      iex> pid = ALLM.Providers.Fake.start_script_cursor
      iex> ALLM.Providers.Fake.cursor_index(pid)
      0
  """
  @spec start_script_cursor() :: pid()
  def start_script_cursor do
    {:ok, pid} = Agent.start_link(fn -> 0 end)
    pid
  end

  @doc """
  Read the current cursor index for an Agent-backed cursor. Used in tests to
  assert how many calls have been consumed.
  """
  @spec cursor_index(pid()) :: non_neg_integer()
  def cursor_index(pid) when is_pid(pid), do: Agent.get(pid, & &1)

  # ---------------------------------------------------------------------------
  # Internals — generate/2 + retry plumbing
  # ---------------------------------------------------------------------------

  # One attempt of the scripted generate path. Returns one of the
  # `ALLM.Retry.closure_result/1` shapes (`{:ok, _} | {:retry, _, _}
  # | {:error, _}`). When `retry_until_call: n` is set on
  # `adapter_opts`, the first n-1 attempts return `{:retry, 0,
  # :fake_transient}`; attempt n returns the scripted `{:ok, response}`
  # (or `{:error, _}` if the script is configured to fail there).
  defp generate_attempt(adapter_opts) do
    case maybe_retry_transient(adapter_opts) do
      :retry ->
        # `:timeout` is in the default `retry_on` set (spec §6.1) so the
        # bare-atom error matches under the default policy. Tests
        # exercising custom `retry_on` lists pass a policy that
        # includes `:timeout`.
        {:retry, 0, :timeout}

      :proceed ->
        case resolve_scripts_for_generate(adapter_opts) do
          {:ok, scripts} -> wrap_generate_result(run_generate_call(scripts, adapter_opts))
          :empty -> {:error, script_exhausted_error()}
        end
    end
  end

  # Convert the raw `run_generate_call/2` return into the
  # `closure_result/1` shape consumed by `ALLM.Retry.run/3`. The Fake
  # uses non-retryable `{:error, _}` for scripted errors (a real adapter
  # would inspect the status code and decide).
  defp wrap_generate_result({:ok, _} = ok), do: ok
  defp wrap_generate_result({:error, %AdapterError{} = err}), do: {:error, err}

  # Decrement the per-process retry counter (keyed by the
  # `retry_until_call:` opt's identity). Returns `:retry` while the
  # counter is > 1 and `:proceed` when the counter has reached 1 (the
  # call that should succeed). Absent opt → always `:proceed`.
  defp maybe_retry_transient(adapter_opts) do
    case Keyword.get(adapter_opts, :retry_until_call) do
      nil ->
        :proceed

      n when is_integer(n) and n >= 1 ->
        decrement_retry_counter(n)
    end
  end

  # The counter lives in the calling process's process dictionary so the
  # streaming and non-streaming arms share state — the test plan
  # specifies that `Fake.stream/2` honours `retry_until_call:` from the
  # SAME counter as `Fake.generate/2`. Test isolation is per-PID
  # (`async: true` is safe — each ExUnit test runs in its own process).
  @retry_counter_key {__MODULE__, :retry_until_call}

  defp decrement_retry_counter(initial) do
    current = Process.get(@retry_counter_key, initial)

    if current > 1 do
      Process.put(@retry_counter_key, current - 1)
      :retry
    else
      # The successful attempt: reset the counter so a subsequent test
      # in the same process (or a follow-up call) starts fresh.
      Process.delete(@retry_counter_key)
      :proceed
    end
  end

  # Telemetry metadata attached to every `[:allm, :adapter, :retry]`
  # event from this adapter. `:request_id` is propagated from the
  # surrounding span (set by `Runner.run/3` / `StreamRunner.run/3` per
  # Phase 9.1) so retry events correlate with their parent generate
  # / step / chat span.
  defp build_retry_telemetry_meta(opts) do
    %{provider: :fake}
    |> maybe_put_meta(:request_id, Keyword.get(opts, :request_id))
  end

  defp maybe_put_meta(meta, _key, nil), do: meta
  defp maybe_put_meta(meta, key, value), do: Map.put(meta, key, value)

  # generate/2 reads :scripts > :script. :stream_script is ignored per
  # key-precedence table in the moduledoc.
  defp resolve_scripts_for_generate(adapter_opts) do
    cond do
      Keyword.has_key?(adapter_opts, :scripts) ->
        {:ok, Keyword.fetch!(adapter_opts, :scripts)}

      Keyword.has_key?(adapter_opts, :script) ->
        {:ok, [Keyword.fetch!(adapter_opts, :script)]}

      true ->
        :empty
    end
  end

  defp run_generate_call(scripts, adapter_opts) do
    cursor = advance_cursor(scripts, adapter_opts)

    case Enum.at(scripts, cursor) do
      nil ->
        {:error, script_exhausted_error()}

      entries ->
        entries
        |> Script.fold_to_response()
        |> wrap_fold_result(adapter_opts, entries)
    end
  end

  # Wrap the fold output in an {:ok, _} | {:error, _} tuple and propagate
  # request_id / empty-script metadata onto the Response.
  defp wrap_fold_result({:error, %AdapterError{}} = err, _adapter_opts, _entries), do: err

  defp wrap_fold_result(%ALLM.Response{} = resp, adapter_opts, entries) do
    resp =
      resp
      |> maybe_attach_request_id(adapter_opts)
      |> maybe_attach_empty_metadata(entries)
      |> maybe_override_usage(adapter_opts)

    {:ok, resp}
  end

  # Phase 21.2 (F1): when `adapter_opts[:usage]` is set, normalize via
  # `normalize_usage/1` and override `response.usage`. The adapter-opt
  # wins over any per-script `{:usage, _}` entry (last-write-wins at the
  # adapter boundary).
  defp maybe_override_usage(%ALLM.Response{} = resp, adapter_opts) do
    case Keyword.get(adapter_opts, :usage) do
      nil -> resp
      usage -> %{resp | usage: normalize_usage(usage)}
    end
  end

  # Normalize a `:usage` adapter_opt value: accept either a pre-built
  # `%ALLM.Usage{}` (pass-through) or a keyword list (route through
  # `ALLM.Usage.new/1`).
  defp normalize_usage(%ALLM.Usage{} = usage), do: usage
  defp normalize_usage(kw) when is_list(kw), do: ALLM.Usage.new(kw)

  defp maybe_attach_request_id(%ALLM.Response{} = resp, adapter_opts) do
    case Keyword.get(adapter_opts, :request_id) do
      nil -> resp
      req_id when is_binary(req_id) -> %{resp | request_id: req_id}
    end
  end

  defp maybe_attach_empty_metadata(%ALLM.Response{metadata: meta} = resp, []) do
    %{resp | metadata: Map.put(meta, :empty_script, true)}
  end

  defp maybe_attach_empty_metadata(%ALLM.Response{} = resp, _entries), do: resp

  # ---------------------------------------------------------------------------
  # Internals — stream/2
  # ---------------------------------------------------------------------------

  # stream/2 reads :stream_script > :scripts > :script.
  #
  # :stream_script is polymorphic — either a list-of-lists (multi-call, one
  # inner list per call) or a flat list of entries (single-call). We
  # normalize by wrapping a flat list as `[list]`. Detection: if every
  # element is itself a list, it's list-of-lists. The Phase 3 harness
  # passes both forms (single-call pre-flight tests pass a flat list;
  # multi-call tests pass a list-of-lists).
  defp resolve_scripts_for_stream(adapter_opts) do
    cond do
      Keyword.has_key?(adapter_opts, :stream_script) ->
        {:ok, normalize_multi_call(Keyword.fetch!(adapter_opts, :stream_script))}

      Keyword.has_key?(adapter_opts, :scripts) ->
        {:ok, Keyword.fetch!(adapter_opts, :scripts)}

      Keyword.has_key?(adapter_opts, :script) ->
        {:ok, [Keyword.fetch!(adapter_opts, :script)]}

      true ->
        :empty
    end
  end

  # Normalize a possibly-flat script list into a list-of-lists. An empty
  # list is treated as "one empty call" so the cursor advances and the
  # stream closes well-formed rather than being misread as exhausted.
  defp normalize_multi_call([]), do: [[]]

  defp normalize_multi_call(list) when is_list(list) do
    if Enum.all?(list, &is_list/1), do: list, else: [list]
  end

  defp open_stream(scripts, adapter_opts) do
    cursor = advance_cursor(scripts, adapter_opts)

    case Enum.at(scripts, cursor) do
      nil -> {:error, script_exhausted_error()}
      entries -> dispatch_entries(entries, adapter_opts)
    end
  end

  defp dispatch_entries(entries, adapter_opts) do
    case preflight_error(entries) do
      {:preflight, err} -> {:error, err}
      :no_preflight -> {:ok, build_stream_from_entries(entries, adapter_opts)}
    end
  end

  defp build_stream_from_entries(entries, adapter_opts) do
    observer = Keyword.get(adapter_opts, :cleanup_observer)
    # Phase 21.2 (F1): pre-normalize the adapter-opt usage so the stream's
    # `:message_completed` payload picks it up via `metadata.usage` without
    # re-parsing per call.
    forced_usage = forced_usage_from_opts(adapter_opts)
    build_stream(entries, observer, forced_usage)
  end

  defp forced_usage_from_opts(adapter_opts) do
    case Keyword.get(adapter_opts, :usage) do
      nil -> nil
      u -> normalize_usage(u)
    end
  end

  defp preflight_error([{:preflight_error, reason, opts} | _])
       when is_atom(reason) and is_list(opts) do
    {:preflight, AdapterError.new(reason, opts)}
  end

  defp preflight_error(_entries), do: :no_preflight

  # Build the Stream.resource/3 — the heart of stream/2.
  #
  # Stream.resource/3's start_fun returns the initial acc (no events). We
  # stash a `:message_started` event in the acc's `:pending` list so the
  # first next_fun call emits it before consuming any entry. This keeps
  # `:message_started` synchronous with the consumer's first reduce.
  defp build_stream(entries, observer, forced_usage) do
    Stream.resource(
      fn -> start_fun(entries, observer, forced_usage) end,
      &next_fun/1,
      &after_fun/1
    )
  end

  defp start_fun(entries, observer, forced_usage) do
    msg = %Message{role: :assistant, content: ""}

    %{
      entries: entries,
      emitted_text?: false,
      cleanup_observer: observer,
      accumulated_text: "",
      closed?: false,
      finish_reason: nil,
      # Phase 21.2 (F1): `:usage` adapter-opt wins; otherwise the LAST
      # per-script `{:usage, _}` entry seen in the stream becomes
      # `metadata.usage` on `:message_completed`. `nil` means "no usage
      # to surface" — the payload key is omitted entirely (preserves the
      # existing closed payload shape for consumers).
      forced_usage: forced_usage,
      script_usage: nil,
      pending: [{:message_started, %{message: msg}}]
    }
  end

  # next_fun — emit pending events first, then pop one entry. Handles:
  # - :delay / :sleep : Process.sleep and recurse without emitting.
  # - :finish : emit :text_completed (if text was seen) + :message_completed,
  #   then halt after the next pull.
  # - every other entry : delegate to Script.interpret/1 (tracking
  #   emitted_text? when the interpreted events include :text_delta).
  # - empty entries list : emit :message_completed (with optional
  #   :text_completed prefix), mark closed, halt next pull.
  defp next_fun(%{pending: [_ | _] = pending} = acc) do
    {pending, %{acc | pending: []}}
  end

  defp next_fun(%{closed?: true} = acc), do: {:halt, acc}

  defp next_fun(%{entries: []} = acc), do: close_stream(acc)

  defp next_fun(%{entries: [{:delay, ms} | rest]} = acc)
       when is_integer(ms) and ms >= 0 do
    Process.sleep(ms)
    next_fun(%{acc | entries: rest})
  end

  defp next_fun(%{entries: [{:sleep, ms} | rest]} = acc)
       when is_integer(ms) and ms >= 0 do
    # Script.interpret/1 fires the one-time deprecation log for :sleep; we
    # reuse that path by delegating here. The returned `[]` is discarded
    # (sleep entries emit no events); the sleep itself must happen here, not
    # inside interpret/1, because interpret/1 is pure.
    _ = Script.interpret({:sleep, ms})
    Process.sleep(ms)
    next_fun(%{acc | entries: rest})
  end

  defp next_fun(%{entries: [{:finish, reason} | rest]} = acc) do
    acc = %{acc | finish_reason: reason}
    closing = closing_events(acc)
    {closing, %{acc | entries: rest, closed?: true}}
  end

  # Phase 21.2 (F1): a per-script `{:usage, _}` entry is absorbed into
  # `acc.script_usage` so the LAST one folds onto `:message_completed`'s
  # `metadata.usage`. Pre-21.2 this entry surfaced as a `:raw_chunk`
  # event via `Script.interpret/1` (`lib/allm/providers/fake/script.ex:309`);
  # post-21.2 the streaming arm reroutes it onto the payload's metadata
  # key so `StreamCollector.collect/1` produces a `%Response{usage: _}`
  # without a parallel `:raw_chunk` channel.
  defp next_fun(%{entries: [{:usage, map} | rest]} = acc) when is_map(map) do
    usage = struct!(ALLM.Usage, map)
    next_fun(%{acc | entries: rest, script_usage: usage})
  end

  defp next_fun(%{entries: [entry | rest]} = acc) do
    events = Script.interpret(entry)
    acc = update_emitted_text(acc, events)
    {events, %{acc | entries: rest}}
  end

  # No finish entry remained — synthesize the terminal :message_completed
  # (with optional :text_completed) so every stream closes well-formed.
  defp close_stream(acc) do
    closing = closing_events(acc)
    {closing, %{acc | closed?: true}}
  end

  defp closing_events(%{emitted_text?: true, accumulated_text: text} = acc) do
    payload =
      maybe_attach_usage_metadata(
        %{message: %Message{role: :assistant, content: text}, finish_reason: acc.finish_reason},
        acc
      )

    [
      {:text_completed, %{id: nil, text: text}},
      {:message_completed, payload}
    ]
  end

  defp closing_events(%{emitted_text?: false} = acc) do
    payload =
      maybe_attach_usage_metadata(
        %{message: %Message{role: :assistant, content: ""}, finish_reason: acc.finish_reason},
        acc
      )

    [{:message_completed, payload}]
  end

  # Phase 21.2 (F1): attach `metadata.usage` to the `:message_completed`
  # payload when EITHER `adapter_opts[:usage]` was set (`forced_usage`
  # wins) OR a per-script `{:usage, _}` entry was observed. Absence is a
  # no-op — the payload's pre-21.2 shape is preserved verbatim.
  defp maybe_attach_usage_metadata(payload, %{forced_usage: %ALLM.Usage{} = u}) do
    Map.put(payload, :metadata, %{usage: u})
  end

  defp maybe_attach_usage_metadata(payload, %{script_usage: %ALLM.Usage{} = u}) do
    Map.put(payload, :metadata, %{usage: u})
  end

  defp maybe_attach_usage_metadata(payload, _acc), do: payload

  # Track whether any :text_delta has been emitted so we know whether to
  # prepend :text_completed at close. Also accumulate the text so
  # :text_completed and :message_completed carry the full content.
  defp update_emitted_text(acc, events) do
    Enum.reduce(events, acc, fn
      {:text_delta, %{delta: d}}, a when is_binary(d) ->
        %{a | emitted_text?: true, accumulated_text: a.accumulated_text <> d}

      _, a ->
        a
    end)
  end

  # Cleanup observer increment. Runs on normal termination (including halt
  # via Enum.take/2). Does not run on brutal :kill (documented caveat).
  defp after_fun(%{cleanup_observer: nil}), do: :ok

  defp after_fun(%{cleanup_observer: observer}) do
    :counters.add(observer, 1, 1)
    :ok
  rescue
    # If the observer isn't a counters ref, swallow silently — this is a
    # test-only hook and a bogus observer value shouldn't mask the real
    # test failure.
    _ -> :ok
  end

  # ---------------------------------------------------------------------------
  # Internals — :record opt (Phase 21.2 / F2)
  # ---------------------------------------------------------------------------

  # When `adapter_opts[:record]` is a pid, send `{:allm_fake_record,
  # request, opts}` verbatim. No key scrubbing — the caller owns the
  # opts they passed in. Fake never resolves real API keys (no
  # `ALLM.Keys.fetch!/2` path), BUT a BYOK-flow caller's `opts[:api_key]`
  # flows in verbatim per `lib/allm/stream_runner.ex`'s
  # `maybe_put_api_key/2`. Callers wanting redaction can
  # `Keyword.delete(opts, :api_key)` before asserting on the recorded
  # message. A dead pid is treated as a test bug: `Process.alive?/1` is
  # checked first and `ArgumentError` is raised with the dead pid in the
  # message so the failure surfaces inside the test body rather than as
  # a silently-lost `send/2`.
  defp maybe_send_record(adapter_opts, request, opts) do
    case Keyword.get(adapter_opts, :record) do
      nil ->
        :ok

      pid when is_pid(pid) ->
        unless Process.alive?(pid) do
          raise ArgumentError,
                "ALLM.Providers.Fake :record pid #{inspect(pid)} is not alive — pass self() or a live pid"
        end

        send(pid, {:allm_fake_record, request, opts})
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Internals — cursor management (shared by generate/2 and stream/2)
  # ---------------------------------------------------------------------------

  # Returns the CURRENT index and advances the stored cursor by one. When
  # `adapter_opts[:script_cursor]` is a pid, the Agent is the source of
  # truth; otherwise the process dictionary is.
  defp advance_cursor(scripts, adapter_opts) do
    case Keyword.get(adapter_opts, :script_cursor) do
      nil ->
        advance_process_dict_cursor(scripts)

      pid when is_pid(pid) ->
        Agent.get_and_update(pid, fn i -> {i, i + 1} end)
    end
  end

  defp advance_process_dict_cursor(scripts) do
    key = {:allm_fake_cursor, :erlang.phash2(scripts)}
    current = Process.get(key, 0)
    Process.put(key, current + 1)
    current
  end
end
