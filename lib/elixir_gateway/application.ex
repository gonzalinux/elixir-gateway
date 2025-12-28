defmodule ElixirGateway.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
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
    # :logger.add_primary_filter(:filter_notice_logs, {filter_fn, []})
    # :logger.add_handler_filter(:default, :filter_notice_logs, {filter_fn, []})

    children = [
      ElixirGateway.PromEx,
      ElixirGatewayWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:elixirgateway, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ElixirGateway.PubSub},
      # Start Finch for HTTP client
      {Finch, name: ElixirGateway.Finch},
      # Start WebSocket connection pool
      ElixirGatewayWeb.WebSocketConnectionPool,
      # Start cluster supervisor (no-op if clustering disabled)
      {ElixirGateway.Cluster.Supervisor, []},
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
