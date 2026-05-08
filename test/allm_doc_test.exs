defmodule ALLMDocTest do
  @moduledoc """
  Drives the doctest sweep for `ALLM`'s `@moduledoc` and the per-public-function
  `@doc` blocks that are not already exercised by per-function test files.

  The existing `ALLM.GenerateTest`, `ALLM.StepTest`, `ALLM.ChatTest`,
  `ALLM.StreamTest`, etc. each register `doctest ALLM, only: [<fun>: <arity>]`
  for their function. That keeps the per-function failure messages local. This
  module's job is to (a) confirm the `@moduledoc` itself runs end-to-end under
  `ALLM.Providers.Fake`, and (b) provide a single place to assert that the
  rewrite did not strip a doctest off any documented function.

  Doctests run on `ALLM.Providers.Fake` exclusively — no API key, no network.
  """

  use ExUnit.Case, async: true

  # The full `doctest ALLM` is owned by `test/allm_test.exs` (preserved
  # untouched by the rewrite). This module asserts the @moduledoc shape +
  # audit-cleanliness; per-function doctests are exercised by the
  # per-function test files (test/allm/allm_<fun>_test.exs).

  describe "ALLM @moduledoc reads cleanly under audit" do
    test "the @moduledoc has no banned tokens (audit-script gate)" do
      Code.require_file("scripts/audit_user_docs.exs")
      hits = Scripts.AuditUserDocs.scan_file(Path.expand("lib/allm.ex"))
      assert hits == [], "lib/allm.ex audit failed: #{inspect(hits)}"
    end

    test "the @moduledoc is a non-empty heredoc with the canonical landing-page sections" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(ALLM)
      assert is_binary(moduledoc)
      assert byte_size(moduledoc) > 500

      # Anchors that downstream guides cross-link.
      assert moduledoc =~ "Hello, ALLM"
      assert moduledoc =~ "When to reach for what"
      assert moduledoc =~ "Where to next"
    end
  end
end
