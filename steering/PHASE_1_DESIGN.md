# Phase 1: Layer A Hardening — Design Document

> **Goal:** Finish the Layer A surface so every later phase can build, validate, and serialize plain-data values without re-hardening the data layer.
> **Outcome:** Every Layer A struct has helpers and `@spec`s; `ALLM.Event` has an `event?/1` guard and variant constructors; a first-class `ALLM.Error.*` struct family exists; an `ALLM.Validate` module covers request/message/tool/thread/session inputs; `ALLM.Serializer` provides `Jason` round-tripping; the `lib/allm.ex` facade has doctests on every public constructor. All changes are covered by unit + property tests with serializability round-trips, and `mix test`, `mix credo --strict`, `mix dialyzer`, and `mix format --check-formatted` pass clean.
> **Spec sections:** §4, §5.1–§5.10, §8, §9, §16, §20, §33
> **Layers touched:** A (Serializable data only). No Layer B/C/D surface is added or modified.
> **Phasing doc:** [`PROJECT_PHASING.md`](PROJECT_PHASING.md) Phase 1.

## Status

| Sub-phase | Description | Layer | Status |
|-----------|-------------|-------|--------|
| 1.1 | `ALLM.Error.*` struct hierarchy (EngineError, AdapterError, StreamError, ValidationError, ToolError) with `Exception` impl | A | Completed |
| 1.2 | Layer A struct helpers (`.new/1`, accessors) + full `@spec`s + `@doc`s | A | Completed |
| 1.3 | `ALLM.Event.event?/1` guard + variant constructor helpers | A | Completed |
| 1.4 | `ALLM.Validate` module with five validator functions | A | Completed |
| 1.5 | `ALLM.Serializer` — `Jason` round-trip via tagged-encoding pattern | A | Completed |
| 1.6 | `lib/allm.ex` facade: `@doc` + runnable doctests on every public constructor | A | Completed |

**Overall Progress:** 6/6 sub-phases complete

## Overview

Phase 1 hardens everything in Layer A so that Phases 2+ can assume well-formed data, structured errors, and guaranteed round-trippability without re-litigating the data layer. The scaffolding today has every Layer A struct defined (except `ALLM.Thread`, which is ~70% implemented with full helpers) but most modules are shallow: no `.new/1` constructors on `Message`, `ToolCall`, `Response`, `StepResult`, `ChatResult`, or `Usage`; no `event?/1` guard or variant constructors on `ALLM.Event`; no validation module at all; no error struct hierarchy; and no tested serialization path through `Jason`. The top-level facade `lib/allm.ex` has the spec §4 constructors (`system/1`, `user/1`, `assistant/1`, `tool_result/2`, `tool/1`, `json_schema/3`, `request/2`) but lacks `@doc` strings and doctests, so there is no executable documentation.

**This design refines spec §20 by introducing a struct-based error hierarchy.** Spec §20 describes the error model using plain atoms (`:missing_adapter`, `:invalid_request`) and tuples (`{:adapter_error, term()}`, `{:tool_error, name, reason}`) — it does not mandate a struct hierarchy. Per `agent-spec/DESIGN.md §7`, every public function that can fail must return `{:error, %ALLM.Error.XError{}}` where `XError` is a struct with `:reason`, `:message`, `:provider`, `:cause` at minimum. This design reconciles the two by: (a) introducing five `ALLM.Error.*` structs whose `:reason` fields carry the exact atoms named in §20; (b) preserving the spec's `:reason` atom taxonomy verbatim so spec citations remain stable; (c) documenting that legacy `{:error, atom}` / `{:error, {tag, _}}` return shapes are not used — everything uses the struct form. No spec amendment is required because §20 leaves the shape open; the struct form is a *refinement* within the spec's taxonomy, not a contradiction of it.

### Deliverables

- **New modules**: `ALLM.Error.EngineError`, `ALLM.Error.AdapterError`, `ALLM.Error.StreamError`, `ALLM.Error.ValidationError`, `ALLM.Error.ToolError` (one file each under `lib/allm/error/`), `ALLM.Validate`, `ALLM.Serializer`.
- **Modified modules**: `ALLM.Message`, `ALLM.ToolCall`, `ALLM.Response`, `ALLM.StepResult`, `ALLM.ChatResult`, `ALLM.Usage` (add `.new/1` constructors, accessors where clarifying, full `@spec` + `@doc`), `ALLM.Event` (add `event?/1` guard + variant constructor helpers), `ALLM.Tool` (add missing `@doc` + doctest; `.new/1` already exists), `ALLM.Request` (add `.new/1` + doctest; validation lives in `ALLM.Validate`), `ALLM.Thread` (add missing `@doc` + doctests; helpers already exist), `lib/allm.ex` (add `@doc` + doctests on all seven public constructors).
- **New tests**: one `_test.exs` per source file, plus property tests for `ALLM.Event` variants, every Layer A struct's serializability round-trip (`:erlang.term_to_binary/1` + `Jason`), and `ALLM.Validate` against known-good and known-bad fixtures.
- **StreamData**: added as a `:test`-only dep to `mix.exs` for property-style tests.

### Spec coverage

- **§4** — public facade constructors get `@doc`/doctest (1.6)
- **§5.1** Message, **§5.2** Tool, **§5.3** ToolCall, **§5.4** Request, **§5.5** Response, **§5.6** Thread, **§5.8** StepResult, **§5.9** ChatResult, **§5.9a** Usage — `.new/1` + `@spec` + `@doc` + serializability tests (1.2)
- **§8** Event protocol — `event?/1` guard + variant constructors + property tests (1.3)
- **§9** request building — `ALLM.request/2` doctest + `ALLM.json_schema/3` doctest (1.6)
- **§16** Validation — `ALLM.Validate.{request,message,tool,thread,session}/1` (1.4)
- **§20** Error model — refined into `ALLM.Error.*` struct hierarchy (1.1)
- **§33** Non-goals — `ValidationError` rejects vision content parts with `reason: :vision_not_in_v0_2` when encountered in messages (1.4)

### Layer demonstration

Phase 1 is entirely Layer A. A user consuming this phase writes **only serializable data** — no engine, no adapter, no execution. The layer demonstration is a single snippet a user can run in `iex -S mix` after Phase 1 ships without any other phases landing:

```elixir
# Layer A: build a serializable Request value, round-trip it through JSON.
messages = [
  ALLM.system("You are helpful."),
  ALLM.user("Name three primes.")
]

req = ALLM.request(messages,
  model: "fake:gpt-test",
  response_format: ALLM.json_schema("primes", %{"type" => "array"})
)

:ok = ALLM.Validate.request(req)

json = ALLM.Serializer.to_json!(req)
{:ok, ^req} = ALLM.Serializer.from_json(json, as: ALLM.Request)
```

No other layer is touched. This is the load-bearing proof that Layer A is self-contained: the user builds, validates, serializes, and re-hydrates a request with zero runtime dependencies.

### Prerequisites

None. This is the first phase in the v0.2 build order (spec §28).

### Out of scope

- **Engine API / key resolution** — Phase 2 territory (§6). Phase 1 does not touch `ALLM.Engine` beyond leaving its struct unchanged.
- **Behaviours, default implementations, conformance harness** — Phase 3 (§7, §18).
- **`ALLM.Providers.Fake`** — Phase 4 (§31). Phase 1 does not need a test adapter because no execution path is exercised; all tests are pure data.
- **Stream runner, collectors, execution functions** — Phases 5–7.
- **Session orchestration** — Phase 8 (§11). `ALLM.Session` struct already exists and is covered by round-trip tests, but no new Session API lands in Phase 1.
- **Telemetry, retries, capability pre-flight** — Phase 9.
- **Real provider adapters** — Phases 10–11.
- **Vision content parts** — explicitly rejected per §33 non-goals; `Validate.message/1` returns `{:error, %ValidationError{reason: :vision_not_in_v0_2}}` when image parts appear in `:content`.
- **Middleware field on Engine** — stays `[]` per §29; Phase 1 does not add serialization tests for non-empty middleware.

