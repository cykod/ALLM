## [FEAT] Phase 1 + 2: Layer A data, Engine resolver, Keys chain
*Thursday, April 23rd at 12pm*
Ship Phase 1 and Phase 2 of the ALLM library end-to-end: Layer A data structs 
(Message, Request, Response, Thread, Session, StepResult, ChatResult, Event, 
Tool, ToolCall, Usage) with term_to_binary + Jason round-trip, the 
ALLM.Validate validator, the ALLM.Serializer tagged-JSON encoder/decoder, the 
full Phase 1 error hierarchy under ALLM.Error.*, and the lib/allm.ex facade 
with doctests (Phase 1). On top of that, Phase 2 adds ALLM.Engine's resolver 
API (merge_opts/2, resolve_model/2, resolve_tools/2, resolve_params/2), engine 
serializability via __from_tagged__/1 + Jason.Encoder, the five-level ALLM.Keys 
resolution chain (opts -> runtime Agent -> app_config -> env -> .env), and 
ALLM.Application supervising ALLM.Keys.Store. Suite stands at 323 tests, 96 
doctests, 12 properties, 0 failures, global coverage 96.59%. Also captures the 
process artifacts (AGENT_*_SPEC.md, steering design docs, retros, reviews, 
CHANGELOG) built via the retro-driven build discipline across both phases.

---

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Phase 2.4 — Engine Integration Test

#### Added
- `test/allm/engine_integration_test.exs` — four end-to-end scenarios proving the Phase 2 surface composes: (1) serialize → fresh process → deserialize → resolve identically; (2) runtime keys (`ALLM.Keys.put/2`) do not leak into the serialized engine (structural walk, not substring search on the ETF binary); (3) opts-win precedence end-to-end across `resolve_model/2`, `resolve_tools/2`, `resolve_params/2`; (4) `{Module, :function}` MFA tool handlers round-trip through `:erlang.term_to_binary/1` regardless of whether the module is loaded at decode time. Tagged `@moduletag :integration` so the suite can be scoped via `mix test --only integration`.

#### Changed
- `ALLM.Engine.@engine_field_keys` deny-list now includes `:params`. Without this, `resolve_params/2` would have attempted to merge a caller-supplied `opts[:params]` value (including `nil`) into `engine.params` via the opts pathway, contradicting Invariant 6's prose "opts with engine-field keys excluded." Surfaced by Sub-phase 2.4 Scenario 3; see PHASE_2_DESIGN.md Non-obvious decision #5 implementation note.

### Phase 2.2 — Keys + Application

