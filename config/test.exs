import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :elixirgateway, ElixirGatewayWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "0Mpg/nHivCKkN4rFWz+wcVsGklGVzT2ZWHsSkwlW6cGuVcvGtKZt9Ip6fkoYQIJ1",
  server: false

# Gateway configuration for tests
config :elixirgateway, :gateway,
  services: %{
    "default" => "http://localhost:8000",
    "test-service.com" => "http://localhost:9000",
    "another-service.com" => "http://localhost:9001",
    "unknown-service.com" => "http://localhost:9002"
  },
  rate_limit: [
    requests_per_minute: 1000,
    cleanup_interval: :timer.minutes(1)
  ]

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime
