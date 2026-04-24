defmodule ALLM.RunnerTest do
  @moduledoc """
  Sub-phase 5.3 — `ALLM.Runner.run/3` tests. See PHASE_5_DESIGN.md
  lines 740-789 and `lib/allm/runner.ex`.
  """

  use ExUnit.Case, async: true

  alias ALLM.{Engine, Message, Request, Response, Runner}
  alias ALLM.Error.{AdapterError, EngineError, StreamError, ValidationError}
  alias ALLM.Providers.Fake

  doctest Runner

  # ---------------------------------------------------------------------------
  # Test-local adapters — inline, mirror stream_runner_test.exs.
  # ---------------------------------------------------------------------------

  # Implements ALLM.Adapter only (no stream/2). Used to assert the
  # :missing_stream_adapter guard fires.
  defmodule NonStreamAdapter do
    @moduledoc false
    @behaviour ALLM.Adapter

    @impl ALLM.Adapter
    def generate(_request, _opts), do: {:ok, %Response{}}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp req, do: Request.new([%Message{role: :user, content: "hi"}])

  defp fake_engine(script) do
    Engine.new(adapter: Fake, adapter_opts: [script: script])
  end

  # ---------------------------------------------------------------------------
  # Happy path
  # ---------------------------------------------------------------------------

  describe "run/3 — happy path" do
    test "plain-text script returns {:ok, %Response{}} with output_text and finish_reason" do
      engine = fake_engine([{:text, "hi"}, {:finish, :stop}])

      assert {:ok, %Response{output_text: "hi", finish_reason: :stop}} =
               Runner.run(engine, req())
    end

    test "tool-call script produces %Response.tool_calls and finish_reason: :tool_calls" do
      engine =
        fake_engine([
          {:tool_call, id: "c1", name: "weather", arguments: %{"city" => "Paris"}},
          {:finish, :tool_calls}
        ])

      assert {:ok, %Response{tool_calls: tool_calls, finish_reason: :tool_calls}} =
               Runner.run(engine, req())

      assert length(tool_calls) == 1
      assert hd(tool_calls).id == "c1"
      assert hd(tool_calls).name == "weather"
    end

    test "include_raw_chunks: false (default) still folds usage into Response.usage" do
      # Non-obvious Decision #9: the usage carve-out preserves
      # {:raw_chunk, {:usage, _}} regardless of the filter flag.
      engine =
        fake_engine([
          {:usage, %{input_tokens: 5, output_tokens: 2}},
          {:text, "hi"},
          {:finish, :stop}
        ])

      assert {:ok, %Response{usage: usage}} =
               Runner.run(engine, req(), include_raw_chunks: false)

      assert usage.input_tokens == 5
      assert usage.output_tokens == 2
    end

    test "include_raw_chunks: false drops non-usage raw chunks before the collector sees them" do
      # Non-usage raw chunks are filtered; they shouldn't leave side-effects
      # on the response. StreamCollector's :raw_chunk catch-all is a no-op
      # anyway, so the test asserts the "no observable change" invariant: a
      # response built with a debug raw chunk is structurally equivalent to
      # one built without.
      engine_with = fake_engine([{:raw_chunk, "debug"}, {:text, "hi"}, {:finish, :stop}])
      engine_without = fake_engine([{:text, "hi"}, {:finish, :stop}])

      assert {:ok, %Response{} = resp_with} = Runner.run(engine_with, req())
      assert {:ok, %Response{} = resp_without} = Runner.run(engine_without, req())

      # Equal on the user-visible fields. (request_id/metadata may vary by
      # accumulation noise; output_text + finish_reason + usage is enough to
      # prove the raw chunk doesn't flow through.)
      assert resp_with.output_text == resp_without.output_text
      assert resp_with.finish_reason == resp_without.finish_reason
      assert resp_with.usage == resp_without.usage
    end
  end

  # ---------------------------------------------------------------------------
  # Error paths
  # ---------------------------------------------------------------------------

  describe "run/3 — pre-flight error paths" do
    test "nil adapter returns :missing_adapter" do
      engine = Engine.new()
      assert {:error, %EngineError{reason: :missing_adapter}} = Runner.run(engine, req())
    end

    test "adapter without stream/2 returns :missing_stream_adapter" do
      engine = Engine.new(adapter: NonStreamAdapter)

      assert {:error, %EngineError{reason: :missing_stream_adapter}} =
               Runner.run(engine, req())
    end

    test "empty messages returns %ValidationError{reason: :invalid_request}" do
      engine = fake_engine([{:text, "x"}, {:finish, :stop}])
      empty_req = %Request{req() | messages: []}

      assert {:error, %ValidationError{reason: :invalid_request, errors: errors}} =
               Runner.run(engine, empty_req)

      assert {:messages, :empty} in errors
    end

    test "adapter pre-flight error bubbles as AdapterError" do
      engine = fake_engine([{:preflight_error, :authentication_failed, []}])

      assert {:error, %AdapterError{reason: :authentication_failed}} =
               Runner.run(engine, req())
    end
  end

  # ---------------------------------------------------------------------------
  # Mid-stream error mapping (Non-obvious Decision #4)
  # ---------------------------------------------------------------------------

  describe "run/3 — mid-stream error mapping" do
    test "mid-stream {:error, :rate_limited} folds to finish_reason: :error + metadata.error" do
      engine = fake_engine([{:text, "partial"}, {:error, :rate_limited}])

      assert {:ok,
              %Response{
                output_text: "partial",
                finish_reason: :error,
                metadata: %{error: %AdapterError{reason: :rate_limited}}
              }} = Runner.run(engine, req())
    end

    test "mid-stream {:stream_error, :cancelled, _} folds into %StreamError{} on response" do
      # Fake's :stream_error (harness shape) emits
      # {:error, %StreamError{reason: :cancelled}}; we verified this in
      # lib/allm/providers/fake/script.ex:347-348.
      engine = fake_engine([{:stream_error, :cancelled, []}])

      assert {:ok,
              %Response{
                finish_reason: :error,
                metadata: %{error: %StreamError{reason: :cancelled}}
              }} = Runner.run(engine, req())
    end
  end
end
