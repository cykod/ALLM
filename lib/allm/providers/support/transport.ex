defmodule ALLM.Providers.Support.Transport do
  @moduledoc """
  Shared HTTP-transport option handling for the streaming provider adapters.

  Streaming adapters open their request with `Finch.async_request/3` and
  forward a small set of transport opts verbatim (see
  `ALLM.Adapter.transport_opts/0` for the full neutral list, which also
  covers the non-streaming `Req` path).

  ## Why this module exists

  Finch's HTTP/1 pool defaults `:receive_timeout` to **15,000 ms**
  (`Finch.HTTP1.Pool`), and that timer covers the gap before the *first*
  byte of the response body. Reasoning models (`gpt-5.x`, extended-thinking
  Claude) routinely spend longer than that thinking before the first SSE
  chunk is emitted, so the transport killed the request mid-think and the
  adapter reported `%AdapterError{reason: :network_error}` — a misleading
  error for what is really "the model is still working".

  Worse, ALLM's own inter-event timer (`opts[:stream_timeout]`, default
  60,000 ms) could never fire: the 15 s transport timer always won the race,
  so raising `:stream_timeout` alone had no effect.

  `finch_opts/2` fixes both halves: `:stream_timeout` becomes the single
  governing knob, and the transport timer is defaulted *above* it (by 30,000
  ms of headroom) so it is a backstop rather than the primary timer. An
  explicit `opts[:receive_timeout]` still wins.
  """

  # Transport opts forwarded verbatim to `Finch.async_request/3`.
  # `:finch_stub_ref` is the test-injection ref read by `ALLM.Test.FinchStub`.
  @finch_forwarded_opts [
    :finch_stub_ref,
    :receive_timeout,
    :request_timeout,
    :pool_timeout
  ]

  # Milliseconds the transport receive timer sits ABOVE `:stream_timeout`, so
  # ALLM's typed `%AdapterError{reason: :timeout}` wins the race against
  # Finch's untyped transport error.
  @transport_timeout_headroom 30_000

  @doc """
  Build the extra-opts keyword forwarded to `Finch.async_request/3`.

  Takes the resolved adapter `opts` and the already-resolved
  `stream_timeout` (the value the adapter passes to its `receive ... after`
  clause). Returns the subset of `opts` Finch understands, with
  `:receive_timeout` defaulted to
  `stream_timeout + #{@transport_timeout_headroom}` when the caller did not
  set it explicitly.

  A `stream_timeout` of `:infinity` yields `receive_timeout: :infinity`.

  ## Examples

      iex> ALLM.Providers.Support.Transport.finch_opts([], 60_000)
      [receive_timeout: 90_000]

      iex> ALLM.Providers.Support.Transport.finch_opts([receive_timeout: 5_000], 60_000)
      [receive_timeout: 5_000]

      iex> ALLM.Providers.Support.Transport.finch_opts([], :infinity)
      [receive_timeout: :infinity]
  """
  @spec finch_opts(keyword(), timeout()) :: keyword()
  def finch_opts(opts, stream_timeout) when is_list(opts) do
    opts
    |> Keyword.take(@finch_forwarded_opts)
    |> Keyword.put_new(:receive_timeout, default_receive_timeout(stream_timeout))
  end

  @doc """
  The opts forwarded verbatim to `Finch.async_request/3`.
  """
  @spec finch_forwarded_opts() :: [atom()]
  def finch_forwarded_opts, do: @finch_forwarded_opts

  # `:infinity` propagates; a finite inter-event budget gets headroom so the
  # ALLM-level timer fires first and produces the documented `:timeout` reason.
  defp default_receive_timeout(:infinity), do: :infinity

  defp default_receive_timeout(ms) when is_integer(ms) and ms > 0,
    do: ms + @transport_timeout_headroom
end
