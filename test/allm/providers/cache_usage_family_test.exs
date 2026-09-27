defmodule ALLM.Providers.CacheUsageFamilyTest do
  @moduledoc """
  Cached-prompt usage across the chat-adapter family: OpenAI Chat
  Completions, OpenAI Responses, Anthropic and Gemini.

  Each row pairs a non-streaming body (decoded through the adapter's public
  decode seam) with a streaming fixture of the same counts (replayed through
  `ALLM.Test.FinchStub` and folded by `ALLM.StreamCollector`). The expected
  integers are literals in the row, never recomputed by the code under test.

  ## Relaxations

  | Field path | Relaxation | Justification | Risk |
  |---|---|---|---|
  | `%Usage{}` (every field, `extra` included) | none — both arms identical | streaming sites build their payload from the non-streaming decoder | — |

  Keys are passed per call (`api_key:`), never through `ALLM.Keys.put/2`.
  """
  use ExUnit.Case, async: true

  alias ALLM.Message
  alias ALLM.Providers.{Anthropic, Gemini, OpenAI}
  alias ALLM.Request
  alias ALLM.StreamCollector
  alias ALLM.Test.CacheUsageFixtures, as: CF
  alias ALLM.Test.FinchStub
  alias ALLM.Usage

  # {row, adapter, model, api_key, non-streaming decoder, expected}
  @rows [
    {:openai_chat, OpenAI, "gpt-4o-mini", "sk-cache-test", &__MODULE__.decode_chat/2,
     %{input: 2048, cached: 1536, write: 256, output: 20, total: 2068}},
    {:openai_responses, OpenAI, "gpt-5.5", "sk-cache-test", &OpenAI.from_responses_response/2,
     %{input: 3000, cached: 2048, write: 512, output: 50, total: 3050}},
    {:anthropic, Anthropic, "claude-sonnet-4-6", "sk-ant-cache-test",
     &Anthropic.from_anthropic_response/2,
     %{input: 4350, cached: 4000, write: 300, output: 25, total: 4375}},
    {:gemini, Gemini, "gemini-2.5-flash", "AIza-cache-test", &Gemini.decode_response/2,
     %{input: 5000, cached: 4096, write: nil, output: 30, total: 5030}}
  ]

  @doc false
  def decode_chat(body, _opts), do: OpenAI.from_openai_response(body, :chat_completions)

  defp stream_usage(adapter, model, key, chunks) do
    stub = FinchStub.install(chunks, [])
    req = Request.new([%Message{role: :user, content: "hi"}], model: model, max_tokens: 64)

    {:ok, stream} =
      adapter.stream(req, api_key: key, finch_module: FinchStub, finch_stub_ref: stub)

    state = Enum.reduce(stream, StreamCollector.new(), &StreamCollector.apply_event(&2, &1))
    StreamCollector.to_response(state).usage
  end

  defp assert_invariant(%Usage{} = u, label) do
    assert is_integer(u.input_tokens) and is_integer(u.cached_input_tokens),
           "#{label}: invariant is vacuous without integer input + cached counts"

    assert u.cached_input_tokens + (u.cache_write_input_tokens || 0) <= u.input_tokens,
           "#{label}: cached + write > input (#{inspect(u)})"
  end

  # Premise guard: the rows below only test the adapters if the fixtures are
  # the synthesized ones this file documents (a re-recorded body with other
  # counts would fail the literal assertions for the wrong reason).
  test "every cache-usage fixture carries the synthesized provenance marker (raw bytes)" do
    for path <- CF.paths() do
      assert CF.synthesized?(path), "#{path} lacks the `synthesized — Phase 27.2` marker"
    end
  end

  for {row, adapter, model, key, decoder, expected} <- @rows do
    @row row
    @adapter adapter
    @model model
    @key key
    @decoder decoder
    @expected expected

    describe "#{row}" do
      test "non-streaming usage reports the fixture's cache counts" do
        u = @decoder.(CF.body(@row), []).usage

        assert u.input_tokens == @expected.input
        assert u.cached_input_tokens == @expected.cached
        assert u.cache_write_input_tokens == @expected.write
        assert u.output_tokens == @expected.output
        assert u.total_tokens == @expected.total
      end

      test "streaming-collected usage equals non-streaming usage field-for-field" do
        non_streamed = @decoder.(CF.body(@row), []).usage
        streamed = stream_usage(@adapter, @model, @key, CF.stream_chunks(@row))

        assert streamed == non_streamed
      end

      test "cached + write <= input holds on both paths" do
        assert_invariant(@decoder.(CF.body(@row), []).usage, "#{@row} non-streaming")

        assert_invariant(
          stream_usage(@adapter, @model, @key, CF.stream_chunks(@row)),
          "#{@row} streaming"
        )
      end
    end
  end

  # A counter the provider did not send stays `nil`: no adapter substitutes
  # `0` for a missing wire field.
  describe "no cache fields on the wire → nil, never 0" do
    test "OpenAI Chat Completions" do
      u =
        OpenAI.from_openai_response(
          %{"choices" => [], "usage" => %{"prompt_tokens" => 9, "completion_tokens" => 1}},
          :chat_completions
        ).usage

      assert {u.cached_input_tokens, u.cache_write_input_tokens} == {nil, nil}
    end

    test "OpenAI Responses" do
      u =
        OpenAI.from_responses_response(
          %{"status" => "completed", "usage" => %{"input_tokens" => 9, "output_tokens" => 1}},
          []
        ).usage

      assert {u.cached_input_tokens, u.cache_write_input_tokens} == {nil, nil}
    end

    test "Anthropic" do
      u =
        Anthropic.from_anthropic_response(
          %{"content" => [], "usage" => %{"input_tokens" => 9, "output_tokens" => 1}},
          []
        ).usage

      assert u.input_tokens == 9
      assert {u.cached_input_tokens, u.cache_write_input_tokens} == {nil, nil}
    end

    test "Gemini" do
      u =
        Gemini.decode_response(
          %{
            "candidates" => [
              %{"content" => %{"role" => "model", "parts" => [%{"text" => "x"}]}}
            ],
            "usageMetadata" => %{"promptTokenCount" => 9, "candidatesTokenCount" => 1}
          },
          []
        ).usage

      assert {u.cached_input_tokens, u.cache_write_input_tokens} == {nil, nil}
    end
  end

  # ---------------------------------------------------------------------------
  # Live recordings (scripts/record_prompt_cache_fixtures.exs)
  # ---------------------------------------------------------------------------

  @recorder "( set -a; . ./.env; set +a; mix run scripts/record_prompt_cache_fixtures.exs )"

  describe "recorded prompt-cache fixtures: provenance" do
    test "the recorded-fixture list equals the prompt_cache_* files on disk, both directions" do
      listed = Enum.sort(CF.recorded_paths())
      found = Enum.sort(CF.discovered_recorded_paths())

      assert listed -- found == [], "listed but missing on disk: #{inspect(listed -- found)}"
      assert found -- listed == [], "on disk but not listed: #{inspect(found -- listed)}"
    end

    for path <- CF.recorded_paths() do
      @path path
      test "#{Path.relative_to(path, "test/fixtures")} is a live recording (raw bytes)" do
        raw = File.read!(@path)

        case Path.extname(@path) do
          ".json" ->
            refute Map.has_key?(Jason.decode!(raw), "_comment"),
                   "#{@path} carries a `_comment` placeholder marker; re-record with #{@recorder}"

          ".sse" ->
            refute raw =~ ~r/^:\s*synthesized/im,
                   "#{@path} carries a `: synthesized` marker; re-record with #{@recorder}"
        end
      end
    end
  end

  describe "recorded prompt-cache fixtures: decoded usage on real data" do
    @responses_hits ["prompt_cache_hit.json", "prompt_cache_hit_gpt6.json"]
    # Derived from the recorded-fixture list, so a new Anthropic recording gets
    # its decoding test without editing a second literal.
    @anthropic_hit ~r{anthropic/messages/recorded/prompt_cache_hit_(.+)\.json$}
    @anthropic_models Enum.flat_map(
                        CF.recorded_paths(),
                        &(Regex.run(@anthropic_hit, &1, capture: :all_but_first) || [])
                      )

    defp recorded(rel), do: CF.recorded_json(Path.join("test/fixtures", rel))

    test "the Anthropic per-model loop below is not empty" do
      assert @anthropic_models != [], "no Anthropic prompt_cache_hit_*.json in CF.recorded_paths/0"
    end

    for file <- @responses_hits do
      @file_name file
      test "OpenAI Responses #{file}: cached count lifted, inclusive input, invariant" do
        body = recorded("openai/responses/recorded/#{@file_name}")
        wire = body["usage"]
        u = OpenAI.from_responses_response(body, []).usage

        assert u.cached_input_tokens == wire["input_tokens_details"]["cached_tokens"]
        assert u.cached_input_tokens > 0
        assert u.cache_write_input_tokens == wire["input_tokens_details"]["cache_write_tokens"]
        assert u.input_tokens == wire["input_tokens"]
        assert_invariant(u, "recorded #{@file_name}")
      end
    end

    for model <- @anthropic_models do
      @model model
      test "Anthropic #{model}: inclusive input_tokens on a real cache hit" do
        body = recorded("anthropic/messages/recorded/prompt_cache_hit_#{@model}.json")
        wire = body["usage"]
        u = Anthropic.from_anthropic_response(body, []).usage

        assert u.cached_input_tokens == wire["cache_read_input_tokens"]
        assert u.cached_input_tokens > 0

        assert u.input_tokens ==
                 wire["input_tokens"] + wire["cache_read_input_tokens"] +
                   wire["cache_creation_input_tokens"]

        assert u.extra["uncached_input_tokens"] == wire["input_tokens"]
        # The falsifier: the raw (exclusive) count is smaller than the read.
        assert wire["input_tokens"] < wire["cache_read_input_tokens"]
        assert_invariant(u, "recorded #{@model}")
      end
    end

    test "Gemini: cachedContentTokenCount lifted, promptTokenCount inclusive" do
      body = recorded("gemini/generate_content/recorded/prompt_cache_hit.json")
      wire = body["usageMetadata"]
      u = Gemini.decode_response(body, []).usage

      assert u.cached_input_tokens == wire["cachedContentTokenCount"]
      assert u.cached_input_tokens > 0
      assert u.cache_write_input_tokens == nil
      assert u.input_tokens == wire["promptTokenCount"]
      assert_invariant(u, "recorded gemini")
    end

    test "OpenAI Chat Completions stream: the final usage chunk's cached count survives the stream" do
      raw = File.read!("test/fixtures/openai/chat_completions/recorded/prompt_cache_stream.sse")
      stub = FinchStub.install([raw], [])
      req = Request.new([%Message{role: :user, content: "hi"}], model: "gpt-5.4-nano")

      {:ok, stream} =
        OpenAI.stream(req,
          api_key: "sk-cache-test",
          endpoint: :chat_completions,
          finch_module: FinchStub,
          finch_stub_ref: stub
        )

      u =
        stream
        |> Enum.reduce(StreamCollector.new(), &StreamCollector.apply_event(&2, &1))
        |> StreamCollector.to_response()
        |> Map.fetch!(:usage)

      assert u.cached_input_tokens > 0
      assert u.input_tokens > u.cached_input_tokens
      assert_invariant(u, "recorded chat stream")
    end

    test "Anthropic stream: message_start's cache read reaches the collected usage" do
      raw = File.read!("test/fixtures/anthropic/messages/recorded/prompt_cache_stream.sse")
      u = stream_usage(Anthropic, "claude-haiku-4-5-20251001", "sk-ant-cache-test", [raw])

      assert u.cached_input_tokens > 0
      assert u.input_tokens == u.cached_input_tokens + u.extra["uncached_input_tokens"]
      assert_invariant(u, "recorded anthropic stream")
    end

    test "each recorded control envelope rejects the invented field by name" do
      for rel <- [
            "openai/responses/recorded/prompt_cache_unknown_field.json",
            "anthropic/messages/recorded/prompt_cache_unknown_field.json",
            "gemini/generate_content/recorded/prompt_cache_unknown_field.json"
          ] do
        %{"error" => error} = recorded(rel)
        assert error["message"] =~ "totallyNotAField", "#{rel}: #{inspect(error)}"
      end
    end
  end
end
