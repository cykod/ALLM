# Engine-Identity Cursor Key — Design Document

> **Goal:** Remove the `ALLM.Providers.Fake` / `ALLM.Providers.FakeImages` content-hash cursor footgun by keying the multi-call cursor on stable per-engine identity instead of `:erlang.phash2(scripts)`.
> **Outcome:** Two engines built with content-equal `:scripts` / `:stream_script` / `:image_script` values and driven through the public façade (`ALLM.generate/3`, `ALLM.stream_generate/3`, `ALLM.chat/3`, `ALLM.stream/3`, `ALLM.step/3`, `ALLM.generate_image/3`, and the `ALLM.Session` quartet) no longer share a cursor — each engine's first call reads index 0. The default needs zero test-side ceremony (no `start_script_cursor/0`).
> **Spec sections:** §6 (Engine), §31 (Fake testing adapter). The cursor mechanism is an implementation detail below the spec line — no spec amendment required.
> **Layers touched:** B (runtime). `ALLM.Engine` gains a generic serializable `:id`; `StreamRunner` and the image-dispatch path thread it into `adapter_opts`; `Fake` / `FakeImages` consume it as the process-dict cursor key.

## Status

| Phase | Description | Layer | Status |
|-------|-------------|-------|--------|
| 1 | `ALLM.Engine` gains a stable, serializable `:id` auto-stamped at `new/1` + restored on round-trip | B | Completed |
| 2 | Chat dispatch injects `cursor_key`; `Fake` prefers it over `phash2` | B | Completed |
| 3 | Image dispatch injects `cursor_key`; `FakeImages` prefers it over `phash2` | B | Completed |

**Overall Progress:** 3/3 phases complete

---

## Overview

`ALLM.Providers.Fake` is a stateless adapter that keeps its multi-call cursor ("which scripted call am I on?") in the process dictionary under a key derived from *script content* — `{:allm_fake_cursor, :erlang.phash2(scripts)}` (`lib/allm/providers/fake.ex:809-814`). Because the key is content-derived rather than engine-derived, **two engines built with content-equal scripts in the same process silently share one cursor**: the second engine's "first" call resumes where the first left off. The failure is silent (a short/wrong-call response, not a raised error). `ALLM.Providers.FakeImages` carries the byte-identical defect (`lib/allm/providers/fake_images.ex:380-385`). A sibling project (Unllmtd) hit this three times in one milestone, each time with a *different* ad-hoc workaround — the signal that the model is leaky, not that the consumer is careless (see `steering/UNLLMTD_FOOTGUN.md`).

The fix is the one the footgun write-up proposed, refined to respect ALLM's serializability invariant: **stamp every engine with a stable unique id at construction, thread it to the adapter as `adapter_opts[:cursor_key]`, and prefer it over the content hash.** Identity is per-engine, so two engines never collide; it is stable for the life of an engine value, so the intended "one engine, N calls, cursor advances in order" behavior is preserved. The explicit `start_script_cursor/0` Agent stays for the two cases it uniquely serves (cross-process sharing, `phash2` collision).

- **Deliverables:**
  - `ALLM.Engine` — new `:id` field (`pos_integer() | nil`); `new/1` auto-stamps `System.unique_integer([:positive])` when unset; `__from_tagged__/1` restores it; new `@doc false` helper `Engine.put_cursor_key/2`.
  - `ALLM.StreamRunner` — `build_dispatch_opts/2` injects `cursor_key` into the merged `adapter_opts`.
  - `ALLM` (`do_generate_image_body/5`) — injects `cursor_key` into the merged image `adapter_opts`.
  - `ALLM.Providers.Fake` — `advance_process_dict_cursor/2` prefers `adapter_opts[:cursor_key]`; moduledoc rewritten.
  - `ALLM.Providers.FakeImages` — `advance_process_dict_cursor/2` **and** `peek_cursor/2` prefer `adapter_opts[:cursor_key]`; moduledoc rewritten.
