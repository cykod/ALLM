defmodule ALLM.Test.Fixtures.ScriptedModerationStub do
  @moduledoc """
  Permanent test fixture that implements `ALLM.ModerationAdapter`. Used by
  `allm_conformance`'s self-test for `ALLM.Test.ModerationAdapterConformance`.

  ## Script contract

      adapter_opts: [
        moderation_script: [
          {:ok, [%ALLM.ModerationResult{...}, ...]},
          {:flagged, ["violence"]},
          {:error, %ALLM.Error.ModerationAdapterError{...}}
        ]
      ]

  Per-call advancing of `adapter_opts[:moderation_script]` is keyed off an
  optional `adapter_opts[:script_cursor]` Agent pid (from
  `start_script_cursor/0`); without one the stub reads entry 0 each call
  (the single-call contract used by every conformance case). An absent script
  returns one unflagged result per input, matching the *cardinality* and
  `:flagged` value of the default verdict `ALLM.Providers.FakeModeration`
  produces. It does **not** match its category vocabulary (the stub carries
  none, so both maps are `%{}` where the reference carries the 13
  `omni-moderation` names), and it does **not** follow the reference's
  spent-script behaviour: the reference errors with
  `:moderation_script_exhausted` on a non-empty script that runs off the end,
  where this stub simply re-reads the default. No conformance case scripts
  exhaustion, so the divergence is unobservable from the suite; it is stated
  so the fixture is not mistaken for a second reference implementation.

  ## Real gates

  Unlike a scripted real provider adapter — which short-circuits to
  `ALLM.Providers.FakeModeration` before its own pre-flight runs — this stub
  evaluates the `input: []` and `length(input) > max_batch_size()` gates
  ahead of the script, and ahead of anything resembling credential
  resolution. `max_batch_size/0` is deliberately small (`4`) so the
  `:batch_too_large` boundary can be exercised without building a large
  list.

  ## Scope

  Permanent fixture under `conformance/test/support/`. Mirrors
  `ALLM.Test.Fixtures.ScriptedEmbeddingStub`'s role for embedding
  conformance.
  """

  @behaviour ALLM.ModerationAdapter

  alias ALLM.Error.ModerationAdapterError
  alias ALLM.{ModerationRequest, ModerationResponse, ModerationResult}

  @max_batch_size 4

  @doc """
  Start a cursor Agent. Pass the returned pid as
  `adapter_opts[:script_cursor]` to advance entries across multi-call tests.
  """
  @spec start_script_cursor() :: pid()
  def start_script_cursor do
    {:ok, pid} = Agent.start_link(fn -> 0 end)
    pid
  end

  @impl ALLM.ModerationAdapter
  @spec max_batch_size() :: pos_integer()
  def max_batch_size, do: @max_batch_size

  @impl ALLM.ModerationAdapter
  def moderate(%ModerationRequest{} = request, opts) when is_list(opts) do
    case gate(request) do
      :ok -> run_scripted(request, opts)
      {:error, _} = error -> error
    end
  end

  defp gate(%ModerationRequest{input: []}) do
    {:error,
     ModerationAdapterError.new(:invalid_request,
       message: "input must not be empty",
       metadata: %{field: :input}
     )}
  end

  defp gate(%ModerationRequest{input: input} = request) when is_list(input) do
    # Invariant 5 measures ITEMS, not raw list elements: a multimodal input is
    # one item however long the list is.
    count = item_count(request)

    if count > @max_batch_size do
      {:error,
       ModerationAdapterError.new(:batch_too_large,
         message: "input count #{count} exceeds max_batch_size #{@max_batch_size}",
         metadata: %{count: count, max: @max_batch_size}
       )}
    else
      :ok
    end
  end

  defp run_scripted(%ModerationRequest{} = request, opts) do
    adapter_opts = Keyword.get(opts, :adapter_opts, [])
    script = Keyword.get(adapter_opts, :moderation_script, [])
    cursor = Keyword.get(adapter_opts, :script_cursor)
    index = advance(cursor)

    case Enum.at(script, index) do
      nil ->
        # Same cardinality and `:flagged` value the reference implementation
        # (`ALLM.Providers.FakeModeration`) produces for an ABSENT script, so
        # the two never disagree about what "no script" means. See the
        # moduledoc for where they do diverge.
        {:ok, build_response(default_results(request), request, opts)}

      {:ok, results} when is_list(results) ->
        {:ok, build_response(results, request, opts)}

      {:flagged, categories} when is_list(categories) ->
        {:ok, build_response([flagged_result(categories)], request, opts)}

      {:error, %ModerationAdapterError{} = err} ->
        {:error, err}
    end
  end

  defp advance(nil), do: 0

  defp advance(pid) when is_pid(pid),
    do: Agent.get_and_update(pid, fn i -> {i, i + 1} end)

  defp item_count(%ModerationRequest{} = request) do
    if ModerationRequest.multimodal?(request), do: 1, else: length(request.input)
  end

  defp default_results(%ModerationRequest{} = request) do
    for index <- 0..(item_count(request) - 1)//1,
        do: ModerationResult.new(flagged: false, index: index)
  end

  defp flagged_result(categories) do
    ModerationResult.new(
      flagged: true,
      categories: Map.new(categories, &{&1, true}),
      category_scores: Map.new(categories, &{&1, 1.0}),
      index: 0
    )
  end

  defp build_response(results, %ModerationRequest{} = request, opts) do
    %ModerationResponse{
      id: nil,
      request_id: Keyword.get(opts, :request_id),
      model: request.model,
      provider: :stub,
      results: results,
      raw: nil,
      metadata: request.metadata
    }
  end
end
