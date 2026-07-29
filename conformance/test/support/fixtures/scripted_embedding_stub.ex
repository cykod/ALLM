defmodule ALLM.Test.Fixtures.ScriptedEmbeddingStub do
  @moduledoc """
  Permanent test fixture that implements `ALLM.EmbeddingAdapter`. Used by
  `allm_conformance`'s self-test for `ALLM.Test.EmbeddingAdapterConformance`.

  ## Script contract

      adapter_opts: [
        embedding_script: [
          {:ok, [%ALLM.Embedding{...}, ...]},
          {:ok, [%ALLM.Embedding{...}], usage: %ALLM.Usage{...}},
          {:error, %ALLM.Error.EmbeddingAdapterError{...}}
        ]
      ]

  Per-call advancing of `adapter_opts[:embedding_script]` is keyed off an
  optional `adapter_opts[:script_cursor]` Agent pid (from
  `start_script_cursor/0`); without one the stub reads entry 0 each call
  (the single-call contract used by every conformance case). An absent or
  spent script returns the same `:unknown` /
  `%{cause: :no_scripted_embedding}` shape `ALLM.Providers.FakeEmbeddings`
  returns.

  ## Real gates

  Unlike a scripted real provider adapter — which short-circuits to
  `ALLM.Providers.FakeEmbeddings` before its own pre-flight runs — this stub
  evaluates the `input: []` and `length(input) > max_batch_size()` gates
  ahead of the script. `max_batch_size/0` is deliberately small (`8`) so the
  `:batch_too_large` boundary can be exercised without building a
  thousands-of-elements list.

  ## Scope

  Permanent fixture under `conformance/test/support/`. Mirrors
  `ALLM.Test.Fixtures.ScriptedImageStub`'s role for image conformance.
  """

  @behaviour ALLM.EmbeddingAdapter

  alias ALLM.{EmbeddingRequest, EmbeddingResponse, Usage}
  alias ALLM.Error.EmbeddingAdapterError

  @max_batch_size 8

  @doc """
  Start a cursor Agent. Pass the returned pid as
  `adapter_opts[:script_cursor]` to advance entries across multi-call tests.
  """
  @spec start_script_cursor() :: pid()
  def start_script_cursor do
    {:ok, pid} = Agent.start_link(fn -> 0 end)
    pid
  end

  @impl ALLM.EmbeddingAdapter
  @spec max_batch_size() :: pos_integer()
  def max_batch_size, do: @max_batch_size

  @impl ALLM.EmbeddingAdapter
  def embed(%EmbeddingRequest{} = request, opts) when is_list(opts) do
    case gate(request) do
      :ok -> run_scripted(request, opts)
      {:error, _} = error -> error
    end
  end

  defp gate(%EmbeddingRequest{input: []}) do
    {:error,
     EmbeddingAdapterError.new(:invalid_request,
       message: "input must not be empty",
       metadata: %{field: :input}
     )}
  end

  defp gate(%EmbeddingRequest{input: input}) when is_list(input) do
    count = length(input)

    if count > @max_batch_size do
      {:error,
       EmbeddingAdapterError.new(:batch_too_large,
         message: "input count #{count} exceeds max_batch_size #{@max_batch_size}",
         metadata: %{count: count, max: @max_batch_size}
       )}
    else
      :ok
    end
  end

  defp run_scripted(%EmbeddingRequest{} = request, opts) do
    adapter_opts = Keyword.get(opts, :adapter_opts, [])
    script = Keyword.get(adapter_opts, :embedding_script, [])
    cursor = Keyword.get(adapter_opts, :script_cursor)
    index = advance(cursor)

    case Enum.at(script, index) do
      nil ->
        # Same exhaustion shape as the reference implementation
        # (`ALLM.Providers.FakeEmbeddings`), so the stub and the reference
        # never disagree about what an absent or spent script means.
        {:error,
         EmbeddingAdapterError.new(:unknown,
           message: "no scripted embedding",
           metadata: %{cause: :no_scripted_embedding}
         )}

      {:ok, embeddings} when is_list(embeddings) ->
        {:ok, build_response(embeddings, %Usage{}, request, opts)}

      {:ok, embeddings, kw} when is_list(embeddings) and is_list(kw) ->
        usage = Keyword.get(kw, :usage) || %Usage{}
        {:ok, build_response(embeddings, usage, request, opts)}

      {:error, %EmbeddingAdapterError{} = err} ->
        {:error, err}
    end
  end

  defp advance(nil), do: 0

  defp advance(pid) when is_pid(pid),
    do: Agent.get_and_update(pid, fn i -> {i, i + 1} end)

  defp build_response(embeddings, usage, %EmbeddingRequest{} = request, opts) do
    %EmbeddingResponse{
      id: nil,
      request_id: Keyword.get(opts, :request_id),
      model: request.model,
      embeddings: embeddings,
      usage: usage,
      raw: nil,
      metadata: request.metadata
    }
  end
end