- **Spec coverage:** §6 (Engine composition — `:id` is a new engine field) and §31 (Fake). Neither section specifies the cursor mechanism, so this refines implementation without redefining spec; **no spec PR required.**
- **Layer demonstration (Layer B only):**
  - *Engine identity, standalone:*
    ```elixir
    a = ALLM.Engine.new(adapter: ALLM.Providers.Fake, adapter_opts: [scripts: [[{:text, "x"}, {:finish, :stop}]]])
    b = ALLM.Engine.new(adapter: ALLM.Providers.Fake, adapter_opts: [scripts: [[{:text, "x"}, {:finish, :stop}]]])
    a.id != b.id          # => true — distinct identity for content-equal engines
    ```
  - *Footgun gone at the façade:*
    ```elixir
    scripts = [[{:text, "a"}, {:finish, :stop}], [{:text, "b"}, {:finish, :stop}]]
    e1 = ALLM.Engine.new(adapter: ALLM.Providers.Fake, adapter_opts: [scripts: scripts])
    e2 = ALLM.Engine.new(adapter: ALLM.Providers.Fake, adapter_opts: [scripts: scripts])
    {:ok, %{output_text: "a"}} = ALLM.generate(e1, ALLM.request([ALLM.user("hi")]) )
    {:ok, %{output_text: "a"}} = ALLM.generate(e2, ALLM.request([ALLM.user("hi")]) )   # was "b" before the fix
    ```
- **Prerequisites:** none. Operates on existing Phase 4 (Fake), Phase 5 (StreamRunner), Phase 14/15 (FakeImages + image dispatch) code.
- **Out of scope:**
  - **Direct adapter calls** — `ALLM.Providers.Fake.generate(req, opts)` / `.stream(req, opts)` invoked without an engine (e.g. the existing `test/allm/providers/fake_test.exs` cursor tests) receive no `cursor_key` and keep the `phash2` default. There is no engine to source identity from; this path stays documented, not fixed. The footgun bit Unllmtd only through the *engine-driven façade*, which this design covers.
  - **Cross-process cursor sharing & `phash2`-collision mitigation** — still the explicit `start_script_cursor/0` Agent's job (`fake.ex:354-358`). Unchanged.
  - **The conformance sibling package** (`conformance/`) — separate pinned package; its stub adapters are untouched.
  - **The `:retry_until_call` retry counter** (`fake.ex:418-426`, key `{__MODULE__, :retry_until_call}`) — a separate single-slot process-dict mechanism, intentionally shared across the streaming/non-streaming arms, and unrelated to the multi-call script cursor. It is **not** engine-keyed and is left unchanged; the "footgun gone at the façade" claim is about the *script cursor* only.
  - **Spec §31 prose** — cursor identity is below the spec line.
