defmodule ElixirGateway.PromEx.Plugins.Gateway do
  @moduledoc """
  Custom PromEx plugin for gateway-specific metrics.
  """

  use PromEx.Plugin

  @impl true
  def polling_metrics(opts) do
    poll_rate = Keyword.get(opts, :poll_rate, 5_000)

    [
      # Active connections metric
      gateway_connections_total(poll_rate),

      # Rate limiting metrics
      rate_limit_metrics(poll_rate),

      # Cluster health metrics
      cluster_health_metrics(poll_rate),

      # DNS failover metrics
      dns_failover_metrics(poll_rate),

      # Session registry metrics
      session_registry_metrics(poll_rate)
    ]
  end

  @impl true
  def event_metrics(_opts) do
    [
      # Request metrics
      gateway_request_metrics(),

      # Response time metrics
      gateway_response_time_metrics()
    ]
  end

  defp gateway_connections_total(poll_rate) do
    Polling.build(
      :gateway_connections_total,
      poll_rate,
      {__MODULE__, :execute_connections_total, []},
      [
        last_value(
          [:elixirgateway, :connections, :total],
          event_name: [:elixirgateway, :connections, :total],
          description: "Total number of active connections",
          measurement: :count
        )
      ]
    )
  end

  defp rate_limit_metrics(poll_rate) do
    Polling.build(
      :gateway_rate_limits,
      poll_rate,
      {__MODULE__, :execute_rate_limits, []},
      [
        last_value(
          [:elixirgateway, :rate_limit, :violations],
          event_name: [:elixirgateway, :rate_limit, :violations],
          description: "Number of rate limit violations",
          measurement: :count,
          tags: [:user_type]
        )
      ]
    )
  end

  defp cluster_health_metrics(poll_rate) do
    Polling.build(
      :cluster_health_metrics,
      poll_rate,
      {__MODULE__, :execute_cluster_health, []},
      [
        last_value(
          [:elixirgateway, :cluster, :peers, :connected],
          event_name: [:elixirgateway, :cluster, :peers, :connected],
          description: "Number of currently connected peers",
          measurement: :count
        ),
        last_value(
          [:elixirgateway, :cluster, :peers, :total],
          event_name: [:elixirgateway, :cluster, :peers, :total],
          description: "Total number of configured peers",
          measurement: :count
        ),
        last_value(
          [:elixirgateway, :cluster, :healthy],
          event_name: [:elixirgateway, :cluster, :healthy],
          description: "Cluster health status (1=healthy, 0=unhealthy)",
          measurement: :status
        ),
        last_value(
          [:elixirgateway, :cluster, :peer, :health],
          event_name: [:elixirgateway, :cluster, :peer, :health],
          description: "Individual peer health status (1=healthy, 0=disconnected)",
          measurement: :status,
          tags: [:peer]
        )
      ]
    )
  end

  defp dns_failover_metrics(poll_rate) do
    Polling.build(
      :dns_failover_metrics,
      poll_rate,
      {__MODULE__, :execute_dns_failover, []},
      [
        last_value(
          [:elixirgateway, :dns_failover, :state],
          event_name: [:elixirgateway, :dns_failover, :state],
          description: "DNS failover state (0=unknown, 1=healthy, 2=failing, 3=failed)",
          measurement: :state
        ),
        last_value(
          [:elixirgateway, :dns_failover, :pending],
          event_name: [:elixirgateway, :dns_failover, :pending],
          description: "Pending failover status (1=pending, 0=not pending)",
          measurement: :status
        ),
        last_value(
          [:elixirgateway, :dns_failover, :time_since_last],
          event_name: [:elixirgateway, :dns_failover, :time_since_last],
          description: "Time in milliseconds since last failover (0 if never triggered)",
          measurement: :duration
        )
      ]
    )
  end

  defp session_registry_metrics(poll_rate) do
    Polling.build(
      :session_registry_metrics,
      poll_rate,
      {__MODULE__, :execute_session_registry, []},
      [
        last_value(
          [:elixirgateway, :session_registry, :active_sessions],
          event_name: [:elixirgateway, :session_registry, :active_sessions],
          description: "Number of active sticky sessions in the registry",
          measurement: :count
        )
      ]
    )
  end

  defp gateway_request_metrics do
    Event.build(
      :gateway_request_metrics,
      [
        counter(
          [:elixirgateway, :request, :total],
          event_name: [:elixirgateway, :request, :complete],
          description: "Total number of requests processed",
          tags: [:method, :status, :target_service]
        ),
        distribution(
          [:elixirgateway, :request, :duration, :milliseconds],
          event_name: [:elixirgateway, :request, :complete],
          description: "Request duration in milliseconds",
          measurement: :duration,
          unit: {:native, :millisecond},
          tags: [:method, :status, :target_service],
          reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000]]
        )
      ]
    )
  end

  defp gateway_response_time_metrics do
    Event.build(
      :gateway_response_time_metrics,
      [
        distribution(
          [:elixirgateway, :response_time, :seconds],
          event_name: [:elixirgateway, :request, :complete],
          description: "Response time distribution",
          measurement: :duration,
          unit: {:native, :second},
          tags: [:method, :target_service],
          reporter_options: [buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]]
        )
      ]
    )
  end

  # Callback functions for polling metrics
  def execute_connections_total do
    # This would normally query the actual connection count
    # For now, return a static value
    :telemetry.execute([:elixirgateway, :connections, :total], %{count: 0})
  end

  def execute_rate_limits do
    # This would normally query rate limit violations from Hammer
    # For now, return static values
    :telemetry.execute([:elixirgateway, :rate_limit, :violations], %{count: 0}, %{
      user_type: "anonymous"
    })
  end

  def execute_cluster_health do
    # Get cluster health information from the manager
    case Process.whereis(ElixirGateway.Cluster.Manager) do
      nil ->
        # Cluster manager not running - emit zero metrics
        :telemetry.execute([:elixirgateway, :cluster, :peers, :connected], %{count: 0})
        :telemetry.execute([:elixirgateway, :cluster, :peers, :total], %{count: 0})
        :telemetry.execute([:elixirgateway, :cluster, :healthy], %{status: 0})

      _pid ->
        # Get connected peers count
        connected_peers = ElixirGateway.Cluster.Manager.connected_peers()
        connected_count = length(connected_peers)

        # Get peer health status
        peer_health = ElixirGateway.Cluster.Manager.peer_health()
        total_peers = map_size(peer_health)

        # Get cluster health
        cluster_healthy = ElixirGateway.Cluster.Manager.cluster_healthy?()

        # Emit cluster-wide metrics
        :telemetry.execute([:elixirgateway, :cluster, :peers, :connected], %{
          count: connected_count
        })

        :telemetry.execute([:elixirgateway, :cluster, :peers, :total], %{count: total_peers})

        :telemetry.execute([:elixirgateway, :cluster, :healthy], %{
          status: if(cluster_healthy, do: 1, else: 0)
        })

        # Emit individual peer health metrics
        Enum.each(peer_health, fn {peer, status} ->
          health_status = if status == :healthy, do: 1, else: 0

          :telemetry.execute(
            [:elixirgateway, :cluster, :peer, :health],
            %{status: health_status},
            %{peer: peer}
          )
        end)
    end
  end

  def execute_dns_failover do
    # Get DNS failover status
    case Process.whereis(ElixirGateway.Cluster.DNSFailover) do
      nil ->
        # DNS failover not running - emit default metrics
        :telemetry.execute([:elixirgateway, :dns_failover, :state], %{state: 0})
        :telemetry.execute([:elixirgateway, :dns_failover, :pending], %{status: 0})
        :telemetry.execute([:elixirgateway, :dns_failover, :time_since_last], %{duration: 0})

      _pid ->
        status = ElixirGateway.Cluster.DNSFailover.status()

        # Convert state to numeric value for Prometheus
        state_value =
          case status.last_state do
            :unknown -> 0
            :healthy -> 1
            :failing -> 2
            :failed -> 3
          end

        # Calculate time since last failover
        time_since_last =
          if status.failover_triggered_at do
            System.monotonic_time(:millisecond) - status.failover_triggered_at
          else
            0
          end

        # Emit metrics
        :telemetry.execute([:elixirgateway, :dns_failover, :state], %{state: state_value})

        :telemetry.execute([:elixirgateway, :dns_failover, :pending], %{
          status: if(status.pending_failover, do: 1, else: 0)
        })

        :telemetry.execute([:elixirgateway, :dns_failover, :time_since_last], %{
          duration: time_since_last
        })
    end
  end

  def execute_session_registry do
    # Get active session count from ConnectionRegistry
    session_count = ElixirGateway.Cluster.ConnectionRegistry.session_count()

    :telemetry.execute([:elixirgateway, :session_registry, :active_sessions], %{
      count: session_count
    })
  end
end
