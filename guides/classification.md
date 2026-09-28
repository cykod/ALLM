# Typed classification

Classification asks a fast, calibrated model closed-form questions about a
piece of text — "which team owns this ticket?", "how frustrated is this
customer, on a 0–2 scale?", "is a refund being requested?" — and returns
**typed answers with probabilities**, without generating any text. ALLM
exposes it as a non-streaming primitive parallel to chat, images,
embeddings, moderation and audio: `%ALLM.ClassificationRequest{}` and
`%ALLM.ClassificationResponse{}` mirror the `Request`/`Response` shape, the
engine has its own `:classification_adapter` slot, and one entry point —
`ALLM.classify/3` — covers it.

Without it an application has two routes, both worse: hand-roll an HTTP
client, or prompt a chat model to "answer in JSON" and parse the text
back, which is slower, not calibrated, and breaks when the model adds a
sentence of preamble.

**The library does not decide thresholds.** It returns the probabilities,
score position and confidence the provider reports. There is no default
confidence floor, no `yes?/2` with a baked-in 0.5, and no routing DSL. What
counts as "confident enough" is a product decision, so it lives in your
code — see "Routing on confidence" below.

The bundled provider is TypeSafe's Jev model, through
`ALLM.Providers.TypeSafe.Classification`. Jev is a classification model,
not a chat model: TypeSafe gets a classification adapter in ALLM and
nothing else.

## The classification engine slot

Classification has its own adapter slot and its own model slot:
`:classification_adapter` and `:classification_model`. Neither falls back
to the chat `:adapter` or the chat `:model`, so one engine can pair a chat
provider with a classification provider and each gets the model it
actually uses:

```elixir
engine =
  ALLM.Engine.new(
    adapter: ALLM.Providers.Anthropic,                                 # chat
    model: "claude-sonnet-4-6",                                        # the CHAT model
    classification_adapter: ALLM.Providers.TypeSafe.Classification,    # classification
    classification_model: "jev-1.13.0"                                 # the classification model
  )
```

`ALLM.classify/3` reads `request.model`, then `engine.classification_model`,
and never `engine.model` — a chat model name sent to a classification
endpoint is a guaranteed rejection. When neither is set, the TypeSafe
adapter sends its documented default, `"jev-latest"`.

Calling `ALLM.classify/3` on an engine with no `:classification_adapter`
returns an engine error before anything else runs, so a misconfigured
engine never surfaces as a request problem:

    iex> question = ALLM.ClassificationQuestion.yes_no("Is a refund requested?")
    iex> {:error, error} = ALLM.classify(ALLM.Engine.new(), "Please refund me.", questions: %{refund: question})
    iex> error.reason
    :no_classification_adapter

Keys resolve at call time through `ALLM.Keys` — for TypeSafe, from
`opts[:api_key]` or the `TYPESAFE_API_KEY` environment variable — never
from the engine, so a serialized engine stays safe to persist.

## A first call

`ALLM.classify/3` takes the state (a string, a JSON object as a map, or a
JSON array as a list) and a `:questions` map from your own question ids to
`%ALLM.ClassificationQuestion{}` values. The examples below use
`ALLM.Providers.FakeClassification` so they run with no network and no key
— see "Testing" at the end for the scripting grammar.

    iex> questions = %{
    ...>   "department" => ALLM.ClassificationQuestion.choice("Which team should handle this?", ["billing", "technical", "sales"]),
    ...>   "frustration" => ALLM.ClassificationQuestion.score("How frustrated is the customer?", ["calm", "annoyed", "furious"]),
    ...>   "refund" => ALLM.ClassificationQuestion.yes_no("Is a refund being requested?")
    ...> }
    iex> engine = ALLM.Engine.new(
    ...>   classification_adapter: ALLM.Providers.FakeClassification,
    ...>   adapter_opts: [classification_script: [
    ...>     {:answers, %{"department" => "billing", "frustration" => 1.25, "refund" => 0.9}}
    ...>   ]]
    ...> )
    iex> {:ok, response} = ALLM.classify(engine, "I was charged twice and I want my money back.", questions: questions)
    iex> ALLM.ClassificationResponse.answer(response, "department").choice
    "billing"
    iex> ALLM.ClassificationResponse.answer(response, "frustration").score
    1.25
    iex> ALLM.ClassificationResponse.answer(response, :refund).yes_probability
    0.9