- **Non-obvious decisions:**
  1. **`:id` is a generic integer, not a `make_ref/0`.** The footgun write-up suggested `make_ref/0`; a ref survives `:erlang.term_to_binary/1` but **not** JSON, which would break the Layer-B serializability invariant (`engine.ex:27-68`) and the `engine_roundtrip_test.exs` JSON assertion. `System.unique_integer([:positive])` is a plain integer — round-trips through both ETF and `Jason`. It is typed `integer()` (not `pos_integer()`) on the struct because that is `System.unique_integer/1`'s success typing; the value is always positive at runtime. The `Date.now`/`Math.random` prohibition in CLAUDE.md is a Unllmtd-workflow-script rule, not an ALLM one. *Docs target: @moduledoc ALLM.Engine.*
  2. **Injection is provider-neutral (unconditional `put_new`), not `Fake`-scoped.** `cursor_key` rides in `adapter_opts` for *every* adapter. Real adapters read only named `adapter_opts` keys (`lib/allm/providers/openai.ex:210` reads `:endpoint`, `:452` reads `:plug`; never splat the list onto the wire), so `cursor_key` is an inert no-op for them. This keeps `StreamRunner` from hard-referencing a specific adapter module. *Docs target: @doc false Engine.put_cursor_key/2.*
  3. **`Engine.new/1` now produces distinguishable engines for identical opts** (`Engine.new(o) != Engine.new(o)` by `:id`). This is intentional — each constructed engine *is* a distinct instance. No existing test compares two independently-constructed engines (the telemetry `assert start_meta.engine == engine` assertions compare one engine value to itself; round-trip tests compare an engine to its own copy). *Docs target: @doc ALLM.Engine.new/1.*
  4. **Derived engines share identity.** `with_model/2`, `merge_opts/2`, `put_tool/2` etc. use `%{e | …}` struct-update, preserving `:id`. A derived engine keeps the same cursor lineage as its parent — correct for "same engine, reconfigured," and documented as an edge for the rare case of deriving two independent multi-call engines from one (use `new/1` or an explicit `script_cursor` there). *Docs target: @doc ALLM.Engine.new/1.*
  5. **`cursor_key` becomes visible in `Fake`'s `:record` side-channel.** `adapter_opts` carried into a façade call now includes `cursor_key`; the `:record` opt (`fake.ex:776`) forwards `{request, opts}` verbatim, so a consumer asserting on the *exact* recorded `adapter_opts` would observe the key. Documented in the Fake moduledoc; focused assertions (model/temperature/api_key) are unaffected. *Docs target: @moduledoc ALLM.Providers.Fake.*

This change adds **no** new event variants and **no** new closed-union members — not a breaking change for any reducer.

---

## Behaviour & Type Contracts

### `ALLM.Engine` (Layer B — runtime)

```elixir
@type t :: %__MODULE__{
        id: integer() | nil,              # NEW — stable per-instance identity; serializable
        adapter: module() | nil,
        adapter_opts: keyword(),
        model: String.t() | nil,
        tools: [Tool.t()],
        tool_executor: module() | nil,
        tool_result_encoder: module() | nil,
        image_adapter: module() | nil,
        params: map(),
        context: map(),
        retry: retry(),
        middleware: [module()],
        metadata: map()
      }

defstruct [
  :id,                                    # NEW — default nil; new/1 stamps when unset
  :adapter,
  :model,
  # … unchanged …
]
```

- **`:id`** — `integer() | nil` (always a *positive* integer at runtime when stamped by `new/1`; typed `integer()` rather than `pos_integer()` so the `System.unique_integer/1` success typing — `integer()` — matches the contract and `mix dialyzer` stays warning-free). Layer A-serializable plain integer (no ref/pid/fun). `nil` for a hand-built `%Engine{}` struct; auto-assigned by `new/1`. Stable across `with_model/2`, `merge_opts/2`, `put_tool/2`, `put_param/2`, `put_context/2` (all struct-update preserving).

```elixir
@spec new(keyword()) :: t()
def new(opts \\ []) do
  engine = struct!(__MODULE__, opts)
  %{engine | id: engine.id || System.unique_integer([:positive])}
end
```

- **`new/1` invariant:** the returned engine always has a positive-integer `:id`; an explicitly-passed `id:` opt is preserved (supports deterministic reconstruction). `System.unique_integer([:positive])` is unique within the runtime instance — sufficient for cursor disambiguation. *(verified: `System.unique_integer/1` docs — `[:positive]` returns a unique positive integer.)*

```elixir
@doc false
@spec put_cursor_key(keyword(), t()) :: keyword()
def put_cursor_key(adapter_opts, %__MODULE__{id: nil}), do: adapter_opts
def put_cursor_key(adapter_opts, %__MODULE__{id: id}) when is_list(adapter_opts),
  do: Keyword.put_new(adapter_opts, :cursor_key, id)
```

