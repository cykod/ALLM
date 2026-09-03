# Embeddings

Embeddings turn text into vectors. ALLM exposes them as a
non-streaming primitive parallel to chat and image generation:
`%ALLM.EmbeddingRequest{}` and `%ALLM.EmbeddingResponse{}` mirror the
`Request`/`Response` shape, the engine has its own `:embed_adapter`
slot, and one entry point — `ALLM.embed/3` — covers every provider.

The output is plain `[[float()]]`, ready to insert into a `pgvector`
column. ALLM does not depend on `Ecto`, `Postgrex`, or `pgvector`, and
ships no repo or migration helpers; the storage half is yours, and this
guide shows the shape it usually takes.

## The embed-adapter engine slot

An engine can carry three independent adapter slots: `:adapter` for
chat, `:image_adapter` for images, and `:embed_adapter` for embeddings.
They are peers — none falls back to another — so a single engine can mix
providers.

The **model** is not a peer, though: `%ALLM.Engine{}` has one `:model`
field shared by all three slots. An engine that mixes providers therefore
sets the chat model on the engine and passes the embedding model per
call, because a chat model id and an embedding model id are never
interchangeable:

```elixir
engine =
  ALLM.Engine.new(
    adapter: ALLM.Providers.Anthropic,               # chat
    embed_adapter: ALLM.Providers.Voyage.Embeddings, # embeddings
    model: "claude-sonnet-4-6"                       # the CHAT model
  )

{:ok, response} = ALLM.embed(engine, chunks, model: "voyage-3.5-lite")
```

`ALLM.embed/3`'s `:model` option overrides `engine.model` for that call
only. If you would rather not think about it, build two engines — one per
capability — and give each the model it actually uses.

Calling `ALLM.embed/3` on an engine with no `:embed_adapter` returns
`{:error, %ALLM.Error.EngineError{reason: :no_embed_adapter}}` before
anything else runs — a misconfigured engine never surfaces as a request
problem.

Keys resolve at call time through `ALLM.Keys`, never from the engine, so
a serialized engine stays safe to persist. Mixing providers means both
providers' keys have to be resolvable.

## A first call

`ALLM.embed/3` takes a string, a list of strings, or a pre-built
`%ALLM.EmbeddingRequest{}`. The examples below use
`ALLM.Providers.FakeEmbeddings` so they run with no network and no key.

    iex> vectors = [
    ...>   ALLM.Embedding.new(vector: [0.1, 0.2, 0.3], index: 0),
    ...>   ALLM.Embedding.new(vector: [0.4, 0.5, 0.6], index: 1)
    ...> ]
    iex> engine = ALLM.Engine.new(
    ...>   embed_adapter: ALLM.Providers.FakeEmbeddings,
    ...>   adapter_opts: [embedding_script: [{:ok, vectors}]]
    ...> )
    iex> {:ok, response} = ALLM.embed(engine, ["a kestrel", "a cedar branch"])
    iex> ALLM.EmbeddingResponse.vectors(response)
    [[0.1, 0.2, 0.3], [0.4, 0.5, 0.6]]
    iex> ALLM.EmbeddingResponse.dimensions(response)
    3

`ALLM.EmbeddingResponse.vectors/1` sorts by each embedding's `:index`
before flattening, so `Enum.at(vectors, i)` is always the vector for
`Enum.at(input, i)` — whatever order the provider returned items in, and
however many HTTP requests the call became.

`ALLM.EmbeddingResponse.dimensions/1` returns the width of the first
vector, which is what you size a `vector(N)` column with.

Against a real provider the same call is:

```elixir
engine =
  ALLM.Engine.new(
    embed_adapter: ALLM.Providers.OpenAI.Embeddings,
    model: "text-embedding-3-small"
  )

{:ok, response} = ALLM.embed(engine, ["a kestrel", "a cedar branch"])
```

## Provider coverage

