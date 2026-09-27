defmodule ALLM.Test.WebSocketStub do
  @moduledoc """
  A scripted `ALLM.Providers.Support.WebSocket` for adapter tests. Internal
  test support — NOT part of the published Hex package.

  Pass `ws_module: ALLM.Test.WebSocketStub, ws_stub: stub` in the adapter's
  opts, where `stub` is the pid `install/2` returns.

  ## State

  The stub's state lives in an `Agent` started by `install/2` and linked to
  the caller, and the pid rides in the opts (the same shape as
  `ALLM.Test.FinchStub.install_shared/2`). The process that reduces the
  stream can therefore differ from the test process, and every install is
  its own Agent, so `async: true` tests never share a stub.

  ## Script

  A list of steps, consumed in order. Each step is
  `{:after_client, matcher, server_frames}`: when the client sends a frame
  that `matcher` accepts while the step is at the head of the script, the
  step is consumed and each server frame is delivered to the sending
  process's mailbox as `{ALLM.Test.WebSocketStub, tag, frame}`, where
  `handle_message/2` interprets it. A client frame the head step does not
  accept consumes nothing.

  Matchers: `:any`; a map, which accepts a `{:text, json}` frame whose JSON
  decodes to exactly that map; or a one-argument function over the frame.

  Server frames: `{:text, s}`, `{:json, map}` (sent as `{:text,
  Jason.encode!(map)}`), `{:binary, b}`, `{:close, code, reason}`,
  `{:ping, data}` (answered with a pong recorded in `sent_frames/1`, and
  never returned as a frame), `:closed` (the transport closed without a
  close frame), `:unknown` (`handle_message/2` answers `:unknown`) and
  `{:transport_error, reason}` (`handle_message/2` answers
  `{:error, conn, reason}`).

  ## Install options

    * `:connect` — `:ok` (default) or the `{:error, reason}` `connect/3`
      returns, e.g. `{:error, {:upgrade_status, 401, body}}`.
    * `:send_error` — a matcher: `send_frame/2` returns
      `{:error, conn, :closed}` for a client frame it accepts (the frame is
      not recorded).
    * `:greeting` — server frames delivered to the connecting process as
      soon as `connect/3` succeeds, before any client frame (for a protocol
      whose server speaks first, such as a realtime `session_started`).

  ## Inspection

  `sent_frames/1` (client frames in order, pongs included),
  `close_count/1`, `connects/1` (`{url, headers}` per `connect/3` call) and
  `calls/1` (`{callback, pid}` per callback invocation, in order).
  """

  @behaviour ALLM.Providers.Support.WebSocket

  @enforce_keys [:agent, :tag]
  defstruct [:agent, :tag]

  @typedoc "A stub connection."
  @type t :: %__MODULE__{agent: pid(), tag: reference()}

  @doc "Install a scripted stub; returns the Agent pid to pass as `ws_stub:`."
  @spec install(list(), keyword()) :: pid()
  def install(script, opts \\ []) when is_list(script) do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          script: script,
          connect: Keyword.get(opts, :connect, :ok),
          send_error: Keyword.get(opts, :send_error),
          greeting: Keyword.get(opts, :greeting, []),
          sent: [],
          close_count: 0,
          connects: [],
          calls: []
        }
      end)

    agent
  end

  @doc "Client frames sent so far, in order."
  @spec sent_frames(pid()) :: [ALLM.Providers.Support.WebSocket.frame() | {:pong, binary()}]
  def sent_frames(agent), do: Agent.get(agent, &Enum.reverse(&1.sent))

  @doc "How many times `close/1` was called."
  @spec close_count(pid()) :: non_neg_integer()
  def close_count(agent), do: Agent.get(agent, & &1.close_count)

  @doc "`{url, headers}` for each `connect/3` call."
  @spec connects(pid()) :: [{String.t(), list()}]
  def connects(agent), do: Agent.get(agent, &Enum.reverse(&1.connects))

  @doc "`{callback, pid}` for each callback invocation, in order."
  @spec calls(pid()) :: [{atom(), pid()}]
  def calls(agent), do: Agent.get(agent, &Enum.reverse(&1.calls))

  # ---------------------------------------------------------------------------
  # Behaviour
  # ---------------------------------------------------------------------------

  @impl true
  def connect(url, headers, opts) do
    agent = Keyword.fetch!(opts, :ws_stub)
    record_call(agent, :connect)

    {reply, greeting} =
      Agent.get_and_update(agent, fn s ->
        {{s.connect, s.greeting}, %{s | connects: [{url, headers} | s.connects]}}
      end)

    case reply do
      :ok ->
        conn = %__MODULE__{agent: agent, tag: make_ref()}
        deliver(conn, conn.tag, greeting)

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def send_frame(%__MODULE__{agent: agent, tag: tag} = conn, frame) do
    record_call(agent, :send_frame)

    case Agent.get_and_update(agent, &advance(&1, frame)) do
      {:send_error, reason} -> {:error, conn, reason}
      frames -> deliver(conn, tag, frames)
    end
  end

  defp deliver(conn, tag, frames) do
    Enum.each(frames, &send(self(), {__MODULE__, tag, &1}))
    {:ok, conn}
  end

  # Records `frame` and, when the head step accepts it, consumes the step and
  # returns its server frames.
  defp advance(%{send_error: matcher} = s, frame) when matcher != nil do
    if matches?(matcher, frame), do: {{:send_error, :closed}, s}, else: record(s, frame)
  end

  defp advance(s, frame), do: record(s, frame)

  defp record(s, frame) do
    s = %{s | sent: [frame | s.sent]}

    case s.script do
      [{:after_client, matcher, server_frames} | rest] ->
        if matches?(matcher, frame), do: {server_frames, %{s | script: rest}}, else: {[], s}

      _ ->
        {[], s}
    end
  end

  @impl true
  def message_tag(%__MODULE__{tag: tag}), do: tag

  @impl true
  def handle_message(%__MODULE__{agent: agent, tag: tag} = conn, {__MODULE__, tag, frame}) do
    record_call(agent, :handle_message)

    case frame do
      {:ping, data} ->
        Agent.update(agent, fn s -> %{s | sent: [{:pong, data} | s.sent]} end)
        {:ok, conn, []}

      {:json, map} ->
        {:ok, conn, [{:text, Jason.encode!(map)}]}

      :closed ->
        {:ok, conn, [:closed]}

      :unknown ->
        :unknown

      {:transport_error, reason} ->
        {:error, conn, reason}

      other ->
        {:ok, conn, [other]}
    end
  end

  def handle_message(_conn, _message), do: :unknown

  @impl true
  def close(%__MODULE__{agent: agent}) do
    record_call(agent, :close)
    Agent.update(agent, fn s -> %{s | close_count: s.close_count + 1} end)
  end

  @impl true
  def flush_messages(%__MODULE__{agent: agent, tag: tag}) do
    record_call(agent, :flush_messages)
    flush(tag)
  end

  defp flush(tag) do
    receive do
      {__MODULE__, ^tag, _} -> flush(tag)
    after
      0 -> :ok
    end
  end

  defp record_call(agent, name) do
    caller = self()
    Agent.update(agent, fn s -> %{s | calls: [{name, caller} | s.calls]} end)
  end

  defp matches?(:any, _frame), do: true

  defp matches?(map, {:text, json}) when is_map(map) do
    case Jason.decode(json) do
      {:ok, ^map} -> true
      _ -> false
    end
  end

  defp matches?(map, _frame) when is_map(map), do: false
  defp matches?(fun, frame) when is_function(fun, 1), do: fun.(frame)
end
