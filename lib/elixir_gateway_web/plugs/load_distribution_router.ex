defmodule ElixirGatewayWeb.Plugs.LoadDistributionRouter do
  @moduledoc """
  Routes requests to appropriate nodes based on weighted load distribution.

  This plug is inserted between DomainRouter and RequestForwarder in the pipeline.
  It makes intelligent routing decisions:

  1. For existing sessions with affinity: Routes to the assigned node (local or remote)
  2. For new sessions: Uses LoadDistributor to select node based on weights
  3. When clustering disabled: Always routes locally

  The plug assigns `:target_node` to the connection, which is then used by
  RequestForwarder to either process locally or forward via RPC.

  ## Target Node Values

  - `:local` - Process request on this node
  - `{:remote, node_name}` - Forward request to remote node via RPC
  """

  import Plug.Conn
  require Logger

  alias ElixirGateway.Cluster.{Config, ConnectionRegistry, LoadDistributor, ServiceHealth}

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, _opts) do
    if Config.load_distribution_enabled?() do
      route_with_load_distribution(conn)
    else
      # Load distribution disabled, always process locally
      assign(conn, :target_node, :local)
    end
    |> maybe_failover_with_health()
  end

  # Private Functions
  #
  defp maybe_failover_with_health(conn) do
    service_key = conn.assigns[:service_key]
    target = conn.assigns[:target_node]

    destination =
      case target do
        {:remote, remote_node} ->
          case ServiceHealth.healthy?(service_key, remote_node) do
            true ->
              remote_node

            false ->
              get_healthy_node(service_key, [node() | Node.list()])
          end

        :local ->
          case ServiceHealth.healthy?(service_key) do
            true ->
              node()

            false ->
              get_healthy_node(service_key, Node.list())
          end
      end

    represent = get_node_representation(destination)

    if represent != conn.assigns[:target_node] do
      Logger.info(
        "Failing unhealthy host #{service_key} from target #{inspect(target)} to node #{inspect(represent)}"
      )

      assign(conn, :target_node, represent)
    else
      conn
    end
  end

  defp get_healthy_node(_host, []) do
    node()
  end

  defp get_healthy_node(host, [node | nodes]) do
    if ServiceHealth.healthy?(host, node) and LoadDistributor.node_has_service?(node, host) do
      node
    else
      get_healthy_node(host, nodes)
    end
  end

  defp get_node_representation(node) do
    if node == node() do
      :local
    else
      {:remote, node}
    end
  end

  defp route_with_load_distribution(conn) do
    case ConnectionRegistry.get_node(conn) do
      {:remote, remote_node} ->
        # Existing session on a different node - must forward to maintain affinity
        Logger.debug("Existing session found on remote node: #{remote_node}")
        assign(conn, :target_node, {:remote, remote_node})

      :local ->
        # Existing session on this node - process locally
        Logger.debug("Existing session found on local node")
        assign(conn, :target_node, :local)

      :new_session ->
        # New session - select node based on weighted distribution
        handle_new_session(conn)

      :not_clustered ->
        # Clustering not enabled
        assign(conn, :target_node, :local)
    end
  end

  defp handle_new_session(conn) do
    selected_node = LoadDistributor.select_node_for_new_session()
    host = conn.assigns[:original_host]

    cond do
      selected_node == node() ->
        Logger.debug("New session assigned to local node")
        ConnectionRegistry.register_session(conn, node())
        assign(conn, :target_node, :local)

      LoadDistributor.node_has_service?(selected_node, host) ->
        Logger.debug("New session assigned to remote node: #{selected_node}")
        ConnectionRegistry.register_session_on_remote(conn, selected_node)
        assign(conn, :target_node, {:remote, selected_node})

      true ->
        Logger.info(
          "Service #{host} not configured on #{selected_node}, routing to local node instead"
        )

        ConnectionRegistry.register_session(conn, node())
        assign(conn, :target_node, :local)
    end
  end
end
