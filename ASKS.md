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
