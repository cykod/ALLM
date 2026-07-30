# Asks

[PHAS] sat 4/18 2am - Phase ALLM library implementation from v0.2 spec

[DSGN] sat 4/18 11am - Design Phase 1 Layer A hardening for ALLM v0.2

[BUILD] mon 4/20 9pm - Build Phase 1 Layer A hardening (sub-phases 1.1-1.6) from PHASE_1_DESIGN.md

[DSGN] tue 4/21 12pm - Design Phase 2 — Engine + Keys runtime API and key resolution

[BUILD] tue 4/21 1pm - Build Phase 2 (Engine + Keys) sub-phases 2.1-2.4 from PHASE_2_DESIGN.md

[DSGN] tue 4/21 8pm - Design Phase 3 — Behaviours, default implementations, and conformance harness

[MILE] thu 4/23 12pm - Committed Phase 1 + Phase 2 milestone: Layer A data structs, validator, serializer, Engine resolver API, Keys five-level chain, and retro-driven process artifacts

[BUILD] thu 4/23 12pm - Build all phases from PHASE_3_DESIGN.md

[DSGN] fri 4/24 1pm - Design Phase 4 — ALLM.Providers.Fake scripted adapter

[MILE] fri 4/24 1pm - Shipped Phase 3: hardened four Layer B behaviour contracts, shipped ToolExecutor.Default + ToolResultEncoder.JSON at 100% coverage, and published allm_conformance sibling Hex package with 47 injected cases

[BUILD] fri 4/24 3pm - Build phases from PHASE_4_DESIGN.md steering doc

[RETR] fri 4/24 3pm - Retro on current session

[DSGN] fri 4/24 4pm - Design Phase 5: stream_generate, generate, StreamCollector

[BUILD] fri 4/24 4pm - Build all phases from PHASE_5_DESIGN.md

[DSGN] fri 4/24 6pm - Design Phase 6 single-turn tool loop (stream_step/step)

[MILE] fri 4/24 6pm - Shipped Phase 4 Fake adapter and Phase 5 generate/stream_generate facade with stream-equivalence property

[BUILD] fri 4/24 6pm - Build all phases from steering/PHASE_6_DESIGN.md

[BUILD] fri 4/24 6pm - Build all phases from PHASE_6_DESIGN.md

[MILE] fri 4/24 10pm - Committed Phase 6 implementation, retro-driven doc updates, and .gitignore fix

[DSGN] fri 4/24 10pm - Design Phase 7: stream/3 + chat/3 full orchestration loop

[BUILD] sat 4/25 11am - Build Phase 7 (stream/3 + chat/3 multi-turn orchestration) from PHASE_7_DESIGN.md

[MILE] sat 4/25 5pm - Committed Phase 7 multi-turn chat/3 + stream/3 orchestration with chat-equivalence property

[DSGN] sat 4/25 5pm - Design Phase 8: ALLM.Session stateful continuation

[BUILD] sat 4/25 5pm - Build Phase 8 from PHASE_8_DESIGN.md

[MILE] sat 4/25 7pm - Committed Phase 8 ALLM.Session stateful continuation (start/reply/continue/step/submit_tool_result(s) + StreamReducer + SessionError + cross-cutting equivalence and status-transition tests)

[DSGN] sat 4/25 7pm - Design Phase 9: telemetry, capability pre-flight, and retries

[BUILD] sat 4/25 8pm - Build all 4 sub-phases of Phase 9 (telemetry, retry, capability, ModelRef) from steering/PHASE_9_DESIGN.md

[DSGN] sat 4/25 11pm - Design Phase 10 OpenAI provider adapter

[MILE] sat 4/25 11pm - Committed Phase 9: telemetry, retry, capability, ModelRef across 4 sub-phases (1095 tests, 0 failures, 94.79% coverage)

[BUILD] sun 4/26 12am - Build all phases from steering/PHASE_10_DESIGN.md

[DSGN] sun 4/26 1pm - Design Phase 11 Anthropic provider adapter

[MILE] sun 4/26 1pm - Committed Phase 10 OpenAI provider (both endpoints) plus the BYOK leak fix

[BUILD] sun 4/26 3pm - Build all 4 sub-phases of Phase 11 (Anthropic provider adapter) from PHASE_11_DESIGN.md

[MILE] sun 4/26 4pm - Applied Phase 11.3 review Option A resolution + M1 metadata fix and committed cumulative Phase 11.1–11.3 Anthropic provider work

[DSGN] sun 4/26 6pm - Design phase 12 release polish (examples, docs, audit)

[MILE] sun 4/26 7pm - Applied 11 retros into AGENT_DESIGN_SPEC, AGENT_IMPLEMENTATION_SPEC, and CLAUDE.md (12 changes)

[BUILD] sun 4/26 7pm - Build Phase 12 (v0.2 release polish: §31 freeze, case-study translations, docs, release artifacts) from PHASE_12_DESIGN.md

[PHAS] sun 4/26 8pm - Phase the 0.3 release from the v0.2 streaming spec

[MILE] sun 4/26 8pm - Committed Phase 12 v0.2.0 release polish: version bump, ex_doc groups, README Getting Started, §31 audit gate, 4 case-study translations

[DSGN] mon 4/27 1am - Design Phase 13 (v0.3 Phase 1): Layer A image data structs, facade constructor, validator, engine image_adapter field

[BUILD] mon 4/27 10am - Build Phase 13 (v0.3 Layer A image data structs, facade, validator) from PHASE_13_image_layer_a.md

[MILE] mon 4/27 10am - Committed Phase 13 v0.3 Layer A image data structs + facade + validator

[DSGN] mon 4/27 11am - Design Phase 14 (v0.3 Phases 2-5): ImageAdapter behaviour + FakeImages + Layer C public API + telemetry/capability/retry + multimodal content parts

[BUILD] mon 4/27 1pm - Build phases from PHASE_14_image_layer_2_5.md steering doc

[DSGN] mon 4/27 6pm - Design Phase 15 OpenAI Images real-provider adapter

[BUILD] mon 4/27 6pm - Build all 6 sub-phases (15.1–15.6) of PHASE_15_image_layer_6.md — ALLM.Providers.OpenAI.Images

[MILE] tue 4/28 4pm - Shipped Phase 15: ALLM.Providers.OpenAI.Images full operation × model coverage with live-recorded fixtures and BLOCKING examples gate

[DSGN] wed 4/29 2am - Design phases 7-9 of v0.3 (vision in OpenAI/Anthropic + release polish)

[DSGN] wed 4/29 2am - Design Gemini provider with chat and images support

[BUILD] wed 4/29 7pm - Build phases from PHASE_17_image_layer_7.md

