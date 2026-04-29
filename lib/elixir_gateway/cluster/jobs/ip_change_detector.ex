defmodule ElixirGateway.Cluster.Jobs.IPChangeDetector do
  @moduledoc """
  Periodic job that detects public IP address changes and updates DNS accordingly.

  This job runs on a schedule (default: every 5 minutes, like ddclient) and:
  1. Checks if this node should manage DNS (primary node or covering for failed primary)
  2. Fetches the current public IP address
  3. Compares it to the last known IP
  4. Triggers DNS update if the IP has changed

  Only runs when:
  - Clustering is enabled
  - DNS failover is enabled
  - This is the primary node (has DDNS_DOMAINS configured)
  """

  require Logger

  alias ElixirGateway.Cluster.DNSFailover

  @doc """
  Main job entry point called by Quantum scheduler.
  """
  def check_ip_change do
    if should_check_ip?() do
      Logger.debug("Running periodic IP change detection")
      DNSFailover.check_ip_change()
    end
  end

  ## Private Functions

  defp should_check_ip? do
    cluster_config = Application.get_env(:elixirgateway, :cluster, [])
    cluster_enabled = Keyword.get(cluster_config, :enabled, false)

    dns_config = Keyword.get(cluster_config, :dns_failover, [])
    dns_enabled = Keyword.get(dns_config, :enabled, false)
    domains = Keyword.get(dns_config, :domains, [])

    # Base requirements
    base_check = cluster_enabled and dns_enabled and domains != []

    # Role-based logic:
    # - Primary nodes: Always check IP (they manage DNS)
    # - Secondary nodes: Only check IP when cluster is unhealthy (failover scenario)
    cond do
      not base_check ->
        false

      is_primary?() ->
        # Primary node: always check IP changes
        true

      true ->
        # Secondary node: only check IP when cluster is unhealthy (primary is down)
        not ElixirGateway.Cluster.Manager.cluster_healthy?()
    end
  end

  defp is_primary?, do: ElixirGateway.Cluster.Role.primary?()
end
