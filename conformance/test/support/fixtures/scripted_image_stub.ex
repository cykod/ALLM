defmodule ALLM.Test.Fixtures.ScriptedImageStub do
  @moduledoc """
  Permanent test fixture that implements `ALLM.ImageAdapter`. Used by
  `allm_conformance`'s self-test for `ALLM.Test.ImageAdapterConformance`.

  ## Script contract

      adapter_opts: [
        image_script: [
          {:ok, [%ALLM.Image{...}, ...]},
          {:ok, [%ALLM.Image{...}], usage: %ALLM.ImageUsage{...}},
          {:error, %ALLM.Error.ImageAdapterError{...}}
        ]
      ]

  Per-call advancing of `adapter_opts[:image_script]` is keyed off an
  optional `adapter_opts[:script_cursor]` Agent pid (from
  `start_script_cursor/0`); without one the stub reads entry 0 each call
  (the single-call contract used by every conformance case).

  ## Per-instance supported_operations

  `supported_operations/0` returns a module attribute. The conformance
  suite uses `ALLM.Test.Fixtures.ScriptedImageStub` for the
  generate/edit/variation happy paths; for the unsupported-operation
  case it uses `ALLM.Test.Fixtures.GenerateOnlyImageStub` (defined in
  this same file) which narrows the list to `[:generate]`.

  ## Scope

  Permanent fixture under `conformance/test/support/`. Mirrors
  `ALLM.Test.Fixtures.StubAdapter`'s role for v0.2 chat conformance.
  """

  @behaviour ALLM.ImageAdapter

  alias ALLM.Error.ImageAdapterError
  alias ALLM.{Image, ImageRequest, ImageResponse, ImageUsage}

  @doc """
  Start a cursor Agent. Pass the returned pid as
  `adapter_opts[:script_cursor]` to advance entries across multi-call
  tests.
  """
  @spec start_script_cursor() :: pid()
  def start_script_cursor do
    {:ok, pid} = Agent.start_link(fn -> 0 end)
    pid
  end

  @impl ALLM.ImageAdapter
  @spec supported_operations() :: [ImageRequest.operation()]
  def supported_operations, do: [:generate, :edit, :variation]

  @impl ALLM.ImageAdapter
  def generate(%ImageRequest{} = request, opts) when is_list(opts) do
    if request.operation in supported_operations() do
      run_scripted(request, opts)
    else
      {:error,
       ImageAdapterError.new(:unsupported_operation,
         message: "operation #{inspect(request.operation)} not supported",
         metadata: %{operation: request.operation}
       )}
    end
  end

  defp run_scripted(%ImageRequest{} = request, opts) do
    adapter_opts = Keyword.get(opts, :adapter_opts, [])
    script = Keyword.get(adapter_opts, :image_script, [])
    cursor = Keyword.get(adapter_opts, :script_cursor)
    index = advance(cursor)

    case Enum.at(script, index) do
      nil ->
        img = Image.from_binary(<<0>>, "image/png")
        {:ok, build_response([img], %ImageUsage{images: 1}, request, opts)}

      {:ok, images} when is_list(images) ->
        {:ok, build_response(images, %ImageUsage{images: length(images)}, request, opts)}

      {:ok, images, kw} when is_list(images) and is_list(kw) ->
        usage = Keyword.get(kw, :usage) || %ImageUsage{images: length(images)}
        {:ok, build_response(images, usage, request, opts)}

      {:error, %ImageAdapterError{} = err} ->
        {:error, err}
    end
  end

  defp advance(nil), do: 0

  defp advance(pid) when is_pid(pid),
    do: Agent.get_and_update(pid, fn i -> {i, i + 1} end)

  defp build_response(images, usage, %ImageRequest{} = request, opts) do
    %ImageResponse{
      id: nil,
      request_id: Keyword.get(opts, :request_id),
      model: request.model,
      images: images,
      usage: usage,
      raw: nil,
      metadata: request.metadata
    }
  end
end

defmodule ALLM.Test.Fixtures.GenerateOnlyImageStub do
  @moduledoc """
  Sister fixture to `ALLM.Test.Fixtures.ScriptedImageStub` that narrows
  `supported_operations/0` to `[:generate]` so the conformance suite can
  exercise the unsupported-operation rejection path.
  """

  @behaviour ALLM.ImageAdapter

  alias ALLM.Error.ImageAdapterError
  alias ALLM.{ImageRequest, ImageResponse, ImageUsage}

  @impl ALLM.ImageAdapter
  @spec supported_operations() :: [ImageRequest.operation()]
  def supported_operations, do: [:generate]

  @impl ALLM.ImageAdapter
  def generate(%ImageRequest{operation: :generate} = request, opts) when is_list(opts) do
    img = ALLM.Image.from_binary(<<0>>, "image/png")

    {:ok,
     %ImageResponse{
       id: nil,
       request_id: Keyword.get(opts, :request_id),
       model: request.model,
       images: [img],
       usage: %ImageUsage{images: 1},
       raw: nil,
       metadata: request.metadata
     }}
  end

  def generate(%ImageRequest{operation: op}, _opts) do
    {:error,
     ImageAdapterError.new(:unsupported_operation,
       message: "operation #{inspect(op)} not supported",
       metadata: %{operation: op}
     )}
  end
end