- **`put_cursor_key/2` invariant:** `Keyword.put_new/3` — an explicit caller-supplied `cursor_key` in `adapter_opts` wins. `nil`-id engines pass through untouched (fall back to `phash2`). Single source of truth for both dispatch chokepoints.

**Serialization contract (round-trip invariant — `engine_roundtrip_test.exs:52-63` asserts `round_tripped == engine`):**

- `__from_tagged__/1` (`engine.ex:397-413`) MUST restore `id: data["id"]` — a plain pass-through (the encoder emits a JSON integer; **no** re-stamping on decode, or round-trip equality breaks). A pre-fix serialized engine lacking `"id"` decodes to `id: nil` → falls back to `phash2` (backward compatible).
- The `Jason.Encoder` impl (`engine.ex:519-542`) needs **no change** — `ALLM.Serializer.encode_tagged/2` serializes all struct fields, and a plain integer encodes natively.
- ETF round-trip preserves `:id` automatically.

### Chat dispatch — `ALLM.StreamRunner.build_dispatch_opts/2` (`stream_runner.ex:222-238`)

The adapter-opts concat (`:230-231`) gains one line:

```elixir
adapter_opts =
  (engine.adapter_opts ++ Keyword.get(opts, :adapter_opts, []))
  |> Engine.put_cursor_key(engine)
```

- **Invariant:** every public chat entry point (`ALLM.generate/3` → `Runner.run/3` → `StreamRunner.run/3`; `stream_generate/3`, `chat/3`, `stream/3`, `step/3`, `stream_step/3`; the `ALLM.Session` quartet) funnels through this single chokepoint and `engine.adapter.stream/2` (`:184`). `Fake.generate/2` is never invoked from the façade (`lib/allm/runner.ex:18-19`). One injection site covers all chat paths.

### Image dispatch — `ALLM.do_generate_image_body/5` (`allm.ex:983-1012`)

The merged-opts concat (`:1005-1006`) gains the same line:

```elixir
merged_adapter_opts =
  (engine.adapter_opts ++ Keyword.get(opts, :adapter_opts, []))
  |> Engine.put_cursor_key(engine)
```

### `ALLM.Providers.Fake` (`fake.ex:799-814`)

```elixir
defp advance_cursor(scripts, adapter_opts) do
  case Keyword.get(adapter_opts, :script_cursor) do
    nil -> advance_process_dict_cursor(scripts, adapter_opts)      # /1 → /2
    pid when is_pid(pid) -> Agent.get_and_update(pid, fn i -> {i, i + 1} end)
  end
end

defp advance_process_dict_cursor(scripts, adapter_opts) do
  key_id = Keyword.get(adapter_opts, :cursor_key) || :erlang.phash2(scripts)
  key = {:allm_fake_cursor, key_id}
  current = Process.get(key, 0)
  Process.put(key, current + 1)
  current
end
```

- **Precedence invariant (unchanged → new):** `script_cursor` (Agent pid) > `cursor_key` (engine id) > `phash2(scripts)`. `||` falls back only on `nil` (a real engine id and any `phash2` value — including `0` — are truthy in Elixir).

### `ALLM.Providers.FakeImages` (`fake_images.ex:370-399`)

Symmetric change to **both** cursor readers — `advance_process_dict_cursor/2` (`:380-385`) and `peek_cursor/2` (`:390-399`, used by `{:retry_until_call, n}`). Both MUST prefer `adapter_opts[:cursor_key]` over `phash2(script)` using the **same** key shape (`{:allm_fake_images_cursor, key_id}`), or advance/peek would key on different cursors and retry counting would break.

### Error Contract

No new error paths, atoms, or `{:error, _}` shapes. `cursor_key` is internal plumbing. `Engine.new/1` raises `KeyError` via `struct!/2` on unknown opts exactly as before (`id:` is now a recognized key). No Error Contract table additions.

---

## Module Tree

