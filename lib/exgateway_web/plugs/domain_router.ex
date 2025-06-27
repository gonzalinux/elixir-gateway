defmodule ExgatewayWeb.Plugs.DomainRouter do
  @moduledoc """
  Plug that determines the target service based on the incoming domain.
  """
  
  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    host = get_host(conn)
    services = Application.get_env(:exgateway, :gateway)[:services] || %{}
    
    case Map.get(services, host) do
      nil ->
        Logger.warning("No service configured for host: #{host}")
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{error: "Service not found for host: #{host}"}))
        |> halt()
      
      target_url ->
        conn
        |> assign(:target_url, target_url)
        |> assign(:original_host, host)
    end
  end

  defp get_host(conn) do
    case get_req_header(conn, "host") do
      [host | _] -> 
        # Remove port if present
        host
        |> String.split(":")
        |> List.first()
      
      [] ->
      conn.host ||
        "default"
    end
  end
end