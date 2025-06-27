defmodule Exgateway.PromEx do
  @moduledoc """
  PromEx configuration for the API Gateway.
  """
  
  use PromEx, otp_app: :exgateway

  alias PromEx.Plugins

  @impl true
  def plugins do
    [
      # Built-in Phoenix and Erlang/Elixir metrics
      Plugins.Application,
      Plugins.Beam,
      {Plugins.Phoenix, router: ExgatewayWeb.Router, endpoint: ExgatewayWeb.Endpoint},
      
      # Custom gateway metrics
      {Exgateway.PromEx.Plugins.Gateway, []}
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
      {:exgateway, "gateway.json"}
    ]
  end
end