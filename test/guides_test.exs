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
  )

  setup_all do
    Code.require_file(@script_path)
    :ok
  end

  # Resolve the auditor module at call time to avoid compile-time
  # "module not available" warnings for the `Code.require_file/1`-loaded
  # script (same idiom as `Scripts.AuditUserDocsTest`).
  defp auditor, do: Module.concat(["Scripts", "AuditUserDocs"])

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
