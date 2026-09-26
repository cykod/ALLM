defmodule ALLM.Test.SpeechStreamAdapterConformance do
  @moduledoc """
  Injectable conformance suite for `c:ALLM.SpeechStreamAdapter.stream_synthesize/2`.

  ## Installation

      {:allm_conformance, "~> 0.3", only: :test}

  ## Usage

      defmodule MySpeechStreamAdapterTest do
        use ExUnit.Case, async: true
        use ALLM.Test.SpeechStreamAdapterConformance, speech_adapter: MySpeechAdapter
      end

  Injects a
  `describe "ALLM.SpeechStreamAdapter conformance (MySpeechAdapter)"` block
  with 6 deterministic cases.

  ## Script contract

  Cases tagged **[scripted]** drive the adapter through
  `adapter_opts[:speech_script]` with a one-entry script, so a real provider
  adapter never touches the network. See `ALLM.Providers.FakeSpeech`'s
  `script/1` `@doc` for the grammar. A real provider adapter honours the key
  by handing the call to `ALLM.Providers.FakeSpeech.stream_synthesize/2`
  before any of its own gates run.

  Cases tagged **[unscripted]** pass no script and no key, so only the
  adapter's own gates are reached. Gates must fire before
  `ALLM.Keys.fetch!/2` and before the enumerable is returned, so a keyless
  environment observes the synchronous rejection rather than
  `%ALLM.Error.EngineError{reason: :missing_key}`.

  ### `:gate_opts`

  Keyless means keyless even in a shell that exports a provider key. The
  `:gate_opts` option (a keyword list, default `[]`) is passed as the opts
  of every [unscripted] case. Pass transport seams that fail, so a gate
  placed after key resolution fails the case instead of reaching the
  provider:

      use ALLM.Test.SpeechStreamAdapterConformance,
        speech_adapter: MySpeechAdapter,
        gate_opts: [finch_module: RaisingFinch, ws_module: RaisingWebSocket]

  ## What this suite does NOT bind

  **Invariant 1 is unbound** beyond the shapes the cases return; the
  streaming façade checks every element of the stream instead.

  **Invariants 4 and 5 (halt-safety and `:stream_timeout`) are unbound.** A
  scripted hand-off never reaches the transport, so they are bound by each
  adapter's own wire tests.

  **Invariants 3 and 8 are bound only for an adapter that implements
  `stream_synthesize/2` itself.** For an adapter whose script short-circuit
  hands off to `ALLM.Providers.FakeSpeech`, the scripted cases certify the
  Fake, not that adapter's decoder.

  No case body is gated on a fixture from this package's own test tree.

  ## Why the helpers below take and return plain data

  This package is compiled *before* `allm` in a consuming project's build, so
  the harness module body must not reference `ALLM.*` functions directly —
  every such call happens inside the `using/1` `quote`.
  """

  use ExUnit.CaseTemplate

  @case_count 6

  @doc """
  Return the number of cases injected by `using/1`. Used by harness
  self-tests to guard against silent case-count drift.
  """
  @spec case_count() :: pos_integer()
  def case_count, do: @case_count

  @doc """
  Return `true` when `events` is a successful speech stream: one
  `:speech_started`, one or more `:audio_delta`, then one
  `:speech_completed`, and nothing after it.
  """
  @spec success_grammar?(list()) :: boolean()
  def success_grammar?([{:speech_started, started} | rest]) when is_map(started) do
    case Enum.split_while(rest, &match?({:audio_delta, _}, &1)) do
      {[_ | _], [{:speech_completed, completed}]} when is_map(completed) -> true
      _ -> false
    end
  end

  def success_grammar?(_events), do: false

  @doc """
  Return `true` when `events` is a failed speech stream: an optional
  `:speech_started`, zero or more `:audio_delta`, then one `{:error, _}`,
  and nothing after it.
  """
  @spec failure_grammar?(list()) :: boolean()
  def failure_grammar?([{:speech_started, started} | rest]) when is_map(started),
    do: deltas_then_error?(rest)

  def failure_grammar?(events) when is_list(events), do: deltas_then_error?(events)

  defp deltas_then_error?(events) do
    case Enum.split_while(events, &match?({:audio_delta, _}, &1)) do
      {_, [{:error, _}]} -> true
      _ -> false
    end
  end

  @doc """
  The scripted audio every [scripted] case supplies: 2,500 bytes, long
  enough that an adapter chunking at 1,024 bytes emits several deltas.
  """
  @spec audio() :: binary()
  def audio, do: :binary.copy("conformance stream audio ", 100)

  @doc """
  Concatenate every `:audio_delta` payload of `events`, in order.
  """
  @spec concat_deltas(list()) :: binary()
  def concat_deltas(events), do: for({:audio_delta, bytes} <- events, into: "", do: bytes)

  using opts do
    quote location: :keep do
      @__allm_speech_stream_conformance_adapter__ Keyword.fetch!(
                                                    unquote(opts),
                                                    :speech_adapter
                                                  )

      describe "ALLM.SpeechStreamAdapter conformance (#{inspect(@__allm_speech_stream_conformance_adapter__)})" do
        alias ALLM.Error.SpeechAdapterError
        alias ALLM.SpeechRequest
        alias ALLM.Test.SpeechStreamAdapterConformance, as: Harness

        test "1. [scripted] the event list obeys the speech stream grammar" do
          assert {:ok, stream} =
                   @__allm_speech_stream_conformance_adapter__.stream_synthesize(
                     SpeechRequest.new(input: "Hello."),
                     adapter_opts: [speech_script: [{:ok, Harness.audio()}]]
                   )

          events = Enum.to_list(stream)
          assert Harness.success_grammar?(events), "grammar violated: #{inspect(events)}"
        end

        test "2. [scripted] the concatenated deltas equal the scripted bytes" do
          assert {:ok, stream} =
                   @__allm_speech_stream_conformance_adapter__.stream_synthesize(
                     SpeechRequest.new(input: "Hello."),
                     adapter_opts: [speech_script: [{:ok, Harness.audio()}]]
                   )

          assert Harness.concat_deltas(Enum.to_list(stream)) == Harness.audio()
        end

        test "3. [scripted] every :audio_delta is a non-empty binary" do
          assert {:ok, stream} =
                   @__allm_speech_stream_conformance_adapter__.stream_synthesize(
                     SpeechRequest.new(input: "Hello."),
                     adapter_opts: [speech_script: [{:ok, Harness.audio()}]]
                   )

          deltas = for {:audio_delta, bytes} <- Enum.to_list(stream), do: bytes
          assert deltas != []
          assert Enum.all?(deltas, &(is_binary(&1) and &1 != ""))
        end

        test "4. [unscripted] empty input is rejected synchronously with :invalid_request before any key" do
          opts = Keyword.get(unquote(opts), :gate_opts, [])

          assert {:error, %SpeechAdapterError{reason: :invalid_request}} =
                   @__allm_speech_stream_conformance_adapter__.stream_synthesize(
                     SpeechRequest.new(input: ""),
                     opts
                   )
        end

        test "5. [scripted] opts[:request_id] appears on both envelope events" do
          assert {:ok, stream} =
                   @__allm_speech_stream_conformance_adapter__.stream_synthesize(
                     SpeechRequest.new(input: "Hello."),
                     adapter_opts: [speech_script: [{:ok, Harness.audio()}]],
                     request_id: "test-id-123"
                   )

          events = Enum.to_list(stream)
          assert [{:speech_started, %{request_id: "test-id-123"}} | _] = events
          assert {:speech_completed, %{request_id: "test-id-123"}} = List.last(events)
        end

        test "6. [scripted] request.metadata round-trips onto :speech_completed" do
          metadata = %{"k" => "v", trace_id: "abc"}

          assert {:ok, stream} =
                   @__allm_speech_stream_conformance_adapter__.stream_synthesize(
                     SpeechRequest.new(input: "Hello.", metadata: metadata),
                     adapter_opts: [speech_script: [{:ok, Harness.audio()}]]
                   )

          assert {:speech_completed, %{metadata: ^metadata}} =
                   stream |> Enum.to_list() |> List.last()
        end
      end
    end
  end
end
