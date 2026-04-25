defmodule ElixirGatewayWeb.AdminController do
  use ElixirGatewayWeb, :controller

  def index(conn, _params) do
    conn
    |> put_layout(false)
    |> render(:index)
  end

  def status(conn, _params) do
    json(conn, build_status())
  end

  def trigger_failover(conn, _params) do
    case Process.whereis(ElixirGateway.Cluster.DNSFailover) do
      nil ->
        conn
        |> put_status(422)
        |> json(%{ok: false, error: "DNS failover is not configured on this node"})

      _pid ->
        case ElixirGateway.Cluster.DNSFailover.trigger_failover() do
          {:ok, ip} -> json(conn, %{ok: true, ip: ip})
          {:error, reason} -> json(conn, %{ok: false, error: inspect(reason)})
        end
    end
  end

  # ── Status helpers ───────────────────────────────────────────────────────────

  defp build_status do
    %{
      node: node() |> to_string(),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      cluster: get_cluster_status(),
      dns_failover: get_dns_failover_status(),
      load_distribution: get_load_distribution_status()
    }
  end

  defp get_cluster_status do
    case Process.whereis(ElixirGateway.Cluster.Manager) do
      nil ->
        %{enabled: false}

      _pid ->
        peer_health =
          ElixirGateway.Cluster.Manager.peer_health()
          |> Map.new(fn {k, v} -> {k, to_string(v)} end)

        %{
          enabled: true,
          healthy: ElixirGateway.Cluster.Manager.cluster_healthy?(),
          peer_health: peer_health,
          connected_peers:
            ElixirGateway.Cluster.Manager.connected_peers() |> Enum.map(&to_string/1)
        }
    end
  end

  defp get_dns_failover_status do
    case Process.whereis(ElixirGateway.Cluster.DNSFailover) do
      nil ->
        %{enabled: false}

      _pid ->
        s = ElixirGateway.Cluster.DNSFailover.status()

        cached_ip =
          case s.cached_public_ip do
            {ip, _ts} -> ip
            nil -> nil
          end

        domains =
          Enum.map(s.domains, fn d ->
            label = if d.host == "@", do: d.domain, else: "#{d.host}.#{d.domain}"
            label
          end)

        %{
          enabled: true,
          last_state: to_string(s.last_state),
          pending_failover: s.pending_failover,
          domains: domains,
          provider: to_string(s.provider),
          cached_ip: cached_ip
        }
    end
  end

  defp get_load_distribution_status do
    case Process.whereis(ElixirGateway.Cluster.LoadDistributor) do
      nil ->
        %{enabled: false}

      _pid ->
        if ElixirGateway.Cluster.LoadDistributor.enabled?() do
          {total_weight, nodes} =
            ElixirGateway.Cluster.LoadDistributor.get_active_node_weights()

          nodes_str =
            Map.new(nodes, fn {k, v} ->
              {to_string(k), %{weight: v.weight, services: v.services}}
            end)

          %{
            enabled: true,
            below_threshold: ElixirGateway.Cluster.LoadDistributor.below_traffic_threshold?(),
            total_weight: total_weight,
            nodes: nodes_str
          }
        else
          %{enabled: false}
        end
    end
  end
end
