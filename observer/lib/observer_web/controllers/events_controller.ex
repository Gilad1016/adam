defmodule ObserverWeb.EventsController do
  use ObserverWeb, :controller

  def index(conn, params) do
    since =
      case Integer.parse(params["since"] || "0") do
        {n, _} -> n
        :error -> 0
      end

    all = Observer.Store.all() |> Enum.reverse()
    events = Enum.drop(all, since)
    next = since + length(events)
    json(conn, %{events: events, next: next})
  end
end
