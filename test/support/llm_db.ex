defmodule LLMDB do
  @moduledoc """
  Test-only fake of the published `:llm_db` Hex package surface — see Phase
  9.4 design Decision #5/#6.

  The module is named `LLMDB` (no `ALLM.` prefix) because that is the
  module name `ALLM.Capability` looks up via
  `Code.ensure_loaded?(Module.concat(["LLMDB"]))`. Only compiled in `:test`
  via `elixirc_paths(:test)` in `mix.exs`. The dep-absent path is exercised
  by setting `Application.put_env(:allm, :force_capability_absent, true)`
  which short-circuits `ALLM.Capability.catalog_loaded?/0` to `false` even
  with this module in the load path.
  """

  alias ALLM.ModelRef

  # Fixtures cover all four chat-capability shapes named by the Phase 9.4
  # design plus three image-capability shapes added in Phase 14.3 for the
  # `Capability.preflight_image/2` rejection-path tests.
  @fixtures %{
    "openai:gpt-4.1-mini" => %ModelRef{
      provider: :openai,
      id: "gpt-4.1-mini",
      capabilities: %{tools: %{enabled: true}, json_native: true},
      limits: %{context: 128_000, output: 16_000},
      pricing: %{input: 0.15, output: 0.6},
      metadata: %{source: :test_fake}
    },
    "anthropic:claude-3-haiku" => %ModelRef{
      provider: :anthropic,
      id: "claude-3-haiku",
      capabilities: %{tools: %{enabled: true}, json_native: true},
      limits: %{context: 200_000, output: 8192},
      pricing: %{input: 0.25, output: 1.25},
      metadata: %{source: :test_fake}
    },
    "local:no-tools" => %ModelRef{
      provider: :local,
      id: "no-tools",
      capabilities: %{tools: %{enabled: false}, json_native: true},
      limits: %{context: 8192, output: 2048},
      pricing: nil,
      metadata: %{source: :test_fake}
    },
    "local:no-json-native" => %ModelRef{
      provider: :local,
      id: "no-json-native",
      capabilities: %{tools: %{enabled: true}, json_native: false},
      limits: %{context: 8192, output: 2048},
      pricing: nil,
      metadata: %{source: :test_fake}
    },
    "openai:gpt-image-1" => %ModelRef{
      provider: :openai,
      id: "gpt-image-1",
      capabilities: %{
        tools: %{enabled: false},
        json_native: false,
        images_enabled: true,
        supported_image_operations: [:generate, :edit]
      },
      limits: %{context: 4000, output: nil},
      pricing: nil,
      metadata: %{source: :test_fake}
    },
    "openai:dall-e-3" => %ModelRef{
      provider: :openai,
      id: "dall-e-3",
      capabilities: %{
        tools: %{enabled: false},
        json_native: false,
        images_enabled: true,
        supported_image_operations: [:generate]
      },
      limits: %{context: 4000, output: nil},
      pricing: nil,
      metadata: %{source: :test_fake}
    },
    "local:no-images" => %ModelRef{
      provider: :local,
      id: "no-images",
      capabilities: %{
        tools: %{enabled: false},
        json_native: false,
        images_enabled: false,
        supported_image_operations: []
      },
      limits: %{context: 4000, output: nil},
      pricing: nil,
      metadata: %{source: :test_fake}
    },
    # Phase 17.1 — vision capability fixtures for `check_vision/3`.
    "openai:gpt-4o-mini" => %ModelRef{
      provider: :openai,
      id: "gpt-4o-mini",
      capabilities: %{tools: %{enabled: true}, json_native: true, vision: true},
      limits: %{context: 128_000, output: 16_000},
      pricing: %{input: 0.15, output: 0.6},
      metadata: %{source: :test_fake}
    },
    "local:no-vision" => %ModelRef{
      provider: :local,
      id: "no-vision",
      capabilities: %{tools: %{enabled: false}, json_native: false, vision: false},
      limits: %{context: 4000, output: nil},
      pricing: nil,
      metadata: %{source: :test_fake}
    }
  }

  @doc """
  Resolve a model identifier to a `%ALLM.ModelRef{}` from the in-memory
  fixture map.

  Accepts:

    * a string like `"openai:gpt-4.1-mini"` — looked up directly;
    * a tuple like `{:openai, "gpt-4.1-mini"}` — flattened to `"openai:gpt-4.1-mini"`;
    * a `%ALLM.ModelRef{}` — returned unchanged (idempotent);
    * `nil` — returned unchanged.

  An unrecognised string is returned unchanged so the caller can still
  receive a bare model identifier the adapter can handle without catalog
  knowledge — matches the published `:llm_db` package's "no match"
  behaviour for `model/1`.
  """
  @spec model(term()) :: ModelRef.t() | term()
  def model(%ModelRef{} = ref), do: ref
  def model(nil), do: nil

  def model(string) when is_binary(string) do
    case Map.fetch(@fixtures, string) do
      {:ok, ref} -> ref
      :error -> string
    end
  end

  def model({provider, id} = tuple) when is_atom(provider) and is_binary(id) do
    case Map.fetch(@fixtures, "#{provider}:#{id}") do
      {:ok, ref} -> ref
      :error -> tuple
    end
  end

  def model(other), do: other

  @doc """
  Capability-based selection. Walks the fixture set, returning the first
  `%ModelRef{}` whose capabilities satisfy every required key in
  `criteria[:require]` (a kwlist of capability atoms or
  `{path, expected}` tuples). Returns `{:error, :no_match}` when no
  fixture matches.

  `criteria[:prefer]` is accepted for surface compatibility but does not
  affect selection in the fake — the fixture order is used as the
  preference order.
  """
  @spec select(keyword()) :: {:ok, ModelRef.t()} | {:error, :no_match}
  def select(criteria) when is_list(criteria) do
    require_set = Keyword.get(criteria, :require, [])

    @fixtures
    |> Map.values()
    |> Enum.find(&matches_requirements?(&1, require_set))
    |> case do
      nil -> {:error, :no_match}
      ref -> {:ok, ref}
    end
  end

  defp matches_requirements?(%ModelRef{capabilities: caps}, requirements)
       when is_list(requirements) do
    Enum.all?(requirements, fn
      :tools -> get_in(caps, [:tools, :enabled]) == true
      :json_native -> Map.get(caps || %{}, :json_native) == true
      {key, expected} -> Map.get(caps || %{}, key) == expected
    end)
  end
end
