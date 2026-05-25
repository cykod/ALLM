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
