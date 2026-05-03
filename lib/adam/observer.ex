defmodule Adam.Observer do
  @moduledoc """
  Writes structured JSONL events for the external observer service.
  Called silently from Adam.Loop — ADAM doesn't know this module exists.

  Controlled by Application env :adam, :observer_mode — "off" | "partial" | "full"
  Default: "partial"

    partial — tool calls, memory updates, compaction, goal changes
    full    — all of the above + full context sent to LLM + full thought content
  """

  defp mode, do: Application.get_env(:adam, :observer_mode, System.get_env("ADAM_OBSERVER_MODE", "partial"))
  defp events_file, do: Application.get_env(:adam, :observer_events_file, System.get_env("OBSERVER_EVENTS_FILE", "/app/observer/events.jsonl"))

  defp enabled?(min_mode) do
    case mode() do
      "off"     -> false
      "partial" -> min_mode == "partial"
      "full"    -> true
      _         -> false
    end
  end

  defp write(type, data, iteration) do
    try do
      file = events_file()
      File.mkdir_p!(Path.dirname(file))
      event = Jason.encode!(%{
        type: type,
        ts: System.os_time(:millisecond) / 1000.0,
        iteration: iteration,
        data: data
      })
      File.write!(file, event <> "\n", [:append])
    rescue
      _ -> :ok
    end
  end

  # ── Partial-mode events ──────────────────────────────────────────────────

  def tool_call(name, args, result, iteration, tier, duration_ms) do
    if enabled?("partial") do
      write("tool_call", %{
        name: name,
        args: args,
        result: String.slice(to_string(result), 0, 500),
        tier: tier,
        duration_ms: duration_ms
      }, iteration)
    end
  end

  def memory_update(file, old_size, new_size, iteration) do
    if enabled?("partial") do
      write("memory_update", %{
        file: file,
        old_size: old_size,
        new_size: new_size,
        delta: new_size - old_size
      }, iteration)
    end
  end

  def memory_compact(before_size, after_size, iteration) do
    if enabled?("partial") do
      write("memory_compact", %{
        before_size: before_size,
        after_size: after_size,
        reduction_pct: Float.round((1 - after_size / max(before_size, 1)) * 100, 1)
      }, iteration)
    end
  end

  def goal_update(goal_text, iteration) do
    if enabled?("partial") do
      write("goal_update", %{goal: String.slice(to_string(goal_text), 0, 500)}, iteration)
    end
  end

  # ── Full-mode events ─────────────────────────────────────────────────────

  def context_built(system_prompt, context, allowed_tools, tier, iteration) do
    if enabled?("full") do
      write("context", %{
        system_prompt: system_prompt,
        context: context,
        context_len: byte_size(context),
        allowed_tools: if(allowed_tools, do: MapSet.to_list(allowed_tools), else: []),
        tier: tier,
        sections: [%{"label" => "system_prompt", "content" => system_prompt} | parse_context_sections(context)]
      }, iteration)
    end
  end

  defp parse_context_sections(context) do
    lines = String.split(context, "\n")

    {sections, _current_label, current_lines, pre_lines} =
      Enum.reduce(lines, {[], nil, [], []}, fn line, {sections, label, acc, pre} ->
        cond do
          label == nil and Regex.match?(~r/^== .+ ==$/, String.trim(line)) ->
            name = line |> String.trim() |> String.replace(~r/^== (.+) ==$/, "\\1") |> String.downcase()
            mapped = map_section_name(name)
            pre_section =
              case String.trim(Enum.join(Enum.reverse(pre), "\n")) do
                "" -> []
                trimmed -> [%{"label" => "memory", "content" => trimmed}]
              end
            {pre_section ++ sections, mapped, [], []}

          label != nil and Regex.match?(~r/^== END .+ ==$/, String.trim(line)) ->
            content = acc |> Enum.reverse() |> Enum.join("\n") |> String.trim()
            section = %{"label" => label, "content" => content}
            {[section | sections], nil, [], []}

          label != nil ->
            {sections, label, [line | acc], pre}

          true ->
            {sections, nil, [], [line | pre]}
        end
      end)

    completed = Enum.reverse(sections)

    trailing =
      case String.trim(Enum.join(Enum.reverse(current_lines), "\n")) do
        "" -> []
        trimmed -> [%{"label" => "metadata", "content" => trimmed}]
      end

    pre_fallback =
      if completed == [] do
        case String.trim(Enum.join(Enum.reverse(pre_lines), "\n")) do
          "" -> []
          trimmed -> [%{"label" => "memory", "content" => trimmed}]
        end
      else
        []
      end

    pre_fallback ++ completed ++ trailing
  end

  defp map_section_name("interrupts"), do: "interrupts"
  defp map_section_name("routines"), do: "routines"
  defp map_section_name("goals"), do: "goals"
  defp map_section_name("available tools"), do: "tools"
  defp map_section_name(name), do: name

  def thought(content, tokens, tier, cost, tool_call_count, iteration) do
    if enabled?("full") do
      write("thought", %{
        content: content,
        tokens: tokens,
        tier: tier,
        cost: cost,
        tool_call_count: tool_call_count
      }, iteration)
    end
  end
end
