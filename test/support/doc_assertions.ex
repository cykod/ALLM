defmodule ALLM.Test.DocAssertions do
  @moduledoc """
  Shared helpers for asserting `@moduledoc` / `@doc` presence on behaviour
  modules.

  `Code.fetch_docs/1` returns a 7-element tuple
  `{:docs_v1, _anno, :elixir, _format, module_doc, _metadata, docs}` where
  `module_doc` and each per-function doc entry can be one of:

    * `:none` — no docstring ever attached
    * `:hidden` — `@doc false`
    * a plain `String.t()` — compiled with the default `:elixir` format
    * a locale-keyed map `%{optional(String.t()) => String.t()}` — the
      canonical docs format

  Behaviour-contract tests only need a *shape* assertion: is a docstring
  actually present? `doc_present?/1` returns `true` for non-empty strings and
  non-empty locale maps, `false` otherwise. Content assertions (substring
  matching, reason-atom listing) belong in doctests, not contract tests —
  per Non-obvious Decision #9 in `steering/PHASE_3_DESIGN.md`.

  Test-only infrastructure: compiled only under `Mix.env() == :test` via
  `elixirc_paths/1` in `mix.exs`.
  """

  @typedoc """
  The legal shapes a docstring slot in `Code.fetch_docs/1` output can take.
  """
  @type doc_entry ::
          :none
          | :hidden
          | String.t()
          | %{optional(String.t()) => String.t()}

  @doc """
  Return `true` when the docstring slot is a non-empty string or a non-empty
  locale map.

  ## Examples

      iex> ALLM.Test.DocAssertions.doc_present?(:none)
      false

      iex> ALLM.Test.DocAssertions.doc_present?(:hidden)
      false

      iex> ALLM.Test.DocAssertions.doc_present?("")
      false

      iex> ALLM.Test.DocAssertions.doc_present?("hello")
      true

      iex> ALLM.Test.DocAssertions.doc_present?(%{})
      false

      iex> ALLM.Test.DocAssertions.doc_present?(%{"en" => "hello"})
      true
  """
  @spec doc_present?(doc_entry()) :: boolean()
  def doc_present?(:none), do: false
  def doc_present?(:hidden), do: false
  def doc_present?(""), do: false
  def doc_present?(doc) when is_binary(doc), do: true
  def doc_present?(doc) when is_map(doc) and map_size(doc) == 0, do: false

  def doc_present?(doc) when is_map(doc) do
    Enum.any?(doc, fn
      {_locale, value} when is_binary(value) and value != "" -> true
      _ -> false
    end)
  end

  def doc_present?(_), do: false

  @doc """
  Return the module-doc slot from `Code.fetch_docs/1` output, or raise
  `ArgumentError` when the module has no docs chunk.
  """
  @spec module_doc(module()) :: doc_entry()
  def module_doc(module) when is_atom(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _anno, :elixir, _format, module_doc, _metadata, _docs} ->
        module_doc

      {:error, reason} ->
        raise ArgumentError,
              "Code.fetch_docs/1 failed for #{inspect(module)}: #{inspect(reason)}"
    end
  end

  @doc """
  Return the list of `@callback` doc entries for a module as
  `[{{name, arity}, doc_entry()}, ...]`.
  """
  @spec callback_docs(module()) :: [{{atom(), arity()}, doc_entry()}]
  def callback_docs(module) when is_atom(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _anno, :elixir, _format, _module_doc, _metadata, docs} ->
        for {{:callback, name, arity}, _anno, _signature, doc, _metadata} <- docs,
            do: {{name, arity}, doc}

      {:error, reason} ->
        raise ArgumentError,
              "Code.fetch_docs/1 failed for #{inspect(module)}: #{inspect(reason)}"
    end
  end
end
