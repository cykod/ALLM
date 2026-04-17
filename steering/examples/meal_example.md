# Case Study: Replacing `meal`'s hand-built LLM code with ALLM

This doc walks through the LLM-facing code in [`~/Projects/meal/server`](../../meal/server) and shows how each piece would be expressed using the ALLM library defined in [`allm_engine_session_streaming_spec_v0_2.md`](../allm_engine_session_streaming_spec_v0_2.md).

## What `meal` uses LLMs for

Meal is an Elixir/Phoenix recipe app. All LLM usage lives under `server/lib/meal/ai/`:

| File | Purpose |
|---|---|
| `ai/openai_client.ex` | Thin wrapper over the `OpenAI` Hex package. Builds chat-completion requests with structured-output schemas, parses JSON out of the response. |
| `ai/recipe_generator.ex` | Three recipe operations — `generate_from_prompt/1`, `parse_from_url/1`, `modify_recipe/2` — each a single OpenAI round-trip with a prompt + JSON schema. |
| `ai/browser_fetcher.ex` | Wallaby-based scraper used as a fallback when a URL has no schema.org JSON-LD. Not really "LLM" code but feeds `extract_recipe_from_text/2`. |

Everything is **non-streaming, single-turn, single-provider, no tools**. The client is locked to `gpt-4o-2024-08-06` (openai_client.ex:48) and the API key is read directly from `Application.get_env(:openai, :api_key)` or `System.get_env("OPENAI_API_KEY")` (openai_client.ex:134-137).

## Mapping `meal` concepts to ALLM concepts

| `meal` construct | ALLM replacement | Spec section |
|---|---|---|
| `Meal.AI.OpenAIClient` module | `ALLM.Providers.OpenAI` adapter + `ALLM.Engine` | §6, §32.1 |
| `structured_request/4` arg list (system, user, schema, opts) | `ALLM.request/2` with `response_format:` | §9 |
| Hard-coded `"gpt-4o-…"` string in a module attribute | `ALLM.Engine.new(model: …)` or per-call `model:` override | §6.2 |
| `get_api_key/0` reading `Application` / `System.get_env` | `ALLM.Keys` with defined precedence (opts → override → config → env → .env) | §6.4 |
| `parse_structured_response/1` + `Jason.decode/1` | `ALLM.Response.output_text` + normalized shapes — structured JSON comes back parsed | §5.5 |
| `handle_openai_response/1` pattern matching on `{:ok, %{choices: […]}}` | Handled inside the adapter; caller sees a uniform `ALLM.Response` | §7.1 |
| `RecipeGenerator.generate_from_prompt/1` | `ALLM.generate/3` | §10.1 |
| `RecipeGenerator.modify_recipe/2` (recipe + modification prompt) | Same `ALLM.generate/3`, but with multi-message thread | §10.1 |
| The `with {:ok, …} <- BrowserFetcher.fetch_recipe_data(url)` chain in `parse_from_url/1` | `ALLM.Tool` for fetching + `ALLM.chat/3` (or manual mode per §12) | §10.5, §12 |
| `map_schema_org_to_recipe/1` and `extract_recipe_from_text/2` fallback logic | Belongs in a tool handler or in a small post-processor on the ALLM response — ALLM doesn't own domain parsing | — |
| `normalize_recipe_fields/1` | Keep as-is; ALLM returns structured data, caller maps to their schema | — |

What ALLM does **not** replace: the `@recipe_schema` itself, the `BrowserFetcher` scraper, the `map_schema_org_to_recipe/1` domain parser, and `normalize_recipe_fields/1`. Those are business logic.

---

## Side-by-side: `generate_from_prompt/1`

### Before — `meal/server/lib/meal/ai/recipe_generator.ex:144-178` + `openai_client.ex:47-78`

```elixir
# recipe_generator.ex
def generate_from_prompt(prompt) when is_binary(prompt) do
  system_prompt = """
  You are an expert chef and recipe creator...
  """

  user_input = """
  Create a recipe for: #{prompt}
  Please provide a complete recipe with all details.
  """

  case OpenAIClient.structured_request(system_prompt, user_input, @recipe_schema) do
    {:ok, recipe_data} ->
      recipe_fields =
        recipe_data
        |> Map.put("source", :generated)
        |> normalize_recipe_fields()

      {:ok, recipe_fields}

    {:error, reason} ->
      {:error, reason}
  end
end

# openai_client.ex
def structured_request(system_prompt, user_input, response_format, opts \\ []) do
  model = Keyword.get(opts, :model, "gpt-4o-2024-08-06")
  temperature = Keyword.get(opts, :temperature, 0.7)
  max_tokens = Keyword.get(opts, :max_tokens, 4000)

  request_body = %{
    model: model,
    messages: [
      %{role: "system", content: system_prompt},
      %{role: "user", content: user_input}
    ],
    response_format: %{
      type: "json_schema",
      json_schema: %{
        name: "structured_response",
        strict: true,
        schema: response_format
      }
    },
    temperature: temperature,
    max_tokens: max_tokens
  }

  case openai_request(request_body) do
    {:ok, response} -> parse_structured_response(response)
    {:error, reason} = error -> Logger.error(...); error
  end
end
```

