defmodule ALLM.Keys.DotenvTest do
  # async: false — lookup/1 depends on the shared Store Agent's dotenv cache
  # and the Application env for :load_dotenv / :dotenv_path.
  use ExUnit.Case, async: false

  alias ALLM.Keys.Dotenv
  alias ALLM.Keys.Store

  @fixture_path Path.expand("../../fixtures/sample.env", __DIR__)

  setup do
    on_exit(fn ->
      Store.clear()
      Application.delete_env(:allm, :load_dotenv)
      Application.delete_env(:allm, :dotenv_path)
    end)

    :ok
  end

  describe "parse/1" do
    test "KEY=VALUE yields the pair" do
      assert Dotenv.parse("KEY=VALUE\n") == [{"KEY", "VALUE"}]
    end

    test "# comment followed by KEY=VAL yields only the pair" do
      assert Dotenv.parse("# comment\nKEY=VAL\n") == [{"KEY", "VAL"}]
    end

    test "blank lines are a no-op" do
      assert Dotenv.parse("\n\nKEY=VAL\n\n") == [{"KEY", "VAL"}]
    end

    test "export KEY=VAL strips the `export` prefix" do
      assert Dotenv.parse("export KEY=VAL\n") == [{"KEY", "VAL"}]
    end

    test ~S|KEY="quoted value" strips surrounding double quotes| do
      assert Dotenv.parse(~S|KEY="quoted value"| <> "\n") ==
               [{"KEY", "quoted value"}]
    end

    test "KEY='single' does NOT strip single quotes (documented limitation)" do
      assert Dotenv.parse("KEY='single'\n") == [{"KEY", "'single'"}]
    end

    test "malformed line (no equals) is silently skipped" do
      assert Dotenv.parse("no equals here\nKEY=VAL\n") == [{"KEY", "VAL"}]
    end

    test "KEY= yields {KEY, \"\"} (empty value preserved)" do
      assert Dotenv.parse("KEY=\n") == [{"KEY", ""}]
    end

    test "multiple entries preserve order" do
      assert Dotenv.parse("A=1\nB=2\nC=3\n") ==
               [{"A", "1"}, {"B", "2"}, {"C", "3"}]
    end

    test "line with empty key (=VAL) is skipped" do
      assert Dotenv.parse("=orphan\nKEY=VAL\n") == [{"KEY", "VAL"}]
    end

    test "line with key containing invalid char (KEY-1=VAL) is skipped" do
      assert Dotenv.parse("KEY-1=VAL\nOK=good\n") == [{"OK", "good"}]
    end

    test "unterminated opening double quote returns the trimmed value as-is" do
      # Value is `"no-end` — starts with `"` but does not end with `"`, so
      # the quote-stripping branch falls through to the literal.
      assert Dotenv.parse(~S|KEY="no-end| <> "\n") == [{"KEY", ~S|"no-end|}]
    end

    test ~S|lone double quote `"` is not treated as a matched pair| do
      # Only ONE character, so stripping would drop too much. Falls through.
      assert Dotenv.parse(~S|KEY="| <> "\n") == [{"KEY", ~S|"|}]
    end
  end

  describe "load/1" do
    test "returns %{} when the file does not exist" do
      assert Dotenv.load("/nonexistent/path/to/file.env") == %{}
    end

    test "parses the sample fixture into a string-keyed map" do
      assert Dotenv.load(@fixture_path) == %{
               "OPENAI_API_KEY" => "sk-test",
               "ANTHROPIC_API_KEY" => "ant-test",
               "GOOGLE_API_KEY" => "g-test",
               "XAI_TOKEN" => "xai-test",
               "LOG_LEVEL" => "debug"
             }
    end
  end

  describe "lookup/1" do
    test "returns nil when load_dotenv is not set, regardless of file contents" do
      Application.put_env(:allm, :dotenv_path, @fixture_path)
      assert Dotenv.lookup(:openai) == nil
    end

    test "lookup(:openai) translates to OPENAI_API_KEY and returns the fixture value" do
      Application.put_env(:allm, :load_dotenv, true)
      Application.put_env(:allm, :dotenv_path, @fixture_path)

      assert Dotenv.lookup(:openai) == "sk-test"
    end

    test "lookup(:xai) translates to XAI_API_KEY and returns nil (fixture has XAI_TOKEN)" do
      Application.put_env(:allm, :load_dotenv, true)
      Application.put_env(:allm, :dotenv_path, @fixture_path)

      # The fallback env-var rule for unknown providers is
      # String.upcase("#{atom}") <> "_API_KEY" — so :xai → "XAI_API_KEY",
      # not "XAI_TOKEN". Consistent with the System.get_env layer.
      assert Dotenv.lookup(:xai) == nil
    end
  end
end
