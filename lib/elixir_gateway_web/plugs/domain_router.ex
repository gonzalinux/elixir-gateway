defmodule ElixirGatewayWeb.Plugs.DomainRouter do
  @moduledoc """
  Plug that determines the target service based on the incoming domain.
  """

  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    host = get_host(conn)
    services = Application.get_env(:elixirgateway, :gateway)[:services] || %{}

    case Map.get(services, host) do
      nil ->
        # Try default_any fallback for unknown domains (not for missing host which uses "default")
        if host != "default" do
          case Map.get(services, "default_any") do
            nil ->
              Logger.warning(
                "No service configured for host: #{host}, and no default_any fallback"
              )

              conn
              |> put_resp_content_type("application/json")
              |> send_resp(404, Jason.encode!(%{error: "Service not found for host: #{host}"}))
              |> halt()

            target_url ->
              Logger.info("Routing unknown host #{host} to default_any service")

              conn
              |> assign(:target_url, target_url)
              |> assign(:original_host, host)
          end
        else
          Logger.warning("No service configured for host: #{host}")

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(404, Jason.encode!(%{error: "Service not found for host: #{host}"}))
          |> halt()
        end

      target_url ->
        conn
        |> assign(:target_url, target_url)
        |> assign(:original_host, host)
    end
  end

  defp get_host(conn) do
    if conn.host do
      conn.host
    else
      case get_req_header(conn, "host") do
        [host | _] ->
          # Remove port if present
          host
          |> String.split(":")
          |> List.first()

        [] ->
          "default"
      end
    end
  end
end
