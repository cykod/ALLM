defmodule ALLMConformance.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/cykod/allm"

  def project do
    [
      app: :allm_conformance,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      description: description(),
      package: package(),
      source_url: @source_url,
      dialyzer: [plt_add_apps: [:ex_unit]]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Local path dep during development; rewritten to `{:allm, "~> 0.2"}` at
      # Hex-publish time (see README release checklist). Path deps are not
      # carried into the published graph, so the cycle
      # `allm_conformance <-> allm` exists only at dev time.
      {:allm, path: "..", only: [:dev, :test]},
      {:jason, "~> 1.4", only: [:dev, :test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    "Conformance test suite for ALLM behaviours (Adapter, StreamAdapter, ToolExecutor, ToolResultEncoder)."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md .formatter.exs)
    ]
  end
end
