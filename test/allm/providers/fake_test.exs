defmodule ALLM.Providers.FakeTest do
  use ExUnit.Case, async: true

  alias ALLM.Error.AdapterError
  alias ALLM.{Message, Request, Response}
  alias ALLM.Providers.Fake

  doctest ALLM.Providers.Fake

  # A fresh request for every test — Fake ignores the request, so content
  # doesn't matter, but constructing one keeps the call shape realistic.
  defp fake_request(content \\ "hi") do
    Request.new([%Message{role: :user, content: content}])
  end

  # ---------------------------------------------------------------------------
  # Happy path (§31 shape)
  # ---------------------------------------------------------------------------

  describe "generate/2 — happy path (§31 shape)" do
    test "with script: [{:text, \"hi\"}, {:finish, :stop}] returns output_text + finish_reason" do
      opts = [adapter_opts: [script: [{:text, "hi"}, {:finish, :stop}]]]

      assert {:ok, %Response{output_text: "hi", finish_reason: :stop}} =
               Fake.generate(fake_request(), opts)
    end

    test "with scripts: [[…]] single-call is equivalent to script:" do
      opts = [adapter_opts: [scripts: [[{:text, "call_1"}, {:finish, :stop}]]]]

      assert {:ok, %Response{output_text: "call_1", finish_reason: :stop}} =
               Fake.generate(fake_request(), opts)
    end

    test "multi-call: scripts of 2 advance the process-dict cursor across calls" do
      opts = [
        adapter_opts: [
          scripts: [
            [{:text, "a"}, {:finish, :stop}],
            [{:text, "b"}, {:finish, :stop}]
          ]
        ]
      ]

      assert {:ok, %Response{output_text: "a"}} = Fake.generate(fake_request(), opts)
      assert {:ok, %Response{output_text: "b"}} = Fake.generate(fake_request(), opts)

      # Third call past the last scripted turn → :no_scripted_response.
      assert {:error, %AdapterError{reason: :no_scripted_response}} =
               Fake.generate(fake_request(), opts)
    end

    test "multi-call with explicit :script_cursor advances via the Agent" do
      pid = Fake.start_script_cursor()

      opts = [
        adapter_opts: [
          scripts: [
            [{:text, "a"}, {:finish, :stop}],
            [{:text, "b"}, {:finish, :stop}]
          ],
          script_cursor: pid
        ]
      ]

      assert {:ok, %Response{output_text: "a"}} = Fake.generate(fake_request(), opts)
      assert {:ok, %Response{output_text: "b"}} = Fake.generate(fake_request(), opts)
      assert Fake.cursor_index(pid) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # Happy path (harness shape)
  # ---------------------------------------------------------------------------

  describe "generate/2 — happy path (harness shape)" do
    test "with script: [{:ok, %{output_text: \"hi\"}}] returns %Response{}" do
      opts = [adapter_opts: [script: [{:ok, %{output_text: "hi"}}]]]

      assert {:ok, %Response{output_text: "hi"}} = Fake.generate(fake_request(), opts)
    end

    test "with script: [{:error, :rate_limited, retry_after_ms: 500}] returns %AdapterError{}" do
      opts = [adapter_opts: [script: [{:error, :rate_limited, [retry_after_ms: 500]}]]]

      assert {:error, %AdapterError{reason: :rate_limited, retry_after_ms: 500}} =
               Fake.generate(fake_request(), opts)
    end
  end

  # ---------------------------------------------------------------------------
  # Error paths
  # ---------------------------------------------------------------------------

  describe "generate/2 — error paths" do
    test "empty script: [] returns empty Response with metadata.empty_script: true" do
      opts = [adapter_opts: [script: []]]

      assert {:ok, %Response{output_text: "", finish_reason: :stop, metadata: meta}} =
               Fake.generate(fake_request(), opts)

      assert meta[:empty_script] == true
    end

    test "empty scripts: [] returns script_exhausted_error" do
      opts = [adapter_opts: [scripts: []]]

      assert {:error, %AdapterError{reason: :no_scripted_response}} =
               Fake.generate(fake_request(), opts)
    end

    test "§31 {:error, :boom} entry returns AdapterError with :unknown + cause" do
      opts = [adapter_opts: [script: [{:text, "partial"}, {:error, :boom}]]]

      assert {:error, %AdapterError{reason: :unknown, cause: :boom}} =
               Fake.generate(fake_request(), opts)
    end

    test "mixing :script and :scripts raises ArgumentError at first call" do
      opts = [adapter_opts: [script: [], scripts: []]]

      assert_raise ArgumentError, ~r/cannot mix :script and :scripts/, fn ->
        Fake.generate(fake_request(), opts)
      end
    end

    test ":script_cursor that isn't a pid raises ArgumentError" do
      opts = [adapter_opts: [script: [{:text, "hi"}, {:finish, :stop}], script_cursor: 42]]

      assert_raise ArgumentError, ~r/:script_cursor must be a pid or nil/, fn ->
        Fake.generate(fake_request(), opts)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Request-ignoring
  # ---------------------------------------------------------------------------

  describe "generate/2 — request ignored" do
    test "same script produces same response regardless of request content" do
      opts = [adapter_opts: [script: [{:text, "out"}, {:finish, :stop}]]]
      cursor = Fake.start_script_cursor()
      opts_with_cursor = Keyword.update!(opts, :adapter_opts, &(&1 ++ [script_cursor: cursor]))

      # Multi-call same script but with an explicit cursor so each call reads
      # the script's only entry list (cursor stays at 0 when scripts is
      # single-call). Wait — with explicit cursor, it advances. Use scripts:
      # to pin behavior.
      multi_opts = [
        adapter_opts: [
          scripts: [
            [{:text, "out"}, {:finish, :stop}],
            [{:text, "out"}, {:finish, :stop}]
          ],
          script_cursor: cursor
        ]
      ]

      req_empty = Request.new([])
      req_tool = Request.new([%Message{role: :tool, content: "r", tool_call_id: "c"}])

      assert {:ok, %Response{output_text: "out"}} = Fake.generate(req_empty, multi_opts)
      assert {:ok, %Response{output_text: "out"}} = Fake.generate(req_tool, multi_opts)

      # Silence unused binding warnings.
      _ = opts
      _ = opts_with_cursor
    end
  end

  # ---------------------------------------------------------------------------
  # Cursor behaviour
  # ---------------------------------------------------------------------------

  describe "generate/2 — cursor behaviour" do
    test "default cursor: two engines with DIFFERENT scripts in the same process advance independently" do
      opts_a = [
        adapter_opts: [
          scripts: [
            [{:text, "a1"}, {:finish, :stop}],
            [{:text, "a2"}, {:finish, :stop}]
          ]
        ]
      ]

      opts_b = [
        adapter_opts: [
          scripts: [
            [{:text, "b1"}, {:finish, :stop}],
            [{:text, "b2"}, {:finish, :stop}]
          ]
        ]
      ]

      assert {:ok, %Response{output_text: "a1"}} = Fake.generate(fake_request(), opts_a)
      assert {:ok, %Response{output_text: "b1"}} = Fake.generate(fake_request(), opts_b)
      assert {:ok, %Response{output_text: "a2"}} = Fake.generate(fake_request(), opts_a)
      assert {:ok, %Response{output_text: "b2"}} = Fake.generate(fake_request(), opts_b)
    end

    @doc """
    Documented footgun — Non-obvious Decision #1 in the Phase 4 design doc.

    Two engines built with content-equal `scripts:` values in the same process
    share a cursor (key: `:erlang.phash2(scripts)`). Workaround: pass distinct
    `script_cursor: pid` Agents.
    """
    test "content-equal collision (documented footgun — see Non-obvious Decision #1)" do
      common_scripts = [
        [{:text, "a"}, {:finish, :stop}],
        [{:text, "b"}, {:finish, :stop}]
      ]

      opts1 = [adapter_opts: [scripts: common_scripts]]
      opts2 = [adapter_opts: [scripts: common_scripts]]

      # First engine's call consumes index 0 → "a".
      assert {:ok, %Response{output_text: "a"}} = Fake.generate(fake_request(), opts1)

      # Second engine's FIRST call reads index 1 (not 0) because the cursor
      # is keyed on :erlang.phash2(scripts) — content collision.
      assert {:ok, %Response{output_text: "b"}} = Fake.generate(fake_request(), opts2)
    end

    test "explicit :script_cursor pid disambiguates content-equal scripts" do
      common_scripts = [
        [{:text, "a"}, {:finish, :stop}],
        [{:text, "b"}, {:finish, :stop}]
      ]

      cursor1 = Fake.start_script_cursor()
      cursor2 = Fake.start_script_cursor()

      opts1 = [adapter_opts: [scripts: common_scripts, script_cursor: cursor1]]
      opts2 = [adapter_opts: [scripts: common_scripts, script_cursor: cursor2]]

      # Each engine's first call reads index 0 → "a" (workaround fires).
      assert {:ok, %Response{output_text: "a"}} = Fake.generate(fake_request(), opts1)
      assert {:ok, %Response{output_text: "a"}} = Fake.generate(fake_request(), opts2)
    end

    test "cross-process cursor sharing via explicit pid: Task sees parent's cursor" do
      scripts = [
        [{:text, "a"}, {:finish, :stop}],
        [{:text, "b"}, {:finish, :stop}]
      ]

      pid = Fake.start_script_cursor()
      opts = [adapter_opts: [scripts: scripts, script_cursor: pid]]

      assert {:ok, %Response{output_text: "a"}} = Fake.generate(fake_request(), opts)
      assert Fake.cursor_index(pid) == 1

      task =
        Task.async(fn ->
          Fake.generate(fake_request(), opts)
        end)

      assert {:ok, %Response{output_text: "b"}} = Task.await(task)
      assert Fake.cursor_index(pid) == 2
    end

    test "default cursor (process-dict) is NOT shared across processes" do
      scripts = [
        [{:text, "a"}, {:finish, :stop}],
        [{:text, "b"}, {:finish, :stop}]
      ]

      opts = [adapter_opts: [scripts: scripts]]

      # Parent advances once.
      assert {:ok, %Response{output_text: "a"}} = Fake.generate(fake_request(), opts)

      # Spawned task has its own process dict — reads index 0.
      task =
        Task.async(fn ->
          Fake.generate(fake_request(), opts)
        end)

      assert {:ok, %Response{output_text: "a"}} = Task.await(task)
    end
  end

  # ---------------------------------------------------------------------------
  # request_id propagation
  # ---------------------------------------------------------------------------

  describe "generate/2 — request_id propagation" do
    test "adapter_opts[:request_id] is copied onto Response.request_id" do
      opts = [
        adapter_opts: [
          script: [{:text, "hi"}, {:finish, :stop}],
          request_id: "req_abc"
        ]
      ]

      assert {:ok, %Response{request_id: "req_abc"}} = Fake.generate(fake_request(), opts)
    end
  end

  # ---------------------------------------------------------------------------
  # Conformance plug-in — inherits the 13 Phase 3 harness cases.
  # ---------------------------------------------------------------------------

  use ALLM.Test.AdapterConformance, adapter: ALLM.Providers.Fake
end
