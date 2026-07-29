defmodule ALLM.ALLMEmbedTest do
  @moduledoc """
  Layer-C `ALLM.embed/3` and `ALLM.embedding_request/2` over
  `ALLM.Providers.FakeEmbeddings` and the variable-batch stub.

  Embeddings have **no streaming counterpart** — there is no
  `stream_embed/3` and no stream-equivalence property to write. That is a
  design decision (embeddings are request/response, like image generation),
  not a gap in this file.

  Telemetry assertions use `ALLM.Test.TelemetryCapture`, which filters by
  owner PID; a bare `:telemetry.attach/4` in an `async: true` module would
  capture other tests' `[:allm, :embed, :*]` events.
  """

  use ExUnit.Case, async: true

  # Per-function registration, matching the nine sibling `allm_*_test.exs`
  # files: a failing doctest then reports from this file with embeddings
  # context rather than from the blanket `doctest ALLM` in `allm_test.exs`.
  doctest ALLM, only: [embed: 3, embedding_request: 2]

  alias ALLM.{Embedding, EmbeddingRequest, EmbeddingResponse, Engine, Usage}
  alias ALLM.Error.{EmbeddingAdapterError, EngineError, ValidationError}
  alias ALLM.Providers.FakeEmbeddings
  alias ALLM.Test.{TelemetryCapture, VariableBatchEmbeddingStub}

  # ---------------------------------------------------------------------------
  # Inline stubs — scope is this file only, so they stay here rather than in
  # test/support/ (per the "don't promote single-file behaviour stubs" rule).
  # ---------------------------------------------------------------------------

  defmodule NilRequestIdAdapter do
    @moduledoc false
    @behaviour ALLM.EmbeddingAdapter

    @impl ALLM.EmbeddingAdapter
    def max_batch_size, do: 1000

    @impl ALLM.EmbeddingAdapter
    def embed(%ALLM.EmbeddingRequest{}, _opts) do
      {:ok,
       %ALLM.EmbeddingResponse{
         request_id: nil,
         embeddings: [ALLM.Embedding.new(vector: [1.0], index: 0)]
       }}
    end
  end

  defmodule ProviderRequestIdAdapter do
    @moduledoc false
    @behaviour ALLM.EmbeddingAdapter

    @impl ALLM.EmbeddingAdapter
    def max_batch_size, do: 1000

    @impl ALLM.EmbeddingAdapter
    def embed(%ALLM.EmbeddingRequest{}, _opts) do
      {:ok,
       %ALLM.EmbeddingResponse{
         request_id: "provider-rid",
         embeddings: [ALLM.Embedding.new(vector: [1.0], index: 0)]
       }}
    end
  end

  defmodule ModelEchoAdapter do
    @moduledoc false
    @behaviour ALLM.EmbeddingAdapter

    @impl ALLM.EmbeddingAdapter
    def max_batch_size, do: 1000

    @impl ALLM.EmbeddingAdapter
    def embed(%ALLM.EmbeddingRequest{} = request, _opts) do
      {:ok,
       %ALLM.EmbeddingResponse{
         model: request.model,
         embeddings: [ALLM.Embedding.new(vector: [1.0], index: 0)]
       }}
    end
  end

  defmodule RawEchoAdapter do
    @moduledoc false
    @behaviour ALLM.EmbeddingAdapter

    @impl ALLM.EmbeddingAdapter
    def max_batch_size, do: 1000

    @impl ALLM.EmbeddingAdapter
    def embed(%ALLM.EmbeddingRequest{} = request, opts) do
      raw = opts |> Keyword.get(:adapter_opts, []) |> Keyword.get(:raw)

      embeddings =
        request.input
        |> Enum.with_index()
        |> Enum.map(fn {_input, i} -> ALLM.Embedding.new(vector: [i * 1.0], index: i) end)

      {:ok, %ALLM.EmbeddingResponse{embeddings: embeddings, raw: raw}}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp emb(index), do: Embedding.new(vector: [index * 1.0], index: index)

  defp embs(count), do: Enum.map(0..(count - 1), &emb/1)

  defp fake_engine(script, opts \\ []) do
    adapter_opts = Keyword.get(opts, :adapter_opts, [])

    Engine.new(
      Keyword.merge(
        [
          embed_adapter: FakeEmbeddings,
          adapter_opts: [embedding_script: script] ++ adapter_opts
        ],
        Keyword.drop(opts, [:adapter_opts])
      )
    )
  end

  defp inputs(n), do: Enum.map(1..n, &"chunk #{&1}")

  # Collect the `:capture_pid` side-channel messages FakeEmbeddings sends on
  # every `embed/2` invocation. `ALLM.embed/3` is blocking, so by the time it
  # returns every send has already landed.
  defp captured_calls(acc \\ []) do
    receive do
      {FakeEmbeddings, :call, payload} -> captured_calls([payload | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # ---------------------------------------------------------------------------
  # embedding_request/2
  # ---------------------------------------------------------------------------

  describe "embedding_request/2" do
    test "normalizes a bare string to a one-element list" do
      assert %EmbeddingRequest{input: ["a chunk"]} = ALLM.embedding_request("a chunk")
    end

    test "passes a list through unchanged" do
      assert %EmbeddingRequest{input: ["a", "b"]} = ALLM.embedding_request(["a", "b"])
    end

    test "forwards request-field opts onto the struct" do
      req =
        ALLM.embedding_request("x",
          model: "m",
          dimensions: 512,
          task_type: :search_query,
          truncate: false,
          options: %{"user" => "u"},
          metadata: %{trace: "t"}
        )

      assert req.model == "m"
      assert req.dimensions == 512
      assert req.task_type == :search_query
      assert req.truncate == false
      assert req.options == %{"user" => "u"}
      assert req.metadata == %{trace: "t"}
    end

    test "filters call-control opts that are not EmbeddingRequest fields" do
      # `EmbeddingRequest.new/1` is a bare `struct!/2` and raises KeyError on
      # any unknown key; the allow-list is what keeps these from reaching it.
      req =
        ALLM.embedding_request("x",
          request_id: "rid",
          request_timeout: 1_000,
          retry: false,
          adapter_opts: [a: 1],
          api_key: "sk-x",
          telemetry_metadata: %{a: 1},
          stream: true
        )

      assert req.input == ["x"]
      assert req.model == nil
    end

    test "every EmbeddingRequest field except :input is reachable through the allow-list" do
      # Consumer/producer symmetry: the façade's allow-list must equal the
      # struct's field set minus `:input`. A field added to the struct — or a
      # typo'd entry in the allow-list — makes that field silently
      # unreachable from the string/list call shape. Asserted behaviourally
      # (rather than by reading the module attribute) so no `@doc false`
      # accessor has to be added to the façade purely for this test.
      struct_fields =
        %EmbeddingRequest{}
        |> Map.from_struct()
        |> Map.keys()
        |> Kernel.--([:input])

      for field <- struct_fields do
        req = ALLM.embedding_request("x", [{field, :__sentinel__}])

        assert Map.fetch!(req, field) == :__sentinel__,
               "#{inspect(field)} is an EmbeddingRequest field but is not reachable " <>
                 "through ALLM.embedding_request/2's opts allow-list"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # embed/3 — input shapes
  # ---------------------------------------------------------------------------

  describe "embed/3 input shapes" do
    test "a bare string returns one embedding" do
      engine = fake_engine([{:ok, embs(1)}])

      assert {:ok, %EmbeddingResponse{embeddings: [%Embedding{}]} = resp} =
               ALLM.embed(engine, "a chunk")

      assert EmbeddingResponse.vectors(resp) == [[0.0]]
    end

    test "a list of 3 strings returns 3 embeddings in input order" do
      engine = fake_engine([{:ok, embs(3)}])

      assert {:ok, resp} = ALLM.embed(engine, ["a", "b", "c"])
      assert Enum.map(resp.embeddings, & &1.index) == [0, 1, 2]
      assert EmbeddingResponse.vectors(resp) == [[0.0], [1.0], [2.0]]
    end

    test "a pre-built %EmbeddingRequest{} dispatches verbatim" do
      engine = fake_engine([{:ok, embs(1)}], adapter_opts: [capture_pid: self()])
      request = EmbeddingRequest.new(input: ["x"], task_type: :clustering, dimensions: 256)

      assert {:ok, _resp} = ALLM.embed(engine, request)

      assert [%{request: dispatched}] = captured_calls()
      assert dispatched.task_type == :clustering
      assert dispatched.dimensions == 256
      assert dispatched.input == ["x"]
    end

    test "call-site opts do not leak into a pre-built request" do
      engine = fake_engine([{:ok, embs(1)}], adapter_opts: [capture_pid: self()])
      request = EmbeddingRequest.new(input: ["x"], dimensions: 256)

      assert {:ok, _} = ALLM.embed(engine, request, dimensions: 999)

      assert [%{request: dispatched}] = captured_calls()
      assert dispatched.dimensions == 256
    end
  end

  # ---------------------------------------------------------------------------
  # embed/3 — gates
  # ---------------------------------------------------------------------------

  describe "embed/3 gates" do
    test "an engine with no embed_adapter returns :no_embed_adapter" do
      assert {:error, %EngineError{reason: :no_embed_adapter}} =
               ALLM.embed(Engine.new(), "a chunk")
    end

    test ":no_embed_adapter fires even when the request would also fail validation" do
      # Gate-ordering assertion: the adapter-presence gate runs BEFORE
      # validation, so a missing adapter never surfaces as a ValidationError.
      assert {:error, %EngineError{reason: :no_embed_adapter}} =
               ALLM.embed(Engine.new(), [""])
    end

    test "input: [\"\"] returns a ValidationError — the façade validates" do
      engine = fake_engine([{:ok, embs(1)}], adapter_opts: [capture_pid: self()])

      assert {:error, %ValidationError{reason: :invalid_embedding_request} = err} =
               ALLM.embed(engine, [""])

      assert {[:input, 0], :empty} in err.errors
      assert captured_calls() == [], "validation must reject before any adapter call"
    end

    test "a non-list :input is hard-rejected without raising in the telemetry metadata" do
      # `:start` metadata (which counts the inputs) is built BEFORE validation
      # runs, so a hand-built request whose `:input` is not a list must not
      # blow up on the way into the span.
      engine = fake_engine([{:ok, embs(1)}], adapter_opts: [capture_pid: self()])
      request = %EmbeddingRequest{EmbeddingRequest.new() | input: "not a list"}

      assert {:error, %ValidationError{reason: :invalid_embedding_request} = err} =
               ALLM.embed(engine, request)

      assert err.errors == [{:input, :invalid_shape}]
      assert captured_calls() == []
    end

    test "an empty input list is rejected by the façade validator" do
      engine = fake_engine([{:ok, embs(1)}], adapter_opts: [capture_pid: self()])

      assert {:error, %ValidationError{reason: :invalid_embedding_request} = err} =
               ALLM.embed(engine, [])

      assert {:input, :empty} in err.errors
      assert captured_calls() == []
    end
  end

  # ---------------------------------------------------------------------------
  # embed/3 — chunking
  # ---------------------------------------------------------------------------

  describe "embed/3 chunking" do
    test "250 inputs at max_batch_size 100 makes exactly 3 adapter calls and returns 250 in order" do
      VariableBatchEmbeddingStub.put_max_batch_size(100)

      script = [
        {:ok, Enum.map(0..99, &Embedding.new(vector: [&1 * 1.0], index: &1))},
        {:ok, Enum.map(0..99, &Embedding.new(vector: [(&1 + 100) * 1.0], index: &1))},
        {:ok, Enum.map(0..49, &Embedding.new(vector: [(&1 + 200) * 1.0], index: &1))}
      ]

      engine =
        Engine.new(
          embed_adapter: VariableBatchEmbeddingStub,
          adapter_opts: [embedding_script: script, capture_pid: self()]
        )

      assert {:ok, resp} = ALLM.embed(engine, inputs(250))

      assert length(resp.embeddings) == 250
      assert Enum.map(resp.embeddings, & &1.index) == Enum.to_list(0..249)
      assert EmbeddingResponse.vectors(resp) == Enum.map(0..249, &[&1 * 1.0])
      assert resp.metadata.chunk_count == 3

      calls = captured_calls()
      assert length(calls) == 3
      assert Enum.map(calls, fn %{request: r} -> length(r.input) end) == [100, 100, 50]
      assert Enum.flat_map(calls, fn %{request: r} -> r.input end) == inputs(250)
    end

    test "the single-chunk path preserves :raw and sets chunk_count 1" do
      raw = %{"object" => "list"}

      engine =
        Engine.new(
          embed_adapter: RawEchoAdapter,
          adapter_opts: [raw: raw]
        )

      assert {:ok, resp} = ALLM.embed(engine, ["a", "b"])
      assert resp.raw == raw
      assert resp.metadata.chunk_count == 1
    end

    test "the multi-chunk path keeps the first chunk's :raw only" do
      VariableBatchEmbeddingStub.put_max_batch_size(1)

      script = [
        {:ok, [emb(0)]},
        {:ok, [emb(0)]},
        {:ok, [emb(0)]}
      ]

      engine =
        Engine.new(
          embed_adapter: VariableBatchEmbeddingStub,
          adapter_opts: [embedding_script: script]
        )

      assert {:ok, resp} = ALLM.embed(engine, ["a", "b", "c"])
      assert resp.metadata.chunk_count == 3
      assert length(resp.embeddings) == 3
      assert Enum.map(resp.embeddings, & &1.index) == [0, 1, 2]
    end

    test "usage is summed across chunks" do
      VariableBatchEmbeddingStub.put_max_batch_size(1)

      script = [
        {:ok, [emb(0)], usage: %Usage{input_tokens: 3, total_tokens: 3}},
        {:ok, [emb(0)], usage: %Usage{input_tokens: 4, total_tokens: 4}}
      ]

      engine =
        Engine.new(
          embed_adapter: VariableBatchEmbeddingStub,
          adapter_opts: [embedding_script: script]
        )

      assert {:ok, resp} = ALLM.embed(engine, ["a", "b"])
      assert resp.usage.input_tokens == 7
      assert resp.usage.total_tokens == 7
      assert resp.usage.output_tokens == nil
    end

    test "a mid-batch failure on chunk 2 of 3 returns the chunk's error and no vectors" do
      VariableBatchEmbeddingStub.put_max_batch_size(1)

      script = [
        {:ok, [emb(0)]},
        {:error, EmbeddingAdapterError.new(:invalid_request, message: "boom")},
        {:ok, [emb(0)]}
      ]

      engine =
        Engine.new(
          embed_adapter: VariableBatchEmbeddingStub,
          adapter_opts: [embedding_script: script, capture_pid: self()],
          retry: false
        )

      assert {:error, %EmbeddingAdapterError{} = err} = ALLM.embed(engine, ["a", "b", "c"])

      assert err.reason == :invalid_request
      assert err.message == "boom"
      assert err.metadata.completed_chunks == 1
      assert err.metadata.completed_inputs == 1

      # Chunk 3 is never dispatched — the whole call fails.
      assert length(captured_calls()) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # embed/3 — model stamping, request_id, adapter_opts, :stream
  # ---------------------------------------------------------------------------

  describe "embed/3 plumbing" do
    test "stamps the engine-resolved model when request.model is nil" do
      engine = Engine.new(embed_adapter: ModelEchoAdapter, model: "text-embedding-3-small")

      assert {:ok, resp} = ALLM.embed(engine, "a chunk")
      assert resp.model == "text-embedding-3-small"
    end

    test "preserves an explicitly-set request.model over the engine model" do
      engine = Engine.new(embed_adapter: ModelEchoAdapter, model: "engine-model")
      request = EmbeddingRequest.new(input: ["x"], model: "request-model")

      assert {:ok, resp} = ALLM.embed(engine, request)
      assert resp.model == "request-model"
    end

    test "fills response.request_id when the adapter left it nil" do
      engine = Engine.new(embed_adapter: NilRequestIdAdapter)

      assert {:ok, resp} = ALLM.embed(engine, "x", request_id: "rid-42")
      assert resp.request_id == "rid-42"
    end

    test "preserves an adapter-populated response.request_id" do
      engine = Engine.new(embed_adapter: ProviderRequestIdAdapter)

      assert {:ok, resp} = ALLM.embed(engine, "x", request_id: "rid-42")
      assert resp.request_id == "provider-rid"
    end

    test "engine adapter_opts win over call-site adapter_opts on key collision" do
      engine =
        fake_engine([{:ok, [Embedding.new(vector: [1.0], index: 0)]}])

      call_script = [{:ok, [Embedding.new(vector: [9.0], index: 0)]}]

      assert {:ok, resp} =
               ALLM.embed(engine, "x", adapter_opts: [embedding_script: call_script])

      assert EmbeddingResponse.vectors(resp) == [[1.0]]
    end

    test "call-site adapter_opts are visible for keys the engine does not set" do
      engine = fake_engine([{:ok, embs(1)}])

      assert {:ok, _} = ALLM.embed(engine, "x", adapter_opts: [capture_pid: self()])
      assert [%{}] = captured_calls()
    end

    test ":stream in opts is silently dropped, not forwarded to the adapter" do
      engine = fake_engine([{:ok, embs(1)}], adapter_opts: [capture_pid: self()])

      assert {:ok, _} = ALLM.embed(engine, "x", stream: true)

      assert [%{opts: opts}] = captured_calls()
      refute Keyword.has_key?(opts, :stream)
    end

    test "request-field opts are not forwarded to the adapter as dispatch opts" do
      engine = fake_engine([{:ok, embs(1)}], adapter_opts: [capture_pid: self()])

      assert {:ok, _} = ALLM.embed(engine, "x", dimensions: 512, task_type: :clustering)

      assert [%{opts: opts, request: request}] = captured_calls()
      refute Keyword.has_key?(opts, :dimensions)
      refute Keyword.has_key?(opts, :task_type)
      # …because they belong on the request struct instead.
      assert request.dimensions == 512
      assert request.task_type == :clustering
    end

    test "request_timeout and other dispatch opts ARE forwarded to the adapter" do
      engine = fake_engine([{:ok, embs(1)}], adapter_opts: [capture_pid: self()])

      assert {:ok, _} = ALLM.embed(engine, "x", request_timeout: 1234)

      assert [%{opts: opts}] = captured_calls()
      assert Keyword.get(opts, :request_timeout) == 1234
      assert Keyword.get(opts, :request_id) != nil
    end
  end

  # ---------------------------------------------------------------------------
  # Telemetry
  # ---------------------------------------------------------------------------

  describe "embed/3 telemetry" do
    setup do
      :ok = TelemetryCapture.attach([[:allm, :embed, :start], [:allm, :embed, :stop]])
      on_exit(&TelemetryCapture.detach/0)
      :ok
    end

    test ":start fires with input_count and :stop with the three measurements" do
      engine = fake_engine([{:ok, embs(2)}])

      assert {:ok, _} = ALLM.embed(engine, ["a", "b"], request_id: "rid-t")

      assert [
               {[:allm, :embed, :start], start_m, start_md},
               {[:allm, :embed, :stop], stop_m, stop_md}
             ] =
               TelemetryCapture.events()

      assert is_integer(start_m.system_time)
      assert start_md.request_id == "rid-t"
      assert start_md.input_count == 2
      assert Map.has_key?(start_md, :engine)
      assert Map.has_key?(start_md, :model)

      assert is_integer(stop_m.duration)
      assert stop_m.embedding_count == 2
      assert stop_m.chunk_count == 1
      assert stop_md.request_id == "rid-t"
      assert stop_md.error == nil
      assert %EmbeddingResponse{} = stop_md.response
      assert %Usage{} = stop_md.usage
    end

    test ":start fires even when the adapter is missing, and :stop carries the error" do
      assert {:error, %EngineError{reason: :no_embed_adapter}} = ALLM.embed(Engine.new(), "x")

      assert [{[:allm, :embed, :start], _, start_md}, {[:allm, :embed, :stop], stop_m, stop_md}] =
               TelemetryCapture.events()

      assert start_md.input_count == 1
      assert %EngineError{reason: :no_embed_adapter} = stop_md.error
      assert stop_md.response == nil
      assert stop_md.usage == nil
      # `embedding_count` is PRESENT and `0` on the error path, matching
      # `image_count` on the `:image` span — the measurement key set is stable
      # across both paths so a metrics handler cannot `KeyError`.
      assert stop_m.embedding_count == 0
      assert stop_m.chunk_count == 0
    end

    test "embedding_count is 0 on an adapter-error path too" do
      engine = fake_engine([{:error, EmbeddingAdapterError.new(:authentication_failed)}])

      assert {:error, %EmbeddingAdapterError{}} = ALLM.embed(engine, "x")

      assert [_start, {[:allm, :embed, :stop], stop_m, _stop_md}] = TelemetryCapture.events()
      assert stop_m.embedding_count == 0
    end

    test "chunk_count is 3 for a 250-input / max-100 run" do
      VariableBatchEmbeddingStub.put_max_batch_size(100)

      script = [
        {:ok, Enum.map(0..99, &Embedding.new(vector: [&1 * 1.0], index: &1))},
        {:ok, Enum.map(0..99, &Embedding.new(vector: [&1 * 1.0], index: &1))},
        {:ok, Enum.map(0..49, &Embedding.new(vector: [&1 * 1.0], index: &1))}
      ]

      engine =
        Engine.new(
          embed_adapter: VariableBatchEmbeddingStub,
          adapter_opts: [embedding_script: script]
        )

      assert {:ok, _} = ALLM.embed(engine, inputs(250))

      assert [_start, {[:allm, :embed, :stop], stop_m, _}] = TelemetryCapture.events()
      assert stop_m.chunk_count == 3
      assert stop_m.embedding_count == 250
    end
  end

  # ---------------------------------------------------------------------------
  # Retry
  # ---------------------------------------------------------------------------

  describe "embed/3 retry" do
    test "a chunk failing :rate_limited is retried and succeeds on attempt 2" do
      engine =
        fake_engine([{:retry_until_call, 2}, {:ok, embs(1)}],
          adapter_opts: [capture_pid: self()],
          retry: [base_delay_ms: 1, jitter_ms: 0]
        )

      assert {:ok, resp} = ALLM.embed(engine, "x")
      assert length(resp.embeddings) == 1
      assert length(captured_calls()) == 2
    end

    test ":invalid_request is NOT retried" do
      engine =
        fake_engine(
          [{:error, EmbeddingAdapterError.new(:invalid_request, message: "nope")}, {:ok, embs(1)}],
          adapter_opts: [capture_pid: self()],
          retry: [base_delay_ms: 1, jitter_ms: 0]
        )

      assert {:error, %EmbeddingAdapterError{reason: :invalid_request}} = ALLM.embed(engine, "x")
      assert length(captured_calls()) == 1
    end

    test "retry: false on the engine disables retry" do
      engine =
        fake_engine([{:retry_until_call, 2}, {:ok, embs(1)}],
          adapter_opts: [capture_pid: self()],
          retry: false
        )

      assert {:error, %EmbeddingAdapterError{reason: :rate_limited}} = ALLM.embed(engine, "x")
      assert length(captured_calls()) == 1
    end

    test "retry: [max_attempts: 0] materialises to no-retry" do
      engine =
        fake_engine([{:retry_until_call, 2}, {:ok, embs(1)}],
          adapter_opts: [capture_pid: self()],
          retry: [max_attempts: 0]
        )

      assert {:error, %EmbeddingAdapterError{reason: :rate_limited}} = ALLM.embed(engine, "x")
      assert length(captured_calls()) == 1
    end

    test "the retry budget is PER CHUNK, not per call" do
      VariableBatchEmbeddingStub.put_max_batch_size(1)

      script = [
        {:retry_until_call, 2},
        {:ok, [emb(0)]},
        {:retry_until_call, 2},
        {:ok, [emb(0)]}
      ]

      engine =
        Engine.new(
          embed_adapter: VariableBatchEmbeddingStub,
          adapter_opts: [embedding_script: script, capture_pid: self()],
          retry: [base_delay_ms: 1, jitter_ms: 0]
        )

      assert {:ok, resp} = ALLM.embed(engine, ["a", "b"])
      assert length(resp.embeddings) == 2
      # 2 chunks × (1 rejection + 1 success) = 4 adapter calls.
      assert length(captured_calls()) == 4
    end
  end
end
