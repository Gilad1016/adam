import Config

config :observer, ObserverWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4000],
  check_origin: false,
  code_reloader: false,
  debug_errors: true,
  secret_key_base: "dev_secret_key_base_at_least_64_chars_long_for_adam_observer_padding",
  server: true

config :logger, :console, format: "[$level] $message\n"
