# ALLM Conformance

Conformance test suite for [ALLM](https://github.com/cykod/allm) behaviours.
Ship your `ALLM.Adapter`, `ALLM.StreamAdapter`, `ALLM.ToolExecutor`, or
`ALLM.ToolResultEncoder` implementation with confidence: plug it into the
matching `ALLM.Test.*Conformance` template and run the shipped suite of
deterministic, scripted test cases.

## Installation

Add one line to your project's `mix.exs` dependencies:

```elixir
def deps do
  [
    {:allm, "~> 0.2"},
    {:allm_conformance, "~> 0.2", only: :test}
  ]
end
```

No `elixirc_paths` surgery required — the harness ships as a regular Hex
package on the test-only load path.

## Quickstart

```elixir
defmodule MyApp.MyAdapterTest do
  use ExUnit.Case, async: true
  use ALLM.Test.AdapterConformance, adapter: MyApp.MyAdapter
end
```

The `use` line injects a `describe "ALLM.Adapter conformance (MyApp.MyAdapter)"`
block with the full shipped case matrix. Cases that require scripted error
paths use `adapter_opts` on the request; consult the harness module's
`@moduledoc` for the exact contract.

The three peer harnesses follow the same shape:

```elixir
use ALLM.Test.StreamAdapterConformance, stream_adapter: MyApp.MyStreamAdapter
use ALLM.Test.ToolExecutorConformance, executor: MyApp.MyExecutor
use ALLM.Test.ToolResultEncoderConformance, encoder: MyApp.MyEncoder
```

## What the harness is for

- **Deterministic.** No network calls, no `StreamData`, no random inputs.
  Every case runs in under 1 ms.
- **Shape assertions.** Cases assert struct shapes and reason atoms against
  the closed sets published by `ALLM.Error.AdapterError`,
  `ALLM.Error.StreamError`, and `ALLM.Error.ToolError`.
- **Layer B only.** The harness certifies adapters, executors, and encoders
  — not stateless execution or session continuation (Layers C and D).

## Release checklist

1. Bump the version in both `mix.exs` files (this package and the main `allm`
   package).
2. Rewrite the in-repo `{:allm, path: ".."}` dep in `conformance/mix.exs` to
   `{:allm, "~> 0.2"}` just before `mix hex.publish`.
3. Publish `allm` first, then `allm_conformance` (the sibling's Hex dep
   resolves against the just-published `allm`).
4. After publish, revert `conformance/mix.exs` to the path dep for local dev.

## License

MIT — see [LICENSE](LICENSE).
