defmodule ElixirGateway.Cluster.DNSFailover do
  @moduledoc """
  Monitors peer health and triggers DDNS updates on failure.

  Behavior:
  - Primary nodes (home server) claim DNS on startup by updating DNS to point to themselves
  - Monitors cluster health via Cluster.Manager every 5 seconds
  - When all peers become unhealthy, schedules a DNS failover after a timeout
  - If peers recover during the timeout, the failover is cancelled
  - Uses async scheduling to avoid blocking the GenServer during timeout

  ## Role Determination

  Primary role is determined by:
  1. Explicit: `IS_PRIMARY=true` environment variable
  2. Auto-detect: If DNS failover domains are configured → Primary

  Typical setup:
  - Primary (home server): Manages DNS updates when cloud servers fail, has `DDNS_DOMAINS` configured
  - Secondary (cloud servers): Don't manage DNS, just handle traffic, no `DDNS_DOMAINS`

  This prevents unnecessary DNS updates if a peer briefly disconnects and
  reconnects before the timeout expires. Primary nodes always claim DNS on
  startup to ensure they regain control when recovering from downtime.
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
    :public_ip_cache,
    :pending_failover_ref
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

  @doc """
  Check if the public IP has changed and update DNS if needed.
  Called periodically by the IP change detector job.
  """
  def check_ip_change do
    GenServer.call(__MODULE__, :check_ip_change)
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
      public_ip_cache: nil,
      pending_failover_ref: nil
    }

    # If this is the primary node and domains are configured, claim DNS on startup
    state =
      if is_primary?() and domains != [] do
        Logger.info("Primary node starting up, claiming DNS for domains: #{inspect(domains)}")
        {_result, updated_state} = perform_dns_update(state)
        updated_state
      else
        state
      end

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
  def handle_info(:execute_failover, state) do
    # Re-check cluster health before executing failover
    # (in case it recovered during the timeout period)
    cluster_healthy = ElixirGateway.Cluster.Manager.cluster_healthy?()

    if cluster_healthy do
      Logger.info("Cluster recovered during failover timeout, cancelling DNS update")
      {:noreply, %{state | last_state: :healthy, pending_failover_ref: nil}}
    else
      Logger.warning("Executing scheduled DNS failover")
      {_result, updated_state} = perform_dns_update(state)

      {:noreply,
       %{
         updated_state
         | last_state: :failed,
           failover_triggered_at: System.monotonic_time(:millisecond),
           pending_failover_ref: nil
       }}
    end
  end

  @impl true
  def handle_call(:trigger_failover, _from, state) do
    Logger.warning("Manual DNS failover triggered")

    if state.pending_failover_ref do
      Process.cancel_timer(state.pending_failover_ref)
    end

    {result, updated_state} = perform_dns_update(state)

    new_state = %{
      updated_state
      | last_state: :failed,
        failover_triggered_at: System.monotonic_time(:millisecond),
        pending_failover_ref: nil
    }

    {:reply, result, new_state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      last_state: state.last_state,
      failover_triggered_at: state.failover_triggered_at,
      pending_failover: state.pending_failover_ref != nil,
      domains: state.domains,
      provider: state.provider,
      cached_public_ip: state.public_ip_cache
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call(:check_ip_change, _from, state) do
    # Get current public IP
    case fetch_public_ip() do
      {:ok, current_ip} ->
        # Get cached IP (if any)
        cached_ip =
          case state.public_ip_cache do
            {ip, _timestamp} -> ip
            _ -> nil
          end

        if current_ip != cached_ip do
          Logger.info(
            "Public IP changed: #{cached_ip || "unknown"} → #{current_ip}, updating DNS"
          )

          # Perform DNS update
          {_result, updated_state} = perform_dns_update(state)

          {:reply, {:ok, :updated, current_ip}, updated_state}
        else
          Logger.debug("Public IP unchanged: #{current_ip}")
          {:reply, {:ok, :no_change, current_ip}, state}
        end

      {:error, reason} ->
        Logger.error("Failed to check IP change: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  ## Private Functions

  defp perform_health_check(state) do
    cluster_healthy = ElixirGateway.Cluster.Manager.cluster_healthy?()

    cond do
      # Cluster was healthy, now unhealthy - schedule delayed failover
      state.last_state == :healthy and not cluster_healthy ->
        Logger.warning(
          "Cluster became unhealthy, scheduling DNS failover in #{state.failover_timeout}ms"
        )

        # Schedule failover asynchronously to avoid blocking the GenServer
        ref = Process.send_after(self(), :execute_failover, state.failover_timeout)
        %{state | last_state: :failing, pending_failover_ref: ref}

      # Cluster was unhealthy/failing, now healthy - cancel pending failover
      state.last_state in [:failed, :failing] and cluster_healthy ->
        Logger.info("Cluster recovered, peers are healthy again")
        # Cancel pending failover if it exists
        if state.pending_failover_ref do
          Process.cancel_timer(state.pending_failover_ref)
          Logger.info("Cancelled pending DNS failover (cluster recovered)")
        end

        %{state | last_state: :healthy, pending_failover_ref: nil}

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

  defp perform_dns_update(state) do
    case get_public_ip(state) do
      {:ok, ip} ->
        Logger.info("Updating DNS records to point to #{ip}")

        # Update IP cache with current timestamp
        now = System.monotonic_time(:millisecond)
        updated_state = %{state | public_ip_cache: {ip, now}}

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
          {{:ok, ip}, updated_state}
        else
          Logger.error("Some DNS updates failed: #{inspect(failures)}")
          {{:error, :partial_failure}, updated_state}
        end

      {:error, reason} ->
        Logger.error("Failed to get public IP: #{inspect(reason)}")
        {{:error, reason}, state}
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
    # Fetch fresh public IP from external service
    Namecheap.get_public_ip()
  end

  defp schedule_health_check(interval) do
    Process.send_after(self(), :check_health, interval)
  end

  def is_primary?, do: ElixirGateway.Cluster.Role.primary?()
end
