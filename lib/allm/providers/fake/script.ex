defmodule ALLM.Providers.Fake.Script do
  @moduledoc """
  Script shape detection, validation, and interpretation for
  `ALLM.Providers.Fake`. See spec §31.

  Layer B — pure helper module, no runtime state.

  Fake accepts two disjoint script shapes:

  - **Spec §31 (user-facing)** — the vocabulary the spec itself samples with
    `{:text, "hi"}, {:finish, :stop}`. Tags: `:text`, `:tool_call`,
    `:tool_call_delta`, `:usage`, `:raw_chunk`, `:finish`, `:error` (2-tuple),
    `:delay`, `:sleep` (deprecated alias of `:delay`).
  - **Phase 3 harness** — the vocabulary `ALLM.Test.AdapterConformance` and
    `ALLM.Test.StreamAdapterConformance` pass to `StubAdapter`. Tags:
    `:ok`, `:error` (3-tuple), `:text_delta`, `:preflight_error`,
    `:error_event`, `:stream_error`, and shared-semantics `:tool_call` /
    `:finish`.

  This module exposes four entry points:

  - `detect_shape/1` — classify a list of entries by leading tag.
  - `validate!/1` — guard `adapter_opts` at the Fake boundary.
  - `fold_to_response/1` — reduce a list of entries into an `%ALLM.Response{}`
    (non-streaming path).
  - `interpret/1` — translate one entry into a list of `ALLM.Event` values
    (streaming path).

  See spec §31 for the script entry grammar; §8 for the event union.
  """

  require Logger

  alias ALLM.Error.{AdapterError, StreamError}
  alias ALLM.{Message, Response, ToolCall, Usage}

  @typedoc "Detected shape of a script — §31 (user-facing) or Phase 3 harness."
  @type shape :: :spec31 | :harness

  @typedoc "A single spec §31 script entry (one call's worth of events)."
  @type spec31_entry ::
          {:text, String.t()}
          | {:tool_call, keyword()}
          | {:tool_call_delta, keyword()}
          | {:usage, map()}
          | {:raw_chunk, term()}
          | {:finish, Response.finish_reason()}
          | {:error, term()}
          | {:delay, non_neg_integer()}
          | {:sleep, non_neg_integer()}

  @typedoc "A single Phase 3 harness-shape entry (non-streaming)."
  @type harness_adapter_entry ::
          {:ok, map()}
          | {:error, atom(), keyword()}

  @typedoc "A single Phase 3 harness-shape entry (streaming)."
  @type harness_stream_entry ::
          {:text_delta, String.t()}
          | {:finish, atom()}
          | {:preflight_error, atom(), keyword()}
          | {:error_event, atom(), keyword()}
          | {:stream_error, atom(), keyword()}

  # Table mapping leading tag → detected shape. `:error` is disambiguated by
  # tuple_size/1 at runtime (2 → :spec31, 3 → :harness). Shared-semantics tags
  # (`:finish`, `:tool_call`) default to `:spec31` — the interpreter handles
  # both shapes identically for those tags.
  @shape_table %{
    # §31-only
    text: :spec31,
    tool_call_delta: :spec31,
    usage: :spec31,
    raw_chunk: :spec31,
    delay: :spec31,
    sleep: :spec31,
    # Harness-only (non-streaming)
    ok: :harness,
    # Harness-only (streaming-only but legal on :script if hand-written)
    text_delta: :harness,
    preflight_error: :harness,
    error_event: :harness,
    stream_error: :harness,
    # Shared semantics — default to :spec31
    finish: :spec31,
    tool_call: :spec31
  }

  # Set of atoms that are valid AdapterError reasons — used by interpret/1 for
  # §31 `{:error, term}` routing.
  @adapter_error_reasons AdapterError.legal_reasons() |> MapSet.new()

  @doc """
  Classify a list of script entries as either `:spec31` or `:harness` shape.

  Inspects only the leading entry's tag. The `:error` tag is disambiguated by
  tuple arity — 2-tuple → `:spec31`, 3-tuple → `:harness`. Shared-semantics
  tags (`:finish`, `:tool_call`) default to `:spec31` (the interpreter handles
  both shapes identically for those tags, so the classification is
  inconsequential).

  An empty list returns `{:spec31, []}` (the default).

  Raises `ArgumentError` if the leading tag is unknown, with a message that
  mentions both vocabularies so script authors can spot typos.

  ## Examples

      iex> ALLM.Providers.Fake.Script.detect_shape([{:text, "hi"}, {:finish, :stop}])
      {:spec31, [{:text, "hi"}, {:finish, :stop}]}

      iex> ALLM.Providers.Fake.Script.detect_shape([{:ok, %{output_text: "hi"}}])
      {:harness, [{:ok, %{output_text: "hi"}}]}

      iex> ALLM.Providers.Fake.Script.detect_shape([])
      {:spec31, []}
  """
  @spec detect_shape([term()]) :: {shape(), [term()]}
  def detect_shape([]), do: {:spec31, []}

  def detect_shape([first | _] = entries) when is_tuple(first) do
    tag = elem(first, 0)

    shape =
      case {tag, tuple_size(first)} do
        {:error, 2} -> :spec31
        {:error, 3} -> :harness
        {tag, _} -> Map.get(@shape_table, tag, :__unknown__)
      end

    case shape do
      :__unknown__ ->
        raise ArgumentError,
              "unknown script entry tag #{inspect(tag)} — " <>
                "expected one of the §31 tags (:text, :tool_call, :tool_call_delta, " <>
                ":usage, :raw_chunk, :finish, :error, :delay, :sleep) or Phase 3 " <>
                "harness tags (:ok, :error/3, :text_delta, :preflight_error, " <>
                ":error_event, :stream_error)"

      s ->
        {s, entries}
    end
  end

  @doc """
  Validate `adapter_opts` at the Fake boundary.

  Guards (in order):

  1. Mixing `:script` and `:scripts` raises `ArgumentError` (spec §31).
  2. `:script` must be a list (of entries).
  3. `:scripts` must be a list of lists (each inner list is one call's script).
  4. `:stream_script` must be a list of lists.
  5. `:script_cursor`, when present, must be a pid or `nil`.

  Returns `:ok` on success.

  Users may call this directly on their `adapter_opts` for construction-time
  feedback (Non-obvious Decision #5 in the Phase 4 design doc) — Fake itself
  calls it at the first adapter invocation.
  """
  @spec validate!(keyword()) :: :ok
  def validate!(opts) when is_list(opts) do
    validate_no_mixed_script_keys!(opts)
    validate_list_opt!(opts, :script, &is_list/1, ":script must be a list of entries")

    validate_list_opt!(
      opts,
      :scripts,
      &list_of_lists?/1,
      ":scripts must be a list of lists"
    )

    # :stream_script is polymorphic — the Phase 3 harness passes a flat
    # list of entries for single-call (pre-flight) tests and a list of
    # lists for multi-call tests. Both are accepted; the stream entry point
    # normalizes to list-of-lists before cursoring.
    validate_list_opt!(
      opts,
      :stream_script,
      &is_list/1,
      ":stream_script must be a list of entries or a list of lists"
    )

    validate_list_opt!(
      opts,
      :script_cursor,
      &pid_or_nil?/1,
      ":script_cursor must be a pid or nil"
    )

    :ok
  end

  defp validate_no_mixed_script_keys!(opts) do
    if Keyword.has_key?(opts, :script) and Keyword.has_key?(opts, :scripts) do
      raise ArgumentError, "cannot mix :script and :scripts in adapter_opts (spec §31)"
    end
  end

  defp validate_list_opt!(opts, key, check, message) do
    if Keyword.has_key?(opts, key) and not check.(Keyword.fetch!(opts, key)) do
      raise ArgumentError, message
    end
  end

  @doc """
  Fold a list of script entries into a single `%ALLM.Response{}`.

  Handles both the spec §31 vocabulary (`:text`, `:tool_call`,
  `:tool_call_delta`, `:usage`, `:raw_chunk`, `:finish`, `:error`/2,
  `:delay`, `:sleep`) and the harness-shape terminal entries (`{:ok, map}`,
  `{:error, reason, opts}`). Harness-shape is one entry per call; the
  reducer returns on the first harness entry it sees.

  A §31 `{:error, term}` entry short-circuits to
  `{:error, %AdapterError{reason: :unknown, message: "scripted error",
  cause: term}}`. `{:delay, ms}` / `{:sleep, ms}` call `Process.sleep/1`
  so non-streaming callers can still exercise timeout paths. `{:raw_chunk,
  _}` is ignored (raw chunks have no place on `%Response{}`).

  `{:usage, map}` calls `struct!(ALLM.Usage, map)` with last-write-wins
  semantics — passing an unknown field name (e.g., `:prompt_tokens`) raises
  `KeyError` at fold time; use the canonical field names from
  `ALLM.Usage` (spec §5.9a).

  Returns `%ALLM.Response{}` on success (NOT `{:ok, %Response{}}` — the
  `{:ok, _}` wrapping is applied at the `ALLM.Providers.Fake.generate/2`
  boundary in sub-phase 4.2), or `{:error, %AdapterError{}}` on
  script-defined failure.

  ## Examples

      iex> ALLM.Providers.Fake.Script.fold_to_response([{:text, "hi"}, {:finish, :stop}])
      %ALLM.Response{output_text: "hi", finish_reason: :stop, tool_calls: [], usage: %ALLM.Usage{}}
  """
  @spec fold_to_response([spec31_entry() | harness_adapter_entry()]) ::
          Response.t() | {:error, AdapterError.t()}
  def fold_to_response(entries) when is_list(entries) do
    initial_acc = %{
      output_text: "",
      tool_calls: %{},
      tool_call_order: [],
      # Ids of tool calls whose raw_arguments were appended via deltas — they
      # need re-parse at finalize time. Ids built from a full `{:tool_call, _}`
      # entry retain their caller-supplied `:arguments` map verbatim.
      deltas: MapSet.new(),
      finish_reason: :stop,
      usage: %Usage{}
    }

    result =
      Enum.reduce_while(entries, initial_acc, fn entry, acc ->
        reduce_entry(entry, acc)
      end)

    case result do
      {:error, _} = err -> err
      {:halt_ok, response} -> response
      acc when is_map(acc) -> build_response_from_acc(acc)
    end
  end

  @doc """
  Translate a single script entry into a list of `ALLM.Event` values.

  Called per-entry by `ALLM.Providers.Fake.stream/2`. `{:delay, ms}` and
  `{:sleep, ms}` return `[]` — the stream runner handles the sleep directly
  before emitting the next event, so `interpret/1` has no events to yield.

  `:text_completed` is NOT emitted here. Whether to emit it depends on
  whether any `:text` was seen earlier in the same call; that state lives in
  the `Stream.resource/3` accumulator, not here. `interpret({:finish, _})`
  returns just `[{:message_completed, _}]`; the stream runner prepends
  `:text_completed` when appropriate. Revisit in sub-phase 4.3 if the
  orchestration needs change.

  ## Deprecation

  `{:sleep, ms}` is a deprecated alias for `{:delay, ms}` (spec §31). Passing
  a `{:sleep, _}` entry triggers a one-time `Logger.warning/1` per BEAM
  lifetime (dedup via `:persistent_term`). Deletion target: v0.3.
  """
  @spec interpret(spec31_entry() | harness_stream_entry()) :: [ALLM.Event.t()]
  def interpret(entry)

  def interpret({:text, s}) when is_binary(s),
    do: [{:text_delta, %{id: nil, delta: s}}]

  def interpret({:tool_call, kw}) when is_list(kw) do
    id = Keyword.fetch!(kw, :id)
    name = Keyword.fetch!(kw, :name)
    arguments = Keyword.get(kw, :arguments, %{})
    raw_arguments = Keyword.get(kw, :raw_arguments) || Jason.encode!(arguments)

    [
      {:tool_call_started, %{id: id, name: name}},
      {:tool_call_completed,
       %{id: id, name: name, arguments: arguments, raw_arguments: raw_arguments}}
    ]
  end

  def interpret({:tool_call_delta, kw}) when is_list(kw) do
    id = Keyword.fetch!(kw, :id)
    arguments_delta = Keyword.fetch!(kw, :arguments_delta)
    [{:tool_call_delta, %{id: id, arguments_delta: arguments_delta}}]
  end

  def interpret({:usage, map}) when is_map(map),
    do: [{:raw_chunk, {:usage, map}}]

  def interpret({:raw_chunk, term}),
    do: [{:raw_chunk, term}]

  def interpret({:finish, _reason}) do
    [{:message_completed, %{message: %Message{role: :assistant, content: ""}}}]
  end

  def interpret({:error, term}) when is_atom(term) do
    if MapSet.member?(@adapter_error_reasons, term) do
      [{:error, AdapterError.new(term)}]
    else
      [{:error, AdapterError.new(:unknown, cause: term)}]
    end
  end

  def interpret({:error, term}),
    do: [{:error, AdapterError.new(:unknown, cause: term)}]

  def interpret({:delay, _ms}), do: []

  def interpret({:sleep, _ms}) do
    warn_sleep_deprecation_once()
    []
  end

  # Harness-shape stream entries.
  def interpret({:text_delta, s}) when is_binary(s),
    do: [{:text_delta, %{id: nil, delta: s}}]

  def interpret({:preflight_error, reason, opts}) when is_atom(reason) and is_list(opts),
    do: [{:error, AdapterError.new(reason, opts)}]

  def interpret({:error_event, reason, opts}) when is_atom(reason) and is_list(opts),
    do: [{:error, AdapterError.new(reason, opts)}]

  def interpret({:stream_error, reason, opts}) when is_atom(reason) and is_list(opts),
    do: [{:error, StreamError.new(reason, opts)}]

  # ---------------------------------------------------------------------------
  # fold_to_response/1 — per-entry reducer
  # ---------------------------------------------------------------------------

  # Harness shape (terminal, one entry per call).
  defp reduce_entry({:ok, map}, _acc) when is_map(map) do
    {:halt, {:halt_ok, build_response_from_harness(map)}}
  end

  defp reduce_entry({:error, reason, opts}, _acc)
       when is_atom(reason) and is_list(opts) do
    {:halt, {:error, AdapterError.new(reason, opts)}}
  end

  # §31 shape.
  defp reduce_entry({:text, s}, acc) when is_binary(s) do
    {:cont, %{acc | output_text: acc.output_text <> s}}
  end

  defp reduce_entry({:tool_call, kw}, acc) when is_list(kw) do
    id = Keyword.fetch!(kw, :id)
    name = Keyword.fetch!(kw, :name)
    arguments = Keyword.get(kw, :arguments, %{})
    raw_arguments = Keyword.get(kw, :raw_arguments) || Jason.encode!(arguments)

    tool_call = %ToolCall{
      id: id,
      name: name,
      arguments: arguments,
      raw_arguments: raw_arguments
    }

    tool_calls = Map.put(acc.tool_calls, id, tool_call)
    order = maybe_append(acc.tool_call_order, id)
    {:cont, %{acc | tool_calls: tool_calls, tool_call_order: order}}
  end

  defp reduce_entry({:tool_call_delta, kw}, acc) when is_list(kw) do
    id = Keyword.fetch!(kw, :id)
    arguments_delta = Keyword.fetch!(kw, :arguments_delta)

    existing =
      Map.get(acc.tool_calls, id, %ToolCall{
        id: id,
        name: "",
        arguments: %{},
        raw_arguments: ""
      })

    raw = (existing.raw_arguments || "") <> arguments_delta
    updated = %{existing | raw_arguments: raw}
    tool_calls = Map.put(acc.tool_calls, id, updated)
    order = maybe_append(acc.tool_call_order, id)

    {:cont,
     %{acc | tool_calls: tool_calls, tool_call_order: order, deltas: MapSet.put(acc.deltas, id)}}
  end

  defp reduce_entry({:usage, map}, acc) when is_map(map) do
    {:cont, %{acc | usage: struct!(Usage, map)}}
  end

  defp reduce_entry({:raw_chunk, _}, acc), do: {:cont, acc}

  defp reduce_entry({:finish, reason}, acc) when is_atom(reason) do
    {:cont, %{acc | finish_reason: reason}}
  end

  defp reduce_entry({:error, term}, _acc) do
    {:halt,
     {:error,
      %AdapterError{
        reason: :unknown,
        message: "scripted error",
        cause: term
      }}}
  end

  defp reduce_entry({:delay, ms}, acc) when is_integer(ms) and ms >= 0 do
    Process.sleep(ms)
    {:cont, acc}
  end

  defp reduce_entry({:sleep, ms}, acc) when is_integer(ms) and ms >= 0 do
    warn_sleep_deprecation_once()
    Process.sleep(ms)
    {:cont, acc}
  end

  # ---------------------------------------------------------------------------
  # Response synthesis
  # ---------------------------------------------------------------------------

  defp build_response_from_acc(%{tool_call_order: order, tool_calls: tool_calls} = acc) do
    finalized =
      Enum.map(order, fn id ->
        tc = Map.fetch!(tool_calls, id)
        if MapSet.member?(acc.deltas, id), do: finalize_tool_call(tc), else: tc
      end)

    %Response{
      output_text: acc.output_text,
      tool_calls: finalized,
      finish_reason: acc.finish_reason,
      usage: acc.usage
    }
  end

  # Re-parse raw_arguments into arguments at finalize time (best-effort).
  # Only called on tool calls that had deltas appended — a tool call built
  # from a full `{:tool_call, _}` entry retains its caller-supplied arguments.
  defp finalize_tool_call(%ToolCall{raw_arguments: raw} = tc)
       when is_binary(raw) and byte_size(raw) > 0 do
    case Jason.decode(raw) do
      {:ok, decoded} when is_map(decoded) -> %{tc | arguments: decoded}
      _ -> tc
    end
  end

  defp finalize_tool_call(%ToolCall{} = tc), do: tc

  # Harness-shape {:ok, map} path — mirrors StubAdapter.build_response/1.
  defp build_response_from_harness(map) do
    %Response{
      id: Map.get(map, :id),
      request_id: Map.get(map, :request_id),
      model: Map.get(map, :model),
      message: Map.get(map, :message),
      output_text: Map.get(map, :output_text, Map.get(map, :text)),
      tool_calls: Map.get(map, :tool_calls, []),
      finish_reason: Map.get(map, :finish_reason, :stop),
      usage: Map.get(map, :usage, %Usage{}),
      raw: Map.get(map, :raw),
      metadata: Map.get(map, :metadata, %{})
    }
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp list_of_lists?(x), do: is_list(x) and Enum.all?(x, &is_list/1)

  defp pid_or_nil?(nil), do: true
  defp pid_or_nil?(x) when is_pid(x), do: true
  defp pid_or_nil?(_), do: false

  defp maybe_append(list, id) do
    if id in list, do: list, else: list ++ [id]
  end

  # Once-per-VM dedup for the `{:sleep, _}` deprecation notice. Uses
  # :persistent_term so concurrent callers don't double-log on a race.
  @sleep_warning_key __MODULE__.SleepWarning
  defp warn_sleep_deprecation_once do
    case :persistent_term.get(@sleep_warning_key, :not_warned) do
      :not_warned ->
        :persistent_term.put(@sleep_warning_key, :warned)

        Logger.warning(
          "[ALLM.Providers.Fake.Script] {:sleep, ms} script entries are deprecated; " <>
            "use {:delay, ms} instead (spec §31). This warning fires once per VM."
        )

      _ ->
        :ok
    end
  end
end
