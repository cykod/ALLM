# Content moderation

Moderation screens content for policy violations *before* you spend a chat
call on it — or before you publish what a model just wrote. ALLM exposes it
as a non-streaming primitive parallel to chat, images, and embeddings:
`%ALLM.ModerationRequest{}` and `%ALLM.ModerationResponse{}` mirror the
`Request`/`Response` shape, the engine has its own `:moderation_adapter`
slot, and one entry point — `ALLM.moderate/3` — covers it.

ALLM already models the *reactive* half of this: `:content_filter` is an
`ALLM.Response` finish reason, so you learn a generation was blocked after
paying for it. Moderation is the proactive half.

**The library does not decide what "unsafe" means.** It returns the
provider's own `flagged` boolean and the provider's per-category score map.
There is no default threshold, no `block?/2`, and no policy DSL. Where the
line sits varies by jurisdiction, audience, and appetite; a library default
would be quietly wrong for most callers and would read as an endorsement.

## The moderation-adapter engine slot

An engine can carry four independent adapter slots: `:adapter` for chat,
`:image_adapter` for images, `:embed_adapter` for embeddings, and
`:moderation_adapter` for this. They are peers — none falls back to another
— so one engine can mix providers.

The **model** is not a peer: `%ALLM.Engine{}` has one `:model` field shared
by every slot. An engine that mixes capabilities therefore sets the chat
model on the engine and passes the moderation model per call, because a chat
model id and a moderation model id are never interchangeable:

```elixir
engine =
  ALLM.Engine.new(
    adapter: ALLM.Providers.Anthropic,                      # chat
    moderation_adapter: ALLM.Providers.OpenAI.Moderation,   # moderation
    model: "claude-sonnet-4-6"                              # the CHAT model
  )

{:ok, verdict} = ALLM.moderate(engine, user_text, model: "omni-moderation-latest")
```

If you would rather not think about it, build two engines — one per
capability — and give each the model it actually uses.

Calling `ALLM.moderate/3` on an engine with no `:moderation_adapter` returns
an engine error before anything else runs, so a misconfigured engine never
surfaces as a request problem:

    iex> {:error, error} = ALLM.moderate(ALLM.Engine.new(), "is this ok?")
    iex> error.reason
    :no_moderation_adapter

Keys resolve at call time through `ALLM.Keys`, never from the engine, so a
serialized engine stays safe to persist. Mixing providers means both
providers' keys have to be resolvable.

## A first call

`ALLM.moderate/3` takes a string, a list of items, or a pre-built
`%ALLM.ModerationRequest{}`. The examples below use
`ALLM.Providers.FakeModeration` so they run with no network and no key —
see "Testing" at the end for the full scripting grammar.

    iex> engine = ALLM.Engine.new(
    ...>   moderation_adapter: ALLM.Providers.FakeModeration,
    ...>   adapter_opts: [moderation_script: [{:flagged, ["violence"]}]]
    ...> )
    iex> {:ok, response} = ALLM.moderate(engine, "…user text…")
    iex> ALLM.ModerationResponse.flagged?(response)
    true
    iex> ALLM.ModerationResponse.flagged_categories(response)
    ["violence"]

`ALLM.ModerationResponse.flagged?/1` is the 95% question — "did anything in
this call trip the provider's own policy?" — and it is true when *any*
result is flagged. `ALLM.ModerationResponse.flagged_categories/1` is the
union of the category names across every flagged result, sorted, so it
answers "which policies" without you walking the list.

Against the real provider the same call is:

```elixir
engine =
  ALLM.Engine.new(
    moderation_adapter: ALLM.Providers.OpenAI.Moderation,
    model: "omni-moderation-latest"
  )

{:ok, response} = ALLM.moderate(engine, user_text)
```

A clean verdict looks like this — one result per input string, in input
order:

    iex> engine = ALLM.Engine.new(moderation_adapter: ALLM.Providers.FakeModeration)
    iex> {:ok, response} = ALLM.moderate(engine, ["a kestrel", "a cedar branch"])
    iex> length(response.results)
    2
    iex> Enum.map(response.results, & &1.index)
    [0, 1]
    iex> ALLM.ModerationResponse.flagged?(response)
    false

