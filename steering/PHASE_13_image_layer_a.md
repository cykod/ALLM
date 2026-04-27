# Phase 13: v0.3 Layer A — Image Data Structs, Facade, Validator — Design Document

> **Goal:** Land the four new Layer A image structs (`ALLM.Image`, `ALLM.ImageRequest`, `ALLM.ImageResponse`, `ALLM.ImageUsage`), the facade constructor `ALLM.image_request/2`, the new `ALLM.Validate.image_request/1` validator, and a populated-case engine round-trip proving `image_adapter:` doesn't perturb v0.2 serializability.
> **Outcome:** `mix test` and `mix dialyzer` green; every new struct round-trips through `:erlang.term_to_binary/1` and `ALLM.Serializer` JSON; the eight new field-error atoms are exhaustively tested; a v0.2 caller using `String` content + chat-only engine compiles and behaves identically.
> **Spec sections:** §35.2.1, §35.2.2, §35.2.3, §35.2.4, §35.4, §35.5 (image_request/2 only); refines §16 (validators).
> **Layers touched:** A (sole). The `:image_adapter` engine field is already present from v0.2 batch 2.3 — this phase only extends round-trip coverage with a populated case; no new Layer B surface.

## Status

| Phase | Description | Layer | Status |
|-------|-------------|-------|--------|
| 13.1  | `ALLM.Image` struct + constructors + `to_binary/1` + `to_data_uri/1` + serializability | A | Not Started |
| 13.2  | `ALLM.ImageRequest`, `ALLM.ImageResponse`, `ALLM.ImageUsage` structs + Serializer registry extension | A | Not Started |
| 13.3  | `ALLM.image_request/2` facade + `ALLM.Validate.image_request/1` + `ValidationError` enum extension + populated engine round-trip | A | Not Started |

**Overall Progress:** 0/3 phases complete

## Overview

ALLM v0.3 adds image generation, editing, and vision input on top of the v0.2 chat runtime. The first slice — this phase — is purely Layer A: the four data structs that downstream phases (behaviour, engine dispatch, real provider adapter, vision content parts) all consume. Nothing in this phase touches an adapter, the engine's call-time behaviour, or any chat-side type. The `image_adapter: module() | nil` field already lives on `%ALLM.Engine{}` (added in v0.2 sub-phase 2.3 alongside its `@engine_field_keys` and `__from_tagged__/1` hookup — `lib/allm/engine.ex:74`, `:111`, `:395`); this phase contributes a populated-case round-trip proving the existing field doesn't break v0.2 invariants once Phase 14's `ALLM.ImageAdapter` behaviour gives it a non-nil module to point at.

- **Deliverables:**
  - `lib/allm/image.ex` (NEW) — struct, four constructors, `to_binary/1`, `to_data_uri/1`, `Jason.Encoder` impl.
  - `lib/allm/image_request.ex`, `lib/allm/image_response.ex`, `lib/allm/image_usage.ex` (NEW) — structs + `Jason.Encoder` impls + `__from_tagged__/1` hydrators.
  - `lib/allm/serializer.ex` (MODIFY) — extend `@known_modules` with the four new structs.
  - `lib/allm.ex` (MODIFY) — add `image_request/2` constructor.
  - `lib/allm/validate.ex` (MODIFY) — add `image_request/1` validator.
  - `lib/allm/error/validation_error.ex` (MODIFY) — extend `@type reason` enum with `:invalid_image_request`.
  - `mix.exs` (MODIFY) — add `ALLM.Image`, `ALLM.ImageRequest`, `ALLM.ImageResponse`, `ALLM.ImageUsage` to the `groups_for_modules: ["Data types": …]` list.
  - Test files mirroring 1:1 (see Module Tree).
- **Spec coverage:** §35.2.1 (`ALLM.Image`), §35.2.2 (`ImageRequest`), §35.2.3 (`ImageResponse`), §35.2.4 (`ImageUsage`), §35.5 (`image_request/2` only — `generate_image/3`, `edit_image/4`, `image_variations/3` are Phase 15). Refines §16 (validators) by adding the eighth public validator.
- **Layer demonstration (Layer A only):**

  ```elixir
  # Layer A: build a request, validate, round-trip through JSON, deserialize.
  iex> req = ALLM.image_request("a watercolor kestrel", model: "gpt-image-1", size: {1024, 1024}, n: 2)
  iex> :ok = ALLM.Validate.image_request(req)
  iex> json = ALLM.Serializer.to_json!(req)
  iex> {:ok, ^req} = ALLM.Serializer.from_json(json)
  ```

  No engine, no adapter, no I/O — proves the data layer is independently usable.
- **Prerequisites:** v0.2 complete (Phases 1–12). Specifically requires `ALLM.Serializer.encode_tagged/2` and `hydrate/1` (Phase 1), the `ALLM.Engine.image_adapter` field (Phase 2.3, `lib/allm/engine.ex:74`), and the `ALLM.Error.ValidationError.@type reason` closed set (`lib/allm/error/validation_error.ex:23-32`).
- **Out of scope (deliberate):**
  - `ALLM.ImageAdapter` behaviour and `ALLM.Providers.FakeImages` — Phase 14 (v0.3 Phase 2). Validating shape without an executor is the whole point of this phase.
  - `ALLM.generate_image/3`, `edit_image/4`, `image_variations/3` — Phase 15 (v0.3 Phase 3). The dispatch path needs a behaviour to dispatch to.
  - `:no_image_adapter` reason on `ALLM.Error.EngineError` — Phase 15. No call-site can return it yet.
  - `ALLM.TextPart`, `ALLM.ImagePart`, multimodal `Message.content` — Phase 17 (v0.3 Phase 5). Vision input lives on the chat side and is sequenced after the image core ships.
  - HTTP fetch in `ALLM.Image.from_url/1` or `to_binary/1` — banned by phasing principle #8 (`steering/RELEASE_0_3_PHASING.md:18`). `{:url, _}` carries the URL as data; the adapter does the fetch.
  - Telemetry, capability pre-flight, retry — Phase 16 (v0.3 Phase 4).
  - Capability pre-flight extension to `:image_generation` / `:image_edit` / `:image_variation` on `ALLM.Capability` — Phase 16. The `:unsupported_capability` atom on `ALLM.Error.ValidationError` already exists in v0.2's enum and is unchanged here.
- **Non-obvious decisions:**
  1. **`ImageUsage.*_cost` fields are typed `float() | nil`, NOT `Decimal.t() | nil` as spec §35.2.4 reads.** Refinement of the spec, NOT an implementation of it: the existing `ALLM.Usage.cost` type is `float()` (`lib/allm/usage.ex:11`), and `decimal` is not a project dep (`mix.exs` has no `:decimal`). Adopting `Decimal` would diverge the cost type between `Usage` and `ImageUsage` and add a runtime dep solely for typed nil-or-number. The downstream `llm_db` integration (Phase 16, deferred) already returns floats per `lib/allm/usage.ex` precedent. **A separate spec PR against `steering/allm_engine_session_streaming_spec_v0_2.md` §35.2.4 needs to land before this refinement is approved** (per AGENT_DESIGN_SPEC §2: "refining requires a separate spec PR before approval"). The implementer files that PR alongside Phase 13.2's first commit. CHANGELOG entry for v0.3.0 will note the float refinement. Note that float-summation drift on `total_cost = input_cost + output_cost` is bounded at ≤1 ULP and well below the cent-level precision of provider pricing — acceptable per `Usage` precedent. *Docs target: `@moduledoc ALLM.ImageUsage` + CHANGELOG entry + linked spec PR.*
  2. **`Image.to_binary/1` for `{:url, _}` returns `{:error, :remote_source}` — never fetches.** Resolves Phase 1 key decision (a) from `steering/RELEASE_0_3_PHASING.md:61`. Eager fetches in Layer A constructors break serializability (the resolved binary changes per call) and hide latency behind a constructor — both anti-patterns relative to v0.2's Layer A discipline. The Phase 18 OpenAI Images adapter performs URL → binary at request-build time with explicit Finch I/O. *Docs target: `@doc ALLM.Image.to_binary/1`.*
  3. **`ValidationError.reason` extends with `:invalid_image_request` (single umbrella).** Field-level distinctions live in `errors:` per the existing v0.2 vocabulary pattern (§Error Contract table below). Resolves Phase 1 key decision (b) from `steering/RELEASE_0_3_PHASING.md:61` — the phasing doc says "distinct atoms," but it conflates the `:reason` atom (single per validator) with `errors:`-list field atoms (one per failed rule). v0.2 validators (`request/1`, `message/1`, `tool/1`, `thread/1`, `session/1`) all use a single `:invalid_X` umbrella reason and accumulate per-field detail in `errors:`. Phase 16 telemetry routes errors by both `reason` (top-level) and `errors:` (granular) — distinct field atoms (8 added below) give telemetry the routing it needs without creating an asymmetric closed set on `:reason`. *Docs target: `@moduledoc ALLM.Validate` (extend) + `@doc ALLM.Validate.image_request/1`.*
  4. **`Image.source` JSON encoding uses an explicit map shape (`%{"type" => "...", "value" => ...}`) — not a JSON 2-tuple.** Jason has no encoder for raw tuples; the same problem v0.2 solves for `Engine.adapter_opts` keyword lists. The `{:binary, b}` variant Base64-encodes the binary on the wire so JSON round-trips work for arbitrary bytes; `:erlang.term_to_binary/1` keeps the tuple shape natively without re-encoding. The decoder dispatches on `data["type"]` against a closed `~w[binary base64 url file]` set; unknown values surface as `[:source, :unknown_source_type]` in the field-error vocabulary. *Docs target: `@moduledoc ALLM.Image` (Serializability section).*
  5. **`from_file/1` does NOT call `File.read/1`; only stores the path.** Pure data — `to_binary/1` is the place I/O happens, and even there only for `{:file, _}`. This keeps `from_file/1` total (no `{:error, posix()}` shape on the constructor) and matches phasing principle #8. The constructor's MIME-type detection is extension-only (`Path.extname/1` → static lookup table); when the extension is absent or unknown, `:mime_type` stays `nil` and the adapter handles defaulting. *Docs target: `@doc ALLM.Image.from_file/1`.*
  6. **`to_data_uri/1` for `{:url, _}` returns `{:error, :remote_source}` — does NOT pass the URL through verbatim.** A `data:` URI and an `https:` URI are different addressing schemes; passing `https://` through a function named `to_data_uri/1` would surprise. Adapters that accept either form (Phase 19 OpenAI vision, Phase 20 Anthropic vision) read `Image.source` directly and choose the right wire form per provider; they don't go through `to_data_uri/1`. *Docs target: `@doc ALLM.Image.to_data_uri/1`.*
  7. **`ALLM.image_request/2`'s first arg is always a prompt string; `:variation` callers construct `%ImageRequest{}` by hand.** The facade is sugar for the common case (generate from a string prompt). `:variation` requires `prompt: nil` per §35.2.2, so a string-prompt facade signature is wrong-shaped for it. Callers building variations work directly with the struct: `%ALLM.ImageRequest{operation: :variation, input_images: [img]}`. The validator catches a prompt-supplied-with-variation construction either way. *Docs target: `@doc ALLM.image_request/2`.*
  8. **Engine round-trip with populated `image_adapter:` is added to the existing `EngineRoundtripTest` (sub-phase 13.3 Test Plan), NOT a new test file.** The field is already covered with `nil` (`test/allm/engine_roundtrip_test.exs:40`); the only new assertion is "value-populated round-trip." Adding a parallel test file would duplicate the populated-engine fixture and split the v0.2 invariant proofs across two suites. *Docs target: internal — no user-facing docs needed.*

## Behaviour & Type Contracts

No new behaviours in this phase. Five struct contracts and one validator/facade contract follow.

### `ALLM.Image` — Layer A

```elixir
defmodule ALLM.Image do
  @type source ::
          {:binary, binary()}
          | {:base64, String.t()}
          | {:url, String.t()}
          | {:file, Path.t()}

  @type t :: %__MODULE__{
          source: source(),
          mime_type: String.t() | nil,
          width: non_neg_integer() | nil,
          height: non_neg_integer() | nil,
          prompt: String.t() | nil,
          revised_prompt: String.t() | nil,
          metadata: map()
        }

  @enforce_keys [:source]
  defstruct [:source, :mime_type, :width, :height, :prompt, :revised_prompt, metadata: %{}]

  @spec from_file(Path.t()) :: t()
  @spec from_binary(binary(), String.t()) :: t()
  @spec from_url(String.t()) :: t()
  @spec from_base64(String.t(), String.t()) :: t()

  @spec to_binary(t()) ::
          {:ok, binary()}
          | {:error, :remote_source | :invalid_base64 | File.posix() | :enoent}
  @spec to_data_uri(t()) ::
          {:ok, String.t()}
          | {:error, :remote_source | :missing_mime_type | :invalid_base64 | File.posix()}

  @doc false
  @spec __from_tagged__(map()) :: t()
end
```

**Invariants.**