| | OpenAI | Gemini | Voyage |
|---|---|---|---|
| Adapter | `ALLM.Providers.OpenAI.Embeddings` | `ALLM.Providers.Gemini.Embeddings` | `ALLM.Providers.Voyage.Embeddings` |
| Example model | `text-embedding-3-small` | `gemini-embedding-001` | `voyage-3.5-lite` |
| Key env var | `OPENAI_API_KEY` | `GEMINI_API_KEY` | `VOYAGE_API_KEY` |
| Inputs per request | 2048 | 100 | 1000 |
| `:dimensions` | yes (`text-embedding-3` and later) | yes | yes, on supporting models |
| `:task_type` | ignored | full five-way support | query/document only |
| `:truncate` | ignored (over-length input is an error) | supported | supported |
| Token counts on the response | `input_tokens` + `total_tokens` | **none reported** | `total_tokens` only |

Read the per-request cap off the adapter rather than hard-coding it:

    iex> ALLM.Providers.OpenAI.Embeddings.max_batch_size()
    2048
    iex> ALLM.Providers.Gemini.Embeddings.max_batch_size()
    100
    iex> ALLM.Providers.Voyage.Embeddings.max_batch_size()
    1000

You do not need to respect that cap for a normal `ALLM.embed/3` call —
the façade chunks for you (see "Batching" below). It matters when you
chunk yourself, which is the recipe for resumability and for bounding
the time a bulk ingest can take.

### Anthropic applications use Voyage

Anthropic ships no embeddings endpoint. It never has, and there is
deliberately no `ALLM.Providers.Anthropic.Embeddings` module — that name
would assert a wire that does not exist. Anthropic instead names Voyage
AI as its recommended embeddings partner, so `ALLM.Providers.Voyage.Embeddings`
is what an Anthropic-stack application uses:

```elixir
engine =
  ALLM.Engine.new(
    adapter: ALLM.Providers.Anthropic,
    model: "claude-sonnet-4-6",
    embed_adapter: ALLM.Providers.Voyage.Embeddings
  )

{:ok, response} = ALLM.embed(engine, chunks, model: "voyage-3.5-lite")
```

The key comes from `VOYAGE_API_KEY`, not `ANTHROPIC_API_KEY`. Nothing
about the adapter is Anthropic-specific beyond that recommendation: use
it with any stack, or point an Anthropic-stack engine at OpenAI or
Gemini instead. The pairing is a default, not a coupling.

## Task types: encode queries differently from documents

Retrieval quality improves measurably when the query and the stored
documents are embedded with different instructions. `:task_type` is a
provider-neutral closed enum:

| `:task_type` | Use for |
|---|---|
| `:search_document` | text you are storing and will search over |
| `:search_query` | the user's search string at query time |
| `:classification` | features for a downstream classifier |
| `:clustering` | features for clustering / topic discovery |
| `:similarity` | symmetric "how alike are these two texts" |

    iex> request = ALLM.embedding_request("kestrel nesting habits", task_type: :search_query)
    iex> request.task_type
    :search_query

Provider behaviour differs, and the differences are silent by design —
an unsupported task type is dropped, never an error:

* **Gemini** supports all five and maps them onto its `taskType` enum.
* **Voyage** has only `"query"` and `"document"`. `:search_query` and
  `:search_document` map through; `:classification`, `:clustering`, and
  `:similarity` send no task type at all, which is the correct
  symmetric-task behaviour on that wire.
* **OpenAI** has no equivalent. The field is dropped and logged at
  `:debug`. If asymmetric embedding matters to you, pick another
  provider.

Whichever you choose, **be consistent**: documents embedded as
`:search_document` and queried with `:search_query` is the intended
pairing. Re-embedding an existing corpus under a different task type
changes the vectors.

## Dimensions and normalization

`:dimensions` requests a narrower vector, which costs less to store and
to compare. Not every model supports it, and per-model legal values
differ — an unsupported combination surfaces as a provider rejection.

```elixir
{:ok, response} = ALLM.embed(engine, chunks, dimensions: 512)
512 = ALLM.EmbeddingResponse.dimensions(response)
```

