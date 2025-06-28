defmodule ElixirGatewayWeb.Plugs.WebSocketUpgradePlug do
  @moduledoc """
  Plug that detects WebSocket upgrade requests and upgrades them to WebSocket connections.
  Uses Bandit's built-in WebSocket support.
  """

  import Plug.Conn
  require Logger

  @behaviour Plug

  @impl Plug
  def init(_opts), do: []

  @impl Plug
  def call(%Plug.Conn{} = conn, _opts) do
    if websocket_upgrade_request?(conn) do
      Logger.debug("WebSocket upgrade detected for: #{conn.request_path}")
      handle_websocket_upgrade(conn)
    else
      conn
    end
  end

  defp websocket_upgrade_request?(conn) do
    connection_header = get_req_header(conn, "connection") |> List.first("")
    upgrade_header = get_req_header(conn, "upgrade") |> List.first("")
    
    Logger.debug("WebSocket check - Path: #{conn.request_path}, Connection: '#{connection_header}', Upgrade: '#{upgrade_header}'")
    
    String.downcase(connection_header) |> String.contains?("upgrade") and
    String.downcase(upgrade_header) == "websocket"
  end

  defp handle_websocket_upgrade(conn) do
    host = conn.host
    services = Application.get_env(:elixirgateway, :gateway)[:services] || %{}
    
    case Map.get(services, host) do
      nil ->
        Logger.warning("No service configured for WebSocket host: #{host}")
        conn
        |> put_status(404)
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "Service not found")
        |> halt()
      
      target_url ->
        Logger.info("WebSocket upgrade request for host: #{host}")
        
        # Parse target URL to get target host and port
        target_uri = URI.parse(target_url)
        target_host_port = "#{target_uri.host}:#{target_uri.port}"
        
        # Get path and rewrite query string to replace proxy URLs with target URLs
        path = conn.request_path
        query_string = "?" <> conn.query_string
        
        # Build target WebSocket URL
        ws_target_url = String.replace(target_url, ~r/^https?/, fn
          "https" -> "wss"
          "http" -> "ws"
        end) <> path <> query_string
        
        # Extract and transform headers to forward
        headers = extract_and_transform_headers(conn, target_uri, target_host_port)
        
        Logger.info("Final WebSocket target URL: #{ws_target_url}")
        Logger.info("Transformed headers: #{inspect(headers)}")
        
        # Upgrade to WebSocket using our custom handler
        state = %{
          target_url: ws_target_url,
          headers: headers,
          host: host,
          target_host: target_host_port,
          path: path <> query_string
        }
        
        conn
        |> WebSockAdapter.upgrade(ElixirGatewayWeb.GunWebSocketHandler, state, [])
        |> halt()
    end
  end

  defp extract_and_transform_headers(conn, target_uri, target_host_port) do
    # Headers to forward (excluding WebSocket headers that Gun will handle automatically)
    headers_to_forward = [
      "authorization",
      "user-agent", 
      "sec-websocket-protocol",
      "accept",
      "accept-encoding",
      "accept-language",
      "x-forwarded-for",
      "x-real-ip"
    ]
    
    base_headers = headers_to_forward
    |> Enum.reduce([], fn header_name, acc ->
      case get_req_header(conn, header_name) do
        [] -> acc
        [value | _] -> [{header_name, value} | acc]
      end
    end)
    
    # Transform key headers for target service
    # Keep the original origin and host to maintain session validity
    original_origin = get_req_header(conn, "origin") |> List.first()
    original_host = "#{conn.host}:#{conn.port}"
    
    transformed_headers = [
      # Keep original origin for session validation (don't change it!)
      {"origin", original_origin || "http://#{original_host}"},
      # Set host header to target (this is what the backend service expects to see in the Host header)
      {"host", target_host_port},
      # Transform referer if present to point to original proxy
      {"referer", transform_referer(get_req_header(conn, "referer"), conn.host, conn.port)},
      # Keep original cookies for session validation
      {"cookie", transform_cookies(get_req_header(conn, "cookie"), target_uri)}
    ]
    |> Enum.filter(fn {_key, value} -> value != nil and value != "" end)
    
    (base_headers ++ transformed_headers)
    |> Enum.reverse()
  end

  defp transform_referer([], _proxy_host, _proxy_port), do: nil
  defp transform_referer([referer | _], proxy_host, proxy_port) do
    # Keep the original referer to maintain session context
    if String.contains?(referer, "#{proxy_host}:#{proxy_port}") do
      referer
    else
      referer
    end
  end

  defp transform_cookies([], _target_uri), do: nil
  defp transform_cookies([cookie_header | _], _target_uri) do
    # For now, pass cookies as-is since they're session cookies
    # In a production setup, you might need to rewrite cookie domains
    Logger.debug("Original cookies: #{cookie_header}")
    cookie_header
  end
end