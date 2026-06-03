import Config

# Do not print debug messages in production
config :logger, level: :info

# Ports are configured in runtime.exs to allow environment variable overrides
config :elixirgateway, ElixirGatewayWeb.Endpoint,
  https: [
    ip: {0, 0, 0, 0},
    cipher_suite: :strong,
    thousand_island_options: [
      transport_options: [sni_fun: &ElixirGateway.CertStore.sni_fun/1]
    ]
  ],
  server: true,
  check_origin: false

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