Question ids are strings on the wire and on the struct. Atom ids passed to
`ALLM.classify/3` or `ALLM.classification_request/2` are converted to
strings (an atom key would not survive a JSON round trip), and
`ALLM.ClassificationResponse.answer/2` accepts either spelling.

## The three question types

A request may mix all three freely. Each answer is one
`%ALLM.ClassificationAnswer{}` whose `:type` matches its question's, and
`ALLM.ClassificationAnswer.value/1` returns the headline field for each
type.

### `choice/2` — pick one option

Use it when exactly one of a named set applies: routing, intent, topic,
language. Options are a list of names, or a map of name to a description
that tells the model what the option means:

    iex> q = ALLM.ClassificationQuestion.choice("Which team should handle this?", %{
    ...>   "billing" => "charges, invoices, refunds",
    ...>   "technical" => "errors, crashes, login problems"
    ...> })
    iex> q.criteria
    %{"billing" => "charges, invoices, refunds", "technical" => "errors, crashes, login problems"}

The answer carries `:choice` (the option picked), `:probabilities` (a map
of every option to its probability) and `:confidence`.

### `score/2` — place on an ordered scale

Use it when the options are ordered from low to high: severity, urgency,
sentiment, quality. Levels are a list, and **index = level**. The answer
carries a fractional `:score` between `0.0` and the number of levels minus
one, plus `:probabilities` and `:legend` as lists in the same order, so
`Enum.at(answer.probabilities, 2)` is the probability of level 2:

    iex> engine = ALLM.Engine.new(
    ...>   classification_adapter: ALLM.Providers.FakeClassification,
    ...>   adapter_opts: [classification_script: [{:answers, %{"frustration" => 1.25}}]]
    ...> )
    iex> q = ALLM.ClassificationQuestion.score("How frustrated is the customer?", ["calm", "annoyed", "furious"])
    iex> {:ok, response} = ALLM.classify(engine, "This is the third time I have asked.", questions: %{"frustration" => q})
    iex> answer = ALLM.ClassificationResponse.answer(response, "frustration")
    iex> {answer.score, answer.probabilities, answer.legend}
    {1.25, [0.0, 0.75, 0.25], ["calm", "annoyed", "furious"]}

A score question needs at least two levels; one level always scores `0`,
so `ALLM.classify/3` rejects it. TypeSafe accepts up to 10.

### `yes_no/2` — the probability of yes

Use it for a single binary property: "is a refund requested?", "does this
mention a competitor?". The optional `true:` and `false:` opts describe
what each answer means. The answer carries `:yes_probability`, and
`:confidence` is always `nil`: the probability *is* the answer. TypeSafe
calls this type `noul`; ALLM spells it `:yes_no` everywhere, and the
TypeSafe adapter translates on the wire.

    iex> q = ALLM.ClassificationQuestion.yes_no("Is a refund being requested?", true: "the customer asks for money back")
    iex> {q.type, q.criteria}
    {:yes_no, %{"true" => "the customer asks for money back"}}

Instructions, option descriptions and score levels may also be JSON
objects or arrays rather than strings, when a question is clearer as
structured data. A score question whose levels are objects gets those
objects back as its `:legend` entries.

## Routing on confidence

