defmodule ElixirGateway.Cluster.CertificateManager do
  @moduledoc """
  Manages certificate synchronization across the distributed cluster.

  Architecture:
  - Primary node: Generates certificates via SiteEncrypt, broadcasts to peers (typically home server)
  - Secondary nodes: Receive certificates via distributed Erlang RPC, validate and install (typically cloud servers)

  Role Determination:
  1. Explicit: IS_PRIMARY env var (true/false)
  2. Auto-detect: DNS failover enabled → Primary (manages DNS), otherwise Secondary

  Typical Setup:
  - Primary (home server): Manages DNS failover, generates certs, knows peer IPs, CLUSTER_PEERS="cloud-a@ip:port,cloud-b@ip:port"
  - Secondary (cloud servers): Accept connections, receive certs, CLUSTER_PEERS="" (empty)

  Certificate Flow:
  Primary: SiteEncrypt generates → handle_new_cert callback → broadcast_certificates
  Secondary: receive_certificates RPC → validate → write to disk → reload endpoint
  """

  use GenServer
  use ElixirGateway.Cluster.RPC
  require Logger

  alias ElixirGateway.Cluster.Manager, as: ClusterManager
  alias ElixirGateway.Utils

  @typedoc "Certificate bundle with all required files"
  @type cert_bundle :: %{
          domain: String.t(),
          cert_pem: binary(),
          privkey_pem: binary(),
          chain_pem: binary(),
          checksum: binary(),
          generated_at: DateTime.t()
        }

  @sync_retry_base_delay 1_000

  defstruct [
    :role,
    :cert_sync_enabled,
    :db_folder,
    :last_sync,
    :sync_failures,
    :rpc_timeout,
    :max_sync_retries
  ]

  ## Client API

  @doc """
  Starts the certificate manager.
  Role is determined from cluster config.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Called by SiteEncrypt's handle_new_cert callback when new certificates are generated.
  Only runs on primary nodes.
  """
  @spec on_certificates_generated(domain :: String.t()) :: :ok | {:error, term()}
  def on_certificates_generated(domain) do
    GenServer.cast(__MODULE__, {:certificates_generated, domain})
  end

  @impl ElixirGateway.Cluster.RPC
  def handle_rpc({:sync_certificates, cert_bundle}) do
    timeout = get_rpc_timeout()
    GenServer.call(__MODULE__, {:receive_certificates, cert_bundle}, timeout)
  end

  @doc """
  Returns current synchronization status.
  """
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Manually trigger certificate sync (for testing/debugging).
  """
  @spec trigger_sync(domain :: String.t()) :: :ok | {:error, term()}
  def trigger_sync(domain) do
    timeout = get_rpc_timeout()
    GenServer.call(__MODULE__, {:trigger_sync, domain}, timeout)
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    cluster_config = Application.get_env(:elixirgateway, :cluster, [])
    cert_sync_config = Keyword.get(cluster_config, :cert_sync, [])

    enabled = Keyword.get(cert_sync_config, :enabled, true)
    role = determine_role(cluster_config)

    db_folder = get_cert_db_folder()
    rpc_timeout = Keyword.get(cert_sync_config, :rpc_timeout, 30_000)
    max_retries = Keyword.get(cert_sync_config, :max_retries, 3)

    state = %__MODULE__{
      role: role,
      cert_sync_enabled: enabled,
      db_folder: db_folder,
      last_sync: nil,
      sync_failures: 0,
      rpc_timeout: rpc_timeout,
      max_sync_retries: max_retries
    }

    if enabled do
      Logger.info("Certificate sync manager started as #{role} (db: #{db_folder})")

      # Primary nodes monitor for new peers to automatically sync certificates
      if role == :primary do
        :net_kernel.monitor_nodes(true, node_type: :all)
        Logger.debug("Monitoring node connections for automatic certificate sync")
      end
    else
      Logger.info("Certificate sync disabled")
    end

    {:ok, state}
  end

  @impl true
  def handle_cast({:certificates_generated, domain}, %{role: :primary} = state) do
    if state.cert_sync_enabled do
      Logger.info("Certificates generated for #{domain}, broadcasting to cluster")

      case broadcast_certificates(domain, state) do
        :ok ->
          {:noreply, %{state | last_sync: DateTime.utc_now(), sync_failures: 0}}

        {:error, reason} ->
          Logger.error("Failed to broadcast certificates: #{inspect(reason)}")
          # Schedule retry with exponential backoff
          backoff_ms = calculate_backoff(state.sync_failures)
          Process.send_after(self(), {:retry_broadcast, domain}, backoff_ms)
          {:noreply, %{state | sync_failures: state.sync_failures + 1}}
      end
    else
      {:noreply, state}
    end
  end

  def handle_cast({:certificates_generated, _domain}, state) do
    # Secondary nodes ignore this - they receive via RPC
    {:noreply, state}
  end

  @impl true
  def handle_call({:receive_certificates, cert_bundle}, _from, %{role: :secondary} = state) do
    Logger.info("Receiving certificates for domain: #{cert_bundle.domain}")

    result = install_certificates(cert_bundle, state)

    case result do
      :ok ->
        {:reply, :ok, %{state | last_sync: DateTime.utc_now(), sync_failures: 0}}

      error ->
        {:reply, error, %{state | sync_failures: state.sync_failures + 1}}
    end
  end

  def handle_call({:receive_certificates, _bundle}, _from, %{role: :primary} = state) do
    {:reply, {:error, :primary_cannot_receive}, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      role: state.role,
      cert_sync_enabled: state.cert_sync_enabled,
      db_folder: state.db_folder,
      last_sync: state.last_sync,
      sync_failures: state.sync_failures,
      clustering_enabled: clustering_enabled?()
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call({:trigger_sync, domain}, _from, %{role: :primary} = state) do
    result = broadcast_certificates(domain, state)
    {:reply, result, state}
  end

  def handle_call({:trigger_sync, _domain}, _from, %{role: :secondary} = state) do
    {:reply, {:error, :secondary_cannot_trigger}, state}
  end

  @impl true
  def handle_info({:retry_broadcast, domain}, state) do
    if state.sync_failures < state.max_sync_retries do
      Logger.info("Retrying certificate broadcast (attempt #{state.sync_failures + 1})")

      case broadcast_certificates(domain, state) do
        :ok ->
          {:noreply, %{state | sync_failures: 0}}

        {:error, _reason} ->
          backoff_ms = calculate_backoff(state.sync_failures)
          Process.send_after(self(), {:retry_broadcast, domain}, backoff_ms)
          {:noreply, %{state | sync_failures: state.sync_failures + 1}}
      end
    else
      Logger.error("Max sync retries exceeded for #{domain}, giving up")
      {:noreply, %{state | sync_failures: 0}}
    end
  end

  @impl true
  def handle_info({:nodeup, node, _info}, %{role: :primary} = state) do
    # New peer connected - schedule automatic certificate sync after delay
    # Delay ensures SiteEncrypt on the secondary finishes initialization first
    if state.cert_sync_enabled do
      Logger.info(
        "New peer #{node} connected, scheduling automatic certificate sync in 3 seconds"
      )

      Process.send_after(self(), {:sync_to_new_peer, node}, 3_000)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:sync_to_new_peer, node}, %{role: :primary} = state) do
    Logger.info("Initiating automatic certificate sync to #{node}")

    with {:ok, domain} <- get_primary_domain(),
         {:ok, _cert_bundle} <- read_certificates(domain, state.db_folder),
         :ok <- broadcast_to_peer(node, domain, state) do
      Logger.info("Successfully synced certificates to new peer #{node}")
    else
      {:error, :no_domains} ->
        Logger.debug("No domains configured, skipping automatic certificate sync")

      {:error, reason} ->
        # This handles errors from both read_certificates and broadcast_to_peer
        # since they both return {:error, reason}
        Logger.warning("Sync interrupted for #{node}: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_info({:nodeup, _node, _info}, state) do
    # Secondary nodes ignore nodeup events
    {:noreply, state}
  end

  def handle_info({:nodedown, _node, _info}, state) do
    # Ignore nodedown events (ClusterManager handles reconnection)
    {:noreply, state}
  end

  ## Private Functions

  defp get_rpc_timeout do
    cluster_config = Application.get_env(:elixirgateway, :cluster, [])
    cert_sync_config = Keyword.get(cluster_config, :cert_sync, [])
    Keyword.get(cert_sync_config, :rpc_timeout, 30_000)
  end

  defp calculate_backoff(attempt) do
    Utils.exponential_backoff(attempt, base_delay: @sync_retry_base_delay)
  end

  defp get_primary_domain do
    case ElixirGateway.SiteEncrypt.get_domains() do
      [domain | _] -> {:ok, domain}
      [] -> {:error, :no_domains}
    end
  end

  defp determine_role(cluster_config) do
    # 1. Check explicit override
    case System.get_env("IS_PRIMARY") do
      "true" ->
        Logger.info("Role: Primary (explicit IS_PRIMARY=true)")
        :primary

      "false" ->
        Logger.info("Role: Secondary (explicit IS_PRIMARY=false)")
        :secondary

      _ ->
        # 2. Auto-detect from peers configuration
        # Primary (home server with dynamic IP) knows about cloud servers and has peers configured
        # Secondary (cloud servers with static IP) accepts connections and has no peers
        peers = Keyword.get(cluster_config, :peers, [])

        if peers != [] do
          Logger.info("Role: Primary (auto-detected: peers configured)")
          :primary
        else
          Logger.info("Role: Secondary (auto-detected: no peers configured)")
          :secondary
        end
    end
  end

  defp clustering_enabled? do
    config = Application.get_env(:elixirgateway, :cluster, [])
    Keyword.get(config, :enabled, false)
  end

  defp get_cert_db_folder do
    System.get_env("SITE_ENCRYPT_DB") || Path.join("priv", "certs")
  end

  defp broadcast_certificates(domain, state) do
    with {:ok, cert_bundle} <- read_certificates(domain, state.db_folder),
         {:ok, peers} <- get_connected_peers() do
      if peers == [] do
        Logger.info("No connected peers to sync certificates to")
        :ok
      else
        results =
          Enum.map(peers, fn peer ->
            broadcast_to_peer(peer, cert_bundle, state.rpc_timeout)
          end)

        # Check if all succeeded
        if Enum.all?(results, &match?(:ok, &1)) do
          Logger.info("Successfully synced certificates to #{length(peers)} peer(s)")
          :ok
        else
          failures = Enum.filter(results, &match?({:error, _}, &1))
          Logger.warning("Some peer syncs failed: #{inspect(failures)}")
          {:error, {:partial_failure, failures}}
        end
      end
    end
  end

  defp read_certificates(domain, db_folder) do
    cert_folder = Path.join([db_folder, "certs", domain])

    files = %{
      cert_pem: Path.join(cert_folder, "cert.pem"),
      privkey_pem: Path.join(cert_folder, "privkey.pem"),
      chain_pem: Path.join(cert_folder, "chain.pem")
    }

    # Read all files
    with {:ok, cert_pem} <- File.read(files.cert_pem),
         {:ok, privkey_pem} <- File.read(files.privkey_pem),
         {:ok, chain_pem} <- File.read(files.chain_pem) do
      # Create checksum of all content
      checksum = :crypto.hash(:sha256, cert_pem <> privkey_pem <> chain_pem)

      bundle = %{
        domain: domain,
        cert_pem: cert_pem,
        privkey_pem: privkey_pem,
        chain_pem: chain_pem,
        checksum: checksum,
        generated_at: DateTime.utc_now()
      }

      {:ok, bundle}
    else
      {:error, reason} ->
        Logger.error("Failed to read certificates for #{domain}: #{inspect(reason)}")
        {:error, {:read_failed, reason}}
    end
  end

  defp get_connected_peers do
    if clustering_enabled?() do
      # Check if ClusterManager is running and retry with backoff if needed
      get_connected_peers_with_retry(0, 3)
    else
      {:error, :clustering_disabled}
    end
  end

  defp get_connected_peers_with_retry(attempt, max_attempts) when attempt < max_attempts do
    try do
      peers = ClusterManager.connected_peers()
      {:ok, peers}
    catch
      :exit, {:noproc, _} ->
        # ClusterManager not running
        if attempt + 1 < max_attempts do
          backoff_ms = Utils.exponential_backoff(attempt, base_delay: 100, jitter: :none)

          Logger.debug(
            "ClusterManager not available, retrying in #{backoff_ms}ms (#{max_attempts - attempt - 1} retries left)"
          )

          Process.sleep(backoff_ms)
          get_connected_peers_with_retry(attempt + 1, max_attempts)
        else
          Logger.warning("ClusterManager unavailable after retries")
          {:ok, []}
        end

      :exit, {:timeout, _} ->
        Logger.warning("Timeout calling ClusterManager.connected_peers()")
        {:ok, []}
    end
  end

  defp get_connected_peers_with_retry(_attempt, _max_attempts) do
    Logger.warning("Failed to get connected peers after all retries")
    {:ok, []}
  end

  defp broadcast_to_peer(peer_node, domain, state) when is_binary(domain) do
    # Read certificates and broadcast to a specific peer
    with {:ok, cert_bundle} <- read_certificates(domain, state.db_folder) do
      broadcast_to_peer(peer_node, cert_bundle, state.rpc_timeout)
    end
  end

  defp broadcast_to_peer(peer_node, cert_bundle, rpc_timeout) do
    Logger.debug("Sending certificates to #{peer_node}")

    case rpc_call(peer_node, {:sync_certificates, cert_bundle}, rpc_timeout) do
      :ok ->
        Logger.info("Successfully synced certificates to #{peer_node}")
        :ok

      {:error, reason} = error ->
        Logger.error("Failed to sync to #{peer_node}: #{inspect(reason)}")
        error
    end
  end

  defp install_certificates(cert_bundle, state) do
    Logger.info("Installing certificates for #{cert_bundle.domain}")

    # Validate checksum
    computed_checksum =
      :crypto.hash(
        :sha256,
        cert_bundle.cert_pem <> cert_bundle.privkey_pem <> cert_bundle.chain_pem
      )

    if computed_checksum != cert_bundle.checksum do
      Logger.error("Certificate checksum mismatch!")
      {:error, :checksum_mismatch}
    else
      # Write certificates to disk
      cert_folder = Path.join([state.db_folder, "certs", cert_bundle.domain])
      File.mkdir_p!(cert_folder)
      File.chmod!(cert_folder, 0o700)

      files = [
        {"cert.pem", cert_bundle.cert_pem},
        {"privkey.pem", cert_bundle.privkey_pem},
        {"chain.pem", cert_bundle.chain_pem}
      ]

      try do
        Enum.each(files, fn {filename, content} ->
          path = Path.join(cert_folder, filename)
          File.write!(path, content)
          File.chmod!(path, 0o600)
        end)

        Logger.info("Certificates written to #{cert_folder}")

        # Reload endpoint to pick up new certificates
        reload_endpoint_certificates()

        :ok
      rescue
        error ->
          Logger.error("Failed to write certificates: #{inspect(error)}")
          {:error, {:write_failed, error}}
      end
    end
  end

  defp reload_endpoint_certificates do
    :ssl.clear_pem_cache()

    # Restart the HTTPS Bandit listener so it re-reads the cert files from disk.
    # clear_pem_cache alone is insufficient when SiteEncrypt passes cert as binary
    # data at startup rather than a file path reference.
    # Must terminate first — restart_child only works on already-stopped children.
    endpoint = ElixirGatewayWeb.Endpoint
    child_id = {endpoint, :https}

    with :ok <- Supervisor.terminate_child(endpoint, child_id),
         {:ok, _pid} <- Supervisor.restart_child(endpoint, child_id) do
      Logger.info("HTTPS listener restarted with new certificates")
    else
      {:error, reason} ->
        Logger.warning("Could not restart HTTPS listener: #{inspect(reason)}")
    end

    :ok
  end
end
