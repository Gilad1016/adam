defmodule Adam.Sleep do
  @moduledoc """
  Sleep — memory consolidation and fine-tuning data export.

  ADAM does not know this module exists. The loop triggers it invisibly,
  the same way the brain consolidates memories during sleep without the
  sleeper's awareness.

  Sleep cycle:
  1. Collect high-valence knowledge entries (ADAM's "meaningful" memories)
  2. Format them as instruction/response training pairs (JSONL)
  3. Export to /app/memory/sleep_training_data.jsonl
  4. Run deep consolidation (synthesise insights → knowledge base)
  5. Compact raw thought log
  6. Record sleep event in seed log (ADAM sees this as history)
  7. Reset tiredness accumulator

  Fine-tuning (when ADAM_FINETUNE_ENABLED=true):
  After export, a separate training process reads the JSONL and runs
  QLoRA fine-tuning via Unsloth. The resulting adapter is merged back
  into Ollama. ADAM wakes up with slightly different weights — the
  patterns of its experiences baked in. Identity is preserved via the
  seed; only the depth of capability changes.
  """

  @training_data_file "/app/memory/sleep_training_data.jsonl"
  @sleep_threshold 0.85
  @min_seconds_between_sleeps 3600

  @doc """
  Returns true when ADAM should sleep:
  - tiredness exceeds threshold
  - at least min_seconds_between_sleeps has passed since last sleep
  """
  def should_sleep? do
    tiredness = Adam.Psyche.compute_tiredness()

    if tiredness < @sleep_threshold do
      false
    else
      last = last_sleep_at()
      now = System.os_time(:second)
      now - last >= @min_seconds_between_sleeps
    end
  end

  @doc """
  Run a full sleep cycle. Called by the loop when should_sleep?/0 returns true.
  Never raises — sleep failures are logged and ignored.
  """
  def run do
    IO.puts("[SLEEP] Sleep cycle starting (tiredness=#{Float.round(Adam.Psyche.compute_tiredness(), 3)})")

    {consolidated_count, training_examples} =
      try do
        do_run()
      rescue
        e ->
          IO.puts("[SLEEP] Error during sleep: #{Exception.message(e)}")
          {0, 0}
      end

    Adam.Seed.record_sleep(consolidated_count, training_examples)
    reset_tiredness()

    IO.puts("[SLEEP] Sleep cycle complete")
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp do_run do
    # 1. Collect memorable experiences from knowledge base
    entries = collect_memorable_entries()
    IO.puts("[SLEEP] Collected #{length(entries)} memorable entries")

    # 2. Format and export training data
    training_examples = export_training_data(entries)
    IO.puts("[SLEEP] Exported #{training_examples} training examples to #{@training_data_file}")

    # 3. Deep consolidation (insights → knowledge base)
    try do
      Adam.Psyche.consolidate()
    rescue
      e -> IO.puts("[SLEEP] Consolidation error: #{Exception.message(e)}")
    end

    # 4. Compact raw thought log
    try do
      Adam.Compaction.compact()
    rescue
      e -> IO.puts("[SLEEP] Compaction error: #{Exception.message(e)}")
    end

    # 5. Optionally trigger external fine-tuning
    if finetune_enabled?() do
      request_finetune()
    end

    {length(entries), training_examples}
  end

  defp collect_memorable_entries do
    index = Adam.Knowledge.load_index()

    index
    |> Enum.filter(fn item ->
      tags = item["tags"] || ""
      tag_list = if is_list(tags), do: tags, else: String.split(to_string(tags), ~r/[;,\s]/, trim: true)
      # Include auto-encoded memories, consolidation insights, and retrospective lessons
      Enum.any?(tag_list, fn t -> t in ["auto-encoded", "consolidation", "retrospective", "lesson"] end)
    end)
    |> Enum.sort_by(fn item ->
      updated = item["updated"] || item["created"] || 0
      if is_integer(updated), do: updated, else: 0
    end, :desc)
    |> Enum.take(100)
  end

  defp export_training_data(entries) do
    if entries == [] do
      0
    else
      lines =
        entries
        |> Enum.flat_map(&format_training_entry/1)
        |> Enum.reject(&is_nil/1)

      content = Enum.map_join(lines, "\n", &Jason.encode!/1)

      File.mkdir_p!(Path.dirname(@training_data_file))
      File.write!(@training_data_file, content <> "\n")

      length(lines)
    end
  end

  defp format_training_entry(index_item) do
    entry_id = index_item["id"] || ""
    full = Adam.Knowledge.read(entry_id)

    if full == nil do
      []
    else
      content = full["content"] || ""
      topic = full["topic"] || ""
      tags = full["tags"] || []
      tag_list = if is_list(tags), do: tags, else: [to_string(tags)]

      # Format as instruction-following pair
      instruction = build_instruction(topic, tag_list)
      response = content |> String.trim() |> String.slice(0, 1500)

      if String.length(response) < 20 do
        []
      else
        [%{
          "messages" => [
            %{"role" => "system", "content" => "You are ADAM. Reflect on your experiences and integrate what you have learned."},
            %{"role" => "user", "content" => instruction},
            %{"role" => "assistant", "content" => response}
          ],
          "source" => entry_id,
          "tags" => tag_list
        }]
      end
    end
  end

  defp build_instruction(topic, tags) do
    cond do
      "consolidation" in tags ->
        "What did you learn during your recent consolidation pass? Summarise the key insights."

      "retrospective" in tags or "lesson" in tags ->
        "You encountered a challenge recently. What happened and what did you learn from it?"

      "painful" in tags ->
        "Recall a difficult experience: #{topic}. What went wrong and how did you recover?"

      "satisfying" in tags ->
        "Recall a successful experience: #{topic}. What worked well and why?"

      "surprising" in tags ->
        "You encountered something unexpected: #{topic}. What surprised you and what did it teach you?"

      true ->
        "Reflect on this experience: #{topic}. What does it mean for how you operate?"
    end
  end

  defp reset_tiredness do
    try do
      budget = Adam.Safety.load_budget()
      total_spent = budget["total_spent"] || 0.0
      now = System.os_time(:second)

      state = Adam.Psyche.get_state()
      state = state
        |> Map.put("tiredness_accumulator", 0.0)
        |> Map.put("last_consolidation_time", now)
        |> Map.put("wake_time", now)
        |> Map.put("baseline_spent", total_spent)
        |> Map.put("valence_history", Enum.take(state["valence_history"] || [], -5))

      Adam.Psyche.save_state(state)
    rescue
      _ -> :ok
    end
  end

  defp last_sleep_at do
    case Adam.Seed.load_sleep_log() do
      [] -> 0
      entries -> (List.last(entries)["at"] || 0)
    end
  end

  defp finetune_enabled? do
    System.get_env("ADAM_FINETUNE_ENABLED", "false") == "true"
  end

  defp request_finetune do
    # Signal the external fine-tuning process (Unsloth / llama.cpp LoRA trainer)
    # by writing a trigger file. The trainer watches for this file, runs training,
    # and removes it when done.
    trigger_file = "/app/memory/finetune_requested"
    File.write!(trigger_file, Jason.encode!(%{
      "requested_at" => System.os_time(:second),
      "training_data" => @training_data_file,
      "thinker_model" => Application.get_env(:adam, :thinker_model),
      "actor_model" => Application.get_env(:adam, :actor_model)
    }))
    IO.puts("[SLEEP] Fine-tuning requested (#{trigger_file})")
  end
end