`:index` is always an integer, never `nil`, so
`Enum.at(response.results, i)` is the verdict for `Enum.at(input, i)` — for
an all-strings input. Images change that rule; see "Moderating images".

## `flagged?/1` versus your own threshold

`:flagged` is the provider's verdict under the provider's own policy. It is
normalized across providers in the sense that it is always a boolean, and
that is the *only* thing ALLM normalizes.

`ALLM.ModerationResult.category_scores` carries the raw per-category floats,
**string-keyed and provider-shaped**. The keys are the provider's own names
(`"violence"`, `"self-harm/intent"`, `"harassment/threatening"` — thirteen
of them on `omni-moderation`), passed through untouched. They are not atoms
on purpose: a provider-controlled key set converted to atoms grows the atom
table on whatever the provider ships next, and a normalized cross-provider
taxonomy would need a second provider to be normalized *against*.

The practical consequence: reading `scores["violence"]` is writing
provider-specific code, and the compiler will not catch a typo. Use
`ALLM.ModerationResult.score/2`, which returns `nil` rather than raising for
a category the provider did not report:

    iex> result = ALLM.ModerationResult.new(
    ...>   flagged: false,
    ...>   category_scores: %{"violence" => 0.42, "hate" => 0.01},
    ...>   index: 0
    ...> )
    iex> ALLM.ModerationResult.score(result, "violence")
    0.42
    iex> ALLM.ModerationResult.score(result, "self-harm")
    nil

A stricter-than-the-provider policy is then a fold over the scores. Here the
provider says "not flagged" and a 0.4 house threshold disagrees:

    iex> results = [
    ...>   ALLM.ModerationResult.new(
    ...>     flagged: false,
    ...>     category_scores: %{"violence" => 0.42, "hate" => 0.01},
    ...>     index: 0
    ...>   )
    ...> ]
    iex> engine = ALLM.Engine.new(
    ...>   moderation_adapter: ALLM.Providers.FakeModeration,
    ...>   adapter_opts: [moderation_script: [{:ok, results}]]
    ...> )
    iex> {:ok, response} = ALLM.moderate(engine, "borderline text")
    iex> ALLM.ModerationResponse.flagged?(response)
    false
    iex> [result] = response.results
    iex> result.category_scores
    ...> |> Enum.filter(fn {_category, score} -> score >= 0.4 end)
    ...> |> Enum.map(fn {category, _score} -> category end)
    ["violence"]

Which direction to lean is yours. A threshold *below* the provider's is a
stricter product; a threshold *above* it means shipping content the provider
already told you it would flag, which is a decision worth making
deliberately rather than by omission.

`ALLM.ModerationResult.flagged_categories/1` is the per-result counterpart
of the response-level function — the sorted names whose `:categories` value
is `true`.

## Batching: there is no transparent chunking

`ALLM.embed/3` chunks for you. `ALLM.moderate/3` deliberately does not, and
the divergence is not an oversight: one moderation call returns exactly one
provider `id` per HTTP request, so merging N chunks would produce N ids with
nowhere to put them, and the endpoint is free, so the cost pressure that
justifies chunking embeddings is absent.

Adapters still declare a per-request cap, and an over-long input comes back
as a `:batch_too_large` adapter error rather than a silent truncation. Read
the cap off the adapter instead of hard-coding it:

    iex> ALLM.Providers.OpenAI.Moderation.max_batch_size()
    1000
    iex> ALLM.Providers.FakeModeration.max_batch_size()
    32

The caller-side loop, for an **all-strings** input:

    iex> engine = ALLM.Engine.new(moderation_adapter: ALLM.Providers.FakeModeration)
    iex> cap = engine.moderation_adapter.max_batch_size()
    iex> inputs = Enum.map(1..70, &"item #{&1}")
    iex> chunks = Enum.chunk_every(inputs, cap)
    iex> Enum.map(chunks, &length/1)
    [32, 32, 6]
    iex> verdicts = Enum.map(chunks, fn chunk ->
    ...>   {:ok, response} = ALLM.moderate(engine, chunk)
    ...>   ALLM.ModerationResponse.flagged?(response)
    ...> end)
    iex> Enum.any?(verdicts)
    false

Chunking yourself is also what makes a bulk pass resumable: you own the
cursor, so a failure at chunk 40 of 50 costs you one chunk rather than the
whole run.

