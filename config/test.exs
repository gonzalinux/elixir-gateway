import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :exgateway, ExgatewayWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "0Mpg/nHivCKkN4rFWz+wcVsGklGVzT2ZWHsSkwlW6cGuVcvGtKZt9Ip6fkoYQIJ1",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime
