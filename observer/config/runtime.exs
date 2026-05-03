import Config

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE environment variable is missing."

  config :observer, ObserverWeb.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT") || "4000")],
    secret_key_base: secret_key_base,
    server: true
end

config :observer,
  events_file: System.get_env("OBSERVER_EVENTS_FILE", "/app/observer/events.jsonl"),
  max_events: String.to_integer(System.get_env("OBSERVER_MAX_EVENTS") || "1000"),
  poll_interval_ms: String.to_integer(System.get_env("OBSERVER_POLL_MS") || "500"),
  mode: System.get_env("ADAM_OBSERVER_MODE", "partial")
