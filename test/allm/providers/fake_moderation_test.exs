defmodule ALLM.Providers.FakeModerationTest do
  use ExUnit.Case, async: true

  alias ALLM.{Engine, ImagePart, ModerationRequest, ModerationResponse, ModerationResult}
  alias ALLM.Error.ModerationAdapterError
  alias ALLM.Providers.FakeModeration
  alias ALLM.Test.FakeModerationFixtures, as: Fixtures

  doctest FakeModeration

  defp request(opts \\ []), do: ModerationRequest.new(Keyword.put_new(opts, :input, ["x"]))

  describe "max_batch_size/0" do
    test "returns a positive integer" do
      assert is_integer(FakeModeration.max_batch_size())
      assert FakeModeration.max_batch_size() > 0
    end

    test "returns 32 — deliberately small so the :batch_too_large boundary is cheap to cross" do
      assert FakeModeration.max_batch_size() == 32
    end
  end

  describe "moderate/2 default (no script)" do
    test "returns one unflagged result per input" do
      req = request(input: ["a", "b", "c"])

      assert {:ok, %ModerationResponse{results: results}} = FakeModeration.moderate(req, [])
      assert length(results) == 3
      assert Enum.map(results, & &1.index) == [0, 1, 2]
      assert Enum.all?(results, &(&1.flagged == false))
    end

    test "every result carries the 13 omni category names, all false, all scores 0.0" do
      assert {:ok, %ModerationResponse{results: [result]}} = FakeModeration.moderate(request(), [])

      assert map_size(result.categories) == 13
      assert map_size(result.category_scores) == 13
      assert Map.keys(result.categories) == Map.keys(result.category_scores)
      assert "self-harm/intent" in Map.keys(result.categories)
      assert Enum.all?(Map.values(result.categories), &(&1 == false))
      assert Enum.all?(Map.values(result.category_scores), &(&1 == 0.0))
      assert Enum.all?(Map.values(result.category_scores), &is_float/1)
    end

    test "flagged?/1 is false for the default verdict" do
      assert {:ok, resp} = FakeModeration.moderate(request(input: ["a", "b"]), [])
      refute ModerationResponse.flagged?(resp)
    end

    test "propagates request_id, model, metadata, and provider onto the response" do
      req = request(model: "omni-moderation-latest", metadata: %{trace: "t"})

      assert {:ok, resp} = FakeModeration.moderate(req, request_id: "rid-9")
      assert resp.request_id == "rid-9"
      assert resp.model == "omni-moderation-latest"
      assert resp.metadata == %{trace: "t"}
      assert resp.provider == :fake
    end
  end

  describe "moderate/2 scripted results" do
    test "an {:ok, results} entry returns those results verbatim" do
      results = [
        ModerationResult.new(flagged: true, categories: %{"hate" => true}, index: 0),
        ModerationResult.new(flagged: false, index: 1)
      ]

      opts = [adapter_opts: [moderation_script: [{:ok, results}]]]

      assert {:ok, %ModerationResponse{results: ^results}} =
               FakeModeration.moderate(request(input: ["a", "b"]), opts)
    end

    test "a {:flagged, categories} entry synthesizes one flagged result" do
      opts = [adapter_opts: Fixtures.flagged(["violence", "hate"])]

      assert {:ok, %ModerationResponse{results: [result]} = resp} =
               FakeModeration.moderate(request(), opts)

      assert result.flagged == true
      assert result.index == 0
      assert ModerationResult.flagged_categories(result) == ["hate", "violence"]
      assert ModerationResult.score(result, "violence") == 1.0
      assert ModerationResult.score(result, "hate") == 1.0
      assert ModerationResponse.flagged?(resp)
      assert ModerationResponse.flagged_categories(resp) == ["hate", "violence"]
    end

    test "a {:flagged, categories} entry reports the un-flagged omni categories as false" do
      opts = [adapter_opts: Fixtures.flagged(["violence"])]

      assert {:ok, %ModerationResponse{results: [result]}} =
               FakeModeration.moderate(request(), opts)

      assert map_size(result.categories) == 13
      assert result.categories["hate"] == false
      assert result.category_scores["hate"] == 0.0
    end

    test "a scripted clean batch returns one clean result per scripted entry" do
      opts = [adapter_opts: Fixtures.clean_batch(2)]

      assert {:ok, %ModerationResponse{results: results} = resp} =
               FakeModeration.moderate(request(input: ["a", "b"]), opts)

      assert results == [Fixtures.clean(0), Fixtures.clean(1)]
      refute ModerationResponse.flagged?(resp)
    end

    test "a scripted {:error, %ModerationAdapterError{}} entry is returned verbatim" do
      opts = [adapter_opts: Fixtures.rate_limited()]

      assert {:error, %ModerationAdapterError{} = err} = FakeModeration.moderate(request(), opts)
      assert err.reason == :rate_limited
      assert err.provider == :fake
      assert err.retry_after_ms == 250
    end

    test "successive calls advance through the script" do
      cursor = FakeModeration.start_script_cursor()

      script = [
        {:flagged, ["violence"]},
        {:ok, [ModerationResult.new(flagged: false)]}
      ]

      opts = [adapter_opts: [moderation_script: script, script_cursor: cursor]]

      assert {:ok, first} = FakeModeration.moderate(request(), opts)
      assert {:ok, second} = FakeModeration.moderate(request(), opts)

      assert ModerationResponse.flagged?(first)
      refute ModerationResponse.flagged?(second)
      assert FakeModeration.cursor_index(cursor) == 2
    end

    test "running past the end of a NON-EMPTY script errors rather than defaulting" do
      cursor = FakeModeration.start_script_cursor()
      opts = [adapter_opts: Fixtures.flagged(["violence"]) ++ [script_cursor: cursor]]

      assert {:ok, first} = FakeModeration.moderate(request(), opts)
      assert ModerationResponse.flagged?(first)

      # A spent script is a caller off-by-one, not a request for the benign
      # default — answering it with a clean verdict would make that bug green.
      assert {:error, %ModerationAdapterError{reason: :unknown, metadata: meta}} =
               FakeModeration.moderate(request(), opts)

      assert meta.cause == :moderation_script_exhausted
    end

    test "an absent script still yields the default clean verdict" do
      assert {:ok, resp} = FakeModeration.moderate(request(), [])
      refute ModerationResponse.flagged?(resp)

      assert {:ok, resp} =
               FakeModeration.moderate(request(), adapter_opts: [moderation_script: []])

      refute ModerationResponse.flagged?(resp)
    end
  end

  describe "moderate/2 gates" do
    test "input: [] returns :invalid_request before consuming a script entry" do
      cursor = FakeModeration.start_script_cursor()
      opts = [adapter_opts: Fixtures.flagged(["violence"]) ++ [script_cursor: cursor]]

      assert {:error, %ModerationAdapterError{reason: :invalid_request, metadata: meta}} =
               FakeModeration.moderate(ModerationRequest.new(input: []), opts)

      assert meta.field == :input
      # The cursor never moved, so the script entry is still the next one up.
      assert FakeModeration.cursor_index(cursor) == 0
    end

    test "over max_batch_size returns :batch_too_large with metadata.count and metadata.max" do
      max = FakeModeration.max_batch_size()
      req = ModerationRequest.new(input: List.duplicate("x", max + 1))

      assert {:error, %ModerationAdapterError{reason: :batch_too_large, metadata: meta}} =
               FakeModeration.moderate(req, [])

      assert meta.count == max + 1
      assert meta.max == max
    end

    test "input exactly at max_batch_size passes the gate" do
      max = FakeModeration.max_batch_size()
      req = ModerationRequest.new(input: List.duplicate("x", max))

      assert {:ok, %ModerationResponse{results: results}} = FakeModeration.moderate(req, [])
      assert length(results) == max
    end
  end

  describe "multimodal cardinality" do
    test "multimodal input returns exactly one result at index 0" do
      part = ImagePart.new(ALLM.Image.from_binary(<<0, 1, 2>>, "image/png"))
      req = ModerationRequest.new(input: ["look at this", part])

      assert ModerationRequest.multimodal?(req)

      assert {:ok, %ModerationResponse{results: [%ModerationResult{index: 0}]}} =
               FakeModeration.moderate(req, [])
    end
  end

  describe "cursor precedence" do
    test "two content-equal engines with distinct :id values do not share a cursor" do
      a = Fixtures.engine(Fixtures.flagged(["violence"]))
      b = Fixtures.engine(Fixtures.flagged(["violence"]))

      assert a.adapter_opts == b.adapter_opts
      refute a.id == b.id

      opts_a = [adapter_opts: Engine.put_cursor_key(a.adapter_opts, a)]
      opts_b = [adapter_opts: Engine.put_cursor_key(b.adapter_opts, b)]

      assert {:ok, first} = FakeModeration.moderate(request(), opts_a)
      assert {:ok, second} = FakeModeration.moderate(request(), opts_b)

      # A shared cursor would have pushed b's read past the single entry and
      # produced the :moderation_script_exhausted error.
      assert ModerationResponse.flagged?(first)
      assert ModerationResponse.flagged?(second)
    end

    test "content-equal scripts with no cursor_key DO share the phash2 cursor" do
      opts = [adapter_opts: [moderation_script: [{:flagged, ["violence"]}]]]

      assert {:ok, first} = FakeModeration.moderate(request(), opts)
      assert ModerationResponse.flagged?(first)

      # The documented direct-call footgun: the second call reads the SAME
      # slot, lands past the single entry, and reports the spent script.
      assert {:error, %ModerationAdapterError{metadata: %{cause: :moderation_script_exhausted}}} =
               FakeModeration.moderate(request(), opts)
    end

    test "an explicit :script_cursor Agent pid outranks :cursor_key" do
      cursor = FakeModeration.start_script_cursor()
      script = [{:flagged, ["a"]}, {:flagged, ["b"]}]
      opts = [adapter_opts: [moderation_script: script, cursor_key: 7, script_cursor: cursor]]

      assert {:ok, _} = FakeModeration.moderate(request(), opts)
      assert {:ok, _} = FakeModeration.moderate(request(), opts)
      assert FakeModeration.cursor_index(cursor) == 2
    end

    test "start_script_cursor/0 starts at 0" do
      assert FakeModeration.cursor_index(FakeModeration.start_script_cursor()) == 0
    end
  end

  describe "capture_pid seam" do
    test "sends the request to :capture_pid before any gate" do
      req = ModerationRequest.new(input: [])
      opts = [adapter_opts: [moderation_script: [], capture_pid: self()]]

      assert {:error, %ModerationAdapterError{reason: :invalid_request}} =
               FakeModeration.moderate(req, opts)

      assert_receive {FakeModeration, :call, %{request: ^req, opts: ^opts}}
    end

    test "fires once per call on the happy path" do
      opts = [adapter_opts: [capture_pid: self()]]

      assert {:ok, _} = FakeModeration.moderate(request(), opts)
      assert_receive {FakeModeration, :call, _}
      refute_receive {FakeModeration, :call, _}, 20
    end

    test "a non-pid :capture_pid is a no-op" do
      opts = [adapter_opts: [capture_pid: :not_a_pid]]
      assert {:ok, _} = FakeModeration.moderate(request(), opts)
    end
  end

  describe "{:retry_until_call, n}" do
    test "returns :rate_limited until the budget is spent, then succeeds" do
      # A leading non-error entry is load-bearing: it forces `advance` to WRITE
      # the process-dict slot that `peek` later READS.
      script = [
        {:ok, [ModerationResult.new(flagged: false)]},
        {:retry_until_call, 3},
        {:flagged, ["violence"]}
      ]

      opts = [adapter_opts: [moderation_script: script, cursor_key: :retry_case]]

      assert {:ok, _} = FakeModeration.moderate(request(), opts)

      assert {:error, %ModerationAdapterError{reason: :rate_limited, retry_after_ms: 0}} =
               FakeModeration.moderate(request(), opts)

      assert {:error, %ModerationAdapterError{reason: :rate_limited}} =
               FakeModeration.moderate(request(), opts)

      assert {:ok, resp} = FakeModeration.moderate(request(), opts)
      assert ModerationResponse.flagged?(resp)
    end

    test "{:retry_until_call, 1} dispatches the next entry on the first call" do
      cursor = FakeModeration.start_script_cursor()
      opts = [adapter_opts: Fixtures.retry_until_call(1, ["violence"]) ++ [script_cursor: cursor]]

      assert {:ok, resp} = FakeModeration.moderate(request(), opts)
      assert ModerationResponse.flagged?(resp)
    end

    test "consecutive retry entries chain into a layered budget instead of raising" do
      cursor = FakeModeration.start_script_cursor()

      script = [
        {:retry_until_call, 2},
        {:retry_until_call, 2},
        {:flagged, ["violence"]}
      ]

      assert :ok = FakeModeration.script(script)

      opts = [adapter_opts: [moderation_script: script, script_cursor: cursor]]

      assert {:error, %ModerationAdapterError{reason: :rate_limited}} =
               FakeModeration.moderate(request(), opts)

      assert {:error, %ModerationAdapterError{reason: :rate_limited}} =
               FakeModeration.moderate(request(), opts)

      assert {:ok, resp} = FakeModeration.moderate(request(), opts)
      assert ModerationResponse.flagged?(resp)
    end

    test "a retry budget that runs off the end errors rather than reporting success" do
      cursor = FakeModeration.start_script_cursor()
      opts = [adapter_opts: [moderation_script: [{:retry_until_call, 1}], script_cursor: cursor]]

      # Otherwise "fail once, then check my retry handler" would silently
      # succeed on call 1 with no retry exercised at all.
      assert {:error, %ModerationAdapterError{reason: :unknown, metadata: meta}} =
               FakeModeration.moderate(request(), opts)

      assert meta.cause == :moderation_script_exhausted
    end

    test "two content-equal-script engines with distinct :id values do not share a retry budget" do
      script = [{:retry_until_call, 2}, {:flagged, ["violence"]}]

      e1 = Engine.new(moderation_adapter: FakeModeration, adapter_opts: [moderation_script: script])
      e2 = Engine.new(moderation_adapter: FakeModeration, adapter_opts: [moderation_script: script])

      refute e1.id == e2.id

      opts1 = [adapter_opts: Engine.put_cursor_key(e1.adapter_opts, e1)]
      opts2 = [adapter_opts: Engine.put_cursor_key(e2.adapter_opts, e2)]

      # Engine A burns the whole budget.
      assert {:error, %ModerationAdapterError{reason: :rate_limited}} =
               FakeModeration.moderate(request(), opts1)

      assert {:ok, resp1} = FakeModeration.moderate(request(), opts1)
      assert ModerationResponse.flagged_categories(resp1) == ["violence"]

      # Engine B must start from a fresh budget in the same process — keying
      # the retry counter on :erlang.phash2(script) alone would let it skip
      # straight to the success entry.
      assert {:error, %ModerationAdapterError{reason: :rate_limited}} =
               FakeModeration.moderate(request(), opts2)

      assert {:ok, resp2} = FakeModeration.moderate(request(), opts2)
      assert ModerationResponse.flagged_categories(resp2) == ["violence"]
    end

    test "two distinct :script_cursor agents do not share a retry budget" do
      script = [{:retry_until_call, 2}, {:flagged, ["hate"]}]
      c1 = FakeModeration.start_script_cursor()
      c2 = FakeModeration.start_script_cursor()
      opts1 = [adapter_opts: [moderation_script: script, script_cursor: c1]]
      opts2 = [adapter_opts: [moderation_script: script, script_cursor: c2]]

      assert {:error, %ModerationAdapterError{reason: :rate_limited}} =
               FakeModeration.moderate(request(), opts1)

      assert {:error, %ModerationAdapterError{reason: :rate_limited}} =
               FakeModeration.moderate(request(), opts2)

      assert {:ok, r1} = FakeModeration.moderate(request(), opts1)
      assert {:ok, r2} = FakeModeration.moderate(request(), opts2)
      assert ModerationResponse.flagged_categories(r1) == ["hate"]
      assert ModerationResponse.flagged_categories(r2) == ["hate"]
    end
  end

  describe "script/1" do
    test "accepts every documented entry shape" do
      err = ModerationAdapterError.new(:rate_limited)

      assert :ok =
               FakeModeration.script([
                 {:ok, [ModerationResult.new(flagged: false)]},
                 {:flagged, ["violence"]},
                 {:error, err},
                 {:retry_until_call, 2}
               ])
    end

    test "raises ArgumentError on an unrecognized entry" do
      assert_raise ArgumentError, ~r/invalid FakeModeration script entry/, fn ->
        FakeModeration.script([{:nope, 1}])
      end
    end

    test "raises ArgumentError when :flagged carries a non-string category" do
      assert_raise ArgumentError, ~r/invalid FakeModeration script entry/, fn ->
        FakeModeration.script([{:flagged, [:violence]}])
      end
    end
  end
end
