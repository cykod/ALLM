# Phase 2: Engine + Keys — Design Document

> **Goal:** Finish the Layer B runtime surface so callers can construct an engine, attach tools, resolve effective options for an adapter call, and look up API keys at adapter-call time without ever putting a key on the engine struct.
> **Outcome:** `ALLM.Engine` exposes the full §6.2 API (resolver functions plus the existing builder helpers); `ALLM.Keys` ships with the five-level resolution chain (call opts → in-process override → app config → env → optional `.env`); engines round-trip through `:erlang.term_to_binary/1`; `resolve_model/2` works with and without `llm_db` loaded; `mix test`, `mix credo --strict`, `mix dialyzer`, and `mix format --check-formatted` are clean.
> **Spec sections:** §6.1, §6.2, §6.3, §6.4, §10 (option precedence), §20 (error reasons)
> **Layers touched:** B (Runtime). No Layer A struct shapes change; no Layer C/D surface is added.
> **Phasing doc:** [`PROJECT_PHASING.md`](PROJECT_PHASING.md) Phase 2.

## Status

| Sub-phase | Description | Layer | Status |
|-----------|-------------|-------|--------|
| 2.1 | Engine resolver API: `merge_opts/2`, `resolve_model/2`, `resolve_tools/2`, `resolve_params/2` | B | Completed |
| 2.2 | `ALLM.Keys` module with five-level resolution chain | B | Completed |
| 2.3 | Engine serializability hardening + `llm_db`-absent property tests | B | Completed |
| 2.4 | Engine integration test (construct → serialize → deserialize → resolve) | B | Completed |

**Overall Progress:** 4/4 sub-phases complete

## Overview

Phase 2 fills out Layer B. Today `ALLM.Engine` has the struct, `new/1`, and the four mutator helpers (`put_tool`, `put_tools`, `put_param`, `put_context`, `with_model`) — but it has no resolution functions, so no later phase can build "the effective model / tools / params for this call." There is also no `ALLM.Keys` module: callers cannot look up a key by provider, and there is no documented path for "set the key for this process only" (which the test suite needs in Phase 4 and onward to drive `ALLM.Providers.Fake` without ambient state). This phase ships the four `resolve_*` / `merge_opts` functions per spec §6.2, the full `ALLM.Keys` module per §6.4, and the load-bearing **engine serializability** test that proves the engine carries only modules, atoms, and plain data — no PIDs, refs, funs, or raw keys.

This design **refines spec §6.4 by introducing a tiny built-in `.env` parser** rather than depending on a third-party library. The spec describes level 5 of the key resolution chain as "`.env` file at project root (opt-in via `config :llm, load_dotenv: true`)" without naming a parser. A `KEY=VALUE` parser supporting `#` comments, blank lines, surrounding double-quote stripping, and `export KEY=VALUE` is ~30 lines of pattern-matching code with no quoting edge cases (because the file is read once at startup and only the lines whose key matches `~r/^[A-Z_][A-Z0-9_]*$/` are honored — anything else is silently ignored). Pulling in `dotenvy` for this is a heavier dependency than the feature warrants, and the spec already keeps `.env` opt-in. No spec amendment is required.

This design **defers `ALLM.ModelRef` and capability pre-flight to a later phase**. Spec §6.3 describes a `%ALLM.ModelRef{}` struct that `LLMDB.model/1` returns and that `resolve_model/2` may produce. The phasing doc puts capability pre-flight in Phase 9 ("Telemetry, Capability Pre-flight, and Retries"), which is the natural home for it because pre-flight requires the request validator and the engine resolver to compose. Phase 2 ships `resolve_model/2` as **a pass-through** when `llm_db` is absent and a **delegate to `LLMDB.model/1`** when present — but the result type stays `String.t() | tuple() | nil` (the same shapes the caller passed in). The `%ALLM.ModelRef{}` struct lands when capability pre-flight does. This keeps Phase 2 self-contained and preserves the spec's "core must function without `llm_db`" rule (§6.3).

### Deliverables

