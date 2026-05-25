# Code Review: Phase 21 (21.1–21.5) Amesbury Integration Feedback

*Generated: Monday, May 25th, 2026*
*Source: Current WIP (working tree at HEAD ≈ 2424036, all Phase 21 changes uncommitted)*
*Spec: no project `AGENT_CODE_REVIEW_SPEC.md`; CLAUDE.md "dispatch trees", "byte-for-byte alignment", and "decision-text drift" rules applied*

## Summary

A focused, well-scoped feedback rollup. The changes are mostly additive (`ALLM.unwrap/1`, `ALLM.Sandbox`, `Image.from_data_uri/1`, Fake `:usage` + `:record`), the existing CLAUDE.md invariants are respected (no `Logger.debug` calls in adapter hot paths, no module renames into a `[DOC]` commit shape, no streaming-runtime regression), and there are no correctness landmines.

The biggest issues are **reuse asymmetries**: `unwrap/1` re-derives the output-text fold that `Response.text/1` already implements; `Tool.new/1` normalizes atom-keyed schemas but `ALLM.json_schema/3` does not (silent provider-side drift when a caller hands `json_schema/3` an atom-keyed map). A handful of medium issues around overly narrow `@spec` and speculative helper coverage. Test-plan-vs-code drift at the steering doc level on the streaming `:usage` event shape (the implementation made the right call; the steering doc has a self-contradicting bullet).

**Verdict:** Minor fixes recommended

## Files Reviewed

