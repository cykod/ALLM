# Phase 27 Prompt Caching — Records

Companion to `steering/2026-09-27_PROMPT_CACHING_DESIGN.md`. Bookkeeping lives here; the design doc's status table is not ticked.

## Status

| Phase | Status | Notes |
|-------|--------|-------|
| 27.0 | Completed | GPT-6 / later-family routing in `lib/allm/providers/openai.ex` |
| 27.1 | Completed | `Usage.cache_write_input_tokens`, `Request.prompt_cache`, `validate_prompt_cache/2`, `@summed_usage_fields` |
| 27.2 | Completed | Cache-usage normalization: OpenAI (both endpoints), Anthropic, Gemini; streaming + non-streaming |
| 27.3 | Not Started | |
| 27.4 | Not Started | |
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
