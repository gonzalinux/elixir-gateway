defmodule ElixirGateway.PromEx do
  @moduledoc """
  PromEx configuration for the API Gateway.
  """
  
  use PromEx, otp_app: :elixirgateway

  alias PromEx.Plugins

  @impl true
  def plugins do
    [
      # Built-in Phoenix and Erlang/Elixir metrics
      Plugins.Application,
      Plugins.Beam,
      {Plugins.Phoenix, router: ElixirGatewayWeb.Router, endpoint: ElixirGatewayWeb.Endpoint},
      
      # Custom gateway metrics
      {ElixirGateway.PromEx.Plugins.Gateway, []}
    ]
  end

  @impl true
  def dashboard_assigns do
    [
      datasource_id: "prometheus"
    ]
  end

  @impl true
  def dashboards do
    [
      # Built-in dashboards
      {:prom_ex, "application.json"},
      {:prom_ex, "beam.json"},
      {:prom_ex, "phoenix.json"},
      
      # Custom gateway dashboard
      {:elixirgateway, "gateway.json"}
    ]
  end
end