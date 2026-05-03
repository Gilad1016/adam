defmodule Adam do
  use Application

  def start(_type, _args) do
    # Mirror the tuning knob registry to disk so external readers (gateway
    # admin) can see defaults/bounds/descriptions without importing Adam.
    Adam.Tuning.dump_registry()

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
