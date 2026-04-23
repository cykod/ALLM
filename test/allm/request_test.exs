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

  # NOTE: ALLM.Serializer JSON round-trip is deferred to sub-phase 1.5.
end
