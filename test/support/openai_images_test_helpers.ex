defmodule ALLM.Providers.OpenAI.ImagesTestHelpers do
  @moduledoc """
  Shared helpers for `ALLM.Providers.OpenAI.Images` test files.

  Extracted in the Phase 15.4 fix step to amortize the helper duplication
  across `images_test.exs`, `images_multipart_test.exs`, and the upcoming
  Phase 15.5 `images_live_test.exs` (15.4 retro Finding 3).

  Per `test/support/` convention, this module is only compiled in `:test`
  (gated via `elixirc_paths` in `mix.exs`).

  Helpers exposed:

    * `merge_adapter_opts/2` — merge an `adapter_opts:` keyword into
      `opts[:adapter_opts]`, preferring values from the right-hand side.
    * `respond_json/3` — `Plug.Conn` response with JSON content-type.
    * `respond_with/4` — `Plug.Conn` response with custom response headers
      AND JSON content-type.
    * `drop_comment/1` — strip the `_comment` key from a fixture map
      (delegates to `ALLM.Providers.OpenAITestFixtures.drop_comment/1`).
    * `load_fixture/2` — `Path.join(dir, name) |> File.read!() |> Jason.decode!()`.
    * `recorded/2` / `synthesized/2` — convenience wrappers.

  The per-file `call/3` and request-building helpers (e.g. `tiny_png_bytes/0`,
  `base_image/0`, `edit_request/3`) remain in the test file that uses them
  — they encode test-class-specific defaults that should not bleed across
  files.
  """

  alias Plug.Conn

  @spec merge_adapter_opts(keyword(), keyword()) :: keyword()
  def merge_adapter_opts(opts, extra) do
    opts
    |> Keyword.get(:adapter_opts, [])
    |> Keyword.merge(extra)
  end

  @spec respond_json(Conn.t(), non_neg_integer(), map() | list()) :: Conn.t()
  def respond_json(conn, status, body) do
    conn
    |> Conn.put_resp_content_type("application/json")
    |> Conn.resp(status, Jason.encode!(body))
  end

  @spec respond_with(Conn.t(), non_neg_integer(), map() | list(), [{String.t(), String.t()}]) ::
          Conn.t()
  def respond_with(conn, status, body, headers) when is_list(headers) do
    headers
    |> Enum.reduce(conn, fn {k, v}, acc -> Conn.put_resp_header(acc, k, v) end)
    |> Conn.put_resp_content_type("application/json")
    |> Conn.resp(status, Jason.encode!(body))
  end

  # Consolidated in the Phase 20.4 fix step: this reached a third
  # implementation on `ALLM.Providers.OpenAITestFixtures` and
  # `AGENT_IMPLEMENTATION_SPEC.md:68` makes TWO the promotion trigger. The
  # delegation keeps the `import ..., only: [drop_comment: 1]` call sites in
  # the three image test files working unchanged.
  # (`ALLM.Providers.GeminiTestFixtures` keeps its own private two-clause
  # variant — different module family, no import surface.)
  defdelegate drop_comment(map), to: ALLM.Providers.OpenAITestFixtures

  @spec load_fixture(Path.t(), String.t()) :: term()
  def load_fixture(dir, name) do
    Path.join([dir, name]) |> File.read!() |> Jason.decode!()
  end

  @spec recorded(Path.t(), String.t()) :: term()
  def recorded(dir, name), do: load_fixture(dir, name)

  @spec synthesized(Path.t(), String.t()) :: term()
  def synthesized(dir, name), do: load_fixture(dir, name)
end
