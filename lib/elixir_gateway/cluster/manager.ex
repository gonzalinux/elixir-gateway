defmodule ElixirGateway.Cluster.Manager do
  @moduledoc """
  Manages native Erlang distribution setup, peer connections, and health heartbeats.

  Responsibilities:
  - Configure and start Erlang distribution with TLS encryption and PSK authentication
  - Connect to peer nodes
  - Monitor peer health status via net_kernel
  - Automatically reconnect to disconnected peers

  ## Peer Address Format

  Peer addresses must be specified in the format: `node_name@host:port`

  Examples:
  - `gateway-b@192.168.1.100:9100` - IP address
  - `gateway-cloud@gateway.example.com:9100` - Hostname
  - Multiple peers: `gateway-a@host1:9100,gateway-b@host2:9100`

  Note: The port in the peer address is informational and stored for reference,
  but the actual connection port is determined by the kernel configuration
  (inet_dist_listen_min/max).

  ## Asymmetric Configuration

  Supports setups where one node has a static IP (cloud) and another has
  a dynamic IP (home). The dynamic IP node should list the static IP node
  as a peer, while the static IP node can have an empty peers list.

  This creates a bidirectional connection where the home node reconnects
  automatically when its IP changes, without requiring the cloud node to
  track the changing IP address.

  ## TLS and PSK Authentication

  Uses native Erlang distribution with inet_tls for TLS encryption and
  PSK (Pre-Shared Key) authentication. Configuration is loaded from
  priv/ssl_dist.conf which references the ssl_psk:lookup/3 function.

  The shared secret is retrieved from the CLUSTER_SECRET environment variable.
  """
  alias ElixirGateway.Cluster.IPDetection

  use GenServer
  require Logger

  @default_heartbeat_interval 1_000
  @default_listen_port 9100

  defstruct [
    :config,
    :node_name,
    :peers,
    :heartbeat_interval,
    :peer_health
  ]

  ## Client API

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc """
  Returns the list of currently connected peer nodes.
  """
  def connected_peers do
    GenServer.call(__MODULE__, :get_connected_peers)
  end

  @doc """
  Returns the health status of all peers.
  """
  def peer_health do
    GenServer.call(__MODULE__, :get_peer_health)
  end

  @doc """
  Checks if clustering is healthy (at least one peer is connected and healthy).
  """
  def cluster_healthy? do
    GenServer.call(__MODULE__, :cluster_healthy)
  end

  ## Server Callbacks

  @impl true
  def init(config) do
    node_name = Keyword.fetch!(config, :node_name)
    peers = Keyword.fetch!(config, :peers)
    secret = Keyword.fetch!(config, :secret)
    listen_port = Keyword.get(config, :listen_port, @default_listen_port)
    heartbeat_interval = Keyword.get(config, :heartbeat_interval, @default_heartbeat_interval)

    # Configure and start Erlang distribution
    start_distribution(node_name, secret, listen_port)

    # Initialize peer health with all configured peers as disconnected
    initial_peer_health =
      Enum.reduce(peers, %{}, fn peer, acc ->
        Map.put(acc, peer, :disconnected)
      end)

    Logger.info(
      "Starting cluster manager for node: #{node_name} and peers: #{inspect(initial_peer_health)}"
    )

    state = %__MODULE__{
      config: config,
      node_name: node_name,
      peers: peers,
      heartbeat_interval: heartbeat_interval,
      peer_health: initial_peer_health
    }

    # Enable node monitoring to receive nodeup/nodedown messages
    :net_kernel.monitor_nodes(true, node_type: :all)

    # Connect to peers asynchronously
    send(self(), :connect_to_peers)

    Logger.info("Cluster manager started for node: #{node_name}")

    {:ok, state}
  end

  @impl true
  def handle_info(:connect_to_peers, state) do
    Enum.each(state.peers, fn peer ->
      connect_to_peer(peer)
    end)

    {:noreply, state}
  end

  # net_kernel sends these messages when nodes connect/disconnect
  @impl true
  def handle_info({:nodeup, node, _info}, state) do
    # Convert to internal peer_up format for consistency
    send(self(), {:peer_up, node, :up_detected})
    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, node, _info}, state) do
    # Convert to internal peer_down format for consistency
    send(self(), {:peer_down, node, :down_detected})
    # Schedule reconnection
    schedule_reconnect(node)
    {:noreply, state}
  end

  @impl true
  def handle_info({:peer_up, peer_node, extra}, state) do
    # Peer connected - update health state immediately
    peer_str = Atom.to_string(peer_node)

    # Find the peer in health map and mark as healthy
    # If not found (e.g., primary node with empty peers list), add it dynamically
    {found, updated_health} =
      Enum.reduce(state.peer_health, {false, state.peer_health}, fn {peer_key, _status}, {found_acc, acc} ->
        if String.contains?(peer_key, peer_str) do
          Logger.info("Peer connected: #{peer_key}  #{extra}")
          {true, Map.put(acc, peer_key, :healthy)}
        else
          {found_acc, acc}
        end
      end)

    # If peer not in configured list, add it dynamically (for primary nodes)
    final_health =
      if not found do
        Logger.info("Peer connected (dynamic): #{peer_str}  #{extra}")
        Map.put(updated_health, peer_str, :healthy)
      else
        updated_health
      end

    {:noreply, %{state | peer_health: final_health}}
  end

  @impl true
  def handle_info({:peer_down, peer_node, extra}, state) do
    # Peer disconnected - update health state immediately
    peer_str = Atom.to_string(peer_node)

    # Find the peer in health map and mark as disconnected (including dynamically added peers)
    {found, updated_health} =
      Enum.reduce(state.peer_health, {false, state.peer_health}, fn {peer_key, status}, {found_acc, acc} ->
        if String.contains?(peer_key, peer_str) and status == :healthy do
          Logger.warning("Peer disconnected: #{peer_key}  #{extra}")
          {true, Map.put(acc, peer_key, :disconnected)}
        else
          {found_acc, acc}
        end
      end)

    # If peer not in health map but we got nodedown (shouldn't happen but be defensive)
    final_health =
      if not found do
        Logger.warning("Peer disconnected (was not tracked): #{peer_str}  #{extra}")
        updated_health
      else
        updated_health
      end

    {:noreply, %{state | peer_health: final_health}}
  end

  @impl true
  def handle_info({:reconnect, peer_node}, state) do
    # Check if peer is in our configured peers list
    peer_str = Atom.to_string(peer_node)

    should_reconnect =
      Enum.any?(state.peers, fn peer ->
        String.contains?(peer, peer_str)
      end)

    if should_reconnect do
      case Node.connect(peer_node) do
        true ->
          Logger.info("Reconnected to #{peer_node}")
          {:noreply, state}

        false ->
          Logger.debug("Reconnection to #{peer_node} failed, will retry")
          schedule_reconnect(peer_node)
          {:noreply, state}

        :ignored ->
          Logger.debug("Node #{peer_node} already connected")
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:get_connected_peers, _from, state) do
    peers = Node.list(:connected)
    {:reply, peers, state}
  end

  @impl true
  def handle_call(:get_peer_health, _from, state) do
    {:reply, state.peer_health, state}
  end

  @impl true
  def handle_call(:cluster_healthy, _from, state) do
    # Cluster is healthy if at least one peer is healthy
    healthy = Enum.any?(state.peer_health, fn {_peer, status} -> status == :healthy end)
    {:reply, healthy, state}
  end

  ## Private Functions

  defp start_distribution(node_name, secret, listen_port) do
    # Validate secret
    validate_secret!(secret)

    # Check if node is already running in distributed mode
    # (started by VM with --name flag and TLS options)
    if Node.alive?() do
      current_node = Node.self()
      Logger.info(
        "Distributed node already running: #{current_node} on port #{listen_port} (TLS 1.2 PSK-DHE Enabled)"
      )

      {:ok, current_node}
    else
      # Not running in distributed mode - try to start it
      # This path is used when running without --name flag
      node_ip = get_node_ip()
      full_node_name = String.to_atom("#{node_name}@#{node_ip}")

      # Set SSL dist config file path
      ssl_conf_path = Path.join(:code.priv_dir(:elixirgateway), "ssl_dist.conf")
      System.put_env("SSL_DIST_OPTFILE", ssl_conf_path)

      # Set distribution protocol to inet_tls
      System.put_env("PROTO_DIST", "inet_tls")

      # Configure kernel inet_dist port range before starting node
      :application.set_env(:kernel, :inet_dist_listen_min, listen_port)
      :application.set_env(:kernel, :inet_dist_listen_max, listen_port)

      # Start node in distributed mode with longnames
      case Node.start(full_node_name, :longnames, 15000) do
        {:ok, _} ->
          Logger.info(
            "Started distributed node: #{full_node_name} on port #{listen_port} (TLS 1.2 PSK-DHE Enabled)"
          )

          {:ok, full_node_name}

        {:error, reason} ->
          Logger.error("Failed to start node: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp validate_secret!(secret) do
    case Base.decode16(secret, case: :mixed) do
      {:ok, bytes} when byte_size(bytes) >= 32 ->
        :ok

      {:ok, bytes} ->
        raise ArgumentError,
              "Cluster secret must be at least 32 bytes (64 hex chars), got #{byte_size(bytes)}"

      :error ->
        raise ArgumentError, "Cluster secret must be a valid hex string"
    end
  end

  defp connect_to_peer(peer_address) do
    # Parse peer address: "node_name@host:port"
    # With EPMD, the port is registered and auto-discovered
    case String.split(peer_address, ["@", ":"]) do
      [node_name, host, _port_str] ->
        # EPMD will look up the port automatically
        peer_node = String.to_atom("#{node_name}@#{host}")

        case Node.connect(peer_node) do
          true ->
            Logger.info("Connected to peer: #{peer_address}")
            :ok

          false ->
            Logger.warning("Failed to connect to peer #{peer_address}")
            {:error, :connection_failed}

          :ignored ->
            Logger.debug("Node #{peer_node} already connected")
            :ok
        end

      _ ->
        Logger.error("Invalid peer address format: #{peer_address} (expected node@host:port)")
        {:error, :invalid_format}
    end
  end

  defp schedule_reconnect(peer_node) do
    # Retry every 5 seconds
    Process.send_after(self(), {:reconnect, peer_node}, 5_000)
  end

  defp get_node_ip do
    # Try to get IP from config first
    config = Application.get_env(:elixirgateway, :cluster, [])
    configured_ip = Keyword.get(config, :node_ip)

    cond do
      # Use configured IP if provided and not empty
      is_binary(configured_ip) and configured_ip != "" ->
        configured_ip

      # Empty string is invalid
      configured_ip == "" ->
        raise ArgumentError, "NODE_IP cannot be empty. Please set a valid IP address."

      # Try auto-detection: public IP first, then local IP
      true ->
        with {:error, public_reason} <- IPDetection.get_public_ip(),
             _ =
               Logger.warning(
                 "Failed to detect public IP (#{inspect(public_reason)}), trying local IP"
               ),
             {:error, local_reason} <- IPDetection.get_local_ip() do
          Logger.error(
            "Failed to auto-detect IP address. Public IP: #{inspect(public_reason)}, Local IP: #{inspect(local_reason)}"
          )

          raise RuntimeError, """
          Could not detect node IP address for clustering.

          Please explicitly set NODE_IP in your environment:
            export NODE_IP="your.server.ip.address"

          For local testing on the same machine, use:
            export NODE_IP="127.0.0.1"

          For production, use your server's public IP address.
          """
        else
          {:ok, ip} -> ip
        end
    end
  end
end