### Non-obvious decisions

1. **Error structs are the only shape used** — no tuple-style errors (`{:error, :invalid_request}`, `{:error, {:adapter_error, _}}`) appear anywhere in Layer A public returns. The spec §20 atom taxonomy is preserved as the `:reason` field on the structs, so spec citations stay meaningful. `Docs target: CHANGELOG entry only` (library-wide philosophy, not a single module).
2. **`Validate.*/1` returns `{:error, %ValidationError{}}`**, not `{:error, [term()]}` as the spec sketches in §16. The `errors: [term()]` list from §16 becomes a field on the `ValidationError` struct so the error type stays uniform with the rest of the error contract. `Docs target: @moduledoc ALLM.Validate`.
3. **Tagged JSON encoding** — `ALLM.Serializer` wraps every struct's JSON form in `{"__type__": "ALLM.Message", "data": {...}}` so the decoder can re-hydrate without the caller knowing the target type at decode time. Alternatives (caller supplies `as:` hint; struct types inferred from shape) are less ergonomic; tagged encoding is the standard pattern in Elixir libs like Jetstream and works well with nested values (a `ChatResult` contains a `Thread` contains `Message`s — tagged encoding handles this recursively with no special cases). `Docs target: @moduledoc ALLM.Serializer`.
4. **`Event.event?/1` is a function, not a macro guard** — Elixir's guards (`defguard`) are useful but restrict pattern matching to guard-allowed expressions. `event?/1` is a plain function: it checks `is_tuple(t) and tuple_size(t) == 2 and elem(t, 0) in @tags`, and for every tag **except** `:raw_chunk` and `:error` (whose payloads are opaque per §8), additionally asserts `is_map(elem(t, 1))`. This means `event?({:text_delta, "not a map"}) == false` while `event?({:error, %RuntimeError{}}) == true` — matching the spec's closed-union shape and the payload contract. `Docs target: @doc ALLM.Event.event?/1`.
5. **`StreamData` is the chosen property-test library** — `:stream_data` is already a common Elixir choice, well-maintained, and integrates with ExUnit. No alternative is considered. `Docs target: internal — no user-facing docs needed` (test-only infrastructure).
6. **Error structs implement `Exception`** via `defexception` so `raise %AdapterError{...}` and `try/rescue` work. This is a small addition with outsized ergonomics for users writing tool handlers. `Docs target: @moduledoc each ALLM.Error.*` (already landed in Batch 1).
7. **`ALLM.request/2` does NOT call `Validate.request/1`**. Per spec §9 its signature is `@spec request([Message.t()], keyword()) :: Request.t()` — it returns the struct, not `{:ok | :error}`. Validation happens at the adapter boundary in Phase 5, not at construction. This keeps constructors composable and tests simple; `Validate.request/1` is a separate explicit step users can call when they need it. `Docs target: @doc ALLM.request/2` (user-facing — the caller must know validation is opt-in, lands in Sub-phase 1.6).
8. **`Session.context :: map()` is permissive; the caller owns serializability.** `context` (spec §5.7) is a free-form map the library threads through to tool handlers (§5.2 arity-2 form). The library does **not** validate or walk it — a user stuffing `DateTime`, `Decimal`, an `Ecto.Repo` reference, or a callback module is legitimate. A user stuffing a PID, ref, or fun violates Layer A's serializability invariant; the failure mode is `:erlang.term_to_binary/1` raising `badarg` at persist time, which is an acceptable blast pattern because the caller controls what goes in. This is documented in `ALLM.Session`'s `@moduledoc` as a hard contract: the library guarantees round-trippability for values the caller knows are serializable, nothing more. Tightening this is a v0.3 hardening candidate (typed `ALLM.serializable()` recursive type + validator walk in `Validate.session/1`) but is out of scope for v0.2. `Docs target: @moduledoc ALLM.Session` (already landed in Batch 2).
9. **Spec §20 atoms `:tool_not_found`, `:no_handler`, and `:max_turns_exceeded` — where they land.** §20 names three atoms that do not appear verbatim in any sub-phase 1.1 `reason` enum. Their mapping is:
    - `:tool_not_found` → `ToolError.reason: :not_found`. Same meaning, renamed because the module name already carries the "tool" context. Preserved behind the rename; see `ToolError`'s `@moduledoc` for a cross-reference comment.
    - `:no_handler` → `ToolError.reason: :not_found`. The §20 atom and `:tool_not_found` are semantically identical ("the tool was called but no handler is registered"). Collapsed into the single `:not_found` reason so callers dispatch on one atom instead of two.
    - `:max_turns_exceeded` → **not** an error. This is a `ChatResult.halted_reason` value (landing in sub-phase 1.2 as `:max_turns`), not an `ALLM.Error.*` reason. Hitting `max_turns` is a successful-but-halted completion, not a failure; the chat loop returns `{:ok, %ChatResult{halted_reason: :max_turns}}`, not `{:error, _}`. No code path should ever construct an error struct with this reason, so adding it to a `reason` enum would be dead weight.

   `Docs target: @moduledoc ALLM.Error.ToolError` (rename cross-reference already landed in Batch 1); `CHANGELOG entry only` for the `:max_turns_exceeded` → `:max_turns` distinction.

## Behaviour & Type Contracts

### ALLM.Error.EngineError

```elixir
# Layer A — serializable (no PIDs, refs, funs, or raw API keys)
defmodule ALLM.Error.EngineError do
  @moduledoc "Errors raised by engine-level operations before any adapter call."

  @type reason ::
          :missing_adapter
          | :missing_stream_adapter
          | :missing_model
          | :missing_key
          | :unknown_tool
          | :invalid_engine
          | :unsupported_response_format

  @type t :: %__MODULE__{
          reason: reason(),
          message: String.t(),
          provider: atom() | nil,
          cause: term() | nil,
          metadata: map()
        }

  defexception [:reason, :message, :provider, :cause, metadata: %{}]

  @spec new(reason(), keyword()) :: t()
  def new(reason, opts \\ [])
  # If opts[:message] is omitted, default to "engine error: #{reason}".

  @impl Exception
  def message(%__MODULE__{message: m}) when is_binary(m), do: m
  def message(%__MODULE__{reason: r}), do: "engine error: #{r}"
end
```

### ALLM.Error.AdapterError

```elixir
defmodule ALLM.Error.AdapterError do
  @moduledoc "Errors returned by `ALLM.Adapter` / `ALLM.StreamAdapter` implementations."

  @type reason ::
          :rate_limited
          | :authentication_failed
          | :invalid_request
          | :provider_unavailable
          | :context_length_exceeded
          | :content_filter
          | :timeout
          | :network_error
          | :malformed_response
          | :unsupported_feature
          | :unknown

  @type t :: %__MODULE__{
          reason: reason(),
          message: String.t(),
          provider: atom() | nil,
          status: non_neg_integer() | nil,   # HTTP status when applicable
          retry_after_ms: non_neg_integer() | nil,
          request_id: String.t() | nil,
          cause: term() | nil,
          metadata: map()
        }

  defexception [
    :reason, :message, :provider, :status,
    :retry_after_ms, :request_id, :cause,
    metadata: %{}
  ]

  @spec new(reason(), keyword()) :: t()
  def new(reason, opts \\ [])
  # If opts[:message] is omitted, default to
  #   "adapter error: #{reason}" <> provider-suffix when opts[:provider] set.

  @impl Exception
  def message(%__MODULE__{message: m}) when is_binary(m), do: m
  def message(%__MODULE__{reason: r, provider: nil}), do: "adapter error: #{r}"
  def message(%__MODULE__{reason: r, provider: p}), do: "adapter error (#{p}): #{r}"
end
```

### ALLM.Error.StreamError