**Do not apply that loop to a multimodal input.** A list carrying an
`ALLM.ImagePart` is *one* item judged as a whole (next section), so there is
nothing to chunk — splitting it would sever an image from the text it
belongs to. Gate on `ALLM.ModerationRequest.multimodal?/1` if the shape is
not known statically.

## Moderating images

An `:input` list may carry `%ALLM.ImagePart{}` items alongside strings. The
cardinality rule then changes, and this is the one genuinely surprising
thing about the moderation wire — it is a property of the provider endpoint
rather than an ALLM choice:

* **all strings** — a batch of independent items, so
  `length(response.results) == length(request.input)`;
* **any image present** — the whole list is **one** multimodal item (text
  plus its images, judged together), so there is exactly **one** result, at
  `index: 0`, however long the list is.

`ALLM.ModerationRequest.multimodal?/1` reports which shape a request is in,
so the count is derivable *before* the call. Derive it, then read the actual
count off the response rather than assuming either number:

    iex> image = ALLM.Image.from_url("https://example.com/photo.png")
    iex> request = ALLM.moderation_request([
    ...>   "Is this photograph acceptable to publish?",
    ...>   %ALLM.ImagePart{image: image}
    ...> ])
    iex> ALLM.ModerationRequest.multimodal?(request)
    true
    iex> length(request.input)
    2
    iex> engine = ALLM.Engine.new(moderation_adapter: ALLM.Providers.FakeModeration)
    iex> {:ok, response} = ALLM.moderate(engine, request)
    iex> length(response.results)
    1
    iex> hd(response.results).index
    0

Two elements in, one result out. That is the rule, not a Fake artifact — it
is how the live endpoint answers, and ALLM's own recorded wire fixture for a
two-block input carries exactly one result.

`ALLM.ModerationResult.applied_input_types` is the per-category map saying
which *parts* of a multimodal input triggered each category
(`%{"violence" => ["image"]}`). It is the only signal distinguishing "the
image was classified and found clean" from "the image was ignored". It is
`%{}` when the provider does not report it — an empty map is the honest
representation of "not reported", not of "nothing applied".

Any `ALLM.Image` source works. A `{:url, _}` image forwards its URL
verbatim; every other source is inlined as a `data:` URI, which the endpoint
accepts, so a local file needs no image host:

```elixir
image =
  "priv/uploads/user_avatar.png"
  |> File.read!()
  |> ALLM.Image.from_binary("image/png")

{:ok, response} = ALLM.moderate(engine, ["profile photo", %ALLM.ImagePart{image: image}])
```

### `ALLM.ImagePart.detail` is dropped

`%ALLM.ImagePart{detail: :low | :high | :auto}` controls vision fidelity in
a *chat* message. The moderation endpoint documents no such control — its
published request shape carries no `detail` key — so the moderation adapter
drops the field rather than inventing an undocumented one, and logs a
one-per-process `Logger.debug/1` when you set it to anything but the default.

The wire cannot confirm this either way: `/v1/moderations` returns 200 for
unknown fields and silently ignores them, so sending `detail` and getting a
200 would prove nothing about whether it was honoured. What holds the
behaviour in place is a contract test in ALLM's own suite asserting that no
`detail` key is emitted, at any `:detail` value, for either image source.

That same permissiveness is worth knowing about generally: an unrecognised
`ALLM.ModerationRequest.options` key is dropped by the provider rather than
rejected, so you get a normal verdict and no signal that the knob did
nothing.

## Provider coverage

| | OpenAI |
|---|---|
| Adapter | `ALLM.Providers.OpenAI.Moderation` |
| Endpoint | `POST /v1/moderations` |
| Example model | `omni-moderation-latest` |
| Key env var | `OPENAI_API_KEY` |
| Inputs per request | `max_batch_size/0` — 1000, a demonstrated floor from a live ladder rather than a provider-stated cap |
| Image input | yes |
| Categories reported | 13, string-keyed |
| Per-category scores | yes |
| `applied_input_types` | yes |
| Token counts / cost | none — the endpoint is free |

One column is not an omission, and it is not a gap waiting to be
backfilled. Moderation is a single-provider capability today:

