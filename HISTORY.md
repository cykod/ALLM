## [OTHR] Close Phase 22's out-of-tree debt — redaction, guide parity, false claims (Phase 22.7)
*Thursday, September 3rd at 7pm*
Seventh and last batch of Phase 22: the `[CHORE]` sweep that closes the phase's 
own debt inside the phase rather than filing tickets that outlive it. It 
deliberately edits released code, which its Module Tree scopes.

- Redact key material in `ALLM.Providers.OpenAI.Images` and 
`ALLM.Providers.Gemini.Images`, and drop `body_preview` from their error 
structs. Those structs derive `Jason.Encoder` and downstream apps persist them, 
so raw provider messages and 200-character body previews in them were a real 
exposure. Redaction sits at the single `to_image_adapter_error/4` funnel every 
non-2xx routes through, so it cannot be bypassed by adding a status, and each 
provider carries its own pattern — applying OpenAI's regex to a Gemini 
credential returns it unchanged, which is the silent no-op the companion tests 
now make fail loudly.
- Route Gemini's `promptFeedback.blockReason` through the redactor too. It 
arrives on a 200 body, structurally off the error funnel, and reached 
`:message` and `metadata.block_reason` raw.
- Add `@guides` parity meta-tests asserting `mix.exs` `docs[:extras]`, 
`test/guides_test.exs`'s literal, and `Path.wildcard/1` over `guides/` name the 
same set in both directions, with an explicit `@excluded` map. This registers 
`guides/fakes.md` for the first time: it was in `mix.exs`'s list and not the 
test's, so it shipped to hexdocs with zero `iex>` blocks and four banned-token 
hits, gated by nothing.
- Correct a false claim about corrupted verdicts at both remaining sites — 
`ALLM.ModerationResult`'s moduledoc and spec §39. A tampered `flagged` decodes 
to `false` beside a fully populated category map; `__from_tagged__/1` decodes 
those fields independently, so the repair is silent rather than self-announcing.
- Strike two false claims from CLAUDE.md and, on review, two more that replaced 
them. The bullet had promised a fenced-API denylist that never existed; the 
replacement then asserted fences get "no gate of any kind" (the banned-token 
audit is line-based and does scan fence text) and dated `fakes.md` to Phase 16 
(it was Phase 21, `85f45d8`). Each correction now carries the command that 
settles it.

The reviews' own finding was that the code here was held to a 
measure-don't-assume standard and the prose written about it was not — two 
lanes reached that independently, and the fix pass then corrected three of the 
reviews' figures the same way, including one wrong impact claim: 
`Exception.message/1` wraps the error from a sanitized decode cause rather than 
crashing the caller.

---

## [DOC] Document content moderation — spec §39, guide, examples (Phase 22.6)
*Thursday, September 3rd at 7pm*
Sixth batch of the Phase 22 moderation family: the capability becomes 
discoverable. Code landed in 22.1–22.5; this is the layer a user actually 
meets.

