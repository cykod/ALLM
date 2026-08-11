defmodule ALLM.Providers.StreamFinchTimeoutForwardingTest do
  @moduledoc """
  Verifies that the streaming adapters forward `:receive_timeout`,
  `:request_timeout`, and `:pool_timeout` opts verbatim to
  `Finch.async_request/3`.

  Without this, real streaming calls regress to Finch's defaults
  (e.g. ~20s receive timeout) regardless of what the caller passes,
  because the streaming codepath builds its Finch request inline and
  the `:request_timeout` opt that `generate/2` handles via `Req.merge/2`
  never reaches the streaming arm.

  Asserts pass-through against the captured `opts` arg on
  `ALLM.Test.FinchStub.async_request/3`.
  """
  use ExUnit.Case, async: true

  alias ALLM.Message
  alias ALLM.Providers.{Anthropic, Gemini, OpenAI}
  alias ALLM.Providers.AnthropicTestFixtures, as: AFx
  alias ALLM.Providers.GeminiTestFixtures, as: GFx
  alias ALLM.Providers.OpenAITestFixtures, as: OFx
  alias ALLM.Request
  alias ALLM.Test.FinchStub

  defp req(model) do
    Request.new([%Message{role: :user, content: "hi"}], model: model)
  end

  describe "OpenAI.stream/2" do
    test "forwards :receive_timeout / :request_timeout / :pool_timeout to Finch" do
      stub = FinchStub.install(OFx.stream_chunks(:happy_text_stream), [])

      {:ok, stream} =
        OpenAI.stream(req("gpt-4o-mini"),
          api_key: "sk-test",
          finch_module: FinchStub,
          finch_stub_ref: stub,
          receive_timeout: 120_000,
          request_timeout: 300_000,
          pool_timeout: 5_000
        )

      _ = Enum.to_list(stream)

      opts = FinchStub.captured_opts(stub)
      assert Keyword.get(opts, :receive_timeout) == 120_000
      assert Keyword.get(opts, :request_timeout) == 300_000
      assert Keyword.get(opts, :pool_timeout) == 5_000
    end

    # (MODIFY — semantic change) This asserted that NO :receive_timeout was
    # forwarded when the caller stayed silent, which handed the request to
    # Finch's 15,000 ms HTTP/1 pool default. That timer covers the gap before
    # the FIRST byte, so a reasoning model that thinks longer than 15 s was
    # killed mid-think and surfaced as %AdapterError{reason: :network_error} —
    # and ALLM's own 60 s :stream_timeout could never fire, making it a dead
    # knob. The adapters now default the transport timer ABOVE :stream_timeout.
    test "defaults :receive_timeout above :stream_timeout when the caller is silent" do
      stub = FinchStub.install(OFx.stream_chunks(:happy_text_stream), [])

      {:ok, stream} =
        OpenAI.stream(req("gpt-4o-mini"),
          api_key: "sk-test",
          finch_module: FinchStub,
          finch_stub_ref: stub
        )

      _ = Enum.to_list(stream)

      opts = FinchStub.captured_opts(stub)
      # 60_000 default stream_timeout + 30_000 headroom
      assert Keyword.get(opts, :receive_timeout) == 90_000
      refute Keyword.has_key?(opts, :request_timeout)
      refute Keyword.has_key?(opts, :pool_timeout)
    end

    test ":stream_timeout is the single knob — it raises the transport timer too" do
      stub = FinchStub.install(OFx.stream_chunks(:happy_text_stream), [])

      {:ok, stream} =
        OpenAI.stream(req("gpt-5.6"),
          api_key: "sk-test",
          finch_module: FinchStub,
          finch_stub_ref: stub,
          stream_timeout: 300_000
        )

      _ = Enum.to_list(stream)

      assert Keyword.get(FinchStub.captured_opts(stub), :receive_timeout) == 330_000
    end

    test "an explicit :receive_timeout still wins over the derived default" do
      stub = FinchStub.install(OFx.stream_chunks(:happy_text_stream), [])

      {:ok, stream} =
        OpenAI.stream(req("gpt-5.6"),
          api_key: "sk-test",
          finch_module: FinchStub,
          finch_stub_ref: stub,
          stream_timeout: 300_000,
          receive_timeout: 45_000
        )

      _ = Enum.to_list(stream)

      assert Keyword.get(FinchStub.captured_opts(stub), :receive_timeout) == 45_000
    end
  end

  describe "Anthropic.stream/2" do
    test "forwards :receive_timeout / :request_timeout / :pool_timeout to Finch" do
      stub = FinchStub.install(AFx.stream_chunks(:happy_text), [])

      {:ok, stream} =
        Anthropic.stream(req("claude-sonnet-4-6"),
          api_key: "sk-ant-test",
          finch_module: FinchStub,
          finch_stub_ref: stub,
          receive_timeout: 120_000,
          request_timeout: 300_000,
          pool_timeout: 5_000
        )

      _ = Enum.to_list(stream)

      opts = FinchStub.captured_opts(stub)
      assert Keyword.get(opts, :receive_timeout) == 120_000
      assert Keyword.get(opts, :request_timeout) == 300_000
      assert Keyword.get(opts, :pool_timeout) == 5_000
    end

    test ":stream_timeout raises the transport timer (extended thinking)" do
      stub = FinchStub.install(AFx.stream_chunks(:happy_text), [])

      {:ok, stream} =
        Anthropic.stream(req("claude-sonnet-4-6"),
          api_key: "sk-ant-test",
          finch_module: FinchStub,
          finch_stub_ref: stub,
          stream_timeout: 300_000
        )

      _ = Enum.to_list(stream)

      assert Keyword.get(FinchStub.captured_opts(stub), :receive_timeout) == 330_000
    end
  end

  describe "Gemini.stream/2" do
    test "forwards :receive_timeout / :request_timeout / :pool_timeout to Finch" do
      stub = FinchStub.install(GFx.stream_chunks(:happy_text_stream), [])

      {:ok, stream} =
        Gemini.stream(req("gemini-2.5-flash"),
          api_key: "g-test",
          finch_module: FinchStub,
          finch_stub_ref: stub,
          receive_timeout: 120_000,
          request_timeout: 300_000,
          pool_timeout: 5_000
        )

      _ = Enum.to_list(stream)

      opts = FinchStub.captured_opts(stub)
      assert Keyword.get(opts, :receive_timeout) == 120_000
      assert Keyword.get(opts, :request_timeout) == 300_000
      assert Keyword.get(opts, :pool_timeout) == 5_000
    end

    test ":stream_timeout raises the transport timer" do
      stub = FinchStub.install(GFx.stream_chunks(:happy_text_stream), [])

      {:ok, stream} =
        Gemini.stream(req("gemini-2.5-flash"),
          api_key: "g-test",
          finch_module: FinchStub,
          finch_stub_ref: stub,
          stream_timeout: 300_000
        )

      _ = Enum.to_list(stream)

      assert Keyword.get(FinchStub.captured_opts(stub), :receive_timeout) == 330_000
    end
  end
end
