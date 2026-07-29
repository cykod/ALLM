defmodule ALLM.EmbeddingBatch do
  @moduledoc false

  # Layer-C internal machinery for `ALLM.embed/3`: split an oversized
  # `%ALLM.EmbeddingRequest{}` into adapter-sized chunks, dispatch them
  # sequentially, and merge the responses back into one.
  #
  # The three target providers cap a single request at 2048, 100, and 1000
  # inputs respectively, and bulk-loading a vector store routinely exceeds
  # all three. Absorbing that asymmetry here keeps every adapter thin: an
  # adapter never sees more than its own `max_batch_size/0` inputs when
  # driven through the façade.
  #
  # Chunks dispatch SEQUENTIALLY. Firing 50 chunks concurrently is the
  # fastest way to a 429 storm, and the retry loop would serialise them
  # again anyway with backoff attached. Sequential dispatch is therefore
  # also the backpressure mechanism: at most one in-flight HTTP request per
  # `ALLM.embed/3` call.
  #
  # Retry is PER CHUNK. `run/4` reads a materialised `ALLM.Retry` policy
  # from `dispatch_opts[:retry_policy]` and pops it before handing the rest
  # of the opts to the adapter, so a 50-chunk call has 50 independent retry
  # budgets and no aggregate ceiling. `ALLM.embed/3` documents the
  # multiplication.
  #
  # Rebasing lives in `run/4`, not in `merge/1`. `chunk/2` hands back
  # `{offset, sub_request}` pairs; `run/4` shifts each chunk's response
  # indices by its offset; `merge/1` then assumes globally-unique indices
  # and does no arithmetic of its own. That split is what makes `merge/1`
  # testable against hand-built responses.

  alias ALLM.{EmbeddingRequest, EmbeddingResponse, Retry, Usage}
  alias ALLM.Error.EmbeddingAdapterError

  @typedoc "A chunk's zero-based offset into the parent request's `:input` list."
  @type offset :: non_neg_integer()

  @doc false
  @spec run(EmbeddingRequest.t(), module(), keyword(), map()) ::
          {:ok, EmbeddingResponse.t()} | {:error, EmbeddingAdapterError.t()}
  def run(%EmbeddingRequest{} = request, adapter, dispatch_opts, telemetry_metadata)
      when is_atom(adapter) and is_list(dispatch_opts) and is_map(telemetry_metadata) do
    {policy, adapter_opts} = Keyword.pop(dispatch_opts, :retry_policy, :no_retry)
    max = adapter.max_batch_size()

    dispatch(chunks_for(request, max), %{
      adapter: adapter,
      opts: adapter_opts,
      telemetry_metadata: telemetry_metadata,
      policy: policy,
      max: max
    })
  end

  @doc false
  @spec chunk(EmbeddingRequest.t(), pos_integer()) :: [{offset(), EmbeddingRequest.t()}]
  def chunk(%EmbeddingRequest{input: input} = request, max_batch_size)
      when is_list(input) and is_integer(max_batch_size) and max_batch_size > 0 do
    input
    |> Enum.chunk_every(max_batch_size)
    |> Enum.with_index()
    |> Enum.map(fn {slice, i} -> {i * max_batch_size, %{request | input: slice}} end)
  end

  @doc false
  @spec merge([EmbeddingResponse.t()]) :: EmbeddingResponse.t()
  def merge([%EmbeddingResponse{} = first | _] = responses) do
    %EmbeddingResponse{
      id: first_non_nil(responses, & &1.id),
      request_id: first_non_nil(responses, & &1.request_id),
      model: first_non_nil(responses, & &1.model),
      embeddings: responses |> Enum.flat_map(& &1.embeddings) |> Enum.sort_by(& &1.index),
      usage: merge_usage(responses),
      # Only the first chunk's `:raw` survives; `metadata.chunk_count`
      # records how many were discarded.
      raw: first.raw,
      metadata: Map.put(first.metadata, :chunk_count, length(responses))
    }
  end

  # ---------------------------------------------------------------------------
  # Chunk dispatch
  # ---------------------------------------------------------------------------

  # An empty `:input` produces no chunks. The façade validates before
  # reaching here, so this is only observable on a direct `run/4` call —
  # dispatch the request once anyway so the adapter's own `:invalid_request`
  # gate is what rejects it, rather than inventing an error here.
  defp chunks_for(%EmbeddingRequest{} = request, max) do
    case chunk(request, max) do
      [] -> [{0, request}]
      chunks -> chunks
    end
  end

  # Single-chunk fast path: return the adapter's response as-is (`:raw`
  # intact) with only `metadata.chunk_count` added. No merge runs, so the
  # overwhelmingly common non-batched call is untouched.
  defp dispatch([{_offset, request}], ctx) do
    case dispatch_chunk(request, ctx) do
      {:ok, response} -> {:ok, put_chunk_count(response, 1)}
      {:error, error} -> {:error, stamp_progress(error, 0, ctx.max)}
    end
  end

  defp dispatch(chunks, ctx) do
    chunks
    |> Enum.reduce_while({:ok, []}, fn {offset, request}, {:ok, acc} ->
      case dispatch_chunk(request, ctx) do
        {:ok, response} -> {:cont, {:ok, [rebase(response, offset) | acc]}}
        {:error, error} -> {:halt, {:error, error, length(acc)}}
      end
    end)
    |> finish(ctx)
  end

  defp finish({:ok, reversed}, _ctx), do: {:ok, merge(Enum.reverse(reversed))}

  defp finish({:error, error, completed_chunks}, ctx),
    do: {:error, stamp_progress(error, completed_chunks, ctx.max)}

  # One chunk, under its own retry budget. The closure hands every adapter
  # error to `Retry.run/3` as `{:retry, delay, error}`; the policy's
  # `retry_on` list — widened at the façade call site with the retryable
  # embedding reasons — is the single source of truth for which ones
  # actually retry. Non-retryable reasons fall straight through to
  # `{:error, error}` inside `Retry.run/3`.
  #
  # The final clause is an EXPLICIT raise, not a laundering fall-through and
  # not an incidental `CaseClauseError`. `ALLM.EmbeddingAdapter` is a public
  # behaviour third parties implement, so the caller set is open by
  # construction and the conformance suite's only two error cases are
  # pre-flight argument gates — an adapter that returns a raw transport error
  # from its HTTP layer passes all ten cases. A `raise` keeps `run/4`'s
  # `@spec` honest (raises do not appear in specs, so the tuple contract is
  # not widened), names the offending adapter rather than surfacing an
  # anonymous `CaseClauseError` from this `@moduledoc false` internal, and is
  # coverable by a non-conforming stub. `ALLM.embed/3`'s `@doc` and
  # `ALLM.EmbeddingAdapter` invariant 2 both state the behaviour.
  defp dispatch_chunk(%EmbeddingRequest{} = request, ctx) do
    Retry.run(ctx.policy, ctx.telemetry_metadata, fn ->
      case ctx.adapter.embed(request, ctx.opts) do
        {:ok, _} = ok ->
          ok

        {:error, %EmbeddingAdapterError{} = error} ->
          {:retry, error.retry_after_ms || 0, error}

        other ->
          raise ArgumentError,
                "#{inspect(ctx.adapter)} violated ALLM.EmbeddingAdapter invariant 2: " <>
                  "embed/2 must return {:ok, %ALLM.EmbeddingResponse{}} or " <>
                  "{:error, %ALLM.Error.EmbeddingAdapterError{}}, got: #{inspect(other)}"
      end
    end)
  end

  defp rebase(%EmbeddingResponse{embeddings: embeddings} = response, offset) do
    %{response | embeddings: Enum.map(embeddings, &%{&1 | index: offset + &1.index})}
  end

  defp put_chunk_count(%EmbeddingResponse{} = response, count) do
    %{response | metadata: Map.put(response.metadata, :chunk_count, count)}
  end

  # Mid-batch failure metadata: chunk k of n failing returns that chunk's
  # own error, unchanged apart from two diagnostic keys. No partial vectors
  # are returned — callers needing resumability chunk themselves against
  # `max_batch_size/0`.
  defp stamp_progress(%EmbeddingAdapterError{} = error, completed_chunks, max) do
    %{
      error
      | metadata:
          Map.merge(error.metadata, %{
            completed_chunks: completed_chunks,
            completed_inputs: completed_chunks * max
          })
    }
  end

  # ---------------------------------------------------------------------------
  # Merge helpers
  # ---------------------------------------------------------------------------

  defp first_non_nil(responses, fun), do: Enum.find_value(responses, fun)

  # EVERY `%ALLM.Usage{}` field is handled, and the two lists below must
  # between them cover the whole struct. The single-chunk fast path in
  # `dispatch/2` returns the adapter's `%Usage{}` verbatim, so any field this
  # function forgot would make `usage` silently depend on input length — full
  # usage at 2,000 inputs against a 2048-cap adapter, truncated usage at
  # 2,049. A new `%ALLM.Usage{}` field MUST be added to one of the two lists;
  # `test/allm/embedding_batch_test.exs` fails if it is not.
  #
  # Numeric fields sum across chunks, skipping `nil`, so the result is `nil`
  # only when every chunk was `nil` and a provider reporting no counters does
  # not acquire a spurious `0`. Costs sum for the same reason token counts do:
  # a chunked call's cost is the sum of its requests'. `:output_tokens` has no
  # embedding-side meaning and is normally `nil` in every chunk, which the sum
  # preserves.
  @summed_usage_fields [
    :input_tokens,
    :output_tokens,
    :cached_input_tokens,
    :reasoning_tokens,
    :total_tokens,
    :input_cost,
    :output_cost,
    :total_cost
  ]

  # Map-valued fields merge with the EARLIER chunk winning on key collision,
  # matching the first-chunk-wins rule `:raw` and `:metadata` already follow.
  @merged_usage_fields [:tool_usage, :extra]

  defp merge_usage(responses) do
    usages = Enum.map(responses, & &1.usage)

    summed = Map.new(@summed_usage_fields, &{&1, sum_usage_field(usages, &1)})
    merged = Map.new(@merged_usage_fields, &{&1, merge_usage_map(usages, &1)})

    struct!(Usage, Map.merge(summed, merged))
  end

  defp merge_usage_map(usages, key) do
    Enum.reduce(usages, %{}, fn usage, acc ->
      case usage_field(usage, key) do
        map when is_map(map) -> Map.merge(map, acc)
        _ -> acc
      end
    end)
  end

  defp sum_usage_field(usages, key) do
    case usages |> Enum.map(&usage_field(&1, key)) |> Enum.reject(&is_nil/1) do
      [] -> nil
      values -> Enum.sum(values)
    end
  end

  # The second clause is deliberately tolerant rather than a raise, unlike
  # `dispatch_chunk/2`'s invariant-2 guard: a `nil` (or otherwise absent)
  # `:usage` costs the caller a counter, whereas a wrong-shaped RETURN costs
  # them the whole response. Degrading a missing counter to `nil` is the
  # documented merge rule; degrading a wrong return shape would be laundering.
  # Covered by a hand-built-response test.
  defp usage_field(%Usage{} = usage, key), do: Map.fetch!(usage, key)
  defp usage_field(_other, _key), do: nil
end
