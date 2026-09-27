defmodule ALLM.Test.CacheUsageFixtures do
  @moduledoc """
  Cached-prompt usage fixtures for the four chat rows (OpenAI Chat
  Completions, OpenAI Responses, Anthropic, Gemini). Internal test support —
  NOT part of the published Hex package.

  A thin table over the existing per-provider loaders: every body and every
  stream is read through `OpenAITestFixtures`, `AnthropicTestFixtures` or
  `GeminiTestFixtures`, never re-parsed here. Each row pairs a non-streaming
  body with a streaming fixture carrying the *same* counts.

  `synthesized?/1` reads a fixture's raw bytes, so it binds provenance where
  an assertion made through a loader (which may strip `_comment`) cannot.
  """

  alias ALLM.Providers.AnthropicTestFixtures
  alias ALLM.Providers.GeminiTestFixtures
  alias ALLM.Providers.OpenAITestFixtures

  @typedoc "One cached-prompt usage row."
  @type row :: :openai_chat | :openai_responses | :anthropic | :gemini

  @rows [:openai_chat, :openai_responses, :anthropic, :gemini]

  @root "test/fixtures"

  @files %{
    openai_chat: [
      "openai/synthesized/cache_usage_chat.json",
      "openai/synthesized/cache_usage_chat_stream.sse"
    ],
    openai_responses: [
      "openai/synthesized/cache_usage_responses.json",
      "openai/synthesized/cache_usage_responses.sse"
    ],
    anthropic: [
      "anthropic/synthesized/cache_usage.json",
      "anthropic/synthesized/cache_usage_stream.sse",
      "anthropic/synthesized/cache_usage_stream_cumulative.sse"
    ],
    gemini: ["gemini/synthesized/cache_usage.json", "gemini/synthesized/cache_usage.sse"]
  }

  @json_marker "Synthesized — Phase 27.2"
  @sse_marker ": synthesized — Phase 27.2"

  @doc "The row names, in table order."
  @spec rows() :: [row()]
  def rows, do: @rows

  @doc "The decoded non-streaming response body for a row."
  @spec body(row()) :: map()
  def body(:openai_chat), do: OpenAITestFixtures.synthesized(:cache_usage_chat)
  def body(:openai_responses), do: OpenAITestFixtures.synthesized(:cache_usage_responses)
  def body(:anthropic), do: AnthropicTestFixtures.synthesized(:cache_usage)
  def body(:gemini), do: GeminiTestFixtures.synthesized(:cache_usage)

  @doc "The SSE chunks of a row's streaming fixture."
  @spec stream_chunks(row() | :anthropic_cumulative) :: [binary()]
  def stream_chunks(:openai_chat), do: OpenAITestFixtures.stream_chunks(:cache_usage_chat_stream)

  def stream_chunks(:openai_responses),
    do: OpenAITestFixtures.stream_chunks(:cache_usage_responses)

  def stream_chunks(:anthropic), do: AnthropicTestFixtures.stream_chunks(:cache_usage_stream)

  def stream_chunks(:anthropic_cumulative),
    do: AnthropicTestFixtures.stream_chunks(:cache_usage_stream_cumulative)

  def stream_chunks(:gemini), do: GeminiTestFixtures.stream_chunks(:cache_usage)

  # Live recordings written by `scripts/record_prompt_cache_fixtures.exs`.
  # Hand-maintained on purpose: the family test asserts this list equals
  # the `prompt_cache_*` files discovered under the `recorded/` directories,
  # in both directions.
  @recorded [
    "openai/responses/recorded/prompt_cache_hit.json",
    "openai/responses/recorded/prompt_cache_hit_gpt6.json",
    "openai/responses/recorded/prompt_cache_unknown_field.json",
    "openai/chat_completions/recorded/prompt_cache_stream.sse",
    "anthropic/messages/recorded/prompt_cache_hit_claude-haiku-4-5-20251001.json",
    "anthropic/messages/recorded/prompt_cache_hit_claude-sonnet-5.json",
    "anthropic/messages/recorded/prompt_cache_hit_claude-sonnet-4-6.json",
    "anthropic/messages/recorded/prompt_cache_stream.sse",
    "anthropic/messages/recorded/prompt_cache_unknown_field.json",
    "gemini/generate_content/recorded/prompt_cache_hit.json",
    "gemini/generate_content/recorded/prompt_cache_unknown_field.json"
  ]

  @doc "Every recorded prompt-cache fixture this module serves, repo-relative."
  @spec recorded_paths() :: [Path.t()]
  def recorded_paths, do: Enum.map(@recorded, &Path.join(@root, &1))

  @doc "The `prompt_cache_*` files actually present under the `recorded/` directories."
  @spec discovered_recorded_paths() :: [Path.t()]
  def discovered_recorded_paths,
    do: Path.wildcard(Path.join(@root, "{openai,anthropic,gemini}/*/recorded/prompt_cache_*"))

  @doc """
  A recorded fixture's decoded JSON, read from raw bytes (no `_comment`
  stripping, so a placeholder would surface rather than be hidden).
  """
  @spec recorded_json(Path.t()) :: map()
  def recorded_json(path), do: path |> File.read!() |> Jason.decode!()

  @doc "Every synthesized fixture file this module serves, repo-relative."
  @spec paths() :: [Path.t()]
  def paths, do: @files |> Map.values() |> List.flatten() |> Enum.map(&Path.join(@root, &1))

  @doc """
  True when the raw bytes carry the synthesized provenance marker: a JSON
  `_comment` beginning `Synthesized — Phase 27.2`, or an `.sse` whose first
  line is `: synthesized — Phase 27.2 …`.
  """
  @spec synthesized?(Path.t()) :: boolean()
  def synthesized?(path) do
    raw = File.read!(path)

    case Path.extname(path) do
      ".json" ->
        comment = Map.get(Jason.decode!(raw), "_comment", "")
        is_binary(comment) and String.starts_with?(comment, @json_marker)

      ".sse" ->
        raw |> String.split("\n", parts: 2) |> hd() |> String.starts_with?(@sse_marker)
    end
  end
end
