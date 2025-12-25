defmodule ElixirGateway.Cluster.Manager do
  @moduledoc """
  Manages Partisan setup, peer connections, and health heartbeats.

  Responsibilities:
  - Configure and start Partisan with TLS encryption
  - Connect to peer nodes
  - Send periodic health heartbeats
  - Monitor peer health status
  - Automatically reconnect to disconnected peers

  ## Peer Address Format

  Peer addresses must be specified in the format: `node_name@host:port`

  Examples:
  - `gateway-b@192.168.1.100:9100` - IP address
  - `gateway-cloud@gateway.example.com:9100` - Hostname
  - Multiple peers: `gateway-a@host1:9100,gateway-b@host2:9100`

  ## Channel Configuration

  Uses two channels (minimum required by Partisan):
  - `undefined`: Required by Partisan internals (hardcoded dependency in v5.0.3)
  - `default`: Used for application RPC calls with monotonic ordering

  We explicitly specify `channel: :default` in RPC calls to use ordered delivery
  for certificate synchronization. The `undefined` channel cannot be removed
  due to Partisan's internal implementation requirements.

  ## Asymmetric Configuration

  Supports setups where one node has a static IP (cloud) and another has
  a dynamic IP (home). The dynamic IP node should list the static IP node
  as a peer, while the static IP node can have an empty peers list.

  This creates a bidirectional connection where the home node reconnects
  automatically when its IP changes, without requiring the cloud node to
  track the changing IP address.
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

    # Configure Partisan
    configure_partisan(node_name, secret, listen_port)

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

    # Connect to peers asynchronously
    send(self(), :connect_to_peers)

    # Start peer discovery timer to register callbacks for incoming connections
    schedule_peer_discovery()

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
  def handle_info({:peer_up, peer_node, extra}, state) do
    # Peer connected - update health state immediately
    peer_str = Atom.to_string(peer_node)

    # Find the peer in health map and mark as healthy
    updated_health =
      Enum.reduce(state.peer_health, state.peer_health, fn {peer_key, _status}, acc ->
        if String.contains?(peer_key, peer_str) do
          Logger.info("Peer connected: #{peer_key}  #{extra}")
          Map.put(acc, peer_key, :healthy)
        else
          acc
        end
      end)

    {:noreply, %{state | peer_health: updated_health}}
  end

  @impl true
  def handle_info({:peer_down, peer_node, extra}, state) do
    # Peer disconnected - update health state immediately
    peer_str = Atom.to_string(peer_node)

    # Find the peer in health map and mark as disconnected
    updated_health =
      Enum.reduce(state.peer_health, state.peer_health, fn {peer_key, status}, acc ->
        if String.contains?(peer_key, peer_str) and status == :healthy do
          Logger.warning("Peer disconnected: #{peer_key}  #{extra}")
          Map.put(acc, peer_key, :disconnected)
        else
          acc
        end
      end)

    {:noreply, %{state | peer_health: updated_health}}
  end

  @impl true
  def handle_info(:discover_peers, state) do
    # Check for new peers that connected to us and register callbacks
    connected = get_partisan_peers()

    new_state =
      Enum.reduce(connected, state, fn peer_node, acc_state ->
        peer_str = Atom.to_string(peer_node)

        # Check if we already have this peer in our health map

        already_tracked =
          Enum.any?(acc_state.peer_health, fn {peer_key, _} ->
            String.contains?(peer_key, peer_str)
          end)

        if already_tracked do
          acc_state
        else
          # New peer connected to us - add to health and register callbacks
          Logger.info("Discovered new peer: #{peer_str}")
          register_peer_callbacks(peer_node)

          # Update health map to track this peer
          updated_health = Map.put(acc_state.peer_health, peer_str, :healthy)
          %{acc_state | peer_health: updated_health}
        end
      end)

    # Schedule next discovery check (every 2 seconds)
    schedule_peer_discovery()

    {:noreply, new_state}
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

  defp parse_ip_address(host) do
    # Try to parse as IP address, otherwise resolve via DNS
    case :inet.parse_address(to_charlist(host)) do
      {:ok, ip_tuple} ->
        ip_tuple

      {:error, _} ->
        # Not a valid IP, try DNS lookup
        case :inet.getaddr(to_charlist(host), :inet) do
          {:ok, ip_tuple} -> ip_tuple
          # Fallback to charlist
          {:error, _} -> to_charlist(host)
        end
    end
  end

  defp configure_partisan(node_name, shared_secret, listen_port) do
    # 1. Identity - Use node_name@ip format
    my_ip = get_node_ip()
    full_node_name = String.to_atom("#{node_name}@#{my_ip}")

    # 2. Basic Partisan Config
    # Note: Partisan 5 uses 'name' and 'peer_service_manager' keys
    Application.put_env(:partisan, :name, full_node_name)

    Application.put_env(
      :partisan,
      :peer_service_manager,
      :partisan_pluggable_peer_service_manager
    )

    # 3. Networking & Storage
    # Use Ets if you want clean slates, or omit this for disk persistence (default)
    # Listen on all interfaces (0.0.0.0) to accept connections from any network
    Application.put_env(:partisan, :listen_addrs, [%{ip: {0, 0, 0, 0}, port: listen_port}])
    Application.put_env(:partisan, :storage_backend, Partisan.Storage.Backend.Ets)
    # Application.put_env(:partisan, :data_dir, "/var/lib/partisan_data")

    # 4. Channels
    # undefined: Required by Partisan internals (hardcoded dependency)
    # default: Used for our RPC calls with monotonic ordering
    Application.put_env(:partisan, :channels, %{
      undefined: %{monotonic: false, parallelism: 1, compression: false},
      default: %{monotonic: true, parallelism: 1, compression: false}
    })

    # 5. TLS with Shared Secret (No Certs)
    # We use Pre-Shared Key (PSK) authentication
    # Secret comes as hex-encoded string from env, needs to be decoded to bytes
    psk_secret =
      case Base.decode16(shared_secret, case: :lower) do
        {:ok, bytes} ->
          bytes

        :error ->
          # Try mixed case
          case Base.decode16(shared_secret, case: :mixed) do
            {:ok, bytes} ->
              bytes

            :error ->
              Logger.error("Invalid cluster secret format - must be hex-encoded")
              raise ArgumentError, "Cluster secret must be a valid hex string"
          end
      end

    # Validate secret length (minimum 32 bytes / 256 bits for security)
    if byte_size(psk_secret) < 32 do
      Logger.error(
        "Cluster secret is too short: #{byte_size(psk_secret)} bytes (minimum 32 bytes required)"
      )

      raise ArgumentError, "Cluster secret must be at least 32 bytes (64 hex characters)"
    end

    # Lookup function required by Erlang's :ssl for PSK
    # It verifies the identity and returns the secret key
    lookup_fun = {fn :psk, _id, _user_data -> {:ok, psk_secret} end, []}

    Application.put_env(:partisan, :tls, true)

    # TLS 1.2 PSK configuration with forward secrecy
    # Note: Erlang SSL does NOT support external PSK for TLS 1.3, only for TLS 1.2
    # Using PSK-DHE (PSK with Diffie-Hellman Ephemeral) for forward secrecy
    psk_options = [
      {:psk_identity, ~c"partisan_cluster"},
      {:user_lookup_fun, lookup_fun},
      # Disable certificate verification for PSK-only auth
      {:verify, :verify_none},
      # TLS 1.2 (required for external PSK support in Erlang)
      {:versions, [:"tlsv1.2"]},
      # PSK-DHE ciphersuites with AEAD for forward secrecy and modern crypto
      {:ciphers,
       [
         # DHE-PSK with AEAD (forward secrecy + authenticated encryption)
         %{key_exchange: :dhe_psk, cipher: :aes_256_gcm, mac: :aead, prf: :sha384},
         %{key_exchange: :dhe_psk, cipher: :aes_128_gcm, mac: :aead, prf: :sha256}
       ]},
      # Aggressive timeout settings for fast disconnect detection
      {:send_timeout, 5_000},
      # Close socket after send timeout (5 seconds)
      {:send_timeout_close, true}
      # Close connection if send fails
    ]

    Application.put_env(:partisan, :tls_server_options, psk_options)
    Application.put_env(:partisan, :tls_client_options, psk_options)

    # 6. Start Application
    case Application.ensure_all_started(:partisan) do
      {:ok, _} ->
        # Set Partisan log level
        :logger.set_application_level(:partisan, :warning)

        Logger.info(
          "Partisan 5.0.3 started as #{full_node_name} on port #{listen_port} (TLS 1.2 PSK-DHE Enabled)"
        )

        {:ok, full_node_name}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp connect_to_peer(peer_address, config) do
    # Parse peer address: "node_name@host:port"
    case parse_peer_address(peer_address) do
      {:ok, node_name, host, port} ->
        # Parse IP address (convert "127.0.0.1" to {127, 0, 0, 1})
        ip_tuple = parse_ip_address(host)

        # Create Partisan node specification with channels
        peer_node = %{
          name: String.to_atom("#{node_name}@#{host}"),
          listen_addrs: [%{ip: ip_tuple, port: port}],
          channels: %{
            undefined: %{monotonic: false, parallelism: 1, compression: false},
            default: %{monotonic: true, parallelism: 1, compression: false}
          }
        }

        # Attempt to join the peer using Partisan manager
        manager = Application.get_env(:partisan, :peer_service_manager)

        case manager.join(peer_node) do
          :ok ->
            # Only log on initial connection attempt, not reconnections
            if config != [] do
              Logger.info("Attempting to connect to peer: #{peer_address}")
            end

            # Register on_up and on_down callbacks for immediate notifications
            register_peer_callbacks(peer_node.name)
            :ok

          {:error, reason} ->
            send(__MODULE__, {:peer_down, peer_node.name})
            Logger.warning("Failed to connect to peer #{peer_address}: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Invalid peer address #{peer_address}: #{reason}")
        {:error, reason}
    end
  end

  defp register_peer_callbacks(node_name) do
    # Register on_up callback to send message when peer connects
    :partisan_peer_service.on_up(
      node_name,
      fn ->
        send(__MODULE__, {:peer_up, node_name, :up_detected})
      end
    )

    # Register on_down callback to send message when peer disconnects
    :partisan_peer_service.on_down(
      node_name,
      fn ->
        send(__MODULE__, {:peer_down, node_name, :down_detected})
      end
    )
  end

  defp parse_peer_address(address) do
    # Format: "node_name@host:port"
    case String.split(address, "@") do
      [node_name, host_port] ->
        case String.split(host_port, ":") do
          [host, port_str] ->
            case Integer.parse(port_str) do
              {port, ""} -> {:ok, node_name, host, port}
              _ -> {:error, "Invalid port number"}
            end

          _ ->
            {:error, "Invalid format after @, expected host:port"}
        end

      _ ->
        {:error, "Invalid format, expected node_name@host:port"}
    end
  end

  defp get_partisan_peers do
    # Get the list of cluster members using Partisan's peer service API
    try do
      # Partisan 5.0.3 API - use partisan_peer_service module
      manager = Application.get_env(:partisan, :peer_service_manager)

      case manager.members() do
        {:ok, members} when is_list(members) ->
          # Get our own node name
          myself = Application.get_env(:partisan, :name)

          # Filter out self from the list
          members
          |> Enum.reject(fn member -> member == myself end)

        {:error, reason} ->
          Logger.warning("Failed to get Partisan members: #{inspect(reason)}")
          []

        other ->
          Logger.warning("manager.members() returned unexpected format: #{inspect(other)}")
          []
      end
    catch
      kind, reason ->
        Logger.warning("Partisan members call failed: #{inspect({kind, reason})}")
        []
    end
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

  defp schedule_peer_discovery do
    # Check for new peers every 2 seconds
    Process.send_after(self(), :discover_peers, 2_000)
  end
end
