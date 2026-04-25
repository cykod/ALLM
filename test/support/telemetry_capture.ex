defmodule ALLM.Test.TelemetryCapture do
  @moduledoc """
  Per-test `:telemetry` handler capture helper used by Phase 9 tests.

  Attaches a single handler per PID that records every matching event into
  the calling process's process dictionary, exposes `events/0` to read the
  recorded list back in arrival order, and `detach/0` to remove the handler
  and clear the dict.

  Per-PID isolation prevents parallel tests from cross-contaminating each
  other; the handler id is derived from `self()` plus a unique integer so
  parallel tests reusing the same module never collide.

  Usage:

      :ok = ALLM.Test.TelemetryCapture.attach([
        [:allm, :generate, :start],
        [:allm, :generate, :stop]
      ])

      {:ok, _resp} = ALLM.generate(engine, request)

      events = ALLM.Test.TelemetryCapture.events()
      :ok = ALLM.Test.TelemetryCapture.detach()
  """

  @handler_id_key {__MODULE__, :handler_id}
  @events_key {__MODULE__, :events}
  @owner_key {__MODULE__, :owner}

  @doc """
  Attach a `:telemetry` handler that captures `event_names` into the
  caller's process dictionary. Idempotent per PID — subsequent calls
  in the same process return `:ok` without installing a second handler.
  """
  @spec attach([[atom(), ...], ...]) :: :ok
  def attach(event_names) when is_list(event_names) do
    case Process.get(@handler_id_key) do
      nil ->
        handler_id =
          "allm-test-#{inspect(self())}-#{System.unique_integer([:positive])}"

        Process.put(@handler_id_key, handler_id)
        Process.put(@events_key, [])
        owner = self()
        Process.put(@owner_key, owner)

        :ok =
          :telemetry.attach_many(
            handler_id,
            event_names,
            &__MODULE__.__handle__/4,
            %{owner: owner}
          )

        :ok

      _existing ->
        :ok
    end
  end

  @doc """
  Return the captured events as a list of `{event_name, measurements, metadata}`
  tuples in arrival order.
  """
  @spec events() :: [{[atom(), ...], map(), map()}]
  def events do
    Process.get(@events_key, []) |> Enum.reverse()
  end

  @doc """
  Remove the per-PID handler and clear the captured-event buffer.
  """
  @spec detach() :: :ok
  def detach do
    case Process.get(@handler_id_key) do
      nil ->
        :ok

      handler_id ->
        _ = :telemetry.detach(handler_id)
        Process.delete(@handler_id_key)
        Process.delete(@events_key)
        Process.delete(@owner_key)
        :ok
    end
  end

  @doc false
  @spec __handle__([atom(), ...], map(), map(), map()) :: :ok
  def __handle__(event_name, measurements, metadata, %{owner: owner}) do
    # Telemetry handlers may execute in arbitrary processes (e.g. inside
    # the per-tool task). Push the event into the owner PID's dictionary
    # via a synchronous message so capture is process-isolated yet still
    # collects from spans that fire elsewhere.
    if owner == self() do
      existing = Process.get(@events_key, [])
      Process.put(@events_key, [{event_name, measurements, metadata} | existing])
    else
      send(owner, {:__telemetry_capture__, event_name, measurements, metadata})
    end

    :ok
  end

  @doc """
  Drain pending cross-process telemetry messages into the per-PID buffer.
  Call before `events/0` when handlers may have fired in spawned processes
  (e.g. inside tool tasks).
  """
  @spec drain(timeout()) :: :ok
  def drain(timeout \\ 50) do
    receive do
      {:__telemetry_capture__, event_name, measurements, metadata} ->
        existing = Process.get(@events_key, [])
        Process.put(@events_key, [{event_name, measurements, metadata} | existing])
        drain(timeout)
    after
      timeout -> :ok
    end
  end
end
