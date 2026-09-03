defmodule GuidesTest do
  @moduledoc """
  Verifies the `guides/` ExDoc extras directory.

  Asserts each guide:
    * exists on disk
    * is non-trivial (>2KB)
    * passes the banned-token audit (zero hits)
    * contains at least one runnable `iex>` code block
    * is wired into both `mix.exs` `docs[:extras]` AND `package[:files]`
  """

  use ExUnit.Case, async: true

  @repo_root Path.expand("../", __DIR__)
  @script_path Path.expand("../scripts/audit_user_docs.exs", __DIR__)

  @guides ~w(
    getting_started.md
    streaming.md
    tools.md
    sessions.md
    vision.md
    image_generation.md
    errors_and_retries.md
    multi_tenant_keys.md
    embeddings.md
    moderation.md
    fakes.md
  )

  # Guides deliberately exempt from the parity assertions below, as
  # `%{"name" => "reason"}`. Empty today, and that is the healthy state: an
  # entry here means a guide ships to hexdocs with no structural gate, which is
  # the fail-open hazard the parity tests exist to surface. The map keeps
  # opt-out possible and, more importantly, visible.
  @excluded %{}

  setup_all do
    Code.require_file(@script_path)
    :ok
  end

  # Resolve the auditor module at call time to avoid compile-time
  # "module not available" warnings for the `Code.require_file/1`-loaded
  # script (same idiom as `Scripts.AuditUserDocsTest`).
  defp auditor, do: Module.concat(["Scripts", "AuditUserDocs"])

  # The set this file structurally gates: registered, plus the deliberate
  # opt-outs.
  defp gated, do: @guides |> MapSet.new() |> MapSet.union(MapSet.new(Map.keys(@excluded)))

  # Read the shipped set off `docs[:extras]` rather than off `mix.exs`'s own
  # `@guides` attribute: the attribute is unreadable post-compile, and
  # `docs[:extras]` is what ExDoc actually publishes.
  defp mix_guides do
    (Mix.Project.config()[:docs][:extras] || [])
    |> Enum.filter(&String.starts_with?(&1, "guides/"))
    |> Enum.map(&Path.basename/1)
    |> MapSet.new()
  end

  describe "every guide" do
    for guide <- @guides do
      @guide guide

      test "guide #{@guide} exists on disk" do
        path = Path.join([@repo_root, "guides", @guide])
        assert File.regular?(path), "expected guide at #{path}"
      end

      test "guide #{@guide} is non-trivial (>2KB)" do
        path = Path.join([@repo_root, "guides", @guide])
        %File.Stat{size: size} = File.stat!(path)
        assert size > 2 * 1024, "expected >2KB, got #{size} bytes"
      end

      test "guide #{@guide} passes the banned-token audit" do
        path = Path.join([@repo_root, "guides", @guide])
        {:ok, hits, _summary} = auditor().run_audit([path])

        assert hits == [],
               "expected zero banned-token hits in #{@guide}, got: " <>
                 inspect(hits, pretty: true, limit: :infinity)
      end

      test "guide #{@guide} contains at least one iex> code block" do
        path = Path.join([@repo_root, "guides", @guide])
        content = File.read!(path)

        assert Regex.match?(~r/^\s*iex>/m, content),
               "expected at least one `iex>` line in #{@guide}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Parity meta-tests.
  #
  # `@guides` above is a hand-maintained literal, and an unregistered guide
  # produces silence rather than a failure — every per-guide gate in this file
  # binds only on a listed name. These four tests assert the literal against
  # discovered sets in both directions, so a guide that is added to `mix.exs`
  # (or dropped on disk) and forgotten here goes red instead of shipping
  # ungated. Measured origin: `guides/fakes.md` was created and registered in
  # `mix.exs` by `85f45d8` (Phase 21, 2026-05-25) and never added to the literal
  # here, so it shipped to hexdocs from Phase 21 to Phase 22 carrying four
  # banned-token audit hits and zero `iex>` blocks the whole time. (The ticket
  # that commissioned these tests said "since Phase 16"; what settles it is
  # `git log --follow --diff-filter=AR -- guides/fakes.md` and
  # `git log -S 'guides/fakes.md' -- mix.exs`, each returning only `85f45d8`.)
  #
  # Note the fourth test below is one-directional by design: it asserts
  # `@guides` is a subset of the `doctest_file/1` call list, not the converse.
  # A stray registration means extra execution, not a missed gate.
  # ---------------------------------------------------------------------------

  describe "@guides parity" do
    test "every guide mix.exs publishes is gated here" do
      missing = MapSet.difference(mix_guides(), gated())

      assert MapSet.equal?(missing, MapSet.new()),
             "these guides are in mix.exs docs[:extras] but neither in @guides nor " <>
               "@excluded, so they ship to hexdocs with no >2KB check, no banned-token " <>
               "audit and no `iex>` requirement: " <> inspect(MapSet.to_list(missing))
    end

    test "every guide gated here is one mix.exs publishes" do
      stale = MapSet.difference(gated(), mix_guides())

      assert MapSet.equal?(stale, MapSet.new()),
             "these names are gated here but absent from mix.exs docs[:extras], so the " <>
               "gate binds on a guide that never ships: " <> inspect(MapSet.to_list(stale))
    end

    test "every guide on disk is accounted for" do
      on_disk =
        [@repo_root, "guides", "*.md"]
        |> Path.join()
        |> Path.wildcard()
        |> Enum.map(&Path.basename/1)
        |> MapSet.new()

      unaccounted = MapSet.difference(on_disk, gated())

      assert MapSet.equal?(unaccounted, MapSet.new()),
             "these files exist under guides/ but appear in neither @guides nor " <>
               "@excluded: " <> inspect(MapSet.to_list(unaccounted))
    end

    test "every guide is registered with doctest_file/1" do
      source = File.read!(Path.join([@repo_root, "test", "guides_doctest_test.exs"]))

      for guide <- @guides do
        assert source =~ ~s|doctest_file("guides/#{guide}")|,
               "expected `doctest_file(\"guides/#{guide}\")` in " <>
                 "test/guides_doctest_test.exs — without it the guide's `iex>` blocks " <>
                 "are never executed and this file's `iex>` gate binds on nothing"
      end
    end
  end

  describe "mix.exs wiring" do
    test "every guide is in docs[:extras]" do
      docs = Mix.Project.config()[:docs]
      extras = docs[:extras] || []

      for guide <- @guides do
        path = "guides/" <> guide

        assert path in extras,
               "expected #{path} in docs[:extras], got: " <> inspect(extras)
      end
    end

    test "guides are grouped under \"Guides\" in groups_for_extras" do
      docs = Mix.Project.config()[:docs]
      groups = docs[:groups_for_extras] || []

      # Tuple form: [{"Guides", paths}]
      assert is_list(groups), "expected groups_for_extras to be a list"

      guides_group =
        Enum.find(groups, fn
          {"Guides", _} -> true
          _ -> false
        end)

      assert guides_group, "expected a {\"Guides\", _} entry in groups_for_extras"

      {_, paths} = guides_group

      for guide <- @guides do
        path = "guides/" <> guide

        assert path in paths,
               "expected #{path} in the Guides group, got: " <> inspect(paths)
      end
    end

    test "package[:files] declares the guides directory" do
      package = Mix.Project.config()[:package]
      files = package[:files] || []

      assert "guides" in files,
             "expected \"guides\" entry in package[:files] (Hex recurses), got: " <>
               inspect(files)
    end
  end
end
