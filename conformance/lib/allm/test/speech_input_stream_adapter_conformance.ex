defmodule ALLM.Test.SpeechInputStreamAdapterConformance do
  @moduledoc """
  Injectable conformance suite for the optional
  `c:ALLM.SpeechStreamAdapter.stream_synthesize_input/3` callback.

  ## Installation

      {:allm_conformance, "~> 0.3", only: :test}

  ## Usage

  Use it only for an adapter that exports the optional callback:

      defmodule MySpeechInputStreamAdapterTest do
        use ExUnit.Case, async: true
        use ALLM.Test.SpeechInputStreamAdapterConformance, speech_adapter: MySpeechAdapter
      end

  Injects a
  `describe "ALLM.SpeechStreamAdapter input conformance (MySpeechAdapter)"`
  block with 6 deterministic cases.

  ## Script contract

  Cases tagged **[scripted]** drive the adapter through
  `adapter_opts[:speech_script]` with a one-entry script, so a real provider
  adapter never opens a socket. A real provider adapter honours the key by
  handing the call to
  `ALLM.Providers.FakeSpeech.stream_synthesize_input/3` before any of its
  own gates run. The scripted cases still exercise the input invariants,
  because the Fake reduces the input exactly as a real adapter does.

  Case 1 is a premise guard with no call. Case 6 is **[unscripted]**: it
  passes no script and no key, so only the adapter's own gates are reached,
  and they must reject a bad request before `ALLM.Keys.fetch!/2`, before
  the enumerable is returned, and before the input is reduced.

  ### `:gate_opts`

  The `:gate_opts` option (a keyword list, default `[]`) is passed as the
  opts of the [unscripted] case. Pass transport seams that fail, so a gate
  placed after key resolution fails the case instead of reaching the
  provider:

      use ALLM.Test.SpeechInputStreamAdapterConformance,
        speech_adapter: MySpeechAdapter,
        gate_opts: [ws_module: RaisingWebSocket]

  ## What this suite does NOT bind

  **Halt-safety and `:stream_timeout` are unbound.** A scripted hand-off
  never reaches the transport, so they are bound by each adapter's own wire
  tests. **`:input_crashed`** (an input killed by an exit signal) is bound by
  the pump's own tests, not here.

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
  The scripted audio every [scripted] case supplies.
  """
  @spec audio() :: binary()
  def audio, do: "conformance input stream audio"

  @doc """
  An input enumerable that sends `:reduced` to `pid` when it is reduced.
  """
  @spec tattling_input(pid()) :: Enumerable.t()
  def tattling_input(pid) do
    Stream.map(["Hello."], fn chunk ->
      send(pid, :reduced)
      chunk
    end)
  end

  @doc """
  An input enumerable that raises when its first element is pulled.
  """
  @spec raising_input() :: Enumerable.t()
  def raising_input, do: Stream.map([1], fn _ -> raise ArgumentError, "conformance input" end)

  using opts do
    quote location: :keep do
      @__allm_speech_input_conformance_adapter__ Keyword.fetch!(
                                                   unquote(opts),
                                                   :speech_adapter
                                                 )

      describe "ALLM.SpeechStreamAdapter input conformance (#{inspect(@__allm_speech_input_conformance_adapter__)})" do
        alias ALLM.Error.SpeechAdapterError
        alias ALLM.SpeechRequest
        alias ALLM.Test.SpeechInputStreamAdapterConformance, as: Harness
        alias ALLM.Test.SpeechStreamAdapterConformance, as: Grammar

        test "1. the adapter exports the optional stream_synthesize_input/3 (premise)" do
          adapter = @__allm_speech_input_conformance_adapter__

          assert Code.ensure_loaded?(adapter) and
                   function_exported?(adapter, :stream_synthesize_input, 3),
                 "#{inspect(adapter)} does not export stream_synthesize_input/3; " <>
                   "this suite applies only to adapters that implement it"
        end

        test "2. [scripted] a chunked input gives a grammar-conformant stream" do
          assert {:ok, stream} =
                   @__allm_speech_input_conformance_adapter__.stream_synthesize_input(
                     SpeechRequest.new(input: ""),
                     ["Hel", "lo."],
                     adapter_opts: [speech_script: [{:ok, Harness.audio()}]]
                   )

          events = Enum.to_list(stream)
          assert Grammar.success_grammar?(events), "grammar violated: #{inspect(events)}"
        end

        test "3. [scripted] a non-binary chunk ends the stream with :invalid_input_chunk" do
          assert {:ok, stream} =
                   @__allm_speech_input_conformance_adapter__.stream_synthesize_input(
                     SpeechRequest.new(input: ""),
                     ["Hel", 123],
                     adapter_opts: [speech_script: [{:ok, Harness.audio()}]]
                   )

          events = Enum.to_list(stream)
          assert Grammar.failure_grammar?(events), "grammar violated: #{inspect(events)}"

          assert {:error,
                  %SpeechAdapterError{
                    reason: :invalid_request,
                    metadata: %{cause: :invalid_input_chunk}
                  }} = List.last(events)
        end

        test "4. [scripted] an input that raises ends in :input_raised and the caller survives" do
          assert {:ok, stream} =
                   @__allm_speech_input_conformance_adapter__.stream_synthesize_input(
                     SpeechRequest.new(input: ""),
                     Harness.raising_input(),
                     adapter_opts: [speech_script: [{:ok, Harness.audio()}]]
                   )

          events = Enum.to_list(stream)

          assert {:error,
                  %SpeechAdapterError{
                    reason: :invalid_request,
                    metadata: %{cause: :input_raised},
                    cause: %{kind: :error, message: message}
                  }} = List.last(events)

          assert is_binary(message)
          assert Process.alive?(self())
        end

        @tag timeout: 5_000
        test "5. [scripted] an input of only empty chunks ends with :empty_input" do
          assert {:ok, stream} =
                   @__allm_speech_input_conformance_adapter__.stream_synthesize_input(
                     SpeechRequest.new(input: ""),
                     [""],
                     adapter_opts: [speech_script: [{:ok, Harness.audio()}]]
                   )

          events = Enum.to_list(stream)
          assert Grammar.failure_grammar?(events), "grammar violated: #{inspect(events)}"

          assert {:error,
                  %SpeechAdapterError{reason: :invalid_request, metadata: %{cause: :empty_input}}} =
                   List.last(events)
        end

        test "6. [unscripted] a malformed request is rejected synchronously, before any key and before the input is reduced" do
          opts = Keyword.get(unquote(opts), :gate_opts, [])

          assert {:error, %SpeechAdapterError{reason: :invalid_request}} =
                   @__allm_speech_input_conformance_adapter__.stream_synthesize_input(
                     SpeechRequest.new(input: "", format: :bogus),
                     Harness.tattling_input(self()),
                     opts
                   )

          refute_received :reduced
        end
      end
    end
  end
end
