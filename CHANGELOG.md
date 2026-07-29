## [Unreleased]

Added — text embeddings:
- `ALLM.embed/3` — turn a string, a list of strings, or a
  `%ALLM.EmbeddingRequest{}` into vectors via the engine's new
  `:embed_adapter` slot. Returns
  `{:ok, %ALLM.EmbeddingResponse{}}`; `EmbeddingResponse.vectors/1` hands
  back `[[float()]]` in input order, ready for a vector column
- `ALLM.embedding_request/2` — builds an `%ALLM.EmbeddingRequest{}` from a
  string or list plus `:model` / `:dimensions` / `:task_type` /
  `:truncate` / `:options` / `:metadata`; every other opt is left for
  `embed/3` to treat as call control
- New serializable data types `%ALLM.Embedding{}` (with `normalize/1` and
  `magnitude/1`), `%ALLM.EmbeddingRequest{}`, and
  `%ALLM.EmbeddingResponse{}` (with `vectors/1` and `dimensions/1`), all
  round-tripping through both `:erlang.term_to_binary/1` and JSON
- New `ALLM.EmbeddingAdapter` behaviour — `embed/2`, `max_batch_size/0`,
  and the optional `prepare_request/2` escape hatch — plus a ten-case
  `ALLM.Test.EmbeddingAdapterConformance` suite in the `allm_conformance`
  package for third-party adapter authors
- New `%ALLM.Error.EmbeddingAdapterError{}` with an eleven-member reason
  enum and a `legal_reasons/0` accessor
- `%ALLM.Engine{}` gains `:embed_adapter`, a peer to `:adapter` and
  `:image_adapter` that never falls back to either; an engine without one
  returns `{:error, %ALLM.Error.EngineError{reason: :no_embed_adapter}}`
  ahead of every other gate
- `ALLM.Error.EngineError` gains `:no_embed_adapter`;
  `ALLM.Error.ValidationError` gains `:invalid_embedding_request`;
  `ALLM.Validate.embedding_request/1` and
  `ALLM.Capability.preflight_embedding/2` are new
- `ALLM.Providers.FakeEmbeddings` — the deterministic scripted embedding
  adapter, shipped in `lib/` so downstream apps can use it in their own
  tests; `{:retry_until_call, n}` script entries exercise retry paths
- `ALLM.Providers.OpenAI.Embeddings` (`/v1/embeddings`, 2048 inputs per
  request), `ALLM.Providers.Gemini.Embeddings` (`batchEmbedContents`, 100
  per request), and `ALLM.Providers.Voyage.Embeddings` (`/v1/embeddings`,
  1000 per request). Voyage is the Anthropic track — Anthropic ships no
  embeddings endpoint and names Voyage as its recommended partner, so the
  key resolves from `VOYAGE_API_KEY`; there is deliberately no
  `ALLM.Providers.Anthropic.Embeddings`
- Batching is transparent: input lists longer than the adapter's
  `max_batch_size/0` are split, dispatched **sequentially**, and merged
  into one response with indices rebased across chunk boundaries.
  `response.metadata.chunk_count` reports how many requests the call
  became. Retry and timeout budgets are **per chunk** with no aggregate
  deadline — `guides/embeddings.md` carries the multiplication table,
  including the `:timeout` case, which costs 9 HTTP attempts per chunk
  rather than 3 because the adapter's own retry loop and the façade's
  widened one both retry it. A failing chunk fails the whole call, with
  `completed_chunks` / `completed_inputs` on the error metadata
- New `[:allm, :embed, :start | :stop | :exception]` telemetry span;
  `:stop` measurements carry `duration`, `embedding_count`, and
  `chunk_count` on both the success and error paths, and `:exception`
  fires instead of `:stop` when the call raises — which a missing API key
  does, by design
- New `guides/embeddings.md` — provider matrix, task-type guidance,
  batching and the resumable-chunking loop, normalization, a `pgvector`
  worked example, and a note that `:stop` telemetry metadata carries the
  full vectors and should not be serialized wholesale
- New example scripts `16_embed_single.exs`,
  `17_embed_batch_chunked.exs`, and `18_embed_query_vs_document.exs`,
  running on all three provider arms. Live-validated against OpenAI,
  Gemini, and Voyage

Known behaviour worth flagging:
- Google's batch embedding endpoint returns no usage metadata, so
  `response.usage` is an all-`nil` `%ALLM.Usage{}` on Gemini. Voyage
  reports `total_tokens` only, leaving `input_tokens` `nil`. OpenAI
  reports both
- The Gemini adapter L2-normalizes any response whose `:dimensions` is
  set to anything other than `3072` (`gemini-embedding-001`'s native
  width), because Google does not normalize truncated output. The
  predicate is that single constant, applied unconditionally across
  models — not a per-model native-width lookup. A `dimensions: 768` response therefore differs numerically from
  the same request issued with `curl` — deliberate, so a vector table
  never ends up holding a mix of normalized and unnormalized rows