* **Anthropic** ships no moderation endpoint, and names no partner for one.
  There is no honest module to write. (Contrast embeddings, where Anthropic
  publicly recommends Voyage AI and ALLM bundles a Voyage adapter for
  exactly that reason.)
* **Google** exposes safety ratings *inline on `generateContent`* — four
  harm categories on an ordinal `NEGLIGIBLE | LOW | MEDIUM | HIGH` scale,
  attached to a generation call. That is a property of a generation, not a
  standalone classification endpoint, so it cannot implement
  `c:ALLM.ModerationAdapter.moderate/2` without inventing a generation call
  to attach itself to. Surfacing those ratings belongs on the chat
  response's metadata, not here.

`ALLM.ModerationAdapter` is a public behaviour, so a third-party or
in-house adapter is a first-class option, and
`ALLM.Test.ModerationAdapterConformance` (in the `allm_conformance` package)
is the published suite to certify it against.

### About `text-moderation-*`

OpenAI's `text-moderation-latest`, `text-moderation-stable`, and
`text-moderation-007` were **shut down on 2025-10-27**, with
`omni-moderation` as the stated replacement. The adapter targets
`omni-moderation-latest` and `omni-moderation-2024-09-26`.

It does not maintain a denylist: whatever `:model` you set is forwarded, and
a shut-down name comes back as the provider's own 400 (`:invalid_request`),
which is a clearer and more current error than a hard-coded list that goes
stale the moment a new model ships. A `nil` model is omitted from the wire
entirely, letting OpenAI apply its own current default rather than pinning a
name ALLM would have to chase.

## Validation and errors

Unlike `ALLM.generate_image/3` and like `ALLM.embed/3`, this façade runs
`ALLM.Validate.moderation_request/1` before dispatch — an empty `:input`
list and an empty-string item are both guaranteed provider rejections and
should fail before the round-trip:

    iex> engine = ALLM.Engine.new(moderation_adapter: ALLM.Providers.FakeModeration)
    iex> {:error, error} = ALLM.moderate(engine, ["fine", ""])
    iex> error.reason
    :invalid_moderation_request
    iex> error.errors
    [{[:input, 1], :empty}]

`:errors` is the exhaustive `{path, atom}` list, not the first failure, so
one round-trip tells you everything wrong with the request.

Adapter failures come back as `%ALLM.Error.ModerationAdapterError{}` with a
closed reason enum — `:authentication_failed`, `:rate_limited`,
`:invalid_request`, `:context_length_exceeded`, `:provider_unavailable`,
`:timeout`, `:network_error`, `:malformed_response`, `:unsupported_feature`,
`:batch_too_large`, `:unknown`:

    iex> engine = ALLM.Engine.new(
    ...>   moderation_adapter: ALLM.Providers.FakeModeration,
    ...>   adapter_opts: [
    ...>     moderation_script: [
    ...>       {:error, %ALLM.Error.ModerationAdapterError{reason: :invalid_request}}
    ...>     ]
    ...>   ]
    ...> )
    iex> {:error, error} = ALLM.moderate(engine, "hello")
    iex> error.reason
    :invalid_request

`:rate_limited`, `:provider_unavailable`, `:timeout`, and `:network_error`
are retried under the engine's `:retry` policy; every other reason surfaces
immediately. One caveat inherited from `ALLM.embed/3`: `opts[:retry]` is
also forwarded to the adapter, so an adapter running its own retry loop
nests inside the façade's and the two budgets **multiply** for any reason
both loops treat as retryable. See `guides/errors_and_retries.md`.

## Telemetry

`ALLM.moderate/3` emits `[:allm, :moderate, :start | :stop | :exception]`.

`:stop` carries `result_count` and `flagged_count` measurements on both the
success and the error path (`0` each on error), plus `usage: nil` in
metadata even though `%ALLM.ModerationResponse{}` has **no `:usage` field** —
the endpoint is free and reports none. The key is present anyway so a
metrics handler written against the embeddings or image span does not
`KeyError` when pointed at this one.

`:start` and `:stop` metadata carry `input_count` and `multimodal`.
`input_count` is the **raw element count**, not the provider's *item* count,
which is `1` whenever `multimodal` is `true`. The two agree exactly for an
all-strings input, and `multimodal` rides alongside so a consumer derives
the item count without a second measurement.

