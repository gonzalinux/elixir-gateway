import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.

# Port configuration for all environments
# Can be overridden with HTTP_PORT and HTTPS_PORT environment variables
if System.get_env("HTTP_PORT") || System.get_env("HTTPS_PORT") do
  http_port = System.get_env("HTTP_PORT")
  https_port = System.get_env("HTTPS_PORT")

  endpoint_config = []

  # HTTP port override (for ACME challenges)
  endpoint_config =
    if http_port do
      [{:http, [ip: {0, 0, 0, 0}, port: String.to_integer(http_port)]} | endpoint_config]
    else
      endpoint_config
    end

  # HTTPS port override
  endpoint_config =
    if https_port do
      [{:https, [port: String.to_integer(https_port)]} | endpoint_config]
    else
      endpoint_config
    end

  if endpoint_config != [] do
    config :elixirgateway, ElixirGatewayWeb.Endpoint, endpoint_config
  end
end

# Metrics authentication token (all environments)
# If set, metrics endpoint will require Bearer token authentication
# If not set, metrics endpoint will only allow access from private networks
if metrics_token = System.get_env("METRICS_AUTH_TOKEN") do
  config :elixirgateway, :metrics_auth_token, metrics_token
end

# Rate limiting configuration (all environments)
# Can be overridden with environment variables
if System.get_env("RATE_LIMIT_USER") || System.get_env("RATE_LIMIT_IP") do
  user_limit = String.to_integer(System.get_env("RATE_LIMIT_USER", "100"))
  ip_limit = String.to_integer(System.get_env("RATE_LIMIT_IP", "500"))

  config :elixirgateway, :gateway,
    rate_limit: [
      user_requests_per_minute: user_limit,
      ip_requests_per_minute: ip_limit,
      cleanup_interval: :timer.minutes(1)
    ]
end

# Bot blocker configuration (all environments)
if System.get_env("BOT_BLOCKER_ENABLED") do
  enabled = System.get_env("BOT_BLOCKER_ENABLED") == "true"
  block_duration = String.to_integer(System.get_env("BOT_BLOCK_DURATION", "3600"))

  config :elixirgateway, :bot_blocker,
    enabled: enabled,
    block_duration_seconds: block_duration,
    max_404s_before_block: 10
end

# Gateway services and SSL domains are now loaded by ElixirGateway.ConfigLoader
# at application startup, either from gateway.yaml or from GATEWAY_SERVICES /
# LETSENCRYPT_DOMAINS env vars. No parsing needed here.

# Native Erlang distribution clustering configuration (all environments)
if System.get_env("CLUSTER_ENABLED") == "true" do
  secret =
    System.get_env("CLUSTER_SECRET") ||
      raise "CLUSTER_ENABLED=true requires CLUSTER_SECRET to be set"

  peers =
    case System.get_env("CLUSTER_PEERS") do
      nil -> []
      "" -> []
      peers_str -> String.split(peers_str, ",", trim: true)
    end

  listen_port = String.to_integer(System.get_env("CLUSTER_PORT", "9100"))

  # Parse DNS failover configuration
  dns_failover_config =
    if System.get_env("DNS_FAILOVER_ENABLED") == "true" do
      # Parse DDNS_DOMAINS format: "host:domain:password,host:domain:password,..."
      domains =
        case System.get_env("DDNS_DOMAINS") do
          nil ->
            []

          "" ->
            []

          domains_str ->
            domains_str
            |> String.split(",", trim: true)
            |> Enum.map(fn entry ->
              case String.split(entry, ":", parts: 3) do
                [host, domain, password] ->
                  %{host: host, domain: domain, password: password}

                _ ->
                  raise """
                  Invalid DDNS_DOMAINS format: #{entry}
                  Expected format: host:domain:password
                  Example: @:example.com:password or api:example.com:password
                  """
              end
            end)
        end

      # Determine public IP method
      public_ip_method =
        case System.get_env("PUBLIC_IP_STATIC") do
          nil -> :auto
          "" -> :auto
          ip -> {:static, ip}
        end

      failover_timeout_seconds =
        System.get_env("DNS_FAILOVER_TIMEOUT", "5")
        |> String.to_integer()

      [
        enabled: true,
        provider: :namecheap_ddns,
        public_ip_method: public_ip_method,
        domains: domains,
        failover_timeout: failover_timeout_seconds * 1_000
      ]
    else
      [enabled: false]
    end

  # Parse load distribution configuration
  load_distribution_config =
    if System.get_env("LOAD_DISTRIBUTION_ENABLED") == "true" do
      [
        enabled: true,
        node_weight: String.to_integer(System.get_env("NODE_WEIGHT", "70")),
        min_requests_threshold: String.to_integer(System.get_env("MIN_REQ_THRESHOLD", "20")),
        window_seconds: 60
      ]
    else
      [enabled: false]
    end

  # Application config for cluster module
  config :elixirgateway, :cluster,
    enabled: true,
    secret: secret,
    node_name: System.get_env("NODE_NAME"),
    node_ip: System.get_env("NODE_IP"),
    listen_port: listen_port,
    peers: peers,
    dns_failover: dns_failover_config,
    load_distribution: load_distribution_config
end

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # Network configuration
  host = System.get_env("PHX_HOST") || "0.0.0.0"

  # DNS cluster query for distributed deployment
  config :elixirgateway, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Configure endpoint with runtime values
  config :elixirgateway, ElixirGatewayWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}],
    secret_key_base: secret_key_base
end