Because ALLM ships no threshold, routing is ordinary pattern matching in
your code. Decide what probability justifies an automatic action and what
falls through to a person:

    iex> route = fn response ->
    ...>   case ALLM.ClassificationResponse.answer(response, "department") do
    ...>     %{choice: team, confidence: c} when c >= 0.8 -> {:auto_assign, team}
    ...>     %{choice: team} -> {:needs_review, team}
    ...>   end
    ...> end
    iex> sure = ALLM.ClassificationResponse.new(answers: %{
    ...>   "department" => ALLM.ClassificationAnswer.new(type: :choice, choice: "billing", confidence: 0.93)
    ...> })
    iex> unsure = ALLM.ClassificationResponse.new(answers: %{
    ...>   "department" => ALLM.ClassificationAnswer.new(type: :choice, choice: "sales", confidence: 0.41)
    ...> })
    iex> {route.(sure), route.(unsure)}
    {{:auto_assign, "billing"}, {:needs_review, "sales"}}

A `:yes_no` answer has no `:confidence`, so route on `:yes_probability`
directly. The same threshold means different things on different model
versions — which is the reason to pin one.

## Pinning the model

`jev-latest` is an alias that moves when TypeSafe ships a new version.
When you tune thresholds against a model's probabilities, pin a versioned
id so the numbers your thresholds were tuned on stay the numbers you get:

```elixir
engine =
  ALLM.Engine.new(
    classification_adapter: ALLM.Providers.TypeSafe.Classification,
    classification_model: "jev-1.13.0"
  )
```

`response.model` reports the versioned id that actually answered, even
when you sent the alias, so it is worth logging next to the decision it
drove. When you pass the state string, a per-call `model:` opt overrides
the engine's slot model for one call. A request built with
`ALLM.classification_request/2` is sent as-is: its own `:model` wins and a
`model:` opt passed to `classify/3` is ignored.

## One call, many questions

Put every question you have about a piece of state into **one** request.
Each question is answered independently against the same state, in the
same call, so there is nothing to gain from splitting them — and every
extra call re-sends, and re-bills, the whole state. TypeSafe's own guidance
is that batching every question into one call is several times cheaper and
faster than one call per question.

The façade therefore does not chunk questions and enforces no question
count. TypeSafe documents no question cap either; the practical limit is
its per-request token budget (documented: 64k tokens per request, 32k for
the state plus the longest question). A request over it comes back as
`:context_length_exceeded`. In ALLM's own recording, requests of 1, 32,
128 and 512 short questions were all accepted.

## Validation and errors

`ALLM.classify/3` validates the request before dispatch, and reports every
problem at once rather than the first:

    iex> engine = ALLM.Engine.new(classification_adapter: ALLM.Providers.FakeClassification)
    iex> {:error, error} = ALLM.classify(engine, "", questions: %{})
    iex> error.reason
    :invalid_classification_request
    iex> error.errors
    [questions: :empty, state: :empty]

A malformed question names its own id in the error path:

    iex> engine = ALLM.Engine.new(classification_adapter: ALLM.Providers.FakeClassification)
    iex> one_level = ALLM.ClassificationQuestion.score("How urgent?", ["whenever"])
    iex> {:error, error} = ALLM.classify(engine, "Not urgent.", questions: %{"urgency" => one_level})
    iex> error.errors
    [{[:questions, "urgency", :criteria], :too_few_levels}]

Adapter failures come back as `%ALLM.Error.ClassificationAdapterError{}`
with a closed reason enum — `:authentication_failed`, `:rate_limited`,
`:invalid_request`, `:context_length_exceeded`, `:provider_unavailable`,
`:timeout`, `:network_error`, `:malformed_response`, `:unknown`.
`:rate_limited`, `:provider_unavailable`, `:timeout` and `:network_error`
are retried under the engine's `:retry` policy, so a retried call is
invisible from the call site when a later attempt succeeds:

    iex> engine = ALLM.Engine.new(
    ...>   classification_adapter: ALLM.Providers.FakeClassification,
    ...>   adapter_opts: [classification_script: [{:retry_until_call, 2}, {:answers, %{"refund" => 0.75}}]],
    ...>   retry: [base_delay_ms: 1, jitter_ms: 0]
    ...> )
    iex> q = ALLM.ClassificationQuestion.yes_no("Is a refund being requested?")
    iex> {:ok, response} = ALLM.classify(engine, "Refund please.", questions: %{"refund" => q})
    iex> ALLM.ClassificationResponse.answer(response, "refund").yes_probability
    0.75