[FIX] thu 4/30 8pm - Fix issues from Phase 17.3 review and retro

[MILE] fri 5/1 4pm - Applied nine Phase 15.x + 17.x retros via /apply-retro: 11 deduplicated rules landed in CLAUDE.md, AGENT_IMPLEMENTATION_SPEC.md, and AGENT_DESIGN_SPEC.md

[BUILD] fri 5/1 4pm - Build phases from GEMINI_DESIGN.md steering doc

[DSGN] fri 5/1 4pm - Design Hex release plan for ALLM package (cykod)

[MILE] fri 5/1 5pm - Stamped engine model onto image requests, bundled a real PNG fixture for the image examples, widened drop_request_opts, and bumped run_all per-script timeout

[IMPL] fri 5/1 5pm - Update README.md with more detailed information and examples for each API level (stateless, session, streaming, non-streaming)

[DSGN] fri 5/1 5pm - Design Phase 18 per-tool manual mode (per-tool opt-out from auto-execution)

[DEVL] fri 5/1 5pm - Quick devil review of PHASE_18_DESIGN.md

[DSGN] sun 5/3 1am - Design Phase 20 embeddings (ALLM.embed/3) per §32.5 / RELEASE_0_3_PHASING.md What-Comes-After

[DSGN] sun 5/3 1am - Design Phase 19 audio I/O (ALLM.transcribe + ALLM.synthesize) per RELEASE_0_3_PHASING.md v0.4 candidate

[MILE] sun 5/3 11am - Shipped Gemini provider (Phase 16.1-16.6) with live examples passing — added sanitize_schema, name lookup, thoughtSignature wiring, and StreamCollector metadata preservation

[MILE] sun 5/3 1pm - Fixed 3 failing tests (README section rename, release_polish_test gemini drift) and cleaned up credo warnings/format

[BUILD] sun 5/3 1pm - Build phases from PHASE_18_DESIGN.md steering doc

[ASKS] sun 5/3 1pm - Review Phase 17 (steering/PHASE_17*) and verify all sub-phases are complete

[MILE] wed 5/6 6pm - Shipped Phase 18 (per-tool manual mode) end-to-end across 5 sub-phases — Tool struct field, chat partition (non-streaming + streaming), Session projection, examples + spec + chat-equivalence

[MILE] wed 5/6 8pm - Applied 18 retro lifts to CLAUDE.md + 3 AGENT_*_SPEC.md docs and tracked 3 previously-untracked steering docs (Phase 19/20 designs + release plan)

[BUILD] wed 5/6 9pm - Build all phases from RELEASE_PLAN.md (Hex release tooling)

[MILE] wed 5/6 9pm - Added scripts/release.exs for Hex publish flow and restructured CHANGELOG/HISTORY around the /changelog skill model

[DSGN] thu 5/7 4pm - Design documentation rebuild — remove internal phasing/spec refs, expand examples

[BUILD] thu 5/7 6pm - Build all 14 phases of REBUILD_DOCUMENTATION.md (docstring rewrite, audit script, guides/, README/CHANGELOG/examples/mix.exs prose) with review/retro deferred to end

[MILE] fri 5/8 3pm - Committed REBUILD_DOCUMENTATION rebuild — 14 phases, 85 files, banned-token-clean across 75-file user-facing surface, plus async-safety fix for anthropic_stream_wire_test

[DSGN] mon 5/25 11am - Design Amesbury implementation feedback fixes for ALLM ergonomics

[BUILD] mon 5/25 12pm - Build Phase 21 Amesbury feedback fixes from AMESBURY_IMPLEMENTATION_FEEDBACK.md

[IMPL] mon 5/25 12pm - Implement phases 21.1-21.5 from AMESBURY feedback: validation metadata, Fake :usage/:record, ALLM.Sandbox, ALLM.unwrap, Image.from_data_uri + docs

[CDRV] mon 5/25 12pm - Code review on current session

[RETR] mon 5/25 12pm - Retro on Phase 21 Amesbury feedback sub-phases 21.1-21.5

[FIX] mon 5/25 12pm - Fix issues from Phase 21 Amesbury feedback reviews (overview + code-review + retro)

[MILE] mon 5/25 6pm - Shipped Phase 21 Amesbury feedback rollup with ALLM.Sandbox, unwrap/1, Fake :usage/:record, Image.from_data_uri/1, ALLM.JsonSchema, and guides updates

[MILE] thu 5/28 1pm - Fixed Responses-API streaming usage no-op so gpt-5* total_tokens populates Response.usage

[DSGN] fri 6/26 2pm - Design fix for Providers.Fake content-hash cursor footgun (per-engine identity key)

[BUILD] sat 6/27 1am - Build all 3 phases of engine-identity cursor key fix per steering/20260626_UNLLMTD_FOOTGUN_DESIGN.md

[CDRV] sat 6/27 1am - Code review on Phase 1 of UNLLMTD footgun design: ALLM.Engine serializable :id field

[RETR] sat 6/27 1am - Retro on Phase 1 (ALLM.Engine stable :id) of the UNLLMTD footgun design build

[CDRV] sat 6/27 1am - Code review of Phase 2 (engine-id cursor key) per steering/20260626_UNLLMTD_FOOTGUN_DESIGN.md

[RETR] sat 6/27 1am - Retro on UNLLMTD_FOOTGUN Phase 2 (engine-id cursor_key at chat dispatch chokepoint)

[FIX] sat 6/27 1am - Fix Phase 2 engine-id cursor findings: refresh stale phash2 comments in four façade test files and correct stream_runner put_cursor_key comment

[CDRV] sat 6/27 1am - Code review on Phase 3 engine-id cursor changes per steering/20260626_UNLLMTD_FOOTGUN_DESIGN.md

[RETR] sat 6/27 1am - Retro on Phase 3 (final) of UNLLMTD_FOOTGUN build — image-path cursor fix mirror

[FIX] sat 6/27 1am - Fix issues from Phase 3 (final) engine-id cursor reviews (overview + code-review + security-review + retro)

[ASKS] sat 6/27 2am - Future: re-key FakeImages bump_retry_visits/2 retry-visit counter off phash2(script) onto engine identity (or document the collision as benign) — residual content-hash footgun, scoped out of UNLLMTD Phase 3 (retro F2)

[MILE] sat 6/27 2am - Keyed Fake/FakeImages multi-call cursor on engine identity via a new serializable Engine :id, removing the content-hash cursor footgun at the façade

[DSGN] mon 7/13 12pm - Design ALLM guide-drift doc corrections and Engine.new/1 fail-fast validation fix per steering/ALLM_VERIFIED_FACTS.md

