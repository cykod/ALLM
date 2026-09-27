defmodule ALLM.Test.RaisingWebSocket do
  @moduledoc """
  A `:ws_module` whose `connect/3` raises. Internal test support — NOT part
  of the published Hex package.

  Keyless pre-flight gate tests for WebSocket stream adapters pass
  `ws_module: ALLM.Test.RaisingWebSocket`, so a gate moved after key
  resolution, or into the stream, fails loudly even in a shell that exports
  the provider's API key. The sibling of `ALLM.Test.RaisingFinch`.
  """

  @doc false
  @spec connect(term(), term(), keyword()) :: no_return()
  def connect(_url, _headers, _opts), do: raise("gate let the request reach the WebSocket")
end
