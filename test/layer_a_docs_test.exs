defmodule LayerADocsTest do
  @moduledoc """
  Asserts the per-module Layer-A `@moduledoc` rewrite holds the contract:

    * Every Layer-A struct module has a non-empty `@moduledoc` (>100 chars).
    * Every Layer-A module's audit-script run is clean (zero banned tokens).
    * The existing `doctest <Struct>` test files (in `test/allm/<struct>_test.exs`)
      remain green — verified by virtue of `mix test` running them; this module
      doesn't re-register `doctest` to avoid duplicating test execution.
  """

  use ExUnit.Case, async: true

  @layer_a [
    ALLM.Message,
    ALLM.Request,
    ALLM.Response,
    ALLM.Thread,
    ALLM.Session,
    ALLM.Event,
    ALLM.Usage,
    ALLM.Tool,
    ALLM.ToolCall,
    ALLM.StepResult,
    ALLM.ChatResult,
    ALLM.ModelRef,
    ALLM.Image,
    ALLM.ImagePart,
    ALLM.TextPart,
    ALLM.ImageRequest,
    ALLM.ImageResponse,
    ALLM.ImageUsage,
    ALLM.Embedding,
    ALLM.EmbeddingRequest,
    ALLM.EmbeddingResponse
  ]

  @audit_paths Enum.map(@layer_a, fn mod ->
                 base =
                   mod
                   |> Module.split()
                   |> Enum.drop(1)
                   |> Enum.map(&Macro.underscore/1)
                   |> Path.join()

                 Path.expand("lib/allm/" <> base <> ".ex")
               end)

  describe "every Layer-A module has a substantial @moduledoc" do
    for mod <- @layer_a do
      test "#{inspect(mod)} @moduledoc length > 100 chars" do
        mod = unquote(mod)
        {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(mod)
        assert is_binary(moduledoc)

        assert byte_size(moduledoc) > 100,
               "#{inspect(mod)} @moduledoc is too short — Layer A modules must be self-contained for hexdocs readers"
      end
    end
  end

  describe "Layer-A audit cleanliness" do
    test "every Layer-A `.ex` returns 0 hits under the banned-token audit" do
      Code.require_file("scripts/audit_user_docs.exs")

      hits =
        @audit_paths
        |> Enum.flat_map(&Scripts.AuditUserDocs.scan_file/1)

      assert hits == [], "Layer-A audit failures: #{inspect(hits, limit: :infinity)}"
    end
  end
end