- Add spec §39 (Content moderation) in ten subsections mirroring §36, plus 
stamped amendment blocks on §27 (module tree), §29 (telemetry) and §35.7 
(bundled-adapter rule). §39.3 reproduces the behaviour's ten invariants in the 
module's own frozen order rather than renumbering them into §36's shape — 
conformance case names cite them by number.
- Add `guides/moderation.md` and register it in all three `@guides` literals, 
so `doctest_file/1` executes its examples rather than letting them rot. Prefer 
`iex>` throughout: 13 executable blocks against `FakeModeration`, 5 fences 
reserved for what a doctest genuinely cannot run (a live key, a nonexistent 
file, an external metrics module, ExUnit's `assert_receive`).
- Add `examples/19_moderate_text.exs` and `20_moderate_image.exs` with `# 
Provider: openai` markers, so `run_all.exs` scopes them to the one arm that has 
an adapter instead of halting the other two. Both cost $0.00 — the endpoint 
is free — and the image script inlines its PNG as a data URI, so it needs no 
third-party host.
- Extract `capability_engine/2` in `examples/_helpers.exs` and migrate 
`image_engine/1`, `embedding_engine/1` and the new `moderation_engine/1` onto 
it in the same edit. Behaviour-preservation measured across a 36-probe matrix; 
the diff is empty once the unique engine id is normalized.
- Fix the guide's flagship screening recipe, which did not compile: it 
referenced a `with`-clause binding inside `else`, where Elixir does not expose 
it. Found by all three review lanes and reproduced before fixing. Converted to 
an `iex>` doctest rather than repaired as a fence — the example runs on Fake 
with no key, so it should never have been a fence, and conversion is what stops 
the next edit breaking silently.
- Correct a false claim about corrupted verdicts. The docs said a repaired 
`flagged` announces itself via empty `:categories`/`:category_scores`; 
`__from_tagged__/1` decodes those fields independently, so a tampered payload 
decodes to `flagged: false` beside a fully populated map. The guide now says 
the repair is silent and tells the caller to validate before decoding. Two 
further copies of the same claim, in the spec and in `ALLM.ModerationResult`'s 
moduledoc, are routed to 22.7 so the normative source and its derived copy move 
together.

The OpenAI examples arm was re-characterized rather than inherited: it halts at 
script 10, not 13. Run individually past the halt, 01–09 OK, 10 FAIL, 11–12 
OK, 13 FAIL, 14–20 OK — both failures resolve to their own existing 
tickets, so no new bug was filed and `RUN_OUTPUT_OPENAI.md` was left untouched.

Not released. `mix.exs @version` stays at 0.5.0; the v0.6.0 CHANGELOG entry is 
staged for a release the maintainer runs deliberately.

---

## [BUG] Stop unreadable image files crashing every vision adapter
*Wednesday, September 2nd at 2pm*
An `%ALLM.Image{source: {:file, path}}` whose file cannot be read raised out of 
`generate/2` and `stream/2` on all four vision translators instead of returning 
an error tuple — a missing file passed both the MIME and the size gate and 
then died in the translator. All four were reproduced before any code changed.

- Fix at the shared gate: `ImageMime.check_byte_size/1` no longer folds "cannot 
read the bytes" into "no size objection". It returned `:ok` on a resolution 
failure, which answers the size question honestly but was read downstream as 
"the bytes exist"; it now returns `{:error, {:unresolvable_image, reason}}`. 
One edit covers OpenAI's and Anthropic's `generate/2` and `stream/2` via 
`validate_request/2`, and both OpenAI endpoints, since the gate runs ahead of 
endpoint dispatch.
- Gemini keeps its own gate — `validate_request/2` accepts only `:openai | 
:anthropic` — so `check_part_source/1` gained a readability clause returning 
`AdapterError` `:invalid_request`, distinct from its siblings' 
`:unsupported_feature` because the `{:file, _}` shape is supported and this 
file just is not there.
- Drop `ALLM.Providers.OpenAI.Moderation`'s local `resolvable?/1`, added days 
earlier for the same defect, now that the shared helper covers it. Its premise 
guard went red on the change — which is what a premise guard is for — and 
was rewritten to assert the new premise.
- Deliberate widening beyond the crash fix: an undecodable `{:base64, _}` 
source is now rejected locally rather than forwarded for the provider to 400 on.
- The translators stay total only over what the gate admits and still raise on 
a direct call. That is the position the moderation adapter already took, and it 
is now asserted on purpose so the gate is not "simplified" away on the belief 
the translator is safe alone.

Eight tests across the four vision suites, each verified by mutation.

---

## [FEAT] Add image input to the OpenAI moderations adapter (Phase 22.5)
*Wednesday, September 2nd at 2pm*
Fifth batch of the Phase 22 moderation family: `%ALLM.ImagePart{}` items reach 
`/v1/moderations` as multimodal content blocks. The cardinality rule the design 
rests on was confirmed on the live wire and recorded.

- Translate an image-bearing `:input` into OpenAI's content-block array via 
`to_openai_content_blocks/1` + `part_to_block/1`; an all-strings `:input` still 
emits the bare string array, so the 22.4 path is untouched. A `{:url, _}` 
source forwards its URL verbatim and is never fetched locally; every other 
source is inlined as a `data:` URI.
- Add gate 3 (`gate_images/2`), which fires ahead of `ALLM.Keys.fetch!/2` like 
its siblings and converts all five ways an item can fail to reach the wire into 
`:invalid_request` with the offending index on `metadata` — never widening 
the callback's error union (§39).
- Confirm the multimodal cardinality rule live: two content blocks in, exactly 
one `results` entry back, with six of thirteen categories listing `"image"` in 
`category_applied_input_types` — so the image was classified rather than 
ignored. Recorded at `recorded/multimodal_text_image.json`; the recorder now 
asserts the count and halts the pass if it ever changes.
- Record `ALLM.ImagePart.detail` as dropped and, after a paired live companion 
arm, as unresolvable at this endpoint: it 200s unknown fields, so acceptance is 
not evidence. A six-assertion contract test, not the wire, is what holds the 
decision.
- Fix-pass corrections after the four review gates: a `{:file, path}` image 
whose file is unreadable raised `MatchError` through the façade, and an 
off-shape item beside an image raised `FunctionClauseError` on a direct adapter 
call — both invariant-2 violations, both now gated. Stop logging the `detail` 
drop for the default `:auto`, matching Gemini. Each fix verified by mutation.

---

## [FEAT] Add OpenAI /v1/moderations adapter with a live wire probe (Phase 22.4)
*Tuesday, September 1st at 12am*
Fourth batch of the Phase 22 moderation family: the real provider adapter,
a self-asserting live wire probe, and eight fixtures. Text input only —
image input is 22.5.

- Add `ALLM.Providers.OpenAI.Moderation` against `POST /v1/moderations`,
  targeting `omni-moderation-latest`. Gates fire in behaviour-invariant
  order — empty input, then batch size, then key resolution — so a keyless
  environment observes a clean rejection rather than a missing-key error
- Add `scripts/record_openai_moderation_fixtures.exs`, a four-part probe
  (negative control, assert-don't-narrate halt, body recording, overwrite
  guard). It ran live at $0.00: the endpoint is free
- Settle `max_batch_size` empirically. A ladder over 1, 32, 100, 128 and
  1000 inputs returns 200 with a matching result count at every rung, so the
  constant is 1000 and is documented as a FLOOR, not a provider-stated cap —
  no upper bound was found
- Confirm on the wire that `text-moderation-latest` is gone: it answers
  "Invalid value for 'model'", recorded as a fixture. The design's decision
  to ship omni-only, which contradicted the literal request, is now backed by
  the live API rather than only by the deprecations table
- Record that the negative control came back POSITIVE — the endpoint ignores
  unknown top-level fields rather than rejecting them. The consequence is
  propagated through the wire-field map: at this endpoint request acceptance
  can never confirm a field's membership, only a response observable can.
  The probe arm was inverted to guard the opposite transition
- Fix two recorder defects found in review: the ladder's verifier never
  compared the result count it was named for, and `--probe-only` wrote
  fixtures while printing that it had written nothing
- Bind the gate-ordering proof against a false pass. The keyless test was
  silently vacuous when OPENAI_API_KEY was exported — which is the shell the
  Verification block prescribes — so a positive control was added, mirroring
  the Voyage sibling

Review artifacts live under `.work/`, which is gitignored.

---

## [FEAT] Add ALLM.moderate/3 facade with telemetry and capability gate (Phase 22.3)
*Monday, August 31st at 9pm*
Third batch of the Phase 22 moderation family, and the one that makes
moderation callable: `ALLM.moderate(engine, text)` now returns
`{:ok, %ALLM.ModerationResponse{}}` end to end over
`ALLM.Providers.FakeModeration`. The real OpenAI adapter lands in 22.4.

- Add `ALLM.moderate/3` and `ALLM.moderation_request/2`. Four gates fire in
  a fixed order inside the telemetry span: adapter-presence (a pattern match
  in the first clause, so a missing adapter never surfaces as a request
  problem), validation, capability pre-flight, then a retry-wrapped dispatch
- Enforce adapter contract invariant 2 at the facade: a `moderate/2` that
  returns anything but the two documented tuples raises `ArgumentError`
  naming the offending module, rather than being laundered into the error
  union. The published conformance suite deliberately cannot bind this — the
  raise is the only thing that does
- Add the `[:allm, :moderate, :*]` span with `result_count` and
  `flagged_count` measurements present on both the success and error paths,
  and `usage: nil` on `:stop`, so a handler written against `:embed` does
  not `KeyError` when pointed at `:moderate`
- Add `ALLM.Capability.preflight_moderation/2` — inert without the optional
  `llm_db` catalog, per the late-model-resolution rule
- Bind the capability gate with a test. Both reviewers found independently
  that deleting the pre-flight call from the facade left the entire suite
  green; the released `embed/3` has the same gap and is filed as a [CARRY].
  The fix is mutation-verified in both directions
- Extract `reject_when_flag_false/4` and migrate all four capability-flag
  checks (vision, images, embeddings, moderation) to it in the same edit.
  Removing one tolerance arm turns four tests red across all four
  capabilities, so the behaviour-equivalence pin is real

Review artifacts live under `.work/`, which is gitignored.

---

## [FEAT] Add moderation adapter behaviour, engine slot, Fake, and conformance (Phase 22.2)
*Monday, August 31st at 8pm*
Second batch of the Phase 22 moderation family: the Layer B runtime contract,
its reference implementation, and a published conformance harness. Spans both
Mix projects. No facade yet — `ALLM.moderate/3` lands in 22.3.

- Add the `ALLM.ModerationAdapter` behaviour: `moderate/2`,
  `max_batch_size/0`, and optional `prepare_request/2`, with ten numbered
  invariants. Invariants 5 and 6 require the empty-input and batch-size gates
  to fire before any I/O *and* before `ALLM.Keys.fetch!/2`, so a keyless
  environment observes the rejection rather than a missing-key error
- Add `:moderation_adapter` to `ALLM.Engine` at all eight sites, including
  the three hand-maintained `@doc` prose lists that duplicate module
  attributes and that a grep for the attribute name misses
- Add `ALLM.Providers.FakeModeration` — a deterministic scripted adapter with
  a four-shape vocabulary including `{:flagged, categories}`, which has no
  embeddings counterpart and makes "assert the app rejects flagged content" a
  one-liner. Gates fire ahead of script consumption
- Add `ALLM.Test.ModerationAdapterConformance` (ten cases) plus its stub and
  self-test. Every case sizes its input from the adapter's own
  `max_batch_size/0` rather than a literal, so the published suite can certify
  a third-party adapter with any cap; verified red against nine deliberately
  non-conforming stubs, each on the case owning the violated invariant
- Fix a cursor defect found independently by the code and security reviews:
  `bump_retry_visits/2` keyed the retry-visit counter on
  `:erlang.phash2(script)` while the cursor slot honoured the documented
  three-source precedence, so two engines with distinct ids and content-equal
  scripts got separate cursor slots but a *shared* retry budget. The same
  defect is inherited in the released `FakeEmbeddings` and `FakeImages`
  siblings and is filed as a [CARRY] rather than fixed cross-phase

Review artifacts live under `.work/`, which is gitignored.

---

## [FEAT] Add Layer A moderation data types and validator (Phase 22.1)
*Monday, August 31st at 7pm*
First batch of the Phase 22 moderation capability family: the Layer A
serializable foundation for screening user-generated content against
OpenAI's free /v1/moderations endpoint. Implements the Layer A half of new
spec §39 (Content moderation); §39 itself lands in 22.6. There is
deliberately no adapter, behaviour, engine slot, or facade yet — those are
22.2-22.4.

- Add `ALLM.ModerationRequest`, `ALLM.ModerationResult`,
  `ALLM.ModerationResponse`, and `ALLM.Error.ModerationAdapterError` —
  plain serializable structs round-tripping through both ETF and JSON, all
  four registered in `ALLM.Serializer`'s `@known_modules` allowlist and in
  `mix.exs` docs groups
- Keep the per-category maps provider-shaped and string-keyed rather than
  normalizing to a cross-provider atom taxonomy: OpenAI spells categories
  `"self-harm/intent"`, which is not a bare atom, and deriving atoms from
  provider-controlled keys would grow the atom table from untrusted input.
  `:provider` decodes through `Serializer.to_atom_field/1`
  (`String.to_existing_atom/1`), never `String.to_atom/1`
- Add `ALLM.Validate.moderation_request/1` with an exhaustive five-row
  field-error vocabulary and a hard-reject short-circuit on a non-list
  `:input`. The `item()` union accepts `%ALLM.ImagePart{}` from the start
  so the image path in 22.5 changes no Layer A or validator code
- Extend two closed enums — `:no_moderation_adapter` on `EngineError` and
  `:invalid_moderation_request` on `ValidationError` — editing both the
  `@type` union and the runtime `~w()a` literal in each
- Extract `validate_input_non_empty/2` and `validate_model_field/2` as
  capability-neutral shared helpers, migrating the embeddings and
  moderation call sites in the same edit: the moderation rules had shipped
  as byte-identical clones of their embeddings twins

Review artifacts for this batch live under `.work/`, which is gitignored,
so they are not part of this commit.

---

## [OTHR] Move agent specs into agent-spec/ and rewrite references
*Monday, August 31st at 2pm*
Migrated the three root-level AGENT_*_SPEC.md files to the agent-spec/ layout 
the pipeline skills now read from: AGENT_DESIGN_SPEC.md, 
AGENT_IMPLEMENTATION_SPEC.md and AGENT_REVIEW_SPEC.md became 
agent-spec/DESIGN.md, agent-spec/IMPLEMENTATION.md and agent-spec/REVIEW.md, 
moved via git mv so history follows. The scripted pass then rewrote every 
reference to the old filenames and to the AGENT_*_SPEC.md glob form across 144 
files — CLAUDE.md, HISTORY.md, ASKS.md, 27 steering docs, roughly 110 .work/ 
retros and reviews, and six test/support files. Three bare extension-less 
mentions in test comments were deliberately left by the script (they could have 
been identifiers rather than paths) and were rewritten by hand after confirming 
all three are genuine file references. A repo-wide grep for AGENT_*_SPEC now 
comes back empty, mix format passes on the eight touched code files, and the 
full suite runs green at 3089 tests with no failures.

---

## [OTHR] Set GIT_OPTIONAL_LOCKS=0 in the dev container
*Saturday, August 29th at 8pm*
Sweeps up the last two uncommitted files in the tree. The substantive change is 
`.devcontainer/devcontainer.json`, which predates this session and had been 
carried unstaged across three commits: it sets `GIT_OPTIONAL_LOCKS=0` in 
`containerEnv` because Zed's remote server polls git roughly once a second and 
each poll rewrote `.git/index` via lock-and-rename, which on this virtiofs bind 
mount exposes a transient ENOENT window to concurrent readers. Git treats a 
MISSING index as an EMPTY one without erroring, so a `git add` landing in that 
window silently rebuilds a one-entry index — the mechanism behind a past 
milestone commit that recorded 1276 deletions. It must live in `containerEnv` 
rather than `remoteEnv` because `zed-remote-server` is launched by `docker 
exec` and inherits only the former, and only OPTIONAL locks are suppressed so 
`add` and `commit` still take mandatory locks. This is the same hazard 
CLAUDE.md documents for parallel review agents, now fixed at the container 
level rather than per-command. Verified the file still parses as JSONC and 
resolves to `containerEnv.GIT_OPTIONAL_LOCKS = "0"`. Also commits a pending 
ASKS.md log line; note that line's CI half is stale — the workflow it 
describes was reverted in 4b5abca because the project does not use CI, a 
constraint already documented at steering/RELEASE_PLAN.md:393.

---

## [TWK] Make chat and runner clean under the Elixir 1.19 type checker
*Tuesday, August 25th at 8pm*
ALLM declares `elixir: "~> 1.17"`, which permits 1.19, and a dependency's 
`lib/` compiles inside the consumer's project — so these two warnings 
surfaced for a downstream app building on 1.19 even though the pinned toolchain 
(1.17.3/OTP 27.1.2) reports none. `ALLM.Chat.handle_step_completed/2` and 
`finalise_unexpected/1` now destructure `%{loop_state: %LoopState{} = 
loop_state}` in the function head so 1.19's inference engine can prove the 
target of the `%LoopState{... | ...}` struct updates; that change is purely 
structural and behaviour-preserving. `ALLM.Runner` drops the 
`response.request_id ||` fallback and assigns the run-level `request_id` 
unconditionally — NOTE this is a real behaviour change, not only a warning 
fix: it removes a defensive fallback, and is safe only because 
`StreamCollector.to_response/1` never populates `:request_id` (the field 
appears nowhere in `stream_collector.ex` and `%Response{}` defaults it to nil), 
so a future collector path that does set it would now be silently clobbered. 
Verified on the pinned toolchain: 3089 tests green, plus format, credo 
--strict, dialyzer, and a --warnings-as-errors compile; the 1.19 warnings 
themselves could not be re-checked here because only 1.17.3 is installed.

---

## [OTHR] Clean all compile, test, docs, and conformance warnings
*Saturday, August 22nd at 1am*
Cleaned up every warning and unclean-output source across the build so `mix 
compile`, `mix test`, `mix docs`, and the `conformance/` sub-project all run 
silent. `examples/_helpers.exs` called `EnvLoader.load/1` directly, which 
warned on every test run because `:env_loader` is `only: [:dev]` while 
`examples_helpers_test.exs` requires the file under `MIX_ENV=test`; it now uses 
the `Code.ensure_loaded?/1` + `apply/3` guard the 
`scripts/record_*_embeddings_fixtures.exs` recorders already used. 
`ExUnit.start/1` gains `capture_log: true` so the ~25 adapter `:debug` lines 
and the deliberate `Task` crash report from `tool_runner_test.exs:1675` no 
longer interleave with the progress dots — verified against a planted failing 
test that logs still replay in full on red. `mix.exs` gains 
`skip_code_autolink_to:` for five prose references to `@doc 
false`/private/external-hidden targets, each verified to still exist so the 
entries suppress autolinking rather than mask a stale reference. Finally, 
`conformance/lib/allm/test/image_adapter_conformance.ex` was formatted, closing 
a `mix format --check-formatted` failure that had stood since Phase 14.1 
(b18ebeb) because the main project's gates never reach the second Mix project.

---

## [BUG] Fix transport timeouts never reaching Finch (§7.2)
*Tuesday, August 11th at 9pm*
Reasoning models spend their thinking time before the first SSE chunk, and 
Finch's HTTP/1 pool defaults receive_timeout to 15,000 ms, so a gpt-5.6 turn 
was killed mid-think and surfaced as %AdapterError{reason: :network_error}; 
ALLM's own 60 s :stream_timeout could never fire because the transport timer 
always won the race. All three documented ways to raise the timeout were 
broken: a call opt or engine params: value reached the adapter but 
Engine.resolve_params/2 also merged it onto request.options, which every 
body-builder merges onto the wire (OpenAI answers HTTP 400 'Unknown 
parameter'), while engine adapter_opts: was nested one level below where 
adapters read transport keys and was never read at all — which had also made 
the adapter_opts: [finch_name: MyApp.Finch] route in OpenAI's own moduledoc a 
silent no-op. This adds ALLM.Adapter.transport_opts/0 as the neutral key list, 
derives ALLM.Chat's @request_carried_keys from it so transport opts reach the 
adapter but never the request body, hoists them out of adapter_opts in 
ALLM.StreamRunner with put_new so call opts still outrank the engine, and adds 
the shared ALLM.Providers.Support.Transport.finch_opts/2 that defaults 
receive_timeout to stream_timeout + 30_000 across all three streaming adapters 
— making :stream_timeout the single governing knob and letting ALLM's typed 
:timeout win the race. Verified live against gpt-5.6 through the streaming 
facade with a closed-schema tool at the new defaults: two turns, 264 s, seven 
tool calls, zero errors, where the same shape previously died at 15 s. Note 
that stream_finch_timeout_forwarding_test.exs's 'omits the timeout keys' test 
was a semantic change — it pinned the 15 s default that was the bug — and 
the Anthropic live arm is blocked on an unrelated account condition ('credit 
balance is too low'), so only the OpenAI examples arm was exercised.

---

## [DOC] Apply 16 backlogged retros to the agent instruction files
*Thursday, July 30th at 1pm*
Folds sixteen unapplied retrospectives — nine dating back to May and all 
seven from the embeddings build — into CLAUDE.md, agent-spec/DESIGN.md and 
agent-spec/IMPLEMENTATION.md, which had not been touched since early May. The 
highest-value entries generalize rules that were previously written 
per-mechanism: any process-global mutation from an async test module is now 
documented as one foot-gun class with a static grep as the gate, rather than 
separate bullets for Logger.configure and telemetry.attach, because a 
per-mechanism rule cannot catch the next mechanism and the third instance cost 
a silently non-deterministic suite for six phases. Provider adapters now 
require a four-part live wire probe with a negative control, since design 
claims about provider wires were wrong seven times across three adapters and 
only ever falsified by a recorded response. Also records that a blocked 
live-gate arm is re-characterized rather than inherited, which is what 
uncovered released code broken against the live API behind a documented older 
failure; that hand-maintained audit literals need meta-tests because a 
fail-open gate ships a silent gap; and that recorded fixtures need a raw-byte 
provenance check, since loader-based assertions strip the very marker they 
claim to test. Two carve-outs to cross-phase discipline were escalated and 
approved: extractions mandated by the two-implementations trigger may touch 
released code, resolving a standing contradiction between two of these files, 
and the sub-phase closing a multi-provider family owns that family's internal 
consistency.

---

## [DOC] Add embeddings spec section, guide, and live examples (Phase 20.7)
*Wednesday, July 29th at 6pm*
Completes the embeddings capability by making it discoverable. Adds spec 
section 36 mirroring the image-generation structure, strikes embeddings from 
the two out-of-scope lists along with image generation which shipped in v0.3 
and was never struck, and scopes the bundled-adapter rule so an adapter may be 
bundled when it is a provider's own recommended path for a capability that 
provider does not offer, with Voyage as the named beneficiary. 
guides/embeddings.md carries the provider matrix, task-type guidance, the 
pgvector worked example, and a note that telemetry stop metadata contains the 
vectors themselves, which are partially invertible to source text, so handlers 
should select fields rather than serializing the map. Examples 16 to 18 run on 
all three provider arms and were verified live, including a 250-input run that 
exercises the multi-chunk merge against Gemini's 100-item cap for the first 
time. Review corrected two pieces of prose before they shipped: the opening 
engine sample taught a broken mixed-provider form, since Engine has one shared 
model field, and the retry-budget table understated the timeout worst case 
threefold because two nested retry loops both list timeout as retryable.

---

## [FEAT] Add Voyage embeddings adapter and make the suite deterministic (Phase 20.6)
*Wednesday, July 29th at 6pm*
Closes the embeddings adapter family with ALLM.Providers.Voyage.Embeddings, the 
Anthropic track. Anthropic ships no embeddings endpoint and directs users to 
Voyage, so the module is named for the wire it actually speaks rather than for 
Anthropic, and it resolves VOYAGE_API_KEY through the Keys unknown-provider 
fallback. Voyage caps a batch at 1000, uses snake_case output_dimension, and 
reports only usage.total_tokens with no prompt_tokens, so input_tokens stays 
nil; the lossy input_type mapping sends document and query and omits the field 
entirely for the three symmetric task types, which is Voyage's documented null 
behaviour. The recorder ships a five-arm live probe with a negative control 
that halts on an unexpected status, and it corrected four design claims, most 
importantly that the error envelope is a FastAPI-style detail string rather 
than the OpenAI-shaped error object the design's framing invited copying. 
Separately this commit fixes an order-dependent test failure that made the 
suite non-deterministic: four async modules wrote provider keys into the global 
Keys store, so an assertion that a missing key raises could see a key left by a 
concurrently running module. Keys are now scoped to per-call api_key opts at 
every async site, and a fixed-seed run joins the random-seed run in the 
verification convention.

---

## [FEAT] Add Gemini embeddings adapter with a self-asserting wire probe (Phase 20.5)
*Wednesday, July 29th at 3pm*
Wires Google's batchEmbedContents as the second embeddings adapter. Gemini caps 
a batch at 100, requires a models/-prefixed model on every sub-request as well 
as in the URL, returns vectors under values rather than embedding, and carries 
no index field at all, so the adapter assigns index by list position; a direct 
call with a nil model is rejected before any HTTP rather than falling back to a 
hardcoded default, because a silently-wrong embedding model produces vectors in 
the wrong space and that is unrecoverable once written to pgvector. 
Truncated-dimension vectors are L2-normalized unconditionally without branching 
on model id, since re-normalizing a unit vector is a no-op and a model 
allow-list would go stale on the next release. The design flagged 
autoTruncate's placement as inferred rather than confirmed, so the recorder now 
ships a four-arm live probe with a negative control that halts the run on an 
unexpected status; it established the nested embedContentConfig form, and 
recording a real rejection also disproved two design claims, that Gemini 
returns usageMetadata and that it sends a correlation-id header, plus revealed 
that a hand-written error fixture had invented its details[] while claiming 
live verification.

---

## [FEAT] Add OpenAI embeddings adapter with live wire fixtures (Phase 20.4)
*Wednesday, July 29th at 2pm*
Wires POST /v1/embeddings as the first real ALLM.EmbeddingAdapter 
implementation. The adapter caps a batch at 2048, always sends input as an 
array, drops :task_type and :truncate as OpenAI has no equivalent, and rejects 
dimensions on text-embedding-ada-002 before any HTTP round-trip; its gate chain 
deliberately runs ahead of key resolution so a malformed request fails the same 
way with or without credentials. Error classification maps the token-budget 400 
to :context_length_exceeded via the type field rather than code, which 
recording against the live API corrected from the design. Security review of 
the error path drove three divergences from the sibling images adapter: no raw 
body preview in metadata, Jason.DecodeError data blanked before it reaches 
:cause, and key-shaped tokens redacted from provider messages, because OpenAI's 
real 401 echoes a key prefix back into a struct that is JSON-serializable and 
commonly persisted. Three wire fixtures are genuine live recordings; the four 
error fixtures are synthesized and marked, and a raw-read provenance check now 
fails the suite if a placeholder is ever mistaken for a recording.

---

## [FEAT] Add ALLM.embed/3 facade with transparent batch chunking (Phase 20.3)
*Wednesday, July 29th at 4am*
Makes the embeddings stack callable end-to-end: ALLM.embed/3 accepts a string, 
a list, or a pre-built request, opens an :embed telemetry span, gates on 
adapter presence before validation so a missing adapter surfaces 
:no_embed_adapter rather than a capability error, then dispatches through 
ALLM.EmbeddingBatch. The batch module chunks against the adapter's 
max_batch_size/0, dispatches sequentially under a per-chunk retry policy, 
rebases each chunk's indices by its offset, and merges, so a 5000-input ingest 
against Gemini's 100-item cap is three lines of caller code instead of a 
hand-rolled loop; a mid-batch failure fails the whole call with 
completed_chunks and completed_inputs in the error metadata rather than 
returning partial vectors. ALLM.embedding_request/2 filters opts through an 
explicit allow-list so facade-only options such as :api_key can never land on 
the serializable request struct. Review of the merge path found it rebuilt 
%Usage{} from three fields while the single-chunk fast path passed all ten 
through, making usage completeness depend on input length; the merge now covers 
the whole struct and a sentinel-driven test fails if a future field is added 
without a rule.

---

## [FEAT] Add embeddings adapter behaviour, error type, and Fake (Phase 20.2)
*Wednesday, July 29th at 3am*
Lands the Layer B runtime for text embeddings: the ALLM.EmbeddingAdapter 
behaviour (embed/2, max_batch_size/0, and an optional prepare_request/2 escape 
hatch) carrying ten numbered invariants, an eleven-atom 
ALLM.Error.EmbeddingAdapterError closed enum mirroring ImageAdapterError, and 
:embed_adapter wired at all five ALLM.Engine sites so the module atom is 
restorable from JSON yet excluded from resolve_params/2's adapter-bound params 
map and can never leak onto a provider wire body. ALLM.Providers.FakeEmbeddings 
is the scripted test vehicle, with three-tier cursor precedence, a capture_pid 
seam that fires before any gate, and layered {:retry_until_call, n} budgets 
that now chain rather than raising. A ten-case EmbeddingAdapterConformance 
suite ships in the conformance sub-project for third-party adapter authors. 
Review established that the suite cannot bind the count-and-index invariant for 
an adapter using the embedding_script short-circuit, since that path delegates 
to FakeEmbeddings before the adapter's own decoder runs; the limit is 
documented in the design and compensated by required fixture-driven 
decode_response/4 tests added to each of the three provider sub-phases.

---

## [FEAT] Add Layer A embedding data types and validator (Phase 20.1)
*Wednesday, July 29th at 3am*
Adds the serializable Layer A foundation for provider-neutral text embeddings: 
ALLM.Embedding (with L2 normalize/1 and magnitude/1), ALLM.EmbeddingRequest 
(closed 5-atom :task_type enum, input normalized to a list, truncate defaulting 
to true) and ALLM.EmbeddingResponse (index-sorted vectors/1 for direct pgvector 
insertion, usage defaulting to %ALLM.Usage{} rather than nil). 
ALLM.Validate.embedding_request/1 implements the full field-error vocabulary, 
accumulating every violation into one %ValidationError{reason: 
:invalid_embedding_request} except a non-list :input, which hard-rejects 
because every element rule presupposes a list. All three structs are registered 
in ALLM.Serializer's @known_modules and round-trip through both 
term_to_binary/1 and JSON, with __from_tagged__/1 coercing integer vector 
elements to floats so a hand-built vector still satisfies the [float()] 
contract. Registering the modules in test/layer_a_docs_test.exs closed a 
fail-open audit gate that had let banned spec-section markers ship in the new 
moduledocs.

---

## [BUG] Honor max_tokens/temperature in chat/stream/session + fix guide drift
*Monday, July 13th at 7pm*
Fixes a silent-correctness bug where Chat.build_request/4 never populated 
max_tokens/temperature, so every chat/3, stream/3, and Session.* turn shipped 
the Anthropic adapter's 1024 default regardless of engine.params or call opts 
— truncating multi-tool turns (finish_reason: :length) and losing all tool 
execution. The builder now folds Engine.resolve_params/2's 
max_tokens/temperature onto the typed %Request{} fields and routes remaining 
opaque params onto request.options via a derived, drift-guarded strip-set 
(built from StreamRunner and OpenAI accessors so future opt-list growth fails 
closed in test, and closing a reasoning-control key leak on the OpenAI 
Responses endpoint found in review). Adds Engine.new/1 fail-fast ArgumentError 
validation of module-typed fields 
(:adapter/:tool_executor/:tool_result_encoder/:image_adapter) so a malformed 
engine can no longer crash deep in tool_runner.ex. Corrects long-standing drift 
in seven guides (engine-first 3-tuples, session status atoms, handler-on-tool 
pattern, Fake keyword tool-call scripts, StreamReducer API, event names, 
JSON-vs-ETF round-trip, retry config) and wires the Fake-based guide iex> 
blocks into doctest_file so the drift becomes a red test rather than a silent 
ship. Cites spec sections 5.2/6.3/6.4/8/10/12.3/31 and references 
steering/ALLM_VERIFIED_FACTS.md.

---

## [FEAT] Key Fake/FakeImages cursor on engine identity
*Saturday, June 27th at 2am*
Add a stable, serializable :id to %ALLM.Engine{} (auto-stamped at new/1, 
preserved across struct-update transforms, round-tripping through ETF and JSON) 
and thread it as adapter_opts[:cursor_key] through the chat and image dispatch 
chokepoints, where Fake/FakeImages now prefer it over :erlang.phash2(scripts). 
This removes the multi-call cursor footgun (see §31): two engines built with 
content-equal scripts no longer share a cursor, so each engine's first façade 
call reads index 0. Direct adapter calls without an engine keep the prior 
content-hash behavior, and the explicit start_script_cursor/0 Agent still wins 
precedence. Implements all three phases of 
steering/20260626_UNLLMTD_FOOTGUN_DESIGN.md; full suite green at 2438 tests.

---

## [BUG] Fix Responses-API streaming usage no-op (gpt-5* totals)
*Thursday, May 28th at 1pm*
Replaced the no-op maybe_apply_usage_from_response/2 in the OpenAI 
Responses-API streaming path with responses_usage_events/1, which emits a 
:raw_chunk {:usage, _} event so StreamCollector folds usage into 
Response.usage. Field shape mirrors decode_responses_usage/1 
(input/output/total tokens plus reasoning_tokens from output_tokens_details and 
an extra spillover map) so streaming and non-streaming Responses paths now 
produce identical %Usage{} structs. Previously, every gpt-5* stream landed 
Response.usage as an all-nil %Usage{}; the recorded happy_text.sse fixture 
omitted the usage block so no test caught it. Added 
test/fixtures/openai/responses/happy_text_with_usage.sse with a gpt-5*-shaped 
usage block on response.completed and a regression test in 
openai_stream_wire_test.exs asserting both the intermediate :raw_chunk event 
and final response.usage fields.

---

## [FEAT] Phase 21 Amesbury feedback rollup (21.1-21.5)
*Monday, May 25th at 6pm*
Ship the Amesbury integration feedback rollup across all five non-release 
sub-phases. Layer A: Validate.message/1 now carries machine-readable 
metadata.invalid_part_type plus a human-readable Exception.message while 
preserving the existing errors-list shape; Tool.new/1 and __from_tagged__/1 
recursively normalize atom-keyed JSON schemas (deterministic adapter wire 
shape) via the extracted ALLM.JsonSchema.normalize/1, which ALLM.json_schema/3 
also calls to close the cross-helper asymmetry; Tool.handler @typedoc 
enumerates the arity-2 :context | :session_id | :tool_call | :engine | 
:request_id keys. Layer B: ALLM.Providers.Fake gains :usage and :record 
adapter_opts (streaming usage rides on the additive 
:message_completed.metadata.usage payload key — no new Event variant), 
StreamCollector folds metadata.usage into state.usage, and new ALLM.Sandbox 
exposes Mox-style set_engine/get_engine/with_engine over $callers so Task 
workers inherit a parent's engine. Layer C: ALLM.unwrap/1 collapses the 
three-clause finish_reason case to {:ok, text} | {:error, _} by delegating to 
Response.text/1. Layer A: Image.from_data_uri/1 parses data: URIs into a base64 
source. Docs: new guides/fakes.md plus additions to getting_started.md, 
tools.md (incl. structured_finalize: true coverage), and vision.md. 2409 tests 
/ 294 doctests / 92.61% coverage; all gates green (format, credo strict, 
dialyzer).

---

## [DOC] Rewrite user-facing docs and add guides/ ExDoc extras
*Friday, May 8th at 3pm*
Replace internal phase/spec/decision vocabulary across every @moduledoc, @doc, 
README, CHANGELOG, examples/README, and mix.exs deps comment so a hex consumer 
can adopt ALLM without access to the steering/ tree. Add eight new guides under 
guides/ (Getting Started, Streaming, Tools, Sessions, Vision, Image Generation, 
Errors & Retries, Multi-Tenant Keys) wired into both docs[:extras] and 
package[:files] so they ship to hexdocs and the source tarball. Add 
scripts/audit_user_docs.exs (banned-token gate, 0 hits across 75 files) and 
scripts/check_lib_diff_non_doc.exs (classifies lib/ diff lines as docstring vs 
body). Fix an async-safety flake in anthropic_stream_wire_test by routing the 
stub key through the per-call :api_key opt instead of the globally-named 
ALLM.Keys.Store agent.

---

## [FEAT] Add scripts/release.exs and adapt to /changelog model
*Wednesday, May 6th at 9pm*
Implements RELEASE_PLAN.md Phase 3+4 — a 470-line scripts/release.exs 
handling the full Hex publish flow (version arg parsing, 
git/branch/tag/CHANGELOG gates, quality gates, mix.exs @version bump, mix 
hex.publish, commit+tag+push) with --dry-run, --skip-dialyzer, --allow-dirty, 
and --help flags. Restructures the changelog model: HISTORY.md now holds 
per-commit rolling history (dev-only, not in package.files), and CHANGELOG.md 
becomes the consumer-facing succinct release-notes file regenerated by the 
/changelog skill before each release. RELEASE_PLAN.md §3.2-§3.4 is amended to 
match (replacing the original Keep-a-Changelog assumption with the /changelog + 
HISTORY.md split), and CLAUDE.md gains a pointer that forbids manual @version 
edits. Removes test/allm/release_polish_test.exs — its assertions were either 
pinned to the v0.3.0 ship or duplicated checks the release script's tarball 
audit and live-gate already cover.

---

## [DOC] Apply 18 retro lifts to CLAUDE/specs + add Phase 19/20/release-plan steering
*Wednesday, May 6th at 8pm*
Apply /apply-retro proposals from 11 reviewed retros (Phase 16.1-16.6 + Phase 
18.1-18.5), routing 18 systemic findings into the standing-rule docs. CLAUDE.md 
gains 9 amendments: README-never-modified-outside-Module-Tree promoted to 
top-level invariant after a 6-phase recurrence; :telemetry.attach/4 + async: 
true foot-gun rule (5-recurrence sibling to Logger.configure/1); live-gate 
blocked-by-pre-existing-failure framing for half-blocked provider runs; 
streaming/non-streaming dual-path file:line disambiguation; SSE-chunk-mapper 
rule generalized to dispatch trees; Layer-A constructors are struct!/2 
pass-throughs by default; cross-provider helper-name alignment refinement; and 
two sub-bullets under Decision text drift (type-contract vs test-plan, 
test-bullet vs test-vehicle). agent-spec/DESIGN.md gains 4 items: reducer-touch 
enumeration extends to event-payload keys, helper-name + arm-description 
anchoring over bare line cites, file structural-stability predicts 
cite-stability across sub-phases, and spec-amendment commit-range provenance. 
agent-spec/REVIEW.md gains the full-suite mix test exit-0 phase-commit gate. 
agent-spec/IMPLEMENTATION.md gains four §4 items (4j bounded max_turns on 
streaming-chat-loop tests, 4k Layer-D session tests through Session public 
seam, 4l relaxation/strip-set tables co-locate with the property, 4m 
equivalence properties paired with absolute-shape tests). 11 retro files 
renamed to _applied.md. Also tracks the three previously-untracked steering 
docs authored prior to this session: PHASE_19_DESIGN.md (audio I/O), 
PHASE_20_DESIGN.md (embeddings), and RELEASE_PLAN.md (Hex publish procedure). 
README.md and ASKS.md changes intentionally left out — README is a 
stand-alone [DOC] commit per the new top-level invariant; ASKS is the running 
task log.

---

## [DOC] Phase 18.5: chat-equivalence property fixtures + spec §5.2/§10.5/§12.4/§17 amendments + examples 14 & 15 + line-cite refresh
*Wednesday, May 6th at 7pm*
Final Phase 18 sub-phase — the data + orchestration + projection from 18.1–18.4 
is now reflected in the spec, exercised by the chat-equivalence property over 
three new fixtures, and demonstrated by two live example scripts. Three 
Unreleased rollup bullets:

- [FEAT] `%ALLM.Tool{manual: boolean()}` field (Phase 18.1) — per-tool manual 
  mode is first-class on the Tool struct; default `false` keeps existing callers 
  unchanged.
- [FEAT] `ALLM.chat/3` mixed-bucket partition (Phase 18.2 non-streaming + 18.3 
  streaming) — auto tools execute eagerly, manual tools halt the loop with 
  `:manual_tool_calls` and surface in `metadata.manual_tool_calls`. Streaming 
  emits the additive `:manual_tool_calls` payload key on `:step_completed`. 
  Session projection (Phase 18.4) routes the manual subset through 
  `pending_tool_calls`; `submit_tool_result/3` flow works unchanged.
- [DOC] spec §5.2 / §10.5 / §12.4 / §17 amendments — `:manual` field on Tool 
  struct (§5.2), `:manual_tool_calls` halt-reason fires under whole-loop OR 
  per-tool conditions (§10.5), new §12.4 "Per-tool manual" subsection with 
  worked examples for chat/3 and Session, §17 ToolRunner clarification (auto 
  bucket only — partition lives in `ALLM.Chat`).

Three new chat-equivalence fixtures (`mixed_manual_first_turn`, 
`pure_manual_first_turn`, `auto_only_no_manual_flags_set`) extend the property's 
fixture matrix from 10 to 13; the relaxation budget is unchanged 
(`metadata.manual_tool_calls` is non-relaxed — both arms must produce identical 
lists in identical order, by-construction via shared 
`Chat.build_chat_result/1`). Three explicit per-fixture tests pin 
`metadata.manual_tool_calls` shape (presence + length + name) and the control's 
absence-of-key invariant — catches a future regression that drops the key from 
BOTH arms simultaneously.

`examples/14_per_tool_manual.exs` (`chat/3`-side) and 
`examples/15_per_tool_manual_session.exs` (Session-side) ship with 
`# Provider: openai, anthropic` markers — `run_all.exs`'s glob picks them up 
unchanged. Per-clean-run cost adds ~$0.004 to the dual-provider /review pass.

Line-cite refresh batch (deferred from 18.2/18.3 fix steps): 12 cites updated 
in PHASE_18_DESIGN.md against HEAD — `chat.ex:1029 → 1044` (do_step/4 entry, 
6 occurrences), `chat.ex:1043 → 1058` (whole-loop mode write), 
`chat.ex:938-948 → 939-950` (terminal_condition halt detector range), 
`chat.ex:1391 → 1421` (streaming start_phase_b preflight), 
`session.ex:646 → 660` (apply_chat_result call site, 2 occurrences), 
`session.ex:668-669 → 688-695` (manual_tool_calls helper, 6 occurrences), 
`session.ex:703 → 729` (classify_step + new per_tool_manual_step? predicate at :758), 
`session.ex:730 → 783-788` (step_manual), 
`tool.ex:41 → 60` (defstruct, 2 occurrences). The pre-refresh deferral marker 
is removed from line 138 (Module Tree). Test-observable claims table refreshed 
to call out post-vs-pre-Phase-18 line numbers explicitly.

Full suite 288 doctests / 26 properties / 2255 tests / 0 failures; 
`mix credo --strict` + `mix format --check-formatted` clean. Live BLOCKING 
gate result recorded post-run in RUN_OUTPUT_OPENAI.md and RUN_OUTPUT_ANTHROPIC.md 
per CLAUDE.md snapshot policy (regen in same commit as the live run, or not at 
all).

---

## [FEAT] Phase 18.4: Session projection lifts manual_tool_calls bucket (Layer D)
*Wednesday, May 6th at 6pm*
Wire ALLM.Session through to :awaiting_tools when ALLM.Chat halts with the 
per-tool manual partition. The internal manual_tool_calls/1 helper now takes a 
%ChatResult{} (not %Response{}) — first clause matches 
metadata.manual_tool_calls with an is_list(tcs) and tcs != [] guard (Decision 
#8 load-bearing); second clause matches final_response.tool_calls for 
whole-loop backwards-compat; third clause catches all and returns []. The 
empty-list guard is critical: it prevents a future metadata.manual_tool_calls: 
[] write (e.g., a defensively-merged StreamCollector fold) from masking the 
whole-loop fallback. Same shape extends to step_manual/2 (2 clauses with the 
same guard). classify_step/1 gains a new clause via per_tool_manual_step?/1 
private predicate — extracted to keep cyclomatic complexity ≤ 9 (third 
Phase 18 sub-phase to hit this Credo threshold; see retro Finding 1 for the 
systemic pattern). The clause runs BEFORE the existing meta[:mode] == :manual 
clause (Decision #11) but produces the same atom — distinction lives in 
metadata shape (per-tool: manual_tool_calls list; whole-loop: mode: :manual). 
Phase 8's status-transition matrix passes unchanged. The call site at 
session.ex:646 changed from manual_tool_calls(cr.final_response) to 
manual_tool_calls(cr) — without this, the new metadata-clause never matches 
because metadata lives on cr, not cr.final_response. ALLM.Session @moduledoc 
gains a 'Per-tool manual cycle (Phase 18)' section. 11 new tests in 
test/allm/session_per_tool_manual_test.exs cover the full design matrix (8 
cells from 18.4.1) plus the empty-list-write defensive case (synthesized 
%ChatResult{metadata: %{manual_tool_calls: []}} → falls through to 
final_response.tool_calls; preemptive bullet added by 18.1's fix step) plus a 
parallel defensive case for step_manual/2 driven through 
Session.apply_step_result/2's @doc false test seam. Full suite 288 doctests / 
26 properties / 2252 tests / 0 failures; mix credo --strict + mix format 
--check-formatted clean.

---

## [FEAT] Phase 18.3: streaming per-tool manual partition + :step_completed payload key (Layer C)
*Wednesday, May 6th at 6pm*
Mirror the non-streaming partition into ALLM.Chat.transition_a_to_b/1 and lift 
the :manual_tool_calls bucket through the streaming chat-loop. 
ALLM.Event.step_completed/4 is the new arity carrying the additive 
:manual_tool_calls payload key (default empty list); existing /2 and /3 forward 
to /4 unchanged so all existing call sites compile and produce 
backwards-compatible payloads (per CLAUDE.md 'adding a key to an existing 
event\'s payload map is NOT breaking'). The streaming partition routes through 
three new helpers — dispatch_partitioned_stream/3 (Credo 
cyclomatic-complexity refactor, threshold 9), start_phase_b_partial/5 (mixed 
bucket — runs auto subset, threads manual_tcs through phase_b_data), and 
start_phase_c_manual_only/4 (pure-manual — skips Phase B entirely, appends 
assistant message before constructing phase_c_data). manual_tcs threads through 
four state-shape sites: phase_b_data, transition_b_to_c/1, 
emit_step_completed/1, and step_result_from_outer_collector/4 → /5 (the 
fourth site was design-under-specified — without it terminal_condition/5's 
per_tool_manual? guard never fires for streaming and the chat-loop hangs on 
Cell 3; caught by test timeout, fixed in-commit per CLAUDE.md 'Decision text 
drift is a known failure mode'). StreamCollector.apply_event/2's 
:step_completed clause merges payload.manual_tool_calls onto 
step_result.metadata IFF non-empty (Decision #12 empty-list-is-absence) — 
load-bearing for chat-equivalence: pure-auto turns produce identical metadata 
keys on both arms (asserted via refute Map.has_key?(metadata, 
:manual_tool_calls) in the new chat-equivalence smoke). 13 new tests + 1 
doctest cover the 5-cell stream matrix (pure-auto, mixed, pure-manual under 
:auto, :manual mixed wins-whole-loop, :manual all-auto whole-loop), 
Event.step_completed/2-/3-/4 arity round-trip, chat-equivalence smoke (mixed + 
pure-auto control), :on_event callback pass-through, and manual-bucket order 
preservation. Full suite 288 doctests / 26 properties / 2241 tests / 0 
failures; mix credo --strict + mix format --check-formatted + mix dialyzer all 
clean. Two streaming-side line-cite refreshes in PHASE_18_DESIGN.md 
(start_phase_b_partial arity bumped to /5 to match implementation); 18.4 cites 
verified-correct against HEAD; non-streaming + already-implemented streaming 
cite refreshes batched into 18.5's spec-amendment commit per build skill triage.

---

## [FEAT] Phase 18.2: chat/3 non-streaming per-tool manual partition (Layer C)
*Wednesday, May 6th at 5pm*
Extend ALLM.Chat.do_step/4 with a partition_tool_calls/2 helper that splits a 
response's tool calls into auto + manual buckets based on tool.manual; auto 
bucket runs eagerly via the existing ToolRunner path, then the loop halts with 
:manual_tool_calls and the manual bucket lands in metadata.manual_tool_calls. 
Adds a chat-layer preflight_unknown_tools/2 invocation BEFORE the partition 
(Decision #14) so unknown-tool errors surface with the existing shape, and a 
new clause in terminal_condition/5 BEFORE the existing :mode clause (Decision 
#11) that recognizes the per-tool path. The pure-auto sub-arm is 
byte-equivalent to the original path — zero behavior change for callers 
without per-tool manual flags. Decision #5 (whole-loop wins) preserved: 
{:manual, :tool_calls} still short-circuits before partition. ALLM.chat/3 @doc 
updated with the halt-reason table prose and a 'Mixed-bucket re-issue' worked 
example for the raw-chat footgun (Decision #4 — naive re-issue without 
appending tool messages for manual ids surfaces a malformed-thread error). 14 
new tests in test/allm/chat/per_tool_manual_test.exs cover the 5-cell 
mode×flag matrix plus 4 edge cases (unknown-tool preflight, empty tool_calls, 
multi-turn caller-resolves flow, structural footgun probe). Two in-commit 
divergences: footgun test rephrased to a structural probe (Validate.thread/1 
doesn't enforce cross-message tool_call_id linkage; Fake adapter doesn't 
validate wire shape — only live providers reject); helper extraction 
(run_auto_tool_calls_step/5, dispatch_partitioned_tool_calls/6) to satisfy 
Credo Refactor.Nesting threshold of 2. Eleven streaming-side line-cite 
refreshes in PHASE_18_DESIGN.md so 18.3 starts with correct line numbers; 
non-streaming cite refreshes deferred to 18.5's spec-amendment commit. Full 
suite 287 doctests / 26 properties / 2228 tests / 0 failures; mix credo 
--strict + mix format --check-formatted clean.

---

## [FEAT] Phase 18.1: %ALLM.Tool{manual: boolean()} field (Layer A)
*Wednesday, May 6th at 5pm*
Add a manual: boolean() field to %ALLM.Tool{} with default false, plus an 
explicit is_boolean/1 guard in Tool.new/1 raising ArgumentError on non-boolean 
:manual (Tool.new/1 uses struct!/2 which silently default-overwrites on nil; 
the guard makes the manual: boolean() type contract honest at runtime). Extends 
__from_tagged__/1 to coerce missing/null to false, updates @moduledoc on Tool 
and Engine to document the per-tool manual semantics, and adds 13 tests + 1 
doctest covering ETF round-trip, JSON round-trip via Serializer, 
missing/null/true __from_tagged__ paths, the new/1 guard, and ALLM.tool/1 
keyword pass-through. Foundation for Phase 18.2-18.5 (chat partition, streaming 
mirror, session projection, examples). Also lands the PHASE_18_DESIGN.md 
steering doc with three classify_step/1 line-cite drift fixes (:707 -> :703) 
and one preemptive 18.4 test bullet for the empty-list-write defensive merge. 
Full suite 287 doctests / 26 properties / 2214 tests, 0 failures (one 
pre-existing async cross-test pollution flake in stream wire tests is unrelated 
and out-of-scope per cross-phase bug discipline).

---

## [BUG] Fix 3 failing tests + lint cleanup post-Phase-16 Gemini
*Sunday, May 3rd at 1pm*
Three test failures from post-Phase-16 drift: README test pinned to the renamed 
'## Getting Started' section (now '## Hello, ALLM'), and two 
release_polish_test markers asserting strict 'openai'-only / 'openai, 
anthropic'-only Provider lines on examples 11/12 that Phase 16 widened with 
gemini. Updated the README test to track the new section heading and relaxed 
the marker regexes to word-boundary substring matches so additional providers 
don't break them. Also formatted lib/allm/providers/gemini.ex, replaced four 
'length(x) >= 1' / '== 1' credo warnings with empty-list comparisons in the 
live/vision test files, sigil-quoted three readability hits, and cleaned the 
unused-alias warning in tool_runner_test.exs by inlining the nested-module 
reference. Full suite now 2201 tests / 0 failures, mix format clean, credo down 
to 10 advisory design suggestions (no warnings).

---

## [FEAT] Phase 16: Gemini provider (chat + streaming + tools + vision + images) live-validated
*Sunday, May 3rd at 11am*
Ships ALLM.Providers.Gemini and ALLM.Providers.Gemini.Images across six 
sub-phases (16.1–16.6) per steering/GEMINI_DESIGN.md — chat, streaming SSE 
via Finch, tool calling round-trip, multimodal input, native image 
generation/edit, and examples wiring. Spec amendments to §32.1 (bundled 
adapters) and §35.7 (bundled-adapter rule) land alongside. Live 
ALLM_PROVIDER=gemini mix run examples/run_all.exs now exits 0 with all 12 
applicable scripts green (10 chat + image-gen + edit + vision-in; 
13_image_variations correctly skipped); RUN_OUTPUT_GEMINI.md captured. Live 
validation surfaced four real bugs the wire-stub tests missed: (1) Gemini's 
OpenAPI-3.0 schema subset rejects 'additionalProperties' — added 
sanitize_schema/1 to strip it (and $schema) recursively from tool params + 
responseSchema; (2) :tool message rewrite was sending empty 
functionResponse.name — added build_tool_call_name_lookup/1 to resolve name 
from prior assistant turn's tool_calls metadata; (3) Gemini 3 requires 
thoughtSignature to be echoed on functionCall parts — captured on decode 
(Decode.decode_function_call/2 + streaming handle_function_call_part/3) and 
replayed on tool_call_to_function_call_part/1; (4) StreamCollector silently 
dropped :tool_call_completed.metadata — preserved cleanly now 
(cross-provider, additive). Includes 79 image tests, 26 stream tests, 26 tool 
tests, 21 vision tests, 12 wire tests, full conformance harness against 
ImageAdapterConformance, gemini_live_test (5 :live tagged), 
examples_helpers_test (Decision #20 caller-override invariant). Coverage: 
Gemini 90.78%, Gemini.Images 92.42%, Gemini.Decode 100%, GeminiHeaders 100%. 
mix credo --strict and mix dialyzer green; full suite 2201 tests with 2 
pre-existing failures (README + intermittent Anthropic stream flake) unrelated 
to this commit.

---

## [FEAT] Phase 16.6 — Gemini examples wiring + conformance + live-test scaffolding
*Friday, May 1st at 8pm*
Final Phase 16 batch wires Gemini into the provider-neutral examples runner
and adds the conformance + live-test gates. Adds the `"gemini"` row to
`examples/_helpers.exs` `@providers` map (`adapter: ALLM.Providers.Gemini`,
`default_model: "gemini-3-flash-preview"`,
`image_adapter: ALLM.Providers.Gemini.Images`,
`image_default_model: "gemini-3.1-flash-image-preview"`,
`default_temperature: 1.0`). Adds `:default_temperature` per-provider field
support in `engine/1` (Decision #20) — Gemini defaults to `1.0` per Google's
recommendation; OpenAI / Anthropic rows omit the key and inherit the
historic `0` baseline; caller-supplied `params: %{temperature: ...}` still
wins, AND a caller passing `params:` with non-temperature keys (e.g.
`%{max_tokens: 100}`) now correctly preserves the row's `default_temperature`
via deep-merge of the `:params` map (`merge_with_params/2`) — the prior
shallow `Keyword.merge` would have silently dropped the default (Phase
16.6 retro Finding 3; verified by `test/allm/examples_helpers_test.exs`).
Adds `test/allm/providers/gemini_live_test.exs` (`@moduletag
:live_gemini`, excluded by default, skips entirely when `GEMINI_API_KEY`
is unset) with five `@tag :live` smoke tests covering core scenarios
(text/stream/tools/vision/image-out — example scripts 01/02/03/06/10);
the remaining example scripts (04/05/07/08/09) are covered by the live
BLOCKING `run_all.exs` gate, mirroring the OpenAI / Anthropic live-test
pattern.
Adds `conformance/test/gemini_conformance_test.exs` running the full
9-case `ALLM.Test.ImageAdapterConformance` against
`ALLM.Providers.Gemini.Images`, plus explicit `supported_operations() ==
[:generate, :edit]` and `:variation`-rejection assertions (11 tests, 0
failures). Live `ALLM_PROVIDER=gemini mix run examples/run_all.exs`
validation **deferred** — implementer environment lacks `GEMINI_API_KEY`;
will be re-validated by maintainer with key. The synthesized chat / stream
/ image fixtures from Phases 16.1–16.5 cover the implementation-side wire
shapes; the live re-record gate per CLAUDE.md applies, and
`examples/RUN_OUTPUT_GEMINI.md` is intentionally NOT created in this
commit per the "snapshot regen-or-skip" rule. Model-string verification
against the live `models?key=$GEMINI_API_KEY` listing is also deferred for
the same reason; the design-specified preview names ship verbatim. Phase
16.6 deviates from the design in one place: `ALLM.Test.AdapterConformance`
and `ALLM.Test.StreamAdapterConformance` are NOT wired against
`ALLM.Providers.Gemini` — both harnesses drive via `adapter_opts[:script]`
which the real chat adapter does not implement (parallel to OpenAI /
Anthropic, which also don't ship those harness invocations). The
`@moduledoc` of the new conformance test documents this. `mix test`
remains at 1 pre-existing failure (`readme_getting_started_test.exs`,
parallel-task issue, untouched per task brief). `cd conformance && mix
test` is fully green (77 tests, 0 failures).

---

## [BUG] Stamp engine model on image requests; bundle real PNG fixture for examples
*Friday, May 1st at 5pm*
Fixes ALLM.edit_image/4 (and would-be variations) failing with OpenAI HTTP 400 
'Missing required parameter: model' — do_generate_image_body never propagated 
the engine-resolved model onto the ImageRequest before dispatch, so the 
multipart body went out without a model field. /v1/images/generations silently 
defaulted to dall-e-2 (masking the bug for 10_generate_image), but 
/v1/images/edits and /v1/images/variations require it. Now mirrors the 
chat-side StreamRunner.resolve_request_model/3 pattern. Also widens 
drop_request_opts/1 to drop :request_timeout, :retry, :api_key, 
:telemetry_metadata so adapter-facing call-control opts don't leak into 
ImageRequest.new/1 and KeyError. Bundles examples/fixtures/kestrel_256.png 
(one-time-baked via dall-e-2) and switches 11_edit_image and 12_vision_input to 
load it — gpt-image-1 moderation and gpt-4o-mini both reject 1×1 synthetic 
placeholders. Bumps run_all per-script Task.yield 60s→180s for slow 
gpt-image-1 calls. 13_image_variations remains failing upstream: 
/v1/images/variations returns Cloudflare HTTP/2 404 with no JSON body for our 
sk-proj-... key — likely an OpenAI project-permission issue, not a library 
bug. Test suite: 1975 tests, 0 failures.

---

## [DOC] Apply Phase 15.x + 17.x retros: 11 steering-doc lifts
*Friday, May 1st at 4pm*
Reviewed nine unapplied retros (Phase 15.1–15.6, 17.1–17.3) and applied 11
deduplicated rules to CLAUDE.md, agent-spec/IMPLEMENTATION.md, and
agent-spec/DESIGN.md. Highlights: synthesized-fixture + recorder + deferred-
record convention (5x recurrence, finally landed); capability pre-flight runs
in StreamRunner not adapter; cross-provider helper-name parity (extending
the OpenAI dual-translator bullet); wire fixtures are .json; mix.exs
package[:files] must be a superset of docs[:extras]; snapshot/audit-grep/
async-Logger discipline; public-test-seam @doc false + @spec convention;
dual-keyed atom/string accessors generalized beyond metadata; Module Tree
path-existence sanity check.

---

# v0.3.0 — Multimodal foundation

*Wednesday, April 29th, 2026*

v0.3.0 ships the v0.3 multimodal foundation: image data structs and
facade (Phases 13.1–13.3), the `ALLM.ImageAdapter` behaviour and
`ALLM.Providers.FakeImages` (Phase 14.1), the
`ALLM.generate_image/3` / `edit_image/4` / `image_variations/3` facade
trio with `EngineError :no_image_adapter` (Phase 14.2), image
telemetry + `Capability.preflight_image/2` + retry integration
(Phase 14.3), `ALLM.TextPart` + `ALLM.ImagePart` + `Message.content`
widening (Phase 14.4), `ALLM.Providers.OpenAI.Images` against
`dall-e-2`/`dall-e-3`/`gpt-image-1` (Phase 15), vision-input wiring in
`ALLM.Providers.OpenAI` (Phase 17.1) and `ALLM.Providers.Anthropic`
(Phase 17.2), and the v0.3.0 release polish (Phase 17.3 — `mix.exs`
`@version` bump from `0.2.0` to `0.3.0`, three new example scripts
(`11_edit_image.exs`, `12_vision_input.exs`,
`13_image_variations.exs`), README "Generating images" + "Vision input"
sections, examples README cost-notes table, `mix hex.build` dry-run
verification, and the §35.10 out-of-scope audit).

Spec sections shipped:
- **§35.1** — `ALLM.Image` Layer A struct (Phase 13.1)
- **§35.2** — `ALLM.ImageRequest` / `ImageResponse` / `ImageUsage`
  Layer A structs (Phase 13.2)
- **§35.3** — `ALLM.ImageAdapter` behaviour (Phase 14.1)
- **§35.4** — `ALLM.image_request/2` facade (Phase 13.3)
- **§35.5** — `ALLM.generate_image/3` · `edit_image/4` ·
  `image_variations/3` (Phase 14.2)
- **§35.6** — `ALLM.TextPart` / `ImagePart` content parts (Phase 14.4)
  + chat-vision wiring on both bundled chat adapters (Phase 17.1, 17.2)
- **§35.7** — `ALLM.Providers.OpenAI.Images` against `dall-e-2` /
  `dall-e-3` / `gpt-image-1` (Phase 15); chat-vision-only on Anthropic
  (Phase 17.2 — confirmed by negative scope per §35.7)
- **§35.8** — `ALLM.Test.ImageAdapterConformance` harness (Phase 14.1)
- **§35.9** — image telemetry `[:allm, :image, :start | :stop |
  :exception]` + `Capability.preflight_image/2` (Phase 14.3)
- **§35.10** — out-of-scope audit (Phase 17.3): zero matches for
  `streaming_image_preview`, `image_to_video`, `ocr`, `upscale`,
  `batch_image` across `lib/`, `test/`, `examples/`
- **§34** — release process (Phase 17.3): `mix hex.build` dry-run
  passes; tarball excludes `test/fixtures/` and
  `examples/RUN_OUTPUT_*.md` per `mix.exs :files`

Vocabulary additions over v0.2.x:
- `ValidationError`: removed `:vision_not_in_v0_2` (Phase 14.4) —
  replaced by `:invalid_message` with per-field
  `:image_in_system_message`, `:unsupported_image_format`,
  `:image_too_large`, `:missing_mime_type` tuples; and
  `:unsupported_capability` with `:vision_disabled`.
- `EngineError`: `:no_image_adapter` (Phase 14.2).
- `ImageAdapterError`: new closed-enum struct
  (`:authentication_failed`, `:rate_limited`, `:content_filter`,
  `:invalid_request`, `:provider_unavailable`, `:timeout`,
  `:network_error`, `:malformed_response`, `:unsupported_operation`,
  `:unknown` per Phase 15).
- `Capability`: new `:vision` capability key (Phase 17.1).
- `Telemetry`: `[:allm, :image, :start | :stop | :exception]` events
  with `:image_count` `:stop` measurement (Phase 14.3).

Live BLOCKING gate: **deferred** — `OPENAI_API_KEY=…
mix run examples/run_all.exs` and
`ANTHROPIC_API_KEY=… ALLM_PROVIDER=anthropic mix run examples/run_all.exs`
are gated as a BLOCKING pre-publish step. Synthesized fixtures + dry-run
validate the in-tree code; live re-record runs at release-tag time
(before `mix hex.publish`). Combined cost ~$0.09 per clean run, ~$0.27
first-implementation per Phase 17.3 Decision #10. Idempotent recorder
scripts (`scripts/record_openai_vision_fixtures.exs`,
`scripts/record_anthropic_vision_fixtures.exs`) ship in the repo for the
re-record step. The `examples/RUN_OUTPUT_OPENAI.md` /
`RUN_OUTPUT_ANTHROPIC.md` snapshots are regenerated at the same time as
the live runs, not before — stale snapshots beat hand-edited ones.

The detailed per-sub-phase narratives below remain for traceability.

## [FEAT] Phase 17.3: v0.3.0 release polish — mix.exs @version bump, three new example scripts, README sections, CHANGELOG rollup, mix hex.build dry-run

*Wednesday, April 29th*

No library-code changes (the version bump aside). Release infrastructure:

- `mix.exs:4` `@version` bumped from `"0.2.0"` to `"0.3.0"`.
- Three new example scripts:
  - `examples/11_edit_image.exs` — `gpt-image-1` inpaint with mask via
    `ALLM.edit_image/4`. Provider marker `# Provider: openai`.
  - `examples/12_vision_input.exs` — multi-provider vision script with
    `[%TextPart{}, %ImagePart{}]` content via `ALLM.generate/3`.
    Provider marker `# Provider: openai, anthropic`. Uses
    `ExamplesHelpers.engine(vision: true)` to route to each row's
    `:vision_default_model` (Decision #8).
  - `examples/13_image_variations.exs` — `dall-e-2` 256×256 variation
    via `ALLM.image_variations/3`. Provider marker `# Provider: openai`.
- `examples/_helpers.exs` — `:vision_default_model` field added to
  both `@providers` rows (`gpt-4o-mini` / `claude-haiku-4-5-20251001`
  per Decision #8); `engine/1` learns a `vision: true` opt that routes
  to the row's `:vision_default_model` instead of `:default_model`.
- `examples/run_all.exs` — no source change required; the existing
  marker-scanner at `:37` automatically gates the three new scripts on
  the OpenAI arm (11, 12, 13) and the Anthropic arm (12 only) per
  Decision #9.
- `examples/README.md` — added Image-editing, Image-variations, and
  Vision-input subsections; added a Phase-17.3 cost-notes table per
  Decision #10.
- `README.md` — added "Generating images" (Fake-adapter worked
  example) and "Vision input" (`[TextPart, ImagePart]` example)
  sections; bumped `~> 0.2` → `~> 0.3` in the deps snippet.
- `CHANGELOG.md` — consolidated v0.3.0 rollup header on top
  enumerating Phase 13–17 deliverables and §35.x coverage.
- `test/allm/release_polish_test.exs` — smoke test asserting (a)
  `mix.exs @version` is `"0.3.0"`, (b) CHANGELOG carries Phase 17.1,
  17.2, 17.3 entries, (c) `examples/_helpers.exs` `@providers` rows
  include `:vision_default_model` for both providers, (d)
  `examples/run_all.exs` registers all three new scripts (filename
  glob — implicit).
- `mix hex.build` dry-run verified locally — tarball produced;
  package files match `mix.exs :files` (excludes `test/`,
  `examples/`, `steering/`, `scripts/`).
- §35.10 audit: `grep -rE 'streaming_image_preview|image_to_video|ocr|upscale|batch_image' lib/ test/ examples/`
  returns zero substantive hits (the `ocr` substring appears only as
  literal user-message strings in `test/examples/garden_test.exs`,
  not as a feature flag, and is ignored).
- Live `run_all.exs` runs deferred BLOCKING — no `OPENAI_API_KEY` or
  `ANTHROPIC_API_KEY` available in the implementation environment.
  Both runs marked deferred for the next environment with keys; the
  scripts have been syntax-validated via
  `mix compile --warnings-as-errors` and structure-validated via
  test-side smoke assertions. The
  `examples/RUN_OUTPUT_OPENAI.md` / `RUN_OUTPUT_ANTHROPIC.md`
  snapshots are intentionally NOT regenerated in this commit per
  Phase 17.3 spec ("Do not commit stale or hand-edited snapshots").

Spec sections cited: §35.6 (vision content parts), §35.7 (provider
matrix), §34 (release process), §35.10 (out-of-scope audit). Phase 17
design Decisions #8 (`vision_default_model`), #9 (provider-arm
gating), #10 (cost notes).

## [FEAT] Phase 17.2: vision input wiring in ALLM.Providers.Anthropic per §35.6 — Messages API content-block translator with base64/URL source dispatch; ImagePart.detail dropped with one-shot debug log
*Wednesday, April 29th*
Mirror of Phase 17.1 for Anthropic. Replaces the Phase 14.4
`reject_image_parts/1` guard in `lib/allm/providers/anthropic.ex` with a
full content-block translator. `[%ALLM.TextPart{}, %ALLM.ImagePart{}]`
content lists now translate to Anthropic's Messages-API wire shape via
a private `to_anthropic_content_blocks/1` helper:

- `TextPart` → `%{"type" => "text", "text" => t}`
- `ImagePart` with `{:url, u}` source → `%{"type" => "image", "source" => %{"type" => "url", "url" => u}}`
- `ImagePart` with `{:base64, s}, mime` → base64 source shape with `data` passed verbatim
- `ImagePart` with `{:binary, b}, mime` → `Base.encode64(b)` then base64 source shape
- `ImagePart` with `{:file, _}, mime` → `Image.to_binary/1` + `Base.encode64/1` then base64 source shape

URL sources are dispatched on a fast-path BEFORE calling
`Image.to_binary/1` (which returns `{:error, :remote_source}` for
`{:url, _}` sources). `to_anthropic_messages/1`'s list-content path
now delegates to the new translator for image-bearing lists; pure
TextPart lists still flatten to joined text per the Phase 14.4
backward-compat invariant.

`ImagePart.detail` is **dropped silently** on the wire — Anthropic's
Messages API has no `detail` field (Decision #3). A single deferred-form
`Logger.debug/1` fires once per process the first time a non-nil
`detail` flows through; subsequent calls in the same process stay
silent. Detection mechanism: `Process.get/2` + `Process.put/2` flag
keyed on `:allm_anthropic_detail_warned`. Tested with `:capture_log`
asserting exactly one debug emission across two ImagePart-bearing calls
in the same process.

Pre-flight order in `generate/2` (`:307-308`) and `stream/2` (`:1172-1173`):
system-rejection → MIME/size validate → translate → HTTP. Reuses
`ALLM.Providers.Support.ImageMime.validate_request(request, :anthropic)`
shipped in Phase 17.1; the accept-set (`image/png`, `image/jpeg`,
`image/webp`, `image/gif`) matches OpenAI's today (per-provider seam
preserved for future divergence). System-message `ImagePart` is
hard-rejected at pre-flight via the mirror helper
`reject_image_in_system_messages/1` — error tuple
`{[:messages, idx, :content], :image_in_system_message}` accumulating in
a `%ValidationError{reason: :invalid_message}`. Capability pre-flight
(`:vision_disabled`) runs at runner level (`StreamRunner.do_run/3`),
NOT inside the adapter — same architectural convention as Phase 17.1
per the 17.1 retro Finding 1 amendment.

Symmetry fix per 17.1 retro Finding 5: `materialize_part(%ImagePart{})`
in `lib/allm/providers/anthropic.ex` now returns the empty string
rather than raising `ArgumentError`. Mirrors `lib/allm/providers/openai.ex`'s
graceful-empty-string contract for stale ImageParts that reach a
text-only context. Cross-adapter divergence eliminated.

Test surface:
- `test/allm/providers/anthropic_vision_test.exs` (27 tests) —
  translator, pre-flight, detail-drop debug log, decoder, and
  `:live_anthropic`-tagged smoke test against `claude-haiku-4-5-20251001`.
- 4 synthesized wire fixtures under `test/fixtures/anthropic/messages/vision/`
  (`single_image_url.json`, `single_image_base64.json`,
  `single_image_binary.json`, `multi_image.json`). Each carries a
  `_comment: "Synthesized…"` provenance marker.
- `scripts/record_anthropic_vision_fixtures.exs` — idempotent
  live-recorder that overwrites the four fixtures from real
  `claude-haiku-4-5-20251001` calls.
- Two flips in `test/allm/providers/anthropic_wire_test.exs` (lines 426
  and 519): the Phase 14.4 `:unsupported_feature` rejection assertions
  become happy-path translations.

Audit per Phase 17.2 checklist: `git grep ':vision_not_in_v0_2' test/`
returns zero hits (already true since Phase 14.4); re-verified.

Cross-phase note: the live-record blocker remains. The committed
fixtures are synthesized with bodies matching real Anthropic shapes;
running `ANTHROPIC_API_KEY=… mix run scripts/record_anthropic_vision_fixtures.exs`
overwrites them with captured wire shapes. Live `:live_anthropic`-tagged
smoke test deferred to /review per the 17.1 BLOCKING-gate convention.

Spec sections cited: §35.6 (vision content parts), §35.7 (chat-vision
on Anthropic; no image-gen adapter). Phase 17 design Decisions #3
(detail drop), #5 (capability gate already wired in 17.1), #7 (pre-flight
order, runner-level capability gate per 17.1 retro Finding 1).

## [FEAT] Phase 17.1: vision input wiring in ALLM.Providers.OpenAI per §35.6 (Chat Completions + Responses translators)
*Wednesday, April 29th*
Replaces the Phase 14.4 `reject_image_parts/1` guard with a full
content-block translator. `[%ALLM.TextPart{}, %ALLM.ImagePart{}]`
content lists now flow end-to-end through both OpenAI endpoints:
`to_openai_messages/1` (Chat Completions, `lib/allm/providers/openai.ex`)
emits `{type: "image_url", image_url: %{url, detail}}` blocks (detail
nested in the image_url map), and `to_responses_input/1` (Responses API)
emits `{type: "input_image", image_url, detail}` blocks (detail at
sibling level). Both translators dispatch through a shared private
`to_openai_content_blocks/2` helper, mirroring the Phase 14.4 rule that
content-shape changes must touch both endpoints.

Adds `ALLM.Providers.Support.ImageMime` (Layer B helper) with `validate/2`,
`accept_mimes/1`, and `validate_request/2`. Per-image MIME and 20-MB
size validation runs in adapter pre-flight; URL sources skip size
validation (no network fetch). Per-image errors accumulate as
`{[:content, msg_idx, part_idx], reason}` field tuples in a
`%ALLM.Error.ValidationError{reason: :invalid_message}`.

System-message `ImagePart` is hard-rejected at pre-flight via a new
private `reject_image_in_system_messages/1` helper —
`{[:messages, idx, :content], :image_in_system_message}`. Pre-flight
order is fixed: system-rejection → capability gate → MIME/size validate
→ translate → HTTP. Order is asserted by a unit test.

Extends `ALLM.Capability.preflight/3` with a `:vision` rule (Decision
#5). When the request contains any `%ImagePart{}` AND the resolved
`%ModelRef{}.capabilities` map says `vision: false`, pre-flight surfaces
`{[:vision], :vision_disabled}` as a per-field error in
`%ValidationError{reason: :unsupported_capability}`. No-op when the
catalog is absent or the model record has no `:vision` key. Tolerates
JSON-rehydrated `%ModelRef{}` with string-keyed capabilities matching
the existing dual-keyed accessor pattern.

Decoder extension (Decision #11): non-streaming-only assistant ImagePart
output. The Chat Completions response decoder now handles list-shaped
`choices[0].message.content` — `{type: "text"}` → `%TextPart{}`,
`{type: "image_url"}` / `{type: "output_image"}` → `%ImagePart{}`.
Streaming-side assistant image output is out of scope for v0.3; spec
§35.6 is satisfied by the non-streaming path. Forward-compat synthesized
fixture under
`test/fixtures/openai/chat_completions/synthesized/vision_assistant_image_output.json`.

Test surface:
- `test/allm/providers/openai_vision_test.exs` (28 tests) — translator,
  pre-flight ordering, decoder, and `:live_openai`-tagged smoke test
  against `gpt-4o-mini`.
- `test/allm/providers/support/image_mime_test.exs` (17 tests + 7
  doctests) — helper unit tests.
- `test/allm/capability_vision_test.exs` (8 tests) — vision-gate
  per-rule pre-flight tests.
- `test/allm/chat_equivalence_test.exs` — adds row 10
  (`:vision_multi_turn`).
- `test/allm/stream_equivalence_test.exs` — extends §31 vocabulary with
  ImagePart-bearing user message; equivalence property holds.
- Wire fixtures under
  `test/fixtures/openai/{chat_completions,responses}/vision/` (4
  source-shapes × 2 endpoints, synthesized — re-record via
  `scripts/record_openai_vision_fixtures.exs` with `OPENAI_API_KEY` set).
- Flips `test/allm/providers/openai_wire_test.exs:467,557` and
  `test/allm/stream_runner_test.exs:113` from
  `:unsupported_feature`-rejection to happy-path translation.

LLMDB test fixture extended with `openai:gpt-4o-mini` (`vision: true`)
and `local:no-vision` (`vision: false`) entries.

Vocabulary additions: `:vision` (capability key) and `:vision_disabled`
(rejection reason). NO change to `ValidationError.@type reason` —
reuses `:invalid_message` and `:unsupported_capability` per Decision
#6.

Anthropic vision wiring is out of scope for this sub-phase (covered in
17.2). The `reject_image_parts/1` guard at
`lib/allm/providers/anthropic.ex:717-733` is intentionally left in
place.

Deviation from design doc: fixtures use the existing project `.json`
convention (consistent with `test/fixtures/openai/chat_completions/*.json`)
rather than the `.exs` shape mentioned in the design's Module Tree.
`scripts/record_openai_vision_fixtures.exs` writes pretty-printed JSON.
A live re-record is required before `/review` to replace the
synthesized fixtures with real OpenAI wire shapes (CLAUDE.md "every
bundled provider adapter ships with a live BLOCKING gate" — deferred
because no `OPENAI_API_KEY` is available in this scratch environment).

`mix test`: 1936 tests / 0 failures (53 new); `mix credo --strict`,
`mix format --check-formatted`, `mix dialyzer` all green.

---

## [FEAT] Phase 15: ALLM.Providers.OpenAI.Images per §35.7 (generate/edit/variation)
*Tuesday, April 28th at 4pm*
Ships ALLM.Providers.OpenAI.Images implementing ALLM.ImageAdapter against 
OpenAI's /v1/images/generations, /v1/images/edits, and /v1/images/variations 
endpoints with model-aware operation gating across dall-e-2, dall-e-3, and 
gpt-image-1. Includes JSON + multipart/form-data builders, URL-source 
eager-download with five closed failure modes, gpt-image-1 forced-base64 
normalization with token-usage mapping, retry integration via ALLM.Retry.run/3, 
and per-§6.4 key resolution at adapter-call time. Extracts 
ALLM.Providers.Support.OpenAIHeaders shared between chat and image adapters 
(REFACTOR). Adds examples/10_generate_image.exs wired into the BLOCKING 
examples gate via run_all.exs provider-arm gating; six of seven happy-path 
fixtures recorded against live OpenAI (variation pending API restoration). Test 
suite grows by 162 tests to 1883 total, all green; coverage 90.71% on images.ex.

---

## [FEAT] examples/10_generate_image.exs runnable against dall-e-2.
*Monday, April 27th*
Phase 15.6 deliverable. New `examples/10_generate_image.exs` exercises
`ALLM.generate_image/3` against OpenAI's `dall-e-2` model at 256×256,
materializes the resulting `%ALLM.Image{}` to bytes via
`ALLM.Image.to_binary/1`, writes the PNG to a tmp file under
`System.tmp_dir!()`, and asserts the on-disk bytes start with the PNG
magic number `<<137, 80, 78, 71>>`. Header marker `# Provider: openai`
tells `examples/run_all.exs` to skip the script on
`ALLM_PROVIDER=anthropic` (provider-arm gating per Phase 15.6 Decision
#15). `examples/_helpers.exs` `@providers` table restructured from
3-tuple values to map values
(`%{adapter:, default_model:, key_env:, image_adapter:, image_default_model:}`)
per Decision #14; new `image_engine/1` constructor sister to `engine/1`
raises `ArgumentError` on providers without an image adapter.
`examples/run_all.exs` learns header-comment provider-arm gating
(`~r/^#\s*Provider:\s*([\w, ]+)\s*$/m`); skipped scripts print `[SKIP]`
and do not count toward `failed`. Per-clean-run cost on the OpenAI arm
of `run_all.exs` adds ~$0.016 USD.

## [REFACTOR] Extract ALLM.Providers.Support.OpenAIHeaders shared between chat and image adapters.
*Monday, April 27th*
Phase 15.2 deliverable. The `OpenAI-Beta` / `Authorization` /
`User-Agent` header construction shared between `ALLM.Providers.OpenAI`
(chat / Responses) and `ALLM.Providers.OpenAI.Images` (image
generation) is consolidated into `ALLM.Providers.Support.OpenAIHeaders`.
Both adapters call the shared helper at request-prepare time; no
public-API change.

## [FEAT] ALLM.Providers.OpenAI.Images per §35.7 — supports dall-e-2 (generate/edit/variation), dall-e-3 (generate), gpt-image-1 (generate/edit).
*Monday, April 27th*
Phase 15 deliverable. New `ALLM.Providers.OpenAI.Images` implements the
`ALLM.ImageAdapter` behaviour against OpenAI's three image endpoints
(`/v1/images/generations`, `/v1/images/edits`, `/v1/images/variations`)
with model-aware operation gating across `dall-e-2` (generate / edit /
variation), `dall-e-3` (generate), and `gpt-image-1` (generate / edit).
JSON path covers `:generate` (response_format=`b64_json` for
`dall-e-2`/`dall-e-3`; gpt-image-1 always returns base64); multipart
path covers `:edit` and `:variation` with adapter-side URL-source fetch
(spec §35.7). Closed-enum `%ALLM.Error.ImageAdapterError{}` reasons
(`:authentication_failed`, `:rate_limited`, `:content_filter`,
`:invalid_request`, `:provider_unavailable`, `:timeout`,
`:network_error`, `:malformed_response`, `:unsupported_operation`,
`:unknown`) wired to OpenAI HTTP statuses + body shapes per the wire-
field map in `steering/PHASE_15_image_layer_6.md`. Telemetry
`[:allm, :image, :start | :stop | :exception]` (Phase 14.3) fires
end-to-end. Live smoke `test/allm/providers/openai/images_live_test.exs`
covers `dall-e-2` `:generate` and `:edit` cells (`@moduletag
:live_openai_images`, opt-in via `mix test --include live_openai_images`).
Per-clean-run live-test cost ≈ $0.04 USD.

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
the joined text via `Enum.join("
")`, plus a private
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
introspection per agent-spec/DESIGN.md §3 rule 7). Translated 4 
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
Phase 11.4) into the canonical agent docs. agent-spec/DESIGN.md gains six new 
Behaviour design-doc checklist rules (14-19) covering Layer-C reducer-touch 
enumeration, per-provider wire-field maps, synthesized-vs-recorded fixture 
policy, detection-mechanism for state-conditioned behavioural deltas, the 
provider-neutral examples _helpers.exs template, and live-API cost estimation. 
agent-spec/IMPLEMENTATION.md adds wall-clock timing assertion guidance under 
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
to @orchestration_opts. Folds nine retro findings into agent-spec/DESIGN.md, 
agent-spec/IMPLEMENTATION.md, and CLAUDE.md (sub-phase retro cadence, shared test 
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
retros drove agent-spec/DESIGN.md and agent-spec/IMPLEMENTATION.md refinements: §3 
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
process artifacts (agent-spec/*.md, steering design docs, retros, reviews, 
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
- `test/allm/session_equivalence_test.exs` — new `StreamData` property test (`@moduletag :property`) asserting `ALLM.Session.start/3 ≡ ALLM.Session.stream_start/3 |> StreamReducer.finalize/1` across 100 iterations over a multi-turn fixture generator (0–2 tool-calls turns + a terminating text turn against the `echo` tool). Each iteration isolates Fake's per-process cursor via `Task.async/Task.await` per `agent-spec/IMPLEMENTATION.md` §Property tests. Uses the new `assert_equivalent_session_result/2` helper.
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
- The design doc's `StreamError` mid-stream reason table named `:truncated | :malformed_chunk | :connection_dropped`, but the Phase 1 committed `ALLM.Error.StreamError` enum is `:adapter_error | :cancelled | :timeout | :malformed_event | :unknown`. The conformance suite uses the committed atoms (`:cancelled` in the self-test case) per `agent-spec/DESIGN.md §3`'s empirical-verification rule.

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
