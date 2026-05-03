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
end
