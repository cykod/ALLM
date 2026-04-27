defmodule ALLM.ImageAdapterTest do
  use ExUnit.Case, async: true

  describe "behaviour callbacks" do
    test "declares the three expected callbacks" do
      callbacks = ALLM.ImageAdapter.behaviour_info(:callbacks)

      assert {:generate, 2} in callbacks
      assert {:prepare_request, 2} in callbacks
      assert {:supported_operations, 0} in callbacks
    end

    test "marks prepare_request/2 as optional" do
      assert ALLM.ImageAdapter.behaviour_info(:optional_callbacks) == [prepare_request: 2]
    end

    test "supported_operations/0 and generate/2 are required (not optional)" do
      optional = ALLM.ImageAdapter.behaviour_info(:optional_callbacks)
      refute {:supported_operations, 0} in optional
      refute {:generate, 2} in optional
    end

    test "compiling a module with @behaviour ALLM.ImageAdapter and only required callbacks succeeds" do
      defmodule MinimalImageAdapter do
        @behaviour ALLM.ImageAdapter

        @impl ALLM.ImageAdapter
        def supported_operations, do: [:generate]

        @impl ALLM.ImageAdapter
        def generate(_req, _opts) do
          {:ok, %ALLM.ImageResponse{}}
        end
      end

      assert MinimalImageAdapter.supported_operations() == [:generate]
      assert function_exported?(MinimalImageAdapter, :generate, 2)
      refute function_exported?(MinimalImageAdapter, :prepare_request, 2)
    end
  end
end
