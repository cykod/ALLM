defmodule GuidesTest do
  @moduledoc """
  Verifies the `guides/` ExDoc extras directory.

  Asserts each guide:
    * exists on disk
    * is non-trivial (>2KB)
    * passes the banned-token audit (zero hits)
    * contains at least one runnable `iex>` code block
    * is wired into both `mix.exs` `docs[:extras]` AND `package[:files]`

  and, across the whole registered set, that every ` ```elixir ` fence compiles
  (`scripts/check_guide_fences.exs`). See the `fenced blocks` describe block for
  what that gate does and does not bind.
  """

  use ExUnit.Case, async: true

  @repo_root Path.expand("../", __DIR__)
  @script_path Path.expand("../scripts/audit_user_docs.exs", __DIR__)
  @fence_script_path Path.expand("../scripts/check_guide_fences.exs", __DIR__)

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
    Code.require_file(@fence_script_path)
    :ok
  end

  # Resolve the auditor module at call time to avoid compile-time
  # "module not available" warnings for the `Code.require_file/1`-loaded
  # script (same idiom as `Scripts.AuditUserDocsTest`).
  defp auditor, do: Module.concat(["Scripts", "AuditUserDocs"])
  defp fence_checker, do: Module.concat(["Scripts", "CheckGuideFences"])

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

  # ---------------------------------------------------------------------------
  # Fenced-block gate.
  #
  # `test/guides_doctest_test.exs` runs each guide's indented `iex>` blocks
  # through `ExUnit.DocTest.doctest_file/1`, which ignores fences entirely, so a
  # ` ```elixir ` fence ships to hexdocs with no execution and no reference
  # checking. Phase 22.6 shipped `guides/moderation.md`'s flagship recipe with a
  # `with`-clause binding referenced from its `else` block — a hard
  # `CompileError` — and it took four review agents reading the block to find it.
  #
  # WHAT THIS GATE BINDS: syntax, unbound variables (including that `with`/`else`
  # shape), struct literals naming a key the struct lacks, and bad local arity.
  #
  # WHAT IT DOES NOT BIND, stated because a control that over-claims its coverage
  # is the exact defect Phase 22.7 spent a batch removing from `CLAUDE.md`:
  # runtime behaviour of any kind. `%ALLM.Response{}` has no `:content` field,
  # and `response.content` compiles clean and raises `KeyError` only when run —
  # the second defect this run hit, which this gate would NOT have caught. Both
  # claims are pinned by the two negative-control tests below rather than
  # asserted in prose. The stronger control remains CLAUDE.md's own rule: prefer
  # an `iex>` block for anything `ALLM.Providers.Fake` can run.
  # ---------------------------------------------------------------------------

  describe "fenced blocks" do
    test "every ```elixir fence in every registered guide compiles" do
      {failures, _skipped, checked} = fence_checker().check()

      assert failures == [],
             "fences that do not compile (run " <>
               "`mix run scripts/check_guide_fences.exs` for the full report):\n" <>
               Enum.map_join(failures, "\n", fn {fence, message} ->
                 "  #{fence.guide}:#{fence.line} — #{message}"
               end)

      assert checked > 0, "expected at least one non-skipped fence to be checked"
    end

    test "every fence-check skip pragma carries a reason" do
      {_failures, skipped, _checked} = fence_checker().check()

      unreasoned = Enum.filter(skipped, &(String.trim(&1.skip) == ""))

      assert unreasoned == [],
             "a `fence-check: skip` pragma must say why the fence cannot compile " <>
               "standalone, so the opt-out stays auditable: " <>
               Enum.map_join(unreasoned, ", ", &"#{&1.guide}:#{&1.line}")
    end

    test "no fence is skipped that would compile anyway" do
      {_failures, skipped, _checked} = fence_checker().check()

      # An opt-out list only stays honest if every entry is still earning its
      # place. Without this, a fence fixed years after its pragma was written
      # keeps the pragma forever and the skip count only ever grows — the same
      # hand-maintained-literal decay `@guides` above has parity tests for.
      needless =
        Enum.filter(skipped, fn fence ->
          fence_checker().compile_fence(%{fence | skip: nil}) == :ok
        end)

      assert needless == [],
             "these fences carry a `fence-check: skip` pragma but compile fine " <>
               "now — delete the pragma: " <>
               Enum.map_join(needless, ", ", &"#{&1.guide}:#{&1.line}")
    end

    # Negative control #1 — the gate is not vacuous.
    #
    # The exact fence Phase 22.6 shipped, recovered from
    # `git show 4efb37c:guides/moderation.md` (tag `wip/22-6-checkpoint`,
    # lines 425-435). If this stops going red, the gate has stopped binding.
    test "the gate goes red on the fence that motivated it" do
      body = """
      def reply(engine, user_text) do
        with {:ok, verdict} <- ALLM.moderate(engine, user_text),
             false <- ALLM.ModerationResponse.flagged?(verdict) do
          ALLM.generate(engine, ALLM.request([%ALLM.Message{role: :user, content: user_text}]))
        else
          true -> {:error, {:rejected, ALLM.ModerationResponse.flagged_categories(verdict)}}
          {:error, _} = error -> error
        end
      end
      """

      fence = %{guide: "guides/negative_control.md", line: 1, body: body, skip: nil}

      assert {:error, message} = fence_checker().compile_fence(fence)
      assert message =~ "verdict"
    end

    # Negative control #2 — the free-variable preamble does not swallow it.
    #
    # Every one of this repo's guides carries fences that read `engine`,
    # `request` or `session` from an earlier block; the checker binds those to
    # `nil` rather than reporting them, which is the only reason the gate has 14
    # skips instead of 54. This test pins the discriminator: a name the fence
    # never binds is carried in (green), a name the fence binds and then reads
    # out of scope is a defect (red, above).
    test "a name the fence never binds is treated as carried in from an earlier block" do
      body = "ALLM.generate(engine, request)\n"
      fence = %{guide: "guides/negative_control.md", line: 1, body: body, skip: nil}

      assert :ok = fence_checker().compile_fence(fence)
    end

    # Boundary control — the documented limit, pinned rather than asserted.
    #
    # `%ALLM.Response{}` has no `:content` field. Phase 22.7 hit exactly this in
    # `guides/fakes.md`; it was caught by converting the fence to an `iex>`
    # doctest, NOT by compilation, and this gate would not have caught it either.
    # If Elixir ever grows inference that makes this red, delete this test and
    # widen the coverage claim in the moduledoc above — do not leave the claim
    # understated once it stops being true.
    test "the gate does NOT bind runtime struct-field access" do
      body = """
      def go(%ALLM.Response{} = response) do
        response.content
      end
      """

      fence = %{guide: "guides/negative_control.md", line: 1, body: body, skip: nil}

      assert :ok = fence_checker().compile_fence(fence),
             "dot access on a missing struct field now fails to compile — the " <>
               "gate binds more than its moduledoc claims; widen the claim"
    end

    # A struct LITERAL naming a missing key does fail at compile time, which is
    # the adjacent case, and the reason the boundary above is about dot access
    # specifically rather than about structs in general.
    test "the gate DOES bind struct literals naming a missing key" do
      body = "%ALLM.Response{content: \"x\"}\n"
      fence = %{guide: "guides/negative_control.md", line: 1, body: body, skip: nil}

      assert {:error, message} = fence_checker().compile_fence(fence)
      assert message =~ "content"
    end
  end
end
