defmodule Observer.Store do
  @moduledoc """
  Holds the last N observer events in memory. Newest event at head of list.
  Populated by Observer.Watcher; read by the LiveView dashboard.
  """

  use Agent

  @known_types ~w(tool_call memory_update memory_compact context thought goal_update)

  def start_link(_opts) do
    Agent.start_link(fn -> [] end, name: __MODULE__)
  end

  @doc "Push a new event to the front. Drops oldest when over the limit."
  def push(event) do
    max = Application.get_env(:observer, :max_events, 1000)
    Agent.update(__MODULE__, fn events ->
      [event | events] |> Enum.take(max)
    end)
  end

  @doc "Return all events, newest first."
  def all do
    Agent.get(__MODULE__, & &1)
  end

  @doc "Return events of a specific type. Unknown types return []."
  def filtered(type) when type in @known_types do
    Agent.get(__MODULE__, fn events ->
      Enum.filter(events, &(&1["type"] == type))
    end)
  end

  def filtered(_type), do: []
end
