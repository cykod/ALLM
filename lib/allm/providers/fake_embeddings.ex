defmodule ALLM.Providers.FakeEmbeddings do
  @moduledoc """
  Deterministic, scripted adapter for text-embedding testing. Implements
  `ALLM.EmbeddingAdapter`.

  Layer B — runtime. FakeEmbeddings is the canonical testing embedding
  adapter; it ships in `lib/` (not `test/support/`) because users need it for
  their own application tests, mirroring the `ALLM.Providers.Fake` and
  `ALLM.Providers.FakeImages` precedent.

  ## What FakeEmbeddings is (and isn't)

  FakeEmbeddings **mostly ignores the `%ALLM.EmbeddingRequest{}`** passed to
  `embed/2`. It does inspect `:input` to enforce the empty-input and
  batch-size gates that the `ALLM.EmbeddingAdapter` contract requires of
  every implementation, and reads `:model` / `:metadata` to round-trip onto
  the response; otherwise the scripted response is produced irrespective of
  the request. In particular the scripted vectors are **not** derived from
  the input strings, and the script — not `length(input)` — decides how many
  embeddings come back.

  ## Script shapes

  `opts[:adapter_opts][:embedding_script]` accepts a list of script entries.
  See `script/1` for the full grammar.

      adapter_opts: [
        embedding_script: [
          {:ok, [%ALLM.Embedding{...}]},
          {:ok, [%ALLM.Embedding{...}], usage: %ALLM.Usage{...}},
          {:error, %ALLM.Error.EmbeddingAdapterError{reason: :rate_limited}},
          {:retry_until_call, 3}
        ]
      ]

  `{:retry_until_call, n}` returns a synthetic
  `%ALLM.Error.EmbeddingAdapterError{reason: :rate_limited, retry_after_ms: 0}`
  for the first `n - 1` calls against this entry, then advances the cursor to
  the next entry on call `n`. Vehicle for testing `ALLM.Retry.run/3`
  integration in `ALLM.embed/3`. Consecutive `{:retry_until_call, _}` entries
  **chain**: the call that exhausts one entry's budget lands on the next entry
  and opens its budget, which is how a layered retry budget is scripted.

  Multi-call scripting uses the same list — each call advances a process-local
  cursor (or an explicit Agent cursor passed via
  `adapter_opts[:script_cursor]` from `start_script_cursor/0`).

  ## Cursor behaviour

  Multi-call scripts (`:embedding_script`) advance a per-process cursor on
  every call. The cursor lives in the process dictionary at
  `{:allm_fake_embeddings_cursor, key_id}`, isolated per ExUnit test process
  (`async: true`), GC'd on pid-down, zero-setup for the common case. The
  `key_id` is chosen by this precedence:

    1. `adapter_opts[:script_cursor]` — an explicit Agent pid (handled
       separately; see `start_script_cursor/0`).
    2. `adapter_opts[:cursor_key]` — the engine's stable `:id`, injected by
       the façade dispatch chokepoint via `ALLM.Engine.put_cursor_key/2`.
    3. `:erlang.phash2(script)` — the content-hash fallback for direct adapter
       calls with no engine.

  At the façade the cursor keys on engine identity, so two engines built with
  content-equal `:embedding_script` values each read index 0 on their first
  call, even in the same process. **The content-hash footgun remains only for
  DIRECT adapter calls** — `ALLM.Providers.FakeEmbeddings.embed(req, opts)`
  invoked without an engine receives no `:cursor_key`. Workaround for that
  path: pass distinct `adapter_opts[:script_cursor]` Agent pids from
  `start_script_cursor/0`.

  ## Test-only capture seam

  Pass `adapter_opts[:capture_pid]` with a pid to receive a side-channel
  message every time `embed/2` is invoked, BEFORE any gate runs and before
  the script is consulted. The message has the form:

      {ALLM.Providers.FakeEmbeddings, :call, %{request: request, opts: opts}}

  This is purely a side-channel — it does NOT affect the response. It exists
  so test files can assert on what the adapter received without the
  `Process.register/2` + named-pid pattern (which forces `async: false`).
  With `:capture_pid` in scope, tests stay `async: true` and use
  `assert_receive {ALLM.Providers.FakeEmbeddings, :call, _}` to pattern-match
  on the captured payload.

  ## Examples

      iex> e = ALLM.Embedding.new(vector: [0.1, 0.2])
      iex> req = ALLM.EmbeddingRequest.new(input: ["a kestrel"])
      iex> opts = [adapter_opts: [embedding_script: [{:ok, [e]}]]]
      iex> {:ok, resp} = ALLM.Providers.FakeEmbeddings.embed(req, opts)
      iex> ALLM.EmbeddingResponse.vectors(resp)
      [[0.1, 0.2]]
  """

  @behaviour ALLM.EmbeddingAdapter

  alias ALLM.{Embedding, EmbeddingRequest, EmbeddingResponse, Usage}
  alias ALLM.Error.EmbeddingAdapterError

  @adapter_max_batch_size 2048

  # ---------------------------------------------------------------------------
  # ALLM.EmbeddingAdapter — max_batch_size/0
  # ---------------------------------------------------------------------------

  @doc """
  Return the maximum number of inputs FakeEmbeddings accepts per call.

  Matches the largest cap among the bundled real providers so a test written
  against the fake is not accidentally narrower than production. Tests that
  need to observe chunking supply their own stub with a smaller cap.

  ## Examples

      iex> ALLM.Providers.FakeEmbeddings.max_batch_size
      2048
  """
  @impl ALLM.EmbeddingAdapter
  @spec max_batch_size() :: pos_integer()
  def max_batch_size, do: @adapter_max_batch_size

  # ---------------------------------------------------------------------------
  # ALLM.EmbeddingAdapter — embed/2
  # ---------------------------------------------------------------------------

  @doc """
  Execute a scripted embedding request.

  Gate order, all before the script is consulted:

    1. `adapter_opts[:capture_pid]` side-channel (fires even for rejected
       calls).
    2. `input: []` → `{:error, %EmbeddingAdapterError{reason: :invalid_request}}`.
    3. `length(input) > max_batch_size()` →
       `{:error, %EmbeddingAdapterError{reason: :batch_too_large,
       metadata: %{count: n, max: max}}}`.

  Otherwise reads the script from `opts[:adapter_opts][:embedding_script]`,
  advances the process-local cursor, and returns the entry verbatim. An empty
  or exhausted script returns
  `{:error, %EmbeddingAdapterError{reason: :unknown,
  metadata: %{cause: :no_scripted_embedding}}}`.

  Propagates `opts[:request_id]` onto `response.request_id`, `request.model`
  onto `response.model`, and round-trips `request.metadata` onto
  `response.metadata`.

  ## Examples

      iex> e = ALLM.Embedding.new(vector: [1.0, 0.0])
      iex> req = ALLM.EmbeddingRequest.new(input: ["x"], metadata: %{trace: "t1"})
      iex> opts = [adapter_opts: [embedding_script: [{:ok, [e]}]], request_id: "rid-1"]
      iex> {:ok, resp} = ALLM.Providers.FakeEmbeddings.embed(req, opts)
      iex> {resp.request_id, resp.metadata}
      {"rid-1", %{trace: "t1"}}

      iex> req = ALLM.EmbeddingRequest.new(input: [])
      iex> {:error, err} = ALLM.Providers.FakeEmbeddings.embed(req, [])
      iex> err.reason
      :invalid_request
  """
  @impl ALLM.EmbeddingAdapter
  @spec embed(EmbeddingRequest.t(), keyword()) ::
          {:ok, EmbeddingResponse.t()} | {:error, EmbeddingAdapterError.t()}
  def embed(%EmbeddingRequest{} = request, opts) when is_list(opts) do
    maybe_capture(request, opts)

    case gate(request) do
      :ok -> run_scripted(request, opts)
      {:error, _} = error -> error
    end
  end

  # Contract invariants 5 and 4, in that order — both fire before any script
  # consult so that a direct caller sees the same rejection a real adapter
  # would produce before its first byte of HTTP I/O.
  defp gate(%EmbeddingRequest{input: []}) do
    {:error,
     EmbeddingAdapterError.new(:invalid_request,
       message: "input must not be empty",
       metadata: %{field: :input}
     )}
  end

  defp gate(%EmbeddingRequest{input: input}) when is_list(input) do
    count = length(input)
    max = max_batch_size()

    if count > max do
      {:error,
       EmbeddingAdapterError.new(:batch_too_large,
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

  @typedoc "One scripted embedding result."
  @type script_entry ::
          {:ok, [Embedding.t()]}
          | {:ok, [Embedding.t()], keyword()}
          | {:error, EmbeddingAdapterError.t()}
          | {:retry_until_call, pos_integer()}

  @doc """
  Document and validate the script grammar for
  `adapter_opts[:embedding_script]`.

  Each entry is one of:

    * `{:ok, [%ALLM.Embedding{}, ...]}` — return the listed embeddings plus a
      default `%ALLM.Usage{}`.
    * `{:ok, [%ALLM.Embedding{}, ...], usage: %ALLM.Usage{}}` — return the
      listed embeddings plus the supplied usage.
    * `{:error, %ALLM.Error.EmbeddingAdapterError{}}` — return the struct
      verbatim.
    * `{:retry_until_call, n}` — synthetic `:rate_limited` for the first
      `n - 1` calls against this entry. Consecutive entries of this shape
      chain into a layered budget (the call that exhausts one entry opens the
      next entry's budget).

  Returns `:ok` when the script is well-formed; raises `ArgumentError` on the
  first invalid entry. (Validation is opt-in — the runtime `embed/2` path
  tolerates a mix of legal entries and surfaces a cursor-exhausted shape on
  `nil` lookups.)

  ## Examples

      iex> e = ALLM.Embedding.new(vector: [0.0])
      iex> ALLM.Providers.FakeEmbeddings.script([{:ok, [e]}])
      :ok
  """
  @spec script([script_entry()]) :: :ok
  def script(entries) when is_list(entries) do
    Enum.each(entries, &validate_entry!/1)
    :ok
  end

  @doc """
  Start an Agent-backed script cursor for cross-process multi-call scripting
  and for disambiguating content-equal scripts in the same process.

  Pass the returned pid as `adapter_opts[:script_cursor]`; subsequent calls
  increment the cursor on the Agent rather than on the process dictionary.

  ## Examples

      iex> pid = ALLM.Providers.FakeEmbeddings.start_script_cursor
      iex> ALLM.Providers.FakeEmbeddings.cursor_index(pid)
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

      iex> pid = ALLM.Providers.FakeEmbeddings.start_script_cursor
      iex> e = ALLM.Embedding.new(vector: [0.0])
      iex> req = ALLM.EmbeddingRequest.new(input: ["x"])
      iex> opts = [adapter_opts: [embedding_script: [{:ok, [e]}], script_cursor: pid]]
      iex> {:ok, _} = ALLM.Providers.FakeEmbeddings.embed(req, opts)
      iex> ALLM.Providers.FakeEmbeddings.cursor_index(pid)
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
  defp maybe_capture(%EmbeddingRequest{} = request, opts) do
    adapter_opts = Keyword.get(opts, :adapter_opts, [])

    case Keyword.get(adapter_opts, :capture_pid) do
      pid when is_pid(pid) ->
        send(pid, {__MODULE__, :call, %{request: request, opts: opts}})
        :ok

      _ ->
        :ok
    end
  end

  defp run_scripted(%EmbeddingRequest{} = request, opts) do
    adapter_opts = Keyword.get(opts, :adapter_opts, [])
    script = Keyword.get(adapter_opts, :embedding_script, [])

    # Peek at the current entry WITHOUT advancing — `:retry_until_call`
    # entries hold the cursor in place for `n - 1` calls and only advance on
    # call n. Every other entry shape advances on consult.
    cursor = peek_cursor(script, adapter_opts)

    case Enum.at(script, cursor) do
      nil ->
        _ = advance_cursor(script, adapter_opts)
        exhausted()

      {:retry_until_call, n} ->
        handle_retry_until_call(script, cursor, n, request, opts, adapter_opts)

      entry ->
        _ = advance_cursor(script, adapter_opts)
        interpret_entry(entry, request, opts)
    end
  end

  defp exhausted do
    {:error,
     EmbeddingAdapterError.new(:unknown,
       message: "no scripted embedding",
       metadata: %{cause: :no_scripted_embedding}
     )}
  end

  # `{:ok, embeddings}` — default `%Usage{}` (every counter nil).
  defp interpret_entry({:ok, embeddings}, request, opts) when is_list(embeddings) do
    {:ok, build_response(embeddings, %Usage{}, request, opts)}
  end

  # `{:ok, embeddings, opts_kw}` — caller supplies usage / extras.
  defp interpret_entry({:ok, embeddings, kw}, request, opts)
       when is_list(embeddings) and is_list(kw) do
    usage = Keyword.get(kw, :usage) || %Usage{}
    {:ok, build_response(embeddings, usage, request, opts)}
  end

  # `{:error, %EmbeddingAdapterError{}}` — return struct verbatim.
  defp interpret_entry({:error, %EmbeddingAdapterError{} = err}, _request, _opts) do
    {:error, err}
  end

  # `{:retry_until_call, n}` — return a synthetic `:rate_limited` error for the
  # first `n - 1` visits to this cursor position, then on the n-th visit
  # advance the cursor past this entry and dispatch the NEXT entry. The
  # per-cursor-position counter lives in the process dictionary keyed by
  # `(script-hash, cursor)` so it's isolated per ExUnit test process and per
  # script.
  defp handle_retry_until_call(script, cursor, n, request, opts, adapter_opts) do
    visits = bump_retry_visits(script, cursor)

    if visits < n do
      {:error,
       EmbeddingAdapterError.new(:rate_limited,
         message: "FakeEmbeddings retry_until_call hint",
         retry_after_ms: 0
       )}
    else
      _ = advance_cursor(script, adapter_opts)
      next_cursor = cursor + 1

      case Enum.at(script, next_cursor) do
        nil ->
          exhausted()

        {:retry_until_call, m} ->
          # Chained retry budgets: this call lands ON the next retry entry and
          # opens its budget rather than consuming it as a result entry. Without
          # this clause two consecutive `{:retry_until_call, _}` entries — a
          # script `script/1` validates as well-formed — reach `interpret_entry/3`,
          # which has no matching clause, and `embed/2` raises (contract
          # invariant 2 says it must not).
          handle_retry_until_call(script, next_cursor, m, request, opts, adapter_opts)

        next_entry ->
          # Advance past the next entry too — it's been consumed.
          _ = advance_cursor(script, adapter_opts)
          interpret_entry(next_entry, request, opts)
      end
    end
  end

  defp bump_retry_visits(script, cursor) do
    key = {:allm_fake_embeddings_retry_visits, :erlang.phash2(script), cursor}
    visits = Process.get(key, 0) + 1
    Process.put(key, visits)
    visits
  end

  defp build_response(embeddings, usage, %EmbeddingRequest{} = request, opts) do
    %EmbeddingResponse{
      id: nil,
      request_id: Keyword.get(opts, :request_id),
      model: request.model,
      embeddings: embeddings,
      usage: usage,
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
    key = {:allm_fake_embeddings_cursor, cursor_key_id(script, adapter_opts)}
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
        Process.get({:allm_fake_embeddings_cursor, cursor_key_id(script, adapter_opts)}, 0)

      pid when is_pid(pid) ->
        Agent.get(pid, & &1)
    end
  end

  # Single source of truth for the process-dict cursor key id, shared by
  # `advance_process_dict_cursor/2` and `peek_cursor/2` so the two never drift.
  defp cursor_key_id(script, adapter_opts) do
    Keyword.get(adapter_opts, :cursor_key) || :erlang.phash2(script)
  end

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  defp validate_entry!({:ok, embeddings}) when is_list(embeddings), do: :ok

  defp validate_entry!({:ok, embeddings, kw}) when is_list(embeddings) and is_list(kw), do: :ok

  defp validate_entry!({:error, %EmbeddingAdapterError{}}), do: :ok

  defp validate_entry!({:retry_until_call, n}) when is_integer(n) and n >= 1, do: :ok

  defp validate_entry!(other) do
    raise ArgumentError,
          "invalid FakeEmbeddings script entry: #{inspect(other)} " <>
            "(expected {:ok, [%Embedding{}]}, {:ok, [%Embedding{}], opts}, " <>
            "{:error, %EmbeddingAdapterError{}}, or {:retry_until_call, pos_integer})"
  end
end