Vectors are unit-length in the common case, which is what cosine
distance and inner-product operators both assume. `ALLM.Embedding`
exposes the two primitives directly:

    iex> embedding = ALLM.Embedding.new(vector: [3.0, 4.0])
    iex> ALLM.Embedding.magnitude(embedding)
    5.0
    iex> ALLM.Embedding.normalize(embedding).vector
    [0.6, 0.8]

`normalize/1` returns a zero-magnitude vector unchanged rather than
producing `NaN`.

### Gemini normalizes truncated vectors in-adapter

One provider behaviour is worth knowing before you write a row:
**`ALLM.Providers.Gemini.Embeddings` L2-normalizes every response whose
`:dimensions` is set to anything other than `3072`.** Google returns
pre-normalized vectors at `gemini-embedding-001`'s native 3072 but not at
truncated ones — a raw 768-wide response measures about 0.585, not 1.0.

The rule is a single constant, not a per-model table, and it does not
branch on the model id: re-normalizing an already-unit vector is a no-op,
so the unconditional form is safe on models that self-normalize, correct
on the ones that do not, and does not go stale when the next model ships.
A model with a different native width would therefore be normalized at
its own native width too — deliberately, and harmlessly.

The consequence is that a `dimensions: 768` response from ALLM **differs
numerically from the same request issued with `curl`**. That is
deliberate. A table holding a mix of normalized and unnormalized vectors
is unrecoverable after the fact: cosine distance tolerates unnormalized
input, but inner-product operators silently return wrong rankings, and
nothing in the data tells you which rows are which. Normalizing in the
adapter makes every ALLM-produced vector unit-length regardless of
provider or model.

Requests that do not set `:dimensions` are passed through untouched.

## Batching

`ALLM.embed/3` accepts an input list of any length. Lists longer than the
adapter's `max_batch_size/0` are split, dispatched **sequentially**, and
merged back into one response with indices rebased across the chunk
boundaries, so the order-correspondence guarantee holds end to end.

```elixir
{:ok, response} = ALLM.embed(engine, Enum.map(1..5_000, &"chunk #{&1}"))

5_000 = length(response.embeddings)
response.metadata.chunk_count   # 3 on OpenAI, 50 on Gemini, 5 on Voyage
```

Sequential dispatch is deliberate: firing fifty chunks concurrently is
the fastest route to a rate-limit storm, and it bounds the call to one
in-flight request at a time.

Merging keeps the first chunk's `:raw` and sums every numeric usage
counter across chunks. A single-chunk call skips the merge entirely, so
`:raw` survives intact for the common case.

### Retry and time budgets are per chunk

There is no aggregate ceiling on a chunked call. Retry attempts,
`:request_timeout`, and backoff all apply **per chunk**, so for a
5,000-input batch against a 100-item cap:

| Budget | Scope | Worst case |
|---|---|---|
| Retry attempts (default 3) | per chunk | **150 HTTP requests** — but **450** when the failure is `:timeout`, see below |
| `:request_timeout` | per chunk | 50 × the value — 450 × when every attempt times out |
| Backoff under sustained rate limiting | per chunk | tens of minutes of wall clock |
| `[:allm, :embed]` span `duration` | whole call | one number for the entire batch |

**`:timeout` costs three times the attempts every other retryable reason
does.** There are two nested retry loops on the embed path: each adapter
runs one of its own with the default policy, and `ALLM.embed/3` wraps a
second, widened one around it. `:timeout` is the one reason that appears
in **both** `retry_on` lists, so the two budgets multiply — **9 HTTP
attempts per chunk** at the default policy, against 3 for
`:rate_limited`, `:provider_unavailable`, and `:network_error`, which
only the outer loop retries. A direct adapter `embed/2` call takes the
inner loop only and makes 3. So the 50-chunk row above is 150 requests
against a rate-limited provider and **450** against one that is timing
out.

If you need a real bound — a deadline, a progress bar, or resumability
after a failure — chunk the input yourself and wrap each call.

### Mid-batch failure and the resumable loop

