# examples/run_all.exs
#
# Runs every numbered example under examples/ in order against the active
# provider. Exits 0 if all succeed, 1 if any failed.
# Used by the Phase 11 / Phase 15 /review validation step (run twice — once
# per provider).
#
# Run with:    OPENAI_API_KEY=sk-... mix run examples/run_all.exs                                # default
#         OR:  ANTHROPIC_API_KEY=sk-ant-... ALLM_PROVIDER=anthropic mix run examples/run_all.exs
#
# Provider-arm gating (Phase 15.6 Decision #15)
# ---------------------------------------------
#
# Each `[0-9][0-9]_*.exs` script may declare which providers it supports via
# a header-comment marker:
#
#     # Provider: openai
#     # Provider: openai, anthropic
#
# The marker is matched anywhere in the file with the regex
# `~r/^#\s*Provider:\s*([\w, ]+)\s*$/m`. Marker absent → run on every
# provider (the default; current behaviour for `01_*` through `09_*`).
# Marker present → run only when `ALLM_PROVIDER` matches one of the listed
# names; otherwise the script is SKIPPED with a `[SKIP]` marker and does
# NOT count toward `failed`.

#
# Process isolation
# -----------------
#
# Every example reports failure with `System.halt(1)` (via
# `ExamplesHelpers.fail!/1`), which stops the whole VM. Running the scripts
# in-process meant the FIRST failure killed the run: no summary, and every
# later script went unobserved rather than passing. Each script therefore
# runs as its own `mix run` OS process; its exit status is the verdict and a
# halt ends only that script. A script still running after
# the per-script timeout (180 s, or `ALLM_EXAMPLE_TIMEOUT_MS`) is killed and
# counted as a timeout.

Application.ensure_all_started(:allm)
Code.require_file("_helpers.exs", __DIR__)

defmodule RunAll do
  @moduledoc false

  # Runs one example in a child `mix run` process, streaming its output.
  # Returns :ok on exit status 0, {:error, {:exit_status, n}} otherwise, or
  # {:error, :timeout} after killing a script that overran.
  def run_script(path, timeout_ms) do
    mix = System.find_executable("mix") || raise "mix not found on PATH"

    port =
      Port.open({:spawn_executable, mix}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["run", path],
        env: [{~c"MIX_ENV", String.to_charlist(to_string(Mix.env()))}]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect(port, os_pid, deadline)
  end

  defp collect(port, os_pid, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        IO.write(data)
        collect(port, os_pid, deadline)

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, status}} ->
        {:error, {:exit_status, status}}
    after
      remaining ->
        # Closing the port alone leaves `mix run` running, so kill the OS
        # process first.
        System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
        Port.close(port)
        {:error, :timeout}
    end
  end
end

# Surface the active provider up-front so the run output is self-describing.
provider = System.get_env("ALLM_PROVIDER", "openai")
IO.puts("=== Provider: #{provider} ===")

# Provider-marker grammar (closed): one optional `# Provider: <names>` line
# anywhere in the file; comma-separated provider names; matched as a whole
# line. Script with no marker runs on every provider.
provider_marker_regex = ~r/^#\s*Provider:\s*([\w, ]+)\s*$/m

# Per-script budget. Image and audio scripts make slow live calls; the
# child `mix run` also pays its own boot.
script_timeout_ms =
  String.to_integer(System.get_env("ALLM_EXAMPLE_TIMEOUT_MS", "180000"))

scripts =
  Path.wildcard(Path.join(__DIR__, "[0-9][0-9]_*.exs"))
  |> Enum.sort()

results =
  Enum.map(scripts, fn path ->
    contents = File.read!(path)

    allowed_providers =
      case Regex.run(provider_marker_regex, contents) do
        nil ->
          :any

        [_, names] ->
          names
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
      end

    if allowed_providers == :any or provider in allowed_providers do
      IO.puts("--- #{Path.basename(path)} ---")
      {path, RunAll.run_script(path, script_timeout_ms)}
    else
      IO.puts("[SKIP] #{Path.basename(path)} (provider gate)")
      {path, :skip}
    end
  end)

failed = Enum.filter(results, fn {_, status} -> status not in [:ok, :skip] end)

IO.puts("\n=== Summary (provider: #{provider}) ===")

Enum.each(results, fn {path, status} ->
  marker =
    case status do
      :ok -> "[OK]  "
      :skip -> "[SKIP]"
      _ -> "[FAIL]"
    end

  detail =
    case status do
      {:error, {:exit_status, n}} -> " (exit #{n})"
      {:error, :timeout} -> " (timed out after #{div(script_timeout_ms, 1000)}s)"
      _ -> ""
    end

  IO.puts("#{marker} #{Path.basename(path)}#{detail}")
end)

if failed != [], do: System.halt(1)
