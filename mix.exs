defmodule ALLM.MixProject do
  use Mix.Project

  @version "0.2.0"
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
      {:stream_data, "~> 1.1", only: [:test]},
      # Required by `Req.Test.stub/2` for the OpenAI wire-test Plug shape
      # (Phase 10.2). Test-only; not in published Hex package.
      {:plug, "~> 1.16", only: [:test]},
      # Test-only path dep: certifies the two defaults
      # (ALLM.ToolExecutor.Default, ALLM.ToolResultEncoder.JSON) against
      # the shipped conformance harness. See conformance/README.md for
      # the release checklist (path → "~> 0.2" rewrite at publish time).
      {:allm_conformance, path: "conformance", only: :test},
      # Dev-only: example scripts under `examples/openai/*.exs` use this
      # to load `OPENAI_API_KEY` from a project-root `.env` file. NOT
      # shipped in the published package — `examples/` is excluded via
      # `package.files` and `only: [:dev]` keeps the dep out of the
      # published `mix.exs` deps list.
      {:env_loader, "~> 0.1", only: [:dev]}
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
      extras: ["README.md", "CHANGELOG.md"],
      groups_for_modules: [
        Facade: [ALLM],
        Sessions: [ALLM.Session, ALLM.Session.StreamReducer],
        Behaviours: [
          ALLM.Adapter,
          ALLM.StreamAdapter,
          ALLM.ToolExecutor,
          ALLM.ToolResultEncoder,
          ALLM.ImageAdapter
        ],
        Providers: [
          ALLM.Providers.OpenAI,
          ALLM.Providers.Anthropic,
          ALLM.Providers.Fake,
          ALLM.Providers.Fake.Script,
          ALLM.Providers.FakeImages,
          ALLM.Providers.Support.SSE
        ],
        Defaults: [
          ALLM.ToolExecutor.Default,
          ALLM.ToolResultEncoder.JSON
        ],
        "Data types": [
          ALLM.Message,
          ALLM.Request,
          ALLM.Response,
          ALLM.Thread,
          ALLM.StepResult,
          ALLM.ChatResult,
          ALLM.Event,
          ALLM.Usage,
          ALLM.Tool,
          ALLM.ToolCall,
          ALLM.ModelRef,
          ALLM.Image,
          ALLM.ImageRequest,
          ALLM.ImageResponse,
          ALLM.ImageUsage,
          ALLM.TextPart,
          ALLM.ImagePart
        ],
        Runtime: [
          ALLM.Engine,
          ALLM.Keys,
          ALLM.Validate,
          ALLM.Capability,
          ALLM.Retry,
          ALLM.Telemetry,
          ALLM.StreamCollector,
          ALLM.Serializer
        ],
        Internals: [
          ALLM.Chat,
          ALLM.Runner,
          ALLM.StreamRunner,
          ALLM.ToolRunner
        ],
        Errors: [
          ALLM.Error.AdapterError,
          ALLM.Error.EngineError,
          ALLM.Error.SessionError,
          ALLM.Error.StreamError,
          ALLM.Error.ToolError,
          ALLM.Error.ValidationError,
          ALLM.Error.ImageAdapterError
        ]
      ]
    ]
  end
end
