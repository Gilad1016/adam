defmodule Adam.ToolStats do
  use GenServer

  @state_file "/app/memory/tool_stats.toon"
  @max_history_per_tool 50

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def init(_) do
    {:ok, load_state()}
  end

  def record_call(tool_name, args, result, success?) do
    GenServer.cast(__MODULE__, {:record, tool_name, args, result, success?})
  end

  def get_summary(tool_name) do
    GenServer.call(__MODULE__, {:summary, tool_name})
  end

  def get_history(tool_name) do
    GenServer.call(__MODULE__, {:history, tool_name})
  end

  def invalidate(tool_name) do
    GenServer.cast(__MODULE__, {:invalidate, tool_name})
  end

  def handle_cast({:record, tool_name, args, result, success?}, state) do
    entry = %{
      "t" => System.os_time(:second),
      "ok" => success?,
      "args" => summarize_args(args),
      "result" => String.slice(to_string(result), 0, 200)
    }

    tool_data = Map.get(state, tool_name, %{"calls" => [], "file_hash" => nil})
    calls = (tool_data["calls"] ++ [entry]) |> Enum.take(-@max_history_per_tool)
    tool_data = Map.put(tool_data, "calls", calls)
    state = Map.put(state, tool_name, tool_data)

    save_state(state)
    {:noreply, state}
  end

  def handle_cast({:invalidate, tool_name}, state) do
    state = Map.delete(state, tool_name)
    save_state(state)
    IO.puts("[TOOL-STATS] Invalidated stats for '#{tool_name}' (tool modified)")
    {:noreply, state}
  end

  def handle_call({:summary, tool_name}, _from, state) do
    case Map.get(state, tool_name) do
      nil ->
        {:reply, nil, state}

      %{"calls" => calls} ->
        total = length(calls)
        successes = Enum.count(calls, & &1["ok"])
        {:reply, %{total: total, successes: successes, failures: total - successes}, state}
    end
  end

  def handle_call({:history, tool_name}, _from, state) do
    case Map.get(state, tool_name) do
      nil ->
        {:reply, "No usage history for '#{tool_name}'.", state}

      %{"calls" => calls} ->
        text =
          calls
          |> Enum.take(-20)
          |> Enum.map(fn entry ->
            status = if entry["ok"], do: "OK", else: "FAIL"
            ago = format_ago(entry["t"])
            "#{ago} [#{status}] args=#{entry["args"]} → #{entry["result"]}"
          end)
          |> Enum.join("\n")

        {:reply, text, state}
    end
  end

  defp summarize_args(args) when is_map(args) do
    args
    |> Enum.map(fn {k, v} -> "#{k}=#{String.slice(to_string(v), 0, 40)}" end)
    |> Enum.join(", ")
    |> String.slice(0, 120)
  end

  defp summarize_args(_), do: ""

  defp format_ago(timestamp) do
    diff = System.os_time(:second) - timestamp

    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86_400)}d ago"
    end
  end

  defp load_state do
    if File.exists?(@state_file) do
      try do
        case @state_file |> File.read!() |> Adam.Toon.decode() do
          result when is_map(result) -> result
          _ -> %{}
        end
      rescue
        _ -> %{}
      end
    else
      %{}
    end
  end

  defp save_state(state) do
    File.mkdir_p!(Path.dirname(@state_file))
    Adam.AtomicFile.write!(@state_file, Adam.Toon.encode(state))
  rescue
    _ -> :ok
  end
end
