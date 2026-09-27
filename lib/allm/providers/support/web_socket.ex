defmodule ALLM.Providers.Support.WebSocket do
  @moduledoc """
  The WebSocket transport seam the streaming audio adapters are written
  against.

  Layer B — runtime. An adapter takes the implementing module from
  `opts[:ws_module]` (default `ALLM.Providers.Support.WebSocket.Mint`),
  exactly as the HTTP stream adapters take `opts[:finch_module]`, so a test
  can substitute a scripted stub without a network.

  ## Transport rule

  A WebSocket is opened over an HTTP/1 connection in the process that
  reduces the stream, and every function of this behaviour is called from
  that process. The connection is process-less: its transport messages
  arrive in the reducing process's mailbox, next to any input-pump
  messages, and a halted stream closes the socket and drains those
  messages in its after function. The API key goes in the upgrade
  request's headers, never in the URL, because URLs reach logs and
  telemetry.

  ## Receiving selectively

  The owner must not consume messages that are not its own, so it selects
  transport messages in its `receive` by tag: every message a connection
  delivers is a 2- or 3-tuple whose second element is `message_tag/1` of
  that connection (for the Mint implementation, the socket). The
  `is_transport_message/2` guard selects exactly those, and a matching
  message goes to `handle_message/2`:

      require ALLM.Providers.Support.WebSocket, as: WebSocket
      tag = ws.message_tag(conn)

      receive do
        message when WebSocket.is_transport_message(message, tag) ->
          ws.handle_message(conn, message)
      end

  `handle_message/2` still returns `:unknown` for a message that carries
  the tag but is not a transport message, so a caller that passes it
  anything else gets a plain answer.

  ## Frames

  Control frames never leave the implementation. A server ping is answered
  with a pong by `handle_message/2` itself, and pongs are dropped, so
  `t:frame/0` has only data and close variants. `:closed` in a
  `handle_message/2` result means the transport closed without a close
  frame.
  """

  @typedoc "An open connection. Opaque to the adapter; only this behaviour's functions read it."
  @type conn :: term()

  @typedoc "A data or close frame, sent or received."
  @type frame ::
          {:text, String.t()}
          | {:binary, binary()}
          | {:close, non_neg_integer() | nil, String.t()}

  @typedoc """
  Why `connect/3` failed: the server answered the upgrade with a status
  other than 101 (with the response body, JSON-decoded when it is JSON), or
  the transport failed before a response.
  """
  @type connect_error ::
          {:upgrade_status, pos_integer(), map() | list() | binary()}
          | {:transport, term()}

  @doc """
  Open a WebSocket to `url` (`wss://` or `ws://`) with `headers` on the
  upgrade request, and drive the handshake to completion in the calling
  process. Honours `opts[:connect_timeout]` (milliseconds).
  """
  @callback connect(url :: String.t(), headers :: [{String.t(), String.t()}], opts :: keyword()) ::
              {:ok, conn()} | {:error, connect_error()}

  @doc "Send one frame."
  @callback send_frame(conn(), frame()) :: {:ok, conn()} | {:error, conn(), term()}

  @doc """
  The tag every transport message of `conn` carries as its second element.
  """
  @callback message_tag(conn()) :: term()

  @doc """
  Interpret one message selected by `message_tag/1`. Returns the data and
  close frames it carried (answering pings itself), `:unknown` for a
  message that is not this connection's, or an error.
  """
  @callback handle_message(conn(), message :: term()) ::
              {:ok, conn(), [frame() | :closed]} | :unknown | {:error, conn(), term()}

  @doc """
  Close the connection: a best-effort close frame, then the transport.
  Idempotent; never raises.
  """
  @callback close(conn()) :: :ok

  @doc """
  Remove every transport message of `conn` from the calling process's
  mailbox. Call it after `close/1`.
  """
  @callback flush_messages(conn()) :: :ok

  @doc """
  Guard: `message` is a transport message of the connection whose
  `message_tag/1` is `tag` (a 2- or 3-tuple whose second element is
  `tag`). Use it to select transport messages in a selective `receive`, so
  no other message in the owner's mailbox is consumed.
  """
  defguard is_transport_message(message, tag)
           when is_tuple(message) and tuple_size(message) in [2, 3] and
                  elem(message, 1) == tag
end