- `:source` is the only required field — other fields are nil-able to support both inputs (vision: only `source`/`mime_type` populated) and outputs (generated: also `prompt`/`revised_prompt`/`width`/`height`).
- `:erlang.term_to_binary/1 |> :erlang.binary_to_term/1` returns an equal struct for every legal `:source` shape. The `{:file, path}` variant preserves the path verbatim — the test asserts the path round-trips; `to_binary/1` is the only call that ever touches the filesystem.
- JSON round-trip: encode emits `%{"__type__" => "ALLM.Image", "data" => %{… "source" => %{"type" => …, "value" => …}}}`; decode dispatches on `data["source"]["type"]` against the closed set `~w[binary base64 url file]`. The `{:binary, b}` variant Base64-encodes `b` on the wire so the JSON form is text-safe; `Base.decode64/1` raises on an unparsable wire (caller passed corrupted JSON).
- `from_file/1` populates `:mime_type` from `Path.extname/1` against `~w[.png .jpg .jpeg .webp .gif]` → `~w[image/png image/jpeg image/jpeg image/webp image/gif]`; unknown/missing extension leaves `:mime_type` as `nil`.
- `from_binary/2` and `from_base64/2` require an explicit `mime_type` argument (binary, no default). Implementations enforce this with `when is_binary(mime_type) and is_binary(b)` (or `… and is_binary(s)`) function guards — `nil`/integer/atom inputs raise `FunctionClauseError`. The runtime guard backs the `@spec` so callers don't get silently-`nil`-mime structs.
- `from_base64/2` does NOT validate that `s` is well-formed base64 — the function is pure-data (Decision #5). Callers passing URL-safe base64 (`-`/`_` instead of `+`/`/`) or unpadded base64 produce a struct that round-trips correctly through ETF and JSON but whose `to_data_uri/1` fast-path (Decision #4) will emit a `data:` URI a downstream consumer may reject. The `@doc` for `from_base64/2` documents the standard-base64-with-padding contract.
- `from_url/1` does NOT inspect the URL or perform an HTTP request; `:mime_type` is `nil` (the adapter resolves it).

**Test-observable verifications.**

- `Base.decode64/1` returns `{:ok, b} | :error` (verified in `iex` against OTP 27 on 2026-04-27 — `Base.decode64("not~b64")` returns `:error`, matching docs). The `Image.__from_tagged__/1` binary-source clause uses the non-bang form and routes `:error` to a `[:source, :invalid_base64]` field-error path (see Field-error vocabulary in §Error Contract); this is invoked through `ALLM.Serializer.from_json/1`'s `hydrate_with/2` only when the field error is raised before the rescue catches it, so the implementer pre-validates inside `__from_tagged__/1` and raises a `ValidationError` directly when corrupted base64 is detected — matching the closed-enum error-shape rules in §Error Contract.
- `File.read/1` returns `{:ok, b} | {:error, File.posix()}` per Elixir 1.17 docs (cited from `https://hexdocs.pm/elixir/File.html#read/1`).
- `Path.extname/1` returns `""` (empty string) when the path has no extension — verified against `Path.extname("noext") == ""` in `iex` on 2026-04-27.
- `Base.encode64("hi")` returns `"aGk="` — verified in `iex` on 2026-04-27 (used in 13.1 doctest output for `to_data_uri/1`).
- `Base.encode64("hello")` returns `"aGVsbG8="` — verified in `iex` on 2026-04-27 (used in 13.1 doctest output for `to_binary/1` round-trip with the base64 source).

### `ALLM.ImageRequest` — Layer A

```elixir
defmodule ALLM.ImageRequest do
  @type operation :: :generate | :edit | :variation
  @type size :: {pos_integer(), pos_integer()} | String.t() | :auto
  @type quality :: :low | :standard | :high | :hd | :auto | String.t()
  @type response_format :: :binary | :base64 | :url

  @type t :: %__MODULE__{
          operation: operation(),
          model: String.t() | nil,
          prompt: String.t() | nil,
          n: pos_integer(),
          size: size() | nil,
          quality: quality() | nil,
          style: :natural | :vivid | nil,
          background: :transparent | :opaque | nil,
          response_format: response_format(),
          input_images: [ALLM.Image.t()],
          mask: ALLM.Image.t() | nil,
          options: map(),
          metadata: map()
        }

  defstruct [
    :model,
    :prompt,
    :size,
    :quality,
    :style,
    :background,
    :mask,
    operation: :generate,
    n: 1,
    response_format: :binary,
    input_images: [],
    options: %{},
    metadata: %{}
  ]

  @spec new(keyword()) :: t()
  @doc false
  @spec __from_tagged__(map()) :: t()
end
```

**Invariants.**

- `new/1` is `struct!/2` over the keyword opts — unknown keys raise `KeyError` (matches `ALLM.Request.new/2` precedent at `lib/allm/request.ex:73`).
- ETF round-trip preserves the `:size` tuple form `{1024, 1024}`. JSON encode emits the tuple as a 2-element JSON array `[1024, 1024]`; decode reconstructs the tuple when the JSON value is a 2-element list of positive integers, otherwise treats it as a string (falling back to `:auto` only on the string `"auto"`).
- Closed atom enums on the wire — `:operation`, `:response_format`, `:style`, `:background`, and the atom variants of `:size`/`:quality` — are decoded via `ALLM.Serializer.to_atom_field/1` (`lib/allm/serializer.ex:185-188`), which delegates to `String.to_existing_atom/1`. NOT `Module.concat/1`. **Unknown atom values cause `String.to_existing_atom/1` to raise `ArgumentError`, which the serializer's `hydrate_with/2` rescue clause (`lib/allm/serializer.ex:237-242`) converts to a top-level `{:error, %ValidationError{reason: :invalid_request, errors: [{:_unknown, :atom_decode_failed}]}}`** — there is no per-field error path for closed-enum decode failures in v0.2's serializer. `:quality` accepts `String.t()` per the type, so the decoder prefers a matched closed-atom restoration but passes binary values through verbatim — same asymmetry as `Request.tool_choice` (`lib/allm/request.ex:96`).

**`__from_tagged__/1` decoder table.** Every atom-typed field on `ImageRequest` is restored via `ALLM.Serializer.to_atom_field/1` (binary → existing-atom; nil/atom passes through; `ArgumentError` propagates to `hydrate_with/2`'s rescue per §`ALLM.Image` Invariants).

| Field | Wire form | Closed atom set | Decoder |
|-------|-----------|-----------------|---------|
| `:operation` | binary | `[:generate, :edit, :variation]` | `to_atom_field/1` |
| `:response_format` | binary | `[:binary, :base64, :url]` | `to_atom_field/1` |
| `:style` | binary or `nil` | `[:natural, :vivid]` | `to_atom_field/1` |
| `:background` | binary or `nil` | `[:transparent, :opaque]` | `to_atom_field/1` |
| `:size` | 2-element JSON array OR binary OR `"auto"` OR `nil` | `:auto` (atom branch only) | dedicated `decode_size/1` clause table — `[w, h]` of pos ints → `{w, h}`; `"auto"` → `:auto` (`to_atom_field/1`); other binary → passes through verbatim; `nil` → `nil` |
| `:quality` | binary OR `nil` | `[:low, :standard, :high, :hd, :auto]` (atom branch); any other binary stays binary | dedicated `decode_quality/1` — try `String.to_existing_atom/1` against the closed set; on `ArgumentError`, return the binary verbatim (the `String.t()` arm of the type) |

`:size` and `:quality` decoders are private helpers (`decode_size/1`, `decode_quality/1`) in `image_request.ex`, mirroring `lib/allm/request.ex:94-99`'s `decode_tool_choice/1`/`decode_response_format/1` precedent — closed-set restoration with binary fall-through. `:operation`, `:response_format`, `:style`, `:background` use `to_atom_field/1` directly because their type does NOT include a `String.t()` arm.

### `ALLM.ImageResponse` — Layer A

```elixir
defmodule ALLM.ImageResponse do
  @type t :: %__MODULE__{
          id: String.t() | nil,
          request_id: String.t() | nil,
          model: String.t() | nil,
          images: [ALLM.Image.t()],
          usage: ALLM.ImageUsage.t(),
          raw: term(),
          metadata: map()
        }

  defstruct [
    :id,
    :request_id,
    :model,
    :raw,
    images: [],
    usage: %ALLM.ImageUsage{},
    metadata: %{}
  ]

  @spec new(keyword()) :: t()
  @doc false
  @spec __from_tagged__(map()) :: t()
end
```

**Invariants.**

- `:raw` is `term()` — adapters stash provider-specific structures here (analogous to `ALLM.Response.raw`). It is opaque to the library and may not survive JSON round-trip (caller responsibility — consistent with v0.2 `Response.raw` precedent).
- Struct default `:usage` is a fresh `%ALLM.ImageUsage{}` (`images: 0`, all other fields `nil`). Adapter populates on success.
- ETF round-trip is total. JSON round-trip with a non-encodable `:raw` value raises `Jason.EncodeError` at encode time — same semantics as `Response.raw` (verified by reading `lib/allm/response.ex` on 2026-04-27).

### `ALLM.ImageUsage` — Layer A

```elixir
defmodule ALLM.ImageUsage do
  @type t :: %__MODULE__{
          images: non_neg_integer(),
          size: String.t() | nil,
          quality: String.t() | nil,
          input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil,
          input_cost: float() | nil,
          output_cost: float() | nil,
          total_cost: float() | nil
        }

  defstruct [
    :size,
    :quality,
    :input_tokens,
    :output_tokens,
    :input_cost,
    :output_cost,
    :total_cost,
    images: 0
  ]

  @spec new(keyword()) :: t()
  @doc false
  @spec __from_tagged__(map()) :: t()
end
```

**Invariants.**

- Default `images: 0` — a default-constructed `ImageUsage` represents "no work done yet"; the response's struct default uses this so callers don't observe a `nil` count.
- Cost fields are `float() | nil` per Non-obvious decision #1 (refinement of spec §35.2.4).
- `:size` and `:quality` are stored as binaries on the response side because providers return them as canonical strings (`"1024x1024"`, `"high"`) — keeping them binary avoids a closed-enum membership check on response decoding when the provider invents a new size.

### `ALLM.image_request/2` — facade

```elixir
@spec image_request(String.t(), keyword()) :: ALLM.ImageRequest.t()
def image_request(prompt, opts \\ []) when is_binary(prompt) and is_list(opts)
```

**Invariants.**

- Always populates `:prompt` from the first argument and `:operation` defaults to `:generate` (struct default) unless `opts[:operation]` overrides — see Non-obvious decision #7. Callers wanting `:variation` build the struct directly.
- Does NOT call `ALLM.Validate.image_request/1` (matches `request/2` precedent at `lib/allm.ex:163`).
- Unknown keys in `opts` raise `KeyError` via `struct!/2` — same idiom as `ALLM.request/2`.

### `ALLM.Validate.image_request/1` — validator

```elixir
@spec image_request(ALLM.ImageRequest.t()) ::
        :ok | {:error, ALLM.Error.ValidationError.t()}
def image_request(%ALLM.ImageRequest{} = req)
```

**Invariants.**

- Returns `:ok` when every rule passes; otherwise `{:error, %ValidationError{reason: :invalid_image_request, errors: [...]}}` accumulating ALL failed rules (no hard-reject — matches `request/1` accumulator pattern at `lib/allm/validate.ex:58-74`).
- Field-error vocabulary is exhaustive — see §Error Contract → Field-error atom vocabulary.
- Operation-arity rules per spec §35.2.2:
  - `:generate` → requires non-empty `:prompt` AND `:input_images == []`.
  - `:edit` → requires non-empty `:prompt` AND `length(:input_images) in 1..2`.
  - `:variation` → requires `:prompt in [nil, ""]` (rejects non-empty) AND `length(:input_images) == 1`.
- `:n >= 1` (positive integer).
- `:response_format in [:binary, :base64, :url]`.
- `:size` validated as `{w, h}` with positive integers, OR a binary, OR `:auto`, OR `nil` — non-matching values produce `{:size, :invalid_shape}`.
- `:input_images` and `:mask`, when present, must be `%ALLM.Image{}` (not arbitrary maps); element rejections produce indexed paths `{[:input_images, idx], :invalid_image}`.

### `ALLM.Engine` — populated round-trip extension

No struct change. Existing field at `lib/allm/engine.ex:74`:

```elixir
image_adapter: module() | nil
```

is already serialized via `restore_module/1` (`lib/allm/engine.ex:395`) and listed in `@engine_field_keys` (`lib/allm/engine.ex:111`). This phase only extends `test/allm/engine_roundtrip_test.exs:40`'s `populated_engine/1` to set `image_adapter: ALLM.Engine` (using `ALLM.Engine` itself as a stub-but-loaded module, matching the pattern at line 25). Asserts ETF and JSON round-trips both return an equal struct.

### Serializer registry extension

`lib/allm/serializer.ex:64-83` `@known_modules` extends from 18 to 22 entries:

```elixir
@known_modules [
  …existing 18…,
  ALLM.Image,
  ALLM.ImageRequest,
  ALLM.ImageResponse,
  ALLM.ImageUsage
]
```

This is registration-as-contract per AGENT_DESIGN_SPEC: a Test Plan assertion in 13.2 ("`ALLM.Serializer.from_json/1` decodes a round-tripped `%ALLM.ImageRequest{}` to an equal struct") depends on the `__type__` → module dispatch table containing the new modules. The registration is part of the contract, not buried in a checklist.

### `ALLM.Error.ValidationError` enum extension

`lib/allm/error/validation_error.ex:23-32` `@type reason` extends with one atom:

```elixir
@type reason ::
        :invalid_request
        | :invalid_message
        | :invalid_tool
        | :invalid_thread
        | :invalid_session
        | :invalid_session_input
        | :unsupported_capability
        | :vision_not_in_v0_2
        | :invalid_image_request    # NEW (§35.2.2)
```

The matching `@legal_reasons` list at `lib/allm/error/validation_error.ex:42-51` extends with `invalid_image_request`. Field-error atoms (8 new — see §Error Contract) are NOT enumerated in this enum; field reasons are open per the existing v0.2 vocabulary (`:empty`, `:duplicate_name`, `:out_of_range`, etc.) and only the umbrella atom is closed.

## Module Tree

```
lib/allm/
├── image.ex                            (NEW — struct + 4 constructors + to_binary/1 + to_data_uri/1)
├── image_request.ex                    (NEW — struct + new/1 + __from_tagged__/1)
├── image_response.ex                   (NEW — struct + new/1 + __from_tagged__/1)
├── image_usage.ex                      (NEW — struct + new/1 + __from_tagged__/1)
├── serializer.ex                       (MODIFY — extend @known_modules with 4 new structs)
├── validate.ex                         (MODIFY — add image_request/1 validator + helpers)
├── error/
│   └── validation_error.ex             (MODIFY — extend @type reason and @legal_reasons)
└── allm.ex                             (MODIFY — add image_request/2 facade constructor)

test/allm/
├── image_test.exs                      (NEW)
├── image_request_test.exs              (NEW)
├── image_response_test.exs             (NEW)
├── image_usage_test.exs                (NEW)
├── validate/
│   └── image_request_test.exs          (NEW — exhaustive field-error matrix)
├── allm_image_request_test.exs         (NEW — facade-only tests)
├── engine_roundtrip_test.exs           (MODIFY — populated case sets image_adapter: ALLM.Engine)
└── serializer/
    └── image_structs_test.exs          (NEW — JSON round-trip for the 4 new structs across all source variants)

mix.exs                                 (MODIFY — extend docs groups_for_modules with 4 new structs)
CHANGELOG.md                            (MODIFY — v0.3.0-dev entry: Layer A image data structs)
```

Test files mirror source 1:1 except the `Validate.image_request/1` tests live under `test/allm/validate/image_request_test.exs` (separate file because the rule matrix is large; `test/allm/validate_test.exs` already covers the v0.2 validators).

## Phases

### Phase 13.1: `ALLM.Image` — Struct, Constructors, to_binary/to_data_uri

**Goal:** Land the central `ALLM.Image` Layer A struct with four pure constructors, two effectful resolvers, and complete serializability across all four `:source` variants.

**Spec sections:** §35.2.1.

#### 13.1.1 Test Plan (write first)

`test/allm/image_test.exs` (NEW):

- **Constructors (pure, no I/O):**
  - `from_binary/2 with PNG bytes and "image/png" returns %Image{source: {:binary, bytes}, mime_type: "image/png"}`
  - `from_base64/2 with a base64 string and explicit mime_type returns the {:base64, _} source verbatim — does NOT decode`
  - `from_url/1 with "https://example.com/x.png" returns %Image{source: {:url, "https://example.com/x.png"}, mime_type: nil}` (no extension scan on URL form per Non-obvious decision #5)
  - `from_file/1 with "fixtures/cat.png" returns mime_type "image/png"` (extension lookup)
  - `from_file/1 with "fixtures/cat.JPG" returns mime_type "image/jpeg"` (case-insensitive ext)
  - `from_file/1 with "fixtures/noext" returns mime_type nil` (unknown extension)
  - `from_file/1 with ".jpeg" mapped to "image/jpeg"` and `.gif` to `"image/gif"` and `.webp` to `"image/webp"`
  - `from_file/1 does NOT call File.read — verified by passing a path that does not exist; from_file/1 returns a struct, no error` (the I/O happens only in `to_binary/1`)
  - `from_binary/2 with mime_type nil raises FunctionClauseError` — proves the `is_binary(mime_type)` guard is in place (the @spec is backed by a runtime guard)
  - `from_base64/2 with mime_type nil raises FunctionClauseError` — same guard contract
  - `from_binary/2 with non-binary first arg (e.g. integer) raises FunctionClauseError` — `is_binary(b)` guard
  - `from_url/1 with "" returns %Image{source: {:url, ""}, mime_type: nil}` — empty-URL pass-through is documented Layer A purity (URL validation lives in the adapter, NOT Layer A; Decision #2 / phasing principle #8). No round-trip test on the empty-URL form is needed beyond the existing `:url` source variant assertions.
- **`to_binary/1`:**
  - `{:binary, b} returns {:ok, b} verbatim`
  - `{:base64, "aGVsbG8="} returns {:ok, "hello"}` (Base.decode64 path)
  - `{:base64, "not~b64"} returns {:error, :invalid_base64}` (verified `Base.decode64/1` returns `:error` on invalid input)
  - `{:url, _} returns {:error, :remote_source}` (Non-obvious decision #2)
  - `{:file, valid_tmp_path} returns {:ok, contents}` (test creates the tmp file with `System.tmp_dir!/0`)
  - `{:file, "/does/not/exist"} returns {:error, :enoent}` (verified `File.read/1` returns `{:error, :enoent}` on missing file)
- **`to_data_uri/1`:**
  - `{:binary, b} with mime_type "image/png" returns {:ok, "data:image/png;base64," <> Base.encode64(b)}`
  - `{:base64, s} with mime_type "image/jpeg" returns {:ok, "data:image/jpeg;base64," <> s}` (no decode + re-encode round-trip)
  - `{:file, path} with mime_type detected from extension returns {:ok, "data:image/png;base64," <> Base.encode64(file_contents)}`
  - `{:url, _} returns {:error, :remote_source}` (Non-obvious decision #6)
  - `{:binary, b} with mime_type nil returns {:error, :missing_mime_type}` (no default to "application/octet-stream")
- **Serializability:**
  - `:erlang.term_to_binary/1 round-trip preserves every legal :source variant` (one assertion per variant; binary, base64, url, file)
  - `Jason via ALLM.Serializer round-trip preserves every legal :source variant` (binary variant Base64-encoded on wire; JSON-text-safe)
  - `JSON encoded form for {:binary, _} contains "type" => "binary" and Base.encode64 of the bytes`
  - `JSON encoded form for {:url, _} preserves the URL string verbatim, NOT Base64-encoded`
  - `JSON decode of {"__type__": "ALLM.Image", "data": {…, "source": {"type": "bogus", "value": "x"}}} returns {:error, %ValidationError{reason: :invalid_request, errors: [{:_unknown, :atom_decode_failed}]}}` — the closed-enum decode failure path through `Serializer.hydrate_with/2`'s rescue (`lib/allm/serializer.ex:237-242`); v0.2's serializer surfaces these as a top-level error tuple, not a per-field path
  - `JSON decode of {"__type__": "ALLM.Image", "data": {…, "source": {"type": "binary", "value": "not~b64"}}} returns {:error, %ValidationError{reason: :invalid_request, errors: [{[:source], :invalid_base64}]}}` — `Image.__from_tagged__/1` raises a pre-built `ValidationError` (NOT `ArgumentError`) so the field-error path survives the serializer rescue
- **Doctests:**
  - `from_binary/2` doctest constructs and accesses `.source` and `.mime_type`.
  - `from_url/1` doctest shows the URL-only form.
  - `to_binary/1` doctest with `{:binary, "hi"}`.
  - `to_data_uri/1` doctest with `{:binary, "hi"}` and an explicit mime.

#### 13.1.2 Implementation Checklist

- [ ] Define the `ALLM.Image` struct with `@enforce_keys [:source]` and the field defaults from spec §35.2.1.
- [ ] Implement four pure constructors (`from_file/1`, `from_binary/2`, `from_url/1`, `from_base64/2`) — no I/O, no validation, just `%__MODULE__{...}` construction. Add the static `@ext_to_mime` map for `from_file/1` (5 entries, lowercase ext keys; `Path.extname/1 |> String.downcase/1` for case-insensitive lookup).
- [ ] Implement `to_binary/1` with one clause per `:source` variant, including the `{:base64, _}` clause that pattern-matches `Base.decode64/1`'s `{:ok, _} | :error` return.
- [ ] Implement `to_data_uri/1` reusing `to_binary/1` for the binary cases plus a `{:base64, s}` fast path that skips the decode-then-re-encode round-trip.
- [ ] Implement `defimpl Jason.Encoder` that pre-pass-transforms `:source` into the `%{"type" => "...", "value" => ...}` map (Base64-encoding the binary variant) before delegating to `ALLM.Serializer.encode_tagged/2`. Pattern matches `lib/allm/engine.ex:508` (`defimpl Jason.Encoder` for tuple-carrying field).
- [ ] Implement `__from_tagged__/1` that dispatches `data["source"]["type"]` against `~w[binary base64 url file]` and rebuilds the tuple. Use `Base.decode64/1` (non-bang form) for the binary variant on decode and pattern-match the `{:ok, b} | :error` return — the `:error` clause raises an explicit `ALLM.Error.ValidationError.new(:invalid_request, [{[:source], :invalid_base64}])` instead of an `ArgumentError`, so the field error is preserved through `Serializer.from_json/1` (the rescue at `lib/allm/serializer.ex:240` only catches `ArgumentError`).
- [ ] **Extend `ALLM.Serializer.@known_modules` (`lib/allm/serializer.ex:64`) with `ALLM.Image` only.** This is required for `ALLM.Serializer.from_json/1` to dispatch the new `__type__` tag through `Image.__from_tagged__/1`; without the registration, the JSON round-trip Test Plan bullets in 13.1.1 fail because `from_json/1` returns the un-hydrated `{:ok, tagged_map}` per `lib/allm/serializer.ex:207`. The other three structs' registrations land alongside their structs in 13.2. Sub-phase 13.1 ships green on its own once `ALLM.Image` is registered.
- [ ] `@doc` with at least one runnable doctest on every public function.
- [ ] `@spec` matching the §Behaviour & Type Contracts shape verbatim.
- [ ] CHANGELOG entry: `[FEAT] v0.3 Phase 13.1: ALLM.Image Layer A struct + four constructors + to_binary/to_data_uri (§35.2.1)`.

#### 13.1.3 Verification

```bash
mix test test/allm/image_test.exs
mix test                                # full suite green
mix credo --strict lib/allm/image.ex
mix dialyzer
mix format --check-formatted
```

---

### Phase 13.2: `ALLM.ImageRequest`, `ALLM.ImageResponse`, `ALLM.ImageUsage` + Serializer Registry

**Goal:** Land the three remaining Layer A structs and register them with `ALLM.Serializer` so the JSON round-trip path dispatches correctly.

**Spec sections:** §35.2.2, §35.2.3, §35.2.4.

#### 13.2.1 Test Plan (write first)

`test/allm/image_request_test.exs` (NEW):

- `new/1 with prompt and operation: :generate sets the fields and inherits struct defaults (n: 1, response_format: :binary, input_images: [], operation: :generate)`
- `new/1 with unknown key raises KeyError via struct!/2` (matches `Request.new/2` precedent)
- `new/1 with size: {1024, 1024} preserves the tuple`
- `:erlang.term_to_binary/1 round-trip is total for every operation × source-variant combination` (3 ops × 4 source variants = 12 assertions or a parameterised property)
- `Jason encode of size: {1024, 1024} emits the JSON array [1024, 1024]; decode reconstructs the tuple`
- `Jason encode of size: :auto emits "auto"; decode restores the atom`
- `Jason encode of operation: :variation emits "variation"; decode dispatches via String.to_existing_atom/1` (verified the atom is in the committed enum at `image_request.ex` `@type operation`)
- `Jason encode of style: :natural emits "natural"; decode restores the atom via to_atom_field/1`
- `Jason encode of style: nil emits null; decode preserves nil` (covers the nil-able atom-typed fields uniformly)
- `Jason encode of background: :transparent emits "transparent"; decode restores the atom`
- `Jason encode of quality: :high emits "high"; decode restores the atom via decode_quality/1`
- `Jason encode of quality: "custom-tier" (binary) emits "custom-tier"; decode_quality/1 returns the binary verbatim` — proves the binary fall-through arm of the type
- `Jason encode of size: "1024x1024" (binary) emits the string; decode_size/1 returns the binary verbatim` — proves the binary fall-through for size
- `unknown operation atom in JSON returns {:error, %ValidationError{reason: :invalid_request, errors: [{:_unknown, :atom_decode_failed}]}}` — closed-enum decode failure surfaces as a top-level error per the serializer rescue at `lib/allm/serializer.ex:237-242`
- Doctest: `new/1` with a prompt + size + n.

`test/allm/image_response_test.exs` (NEW):

- `new/1 with no opts produces images: [], usage: %ImageUsage{images: 0}, raw: nil`
- `:erlang.term_to_binary/1 round-trip with images: [%Image{source: {:binary, b}}], usage: %ImageUsage{images: 1, input_tokens: 10}`
- `Jason round-trip with images list (binary source) preserves byte equality after Base.decode64`
- `Jason encode of :raw containing a non-encodable value (e.g. a Range struct missing a Jason.Encoder impl) raises Jason.EncodeError` — documents the same caller-responsibility contract as `Response.raw`
- Doctest: `new/1` with images + usage.

`test/allm/image_usage_test.exs` (NEW):

- `new/1 with no opts produces images: 0 and every other field nil`
- `:erlang.term_to_binary/1 round-trip preserves every field including nils`
- `Jason round-trip with input_cost: 0.012 preserves the float value` (no Decimal — Non-obvious decision #1)
- `Jason round-trip with all-nil cost fields produces the same struct after decode`
- Doctest: `new/1` with `images: 1, input_tokens: 100`.

`test/allm/serializer/image_structs_test.exs` (NEW):

- `Serializer.@known_modules contains ALLM.Image, ALLM.ImageRequest, ALLM.ImageResponse, ALLM.ImageUsage` (introspection test on the module attribute)
- `Serializer.from_json/1 dispatches an %{"__type__" => "ALLM.ImageRequest", ...} payload through ImageRequest.__from_tagged__/1` (end-to-end via `to_json!/1 |> from_json/1`)
- `Serializer.from_json/1 returns {:error, %ValidationError{reason: :invalid_request, errors: [{:_unknown, :unknown_type_tag}]}} for {"__type__": "ALLM.NotAType", ...}` — proves the registry extension didn't break the unknown-tag path

#### 13.2.2 Implementation Checklist

- [ ] Implement `ALLM.ImageRequest` struct + `new/1` + `__from_tagged__/1` + `defimpl Jason.Encoder, do: encode_tagged/2`.
- [ ] Implement `ALLM.ImageResponse` likewise.
- [ ] Implement `ALLM.ImageUsage` likewise.
- [ ] Extend `ALLM.Serializer.@known_modules` (`lib/allm/serializer.ex:64`) with the three new modules added in this sub-phase (`ImageRequest`, `ImageResponse`, `ImageUsage`). `ALLM.Image` was already registered in 13.1 — total goes from 19 to 22 entries.
- [ ] Add the structs to `mix.exs` `groups_for_modules: ["Data types": …]` so `ex_doc` groups them with v0.2 data types.
- [ ] `@doc` + `@spec` on every public function; doctests as listed in the Test Plan.
- [ ] Verify `mix.exs` package files glob `lib` continues to ship the new modules in the published tarball (no change needed — `lib` is the glob root at `mix.exs:69`).
- [ ] CHANGELOG entry: `[FEAT] v0.3 Phase 13.2: ALLM.ImageRequest/ImageResponse/ImageUsage Layer A structs + Serializer registry extension (§35.2.2-4)`.

#### 13.2.3 Verification

```bash
mix test test/allm/image_request_test.exs test/allm/image_response_test.exs test/allm/image_usage_test.exs test/allm/serializer/image_structs_test.exs
mix test                                # full suite green; serializer round-trip suite expanded
mix credo --strict lib/allm/image_request.ex lib/allm/image_response.ex lib/allm/image_usage.ex lib/allm/serializer.ex
mix dialyzer
```

---

### Phase 13.3: `ALLM.image_request/2` Facade + `ALLM.Validate.image_request/1` + Engine Round-Trip Extension

**Goal:** Public surface: the facade constructor and the validator. Plus the v0.2 invariant proof that `image_adapter:` populated on `Engine` doesn't break round-trip.

**Spec sections:** §35.5 (image_request/2 only), §16 (validators), §35.4 (engine field — already implemented; this is a coverage extension).

#### 13.3.1 Test Plan (write first)

`test/allm/allm_image_request_test.exs` (NEW):

- `image_request/2 with "a kestrel" returns a %ImageRequest{operation: :generate, prompt: "a kestrel", n: 1, response_format: :binary, input_images: []}`
- `image_request/2 with opts model: "gpt-image-1", size: {1024, 1024}, n: 2 sets the fields` (all opts forwarded via `struct!/2`)
- `image_request/2 with opts including unknown key raises KeyError` (matches `request/2` precedent)
- `image_request/2 does NOT call ALLM.Validate.image_request/1` (test passes operation: :variation with prompt — validator would reject — and asserts the struct returns from the constructor without error)
- Doctest covering the canonical generate case.

`test/allm/validate/image_request_test.exs` (NEW) — exhaustive field-error matrix:

- **Happy paths:**
  - `:generate` with prompt only → `:ok`
  - `:edit` with prompt + 1 input_image → `:ok`
  - `:edit` with prompt + 2 input_images (mask-as-second-image form) → `:ok`
  - `:variation` with 1 input_image, prompt nil → `:ok`
  - All response_format values (`:binary`, `:base64`, `:url`) accepted
  - All size shapes (`{w, h}`, `String.t()`, `:auto`, `nil`) accepted
- **Operation rules (§35.2.2):**
  - `:generate` with prompt nil → `[{:prompt, :required_for_operation}]`
  - `:generate` with prompt "" → `[{:prompt, :required_for_operation}]`
  - `:generate` with input_images != [] → `[{:input_images, :must_be_empty}]`
  - `:edit` with prompt nil → `[{:prompt, :required_for_operation}]`
  - `:edit` with input_images == [] → `[{:input_images, :invalid_count}]`
  - `:edit` with input_images of length 3 → `[{:input_images, :invalid_count}]`
  - `:variation` with prompt "non-empty" → `[{:prompt, :not_allowed_for_operation}]`
  - `:variation` with input_images == [] → `[{:input_images, :invalid_count}]`
  - `:variation` with input_images of length 2 → `[{:input_images, :invalid_count}]`
  - `:variation` with empty-string prompt + 1 valid input_image → `:ok` — empty string is treated as absent for the `:not_allowed_for_operation` rule (only non-empty strings trip it). Documents the prompt-empty-string semantics that Decision #7's "validator catches a prompt-supplied-with-variation construction either way" relies on.
- **Field rules:**
  - `:operation` not in `[:generate, :edit, :variation]` → `[{:operation, :unknown}]`
  - `:n` zero → `[{:n, :must_be_positive}]`
  - `:n` negative → `[{:n, :must_be_positive}]`
  - `:n` non-integer → `[{:n, :must_be_positive}]`
  - `:response_format` not in `[:binary, :base64, :url]` → `[{:response_format, :unknown}]`
  - `:size` of shape `{0, 1024}` → `[{:size, :invalid_shape}]` (zero not positive)
  - `:size` of shape `{:not, :a, :tuple_of_integers}` → `[{:size, :invalid_shape}]`
  - `:size` shape `:not_an_atom` (non-`:auto`) → accepted as a binary if it's a binary, else rejected — non-binary, non-tuple, non-`:auto`, non-nil → `[{:size, :invalid_shape}]`
  - `:input_images` non-list → `[{:input_images, :not_a_list}]`
  - `:input_images` containing a non-`%Image{}` element → `[{[:input_images, 0], :invalid_image}]` (indexed path)
  - `:mask` non-`%Image{}` value → `[{:mask, :invalid_image}]`
- **Accumulator (no hard-reject):**
  - `:generate` with prompt nil AND n: 0 AND response_format: :unknown → all three errors in `errors:` list (proves accumulator semantics — matches `request/1`)
- **Return shape:**
  - On any error, `err.reason == :invalid_image_request`, `err.message` defaults to `"validation failed: invalid_image_request (N error(s))"`, and `err.errors` is a list of `{field, atom}` tuples
- Doctest covering happy `:generate`.

`test/allm/engine_roundtrip_test.exs` (MODIFY):

- Modify the existing `populated_engine/1` helper (line 27) to set `image_adapter: ALLM.Engine` (matching the `@stub_handler_module` pattern at line 25) by default.
- Existing `populated engine round-trips through :erlang.term_to_binary/1` (line 52) and `populated engine round-trips through ALLM.Serializer JSON` (line 58) tests now exercise the populated `image_adapter:` field — no new test cases needed; the assertion is `decoded == engine` and the field is part of the equality check.
- Add ONE new explicit test: `populated engine with image_adapter set decodes via String.to_existing_atom/1 — proves the existing decoder wiring at lib/allm/engine.ex:395 handles a non-nil module value`. This is belt-and-braces against the silent-success failure mode where `image_adapter:` decodes via `restore_module/1` but is silently `nil` because of a wiring bug.

#### 13.3.2 Implementation Checklist

- [ ] Implement `ALLM.image_request/2` in `lib/allm.ex` directly above `request/2` (matching the doc-comment style at `lib/allm.ex:144`). One-line `struct!/2` body — no validation per `Non-obvious decision #7`.
- [ ] Extend `ALLM.Error.ValidationError.@type reason` (`lib/allm/error/validation_error.ex:23`) and `@legal_reasons` (`lib/allm/error/validation_error.ex:42`) with `:invalid_image_request`.
- [ ] Implement `ALLM.Validate.image_request/1` in `lib/allm/validate.ex` matching the `request/1` accumulator pattern (`lib/allm/validate.ex:58-74`). Add private helpers per the field-error vocabulary table — one per rule.
- [ ] Update the `ALLM.Validate` `@moduledoc` to mention `image_request/1` alongside the v0.2 validators (it currently lists the five `request/message/tool/thread/session` validators).
- [ ] Modify `populated_engine/1` in `test/allm/engine_roundtrip_test.exs` to use `image_adapter: ALLM.Engine`. Add the new explicit assertion described in the Test Plan.
- [ ] CHANGELOG entry: `[FEAT] v0.3 Phase 13.3: ALLM.image_request/2 facade + ALLM.Validate.image_request/1 + Engine round-trip extension (§35.4, §35.5)`.

#### 13.3.3 Verification

```bash
mix test test/allm/allm_image_request_test.exs
mix test test/allm/validate/image_request_test.exs
mix test test/allm/engine_roundtrip_test.exs
mix test                                # full v0.2 suite green — backward-compat invariant
mix credo --strict lib/allm.ex lib/allm/validate.ex lib/allm/error/validation_error.ex
mix dialyzer
mix format --check-formatted
```

The v0.2 backward-compat clause is the load-bearing assertion: `mix test` running the unchanged v0.2 suite at full green proves that adding the `:invalid_image_request` reason and the new `image_request/2` constructor did not perturb any v0.2 behaviour. Any failure in `test/allm/engine_test.exs`, `test/allm/validate_test.exs`, or the existing serializer suite is a Phase 13.3 regression.

## Test Plan (cross-phase)

Aggregating the per-sub-phase plans plus cross-cutting properties:

- **Unit tests** — every public function (`from_file/1`, `from_binary/2`, `from_url/1`, `from_base64/2`, `to_binary/1`, `to_data_uri/1`, `Image.__from_tagged__/1`, `ImageRequest.new/1`, `ImageResponse.new/1`, `ImageUsage.new/1`, `image_request/2`, `Validate.image_request/1`) gets at least one happy-path test and one error-path or edge-case test.
- **No behaviour conformance tests** in this phase — no behaviour introduced.
- **Integration tests** — covered by the JSON round-trip path in `test/allm/serializer/image_structs_test.exs` (multi-module: `Image` → `ImageRequest` → `Serializer` → JSON → `Serializer.from_json/1` → struct).
- **Property tests** — one StreamData property per phase:
  - 13.1: `forall source ∈ legal_sources, image |> :erlang.term_to_binary/1 |> :erlang.binary_to_term/1 == image` (excludes `{:file, _}` for tmp-file lifecycle reasons; covered by parameterised unit tests instead).
  - 13.2: `forall (op, n, response_format) ∈ legal_combos, ImageRequest.new/1 |> serializer_round_trip == itself` (closed-enum coverage).
- **Doctests** — every public function has at least one runnable `@doc` example. Living docs.
- **Serializability tests** — every Layer A struct round-trips through both `:erlang.term_to_binary/1` and `ALLM.Serializer.to_json!/1 |> from_json/1`. Required for v0.3 release per AGENT_DESIGN_SPEC §6.
- **Stream-equivalence tests** — N/A; this phase introduces no streaming paths.
- **Backward-compat tests** — the v0.2 chat-only invariant: `populated_engine/1` round-trip with the modified `image_adapter: ALLM.Engine` value continues to assert `decoded == engine`. A v0.2 caller using only `String` content + chat adapter sees zero behaviour change.

**Coverage threshold:** 80% global per `mix.exs:19`; ≥90% on new code per AGENT_DESIGN_SPEC. The `Validate.image_request/1` matrix (≥30 assertions across happy + error paths) takes the validator above 90% on its own; the four struct constructors are simple struct + getter shape and reach 100% trivially.

## Error Contract

### Atom additions to `ALLM.Error.ValidationError.@type reason`

| Function | Error reason | Recovery guidance |
|----------|--------------|-------------------|
| `Validate.image_request/1` | `:invalid_image_request` | Caller-recoverable. Inspect `err.errors` for the per-field atoms below; fix the request and re-validate. |

### Atom additions to `ALLM.Error.EngineError`

**None.** No call-site can return an engine error in this phase. Phase 15 introduces `:no_image_adapter`.

### Field-error atom vocabulary (`ALLM.Validate.image_request/1`)

Exhaustive — the implementer should never need to invent an atom outside this table.

| Field path | Reason atom | Hard-reject? | Fires when |
|------------|-------------|--------------|------------|
| `:operation` | `:unknown` | no | not in `[:generate, :edit, :variation]` |
| `:prompt` | `:required_for_operation` | no | `:operation in [:generate, :edit]` and prompt is `nil` or `""` |
| `:prompt` | `:not_allowed_for_operation` | no | `:operation == :variation` and prompt is a non-empty string |
| `:input_images` | `:not_a_list` | no | not a list (e.g. `nil`, map, binary) |
| `:input_images` | `:must_be_empty` | no | `:operation == :generate` and list non-empty |
| `:input_images` | `:invalid_count` | no | `:edit` length not in `1..2`, OR `:variation` length != 1 |
| `[:input_images, idx]` | `:invalid_image` | no | element at `idx` is not a `%ALLM.Image{}` |
| `:mask` | `:invalid_image` | no | non-nil and not a `%ALLM.Image{}` |
| `:n` | `:must_be_positive` | no | not an integer ≥ 1 |
| `:response_format` | `:unknown` | no | not in `[:binary, :base64, :url]` |
| `:size` | `:invalid_shape` | no | not in `{pos_integer, pos_integer}`, `String.t()`, `:auto`, `nil` |
| `[:source]` | `:invalid_base64` | yes | `Image.__from_tagged__/1` decoding a JSON `"source": {"type": "binary", "value": <not-valid-base64>}` — short-circuits the rest of the struct hydration because `:source` is `@enforce_keys` (no point continuing without it). Surfaced through `Serializer.from_json/1` by raising a pre-built `ValidationError` (NOT `ArgumentError`, which would be coerced to `:atom_decode_failed`). |

**Hard-reject semantics.** Within `Validate.image_request/1` itself, every rule accumulates — matches `request/1` precedent at `lib/allm/validate.ex:58-74`. The only hard-reject in this phase's vocabulary is the JSON-decode-time `[:source, :invalid_base64]` raised inside `Image.__from_tagged__/1`, where the `:source` field is `@enforce_keys` and continuation without it is meaningless. The v0.2 `:vision_not_in_v0_2` hard-reject is being phased out in v0.3 Phase 17.

### Field-error atoms NOT added (intentionally)

- `:size`-shape distinctions (`:not_a_tuple` vs `:zero_dimension`) — collapsed into `:invalid_shape` because the caller's recovery is identical (re-supply a legal shape) and provider-specific size validation lives in the adapter (e.g., `gpt-image-1` rejects sizes outside its closed set; that's `unsupported_capability` at adapter time, not Layer A validation).
- `:quality`-value validation — `:quality` is a string-or-atom open type per spec §35.2.2; the validator does not enforce a closed set because providers extend it (`:hd` is dall-e-3-specific; `:high` is gpt-image-1-specific). Adapter-level validation in Phase 16 (`Capability.preflight/2`).
- `:style`, `:background` — closed atom enums but not currently validated by `image_request/1` because struct construction via `new/1`/`struct!/2` rejects unknown atom values via the `@type` annotation alone (Dialyzer-enforced; not runtime-enforced — same precedent as `Request.tool_choice`).

## Streaming & Backpressure

N/A. This phase introduces no streaming paths. The `:image_adapter` field on Engine is module-only metadata; no `Stream.resource/3` or Finch state is added.

## Definition of Done

- [ ] All three sub-phases (13.1, 13.2, 13.3) marked `Completed`
- [ ] `mix test` zero failures, zero `unused_var` warnings, coverage ≥80% globally and ≥90% on new code (verified per phase via `mix test --cover`)
- [ ] `mix credo --strict` zero issues on changed files (`lib/allm/image*.ex`, `lib/allm/validate.ex`, `lib/allm.ex`, `lib/allm/error/validation_error.ex`, `lib/allm/serializer.ex`)
- [ ] `mix dialyzer` zero new warnings vs the v0.2 PLT
- [ ] `mix format --check-formatted` passes
- [ ] Every new public function (`Image.from_file/1`, `from_binary/2`, `from_url/1`, `from_base64/2`, `to_binary/1`, `to_data_uri/1`; `ImageRequest.new/1`; `ImageResponse.new/1`; `ImageUsage.new/1`; `ALLM.image_request/2`; `ALLM.Validate.image_request/1`) has `@spec` and `@doc` with at least one runnable doctest
- [ ] Every Layer A struct change has a serializability round-trip test for both `:erlang.term_to_binary/1` and JSON via `ALLM.Serializer`
- [ ] No behaviour change → no conformance suite update needed (re-confirmed)
- [ ] Stream-equivalence tests N/A
- [ ] Spec section references in commit messages cite §35.2.1, §35.2.2, §35.2.3, §35.2.4, §35.5, §35.4 per phase
- [ ] CHANGELOG.md updated with one bullet per public-API addition (3 bullets: `Image`, the three `Image*` request/response/usage structs, the facade + validator + engine round-trip)
- [ ] Reviewed via `/review` per AGENT_REVIEW_SPEC.md
- [ ] v0.2 backward-compat invariant: `mix test` over the unchanged v0.2 suite (everything outside `test/allm/image*` and `test/allm/validate/image_request_test.exs`) is green at the same total count as before this phase, modulo the one modified line in `test/allm/engine_roundtrip_test.exs:40`
