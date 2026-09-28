{:ok, _started} = Application.ensure_all_started(:allm)

# The 8-tool compact-tools fixture is plain data shared with `examples/`
# (which cannot see `test/support/`). Required once here so test modules
# don't redefine `CompactToolsFixture`.
Code.require_file("../examples/fixtures/compact_tools.exs", __DIR__)

# Exclude `:pending` by default so `@tag :pending` actually suspends tests on
# plain `mix test`. ExUnit precedence: `include` beats `exclude`, so a test
# tagged (or moduletagged) `:spec_31` will still run under `mix test --only
# spec_31` even if it also carries `:pending` — i.e., `--only spec_31` shows
# all §31 scenarios including the deferred placeholders, while a bare `mix
# test` excludes them. See `fake_scenarios_test.exs` for the idiom.
#
# `capture_log: true` buffers every test's log output and replays it ONLY when
# that test fails. Adapters legitimately log at `:debug` on well-tested paths
# (`ImagePart.detail` drops, `task_type` omissions, stripped orchestration
# opts) and one tool-runner test deliberately crashes a `Task`, so an
# uncaptured run interleaves ~25 log lines with the progress dots. This keeps a
# green run quiet WITHOUT losing diagnostics on red — and it composes with the
# explicit `ExUnit.CaptureLog.capture_log/2` calls that assert on log content
# (ExUnit supports nested capture).
#
# `assert_receive_timeout: 1_000` raises ExUnit's 100 ms default for every
# `assert_receive/2` without an explicit timeout. The value only bounds how
# long a PASSING assertion may wait, so it costs nothing on green; under a
# loaded `async: true` suite 100 ms was too short for process-hop tests
# (`input_pump_test.exs` flaked one line at a time across two batches).
# `refute_receive/3` has its own default (`refute_receive_timeout`, 100 ms),
# untouched here, so no refute window changes.
live_tags = [:live_openai, :live_anthropic, :live_gemini, :live_openai_images]

ExUnit.start(
  exclude: [:pending | live_tags],
  capture_log: true,
  assert_receive_timeout: 1_000
)

# The default suite never makes a live provider call. Keys resolve only through
# `ALLM.Keys` (opts → runtime store → app config → `*_API_KEY` env → `.env`
# when `load_dotenv: true`), so removing every ambient source here makes
# "keyless" a property of the run rather than of the developer's shell. Without
# it, a shell with `.env` sourced (the repo's documented key mechanism) let
# keyless `assert_raise EngineError` tests reach HTTP with a real key. This runs
# once, before any test module loads, so it is not a mid-suite global mutation.
# Only an explicit `--only live_*` / `--include live_*` run keeps the keys —
# that is the eval suite, and the `live_*` modules skip themselves when their
# key is absent.
unless Enum.any?(ExUnit.configuration()[:include], &(&1 in live_tags)) do
  for {name, _value} <- System.get_env(), String.ends_with?(name, "_API_KEY") do
    System.delete_env(name)
  end

  Application.put_env(:allm, :keys, %{})
  Application.put_env(:allm, :load_dotenv, false)
end
