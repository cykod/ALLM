defmodule ALLM.StreamAdapter do
  @moduledoc "See spec §7.2."

  @callback stream(ALLM.Request.t(), keyword()) ::
              {:ok, Enumerable.t()} | {:error, term()}
end
