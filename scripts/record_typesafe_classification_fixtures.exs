# scripts/record_typesafe_classification_fixtures.exs
#
# Fixture recorder AND live wire probe for
# `ALLM.Providers.TypeSafe.Classification` (POST https://api.typesafe.ai/v1/systemone).
#
# Usage (the subshell keeps `.env` out of the parent shell, so a later
# `mix test` stays keyless and the keyless gate-ordering test keeps proving
# its ordering):
#
#     ( set -a; . ./.env; set +a; mix run scripts/record_typesafe_classification_fixtures.exs )
#
# A bare `mix run scripts/record_typesafe_classification_fixtures.exs` works
# too: the script loads the project-root `.env` itself (through the
# `:env_loader` dev dep) when `TYPESAFE_API_KEY` is not already set, and an
# explicit assignment in the environment always wins over `.env`.
#
# Writes `test/fixtures/typesafe/classification/recorded/*.json`. It never
# touches `synthesized/`.
#
# The four parts every probe in this repo carries
# -----------------------------------------------
#
# 1. **Negative control.** Arm 11 sends arm 1's request plus an invented
#    question field. Observed 2026-09-27: **200** — TypeSafe ignores unknown
#    question fields (and unknown top-level fields), so no arm here treats a
#    200 as proof that a field is in the request schema. Only RESPONSE
#    observables (answer shapes, an error body, a status the control does not
#    share) settle a wire-map row.
#
# 2. **Assert, don't narrate.** Every arm carries an expected status plus a
#    body verdict. All pending arms run first, and any mismatch prints the
#    want/got table to stderr and `System.halt(1)`s BEFORE a single file is
#    written. The `Req.Test` wire tests assert what the ADAPTER emits and stay
#    green whatever TypeSafe does, so this script is the only place in the repo
#    that can see the provider change.
#
# 3. **Record the body, not the status.** Every arm except the ladder writes a
#    JSON envelope, error bodies included:
#
#        {"status", "headers": {...}, "header_names": [...], "body": ...}
#
#    `headers` keeps only the correlation and retry headers the adapter reads
#    (never `set-cookie`); `header_names` lists EVERY response header name, so
#    a header that is absent is visible as absent. The question ladder (arm 10)
#    writes its own summary, `{"max_ok", "steps", "first_failure"}`.
#
# 4. **Overwrite guard over EVERY arm.** Every target path is checked FIRST.
#    A fully recorded tree makes ZERO live calls, the probe included. When any
#    target is pending the whole probe runs (the verdict needs every arm), but
#    only pending files are written. To re-record a fixture, delete it (or put
#    a `_comment` key back in it) and re-run.
#
# Arms (numbering is stable against the design's wire-field map; there is no
# arm 6). Expected statuses are the ones OBSERVED on 2026-09-27 — where they
# differ from the design's first guess, the design carries a CORRECTED note:
#
#   1   choice + score + noul, string state        200  mixed_questions
#   2   object state/instructions/score levels     200  structured_state
#   3   question type "ranking"                    400  error_400_bad_type
#   4   choice with 256 options                    400  error_400_too_many_options
#   4b  choice with 255 options                    200  choice_255_options
#   5   score with 11 levels                       400  error_400_too_many_levels
#   5b  score with 10 levels                       200  score_10_levels
#   7   unknown model                              400  error_bad_model
#   8   bogus key                                  401  error_401_live
#   9   ~39k-token state                           400  error_context_length
#   10  question ladder [1, 32, 128, 512]          -    probe_question_ladder
#   11  CONTROL: invented question field           200  negative_control
#   12  list state with a non-text element         200  probe_state_list_any
#   13  questions: {}                              422  error_422_empty_questions
#
# Cost: TypeSafe bills input tokens only ($0.042 / Mtok). One clean run is
# roughly 70k billed input tokens (the ladder dominates; arm 9 is rejected
# before evaluation), i.e. well under $0.01.
#
# This script is NOT included in the published Hex package — `mix.exs`
# excludes `scripts/` from the package files list.