```
lib/allm/
├── engine.ex                          (MODIFY — 1.x: add :id field + type, new/1 stamp, __from_tagged__ restore, put_cursor_key/2, moduledoc bullet)
├── stream_runner.ex                   (MODIFY — 2.x: build_dispatch_opts/2 cursor_key injection)
├── allm.ex                            (MODIFY — 3.x: do_generate_image_body/5 cursor_key injection)
└── providers/
    ├── fake.ex                        (MODIFY — 2.x: advance_process_dict_cursor/2 + moduledoc rewrite)
    └── fake_images.ex                 (MODIFY — 3.x: advance_process_dict_cursor/2 + peek_cursor/2 + moduledoc rewrite)

test/allm/
├── engine_test.exs                    (MODIFY — 1.x: new/1 id-stamping, explicit-id, derived-engine identity)
├── engine_roundtrip_test.exs          (MODIFY — 1.x: id survives ETF + JSON round-trip; pre-fix engine decodes id: nil)
├── stream_runner_test.exs             (MODIFY — 2.x: cursor_key injected into adapter_opts; user cursor_key wins)
├── providers/
│   ├── fake_test.exs                  (MODIFY — 2.x: reword direct-call collision docstring; add façade no-collision test)
│   ├── fake_stream_test.exs           (MODIFY — 2.x: façade two-engine no-collision via stream_generate)
│   └── fake_images_test.exs           (MODIFY — 3.x: façade two-engine no-collision via generate_image; retry_until_call intact)
├── stream_equivalence_test.exs        (MODIFY — 2.x: refresh cursor-isolation moduledoc to engine-id keying)
├── step_equivalence_test.exs          (MODIFY — 2.x: refresh cursor-isolation moduledoc to engine-id keying)
├── chat_equivalence_test.exs          (MODIFY — 2.x: refresh cursor-isolation moduledoc to engine-id keying)
└── fake_footgun_facade_test.exs       (NEW — 2.x/3.x: Unllmtd 8.1/8.3 regression scenarios at the façade)

CHANGELOG.md                           (MODIFY — one line per the changelog skill)
```

Every NEW path's parent directory exists (`test/allm/`). `git diff --stat` entry count should equal the tree ± 1 (CHANGELOG).

---

## Phases

### Phase 1: `ALLM.Engine` stable `:id` (Layer B)

**Goal:** Every engine carries a stable, serializable identity, auto-assigned at `new/1` and preserved across transformations and round-trips.

#### 1.1 Test Plan (write first)

`test/allm/engine_test.exs` (MODIFY):
- `new/1 stamps a positive-integer :id when none is supplied` (`is_integer/1` and `> 0`).
- `new/1 with explicit id: preserves it` (`Engine.new(id: 42, adapter: Fake).id == 42`).
- `two new/1 calls with identical opts produce distinct ids`.
- `with_model/2 preserves :id`; `merge_opts/2 preserves :id`; `put_tool/2 preserves :id`.
- `a hand-built %Engine{} struct has id: nil` (struct default).

`test/allm/engine_roundtrip_test.exs` (MODIFY):
- `populated engine (with stamped id) round-trips through :erlang.term_to_binary/1` — existing `round_tripped == engine` still green.
- `populated engine round-trips through ALLM.Serializer JSON` — existing `decoded == engine` still green (requires `__from_tagged__` id restore).
- `a serialized engine map without an "id" key decodes to id: nil` (backward-compat — synthesize a tagged map missing `"id"`, assert `decoded.id == nil`).

#### 1.2 Implementation Checklist

- [x] Add `:id` to `defstruct` (default `nil`) and `@type t` (`integer() | nil`).
- [x] Rewrite `new/1` to stamp `System.unique_integer([:positive])` when `id` is `nil`.
- [x] Add `id: data["id"]` to `__from_tagged__/1`.
- [x] Add `@doc false` `put_cursor_key/2` with `@spec`.
- [x] Add a `:id` bullet to the Serializability moduledoc section (`engine.ex:27-68`).

