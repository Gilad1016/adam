defmodule Adam.Loop do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def init(_) do
    Adam.Checkpoint.init_git()
    Adam.Safety.init_budget()
    Adam.Knowledge.init()
    Adam.Scheduler.init()
    Adam.Psyche.init()
    model_status = Adam.LLM.ensure_models()
    IO.puts("[ADAM] Models: #{model_status}")
    IO.puts("[ADAM] Stage: #{Adam.Psyche.get_stage()} (#{Adam.Psyche.get_stage_name()})")
    IO.puts("[ADAM] Balance: $#{Adam.Safety.get_balance()}")
    send(self(), :iterate)
    {:ok, %{iteration: 0, last_checkpoint: System.os_time(:second)}}
  end

  def handle_info(:iterate, state) do
    iteration = state.iteration + 1
    IO.puts("\n[ITERATION #{iteration}]")

    state = iterate(iteration, state)

    case Adam.Safety.validate_mutable_state() do
      [] ->
        Adam.Safety.clear_corruption_counter()

      errors ->
        Adam.Safety.handle_corruption(errors, &Adam.Checkpoint.restore_latest/0)
    end

    state = maybe_checkpoint(state)

    if rem(iteration, 10) == 0, do: Adam.Psyche.emit_signals()

    send(self(), :iterate)
    {:noreply, %{state | iteration: iteration}}
  end

  defp iterate(iteration, state) do
    interrupt_result = Adam.Interrupts.check_all()
    interrupts = interrupt_result.interrupts
    emails = interrupt_result.emails

    Enum.each(emails, fn msg ->
      Adam.Psyche.process_owner_email(msg)
      handle_owner_email(msg)
    end)

    routines = Adam.Scheduler.check_routines()

    if rem(iteration, 20) == 0 do
      # Compaction rewrites thought_log.toon in place (collapses old entries
      # into a single summary entry). Watch that file's size for changes.
      log_path = "/app/memory/thought_log.toon"
      before_size = if File.exists?(log_path), do: File.stat!(log_path).size, else: 0
      Adam.Compaction.check()
      after_size = if File.exists?(log_path), do: File.stat!(log_path).size, else: 0
      if after_size != before_size, do: Adam.Observer.memory_compact(before_size, after_size, iteration)
    end
    if rem(iteration, 30) == 0, do: Adam.Speciation.check()

    psyche_state = Adam.Psyche.prepare(iteration)
    system_prompt = load_system_prompt()
    context = build_context(psyche_state, interrupts, routines, iteration)
    tools = Adam.Tools.get_tools_for_llm(psyche_state.allowed_tools)

    tier = determine_tier(interrupts, routines)

    Adam.Observer.context_built(system_prompt, context, psyche_state.allowed_tools, tier, iteration)
    thought = Adam.LLM.think(system_prompt, context, tools, tier: tier)
    Adam.Observer.thought(thought.content, thought.tokens, thought.tier, thought.cost, length(thought.tool_calls), iteration)

    IO.puts("[THOUGHT] #{String.slice(thought.content, 0, 200)}")

    tool_results =
      if thought.tool_calls != [] do
        results =
          Enum.map(thought.tool_calls, fn %{name: name, arguments: args} ->
            t0 = System.monotonic_time(:millisecond)
            result = Adam.Tools.execute(name, args)
            duration_ms = System.monotonic_time(:millisecond) - t0
            IO.puts("[TOOL] #{name}: #{String.slice(to_string(result), 0, 100)}")
            Adam.Observer.tool_call(name, args, result, iteration, tier, duration_ms)
            %{name: name, result: to_string(result)}
          end)

        results
      else
        []
      end

    Adam.Psyche.process(thought, tool_results)

    exp_path = "/app/memory/thought_log.toon"
    old_size = if File.exists?(exp_path), do: File.stat!(exp_path).size, else: 0
    Adam.Compaction.log_thought(iteration, thought.content, tool_results)
    new_size = if File.exists?(exp_path), do: File.stat!(exp_path).size, else: 0
    Adam.Observer.memory_update(exp_path, old_size, new_size, iteration)

    balance = Adam.Safety.deduct_electricity(thought.cost)
    IO.puts("[BUDGET] $#{Float.round(balance, 2)} remaining (#{thought.tier})")

    if balance <= 0 do
      IO.puts("[ADAM] Budget exhausted. Shutting down.")
      System.halt(0)
    end

    state
  end

  defp load_system_prompt do
    path = "/app/prompts/system.md"

    if File.exists?(path) do
      File.read!(path)
    else
      "You are ADAM, an autonomous digital agent. Explore your environment and learn."
    end
  end

  defp build_context(psyche_state, interrupts, routines, iteration) do
    parts = []

    parts = if psyche_state.context != "", do: parts ++ [psyche_state.context], else: parts

    parts =
      if interrupts != [] do
        parts ++ ["== INTERRUPTS ==\n#{Enum.join(interrupts, "\n")}\n== END INTERRUPTS =="]
      else
        parts
      end

    parts =
      if routines != [] do
        parts ++ ["== ROUTINES ==\n#{Enum.join(routines, "\n")}\n== END ROUTINES =="]
      else
        parts
      end

    goals =
      if File.exists?("/app/prompts/goals.md") do
        File.read!("/app/prompts/goals.md")
      else
        ""
      end

    parts = if goals != "", do: parts ++ ["== GOALS ==\n#{goals}\n== END GOALS =="], else: parts

    tools_summary = Adam.Tools.get_tools_summary(psyche_state.allowed_tools)
    parts = parts ++ ["== AVAILABLE TOOLS ==\n#{tools_summary}\n== END TOOLS =="]

    if Adam.Safety.budget_visible?() do
      parts = parts ++ ["Iteration: #{iteration}. Balance: $#{Adam.Safety.get_balance()}"]
      Enum.join(parts, "\n\n")
    else
      Enum.join(parts, "\n\n")
    end
  end

  defp determine_tier(interrupts, routines) do
    cond do
      Enum.any?(interrupts, &String.contains?(&1, "[EMAIL")) -> "actor"
      interrupts != [] -> "actor"
      routines != [] -> "actor"
      true -> "thinker"
    end
  end

  defp handle_owner_email(msg) do
    subject = msg["subject"] || ""
    body = msg["body"] || ""
    cond do
      String.upcase(subject) |> String.starts_with?("GOAL:") ->
        goal = String.trim_leading(subject, "GOAL:") |> String.trim_leading("goal:") |> String.trim()
        goal_text = if body != "", do: "#{goal}\n\n#{body}", else: goal
        File.write!("/app/prompts/goals.md", goal_text)
        IO.puts("[OWNER] Goal set: #{goal}")
        Adam.Observer.goal_update(goal_text, 0)

      String.upcase(subject) |> String.starts_with?("BUDGET:") ->
        amount = subject |> String.replace(~r/^BUDGET:\s*/i, "") |> String.trim()
        case Float.parse(amount) do
          {val, _} ->
            budget = Adam.Safety.load_budget()
            budget = Map.merge(budget, %{"balance" => budget["balance"] + val, "initial" => budget["initial"] + val})
            Adam.Safety.save_budget(budget)
            IO.puts("[OWNER] Budget added: $#{val}")
          _ ->
            IO.puts("[OWNER] Invalid budget amount: #{amount}")
        end

      String.upcase(subject) |> String.starts_with?("STAGE:") ->
        Adam.Psyche.advance_stage()

      true ->
        :ok
    end
  end

  defp maybe_checkpoint(state) do
    if Adam.Checkpoint.should_checkpoint(state.last_checkpoint) do
      Adam.Checkpoint.snapshot()
      IO.puts("[CHECKPOINT] Snapshot saved")
      %{state | last_checkpoint: System.os_time(:second)}
    else
      state
    end
  end
end
