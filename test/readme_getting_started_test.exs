defmodule ALLM.ReadmeGettingStartedTest do
  @moduledoc """
  Parallel-source drift detection for the README.

  The README's `## Hello, ALLM` section carries a plain ` ```elixir `
  fenced block intended for copy-paste into `iex -S mix`. A parallel
  `iex>`-prefixed doctest lives in `lib/allm.ex`'s `@moduledoc` and is
  exercised by `doctest ALLM` in `test/allm_test.exs`. The doctest
  validates the moduledoc copy; this test validates the README copy.

  The first test extracts the README's Hello block, evaluates it via
  `Code.eval_string/1`, and asserts the bound `text` variable equals
  `"Hello, ALLM!"` — drift between the README and the live API surfaces
  here as a test failure rather than silent doc rot.

  The remaining tests walk each section of the new "5-minute tour"
  to ensure the README's structural anchors (heading text +
  fenced-block presence) stay aligned with what the rest of the
  documentation cross-links to. They're substring/structure checks,
  not full evaluations — many tour snippets call real providers and
  require API keys that the test environment does not have.
  """

  use ExUnit.Case, async: true

  @readme_path Path.expand("../README.md", __DIR__)

  test "README Hello, ALLM snippet evaluates to \"Hello, ALLM!\"" do
    snippet = extract_first_elixir_block_after!("## Hello, ALLM", "ALLM.Engine.new")
    {result, _bindings} = Code.eval_string(snippet)
    assert result == "Hello, ALLM!"
  end

  test "README contains a top-level Why ALLM? section" do
    source = read_readme()
    assert source =~ ~r/^## Why ALLM\?\s*$/m
  end

  test "README contains an Install section with a deps snippet" do
    source = read_readme()
    assert source =~ ~r/^## Install\s*$/m
    install_block = section_body(source, "## Install")
    assert install_block =~ "{:allm,"
    assert install_block =~ "mix deps.get"
  end

  test "README Pick a provider section shows three engine constructors" do
    source = read_readme()
    body = section_body(source, "## Pick a provider")
    assert body =~ "ALLM.Providers.OpenAI"
    assert body =~ "ALLM.Providers.Anthropic"
    assert body =~ "ALLM.Providers.Gemini"
  end

  test "README 5-minute tour has Generate / Stream / Chat / Tools / Sessions subsections" do
    source = read_readme()
    tour = section_body(source, "## The 5-minute tour")

    for needle <- [
          "### 1. Generate",
          "### 2. Stream",
          "### 3. Chat",
          "### 4. Tools",
          "### 5. Sessions"
        ] do
      assert String.contains?(tour, needle),
             "expected the 5-minute tour to contain section header #{inspect(needle)}"
    end
  end

  test "README 5-minute tour Generate subsection covers ALLM.generate/3 and ALLM.stream_generate/3" do
    body = subsection_body!("### 1. Generate")
    assert body =~ "ALLM.generate("
    assert body =~ "ALLM.stream_generate("
  end

  test "README 5-minute tour Stream subsection covers ALLM.stream/3 and event-tuple matching" do
    body = subsection_body!("### 2. Stream")
    assert body =~ "ALLM.stream("
    assert body =~ ":text_delta"
  end

  test "README 5-minute tour Chat subsection covers ALLM.chat/3 and Thread.add_message/2" do
    body = subsection_body!("### 3. Chat")
    assert body =~ "ALLM.chat("
    assert body =~ "ALLM.Thread.add_message"
  end

  test "README 5-minute tour Tools subsection declares a tool and feeds it through chat/3" do
    body = subsection_body!("### 4. Tools")
    assert body =~ "ALLM.tool("
    assert body =~ "ALLM.Engine.put_tools"
    assert body =~ "ALLM.chat("
  end

  test "README 5-minute tour Sessions subsection covers ETF round-trip and Session.reply/4" do
    body = subsection_body!("### 5. Sessions")
    assert body =~ "binary_to_term"
    assert body =~ "ALLM.Session.reply"
  end

  test "README Worked examples section cross-links every guide" do
    body = section_body(read_readme(), "## Worked examples")

    for guide <- [
          "guides/getting_started.md",
          "guides/streaming.md",
          "guides/tools.md",
          "guides/sessions.md",
          "guides/vision.md",
          "guides/image_generation.md",
          "guides/errors_and_retries.md",
          "guides/multi_tenant_keys.md"
        ] do
      assert String.contains?(body, guide),
             "expected README's Worked examples section to link to #{guide}"
    end
  end

  test "README Real providers section documents env vars + per-call BYOK" do
    body = section_body(read_readme(), "## Real providers")
    assert body =~ "OPENAI_API_KEY"
    assert body =~ "ANTHROPIC_API_KEY"
    assert body =~ "GEMINI_API_KEY"
    assert body =~ "api_key:"
  end

  test "README Compatibility section states Elixir + OTP floor" do
    body = section_body(read_readme(), "## Compatibility")
    assert body =~ "Elixir"
    assert body =~ "1.17"
    assert body =~ "27"
  end

  defp read_readme, do: File.read!(@readme_path)

  defp extract_first_elixir_block_after!(heading, contains) do
    [_, after_heading] = String.split(read_readme(), heading, parts: 2)

    Regex.scan(~r/```elixir\n(.*?)\n```/s, after_heading, capture: :all_but_first)
    |> Enum.map(fn [block] -> block end)
    |> Enum.find(&String.contains?(&1, contains))
    |> case do
      nil ->
        flunk(
          "README.md #{heading} section has no ```elixir block " <>
            "containing #{inspect(contains)} — snippet may have moved or renamed."
        )

      block ->
        block
    end
  end

  # Returns the body of a `##`-level section (or `###` subsection),
  # stopping at the next heading at the same-or-shallower depth.
  defp section_body(source, heading) do
    [_before, rest] = String.split(source, heading, parts: 2)

    depth = leading_hash_count(heading)
    # Stop at the next heading whose depth is `<= depth` AND `>= 2`
    # (a top-level `#` heading appears only in the README title; we
    # also avoid matching `# ` comments inside fenced elixir blocks).
    stopper =
      Regex.compile!(
        "\\n(?:" <>
          (2..depth |> Enum.map_join("|", fn n -> String.duplicate("#", n) end)) <>
          ") "
      )

    case Regex.split(stopper, rest, parts: 2) do
      [body, _] -> body
      [body] -> body
    end
  end

  defp subsection_body!(heading) do
    body = section_body(read_readme(), heading)

    if body == "" or body == read_readme() do
      flunk("README.md does not contain subsection heading #{inspect(heading)}")
    end

    body
  end

  defp leading_hash_count("#" <> rest), do: 1 + leading_hash_count(rest)
  defp leading_hash_count(_), do: 0
end
