defmodule ElixirGateway.Cluster.Supervisor do
  @moduledoc """
  Top-level supervisor for clustering functionality.

  This supervisor is a no-op if clustering is disabled (default).
  When enabled, it supervises all cluster-related processes.
  """

  use Supervisor
  require Logger

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    config = Application.get_env(:elixirgateway, :cluster, [])
    enabled = Keyword.get(config, :enabled, false)

    if enabled do
      Logger.info("Starting ElixirGateway clustering")
      start_cluster_children(config)
    else
      Logger.debug("ElixirGateway clustering disabled")
      # No-op: return empty supervision tree
      Supervisor.init([], strategy: :one_for_one)
    end
  end

  defp start_cluster_children(config) do
    validate_config!(config)

    children =
      [
        # Cluster manager handles Partisan setup and peer connections
        {ElixirGateway.Cluster.Manager, config},

        # Connection registry for distributed sticky sessions
        {ElixirGateway.Cluster.ConnectionRegistry, []},

        # DNS failover monitor (only if DNS failover is enabled)
        dns_failover_child(config)
      ]
      |> Enum.reject(&is_nil/1)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp dns_failover_child(config) do
    dns_config = Keyword.get(config, :dns_failover, [])

    if Keyword.get(dns_config, :enabled, false) do
      {ElixirGateway.Cluster.DNSFailover, dns_config}
    end
  end

  defp validate_config!(config) do
    # Validate secret and node_name are present
    required_fields = [:secret, :node_name]

    Enum.each(required_fields, fn field ->
      value = Keyword.get(config, field)

      if is_nil(value) or (is_binary(value) and String.trim(value) == "") do
        raise ArgumentError, """
        Clustering is enabled but required field :#{field} is missing or empty.

        Please configure in config/runtime.exs:

        config :elixirgateway, :cluster,
          enabled: true,
          secret: System.get_env("CLUSTER_SECRET"),
          node_name: System.get_env("NODE_NAME"),
          peers: ["gateway-b.example.com:9100"]  # Can be empty for asymmetric setup
        """
      end
    end)

    # Peers must be a list (can be empty for asymmetric cloud setup)
    peers = Keyword.get(config, :peers)
    unless is_list(peers) do
      raise ArgumentError, """
      Clustering is enabled but :peers must be a list.
      Use an empty list [] for nodes that only accept connections (e.g., cloud servers).
      """
    end

    :ok
  end
end