- `:task_type` is provider-neutral and lossy by design: Gemini maps all
  five members, Voyage supports query/document only, and OpenAI drops the
  field entirely (logged at `:debug`). A dropped task type is never an
  error

Changed:
- `ALLM.Engine.new/1` now raises `ArgumentError` on a non-module
  `:adapter`/`:tool_executor`/`:tool_result_encoder`/`:image_adapter`
  value (e.g. the unsupported `tool_executor: {Mod, tools: %{}}` form) —
  previously it constructed a booby-trapped engine that crashed later at
  tool-run time (§6.4)
- Bundled `guides/*.md` `iex>` examples now execute under `mix test` via
  `doctest_file` (`test/guides_doctest_test.exs`), so guide drift is a
  red test rather than a silent ship (§31)

Fixed:
- `chat/3`, `stream/3`, and `Session.*` now honor `max_tokens`/`temperature`
  from `engine.params` and call opts (previously silently capped at the
  adapter default, e.g. Anthropic 1024) — `Chat.build_request/4` folds the
  resolved sampling params onto the built `%Request{}`; opaque params
  (`top_p`, …) ride on `request.options` (§6.3, §10)
- Correct guide-content drift against the real 0.4.x API: engine-first
  3-tuple `Session.*` calls, the real status union
  (`:idle | :awaiting_user | :awaiting_tools | :completed | :error`),
  handler-on-tool executor pattern, `StreamReducer.{new,apply_event,finalize}`
  API, the closed streaming-event union, JSON round-trip field assertions,
  and the `FakeImages` `adapter_opts: [image_script: …]` shape
  (`guides/{sessions,tools,streaming,getting_started,image_generation,vision,errors_and_retries}.md`;
  see `steering/ALLM_VERIFIED_FACTS.md`)

## [REL] v0.4.3 — Engine identity

Breaking changes:
- `ALLM.Engine.new/1` now stamps each engine with a unique `:id`, so two
  engines constructed from identical opts are no longer equal
  (`Engine.new(o) != Engine.new(o)`); code comparing two independently
  built engines for equality will see them differ

Other changes:
- Add a stable, serializable `:id` field to `%ALLM.Engine{}` —
  auto-assigned at `new/1`, preserved across `with_model/2` /
  `merge_opts/2` / `put_tool/2`, and round-tripping through both ETF and
  JSON (pre-existing serialized engines decode with `id: nil`)
