defmodule ElixirGateway.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ElixirGateway.PromEx,
      ElixirGatewayWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:elixirgateway, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ElixirGateway.PubSub},
      # Start Finch for HTTP client
      {Finch, name: ElixirGateway.Finch},
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
