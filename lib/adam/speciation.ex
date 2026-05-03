defmodule Adam.Speciation do
  @thought_log "/app/memory/thought_log.toon"
  @patterns_file "/app/memory/patterns.toon"
  @threshold 3

  def check do
    if File.exists?(@thought_log) do
      entries = load_thought_log()
      patterns = detect_patterns(entries)
      existing = load_patterns()

      new_patterns =
        Enum.filter(patterns, fn p ->
          not Enum.any?(existing, &(&1["signature"] == p["signature"]))
        end)

      if new_patterns != [] do
        save_patterns(existing ++ new_patterns)
        Enum.each(new_patterns, fn p ->
          IO.puts("[SPECIATION] Detected pattern: #{p["signature"]} (#{p["count"]} occurrences)")
        end)
      end
    end
  end

  defp detect_patterns(entries) do
    entries
    |> Enum.map(fn e -> e["tools"] || "" end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.frequencies()
    |> Enum.filter(fn {_sig, count} -> count >= @threshold end)
    |> Enum.map(fn {sig, count} ->
      %{
        "signature" => sig,
        "count" => count,
        "detected_at" => System.os_time(:second)
      }
    end)
  end

  defp load_thought_log do
    content = File.read!(@thought_log)
    if String.trim(content) == "" do
      []
    else
      case Adam.Toon.decode(content) do
        list when is_list(list) -> list
        _ -> []
      end
    end
  end

  defp load_patterns do
    if File.exists?(@patterns_file) do
      content = File.read!(@patterns_file)
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

  defp save_patterns(patterns) do
    File.mkdir_p!(Path.dirname(@patterns_file))
    Adam.AtomicFile.write!(@patterns_file, Adam.Toon.encode(patterns))
  end
end
