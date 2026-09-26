defmodule ALLM.Providers.Support.InputPump do
  @moduledoc """
  Reduces a caller-supplied input enumerable in a helper process and hands
  its elements to an owner process under a credit window.

  Layer B — runtime support for the input-streaming audio callbacks
  (`c:ALLM.SpeechStreamAdapter.stream_synthesize_input/3`,
  `c:ALLM.TranscriptionStreamAdapter.stream_transcribe/3`).

  ## Why a helper process

  A microphone or LLM enumerable blocks while it waits for its next
  element, and the process reducing the audio stream must keep reading
  server frames during that wait. So the input is reduced in a separate
  process, the pump, and each element arrives in the owner's mailbox as a
  message the owner can `receive` alongside its transport messages. The
  owner is the only process that writes the transport.

  **Consequence for callers:** the input runs in another process. An input
  that reads the caller's mailbox (`Stream.repeatedly(fn -> receive … end)`)
  or process dictionary sees the pump's instead, and must be relayed from a
  process the caller controls.

  ## Messages the owner receives

      {ref, {:input, element}}
      {ref, :input_done}
      {ref, {:input_error, %{kind: kind, message: message}}}
      {:DOWN, ref, :process, pid, reason}

  `ref` is the monitor reference `start/3` returns, so every pump message
  and the pump's `:DOWN` share one tag. `:input_error` reports an input that
  raised, threw or exited inside its own reduction; its payload is a
  string-only map (`kind` is `:error`, `:throw` or `:exit`, `message` is
  `Exception.format_banner/3`), never the raw exception or exit term, which
  can carry pids and references. A `:DOWN` whose reason is not `:normal`
  and that was not preceded by `:input_done` or `:input_error` means the
  pump was killed by an exit signal, typically from a process linked inside
  the input that crashed.

  ## Lifecycle

    1. `start/3` spawns the pump with `spawn_monitor/1`. The pump is **not
       linked** to the caller, so its exit is a `:DOWN` message and never
       an exit signal that could take the caller down with it.
    2. The pump links a watchdog that monitors the owner and kills the pump
       when the owner dies, so a killed consumer never leaves an input being
       reduced.
    3. At most `window` elements are unacknowledged at any time. The pump
       blocks until the owner calls `ack/2`.
    4. `stop/2` kills the pump, waits for it to be dead, and drains every
       `{ref, _}` message and the `:DOWN` from the caller's mailbox. It is
       idempotent.

  A killed pump runs no code, so the input's own cleanup (a
  `Stream.resource/3` after function) does not run. Its resources are
  released by process exit instead: processes linked to the pump, such as
  the request process `Finch.async_request/3` links to its caller, die with
  it.

  `start/3` must be called from the process that will receive the `:DOWN`,
  which is the owner in every bundled adapter.

  ## Consuming pump messages

  Every consumer handles the four messages the same way, so the protocol
  lives here rather than in each adapter: `is_pump_message/2` selects them
  in the owner's `receive` (next to any transport clauses), and `classify/2`
  says what each one means. The consumer keeps only its element rules and
  its own error construction:

      receive do
        message when InputPump.is_pump_message(message, ref) ->
          case InputPump.classify(message, ref) do
            {:input, element} -> InputPump.ack(pid, ref); handle(element)
            :done -> finish()
            {:failed, cause, info} -> fail(cause, info)
          end
      after
        timeout -> time_out()
      end

  `default_window/0` is the credit window the bundled adapters use when the
  caller does not set one.
  """

  @typedoc "An input failure report, string-only so it is safe to encode and persist."
  @type input_error :: %{kind: :error | :throw | :exit, message: String.t()}

  @typedoc """
  What a pump message means to its owner. `cause` is the value an adapter
  puts on its error's `metadata.cause`; `info` goes on the error's `:cause`.
  """
  @type classified ::
          {:input, term()}
          | :done
          | {:failed, :input_raised | :input_crashed, input_error()}

  @default_window 8

  @doc """
  The credit window bundled adapters use when `adapter_opts[:input_window]`
  is not set.

  ## Examples

      iex> ALLM.Providers.Support.InputPump.default_window()
      8
  """
  @spec default_window() :: pos_integer()
  def default_window, do: @default_window

  @doc """
  Guard: `message` is one of the pump's messages for `ref` (a `{ref, _}`
  tuple or the pump's `:DOWN`). Use it to select pump messages in a
  selective `receive`, so no other message in the owner's mailbox is
  consumed.
  """
  defguard is_pump_message(message, ref)
           when (is_tuple(message) and tuple_size(message) == 2 and elem(message, 0) == ref) or
                  (is_tuple(message) and tuple_size(message) == 5 and
                     elem(message, 0) == :DOWN and elem(message, 1) == ref)

  @doc """
  Classify a pump message selected by `is_pump_message/2`.

    * `{ref, {:input, element}}` — `{:input, element}`. The owner must call
      `ack/2` once it has taken the element, or the pump stalls when the
      window is spent.
    * `{ref, :input_done}` — `:done`; the input is exhausted.
    * `{ref, {:input_error, info}}` — `{:failed, :input_raised, info}`; the
      input raised, threw or exited inside its own reduction.
    * `{:DOWN, ref, :process, _, reason}` — `{:failed, :input_crashed,
      crash_info(reason)}`; an exit signal killed the pump.

  Pure: it neither acks nor stops the pump.

  ## Examples

      iex> ref = make_ref()
      iex> ALLM.Providers.Support.InputPump.classify({ref, {:input, "a"}}, ref)
      {:input, "a"}
      iex> ALLM.Providers.Support.InputPump.classify({:DOWN, ref, :process, self(), :boom}, ref)
      {:failed, :input_crashed, %{kind: :exit, message: "** (exit) :boom"}}
  """
  @spec classify(tuple(), reference()) :: classified()
  def classify({ref, {:input, element}}, ref), do: {:input, element}
  def classify({ref, :input_done}, ref), do: :done
  def classify({ref, {:input_error, info}}, ref), do: {:failed, :input_raised, info}

  def classify({:DOWN, ref, :process, _pid, reason}, ref),
    do: {:failed, :input_crashed, crash_info(reason)}

  @doc """
  Start a pump reducing `enumerable` and sending its elements to `owner`.

  Returns `{pid, ref}`, where `ref` is both the monitor reference and the
  tag on every message the pump sends. `window` is the number of elements
  the pump may send before it waits for an `ack/2`.
  """
  @spec start(Enumerable.t(), pid(), pos_integer()) :: {pid(), reference()}
  def start(enumerable, owner, window)
      when is_pid(owner) and is_integer(window) and window > 0 do
    {pid, ref} = spawn_monitor(fn -> init(enumerable, owner, window) end)
    send(pid, {__MODULE__, :ref, ref})
    {pid, ref}
  end

  @doc """
  Grant the pump one more element of credit.
  """
  @spec ack(pid(), reference()) :: :ok
  def ack(pid, ref) when is_pid(pid) and is_reference(ref) do
    send(pid, {ref, :ack})
    :ok
  end

  @doc """
  Kill the pump and remove every trace of it from the caller's mailbox.

  After it returns, the pump is dead, the monitor is gone, and no
  `{ref, _}` message or `:DOWN` for `ref` remains in the mailbox. Calling it
  again, or after the pump already finished, is a no-op.
  """
  @spec stop(pid(), reference()) :: :ok
  def stop(pid, ref) when is_pid(pid) and is_reference(ref) do
    Process.exit(pid, :kill)

    # A still-active monitor means the pump may not be dead yet. A second
    # monitor's :DOWN is ordered after every message the pump sent, so once
    # it arrives the drain below cannot miss a late element.
    if Process.demonitor(ref, [:flush, :info]) do
      wait_ref = Process.monitor(pid)

      receive do
        {:DOWN, ^wait_ref, :process, ^pid, _reason} -> :ok
      end
    end

    drain(ref)
  end

  @doc """
  Describe a pump's abnormal `:DOWN` reason as the same string-only map an
  `:input_error` carries, with `kind: :exit`.

  An adapter puts it on the error's `:cause` field for an input that
  crashed, so the raw exit reason, which can carry pids and references,
  never reaches the error.

  ## Examples

      iex> ALLM.Providers.Support.InputPump.crash_info(:boom)
      %{kind: :exit, message: "** (exit) :boom"}
  """
  @spec crash_info(term()) :: input_error()
  def crash_info(reason), do: %{kind: :exit, message: Exception.format_banner(:exit, reason)}

  defp drain(ref) do
    receive do
      {^ref, _} -> drain(ref)
      {:DOWN, ^ref, :process, _pid, _reason} -> drain(ref)
    after
      0 -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Pump process
  # ---------------------------------------------------------------------------

  defp init(enumerable, owner, window) do
    ref =
      receive do
        {__MODULE__, :ref, ref} -> ref
      end

    pump = self()
    spawn_link(fn -> watchdog(owner, pump) end)
    run(enumerable, owner, ref, window)
  end

  defp run(enumerable, owner, ref, window) do
    _credit =
      Enum.reduce(enumerable, window, fn element, credit ->
        credit = await_credit(credit, ref)
        send(owner, {ref, {:input, element}})
        credit - 1
      end)

    send(owner, {ref, :input_done})
  catch
    kind, reason ->
      message = Exception.format_banner(kind, reason, __STACKTRACE__)
      send(owner, {ref, {:input_error, %{kind: kind, message: message}}})
  end

  defp await_credit(0, ref) do
    receive do
      {^ref, :ack} -> 1
    end
  end

  defp await_credit(credit, _ref), do: credit

  # Linked to the pump, so a killed pump takes it down. It also monitors
  # the pump, because a pump that finishes normally sends a `:normal` exit
  # signal, which a linked process ignores.
  defp watchdog(owner, pump) do
    owner_ref = Process.monitor(owner)
    pump_ref = Process.monitor(pump)

    receive do
      {:DOWN, ^owner_ref, :process, _, _} -> Process.exit(pump, :kill)
      {:DOWN, ^pump_ref, :process, _, _} -> :ok
    end
  end
end
