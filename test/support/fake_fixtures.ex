defmodule ALLM.Test.FakeFixtures do
  @moduledoc """
  Named scripted scenarios for `ALLM.Providers.Fake`. Every fixture returns a
  keyword-list `adapter_opts` ready to pass to `ALLM.Engine.new/1` under the
  `adapter_opts:` key.

  For anything these eight fixtures don't cover, write the script verbatim
  against `ALLM.Providers.Fake` — the fixture library is for common shapes,
  not a replacement for the adapter's script vocabulary. See
  `ALLM.Providers.Fake` for the full §31 / Phase 3 harness tag grammar.

  Layer B (test support) — lives under `test/support/` and is not part of the
  published Hex package (per Phase 4 design Non-obvious Decision #10).
  """

  alias ALLM.Engine
  alias ALLM.Error.AdapterError
  alias ALLM.Providers.Fake
  alias ALLM.Providers.Fake.Script

  @doc """
  Build a single-script Fake-adapter engine for one-turn tests.

  `script` is a Phase 4 §31 entry list (the same shape consumed by
  `ALLM.Providers.Fake` under the `script:` adapter opt).

  ## Options

    * `:tools` — list of `ALLM.Tool` structs (default `[]`).
    * `:adapter_opts` — extra adapter opts to merge into `[script: script]`
      (e.g., `[emit_text_deltas: false]`). Caller-supplied keys win on
      collision.
    * `:engine_opts` — extra keyword opts to merge into the engine
      construction (e.g., `[context: %{user_id: 1}]`). Caller-supplied keys
      win on collision with the defaults built here.

  Extracted from the `engine_with_script/2` helpers previously cloned across
  `chat_step_test.exs`, `chat_stream_step_test.exs`, and `chat_run_test.exs`.
  """
  @spec engine([Script.spec31_entry()], keyword()) :: Engine.t()
  def engine(script, opts \\ []) when is_list(script) and is_list(opts) do
    tools = Keyword.get(opts, :tools, [])
    extra_adapter_opts = Keyword.get(opts, :adapter_opts, [])
    extra_engine_opts = Keyword.get(opts, :engine_opts, [])

    adapter_opts = Keyword.merge([script: script], extra_adapter_opts)

    engine_opts =
      [adapter: Fake, adapter_opts: adapter_opts, tools: tools]
      |> Keyword.merge(extra_engine_opts)

    Engine.new(engine_opts)
  end

  @doc """
  Build a multi-script Fake-adapter engine for multi-turn tests.

  Allocates a fresh `Fake.start_script_cursor/0` cursor and threads it
  through `adapter_opts` so each call to the adapter advances the cursor
  through the script list.

  `scripts` is a list of §31 entry lists, one per expected adapter call.

  ## Options

  Same as `engine/2`. `:adapter_opts` is merged on top of
  `[scripts: scripts, script_cursor: cursor]`.

  Extracted from `chat_run_test.exs:engine_with_scripts/2`.
  """
  @spec engine_with_scripts([[Script.spec31_entry()]], keyword()) :: Engine.t()
  def engine_with_scripts(scripts, opts \\ []) when is_list(scripts) and is_list(opts) do
    tools = Keyword.get(opts, :tools, [])
    extra_adapter_opts = Keyword.get(opts, :adapter_opts, [])
    extra_engine_opts = Keyword.get(opts, :engine_opts, [])

    cursor = Fake.start_script_cursor()

    adapter_opts =
      Keyword.merge(
        [scripts: scripts, script_cursor: cursor],
        extra_adapter_opts
      )

    engine_opts =
      [adapter: Fake, adapter_opts: adapter_opts, tools: tools]
      |> Keyword.merge(extra_engine_opts)

    Engine.new(engine_opts)
  end

  @doc """
  Plain text response. Returns `adapter_opts` that, fed to
  `ALLM.Providers.Fake.generate/2`, produces `%Response{output_text: text,
  finish_reason: :stop}`.

  Default text is `"Hello world"` so the fixture is a one-word replacement for
  inline scripts in trivial tests.

  ## Examples

      iex> ALLM.Test.FakeFixtures.plain_text("hi")
      [script: [{:text, "hi"}, {:finish, :stop}]]
  """
  @spec plain_text(String.t()) :: keyword()
  def plain_text(text \\ "Hello world") when is_binary(text) do
    [script: [{:text, text}, {:finish, :stop}]]
  end

  @doc """
  Single tool call response. Produces one `%ToolCall{}` with the given `name`
  and `arguments`, terminating with `:tool_calls` as the finish reason. The
  tool-call id is deterministically `"call_0"` so tests can assert on it.
  """
  @spec single_tool_call(String.t(), map()) :: keyword()
  def single_tool_call(name, arguments)
      when is_binary(name) and is_map(arguments) do
    [
      script: [
        {:tool_call, id: "call_0", name: name, arguments: arguments},
        {:finish, :tool_calls}
      ]
    ]
  end

  @doc """
  Parallel tool calls in a single assistant turn. Takes a list of
  `{name, arguments}` 2-tuples; ids are assigned deterministically as
  `"call_0"`, `"call_1"`, ... so tests can pattern-match.
  """
  @spec parallel_tool_calls([{String.t(), map()}]) :: keyword()
  def parallel_tool_calls(calls) when is_list(calls) do
    tool_entries =
      calls
      |> Enum.with_index()
      |> Enum.map(fn {{name, arguments}, idx}
                     when is_binary(name) and is_map(arguments) ->
        {:tool_call, id: "call_#{idx}", name: name, arguments: arguments}
      end)

    [script: tool_entries ++ [{:finish, :tool_calls}]]
  end

  @doc """
  Multi-turn conversation — each inner list is one call's worth of entries.
  The caller's list is wrapped verbatim under `scripts:` so every call
  advances the per-process cursor.

  Raises `ArgumentError` if any inner element isn't a list (quick failure mode
  so fixture callers see the error at fixture-construction time rather than at
  first `Fake.generate/2`).
  """
  @spec multi_turn_conversation([[Script.spec31_entry()]]) :: keyword()
  def multi_turn_conversation(scripts) when is_list(scripts) do
    unless Enum.all?(scripts, &is_list/1) do
      raise ArgumentError, "multi_turn_conversation/1 requires a list of lists"
    end

    [scripts: scripts]
  end

  @doc """
  Mid-stream adapter error. Emits a partial text delta followed by a scripted
  error with the given `reason` atom (must be a member of
  `ALLM.Error.AdapterError.reason()`).

  Feed into `ALLM.Providers.Fake.stream/2`; the event stream yields an event
  matching `{:error, %AdapterError{reason: reason}}` mid-stream. The `:error`
  is a mid-stream event, not a terminal one — the stream still closes
  well-formed with the synthetic `:text_completed` + `:message_completed`
  bookends. Consumers that need to stop at the error should branch on the
  `:error` tuple themselves (see `ALLM.StreamCollector`, Phase 5).
  """
  @spec mid_stream_error(AdapterError.reason()) :: keyword()
  def mid_stream_error(reason) when is_atom(reason) do
    [script: [{:text, "partial"}, {:error, reason}]]
  end

  @doc """
  Empty script — zero events this call. `ALLM.Providers.Fake.generate/2`
  returns an empty-but-valid `%Response{output_text: "", finish_reason:
  :stop, metadata: %{empty_script: true}}`; `stream/2` emits
  `:message_started` followed immediately by `:message_completed`.

  See Phase 4 design Non-obvious Decision #11 for the empty-script semantics.
  """
  @spec empty_response() :: keyword()
  def empty_response, do: [script: []]

  @doc """
  Tool call whose arguments stream as two deltas. `arguments_json` is split
  at a **codepoint boundary** (via `String.split_at/2`) into two halves; the
  fragments are emitted as separate `:tool_call_delta` entries on id
  `"call_1"`, and the reassembled string parses cleanly via `Jason.decode/1`.

  Feed into `ALLM.Providers.Fake.stream/2` to exercise streamed tool-call
  argument accumulation.
  """
  @spec tool_call_with_streamed_args(String.t(), String.t()) :: keyword()
  def tool_call_with_streamed_args(_name, arguments_json)
      when is_binary(arguments_json) do
    # Codepoint-based split so non-ASCII JSON never yields a mid-codepoint
    # fragment. String.split_at/2's length argument is in codepoints.
    len = String.length(arguments_json)
    split_point = div(len, 2)
    {first, second} = String.split_at(arguments_json, split_point)

    [
      script: [
        {:tool_call_delta, id: "call_1", arguments_delta: first},
        {:tool_call_delta, id: "call_1", arguments_delta: second},
        {:finish, :tool_calls}
      ]
    ]
  end

  @doc """
  Delayed text response. Emits a `{:delay, delay_ms}` before the text so the
  stream's first `:text_delta` event fires after ≥ `delay_ms` of wall-clock.

  `{:delay, _}` is front-loaded — see "Backpressure and delays" in the
  `ALLM.Providers.Fake` moduledoc.
  """
  @spec delayed_text(String.t(), non_neg_integer()) :: keyword()
  def delayed_text(text, delay_ms)
      when is_binary(text) and is_integer(delay_ms) and delay_ms >= 0 do
    [script: [{:delay, delay_ms}, {:text, text}, {:finish, :stop}]]
  end
end
