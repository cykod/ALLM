## [REL] v0.6.0 — Content moderation

Breaking changes:
- An `%ALLM.Image{source: {:base64, _}}` whose data will not decode is now
  rejected locally as `%ALLM.Error.ValidationError{reason: :invalid_message}`
  carrying `:unresolvable_image`, instead of being forwarded for the provider
  to answer 400. Code matching on the provider's `%AdapterError{}` for this
  case now sees a `%ValidationError{}` from pre-flight
- `ALLM.Error.EngineError` gains `:no_moderation_adapter` and
  `ALLM.Error.ValidationError` gains `:invalid_moderation_request`. Both are
  closed enums, so an exhaustive `case` over either reason union needs a new
  clause

Other changes:
- Add content moderation: `ALLM.moderate(engine, "…user text…")` returns
  `{:ok, %ALLM.ModerationResponse{}}` via the engine's new
  `:moderation_adapter` slot. `ModerationResponse.flagged?/1` answers the
  common question in one call; `ModerationResult.category_scores` carries the
  provider's full per-category float map for callers wanting their own
  threshold
- Add `ALLM.Providers.OpenAI.Moderation` against the free `POST
  /v1/moderations`, targeting `omni-moderation-latest`. `max_batch_size/0` is
  1000, settled by a live ladder and documented as a demonstrated floor rather
  than a provider-stated cap
- Accept images: an `:input` may carry `%ALLM.ImagePart{}` items alongside
  strings. Any image makes the whole input **one** multimodal item, so the
  provider returns exactly one result however long the list —
  `ModerationRequest.multimodal?/1` derives that before the call
- Keep per-category maps provider-shaped and string-keyed rather than
  normalizing to a cross-provider atom taxonomy, so provider-controlled keys
  never grow the atom table
- Add the `ALLM.ModerationAdapter` behaviour with ten numbered invariants,
  a ten-case published conformance suite, and `ALLM.Providers.FakeModeration`
  — a scripted adapter whose `{:flagged, categories}` entry makes "assert the
  app rejects flagged content" a one-liner
- Add the `[:allm, :moderate, :*]` telemetry span with `result_count` and
  `flagged_count` on both success and error paths, and `usage: nil` on
  `:stop` so a handler written for `:embed` does not `KeyError`
- Add `ALLM.Capability.preflight_moderation/2`, inert without the optional
  `llm_db` catalog, and bind it with a test — deleting the gate previously
  left the whole suite green
- Add `guides/moderation.md` — the engine slot, `flagged?/1` versus a
  per-category threshold, the caller-side chunk loop (moderation deliberately
  does NOT chunk transparently the way `embed/3` does), image input and the
  multimodal cardinality rule, the one-row provider matrix and why it has one
  row, and the `FakeModeration` scripting grammar. Every runnable example
  executes as a doctest under `mix test`
- Add `examples/19_moderate_text.exs` and `examples/20_moderate_image.exs`,
  plus `ExamplesHelpers.moderation_engine/1` and the `ALLM_MODERATION_MODEL`
  override. Both carry a `# Provider: openai` marker so `run_all.exs` skips
  them on the arms that have no moderation adapter, and both cost $0.00
- Fix unreadable image files crashing every vision adapter. A
  `%ALLM.Image{source: {:file, path}}` whose file could not be read passed
  both the MIME and the size gate and then raised out of `generate/2` and
  `stream/2` on all four translators; it now returns an error tuple
- Fix transport timeouts never reaching Finch, so a slow reasoning turn is no
  longer killed at Finch's 15 s default. Add `ALLM.Adapter.transport_opts/0`
  as the neutral key list; transport opts now reach the adapter without
  leaking onto the request body, which also makes the documented
  `adapter_opts: [finch_name: …]` route work for the first time
- Assign the run-level `request_id` unconditionally in `ALLM.Runner`,
  dropping a defensive fallback no current code path could reach, and let
  `ALLM.Chat` compile clean under the Elixir 1.19 type checker
- Silence every compile, test, docs, and conformance warning across both Mix
  projects

## [REL] v0.5.0 — Text embeddings

