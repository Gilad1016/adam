import Config

config :llm_gateway, LlmGateway.Repo,
  database: ":memory:",
  pool: Ecto.Adapters.SQL.Sandbox

config :llm_gateway, LlmGatewayWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test_secret_key_base_at_least_64_bytes_long_for_phoenix_endpoint_xxxxxxxx",
  server: false

config :logger, level: :warning
