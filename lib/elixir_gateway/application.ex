defmodule ElixirGateway.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    ElixirGateway.ConfigLoader.load()

    # Filter out notice level logs (typically OTP internals like syn)
    filter_fn = fn log_event, _extra ->
      case log_event do
        # Block all notice level logs
        %{level: :notice} ->
          :stop

        # Allow everything else
        _ ->
          :ignore
      end
    end

    # Add filter at both primary and handler level
    :logger.add_primary_filter(:filter_notice_logs, {filter_fn, []})
    :logger.add_handler_filter(:default, :filter_notice_logs, {filter_fn, []})

    # Attach JSON log handler if a path is configured (for Grafana Alloy ingestion)
    case Application.get_env(:elixirgateway, :json_logging) do
      [enabled: true, path: path] -> ElixirGateway.JsonLogHandler.attach(path)
      _ -> :ok
    end

    # Optionally include cluster supervisor (excluded in test mode where tests manage it manually)
    cluster_supervisor =
      if Application.get_env(:elixirgateway, :start_cluster_supervisor, true) do
        [{ElixirGateway.Cluster.Supervisor, []}]
      else
        []
      end

    children =
      [
        ElixirGateway.PromEx,
        ElixirGatewayWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:elixirgateway, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: ElixirGateway.PubSub},
        # Start Finch for HTTP client
        {Finch, name: ElixirGateway.Finch},
        ElixirGateway.RateLimit,
        # Start WebSocket connection pool
        ElixirGatewayWeb.WebSocketConnectionPool
      ] ++
        cluster_supervisor ++
        [
          # Start scheduler for periodic tasks (IP change detection, etc.)
          ElixirGateway.Scheduler,
          # Load TLS certs into ETS before the endpoint starts accepting connections
          ElixirGateway.CertStore,
          # Task supervisor for certbot subprocesses (isolates crashes from CertbotRunner)
          {Task.Supervisor, name: ElixirGateway.CertbotRunner.TaskSupervisor},
          # Serial queue for certbot invocations (certbot lock file prevents concurrency)
          ElixirGateway.CertbotRunner,
          # Start to serve requests, typically the last entry
          ElixirGatewayWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ElixirGateway.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ElixirGatewayWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
