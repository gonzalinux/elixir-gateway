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

# Native Erlang distribution clustering configuration (all environments)
if System.get_env("CLUSTER_ENABLED") == "true" do
  peers =
    case System.get_env("CLUSTER_PEERS") do
      nil -> []
      "" -> []
      peers_str -> String.split(peers_str, ",", trim: true)
    end

  listen_port = String.to_integer(System.get_env("CLUSTER_PORT", "9100"))

  # Set kernel inet_dist port range via environment (before kernel starts)
  # This must be done before the application starts
  System.put_env("ERL_DIST_PORT", to_string(listen_port))

  # Application config for cluster module
  config :elixirgateway, :cluster,
    enabled: true,
    secret: System.get_env("CLUSTER_SECRET"),
    node_name: System.get_env("NODE_NAME"),
    node_ip: System.get_env("NODE_IP"),
    listen_port: listen_port,
    peers: peers
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
