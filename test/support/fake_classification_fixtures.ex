defmodule ALLM.Test.FakeClassificationFixtures do
  @moduledoc """
  Named requests and scripted fixtures for `ALLM.Providers.FakeClassification`.

  Layer B (test support) — lives under `test/support/` and is not part of the
  published Hex package. Every script fixture returns a keyword `adapter_opts`
  ready to pass to `ALLM.Engine.new/1` under `adapter_opts:`, or straight into
  a direct `classify/2` call.
  """

  alias ALLM.{ClassificationQuestion, ClassificationRequest, Engine}
  alias ALLM.Error.ClassificationAdapterError
  alias ALLM.Providers.FakeClassification

  @doc """
  A request carrying one question of each type: `"d"` (choice over
  `billing`/`technical`/`sales`), `"s"` (score on three levels) and `"y"`
  (yes/no). `opts` are merged onto the request.
  """
  @spec request(keyword()) :: ClassificationRequest.t()
  def request(opts \\ []) when is_list(opts) do
    ClassificationRequest.new(
      Keyword.merge(
        [state: "My payouts failed twice this week.", questions: questions()],
        opts
      )
    )
  end

  @doc ~s(The three questions `request/1` carries, keyed "d", "s" and "y".)
  @spec questions() :: %{String.t() => ClassificationQuestion.t()}
  def questions do
    %{
      "d" => ClassificationQuestion.choice("Which team?", ["billing", "technical", "sales"]),
      "s" => ClassificationQuestion.score("How frustrated?", ["Calm", "Annoyed", "Angry"]),
      "y" => ClassificationQuestion.yes_no("Is a refund requested?")
    }
  end

  @doc """
  An engine wired to `ALLM.Providers.FakeClassification`, carrying
  `adapter_opts` and a stable `:id` (so the per-engine cursor key applies).
  """
  @spec engine(keyword()) :: Engine.t()
  def engine(adapter_opts \\ []) when is_list(adapter_opts),
    do: Engine.new(classification_adapter: FakeClassification, adapter_opts: adapter_opts)

  @doc "Script answering with the given per-id overrides in one call."
  @spec answers(map()) :: keyword()
  def answers(overrides) when is_map(overrides),
    do: [classification_script: [{:answers, overrides}]]

  @doc "Script returning a scripted `:rate_limited` rejection verbatim."
  @spec rate_limited() :: keyword()
  def rate_limited do
    err =
      ClassificationAdapterError.new(:rate_limited,
        message: "scripted rate limit",
        provider: :fake,
        retry_after_ms: 250
      )

    [classification_script: [{:error, err}]]
  end
end