Breaking changes:
- `ALLM.Engine.new/1` now raises `ArgumentError` on a non-module
  `:adapter` / `:tool_executor` / `:tool_result_encoder` / `:image_adapter`
  value (e.g. the unsupported `tool_executor: {Mod, tools: %{}}` form).
  Previously it built a booby-trapped engine that crashed later at
  tool-run time
- `chat/3`, `stream/3`, and `Session.*` now honor `max_tokens` /
  `temperature` from `engine.params` and call opts. Responses that were
  silently capped at the adapter default (Anthropic's 1024) are no longer
  capped, so requests that previously truncated will now run to
  completion — expect longer outputs and higher per-call cost

Other changes:
- Add text embeddings: `ALLM.embed/3` turns a string, a list of strings,
  or an `%ALLM.EmbeddingRequest{}` into vectors via the engine's new
  `:embed_adapter` slot. `EmbeddingResponse.vectors/1` returns
  `[[float()]]` in input order, ready for a vector column
- Add `ALLM.Providers.OpenAI.Embeddings` (2048 inputs/request),
  `ALLM.Providers.Gemini.Embeddings` (100), and
  `ALLM.Providers.Voyage.Embeddings` (1000). Voyage is the Anthropic
  track — Anthropic ships no embeddings endpoint and names Voyage as its
  recommended partner, so the key resolves from `VOYAGE_API_KEY` and
  there is deliberately no `ALLM.Providers.Anthropic.Embeddings`
- Chunk oversized input transparently: lists longer than the adapter's
  `max_batch_size/0` are split, dispatched sequentially, and merged with
  indices rebased across chunk boundaries. A failing chunk fails the whole
  call, carrying `completed_chunks` / `completed_inputs` on the error
- Add the `ALLM.EmbeddingAdapter` behaviour plus a ten-case
  `ALLM.Test.EmbeddingAdapterConformance` suite in the `allm_conformance`
  package for third-party adapter authors
- Add serializable `%ALLM.Embedding{}`, `%ALLM.EmbeddingRequest{}`, and
  `%ALLM.EmbeddingResponse{}`, all round-tripping through ETF and JSON,
  plus `%ALLM.Error.EmbeddingAdapterError{}` and its eleven-member reason
  enum
- Add `ALLM.Providers.FakeEmbeddings`, shipped in `lib/` so downstream
  apps can script embeddings in their own tests
- Add the `[:allm, :embed, :start | :stop | :exception]` telemetry span,
  with `chunk_count` on `:stop` so one call becoming fifty HTTP requests
  is visible
- Add `guides/embeddings.md` — provider matrix, task-type guidance,
  batching and resumable chunking, and a `pgvector` worked example — and
  example scripts 16–18, live-validated on all three providers
- Execute bundled `guides/*.md` `iex>` examples under `mix test` via
  `doctest_file`, so guide drift is a red test rather than a silent ship
- Correct guide drift against the real 0.4.x API: engine-first `Session.*`
  calls, the real status union, the handler-on-tool-executor pattern, the
  `StreamReducer` API, and the `FakeImages` `image_script` shape

Upgrade notes:
- Google's batch endpoint returns no usage metadata, so `response.usage`
  is an all-`nil` `%ALLM.Usage{}` on Gemini. Voyage reports
  `total_tokens` only; OpenAI reports both
- The Gemini adapter L2-normalizes any response whose `:dimensions` is set
  to anything other than `3072`, because Google does not normalize
  truncated output. A `dimensions: 768` response therefore differs
  numerically from the same request issued with `curl` — deliberate, so a
  vector table never holds a mix of normalized and unnormalized rows
- `:task_type` is provider-neutral and lossy by design: Gemini maps all
  five members, Voyage supports query/document only, and OpenAI drops the
  field entirely. A dropped task type is never an error
- Retry and timeout budgets are per chunk, with no aggregate deadline. A
  `:timeout` costs 9 HTTP attempts per chunk rather than 3, because the
  adapter's retry loop and the facade's widened one both retry it;
  `guides/embeddings.md` carries the multiplication table

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