| File | LOC Changed | Notes |
|------|-------------|-------|
| `lib/allm.ex` | +60 / 0 | `unwrap/1` duplicates `Response.text/1` fall-back; `json_schema/3` left un-normalized (asymmetry with `Tool.new/1`) |
| `lib/allm/image.ex` | +56 / -4 | New `from_data_uri/1`; clean. Two minor parse-edge concerns |
| `lib/allm/providers/fake.ex` | +137 / -16 | `:usage` + `:record` opts; `next_fun/1` clause count grew 7→8; `Process.alive?`+`send` TOCTOU acceptable for test helper |
| `lib/allm/sandbox.ex` (NEW) | +181 | `$callers` walker mirrors Mox/Ecto idiom; clean; one inherent caveat (reading another process's dict via `Process.info/2`) |
| `lib/allm/stream_collector.ex` | +11 / 0 | Two-line surface — straightforward |
| `lib/allm/tool.ex` | +71 / -2 | `normalize_schema/1` `@spec` is too narrow; `to_string_key/1` is partial |
| `lib/allm/validate.ex` | +78 / -4 | `module_of/1` has eight YAGNI-flavored clauses |
| `mix.exs` | +2 / -1 | Adds `guides/fakes.md` + `ALLM.Sandbox` to docs; correctly mirrors the `package[:files]` superset rule |
| Tests (4 MOD, 4 NEW) | ~+250 | Cover new behavior; the rerouted `{:usage, _}` test in `fake_stream_test.exs:102` documents the breaking-change rationale inline |
| Guides (3 MOD, 1 NEW) | ~+145 | Out of scope for this review (docs-only) |

## Findings

### F1: `ALLM.unwrap/1` re-derives `Response.text/1`'s output-text fall-back

**Category:** DRY / Reuse
**Severity:** Medium
**Location:** `lib/allm.ex:381-390` (clauses 1 + 2 of `unwrap/1`)
**What's wrong:** The first two `unwrap/1` clauses pattern-match `:stop` + `output_text: binary` → `{:ok, text}`, then `:stop` + `output_text: nil` + `message.content: binary` → `{:ok, content}`. `ALLM.Response.text/1` (`lib/allm/response.ex:100-103`) already implements exactly this fall-back: `output_text` if binary, else `message.content` if binary, else `nil`. The new code rewrites the same logic with the same precedence.
**Why it matters:** Two implementations of the same fall-back. If `Response.text/1` ever grows a third clause (e.g., flatten a `[%TextPart{text: t}]` to `t`), `unwrap/1` won't pick it up. This is the exact "we already have a `formatDate` helper but the new code wrote a local one" case CLAUDE.md flags.
**Suggested fix:** Collapse the `:stop` clauses to a single clause that delegates to `Response.text/1`:

```elixir
def unwrap({:ok, %ALLM.Response{finish_reason: :stop, message: %Message{content: c}}})
    when is_list(c),
    do: {:error, :structured_content}

def unwrap({:ok, %ALLM.Response{finish_reason: :stop} = resp}) do
  case ALLM.Response.text(resp) do
    text when is_binary(text) -> {:ok, text}
    nil -> {:error, :empty_stop_response}  # output_text nil + message nil/empty
  end
end
```

The current implementation also silently misroutes `finish_reason: :stop` with both `output_text: nil` AND `message: nil` (or `message.content: nil`) into the `:non_stop_finish` clause (clause 5) — the response's finish reason IS `:stop`. The above reshape surfaces the empty-stop case explicitly.

---

### F2: `ALLM.json_schema/3` not symmetric with `ALLM.Tool.new/1` schema normalization

**Category:** Reuse / Project Fit
**Severity:** Medium
**Location:** `lib/allm.ex:192-199` (`json_schema/3`) vs `lib/allm/tool.ex:105-119` (`Tool.new/1`)
**What's wrong:** Phase 21.1 normalized atom keys to strings inside `Tool.new(schema: %{...})` because "adapters expect string-keyed JSON Schema". `ALLM.json_schema/3` produces `%{type: :json_schema, name: name, schema: schema, strict: boolean}` — the `:schema` field is the same JSON-Schema shape, used as a response-format constraint by all three adapters (`lib/allm/providers/openai.ex:106`, `lib/allm/providers/anthropic.ex:981`, `lib/allm/providers/gemini.ex:1007`). A caller doing `ALLM.json_schema("person", %{type: :object, properties: %{name: %{type: :string}}})` gets atom keys passed verbatim to the same adapters that `Tool.new/1` was hardened against.
**Why it matters:** The asymmetry is invisible at call time and surfaces as non-deterministic provider wire shapes (the exact bug Phase 21.1 closed for tools). The asymmetry also breaks the cross-helper "byte-for-byte alignment" pattern CLAUDE.md champions for cross-provider work.
**Suggested fix:** Either (a) extract `normalize_schema/1` from `lib/allm/tool.ex` to a shared module (`lib/allm/schema.ex` or `ALLM.JsonSchema`) and call it from both `Tool.new/1`'s `Keyword.update(opts, :schema, ...)` AND `ALLM.json_schema/3`'s `:schema` argument; or (b) document in `json_schema/3`'s `@doc` that the caller MUST pass string-keyed maps and lift the burden to the doctest. (a) is the right call — the helper is already general; only its location is private.

---

### F3: `Tool.normalize_schema/1` `@spec` is too narrow; covers only the map clause

**Category:** Project Fit (Dialyzer correctness)
**Severity:** Medium
**Location:** `lib/allm/tool.ex:143-152`
**What's wrong:** `@spec normalize_schema(map()) :: map()` is attached to a defp with two clauses: `normalize_schema(schema) when is_map(schema)` AND `normalize_schema(other), do: other`. Dialyzer will flag the second clause as "type does not match" or "unreachable" because the spec advertises the function only accepts maps. The second clause is reachable in practice — `Keyword.update/4`'s default is `%{}`, but `__from_tagged__/1` passes `data["schema"] || %{}` which is always a map — so the second clause is currently dead code AND wrongly-spec'd.
**Why it matters:** Dialyzer noise + invitations for `mix dialyzer` to report a false-positive that gets ignored. The `defp normalize_schema(other), do: other` clause looks defensive (against future callers passing a non-map?) but isn't reachable today.
**Suggested fix:** Either drop the `defp normalize_schema(other), do: other` clause entirely (preferred — `__from_tagged__/1`'s `|| %{}` already guarantees a map), or widen the spec to `@spec normalize_schema(term()) :: term()`. Same applies to `defp to_string_key/1` on `lib/allm/tool.ex:182-183` — only handles binary and atom; an integer key (e.g., user-supplied numeric `properties` keyed map) would raise `FunctionClauseError` deep inside `deep_stringify`. Add a `defp to_string_key(k), do: inspect(k)` fallback or document the constraint explicitly.

---

### F4: `Validate.module_of/1` ships eight clauses for one realistic case

**Category:** YAGNI
**Severity:** Low
**Location:** `lib/allm/validate.ex:511-519`
**What's wrong:** `module_of/1` enumerates eight type cases — `BitString`, `Integer`, `Float`, `Atom`, `List`, `Tuple`, `Map`, struct module — to label the offending element's "type" for the `invalid_part_type` metadata. The only way to reach this helper is via `valid_content_part?/1` (line 363-365) returning `false`, which happens when the element is not `%TextPart{}` or `%ImagePart{}`. Realistic offending values: another struct (handled by `%mod{}` clause), a plain map (`Map` clause), or `nil`/atom (`Atom` clause). The `Integer/Float/Tuple/List/BitString` cases require a caller writing `%Message{content: [123, 1.5, {:a, :b}]}` — possible, but contrived.
**Why it matters:** Six of the eight clauses cover paths that no realistic test exercises. They expand surface area for no payoff and create a private vocabulary (`BitString`, `Integer`, `Atom` as module-name-like atoms) that doesn't appear anywhere else in `lib/`.
**Suggested fix:** Collapse to three clauses:

```elixir
defp module_of(%mod{}), do: mod
defp module_of(m) when is_map(m), do: Map
defp module_of(other), do: other |> :erlang.term_to_binary() |> byte_size() |> then(&"unknown:#{&1}bytes") |> String.to_atom()
# or simply:
defp module_of(_), do: :unknown
```

The simpler form preserves the docstring's "got: <module> or `Map`" contract and lets the human-readable `:message` opt at `lib/allm/validate.ex:493` carry the rest via `inspect/1` in the error text. Worth noting the docstring at `lib/allm/validate.ex:34` only promises "the offending element's struct module, or `Map` when the element is a plain map" — the other six clauses aren't even part of the documented contract.

---

### F5: `next_fun/1` clause count crossed CLAUDE.md's "≥7 branches" advisory

**Category:** Complexity / Project Fit
**Severity:** Low
**Location:** `lib/allm/providers/fake.ex:641-688`
**What's wrong:** Phase 21.2 added a new `next_fun/1` clause for `[{:usage, map} | rest]` (lines 679-682). The function now has eight head clauses: `pending`, `closed?: true`, `entries: []`, `[{:delay, _}|]`, `[{:sleep, _}|]`, `[{:finish, _}|]`, `[{:usage, _}|]`, `[entry|rest]`. CLAUDE.md's "dispatch tree" rule advises in-commit extraction at "≥7 branches OR ≥2 boolean-composition guards". Pattern-matched function heads aren't a single `case`, so the literal rule doesn't apply — but the spirit (one dispatch + many sub-handlers) does.
**Why it matters:** Each new dispatch atom (next time someone adds `{:reasoning, _}` or `{:image_part, _}` etc.) compounds the count. Pre-emptive extraction at the eighth clause is cheaper than at the tenth.
**Suggested fix:** Defer to the next phase that touches Fake script vocabulary. When `next_fun/1` grows a ninth clause, extract a `dispatch_entry/2` private function keyed off the head atom and have `next_fun/1` reduce to four heads (pending, closed, empty, generic-dispatch). Don't change in this commit — same-commit extraction risks regressing Fake's well-tested per-entry semantics.

---

### F6: Steering doc has self-contradicting bullet for streaming `:usage` event shape

**Category:** Project Fit (design-vs-code drift, per CLAUDE.md "decision text drift is a known failure mode")
**Severity:** Low (the implementer made the right call)
**Location:** `steering/AMESBURY_IMPLEMENTATION_FEEDBACK.md:455` vs `:469-472`
**What's wrong:** Line 455 of the steering doc says streaming `:usage` should "emit a `{:usage, %{usage: normalized}}` event immediately before `:message_completed`". Line 469-472 says it should "land on the `:message_completed` payload's `metadata.usage` key (additive payload-key extension)". The implementation correctly chose the latter approach (additive payload key, no new `Event` variant) per CLAUDE.md's "adding a key to an existing event's payload map is NOT breaking" rule. The line-455 bullet remained in the steering doc.
**Why it matters:** A future reader of the steering doc will see the contradiction and either (a) propose the bullet-455 shape in a later sub-phase or (b) ship a parallel `Event` variant that breaks reducer exhaustiveness. CLAUDE.md explicitly calls this out: "amend the steering doc as part of the implementation commit, not as a follow-up."
**Suggested fix:** In the commit that lands Phase 21.2, edit `steering/AMESBURY_IMPLEMENTATION_FEEDBACK.md:455` from "emits a `{:usage, %{usage: normalized}}` event immediately before `:message_completed`" to "lands `metadata.usage` on the `:message_completed` payload (additive payload-key extension; no new `Event` variant)." Cite the divergence in the commit body.

---

### F7: Breaking change to `{:usage, _}` Fake script entry not yet in CHANGELOG

**Category:** Project Fit
**Severity:** Low (CHANGELOG entry is Phase 21.6's responsibility per the design)
**Location:** `lib/allm/providers/fake.ex:679-682`; observable effect at `test/allm/providers/fake_stream_test.exs:102-122` and `test/allm/stream_runner_test.exs:200-241`
**What's wrong:** Before Phase 21.2, `{:usage, map}` script entries emitted a `{:raw_chunk, {:usage, map}}` event on the streaming path (per `Script.interpret/1` at `lib/allm/providers/fake/script.ex:309-310`). Post-Phase 21.2, the streaming arm absorbs these entries into `acc.script_usage` and folds them onto `:message_completed.metadata.usage` instead — the `:raw_chunk` no longer fires. The non-streaming `generate/2` path is unaffected. The `stream_runner_test.exs` test had to change FROM `{:usage, _}` TO `{:raw_chunk, {:usage, _}}` to exercise the raw-chunk carve-out — exactly the kind of migration a downstream Fake user would also need.
**Why it matters:** A Fake user with a script asserting `assert {:raw_chunk, {:usage, _}} in events` on the streaming path will see the assertion fail with no error message after upgrading. This is exactly the "silent breaking change" class CLAUDE.md guards against.
**Suggested fix:** Phase 21.6's v0.4.0 CHANGELOG entry MUST list "Breaking: `{:usage, _}` Fake script entries no longer emit `:raw_chunk` events on the streaming path — they fold onto `:message_completed.metadata.usage` as `%ALLM.Usage{}`. Tests asserting against `:raw_chunk` must switch to `{:raw_chunk, {:usage, _}}` script entries (which emit `:raw_chunk` verbatim) OR assert against `payload.metadata.usage` on `:message_completed`." Pair with the existing breaking-change line for "tool schema auto-normalization for atom-keyed maps" per `steering/AMESBURY_IMPLEMENTATION_FEEDBACK.md:122,704`.

---

### F8: `:record` opt forwards `opts` verbatim — moduledoc claim "Fake never sees real keys" is partly true

**Category:** Project Fit
**Severity:** Low
**Location:** `lib/allm/providers/fake.ex:765-776`
**What's wrong:** The internal comment at `lib/allm/providers/fake.ex:765-768` says "No key scrubbing — the caller owns the opts they passed in. Fake never sees real keys in practice." The first half is true (`opts` is forwarded verbatim — no defensive scrub). The second half elides a real path: a test that exercises the BYOK flow (`ALLM.generate(engine, req, api_key: "sk-real")`) against a Fake-backed engine WILL place `:api_key => "sk-real"` into `opts` per `lib/allm/stream_runner.ex:255-259`'s `maybe_put_api_key/2`. The recorded message will then carry the key.
**Why it matters:** Low risk because `record:` is a test-mode opt-in, but the moduledoc-adjacent reassurance "Fake never sees real keys" is overconfident. A user reading it could plausibly conclude they don't need to redact `opts` before storing the recorded messages.
**Suggested fix:** Tighten the inline comment to "Fake never resolves real keys (no `ALLM.Keys.fetch!/2` path), but `opts[:api_key]` from a BYOK-flow caller flows in verbatim. Callers wanting redaction can `Keyword.delete(opts, :api_key)` before asserting on the recorded message." OR add a `:redact_keys` opt that scrubs known-sensitive keys (`:api_key`, `:authorization`) before `send/2`. The doc-only fix is sufficient.

---

### F9: `Image.from_data_uri/1` accepts media-type parameters but doesn't strip them

**Category:** API Design
**Severity:** Low
**Location:** `lib/allm/image.ex:193-207`
**What's wrong:** The parser splits on `";base64,"` with `parts: 2`. For an input like `data:image/svg+xml;charset=utf-8;base64,PHN2Zy8+`, the split lands `mime = "image/svg+xml;charset=utf-8"` and `encoded = "PHN2Zy8+"`. The MIME field on the resulting `%Image{}` then carries the parameter (`charset=utf-8`) bundled into the type string. Adapter consumers expecting a bare `image/svg+xml` may reject or mis-route. The current behavior is undocumented either way.
**Why it matters:** Data-URIs with media-type parameters are uncommon but legal per RFC 2397; integrators copy-pasting URIs from browser DevTools occasionally get the parameterized form. A documentation-only call-out is enough.
**Suggested fix:** Either (a) strip the first `;`-delimited segment as the MIME type and discard parameters explicitly, with a `@doc` note that parameters are dropped; or (b) document in the `@doc` that the MIME segment is forwarded verbatim and a `;`-bearing MIME may not round-trip to a clean `data:<mime>;base64,...` form. Pick (a) — three-line shape:

```elixir
[full_mime, encoded] when full_mime != "" ->
  mime = String.split(full_mime, ";", parts: 2) |> hd()
  %__MODULE__{source: {:base64, encoded}, mime_type: mime}
```

This matches the existing `from_base64/2` doctest semantics (bare MIME types only).

---

## Reuse Opportunities

- **`ALLM.Response.text/1` (`lib/allm/response.ex:100-103`)** already implements the `output_text → message.content → nil` fall-back that `ALLM.unwrap/1`'s first two clauses re-derive. See F1.
- **`Tool.normalize_schema/1` (`lib/allm/tool.ex:143-152`)** should be lifted to a shared `ALLM.JsonSchema` (or `ALLM.Schema`) module so `ALLM.json_schema/3` can reuse it. See F2.
- **`module_of/1` collapse** — the existing `defp module_of(%mod{}), do: mod` head plus a 2-arm fall-back covers every realistic offending-element type. The other six clauses can go. See F4.

## Patterns

Two findings share a single root: **`Tool.new/1`'s schema normalization (F2) and `Response.text/1`'s output-text fall-back (F1) were both written from scratch when a half-step's grep would have surfaced an existing helper or asymmetric peer.** Both are textbook cases CLAUDE.md addresses with "Did we reinvent this?". The fix in both cases is structural (extract or delegate), not stylistic.

One finding is a steering-doc-vs-code drift (F6) — the implementer correctly chose the better alternative; the doc just needs to be amended in-commit per CLAUDE.md.

## Positive Notes

- **`ALLM.Sandbox` is well-shaped.** The `$callers` walk mirrors Mox / `Ecto.Adapters.SQL.Sandbox` byte-for-byte in approach, the comments explicitly cite that lineage, `with_engine/2` correctly restores prior state via `try/after`, and the moduledoc is honest about the storage key and isolation model. No reinvention; clean separation between same-process fast path and cross-process walk.
- **`StreamCollector.extract_metadata_usage/2` is a two-line surface and a single-purpose helper.** Pattern-matches the metadata key directly, falls through to preserve prior state. No mixed-level abstraction.
- **The Fake `:record` opt's `Process.alive?` check + raise-on-dead-pid is the right shape for a test helper** — fails loudly in-test rather than silently swallowing a `send/2` to a dead pid. Documented inline.
- **The `{:usage, _}` script-entry rewire (F7) is honest in the tests** — the migrated `fake_stream_test.exs:102` and `stream_runner_test.exs:200` both carry inline comments explaining the new shape. A future reader can trace the rationale without the steering doc.
- **`mix.exs` correctly adds `guides/fakes.md` to both `package[:files]` (line 73) AND `docs[:extras]`** per CLAUDE.md's "superset" rule. Caught the trap that bit v0.3.0.
- **No `Logger.debug/1` interpolation foot-guns introduced** in any of the touched adapter files. The hot-path discipline holds.
- **`@spec` coverage on public functions is uniform** across `unwrap/1`, `Sandbox.{set,get,with,unset}_engine`, `Image.from_data_uri/1`, and `Tool.new/1`. The only spec-narrowness issue is on a private helper (F3).
