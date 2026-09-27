# scripts/record_prompt_cache_fixtures.exs
#
# Live wire probe and fixture recorder for provider prompt caching.
#
# Usage:
#
#     set -a; . ./.env; set +a; mix run scripts/record_prompt_cache_fixtures.exs --only acceptance
#     set -a; . ./.env; set +a; mix run scripts/record_prompt_cache_fixtures.exs
#
# Keys are read from the environment (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`,
# and `GEMINI_API_KEY` for the recording pass). A project-root `.env` is
# loaded first, per key, only when that key is not already set:
# `EnvLoader.load/1` calls `System.put_env/2` unconditionally, so an unguarded
# load would let a stale `.env` override an explicit assignment. This
# generalizes the `scripts/record_voyage_embeddings_fixtures.exs` guard to
# several keys.
#
# Modes
# -----
#
#   * `--only acceptance` — the acceptance arms only: does each provider ACCEPT
#     the wire fields `ALLM.Providers.OpenAI` and `ALLM.Providers.Anthropic`
#     emit for `Request.prompt_cache`? Arms OA-P1 (`prompt_cache_key`), OA-P2
#     (`prompt_cache_retention: "24h"`) on the Responses endpoint AND on Chat
#     Completions (a pre-GPT-5 model, `gpt-4o-mini` by default, because the
#     question of whether `"24h"` is accepted is per model, not per endpoint),
#     AN-P2 (top-level `cache_control` with `ttl: "1h"`), and one negative
#     control per endpoint (OA-C, OA-CC-C, AN-C: an invented top-level field,
#     expected 400). Writes NO fixture. Acceptance is not a cache hit, so these
#     arms send a short prompt with a small output cap rather than the
#     ~5k-token prefix the hit arms need. Cost: a dozen tiny calls, well under
#     $0.01.
#   * no flag — the full probe + recording pass. The overwrite guard runs
#     first: when every target in `recording_arms/0` is already a live
#     recording, the script makes NO HTTP call and exits 0. Otherwise it runs
#     the acceptance arms, then OA-P6 (gpt-6 routing through `ALLM.generate/3`),
#     then every recording arm, asserts all of them, and only then writes the
#     targets that are still pending. A target that is already a live
#     recording is never overwritten.
#
# Recording arms (the design's 27.5 arm table)
# --------------------------------------------
#
#   * OA-P4  Responses, `gpt-5.6` and `gpt-6-luna`: the ~5k prefix + key,
#            repeated; a later call must report `input_tokens_details.cached_tokens > 0`.
#   * OA-P5  Chat Completions stream, `gpt-5.4-nano`, `include_usage`: the
#            final usage chunk must report `prompt_tokens_details.cached_tokens > 0`.
#   * OA-C   Responses control (invented field → 400), body recorded.
#   * AN-P1  top-level `cache_control`, one arm per Anthropic model: the first
#            call must report `cache_creation_input_tokens > 0`, a later one
#            `cache_read_input_tokens > 0`. No `anthropic-beta` header.
#   * AN-P3  the AN-P1 request on the first Anthropic model, streamed. AN-P1
#            primed the cache, so ANY call may be the hit:
#            `message_start.message.usage.cache_read_input_tokens > 0`.
#   * AN-C   Messages control (invented field → 400), body recorded.
#   * GE-P1  Gemini `gemini-3-flash-preview`, no cache field (implicit caching);
#            a later call must report `usageMetadata.cachedContentTokenCount > 0`.
#   * GE-C   Gemini top-level invented field. INFORMATIONAL: ALLM sends no
#            top-level Gemini field, so a non-400 is reported, not fatal, and
#            the body is recorded only when the answer is 400.
#
# A repeat arm sends the identical request up to `@repeat_attempts` times,
# `@repeat_spacing_ms` apart, and stops at the first qualifying hit. Every
# prefix opens with a per-run nonce, so a run's first call is always a cache
# write even when an earlier run wrote the same recipe text with a 1h TTL.
#
# The four probe parts (CLAUDE.md "live wire probe" rule)
# -------------------------------------------------------
#
#   1. Negative control — every "the provider accepts X" arm is paired with an
#      invented-field arm in the same run. A 200 is evidence the field is part
#      of the schema only once the API is shown to reject unknown fields.
#   2. Assert, don't narrate — every arm carries an expected outcome. Any
#      mismatch prints the want/got table to stderr and `System.halt(1)`s before
#      a single fixture is written. A 404 / `model_not_found` is reported as a
#      MISSING MODEL, distinct from a rejected field.
#   3. Record the body, not the status — recording arms write the response body
#      (error envelopes included) under `test/fixtures/<provider>/.../recorded/`.
#      Every body passes through that provider's key redactor (`redact/2`)
#      before it is written or printed.
#   4. Overwrite guard first — every recording target is checked before any
#      HTTP call, so a fully-recorded tree costs zero live calls. A file is
#      overwritable only when absent or still carrying a synthesized marker.
#
# Before any HTTP call the script also checks, offline, that the cache fields
# each acceptance arm sends are exactly what the adapter's body builder emits
# for the same `prompt_cache`, so the probe tests the adapter's real output and
# not a hand-copied literal that could drift from it.
#
# Model lists are env-overridable (comma-separated): `ALLM_PROBE_OPENAI_MODELS`
# (Responses acceptance), `ALLM_PROBE_OPENAI_CHAT_MODELS` (Chat Completions
# acceptance), `ALLM_PROBE_ANTHROPIC_MODELS` (acceptance, AN-P1, AN-P3, AN-C),
# and `ALLM_PROBE_GEMINI_MODEL` (one model). OA-P4 and OA-P5 run fixed models
# because each names its fixture file.
#
# `redact/2`, `redactor/1` and `recording_arms/0,1` are public (`@doc false`) so
# `test/scripts/record_prompt_cache_fixtures_test.exs` can load this file with
# `Code.require_file/1` (the run line below is skipped under `MIX_ENV=test`).
#
# This script is NOT included in the published Hex package — `mix.exs` excludes
# `scripts/` from the package files list.

