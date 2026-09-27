defmodule ALLM.Providers.Support.SpeechAdapterTest do
  @moduledoc """
  Direct tests of `ALLM.Providers.Support.SpeechAdapter`'s retry-step
  mapping and helpers, which the adapters' own suites reach only through the
  default retry policy (so a `:retry` turned into an `:error`, or a dropped
  `Retry-After`, would stay green there). Driven with
  `ALLM.Providers.OpenAI.Speech` as the callback module and a plug in place
  of the network.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ALLM.Error.SpeechAdapterError
  alias ALLM.Providers.OpenAI.Speech, as: OpenAISpeech
  alias ALLM.Providers.Support.SpeechAdapter
  alias ALLM.SpeechRequest

  defp attempt(plug) do
    http_req = Req.new(url: "http://speech.test/v1", plug: plug, retry: false)

    SpeechAdapter.run_one_attempt(
      OpenAISpeech,
      :openai,
      http_req,
      SpeechRequest.new(input: "Hi."),
      []
    )
  end

  describe "run_one_attempt/5 returns a Retry.run/3 step" do
    test "a transport timeout is {:retry, 0, :timeout}" do
      assert {:retry, 0, %SpeechAdapterError{reason: :timeout, provider: :openai}} =
               attempt(&Req.Test.transport_error(&1, :timeout))
    end

    test "any other transport failure is {:retry, 0, :network_error}" do
      assert {:retry, 0, %SpeechAdapterError{reason: :network_error}} =
               attempt(&Req.Test.transport_error(&1, :econnrefused))
    end

    test "a 429 is retried after its Retry-After" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "2")
        |> Plug.Conn.send_resp(429, ~s({"error":{"message":"slow down"}}))
      end

      assert {:retry, 2_000, %SpeechAdapterError{reason: :rate_limited}} = attempt(plug)
    end

    test "a 400 is a terminal {:error, _}" do
      assert {:error, %SpeechAdapterError{reason: :invalid_request}} =
               attempt(&Plug.Conn.send_resp(&1, 400, ~s({"error":{"message":"bad"}})))
    end
  end

  test "retry_telemetry_meta/2 carries the request id only when one is given" do
    assert SpeechAdapter.retry_telemetry_meta(:openai, []) == %{provider: :openai}

    assert SpeechAdapter.retry_telemetry_meta(:elevenlabs, request_id: "r1") ==
             %{provider: :elevenlabs, request_id: "r1"}
  end

  test "non_audio_error/3 passes the content type through the adapter's redactor" do
    err = SpeechAdapter.non_audio_error(OpenAISpeech, "text/html; sk-abcdef123456", [])

    assert %SpeechAdapterError{reason: :malformed_response} = err
    assert err.message =~ "[REDACTED]"
    refute err.message =~ "sk-abcdef123456"
  end

  test "drop_reserved_options/4 drops the reserved keys and logs which" do
    log =
      capture_log([level: :debug], fn ->
        assert SpeechAdapter.drop_reserved_options(
                 %{"a" => 1, "x" => 2},
                 ["x"],
                 OpenAISpeech,
                 "why."
               ) == %{"a" => 1}
      end)

    assert log =~ ~s{ALLM.Providers.OpenAI.Speech: dropping reserved option(s) ["x"]; why.}
  end
end