Every other reason surfaces immediately:

    iex> engine = ALLM.Engine.new(
    ...>   classification_adapter: ALLM.Providers.FakeClassification,
    ...>   adapter_opts: [classification_script: [
    ...>     {:error, %ALLM.Error.ClassificationAdapterError{reason: :invalid_request}}
    ...>   ]]
    ...> )
    iex> q = ALLM.ClassificationQuestion.yes_no("Is a refund being requested?")
    iex> {:error, error} = ALLM.classify(engine, "Refund please.", questions: %{"refund" => q})
    iex> error.reason
    :invalid_request

A missing API key is **raised**, not returned:
`%ALLM.Error.EngineError{reason: :missing_key}`, as on every other façade.
A `case` matching `{:error, _}` does not catch it.

### What TypeSafe sends back

The TypeSafe adapter makes one HTTP attempt per call — the façade's retry
is the only loop — and maps statuses as below. "Observed" rows were seen
on the live API when the adapter was recorded (2026-09-27); "documented"
rows come from TypeSafe's published error table.

| Situation | Status | Reason | Source |
|---|---|---|---|
| Unknown question type, unknown model, over a limit (more than 255 options or 10 levels) | 400 | `:invalid_request` | observed |
| A body that fails schema validation (for example an empty `questions` object) | 422 | `:invalid_request` | observed |
| State plus longest question over the token budget | 400, with `detail.error_type` `"max_tokens_exceeded"` | `:context_length_exceeded` | observed |
| Bad or revoked key | 401 | `:authentication_failed` | observed |
| Rate limited | 429 | `:rate_limited` | documented |
| Overloaded | 529 | `:provider_unavailable` | documented |
| 500, 502, 503, 504 | — | `:provider_unavailable` | inferred (mapped the same way; not observed) |

The adapter rejects the two limit breaches and an empty `questions` map
itself, before any HTTP call and before it looks for a key, so they never
cost a request.

Every TypeSafe response observed so far, success and error alike, carried
an `x-typesafe-request-id` header. It lands on
`ClassificationResponse.id` for a success and on the error's
`metadata.typesafe_request_id` for a failure — it is what TypeSafe support
asks for. An error's `:metadata` also carries `status` and, when the body
has one, `typesafe_error_type`; a transport failure adds
`transport_reason`. `:cause` is always `nil`, so every error encodes with
`Jason.encode!/1`.

One more observed behaviour: TypeSafe **ignores unknown fields** in a
request. The recorded probe showed it for a field on a question; one
exploratory call, not recorded, showed the same for a top-level field.
A misspelled field is dropped
without an error, so "the API accepted it" is not evidence the field did
anything.

## Telemetry

`ALLM.classify/3` emits `[:allm, :classify, :start | :stop | :exception]`.

`:start` and `:stop` metadata carry `request_id`, `engine`, `model` (the
classification slot's model, `nil` when the adapter's default will apply)
and `question_count`. `:stop` adds the `answer_count` measurement (`0` on
error) and `usage` in metadata (`nil` on error), so a metrics handler
written against another capability span does not `KeyError` here.

```elixir
:telemetry.attach_many(
  "classification-metrics",
  [[:allm, :classify, :stop], [:allm, :classify, :exception]],
  fn
    [:allm, :classify, :stop], measurements, metadata, _config ->
      MyApp.Metrics.timing("classify.duration", measurements.duration, tags: [metadata.model])
      MyApp.Metrics.count("classify.answers", measurements.answer_count)

    [:allm, :classify, :exception], _measurements, metadata, _config ->
      MyApp.Metrics.count("classify.exceptions", 1, tags: [metadata.kind])
  end,
  nil
)
```

