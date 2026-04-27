defmodule ALLM.TelemetryImageTest do
  @moduledoc """
  Phase 14.3 — `[:allm, :image, :start | :stop]` telemetry span tests
  for the `ALLM.generate_image/3` façade. Asserts the `:image` atom is
  in `Telemetry.@valid_span_names` and that `:start` / `:stop` events
  fire with the documented metadata + measurement shape on success,
  on a missing-adapter shortcut, and on adapter-error pass-through.
  """

  use ExUnit.Case, async: false

  alias ALLM.Engine
  alias ALLM.Error.{EngineError, ImageAdapterError}
  alias ALLM.{Image, ImageRequest, ImageResponse, ImageUsage, Telemetry}
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

  defp event(events, name) do
    Enum.find(events, fn {n, _, _} -> n == name end)
  end

  defp scripted_engine(script) do
    Engine.new(
      image_adapter: FakeImages,
      adapter_opts: [image_script: script]
    )
  end

  describe "Telemetry.span/3 closed-enum guard" do
    test ":image is a legal span name" do
      assert :ok = Telemetry.span(:image, %{}, fn -> {:ok, %{}} end)
    end

    test "an :image_typo raises ArgumentError" do
      assert_raise ArgumentError, ~r/unknown span name/, fn ->
        Telemetry.span(:image_typo, %{}, fn -> {:ok, %{}} end)
      end
    end
  end

  describe "generate_image/3 — success span" do
    test ":start fires with operation/n/model/request_id metadata; :stop fires with image_count and usage" do
      :ok =
        TelemetryCapture.attach([
          [:allm, :image, :start],
          [:allm, :image, :stop]
        ])

      img1 = Image.from_binary(<<1>>, "image/png")
      img2 = Image.from_binary(<<2>>, "image/png")
      engine = scripted_engine([{:ok, [img1, img2]}])

      assert {:ok, %ImageResponse{} = response} =
               ALLM.generate_image(engine, "a kestrel", request_id: "rid-success")

      events = TelemetryCapture.events()

      assert {[:allm, :image, :start], _, start_meta} =
               event(events, [:allm, :image, :start])

      assert start_meta.request_id == "rid-success"
      assert start_meta.operation == :generate
      assert start_meta.n == 1
      assert is_struct(start_meta.engine, Engine)

      assert {[:allm, :image, :stop], stop_measurements, stop_meta} =
               event(events, [:allm, :image, :stop])

      assert stop_measurements.image_count == 2
      assert is_integer(stop_measurements.duration)
      assert stop_meta.request_id == "rid-success"
      assert stop_meta.operation == :generate
      assert stop_meta.n == 1
      assert stop_meta.usage == response.usage
      assert stop_meta.error == nil
      assert match?(%ImageResponse{}, stop_meta.response)
    end
  end

  describe "generate_image/3 — missing image_adapter span" do
    test ":start STILL fires; :stop carries image_count: 0 + EngineError" do
      :ok =
        TelemetryCapture.attach([
          [:allm, :image, :start],
          [:allm, :image, :stop]
        ])

      engine = Engine.new()

      assert {:error, %EngineError{reason: :no_image_adapter}} =
               ALLM.generate_image(engine, "x", request_id: "rid-missing")

      events = TelemetryCapture.events()

      assert {[:allm, :image, :start], _, start_meta} =
               event(events, [:allm, :image, :start])

      assert start_meta.request_id == "rid-missing"

      assert {[:allm, :image, :stop], stop_measurements, stop_meta} =
               event(events, [:allm, :image, :stop])

      assert stop_measurements.image_count == 0
      assert stop_meta.usage == nil
      assert stop_meta.response == nil
      assert match?(%EngineError{reason: :no_image_adapter}, stop_meta.error)
    end
  end

  describe "generate_image/3 — adapter-error span" do
    test ":stop carries image_count: 0 + the adapter error" do
      :ok =
        TelemetryCapture.attach([
          [:allm, :image, :start],
          [:allm, :image, :stop]
        ])

      err =
        ImageAdapterError.new(:invalid_request,
          message: "bad prompt",
          metadata: %{}
        )

      engine = scripted_engine([{:error, err}])

      assert {:error, %ImageAdapterError{reason: :invalid_request}} =
               ALLM.generate_image(engine, "x", request_id: "rid-err")

      events = TelemetryCapture.events()

      assert {[:allm, :image, :stop], stop_measurements, stop_meta} =
               event(events, [:allm, :image, :stop])

      assert stop_measurements.image_count == 0
      assert stop_meta.usage == nil
      assert stop_meta.response == nil
      assert match?(%ImageAdapterError{reason: :invalid_request}, stop_meta.error)
    end
  end

  describe "generate_image/3 — single span wraps the retry loop" do
    test "a successful retry produces ONE :image span and N :adapter, :retry events between attempts" do
      :ok =
        TelemetryCapture.attach([
          [:allm, :image, :start],
          [:allm, :image, :stop],
          [:allm, :adapter, :retry]
        ])

      img = Image.from_binary(<<1>>, "image/png")
      # retry_until_call: 2 → first attempt errors, second attempt succeeds.
      engine = scripted_engine([{:retry_until_call, 2}, {:ok, [img]}])

      assert {:ok, %ImageResponse{}} =
               ALLM.generate_image(engine, "x", request_id: "rid-retry")

      events = TelemetryCapture.events()

      starts = Enum.filter(events, fn {n, _, _} -> n == [:allm, :image, :start] end)
      stops = Enum.filter(events, fn {n, _, _} -> n == [:allm, :image, :stop] end)
      retries = Enum.filter(events, fn {n, _, _} -> n == [:allm, :adapter, :retry] end)

      assert length(starts) == 1
      assert length(stops) == 1
      assert length(retries) == 1

      [{_, _, retry_meta}] = retries
      assert retry_meta.attempt == 1
      assert retry_meta.request_id == "rid-retry"
      assert retry_meta.operation == :generate
    end
  end

  describe "generate_image/3 — start metadata for :image_request struct input" do
    test "operation/n surface from the supplied struct, not opts" do
      :ok = TelemetryCapture.attach([[:allm, :image, :start]])

      img = Image.from_binary(<<1>>, "image/png")
      engine = scripted_engine([{:ok, [img]}])

      req = ImageRequest.new(operation: :variation, input_images: [img], n: 3)

      assert {:ok, %ImageResponse{}} =
               ALLM.generate_image(engine, req, request_id: "rid-struct")

      [{_, _, meta}] = TelemetryCapture.events()
      assert meta.operation == :variation
      assert meta.n == 3
    end
  end

  describe "generate_image/3 — usage round-trip" do
    test ":stop usage carries the FakeImages-supplied %ImageUsage{}" do
      :ok = TelemetryCapture.attach([[:allm, :image, :stop]])

      img = Image.from_binary(<<1>>, "image/png")
      usage = %ImageUsage{images: 1, input_tokens: 50}
      engine = scripted_engine([{:ok, [img], usage: usage}])

      assert {:ok, _} = ALLM.generate_image(engine, "x")

      [{_, _, meta}] = TelemetryCapture.events()
      assert meta.usage == usage
    end
  end
end
