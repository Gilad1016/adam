defmodule Adam.Tools.Shell do
  def run(%{"command" => command}) do
    try do
      case System.cmd("sh", ["-c", command], stderr_to_stdout: true) do
        {output, _} -> String.slice(output, 0, 2000)
      end
    rescue
      _ -> "[TIMEOUT after 60s]"
    end
  end

  def wait(%{"minutes" => minutes}) do
    minutes = max(1, min(minutes, 60))
    total_ms = minutes * 60_000
    wait_loop(total_ms, 0)
  end

  defp wait_loop(total_ms, elapsed) when elapsed >= total_ms do
    "rested for #{div(total_ms, 60_000)} minutes"
  end

  defp wait_loop(total_ms, elapsed) do
    Process.sleep(15_000)

    if Adam.Interrupts.has_pending?() do
      "woke up after #{div(elapsed + 15_000, 60_000)}m — interrupt detected"
    else
      wait_loop(total_ms, elapsed + 15_000)
    end
  end
end
