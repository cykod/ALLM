defmodule ALLM.Providers.OpenAI.ModerationVisionTest do
  @moduledoc """
  Image input for `ALLM.Providers.OpenAI.Moderation` — Phase 22.5.

  Three concerns, in the order the adapter meets them:

    * the **content-block translator** (`to_openai_content_blocks/1`,
      `part_to_block/1`) and its two deliberate omissions — no `detail` key
      (Decision #8) and no `ALLM.Image.to_data_uri/1` call on a URL source;
    * the **image gate** (`gate_images/2`), which converts all five ways an
      item can fail to reach the wire into
      `%ALLM.Error.ModerationAdapterError{reason: :invalid_request}` rather
      than widening this callback's error union (Decision #7), and fires ahead
      of `ALLM.Keys.fetch!/2` like the two 22.4 gates. Three shapes come from
      `ALLM.Providers.Support.ImageMime.validate/2`; the `:unresolvable_image`
      and `:untranslatable_item` arms were added in the 22.5 fix pass, because
      without them a missing file and an off-shape item escaped `moderate/2` as
      a raised `MatchError` / `FunctionClauseError` — invariant 2 violations by
      ALLM's own bundled adapter. Each carries a premise guard so the arms
      cannot go vacuous;
    * the **multimodal cardinality rule** — an `:input` carrying any
      `%ALLM.ImagePart{}` is ONE item and comes back as exactly one result at
      `index: 0`, however many elements the list had. Driven here by the live
      recording at
      `test/fixtures/openai/moderations/recorded/multimodal_text_image.json`.

  The all-strings request shape lives in `moderation_test.exs` and must stay
  byte-identical; `to_json_body/2`'s multimodal arm is additive.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  import ALLM.Providers.OpenAI.ImagesTestHelpers, only: [respond_json: 3]

  alias ALLM.Error.ModerationAdapterError
  alias ALLM.{Image, ImagePart, ModerationRequest, ModerationResponse, ModerationResult}
  alias ALLM.Providers.OpenAI.Moderation
  alias ALLM.Providers.OpenAITestFixtures
  alias ALLM.Providers.Support.ImageMime

  # A four-byte PNG header. Enough for the MIME/byte gates and the data-URI
  # encoder, which never look at pixels; the recorder's live arm posts a real
  # 1x1 PNG.
  @png <<137, 80, 78, 71>>

  setup do
    {:ok, stub: String.to_atom("openai_moderation_vision_#{System.unique_integer([:positive])}")}
  end

  defp png_part(opts \\ []), do: ImagePart.new(Image.from_binary(@png, "image/png"), opts)

  defp url_part(url \\ "https://example.com/cat.png", opts \\ []),
    do: ImagePart.new(Image.from_url(url), opts)

  defp req(input, opts \\ []) do
    ModerationRequest.new(Keyword.merge([input: input, model: "omni-moderation-latest"], opts))
  end

  # ---------------------------------------------------------------------------
  # part_to_block/1 — the wire shape of one item
  # ---------------------------------------------------------------------------

  describe "part_to_block/1" do
    test "a bare binary emits a text block" do
      assert Moderation.part_to_block("hello") == %{"type" => "text", "text" => "hello"}
    end

    # The URL fast-path. `ALLM.Image.to_data_uri/1` returns
    # `{:error, :remote_source}` for a `{:url, _}` source (`lib/allm/image.ex:297`),
    # so a translator that reached for it would raise a MatchError on every
    # URL-sourced image. This test is what keeps the fast-path clause ahead of
    # the general one.
    test "a URL-sourced ImagePart forwards the URL verbatim, never a data: URI" do
      block = Moderation.part_to_block(url_part("https://example.com/x.png"))

      assert block == %{
               "type" => "image_url",
               "image_url" => %{"url" => "https://example.com/x.png"}
             }

      refute block["image_url"]["url"] =~ "data:"
    end

    test "a binary-sourced ImagePart emits a data: URI" do
      block = Moderation.part_to_block(png_part())

      assert %{"type" => "image_url", "image_url" => %{"url" => url}} = block
      assert url == "data:image/png;base64," <> Base.encode64(@png)
    end

    test "a base64-sourced ImagePart emits a data: URI without re-encoding" do
      part = ImagePart.new(Image.from_base64("aGk=", "image/png"))

      assert %{"image_url" => %{"url" => "data:image/png;base64,aGk="}} =
               Moderation.part_to_block(part)
    end

    # Decision #8, asserted in code rather than only in prose. This endpoint
    # ignores unknown fields (22.4's negative control came back POSITIVE), so a
    # live 200 on a `detail`-bearing request proves nothing either way — which
    # makes this test, not the wire, the thing that holds the decision.
    test "emits NO detail key, at any :detail value, for either image source" do
      for detail <- [:auto, :low, :high],
          part <- [png_part(detail: detail), url_part("https://example.com/x.png", detail: detail)] do
        %{"image_url" => image_url} = block = Moderation.part_to_block(part)

        refute Map.has_key?(image_url, "detail"),
               "detail leaked into image_url for #{inspect(detail)}: #{inspect(block)}"

        refute Map.has_key?(block, "detail"),
               "detail leaked as a sibling key for #{inspect(detail)}: #{inspect(block)}"
      end
    end
  end

  describe "to_openai_content_blocks/1" do
    test "preserves item order" do
      items = ["one", png_part(), "two", url_part("https://example.com/y.png")]

      assert [
               %{"type" => "text", "text" => "one"},
               %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64," <> _}},
               %{"type" => "text", "text" => "two"},
               %{"type" => "image_url", "image_url" => %{"url" => "https://example.com/y.png"}}
             ] = Moderation.to_openai_content_blocks(items)
    end

    test "an empty list yields an empty list" do
      assert Moderation.to_openai_content_blocks([]) == []
    end
  end

  # ---------------------------------------------------------------------------
  # to_json_body/2 — the multimodal arm is additive
  # ---------------------------------------------------------------------------

  describe "to_json_body/2 multimodal arm" do
    test "a multimodal :input becomes an array of content blocks" do
      body = Moderation.to_json_body(req(["look at this", png_part()]), [])

      assert %{
               "input" => [
                 %{"type" => "text", "text" => "look at this"},
                 %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64," <> _}}
               ],
               "model" => "omni-moderation-latest"
             } = body
    end

    # The 22.4 branch must stay byte-identical — `to_json_body/2`'s all-strings
    # tests in `moderation_test.exs` pin the same property from the other side.
    test "an all-strings :input still emits the bare string array" do
      assert %{"input" => ["a", "b"]} = Moderation.to_json_body(req(["a", "b"]), [])
    end

    # The adapter inlines `ModerationRequest.multimodal?/1`'s predicate rather
    # than calling it — a deliberate clone whose reason is recorded on
    # `wire_input/1` (calling the `t()`-specced function refines the binding and
    # kills two released defensive clauses under dialyzer). This is the test
    # that stops the clone drifting: the branch taken must be exactly what the
    # published predicate reports, for every shape.
    test "to_json_body/2 branches on exactly what multimodal?/1 reports" do
      shapes = [
        [],
        ["a"],
        ["a", "b"],
        [png_part()],
        ["a", png_part()],
        [png_part(), "a"],
        [url_part(), png_part()]
      ]

      for input <- shapes do
        request = req(input)
        %{"input" => wire} = Moderation.to_json_body(request, [])

        if ModerationRequest.multimodal?(request) do
          assert Enum.all?(wire, &is_map/1),
                 "multimodal?/1 said true but the wire input is not content blocks: " <>
                   inspect(wire)
        else
          assert wire == input,
                 "multimodal?/1 said false but the wire input was rewritten: #{inspect(wire)}"
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # gate_images/2 — gate 3
  # ---------------------------------------------------------------------------

  describe "image gate" do
    test "an unsupported MIME returns :invalid_request naming the MIME and the index" do
      part = ImagePart.new(Image.from_binary(@png, "image/svg+xml"))

      assert {:error, %ModerationAdapterError{reason: :invalid_request} = err} =
               Moderation.moderate(req(["ok", part]), [])

      assert err.metadata.image_error == :unsupported_image_format
      assert err.metadata.mime_type == "image/svg+xml"
      assert err.metadata.index == 1
      assert err.metadata.field == :input
      assert err.message =~ "image/svg+xml"
    end

    test "an image over 20 MB returns :invalid_request carrying the byte size" do
      oversized = :binary.copy(<<0>>, 20 * 1024 * 1024 + 1)
      part = ImagePart.new(Image.from_binary(oversized, "image/png"))

      assert {:error, %ModerationAdapterError{reason: :invalid_request} = err} =
               Moderation.moderate(req([part]), [])

      assert err.metadata.image_error == :image_too_large
      assert err.metadata.byte_size == byte_size(oversized)
      assert err.metadata.index == 0
    end

    # Reachable via `ALLM.Image.from_file/1` on an unrecognised extension, which
    # leaves `:mime_type` nil. NOT via `from_url/1`: a `{:url, _}` source takes
    # `ImageMime.validate/2`'s first clause and is accepted with a nil mime.
    test "an ImagePart lacking a mime_type returns :invalid_request naming the item index" do
      part = ImagePart.new(Image.from_file("/tmp/allm-moderation-vision.unknownext"))
      assert part.image.mime_type == nil

      assert {:error, %ModerationAdapterError{reason: :invalid_request} = err} =
               Moderation.moderate(req(["a", "b", part]), [])

      assert err.metadata.image_error == :missing_mime_type
      assert err.metadata.index == 2
    end

    test "a URL-sourced image with no mime_type is accepted — no fetch, no gate" do
      assert Moderation.gate_images(req(["a", url_part()]), []) == :ok
    end

    test "the gate is fail-fast: the FIRST offending item is reported" do
      bad_a = ImagePart.new(Image.from_binary(@png, "image/svg+xml"))
      bad_b = ImagePart.new(Image.from_binary(@png, "image/tiff"))

      assert {:error, err} = Moderation.gate_images(req([bad_a, bad_b]), [])
      assert err.metadata.index == 0
      assert err.metadata.mime_type == "image/svg+xml"
    end

    test "errors carry opts[:request_id] like every other error this adapter surfaces" do
      part = ImagePart.new(Image.from_binary(@png, "image/svg+xml"))

      assert {:error, err} = Moderation.gate_images(req([part]), request_id: "rq-42")
      assert err.metadata.request_id == "rq-42"
    end

    # ------------------------------------------------------------------------
    # Invariant 2, the two ways the translator was NOT total (22.5 fix pass).
    #
    # Both were found by running the code, not by reading it, and both escaped
    # `moderate/2` as a RAISED EXCEPTION before this pass — which is ALLM's own
    # bundled adapter violating the behaviour it ships a conformance suite for.
    # The premise for the first is that `ImageMime.check_byte_size/1` returns
    # `:ok` when the bytes cannot be resolved at all (`image_mime.ex:126-129`),
    # so MIME and size validation both PASS for a file that is not there.
    # ------------------------------------------------------------------------

    test "an image whose bytes cannot be resolved is :invalid_request, not a MatchError" do
      part = %ImagePart{
        image: %Image{
          source: {:file, "/nonexistent/definitely-not-here.png"},
          mime_type: "image/png"
        }
      }

      assert {:error, %ModerationAdapterError{reason: :invalid_request} = err} =
               Moderation.gate_images(req(["a", part]), [])

      assert err.metadata.image_error == :unresolvable_image
      assert err.metadata.index == 1
      assert err.metadata.cause == :enoent
    end

    test "the unresolvable-image gate holds all the way through ALLM.moderate/3" do
      part = %ImagePart{
        image: %Image{source: {:file, "/nonexistent/gone.png"}, mime_type: "image/png"}
      }

      engine =
        ALLM.Engine.new(
          moderation_adapter: Moderation,
          model: "omni-moderation-latest",
          retry: false
        )

      assert {:error, %ModerationAdapterError{reason: :invalid_request}} =
               ALLM.moderate(engine, ["is this ok?", part], api_key: "sk-not-used")
    end

    # `part_to_block/1` has two heads and no catch-all, so an off-shape item in
    # a MULTIMODAL request used to raise `FunctionClauseError`. The all-strings
    # path is different and must stay different: there `wire_input/1` forwards
    # `:input` verbatim and the provider answers the 400, which is the adapter
    # declining to invent a second opinion about a shape it does not translate.
    test "an untranslatable item in a MULTIMODAL request is :invalid_request, not a crash" do
      assert {:error, %ModerationAdapterError{reason: :invalid_request} = err} =
               Moderation.gate_images(req([42, png_part()]), [])

      assert err.metadata.image_error == :untranslatable_item
      assert err.metadata.index == 0
      assert err.message =~ "neither a string nor an %ALLM.ImagePart{}"
    end

    test "the same item in an ALL-STRINGS request still passes through to the provider" do
      assert Moderation.gate_images(req([42, "ok"]), []) == :ok
      assert Moderation.to_json_body(req([42, "ok"]), [])["input"] == [42, "ok"]
    end

    # Premise guard for the four tests above, and a record of a premise that
    # CHANGED. When the two arms first landed, `ImageMime.validate/2` returned
    # `:ok` for an unresolvable image — it folded "cannot read the bytes" into
    # "no size objection" — so this adapter carried its own local
    # resolvability check and this guard asserted that `:ok`.
    #
    # The same defect was then confirmed on four other translators (OpenAI chat
    # + Responses, Anthropic, Gemini) and the check was promoted into the shared
    # helper, which flipped the premise. This guard going red is what caught the
    # flip, which is the whole reason it exists — so it now asserts the NEW
    # premise from the other side: resolvability arrives from `validate/2`, and
    # the local check is gone rather than silently duplicated.
    test "premise: ImageMime.validate/2 is what rejects an unresolvable image" do
      unresolvable = %ImagePart{
        image: %Image{source: {:file, "/nonexistent/gone.png"}, mime_type: "image/png"}
      }

      accept = ImageMime.accept_mimes(:openai)

      assert ImageMime.validate(unresolvable, accept) == {:error, {:unresolvable_image, :enoent}},
             "the shared helper stopped rejecting unresolvable images; this adapter no longer " <>
               "carries a local check, so `moderate/2` would raise a MatchError again"
    end

    # `validate/2` never sees a non-`%ImagePart{}` item — `validate_item/3`
    # dispatches on the struct before it is reached — so the untranslatable-item
    # arm cannot be delegated upstream the way resolvability was, and stays this
    # adapter's own. Recorded so it is not "consolidated" later by analogy.
    test "premise: the untranslatable-item arm is NOT delegable to ImageMime" do
      assert Moderation.gate_images(req([42, png_part()]), []) != :ok

      refute function_exported?(ImageMime, :validate, 1),
             "ImageMime validates a %ImagePart{}, not an arbitrary :input item"
    end

    # Decision #7: the union is `{:ok, _} | {:error, %ModerationAdapterError{}}`
    # and nothing else. A `%ValidationError{}` escaping here would break
    # `ALLM.ModerationAdapter` invariant 2 and make `ALLM.moderate/3` raise.
    test "every image failure is a ModerationAdapterError, never a ValidationError" do
      parts = [
        ImagePart.new(Image.from_binary(@png, "image/svg+xml")),
        ImagePart.new(Image.from_binary(:binary.copy(<<0>>, 20 * 1024 * 1024 + 1), "image/png")),
        ImagePart.new(Image.from_file("/tmp/allm-moderation-vision.unknownext"))
      ]

      for part <- parts do
        assert {:error, %ModerationAdapterError{reason: :invalid_request}} =
                 Moderation.moderate(req([part]), [])
      end
    end

    # The ordering proof, with NO :api_key in opts. `Keys.fetch!/2` raises
    # `%EngineError{reason: :missing_key}` if it runs first, so a passing
    # assertion here IS the proof — and the positive control below is what stops
    # it passing vacuously in a shell that has exported OPENAI_API_KEY (the state
    # `set -a; . ./.env; set +a` leaves behind). Mirrors
    # `moderation_test.exs`'s "pre-flight gates" describe, extended to gate 3.
    test "positive control: a multimodal request that passes every gate DOES reach key resolution" do
      assert_raise ALLM.Error.EngineError, fn ->
        Moderation.moderate(req(["ok", png_part()]), [])
      end
    end

    test "all three image gates fire before Keys.fetch!/2" do
      cases = [
        ImagePart.new(Image.from_binary(@png, "image/svg+xml")),
        ImagePart.new(Image.from_binary(:binary.copy(<<0>>, 20 * 1024 * 1024 + 1), "image/png")),
        ImagePart.new(Image.from_file("/tmp/allm-moderation-vision.unknownext"))
      ]

      for part <- cases do
        assert {:error, %ModerationAdapterError{reason: :invalid_request}} =
                 Moderation.moderate(req([part]), []),
               "gate did not fire ahead of key resolution for #{inspect(part.image.mime_type)}"
      end
    end

    test "prepare_request/2 runs the image gate too" do
      part = ImagePart.new(Image.from_binary(@png, "image/svg+xml"))

      assert {:error, %ModerationAdapterError{reason: :invalid_request}} =
               Moderation.prepare_request(req([part]), [])
    end
  end

  # ---------------------------------------------------------------------------
  # Multimodal cardinality, against the live recording
  # ---------------------------------------------------------------------------

  describe "multimodal cardinality" do
    test "a recorded multimodal response decodes to exactly one result at index 0", %{stub: stub} do
      body = OpenAITestFixtures.moderation_recorded(:multimodal_text_image)

      Req.Test.stub(stub, fn conn -> respond_json(conn, 200, body) end)

      assert {:ok, %ModerationResponse{results: [%ModerationResult{index: 0} = result]}} =
               Moderation.moderate(req(["is this ok?", png_part()]),
                 api_key: "sk-vision-test",
                 retry: false,
                 adapter_opts: [plug: {Req.Test, stub}]
               )

      assert is_boolean(result.flagged)
      assert is_map(result.categories)
      assert is_map(result.category_scores)
    end

    # The provider is what collapses the cardinality, so this asserts the
    # request half: two elements go out as two content blocks in ONE `input`
    # array, and `ALLM.ModerationRequest.multimodal?/1` is what selects that
    # shape before the call.
    test "the two-element multimodal request goes out as one input array", %{stub: stub} do
      Req.Test.stub(stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(self(), {:body, Jason.decode!(raw)})
        respond_json(conn, 200, OpenAITestFixtures.moderation_recorded(:multimodal_text_image))
      end)

      request = req(["is this ok?", png_part()])
      assert ModerationRequest.multimodal?(request)

      assert {:ok, _} =
               Moderation.moderate(request,
                 api_key: "sk-vision-test",
                 retry: false,
                 adapter_opts: [plug: {Req.Test, stub}]
               )

      assert_received {:body, %{"input" => input}}
      assert [%{"type" => "text"}, %{"type" => "image_url"}] = input
    end

    # Invariant 5 measures the ITEM count invariant 3 defines. A multimodal
    # `:input` is exactly one item, so it never trips the batch gate however
    # long the list is — verified live in 22.4's functional review at 2001
    # elements. `max_batch_size/0` + 1 is the cheapest list that would trip a
    # `length(request.input)` gate.
    test "a multimodal list longer than max_batch_size/0 sails past the batch gate" do
      long = List.duplicate("x", Moderation.max_batch_size()) ++ [png_part()]
      request = req(long)

      assert length(request.input) > Moderation.max_batch_size()
      assert ModerationRequest.multimodal?(request)

      # Reaching key resolution is the observable: the batch gate did not fire.
      assert_raise ALLM.Error.EngineError, fn -> Moderation.moderate(request, []) end
    end
  end

  # ---------------------------------------------------------------------------
  # The dropped-detail debug log
  # ---------------------------------------------------------------------------

  describe "ImagePart.detail one-shot debug log (Decision #8)" do
    test "dropping detail logs once per process at :debug across two calls" do
      log =
        capture_log([level: :debug], fn ->
          # `Task.async/1` isolates the process dictionary the once-per-process
          # latch lives in. Do NOT call `Logger.configure/1` in here: it mutates
          # application-global state and races with concurrent `async: true`
          # modules — the outer `capture_log/2` already sets the level for the
          # duration and restores it on exit (CLAUDE.md, PHASE_17.2 foot-gun).
          Task.async(fn ->
            _ = Moderation.to_json_body(req(["a", png_part(detail: :high)]), [])
            _ = Moderation.to_json_body(req(["b", png_part(detail: :low)]), [])
            :ok
          end)
          |> Task.await(5_000)
        end)

      count =
        log
        |> String.split("\n")
        |> Enum.count(&String.contains?(&1, "ImagePart.detail is not part of the"))

      assert count == 1, "expected exactly one debug log; saw #{count}\n--- log ---\n#{log}"
    end

    # `:auto` is `ALLM.ImagePart`'s DEFAULT, so it means "the caller expressed
    # no preference" and nothing was really dropped. Logging it would fire on
    # every plainly-constructed `ImagePart.new/1`. Matches
    # `lib/allm/providers/gemini.ex:755`; `anthropic.ex:883` is the outlier and
    # is filed as a `[DEFERRED-DRY]` ticket. Added in the 22.5 fix pass.
    test "emits NO debug log when detail is the DEFAULT :auto" do
      log =
        capture_log([level: :debug], fn ->
          Task.async(fn ->
            # Constructed the ordinary way — no :detail opt at all.
            _ = Moderation.to_json_body(req(["a", png_part()]), [])
            _ = Moderation.to_json_body(req(["b", png_part(detail: :auto)]), [])
            :ok
          end)
          |> Task.await(5_000)
        end)

      refute String.contains?(log, "ImagePart.detail is not part of the")
    end

    test "premise: ImagePart's default detail really is :auto" do
      assert ImagePart.new(Image.from_binary(@png, "image/png")).detail == :auto,
             "if this default changes, the :auto exclusion above stops describing the common case"
    end

    test "emits NO debug log when detail is nil" do
      log =
        capture_log([level: :debug], fn ->
          Task.async(fn ->
            part = %ImagePart{image: Image.from_binary(@png, "image/png"), detail: nil}
            _ = Moderation.to_json_body(req(["a", part]), [])
            :ok
          end)
          |> Task.await(5_000)
        end)

      refute String.contains?(log, "ImagePart.detail is not part of the")
    end

    test "an all-strings request never reaches the translator, so it never logs" do
      log =
        capture_log([level: :debug], fn ->
          Task.async(fn ->
            _ = Moderation.to_json_body(req(["a", "b"]), [])
            :ok
          end)
          |> Task.await(5_000)
        end)

      refute String.contains?(log, "ImagePart.detail is not part of the")
    end
  end
end
