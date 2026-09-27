# Phase 27 Prompt Caching — Records

Companion to `steering/2026-09-27_PROMPT_CACHING_DESIGN.md`. Bookkeeping lives here; the design doc's status table is not ticked.

## Status

| Phase | Status | Notes |
|-------|--------|-------|
| 27.0 | Completed | GPT-6 / later-family routing in `lib/allm/providers/openai.ex` |
| 27.1 | Completed | `Usage.cache_write_input_tokens`, `Request.prompt_cache`, `validate_prompt_cache/2`, `@summed_usage_fields` |
| 27.2 | Completed | Cache-usage normalization: OpenAI (both endpoints), Anthropic, Gemini; streaming + non-streaming |
| 27.3 | Completed | `put_prompt_cache/2` in OpenAI (both translators) and Anthropic; Gemini doc-only; recorder `--only acceptance` green live 2026-09-27 |
| 27.4 | Completed | `Chat.build_request/4` resolves + normalizes `prompt_cache:` (session-id key default); prefix-stability pin over four translators |
| 27.5 | Not Started | |

## Start Green (2026-09-27, HEAD `94ffa45`)

- `mix compile --warnings-as-errors && mix test` → exit 0; `612 doctests, 33 properties, 4921 tests, 0 failures, 14 excluded, 1 skipped`.
- Five pre-existing modified files (the user's in-flight work) left untouched: `lib/allm/providers/{elevenlabs/transcription,fake_speech,openai/speech}.ex`, `test/support/{openai_fixtures,pcm}.ex`. `README.md` was clean, so no stash was needed.

## 27.0 — GPT-6 model-family routing

### Checklist

- [x] One shared pattern (`@gpt5_or_later_family` source string, compiled into `@gpt5_or_later`) feeds `@endpoint_dispatch`'s gpt row, `@chat_completions_new_max_tokens_models` and `@chat_completions_reasoning_models`.
- [x] `gpt-(4o|4\.1)` alternation kept in the max-tokens table.
- [x] Docs updated in the same change: `@moduledoc` (max-tokens bullet, endpoint dispatch, reasoning controls), the `translate_options/2` max-tokens table (header renamed "Model regex" → "Model family", row now prose), and the `generate/2` routing sentence.

### Tests (`test/allm/providers/openai_test.exs`, describe "gpt-5-and-later model family", 5 tests)

- Positive table `gpt-5, gpt-5.6, gpt-5.6-luna, gpt-6-astra, gpt-6-sol, gpt-6-luna, gpt-10-x` → `:responses`. Red before the change (`gpt-6-astra` → `:chat_completions`).
- Negative rows `gpt-4o, gpt-4.1, gpt-3.5-turbo, gpt-image-2` → `:chat_completions`.
- Forced `:chat_completions` on `gpt-6-sol`: `max_completion_tokens` on the wire; `reasoning_effort: "low"` kept and no "reasoning controls ignored" log line.
- Extra (Contracts coverage): the max-tokens rename covers every later-family id and leaves `gpt-3.5-turbo`, `gpt-4-turbo`, `gpt-image-2` on `max_tokens`.
- `git --no-optional-locks grep -n 'gpt-5' test/allm/providers/openai*_test.exs` → 59 pre-existing hits (65 with the new block). Disposition: all **keep**. None pins the old regex source or gpt-6 fall-through; the suite passes them unchanged.

### Mutation checks (each binds: ≥1 failure, file restored after)

| Mutant | Failing test |
|---|---|
| `@chat_completions_reasoning_models` back to `~r/^gpt-5/` | "forced :chat_completions on gpt-6-sol keeps reasoning_effort on the wire" |
| family pattern `[1-9]\d` → `\d` (over-broad: matches `gpt-4o`, `gpt-3.5`) | negative-rows test (`gpt-4o` → `:responses`) |

### Verification

| Command | Exit |
|---|---|
| `mix test test/allm/providers/openai_test.exs test/allm/providers/openai_wire_test.exs` | 0 (2 properties, 127 tests, 0 failures) |
| `mix test && mix test --seed 0` | 0 / 0 (run once after 27.1, same tree; see below) |
| `mix credo --strict && mix dialyzer && mix format --check-formatted` | 0 / 0 / 0 |

### Deviations

- `[tactical]` The shared pattern is a source string (`@gpt5_or_later_family`) compiled twice with `Regex.compile!/2` at compile time, because the max-tokens table must prepend `gpt-(4o|4\.1)|` to it. A single `Regex.t()` attribute cannot be composed.
- `[tactical]` All three tables are now case-insensitive (`"i"`). Before, only `@endpoint_dispatch` was; the other two were case-sensitive. Effect: an upper-case id like `GPT-4O` now also gets `max_completion_tokens` and kept reasoning controls, consistent with how it was already dispatched. The design's example regex carried `/i`.

## 27.1 — Layer-A fields and validation

### Checklist

- [x] `usage.ex`: field, `@type`, `defstruct` (default `nil`), `__from_tagged__/1` bare read (safe: nil default), moduledoc table row and "Cached prompt tokens" section defining inclusive `input_tokens`.
- [x] `request.ex`: `@type prompt_cache`, `@type t`, `defstruct` (default `nil`), moduledoc table row + "Prompt caching" section with an `iex>` example (validate + JSON round-trip), `decode_prompt_cache/1` + `decode_retention/1`.
- [x] `validate.ex`: `validate_prompt_cache/2` next to `validate_response_format/2`, piped last in `request/1`; one `{:prompt_cache, :invalid_shape}` per request regardless of how many rules fail.
- [x] `embedding_batch.ex`: `:cache_write_input_tokens` in `@summed_usage_fields`.

### Tests

- `usage_test.exs` (+2): default/`new/1`; non-nil cache fields round-trip `term_to_binary` and `Jason.encode!/1 |> Serializer.from_json/1`.
- `request_test.exs` (+6): nil default and JSON nil round-trip; `%{key: "k", retention: :long}` restores the atom; nil key + `:short`; unknown retention string decodes without raising/minting an atom; partial and over-full persisted maps pass through undecoded; `decode_retention/1` table.
- `validate_test.exs` (+5): good inputs per row; row 1 (not nil / not exact two-key map: `true`, a binary, a keyword list, key-only, retention-only, three keys); row 2 (`""`, atom, integer key); row 3 (`"long"`, `:forever`, `nil` retention); several failing rules → exactly one error.
- `embedding_batch_test.exs` (MODIFY): summed-field fixture carries `cache_write_input_tokens` 2 + 4 == 6. The pre-existing "no field reset to its default" test independently goes red if the field is not registered (confirmed by mutant).

### Mutation checks (each binds: ≥1 failure, file restored after)

| Mutant | Failing test |
|---|---|
| drop `cache_write_input_tokens` from `Usage.__from_tagged__/1` | usage JSON round-trip |
| `decode_prompt_cache/1` skips `decode_retention/1` | request JSON round-trip restores `:long` |
| drop `map_size(map) == 2` in `decode_prompt_cache/1` | partial/over-full map passes through |
| remove `validate_prompt_cache/2` from the pipeline | retention row |
| drop `map_size(pc) == 2` in the validator | exact-two-keys row |
| accept `""` as key | key row |
| drop the field from `@summed_usage_fields` | embedding_batch "no field reset" |

### Verification

| Command | Exit |
|---|---|
| `mix test test/allm/usage_test.exs test/allm/request_test.exs test/allm/validate_test.exs test/allm/embedding_batch_test.exs test/layer_a_docs_test.exs` | 0 (31 doctests, 2 properties, 136 tests, 0 failures) |
| `mix compile --warnings-as-errors` | 0 |
| `mix test` | 0 (613 doctests, 33 properties, 4939 tests, 0 failures, 14 excluded, 1 skipped) |
| `mix test --seed 0` | 0 (same counts) |
| `mix credo --strict` | 0 (no issues) |
| `mix dialyzer` | 0 (Total errors: 0) |
| `mix format --check-formatted` | 0 |
| `mix run scripts/audit_user_docs.exs lib/allm/usage.ex lib/allm/request.ex lib/allm/validate.ex lib/allm/providers/openai.ex lib/allm/embedding_batch.ex` | 0 (0 hits across 5 files; `validate.ex` had no pre-existing hit at this HEAD either) |

Test delta vs Start Green: +18 tests, +1 doctest (4921 → 4939; 612 → 613).

### Deviations

- `[tactical]` `decode_prompt_cache/1` decodes only when the map has exactly the two keys (`map_size(map) == 2` guard), mirroring `restore_response_format/1`'s `json_object` guard. Without it a persisted map with a third key would decode and silently drop that key, and `Validate` could no longer reject it. The design's clause listing did not state the guard; its stated intent ("a persisted partial map decodes without raising and `Validate` rejects it") requires it.
- `[tactical]` `Request.decode_retention/1` is `@doc false def` with `@spec`, not `defp`: the design names 27.4's `Chat.build_request/4` string-keyed normalization as a foreseen second caller ("through the same `decode_retention/1`"), and IMPLEMENTATION.md lands foreseen second callers at their final visibility.
- `[tactical]` The Usage moduledoc omits the design's "Adapters never replace a missing wire field with `0`" sentence, keeping only the `nil`/`0` meaning. The adapter-behaviour claim is not pinned by any test until 27.2's decoding tests exist.

### Notes for 27.2

- **The `ALLM.Usage` moduledoc now defines `input_tokens` as inclusive of cached reads and cache writes.** Until 27.2 lands, the Anthropic adapter still reports the raw (exclusive) count on cache-active requests. This is a transient gap between the Layer-A definition and one adapter, closed by 27.2's Decision #1 work; 27.1 cannot close it without touching Layer B.

## 27.2 — Cache-usage normalization

### Checklist

- [x] OpenAI: `lift_cache_details/2` (one private helper) called by `decode_usage/1` (Chat Completions, non-streaming) and `decode_responses_usage/1` (Responses, non-streaming). `maybe_append_usage/3` (Chat Completions, streaming) and `responses_usage_events/1` (Responses, streaming) now emit `Map.from_struct(<non-streaming decoder>(usage))`, so equality holds by construction.
- [x] OpenAI: `put_stream_usage_option/2` in `do_stream/2` — `Map.put_new(body, "stream_options", %{"include_usage" => true})` for `:chat_completions` only.
- [x] Anthropic: inclusive `decode_usage/1` (`input + read + creation`, nil when raw input is nil, absent cache counter counts 0 but stays `nil` on its field), normalized `total_tokens`, `extra["uncached_input_tokens"]`; stream state `start_usage: nil`, set on `message_start`; `message_delta` merges (`merge_stream_usage/2`, non-nil delta keys win) and emits ONE usage chunk through the shared decoder, including when the delta has no `usage` key.
- [x] Gemini: `parse_usage/1` lifts `cachedContentTokenCount`; `handle_usage_metadata/2` emits `Map.from_struct(parse_usage(um))`.
- [x] `test/support/finch_stub.ex`: `captured_request` stored in both install modes; `captured_request/1`.
- [x] Synthesized fixtures (JSON `_comment: "Synthesized — Phase 27.2 …"`, SSE first line `: synthesized — Phase 27.2 …`) and `test/support/cache_usage_fixtures.ex` (loads only through the existing loaders; `synthesized?/1` reads raw bytes).
- [x] Docs: "Cached prompt usage" section with an `iex>` block in `generate/2` of all three adapters; `OpenAI.stream/2` "Usage on a stream" (injected `stream_options` default); Anthropic stream event table row; Gemini moduledoc "Usage decoding".

### HYPOTHESIS outcomes

- **Gemini streaming drop — CONFIRMED.** `handle_usage_metadata/2` built a four-key `pre_mapped` map (`input_tokens`, `output_tokens`, `total_tokens`, `extra`). Lifting `cachedContentTokenCount` in `parse_usage/1` alone would have removed it from `extra` and dropped it from the stream. Mutant M20 (restore the four-key projection) turns `cache_usage_family_test.exs` "gemini streaming-collected usage equals non-streaming" red.
- **FinchStub cannot expose the streaming body — CONFIRMED.** `async_request_local/4` ignored `_req` and `async_request_shared/2` never received it. Both now store it.

### Tests

- `test/allm/providers/cache_usage_family_test.exs` (NEW, 17 tests): raw-bytes provenance premise guard; per row (OpenAI Chat, Responses, Anthropic, Gemini) — literal counts, streaming ≡ non-streaming whole-`%Usage{}` equality (incl. `extra`), and `cached + (write || 0) <= input` on BOTH paths; "no cache fields → nil, never 0" for all four.
- `anthropic_stream_wire_test.exs` (+6): output-only delta → inclusive input; cumulative delta → same `%Usage{}` (no double count); `happy_text.sse` → `input_tokens: 10` (semantic change: was `nil`); null `input_tokens` in delta keeps start's integer; delta without `usage` still emits once; no `message_delta` → no usage.
- `anthropic_wire_test.exs` (+2): inclusive input, normalized total, `uncached_input_tokens`, lifted keys absent, `cache_creation` + `service_tier` kept; no cache fields → raw input, nil counters.
- `openai_stream_wire_test.exs` (+5): `include_usage: true` on Chat body (via `FinchStub.captured_request/1`); caller's `stream_options` wins; Responses body has no `stream_options`; streamed cache counts on both endpoints.
- `openai_wire_test.exs` (+2): `extra["prompt_tokens_details"] == %{"audio_tokens" => 0}`; emptied `input_tokens_details` dropped.
- `gemini_wire_test.exs` (+1) and `gemini_stream_test.exs` (+2: `:cache_usage` added to the equivalence harness, whose assertions now also compare `cached_input_tokens`, `cache_write_input_tokens` and `extra` for every fixture — (MODIFY); plus a streamed-value test).
- Doctests +2 net in the full suite (613 → 615).

### Contract-flip triage

- The design's grep (`git grep -n 'extra' … | grep -iE 'cache|prompt_tokens_details|input_tokens_details|cachedContent'`) → 0 hits, exit 1. No test asserted a cache key in `usage.extra`; no fixture outside the new ones carries a cache field (`grep -rlE 'cache_read_input_tokens|cache_creation_input_tokens|cached_tokens|cachedContentTokenCount' test/fixtures` → only images fixtures + the 27.2 files).
- Existing usage assertions on the changed paths, all **keep** (pass unchanged): `anthropic_stream_wire_test.exs:305` (usage_stream; now also reports `input_tokens: 12`, not asserted); `anthropic_test.exs:725`; `anthropic_wire_test.exs:84`; `openai_stream_wire_test.exs:246` (usage_chunk) and `:438` (Responses, partial `match?` on the payload map — still matches the wider payload); `gemini_stream_test.exs:95`, `:114`; `gemini_test.exs:65`, `:410-436`. **Flipped:** `gemini_stream_test.exs` equivalence harness (extended, see Tests). No test asserted Anthropic `input_tokens` on a cache-bearing fixture, and none asserted the old streamed `input_tokens: nil`.
- **Semantic change to existing emissions (payload widening, not rerouting):** every adapter's streaming `{:raw_chunk, {:usage, map}}` now carries the full `%Usage{}` key set. OpenAI Chat streaming gains `reasoning_tokens` + `extra` (previously three keys); Anthropic streaming gains `input_tokens` from `message_start`, `total_tokens`, cache counters and `extra`; Gemini streaming gains the cache counter. No existing test site asserted the narrower shape by equality.

### Mutation checks (each binds: ≥1 failure with `--max-failures 1 --timeout 5000`; sources restored, md5-verified)

| Mutant | First failing test |
|---|---|
| M1 OpenAI lift returns `{nil, nil, usage}` | family "openai_responses non-streaming usage reports the fixture's cache counts" |
| M2 details object kept wholesale in `extra` | openai_wire "cache keys lifted; prompt_tokens_details keeps its other keys" |
| M3 details object always dropped | openai_stream_wire "Chat Completions final usage chunk → cache counts" |
| M4 Chat streaming back to three-key payload | family "openai_chat cached + write <= input holds on both paths" |
| M5 Responses streaming nils the cache fields | family "openai_responses streaming-collected usage equals non-streaming" |
| M6 no `put_stream_usage_option` | openai_stream_wire "Chat Completions asks for usage with include_usage: true" |
| M7 `Map.put` instead of `put_new` | openai_stream_wire "a caller-supplied stream_options in request.options wins" |
| M8 `stream_options` on every endpoint | openai_stream_wire "a Responses streaming body carries no stream_options key" |
| M9 Anthropic exclusive `input_tokens` | family "anthropic non-streaming usage reports the fixture's cache counts" |
| M10 absent cache counter not counted as 0 (raises) | anthropic_stream_wire "happy_text.sse now reports message_start's input_tokens" |
| M11 delta `nil`s not rejected | anthropic_stream_wire "a null input_tokens in message_delta never wipes…" |
| M12 no emission when delta has no usage | anthropic_stream_wire "…no usage key still emits message_start's usage once" |
| M13 start usage wins over delta | family "anthropic streaming-collected usage equals non-streaming" |
| M14 start + delta summed (double count) | family "anthropic streaming-collected usage equals non-streaming" |
| M15 missing cache read reported as `0` | family "no cache fields on the wire → nil, never 0 Anthropic" |
| M16 no `uncached_input_tokens` | anthropic_wire "cache fields → inclusive input_tokens, normalized total, raw count in extra" |
| M17 `total_tokens` from raw input | family "anthropic non-streaming usage reports the fixture's cache counts" |
| M18 Gemini count not lifted | family "gemini cached + write <= input holds on both paths" |
| M19 Gemini key left in `extra` | gemini_wire "cachedContentTokenCount → cached_input_tokens; write nil; key leaves extra" |
| M20 Gemini stream four-key projection | family "gemini streaming-collected usage equals non-streaming" |
| M21 Anthropic also emits usage at `message_start` | anthropic_stream_wire "no message_delta → no usage emitted" |

### Verification

| Command | Exit |
|---|---|
| `mix compile --warnings-as-errors` | 0 |
| `mix test test/allm/providers/` | 0 (162 doctests, 4 properties, 2478 tests, 0 failures, 14 excluded, 1 skipped) |
| `mix test` | 0 on the final tree, repeated (615 doctests, 33 properties, 4974 tests, 0 failures). **One** earlier random-seed run of the same tree exited 2 with 1 failure; seed and test name were not captured, and 20 further random-seed runs plus `--seed 0` were green. Unattributed — see HANDOFF. |
| `mix test --seed 0` | 0 (same counts) |
| `mix credo --strict` | 0 (after aliasing `GeminiTestFixtures` in `gemini_wire_test.exs`) |
| `mix dialyzer` | 0 |
| `mix format --check-formatted` | 0 |
| `mix run scripts/audit_user_docs.exs lib/allm/usage.ex lib/allm/providers/openai.ex lib/allm/providers/anthropic.ex lib/allm/providers/gemini.ex` | 0 hits |

Test delta vs 27.1: +35 tests, +2 doctests (4939 → 4974; 613 → 615).

### Deviations

- `[tactical]` Added `test/fixtures/gemini/synthesized/cache_usage.sse` (not in the Module Tree, which lists only `cache_usage.json` for Gemini). The family table and the Gemini harness row need a streaming fixture with the same counts.
- `[tactical]` The family test wraps the Chat decoder (`decode_chat/2`): `OpenAI.from_openai_response/2`'s second argument is the endpoint atom (`:chat_completions`), not an opts list as the design's seam list implies.
- `[tactical]` Anthropic adds `extra["uncached_input_tokens"]` only when the raw `input_tokens` is an integer, so an absent count never becomes a `nil` entry in `extra`.
- `[tactical]` The Usage-decoding table's "removed from `extra` … only when both of its keys above were read" contradicts the correction bullet under it. Implemented the correction: the lifted keys that are present are removed; the details object is dropped only when that leaves it empty.
- `[structural, documented]` `lib/allm/usage.ex` (27.1's file) edited, doc-only, per HANDOFF: the "adapters never replace a missing wire field with `0`" sentence is restored with its pinning cite (`cache_usage_family_test.exs:112`), and the hit-ratio claim now cites `cache_usage_family_test.exs:99`. Supersedes 27.1's third deviation.
- `[tactical]` `FinchStub.async_request_shared/2` became `/3` (private) to receive the request.

### Fix pass (b2)

- Code-review F1 (Medium) fixed, doc-only: the Anthropic `generate/2` "Cached prompt usage" section and the `ALLM.Usage` "Cached prompt tokens" section now state that `ALLM.Capability.populate_costs/2` prices every `input_tokens` token (cached reads and cache writes included) at the plain input rate, so `input_cost` on a cache-active call differs from provider billing; cache-aware pricing is not implemented. The review named the private `apply_pricing/2`; the docs cite the public `populate_costs/2` (`lib/allm/capability.ex:438`).
- Code-review F2 (Low, DEFER→HANDOFF) transcribed to `.work/HANDOFF.md` for 27.5. `stream_adapter.ex` item 5 and the `StreamCollector` usage-fold paragraph were re-read: still true (a `Map.from_struct/1` of `%Usage{}` carries only `%Usage{}` keys), so carve-out 1 did not apply and neither file was edited.
- Left for the phase-end polish pass: code-review F3; functional review Known Issues #2 (design choice, behaviour unchanged) and #3 (RECORDS deviation 3 unpinned). Functional Known Issue #1 (top-level `plug:`) is pre-existing, for the retro.

| Command | Exit |
|---|---|
| `mix run scripts/audit_user_docs.exs lib/allm/usage.ex lib/allm/providers/anthropic.ex` | 0 hits |
| `mix test` (seed 228704) | 0 (615 doctests, 33 properties, 4974 tests, 0 failures, 14 excluded, 1 skipped) |
| `mix test --seed 0` | 0 (same counts) |
| `mix credo --strict` | 0 |
| `mix dialyzer` | 0 |
| `mix format --check-formatted` | 0 |

## 27.3 — Adapter translation of `prompt_cache`

### Checklist

- [x] `put_prompt_cache/2` in `openai.ex` (private), ONE helper called from both `to_openai_request_body/3` clauses (`:chat_completions`, `:responses`), before the `request.options` merge. `key` → `prompt_cache_key` (verbatim, omitted when nil); `:long` → `prompt_cache_retention: "24h"`; `:short` sends no retention.
- [x] `put_prompt_cache/2` in `anthropic.ex` (private, same name), in `to_anthropic_request_body/1` before the options merge. `:short` → `cache_control: %{"type" => "ephemeral"}`, `:long` adds `"ttl" => "1h"`; the key is never sent.
- [x] Gemini: `## Prompt caching` section on `generate/2` (ignored without error), with an `iex>` block proving the body is unchanged. No code change, no helper.
- [x] `scripts/record_prompt_cache_fixtures.exs` created with `--only acceptance` (OA-P1, OA-P2, AN-P2 plus OA-C / AN-C controls; no fixture writes). Structure ready for 27.5: `recording_arms/0` (empty) feeds the overwrite guard `pending_paths/0` (JSON `_comment` / SSE `: synthesized` markers), so a bare run today makes zero HTTP calls and says so; want/got table + `System.halt(1)` before any write; `.env` loaded via guarded `EnvLoader` (per key: preset values restored after the load).
- [x] Each adapter's `generate/2` `@doc` gains a `## Prompt caching` section naming the retention value it sends, each with an `iex>` block (OpenAI: `"24h"`; Anthropic: `ttl: "1h"` and no key in the encoded body; Gemini: unchanged body).

### Tests (+25 tests, +2 doctests; 4974 → 4999, 615 → 617)

- `openai_wire_test.exs` describe "prompt_cache translation" (+13): the 2 endpoints × 3 columns table as a `for` comprehension asserting `body == Map.merge(nil_body, added)` (exact added keys, nothing else changed); `nil` byte-identical to a request built without the field (both endpoints); `key: nil` + `:short` adds no key; `key: nil` + `:long` sends only the retention; raw `prompt_cache_key` / `prompt_cache_retention` in `options` win on BOTH endpoints (`:698`); key `"Recipe 42/é ÜBER"` verbatim on both endpoints, decoded and in the raw JSON (`:711`); ten invalid shapes (`:bogus`, `true`, `%{}`, partial, bad retention, `""` key, integer key, three keys, string-keyed) leave the body byte-identical, both endpoints; end-to-end through `generate/2` (`Req.Test` plug in `adapter_opts`, `api_key:` per call) on `gpt-4o-mini` → `/v1/chat/completions` and `gpt-5.6` → `/v1/responses`.
- `anthropic_wire_test.exs` describe "prompt_cache translation" (+9): the 3-column table; `nil` byte-identical; the key string never appears in the encoded body (`refute Jason.encode!(body) =~ "recipe-42"`); `key: nil` translates the same as a keyed request; raw `cache_control` in `options` wins (`:715`); nine invalid shapes leave the body byte-identical; end-to-end through `generate/2` asserting `cache_control` on the wire and no `anthropic-beta` header.
- `gemini_wire_test.exs` describe "prompt_cache is ignored" (+3): the 3-column table, each byte-identical to the no-field body (system + user request). Green before any code change, as expected for a no-op row; its falsifier is any future Gemini translation of the field.
- No test can reach a real host: every translation test calls the body builder directly; the three end-to-end tests route through `adapter_opts: [plug: {Req.Test, stub}]` and non-streaming `generate/2` (no Finch).

### Mutation checks (each binds: ≥1 failure with `--max-failures 1 --timeout 5000` over the three wire files + `validate_test.exs`; sources restored, md5-verified)

| Mutant | First failing test |
|---|---|
| M1 `:chat_completions` clause skips `put_prompt_cache` | "key: nil with :long sends only the retention" |
| M2 `:responses` clause skips it | "responses: prompt_cache %{…:long} adds exactly …" |
| M3 / M3b translation after the options merge (each endpoint) | "raw prompt_cache_key in options wins … on both endpoints" |
| M4 `:long` → `"in_memory"` | "chat_completions: prompt_cache %{…:long} adds exactly …" |
| M4b `:long` sends nothing | same |
| M4c `:short` also sends `"24h"` | "responses: prompt_cache %{…:short} adds exactly …" |
| M5 key downcased / M5b spaces replaced | "the key is sent verbatim …" |
| M6 nil key written as `"prompt_cache_key" => nil` | "key: nil with :short adds no prompt_cache_key at all" |
| M7 OpenAI guard loosened to `%{retention: r}` | "an invalid prompt_cache … leaves the body unchanged" |
| A1 Anthropic translation after the options merge | "raw cache_control in options wins over the typed field" |
| A2 Anthropic sends the key inside `cache_control` | "a key: nil request translates the same as a keyed one"; run alone against the describe, "the cache key never appears anywhere in the encoded body" also fails |
| A3 `:long` without `ttl` / A3b `:short` with `ttl: "5m"` | end-to-end `generate/2` test / `:short` table cell |
| A4 Anthropic guard loosened | "an invalid prompt_cache … leaves the body unchanged" |
| A5 Anthropic not wired | `:short` table cell |
| A6 `anthropic-beta` header added to every request | "generate/2 puts cache_control on the wire and sends no beta header" |
| G1 `is_prompt_cache` drops `map_size == 2` | `validate_test` "prompt_cache must be nil or a map with exactly :key and :retention" |
| G2 `is_prompt_cache` accepts `""` | `validate_test` ":key must be nil or a non-empty binary" |

Recorder parity check: a copy of the script with OA-P2's literal set to `"in_memory"` halted with exit 1 and a probe-vs-adapter table before any HTTP call (dummy keys in the environment).

### Live acceptance (2026-09-27, `set -a; . ./.env; set +a; mix run scripts/record_prompt_cache_fixtures.exs --only acceptance` → exit 0)

Short prompt (`"Reply with the single word: ok"`), `max_output_tokens: 16` / `max_tokens: 16`: acceptance, not hits, so no ~5k prefix. Key per run: `allm-probe-<unix seconds>-<unique int>`. No fixture written. OpenAI arms on `POST /v1/responses`; Anthropic arms with no `anthropic-beta` header.

| Arm | Model | Want | Got |
|---|---|---|---|
| OA-P1 (`prompt_cache_key`) | gpt-5.6 | 200 | 200 |
| OA-P2 (+ `prompt_cache_retention: "24h"`) | gpt-5.6 | 200 | 200 |
| OA-P1 | gpt-6-luna | 200 | 200 |
| OA-P2 | gpt-6-luna | 200 | 200 |
| OA-P1 | gpt-5.4-nano | 200 | 200 |
| OA-P2 | gpt-5.4-nano | 200 | 200 |
| AN-P2 (top-level `cache_control`, `ttl: "1h"`) | claude-haiku-4-5-20251001 | 200 | 200 |
| AN-P2 | claude-sonnet-5 | 200 | 200 |
| AN-P2 | claude-sonnet-4-6 | 200 | 200 |
| OA-C control (`totallyNotAField: {}`) | gpt-5.6 | 400 | 400 |
| AN-C control (`totallyNotAField: {}`) | claude-haiku-4-5-20251001 | 400 | 400 |

Both controls rejected the invented field, so the 200s are evidence of schema membership (Responses endpoint; Chat Completions acceptance of the same fields is not probed here). Decision #9's escalation point did not fire. Response bodies were not recorded (27.5 records the control bodies).

### Verification

| Command | Exit |
|---|---|
| `mix test test/allm/providers/openai_wire_test.exs test/allm/providers/anthropic_wire_test.exs test/allm/providers/gemini_wire_test.exs` | 0 |
| `set -a; . ./.env; set +a; mix run scripts/record_prompt_cache_fixtures.exs --only acceptance` | 0 (11/11 arms as expected) |
| `mix run scripts/record_prompt_cache_fixtures.exs` (bare) | 0, zero HTTP calls (no recording arms yet) |
| `mix compile --warnings-as-errors` | 0 |
| `mix test` | 0 (617 doctests, 33 properties, 4999 tests, 0 failures, 14 excluded, 1 skipped) |
| `mix test --seed 0` | 0 (same counts) |
| `mix credo --strict` | 0 (no issues) |
| `mix dialyzer` | 0 (Total errors: 0) |
| `mix format --check-formatted` | 0 |
| `mix run scripts/audit_user_docs.exs lib/allm/providers/openai.ex lib/allm/providers/anthropic.ex lib/allm/providers/gemini.ex lib/allm/request.ex lib/allm/validate.ex` | 0 hits |

Start Green for 27.3 (tree at `b214bcd` + the user's five files): `mix compile --warnings-as-errors && mix test` → 0 (615 doctests, 33 properties, 4974 tests, 0 failures, seed 861830).

### Deviations

- `[structural, documented]` The valid-`prompt_cache` predicate is now ONE `defguard is_prompt_cache/1` (`@doc false`) in `lib/allm/request.ex` (27.1's file, not in 27.3's Module Tree). The design's Error Contract says `put_prompt_cache/2` "pattern-matches only the valid shapes"; writing that guard in both adapters would have made three copies of `validate_prompt_cache/2`'s guard. `ALLM.Validate.validate_prompt_cache/2` now calls the shared guard (private, behaviour-preserving migration-on-extraction, pinned by 27.1's `validate_test.exs` rows — mutants G1/G2). `require Request` added to `validate.ex`, `openai.ex`, `anthropic.ex`.
- `[tactical]` The acceptance mode also runs the negative controls OA-C and AN-C (without recording them). CLAUDE.md's probe rule pairs every acceptance arm with an invented-field arm in the same run; 27.5 still owns recording their bodies.
- `[tactical]` The recorder checks offline, before any HTTP call, that each acceptance arm's cache fields equal what the adapter's body builder adds for the same `prompt_cache`, so the probe tests the adapter's output, not a literal copy.
- `[tactical]` The recorder's `.env` loader handles two keys: it loads `.env` when either is unset, then restores any value that was already set, preserving the Voyage script's "explicit assignment wins" guarantee.
- `[tactical]` OpenAI acceptance arms run on the Responses endpoint only, as the design's arm table specifies; Chat Completions acceptance of the same two fields is unprobed (the translation is shared, and the unit tests pin both bodies). **Superseded by the b3 fix pass below:** Chat Completions is now probed on `gpt-4o-mini`.

### b3 fix pass (2026-09-27)

Sources: `.work/reviews/2026-09-27-prompt-caching-b3/overview.md`, `.work/code-reviews/2026-09-27-prompt-caching-b3.md`, `.work/security-reviews/2026-09-27-prompt-caching-b3.md` (clean), `.work/design-reviews/2026-09-27-prompt-caching-b3.md` (N/A).

- **Functional review Known Issue 1 (Medium, `retention: :long` → `"24h"` on pre-GPT-5 Chat Completions models unprobed) — CLOSED by a live arm, not deferred.** `scripts/record_prompt_cache_fixtures.exs --only acceptance` now carries an endpoint per arm and runs OA-P1 + OA-P2 on `POST /v1/chat/completions` against `ALLM_PROBE_OPENAI_CHAT_MODELS` (default `gpt-4o-mini`), plus a Chat Completions negative control OA-CC-C. The offline adapter-parity check builds each arm's expected fields with `OpenAI.to_openai_request_body/3` on that arm's endpoint, so the new arms are covered. Live run `set -a; . ./.env; set +a; mix run scripts/record_prompt_cache_fixtures.exs --only acceptance` → exit 0, 14/14 arms as expected:

| Arm | Endpoint | Model | Want | Got |
|---|---|---|---|---|
| OA-P1 / OA-P2 | responses | gpt-5.6, gpt-6-luna, gpt-5.4-nano | 200 | 200 (all six) |
| OA-P1 (`prompt_cache_key`) | chat_completions | gpt-4o-mini | 200 | 200 |
| OA-P2 (+ `prompt_cache_retention: "24h"`) | chat_completions | gpt-4o-mini | 200 | 200 |
| AN-P2 | messages | claude-haiku-4-5-20251001, claude-sonnet-5, claude-sonnet-4-6 | 200 | 200 (all three) |
| OA-C control | responses | gpt-5.6 | 400 | 400 |
| OA-CC-C control (`totallyNotAField: {}`) | chat_completions | gpt-4o-mini | 400 | 400 |
| AN-C control | messages | claude-haiku-4-5-20251001 | 400 | 400 |

  The Chat Completions control rejected the invented field, so `gpt-4o-mini`'s 200 on `"24h"` is evidence of acceptance, not of a permissive endpoint. No translation change. (Acceptance is not proof that 24h retention is *honoured* on that model; only that the field is accepted.)
- **Code-review F4 (Low; gate accept/refuse carve-out)** — fixed: the bare-run branch taken when `pending_paths/0` is non-empty now prints a stderr line and `System.halt(1)` instead of running acceptance and exiting 0 with nothing recorded. Verified with a scratch copy whose `recording_arms/0` returned one absent path → exit 1, zero HTTP calls; the real script's bare run → exit 0, "Nothing to record".
- **Code-review F1 (Medium DRY, DEFER→HANDOFF)** — not extracted (out-of-fence `[CHORE]`). Appended to `.work/HANDOFF.md`'s existing 22.4-fix and 22.7 item (1) rows: this recorder's `load_dotenv/1` / `overwritable?/1` are the extraction source; predicate `grep -l 'defp load_dotenv\|defp overwritable?' scripts/record_*.exs | wc -l` → 8.
- **Security informational note (27.5 error-body redaction)** — new Open HANDOFF row for 27.5.
- **Left for the phase-end polish pass (Lows, severity floor):** F2 (`load_dotenv/1` "scratch copy" comment and "mirrors Voyage" header wording), F3 (`:erlang.map_get/2` → `map_get/2`), functional Known Issue 2 (key check before mode dispatch), Known Issue 3 (`max_retries: 2` ineffective on POST).

Fix-pass gates (tree = batch 3 + this fix pass + the user's five files):

| Command | Exit |
|---|---|
| `mix test` | 0 (617 doctests, 33 properties, 4999 tests, 0 failures, 14 excluded, 1 skipped) |
| `mix test --seed 0` | 0 (same counts) |
| `mix credo --strict` | 0 |
| `mix dialyzer` | 0 (passed successfully) |
| `mix format --check-formatted` | 0 |

## 27.4 — Chat/Session wiring and prefix stability

### Checklist

- [x] `build_request/4` reads `:prompt_cache` from the resolved params map (`Engine.resolve_params/2`, so engine params apply and call opts win) and normalizes it per the call-opt table: `normalize_prompt_cache/2` + `atomize_prompt_cache_key/4` + `default_prompt_cache_key/1` in `lib/allm/chat.ex` (private, next to `build_request/4`). The string-keyed row calls the existing `Request.decode_retention/1` — no second copy (HANDOFF 27.1 row).
- [x] `:prompt_cache` added to `@local_request_carried_keys` ("handled by `extra`" group).
- [x] `lib/allm.ex` docs: new "Prompt caching (`:prompt_cache`)" section on `chat/3` with the normalization table and an `iex>` doctest (engine param + `session_id:` → `%{key: "recipe-42", retention: :long}` via Fake `:record`); `stream/3`, `step/3`, `stream_step/3` point to it; `generate/3` / `stream_generate/3` say to set `Request.prompt_cache` directly. `ALLM.Session` moduledoc "`session_id` propagation" gains the security sentence.
- [x] `chat_request_params_test.exs`: `:prompt_cache` in the carried-key literal, `probe_value(:prompt_cache) -> true`, plus an explicit R2-shaped engine-param test refuting `:prompt_cache` in `request.options`.
- [x] `test/allm/prompt_cache_chat_test.exs` and `test/allm/prompt_cache_prefix_stability_test.exs`.

### Tests (+42 tests, +2 doctests; 4999 → 5041, 617 → 619)

The one new `iex>` block counts twice because `ALLM` is doctested from both `test/allm_test.exs` and `test/allm_doc_test.exs`.

- `prompt_cache_chat_test.exs` (32): R1–R5 on `chat/3` AND `stream/3`; R6/R7 on `Session.reply/4` AND `stream_reply/4`; R8 (JSON round-tripped engine, with a premise guard that `restored.params.prompt_cache == %{"retention" => "long"}` so the string-keyed row is what is exercised); R9; R10 on `step/3` AND `stream_step/3`; plus one test per remaining table row (false, explicit-nil call opt overriding an engine param, session_id-alone never enables caching, `%{}`/`[]`, keyword, explicit nil key, explicit key never replaced, non-binary session_id, string-keyed full/partial, unknown retention string not atomized, unknown retention atom, non-keyword list, explicit `retention: nil`).
- `prompt_cache_prefix_stability_test.exs` (9): premise guard (snapshots strictly grow, contain `:system` and `:tool` messages); one pin per translator (OpenAI `:chat_completions` / `:responses`, Anthropic, Gemini) over a three-turn Session (text → tool call + result → text), requests built separately per snapshot with a fresh `Tool`, cache-field premise (`prompt_cache_key` / `cache_control` present; Gemini none); negative control per translator stamping the turn index into the system text, asserting `prefix_violations/2` reports both pairs (OpenAI trips (b), since system is in the message array; Anthropic/Gemini trip (a), since system is outside it — so both halves of the helper bind).
- `chat_request_params_test.exs` (+1).
- Stream R5 note: `stream/3` returns the `ValidationError` synchronously (first-step pre-flight), matching `chat/3`.

### Mutation checks (each binds: ≥1 failure with `--max-failures 1 --timeout 5000` over the three Verification test files; source restored from a scratch copy)

| Mutant | Bound |
|---|---|
| M1 drop the `false` clause (false passes through) | yes |
| M2 `true` → nil | yes |
| M3 keyword list not converted | yes |
| M4 no `"key"` atomization | yes |
| M5 `"retention"` not decoded | yes |
| M6 no default `:short` | yes |
| M7 explicit nil key kept nil | yes |
| M8 non-binary session_id used as key | yes |
| M9 `nil` prompt_cache turns caching on | yes |
| M10 `:prompt_cache` not in carried keys | yes |
| M11 read from `opts` instead of resolved params | yes |
| M12 explicit key overridden by session_id | yes |
| M13 no session-id default at all | yes |

### Verification (tree = 27.0–27.4 + the user's five files)

| Command | Exit |
|---|---|
| `mix test test/allm/prompt_cache_chat_test.exs test/allm/prompt_cache_prefix_stability_test.exs test/allm/chat_request_params_test.exs` | 0 (61 tests) |
| `mix test` (seeds 481848, 600147, 550974, 622602) | 0 each (final: 619 doctests, 33 properties, 5041 tests, 0 failures, 14 excluded, 1 skipped) |
| `mix test --seed 0` (run twice) | 0 |
| `mix compile --warnings-as-errors --force` | 0 |
| `mix credo --strict` | 0 |
| `mix dialyzer` | 0 (passed successfully) |
| `mix format --check-formatted` | 0 |
| `mix run scripts/audit_user_docs.exs lib/allm.ex lib/allm/session.ex lib/allm/chat.ex` | 0 hits |

### Deviations

- `[structural, documented]` `lib/allm/session.ex` edited, moduledoc only: the Module Tree has no `session.ex` row (Decision #5: "`session.ex` is not modified"), but the 27.4 Checklist and Security note require the "`session_id` propagation" sentence there. No code change.
- `[tactical]` Only a *missing* `:retention` defaults to `:short` (the table's literal wording); an explicit `retention: nil` passes through and `Validate` rejects it. `:key` is defaulted when missing *or* nil, as the table says. Pinned by "only a MISSING retention defaults…".
- `[tactical]` Normalization applies to every map, including one with neither `:key` nor `:retention` (e.g. `%{foo: 1}`): defaults are added and the extra key is kept, so `Validate` rejects it — the same outcome as the table's pass-through row.
- `[tactical]` The session-id default reads the call opt `:session_id` (the table's `opts[:session_id]`), not `engine.params`.
- Docs claims in `ALLM.chat/3` are pinned by `test/allm/prompt_cache_chat_test.exs` (table rows) and the section's own `iex>` block.

### b4 fix pass (2026-09-27)

- **Empty-string session id** (code-review F1 + functional-review Known Issue 1; both lanes found it without being pointed at it; both rated it Low; fixed on an orchestrator override of the severity floor). `default_prompt_cache_key/1` (`lib/allm/chat.ex:2084`) now guards `is_binary(session_id) and session_id != ""`, so `session_id: ""` falls back to `key: nil` the way a non-binary id already does. An explicit `prompt_cache: %{key: ""}` is still rejected. `ALLM.chat/3`'s "Prompt caching" wording now reads "only when it is a non-empty binary". New rows in `test/allm/prompt_cache_chat_test.exs`: chat/3 empty sid → `%{key: nil, retention: :short}`; explicit `key: ""` → `{:prompt_cache, :invalid_shape}`; `Session.reply/4` and `Session.stream_reply/4` on `Session.new(id: "")` → nil key (+4 tests).
- Mutation M14 (guard reverted to `when is_binary(session_id)`), run as `mix test test/allm/prompt_cache_chat_test.exs` → 3 failures (chat/3 row, reply, stream_reply): binds. Source restored, `grep -n 'session_id != ""' lib/allm/chat.ex` → :2084.
- Deferred to the polish pass (Low): code-review F2 (comment pointer), F3 (prefix-test scope), and functional Known Issues 2–4. KI4 was checked against carve-out 1. The docs list keyword as an accepted *value*, which is true at call time, and do not recommend keyword on `engine.params`. So no sentence is false, and the carve-out does not apply.

| Command | Exit |
|---|---|
| `mix run scripts/audit_user_docs.exs lib/allm.ex lib/allm/chat.ex` | 0 hits |
| `mix test` (first run) | 1 failure, not captured, test name unknown (619 doctests, 33 properties, 5045 tests); 5 later full runs → 0 failures each. Unattributed intermittent failure |
| `mix test --seed 0` | 0 (619 doctests, 33 properties, 5045 tests, 0 failures) |
| `mix credo --strict` | 0 |
| `mix dialyzer` | 0 |
| `mix format --check-formatted` | 0 |
