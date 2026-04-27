import Config

# For development, we disable any cache and enable
# debugging and code reloading.
#
# The watchers configuration can be used to run external
# watchers to your application. For example, we can use it
# to bundle .js and .css sources.
config :elixirgateway, ElixirGatewayWeb.Endpoint,
  # URL generation configuration (shows actual dev port in logs)
  url: [host: "localhost", port: 4003, scheme: "https"],
  # Binding to all interfaces to allow testing from other machines
  http: [ip: {0, 0, 0, 0}, port: 4004],
  https: [
    ip: {0, 0, 0, 0},
    port: 4003,
    cipher_suite: :strong,
    thousand_island_options: [
      transport_options: [sni_fun: &ElixirGateway.CertStore.sni_fun/1]
    ]
  ],
  # Server configuration
  server: true,
  check_origin: false,
  code_reloader: false,
  debug_errors: true,
  secret_key_base: "R8wqe/SC6qs5wWrFw6+9QI4tAJvD+wUifCE/s3z69N4X2fpPyTsX9In58cdOBJr/",
  watchers: []

# Example gateway services configuration for development
config :elixirgateway, :gateway,
  services: %{
    "default" => "http://localhost:8443",
    "localhost" => "http://localhost:8443"
  }

# rate_limit is configured in runtime.exs via env vars

# Bot blocker configuration
config :elixirgateway, :bot_blocker,
  enabled: true,
  # 1 hour
  block_duration_seconds: 3600,
  max_404s_before_block: 10

# Enable dev routes for dashboard and mailbox
config :elixirgateway, dev_routes: true

# Do not include metadata nor timestamps in development logs
config :logger, :console, format: "[$level] $message\n"

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime
