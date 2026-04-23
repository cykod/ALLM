defmodule ALLM.Keys.Dotenv do
  @moduledoc false

  # Minimal `.env` parser for ALLM.Keys level-5 resolution (spec §6.4).
  #
  # The supported subset is intentionally strict (Non-obvious decision #2):
  #
  #   * `KEY=VALUE`
  #   * `# comment` lines (skipped)
  #   * blank lines (skipped)
  #   * `export KEY=VALUE` (the leading `export ` is stripped)
  #   * surrounding double quotes on the value are stripped
  #     (single quotes are NOT stripped — documented limitation)
  #
  # No variable interpolation, no multi-line values, no escape sequences.
  # Malformed lines (no `=` sign) are silently skipped.
  #
  # `load/1` reads and parses a file, returning `%{}` on ENOENT; other file
  # errors (e.g. EACCES) propagate. Lookup uses `Store.dotenv_lookup/1`
  # which caches the load result in the `ALLM.Keys.Store` Agent (Decision
  # #10) — this module is pure beyond the single `File.read!/1` in
  # `load/1`.

  alias ALLM.Keys
  alias ALLM.Keys.Store

  @type entry :: {String.t(), String.t()}

  @doc """
  Read and parse the `.env` file at `path`.

  Returns a string-keyed map of every well-formed `KEY=VALUE` pair. Returns
  `%{}` when the file does not exist (ENOENT). Other file errors propagate
  via `File.read!/1`.
  """
  @spec load(Path.t()) :: %{String.t() => String.t()}
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} -> content |> parse() |> Map.new()
      {:error, :enoent} -> %{}
      {:error, reason} -> raise File.Error, reason: reason, action: "read file", path: path
    end
  end

  @doc """
  Parse `.env` file contents into an ordered list of `{key, value}` pairs.

  Pure — does not touch the filesystem. See the module docs for the
  supported subset.
  """
  @spec parse(String.t()) :: [entry()]
  def parse(content) when is_binary(content) do
    content
    |> String.split(["\r\n", "\n"])
    |> Enum.flat_map(&parse_line/1)
  end

  @doc """
  Look up an API key for `provider` in the cached `.env` load result.

  Translates the provider atom to its env-var name via
  `ALLM.Keys.env_var_for/1`, then delegates to
  `ALLM.Keys.Store.dotenv_lookup/1` which performs the one-time lazy load.

  Returns `nil` when `config :allm, load_dotenv: true` is not set or when
  the env var is not present in the file.
  """
  @spec lookup(atom()) :: String.t() | nil
  def lookup(provider) when is_atom(provider) do
    provider
    |> Keys.env_var_for()
    |> Store.dotenv_lookup()
  end

  # ---------------------------------------------------------------------------
  # Private — line parser
  # ---------------------------------------------------------------------------

  @spec parse_line(String.t()) :: [entry()]
  defp parse_line(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" -> []
      String.starts_with?(trimmed, "#") -> []
      true -> parse_assignment(trimmed)
    end
  end

  @spec parse_assignment(String.t()) :: [entry()]
  defp parse_assignment(line) do
    line = strip_export(line)

    case String.split(line, "=", parts: 2) do
      [key, value] ->
        key = String.trim(key)

        if valid_key?(key) do
          [{key, unquote_value(value)}]
        else
          []
        end

      _ ->
        []
    end
  end

  @spec strip_export(String.t()) :: String.t()
  defp strip_export("export " <> rest), do: String.trim_leading(rest)
  defp strip_export(line), do: line

  @spec valid_key?(String.t()) :: boolean()
  defp valid_key?(""), do: false
  defp valid_key?(key), do: Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, key)

  # Strip ONE pair of surrounding double quotes if present. Single quotes
  # are NOT stripped (documented limitation).
  @spec unquote_value(String.t()) :: String.t()
  defp unquote_value(value) do
    trimmed = String.trim(value)

    case trimmed do
      <<?">> <> _ = quoted ->
        if String.ends_with?(quoted, "\"") and byte_size(quoted) >= 2 do
          quoted |> String.slice(1..-2//1)
        else
          trimmed
        end

      other ->
        other
    end
  end
end