```elixir
:telemetry.attach(
  "moderation-metrics",
  [:allm, :moderate, :stop],
  fn _event, measurements, metadata, _config ->
    MyApp.Metrics.count("moderation.flagged", measurements.flagged_count)
    MyApp.Metrics.count("moderation.results", measurements.result_count)
    MyApp.Metrics.timing("moderation.duration", measurements.duration, tags: [metadata.model])
  end,
  nil
)
```

A `:start`/`:stop`-only attachment leaves an unterminated span whenever a
key is missing: `ALLM.Keys.fetch!/2` raises by design, which emits
`:exception` *instead of* `:stop`. Attach all three.

**Operator note.** `:stop` metadata carries `response:`, and a moderation
response's `:raw` is the provider body. The submitted text is not echoed
there by the bundled adapter's provider, but a handler that serializes the
whole metadata map to an external backend is still exporting moderation
verdicts about your users to that vendor. Same shape of exposure the
embeddings and image spans already carry; it needs explicit operator opt-in.

## Screening before you generate

The point of a proactive check is to spend the moderation call — which is
free — instead of the generation call, which is not:

    iex> defmodule ModerationGuide.Screen do
    ...>   def reply(engine, user_text) do
    ...>     with {:ok, verdict} <- ALLM.moderate(engine, user_text),
    ...>          {false, _verdict} <- {ALLM.ModerationResponse.flagged?(verdict), verdict} do
    ...>       ALLM.generate(engine, ALLM.request([%ALLM.Message{role: :user, content: user_text}]))
    ...>     else
    ...>       {true, verdict} -> {:error, {:rejected, ALLM.ModerationResponse.flagged_categories(verdict)}}
    ...>       {:error, _} = error -> error
    ...>     end
    ...>   end
    ...> end
    iex> clean = ALLM.Engine.new(
    ...>   adapter: ALLM.Providers.Fake,
    ...>   moderation_adapter: ALLM.Providers.FakeModeration,
    ...>   adapter_opts: [script: [{:text, "a kestrel is a small falcon"}, {:finish, :stop}]]
    ...> )
    iex> {:ok, response} = ModerationGuide.Screen.reply(clean, "tell me about kestrels")
    iex> response.output_text
    "a kestrel is a small falcon"
    iex> blocked = ALLM.Engine.new(
    ...>   adapter: ALLM.Providers.Fake,
    ...>   moderation_adapter: ALLM.Providers.FakeModeration,
    ...>   adapter_opts: [moderation_script: [{:flagged, ["violence"]}]]
    ...> )
    iex> ModerationGuide.Screen.reply(blocked, "…user text…")
    {:error, {:rejected, ["violence"]}}
    iex> {:error, error} = ModerationGuide.Screen.reply(ALLM.Engine.new(), "is this ok?")
    iex> error.reason
    :no_moderation_adapter

ALLM does **not** wire this into `ALLM.chat/3` or `ALLM.generate/3` for you.
An automatic second HTTP call per turn would double latency and silently
change those functions' error unions; whether to screen, and what to do
about a flag, is an application decision. The same call screens model
*output* — it is the same function with a different string.

Note the tuple in the second `with` clause. Variables bound in a `with`
clause are **not** in scope inside `else` — the `else` block sees only the
value that failed to match, exactly like a `case`. Matching on
`{ALLM.ModerationResponse.flagged?(verdict), verdict}` is what carries the
verdict across that boundary, so the `{true, verdict}` branch can name the
categories it rejected. Writing the clause as the bare
`false <- ALLM.ModerationResponse.flagged?(verdict)` and then reaching for
`verdict` in `else` is a `CompileError`, not a warning.

## Serializable by design

Every moderation type is Layer A — plain structs that round-trip through
both `:erlang.term_to_binary/1` and JSON, with no PIDs, refs, funs, or key
material. A verdict can be persisted alongside the content it judged and
replayed later:

    iex> request = ALLM.moderation_request(["is this ok?"], model: "omni-moderation-latest")
    iex> json = ALLM.Serializer.to_json!(request)
    iex> ALLM.Serializer.from_json(json) == {:ok, request}
    true

