defmodule ElixirGateway.Cluster.Role do
  @moduledoc """
  Single source of truth for primary/secondary role detection.

  Resolution order:
  1. IS_PRIMARY env var — explicit override ("true" / "false")
  2. CLUSTER_PEERS configured — primary if non-empty
  3. DNS failover configured and enabled — primary if domains present
  4. Default — primary (single-node mode, no clustering configured)
  """

  @spec primary?() :: boolean()
  def primary? do
    case System.get_env("IS_PRIMARY") do
      "true" -> true
      "false" -> false
      _ -> auto_detect?()
    end
  end

  defp auto_detect? do
    cluster_config = Application.get_env(:elixirgateway, :cluster, [])
    peers_configured?(cluster_config) or dns_failover_configured?(cluster_config)
  end

  defp peers_configured?(cluster_config) do
    Keyword.get(cluster_config, :peers, []) != []
  end

  defp dns_failover_configured?(cluster_config) do
    dns_config = Keyword.get(cluster_config, :dns_failover, [])
    Keyword.get(dns_config, :domains, []) != [] and Keyword.get(dns_config, :enabled, false)
  end
end
