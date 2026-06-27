defmodule ALLM.FakeFootgunFacadeTest do
  @moduledoc """
  Phase 2 regression — the Unllmtd content-hash cursor footgun, fixed at the
  façade (§6, §31).

  Two engines built with content-equal `:scripts` / `:stream_script` values and
  driven through the public façade (`ALLM.generate/3`, `ALLM.stream_generate/3`)
  no longer share the `ALLM.Providers.Fake` process-dict cursor: each engine's
  first call reads index 0. The cursor key is now `engine.id` (injected into
  `adapter_opts[:cursor_key]` by `ALLM.StreamRunner.build_dispatch_opts/2`),
  not `:erlang.phash2(scripts)`.

  These tests deliberately run BOTH engines in the SAME process (no
  `Task.async/1` isolation) — that is the exact shape that used to collide and
  is the load-bearing proof the default footgun is gone.

  Reproduces Unllmtd 8.x (two engines, content-equal scripts) and 8.3 (one
  engine, multi-call cursor advances in order).
  """

  use ExUnit.Case, async: true

  alias ALLM.{Engine, Response, StreamCollector}
  alias ALLM.Providers.Fake

  defp engine(adapter_opts), do: Engine.new(adapter: Fake, adapter_opts: adapter_opts)

  defp collect(stream) do
    stream
    |> Enum.reduce(StreamCollector.new(), fn e, s -> StreamCollector.apply_event(s, e) end)
    |> StreamCollector.to_response()
  end

  test "two engines, content-equal :scripts via ALLM.generate/3 → each first call reads index 0" do
    scripts = [
      [{:text, "a"}, {:finish, :stop}],
      [{:text, "b"}, {:finish, :stop}]
    ]

    e1 = engine(scripts: scripts)
    e2 = engine(scripts: scripts)

    # Distinct identity for content-equal engines.
    assert e1.id != e2.id

    assert {:ok, %Response{output_text: "a"}} = ALLM.generate(e1, ALLM.request([ALLM.user("hi")]))

    # Was "b" before the fix (shared phash2 cursor); now "a".
    assert {:ok, %Response{output_text: "a"}} = ALLM.generate(e2, ALLM.request([ALLM.user("hi")]))
  end

  test "two engines, content-equal :stream_script via ALLM.stream_generate/3 → each first call reads index 0" do
    stream_script = [
      [{:text_delta, "a"}, {:finish, :stop}],
      [{:text_delta, "b"}, {:finish, :stop}]
    ]

    e1 = engine(stream_script: stream_script)
    e2 = engine(stream_script: stream_script)

    assert {:ok, stream1} = ALLM.stream_generate(e1, ALLM.request([ALLM.user("hi")]))
    assert %Response{output_text: "a"} = collect(stream1)

    assert {:ok, stream2} = ALLM.stream_generate(e2, ALLM.request([ALLM.user("hi")]))
    assert %Response{output_text: "a"} = collect(stream2)
  end

  test "one engine, generate then stream_generate → cursor advances 0 then 1 (in order)" do
    # Same engine, two calls — the intended multi-call behaviour is preserved
    # (cursor advances across calls because identity is stable per engine).
    e =
      engine(
        scripts: [
          [{:text, "first"}, {:finish, :stop}],
          [{:text, "second"}, {:finish, :stop}]
        ],
        stream_script: [
          [{:text_delta, "first"}, {:finish, :stop}],
          [{:text_delta, "second"}, {:finish, :stop}]
        ]
      )

    assert {:ok, %Response{output_text: "first"}} =
             ALLM.generate(e, ALLM.request([ALLM.user("hi")]))

    assert {:ok, stream} = ALLM.stream_generate(e, ALLM.request([ALLM.user("hi")]))
    assert %Response{output_text: "second"} = collect(stream)
  end

  test "explicit script_cursor still overrides cursor_key at the façade (Agent pid wins)" do
    scripts = [
      [{:text, "a"}, {:finish, :stop}],
      [{:text, "b"}, {:finish, :stop}]
    ]

    cursor = Fake.start_script_cursor()

    e = engine(scripts: scripts, script_cursor: cursor)

    # The Agent pid takes precedence over the injected cursor_key, so the
    # cursor advances across calls on the SAME engine via the Agent.
    assert {:ok, %Response{output_text: "a"}} = ALLM.generate(e, ALLM.request([ALLM.user("hi")]))
    assert Fake.cursor_index(cursor) == 1

    assert {:ok, %Response{output_text: "b"}} = ALLM.generate(e, ALLM.request([ALLM.user("hi")]))
    assert Fake.cursor_index(cursor) == 2
  end
end