[BUILD] mon 7/13 1pm - Build all 4 phases of Phase 21 (guide-drift corrections + Engine.new/1 fail-fast validation + max_tokens/temperature request-builder fix) from 20260713_ALLM_FIX_DOCS_AND_ERRORS.md

[RETR] mon 7/13 1pm - Retro on Phase 21 Batch 1 (Engine.new/1 validation, guide-drift corrections, doctest_file execution)

[DREV] mon 7/13 1pm - Design-review Phase 21 Batch 1 (Engine validation guard + guide/doctest doc fixes) against reference in steering/20260713_ALLM_FIX_DOCS_AND_ERRORS.md — N/A, backend-only, no renderable front-end or reference design.

[FIX] mon 7/13 1pm - Fix Phase 21 Batch 1 issues from review/code-review/security/retro files, priority guide-drift fix in errors_and_retries.md

[ASKS] mon 7/13 1pm - Convert errors_and_retries.md retry examples to Fake-runnable iex> blocks so they gain doctest_file protection (currently fences, per Phase 21 retro F2)

[ASKS] mon 7/13 1pm - Add a fenced-API denylist check to test/guides_test.exs seeded with retry_policy:, ALLM.Retry.none, retry_on_reasons:, %ALLM.Retry{, image_adapter_opts:, 'tool_executor: {' (Phase 21 retro F2/F3)

[ASKS] mon 7/13 1pm - Add a Fake-scripting cheat-sheet to guides/fakes.md (keyword-not-map tool calls, string-keyed args, apply_event/2 arg order, full-consumption-before-finalize) — Phase 21 retro F4

[CDRV] mon 7/13 1pm - Code review Phase 21 Batch 2 (Phase 4) chat.ex request-param routing per steering/20260713_ALLM_FIX_DOCS_AND_ERRORS.md

[RETR] mon 7/13 1pm - Retro on Phase 21 Batch 2 (Phase 4) — wiring resolved max_tokens/temperature/opaque params onto %Request{} in Chat.build_request/4

[ASKS] mon 7/13 1pm - Optional hardening: also strip :api_key nested inside Engine.new(params: %{...}) so a deliberate misuse can't forward a key onto the wire body (Phase 21 Batch 2 security Finding 1, pre-existing, not widened by the max_tokens fix)

[MILE] mon 7/13 7pm - Fixed silent max_tokens/temperature drop in chat/stream/session request-builder, added Engine.new/1 fail-fast validation, corrected seven drifted guides, and wired guide iex> blocks into doctest_file (Phase 21)

[DSGN] tue 7/28 8pm - Design a provider-neutral embeddings API for ALLM with OpenAI, Anthropic, and Google adapters to support local pgvector stores

[BUILD] wed 7/29 2am - Build Phase 20.1-20.7 text embeddings (Layer A/B/C + OpenAI, Gemini, Voyage adapters + docs) from steering/2026-07-28_EMBEDDINGS_DESIGN.md

[CDRV] wed 7/29 2am - Code review Phase 20.1 Layer A embedding data types against steering/2026-07-28_EMBEDDINGS_DESIGN.md

[RETR] wed 7/29 2am - Retro on Phase 20.1 Layer A embedding data types per steering/2026-07-28_EMBEDDINGS_DESIGN.md

[DREV] wed 7/29 2am - Design review Phase 20.1 Layer A embedding data types against steering/2026-07-28_EMBEDDINGS_DESIGN.md — self-gated N/A, headless Elixir library with no front-end surface

[MILE] wed 7/29 3am - Added Layer A embedding data types (Embedding, EmbeddingRequest, EmbeddingResponse), validator, and serializer registration for Phase 20.1

[IMPL] wed 7/29 3am - Implement Phase 20.2 Layer B embeddings runtime — EmbeddingAdapter behaviour, EmbeddingAdapterError, Engine.embed_adapter, FakeEmbeddings, and the 10-case conformance suite per steering/2026-07-28_EMBEDDINGS_DESIGN.md

[CDRV] wed 7/29 3am - Code review on current session

[DREV] wed 7/29 3am - Design review Phase 20.2 Layer B embeddings runtime against steering/2026-07-28_EMBEDDINGS_DESIGN.md — self-gated N/A, headless Elixir library with no front-end surface

[RETR] wed 7/29 3am - Retro on Phase 20.2 embeddings Layer B build (behaviour, error type, engine field, FakeEmbeddings, conformance suite)

[MILE] wed 7/29 3am - Added EmbeddingAdapter behaviour, EmbeddingAdapterError enum, Engine :embed_adapter field, FakeEmbeddings, and the ten-case conformance suite for Phase 20.2

[CDRV] wed 7/29 4am - Code review Phase 20.3 embeddings Layer C facade, batching, telemetry, capability pre-flight

[DREV] wed 7/29 4am - Design review Phase 20.3 embeddings Layer C facade, batching, telemetry, and capability pre-flight against steering/2026-07-28_EMBEDDINGS_DESIGN.md — self-gated N/A, headless Elixir library with no front-end surface

[RETR] wed 7/29 4am - Retro on Phase 20.3 (Layer C facade, batching, telemetry, capability pre-flight) of steering/2026-07-28_EMBEDDINGS_DESIGN.md

[MILE] wed 7/29 4am - Added ALLM.embed/3 facade with transparent batch chunking, EmbeddingBatch merge, capability pre-flight, and the :embed telemetry span for Phase 20.3

[IMPL] wed 7/29 4am - Implement Phase 20.4 ALLM.Providers.OpenAI.Embeddings — POST /v1/embeddings adapter with pre-flight gates, index-sorted decoder, and wire fixtures per steering/2026-07-28_EMBEDDINGS_DESIGN.md

[CDRV] wed 7/29 1pm - Code review Phase 20.4 OpenAI embeddings adapter against images.ex sibling and embeddings design doc

[RETR] wed 7/29 2pm - Retro on Phase 20.4 OpenAI embeddings adapter build

[DREV] wed 7/29 2pm - Design review Phase 20.4 ALLM.Providers.OpenAI.Embeddings against steering/2026-07-28_EMBEDDINGS_DESIGN.md — self-gated N/A, headless Elixir library with no front-end surface and no reference design

[FIX] wed 7/29 2pm - Fix Phase 20.4 OpenAI embeddings adapter review findings from .work/reviews, code-reviews, security-reviews, design-reviews, and retro

[ASKS] wed 7/29 2pm - [BUG] Port Phase 20.4's error-struct hardening to the image adapters: redact key-shaped tokens in provider messages (openai/images.ex:1069-1070 passes OpenAI's raw 401 text, which echoes an sk-proj- prefix, into a Jason.Encoder-derived struct), sanitize Jason.DecodeError's :data on :cause and stop interpolating inspect(cause) into :message (:1109-1114), and replace the 200-char body_preview in :malformed_response metadata with the body's sorted top-level key list (:1229-1241 and gemini/images.ex:660) — grep -rn 'redact' lib/ hits only the new embeddings module

