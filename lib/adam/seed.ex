defmodule Adam.Seed do
  @seed_file "/app/priv/defaults/seed.md"
  @sleep_log_file "/app/memory/sleep_log.toon"

  @doc """
  Returns the seed content wrapped in context markers.
  Injected into every context before anything else — immutable, always present.
  """
  def context do
    seed_text =
      if File.exists?(@seed_file) do
        File.read!(@seed_file)
      else
        "(seed file missing — contact owner)"
      end

    sleep_summary = sleep_history_summary()

    parts = ["== SEED (immutable) ==", seed_text, "== END SEED =="]

    parts =
      if sleep_summary != "" do
        parts ++ ["== SLEEP HISTORY ==", sleep_summary, "== END SLEEP HISTORY =="]
      else
        parts
      end

    Enum.join(parts, "\n")
  end

  @doc """
  Record that a sleep cycle completed. Called by Sleep module.
  """
  def record_sleep(consolidated_count, training_examples) do
    now = System.os_time(:second)
    entry = %{
      "at" => now,
      "consolidated" => consolidated_count,
      "training_examples" => training_examples,
      "timestamp_human" => DateTime.utc_now() |> Calendar.strftime("%Y-%m-%d %H:%M UTC")
    }

    existing = load_sleep_log()
    updated = Enum.take(existing ++ [entry], -20)

    File.mkdir_p!(Path.dirname(@sleep_log_file))
    File.write!(@sleep_log_file, Adam.Toon.encode(updated))

    IO.puts("[SEED] Sleep recorded: #{consolidated_count} memories consolidated, #{training_examples} training examples")
  end

  @doc """
  Load all sleep log entries.
  """
  def load_sleep_log do
    if File.exists?(@sleep_log_file) do
      try do
        @sleep_log_file |> File.read!() |> Adam.Toon.decode()
      rescue
        _ -> []
      end
    else
      []
    end
  end

  defp sleep_history_summary do
    entries = load_sleep_log()

    if entries == [] do
      ""
    else
      last = List.last(entries)
      count = length(entries)
      last_time = last["timestamp_human"] || "unknown"
      "You have slept #{count} time(s). Last sleep: #{last_time} (#{last["consolidated"] || 0} memories consolidated)."
    end
  end
end
