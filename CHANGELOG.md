## [FEAT] Phase 14.4: ALLM.TextPart + ALLM.ImagePart + Message.content widening + ValidationError :vision_not_in_v0_2 removed (§35.6, BREAKING for raw-map content callers)
*Monday, April 27th*
Multimodal Layer A content parts. Two new structs: `%ALLM.TextPart{}`
(`@enforce_keys [:text]`, `defstruct [:text, metadata: %{}]`) and
`%ALLM.ImagePart{}` (`@enforce_keys [:image]`, `defstruct [:image,
detail: :auto, metadata: %{}]`; `:detail` closed-set
`[:auto, :low, :high]` matching OpenAI's vision wire field). Both expose
`new/2` constructors with doctests, `__from_tagged__/1` hydrators, and
`Jason.Encoder` impls — ETF and JSON round-trips total. `ALLM.Message`
widens `@type t.content` to `String.t() | [TextPart.t() | ImagePart.t()]`
(spec §35.6); the v0.2 raw-`[map(), …]` shape is removed.
`Message.normalize_content/1` added as a one-way string→[TextPart] lift
helper for chat-adapter wire-shape boundaries (Phase 16/17).
`ALLM.Validate.message/1` rewritten: content lists are accepted iff
every element is a TextPart or ImagePart; raw maps now fail with
`{:content, :invalid_part_type}` (Decision #11). The
`:vision_not_in_v0_2` short-circuit, the four `image_part?/1` clauses,
the `vision_error/1` helper, the `check_vision_in_messages/2` helper,
and the `with :ok <- check_vision_in_messages(…)` calls in `request/1`
/ `thread/1` / `session/1` are all REMOVED. `ALLM.Error.ValidationError`
removes `:vision_not_in_v0_2` from `@type reason` and `@legal_reasons`
(Decision #12) — `ValidationError.new(:vision_not_in_v0_2, …)` now
raises `ArgumentError`. **BREAKING** for any caller pattern-matching on
`:vision_not_in_v0_2` or passing raw maps in `Message.content` lists.
`ALLM.Serializer.@known_modules` extends from 23 to 25 entries
(`ALLM.TextPart`, `ALLM.ImagePart`). `ALLM.Providers.OpenAI` and
`ALLM.Providers.Anthropic` get TWO co-ordinated changes per Decision
#14: (a) a top-level `reject_image_parts/1` guard at the start of
`generate/2` AND `stream/2` returning
`{:error, %AdapterError{reason: :unsupported_feature}}` for any
`%ImagePart{}` in a message content list (vision input is not yet wired
in either adapter — Phase 16/17 territory); (b) `stringify_content/1`
extended with a list-clause that maps `[%TextPart{text: t}, ...]` to
the joined text via `Enum.join("\n")`, plus a private
`materialize_part/1` with a `%TextPart{}` clause and a catch-all
`raise ArgumentError` programmer-error guard. The `materialize_part/1`
catch-all is unreachable in v0.3 (the upstream guard ensures only
TextParts reach it) but documents the expectation for the Phase 16/17
vision wiring. v0.2 backward-compat invariant load-bearing — every
existing `Message{content: "string"}` test continues to pass.

## [FEAT] Phase 14.3: image telemetry + capability preflight_image + retry integration (§35.9, §6.1)
*Monday, April 27th*
Cross-cutting wrap for the v0.3 image pipeline. The bare 14.2 façade
(`generate_image/3 · edit_image/4 · image_variations/3`) is now wrapped
in `Telemetry.span(:image, ...)` plus `Capability.preflight_image/2`
plus `Retry.run/3`-driven dispatch. `ALLM.Telemetry.@valid_span_names`
extends with `:image` (typedoc + moduledoc updated) — `[:allm, :image,
:start | :stop | :exception]` events fire per call. `:image, :stop`
measurements add `:image_count` (length of `response.images` on success
/ `0` on error per design Decision #8); metadata extends with
`:operation`, `:n` (request fields, NOT measurements per Decision #8),
`:usage`, `:response`, and `:error`. `Telemetry.span/3` widened to
accept either `{result, stop_extras}` or `{result, extra_measurements,
stop_extras}` from the closure (3-tuple form forwards extras as
telemetry measurements). `ALLM.Capability.preflight_image/2` added as
a 2-arity SISTER of `preflight/3` (Decision #10 — narrower contract,
no rewrite branch): two rejection rules (`:images_disabled`,
`:unsupported_image_operation`) accumulating per `preflight/3`'s
field-error precedent; tolerates atom-keyed AND string-keyed
capabilities per the `lib/allm/capability.ex:296-303` pattern.
`do_generate_image/3` rewritten as: `Telemetry.span(:image, ...) ->
adapter-presence gate (FIRST, per Decision #15) -> preflight_image ->
Retry.run`. `Retry` policy augmented at the call site with the four
image-side retryable atoms (`:rate_limited`, `:provider_unavailable`,
`:timeout`, `:network_error`) appended to the chat-side `retry_on`
default — chat default unchanged (Decision #9). `ALLM.Providers.FakeImages`
extended with `{:retry_until_call, n}` script entry that holds the
cursor in place for `n - 1` calls returning synthetic
`%ImageAdapterError{reason: :rate_limited, retry_after_ms: 0}`, then
advances on call n. `test/support/llm_db.ex` `@fixtures` map extended
with three image-capability fixtures (`openai:gpt-image-1`,
`openai:dall-e-3`, `local:no-images`). Three new test files
(`telemetry_image_test.exs`, `capability_image_test.exs`,
`retry_image_test.exs`) and four new cases in
`fake_images_test.exs`. 1668 tests / 0 failures / 0 dialyzer warnings;
conformance 66 tests / 0 failures.

---

## [FEAT] Phase 14.2: ALLM.generate_image/3 · edit_image/4 · image_variations/3 + EngineError :no_image_adapter (§35.4, §35.5)
*Monday, April 27th*
Layer C facade for v0.3 image pipeline. Adds `ALLM.generate_image/3`,
`ALLM.edit_image/4`, `ALLM.image_variations/3` to `lib/allm.ex` — bare
`with`-chain dispatch against `engine.image_adapter` through
`ALLM.Providers.FakeImages` (no telemetry, no preflight, no retry — those
land in 14.3). `generate_image/3` accepts either a binary prompt
(delegates to `ALLM.image_request/2`) or a pre-built `%ImageRequest{}`.
`edit_image/4` honors three call shapes per Decision #6: single base
image, 2-element list `[base, mask]` (becomes `input_images: [base, mask]`,
`mask: nil`), and explicit `mask:` keyword. `image_variations/3` builds
`%ImageRequest{operation: :variation, input_images: [image], prompt: nil}`.
Adapter-presence gate is the FIRST check (before any other validation per
Decision #5): `engine.image_adapter == nil` returns
`{:error, %EngineError{reason: :no_image_adapter}}`. `request_id`
precedence per Decision #7 — `opts[:request_id]` wins over
`Telemetry.request_id/0`; forwarded to adapter via `opts[:request_id]`;
`response.request_id` filled post-call IFF adapter left it `nil`.
`:stream` opt silently dropped (line 294); unknown opts forward to the
adapter via `opts`. Validator NOT called from facade per Decision #13 —
caller-opt-in only. `EngineError` `@type reason` and `@legal_reasons`
extended with `:no_image_adapter` (closed enum 7 → 8 atoms). Property
tests assert `edit_image/4` and `image_variations/3` produce structs
byte-equal (modulo `:request_id`) to `ALLM.image_request/2`-built
equivalents. 1625 tests / 0 failures / 0 dialyzer warnings.

---

## [FEAT] Phase 14.1: ALLM.ImageAdapter behaviour + ALLM.Providers.FakeImages + ALLM.Test.ImageAdapterConformance harness (§35.3, §35.8)
*Monday, April 27th*
Layer B for v0.3 image pipeline. Introduces `ALLM.ImageAdapter` behaviour
(callbacks: `generate/2`, optional `prepare_request/2`, `supported_operations/0`)
in `lib/allm/image_adapter.ex` plus `ALLM.Error.ImageAdapterError` — closed-enum
exception struct (12 reasons: `:authentication_failed`, `:rate_limited`,
`:invalid_request`, `:content_filter`, `:context_length_exceeded`,
`:provider_unavailable`, `:timeout`, `:network_error`, `:malformed_response`,
`:unsupported_feature`, `:unsupported_operation`, `:unknown`) with full ETF +
JSON round-trip via `ALLM.Serializer` (`@known_modules` 22 → 23). Ships
`ALLM.Providers.FakeImages` in `lib/` (Decision #1, mirrors `Fake` precedent)
implementing the behaviour with a process-local cursor, `script/1` validation,
`start_script_cursor/0` Agent escape hatch, `:unsupported_operation` entry-point
gate, and `request_id` / `metadata` round-trip per §35.3 invariants.
`ALLM.Test.ImageAdapterConformance` harness lives at
`conformance/lib/allm/test/image_adapter_conformance.ex` (Decision #2 — published
with `allm_conformance`); 9-case `@case_count` matrix with introspection
seam + meta-test against drift; `ScriptedImageStub` / `GenerateOnlyImageStub`
fixtures in `conformance/test/support/`. `mix.exs` docs groups extended
(`ALLM.ImageAdapter` under Behaviours; `ALLM.Providers.FakeImages` under
Providers; `ALLM.Error.ImageAdapterError` under Errors). 1600 tests / 0
failures / 0 dialyzer warnings; conformance package 66 tests / 0 failures.

---

## [FEAT] Phase 13: v0.3 Layer A image data structs + facade + validator
*Monday, April 27th at 10am*
First v0.3 slice (see steering/PHASE_13_image_layer_a.md). Adds Layer A image 
data structs ALLM.Image, ALLM.ImageRequest, ALLM.ImageResponse, ALLM.ImageUsage 
with full constructors (from_file/from_binary/from_url/from_base64), pure 
resolvers (to_binary/to_data_uri), Jason.Encoder + __from_tagged__/1 hydrators, 
and ETF/JSON round-trip serializability across all four :source variants. 
Public surface: ALLM.image_request/2 facade and ALLM.Validate.image_request/1 
validator with exhaustive 11-atom field-error vocabulary (accumulator pattern 
matching Validate.request/1 precedent). Extended ALLM.Serializer.@known_modules 
18 to 22; extended hydrate_with/2 rescue to forward ValidationError raises 
(required for [:source, :invalid_base64] field-error path); extended 
ALLM.Error.ValidationError.@type reason with :invalid_image_request. Engine 
round-trip extension proves populated image_adapter: doesn't perturb v0.2 
serializability. ImageUsage cost fields refined to float() | nil from spec 
§35.2.4's Decimal — spec PR pending alongside v0.3.0. Full suite: 1553 tests 
/ 0 failures / 0 dialyzer warnings. Cite §35.2.1, §35.2.2, §35.2.3, 
§35.2.4, §35.4, §35.5; refines §16.

---

## [FEAT] v0.3 Phase 13.3: ALLM.image_request/2 facade + ALLM.Validate.image_request/1 + Engine round-trip extension (§35.4, §35.5)

Public surface for image creation lands.

`ALLM.image_request/2` facade constructor (`lib/allm.ex`) — one-line wrapper
over `ALLM.ImageRequest.new/1` that puts the positional `prompt` last in
the opts list (positional argument is authoritative). Mirrors `request/2`'s
no-validate precedent (Decision #7): unknown keys raise `KeyError` via
`struct!/2`; validator rejection cases (e.g. `:variation` with a non-empty
prompt) return the struct anyway — call `Validate.image_request/1`
explicitly to check.

`ALLM.Validate.image_request/1` validator (`lib/allm/validate.ex`) —
accumulator pattern matching `request/1`. Returns `:ok` or
`{:error, %ValidationError{reason: :invalid_image_request, errors: [...]}}`
accumulating ALL failed rules (no hard-reject). Operation-arity rules per
spec §35.2.2 (`:generate`/`:edit`/`:variation`); field rules over `:n`,
`:response_format`, `:size`, `:input_images`, `:mask`. Field-error vocabulary
is closed against the design's §Error Contract table — atoms include
`:required_for_operation`, `:not_allowed_for_operation`, `:must_be_empty`,
`:invalid_count`, `:not_a_list`, `:invalid_image`, `:must_be_positive`,
`:unknown`, `:invalid_shape`. Indexed paths for `:input_images` element
rejections (`{[:input_images, idx], :invalid_image}`).

`ALLM.Error.ValidationError.@type reason` and `@legal_reasons` extended with
`:invalid_image_request` (1 atom — closed-set extension; field-reason atoms
remain open per the v0.2 vocabulary precedent).

`test/allm/engine_roundtrip_test.exs` populated_engine helper now sets
`image_adapter: ALLM.Engine` (using the engine module itself as a
stub-but-loaded module, matching the `@stub_handler_module` pattern). The
existing ETF and JSON round-trip tests now exercise the populated field;
plus one new explicit test asserts the field decodes to the loaded module
via `restore_module/1` (`String.to_existing_atom/1` per
`lib/allm/engine.ex:416`) — belt-and-braces against the silent-success
failure mode where the field round-trips to `nil` due to a wiring bug.

v0.2 backward-compat invariant holds: full suite at 1553 tests, all green.

---

## [FEAT] v0.3 Phase 13.1: ALLM.Image Layer A struct + four constructors + to_binary/to_data_uri (§35.2.1)

New `ALLM.Image` Layer A struct (`lib/allm/image.ex`) with `@enforce_keys [:source]`
and four pure constructors — `from_file/1`, `from_binary/2`, `from_url/1`,
`from_base64/2`. `from_binary/2` and `from_base64/2` carry runtime
`is_binary(mime_type)` guards backing the `@spec` (nil/integer mime raises
`FunctionClauseError`). `from_file/1` is pure data — does NOT call
`File.read/1`; MIME-type lookup is extension-only against the closed set
`[".png", ".jpg", ".jpeg", ".webp", ".gif"]` (case-insensitive). `to_binary/1`
resolves `:binary`/`:base64`/`:file` sources; `{:url, _}` returns
`{:error, :remote_source}` (Decision #2 — Layer A never fetches URLs).
`to_data_uri/1` likewise returns `{:error, :remote_source}` for `{:url, _}`
and `{:error, :missing_mime_type}` when `:mime_type` is `nil`; the
`{:base64, _}` arm is a fast path that forwards the encoded string verbatim.
JSON `Jason.Encoder` impl pre-pass-transforms `:source` from a tuple into a
`%{"type" => "...", "value" => ...}` map (Base64-encoding the binary
variant). `__from_tagged__/1` dispatches `data["source"]["type"]` against
the closed set `~w[binary base64 url file]`; an unknown type falls through
to `{:_unknown, :atom_decode_failed}`, while invalid base64 in a `"binary"`
source raises a pre-built `ValidationError` carrying
`{[:source], :invalid_base64}` so the field-error survives the serializer's
`ArgumentError` rescue. `ALLM.Image` registered in `ALLM.Serializer.@known_modules`.

---

## [FEAT] v0.3 Phase 13.2: ALLM.ImageRequest/ImageResponse/ImageUsage Layer A structs + Serializer registry extension (§35.2.2-4)

Three remaining Layer A image structs land plus the serializer registry
extension to 22 known modules.

`ALLM.ImageRequest` (`lib/allm/image_request.ex`) carries the closed
operation enum `:generate | :edit | :variation`, a `:size` type that mixes
the tuple form `{w, h}` with `String.t()` and `:auto`, a `:quality` open
type with closed-atom restoration on decode, and the closed
`:response_format` enum `:binary | :base64 | :url`. `new/1` is `struct!/2`
over keyword opts — unknown keys raise `KeyError` (mirrors
`ALLM.Request.new/2`). The `__from_tagged__/1` decoder uses dedicated
`decode_size/1` and `decode_quality/1` private helpers (mirroring
`lib/allm/request.ex:94-99`'s closed-set-with-binary-fall-through pattern)
and routes the atom-only fields through `ALLM.Serializer.to_atom_field/1`
directly. JSON encodes the `:size` tuple as a 2-element array.

`ALLM.ImageResponse` (`lib/allm/image_response.ex`) carries an `:images`
list, an `:usage` field defaulting to `%ALLM.ImageUsage{}` (NEVER nil), an
opaque `:raw` term (caller responsibility to keep JSON-encodable — same
contract as `ALLM.Response.raw`), plus `:id`/`:request_id`/`:model`
correlation fields. ETF round-trip is total.

`ALLM.ImageUsage` (`lib/allm/image_usage.ex`) carries `:images`
(default `0`), the `:size` and `:quality` strings the provider returned, and
optional token + cost fields for token-priced models like gpt-image-1.

**NOTE — spec refinement (Decision #1).** `ALLM.ImageUsage` cost fields are
typed `float() | nil`, NOT `Decimal.t() | nil` as spec §35.2.4 currently
reads. Rationale: `ALLM.Usage.cost` is already `float()`
(`lib/allm/usage.ex:11`); adopting `Decimal` solely for `ImageUsage` would
split the cost type and add a runtime dep (`:decimal` is not in `mix.exs`)
for no semantic gain. Float-summation drift on
`total_cost = input_cost + output_cost` is bounded at ≤1 ULP, well below
provider cent-level pricing precision. A spec PR against
`steering/allm_engine_session_streaming_spec_v0_2.md` §35.2.4 will land
alongside v0.3.0 recording this refinement.

`ALLM.Serializer.@known_modules` extended from 18 to 22 entries — adds
`ALLM.Image`, `ALLM.ImageRequest`, `ALLM.ImageResponse`, `ALLM.ImageUsage`.
`mix.exs` `groups_for_modules: ["Data types": …]` extended likewise so
`ex_doc` groups the four new structs with v0.2 data types.

---

## [FEAT] Phase 12: v0.2.0 release polish + case-study tests
*Sunday, April 26th at 8pm*
Final v0.2 release polish (see steering/PHASE_12_DESIGN.md). Bumped @version 
0.0.1 to 0.2.0; added ex_doc groups_for_modules (9 groups 
Facade/Sessions/Behaviours/Providers/Defaults/Data 
types/Runtime/Internals/Errors) + extended extras: with CHANGELOG.md; rewrote 
README with copy-paste Getting Started snippet against ALLM.Providers.Fake plus 
parallel iex-prompt doctest in lib/allm.ex's @moduledoc (Decision #3). Added 
§31 audit-gate meta-test (frozen at 18 test-blocks via @case_count 
introspection per AGENT_DESIGN_SPEC §3 rule 7). Translated 4 
steering/examples/ case studies (Amesbury, Garden, meal, unllmtd) into 
deterministic Fake-driven integration tests under test/examples/ — 21 new 
tests via shared ALLM.Test.ExampleFixtures helper at test/support/. Added audit 
test enforcing every public lib/ module appears in exactly one ex_doc group, 
and a README-snippet drift test that parses + evaluates the Getting Started 
block. CHANGELOG.md gains a v0.2 rollup heading; existing per-phase entries 
preserved verbatim. mix hex.build dry-run validates a clean tarball whitelist 
(lib/, mix.exs, README.md, LICENSE, .formatter.exs); mix hex.publish remains an 
out-of-band maintainer step (Decision #1). Full suite: 1425 tests / 0 failures 
/ 0 dialyzer warnings. Cite §31, §32.1, §32.4, §33, §34.

---

## v0.2 — 2026-04-26

First public release of ALLM. The v0.2 delta from `0.0.1` (initial scaffolding)
covers eleven implementation phases plus the release-polish wrap. Per-phase
entries below remain verbatim; this rollup is the elevator pitch.

- **Layered architecture (Phases 1–2).** Four-layer split — Serializable data
  (`ALLM.Message`, `Request`, `Response`, `Thread`, `Session`, `Event`, …) /
  Runtime (`ALLM.Engine` + behaviours) / Stateless execution (`ALLM.generate/3`,
  `chat/3`, …) / Stateful continuation (`ALLM.Session.*`). Engines and sessions
  round-trip through `:erlang.term_to_binary/1` and JSON via `ALLM.Serializer`;
  no PIDs, refs, funs, or API keys leak across the boundary.
- **Stream-first execution + `ALLM.Providers.Fake` (Phases 4–5).** `stream_*`
  variants are the primitives; non-streaming `generate/3` / `step/3` / `chat/3`
  are reducers over an `ALLM.Event` stream. The deterministic Fake adapter is
  the canonical test vehicle — scripted text, tool-call, finish, error, and
  delay events drive every §31 property-style scenario without the network.
- **Tool orchestration with auto + manual modes and ask-user (Phases 6–7).**
  `chat/3` runs a multi-turn loop with `:auto` mode (executes tool handlers)
  or `:manual` mode (halts on `finish_reason: :tool_calls` for the caller to
  submit results). Handlers may return `{:ask_user, q, opts}` to suspend the
  loop; `on_tool_error: :halt` and a `:halt_when` predicate provide additional
  per-step gates.
- **Sessions with serializability (Phase 8).** `ALLM.Session` persists a thread
  + engine reference + halted state so a paused conversation survives a
  process restart; `Session.start/3`, `reply/4`, `submit_tool_result/3`, and
  the streaming variants resume the loop against new input.
- **Telemetry, retry, and capability cross-cutting (Phase 9).** `ALLM.Telemetry`
  emits `:request`, `:stream`, `:tool`, and `:retry` events; `ALLM.Retry`
  centralizes 429/5xx backoff with provider-aware `retry_after` parsing;
  `ALLM.Capability` + `ALLM.ModelRef` provide pre-flight model-string
  resolution (optional, falling back gracefully when `llm_db` is absent).
- **OpenAI + Anthropic adapters with structured output (Phases 10–11).** Both
  providers ship as `ALLM.Adapter` + `ALLM.StreamAdapter` implementations
  (Req for non-streaming; Finch HTTP/1 + SSE for streaming). Structured-output
  via OpenAI's native `:json_schema` `response_format` and Anthropic's
  tool-forcing pattern with a shared `lift_structured_output/1` helper;
  streamed structured output emits `:text_delta` events on both providers.
- **Provider-neutral runnable examples (Phase 11.4).** `examples/_helpers.exs`
  + nine numbered scripts + `run_all.exs` orchestrator; `ALLM_PROVIDER=openai`
  or `anthropic` switches the engine. `examples/run_all.exs` is the BLOCKING
  `/review` validation gate — both providers must exit 0.
- **§31 testing harness + audit gate freeze (Phase 4 + Phase 12.1).** Spec §31
  property-style scenarios live in `test/allm/providers/fake_scenarios_test.exs`
  with a `@case_count`-backed meta-test that fails loudly when a contributor
  adds or removes a `test` block without bumping the freeze count.
- **Case-study translations (Phase 12.2).** Four `steering/examples/` case
  studies (Amesbury, Garden, meal, unllmtd) translated into deterministic
  Fake-driven integration tests under `test/examples/`, proving the public
  API surface matches each case study's promised "After" snippets.

---

## [DOC] Apply 11 retros into design + implementation spec docs
*Sunday, April 26th at 7pm*
Lifted 12 high-priority findings from 11 unapplied retros (Phase 9 through 
Phase 11.4) into the canonical agent docs. AGENT_DESIGN_SPEC.md gains six new 
Behaviour design-doc checklist rules (14-19) covering Layer-C reducer-touch 
enumeration, per-provider wire-field maps, synthesized-vs-recorded fixture 
policy, detection-mechanism for state-conditioned behavioural deltas, the 
provider-neutral examples _helpers.exs template, and live-API cost estimation. 
AGENT_IMPLEMENTATION_SPEC.md adds wall-clock timing assertion guidance under 
Layer C tests and a new sub-section 4i on closed-enum dual-validation (protocol 
vs provider acceptance). CLAUDE.md gains an 
adapter-default-for-required-wire-field invariant plus four 
Working-on-this-codebase rules: BLOCKING per-provider live-validation, 
cross-phase bug discipline, Logger deferred form for hot paths, and SSE 
chunk-mapper one-function-per-event-type pattern. All 11 retros renamed to 
_applied.md (gitignored, not staged).

---

## [FEAT] Phase 11.4: provider-neutral examples framework + Anthropic enrollment
*Sunday, April 26th at 5pm*
Migrates the nine runnable example scripts from examples/openai/ up to a
unified provider-neutral examples/ directory and introduces examples/_helpers.exs
with a provider table keyed by ALLM_PROVIDER (default "openai"; "anthropic"
added as the second row per spec §32.1). Each script's first lines are now
Code.require_file("_helpers.exs", __DIR__) + engine = ExamplesHelpers.engine()
(or .engine(tools: [...])); the helper centralizes EnvLoader-based .env
auto-load, validates the per-provider *_API_KEY env, honors ALLM_MODEL
override, and bakes params: %{temperature: 0} for cross-provider determinism.
06_structured_output.exs now branches on ALLM_PROVIDER to assert
metadata.structured_output_tool == true only for Anthropic per Phase 11
Decision #4 (OpenAI's native :json_schema response carries no equivalent
marker). examples/run_all.exs is the BLOCKING /review validation gate — it
must exit 0 against BOTH providers; per-provider RUN_OUTPUT_OPENAI.md and
RUN_OUTPUT_ANTHROPIC.md snapshots are committed alongside.

---

## [FEAT] Phase 11: Anthropic provider (non-streaming + streaming + structured output)
*Sunday, April 26th at 4pm*
Lands ALLM.Providers.Anthropic implementing both Adapter and StreamAdapter 
behaviours with non-streaming generate/2 (Req-backed, Retry integration 
including 529 Overloaded per spec §6.4), streaming stream/2 (Finch HTTP/1 + 
SSE → ALLM.Event mapper per §7.2 §8 Decision #14), and structured output 
via the tool-forcing pattern (§5.4) sharing lift_structured_output/1 between 
both arms. Decision #5b is amended: streamed structured-output now emits 
:text_delta events (matching OpenAI's native :json_schema streaming) so 
consumers can write provider-neutral structured-output streaming code; the 
stream wrapper additionally stamps metadata.structured_output_tool: true on the 
rewritten :message_completed payload so invariant 14's byte-identical 
%Response{} guarantee holds across arms (M1 fix from the Phase 11.3 review). 
Coverage on the new adapter is 91.10%; full suite 1401 tests / 0 failures, 
credo and dialyzer clean.

---

## [FEAT] Phase 10: OpenAI provider (both endpoints) + BYOK fix
*Sunday, April 26th at 1pm*
Ships ALLM.Providers.OpenAI implementing both ALLM.Adapter and
ALLM.StreamAdapter against /v1/chat/completions and /v1/responses,
including endpoint dispatch (gpt-5* and o-series → Responses, gpt-4*
→ Chat Completions), reasoning controls (reasoning_effort,
reasoning_summary, verbosity), structured_finalize two-pass
orchestration in ALLM.Chat, ALLM.Capability.preflight contract
widened to optionally rewrite the request, ALLM.Providers.Support.SSE
line-buffered decoder shared with future Anthropic adapter, and
default ALLM.Finch HTTP/1 pool started by ALLM.Application. Adds 9
runnable example scripts under examples/openai/ targeting
gpt-5.4-nano with a run_all.exs orchestrator validated live against
the real provider — the BLOCKING /review gate caught and led to
fixes for five wire-shape bugs (tool envelope per endpoint,
reasoning-opts endpoint override, Responses input encoder for tool
round-trips, Responses output[] tool-call decoder, streaming
function_call SSE handlers). Also fixes a per-call api_key leak in
StreamRunner.build_dispatch_opts/2 so SaaS BYOK works end-to-end via
ALLM.generate(engine, req, api_key: tenant_key), and stops Chat from
forwarding orchestration opts (:mode, :max_turns, :halt_when) into
the runner. 1272 tests / 0 failures across 6 sub-phases (10.1
through 10.6).

---

## [FEAT] Phase 9: telemetry, retry, capability, ModelRef
*Saturday, April 25th at 11pm*
Ships Phase 9 in four sub-phases: ALLM.Telemetry wraps every Layer C entry 
point with :telemetry.span/3 and threads a per-call request_id through 
generate/stream/step/chat plus per-tool spans inside ToolRunner (spec §29); 
ALLM.Retry runs the spec §6.1 default policy with bounded additive jitter and 
emits [:allm, :adapter, :retry] per attempt, integrated end-to-end via the Fake 
adapter's retry_until_call: opt; ALLM.Capability adds 
preflight/populate_costs/select gated on Code.ensure_loaded?(LLMDB) with an 
Application.put_env override-based dep-free smoke test, plus the ALLM.ModelRef 
Layer A struct (spec §6.3) and the :unsupported_capability ValidationError 
vocabulary extension. Test suite grows from 1054 to 1095 tests (0 failures); 
coverage 94.79 percent global with 100/97/95 percent on the new modules; mix 
credo --strict and mix dialyzer remain clean. The :allm event prefix is used 
throughout in deliberate deviation from spec §29's [:llm, ...] (Decision #15) 
— a non-blocking spec-amendment ticket follows.

---

## [FEAT] Phase 8: ALLM.Session stateful continuation
*Saturday, April 25th at 7pm*
Implements Layer D ALLM.Session stateful continuation per spec §11 and §13.2. 
Adds Session.start/3, reply/4, continue/3, step/3, submit_tool_result/3, and 
submit_tool_results/2 over a persisted %ALLM.Session{} with a 5-status state 
machine (:idle, :running, :awaiting_tools, :awaiting_user, :completed, :error). 
Adds ALLM.Session.StreamReducer wrapping StreamCollector with a :chat | :mode 
flag for streaming Layer D, ALLM.Error.SessionError as a new Layer A error 
struct (closed :reason enum), and extends ValidationError with 
:invalid_session_input. Phase 8.4 cross-cutting tests include a StreamData 
property asserting Session.start ≡ stream_start |> finalize, an exhaustive 
25-row status-transition matrix, post-operation ETF + Jason round-trip rows, 
and activation of the §31 session round-trip scenario (all 12 §31 scenarios 
now active). Empirical verification of the masking-divergence row in 
PHASE_8_DESIGN.md §8.4.1 found no metadata divergence between streaming and 
non-streaming arms; assert_equivalent_session_result/2 asserts :metadata 
unconditionally.

---

## [FEAT] Phase 7: chat/3 + stream/3 multi-turn orchestration loop
*Saturday, April 25th at 5pm*
Ships the first Layer C surface that orchestrates the full multi-turn loop. 
ALLM.chat/3 repeatedly runs step/3, appending results to the thread until a 
terminal condition fires (adapter finish_reason, :max_turns exhausted, 
:halt_when callback, handler-requested {:halt, _, _} or {:ask_user, _}, 
on_tool_error: :halt, or :manual mode surfacing tool calls). ALLM.stream/3 
emits every Phase-5/6 event across every turn plus exactly one terminal 
:chat_completed event carrying the final %ChatResult{}. Adds StreamCollector 
:step_completed/:chat_completed fold clauses, the ToolRunner on_tool_error 
function form, ask-user thread mutation at the turn boundary (spec §12.3), and 
a chat-equivalence property asserting chat/3 ≡ stream/3 |> 
StreamCollector.to_chat_result/1 across every multi-turn Fake fixture. 
Activates §31 max_turns/halt_when/manual scenarios; all 857 tests + 18 
properties green.

---

## [FEAT] Phase 6: step/3 + stream_step/3 with parallel tool execution
*Friday, April 24th at 10pm*
Implements Phase 6 sub-phases 6.1-6.4 across three batches: ALLM.ToolRunner 
(parallel Task.async_stream dispatch + on_tool_error policy), ALLM.Chat.step/3 
+ stream_step/3 (three-phase Stream.resource state machine), the ALLM.step/3 + 
stream_step/3 facade, and a 100-iteration step-equivalence property proving 
step ≡ stream_step |> collect. Extends StreamCollector with :tool_results and 
:halt fields plus three fold clauses, activates three §31 scenarios (single 
tool call auto, parallel tool calls, handler raises), and renames @phase_7_opts 
to @orchestration_opts. Folds nine retro findings into AGENT_DESIGN_SPEC, 
AGENT_IMPLEMENTATION_SPEC, and CLAUDE.md (sub-phase retro cadence, shared test 
helpers threshold, primitive-vs-composition verification, struct-field 
structural rule, mid-stream error contract, and others). Test suite: 140 
doctests, 17 properties, 726 tests, 0 failures.

---

## [FEAT] Phase 4+5: Fake adapter + generate/stream_generate facade
*Friday, April 24th at 6pm*
Ships Phase 4 (ALLM.Providers.Fake scripted adapter implementing both
ALLM.Adapter and ALLM.StreamAdapter, plus ALLM.Providers.Fake.Script helper
and ALLM.Test.FakeFixtures test-support fixtures) and Phase 5 (Layer C
execution: ALLM.StreamCollector fold state, ALLM.StreamRunner and ALLM.Runner
internal runners, and the ALLM.generate/3 + ALLM.stream_generate/3 public
facade). The :message_completed event payload additively gains an optional
:finish_reason key (tag count stays at 16). The stream-equivalence property
exercises 100 random §31 fixtures asserting generate ≡ stream_generate |>
collect, and three §31 scenarios previously tagged :pending are now active.
622 tests / 132 doctests / 15 properties green; credo --strict, dialyzer,
format, hex.build all clean. See steering/PHASE_4_DESIGN.md, PHASE_5_DESIGN.md,
and spec §3, §4, §8, §10.1, §10.2, §13.1, §17, §19, §20, §30, §31.

---

## [FEAT] Phase 3: Behaviour contracts, defaults, conformance harness
*Friday, April 24th at 1pm*
Hardens the four Layer B behaviours (ALLM.Adapter, StreamAdapter, ToolExecutor, 
ToolResultEncoder) with rich moduledocs, per-callback docs, and 
error-struct-tightened return types. Ships two default implementations — 
ALLM.ToolExecutor.Default with arity-1/2 dispatch and raise/exit/throw 
conversion to %ToolError{}, and ALLM.ToolResultEncoder.JSON with binary 
passthrough plus Jason-backed encoding — both at 100% coverage. Publishes the 
allm_conformance sibling Hex package under conformance/ with four 
ExUnit.CaseTemplate harnesses (47 injected cases across 
Adapter/StreamAdapter/ToolExecutor/ToolResultEncoder), a permanent StubAdapter 
fixture implementing both adapter behaviours, and harness self-tests; main 
project certifies its defaults via a path-dep on the sibling. Three accumulated 
retros drove AGENT_DESIGN_SPEC and AGENT_IMPLEMENTATION_SPEC refinements: §3 
consolidated into a five-class empirical-verification rule (stdlib exceptions, 
project closed-atom enums, stdlib function failure modes on OTP floor, 
macro-expansion-wrapped raises, opaque-term returns) plus hedge-word guidance, 
and §16 now names both conformance shipping shapes with the Shape-B PLT gotcha 
(plt_add_apps: [:ex_unit]) documented. Main suite: 323 → 393 tests, 0 
failures, 0 credo issues, 0 dialyzer errors; conformance sub-project: 55 tests.

---

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

### Phase 9.4 — `ALLM.Capability` + `ALLM.ModelRef` + LLMDB optional gate (spec §6.3)

#### Added
- `ALLM.ModelRef` — new Layer A struct (spec §6.3 lines 637-648). Carries the catalog's view of a single model: `:provider`, `:id`, `:capabilities`, `:limits`, `:pricing` (per-million-token rates), and an opaque `:metadata` bag. Plain serializable data; ETF round-trip is byte-identical, JSON round-trip preserves the outer struct shape with the documented Layer-A nested-map asymmetry (opaque map fields keep STRING keys post-`Jason.encode!/1` → `Serializer.from_json/1`, matching the Phase 1 `Engine.metadata` carve-out). Registered in `ALLM.Serializer.@known_modules`. `__from_tagged__/1` restores `:provider` via `String.to_existing_atom/1`; opaque map fields hydrate as-is.
- `ALLM.Capability` — new Layer B helper (spec §6.3). Three public functions, all gated on the optional `LLMDB` Hex package's load state: `preflight/2` (rejects `request.tools != []` against tools-disabled models with `{[:tools], :tools_disabled}`; rejects `response_format: %{type: :json_schema, ...}` against non-`json_native` models with `{[:response_format], :json_native_disabled}`; both errors accumulate in a single `%ValidationError{reason: :unsupported_capability}`). Pattern-matches both atom-keyed and string-keyed `:capabilities` shapes so JSON-rehydrated `%ModelRef{}` values pre-flight identically to in-process ones. `populate_costs/2` fills `Usage.{input_cost, output_cost, total_cost}` from per-million-token pricing (never overwrites a non-nil cost); tolerates string-keyed pricing maps. `select/1` delegates to `LLMDB.select/1` for capability-based selection. `catalog_loaded?/0` checks `Application.get_env(:allm, :force_capability_absent, false)` BEFORE `Code.ensure_loaded?(Module.concat(["LLMDB"]))` so the dep-free smoke test can simulate catalog absence.
- `ALLM.Error.ValidationError.@type reason` and `@legal_reasons` extended with `:unsupported_capability` (one new atom; surfaces from `Capability.preflight/2` only).
- `test/support/llm_db.ex` — test-only fake catalog mimicking the published `:llm_db` Hex package surface verbatim (no `ALLM.` prefix). Compiled only in `:test` via `elixirc_paths(:test)`. Provides a small fixture catalog covering `openai:gpt-4.1-mini` (tools + json_native + pricing), `local:no-tools` (tools-disabled), and `local:no-json-native` (non-`json_native`).

#### Changed
- `ALLM.StreamRunner.run/3` — pre-flight chain now calls `Capability.preflight(resolved_request.model, request)` after `ALLM.Validate.request/1` and after `Engine.resolve_model/2`. The resolved `%ModelRef{}` (or bare string/tuple) is threaded into opts as `:resolved_model` for downstream `Capability.populate_costs/2` calls. `@phase_5_layer_opts` strip-list extended with `:resolved_model` and `:request_id` (Phase 9 internal — must not leak to adapters).
- `ALLM.Runner.do_run/3` and `ALLM.Chat.transition_a_to_b/1` — populate `Usage` cost fields via `Capability.populate_costs/2` post-collection (not in `StreamCollector` — keeps the collector Layer-A/pure and avoids an LLMDB-loaded conditional inside the fold). Phase 9 design Decision #5.
- `mix.exs` — no `{:llm_db, ...}` line added per Phase 9 design Decision #6 / DoD line 745. Detection is via `Code.ensure_loaded?(Module.concat(["LLMDB"]))` at runtime.

### Phase 9.3 — `ALLM.Retry` (spec §6.1)

#### Added
- `ALLM.Retry` — new internal Layer B helper. `default_policy/0` returns the spec §6.1 closed map (`max_attempts: 3`, `base_delay_ms: 500`, `max_delay_ms: 30_000`, `retry_on: [429, 500, 502, 503, 504, :timeout]`, `jitter_ms: 250`, `respect_retry_after: true`). `materialize/1` accepts `:default | false | keyword()`; unknown keys raise `ArgumentError` (a typo like `max_atempts:` fails loudly). `run/3` invokes a closure under a materialised policy with bounded exponential backoff and additive `[0, jitter_ms]` jitter; emits `[:allm, :adapter, :retry]` per attempt with measurements `%{system_time}` and metadata `%{attempt, delay_ms, reason}` plus caller-supplied `:request_id` / `:provider`. Closure-raised exceptions propagate unchanged (spec §6.1 "exception is not retryable"). The final attempt emits no retry event — the surrounding `[:allm, :adapter, :stop]` span fires instead.
- `ALLM.Providers.Fake` — non-streaming `generate/2` now wraps adapter dispatch in `Retry.run/3` when `adapter_opts: [retry_until_call: n]` is set, returning `{:retry, 0, :timeout}` until the n-th call; the streaming `stream/2` arm does NOT call `Retry.run/3` (spec §6.1 prohibits streaming retries).

#### Notes
- **v0.2 surface caveat** — the public Layer-C entry points (`ALLM.generate/3`, `ALLM.step/3`, `ALLM.chat/3`) all route through `ALLM.StreamRunner` which calls the adapter's streaming callback. Per spec §6.1 streaming calls are not retried, so retry telemetry does not fire from any public façade in v0.2; it fires only when adapters are invoked directly (the Fake retry round-trip). Real-provider Phase 10/11 adapters reuse `Retry.run/3` from their non-streaming `c:ALLM.Adapter.generate/3` callbacks. Documented inline in `ALLM.Retry` and `ALLM.Runner` `@moduledoc`s. See review Finding #3.

### Phase 9.2 — Tool spans (spec §29)

#### Added
- `ALLM.ToolRunner` — per-tool `[:allm, :tool, :start | :stop | :exception]` spans wrap `execute_one_tool/3` inside the `Task.async_stream/5` worker process so `:duration` reflects only that tool's execution and the auto-exception trap captures only that tool's raise (Phase 9 design Decision #9). Metadata: `:tool` (`%ALLM.Tool{}`), `:tool_call` (`%ToolCall{}`), `:engine`, `:model` (lifted from the engine for parity with the other Layer-C spans — review Finding #4 fix), `:request_id` (threaded from the wrapping `:step`/`:chat` span via `opts[:request_id]`); `:stop` adds `:result` (the dispatch tuple). For `Task.async_stream/5`-killed timeouts (`:on_timeout: :kill_task`), the parent process synthesises `[:allm, :tool, :exception]` with `%{kind: :exit, reason: :timeout, duration: 0}` since the killed worker can't reach its `:stop` arm.

### Phase 9.1 — Telemetry spans + `:request_id` correlation (spec §29)

#### Added
- `ALLM.Telemetry` — new internal Layer B helper. `event_prefix/0` returns `[:allm]` (Phase 9 design Decision #15 — uses the project namespace, not the spec §29 `[:llm, ...]` prefix; spec amendment slated as non-blocking follow-up). `request_id/0` produces a 22-character URL-safe Base64 id from 16 cryptographic random bytes. `span/3` wraps a closure in `:telemetry.span/3` under `[:allm, name]` for `name in [:generate, :stream, :step, :chat, :tool]`; raises `ArgumentError` on unrecognised names (typo guard). `execute/3` emits a single non-span event under `[:allm | suffix_path]` (used by `ALLM.Retry`).
- `ALLM.Runner.run/3` and `ALLM.StreamRunner.run/3` — wrapped in `Telemetry.span(:generate, ...)` / `Telemetry.span(:stream, ...)`. Common metadata: `:request_id`, `:engine`, `:model`. `:generate :stop` carries `:response` (the reduced `%Response{}`); `:stream :stop` carries `:response => nil` per the documented carve-out (materialising the wrapped enumerable would defeat consumer-driven laziness — see review Finding #2 and `ALLM.Telemetry.span/3` `@doc`).
- `ALLM.Chat.run/3`, `ALLM.Chat.stream/3`, `ALLM.Chat.step/3`, `ALLM.Chat.stream_step/3` — wrapped in `Telemetry.span(:chat, ...)` / `Telemetry.span(:step, ...)`. `:request_id` is generated at the outermost call and threaded into inner calls via `opts[:request_id]` (Phase 9 Decision #7). `Response.request_id` is populated post-collection so a consumer who never attaches a telemetry handler still has the correlation id on the response.

#### Changed
- `ALLM.Response` — `:request_id` populated post-collection in every Phase-5/6/7/8 path (DoD line 741). The id matches the outermost span's `:request_id` metadata; populated only when the underlying span generated a fresh id (i.e., not when an adapter set `request_id` on the response itself).
- `ALLM.StreamRunner` `@phase_5_layer_opts` — extended with `:request_id` so the telemetry-correlation id is read by this module but stripped from adapter-facing opts.

### Phase 8.4 — Cross-cutting tests + §31 session round-trip activation

#### Added
- `test/allm/session_equivalence_test.exs` — new `StreamData` property test (`@moduletag :property`) asserting `ALLM.Session.start/3 ≡ ALLM.Session.stream_start/3 |> StreamReducer.finalize/1` across 100 iterations over a multi-turn fixture generator (0–2 tool-calls turns + a terminating text turn against the `echo` tool). Each iteration isolates Fake's per-process cursor via `Task.async/Task.await` per `AGENT_IMPLEMENTATION_SPEC.md` §Property tests. Uses the new `assert_equivalent_session_result/2` helper.
- `test/allm/session_status_transition_test.exs` — exhaustive 25-row status-transition matrix test covering every `(status, op)` cell from `PHASE_8_DESIGN.md` §Overview: legal arrows assert post-status; illegal status mismatches assert `ArgumentError` raise; `:error`-state cells assert `{:error, %SessionError{reason: :session_in_error_state}}`; the data-mismatch row asserts `{:error, %SessionError{reason: :unknown_tool_call_id}}` for `submit_tool_result/3` with a stale id.
- `ALLM.Test.Assertions.assert_equivalent_session_result/2` — new test-support helper. Extends `assert_equivalent_chat_result/2` with `s1.status == s2.status`, thread equality (modulo Phase 6 tool-result `tool_call_id` sort), and `pending_*` field equality. `:metadata` is asserted unconditionally — no silent skip. `:id` and `:context` are excluded as identical-by-construction. Accepts both `{Session, ChatResult}` and `{Session, StepResult}` tuple shapes.
- `ALLM.Test.Assertions.assert_session_round_trip/2` — new test-support helper. ETF round-trip asserted unconditionally; Jason round-trip asserted on every `%Session{}` field except those listed in `opts[:exclude]`. `:exclude` defaults to `[]` (full Jason equality) per `PHASE_8_DESIGN.md` §8.4.1 Invariants 1.
- `ALLM.Test.FakeFixtures.manual_multi_turn/2` — new test-support fixture. Accepts a list of `{tool_name, args, tool_result_text}` triples and produces a multi-script Fake-adapter engine driven via `start(mode: :manual) → submit_tool_result × N → continue(nil)`.
- `ALLM.Test.FakeFixtures.ask_user_then_resume/2` — new test-support fixture. Accepts `{question, answer_text}` and produces a two-script engine for the `start → reply(answer)` flow. Caller supplies the ask-user tool handler via `:tools` opt.
- `test/allm/session_roundtrip_test.exs` — added 10 post-operation round-trip rows covering `start/3`, `reply/4`, `continue/3` (with both `%Message{}` and `nil` message), `step/3`, `submit_tool_result/3` (final + intermediate), `submit_tool_results/2`, `:awaiting_user → reply/4` cycle, and `:error`-status mid-stream-error session. ETF round-trip asserted unconditionally; Jason round-trip excludes `:thread` / `:metadata` for post-`Chat.run/3` cases (Message metadata atom keys are not restored on JSON round-trip per the Phase 1 caller-owned-metadata contract).

#### Changed
- `test/allm/providers/fake_scenarios_test.exs` — flipped the §31 session round-trip scenario from `@tag :pending` to active. The activated test exercises `Session.start/3 → :erlang.term_to_binary → :erlang.binary_to_term → Session.reply/4` across a two-script Fake fixture and asserts the resumed thread matches the in-process thread. All 12 §31 scenarios are now active; the moduledoc table is updated.

#### Notes
- **Masking-divergence resolution.** `PHASE_8_DESIGN.md` §8.4.1 reserved a `masking-divergence` row in the relaxation table for `:metadata` between the streaming and non-streaming paths and required a load-bearing fix before Batch 3 ships. Empirical verification (multi-turn / max_turns / manual / ask_user / adapter-error / halt_when fixtures, both arms diffed) found **no metadata divergence**: both paths construct the `%ChatResult{}` via the same `ALLM.Chat.build_chat_result/1` helper (`lib/allm/chat.ex:535`), and `Session.apply_chat_result/2` projects bytewise-identical `cr.metadata` onto both sides. The row is therefore not needed; `assert_equivalent_session_result/2` asserts `:metadata` unconditionally.

### Phase 8.1 + 8.2 — Non-streaming Session API + `ALLM.Session.StreamReducer` + `ALLM.Error.SessionError`

#### Added
- `ALLM.Session.start/3` — new public Layer D function (spec §11). Coerces a `%Session{}` / `%Thread{}` / `[Message.t()]` input via `coerce_session_input/1`, dispatches to `ALLM.Chat.run/3`, and projects the resulting `%ChatResult{}` onto a fresh `%Session{}` via `apply_chat_result/2`. Returns `{:ok, %Session{}, %ChatResult{}}` or `{:error, %EngineError{} | %AdapterError{} | %ValidationError{} | %SessionError{}}`. Phase 8 Decision #2.
- `ALLM.Session.reply/4` — new public Layer D function (spec §11). Sugar for `continue/3` with a `%Message{role: :user}` built from the supplied text. Legal on `:idle`, `:awaiting_user` (clears pending fields), `:completed`. Phase 8 Decision #4.
- `ALLM.Session.continue/3` — new public Layer D function (spec §11). Drives the next adapter turn; accepts `Message.t() | nil`. The `nil` form skips the append and runs on `session.thread` as-is — used for manual-tool-cycle resumption (Phase 8 Decision #4).
- `ALLM.Session.step/3` — new public Layer D function (spec §11). Single-turn entry point dispatching to `ALLM.Chat.step/3`; does NOT loop. Status follows Phase 6 step semantics via `apply_step_result/2`. Phase 8 Decision #6.
- `ALLM.Session.submit_tool_result/3` — new public Layer D function (spec §11, return-type widened per Decision #14). In-process state mutation only — no adapter call. Appends a `:tool`-role message to `session.thread` (encoding map content via `Jason.encode!/1` so the resulting thread passes `ALLM.Validate.thread/1`), drops the matched `%ToolCall{}` from `pending_tool_calls`, flips `status` to `:idle` when the last pending call is submitted. Returns `t()` on success or `{:error, %SessionError{reason: :unknown_tool_call_id}}` on a stale id. Phase 8 Decision #3.
- `ALLM.Session.submit_tool_results/2` — new public Layer D function (spec §11). Batch form folding `submit_tool_result/3` over `[{id, content}]` pairs; first-error-wins short-circuit (no partial mutations) matches `ALLM.Validate`'s hard-reject semantics. Empty list is identity.
- `ALLM.Session.apply_chat_result/2` and `ALLM.Session.apply_step_result/2` — new internal `@doc false def` helpers projecting `%ChatResult{}` / `%StepResult{}` onto a session. Cross-module visibility is required because `ALLM.Session.StreamReducer.finalize/1` calls them (per Phase 8.1.2 "Visibility decision"). Field-source map matches the table in `steering/PHASE_8_DESIGN.md` §8.2.2.
- `ALLM.Session.StreamReducer` — new Layer D module (spec §13.2). Wraps a `%StreamCollector{}` plus the originating `%Session{}` and a `:mode` flag (`:chat | :step`). `new/2` validates `:mode` against the closed set; `apply_event/2` delegates to `StreamCollector.apply_event/2` and never short-circuits; `finalize/1` dispatches per Phase 8 Decision #15 — `:chat` returns `{Session.apply_chat_result(session, cr), %ChatResult{}}` (using `StreamCollector.to_chat_result/1`'s `:cancelled` fallback when no `:chat_completed` was folded), `:step` returns `{Session.apply_step_result(session, sr), %StepResult{}}` for the first observed step or `{session, %ChatResult{halted_reason: :cancelled}}` when no step completed.
- `ALLM.Error.SessionError` — new Layer A error struct (spec §20 atom-vocabulary extension). Closed `:reason` enum: `:session_in_error_state | :invalid_status_for_operation | :no_pending_tool_call | :unknown_tool_call_id`. Mirrors the existing `EngineError` / `AdapterError` shape: `:reason`, `:message`, `:provider` (always `nil`), `:cause`, `:metadata`. Implements `Jason.Encoder` via `ALLM.Serializer.encode_tagged/2` and `__from_tagged__/1`; registered in `ALLM.Serializer.@known_modules` so JSON round-trips. `validate_reason!/1` private helper raises `ArgumentError` on unknown atoms.

#### Changed
- `ALLM.Error.ValidationError.@type reason` and `@legal_reasons` extended with `:invalid_session_input` (one new atom). Surfaces as `{:error, %ValidationError{reason: :invalid_session_input}}` from `ALLM.Session.start/3` and `stream_start/3` (Batch 2) when the second arg is neither `%Session{}` nor `%Thread{}` nor a list of `%Message{}`. Per Phase 8 §Prerequisites — scoped Phase 1 vocabulary extension.
- `ALLM.Session` — `@moduledoc` rewritten to document the Phase-8 status-transition matrix (5 statuses × 5 operations, with status-mismatch raise vs. data-mismatch error tuple), mid-stream error projection (`halted_reason: :error` → `status: :error` + `metadata.error`), the manual-tool-cycle pattern (start `:manual` → `submit_tool_result/3 × N` → `continue/3 nil`), `:context` propagation (caller-wins via `merge_session_opts/2`), and `:session_id` propagation (caller-wins; no opt added when `session.id == nil`). Phase 1 helpers (`new/1`, `append/2`, `append_user/2`, `append_tool_result/3`, `pending_tool_calls/1`, `messages/1`, `__from_tagged__/1`) preserved verbatim.

### Phase 7.5 — `ALLM.chat/3` + `ALLM.stream/3` facade + chat-equivalence property + §31 activations

#### Added
- `ALLM.chat/3` — new public facade function (spec §4, §10.5). Pure one-line delegation to `ALLM.Chat.run/3`; multi-turn non-streaming orchestration. `@doc` covers `:mode`, `:max_turns` precedence chain (Phase 7 Non-obvious Decision #9), `:halt_when` semantics (Decision #11), `:on_tool_error` including the function form (Decision #8), the halt-reason table, and the `:on_event` adapter-only scope (Decision #13). One runnable Fake two-turn doctest.
- `ALLM.stream/3` — new public facade function (spec §4, §10.6). Pure one-line delegation to `ALLM.Chat.stream/3`; multi-turn streaming orchestration emitting exactly one terminal `:chat_completed` event (Decision #3) carrying a `%ChatResult{}` constructed via the same `ALLM.Chat.build_chat_result/1` helper as `ALLM.chat/3` (Decision #4 — chat-equivalence by construction). `@doc` covers single-terminal-event invariant, ask-user thread asymmetry (Invariant 8), and `:on_event` scope. One runnable Fake two-turn doctest asserting exactly one `:chat_completed`.
- `ALLM.Test.Assertions.assert_equivalent_chat_result/2` — new test-support helper. Compares two `%ChatResult{}` values: `:halted_reason`, `:pending_question`, `:pending_tool_call_id`, and `:final_response` exact; `:metadata` modulo `:halt_result` (documented Phase 6/7 streaming-vs-non-streaming gap — see test moduledoc); thread split into non-`:tool` (positional) and `:tool`-role (sorted by `:tool_call_id`); `:steps` element-wise via a private `assert_equivalent_chat_step/2` that strips halt-induced sentinel tool messages from `:tool_results` before comparison.
- `test/allm/chat_equivalence_test.exs` — `StreamData` property test (`@moduletag :property`) asserting `ALLM.Chat.run(engine, thread, opts) ≡ ALLM.Chat.stream(engine, thread, opts) |> Enum.reduce(StreamCollector.new(thread), &apply_event/2) |> StreamCollector.to_chat_result/1` across 100 iterations over eight named fixtures (happy multi-turn, `max_turns: 1`, single-turn text, `halt_when` at step 1, manual mode, ask-user mid-loop, custom halt atom, `on_tool_error: fn _, _ -> {:continue, %{ok: 1}} end`). Each iteration isolates Fake's per-process cursor via `Task.async/1`. The `:on_tool_error_halt` fixture from Phase 7 design 7.5.1 is excluded — see BLOCKER notes in test moduledoc and Batch 4 report.
- `test/allm/allm_chat_test.exs`, `test/allm/allm_stream_test.exs` — facade-level tests covering happy paths, `%EngineError{reason: :missing_adapter}` pre-flight, list-of-messages normalisation, and delegation-invariant equality (both facades under `Task.async/1` to isolate cursor state). Each module registers its own `doctest ALLM` so the `@doc` example runs as part of the test suite.
- `test/allm/providers/fake_scenarios_test.exs` — three §31 scenarios activated: "max_turns cap" (three-turn tool-call script + `chat/3` with `max_turns: 2` → `halted_reason: :max_turns`, `metadata.max_turns == 2`, `length(steps) == 2`), "halt_when fires" (two-turn fixture + `halt_when: fn sr -> sr.tool_results != [] end` → `halted_reason: :halt_when`, `metadata.halt_when_step_index == 0`, `length(steps) == 1`), and "single tool call with `mode: :manual` — partial flow via `chat/3`" (newly added; single-turn tool-call script + `mode: :manual` → `halted_reason: :manual_tool_calls`, `metadata.manual_turn_index == 0`, empty `tool_results`). The two `@tag :pending` placeholders for `max_turns` and `halt_when` were flipped to active. The "session round-trip (Phase 8)" placeholder remains pending. Scenario table in the moduledoc updated to 12 active / 1 pending.

### Phase 7.4 — `ALLM.Chat.stream/3` (multi-turn streaming, internal)

#### Added
- `ALLM.Chat.stream/3` — new internal Layer C entry point (spec §17). Composes `Chat.stream_step/3` enumerables sequentially via a two-phase `Stream.resource/3` state machine (Phase 7 Non-obvious Decision #1) driven by the same `Enumerable.reduce/3` continuation idiom as Phase 6's `stream_step/3`. Emits adapter events + tool events for each turn, one `:step_completed` per turn, then exactly one terminal `:chat_completed` event (Decision #3) carrying a `%ChatResult{}` constructed via `build_chat_result/1` (Decision #4). Ask-user thread asymmetry per Invariant 8: `:step_completed.thread` lacks the question; only `:chat_completed.result.thread` includes it. Cleanup chain: outer `after_fun` halts the active step's continuation, which triggers `stream_step/3`'s own cleanup chain.

### Phase 7.3 — `ALLM.Chat.run/3` (multi-turn non-streaming, internal)

#### Added
- `ALLM.Chat.run/3` — new internal Layer C entry point (spec §17). Multi-turn non-streaming orchestrator composing `Chat.step/3` calls via `Enum.reduce_while/3` over a `%Chat.LoopState{}`. Honours `:max_turns` (call-opts > `engine.params` > `Application.get_env(:allm, :max_turns)` > library default 8 — Phase 7 Non-obvious Decision #9), `:halt_when` (Decision #11), `:on_tool_error` (atom + function forms — Decision #8), and the seven-entry `terminal_condition/5` total order (Decision #5). Halt-reason vocabulary: `:completed`, `:max_turns`, `:halt_when`, `:ask_user`, `:tool_error`, `:manual_tool_calls`, `:error`, plus user custom atoms.
- `ALLM.Chat.LoopState` — new internal Layer C struct (Phase 7 Non-obvious Decision #4). Carries the loop's accumulator (`engine`, `opts`, `initial_thread`, `thread`, `max_turns`, `steps`, `step_index`, `halted_reason`, `halt_metadata`, `pending_question`, `pending_tool_call_id`, `last_response`). Both `Chat.run/3` and `Chat.stream/3` build their `%ChatResult{}` via the single `build_chat_result/1` helper, which takes a `%LoopState{}` — chat-equivalence is established by construction.

### Phase 7.2 — `ALLM.ToolRunner` `on_tool_error` function form

#### Changed
- `ALLM.ToolRunner.run_tool_calls/3` / `stream_tool_calls/3` — `:on_tool_error` `(ToolCall.t(), term() -> {:continue, term()} | :halt)` function form is now active (Phase 6's `ArgumentError` guard relaxed). Function is invoked synchronously inside the per-tool `Task.async_stream/5` task after the handler's return / encoder failure resolves to an error term (Phase 7 Non-obvious Decision #8); `{:continue, replacement}` encodes `replacement` as the tool-result content, `:halt` halts the batch with `halted_reason: :tool_error`. Invalid return shapes and function raises are wrapped as `%ToolError{reason: :invalid_return}` and treated as `:halt` (recursion-avoidance — function not re-invoked on its own failure). Function-arity validation (`is_function(fun, 2)`) raises `ArgumentError` at validation time on wrong arity.

### Phase 7.1 — `ALLM.StreamCollector` extension

#### Changed
- `ALLM.StreamCollector` — struct gains a `:chat_result` field (`ChatResult.t() | nil`). Two new fold clauses (`:step_completed`, `:chat_completed`) inserted immediately before the catch-all per Phase 5 Non-obvious Decision #5: `:step_completed` appends a computed `%StepResult{}` to `state.steps` and resets per-step sub-state (`:current_text`, `:current_tool_calls`, `:tool_call_order`, `:tool_results`, `:halt`, `:finish_reason`, `:raw_finish_reason`, `:error`) so the next step folds cleanly (Phase 7 Non-obvious Decision #6). `:chat_completed` stores the payload's `:result` on `state.chat_result` and sets `state.done? = true`. `to_chat_result/1` extended to prefer the stored `:chat_result` when present and to compute a Phase-7-aware fallback (`:cancelled` for consumer-halted streams, `:error` for mid-stream adapter errors) when absent. `step_done?/1` and `merge_halt_metadata/2` promoted from `defp` to `def` (`@doc false`) for cross-module reuse from `Chat.step_result_from_outer_collector/4` (Phase 7 retro F2).

### Phase 6.3 + 6.4 — `ALLM.step/3` + `ALLM.stream_step/3` facade + step-equivalence property + §31 activation

#### Added
- `ALLM.step/3` — new public facade function (spec §4, §10.3). Pure one-line delegation to `ALLM.Chat.step/3`; accepts either an `%ALLM.Thread{}` or a list of `%ALLM.Message{}` as the second arg. `@doc` carries a runnable Fake + inline tool doctest.
- `ALLM.stream_step/3` — new public facade function (spec §4, §10.4). Pure one-line delegation to `ALLM.Chat.stream_step/3`; returns `{:ok, stream}` where the stream emits adapter events → tool-execution event groups → exactly one terminal `:step_completed`. `@doc` carries a runnable Fake + inline tool doctest.
- `ALLM.Test.Assertions` — new test-support module (`test/support/assertions.ex`, not shipped in the Hex package). Exports `assert_equivalent_step_result/2` which compares two `%StepResult{}` values modulo a `tool_call_id` sort on `:tool_results` and on `:tool`-role thread messages (per PHASE_6_DESIGN.md Non-obvious Decision #9). Every other field (`:response`, `:done?`, non-tool-role thread messages, `:metadata`) is compared by exact `==`.
- `test/allm/step_equivalence_test.exs` — `StreamData` property test (`@moduletag :property`) asserting `ALLM.step(engine, thread, mode: :auto) ≡ ALLM.stream_step(engine, thread, mode: :auto) |> reduce(collector) |> to_step_result/1` across 100 randomly generated tool-call-bearing Fake scripts. A second property at 25 iterations covers mid-execution handler failures (`on_tool_error: :continue`). Each iteration isolates Fake's per-process cursor via `Task.async/1` so the two paths see fresh process-dict cursors. Thread extraction from the `:step_completed` event payload compensates for the `StreamCollector` catch-all no-op on that tag (Phase 7 may add explicit handling).
- `test/allm/providers/fake_scenarios_test.exs` — three Phase 6 §31 scenarios activated as new describe blocks: "single tool call with `mode: :auto`" (through `ALLM.step/3` with an echo tool), "parallel tool calls through `ALLM.step/3`" (two tools, order-independent tool_results assertion), "tool handler raises, `on_tool_error` policy fires" (covers atom forms `:continue` and `:halt`; function form deferred to Phase 7 with an inline comment). The existing `@tag :pending` placeholder for the handler-raises scenario was removed; three `@tag :pending` placeholders remain for Phase 7/8 (max_turns, halt_when, session round-trip). Moduledoc scenario table updated to reflect the 9-active / 3-pending split.
- `test/allm/allm_step_test.exs`, `test/allm/allm_stream_step_test.exs` — facade-level tests covering happy paths, pre-flight `%EngineError{reason: :missing_adapter}`, list-of-messages normalisation, and delegation-invariant equality (both facades under `Task.async/1` to isolate cursor state).

### Phase 6.2 — `ALLM.Chat.step/3` + `ALLM.Chat.stream_step/3` + `StreamCollector` extension

#### Added
- `ALLM.Chat` — new internal Layer C module (spec §17). Ships `step/3` (non-streaming single-turn orchestrator) and `stream_step/3` (streaming variant). Normalises `thread_or_messages` (list of `%Message{}` → `ALLM.Thread.from_messages/1`), validates the thread via `ALLM.Validate.thread/1`, dispatches the adapter call via `ALLM.Runner.run/3` / `ALLM.StreamRunner.run/3`, then branches on `:mode` and `response.finish_reason`. `mode: :manual` + `:tool_calls` surfaces tool calls without executing handlers and sets `StepResult.metadata.mode: :manual` (NOT a halt — Finding F2). `mode: :auto` + `:tool_calls` dispatches to `ALLM.ToolRunner.run_tool_calls/3` / `ALLM.ToolRunner.stream_tool_calls/3`, appends tool-role messages to the thread, and surfaces halt metadata (`:tool_error`, `{:halt, reason, result}`, `{:ask_user, ...}`) via `StepResult.metadata`. Assistant-message construction uses `response.output_text` (collector-authoritative) per PHASE_6_DESIGN.md Non-obvious Decision #10. Ask-user handler returns do NOT append an `:assistant` message with `metadata.ask_user: true` in Phase 6 (Non-obvious Decision #6); that thread mutation is Phase 7's concern. `stream_step/3` composes via a single three-phase `Stream.resource/3` state machine (Phase A drives the adapter stream, Phase B drives `ToolRunner.stream_tool_calls/3`, Phase C emits exactly one `:step_completed` event) — one outer resource, no wrapping (Non-obvious Decision #1). Event sequence invariant: all adapter events → zero-to-N tool-execution event groups → exactly one terminal `:step_completed`. No new `ALLM.Event` variants added. No new error-reason atoms added. Error table inherited from Phase 5 plus `%EngineError{reason: :unknown_tool}` from Phase 6.1.

#### Changed
- `ALLM.StreamCollector` — struct gains two fields (`:tool_results: []`, `:halt: nil`) and three new fold clauses (`:tool_result_encoded`, `:tool_halt`, `:ask_user_requested`) inserted immediately before the catch-all per Phase 5 Non-obvious Decision #5. `:tool_result_encoded` appends a `%Message{role: :tool, tool_call_id: id, content: content, metadata: %{}}` to `:tool_results`; `:tool_halt` and `:ask_user_requested` set `:halt` on first observation (first-halt-wins via `halt: nil` guard on the clause head — subsequent halts fall to the catch-all no-op). `to_step_result/1` now reads `:tool_results` from the struct (was hardcoded `[]`), computes `done?` via `step_done?/1` (`halt != nil or finish_reason in [:stop, :length, :content_filter, :error]` — was derived from `:finish_reason` alone), and merges halt metadata into `StepResult.metadata` via `merge_halt_metadata/2` (`{:halt, reason, id}` → `%{halted_reason: reason, halt_tool_call_id: id}`; `{:ask_user, :ask_user, id, q, o}` → `%{halted_reason: :ask_user, pending_tool_call_id: id, pending_question: q, ask_user_opts: o}`). Per PHASE_6_DESIGN.md §StreamCollector extension, Non-obvious Decision #11, and Invariants 1–7. `:tool_execution_started`, `:tool_execution_completed`, and `:step_completed` stay in the catch-all; Phase 7 may add explicit clauses for `:step_completed`. Totality property still holds across the 16-tag closed union.

### Phase 6.1 — `ALLM.ToolRunner` + `StreamRunner` attribute rename

#### Added
- `ALLM.ToolRunner` — new internal Layer C module (spec §17). Ships `run_tool_calls/3` (non-streaming, returns `{:ok, [Message.t()]} | {:ok, [Message.t()], halt_metadata} | {:error, %EngineError{}}`) and `stream_tool_calls/3` (streaming, returns an enumerable of `ALLM.Event` values — Phase 6 extension to spec §17 per PHASE_6_DESIGN.md Non-obvious Decision #2). Both variants share `execute_one_tool/3` for dispatch + encoding + `on_tool_error` policy. Parallel execution via `Task.async_stream/5` with `ordered: false`, `max_concurrency: max(1, min(length(tool_calls), System.schedulers_online() * 2))` default, `on_timeout: :kill_task`, `zip_input_on_exit: true`; per-tool `tool_timeout` (default 30_000 ms). Unknown-tool pre-flight returns `{:error, %EngineError{reason: :unknown_tool, metadata: %{tool_name: name}}}` synchronously (non-streaming) or a single-element error stream (streaming); no tools execute. Empty `tool_calls` short-circuits to `{:ok, []}` / `Stream.concat([])` to guard against `Task.async_stream/5`'s `ArgumentError` on `max_concurrency: 0`. Handler-return dispatch covers all five spec §5.2 shapes: `{:ok, _}`, `{:error, _}` (policy-routed), `{:ask_user, _}` / `{:ask_user, _, _}` (content `"<awaiting user response>"` per spec §12.3; halt with ask-user metadata), `{:halt, reason, result}` (halt with tool_halt metadata). Encoder failures (`Protocol.UndefinedError`, `Jason.EncodeError`) caught and wrapped as `%ToolError{reason: :encoding_failed}`, then routed through `on_tool_error` (Non-obvious Decision #3). Function form of `on_tool_error` raises `ArgumentError` mentioning Phase 7. Sibling-drain on halt (Invariant 3): `Task.async_stream/5` runs to natural exhaustion on handler halt; first-halt-wins (earliest input-index) for `halt_metadata`. No new `ALLM.Event` variants added. No new error-reason atoms added.

#### Changed
- `ALLM.StreamRunner` — internal module-attribute rename (no behavioural change): `@phase_7_opts` → `@orchestration_opts`, `strip_phase_7_opts/1` → `strip_orchestration_opts/1`, `Logger.debug/1` message "Phase 7 opt" → "orchestration opt", `@moduledoc` section heading "Phase 7 opts are stripped" → "Orchestration opts are stripped". Contents unchanged (`[:mode, :max_turns, :halt_when]`). Phase 6 consumes `:mode` at the `ALLM.Chat` layer (Phase 6.2); StreamRunner's deny-list remains as the safety-net before adapter dispatch. Per PHASE_6_DESIGN.md Non-obvious Decision #5.

### Phase 5.4 — Stream-equivalence property + §31 scenario wiring

#### Added
- `test/allm/stream_equivalence_test.exs` — `StreamData` property test module (`@moduletag :property`) asserting `ALLM.generate/3 == ALLM.stream_generate/3 |> reduce(StreamCollector) |> to_response` across 100 randomly generated §31 scripts. Separate property covers mid-stream `{:error, reason}` equivalence (finish_reason and metadata.error agreement). Each iteration runs `generate/3` and `stream_generate/3` in isolated `Task.async/1` processes so Fake's per-process cursor doesn't collide across the two calls.
- `test/allm/providers/fake_scenarios_test.exs` — flipped three `@tag :pending` placeholders to active tests: pure text streaming with `emit_text_deltas: false`, mid-stream adapter error through `stream_generate/3` + `generate/3`, and consumer cancellation releasing Fake's `:counters` observer. Added a halt-safety-through-filters regression assertion (same 10-event fixture + `emit_text_deltas: false` + `Enum.take(stream, 2)` → observer increments within 500 ms) pinning Phase 5 Non-obvious Decision #6.

### Phase 5.3 — `ALLM.Runner` + `ALLM.generate/3`

#### Added
- `ALLM.Runner` — new internal Layer C module (spec §17). `run/3` delegates to `ALLM.StreamRunner.run/3`, folds the returned stream through `ALLM.StreamCollector.new/0 |> apply_event/2` and emits `{:ok, %Response{}}` via `to_response/1`. Pre-flight errors bubble verbatim; mid-stream `{:error, _}` events fold into `%Response{finish_reason: :error, metadata: %{error: struct}}` per Non-obvious Decision #4 — `run/3` still returns `{:ok, _}` in that case. The `include_raw_chunks: false` filter's usage carve-out (§StreamRunner Decision #9) means the collector always sees `{:raw_chunk, {:usage, _}}` regardless of caller intent, so no Runner-side filter override is needed. `@moduledoc` begins with "Internal — use `ALLM.generate/3` instead." (Non-obvious Decision #10).
- `ALLM.generate/3` — new public facade function (spec §4, §10.1). Pure delegation to `ALLM.Runner.run/3`; `@doc` carries a runnable Fake doctest demonstrating the non-streaming path.

### Phase 5.2 — `ALLM.StreamRunner` + `ALLM.stream_generate/3`

#### Added
- `ALLM.StreamRunner` — new internal Layer C module (spec §17). `run/3` validates (`:missing_adapter` → `:missing_stream_adapter` via `Code.ensure_loaded?/1 + function_exported?(adapter, :stream, 2)` → `ALLM.Validate.request/1`), resolves model/params via `ALLM.Engine`, dispatches to `engine.adapter.stream/2`, and post-processes the returned stream. Post-processing composes `Stream.each/2` (for `:on_event`) with `Stream.filter/2` (for `:emit_text_deltas`, `:emit_tool_deltas`, `:include_raw_chunks`) — no extra `Stream.resource/3` wrap (per PHASE_5_DESIGN Non-obvious Decision #6). `{:raw_chunk, {:usage, _}}` events always pass the filter regardless of `:include_raw_chunks` (usage carve-out per Non-obvious Decision #9). `:on_event` exceptions surface in the consumer's reducing process — no `try/rescue` (per Non-obvious Decision #7). `@moduledoc` begins with "Internal — use `ALLM.stream_generate/3` instead." (per Non-obvious Decision #10).
- `ALLM.stream_generate/3` — new public facade function (spec §4, §10.2). Pure delegation to `ALLM.StreamRunner.run/3`; `@doc` carries a runnable Fake doctest.

#### Changed
- Phase 7 orchestration opts (`:mode`, `:max_turns`, `:halt_when`) are deny-listed at the `StreamRunner` boundary and never reach the adapter — prevents a future `Jason.encode!` trip on a `:halt_when` fun when real provider adapters land (per Non-obvious Decision #11). `Logger.debug/1` fires once per stripped key.

### Phase 5.1 — `:message_completed` finish_reason + `ALLM.StreamCollector`

#### Added
- `ALLM.StreamCollector` — new Layer C module (spec §13.1). Reduces an `ALLM.Event` stream into a `%Response{}` (`to_response/1`, thread-less), `%StepResult{}` (`to_step_result/1`), or `%ChatResult{}` (`to_chat_result/1`). Ships `new/0` (Phase 5 extension per PHASE_5_DESIGN Non-obvious Decision #3), `new/1` (accepts `nil` or `%Thread{}` per Non-obvious Decision #3), and `apply_event/2` with nine explicit per-tag clauses plus a catch-all (per Non-obvious Decision #12). Mid-stream `{:error, _}` events fold into `finish_reason: :error` + `metadata.error: struct` so `to_response/1` never returns `{:error, _}` (per Non-obvious Decision #4). `{:raw_chunk, {:usage, map}}` applies `struct!(ALLM.Usage, map)` — documented pass-through that raises `KeyError` on unknown fields (adapter-side contract).
- `ALLM.Event.message_completed/2` — new arity adding an explicit `finish_reason` argument (`is_atom(fr) or is_nil(fr)` guard). `message_completed/1` now emits `finish_reason: nil` for back-compat.

#### Changed
- `:message_completed` event payload additively gains an optional `:finish_reason` key (`Response.finish_reason() | nil`). Tag count stays at 16; `event?/1` accepts both shapes (with and without the key). See PHASE_5_DESIGN Non-obvious Decision #1 for the back-compat guarantee. `ALLM.Providers.Fake` threads the reason from `{:finish, reason}` script entries into the terminal `:message_completed` event.

### Phase 4 — `ALLM.Providers.Fake` scripted adapter

#### Added
- `ALLM.Providers.Fake` — deterministic scripted adapter (Layer B) implementing both `ALLM.Adapter` and `ALLM.StreamAdapter`. Accepts two disjoint script shapes on `adapter_opts` (spec §31 user-facing and Phase 3 harness), supports multi-call sequencing via a per-process cursor with an explicit Agent-backed override (`start_script_cursor/0` / `cursor_index/1`), honours `{:delay, ms}` / `{:sleep, ms}` for backpressure testing, and exposes a `:cleanup_observer` (`:counters` ref) hook for halt-safety assertions. Passes the 13-case `ALLM.Test.AdapterConformance` and 14-case `ALLM.Test.StreamAdapterConformance` harnesses unchanged. See spec §7.1, §7.2, §8, §20, §30, §31.
- `ALLM.Providers.Fake.Script` — pure helper module (Layer B) for shape detection (`detect_shape/1`), boundary validation (`validate!/1`), non-streaming fold (`fold_to_response/1`), and per-entry event translation (`interpret/1`). Shared interpreter for `:finish` / `:tool_call` tags across both script vocabularies; `:error` disambiguates by tuple arity.
- `ALLM.Test.FakeFixtures` — test-support library (`test/support/fake_fixtures.ex`, not shipped in the Hex package) with eight named `adapter_opts` fixtures: `plain_text/1`, `single_tool_call/2`, `parallel_tool_calls/1`, `multi_turn_conversation/1`, `mid_stream_error/1`, `empty_response/0`, `tool_call_with_streamed_args/2` (codepoint-safe split), and `delayed_text/2`. Per Phase 4 design Non-obvious Decision #10.
- `:no_scripted_response` added to `ALLM.Error.AdapterError.@legal_reasons` (12th reason atom, scoped to testing adapters). Spec §31 preserves the bare-atom form; Phase 1's narrowed `{:error, %AdapterError{}}` behaviour contract carries it on the struct's `:reason` field.
- `test/allm/providers/fake_scenarios_test.exs` — three spec §31 scenarios covered today (pure text streaming with `emit_text_deltas: true`, parallel tool calls, mid-stream adapter error) plus six `@tag :pending` placeholders naming the phase that will cover each deferred scenario. `@moduletag :spec_31` allows `mix test --only spec_31` to scope the audit.

### Phase 3.5 — `allm_conformance` Sibling Package + Harness Wiring

#### Added
- `allm_conformance` — new sibling Hex package (in-repo sub-project at `conformance/`, app `:allm_conformance`, version `0.2.0`). Ships four `ExUnit.CaseTemplate`-based harnesses under the `ALLM.Test.*` namespace (`ALLM.Test.AdapterConformance`, `ALLM.Test.StreamAdapterConformance`, `ALLM.Test.ToolExecutorConformance`, `ALLM.Test.ToolResultEncoderConformance`). Consumer install is one line (`{:allm_conformance, "~> 0.2", only: :test}`); no `elixirc_paths` surgery. See `conformance/README.md` for usage and release checklist. Per PHASE_3_DESIGN.md §Non-obvious Decision #1.
- `ALLM.Test.Fixtures.StubAdapter` — permanent scripted test fixture (in `conformance/test/support/`, not exported) implementing both `ALLM.Adapter` and `ALLM.StreamAdapter`. Drives the harness's own self-tests; script shape documented in its `@moduledoc`.
- 43 conformance self-tests across the sub-project (12 + 6 + 10 + 7 injected cases plus 8 meta-tests covering case-count stability and missing-opt `KeyError`).
- Main project `mix.exs` now declares `{:allm_conformance, path: "conformance", only: :test}` so the two default implementations (`ALLM.ToolExecutor.Default`, `ALLM.ToolResultEncoder.JSON`) certify against the harness: `test/allm/tool_executor/default_test.exs` and `test/allm/tool_result_encoder/json_test.exs` each plug in via `use ALLM.Test.<...>Conformance, ...`.
- `LICENSE` files at the repo root and in `conformance/` (MIT, Pascal Rettig) — prerequisite for `mix hex.build`.

#### Notes
- The design doc's `StreamError` mid-stream reason table named `:truncated | :malformed_chunk | :connection_dropped`, but the Phase 1 committed `ALLM.Error.StreamError` enum is `:adapter_error | :cancelled | :timeout | :malformed_event | :unknown`. The conformance suite uses the committed atoms (`:cancelled` in the self-test case) per `AGENT_DESIGN_SPEC.md §3`'s empirical-verification rule.

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