[ASKS] wed 7/29 2pm - [BUG] :timeout gets 9 HTTP attempts through ALLM.embed/3 and ALLM.generate_image/3 where every other retryable reason gets 3 — the adapter's Retry.run reads opts[:retry] (defaulting to :default, whose retry_on contains :timeout) while the facade sets opts[:retry_policy], so both nested loops retry :timeout and the budgets multiply; fix in the facade plus both image adapters and the embeddings adapter at once (either adapters read opts[:retry_policy] with opts[:retry] as fallback, or the facade passes retry: :no_retry in dispatch_opts)

[ASKS] wed 7/29 2pm - [TEST] Modules carrying iex> examples that no test file declares a doctest for ship a comment that looks like a test — ALLM.Providers.OpenAI.Images is the origin instance (Phase 20.4 wired the equivalent for OpenAI.Embeddings), and the defect recurred one phase later in test/support/ (OpenAITestFixtures, AnthropicTestFixtures), which the original lib/-scoped wording could never have caught. DONE WHEN: every module with an iex> block in BOTH lib/ AND test/support/ has a `doctest` declaration somewhere — i.e. `grep -rl 'iex>' lib/ test/support/` minus the set named in any `doctest ` line under test/ must be empty. Stated as a predicate rather than a directory scope on purpose: the ticket was written from the instance, so it named lib/, and the class is wider.

[ASKS] wed 7/29 2pm - [BUG] Recorder scripts that read System.get_env/1 bare never load the project-root .env, so they report 'KEY not set' in a fully-provisioned checkout and their own diagnostic confirms a false 'no key' premise (this shipped three placeholder fixtures under recorded/ in Phase 20.4); DONE WHEN `grep -L EnvLoader scripts/record_*.exs` comes back empty — port record_openai_embeddings_fixtures.exs's guarded load_dotenv/0 (the is_nil(System.get_env(...)) guard matters: EnvLoader.load/1 calls System.put_env/2 unconditionally, so an unguarded load lets a stale .env override an explicit KEY=... mix run) to every remaining recorder, ideally as a shared scripts/_env.exs that all of them Code.require_file/1. Stated as a grep rather than a count on purpose: Phases 20.4 and 20.5 each fixed one instance and the original 'six of the seven' text rotted silently both times.

[ASKS] wed 7/29 2pm - [REFACTOR] [RE-DATED wed 7/29 7pm — the "BEFORE Phase 20.7" deadline has now EXPIRED: 20.7 shipped with zero `lib/` changes (it could not have actioned this) and the counts below are unchanged at HEAD, so the family IS now a published promise and the old trigger no longer points at anything. NEW TRIGGER, stated as a condition rather than a date so it cannot expire again: **whichever comes first of (a) the next provider adapter of ANY capability landing in `lib/allm/providers/`, or (b) the next minor-version release** — because either one adds copy 9 or freezes 8 into another published shape. Still wants a STAND-ALONE `[REFACTOR]` commit, not a rider on a feature phase. Prior escalation, retained for the record: "ESCALATED wed 7/29 6pm — the deadline in this ticket has now passed UNACTIONED TWICE and the debt got worse exactly as predicted."] Promote byte-identical private helpers duplicated across the provider adapters into lib/allm/providers/support/ before Phases 20.5/20.6 add a seventh copy each: header_value/2, header_value_to_string/1, retry_after_ms/1 and parse_retry_after/1 into a provider-neutral Headers module (ALLM.Providers.Support.Headers), maybe_apply_req_test_stub/2 and maybe_apply_request_timeout/2 into a ReqOpts module (ALLM.Providers.Support.ReqOpts); then point the adapters' naming-parity blocks at the shared modules. CURRENT COUNTS at HEAD, both 20.5 and 20.6 having landed without the promotion: maybe_apply_req_test_stub/2 = 8 copies in lib/, maybe_apply_request_timeout/2 = 8, header_value/2 + header_value_to_string/1 = 6 each, retry_after_ms/1 + parse_retry_after/1 = 6 each. SCOPE ADDITION so the promotion is scoped once rather than twice: 18 helpers are now byte-identical across all three embeddings adapters, and the newly-3-copy set that also belongs in the same commit is fetch_embedding_script/1, sanitize_cause/1, non_neg_int/2, decode_error_body/1, build_metadata/2 and classify_http_error/4 (byte-identity verified by line-range diff, character for character, modulo the provider atom). The directory and the pattern already exist — lib/allm/providers/support/ hosts OpenAIHeaders and GeminiHeaders. AGENT_IMPLEMENTATION_SPEC.md:68 says 'Two implementations IS the trigger — don't wait for three.' DONE WHEN: `grep -rlc 'defp maybe_apply_req_test_stub(' lib/` returns at most one file, and the same for each of the five other Headers/ReqOpts helpers. NOT in scope: Voyage's headers/1, which is deliberately inline at n=1 (see the naming-parity block in lib/allm/providers/voyage/embeddings.ex) — reusing Support.OpenAIHeaders there would inherit its openai-organization branch, which Voyage rejects with a 400.

[ASKS] wed 7/29 2pm - [REFACTOR] ALLM.Providers.OpenAI.ImagesTestHelpers' respond_json/3 and respond_with/4 are now imported by the embeddings test files too — four consumers, half of them non-images — so move them to a capability-neutral test-support module (defdelegate from ImagesTestHelpers keeps the three image test files untouched) before Phase 20.5's Gemini embeddings tests need the same thing

[ASKS] wed 7/29 2pm - [DESIGN] Decide whether an embedding adapter must reject a ragged data[] (vectors of differing lengths) as :malformed_response — no adapter performs a cross-entry length check today, so a ragged body decodes cleanly and ALLM.EmbeddingResponse.dimensions/1 reports the head vector's width; either add the gate plus a deliberately-ragged fixture across 20.4/20.5/20.6, or document at embedding_response.ex:124 that uniformity is unenforced

[MILE] wed 7/29 2pm - Added the OpenAI embeddings adapter with live-recorded wire fixtures, key redaction in the error path, and a fixture-provenance gate for Phase 20.4

[ASKS] wed 7/29 3pm - [BUG] ALLM.Providers.Gemini.classify_error/3 types %AdapterError{}'s :message as String.t() but populates it with Map.get(error, "message", default) straight off the decoded body, so a provider or proxy answering {"error": {"message": 123}} puts a non-binary on a typed field — Dialyzer believes the declaration and proves defensive non-binary arms in downstream consumers unreachable (Phase 20.5's Gemini embeddings redactor had to re-read the message off the raw body to keep its arm both live and visible); coerce at the classifier instead

