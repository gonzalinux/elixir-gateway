defmodule ExgatewayWeb.GatewayController do
  @moduledoc """
  Controller that handles proxied requests.
  Note: Most of the work is done by plugs, this is mainly a fallback.
  """
  
  use ExgatewayWeb, :controller
  require Logger

  def proxy(conn, _params) do
    # If we reach this point, it means the request wasn't handled by the plugs
    # This could happen if there's an error in the plug pipeline
    Logger.warning("Request reached GatewayController.proxy - this should not normally happen")
    
    conn
    |> put_status(500)
    |> json(%{error: "Gateway configuration error"})
  end
end