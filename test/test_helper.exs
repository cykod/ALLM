{:ok, _started} = Application.ensure_all_started(:allm)

# Exclude `:pending` by default so `@tag :pending` actually suspends tests on
# plain `mix test`. ExUnit precedence: `include` beats `exclude`, so a test
# tagged (or moduletagged) `:spec_31` will still run under `mix test --only
# spec_31` even if it also carries `:pending` — i.e., `--only spec_31` shows
# all §31 scenarios including the deferred placeholders, while a bare `mix
# test` excludes them. See `fake_scenarios_test.exs` for the idiom.
ExUnit.start(exclude: [:pending, :live_openai, :live_anthropic, :live_openai_images])
