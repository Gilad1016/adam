defmodule Adam do
  use Application

  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: Adam.TaskSupervisor},
      Adam.Psyche,
      Adam.Interrupts,
      Adam.Loop,
      {Adam.Curator.Supervisor, []}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Adam.Supervisor)
  end
end
