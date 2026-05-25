defmodule ALLM.JsonSchema do
  @moduledoc """
  Shared helpers for JSON-Schema maps consumed by adapters.

  Adapters expect string-keyed JSON Schema with string values for `type`,
  `format`, etc. Atom keys / atom values produce non-deterministic wire
  shapes across providers; `normalize/1` enforces a single canonical form
  for both `ALLM.Tool` `:schema` AND `ALLM.json_schema/3` `:schema`.

  The normalization is idempotent: a map whose keys are all binaries AND
  contains no atom values passes through verbatim (fast path); otherwise
  the tree is walked and both keys and atom values are stringified.
  """

  @doc """
  Normalize a JSON-Schema map's atom keys AND atom values to strings.

  Returns the input verbatim (fast path) when keys are already binaries
  AND no atom values are present. Otherwise walks the tree recursively,
  rewriting atom keys via `Atom.to_string/1` and atom values (other than
  `nil`, `true`, `false`) the same way.

  Non-map inputs pass through unchanged — the helper is defensive against
  hydration paths that may produce `nil` or other values where a map is
  expected.

  ## Examples

      iex> ALLM.JsonSchema.normalize(%{type: :object, properties: %{name: %{type: :string}}})
      %{"properties" => %{"name" => %{"type" => "string"}}, "type" => "object"}

      iex> ALLM.JsonSchema.normalize(%{"type" => "object"})
      %{"type" => "object"}
  """
  @spec normalize(term()) :: term()
  def normalize(schema) when is_map(schema) do
    if all_string_keys?(schema) and not contains_atom_value?(schema) do
      schema
    else
      deep_stringify(schema)
    end
  end

  def normalize(other), do: other

  defp all_string_keys?(%{} = m), do: Enum.all?(Map.keys(m), &is_binary/1)

  # Walk the tree shallowly looking for any atom value (other than nil /
  # true / false). Triggers a deep walk when found; otherwise the input
  # passes through verbatim.
  defp contains_atom_value?(%{} = m) do
    Enum.any?(m, fn {_k, v} ->
      cond do
        is_atom(v) and v not in [nil, true, false] -> true
        is_map(v) -> contains_atom_value?(v)
        is_list(v) -> Enum.any?(v, &(is_map(&1) and contains_atom_value?(&1)))
        true -> false
      end
    end)
  end

  defp deep_stringify(%{} = m) do
    m
    |> Enum.map(fn {k, v} -> {to_string_key(k), deep_stringify(v)} end)
    |> Map.new()
  end

  defp deep_stringify(list) when is_list(list), do: Enum.map(list, &deep_stringify/1)
  defp deep_stringify(v) when is_atom(v) and v not in [nil, true, false], do: Atom.to_string(v)
  defp deep_stringify(other), do: other

  defp to_string_key(k) when is_binary(k), do: k
  defp to_string_key(k) when is_atom(k), do: Atom.to_string(k)
  defp to_string_key(k), do: inspect(k)
end
