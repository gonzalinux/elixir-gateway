defmodule Mix.Tasks.ElixirGateway.DetectIp do
  @moduledoc """
  Detects the node IP address for clustering.

  Tries to detect the public IP first (via ipify.org), then falls back to local IP.
  Outputs the detected IP to stdout for use in shell scripts.

  ## Usage

      mix elixir_gateway.detect_ip

  ## Exit Codes

  - 0: Successfully detected IP
  - 1: Failed to detect IP
  """

  use Mix.Task

  @shortdoc "Detects node IP for clustering"

  @impl Mix.Task
  def run(_args) do
    # Suppress all application logs during IP detection
    Logger.configure(level: :emergency)

    # Start the application dependencies (needed for Req HTTP client)
    Application.ensure_all_started(:req)

    alias ElixirGateway.Cluster.IPDetection

    ip =
      case IPDetection.get_public_ip() do
        {:ok, ip} ->
          ip

        {:error, _reason} ->
          case IPDetection.get_local_ip() do
            {:ok, ip} ->
              ip

            {:error, _} ->
              ""
          end
      end

    if ip == "" do
      System.halt(1)
    end

    # Output only the IP to stdout, nothing else
    IO.write(ip)
  end
end
