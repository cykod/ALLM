defmodule ALLM.TransportOptsRoutingTest do
  @moduledoc """
  Regression lock for the three ways a caller can try to raise an HTTP
  transport timeout, all of which were broken.

  A reasoning model (`gpt-5.6`, extended-thinking Claude) can spend well over
  Finch's 15,000 ms default `:receive_timeout` thinking BEFORE the first SSE
  chunk. The turn then died as `%AdapterError{reason: :network_error}` and
  every documented way to raise the timeout failed:

    1. **call opt** — `ALLM.chat(engine, thread, receive_timeout: 300_000)`
       reached the adapter, but `Engine.resolve_params/2` also merged it into
       the opaque param map, so `Chat.build_request/4` put it on
       `request.options`, which every body-builder merges onto the provider
       wire → OpenAI HTTP 400 "Unknown parameter: 'receive_timeout'".
    2. **engine `params:`** — same path, same 400.
    3. **engine `adapter_opts:`** — the adapters read transport opts off the
       TOP level of their resolved opts, while `StreamRunner` nests
       `adapter_opts` one level down, so the value was never read. (This is
       the route `ALLM.Providers.OpenAI`'s moduledoc documents for
       `finch_name:`, so that was silently broken too.)

  Route 1/2 are fixed by deriving `Chat.@request_carried_keys` from
  `ALLM.Adapter.transport_opts/0`; route 3 by `StreamRunner`'s
  `hoist_transport_opts/2`. `ALLM.Providers.Fake`'s `:record` hook gives us
  both halves in one call: the `%Request{}` (does it leak onto the wire?) and
  the resolved adapter opts (did the value arrive?).
  """
  use ExUnit.Case, async: true

  alias ALLM.{Adapter, Engine, Request}
  alias ALLM.Providers.Fake
  alias ALLM.Providers.Support.Transport

  @script [{:text, "hi"}, {:finish, :stop}]

  defp engine(extra) do
    base = [
      adapter: Fake,
      model: "fake:m",
      adapter_opts: [script: @script, record: self()]
    ]

    Engine.new(
      Keyword.merge(base, extra, fn
        :adapter_opts, a, b -> a ++ b
        _k, _a, b -> b
      end)
    )
  end

  defp thread, do: [ALLM.user("hi")]

  defp recorded do
    assert_receive {:allm_fake_record, %Request{} = req, opts}
    {req, opts}
  end

  describe "route 1 — call opt" do
    test "reaches the adapter and never lands on request.options" do
      assert {:ok, _} =
               ALLM.chat(engine([]), thread(),
                 stream_timeout: 300_000,
                 receive_timeout: 300_000
               )

      {req, opts} = recorded()

      assert Keyword.get(opts, :stream_timeout) == 300_000
      assert Keyword.get(opts, :receive_timeout) == 300_000
      assert req.options == %{}
    end

    test "the streaming façade behaves identically" do
      {:ok, stream} = ALLM.stream(engine([]), thread(), stream_timeout: 300_000)
      _ = Enum.to_list(stream)

      {req, opts} = recorded()

      assert Keyword.get(opts, :stream_timeout) == 300_000
      assert req.options == %{}
    end
  end

  describe "route 2 — engine params:" do
    test "reaches the adapter and never lands on request.options" do
      assert {:ok, _} = ALLM.chat(engine(params: %{stream_timeout: 300_000}), thread())

      {req, opts} = recorded()

      assert Keyword.get(opts, :stream_timeout) == 300_000
      assert req.options == %{}
    end

    test "genuine model params on the same engine still ride request.options" do
      # Guard against over-stripping: only transport opts are removed.
      assert {:ok, _} =
               ALLM.chat(engine(params: %{stream_timeout: 300_000, top_p: 0.9}), thread())

      {req, _opts} = recorded()
      assert req.options == %{top_p: 0.9}
    end
  end

  describe "route 3 — engine adapter_opts:" do
    test "is hoisted to the top level of the adapter's opts" do
      assert {:ok, _} =
               ALLM.chat(
                 engine(adapter_opts: [stream_timeout: 300_000, finch_name: MyApp.Finch]),
                 thread()
               )

      {req, opts} = recorded()

      assert Keyword.get(opts, :stream_timeout) == 300_000
      assert Keyword.get(opts, :finch_name) == MyApp.Finch
      assert req.options == %{}

      # …and stays available under :adapter_opts for adapters that read it there.
      assert Keyword.get(opts[:adapter_opts], :stream_timeout) == 300_000
    end

    test "a call opt outranks the engine's adapter_opts fallback" do
      assert {:ok, _} =
               ALLM.chat(engine(adapter_opts: [stream_timeout: 300_000]), thread(),
                 stream_timeout: 90_000
               )

      {_req, opts} = recorded()
      assert Keyword.get(opts, :stream_timeout) == 90_000
    end

    test "non-transport adapter_opts are NOT hoisted" do
      assert {:ok, _} = ALLM.chat(engine(adapter_opts: [script: @script]), thread())

      {_req, opts} = recorded()
      refute Keyword.has_key?(opts, :script)
      assert Keyword.has_key?(opts[:adapter_opts], :script)
    end
  end

  describe "ALLM.Adapter.transport_opts/0" do
    test "covers every key the streaming adapters forward to Finch" do
      # Fail-closed: a transport opt added to the Finch forwarding list without
      # being registered here would silently start leaking onto the wire again.
      assert Transport.finch_forwarded_opts() -- Adapter.transport_opts() == []
    end
  end
end
