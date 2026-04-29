defmodule Adam.Compaction do
  @thought_log "/app/memory/thought_log.toon"
  @max_entries 100
  @compact_threshold 80

  def check do
    if File.exists?(@thought_log) do
      entries = load_entries()

      if length(entries) > @compact_threshold do
        compact(entries)
      end
    end
  end

  defp compact(entries) do
    {old, recent} = Enum.split(entries, length(entries) - 20)
    summary = summarize(old)

    summary_entry = %{
      "iteration" => "compacted",
      "thought" => summary,
      "timestamp" => System.os_time(:second)
    }

    save_entries([summary_entry | recent])
    IO.puts("[COMPACTION] Compressed #{length(old)} entries into summary")
  end

  defp summarize(entries) do
    thoughts =
      entries
      |> Enum.map(fn e -> e["thought"] || "" end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.take(50)

    context = Enum.join(thoughts, "\n---\n") |> String.slice(0, 3000)

    prompt = """
    Summarize these thoughts into key patterns, decisions, and learnings. Be concise.
    Focus on: what was attempted, what worked, what failed, key discoveries.
    """

    result = Adam.LLM.think(prompt, context, [], tier: "thinker")
    result.content
  end

  def log_thought(iteration, thought, tool_results) do
    File.mkdir_p!(Path.dirname(@thought_log))

    entry = %{
      "iteration" => iteration,
      "thought" => String.slice(thought, 0, 500),
      "tools" => Enum.map(tool_results, fn r -> r.name end) |> Enum.join(","),
      "timestamp" => System.os_time(:second)
    }

    entries = load_entries()
    entries = entries ++ [entry]

    entries =
      if length(entries) > @max_entries do
        Enum.take(entries, -@max_entries)
      else
        entries
      end

    save_entries(entries)
  end

  defp load_entries do
    if File.exists?(@thought_log) do
      content = File.read!(@thought_log)
      if String.trim(content) == "", do: [], else: Adam.Toon.decode(content) || []
    else
      []
    end
  end

  defp save_entries(entries) do
    File.write!(@thought_log, Adam.Toon.encode(entries))
  end
end
