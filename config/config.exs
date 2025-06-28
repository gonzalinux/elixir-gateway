# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :elixirgateway,
  generators: [timestamp_type: :utc_datetime]

# Gateway configuration
# Modify it with your proxied services
config :elixirgateway, :gateway,
  services: %{
  # default is used when no host comes in the headers
    "default" => "http://localhost:8000",
    "yoursite.com" => "http://192.168.0.178:9022",
  },

  rate_limit: [
    requests_per_minute: 100,
    cleanup_interval: :timer.minutes(1)
  ]

# Configures the endpoint
config :elixirgateway, ElixirGatewayWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: ElixirGatewayWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: ElixirGateway.PubSub,
  live_view: [signing_salt: "l5uDvTHO"]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Configure Finch for HTTP client
config :elixirgateway, :finch,
  name: ElixirGateway.Finch,
  pools: %{
    :default => [size: 25, max_idle_time: 30_000]
  }

# Configure Hammer for rate limiting
config :hammer,
  backend: {Hammer.Backend.ETS, [expiry_ms: 60_000 * 60 * 2, cleanup_interval_ms: 60_000 * 10]}

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
