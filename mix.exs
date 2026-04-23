defmodule ALLM.MixProject do
  use Mix.Project

  @version "0.0.1"
  @source_url "https://github.com/cykod/ALLM"

  def project do
    [
      app: :allm,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      description: description(),
      package: package(),
      source_url: @source_url,
      docs: docs(),
      test_coverage: [summary: [threshold: 80]]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ALLM.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:req, "~> 0.5"},
      {:finch, "~> 0.19"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.2"},
      # :llm_db re-added in Phase 9 (capability pre-flight / cost population, spec §6.3)
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: [:test]}
    ]
  end

  defp description do
    "Provider-neutral LLM execution for Elixir with first-class streaming, tool calling, and serializable sessions."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "ALLM",
      source_ref: "v#{@version}",
      extras: ["README.md"]
    ]
  end
end
