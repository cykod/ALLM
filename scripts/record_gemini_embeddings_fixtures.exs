# scripts/record_gemini_embeddings_fixtures.exs
#
# Fixture recorder for `test/fixtures/gemini/embeddings/recorded/`.
# Runs against the live Gemini `batchEmbedContents` API; gated on
# `GEMINI_API_KEY`.
#
# Idempotent by construction: it NEVER touches
# `test/fixtures/gemini/embeddings/synthesized/`, and it refuses to overwrite
# a `recorded/` file that has already been recorded — i.e. one that no longer
# carries a leading `_comment` provenance marker. A second run against an
# already-recorded tree is therefore a no-op **including the placement probe**:
# `run/0` checks every target path FIRST and returns without issuing a single
# HTTP request when they are all already recorded. (Before the 20.5 fix step the
# probe fired ahead of that check, so a "no-op" run still spent four live calls.)
#
# Usage:
#
#     mix run scripts/record_gemini_embeddings_fixtures.exs
#
# The key is read from the environment, but a project-root `.env` is loaded
# first — that gitignored file is this repo's documented key mechanism
# (`examples/README.md`), and `examples/_helpers.exs` already loads it via the
# `:env_loader` dev dep. `.env` is consulted only when the variable is not
# already set, so an explicit assignment still wins:
#
#     GEMINI_API_KEY=AIza... mix run scripts/record_gemini_embeddings_fixtures.exs
#
# To deliberately re-record a fixture, delete the file first (or restore its
# `_comment` marker) and re-run.
#
# Approximate cost (one-time), `gemini-embedding-001` at $0.15 / 1M input
# tokens: ~25 tokens across the two recordings plus the placement probe, well
# under $0.0001. Verify against https://ai.google.dev/pricing.
#
# The `autoTruncate` placement probe
# ----------------------------------
#
# `run/0` issues four live calls BEFORE recording anything and **asserts** the
# outcome, halting the whole recording pass on a mismatch. This exists because
# the placement of `autoTruncate` on the BATCH path is not settled by Google's
# published schema: the field is documented on the single-item `:embedContent`
# request nested in `embedContentConfig`, while the published
# `batchEmbedContents` sub-request schema enumerates only `model` and
# `content`.
#
# The probe is a four-way discrimination, not a single call, because
# "the request was accepted" is only evidence of schema membership if the API
# is known to reject unknown fields. The control arm establishes exactly that.
# Expected outcome, asserted by `probe_arms/0` below and first observed on
# 2026-07-29 against `gemini-embedding-001` on `v1beta`:
#
#   * `embedContentConfig: {autoTruncate: false}` on the sub-request -> 200
#   * `autoTruncate: false` as a sub-request sibling                 -> 400
#   * `autoTruncate: false` as a top-level sibling of `requests`     -> 400
#   * `totallyNotAField: {}` on the sub-request (CONTROL)            -> 400
#
# The control rejecting is what makes the first arm's 200 meaningful: Google
# validates unknown fields strictly, so acceptance means `embedContentConfig`
# is a recognised member of the batch sub-request schema. The adapter emits
# the nested form.
#
# The probe ASSERTS rather than narrates. Each arm carries an expected status
# in `probe_arms/0`; any divergence prints the full result table to stderr and
# `System.halt(1)`s before a single fixture is written. A probe that prints its
# verdict into a scrollback is documentation with a network bill: if Google
# moves `autoTruncate`, the `Req.Test`-stubbed wire tests assert what the
# ADAPTER emits and stay green forever, so this script is the only place in the
# repo that can observe the change — and it must therefore fail on it.
#
# The probe also RECORDS, because two of its arms already pay for a genuine
# Google 400 envelope. The CONTROL arm's body is written to
# `recorded/error_400_unknown_field.json` (subject to the same
# refuse-to-overwrite guard as every other recorded fixture), which is what
# lets `embeddings_wire_test.exs` assert the `{"error": {code, message,
# status, details}}` envelope shape against a response Google actually sent
# rather than against a hand-written recollection of one. A status code is the
# cheapest field in a response and almost never the thing under test.
#
# Load-bearing details for the wire tests
# ---------------------------------------
#
#   * `batch_embed_contents` MUST record exactly THREE inputs —
#     `test/allm/providers/gemini/embeddings_test.exs` drives it with a
#     three-element `:input` and asserts `length(embeddings) == length(input)`
#     with `:index` values `0..n-1` (the assertion that binds
#     `ALLM.EmbeddingAdapter` invariant 8 for this adapter, which the
#     conformance suite cannot). Gemini assigns `:index` by list position, so
#     a dropped sub-response shifts every subsequent index silently.
#   * `batch_embed_contents` is recorded at `outputDimensionality: 768`, which
#     `gemini-embedding-001` does NOT normalise (measured L2 norm 0.589 on
#     2026-07-29). That is what makes the Decision-#7 normalisation tests
#     falsifiable: driving the same fixture at `dimensions: nil` must leave
#     the values untouched, and at `dimensions: 768` must yield unit vectors.
#     A pre-normalised fixture would make both assertions pass vacuously.
#   * `reduced_dimensions` MUST request fewer dimensions than
#     `batch_embed_contents`, because the wire test asserts the RELATION
#     `dimension_of(reduced) < dimension_of(batch)` rather than a literal.
#   * `error_400_unknown_field` is written by the probe's CONTROL arm, not by
#     `@specs`. It is the tree's only GENUINE Gemini error envelope, and
#     `embeddings_wire_test.exs` asserts the `{"error": {code, message, status}}`
#     shape and the `:invalid_request` / `google_status` mapping against it.
#     The two `synthesized/` error fixtures remain hand-written on purpose: the
#     429 would need sustained abuse of the endpoint to provoke, and the 400's
#     message carries a deliberately-planted `AIzaSy…` string so the redaction
#     test has a target (Google's real text does not echo the key back).
#
# This script is NOT included in the published Hex package — `mix.exs`
# excludes `scripts/` from the package files list.

