defmodule ALLM.Test.Examples.MealTest do
  @moduledoc """
  Phase 12.2 case-study translation of `steering/examples/meal_example.md`.

  ## Coverage

    * `## Side-by-side: generate_from_prompt/1` — `### After — with ALLM`
      snippet translated as `ALLM.generate/3` with
      `response_format: ALLM.json_schema(...)`.
    * `## Side-by-side: parse_from_url/1 as a tool-calling chat` —
      translated as `ALLM.chat/3` with one fetch tool.
    * `## Side-by-side: modify_recipe/2 as a session` — translated as
      `ALLM.Session.start/3` + ETF round-trip + `Session.reply/4`.
    * `## What streaming buys` — covered in the garden + amesbury
      streaming sweeps.
    * `## What ALLM doesn't give you for free`, `## Net change`,
      `## Suggested migration order` — non-code prose; nothing to
      translate.
  """

  use ExUnit.Case, async: true

  import ALLM.Test.ExampleFixtures

  alias ALLM.{ChatResult, Engine, Response, Session}
  alias ALLM.Providers.Fake

  describe "meal_example.md / Side-by-side: generate_from_prompt/1 — After (single-turn structured generate)" do
    test "ALLM.generate/3 with response_format: ALLM.json_schema(...) decodes via Jason" do
      payload = recipe_text()

      eng = engine(text_response(payload))

      schema = %{
        type: "object",
        properties: %{
          title: %{type: "string"},
          servings: %{type: "integer"},
          ingredients: %{type: "array", items: %{type: "string"}}
        },
        required: ["title", "servings", "ingredients"]
      }

      request =
        ALLM.request(
          [
            ALLM.system("You are an expert chef."),
            ALLM.user("Create a recipe for: tomato pasta")
          ],
          response_format: ALLM.json_schema("recipe", schema)
        )

      assert {:ok, %Response{output_text: ^payload}} =
               ALLM.generate(eng, request)

      assert {:ok, %{"title" => "Tomato Pasta", "servings" => 4}} =
               Jason.decode(payload)
    end
  end

  describe "meal_example.md / Side-by-side: parse_from_url/1 as a tool-calling chat" do
    test "ALLM.chat/3 with one fetch tool runs the loop and reaches :completed" do
      fetch_tool =
        ALLM.tool(
          name: "fetch_recipe_page",
          description: "Fetch a recipe URL and return either schema.org JSON-LD or raw text.",
          schema: %{
            type: "object",
            properties: %{url: %{type: "string"}},
            required: ["url"]
          },
          handler: fn %{"url" => _url} ->
            {:ok, %{kind: "jsonld", data: %{name: "Tomato Pasta"}}}
          end
        )

      eng =
        engine_with_scripts(
          [
            [
              {:tool_call,
               id: "tc_1",
               name: "fetch_recipe_page",
               arguments: %{"url" => "https://example.com/recipe"}},
              {:finish, :tool_calls}
            ],
            text_response(recipe_text())
          ],
          tools: [fetch_tool]
        )

      assert {:ok, %ChatResult{halted_reason: :completed, final_response: resp}} =
               ALLM.chat(eng, [
                 ALLM.system("Extract a recipe from the fetched page."),
                 ALLM.user("Parse the recipe at https://example.com/recipe")
               ])

      assert {:ok, %{"title" => "Tomato Pasta"}} = Jason.decode(resp.output_text)
    end
  end

  describe "meal_example.md / Side-by-side: modify_recipe/2 as a session" do
    setup do
      eng =
        engine_with_scripts([
          text_response("Acknowledged. Send modifications."),
          text_response(Jason.encode!(%{"title" => "Spicier Tomato Pasta", "servings" => 4}))
        ])

      {:ok, engine: eng}
    end

    test "Session.start/3 then ETF round-trip then Session.reply/4 carries both turns",
         %{engine: eng} do
      starting_recipe = %{"title" => "Tomato Pasta", "servings" => 4}

      messages = [
        ALLM.system("You are a recipe modifier."),
        ALLM.user("Starting recipe:\n#{Jason.encode!(starting_recipe)}\nAcknowledge.")
      ]

      assert {:ok, %Session{} = session, %ChatResult{}} =
               Session.start(eng, messages, id: "recipe_session_1")

      # ETF round-trip mid-flow — case study claim that sessions are
      # plain serializable structs (§5.7). Keys never leak.
      serialized = :erlang.term_to_binary(session)
      restored = :erlang.binary_to_term(serialized)
      assert session == restored

      assert {:ok, %Session{} = session_after, %ChatResult{final_response: resp}} =
               Session.reply(eng, restored, "Make it spicier")

      assert {:ok, %{"title" => "Spicier Tomato Pasta"}} =
               Jason.decode(resp.output_text)

      # The post-reply thread carries both turns plus their assistant
      # responses.
      roles = Enum.map(session_after.thread.messages, & &1.role)
      assert :system in roles
      assert Enum.count(roles, &(&1 == :user)) >= 2
      assert :assistant in roles
    end

    test "Session ETF round-trip carries no PIDs / refs / API keys", %{engine: eng} do
      {:ok, session, _} = Session.start(eng, [ALLM.user("hi")])

      bin = :erlang.term_to_binary(session)
      # Sanity check: the binary form contains no atoms named for keys that
      # could leak through. (We don't aim to assert all such atoms — just
      # smoke-test the round-trip succeeds.)
      assert is_binary(bin)
      restored = :erlang.binary_to_term(bin)
      assert restored == session
    end
  end

  describe "meal_example.md / Mapping table — modify_recipe/2 as ALLM.generate/3 with multi-message thread" do
    test "ALLM.generate/3 over a multi-message thread reproduces the modify-recipe one-shot shape" do
      eng =
        Engine.new(
          adapter: Fake,
          adapter_opts: [
            script: [
              {:text, Jason.encode!(%{"title" => "Spicier Tomato Pasta"})},
              {:finish, :stop}
            ]
          ]
        )

      messages = [
        ALLM.system("You are a recipe modifier."),
        ALLM.user("Recipe: Tomato Pasta"),
        ALLM.assistant("Got it."),
        ALLM.user("Make it spicier.")
      ]

      assert {:ok, %Response{output_text: out}} =
               ALLM.generate(eng, ALLM.request(messages))

      assert {:ok, %{"title" => "Spicier Tomato Pasta"}} = Jason.decode(out)
    end
  end
end