[ASKS] wed 7/29 3pm - [DESIGN] Gemini's batchEmbedContents returns no usageMetadata at all (a live 200 body carries exactly {"embeddings": [{"values": [...]}]}) and no correlation-id response header, so ALLM.embed/3 against Gemini yields an all-nil %Usage{} and cannot report per-request token cost — decide whether guides/embeddings.md's provider-comparison table should call out usage reporting as a per-provider capability rather than implying it is uniform

[CDRV] wed 7/29 2pm - Code review on current session

[RETR] wed 7/29 2pm - Retro on Phase 20.5 Gemini embeddings adapter build per steering/2026-07-28_EMBEDDINGS_DESIGN.md

[DREV] wed 7/29 2pm - Design-review Phase 20.5 Gemini embeddings adapter front-end against reference in steering/2026-07-28_EMBEDDINGS_DESIGN.md

[FIX] wed 7/29 3pm - Fix Phase 20.5 Gemini embeddings review findings: make the autoTruncate probe assert-and-halt, record a real 400 envelope, test translate_reason/1, convert materialize_text/1 raises to errors, and repair the naming-parity block.

[ASKS] wed 7/29 3pm - [BUG] Jason.encode!/1 raises Protocol.UndefinedError on every embeddings/images adapter error whose :cause is set — sanitize_cause/1 blanks Jason.DecodeError's :data but leaves the STRUCT on :cause, and neither %Req.TransportError{} nor %Jason.DecodeError{} implements Jason.Encoder, so the three transport/decode paths produce a struct whose moduledoc says it 'derives Jason.Encoder and is commonly logged and persisted' but which crashes any downstream app that persists it as JSON on the first network blip; carried not new (committed openai/embeddings.ex, gemini/embeddings.ex, and shipped v0.4 gemini/images.ex all fail identically), so fix in sanitize_cause/1 across all adapters at once (reduce the cause to %{reason: ...} or a string) or in ALLM.Serializer.encode_tagged/2 — verify with: for each adapter, drive a Req.Test transport_error stub and assert Jason.encode!(err) does not raise

[ASKS] wed 7/29 3pm - [DESIGN] Req forwards the custom x-goog-api-key header across a cross-host redirect — remove_credentials_if_untrusted/3 (deps/req/lib/req/steps.ex:2045-2056) strips only the literal authorization header and the :auth option on a host/scheme/port change, and :redirect defaults to true, so a redirect from a caller-configured adapter_opts[:endpoint] proxy carries the Google key onward; inherited verbatim by all three Gemini builders and grants no new capability today (the default endpoint would need a TLS MITM of a Google host, and a configured proxy already receives the key on the initial POST), but library-wide hardening (redirect: false, or an explicit header strip on host change) should land across lib/allm/providers/gemini.ex:211-219, gemini/images.ex:486-500, and gemini/embeddings.ex at once — verify with: grep -Ln 'redirect' the three Gemini request builders must be empty

[ASKS] wed 7/29 3pm - [REFACTOR] metadata.google_status bypasses redact_key_material/1 in the Gemini embeddings error path (gemini/embeddings.ex forwards chat_error.metadata, populated at gemini.ex:406-407,418 as %{google_status: Map.get(error, 'status')}) — defense-in-depth only, since error.status is the bounded google.rpc.Code enum name and Google's key-echo failure mode lands in the sibling error.message which IS redacted, and the OpenAI sibling forwards openai_code/openai_type the same way; if adopted, route provider-supplied metadata VALUES through the redactor in all embeddings adapters at once rather than per-adapter

[MILE] wed 7/29 3pm - Added the Gemini embeddings adapter with unconditional truncated-dimension normalization and a self-asserting live wire probe for Phase 20.5

[IMPL] wed 7/29 5pm - Implement Phase 20.6 of steering/2026-07-28_EMBEDDINGS_DESIGN.md — the Voyage AI embeddings adapter that serves as the Anthropic track, with live-recorded wire fixtures.

[ASKS] wed 7/29 5pm - [BUG] ALLM.Providers.OpenAI.Embeddings.embed/2 raises Protocol.UndefinedError instead of returning {:error, _} when an :input ELEMENT is a tuple — verified 2026-07-29: OpenAI raises where the Gemini and Voyage siblings both return %EmbeddingAdapterError{reason: :invalid_request}, because 20.4's carried-forward fix added a CONTAINER gate (gate_batch_size/2's catch-all for a non-list :input) but no ELEMENT gate, and to_json_body/2 hands request.input to Jason verbatim, so a tuple with no Jason.Encoder raises from inside Req.request/1 past every gate; map and integer elements encode fine and earn a provider 400, which is why the hole survived 20.4's review, and it is a behaviour-invariant-2 violation that ALLM.EmbeddingBatch.dispatch_chunk/2 re-frames as an ArgumentError naming the adapter two layers up. Fix by adding gate_input/2 to openai/embeddings.ex under the same gate_*/2 prefix the other two use (one total clause: is_list(input) and Enum.all?(input, &is_binary/1)) — verify with: ALLM.Providers.OpenAI.Embeddings.embed(%ALLM.EmbeddingRequest{input: [{:a, 1}], model: "m"}, api_key: "k") must return {:error, _} rather than raise. ESCALATED wed 7/29 6pm: with Phase 20.6 shipped, THE EMBEDDINGS FAMILY IS NOW CLOSED AND INTERNALLY INCONSISTENT AT A PUBLIC EXTENSION POINT — two of the three bundled adapters convert and the third raises, on the same input, through the same façade. Re-verified live at HEAD by three independent reviewers (openai: RAISED Protocol.UndefinedError; gemini and voyage: {:error, %EmbeddingAdapterError{reason: :invalid_request}}). Deferring it out of 20.4/20.5/20.6 was correct per CLAUDE.md cross-phase discipline each time, but 20.7 publishes guides/embeddings.md and the CHANGELOG, at which point 'the three embeddings adapters behave identically at the extension point' becomes a documented promise and this stops being a one-line gate and becomes a user-visible bug in a released capability. Do it in or before 20.7. Worth doing alongside: a small table-driven equivalence pass parameterised over the family's three adapters asserting the shared invariants (invariant 2 on malformed input, gate ordering ahead of Keys.fetch!/2, max_batch_size/0 enforcement) — it would have caught this in minutes and would keep catching it; and the 20.6 positive-control test (test/allm/providers/voyage/embeddings_test.exs:249-253, which proves the gate-ordering assertion is not vacuous) is explicitly recommended for retrofit onto 20.4 and 20.5 with no mechanism today to make that happen.

