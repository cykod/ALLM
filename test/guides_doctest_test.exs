defmodule GuidesDoctestTest do
  use ExUnit.Case, async: true

  # Phase 3 (§31): execute every Fake-based `iex>` block in the bundled guides
  # as a doctest, so a wrong signature in a guide is a red test, not a silent
  # ship. `doctest_file/1` runs only `iex>` blocks; ` ```elixir ` fenced blocks
  # (real-provider illustrations) are ignored, so provider-key-dependent
  # snippets stay safe. Fake's per-engine cursor (fact 13) keeps `async: true`
  # safe — parallel guide doctests don't share cursor state.
  doctest_file("guides/getting_started.md")
  doctest_file("guides/sessions.md")
  doctest_file("guides/tools.md")
  doctest_file("guides/streaming.md")
  doctest_file("guides/vision.md")
  doctest_file("guides/image_generation.md")
  doctest_file("guides/errors_and_retries.md")
  doctest_file("guides/multi_tenant_keys.md")
  doctest_file("guides/embeddings.md")
end
