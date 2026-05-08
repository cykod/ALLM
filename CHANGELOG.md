## [DOC] User-facing documentation rebuild

Rewrite user-facing documentation — drop internal phase/spec
references, expand examples, add `guides/` ExDoc extras (Getting
Started, Streaming, Tools, Sessions, Vision, Image Generation, Errors
& Retries, Multi-Tenant Keys). The README now opens with a 5-minute
on-ramp and cross-links the guides instead of duplicating their
content.

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
