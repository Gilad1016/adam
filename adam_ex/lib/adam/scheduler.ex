defmodule Adam.Scheduler do
  @routines_file "/app/memory/routines.toon"

  def init do
    File.mkdir_p!(Path.dirname(@routines_file))
    unless File.exists?(@routines_file), do: save_routines([])
  end

  def check_routines do
    now = System.os_time(:second)
    routines = load_routines()

    {due, rest} =
      Enum.split_with(routines, fn r ->
        last = r["last_run"] || 0
        interval = (r["interval_minutes"] || 60) * 60
        now - last >= interval
      end)

    updated_due =
      Enum.map(due, fn r -> Map.put(r, "last_run", now) end)

    save_routines(updated_due ++ rest)

    Enum.map(due, fn r ->
      "[ROUTINE] #{r["name"]}: #{r["action"]}"
    end)
  end

  def add_routine(%{"name" => name, "interval_minutes" => interval, "action" => action}) do
    routines = load_routines()
    routines = Enum.reject(routines, &(&1["name"] == name))

    routine = %{
      "name" => name,
      "interval_minutes" => interval,
      "action" => action,
      "last_run" => 0
    }

    save_routines([routine | routines])
    "added routine '#{name}' every #{interval}m"
  end

  def remove_routine(%{"name" => name}) do
    routines = load_routines() |> Enum.reject(&(&1["name"] == name))
    save_routines(routines)
    "removed routine '#{name}'"
  end

  def list_routines do
    case load_routines() do
      [] ->
        "no routines"

      routines ->
        routines
        |> Enum.map(fn r -> "#{r["name"]}: #{r["action"]} (every #{r["interval_minutes"]}m)" end)
        |> Enum.join("\n")
    end
  end

  defp load_routines do
    if File.exists?(@routines_file) do
      content = File.read!(@routines_file)
      if String.trim(content) == "" do
        []
      else
        case Adam.Toon.decode(content) do
          list when is_list(list) -> list
          _ -> []
        end
      end
    else
      []
    end
  end

  defp save_routines(routines) do
    File.write!(@routines_file, Adam.Toon.encode(routines))
  end
end
