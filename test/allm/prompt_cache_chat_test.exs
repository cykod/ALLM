defmodule ALLM.PromptCacheChatTest do
  @moduledoc """
  `prompt_cache:` resolution in `Chat.build_request/4`: call opts and
  `engine.params` reach the typed `%Request{prompt_cache: _}` field, the key
  defaults to `:session_id` only when caching is asked for, and every
  normalization row of the design's call-opt table is pinned on both the
  non-streaming (`chat/3`, `step/3`, `Session.reply/4`) and streaming
  (`stream/3`, `stream_step/3`, `Session.stream_reply/4`) paths.

  Vehicle: `ALLM.Providers.Fake` with `adapter_opts[:record]`, which sends the
  `%Request{}` it received before interpreting the script.
  """
  use ExUnit.Case, async: true

  alias ALLM.{Engine, Request, Serializer, Session, Thread}
  alias ALLM.Error.ValidationError
  alias ALLM.Providers.Fake

  @script [{:text, "ok"}, {:finish, :stop}]

  defp fake_engine(params \\ %{}) do
    Engine.new(
      adapter: Fake,
      model: "fake:m",
      params: params,
      adapter_opts: [script: @script, record: self()]
    )
  end

  defp thread, do: [ALLM.user("hi")]

  defp recorded_request do
    assert_receive {:allm_fake_record, %Request{} = req, _opts}
    req
  end

  # Drive one path and return the %Request{} the adapter saw.
  defp run(:chat, engine, opts) do
    assert {:ok, _} = ALLM.chat(engine, thread(), opts)
    recorded_request()
  end

  defp run(:stream, engine, opts) do
    assert {:ok, stream} = ALLM.stream(engine, thread(), opts)
    _ = Enum.to_list(stream)
    recorded_request()
  end

  defp run(:step, engine, opts) do
    assert {:ok, _} = ALLM.step(engine, thread(), opts)
    recorded_request()
  end

  defp run(:stream_step, engine, opts) do
    assert {:ok, stream} = ALLM.stream_step(engine, thread(), opts)
    _ = Enum.to_list(stream)
    recorded_request()
  end

  defp prompt_cache_errors(%ValidationError{errors: errors}),
    do: Enum.filter(errors, &match?({:prompt_cache, _}, &1))

  for path <- [:chat, :stream] do
    describe "#{path} — R1..R5" do
      test "R1: no opt anywhere → nil" do
        assert run(unquote(path), fake_engine(), []).prompt_cache == nil
      end

      test "R2: engine param %{retention: :long} + session_id → key defaults to the session id" do
        req =
          run(unquote(path), fake_engine(%{prompt_cache: %{retention: :long}}), session_id: "s1")

        assert req.prompt_cache == %{key: "s1", retention: :long}
        refute Map.has_key?(req.options, :prompt_cache)
      end

      test "R3: call opt wins over engine param; missing retention → :short" do
        engine = fake_engine(%{prompt_cache: %{retention: :long}})
        req = run(unquote(path), engine, prompt_cache: %{key: "x"}, session_id: "s1")
        assert req.prompt_cache == %{key: "x", retention: :short}
      end

      test "R4: true with no session_id → %{key: nil, retention: :short}" do
        assert run(unquote(path), fake_engine(), prompt_cache: true).prompt_cache ==
                 %{key: nil, retention: :short}
      end

      test "R5: :bogus → {:error, %ValidationError{}} naming :prompt_cache" do
        engine = fake_engine()

        result =
          case unquote(path) do
            :chat -> ALLM.chat(engine, thread(), prompt_cache: :bogus)
            :stream -> ALLM.stream(engine, thread(), prompt_cache: :bogus)
          end

        assert {:error, %ValidationError{} = err} = result
        assert prompt_cache_errors(err) == [{:prompt_cache, :invalid_shape}]
        refute_received {:allm_fake_record, _, _}
      end
    end
  end

  describe "normalization table (chat/3)" do
    test "false → nil, and an explicit call-opt nil overrides an engine param" do
      assert run(:chat, fake_engine(), prompt_cache: false, session_id: "s1").prompt_cache == nil

      engine = fake_engine(%{prompt_cache: true})
      assert run(:chat, engine, prompt_cache: nil, session_id: "s1").prompt_cache == nil
    end

    test "session_id is NOT used when caching was not asked for" do
      assert run(:chat, fake_engine(), session_id: "s1").prompt_cache == nil
    end

    test "true with a session_id → key is the session id" do
      assert run(:chat, fake_engine(), prompt_cache: true, session_id: "s1").prompt_cache ==
               %{key: "s1", retention: :short}
    end

    test "%{} and [] behave like true" do
      for value <- [%{}, []] do
        assert run(:chat, fake_engine(), prompt_cache: value, session_id: "s1").prompt_cache ==
                 %{key: "s1", retention: :short}
      end
    end

    test "keyword form is accepted" do
      assert run(:chat, fake_engine(), prompt_cache: [key: "k", retention: :long]).prompt_cache ==
               %{key: "k", retention: :long}
    end

    test "explicit nil key falls back to the session id" do
      req = run(:chat, fake_engine(), prompt_cache: %{key: nil, retention: :long}, session_id: "s1")
      assert req.prompt_cache == %{key: "s1", retention: :long}
    end

    test "an explicit key is never replaced by the session id" do
      req = run(:chat, fake_engine(), prompt_cache: %{key: "mine"}, session_id: "s1")
      assert req.prompt_cache == %{key: "mine", retention: :short}
    end

    test "a non-binary session_id is not used as the key" do
      assert run(:chat, fake_engine(), prompt_cache: true, session_id: :atom_id).prompt_cache ==
               %{key: nil, retention: :short}
    end

    test "an empty-string session_id is not used as the key" do
      assert run(:chat, fake_engine(), prompt_cache: true, session_id: "").prompt_cache ==
               %{key: nil, retention: :short}
    end

    test "an explicit empty-string key is still rejected" do
      assert {:error, %ValidationError{} = err} =
               ALLM.chat(fake_engine(), thread(), prompt_cache: %{key: ""}, session_id: "s1")

      assert prompt_cache_errors(err) == [{:prompt_cache, :invalid_shape}]
    end

    test "string-keyed map is converted, retention decoded" do
      req =
        run(:chat, fake_engine(), prompt_cache: %{"key" => "k", "retention" => "long"})

      assert req.prompt_cache == %{key: "k", retention: :long}
    end

    test "string-keyed map with only retention picks up the session id" do
      req = run(:chat, fake_engine(), prompt_cache: %{"retention" => "short"}, session_id: "s1")
      assert req.prompt_cache == %{key: "s1", retention: :short}
    end

    test "string-keyed map with an unknown retention string is rejected, not atomized" do
      assert {:error, %ValidationError{} = err} =
               ALLM.chat(fake_engine(), thread(),
                 prompt_cache: %{"retention" => "forever-and-ever-27-4"}
               )

      assert prompt_cache_errors(err) == [{:prompt_cache, :invalid_shape}]
      assert_raise ArgumentError, fn -> String.to_existing_atom("forever-and-ever-27-4") end
    end

    test "only a MISSING retention defaults to :short; an explicit nil is rejected" do
      assert {:error, %ValidationError{} = err} =
               ALLM.chat(fake_engine(), thread(), prompt_cache: %{key: "k", retention: nil})

      assert prompt_cache_errors(err) == [{:prompt_cache, :invalid_shape}]
    end

    test "an unknown retention atom is rejected" do
      assert {:error, %ValidationError{}} =
               ALLM.chat(fake_engine(), thread(), prompt_cache: %{retention: :forever})
    end

    test "a non-keyword list is passed through and rejected" do
      assert {:error, %ValidationError{} = err} =
               ALLM.chat(fake_engine(), thread(), prompt_cache: ["k"])

      assert prompt_cache_errors(err) == [{:prompt_cache, :invalid_shape}]
    end

    test "R9: extra keys are kept, so validation rejects them" do
      assert {:error, %ValidationError{} = err} =
               ALLM.chat(fake_engine(), thread(), prompt_cache: %{key: "x", foo: 1})

      assert prompt_cache_errors(err) == [{:prompt_cache, :invalid_shape}]
    end

    test "R8: JSON round-tripped engine params still resolve" do
      # adapter_opts (a Fake script of tuples) is not JSON-encodable; the
      # engine is serialized without it and the script is re-attached.
      engine =
        Engine.new(adapter: Fake, model: "fake:m", params: %{prompt_cache: %{retention: :long}})

      {:ok, restored} = engine |> Serializer.to_json!() |> Serializer.from_json()

      # premise guard: the round trip leaves the nested map string-keyed, so
      # this test exercises the string-keyed normalization row.
      assert restored.params.prompt_cache == %{"retention" => "long"}

      restored = %{restored | adapter_opts: [script: @script, record: self()]}
      req = run(:chat, restored, session_id: "s1")
      assert req.prompt_cache == %{key: "s1", retention: :long}
    end
  end

  describe "R10 — step/3 and stream_step/3" do
    for path <- [:step, :stream_step] do
      test "#{path}: engine param + session_id" do
        engine = fake_engine(%{prompt_cache: %{retention: :long}})
        req = run(unquote(path), engine, session_id: "s1")
        assert req.prompt_cache == %{key: "s1", retention: :long}
        refute Map.has_key?(req.options, :prompt_cache)
      end
    end
  end

  describe "R6/R7 — Session.reply/4 and stream_reply/4" do
    defp session(id), do: Session.new(id: id, thread: Thread.new(messages: thread()))

    defp reply(:reply, engine, s) do
      assert {:ok, _, _} = Session.reply(engine, s, "again")
      recorded_request()
    end

    defp reply(:stream_reply, engine, s) do
      assert {:ok, stream} = Session.stream_reply(engine, s, "again")
      _ = Enum.to_list(stream)
      recorded_request()
    end

    for path <- [:reply, :stream_reply] do
      test "R6 #{path}: session.id becomes the key" do
        req = reply(unquote(path), fake_engine(%{prompt_cache: true}), session("sess-9"))
        assert req.prompt_cache == %{key: "sess-9", retention: :short}
      end

      test "R7 #{path}: nil session id → nil key" do
        req = reply(unquote(path), fake_engine(%{prompt_cache: true}), session(nil))
        assert req.prompt_cache == %{key: nil, retention: :short}
      end

      test "#{path}: empty-string session id → nil key, not a validation error" do
        req = reply(unquote(path), fake_engine(%{prompt_cache: true}), session(""))
        assert req.prompt_cache == %{key: nil, retention: :short}
      end
    end
  end
end
