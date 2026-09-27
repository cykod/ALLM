# Phase 27 Prompt Caching — Records

Companion to `steering/2026-09-27_PROMPT_CACHING_DESIGN.md`. Bookkeeping lives here; the design doc's status table is not ticked.

## Status

| Phase | Status | Notes |
|-------|--------|-------|
| 27.0 | Completed | GPT-6 / later-family routing in `lib/allm/providers/openai.ex` |
| 27.1 | Completed | `Usage.cache_write_input_tokens`, `Request.prompt_cache`, `validate_prompt_cache/2`, `@summed_usage_fields` |
| 27.2 | Not Started | |
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
