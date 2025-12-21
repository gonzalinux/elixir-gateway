defmodule ElixirGateway.Cluster.DNSFailover do
  @moduledoc """
  Monitors peer health and triggers DDNS updates on failure.

  Behavior:
  - Monitors cluster health via Cluster.Manager
  - When all peers are down, updates DNS to point to this node
  - When peers recover, optionally updates DNS back
  - Includes backoff to prevent DNS flapping
  """

  use GenServer
  require Logger

  alias ElixirGateway.Cluster.DDNS.Namecheap

  @default_check_interval 5_000
  @default_failover_timeout 5_000

  defstruct [
    :config,
    :domains,
    :public_ip_method,
    :provider,
    :check_interval,
    :failover_timeout,
    :last_state,
    :failover_triggered_at,
    :public_ip_cache
  ]

  ## Client API

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc """
  Manually trigger a DNS update to this node's IP.
  """
  def trigger_failover do
    GenServer.call(__MODULE__, :trigger_failover)
  end

  @doc """
  Get the current failover status.
  """
  def status do
    GenServer.call(__MODULE__, :get_status)
  end

  ## Server Callbacks

  @impl true
  def init(config) do
    domains = Keyword.get(config, :domains, [])
    provider = Keyword.get(config, :provider, :namecheap_ddns)
    public_ip_method = Keyword.get(config, :public_ip_method, :auto)
    check_interval = Keyword.get(config, :check_interval, @default_check_interval)
    failover_timeout = Keyword.get(config, :failover_timeout, @default_failover_timeout)

    if domains == [] do
      Logger.warning("DNS failover enabled but no domains configured")
    end

    state = %__MODULE__{
      config: config,
      domains: domains,
      public_ip_method: public_ip_method,
      provider: provider,
      check_interval: check_interval,
      failover_timeout: failover_timeout,
      last_state: :unknown,
      failover_triggered_at: nil,
      public_ip_cache: nil
    }

    # Schedule first health check
    schedule_health_check(check_interval)

    Logger.info("DNS failover monitor started (provider: #{provider})")

    {:ok, state}
  end

  @impl true
  def handle_info(:check_health, state) do
    new_state = perform_health_check(state)

    # Schedule next check
    schedule_health_check(state.check_interval)

    {:noreply, new_state}
  end

  @impl true
  def handle_call(:trigger_failover, _from, state) do
    Logger.warning("Manual DNS failover triggered")
    result = perform_dns_update(state)

    new_state = %{state | last_state: :failed, failover_triggered_at: System.monotonic_time(:millisecond)}

    {:reply, result, new_state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      last_state: state.last_state,
      failover_triggered_at: state.failover_triggered_at,
      domains: state.domains,
      provider: state.provider,
      cached_public_ip: state.public_ip_cache
    }

    {:reply, status, state}
  end

  ## Private Functions

  defp perform_health_check(state) do
    cluster_healthy = ElixirGateway.Cluster.Manager.cluster_healthy?()

    cond do
      # Cluster was healthy, now unhealthy - trigger failover
      state.last_state == :healthy and not cluster_healthy ->
        Logger.warning("Cluster became unhealthy, initiating DNS failover")
        wait_for_failover_timeout(state.failover_timeout)
        perform_dns_update(state)
        %{state | last_state: :failed, failover_triggered_at: System.monotonic_time(:millisecond)}

      # Cluster was unhealthy, now healthy - log recovery
      state.last_state == :failed and cluster_healthy ->
        Logger.info("Cluster recovered, peers are healthy again")
        # Optionally update DNS back to primary (for now, we don't)
        %{state | last_state: :healthy}

      # First check or no state change
      state.last_state == :unknown ->
        initial_state = if cluster_healthy, do: :healthy, else: :failed
        Logger.info("Initial cluster health state: #{initial_state}")
        %{state | last_state: initial_state}

      # No change
      true ->
        state
    end
  end

  defp wait_for_failover_timeout(timeout) do
    Logger.info("Waiting #{timeout}ms before triggering failover...")
    Process.sleep(timeout)
  end

  defp perform_dns_update(state) do
    case get_public_ip(state) do
      {:ok, ip} ->
        Logger.info("Updating DNS records to point to #{ip}")

        results =
          case state.provider do
            :namecheap_ddns ->
              Namecheap.update_all(state.domains, ip)

            other ->
              Logger.error("Unsupported DNS provider: #{other}")
              []
          end

        # Check if all updates succeeded
        failures = Enum.filter(results, fn {_domain, _host, result} -> result != :ok end)

        if failures == [] do
          Logger.info("All DNS updates successful")
          {:ok, ip}
        else
          Logger.error("Some DNS updates failed: #{inspect(failures)}")
          {:error, :partial_failure}
        end

      {:error, reason} ->
        Logger.error("Failed to get public IP: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp get_public_ip(state) do
    case state.public_ip_method do
      :auto ->
        # Use cached IP if available and recent (5 minutes)
        now = System.monotonic_time(:millisecond)

        case state.public_ip_cache do
          {ip, cached_at} ->
            if now - cached_at < 300_000 do
              {:ok, ip}
            else
              fetch_public_ip()
            end

          _ ->
            fetch_public_ip()
        end

      {:static, ip} ->
        {:ok, ip}

      other ->
        Logger.error("Invalid public_ip_method: #{inspect(other)}")
        {:error, :invalid_config}
    end
  end

  defp fetch_public_ip do
    case Namecheap.get_public_ip() do
      {:ok, ip} ->
        # Update cache
        # Note: We're returning the result, cache update happens in caller
        {:ok, ip}

      error ->
        error
    end
  end

  defp schedule_health_check(interval) do
    Process.send_after(self(), :check_health, interval)
  end
end
