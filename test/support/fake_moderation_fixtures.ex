defmodule ALLM.Test.FakeModerationFixtures do
  @moduledoc """
  Named scripted fixtures for `ALLM.Providers.FakeModeration`. Every fixture
  returns a keyword `adapter_opts` ready to pass to `ALLM.Engine.new/1` under
  the `adapter_opts:` key, or straight into a direct `moderate/2` call.

  Layer B (test support) — lives under `test/support/` and is not part of the
  published Hex package. The Fake adapter itself ships in `lib/` but its named
  test fixtures stay test-only.

  Verdicts are deterministic and carry the same 13 `omni-moderation` category
  names the adapter synthesizes (`ALLM.Providers.FakeModeration.categories/0`),
  so a fixture-driven test and a default-verdict test assert against one
  vocabulary.
  """

  alias ALLM.Engine
  alias ALLM.Error.ModerationAdapterError
  alias ALLM.ModerationResult
  alias ALLM.Providers.FakeModeration

  @doc """
  An engine wired to `ALLM.Providers.FakeModeration`, carrying `adapter_opts`
  and a stable `:id` (so the per-engine cursor key applies).
  """
  @spec engine(keyword()) :: Engine.t()
  def engine(adapter_opts \\ []) when is_list(adapter_opts),
    do: Engine.new(moderation_adapter: FakeModeration, adapter_opts: adapter_opts)

  @doc """
  A clean (unflagged) result at `index`, carrying every omni category `false`.
  """
  @spec clean(non_neg_integer()) :: ModerationResult.t()
  def clean(index \\ 0) when is_integer(index) and index >= 0 do
    ModerationResult.new(
      flagged: false,
      categories: Map.new(FakeModeration.categories(), &{&1, false}),
      category_scores: Map.new(FakeModeration.categories(), &{&1, 0.0}),
      index: index
    )
  end

  @doc """
  Script returning `count` clean results in one call.
  """
  @spec clean_batch(pos_integer()) :: keyword()
  def clean_batch(count) when is_integer(count) and count >= 1,
    do: [moderation_script: [{:ok, Enum.map(0..(count - 1), &clean/1)}]]

  @doc """
  Script returning one flagged result carrying `categories`.
  """
  @spec flagged([String.t()]) :: keyword()
  def flagged(categories) when is_list(categories),
    do: [moderation_script: [{:flagged, categories}]]

  @doc """
  Script driving a scripted `:rate_limited` rejection returned verbatim.
  """
  @spec rate_limited() :: keyword()
  def rate_limited do
    err =
      ModerationAdapterError.new(:rate_limited,
        message: "scripted rate limit",
        provider: :fake,
        retry_after_ms: 250
      )

    [moderation_script: [{:error, err}]]
  end

  @doc """
  Script that fails with a synthetic `:rate_limited` for the first `n - 1`
  calls and then returns a flagged result carrying `categories`.
  """
  @spec retry_until_call(pos_integer(), [String.t()]) :: keyword()
  def retry_until_call(n, categories) when is_integer(n) and n >= 1 and is_list(categories),
    do: [moderation_script: [{:retry_until_call, n}, {:flagged, categories}]]
end
