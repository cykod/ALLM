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