### After — with ALLM

Build the engine once at app start:

```elixir
# application.ex or a small Meal.AI.Engine module
def engine do
  ALLM.Engine.new(
    adapter: ALLM.Providers.OpenAI,
    model: "gpt-4o-2024-08-06",
    params: %{temperature: 0.7, max_tokens: 4000}
  )
end
```

Then each operation collapses to a request + `ALLM.generate/3`:

```elixir
def generate_from_prompt(prompt) when is_binary(prompt) do
  request =
    ALLM.request(
      [
        ALLM.system("You are an expert chef and recipe creator..."),
        ALLM.user("Create a recipe for: #{prompt}\n\nPlease provide a complete recipe.")
      ],
      response_format: %{
        type: :json_schema,
        name: "recipe",
        strict: true,
        schema: @recipe_schema
      }
    )

  with {:ok, %ALLM.Response{output_text: json}} <- ALLM.generate(Meal.AI.engine(), request),
       {:ok, recipe_data} <- Jason.decode(json) do
    {:ok, recipe_data |> Map.put("source", :generated) |> normalize_recipe_fields()}
  end
end
```

Deletions this unlocks:
- The entire `Meal.AI.OpenAIClient` module (~165 lines) disappears.
- `get_api_key/0` is gone — `ALLM.Keys` handles precedence (§6.4).
- `handle_openai_response/1`, `parse_structured_response/1`, `parse_text_response/1` are gone — ALLM normalizes the response.
- The hard-coded `"gpt-4o-2024-08-06"` moves to a single place (engine config).

---

## Side-by-side: `parse_from_url/1` as a tool-calling chat

The current code in `recipe_generator.ex:209-225` is a fixed pipeline:

```
BrowserFetcher.fetch_recipe_data(url)
  └─ if schema.org JSON-LD found → map_schema_org_to_recipe/1    (no LLM call)
  └─ if only text available      → extract_recipe_from_text/2    (second OpenAI call)
```

With ALLM, the fetch becomes a **tool** the model can call, and the orchestration becomes a single `ALLM.chat/3`:

```elixir
fetch_tool =
  ALLM.tool(
    name: "fetch_recipe_page",
    description: "Fetch a recipe URL and return either schema.org JSON-LD or raw text.",
    schema: %{
      type: "object",
      properties: %{url: %{type: "string"}},
      required: ["url"]
    },
    handler: fn %{"url" => url} ->
      case Meal.AI.BrowserFetcher.fetch_recipe_data(url) do
        {:ok, %{type: :schema_org, data: data}} -> {:ok, %{kind: "jsonld", data: data}}
        {:ok, %{type: :text, data: text}} -> {:ok, %{kind: "text", text: String.slice(text, 0, 50_000)}}
        other -> other
      end
    end
  )

engine = ALLM.Engine.put_tool(Meal.AI.engine(), fetch_tool)

def parse_from_url(url) do
  {:ok, %ALLM.ChatResult{final_response: %{output_text: json}}} =
    ALLM.chat(engine, [
      ALLM.system("Extract a recipe from the fetched page. Use the fetch_recipe_page tool."),
      ALLM.user("Parse the recipe at #{url}")
    ],
    response_format: %{type: :json_schema, name: "recipe", strict: true, schema: @recipe_schema})

  with {:ok, data} <- Jason.decode(json) do
    {:ok, data |> Map.put("source", :url) |> Map.put("source_url", url) |> normalize_recipe_fields()}
  end
end
```

`ALLM.chat/3` runs the full tool loop: it calls the model, detects `finish_reason: :tool_calls`, runs the handler via `ALLM.ToolExecutor.Default`, appends a `:tool` message, and re-prompts until the model emits the final structured response (§10.5, §12 `mode: :auto`).

Two things to note:
1. `map_schema_org_to_recipe/1` and `extract_schema_text/1` in `recipe_generator.ex:363-532` stay as **domain helpers**, but they no longer need to decide branch — the model gets both kinds of payloads back in the tool result and produces a single structured recipe either way. If you want to keep the deterministic JSON-LD mapper for cost reasons, short-circuit before calling the model when `type == :schema_org`.
2. If you want tighter control (e.g. cap wall-clock, intercept the fetch for caching), switch to `mode: :manual` (§12) and call `ALLM.Session.submit_tool_result/3` yourself.

---

## Side-by-side: `modify_recipe/2` as a session

