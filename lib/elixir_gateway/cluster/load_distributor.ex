defmodule ElixirGateway.Cluster.LoadDistributor do
  @moduledoc """
  Manages weight-based load distribution across cluster nodes.

  This module implements active-active load distribution where the primary node
  (home server) receives all DNS traffic and intelligently distributes load across
  all connected nodes based on their configured weights, while maintaining session
  affinity.

  ## Weight-Based Distribution

  Each node is assigned a capacity weight (points). Load is distributed proportionally:

  - Primary (home) alone: 70 points = 100% distribution
  - Primary + secondary1: 70 + 30 = 100 points → 70%/30% distribution
  - Primary + secondary1 + secondary2: 70 + 30 + 15 = 115 points → 60.9%/26.1%/13.0% distribution

  ## Threshold Behavior

  When traffic is below the minimum threshold (default: 20 requests/minute), all
  requests are processed locally on the primary node to avoid RPC overhead. Once
  traffic exceeds the threshold, weighted distribution activates.

  ## Dynamic Adjustment

  When nodes connect or disconnect, weights automatically recalculate and load
  redistributes across the available nodes.
  """
  use ElixirGateway.Cluster.RPC
  use GenServer
  require Logger

  alias ElixirGateway.Cluster.Config

  @typedoc "Node weights shared when connected"
  @type node_weights :: %{
          weight: integer(),
          node: node(),
          services: [String.t()]
        }

  @table_name :elixirgateway_load_distributor
  @request_window_seconds 60
  @cleanup_interval_ms 10_000

  # Client API

  @doc """
  Starts the LoadDistributor GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Selects which node should handle a new session based on current load and weights.

  Returns the node atom. If traffic is below threshold, returns the current node.
  Otherwise, performs weighted random selection across all active nodes.
  """
  def select_node_for_new_session do
    if enabled?() do
      {total_weight, weights} = get_active_node_weights()

      if below_traffic_threshold?() do
        Logger.info(
          "Load distributor: Traffic below threshold, routing to local node (active nodes: #{map_size(weights)}, total weight: #{total_weight})"
        )

        node()
      else
        selected_node = weighted_random_node()
        node_weight = get_in(weights, [selected_node, :weight]) || 0

        percentage =
          if total_weight > 0, do: Float.round(node_weight / total_weight * 100, 1), else: 0

        Logger.info(
          "Load distributor: Selected #{selected_node} for new session (weight: #{node_weight}/#{total_weight} = #{percentage}%)"
        )

        selected_node
      end
    else
      node()
    end
  end

  @doc """
  Performs weighted random selection across active nodes.

  Example: Primary=70, secondary1=30 (total=100)
  - Random value 0-69 → Primary
  - Random value 70-99 → secondary1
  """
  def weighted_random_node do
    {total_weight, weights} = get_active_node_weights()

    cond do
      map_size(weights) == 0 ->
        # No weights configured or no nodes active
        node()

      total_weight == 0 ->
        node()

      true ->
        random_value = :rand.uniform(total_weight)
        select_by_cumulative_weight(weights, random_value)
    end
  end

  @doc """
  Returns a map of currently active (connected) nodes to their weights.

  Only includes nodes that are currently connected to the cluster.
  Always includes the current node (primary).
  """
  def get_active_node_weights do
    GenServer.call(__MODULE__, :get_weights)
  end

  @doc """
  Records a request for the given node for threshold tracking.

  Uses a sliding window approach with 1-second buckets for accurate
  request counting over the last 60 seconds.
  """
  def record_request(target_node) do
    if enabled?() do
      GenServer.cast(__MODULE__, {:record_request, target_node, System.monotonic_time(:second)})
    end
  end

  @doc """
  Returns true if total requests in the last 60 seconds is below the minimum threshold.

  Default threshold is 20 requests/minute.
  """
  def below_traffic_threshold? do
    if enabled?() do
      config = load_distribution_config()
      min_threshold = config[:min_requests_threshold] || 20
      window_seconds = config[:window_seconds] || @request_window_seconds

      current_time = System.monotonic_time(:second)
      cutoff_time = current_time - window_seconds

      # Count requests in the window
      total_requests =
        :ets.foldl(
          fn
            {{:request, _node, timestamp}, count}, acc when timestamp >= cutoff_time ->
              acc + count

            _, acc ->
              acc
          end,
          0,
          @table_name
        )

      total_requests < min_threshold
    else
      true
    end
  end

  @doc """
  Returns true if load distribution is enabled in configuration.

  Delegates to `ElixirGateway.Cluster.Config.load_distribution_enabled?/0`
  """
  defdelegate enabled?, to: Config, as: :load_distribution_enabled?

  @doc """
  Returns the total weight of all currently active nodes.
  Used for metrics.
  """
  def get_total_active_weight do
    {total_weight, _} = get_active_node_weights()
    total_weight
  end

  @doc """
  Returns node weights formatted for PromEx metrics.
  Returns a list of tuples: [{node_name, weight}, ...]
  """
  def get_node_weights_for_metrics do
    {_total, nodes} = get_active_node_weights()

    nodes
    |> Enum.map(fn {_node_key, %{node: node_name, weight: weight}} ->
      {[node_name: to_string(node_name)], weight}
    end)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    if enabled?() do
      # Create ETS table for request tracking
      :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])
      :net_kernel.monitor_nodes(true, node_type: :all)
      # Schedule cleanup of old request data
      schedule_cleanup()

      config = load_distribution_config()
      weight = config[:node_weight] || 100
      min_threshold = config[:min_requests_threshold] || 20
      services = get_local_service_keys()

      Logger.info(
        "Load distributor: ENABLED - This node weight: #{weight}, min threshold: #{min_threshold} req/min, initial total weight: #{weight}"
      )

      {:ok,
       %{
         node_weight: weight,
         total_weight: weight,
         nodes: %{node() => %{node: node(), weight: weight, services: services}}
       }}
    else
      Logger.info("LoadDistributor disabled")
      {:ok, %{}, :hibernate}
    end
  end

  @impl true
  def handle_cast({:record_request, target_node, timestamp}, state) do
    key = {:request, target_node, timestamp}

    case :ets.lookup(@table_name, key) do
      [{^key, count}] ->
        :ets.insert(@table_name, {key, count + 1})

      [] ->
        :ets.insert(@table_name, {key, 1})
    end

    # Emit telemetry event
    :telemetry.execute(
      [:elixirgateway, :load_distribution, :request],
      %{count: 1},
      %{target_node: target_node}
    )

    {:noreply, state}
  end

  @impl true
  def handle_cast({:remote_node_weight, new_weight}, state) do
    elem = Map.get(state.nodes, new_weight.node)
    old_total = state.total_weight

    state =
      if elem != nil do
        # Node already exists, subtract old weight
        total_weight = state.total_weight - elem.weight
        %{state | total_weight: total_weight}
      else
        state
      end

    # Preserve services if the peer didn't send them (older node version)
    services = Map.get(new_weight, :services, [])
    node_info = %{node: new_weight.node, weight: new_weight.weight, services: services}

    nodes = Map.put(state.nodes, new_weight.node, node_info)
    new_total = state.total_weight + new_weight.weight
    state = %{state | nodes: nodes, total_weight: new_total}

    Logger.info(
      "Load distributor: Node #{if elem, do: "updated", else: "joined"} #{new_weight.node} (weight: #{new_weight.weight}, services: #{length(services)}), total weight: #{old_total} -> #{new_total}, active nodes: #{map_size(nodes)}"
    )

    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_old_requests()
    schedule_cleanup()
    {:noreply, state}
  end

  @impl true
  def handle_info({:nodeup, peer_node, _info}, state) do
    # Broadcast weight and service keys to peer asynchronously to avoid blocking GenServer
    node_weight = state.node_weight
    services = get_local_service_keys()

    Task.start(fn ->
      case(
        rpc_call(
          peer_node,
          {:remote_node_weight, %{node: node(), weight: node_weight, services: services}}
        )
      ) do
        :ok ->
          Logger.debug("Successfully shared weight with peer #{peer_node}")

        {:error, {:EXIT, {:noproc, _}}} ->
          Logger.info("Load distribution not enabled on peer #{peer_node}, skipping weight share")

        {:error, reason} ->
          Logger.warning("Failed to share weight with peer #{peer_node}: #{inspect(reason)}")

        other ->
          Logger.warning("Unexpected response from peer #{peer_node}: #{inspect(other)}")
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, peer_node, _info}, state) do
    elem = Map.get(state.nodes, peer_node)

    state =
      if elem != nil do
        old_total = state.total_weight
        new_total = state.total_weight - elem.weight
        nodes = Map.delete(state.nodes, peer_node)

        Logger.info(
          "Load distributor: Node disconnected #{peer_node} (weight: #{elem.weight}), total weight: #{old_total} -> #{new_total}, active nodes: #{map_size(nodes)}"
        )

        %{state | total_weight: new_total, nodes: nodes}
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  @doc """
  RPC endpoint called when a node joins the cluster to broadcast its weight.
  """
  @spec handle_rpc({:remote_node_weight, node_weights()}) :: :ok | {:error, term()}
  def handle_rpc({:remote_node_weight, new_weight}) do
    GenServer.cast(__MODULE__, {:remote_node_weight, new_weight})
  end

  @impl true
  def handle_call(:get_weights, _from, state) do
    {:reply, {state.total_weight, state.nodes}, state}
  end

  @impl true
  def handle_call({:node_has_service, node_name, host}, _from, state) do
    result =
      case Map.get(state.nodes, node_name) do
        %{services: services} -> Enum.any?(services, &service_key_matches?(&1, host))
        nil -> false
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:refresh_local_services, _from, state) do
    services = get_local_service_keys()

    nodes =
      Map.update!(state.nodes, node(), fn node_info ->
        %{node_info | services: services}
      end)

    {:reply, :ok, %{state | nodes: nodes}}
  end

  @doc """
  Returns true if the given node has a service configured for the host.

  Uses cached service keys exchanged at node-join time — no RPC call needed.
  Supports exact match, wildcard patterns (`*.example.com`), and `default_any`.
  """
  def node_has_service?(node_name, host) do
    GenServer.call(__MODULE__, {:node_has_service, node_name, host})
  end

  @doc """
  Refreshes the local node's cached service keys from the current application config.

  Useful when gateway services are updated at runtime without a full restart.
  """
  def refresh_local_services do
    GenServer.call(__MODULE__, :refresh_local_services)
  end

  # Private Functions

  defp select_by_cumulative_weight(weights, random_value) do
    weights
    |> Enum.sort_by(fn {node_key, _node_info} -> node_key end)
    |> Enum.reduce_while({0, node()}, fn {_node_key, %{node: node_name, weight: weight}},
                                         {cumulative, _} ->
      new_cumulative = cumulative + weight

      if random_value <= new_cumulative do
        {:halt, {new_cumulative, node_name}}
      else
        {:cont, {new_cumulative, node_name}}
      end
    end)
    |> elem(1)
  end

  defp cleanup_old_requests do
    config = load_distribution_config()
    window_seconds = config[:window_seconds] || @request_window_seconds
    current_time = System.monotonic_time(:second)
    cutoff_time = current_time - window_seconds

    # Delete all request records older than the window
    :ets.select_delete(@table_name, [
      {{{:request, :_, :"$1"}, :_}, [{:<, :"$1", cutoff_time}], [true]}
    ])
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  defp load_distribution_config do
    Config.load_distribution_config()
  end

  defp get_local_service_keys do
    case Application.get_env(:elixirgateway, :gateway)[:services] do
      nil -> []
      services -> Map.keys(services)
    end
  end

  defp service_key_matches?(key, host) do
    cond do
      key == host ->
        true

      key in ["default_any", "default"] ->
        true

      String.starts_with?(key, "*") ->
        suffix = String.slice(key, 1..-1//1)
        String.ends_with?(host, suffix)

      true ->
        false
    end
  end
end
