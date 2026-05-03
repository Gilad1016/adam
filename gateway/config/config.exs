import Config

config :llm_gateway,
  ecto_repos: [LlmGateway.Repo]

config :llm_gateway, LlmGatewayWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: LlmGatewayWeb.ErrorHTML],
    layout: false
  ],
  pubsub_server: LlmGateway.PubSub,
  live_view: [signing_salt: "gateway_lv_salt_v1"]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