#### 1.3 Verification

```bash
mix test test/allm/engine_test.exs test/allm/engine_roundtrip_test.exs
mix test                       # full suite green — telemetry engine-equality asserts unaffected
mix credo --strict lib/allm/engine.ex
mix dialyzer
```

**Success criterion:** all engine + round-trip tests pass; full suite green (proves no `assert start_meta.engine == engine` regressions across the 9 telemetry tests).

---

### Phase 2: Chat dispatch injects `cursor_key`; `Fake` prefers it (Layer B)

**Goal:** Façade chat calls disambiguate the Fake cursor by engine identity; direct adapter calls keep the `phash2` default.

#### 2.1 Test Plan (write first)

`test/allm/fake_footgun_facade_test.exs` (NEW — the Unllmtd regression):
- `two engines, content-equal :scripts, both via ALLM.generate/3 → each first call reads index 0` (8.x core scenario; was the footgun).
- `two engines, content-equal :stream_script, both via ALLM.stream_generate/3 → each first call reads index 0`.
- `one engine, generate then stream_generate → cursor advances 0 then 1 (in order)` (intended multi-call behavior preserved; 8.3 shape).
- `explicit script_cursor still overrides cursor_key at the façade` (Agent pid wins).

`test/allm/stream_runner_test.exs` (MODIFY):
- `build path injects cursor_key == engine.id into adapter_opts` (drive via `Fake` `:record` pid, assert recorded `adapter_opts[:cursor_key] == engine.id`).
- `a caller-supplied adapter_opts[:cursor_key] is preserved (put_new)`.

`test/allm/providers/fake_test.exs` (MODIFY):
- Reword the `content-equal collision` docstring (`:202-208`) to scope the footgun to **direct adapter calls without a cursor_key/script_cursor**; the assertion stays green (direct call, no injection).
- Add `advance_process_dict_cursor prefers cursor_key over phash2` (direct call with `adapter_opts: [scripts: …, cursor_key: 999]` distinct from same-scripts without it).

#### 2.2 Implementation Checklist

- [x] `StreamRunner.build_dispatch_opts/2`: pipe merged `adapter_opts` through `Engine.put_cursor_key/2`.
- [x] `Fake.advance_cursor/2`: call `advance_process_dict_cursor(scripts, adapter_opts)`.
- [x] `Fake.advance_process_dict_cursor/2`: prefer `adapter_opts[:cursor_key] || :erlang.phash2(scripts)`.
- [x] Rewrite the Fake moduledoc "Cursor behaviour" section (`fake.ex:71-103`): default is now per-engine-identity at the façade; footgun remains only for direct adapter calls; `:record` now surfaces `cursor_key`.
- [x] **Contract-flip audit** (per agent-spec/DESIGN.md rule 9): `git grep -n "phash2\|content-equal\|collision" test/` — confirm the direct-call collision test (`fake_test.exs:209`) stays green (no injection on direct calls). The `stream_equivalence_test.exs` / `step_equivalence_test.exs` / `chat_equivalence_test.exs` moduledocs are **façade-driven** (`stream_equivalence_test.exs:135-136,147-148` call `ALLM.generate/3` / `ALLM.stream_generate/3`), each path building its own engine via `engine_of/1` — after the fix those paths get distinct `engine.id` cursor keys and no longer collide even in one process. Refresh their cursor-mechanism comments (currently stating `:erlang.phash2(scripts)` keying, e.g. `stream_equivalence_test.exs:127`) to engine-id keying; the `Task.async/1` process isolation is retained as defensive belt-and-suspenders, no longer the collision guard. `session_equivalence_test.exs` is correctly untouched — it drives an explicit `start_script_cursor/0` Agent (`:110`), whose precedence is unchanged.

#### 2.3 Verification