- **Modified modules**: `ALLM.Engine` (add `merge_opts/2`, `resolve_model/2`, `resolve_tools/2`, `resolve_params/2`; add `@doc` + doctests to existing helpers; add `defimpl Jason.Encoder` and `__from_tagged__/1` consistent with Layer A's serialization pattern. The encoder emits module names as binaries (`inspect/1`); the decoder uses `String.to_existing_atom/1` and rescues `ArgumentError` to surface `{:adapter, :module_not_loaded}` — **never `Module.concat/1` on JSON-derived strings** (the 2.3 decoder path), which would create phantom atoms from untrusted input and is a known atom-table-exhaustion vector. `Module.concat/1` on **hard-coded string literals** (e.g., `Module.concat(["LLMDB"])` for optional-dep detection in `resolve_model/2`, Sub-phase 2.1) is allowed — the atom is pre-declared by the source code, bounded at one atom for the process lifetime, not derived from input).
- **New modules**: `ALLM.Keys` (the five-level resolver), `ALLM.Keys.Store` (private — the `Agent`-backed in-process key store), `ALLM.Keys.Dotenv` (private — minimal `.env` parser).
- **New tests**: `test/allm/engine_test.exs`, `test/allm/keys_test.exs`, `test/allm/keys/store_test.exs`, `test/allm/keys/dotenv_test.exs`, `test/allm/engine_property_test.exs` (StreamData over resolve precedence), `test/allm/engine_roundtrip_test.exs` (term_to_binary + Jason for the engine).
- **Test fixtures**: `test/fixtures/sample.env` for `Dotenv` parsing tests.
- **Application supervision**: `ALLM.Application` (NEW) with a single child — `ALLM.Keys.Store` — added under `mix.exs`'s `mod:` key so `Application.ensure_all_started(:allm)` brings the key store up automatically.
- **Config**: documented config keys `config :allm, keys: %{provider => key}`, `config :allm, load_dotenv: true`, `config :allm, dotenv_path: "path/to/.env"` (default: `Path.join(File.cwd!(), ".env")`).

### Spec coverage

- **§6.1** Engine struct — unchanged shape, but adds round-trip tests proving the struct as currently defined satisfies the Layer B serializability invariant.
- **§6.2** Engine API — adds `merge_opts/2`, `resolve_model/2`, `resolve_tools/2`, `resolve_params/2`; refines existing helpers with `@doc` + doctests.
- **§6.3** Model catalog integration — `resolve_model/2` is `llm_db`-aware via `Code.ensure_loaded?(LLMDB)`. Without `llm_db`, all model strings/tuples pass through verbatim. With `llm_db`, the result is whatever `LLMDB.model/1` returns (typically a `%ALLM.ModelRef{}`, but Phase 2 does not declare or depend on that type — it's an opaque pass-through value).
- **§6.4** API key management — `ALLM.Keys.{put/2, get/1, fetch!/2}` with the five-level chain.
- **§10** Option precedence — `resolve_*` functions implement steps 1–4 of the chain (call opts → engine defaults → app config; library defaults are documented per option in later phases).
- **§20** Error model — `ALLM.Keys.fetch!/2` raises `ALLM.Error.EngineError{reason: :missing_key, provider: <atom>}` (atom is already in the closed reason enum from Phase 1).

### Layer demonstration

Phase 2 is entirely Layer B. A user consuming this phase can build a fully-resolved engine, look up keys by provider, and serialize the engine to disk — all without ever calling an adapter or running a stream. This snippet runs in `iex -S mix` after Phase 2 ships:

```elixir
# Layer B: build an engine, set a key for the current process, resolve options.
ALLM.Keys.put(:openai, "sk-test-…")

engine =
  ALLM.Engine.new(adapter: ALLM.Providers.Fake, model: "fake:gpt-test")
  |> ALLM.Engine.put_tool(ALLM.tool(name: "echo", description: "echo", schema: %{}))
  |> ALLM.Engine.put_param(:temperature, 0.2)

"fake:gpt-test"          = ALLM.Engine.resolve_model(engine, [])
"override-model"         = ALLM.Engine.resolve_model(engine, model: "override-model")
%{temperature: 0.7}      = ALLM.Engine.resolve_params(engine, temperature: 0.7)

"sk-test-…" = ALLM.Keys.fetch!(:openai)

# Engine round-trips to disk; keys do not leak.
serialized = :erlang.term_to_binary(engine)
^engine    = :erlang.binary_to_term(serialized)
```

No Layer A struct shape changes; no Layer C execution function exists yet. Phase 2 lets users prove the engine is a serializable value and that key resolution is decoupled from engine construction.

### Prerequisites

- **Phase 1 complete.** Phase 2 depends on `ALLM.Error.EngineError` (the `:missing_key` reason atom), `ALLM.Tool` (`Engine.put_tool/2` accepts `%Tool{}` values), and `ALLM.Serializer.encode_tagged/2` (the engine's Jason impl delegates to it).

### Out of scope

- **`ALLM.ModelRef` struct.** Lands in Phase 9 alongside capability pre-flight (§6.3). Phase 2 treats `llm_db`'s return value as an opaque pass-through — `resolve_model/2` returns whatever the catalog returns without asserting a shape.
- **Capability pre-flight.** Phase 9 (`tools_enabled`, `json_native`, context-length checks). Phase 2 does not call `LLMDB.capability?/2` or read the `:capabilities` field of any returned ref.
- **`select:` capability-based model selection.** Spec §6.3's `select: [require: [...], prefer: [...]]` syntax is part of capability pre-flight and lands in Phase 9.
- **Retry policy execution.** Phase 9 implements the actual retry loop. Phase 2 ships only the `:retry` field on the engine (already present) and a `Validate`-style sanity check that the `retry` value is one of `:default | false | keyword()`.
- **`ALLM.Validate.engine/1`.** No engine validator in Phase 2 — engine fields are validated by `Engine.new/1` via `struct!/2` for required-field shape only. Field-content validation (e.g., adapter is a module that implements `ALLM.Adapter`) requires the behaviours from Phase 3, so it lands there.
- **Session-level key resolution.** `ALLM.Session` does not call `ALLM.Keys`; sessions hold an engine (Phase 8) and the engine's adapter looks up the key at call time. Phase 2 makes no Session API changes.
- **Engine builder DSL or macro.** `ALLM.Engine.new/1` plus the explicit `put_*` helpers are the API. No `engine do ... end` block.
- **Multi-key support per provider** (e.g., `:openai_admin` vs `:openai_user`). The spec keys by provider atom; multiple keys per provider is a user-land pattern (use `ALLM.Keys.put(:openai, key)` before each call) and not built into the resolver.
- **Resolver-fn key sources.** `PROJECT_PHASING.md` Phase 2 raised "where `ALLM.Keys` stores resolver funs" as an open decision. v0.2 stores eagerly-resolved key strings only; `Keys.put(:openai, fn -> Vault.read("openai-key") end)` is **not** supported. Users with Vault-style backends wrap their own lazy resolver around `Keys.put/2`, calling it during application start or before the first adapter call. Rationale: storing strings keeps the Agent state JSON-inspectable for debugging and avoids the question of fn evaluation context (which process? which timeout? which error policy on failure?). Resolver-fn support is a v0.3 candidate behind a separate `ALLM.Keys.Resolver` behaviour.
- **Application config hot-reload.** `config :allm, keys: %{...}` is read once when looked up, no caching invariants. If the user changes config at runtime via `Application.put_env/3`, the next `Keys.get/1` sees it.

### Non-obvious decisions

1. **`ALLM.Keys.Store` is an `Agent`, not `:persistent_term` or ETS.** Three-way tradeoff:
   - `Agent`: simplest API, supervised by the application, easy to start/stop in tests, serializes writes (key install is rare).
   - `:persistent_term`: lockless reads (~5x faster than Agent), but every write copies all of `:persistent_term` and forces GC across all processes — designed for "set once at startup," not a runtime key store.
   - `ETS`: lockless concurrent reads, mutable, but requires owning a process anyway (so we'd still need a supervisor child) and adds a `:public` table whose ownership we'd have to document.

   `Agent` wins because (a) the keys API is `put/2` (write, rare) and `fetch!/2` (read, called per adapter call but bounded by HTTP latency — 100ns vs 100μs is irrelevant); (b) supervision is built in; (c) the Agent is trivially resettable in tests via `start_supervised!/1`. Future hot-path optimization can swap `Agent` for `:persistent_term` behind the same public API. `Docs target: @moduledoc ALLM.Keys`.

2. **Built-in `.env` parser, no `dotenvy` dep.** The dotenv format ALLM supports is a strict subset: `KEY=VALUE` lines, `# comment` lines, blank lines, and `export KEY=VALUE` (the leading `export` is stripped). Surrounding double quotes on the value are stripped. No variable interpolation, no multi-line values, no escape sequences. The parser loads **every** valid `KEY=VALUE` line into a string-keyed map (`%{"OPENAI_API_KEY" => "...", "OPENAI_ORG" => "...", "XAI_TOKEN" => "..."}`) — it does not restrict to keys ending in `_API_KEY`, so users with non-standard env vars (`XAI_TOKEN`, `GROQ_KEY`, etc.) get the same dotenv lookup behavior as the env-var layer. The `Keys.get/1` dotenv branch then looks up `env_var_for(provider)` in this map, exactly mirroring how the `:env` source uses `System.get_env/1`. This covers all real `.env` shapes for API keys and avoids a transitive dependency. `.env` parsing is opt-in via `config :allm, load_dotenv: true` and runs once on first `Keys.get/1` call (lazy load — see Decision #10 for the cache mechanism). `Docs target: @moduledoc ALLM.Keys` (parser limitations called out for users with complex .env files who should use `System.put_env/2` at boot or switch to `dotenvy` themselves).

3. **`resolve_model/2` returns the value verbatim — no struct wrap when `llm_db` is absent.** When `llm_db` is loaded, the function delegates to `LLMDB.model/1` and returns whatever that returns (typically `%ALLM.ModelRef{}` once Phase 9 lands). When absent, `resolve_model/2` returns the input value unchanged: a string returns a string, a tuple returns a tuple. The adapter is then responsible for parsing the form it accepts. This keeps Phase 2 catalog-agnostic and preserves the "core works without `llm_db`" invariant. `Docs target: @doc ALLM.Engine.resolve_model/2`.

4. **`resolve_tools/2` dedupes by `:name`, opts win, replacement is in-place.** Per spec §10's option precedence, call-opts override engine defaults. Concrete behavior: the result preserves `engine.tools` order; for each engine tool whose name appears in `opts[:tools]`, the opts version replaces it **at the same position**; remaining opts tools (no name collision with any engine tool) are appended in their `opts[:tools]` order. Example: `engine.tools = [a, b, c]`, `opts[:tools] = [b', d]` → `[a, b', c, d]`. This matches user intuition — `engine |> ALLM.generate(req, tools: [override_weather])` lets the caller patch a single tool without reordering the rest. `Docs target: @doc ALLM.Engine.resolve_tools/2`.

5. **`resolve_params/2` is a shallow merge of `engine.params` and the opts list with engine-field keys excluded; everything else passes through.** The result is a map. The opts list is filtered using a **deny-list** of engine struct fields (`:adapter`, `:adapter_opts`, `:model`, `:tools`, `:tool_executor`, `:tool_result_encoder`, `:image_adapter`, `:params`, `:context`, `:retry`, `:middleware`, `:metadata`, `:api_key`) — every other key flows through unchanged. This matches spec §10's "unknown options in `opts` are forwarded to the adapter unchanged" rule, so provider-specific opts like `:reasoning_effort` for OpenAI o-series models naturally land in the result map without the engine resolver having to know about them. Orchestration knobs (`:max_turns`, `:halt_when`, `:on_event`, timeouts, etc.) also flow through because the spec sample (§22) shows them living in `engine.params` already; downstream code (Phase 6/7) extracts what it needs by key. The deny-list is open for additions only when a new engine field is added to the struct itself. `Docs target: @doc ALLM.Engine.resolve_params/2`.

   **Implementation note (Sub-phase 2.4):** `:params` was added to the deny-list during 2.4 integration testing. The original 2.1 list matched the engine-field docs prose but omitted `:params` itself — the one field whose role is "the map being merged into." Scenario 3 of the 2.4 integration test (`opts = [model: "override", params: nil, temperature: 0.9, tools: [...]]`) surfaced the gap: without `:params` in the deny-list, `resolve_params/2` would have attempted to merge `nil` (or any caller-supplied replacement map) into `engine.params` via the opts pathway, contradicting Invariant 6's prose. The fix is a one-line addition to `@engine_field_keys`; `merge_opts/2`'s handling of `opts[:params]` is already map-typed via the `maybe_merge_params/2` helper, so this change narrows (not widens) the contract.

6. **`merge_opts/2` is convenience, not a primitive — and it does NOT call `put_tools/2`.** `put_tools/2` (Phase 1) is naive append (`engine.tools ++ more`); `merge_opts/2` needs the dedup-by-name semantics from `resolve_tools/2`. Implementation: `merge_opts/2` calls `resolve_tools(engine, opts)` and writes the result to `engine.tools` directly (bypassing `put_tools/2`). The two helpers are now intentionally distinct: `put_tools/2` is the explicit append builder for engine construction; `merge_opts/2` is the per-call override applier. `merge_opts/2` similarly handles `:model` via `with_model/2`, and `:params` / `:context` via shallow merge into the corresponding maps. Execution functions (Phase 5+) typically use the `resolve_*` functions to compute effective values rather than rebuilding an engine, but `merge_opts/2` is documented because some users will want a single engine value reflecting their per-call overrides (e.g., for telemetry or for passing to a pre-built helper). `Docs target: @doc ALLM.Engine.merge_opts/2` and `@doc ALLM.Engine.put_tools/2` (cross-reference both so the difference is unambiguous).

7. **Engine serializability rule: every field carries only modules, atoms, or plain serializable data.** The closed contract for `ALLM.Engine` field contents is:
   - `:adapter`, `:tool_executor`, `:tool_result_encoder`, `:image_adapter` — `module() | nil`. Round-trips trivially.
   - `:adapter_opts` — `keyword()` of serializable values only (atoms, binaries, numbers, booleans, nested lists/maps thereof). A keyword list containing a fun (e.g., a Finch retry callback) **passes** `:erlang.term_to_binary/1` (ETF silently encodes funs into a BEAM-private form — the unsafety is cross-boundary decode, `:badfun` on a different node or after hot reload — not encode time) and **fails** `Jason.encode!` (raises `Protocol.UndefinedError` — no `Jason.Encoder` impl for `Function`). The JSON boundary is where this contract is mechanically enforced. Atom values in the kwlist (e.g. `adapter_opts: [mode: :strict]`) survive ETF but lose type on JSON round-trip (become binaries) — the decoder restores kwlist keys via `String.to_existing_atom/1` but passes values through verbatim. This is the same asymmetry as `:params`/`:context`/`:metadata` values.
   - `:model` — `String.t() | nil`. Trivial.
   - `:tools` — `[Tool.t()]` where each tool's `:handler` is `nil` or `{Module, :function}`. An MFA tuple handler round-trips through **ETF only** — Jason cannot encode raw tuples (`Protocol.UndefinedError` on `Tuple`). A fully-JSON-safe representation (emit handler as `[module_str, fn_str]`) is a v0.3 enhancement. A tool with an **anonymous-function** handler **passes** `:erlang.term_to_binary/1` (same ETF-encodes-funs caveat as `:adapter_opts`) and **fails** `Jason.encode!` (raises `Protocol.UndefinedError` — no `Jason.Encoder` impl for `Function`).
   - `:params`, `:context`, `:metadata` — `map()` of serializable values. `Date`, `DateTime`, `Decimal` survive `term_to_binary` but the JSON round-trip is **non-equality-preserving**: Jason ships a `Jason.Encoder.DateTime` impl that emits ISO-8601 strings, but the library's decoder does not re-parse those back into `%DateTime{}` structs — so the decoded value is a binary, not the original struct. Users who need equality-preserving JSON round-trip must supply their own decoder (or keep these values out of serialized engines).
   - `:retry` — `:default | false | keyword()`. Trivial.
   - `:middleware` — `[]` in v0.2 per spec §29; trivial.

   **Stdlib exception shapes in this contract were empirically verified in IEx** — `:erlang.term_to_binary/1` silently encodes funs (does *not* raise `ArgumentError`); Jason raises `Protocol.UndefinedError` at protocol dispatch when no encoder exists for a value (not `Jason.EncodeError`, which is for encoders that exist but fail internally).

   The 2.3 test plan covers each failure mode with a positive or negative case so the contract is enforced by tests, not just prose. `Docs target: @moduledoc ALLM.Engine` (one paragraph stating the closed contract verbatim).

8. **`ALLM.Keys.fetch!/2` raises rather than returning `{:error, _}`.** This is the only function in the library that raises `ALLM.Error.EngineError` rather than returning it. Justification: keys are looked up at adapter-call time, deep inside an adapter implementation; bubbling `{:error, _}` from `fetch!/2` through every adapter would clutter every implementation with a `with` chain whose only purpose is to surface "no key configured for this provider." The bang version raises and lets adapters use the value directly; adapters wrap their public functions in `try/rescue` if they want to convert the raise to a `{:error, _}` return. `ALLM.Keys.get/1` is the non-raising variant, returning `{:ok, key, source}` or `{:error, :missing}` per spec §6.4 — that's the shape adapters use when they want to log "no key, falling back to env" diagnostics. `Docs target: @doc ALLM.Keys.fetch!/2`.

9. **Spec §6.4's `{:error, :missing}` shape on `Keys.get/1` is preserved verbatim**, even though Phase 1 established a "no atom-tuple errors" pattern for public returns. This is a deliberate exception: `Keys.get/1` is a primitive lookup whose only failure is "absent" — an `EngineError` struct here is overkill, and the spec types the function this way. `fetch!/2` is the user-facing version and **does** raise the struct. `Docs target: @doc ALLM.Keys.get/1` (one line referencing spec §6.4).

10. **`.env` file load is lazy and cached in the same `ALLM.Keys.Store` Agent that holds runtime keys.** First `Keys.get/1` after app start (when `:load_dotenv` is true) reads the file, parses it, and writes the result into the Agent's state under a `:dotenv_cache` key. Subsequent calls read from the Agent. Reset is a normal `Agent.update/3` call from tests — no `:persistent_term.erase/1` global GC, no separate `__reset__/0` test-only public hook (which would conflict with `AGENT_DESIGN_SPEC.md`'s "no test-only conditional compilation" rule). Sharing the Agent unifies supervision (one child under `ALLM.Application`, one ownership story) and makes test isolation trivial: `start_supervised!(ALLM.Keys.Store)` in a test gives a fresh state including a fresh dotenv cache. The original `:persistent_term` consideration was rejected for the same reasons as Decision #1: write cost is global GC, and we do write (on first call after each test). `Docs target: @moduledoc ALLM.Keys`.

## Behaviour & Type Contracts

### `ALLM.Engine` (Layer B — runtime, contains modules and may contain funs via tools)

```elixir
defmodule ALLM.Engine do
  alias ALLM.Tool

  # Existing types (unchanged):
  @type retry :: :default | false | keyword()
  @type t :: %__MODULE__{...}   # see lib/allm/engine.ex

  # New API surface — Phase 2:

  @spec merge_opts(t(), keyword()) :: t()
  def merge_opts(engine, opts)

  @spec resolve_model(t(), keyword()) :: String.t() | tuple() | struct() | nil
  def resolve_model(engine, opts)

  @spec resolve_tools(t(), keyword()) :: [Tool.t()]
  def resolve_tools(engine, opts)

  @spec resolve_params(t(), keyword()) :: map()
  def resolve_params(engine, opts)

  # Phase 2 also adds Jason serialization for engine round-trip:
  @doc false
  @spec __from_tagged__(map()) :: t()
  def __from_tagged__(data)
end

defimpl Jason.Encoder, for: ALLM.Engine do
  def encode(value, opts) do
    # :adapter_opts and kwlist-shaped :retry carry raw 2-tuples that Jason
    # cannot encode. Pre-pass them to list-of-pairs ([[k, v], ...]) before
    # delegating; the decoder reconstructs kwlists via restore_keyword/1.
    # This pre-pass is part of the contract — Jason has no encoder for
    # raw Elixir 2-tuples, so any struct field typed keyword() must be
    # transformed encoder-side. (Only ALLM.Engine carries keyword() fields
    # in v0.2; if a second Layer A/B struct adds one, extend
    # ALLM.Serializer.encode_tagged/2 generically instead of duplicating
    # the pre-pass — see retro/2026-04-21-phase-2-3-serializability.md
    # Finding 3.)
    ALLM.Serializer.encode_tagged(transformed_value, opts)
  end
end

# Required dispatcher wiring — the type contract is incomplete without it.
# Add `ALLM.Engine` to `ALLM.Serializer.@known_modules` so the JSON decoder
# routes tagged `{"__type__" => "ALLM.Engine", ...}` blobs through
# `__from_tagged__/1` and the existing `hydrate_with/2` rescue surfaces
# `{:_unknown, :atom_decode_failed}` on unloaded-module adapter strings.
# Without this registration, the 2.3 Test Plan's "`NonExistent.Module`
# adapter returns ValidationError with `[:_unknown, :atom_decode_failed]`"
# assertion cannot fire — the tagged blob would pass through the forward-
# compat path unchanged.
```

**Invariants:**

1. `resolve_model(engine, [])` returns `engine.model` verbatim when `llm_db` is not loaded.
2. `resolve_model(engine, model: m)` returns the result of catalog resolution applied to `m` (or `m` verbatim when no catalog), regardless of `engine.model`.
3. `resolve_tools(engine, [])` returns `engine.tools` (no catalog interaction).
4. `resolve_tools(engine, tools: ts)` preserves `engine.tools` order. Each engine tool whose `:name` matches a tool in `ts` is replaced **at the same position** by the matching opts tool. Opts tools whose `:name` doesn't match any engine tool are appended in `ts` order. Example: `engine.tools = [a, b, c]`, `ts = [b', d]` → `[a, b', c, d]`.
5. `resolve_params(engine, [])` returns `engine.params` unchanged.
6. `resolve_params(engine, opt_kwlist)` returns `Map.merge(engine.params, opts_with_engine_field_keys_excluded_as_map)` — provider-specific and orchestration opts flow through verbatim (§10).
7. `merge_opts(engine, opts)` returns an engine where each `opts` key recognized as an engine field has been written via the corresponding `put_*` / `with_*` helper. Unknown opts are silently dropped (they're for execution functions, not the engine).
8. Round-trip: `:erlang.term_to_binary(engine) |> :erlang.binary_to_term() == engine` for any engine whose tools have `nil` or `{Module, :function}` handlers.

**Idiomatic Elixir requirements:**

- `Engine.new/1` keeps `struct!/2` semantics (raises `KeyError` on unknown keys, accepts any subset of the documented fields). No `@enforce_keys` on the struct — `:adapter` may be `nil` at construction; the missing-adapter check fires at adapter-call time per spec §20 (`:missing_adapter`).
- `defimpl Jason.Encoder` block at the bottom of `lib/allm/engine.ex` (matches Layer A pattern).

### `ALLM.Keys` (Layer B — runtime; never serialized)

```elixir
defmodule ALLM.Keys do
  @moduledoc "API key resolution per spec §6.4. Keys never appear on the engine."

  @type provider :: atom()
  @type source :: :opts | :runtime | :app_config | :env | :dotenv

  @spec put(provider(), String.t()) :: :ok
  def put(provider, key)

  @spec delete(provider()) :: :ok
  def delete(provider)

  @spec get(provider()) :: {:ok, String.t(), source()} | {:error, :missing}
  def get(provider)

  @spec get(provider(), keyword()) :: {:ok, String.t(), source()} | {:error, :missing}
  def get(provider, opts)

  @spec fetch!(provider(), keyword()) :: String.t()
  def fetch!(provider, opts \\ [])
end
```

**Resolution order for `get/2` and `fetch!/2`:**

1. `opts[:api_key]` — explicit per-call override → `{:ok, key, :opts}`
2. `ALLM.Keys.Store` (in-process Agent set via `put/2`) → `{:ok, key, :runtime}`
3. `Application.get_env(:allm, :keys, %{})[provider]` → `{:ok, key, :app_config}`
4. `System.get_env(env_var_for(provider))` where `env_var_for/1` upcases the atom and appends `_API_KEY` (e.g., `:openai → "OPENAI_API_KEY"`) → `{:ok, key, :env}`
5. `.env` file (only when `config :allm, load_dotenv: true`) → `{:ok, key, :dotenv}`

If none yield a non-empty binary, returns `{:error, :missing}`. `fetch!/2` raises `ALLM.Error.EngineError.new(:missing_key, provider: provider, message: "no API key found for provider #{provider} (checked: #{sources})", metadata: %{checked_sources: [:opts, :runtime, :app_config, :env, :dotenv]})` on miss. The `:checked_sources` list reflects which sources were actually consulted (e.g., `:dotenv` is omitted when `config :allm, load_dotenv: true` is not set), so adapters and operators can diagnose "did we even try the .env?" without re-deriving the chain.

**`env_var_for/1` table** (extensible — covers known providers; unknown providers fall back to `String.upcase("#{provider}") <> "_API_KEY"`):

| Provider atom | Env var |
|---------------|---------|
| `:openai` | `OPENAI_API_KEY` |
| `:anthropic` | `ANTHROPIC_API_KEY` |
| `:google` | `GOOGLE_API_KEY` |
| `:cohere` | `COHERE_API_KEY` |
| `:mistral` | `MISTRAL_API_KEY` |
| `:fake` | `FAKE_API_KEY` (used only by Fake adapter tests) |
| `<other>` | `String.upcase("#{atom}") <> "_API_KEY"` |

### `ALLM.Keys.Store` (private — Agent)

```elixir
defmodule ALLM.Keys.Store do
  @moduledoc false
  use Agent

  # Holds two slices of state:
  #   :runtime  — %{provider => key} populated by ALLM.Keys.put/2
  #   :dotenv   — :unloaded | %{env_var_name => value} from .env (Decision #10)
  @type state :: %{runtime: %{atom() => String.t()},
                   dotenv: :unloaded | %{String.t() => String.t()}}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ [])
  # Started by ALLM.Application; name is __MODULE__.

  @spec put(atom(), String.t()) :: :ok
  def put(provider, key)

  @spec get(atom()) :: String.t() | nil
  def get(provider)

  @spec delete(atom()) :: :ok
  def delete(provider)

  @spec clear() :: :ok
  def clear()
  # Resets BOTH the runtime map and the dotenv cache to initial state.

  @spec dotenv_lookup(String.t()) :: String.t() | nil
  def dotenv_lookup(env_var)
  # Triggers one-time .env load on first call when load_dotenv is true.
  # Returns nil when load_dotenv is disabled or the env_var isn't in the file.
end
```

### `ALLM.Keys.Dotenv` (private — minimal `.env` parser)

```elixir
defmodule ALLM.Keys.Dotenv do
  @moduledoc false

  @type entry :: {String.t(), String.t()}

  @spec load(Path.t()) :: %{String.t() => String.t()}
  def load(path)
  # Reads the file (returns %{} on ENOENT), parses, returns a string-keyed
  # map of every well-formed KEY=VALUE pair. Malformed lines, comment-only
  # lines, and blank lines silently skipped. No key-shape restriction.

  @spec parse(String.t()) :: [entry()]
  def parse(content)
  # Pure function — testable without filesystem.

  @spec lookup(atom()) :: String.t() | nil
  def lookup(provider)
  # Looks up env_var_for(provider) in the cached load result. Triggers the
  # one-time load on first call. Returns nil when load_dotenv is disabled.
end
```

### `ALLM.Application` (NEW)

```elixir
defmodule ALLM.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [ALLM.Keys.Store]
    Supervisor.start_link(children, strategy: :one_for_one, name: ALLM.Supervisor)
  end
end
```

`mix.exs` `application/0` adds `mod: {ALLM.Application, []}`.

## Module Tree

```
lib/allm.ex                              (no change in Phase 2)

lib/allm/
├── engine.ex                            (MODIFY — add merge_opts/2, resolve_model/2,
│                                                   resolve_tools/2, resolve_params/2;
│                                                   add @doc + doctests on existing helpers;
│                                                   add defimpl Jason.Encoder + __from_tagged__/1)
├── keys.ex                              (NEW — public Keys API per §6.4)
├── keys/
│   ├── store.ex                         (NEW — Agent-backed in-process key store)
│   └── dotenv.ex                        (NEW — minimal .env parser + persistent_term cache)
└── application.ex                       (NEW — supervises ALLM.Keys.Store)

mix.exs                                  (MODIFY — application/0 adds mod: {ALLM.Application, []})

test/allm/
├── engine_test.exs                      (NEW — happy path + error path on each new function;
│                                              precedence tests; doctest discovery)
├── engine_property_test.exs             (NEW — StreamData over (engine, opts) pairs proving
│                                              option precedence: opts > engine for every key)
├── engine_roundtrip_test.exs            (NEW — :erlang.term_to_binary + Jason round-trip;
│                                              tagged @roundtrip)
├── keys_test.exs                        (NEW — five-level chain tested in order;
│                                              fetch!/2 raises EngineError; doctests)
└── keys/
    ├── store_test.exs                   (NEW — Agent put/get/delete/clear)
    └── dotenv_test.exs                  (NEW — parser unit tests; load tests against fixture)

test/fixtures/
└── sample.env                           (NEW — KEY=VAL, comments, exports, quoted values,
                                                bad lines silently skipped)

test/test_helper.exs                     (MODIFY — Application.ensure_all_started(:allm) called
                                                  before ExUnit.start; per-test on_exit calls
                                                  ALLM.Keys.Store.clear/0 which resets BOTH the
                                                  runtime key map and the dotenv cache to :unloaded)
```

Test files mirror source files 1:1 per `AGENT_DESIGN_SPEC.md §4`. No test-support modules needed in Phase 2 — conformance harnesses land in Phase 3.

## Phases

### Sub-phase 2.1: `Engine` Resolver API

**Goal:** Implement the four resolver functions and refresh `@doc` on existing helpers.

**Spec sections:** §6.2, §10 (precedence)

#### 2.1 Test Plan (write first)

`test/allm/engine_test.exs`:

- `merge_opts/2` with `[model: m]` returns engine with `:model = m`; with `[tools: ts]` appends `ts` to engine tools (dedup by name with opts winning); with `[params: %{...}]` shallow-merges into engine.params; with `[context: %{...}]` shallow-merges into engine.context; unknown keys are silently dropped.
- `merge_opts/2` is a no-op when opts is `[]`.
- `resolve_model/2` with no opts returns `engine.model` (including `nil`).
- `resolve_model/2` with `[model: "x"]` returns `"x"` even when `engine.model` is set.
- `resolve_model/2` with a `{:openai, "gpt-x"}` tuple returns the tuple verbatim (pass-through; `llm_db` not loaded in test env).
- `resolve_tools/2` with no opts returns `engine.tools` exactly.
- `resolve_tools/2` with opts containing a tool whose name matches an engine tool replaces in-place, preserving order of non-colliding engine tools.
- `resolve_tools/2` with opts containing only new tool names appends.
- `resolve_params/2` with no opts returns `engine.params`.
- `resolve_params/2` with `[temperature: 0.7]` merges `%{temperature: 0.7}` over `engine.params`.
- `resolve_params/2` with an engine-field key (`:tools`, `:model`, `:adapter`, `:context`) does **not** include that key in the result — engine fields don't leak into params.
- `resolve_params/2` with a provider-specific key (`:reasoning_effort`, `:potato`) **does** include that key in the result (§10 forwarding).
- `resolve_params/2` with an orchestration key (`:max_turns`, `:halt_when`) **does** include that key (it lands in the params map per spec §22 sample).
- Doctest on every new public function.

`test/allm/engine_property_test.exs`:

- For any `(engine, opts)` pair where `opts` includes a key not in the engine-field deny-list, `resolve_params(engine, opts)` returns a map whose value at that key equals `opts[key]` (opts wins).
- For any `(engine, opts)` pair where `opts` includes an engine-field key (e.g., `:adapter`, `:model`, `:tools`), the resulting `resolve_params/2` map does not contain that key.
- For any `engine` and `opts: [model: m]` where `m` is a binary, `resolve_model/2` returns `m`.
- For any list `engine.tools = ts1` and `opts: [tools: ts2]`, the result of `resolve_tools/2` is a list of length `length(ts1) + length(ts2) - intersect_count`, where intersection is computed by `:name`.

#### 2.1 Implementation Checklist

- [x] Add `merge_opts/2` to `lib/allm/engine.ex` — composes `with_model/2`, `put_tools/2`, params merge, context merge based on opt keys.
- [x] Add `resolve_model/2` — reads `opts[:model] || engine.model`; if `Code.ensure_loaded?(LLMDB)`, delegates to `LLMDB.model/1` on the chosen value; else returns the value verbatim. Note: producing the `LLMDB` atom without a compile-time binding requires `Module.concat(["LLMDB"])` — a direct `LLMDB` reference or a bound variable (e.g., `mod = LLMDB`) trips `--warnings-as-errors` when the optional dep is absent, and `apply(LLMDB, :model, [chosen])` trips Credo's `Refactor.Apply` rule. The one-atom-per-process-lifetime `Module.concat/1` call on a hard-coded string literal is explicitly allowed (see §Deliverables scope note); the 2.3 decoder path's ban applies to input-derived strings only.
- [x] Add `resolve_tools/2` — dedup-by-name merge of `engine.tools` and `opts[:tools]`, opts wins.
- [x] Add `resolve_params/2` — shallow-merges `engine.params` with the opts list filtered by an engine-field deny-list.
- [x] Define `@engine_field_keys` module attribute listing the engine struct fields excluded from `resolve_params/2` (Non-obvious decision #5).
- [x] Add `@doc` + runnable doctest on every new public function.
- [x] Refresh `@doc` on existing `new/1`, `put_tool/2`, `put_tools/2`, `put_param/3`, `put_context/3`, `with_model/2` to add doctests.

#### 2.1 Verification

```bash
mix test test/allm/engine_test.exs test/allm/engine_property_test.exs
mix credo --strict lib/allm/engine.ex
mix dialyzer
mix format --check-formatted lib/allm/engine.ex
```

---

### Sub-phase 2.2: `ALLM.Keys` and the Five-Level Resolution Chain

**Goal:** Ship `ALLM.Keys`, `ALLM.Keys.Store`, and `ALLM.Keys.Dotenv`. Wire `ALLM.Application` so the `Store` Agent starts when `:allm` does.

**Spec sections:** §6.4

#### 2.2 Test Plan (write first)

`test/allm/keys/store_test.exs`:

- `start_link/1` returns `{:ok, pid}` and is registered under `ALLM.Keys.Store`.
- `put/2` followed by `get/1` returns the same string.
- `get/1` returns `nil` when nothing is stored.
- `delete/1` removes a stored key; subsequent `get/1` returns `nil`.
- `clear/0` removes all keys **and** resets the dotenv cache to `:unloaded`.
- Concurrent `put/2` calls from 100 tasks land deterministically (Agent serializes writes — last-write-wins).
- `dotenv_lookup/1` triggers `Dotenv.load/1` on first call when `load_dotenv: true`; subsequent calls return cached values without re-reading the file.
- `dotenv_lookup/1` returns `nil` when `Application.get_env(:allm, :load_dotenv)` is falsy, regardless of file contents.

`test/allm/keys/dotenv_test.exs`:

- `parse/1` on `KEY=VALUE\n` yields `[{"KEY", "VALUE"}]`.
- `parse/1` on `# comment\nKEY=VAL` yields `[{"KEY", "VAL"}]`.
- `parse/1` on `export KEY=VAL` yields `[{"KEY", "VAL"}]`.
- `parse/1` on `KEY="quoted value"` yields `[{"KEY", "quoted value"}]` (quotes stripped).
- `parse/1` on `KEY='single'` yields `[{"KEY", "'single'"}]` (single quotes are NOT stripped — documented limitation).
- `parse/1` on a malformed line (`no equals here`) silently skips it.
- `parse/1` on a blank line is a no-op.
- `parse/1` on `KEY=` yields `[{"KEY", ""}]` (empty value preserved; `Keys.get/1` then treats empty string as missing — see Keys test).
- `load/1` on a non-existent path returns `%{}` without raising.
- `load/1` on `test/fixtures/sample.env` (which contains `OPENAI_API_KEY=sk-test`, `ANTHROPIC_API_KEY=ant-test`, `# comment`, `export GOOGLE_API_KEY=g-test`, `XAI_TOKEN=xai-test`, `LOG_LEVEL=debug`, and a malformed line) returns `%{"OPENAI_API_KEY" => "sk-test", "ANTHROPIC_API_KEY" => "ant-test", "GOOGLE_API_KEY" => "g-test", "XAI_TOKEN" => "xai-test", "LOG_LEVEL" => "debug"}`. The map is string-keyed and unfiltered — `lookup/1` does the provider-to-env-var translation.
- `lookup/1` returns `nil` when `config :allm, load_dotenv: true` is not set, regardless of `.env` contents.
- `lookup(:openai)` translates to `"OPENAI_API_KEY"` and returns the value from the cached load.
- `lookup(:xai)` translates to `"XAI_API_KEY"` (the `env_var_for/1` fallback for unknown providers) and returns `nil` even though the file has `XAI_TOKEN` — this is documented as the consistent rule: dotenv lookup uses the same env-var name as the System.get_env layer.
- Reset path tested via the shared cache Agent (Decision #10) — `Agent.update(ALLM.Keys.Store, &reset_dotenv_cache/1)` or equivalent — not via `:persistent_term.erase/1`.

`test/allm/keys_test.exs`:

- `put/2` + `get/1` round-trips a key with `source: :runtime`.
- `get/1` falls through to `:app_config` when the runtime store has no entry and `Application.get_env(:allm, :keys)` provides one (test sets and deletes via `on_exit`).
- `get/1` falls through to `:env` when neither runtime nor app config provides a key but `OPENAI_API_KEY` is set (test sets and deletes via `System.put_env/System.delete_env`).
- `get/1` returns `{:error, :missing}` when no source provides a key (clean `Application` and `System` env in the test).
- `get/2` with `[api_key: "explicit"]` returns `{:ok, "explicit", :opts}` regardless of other sources.
- `get/2` precedence: opts > runtime > app_config > env > dotenv. Each level tested with an isolating fixture, including:
  - opts wins over a runtime-set key (`Keys.put(:openai, "store"); get(:openai, api_key: "explicit")` → `"explicit"`, `:opts`)
  - runtime wins over app_config (config set, runtime overrides)
  - app_config wins over env (env var set, app_config overrides)
  - env wins over dotenv (`.env` has key, env var also set with different value, `load_dotenv: true` → env value, `:env`)
  - **dotenv-only positive case**: only `.env` has the key, `load_dotenv: true` → returns from dotenv with `source: :dotenv`
  - **dotenv-disabled negative case**: `.env` has the key, `load_dotenv: false` (or unset) → returns `{:error, :missing}` even though `.env` would supply it
  - **dotenv cache invalidation**: load → modify `.env` on disk → without `__reset__/0`, subsequent `get/1` returns the cached value; after `__reset__/0`, returns the new value
- `fetch!/2` returns the string on hit; raises `%ALLM.Error.EngineError{reason: :missing_key, provider: :openai}` on miss with a non-empty `Exception.message/1`.
- The raised `EngineError`'s `:metadata` carries `%{checked_sources: [...]}` reflecting which sources were consulted; the test asserts `:dotenv` appears when `load_dotenv: true` is set and is absent otherwise.
- `get/1` treats an empty-string key as `{:error, :missing}` (defensive — empty `OPENAI_API_KEY=` env var should not satisfy resolution).
- Doctest on `put/2`, `get/1`, `fetch!/2` (using a fake provider atom and `on_exit` cleanup).
- `.env` lookup is **only** consulted when `Application.get_env(:allm, :load_dotenv)` is `true`. Test toggles the config, calls `Keys.Dotenv.__reset__/0`, asserts behavior in both modes.

#### 2.2 Implementation Checklist

- [x] Create `lib/allm/keys/store.ex` — `Agent`-backed state holding `%{runtime: %{...}, dotenv: :unloaded | %{...}}`; `start_link/1` registers under `__MODULE__`; `put/get/delete/clear/dotenv_lookup` operate on the Agent. `dotenv_lookup/1` performs the lazy load by calling `ALLM.Keys.Dotenv.load/1` inside an `Agent.get_and_update/3` when state is `:unloaded` and `load_dotenv: true`.
- [x] Create `lib/allm/keys/dotenv.ex` — pure `parse/1`, file-reading `load/1` (returns `%{}` on ENOENT), and `lookup/1` (delegates to `ALLM.Keys.Store.dotenv_lookup/1` after translating the provider atom to its env-var name). No `__reset__/0`, no `:persistent_term`.
- [x] Create `lib/allm/keys.ex` — `put/2`, `delete/1`, `get/1`, `get/2`, `fetch!/2` walking the five-level chain in order and tagging the source.
- [x] Create `lib/allm/application.ex` — supervises `ALLM.Keys.Store`.
- [x] Modify `mix.exs` `application/0` to add `mod: {ALLM.Application, []}`.
- [x] Modify `test/test_helper.exs` to call `Application.ensure_all_started(:allm)` before `ExUnit.start()`. Tests that touch keys add `on_exit(fn -> ALLM.Keys.Store.clear() end)` — the single Agent reset call zeros both runtime keys and the dotenv cache.
- [x] Create `test/fixtures/sample.env` per the test plan.
- [x] Add `@doc` + runnable doctest on every public function in `ALLM.Keys`.

#### 2.2 Verification

```bash
mix test test/allm/keys_test.exs test/allm/keys/store_test.exs test/allm/keys/dotenv_test.exs
mix credo --strict lib/allm/keys.ex lib/allm/keys/ lib/allm/application.ex
mix dialyzer
mix format --check-formatted lib/allm/keys.ex lib/allm/keys/ lib/allm/application.ex
```

---

### Sub-phase 2.3: Engine Serializability + `llm_db`-absent Property Tests

**Goal:** Prove the engine is safe to persist (`:erlang.term_to_binary/1` + `Jason` round-trip) and that `resolve_model/2` works identically with and without `llm_db` loaded. Phase 2 ships with `llm_db` deliberately absent (per `mix.exs` comment); the `llm_db`-present case is verified by a runtime stub — a test-only `LLMDB` module compiled under `test/support/`.

**Spec sections:** §6.1 (struct shape), §6.3 (catalog optionality)

#### 2.3 Test Plan (write first)

`test/allm/engine_roundtrip_test.exs` (`@moduletag :roundtrip`):

- A populated engine (adapter set, model set, two tools with `nil` handlers, params populated with atom/number/string values only, context populated similarly, retry: `:default`, middleware: `[]`, metadata populated) round-trips through `:erlang.term_to_binary/1` and `:erlang.binary_to_term/1` to the equal struct.
- The same engine round-trips through `ALLM.Serializer.to_json!/1 |> ALLM.Serializer.from_json/1` to the equal struct (atoms restored via `String.to_existing_atom/1`; module fields restored via `String.to_existing_atom/1`).
- JSON decode of an engine whose `"adapter"` value is a module string not loaded in the BEAM (e.g., `"NonExistent.Module"`) returns `{:error, %ALLM.Error.ValidationError{reason: :invalid_request, errors: [{:_unknown, :atom_decode_failed}]}}` — proves `Module.concat/1` is **not** used on this input-derived path (which would silently create a phantom atom from untrusted JSON). This ban is scoped to the JSON decoder; `Module.concat/1` on compile-time string literals (as used in `resolve_model/2` for optional-dep detection, Sub-phase 2.1) is a different threat model and remains allowed.
- An engine with a tool whose `:handler` is `{MyApp.Tools, :weather}` (MFA tuple) round-trips through `term_to_binary` only. Jason cannot encode raw 2-tuples (`Protocol.UndefinedError` on `Tuple`); the JSON half of this bullet is **not** covered by v0.2 and is tracked as a v0.3 enhancement (emit handler as `[module_str, fn_str]` in the Tool encoder with a symmetric decoder).
- An engine with a tool whose `:handler` is an anonymous function **does not raise** at the ETF boundary — `:erlang.term_to_binary/1` silently encodes funs (BEAM-private form; unsafe to deserialize across nodes or hot reloads, but encode succeeds). The contract is mechanically enforced at the JSON boundary instead: `ALLM.Serializer.to_json!/1` raises **`Protocol.UndefinedError`** (no `Jason.Encoder` impl for `Function`). The test asserts the JSON-boundary raise and references the closed contract from Non-obvious decision #7. Empirically verified in IEx.
- `engine.adapter_opts` containing a fun (`[finch_callback: fn _ -> :ok end]`) exhibits the same asymmetry — ETF silently encodes, JSON raises `Protocol.UndefinedError` — covers the keyword-list-with-fn failure mode called out in the closed contract. Empirically verified in IEx.
- `engine.metadata` containing `%{created_at: ~U[2026-01-01 00:00:00Z]}` round-trips equality-preserving through `term_to_binary` (DateTime survives ETF). The JSON round-trip is **non-equality-preserving**: Jason ships a `Jason.Encoder.DateTime` impl that emits ISO-8601 strings, but the library's decoder does not re-parse those back into `%DateTime{}` — so `decoded != engine` and `decoded.metadata[:created_at] == "2026-01-01T00:00:00Z"` (a binary). The test asserts both the `refute decoded == engine` and the binary shape; the `@moduledoc` documents the asymmetry.

`test/allm/engine_property_test.exs` (additions to the file from 2.1):

- For any engine constructed via `Engine.new/1` with serializable inputs, `resolve_model(engine, [])` returns the same value whether the test process has `:llm_db_loaded` set in its process dictionary or not (Phase 2 has no real `llm_db` dep — the resolver branches on `Code.ensure_loaded?/1`, which always returns `false` in this phase, so the property collapses to "always pass-through"). When Phase 9 lands, this test is updated to use a test-mode `LLMDB` stub.

`test/support/llm_db_stub.ex` (NEW — but not in this phase):

- Deferred — the stub is added in Phase 9. Phase 2 documents in the test file's `@moduledoc` that the `llm_db`-present path is untestable until Phase 9 ships the stub or the dep is added. The dep-absent path is the supported configuration in v0.2 builds without Phase 9.

#### 2.3 Implementation Checklist

- [x] Add `__from_tagged__/1` to `ALLM.Engine` — restore module-typed fields (`:adapter`, `:tool_executor`, `:tool_result_encoder`, `:image_adapter`) via `String.to_existing_atom/1` (matching Phase 1's `ALLM.Serializer.to_atom_field/1` pattern at `lib/allm/serializer.ex:184`); the `hydrate_with/2` rescue at `lib/allm/serializer.ex:236` converts `ArgumentError` to `{:_unknown, :atom_decode_failed}` automatically. Restore atom-keyed maps (`:params`, `:context`, `:metadata`) via `String.to_existing_atom/1` on keys. Never use `Module.concat/1` on decoded JSON — it creates atoms unconditionally from untrusted input. (This ban is scoped to input-derived strings; `Module.concat/1` on compile-time string literals as used in Sub-phase 2.1's `resolve_model/2` for optional-dep detection is a different threat model and remains allowed.)
- [x] Add `defimpl Jason.Encoder, for: ALLM.Engine` block delegating to `ALLM.Serializer.encode_tagged/2` (with a pre-pass that transforms keyword-list fields — `:adapter_opts` and `:retry` when kwlist-shaped — into list-of-pairs so Jason can encode them; the decoder reconstructs keyword lists from either shape).
- [x] Register `ALLM.Engine` in `ALLM.Serializer`'s `@known_modules` so the JSON decoder dispatches tagged engine blobs to `Engine.__from_tagged__/1` and the existing `hydrate_with/2` rescue surfaces `{:_unknown, :atom_decode_failed}` on unloaded-module adapter strings.
- [x] Add `@spec` and `@doc false` on `__from_tagged__/1`.
- [x] Verify the `term_to_binary` round-trip test passes for the populated engine.
- [x] Document the "Engines are serializable iff …" rule in `ALLM.Engine`'s `@moduledoc` (verbatim from Non-obvious decision #7).

#### 2.3 Verification

```bash
mix test test/allm/engine_roundtrip_test.exs test/allm/engine_property_test.exs
mix test --only roundtrip            # all serializability tests including Phase 1's
mix dialyzer
```

---

### Sub-phase 2.4: Engine Integration Test (Construct → Serialize → Deserialize → Resolve)

**Goal:** A single end-to-end test proving the Phase 2 surface composes: a user constructs an engine, persists it to a binary, restores it in a fresh test process, and the restored engine resolves model/tools/params/keys identically to the original.

**Spec sections:** §6.1, §6.2, §6.4

#### 2.4 Test Plan (write first)

`test/allm/engine_integration_test.exs` (NEW):

- **Scenario 1: serialize → restore → resolve.** Construct engine, populate via `put_*`, `term_to_binary`, ship to a `Task` (forced fresh process), `binary_to_term` there, run `resolve_model/2`, `resolve_tools/2`, `resolve_params/2` — assert each returns the same value as the original.
- **Scenario 2: keys are not on the engine.** Set a runtime key via `Keys.put(:fake, "k")`, serialize the engine, restore it, prove that the restored binary contains no occurrence of the key string (`String.contains?(:erlang.term_to_binary(engine), "k")` is the wrong test — too coarse; instead, walk the deserialized engine struct's fields with `Map.from_struct/1 |> Enum.flat_map(&string_leaves/1)` — a recursive helper that collects every binary leaf reachable through maps, lists, and tuples — and assert the literal `"k"` does not appear anywhere).
- **Scenario 3: opts win precedence end-to-end.** Construct engine with `model: "engine-default"`, `params: %{temperature: 0.5}`, two tools. Call `resolve_*` with `[model: "override", params: nil, temperature: 0.9, tools: [override_tool, new_tool]]`. Assert resolved model is `"override"`, params is `%{temperature: 0.9}`, tools list reflects opts-winning dedup.
- **Scenario 4: round-trip of an engine whose tool handler is `{Module, :function}`.** Build engine with one tool whose handler is `{MyApp.Tools, :weather}`, round-trip through `term_to_binary`, restored engine's tool's handler equals `{MyApp.Tools, :weather}`. (Module need not exist at decode time — the tuple is opaque data.)

#### 2.4 Implementation Checklist

- [x] Create `test/allm/engine_integration_test.exs` covering the four scenarios.
- [x] Add `@moduletag :integration` so the test can be excluded from fast unit runs (`mix test --exclude integration`).
- [x] Verify all four scenarios pass and add to the `mix test --only integration` selection.

#### 2.4 Verification

```bash
mix test test/allm/engine_integration_test.exs
mix test                                          # full suite, including everything from Phase 1
mix test --only roundtrip
mix coveralls.html                                # ≥90% on Phase 2 new code
```

---

## Test Plan (cross-phase summary)

- **Unit tests** for each module: `engine_test.exs`, `keys_test.exs`, `keys/store_test.exs`, `keys/dotenv_test.exs`. Each public function gets at least one happy-path and one error-path test.
- **Property tests** (`StreamData`): `engine_property_test.exs` for option precedence on `resolve_*`. The properties are the load-bearing correctness check that "opts win" is universal.
- **Integration test**: `engine_integration_test.exs` — single end-to-end scenario chain.
- **Round-trip tests** (`@moduletag :roundtrip`): `engine_roundtrip_test.exs` adds Engine to the existing Phase 1 round-trip suite. Run via `mix test --only roundtrip`.
- **Doctests**: every public function in `ALLM.Engine` (new and existing) and `ALLM.Keys` carries a runnable `@doc` example.
- **Coverage**: ≥90% line coverage on all files added or modified in Phase 2; `mix.exs` global threshold of 80% remains the floor.
- **No conformance tests in Phase 2.** Behaviour conformance lands in Phase 3. Engine doesn't implement a behaviour itself — it consumes them.

## Error Contract

Phase 2 introduces one new error path:

| Function | Error reason | Recovery guidance |
|----------|--------------|--------------------|
| `ALLM.Keys.fetch!/2` | `:missing_key` | Caller must set the key via `ALLM.Keys.put/2`, `config :allm, keys: %{...}`, the env var, or `.env`. The provider field on the raised `EngineError` identifies which key is missing. |
| `ALLM.Engine.resolve_model/2` | (none in Phase 2) | Resolution is total when `llm_db` is absent: `nil` model returns `nil`, any other value returns verbatim. Capability errors (`:unsupported_capability`) land in Phase 9. |
| `ALLM.Engine.merge_opts/2` | (none) | Total function; unknown opts are silently dropped. |

`ALLM.Keys.get/1` and `get/2` return `{:error, :missing}` per spec §6.4. This is the documented exception to the "no atom-tuple errors" rule (Non-obvious decision #9) — `get/2` is a primitive lookup whose only failure mode is "absent." Adapters should call `fetch!/2` (struct-based raise) for the simpler call site.

### Field-error vocabulary

Phase 2 introduces no validators (`ALLM.Validate.engine/1` is out of scope — see Out of Scope). The only structured error is `ALLM.Error.EngineError{reason: :missing_key}` from `Keys.fetch!/2`, which uses the `:missing_key` atom already in the closed reason enum from Phase 1.

One new `ValidationError` field-error path is introduced via the engine JSON decode hook (the rescue at `lib/allm/serializer.ex:236` already returns `{:_unknown, :atom_decode_failed}` for any `ArgumentError` raised inside `__from_tagged__/1`). Phase 2 documents the engine-specific surface:

| Field path | Reason atom | Hard-reject? | Fires when |
|------------|-------------|--------------|------------|
| `[:adapter]` | `:module_not_loaded` | **yes** | JSON decode of an engine names an `:adapter` module that isn't loaded in the BEAM (cross-machine restore where the adapter dep isn't present). Surfaces via the existing `{:_unknown, :atom_decode_failed}` aggregator — Phase 2 does not add a more specific path because per-field threading is the v0.3 hardening item already documented in Phase 1's serializer notes. |
| `[:tool_executor]`, `[:tool_result_encoder]`, `[:image_adapter]` | same | **yes** | same — any module field. |

## Streaming & Backpressure

Not applicable to Phase 2 — no streaming surface is added or modified. (Phase 5 is the first phase that touches `Stream.resource/3`.)

## Definition of Done

- [ ] All four sub-phases marked `Completed` in the status table.
- [ ] `mix test` passes with zero failures, zero `unused_var` warnings, coverage ≥80% globally and ≥90% on new code.
- [ ] `mix credo --strict` passes with zero issues on changed files.
- [ ] `mix dialyzer` passes with zero new warnings (compare against the prior PLT).
- [ ] `mix format --check-formatted` passes.
- [ ] Every new public function has an `@spec` and an `@doc` with at least one runnable doctest.
- [ ] Engine serializability round-trip tests pass under `mix test --only roundtrip`.
- [ ] No behaviour-conformance suite needed (no behaviour added in Phase 2).
- [ ] `ALLM.Application` starts cleanly on `iex -S mix`; `ALLM.Keys.Store` is alive and registered.
- [ ] Spec section references in commit messages match the §-numbers in the Overview (`§6.2`, `§6.3`, `§6.4`).
- [ ] CHANGELOG.md updated with one-line entries: "Add `ALLM.Engine.{merge_opts,resolve_model,resolve_tools,resolve_params}/2`", "Add `ALLM.Keys` with five-level resolution chain", "Engine round-trips through `:erlang.term_to_binary/1` and `Jason`".
- [ ] Reviewed via `/review` (see `AGENT_REVIEW_SPEC.md`).
