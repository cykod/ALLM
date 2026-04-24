defmodule ALLM.StreamEquivalenceTest do
  @moduledoc """
  Sub-phase 5.4 — stream-equivalence property test (spec §3).

  The load-bearing correctness invariant for Phase 5: for every Fake
  script drawn from the §31 vocabulary (excluding timing noise and
  short-circuit error paths — covered by a separate mid-stream-error
  property), `ALLM.generate/3` returns a `%Response{}` equal to
  `ALLM.stream_generate/3 |> reduce(StreamCollector) |> to_response`.

  Each iteration isolates Fake's per-process cursor via `Task.async/1` +
  `Task.await/1`, so the `generate/3` and `stream_generate/3` calls see
  separate fresh process-dict cursors and don't collide on the cursor
  key derived from the script content.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :property

  alias ALLM.{Engine, Message, Request, Response, StreamCollector}
  alias ALLM.Error.AdapterError
  alias ALLM.Providers.Fake

  defp fake_request, do: Request.new([%Message{role: :user, content: "hi"}])

  defp engine_of(script) do
    Engine.new(adapter: Fake, adapter_opts: [script: script])
  end

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  # A single spec §31 entry — EXCLUDES :delay/:sleep (timing noise),
  # :error/:preflight_error (short-circuit paths), and :raw_chunk with
  # non-usage payload (filter-dropped by default, no user-visible effect).
  # :usage entries use explicit integer keys so struct!(Usage, map) doesn't
  # KeyError on spurious keys.
  defp spec31_entry_gen do
    StreamData.one_of([
      StreamData.bind(StreamData.string(:printable, min_length: 1, max_length: 8), fn s ->
        StreamData.constant({:text, s})
      end),
      StreamData.bind(
        StreamData.tuple({
          StreamData.integer(1..9),
          StreamData.string(Enum.concat([?a..?z, [?_]]), min_length: 1, max_length: 6)
        }),
        fn {n, name} ->
          id = "id_#{n}"
          StreamData.constant({:tool_call, id: id, name: name, arguments: %{}})
        end
      ),
      StreamData.bind(
        StreamData.tuple({
          StreamData.integer(1..9),
          StreamData.string(:printable, min_length: 1, max_length: 8)
        }),
        fn {n, delta} ->
          id = "id_#{n}"
          StreamData.constant({:tool_call_delta, id: id, arguments_delta: delta})
        end
      ),
      StreamData.bind(
        StreamData.tuple({StreamData.integer(0..100), StreamData.integer(0..100)}),
        fn {input, output} ->
          StreamData.constant({:usage, %{input_tokens: input, output_tokens: output}})
        end
      )
    ])
  end

  defp finish_reason_gen do
    StreamData.member_of([:stop, :length, :tool_calls, :content_filter])
  end

  # A list of entries terminated by {:finish, reason}.
  defp spec31_script_gen do
    StreamData.bind(
      StreamData.tuple({
        StreamData.list_of(spec31_entry_gen(), min_length: 0, max_length: 10),
        finish_reason_gen()
      }),
      fn {entries, reason} ->
        StreamData.constant(entries ++ [{:finish, reason}])
      end
    )
  end

  defp adapter_error_reason_gen do
    StreamData.member_of(AdapterError.legal_reasons())
  end

  # A script ending in a {:error, reason} atom — the short-circuit path.
  defp mid_stream_error_script_gen do
    StreamData.bind(
      StreamData.tuple({
        StreamData.list_of(spec31_entry_gen(), min_length: 0, max_length: 5),
        adapter_error_reason_gen()
      }),
      fn {entries, reason} ->
        StreamData.constant(entries ++ [{:error, reason}])
      end
    )
  end

  # ---------------------------------------------------------------------------
  # Helpers — run calls in isolated processes so each sees a fresh
  # process-dict cursor. Fake's default cursor lives in the reducing
  # process's dictionary keyed by :erlang.phash2(scripts), so running
  # `generate/3` then `stream_generate/3` in the same process against the
  # same content-equal script would bump the cursor and script-exhaust the
  # second call. Task.async/1 gives each call its own process.
  # ---------------------------------------------------------------------------

  defp run_generate(script) do
    Task.async(fn ->
      engine = engine_of(script)
      ALLM.generate(engine, fake_request(), include_raw_chunks: true)
    end)
    |> Task.await(:timer.seconds(5))
  end

  defp run_stream_and_collect(script) do
    Task.async(fn -> do_stream_and_collect(script) end)
    |> Task.await(:timer.seconds(5))
  end

  defp do_stream_and_collect(script) do
    engine = engine_of(script)
    opened = ALLM.stream_generate(engine, fake_request(), include_raw_chunks: true)
    collect_if_ok(opened)
  end

  defp collect_if_ok({:error, _} = err), do: err

  defp collect_if_ok({:ok, stream}) do
    response =
      stream
      |> Enum.reduce(StreamCollector.new(), fn e, s ->
        StreamCollector.apply_event(s, e)
      end)
      |> StreamCollector.to_response()

    {:ok, response}
  end

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  property "generate/3 ≡ stream_generate/3 |> collect" do
    check all(script <- spec31_script_gen(), max_runs: 100) do
      assert {:ok, %Response{} = gen_resp} = run_generate(script)
      assert {:ok, %Response{} = collected_resp} = run_stream_and_collect(script)

      assert gen_resp == collected_resp
    end
  end

  property "mid-stream {:error, reason} maps to finish_reason: :error + metadata.error" do
    check all(script <- mid_stream_error_script_gen(), max_runs: 50) do
      assert {:ok, %Response{} = resp} = run_generate(script)

      assert resp.finish_reason == :error

      reason = script |> List.last() |> elem(1)
      assert %AdapterError{reason: ^reason} = resp.metadata.error
    end
  end
end