[ASKS] wed 7/29 5pm - [BUG] [RESOLVED wed 7/29 6pm, in the Phase 20.6 fix pass — and the ORIGINAL DIAGNOSIS BELOW WAS WRONG; corrected in place because a well-formed self-scoring ticket that is wrong about its own cause is worse than no ticket] Order-dependent test flake: ALLM.Providers.Gemini.EmbeddingsTest 'keys on the per-call opt only — no ambient switch' (test/allm/providers/gemini/embeddings_test.exs:388) failed with 'Expected exception ALLM.Error.EngineError but nothing was raised' at 'mix test --seed 3333'; confirmed PRE-EXISTING (20.5 code) by reproducing it with the Phase 20.6 Voyage test files removed from the tree entirely. WRONG CAUSE AS FILED: 'test/allm/providers/gemini_test.exs:66 ... and both modules are async: true'. That module is `use ExUnit.Case, async: false` (gemini_test.exs:25); ExUnit runs async modules concurrently and sync modules serially AFTERWARDS, so it cannot overlap the async embeddings module and editing it would have left the race in place. ACTUAL CAUSE: ALLM.Keys.Store is a process-global Agent, and the async: true writers of a :gemini key were test/allm/providers/gemini_vision_test.exs:20 and test/allm/providers/gemini_stream_wire_test.exs:24 — both in a setup with on_exit cleanup, which NARROWS the window rather than closing it and is exactly why the failure was seed-dependent rather than deterministic. The 'OpenAI and Voyage are safe — verified' claim was also false for :openai: test/allm/providers/openai/images_test.exs (async: true) put an :openai key at :1380 against the identical assert_raise at test/allm/providers/openai/embeddings_test.exs:241; test/allm/engine_roundtrip_test.exs:247 was the same shape for :anthropic. FIXED by changing the WRITERS, not the readers (making an asserting test robust would convert a real global-state defect into a hidden one): gemini_stream_wire_test.exs, gemini_vision_test.exs and openai/images_test.exs now scope the key to opts[:api_key], the highest-precedence level of ALLM.Keys' chain; engine_roundtrip_test.exs is declared async: false because its Keys.put/2 is load-bearing there (the assertion is that a RESOLVABLE key does not leak into the serialized engine, and there is no process-local store). DISCRIMINATOR THE ORIGINAL DIAGNOSIS NEVER RAN, and the lesson worth keeping: 'mix test --seed 3333 --max-cases 1' was green while '--seed 3333' was red, which proves a concurrency race between async modules rather than an ordering effect — any bug report naming a concurrency cause must record that experiment plus the `use ExUnit.Case, async:` line of every module it names. Verified: 'mix test --seed 3333' → 0 failures, and 'grep -rn "Keys\.put(" test/' returns only async: false modules. Follow-on, NOT resolved: the gate that would have caught this — a pinned-seed run alongside the random one — is now in the design's standing verification convention (steering/2026-07-28_EMBEDDINGS_DESIGN.md, '## Phases' preamble) but NOT in CLAUDE.md's 'Common commands'; nor is the generalisation of the async-global rule from the two named functions (Logger.configure/1, :telemetry.attach/4) to the mechanism class. Both are CLAUDE.md edits owned by /apply-retro; drafts are in .work/retro/2026-07-29-embeddings-20-6.md.

[CDRV] wed 7/29 5pm - Code review on current session

[RETR] wed 7/29 5pm - Retro on Phase 20.6 Voyage embeddings adapter build

[DREV] wed 7/29 5pm - Design-review Phase 20.6 Voyage embeddings adapter front-end against reference in steering/2026-07-28_EMBEDDINGS_DESIGN.md

[FIX] wed 7/29 6pm - Fix Phase 20.6 Voyage embeddings review findings: fix the async-global Keys.Store race at its four writer sites and correct the flake ticket's diagnosis, add the usage premise guard the design claimed existed, make every claim in the naming-parity block true, and pin a fixed seed in the verification convention.

[ASKS] wed 7/29 6pm - [CHORE] One sweep commit before Phase 20.7 closes the embeddings phase. All four items are out of EVERY Module Tree — which is precisely why none has happened — and all four fit in one commit. (1) scripts/_env.exs: load_dotenv/0 is now byte-identical in three recorders (record_openai_embeddings_fixtures.exs, record_gemini_embeddings_fixtures.exs, record_voyage_embeddings_fixtures.exs) except for the env-var name, so the Rule of 3 trigger is met exactly; landing it closes the ticket above whose predicate `grep -L EnvLoader scripts/record_*.exs` currently returns six of nine. (2) `cd conformance && mix format` — two lines in conformance/lib/allm/test/image_adapter_conformance.ex, red since Phase 14.1 (~6 months, six consecutive phases), never in a Module Tree; 20.3 predicted 20.4/20.5/20.6 would each be forced to confront it and none was, because all three landed their conformance test in the MAIN project instead. 20.5's counter-prediction ('if it is going to be fixed it needs a ticket, not a phase') is now confirmed — this is that ticket. (3) DONE in the 20.6 fix pass: amend the seed-3333 flake ticket's wrong cause. (4) DONE in the 20.6 fix pass: correct the three false prose claims in steering/2026-07-28_EMBEDDINGS_DESIGN.md (the two 'pinned by a test' claims about usage.total_tokens, and the wrong flake diagnosis in 20.6.4) and add the missing usage premise guard. DONE WHEN: items 1 and 2 land — `grep -L EnvLoader scripts/record_*.exs` is empty AND `cd conformance && mix format --check-formatted` exits 0.

[ASKS] wed 7/29 6pm - [REFACTOR] Rename the OpenAI-namespaced test-support modules that are now provider-neutral in fact: ALLM.Providers.OpenAITestFixtures.drop_comment/1 is delegated to by ALLM.Providers.VoyageTestFixtures (test/support/voyage_fixtures.ex:21,71) and Gemini's, and ALLM.Providers.OpenAI.ImagesTestHelpers' respond_json/3 + respond_with/4 are imported by both Voyage embeddings test files (embeddings_test.exs:13, embeddings_wire_test.exs:35) — eight importers across three providers and two capabilities. Naming only, nothing breaks, and the delegation as shipped is the RIGHT shape (a fourth copy of drop_comment/1 would have been wrong, and test/support/voyage_fixtures.ex:11-13 says so). But 'ALLM.Providers.OpenAI.ImagesTestHelpers is the canonical HTTP-stub helper for a Voyage embeddings test' reads as an accident rather than a decision, and the next provider will copy the import without asking. Move to ALLM.Test.FixtureHelpers / ALLM.Test.ReqStub (or ALLM.Providers.Support.TestFixtures) with delegating shims left behind so the image test files are untouched. Supersedes and widens the wed 7/29 2pm ticket that scoped this to respond_json/3 + respond_with/4 alone.

