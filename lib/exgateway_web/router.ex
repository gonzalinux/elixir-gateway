defmodule ElixirGatewayWeb.Router do
  use ElixirGatewayWeb, :router

  pipeline :gateway do
    plug ElixirGatewayWeb.Plugs.RateLimiter
    plug ElixirGatewayWeb.Plugs.WebSocketUpgradePlug
    plug ElixirGatewayWeb.Plugs.DomainRouter
    plug ElixirGatewayWeb.Plugs.RequestForwarder
  end

  pipeline :metrics_auth do
    plug ElixirGatewayWeb.Plugs.MetricsAuthPlug
  end

  # ACME challenge endpoint (must come first for Let's Encrypt)
  scope "/.well-known" do
    forward "/acme-challenge", SiteEncrypt.AcmeChallenge, ElixirGateway.SiteEncrypt
  end

  # PromEx metrics endpoint (must come before catch-all)
  scope "/" do
    pipe_through :metrics_auth
    forward "/metrics", PromEx.Plug, prom_ex_module: ElixirGateway.PromEx
  end

  # Enable LiveDashboard in development (must come before catch-all)
  if Application.compile_env(:elixirgateway, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:fetch_session, :protect_from_forgery]

      live_dashboard "/dashboard", metrics: ElixirGatewayWeb.Telemetry
    end
  end

  # Gateway routes - catch all remaining requests
  scope "/", ElixirGatewayWeb do
    pipe_through :gateway
    
    # Match all paths and methods that weren't caught above
    match :*, "/*path", GatewayController, :proxy
  end
end
