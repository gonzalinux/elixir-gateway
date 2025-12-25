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
    # Update peer health based on connections
    # Note: We check peer health via members() - no need for explicit heartbeat messages
    # as Partisan handles connection health internally
    new_peer_health = update_peer_health(state.peers)

    # Log health state changes
    log_health_changes(state.peer_health, new_peer_health)

    # Attempt to reconnect to disconnected peers
    reconnect_if_needed(state.peers, new_peer_health)

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

    # Shared options for both Client and Server
    psk_options = [
      {:psk_identity, ~c"partisan_cluster"},
      {:user_lookup_fun, lookup_fun},
      # Disable certificate verification for PSK-only auth
      {:verify, :verify_none},
      # Support TLS 1.2 only (TLS 1.3 PSK has different requirements)
      {:versions, [:"tlsv1.2"]},
      # PSK ciphersuites for TLS 1.2 (tuple format required)
      {:ciphers,
       [
         {:psk, :aes_128_cbc, :sha},
         {:psk, :aes_256_cbc, :sha}
       ]}
    ]

    Application.put_env(:partisan, :tls_server_options, psk_options)
    Application.put_env(:partisan, :tls_client_options, psk_options)

    # 6. Start Application
    case Application.ensure_all_started(:partisan) do
      {:ok, _} ->
        # Set Partisan log level
        :logger.set_application_level(:partisan, :warning)

        Logger.info(
          "Partisan 5.0.3 started as #{full_node_name} on port #{listen_port} (PSK Enabled)"
        )

        {:ok, full_node_name}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp connect_to_peer(peer_address, _config) do
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

  defp update_peer_health(configured_peers) do
    connected = get_partisan_peers()

    # Track configured peers (ones we're trying to connect to)
    configured_health =
      Enum.reduce(configured_peers, %{}, fn peer, acc ->
        status =
          case parse_peer_address(peer) do
            {:ok, node_name, host, _port} ->
              expected_node = String.to_atom("#{node_name}@#{host}")

              if Enum.member?(connected, expected_node) do
                :healthy
              else
                :disconnected
              end

            _ ->
              :disconnected
          end

        Map.put(acc, peer, status)
      end)

    # Also track peers that connected to us (not in configured list)
    # Convert connected node atoms to string format for consistency
    connected_health =
      connected
      |> Enum.reject(fn node_atom ->
        # Skip if already tracked in configured_peers
        node_str = Atom.to_string(node_atom)

        Enum.any?(configured_peers, fn peer ->
          case parse_peer_address(peer) do
            {:ok, node_name, host, _port} ->
              "#{node_name}@#{host}" == node_str

            _ ->
              false
          end
        end)
      end)
      |> Enum.reduce(%{}, fn node_atom, acc ->
        # Track connected peers as healthy (they're connected)
        Map.put(acc, Atom.to_string(node_atom), :healthy)
      end)

    # Merge both maps
    Map.merge(configured_health, connected_health)
  end

  defp log_health_changes(old_health, new_health) do
    Enum.each(new_health, fn {peer, new_status} ->
      old_status = Map.get(old_health, peer)

      cond do
        # New peer connected to us (wasn't tracked before, now healthy)
        old_status == nil and new_status == :healthy ->
          Logger.info("Peer connected: #{peer}")

        # Peer went down
        old_status == :healthy and new_status == :disconnected ->
          Logger.warning("Peer disconnected: #{peer}")

        # Peer recovered
        old_status == :disconnected and new_status == :healthy ->
          Logger.info("Peer recovered: #{peer}")

        # No change
        true ->
          :ok
      end
    end)
  end

  defp reconnect_if_needed(configured_peers, peer_health) do
    Enum.each(configured_peers, fn peer ->
      case Map.get(peer_health, peer) do
        :disconnected ->
          # Silently attempt reconnection (already logged state change)
          connect_to_peer(peer, [])

        _ ->
          :ok
      end
    end)
  end

  defp get_node_ip do
    # Try to get IP from config first
    config = Application.get_env(:elixirgateway, :cluster, [])

    case Keyword.get(config, :node_ip) do
      nil ->
        # Auto-detect public IP
        case IPDetection.get_public_ip() do
          {:ok, ip} ->
            ip

          {:error, reason} ->
            Logger.warning("Failed to detect public IP (#{inspect(reason)}), trying local IP")

            # Fallback to local IP detection
            case IPDetection.get_local_ip() do
              {:ok, ip} ->
                ip

              {:error, local_reason} ->
                Logger.error(
                  "Failed to auto-detect IP address. Public IP: #{inspect(reason)}, Local IP: #{inspect(local_reason)}"
                )

                raise RuntimeError, """
                Could not detect node IP address for clustering.

                Please explicitly set NODE_IP in your environment:
                  export NODE_IP="your.server.ip.address"

                For local testing on the same machine, use:
                  export NODE_IP="127.0.0.1"

                For production, use your server's public IP address.
                """
            end
        end

      ip when is_binary(ip) and ip != "" ->
        ip

      _ ->
        raise ArgumentError, "NODE_IP cannot be empty. Please set a valid IP address."
    end
  end

  defp schedule_heartbeat(interval) do
    Process.send_after(self(), :send_heartbeat, interval)
  end
end
