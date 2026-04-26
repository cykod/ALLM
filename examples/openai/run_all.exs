# examples/openai/run_all.exs
#
# Runs every numbered example under examples/openai/ in order.
# Exits 0 if all succeed, 1 if any failed.
# Used by the Phase 10 /review validation step.

# Auto-load OPENAI_API_KEY from project-root .env if not already in env.
if System.get_env("OPENAI_API_KEY") in [nil, ""], do: EnvLoader.load(Path.expand(".env", Path.join(__DIR__, "../..")))

Application.ensure_all_started(:allm)

scripts =
  Path.wildcard("examples/openai/[0-9][0-9]_*.exs")
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

IO.puts("\n=== Summary ===")

Enum.each(results, fn {path, status} ->
  marker = if status == :ok, do: "[OK]  ", else: "[FAIL]"
  IO.puts("#{marker} #{Path.basename(path)}")
end)

if failed != [], do: System.halt(1)
