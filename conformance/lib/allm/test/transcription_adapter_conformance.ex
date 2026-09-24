defmodule ALLM.Test.TranscriptionAdapterConformance do
  @moduledoc """
  Injectable conformance suite for `ALLM.TranscriptionAdapter`
  implementations.

  ## Installation

      {:allm_conformance, "~> 0.3", only: :test}

  ## Usage

      defmodule MyTranscriptionAdapterTest do
        use ExUnit.Case, async: true

        use ALLM.Test.TranscriptionAdapterConformance,
          transcription_adapter: MyTranscriptionAdapter
      end

  Injects a
  `describe "ALLM.TranscriptionAdapter conformance (MyTranscriptionAdapter)"`
  block with 6 deterministic cases.

  ## Script contract

  Cases tagged **[scripted]** drive the adapter through
  `adapter_opts[:transcription_script]` with a one-entry script, so a real
  provider adapter never touches the network. See
  `ALLM.Providers.FakeTranscription`'s `script/1` `@doc` for the grammar.
  Real provider adapters honour the key by handing the call to
  `ALLM.Providers.FakeTranscription.transcribe/2` before any of their own
  gates run, passing their own `max_audio_bytes/0` as
  `adapter_opts[:max_audio_bytes]`. The scripted clip is at most 512 bytes,
  under the Fake's 1024-byte default either way.

  Cases tagged **[unscripted]** pass no script and no key, so only the
  adapter's own gates are reached. Gates must fire before
  `ALLM.Keys.fetch!/2`, so a keyless environment observes the rejection.

  ### `:gate_opts`

  Keyless means keyless even in a shell that exports a provider key. The
  `:gate_opts` option (a keyword list, default `[]`) is passed as the
  opts of every [unscripted] case that calls `transcribe/2`. Pass a plug that
  fails the request, so a gate placed after key resolution fails the case
  instead of uploading the oversized clip:

      use ALLM.Test.TranscriptionAdapterConformance,
        transcription_adapter: MyTranscriptionAdapter,
        gate_opts: [adapter_opts: [plug: fn _conn -> raise "gate let the request reach HTTP" end]]

  ## Sizing

  Case 4 sizes its oversized clip from the adapter's own `max_audio_bytes/0`,
  never from a literal, so it stays correct for any cap. For a real adapter
  that means allocating a clip of provider size (tens of megabytes) once per
  run.

  ## What this suite does NOT bind

  **Invariant 1 is unbound.** It is enforced at the façade, which raises
  `ArgumentError` on any other return shape.

  **Invariant 2 is bound only for an adapter that implements `transcribe/2`
  itself.** For an adapter whose script short-circuit hands off to
  `ALLM.Providers.FakeTranscription` — the Fake and every bundled provider
  adapter — case 2 never reaches that adapter's own response decoder. Its
  decoder's conformance is the job of its own fixture tests.

  Invariants 8 and 9 (timeout and `prepare_request/2`) need a live or stubbed
  transport and are not exercised here. MIME acceptance is adapter-specific
  and not a behaviour invariant; every case uses `audio/mpeg`, so an
  adapter's MIME gate never pre-empts the metadata cases 3 and 4 assert.

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

  @doc false
  @spec clip_bytes(non_neg_integer()) :: binary()
  def clip_bytes(n) when is_integer(n) and n >= 0, do: :binary.copy(<<0>>, n)

  using opts do
    quote location: :keep do
      @__allm_transcription_conformance_adapter__ Keyword.fetch!(
                                                    unquote(opts),
                                                    :transcription_adapter
                                                  )

      describe "ALLM.TranscriptionAdapter conformance (#{inspect(@__allm_transcription_conformance_adapter__)})" do
        alias ALLM.{Audio, TranscriptionRequest, TranscriptionResponse, Usage}
        alias ALLM.Error.TranscriptionAdapterError
        alias ALLM.Test.TranscriptionAdapterConformance, as: Harness

        test "1. [unscripted] max_audio_bytes/0 returns a pos_integer" do
          max = @__allm_transcription_conformance_adapter__.max_audio_bytes()
          assert is_integer(max)
          assert max > 0
        end

        test "2. [scripted] a small clip returns binary text and %Usage{} usage" do
          audio = Audio.from_binary(Harness.clip_bytes(512), "audio/mpeg")
          req = TranscriptionRequest.new(audio: audio)

          assert {:ok, %TranscriptionResponse{text: text, usage: %Usage{}}} =
                   @__allm_transcription_conformance_adapter__.transcribe(req,
                     adapter_opts: [transcription_script: [{:ok, "conformance transcript"}]]
                   )

          assert is_binary(text)
        end

        test "3. [unscripted] unresolvable audio is rejected with :invalid_request before any key" do
          req = TranscriptionRequest.new(audio: Audio.from_file("/nonexistent.mp3"))
          opts = Keyword.get(unquote(opts), :gate_opts, [])

          assert {:error, %TranscriptionAdapterError{reason: :invalid_request}} =
                   @__allm_transcription_conformance_adapter__.transcribe(req, opts)
        end

        test "4. [unscripted] audio over max_audio_bytes/0 is rejected with count and max" do
          adapter = @__allm_transcription_conformance_adapter__
          max = adapter.max_audio_bytes()
          audio = Audio.from_binary(Harness.clip_bytes(max + 1), "audio/mpeg")
          req = TranscriptionRequest.new(audio: audio)
          opts = Keyword.get(unquote(opts), :gate_opts, [])

          assert {:error, %TranscriptionAdapterError{reason: :invalid_request, metadata: meta}} =
                   adapter.transcribe(req, opts)

          assert meta.count == max + 1
          assert meta.max == max
        end

        test "5. [scripted] preserves opts[:request_id] onto response.request_id" do
          audio = Audio.from_binary(Harness.clip_bytes(16), "audio/mpeg")
          req = TranscriptionRequest.new(audio: audio)

          assert {:ok, %TranscriptionResponse{request_id: "test-id-123"}} =
                   @__allm_transcription_conformance_adapter__.transcribe(req,
                     adapter_opts: [transcription_script: [{:ok, "conformance transcript"}]],
                     request_id: "test-id-123"
                   )
        end

        test "6. [scripted] round-trips request.metadata onto response.metadata" do
          metadata = %{"k" => "v", trace_id: "abc"}
          audio = Audio.from_binary(Harness.clip_bytes(16), "audio/mpeg")
          req = TranscriptionRequest.new(audio: audio, metadata: metadata)

          assert {:ok, %TranscriptionResponse{metadata: ^metadata}} =
                   @__allm_transcription_conformance_adapter__.transcribe(req,
                     adapter_opts: [transcription_script: [{:ok, "conformance transcript"}]]
                   )
        end
      end
    end
  end
end
