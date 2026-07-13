defmodule ALLM.ChatRequestParamsTest do
  @moduledoc """
  Phase 21.4 — proves `Chat.build_request/4` folds resolved sampling params
  (`max_tokens`/`temperature`) from `engine.params` + call opts onto the built
  `%Request{}`, so `chat/3`, `stream/3`, and `Session.*` honor them instead of
  silently shipping the adapter's `max_tokens` default (e.g. Anthropic 1024).

  Orchestration is driven by `ALLM.Providers.Fake` (§31), which forwards the
  request it received to the test pid via its `:record` hook. The wire proof is
  a direct `ALLM.Providers.Anthropic.to_anthropic_request_body/1` assertion (no
  network). Spec §6.3 (param resolution), §10 (request building).
  """
  use ExUnit.Case, async: true

  alias ALLM.{Engine, Request, StreamRunner}
  alias ALLM.Providers.{Anthropic, Fake, OpenAI}

  @script [{:text, "ok"}, {:finish, :stop}]

  defp fake_engine(params) do
    Engine.new(
      adapter: Fake,
      model: "fake:m",
      params: params,
      adapter_opts: [script: @script, record: self()]
    )
  end

  defp thread, do: [ALLM.user("hi")]

  # Validation-safe probe values for the drift-guard test: some carried keys
  # are validated by chat/3 before build_request/4 runs (e.g. :mode, :max_turns),
  # so a bare marker atom would raise before we can observe request.options.
  defp probe_value(:mode), do: :auto
  defp probe_value(:max_turns), do: 5
  defp probe_value(:max_concurrency), do: 1
  # function-typed opts (invoked when present, regardless of leak assertion)
  defp probe_value(:on_event), do: fn _ -> :ok end
  defp probe_value(:on_tool_error), do: fn _, _ -> :halt end
  defp probe_value(_), do: :__probe__

  # Pull the %Request{} the Fake adapter received via its :record hook.
  defp recorded_request do
    assert_receive {:allm_fake_record, %Request{} = req, _opts}
    req
  end

  describe "chat/3 (non-streaming) — engine.params" do
    test "engine.params[:max_tokens] reaches request.max_tokens" do
      engine = fake_engine(%{max_tokens: 4096})
      assert {:ok, _} = ALLM.chat(engine, thread())
      assert recorded_request().max_tokens == 4096
    end

    test "engine.params[:temperature] reaches request.temperature" do
      engine = fake_engine(%{temperature: 0.3})
      assert {:ok, _} = ALLM.chat(engine, thread())
      assert recorded_request().temperature == 0.3
    end

    test "unset max_tokens leaves request.max_tokens == nil (adapter default is a floor)" do
      engine = fake_engine(%{})
      assert {:ok, _} = ALLM.chat(engine, thread())
      req = recorded_request()
      assert req.max_tokens == nil
      assert req.temperature == nil
    end

    test "engine.params[:top_p] rides on request.options (opaque param passthrough)" do
      engine = fake_engine(%{top_p: 0.9})
      assert {:ok, _} = ALLM.chat(engine, thread())
      assert recorded_request().options == %{top_p: 0.9}
    end
  end

  describe "chat/3 (non-streaming) — call-opt precedence" do
    test "call-opt max_tokens overrides engine.params[:max_tokens]" do
      engine = fake_engine(%{max_tokens: 4096})
      assert {:ok, _} = ALLM.chat(engine, thread(), max_tokens: 2048)
      assert recorded_request().max_tokens == 2048
    end

    test "call-opt temperature overrides engine.params[:temperature]" do
      engine = fake_engine(%{temperature: 0.3})
      assert {:ok, _} = ALLM.chat(engine, thread(), temperature: 0.9)
      assert recorded_request().temperature == 0.9
    end

    test "orchestration/request-carried opts never leak into request.options" do
      engine = fake_engine(%{max_tokens: 128})

      assert {:ok, _} =
               ALLM.chat(engine, thread(),
                 max_turns: 3,
                 mode: :auto,
                 tool_choice: :auto,
                 top_p: 0.5
               )

      req = recorded_request()
      # only the genuine body param survives; tool_choice lands on its typed
      # field, not options; max_turns/mode are consumed upstream.
      assert req.options == %{top_p: 0.5}
      assert req.tool_choice == :auto
      assert req.max_tokens == 128
    end

    test "reasoning-control opts never leak into request.options (Responses double-route guard)" do
      # Pre-fix regression: :reasoning_effort double-routed — it rode
      # request.options AND was re-shaped by OpenAI.merge_reasoning_opts/4,
      # orphaning a raw atom key on the Responses body. It must be stripped.
      engine = fake_engine(%{})

      assert {:ok, _} =
               ALLM.chat(engine, thread(), reasoning_effort: :medium, top_p: 0.9)

      req = recorded_request()
      refute Map.has_key?(req.options, :reasoning_effort)
      assert req.options == %{top_p: 0.9}
    end

    test ":api_key call opt is stripped and never reaches request.options" do
      # Security regression lock: a call-opt api_key is denied by
      # resolve_params/2's @engine_field_keys and must not survive onto the
      # opaque param map that becomes request.options.
      engine = fake_engine(%{})

      assert {:ok, _} =
               ALLM.chat(engine, thread(), api_key: "sk-test-leak", top_p: 0.5)

      req = recorded_request()
      refute Map.has_key?(req.options, :api_key)
      assert req.options == %{top_p: 0.5}
    end

    test "data-driven drift guard: no orchestration/streaming/reasoning key reaches request.options" do
      # Folds the UNION of every upstream downstream-opt source list through a
      # real chat/3 call and asserts NONE reach request.options. This converts
      # the fail-open denylist into fail-closed-in-test: adding a key to any
      # source list without mirroring it in @request_carried_keys goes red here.
      # :response_format and :tool_choice are EXCLUDED here — they route onto
      # typed %Request{} fields via `extra` (not request.options), require
      # valid shapes, and :response_format triggers two-pass finalize
      # orchestration. Their non-leak into options is proven separately (see
      # the "orchestration/request-carried opts never leak" test).
      carried =
        StreamRunner.orchestration_opts() ++
          StreamRunner.phase_5_layer_opts() ++
          OpenAI.reasoning_opts() ++
          [
            :structured_finalize,
            :structured_finalize_nudge,
            :tool_timeout,
            :on_tool_error,
            :max_concurrency,
            :session_id
          ]

      # Give each carried key a value that passes upstream validation (some
      # are validated before build_request/4); add one genuine body param that
      # MUST survive so we also prove we don't over-strip.
      opts =
        Enum.map(carried, fn k -> {k, probe_value(k)} end) ++ [top_p: 0.7]

      engine = fake_engine(%{})
      assert {:ok, _} = ALLM.chat(engine, thread(), opts)

      req = recorded_request()

      leaked = Enum.filter(carried, &Map.has_key?(req.options, &1))
      assert leaked == [], "these opts leaked onto request.options: #{inspect(leaked)}"
      assert req.options[:top_p] == 0.7
    end

    test "local reasoning-control copy stays in sync with OpenAI.reasoning_opts/0" do
      # The reasoning keys are listed locally in @request_carried_keys (to keep
      # the neutral orchestration layer decoupled from a provider); this asserts
      # the local copy never drifts from the provider's source-of-truth list.
      assert OpenAI.reasoning_opts() == [:reasoning_effort, :reasoning_summary, :verbosity]
    end
  end

  describe "stream/3 (streaming) — matrix-identical to chat/3" do
    test "engine.params[:max_tokens] reaches request.max_tokens on the streaming path" do
      engine = fake_engine(%{max_tokens: 4096})
      assert {:ok, stream} = ALLM.stream(engine, thread())
      # force the stream so the adapter dispatches (and records the request)
      Enum.to_list(stream)
      assert recorded_request().max_tokens == 4096
    end

    test "call-opt max_tokens overrides engine.params on the streaming path" do
      engine = fake_engine(%{max_tokens: 4096})
      assert {:ok, stream} = ALLM.stream(engine, thread(), max_tokens: 2048)
      Enum.to_list(stream)
      assert recorded_request().max_tokens == 2048
    end
  end

  describe "Session.* — stateful path" do
    test "Session.reply carries engine.params[:max_tokens] to the built request" do
      # start + reply are two adapter turns on one per-engine cursor -> scripts:.
      engine =
        Engine.new(
          adapter: Fake,
          model: "fake:m",
          params: %{max_tokens: 4096},
          adapter_opts: [scripts: [@script, @script], record: self()]
        )

      assert {:ok, session, _} = ALLM.Session.start(engine, thread())
      # drain the start turn's record message
      _ = recorded_request()

      assert {:ok, _session, _} = ALLM.Session.reply(engine, session, "again")
      assert recorded_request().max_tokens == 4096
    end
  end

  describe "wire proof — Anthropic body-builder (no network)" do
    test "to_anthropic_request_body/1 emits the configured max_tokens, not 1024" do
      req = Request.new(thread(), max_tokens: 4096)
      body = Anthropic.to_anthropic_request_body(req)
      assert body["max_tokens"] == 4096
    end

    test "unset max_tokens still floors at the adapter default (1024)" do
      req = Request.new(thread(), max_tokens: nil)
      body = Anthropic.to_anthropic_request_body(req)
      assert body["max_tokens"] == 1024
    end

    test "opaque options reach the Anthropic body via Map.merge" do
      req = Request.new(thread(), max_tokens: 4096, options: %{top_p: 0.9})
      body = Anthropic.to_anthropic_request_body(req)
      assert body["top_p"] == 0.9
    end
  end

  describe "wire proof — OpenAI Responses body-builder (two-translator rule)" do
    # After the Phase 21.4 fix, chat.ex strips reasoning keys from
    # request.options, so reasoning reaches the translator ONLY via opts. This
    # proves both translators then emit a clean body — the Responses translator
    # (the endpoint where the leak manifested) emits only the encoded
    # `reasoning` map with NO orphaned raw `reasoning_effort` key.
    test "Responses body carries the encoded reasoning map and no raw reasoning_effort" do
      # options is clean (reasoning stripped by chat.ex); reasoning arrives via opts.
      req = Request.new(thread(), model: "gpt-5", options: %{})
      body = OpenAI.to_openai_request_body(req, :responses, reasoning_effort: :medium)

      assert body["reasoning"] == %{effort: "medium"}
      refute Map.has_key?(body, "reasoning_effort")
    end

    test "chat_completions body carries string-valued reasoning_effort, never a raw atom" do
      req = Request.new(thread(), model: "gpt-5", options: %{})
      body = OpenAI.to_openai_request_body(req, :chat_completions, reasoning_effort: :medium)

      assert body["reasoning_effort"] == "medium"
      refute body["reasoning_effort"] == :medium
    end
  end
end