```elixir
defmodule ALLM.Error.StreamError do
  @moduledoc "Errors that surface mid-stream."

  @type reason ::
          :adapter_error      # wraps an underlying %AdapterError{}
          | :cancelled        # consumer halted the stream
          | :timeout          # stream_timeout exceeded
          | :malformed_event  # adapter yielded a shape Event.event?/1 rejects
          | :unknown

  @type t :: %__MODULE__{
          reason: reason(),
          message: String.t(),
          provider: atom() | nil,
          event_index: non_neg_integer() | nil,   # how many events were emitted before the error
          cause: term() | nil,                    # typically %AdapterError{} or the malformed term
          metadata: map()
        }

  defexception [
    :reason, :message, :provider, :event_index, :cause,
    metadata: %{}
  ]

  @spec new(reason(), keyword()) :: t()
  def new(reason, opts \\ [])
  # If opts[:message] is omitted, default to "stream error: #{reason}".

  @impl Exception
  def message(%__MODULE__{message: m}) when is_binary(m), do: m
  def message(%__MODULE__{reason: r}), do: "stream error: #{r}"
end
```

### ALLM.Error.ValidationError

```elixir
defmodule ALLM.Error.ValidationError do
  @moduledoc "Errors returned by `ALLM.Validate` functions."

  @type field_error :: {field :: atom() | [atom()], reason :: atom()}

  @type reason ::
          :invalid_request
          | :invalid_message
          | :invalid_tool
          | :invalid_thread
          | :invalid_session
          | :vision_not_in_v0_2

  @type t :: %__MODULE__{
          reason: reason(),
          message: String.t(),
          errors: [field_error()],
          cause: term() | nil,
          metadata: map()
        }

  defexception [:reason, :message, :cause, errors: [], metadata: %{}]

  @spec new(reason(), [field_error()], keyword()) :: t()
  def new(reason, errors, opts \\ [])
  # If opts[:message] is omitted, default to
  #   "validation failed: #{reason} (#{length(errors)} error(s))".

  @impl Exception
  def message(%__MODULE__{message: m}) when is_binary(m), do: m
  def message(%__MODULE__{reason: r, errors: errs}),
    do: "validation failed: #{r} (#{length(errs)} error(s))"
end
```

### ALLM.Error.ToolError

```elixir
defmodule ALLM.Error.ToolError do
  @moduledoc "Errors from tool handler execution."

  @type reason ::
          :handler_raised       # handler raised an exception
          | :handler_exit       # handler process exited
          | :timeout            # tool_timeout exceeded
          | :invalid_return     # handler returned a shape outside the documented union
          | :not_found          # tool name not declared on the engine
          | :encoding_failed    # ToolResultEncoder could not encode the result

  @type t :: %__MODULE__{
          reason: reason(),
          message: String.t(),
          tool_name: String.t() | nil,
          tool_call_id: String.t() | nil,
          cause: term() | nil,                  # the raise/exit reason or the invalid term
          metadata: map()
        }

  defexception [
    :reason, :message, :tool_name, :tool_call_id, :cause,
    metadata: %{}
  ]

  @spec new(reason(), keyword()) :: t()
  def new(reason, opts \\ [])
  # If opts[:message] is omitted, default to
  #   "tool error: #{reason}" <> tool-name suffix when opts[:tool_name] set.

  @impl Exception
  def message(%__MODULE__{message: m}) when is_binary(m), do: m
  def message(%__MODULE__{reason: r, tool_name: nil}), do: "tool error: #{r}"
  def message(%__MODULE__{reason: r, tool_name: name}), do: "tool error (#{name}): #{r}"
end
```

### ALLM.Event (augmented)

```elixir
# Layer A — existing @type t :: {...} closed union stays as-is.
# This phase adds the predicate and variant constructors.

defmodule ALLM.Event do
  @tags ~w(
    message_started text_delta text_completed
    tool_call_started tool_call_delta tool_call_completed
    tool_execution_started tool_execution_completed tool_result_encoded
    ask_user_requested tool_halt
    message_completed step_completed chat_completed
    raw_chunk error
  )a

  @spec event?(term()) :: boolean()
  def event?(value)

  # Variant constructors — one per tag. Each returns a value of type t().
  # These exist for the stream runner in later phases; Phase 1 ships
  # constructors + tests, no consumer yet.

  @spec text_delta(String.t() | nil, String.t()) :: t()
  def text_delta(id, delta)

  @spec tool_call_started(String.t(), String.t()) :: t()
  def tool_call_started(id, name)

  # ... one per variant (14 total, excluding :raw_chunk and :error which take
  # opaque payloads and use plain tuple construction in-line).

  @spec tags() :: [atom()]
  def tags, do: @tags
end
```

### ALLM.Validate

```elixir
# Layer A — pure validators, no side effects, no network.
defmodule ALLM.Validate do
  alias ALLM.Error.ValidationError
  alias ALLM.{Message, Request, Session, Thread, Tool}

  @spec request(Request.t()) :: :ok | {:error, ValidationError.t()}
  def request(request)

  @spec message(Message.t()) :: :ok | {:error, ValidationError.t()}
  def message(message)

  @spec tool(Tool.t()) :: :ok | {:error, ValidationError.t()}
  def tool(tool)

  @spec thread(Thread.t()) :: :ok | {:error, ValidationError.t()}
  def thread(thread)

  @spec session(Session.t()) :: :ok | {:error, ValidationError.t()}
  def session(session)
end
```

**Rules (minimum; additional rules from §16 plus derived from §5):**

- `request/1`: messages non-empty; every message passes `message/1`; every tool passes `tool/1`; tool names unique within `request.tools`; `temperature` in `[0.0, 2.0]` when set; `max_tokens > 0` when set; `response_format` is `nil`, `:text`, `%{type: :json_object}`, `%{type: :json_schema, name: _, schema: _, strict: _}`, **or any other map (escape-hatch per §5.4 — adapters may reject later with `:unsupported_response_format` at call time)**; non-map non-atom values → `errors: [{:response_format, :invalid_shape}]`; if `structured_finalize: true` then `response_format` is a `:json_schema`.
- `message/1`: `role` in `[:system, :user, :assistant, :tool]`; `content` is a `String.t()` or a list of map structs (text/tool parts only — image parts rejected with `:vision_not_in_v0_2`); `role: :tool` requires non-nil `tool_call_id`. **Image-part detection must accept both atom-keyed and string-keyed maps** — `%{type: "image", ...}`, `%{type: "image_url", ...}`, `%{"type" => "image", ...}`, `%{"type" => "image_url", ...}`. Content parts cross the Layer A serialization boundary: user code typically constructs atom-keyed maps, but `ALLM.Serializer.from_json/2` (sub-phase 1.5) produces string-keyed maps on the return path; a vision part that slips in through a JSON round-trip must be caught on the way back, not just on the way in. Tests cover both key styles for both image types.
- `tool/1`: `name` is a non-empty string matching `~r/^[A-Za-z0-9_-]{1,64}$/`; `description` is a string; `schema` is a map (providers differ on whether the top level must be `"type" => "object"`, so no top-level shape is required by the validator — a non-map `schema` → `errors: [{:schema, :not_a_map}]`).
- `thread/1`: every message passes `message/1`; errors carry path `[:messages, index, :field]` so callers can locate the offending message.
- `session/1`: `status` in `[:idle, :awaiting_user, :awaiting_tools, :completed, :error]`; thread passes `thread/1`; `:awaiting_user` implies non-nil `pending_question`; `:awaiting_tools` implies non-empty `pending_tool_calls`; `:error` implies `metadata[:error]` is non-nil (per spec §5.7 "unrecoverable adapter/tool error; see `metadata.error`"); missing `metadata[:error]` when `status: :error` → `errors: [{:metadata, :error_required_for_status}]`.

### ALLM.Serializer

