defmodule ElixirGateway.Cluster.IPDetection do
  @moduledoc """
  Utility module for detecting IP addresses.

  Provides methods to detect both public and local IP addresses.
  """

  require Logger

  @public_ip_service "https://api.ipify.org"

  @doc """
  Gets the public IP address of this server.

  Uses ipify.org to detect the public-facing IP address.

  Returns:
  - `{:ok, ip}` - Successfully detected IP
  - `{:error, reason}` - Failed to detect IP
  """
  def get_public_ip do
    case Req.get(@public_ip_service) do
      {:ok, %{status: 200, body: ip}} ->
        ip = String.trim(ip)
        Logger.debug("Detected public IP: #{ip}")
        {:ok, ip}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Failed to get public IP, status #{status}: #{body}")
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        Logger.error("Failed to get public IP: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Gets the local IP address of this server.

  Detects the first non-loopback IPv4 address from network interfaces.

  Returns:
  - `{:ok, ip}` - Successfully detected IP
  - `{:error, reason}` - Failed to detect IP
  """
  def get_local_ip do
    case detect_local_ip() do
      "127.0.0.1" ->
        {:error, "Only loopback interface found"}

      ip ->
        Logger.debug("Detected local IP: #{ip}")
        {:ok, ip}
    end
  end

  ## Private Functions

  defp detect_local_ip do
    # Get network interfaces and find first non-loopback IPv4 address
    case :inet.getifaddrs() do
      {:ok, interfaces} ->
        interfaces
        |> Enum.find_value(fn {_iface, opts} ->
          opts
          |> Keyword.get_values(:addr)
          |> Enum.find(fn
            # Skip loopback
            {127, 0, 0, 1} -> false
            # Skip IPv6
            {_, _, _, _, _, _, _, _} -> false
            # Accept IPv4
            {a, _b, _c, _d} when is_integer(a) -> true
            _ -> false
          end)
        end)
        |> case do
          {a, b, c, d} ->
            "#{a}.#{b}.#{c}.#{d}"

          _ ->
            Logger.warning("Could not detect local IP, using 127.0.0.1")
            "127.0.0.1"
        end

      {:error, _reason} ->
        Logger.warning("Could not get network interfaces, using 127.0.0.1")
        "127.0.0.1"
    end
  end
end
