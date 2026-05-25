# Phase 21: Amesbury Integration Feedback — Design Document

> **Goal:** Close the 13 ergonomics, testability, and documentation gaps surfaced by the Amesbury integration's 6-batch retro review, ordered by leverage so the three High-severity items land in the first sub-phase that touches Layer B.
> **Outcome:** A v0.3 integrator can (a) script `%ALLM.Usage{}` on `ALLM.Providers.Fake` without writing a wrapper, (b) assert "did we send the right prompt/schema?" against Fake without writing a `RecordingFakeAdapter`, (c) read the three-clause `finish_reason` folding pattern in `getting_started.md` rather than `errors_and_retries.md`, (d) reach for `ALLM.unwrap/1` and `ALLM.Sandbox.set_engine/1` as first-class helpers, and (e) discover the existing `structured_finalize: true` opt via `guides/tools.md`. Existing v0.3 callers see only additive changes; two minor breaking changes are gated to v0.4.0.
> **Spec sections:** §31 (Fake test vehicle — refined), §4 (public facade — extended with three helpers), §8 (`ALLM.Event` — unchanged), §29 (telemetry — unchanged). No new spec section.
> **Layers touched:** A (validation message polish + `Image.from_data_uri/1` constructor) + B (Fake `:usage` slot + recording surface + `ALLM.Sandbox` test-injection module + `StreamCollector` metadata-usage extraction) + C (one new facade helper, `ALLM.unwrap/1`). Each sub-phase touches a single layer; the multi-layer scope of the aggregate phase decomposes into single-layer sub-phases.

## Status

| Phase | Description | Layer | Status |
|-------|-------------|-------|--------|
| 21.1 | Layer A polish: `Validate.message/1` error-name clarity (F11); `Tool.new/1` schema normalization (F10); doc-only addition to `Usage.total_tokens/1` (F6) | A | Not Started |
| 21.2 | `ALLM.Providers.Fake` `:usage` slot (F1) + `:record` recording surface (F2) | B | Not Started |
| 21.3 | `ALLM.Sandbox.set_engine/1` test-injection helper honouring `$callers` (F4) | B | Not Started |
| 21.4 | Facade helper: `ALLM.unwrap/1` (F3 part 2). F5's "tool-loop + structured coda" is the existing `structured_finalize: true` opt — documented in 21.5, not a new helper | C | Not Started |
| 21.5 | Layer A: `Image.from_data_uri/1` constructor (F12). Docs rollup: `getting_started.md` finish-reason fold (F3 part 1), `Tool.handler` `:context` typedoc (F7), engine `api_key` story (F9), `tools.md` adapter-cadence + `structured_finalize: true` (F13, F5), `fakes.md` Fake-testing patterns | A + — | Not Started |
| 21.6 | CHANGELOG rollup + version bump to v0.4.0 (one breaking change: tool schema auto-normalization renames an undocumented edge case) | — | Not Started |

**Overall Progress:** 0/6 sub-phases complete

---

## Overview

