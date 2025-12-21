defmodule ElixirGateway.Cluster.Manager do
  @moduledoc """
  Manages Partisan setup, peer connections, and health heartbeats.

  Responsibilities:
  - Configure and start Partisan with TLS encryption
  - Connect to peer nodes
  - Send periodic health heartbeats
  - Monitor peer health status
  - Automatically reconnect to disconnected peers

  ## Asymmetric Configuration

  Supports setups where one node has a static IP (cloud) and another has
  a dynamic IP (home). The dynamic IP node should list the static IP node
  as a peer, while the static IP node can have an empty peers list.

  This creates a bidirectional connection where the home node reconnects
  automatically when its IP changes, without requiring the cloud node to
  track the changing IP address.
  """
  alias :partisan_peer_service, as: PartisanPeerService
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
      PartisanPeerService.Manager.DefaultPeerServiceManager
    )

    # 3. Networking & Storage
    # Use Ets if you want clean slates, or omit this for disk persistence (default)
    Application.put_env(:partisan, :listen_addrs, [%{ip: {0, 0, 0, 0}, port: listen_port}])
    Application.put_env(:partisan, :storage_backend, Partisan.Storage.Backend.Ets)
    # Application.put_env(:partisan, :data_dir, "/var/lib/partisan_data")

    # 4. Channels
    Application.put_env(:partisan, :channels, %{
      default: %{monotonic: true, parallelism: 1}
    })

    # 5. TLS with Shared Secret (No Certs)
    # We use Pre-Shared Key (PSK) authentication
    # Secret comes as hex-encoded string from env, needs to be decoded to bytes
    psk_secret =
      case Base.decode16(shared_secret, case: :lower) do
        {:ok, bytes} -> bytes
        :error ->
          # Try mixed case
          case Base.decode16(shared_secret, case: :mixed) do
            {:ok, bytes} -> bytes
            :error ->
              Logger.error("Invalid cluster secret format - must be hex-encoded")
              raise ArgumentError, "Cluster secret must be a valid hex string"
          end
      end

    # Lookup function required by Erlang's :ssl for PSK
    # It verifies the identity and returns the secret key
    lookup_fun = {fn :psk, _id, _user_data -> {:ok, psk_secret} end, []}

    Application.put_env(:partisan, :tls, true)

    # Shared options for both Client and Server
    psk_options = [
      {:psk_identity, "partisan_cluster"},
      {:user_lookup_fun, lookup_fun},
      # Support TLS 1.3 and 1.2
      {:versions, [:"tlsv1.3", :"tlsv1.2"]},
      # PSK ciphersuites for both TLS versions
      {:ciphers, [
        # TLS 1.3 PSK cipher (preferred)
        :"TLS_AES_256_GCM_SHA384",
        :"TLS_AES_128_GCM_SHA256",
        # TLS 1.2 PSK fallback
        :psk_with_aes_128_cbc_sha,
        :psk_with_aes_256_cbc_sha
      ]}
    ]

    Application.put_env(:partisan, :tls_server_options, psk_options)
    Application.put_env(:partisan, :tls_client_options, psk_options)

    # 6. Start Application
    case Application.ensure_all_started(:partisan) do
      {:ok, _} ->
        Logger.info(
          "Partisan 5.0.3 started as #{full_node_name} on port #{listen_port} (PSK Enabled)"
        )

        {:ok, full_node_name}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp connect_to_peer(peer_address, _config) do
    # Parse peer address (e.g., "gateway-b.example.com:9100" or "192.168.1.10:9100")
    case parse_peer_address(peer_address) do
      {:ok, host, port} ->
        # Extract node name from hostname (first part before .)
        # For "gateway-b.example.com" -> "gateway-b"
        # For "192.168.1.10" -> "192.168.1.10" (IP as-is)
        peer_node_name = extract_node_name(host)

        # Create Partisan node specification using name@host format
        peer_node = %{
          name: String.to_atom("#{peer_node_name}@#{host}"),
          listen_addrs: [%{ip: to_charlist(host), port: port}]
        }

        # Attempt to join the peer
        case PartisanPeerService.join(peer_node) do
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
    # Get the list of cluster members
    case PartisanPeerService.members() do
      {:ok, members} ->
        # Get our own identity to filter it out
        myself = :partisan.node_spec()

        # Filter out self. Note: 'members' usually returns a list of names (atoms).
        # 'myself' returns a full spec map. We compare the name field.
        members
        |> Enum.reject(fn member_name -> member_name == myself.name end)

      {:error, reason} ->
        Logger.warning("Failed to get Partisan members: #{inspect(reason)}")
        []
    end
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

  defp reconnect_if_needed(configured_peers, peer_health) do
    Enum.each(configured_peers, fn peer ->
      case Map.get(peer_health, peer) do
        :disconnected ->
          Logger.info("Attempting to reconnect to disconnected peer: #{peer}")
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
            Logger.warning("Failed to detect public IP (#{inspect(reason)}), falling back to local IP")

            # Fallback to local IP detection
            case IPDetection.get_local_ip() do
              {:ok, ip} ->
                ip

              {:error, _} ->
                Logger.error("Could not detect any IP address, using 127.0.0.1")
                "127.0.0.1"
            end
        end

      ip when is_binary(ip) ->
        ip
    end
  end

  defp extract_node_name(host) do
    # If it looks like an IP address, use it as-is
    # Otherwise, extract first part of hostname
    if String.match?(host, ~r/^\d+\.\d+\.\d+\.\d+$/) do
      # It's an IP address, use as-is
      host
    else
      # It's a hostname, extract first part before '.'
      host |> String.split(".") |> List.first()
    end
  end

  defp schedule_heartbeat(interval) do
    Process.send_after(self(), :send_heartbeat, interval)
  end
end
