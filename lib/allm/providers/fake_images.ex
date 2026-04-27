defmodule ALLM.Providers.FakeImages do
  @moduledoc """
  Deterministic, scripted adapter for image-generation testing. Implements
  `ALLM.ImageAdapter`. See spec §35.8.

  Layer B — runtime. FakeImages is the canonical testing image adapter; it
  ships in `lib/` (not `test/support/`) because users need it for their
  own application tests, mirroring the v0.2 `ALLM.Providers.Fake`
  precedent.

  ## What FakeImages is (and isn't)

  FakeImages **mostly ignores the `%ALLM.ImageRequest{}`** passed to
  `generate/2`. It does inspect `:operation` to enforce the
  `supported_operations/0` gate, and reads `:metadata` to round-trip onto
  the response per the `ImageAdapter` contract; otherwise the scripted
  response is produced irrespective of the request.

  ## Script shapes

  `opts[:adapter_opts][:image_script]` accepts a list of script entries.
  See `script/1` for the full grammar.

      adapter_opts: [
        image_script: [
          {:ok, [%ALLM.Image{...}], usage: %ALLM.ImageUsage{...}},
          {:error, %ALLM.Error.ImageAdapterError{reason: :rate_limited}}
        ]
      ]

  Multi-call scripting uses the same list — each call advances a
  process-local cursor (or an explicit Agent cursor passed via
  `adapter_opts[:script_cursor]` from `start_script_cursor/0`).

  ## Cursor behaviour

  By default the cursor lives in the process dictionary at
  `{:allm_fake_images_cursor, :erlang.phash2(scripts)}` — isolated per
  ExUnit test process (`async: true`), GC'd on pid-down. Pass
  `adapter_opts[:script_cursor]` with the pid returned from
  `start_script_cursor/0` to share / isolate cursors explicitly across
  processes.

  ## Test-only capture seam

  Pass `adapter_opts[:capture_pid]` with a pid to receive a side-channel
  message every time `generate/2` is invoked, BEFORE the script is
  consulted. The message has the form:

      {ALLM.Providers.FakeImages, :call, %{request: request, opts: opts}}

  This is purely a side-channel — it does NOT affect the response. It
  exists so test files can assert on what the adapter received without
  the `Process.register/2` + named-pid pattern (which forces
  `async: false`). With `:capture_pid` in scope, tests stay
  `async: true` and use `assert_receive {ALLM.Providers.FakeImages,
  :call, _}` to pattern-match on the captured payload.

  ## Examples

      iex> img = ALLM.Image.from_binary(<<137, 80, 78, 71>>, "image/png")
      iex> req = ALLM.ImageRequest.new(prompt: "a kestrel")
      iex> opts = [adapter_opts: [image_script: [{:ok, [img]}]]]
      iex> {:ok, resp} = ALLM.Providers.FakeImages.generate(req, opts)
      iex> length(resp.images)
      1
  """

  @behaviour ALLM.ImageAdapter

  alias ALLM.Error.ImageAdapterError
  alias ALLM.{Image, ImageRequest, ImageResponse, ImageUsage}

  @adapter_supported_operations [:generate, :edit, :variation]

  # ---------------------------------------------------------------------------
  # ALLM.ImageAdapter — supported_operations/0
  # ---------------------------------------------------------------------------

  @doc """
  Return the list of operations FakeImages can perform.

  Defaults to all three image operations; tests asserting per-adapter
  rejection paths typically construct a custom `@behaviour
  ALLM.ImageAdapter` module rather than narrowing this list.

  ## Examples

      iex> ALLM.Providers.FakeImages.supported_operations()
      [:generate, :edit, :variation]
  """
  @impl ALLM.ImageAdapter
  @spec supported_operations() :: [ImageRequest.operation()]
  def supported_operations, do: @adapter_supported_operations

  # ---------------------------------------------------------------------------
  # ALLM.ImageAdapter — generate/2
  # ---------------------------------------------------------------------------

  @doc """
  Execute a scripted image-generation request. See spec §35.3.

  Returns `{:error, %ImageAdapterError{reason: :unsupported_operation,
  metadata: %{operation: op}}}` BEFORE consulting the script when
  `request.operation not in supported_operations()` (entry-point gate per
  the conformance contract).

  Otherwise reads the script from `opts[:adapter_opts][:image_script]`,
  advances the process-local cursor, and returns the entry verbatim.
  Empty / exhausted script returns
  `{:error, %ImageAdapterError{reason: :unknown, metadata: %{cause:
  :no_scripted_image}}}`.

  Propagates `opts[:request_id]` onto `response.request_id` when the
  script does not already populate it. Round-trips `request.metadata`
  onto `response.metadata` when the script does not populate it.

  When `opts[:adapter_opts][:capture_pid]` is a pid, sends
  `{ALLM.Providers.FakeImages, :call, %{request: request, opts: opts}}`
  to that pid BEFORE the operation gate fires (so even rejected calls
  are captured). Side-channel only — does not affect the response.

  ## Examples

      iex> img = ALLM.Image.from_url("https://example.com/x.png")
      iex> req = ALLM.ImageRequest.new(prompt: "a kestrel")
      iex> opts = [adapter_opts: [image_script: [{:ok, [img]}]]]
      iex> {:ok, resp} = ALLM.Providers.FakeImages.generate(req, opts)
      iex> resp.usage.images
      1

      iex> img = ALLM.Image.from_binary(<<1>>, "image/png")
      iex> req = ALLM.ImageRequest.new(prompt: "a kestrel")
      iex> opts = [adapter_opts: [image_script: [{:ok, [img]}], capture_pid: self()]]
      iex> {:ok, _} = ALLM.Providers.FakeImages.generate(req, opts)
      iex> receive do
      ...>   {ALLM.Providers.FakeImages, :call, %{request: ^req}} -> :ok
      ...> after
      ...>   0 -> :no_message
      ...> end
      :ok
  """
  @impl ALLM.ImageAdapter
  @spec generate(ImageRequest.t(), keyword()) ::
          {:ok, ImageResponse.t()} | {:error, ImageAdapterError.t()}
  def generate(%ImageRequest{} = request, opts) when is_list(opts) do
    maybe_capture(request, opts)

    if request.operation in supported_operations() do
      run_scripted(request, opts)
    else
      {:error,
       ImageAdapterError.new(:unsupported_operation,
         message:
           "operation #{inspect(request.operation)} not supported by " <>
             inspect(__MODULE__),
         metadata: %{operation: request.operation}
       )}
    end
  end

  # ---------------------------------------------------------------------------
  # Public helpers
  # ---------------------------------------------------------------------------

  @doc """
  Document and validate the script grammar for `adapter_opts[:image_script]`.

  Each entry is one of:

    * `{:ok, [%Image{}, ...]}` — return the listed images plus a default
      `%ImageUsage{images: length(images)}`.
    * `{:ok, [%Image{}, ...], usage: %ImageUsage{}}` — return the listed
      images plus the supplied usage.
    * `{:error, %ImageAdapterError{}}` — return the struct verbatim.

  Returns `:ok` when the script is well-formed; raises `ArgumentError`
  on the first invalid entry. (Validation is opt-in — the runtime
  `generate/2` path tolerates a mix of legal entries and surfaces a
  cursor-exhausted shape on `nil` lookups.)

  ## Examples

      iex> img = ALLM.Image.from_binary(<<1>>, "image/png")
      iex> ALLM.Providers.FakeImages.script([{:ok, [img]}])
      :ok
  """
  @spec script([script_entry()]) :: :ok
  def script(entries) when is_list(entries) do
    Enum.each(entries, &validate_entry!/1)
    :ok
  end

  @typedoc "One scripted image-generation result."
  @type script_entry ::
          {:ok, [Image.t()]}
          | {:ok, [Image.t()], keyword()}
          | {:error, ImageAdapterError.t()}

  @doc """
  Start an Agent-backed script cursor for cross-process multi-call
  scripting and for disambiguating content-equal scripts in the same
  process.

  Pass the returned pid as `adapter_opts[:script_cursor]`; subsequent
  calls increment the cursor on the Agent rather than on the process
  dictionary.

  ## Examples

      iex> pid = ALLM.Providers.FakeImages.start_script_cursor()
      iex> ALLM.Providers.FakeImages.cursor_index(pid)
      0
  """
  @spec start_script_cursor() :: pid()
  def start_script_cursor do
    {:ok, pid} = Agent.start_link(fn -> 0 end)
    pid
  end

  @doc """
  Read the current cursor index for an Agent-backed cursor. Used in
  tests to assert how many calls have been consumed.
  """
  @spec cursor_index(pid()) :: non_neg_integer()
  def cursor_index(pid) when is_pid(pid), do: Agent.get(pid, & &1)

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  # Test-only side-channel. Sends a tagged message to the configured pid
  # BEFORE the operation gate / script consult so that even rejected
  # operations are captured. No-op when `:capture_pid` is absent or not a
  # live pid.
  defp maybe_capture(%ImageRequest{} = request, opts) do
    adapter_opts = Keyword.get(opts, :adapter_opts, [])

    case Keyword.get(adapter_opts, :capture_pid) do
      pid when is_pid(pid) ->
        send(pid, {__MODULE__, :call, %{request: request, opts: opts}})
        :ok

      _ ->
        :ok
    end
  end

  defp run_scripted(%ImageRequest{} = request, opts) do
    adapter_opts = Keyword.get(opts, :adapter_opts, [])
    script = Keyword.get(adapter_opts, :image_script, [])

    cursor = advance_cursor(script, adapter_opts)

    case Enum.at(script, cursor) do
      nil ->
        {:error,
         ImageAdapterError.new(:unknown,
           message: "no scripted image",
           metadata: %{cause: :no_scripted_image}
         )}

      entry ->
        interpret_entry(entry, request, opts)
    end
  end

  # `{:ok, images}` — default usage of `%ImageUsage{images: length(images)}`.
  defp interpret_entry({:ok, images}, request, opts) when is_list(images) do
    usage = %ImageUsage{images: length(images)}
    {:ok, build_response(images, usage, request, opts)}
  end

  # `{:ok, images, opts_kw}` — caller supplies usage / extras.
  defp interpret_entry({:ok, images, kw}, request, opts)
       when is_list(images) and is_list(kw) do
    usage = Keyword.get(kw, :usage) || %ImageUsage{images: length(images)}
    {:ok, build_response(images, usage, request, opts)}
  end

  # `{:error, %ImageAdapterError{}}` — return struct verbatim.
  defp interpret_entry({:error, %ImageAdapterError{} = err}, _request, _opts) do
    {:error, err}
  end

  defp build_response(images, usage, %ImageRequest{} = request, opts) do
    request_id = Keyword.get(opts, :request_id)

    %ImageResponse{
      id: nil,
      request_id: request_id,
      model: request.model,
      images: images,
      usage: usage,
      raw: nil,
      metadata: request.metadata
    }
  end

  # ---------------------------------------------------------------------------
  # Cursor management
  # ---------------------------------------------------------------------------

  defp advance_cursor(script, adapter_opts) do
    case Keyword.get(adapter_opts, :script_cursor) do
      nil ->
        advance_process_dict_cursor(script)

      pid when is_pid(pid) ->
        Agent.get_and_update(pid, fn i -> {i, i + 1} end)
    end
  end

  defp advance_process_dict_cursor(script) do
    key = {:allm_fake_images_cursor, :erlang.phash2(script)}
    current = Process.get(key, 0)
    Process.put(key, current + 1)
    current
  end

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  defp validate_entry!({:ok, images}) when is_list(images), do: :ok

  defp validate_entry!({:ok, images, kw}) when is_list(images) and is_list(kw), do: :ok

  defp validate_entry!({:error, %ImageAdapterError{}}), do: :ok

  defp validate_entry!(other) do
    raise ArgumentError,
          "invalid FakeImages script entry: #{inspect(other)} " <>
            "(expected {:ok, [%Image{}]}, {:ok, [%Image{}], opts}, " <>
            "or {:error, %ImageAdapterError{}})"
  end
end
