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
end