```elixir
# Layer A — tagged JSON encoding + decoding.
defmodule ALLM.Serializer do
  @type tagged_json :: map()   # %{"__type__" => "ALLM.Message", "data" => %{...}}

  @spec to_json!(struct()) :: String.t()
  def to_json!(value)

  @spec to_iodata!(struct()) :: iodata()
  def to_iodata!(value)

  @spec from_json(String.t(), keyword()) ::
          {:ok, struct()} | {:error, ALLM.Error.ValidationError.t()}
  def from_json(json, opts \\ [])

  # Called by per-struct `Jason.Encoder` impls; emits the tagged wrapper.
  @spec encode_tagged(struct(), Jason.Encode.opts()) :: iodata()
  def encode_tagged(value, opts)

  # Opts on from_json/2:
  #   :as — module atom; required when the top-level JSON is not tagged (escape
  #         hatch for third-party JSON → ALLM struct).
end
```

**Encoding pattern.** Every Layer A struct file ends with an explicit `defimpl` delegating to the shared helper (not a `@derive` or central macro, which prevents `Jason` from resolving the protocol at compile time):

```elixir
# at the bottom of lib/allm/message.ex (and every other Layer A struct file)
defimpl Jason.Encoder, for: ALLM.Message do
  def encode(value, opts), do: ALLM.Serializer.encode_tagged(value, opts)
end
```

`encode_tagged/2` builds `%{"__type__" => inspect(mod), "data" => Map.from_struct(value)}` and hands it to `Jason.Encode.map/2`. The encoder emits **all** fields, including `nil` values, so the decoder sees the complete struct shape — do not use `@derive {Jason.Encoder, only: [...]}` which can silently drop nils and break round-trip equality.

**Decoding pattern.** `from_json/2` decodes the JSON with `Jason.decode/1`, then recursively re-hydrates. Hydration is dispatched per `__type__`: each Layer A struct module exposes a private-ish `__from_tagged__/1` helper that knows which of its fields carry atoms, which carry nested structs, and which carry plain data. Atom fields are restored via `String.to_existing_atom/1` (safe because every atom in Layer A types — `:system`, `:user`, `:assistant`, `:tool`, `:stop`, `:length`, `:tool_calls`, `:content_filter`, `:error`, `:other`, `:auto`, `:none`, `:required`, `:text`, `:json_object`, `:json_schema`, every `ALLM.Event` tag, every `ALLM.Session.status`, every `ALLM.Error.*.reason`, `:idle`, `:awaiting_user`, `:awaiting_tools`, `:completed` — is compiled into the BEAM as a struct field type or literal). Map field keys (like `Message.name`, `tool_result_id`) stay as binaries per the struct's `@type`. Struct field names containing `?` (e.g., `StepResult.done?`) are handled because `:done?` is a legal atom and compiled into the BEAM as a struct field; `String.to_existing_atom("done?")` resolves it.

Nested structs decode first: a `ChatResult` containing a `Thread` of `Message`s walks in this order — decode outer JSON → recurse into `"thread"` (tagged `ALLM.Thread`) → recurse into `"messages"` list (each tagged `ALLM.Message`) → restore atoms on each → rebuild outward. Unknown `"__type__"` values are returned as plain maps so forward-compat with future struct types is graceful.

**Atom discipline.** Because decode uses `String.to_existing_atom/1`, every atom that can legally appear in Layer A data must already be loaded when decode runs. This is guaranteed in practice because (a) the Elixir compiler places every struct-field atom in the BEAM, (b) `Application.ensure_all_started(:allm)` loads all Layer A modules before any user code runs. `ArgumentError` on decode is a test bug, not a runtime risk.

### Layer A Struct Helpers

Every Layer A struct gains at minimum `.new/1` (struct-building constructor) with validation of required fields. Where an accessor clarifies the API (e.g., `Response.text/1` returns `output_text || content_of(message)`), it's added — but accessors are not added for simple field reads.

```elixir
# Message
@spec new(keyword()) :: t()   # Requires :role, :content; optional :name, :tool_call_id, :metadata
def new(opts)

# ToolCall
@spec new(keyword()) :: t()   # Requires :id, :name, :arguments
def new(opts)

# Response
@spec new(keyword()) :: t()
def new(opts)

@spec text(t()) :: String.t() | nil
def text(%__MODULE__{output_text: t}) when is_binary(t), do: t
def text(%__MODULE__{message: %ALLM.Message{content: c}}) when is_binary(c), do: c
def text(%__MODULE__{}), do: nil

# StepResult
@spec new(keyword()) :: t()
def new(opts)

# ChatResult
@spec new(keyword()) :: t()
def new(opts)
@spec halted?(t()) :: boolean()
def halted?(result)                    # halted_reason != :completed

# Usage
@spec new(keyword()) :: t()
def new(opts)
@spec total_tokens(t()) :: non_neg_integer() | nil
def total_tokens(usage)                # total_tokens field, or input + output when nil

# Request (already exists; add .new/1 which is identical to ALLM.request/2)
@spec new([Message.t()], keyword()) :: t()
def new(messages, opts \\ [])

# Tool (.new/1 already exists — add @doc + doctest only)

# Thread (all helpers already exist — add @doc + doctests only)
```

**Invariants preserved by every `.new/1`:**

1. The returned value is a `%__MODULE__{}` struct — not a map.
2. Every field in the `@type t` is either explicitly set by the caller or has a default from `defstruct`.
3. `.new/1` never calls `ALLM.Validate.*/1`; callers opt in to validation explicitly.

## Module Tree

Each Layer A struct file gets a trailing `defimpl Jason.Encoder, for: __MODULE__ do ... end` block delegating to `ALLM.Serializer.encode_tagged/2`, and a `__from_tagged__/1` private-ish hydrator. The `(MODIFY)` notes below include those additions.

```
lib/allm.ex                              (MODIFY — @doc + doctests on 7 constructors; thin wrapper to Request.new / Tool.new)

lib/allm/
├── message.ex                           (MODIFY — add .new/1 + @doc + @spec + defimpl Jason.Encoder + __from_tagged__/1)
├── tool.ex                              (MODIFY — @doc + doctest; .new/1 already exists; add defimpl + __from_tagged__/1)
├── tool_call.ex                         (MODIFY — add .new/1 + @doc + @spec + defimpl + __from_tagged__/1)
├── request.ex                           (MODIFY — add .new/2 + @doc + @spec + defimpl + __from_tagged__/1)
├── response.ex                          (MODIFY — add .new/1, .text/1 + @doc + @spec + defimpl + __from_tagged__/1)
├── step_result.ex                       (MODIFY — add .new/1 + @doc + @spec + defimpl + __from_tagged__/1)
├── chat_result.ex                       (MODIFY — add .new/1, .halted?/1 + @doc + @spec + defimpl + __from_tagged__/1)
├── usage.ex                             (MODIFY — add .new/1, .total_tokens/1 + @doc + @spec + defimpl + __from_tagged__/1)
├── thread.ex                            (MODIFY — @doc + doctests; helpers already exist; add defimpl + __from_tagged__/1)
├── event.ex                             (MODIFY — add event?/1 with shape checks, 14 variant constructors, tags/0 returning 16 atoms)
├── session.ex                           (MODIFY — @doc pass + @typedoc on status(); add defimpl + __from_tagged__/1; no new helpers. `@moduledoc` documents two contracts: `metadata[:error]` is populated when `status: :error`, and `context` is a caller-owned free-form map whose serializability is the caller's responsibility — library guarantees round-trip only for values the caller knows are serializable)
├── validate.ex                          (NEW — ALLM.Validate with 5 functions)
├── serializer.ex                        (NEW — ALLM.Serializer.encode_tagged/2 + to_json!/1 + from_json/2 with per-struct dispatch)
└── error/
    ├── engine_error.ex                  (NEW — defexception + message/1 override + defimpl Jason.Encoder)
    ├── adapter_error.ex                 (NEW — same)
    ├── stream_error.ex                  (NEW — same)
    ├── validation_error.ex              (NEW — same)
    └── tool_error.ex                    (NEW — same)

test/allm_test.exs                       (MODIFY — doctests pulled from lib/allm.ex)

test/allm/
├── message_test.exs                     (NEW)
├── tool_test.exs                        (NEW)
├── tool_call_test.exs                   (NEW)
├── request_test.exs                     (NEW)
├── response_test.exs                    (NEW)
├── step_result_test.exs                 (NEW)
├── chat_result_test.exs                 (NEW)
├── usage_test.exs                       (NEW)
├── thread_test.exs                      (NEW)
├── event_test.exs                       (NEW)
├── event_property_test.exs              (NEW — StreamData over every variant)
├── session_roundtrip_test.exs           (NEW — round-trip the existing Session struct)
├── validate_test.exs                    (NEW)
├── serializer_test.exs                  (NEW)
├── serializer_property_test.exs         (NEW — round-trip property over all Layer A structs)
└── error/
    ├── engine_error_test.exs            (NEW)
    ├── adapter_error_test.exs           (NEW)
    ├── stream_error_test.exs            (NEW)
    ├── validation_error_test.exs        (NEW)
    └── tool_error_test.exs              (NEW)

mix.exs                                  (MODIFY — add :stream_data to deps in :test env)
```