defmodule RecordGeminiEmbeddingsFixtures do
  @moduledoc false

  @recorded_dir "test/fixtures/gemini/embeddings/recorded"
  @base_url "https://generativelanguage.googleapis.com/v1beta"
  @model "gemini-embedding-001"

  # The CONTROL arm's 400 envelope is recorded here — see the header note.
  @error_fixture_name "error_400_unknown_field"

  @specs [
    %{
      # Exactly three inputs at 768 dimensions — see the header note.
      name: "batch_embed_contents",
      inputs: ["chunk one", "chunk two", "chunk three"],
      dimensions: 768,
      task_type: "RETRIEVAL_DOCUMENT"
    },
    %{
      # Narrower than the batch fixture so the wire test's relation holds.
      name: "reduced_dimensions",
      inputs: ["a kestrel"],
      dimensions: 256,
      task_type: nil
    }
  ]

  def run do
    load_dotenv()

    unless System.get_env("GEMINI_API_KEY") do
      IO.puts(
        :stderr,
        "GEMINI_API_KEY not set (checked the environment and project-root .env) — " <>
          "refusing to record."
      )

      System.halt(1)
    end

    File.mkdir_p!(@recorded_dir)

    # Every target path is checked BEFORE any HTTP request, so a run against a
    # fully-recorded tree costs zero live calls — including the probe's four.
    if Enum.empty?(pending_paths()) do
      IO.puts(
        "Nothing to record: every fixture under #{@recorded_dir}/ is already a live " <>
          "recording (no _comment marker). No HTTP requests were made — including the " <>
          "placement probe. Delete a file first to re-record it."
      )
    else
      probe_auto_truncate_placement()
      Enum.each(@specs, &record/1)

      IO.puts(
        "Done. Recorded fixtures live under #{@recorded_dir}/. Review the diff, then " <>
          "re-run `mix test test/allm/providers/gemini/embeddings_wire_test.exs`."
      )
    end
  end

  # Every `recorded/` file this script owns: the two 200 bodies plus the
  # CONTROL arm's 400 envelope.
  defp target_paths do
    Enum.map(@specs ++ [%{name: @error_fixture_name}], &Path.join(@recorded_dir, "#{&1.name}.json"))
  end

  defp pending_paths, do: Enum.filter(target_paths(), &overwritable?/1)

  # Mirrors `scripts/record_openai_embeddings_fixtures.exs`. Loaded ONLY when
  # the key is not already in the environment: `EnvLoader.load/1` calls
  # `System.put_env/2` unconditionally, so an unguarded load would let a stale
  # `.env` silently override an explicit `GEMINI_API_KEY=... mix run ...`.
  defp load_dotenv do
    path = Path.expand(".env", Path.join(__DIR__, ".."))

    if is_nil(System.get_env("GEMINI_API_KEY")) and Code.ensure_loaded?(EnvLoader) and
         File.exists?(path) do
      EnvLoader.load(path)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # `autoTruncate` placement probe — see the header note for why the control
  # arm is what makes this conclusive.
  # ---------------------------------------------------------------------------

  # `expect: 200` is schema membership; `expect: 400` is rejection of a field
  # Google does not know. The CONTROL arm is what turns the first arm's 200
  # from "accepted" into "recognised" — without it, a 200 is equally consistent
  # with Google silently ignoring unknown keys.
  defp probe_arms do
    bare = %{
      "model" => "models/#{@model}",
      "content" => %{"parts" => [%{"text" => "a kestrel"}]}
    }

    [
      %{
        label: "embedContentConfig.autoTruncate=false (nested — the adapter's shape)",
        expect: 200,
        control: false,
        body: %{"requests" => [Map.put(bare, "embedContentConfig", %{"autoTruncate" => false})]}
      },
      %{
        label: "autoTruncate=false as a sub-request sibling",
        expect: 400,
        control: false,
        body: %{"requests" => [Map.put(bare, "autoTruncate", false)]}
      },
      %{
        label: "autoTruncate=false as a top-level sibling of `requests`",
        expect: 400,
        control: false,
        body: %{"requests" => [bare], "autoTruncate" => false}
      },
      %{
        label: "CONTROL: totallyNotAField on the sub-request (unknown-field tolerance)",
        expect: 400,
        control: true,
        body: %{"requests" => [Map.put(bare, "totallyNotAField", %{})]}
      }
    ]
  end

  defp probe_auto_truncate_placement do
    IO.puts("\n-- autoTruncate placement probe (live, 4 requests) --")

    results = Enum.map(probe_arms(), &probe_arm/1)

    Enum.each(results, fn result ->
      flag = if result.ok?, do: "ok  ", else: "FAIL"

      IO.puts(
        "  #{flag} #{String.pad_trailing(result.got, 4)} (want #{result.expect})  #{result.label}"
      )
    end)

    halt_unless_placement_holds(results)
    record_control_envelope(results)

    IO.puts("  Placement holds: the nested arm is 200 and the control is 400.\n")
  end

  defp probe_arm(%{label: label, expect: expect, control: control, body: body}) do
    {got, response_body} =
      case post(body) do
        {:ok, response} -> {"#{response.status}", response.body}
        {:error, reason} -> {"ERR " <> inspect(reason), nil}
      end

    %{
      label: label,
      expect: expect,
      got: got,
      ok?: got == "#{expect}",
      control: control,
      body: response_body
    }
  end

  # The whole point of the probe. A printed table nobody reads cannot hold an
  # invariant; the recording pass must not proceed on a broken premise.
  defp halt_unless_placement_holds(results) do
    if Enum.all?(results, & &1.ok?) do
      :ok
    else
      IO.puts(:stderr, "\nautoTruncate placement has CHANGED — refusing to record.\n")

      Enum.each(results, fn result ->
        IO.puts(:stderr, "  want #{result.expect}  got #{result.got}  #{result.label}")
      end)

      IO.puts(
        :stderr,
        "\nRe-verify `auto_truncate_pair/1` in lib/allm/providers/gemini/embeddings.ex and\n" <>
          "the \"Truncation\" moduledoc section, then update probe_arms/0 here. Note that\n" <>
          "test/allm/providers/gemini/embeddings_wire_test.exs asserts what the ADAPTER\n" <>
          "emits against a Req.Test stub and will stay green regardless — this script is\n" <>
          "the only place in the repo that observes the provider's actual schema."
      )

      System.halt(1)
    end
  end

  # The control arm already paid for a genuine Google 400 envelope; keeping only
  # its status code and hand-writing the body back into `synthesized/` would be
  # a provider-wire claim with no artifact behind it.
  defp record_control_envelope(results) do
    path = Path.join(@recorded_dir, "#{@error_fixture_name}.json")
    control = Enum.find(results, & &1.control)

    cond do
      not overwritable?(path) ->
        IO.puts("  - #{path} already recorded — refusing to overwrite.")

      is_map(control.body) ->
        File.write!(path, Jason.encode!(control.body, pretty: true) <> "\n")
        IO.puts("  ✓ recorded #{path} (the CONTROL arm's live 400 envelope)")

      true ->
        IO.puts(:stderr, "  ✗ control arm returned no decodable body: #{inspect(control.body)}")
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

  # A file is safe to overwrite when it does not exist, or when it still
  # carries the leading `_comment` marker that synthesized placeholders use.
  # A real recorded response has no such field.
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

  defp do_record(path, spec, name) do
    case post(%{"requests" => Enum.map(spec.inputs, &sub_request(&1, spec))}) do
      {:ok, %{status: 200} = response} ->
        File.write!(path, Jason.encode!(response.body, pretty: true) <> "\n")
        IO.puts("✓ recorded #{path}")

      {:ok, response} ->
        IO.puts(:stderr, "✗ #{name} failed: HTTP #{response.status} — #{inspect(response.body)}")

      {:error, reason} ->
        IO.puts(:stderr, "✗ #{name} transport failure: #{inspect(reason)}")
    end
  end

  # Mirrors `ALLM.Providers.Gemini.Embeddings.to_batch_body/2`'s sub-request
  # shape. Kept literal rather than calling the adapter so a bug in the adapter
  # cannot quietly re-shape the fixture it is supposed to be checked against.
  defp sub_request(text, spec) do
    %{
      "model" => "models/#{@model}",
      "content" => %{"parts" => [%{"text" => text}]}
    }
    |> maybe_put("outputDimensionality", spec.dimensions)
    |> maybe_put("taskType", spec.task_type)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp post(body) do
    Req.post("#{@base_url}/models/#{@model}:batchEmbedContents",
      headers: [
        {"x-goog-api-key", System.get_env("GEMINI_API_KEY")},
        {"content-type", "application/json"}
      ],
      json: body,
      receive_timeout: 120_000
    )
  end
end

RecordGeminiEmbeddingsFixtures.run()
