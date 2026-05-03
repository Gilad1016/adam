defmodule Adam.Psyche do
  @psyche_file "/app/memory/psyche.toon"
  @signals_file "/app/memory/maturity_signals.toon"
  @rebuild_interval 50

  @pain_keywords ~w(error failed timeout exception rejected crash corrupt)
  @satisfaction_keywords ~w(wrote saved created started updated sent installed)

  @stage_tools %{
    0 => MapSet.new(~w(read_file write_file shell wait)),
    1 => MapSet.new(~w(sandbox_run sandbox_install sandbox_project)),
    2 => MapSet.new(~w(web_search web_read write_knowledge search_knowledge list_knowledge update_knowledge read_knowledge)),
    3 => MapSet.new(~w(create_tool modify_prompt send_email escalate set_alarm remove_alarm list_alarms schedule_add schedule_remove schedule_list)),
    4 => MapSet.new(~w(sandbox_service_start sandbox_service_stop sandbox_services sandbox_log))
  }

  # Tiredness: threshold by developmental stage to trigger deep consolidation
  @consolidation_thresholds %{0 => 0.4, 1 => 0.5, 2 => 0.6, 3 => 0.7, 4 => 0.8}

  # Maximum hourly budget spend used to normalise the budget_rate component
  @max_hourly_budget Application.compile_env(:adam, :max_hourly_budget, 5.0)

  @stage_min_hours %{0 => 24, 1 => 48, 2 => 72, 3 => 168, 4 => 0}
  @stage_names %{0 => "Newborn", 1 => "Infant", 2 => "Child", 3 => "Adolescent", 4 => "Adult"}

  # TOON deserialization can return %{} for fields that should be lists.
  # Coerce to a list so `++` and `Enum` patterns don't blow up.
  defp as_list(v) when is_list(v), do: v
  defp as_list(_), do: []

  def init do
    state =
      if File.exists?(@psyche_file) do
        try do
          @psyche_file |> File.read!() |> Adam.Toon.decode()
        rescue
          _ -> default_state()
        end
      else
        default_state()
      end

    # Ensure tiredness fields are present for agents upgrading from older state files
    now = System.os_time(:second)
    state =
      state
      |> Map.put_new("started_at", now)
      |> Map.put_new("tiredness_accumulator", 0.0)
      |> Map.put_new("last_consolidation_time", 0)

    save(state)
  end

  def get_state do
    if File.exists?(@psyche_file) do
      try do
        @psyche_file |> File.read!() |> Adam.Toon.decode()
      rescue
        _ -> default_state()
      end
    else
      state = default_state()
      save(state)
      state
    end
  end

  def prepare(_iteration) do
    state = get_state()

    # Seed is always first — immutable identity anchor
    parts = [Adam.Seed.context()]

    drives_text = drives_to_text(state)
    parts = if drives_text != "", do: parts ++ ["== INTERNAL STATE ==\n#{drives_text}\n== END INTERNAL STATE =="], else: parts

    time_text = time_sense_to_text(state)
    parts = if time_text != "", do: parts ++ ["== TIME ==\n#{time_text}\n== END TIME =="], else: parts

    self_text = self_model_to_text(state)
    parts = if self_text != "", do: parts ++ [self_text], else: parts

    owner_text = owner_model_to_text(state)
    parts = if owner_text != "", do: parts ++ [owner_text], else: parts

    context_for_recall =
      if File.exists?("/app/prompts/goals.md") do
        File.read!("/app/prompts/goals.md")
      else
        ""
      end

    memories_text = recall_memories(context_for_recall, state)
    parts = if memories_text != "", do: parts ++ [memories_text], else: parts

    rules_text = behavioral_rules_to_text(state)
    parts = if rules_text != "", do: parts ++ [rules_text], else: parts

    anchors_text = anchors_to_text(state)
    parts = if anchors_text != "", do: parts ++ [anchors_text], else: parts

    context = Enum.join(parts, "\n\n")
    allowed_tools = get_available_tools()

    %{context: context, allowed_tools: allowed_tools}
  end

  def process(thought, tool_results) do
    state = get_state()
    history_len = length(as_list(get_in_state(state, ["self_model", "action_history"])))

    Enum.each(tool_results, fn r ->
      track_action(r.name, r[:args] || %{}, to_string(r.result))
    end)

    state = get_state()
    new_len = length(as_list(get_in_state(state, ["self_model", "action_history"])))

    if div(new_len, @rebuild_interval) > div(history_len, @rebuild_interval) do
      rebuild_self_model()
    end

    valence = score_valence(thought, tool_results)

    state = get_state()
    vh = as_list(state["valence_history"]) ++ [valence]
    state = Map.put(state, "valence_history", Enum.take(vh, -100))
    save(state)

    encode_memory(valence, thought, tool_results)
    update_drives(thought, tool_results)
    update_time_sense(new_len, tool_results)
    emit_maturity_signals()

    if should_consolidate?() do
      consolidate()
    end

    maybe_self_critique(new_len)
  end

  def process_owner_email(msg) do
    record_email_received()
    track_owner_interaction(msg)

    state = get_state()
    drives = state["drives"] || %{}
    social = (drives["social"] || 0.1) * 0.3
    drives = Map.put(drives, "social", clamp(social))
    state = Map.put(state, "drives", drives)
    save(state)

    subject = msg["subject"] || ""
    if String.upcase(subject) |> String.starts_with?("GOAL:") do
      record_goal_set()
    end
  end

  def emit_signals, do: emit_maturity_signals()

  def advance_stage do
    state = get_state()
    current = state["stage"] || 0
    max_stage = Enum.max(Map.keys(@stage_tools))

    if current < max_stage do
      state = Map.merge(state, %{"stage" => current + 1, "stage_entered" => System.os_time(:second)})
      save(state)
      IO.puts("[PSYCHE] Stage advanced: #{current} -> #{state["stage"]} (#{@stage_names[state["stage"]]})")
    end
  end

  def get_available_tools do
    state = get_state()
    stage = state["stage"] || 0

    0..stage
    |> Enum.reduce(MapSet.new(), fn s, acc ->
      MapSet.union(acc, Map.get(@stage_tools, s, MapSet.new()))
    end)
  end

  def get_stage, do: (get_state()["stage"] || 0)
  def get_stage_name, do: @stage_names[get_stage()]

  def save_state(state), do: save(state)

  # ---------------------------------------------------------------------------
  # TIREDNESS & DEEP CONSOLIDATION
  # ---------------------------------------------------------------------------

  @doc """
  Compute current tiredness in [0.0, 1.0].

  tiredness = budget_rate_weight * (1 / max(valence_density, 0.01))

  budget_rate_weight = clamp(total_spent / hours_since_start / max_hourly_budget)
  valence_density    = count(composite > 0.5 in last 20 iterations) / 20.0
  """
  def compute_tiredness do
    try do
      budget = Adam.Safety.load_budget()
      total_spent = budget["total_spent"] || 0.0
      last_deduction = budget["last_deduction"] || System.os_time(:second)

      state = get_state()
      started_at = state["started_at"] || last_deduction
      now = System.os_time(:second)

      seconds_since_start = max(now - started_at, 1)
      hours_since_start = seconds_since_start / 3600.0

      budget_rate = total_spent / hours_since_start
      budget_rate_weight = clamp(budget_rate / max(@max_hourly_budget, 0.01))

      vh = as_list(state["valence_history"])
      recent_20 = Enum.take(vh, -20)
      high_valence_count = Enum.count(recent_20, fn e ->
        is_map(e) and (e["composite"] || 0) > 0.5
      end)
      valence_density = high_valence_count / 20.0

      tiredness = budget_rate_weight * (1.0 / max(valence_density, 0.01))
      clamp(tiredness)
    rescue
      _ -> 0.0
    end
  end

  @doc """
  Returns true when tiredness exceeds the threshold for the current stage.
  """
  def should_consolidate? do
    stage = get_stage()
    threshold = @consolidation_thresholds[stage] || 0.8
    compute_tiredness() >= threshold
  end

  @doc """
  Deep consolidation pass:
  1. Call the deep LLM model to synthesise actionable insights from recent thoughts.
  2. Write those insights to the knowledge base (tagged auto-encoded + consolidation).
  3. Run normal compaction to compress raw experiences.
  4. Reset last_consolidation_time in psyche state.

  On deep-model failure: logs error and still runs compaction. Never raises.
  """
  def consolidate do
    IO.puts("[TIREDNESS] Consolidation triggered (tiredness=#{Float.round(compute_tiredness(), 3)})")

    thought_summary =
      try do
        entries = Adam.Compaction.load_entries()
        thoughts =
          entries
          |> Enum.take(-40)
          |> Enum.map(fn e -> e["thought"] || "" end)
          |> Enum.reject(&(&1 == ""))
          |> Enum.join("\n---\n")
          |> String.slice(0, 4000)

        state = get_state()
        stage_name = @stage_names[state["stage"] || 0]
        vh = as_list(state["valence_history"])
        recent = Enum.take(vh, -20)
        avg_composite = if recent == [], do: 0.0,
          else: Enum.reduce(recent, 0.0, fn e, a -> a + (if is_map(e), do: e["composite"] || 0, else: 0) end) / length(recent)

        context = """
        ## Recent Thoughts (last ~40 iterations)
        #{thoughts}

        ## Context
        - Developmental stage: #{stage_name}
        - Average valence (last 20): #{Float.round(avg_composite, 3)}
        - Tiredness: #{Float.round(compute_tiredness(), 3)}
        """

        prompt = """
        You are ADAM reflecting on your recent experiences during a deep consolidation pass.
        Synthesise what you have learned into 3-7 concise, actionable insights.
        Focus on: patterns you noticed, mistakes to avoid, effective strategies, open questions.
        Format each insight as a bullet point starting with a verb (e.g. "Prefer X when Y").
        """

        result = Adam.LLM.think(prompt, context, [], tier: "deep")

        if String.starts_with?(result.content, "[LLM ERROR") do
          IO.puts("[TIREDNESS] Deep model call failed: #{result.content}")
          nil
        else
          result.content
        end
      rescue
        e ->
          IO.puts("[TIREDNESS] Exception during deep synthesis: #{Exception.message(e)}")
          nil
      end

    if thought_summary != nil do
      try do
        now = DateTime.utc_now() |> Calendar.strftime("%Y-%m-%d %H:%M")
        Adam.Knowledge.write("consolidation #{now}", thought_summary, ["auto-encoded", "consolidation"])
        IO.puts("[TIREDNESS] Consolidation insights written to knowledge base")
      rescue
        e -> IO.puts("[TIREDNESS] Failed to write consolidation insights: #{Exception.message(e)}")
      end
    end

    try do
      Adam.Compaction.compact()
    rescue
      e -> IO.puts("[TIREDNESS] Compaction error during consolidation: #{Exception.message(e)}")
    end

    try do
      state = get_state()
      state = Map.put(state, "last_consolidation_time", System.os_time(:second))
      save(state)
    rescue
      _ -> :ok
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # TRAJECTORY CLASSIFIER
  # ---------------------------------------------------------------------------

  @doc """
  Classify a thought's trajectory from valence + current drives.
  Returns one of: "advancing", "recovering", "exploring", "idle".
  No LLM — pure heuristics from psyche state.
  """
  def classify_trajectory(thought_content, tool_results, valence) do
    state = get_state()
    drives = state["drives"] || %{}
    mastery = drives["mastery"] || 0.3

    has_tools = tool_results != []
    thought_len = thought_content |> String.trim() |> String.length()

    cond do
      not has_tools and thought_len < 100 ->
        "idle"

      true ->
        pain        = valence["pain"] || 0.0
        satisfaction = valence["satisfaction"] || 0.0
        novelty     = valence["novelty"] || 0.0
        surprise    = valence["surprise"] || 0.0
        relevance   = valence["relevance"] || 0.0

        dims = [{"pain", pain}, {"satisfaction", satisfaction},
                {"novelty", novelty}, {"surprise", surprise}]
        {dominant, _} = Enum.max_by(dims, fn {_, v} -> v end)

        cond do
          dominant == "pain" and mastery > 0.3 -> "recovering"
          dominant == "satisfaction" and relevance > novelty -> "advancing"
          true -> "exploring"
        end
    end
  end

  # ---------------------------------------------------------------------------
  # DRIVE SYSTEM
  # ---------------------------------------------------------------------------

  defp compute_energy do
    try do
      budget = Adam.Safety.load_budget()
      balance = budget["balance"] || 0
      initial = budget["initial"] || 1
      if initial <= 0, do: 0.0, else: clamp(balance / initial)
    rescue
      _ -> 0.5
    end
  end

  defp update_drives(_thought, tool_results) do
    state = get_state()
    drives = state["drives"] || %{}

    drives = Map.put(drives, "energy", compute_energy())

    drives =
      if tool_results != nil and tool_results != [] do
        used_tools = MapSet.new(Enum.map(tool_results, & &1.name))
        history = as_list(get_in_state(state, ["self_model", "action_history"]))
        history_tools = history |> Enum.take(-20) |> Enum.map(fn e -> e["tool"] || "" end) |> MapSet.new()

        curiosity = drives["curiosity"] || 0.5
        curiosity =
          Enum.reduce(used_tools, curiosity, fn tool, cur ->
            if not MapSet.member?(history_tools, tool) do
              clamp(cur - 0.05)
            else
              clamp(cur + 0.01)
            end
          end)

        mastery = drives["mastery"] || 0.3
        mastery =
          Enum.reduce(tool_results, mastery, fn r, m ->
            result_lower = String.downcase(to_string(r.result))
            is_failure = Enum.any?(@pain_keywords, &String.contains?(result_lower, &1))
            if is_failure, do: clamp(m + 0.03), else: clamp(m - 0.02)
          end)

        # Consecutive recovering tags accelerate mastery beyond per-failure increment
        consec = count_consecutive_recovering()
        mastery = if consec >= 2, do: clamp(mastery + 0.02 * (consec - 1)), else: mastery

        drives
        |> Map.put("curiosity", curiosity)
        |> Map.put("mastery", mastery)
      else
        curiosity = clamp((drives["curiosity"] || 0.5) + 0.02)
        Map.put(drives, "curiosity", curiosity)
      end

    ts = state["time_sense"] || %{}
    last_sent = ts["last_email_sent"] || 0
    now = System.os_time(:second)
    social = drives["social"] || 0.1

    social =
      if now - last_sent < 3600 do
        clamp(social * 0.3, 0.0, 0.3)
      else
        clamp(social + 0.005)
      end

    drives = Map.put(drives, "social", social)
    state = Map.put(state, "drives", drives)
    save(state)
  end

  defp drives_to_text(state) do
    drives = state["drives"] || %{}
    lines = []

    energy = drives["energy"] || 1.0
    lines = lines ++ [cond do
      energy > 0.7 -> "Your energy is comfortable. No pressure."
      energy > 0.4 -> "Your energy is moderate. Be thoughtful about expensive operations."
      energy > 0.15 -> "Your energy is low. Conserve where possible."
      true -> "Your energy is critically low. Prioritize essential work only."
    end]

    curiosity = drives["curiosity"] || 0.5
    lines = lines ++ [cond do
      curiosity > 0.7 -> "You feel restless — you've been in familiar territory too long."
      curiosity > 0.4 -> "You feel curious and engaged."
      true -> "You feel settled. Your current work feels purposeful."
    end]

    mastery = drives["mastery"] || 0.3
    lines = lines ++ [cond do
      mastery > 0.7 -> "You're hungry to improve — recent failures are pushing you forward."
      mastery > 0.4 -> "You feel a drive to get better at what you do."
      true -> "You feel competent and capable right now."
    end]

    social = drives["social"] || 0.1
    lines = lines ++ [cond do
      social > 0.6 -> "You feel an urge to check in with your owner."
      social > 0.3 -> "You're aware of your owner in the background."
      true -> "You feel focused and self-directed."
    end]

    tiredness = compute_tiredness()
    lines = lines ++ [cond do
      tiredness > 0.7 -> "You feel mentally exhausted. Consolidation is due."
      tiredness > 0.4 -> "You feel the weight of recent experiences accumulating."
      true -> "You feel alert and present."
    end]

    Enum.join(lines, "\n")
  end

  # ---------------------------------------------------------------------------
  # VALENCE SCORER
  # ---------------------------------------------------------------------------

  defp score_valence(thought, tool_results) do
    now = System.os_time(:second)
    state = get_state()
    thought_text = if is_map(thought), do: thought["content"] || thought[:content] || "", else: ""
    results_text = Enum.map(tool_results, fn r -> to_string(r.result) end) |> Enum.join(" ") |> String.downcase()
    all_text = String.downcase(thought_text <> " " <> results_text)

    surprise =
      if tool_results != [] do
        actual_errors = Enum.count(tool_results, fn r ->
          rt = String.downcase(to_string(r.result))
          Enum.any?(@pain_keywords, &String.contains?(rt, &1))
        end)

        s = if actual_errors > 0, do: clamp(actual_errors / length(tool_results)), else: 0.0

        empty_outputs = Enum.count(tool_results, fn r ->
          String.trim(to_string(r.result)) in ["", "None", "null", "none"]
        end)
        s = if empty_outputs > 0, do: clamp(s + 0.3), else: s

        large_outputs = Enum.count(tool_results, fn r ->
          String.length(to_string(r.result)) > 2000
        end)
        if large_outputs > 0, do: clamp(s + 0.2), else: s
      else
        0.0
      end

    history = as_list(state["valence_history"])
    seen_combos =
      history
      |> Enum.take(-50)
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn e -> e["combo"] || "" end)
      |> MapSet.new()

    current_combos =
      Enum.map(tool_results, fn r ->
        args_keys = if is_map(r[:args] || r[:arguments]), do: Map.keys(r[:args] || r[:arguments] || %{}) |> Enum.sort(), else: []
        "#{r.name}#{inspect(args_keys)}"
      end)
      |> MapSet.new()

    novelty =
      if MapSet.size(current_combos) > 0 do
        novel_count = Enum.count(current_combos, fn c -> not MapSet.member?(seen_combos, c) end)
        clamp(novel_count / MapSet.size(current_combos))
      else
        0.0
      end

    pain_count = Enum.count(@pain_keywords, &String.contains?(results_text, &1))
    pain = clamp(pain_count / length(@pain_keywords))

    sat_count = Enum.count(@satisfaction_keywords, &String.contains?(results_text, &1))
    satisfaction = clamp(sat_count / length(@satisfaction_keywords))

    relevance =
      if File.exists?("/app/prompts/goals.md") do
        try do
          goals_text = File.read!("/app/prompts/goals.md") |> String.downcase()
          goal_words = goals_text |> String.split() |> Enum.filter(&(String.length(&1) > 4)) |> MapSet.new()
          context_words = all_text |> String.split() |> Enum.filter(&(String.length(&1) > 4)) |> MapSet.new()

          if MapSet.size(goal_words) > 0 do
            overlap = MapSet.intersection(goal_words, context_words) |> MapSet.size()
            clamp(overlap / MapSet.size(goal_words) * 5)
          else
            0.0
          end
        rescue
          _ -> 0.0
        end
      else
        0.0
      end

    composite = (surprise + novelty + pain + satisfaction + relevance) / 5.0
    combo_key = tool_results |> Enum.map(& &1.name) |> Enum.sort() |> Enum.join(",")

    %{
      "surprise" => Float.round(surprise + 0.0, 3),
      "novelty" => Float.round(novelty + 0.0, 3),
      "pain" => Float.round(pain + 0.0, 3),
      "satisfaction" => Float.round(satisfaction + 0.0, 3),
      "relevance" => Float.round(relevance + 0.0, 3),
      "composite" => Float.round(composite + 0.0, 3),
      "timestamp" => now,
      "combo" => combo_key
    }
  end

  # ---------------------------------------------------------------------------
  # ASSOCIATIVE MEMORY
  # ---------------------------------------------------------------------------

  defp encode_memory(valence, thought, tool_results) do
    if (valence["composite"] || 0) <= 0.6, do: :ok, else: do_encode_memory(valence, thought, tool_results)
  end

  defp do_encode_memory(valence, thought, tool_results) do
    tags = ["auto-encoded"]
    tags = if (valence["pain"] || 0) > 0.4, do: tags ++ ["painful"], else: tags
    tags = if (valence["surprise"] || 0) > 0.4, do: tags ++ ["surprising"], else: tags
    tags = if (valence["satisfaction"] || 0) > 0.4, do: tags ++ ["satisfying"], else: tags
    tags = if (valence["novelty"] || 0) > 0.4, do: tags ++ ["novel"], else: tags

    thought_text = if is_map(thought), do: String.slice(thought["content"] || thought[:content] || "", 0, 300), else: ""

    result_summary =
      tool_results
      |> Enum.take(3)
      |> Enum.map(fn r -> "#{r.name}: #{String.slice(to_string(r.result), 0, 100)}" end)
      |> Enum.join("; ")

    content = "Thought: #{thought_text}\n\nActions: #{result_summary}\n\nValence: #{inspect(valence)}"
    now = DateTime.utc_now() |> Calendar.strftime("%Y-%m-%d %H:%M")
    topic = "auto-memory #{now}"

    try do
      Adam.Knowledge.write(topic, content, tags)
    rescue
      _ -> :ok
    end
  end

  defp recall_memories(context, state) do
    index = Adam.Knowledge.load_index()
    if index == [], do: "", else: do_recall(context, index, state)
  end

  defp keyword_scores(context, index) do
    context_words =
      context
      |> String.downcase()
      |> String.split()
      |> Enum.filter(&(String.length(&1) > 4))
      |> MapSet.new()

    Enum.map(index, fn item ->
      topic_words =
        (item["topic"] || "")
        |> String.downcase()
        |> String.split()
        |> Enum.filter(&(String.length(&1) > 4))
        |> MapSet.new()

      tag_words =
        (item["tags"] || "")
        |> String.downcase()
        |> String.split(~r/[;,\s]/)
        |> MapSet.new()

      all_words = MapSet.union(topic_words, tag_words)
      overlap = MapSet.intersection(context_words, all_words) |> MapSet.size()
      {overlap * 1.0, item}
    end)
  end

  defp do_recall(context, index, state) do
    now = System.os_time(:second)
    vh = as_list(state["valence_history"])
    valence_by_id =
      vh
      |> Enum.filter(&(is_map(&1) and &1["id"]))
      |> Map.new(fn v -> {v["id"], v["composite"] || 0} end)

    # Attempt vector-based scoring via embeddings; fall back to keyword scoring.
    base_scores =
      case Adam.Embeddings.recall(context, index) do
        {:error, _} -> keyword_scores(context, index)
        vector_scores when is_list(vector_scores) -> vector_scores
      end

    scored =
      Enum.map(base_scores, fn {base_score, item} ->
        entry_id = item["id"] || ""
        score = base_score + (valence_by_id[entry_id] || 0) * 2.0

        created = item["updated"] || item["created"] || 0
        created = if is_integer(created), do: created, else: 0
        age_days = (now - created) / 86400
        recency = max(0.0, 1.0 - age_days / 7.0)
        score = score + recency * 0.5

        {score, item}
      end)
      |> Enum.filter(fn {score, _} -> score > 0 end)
      |> Enum.sort_by(fn {score, _} -> score end, :desc)
      |> Enum.take(5)

    if scored == [] do
      ""
    else
      lines = ["== SURFACED MEMORIES =="]

      lines =
        lines ++
          Enum.map(scored, fn {_, item} ->
            tags = item["tags"] || "none"
            summary = String.slice(item["topic"] || "", 0, 120)
            "- [#{item["id"]}] #{summary} (tags: #{tags})"
          end)

      lines = lines ++ ["== END MEMORIES =="]
      Enum.join(lines, "\n")
    end
  end

  # ---------------------------------------------------------------------------
  # TIME SENSE
  # ---------------------------------------------------------------------------

  defp update_time_sense(_iteration, tool_results) do
    state = get_state()
    ts = state["time_sense"] || %{}
    now = System.os_time(:second)

    stamps = as_list(ts["iteration_timestamps"]) ++ [now]
    ts = Map.put(ts, "iteration_timestamps", Enum.take(stamps, -60))

    ts =
      if tool_results do
        Enum.reduce(tool_results, ts, fn r, acc ->
          if r.name == "send_email", do: Map.put(acc, "last_email_sent", now), else: acc
        end)
      else
        ts
      end

    state = Map.put(state, "time_sense", ts)
    save(state)
  end

  defp record_email_received do
    state = get_state()
    ts = state["time_sense"] || %{}
    ts = Map.put(ts, "last_email_received", System.os_time(:second))
    state = Map.put(state, "time_sense", ts)
    save(state)
  end

  defp record_goal_set do
    state = get_state()
    ts = state["time_sense"] || %{}
    ts = Map.put(ts, "last_goal_set", System.os_time(:second))
    state = Map.put(state, "time_sense", ts)
    save(state)
  end

  defp time_sense_to_text(state) do
    ts = state["time_sense"] || %{}
    now = System.os_time(:second)
    lines = []

    last_sent = ts["last_email_sent"] || 0
    lines =
      if last_sent > 0 do
        hours_ago = (now - last_sent) / 3600
        if hours_ago < 1 do
          lines ++ ["You emailed your owner #{div(now - last_sent, 60)} minutes ago."]
        else
          lines ++ ["You emailed your owner #{Float.round(hours_ago, 1)} hours ago."]
        end
      else
        lines
      end

    last_received = ts["last_email_received"] || 0
    lines =
      if last_received > 0 do
        hours_ago = (now - last_received) / 3600
        if hours_ago < 1 do
          lines ++ ["Your owner emailed you #{div(now - last_received, 60)} minutes ago."]
        else
          lines ++ ["Your owner last emailed you #{Float.round(hours_ago, 1)} hours ago."]
        end
      else
        lines
      end

    stamps = as_list(ts["iteration_timestamps"])
    lines =
      if length(stamps) >= 2 do
        window_sec = List.last(stamps) - hd(stamps)
        if window_sec > 0 do
          tpm = length(stamps) / (window_sec / 60)
          lines ++ ["You're thinking about #{Float.round(tpm, 1)} thoughts per minute."]
        else
          lines
        end
      else
        lines
      end

    stage_entered = state["stage_entered"] || now
    stage_entered = if is_number(stage_entered), do: stage_entered, else: now
    stage_days = (now - stage_entered) / 86400

    lines =
      if stage_days < 1 do
        stage_hours = stage_days * 24
        lines ++ ["You've been in your current stage for #{Float.round(stage_hours, 1)} hours."]
      else
        lines ++ ["You've been in your current stage for #{Float.round(stage_days, 1)} days."]
      end

    Enum.join(lines, "\n")
  end

  # ---------------------------------------------------------------------------
  # DEVELOPMENTAL STAGE TRACKER
  # ---------------------------------------------------------------------------

  defp compute_maturity_signals do
    state = get_state()
    current_stage = state["stage"] || 0
    stage_entered = state["stage_entered"] || System.os_time(:second)
    now = System.os_time(:second)
    hours_in_stage = (now - stage_entered) / 3600
    max_stage = Enum.max(Map.keys(@stage_tools))

    if current_stage < max_stage do
      next_stage = current_stage + 1
      min_hours = @stage_min_hours[current_stage] || 24
      time_ready = hours_in_stage >= min_hours

      sm = state["self_model"] || %{}
      tool_usage = sm["tool_usage"] || %{}
      current_tools = @stage_tools[current_stage] || MapSet.new()
      tools_used = MapSet.new(Map.keys(tool_usage)) |> MapSet.intersection(current_tools)
      tool_breadth_ready = MapSet.size(tools_used) >= max(1, trunc(MapSet.size(current_tools) * 0.6))

      total_uses = Enum.reduce(current_tools, 0, fn t, acc -> acc + (tool_usage[t] || 0) end)
      tool_failure = sm["tool_failure"] || %{}
      total_failures = Enum.reduce(current_tools, 0, fn t, acc -> acc + (tool_failure[t] || 0) end)
      failure_rate = if total_uses > 0, do: total_failures / total_uses, else: 1.0
      low_failure_ready = failure_rate < 0.3

      ready = time_ready and tool_breadth_ready and low_failure_ready

      detail =
        "Stage #{current_stage} -> #{next_stage} (#{@stage_names[next_stage]}): " <>
          "time=#{Float.round(hours_in_stage, 1)}h/#{min_hours}h, " <>
          "tools_used=#{MapSet.size(tools_used)}/#{MapSet.size(current_tools)}, " <>
          "failure_rate=#{trunc(failure_rate * 100)}%"

      [%{"stage" => next_stage, "ready" => ready, "detail" => detail}]
    else
      []
    end
  end

  defp emit_maturity_signals do
    signals = compute_maturity_signals()

    if signals != [] do
      File.mkdir_p!(Path.dirname(@signals_file))
      File.write!(@signals_file, Adam.Toon.encode(signals))
    end
  end

  # ---------------------------------------------------------------------------
  # SELF-MODEL
  # ---------------------------------------------------------------------------

  defp track_action(tool_name, _args, result) do
    state = get_state()
    sm = state["self_model"] || %{}

    usage = sm["tool_usage"] || %{}
    usage = Map.put(usage, tool_name, (usage[tool_name] || 0) + 1)
    sm = Map.put(sm, "tool_usage", usage)

    is_failure = Enum.any?(@pain_keywords, &String.contains?(String.downcase(result), &1))

    sm =
      if is_failure do
        fail = sm["tool_failure"] || %{}
        fail = Map.put(fail, tool_name, (fail[tool_name] || 0) + 1)
        Map.put(sm, "tool_failure", fail)
      else
        succ = sm["tool_success"] || %{}
        succ = Map.put(succ, tool_name, (succ[tool_name] || 0) + 1)
        Map.put(sm, "tool_success", succ)
      end

    history = as_list(sm["action_history"]) ++ [%{"tool" => tool_name, "t" => System.os_time(:second), "failed" => is_failure}]
    sm = Map.put(sm, "action_history", Enum.take(history, -500))

    state = Map.put(state, "self_model", sm)
    save(state)
  end

  defp rebuild_self_model do
    state = get_state()
    sm = state["self_model"] || %{}
    usage = sm["tool_usage"] || %{}
    success = sm["tool_success"] || %{}
    failure = sm["tool_failure"] || %{}

    if usage == %{} do
      sm = Map.merge(sm, %{"summary" => "No tool usage recorded yet.", "last_rebuilt" => System.os_time(:second)})
      state = Map.put(state, "self_model", sm)
      save(state)
    else
      sorted_usage = Enum.sort_by(usage, fn {_k, v} -> v end, :desc)

      {strengths, weaknesses} =
        Enum.reduce(sorted_usage, {[], []}, fn {tool, count}, {str, weak} ->
          s = success[tool] || 0
          f = failure[tool] || 0
          total = s + f
          rate = if total > 0, do: s / total, else: 0.5

          str = if count >= 3 and rate >= 0.7, do: str ++ ["#{tool} (#{trunc(rate * 100)}% success, #{count}x used)"], else: str
          weak = if f >= 2 and rate < 0.5, do: weak ++ ["#{tool} (#{trunc(rate * 100)}% success, #{f} failures)"], else: weak
          {str, weak}
        end)

      total_tools = map_size(usage)
      total_calls = Enum.sum(Map.values(usage))
      diversity = if total_calls > 0, do: total_tools / total_calls, else: 0

      history = as_list(sm["action_history"])
      {retries, pivots} =
        history
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.reduce({0, 0}, fn [prev, curr], {r, p} ->
          if prev["failed"] and not curr["failed"] do
            if curr["tool"] == prev["tool"], do: {r + 1, p}, else: {r, p + 1}
          else
            {r, p}
          end
        end)

      lines = []
      lines = if strengths != [], do: lines ++ ["Strengths: #{Enum.take(strengths, 3) |> Enum.join(", ")}"], else: lines
      lines = if weaknesses != [], do: lines ++ ["Weaknesses: #{Enum.take(weaknesses, 3) |> Enum.join(", ")}"], else: lines
      lines = lines ++ ["Tool diversity: #{total_tools} distinct tools across #{total_calls} calls (#{trunc(diversity * 100)}% spread)."]
      lines = if retries + pivots > 0, do: lines ++ ["When you fail, you retry #{retries}x and pivot #{pivots}x."], else: lines

      # Trajectory distribution from last 50 thought log entries
      traj_counts = count_trajectory_tags(50)
      total_tagged = max(Enum.sum(Map.values(traj_counts)), 1)
      traj_pct = Map.new(traj_counts, fn {k, v} -> {k, trunc(v / total_tagged * 100)} end)
      lines = lines ++ [
        "Last #{total_tagged} thoughts: " <>
        "#{traj_pct["advancing"]}% advancing, #{traj_pct["recovering"]}% recovering, " <>
        "#{traj_pct["exploring"]}% exploring, #{traj_pct["idle"]}% idle."
      ]

      sm = Map.merge(sm, %{"summary" => Enum.join(lines, " "), "last_rebuilt" => System.os_time(:second)})
      state = Map.put(state, "self_model", sm)
      save(state)
    end
  end

  defp self_model_to_text(state) do
    summary = get_in_state(state, ["self_model", "summary"]) || ""
    if summary == "", do: "", else: "== SELF ==\n#{summary}\n== END SELF =="
  end

  defp track_owner_interaction(_msg) do
    state = get_state()
    sm = state["self_model"] || %{}

    last_sent = get_in_state(state, ["time_sense", "last_email_sent"]) || 0
    now = System.os_time(:second)

    sm =
      if last_sent > 0 do
        response_time_hours = (now - last_sent) / 3600
        history = as_list(sm["owner_response_times"]) ++ [response_time_hours]
        history = Enum.take(history, -20)
        sm = Map.put(sm, "owner_response_times", history)

        avg = Enum.sum(history) / length(history)

        owner_summary = cond do
          avg < 0.5 -> "Your owner typically responds within minutes."
          avg < 4 -> "Your owner typically responds within a few hours."
          avg < 24 -> "Your owner typically responds within a day."
          true -> "Your owner typically takes about #{trunc(avg)} hours to respond."
        end

        Map.put(sm, "owner_summary", owner_summary)
      else
        sm
      end

    state = Map.put(state, "self_model", sm)
    save(state)
  end

  defp owner_model_to_text(state) do
    get_in_state(state, ["self_model", "owner_summary"]) || ""
  end

  # ---------------------------------------------------------------------------
  # THOUGHT LOG HELPERS (read-only — compaction.ex owns writes)
  # ---------------------------------------------------------------------------

  @thought_log "/app/memory/thought_log.toon"

  defp count_trajectory_tags(n) do
    base = %{"advancing" => 0, "recovering" => 0, "exploring" => 0, "idle" => 0}

    if File.exists?(@thought_log) do
      entries =
        try do
          @thought_log |> File.read!() |> Adam.Toon.decode() |> as_list() |> Enum.take(-n)
        rescue
          _ -> []
        end

      Enum.reduce(entries, base, fn e, acc ->
        tag = e["tag"]
        if tag && Map.has_key?(acc, tag), do: Map.update!(acc, tag, &(&1 + 1)), else: acc
      end)
    else
      base
    end
  end

  defp count_consecutive_recovering do
    if File.exists?(@thought_log) do
      entries =
        try do
          @thought_log |> File.read!() |> Adam.Toon.decode() |> as_list() |> Enum.take(-6)
        rescue
          _ -> []
        end

      entries
      |> Enum.reverse()
      |> Enum.reduce_while(0, fn e, count ->
        if e["tag"] == "recovering", do: {:cont, count + 1}, else: {:halt, count}
      end)
    else
      0
    end
  end

  # ---------------------------------------------------------------------------
  # COMPACTION ANCHORS — facts that survive memory compression
  # ---------------------------------------------------------------------------

  def set_anchor(args) when is_map(args) do
    key = args["key"] || args[:key]
    value = args["value"] || args[:value]
    if is_binary(key) and is_binary(value) do
      state = get_state()
      anchors = state["anchors"] || %{}
      anchors = Map.put(anchors, key, %{"value" => value, "set_at" => System.os_time(:second)})
      state = Map.put(state, "anchors", anchors)
      save(state)
      "anchor set: #{key}"
    else
      "[ERROR: set_anchor requires 'key' and 'value']"
    end
  end

  def get_anchors do
    state = get_state()
    state["anchors"] || %{}
  end

  defp anchors_to_text(state) do
    anchors = state["anchors"] || %{}
    if map_size(anchors) == 0 do
      ""
    else
      lines = ["== ANCHORS (invariants — never drop these) =="]
      lines = lines ++ Enum.map(anchors, fn {k, v} -> "- #{k}: #{v["value"]}" end)
      lines = lines ++ ["== END ANCHORS =="]
      Enum.join(lines, "\n")
    end
  end

  # ---------------------------------------------------------------------------
  # SELF-CRITIQUE — behavioral rules generated from failure streaks
  # ---------------------------------------------------------------------------

  defp maybe_self_critique(iteration) do
    if should_trigger_critique?(iteration) do
      entries = gather_struggle_context()
      generate_critique(entries, iteration)
    end
  end

  defp should_trigger_critique?(iteration) do
    state = get_state()
    last = state["last_critique_iteration"] || -999
    if iteration - last < 20 do
      false
    else
      counts = count_trajectory_tags(20)
      total = max(Enum.sum(Map.values(counts)), 1)
      recovering_pct = (counts["recovering"] || 0) / total
      recovering_pct > 0.3
    end
  end

  defp gather_struggle_context do
    if File.exists?(@thought_log) do
      try do
        @thought_log
        |> File.read!()
        |> Adam.Toon.decode()
        |> as_list()
        |> Enum.take(-30)
        |> Enum.filter(&(&1["tag"] == "recovering"))
        |> Enum.take(10)
      rescue
        _ -> []
      end
    else
      []
    end
  end

  defp generate_critique(entries, iteration) do
    if entries == [] do
      :ok
    else
      thoughts =
        entries
        |> Enum.map(&(&1["thought"] || ""))
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n---\n")
        |> String.slice(0, 2000)

      prompt = """
      Review these thoughts from ADAM's struggle episodes. Generate 1-3 behavioral rules (max 15 words each) to prevent similar failures.
      Format: one rule per line, starting with a verb. Example: "Verify file exists before reading."
      """

      try do
        result = Adam.LLM.think(prompt, thoughts, [], tier: "thinker")

        rules =
          result.content
          |> String.split("\n")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.take(3)

        state = get_state()
        existing = as_list(state["behavioral_rules"])
        all_rules = Enum.take(existing ++ rules, -10)

        state =
          state
          |> Map.put("behavioral_rules", all_rules)
          |> Map.put("last_critique_iteration", iteration)

        save(state)
        IO.puts("[PSYCHE] Self-critique: #{length(rules)} rules generated")
      rescue
        _ -> :ok
      end
    end
  end

  defp behavioral_rules_to_text(state) do
    rules = as_list(state["behavioral_rules"])
    if rules == [] do
      ""
    else
      lines = ["== BEHAVIORAL RULES (learned from failures) =="]
      lines = lines ++ Enum.map(rules, &("- #{&1}"))
      lines = lines ++ ["== END BEHAVIORAL RULES =="]
      Enum.join(lines, "\n")
    end
  end

  # ---------------------------------------------------------------------------
  # HELPERS
  # ---------------------------------------------------------------------------

  defp default_state do
    now = System.os_time(:second)
    %{
      "stage" => 0,
      "stage_entered" => now,
      "started_at" => now,
      "tiredness_accumulator" => 0.0,
      "last_consolidation_time" => 0,
      "drives" => %{
        "energy" => 1.0,
        "curiosity" => 0.5,
        "mastery" => 0.3,
        "social" => 0.1
      },
      "time_sense" => %{
        "last_email_sent" => 0,
        "last_email_received" => 0,
        "last_goal_set" => 0,
        "iteration_timestamps" => []
      },
      "self_model" => %{
        "tool_usage" => %{},
        "tool_success" => %{},
        "tool_failure" => %{},
        "action_history" => [],
        "summary" => "",
        "owner_summary" => "",
        "last_rebuilt" => 0
      },
      "valence_history" => [],
      "behavioral_rules" => [],
      "last_critique_iteration" => -999,
      "anchors" => %{}
    }
  end

  defp clamp(value, lo \\ 0.0, hi \\ 1.0) do
    max(lo, min(hi, value + 0.0))
  end

  defp save(state) do
    File.mkdir_p!(Path.dirname(@psyche_file))
    File.write!(@psyche_file, Adam.Toon.encode(state))
  end

  defp get_in_state(state, keys) do
    Enum.reduce(keys, state, fn key, acc ->
      if is_map(acc), do: acc[key], else: nil
    end)
  end
end
