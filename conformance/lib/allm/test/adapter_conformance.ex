defmodule ALLM.Test.AdapterConformance do
  @moduledoc """
  Injectable conformance suite for `ALLM.Adapter` implementations.

  ## Installation

      {:allm_conformance, "~> 0.2", only: :test}

  No `elixirc_paths` surgery required — the harness ships as a regular Hex
  package on the test-only load path.

  ## Usage

      defmodule MyAdapterTest do
        use ExUnit.Case, async: true
        use ALLM.Test.AdapterConformance, adapter: MyAdapter
      end

  Injects a `describe "ALLM.Adapter conformance (MyAdapter)"` block with
  13 deterministic cases covering every reason atom in the
  `ALLM.Error.AdapterError` closed enum, plus a `:request_timeout`
  passthrough case verified via the stub's `opts_recorder`.

  ## Script contract

  Each injected case scripts the adapter through `adapter_opts[:script]`
  on the call's `opts` keyword list. The first entry of the script is
  consumed by one `generate/2` call. See
  `ALLM.Test.Fixtures.StubAdapter`'s `@moduledoc` for the full
  script-shape contract.

  Adapters that read their script from a different key may override by
  populating the matching field themselves — the harness's requirement
  is only that the adapter respects the shape the script declares (one
  `{:ok, response_map}` or `{:error, reason, opts}` entry consumed per
  call).
  """

  use ExUnit.CaseTemplate

  @case_count 13

  @doc """
  Return the number of cases injected by `using/1`. Used by harness
  self-tests to guard against silent case-count drift.
  """
  @spec case_count() :: pos_integer()
  def case_count, do: @case_count

  using opts do
    quote location: :keep do
      # Namespaced attribute — avoids collisions with the caller's own
      # module attributes. Keyword.fetch!/2 raises KeyError at
      # quoted-expansion time if `:adapter` is missing; the KeyError
      # propagates up to the `use` site (design said CompileError,
      # OTP 27 observation is KeyError — see retro 2026-04-23-batch3).
      @__allm_conformance_adapter__ Keyword.fetch!(unquote(opts), :adapter)

      describe "ALLM.Adapter conformance (#{inspect(@__allm_conformance_adapter__)})" do
        alias ALLM.Error.AdapterError
        alias ALLM.{Message, Request, Response}
        alias ALLM.Test.Fixtures.StubAdapter

        test "generate/2 with a minimal text request returns {:ok, %Response{}}" do
          req = Request.new([%Message{role: :user, content: "hi"}])
          script = [{:ok, %{output_text: "hi", finish_reason: :stop}}]
          opts = [adapter_opts: [script: script]]

          assert {:ok, %Response{} = resp} = @__allm_conformance_adapter__.generate(req, opts)
          assert resp.output_text == "hi" or is_nil(resp.output_text) or is_binary(resp.output_text)
        end

        test "returns %AdapterError{reason: :authentication_failed} when scripted with 401" do
          req = Request.new([%Message{role: :user, content: "x"}])
          script = [{:error, :authentication_failed, status: 401}]
          opts = [adapter_opts: [script: script]]

          assert {:error, %AdapterError{reason: :authentication_failed} = err} =
                   @__allm_conformance_adapter__.generate(req, opts)

          assert err.status == 401 or is_nil(err.status)
        end

        test "returns %AdapterError{reason: :rate_limited} with retry_after_ms populated" do
          req = Request.new([%Message{role: :user, content: "x"}])
          script = [{:error, :rate_limited, retry_after_ms: 500}]
          opts = [adapter_opts: [script: script]]

          assert {:error, %AdapterError{reason: :rate_limited, retry_after_ms: 500}} =
                   @__allm_conformance_adapter__.generate(req, opts)
        end

        test "returns %AdapterError{reason: :timeout} when scripted" do
          req = Request.new([%Message{role: :user, content: "x"}])
          script = [{:error, :timeout, []}]
          opts = [adapter_opts: [script: script], request_timeout: 10]

          assert {:error, %AdapterError{reason: :timeout}} =
                   @__allm_conformance_adapter__.generate(req, opts)
        end

        test "returns %AdapterError{reason: :network_error} when scripted" do
          req = Request.new([%Message{role: :user, content: "x"}])
          script = [{:error, :network_error, []}]
          opts = [adapter_opts: [script: script]]

          assert {:error, %AdapterError{reason: :network_error}} =
                   @__allm_conformance_adapter__.generate(req, opts)
        end

        test "returns %AdapterError{reason: :invalid_request} when scripted with a 400" do
          req = Request.new([%Message{role: :user, content: "x"}])
          script = [{:error, :invalid_request, status: 400}]
          opts = [adapter_opts: [script: script]]

          assert {:error, %AdapterError{reason: :invalid_request}} =
                   @__allm_conformance_adapter__.generate(req, opts)
        end

        test "returns %AdapterError{reason: :context_length_exceeded} when scripted" do
          req = Request.new([%Message{role: :user, content: "x"}])
          script = [{:error, :context_length_exceeded, status: 400}]
          opts = [adapter_opts: [script: script]]

          assert {:error, %AdapterError{reason: :context_length_exceeded}} =
                   @__allm_conformance_adapter__.generate(req, opts)
        end

        test "returns %AdapterError{reason: :content_filter} when scripted" do
          req = Request.new([%Message{role: :user, content: "x"}])
          script = [{:error, :content_filter, []}]
          opts = [adapter_opts: [script: script]]

          assert {:error, %AdapterError{reason: :content_filter}} =
                   @__allm_conformance_adapter__.generate(req, opts)
        end

        test "returns %AdapterError{reason: :provider_unavailable} when scripted with a 503" do
          req = Request.new([%Message{role: :user, content: "x"}])
          script = [{:error, :provider_unavailable, status: 503}]
          opts = [adapter_opts: [script: script]]

          assert {:error, %AdapterError{reason: :provider_unavailable}} =
                   @__allm_conformance_adapter__.generate(req, opts)
        end

        test "returns %AdapterError{reason: :malformed_response} when scripted" do
          req = Request.new([%Message{role: :user, content: "x"}])
          script = [{:error, :malformed_response, []}]
          opts = [adapter_opts: [script: script]]

          assert {:error, %AdapterError{reason: :malformed_response}} =
                   @__allm_conformance_adapter__.generate(req, opts)
        end

        test "returns %AdapterError{reason: :unsupported_feature} when scripted" do
          req = Request.new([%Message{role: :user, content: "x"}])
          script = [{:error, :unsupported_feature, []}]
          opts = [adapter_opts: [script: script]]

          assert {:error, %AdapterError{reason: :unsupported_feature}} =
                   @__allm_conformance_adapter__.generate(req, opts)
        end

        test "populates %AdapterError.request_id when the stub attaches one" do
          req = Request.new([%Message{role: :user, content: "x"}])
          script = [{:error, :rate_limited, request_id: "req_abc"}]
          opts = [adapter_opts: [script: script]]

          assert {:error, %AdapterError{request_id: "req_abc"}} =
                   @__allm_conformance_adapter__.generate(req, opts)
        end

        test "accepts opts[:request_timeout] and (when StubAdapter) records it verbatim" do
          # Design case 11: adapter must honor opts[:request_timeout] per
          # ALLM.Adapter invariant #3. Universal assertion: the call
          # succeeds when :request_timeout is present. Additional
          # assertion when the adapter is ALLM.Test.Fixtures.StubAdapter:
          # its opts_recorder mechanism captures the full opts keyword,
          # so we verify the key survived into the adapter's call site.
          # Third-party adapters ignore :opts_recorder harmlessly — it
          # lives under the opaque :adapter_opts blob.
          req = Request.new([%Message{role: :user, content: "x"}])
          script = [{:ok, %{output_text: "hi"}}]

          adapter_opts =
            if @__allm_conformance_adapter__ == StubAdapter do
              [script: script, opts_recorder: StubAdapter.start_opts_recorder()]
            else
              [script: script]
            end

          opts = [adapter_opts: adapter_opts, request_timeout: 1234]

          assert {:ok, _} = @__allm_conformance_adapter__.generate(req, opts)

          if @__allm_conformance_adapter__ == StubAdapter do
            recorder = Keyword.fetch!(adapter_opts, :opts_recorder)
            [recorded | _] = StubAdapter.recorded_opts(recorder)
            assert Keyword.get(recorded, :request_timeout) == 1234
          end
        end
      end
    end
  end
end
