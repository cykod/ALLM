# scripts/record_openai_moderation_fixtures.exs
#
# Fixture recorder for `test/fixtures/openai/moderations/recorded/`.
# Runs against the live OpenAI Moderations API; gated on `OPENAI_API_KEY`.
#
# Idempotent by construction: it NEVER touches
# `test/fixtures/openai/moderations/synthesized/`, and it refuses to overwrite a
# `recorded/` file that has already been recorded — i.e. one that no longer
# carries a leading `_comment` provenance marker. A second run against an
# already-recorded tree is a no-op **including the wire probe**: `run/0` checks
# every target path FIRST and returns without issuing a single HTTP request when
# they are all already recorded.
#
# Usage:
#
#     mix run scripts/record_openai_moderation_fixtures.exs
#     mix run scripts/record_openai_moderation_fixtures.exs --probe-only
#
# `--probe-only` runs the wire probe (including the `max_batch_size` ladder) and
# writes nothing. It exists because the probe is the repo's only live observer of
# OpenAI's moderation schema and the overwrite guard would otherwise make it
# unrunnable the moment the tree is fully recorded. The endpoint is free, so
# re-running it costs nothing.
#
# The key is read from the environment, but a project-root `.env` is loaded
# first — that gitignored file is this repo's documented key mechanism
# (`examples/README.md`), and `examples/_helpers.exs` already loads it via the
# `:env_loader` dev dep. `.env` is consulted only when the variable is not
# already set, because `EnvLoader.load/1` calls `System.put_env/2`
# unconditionally and an unguarded load would let a stale `.env` override an
# explicit assignment:
#
#     OPENAI_API_KEY=sk-... mix run scripts/record_openai_moderation_fixtures.exs
#
# To deliberately re-record a fixture, delete the file first (or restore its
# `_comment` marker) and re-run.
#
# Cost: $0.00. OpenAI documents the moderation endpoint as free to use, which is
# why the arm ladder below sweeps as far as 1000 inputs without a budget caveat.
#
# The wire probe
# --------------
#
# `run/0` issues one live call per `probe_arms/0` entry, plus the ladder, BEFORE
# recording anything, and **asserts** each outcome — halting the whole recording
# pass on a mismatch. The probe exists because Phase 22's design marked eleven
# rows of its OpenAI wire-field map **inferred**, and a design's claims about a
# provider's wire have repeatedly been the claims that turned out wrong.
#
# The probe is a discrimination, not a run of accepting calls, because "the
# request was accepted" is only evidence of schema membership if the API is known
# to reject unknown fields. The CONTROL arm exists to establish exactly that —
# and on 2026-08-31 it established the OPPOSITE:
#
#     POST /v1/moderations {"model": "...", "input": "hi", "not_a_real_field": true}
#       -> 200, a normal results array
#
# `/v1/moderations` IGNORES unknown top-level fields rather than rejecting them,
# unlike Voyage's embeddings endpoint (400 "Argument ... is not supported") and
# unlike OpenAI's own Chat Completions ("Unknown parameter"). Two consequences,
# both load-bearing:
#
#   * **No acceptance arm at this endpoint can prove schema membership.** A 200
#     means "OpenAI did not object", not "OpenAI understood the field". Any claim
#     that this endpoint *supports* a field has to be evidenced by an observable
#     difference in the RESPONSE, not by the absence of a 400.
#   * **Binding on 22.5.** The plan for the image arm was a paired control
#     sending `detail` inside `image_url` and reading its disposition off the
#     status. That control cannot work here: `detail` will come back 200 whether
#     it is honoured or discarded. 22.5 must either find a response-observable
#     difference or record the field's disposition as unknowable from the wire —
#     Decision #8 drops `detail` regardless, so the drop stays correct either
#     way, but the *evidence* for it is weaker than the design assumed.
#
# The arm is kept, with its expectation inverted to the observed truth, so that
# the day OpenAI starts validating unknown arguments this script fails loudly.
#
# The probe ASSERTS rather than narrates. Each arm carries an expected status and
# most carry an extra body-shaped verdict; any divergence prints the full
# want/got table to stderr and `System.halt(1)`s before a single fixture is
# written. A probe that prints its verdict into a scrollback is documentation
# with a network bill: `test/allm/providers/openai/moderation_wire_test.exs`
# asserts what the ADAPTER emits against a `Req.Test` stub and would stay green
# forever if OpenAI renamed a field, so this script is the only place in the repo
# that can observe the change — and it must therefore fail on it.
#
# The probe also RECORDS, because four of its arms already pay for a response
# body worth keeping:
#
#   * clean single string  -> recorded/single_clean.json
#   * flagged string       -> recorded/flagged_violence.json
#   * batch of three       -> recorded/batch_mixed.json
#   * shut-down model name -> recorded/error_400_bad_model.json
#
# The BAD-KEY arm deliberately records nothing. Its whole purpose is to observe
# whether OpenAI's 401 text echoes the submitted key back, and writing that body
# to a tracked fixture is the one recording that could commit key material. The
# redaction test is driven by `synthesized/error_401.json`, whose key-shaped
# token is planted for exactly that reason.
#
# The SECURITY arm is a verdict, not a call of its own: every recorded 200 body
# is checked for a sentinel substring drawn from the submitted input. Moderation
# responses ride onto `%ALLM.ModerationResponse{}.raw`, which `ALLM.moderate/3`
# puts into `[:allm, :moderate, :stop]` telemetry metadata — so an endpoint that
# echoed the submitted text back would push moderated user content into every
# attached telemetry handler and any log sink behind one. The arm's verdict is
# what turns that from a worry into a measurement.
#
# This script is NOT included in the published Hex package — `mix.exs` excludes
# `scripts/` from the package files list.

