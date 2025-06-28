import Config

# Do not print debug messages in production
config :logger, level: :info

# Configure the endpoint for HTTPS with Let's Encrypt
config :elixirgateway, ElixirGatewayWeb.Endpoint,
  # Enable HTTPS with SiteEncrypt for automatic SSL certificates
  https: [
    port: 4001,
         ip: {0, 0, 0, 0},
    cipher_suite: :strong,
    # SiteEncrypt will automatically provide these
    keyfile: {SiteEncrypt, {:pem_encoder, :key}},
    certfile: {SiteEncrypt, {:pem_encoder, :cert}},
#    cacertfile: {SiteEncrypt, {:pem_encoder, :chain}}
  ],
  # HTTP listener for ACME challenges and optional redirect
  http: [ip: {0, 0, 0, 0}, port: 4000],
  # Server configuration
  server: true,
  check_origin: false

# SiteEncrypt configuration
config :site_encrypt, ElixirGateway.SiteEncrypt,
  # Use this endpoint for ACME HTTP-01 challenges
  endpoint: ElixirGatewayWeb.Endpoint

# Certificate storage configuration
config :elixirgateway,
  cert_db_folder: System.get_env("CERT_DB_FOLDER", "/etc/elixirgateway/certs")

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
