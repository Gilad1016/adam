defmodule Adam.Curator.Autopush do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def init(state) do
    schedule_push()
    {:ok, state}
  end

  def handle_info(:push, state) do
    if Application.get_env(:adam, :git_remote_url) do
      System.cmd("git", ["add", "-A"], cd: "/app", stderr_to_stdout: true)
      System.cmd("git", ["commit", "-m", "."], cd: "/app", stderr_to_stdout: true)
      System.cmd("git", ["push"], cd: "/app", stderr_to_stdout: true)
    end

    schedule_push()
    {:noreply, state}
  end

  defp schedule_push, do: Process.send_after(self(), :push, :timer.minutes(15))
end
