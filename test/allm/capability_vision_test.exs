defmodule ALLM.CapabilityVisionTest do
  @moduledoc """
  Phase 17.1 — vision capability gate (`ALLM.Capability.preflight/3` extension).
  See spec §35.6 and Phase 17 design Decision #5.

  Pre-flight rejects when ALL of the following hold:

    * The catalog is loaded (`Code.ensure_loaded?(LLMDB)`).
    * The resolved model is a `%ModelRef{}` (not a bare string/tuple).
    * The model's `:capabilities` map has `vision: false` (atom-keyed) or
      `"vision" => false` (string-keyed JSON-rehydrated).
    * The request's messages contain any `%ImagePart{}` in a list-shaped
      `:content`.

  When the catalog says nothing about vision (no `:vision` key), pre-flight
  no-ops — graceful degradation, matching the existing `:tools_disabled`
  precedent.
  """

  use ExUnit.Case, async: true

  alias ALLM.Capability
  alias ALLM.Error.ValidationError
  alias ALLM.{Image, ImagePart, Message, ModelRef, Request, TextPart, Tool}

  defp vision_user_msg do
    %Message{
      role: :user,
      content: [
        %TextPart{text: "what is in this image?"},
        %ImagePart{image: Image.from_url("https://example.com/cat.png")}
      ]
    }
  end

  defp text_only_req, do: Request.new([%Message{role: :user, content: "hi"}])
  defp vision_req(opts \\ []), do: Request.new([vision_user_msg()], opts)

  describe "preflight/2 — vision rule" do
    test "with capabilities.vision == true accepts ImagePart" do
      ref =
        ModelRef.new(
          provider: :openai,
          id: "gpt-4o-mini",
          capabilities: %{vision: true}
        )

      assert Capability.preflight(ref, vision_req()) == :ok
    end

    test "with capabilities.vision == false rejects ImagePart" do
      ref =
        ModelRef.new(
          provider: :local,
          id: "no-vision",
          capabilities: %{vision: false}
        )

      assert {:error, %ValidationError{reason: :unsupported_capability, errors: errors}} =
               Capability.preflight(ref, vision_req())

      assert {[:vision], :vision_disabled} in errors
    end

    test "with %{\"vision\" => false} (string-keyed) rejects ImagePart" do
      # JSON-rehydrated %ModelRef{} has string-keyed capabilities.
      ref =
        ModelRef.new(
          provider: :local,
          id: "no-vision",
          capabilities: %{"vision" => false}
        )

      assert {:error, %ValidationError{reason: :unsupported_capability, errors: errors}} =
               Capability.preflight(ref, vision_req())

      assert {[:vision], :vision_disabled} in errors
    end

    test "no llm_db loaded — no-op (returns :ok)" do
      Application.put_env(:allm, :force_capability_absent, true)

      try do
        ref =
          ModelRef.new(
            provider: :local,
            id: "no-vision",
            capabilities: %{vision: false}
          )

        assert Capability.preflight(ref, vision_req()) == :ok
      after
        Application.delete_env(:allm, :force_capability_absent)
      end
    end

    test "no :vision key in catalog — no-op even when ImagePart present" do
      ref =
        ModelRef.new(
          provider: :openai,
          id: "no-info",
          capabilities: %{tools: %{enabled: true}}
        )

      assert Capability.preflight(ref, vision_req()) == :ok
    end

    test "no ImagePart in request — vision rule does NOT fire even on vision-disabled model" do
      ref =
        ModelRef.new(
          provider: :local,
          id: "no-vision",
          capabilities: %{vision: false}
        )

      assert Capability.preflight(ref, text_only_req()) == :ok
    end

    test "accumulates :vision_disabled with :tools_disabled when both fail" do
      ref =
        ModelRef.new(
          provider: :local,
          id: "double-fail",
          capabilities: %{tools: %{enabled: false}, vision: false}
        )

      tool = Tool.new(name: "echo", description: "x", schema: %{})

      req = Request.new([vision_user_msg()], tools: [tool])

      assert {:error, %ValidationError{reason: :unsupported_capability, errors: errors}} =
               Capability.preflight(ref, req)

      assert {[:tools], :tools_disabled} in errors
      assert {[:vision], :vision_disabled} in errors
      assert length(errors) == 2
    end

    test "bare string model — no-op even with ImagePart (no capability info)" do
      assert Capability.preflight("openai:no-record", vision_req()) == :ok
    end
  end
end
