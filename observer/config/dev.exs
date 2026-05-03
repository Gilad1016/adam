import Config

config :observer, ObserverWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4000],
  check_origin: false,
  code_reloader: false,
  debug_errors: false,
  secret_key_base: "dev_secret_key_base_at_least_64_chars_long_for_adam_observer_padding",
  server: true

# Keep our own [Observer.*] info logs but drop Phoenix request/socket chatter.
config :logger, level: :info
config :logger, :console, format: "[$level] $message\n"

# Disables Phoenix.Logger plug — kills the GET /, MOUNT, HANDLE EVENT spam.
config :phoenix, :logger, false
config :phoenix_live_view, :debug_heex_annotations, false