```bash
mix test test/allm/fake_footgun_facade_test.exs \
         test/allm/stream_runner_test.exs \
         test/allm/providers/fake_test.exs \
         test/allm/providers/fake_stream_test.exs
mix test                       # full suite incl. stream/step/chat-equivalence properties
mix credo --strict lib/allm/stream_runner.ex lib/allm/providers/fake.ex
mix dialyzer
```

**Success criterion:** the two-engine façade tests read index 0 for each engine's first call; all pre-existing direct-call cursor tests stay green; equivalence properties unbroken.

---

### Phase 3: Image dispatch injects `cursor_key`; `FakeImages` prefers it (Layer B)

**Goal:** Close the byte-identical footgun on the image path symmetrically.

#### 3.1 Test Plan (write first)

`test/allm/providers/fake_images_test.exs` (MODIFY):
- `two engines, content-equal :image_script, both via ALLM.generate_image/3 → each first call reads index 0`.
- `one engine, N generate_image calls → cursor advances in order`.
- `{:retry_until_call, n} still works under cursor_key` (peek + advance share the key — assert the n-th call succeeds and prior calls retry).
- `explicit script_cursor still overrides cursor_key on the image path`.

#### 3.2 Implementation Checklist

- [x] `ALLM.do_generate_image_body/5`: pipe `merged_adapter_opts` through `Engine.put_cursor_key/2`.
- [x] `FakeImages.advance_cursor/2`: call `advance_process_dict_cursor(script, adapter_opts)`.
- [x] `FakeImages.advance_process_dict_cursor/2`: prefer `adapter_opts[:cursor_key]`.
- [x] `FakeImages.peek_cursor/2`: prefer the **same** `adapter_opts[:cursor_key]` key shape (shared `cursor_key_id/2` helper guarantees peek/advance never drift).
- [x] Rewrite the FakeImages moduledoc cursor section (`fake_images.ex:44-49`) to match Fake's.

#### 3.3 Verification

```bash
mix test test/allm/providers/fake_images_test.exs test/allm/allm_generate_image_test.exs
mix test
mix credo --strict lib/allm.ex lib/allm/providers/fake_images.ex
mix dialyzer
mix format --check-formatted
```

**Success criterion:** image two-engine tests read index 0 per engine; `retry_until_call` still counts correctly; full suite green.

---

## Test Plan (cross-phase)

- **Unit (Engine):** `new/1` stamping (happy + explicit-id + distinctness), transformation-preservation, struct default `nil`.
- **Serializability (Layer-A round-trip of the Layer-B engine):** ETF + JSON round-trip equality with stamped `:id`; backward-compat decode of an id-less map. Blocking per agent-spec/DESIGN.md §6.
- **Integration (façade):** the new `fake_footgun_facade_test.exs` is the load-bearing regression — it reproduces Unllmtd's 8.1 (`run/3 ≡ stream_run/3`, two engines) and 8.3 (collected generate + streamed stream_generate, one engine) shapes and asserts the corrected behavior. Driven by `ALLM.Providers.Fake` per CLAUDE.md (no network mocks).
- **Image parity:** symmetric façade test through `ALLM.generate_image/3` + `FakeImages`.
- **Regression guard:** full `mix test` green proves (a) the 9 telemetry `engine == engine` assertions survive, (b) the stream/step/chat-equivalence properties survive, (c) every pre-existing direct-call cursor test (`fake_test.exs:35-282`, `fake_stream_test.exs:472-492`, `fake_images_test.exs:182-202`) survives.
- **Stream-equivalence relaxation budget:** unchanged — this design adds no relaxation rows.
- **Coverage:** new `lib/` code (≈10 LOC across `Engine.new/1`, `put_cursor_key/2`, two `advance_process_dict_cursor/2`, one `peek_cursor/2`, two injection lines) lands at ≥90%; global floor 80% unchanged.

---

## Streaming & Backpressure

No change to stream lifecycle, cleanup (`Stream.resource/3` `after_fun`), backpressure, or cancellation. `cursor_key` only affects which process-dict slot the cursor index reads/writes before any stream is opened. No `after_fun` touches it.