Attach `:exception` too: a missing key raises, which emits `:exception`
*instead of* `:stop`.

Usage is populated — `input_tokens` and `output_tokens` from the provider,
`total_tokens` their sum — but the cost fields stay `nil`. TypeSafe
charges per input token (documented: output tokens are free), so a caller
who knows the rate can compute the cost from `usage.input_tokens`.

## Serializable by design

Every classification type is Layer A data — plain structs that round-trip
through `:erlang.term_to_binary/1` and JSON, with no PIDs, refs, funs or
key material. A request can be persisted next to the record it judged and
replayed later:

    iex> q = ALLM.ClassificationQuestion.choice("Which team?", ["billing", "technical"])
    iex> request = ALLM.classification_request("My card was declined.", questions: %{"team" => q}, model: "jev-1.13.0")
    iex> json = ALLM.Serializer.to_json!(request)
    iex> ALLM.Serializer.from_json(json) == {:ok, request}
    true

A map state with atom keys is sent with string keys, and comes back from a
JSON round trip with string keys — use string keys if the round trip must
be exact.

## Testing

`ALLM.Providers.FakeClassification` implements `ALLM.ClassificationAdapter`
with scripted answers. It ships in `lib/`, not `test/support/`, so your
application tests can use it.

With **no script**, every question gets a deterministic default: a choice
picks the lexicographically first option with probability `1.0`, a score
answers level `0`, and a yes/no answers `0.0`:

    iex> engine = ALLM.Engine.new(classification_adapter: ALLM.Providers.FakeClassification)
    iex> q = ALLM.ClassificationQuestion.choice("Which team?", ["technical", "billing"])
    iex> {:ok, response} = ALLM.classify(engine, "My card was charged twice.", questions: %{"team" => q})
    iex> answer = ALLM.ClassificationResponse.answer(response, "team")
    iex> {answer.choice, answer.probabilities}
    {"billing", %{"billing" => 1.0, "technical" => 0.0}}

The script grammar:

| Entry | Effect |
|---|---|
| `{:answers, %{id => value}}` | overrides the answer for each listed id; unlisted ids get their default. A string is a choice's option; a number is a score's position or a yes/no's probability; an `%ALLM.ClassificationAnswer{}` is used verbatim |
| `{:error, %ALLM.Error.ClassificationAdapterError{}}` | returns that error |
| `{:retry_until_call, n}` | a synthetic `:rate_limited` error for the first `n - 1` calls, then advances — the vehicle for exercising retries |

A scripted value that does not fit its question — a string for a score, a
choice that is not one of the options, a number out of range, an id that
is not in the request — raises `ArgumentError`, because it is a mistake in
the test rather than an answer.

**The Fake's confidence is its own convention**, not any provider's
formula: a choice reports `1.0`, and a fractional score reports the larger
of its two level probabilities. Do not tune thresholds against it.

Two behaviours to know before you script a *sequence*:

* **A non-empty script that runs off the end is an error**, not a fallback
  to the defaults — `reason: :unknown` with
  `metadata.cause: :classification_script_exhausted`. A test scripting N
  entries must expect exactly N calls.
* **The cursor keys on engine identity** when you go through the façade,
  so two engines built with content-equal scripts each start at the first
  entry, even in the same `async: true` test process.

`ALLM.ClassificationAdapter` is a public behaviour, and
`ALLM.Test.ClassificationAdapterConformance` (in the `allm_conformance`
package) is the suite to certify a third-party adapter against. A green
conformance run drives the Fake for any adapter that hands scripted calls
to it, so it is not evidence that a provider's response decoder is correct
— that needs decoder tests over recorded responses.

## Where to next

* `errors_and_retries.md` — the retry policy and the error structs.
* `fakes.md` — every capability Fake and its script key.
* `moderation.md` — the other screening-style capability: a provider's
  own safety policy, rather than your questions.
