defmodule ALLM.RequestTest do
  use ExUnit.Case, async: true

  alias ALLM.{Message, Request, Tool}

  doctest Request

  describe "new/2" do
    test "builds a Request with just messages" do
      msgs = [%Message{role: :user, content: "hi"}]
      req = Request.new(msgs)
      assert %Request{messages: ^msgs, stream: false, tools: []} = req
    end

    test "passes through options" do
      msgs = [%Message{role: :user, content: "hi"}]

      req =
        Request.new(msgs,
          model: "fake:gpt-test",
          temperature: 0.2,
          max_tokens: 128,
          tools: [%Tool{name: "t", description: "", schema: %{}}],
          tool_choice: :auto,
          response_format: :text,
          stream: true,
          structured_finalize: false,
          options: %{seed: 42},
          metadata: %{trace: "x"}
        )

      assert req.model == "fake:gpt-test"
      assert req.temperature == 0.2
      assert req.max_tokens == 128
      assert req.tool_choice == :auto
      assert req.response_format == :text
      assert req.stream == true
      assert req.options == %{seed: 42}
      assert req.metadata == %{trace: "x"}
      assert [%Tool{name: "t"}] = req.tools
    end

    test "defaults fields when opts omit them" do
      req = Request.new([])
      assert req.messages == []
      assert req.tools == []
      assert req.tool_choice == nil
      assert req.stream == false
      assert req.structured_finalize == false
      assert req.options == %{}
      assert req.metadata == %{}
    end
  end

  describe "term_to_binary/binary_to_term round-trip" do
    @tag :roundtrip
    test "a fully populated Request round-trips to equal value" do
      msgs = [%Message{role: :user, content: "hi"}]

      req =
        Request.new(msgs,
          model: "fake:gpt-test",
          temperature: 0.2,
          max_tokens: 128,
          response_format: %{type: :json_object},
          tool_choice: :auto,
          metadata: %{trace: "x"}
        )

      assert req == req |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end
  end

  describe "prompt_cache" do
    defp json_round_trip(req) do
      {:ok, decoded} = req |> Jason.encode!() |> ALLM.Serializer.from_json()
      decoded
    end

    test "defaults to nil and round-trips JSON as nil" do
      req = Request.new([%Message{role: :user, content: "hi"}])
      assert req.prompt_cache == nil
      assert json_round_trip(req).prompt_cache == nil
    end

    test "round-trips JSON with the retention atom restored" do
      req =
        Request.new([%Message{role: :user, content: "hi"}],
          prompt_cache: %{key: "k", retention: :long}
        )

      decoded = json_round_trip(req)
      # Falsifier: an undecoded value reads %{key: "k", retention: "long"}.
      assert decoded.prompt_cache == %{key: "k", retention: :long}
      assert decoded == req
    end

    test "round-trips a nil key and :short retention" do
      req =
        Request.new([%Message{role: :user, content: "hi"}],
          prompt_cache: %{key: nil, retention: :short}
        )

      assert json_round_trip(req).prompt_cache == %{key: nil, retention: :short}
      assert req == req |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end

    test "an unknown persisted retention decodes without raising or minting an atom" do
      data = %{
        "messages" => [],
        "prompt_cache" => %{"key" => "k", "retention" => "forever"}
      }

      assert Request.__from_tagged__(data).prompt_cache == %{key: "k", retention: "forever"}
    end

    test "a partial or over-full persisted map passes through undecoded" do
      partial = %{"key" => "k"}
      extra = %{"key" => "k", "retention" => "long", "ttl" => "1h"}

      assert Request.__from_tagged__(%{"prompt_cache" => partial}).prompt_cache == partial
      assert Request.__from_tagged__(%{"prompt_cache" => extra}).prompt_cache == extra
    end

    test "decode_retention/1 maps the two known strings and passes others through" do
      assert Request.decode_retention("short") == :short
      assert Request.decode_retention("long") == :long
      assert Request.decode_retention(:long) == :long
      assert Request.decode_retention("forever") == "forever"
    end
  end
end
