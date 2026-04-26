defmodule ElixirGatewayWeb.AdminController do
  use ElixirGatewayWeb, :controller
  use ElixirGateway.Cluster.RPC

  @impl ElixirGateway.Cluster.RPC
  def handle_rpc({:trigger_failover}) do
    case Process.whereis(ElixirGateway.Cluster.DNSFailover) do
      nil -> {:error, "DNS failover not configured on this node"}
      _pid -> ElixirGateway.Cluster.DNSFailover.trigger_failover()
    end
  end

  def index(conn, _params) do
    conn
    |> put_layout(false)
    |> render(:index)
  end

  def status(conn, _params) do
    json(conn, build_status())
  end

  def trigger_failover(conn, params) do
    target_str = params["node"]
    local = to_string(node())

    result =
      if is_nil(target_str) or target_str == local do
        handle_rpc({:trigger_failover})
      else
        case ElixirGateway.Cluster.Manager.transform_peer_address(target_str) do
          {:ok, target_node} -> rpc_call(target_node, {:trigger_failover})
          {:error, _} -> {:error, "Invalid node format: #{target_str}"}
        end
      end

    case result do
      {:ok, ip} when is_binary(ip) -> json(conn, %{ok: true, ip: ip})
      {:ok, :not_primary} -> json(conn, %{ok: false, error: "Node is not a primary"})
      {:error, reason} -> conn |> put_status(422) |> json(%{ok: false, error: inspect(reason)})
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
          local_node: to_string(node()),
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
