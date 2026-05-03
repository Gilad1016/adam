defmodule Adam.Compaction do
  @thought_log "/app/memory/thought_log.toon"
  @compaction_state_file "/app/memory/compaction_state.toon"
  # Per-stage hard cap on entries kept in the thought log.
  @max_entries_per_stage %{0 => 100, 1 => 150, 2 => 200, 3 => 300, 4 => 500}
  # Per-stage entry-count trigger for compaction.
  @compact_entry_threshold_per_stage %{0 => 50, 1 => 80, 2 => 120, 3 => 180, 4 => 250}
  # Per-stage byte-size trigger for compaction (file size on disk).
  @compact_byte_threshold_per_stage %{
    0 => 25_000, 1 => 40_000, 2 => 60_000, 3 => 80_000, 4 => 120_000
  }
  # Dense pain cluster: compact early when this many consecutive recovering entries exist
  @pain_cluster_threshold 6
  # Don't compact more than once every N entries added since the previous compaction
  # (rate limit even when thresholds are exceeded — protects against thrash).
  @min_entries_between_compactions 20
  # Content guard: if the to-be-summarised body is shorter than this, skip the LLM call.
  @summarize_min_chars 200

  def check do
    if File.exists?(@thought_log) do
      entries = load_entries()
      count = length(entries)
      bytes =
        case File.stat(@thought_log) do
          {:ok, %{size: s}} -> s
          _ -> 0
        end

      state = load_state()
      last_count = state["last_compacted_count"] || 0
      entries_since = count - last_count

      cond do
        # Hard rate limit: don't run again until enough new entries accumulated.
        entries_since < @min_entries_between_compactions ->
          :ok

        count > compact_entry_threshold() ->
          compact(entries, :standard)

        bytes > compact_byte_threshold() ->
          compact(entries, :standard)

        count > 0 and consecutive_recovering_tail(entries) >= @pain_cluster_threshold ->
          compact(entries, :pain_cluster)

        true ->
          :ok
      end
    end
  end

  @doc "Force a compaction pass regardless of entry count (used by deep consolidation)."
  def compact do
    if File.exists?(@thought_log) do
      entries = load_entries()
      if entries != [], do: compact(entries, :standard)
    end
  end

  defp consecutive_recovering_tail(entries) do
    entries
    |> Enum.reverse()
    |> Enum.reduce_while(0, fn e, n ->
      if is_map(e) and e["tag"] == "recovering", do: {:cont, n + 1}, else: {:halt, n}
    end)
  end

  defp compact(entries, mode) do
    {old, recent} =
      case mode do
        :pain_cluster ->
          tail_count = consecutive_recovering_tail(entries)
          split_at = max(0, length(entries) - tail_count)
          Enum.split(entries, split_at)

        :standard ->
          Enum.split(entries, length(entries) - 20)
      end

    summary = summarize(old, mode)

    summary_entry = %{
      "iteration" => "compacted",
      "thought" => summary,
      "timestamp" => System.os_time(:second),
      "tag" => "summary"
    }

    save_entries([summary_entry | recent])
    save_state(%{
      "last_compacted_count" => length([summary_entry | recent]),
      "last_compacted_at" => System.os_time(:second)
    })
    IO.puts("[COMPACTION] #{mode} — compressed #{length(old)} entries into summary")
  end

  defp summarize(entries, mode) do
    thoughts =
      entries
      |> Enum.map(fn e -> e["thought"] || "" end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.take(50)

    context = Enum.join(thoughts, "\n---\n") |> String.slice(0, 3000)

    anchors = Adam.Psyche.get_anchors()
    anchor_text =
      if map_size(anchors) > 0 do
        "\n\nANCHORS (must survive — include in summary):\n" <>
          Enum.map_join(anchors, "\n", fn {k, v} -> "- #{k}: #{v["value"]}" end)
      else
        ""
      end

    base_instruction =
      case mode do
        :pain_cluster ->
          "Summarize this struggle episode: what was attempted, what failed, and any insight gained."

        :standard ->
          "Summarize these thoughts into key patterns, decisions, and learnings. Be concise.\nFocus on: what was attempted, what worked, what failed, key discoveries."
      end

    prompt = base_instruction <> anchor_text

    # Content guard: if there isn't enough material, skip the LLM call entirely
    # and emit a trivial placeholder so callers still see the compaction took
    # effect (entries got dropped) without burning tokens on empty input.
    if String.length(context) < @summarize_min_chars do
      IO.puts("[COMPACTION] Skipping LLM summarize: only #{String.length(context)} chars (< #{@summarize_min_chars}).")
      "[skipped: insufficient content to summarize — #{length(thoughts)} short entries dropped]"
    else
      result = Adam.LLM.think(prompt, context, [], kind: "infra.compact")
      result.content
    end
  end

  def log_thought(iteration, thought, tool_results) do
    File.mkdir_p!(Path.dirname(@thought_log))

    # Valence was just scored by Adam.Psyche.process — read it from state
    valence =
      try do
        state = Adam.Psyche.get_state()
        state["valence_history"] |> List.last() || %{}
      rescue
        _ -> %{}
      end

    tag = Adam.Psyche.classify_trajectory(thought, tool_results, valence)

    entry = %{
      "iteration" => iteration,
      "thought" => String.slice(thought, 0, 500),
      "tools" => Enum.map(tool_results, fn r -> r.name end) |> Enum.join(","),
      "timestamp" => System.os_time(:second),
      "tag" => tag
    }

    entries = load_entries()
    entries = entries ++ [entry]

    cap = max_entries()

    entries =
      if length(entries) > cap do
        Enum.take(entries, -cap)
      else
        entries
      end

    save_entries(entries)
  end

  def load_entries do
    if File.exists?(@thought_log) do
      content = File.read!(@thought_log)
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

  defp save_entries(entries) do
    Adam.AtomicFile.write!(@thought_log, Adam.Toon.encode(entries))
  end

  defp load_state do
    if File.exists?(@compaction_state_file) do
      try do
        case @compaction_state_file |> File.read!() |> Adam.Toon.decode() do
          m when is_map(m) -> m
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
    File.mkdir_p!(Path.dirname(@compaction_state_file))
    Adam.AtomicFile.write!(@compaction_state_file, Adam.Toon.encode(state))
  end

  defp max_entries do
    try do
      Map.get(@max_entries_per_stage, Adam.Psyche.get_stage(), 200)
    rescue
      _ -> 200
    end
  end

  defp compact_entry_threshold do
    try do
      Map.get(@compact_entry_threshold_per_stage, Adam.Psyche.get_stage(), 100)
    rescue
      _ -> 100
    end
  end

  defp compact_byte_threshold do
    try do
      Map.get(@compact_byte_threshold_per_stage, Adam.Psyche.get_stage(), 50_000)
    rescue
      _ -> 50_000
    end
  end
end