---

## Definition of Done

- [x] All 3 phases marked `Completed`.
- [x] `mix test` zero failures (2438 tests); new Phase-3 lib lines all directly exercised by the new `fake_images_test.exs` façade tests; global coverage unaffected.
- [x] `mix credo --strict` clean on changed files.
- [x] `mix dialyzer` zero new warnings (`put_cursor_key/2` and `new/1` `@spec`s match contracts).
- [x] `mix format --check-formatted` passes.
- [x] `Engine.new/1` carries `@spec` + updated `@doc` noting auto-stamped `:id`; `put_cursor_key/2` is `@doc false` + `@spec`. (Phase 1)
- [x] `Engine` ETF + JSON round-trip tests pass with `:id`. (Phase 1)
- [x] Fake + FakeImages moduledoc cursor sections rewritten to the new default; direct-call caveat documented.
- [x] No new event variant / closed-union member (no reducer-touch needed).
- [x] CHANGELOG.md updated (one line: "Fake/FakeImages multi-call cursor now keyed on engine identity at the façade — content-equal engines no longer share a cursor").

---

## Alternatives Considered

1. **`make_ref/0` token (the write-up's first sketch).** Rejected: a ref breaks JSON serializability (`engine_roundtrip_test.exs:58-63` JSON round-trip), violating the Layer-B "modules + atoms + serializable data only" invariant (`engine.ex:27-68`). A `pos_integer` from `System.unique_integer/1` gives the same uniqueness, round-trips through both ETF and JSON, and is human-readable in telemetry.
2. **`Fake`-scoped injection** — inject `cursor_key` only when `engine.adapter == ALLM.Providers.Fake` (and `FakeImages` on the image path). Rejected: hard-codes a specific adapter module into the generic `StreamRunner`/image dispatcher (a layering smell), for no benefit — real adapters read only named `adapter_opts` keys (`openai.ex:210,452`) and ignore `cursor_key`, so unconditional `put_new` injection is inert for them. Provider-neutral injection keeps the dispatcher adapter-agnostic.
3. **Inject the id into `adapter_opts` at `Engine.new/1`** (no dispatch-site change). Rejected: `new/1` would special-case `adapter == Fake`, re-introducing the adapter coupling alternative 2 avoids, and would only cover engines built via `new/1` (not the dispatch chokepoint that already concatenates engine + call-site `adapter_opts`). The chokepoint is the natural single injection site.
4. **Leave it as-is; promote the `start_script_cursor/0` decision-rule into CLAUDE.md only.** This is the write-up's "Recommendation #1" (cheapest, stops a 4th rediscovery in Unllmtd's tests). Rejected as the *upstream* answer because it keeps the default footgun for every consumer; the "different workaround each time" evidence is the argument for fixing the default. The CLAUDE.md rule and this fix are complementary, not exclusive — the rule still covers the genuinely-Agent-only cases (cross-process, `phash2` collision).

## Assumptions

- `System.unique_integer([:positive])` uniqueness within a single runtime instance is sufficient — the cursor only needs to distinguish engines live in one BEAM process/test run, never across nodes or restarts.
- No external consumer relies on `Engine.new(opts) == Engine.new(opts)` being `true` (verified: no such assertion in `lib/` or `test/`; the only engine-equality assertions compare a value to itself through telemetry/round-trip).
- Real provider adapters (OpenAI/Anthropic/Gemini) consume only named `adapter_opts` keys and never forward the whole list to the wire (verified for OpenAI: `openai.ex:210,452`; assumed parallel for Anthropic/Gemini — the implementer should `grep -n "Keyword.get(opts, :adapter_opts" lib/allm/providers/{anthropic,gemini}.ex` to confirm named-key access before relying on inert injection; if any adapter splats `adapter_opts`, fall back to Alternative 2 for that path).
