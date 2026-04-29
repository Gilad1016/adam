defmodule Adam.Curator.Curate do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def init(state) do
    schedule_curate()
    {:ok, state}
  end

  def handle_info(:curate, state) do
    prune_old_knowledge()
    schedule_curate()
    {:noreply, state}
  end

  defp prune_old_knowledge do
    index = Adam.Knowledge.load_index()
    now = System.os_time(:second)
    max_entries = 200
    max_age_days = 30

    if length(index) > max_entries do
      {kept, dropped} =
        Enum.split_with(index, fn entry ->
          updated = entry["updated"] || entry["created"] || 0
          updated = if is_integer(updated), do: updated, else: 0
          age_days = (now - updated) / 86400
          # Keep if young enough OR explicitly marked important
          age_days <= max_age_days or String.contains?(entry["tags"] || "", "important")
        end)

      kept = Enum.take(kept, max_entries)

      Enum.each(dropped, fn entry ->
        if id = entry["id"], do: Adam.Knowledge.delete(id)
      end)

      removed = length(dropped)

      if removed > 0 do
        IO.puts("[CURATOR] Pruned #{removed} old knowledge entries (#{length(kept)} kept)")
      end
    end
  end

  defp schedule_curate, do: Process.send_after(self(), :curate, :timer.minutes(30))
end
