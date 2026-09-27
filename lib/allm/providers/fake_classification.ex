defmodule ALLM.Providers.FakeClassification do
  @moduledoc """
  Deterministic, scripted adapter for typed-classification testing.
  Implements `ALLM.ClassificationAdapter`.

  Layer B — runtime. FakeClassification is the canonical testing
  classification adapter; it ships in `lib/` (not `test/support/`) because
  users need it for their own application tests, like `ALLM.Providers.Fake`
  and `ALLM.Providers.FakeModeration`.

  ## What FakeClassification is (and isn't)

  FakeClassification never looks at `:state`. It reads `:questions` to answer
  each question id with an answer of the right type and shape, `:model` and
  `:metadata` to round-trip them onto the response, and nothing else. It
  does not re-validate the request: a question that
  `ALLM.Validate.classification_request/1` would reject may still be
  answered, or may raise.

  **Its confidence convention is its own and is NOT any provider's formula.**
  A default or scripted choice answer reports `confidence: 1.0`; a scripted
  fractional score reports the larger of its two level probabilities. A real
  adapter reports whatever its provider returns and never computes
  confidence.

  ## Default answers (no script)

  With **no script** — `adapter_opts[:classification_script]` absent or
  `[]` — every question gets a deterministic default:

  | Type | Default |
  |------|---------|
  | `:choice` | the lexicographically first option, probability `1.0` on it and `0.0` on every other option, `confidence: 1.0` |
  | `:score` | `score: 0.0`, probabilities `[1.0, 0.0, …]` (one per level), `legend` = the question's levels, `confidence: 1.0` |
  | `:yes_no` | `yes_probability: 0.0`, `confidence: nil` |

      iex> q = ALLM.ClassificationQuestion.choice("Which team?", ["technical", "billing"])
      iex> req = ALLM.ClassificationRequest.new(state: "My card was charged twice.", questions: %{"team" => q})
      iex> {:ok, resp} = ALLM.Providers.FakeClassification.classify(req, [])
      iex> ALLM.ClassificationResponse.answer(resp, "team").choice
      "billing"

  ## Spent script

  A **non-empty** script whose cursor has run off the end does NOT fall back
  to the defaults — it returns

      {:error, %ALLM.Error.ClassificationAdapterError{
         reason: :unknown,
         metadata: %{cause: :classification_script_exhausted}}}

  "I didn't script anything, give me a default" is a convenience; "my script
  ran out" is almost always an off-by-one in the caller's expectation of how
  many times `classify/2` gets invoked, and answering it with defaults would
  make that bug pass green.

  ## Script shapes

  `opts[:adapter_opts][:classification_script]` accepts a list of entries.
  See `script/1` for the grammar.

      adapter_opts: [
        classification_script: [
          {:answers, %{"team" => "billing", "frustration" => 1.25, "refund" => 0.9}},
          {:error, %ALLM.Error.ClassificationAdapterError{reason: :rate_limited}},
          {:retry_until_call, 3}
        ]
      ]

  `{:answers, map}` overrides the answer for each listed question id; every
  id not listed gets its default. A value is read according to the
  question's type:

  | Value | `:choice` | `:score` (n levels) | `:yes_no` |
  |-------|-----------|---------------------|-----------|
  | a string | the chosen option; must be one of the options | raises | raises |
  | a number | raises | the position, between `0` and `n - 1` | the probability of yes, between `0` and `1` |
  | `%ALLM.ClassificationAnswer{}` | used verbatim | used verbatim | used verbatim |

  A fractional score `x` puts probability `ceil(x) - x` on level `floor(x)`
  and `x - floor(x)` on level `ceil(x)`; a whole-number score puts `1.0` on
  that level. Every "raises" cell, an out-of-range number, and an id that is
  not one of the request's questions raise `ArgumentError` naming the
  question id: those are test-author mistakes and should not pass green.

  `{:retry_until_call, n}` returns a synthetic
  `%ALLM.Error.ClassificationAdapterError{reason: :rate_limited, retry_after_ms: 0}`
  for the first `n - 1` calls against this entry, then advances to the next
  entry on call `n`. Consecutive `{:retry_until_call, _}` entries chain into a
  layered budget.

  ## Cursor behaviour

  Multi-call scripts advance a per-process cursor on every call. The cursor
  lives in the process dictionary at
  `{:allm_fake_classification_cursor, key_id}`, isolated per ExUnit test
  process (`async: true`), GC'd on pid-down, zero-setup for the common case.
  The `key_id` is chosen by this precedence:

    1. `adapter_opts[:script_cursor]` — an explicit Agent pid (handled
       separately; see `start_script_cursor/0`).
    2. `adapter_opts[:cursor_key]` — the engine's stable `:id`, injected by
       the façade dispatch chokepoint via `ALLM.Engine.put_cursor_key/2`.
    3. `:erlang.phash2(script)` — the content-hash fallback for direct
       adapter calls with no engine.

  The `{:retry_until_call, n}` budget keys on the same identity, so two
  engines built with content-equal scripts each get their own cursor and
  their own retry budget. **The content-hash footgun remains only for DIRECT
  adapter calls** — `ALLM.Providers.FakeClassification.classify(req, opts)`
  invoked without an engine receives no `:cursor_key`. Workaround for that
  path: pass distinct `adapter_opts[:script_cursor]` Agent pids from
  `start_script_cursor/0`, or distinct `:cursor_key` values.

  ## Test-only capture seam

  Pass `adapter_opts[:capture_pid]` with a pid to receive a side-channel
  message every time `classify/2` is invoked, BEFORE the empty-questions
  gate runs and before the script is consulted:

      {ALLM.Providers.FakeClassification, :call, %{request: request, opts: opts}}

  It does not affect the response.
  """

  @behaviour ALLM.ClassificationAdapter

  alias ALLM.{ClassificationAnswer, ClassificationQuestion, ClassificationRequest}
  alias ALLM.{ClassificationResponse, Usage}
  alias ALLM.Error.ClassificationAdapterError

  @default_model "fake-classification"

  @typedoc "One scripted classification call."
  @type script_entry ::
          {:answers, %{String.t() => String.t() | number() | ClassificationAnswer.t()}}
          | {:error, ClassificationAdapterError.t()}
          | {:retry_until_call, pos_integer()}

  # ---------------------------------------------------------------------------
  # ALLM.ClassificationAdapter — classify/2
  # ---------------------------------------------------------------------------

  @doc """
  Execute a scripted classification request.

  Order, all before the script is consulted:

    1. `adapter_opts[:capture_pid]` side-channel (fires even for rejected
       calls).
    2. `questions: %{}` →
       `{:error, %ClassificationAdapterError{reason: :invalid_request}}`.

  Otherwise reads the script from `opts[:adapter_opts][:classification_script]`,
  advances the process-local cursor, and interprets the entry. An **absent**
  script produces the default answers; a **spent non-empty** script returns
  `:classification_script_exhausted`.

  The response carries `model: request.model || "fake-classification"`,
  `provider: :fake`, zero token usage, `request_id: opts[:request_id]`,
  `metadata: request.metadata`, and `id: nil`.

  ## Examples

      iex> q = ALLM.ClassificationQuestion.yes_no("Is a refund requested?")
      iex> req = ALLM.ClassificationRequest.new(state: "Please refund me.", questions: %{"refund" => q})
      iex> opts = [adapter_opts: [classification_script: [{:answers, %{"refund" => 0.9}}]]]
      iex> {:ok, resp} = ALLM.Providers.FakeClassification.classify(req, opts)
      iex> ALLM.ClassificationResponse.answer(resp, "refund").yes_probability
      0.9

      iex> req = ALLM.ClassificationRequest.new(state: "x", questions: %{})
      iex> {:error, err} = ALLM.Providers.FakeClassification.classify(req, [])
      iex> err.reason
      :invalid_request
  """
  @impl ALLM.ClassificationAdapter
  @spec classify(ClassificationRequest.t(), keyword()) ::
          {:ok, ClassificationResponse.t()} | {:error, ClassificationAdapterError.t()}
  def classify(%ClassificationRequest{} = request, opts) when is_list(opts) do
    maybe_capture(request, opts)

    case gate(request) do
      :ok -> run_scripted(request, opts)
      {:error, _} = error -> error
    end
  end

  # Contract invariant 6 — fires before any script consult, so a direct caller
  # sees the same rejection a real adapter produces before its first byte of
  # HTTP I/O and before it resolves a key.
  defp gate(%ClassificationRequest{questions: questions}) when questions == %{} do
    {:error,
     ClassificationAdapterError.new(:invalid_request,
       message: "questions must not be empty",
       metadata: %{field: :questions}
     )}
  end

  defp gate(%ClassificationRequest{}), do: :ok

  # ---------------------------------------------------------------------------
  # Public helpers
  # ---------------------------------------------------------------------------

  @doc """
  Document and validate the script grammar for
  `adapter_opts[:classification_script]`.

  Each entry is one of:

    * `{:answers, %{id => value}}` — per-id overrides; see the module docs for
      how each value is read.
    * `{:error, %ALLM.Error.ClassificationAdapterError{}}` — return the struct
      verbatim.
    * `{:retry_until_call, n}` — synthetic `:rate_limited` for the first
      `n - 1` calls against this entry.

  Returns `:ok` when the script is well-formed and raises `ArgumentError` on
  the first invalid entry. Validation is opt-in: `classify/2` does not call
  it. It checks entry shapes only; whether an `{:answers, map}` value fits its
  question is checked when `classify/2` reads it.

  ## Examples

      iex> ALLM.Providers.FakeClassification.script([{:answers, %{"team" => "billing"}}, {:retry_until_call, 2}])
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

  Pass the returned pid as `adapter_opts[:script_cursor]`.

  ## Examples

      iex> pid = ALLM.Providers.FakeClassification.start_script_cursor()
      iex> ALLM.Providers.FakeClassification.cursor_index(pid)
      0
  """
  @spec start_script_cursor() :: pid()
  def start_script_cursor do
    {:ok, pid} = Agent.start_link(fn -> 0 end)
    pid
  end

  @doc """
  Read the current cursor index for an Agent-backed cursor. Used in tests to
  assert how many script entries have been consumed.

  ## Examples

      iex> pid = ALLM.Providers.FakeClassification.start_script_cursor()
      iex> q = ALLM.ClassificationQuestion.yes_no("Spam?")
      iex> req = ALLM.ClassificationRequest.new(state: "x", questions: %{"spam" => q})
      iex> opts = [adapter_opts: [classification_script: [{:answers, %{}}], script_cursor: pid]]
      iex> {:ok, _} = ALLM.Providers.FakeClassification.classify(req, opts)
      iex> ALLM.Providers.FakeClassification.cursor_index(pid)
      1
  """
  @spec cursor_index(pid()) :: non_neg_integer()
  def cursor_index(pid) when is_pid(pid), do: Agent.get(pid, & &1)

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp maybe_capture(%ClassificationRequest{} = request, opts) do
    case opts |> Keyword.get(:adapter_opts, []) |> Keyword.get(:capture_pid) do
      pid when is_pid(pid) ->
        send(pid, {__MODULE__, :call, %{request: request, opts: opts}})
        :ok

      _ ->
        :ok
    end
  end

  defp run_scripted(%ClassificationRequest{} = request, opts) do
    adapter_opts = Keyword.get(opts, :adapter_opts, [])
    script = Keyword.get(adapter_opts, :classification_script, [])

    # Peek WITHOUT advancing — `:retry_until_call` holds the cursor in place
    # for `n - 1` calls and only advances on call n. Every other entry shape
    # advances on consult.
    cursor = peek_cursor(script, adapter_opts)

    case Enum.at(script, cursor) do
      nil ->
        _ = advance_cursor(script, adapter_opts)
        spent_or_default(script, request, opts)

      # A malformed `n` (non-integer or < 1) falls through to
      # `interpret_entry/3`'s grammar-naming raise, like every other bad entry.
      {:retry_until_call, n} when is_integer(n) and n >= 1 ->
        handle_retry_until_call(script, cursor, n, request, opts, adapter_opts)

      entry ->
        _ = advance_cursor(script, adapter_opts)
        interpret_entry(entry, request, opts)
    end
  end

  defp interpret_entry({:answers, overrides}, request, opts) when is_map(overrides) do
    {:ok, build_response(answers(request.questions, overrides), request, opts)}
  end

  defp interpret_entry({:error, %ClassificationAdapterError{} = err}, _request, _opts),
    do: {:error, err}

  defp interpret_entry(other, _request, _opts) do
    raise ArgumentError,
          "invalid FakeClassification script entry: #{inspect(other)} " <> expected_entries()
  end

  defp handle_retry_until_call(script, cursor, n, request, opts, adapter_opts) do
    visits = bump_retry_visits(script, cursor, adapter_opts)

    if visits < n do
      {:error,
       ClassificationAdapterError.new(:rate_limited,
         message: "FakeClassification retry_until_call hint",
         retry_after_ms: 0
       )}
    else
      _ = advance_cursor(script, adapter_opts)
      next_cursor = cursor + 1

      case Enum.at(script, next_cursor) do
        nil ->
          spent_or_default(script, request, opts)

        {:retry_until_call, m} when is_integer(m) and m >= 1 ->
          # Chained budgets: this call lands ON the next retry entry and opens
          # its budget rather than consuming it as a result entry.
          handle_retry_until_call(script, next_cursor, m, request, opts, adapter_opts)

        next_entry ->
          _ = advance_cursor(script, adapter_opts)
          interpret_entry(next_entry, request, opts)
      end
    end
  end

  # MUST key on the SAME identity the cursor helpers use (`cursor_key_id/2`).
  # Keying on `:erlang.phash2(script)` alone would give two content-equal
  # engines separate cursors but a SHARED retry budget, so the second engine
  # would skip its scripted `:rate_limited` returns and succeed on call one.
  defp bump_retry_visits(script, cursor, adapter_opts) do
    key = {:allm_fake_classification_retry_visits, cursor_key_id(script, adapter_opts), cursor}
    visits = Process.get(key, 0) + 1
    Process.put(key, visits)
    visits
  end

  # Only an absent (or `[]`) script yields defaults; a NON-EMPTY script that
  # has run off the end is a caller off-by-one and errors.
  defp spent_or_default([], request, opts) do
    {:ok, build_response(answers(request.questions, %{}), request, opts)}
  end

  defp spent_or_default(_script, _request, _opts) do
    {:error,
     ClassificationAdapterError.new(:unknown,
       message: "FakeClassification script exhausted: no entry at the current cursor position",
       metadata: %{cause: :classification_script_exhausted}
     )}
  end

  defp build_response(answers, %ClassificationRequest{} = request, opts) do
    %ClassificationResponse{
      id: nil,
      request_id: Keyword.get(opts, :request_id),
      model: request.model || @default_model,
      provider: :fake,
      answers: answers,
      usage: %Usage{input_tokens: 0, output_tokens: 0, total_tokens: 0},
      raw: nil,
      metadata: request.metadata
    }
  end

  # ---------------------------------------------------------------------------
  # Answers
  # ---------------------------------------------------------------------------

  defp answers(questions, overrides) do
    case Enum.reject(Map.keys(overrides), &Map.has_key?(questions, &1)) do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "FakeClassification {:answers, map} names #{inspect(unknown)}, which " <>
                "are not question ids in the request (#{inspect(Map.keys(questions))})"
    end

    Map.new(questions, fn {id, question} ->
      answer =
        case Map.fetch(overrides, id) do
          {:ok, value} -> scripted_answer(id, question, value)
          :error -> default_answer(question)
        end

      {id, answer}
    end)
  end

  defp default_answer(%ClassificationQuestion{type: :choice, criteria: criteria}),
    do: choice_answer(criteria, criteria |> Map.keys() |> Enum.min())

  defp default_answer(%ClassificationQuestion{type: :score, criteria: levels}),
    do: score_answer(0.0, levels)

  defp default_answer(%ClassificationQuestion{type: :yes_no}),
    do: ClassificationAnswer.new(type: :yes_no, yes_probability: 0.0)

  defp scripted_answer(_id, _question, %ClassificationAnswer{} = answer), do: answer

  defp scripted_answer(id, %ClassificationQuestion{type: :choice, criteria: criteria}, option)
       when is_binary(option) do
    if Map.has_key?(criteria, option) do
      choice_answer(criteria, option)
    else
      bad_value!(id, option, "one of the options #{inspect(criteria |> Map.keys() |> Enum.sort())}")
    end
  end

  defp scripted_answer(id, %ClassificationQuestion{type: :score, criteria: levels}, x)
       when is_number(x) do
    top = length(levels) - 1

    if x >= 0 and x <= top,
      do: score_answer(x * 1.0, levels),
      else: bad_value!(id, x, "a number between 0 and #{top} (the score levels)")
  end

  defp scripted_answer(id, %ClassificationQuestion{type: :yes_no}, x) when is_number(x) do
    if x >= 0 and x <= 1,
      do: ClassificationAnswer.new(type: :yes_no, yes_probability: x * 1.0),
      else: bad_value!(id, x, "a number between 0 and 1 (the probability of yes)")
  end

  defp scripted_answer(id, %ClassificationQuestion{type: type}, value),
    do: bad_value!(id, value, accepts(type))

  defp accepts(:choice), do: "an option name (a string) or a %ClassificationAnswer{}"
  defp accepts(:score), do: "a number (the score position) or a %ClassificationAnswer{}"
  defp accepts(:yes_no), do: "a number (the probability of yes) or a %ClassificationAnswer{}"

  defp bad_value!(id, value, accepts) do
    raise ArgumentError,
          "FakeClassification answer for question #{inspect(id)} is #{inspect(value)}; " <>
            "it accepts #{accepts}"
  end

  defp choice_answer(criteria, chosen) do
    ClassificationAnswer.new(
      type: :choice,
      choice: chosen,
      probabilities:
        Map.new(criteria, fn {option, _} -> {option, if(option == chosen, do: 1.0, else: 0.0)} end),
      confidence: 1.0
    )
  end

  # `x` is a float in 0..length(levels) - 1. Probability sits on the one or
  # two levels either side of it; confidence is the larger share.
  defp score_answer(x, levels) do
    lo = floor(x)
    hi = ceil(x)

    weights =
      if lo == hi,
        do: %{lo => 1.0},
        else: %{lo => hi - x, hi => x - lo}

    probabilities = for level <- 0..(length(levels) - 1)//1, do: Map.get(weights, level, 0.0)

    ClassificationAnswer.new(
      type: :score,
      score: x,
      probabilities: probabilities,
      legend: levels,
      confidence: weights |> Map.values() |> Enum.max()
    )
  end

  # ---------------------------------------------------------------------------
  # Cursor management (a private copy of FakeModeration's)
  # ---------------------------------------------------------------------------

  defp advance_cursor(script, adapter_opts) do
    case Keyword.get(adapter_opts, :script_cursor) do
      nil ->
        key = {:allm_fake_classification_cursor, cursor_key_id(script, adapter_opts)}
        current = Process.get(key, 0)
        Process.put(key, current + 1)
        current

      pid when is_pid(pid) ->
        Agent.get_and_update(pid, fn i -> {i, i + 1} end)
    end
  end

  # Read the current cursor without advancing. MUST key on the SAME slot as
  # `advance_cursor/2`, or retry counting breaks.
  defp peek_cursor(script, adapter_opts) do
    case Keyword.get(adapter_opts, :script_cursor) do
      nil -> Process.get({:allm_fake_classification_cursor, cursor_key_id(script, adapter_opts)}, 0)
      pid when is_pid(pid) -> Agent.get(pid, & &1)
    end
  end

  # Single source of truth for the cursor identity, shared by the cursor
  # helpers and `bump_retry_visits/3`: `:script_cursor` pid > `:cursor_key` >
  # `:erlang.phash2(script)`. `||` falls back only on `nil`.
  defp cursor_key_id(script, adapter_opts) do
    case Keyword.get(adapter_opts, :script_cursor) do
      pid when is_pid(pid) -> pid
      _ -> Keyword.get(adapter_opts, :cursor_key) || :erlang.phash2(script)
    end
  end

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  defp validate_entry!({:answers, overrides}) when is_map(overrides), do: :ok
  defp validate_entry!({:error, %ClassificationAdapterError{}}), do: :ok
  defp validate_entry!({:retry_until_call, n}) when is_integer(n) and n >= 1, do: :ok

  defp validate_entry!(other) do
    raise ArgumentError,
          "invalid FakeClassification script entry: #{inspect(other)} " <> expected_entries()
  end

  defp expected_entries,
    do:
      "(expected {:answers, %{id => value}}, {:error, %ClassificationAdapterError{}}, " <>
        "or {:retry_until_call, pos_integer})"
end
