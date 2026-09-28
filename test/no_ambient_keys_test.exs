defmodule ALLM.NoAmbientKeysTest do
  # Pins the guarantee `test/test_helper.exs` makes: the default suite runs with
  # no provider key reachable from the environment, so no test can make a live
  # provider call just because the developer's shell sourced `.env`. Only an
  # explicit `--only live_*` / `--include live_*` run keeps the keys, and that
  # run filters this module out (it carries no live tag).
  use ExUnit.Case, async: true

  alias ALLM.Keys

  test "no *_API_KEY variable survives into the default suite" do
    leaked =
      for {name, value} <- System.get_env(),
          String.ends_with?(name, "_API_KEY"),
          value != "",
          do: name

    assert leaked == [],
           "ambient provider keys reached the test run: #{inspect(leaked)} — " <>
             "test/test_helper.exs must scrub them unless a live_* tag is included"
  end

  test "no provider key resolves from app config or .env" do
    assert Application.get_env(:allm, :keys, %{}) == %{}
    refute Application.get_env(:allm, :load_dotenv, false)

    for provider <- [:openai, :anthropic, :gemini, :google, :voyage, :elevenlabs, :typesafe] do
      assert Keys.get(provider) == {:error, :missing},
             "#{provider} resolved a key with no opts and an empty store"
    end
  end
end
