defmodule ElixirGatewayWeb.Plugs.MetricsAuthPlug do
  @moduledoc """
  Plug to restrict metrics endpoint access.

  Supports two authentication methods (in order of priority):
  1. Bearer token authentication (if METRICS_AUTH_TOKEN env var is set)
  2. Private network IP validation (fallback)
  """

  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    # Check if token authentication is configured
    case Application.get_env(:elixirgateway, :metrics_auth_token) do
      nil ->
        # No token configured, use IP-based authentication
        validate_private_network(conn)

      token when is_binary(token) ->
        # Token configured, use token-based authentication
        validate_token(conn, token)
    end
  end

  # Validate Bearer token from Authorization header
  defp validate_token(conn, expected_token) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token == expected_token ->
        conn

      ["Bearer " <> _invalid_token] ->
        Logger.warning("Metrics access denied: Invalid token provided")

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(401, "Unauthorized: Invalid authentication token")
        |> halt()

      _other ->
        Logger.warning("Metrics access denied: No valid Bearer token provided")

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(
          401,
          "Unauthorized: Metrics endpoint requires authentication. Use: Authorization: Bearer <token>"
        )
        |> halt()
    end
  end

  # Validate IP is from private network
  defp validate_private_network(conn) do
    remote_ip = conn.remote_ip

    case is_private_network?(remote_ip) do
      true ->
        conn

      false ->
        ip_string =
          case :inet.ntoa(remote_ip) do
            {:error, _} -> inspect(remote_ip)
            ip_str -> to_string(ip_str)
          end

        Logger.warning("Metrics access denied: IP #{ip_string} not in private network")

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(
          403,
          "Forbidden: Metrics endpoint restricted to private networks. Your IP: #{ip_string}"
        )
        |> halt()
    end
  end

  # Check if IP is in private network ranges
  defp is_private_network?(ip) do
    case ip do
      # IPv4 private ranges
      # 10.0.0.0/8
      {10, _, _, _} -> true
      # 172.16.0.0/12
      {172, b, _, _} when b >= 16 and b <= 31 -> true
      # 192.168.0.0/16
      {192, 168, _, _} -> true
      # Localhost and loopback
      {127, _, _, _} -> true
      # Link-local addresses (169.254.0.0/16)
      {169, 254, _, _} -> true
      # IPv6 private ranges
      # ::1 (localhost)
      {0, 0, 0, 0, 0, 0, 0, 1} -> true
      # fc00::/7 (unique local)
      {0xFC00, _, _, _, _, _, _, _} -> true
      # fd00::/8 (unique local)
      {0xFD00, _, _, _, _, _, _, _} -> true
      # IPv6 link-local (fe80::/10)
      {0xFE80, _, _, _, _, _, _, _} -> true
      # Docker default bridge network (172.17.0.0/16)
      {172, 17, _, _} -> true
      _ -> false
    end
  end
end
