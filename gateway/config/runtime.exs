import Config

config :llm_gateway,
  ollama_url: System.get_env("OLLAMA_URL", "http://ollama:11434")

if config_env() == :prod do
  database_path = System.get_env("DATABASE_PATH") || "/app/data/calls.db"

  config :llm_gateway, LlmGateway.Repo,
    database: database_path,
    pool_size: 5

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE is required in prod"

  config :llm_gateway, LlmGatewayWeb.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4000"))],
    secret_key_base: secret_key_base,
    server: true,
    check_origin: false
end
