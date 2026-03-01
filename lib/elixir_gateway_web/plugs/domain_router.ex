defmodule ElixirGatewayWeb.Plugs.DomainRouter do
  @moduledoc """
  Plug that determines the target service based on the incoming domain.
  """

  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    host = get_host(conn)

    case resolve_service(host) do
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

  @doc """
  Resolves a host to its target service URL using local configuration.

  Returns the target URL string, or nil if no service is configured for the host.
  Checks exact match, wildcard patterns, and the default_any fallback in order.
  """
  def resolve_service(host) do
    services = Application.get_env(:elixirgateway, :gateway)[:services] || %{}

    Map.get(services, host) ||
      find_wildcard_match(services, host) ||
      if(host != "default", do: Map.get(services, "default_any"))
  end

  defp find_wildcard_match(services, host) do
    Enum.find_value(services, fn
      {"*" <> suffix, target_url} ->
        if String.ends_with?(host, suffix) or host == suffix, do: target_url

      _ ->
        nil
    end)
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
