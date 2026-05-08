defmodule ALLM.ReadmePickAProviderTest do
  @moduledoc """
  Structural check on the README's `## Pick a provider` section.

  The pitch of the section — and a load-bearing claim the rest of the
  README leans on — is that **picking a provider is a one-line change**
  and every call site below it is identical across providers. This test
  enforces both halves:

  1. Three engine constructors are present (OpenAI, Anthropic, Gemini).
     Each of those construction lines differs only in the adapter
     module + model string.
  2. The post-engine call site shown below the constructors does not
     mention any of the three provider modules — it is provider-neutral
     by construction. The README cannot drift into a provider-specific
     follow-up without breaking this test.
  """

  use ExUnit.Case, async: true

  @readme_path Path.expand("../README.md", __DIR__)

  test "Pick a provider section shows all three bundled adapters" do
    body = section_body!("## Pick a provider")
    assert body =~ "ALLM.Providers.OpenAI"
    assert body =~ "ALLM.Providers.Anthropic"
    assert body =~ "ALLM.Providers.Gemini"
  end

  test "the three engine construction lines have byte-equal post-`adapter:` shape" do
    body = section_body!("## Pick a provider")

    [openai_line] = grep_lines(body, ~r/ALLM\.Engine\.new\(adapter: ALLM\.Providers\.OpenAI/)
    [anthropic_line] = grep_lines(body, ~r/ALLM\.Engine\.new\(adapter: ALLM\.Providers\.Anthropic/)
    [gemini_line] = grep_lines(body, ~r/ALLM\.Engine\.new\(adapter: ALLM\.Providers\.Gemini/)

    # Each line must follow the canonical shape:
    #   engine = ALLM.Engine.new(adapter: <Mod>, model: "<string>")
    # and must have a model string. The post-`model: ` shape is the
    # tail closer `)` — byte-equal across providers by construction.
    for line <- [openai_line, anthropic_line, gemini_line] do
      assert line =~
               ~r/^engine = ALLM\.Engine\.new\(adapter: ALLM\.Providers\.[A-Za-z]+, model: "[^"]+"\)$/,
             "expected canonical shape, got: #{inspect(line)}"
    end

    # The post-engine portion (everything after `adapter: ...,`) must be
    # byte-equal modulo the model string itself. Extract `model: "<x>")`
    # from each and assert they share the structural shape.
    tails =
      for line <- [openai_line, anthropic_line, gemini_line] do
        [_, tail] = Regex.run(~r/, (model: "[^"]+"\))$/, line)
        # Replace the model literal with a placeholder so the three tails
        # collapse to byte-equality.
        Regex.replace(~r/"[^"]+"/, tail, "\"<MODEL>\"")
      end

    assert Enum.uniq(tails) == ["model: \"<MODEL>\")"],
           "post-engine tails diverged: #{inspect(tails)}"
  end

  test "shared call site below the three engines is provider-neutral" do
    body = section_body!("## Pick a provider")

    [_, after_engines] =
      String.split(body, ~r/ALLM\.Engine\.new\(adapter: ALLM\.Providers\.Gemini[^\n]+\n/, parts: 2)

    [shared_call] = grep_lines(after_engines, ~r/ALLM\.chat\(engine,/)

    refute shared_call =~ "ALLM.Providers.OpenAI",
           "shared call site mentions a specific provider: #{inspect(shared_call)}"

    refute shared_call =~ "ALLM.Providers.Anthropic",
           "shared call site mentions a specific provider: #{inspect(shared_call)}"

    refute shared_call =~ "ALLM.Providers.Gemini",
           "shared call site mentions a specific provider: #{inspect(shared_call)}"
  end

  defp section_body!(heading) do
    source = File.read!(@readme_path)
    [_, rest] = String.split(source, heading, parts: 2)

    case Regex.split(~r/\n## /, rest, parts: 2) do
      [body, _] -> body
      [body] -> body
    end
  end

  defp grep_lines(text, pattern) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&Regex.match?(pattern, &1))
  end
end
