defmodule ALLM.Test.SpeechAdapterConformance do
  @moduledoc """
  Injectable conformance suite for `ALLM.SpeechAdapter` implementations.

  ## Installation

      {:allm_conformance, "~> 0.3", only: :test}

  ## Usage

      defmodule MySpeechAdapterTest do
        use ExUnit.Case, async: true
        use ALLM.Test.SpeechAdapterConformance, speech_adapter: MySpeechAdapter
      end

  Injects a `describe "ALLM.SpeechAdapter conformance (MySpeechAdapter)"`
  block with 6 deterministic cases.

  ## Script contract

  Cases tagged **[scripted]** drive the adapter through
  `adapter_opts[:speech_script]` with a one-entry script, so a real provider
  adapter never touches the network. See `ALLM.Providers.FakeSpeech`'s
  `script/1` `@doc` for the grammar. Real provider adapters honour the key
  by handing the call to `ALLM.Providers.FakeSpeech.synthesize/2` before any
  of their own gates run.

  Cases tagged **[unscripted]** pass no script and no key, so only the
  adapter's own gates are reached. Gates must fire before
  `ALLM.Keys.fetch!/2`, so a keyless environment observes the rejection
  rather than `%ALLM.Error.EngineError{reason: :missing_key}`.

  ### `:gate_opts`

  Keyless means keyless even in a shell that exports a provider key. The
  `:gate_opts` option (a keyword list, default `[]`) is passed as the
  opts of every [unscripted] case. Pass a plug that fails the request, so a
  gate placed after key resolution fails the case instead of reaching the
  provider:

      use ALLM.Test.SpeechAdapterConformance,
        speech_adapter: MySpeechAdapter,
        gate_opts: [adapter_opts: [plug: fn _conn -> raise "gate let the request reach HTTP" end]]

  ## What this suite does NOT bind

  **Invariant 1 is unbound.** It is enforced at the façade, which raises
  `ArgumentError` on any other return shape; a conformance run cannot observe
  that, and a green run is no evidence that transport, auth, or rate-limit
  failures return the error tuple.

  **Invariants 2 and 3 are bound only for an adapter that implements
  `synthesize/2` itself.** For an adapter whose script short-circuit hands
  off to `ALLM.Providers.FakeSpeech` — the Fake and every bundled provider
  adapter — the scripted cases never reach that adapter's own response
  decoder. Its decoder's conformance is the job of its own fixture tests.

  Invariants 7 and 8 (timeout and `prepare_request/2`) need a live or stubbed
  transport and are not exercised here.

  No case body is gated on a fixture from this package's own test tree: every
  assertion must be reachable for every consumer.

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

  using opts do
    quote location: :keep do
      @__allm_speech_conformance_adapter__ Keyword.fetch!(unquote(opts), :speech_adapter)

      describe "ALLM.SpeechAdapter conformance (#{inspect(@__allm_speech_conformance_adapter__)})" do
        alias ALLM.{Audio, SpeechRequest, SpeechResponse}
        alias ALLM.Error.SpeechAdapterError

        test "1. [scripted] a synthesis returns non-empty binary audio" do
          req = SpeechRequest.new(input: "Hello.")

          assert {:ok, %SpeechResponse{audio: %Audio{source: {:binary, bytes}}}} =
                   @__allm_speech_conformance_adapter__.synthesize(req,
                     adapter_opts: [speech_script: [{:ok, "conformance audio"}]]
                   )

          assert is_binary(bytes)
          assert bytes != ""
        end

        test "2. [scripted] the audio carries a binary mime_type beginning audio/" do
          req = SpeechRequest.new(input: "Hello.")

          assert {:ok, %SpeechResponse{audio: %Audio{mime_type: mime}}} =
                   @__allm_speech_conformance_adapter__.synthesize(req,
                     adapter_opts: [speech_script: [{:ok, "conformance audio"}]]
                   )

          assert is_binary(mime)
          assert String.starts_with?(mime, "audio/")
        end

        test "3. [scripted] response.format is nil or one of SpeechRequest.formats/0" do
          req = SpeechRequest.new(input: "Hello.", format: :wav)

          assert {:ok, %SpeechResponse{format: format}} =
                   @__allm_speech_conformance_adapter__.synthesize(req,
                     adapter_opts: [speech_script: [{:ok, "conformance audio"}]]
                   )

          assert format in [nil | SpeechRequest.formats()]
        end

        test "4. [unscripted] empty input is rejected with :invalid_request before any key" do
          req = SpeechRequest.new(input: "")
          opts = Keyword.get(unquote(opts), :gate_opts, [])

          assert {:error, %SpeechAdapterError{reason: :invalid_request}} =
                   @__allm_speech_conformance_adapter__.synthesize(req, opts)
        end

        test "5. [scripted] preserves opts[:request_id] onto response.request_id" do
          req = SpeechRequest.new(input: "Hello.")

          assert {:ok, %SpeechResponse{request_id: "test-id-123"}} =
                   @__allm_speech_conformance_adapter__.synthesize(req,
                     adapter_opts: [speech_script: [{:ok, "conformance audio"}]],
                     request_id: "test-id-123"
                   )
        end

        test "6. [scripted] round-trips request.metadata onto response.metadata" do
          metadata = %{"k" => "v", trace_id: "abc"}
          req = SpeechRequest.new(input: "Hello.", metadata: metadata)

          assert {:ok, %SpeechResponse{metadata: ^metadata}} =
                   @__allm_speech_conformance_adapter__.synthesize(req,
                     adapter_opts: [speech_script: [{:ok, "conformance audio"}]]
                   )
        end
      end
    end
  end
end
