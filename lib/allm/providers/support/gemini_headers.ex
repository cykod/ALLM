defmodule ALLM.Providers.Support.GeminiHeaders do
  @moduledoc """
  Shared HTTP-header builder for Gemini provider adapters. See spec
   (bundled adapters) and the design's the documented contract.

  Layer B helper. Both the chat adapter (`ALLM.Providers.Gemini`) and the
  image adapter (`ALLM.Providers.Gemini.Images`,) inject the
  same `x-goog-api-key` and `content-type: application/json` headers.

  Per the design's the documented contract: the API key flows on the
  `x-goog-api-key` request header, not the `?key=...` query parameter.
  Both forms are documented and equivalent server-side; the header form
  keeps the API key out of HTTP access logs and metrics.

  Per the documented contract: the same header is also the streaming-endpoint
  authentication; `streamGenerateContent?alt=sse` accepts identical
  headers — only the URL's `?alt=sse` query param differs.

  ## Examples

      iex> ALLM.Providers.Support.GeminiHeaders.headers("AIza-test")
      [{"x-goog-api-key", "AIza-test"}, {"content-type", "application/json"}]
  """

  @doc """
  Build headers for a JSON-bodied Gemini request. Returns
  `[{"x-goog-api-key", api_key}, {"content-type", "application/json"}]`.
  """
  @spec headers(api_key :: String.t()) :: [{String.t(), String.t()}]
  def headers(api_key) when is_binary(api_key) do
    [
      {"x-goog-api-key", api_key},
      {"content-type", "application/json"}
    ]
  end
end
