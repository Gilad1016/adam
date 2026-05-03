defmodule LlmGatewayWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :llm_gateway

  @session_options [
    store: :cookie,
    key: "_llm_gateway_key",
    signing_salt: "gateway_session_salt_v1",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  # Intercept /api/* before the browser pipeline so the proxy reads raw bodies.
  plug LlmGatewayWeb.ApiDispatcher

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug LlmGatewayWeb.Router
end