[MILE] wed 7/29 6pm - Added the Voyage embeddings adapter closing the provider family, and fixed four async global-key writers that made the test suite non-deterministic (Phase 20.6)

[CDRV] wed 7/29 6pm - Code review Phase 20.7 embeddings docs/examples/spec wiring on current WIP

[RETR] wed 7/29 6pm - Retro on Phase 20.7 (spec 36, embeddings guide, examples, docs wiring) and the full seven-phase embeddings build

[DREV] wed 7/29 6pm - Design-review Phase 20.7 embeddings docs/examples/spec wiring against the reference design in steering/2026-07-28_EMBEDDINGS_DESIGN.md

[FIX] wed 7/29 7pm - Fix Phase 20.7 embeddings docs/examples/spec review findings from .work/reviews, code-reviews, security-reviews, design-reviews, and retro

[ASKS] wed 7/29 7pm - [BUG] ALLM.Providers.OpenAI.Images sends response_format to dall-e-2 and OpenAI now rejects it — examples/run_all.exs on the OpenAI arm halts at script 10 (10_generate_image.exs) with %ALLM.Error.ImageAdapterError{reason: :invalid_request, message: "Unknown parameter: 'response_format'.", status: 400, openai_code: "unknown_parameter", openai_type: "invalid_request_error"}, originating at lib/allm/providers/openai/images.ex:554 which puts :response_format in the dall-e-2 request body. THIS IS RELEASED v0.4 CODE BROKEN AGAINST THE LIVE API, not a provider-side deprecation, and it is DISTINCT from the documented dall-e-2 404 at script 13 (a7b934b, inherited through PHASE_17.3/18.5) — do not fold the two together: script 13 still 404s independently. It was invisible for multiple phases because CLAUDE.md's blocked-by-pre-existing-failure rule licenses inheriting the arm's recorded verdict ("halts at 13") and each script System.halt(1)s inside run_all.exs's single-VM Task, so a block that moves EARLIER silently un-tests the tail of the arm. Full individual characterization at HEAD, produced by running the scripts past the halt: 01-09 OK, 10 FAIL, 11 OK, 12 OK, 13 FAIL, 14 OK, 15 OK, 16-18 OK. NOT fixed in Phase 20.7 (zero lib/ changes by construction). DONE WHEN: ALLM_PROVIDER=openai mix run examples/10_generate_image.exs exits 0, and a wire test asserts the dall-e-2 request body carries no "response_format" key. Verify the same parameter is not sent on the other image ops (edit/variations) before assuming a one-line fix.

