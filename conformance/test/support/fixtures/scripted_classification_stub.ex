defmodule ALLM.Test.Fixtures.ScriptedClassificationStub do
  @moduledoc """
  Permanent test fixture that implements `ALLM.ClassificationAdapter`. Used by
  `allm_conformance`'s self-test for
  `ALLM.Test.ClassificationAdapterConformance`.

  ## Script contract

      adapter_opts: [
        classification_script: [
          {:answers, %{"id" => %ALLM.ClassificationAnswer{}}},
          {:error, %ALLM.Error.ClassificationAdapterError{}}
        ]
      ]

  The stub reads entry 0 on every call (the single-call contract every
  conformance case uses). `{:answers, map}` accepts only
  `%ALLM.ClassificationAnswer{}` values, used verbatim; every id not listed,
  and every call with no script, gets the stub's own default answer.

  Its defaults deliberately **differ** from
  `ALLM.Providers.FakeClassification`'s — the lexicographically *last*
  option with probability spread evenly, the *top* score level, a yes
  probability of `1.0` — so a harness case cannot pass merely because it
  hard-codes the reference implementation's numbers. It is not a second
  reference implementation: it has no numeric shorthand, no cursor, and no
  spent-script error.

  ## Real gates

  Unlike a scripted provider adapter, which short-circuits to the Fake before
  its own pre-flight runs, this stub evaluates the empty-questions gate ahead
  of the script, and ahead of anything resembling credential resolution.
  """

  @behaviour ALLM.ClassificationAdapter

  alias ALLM.{ClassificationAnswer, ClassificationQuestion, ClassificationRequest}
  alias ALLM.{ClassificationResponse, Usage}
  alias ALLM.Error.ClassificationAdapterError

  @impl ALLM.ClassificationAdapter
  def classify(%ClassificationRequest{questions: questions}, _opts) when questions == %{} do
    {:error,
     ClassificationAdapterError.new(:invalid_request,
       message: "questions must not be empty",
       metadata: %{field: :questions}
     )}
  end

  def classify(%ClassificationRequest{} = request, opts) when is_list(opts) do
    script =
      opts |> Keyword.get(:adapter_opts, []) |> Keyword.get(:classification_script, [])

    case List.first(script) do
      {:error, %ClassificationAdapterError{} = err} -> {:error, err}
      {:answers, overrides} when is_map(overrides) -> {:ok, response(request, overrides, opts)}
      nil -> {:ok, response(request, %{}, opts)}
    end
  end

  defp response(%ClassificationRequest{} = request, overrides, opts) do
    answers =
      Map.new(request.questions, fn {id, question} ->
        {id, Map.get_lazy(overrides, id, fn -> default(question) end)}
      end)

    %ClassificationResponse{
      id: nil,
      request_id: Keyword.get(opts, :request_id),
      model: request.model,
      provider: :stub,
      answers: answers,
      usage: %Usage{input_tokens: 1, output_tokens: 0, total_tokens: 1},
      raw: nil,
      metadata: request.metadata
    }
  end

  defp default(%ClassificationQuestion{type: :choice, criteria: criteria}) do
    options = Map.keys(criteria)
    share = 1.0 / length(options)

    ClassificationAnswer.new(
      type: :choice,
      choice: Enum.max(options),
      probabilities: Map.new(options, &{&1, share}),
      confidence: share
    )
  end

  defp default(%ClassificationQuestion{type: :score, criteria: levels}) do
    top = length(levels) - 1

    ClassificationAnswer.new(
      type: :score,
      score: top * 1.0,
      probabilities: for(level <- 0..top, do: if(level == top, do: 1.0, else: 0.0)),
      legend: levels,
      confidence: 1.0
    )
  end

  defp default(%ClassificationQuestion{type: :yes_no}),
    do: ClassificationAnswer.new(type: :yes_no, yes_probability: 1.0)
end