- Fix the `ALLM.Providers.Fake` / `FakeImages` multi-call cursor footgun
  — the cursor is now keyed on engine identity at the façade, so engines
  built with content-equal scripts no longer share a cursor (each
  engine's first call reads index 0); direct adapter calls without an
  engine keep the prior content-hash behavior

## [REL] v0.4.2 — Streaming usage fidelity

Other changes:
- Fix OpenAI Responses-API streaming usage landing as an all-nil
  `%Usage{}` for `gpt-5*` models — streaming now folds input/output/total
  and reasoning token counts into `Response.usage`, matching the
  non-streaming Responses path

## [REL] v0.4.0 — Integrator ergonomics

Breaking changes:
- `ALLM.Tool.new/1` (and `__from_tagged__/1`) now recursively normalize
  atom-keyed `:schema` maps to string keys for deterministic adapter
  wire shape; callers depending on atom keys on `%Tool{}.schema` will
  see strings instead
- `ALLM.Providers.Fake` streaming `{:usage, map}` script entries now
  fold onto `:message_completed.metadata.usage` instead of emitting a
  `:raw_chunk` event; tests asserting the prior `:raw_chunk` shape
  should pass `{:raw_chunk, {:usage, _}}` directly

Other changes:
- Add `ALLM.Sandbox` — Mox-style `set_engine/1` / `get_engine/0` /
  `with_engine/2` honouring `$callers` so engines set in a parent
  test process are visible to `Task.async/1` / `Task.async_stream/3`
  workers
- Add `ALLM.unwrap/1` — fold the three-clause `generate/3` return
  (`:stop` / `:error` / `{:error, _}`) into `{:ok, text} | {:error, _}`
- Add `ALLM.Providers.Fake` `adapter_opts[:usage]` (Usage struct or
  keyword; populates `response.usage` on every call) and
  `adapter_opts[:record]` (sends `{:allm_fake_record, request, opts}`
  to a pid before script interpretation)
- Add `ALLM.Image.from_data_uri/1` — parse `data:<mime>;base64,...`
  strings into a `{:base64, _}`-source `%Image{}` that round-trips
  through `to_data_uri/1`
- Add `ALLM.JsonSchema.normalize/1` — shared atom-to-string key
  normalizer called by both `Tool.new/1` and `ALLM.json_schema/3`
- Carry structured detail for `Validate.message/1`'s
  `{:content, :invalid_part_type}` error in
  `%ValidationError{}.metadata` (machine-readable) plus a human-readable
  `Exception.message/1` — `errors` list shape unchanged
- Document the arity-2 `:handler` context keys
  (`:context | :session_id | :tool_call | :engine | :request_id`) in
  `ALLM.Tool`'s `@typedoc`
- Document `chat(engine, thread, response_format: schema,
  structured_finalize: true)` in `guides/tools.md` — the existing
  tool-loop + structured coda flow was previously undiscoverable
- Add `guides/fakes.md` — consolidated Fake testing patterns
  (script vocabulary, cursor disambiguation, `:usage` / `:record`,
  halt-cleanup observation, retry simulation, Sandbox cross-process
  injection)
- Extend `guides/getting_started.md` with the three-clause
  finish-reason fold pattern and the engine-no-`:api_key` clarification
- Extend `guides/tools.md` with handler-context keys and an
  "Adapter-call cadence" subsection (tool-loop turns consume 2 adapter
  calls each)
- Extend `guides/vision.md` to point at `Image.from_data_uri/1` for
  data-URI inputs

## [REL] v0.4.1 — Streaming HTTP timeout forwarding

Other changes:
- Forward `:receive_timeout`, `:request_timeout`, and `:pool_timeout`
  from `opts` to `Finch.async_request/3` in the streaming codepath of
  `ALLM.Providers.OpenAI`, `ALLM.Providers.Anthropic`, and
  `ALLM.Providers.Gemini`. Previously these opts were dropped on the
  streaming arm — only `generate/2`'s non-streaming `Req`-based path
  honoured them — so callers passing `request_timeout:` to long-running
  streaming requests fell back to Finch's defaults (≈20s receive),
  causing premature `:timeout` failures on slow-first-token requests.
  Each `stream/2`'s `@doc` now documents the new opts and clarifies
  that `:stream_timeout` (inter-message) and `:receive_timeout`
  (HTTP-level) are distinct timers
- Extend `ALLM.Test.FinchStub` with `captured_opts/1` so tests can
  assert which Finch-level options the adapter forwarded
- Fix `scripts/release.exs` mangling `mix.exs` `@version` when the
  new version starts with a digit (e.g. `0.4.0`). The replacement used
  `\1` back-references which Erlang's `re` parsed as `\10` followed by
  literal text — producing `.4.0"` instead of `@version "0.4.0"`.
  Switch to unambiguous `\g{N}` back-refs

## [REL] v0.3.1 — Documentation rebuild

Other changes:
- Rewrite every `@moduledoc` and public `@doc` so prose is self-contained
  — no internal phase, spec-section, or design-decision references
- Add eight ExDoc guides under `guides/` (Getting Started, Streaming,
  Tools, Sessions, Vision, Image Generation, Errors & Retries,
  Multi-Tenant Keys), shipped to both hexdocs and the source tarball
- Restructure README around a 5-minute on-ramp and cross-link the
  guides instead of duplicating their content
- Drop the alpha warning in favor of a concrete stability statement
  (semver promise within v0.x)
- Add `scripts/audit_user_docs.exs` (banned-token gate) and
  `scripts/check_lib_diff_non_doc.exs` (docstring-vs-body classifier)
- Fix an `async: true` flake in `anthropic_stream_wire_test` by
  passing the stub key per-call instead of through the global
  `ALLM.Keys.Store` agent
- Clean up the release script — drop the redundant `finalize` step

## [REL] v0.3.0 — Initial public release

First public release of ALLM — a provider-neutral, streaming-first LLM
execution library for Elixir. The package is alpha: public APIs and
on-disk session shapes may shift between releases until v1.0.

Other changes:
- Layer A serializable data: `Message`, `Thread`, `ToolCall`, `Request`,
  `Response`, `Session`, `StepResult`, `ChatResult`, `Event`, `Usage` —
  round-trip through `:erlang.term_to_binary/1` and JSON
- Stateless execution facade: `ALLM.generate/3`, `stream_generate/3`,
  `step/3`, `stream_step/3`, `chat/3`, `stream/3`
- Stateful continuation via `ALLM.Session` with auto and per-tool manual
  orchestration modes and `{:ask_user, ...}` suspension
- Streaming as the primitive — synchronous calls are reducers over a
  closed `ALLM.Event` tagged-tuple union via `ALLM.StreamCollector`
- Bundled adapters for OpenAI (Chat Completions + Responses),
  Anthropic Messages, and Google Gemini, all live-validated
- Vision input across all three providers via `ALLM.TextPart` /
  `ALLM.ImagePart`
- Image generation/edit/variation behaviour with an OpenAI Images adapter
- Telemetry events, retry policy, capability pre-flight, and BYOK key
  resolution through `ALLM.Keys`
- Conformance harnesses (`ALLM.Test.AdapterConformance`,
  `ImageAdapterConformance`) and a deterministic `ALLM.Providers.Fake`
  test vehicle
- Provider-neutral example scripts under `examples/` runnable via
  `ALLM_PROVIDER=<name> mix run examples/run_all.exs`
