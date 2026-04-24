defmodule ALLM.Test.StreamAdapterConformance do
  @moduledoc """
  Injectable conformance suite for `ALLM.StreamAdapter` implementations.

  ## Installation

      {:allm_conformance, "~> 0.2", only: :test}

  ## Usage

      defmodule MyStreamAdapterTest do
        use ExUnit.Case, async: true
        use ALLM.Test.StreamAdapterConformance, stream_adapter: MyStreamAdapter
      end

  Injects a `describe "ALLM.StreamAdapter conformance (MyStreamAdapter)"`
  block with 14 deterministic cases:

    1–9. synchronous `{:error, %AdapterError{reason: R}}` pre-flight for
         each spec §20 reason atom that a streaming adapter may surface
         before emitting any event: `:authentication_failed`,
         `:rate_limited`, `:invalid_request`, `:provider_unavailable`,
         `:context_length_exceeded`, `:timeout`, `:network_error`,
         `:malformed_response`, `:unknown`.
    10. plain text stream — 2 `:text_delta` events followed by a
        `:message_completed`.
    11. mid-stream `{:error, %AdapterError{reason: :rate_limited}}` event.
    12. mid-stream `{:error, %StreamError{reason: :cancelled}}` event
        (note: `:cancelled` is in the committed `StreamError` enum; the
        earlier spec's `:truncated` / `:malformed_chunk` /
        `:connection_dropped` atoms are not).
    13. halt-safety: consumer halt triggers the cleanup observer within
        500 ms (`:counters.get(ref, 1) == 1`).
    14. `stream_timeout` opt is accepted (the stub records it in its
        scripted error; the assertion is on the `%AdapterError{reason:
        :timeout}` event shape).

  ## Script contract

  See `ALLM.Test.Fixtures.StubAdapter`'s `@moduledoc` for the event
  spec variants (`:text_delta`, `:finish`, `:error_event`,
  `:stream_error`).
  """

  use ExUnit.CaseTemplate

  @case_count 14

  @doc """
  Return the number of cases injected by `using/1`.
  """
  @spec case_count() :: pos_integer()
  def case_count, do: @case_count

  @doc false
  @spec __allm_conformance_eventually__((-> boolean()), pos_integer()) :: boolean()
  def __allm_conformance_eventually__(fun, timeout_ms) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    eventually_loop(fun, deadline)
  end

  defp eventually_loop(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(10)
        eventually_loop(fun, deadline)
      end
    end
  end

  using opts do
    quote location: :keep do
      @__allm_conformance_stream_adapter__ Keyword.fetch!(
                                             unquote(opts),
                                             :stream_adapter
                                           )

      describe "ALLM.StreamAdapter conformance (#{inspect(@__allm_conformance_stream_adapter__)})" do
        alias ALLM.Error.{AdapterError, StreamError}
        alias ALLM.{Message, Request}

        # Cases 1–9: synchronous {:error, %AdapterError{}} pre-flight for
        # each spec §20 reason atom that a streaming adapter may surface
        # before emitting any event. The atoms are a subset of
        # ALLM.Error.AdapterError.@legal_reasons — specifically the ones
        # that can occur during request preparation / HTTP handshake
        # (i.e., not :content_filter or :unsupported_feature, which
        # surface only after the provider has streamed content).
        for preflight_reason <- [
              :authentication_failed,
              :rate_limited,
              :invalid_request,
              :provider_unavailable,
              :context_length_exceeded,
              :timeout,
              :network_error,
              :malformed_response,
              :unknown
            ] do
          @__allm_conformance_preflight_reason__ preflight_reason

          test "synchronous {:error, %AdapterError{reason: #{inspect(preflight_reason)}}} pre-flight" do
            reason = @__allm_conformance_preflight_reason__
            req = Request.new([%Message{role: :user, content: "x"}])
            script = [{:preflight_error, reason, []}]
            opts = [adapter_opts: [stream_script: script]]

            assert {:error, %AdapterError{reason: ^reason}} =
                     @__allm_conformance_stream_adapter__.stream(req, opts)
          end
        end

        test "streams text_delta+ events followed by message_completed for a plain text script" do
          req = Request.new([%Message{role: :user, content: "x"}])

          script = [
            [
              {:text_delta, "hel"},
              {:text_delta, "lo"},
              {:finish, :stop}
            ]
          ]

          opts = [adapter_opts: [stream_script: script]]

          assert {:ok, stream} = @__allm_conformance_stream_adapter__.stream(req, opts)
          events = Enum.to_list(stream)

          assert Enum.any?(events, &match?({:text_delta, %{delta: "hel"}}, &1))
          assert Enum.any?(events, &match?({:text_delta, %{delta: "lo"}}, &1))
          assert Enum.any?(events, &match?({:message_completed, _}, &1))
        end

        test "streams a mid-stream {:error, %AdapterError{reason: :rate_limited}} event when scripted" do
          req = Request.new([%Message{role: :user, content: "x"}])
          script = [[{:error_event, :rate_limited, [retry_after_ms: 500]}]]
          opts = [adapter_opts: [stream_script: script]]

          assert {:ok, stream} = @__allm_conformance_stream_adapter__.stream(req, opts)
          events = Enum.to_list(stream)

          assert Enum.any?(events, fn
                   {:error, %AdapterError{reason: :rate_limited, retry_after_ms: 500}} -> true
                   _ -> false
                 end)
        end

        test "streams a mid-stream {:error, %StreamError{reason: :cancelled}} event when scripted" do
          # `:cancelled` is a committed atom in ALLM.Error.StreamError's
          # closed enum (:adapter_error | :cancelled | :timeout |
          # :malformed_event | :unknown). The design doc's :truncated /
          # :malformed_chunk / :connection_dropped are not committed.
          req = Request.new([%Message{role: :user, content: "x"}])
          script = [[{:stream_error, :cancelled, []}]]
          opts = [adapter_opts: [stream_script: script]]

          assert {:ok, stream} = @__allm_conformance_stream_adapter__.stream(req, opts)
          events = Enum.to_list(stream)

          assert Enum.any?(events, fn
                   {:error, %StreamError{reason: :cancelled}} -> true
                   _ -> false
                 end)
        end

        test "halt-safety: consumer halt triggers the cleanup observer within 500ms" do
          req = Request.new([%Message{role: :user, content: "x"}])
          ref = :counters.new(1, [:atomics])

          script = [
            [
              {:text_delta, "a"},
              {:text_delta, "b"},
              {:text_delta, "c"},
              {:text_delta, "d"},
              {:finish, :stop}
            ]
          ]

          opts = [adapter_opts: [stream_script: script, cleanup_observer: ref]]

          assert {:ok, stream} = @__allm_conformance_stream_adapter__.stream(req, opts)
          _ = stream |> Enum.take(2)

          # Stream.resource/3's after_fun runs synchronously at halt.
          # :counters is shared memory, visible across async boundaries.
          harness = unquote(__MODULE__)
          assert harness.__allm_conformance_eventually__(fn -> :counters.get(ref, 1) == 1 end, 500)
        end

        test "stream_timeout: mid-stream %AdapterError{reason: :timeout} event is accepted" do
          req = Request.new([%Message{role: :user, content: "x"}])
          script = [[{:error_event, :timeout, []}]]
          opts = [adapter_opts: [stream_script: script], stream_timeout: 100]

          assert {:ok, stream} = @__allm_conformance_stream_adapter__.stream(req, opts)
          events = Enum.to_list(stream)

          assert Enum.any?(events, fn
                   {:error, %AdapterError{reason: :timeout}} -> true
                   _ -> false
                 end)
        end
      end
    end
  end
end
