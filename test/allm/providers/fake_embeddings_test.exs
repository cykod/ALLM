defmodule ALLM.Providers.FakeEmbeddingsTest do
  use ExUnit.Case, async: true

  alias ALLM.{Embedding, EmbeddingRequest, EmbeddingResponse, Usage}
  alias ALLM.Error.EmbeddingAdapterError
  alias ALLM.Providers.FakeEmbeddings
  alias ALLM.Test.FakeEmbeddingFixtures, as: Fixtures

  doctest FakeEmbeddings

  defp request(opts \\ []), do: EmbeddingRequest.new(Keyword.put_new(opts, :input, ["x"]))

  describe "max_batch_size/0" do
    test "returns a positive integer" do
      assert is_integer(FakeEmbeddings.max_batch_size())
      assert FakeEmbeddings.max_batch_size() > 0
    end

    test "returns 2048" do
      assert FakeEmbeddings.max_batch_size() == 2048
    end
  end

  describe "embed/2 scripted results" do
    test "returns the scripted embeddings verbatim" do
      opts = [adapter_opts: Fixtures.batch(3)]
      req = request(input: ["a", "b", "c"])

      assert {:ok, %EmbeddingResponse{embeddings: embeddings}} = FakeEmbeddings.embed(req, opts)
      assert length(embeddings) == 3
      assert Enum.map(embeddings, & &1.index) == [0, 1, 2]
    end

    test "returns scripted vectors in order across successive calls" do
      cursor = FakeEmbeddings.start_script_cursor()

      script = [
        {:ok, [Embedding.new(vector: [1.0], index: 0)]},
        {:ok, [Embedding.new(vector: [2.0], index: 0)]}
      ]

      opts = [adapter_opts: [embedding_script: script, script_cursor: cursor]]

      assert {:ok, first} = FakeEmbeddings.embed(request(), opts)
      assert {:ok, second} = FakeEmbeddings.embed(request(), opts)

      assert EmbeddingResponse.vectors(first) == [[1.0]]
      assert EmbeddingResponse.vectors(second) == [[2.0]]
      assert FakeEmbeddings.cursor_index(cursor) == 2
    end

    test "usage defaults to %ALLM.Usage{} when the script supplies none" do
      opts = [adapter_opts: Fixtures.single()]

      assert {:ok, %EmbeddingResponse{usage: %Usage{} = usage}} =
               FakeEmbeddings.embed(request(), opts)

      assert usage == %Usage{}
    end

    test "a script-supplied usage is returned verbatim" do
      opts = [adapter_opts: Fixtures.batch_with_usage(2, 42)]
      req = request(input: ["a", "b"])

      assert {:ok, %EmbeddingResponse{usage: usage}} = FakeEmbeddings.embed(req, opts)
      assert usage.input_tokens == 42
      assert usage.total_tokens == 42
      assert usage.output_tokens == nil
    end

    test "propagates request_id, model, and metadata onto the response" do
      opts = [adapter_opts: Fixtures.single(), request_id: "rid-9"]
      req = request(model: "text-embedding-3-small", metadata: %{trace: "t"})

      assert {:ok, resp} = FakeEmbeddings.embed(req, opts)
      assert resp.request_id == "rid-9"
      assert resp.model == "text-embedding-3-small"
      assert resp.metadata == %{trace: "t"}
    end

    test "a scripted {:error, %EmbeddingAdapterError{}} entry is returned verbatim" do
      opts = [adapter_opts: Fixtures.rate_limited()]

      assert {:error, %EmbeddingAdapterError{} = err} = FakeEmbeddings.embed(request(), opts)
      assert err.reason == :rate_limited
      assert err.provider == :fake
      assert err.retry_after_ms == 250
    end

    test "exhausting the script returns :unknown / :no_scripted_embedding" do
      opts = [adapter_opts: Fixtures.exhausted_script()]

      assert {:error, %EmbeddingAdapterError{reason: :unknown, metadata: meta}} =
               FakeEmbeddings.embed(request(), opts)

      assert meta.cause == :no_scripted_embedding
    end

    test "running past the end of a non-empty script exhausts too" do
      cursor = FakeEmbeddings.start_script_cursor()
      opts = [adapter_opts: Fixtures.single() ++ [script_cursor: cursor]]

      assert {:ok, _} = FakeEmbeddings.embed(request(), opts)

      assert {:error, %EmbeddingAdapterError{reason: :unknown}} =
               FakeEmbeddings.embed(request(), opts)
    end

    test "a call with no :embedding_script at all exhausts immediately" do
      assert {:error, %EmbeddingAdapterError{reason: :unknown}} =
               FakeEmbeddings.embed(request(), [])
    end
  end

  describe "embed/2 gates" do
    test "input: [] is rejected with :invalid_request before the script is consulted" do
      opts = [adapter_opts: Fixtures.single()]

      assert {:error, %EmbeddingAdapterError{reason: :invalid_request, metadata: meta}} =
               FakeEmbeddings.embed(EmbeddingRequest.new(input: []), opts)

      assert meta.field == :input
    end

    test "input longer than max_batch_size is rejected with :batch_too_large" do
      max = FakeEmbeddings.max_batch_size()
      req = EmbeddingRequest.new(input: for(i <- 1..(max + 1), do: "chunk #{i}"))
      opts = [adapter_opts: Fixtures.single()]

      assert {:error, %EmbeddingAdapterError{reason: :batch_too_large, metadata: meta}} =
               FakeEmbeddings.embed(req, opts)

      assert meta.count == max + 1
      assert meta.max == max
    end

    test "input exactly at max_batch_size passes the gate" do
      max = FakeEmbeddings.max_batch_size()
      req = EmbeddingRequest.new(input: for(i <- 1..max, do: "chunk #{i}"))
      opts = [adapter_opts: Fixtures.single()]

      assert {:ok, %EmbeddingResponse{}} = FakeEmbeddings.embed(req, opts)
    end
  end

  describe "cursor precedence" do
    test "honors adapter_opts[:cursor_key] so two content-equal scripts do not share a cursor" do
      script = Fixtures.two_calls(1)[:embedding_script]

      a = [adapter_opts: [embedding_script: script, cursor_key: 1]]
      b = [adapter_opts: [embedding_script: script, cursor_key: 2]]

      assert {:ok, _} = FakeEmbeddings.embed(request(), a)
      assert {:ok, _} = FakeEmbeddings.embed(request(), b)

      # Each key has its own cursor, so both calls read entry 0. A shared
      # cursor would have advanced b's read to entry 1.
      assert {:ok, _} = FakeEmbeddings.embed(request(), a)
      assert {:ok, _} = FakeEmbeddings.embed(request(), b)

      assert {:error, %EmbeddingAdapterError{reason: :unknown}} =
               FakeEmbeddings.embed(request(), a)
    end

    test "content-equal scripts with no cursor_key DO share the phash2 cursor" do
      script = Fixtures.two_calls(1)[:embedding_script]
      opts = [adapter_opts: [embedding_script: script]]

      assert {:ok, _} = FakeEmbeddings.embed(request(), opts)
      assert {:ok, _} = FakeEmbeddings.embed(request(), opts)

      assert {:error, %EmbeddingAdapterError{reason: :unknown}} =
               FakeEmbeddings.embed(request(), opts)
    end

    test "an explicit :script_cursor Agent pid outranks :cursor_key" do
      cursor = FakeEmbeddings.start_script_cursor()
      script = Fixtures.two_calls(1)[:embedding_script]
      opts = [adapter_opts: [embedding_script: script, cursor_key: 7, script_cursor: cursor]]

      assert {:ok, _} = FakeEmbeddings.embed(request(), opts)
      assert {:ok, _} = FakeEmbeddings.embed(request(), opts)
      assert FakeEmbeddings.cursor_index(cursor) == 2
    end

    test "start_script_cursor/0 starts at 0" do
      assert FakeEmbeddings.cursor_index(FakeEmbeddings.start_script_cursor()) == 0
    end
  end

  describe "capture_pid seam" do
    test "sends the request to :capture_pid before any gate" do
      req = EmbeddingRequest.new(input: [])
      opts = [adapter_opts: [embedding_script: [], capture_pid: self()]]

      # The empty-input gate rejects, yet the capture still fired.
      assert {:error, %EmbeddingAdapterError{reason: :invalid_request}} =
               FakeEmbeddings.embed(req, opts)

      assert_receive {FakeEmbeddings, :call, %{request: ^req, opts: ^opts}}
    end

    test "fires once per call on the happy path" do
      opts = [adapter_opts: Fixtures.single() ++ [capture_pid: self()]]

      assert {:ok, _} = FakeEmbeddings.embed(request(), opts)
      assert_receive {FakeEmbeddings, :call, _}
      refute_receive {FakeEmbeddings, :call, _}, 20
    end

    test "a non-pid :capture_pid is a no-op" do
      opts = [adapter_opts: Fixtures.single() ++ [capture_pid: :not_a_pid]]
      assert {:ok, _} = FakeEmbeddings.embed(request(), opts)
    end
  end

  describe "{:retry_until_call, n}" do
    test "returns a synthetic :rate_limited for the first n-1 calls" do
      cursor = FakeEmbeddings.start_script_cursor()
      opts = [adapter_opts: Fixtures.retry_until_call(3, 1) ++ [script_cursor: cursor]]

      assert {:error, %EmbeddingAdapterError{reason: :rate_limited, retry_after_ms: 0}} =
               FakeEmbeddings.embed(request(), opts)

      assert {:error, %EmbeddingAdapterError{reason: :rate_limited}} =
               FakeEmbeddings.embed(request(), opts)

      assert {:ok, %EmbeddingResponse{embeddings: [_]}} = FakeEmbeddings.embed(request(), opts)
    end

    test "{:retry_until_call, 1} succeeds on the first call" do
      cursor = FakeEmbeddings.start_script_cursor()
      opts = [adapter_opts: Fixtures.retry_until_call(1, 2) ++ [script_cursor: cursor]]

      assert {:ok, %EmbeddingResponse{embeddings: [_, _]}} = FakeEmbeddings.embed(request(), opts)
    end

    test "a retry budget exhausting the rest of the script surfaces :no_scripted_embedding" do
      cursor = FakeEmbeddings.start_script_cursor()
      opts = [adapter_opts: [embedding_script: [{:retry_until_call, 1}], script_cursor: cursor]]

      assert {:error, %EmbeddingAdapterError{reason: :unknown, metadata: %{cause: cause}}} =
               FakeEmbeddings.embed(request(), opts)

      assert cause == :no_scripted_embedding
    end

    test "consecutive retry entries chain into a layered budget instead of raising" do
      cursor = FakeEmbeddings.start_script_cursor()

      script = [
        {:retry_until_call, 2},
        {:retry_until_call, 2},
        {:ok, Fixtures.embeddings(1)}
      ]

      # script/1 validates this shape, so embed/2 must be able to run it
      # (contract invariant 2: embed/2 does not raise).
      assert :ok = FakeEmbeddings.script(script)

      opts = [adapter_opts: [embedding_script: script, script_cursor: cursor]]

      # Each entry contributes n - 1 rejections; the call that spends one
      # entry's budget opens the next entry's.
      assert {:error, %EmbeddingAdapterError{reason: :rate_limited}} =
               FakeEmbeddings.embed(request(), opts)

      assert {:error, %EmbeddingAdapterError{reason: :rate_limited}} =
               FakeEmbeddings.embed(request(), opts)

      assert {:ok, %EmbeddingResponse{embeddings: [_]}} = FakeEmbeddings.embed(request(), opts)
    end

    test "consecutive retry entries with no terminal entry surface :no_scripted_embedding" do
      cursor = FakeEmbeddings.start_script_cursor()
      script = [{:retry_until_call, 2}, {:retry_until_call, 2}]
      opts = [adapter_opts: [embedding_script: script, script_cursor: cursor]]

      assert {:error, %EmbeddingAdapterError{reason: :rate_limited}} =
               FakeEmbeddings.embed(request(), opts)

      assert {:error, %EmbeddingAdapterError{reason: :rate_limited}} =
               FakeEmbeddings.embed(request(), opts)

      assert {:error, %EmbeddingAdapterError{reason: :unknown, metadata: %{cause: cause}}} =
               FakeEmbeddings.embed(request(), opts)

      assert cause == :no_scripted_embedding
    end
  end

  describe "script/1 validation" do
    test "accepts every legal entry shape" do
      err = EmbeddingAdapterError.new(:timeout)

      assert :ok =
               FakeEmbeddings.script([
                 {:ok, Fixtures.embeddings(2)},
                 {:ok, Fixtures.embeddings(1), usage: %Usage{}},
                 {:error, err},
                 {:retry_until_call, 2}
               ])
    end

    test "raises ArgumentError on an unrecognised entry" do
      assert_raise ArgumentError, ~r/invalid FakeEmbeddings script entry/, fn ->
        FakeEmbeddings.script([:nonsense])
      end
    end

    test "raises ArgumentError on {:retry_until_call, 0}" do
      assert_raise ArgumentError, ~r/invalid FakeEmbeddings script entry/, fn ->
        FakeEmbeddings.script([{:retry_until_call, 0}])
      end
    end
  end
end
