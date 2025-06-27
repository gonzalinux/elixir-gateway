defmodule Exgateway.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Exgateway.PromEx,
      ExgatewayWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:exgateway, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Exgateway.PubSub},
      # Start Finch for HTTP client
      {Finch, name: Exgateway.Finch},
      # Start to serve requests, typically the last entry
      ExgatewayWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Exgateway.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ExgatewayWeb.Endpoint.config_change(changed, removed)
    :ok
  end

end
