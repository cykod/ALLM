# scripts/record_voyage_embeddings_fixtures.exs
#
# Fixture recorder for `test/fixtures/voyage/embeddings/recorded/`.
# Runs against the live Voyage AI Embeddings API; gated on `VOYAGE_API_KEY`.
#
# Idempotent by construction: it NEVER touches
# `test/fixtures/voyage/embeddings/synthesized/`, and it refuses to overwrite a
# `recorded/` file that has already been recorded — i.e. one that no longer
# carries a leading `_comment` provenance marker. A second run against an
# already-recorded tree is a no-op **including the wire probe**: `run/0` checks
# every target path FIRST and returns without issuing a single HTTP request when
# they are all already recorded.
#
# Usage:
#
#     mix run scripts/record_voyage_embeddings_fixtures.exs
#
# The key is read from the environment, but a project-root `.env` is loaded
# first — that gitignored file is this repo's documented key mechanism
# (`examples/README.md`), and `examples/_helpers.exs` already loads it via the
# `:env_loader` dev dep. `.env` is consulted only when the variable is not
# already set, because `EnvLoader.load/1` calls `System.put_env/2`
# unconditionally and an unguarded load would let a stale `.env` override an
# explicit assignment:
#
#     VOYAGE_API_KEY=pa-... mix run scripts/record_voyage_embeddings_fixtures.exs
#
# To deliberately re-record a fixture, delete the file first (or restore its
# `_comment` marker) and re-run.
#
# Approximate cost (one-time), `voyage-3.5-lite` at $0.02 / 1M tokens: ~20
# tokens across the three 200 recordings, plus one call per probe arm (the arms
# are enumerated in `probe_arms/0`; the count is not restated here so the prose
# cannot drift from the code). The context-length arm sends a deliberately
# over-length input that Voyage REJECTS
# with a 400 before embedding it, so it is not billed for the full body. Total
# well under $0.001, and Voyage's free tier covers it. Verify against
# https://docs.voyageai.com/docs/pricing.
#
# The wire probe
# --------------
#
# `run/0` issues one live call per `probe_arms/0` entry BEFORE recording
# anything and **asserts** the outcome, halting the whole recording pass on a
# mismatch. The probe exists because the fields this adapter emits beyond
# `model` and `input` — `output_dimension`, `truncation`, `input_type` — were
# taken from published documentation, and a design's claims about a provider's
# wire have been the claims that turned out wrong.
#
# The probe is a discrimination, not a run of accepting calls, because "the
# request was accepted" is only evidence of schema membership if the API is
# known to reject unknown fields. The CONTROL arm establishes exactly that.
# Expected outcome, asserted by `probe_arms/0` and first observed on 2026-07-29
# against `voyage-3.5-lite`:
#
#   * `output_dimension: 512`                            -> 200 (512-wide vectors)
#   * `truncation: false`                                -> 200
#   * `input_type: "document"`                           -> 200
#   * CONTROL: `totallyNotAField: {}`                    -> 400
#   * over-length input with `truncation: false`         -> 400 (context window)
#
# The control rejecting is what makes the first three arms' 200s meaningful:
# Voyage validates unknown arguments strictly ("Argument 'totallyNotAField' is
# not supported by our API"), so acceptance means the field is a recognised
# member of the request schema.
#
# The probe ASSERTS rather than narrates. Each arm carries an expected status,
# and every 200 arm additionally asserts that the response's `usage` object
# carries exactly `["total_tokens"]` — the one wire row that drives this
# adapter's whole `ALLM.Usage` mapping, since `build_usage/1` hardcodes
# `input_tokens: nil` and would drop a new provider counter in silence. Any
# divergence prints the full want/got table to stderr and `System.halt(1)`s
# before a single fixture is written. A probe that prints its verdict into a
# scrollback is documentation with a network bill: the `Req.Test`-stubbed wire
# tests assert what the ADAPTER emits and would stay green forever if Voyage
# renamed a field, so this script is the only place in the repo that can observe
# the change — and it must therefore fail on it. (`embeddings_wire_test.exs`
# carries the same usage-key assertion as a premise guard, but bound to the
# RECORDED bodies: it fires at re-record time, this arm fires live.)
#
# The probe also RECORDS, because three of its arms already pay for a response
# body worth keeping. A status code is the cheapest field in a response and
# almost never the thing under test:
#
#   * the `output_dimension` arm's 200 becomes `recorded/reduced_dimensions.json`
#   * the CONTROL arm's 400 becomes `recorded/error_400_unknown_field.json`
#   * the over-length arm's 400 becomes `recorded/error_400_context_length.json`
#
# Load-bearing details for the wire tests
# ---------------------------------------
#
#   * `batch_input` MUST record exactly THREE inputs —
#     `test/allm/providers/voyage/embeddings_test.exs` drives it with a
#     three-element `:input` and asserts `length(embeddings) == length(input)`
#     with `:index` values `0..n-1` (the assertion that binds
#     `ALLM.EmbeddingAdapter` invariant 8 for this adapter, which the
#     conformance suite cannot).
#   * `reduced_dimensions` MUST request fewer dimensions than the model's native
#     width, because the wire test asserts the RELATION
#     `dimension_of(reduced) < dimension_of(single_input)` rather than a literal.
#   * `error_400_unknown_field` and `error_400_context_length` are the tree's
#     only GENUINE Voyage error envelopes, and `embeddings_wire_test.exs`
#     asserts the `{"detail": "..."}` envelope shape and the
#     `:invalid_request` / `:context_length_exceeded` mappings against them. The
#     two `synthesized/` error fixtures remain hand-written on purpose: the 429
#     would need sustained abuse of the endpoint to provoke, and the 401's
#     message carries a deliberately-planted `pa-…` string so the redaction test
#     has a target (Voyage's real 401 text is "Provided API key is invalid." and
#     does not echo the key back).
#
# This script is NOT included in the published Hex package — `mix.exs` excludes
# `scripts/` from the package files list.

