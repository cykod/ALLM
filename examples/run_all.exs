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

Application.ensure_all_started(:allm)
Code.require_file("_helpers.exs", __DIR__)

# Surface the active provider up-front so the run output is self-describing.
provider = System.get_env("ALLM_PROVIDER", "openai")
IO.puts("=== Provider: #{provider} ===")

# Provider-marker grammar (closed): one optional `# Provider: <names>` line
# anywhere in the file; comma-separated provider names; matched as a whole
# line. Script with no marker runs on every provider.
provider_marker_regex = ~r/^#\s*Provider:\s*([\w, ]+)\s*$/m

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
      task = Task.async(fn -> Code.eval_file(path) end)

      case Task.yield(task, 60_000) || Task.shutdown(task, :brutal_kill) do
        {:ok, _} -> {path, :ok}
        {:exit, reason} -> {path, {:error, reason}}
        nil -> {path, {:error, :timeout}}
      end
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

  IO.puts("#{marker} #{Path.basename(path)}")
end)

if failed != [], do: System.halt(1)
