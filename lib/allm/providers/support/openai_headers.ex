defmodule ALLM.Providers.Support.OpenAIHeaders do
  @moduledoc """
  Shared HTTP-header builder for OpenAI provider adapters.
  the documented contract.

  Layer B helper. Both the chat adapter (`ALLM.Providers.OpenAI`) and the
  image adapter (`ALLM.Providers.OpenAI.Images`) inject the same
  `Authorization` and (optional) `openai-organization` headers; the only
  difference is whether `content-type: application/json` is set explicitly
  (`json_headers/2`) or elided so `Req`'s `:form_multipart` step can stamp
  the multipart boundary itself (`multipart_headers/2`).

  Both functions honor `opts[:adapter_opts][:organization]` per the
  chat-adapter precedent at `lib/allm/providers/openai.ex:443-446`
  callers wishing to scope a request to an OpenAI org pass
  `adapter_opts: [organization: "org-..."]` in their `opts` keyword list.

  ## Examples

      iex> ALLM.Providers.Support.OpenAIHeaders.json_headers("sk-test", [])
      [{"authorization", "Bearer sk-test"}, {"content-type", "application/json"}]

      iex> ALLM.Providers.Support.OpenAIHeaders.multipart_headers("sk-test", [])
      [{"authorization", "Bearer sk-test"}]

      iex> opts = [adapter_opts: [organization: "org-abc"]]
      iex> ALLM.Providers.Support.OpenAIHeaders.json_headers("sk-test", opts)
      [
        {"openai-organization", "org-abc"},
        {"authorization", "Bearer sk-test"},
        {"content-type", "application/json"}
      ]

      iex> opts = [adapter_opts: [organization: "org-abc"]]
      iex> ALLM.Providers.Support.OpenAIHeaders.multipart_headers("sk-test", opts)
      [{"openai-organization", "org-abc"}, {"authorization", "Bearer sk-test"}]
  """

  @doc """
  Build headers for a JSON-bodied request. Returns
  `[{"authorization", "Bearer <api_key>"}, {"content-type", "application/json"},...]`
  optionally prefixed with `{"openai-organization", org}` when
  `opts[:adapter_opts][:organization]` is a binary.
  """
  @spec json_headers(api_key :: String.t(), opts :: keyword()) :: [{String.t(), String.t()}]
  def json_headers(api_key, opts) when is_binary(api_key) and is_list(opts) do
    base = [
      {"authorization", "Bearer " <> api_key},
      {"content-type", "application/json"}
    ]

    maybe_prefix_org(base, opts)
  end

  @doc """
  Build headers for a multipart/form-data request. Returns
  `[{"authorization", "Bearer <api_key>"}]` only — `content-type` is
  intentionally elided so `Req`'s `:form_multipart` step stamps it with
  the boundary string. Optionally prefixed with
  `{"openai-organization", org}` when set.
  """
  @spec multipart_headers(api_key :: String.t(), opts :: keyword()) :: [{String.t(), String.t()}]
  def multipart_headers(api_key, opts) when is_binary(api_key) and is_list(opts) do
    base = [{"authorization", "Bearer " <> api_key}]
    maybe_prefix_org(base, opts)
  end

  defp maybe_prefix_org(base, opts) do
    case opts |> Keyword.get(:adapter_opts, []) |> Keyword.get(:organization) do
      nil -> base
      org when is_binary(org) -> [{"openai-organization", org} | base]
    end
  end
end
