# scripts/release.exs — ALLM Hex release script
#
# Usage
# -----
#
#     mix run scripts/release.exs patch          # 0.3.0 -> 0.3.1
#     mix run scripts/release.exs minor          # 0.3.0 -> 0.4.0
#     mix run scripts/release.exs major          # 0.3.0 -> 1.0.0
#     mix run scripts/release.exs 0.4.0-rc.1     # explicit SemVer
#     mix run scripts/release.exs --help
#
# Flags
# -----
#
#     --skip-dialyzer   Skip `mix dialyzer` (PLT is slow; OK for patches you
#                       just ran dialyzer against).
#     --dry-run         Run every gate including `mix hex.publish --dry-run`,
#                       stop before the real publish + tag. No working-tree
#                       mutations.
#     --allow-dirty     Bypass the working-tree-clean check. Loud warning.
#
# Setup (one-time, per maintainer workstation)
# --------------------------------------------
#
# Hex auth lives in `~/.hex/hex.config`. There is no `HEX_API_KEY` env var,
# no GitHub Actions secret, no shared key in any secrets manager. Releases
# are local-only by design (no CI automation).
#
#     mix hex.user whoami           # confirm cykod
#     mix hex.user auth             # log in if needed (interactive; 2FA if enrolled)
#     mix hex.user register         # only if cykod doesn't yet exist on hex.pm
#
# 2FA on the cykod account is recommended. Enroll via the hex.pm web UI
# under Account -> Two-factor authentication. There is no Mix task for 2FA
# enrollment. After enrollment, every `mix hex.publish` prompts for a TOTP
# code.
#
# Hotfix runbook (broken release)
# -------------------------------
#
# 1. Within 24 hours of the FIRST-EVER publish of `allm`:
#
#        mix hex.publish --revert 0.3.0
#
#    Fully removes from hex.pm. Use only if dangerously broken (corrupted
#    .beam, accidentally-included secret).
#
# 2. For any subsequent version (0.3.1, 0.4.0, ...): the revert window
#    narrows to **1 hour** after that version's publish.
#
# 3. After the revert window closes you cannot revert. Choices:
#
#    - Soft retire:
#
#          mix hex.retire allm 0.3.0 invalid \
#            --message "Use 0.3.1, contains <bug>"
#
#      Package stays installable but Hex shows a warning. `--message`
#      required (<= 140 chars). Valid reasons: `renamed`, `deprecated`,
#      `security`, `invalid`, `other`.
#
#    - Patch forward: ship 0.3.1 with the fix, mark 0.3.0 retired.
#
# Never `git commit --amend` past a release tag. Once `v0.3.0` is tagged
# and pushed the commit is immutable; any fix is `v0.3.1`. The script's
# idempotent-re-run path (mix.exs already at target -> skip the bump)
# handles "publish failed mid-flight, fix and re-run" without amending.
#
# Co-maintainer onboarding
# ------------------------
#
#     # Run by current owner (cykod):
#     mix hex.owner add allm <new-maintainer-email>
#     mix hex.owner list allm
#
# Each new maintainer authenticates from their own workstation
# (`mix hex.user auth` -> their own `~/.hex/hex.config`; no shared key)
# and runs `mix run scripts/release.exs <bump>` from there.
#
# Major-version bump checklist (v1.0.0)
# -------------------------------------
#
# - CHANGELOG entry enumerates every closed-union variant added, every
#   behaviour signature changed, every struct field removed/renamed.
# - README "Getting Started" updates `~> 0.X` to `~> 1.0`.
# - Open a deprecation policy doc (`DEPRECATION.md`) — what `0.x` users get
#   for migration time.
# - Optional: tag `v1.0.0-rc.1` first, sit on it for two weeks, gather
#   feedback.
#
# What this script does NOT do
# ----------------------------
#
# - Does NOT skip the `mix hex.publish` interactive confirmation. Hex
#   prompts ARE part of the safety story. Never `--yes`.
# - Does NOT publish from CI. There is no `--non-interactive` mode by
#   design.
# - Does NOT auto-edit CHANGELOG content. Before running this script the
#   maintainer runs the `/changelog` skill, which regenerates
#   `CHANGELOG.md` with one succinct entry per shipped version (e.g.,
#   `## v0.3.0 — Multimodal foundation`, or the bare `## v0.3.1`). This
#   script verifies that a `## ` heading line containing the literal
#   `v<X.Y.Z>` exists, then commits `CHANGELOG.md` as part of the release
#   commit. Per-commit history lives in `HISTORY.md` (dev-only, NOT in
#   `mix.exs` `package.files`). There is no `## [Unreleased]` rewrite.
# - Does NOT push to origin before the publish succeeds. Order is
#   publish-first, commit+tag+push-after, so a failed publish leaves no
#   stranded artifacts.
# - Does NOT run the live-API gate (`examples/run_all.exs`). Those cost
#   real money. The maintainer runs them manually before invoking this
#   script when image/vision code has changed; the script merely WARNS
#   when image-touching files are in the diff since the last release tag.
#
# Spec: see `steering/RELEASE_PLAN.md` (Phase 3 + Phase 4).

