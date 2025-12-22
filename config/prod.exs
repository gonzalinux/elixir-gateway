import Config

# Do not print debug messages in production
config :logger, level: :info

# Configure the endpoint for HTTPS with SiteEncrypt
# Ports are configured in runtime.exs to allow environment variable overrides
config :elixirgateway, ElixirGatewayWeb.Endpoint,
  # Enable HTTPS with SiteEncrypt for automatic SSL certificates
  https: [
    ip: {0, 0, 0, 0},
    cipher_suite: :strong,
    # SiteEncrypt will automatically provide these
    keyfile: {SiteEncrypt, {:pem_encoder, :key}},
    certfile: {SiteEncrypt, {:pem_encoder, :cert}}
  ],
  # Server configuration
  server: true,
  check_origin: false

# SiteEncrypt configuration
config :site_encrypt, ElixirGateway.SiteEncrypt,
  # Use this endpoint for ACME HTTP-01 challenges
  endpoint: ElixirGatewayWeb.Endpoint

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