A failing chunk fails the whole call. No partial vectors are returned;
the error is that chunk's own, with `metadata.completed_chunks` and
`metadata.completed_inputs` added so you can see how far it got.

For a bulk ingest you usually want to keep what succeeded. Chunk against
the adapter's own cap and persist as you go:

```elixir
defmodule Ingest do
  def run(engine, adapter, chunks, already_done \\ 0) do
    size = adapter.max_batch_size()

    chunks
    |> Enum.drop(already_done)
    |> Enum.chunk_every(size)
    |> Enum.reduce_while({:ok, already_done}, fn batch, {:ok, done} ->
      case ALLM.embed(engine, batch, task_type: :search_document, request_timeout: 30_000) do
        {:ok, response} ->
          store!(batch, ALLM.EmbeddingResponse.vectors(response))
          {:cont, {:ok, done + length(batch)}}

        {:error, error} ->
          # `done` is the resume point — re-run with `already_done: done`.
          {:halt, {:error, error, done}}
      end
    end)
  end

  # Replace with your own persistence — an `insert_all`, a `Repo.transaction`,
  # a file append. It is a stub here only so the module compiles as printed.
  defp store!(_batch, _vectors), do: :ok
end
```

The same loop is how you bound total time: each `ALLM.embed/3` call is
now one HTTP request, so its retry and timeout budgets are the whole
budget, and you decide between chunks whether to keep going.

## Storing vectors in pgvector