[ASKS] wed 7/29 7pm - [BUG] examples/09_ask_user.exs fails deterministically (3/3) on the Anthropic arm — "FAIL: ask_user pass-1 — halted=:completed q=nil" — a regression against its own committed snapshot examples/RUN_OUTPUT_ANTHROPIC.md:72, which records [OK] 09_ask_user.exs. It halts run_all.exs at script 09 on that arm. CAUSE IS MODEL DRIFT, AND c3451d2 IS EXONERATED — this was tested, not guessed: three conditions x 3 reps against Anthropic, A temperature=0 (current ExamplesHelpers default) FAIL/FAIL/FAIL, B temperature=1.0 FAIL/FAIL/FAIL, C NO temperature at all i.e. the exact pre-c3451d2 wire shape FAIL/FAIL/FAIL. The pre-c3451d2 shape fails identically, so temperature is not the discriminator and c3451d2 ([BUG] Honor max_tokens/temperature in chat/stream/session) did not cause this. ALLM is behaving correctly: the wire body keys are ["max_tokens", "messages", "model", "system", "temperature", "tools"] with max_tokens: 1024 (Anthropic's documented injected default) and tool_choice: nil (correct for :auto on that API), the tool definitions ARE transmitted, and forcing tool_choice: :required makes the ask-user path work 2/2 (halted=:ask_user q="Which city?"). What changed is that claude-sonnet-4-6 under tool_choice: :auto now answers "What's the weather?" directly rather than calling get_weather with empty arguments; the identical script still passes on OpenAI and Gemini. The fragility is the script's first-turn assertion depending on a model choice its own header calls handler-controlled. LIKELY FIX: pass tool_choice: :required on pass 1 in examples/09_ask_user.exs (an examples/ change, not a lib/ one). DONE WHEN: ALLM_PROVIDER=anthropic mix run examples/09_ask_user.exs exits 0 and the assertion no longer depends on the model volunteering a tool call. Do NOT re-file this against c3451d2.

[ASKS] wed 7/29 7pm - [BUG] lib/allm/telemetry.ex's moduledoc is the sole outlier on the embed span's error path and now contradicts two shipped user-facing documents. :27-28 says "[:allm, :embed, :stop] omits embedding_count entirely on the error path — there is no count to report — while still carrying chunk_count", and the event table at :24 says embedding_count appears "on a successful :stop". The code emits it as 0 on BOTH paths — lib/allm.ex:1488 returns {metadata, %{embedding_count: 0, chunk_count: 0}} and the comment at lib/allm.ex:1457-1465 deliberately justifies the 0 ("BOTH measurements are present on BOTH paths"). Measured on the error path: %{chunk_count: 0, embedding_count: 0, duration: ...}. guides/embeddings.md and the CHANGELOG both describe the 0 behaviour correctly, and both render in the same hexdocs set as this moduledoc. Pre-existing from Phase 20.3, and out of scope for 20.7 (zero lib/ changes) per cross-phase bug discipline. DONE WHEN: lib/allm/telemetry.ex:24 and :27-28 match lib/allm.ex:1488 — the table row reads "chunk_count and embedding_count on :stop" with no success/error qualifier, and the paragraph states that both report 0 on the error path. While there: the same table row does not mention that [:allm, :embed, :exception] is the event a missing key produces (Keys.fetch!/2 raises by design), which is now stated in guides/embeddings.md and in the spec.

[ASKS] wed 7/29 7pm - [BUG] ALLM.embed/3's own budget table at lib/allm.ex:1058-1072 understates the :timeout worst case 3x, the same defect the Phase 20.7 review found in guides/embeddings.md and which was fixed there. The table's "Retry :max_attempts (default 3) | per chunk | 150 HTTP requests" row and its "opts[:request_timeout] | per chunk | 50 x the value" row both ignore the NESTED retry loop: each adapter runs its own ALLM.Retry.run/3 with the default policy (retry_on: [429, 500, 502, 503, 504, :timeout], lib/allm/retry.ex:143) at openai/embeddings.ex:525, gemini/embeddings.ex:673, voyage/embeddings.ex:752, and the facade wraps a second widened one at lib/allm.ex:1348 and :1449. :timeout is a member of BOTH lists, so the budgets multiply to 9 attempts per chunk (450 requests for the 50-chunk worked example, and 450 x the request_timeout value) against 3 for every other retryable reason. lib/allm/providers/openai/embeddings.ex:137-141 already documents the multiplication verbatim; the facade @doc never mentions the inner loop. DOC-ONLY FIX — do NOT change the retry behaviour here, that is the separate [BUG] ticket above about :timeout getting 9 attempts. The same omission is present in ALLM.generate_image/3's equivalent table if it has one; check before closing. DONE WHEN: lib/allm.ex's "Retry and time budgets are PER CHUNK" section names the nested loop and gives both numbers, matching guides/embeddings.md's "Retry and time budgets are per chunk" section.

[ASKS] wed 7/29 7pm - [BUG] ExamplesHelpers.image_engine/1 reads ALLM_MODEL (examples/_helpers.exs:169), so the invocation examples/README.md documents as supported — ALLM_MODEL=gpt-4.1-mini mix run examples/run_all.exs — sends a CHAT model id to /v1/images/generations and breaks scripts 10, 11, and 13. Phase 20.7 fixed exactly this hazard for embeddings by giving embedding_engine/1 its own ALLM_EMBEDDING_MODEL variable (a chat model id on /v1/embeddings is a guaranteed 400) and documented it in the README's ## Models section; image_engine/1 was left on the shared variable and is the remaining instance. Pre-existing from Phase 15.6, out of 20.7's scope. DONE WHEN: image_engine/1 reads ALLM_IMAGE_MODEL with the row's :image_default_model as the default, mirroring embedding_engine/1 byte-for-byte modulo the variable name, AND the three per-provider image defaults plus one ALLM_IMAGE_MODEL=... example are added to examples/README.md's ## Models section alongside the embedding ones. Note this ticket cannot be verified live on the OpenAI arm until the dall-e-2 response_format 400 above is fixed.

[ASKS] wed 7/29 7pm - [TEST] No probe arm has ever sent max_batch_size() + 1 inputs to a LIVE embeddings provider, so the "Inputs per request: 2048 / 100 / 1000" row that guides/embeddings.md now publishes to users is backed by published vendor docs only. This is the one row in that table the LIBRARY computes with rather than merely reports: max_batch_size/0 is the arithmetic ALLM.EmbeddingBatch chunks by, so the failure modes are asymmetric and both silent — a cap set too HIGH means ALLM does not chunk and the provider 400s a call the guide promised would work; a cap set too LOW means ALLM over-chunks and the user pays for extra round-trips forever. Current evidence: examples/17_embed_batch_chunked.exs at 250 inputs proves Gemini's 100 EXACTLY (chunk_count=3) and proves OpenAI's 2048 and Voyage's 1000 only as ">= 250". Conformance case 3 exercises max_batch_size() + 1 but only against FakeEmbeddings and the scripted stubs — no I/O, by design. PROPOSED: one probe arm per adapter in scripts/record_<provider>_embeddings_fixtures.exs sending max_batch_size() + 1 one-character strings and asserting a 4xx, recording the 400 body as a real :batch_too_large envelope (no fixture in the tree currently is one). Cost is well under a cent per provider — 2049 one-character inputs. DO NOT RUN IT SPECULATIVELY: it needs a maintainer who has decided to spend the quota. DONE WHEN: each of the three recorders has a max_batch_size()+1 arm whose recorded fixture carries a real provider 4xx body, and the guide's cap row cites the probe rather than vendor docs.

[ASKS] wed 7/29 7pm - [TEST] Add an eleventh case to ALLM.Test.EmbeddingAdapterConformance binding the error-struct-hygiene invariant. The Phase 20.7 security review filtered this as a non-finding (its whole locus was a steering doc that does not ship in the Hex package, and all three bundled adapters implement redaction in code) but recommended it as follow-up, and the spec's §36.3 invariant list has since been extended to seven with invariant 7 stating the obligation and explicitly flagging that the conformance suite does not yet assert it. The gap that matters: §36 is the contract a THIRD-PARTY embedding-adapter author implements against, and "never copy a raw response body, a request header, or an Authorization value into :cause, :metadata, or :message" is invisible from the callback signatures — an author who stuffs a %Req.Response{} into :cause passes all ten current cases. PROPOSED CASE: drive the adapter under test to an error with a recognisable sentinel api_key (e.g. "sk-CONFORMANCE-SENTINEL-0123456789") and assert Jason.encode!(error) contains no substring of it, and that the encode does not raise. NOTE the second half interacts with the open ticket about Jason.encode!/1 raising Protocol.UndefinedError when :cause holds a %Req.TransportError{} or %Jason.DecodeError{} — that ticket should land first or the new case will fail on the bundled adapters for an unrelated reason. DONE WHEN: the suite reports eleven cases, spec §36.3 invariant 7 drops its "documentary in v0.5" qualifier, and §36.8's enumeration is updated from ten.

[ASKS] wed 7/29 7pm - [DOC] lib/allm/providers/fake_embeddings.ex:28-40's own moduledoc example leads with the script entry shape guides/embeddings.md now explicitly warns about: it scripts {:error, %ALLM.Error.EmbeddingAdapterError{reason: :rate_limited}} followed by {:retry_until_call, 3}. Through ALLM.embed/3 the facade's widened retry policy CONSUMES a scripted retryable error, retries, and — if the script runs short — surfaces reason: :unknown with metadata.cause :no_scripted_embedding instead of the :rate_limited the reader expected. This was discovered while writing the guide's error-path doctest in Phase 20.7 (six phases of tests over the same module never hit it, because every one was written by someone who already knew the retry policy), and the guide now states the rule and points at {:retry_until_call, n} as the entry for exercising retries. The canonical test vehicle's canonical example still teaches the confusion. lib/ change, out of 20.7's scope. DONE WHEN: fake_embeddings.ex's moduledoc example either scripts a NON-retryable reason (:invalid_request) or keeps :rate_limited with one sentence naming what the facade does to it — i.e. the moduledoc and the guide agree. The same paragraph is worth adding to the script-entry @doc.

[MILE] wed 7/29 6pm - Added embeddings spec section 36, the embeddings guide with a pgvector worked example, and live-verified examples 16-18 across all three provider arms (Phase 20.7)

[ASKS] thu 7/30 2am - Applied 16 unapplied retros into CLAUDE.md, AGENT_DESIGN_SPEC.md and AGENT_IMPLEMENTATION_SPEC.md — async-global foot-gun class, provider wire probe, live-gate discipline, fail-open audit literals, and two approved cross-phase carve-outs
