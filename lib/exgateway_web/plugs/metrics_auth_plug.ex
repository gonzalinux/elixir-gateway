defmodule ElixirGatewayWeb.Plugs.MetricsAuthPlug do
  @moduledoc """
  Plug to restrict metrics endpoint to private networks only.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    remote_ip = conn.remote_ip
    IO.inspect(remote_ip, label: "Metrics endpoint access from IP")
    
    case is_private_network?(remote_ip) do
      true ->
        conn

      false ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(403, "Forbidden: Metrics endpoint restricted to private networks. Your IP: #{:inet.ntoa(remote_ip)}")
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
