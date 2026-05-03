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
  # Sleep trigger threshold is now tunable via Adam.Tuning.get(:sleep_threshold).
  @min_seconds_between_sleeps 3600

  @doc """
  Returns true when ADAM should sleep:
  - tiredness exceeds threshold
  - at least min_seconds_between_sleeps has passed since last sleep
  """
  def should_sleep? do
    tiredness = Adam.Psyche.compute_tiredness()

    if tiredness < Adam.Tuning.get(:sleep_threshold) do
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

    regression_snapshot = capture_regression_snapshot()

    {consolidated_count, training_examples} =
      try do
        do_run()
      rescue
        e ->
          IO.puts("[SLEEP] Error during sleep: #{Exception.message(e)}")
          {0, 0}
      end

    check_regression_and_rollback(regression_snapshot)

    try do
      Adam.Narrative.regenerate()
    rescue
      e -> IO.puts("[SLEEP] Narrative regen failed: #{Exception.message(e)}")
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

  # ---------------------------------------------------------------------------
  # Tuning regression hook
  #
  # Snapshot mean valence at sleep start, compare to mean valence at sleep end,
  # and if valence dropped materially, roll back the most recent agent-sourced
  # tuning change inside the configured window. Operator and rollback entries
  # are excluded — operator changes are intentional human will, and rolling
  # back a rollback would oscillate.
  #
  # The hook is wrapped in try/rescue at every step so any failure (missing
  # state, knowledge write error, history corruption, etc.) just logs and
  # continues sleep. Sleep MUST NOT crash because of this hook.
  # ---------------------------------------------------------------------------

  defp capture_regression_snapshot do
    try do
      sample_size = Adam.Tuning.get(:sleep_valence_sample_size)
      window_seconds = Adam.Tuning.get(:sleep_regression_window_seconds)

      vh =
        case Adam.Psyche.get_state() do
          %{} = state -> state["valence_history"] || []
          _ -> []
        end

      vh = if is_list(vh), do: vh, else: []

      if length(vh) < 5 do
        nil
      else
        %{
          pre_sleep_valence: mean_last_n(vh, sample_size),
          tuning_window_start_ts: System.os_time(:second) - window_seconds,
          sample_size: sample_size
        }
      end
    rescue
      e ->
        IO.puts("[SLEEP] Regression snapshot failed: #{Exception.message(e)}")
        nil
    end
  end

  defp check_regression_and_rollback(nil), do: :ok

  defp check_regression_and_rollback(%{pre_sleep_valence: pre, tuning_window_start_ts: window_start, sample_size: sample_size}) do
    try do
      threshold = Adam.Tuning.get(:sleep_regression_threshold_pct)

      vh =
        case Adam.Psyche.get_state() do
          %{} = state -> state["valence_history"] || []
          _ -> []
        end

      vh = if is_list(vh), do: vh, else: []
      post = mean_last_n(vh, sample_size)

      delta_pct = (post - pre) / max(abs(pre), 0.01)

      if delta_pct >= -threshold do
        IO.puts("[SLEEP] valence held: pre=#{Float.round(pre * 1.0, 3)} post=#{Float.round(post * 1.0, 3)}")
        :ok
      else
        now = System.os_time(:second)

        target =
          Adam.Tuning.history()
          |> Enum.filter(fn entry ->
            entry["source"] == "agent" and
              is_integer(entry["ts"]) and
              entry["ts"] >= window_start and
              entry["ts"] <= now
          end)
          |> List.last()

        case target do
          nil ->
            IO.puts("[SLEEP] valence regressed but no recent agent tunings to rollback (delta=#{Float.round(delta_pct * 100.0, 1)}%)")
            :ok

          %{"name" => name} = entry ->
            try do
              knob = String.to_existing_atom(name)
              IO.puts("[SLEEP] valence regressed #{Float.round(delta_pct * 100.0, 1)}%; rolling back agent tuning '#{name}'")
              Adam.Tuning.rollback(knob, 1)
              write_regression_knowledge(entry, pre, post, delta_pct)
            rescue
              e -> IO.puts("[SLEEP] Rollback failed for #{name}: #{Exception.message(e)}")
            end
        end
      end
    rescue
      e -> IO.puts("[SLEEP] Regression check failed: #{Exception.message(e)}")
    end
  end

  defp write_regression_knowledge(entry, pre, post, delta_pct) do
    try do
      drop_pct = Float.round(abs(delta_pct) * 100.0, 1)

      body = """
      Tuning regression detected during sleep.
      - Knob: #{entry["name"]}
      - Tried value: #{inspect(entry["value"])}; reverted to: #{inspect(entry["previous"])}
      - Reason given: #{entry["reason"]}
      - Pre-sleep valence: #{Float.round(pre * 1.0, 3)}; post-sleep: #{Float.round(post * 1.0, 3)} (-#{drop_pct}%)
      This change degraded my recent experience. Avoid trying it again under similar conditions.
      """

      Adam.Knowledge.write(
        "tuning regression: #{entry["name"]}",
        body,
        ["tuning", "regression", "auto-rollback", "lesson"]
      )
    rescue
      e -> IO.puts("[SLEEP] Knowledge write for regression failed: #{Exception.message(e)}")
    end
  end

  defp mean_last_n(list, n) when is_list(list) and is_integer(n) and n > 0 do
    sample =
      list
      |> Enum.take(-n)
      |> Enum.filter(&is_number/1)

    case sample do
      [] -> 0.0
      values -> Enum.sum(values) / length(values)
    end
  end

  defp mean_last_n(_, _), do: 0.0

  defp request_finetune do
    # Signal the external fine-tuning process (Unsloth / llama.cpp LoRA trainer)
    # by writing a trigger file. The trainer watches for this file, runs training,
    # and removes it when done.
    trigger_file = "/app/memory/finetune_requested"
    File.write!(trigger_file, Jason.encode!(%{
      "requested_at" => System.os_time(:second),
      "training_data" => @training_data_file,
      "model" => Application.get_env(:adam, :model)
    }))
    IO.puts("[SLEEP] Fine-tuning requested (#{trigger_file})")
  end
end
