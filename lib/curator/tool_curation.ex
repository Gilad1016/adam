defmodule Adam.Curator.ToolCuration do
  use GenServer

  @tools_dir "/app/tools"
  @archive_dir "/app/tools/archive"
  @state_file "/app/memory/tool_curation.toon"

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def init(state) do
    schedule()
    {:ok, state}
  end

  def handle_info(:curate_tools, state) do
    curate()
    schedule()
    {:noreply, state}
  end

  defp curate do
    custom_tools = list_custom_tools()
    if custom_tools == [], do: :ok, else: do_curate(custom_tools)
  end

  defp do_curate(custom_tools) do
    now = System.os_time(:second)
    curation_state = load_state()
    psyche = Adam.Psyche.get_state()
    sm = psyche["self_model"] || %{}
    tool_usage = sm["tool_usage"] || %{}
    tool_failure = sm["tool_failure"] || %{}
    action_history = as_list(sm["action_history"])

    {updated_state, actions} =
      Enum.reduce(custom_tools, {curation_state, []}, fn tool_name, {st, acts} ->
        uses = tool_usage[tool_name] || 0
        failures = tool_failure[tool_name] || 0
        last_used = last_usage_time(tool_name, action_history)
        stale_since = get_in(st, [tool_name, "stale_since"])

        cond do
          uses >= 3 and failures / max(uses, 1) > 0.5 ->
            nudge_revision(tool_name, failures, uses)
            {st, acts ++ [{:revision, tool_name}]}

          stale_since != nil and now - stale_since >= 14 * 86_400 ->
            archive_tool(tool_name)
            st = Map.delete(st, tool_name)
            {st, acts ++ [{:archived, tool_name}]}

          last_used != nil and now - last_used >= 7 * 86_400 and stale_since == nil ->
            st = Map.put(st, tool_name, %{"stale_since" => now})
            {st, acts ++ [{:stale, tool_name}]}

          last_used == nil and not Map.has_key?(st, tool_name) ->
            st = Map.put(st, tool_name, %{"first_seen" => now})
            {st, acts}

          true ->
            if last_used != nil and stale_since != nil and now - last_used < 7 * 86_400 do
              st = Map.put(st, tool_name, Map.delete(st[tool_name] || %{}, "stale_since"))
              {st, acts}
            else
              {st, acts}
            end
        end
      end)

    save_state(updated_state)

    Enum.each(actions, fn
      {:revision, name} -> IO.puts("[TOOL-CURATOR] Marked '#{name}' for revision (high failure rate)")
      {:stale, name} -> IO.puts("[TOOL-CURATOR] Marked '#{name}' as stale (unused 7+ days)")
      {:archived, name} -> IO.puts("[TOOL-CURATOR] Archived '#{name}' (stale 14+ days)")
    end)
  end

  defp list_custom_tools do
    if File.dir?(@tools_dir) do
      File.ls!(@tools_dir)
      |> Enum.filter(&String.ends_with?(&1, ".exs"))
      |> Enum.map(&String.replace_suffix(&1, ".exs", ""))
    else
      []
    end
  end

  defp last_usage_time(tool_name, action_history) do
    action_history
    |> Enum.filter(&(&1["tool"] == tool_name))
    |> Enum.map(&(&1["t"]))
    |> Enum.max(fn -> nil end)
  end

  defp nudge_revision(tool_name, failures, total) do
    rate = trunc(failures / max(total, 1) * 100)
    message = "[TOOL-CURATOR] Custom tool '#{tool_name}' has #{rate}% failure rate (#{failures}/#{total}). Consider revising or replacing it."
    Adam.Interrupts.add_alarm(%{"name" => "tool_revise_#{tool_name}", "minutes" => 0, "message" => message})
  end

  defp archive_tool(tool_name) do
    source = Path.join(@tools_dir, "#{tool_name}.exs")
    if File.exists?(source) do
      File.mkdir_p!(@archive_dir)
      dest = Path.join(@archive_dir, "#{tool_name}.exs")
      File.rename!(source, dest)
    end
  end

  defp load_state do
    if File.exists?(@state_file) do
      try do
        @state_file |> File.read!() |> Adam.Toon.decode()
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

  defp as_list(v) when is_list(v), do: v
  defp as_list(_), do: []

  defp schedule, do: Process.send_after(self(), :curate_tools, :timer.minutes(30))
end