defmodule ALLM.Release do
  @moduledoc false

  @mix_exs_path "mix.exs"
  @changelog_path "CHANGELOG.md"

  def main(argv) do
    case parse_args(argv) do
      :help ->
        print_help()
        System.halt(0)

      {:ok, opts} ->
        run(opts)

      {:error, msg} ->
        IO.puts(:stderr, "ERROR: " <> msg)
        IO.puts(:stderr, "")
        print_help()
        System.halt(1)
    end
  end

  # ----- argument parsing ----------------------------------------------------

  defp parse_args([]), do: {:error, "missing version-bump argument"}

  defp parse_args(argv) do
    cond do
      "--help" in argv or "-h" in argv ->
        :help

      true ->
        {flags, positionals} = Enum.split_with(argv, &String.starts_with?(&1, "--"))

        with {:ok, bump} <- parse_bump(positionals),
             {:ok, opts} <- parse_flags(flags) do
          {:ok, Map.put(opts, :bump, bump)}
        end
    end
  end

  defp parse_bump([]), do: {:error, "missing version-bump argument"}
  defp parse_bump([single]), do: {:ok, single}
  defp parse_bump(many), do: {:error, "expected one positional arg, got #{inspect(many)}"}

  defp parse_flags(flags) do
    valid = ["--skip-dialyzer", "--dry-run", "--allow-dirty"]

    Enum.reduce_while(flags, {:ok, default_opts()}, fn flag, {:ok, acc} ->
      cond do
        flag == "--skip-dialyzer" -> {:cont, {:ok, %{acc | skip_dialyzer: true}}}
        flag == "--dry-run" -> {:cont, {:ok, %{acc | dry_run: true}}}
        flag == "--allow-dirty" -> {:cont, {:ok, %{acc | allow_dirty: true}}}
        true -> {:halt, {:error, "unknown flag: #{flag} (valid: #{Enum.join(valid, ", ")})"}}
      end
    end)
  end

  defp default_opts do
    %{skip_dialyzer: false, dry_run: false, allow_dirty: false}
  end

  defp print_help do
    IO.puts("""
    ALLM release script — drives `mix hex.publish` with full quality gates.

    Usage:
      mix run scripts/release.exs <bump> [flags]

    <bump>:
      patch          MAJOR.MINOR.(PATCH+1)
      minor          MAJOR.(MINOR+1).0
      major          (MAJOR+1).0.0
      <semver>       explicit version, e.g. 0.4.0-rc.1

    Flags:
      --skip-dialyzer   skip `mix dialyzer` (PLT slow)
      --dry-run         run every gate; stop before publish + tag; no mutations
      --allow-dirty     bypass git-clean check (loud warning)
      --help, -h        this message

    Spec: steering/RELEASE_PLAN.md (Phase 3 + Phase 4).
    """)
  end

  # ----- main flow -----------------------------------------------------------

  defp run(opts) do
    log_step("step 1", "compute new version from #{@mix_exs_path}")
    current = current_version()
    new_version = compute_new_version(current, opts.bump)
    IO.puts("  current: #{current}")
    IO.puts("  new:     #{new_version}")
    tag = "v#{new_version}"

    log_step("step 2", "git working tree clean?")
    check_working_tree(opts.allow_dirty)

    log_step("step 3", "on `main`?")
    check_branch()

    log_step("step 4", "up to date with origin/main?")
    check_up_to_date()

    log_step("step 5", "tag #{tag} doesn't already exist?")
    check_tag_absent(tag)

    log_step("step 6", "CHANGELOG entry for #{new_version}?")
    check_changelog(new_version)

    log_step("step 6b", "image-touching files in diff since last tag?")
    image_touch_warning(current)

    log_step("step 7", "quality gates")
    run_quality_gates(opts)

    # Idempotent re-run: if mix.exs is already at target, skip the bump (step 8).
    log_step("step 8", "bump @version in #{@mix_exs_path}")
    already_bumped? = current == new_version

    if already_bumped? do
      IO.puts("  mix.exs already at #{new_version}; skipping bump (idempotent re-run path)")
    else
      bump_mix_version!(new_version, opts.dry_run)
    end

    log_step("step 9b", "diff preview")
    show_diff()

    if opts.dry_run do
      IO.puts("")
      IO.puts("--- DRY RUN: stopping before mix hex.publish + tag ---")

      # Roll back any working-tree mutations done in dry-run mode.
      # (The bump branch above already short-circuits for dry-run, but
      # defensively run a checkout here so a partial edit is cleaned up.)
      rollback_edits(:dry_run)

      log_step("step 10", "would prompt: Publish allm #{new_version} to Hex? [y/N] (skipped)")
      log_step("step 11", "would run: mix hex.publish --dry-run")
      run_hex_publish_dry_run()
      log_step("step 12", "would commit + tag + push origin main #{tag} (skipped)")
      log_step("step 13", "would print success URLs (skipped)")
      System.halt(0)
    end

    log_step("step 10", "confirmation prompt #1")

    case prompt_yes_no("Publish allm #{new_version} to Hex? [y/N] ") do
      :yes ->
        :ok

      :no ->
        IO.puts("Aborted; rolling back mix.exs + CHANGELOG.md edits.")
        rollback_edits(:user_declined)
        System.halt(1)
    end

    log_step("step 11", "mix hex.publish (interactive)")
    publish_to_hex!()

    log_step("step 12", "git commit + tag + push")
    finalize_release!(new_version, tag)

    log_step("step 13", "done")
    print_success(new_version)
  end

  # ----- step 1: version computation -----------------------------------------

  defp current_version do
    Mix.Project.config()[:version]
  end

  defp compute_new_version(current, "patch"), do: bump_segment(current, :patch)
  defp compute_new_version(current, "minor"), do: bump_segment(current, :minor)
  defp compute_new_version(current, "major"), do: bump_segment(current, :major)

  defp compute_new_version(_current, explicit) do
    case Version.parse(explicit) do
      {:ok, %Version{} = v} -> to_string(v)
      :error -> abort("invalid version: #{inspect(explicit)} (must be patch|minor|major|<semver>)")
    end
  end

  defp bump_segment(current, segment) do
    case Version.parse(current) do
      {:ok, %Version{major: ma, minor: mi, patch: pa}} ->
        case segment do
          :patch -> "#{ma}.#{mi}.#{pa + 1}"
          :minor -> "#{ma}.#{mi + 1}.0"
          :major -> "#{ma + 1}.0.0"
        end

      :error ->
        abort("could not parse current version #{inspect(current)} from mix.exs")
    end
  end

  # ----- step 2-5: git gates -------------------------------------------------

  defp check_working_tree(true) do
    IO.puts("  --allow-dirty set: skipping clean-tree check (BE CAREFUL).")
  end

  defp check_working_tree(false) do
    {out, 0} = System.cmd("git", ["status", "--porcelain"])

    if out == "" do
      IO.puts("  clean")
    else
      IO.puts(:stderr, out)
      abort("git working tree is dirty; commit/stash or pass --allow-dirty")
    end
  end

  defp check_branch do
    {out, 0} = System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"])
    branch = String.trim(out)

    if branch == "main" do
      IO.puts("  on main")
    else
      abort("not on `main` (current: #{branch}); release must run from `main`")
    end
  end

  defp check_up_to_date do
    case System.cmd("git", ["fetch", "origin", "main"], stderr_to_stdout: true) do
      {_out, 0} ->
        :ok

      {out, code} ->
        IO.puts(:stderr, out)
        abort("git fetch origin main failed (exit #{code})")
    end

    {out, 0} = System.cmd("git", ["rev-list", "--count", "HEAD..origin/main"])

    behind = out |> String.trim() |> String.to_integer()

    if behind == 0 do
      IO.puts("  up to date")
    else
      abort("HEAD is #{behind} commit(s) behind origin/main; `git pull --rebase` first")
    end
  end

  defp check_tag_absent(tag) do
    case System.cmd("git", ["rev-parse", tag], stderr_to_stdout: true) do
      {_out, 0} ->
        abort("tag #{tag} already exists locally; bump again or delete the local tag")

      {_out, _nonzero} ->
        :ok
    end

    {out, 0} = System.cmd("git", ["ls-remote", "--tags", "origin", tag])

    if String.trim(out) != "" do
      abort("tag #{tag} already exists on origin; pick a different version")
    end

    IO.puts("  tag #{tag} is free")
  end

  # ----- step 6: CHANGELOG check ---------------------------------------------

  # `CHANGELOG.md` is regenerated by the `/changelog` skill, which the
  # maintainer runs BEFORE invoking this script. That skill produces one
  # succinct entry per shipped version, e.g. `## v0.3.0 — Multimodal
  # foundation` (or the bare form `## v0.3.1`). We only require that
  # SOME `## ` heading line contains the literal `v<X.Y.Z>`. There is no
  # `## [Unreleased]` rewrite. Per-commit history lives in `HISTORY.md`
  # (dev-only, NOT in `package.files`).
  defp check_changelog(new_version) do
    body = File.read!(@changelog_path)
    pattern = ~r/^##\s+.*v#{Regex.escape(new_version)}\b/m

    if Regex.match?(pattern, body) do
      IO.puts("  found `## ` heading containing `v#{new_version}`")
      :ok
    else
      abort(
        "CHANGELOG.md missing release notes heading for v#{new_version}. " <>
          "Run the `/changelog` skill to regenerate CHANGELOG.md with a heading " <>
          "for v#{new_version} (e.g., '## v#{new_version} — <summary>'), then re-run."
      )
    end
  end

  # ----- step 6b: image-touch warning ----------------------------------------

  defp image_touch_warning(current_version) do
    previous_tag = "v#{current_version}"

    case System.cmd("git", ["rev-parse", previous_tag], stderr_to_stdout: true) do
      {_out, 0} -> emit_image_warning_for_diff(previous_tag)
      {_out, _} -> IO.puts("  (no previous tag #{previous_tag}; skipping image-touch warning)")
    end
  end

  defp emit_image_warning_for_diff(previous_tag) do
    {out, 0} = System.cmd("git", ["diff", "#{previous_tag}..HEAD", "--name-only"])

    image_files =
      out
      |> String.split("\n", trim: true)
      |> Enum.filter(fn path ->
        String.contains?(path, "lib/allm/providers/") and
          (String.contains?(path, "image") or String.contains?(path, "Image"))
      end)
      |> Kernel.++(
        out
        |> String.split("\n", trim: true)
        |> Enum.filter(fn path ->
          String.starts_with?(path, "lib/allm/image")
        end)
      )
      |> Enum.uniq()

    if image_files == [] do
      IO.puts("  no image-touching files in diff since #{previous_tag}")
    else
      IO.puts(:stderr, "")

      IO.puts(
        :stderr,
        "WARNING: image-touching files changed since #{previous_tag}: " <>
          Enum.join(image_files, ", ")
      )

      IO.puts(
        :stderr,
        "         Run `mix run examples/run_all.exs` against live keys " <>
          "BEFORE publishing (see RELEASE_PLAN.md §0)."
      )

      IO.puts(:stderr, "")
    end
  end

  # ----- step 7: quality gates -----------------------------------------------

  defp run_quality_gates(opts) do
    gates = [
      {"mix format --check-formatted", ["format", "--check-formatted"]},
      {"mix deps.get", ["deps.get"]},
      {"mix test", ["test"]},
      {"mix credo --strict", ["credo", "--strict"]},
      {"mix hex.build", ["hex.build"]}
    ]

    gates =
      if opts.skip_dialyzer do
        IO.puts("  --skip-dialyzer set: dialyzer gate skipped")
        gates
      else
        List.insert_at(gates, -2, {"mix dialyzer", ["dialyzer"]})
      end

    Enum.each(gates, fn {label, args} ->
      IO.puts("  -> #{label}")

      case System.cmd("mix", args, stderr_to_stdout: true) do
        {_out, 0} ->
          :ok

        {out, code} ->
          IO.puts(:stderr, out)
          abort("#{label} failed (exit #{code}); fix and re-run (working tree NOT mutated)")
      end
    end)
  end

  # ----- step 8: bump mix.exs -----------------------------------------------

  defp bump_mix_version!(new_version, dry_run?) do
    body = File.read!(@mix_exs_path)
    pattern = ~r/(@version\s+")[^"]+(")/

    unless Regex.match?(pattern, body) do
      abort("could not find `@version \"...\"` in #{@mix_exs_path}")
    end

    new_body = Regex.replace(pattern, body, "\\1#{new_version}\\2", global: false)

    cond do
      new_body == body ->
        IO.puts("  no change (already #{new_version})")

      dry_run? ->
        IO.puts("  [dry-run] would write #{@mix_exs_path} with @version \"#{new_version}\"")

      true ->
        File.write!(@mix_exs_path, new_body)
        IO.puts("  bumped @version -> #{new_version}")
    end
  end

  # ----- step 9b: diff preview ----------------------------------------------

  defp show_diff do
    case System.cmd("git", ["diff", "--", @mix_exs_path, @changelog_path]) do
      {"", 0} ->
        IO.puts("  (no diff in mix.exs / CHANGELOG.md)")

      {out, 0} ->
        IO.puts("")
        IO.puts(out)
        IO.puts("")
    end
  end

  # ----- step 10: confirmation prompt ---------------------------------------

  defp prompt_yes_no(prompt) do
    case IO.gets(prompt) do
      :eof ->
        :no

      {:error, _} ->
        :no

      input when is_binary(input) ->
        normalize_yes_no(input)
    end
  end

  defp normalize_yes_no(input) do
    case input |> String.trim() |> String.downcase() do
      "y" -> :yes
      "yes" -> :yes
      _ -> :no
    end
  end

  # ----- step 10 rollback ----------------------------------------------------

  defp rollback_edits(reason) do
    # Only mix.exs is mutated by the script; CHANGELOG.md is maintainer-
    # written and never touched by the script, so we must NOT `git checkout
    # -- CHANGELOG.md` (would blow away unstaged release notes under
    # --allow-dirty).
    {_out, _code} =
      System.cmd("git", ["checkout", "--", @mix_exs_path], stderr_to_stdout: true)

    IO.puts("  reverted #{@mix_exs_path} (#{reason})")
  end

  # ----- step 11: hex.publish ------------------------------------------------

  defp publish_to_hex! do
    # `Mix.Task.run/2` runs in-process so prompts pass through stdin/stdout.
    # `--yes` is NEVER passed; the Hex prompts are the second safety check.
    # `run/2` (not `rerun/2`) per RELEASE_PLAN.md §3.2 step 11 — `mix
    # hex.publish` is not invoked elsewhere in this script, so the
    # already-run guard `rerun/2` defends against does not apply.
    Mix.Task.run("hex.publish", [])
  rescue
    e ->
      IO.puts(:stderr, "")
      IO.puts(:stderr, "mix hex.publish failed: #{Exception.message(e)}")

      IO.puts(
        :stderr,
        "mix.exs and CHANGELOG.md edits are LEFT IN WORKING TREE (not committed)."
      )

      IO.puts(:stderr, "Investigate, fix, and re-run — the script is idempotent.")
      System.halt(1)
  end

  defp run_hex_publish_dry_run do
    case System.cmd("mix", ["hex.build"], stderr_to_stdout: true) do
      {_out, 0} ->
        IO.puts("  mix hex.build OK (dry-run substitute for mix hex.publish --dry-run)")

      {out, code} ->
        IO.puts(:stderr, out)
        abort("mix hex.build failed (exit #{code})")
    end
  end

  # ----- step 12: commit + tag + push ---------------------------------------

  defp finalize_release!(new_version, tag) do
    run!("git", ["add", @mix_exs_path, @changelog_path])
    run!("git", ["commit", "-m", "Release #{tag}"])
    run!("git", ["tag", "-a", tag, "-m", "v#{new_version}"])
    run!("git", ["push", "origin", "main", tag])
  end

  defp run!(cmd, args) do
    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {_out, 0} ->
        :ok

      {out, code} ->
        IO.puts(:stderr, out)
        abort("#{cmd} #{Enum.join(args, " ")} failed (exit #{code})")
    end
  end

  # ----- step 13: success ---------------------------------------------------

  defp print_success(new_version) do
    IO.puts("")
    IO.puts("Released allm v#{new_version}.")
    IO.puts("  https://hex.pm/packages/allm/#{new_version}")
    IO.puts("  https://hexdocs.pm/allm/#{new_version}/")
    IO.puts("")
    IO.puts("If this was a major bump, run the smoke test from RELEASE_PLAN.md §2.4.")
  end

  # ----- helpers -------------------------------------------------------------

  defp log_step(label, msg) do
    IO.puts("[#{label}] #{msg}")
  end

  defp abort(msg) do
    IO.puts(:stderr, "ERROR: " <> msg)
    System.halt(1)
  end
end

ALLM.Release.main(System.argv())
