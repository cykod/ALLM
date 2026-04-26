# examples/run_all.exs
#
# Runs every numbered example under examples/ in order against the active
# provider. Exits 0 if all succeed, 1 if any failed.
# Used by the Phase 11 /review validation step (run twice — once per provider).
#
# Run with:    OPENAI_API_KEY=sk-... mix run examples/run_all.exs                                # default
#         OR:  ANTHROPIC_API_KEY=sk-ant-... ALLM_PROVIDER=anthropic mix run examples/run_all.exs

Application.ensure_all_started(:allm)
Code.require_file("_helpers.exs", __DIR__)

# Surface the active provider up-front so the run output is self-describing.
provider = System.get_env("ALLM_PROVIDER", "openai")
IO.puts("=== Provider: #{provider} ===")

scripts =
  Path.wildcard(Path.join(__DIR__, "[0-9][0-9]_*.exs"))
  |> Enum.sort()

results =
  Enum.map(scripts, fn path ->
    IO.puts("--- #{Path.basename(path)} ---")
    task = Task.async(fn -> Code.eval_file(path) end)

    case Task.yield(task, 60_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, _} -> {path, :ok}
      {:exit, reason} -> {path, {:error, reason}}
      nil -> {path, {:error, :timeout}}
    end
  end)

failed = Enum.filter(results, fn {_, status} -> status != :ok end)

IO.puts("\n=== Summary (provider: #{provider}) ===")

Enum.each(results, fn {path, status} ->
  marker = if status == :ok, do: "[OK]  ", else: "[FAIL]"
  IO.puts("#{marker} #{Path.basename(path)}")
end)

if failed != [], do: System.halt(1)
