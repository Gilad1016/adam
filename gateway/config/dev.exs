import Config

config :llm_gateway, LlmGateway.Repo,
  database: System.get_env("DATABASE_PATH", "/app/data/calls.db"),
  pool_size: 5,
  show_sensitive_data_on_connection_error: true

config :llm_gateway, LlmGatewayWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4000"))],
  secret_key_base: "dev_secret_key_base_at_least_64_bytes_long_for_phoenix_endpoint_xxxxxxxx",
  server: true,
  check_origin: false,
  debug_errors: true

config :logger, level: :info
