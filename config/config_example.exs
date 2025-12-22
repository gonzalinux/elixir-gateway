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
    "yoursite.com" => "http://192.168.0.178:9022"
  },
  rate_limit: [
    user_requests_per_minute: 100,
    ip_requests_per_minute: 500,
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

# Configure WebSocket settings
config :elixirgateway, :websocket,
  # WebSocket upgrade timeout (30 seconds default, configurable for slow networks)
  upgrade_timeout: 30_000,
  # Connection pool settings per target host
  connection_pool: [
    # Max connections per target host
    size: 10,
    # 5 minutes idle timeout
    max_idle_time: 300_000,
    # Cleanup every minute
    cleanup_interval: 60_000
  ],
  # Reconnection settings
  reconnect: [
    # Maximum reconnection attempts
    max_attempts: 3,
    # Initial backoff in ms
    initial_backoff: 1000,
    # Maximum backoff in ms
    max_backoff: 30_000,
    # Exponential backoff multiplier
    backoff_multiplier: 2
  ],
  # Message queue settings during reconnection
  message_queue: [
    # Maximum queued messages during reconnection
    max_size: 100,
    # How long to queue messages before giving up
    timeout: 30_000
  ]

# Configure clustering (opt-in, disabled by default)
config :elixirgateway, :cluster,
  enabled: false,
  secret: nil,
  node_name: nil,
  listen_port: 9100,
  peers: [],
  heartbeat_interval: 1_000,
  failover_timeout: 5_000,
  cert_sync: [
    # Enable certificate sync (default: true when clustering enabled)
    enabled: true,
    # Retry delay for failed syncs (ms)
    retry_delay: 5_000,
    # Max sync retry attempts
    max_retries: 3,
    # RPC call timeout (ms)
    rpc_timeout: 30_000
  ],
  dns_failover: [
    enabled: false,
    provider: :namecheap_ddns,
    public_ip_method: :auto,
    domains: []
  ]

config :elixirgateway, env: config_env()

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
