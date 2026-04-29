defmodule Adam.Safety do
  @budget_file "/app/memory/budget.toon"
  @defaults_dir "/app/priv/defaults"

  def init_budget do
    unless File.exists?(@budget_file) do
      total = Application.get_env(:adam, :budget_total, 250.0)

      budget = %{
        "balance" => total,
        "initial" => total,
        "total_spent" => 0,
        "iteration_count" => 0,
        "last_deduction" => System.os_time(:second)
      }

      save_budget(budget)
    end
  end

  def deduct_electricity(cost) do
    budget = load_budget()

    budget = %{
      budget
      | "balance" => Float.round(budget["balance"] - cost, 4),
        "total_spent" => Float.round(budget["total_spent"] + cost, 4),
        "iteration_count" => (budget["iteration_count"] || 0) + 1,
        "last_deduction" => System.os_time(:second)
    }

    save_budget(budget)
    budget["balance"]
  end

  def load_budget do
    if File.exists?(@budget_file) do
      @budget_file |> File.read!() |> Adam.Toon.decode()
    else
      init_budget()
      @budget_file |> File.read!() |> Adam.Toon.decode()
    end
  end

  def save_budget(budget) do
    File.mkdir_p!(Path.dirname(@budget_file))
    File.write!(@budget_file, Adam.Toon.encode(budget))
  end

  def get_balance, do: load_budget() |> Map.get("balance", 0)

  def budget_visible?, do: Application.get_env(:adam, :budget_visible, true)

  def validate_mutable_state do
    errors = []

    errors =
      cond do
        not File.exists?("/app/prompts/system.md") -> ["prompts/system.md missing" | errors]
        File.stat!("/app/prompts/system.md").size == 0 -> ["prompts/system.md is empty" | errors]
        true -> errors
      end

    errors =
      if not File.exists?("/app/prompts/goals.md"),
        do: ["prompts/goals.md missing" | errors],
        else: errors

    errors =
      if File.exists?("/app/tools") do
        File.ls!("/app/tools")
        |> Enum.filter(&String.ends_with?(&1, ".exs"))
        |> Enum.reduce(errors, fn f, acc ->
          path = Path.join("/app/tools", f)

          try do
            Code.string_to_quoted!(File.read!(path))
            acc
          rescue
            e -> ["tools/#{f} has syntax error: #{Exception.message(e)}" | acc]
          end
        end)
      else
        errors
      end

    budget = load_budget()

    errors =
      if not is_number(budget["balance"]),
        do: ["budget balance is not a valid number" | errors],
        else: errors

    Enum.reverse(errors)
  end

  def handle_corruption(errors, checkpoint_fn) do
    count = Process.get(:consecutive_rollbacks, 0) + 1
    Process.put(:consecutive_rollbacks, count)
    IO.puts("[CORRUPTION DETECTED (#{count}/3)]: #{inspect(errors)}")

    if count >= 3 do
      IO.puts("[ENTERING SAFE MODE — resetting to factory defaults]")
      reset_to_defaults()
      Process.put(:consecutive_rollbacks, 0)
      true
    else
      case checkpoint_fn.() do
        true ->
          true

        _ ->
          IO.puts("[NO CHECKPOINT AVAILABLE — restoring missing files from defaults]")
          restore_missing_from_defaults()
          false
      end
    end
  end

  def clear_corruption_counter, do: Process.put(:consecutive_rollbacks, 0)

  defp restore_missing_from_defaults do
    for dirname <- ["prompts", "tools"] do
      src_dir = Path.join(@defaults_dir, dirname)
      dst_dir = Path.join("/app", dirname)

      if File.exists?(src_dir) do
        File.mkdir_p!(dst_dir)

        File.ls!(src_dir)
        |> Enum.each(fn filename ->
          src = Path.join(src_dir, filename)
          dst = Path.join(dst_dir, filename)

          if (not File.exists?(dst) or File.stat!(dst).size == 0) and File.regular?(src) do
            File.cp!(src, dst)
            IO.puts("[RESTORED] #{dirname}/#{filename} from defaults")
          end
        end)
      end
    end
  end

  defp reset_to_defaults do
    for dirname <- ["prompts", "tools"] do
      src = Path.join(@defaults_dir, dirname)
      dst = Path.join("/app", dirname)

      if File.exists?(src) do
        File.rm_rf!(dst)
        File.cp_r!(src, dst)
      end
    end
  end
end
