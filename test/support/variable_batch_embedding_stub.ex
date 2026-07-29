defmodule ALLM.Test.VariableBatchEmbeddingStub do
  @moduledoc """
  An `ALLM.EmbeddingAdapter` whose `max_batch_size/0` is settable per test
  process, so `ALLM.EmbeddingBatch`'s chunking is observable.

  `ALLM.Providers.FakeEmbeddings.max_batch_size/0` is a per-module constant of
  `2048` (the behaviour requires a zero-arity constant — see
  `c:ALLM.EmbeddingAdapter.max_batch_size/0`), so no chunking is reachable
  through it and a property quantifying over `max_batch_size in 1..500` has
  nothing to vary. This stub varies exactly that one value and delegates
  everything else to `FakeEmbeddings`, so scripts, cursors, the `:capture_pid`
  seam, and the two mandatory pre-flight gates all behave identically.

  ## Why the process dictionary

  `put_max_batch_size/1` writes to the **calling process's** dictionary, not
  application env. Application env is global and would race across `async:
  true` test modules — the same class of foot-gun as `Logger.configure/1` and a
  bare `:telemetry.attach/4`. Process-dict scoping mirrors `FakeEmbeddings`'
  own cursor.

  The default when unset is `100`.

      adapter_opts = [embedding_script: [{:ok, [ALLM.Embedding.new(vector: [1.0])]}]]
      ALLM.Test.VariableBatchEmbeddingStub.put_max_batch_size(100)
      engine = ALLM.Engine.new(
        embed_adapter: ALLM.Test.VariableBatchEmbeddingStub,
        adapter_opts: adapter_opts
      )

  Test-only: this module lives under `test/support/` and is not part of the
  published package. Unlike `FakeEmbeddings`, no library user needs it.
  """

  @behaviour ALLM.EmbeddingAdapter

  @default_max_batch_size 100

  @doc """
  Set `max_batch_size/0` for the calling process. Process-dict scoped, so
  `async: true` is safe.
  """
  @spec put_max_batch_size(pos_integer()) :: :ok
  def put_max_batch_size(n) when is_integer(n) and n > 0 do
    Process.put(__MODULE__, n)
    :ok
  end

  @doc """
  Clear the per-process override, restoring the `#{@default_max_batch_size}`
  default.
  """
  @spec reset_max_batch_size() :: :ok
  def reset_max_batch_size do
    Process.delete(__MODULE__)
    :ok
  end

  @impl ALLM.EmbeddingAdapter
  @spec max_batch_size() :: pos_integer()
  def max_batch_size, do: Process.get(__MODULE__, @default_max_batch_size)

  @impl ALLM.EmbeddingAdapter
  @spec embed(ALLM.EmbeddingRequest.t(), keyword()) ::
          {:ok, ALLM.EmbeddingResponse.t()}
          | {:error, ALLM.Error.EmbeddingAdapterError.t()}
  defdelegate embed(request, opts), to: ALLM.Providers.FakeEmbeddings
end
