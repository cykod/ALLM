defmodule ALLM.ExamplesHelpersTest do
  @moduledoc """
  Phase 16.6 retro Finding 3 — Decision #20 default-temperature merge invariant.

  `examples/_helpers.exs` `engine/1` reads the provider row's
  `:default_temperature` (Gemini = `1.0` per Google's recommendation;
  OpenAI / Anthropic omit the key and inherit `0`) and injects it into
  `params: %{temperature: ...}` BEFORE merging caller-supplied
  `extra_opts`. The merge MUST deep-merge the `:params` map — a caller
  passing `params: %{max_tokens: 100}` (no `temperature` key) MUST
  preserve the row's default temperature, not silently lose it.

  This file exercises the `merge_with_params/2` test seam directly
  (rather than driving `engine/1`) because `engine/1` requires the
  provider's API key to be present in the environment via
  `ensure_key_present!/1`. Tests run under `mix test` without any keys
  set, so we exercise the merge logic via the `@doc false` seam.
  """

  use ExUnit.Case, async: true

  # `examples/_helpers.exs` is a script (not in `elixirc_paths`); load it at
  # test-module compile time via `Code.require_file/1` so `ExamplesHelpers.*`
  # resolves cleanly without compile-time warnings. The file is idempotent
  # under repeated `require_file` calls in the same VM.
  Code.require_file(Path.expand("../../examples/_helpers.exs", __DIR__))

  describe "merge_with_params/2 (Decision #20 deep-merge invariant)" do
    test "Gemini default — base carries temperature 1.0; no caller override → preserved" do
      base = [
        adapter: :stub,
        model: "gemini-3-flash-preview",
        params: %{temperature: 1.0}
      ]

      merged = ExamplesHelpers.merge_with_params(base, [])

      assert merged[:params] == %{temperature: 1.0}
    end

    test "OpenAI / Anthropic default — base carries temperature 0; no caller override → preserved" do
      base = [
        adapter: :stub,
        model: "gpt-5.4-nano",
        params: %{temperature: 0}
      ]

      merged = ExamplesHelpers.merge_with_params(base, [])

      assert merged[:params] == %{temperature: 0}
    end

    test "caller params: %{temperature: 0.5} OVERRIDES Gemini default 1.0" do
      base = [
        adapter: :stub,
        model: "gemini-3-flash-preview",
        params: %{temperature: 1.0}
      ]

      merged = ExamplesHelpers.merge_with_params(base, params: %{temperature: 0.5})

      assert merged[:params] == %{temperature: 0.5}
    end

    test "caller params: %{max_tokens: 100} (no :temperature) PRESERVES Gemini default 1.0" do
      # This is the foot-gun case. `Keyword.merge(base, extra_opts)` would
      # SHALLOW-replace the whole `:params` map, silently dropping the
      # row's `default_temperature`. The deep-merge fix preserves it.
      base = [
        adapter: :stub,
        model: "gemini-3-flash-preview",
        params: %{temperature: 1.0}
      ]

      merged = ExamplesHelpers.merge_with_params(base, params: %{max_tokens: 100})

      assert merged[:params] == %{temperature: 1.0, max_tokens: 100}
    end

    test "caller params: %{temperature: 0.2, max_tokens: 100} — caller temperature wins, max_tokens added" do
      base = [
        adapter: :stub,
        model: "gemini-3-flash-preview",
        params: %{temperature: 1.0}
      ]

      merged =
        ExamplesHelpers.merge_with_params(base, params: %{temperature: 0.2, max_tokens: 100})

      assert merged[:params] == %{temperature: 0.2, max_tokens: 100}
    end

    test "non-:params keys still shallow-replace as Keyword.merge would (model: caller wins)" do
      base = [
        adapter: :stub,
        model: "gemini-3-flash-preview",
        params: %{temperature: 1.0}
      ]

      merged = ExamplesHelpers.merge_with_params(base, model: "gemini-other")

      assert merged[:model] == "gemini-other"
      # And the params: default still survives the merge.
      assert merged[:params] == %{temperature: 1.0}
    end

    test "row WITHOUT :default_temperature (OpenAI/Anthropic shape) — base temperature 0 baseline preserved when caller overrides only max_tokens" do
      # Mirrors the `engine/1` flow when row omits `:default_temperature`:
      # `Map.get(row, :default_temperature, 0)` → `0`, base carries
      # `params: %{temperature: 0}`. Caller passing only `max_tokens`
      # must not clobber the `0` baseline.
      base = [
        adapter: :stub,
        model: "gpt-5.4-nano",
        params: %{temperature: 0}
      ]

      merged = ExamplesHelpers.merge_with_params(base, params: %{max_tokens: 100})

      assert merged[:params] == %{temperature: 0, max_tokens: 100}
    end
  end

  describe "provider rows and chat_provider?/1" do
    test "chat_provider?/1 is false for elevenlabs and true for every other row" do
      rows = ExamplesHelpers.provider_rows()

      # The rows are iterated, so a new chat row needs no edit here.
      for {name, _row} <- rows do
        assert ExamplesHelpers.chat_provider?(name) == (name != "elevenlabs"),
               "chat_provider?(#{inspect(name)})"
      end

      assert Map.has_key?(rows, "elevenlabs")
    end

    test "chat_provider?/1 raises ArgumentError for an unknown provider" do
      assert_raise ArgumentError, ~r/Unknown ALLM_PROVIDER "nope"/, fn ->
        ExamplesHelpers.chat_provider?("nope")
      end
    end

    test "the elevenlabs row is audio-only, keyed on ELEVENLABS_API_KEY, with a voice id" do
      row = Map.fetch!(ExamplesHelpers.provider_rows(), "elevenlabs")

      assert row.key_env == "ELEVENLABS_API_KEY"
      assert row.adapter == nil
      assert row.speech_adapter == ALLM.Providers.ElevenLabs.Speech
      assert row.transcription_adapter == ALLM.Providers.ElevenLabs.Transcription
      assert is_binary(row.speech_voice) and row.speech_voice != ""
    end

    test "the openai row carries speech_voice \"alloy\"" do
      assert Map.fetch!(ExamplesHelpers.provider_rows(), "openai").speech_voice == "alloy"
    end
  end

  describe "read_pcm_wav!/1 and pcm_chunks/3" do
    test "reads the streaming-WAV fixture to EOF: 24 kHz, 182,400 PCM bytes (examples/README.md)" do
      path = Path.expand("../../examples/fixtures/quick_brown_fox.wav", __DIR__)

      assert {24_000, pcm} = ExamplesHelpers.read_pcm_wav!(path)
      assert byte_size(pcm) == 182_400

      chunks = ExamplesHelpers.pcm_chunks(pcm, 24_000, 100)
      assert length(chunks) == 38
      assert Enum.all?(chunks, &(byte_size(&1) == 4_800))
    end
  end

  test "skip_exit_status/0 is neither a pass nor fail!/1's status" do
    assert ExamplesHelpers.skip_exit_status() not in [0, 1]
  end
end
