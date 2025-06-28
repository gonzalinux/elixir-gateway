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
      rate_limit_metrics(poll_rate)
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
    :telemetry.execute([:elixirgateway, :rate_limit, :violations], %{count: 0}, %{user_type: "anonymous"})
  end
end