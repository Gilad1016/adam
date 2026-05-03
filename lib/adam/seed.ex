defmodule Adam.Seed do
  @sleep_log_file "/app/memory/sleep_log.toon"

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

end