defmodule RecordPromptCacheFixtures do
  @moduledoc false

  alias ALLM.{Message, Request}
  alias ALLM.Providers.{Anthropic, OpenAI}

  @openai_urls %{
    responses: "https://api.openai.com/v1/responses",
    chat_completions: "https://api.openai.com/v1/chat/completions"
  }
  @anthropic_url "https://api.anthropic.com/v1/messages"
  @anthropic_version "2023-06-01"
  @gemini_base "https://generativelanguage.googleapis.com/v1beta/models/"

  @default_openai_models ["gpt-5.6", "gpt-6-luna", "gpt-5.4-nano"]
  @default_openai_chat_models ["gpt-4o-mini"]
  @default_anthropic_models ["claude-haiku-4-5-20251001", "claude-sonnet-5", "claude-sonnet-4-6"]
  @default_gemini_model "gemini-3-flash-preview"

  @prompt "Reply with the single word: ok"
  @question "Using the recipe above, reply with the single word: ok"

  @repeat_attempts 3
  @repeat_spacing_ms 2_000

  @fixtures Path.expand("../test/fixtures", __DIR__)

  # Key-shaped tokens per provider. Each provider has its own pattern; the
  # OpenAI one excludes `sk-ant-` so it cannot silently stand in for
  # Anthropic's, and every pattern admits `*` so a masked echo
  # (`sk-proj-****…9900`) is redacted too.
  @redactors %{
    openai: ~r/\b(?:sk-(?!ant-)|rk-|org-)[A-Za-z0-9_\-*]{6,}/,
    anthropic: ~r/\bsk-ant-[A-Za-z0-9_\-*]{6,}/,
    gemini: ~r/\b(?:AIza[A-Za-z0-9_\-*]{6,}|ya29\.[A-Za-z0-9_\-.*]{6,})/
  }

  def run(argv) do
    mode = parse_mode(argv)
    load_dotenv(["OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GEMINI_API_KEY"])

    case mode do
      :acceptance ->
        require_keys!(["OPENAI_API_KEY", "ANTHROPIC_API_KEY"])
        run_acceptance()

      :all ->
        pending = pending_paths()

        if pending == [] do
          IO.puts(
            "Nothing to record: every recording target is already a live recording. " <>
              "No HTTP requests were made. Run with --only acceptance for the acceptance arms."
          )
        else
          require_keys!(["OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GEMINI_API_KEY"])
          run_recording(pending)
        end
    end
  end

  defp parse_mode(["--only", "acceptance"]), do: :acceptance
  defp parse_mode([]), do: :all

  defp parse_mode(other) do
    IO.puts(:stderr, "Unknown arguments #{inspect(other)}. Use --only acceptance, or no flag.")
    System.halt(2)
  end

  # ---------------------------------------------------------------------------
  # Keys
  # ---------------------------------------------------------------------------

  defp load_dotenv(vars) do
    path = Path.expand(".env", Path.join(__DIR__, ".."))

    if Enum.any?(vars, &is_nil(System.get_env(&1))) and Code.ensure_loaded?(EnvLoader) and
         File.exists?(path) do
      # Snapshot the preset values, load `.env` into the environment, then
      # restore any value that was already set, so an explicit assignment wins.
      preset = Map.new(vars, &{&1, System.get_env(&1)})
      # Called through a variable: `:env_loader` is a dev-only dep, and the
      # test that loads this file compiles it without that module.
      apply(Module.concat(["EnvLoader"]), :load, [path])

      Enum.each(preset, fn
        {_var, nil} -> :ok
        {var, value} -> System.put_env(var, value)
      end)
    end

    :ok
  end

  defp require_keys!(vars) do
    missing = Enum.filter(vars, &(System.get_env(&1) in [nil, ""]))

    unless missing == [] do
      IO.puts(
        :stderr,
        "#{Enum.join(missing, ", ")} not set (checked the environment and project-root " <>
          ".env) — refusing to probe."
      )

      System.halt(1)
    end
  end

  # ---------------------------------------------------------------------------
  # Redaction
  # ---------------------------------------------------------------------------

  @doc false
  @spec redact(:openai | :anthropic | :gemini, String.t()) :: String.t()
  def redact(provider, text) when is_binary(text),
    do: String.replace(text, Map.fetch!(@redactors, provider), "[REDACTED]")

  @doc false
  @spec redactor(:openai | :anthropic | :gemini) :: Regex.t()
  def redactor(provider), do: Map.fetch!(@redactors, provider)

  # ---------------------------------------------------------------------------
  # Acceptance arms
  # ---------------------------------------------------------------------------

  defp models(var, default) do
    case System.get_env(var) do
      nil -> default
      "" -> default
      list -> list |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end
  end

  defp nonce, do: "allm-probe-#{System.os_time(:second)}-#{System.unique_integer([:positive])}"

  # Each arm: the provider, the endpoint, the model, the extra top-level fields it sends,
  # the `prompt_cache` those fields must equal the adapter's translation of
  # (nil for a control arm), and the expected status.
  defp acceptance_arms do
    key = nonce()
    openai = models("ALLM_PROBE_OPENAI_MODELS", @default_openai_models)
    openai_chat = models("ALLM_PROBE_OPENAI_CHAT_MODELS", @default_openai_chat_models)
    anthropic = models("ALLM_PROBE_ANTHROPIC_MODELS", @default_anthropic_models)

    oa =
      Enum.flat_map(openai, &openai_arms(&1, :responses, key)) ++
        Enum.flat_map(openai_chat, &openai_arms(&1, :chat_completions, key))

    an =
      Enum.map(anthropic, fn model ->
        %{
          id: "AN-P2",
          provider: :anthropic,
          endpoint: :messages,
          model: model,
          prompt_cache: %{key: key, retention: :long},
          fields: %{"cache_control" => %{"type" => "ephemeral", "ttl" => "1h"}},
          expect: 200
        }
      end)

    controls = [
      %{
        id: "OA-C",
        provider: :openai,
        endpoint: :responses,
        model: hd(openai),
        prompt_cache: nil,
        fields: %{"totallyNotAField" => %{}},
        expect: 400
      },
      %{
        id: "OA-CC-C",
        provider: :openai,
        endpoint: :chat_completions,
        model: hd(openai_chat),
        prompt_cache: nil,
        fields: %{"totallyNotAField" => %{}},
        expect: 400
      },
      %{
        id: "AN-C",
        provider: :anthropic,
        endpoint: :messages,
        model: hd(anthropic),
        prompt_cache: nil,
        fields: %{"totallyNotAField" => %{}},
        expect: 400
      }
    ]

    oa ++ an ++ controls
  end

  defp openai_arms(model, endpoint, key) do
    [
      %{
        id: "OA-P1",
        provider: :openai,
        endpoint: endpoint,
        model: model,
        prompt_cache: %{key: key, retention: :short},
        fields: %{"prompt_cache_key" => key},
        expect: 200
      },
      %{
        id: "OA-P2",
        provider: :openai,
        endpoint: endpoint,
        model: model,
        prompt_cache: %{key: key, retention: :long},
        fields: %{"prompt_cache_key" => key, "prompt_cache_retention" => "24h"},
        expect: 200
      }
    ]
  end

  defp run_acceptance do
    arms = acceptance_arms()
    check_adapter_parity!(arms)

    IO.puts("\n-- prompt-cache acceptance probe (live, #{length(arms)} requests) --")
    results = Enum.map(arms, &probe_arm/1)

    Enum.each(results, fn r ->
      IO.puts(
        "  #{if r.ok?, do: "ok  ", else: "FAIL"} #{String.pad_trailing(r.id, 7)} " <>
          "#{String.pad_trailing(to_string(r.endpoint), 17)} " <>
          "#{String.pad_trailing(r.model, 28)} " <>
          redact(r.provider, "want #{r.expect} got #{r.got}#{r.note}")
      )
    end)

    halt_unless_all_ok(results)
    IO.puts("  Every cache field is accepted and every control is rejected.\n")
    results
  end

  # Offline: the fields each accepting arm sends must be exactly what the
  # adapter adds for that `prompt_cache`. A drift here means the probe would be
  # testing a literal the adapter no longer emits.
  defp check_adapter_parity!(arms) do
    mismatches =
      for %{prompt_cache: pc} = arm <- arms,
          pc != nil,
          added = adapter_added_fields(arm, pc),
          added != arm.fields,
          do: {arm, added}

    unless mismatches == [] do
      IO.puts(
        :stderr,
        "\nProbe literals drifted from the adapter translation — refusing to probe.\n"
      )

      Enum.each(mismatches, fn {arm, added} ->
        IO.puts(
          :stderr,
          "  #{arm.id} #{arm.endpoint} #{arm.model}: probe sends #{inspect(arm.fields)}"
        )

        IO.puts(
          :stderr,
          "  #{String.duplicate(" ", String.length(arm.id))} adapter emits #{inspect(added)}"
        )
      end)

      System.halt(1)
    end
  end

  defp adapter_added_fields(arm, pc) do
    with_pc = build_adapter_body(arm, pc)
    without = build_adapter_body(arm, nil)
    Map.drop(with_pc, Map.keys(without))
  end

  defp build_adapter_body(%{provider: :openai, endpoint: endpoint, model: model}, pc),
    do: OpenAI.to_openai_request_body(adapter_request(model, pc), endpoint, [])

  defp build_adapter_body(%{provider: :anthropic, model: model}, pc),
    do: Anthropic.to_anthropic_request_body(adapter_request(model, pc))

  defp adapter_request(model, pc),
    do: Request.new([%Message{role: :user, content: @prompt}], model: model, prompt_cache: pc)

  defp probe_arm(arm) do
    {got, body} =
      case post(arm, request_body(arm)) do
        {:ok, response} -> {"#{response.status}", response.body}
        {:error, reason} -> {"ERR " <> inspect(reason), nil}
      end

    ok? = got == "#{arm.expect}"

    %{
      id: arm.id,
      provider: arm.provider,
      endpoint: arm.endpoint,
      model: arm.model,
      expect: arm.expect,
      got: got,
      ok?: ok?,
      note: note(ok?, got, body),
      body: body
    }
  end

  defp request_body(%{provider: :openai, endpoint: :responses, model: model, fields: fields}) do
    Map.merge(%{"model" => model, "input" => @prompt, "max_output_tokens" => 16}, fields)
  end

  defp request_body(%{
         provider: :openai,
         endpoint: :chat_completions,
         model: model,
         fields: fields
       }) do
    Map.merge(
      %{
        "model" => model,
        "messages" => [%{"role" => "user", "content" => @prompt}],
        "max_tokens" => 16
      },
      fields
    )
  end

  defp request_body(%{provider: :anthropic, model: model, fields: fields}) do
    Map.merge(
      %{
        "model" => model,
        "max_tokens" => 16,
        "messages" => [%{"role" => "user", "content" => @prompt}]
      },
      fields
    )
  end

  defp note(true, _got, _body), do: ""

  defp note(false, got, body) do
    kind = if missing_model?(got, body), do: "MISSING MODEL", else: "REJECTED"
    "  <- #{kind}: #{error_summary(body)}"
  end

  defp missing_model?("404", _body), do: true

  defp missing_model?(_got, %{"error" => %{"code" => "model_not_found"}}), do: true
  defp missing_model?(_got, _body), do: false

  defp error_summary(%{"error" => %{} = err}) do
    [err["type"], err["code"], err["param"], err["message"]]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" | ")
  end

  defp error_summary(body), do: inspect(body, limit: 20, printable_limit: 300)

  defp halt_unless_all_ok(results) do
    if Enum.all?(results, & &1.ok?) do
      :ok
    else
      IO.puts(:stderr, "\nPrompt-cache acceptance FAILED — nothing recorded.\n")

      for r <- results, not r.ok? do
        IO.puts(
          :stderr,
          redact(
            r.provider,
            "  want #{r.expect}  got #{r.got}  #{r.id} #{r.endpoint} #{r.model}#{r.note}"
          )
        )

        IO.puts(:stderr, "    body: " <> redact(r.provider, Jason.encode!(r.body)))
      end

      IO.puts(
        :stderr,
        "\nA rejected OA-P2 or AN-P2 arm means the adapter's `retention: :long` wire value\n" <>
          "is not accepted by that model: escalate, do not change the translation table\n" <>
          "to route around it. A MISSING MODEL means the model id itself does not exist."
      )

      System.halt(1)
    end
  end

  # ---------------------------------------------------------------------------
  # Recording arms (overwrite guard)
  # ---------------------------------------------------------------------------

  # `recording_arms/0` resolves the env overrides; `recording_arms/1` takes the
  # model choices as arguments (missing keys take the defaults, NOT the env) so
  # the target-parity test is independent of the developer's environment.
  @doc false
  @spec recording_arms() :: [map()]
  def recording_arms do
    recording_arms(
      anthropic_models: models("ALLM_PROBE_ANTHROPIC_MODELS", @default_anthropic_models),
      gemini_model:
        System.get_env("ALLM_PROBE_GEMINI_MODEL") |> blank_default(@default_gemini_model)
    )
  end

  @doc false
  @spec recording_arms(keyword()) :: [map()]
  def recording_arms(opts) when is_list(opts) do
    anthropic = Keyword.get(opts, :anthropic_models, @default_anthropic_models)
    gemini = Keyword.get(opts, :gemini_model, @default_gemini_model)

    [
      %{
        id: "OA-P4",
        kind: :hit,
        provider: :openai,
        endpoint: :responses,
        model: "gpt-5.6",
        path: fixture("openai/responses/recorded/prompt_cache_hit.json")
      },
      %{
        id: "OA-P4",
        kind: :hit,
        provider: :openai,
        endpoint: :responses,
        model: "gpt-6-luna",
        path: fixture("openai/responses/recorded/prompt_cache_hit_gpt6.json")
      },
      %{
        id: "OA-P5",
        kind: :stream_hit,
        provider: :openai,
        endpoint: :chat_completions,
        model: "gpt-5.4-nano",
        path: fixture("openai/chat_completions/recorded/prompt_cache_stream.sse")
      },
      %{
        id: "OA-C",
        kind: :control,
        provider: :openai,
        endpoint: :responses,
        model: "gpt-5.6",
        path: fixture("openai/responses/recorded/prompt_cache_unknown_field.json")
      }
    ] ++
      Enum.map(anthropic, fn model ->
        %{
          id: "AN-P1",
          kind: :hit,
          provider: :anthropic,
          endpoint: :messages,
          model: model,
          path: fixture("anthropic/messages/recorded/prompt_cache_hit_#{model}.json")
        }
      end) ++
      [
        %{
          id: "AN-P3",
          kind: :stream_hit,
          provider: :anthropic,
          endpoint: :messages,
          model: hd(anthropic),
          path: fixture("anthropic/messages/recorded/prompt_cache_stream.sse")
        },
        %{
          id: "AN-C",
          kind: :control,
          provider: :anthropic,
          endpoint: :messages,
          model: hd(anthropic),
          path: fixture("anthropic/messages/recorded/prompt_cache_unknown_field.json")
        },
        %{
          id: "GE-P1",
          kind: :hit,
          provider: :gemini,
          endpoint: :generate_content,
          model: gemini,
          path: fixture("gemini/generate_content/recorded/prompt_cache_hit.json")
        },
        %{
          id: "GE-C",
          kind: :informational_control,
          provider: :gemini,
          endpoint: :generate_content,
          model: gemini,
          path: fixture("gemini/generate_content/recorded/prompt_cache_unknown_field.json")
        }
      ]
  end

  defp blank_default(nil, default), do: default
  defp blank_default("", default), do: default
  defp blank_default(value, _default), do: String.trim(value)

  defp fixture(relative), do: Path.join(@fixtures, relative)

  defp pending_paths do
    recording_arms() |> Enum.map(& &1.path) |> Enum.filter(&overwritable?/1)
  end

  # Overwritable when absent, or when still a synthesized placeholder: a JSON
  # file with a leading `_comment`, or an SSE file whose first line is a
  # `: synthesized` comment. A live recording carries neither.
  defp overwritable?(path) do
    case File.read(path) do
      {:error, :enoent} ->
        true

      {:ok, contents} ->
        synthesized?(Path.extname(path), contents)

      {:error, reason} ->
        raise "cannot read #{path}: #{:file.format_error(reason)}"
    end
  end

  defp synthesized?(".sse", contents), do: contents =~ ~r/\A:\s*synthesized/i

  defp synthesized?(_ext, contents) do
    match?({:ok, %{"_comment" => _}}, Jason.decode(contents))
  end

  # ---------------------------------------------------------------------------
  # Recording pass
  # ---------------------------------------------------------------------------

  defp run_recording(pending) do
    IO.puts("#{length(pending)} recording target(s) pending; running the full probe.")
    run_acceptance()

    oa_p6 = run_oa_p6()
    run = nonce()
    prefix = prefix(run)
    IO.puts("-- recording arms (run #{run}, prefix #{byte_size(prefix)} bytes) --")

    results =
      Enum.map(recording_arms(), fn arm ->
        r = run_arm(arm, prefix, run)
        print_result(r)
        r
      end)

    halt_unless_recorded_ok([oa_p6 | results])

    written =
      for %{record: content, path: path} <- results, is_binary(content), path in pending do
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, content)
        Path.relative_to(path, Path.expand("..", __DIR__))
      end

    IO.puts("\nWrote #{length(written)} fixture(s):")
    Enum.each(written, &IO.puts("  " <> &1))
    IO.puts("HTTP calls this run: #{http_calls()}")
  end

  # ~5k tokens of recipe text, opened by the run nonce so every run starts
  # with a cache write. Clears OpenAI's 1,024, Anthropic's 4,096 (Haiku 4.5)
  # and Gemini 3's 4,096-token minimums.
  defp prefix(run) do
    cuts = ["short ribs", "chuck roast", "lamb shoulder", "pork belly", "oxtail", "brisket"]
    liquids = ["red wine", "dark stock", "cider", "tomato passata", "stout", "dashi"]
    aromatics = ["shallots", "garlic", "fennel", "celery root", "leeks", "star anise"]

    steps =
      for i <- 1..90 do
        "Step #{i}. Sear the #{Enum.at(cuts, rem(i, 6))} in batches over medium-high heat " <>
          "until deeply browned, then soften the #{Enum.at(aromatics, rem(i * 5, 6))} in the " <>
          "rendered fat, deglaze with the #{Enum.at(liquids, rem(i * 7, 6))}, scrape up the " <>
          "fond, return the meat, cover and braise at 150 C for #{60 + rem(i * 13, 120)} " <>
          "minutes, checking that the liquid stays at a bare simmer."
      end

    "Probe #{run}. You are a sous-chef in cook mode. The recipe the cook is following:\n\n" <>
      Enum.join(steps, "\n")
  end

  defmodule PathFinch do
    @moduledoc false
    # A pass-through `:finch_module` for OA-P6: forwards to Finch and records
    # the request path, so the probe observes which endpoint ALLM really
    # called (the response id is not surfaced on this path).
    def async_request(%Finch.Request{} = req, name, opts) do
      Agent.update(:allm_probe_oa_p6_paths, &(&1 ++ [req.path]))
      Finch.async_request(req, name, opts)
    end

    def cancel_async_request(ref), do: Finch.cancel_async_request(ref)
  end

  # OA-P6: gpt-6-luna through ALLM itself, default dispatch then forced Chat
  # Completions. No `temperature` (the engine is built directly, not via
  # `examples/_helpers.exs`).
  defp run_oa_p6 do
    model = "gpt-6-luna"
    offline_ok? = OpenAI.dispatch_endpoint(model, []) == :responses

    chat_body =
      OpenAI.to_openai_request_body(
        Request.new([ALLM.user(@prompt)], model: model, max_tokens: 64),
        :chat_completions,
        []
      )

    offline_ok? = offline_ok? and Map.has_key?(chat_body, "max_completion_tokens")

    calls =
      for {label, adapter_opts, want_suffix} <- [
            {"default dispatch", [], "/v1/responses"},
            {"endpoint: :chat_completions", [endpoint: :chat_completions], "/v1/chat/completions"}
          ] do
        {:ok, seen} = Agent.start_link(fn -> [] end, name: :allm_probe_oa_p6_paths)

        engine =
          ALLM.Engine.new(
            adapter: OpenAI,
            model: model,
            adapter_opts: adapter_opts ++ [finch_module: __MODULE__.PathFinch]
          )

        req = Request.new([ALLM.user(@prompt)], max_tokens: 64)
        bump_calls()
        outcome = ALLM.generate(engine, req)
        paths = Agent.get(seen, & &1)
        Agent.stop(seen)
        path_ok? = match?([_], paths) and String.ends_with?(hd(paths), want_suffix)
        seen_note = "path #{inspect(paths)} (want …#{want_suffix})"

        case outcome do
          {:ok, %{finish_reason: :error} = resp} ->
            {label, false, "finish_reason :error #{inspect(resp.metadata[:error])}; #{seen_note}"}

          {:ok, resp} ->
            {label, path_ok?,
             "#{inspect(resp.finish_reason)} #{inspect(resp.output_text)}; " <> seen_note}

          {:error, err} ->
            {label, false, "error #{inspect(err)}; #{seen_note}"}
        end
      end

    ok? = offline_ok? and Enum.all?(calls, fn {_, ok?, _} -> ok? end)

    got =
      Enum.map_join(calls, "; ", fn {label, _, detail} -> "#{label}: #{detail}" end)

    r = %{
      id: "OA-P6",
      kind: :routing,
      provider: :openai,
      model: model,
      path: nil,
      want:
        "200 on both, on the endpoint dispatched (offline: dispatch :responses, " <>
          "max_completion_tokens)",
      got: "offline #{offline_ok?}; " <> got,
      ok?: ok?,
      calls: 2,
      record: nil
    }

    print_result(r)
    r
  end

  defp run_arm(%{kind: :control} = arm, prefix, _run) do
    {status, raw} = send_arm(arm, prefix, nil, %{"totallyNotAField" => %{}})
    ok? = status == 400

    result(arm, "400", "#{status}", ok?, 1, if(ok?, do: pretty(arm.provider, raw)))
  end

  defp run_arm(%{kind: :informational_control} = arm, prefix, _run) do
    {status, raw} = send_arm(arm, prefix, nil, %{"totallyNotAField" => %{}})
    record = if status == 400, do: pretty(arm.provider, raw)

    arm
    |> result("400 (informational)", "#{status}", true, 1, record)
    |> Map.put(:informational_miss?, status != 400)
  end

  # A qualifying hit: a 200 reporting cache reads, on a repeat attempt (or on
  # any attempt when the cache was already primed). Decides both when the
  # repeat loop stops and which attempt is recorded.
  defp hit?(status, counts, i, first_counts?),
    do: status == 200 and (i > 1 or first_counts?) and (counts.read || 0) > 0

  defp run_arm(%{kind: kind} = arm, prefix, run) when kind in [:hit, :stream_hit] do
    stream? = kind == :stream_hit
    # AN-P3 re-sends AN-P1's request, which already wrote the cache.
    first_counts? = arm.id == "AN-P3"

    attempts =
      Enum.reduce_while(1..@repeat_attempts, [], fn i, acc ->
        if i > 1, do: Process.sleep(@repeat_spacing_ms)
        {status, raw} = send_arm(arm, prefix, run, %{}, stream?)
        counts = counts(arm, status, raw)
        acc = acc ++ [%{status: status, raw: raw, counts: counts}]

        if hit?(status, counts, i, first_counts?) or status != 200,
          do: {:halt, acc},
          else: {:cont, acc}
      end)

    hit_index =
      Enum.find_index(Enum.with_index(attempts, 1), fn {a, i} ->
        hit?(a.status, a.counts, i, first_counts?)
      end)

    first = hd(attempts)
    write_ok? = arm.id != "AN-P1" or (first.counts.write || 0) > 0
    ok? = hit_index != nil and write_ok?

    got =
      Enum.map_join(Enum.with_index(attempts, 1), " / ", fn {a, i} ->
        "##{i} #{a.status} in=#{inspect(a.counts.input)} read=#{inspect(a.counts.read)} " <>
          "write=#{inspect(a.counts.write)}"
      end)

    record =
      if ok? do
        hit = Enum.at(attempts, hit_index)
        if stream?, do: redact(arm.provider, hit.raw), else: pretty(arm.provider, hit.raw)
      end

    result(arm, want(arm), got, ok?, length(attempts), record)
  end

  defp want(%{id: "AN-P1"}), do: "#1 write>0, a later call read>0"
  defp want(%{id: "AN-P3"}), do: "any call read>0 (primed by AN-P1)"
  defp want(_arm), do: "a call after #1 read>0"

  defp result(arm, want, got, ok?, calls, record) do
    %{
      id: arm.id,
      kind: arm.kind,
      provider: arm.provider,
      model: arm.model,
      path: arm.path,
      want: want,
      got: got,
      ok?: ok?,
      calls: calls,
      record: record
    }
  end

  defp pretty(provider, raw) do
    body = Jason.decode!(raw)
    redact(provider, Jason.encode!(body, pretty: true) <> "\n")
  end

  defp print_result(r) do
    mark =
      cond do
        Map.get(r, :informational_miss?) -> "info"
        r.ok? -> "ok  "
        true -> "FAIL"
      end

    IO.puts(
      "  #{mark} #{String.pad_trailing(r.id, 6)} #{String.pad_trailing(r.model, 26)} " <>
        redact(r.provider, "calls=#{r.calls}  want #{r.want}  got #{r.got}")
    )
  end

  defp halt_unless_recorded_ok(results) do
    failed = Enum.reject(results, & &1.ok?)

    Enum.each(results, fn r ->
      if Map.get(r, :informational_miss?) do
        IO.puts(
          "  note: #{r.id} #{r.model} answered #{redact(r.provider, to_string(r.got))}, not 400. " <>
            "Informational only " <>
            "(ALLM sends no top-level Gemini field); its body is not recorded."
        )
      end
    end)

    unless failed == [] do
      IO.puts(:stderr, "\nPrompt-cache recording FAILED — nothing recorded.\n")
      IO.puts(:stderr, "  arm    model                      want | got")

      Enum.each(failed, fn r ->
        IO.puts(
          :stderr,
          redact(
            r.provider,
            "  #{String.pad_trailing(r.id, 6)} #{String.pad_trailing(r.model, 26)} " <>
              "#{r.want} | #{r.got}"
          )
        )
      end)

      IO.puts(
        :stderr,
        "\nCaching is best-effort: a repeat arm that missed #{@repeat_attempts} times is a\n" <>
          "report, not a reason to loosen the assertion. HTTP calls this run: #{http_calls()}."
      )

      System.halt(1)
    end
  end

  # Cache counters read straight from the wire body (never through ALLM).
  defp counts(_arm, status, _raw) when status != 200, do: %{input: nil, read: nil, write: nil}

  defp counts(%{provider: :openai, endpoint: :responses}, _status, raw) do
    u = Jason.decode!(raw)["usage"] || %{}
    d = u["input_tokens_details"] || %{}
    %{input: u["input_tokens"], read: d["cached_tokens"], write: d["cache_write_tokens"]}
  end

  defp counts(%{provider: :openai, endpoint: :chat_completions}, _status, raw) do
    u = raw |> sse_data() |> Enum.find_value(& &1["usage"]) || %{}
    d = u["prompt_tokens_details"] || %{}
    %{input: u["prompt_tokens"], read: d["cached_tokens"], write: d["cache_write_tokens"]}
  end

  defp counts(%{provider: :anthropic, kind: :stream_hit}, _status, raw) do
    start = raw |> sse_data() |> Enum.find(&(&1["type"] == "message_start")) || %{}
    anthropic_counts(get_in(start, ["message", "usage"]) || %{})
  end

  defp counts(%{provider: :anthropic}, _status, raw),
    do: anthropic_counts(Jason.decode!(raw)["usage"] || %{})

  defp counts(%{provider: :gemini}, _status, raw) do
    u = Jason.decode!(raw)["usageMetadata"] || %{}
    %{input: u["promptTokenCount"], read: u["cachedContentTokenCount"], write: nil}
  end

  defp anthropic_counts(u) do
    %{
      input: u["input_tokens"],
      read: u["cache_read_input_tokens"],
      write: u["cache_creation_input_tokens"]
    }
  end

  defp sse_data(raw) do
    for "data:" <> rest <- String.split(raw, "\n"),
        data = String.trim(rest),
        data != "[DONE]",
        {:ok, %{} = decoded} <- [Jason.decode(data)],
        do: decoded
  end

  # ---------------------------------------------------------------------------
  # Recording request bodies
  # ---------------------------------------------------------------------------

  defp send_arm(arm, prefix, key, extra, stream? \\ false) do
    body = arm |> hit_body(prefix, key, stream?) |> Map.merge(extra)

    case post(arm, body, decode_body: false) do
      {:ok, %{status: status, body: raw}} -> {status, raw}
      {:error, reason} -> {"ERR " <> inspect(reason), ""}
    end
  end

  defp hit_body(%{provider: :openai, endpoint: :responses, model: model}, prefix, key, _stream?) do
    %{
      "model" => model,
      "input" => [
        %{"role" => "system", "content" => prefix},
        %{"role" => "user", "content" => @question}
      ],
      "max_output_tokens" => 16
    }
    |> put_if("prompt_cache_key", key)
  end

  defp hit_body(%{provider: :openai, endpoint: :chat_completions} = arm, prefix, key, stream?) do
    %{
      "model" => arm.model,
      "messages" => [
        %{"role" => "system", "content" => prefix},
        %{"role" => "user", "content" => @question}
      ],
      "max_completion_tokens" => 16
    }
    |> put_if("prompt_cache_key", key)
    |> put_stream(stream?, %{"stream_options" => %{"include_usage" => true}})
  end

  defp hit_body(%{provider: :anthropic, model: model}, prefix, key, stream?) do
    %{
      "model" => model,
      "max_tokens" => 16,
      "system" => prefix,
      "messages" => [%{"role" => "user", "content" => @question}]
    }
    |> then(fn body ->
      if key, do: Map.put(body, "cache_control", %{"type" => "ephemeral"}), else: body
    end)
    |> put_stream(stream?, %{})
  end

  defp hit_body(%{provider: :gemini}, prefix, _key, _stream?) do
    %{
      "systemInstruction" => %{"parts" => [%{"text" => prefix}]},
      "contents" => [%{"role" => "user", "parts" => [%{"text" => @question}]}],
      "generationConfig" => %{"maxOutputTokens" => 16}
    }
  end

  defp put_if(body, _k, nil), do: body
  defp put_if(body, k, v), do: Map.put(body, k, v)

  defp put_stream(body, false, _extra), do: body
  defp put_stream(body, true, extra), do: body |> Map.put("stream", true) |> Map.merge(extra)

  # ---------------------------------------------------------------------------
  # HTTP
  # ---------------------------------------------------------------------------

  defp bump_calls, do: Process.put(:prompt_cache_http_calls, http_calls() + 1)
  defp http_calls, do: Process.get(:prompt_cache_http_calls, 0)

  defp post(arm, body, req_opts \\ [])

  defp post(%{provider: :openai, endpoint: endpoint}, body, req_opts) do
    bump_calls()

    Req.post(
      Map.fetch!(@openai_urls, endpoint),
      [
        headers: [
          {"authorization", "Bearer " <> System.fetch_env!("OPENAI_API_KEY")},
          {"content-type", "application/json"}
        ],
        json: body,
        receive_timeout: 120_000,
        retry: false
      ] ++ req_opts
    )
  end

  # No `anthropic-beta` header: caching needs none.
  defp post(%{provider: :anthropic}, body, req_opts) do
    bump_calls()

    Req.post(
      @anthropic_url,
      [
        headers: [
          {"x-api-key", System.fetch_env!("ANTHROPIC_API_KEY")},
          {"anthropic-version", @anthropic_version},
          {"content-type", "application/json"}
        ],
        json: body,
        receive_timeout: 120_000,
        retry: false
      ] ++ req_opts
    )
  end

  # The key rides the `x-goog-api-key` header, never the URL.
  defp post(%{provider: :gemini, model: model}, body, req_opts) do
    bump_calls()

    Req.post(
      @gemini_base <> model <> ":generateContent",
      [
        headers: [
          {"x-goog-api-key", System.fetch_env!("GEMINI_API_KEY")},
          {"content-type", "application/json"}
        ],
        json: body,
        receive_timeout: 120_000,
        retry: false
      ] ++ req_opts
    )
  end
end

if Mix.env() != :test do
  RecordPromptCacheFixtures.run(System.argv())
end