#### Added
- `ALLM.Keys` module with five-level resolution chain (opts → runtime store → app config → env → `.env`) per spec §6.4. `get/1,2` returns `{:ok, key, source}` or `{:error, :missing}`; `fetch!/2` raises `%ALLM.Error.EngineError{reason: :missing_key}` with `:checked_sources` metadata. Empty-string values at every level are treated as missing.
- `ALLM.Keys.Store` — `Agent`-backed in-process key store (Non-obvious decision #1), caches the lazy `.env` load in the same Agent (Decision #10). `clear/0` resets both runtime keys and the dotenv cache.
- `ALLM.Keys.Dotenv` — built-in `.env` parser (Non-obvious decision #2) supporting `KEY=VALUE`, `# comment`, blank lines, `export KEY=VALUE`, and surrounding double-quote stripping. Single quotes are intentionally not stripped (documented limitation).
- `ALLM.Application` supervises `ALLM.Keys.Store`; `mix.exs` `application/0` now sets `mod: {ALLM.Application, []}` so the store starts with the `:allm` OTP app.
- `test/fixtures/sample.env` fixture plus unit + integration tests in `test/allm/keys_test.exs`, `test/allm/keys/store_test.exs`, `test/allm/keys/dotenv_test.exs`.

### Added
- `ALLM.Error.*` struct hierarchy (`EngineError`, `AdapterError`, `StreamError`, `ValidationError`, `ToolError`) — first-class serializable errors with `Exception` impls and default `:message` fallbacks. Per design sub-phase 1.1.
- `.new/1` constructors, `@spec`s, and `@doc` doctests on every Layer A struct (`ALLM.Message`, `ALLM.ToolCall`, `ALLM.Request`, `ALLM.Response`, `ALLM.StepResult`, `ALLM.ChatResult`, `ALLM.Usage`); `@doc` + doctest coverage expanded on the pre-existing `ALLM.Thread` and `ALLM.Tool` helpers; `@moduledoc` rewrite on `ALLM.Session` documenting the `metadata[:error]` convention and the caller-owned `context` contract. Per design sub-phase 1.2.
- Accessor functions `ALLM.Response.text/1`, `ALLM.ChatResult.halted?/1`, and `ALLM.Usage.total_tokens/1` with the documented fallback semantics. Per design sub-phase 1.2.
- `@enforce_keys` on `ALLM.Message` (`:role`, `:content`), `ALLM.ToolCall` (`:id`, `:name`, `:arguments`), and `ALLM.Tool` (`:name`, `:description`, `:schema`) so required-field omission raises `ArgumentError` at construction time. Per design sub-phase 1.2.
- `ALLM.Event.event?/1` guard function with payload-shape checks (map-typed payload required for every tag except the opaque `:raw_chunk` / `:error`), `ALLM.Event.tags/0` returning the closed 16-atom union, and 14 variant constructors (`text_delta/2`, `text_completed/2`, `tool_call_started/2`, `tool_call_delta/2`, `tool_call_completed/4`, `tool_execution_started/3`, `tool_execution_completed/3`, `tool_result_encoded/2`, `ask_user_requested/4`, `tool_halt/3`, `message_started/1`, `message_completed/1`, `step_completed/2`, `chat_completed/1`). Per design sub-phase 1.3.
- `ALLM.Validate` module with five validators (`request/1`, `message/1`, `tool/1`, `thread/1`, `session/1`). Returns structured `%ALLM.Error.ValidationError{}` with field-level error lists. Per sub-phase 1.4.
- `ALLM.Test.Generators` test-support module extracting Layer A struct generators (`role_gen/0`, `text_gen/0`, `tool_name_gen/0`, `message_gen/0`, `tool_gen/0`, `request_gen/0`) for reuse across property tests. Per retro 2026-04-19-phase1-1.4.
- `ALLM.Serializer` with `encode_tagged/2`, `to_json!/1`, `to_iodata!/1`, and `from_json/2` — tagged JSON encoding (`%{"__type__" => ..., "data" => ...}`) with `Jason` round-trip for every Layer A struct. `from_json/2` returns `{:error, %ValidationError{}}` with the closed field-error vocabulary (`:malformed`, `:missing_type_tag`, `:unknown_type_tag`, `:missing`, `:malformed_struct`, `:atom_decode_failed`) from sub-phase 1.5.
- `defimpl Jason.Encoder` and private `__from_tagged__/1` hydrators on every Layer A struct (`ALLM.Message`, `ALLM.Tool`, `ALLM.ToolCall`, `ALLM.Request`, `ALLM.Response`, `ALLM.Thread`, `ALLM.Session`, `ALLM.StepResult`, `ALLM.ChatResult`, `ALLM.Usage`) and every `ALLM.Error.*` struct. Atom-typed fields (`Message.role`, `Request.tool_choice`, `Request.response_format`, `Response.finish_reason`, `Session.status`, `ChatResult.halted_reason`, every error `:reason` and `:provider`) are restored via `String.to_existing_atom/1` per the tagged-encoding design (§1.5).
- `@doc` with runnable doctests on every public constructor in `ALLM` (`system/1`, `user/1`, `assistant/1`, `tool_result/2`, `tool/1`, `json_schema/3`, `request/2`) plus expanded `@moduledoc` with a Layer-A end-to-end worked example. Per sub-phase 1.6.

### Changed
- Removed `:llm_db` dependency from `mix.exs` (pinned to non-existent `~> 0.1`). Will be re-added in Phase 9 when capability pre-flight / cost population (spec §6.3) need it.
- `mix.exs` — added `:stream_data` (`~> 1.1`, test-only) for property-style tests on closed-union types (`ALLM.Event` variants).
- `ALLM.Serializer` now round-trips `response_format` map shapes (`%{type: :json_object}` and `%{type: :json_schema, name: _, schema: _, strict: _}`), preserving atom-keyed form on decode via a new `ALLM.Request.restore_response_format/1` helper. Escape-hatch maps with other string keys pass through unchanged (spec §5.4). Per sub-phase 1.5 review Finding 2.
- `ALLM.Validate.tool/1` now rejects tool names `"auto"`, `"none"`, `"required"` with `{:name, :reserved_tool_name}` to prevent collision with `tool_choice` atom restoration in the Serializer. Per sub-phase 1.5 review Finding 3; vocabulary table in sub-phase 1.4 updated accordingly.
- `ALLM.request/2` rewritten as a thin wrapper around `ALLM.Request.new/2` (semantically identical; internal cleanup so both facade and struct module have independent doctests). Per sub-phase 1.6.

### Fixed
- Normalized `lib/allm/event.ex` formatting (scaffolding commit had unformatted lines).
- `mix docs` warnings resolved — `README.md` and `ALLM.Validate` `@moduledoc` references restructured to avoid ExDoc cross-reference failures (forward-looking `ALLM.generate/3`, `ALLM.Session.reply/4` references phrased as plain text tagged with target phase; spec-path link converted to plain prose; `ALLM.Validate.*/1` glob replaced with an explicit enumeration of the five validators). Per sub-phase 1.6 review Finding 1.