Test files mirror source files 1:1 per `agent-spec/DESIGN.md §4`. No `test/support/` modules needed in Phase 1 — conformance harnesses land in Phase 3.

## Phases

### Sub-phase 1.1: `ALLM.Error.*` Struct Hierarchy

**Goal:** Ship a first-class, serializable, `Exception`-compatible error hierarchy that refines spec §20.

**Spec sections:** §20

#### 1.1 Test Plan (write first)

`test/allm/error/{engine,adapter,stream,validation,tool}_error_test.exs`:

For each of the five error modules:
- `.new/2` (or `.new/3` for ValidationError) sets every documented field from opts.
- Required positional args (`reason`, and `errors` for ValidationError) raise `ArgumentError` when omitted.
- Unknown `:reason` atoms raise `ArgumentError` at `.new/*` time (the design keeps the reason type closed per the listed atoms).
- When `opts[:message]` is omitted, `.new/*` populates `:message` with the documented default string so `Exception.message/1` returns a non-empty binary.
- Each error is raiseable: `raise AdapterError, reason: :rate_limited, message: "..."` works and `Exception.message/1` returns the stored `message` field.
- Raw struct construction (`%EngineError{reason: :missing_adapter}` — bypasses `.new/*`) still yields a non-empty `Exception.message/1` because the `message/1` override computes a fallback from `:reason` when the `:message` field is nil.
- Each error round-trips through `:erlang.term_to_binary/1` and `:erlang.binary_to_term/1` to the equal struct.
- Each error JSON-encodes through `ALLM.Serializer.to_json!/1` and decodes back to the equal struct (this test is written in 1.5 but cross-references here; the round-trip contract is guaranteed in 1.5).

Property test: for a struct built via `struct!/2` with only `:reason` set (and `:errors` for ValidationError), `Exception.message/1` returns a non-empty binary across every legal reason atom.

#### 1.1 Implementation Checklist

- [x] Create `lib/allm/error/engine_error.ex` with `defexception` + `new/2` + `message/1` override.
- [x] Create `lib/allm/error/adapter_error.ex`.
- [x] Create `lib/allm/error/stream_error.ex`.
- [x] Create `lib/allm/error/validation_error.ex` with `new/3` (`reason, errors, opts`).
- [x] Create `lib/allm/error/tool_error.ex`.
- [x] Add `@spec` on every `new/*` matching the Behaviour & Type Contracts section verbatim.
- [x] Add `@doc` on every `new/*` with a runnable doctest.
- [x] Run the sub-phase 1.1 test suite; ensure ≥90% line coverage on new files.

#### 1.1 Verification

```bash
mix test test/allm/error/
mix credo --strict lib/allm/error/
mix dialyzer
mix format --check-formatted lib/allm/error/
```

---

### Sub-phase 1.2: Layer A Struct Helpers + `@spec`s

**Goal:** Every Layer A struct has a `.new/1` constructor, full `@spec`, and `@doc` with runnable doctest. Small accessors (`Response.text/1`, `ChatResult.halted?/1`, `Usage.total_tokens/1`) are added where they clarify intent.

**Spec sections:** §5.1, §5.2, §5.3, §5.4, §5.5, §5.6, §5.8, §5.9, §5.9a

#### 1.2 Test Plan (write first)

`test/allm/{message,tool_call,request,response,step_result,chat_result,usage,thread,tool}_test.exs`:

For each struct:
- `.new/1` (or `.new/2` for Request) with all valid fields returns a struct with those fields set.
- Omitting required fields raises `ArgumentError` via `struct!/2`'s built-in behavior; the test asserts the raise and the message.
- Every accessor (`Response.text/1` with `output_text` set, `message` set but `output_text` nil, both nil; `ChatResult.halted?/1`; `Usage.total_tokens/1`) is covered with both a nil-input and a populated-input test.
- `:erlang.term_to_binary/1` → `binary_to_term/1` round-trip preserves equality for a fully-populated instance.
- Struct fields with non-alphanumeric atom names (`StepResult.done?`) round-trip through both `term_to_binary` **and** the `Serializer` JSON path (the JSON test cross-references 1.5 but is noted here as the spec-facing concern — `String.to_existing_atom("done?")` must succeed, which it does because `:done?` is compiled into the BEAM as a struct-field atom).
- Doctest in `@doc` is discovered by `mix test` and passes.

`test/allm/session_roundtrip_test.exs`:
- Round-trip the existing `ALLM.Session` struct through `term_to_binary` for all five statuses (`:idle`, `:awaiting_user`, `:awaiting_tools`, `:completed`, `:error`), each with appropriate `pending_*` fields populated (and `metadata[:error]` populated for the `:error` status).
- Fixtures populate `context` with serializable values only — strings, atoms, integers, nested maps of the same — to match the caller-owned contract. No test stuffs a PID/ref/fun in `context`; the `badarg`-on-`term_to_binary` failure mode is documented in `@moduledoc`, not enforced.

#### 1.2 Implementation Checklist

- [x] Add `.new/1` and `@doc` to `ALLM.Message`; expose `@type role` as documented.
- [x] Add `@doc` + doctest to `ALLM.Tool` (`.new/1` already exists).
- [x] Add `.new/1` and `@doc` to `ALLM.ToolCall`.
- [x] Add `.new/2` and `@doc` to `ALLM.Request` (delegate from `ALLM.request/2` in 1.6).
- [x] Add `.new/1`, `.text/1`, and `@doc` to `ALLM.Response`.
- [x] Add `.new/1` and `@doc` to `ALLM.StepResult`.
- [x] Add `.new/1`, `.halted?/1`, and `@doc` to `ALLM.ChatResult`.
- [x] Add `.new/1`, `.total_tokens/1`, and `@doc` to `ALLM.Usage`.
- [x] Add `@doc` + doctests to `ALLM.Thread` public functions.
- [x] Add `@doc` pass to `ALLM.Session` (no new API; just docstring hygiene).
- [x] Ensure every `@spec` exists and matches the Behaviour & Type Contracts section.

#### 1.2 Verification

```bash
mix test test/allm/message_test.exs test/allm/tool_test.exs test/allm/tool_call_test.exs \
  test/allm/request_test.exs test/allm/response_test.exs test/allm/step_result_test.exs \
  test/allm/chat_result_test.exs test/allm/usage_test.exs test/allm/thread_test.exs \
  test/allm/session_roundtrip_test.exs
mix credo --strict lib/allm/
mix dialyzer
```

---

### Sub-phase 1.3: `ALLM.Event` — `event?/1` Guard + Variant Constructors

**Goal:** `ALLM.Event` gets a runtime predicate and 14 variant constructor helpers so later phases can emit events without hand-assembling tagged tuples. Property tests prove every variant round-trips through `term_to_binary` and is accepted by `event?/1`.

