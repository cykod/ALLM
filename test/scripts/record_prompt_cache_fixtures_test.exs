defmodule Scripts.RecordPromptCacheFixturesTest do
  @moduledoc """
  Tests for `scripts/record_prompt_cache_fixtures.exs`: the per-provider key
  redactor every recorded body passes through, and the recorder's target
  list against the recorded fixtures the suite consumes.

  The script is loaded with `Code.require_file/1`; its run line is skipped
  under `MIX_ENV=test`, so no HTTP call is made.

  The planted tokens below bind the redaction PATTERNS, not a leak path:
  none of the recorded provider error bodies echoes key material. Each
  provider's planted envelope is paired with a companion test asserting the
  sibling providers' patterns match nothing in it, so a pattern copied
  verbatim from a sibling fails loudly instead of redacting nothing.
  """

  use ExUnit.Case, async: true

  alias ALLM.Test.CacheUsageFixtures

  @script_path Path.expand("../../scripts/record_prompt_cache_fixtures.exs", __DIR__)

  setup_all do
    Code.require_file(@script_path)
    :ok
  end

  defp recorder, do: Module.concat(["RecordPromptCacheFixtures"])

  # One planted error envelope per provider, each shaped like that provider's
  # real 4xx body, carrying a key-shaped token of that provider only. The
  # OpenAI token copies the MASKED form OpenAI's real 401 echoes
  # (`test/fixtures/openai/speech/recorded/error_401_bad_key.json`), which a
  # pattern without `*` in its character class does not match at all.
  @planted %{
    openai:
      ~s|{"error":{"message":"Incorrect API key provided: sk-proj-*****************************9900.","type":"invalid_request_error","code":"invalid_api_key"}}|,
    anthropic:
      ~s|{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key sk-ant-api03-AbC123dEf456"}}|,
    gemini:
      ~s|{"error":{"code":400,"message":"API key not valid: AIzaSyA1b2C3d4E5f6G7h8I9j0 (token ya29.a0AfH6SMBx)","status":"INVALID_ARGUMENT"}}|
  }

  @providers [:openai, :anthropic, :gemini]

  for provider <- @providers do
    @provider provider

    test "#{provider}: the planted key-shaped token is redacted" do
      planted = @planted[@provider]
      assert planted =~ recorder().redactor(@provider), "premise: the plant must match"

      redacted = recorder().redact(@provider, planted)

      assert redacted =~ "[REDACTED]"
      refute redacted =~ recorder().redactor(@provider)
      # The envelope still decodes: redaction replaces tokens, not structure.
      assert {:ok, %{}} = Jason.decode(redacted)
    end

    test "#{provider}: sibling providers' patterns match nothing in its planted envelope" do
      planted = @planted[@provider]

      for sibling <- @providers -- [@provider] do
        refute planted =~ recorder().redactor(sibling),
               "#{sibling}'s pattern matched #{@provider}'s planted envelope"

        assert recorder().redact(sibling, planted) == planted
      end
    end
  end

  test "OpenAI's pattern does not claim an Anthropic key (sk-ant-)" do
    refute "sk-ant-api03-AbC123dEf456" =~ recorder().redactor(:openai)
  end

  test "no recorded prompt-cache fixture contains a key-shaped token for any provider" do
    for path <- CacheUsageFixtures.recorded_paths(), provider <- @providers do
      refute File.read!(path) =~ recorder().redactor(provider),
             "#{path} carries a #{provider} key-shaped token"
    end
  end

  test "the recorder's targets are exactly the recorded fixtures the suite consumes" do
    # The model lists are passed in (as defaults) rather than read from
    # ALLM_PROBE_* env, so an exported override cannot turn this red; the env is
    # never mutated from this async module.
    targets =
      recorder().recording_arms([])
      |> Enum.map(&Path.relative_to(&1.path, File.cwd!()))
      |> Enum.sort()

    assert targets == Enum.sort(CacheUsageFixtures.recorded_paths())
  end
end
