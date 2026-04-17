defmodule ALLM.Adapter do
  @moduledoc "See spec §7.1."

  @callback generate(ALLM.Request.t(), keyword()) ::
              {:ok, ALLM.Response.t()} | {:error, term()}

  @callback prepare_request(ALLM.Request.t(), keyword()) ::
              {:ok, Req.Request.t()} | {:error, term()}

  @callback translate_options(keyword(), ALLM.Request.t()) :: keyword()

  @optional_callbacks prepare_request: 2, translate_options: 2
end
