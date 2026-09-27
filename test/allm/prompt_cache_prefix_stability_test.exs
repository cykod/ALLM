defmodule ALLM.PromptCachePrefixStabilityTest do
  @moduledoc """
  Pins the append-prefix property that makes provider prompt caching work
  across the turns of a `Session`: after each turn, re-translating the grown
  thread must leave every non-message part of the wire body byte-identical and
  must only *append* to the message array.

  For each consecutive pair of turns (N, N+1) and each of the four
  translators (OpenAI Chat Completions, OpenAI Responses, Anthropic, Gemini):

    (a) the body with its message-array key removed is byte-identical after
        `Jason.encode!/1`;
    (b) the decoded message array of N is an element-wise prefix of N+1's.

  Bodies are built from separately constructed `%Request{}`s — the same term
  is never compared with itself. The negative control stamps the turn index
  into the system text and asserts the helper reports the violation, so the
  helper cannot pass vacuously. No network: the body builders are called
  directly.
  """
  use ExUnit.Case, async: true

  alias ALLM.{Engine, Request, Session, Tool}
  alias ALLM.Providers.{Anthropic, Fake, Gemini, OpenAI}

  @prompt_cache %{key: "s", retention: :long}

  @cache_fields %{
    openai_chat_completions: "prompt_cache_key",
    openai_responses: "prompt_cache_key",
    anthropic: "cache_control",
    gemini: nil
  }

  # {name, message-array key, body builder}
  @translators [
    {:openai_chat_completions, "messages", &__MODULE__.openai_chat_completions/1},
    {:openai_responses, "input", &__MODULE__.openai_responses/1},
    {:anthropic, "messages", &Anthropic.to_anthropic_request_body/1},
    {:gemini, "contents", &__MODULE__.gemini/1}
  ]

  @doc false
  def openai_chat_completions(req), do: OpenAI.to_openai_request_body(req, :chat_completions, [])
  @doc false
  def openai_responses(req), do: OpenAI.to_openai_request_body(req, :responses, [])
  @doc false
  def gemini(req), do: Gemini.to_gemini_request_body(req, [])

  defp lookup_tool do
    Tool.new(
      name: "lookup",
      description: "Look up a recipe step",
      schema: %{
        "type" => "object",
        "properties" => %{"step" => %{"type" => "integer"}},
        "required" => ["step"]
      },
      handler: fn %{"step" => n} -> {:ok, %{step: n, text: "Braise for 90 minutes"}} end
    )
  end

  # Three turns over Fake: plain text, a tool call + tool result, plain text.
  # Returns the thread messages after each turn.
  defp session_snapshots do
    engine =
      Engine.new(
        adapter: Fake,
        model: "fake:m",
        tools: [lookup_tool()],
        adapter_opts: [
          scripts: [
            [{:text, "Let's start the braise."}, {:finish, :stop}],
            [
              {:tool_call, id: "call_0", name: "lookup", arguments: %{"step" => 3}},
              {:finish, :tool_calls}
            ],
            [{:text, "Step 3: braise for 90 minutes."}, {:finish, :stop}],
            [{:text, "Yes, lid on."}, {:finish, :stop}]
          ]
        ]
      )

    {:ok, s1, _} =
      Session.start(engine, [ALLM.system("You are a cooking assistant."), ALLM.user("Begin")])

    {:ok, s2, _} = Session.reply(engine, s1, "What is step 3?")
    {:ok, s3, _} = Session.reply(engine, s2, "Lid on?")

    Enum.map([s1, s2, s3], & &1.thread.messages)
  end

  # A fresh %Request{} (and fresh tool) per call: bodies under comparison
  # never share a term.
  defp build_request(messages) do
    Request.new(messages,
      model: "gpt-5.6",
      tools: [lookup_tool()],
      prompt_cache: @prompt_cache
    )
  end

  @doc false
  # Returns the list of `{pair_index, violation}` for a sequence of bodies;
  # `[]` means the append-prefix property holds for every consecutive pair.
  def prefix_violations(bodies, message_key) do
    bodies
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.with_index()
    |> Enum.flat_map(fn {[a, b], n} -> pair_violations(a, b, message_key, n) end)
  end

  defp pair_violations(a, b, key, n) do
    rest_a = a |> Map.delete(key) |> Jason.encode!()
    rest_b = b |> Map.delete(key) |> Jason.encode!()
    msgs_a = a |> Map.fetch!(key) |> Jason.encode!() |> Jason.decode!()
    msgs_b = b |> Map.fetch!(key) |> Jason.encode!() |> Jason.decode!()

    [
      {rest_a == rest_b, {n, :non_message_body_changed}},
      {length(msgs_b) > length(msgs_a) and Enum.take(msgs_b, length(msgs_a)) == msgs_a,
       {n, :message_array_not_an_append}}
    ]
    |> Enum.reject(fn {ok?, _} -> ok? end)
    |> Enum.map(fn {_, violation} -> violation end)
  end

  test "premise: the snapshots grow every turn and include a tool round trip" do
    snapshots = session_snapshots()
    lengths = Enum.map(snapshots, &length/1)
    assert lengths == Enum.sort(lengths) and Enum.uniq(lengths) == lengths
    assert Enum.any?(List.last(snapshots), &(&1.role == :tool))
    assert Enum.any?(List.last(snapshots), &(&1.role == :system))
  end

  for {name, key, _builder} <- @translators do
    test "#{name}: every turn appends to the message array and leaves the rest byte-identical" do
      {_, key, builder} = List.keyfind(@translators, unquote(name), 0)
      assert key == unquote(key)

      bodies = Enum.map(session_snapshots(), &builder.(build_request(&1)))

      # premise: the translated body carries the cache field (Gemini has
      # none), so the "rest" compared in (a) includes it.
      if cache_field = @cache_fields[unquote(name)] do
        assert Enum.all?(bodies, &Map.has_key?(&1, cache_field))
      end

      assert prefix_violations(bodies, key) == []
    end
  end

  describe "negative control" do
    # Wraps a translator so the system text carries the turn index — the
    # classic cache-busting mistake (a timestamp or counter in the prefix).
    defp stamp_turn(messages, turn) do
      Enum.map(messages, fn
        %{role: :system} = m -> %{m | content: "#{m.content} (turn #{turn})"}
        m -> m
      end)
    end

    for {name, _key, _builder} <- @translators do
      test "#{name}: a turn-index stamp in the system text is reported" do
        {_, key, builder} = List.keyfind(@translators, unquote(name), 0)

        bodies =
          session_snapshots()
          |> Enum.with_index()
          |> Enum.map(fn {msgs, turn} -> builder.(build_request(stamp_turn(msgs, turn))) end)

        violations = prefix_violations(bodies, key)
        assert violations != []
        assert Enum.map(violations, &elem(&1, 0)) |> Enum.uniq() == [0, 1]
      end
    end
  end
end
