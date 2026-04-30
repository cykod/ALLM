defmodule ALLM.ReleasePolishTest do
  @moduledoc """
  Smoke-style assertions that the v0.3.0 release infrastructure is in
  place per Phase 17.3 of `steering/PHASE_17_image_layer_7.md` §17.3.1.

  These are not behavioural tests on library code — they are structural
  assertions on the repo files (`mix.exs`, `CHANGELOG.md`,
  `examples/_helpers.exs`, `examples/run_all.exs`, three new example
  scripts) that the release polish step is complete. The Definition of
  Done in §9 calls for `mix.exs @version "0.3.0"`, CHANGELOG rollup,
  vision-default-model in the helpers, and the three new example
  scripts wired into the suite via the marker-driven `run_all.exs`.

  All assertions are repo-file lookups; no network, no provider, no
  process dictionary.
  """

  use ExUnit.Case, async: true

  @project_root Path.expand("../..", __DIR__)
  @mix_exs Path.join(@project_root, "mix.exs")
  @changelog Path.join(@project_root, "CHANGELOG.md")
  @helpers Path.join(@project_root, "examples/_helpers.exs")
  @run_all Path.join(@project_root, "examples/run_all.exs")

  describe "mix.exs version" do
    test "@version is bumped to 0.3.0" do
      assert File.read!(@mix_exs) =~ ~s(@version "0.3.0")

      refute File.read!(@mix_exs) =~ ~s(@version "0.2.0"),
             "mix.exs still contains @version \"0.2.0\" — bump to 0.3.0"
    end
  end

  describe "CHANGELOG v0.3.0 rollup" do
    test "Phase 17.1, 17.2, 17.3 entries are present" do
      contents = File.read!(@changelog)

      assert contents =~ "Phase 17.1",
             "CHANGELOG missing Phase 17.1 entry"

      assert contents =~ "Phase 17.2",
             "CHANGELOG missing Phase 17.2 entry"

      assert contents =~ "Phase 17.3",
             "CHANGELOG missing Phase 17.3 entry"
    end

    test "v0.3.0 rollup header is present" do
      contents = File.read!(@changelog)

      assert contents =~ "v0.3.0",
             "CHANGELOG missing v0.3.0 rollup header"
    end
  end

  describe "examples/_helpers.exs @providers" do
    test "openai row carries :vision_default_model" do
      contents = File.read!(@helpers)

      assert contents =~ ~s(vision_default_model: "gpt-4o-mini"),
             "examples/_helpers.exs openai row missing :vision_default_model — \"gpt-4o-mini\""
    end

    test "anthropic row carries :vision_default_model" do
      contents = File.read!(@helpers)

      assert contents =~ ~s(vision_default_model: "claude-haiku-4-5-20251001"),
             "examples/_helpers.exs anthropic row missing :vision_default_model — " <>
               "\"claude-haiku-4-5-20251001\""
    end

    test "engine/1 supports the vision: true opt (Decision #8)" do
      contents = File.read!(@helpers)

      assert contents =~ ~r/Keyword\.pop\(extra_opts,\s*:vision/,
             "examples/_helpers.exs engine/1 missing :vision opt extraction"
    end
  end

  describe "examples/run_all.exs registers Phase 17.3 scripts" do
    test "11_edit_image.exs is on disk and has openai-only provider marker" do
      path = Path.join(@project_root, "examples/11_edit_image.exs")
      assert File.exists?(path), "examples/11_edit_image.exs missing"
      assert File.read!(path) =~ ~r/^#\s*Provider:\s*openai\s*$/m
    end

    test "12_vision_input.exs is on disk and has openai+anthropic provider marker" do
      path = Path.join(@project_root, "examples/12_vision_input.exs")
      assert File.exists?(path), "examples/12_vision_input.exs missing"
      assert File.read!(path) =~ ~r/^#\s*Provider:\s*openai,\s*anthropic\s*$/m
    end

    test "13_image_variations.exs is on disk and has openai-only provider marker" do
      path = Path.join(@project_root, "examples/13_image_variations.exs")
      assert File.exists?(path), "examples/13_image_variations.exs missing"
      assert File.read!(path) =~ ~r/^#\s*Provider:\s*openai\s*$/m
    end

    test "run_all.exs glob picks up two-digit numbered scripts" do
      contents = File.read!(@run_all)
      # Phase 15.6 scanner glob: [0-9][0-9]_*.exs — covers 11/12/13.
      assert contents =~ "[0-9][0-9]_*.exs"
      # Marker scanner regex still in place.
      assert contents =~ "Provider:"
      assert contents =~ "provider_marker_regex"
    end
  end

  describe "mix.exs package files vs docs extras (Phase 17.3 retro Finding 2)" do
    # ExDoc renders `extras:` files into hexdocs at publish time, but the Hex
    # source tarball is gated on `package[:files]` only — a file in `extras:`
    # but not in `:files` ships in hexdocs but NOT in the hex source download.
    # Assert :files is a superset of docs.extras so CHANGELOG.md (and any
    # future extra) lands in the published source tarball.
    test "package[:files] is a superset of docs[:extras]" do
      config = Mix.Project.config()
      files = config[:package][:files]
      extras = config[:docs][:extras]

      missing = Enum.reject(extras, fn extra -> extra in files end)

      assert missing == [],
             "mix.exs :package[:files] is missing docs[:extras] entries: " <>
               "#{inspect(missing)} — add to package.files so they ship in the hex tarball"
    end

    test "CHANGELOG.md is in package[:files]" do
      files = Mix.Project.config()[:package][:files]

      assert "CHANGELOG.md" in files,
             "mix.exs :package[:files] missing CHANGELOG.md — Hex source tarball would " <>
               "ship without it (Phase 17.3 retro Finding 2)"
    end
  end
end
