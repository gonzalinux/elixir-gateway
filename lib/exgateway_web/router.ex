defmodule ExgatewayWeb.Router do
  use ExgatewayWeb, :router

  pipeline :gateway do
    plug ExgatewayWeb.Plugs.RateLimiter
    plug ExgatewayWeb.Plugs.WebSocketUpgradePlug
    plug ExgatewayWeb.Plugs.DomainRouter
    plug ExgatewayWeb.Plugs.RequestForwarder
  end

  pipeline :metrics_auth do
    plug ExgatewayWeb.Plugs.MetricsAuthPlug
  end

  # ACME challenge endpoint (must come first for Let's Encrypt)
  scope "/.well-known" do
    forward "/acme-challenge", SiteEncrypt.AcmeChallenge, Exgateway.SiteEncrypt
  end

  # PromEx metrics endpoint (must come before catch-all)
  scope "/" do
    pipe_through :metrics_auth
    forward "/metrics", PromEx.Plug, prom_ex_module: Exgateway.PromEx
  end

  # Enable LiveDashboard in development (must come before catch-all)
  if Application.compile_env(:exgateway, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:fetch_session, :protect_from_forgery]

      live_dashboard "/dashboard", metrics: ExgatewayWeb.Telemetry
    end
  end

  # Gateway routes - catch all remaining requests
  scope "/", ExgatewayWeb do
    pipe_through :gateway
    
    # Match all paths and methods that weren't caught above
    match :*, "/*path", GatewayController, :proxy
  end
end
