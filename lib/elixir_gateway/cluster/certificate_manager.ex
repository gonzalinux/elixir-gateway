defmodule ElixirGateway.Cluster.CertificateManager do
  @moduledoc """
  Manages certificate synchronization across the distributed cluster.

  Architecture:
  - Primary node: Certbot issues/renews certs, broadcasts to peers via RPC
  - Secondary nodes: Receive cert files via RPC, write to their certbot live dir, reload CertStore

  Role Determination:
  1. Explicit: IS_PRIMARY env var (true/false)
  2. Auto-detect: peers configured → Primary, otherwise Secondary

  Certificate Flow:
  Primary: CertbotRunner succeeds → on_certificates_generated → broadcast_certificates
  Secondary: receive_certificates RPC → validate → write to certbot live dir → CertStore.reload()
  """

  use GenServer
  use ElixirGateway.Cluster.RPC
  require Logger

  alias ElixirGateway.Cluster.Manager, as: ClusterManager
  alias ElixirGateway.Utils

  @typedoc "Certificate bundle with all required files"
  @type cert_bundle :: %{
          domain: String.t(),
          fullchain_pem: binary(),
          privkey_pem: binary(),
          checksum: binary(),
          generated_at: DateTime.t()
        }

  @sync_retry_base_delay 1_000

  defstruct [
    :role,
    :cert_sync_enabled,
    :live_dir,
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
    role = if ElixirGateway.Cluster.Role.primary?(), do: :primary, else: :secondary

    live_dir = certbot_live_dir()
    rpc_timeout = Keyword.get(cert_sync_config, :rpc_timeout, 30_000)
    max_retries = Keyword.get(cert_sync_config, :max_retries, 3)

    state = %__MODULE__{
      role: role,
      cert_sync_enabled: enabled,
      live_dir: live_dir,
      last_sync: nil,
      sync_failures: 0,
      rpc_timeout: rpc_timeout,
      max_sync_retries: max_retries
    }

    if enabled do
      Logger.info("Certificate sync manager started as #{role} (live: #{live_dir})")

      if role == :primary do
        # Monitor for new peers to automatically sync certificates
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
      Logger.info("Certbot issued/renewed cert for #{domain}, broadcasting to cluster")

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
      live_dir: state.live_dir,
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

    domains = all_cert_domains()

    if domains == [] do
      Logger.debug("No domains configured, skipping automatic certificate sync")
    else
      {succeeded, failed} =
        domains
        |> Enum.map(fn domain ->
          case broadcast_to_peer(node, domain, state) do
            :ok -> {:ok, domain}
            {:error, reason} -> {:error, domain, reason}
          end
        end)
        |> Enum.split_with(&match?({:ok, _}, &1))

      Enum.each(failed, fn {:error, domain, reason} ->
        Logger.warning("Failed to sync #{domain} to #{node}: #{inspect(reason)}")
      end)

      Logger.info(
        "Certificate sync to #{node} complete: #{length(succeeded)}/#{length(domains)} domain(s) synced"
      )
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

  defp all_cert_domains do
    http = Application.get_env(:elixirgateway, :letsencrypt_domains, [])
    dns = Application.get_env(:elixirgateway, :letsencrypt_wildcard_domains, [])
    Enum.map(http, &to_cert_name/1) ++ dns
  end

  # Certbot stores wildcard certs under the apex domain, e.g. "*.example.com" → "example.com"
  defp to_cert_name("*." <> apex), do: apex
  defp to_cert_name(domain), do: domain

  defp clustering_enabled? do
    config = Application.get_env(:elixirgateway, :cluster, [])
    Keyword.get(config, :enabled, false)
  end

  defp certbot_live_dir do
    Application.get_env(:elixirgateway, :cert_store, [])
    |> Keyword.get(:certbot_config_dir)
    |> Path.join("live")
  end

  defp broadcast_certificates(domain, state) do
    with {:ok, cert_bundle} <- read_certificates(domain, state.live_dir),
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

  defp read_certificates(domain, live_dir) do
    cert_dir = Path.join(live_dir, domain)

    with {:ok, fullchain_pem} <- File.read(Path.join(cert_dir, "fullchain.pem")),
         {:ok, privkey_pem} <- File.read(Path.join(cert_dir, "privkey.pem")) do
      checksum = :crypto.hash(:sha256, fullchain_pem <> privkey_pem)

      {:ok,
       %{
         domain: domain,
         fullchain_pem: fullchain_pem,
         privkey_pem: privkey_pem,
         checksum: checksum,
         generated_at: DateTime.utc_now()
       }}
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
    with {:ok, cert_bundle} <- read_certificates(domain, state.live_dir) do
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

    computed_checksum =
      :crypto.hash(:sha256, cert_bundle.fullchain_pem <> cert_bundle.privkey_pem)

    if computed_checksum != cert_bundle.checksum do
      Logger.error("Certificate checksum mismatch for #{cert_bundle.domain}")
      {:error, :checksum_mismatch}
    else
      cert_dir = Path.join(state.live_dir, cert_bundle.domain)
      File.mkdir_p!(cert_dir)
      File.chmod!(cert_dir, 0o700)

      files = [
        {"fullchain.pem", cert_bundle.fullchain_pem},
        {"privkey.pem", cert_bundle.privkey_pem}
      ]

      try do
        Enum.each(files, fn {filename, content} ->
          path = Path.join(cert_dir, filename)
          File.write!(path, content)
          File.chmod!(path, 0o600)
        end)

        Logger.info("Certificates written to #{cert_dir}")
        ElixirGateway.CertStore.reload()
        :ok
      rescue
        error ->
          Logger.error("Failed to write certificates: #{inspect(error)}")
          {:error, {:write_failed, error}}
      end
    end
  end
end