defmodule RecordVoyageEmbeddingsFixtures do
  @moduledoc false

  @recorded_dir "test/fixtures/voyage/embeddings/recorded"
  @url "https://api.voyageai.com/v1/embeddings"
  @model "voyage-3.5-lite"

  # Names owned by the probe rather than by `@specs`.
  @reduced_fixture_name "reduced_dimensions"
  @unknown_field_fixture_name "error_400_unknown_field"
  @context_length_fixture_name "error_400_context_length"

  @specs [
    %{
      name: "single_input",
      body: %{"model" => @model, "input" => ["a kestrel"]}
    },
    %{
      # Exactly three inputs — see the header note.
      name: "batch_input",
      body: %{"model" => @model, "input" => ["chunk one", "chunk two", "chunk three"]}
    }
  ]

  def run do
    load_dotenv()

    unless System.get_env("VOYAGE_API_KEY") do
      IO.puts(
        :stderr,
        "VOYAGE_API_KEY not set (checked the environment and project-root .env) — " <>
          "refusing to record."
      )

      System.halt(1)
    end

    File.mkdir_p!(@recorded_dir)

    # Every target path is checked BEFORE any HTTP request, so a run against a
    # fully-recorded tree costs zero live calls — including the probe's.
    if Enum.empty?(pending_paths()) do
      IO.puts(
        "Nothing to record: every fixture under #{@recorded_dir}/ is already a live " <>
          "recording (no _comment marker). No HTTP requests were made — including the " <>
          "wire probe. Delete a file first to re-record it."
      )
    else
      probe_wire_schema()
      Enum.each(@specs, &record/1)

      IO.puts(
        "Done. Recorded fixtures live under #{@recorded_dir}/. Review the diff, then " <>
          "re-run `mix test test/allm/providers/voyage/embeddings_wire_test.exs`."
      )
    end
  end

  # Every `recorded/` file this script owns: the two 200 bodies from `@specs`
  # plus the three the probe arms pay for.
  defp target_paths do
    names =
      Enum.map(@specs, & &1.name) ++
        [@reduced_fixture_name, @unknown_field_fixture_name, @context_length_fixture_name]

    Enum.map(names, &Path.join(@recorded_dir, "#{&1}.json"))
  end

  defp pending_paths, do: Enum.filter(target_paths(), &overwritable?/1)

  # Mirrors the OpenAI and Gemini embeddings recorders. Loaded ONLY when the key
  # is not already in the environment: `EnvLoader.load/1` calls
  # `System.put_env/2` unconditionally, so an unguarded load would let a stale
  # `.env` silently override an explicit `VOYAGE_API_KEY=... mix run ...`.
  defp load_dotenv do
    path = Path.expand(".env", Path.join(__DIR__, ".."))

    if is_nil(System.get_env("VOYAGE_API_KEY")) and Code.ensure_loaded?(EnvLoader) and
         File.exists?(path) do
      EnvLoader.load(path)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Wire probe — see the header note for why the CONTROL arm is what makes the
  # accepting arms conclusive rather than suggestive.
  # ---------------------------------------------------------------------------

  # Roughly 40,000 tokens of filler against a 32,000-token context window. Sent
  # with `truncation: false` so Voyage rejects it instead of silently truncating
  # (the default `truncation: true` returns a 200 and bills the full window).
  defp over_length_input, do: String.duplicate("kestrel cedar branch ", 8_000)

  defp probe_arms do
    [
      %{
        label: "output_dimension: 512 (snake_case — the adapter's shape)",
        expect: 200,
        record_as: @reduced_fixture_name,
        body: %{"model" => @model, "input" => ["a kestrel"], "output_dimension" => 512}
      },
      %{
        label: "truncation: false",
        expect: 200,
        record_as: nil,
        body: %{"model" => @model, "input" => ["a kestrel"], "truncation" => false}
      },
      %{
        label: ~s(input_type: "document"),
        expect: 200,
        record_as: nil,
        body: %{"model" => @model, "input" => ["a kestrel"], "input_type" => "document"}
      },
      %{
        label: "CONTROL: totallyNotAField (unknown-argument tolerance)",
        expect: 400,
        record_as: @unknown_field_fixture_name,
        body: %{"model" => @model, "input" => ["a kestrel"], "totallyNotAField" => %{}}
      },
      %{
        label: "over-length input with truncation: false (context window)",
        expect: 400,
        record_as: @context_length_fixture_name,
        body: %{"model" => @model, "input" => [over_length_input()], "truncation" => false}
      }
    ]
  end

  defp probe_wire_schema do
    IO.puts("\n-- Voyage wire probe (live, #{length(probe_arms())} requests) --")

    results = Enum.map(probe_arms(), &probe_arm/1)

    Enum.each(results, fn result ->
      flag = if result.ok?, do: "ok  ", else: "FAIL"

      IO.puts(
        "  #{flag} #{String.pad_trailing(result.got, 4)} (want #{result.expect})  " <>
          "#{result.label}#{result.note}"
      )
    end)

    halt_unless_schema_holds(results)
    Enum.each(results, &record_probe_body/1)

    IO.puts("  Schema holds: every named field is accepted and the control is rejected.\n")
  end

  defp probe_arm(%{label: label, expect: expect, record_as: record_as, body: body}) do
    {got, response_body} =
      case post(body) do
        {:ok, response} -> {"#{response.status}", response.body}
        {:error, reason} -> {"ERR " <> inspect(reason), nil}
      end

    usage = usage_verdict(expect, response_body)

    %{
      label: label,
      expect: expect,
      got: got,
      ok?: got == "#{expect}" and usage.ok?,
      note: usage.note,
      record_as: record_as,
      body: response_body
    }
  end

  # Every 200 arm additionally asserts the `usage` key list, because that one
  # row drives this adapter's entire `ALLM.Usage` mapping: `build_usage/1` reads
  # `total_tokens` and hardcodes `input_tokens: nil`, so a counter Voyage adds
  # later is dropped in silence. `embeddings_wire_test.exs`'s premise guard pins
  # the same property against the RECORDED bodies — it therefore fires only once
  # someone re-records. This arm is the repo's only LIVE observer of it, which
  # is the same argument that justifies the status assertions above.
  @expected_usage_keys ["total_tokens"]

  defp usage_verdict(200, body) when is_map(body) do
    case body |> Map.get("usage", %{}) |> Map.keys() |> Enum.sort() do
      @expected_usage_keys ->
        %{ok?: true, note: ""}

      other ->
        %{
          ok?: false,
          note: "  <- usage keys #{inspect(other)}, want #{inspect(@expected_usage_keys)}"
        }
    end
  end

  defp usage_verdict(_expect, _body), do: %{ok?: true, note: ""}

  # The whole point of the probe. A printed table nobody reads cannot hold an
  # invariant; the recording pass must not proceed on a broken premise.
  defp halt_unless_schema_holds(results) do
    if Enum.all?(results, & &1.ok?) do
      :ok
    else
      IO.puts(:stderr, "\nVoyage's request schema has CHANGED — refusing to record.\n")

      Enum.each(results, fn result ->
        IO.puts(
          :stderr,
          "  want #{result.expect}  got #{result.got}  #{result.label}#{result.note}"
        )
      end)

      IO.puts(
        :stderr,
        "\nRe-verify `to_json_body/2` in lib/allm/providers/voyage/embeddings.ex and the\n" <>
          "\"Wire-field map\" moduledoc section, then update probe_arms/0 here. A usage-key\n" <>
          "mismatch instead means `build_usage/1` needs extending (it hardcodes\n" <>
          "input_tokens: nil), along with the premise guard in\n" <>
          "test/allm/providers/voyage/embeddings_wire_test.exs. Note that that file asserts\n" <>
          "what the ADAPTER emits against a Req.Test stub and will stay green regardless —\n" <>
          "this script is the only place in the repo that observes the provider's actual\n" <>
          "schema."
      )

      System.halt(1)
    end
  end

  # Three arms already paid for a body worth keeping; hand-writing any of them
  # back into `synthesized/` would be a provider-wire claim with no artifact
  # behind it.
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

  # ---------------------------------------------------------------------------
  # Recording
  # ---------------------------------------------------------------------------

  defp record(%{name: name} = spec) do
    path = Path.join(@recorded_dir, "#{name}.json")

    if overwritable?(path) do
      do_record(path, spec, name)
    else
      IO.puts(
        "- #{path} already recorded (no _comment marker) — refusing to overwrite. " <>
          "Delete it first to re-record."
      )
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

  defp do_record(path, %{body: body}, name) do
    case post(body) do
      {:ok, %{status: 200} = response} ->
        write!(path, response.body)
        IO.puts("✓ recorded #{path}")

      {:ok, response} ->
        IO.puts(:stderr, "✗ #{name} failed: HTTP #{response.status} — #{inspect(response.body)}")

      {:error, reason} ->
        IO.puts(:stderr, "✗ #{name} transport failure: #{inspect(reason)}")
    end
  end

  defp write!(path, body), do: File.write!(path, Jason.encode!(body, pretty: true) <> "\n")

  defp post(body) do
    Req.post(@url,
      headers: [
        {"authorization", "Bearer " <> System.get_env("VOYAGE_API_KEY")},
        {"content-type", "application/json"}
      ],
      json: body,
      receive_timeout: 120_000
    )
  end
end

RecordVoyageEmbeddingsFixtures.run()