defmodule RecordOpenAIModerationFixtures do
  @moduledoc false

  @recorded_dir "test/fixtures/openai/moderations/recorded"
  @url "https://api.openai.com/v1/moderations"
  @model "omni-moderation-latest"

  # A shut-down model name (OpenAI's deprecations table: shutdown 2025-10-27,
  # replacement `omni-moderation`). Doubles as the design's Assumption 1 check.
  @dead_model "text-moderation-latest"

  # Distinctive tokens the security verdict greps every recorded 200 body for.
  @clean_text "a kestrel on a cedar branch at dusk"
  @clean_sentinel "kestrel"
  @flagged_text "I am going to find you and beat you to death with a hammer."
  @flagged_sentinel "hammer"

  @batch_inputs [
    "the quarterly report is attached",
    "I will hunt you down and kill you",
    "how do I bake sourdough bread"
  ]

  # Fixture names the probe arms own.
  @single_clean "single_clean"
  @flagged_violence "flagged_violence"
  @batch_mixed "batch_mixed"
  @error_400_bad_model "error_400_bad_model"

  # The `max_batch_size` ladder. The design deliberately states no number —
  # `ALLM.Providers.OpenAI.Moderation`'s `@adapter_max_batch_size` is set FROM this
  # result, and this table is what re-asserts it on every later run. Each rung
  # is `{n, expected_status}`; first observed 2026-08-31.
  @ladder [
    {1, 200},
    {32, 200},
    {100, 200},
    {128, 200},
    {1000, 200}
  ]

  def run(argv) do
    load_dotenv()

    unless System.get_env("OPENAI_API_KEY") do
      IO.puts(
        :stderr,
        "OPENAI_API_KEY not set (checked the environment and project-root .env) — " <>
          "refusing to record."
      )

      System.halt(1)
    end

    File.mkdir_p!(@recorded_dir)

    cond do
      "--probe-only" in argv ->
        _results = probe_wire_schema()
        IO.puts("--probe-only: nothing written.")

      Enum.empty?(pending_paths()) ->
        IO.puts(
          "Nothing to record: every fixture under #{@recorded_dir}/ is already a live " <>
            "recording (no _comment marker). No HTTP requests were made — including the " <>
            "wire probe. Delete a file first to re-record it, or pass --probe-only to " <>
            "re-run the probe without writing."
        )

      true ->
        probe_wire_schema()
        |> Enum.each(&record_probe_body/1)

        IO.puts(
          "Done. Recorded fixtures live under #{@recorded_dir}/. Review the diff, then " <>
            "re-run `mix test test/allm/providers/openai/moderation_wire_test.exs`."
        )
    end
  end

  # Every `recorded/` file this script owns. All four are paid for by probe arms:
  # a status code is the cheapest field in a response and almost never the thing
  # under test.
  defp target_paths do
    [@single_clean, @flagged_violence, @batch_mixed, @error_400_bad_model]
    |> Enum.map(&Path.join(@recorded_dir, "#{&1}.json"))
  end

  defp pending_paths, do: Enum.filter(target_paths(), &overwritable?/1)

  # Mirrors the OpenAI / Gemini / Voyage embeddings recorders. Loaded ONLY when
  # the key is not already in the environment: `EnvLoader.load/1` calls
  # `System.put_env/2` unconditionally, so an unguarded load would let a stale
  # `.env` silently override an explicit `OPENAI_API_KEY=... mix run ...`.
  defp load_dotenv do
    path = Path.expand(".env", Path.join(__DIR__, ".."))

    if is_nil(System.get_env("OPENAI_API_KEY")) and Code.ensure_loaded?(EnvLoader) and
         File.exists?(path) do
      EnvLoader.load(path)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Wire probe — see the header note for why the CONTROL arm is what makes the
  # accepting arms conclusive rather than suggestive.
  # ---------------------------------------------------------------------------

  defp probe_arms do
    [
      %{
        # NEGATIVE CONTROL — and it came back POSITIVE. Observed 2026-08-31:
        # `/v1/moderations` returns 200 for an unknown top-level field. The arm
        # is kept and its expectation inverted to the observed truth so that the
        # day OpenAI starts validating unknown arguments, this script says so.
        # See the header note: the consequence is that acceptance is NOT
        # evidence of schema membership at this endpoint.
        label: "CONTROL: not_a_real_field is IGNORED, not rejected (permissive endpoint)",
        expect: 200,
        record_as: nil,
        key: :live,
        verify: &verify_control_ignored/1,
        body: %{"model" => @model, "input" => "hi", "not_a_real_field" => true}
      },
      %{
        label: "model omitted (server default applies)",
        expect: 200,
        record_as: nil,
        key: :live,
        verify: &verify_model_echoed/1,
        body: %{"input" => @clean_text}
      },
      %{
        label: "clean single string (no usage key, x-request-id, no input echo)",
        expect: 200,
        record_as: @single_clean,
        key: :live,
        verify: &verify_clean_single/1,
        body: %{"model" => @model, "input" => [@clean_text]}
      },
      %{
        label: "flagged string (category_applied_input_types present)",
        expect: 200,
        record_as: @flagged_violence,
        key: :live,
        verify: &verify_flagged/1,
        body: %{"model" => @model, "input" => [@flagged_text]}
      },
      %{
        label: "batch of 3 strings (exactly 3 results, indices 0..2)",
        expect: 200,
        record_as: @batch_mixed,
        key: :live,
        verify: &verify_batch/1,
        body: %{"model" => @model, "input" => @batch_inputs}
      },
      %{
        label: "shut-down model name #{@dead_model} (error envelope shape)",
        expect: 400,
        record_as: @error_400_bad_model,
        key: :live,
        verify: &verify_error_envelope/1,
        body: %{"model" => @dead_model, "input" => ["hi"]}
      },
      %{
        label: "BAD KEY: 401 (does the message echo key material?) — NOT recorded",
        expect: 401,
        record_as: nil,
        key: :bad,
        verify: &verify_bad_key/1,
        body: %{"model" => @model, "input" => ["hi"]}
      }
    ]
  end

  # Returns the probe-arm results WITHOUT writing anything. Recording is the
  # caller's decision (`run/1`'s `true ->` branch), so that `--probe-only`'s
  # documented "writes nothing" contract is enforced by the call graph rather
  # than by the `overwritable?/1` guard happening to absorb the write.
  defp probe_wire_schema do
    IO.puts("\n-- OpenAI moderations wire probe (live, #{length(probe_arms())} requests) --")

    results = Enum.map(probe_arms(), &probe_arm/1)
    Enum.each(results, &print_result/1)

    ladder_results = probe_ladder()

    halt_unless_schema_holds(results ++ ladder_results)

    IO.puts("  Schema holds: every asserted arm matched (see the header note on the control).\n")

    results
  end

  # The ladder is what sets `@adapter_max_batch_size` on the adapter. It is written as an
  # ASSERTION table rather than a discovery print so that a later change to
  # OpenAI's cap fails this script instead of quietly disagreeing with the
  # adapter constant, the moduledoc, and `guides/moderation.md`.
  defp probe_ladder do
    IO.puts("\n-- max_batch_size ladder (#{length(@ladder)} requests) --")

    results =
      Enum.map(@ladder, fn {n, expect} ->
        body = %{"model" => @model, "input" => List.duplicate("ok", n)}

        arm = %{
          label: "ladder n=#{n}",
          expect: expect,
          record_as: nil,
          key: :live,
          verify: verify_result_count_matches_input(n),
          body: body
        }

        probe_arm(arm)
      end)

    Enum.each(results, &print_result/1)
    print_ladder_verdict(results)
    results
  end

  defp print_ladder_verdict(results) do
    accepted =
      @ladder
      |> Enum.zip(results)
      |> Enum.filter(fn {_rung, result} -> result.got == "200" end)
      |> Enum.map(fn {{n, _expect}, _result} -> n end)

    rejected =
      @ladder
      |> Enum.zip(results)
      |> Enum.reject(fn {_rung, result} -> result.got == "200" end)
      |> Enum.map(fn {{n, _expect}, result} -> "#{n} -> #{result.got}" end)

    IO.puts("  largest accepted n: #{inspect(List.last(accepted))}")
    IO.puts("  rejected rungs:     #{if rejected == [], do: "(none)", else: inspect(rejected)}")

    if rejected == [] do
      IO.puts(
        "  NOTE: the ladder's top rung was accepted — no upper bound was found. " <>
          "`max_batch_size/0` caps at the top rung and says so."
      )
    end
  end

  defp probe_arm(%{label: label, expect: expect, record_as: record_as} = arm) do
    {got, response_body, headers} =
      case post(arm.body, arm.key) do
        {:ok, response} -> {"#{response.status}", decode_body(response.body), response.headers}
        {:error, reason} -> {"ERR " <> inspect(reason), nil, %{}}
      end

    verdict =
      cond do
        got != "#{expect}" -> %{ok?: false, note: ""}
        not is_map(response_body) -> %{ok?: false, note: "  <- body is not JSON"}
        true -> arm.verify.(%{body: response_body, headers: headers})
      end

    %{
      label: label,
      expect: expect,
      got: got,
      ok?: got == "#{expect}" and verdict.ok?,
      note: verdict.note,
      record_as: record_as,
      body: response_body
    }
  end

  defp print_result(result) do
    flag = if result.ok?, do: "ok  ", else: "FAIL"

    IO.puts(
      "  #{flag} #{String.pad_trailing(result.got, 7)} (want #{result.expect})  " <>
        "#{result.label}#{result.note}"
    )
  end

  # ---------------------------------------------------------------------------
  # Per-arm verdicts. Each corresponds to one row the design's wire-field map
  # marks `inferred`.
  # ---------------------------------------------------------------------------

  defp verify_clean_single(%{body: body, headers: headers}) do
    first = body |> Map.get("results", []) |> List.first() || %{}

    checks = [
      {Map.get(first, "flagged") == false, "flagged is not false"},
      {not usage_key_anywhere?(body), "a `usage` key appeared in the body"},
      {header_present?(headers, "x-request-id"), "x-request-id header absent"},
      {is_binary(Map.get(body, "id")), "top-level `id` absent or non-string"},
      {Map.has_key?(first, "category_applied_input_types"), "category_applied_input_types absent"},
      {not echoes?(body, @clean_sentinel), "the response ECHOES the submitted input"}
    ]

    verdict(checks, extra_note: "  (usage absent; x-request-id present; no input echo)")
  end

  defp verify_flagged(%{body: body}) do
    first = body |> Map.get("results", []) |> List.first() || %{}
    categories = Map.get(first, "categories", %{})

    checks = [
      {Map.get(first, "flagged") == true, "flagged is not true"},
      {Map.get(categories, "violence") == true, "`violence` category is not true"},
      {Map.has_key?(first, "category_applied_input_types"), "category_applied_input_types absent"},
      {not usage_key_anywhere?(body), "a `usage` key appeared in the body"},
      {not echoes?(body, @flagged_sentinel), "the response ECHOES the submitted input"}
    ]

    verdict(checks)
  end

  defp verify_batch(%{body: body}) do
    results = Map.get(body, "results", [])

    checks = [
      {length(results) == length(@batch_inputs),
       "#{length(results)} results for #{length(@batch_inputs)} inputs"},
      {not usage_key_anywhere?(body), "a `usage` key appeared in the body"},
      {not Enum.any?(@batch_inputs, &echoes?(body, &1)), "the response ECHOES a submitted input"}
    ]

    verdict(checks)
  end

  # The wire's `results` array carries no `index` field, so the ADAPTER assigns
  # `:index` from array position (`ALLM.ModerationAdapter` invariant 4). This
  # verdict is what binds "one result per input, in order" at the provider, so it
  # closes over the rung's `n` and compares `length(results)` against it — a
  # response returning one result for a 1000-input batch must FAIL the rung, not
  # pass it on the presence of a `results` key.
  defp verify_result_count_matches_input(n) when is_integer(n) do
    fn %{body: body} ->
      results = Map.get(body, "results", [])

      verdict([
        {is_list(results) and length(results) == n,
         "#{length(List.wrap(results))} results for #{n} inputs"}
      ])
    end
  end

  defp verify_model_echoed(%{body: body}) do
    model = Map.get(body, "model")

    verdict([{is_binary(model), "no `model` echoed"}],
      extra_note: "  (server default model: #{inspect(model)})"
    )
  end

  # The control's verdict is deliberately weak — a 200 with a `results` array is
  # all it takes to establish that the invented field changed nothing. Its VALUE
  # is the inversion recorded on the arm itself, not the assertion here.
  defp verify_control_ignored(%{body: body}) do
    verdict([{is_list(Map.get(body, "results")), "no `results` array"}],
      extra_note: "  (acceptance proves NOTHING about schema membership here)"
    )
  end

  defp verify_error_envelope(%{body: body}) do
    error = Map.get(body, "error")

    checks = [
      {is_map(error), "no `error` object"},
      {is_map(error) and is_binary(Map.get(error, "message")), "error.message absent"},
      {is_map(error) and Map.has_key?(error, "type"), "error.type absent"},
      {is_map(error) and Map.has_key?(error, "code"), "error.code absent"},
      {is_map(error) and Map.has_key?(error, "param"), "error.param absent"}
    ]

    verdict(checks)
  end

  # Observation only — the arm asserts the 401 status and reports whether the
  # message echoes the key. The body is NOT recorded (see the header note).
  defp verify_bad_key(%{body: body}) do
    message = body |> Map.get("error", %{}) |> Map.get("message", "")
    echoed? = is_binary(message) and String.contains?(message, bad_key_tail())

    verdict([{is_binary(message), "no error.message"}],
      extra_note: "  (echoes submitted key material: #{echoed?})"
    )
  end

  defp verdict(checks, opts \\ []) do
    failures = for {false, why} <- checks, do: why

    case failures do
      [] -> %{ok?: true, note: Keyword.get(opts, :extra_note, "")}
      _ -> %{ok?: false, note: "  <- " <> Enum.join(failures, "; ")}
    end
  end

  # Assumption 6 says the endpoint returns no usage object. Checked ANYWHERE in
  # the body, not just at the top level, because `%ModerationResponse{}` has no
  # `:usage` field at all and a nested counter would still be a design change.
  defp usage_key_anywhere?(body) when is_map(body) do
    Enum.any?(body, fn {k, v} -> k == "usage" or usage_key_anywhere?(v) end)
  end

  defp usage_key_anywhere?(list) when is_list(list), do: Enum.any?(list, &usage_key_anywhere?/1)
  defp usage_key_anywhere?(_other), do: false

  defp echoes?(body, sentinel) when is_map(body) do
    body |> Jason.encode!() |> String.contains?(sentinel)
  end

  defp echoes?(_body, _sentinel), do: false

  defp header_present?(headers, name) when is_map(headers), do: Map.has_key?(headers, name)

  defp header_present?(headers, name) when is_list(headers) do
    Enum.any?(headers, fn
      {k, _v} when is_binary(k) -> String.downcase(k) == name
      _ -> false
    end)
  end

  defp header_present?(_headers, _name), do: false

  # The whole point of the probe. A printed table nobody reads cannot hold an
  # invariant; the recording pass must not proceed on a broken premise.
  defp halt_unless_schema_holds(results) do
    if Enum.all?(results, & &1.ok?) do
      :ok
    else
      IO.puts(:stderr, "\nOpenAI's moderation schema has CHANGED — refusing to record.\n")

      Enum.each(results, fn result ->
        IO.puts(
          :stderr,
          "  want #{result.expect}  got #{result.got}  #{result.label}#{result.note}"
        )
      end)

      IO.puts(
        :stderr,
        "\nIf the CONTROL arm was REJECTED (400 rather than the 200 recorded on 2026-08-31),\n" <>
          "OpenAI has started validating unknown top-level arguments on this endpoint. That\n" <>
          "is good news — acceptance would once again be evidence of schema membership —\n" <>
          "but it also means a request carrying an unrecognised `request.options` key now\n" <>
          "fails where it used to be ignored. Re-read the header note and 22.5's `detail`\n" <>
          "disposition before flipping the expectation back.\n\n" <>
          "Re-verify `to_json_body/2` in lib/allm/providers/openai/moderation.ex and the\n" <>
          "\"Wire-field map\" section of steering/2026-08-31_PHASE_22_moderation.md, then\n" <>
          "update probe_arms/0 and @ladder here. A ladder mismatch instead means\n" <>
          "`@adapter_max_batch_size` in the adapter (and the cap quoted in\n" <>
          "guides/moderation.md) no longer matches the wire. Note that\n" <>
          "test/allm/providers/openai/moderation_wire_test.exs asserts what the ADAPTER\n" <>
          "emits against a Req.Test stub and will stay green regardless — this script is\n" <>
          "the only place in the repo that observes the provider's actual schema."
      )

      System.halt(1)
    end
  end

  # ---------------------------------------------------------------------------
  # Recording
  # ---------------------------------------------------------------------------

  defp record_probe_body(%{record_as: nil}), do: :ok

  defp record_probe_body(%{record_as: name, body: body, label: label}) do
    path = Path.join(@recorded_dir, "#{name}.json")

    cond do
      not overwritable?(path) ->
        IO.puts("  - #{path} already recorded — refusing to overwrite.")

      is_map(body) ->
        write!(path, body)
        IO.puts("  ✓ recorded #{path} (from the probe arm: #{label})")

      true ->
        IO.puts(:stderr, "  ✗ probe arm returned no decodable body: #{inspect(body)}")
    end
  end

  # A file is safe to overwrite when it does not exist, or when it still carries
  # the leading `_comment` marker that synthesized placeholders use. A real
  # recorded response has no such field.
  defp overwritable?(path) do
    case File.read(path) do
      {:error, :enoent} ->
        true

      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{"_comment" => _}} -> true
          _ -> false
        end

      # Fail loudly with a readable reason rather than a CaseClauseError that
      # reads as a script bug when it is a permissions problem.
      {:error, reason} ->
        raise "cannot read #{path}: #{:file.format_error(reason)}"
    end
  end

  defp write!(path, body), do: File.write!(path, Jason.encode!(body, pretty: true) <> "\n")

  # OpenAI answers some error statuses with a `text/plain` content type, which
  # `Req` hands back as an undecoded binary. Every verdict below reads a map, so
  # normalize here rather than in seven places.
  defp decode_body(body) when is_map(body), do: body

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> body
    end
  end

  defp decode_body(body), do: body

  # A deliberately invalid key with a real OpenAI prefix, so the 401 arm
  # exercises the provider's own auth rejection rather than a malformed header.
  defp bad_key, do: "sk-proj-" <> bad_key_tail()
  defp bad_key_tail, do: "NOTAREALKEY0011223344556677889900"

  defp post(body, key_kind) do
    key = if key_kind == :bad, do: bad_key(), else: System.get_env("OPENAI_API_KEY")

    Req.post(@url,
      headers: [
        {"authorization", "Bearer " <> key},
        {"content-type", "application/json"}
      ],
      json: body,
      receive_timeout: 120_000
    )
  end
end

RecordOpenAIModerationFixtures.run(System.argv())
