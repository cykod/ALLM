defmodule ALLM.Test.RaisingFinch do
  @moduledoc """
  A `:finch_module` whose `async_request/3` and `cancel_async_request/1`
  both raise. Internal test support — NOT part of the published Hex package.

  Keyless pre-flight gate tests for streaming HTTP adapters pass
  `finch_module: ALLM.Test.RaisingFinch`, so a gate moved after key
  resolution, or into the stream, fails loudly even in a shell that
  exports the provider's API key.
  """

  @doc false
  @spec async_request(term(), term(), keyword()) :: no_return()
  def async_request(_req, _name, _opts), do: raise("gate let the request reach Finch")

  @doc false
  @spec cancel_async_request(term()) :: no_return()
  def cancel_async_request(_ref), do: raise("gate let the request reach Finch")
end
