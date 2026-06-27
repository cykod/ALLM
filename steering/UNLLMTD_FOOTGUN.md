# ALLM `Providers.Fake` cursor footgun — issue & proposed fix

> **Status:** Known issue, mitigated test-side. Upstream fix proposed but not yet
> applied. ALLM pinned rev `d3c769f` / v0.4.2 (the rev recorded in
> `apps/core/lib/unllmtd/llm/bridge.ex`).
>
> **Audience:** anyone writing Unllmtd tests that drive `ALLM.Providers.Fake`
> with multi-call scripts, and anyone deciding whether to patch ALLM upstream.
>
> **Provenance:** surfaced three times during Core Phase 8 (streaming), once per
> sub-phase, each time with a *different* workaround — see
> `.work/retro/2026-06-26-phase-8-1-bridge-stream.md`,
> `.work/retro/2026-06-26-phase-8-2-interpreter-stream.md` (pattern note), and
> `.work/retro/2026-06-26-phase-8-3-stream-facade.md` (F1).

---

## TL;DR

`ALLM.Providers.Fake` keeps the multi-call **cursor** ("which scripted call am I
on?") in the **process dictionary, keyed by the content hash of the script
list** (`:erlang.phash2(scripts)`). Because the key is derived from *script
content* rather than *engine identity*, two engines built with content-equal
scripts in the same process **silently share one cursor** — the second engine's
"first" call resumes where the first engine left off. The failure is silent (a
short/empty/wrong-call response, not a raised error), which is what makes it a
footgun.

It **can** be fixed in ALLM (key the cursor on a per-engine identity stamped at
`Engine.new/1` time), and that would remove the default footgun for the common
in-process case. It is currently content-hash-keyed by deliberate design
trade-off, and is fully documented with an opt-in workaround
(`start_script_cursor/0`). This doc records both the mechanism and the proposed
upstream change so the decision is explicit rather than rediscovered.

---

## Mechanism

`Fake` is a **stateless adapter** — a module, not a process — and it
deliberately ignores the `%Request{}`. For a multi-call script (`:scripts` /
`:stream_script`, a list-of-lists where each call consumes one inner list), it
must remember which call it is on. By default it stores that index in the
**process dictionary**, under a key derived from the script *content*:

`/workspaces/ALLM/lib/allm/providers/fake.ex:799-814`

```elixir
defp advance_cursor(scripts, adapter_opts) do
  case Keyword.get(adapter_opts, :script_cursor) do
    nil ->
      advance_process_dict_cursor(scripts)

    pid when is_pid(pid) ->
      Agent.get_and_update(pid, fn i -> {i, i + 1} end)
  end
end

defp advance_process_dict_cursor(scripts) do
  key = {:allm_fake_cursor, :erlang.phash2(scripts)}   # ← keyed by CONTENT, not engine
  current = Process.get(key, 0)
  Process.put(key, current + 1)
  current
end
```

The design intent of the process-dict cursor is reasonable:

- **Zero-setup** for the common case — no Agent to start, no pid to thread.
- **Isolated per ExUnit test process** under `async: true` (each test is its own
  process, so cursors don't bleed across tests).
- **GC'd on pid-down** — no cleanup needed.

The defect is purely the **key choice**. Keying on `phash2(scripts)` means:

> Two engines built with **content-equal** `:scripts` values in the **same
> process** share a cursor.

(ALLM's own moduledoc, `fake.ex:78-84`, states this verbatim and calls it "a
documented footgun.")

Sharing is decided by *what the script contains*, not by *which engine instance
you are calling*. The intended multi-call pattern — build **one** engine with
`:scripts`, call it N times, watch the cursor advance — works fine. The footgun
only bites when **two** engines carry equal content, or when **two different
call types** on one engine resolve to the same script value.

### Script-resolution precedence (why the 8.3 variant happened)

`fake.ex:59-60`:

| Call          | Resolution order                                              |
|---------------|--------------------------------------------------------------|
| `generate/2`  | `:scripts` > `:script` (wrapped). `:stream_script` ignored.   |
| `stream/2`    | `:stream_script` > `:scripts` > `:script` (wrapped).          |

So whether a collected `generate` and a streamed `stream_generate` share a
cursor depends on **which keys you set**. Split them across `:script` and
`:stream_script` and they resolve to different content (different `phash2`) — but
the collected call can still advance/exhaust the cursor the stream then reads,
because both ultimately fall through to a shared `:scripts` list when present.
Put them in one ordered `:scripts` list and they consume one cursor *in order* —
which is what you usually want.

---

## How it manifested in Phase 8

All three are the same root cause (content-keyed cursor); note that **each needed
a different fix**, which is the signal that the model is leaky rather than that we
made the same mistake three times.

| Sub-phase | Test                                   | Trigger                                                                 | Workaround used                                              |
|-----------|----------------------------------------|------------------------------------------------------------------------|-------------------------------------------------------------|
| 8.1       | stream-equivalence (`run/3` ≡ `stream_run/3`) | The *same* script run through collected and streamed paths → identical content → same `phash2` key → second path resumed at index 1 | Two distinct `start_script_cursor/0` Agents (one per engine) |
| 8.2       | (pattern note only)                    | No live hit — the LLM call was an injected fake `stream_llm_dispatch`, so `Fake` wasn't driven through `:scripts` | n/a                                                          |
| 8.3       | intermediate-collected + terminal-stream | A collected `generate` and a streamed `stream_generate` in one process with split `:script`/`:stream_script` keys → the collected call exhausted the stream's cursor | A single shared `:scripts` list (both call types consume one ordered cursor) |

---

## Current mitigation (test-side, in our control)

ALLM ships an **opt-in explicit cursor**: `start_script_cursor/0` returns an
Agent pid you pass as `adapter_opts[:script_cursor]`; the adapter then increments
that Agent instead of the process dictionary.

`/workspaces/ALLM/lib/allm/providers/fake.ex:354-365`

```elixir
@spec start_script_cursor() :: pid()
def start_script_cursor do
  {:ok, pid} = Agent.start_link(fn -> 0 end)
  pid
end
```

Usage:

```elixir
cursor = ALLM.Providers.Fake.start_script_cursor()
opts = [adapter_opts: [scripts: [...], script_cursor: cursor]]
```

The explicit Agent also unlocks two capabilities the default cursor lacks, and
which an auto-fix (below) would **not** fully replace:

1. **Cross-process cursor sharing** — e.g. dispatching the adapter call via
   `Task.async/1`, where a process-dict cursor wouldn't carry across.
2. **Hash-collision mitigation** — `:erlang.phash2/1` is a 27-bit hash, so even
   *non*-equal scripts can (rarely) collide on the key.

### Decision rule (to be promoted into `CLAUDE.md` via `/apply-retro`)

Use `start_script_cursor/0` (or a single shared ordered `:scripts` list) whenever
a test:

- (a) runs **multiple** `Fake` calls with a `:scripts`/`:stream_script` list, **AND**
- (b) another test in the same `async: true` module could share content-equal
  script entries, **OR**
- (c) the test dispatches the adapter call **across processes** (`Task.async/1`).

The default process-dict cursor is fine for one-shot `:script` calls and for a
single multi-call test whose script content is unique within its module.

---

## Proposed upstream fix (ALLM)

**Key the cursor on engine identity, not script content.** This removes the
default in-process footgun while preserving the intended multi-call behavior and
the explicit-Agent capabilities.

### Sketch

1. **Stamp every engine with a unique token at build time.** In
   `ALLM.Engine.new/1`, attach a `make_ref/0` (or `System.unique_integer/1`)
   token to the engine. This is **generic** — not Fake-specific — so `Engine`
   gains nothing more than a harmless unique id; no layering violation (Engine
   does not need to know about Fake).
   - ALLM may use `make_ref`/`unique_integer` freely; the
     `Date.now`/`Math.random` prohibition is a *Unllmtd-workflow-script*
     constraint, not an ALLM one.

2. **Thread the token into `adapter_opts`.** The `Fake` adapter receives
   `opts[:adapter_opts]`, **not** the `%Engine{}` struct (it ignores the
   request), so the token must ride in the opts the engine passes down. When the
   adapter is `Fake`, `Engine.new/1` (or the engine's adapter-dispatch path)
   injects the token as e.g. `adapter_opts[:cursor_key]`.

3. **Prefer the engine token in `advance_process_dict_cursor`, fall back to the
   content hash.**

   ```elixir
   defp advance_process_dict_cursor(scripts, adapter_opts) do
     key_id = Keyword.get(adapter_opts, :cursor_key) || :erlang.phash2(scripts)
     key = {:allm_fake_cursor, key_id}
     current = Process.get(key, 0)
     Process.put(key, current + 1)
     current
   end
   ```

### Why this is strictly better

- **One engine, N calls** → one advancing cursor (intended multi-call behavior),
  because the token is stable for the life of that engine.
- **Two engines, equal content** → distinct tokens → distinct cursors
  automatically. **The footgun disappears with zero test-side ceremony.**
- **Backward compatible** — absent a token (older callers, hand-built opts), it
  falls back to today's `phash2` behavior.
- The explicit `start_script_cursor/0` Agent **stays** for the cross-process (c)
  and hash-collision cases it uniquely serves.

### Caveats / scope

- The process-dict storage is still **per-process**; a ref-keyed cursor does not
  by itself enable cross-process sharing. That remains the Agent's job — by
  design.
- This touches `ALLM.Engine` (a new id field) and `Fake`'s cursor resolution.
  It is a small, self-contained change but is **ALLM's owners' call** — `Fake`
  is a test-only adapter and the current behavior is fully documented, so they
  may reasonably prefer to keep the opt-in model. The "different workaround each
  time" evidence from Phase 8 is the argument *for* fixing it.

---

## Recommendation

1. **Now (in our control):** apply the `CLAUDE.md` Gotcha capturing the decision
   rule above, via `/apply-retro`. Cheapest guard; stops a 4th rediscovery. Do
   **not** fork ALLM behavior mid-milestone.
2. **Upstream (worth proposing):** the per-engine-identity cursor key. We
   co-develop ALLM as a pinned sibling (`d3c769f`), so this is a legitimate small
   PR that removes the default footgun for all consumers while keeping the Agent
   override for the cross-process / collision cases.

## References

- `/workspaces/ALLM/lib/allm/providers/fake.ex` — moduledoc "Cursor behaviour"
  (`:71-103`), `advance_cursor/2` + `advance_process_dict_cursor/1`
  (`:799-814`), `start_script_cursor/0` (`:354-365`), resolution precedence
  (`:59-60`).
- `apps/core/lib/unllmtd/llm/bridge.ex` — pinned ALLM rev `d3c769f` in the
  moduledoc.
- Phase 8 retros under `.work/retro/2026-06-26-phase-8-*`.
