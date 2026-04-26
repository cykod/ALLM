defmodule ALLM.Test.ExampleFixtures do
  @moduledoc """
  Scripted-fixture helpers shared across the four `test/examples/*_test.exs`
  case-study translations (Phase 12.2). Builds on `ALLM.Providers.Fake`'s
  spec §31 script vocabulary — these helpers are thin wrappers around the
  same `{:text, _}` / `{:tool_call, _}` / `{:finish, _}` entry tags so the
  case-study tests read like their source markdown.

  See `ALLM.Providers.Fake` for the full script grammar; see
  `ALLM.Test.FakeFixtures` (under `test/support/`) for the Layer-B
  reusable-engine helpers that this module composes with.

  Layer C (test consumer) — these fixtures are imported in
  `test/examples/<name>_test.exs` files only.
  """

  alias ALLM.Test.FakeFixtures
  alias ALLM.Tool

  @doc """
  Single-call script that emits `text` and finishes with `:stop`.
  """
  @spec text_response(String.t()) :: [tuple()]
  def text_response(text) when is_binary(text) do
    [{:text, text}, {:finish, :stop}]
  end

  @doc """
  Single-call script that emits one tool call and finishes with `:tool_calls`.
  Tool-call id is deterministically `"tc_1"` so tests can pattern-match.
  """
  @spec tool_call_response(String.t(), map()) :: [tuple()]
  def tool_call_response(name, args) when is_binary(name) and is_map(args) do
    [
      {:tool_call, id: "tc_1", name: name, arguments: args},
      {:finish, :tool_calls}
    ]
  end

  @doc """
  Two-call multi-script: first call emits a tool call, second call emits the
  follow-up text. Wrap in `[scripts: tool_round_trip(...)]` to drive a
  multi-call Fake adapter via `Fake.start_script_cursor/0`.
  """
  @spec tool_round_trip(String.t(), map(), String.t()) :: [[tuple()]]
  def tool_round_trip(name, args, follow_up_text)
      when is_binary(name) and is_map(args) and is_binary(follow_up_text) do
    [
      tool_call_response(name, args),
      text_response(follow_up_text)
    ]
  end

  @doc """
  Single-call script that emits a tool call and halts — used with
  `mode: :manual` so the caller submits results themselves.
  """
  @spec manual_halt(String.t(), map()) :: [tuple()]
  def manual_halt(name, args), do: tool_call_response(name, args)

  @doc """
  Synthetic ask-user model: a tool call to a tool named `"ask_user"` whose
  handler returns `{:ask_user, question}`. Decision #9 — case studies model
  ask-user as a tool the model invokes, not a separate API.

  Returns the script (a single-call entry list) — pair with the
  `ask_user_tool/1` helper below for the matching tool definition.
  """
  @spec ask_user(String.t()) :: [tuple()]
  def ask_user(question) when is_binary(question) do
    [
      {:tool_call, id: "tc_1", name: "ask_user", arguments: %{question: question}},
      {:finish, :tool_calls}
    ]
  end

  @doc """
  Companion to `ask_user/1`: a tool definition whose handler converts the
  `question` argument into a `{:ask_user, question}` halt signal.
  """
  @spec ask_user_tool() :: Tool.t()
  def ask_user_tool do
    Tool.new(
      name: "ask_user",
      description: "Pause generation and ask the user a clarifying question.",
      schema: %{
        type: "object",
        properties: %{question: %{type: "string"}},
        required: ["question"]
      },
      handler: fn %{question: q} -> {:ask_user, q} end
    )
  end

  @doc """
  Fixture map standing in for a generated recipe — used by the meal
  translation as the JSON payload an `output_text` would carry.
  """
  @spec recipe_text() :: String.t()
  def recipe_text do
    Jason.encode!(%{
      "title" => "Tomato Pasta",
      "servings" => 4,
      "ingredients" => ["pasta", "tomato", "olive oil"]
    })
  end

  @doc """
  Reusable weather tool with a deterministic handler — returns
  `{:ok, %{forecast: "sunny", city: c}}` regardless of input city.
  Used by the unllmtd and amesbury translations for tool-loop scripts.
  """
  @spec weather_tool() :: Tool.t()
  def weather_tool do
    Tool.new(
      name: "weather",
      description: "Forecast by city.",
      schema: %{
        type: "object",
        properties: %{city: %{type: "string"}},
        required: ["city"]
      },
      handler: fn args ->
        city = Map.get(args, "city") || Map.get(args, :city) || "unknown"
        {:ok, %{forecast: "sunny", city: city}}
      end
    )
  end

  @doc """
  Build a single-call Fake-backed engine with the given script and opts.

  Delegates to `ALLM.Test.FakeFixtures.engine/2` (under `test/support/`) —
  these two modules historically duplicated the engine-construction surface;
  the canonical implementation lives in `FakeFixtures`. See Phase 12.2 retro
  Finding 1.
  """
  defdelegate engine(script, opts \\ []), to: FakeFixtures

  @doc """
  Build a multi-call Fake-backed engine with a per-engine cursor (so the
  script list advances across calls regardless of content collisions).

  Delegates to `ALLM.Test.FakeFixtures.engine_with_scripts/2`. The per-engine
  cursor allocation is load-bearing for multi-engine test patterns (see Fake
  moduledoc "Cursor behaviour" and Phase 12.2 retro Finding 4).
  """
  defdelegate engine_with_scripts(scripts, opts \\ []), to: FakeFixtures
end
