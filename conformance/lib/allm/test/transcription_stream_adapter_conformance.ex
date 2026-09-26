defmodule ALLM.Test.TranscriptionStreamAdapterConformance do
  @moduledoc """
  Injectable conformance suite for `ALLM.TranscriptionStreamAdapter`
  implementations.

  ## Installation

      {:allm_conformance, "~> 0.3", only: :test}

  ## Usage

      defmodule MyTranscriptionStreamAdapterTest do
        use ExUnit.Case, async: true

        use ALLM.Test.TranscriptionStreamAdapterConformance,
          transcription_adapter: MyTranscriptionAdapter
      end

  Injects a
  `describe "ALLM.TranscriptionStreamAdapter conformance (MyTranscriptionAdapter)"`
  block with 6 deterministic cases.

  ## Script contract

  Cases tagged **[scripted]** drive the adapter through
  `adapter_opts[:transcription_script]` with a one-entry script, so a real
  provider adapter never opens a socket. A real provider adapter honours
  the key by handing the call to
  `ALLM.Providers.FakeTranscription.stream_transcribe/3` before any of its
  own gates run, passing its own `stream_sample_rates/0` as
  `adapter_opts[:stream_sample_rates]`. Every scripted case uses the first
  rate the adapter reports, so the hand-off accepts it.

  Cases tagged **[unscripted]** pass no script and no key, so only the
  adapter's own gates are reached, and they must fire before
  `ALLM.Keys.fetch!/2` and before the enumerable is returned.

  ### `:gate_opts`

  The `:gate_opts` option (a keyword list, default `[]`) is passed as the
  opts of every [unscripted] case that calls `stream_transcribe/3`. Pass a
  transport seam that fails, so a gate placed after key resolution fails
  the case instead of reaching the provider:

      use ALLM.Test.TranscriptionStreamAdapterConformance,
        transcription_adapter: MyTranscriptionAdapter,
        gate_opts: [ws_module: RaisingWebSocket]

  ## What this suite does NOT bind

  **Halt-safety and `:stream_timeout` are unbound.** A scripted hand-off
  never reaches the transport, so they are bound by each adapter's own wire
  tests. **Invariant 8** (end-of-input commit and wait) likewise needs a
  transport.

  **Invariant 7 is bound only for its odd-total-length arm** (case 4). A
  non-binary, non-`:commit` element, an input that raises
  (`:input_raised`), an input killed by an exit signal (`:input_crashed`),
  an odd-length chunk completed by the next one, and "the audio the
  provider receives equals the concatenated input" are unbound here and
  are bound by each adapter's own tests.

  No case body is gated on a fixture from this package's own test tree.

  ## Why the helpers below take and return plain data

  This package is compiled *before* `allm` in a consuming project's build, so
  the harness module body must not reference `ALLM.*` functions directly.
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
  `n` bytes of PCM16 silence.
  """
  @spec silence(non_neg_integer()) :: binary()
  def silence(n) when is_integer(n) and n >= 0, do: :binary.copy(<<0>>, n)

  @doc """
  Return `true` when `events` is a successful transcription stream: one
  `:transcription_started`, then only `:partial_transcript` and
  `:committed_transcript` events, then one `:transcription_completed`, and
  nothing after it.
  """
  @spec success_grammar?(list()) :: boolean()
  def success_grammar?([{:transcription_started, started} | rest]) when is_map(started) do
    case Enum.split_while(rest, &segment_event?/1) do
      {_, [{:transcription_completed, completed}]} when is_map(completed) -> true
      _ -> false
    end
  end

  def success_grammar?(_events), do: false

  @doc """
  Return `true` when `events` is a failed transcription stream: an optional
  `:transcription_started`, then only partial and committed transcripts,
  then one `{:error, _}`, and nothing after it.
  """
  @spec failure_grammar?(list()) :: boolean()
  def failure_grammar?([{:transcription_started, started} | rest]) when is_map(started),
    do: segments_then_error?(rest)

  def failure_grammar?(events) when is_list(events), do: segments_then_error?(events)

  defp segments_then_error?(events) do
    case Enum.split_while(events, &segment_event?/1) do
      {_, [{:error, _}]} -> true
      _ -> false
    end
  end

  defp segment_event?({:partial_transcript, %{text: text}}) when is_binary(text), do: true
  defp segment_event?({:committed_transcript, %{text: text}}) when is_binary(text), do: true
  defp segment_event?(_), do: false

  using opts do
    quote location: :keep do
      @__allm_transcription_stream_conformance_adapter__ Keyword.fetch!(
                                                           unquote(opts),
                                                           :transcription_adapter
                                                         )

      describe "ALLM.TranscriptionStreamAdapter conformance (#{inspect(@__allm_transcription_stream_conformance_adapter__)})" do
        alias ALLM.Error.TranscriptionAdapterError
        alias ALLM.Test.TranscriptionStreamAdapterConformance, as: Harness
        alias ALLM.TranscriptionStreamRequest

        test "1. [unscripted] stream_sample_rates/0 is a non-empty list of pos_integer" do
          rates = @__allm_transcription_stream_conformance_adapter__.stream_sample_rates()

          assert is_list(rates)
          assert rates != []
          assert Enum.all?(rates, &(is_integer(&1) and &1 > 0))
        end

        test "2. [scripted] 3,200 bytes of silence give a grammar-conformant stream" do
          adapter = @__allm_transcription_stream_conformance_adapter__
          [rate | _] = adapter.stream_sample_rates()

          assert {:ok, stream} =
                   adapter.stream_transcribe(
                     TranscriptionStreamRequest.new(sample_rate: rate),
                     [Harness.silence(3_200)],
                     adapter_opts: [transcription_script: [{:ok, "conformance transcript"}]]
                   )

          events = Enum.to_list(stream)
          assert Harness.success_grammar?(events), "grammar violated: #{inspect(events)}"
        end

        test "3. [unscripted] an unsupported sample rate is rejected synchronously before any key" do
          adapter = @__allm_transcription_stream_conformance_adapter__
          rate = Enum.max(adapter.stream_sample_rates()) + 1
          opts = Keyword.get(unquote(opts), :gate_opts, [])

          assert {:error, %TranscriptionAdapterError{reason: :invalid_request, metadata: meta}} =
                   adapter.stream_transcribe(
                     TranscriptionStreamRequest.new(sample_rate: rate),
                     [Harness.silence(2)],
                     opts
                   )

          assert meta.sample_rate == rate
        end

        test "4. [scripted] an input whose total length is odd ends with :invalid_input_chunk" do
          adapter = @__allm_transcription_stream_conformance_adapter__
          [rate | _] = adapter.stream_sample_rates()
          req = TranscriptionStreamRequest.new(sample_rate: rate)

          assert {:ok, odd} =
                   adapter.stream_transcribe(req, [<<1, 2, 3>>],
                     adapter_opts: [transcription_script: [{:ok, "odd total"}]]
                   )

          events = Enum.to_list(odd)
          assert Harness.failure_grammar?(events), "grammar violated: #{inspect(events)}"

          assert {:error,
                  %TranscriptionAdapterError{
                    reason: :invalid_request,
                    metadata: %{cause: :invalid_input_chunk}
                  }} = List.last(events)

          # An odd-length chunk followed by one that completes the sample is
          # not an error: chunk boundaries are the caller's.
          assert {:ok, even} =
                   adapter.stream_transcribe(req, [<<1, 2, 3>>, <<4>>],
                     adapter_opts: [transcription_script: [{:ok, "even total"}]]
                   )

          events = Enum.to_list(even)
          assert Harness.success_grammar?(events), "grammar violated: #{inspect(events)}"
        end

        test "5. [scripted] opts[:request_id] appears on both envelope events" do
          adapter = @__allm_transcription_stream_conformance_adapter__
          [rate | _] = adapter.stream_sample_rates()

          assert {:ok, stream} =
                   adapter.stream_transcribe(
                     TranscriptionStreamRequest.new(sample_rate: rate),
                     [Harness.silence(320)],
                     adapter_opts: [transcription_script: [{:ok, "conformance transcript"}]],
                     request_id: "test-id-123"
                   )

          events = Enum.to_list(stream)
          assert [{:transcription_started, %{request_id: "test-id-123"}} | _] = events
          assert {:transcription_completed, %{request_id: "test-id-123"}} = List.last(events)
        end

        test "6. [scripted] request.metadata round-trips onto :transcription_completed" do
          adapter = @__allm_transcription_stream_conformance_adapter__
          [rate | _] = adapter.stream_sample_rates()
          metadata = %{"k" => "v", trace_id: "abc"}

          assert {:ok, stream} =
                   adapter.stream_transcribe(
                     TranscriptionStreamRequest.new(sample_rate: rate, metadata: metadata),
                     [Harness.silence(320)],
                     adapter_opts: [transcription_script: [{:ok, "conformance transcript"}]]
                   )

          assert {:transcription_completed, %{metadata: ^metadata}} =
                   stream |> Enum.to_list() |> List.last()
        end
      end
    end
  end
end
