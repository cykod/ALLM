defmodule ALLMFacadeDoctestInventoryTest do
  @moduledoc """
  Contract test: every public function on `ALLM` has at least one runnable
  doctest in its `@doc` block. The contract list is `@public_facade` below;
  adding a new public function without a doctest fails this test.

  Streaming functions are allowed to use construction-only doctests (build
  the engine, call the function, assert the `{:ok, %Stream{}}` shape match)
  rather than consume the stream — `Logger.configure/1` and
  `:telemetry.attach/4` are async-foot-guns under `async: true` doctests.
  Stream-consumption examples live in `guides/streaming.md`.
  """

  use ExUnit.Case, async: true

  @public_facade [
    # Layer A constructors
    system: 1,
    user: 1,
    assistant: 1,
    tool_result: 2,
    tool: 1,
    json_schema: 3,
    image_request: 2,
    embedding_request: 2,
    request: 2,
    # Stateless execution
    generate: 3,
    stream_generate: 3,
    step: 3,
    stream_step: 3,
    chat: 3,
    stream: 3,
    # Image generation
    generate_image: 3,
    edit_image: 4,
    image_variations: 3,
    # Embeddings
    embed: 3
  ]

  describe "every public ALLM function has a doctest" do
    for {fun, arity} <- @public_facade do
      test "#{fun}/#{arity} has at least one `iex>` doctest line" do
        {fun, arity} = {unquote(fun), unquote(arity)}
        body = doc_body_for(ALLM, fun, arity)

        assert body != nil,
               "ALLM.#{fun}/#{arity} has no @doc — every public facade function must be documented"

        assert body =~ "iex>",
               "ALLM.#{fun}/#{arity} has a @doc but no `iex>` doctest example"
      end
    end
  end

  describe "@public_facade matches the actual exported public API" do
    test "every fun/arity in @public_facade is exported by ALLM" do
      exported = ALLM.__info__(:functions)

      for {fun, arity} <- @public_facade do
        assert {fun, arity} in exported,
               "@public_facade lists ALLM.#{fun}/#{arity}, but it is not exported"
      end
    end
  end

  defp doc_body_for(module, fun, arity) do
    {:docs_v1, _, _, _, _, _, function_docs} = Code.fetch_docs(module)

    Enum.find_value(function_docs, fn
      {{:function, ^fun, ^arity}, _line, _sig, %{"en" => body}, _meta} -> body
      _ -> nil
    end)
  end
end
