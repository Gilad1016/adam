import Config

config :observer, ObserverWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [formats: [html: ObserverWeb.ErrorHTML], layout: false],
  pubsub_server: Observer.PubSub,
  live_view: [signing_salt: "adam_observer_salt_v1"]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
