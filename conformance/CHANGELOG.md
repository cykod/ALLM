# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Phase 14.1 — ALLM.ImageAdapter conformance

#### Added
- `ALLM.Test.ImageAdapterConformance` — 9 deterministic cases for the new
  v0.3 `ALLM.ImageAdapter` behaviour. Asserts `supported_operations/0`
  legal atoms, `:unsupported_operation` rejection before I/O,
  `request_id` and `metadata` round-trip, generate/edit/variation happy
  paths, default `%ImageUsage{}` populated, and `n: 4` batch returns up
  to four images. `@case_count 9` introspection seam plus meta-test
  asserting case-count stability.
- `ALLM.Test.Fixtures.ScriptedImageStub` and
  `ALLM.Test.Fixtures.GenerateOnlyImageStub` — permanent fixtures under
  `conformance/test/support/` exercising the harness's two adapter
  shapes (full operation list and narrowed `[:generate]`-only).

## [0.2.0]

### Added
- Initial release of the `allm_conformance` sibling package. Ships four
  `ExUnit.CaseTemplate`-based conformance harnesses:
  - `ALLM.Test.AdapterConformance` — 12 deterministic cases covering every
    `ALLM.Error.AdapterError` reason atom in the closed enum.
  - `ALLM.Test.StreamAdapterConformance` — 6 cases covering pre-flight error
    reasons, a plain text stream, mid-stream `AdapterError`, mid-stream
    `StreamError`, halt-safety (via `:counters`-backed cleanup observation),
    and `stream_timeout`.
  - `ALLM.Test.ToolExecutorConformance` — 10 cases covering every
    `ALLM.Tool.handler_result/0` shape and every executor-originated
    `ALLM.Error.ToolError` reason atom.
  - `ALLM.Test.ToolResultEncoderConformance` — 7 cases covering binary
    passthrough, Jason encoding, tuple unwrap, and determinism.
- `ALLM.Test.Fixtures.StubAdapter` — permanent test fixture that implements
  both `ALLM.Adapter` and `ALLM.StreamAdapter` with a scripted-event
  contract. Used by the harness's own self-tests.
