defmodule ALLM.Providers.FakeModeration do
  @moduledoc """
  Deterministic, scripted adapter for content-moderation testing. Implements
  `ALLM.ModerationAdapter`.

  Layer B — runtime. FakeModeration is the canonical testing moderation
  adapter; it ships in `lib/` (not `test/support/`) because users need it for
  their own application tests, mirroring the `ALLM.Providers.Fake`,
  `ALLM.Providers.FakeImages`, and `ALLM.Providers.FakeEmbeddings` precedent.

  ## What FakeModeration is (and isn't)

  FakeModeration **mostly ignores the `%ALLM.ModerationRequest{}`** passed to
  `moderate/2`. It inspects `:input` to enforce the empty-input and
  batch-size gates the `ALLM.ModerationAdapter` contract requires of every
  implementation, and to size the *default* verdict; it reads `:model` and
  `:metadata` to round-trip them onto the response. Otherwise the scripted
  response is produced irrespective of the request — in particular no
  scripted verdict is derived from the input text, and a `{:ok, results}`
  entry decides how many results come back, not `length(input)`.

  ## Default verdict (no script)

  With **no script** — `adapter_opts[:moderation_script]` absent or `[]` —
  every input yields one unflagged `ALLM.ModerationResult` carrying all 13
  `omni-moderation` category names, every value `false` and every score
  `0.0`. Cardinality follows `ALLM.ModerationRequest`'s rule: `length(input)`
  results for an all-strings input, exactly one result for a multimodal one.

  This is a deliberate divergence from `ALLM.Providers.FakeEmbeddings`, whose
  *no-script* call surfaces an error: a clean verdict is a meaningful default
  that costs a caller nothing, whereas a synthesized embedding vector is
  not.

  ## Spent script

  A **non-empty** script whose cursor has run off the end is a different case
  and does NOT fall back to the clean verdict — it returns

      {:error, %ALLM.Error.ModerationAdapterError{
         reason: :unknown,
         metadata: %{cause: :moderation_script_exhausted}}}

  "I didn't script anything, give me a benign default" is a convenience;
  "my script ran out" is almost always an off-by-one in the *caller's*
  expectation of how many times `moderate/2` gets invoked, and a test vehicle
  that answers it with an unflagged pass hides that bug. In particular a
  truncated `[{:retry_until_call, 1}]` script would otherwise report success
  on call 1 with no retry ever exercised.

  ## Script shapes

  `opts[:adapter_opts][:moderation_script]` accepts a list of script entries.
  See `script/1` for the full grammar.

      adapter_opts: [
        moderation_script: [
          {:ok, [%ALLM.ModerationResult{...}]},
          {:flagged, ["violence"]},
          {:error, %ALLM.Error.ModerationAdapterError{reason: :rate_limited}},
          {:retry_until_call, 3}
        ]
      ]

  `{:flagged, categories}` is the shorthand for the overwhelmingly common
  test — "assert my app rejects flagged content" — and synthesizes a single
  flagged result with those category names `true` at score `1.0` and every
  other omni category `false` at `0.0`.

  `{:retry_until_call, n}` returns a synthetic
  `%ALLM.Error.ModerationAdapterError{reason: :rate_limited, retry_after_ms: 0}`
  for the first `n - 1` calls against this entry, then advances the cursor to
  the next entry on call `n`. Vehicle for testing `ALLM.Retry.run/3`
  integration. Consecutive `{:retry_until_call, _}` entries **chain**: the
  call that exhausts one entry's budget lands on the next entry and opens its
  budget, which is how a layered retry budget is scripted.

  ## Cursor behaviour

  Multi-call scripts (`:moderation_script`) advance a per-process cursor on
  every call. The cursor lives in the process dictionary at
  `{:allm_fake_moderation_cursor, key_id}`, isolated per ExUnit test process
  (`async: true`), GC'd on pid-down, zero-setup for the common case. The
  `key_id` is chosen by this precedence:

    1. `adapter_opts[:script_cursor]` — an explicit Agent pid (handled
       separately; see `start_script_cursor/0`).
    2. `adapter_opts[:cursor_key]` — the engine's stable `:id`, injected by
       the façade dispatch chokepoint via `ALLM.Engine.put_cursor_key/2`.
    3. `:erlang.phash2(script)` — the content-hash fallback for direct
       adapter calls with no engine.

  At the façade the cursor keys on engine identity, so two engines built with
  content-equal `:moderation_script` values each read index 0 on their first
  call, even in the same process. **The content-hash footgun remains only for
  DIRECT adapter calls** — `ALLM.Providers.FakeModeration.moderate(req, opts)`
  invoked without an engine receives no `:cursor_key`. Workaround for that
  path: pass distinct `adapter_opts[:script_cursor]` Agent pids from
  `start_script_cursor/0`.

  ## Test-only capture seam

  Pass `adapter_opts[:capture_pid]` with a pid to receive a side-channel
  message every time `moderate/2` is invoked, BEFORE any gate runs and before
  the script is consulted. The message has the form:

      {ALLM.Providers.FakeModeration, :call, %{request: request, opts: opts}}

  This is purely a side-channel — it does NOT affect the response. It exists
  so test files can assert on what the adapter received without the
  `Process.register/2` + named-pid pattern (which forces `async: false`).

  ## Examples

      iex> req = ALLM.ModerationRequest.new(input: ["is this ok?"])
      iex> opts = [adapter_opts: [moderation_script: [{:flagged, ["violence"]}]]]
      iex> {:ok, resp} = ALLM.Providers.FakeModeration.moderate(req, opts)
      iex> ALLM.ModerationResponse.flagged_categories(resp)
      ["violence"]
  """

  @behaviour ALLM.ModerationAdapter

  alias ALLM.Error.ModerationAdapterError
  alias ALLM.{ModerationRequest, ModerationResponse, ModerationResult}

  @adapter_max_batch_size 32

  # The 13 category names `omni-moderation-*` reports. String-keyed and
  # provider-shaped by design — see `ALLM.ModerationResult`.
  @omni_categories ~w(
    harassment
    harassment/threatening
    hate
    hate/threatening
    illicit
    illicit/violent
    self-harm
    self-harm/instructions
    self-harm/intent
    sexual
    sexual/minors
    violence
    violence/graphic
  )

  # ---------------------------------------------------------------------------
  # ALLM.ModerationAdapter — max_batch_size/0
  # ---------------------------------------------------------------------------

  @doc """
  Return the maximum number of inputs FakeModeration accepts per call.

  Deliberately **not** a provider-shaped number. The real moderation cap is
  undocumented, and a mirrored constant would force every conformance run to
  build a list of that size just to cross the `:batch_too_large` boundary.
  32 is large enough to be plausible and small enough to be cheap.

  ## Examples

      iex> ALLM.Providers.FakeModeration.max_batch_size
      32
  """
  @impl ALLM.ModerationAdapter
  @spec max_batch_size() :: pos_integer()
  def max_batch_size, do: @adapter_max_batch_size

  # ---------------------------------------------------------------------------
  # ALLM.ModerationAdapter — moderate/2
  # ---------------------------------------------------------------------------

  @doc """
  Execute a scripted moderation request.

  Gate order, all before the script is consulted:

    1. `adapter_opts[:capture_pid]` side-channel (fires even for rejected
       calls).
    2. `input: []` → `{:error, %ModerationAdapterError{reason: :invalid_request}}`.
    3. item count `> max_batch_size()` →
       `{:error, %ModerationAdapterError{reason: :batch_too_large,
       metadata: %{count: n, max: max}}}`. Per contract invariant 5 the count
       is the *item* count invariant 3 defines — `length(input)` for an
       all-strings input, `1` for a multimodal one — not the raw list length.

  Otherwise reads the script from `opts[:adapter_opts][:moderation_script]`,
  advances the process-local cursor, and interprets the entry. An **absent**
  script produces the default clean verdict; a **spent non-empty** script
  returns `:moderation_script_exhausted`. Both are described in the module
  docs.

  Propagates `opts[:request_id]` onto `response.request_id`, `request.model`
  onto `response.model`, `request.metadata` onto `response.metadata`, and
  stamps `provider: :fake`.

  ## Examples

      iex> req = ALLM.ModerationRequest.new(input: ["hello"], metadata: %{trace: "t1"})
      iex> {:ok, resp} = ALLM.Providers.FakeModeration.moderate(req, request_id: "rid-1")
      iex> {resp.request_id, resp.metadata, ALLM.ModerationResponse.flagged?(resp)}
      {"rid-1", %{trace: "t1"}, false}

      iex> req = ALLM.ModerationRequest.new(input: [])
      iex> {:error, err} = ALLM.Providers.FakeModeration.moderate(req, [])
      iex> err.reason
      :invalid_request
  """
  @impl ALLM.ModerationAdapter
  @spec moderate(ModerationRequest.t(), keyword()) ::
          {:ok, ModerationResponse.t()} | {:error, ModerationAdapterError.t()}
  def moderate(%ModerationRequest{} = request, opts) when is_list(opts) do
    maybe_capture(request, opts)

    case gate(request) do
      :ok -> run_scripted(request, opts)
      {:error, _} = error -> error
    end
  end

  # Contract invariants 6 and 5, in that order — both fire before any script
  # consult so a direct caller sees the same rejection a real adapter would
  # produce before its first byte of HTTP I/O and before it resolves a key.
  defp gate(%ModerationRequest{input: []}) do
    {:error,
     ModerationAdapterError.new(:invalid_request,
       message: "input must not be empty",
       metadata: %{field: :input}
     )}
  end

  defp gate(%ModerationRequest{input: input} = request) when is_list(input) do
    count = item_count(request)
    max = max_batch_size()

    if count > max do
      {:error,
       ModerationAdapterError.new(:batch_too_large,
         message: "input count #{count} exceeds max_batch_size #{max}",
         metadata: %{count: count, max: max}
       )}
    else
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Public helpers
  # ---------------------------------------------------------------------------

  @typedoc "One scripted moderation result."
  @type script_entry ::
          {:ok, [ModerationResult.t()]}
          | {:flagged, [String.t()]}
          | {:error, ModerationAdapterError.t()}
          | {:retry_until_call, pos_integer()}

  @doc """
  Document and validate the script grammar for
  `adapter_opts[:moderation_script]`.

  Each entry is one of:

    * `{:ok, [%ALLM.ModerationResult{}, ...]}` — return the listed results
      verbatim.
    * `{:flagged, ["violence", ...]}` — synthesize ONE flagged result with
      those category names `true` at score `1.0`, every other omni category
      `false` at `0.0`.
    * `{:error, %ALLM.Error.ModerationAdapterError{}}` — return the struct
      verbatim.
    * `{:retry_until_call, n}` — synthetic `:rate_limited` for the first
      `n - 1` calls against this entry. Consecutive entries of this shape
      chain into a layered budget (the call that exhausts one entry opens
      the next entry's budget).

  Returns `:ok` when the script is well-formed; raises `ArgumentError` on the
  first invalid entry. (Validation is opt-in — the runtime `moderate/2` path
  tolerates a mix of legal entries and surfaces
  `metadata: %{cause: :moderation_script_exhausted}` when the cursor runs off
  the end of a non-empty script.)

  ## Examples

      iex> ALLM.Providers.FakeModeration.script([{:flagged, ["violence"]}])
      :ok
  """
  @spec script([script_entry()]) :: :ok
  def script(entries) when is_list(entries) do
    Enum.each(entries, &validate_entry!/1)
    :ok
  end

  @doc """
  The 13 `omni-moderation` category names FakeModeration reports, sorted.

  Exposed so tests can assert against the same vocabulary the adapter
  synthesizes rather than hand-copying a 13-element list.

  ## Examples

      iex> ALLM.Providers.FakeModeration.categories |> length()
      13

      iex> "self-harm/intent" in ALLM.Providers.FakeModeration.categories
      true
  """
  @spec categories() :: [String.t()]
  def categories, do: @omni_categories

  @doc """
  Start an Agent-backed script cursor for cross-process multi-call scripting
  and for disambiguating content-equal scripts in the same process.

  Pass the returned pid as `adapter_opts[:script_cursor]`; subsequent calls
  increment the cursor on the Agent rather than on the process dictionary.

  ## Examples

      iex> pid = ALLM.Providers.FakeModeration.start_script_cursor
      iex> ALLM.Providers.FakeModeration.cursor_index(pid)
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

  ## Examples

      iex> pid = ALLM.Providers.FakeModeration.start_script_cursor
      iex> req = ALLM.ModerationRequest.new(input: ["x"])
      iex> opts = [adapter_opts: [moderation_script: [{:flagged, ["hate"]}], script_cursor: pid]]
      iex> {:ok, _} = ALLM.Providers.FakeModeration.moderate(req, opts)
      iex> ALLM.Providers.FakeModeration.cursor_index(pid)
      1
  """
  @spec cursor_index(pid()) :: non_neg_integer()
  def cursor_index(pid) when is_pid(pid), do: Agent.get(pid, & &1)

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  # Test-only side-channel. Sends a tagged message to the configured pid
  # BEFORE the gates / script consult so that even rejected calls are
  # captured. No-op when `:capture_pid` is absent or not a pid.
  defp maybe_capture(%ModerationRequest{} = request, opts) do
    adapter_opts = Keyword.get(opts, :adapter_opts, [])

    case Keyword.get(adapter_opts, :capture_pid) do
      pid when is_pid(pid) ->
        send(pid, {__MODULE__, :call, %{request: request, opts: opts}})
        :ok

      _ ->
        :ok
    end
  end

  defp run_scripted(%ModerationRequest{} = request, opts) do
    adapter_opts = Keyword.get(opts, :adapter_opts, [])
    script = Keyword.get(adapter_opts, :moderation_script, [])

    # Peek at the current entry WITHOUT advancing — `:retry_until_call`
    # entries hold the cursor in place for `n - 1` calls and only advance on
    # call n. Every other entry shape advances on consult.
    cursor = peek_cursor(script, adapter_opts)

    case Enum.at(script, cursor) do
      nil ->
        _ = advance_cursor(script, adapter_opts)
        spent_or_default(script, request, opts)

      {:retry_until_call, n} ->
        handle_retry_until_call(script, cursor, n, request, opts, adapter_opts)

      entry ->
        _ = advance_cursor(script, adapter_opts)
        interpret_entry(entry, request, opts)
    end
  end

  # `{:ok, results}` — return the scripted results verbatim.
  defp interpret_entry({:ok, results}, request, opts) when is_list(results) do
    {:ok, build_response(results, request, opts)}
  end

  # `{:flagged, categories}` — synthesize ONE flagged result.
  defp interpret_entry({:flagged, categories}, request, opts) when is_list(categories) do
    {:ok, build_response([flagged_result(categories)], request, opts)}
  end

  # `{:error, %ModerationAdapterError{}}` — return struct verbatim.
  defp interpret_entry({:error, %ModerationAdapterError{} = err}, _request, _opts) do
    {:error, err}
  end

  # `{:retry_until_call, n}` — return a synthetic `:rate_limited` error for the
  # first `n - 1` visits to this cursor position, then on the n-th visit
  # advance the cursor past this entry and dispatch the NEXT entry. The
  # per-cursor-position counter lives in the process dictionary keyed by
  # `(script-hash, cursor)` so it's isolated per ExUnit test process and per
  # script.
  defp handle_retry_until_call(script, cursor, n, request, opts, adapter_opts) do
    visits = bump_retry_visits(script, cursor, adapter_opts)

    if visits < n do
      {:error,
       ModerationAdapterError.new(:rate_limited,
         message: "FakeModeration retry_until_call hint",
         retry_after_ms: 0
       )}
    else
      _ = advance_cursor(script, adapter_opts)
      next_cursor = cursor + 1

      case Enum.at(script, next_cursor) do
        nil ->
          spent_or_default(script, request, opts)

        {:retry_until_call, m} ->
          # Chained retry budgets: this call lands ON the next retry entry and
          # opens its budget rather than consuming it as a result entry.
          # Without this clause two consecutive `{:retry_until_call, _}`
          # entries — a script `script/1` validates as well-formed — reach
          # `interpret_entry/3`, which has no matching clause, and
          # `moderate/2` raises (contract invariant 2 says it must not).
          handle_retry_until_call(script, next_cursor, m, request, opts, adapter_opts)

        next_entry ->
          # Advance past the next entry too — it's been consumed.
          _ = advance_cursor(script, adapter_opts)
          interpret_entry(next_entry, request, opts)
      end
    end
  end

  # MUST key on the SAME identity `advance_process_dict_cursor/2` and
  # `peek_cursor/2` use — see `cursor_key_id/2`. Keying on
  # `:erlang.phash2(script)` alone would give two content-equal engines
  # separate cursor slots but a SHARED retry budget, so the second engine
  # would skip its scripted `:rate_limited` returns and succeed on call one.
  defp bump_retry_visits(script, cursor, adapter_opts) do
    key = {:allm_fake_moderation_retry_visits, cursor_key_id(script, adapter_opts), cursor}
    visits = Process.get(key, 0) + 1
    Process.put(key, visits)
    visits
  end

  # An absent (or `[]`) script yields the benign default verdict: a clean
  # verdict is a meaningful default in a way a synthesized embedding vector is
  # not. A NON-EMPTY script whose cursor has run off the end is a different
  # mistake — almost always an off-by-one in the caller's expectation of how
  # many times `moderate/2` is invoked — and answering it with a clean verdict
  # would make that bug pass green. That case errors, mirroring
  # `ALLM.Providers.FakeEmbeddings`' exhaustion shape.
  defp spent_or_default([], request, opts) do
    {:ok, build_response(default_results(request), request, opts)}
  end

  defp spent_or_default(_script, _request, _opts) do
    {:error,
     ModerationAdapterError.new(:unknown,
       message: "FakeModeration script exhausted: no entry at the current cursor position",
       metadata: %{cause: :moderation_script_exhausted}
     )}
  end

  # Invariant 3's item count: an `:input` carrying any `%ALLM.ImagePart{}` is
  # ONE multimodal item regardless of list length; an all-strings input is one
  # item per element. Invariant 5's batch gate measures items, not raw list
  # elements, so `gate/1` and `default_results/1` read the same number.
  defp item_count(%ModerationRequest{} = request) do
    if ModerationRequest.multimodal?(request), do: 1, else: length(request.input)
  end

  # Cardinality per `ALLM.ModerationRequest`'s normative rule: one result per
  # input for an all-strings batch, exactly one result for a multimodal item.
  defp default_results(%ModerationRequest{} = request) do
    for index <- 0..(item_count(request) - 1)//1, do: clean_result(index)
  end

  defp clean_result(index) do
    ModerationResult.new(
      flagged: false,
      categories: Map.new(@omni_categories, &{&1, false}),
      category_scores: Map.new(@omni_categories, &{&1, 0.0}),
      index: index
    )
  end

  defp flagged_result(flagged_categories) do
    ModerationResult.new(
      flagged: true,
      categories: Map.new(@omni_categories, &{&1, &1 in flagged_categories}),
      category_scores:
        Map.new(@omni_categories, &{&1, if(&1 in flagged_categories, do: 1.0, else: 0.0)}),
      index: 0
    )
  end

  defp build_response(results, %ModerationRequest{} = request, opts) do
    %ModerationResponse{
      id: nil,
      request_id: Keyword.get(opts, :request_id),
      model: request.model,
      provider: :fake,
      results: results,
      raw: nil,
      metadata: request.metadata
    }
  end

  # ---------------------------------------------------------------------------
  # Cursor management
  # ---------------------------------------------------------------------------

  defp advance_cursor(script, adapter_opts) do
    case Keyword.get(adapter_opts, :script_cursor) do
      nil ->
        advance_process_dict_cursor(script, adapter_opts)

      pid when is_pid(pid) ->
        Agent.get_and_update(pid, fn i -> {i, i + 1} end)
    end
  end

  # Precedence: `script_cursor` (Agent pid, handled above) > `cursor_key`
  # (engine id, injected by the façade) > `:erlang.phash2(script)`
  # (direct-call default). `||` falls back only on `nil` — a real engine id
  # and any `phash2` value (including `0`) are truthy.
  defp advance_process_dict_cursor(script, adapter_opts) do
    key = {:allm_fake_moderation_cursor, cursor_key_id(script, adapter_opts)}
    current = Process.get(key, 0)
    Process.put(key, current + 1)
    current
  end

  # Read the current cursor without advancing — used by `run_scripted/2` to
  # support the `{:retry_until_call, n}` entry shape (which holds the cursor
  # in place for `n - 1` calls). MUST key on the SAME slot as
  # `advance_process_dict_cursor/2`, or retry counting breaks.
  defp peek_cursor(script, adapter_opts) do
    case Keyword.get(adapter_opts, :script_cursor) do
      nil ->
        Process.get({:allm_fake_moderation_cursor, cursor_key_id(script, adapter_opts)}, 0)

      pid when is_pid(pid) ->
        Agent.get(pid, & &1)
    end
  end

  # Single source of truth for the cursor identity, shared by
  # `advance_process_dict_cursor/2`, `peek_cursor/2` and `bump_retry_visits/3`
  # so the three never drift. Implements the full three-source precedence
  # documented in the moduledoc: `:script_cursor` pid > `:cursor_key` >
  # `:erlang.phash2(script)`. The pid clause is unreachable from the two
  # process-dict cursor helpers (which only call this on the `nil`
  # `:script_cursor` branch) and load-bearing for `bump_retry_visits/3`,
  # whose retry counter is always process-dict-backed.
  defp cursor_key_id(script, adapter_opts) do
    case Keyword.get(adapter_opts, :script_cursor) do
      pid when is_pid(pid) -> pid
      _ -> Keyword.get(adapter_opts, :cursor_key) || :erlang.phash2(script)
    end
  end

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  defp validate_entry!({:ok, results}) when is_list(results), do: :ok

  defp validate_entry!({:flagged, categories}) when is_list(categories) do
    if Enum.all?(categories, &is_binary/1), do: :ok, else: invalid_entry!({:flagged, categories})
  end

  defp validate_entry!({:error, %ModerationAdapterError{}}), do: :ok

  defp validate_entry!({:retry_until_call, n}) when is_integer(n) and n >= 1, do: :ok

  defp validate_entry!(other), do: invalid_entry!(other)

  defp invalid_entry!(other) do
    raise ArgumentError,
          "invalid FakeModeration script entry: #{inspect(other)} " <>
            "(expected {:ok, [%ModerationResult{}]}, {:flagged, [category_string]}, " <>
            "{:error, %ModerationAdapterError{}}, or {:retry_until_call, pos_integer})"
  end
end
