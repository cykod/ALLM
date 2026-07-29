defmodule ALLM.MixProject do
  use Mix.Project

  @version "0.4.3"
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
      # llm_db: capability pre-flight + cost. Deferred to a future release; will be re-added as an optional dep.
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: [:test]},
      # Test-only — Req.Test.stub/2 expects a Plug shape; not in the published Hex package.
      {:plug, "~> 1.16", only: [:test]},
      # Test-only path dep — certifies the bundled defaults against the conformance harness. mix hex.build automatically strips test-only deps from the published metadata.
      {:allm_conformance, path: "conformance", only: :test},
      # Dev-only — the example scripts under examples/ load API keys from a project-root .env via this. examples/ is excluded from the published package.
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
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE .formatter.exs guides)
    ]
  end

  @guides ~w(
    guides/getting_started.md
    guides/streaming.md
    guides/tools.md
    guides/sessions.md
    guides/vision.md
    guides/image_generation.md
    guides/errors_and_retries.md
    guides/multi_tenant_keys.md
    guides/fakes.md
  )

  defp docs do
    [
      main: "ALLM",
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md"] ++ @guides,
      groups_for_extras: [{"Guides", @guides}],
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
          ALLM.Providers.OpenAI.Images,
          ALLM.Providers.Anthropic,
          ALLM.Providers.Gemini,
          ALLM.Providers.Gemini.Images,
          ALLM.Providers.Fake,
          ALLM.Providers.Fake.Script,
          ALLM.Providers.FakeImages,
          ALLM.Providers.Support.SSE,
          ALLM.Providers.Support.OpenAIHeaders,
          ALLM.Providers.Support.GeminiHeaders,
          ALLM.Providers.Support.ImageMime
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
          ALLM.JsonSchema,
          ALLM.TextPart,
          ALLM.ImagePart,
          ALLM.Embedding,
          ALLM.EmbeddingRequest,
          ALLM.EmbeddingResponse
        ],
        Runtime: [
          ALLM.Engine,
          ALLM.Keys,
          ALLM.Validate,
          ALLM.Capability,
          ALLM.Retry,
          ALLM.Telemetry,
          ALLM.StreamCollector,
          ALLM.Serializer,
          ALLM.Sandbox
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
