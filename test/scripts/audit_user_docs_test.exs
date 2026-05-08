defmodule Scripts.AuditUserDocsTest do
  @moduledoc """
  Tests for `scripts/audit_user_docs.exs` — the banned-token audit that
  enforces zero internal-vocabulary references inside ALLM's user-facing
  documentation surface.

  The script is normally invoked via `mix run scripts/audit_user_docs.exs`
  but its core walking + matching logic is exposed via `@doc false` public
  functions on the auditor module so it can be tested without spawning a
  child VM.
  """

  use ExUnit.Case, async: true

  @script_path Path.expand("../../scripts/audit_user_docs.exs", __DIR__)
  @repo_root Path.expand("../..", __DIR__)

  setup_all do
    # Compile the script once. It defines `Scripts.AuditUserDocs` as a side
    # effect of being loaded; we only run the CLI side when invoked under
    # `mix run`.
    Code.require_file(@script_path)
    :ok
  end

  # Resolve the auditor module via `Module.concat/1` at the call site so
  # the compile-time linker doesn't emit "module is not available"
  # warnings for this `Code.require_file/1`-loaded script (per
  # AGENT_IMPLEMENTATION_SPEC.md §Optional-dep detection — same idiom).
  defp auditor, do: Module.concat(["Scripts", "AuditUserDocs"])

  describe "banned-token regex coverage" do
    test "every banned-token pattern matches its positive fixture line" do
      fixtures = [
        # {pattern_label, input_line}
        {"phase_n", "This is Phase 1 work."},
        {"phase_n_lower", "this is phase 7.3 work."},
        {"section_marker", "See §8 for details."},
        {"spec_section", "Per spec §6.4 keys never live on the engine."},
        {"spec_filename", "Reference allm_engine_session_streaming_spec_v0_2.md."},
        {"steering_path", "Inlined from steering/foo.md."},
        {"phase_design_md", "See PHASE_17_DESIGN.md."},
        {"decision_hash", "Per Decision #4 the loop terminates."},
        {"decision_lower", "decision 9 covers the edge case."},
        {"non_obvious_decision", "Non-obvious Decision #2 explains it."},
        {"retro_finding", "See retro F12 for context."},
        {"retro_path", "See retro/2026-04-29-foo.md."},
        {"release_plan", "RELEASE_PLAN.md outlines the cadence."},
        {"project_phasing", "PROJECT_PHASING.md was the original phasing doc."}
      ]

      for {label, line} <- fixtures do
        hits = auditor().scan_line(line)

        assert hits != [],
               "expected pattern #{label} to match line: #{inspect(line)}, got no hits"
      end
    end

    test "clean lines produce zero hits" do
      clean_lines = [
        "Run `ALLM.chat(engine, [ALLM.user(\"hello\")])`.",
        "The Engine struct holds adapter-level configuration.",
        "Configure your provider and call generate/3.",
        "Returns `{:ok, %ALLM.Response{}}` on success."
      ]

      for line <- clean_lines do
        assert auditor().scan_line(line) == [],
               "expected zero hits on: #{inspect(line)}"
      end
    end
  end

  describe "surface-set walking" do
    test "the documented surface set excludes test/, steering/, retro/, reviews/, doc/, _build/, deps/, HISTORY.md" do
      surface = auditor().surface_paths(@repo_root)
      relative = Enum.map(surface, &Path.relative_to(&1, @repo_root))

      excluded_prefixes = ["test/", "steering/", "retro/", "reviews/", "doc/", "_build/", "deps/"]

      for path <- relative, prefix <- excluded_prefixes do
        refute String.starts_with?(path, prefix),
               "surface set leaks excluded prefix #{prefix}: #{path}"
      end

      refute Enum.any?(relative, &(&1 == "HISTORY.md")),
             "surface set must not include HISTORY.md"
    end

    test "the surface set includes lib/**/*.ex when lib/ has content" do
      surface = auditor().surface_paths(@repo_root)
      relative = Enum.map(surface, &Path.relative_to(&1, @repo_root))

      assert Enum.any?(relative, &String.starts_with?(&1, "lib/")),
             "surface set should include lib/ files"
    end

    test "the surface set includes top-level README.md, CHANGELOG.md, mix.exs, examples/README.md when they exist" do
      surface = auditor().surface_paths(@repo_root)
      relative = Enum.map(surface, &Path.relative_to(&1, @repo_root))

      for required <- ["README.md", "CHANGELOG.md", "mix.exs", "examples/README.md"] do
        if File.exists?(Path.join(@repo_root, required)) do
          assert required in relative, "surface should include #{required}"
        end
      end
    end
  end

  describe ".ex docstring-block targeting" do
    test "only @moduledoc/@doc heredoc bodies count; def/defp body comments do not" do
      tmp = tmp_dir()
      file = Path.join(tmp, "fixture.ex")

      File.write!(file, """
      defmodule Fixture do
        @moduledoc \"\"\"
        Phase 1 lives in a docstring — should be flagged.
        \"\"\"

        @doc \"\"\"
        Phase 2 lives in a docstring — should be flagged.
        \"\"\"
        def foo do
          # Phase 3 in a def body comment — should NOT be flagged.
          :ok
        end

        defp bar do
          # See §99 in a defp comment — should NOT be flagged.
          :ok
        end
      end
      """)

      hits = auditor().scan_file(file)

      lines_hit = Enum.map(hits, & &1.line)
      assert 3 in lines_hit, "expected hit on @moduledoc body line 3"
      assert 7 in lines_hit, "expected hit on @doc body line 7"
      refute 11 in lines_hit, "def-body comment line 11 must not be flagged"
      refute 16 in lines_hit, "defp-body comment line 16 must not be flagged"
    after
      File.rm_rf!(tmp_dir())
    end

    test "@doc false does not enter heredoc state" do
      tmp = tmp_dir()
      file = Path.join(tmp, "doc_false.ex")

      File.write!(file, """
      defmodule Fixture do
        @doc false
        def foo do
          # Phase 5 inside def body of @doc false function — must NOT flag.
          :ok
        end
      end
      """)

      assert auditor().scan_file(file) == []
    after
      File.rm_rf!(tmp_dir())
    end

    test "@moduledoc false does not enter heredoc state" do
      tmp = tmp_dir()
      file = Path.join(tmp, "moduledoc_false.ex")

      File.write!(file, """
      defmodule Fixture do
        @moduledoc false
        # Phase 9 in a top-level comment — must NOT flag.
        def foo, do: :ok
      end
      """)

      assert auditor().scan_file(file) == []
    after
      File.rm_rf!(tmp_dir())
    end
  end

  describe ".md whole-file scanning" do
    test "every line in a Markdown file is scanned, regardless of position" do
      tmp = tmp_dir()
      file = Path.join(tmp, "fixture.md")

      File.write!(file, """
      # Title

      Phase 1 prose appears here.

      ```elixir
      # See §8 inside a code fence — still flagged for .md files.
      :ok
      ```
      """)

      hits = auditor().scan_file(file)
      lines_hit = Enum.map(hits, & &1.line)

      assert 3 in lines_hit
      assert 6 in lines_hit
    after
      File.rm_rf!(tmp_dir())
    end
  end

  describe "exit code semantics" do
    test "run_audit/1 returns {:ok, hits, summary} where hits is a list and summary is a map" do
      tmp = tmp_dir()
      File.write!(Path.join(tmp, "clean.md"), "# Clean\n\nNothing flagged here.\n")

      assert {:ok, hits, summary} = auditor().run_audit([Path.join(tmp, "clean.md")])
      assert hits == []
      assert is_map(summary)
      assert Map.has_key?(summary, :total_hits)
      assert summary.total_hits == 0
    after
      File.rm_rf!(tmp_dir())
    end

    test "run_audit/1 reports hits when a banned token is present" do
      tmp = tmp_dir()
      file = Path.join(tmp, "dirty.md")
      File.write!(file, "# Title\n\nPhase 1 reference here.\n")

      assert {:ok, hits, summary} = auditor().run_audit([file])
      assert hits != []
      assert summary.total_hits >= 1
    after
      File.rm_rf!(tmp_dir())
    end

    test "exit_code_for/1 returns 0 for empty hits and 1 otherwise" do
      assert auditor().exit_code_for([]) == 0
      assert auditor().exit_code_for([%{}]) == 1
    end
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "allm_audit_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end
end
