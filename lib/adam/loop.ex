defmodule Adam.Loop do
  use GenServer

  # Cap on rolling chat history: keep at most this many user turns
  # (each user turn brings its assistant reply + tool result messages).
  @history_user_turns 6

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def reset_history, do: GenServer.cast(__MODULE__, :reset_history)

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
    {:ok, %{iteration: 0, last_checkpoint: System.os_time(:second), messages: []}}
  end

  def handle_cast(:reset_history, state) do
    {:noreply, %{state | messages: []}}
  end

  def handle_info(:iterate, state) do
    iteration = state.iteration + 1
    IO.puts("\n[ITERATION #{iteration}]")

    state = iterate(iteration, state)

    state =
      case Adam.Safety.validate_mutable_state() do
        [] ->
          Adam.Safety.clear_corruption_counter()
          state

        errors ->
          Adam.Safety.handle_corruption(errors, &Adam.Checkpoint.restore_latest/0)
          # Conversation context is stale after rollback / safe-mode reset.
          %{state | messages: []}
      end

    state = maybe_checkpoint(state)

    if rem(iteration, 10) == 0, do: Adam.Psyche.emit_signals()

    state =
      if Adam.Sleep.should_sleep?() do
        Adam.Sleep.run()
        # Fresh start after consolidation.
        %{state | messages: []}
      else
        state
      end

    send(self(), :iterate)
    {:noreply, %{state | iteration: iteration}}
  end

  defp iterate(iteration, state) do
    interrupt_result = Adam.Interrupts.check_all()
    interrupts = interrupt_result.interrupts
    emails = interrupt_result.emails

    {state, goal_changed} =
      Enum.reduce(emails, {state, false}, fn msg, {st, changed} ->
        Adam.Psyche.process_owner_email(msg)
        changed? = handle_owner_email(msg)
        {st, changed or changed?}
      end)

    state = if goal_changed, do: %{state | messages: []}, else: state

    routines = Adam.Scheduler.check_routines()

    if rem(iteration, 30) == 0, do: Adam.Speciation.check()

    psyche_state = Adam.Psyche.prepare(iteration)
    system_prompt = load_system_prompt()
    user_content = build_context(psyche_state, interrupts, routines, iteration)
    tools = Adam.Tools.get_tools_for_llm(psyche_state.allowed_tools)

    tier = determine_tier(interrupts, routines)

    messages = state.messages ++ [%{role: "user", content: user_content}]

    thought =
      Adam.LLM.think_messages(system_prompt, messages, tools,
        tier: tier,
        kind: "agent.think"
      )

    IO.puts("[THOUGHT] #{String.slice(thought.content, 0, 200)}")

    messages =
      messages ++
        [
          %{
            role: "assistant",
            content: thought.content,
            tool_calls: format_tool_calls_for_message(thought.tool_calls)
          }
        ]

    {tool_results, messages} =
      if thought.tool_calls != [] do
        Enum.reduce(thought.tool_calls, {[], messages}, fn %{name: name, arguments: args},
                                                           {acc, msgs} ->
          result = Adam.Tools.execute(name, args)
          IO.puts("[TOOL] #{name}: #{String.slice(to_string(result), 0, 100)}")

          tool_msg = %{role: "tool", name: name, content: to_string(result)}
          {acc ++ [%{name: name, result: to_string(result)}], msgs ++ [tool_msg]}
        end)
      else
        {[], messages}
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

    %{state | messages: trim_history(messages)}
  end

  defp format_tool_calls_for_message([]), do: []

  defp format_tool_calls_for_message(calls) do
    Enum.map(calls, fn %{name: name, arguments: args} ->
      %{
        "type" => "function",
        "function" => %{
          "name" => name,
          "arguments" => args
        }
      }
    end)
  end

  # Keep at most @history_user_turns most-recent user turns, with the
  # assistant + tool messages that follow each. We walk forward, find the
  # cutoff index of the Nth-from-last user message, and drop everything before.
  defp trim_history(messages) do
    user_indices =
      messages
      |> Enum.with_index()
      |> Enum.filter(fn {m, _} -> m.role == "user" end)
      |> Enum.map(fn {_, i} -> i end)

    if length(user_indices) <= @history_user_turns do
      messages
    else
      cutoff = Enum.at(user_indices, length(user_indices) - @history_user_turns)
      Enum.drop(messages, cutoff)
    end
  end

  defp load_system_prompt do
    path = "/app/prompts/system.md"

    if File.exists?(path) do
      File.read!(path)
    else
      "You are ADAM, an autonomous digital agent. Explore your environment and learn."
    end
  end

  # Builds the per-iteration user message. Exactly four sections, each
  # rendered only when it has content:
  #   IDENTITY + STATE  (produced by Adam.Psyche.prepare/1 as `psyche_state.context`)
  #   GOALS             (from /app/prompts/goals.md)
  #   INTERRUPTS        (interrupts + scheduled routines, when present)
  #
  # Tools are passed via the API's `tools:` field; the model sees them through
  # the chat template. Iteration counter and balance are intentionally omitted —
  # budget pressure reaches the model via the felt energy drive in STATE.
  defp build_context(psyche_state, interrupts, routines, _iteration) do
    parts = []

    parts = if psyche_state.context != "", do: parts ++ [psyche_state.context], else: parts

    goals =
      if File.exists?("/app/prompts/goals.md") do
        File.read!("/app/prompts/goals.md") |> String.trim()
      else
        ""
      end

    parts = if goals != "", do: parts ++ ["== GOALS ==\n#{goals}\n== END GOALS =="], else: parts

    interrupt_lines = interrupts ++ routines

    parts =
      if interrupt_lines != [] do
        parts ++
          ["== INTERRUPTS ==\n#{Enum.join(interrupt_lines, "\n")}\n== END INTERRUPTS =="]
      else
        parts
      end

    Enum.join(parts, "\n\n")
  end

  defp determine_tier(interrupts, routines) do
    cond do
      Enum.any?(interrupts, &String.contains?(&1, "[EMAIL")) -> "actor"
      interrupts != [] -> "actor"
      routines != [] -> "actor"
      true -> "thinker"
    end
  end

  # Returns true if the action changed context meaningfully (e.g. new goal),
  # signalling the loop to drop rolling chat history.
  defp handle_owner_email(msg) do
    owner_email = System.get_env("OWNER_EMAIL", "") |> String.downcase() |> String.trim()
    sender = (msg["from"] || "") |> String.downcase() |> String.trim()

    # Only process commands from the owner
    if owner_email != "" and not String.contains?(sender, owner_email) do
      IO.puts("[OWNER] Ignoring command from non-owner: #{sender}")
      false
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
          true

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
          false

        String.upcase(subject) |> String.starts_with?("STAGE:") ->
          Adam.Psyche.advance_stage()
          false

        true ->
          false
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