**Spec sections:** §8

#### 1.3 Test Plan (write first)

`test/allm/event_test.exs`:
- `event?/1` returns `true` for a representative of every variant; `false` for `:not_an_event`, `{:unknown_tag, %{}}`, `{1, 2}`, `nil`, `%{}`, `{"text_delta", %{}}` (string tag), and `{:text_delta, "not a map"}` (wrong-shape payload for a map-payload tag).
- `event?({:raw_chunk, any})` and `event?({:error, any})` return `true` for any payload type (opaque per §8).
- Each variant constructor (`text_delta/2`, `tool_call_started/2`, etc.) returns a term that passes `event?/1`.
- `tags/0` returns the full list of 16 tag atoms (14 structured + `:raw_chunk` + `:error`) in a stable order; `:raw_chunk in Event.tags()` and `:error in Event.tags()` both hold.

`test/allm/event_property_test.exs` (StreamData):
- Generator for each variant: produce a legal payload and assert `event?(variant) == true`.
- Round-trip: `variant |> :erlang.term_to_binary() |> :erlang.binary_to_term() == variant`.
- Malformed check: for every `{tag, non_map}` pair where `non_map` is not a map and `tag` is a known tag (except `:raw_chunk` and `:error` which accept any term), `event?/1 == false`.

#### 1.3 Implementation Checklist

- [x] Add `@tags` module attribute listing all 16 variant atoms (14 structured + `:raw_chunk` + `:error`).
- [x] Implement `event?/1`: checks tag ∈ `@tags`; for every tag except `:raw_chunk` and `:error`, additionally asserts `is_map(payload)`.
- [x] Implement `tags/0` returning `@tags` (sorted stable).
- [x] Add 14 variant constructors (`text_delta/2`, `text_completed/2`, `tool_call_started/2`, `tool_call_delta/2`, `tool_call_completed/4`, `tool_execution_started/3`, `tool_execution_completed/3`, `tool_result_encoded/2`, `ask_user_requested/4`, `tool_halt/3`, `message_started/1`, `message_completed/1`, `step_completed/2`, `chat_completed/1`). Skip explicit constructors for `:raw_chunk` and `:error` since their payloads are opaque; callers construct those inline.
- [x] Add `@spec` on every function matching the Behaviour & Type Contracts section.
- [x] Add `@doc` with runnable doctest on `event?/1` and each variant constructor.

#### 1.3 Verification

```bash
mix test test/allm/event_test.exs test/allm/event_property_test.exs
mix credo --strict lib/allm/event.ex
mix dialyzer
```

---

### Sub-phase 1.4: `ALLM.Validate`

**Goal:** Ship `ALLM.Validate` with five validator functions covering Request, Message, Tool, Thread, and Session. Each returns `:ok` or `{:error, %ALLM.Error.ValidationError{}}`. Failures include a machine-readable `errors: [field_error()]` list per the spec §16 "list of error terms" pattern.

**Spec sections:** §16, §33 (vision rejection)

#### 1.4 Field-Error Vocabulary

Exhaustive atom vocabulary per `agent-spec/DESIGN.md §7`. Implementer must not invent atoms; if a rule produces an error not in this table, amend the table first.

| Field path | Reason atom | Hard-reject? | Fires when |
|------------|-------------|--------------|------------|
| `[:messages]` | `:empty` | no | request has zero messages |
| `[:tools]` | `:duplicate_name` | no | two tools in a request share a `name` |
| `[:temperature]` | `:out_of_range` | no | temperature outside `[0.0, 2.0]` OR non-numeric (defensive) |
| `[:max_tokens]` | `:must_be_positive` | no | `max_tokens ≤ 0` |
| `[:response_format]` | `:invalid_shape` | no | non-map non-atom value (escape-hatch maps accepted, per §5.4) |
| `[:structured_finalize]` | `:requires_json_schema` | no | `structured_finalize: true` without a `:json_schema` |
| `[:role]` | `:unknown` | no | role not in `[:system, :user, :assistant, :tool]` |
| `[:tool_call_id]` | `:required` | no | `role: :tool` without a `tool_call_id` |
| `[:content]` | `:invalid_type` | no | content is neither `String.t()` nor a list |
| `[:content]` | `:image_part` | **yes** | content list contains an image part (atom- or string-keyed); hard reject per §33 |
| `[:name]` | `:empty` | no | tool name is `""` |
| `[:name]` | `:invalid_format` | no | tool name doesn't match `~r/^[A-Za-z0-9_-]{1,64}$/` or is not a binary |
| `[:name]` | `:reserved_tool_name` | no | tool name is `"auto"`, `"none"`, or `"required"` — these are reserved `tool_choice` atom values per spec §5.4 |
| `[:description]` | `:not_a_string` | no | tool description is not a string |
| `[:schema]` | `:not_a_map` | no | tool schema is not a map |
| `[:messages, idx, <field>]` | (any above) | — | per-message errors propagated from `thread/1` and `request/1` with list-path prefix |
| `[:pending_question]` | `:required_for_status` | no | `status: :awaiting_user` with nil `pending_question` |
| `[:pending_tool_calls]` | `:required_for_status` | no | `status: :awaiting_tools` with empty `pending_tool_calls` |
| `[:metadata]` | `:error_required_for_status` | no | `status: :error` with nil `metadata[:error]` |

Top-level `ValidationError.reason` atoms: `:invalid_request`, `:invalid_message`, `:invalid_tool`, `:invalid_thread`, `:invalid_session`, or `:vision_not_in_v0_2` (only the last is hard-reject).

#### 1.4 Test Plan (write first)

`test/allm/validate_test.exs`:

- `Validate.request/1` happy path: single-message valid request returns `:ok`.
- `Validate.request/1` fails: empty messages → `reason: :invalid_request, errors: [{:messages, :empty}]`.
- `Validate.request/1` fails: duplicate tool names → `errors: [{:tools, :duplicate_name}]`.
- `Validate.request/1` fails: `temperature: 3.0` → `errors: [{:temperature, :out_of_range}]`.
- `Validate.request/1` fails: `structured_finalize: true` with no json_schema → `errors: [{:structured_finalize, :requires_json_schema}]`.
- `Validate.message/1` fails: `role: :invalid` → `errors: [{:role, :unknown}]`.
- `Validate.message/1` fails: `role: :tool` without `tool_call_id` → `errors: [{:tool_call_id, :required}]`.
- `Validate.message/1` fails: content has `%{type: "image"}` list part → `reason: :vision_not_in_v0_2`.
- `Validate.tool/1` fails: `name: ""` → `errors: [{:name, :empty}]`.
- `Validate.tool/1` fails: `name: "has spaces"` → `errors: [{:name, :invalid_format}]`.
- `Validate.thread/1` fails: propagates per-message errors with `:messages, index` path prefix.
- `Validate.session/1` fails: `status: :awaiting_user` with `pending_question: nil` → `errors: [{:pending_question, :required_for_status}]`.
- `Validate.session/1` fails: `status: :error` with empty `metadata` → `errors: [{:metadata, :error_required_for_status}]`.
- Every happy path has a doctest.

Property test: for any `%Request{}` built with only valid fields via generators, `Validate.request/1 == :ok`.

#### 1.4 Implementation Checklist

