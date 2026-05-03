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

    if Adam.Sleep.should_sleep?(), do: Adam.Sleep.run()

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

    if rem(iteration, 30) == 0, do: Adam.Speciation.check()

    psyche_state = Adam.Psyche.prepare(iteration)
    system_prompt = load_system_prompt()
    context = build_context(psyche_state, interrupts, routines, iteration)
    tools = Adam.Tools.get_tools_for_llm(psyche_state.allowed_tools)

    tier = determine_tier(interrupts, routines)

    thought = Adam.LLM.think(system_prompt, context, tools, tier: tier)

    IO.puts("[THOUGHT] #{String.slice(thought.content, 0, 200)}")

    tool_results =
      if thought.tool_calls != [] do
        results =
          Enum.map(thought.tool_calls, fn %{name: name, arguments: args} ->
            result = Adam.Tools.execute(name, args)
            IO.puts("[TOOL] #{name}: #{String.slice(to_string(result), 0, 100)}")
            %{name: name, result: to_string(result)}
          end)

        results
      else
        []
      end

    Adam.Psyche.process(thought, tool_results)

    Adam.Compaction.log_thought(iteration, thought.content, tool_results)
    Adam.Retrospective.check()
    Adam.Compaction.check()

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
    owner_email = System.get_env("OWNER_EMAIL", "") |> String.downcase() |> String.trim()
    sender = (msg["from"] || "") |> String.downcase() |> String.trim()

    # Only process commands from the owner
    if owner_email != "" and not String.contains?(sender, owner_email) do
      IO.puts("[OWNER] Ignoring command from non-owner: #{sender}")
      :ok
    else
      subject = msg["subject"] || ""
      body = msg["body"] || ""
      cond do
        String.upcase(subject) |> String.starts_with?("GOAL:") ->
          goal = subject
            |> String.replace_prefix("GOAL:", "")
            |> String.replace_prefix("goal:", "")
            |> String.trim()
          goal_text = if body != "", do: "#{goal}\n\n#{body}", else: goal
          File.write!("/app/prompts/goals.md", goal_text)
          IO.puts("[OWNER] Goal set: #{goal}")

        String.upcase(subject) |> String.starts_with?("BUDGET:") ->
          amount = subject
            |> String.replace_prefix("BUDGET:", "")
            |> String.replace_prefix("budget:", "")
            |> String.trim()
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
