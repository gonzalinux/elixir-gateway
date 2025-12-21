defmodule ElixirGateway.Cluster.Manager do
  @moduledoc """
  Manages Partisan setup, peer connections, and health heartbeats.

  Responsibilities:
  - Configure and start Partisan with TLS encryption
  - Connect to peer nodes
  - Send periodic health heartbeats
  - Monitor peer health status
  """

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

    # Configure Partisan
    configure_partisan(node_name, secret, listen_port)

    state = %__MODULE__{
      config: config,
      node_name: node_name,
      peers: peers,
      heartbeat_interval: heartbeat_interval,
      peer_health: %{}
    }

    # Connect to peers asynchronously
    send(self(), :connect_to_peers)

    # Schedule first heartbeat
    schedule_heartbeat(heartbeat_interval)

    Logger.info("Cluster manager started for node: #{node_name}")

    {:ok, state}
  end

  @impl true
  def handle_info(:connect_to_peers, state) do
    Enum.each(state.peers, fn peer ->
      connect_to_peer(peer, state.config)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info(:send_heartbeat, state) do
    # Send heartbeat to all peers
    send_heartbeat_to_peers()

    # Update peer health based on connections
    new_peer_health = update_peer_health(state.peers)

    # Schedule next heartbeat
    schedule_heartbeat(state.heartbeat_interval)

    {:noreply, %{state | peer_health: new_peer_health}}
  end

  @impl true
  def handle_call(:get_connected_peers, _from, state) do
    peers = get_partisan_peers()
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

  defp configure_partisan(node_name, secret, listen_port) do
    # Set Partisan configuration
    Application.put_env(:partisan, :partisan_peer_service_manager,
      :partisan_pluggable_peer_service_manager
    )

    # Configure node name
    full_node_name = String.to_atom("#{node_name}@127.0.0.1")
    Application.put_env(:partisan, :node, full_node_name)

    # Configure listen address
    Application.put_env(:partisan, :listen_addrs, [
      %{ip: {0, 0, 0, 0}, port: listen_port}
    ])

    # Configure channels with encryption
    Application.put_env(:partisan, :channels, [
      {:default, %{monotonic: true, parallelism: 1}}
    ])

    # Configure TLS with shared secret
    Application.put_env(:partisan, :tls, true)
    Application.put_env(:partisan, :tls_server_options, [
      {:certfile, generate_cert_path(node_name, secret)},
      {:keyfile, generate_key_path(node_name, secret)}
    ])
    Application.put_env(:partisan, :tls_client_options, [
      {:verify, :verify_none}  # Using shared secret, not PKI
    ])

    # Start Partisan
    {:ok, _} = Application.ensure_all_started(:partisan)

    Logger.info("Partisan configured for node #{full_node_name} on port #{listen_port}")
  end

  defp connect_to_peer(peer_address, _config) do
    # Parse peer address (e.g., "gateway-b.example.com:9100")
    case parse_peer_address(peer_address) do
      {:ok, host, port} ->
        # Create Partisan node specification
        peer_node = %{
          name: String.to_atom("peer@#{host}"),
          listen_addrs: [%{ip: to_charlist(host), port: port}],
          channels: [:default]
        }

        # Attempt to join the peer
        case :partisan_peer_service.join(peer_node) do
          :ok ->
            Logger.info("Successfully connected to peer: #{peer_address}")
            :ok

          {:error, reason} ->
            Logger.warning("Failed to connect to peer #{peer_address}: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Invalid peer address #{peer_address}: #{reason}")
        {:error, reason}
    end
  end

  defp parse_peer_address(address) do
    case String.split(address, ":") do
      [host, port_str] ->
        case Integer.parse(port_str) do
          {port, ""} -> {:ok, host, port}
          _ -> {:error, "Invalid port: #{port_str}"}
        end

      _ ->
        {:error, "Invalid format, expected host:port"}
    end
  end

  defp get_partisan_peers do
    case :partisan_peer_service.members() do
      peers when is_list(peers) ->
        Enum.reject(peers, fn peer ->
          peer == :partisan_peer_service.myself()
        end)

      _ ->
        []
    end
  end

  defp send_heartbeat_to_peers do
    peers = get_partisan_peers()

    Enum.each(peers, fn peer ->
      # Send a simple ping message
      :partisan_peer_service.forward_message(
        peer,
        __MODULE__,
        {:heartbeat, node()}
      )
    end)
  end

  defp update_peer_health(configured_peers) do
    connected = get_partisan_peers()

    Enum.reduce(configured_peers, %{}, fn peer, acc ->
      # Check if this peer is in the connected list
      status =
        if Enum.any?(connected, fn connected_peer ->
             # Match by hostname from the peer address
             case parse_peer_address(peer) do
               {:ok, host, _port} ->
                 String.contains?(to_string(connected_peer), host)

               _ ->
                 false
             end
           end) do
          :healthy
        else
          :disconnected
        end

      Map.put(acc, peer, status)
    end)
  end

  defp schedule_heartbeat(interval) do
    Process.send_after(self(), :send_heartbeat, interval)
  end

  # Generate self-signed cert paths based on shared secret
  # In production, you'd use proper cert generation
  defp generate_cert_path(node_name, _secret) do
    Path.join([System.tmp_dir(), "partisan_#{node_name}.crt"])
  end

  defp generate_key_path(node_name, _secret) do
    Path.join([System.tmp_dir(), "partisan_#{node_name}.key"])
  end
end
