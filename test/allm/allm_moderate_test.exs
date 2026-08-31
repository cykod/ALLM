defmodule ALLM.ALLMModerateTest do
  @moduledoc """
  Layer-C `ALLM.moderate/3` and `ALLM.moderation_request/2` over
  `ALLM.Providers.FakeModeration`.

  Moderation has **no streaming counterpart** — there is no
  `stream_moderate/3` and no stream-equivalence property to write, exactly as
  for images and embeddings. It also has **no transparent chunking**, so there
  is no chunk-count/merge section here; `max_batch_size/0` is the caller's to
  respect (`ALLM.moderate/3`'s "Batching" section).

  Telemetry assertions use `ALLM.Test.TelemetryCapture`, which filters by
  owner PID; a bare `:telemetry.attach/4` in an `async: true` module would
  capture other tests' `[:allm, :moderate, :*]` events.

  **Script arithmetic matters here.** A non-empty `:moderation_script` that
  runs off the end returns `{:error, %ModerationAdapterError{reason: :unknown,
  metadata: %{cause: :moderation_script_exhausted}}}` rather than defaulting to
  a clean verdict, so every test below scripts exactly as many entries as it
  drives calls.
  """

  use ExUnit.Case, async: true

  # Per-function registration, matching the sibling `allm_*_test.exs` files: a
  # failing doctest then reports from this file with moderation context rather
  # than from the blanket `doctest ALLM` in `allm_test.exs`.
  doctest ALLM, only: [moderate: 3, moderation_request: 2]

  alias ALLM.{Engine, ModelRef, ModerationRequest, ModerationResponse, ModerationResult}
  alias ALLM.Error.{EngineError, ModerationAdapterError, ValidationError}
  alias ALLM.Providers.FakeModeration
  alias ALLM.Test.{FakeModerationFixtures, TelemetryCapture}

  # ---------------------------------------------------------------------------
  # Inline stubs — scope is this file only, so they stay here rather than in
  # test/support/ (per the "don't promote single-file behaviour stubs" rule).
  # ---------------------------------------------------------------------------

  defmodule BareMapAdapter do
    @moduledoc false
    @behaviour ALLM.ModerationAdapter

    @impl ALLM.ModerationAdapter
    def max_batch_size, do: 32

    # Deliberately non-conforming: returns the response struct bare rather
    # than in an `{:ok, _}` tuple — `ALLM.ModerationAdapter` invariant 2.
    @impl ALLM.ModerationAdapter
    def moderate(%ALLM.ModerationRequest{}, _opts) do
      %ALLM.ModerationResponse{results: []}
    end
  end

  defmodule NilRequestIdAdapter do
    @moduledoc false
    @behaviour ALLM.ModerationAdapter

    @impl ALLM.ModerationAdapter
    def max_batch_size, do: 32

    @impl ALLM.ModerationAdapter
    def moderate(%ALLM.ModerationRequest{}, _opts) do
      {:ok,
       %ALLM.ModerationResponse{
         request_id: nil,
         results: [ALLM.ModerationResult.new(flagged: false, index: 0)]
       }}
    end
  end

  defmodule ProviderRequestIdAdapter do
    @moduledoc false
    @behaviour ALLM.ModerationAdapter

    @impl ALLM.ModerationAdapter
    def max_batch_size, do: 32

    @impl ALLM.ModerationAdapter
    def moderate(%ALLM.ModerationRequest{}, _opts) do
      {:ok,
       %ALLM.ModerationResponse{
         request_id: "provider-rid",
         results: [ALLM.ModerationResult.new(flagged: false, index: 0)]
       }}
    end
  end

  defmodule ModelEchoAdapter do
    @moduledoc false
    @behaviour ALLM.ModerationAdapter

    @impl ALLM.ModerationAdapter
    def max_batch_size, do: 32

    @impl ALLM.ModerationAdapter
    def moderate(%ALLM.ModerationRequest{} = request, _opts) do
      {:ok,
       %ALLM.ModerationResponse{
         model: request.model,
         results: [ALLM.ModerationResult.new(flagged: false, index: 0)]
       }}
    end
  end

  defmodule RaisingAdapter do
    @moduledoc false
    @behaviour ALLM.ModerationAdapter

    @impl ALLM.ModerationAdapter
    def max_batch_size, do: 32

    @impl ALLM.ModerationAdapter
    def moderate(%ALLM.ModerationRequest{}, _opts), do: raise("boom")
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp clean(index), do: FakeModerationFixtures.clean(index)

  defp cleans(count), do: Enum.map(0..(count - 1), &clean/1)

  defp fake_engine(script, opts \\ []) do
    adapter_opts = Keyword.get(opts, :adapter_opts, [])

    Engine.new(
      Keyword.merge(
        [
          moderation_adapter: FakeModeration,
          adapter_opts: [moderation_script: script] ++ adapter_opts
        ],
        Keyword.drop(opts, [:adapter_opts])
      )
    )
  end

  # Collect the `:capture_pid` side-channel messages FakeModeration sends on
  # every `moderate/2` invocation. `ALLM.moderate/3` is blocking, so by the
  # time it returns every send has already landed.
  defp captured_calls(acc \\ []) do
    receive do
      {FakeModeration, :call, payload} -> captured_calls([payload | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # ---------------------------------------------------------------------------
  # moderation_request/2
  # ---------------------------------------------------------------------------

  describe "moderation_request/2" do
    test "normalizes a bare string to a one-element list" do
      assert ALLM.moderation_request("is this ok?").input == ["is this ok?"]
    end

    test "passes a list through unchanged" do
      assert ALLM.moderation_request(["a", "b"]).input == ["a", "b"]
    end

    test "a list containing an %ImagePart{} produces a multimodal request" do
      # NOT a wrapping test: the input is already a list, so `List.wrap/1` is
      # the identity here (the wrapping arm is bound by the bare-string test
      # above). A BARE `%ImagePart{}` is outside `moderation_request/2`'s
      # `@spec` — `String.t() | [ModerationRequest.item()]` — and is
      # deliberately not a supported call shape.
      part = ALLM.ImagePart.new(ALLM.Image.from_url("https://example.com/cat.png"))

      req = ALLM.moderation_request([part])

      assert req.input == [part]
      assert ModerationRequest.multimodal?(req)
    end

    test "forwards request-field opts onto the struct" do
      req =
        ALLM.moderation_request("x",
          model: "omni-moderation-latest",
          options: %{foo: 1},
          metadata: %{trace: "t"}
        )

      assert req.model == "omni-moderation-latest"
      assert req.options == %{foo: 1}
      assert req.metadata == %{trace: "t"}
    end

    test "filters call-control opts that are not ModerationRequest fields" do
      # `ModerationRequest.new/1` is a bare `struct!/2` and would `KeyError`
      # on any of these; the allow-list is what keeps `moderate/3` able to
      # forward its own opts through this function.
      req =
        ALLM.moderation_request("x",
          request_id: "rid",
          request_timeout: 5_000,
          retry: false,
          adapter_opts: [foo: 1],
          api_key: "sk-nope",
          telemetry_metadata: %{a: 1},
          stream: true,
          totally_unknown: :whatever
        )

      assert req.input == ["x"]
      assert req.model == nil
      assert req.options == %{}
      assert req.metadata == %{}
    end

    test "every ModerationRequest field except :input is reachable through the allow-list" do
      # Consumer/producer symmetry: the façade's allow-list must equal the
      # struct's field set minus `:input`. A field added to the struct — or a
      # typo'd entry in the allow-list — makes that field silently
      # unreachable from the string/list call shape. Asserted behaviourally
      # (rather than by reading the module attribute) so no `@doc false`
      # accessor has to be added to the façade purely for this test, and
      # computed from `Map.keys/1` rather than a hand-copied literal.
      struct_fields =
        %ModerationRequest{}
        |> Map.from_struct()
        |> Map.keys()
        |> Kernel.--([:input])

      for field <- struct_fields do
        req = ALLM.moderation_request("x", [{field, :__sentinel__}])

        assert Map.fetch!(req, field) == :__sentinel__,
               "#{inspect(field)} is a ModerationRequest field but is not reachable " <>
                 "through ALLM.moderation_request/2's opts allow-list"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # moderate/3 — input shapes
  # ---------------------------------------------------------------------------

  describe "moderate/3 input shapes" do
    test "a bare string is wrapped into a one-element batch" do
      engine = fake_engine([{:ok, cleans(1)}], adapter_opts: [capture_pid: self()])

      assert {:ok, %ModerationResponse{results: [%ModerationResult{index: 0}]}} =
               ALLM.moderate(engine, "is this ok?")

      assert [%{request: request}] = captured_calls()
      assert request.input == ["is this ok?"]
    end

    test "a list of binaries dispatches them as one batch" do
      engine = fake_engine([{:ok, cleans(3)}], adapter_opts: [capture_pid: self()])

      assert {:ok, %ModerationResponse{results: results}} =
               ALLM.moderate(engine, ["a", "b", "c"])

      assert Enum.map(results, & &1.index) == [0, 1, 2]
      assert [%{request: request}] = captured_calls()
      assert request.input == ["a", "b", "c"]
    end

    test "a pre-built %ModerationRequest{} dispatches verbatim" do
      engine = fake_engine([{:ok, cleans(2)}], adapter_opts: [capture_pid: self()])
      request = ModerationRequest.new(input: ["a", "b"], metadata: %{trace: "t"})

      assert {:ok, %ModerationResponse{metadata: %{trace: "t"}}} = ALLM.moderate(engine, request)

      assert [%{request: dispatched}] = captured_calls()
      assert dispatched.input == ["a", "b"]
    end

    test "call-site opts are NOT merged onto a pre-built request" do
      engine = fake_engine([{:ok, cleans(1)}], adapter_opts: [capture_pid: self()])
      request = ModerationRequest.new(input: ["a"], metadata: %{from: :request})

      assert {:ok, _} = ALLM.moderate(engine, request, metadata: %{from: :opts})

      assert [%{request: dispatched}] = captured_calls()
      assert dispatched.metadata == %{from: :request}
    end

    test "a multimodal input yields exactly one result at index 0" do
      part = ALLM.ImagePart.new(ALLM.Image.from_url("https://example.com/cat.png"))
      engine = FakeModerationFixtures.engine()

      assert {:ok, %ModerationResponse{results: [%ModerationResult{index: 0}]}} =
               ALLM.moderate(engine, ["look at this", part])
    end
  end

  # ---------------------------------------------------------------------------
  # moderate/3 — gate order
  # ---------------------------------------------------------------------------

  describe "moderate/3 gates" do
    test "an engine with no moderation_adapter returns :no_moderation_adapter" do
      assert {:error, %EngineError{reason: :no_moderation_adapter}} =
               ALLM.moderate(Engine.new(), "x")
    end

    test ":no_moderation_adapter fires even when the request would also fail validation" do
      # Gate 1 precedes gate 2: a missing adapter is an engine problem and
      # must never surface as a request problem.
      assert {:error, %EngineError{reason: :no_moderation_adapter}} =
               ALLM.moderate(Engine.new(), [])
    end

    test "input: [] returns a ValidationError — the façade validates" do
      engine = fake_engine([{:ok, cleans(1)}], adapter_opts: [capture_pid: self()])

      assert {:error, %ValidationError{reason: :invalid_moderation_request} = err} =
               ALLM.moderate(engine, [])

      assert {:input, :empty} in err.errors
      assert captured_calls() == []
    end

    test "input: [\"\"] returns a ValidationError before any adapter call" do
      engine = fake_engine([{:ok, cleans(1)}], adapter_opts: [capture_pid: self()])

      assert {:error, %ValidationError{reason: :invalid_moderation_request}} =
               ALLM.moderate(engine, [""])

      assert captured_calls() == []
    end

    test "a non-list :input is hard-rejected without raising in the telemetry metadata" do
      # `:start` metadata (which counts the inputs AND asks `multimodal?/1`)
      # is built BEFORE validation runs, so a hand-built request whose
      # `:input` is not a list must not blow up on the way into the span.
      engine = fake_engine([{:ok, cleans(1)}], adapter_opts: [capture_pid: self()])
      request = %ModerationRequest{ModerationRequest.new() | input: "not a list"}

      assert {:error, %ValidationError{reason: :invalid_moderation_request} = err} =
               ALLM.moderate(engine, request)

      assert err.errors == [{:input, :invalid_shape}]
      assert captured_calls() == []
    end

    test "gate 3 — Capability.preflight_moderation/2 is wired into the façade" do
      # The one thing a test can prove about a no-op-by-default gate is that
      # it is PLUGGED IN: deleting
      # `:ok <- ALLM.Capability.preflight_moderation(resolved_model, request)`
      # from `do_moderate_body/5`'s `with` must turn this test red.
      #
      # A bare `%ModelRef{}` on the engine needs no `Application.put_env/3`:
      # `test/support/llm_db.ex` is compiled in `:test`, so `catalog_loaded?/0`
      # is true and `LLMDB.model/1` returns a `%ModelRef{}` unchanged
      # (its identity clause). The file therefore stays `async: true` and
      # introduces no process-global mutation — deliberately NOT the
      # `:force_capability_absent` env override, which is a documented
      # `async: true` foot-gun.
      ref =
        ModelRef.new(
          provider: :local,
          id: "no-moderation",
          capabilities: %{moderation_enabled: false}
        )

      engine =
        fake_engine([{:ok, cleans(1)}], model: ref, adapter_opts: [capture_pid: self()])

      assert {:error, %ValidationError{reason: :unsupported_capability, errors: errors}} =
               ALLM.moderate(engine, "hello")

      assert {[:moderation_enabled], :moderation_disabled} in errors
      # Rejected locally — the request never reached the adapter.
      assert captured_calls() == []
    end

    test "gate 2 precedes gate 3 — validation wins over the capability gate" do
      ref =
        ModelRef.new(
          provider: :local,
          id: "no-moderation",
          capabilities: %{moderation_enabled: false}
        )

      engine =
        fake_engine([{:ok, cleans(1)}], model: ref, adapter_opts: [capture_pid: self()])

      # Both gate 2 and gate 3 would reject; the `with` runs validation first.
      assert {:error, %ValidationError{reason: :invalid_moderation_request}} =
               ALLM.moderate(engine, [])

      assert captured_calls() == []
    end
  end

  # ---------------------------------------------------------------------------
  # moderate/3 — plumbing
  # ---------------------------------------------------------------------------

  describe "moderate/3 plumbing" do
    test "stamps the engine-resolved model when request.model is nil" do
      engine = Engine.new(moderation_adapter: ModelEchoAdapter, model: "engine-model")

      assert {:ok, %ModerationResponse{model: "engine-model"}} = ALLM.moderate(engine, "x")
    end

    test "preserves an explicitly-set request.model over the engine model" do
      engine = Engine.new(moderation_adapter: ModelEchoAdapter, model: "engine-model")
      request = ModerationRequest.new(input: ["x"], model: "explicit-model")

      assert {:ok, %ModerationResponse{model: "explicit-model"}} = ALLM.moderate(engine, request)
    end

    test "fills response.request_id when the adapter left it nil" do
      engine = Engine.new(moderation_adapter: NilRequestIdAdapter)

      assert {:ok, %ModerationResponse{request_id: "rid-fill"}} =
               ALLM.moderate(engine, "x", request_id: "rid-fill")
    end

    test "preserves an adapter-populated response.request_id" do
      engine = Engine.new(moderation_adapter: ProviderRequestIdAdapter)

      assert {:ok, %ModerationResponse{request_id: "provider-rid"}} =
               ALLM.moderate(engine, "x", request_id: "rid-fill")
    end

    test "opts[:request_id] wins over the auto-generated id and reaches the adapter" do
      engine = fake_engine([{:ok, cleans(1)}], adapter_opts: [capture_pid: self()])

      assert {:ok, %ModerationResponse{request_id: "rid-explicit"}} =
               ALLM.moderate(engine, "x", request_id: "rid-explicit")

      assert [%{opts: opts}] = captured_calls()
      assert Keyword.get(opts, :request_id) == "rid-explicit"
    end

    test "engine adapter_opts win over call-site adapter_opts on key collision" do
      # `engine.adapter_opts ++ call_site` with `Keyword.get/2` first-wins —
      # NOT `Keyword.merge/2`, which would have the opposite precedence.
      engine = fake_engine([{:ok, cleans(1)}], adapter_opts: [capture_pid: self(), tag: :engine])

      assert {:ok, _} = ALLM.moderate(engine, "x", adapter_opts: [tag: :call_site])

      assert [%{opts: opts}] = captured_calls()
      assert opts |> Keyword.fetch!(:adapter_opts) |> Keyword.get(:tag) == :engine
    end

    test "call-site adapter_opts are visible for keys the engine does not set" do
      engine = fake_engine([{:ok, cleans(1)}], adapter_opts: [capture_pid: self()])

      assert {:ok, _} = ALLM.moderate(engine, "x", adapter_opts: [extra: :from_call])

      assert [%{opts: opts}] = captured_calls()
      assert opts |> Keyword.fetch!(:adapter_opts) |> Keyword.get(:extra) == :from_call
    end

    test "the engine's :id is injected as adapter_opts[:cursor_key]" do
      # Without this injection FakeModeration's documented cursor-precedence
      # source 2 never fires at the façade, every façade-driven script falls
      # back to `:erlang.phash2(script)`, and two content-equal engines
      # silently share one cursor slot AND one retry budget.
      engine =
        fake_engine([{:ok, cleans(1)}], id: 987_654, adapter_opts: [capture_pid: self()])

      assert {:ok, _} = ALLM.moderate(engine, "x")

      assert [%{opts: opts}] = captured_calls()
      assert opts |> Keyword.fetch!(:adapter_opts) |> Keyword.get(:cursor_key) == 987_654
    end

    test "two content-equal-script engines with distinct :id values do not share a cursor" do
      # The observable consequence of the injection above: engine B must read
      # its own index 0, not engine A's advanced cursor.
      script = [{:flagged, ["violence"]}, {:ok, [clean(0)]}]
      a = fake_engine(script, id: 111_111)
      b = fake_engine(script, id: 222_222)

      assert {:ok, first} = ALLM.moderate(a, "x")
      assert ModerationResponse.flagged?(first)

      assert {:ok, second} = ALLM.moderate(b, "x")
      assert ModerationResponse.flagged?(second)
    end

    test "a caller-supplied adapter_opts[:cursor_key] wins over the engine :id" do
      engine =
        fake_engine([{:ok, cleans(1)}],
          id: 987_654,
          adapter_opts: [capture_pid: self(), cursor_key: "caller-key"]
        )

      assert {:ok, _} = ALLM.moderate(engine, "x")

      assert [%{opts: opts}] = captured_calls()
      assert opts |> Keyword.fetch!(:adapter_opts) |> Keyword.get(:cursor_key) == "caller-key"
    end

    test "stream: true is silently dropped and does not error" do
      engine = fake_engine([{:ok, cleans(1)}], adapter_opts: [capture_pid: self()])

      assert {:ok, _} = ALLM.moderate(engine, "x", stream: true)

      assert [%{opts: opts}] = captured_calls()
      refute Keyword.has_key?(opts, :stream)
    end

    test "request-field opts are not forwarded to the adapter as dispatch opts" do
      engine = fake_engine([{:ok, cleans(1)}], adapter_opts: [capture_pid: self()])

      assert {:ok, _} =
               ALLM.moderate(engine, "x", model: "omni-moderation-latest", metadata: %{t: 1})

      assert [%{opts: opts, request: request}] = captured_calls()
      refute Keyword.has_key?(opts, :model)
      refute Keyword.has_key?(opts, :metadata)
      # …because they belong on the request struct instead.
      assert request.model == "omni-moderation-latest"
      assert request.metadata == %{t: 1}
    end

    test "an unknown opt is forwarded to the adapter untouched" do
      engine = fake_engine([{:ok, cleans(1)}], adapter_opts: [capture_pid: self()])

      assert {:ok, _} = ALLM.moderate(engine, "x", request_timeout: 1234, provider_knob: :on)

      assert [%{opts: opts}] = captured_calls()
      assert Keyword.get(opts, :request_timeout) == 1234
      assert Keyword.get(opts, :provider_knob) == :on
      assert Keyword.get(opts, :request_id) != nil
    end

    test "no :retry_policy key leaks into the adapter's dispatch opts" do
      # Unlike the embeddings façade, there is no batcher downstream to read
      # it — the `Retry.run/3` wrap lives in `do_moderate_body/5` itself, so
      # putting the policy in the opts would leak an unread key into every
      # adapter call.
      engine = fake_engine([{:ok, cleans(1)}], adapter_opts: [capture_pid: self()])

      assert {:ok, _} = ALLM.moderate(engine, "x")

      assert [%{opts: opts}] = captured_calls()
      refute Keyword.has_key?(opts, :retry_policy)
    end
  end

  # ---------------------------------------------------------------------------
  # moderate/3 — retry and invariant enforcement
  # ---------------------------------------------------------------------------

  describe "moderate/3 retry" do
    test "a :rate_limited error retries and then succeeds" do
      engine =
        FakeModerationFixtures.engine(FakeModerationFixtures.retry_until_call(2, ["violence"]))

      assert {:ok, resp} = ALLM.moderate(engine, "x")
      assert ModerationResponse.flagged_categories(resp) == ["violence"]
    end

    test ":invalid_request is NOT retried" do
      err = ModerationAdapterError.new(:invalid_request, message: "nope")
      engine = fake_engine([{:error, err}], adapter_opts: [capture_pid: self()])

      assert {:error, %ModerationAdapterError{reason: :invalid_request}} =
               ALLM.moderate(engine, "x")

      assert length(captured_calls()) == 1
    end

    test "retry: false on the engine disables retry for a retryable reason" do
      err = ModerationAdapterError.new(:rate_limited, retry_after_ms: 0)
      engine = fake_engine([{:error, err}], retry: false, adapter_opts: [capture_pid: self()])

      assert {:error, %ModerationAdapterError{reason: :rate_limited}} = ALLM.moderate(engine, "x")
      assert length(captured_calls()) == 1
    end

    test "an adapter returning a bare map raises ArgumentError naming the adapter and invariant 2" do
      # `ALLM.ModerationAdapter` invariant 2 is deliberately unbound by the
      # conformance suite — this raise is the only thing that enforces it.
      engine = Engine.new(moderation_adapter: BareMapAdapter)

      assert_raise ArgumentError, ~r/BareMapAdapter.*invariant 2/s, fn ->
        ALLM.moderate(engine, "x")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Telemetry
  # ---------------------------------------------------------------------------

  describe "moderate/3 telemetry" do
    setup do
      :ok =
        TelemetryCapture.attach([
          [:allm, :moderate, :start],
          [:allm, :moderate, :stop],
          [:allm, :moderate, :exception]
        ])

      on_exit(&TelemetryCapture.detach/0)
      :ok
    end

    test ":stop measurements carry result_count and flagged_count on success" do
      engine = fake_engine([{:flagged, ["violence"]}])

      assert {:ok, _} = ALLM.moderate(engine, "x", request_id: "rid-t")

      assert [
               {[:allm, :moderate, :start], start_m, start_md},
               {[:allm, :moderate, :stop], stop_m, stop_md}
             ] = TelemetryCapture.events()

      assert is_integer(start_m.system_time)
      assert start_md.request_id == "rid-t"
      assert start_md.input_count == 1
      assert start_md.multimodal == false
      assert Map.has_key?(start_md, :engine)
      assert Map.has_key?(start_md, :model)

      assert is_integer(stop_m.duration)
      assert stop_m.result_count == 1
      assert stop_m.flagged_count == 1
      assert stop_md.error == nil
      assert %ModerationResponse{} = stop_md.response
    end

    test "flagged_count counts only the flagged results in a mixed batch" do
      engine =
        fake_engine([
          {:ok,
           [
             clean(0),
             ModerationResult.new(flagged: true, index: 1),
             clean(2)
           ]}
        ])

      assert {:ok, _} = ALLM.moderate(engine, ["a", "b", "c"])

      assert [_start, {[:allm, :moderate, :stop], stop_m, _}] = TelemetryCapture.events()
      assert stop_m.result_count == 3
      assert stop_m.flagged_count == 1
    end

    test ":start fires even when the adapter is missing, and :stop carries the error" do
      assert {:error, %EngineError{reason: :no_moderation_adapter}} =
               ALLM.moderate(Engine.new(), "x")

      assert [
               {[:allm, :moderate, :start], _, start_md},
               {[:allm, :moderate, :stop], stop_m, stop_md}
             ] = TelemetryCapture.events()

      assert start_md.input_count == 1
      assert start_md.multimodal == false
      assert %EngineError{reason: :no_moderation_adapter} = stop_md.error
      assert stop_md.response == nil
      # Both measurements are PRESENT and `0` on the error path — a stable
      # measurement key set across capability spans is what a metrics backend
      # wants, so a handler cannot `KeyError`.
      assert stop_m.result_count == 0
      assert stop_m.flagged_count == 0
    end

    test ":stop metadata carries usage: nil on BOTH paths" do
      # `%ModerationResponse{}` has no `:usage` field — the endpoint is free —
      # but the span metadata carries the key unconditionally so a handler
      # written against `[:allm, :embed, :stop]` does not `KeyError`.
      ok_engine = fake_engine([{:ok, cleans(1)}])
      assert {:ok, _} = ALLM.moderate(ok_engine, "x")

      assert {:error, _} = ALLM.moderate(Engine.new(), "x")

      stops =
        for {[:allm, :moderate, :stop], _m, md} <- TelemetryCapture.events(), do: md

      assert length(stops) == 2
      assert Enum.all?(stops, &(Map.fetch!(&1, :usage) == nil))
    end

    test ":start fires with a non-list :input without raising" do
      engine = fake_engine([{:ok, cleans(1)}])
      request = %ModerationRequest{ModerationRequest.new() | input: 42}

      assert {:error, %ValidationError{}} = ALLM.moderate(engine, request)

      assert [{[:allm, :moderate, :start], _, start_md} | _] = TelemetryCapture.events()
      assert start_md.input_count == 0
      assert start_md.multimodal == false
    end

    test ":start carries multimodal: true for an %ImagePart{}-bearing input" do
      part = ALLM.ImagePart.new(ALLM.Image.from_url("https://example.com/cat.png"))
      engine = fake_engine([{:ok, [clean(0)]}])

      assert {:ok, _} = ALLM.moderate(engine, ["look at this", part])

      assert [{[:allm, :moderate, :start], _, start_md} | _] = TelemetryCapture.events()
      assert start_md.multimodal == true
      # The item count is 1 for a multimodal request even though the list has
      # two elements — `input_count` reports raw list length, which is why the
      # `multimodal` flag rides alongside it.
      assert start_md.input_count == 2
    end

    test ":exception fires when the adapter raises" do
      engine = Engine.new(moderation_adapter: RaisingAdapter)

      assert_raise RuntimeError, "boom", fn -> ALLM.moderate(engine, "x") end

      assert [{[:allm, :moderate, :start], _, _}, {[:allm, :moderate, :exception], _, md}] =
               TelemetryCapture.events()

      assert md.kind == :error
      assert %RuntimeError{message: "boom"} = md.reason
    end
  end
end