ALLM hands back `[[float()]]`, which is exactly what the
[`pgvector`](https://github.com/pgvector/pgvector) extension wants. The
integration is a few lines against your own repo.

**1. Enable the extension and size the column.** The width must match
the model — `ALLM.EmbeddingResponse.dimensions/1` tells you what you
actually got, which is the number to build the migration around:

```elixir
defmodule MyApp.Repo.Migrations.AddEmbeddings do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS vector"

    alter table(:documents) do
      # `vector(1536)` for text-embedding-3-small at its native width.
      add :embedding, :vector, size: 1536
    end

    execute """
    CREATE INDEX documents_embedding_idx
      ON documents
      USING hnsw (embedding vector_cosine_ops)
    """
  end

  def down do
    drop index(:documents, [:embedding], name: :documents_embedding_idx)

    alter table(:documents) do
      remove :embedding
    end
  end
end
```

Vectors from different models — or the same model at different
`:dimensions` — are not comparable, so one column means one model. Record
`response.model` alongside the vector if you expect to migrate later.

**2. Embed and insert.** Store the documents with
`task_type: :search_document`:

<!-- fence-check: skip — writes to `%MyApp.Document{}` through Ecto/Pgvector — neither is a dependency of this library -->
```elixir
{:ok, response} = ALLM.embed(engine, texts, task_type: :search_document)

texts
|> Enum.zip(ALLM.EmbeddingResponse.vectors(response))
|> Enum.each(fn {text, vector} ->
  MyApp.Repo.insert!(%MyApp.Document{body: text, embedding: Pgvector.new(vector)})
end)
```

**3. Query by cosine distance.** Embed the search string with
`task_type: :search_query`, then order by the `<=>` operator:

<!-- fence-check: skip — imports `Ecto.Query` and `Pgvector.Ecto.Query` — neither is a dependency of this library -->
```elixir
import Ecto.Query
import Pgvector.Ecto.Query

{:ok, response} = ALLM.embed(engine, query_text, task_type: :search_query)
[query_vector] = ALLM.EmbeddingResponse.vectors(response)

nearest =
  MyApp.Document
  |> order_by([d], cosine_distance(d.embedding, ^Pgvector.new(query_vector)))
  |> limit(5)
  |> MyApp.Repo.all()
```

`<=>` (cosine distance) is the safe default. `<#>` (inner product) is
faster but assumes unit-length vectors — which is exactly why the Gemini
adapter normalizes rather than leaving a mixed table behind.

## Usage and token accounting

`response.usage` is always an `%ALLM.Usage{}`, never `nil`, and
`:output_tokens` is always `nil` — embeddings produce no completion
tokens. What the other counters carry is provider-dependent:

* **OpenAI** reports `:input_tokens` and `:total_tokens`.
* **Voyage** reports `:total_tokens` only; `:input_tokens` is `nil`.
* **Gemini** reports **nothing** — a `batchEmbedContents` response
  carries no usage metadata at all, so `response.usage` is an
  all-`nil` `%ALLM.Usage{}`. Per-request cost accounting on Gemini has
  to come from your own token estimate.

Counters sum across chunks, so a chunked call's usage matches what the
same inputs would have reported unchunked.

## Telemetry

`ALLM.embed/3` runs inside a telemetry span with three event names. Every
call emits `:start` and then exactly one of `:stop` or `:exception` —
including a call that fails its adapter-presence gate, which still gets a
full `:start`/`:stop` pair:

* `[:allm, :embed, :start]` — measurements `system_time`; metadata
  `request_id`, `engine`, `model`, `input_count`.
* `[:allm, :embed, :stop]` — measurements `duration`, `embedding_count`,
  `chunk_count`; metadata `request_id`, `model`, `usage`, `response`,
  `error` (`nil` on success).
* `[:allm, :embed, :exception]` — measurements `duration`; metadata
  `kind`, `reason`, `stacktrace`. Emitted **instead of** `:stop` when the
  call raises rather than returning a tuple, and then re-raised. The two
  ways to reach it are a missing API key (see "Errors" below —
  `ALLM.Keys.fetch!/2` raises by design) and an `:embed_adapter` module
  that does not conform to the `ALLM.EmbeddingAdapter` behaviour.

Attach a handler for `:exception` as well as `:stop`, or a missing key
leaves you with an unterminated span and nothing explaining why.

Both `:stop` measurement keys are present on the success and error paths alike
(`0` on error), so a metrics backend sees a stable key set.
`chunk_count` is the only signal that one call became fifty HTTP
requests — worth graphing on any bulk ingest.

```elixir
:telemetry.attach(
  "embed-metrics",
  [:allm, :embed, :stop],
  fn _event, measurements, metadata, _config ->
    MyApp.Metrics.histogram("allm.embed.duration", measurements.duration,
      tags: [model: metadata.model, chunks: measurements.chunk_count]
    )
  end,
  nil
)
```

### Select the fields you need — do not serialize the whole map

The `:stop` metadata carries `response:`, which means it carries **the
full vectors**. Embedding vectors are partially invertible back to their
source text, so a handler that serializes the entire metadata map to a
log aggregator or APM backend is exporting a lossy encoding of your
corpus to that vendor.

Pick the fields you actually need — `duration`, `chunk_count`,
`embedding_count`, `usage`, `model` are the useful ones — rather than
passing `metadata` through wholesale. The input text itself is never
emitted: `:start` carries only `input_count`, a bare count.

## Errors

Everything except a missing key returns an error tuple.

| Error | Reason | What to do |
|---|---|---|
| `EngineError` | `:no_embed_adapter` | The engine has no `:embed_adapter`. Pass one. |
| `ValidationError` | `:invalid_embedding_request` | Empty input list, an empty-string element, a non-positive `:dimensions`, an unknown `:task_type`. `:errors` names the field. |
| `ValidationError` | `:unsupported_capability` | The model catalog says this model does not do embeddings. |
| `EmbeddingAdapterError` | `:authentication_failed` | 401/403. No retry. |
| `EmbeddingAdapterError` | `:rate_limited` | 429. Retried automatically, honouring `Retry-After`. |
| `EmbeddingAdapterError` | `:invalid_request` | 400. Fix the request. |
| `EmbeddingAdapterError` | `:context_length_exceeded` | An input is longer than the model's window, or the batch exceeds a per-request token cap. Shorten or chunk smaller. |
| `EmbeddingAdapterError` | `:provider_unavailable` | 5xx. Retried automatically. |
| `EmbeddingAdapterError` | `:timeout` / `:network_error` | Retried automatically. |
| `EmbeddingAdapterError` | `:malformed_response` | A 200 that could not be decoded. File a bug. |
| `EmbeddingAdapterError` | `:unsupported_feature` | The request combined features the adapter cannot express — e.g. `:dimensions` on a model with no such knob. |
| `EmbeddingAdapterError` | `:batch_too_large` | Only reachable on a direct adapter call; `ALLM.embed/3` chunks instead. |
| `EmbeddingAdapterError` | `:unknown` | The adapter could not classify the failure. Check `error.message` and `metadata.cause`. `FakeEmbeddings` returns it with `cause: :no_scripted_embedding` when a script runs out. |

The `EmbeddingAdapterError` rows are the complete eleven-member reason
enum (`ALLM.Error.EmbeddingAdapterError.legal_reasons/0`), so a `case` on
`error.reason` covering them is exhaustive — and `:unknown` is the clause
that fires when something unanticipated happens.

Unlike `ALLM.generate_image/3`, this façade validates the request before
dispatch. An empty-string input is a guaranteed provider rejection, and
in a chunked call it should fail immediately rather than after
forty-nine successful round-trips.

    iex> engine = ALLM.Engine.new(embed_adapter: ALLM.Providers.FakeEmbeddings)
    iex> {:error, error} = ALLM.embed(engine, [])
    iex> error.reason
    :invalid_embedding_request

A missing API key is the one exception: `ALLM.Keys.fetch!/2` **raises**
`%ALLM.Error.EngineError{reason: :missing_key}` by design, and adapters
do not rescue it.

## Testing with `FakeEmbeddings`

`ALLM.Providers.FakeEmbeddings` is the canonical test vehicle — same
idea as `ALLM.Providers.Fake` for chat. It is deterministic, needs no
network or key, and is `async: true`-safe (the script cursor keys on
engine identity).

Script one entry per expected call:

    iex> ok = {:ok, [ALLM.Embedding.new(vector: [1.0, 0.0])]}
    iex> boom = {:error, ALLM.Error.EmbeddingAdapterError.new(:invalid_request)}
    iex> engine = ALLM.Engine.new(
    ...>   embed_adapter: ALLM.Providers.FakeEmbeddings,
    ...>   adapter_opts: [embedding_script: [ok, boom]]
    ...> )
    iex> {:ok, _first} = ALLM.embed(engine, "a kestrel")
    iex> {:error, error} = ALLM.embed(engine, "a cedar branch")
    iex> error.reason
    :invalid_request

Retryable reasons (`:rate_limited`, `:provider_unavailable`, `:timeout`,
`:network_error`) are retried by the façade before they reach you, so a
script entry carrying one is consumed by the retry loop rather than
returned — script `{:retry_until_call, n}` instead when that is what you
want to exercise. It returns a synthetic `:rate_limited` error for the
first `n - 1` calls against it, then advances to the next entry.

A call past the end of the script is not an error you wrote: it returns
`%ALLM.Error.EmbeddingAdapterError{reason: :unknown}` with
`metadata.cause` set to `:no_scripted_embedding`. Seeing `:unknown` from
a `FakeEmbeddings`-backed test almost always means the script was one
entry short — often because the retry loop ate one.

Note that `FakeEmbeddings` mostly ignores the request — the script, not
`length(input)`, decides how many embeddings come back, and the vectors
are not derived from the input strings. That is what makes it useful for
asserting orchestration and useless for asserting a provider's wire
shape.

## Where to next

* `ALLM.embed/3` — the full option list. (Its own budget table does not
  yet call out the `:timeout` multiplication; the numbers above are the
  current ones.)
* `errors_and_retries.md` — how the retry policy is built and widened.
* `multi_tenant_keys.md` — per-call `:api_key` for bring-your-own-key.
* `examples/16_embed_single.exs` — one input, end to end.
* `examples/17_embed_batch_chunked.exs` — 250 inputs across several
  provider requests.
* `examples/18_embed_query_vs_document.exs` — asymmetric query/document
  embedding.
