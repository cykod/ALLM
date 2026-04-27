defmodule ALLM.RetryImageTest do
  @moduledoc """
  Phase 14.3 — `ALLM.Retry.run/3` integration with the image-side
  façade. Asserts that the four retry-engaging `ImageAdapterError`
  reasons engage the retry loop, that non-retryable reasons surface
  verbatim with NO retry attempt, and that `:retry_until_call`
  exhaustion surfaces the most recent error.
  """

  use ExUnit.Case, async: false

  alias ALLM.Engine
  alias ALLM.Error.ImageAdapterError
  alias ALLM.{Image, ImageResponse}
  alias ALLM.Providers.FakeImages
  alias ALLM.Test.TelemetryCapture

  setup do
    Application.delete_env(:allm, :force_capability_absent)

    on_exit(fn ->
      TelemetryCapture.detach()
      Application.delete_env(:allm, :force_capability_absent)
    end)

    :ok
  end

  defp scripted_engine(script, retry \\ :default) do
    Engine.new(
      image_adapter: FakeImages,
      retry: retry,
      adapter_opts: [image_script: script]
    )
  end

  defp filter_retries do
    TelemetryCapture.events()
    |> Enum.filter(fn {n, _, _} -> n == [:allm, :adapter, :retry] end)
  end

  describe "retry-loop happy path" do
    test "retry_until_call: 2 then {:ok, [img]} — first call retries, second succeeds" do
      :ok = TelemetryCapture.attach([[:allm, :adapter, :retry]])

      img = Image.from_binary(<<1>>, "image/png")
      engine = scripted_engine([{:retry_until_call, 2}, {:ok, [img]}])

      assert {:ok, %ImageResponse{images: [^img]}} =
               ALLM.generate_image(engine, "x", request_id: "rid-happy")

      retries = filter_retries()
      assert length(retries) == 1

      [{_, _, meta}] = retries
      assert meta.attempt == 1
      assert meta.reason.reason == :rate_limited
    end
  end

  describe "retry-loop exhausted" do
    test "retry_until_call: 5 with max_attempts: 3 — exhausts and returns the most recent error" do
      :ok = TelemetryCapture.attach([[:allm, :adapter, :retry]])

      img = Image.from_binary(<<1>>, "image/png")
      engine = scripted_engine([{:retry_until_call, 5}, {:ok, [img]}], max_attempts: 3)

      assert {:error, %ImageAdapterError{reason: :rate_limited, retry_after_ms: 0}} =
               ALLM.generate_image(engine, "x")

      retries = filter_retries()
      # max_attempts: 3 → 2 retry events (attempts 1 and 2; final attempt
      # 3 emits no retry event because the surrounding stop span fires).
      assert length(retries) == 2
    end
  end

  describe "non-retryable error" do
    test ":invalid_request surfaces verbatim, NO retry attempt" do
      :ok = TelemetryCapture.attach([[:allm, :adapter, :retry]])

      err = ImageAdapterError.new(:invalid_request, message: "bad")
      engine = scripted_engine([{:error, err}])

      assert {:error, ^err} = ALLM.generate_image(engine, "x")
      assert filter_retries() == []
    end

    test ":content_filter surfaces verbatim, NO retry attempt" do
      :ok = TelemetryCapture.attach([[:allm, :adapter, :retry]])

      err = ImageAdapterError.new(:content_filter, message: "blocked")
      engine = scripted_engine([{:error, err}])

      assert {:error, ^err} = ALLM.generate_image(engine, "x")
      assert filter_retries() == []
    end

    test ":authentication_failed surfaces verbatim, NO retry attempt" do
      :ok = TelemetryCapture.attach([[:allm, :adapter, :retry]])

      err = ImageAdapterError.new(:authentication_failed, message: "401")
      engine = scripted_engine([{:error, err}])

      assert {:error, ^err} = ALLM.generate_image(engine, "x")
      assert filter_retries() == []
    end
  end

  describe ":rate_limited with explicit retry_after_ms" do
    test "scripted :rate_limited error followed by ok — retries with the closure-supplied delay" do
      :ok = TelemetryCapture.attach([[:allm, :adapter, :retry]])

      img = Image.from_binary(<<1>>, "image/png")

      err =
        ImageAdapterError.new(:rate_limited,
          message: "throttled",
          retry_after_ms: 1
        )

      engine = scripted_engine([{:error, err}, {:ok, [img]}])

      assert {:ok, %ImageResponse{}} = ALLM.generate_image(engine, "x")

      retries = filter_retries()
      assert length(retries) == 1

      [{_, _, meta}] = retries
      assert meta.attempt == 1
      assert meta.reason.reason == :rate_limited
      # The closure-supplied delay (1ms) plus jitter wins over backoff.
      assert is_integer(meta.delay_ms)
    end
  end

  describe "engine retry: false" do
    test "first transient error short-circuits with NO retry attempt" do
      :ok = TelemetryCapture.attach([[:allm, :adapter, :retry]])

      img = Image.from_binary(<<1>>, "image/png")

      engine =
        Engine.new(
          image_adapter: FakeImages,
          retry: false,
          adapter_opts: [image_script: [{:retry_until_call, 5}, {:ok, [img]}]]
        )

      assert {:error, %ImageAdapterError{reason: :rate_limited}} =
               ALLM.generate_image(engine, "x")

      assert filter_retries() == []
    end
  end

  describe ":provider_unavailable / :timeout / :network_error engage retry" do
    for reason <- [:provider_unavailable, :timeout, :network_error] do
      test "#{inspect(reason)} engages the retry loop" do
        :ok = TelemetryCapture.attach([[:allm, :adapter, :retry]])

        img = Image.from_binary(<<1>>, "image/png")
        err = ImageAdapterError.new(unquote(reason), message: "x", retry_after_ms: 0)
        engine = scripted_engine([{:error, err}, {:ok, [img]}])

        assert {:ok, %ImageResponse{}} = ALLM.generate_image(engine, "x")

        retries = filter_retries()
        assert length(retries) == 1
        [{_, _, meta}] = retries
        assert meta.reason.reason == unquote(reason)
      end
    end
  end
end
