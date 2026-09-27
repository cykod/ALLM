# scripts/record_prompt_cache_fixtures.exs
#
# Live wire probe and fixture recorder for provider prompt caching.
#
# Usage:
#
#     set -a; . ./.env; set +a; mix run scripts/record_prompt_cache_fixtures.exs --only acceptance
#     set -a; . ./.env; set +a; mix run scripts/record_prompt_cache_fixtures.exs
#
# Keys are read from the environment (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`).
# A project-root `.env` is loaded first, per key, only when that key is not
# already set: `EnvLoader.load/1` calls `System.put_env/2` unconditionally, so an
# unguarded load would let a stale `.env` override an explicit assignment. This
# mirrors `scripts/record_voyage_embeddings_fixtures.exs`.
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
#     expected 400). Writes
#     NO fixture. Acceptance is not a cache hit, so these arms send a short
#     prompt with a small output cap rather than the ~5k-token prefix the hit
#     arms need. Cost: a dozen tiny calls, well under $0.01.
#   * no flag — the full probe + recording pass. The recording arms (hit arms,
#     streams, recorded control bodies) are listed in `recording_arms/0`; that
#     list is empty until the recording pass is built, so today a bare run
#     makes no HTTP call and says so. If arms are defined before the recording
#     pass is wired, a bare run halts non-zero rather than exiting 0 unrecorded.
#
# The four probe parts (CLAUDE.md "live wire probe" rule)
# -------------------------------------------------------
#
#   1. Negative control — every "the provider accepts X" arm is paired with an
#      invented-field arm in the same run. A 200 is evidence the field is part
#      of the schema only once the API is shown to reject unknown fields.
#   2. Assert, don't narrate — every arm carries an expected status. Any
#      mismatch prints the want/got table to stderr and `System.halt(1)`s before
#      a single fixture is written. A 404 / `model_not_found` is reported as a
#      MISSING MODEL, distinct from a rejected field.
#   3. Record the body, not the status — recording arms write the response body
#      (error envelopes included) under `test/fixtures/<provider>/.../recorded/`.
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
# (Responses), `ALLM_PROBE_OPENAI_CHAT_MODELS` (Chat Completions),
# `ALLM_PROBE_ANTHROPIC_MODELS`.
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

  @default_openai_models ["gpt-5.6", "gpt-6-luna", "gpt-5.4-nano"]
  @default_openai_chat_models ["gpt-4o-mini"]
  @default_anthropic_models ["claude-haiku-4-5-20251001", "claude-sonnet-5", "claude-sonnet-4-6"]

  @prompt "Reply with the single word: ok"

  def run(argv) do
    mode = parse_mode(argv)
    load_dotenv(["OPENAI_API_KEY", "ANTHROPIC_API_KEY"])
    require_keys!(["OPENAI_API_KEY", "ANTHROPIC_API_KEY"])

    case mode do
      :acceptance ->
        run_acceptance()

      :all ->
        if Enum.empty?(pending_paths()) do
          IO.puts(
            "Nothing to record: every recording target is already a live recording, " <>
              "or no recording arms are defined yet (recording_arms/0 is empty). " <>
              "No HTTP requests were made. Run with --only acceptance for the acceptance arms."
          )
        else
          # Recording arms exist but the recording pass is not wired yet:
          # refuse rather than exit 0 having written nothing (the pass that
          # adds recording arms replaces this branch).
          IO.puts(
            :stderr,
            "#{length(pending_paths())} recording target(s) pending but the recording " <>
              "pass is not implemented — refusing to exit 0 with nothing recorded."
          )

          System.halt(1)
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
      # Load into a scratch copy, then set only the variables still unset.
      preset = Map.new(vars, &{&1, System.get_env(&1)})
      EnvLoader.load(path)

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
          "#{String.pad_trailing(r.model, 28)} want #{r.expect} got #{r.got}#{r.note}"
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
          "  want #{r.expect}  got #{r.got}  #{r.id} #{r.endpoint} #{r.model}#{r.note}"
        )

        IO.puts(:stderr, "    body: #{Jason.encode!(r.body)}")
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
  # Recording (overwrite guard)
  # ---------------------------------------------------------------------------

  # Each recording arm names its target path. Empty until the recording pass
  # is built; `pending_paths/0` then decides whether a bare run makes any call.
  defp recording_arms, do: []

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
  # HTTP
  # ---------------------------------------------------------------------------

  defp post(%{provider: :openai, endpoint: endpoint}, body) do
    Req.post(Map.fetch!(@openai_urls, endpoint),
      headers: [
        {"authorization", "Bearer " <> System.fetch_env!("OPENAI_API_KEY")},
        {"content-type", "application/json"}
      ],
      json: body,
      receive_timeout: 120_000,
      max_retries: 2
    )
  end

  # No `anthropic-beta` header: caching needs none.
  defp post(%{provider: :anthropic}, body) do
    Req.post(@anthropic_url,
      headers: [
        {"x-api-key", System.fetch_env!("ANTHROPIC_API_KEY")},
        {"anthropic-version", @anthropic_version},
        {"content-type", "application/json"}
      ],
      json: body,
      receive_timeout: 120_000,
      max_retries: 2
    )
  end
end

RecordPromptCacheFixtures.run(System.argv())