`modify_recipe/2` (recipe_generator.ex:255-310) currently re-encodes the full recipe into a JSON string on every call and sends it as a one-shot user message. That works once, but every subsequent "make it spicier" has to re-send the whole recipe.

With `ALLM.Session` (§11), the recipe + modification history is persisted as a `Thread`:

```elixir
def start_modification(recipe_map) do
  {:ok, session, _result} =
    ALLM.Session.start(
      Meal.AI.engine(),
      [
        ALLM.system("You are a recipe modifier. Preserve the recipe's character unless asked to change it."),
        ALLM.user("Here is the starting recipe:\n\n#{Jason.encode!(recipe_map, pretty: true)}\n\nAcknowledge and wait for modifications.")
      ],
      id: "recipe_session_#{recipe_map.id}"
    )

  Meal.Repo.insert!(%Meal.RecipeSession{id: session.id, state: :erlang.term_to_binary(session)})
  {:ok, session}
end

def modify_recipe(session_id, modification_prompt) do
  session = load_session!(session_id)

  {:ok, session, result} =
    ALLM.Session.reply(Meal.AI.engine(), session, modification_prompt,
      response_format: %{type: :json_schema, name: "recipe", strict: true, schema: @recipe_schema})

  save_session!(session)
  Jason.decode(result.final_response.output_text)
end
```

Because `ALLM.Session` is defined as plain data (spec §5.7), the `:erlang.term_to_binary` / `Jason` round-trip is safe. Keys never appear in the serialized form (§6.4).

---

## What streaming buys

Meal's UI currently has to wait for the full recipe JSON before rendering anything — `structured_request/4` blocks on `OpenAI.chat_completion/1` (openai_client.ex:129). Recipe generation with `max_tokens: 4000` can take 15–30 seconds.

Swapping `ALLM.generate/3` for `ALLM.stream/3` lets the Phoenix channel / LiveView push tokens as they arrive:

```elixir
{:ok, stream} = ALLM.stream(Meal.AI.engine(), messages, response_format: ...)

Enum.each(stream, fn
  {:text_delta, %{delta: delta}} -> Phoenix.PubSub.broadcast(Meal.PubSub, topic, {:delta, delta})
  {:tool_execution_started, %{name: name}} -> broadcast({:status, "running #{name}"})
  {:chat_completed, %{result: %{final_response: %{output_text: json}}}} -> broadcast({:done, Jason.decode!(json)})
  _ -> :ok
end)
```

No changes to `BrowserFetcher`, `@recipe_schema`, or `normalize_recipe_fields/1` — the event protocol (§8) sits on top.

---

## Suggested migration order

1. **Drop-in the engine.** Add `:allm` to `mix.exs`, construct an engine in `Meal.AI`, rewrite `generate_from_prompt/1` using `ALLM.generate/3`. Delete `Meal.AI.OpenAIClient`. Tests for `generate_from_prompt/1` should pass unchanged.
2. **Rewrite `modify_recipe/2`** as above — either one-shot like step 1, or as a persisted `ALLM.Session` if the UI benefits from multi-turn modifications.
3. **Turn `BrowserFetcher.fetch_recipe_data/1` into an `ALLM.Tool`** and rewrite `parse_from_url/1` to use `ALLM.chat/3`. Keep `map_schema_org_to_recipe/1` as a pre-check to skip the LLM when JSON-LD is present.
4. **Swap to streaming** (`ALLM.stream/3`) once the GraphQL/LiveView layer is ready to consume `ALLM.Event`s.
5. **Optional: multi-provider.** Because `ALLM.Engine.adapter` is swappable, running `modify_recipe/2` against `ALLM.Providers.Anthropic` becomes a one-line change — useful for A/B testing recipe quality.

---

## What ALLM doesn't give you for free

- `@recipe_schema` still has to be defined somewhere. ALLM accepts it via `response_format:`.
- `BrowserFetcher` and its Wallaby session lifecycle are out of scope.
- `map_schema_org_to_recipe/1`, ISO-8601 duration parsing, and `normalize_recipe_fields/1` are domain transforms — keep them as they are.
- The GraphQL resolver layer in `meal_web/graphql/resolvers/recipe_resolver.ex` is unaffected; it calls `Meal.AI.RecipeGenerator` the same way, the internals just shrink.

---

## Net change

Rough line-count delta for `server/lib/meal/ai/`:

| Module | Before | After |
|---|---|---|
| `openai_client.ex` | 165 | **deleted** |
| `recipe_generator.ex` | 557 | ~300 (prompts + `@recipe_schema` + `map_schema_org_to_recipe/1` + `normalize_recipe_fields/1`) |
| `browser_fetcher.ex` | unchanged | unchanged |

Plus: streaming, provider-neutrality, serializable sessions, telemetry (§29), built-in timeouts/cancellation (§30), and a testable fake adapter (§31) — none of which the hand-built version has today.
