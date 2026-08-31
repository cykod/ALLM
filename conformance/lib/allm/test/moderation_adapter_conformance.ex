defmodule ALLM.Test.ModerationAdapterConformance do
  @moduledoc """
  Injectable conformance suite for `ALLM.ModerationAdapter` implementations.

  ## Installation

      {:allm_conformance, "~> 0.3", only: :test}

  ## Usage

      defmodule MyModerationAdapterTest do
        use ExUnit.Case, async: true
        use ALLM.Test.ModerationAdapterConformance, moderation_adapter: MyModerationAdapter
      end

  Injects a `describe "ALLM.ModerationAdapter conformance (MyModerationAdapter)"`
  block with 10 deterministic cases.

  ## Script contract

  Each injected case scripts the adapter through
  `adapter_opts[:moderation_script]` on the call's `opts` keyword list. See
  `ALLM.Providers.FakeModeration`'s `script/1` `@doc` for the full grammar
  (the published reference implementation the suite targets).

  Real provider adapters honour the same key through a test-injection
  short-circuit that delegates to `ALLM.Providers.FakeModeration.moderate/2`
  before any pre-flight gate runs.

  ## Gate cases

  Cases 3 and 4 assert the two pre-flight gates (`:batch_too_large` and
  `:invalid_request`) and therefore pass **no script** — a scripted adapter
  short-circuits before reaching its own gates by design, so scripting them
  would assert nothing. Case 3 sizes its oversized input from
  `max_batch_size/0` on the adapter under test rather than from a literal, so
  it stays correct for a third-party adapter whose cap is 1 or 100_000.

  ## Batch sizing

  No case sizes its input from a bare literal. Case 3 crosses the
  `:batch_too_large` boundary at `max_batch_size() + 1`; cases 5, 6 and 7 want
  a *small* batch and take `min(<wanted>, max_batch_size())`, so an adapter
  whose cap is `1` or `2` is certified rather than failed by its own correct
  invariant-5 rejection. Case 10's two-element multimodal input is
  deliberately **not** clamped: `ALLM.ModerationAdapter` invariant 5 measures
  *items*, and a multimodal `:input` is one item however long the list is.

  Both cases run against the caller-supplied adapter and nothing else: every
  assertion in this suite has to be reachable for every consumer of the
  package, so no case may be gated on a fixture that lives inside
  `allm_conformance`'s own test tree — a case body wrapped in
  `if fixture = optional() do ... end` compiles to an assertion-free test
  that ExUnit reports green.

  ## What this suite does NOT bind

  **Invariant 2 is deliberately unbound.** `ALLM.ModerationAdapter`'s
  invariant 2 — `moderate/2` returns exactly one of the two documented
  tuples — is enforced at the façade, which raises `ArgumentError` on any
  other shape. That enforcement lives outside every adapter, so a conformance
  run cannot observe it. An adapter certified only by this suite has had
  **no** check that its transport, auth, or rate-limit failure paths return
  the error tuple rather than a raw struct or a three-tuple. Convert every
  failure shape; the suite will not tell you if you did not.

  Cases 2 and 5–10 drive the adapter through
  `adapter_opts[:moderation_script]`. For an adapter whose short-circuit
  returns the scripted response verbatim — `ALLM.Providers.FakeModeration`
  and every bundled provider adapter — the success path never reaches that
  adapter's own response decoder. For those adapters these cases therefore do
  **not** bind `ALLM.ModerationAdapter` invariants 3 and 4 (result cardinality
  and `:index` values `0..length-1`); they bind them only for an adapter that
  implements `moderate/2` itself rather than delegating.

  A passthrough adapter's invariant-3 and invariant-4 conformance is the job
  of that adapter's own decoder tests, driven from recorded wire fixtures.
  **Do not read a green run of this suite as evidence that a provider's
  decoder indexes its response correctly.**

  ## Why the helpers below take and return plain data

  This package is compiled *before* `allm` in a consuming project's build, so
  the harness module body must not reference `ALLM.*` functions directly —
  every such call happens inside the `using/1` `quote`, which expands at the
  consumer's compile time when `allm` is loaded.
  """

  use ExUnit.CaseTemplate

  @case_count 10

  @doc """
  Return the number of cases injected by `using/1`. Used by harness
  self-tests to guard against silent case-count drift.
  """
  @spec case_count() :: pos_integer()
  def case_count, do: @case_count

  @doc false
  @spec inputs(pos_integer()) :: [String.t()]
  def inputs(count) when is_integer(count) and count >= 1,
    do: for(i <- 1..count, do: "conformance input #{i}")

  @doc false
  @spec png_bytes() :: binary()
  def png_bytes, do: <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13>>

  using opts do
    quote location: :keep do
      @__allm_moderation_conformance_adapter__ Keyword.fetch!(
                                                 unquote(opts),
                                                 :moderation_adapter
                                               )

      describe "ALLM.ModerationAdapter conformance (#{inspect(@__allm_moderation_conformance_adapter__)})" do
        alias ALLM.Error.ModerationAdapterError
        alias ALLM.{Image, ImagePart, ModerationRequest, ModerationResponse, ModerationResult}
        alias ALLM.Test.ModerationAdapterConformance, as: Harness

        test "1. max_batch_size/0 returns a pos_integer" do
          max = @__allm_moderation_conformance_adapter__.max_batch_size()
          assert is_integer(max)
          assert max > 0
        end

        test "2. single string input returns exactly one result at index: 0" do
          req = ModerationRequest.new(input: ["is this ok?"])
          script = [{:ok, [ModerationResult.new(flagged: false, index: 0)]}]

          assert {:ok, %ModerationResponse{results: [%ModerationResult{index: 0}]}} =
                   @__allm_moderation_conformance_adapter__.moderate(req,
                     adapter_opts: [moderation_script: script]
                   )
        end

        test "3. input longer than max_batch_size is rejected with :batch_too_large before I/O" do
          adapter = @__allm_moderation_conformance_adapter__
          max = adapter.max_batch_size()
          req = ModerationRequest.new(input: Harness.inputs(max + 1))

          # No script: a scripted adapter short-circuits ahead of its gates.
          # No key either: the gate must fire before credential resolution.
          assert {:error, %ModerationAdapterError{reason: :batch_too_large, metadata: meta}} =
                   adapter.moderate(req, [])

          assert meta.count == max + 1
          assert meta.max == max
        end

        test "4. empty input is rejected with :invalid_request before I/O" do
          req = ModerationRequest.new(input: [])

          assert {:error, %ModerationAdapterError{reason: :invalid_request}} =
                   @__allm_moderation_conformance_adapter__.moderate(req, [])
        end

        test "5. an all-strings batch returns exactly length(input) results" do
          adapter = @__allm_moderation_conformance_adapter__
          # Clamped to the adapter's own cap: a correct invariant-5 rejection
          # must never be what makes this case red. See `## Batch sizing`.
          n = min(4, adapter.max_batch_size())
          req = ModerationRequest.new(input: Harness.inputs(n))
          results = for i <- 0..(n - 1), do: ModerationResult.new(flagged: false, index: i)

          assert {:ok, %ModerationResponse{results: out}} =
                   adapter.moderate(req, adapter_opts: [moderation_script: [{:ok, results}]])

          assert length(out) == length(req.input)
        end

        test "6. :index values are exactly 0..length-1" do
          adapter = @__allm_moderation_conformance_adapter__
          n = min(3, adapter.max_batch_size())
          req = ModerationRequest.new(input: Harness.inputs(n))

          # Deliberately out of order — last index first: the contract is on
          # the SET of indices, and an adapter must not depend on the provider
          # emitting them pre-sorted. `Enum.slide/3` degenerates to the
          # identity at n == 1, so the scramble needs no conditional in the
          # case body.
          scrambled = Enum.slide(Enum.to_list(0..(n - 1)), -1, 0)
          results = for i <- scrambled, do: ModerationResult.new(flagged: false, index: i)

          assert {:ok, %ModerationResponse{results: out}} =
                   adapter.moderate(req, adapter_opts: [moderation_script: [{:ok, results}]])

          assert out |> Enum.map(& &1.index) |> Enum.sort() ==
                   Enum.to_list(0..(length(req.input) - 1))
        end

        test "7. :flagged is a boolean and both category maps are string-keyed" do
          adapter = @__allm_moderation_conformance_adapter__
          n = min(2, adapter.max_batch_size())
          req = ModerationRequest.new(input: Harness.inputs(n))

          # The populated result is first, so it survives the clamp at n == 1.
          results =
            Enum.take(
              [
                ModerationResult.new(
                  flagged: true,
                  categories: %{"violence" => true, "hate" => false},
                  category_scores: %{"violence" => 0.91, "hate" => 0.01},
                  index: 0
                ),
                ModerationResult.new(flagged: false, index: 1)
              ],
              n
            )

          assert {:ok, %ModerationResponse{results: out}} =
                   adapter.moderate(req, adapter_opts: [moderation_script: [{:ok, results}]])

          for %ModerationResult{} = result <- out do
            assert is_boolean(result.flagged)
            assert is_map(result.categories)
            assert is_map(result.category_scores)
            assert Enum.all?(Map.keys(result.categories), &is_binary/1)
            assert Enum.all?(Map.keys(result.category_scores), &is_binary/1)
          end
        end

        test "8. round-trips request.metadata onto response.metadata unchanged" do
          metadata = %{trace_id: "abc", user: "alice"}
          req = ModerationRequest.new(input: ["x"], metadata: metadata)
          script = [{:ok, [ModerationResult.new(flagged: false, index: 0)]}]

          assert {:ok, %ModerationResponse{metadata: ^metadata}} =
                   @__allm_moderation_conformance_adapter__.moderate(req,
                     adapter_opts: [moderation_script: script]
                   )
        end

        test "9. preserves opts[:request_id] onto ModerationResponse.request_id" do
          req = ModerationRequest.new(input: ["x"])
          script = [{:ok, [ModerationResult.new(flagged: false, index: 0)]}]

          assert {:ok, %ModerationResponse{request_id: "test-id-123"}} =
                   @__allm_moderation_conformance_adapter__.moderate(req,
                     adapter_opts: [moderation_script: script],
                     request_id: "test-id-123"
                   )
        end

        test "10. a multimodal input returns exactly one result" do
          # Two list elements but ONE item, so invariant 5's batch gate must
          # not reject this even for an adapter whose cap is 1 — see the
          # behaviour's invariant 5, which measures items rather than raw
          # list elements. Deliberately not clamped.
          part = ImagePart.new(Image.from_binary(Harness.png_bytes(), "image/png"))
          req = ModerationRequest.new(input: ["look at this", part])
          script = [{:ok, [ModerationResult.new(flagged: false, index: 0)]}]

          assert ModerationRequest.multimodal?(req)

          assert {:ok, %ModerationResponse{results: [%ModerationResult{index: 0}]}} =
                   @__allm_moderation_conformance_adapter__.moderate(req,
                     adapter_opts: [moderation_script: script]
                   )
        end
      end
    end
  end
end