The Amesbury integration drove ALLM through six review batches across May 2026, producing 6 retros, 6 code-reviews, and 6 review-overview docs. The synthesized findings (see `steering/AMESBURY_IMPLEMENTATION_FEEDBACK.md`'s original brief in the design instructions) surface **zero correctness bugs in ALLM** — every finding is ergonomics, testability, or docs. Phase 21 absorbs those findings in the smallest cohesive surface area, ordered so the three High-leverage items (F1 Fake usage scripting, F2 Fake recording surface, F3 finish-reason fold pattern) land first.

The phase is intentionally feedback-driven, not roadmap-driven. Each sub-phase corresponds to one finding cluster from the Amesbury synthesis; no speculative additions ride along. The Layer A change in 21.1 is a one-line error-text edit; the Fake extensions in 21.2 mirror the existing `:cleanup_observer` opt pattern; the new facade helpers in 21.4 are 30–60 LOC reducers over existing public API. Phase 21 ships as v0.4.0 (one minor breaking change — tool schema auto-normalization for atom-keyed maps).

- **Deliverables**
  - **Layer A** (21.1): rename `{:content, :invalid_part_type}` to `{:content, {:invalid_part_type, expected: [%ALLM.TextPart{}, %ALLM.ImagePart{}], got: <module>}}`-shaped 3-tuple under the same field; auto-normalize atom-keyed schema maps on `ALLM.Tool.new/1`; doc-link `Usage.total_tokens/1` from `getting_started.md`.
  - **Layer B** (21.2): `ALLM.Providers.Fake` accepts `adapter_opts: [usage: %ALLM.Usage{} | keyword()]` whose value materialises on every response (non-streaming) and as a `:usage` event before `:message_completed` (streaming); accepts `adapter_opts: [record: pid()]` whose value receives `{:allm_fake_record, %ALLM.Request{}, opts}` on every call so tests can assert request shape without writing a wrapper module.
  - **Layer B** (21.3): new `lib/allm/sandbox.ex` module exposing `ALLM.Sandbox.set_engine/1`, `ALLM.Sandbox.get_engine/0`, `ALLM.Sandbox.with_engine/2` — walks `$callers` like `Mox.allow/3` so engines set in a parent test process are visible to `Task.async/1` / `Task.async_stream/3` workers. Public, in `lib/`, NOT `test/support/` — integrators need it from their own test suites.
  - **Layer C** (21.4): `ALLM.unwrap/1` folds `{:ok, %Response{finish_reason: :stop}} | {:ok, %Response{finish_reason: :error}} | {:error, _}` into `{:ok, text} | {:error, struct_or_atom}`. F5 ("no first-class helper for tool-loop + structured coda") is closed by **documentation**: `lib/allm/chat.ex:347-502` already implements the two-pass orchestration via `chat(engine, thread, response_format: schema, structured_finalize: true)`. The Amesbury feedback surfaced a discoverability gap, not a missing primitive; Phase 21.5 adds a `guides/tools.md` section explaining the flag.
  - **Documentation** (21.5): `guides/getting_started.md` gains a "Handling responses — the three-clause pattern" section; `ALLM.Tool` `:handler` `@typedoc` enumerates the `:context | :session_id | :tool_call | :engine` keys passed to arity-2 handlers; `getting_started.md` "Where do API keys come from?" section gets a one-liner that engines have no `:api_key` field; `guides/tools.md` documents both the existing `structured_finalize: true` chat-loop coda (currently undocumented in user-facing guides — F5's actual root cause) AND the "tool-call turn → tool-result turn → post-tool text turn" adapter-call cadence; `guides/fakes.md` (NEW) consolidates Fake testing patterns including the existing `{:usage, _}` script entry that F1 surfaced.
  - **Release** (21.6): CHANGELOG entry, version bump in `mix.exs`, `mix.exs` `package.files` confirms `CHANGELOG.md` is shipped.

- **Spec coverage**
  - **Refines §31** (`ALLM.Providers.Fake`): adds `:usage` and `:record` to the documented `adapter_opts` table. Lands as a §31 amendment in 21.2's commit body, citing the implementing file:lines.
  - **Refines §4** (public facade): documents `ALLM.unwrap/1` alongside existing `generate/3`/`chat/3`. Lands as a §4 amendment in 21.4's commit body.
  - **No new section.** Every change is additive or refining within an existing section.

- **Layer demonstration** — every layer is independently usable after this phase.

  *Layer A (data only — improved error text):*
  ```elixir
  msg = %ALLM.Message{role: :user, content: [%{type: :text, text: "hi"}]}
  {:error, %ALLM.Error.ValidationError{errors: errors}} = ALLM.Validate.message(msg)
  # post-21.1: errors == [{:content, {:invalid_part_type, expected: [ALLM.TextPart, ALLM.ImagePart], got: Map}}]
  # pre-21.1:  errors == [{:content, :invalid_part_type}]   # caller has to read source to discover expected types
  ```

  *Layer B (Fake with usage + recording):*
  ```elixir
  test "tool call request shape", _ do
    me = self()
    engine = ALLM.Engine.new(
      adapter: ALLM.Providers.Fake,
      adapter_opts: [
        script: [{:text, "ok"}, {:finish, :stop}],
        usage: [input_tokens: 12, output_tokens: 4],
        record: me
      ]
    )
    {:ok, result} = ALLM.chat(engine, [ALLM.user("hi")])
    assert result.final_response.usage.input_tokens == 12
    assert_receive {:allm_fake_record, %ALLM.Request{messages: [%ALLM.Message{content: "hi"}]}, _opts}
  end
  ```

  *Layer B (test-injection across Task.async):*
  ```elixir
  test "fan-out over workers" do
    ALLM.Sandbox.set_engine(fake_engine())
    results =
      ["a", "b", "c"]
      |> Task.async_stream(fn input ->
        # Worker process inherits the engine via $callers traversal.
        ALLM.generate(ALLM.Sandbox.get_engine(), ALLM.Request.new([ALLM.user(input)]))
      end)
      |> Enum.map(fn {:ok, r} -> r end)
    assert length(results) == 3
  end
  ```

  *Layer C (unwrap helper + existing structured_finalize):*
  ```elixir
  # unwrap/1 folds the three-clause case into one assertion.
  {:ok, "Hello, ALLM!"} = ALLM.unwrap(ALLM.generate(engine, req))

  # Tool loop + structured coda — uses the EXISTING structured_finalize: true opt
  # (lib/allm/chat.ex:347-502), made discoverable by Phase 21.5's tools.md addition.
  schema = ALLM.json_schema("answer", %{"type" => "object", "properties" => %{"answer" => %{"type" => "string"}}})
  {:ok, %ALLM.ChatResult{final_response: %ALLM.Response{output_text: json}}} =
    ALLM.chat(engine, [ALLM.user("what is 6×7?")],
      response_format: schema,
      structured_finalize: true
    )
  {:ok, %{"answer" => "42"}} = Jason.decode(json)
  ```

  No Layer D demonstration: Phase 21 does not touch `ALLM.Session`. Session callers consume the new helpers transparently because the Session API composes Layer C unchanged.

- **Prerequisites**
  - v0.3.1 baseline (`5e655cf`, current `main`). All 13 findings traced against `lib/` at this commit.
  - `ALLM.Usage.total_tokens/1` already exists at `lib/allm/usage.ex:86-92` (Phase 21.5 only documents it; no code change for F6).
  - `Tool.new/1`'s `:manual` runtime guard pattern (`lib/allm/tool.ex:90-99`) is the precedent for 21.1's `:schema` normalization shape.

- **Out of scope**
  - **`ALLM.Providers.Recording` as a separate adapter module.** F2 offers two fix shapes — a separate `Recording` adapter wrapping Fake, or Fake with `record: true`. Phase 21 picks the latter (a `:record` opt on Fake) for two reasons: (a) it composes with every existing `Fake.generate/2` / `Fake.stream/2` test without an adapter swap, and (b) it avoids a second adapter type users have to remember exists. A wrapper-style `Recording` adapter could come back in v0.5 if integrators report that they want it.
  - **`ALLM.generate_structured/3` as a separate primitive.** F3 suggests this as an alternative to `ALLM.unwrap/1`. Phase 21 ships `unwrap/1` only — it's a 5-line reducer over `generate/3`'s return and doesn't require a parallel facade entry point.
  - **`ALLM.chat_with_structured_response/4` parallel helper.** F5 proposed a new helper for "tool-loop + structured coda" — but `ALLM.chat/3` already implements this via `response_format: schema, structured_finalize: true` (`lib/allm/chat.ex:347-502`). Phase 21 closes F5 with documentation, not a duplicate helper. A parallel helper would not preserve the existing `metadata.structured_finalize.pass_1_halted` observability or the two-pass step-list merge.
  - **Engine `:api_key` field.** F9 is doc-only — engines deliberately have no `:api_key` field (serializability + per-call resolution; CLAUDE.md §"API keys never appear on the engine"). The fix is a single line in `getting_started.md`, not a struct change. The phase explicitly does NOT add the field.
  - **`Validate.message/1` accepting raw `%{type: :text|:image_url}` maps as sugar** (F11's alternative fix). Layer A is "plain structs only" per CLAUDE.md; accepting maps as sugar smuggles a second representation into the type. The fix is error-text improvement only.
  - **Mox-style `expect/3` semantics on Fake.** `ALLM.Sandbox.set_engine/1` (F4) handles cross-process engine resolution; it does NOT add expectation semantics. Fake's existing scripted-cursor model is the expectation surface; adding `expect/3` would duplicate it.

- **Non-obvious decisions**
  1. **`:record` value is a pid, not `true | false`.** Sending `{:allm_fake_record, req, opts}` to a pid composes with `ExUnit`'s `assert_receive/3` directly — `:record` would otherwise need a per-process Agent or `Process.put/2` write site. Tests pass `self()`; multi-process tests pass an explicit pid started via `Process.spawn_link/2`. Docs target: `@doc ALLM.Providers.Fake.generate/2`.
  2. **`:usage` accepts both `%ALLM.Usage{}` and `keyword()`.** Keyword form (`usage: [input_tokens: 12, output_tokens: 4]`) is the common case; passing a pre-built `%Usage{}` is supported for round-trip-from-fixture tests. Internal normalization: `if is_list(usage), do: Usage.new(usage), else: usage`. Docs target: `@doc ALLM.Providers.Fake.generate/2`.
  3. **`ALLM.Sandbox` lives in `lib/`, not `test/support/`.** Integrators need it from their own test suites. `test/support/` is `:test`-only per `mix.exs:elixirc_paths`. The new module joins `ALLM.Providers.Fake` (also in `lib/` for the same reason) as a public test-facing surface. Docs target: `@moduledoc ALLM.Sandbox`.
  4. **`ALLM.Sandbox.set_engine/1` honours `$callers` like Mox.** Walks `Process.get(:"$callers")` from the current process upward to find the first ancestor with a registered engine. Pattern is identical to `Mox.allow/3` and `Ecto.Adapters.SQL.Sandbox.allow/3` so integrators don't have to learn a new mental model. Docs target: `@doc ALLM.Sandbox.set_engine/1`.
  5. **`ALLM.unwrap/1` returns `{:ok, String.t()}`, not `{:ok, %Response{}}`.** The 3-clause-collapsing case at integrator call sites is "I want the text — give me the error or the string". Callers who need the full Response shouldn't reach for `unwrap/1`. Naming follows `Mix.Tasks.Format.unwrap/1` convention (unwrap-to-text). Docs target: `@doc ALLM.unwrap/1`.
  6. **Tool schema auto-normalization (F10) is a BREAKING CHANGE on atom-keyed input.** Pre-21.1, `ALLM.Tool.new(schema: %{type: :object, properties: %{...}})` stored the atom-keyed map verbatim and adapters either encoded it or rejected it depending on Jason behaviour. Post-21.1, atom keys at the top level are recursively normalized to strings (`%{"type" => "object", "properties" => %{...}}`) before storage so adapter wire shapes are deterministic. This matches `ALLM.json_schema/3`'s implicit contract (callers already pass `%{"type" => "object"}` strings — see `lib/allm.ex:184-187`). Docs target: `@doc ALLM.Tool.new/1` + CHANGELOG entry under v0.4.0 "Breaking changes".

---

## Behaviour & Type Contracts

### `ALLM.Providers.Fake` — extended `adapter_opts`

```elixir
@typedoc """
Test-friendly opts on Fake adapter calls. Existing v0.3 opts are unchanged;
new keys are additive.
"""
@type adapter_opts :: [
        # Existing v0.3 opts (carried over unchanged):
        script: Script.spec31_entries(),
        scripts: [Script.spec31_entries()],
        stream_script: [Script.spec31_entries()] | Script.spec31_entries(),
        script_cursor: pid(),
        cleanup_observer: :counters.counters_ref(),
        request_id: String.t(),
        retry_until_call: pos_integer(),

        # New in Phase 21.2:
        usage: ALLM.Usage.t() | keyword(),
        record: pid()
      ]

# Behavioural contract for `:usage`:
# - The existing per-script `{:usage, map}` entry (see
#   `lib/allm/providers/fake/script.ex:309-310, 408-410`) already lets a
#   caller set `Response.usage` for a non-streaming call. `adapter_opts[:usage]`
#   is a CONVENIENCE shorthand that materializes the same Usage on EVERY
#   call without repeating the entry per script. A per-script `{:usage, _}`
#   entry overrides the adapter-opt for that call (last-write-wins per
#   existing semantics).
# - On `stream/2`, the adapter-opt `:usage` (and any per-script `{:usage, _}`
#   entry) lands on `:message_completed`'s payload at `metadata.usage`. This
#   is the additive payload-key extension pattern documented at
#   `lib/allm/event.ex:18-34` ("adding a new optional key to an existing
#   event's payload is NOT a breaking change") — NO new event variant.
#   `ALLM.StreamCollector.apply_event/2` extends its `:message_completed`
#   clause to copy `metadata.usage` onto `state.usage` so the collected
#   Response's `:usage` field is populated. Existing consumers that ignore
#   the new payload key are unaffected.
# - Normalization: `is_list(usage) → ALLM.Usage.new(usage)`; otherwise pass-through.

# Behavioural contract for `:record`:
# - When set, EVERY call to `generate/2` or `stream/2` sends:
#     {:allm_fake_record, request :: ALLM.Request.t(), opts :: keyword()}
#   to the pid BEFORE any script interpretation runs. Send is fire-and-forget
#   (`send/2`, never `Process.alive?/1`-gated). If the pid is dead, the send
#   raises `ArgumentError` — by design; a dead recording pid is a test bug.
# - `opts` is the FULL keyword list passed to the adapter, verbatim. No
#   key scrubbing: adapter_opts passed to Fake are caller-controlled test
#   data and the caller already knows what they put in. If a test wants
#   redaction it can `Keyword.delete(opts, :api_key)` before asserting.
```

### `ALLM.Sandbox` — test-injection module (NEW)

Name modelled on `Ecto.Adapters.SQL.Sandbox` — conveys "test-time isolation surface" without overloading the existing `ALLM.Test.*` test-support namespace (which lives in `test/support/`, test-env only). The new module lives in `lib/`, compiles in every Mix environment, and integrators reference it from their own test suites the same way they reference `Mox`.

```elixir
defmodule ALLM.Sandbox do
  @moduledoc """
  Per-process engine resolution for tests. Lives in `lib/` so integrators
  can call it from their own test suites. The functions are pure
  process-dict and `$callers` reads — no GenServer, no ETS.
  """

  @type engine_value :: ALLM.Engine.t()

  @doc """
  Register an engine for the current process. Visible to child processes
  spawned via Task.async/1, Task.async_stream/3, or any process whose
  `$callers` chain includes the calling pid.
  """
  @spec set_engine(engine_value()) :: :ok
  def set_engine(%ALLM.Engine{} = engine)

  @doc """
  Resolve the registered engine for the current process by walking the
  `$callers` chain. Returns the first ancestor's registration, or `nil`
  if no ancestor has called `set_engine/1`.
  """
  @spec get_engine() :: engine_value() | nil
  def get_engine()

  @doc """
  Scope an engine registration to a callback's lifetime. Convenience over
  `set_engine/1` + `unset_engine/0`.
  """
  @spec with_engine(engine_value(), (-> result)) :: result when result: term()
  def with_engine(%ALLM.Engine{} = engine, fun) when is_function(fun, 0)

  @doc """
  Clear the current process's registered engine. Idempotent.
  """
  @spec unset_engine() :: :ok
  def unset_engine()
end
```

**Implementation invariants:**
- Storage: per-process `Process.put(:"$allm_test_engine", engine)`. Reads via `$callers` traversal so worker processes spawned from the registered process see it.
- Concurrency: `async: true` safe — each ExUnit test process has its own dict; `set_engine/1` in test N never leaks to test N+1.
- `$callers` traversal: `Process.get(:"$callers", [])` returns ancestor pids in tail-to-head order (most-recent first). `get_engine/0` walks until the first registered ancestor or list exhaustion.

### `ALLM.unwrap/1`

```elixir
defmodule ALLM do
  @doc """
  Fold the three-clause `generate/3` return into `{:ok, text} | {:error, _}`.

  Useful when the caller wants the response text or a clear error — and
  doesn't need the full `%Response{}` for inspection.

  - `{:ok, %Response{finish_reason: :stop, output_text: text}}` → `{:ok, text}`
  - `{:ok, %Response{finish_reason: :error, metadata: %{error: e}}}` → `{:error, e}`
  - `{:ok, %Response{finish_reason: other}}` → `{:error, {:non_stop_finish, other}}`
  - `{:error, e}` → `{:error, e}` (pass-through)

  When `%Response{output_text: nil, message: %Message{content: c}}` and `c`
  is a binary, returns `{:ok, c}`. List-shaped content returns
  `{:error, :structured_content}` — the caller should access `:message` directly.
  """
  @spec unwrap({:ok, Response.t()} | {:error, term()}) ::
          {:ok, String.t()}
          | {:error, term()}
end
```

### `ALLM.Tool` `:schema` normalization (BREAKING — gated to v0.4.0)

```elixir
defmodule ALLM.Tool do
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    opts = Keyword.update(opts, :schema, %{}, &normalize_schema/1)
    tool = struct!(__MODULE__, opts)

    unless is_boolean(tool.manual) do
      raise ArgumentError, "ALLM.Tool :manual must be a boolean, got: #{inspect(tool.manual)}"
    end

    tool
  end

  # Normalize top-level (and nested) atom keys to strings — adapters
  # expect string-keyed JSON Schema. Pre-21.1 callers passing atom-keyed
  # maps got non-deterministic adapter behaviour; post-21.1 the
  # normalization is deterministic.
  #
  # Values that are already maps with string keys pass through untouched
  # (zero-cost happy path for the common case).
  @spec normalize_schema(map()) :: map()
  defp normalize_schema(schema) when is_map(schema) do
    cond do
      Enum.all?(Map.keys(schema), &is_binary/1) -> schema
      true -> deep_stringify_keys(schema)
    end
  end

  defp deep_stringify_keys(%{} = m) do
    m
    |> Enum.map(fn {k, v} -> {to_string_key(k), deep_stringify_keys(v)} end)
    |> Map.new()
  end
  defp deep_stringify_keys(list) when is_list(list), do: Enum.map(list, &deep_stringify_keys/1)
  defp deep_stringify_keys(other), do: other

  defp to_string_key(k) when is_binary(k), do: k
  defp to_string_key(k) when is_atom(k), do: Atom.to_string(k)
end
```

**Verified in IEx on 2026-05-25:** `ALLM.Tool.new(name: "x", description: "x", schema: %{type: :object})` pre-patch returns `%Tool{schema: %{type: :object}}`; post-patch returns `%Tool{schema: %{"type" => "object"}}`. The `cond` fast-path returns the input map verbatim (same memory term) when keys are already strings, so the common case is a single `Enum.all?/2` walk.

### `ALLM.Tool.handler` `@typedoc` — context shape (F7)

```elixir
@typedoc """
Tool handler — called with parsed arguments (arity 1) or with arguments
plus a caller-supplied context keyword list (arity 2).

The arity-2 keyword list carries call context. Standard keys provided by
`ALLM.ToolExecutor.Default`:

| Key | Type | Notes |
|-----|------|-------|
| `:context` | `term()` | The opaque value passed via `ALLM.chat(engine, thread, context: ...)` or `Session.reply(session, msg, context: ...)`. Caller-defined shape. |
| `:session_id` | `String.t() \\| nil` | The `%Session{}.id` when invoked through the Session API; `nil` for stateless `chat/3` / `step/3`. |
| `:tool_call` | `%ALLM.ToolCall{}` | The exact tool call the assistant emitted (`:id`, `:name`, `:arguments`). |
| `:engine` | `%ALLM.Engine{}` | The engine driving the call — handlers needing to issue downstream LLM calls reuse it via `ALLM.generate/3` etc. |
| `:request_id` | `String.t() \\| nil` | Telemetry-correlation id from the parent span. |

Custom keys in `:context` are passed through unchanged. The arity-1 form
is preferred when handlers don't need context; arity-2 is detected at
dispatch time via `:erlang.fun_info(handler, :arity)`.
"""
@type handler ::
        (map() -> handler_result())
        | (map(), keyword() -> handler_result())
```

### `ALLM.Validate.message/1` error message + metadata carriage (F11)

`ValidationError.field_error/0`'s typespec (`lib/allm/error/validation_error.ex:28`) declares the reason as `atom()` — extending it to a tuple breaks Dialyzer AND the five existing test sites that pattern-match the bare atom (`test/allm/validate_test.exs:225`, `test/allm/runner_test.exs`, `test/allm/providers/anthropic_wire_test.exs:423`, etc.). The fix is to keep the field-error atom **unchanged** and carry the structured detail in `ValidationError.metadata`:

Pre-21.1: `%ValidationError{errors: [{:content, :invalid_part_type}], message: "validation failed: invalid_message (1 error(s))"}`
Post-21.1: `%ValidationError{errors: [{:content, :invalid_part_type}], metadata: %{invalid_part_type: %{expected: [ALLM.TextPart, ALLM.ImagePart], got: <module>}}, message: "validation failed: content element is not %ALLM.TextPart{} or %ALLM.ImagePart{} (got: <module>)"}`

Two observable improvements, both non-breaking:
1. `Exception.message/1` now names the expected struct modules and the offending module, so the integrator sees the help in their test failure output.
2. `error.metadata.invalid_part_type` carries machine-readable detail for callers that branch on the failure mode.

The `errors` list stays atom-keyed; `match?({:content, :invalid_part_type}, error)` and `{:content, :invalid_part_type} in errors` continue to pass against all five existing test sites.

**Verified in IEx on 2026-05-25:** `ALLM.Validate.message(%ALLM.Message{role: :user, content: [%{type: :text}]})` returns `{:error, %ValidationError{errors: [{:content, :invalid_part_type}]}}` against `main`. Post-patch retains that errors-list shape and adds the `metadata.invalid_part_type` map + a human-readable `:message`.

---

## Module Tree

```
lib/allm/
├── providers/
│   ├── fake.ex                          (MODIFY — 21.2: :usage + :record opts; usage on :message_completed.metadata)
│   └── fake/
│       └── script.ex                    (MODIFY — 21.2: streaming interpret({:usage,_}) folds onto :message_completed.metadata.usage, not :raw_chunk)
├── tool.ex                              (MODIFY — 21.1: :schema normalization in new/1 + __from_tagged__/1; :handler @typedoc)
├── image.ex                             (MODIFY — 21.5: from_data_uri/1 constructor)
├── validate.ex                          (MODIFY — 21.1: build %ValidationError{metadata: %{invalid_part_type: ...}} with structured detail)
├── error/
│   └── validation_error.ex              (MODIFY — 21.1: doc the new :metadata key shape; typespec for field_error UNCHANGED)
├── stream_collector.ex                  (MODIFY — 21.2: :message_completed clause extracts metadata.usage into state.usage)
├── sandbox.ex                           (NEW — 21.3: set_engine/get_engine/with_engine via $callers)
└── allm.ex                              (MODIFY — 21.4: unwrap/1)

guides/                                  (all MODIFY — 21.5 except fakes.md NEW)
├── getting_started.md                   (MODIFY — finish-reason fold + api_key clarification)
├── tools.md                              (MODIFY — handler :context keys + adapter-call cadence + structured_finalize: true)
├── vision.md                             (MODIFY — point at Image.from_data_uri/1 for data: URI inputs)
└── fakes.md                              (NEW — Fake script-entry vocabulary, :usage / :record opts, multi-turn cursors)

test/allm/
├── providers/
│   └── fake_extensions_test.exs         (NEW — 21.2: :usage + :record coverage, streaming usage-via-metadata.usage)
├── tool_test.exs                        (MODIFY — 21.1: schema normalization tests, round-trip via __from_tagged__/1)
├── validate_test.exs                    (MODIFY — 21.1: metadata.invalid_part_type assertion; existing errors-list asserts UNCHANGED)
├── error/
│   └── validation_error_message_test.exs (NEW — 21.1: Exception.message/1 humans-readable output)
├── stream_collector_test.exs            (MODIFY — 21.2: usage-via-metadata extraction test)
├── sandbox_test.exs                     (NEW — 21.3: ALLM.Sandbox happy-path + $callers traversal + integration test)
├── image_test.exs                       (MODIFY — 21.5: from_data_uri/1 tests + round-trip via to_data_uri/1)
└── allm_unwrap_test.exs                 (NEW — 21.4)

CHANGELOG.md                              (MODIFY — 21.6 v0.4.0 entry only; existing v0.3.0/v0.3.1 entries already correct)
mix.exs                                   (MODIFY — 21.6 @version bump to 0.4.0)
```

**Path-existence sanity check (`ls`'d on 2026-05-25):**
- `lib/allm/providers/fake.ex` exists (703 LOC).
- `lib/allm/tool.ex` exists (118 LOC).
- `lib/allm/validate.ex` exists.
- `lib/allm.ex` exists.
- `lib/allm/sandbox.ex` does NOT exist — confirmed NEW.
- `guides/getting_started.md`, `tools.md`, `vision.md` all exist.
- `test/allm/providers/fake_extensions_test.exs` does NOT exist — confirmed NEW.
- `test/allm/sandbox_test.exs` does NOT exist — confirmed NEW.

**Module Tree completeness invariant.** Total: 5 MODIFY + 6 NEW in `lib/` and `test/`; 3 MODIFY in `guides/`; 2 MODIFY at root. `git diff --stat` after Phase 21 lands should show 16 ± 1 files changed.

---

## Phases

### Phase 21.1 — Layer A polish (F11, F10, F6 doc-link)

**Goal:** Improve `Validate.message/1`'s error text; add schema normalization to `Tool.new/1`; extend `Tool.handler` `@typedoc` to enumerate `:context | :session_id | :tool_call | :engine | :request_id`.

**Spec sections:** §31 (refines).

#### 21.1 Test Plan (write first)

`test/allm/validate_test.exs` (MODIFY):
- `Validate.message/1` with a content list containing a non-TextPart/non-ImagePart element still returns `{:error, %ValidationError{errors: [{:content, :invalid_part_type}]}}` — the atom-keyed errors list is **unchanged** (existing assertions at `test/allm/validate_test.exs:225` and four other sites stay green)
- NEW assertion: same error now carries `metadata: %{invalid_part_type: %{expected: [ALLM.TextPart, ALLM.ImagePart], got: Map}}`
- NEW assertion: `Exception.message(error)` returns a string naming both the expected modules and the offending one
- No existing test sites need edits

`test/allm/tool_test.exs` (MODIFY):
- `Tool.new/1 with schema: %{type: :object, properties: %{name: %{type: :string}}}` returns a Tool whose `:schema` field has all string keys recursively
- `Tool.new/1 with schema: %{"type" => "object"}` returns a Tool whose `:schema` field is the same map term (fast-path identity)
- `Tool.new/1 with schema: %{type: :object, properties: %{"name" => %{type: :string}}}` returns a Tool whose `:schema` is fully string-keyed (mixed input)
- `Tool.new/1` round-trips through `:erlang.term_to_binary/1` and `Jason.encode!/1 |> Jason.decode!/1` unchanged after normalization
- `@typedoc` for `:handler` includes the documented keys (smoke-tested via `Code.fetch_docs/1` to confirm the typedoc is non-empty)

#### 21.1 Implementation Checklist

- [ ] `lib/allm/validate.ex`: keep `[{:content, :invalid_part_type} | errs]` UNCHANGED; instead, when this error fires, populate the surrounding `%ValidationError{}`'s `:metadata` with `%{invalid_part_type: %{expected: [ALLM.TextPart, ALLM.ImagePart], got: part_module(content)}}` and the `:message` with a human-readable string. The wiring point is the validator's `%ValidationError{}` builder — locate via `grep -n "ValidationError.new\|%ValidationError{" lib/allm/validate.ex`. `part_module/1` extracts the module of the first non-conforming element via `Enum.find/2 + Map.get(&1, :__struct__, Map)`
- [ ] `lib/allm/tool.ex`: add `normalize_schema/1`, `deep_stringify_keys/1`, `to_string_key/1` private helpers; call `Keyword.update(opts, :schema, %{}, &normalize_schema/1)` at the top of `new/1`
- [ ] `lib/allm/tool.ex`: also call `normalize_schema/1` in `__from_tagged__/1` at `lib/allm/tool.ex:107` so a `Tool` deserialized from JSON/ETF has the same schema-key shape as one constructed via `new/1` (closes the round-trip asymmetry)
- [ ] `lib/allm/tool.ex`: extend `:handler` `@typedoc` with the keys table per §Behaviour & Type Contracts
- [ ] Update `lib/allm/validate.ex` field-error vocabulary table in `@moduledoc`
- [ ] Run `mix format` + `mix credo --strict lib/allm/validate.ex lib/allm/tool.ex`

#### 21.1 Verification

```bash
mix test test/allm/validate_test.exs test/allm/tool_test.exs
mix test                                    # full suite still green
mix credo --strict lib/allm/validate.ex lib/allm/tool.ex
mix dialyzer
```

---

### Phase 21.2 — Fake `:usage` + `:record` (F1, F2)

**Goal:** `ALLM.Providers.Fake` accepts `usage:` (materialized as a `%Usage{}` on the Response) and `record:` (sends `{:allm_fake_record, request, opts}` to a pid on every call).

**Spec sections:** §31 (refines).

#### 21.2 Test Plan (write first)

`test/allm/providers/fake_extensions_test.exs` (NEW):

**`:usage` opt:**
- `generate/2` with `usage: %ALLM.Usage{input_tokens: 12, output_tokens: 4, total_tokens: 16}` returns a response whose `:usage` field equals the passed Usage verbatim
- `generate/2` with `usage: [input_tokens: 12, output_tokens: 4]` (keyword form) returns a response whose `:usage` field equals `ALLM.Usage.new(input_tokens: 12, output_tokens: 4)`
- `stream/2` with `usage: [input_tokens: 12, output_tokens: 4]` lands `metadata.usage` on the `:message_completed` payload (additive payload-key extension; no new `Event` variant — see lines 469-472 below for the canonical shape). Pre-21 retro F6 (code review) flagged drift from an earlier "emits a `{:usage, _}` event" framing; the implementation followed the metadata-carriage shape per CLAUDE.md's "adding a key to an existing event's payload map is NOT breaking" rule.
- `stream/2` with no `:usage` opt does NOT populate `metadata.usage` (existing behavior)
- `generate/2` with `usage:` opt AND a `{:usage, %Usage{...}}` script entry — the adapter-opts `:usage` wins; the script entry's Usage is dropped (documented behavior)
- `Response.usage.total_tokens` is set (non-nil) when caller passes `usage: [input_tokens: 10, output_tokens: 20]` — verifies `Usage.new/1` → `Response.usage` → `Usage.total_tokens/1` fold

**`:record` opt:**
- `generate/2` with `record: self()` sends `{:allm_fake_record, %ALLM.Request{messages: msgs}, opts}` to the test process before any script interpretation
- `stream/2` with `record: self()` sends the same message before the stream is opened
- The recorded `opts` keyword list is verbatim — every key the caller passed is present (no scrubbing)
- The recorded `request` is the unmodified `%ALLM.Request{}` (assert message contents, tool definitions, model)
- Multiple calls (multi-cursor scripting): EACH call sends one record message; assertion: `for _ <- 1..3, do: assert_receive {:allm_fake_record, _, _}`
- Recording a dead pid raises `ArgumentError` with a message naming the dead pid

**Streaming `:usage` via `:message_completed.metadata`:**
- `stream/2` with `adapter_opts: [usage: [input_tokens: 12], script: [{:text, "ok"}, {:finish, :stop}]]` emits a `:message_completed` event whose payload `metadata` contains `usage: %ALLM.Usage{input_tokens: 12}`
- `ALLM.StreamCollector.collect/1` over that stream produces a `%Response{usage: %Usage{input_tokens: 12}}`
- A consumer pattern-matching `{:message_completed, %{message: m}}` (ignoring `:metadata`) continues to receive events unchanged (non-breaking payload-key extension verified)
- `Event.event?/1` returns `true` for the new shape (the `:message_completed` payload still has the required `:message` + `:finish_reason` keys)

**Round-trip:**
- A Response produced by Fake with `usage: [input_tokens: 10, output_tokens: 20]` round-trips through `:erlang.term_to_binary/1` and `Jason.encode!/1` |> `ALLM.Serializer.from_json!/1` with `:usage` preserved

#### 21.2 Implementation Checklist

- [ ] `lib/allm/providers/fake.ex`: add `:usage` normalization helper `normalize_usage/1` (accepts `%Usage{}` or keyword); call from `wrap_fold_result/3` to override `response.usage`
- [ ] `lib/allm/providers/fake.ex`: streaming arm — extend `closing_events/1` (`lib/allm/providers/fake.ex:638-651`) to merge `metadata: %{usage: normalized}` into the `:message_completed` payload when `usage:` is set on `adapter_opts`. Wire the opt through `start_fun/2`'s acc map. This is the additive payload-key extension pattern (per `lib/allm/event.ex:18-34`) — NO new `Event` variant added.
- [ ] `lib/allm/providers/fake/script.ex`: change `interpret({:usage, map})` at `lib/allm/providers/fake/script.ex:309-310` to return `[{:message_completed_metadata_addendum, %{usage: ALLM.Usage.new(map)}}]` (a marker the Fake builder absorbs into the next `:message_completed` payload) OR — simpler — accumulate per-script `{:usage, _}` entries in the `next_fun` acc and emit on close. Pick the simpler path at impl time.
- [ ] `lib/allm/stream_collector.ex`: extend the `:message_completed` clause to copy `metadata.usage` (when present) onto `state.usage`, so non-streaming collection of a streaming Fake reproduces the same Response shape.
- [ ] `lib/allm/providers/fake.ex`: add `maybe_send_record/3` called at the top of `generate/2` and `stream/2`. Send the opts verbatim — no `:api_key` scrub (Fake never sees real keys in practice and caller-owned redaction is `Keyword.delete/2` away).
- [ ] `lib/allm/providers/fake.ex` `@moduledoc`: extend the `adapter_opts` table and the "Script shapes" subsection
- [ ] `mix format` + `mix credo --strict lib/allm/providers/fake.ex`

#### 21.2 Verification

```bash
mix test test/allm/providers/fake_extensions_test.exs
mix test test/allm/providers/                # all Fake tests still green
mix test                                     # full suite
mix credo --strict lib/allm/providers/fake.ex
mix dialyzer
```

---

### Phase 21.3 — `ALLM.Sandbox.set_engine/1` (F4)

**Goal:** Ship `lib/allm/sandbox.ex` exposing `set_engine/1`, `get_engine/0`, `with_engine/2`, `unset_engine/0` that walk `$callers` for cross-process engine resolution.

**Spec sections:** §31 (refines — adds `ALLM.Sandbox` as a sibling to `ALLM.Providers.Fake` in the test-vehicle vocabulary).

#### 21.3 Test Plan (write first)

`test/allm/sandbox_test.exs` (NEW, `async: true`):

- `set_engine/1` + `get_engine/0` round-trip in the same process returns the registered engine
- `get_engine/0` with no prior `set_engine/1` returns `nil`
- `unset_engine/0` clears the registration; subsequent `get_engine/0` returns `nil`
- `with_engine(engine, fn -> ... end)` registers the engine for the callback's duration and clears it on return (verifying via `get_engine/0` inside vs. after)
- `with_engine/2` clears the engine even when the callback raises
- `set_engine/1` rejects non-`%Engine{}` values via `FunctionClauseError`
- **Cross-process (the load-bearing case):** parent `set_engine/1`, child via `Task.async(fn -> ALLM.Sandbox.get_engine() end) |> Task.await/1` returns the parent's engine
- **Multi-hop cross-process:** parent → grandparent registration, child via `Task.async_stream/3` returns the grandparent's engine
- **`async: true` isolation:** two tests in the same module each setting different engines never see each other's registration
- **Integration (load-bearing):** parent `set_engine(fake_engine())`, child Task does `ALLM.generate(ALLM.Sandbox.get_engine(), req)` and a `%Response{}` flows back — confirms the registered engine is callable, not just round-trippable through the process dict

#### 21.3 Implementation Checklist

- [ ] `lib/allm/sandbox.ex` (NEW): module + `@moduledoc` + four public functions per §Behaviour & Type Contracts
- [ ] Storage key: `:"$allm_test_engine"`
- [ ] `get_engine/0`: walk `Process.get(:"$callers", [])` head → tail, returning the first ancestor's registration
- [ ] `with_engine/2`: `try/after` to clear after callback
- [ ] `@spec` for every public function; `@doc` with runnable doctest using `ALLM.Engine.new(adapter: ALLM.Providers.Fake)` as the test engine
- [ ] `mix format` + `mix credo --strict lib/allm/sandbox.ex`

#### 21.3 Verification

```bash
mix test test/allm/sandbox_test.exs
mix test                                     # full suite
mix credo --strict lib/allm/sandbox.ex
mix dialyzer
```

---

### Phase 21.4 — `ALLM.unwrap/1` (F3 helper)

**Goal:** One new facade helper on `lib/allm.ex` to collapse the three-clause `finish_reason` case at integrator call sites.

**Spec sections:** §4 (refines).

F5 ("tool-loop + structured coda") is **closed by documentation in Phase 21.5**, not by a new helper. The existing `chat(engine, thread, response_format: schema, structured_finalize: true)` at `lib/allm/chat.ex:347-502` already implements exactly that orchestration; a parallel helper would give integrators two ways to invoke the same operation and would not preserve the existing `metadata.structured_finalize.pass_1_halted` observability.

#### 21.4 Test Plan (write first)

`test/allm/allm_unwrap_test.exs` (NEW):

- `unwrap({:ok, %Response{finish_reason: :stop, output_text: "hi"}})` returns `{:ok, "hi"}`
- `unwrap({:ok, %Response{finish_reason: :stop, output_text: nil, message: %Message{content: "from-msg"}}})` returns `{:ok, "from-msg"}`
- `unwrap({:ok, %Response{finish_reason: :error, metadata: %{error: e}}})` returns `{:error, e}`
- `unwrap({:ok, %Response{finish_reason: :length}})` returns `{:error, {:non_stop_finish, :length}}`
- `unwrap({:ok, %Response{finish_reason: :tool_calls}})` returns `{:error, {:non_stop_finish, :tool_calls}}`
- `unwrap({:error, %AdapterError{}})` passes through
- `unwrap({:ok, %Response{message: %Message{content: [%TextPart{}, ...]}}})` returns `{:error, :structured_content}`
- Integration: `ALLM.generate(engine, req) |> ALLM.unwrap()` against a Fake engine returns `{:ok, "scripted text"}`

#### 21.4 Implementation Checklist

- [ ] `lib/allm.ex`: `unwrap/1` — 7-clause function head per §Behaviour & Type Contracts
- [ ] `@spec` + `@doc` with runnable doctest using Fake
- [ ] Document the error-tuple shapes explicitly in `@doc` (`{:non_stop_finish, atom}`, `:structured_content`, plus pass-through)
- [ ] Update the `ALLM` moduledoc's "When to reach for what" table with the unwrap row

#### 21.4 Verification

```bash
mix test test/allm/allm_unwrap_test.exs
mix test                                     # full suite
mix credo --strict lib/allm.ex
mix dialyzer
```

---

### Phase 21.5 — Documentation rollup (F3 docs, F7, F8, F9, F12, F13)

**Goal:** All remaining doc-only fixes. No `lib/` changes.

**Spec sections:** none (docs only).

#### 21.5 Test Plan (write first)

`scripts/audit_user_docs.exs` (existing) already gates banned tokens. Extend the guide-content tests in `test/guides/` if any exist; otherwise:

- `test/guides/getting_started_test.exs`: any existing doctest-style verification (e.g., the Fake snippet at line ~38) continues to pass after edits
- `test/allm/tool_test.exs`: `Code.fetch_docs/1` against `ALLM.Tool` shows the `:handler` typedoc body contains the substrings `:context`, `:session_id`, `:tool_call`, `:engine` (added in 21.1; this is a regression test)

#### 21.5 Implementation Checklist

- [ ] `guides/getting_started.md`: add "Handling responses — the three-clause pattern" section between "Hello, ALLM" and "Where do API keys come from?", with a worked example pattern-matching on `{:ok, %{finish_reason: :stop}}` / `{:ok, %{finish_reason: :error, metadata: %{error: e}}}` / `{:error, e}`, and a one-line mention of `ALLM.unwrap/1` as the short form
- [ ] `guides/getting_started.md` "Where do API keys come from?" section: add one sentence — "`%ALLM.Engine{}` has no `:api_key` field; keys resolve per-call via `opts[:api_key]` or via the `:allm, :keys` application config (see `ALLM.Keys`). An engine struct can be persisted to ETF/JSON safely."
- [ ] `guides/tools.md`: add "Handler context (arity-2)" subsection documenting the `:context | :session_id | :tool_call | :engine | :request_id` keys
- [ ] `guides/tools.md`: add "Adapter-call cadence" subsection — "Each tool-loop turn consumes TWO adapter calls: one for the assistant's tool-call request, and one for the post-tool-result assistant turn. Token bills scale with turn count × 2."
- [ ] `guides/tools.md`: add "Structured response after tool loop" subsection documenting `chat(engine, thread, response_format: schema, structured_finalize: true)` — the existing two-pass orchestration at `lib/allm/chat.ex:347-502`. Cite the `pass_1_halted` / `pass_1_response` observability metadata. Worked example end-to-end against Fake.
- [ ] `guides/fakes.md` (NEW): consolidated Fake testing guide — script entry vocabulary (every documented tag), `:usage` opt + the existing `{:usage, _}` script entry, `:record` opt, cursor disambiguation patterns, halt-cleanup observation. Replaces tribal knowledge currently spread across the Fake moduledoc.
- [ ] `lib/allm/image.ex`: NEW constructor `from_data_uri/1` that parses `data:<mime>;base64,<encoded>` into `%Image{source: {:base64, encoded}, mime_type: mime}`. Reject malformed URIs with `ArgumentError`; reject non-base64 transfer encodings (`data:image/png,...` URL-encoded form) likewise — closed support: `;base64,` only. `Image.to_data_uri/1`'s base64 fast-path then works correctly because the source is `{:base64, _}`, not `{:url, _}`.
- [ ] `lib/allm/image.ex`: extend `@moduledoc` source-variants table with one row for `{:base64, encoded}` originating from `from_data_uri/1`.
- [ ] `test/allm/image_test.exs` (MODIFY — 21.5): add tests for `from_data_uri/1` happy path, `ArgumentError` on missing `data:` prefix, `ArgumentError` on missing `;base64,` segment, round-trip via `to_data_uri/1` returning a `data:` URI equal to the original.
- [ ] `guides/vision.md`: document `ALLM.Image.from_data_uri/1` as the right constructor for callers holding `data:image/png;base64,...` strings. Replace any prior claim that `from_url/1` accepts data-URIs with a redirect to `from_data_uri/1`.
- [ ] `CHANGELOG.md`: v0.3.0 entry already exists at lines 20-47 with a per-feature breakdown — no edit needed. v0.3.1 "Documentation rebuild" is correct. The v0.4.0 entry lands in 21.6, not 21.5. F8's "CHANGELOG essentially empty" feedback was traced against the brief synthesis, not the actual CHANGELOG — leave existing entries alone

#### 21.5 Verification

```bash
mix run scripts/audit_user_docs.exs           # banned-token gate
mix test test/guides/                          # if guide tests exist
mix test                                       # full suite
```

---

### Phase 21.6 — Release v0.4.0 (CHANGELOG + version bump)

**Goal:** Cut v0.4.0 with the breaking change (tool schema normalization for atom keys + `Validate.message/1` error shape) gated behind the version bump.

**Spec sections:** none.

#### 21.6 Implementation Checklist

- [ ] `CHANGELOG.md`: add `## [REL] v0.4.0 — Integration-feedback rollup` entry with:
  - **Breaking changes** (1): `ALLM.Tool.new/1` now normalizes atom-keyed `:schema` maps to string keys (see Breaking Changes Summary). `Validate.message/1` carries new `:metadata` + `:message` fields but `errors` list shape is UNCHANGED — non-breaking.
  - **Additions** (10): `Fake :usage` (incl. streaming via `:message_completed.metadata.usage`), `Fake :record`, `ALLM.Sandbox.set_engine/1`/`get_engine/0`/`with_engine/2`/`unset_engine/0`, `ALLM.unwrap/1`, `ALLM.Image.from_data_uri/1`, `Tool :handler @typedoc` keys, `ValidationError.metadata.invalid_part_type` + human-readable `:message`, `ALLM.JsonSchema.normalize/1` (extracted helper now applied to `ALLM.json_schema/3` schemas too), six guide updates (incl. NEW `fakes.md`)
- [ ] `mix.exs`: bump `@version` from `"0.3.1"` to `"0.4.0"` via `mix run scripts/release.exs minor` (per CLAUDE.md — never hand-edit @version)
- [ ] Confirm `mix.exs` `package[:files]` includes `CHANGELOG.md` (per CLAUDE.md invariant)
- [ ] `mix hex.build` and `tar -tzf <package>.tar | grep CHANGELOG` — ensure CHANGELOG is in the source tarball

#### 21.6 Verification

```bash
mix run scripts/release.exs minor              # bumps version, runs quality gates, opens hex.publish
git diff mix.exs CHANGELOG.md                  # final review pre-publish
```

---

## Test Plan (cross-phase)

- **Unit tests** — every new public function (`ALLM.Sandbox.*`, `ALLM.unwrap/1`, `ALLM.Image.from_data_uri/1`) has happy-path + error-path tests. The `Validate.message/1` change keeps the existing field-error atom assertions intact (no test edits) and adds new `metadata.invalid_part_type` assertions
- **Behaviour conformance** — `ALLM.Providers.Fake` continues to pass the existing `ALLM.Test.AdapterConformance` and `ALLM.Test.StreamAdapterConformance` suites; the new `:usage` and `:record` opts are additive and don't touch the conformance contract
- **Integration tests** — `ALLM.Sandbox.set_engine/1` is verified across `Task.async_stream/3` workers driving real `ALLM.generate/3` calls; streaming Fake `:usage` is verified via `StreamCollector.collect/1` producing a `%Response{usage: ...}`
- **Property tests** — `ALLM.unwrap/1` over `StreamData`-generated `{:ok, %Response{}} | {:error, _}` values returns one of the two documented shapes
- **Doctests** — every new public function has a runnable doctest using Fake; the doctest is part of the test corpus and runs under `mix test`
- **Serializability tests** — the new `:usage` opt produces a Response whose `:usage` field round-trips through ETF + JSON (covered in 21.2)
- **Stream-equivalence tests** — Phase 21 does not touch the streaming reducer contract; existing equivalence properties continue to pass
- **`async: true` isolation** — `test/allm/sandbox_test.exs` is `async: true` and explicitly tests two concurrent registrations never colliding

**Coverage threshold:** 80% global per `mix.exs`; new code lands at ≥90%. The new modules are small (`lib/allm/sandbox.ex` ~80 LOC, two new facade functions ~50 LOC total) so 90% is easily reached.

---

## Error Contract

No new error modules. Existing modules extended:

| Function | Error reason | Recovery guidance |
|----------|--------------|--------------------|
| `Validate.message/1` | `{:content, {:invalid_part_type, expected: list(module), got: module}}` | Caller passed a raw map or struct other than `%TextPart{}`/`%ImagePart{}`; wrap content in the documented part structs. |
| `ALLM.unwrap/1` | `{:non_stop_finish, atom}` | The response finished with a non-stop reason (`:length`, `:tool_calls`, `:content_filter`, `:other`); caller should inspect the underlying `%Response{}` instead of using `unwrap/1`. |
| `ALLM.unwrap/1` | `:structured_content` | The response's `:message.content` is a list (vision / structured parts); caller should access `:message` directly. |
| `ALLM.Image.from_data_uri/1` | `ArgumentError` | Input is not a `data:<mime>;base64,<encoded>` string; caller should use `from_url/1` for `http(s)://...` or `from_base64/2` for already-decoded payloads. |
| `ALLM.Providers.Fake.generate/2` (with `:record`) | `ArgumentError` | Recording pid is dead; pass a live pid (commonly `self()` in tests). |

### Field-error atom vocabulary (extension)

The 21.1 Validate change extends ONE existing row:

| Field path | Reason atom | Hard-reject? | Fires when |
|------------|-------------|--------------|------------|
| `[:content]` | `{:invalid_part_type, expected: list(module), got: module}` | no | content list contains a non-`%TextPart{}` / non-`%ImagePart{}` element. **Pre-21.1**: bare atom `:invalid_part_type`. **Post-21.1**: 3-tuple with detail. |

No new closed-enum atoms added — `:invalid_part_type` is preserved as the first element of the structured tuple.

---

## Streaming & Backpressure

Phase 21 does not modify any streaming code path. The Fake `:usage` opt's `{:usage, %{usage: _}}` event is interleaved into the existing `closing_events/1` sequence (between `:text_completed` and `:message_completed`); cleanup (`after_fun`) is unchanged. The new `:record` opt's `send/2` fires once at stream-open time (before `Stream.resource/3`'s `start_fun`), so it doesn't affect backpressure semantics. The 500ms cleanup-on-halt bound is unaffected.

---

## Definition of Done

- [ ] All 6 sub-phases marked `Completed`
- [ ] `mix test` zero failures, zero `unused_var` warnings, coverage ≥80% globally and ≥90% on new code
- [ ] `mix credo --strict` zero issues on changed files
- [ ] `mix dialyzer` zero new warnings
- [ ] `mix format --check-formatted` passes
- [ ] Every new public function has `@spec` + `@doc` + runnable doctest (`ALLM.Sandbox.set_engine/1`, `ALLM.Sandbox.get_engine/0`, `ALLM.Sandbox.with_engine/2`, `ALLM.Sandbox.unset_engine/0`, `ALLM.unwrap/1`, `ALLM.Image.from_data_uri/1`)
- [ ] Behaviour conformance: `ALLM.Test.AdapterConformance` + `ALLM.Test.StreamAdapterConformance` continue to pass for Fake
- [ ] Layer A serializability: a `%Response{}` produced by Fake with `usage:` set round-trips through ETF + JSON
- [ ] CHANGELOG.md v0.4.0 entry lands with both breaking changes flagged
- [ ] `mix.exs` `@version` bumped via `scripts/release.exs minor` (NOT hand-edited per CLAUDE.md)
- [ ] `tar -tzf` of the built Hex tarball confirms `CHANGELOG.md` is shipped
- [ ] `examples/` snapshot files NOT modified (Phase 21 does not touch examples — out-of-scope per CLAUDE.md's snapshot-deferral invariant)

---

## Breaking Changes Summary

Phase 21 ships **one** minor breaking change, gated behind v0.4.0:

1. **`ALLM.Tool.new/1` normalizes atom-keyed `:schema` maps to string keys.** Pre-21.1 callers passing atom-keyed schemas got non-deterministic adapter wire shapes; post-21.1 the normalization is deterministic. Callers who depended on `%Tool{}.schema` having atom keys will see string keys instead. Migration: most callers were already passing string keys (per `ALLM.json_schema/3`'s convention); atom-key callers should re-test schema-dependent assertions. (Phase 21 also extracts the normalization helper to `ALLM.JsonSchema.normalize/1` so `ALLM.json_schema/3` applies the same normalization to response-format schemas — purely additive, but worth noting in the CHANGELOG under additions.)

`Validate.message/1`'s error shape is **unchanged** — the `:invalid_part_type` field-error remains the bare atom `{:content, :invalid_part_type}` in the `errors` list. The structured detail (`expected: [...], got: <module>`) rides on `ValidationError.metadata.invalid_part_type` (additive), and the human-readable rendering rides on `ValidationError.message` (additive). The `/ddesign` review walked back an earlier 3-tuple migration after the typespec-vs-test conflict at `lib/allm/error/validation_error.ex` was identified — see the Type Contracts block at line 329. Existing callers pattern-matching `{:content, :invalid_part_type}` continue to match.

No deprecation cycle — v0.x semver allows minor breaks per CLAUDE.md's stability statement.
