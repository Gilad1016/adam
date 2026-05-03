defmodule LlmGatewayWeb.Router do
  use LlmGatewayWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {LlmGatewayWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/" do
    pipe_through :browser
    live "/", LlmGatewayWeb.CallsLive, :index
    live "/admin", LlmGatewayWeb.AdminLive, :index
    live "/system", LlmGatewayWeb.SystemLive, :index
  end
end