defmodule RecordTypeSafeClassificationFixtures do
  @moduledoc false

  @recorded_dir "test/fixtures/typesafe/classification/recorded"
  @url "https://api.typesafe.ai/v1/systemone"
  @model "jev-latest"
  @key_var "TYPESAFE_API_KEY"

  # Headers whose VALUES are kept in an envelope. Everything else is recorded
  # by name only.
  @kept_headers ~w(content-type x-typesafe-request-id retry-after retry-after-ms)

  @expected_usage_keys ["input_tokens", "output_tokens"]

  @ladder [1, 32, 128, 512]

  def run do
    load_dotenv([@key_var])
    require_key!()

    File.mkdir_p!(@recorded_dir)

    case Enum.filter(target_paths(), &overwritable?/1) do
      [] ->
        IO.puts(
          "Nothing to record: every fixture under #{@recorded_dir}/ is already a live " <>
            "recording (no _comment marker). No HTTP requests were made — including the " <>
            "wire probe. Delete a file first to re-record it."
        )

      pending ->
        IO.puts("#{length(pending)} target(s) pending; running the full probe.")
        results = Enum.map(arms(), &run_arm/1) ++ [run_ladder()]
        print_table(results)
        halt_unless_holds(results)
        print_header_note(results)
        write_pending(results, pending)
        IO.puts("Billed input tokens this run (from usage): #{billed_tokens(results)}")
    end
  end

  # ---------------------------------------------------------------------------
  # Arms
  # ---------------------------------------------------------------------------

  defp arms do
    [
      %{
        arm: "1",
        name: "mixed_questions",
        expect: 200,
        body:
          body("I was charged twice for my subscription and I am furious. Refund me.", %{
            "department" =>
              choice_q(%{"billing" => nil, "technical" => "Bugs and outages", "sales" => nil}),
            "frustration" => score_q(["Calm", "Frustrated", "Very angry"]),
            "refund" => %{
              "type" => "noul",
              "instructions" => "Is the customer asking for a refund?"
            }
          }),
        verdict:
          &answers_verdict(&1, %{
            "department" => "choice",
            "frustration" => "score",
            "refund" => "noul"
          })
      },
      %{
        arm: "2",
        name: "structured_state",
        expect: 200,
        body: %{
          "state" => %{"customer" => "Ada", "message" => "The app crashes when I upload a photo."},
          "model" => @model,
          "questions" => %{
            "severity" => %{
              "type" => "score",
              "instructions" => %{
                "task" => "Rate the severity of the report",
                "scale" => "low to high"
              },
              "criteria" => [
                %{"label" => "Minor", "meaning" => "cosmetic"},
                %{"label" => "Major", "meaning" => "a feature is broken"},
                %{"label" => "Critical", "meaning" => "data loss or outage"}
              ]
            }
          }
        },
        verdict: &answers_verdict(&1, %{"severity" => "score"})
      },
      %{
        arm: "3",
        name: "error_400_bad_type",
        expect: 400,
        body: body("hi", %{"q" => %{"type" => "ranking", "instructions" => "Rank it"}}),
        verdict: &detail_verdict/1
      },
      %{
        arm: "4",
        name: "error_400_too_many_options",
        expect: 400,
        body: body("hi", %{"q" => choice_q(options(256))}),
        verdict: &detail_verdict/1
      },
      %{
        arm: "4b",
        name: "choice_255_options",
        expect: 200,
        body: body("hi", %{"q" => choice_q(options(255))}),
        verdict: &answers_verdict(&1, %{"q" => "choice"})
      },
      %{
        arm: "5",
        name: "error_400_too_many_levels",
        expect: 400,
        body: body("hi", %{"q" => score_q(levels(11))}),
        verdict: &detail_verdict/1
      },
      %{
        arm: "5b",
        name: "score_10_levels",
        expect: 200,
        body: body("hi", %{"q" => score_q(levels(10))}),
        verdict: &answers_verdict(&1, %{"q" => "score"})
      },
      %{
        arm: "7",
        name: "error_bad_model",
        expect: 400,
        body: %{
          "state" => "hi",
          "model" => "jev-allm-probe-nonexistent",
          "questions" => %{"q" => noul_q()}
        },
        verdict: &detail_verdict/1
      },
      %{
        arm: "8",
        name: "error_401_live",
        expect: 401,
        key: bogus_key(),
        body: body("hi", %{"q" => noul_q()}),
        verdict: &no_key_echo_verdict/1
      },
      %{
        arm: "9",
        name: "error_context_length",
        expect: 400,
        body: body(String.duplicate("kestrel cedar branch ", 13_000), %{"q" => noul_q()}),
        verdict: &context_length_verdict/1
      },
      %{
        arm: "11",
        name: "negative_control",
        expect: 200,
        body: body("hi", %{"q" => Map.put(noul_q(), "allm_probe_field", "x")}),
        verdict: &answers_verdict(&1, %{"q" => "noul"})
      },
      %{
        arm: "12",
        name: "probe_state_list_any",
        expect: 200,
        body: %{"state" => ["a", 1], "model" => @model, "questions" => %{"q" => noul_q()}},
        verdict: &answers_verdict(&1, %{"q" => "noul"})
      },
      %{
        arm: "13",
        name: "error_422_empty_questions",
        expect: 422,
        body: %{"state" => "hi", "model" => @model, "questions" => %{}},
        verdict: &detail_verdict/1
      }
    ]
  end

  defp body(state, questions), do: %{"state" => state, "model" => @model, "questions" => questions}

  defp choice_q(criteria),
    do: %{"type" => "choice", "instructions" => "Which option fits best?", "criteria" => criteria}

  defp score_q(levels),
    do: %{
      "type" => "score",
      "instructions" => "How strongly does this apply?",
      "criteria" => levels
    }

  defp noul_q, do: %{"type" => "noul", "instructions" => "Is this a greeting?"}

  defp options(n), do: Map.new(1..n, &{"option_#{&1}", nil})
  defp levels(n), do: Enum.map(0..(n - 1), &"level #{&1}")

  # Realistic length and a plausible shape; never a real credential.
  defp bogus_key, do: "apikey_allmprobe" <> String.duplicate("0", 48)

  # ---------------------------------------------------------------------------
  # Verdicts — each returns "" when the body holds, else a one-line reason.
  # ---------------------------------------------------------------------------

  defp answers_verdict(%{"answers" => answers, "usage" => usage}, want)
       when is_map(answers) and is_map(usage) do
    got = Map.new(answers, fn {id, a} -> {id, is_map(a) && a["type"]} end)

    cond do
      got != want -> "answer types #{inspect(got)}, want #{inspect(want)}"
      Enum.sort(Map.keys(usage)) != @expected_usage_keys -> "usage keys #{inspect(Map.keys(usage))}"
      true -> ""
    end
  end

  defp answers_verdict(body, _want), do: "no answers/usage in #{inspect(body, limit: 5)}"

  defp detail_verdict(%{"detail" => _}), do: ""
  defp detail_verdict(body), do: "no \"detail\" in #{inspect(body, limit: 5)}"

  defp no_key_echo_verdict(body) do
    cond do
      not is_map(body) or not Map.has_key?(body, "detail") -> "no \"detail\" in 401 body"
      String.contains?(Jason.encode!(body), bogus_key()) -> "401 body echoes the sent key"
      true -> ""
    end
  end

  defp context_length_verdict(%{"detail" => %{"error_type" => "max_tokens_exceeded"}}), do: ""

  defp context_length_verdict(body),
    do: "no max_tokens_exceeded signal in #{inspect(body, limit: 5)}"

  # ---------------------------------------------------------------------------
  # Running
  # ---------------------------------------------------------------------------

  defp run_arm(arm) do
    case post(arm.body, Map.get(arm, :key, System.get_env(@key_var))) do
      {:ok, %Req.Response{status: status, headers: headers, body: body}} ->
        why = if status == arm.expect, do: arm.verdict.(body), else: ""

        %{
          label: "#{arm.arm} #{arm.name}",
          expect: "#{arm.expect}",
          got: "#{status}",
          ok?: status == arm.expect and why == "",
          note: why,
          path: path(arm.name),
          record: %{
            "status" => status,
            "headers" => Map.new(Map.take(headers, @kept_headers), fn {k, [v | _]} -> {k, v} end),
            "header_names" => headers |> Map.keys() |> Enum.sort(),
            "body" => body
          }
        }

      {:error, reason} ->
        %{
          label: "#{arm.arm} #{arm.name}",
          expect: "#{arm.expect}",
          got: "ERR",
          ok?: false,
          note: inspect(reason),
          path: path(arm.name),
          record: nil
        }
    end
  end

  # Arm 10: trivial nouls, stopping at the first non-200. A 4xx is a finding
  # (a question-count cap); a 5xx or a transport error halts.
  defp run_ladder do
    {steps, failure} =
      Enum.reduce_while(@ladder, {[], nil}, fn n, {steps, nil} ->
        questions =
          Map.new(
            1..n,
            &{"q#{&1}", %{"type" => "noul", "instructions" => "Is item #{&1} present?"}}
          )

        case post(body("A short list of items.", questions), System.get_env(@key_var)) do
          {:ok, %Req.Response{status: 200, body: %{"answers" => a} = b}} when map_size(a) == n ->
            {:cont, {steps ++ [%{"size" => n, "status" => 200, "usage" => b["usage"]}], nil}}

          {:ok, %Req.Response{status: s, body: b}} when s in 400..499 ->
            {:halt, {steps, %{"size" => n, "status" => s, "body" => b}}}

          {:ok, %Req.Response{status: s}} ->
            {:halt, {steps, %{"size" => n, "status" => s, "body" => :halt}}}

          {:error, reason} ->
            {:halt, {steps, %{"size" => n, "status" => "ERR " <> inspect(reason), "body" => :halt}}}
        end
      end)

    halted? = match?(%{"body" => :halt}, failure)
    max_ok = steps |> Enum.map(& &1["size"]) |> Enum.max(fn -> 0 end)

    %{
      label: "10 probe_question_ladder #{inspect(@ladder)}",
      expect: "200|4xx",
      got: if(failure, do: "#{failure["status"]}@#{failure["size"]}", else: "200@all"),
      ok?: not halted?,
      note: if(halted?, do: "5xx/transport error on the ladder", else: ""),
      path: path("probe_question_ladder"),
      ladder_usage: Enum.map(steps, & &1["usage"]),
      record: %{
        "max_ok" => max_ok,
        "steps" => Enum.map(steps, &Map.delete(&1, "usage")),
        "first_failure" => failure
      }
    }
  end

  defp post(body, key) do
    Req.post(@url,
      headers: [{"authorization", "Bearer " <> key}, {"content-type", "application/json"}],
      json: body,
      retry: false,
      receive_timeout: 180_000
    )
  end

  defp path(name), do: Path.join(@recorded_dir, "#{name}.json")

  defp target_paths do
    Enum.map(arms(), &path(&1.name)) ++ [path("probe_question_ladder")]
  end

  # ---------------------------------------------------------------------------
  # Verdict, notes, writing
  # ---------------------------------------------------------------------------

  defp print_table(results) do
    IO.puts("\n-- TypeSafe wire probe (live) --")

    Enum.each(results, fn r ->
      flag = if r.ok?, do: "ok  ", else: "FAIL"

      IO.puts(
        "  #{flag} got #{String.pad_trailing(r.got, 8)} want #{String.pad_trailing(r.expect, 8)} #{r.label}  #{r.note}"
      )
    end)
  end

  defp halt_unless_holds(results) do
    if Enum.all?(results, & &1.ok?) do
      :ok
    else
      IO.puts(:stderr, "\nTypeSafe's wire has CHANGED — refusing to record.\n")

      for r <- results, not r.ok? do
        IO.puts(:stderr, "  want #{r.expect}  got #{r.got}  #{r.label}  #{r.note}")
      end

      IO.puts(
        :stderr,
        "\nRe-verify the wire-field map in lib/allm/providers/typesafe/classification.ex\n" <>
          "and the design's arm table, then update arms/0 here. The Req.Test wire tests\n" <>
          "assert what the ADAPTER emits and stay green regardless."
      )

      System.halt(1)
    end
  end

  # Header presence per arm, for the RECORDS transcript. Values of the
  # request id are not secret; they are printed only as present/absent.
  defp print_header_note(results) do
    IO.puts("\n-- header note --")

    for %{record: %{"header_names" => names}, label: label} <- results do
      flags =
        for h <- ~w(x-typesafe-request-id retry-after retry-after-ms),
            do: "#{h}=#{if h in names, do: "yes", else: "no"}"

      IO.puts("  #{label}: #{Enum.join(flags, " ")}")
    end
  end

  defp write_pending(results, pending) do
    for %{path: path, record: record} <- results, path in pending, is_map(record) do
      File.write!(path, Jason.encode!(record, pretty: true) <> "\n")
      IO.puts("  ✓ recorded #{path}")
    end
  end

  defp billed_tokens(results) do
    arm_usage =
      for %{record: %{"body" => %{"usage" => %{"input_tokens" => n}}}} <- results, do: n

    ladder_usage =
      for %{ladder_usage: us} <- results, %{"input_tokens" => n} <- us, do: n

    Enum.sum(arm_usage ++ ladder_usage)
  end

  # ---------------------------------------------------------------------------
  # Key loading and the overwrite guard — copied verbatim from
  # `scripts/record_prompt_cache_fixtures.exs`, the designated extraction
  # source for the pending recorder-scaffolding `[CHORE]`.
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

  defp require_key! do
    if System.get_env(@key_var) in [nil, ""] do
      IO.puts(
        :stderr,
        "#{@key_var} not set (checked the environment and project-root .env) — refusing to probe."
      )

      System.halt(1)
    end
  end

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
end

RecordTypeSafeClassificationFixtures.run()
