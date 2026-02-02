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
  - Primary + Cloud1: 70 + 30 = 100 points → 70%/30% distribution
  - Primary + Cloud1 + Cloud2: 70 + 30 + 15 = 115 points → 60.9%/26.1%/13.0% distribution

  ## Threshold Behavior

  When traffic is below the minimum threshold (default: 20 requests/minute), all
  requests are processed locally on the primary node to avoid RPC overhead. Once
  traffic exceeds the threshold, weighted distribution activates.

  ## Dynamic Adjustment

  When nodes connect or disconnect, weights automatically recalculate and load
  redistributes across the available nodes.
  """

  use GenServer
  require Logger

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
      if below_traffic_threshold?() do
        Logger.debug("Traffic below threshold, routing to local node")
        node()
      else
        node = weighted_random_node()
        Logger.debug("Selected node via weighted distribution: #{node}")
        node
      end
    else
      node()
    end
  end

  @doc """
  Performs weighted random selection across active nodes.

  Example: Primary=70, Cloud1=30 (total=100)
  - Random value 0-69 → Primary
  - Random value 70-99 → Cloud1
  """
  def weighted_random_node do
    weights = get_active_node_weights()

    if map_size(weights) == 0 do
      # No weights configured or no nodes active
      node()
    else
      total_weight = weights |> Map.values() |> Enum.sum()

      if total_weight == 0 do
        node()
      else
        random_value = :rand.uniform(total_weight)
        select_by_cumulative_weight(weights, random_value)
      end
    end
  end

  @doc """
  Returns a map of currently active (connected) nodes to their weights.

  Only includes nodes that are currently connected to the cluster.
  Always includes the current node (primary).
  """
  def get_active_node_weights do
    config = load_distribution_config()

    if config[:enabled] do
      primary_weight = config[:primary_weight] || 70
      secondary_weights = config[:secondary_weights] || %{}

      # Get list of connected nodes
      connected_nodes = [node() | Node.list()]

      # Start with primary node
      weights = %{node() => primary_weight}

      # Add secondary nodes that are connected
      Enum.reduce(secondary_weights, weights, fn {node_name, weight}, acc ->
        if node_name in connected_nodes do
          Map.put(acc, node_name, weight)
        else
          acc
        end
      end)
    else
      %{node() => 100}
    end
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
  """
  def enabled? do
    config = load_distribution_config()
    config[:enabled] == true
  end

  @doc """
  Returns the total weight of all currently active nodes.
  Used for metrics.
  """
  def get_total_active_weight do
    get_active_node_weights()
    |> Map.values()
    |> Enum.sum()
  end

  @doc """
  Returns node weights formatted for PromEx metrics.
  Returns a list of tuples: [{node_name, weight}, ...]
  """
  def get_node_weights_for_metrics do
    get_active_node_weights()
    |> Enum.map(fn {node_name, weight} ->
      {[node_name: to_string(node_name)], weight}
    end)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    if enabled?() do
      # Create ETS table for request tracking
      :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])

      # Schedule cleanup of old request data
      schedule_cleanup()

      Logger.info(
        "LoadDistributor started with configuration: #{inspect(load_distribution_config())}"
      )

      {:ok, %{}}
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
  def handle_info(:cleanup, state) do
    cleanup_old_requests()
    schedule_cleanup()
    {:noreply, state}
  end

  # Private Functions

  defp select_by_cumulative_weight(weights, random_value) do
    weights
    |> Enum.sort_by(fn {_node, _weight} -> :rand.uniform() end)
    |> Enum.reduce_while({0, node()}, fn {node_name, weight}, {cumulative, _} ->
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
    cluster_config = Application.get_env(:elixirgateway, :cluster, [])
    cluster_config[:load_distribution] || [enabled: false]
  end
end
