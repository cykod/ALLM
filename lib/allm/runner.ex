defmodule ALLM.Runner do
  @moduledoc """
  Internal — use `ALLM.generate/3` instead. See spec §17.

  Layer C — stateless non-streaming entry point. `run/3` delegates to
  `ALLM.StreamRunner.run/3`, folds the returned stream through
  `ALLM.StreamCollector`, and wraps the final `%Response{}` in
  `{:ok, _}`.

  ## Stream-first (spec §3)

  Non-streaming generation is a *reducer* over the streaming path:

      {:ok, stream} = ALLM.StreamRunner.run(engine, request, opts)
      stream
      |> Enum.reduce(ALLM.StreamCollector.new(), &ALLM.StreamCollector.apply_event(&2, &1))
      |> ALLM.StreamCollector.to_response()

  This is the same algorithm consumers can run manually against
  `ALLM.stream_generate/3`; it exists here so `generate/3` has one
  canonical code path and stream-equivalence (spec §3's first consequence)
  is preserved by construction.

  ## Pre-flight vs. mid-stream errors (Non-obvious Decision #4)

    * **Pre-flight** — `StreamRunner.run/3` returns `{:error, struct}`
      synchronously (no stream opened). `run/3` bubbles the error up
      verbatim.
    * **Mid-stream** — the adapter opened a stream and then emitted a
      terminal `{:error, struct}` event. `StreamCollector.apply_event/2`
      folds the error into `%Response{finish_reason: :error, metadata: %{error: struct}}`.
      `run/3` still returns `{:ok, response}` — the caller inspects
      `response.finish_reason == :error` to detect it.

  ## Usage carve-out

  `StreamRunner.run/3`'s `include_raw_chunks: false` filter preserves
  `{:raw_chunk, {:usage, _}}` events regardless of the caller's filter
  preference (Non-obvious Decision #9), so the collector always sees
  usage and populates `response.usage` — no Runner-side override needed.
  """

  alias ALLM.{Engine, Request, Response, StreamCollector, StreamRunner}
  alias ALLM.Error.{AdapterError, EngineError, ValidationError}

  @doc """
  Dispatch a non-streaming request by reducing the streaming adapter's
  output via `ALLM.StreamCollector`.

  Returns `{:ok, %Response{}}` on a successfully-completed stream (a
  mid-stream `{:error, _}` still returns `{:ok, _}` with
  `response.finish_reason == :error` — see module doc) or
  `{:error, struct}` on a synchronous pre-flight failure.

  ## Examples

      iex> engine = ALLM.Engine.new(
      ...>   adapter: ALLM.Providers.Fake,
      ...>   adapter_opts: [script: [{:text, "hi"}, {:finish, :stop}]]
      ...> )
      iex> req = ALLM.request([ALLM.user("say hi")])
      iex> {:ok, response} = ALLM.Runner.run(engine, req)
      iex> {response.output_text, response.finish_reason}
      {"hi", :stop}
  """
  @spec run(Engine.t(), Request.t(), keyword()) ::
          {:ok, Response.t()}
          | {:error, EngineError.t() | AdapterError.t() | ValidationError.t()}
  def run(%Engine{} = engine, %Request{} = request, opts \\ []) when is_list(opts) do
    with {:ok, stream} <- StreamRunner.run(engine, request, opts) do
      response =
        stream
        |> Enum.reduce(StreamCollector.new(), fn event, acc ->
          StreamCollector.apply_event(acc, event)
        end)
        |> StreamCollector.to_response()

      {:ok, response}
    end
  end
end