- [x] Create `lib/allm/validate.ex` with the five public functions.
- [x] Implement each validator as a reduce-over-rules that accumulates `field_error()` tuples and returns `:ok` if empty, `{:error, ValidationError.new(:invalid_*, errors)}` otherwise.
- [x] `message/1` detects image content parts (`%{type: "image", ...}` or `%{type: "image_url", ...}`) and returns `:vision_not_in_v0_2` immediately (not accumulated — it's a hard reject per §33).
- [x] Add `@spec` on every public function matching the Behaviour & Type Contracts section.
- [x] Add `@doc` with runnable doctest on each public function.

#### 1.4 Verification

```bash
mix test test/allm/validate_test.exs
mix credo --strict lib/allm/validate.ex
mix dialyzer
```

---

### Sub-phase 1.5: `ALLM.Serializer` — `Jason` Round-Trip

**Goal:** Every Layer A struct (including `ALLM.Error.*`) round-trips through `Jason.encode!/1 |> Jason.decode!/1 |> ALLM.Serializer.from_json/1` via tagged encoding. `:erlang.term_to_binary/1` round-trips are already covered by 1.2's per-struct tests; this phase adds the JSON path.

**Spec sections:** §2 (Layer A serializability invariant)

#### 1.5 Field-Error Vocabulary

Exhaustive atom vocabulary per `agent-spec/DESIGN.md §7`. Implementer must not invent atoms; if a decoder branch needs a new atom, amend this table first and add the matching Test Plan entry.

| Field path | Reason atom | Hard-reject? | Fires when |
|------------|-------------|--------------|------------|
| `[:json]` | `:malformed` | **yes** | raw input isn't decodable by `Jason.decode/1` |
| `[:format]` | `:missing_type_tag` | **yes** | decoded JSON is a top-level object with no `"__type__"` key and caller passed no `:as` hint |
| `[:format]` | `:unknown_type_tag` | **yes** | `"__type__"` value isn't a recognized ALLM struct module (without `:as` override, this decodes to a plain map — forward-compat; atom fires only when `:as` is supplied with a non-ALLM module) |
| `[:data]` | `:missing` | **yes** | tagged JSON has `"__type__"` but no `"data"` key |
| `[:_unknown]` | `:atom_decode_failed` | **yes** | `String.to_existing_atom/1` raised on an atom-typed field's value — indicates the atom isn't loaded into the BEAM (programmer error; check `@type` declarations and module load order per design Non-obvious decision #3 "Atom discipline"). The `:_unknown` field-path placeholder is a **documented structural limitation** of Elixir's `rescue` scope — the hydrator catches at the struct level, not per-field. Per-field threading is a v0.3 hardening candidate. |
| `[:data]` | `:malformed_struct` | **yes** | tagged JSON's `"data"` value is not a map (e.g., a string, integer, or list where a field map is expected). Per-field shape checks are deferred to v0.3 — see Note below. |

**Note on per-field shape checking:** The v0.2 hydrators do not validate individual field values against the target struct's `@type`. A `Message` with `content: 42` decodes to a `%Message{content: 42}` struct rather than an error. If the bogus struct is subsequently consumed, downstream Layer C/D code raises; Layer A validates via `ALLM.Validate.*/1` which the caller opts into. Stricter per-field decode validation is a v0.3 hardening candidate.

Top-level `ValidationError.reason` atom for `from_json/2` failures: `:invalid_request`. All decoder failures are hard-reject because a partial decode yields a corrupted struct, which is strictly worse than an early error.

Encoding (`to_json!/1`) raises `Jason.EncodeError` on unencodable values rather than returning `{:error, _}`. This is by design: encoder failure indicates a Layer A invariant violation (non-serializable field), which is caught earlier by `Validate.*/1` and the `term_to_binary/1` round-trip tests from 1.1 and 1.2. Use `to_json!/1` when you've already validated; reach for the round-trip tests when you haven't.

#### 1.5 Test Plan (write first)

`test/allm/serializer_test.exs`:

- `to_json!/1` on a populated `Message` emits `{"__type__":"ALLM.Message","data":{...}}` with every field present — including `nil` values.
- `from_json/1` decodes that string back to the equal `%Message{}`, with `:role` restored to an atom via `String.to_existing_atom/1`.
- Atom-field round-trip is exercised for every atom-carrying field across Layer A: `Message.role`, `Request.response_format` (when `:text`), `Request.tool_choice` (when `:auto | :none | :required`), `Response.finish_reason`, `Session.status`, every `ALLM.Error.*.reason`, every `ALLM.Event` tag.
- `StepResult` with `done?: true` round-trips through JSON preserving the `:done?` atom key (tests `String.to_existing_atom("done?")` path).
- Nested round-trip: a `ChatResult` containing a `Thread` containing three `Message`s and a `Response` whose `usage` is a populated `Usage` round-trips to the equal struct.
- `from_json/1` returns `{:error, %ValidationError{reason: :invalid_request, errors: [{:format, :missing_type_tag}]}}` on an untagged JSON object when `:as` is not provided.
- `from_json/1` with `as: ALLM.Message` on an untagged JSON object decodes using the hint.
- Unknown `"__type__"` values decode to plain maps (forward-compat).
- Doctest on `to_json!/1` and `from_json/1`.

`test/allm/serializer_property_test.exs` (StreamData):
- Generator per Layer A struct; property: `ALLM.Serializer.from_json(ALLM.Serializer.to_json!(value)) == {:ok, value}` for every generated value.

#### 1.5 Implementation Checklist

- [x] Create `lib/allm/serializer.ex` with `encode_tagged/2`, `to_json!/1`, `to_iodata!/1`, `from_json/2`.
- [x] `encode_tagged/2` builds `%{"__type__" => inspect(module), "data" => Map.from_struct(value)}` and forwards to `Jason.Encode.map/2`; emits every field including `nil` values (do not use `@derive {Jason.Encoder, only: [...]}`).
- [x] Implement `from_json/2`: decode with `Jason.decode/1`, dispatch on `__type__` string, call each target module's `__from_tagged__/1` which re-hydrates atom fields and recurses into nested tagged maps.
- [x] Add `defimpl Jason.Encoder, for: ALLM.<struct>` + `__from_tagged__/1` to each of: `Message`, `Tool`, `ToolCall`, `Request`, `Response`, `Thread`, `Session`, `StepResult`, `ChatResult`, `Usage`, and all five `ALLM.Error.*`.
- [x] Each `__from_tagged__/1` enumerates its atom-bearing fields (compile-time known from the `@type t`) and calls `String.to_existing_atom/1` on the decoded string.
- [x] Verify `:erlang.term_to_binary/1` round-trips for the same set of structs were covered in 1.1 and 1.2; if any struct is missing a `term_to_binary` test, add it here.
- [x] Add `@spec` and `@doc` per the Behaviour & Type Contracts section.

#### 1.5 Verification

```bash
mix test test/allm/serializer_test.exs test/allm/serializer_property_test.exs
mix credo --strict lib/allm/serializer.ex
mix dialyzer
mix test --only roundtrip            # all @tag :roundtrip tests from 1.1, 1.2, 1.5
```

---

### Sub-phase 1.6: `lib/allm.ex` Facade — `@doc` + Runnable Doctests

**Goal:** Every public function in `lib/allm.ex` has a `@doc` with at least one runnable doctest that compiles under `mix test` and serves as executable documentation.

**Spec sections:** §4, §9

#### 1.6 Test Plan (write first)

The doctests themselves *are* the test plan. Each doctest lives in the `@doc` of its function and runs as part of `mix test` via the `doctest ALLM` directive in `test/allm_test.exs`.

Expected doctests:
- `ALLM.system/1` — build a system message.
- `ALLM.user/1` — build a user message.
- `ALLM.assistant/1` — build an assistant message.
- `ALLM.tool_result/2` — build a tool-role message with a tool_call_id.
- `ALLM.tool/1` — construct a tool (reference `ALLM.Tool.new/1`).
- `ALLM.json_schema/3` — produce a canonical `%{type: :json_schema, ...}` map with default `strict: true`.
- `ALLM.request/2` — build a request from messages with optional model/tools/response_format.

`test/allm_test.exs` (MODIFY):
- Add `doctest ALLM` at the top.
- Add one assertion-style test per function that also verifies the return is a struct of the expected type (doctests assert equality; this covers the `is_struct/2` check which doctests handle awkwardly).

#### 1.6 Implementation Checklist

- [x] Add `@doc` with a doctest on `ALLM.system/1`.
- [x] Add `@doc` with a doctest on `ALLM.user/1`.
- [x] Add `@doc` with a doctest on `ALLM.assistant/1`.
- [x] Add `@doc` with a doctest on `ALLM.tool_result/2`.
- [x] Add `@doc` with a doctest on `ALLM.tool/1` (doctest imports `ALLM.Tool.new/1`).
- [x] Add `@doc` with a doctest on `ALLM.json_schema/3` covering default `strict: true` and override.
- [x] Add `@doc` with a doctest on `ALLM.request/2` covering messages-only and messages-with-opts forms.
- [x] Rewrite `ALLM.request/2` as a thin wrapper: `def request(messages, opts \\ []), do: ALLM.Request.new(messages, opts)`. Do **not** use `defdelegate` — it can lose doctest behavior in some Elixir versions and prevents an independent `@doc` on the facade form. Same pattern for `ALLM.tool/1` → `ALLM.Tool.new/1` (scaffold already does this; confirm doctest is on `ALLM.tool/1`, not only on `ALLM.Tool.new/1`).
- [x] Expand `@moduledoc` on `ALLM` to include a 5-line worked example using the constructors.
- [x] Add `doctest ALLM` to `test/allm_test.exs`.

#### 1.6 Verification

```bash
mix test test/allm_test.exs
mix docs                              # hex doc build clean, no @doc warnings
mix credo --strict lib/allm.ex
mix dialyzer
```

---

## Test Plan (cross-phase)

Consolidated view of what lands in Phase 1 tests. The per-sub-phase tests above are the detail; this section is the top-down view.

### Unit tests (per module)

- Every `ALLM.*` module gets a matching `test/allm/*_test.exs`.
- Every public function has at least one happy-path and one error-path test.
- Every tagged-union type (`ALLM.Event`, `ALLM.Error.*.reason`) has one test per variant.

### Doctests

- `ALLM.system/1`, `user/1`, `assistant/1`, `tool_result/2`, `tool/1`, `json_schema/3`, `request/2` — one doctest each.
- Every `.new/1` on Layer A structs — one doctest each.
- `Event.event?/1`, every variant constructor, `Event.tags/0` — one doctest each.
- `Validate.request/1`, `message/1`, `tool/1`, `thread/1`, `session/1` — one happy-path doctest each.
- `Serializer.to_json!/1`, `from_json/2` — one doctest each.
- Every `ALLM.Error.*.new/*` — one doctest each.

Doctests double as living documentation and as the cheapest smoke test. A `@doc` example that doesn't compile is a failing test — per `agent-spec/DESIGN.md §6` this is a feature, not a defect.

### Property tests

- `ALLM.Event.event?/1` — for every variant, a StreamData generator produces legal payloads and asserts `event?(t) == true`; for every `{tag, non_map}` with known tags (except `:raw_chunk`/`:error`), asserts `event?(t) == false`.
- Serializer round-trip — for every Layer A struct, `from_json(to_json!(v)) == {:ok, v}`.
- `ALLM.Error.*` `Exception.message/1` — always returns a binary.
- `Validate.request/1` on random-field-valid requests — always returns `:ok`.

### Serializability round-trips (Layer A invariant)

- Every Layer A struct round-trips through `:erlang.term_to_binary/1 |> :erlang.binary_to_term/1` to an equal value. Tagged with `@tag :roundtrip` so they can be run as a dedicated regression suite via `mix test --only roundtrip`.
- Every Layer A struct round-trips through `Serializer.to_json!/1 |> Serializer.from_json/1` to `{:ok, equal_value}`.
- `ALLM.Session` (already scaffolded) is covered for all five status transitions, each with the appropriate `pending_*` fields populated.

### Stream-equivalence tests

N/A for Phase 1 — no streaming wrappers exist yet. First appear in Phase 5.

### Coverage

- Global coverage threshold ≥80% per `mix.exs` configuration — untouched.
- New code in Phase 1 lands at ≥90% line coverage. Error struct `.new/1` negative branches and `Serializer.from_json/2` forward-compat branches are the likely gaps; aim for each.

## Error Contract

| Function | Error reason | Recovery guidance |
|----------|--------------|--------------------|
| `ALLM.Validate.request/1` | `%ValidationError{reason: :invalid_request, errors: [...]}` | Inspect `errors` for per-field issues; fix the `Request` and re-validate. |
| `ALLM.Validate.message/1` | `%ValidationError{reason: :invalid_message, errors: [...]}` | Inspect `errors`; fix role/content/tool_call_id as indicated. |
| `ALLM.Validate.message/1` | `%ValidationError{reason: :vision_not_in_v0_2, errors: [{:content, :image_part}]}` | Vision input is a v0.2 non-goal (§33); remove image content parts or wait for v0.3. |
| `ALLM.Validate.tool/1` | `%ValidationError{reason: :invalid_tool, errors: [...]}` | Inspect `errors`; fix name/schema/description. |
| `ALLM.Validate.thread/1` | `%ValidationError{reason: :invalid_thread, errors: [...]}` | Inspect `errors` — each entry has path `[:messages, index, :field]`; fix the offending message. |
| `ALLM.Validate.session/1` | `%ValidationError{reason: :invalid_session, errors: [...]}` | Inspect `errors`; most commonly a status/pending_* mismatch. |
| `ALLM.Serializer.from_json/2` | `%ValidationError{reason: :invalid_request, errors: [{:format, :missing_type_tag}]}` | JSON lacks `"__type__"`; pass `:as` opt or re-serialize with `Serializer.to_json!/1`. |
| `ALLM.Serializer.from_json/2` | `%ValidationError{reason: :invalid_request, errors: [{:json, :malformed}]}` | JSON is not decodable by `Jason`; fix upstream. |
| `ALLM.Error.*.new/*` | `ArgumentError` | Programmer error — fix the `.new/*` call at the callsite. |

No function in Phase 1 returns `{:error, term()}`. Every error is a struct per `agent-spec/DESIGN.md §7`.

## Streaming & Backpressure

**N/A for Phase 1.** No Layer C code is added; streaming primitives land in Phase 5. Consumer cancellation, Finch resource cleanup, and SSE buffering are Phase 5 + Phase 10 concerns.

## Definition of Done

- [x] All 6 sub-phases marked `Completed` in the Status table.
- [x] `mix test` passes with zero failures and zero `unused_var` warnings.
- [x] Global coverage ≥80%; new-code coverage ≥90%.
- [x] `mix credo --strict` clean on every changed file.
- [x] `mix dialyzer` clean against the prior PLT (no new warnings).
- [x] `mix format --check-formatted` clean.
- [x] `mix docs` builds without `@doc` warnings.
- [x] Every new public function has an `@spec` matching the Behaviour & Type Contracts section verbatim.
- [x] Every new public function has an `@doc` with at least one runnable doctest that passes under `mix test`.
- [x] Every Layer A struct (including `ALLM.Error.*`) round-trips through `:erlang.term_to_binary/1` (covered by tests tagged `@tag :roundtrip`).
- [x] Every Layer A struct round-trips through `ALLM.Serializer.to_json!/1 |> from_json/1` to `{:ok, equal_value}`.
- [x] `ALLM.Event.event?/1` accepts every legal variant and rejects every malformed shape listed in the property test.
- [x] `ALLM.Validate.*/1` returns `{:error, %ValidationError{}}` (never `{:error, atom}` or `{:error, [term()]}`).
- [x] `CHANGELOG.md` updated with one-line entries: "Add `ALLM.Error.*` hierarchy", "Add `ALLM.Validate`", "Add `ALLM.Serializer`", "Add `ALLM.Event.event?/1` + variant constructors", "Add `.new/1` constructors to every Layer A struct".
- [ ] Commit messages cite the spec sections they implement (e.g., `feat(validate): add ALLM.Validate per §16`). _Not yet satisfied: Phase 1 work remains in the uncommitted working tree (single `Initial Scaffolding` commit on branch). To be satisfied by the Phase 1 close-out commit(s)._
- [ ] Reviewed via `/review`.
