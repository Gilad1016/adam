defmodule Adam.Retrospective do
  @thought_log "/app/memory/thought_log.toon"

  defp as_list(v) when is_list(v), do: v
  defp as_list(_), do: []

  @doc """
  Called after every thought is logged. Detects when a recovery episode just ended
  (previous entry was "recovering", current is not) and extracts a lesson.
  """
  def check do
    entries =
      if File.exists?(@thought_log) do
        try do
          @thought_log |> File.read!() |> Adam.Toon.decode() |> as_list()
        rescue
          _ -> []
        end
      else
        []
      end

    case Enum.take(entries, -2) do
      [prev, curr] when is_map(prev) and is_map(curr) ->
        if prev["tag"] == "recovering" and curr["tag"] != "recovering" do
          episode = collect_recovery_episode(entries)
          if length(episode) >= 2, do: write_lesson(episode)
        end

      _ ->
        :ok
    end
  end

  defp collect_recovery_episode(entries) do
    entries
    |> Enum.reverse()
    |> Enum.drop(1)
    |> Enum.take_while(&(is_map(&1) and &1["tag"] == "recovering"))
    |> Enum.reverse()
  end

  defp write_lesson(episode) do
    thoughts =
      episode
      |> Enum.map(&(&1["thought"] || ""))
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n---\n")
      |> String.slice(0, 2000)

    prompt = """
    These are ADAM's thoughts during a recovery episode — a stretch where something was failing.
    Write a brief lesson (2-4 sentences): what was attempted, what failed, and what was learned.
    Be specific and concrete.
    """

    try do
      result = Adam.LLM.think(prompt, thoughts, [], kind: "infra.retrospective")
      now = DateTime.utc_now() |> Calendar.strftime("%Y-%m-%d")

      Adam.Knowledge.write(
        "retrospective #{now}",
        result.content,
        ["retrospective", "auto-encoded", "lesson"]
      )

      IO.puts("[RETROSPECTIVE] Lesson written from #{length(episode)}-iteration recovery episode")
    rescue
      _ -> :ok
    end
  end
end
