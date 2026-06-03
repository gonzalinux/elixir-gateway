defmodule ElixirGatewayWeb.HealthController do
  use ElixirGatewayWeb, :controller

  @moduledoc """
  Health check controller for load balancers and monitoring systems.
  """

  def check(conn, _params) do
    {uptime_total, _uptime_since_last} = :erlang.statistics(:runtime)
    # Basic health checks
    status = %{
      status: "healthy",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      version: Application.spec(:elixirgateway, :vsn) |> to_string(),
      uptime: uptime_total,
      checks: perform_health_checks()
    }

    case status.checks.overall do
      "healthy" ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(status))

      "degraded" ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(status))

      "unhealthy" ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(503, Jason.encode!(status))
    end
  end

  def ready(conn, _params) do
    # Kubernetes readiness probe - check if app is ready to serve traffic
    checks = perform_readiness_checks()

    status = %{
      status: if(checks.ready, do: "ready", else: "not_ready"),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      checks: checks
    }

    status_code = if checks.ready, do: 200, else: 503

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status_code, Jason.encode!(status))
  end

  def live(conn, _params) do
    # Kubernetes liveness probe - check if app is alive
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      200,
      Jason.encode!(%{
        status: "alive",
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      })
    )
  end

  defp perform_health_checks do
    checks = %{
      database: check_database(),
      websocket_pool: check_websocket_pool(),
      rate_limiter: check_rate_limiter(),
      configuration: check_configuration()
    }

    overall_status = determine_overall_status(checks)

    Map.put(checks, :overall, overall_status)
  end

  defp perform_readiness_checks do
    # Check if application is ready to serve traffic
    config_valid = check_configuration().status == "healthy"
    services_configured = check_gateway_services()

    %{
      ready: config_valid and services_configured,
      configuration: config_valid,
      services: services_configured
    }
  end

  defp check_database do
    # Check if ETS tables are available (used by Hammer for rate limiting)
    try do
      case :ets.info(:hammer_ets_buckets) do
        :undefined ->
          %{status: "unhealthy", message: "Rate limiting ETS table not found"}

        _ ->
          %{status: "healthy", message: "ETS tables available"}
      end
    rescue
      _ ->
        %{status: "degraded", message: "ETS table check failed"}
    end
  end

  defp check_websocket_pool do
    # Check WebSocket connection pool status
    try do
      case ElixirGatewayWeb.WebSocketConnectionPool.get_stats() do
        stats when is_map(stats) ->
          %{
            status: "healthy",
            message: "WebSocket pool available",
            stats: %{
              total_connections: stats.total_connections,
              total_hosts: stats.total_hosts
            }
          }

        _ ->
          %{status: "degraded", message: "WebSocket pool statistics unavailable"}
      end
    rescue
      _ ->
        %{status: "unhealthy", message: "WebSocket pool unavailable"}
    end
  end

  defp check_rate_limiter do
    # Test rate limiter functionality
    try do
      case ElixirGateway.RateLimit.hit("health_check", 60_000, 1) do
        {:allow, _count} ->
          %{status: "healthy", message: "Rate limiter functional"}

        {:deny, _retry_after} ->
          %{status: "healthy", message: "Rate limiter functional (denied as expected)"}

        _ ->
          %{status: "degraded", message: "Rate limiter response unexpected"}
      end
    rescue
      _ ->
        %{status: "unhealthy", message: "Rate limiter unavailable"}
    end
  end

  defp check_configuration do
    # Check if gateway configuration is valid
    try do
      services = Application.get_env(:elixirgateway, :gateway)[:services]

      if is_map(services) and map_size(services) > 0 do
        %{status: "healthy", message: "Gateway configuration valid"}
      else
        %{status: "unhealthy", message: "Gateway services not configured"}
      end
    rescue
      _ ->
        %{status: "unhealthy", message: "Configuration check failed"}
    end
  end

  defp check_gateway_services do
    # Check if at least one gateway service is configured
    services = Application.get_env(:elixirgateway, :gateway)[:services]
    is_map(services) and map_size(services) > 0
  end

  defp determine_overall_status(checks) do
    statuses = Map.values(checks) |> Enum.map(& &1.status)

    cond do
      Enum.any?(statuses, &(&1 == "unhealthy")) ->
        "unhealthy"

      Enum.any?(statuses, &(&1 == "degraded")) ->
        "degraded"

      true ->
        "healthy"
    end
  end
end