One decoder in this family **repairs** rather than passes through: on the
JSON path, a `"flagged"` that is not a boolean — absent, `null`, the string
`"true"`, a truncated or tampered payload — deserializes to `false`. The
struct's declared `t:boolean/0` is preserved rather than admitting a `nil`,
and a decode glitch cannot manufacture a `true` that blocks legitimate
content. The repair is **silent**, though: `:categories` and
`:category_scores` are decoded independently of `:flagged`, so a tampered
payload — or one carrying the string `"true"` — comes back `flagged: false`
next to a fully populated category map, with nothing in the struct marking
it as repaired. Only a payload truncated so badly that all three keys are
missing arrives with the category maps empty, and that is the absence of
data rather than a signal about the repair. A caller who needs to detect a
corrupted verdict has to validate the payload before decoding, or compare
`:flagged` against the `:categories` map itself. ETF round-trips are
lossless and preserve the off-contract value, so the two paths are not
interchangeable for a malformed verdict.

## Testing

`ALLM.Providers.FakeModeration` implements `ALLM.ModerationAdapter` with
scripted responses. It ships in `lib/`, not `test/support/`, because
downstream applications need it for their own tests — same arrangement as
`ALLM.Providers.Fake` and `ALLM.Providers.FakeEmbeddings`.

With **no script**, every call returns one unflagged result per item
carrying all 13 `omni-moderation` category names at score `0.0`. A clean
verdict is a meaningful default that costs a caller nothing, so unlike
`ALLM.Providers.FakeEmbeddings` the no-script call is a success rather than
an error.

The script grammar:

| Entry | Effect |
|---|---|
| `{:ok, results}` | returns those `%ALLM.ModerationResult{}` structs verbatim — the entry decides the result count, not `length(input)` |
| `{:flagged, categories}` | synthesizes one flagged result with those names `true` at `1.0` and every other category `false` at `0.0` |
| `{:error, %ALLM.Error.ModerationAdapterError{}}` | returns that error |
| `{:retry_until_call, n}` | a synthetic `:rate_limited` error for the first `n - 1` calls, then advances — the vehicle for exercising retry integration |

`{:flagged, categories}` is the shorthand for the overwhelmingly common
test, "assert my app rejects flagged content":

    iex> engine = ALLM.Engine.new(
    ...>   moderation_adapter: ALLM.Providers.FakeModeration,
    ...>   adapter_opts: [moderation_script: [{:flagged, ["hate", "harassment"]}]]
    ...> )
    iex> {:ok, response} = ALLM.moderate(engine, "…")
    iex> ALLM.ModerationResponse.flagged_categories(response)
    ["harassment", "hate"]
    iex> [result] = response.results
    iex> ALLM.ModerationResult.score(result, "hate")
    1.0
    iex> ALLM.ModerationResult.score(result, "violence")
    0.0

Two behaviours to know before you script a *sequence*:

* **A non-empty script that runs off the end is an error**, not a fallback
  to the clean verdict — `reason: :unknown` with
  `metadata.cause: :moderation_script_exhausted`. "I scripted nothing, give
  me a benign default" is a convenience; "my script ran out" is almost
  always an off-by-one in your expectation of how many times the adapter
  gets called, and answering it with an unflagged pass would hide that.
  A test scripting N entries must expect exactly N calls.
* **The cursor keys on engine identity** when you go through the façade, so
  two engines built with content-equal scripts each start at index 0 — even
  in the same `async: true` test process. Direct adapter calls (no engine)
  fall back to a content hash and *do* share a cursor; pass distinct
  `adapter_opts[:script_cursor]` agents if you need that path isolated.

`adapter_opts[:capture_pid]` gives you a side-channel message on every call,
before any gate runs, so you can assert on what the adapter received without
registering a named process:

<!-- fence-check: skip — an ExUnit test body: `assert_receive/1` and `assert/1` need a `use ExUnit.Case` module around them -->
```elixir
engine =
  ALLM.Engine.new(
    moderation_adapter: ALLM.Providers.FakeModeration,
    adapter_opts: [capture_pid: self()]
  )

{:ok, _} = ALLM.moderate(engine, "check me")

assert_receive {ALLM.Providers.FakeModeration, :call, %{request: request}}
assert request.input == ["check me"]
```

See `guides/fakes.md` for the wider Fake-adapter patterns, and
`guides/errors_and_retries.md` for the retry policy this capability shares
with the rest of the library.
