defmodule Adam.Tools.Shell do
  def run(%{"command" => command}) when is_binary(command) do
    try do
      case System.cmd("sh", ["-c", command], stderr_to_stdout: true) do
        {output, _} -> String.slice(output, 0, 2000)
      end
    rescue
      _ -> "[TIMEOUT after 60s]"
    end
  end

  def run(args), do: "[ERROR: shell requires 'command' string, got #{inspect(args)}]"

  def wait(%{"minutes" => minutes}) when is_integer(minutes) do
    minutes = max(1, min(minutes, 60))
    total_ms = minutes * 60_000
    wait_loop(total_ms, 0)
  end

  def wait(%{"minutes" => minutes}) when is_binary(minutes) do
    case Integer.parse(minutes) do
      {n, _} -> wait(%{"minutes" => n})
      _ -> "[ERROR: wait 'minutes' not parseable: #{inspect(minutes)}]"
    end
  end

  def wait(args), do: "[ERROR: wait requires 'minutes' integer, got #{inspect(args)}]"

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
