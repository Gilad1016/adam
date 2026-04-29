defmodule Observer.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Observer.PubSub},
      Observer.Store,
      Observer.Watcher,
      ObserverWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Observer.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
