defmodule ObserverWeb.Router do
  use ObserverWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ObserverWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ObserverWeb do
    pipe_through :browser
    live "/", DashboardLive
  end

  scope "/api", ObserverWeb do
    pipe_through :api
    get "/events", EventsController, :index
  end
end
